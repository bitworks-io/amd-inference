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
$keyPattern = '\Afl-[A-Za-z0-9_-]{43}\z'
# The key only ever crosses a function boundary inside a SecureString holder. The test builds and reads holders itself.
function New-Holder([string]$Text) { $h = New-Object Security.SecureString; foreach ($c in $Text.ToCharArray()) { $h.AppendChar($c) }; $h.MakeReadOnly(); return $h }
function Get-HolderText($Holder) {
    $p = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Holder)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($p) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p) }
}
$markerHolder = New-Holder $marker

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
$keyHolders = @(1..100 | ForEach-Object { InModule { New-FastLlmApiKey } })
Check (@($keyHolders | Where-Object { $_ -is [Security.SecureString] }).Count -eq 100) 'a generated key is handed out in a SecureString holder, never as a plain string'
$keys = @($keyHolders | ForEach-Object { Get-HolderText $_ })
Check (@($keys | Where-Object { $_ -cmatch $keyPattern }).Count -eq 100) 'every generated key is fl- plus 43 base64url characters (46 in all)'
Check (@($keys | Select-Object -Unique).Count -eq 100) '100 generated keys are all different'
Check (-not (@($keys) -match '[,\s#]')) 'a generated key has no comma, space or hash'
Check (('fl-' + 'A' * 43 + "`n") -cnotmatch $keyPattern -and ('fl-' + 'A' * 43) -cmatch $keyPattern) 'the key pattern rejects a trailing line feed'
# Holder rules: a holder never shows the key in ToString or Out-String.
Check ($markerHolder.ToString() -cnotmatch 'LEAKMARKER' -and ($markerHolder | Out-String) -cnotmatch 'LEAKMARKER' -and ("$markerHolder") -cnotmatch 'LEAKMARKER') 'a holder shows no key text in ToString, Out-String or string interpolation'
Check (($keyHolders[0] | Out-String) -cnotmatch [regex]::Escape($keys[0])) 'a generated holder shows no key text in Out-String'

# ---- key id ----
$sha = [Security.Cryptography.SHA256]::Create()
$hex = (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('fastllm-api-key-id-v1:' + $marker)) | ForEach-Object { $_.ToString('x2') }) -join '')
$sha.Dispose()
$id = InModule { param($K) Get-FastLlmApiKeyId -ApiKeyHolder $K } @($markerHolder)
Check ($id -cmatch '^[0-9a-f]{8}$') 'the key id is 8 lowercase hex characters'
Check ($id -ceq $hex.Substring(0, 8)) 'the key id is the first 8 hex of SHA-256 over the fixed prefix plus the key'
Check (($id -ceq (InModule { param($K) Get-FastLlmApiKeyId -ApiKeyHolder $K } @($markerHolder))) -and ($id -cne (InModule { param($K) Get-FastLlmApiKeyId -ApiKeyHolder $K } @($keyHolders[0])))) 'the key id is stable and differs between keys'
Check ($id -cnotmatch 'LEAKMARKER') 'the key id does not contain key text'

