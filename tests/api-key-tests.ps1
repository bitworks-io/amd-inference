#requires -Version 5.1
# Optional API key building blocks: key generation, the per-user protected store, the loopback-only bearer header, the child
# environment and the 401/200 enforcement rule. Nothing here starts a server, needs a GPU, a network or admin rights. The protector is
# a seam, so the store logic runs everywhere with a fake; the real DPAPI round trip runs only on Windows.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force
$module = Get-Module FastLlm
$script:count = 0
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; $script:count++; Write-Host "PASS: $Message" }
function InModule([scriptblock]$Block, [object[]]$Arguments = @()) { & $module $Block @Arguments }
$isWindowsHost = ($env:OS -eq 'Windows_NT')
$marker = 'fl-' + 'LEAKMARKER' * 4 + 'abc'
if ($marker.Length -ne 46) { throw 'test marker is not a well-formed key' }

# Everything the failure carries: message, type, inner exceptions, data. A marker anywhere in it is a leak.
function Get-FailureText([scriptblock]$Action) {
    try { & $Action | Out-Null } catch { return ($_.Exception.ToString() + '|' + [string]$_.Exception.Message + '|' + (($_ | Out-String))) }
    return $null
}
function Get-FailureCode([scriptblock]$Action) {
    try { & $Action | Out-Null } catch { if ($_.Exception.Data -and $_.Exception.Data['FastLlmFailureCode']) { return [string]$_.Exception.Data['FastLlmFailureCode'] }; return 'untyped' }
    return 'none'
}

# A reversible fake protector (xor plus a header), so the store is never plain text and a corrupt file is detectable.
$fakeProtector = @{
    Protect = { param([byte[]]$Bytes) $out = New-Object 'System.Collections.Generic.List[byte]'; $out.AddRange([byte[]](0x46, 0x4B, 0x31)); foreach ($b in $Bytes) { $out.Add([byte]($b -bxor 0x5A)) }; return ,($out.ToArray()) }
    Unprotect = { param([byte[]]$Bytes)
        if ($Bytes.Length -lt 4 -or $Bytes[0] -ne 0x46 -or $Bytes[1] -ne 0x4B -or $Bytes[2] -ne 0x31) { throw 'fake protector: not protected data' }
        $out = New-Object 'System.Collections.Generic.List[byte]'; for ($i = 3; $i -lt $Bytes.Length; $i++) { $out.Add([byte]($Bytes[$i] -bxor 0x5A)) }; return ,($out.ToArray()) }
}
function Set-Protector($Protector) { & $module { param($P) $script:FastLlmApiKeyProtector = $P } $Protector }
function New-TempRoot { $p = Join-Path ([IO.Path]::GetTempPath()) ('fl-apikey-' + [Guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $p | Out-Null; return $p }

# ---- key format and uniqueness ----
$keys = @(1..100 | ForEach-Object { InModule { New-FastLlmApiKey } })
Check (@($keys | Where-Object { $_ -cmatch '^fl-[A-Za-z0-9_-]{43}$' }).Count -eq 100) 'every generated key is fl- plus 43 base64url characters (46 in all)'
Check (@($keys | Select-Object -Unique).Count -eq 100) '100 generated keys are all different'
Check (-not (@($keys) -match '[,\s#]')) 'a generated key has no comma, space or hash'

# ---- key id ----
$sha = [Security.Cryptography.SHA256]::Create()
$hex = (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('fastllm-api-key-id-v1:' + $marker)) | ForEach-Object { $_.ToString('x2') }) -join '')
$sha.Dispose()
$id = InModule { param($K) Get-FastLlmApiKeyId -Key $K } @($marker)
Check ($id -cmatch '^[0-9a-f]{8}$') 'the key id is 8 lowercase hex characters'
Check ($id -ceq $hex.Substring(0, 8)) 'the key id is the first 8 hex of SHA-256 over the fixed prefix plus the key'
Check (($id -ceq (InModule { param($K) Get-FastLlmApiKeyId -Key $K } @($marker))) -and ($id -cne (InModule { param($K) Get-FastLlmApiKeyId -Key $K } @($keys[0])))) 'the key id is stable and differs between keys'
Check ($id -cnotmatch 'LEAKMARKER') 'the key id does not contain key text'