# ---- protector seam and the store ----
Set-Protector $fakeProtector
$round = InModule { param($K) Unprotect-FastLlmApiKey -Bytes (Protect-FastLlmApiKey -ApiKeyHolder $K) } @($markerHolder)
Check ($round -is [Security.SecureString] -and (Get-HolderText $round) -ceq $marker) 'a protect/unprotect round trip returns the key (fake protector)'
$store = New-TempRoot
try {
    InModule { param($R, $K) Write-FastLlmApiKeyStore -InstallRoot $R -ApiKeyHolder $K } @($store, $markerHolder)
    $file = Join-Path $store 'api-key.dat'
    Check (Test-Path -LiteralPath $file -PathType Leaf) 'the store is <InstallRoot>/api-key.dat'
    $bytes = [IO.File]::ReadAllBytes($file)
    $latin = [Text.Encoding]::GetEncoding(28591).GetString($bytes)
    Check ($latin.IndexOf($marker, [StringComparison]::Ordinal) -lt 0 -and $latin.IndexOf('LEAKMARKER', [StringComparison]::Ordinal) -lt 0) 'the store file never contains the plain key'
    Check ($latin.IndexOf([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($marker)), [StringComparison]::Ordinal) -lt 0) 'the store file does not hold a base64 copy of the key'
    Check (@(Get-ChildItem -LiteralPath $store -Force | Where-Object { $_.Name -ne 'api-key.dat' }).Count -eq 0) 'the atomic write leaves no temporary file behind'
    Check ((Get-HolderText (InModule { param($R) Read-FastLlmApiKeyStore -InstallRoot $R } @($store))) -ceq $marker) 'the store reads back the same key (as a holder)'
    $second = InModule { New-FastLlmApiKey }
    $secondText = Get-HolderText $second
    InModule { param($R, $K) Write-FastLlmApiKeyStore -InstallRoot $R -ApiKeyHolder $K } @($store, $second)
    Check ((Get-HolderText (InModule { param($R) Read-FastLlmApiKeyStore -InstallRoot $R } @($store))) -ceq $secondText) 'a second write replaces the stored key'
    Check ((Get-FailureCode { InModule { param($R, $K) Write-FastLlmApiKeyStore -InstallRoot $R -ApiKeyHolder $K } @($store, (New-Holder 'not-a-key')) }) -ceq 'api-key-invalid') 'a holder with a malformed key is refused at write time (api-key-invalid)'
    Check ((Get-FailureCode { InModule { param($R, $K) Write-FastLlmApiKeyStore -InstallRoot $R -ApiKeyHolder $K } @($store, ($marker + "`n")) }) -ceq 'api-key-invalid') 'a plain string is refused at write time (api-key-invalid)'
    Check ((Get-FailureCode { InModule { param($R, $K) Write-FastLlmApiKeyStore -InstallRoot $R -ApiKeyHolder $K } @($store, (New-Holder ($marker + "`n"))) }) -ceq 'api-key-invalid') 'a key plus a trailing line feed is refused by the store write'
    Check ((Get-FailureText { InModule { param($R, $K) Write-FastLlmApiKeyStore -InstallRoot $R -ApiKeyHolder $K } @($store, $marker) }) -cnotmatch 'LEAKMARKER') 'a refused write of a plain string does not echo the key'

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
    InModule { param($R, $K) Write-FastLlmApiKeyStore -InstallRoot $R -ApiKeyHolder $K } @($store, $markerHolder)
    $leaky = @{ Protect = { param([byte[]]$B) throw ('protect failed for ' + [Text.Encoding]::UTF8.GetString($B)) }; Unprotect = $null }
    $leaky.Unprotect = [scriptblock]::Create("param([byte[]]`$B) throw 'unprotect failed for $marker'")
    Set-Protector $leaky
    $readText = Get-FailureText { InModule { param($R) Read-FastLlmApiKeyStore -InstallRoot $R } @($store) }
    Check ($null -ne $readText -and $readText -cnotmatch 'LEAKMARKER') 'an unprotect failure carrying the key in its own text does not leak it (message, inner exceptions, error record)'
    Check ((Get-FailureCode { InModule { param($R) Read-FastLlmApiKeyStore -InstallRoot $R } @($store) }) -ceq 'api-key-unavailable') 'an unprotect failure is typed api-key-unavailable'
    $writeText = Get-FailureText { InModule { param($R, $K) Write-FastLlmApiKeyStore -InstallRoot $R -ApiKeyHolder $K } @($store, $markerHolder) }
    Check ($null -ne $writeText -and $writeText -cnotmatch 'LEAKMARKER') 'a protect failure carrying the key in its own text does not leak it'
    Set-Protector $fakeProtector
}
finally { Remove-Item -LiteralPath $store -Recurse -Force -ErrorAction SilentlyContinue }