# ---- protector seam and the store ----
Set-Protector $fakeProtector
$round = InModule { param($K) Unprotect-FastLlmApiKey -Bytes (Protect-FastLlmApiKey -Key $K) } @($marker)
Check ($round -ceq $marker) 'a protect/unprotect round trip returns the key (fake protector)'
$store = New-TempRoot
try {
    InModule { param($R, $K) Write-FastLlmApiKeyStore -InstallRoot $R -Key $K } @($store, $marker)
    $file = Join-Path $store 'api-key.dat'
    Check (Test-Path -LiteralPath $file -PathType Leaf) 'the store is <InstallRoot>/api-key.dat'
    $bytes = [IO.File]::ReadAllBytes($file)
    $latin = [Text.Encoding]::GetEncoding(28591).GetString($bytes)
    Check ($latin.IndexOf($marker, [StringComparison]::Ordinal) -lt 0 -and $latin.IndexOf('LEAKMARKER', [StringComparison]::Ordinal) -lt 0) 'the store file never contains the plain key'
    Check ($latin.IndexOf([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($marker)), [StringComparison]::Ordinal) -lt 0) 'the store file does not hold a base64 copy of the key'
    Check (@(Get-ChildItem -LiteralPath $store -Force | Where-Object { $_.Name -ne 'api-key.dat' }).Count -eq 0) 'the atomic write leaves no temporary file behind'
    Check ((InModule { param($R) Read-FastLlmApiKeyStore -InstallRoot $R } @($store)) -ceq $marker) 'the store reads back the same key'
    $second = InModule { New-FastLlmApiKey }
    InModule { param($R, $K) Write-FastLlmApiKeyStore -InstallRoot $R -Key $K } @($store, $second)
    Check ((InModule { param($R) Read-FastLlmApiKeyStore -InstallRoot $R } @($store)) -ceq $second) 'a second write replaces the stored key'
    Check ((Get-FailureCode { InModule { param($R, $K) Write-FastLlmApiKeyStore -InstallRoot $R -Key $K } @($store, 'not-a-key') }) -ne 'none') 'a malformed key is refused at write time'
    Check ((Get-FailureText { InModule { param($R, $K) Write-FastLlmApiKeyStore -InstallRoot $R -Key $K } @($store, $marker.Substring(0, 40) + ' ' + 'LEAKMARKERx') }) -cnotmatch 'LEAKMARKER') 'a refused key write does not echo the key'

    # corrupt, missing, wrongly protected, and a store that unprotects to something that is not a key
    [IO.File]::WriteAllBytes($file, [byte[]](1, 2, 3, 4, 5, 6))
    Check ((Get-FailureCode { InModule { param($R) Read-FastLlmApiKeyStore -InstallRoot $R } @($store) }) -ceq 'api-key-unavailable') 'a corrupt store raises api-key-unavailable'
    Remove-Item -LiteralPath $file -Force
    Check ((Get-FailureCode { InModule { param($R) Read-FastLlmApiKeyStore -InstallRoot $R } @($store) }) -ceq 'api-key-unavailable') 'a missing store raises api-key-unavailable'
    [IO.File]::WriteAllBytes($file, ([byte[]](0x46, 0x4B, 0x31) + [byte[]]([Text.Encoding]::UTF8.GetBytes('short') | ForEach-Object { [byte]($_ -bxor 0x5A) })))
    Check ((Get-FailureCode { InModule { param($R) Read-FastLlmApiKeyStore -InstallRoot $R } @($store) }) -ceq 'api-key-unavailable') 'a store that unprotects to a value that is not a key raises api-key-unavailable'
    [IO.File]::WriteAllBytes($file, [byte[]]@())
    Check ((Get-FailureCode { InModule { param($R) Read-FastLlmApiKeyStore -InstallRoot $R } @($store) }) -ceq 'api-key-unavailable') 'an empty store raises api-key-unavailable'

    # a protector whose own failure text carries the key must not leak it through our exception
    InModule { param($R, $K) Write-FastLlmApiKeyStore -InstallRoot $R -Key $K } @($store, $marker)
    $leaky = @{ Protect = { param([byte[]]$B) throw ('protect failed for ' + [Text.Encoding]::UTF8.GetString($B)) }; Unprotect = $null }
    $leaky.Unprotect = [scriptblock]::Create("param([byte[]]`$B) throw 'unprotect failed for $marker'")
    Set-Protector $leaky
    $readText = Get-FailureText { InModule { param($R) Read-FastLlmApiKeyStore -InstallRoot $R } @($store) }
    Check ($null -ne $readText -and $readText -cnotmatch 'LEAKMARKER') 'an unprotect failure carrying the key in its own text does not leak it (message, inner exceptions, error record)'
    Check ((Get-FailureCode { InModule { param($R) Read-FastLlmApiKeyStore -InstallRoot $R } @($store) }) -ceq 'api-key-unavailable') 'an unprotect failure is typed api-key-unavailable'
    $writeText = Get-FailureText { InModule { param($R, $K) Write-FastLlmApiKeyStore -InstallRoot $R -Key $K } @($store, $marker) }
    Check ($null -ne $writeText -and $writeText -cnotmatch 'LEAKMARKER') 'a protect failure carrying the key in its own text does not leak it'
    Set-Protector $fakeProtector
}
finally { Remove-Item -LiteralPath $store -Recurse -Force -ErrorAction SilentlyContinue }

# ---- the real DPAPI protector (Windows only) ----
if ($isWindowsHost) {
    Set-Protector $null
    $realRoot = New-TempRoot
    try {
        InModule { param($R, $K) Write-FastLlmApiKeyStore -InstallRoot $R -Key $K } @($realRoot, $marker)
        $realBytes = [IO.File]::ReadAllBytes((Join-Path $realRoot 'api-key.dat'))
        $realLatin = [Text.Encoding]::GetEncoding(28591).GetString($realBytes)
        Check ($realLatin.IndexOf('LEAKMARKER', [StringComparison]::Ordinal) -lt 0 -and $realLatin.IndexOf($marker, [StringComparison]::Ordinal) -lt 0) 'DPAPI: the store file never contains the plain key'
        Check ((InModule { param($R) Read-FastLlmApiKeyStore -InstallRoot $R } @($realRoot)) -ceq $marker) 'DPAPI: the store round trip returns the key'
        $entropyBlob = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($marker), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        [IO.File]::WriteAllBytes((Join-Path $realRoot 'api-key.dat'), $entropyBlob)
        Check ((Get-FailureCode { InModule { param($R) Read-FastLlmApiKeyStore -InstallRoot $R } @($realRoot) }) -ceq 'api-key-unavailable') 'DPAPI: a blob protected without the fixed entropy is refused'
        [IO.File]::WriteAllBytes((Join-Path $realRoot 'api-key.dat'), [byte[]](9, 9, 9, 9))
        Check ((Get-FailureCode { InModule { param($R) Read-FastLlmApiKeyStore -InstallRoot $R } @($realRoot) }) -ceq 'api-key-unavailable') 'DPAPI: a corrupt store raises api-key-unavailable'
    }
    finally { Set-Protector $fakeProtector; Remove-Item -LiteralPath $realRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
else { Write-Host 'SKIP: DPAPI round trip (Windows-only, runs in CI)' }
Set-Protector $null

# ---- the enforcement table ----
$table = @(
    @{ n = 401; k = 200; e = 'enforced' }, @{ n = 200; k = 200; e = 'api-key-not-enforced' }, @{ n = 401; k = 401; e = 'api-key-not-enforced' },
    @{ n = 0; k = 200; e = 'api-key-not-enforced' }, @{ n = 200; k = 401; e = 'api-key-not-enforced' }, @{ n = 401; k = 0; e = 'api-key-not-enforced' },
    @{ n = 403; k = 200; e = 'api-key-not-enforced' }, @{ n = 500; k = 200; e = 'api-key-not-enforced' }, @{ n = 401; k = 204; e = 'api-key-not-enforced' }
)
foreach ($row in $table) {
    $got = InModule { param($N, $K) Get-FastLlmApiKeyEnforcement -WithoutKeyStatus $N -WithKeyStatus $K } @($row.n, $row.k)
    Check ($got -ceq $row.e) ("enforcement: without=$($row.n) with=$($row.k) -> $($row.e)")
}

# ---- the child environment ----
$envSandbox = [pscustomobject]@{ appData = 'C:\sandbox\appdata'; programData = 'C:\sandbox\programdata' }
$envPlan = [pscustomobject]@{ backend = 'Vulkan'; enginePath = 'C:\fl\engines\b10698\vulkan\llama-server.exe' }
$inheritedNames = @('PATH', 'LLAMA_API_KEY', 'LLAMA_ARG_PORT', 'HF_TOKEN')
$plain = InModule { param($P, $S, $I) Get-FastLlmEngineEnvironment -Plan $P -Sandbox $S -InheritedNames $I -SystemRoot 'C:\Windows' } @($envPlan, $envSandbox, $inheritedNames)
Check (-not $plain.set.Contains('LLAMA_API_KEY')) 'no key requested: the environment sets no LLAMA_API_KEY'
Check (@($plain.remove) -ccontains 'LLAMA_API_KEY') 'no key requested: an inherited LLAMA_API_KEY is still scrubbed'
Check (($plain.set.Keys -join ',') -ceq 'APPDATA,PROGRAMDATA,PATH') 'no key requested: the set list is exactly as before'
$withKey = InModule { param($P, $S, $I, $K) Get-FastLlmEngineEnvironment -Plan $P -Sandbox $S -InheritedNames $I -SystemRoot 'C:\Windows' -ApiKey $K } @($envPlan, $envSandbox, $inheritedNames, $marker)
Check ($withKey.set['LLAMA_API_KEY'] -ceq $marker) '-ApiKey sets LLAMA_API_KEY'
Check (@($withKey.remove) -ccontains 'LLAMA_API_KEY') '-ApiKey: an inherited LLAMA_API_KEY is still scrubbed first'
Check (@($withKey.set.Keys | Where-Object { $_ -cne 'LLAMA_API_KEY' }) -join ',' -ceq 'APPDATA,PROGRAMDATA,PATH') '-ApiKey changes nothing else in the environment'
$emptyKey = InModule { param($P, $S, $I) Get-FastLlmEngineEnvironment -Plan $P -Sandbox $S -InheritedNames $I -SystemRoot 'C:\Windows' -ApiKey '' } @($envPlan, $envSandbox, $inheritedNames)
Check (-not $emptyKey.set.Contains('LLAMA_API_KEY')) 'an empty key sets nothing'
# the device probe's call has no key parameter in play: it goes through the same builder without -ApiKey
$probeStart = New-Object Diagnostics.ProcessStartInfo
$probeStart.EnvironmentVariables['LLAMA_API_KEY'] = 'inherited-secret-value'
InModule { param($I, $P, $S) Initialize-FastLlmEngineStartInfo -StartInfo $I -Plan $P -Sandbox $S } @($probeStart, $envPlan, $envSandbox)
Check (-not $probeStart.EnvironmentVariables.ContainsKey('LLAMA_API_KEY')) 'the device probe path (no -ApiKey) never carries LLAMA_API_KEY and drops an inherited one'
$serverStart = New-Object Diagnostics.ProcessStartInfo
$serverStart.EnvironmentVariables['LLAMA_API_KEY'] = 'inherited-secret-value'
$serverStart.Arguments = InModule { Join-FastLlmProcessArguments -Arguments @('-m', 'model.gguf', '--port', '8080') }
$argvBefore = $serverStart.Arguments
InModule { param($I, $P, $S, $K) Initialize-FastLlmEngineStartInfo -StartInfo $I -Plan $P -Sandbox $S -ApiKey $K } @($serverStart, $envPlan, $envSandbox, $marker)
Check ($serverStart.EnvironmentVariables['LLAMA_API_KEY'] -ceq $marker) 'the server child gets the run key, replacing an inherited value'
Check ($serverStart.Arguments -ceq $argvBefore -and $serverStart.Arguments -cnotmatch 'LEAKMARKER') 'the key is never in the child argument list'

# ---- the loopback header ----
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
public sealed class FlApiKeyHeaderRecorder : IDisposable {
    private readonly TcpListener listener;
    private readonly Thread worker;
    private readonly int expected;
    public readonly List<string> Requests = new List<string>();
    public int Port;
    public FlApiKeyHeaderRecorder(int expectedRequests) {
        expected = expectedRequests;
        listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        Port = ((IPEndPoint)listener.LocalEndpoint).Port;
        worker = new Thread(Run);
        worker.IsBackground = true;
        worker.Start();
    }
    private void Run() {
        try {
            for (int i = 0; i < expected; i++) {
                using (TcpClient client = listener.AcceptTcpClient()) {
                    client.ReceiveTimeout = 3000;
                    NetworkStream stream = client.GetStream();
                    StringBuilder text = new StringBuilder();
                    byte[] buffer = new byte[2048];
                    while (text.ToString().IndexOf("\r\n\r\n", StringComparison.Ordinal) < 0) {
                        int n = stream.Read(buffer, 0, buffer.Length);
                        if (n <= 0) break;
                        text.Append(Encoding.ASCII.GetString(buffer, 0, n));
                    }
                    lock (Requests) { Requests.Add(text.ToString()); }
                    byte[] reply = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}");
                    stream.Write(reply, 0, reply.Length);
                }
            }
        } catch (Exception) { }
    }
    public string[] Snapshot() { lock (Requests) { return Requests.ToArray(); } }
    public void Dispose() { try { listener.Stop(); } catch (Exception) { } }
}
'@
InModule { Initialize-FastLlmProcessHost }
$recorder = New-Object FlApiKeyHeaderRecorder 3
try {
    $base = "http://127.0.0.1:$($recorder.Port)"
    $r1 = InModule { param($B) Invoke-FastLlmHttp -BaseUrl $B -Path '/props' -TimeoutMs 3000 } @($base)
    $r2 = InModule { param($B, $K) Invoke-FastLlmHttp -BaseUrl $B -Path '/props' -TimeoutMs 3000 -ApiKey $K } @($base, $marker)
    $r3 = InModule { param($B) Invoke-FastLlmHttp -BaseUrl $B -Path '/props' -TimeoutMs 3000 -ApiKey '' } @($base)
    $seen = @($recorder.Snapshot())
    Check ($seen.Count -eq 3 -and $r1.Status -eq 200 -and $r2.Status -eq 200 -and $r3.Status -eq 200) 'the fake loopback server answered all three requests'
    Check ($seen[0] -cnotmatch '(?im)^authorization:') 'no key: no Authorization header is sent'
    Check ($seen[1] -cmatch ('(?im)^authorization: Bearer ' + [regex]::Escape($marker) + '\r?$')) 'with a key: Authorization: Bearer <key> is sent'
    Check ($seen[2] -cnotmatch '(?im)^authorization:') 'an empty key sends no Authorization header'
}
finally { $recorder.Dispose() }
$never = New-Object FlApiKeyHeaderRecorder 1
try {
    foreach ($url in @("http://localhost:$($never.Port)", "http://[::1]:$($never.Port)", "https://127.0.0.1:$($never.Port)", "http://user:pw@127.0.0.1:$($never.Port)", 'http://192.0.2.1:9')) {
        $text = Get-FailureText { InModule { param($B, $K) Invoke-FastLlmHttp -BaseUrl $B -Path '/props' -TimeoutMs 500 -ApiKey $K } @($url, $marker) }
        Check ($null -ne $text -and $text -cnotmatch 'LEAKMARKER') "a non-loopback URL is refused with no key in the error: $($url -replace 'pw@', '@')"
    }
    Start-Sleep -Milliseconds 200
    Check (@($never.Snapshot()).Count -eq 0) 'no connection reached the listener for any refused URL, so no header was sent'
    foreach ($bad in @("fl-abc`r`nX-Injected: 1", "fl-abc def", ('x' * 300))) {
        $text = Get-FailureText { InModule { param($B, $K) Invoke-FastLlmHttp -BaseUrl $B -Path '/props' -TimeoutMs 500 -ApiKey $K } @("http://127.0.0.1:$($never.Port)", $bad) }
        Check ($null -ne $text -and $text -cnotmatch 'X-Injected') 'a bearer value with control, space or excessive length is refused without echoing it'
    }
    Check (@($never.Snapshot()).Count -eq 0) 'a refused bearer value sends nothing'
}
finally { $never.Dispose() }

# ---- no leak through argv, status document, run log, exception messages or console ----
$leakRoot = New-TempRoot
try {
    $plan = [pscustomobject]@{ serverArguments = @('-m', 'model.gguf', '--port', '8080', '--host', '127.0.0.1'); backend = 'Vulkan'; enginePath = $envPlan.enginePath }
    $leakStart = New-Object Diagnostics.ProcessStartInfo
    $leakStart.Arguments = InModule { param($A) Join-FastLlmProcessArguments -Arguments $A } @(, $plan.serverArguments)
    InModule { param($I, $P, $S, $K) Initialize-FastLlmEngineStartInfo -StartInfo $I -Plan $P -Sandbox $S -ApiKey $K } @($leakStart, $plan, $envSandbox, $marker)
    Check ($leakStart.Arguments -cnotmatch 'LEAKMARKER' -and (@($plan.serverArguments) -join ' ') -cnotmatch 'LEAKMARKER') 'no leak: argv and the plan argument list carry no key after the environment is built'
    $state = [ordered]@{ phase = 'ready'; requestedArguments = @($plan.serverArguments); port = 8080 }
    InModule { param($R, $S) Write-FastLlmState -InstallRoot $R -State $S } @($leakRoot, $state)
    $statusText = [IO.File]::ReadAllText((Join-Path (Join-Path $leakRoot 'state') 'status.json'))
    Check ($statusText -cnotmatch 'LEAKMARKER' -and $statusText -cnotmatch 'apiKey|LLAMA_API_KEY') 'no leak: the status document has no key and no key field when the key is not wired'
    $logged = InModule { param($R) Write-FastLlmRunLogEvent -InstallRoot $R -RunId 'run-1' -Event 'start' -Fields @{ modelId = 'm'; port = 8080 } } @($leakRoot)
    Check ($logged -eq $true) 'the run log is writable in the harness'
    $thrown = Get-FailureText { InModule { param($R, $K) Write-FastLlmRunLogEvent -InstallRoot $R -RunId 'run-1' -Event 'start' -Fields @{ apiKey = $K } } @($leakRoot, $marker) }
    Check ($null -ne $thrown -and $thrown -cmatch 'run-log-field-not-allowed') 'no leak: the run log refuses an apiKey field'
    Check ($thrown -cnotmatch 'LEAKMARKER') 'no leak: the run-log refusal does not echo the value'
    $logText = ''
    foreach ($f in @(Get-ChildItem -LiteralPath $leakRoot -Recurse -File -Force)) { $logText += [IO.File]::ReadAllText($f.FullName) }
    Check ($logText -cnotmatch 'LEAKMARKER') 'no leak: no file under the state folder or run logs holds the key'
}
finally { Remove-Item -LiteralPath $leakRoot -Recurse -Force -ErrorAction SilentlyContinue }
$source = [IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.ApiKey.ps1'))
Check ($source -cnotmatch '(?m)^\s*[^#\r\n]*\b(Write-Host|Write-Output|Write-Verbose|Write-Debug|Write-Warning|Write-Information|Out-Host|Out-File|Add-Content|Set-Content|Write-FastLlmRunLogEvent|Write-FastLlmState)\b') 'no leak: the key module has no console, log, status or text-file output call (only the store write)'
Check ($source -cnotmatch 'InnerException|\$_\.Exception\.Message|\$_\.Exception\.ToString|\$_\s*\)|\$Error\b') 'no leak: the key module never forwards an inner exception or error text'
$flat = ((Get-Content -LiteralPath (Join-Path $root 'src/FastLlm.Runtime.ps1')) -join "`n")
Check ($flat -cnotmatch 'Write-Fast[A-Za-z]*\([^)]*ApiKey|requestedArguments[^\n]*ApiKey') 'no leak: the runtime does not place an ApiKey value in state or requested arguments'
Check (-not ((InModule { $script:FastLlmRunLogAllowedFields.Values | ForEach-Object { $_ } }) -match '(?i)key')) 'no run-log event has a key-like field'

# ---- the bench path and the default golden are untouched ----
foreach ($fn in @('Get-FastLlmPlan', 'Start-FastLlmServer')) {
    $body = InModule { param($N) $c = Get-Command $N -ErrorAction SilentlyContinue; if ($c) { $c.ScriptBlock.ToString() } else { '' } } @($fn)
    Check ($body.Length -gt 100 -and $body -cnotmatch 'ApiKey') "$fn does not reference the key, so -IgnoreUserSettings and direct module calls give today's behaviour"
}
$goldenBefore = (Get-FileHash -LiteralPath (Join-Path $root 'tests/fixtures/default-server-arguments.json') -Algorithm SHA256).Hash
Check ($goldenBefore.Length -eq 64) 'the default arguments fixture is present (the golden suite asserts its content)'
Check ((InModule { Get-Command Get-FastLlmApiKeyEnforcement, New-FastLlmApiKey -ErrorAction SilentlyContinue }).Count -eq 2) 'the key functions are module-internal and available'
Check ($null -eq (Get-Command -Module FastLlm -Name 'Read-FastLlmApiKeyStore','Write-FastLlmApiKeyStore','New-FastLlmApiKey' -ErrorAction SilentlyContinue)) 'no key function is exported to callers (not wired to any surface)'

Write-Host "api-key-tests: $($script:count) checks passed"