# ---- the real DPAPI protector (Windows only) ----
if ($isWindowsHost) {
    Set-Protector $null
    $realRoot = New-TempRoot
    try {
        InModule { param($R, $K) Write-FastLlmApiKeyStore -InstallRoot $R -ApiKeyHolder $K } @($realRoot, $markerHolder)
        $realBytes = [IO.File]::ReadAllBytes((Join-Path $realRoot 'api-key.dat'))
        $realLatin = [Text.Encoding]::GetEncoding(28591).GetString($realBytes)
        Check ($realLatin.IndexOf('LEAKMARKER', [StringComparison]::Ordinal) -lt 0 -and $realLatin.IndexOf($marker, [StringComparison]::Ordinal) -lt 0) 'DPAPI: the store file never contains the plain key'
        Check ((Get-HolderText (InModule { param($R) Read-FastLlmApiKeyStore -InstallRoot $R } @($realRoot))) -ceq $marker) 'DPAPI: the store round trip returns the key'
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
$withKey = InModule { param($P, $S, $I, $K) Get-FastLlmEngineEnvironment -Plan $P -Sandbox $S -InheritedNames $I -SystemRoot 'C:\Windows' -ApiKeyHolder $K } @($envPlan, $envSandbox, $inheritedNames, $markerHolder)
Check ($withKey.set['LLAMA_API_KEY'] -ceq $marker) '-ApiKeyHolder sets LLAMA_API_KEY'
Check (@($withKey.remove) -ccontains 'LLAMA_API_KEY') '-ApiKeyHolder: an inherited LLAMA_API_KEY is still scrubbed first'
Check (@($withKey.set.Keys | Where-Object { $_ -cne 'LLAMA_API_KEY' }) -join ',' -ceq 'APPDATA,PROGRAMDATA,PATH') '-ApiKeyHolder changes nothing else in the environment'
# S2: a value llama-server would split or mangle is refused with a typed error that never carries the value.
$badValues = @(($marker.Substring(0, 20) + ',' + $marker.Substring(21)), ('"' + $marker.Substring(1) + '"'), ($marker.Substring(0, 20) + ' ' + $marker.Substring(21)), ($marker + "`n"), ($marker + "`r`n"), 'fl-short', '')
foreach ($bad in $badValues) {
    $holder = New-Holder $bad
    $code = Get-FailureCode { InModule { param($P, $S, $I, $K) Get-FastLlmEngineEnvironment -Plan $P -Sandbox $S -InheritedNames $I -SystemRoot 'C:\Windows' -ApiKeyHolder $K } @($envPlan, $envSandbox, $inheritedNames, $holder) }
    $text = Get-FailureText { InModule { param($P, $S, $I, $K) Get-FastLlmEngineEnvironment -Plan $P -Sandbox $S -InheritedNames $I -SystemRoot 'C:\Windows' -ApiKeyHolder $K } @($envPlan, $envSandbox, $inheritedNames, $holder) }
    Check ($code -ceq 'api-key-invalid' -and $text -cnotmatch 'LEAKMARKER') ("the environment builder refuses a malformed key with api-key-invalid and no key text: length " + $bad.Length)
}
$plainCode = Get-FailureCode { InModule { param($P, $S, $I, $K) Get-FastLlmEngineEnvironment -Plan $P -Sandbox $S -InheritedNames $I -SystemRoot 'C:\Windows' -ApiKeyHolder $K } @($envPlan, $envSandbox, $inheritedNames, $marker) }
Check ($plainCode -ceq 'api-key-invalid') 'the environment builder refuses a plain string in place of a holder'
$lfHolderForm = Get-FailureCode { InModule { param($K) Get-FastLlmApiKeyId -ApiKeyHolder $K } @(New-Holder ($marker + "`n")) }
Check ($lfHolderForm -ceq 'api-key-invalid') 'the key id refuses a key with a trailing line feed'
Check ((Get-FailureCode { InModule { param($K) Get-FastLlmApiKeyId -ApiKeyHolder $K } @($marker) }) -ceq 'api-key-invalid') 'the key id refuses a plain string'
Check ((Get-FailureCode { InModule { param($K) Protect-FastLlmApiKey -ApiKeyHolder $K } @($marker) }) -ceq 'api-key-invalid') 'protect refuses a plain string'
Check ((Get-FailureCode { InModule { param($B, $K) Invoke-FastLlmHttp -BaseUrl $B -Path '/props' -TimeoutMs 500 -ApiKeyHolder $K } @('http://127.0.0.1:1', $marker) }) -ceq 'api-key-invalid') 'the HTTP client refuses a plain string in place of a holder'
Check ((Get-FailureCode { InModule { param($B, $K) Invoke-FastLlmHttp -BaseUrl $B -Path '/props' -TimeoutMs 500 -ApiKeyHolder $K } @('http://127.0.0.1:1', (New-Holder 'fl-short')) }) -ceq 'api-key-invalid') 'the HTTP client refuses a holder with a malformed key'
# S3: no public key function takes the key as a plain [string] parameter.
foreach ($fn in @('Get-FastLlmApiKeyId', 'Protect-FastLlmApiKey', 'Write-FastLlmApiKeyStore', 'Get-FastLlmEngineEnvironment', 'Initialize-FastLlmEngineStartInfo', 'Invoke-FastLlmHttp')) {
    $plainKeyParams = InModule { param($N) @((Get-Command $N).Parameters.Values | Where-Object { $_.Name -match '(?i)^(ApiKey|Key)$' }).Count } @($fn)
    Check ($plainKeyParams -eq 0) "$fn has no -ApiKey or -Key parameter (the key arrives only in a holder)"
}
# the device probe's call has no key parameter in play: it goes through the same builder without a holder
$probeStart = New-Object Diagnostics.ProcessStartInfo
$probeStart.EnvironmentVariables['LLAMA_API_KEY'] = 'inherited-secret-value'
InModule { param($I, $P, $S) Initialize-FastLlmEngineStartInfo -StartInfo $I -Plan $P -Sandbox $S } @($probeStart, $envPlan, $envSandbox)
Check (-not $probeStart.EnvironmentVariables.ContainsKey('LLAMA_API_KEY')) 'the device probe path (no holder) never carries LLAMA_API_KEY and drops an inherited one'
$serverStart = New-Object Diagnostics.ProcessStartInfo
$serverStart.EnvironmentVariables['LLAMA_API_KEY'] = 'inherited-secret-value'
$serverStart.Arguments = InModule { Join-FastLlmProcessArguments -Arguments @('-m', 'model.gguf', '--port', '8080') }
$argvBefore = $serverStart.Arguments
InModule { param($I, $P, $S, $K) Initialize-FastLlmEngineStartInfo -StartInfo $I -Plan $P -Sandbox $S -ApiKeyHolder $K } @($serverStart, $envPlan, $envSandbox, $markerHolder)
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
    public int Connections;
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
                    Interlocked.Increment(ref Connections);
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
# The key is sent only to the server process the run recorded (tests/api-key-wiring-tests.ps1 covers that check). Here the recorder lives in
# this test process, so this process is the recorded server; off Windows lsof stands in for the listener table.
$self = [Diagnostics.Process]::GetCurrentProcess()
$selfIdentity = [pscustomobject]@{ pid = [int]$self.Id; startUtcTicks = [long]$self.StartTime.ToUniversalTime().Ticks }
function Get-TestListenerOwners([int]$Port) {
    $found = New-Object 'System.Collections.Generic.List[int]'
    foreach ($line in @(& lsof -nP "-iTCP@127.0.0.1:$Port" -sTCP:LISTEN -Fp 2>$null)) { if ([string]$line -match '^p(\d+)$') { $value = [int]$Matches[1]; if (-not $found.Contains($value)) { $found.Add($value) } } }
    return $found.ToArray()
}
if (-not $isWindowsHost) { & $module { param($P) $script:FastLlmApiKeyListenerOwners = $P } ${function:Get-TestListenerOwners} }
$recorder = New-Object FlApiKeyHeaderRecorder 3
try {
    $base = "http://127.0.0.1:$($recorder.Port)"
    $r1 = InModule { param($B) Invoke-FastLlmHttp -BaseUrl $B -Path '/props' -TimeoutMs 3000 } @($base)
    $r2 = InModule { param($B, $K, $I) Invoke-FastLlmHttp -BaseUrl $B -Path '/props' -TimeoutMs 3000 -ApiKeyHolder $K -ApiKeyServer $I } @($base, $markerHolder, $selfIdentity)
    $r3 = InModule { param($B) Invoke-FastLlmHttp -BaseUrl $B -Path '/props' -TimeoutMs 3000 -ApiKeyHolder $null } @($base)
    $seen = @($recorder.Snapshot())
    Check ($seen.Count -eq 3 -and $r1.Status -eq 200 -and $r2.Status -eq 200 -and $r3.Status -eq 200) 'the fake loopback server answered all three requests'
    Check ($seen[0] -cnotmatch '(?im)^authorization:') 'no key: no Authorization header is sent'
    Check ($seen[1] -cmatch ('(?im)^authorization: Bearer ' + [regex]::Escape($marker) + '\r?$')) 'with a key: Authorization: Bearer <key> is sent'
    Check ($seen[2] -cnotmatch '(?im)^authorization:') 'a null holder sends no Authorization header'
}
finally { $recorder.Dispose() }
$never = New-Object FlApiKeyHeaderRecorder 1
try {
    foreach ($url in @("http://localhost:$($never.Port)", "http://[::1]:$($never.Port)", "https://127.0.0.1:$($never.Port)", "http://user:pw@127.0.0.1:$($never.Port)", 'http://192.0.2.1:9')) {
        $text = Get-FailureText { InModule { param($B, $K, $I) Invoke-FastLlmHttp -BaseUrl $B -Path '/props' -TimeoutMs 500 -ApiKeyHolder $K -ApiKeyServer $I } @($url, $markerHolder, $selfIdentity) }
        Check ($null -ne $text -and $text -cnotmatch 'LEAKMARKER') "a non-loopback URL is refused with no key in the error: $($url -replace 'pw@', '@')"
    }
    Start-Sleep -Milliseconds 200
    Check ($never.Connections -eq 0 -and @($never.Snapshot()).Count -eq 0) 'no connection reached the listener for any refused URL, so no header was sent'
    foreach ($bad in @(($marker + "`r`nX-Injected: 1"), ($marker + ' x'), ('fl-' + 'x' * 300), ($marker + "`n"))) {
        $text = Get-FailureText { InModule { param($B, $K, $I) Invoke-FastLlmHttp -BaseUrl $B -Path '/props' -TimeoutMs 500 -ApiKeyHolder $K -ApiKeyServer $I } @("http://127.0.0.1:$($never.Port)", (New-Holder $bad), $selfIdentity) }
        Check ($null -ne $text -and $text -cnotmatch 'X-Injected' -and $text -cnotmatch 'LEAKMARKER') 'a malformed bearer value is refused without echoing it'
    }
    # The C# client is the last hop: it must refuse a bad bearer itself, before any socket is opened.
    foreach ($bad in @(($marker + "`r`nX-Injected: 1"), ($marker + ' x'), ('x' * 300))) {
        $text = Get-FailureText { InModule { param($B, $K) [Bitworks.FastLlm.LoopbackHttp]::Request($B, $null, 500, 1048576, $K) } @("http://127.0.0.1:$($never.Port)/props", $bad) }
        Check ($null -ne $text -and $text -cnotmatch 'X-Injected' -and $text -cnotmatch 'LEAKMARKER') 'the C# client refuses a malformed bearer value without echoing it'
    }
    Start-Sleep -Milliseconds 200
    Check ($never.Connections -eq 0 -and @($never.Snapshot()).Count -eq 0) 'a refused bearer value opens no socket and writes nothing'
}
finally { $never.Dispose() }

# ---- no leak through argv, status document, run log, exception messages or console ----
# A real supervised start against the mock server, with the key handed to the supervisor the way a start with the key setting on does.
# The mock enforces the key as llama-server does, so reaching Ready also means the 401/200 check passed. The proof cases, the failure
# paths and the full marker sweeps are in tests/api-key-wiring-tests.ps1.
$leakRoot = New-TempRoot
$leakListener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $leakListener.Start(); $leakPort = $leakListener.LocalEndpoint.Port; $leakListener.Stop()
$leakPlan = [pscustomobject]@{
    enginePath = (Get-Process -Id $PID).Path
    serverArguments = @('-NoLogo', '-NoProfile', '-File', (Join-Path $PSScriptRoot 'helpers/mock-server.ps1'), '-Port', "$leakPort", '-Mode', 'ok', '-Model', 'test-model', '-Context', '1024')
    endpoint = "http://127.0.0.1:$leakPort/v1"; selectedAdapters = @([pscustomobject]@{ device = 'Vulkan0' })
    hardwareFingerprint = 'synthetic'; engineVersion = 'test'; model = [pscustomobject]@{ id = 'test-model'; contextSize = 1024; sha256 = ('0' * 64) }
    catalogVersion = 'test'; backend = 'Vulkan'; splitMode = 'none'; tensorSplit = $null; modelPath = 'test-model'
    recipe = [pscustomobject]@{ id = 'r1'; origin = 'bitworks'; label = 'Measured'; evidenceUrl = 'https://bitworks.io/amd/results/x'; expected = $null }
    requestedThinking = 'off'; requestedChatPage = 'on'; requestedServerPort = [int]$leakPort
}
$leakPlan.model | Add-Member -NotePropertyMembers @{ parallel = 1; cacheTypeK = 'f16'; cacheTypeV = 'f16' }
$stopCode = "Import-Module '" + $root.Replace("'", "''") + "/src/FastLlm.psm1'; for (`$i=0; `$i -lt 300; `$i++) { try { `$s=Get-FastLlmStatus '" + $leakRoot.Replace("'", "''") + "'; if (`$s.phase -eq 'ready') { Request-FastLlmStop '" + $leakRoot.Replace("'", "''") + "'; exit 0 } } catch {}; Start-Sleep -Milliseconds 200 }; exit 1"
$stopper = New-Object Diagnostics.Process
$stopper.StartInfo.FileName = (Get-Process -Id $PID).Path
$stopper.StartInfo.Arguments = '-NoLogo -NoProfile -OutputFormat Text -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($stopCode))
$stopper.StartInfo.UseShellExecute = $false
$lock = $null
try {
    $lock = Enter-FastLlmOperation $leakRoot
    $stopper.Start() | Out-Null
    $exitCode = @(InModule { param($P, $R, $C, $H) Invoke-FastLlmSupervisedServer -Plan $P -InstallRoot $R -LoadTimeoutSeconds 120 -CatalogPath $C -ApiKeyHolder $H } @($leakPlan, $leakRoot, (Join-Path $root 'config/catalog.json'), $markerHolder) 6>$null)[-1]
    Check ($exitCode -eq 0) 'a real supervised start (mock server) with the key reaches Ready (the mock enforces the key, so the 401/200 check passed) and stops cleanly'
    Check ((@($leakPlan.serverArguments) -join ' ') -cnotmatch 'LEAKMARKER') 'no leak: the plan argument list carries no key after a real start'
    $statusText = [IO.File]::ReadAllText((Join-Path (Join-Path $leakRoot 'state') 'status.json'))
    $statusDocument = ConvertFrom-Json $statusText
    Check ($statusText -cnotmatch 'LEAKMARKER' -and $statusText -cnotmatch 'LLAMA_API_KEY' -and [string]$statusDocument.apiKey -ceq 'on' -and [string]$statusDocument.apiKeyId -ceq [string](InModule { param($K) Get-FastLlmApiKeyId -ApiKeyHolder $K } @(, $markerHolder))) 'no leak: the real status document says apiKey on with the key id, and has no key'
    $logFiles = @(Get-ChildItem -LiteralPath $leakRoot -Recurse -File -Force | Where-Object { $_.Name -cne 'operation.lock' })
    Check (@($logFiles | Where-Object { $_.FullName -match 'run-.*\.jsonl$' }).Count -ge 1) 'the real run wrote a run log to scan'
    $allText = ''
    foreach ($f in $logFiles) { $allText += [IO.File]::ReadAllText($f.FullName) }
    Check ($allText -cnotmatch 'LEAKMARKER') 'no leak: no file under the install root (status, run log, state) holds the key'
}
finally {
    if ($stopper -and -not $stopper.HasExited) { try { $stopper.Kill() } catch { } }
    $stopper.Dispose()
    if ($lock) { $lock.Dispose() }
}
try {
    $logged = InModule { param($R) Write-FastLlmRunLogEvent -InstallRoot $R -RunId 'run-1' -Event 'start' -Fields @{ modelId = 'm'; port = 8080 } } @($leakRoot)
    Check ($logged -eq $true) 'the run log is writable in the harness'
    $thrown = Get-FailureText { InModule { param($R, $K) Write-FastLlmRunLogEvent -InstallRoot $R -RunId 'run-1' -Event 'start' -Fields @{ apiKey = $K } } @($leakRoot, $markerHolder) }
    Check ($null -ne $thrown -and $thrown -cmatch 'run-log-field-not-allowed') 'no leak: the run log refuses an apiKey field'
    Check ($thrown -cnotmatch 'LEAKMARKER') 'no leak: the run-log refusal does not echo the value'
}
finally { Remove-Item -LiteralPath $leakRoot -Recurse -Force -ErrorAction SilentlyContinue }

# ---- S4: a failed replace is reported truthfully and keeps its temporary file ----
$s4 = New-TempRoot
Set-Protector $fakeProtector
try {
    InModule { param($R, $K) Write-FastLlmApiKeyStore -InstallRoot $R -ApiKeyHolder $K } @($s4, $markerHolder)
    $origMove = InModule { (Get-Command Move-FastLlmFileReplacing).ScriptBlock }
    try {
        InModule { Set-Item -Path function:Move-FastLlmFileReplacing -Value { param($Source, $Destination) Remove-Item -LiteralPath $Destination -Force; throw 'state-replace-failed: api-key.dat (HResult 0x80070020)' } }
        $failText = Get-FailureText { InModule { param($R, $K) Write-FastLlmApiKeyStore -InstallRoot $R -ApiKeyHolder $K } @($s4, (InModule { New-FastLlmApiKey })) }
        $failCode = Get-FailureCode { InModule { param($R, $K) Write-FastLlmApiKeyStore -InstallRoot $R -ApiKeyHolder $K } @($s4, (InModule { New-FastLlmApiKey })) }
    }
    finally { InModule { param($O) Set-Item -Path function:Move-FastLlmFileReplacing -Value $O } @($origMove) }
    Check ($failCode -ceq 'api-key-store-failed') 'a failed replace is typed api-key-store-failed'
    Check ($failText -cnotmatch 'Nothing was changed' -and $failText -cmatch 'may') 'a failed replace never claims that nothing was changed (the original may already be gone)'
    Check ($failText -cnotmatch 'LEAKMARKER|0x8007') 'a failed replace message carries no key text and no inner error text'
    Check (@(Get-ChildItem -LiteralPath $s4 -Force | Where-Object { $_.Name -match '^api-key\.[0-9a-f]{32}\.tmp$' }).Count -ge 1) 'a failed replace keeps the protected temporary file (it can be the only copy)'
    $tmp = @(Get-ChildItem -LiteralPath $s4 -Force | Where-Object { $_.Name -match '\.tmp$' })[0]
    $tmpLatin = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($tmp.FullName))
    Check ($tmpLatin.IndexOf('LEAKMARKER', [StringComparison]::Ordinal) -lt 0) 'the kept temporary file holds protected bytes only'
    # a failure before the replace starts leaves the original and no temp
    $s4b = New-TempRoot
    try {
        InModule { param($R, $K) Write-FastLlmApiKeyStore -InstallRoot $R -ApiKeyHolder $K } @($s4b, $markerHolder)
        $beforeText = Get-FailureText { InModule { param($R, $K) Write-FastLlmApiKeyStore -InstallRoot $R -ApiKeyHolder $K } @(([IO.Path]::Combine($s4b, 'api-key.dat')), (InModule { New-FastLlmApiKey })) }
        Check ($null -ne $beforeText -and $beforeText -cnotmatch 'LEAKMARKER') 'a store write into an impossible folder fails typed without key text'
    }
    finally { Remove-Item -LiteralPath $s4b -Recurse -Force -ErrorAction SilentlyContinue }
}
finally { Set-Protector $null; Remove-Item -LiteralPath $s4 -Recurse -Force -ErrorAction SilentlyContinue }
$source = [IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.ApiKey.ps1'))
Check ($source -cnotmatch '(?m)^\s*[^#\r\n]*\b(Write-Host|Write-Output|Write-Verbose|Write-Debug|Write-Warning|Write-Information|Out-Host|Out-File|Add-Content|Set-Content|Write-FastLlmRunLogEvent|Write-FastLlmState)\b') 'no leak: the key module has no console, log, status or text-file output call (only the store write)'
Check ($source -cnotmatch 'InnerException|\$_\.Exception\.Message|\$_\.Exception\.ToString|\$_\s*\)|\$Error\b') 'no leak: the key module never forwards an inner exception or error text'
$flat = ((Get-Content -LiteralPath (Join-Path $root 'src/FastLlm.Runtime.ps1')) -join "`n")
Check ($flat -cnotmatch 'Write-Fast[A-Za-z]*\([^)]*ApiKey|requestedArguments[^\n]*ApiKey') 'no leak: the runtime does not place an ApiKey value in state or requested arguments'
Check (-not ((InModule { $script:FastLlmRunLogAllowedFields.Values | ForEach-Object { $_ } }) -match '(?i)key')) 'no run-log event has a key-like field'

# ---- the bench path and the default golden are untouched ----
foreach ($fn in @('Get-FastLlmPlan', 'Invoke-FastLlmDeviceProbe')) {
    $body = InModule { param($N) $c = Get-Command $N -ErrorAction SilentlyContinue; if ($c) { $c.ScriptBlock.ToString() } else { '' } } @($fn)
    Check ($body.Length -gt 100 -and $body -cnotmatch 'ApiKey') "$fn does not reference the key, so the planner, the device probe and the bench path are as before"
}
# The start takes only an on/off flag (default off) and reads the store itself; a direct module call without the flag is today's start.
$startBody = InModule { (Get-Command Start-FastLlmServer).ScriptBlock.ToString() }
Check ($startBody -cmatch "\[ValidateSet\('off', 'on'\)\]\s*\[string\] \`$ApiKey = 'off'" -and $startBody -cmatch "if \(\`$ApiKey -ceq 'on'\) \{ \`$apiKeyHolder = Read-FastLlmApiKeyStore -InstallRoot \`$InstallRoot \}" -and $startBody -cnotmatch '\$ApiKeyHolder\s*[,)]') 'Start-FastLlmServer takes the flag -ApiKey (default off), never a key, and reads the store only when the flag is on'
$goldenBefore = (Get-FileHash -LiteralPath (Join-Path $root 'tests/fixtures/default-server-arguments.json') -Algorithm SHA256).Hash
Check ($goldenBefore.Length -eq 64) 'the default arguments fixture is present (the golden suite asserts its content)'
Check ((InModule { Get-Command Get-FastLlmApiKeyEnforcement, New-FastLlmApiKey -ErrorAction SilentlyContinue }).Count -eq 2) 'the key functions are module-internal and available'
Check ($null -eq (Get-Command -Module FastLlm -Name 'Read-FastLlmApiKeyStore','Write-FastLlmApiKeyStore','New-FastLlmApiKey' -ErrorAction SilentlyContinue)) 'the functions that read, write or create a key holder are not exported to callers'

Write-Host "api-key-tests: $($script:count) checks passed"
