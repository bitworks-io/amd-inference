#requires -Version 5.1
# The optional API key, wired: the capture filter (W1), the scrub where failures are recorded (W2), the same key for the stand-in start
# (W3), the listener check before the key is sent (W4), the 401/200 proof, the settings actions and the marker sweeps. Everything runs
# against the native mock server and a fake protector: no engine, model, GPU, network or admin rights. The marker key is generated text
# in the key format, never a real key.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force
$module = Get-Module FastLlm
. (Join-Path $root 'src/FastLlm.ServingSettings.ps1')
. (Join-Path $root 'src/FastLlm.Update.ps1')
. (Join-Path $root 'src/FastLlm.Components.ps1')
. (Join-Path $root 'src/FastLlm.SupportBundle.ps1')
. (Join-Path $root 'src/FastLlm.ConnectInfo.ps1')
. (Join-Path $root 'src/FastLlm.UiFlow.ps1')
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$catalog = Join-Path $root 'config/catalog.json'
$script:count = 0
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; $script:count++; Write-Host "PASS: $Message" }
function InModule([scriptblock]$Block, [object[]]$Arguments = @()) { & $module $Block @Arguments }
$isWindowsHost = ($env:OS -eq 'Windows_NT')

# Marker keys: well-formed, recognisable, and with a tail (the last four characters) that appears nowhere else in FastLLM's own output.
$marker = 'fl-' + 'LEAKMARKER' * 3 + 'wiringKEY' + 'Zq7_'
$markerTail = 'Zq7_'
$rotated = 'fl-' + 'ROTATEDKEY' * 3 + 'wiringKEY' + 'Xw4-'
$rotatedTail = 'Xw4-'
if ($marker.Length -ne 46 -or $rotated.Length -ne 46) { throw 'a test marker is not a well-formed key' }
$leakWords = @('LEAKMARKER', $markerTail, 'ROTATEDKEY', $rotatedTail)
function New-Holder([string]$Text) { $h = New-Object Security.SecureString; foreach ($c in $Text.ToCharArray()) { $h.AppendChar($c) }; $h.MakeReadOnly(); return $h }
$markerHolder = New-Holder $marker
$rotatedHolder = New-Holder $rotated
function Get-FailureCode([scriptblock]$Action) {
    try { & $Action | Out-Null } catch { if ($_.Exception.Data -and $_.Exception.Data['FastLlmFailureCode']) { return [string]$_.Exception.Data['FastLlmFailureCode'] }; return 'untyped' }
    return 'none'
}
function Get-Failure([scriptblock]$Action) { try { & $Action | Out-Null } catch { return $_ }; return $null }
function Get-FailureText($ErrorRecord) { if ($null -eq $ErrorRecord) { return '' }; return ($ErrorRecord.Exception.ToString() + '|' + [string]$ErrorRecord.Exception.Message + '|' + (($ErrorRecord | Out-String))) }
function Test-NoLeak([string]$Text) { foreach ($word in $leakWords) { if ($Text.IndexOf($word, [StringComparison]::Ordinal) -ge 0) { return $false } }; return $true }

# A reversible fake protector (xor plus a header), so the store logic runs everywhere and the file is never plain text.
$fakeProtector = @{
    Protect = { param([byte[]]$Bytes) $out = New-Object 'System.Collections.Generic.List[byte]'; $out.AddRange([byte[]](0x46, 0x4B, 0x31)); foreach ($b in $Bytes) { $out.Add([byte]($b -bxor 0x5A)) }; return , ($out.ToArray()) }
    Unprotect = { param([byte[]]$Bytes)
        if ($Bytes.Length -lt 4 -or $Bytes[0] -ne 0x46 -or $Bytes[1] -ne 0x4B -or $Bytes[2] -ne 0x31) { throw 'fake protector: not protected data' }
        $out = New-Object 'System.Collections.Generic.List[byte]'; for ($i = 3; $i -lt $Bytes.Length; $i++) { $out.Add([byte]($Bytes[$i] -bxor 0x5A)) }; return , ($out.ToArray()) }
}
function Set-Protector($Protector) { & $module { param($P) $script:FastLlmApiKeyProtector = $P } $Protector }
function Set-ListenerOwners($Provider) { & $module { param($P) $script:FastLlmApiKeyListenerOwners = $P } $Provider }
# The owners of the 127.0.0.1 listener on a port. On Windows the product's own listener-table read is used (the seam stays $null);
# elsewhere lsof answers the same question, so the check is real on every test host.
function Get-TestListenerOwners([int]$Port) {
    $found = New-Object 'System.Collections.Generic.List[int]'
    foreach ($line in @(& lsof -nP "-iTCP@127.0.0.1:$Port" -sTCP:LISTEN -Fp 2>$null)) { if ([string]$line -match '^p(\d+)$') { $value = [int]$Matches[1]; if (-not $found.Contains($value)) { $found.Add($value) } } }
    return $found.ToArray()
}
function Reset-ListenerOwners { if ($isWindowsHost) { Set-ListenerOwners $null } else { Set-ListenerOwners ${function:Get-TestListenerOwners} } }
function Get-Identity([int]$ProcessId) { $p = [Diagnostics.Process]::GetProcessById($ProcessId); try { return [pscustomobject]@{ pid = [int]$p.Id; startUtcTicks = [long]$p.StartTime.ToUniversalTime().Ticks } } finally { $p.Dispose() } }
$temp = Join-Path ([IO.Path]::GetTempPath()) ('fl-apikey-wiring-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
function New-Dir([string]$Name) { $p = Join-Path $temp $Name; New-Item -ItemType Directory -Path $p -Force | Out-Null; return $p }
function Get-FreePort { $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop(); return $p }
# Every file under the folders, byte-wise, for every leak word: a leak in any format is found.
function Find-LeakFiles([string[]]$Folders) {
    $hits = New-Object 'System.Collections.Generic.List[string]'
    foreach ($folder in $Folders) {
        foreach ($file in @(Get-ChildItem -LiteralPath $folder -Recurse -File -Force -ErrorAction SilentlyContinue)) {
            $text = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($file.FullName))
            foreach ($word in $leakWords) { if ($text.IndexOf($word, [StringComparison]::Ordinal) -ge 0) { $hits.Add($file.Name + ' :: ' + $word) } }
        }
    }
    return $hits.ToArray()
}

try {
    Set-Protector $fakeProtector
    Reset-ListenerOwners
    InModule { Initialize-FastLlmProcessHost }

    # ================= W1: the capture filter =================
    Check ([Bitworks.FastLlm.ProcessHost]::IsSecretLine("0.00.123.456 I srv          main: api_keys: ****$markerTail", $null)) 'W1: the server line that prints the key tail is a secret line'
    Check ([Bitworks.FastLlm.ProcessHost]::IsSecretLine('main: API_KEYS: 2 keys loaded', $null) -and [Bitworks.FastLlm.ProcessHost]::IsSecretLine('x LLAMA_API_KEY=whatever', $null)) 'W1: an api_key label in any letter case is a secret line'
    Check ([Bitworks.FastLlm.ProcessHost]::IsSecretLine("request header Authorization: Bearer $marker", $marker)) 'W1: a line that holds the key itself is a secret line'
    Check (-not [Bitworks.FastLlm.ProcessHost]::IsSecretLine('load_tensors: offloaded 41/41 layers to GPU', $marker) -and -not [Bitworks.FastLlm.ProcessHost]::IsSecretLine($null, $marker) -and -not [Bitworks.FastLlm.ProcessHost]::IsSecretLine('', $null)) 'W1: an ordinary line, an empty line and no line are not secret lines'
    $w1Script = Join-Path $temp 'w1-child.ps1'
    # A device-list shaped line with the api_keys label would be captured as a device entry (name api_keys, description the tail) without the filter.
    Set-Content -LiteralPath $w1Script -Encoding ASCII -Value @(
        "[Console]::Error.WriteLine('load_tensors: offloaded 41/41 layers to GPU')",
        "[Console]::Error.WriteLine('0.00.402.100 I srv          main: api_keys: ****$markerTail')",
        "[Console]::Error.WriteLine('  - api_keys: ****$markerTail (24560 MiB, 20304 MiB free)')",
        "[Console]::Out.WriteLine('verbose header dump: Authorization: Bearer ' + `$env:LLAMA_API_KEY)",
        "[Console]::Error.WriteLine('llama_kv_cache: Vulkan0 KV buffer size = 256.00 MiB')",
        "[Console]::Out.WriteLine('ordinary line after the secret lines')"
    )
    $w1Host = New-Object Bitworks.FastLlm.ProcessHost
    try {
        $w1Info = New-Object Diagnostics.ProcessStartInfo
        $w1Info.FileName = (Get-Process -Id $PID).Path
        $w1Info.Arguments = InModule { param($A) Join-FastLlmProcessArguments $A } @(, @('-NoLogo', '-NoProfile', '-File', $w1Script))
        $w1Info.EnvironmentVariables['LLAMA_API_KEY'] = $marker
        $w1Host.DropLinesContaining($marker)
        $w1Host.Start($w1Info)
        if (-not $w1Host.Process.WaitForExit(120000)) { throw 'the W1 child did not exit' }
        $w1Wait = [Diagnostics.Stopwatch]::StartNew()
        while (-not $w1Host.OutputCompleted -and $w1Wait.ElapsedMilliseconds -lt 20000) { Start-Sleep -Milliseconds 50 }
        $w1Output = [string]$w1Host.Snapshot()
        Check ($w1Output.Contains('offloaded 41/41') -and $w1Output.Contains('KV buffer size') -and $w1Output.Contains('ordinary line after the secret lines')) 'W1: ordinary lines before and after the secret lines are still captured'
        Check (Test-NoLeak $w1Output) 'W1: neither the key nor its tail is in the in-memory output capture'
        Check ($w1Output -cnotmatch '(?i)api_key') 'W1: no api_keys line reaches the output capture'
        $w1Captures = [string]$w1Host.FreezeStartupDiagnostics() + '|' + [string]$w1Host.FreezeDeviceInfoEntries() + '|' + [string]$w1Host.FreezeUsingDeviceEntries() + '|' + [string]$w1Host.PlacementSnapshot() + '|' + [string]$w1Host.DeviceListCaptureDiagnostics()
        Check ((Test-NoLeak $w1Captures) -and $w1Captures -cnotmatch '(?i)api_key' -and [int]$w1Host.DeviceInfoLikeLines -eq 0) 'W1: a device-list shaped api_keys line never reaches the startup, placement or device captures'
        Check ([int]$w1Host.SecretLinesDropped -eq 3) 'W1: exactly the three secret lines were dropped, and only their count is kept'
    }
    finally { $w1Host.Dispose() }
    # Without a key to look for, only the labelled lines are dropped; and the host never reads a child's environment to find one.
    $w1Plain = New-Object Bitworks.FastLlm.ProcessHost
    try {
        $w1PlainInfo = New-Object Diagnostics.ProcessStartInfo
        $w1PlainInfo.FileName = (Get-Process -Id $PID).Path
        $w1PlainInfo.Arguments = InModule { param($A) Join-FastLlmProcessArguments $A } @(, @('-NoLogo', '-NoProfile', '-File', $w1Script))
        $w1Plain.Start($w1PlainInfo)
        if (-not $w1Plain.Process.WaitForExit(120000)) { throw 'the second W1 child did not exit' }
        $w1Wait = [Diagnostics.Stopwatch]::StartNew()
        while (-not $w1Plain.OutputCompleted -and $w1Wait.ElapsedMilliseconds -lt 20000) { Start-Sleep -Milliseconds 50 }
        $w1PlainOutput = [string]$w1Plain.Snapshot()
        Check ([int]$w1Plain.SecretLinesDropped -eq 2 -and $w1PlainOutput -cnotmatch '(?i)api_key' -and $w1PlainOutput.IndexOf($markerTail, [StringComparison]::Ordinal) -lt 0 -and $w1PlainOutput.Contains('verbose header dump')) 'W1: a child that was given no key still loses every api_keys line (and the tail with it); its other lines are kept'
    }
    finally { $w1Plain.Dispose() }
    $hostSourceText = [IO.File]::ReadAllText((Join-Path $root 'src/ProcessHost.cs'))
    $runtimeSourceText = [IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.Runtime.ps1'))
    Check ($hostSourceText -cnotmatch 'EnvironmentVariables' -and $runtimeSourceText.IndexOf('$hostProcess.DropLinesContaining((Get-FastLlmApiKeyText -ApiKeyHolder $ApiKeyHolder))') -gt 0 -and $runtimeSourceText.IndexOf('$hostProcess.DropLinesContaining(') -lt $runtimeSourceText.IndexOf('try { $hostProcess.Start($info) }')) 'W1: the process host never touches a child''s environment; the supervised start hands it the key to look for, before the child starts'

    # ================= W2: the scrub =================
    function Scrub([string]$Text, $Holder = $null, [switch]$Structured) { return [string](InModule { param($T, $H, $S) ConvertTo-FastLlmKeyFreeText -Text $T -ApiKeyHolder $H -Structured:$S } @($Text, $Holder, [bool]$Structured)) }
    Check ((Scrub "start failed: bearer $marker was refused") -ceq 'start failed: bearer <api-key> was refused') 'W2: a well-formed key inside a message is replaced by <api-key>'
    Check ((Scrub "a $marker b $rotated c") -ceq 'a <api-key> b <api-key> c') 'W2: every key in a text is replaced, also one FastLLM no longer holds'
    Check ((Scrub "srv main: api_keys: ****$markerTail`nnext line") -ceq "srv main: api_keys: <removed>`nnext line") 'W2: whatever follows an api_keys label is removed to the end of its line only'
    Check ((Scrub "seen ****$markerTail in a dump" $markerHolder) -ceq 'seen <api-key> in a dump') 'W2: with the run key, its masked tail is removed too'
    Check ((Scrub 'Server exited before readiness.') -ceq 'Server exited before readiness.' -and (Scrub '') -ceq '' -and (Scrub $null) -ceq '') 'W2: a text without a key is unchanged; an empty or missing text is empty'
    $folderLike = 'C:\models\fl-' + ('a' * 60) + '\x.gguf'
    Check ((Scrub $folderLike) -ceq $folderLike) 'W2: a longer run of the same characters (a folder name) is not mistaken for a key'
    $jsonLine = '{"a":"' + $marker + '","api_keys_note":"kept","n":1}'
    $jsonScrubbed = Scrub $jsonLine -Structured
    Check ($jsonScrubbed -ceq '{"a":"<api-key>","api_keys_note":"kept","n":1}' -and $null -ne (ConvertFrom-Json $jsonScrubbed)) 'W2: the structured form replaces only the key, so a JSON document keeps its shape'
    Check ((Get-FailureCode { InModule { param($T) ConvertTo-FastLlmKeyFreeText -Text $T -ApiKeyHolder 'not a holder' } @("x $marker y") }) -ceq 'none' -and (Scrub "x $marker y" 'not a holder') -ceq 'x <api-key> y') 'W2: the scrub never throws, also when the holder is not usable'

    # Where failures and state are recorded: status.json, any other state document, and the run log.
    $w2Root = New-Dir 'w2'
    $w2State = [ordered]@{ schemaVersion = 1; runId = ('c' * 32); phase = 'failed'; failureCode = 'x'; note = "the key was $marker"; nested = [ordered]@{ list = @("a $marker", 'b'); deep = [ordered]@{ text = $marker } } }
    Write-FastLlmState -InstallRoot $w2Root -State $w2State
    Write-FastLlmState -InstallRoot $w2Root -State $w2State -FileName 'selftest.json'
    $w2Status = [IO.File]::ReadAllText((Join-Path $w2Root 'state/status.json'))
    Check ((Test-NoLeak $w2Status) -and (Test-NoLeak ([IO.File]::ReadAllText((Join-Path $w2Root 'state/selftest.json'))))) 'W2: a state document never reaches disk with a key in it (status.json and selftest.json)'
    $w2Parsed = ConvertFrom-Json $w2Status
    Check ($w2Parsed.note -ceq 'the key was <api-key>' -and $w2Parsed.nested.deep.text -ceq '<api-key>' -and $w2Parsed.nested.list[1] -ceq 'b' -and $w2Parsed.phase -ceq 'failed') 'W2: the scrubbed status document is still valid JSON with every other value intact'
    $w2Run = '0123456789abcdef0123456789abcdef'
    [void](Write-FastLlmRunLogEvent -InstallRoot $w2Root -RunId $w2Run -Event 'end' -Fields @{ phase = 'failed'; failedAtPhase = 'loading'; failureCode = 'x'; failureMessage = ('p' * 170) + " $marker tail text"; exitCode = 1 })
    [void](Write-FastLlmRunLogEvent -InstallRoot $w2Root -RunId $w2Run -Event 'phase' -Fields @{ phase = "srv api_keys: ****$markerTail"; failureCode = $marker })
    $w2LogFile = @(Get-ChildItem -LiteralPath (Join-Path $w2Root 'state/logs') -Filter 'run-*.jsonl')[0]
    $w2Log = [IO.File]::ReadAllText($w2LogFile.FullName)
    Check (Test-NoLeak $w2Log) 'W2: a run-log value is scrubbed before it is cut to length, so no part of a key survives the 200-character cap'
    $w2Lines = @([IO.File]::ReadAllLines($w2LogFile.FullName) | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    Check ([string]$w2Lines[0].failureMessage -cmatch '<api-key>' -and [string]$w2Lines[1].failureCode -ceq '<api-key>' -and [string]$w2Lines[1].phase -ceq 'srv api_keys: <removed>') 'W2: the run log keeps the scrubbed text'
    Check (@(Find-LeakFiles @($w2Root)).Count -eq 0) 'W2: no key or tail in any file the state and run-log writers produced'

    # ================= W4: the listener check =================
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
public sealed class FlApiKeyWiringRecorder : IDisposable {
    private readonly TcpListener listener;
    private readonly Thread worker;
    public readonly List<string> Requests = new List<string>();
    public int Port;
    public int Connections;
    public FlApiKeyWiringRecorder() {
        listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        Port = ((IPEndPoint)listener.LocalEndpoint).Port;
        worker = new Thread(Run);
        worker.IsBackground = true;
        worker.Start();
    }
    private void Run() {
        try {
            while (true) {
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
    $own = Get-Identity $PID
    $recorder = New-Object FlApiKeyWiringRecorder
    $sleeper = $null
    try {
        $base = "http://127.0.0.1:$($recorder.Port)"
        function Send-Keyed($Identity) { InModule { param($B, $K, $I) Invoke-FastLlmHttp -BaseUrl $B -Path '/props' -TimeoutMs 5000 -ApiKeyHolder $K -ApiKeyServer $I } @($base, $markerHolder, $Identity) }
        $okReply = Send-Keyed $own
        $seen = @($recorder.Snapshot())
        Check ($okReply.Status -eq 200 -and $seen.Count -eq 1 -and $seen[0] -cmatch ('(?im)^authorization: Bearer ' + [regex]::Escape($marker) + '\r?$')) 'W4: the key is sent when the recorded server process is the one listener on the port'
        Check ((Send-Keyed @{ pid = $own.pid; startUtcTicks = $own.startUtcTicks }).Status -eq 200 -and $recorder.Connections -eq 2) 'W4: the recorded identity may be a hashtable or an object (as read from status.json)'
        $before = $recorder.Connections
        # A foreign listener: the port is owned by this test process, but the run recorded another (live) process as its server.
        $sleeper = New-Object Diagnostics.Process
        $sleeper.StartInfo.FileName = (Get-Process -Id $PID).Path
        $sleeper.StartInfo.Arguments = '-NoLogo -NoProfile -Command "Start-Sleep -Seconds 600"'
        $sleeper.StartInfo.UseShellExecute = $false
        [void]$sleeper.Start()
        $other = Get-Identity $sleeper.Id
        $refusals = [ordered]@{
            'the listener belongs to another program than the recorded server' = $other
            'the recorded process id is right but its start time is not (a reused process id)' = [pscustomobject]@{ pid = $own.pid; startUtcTicks = ($own.startUtcTicks + 1) }
            'no server process was recorded' = $null
            'the recorded identity is not a process identity' = 'fl-not-an-identity'
            'the recorded process id is zero' = [pscustomobject]@{ pid = 0; startUtcTicks = $own.startUtcTicks }
        }
        foreach ($case in $refusals.Keys) {
            $failure = Get-Failure { Send-Keyed $refusals[$case] }
            Check ($null -ne $failure -and [string]$failure.Exception.Data['FastLlmFailureCode'] -ceq 'api-key-listener-not-verified' -and (Test-NoLeak (Get-FailureText $failure))) "W4: refused, typed and without key text when $case"
        }
        Set-ListenerOwners { param($Port) return @($PID, 4242) }
        $twoOwners = Get-FailureCode { Send-Keyed $own }
        Set-ListenerOwners { param($Port) return @() }
        $noOwner = Get-FailureCode { Send-Keyed $own }
        Set-ListenerOwners { param($Port) throw "listener table failed for $marker" }
        $tableFailure = Get-Failure { Send-Keyed $own }
        Reset-ListenerOwners
        Check ($twoOwners -ceq 'api-key-listener-not-verified' -and $noOwner -ceq 'api-key-listener-not-verified') 'W4: a second listener on the port, or none, is refused'
        Check ([string]$tableFailure.Exception.Data['FastLlmFailureCode'] -ceq 'api-key-listener-not-verified' -and (Test-NoLeak (Get-FailureText $tableFailure))) 'W4: a listener table that cannot be read is refused, and its error text is not forwarded'
        Check ([string]$tableFailure.Exception.Data['FastLlmReason'] -ceq 'ApiKeyFailed') 'W4: the refusal carries the reason that keeps it out of recovery and the stand-in start'
        $deadPort = Get-FreePort
        Check ((Get-FailureCode { InModule { param($B, $K, $I) Invoke-FastLlmHttp -BaseUrl $B -Path '/props' -TimeoutMs 500 -ApiKeyHolder $K -ApiKeyServer $I } @("http://127.0.0.1:$deadPort", $markerHolder, $own) }) -ceq 'api-key-listener-not-verified') 'W4: a port nothing listens on is refused before any connection is tried'
        Start-Sleep -Milliseconds 200
        Check ($recorder.Connections -eq $before -and @($recorder.Snapshot()).Count -eq $before) 'W4: no refused request opened a connection, so the key never left the process'
        $script:ownerReads = 0
        Set-ListenerOwners { param($Port) $script:ownerReads++; return @($PID) }
        $plain = InModule { param($B) Invoke-FastLlmHttp -BaseUrl $B -Path '/health' -TimeoutMs 5000 } @($base)
        Reset-ListenerOwners
        Check ($plain.Status -eq 200 -and $script:ownerReads -eq 0 -and @($recorder.Snapshot())[-1] -cnotmatch '(?im)^authorization:') 'W4: a request without a key is sent as before: no listener check and no Authorization header'
    }
    finally {
        $recorder.Dispose()
        if ($sleeper) { try { if (-not $sleeper.HasExited) { $sleeper.Kill() } } catch { $null = $_ }; $sleeper.Dispose() }
    }

    # ================= the store actions behind on, rotate and show =================
    $storeRoot = New-Dir 'store'
    $storePath = Join-Path $storeRoot 'api-key.dat'
    $none = InModule { param($R) Get-FastLlmApiKeyStoreState -InstallRoot $R } @($storeRoot)
    Check (-not $none.exists -and -not $none.available -and $null -eq $none.apiKeyId) 'store: no store file reads as not existing and not available, without an error'
    Check ((Get-FailureCode { InModule { param($R) Assert-FastLlmApiKeyStore -InstallRoot $R } @($storeRoot) }) -ceq 'api-key-unavailable') 'store: the start check refuses a missing store with api-key-unavailable'
    $created = InModule { param($R) Initialize-FastLlmApiKeyStore -InstallRoot $R } @($storeRoot)
    Check ($created.created -eq $true -and [string]$created.apiKeyId -cmatch '\A[0-9a-f]{8}\z' -and (Test-Path -LiteralPath $storePath -PathType Leaf)) 'store: turning the key on creates a key when there is no store'
    $again = InModule { param($R) Initialize-FastLlmApiKeyStore -InstallRoot $R } @($storeRoot)
    Check ($again.created -eq $false -and [string]$again.apiKeyId -ceq [string]$created.apiKeyId) 'store: turning the key on again keeps the existing key'
    $shown = [string](InModule { param($R) Get-FastLlmApiKeyForDisplay -InstallRoot $R } @($storeRoot))
    Check ($shown -cmatch '\Afl-[A-Za-z0-9_-]{43}\z' -and (InModule { param($K) Get-FastLlmApiKeyId -ApiKeyHolder $K } @(, (New-Holder $shown))) -ceq [string]$created.apiKeyId) 'store: the key shown on request is the stored key (its id matches)'
    $storeBytes = [IO.File]::ReadAllBytes($storePath)
    Check ([Text.Encoding]::GetEncoding(28591).GetString($storeBytes).IndexOf($shown, [StringComparison]::Ordinal) -lt 0) 'store: the store file does not hold the key as text'
    $rotation = InModule { param($R) Reset-FastLlmApiKeyStore -InstallRoot $R } @($storeRoot)
    $afterRotation = [string](InModule { param($R) Get-FastLlmApiKeyForDisplay -InstallRoot $R } @($storeRoot))
    Check ($rotation.created -eq $true -and [string]$rotation.apiKeyId -cne [string]$created.apiKeyId -and [string]$rotation.previousApiKeyId -ceq [string]$created.apiKeyId -and $afterRotation -cne $shown) 'rotation: creating a new key replaces the stored key and reports both ids'
    Check (@(Get-ChildItem -LiteralPath $storeRoot -Force | Where-Object { $_.Name -cne 'api-key.dat' }).Count -eq 0) 'rotation: the replace leaves one store file and no temporary file'
    $latin = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($storePath))
    Check ($latin.IndexOf($shown, [StringComparison]::Ordinal) -lt 0 -and $latin.IndexOf($afterRotation, [StringComparison]::Ordinal) -lt 0) 'rotation: the old key is gone from the store and the new one is not stored as text'
    # An unreadable store (a moved profile, a restored backup): never replaced silently.
    [IO.File]::WriteAllBytes($storePath, [byte[]](1, 2, 3, 4, 5, 6, 7, 8))
    $unreadable = InModule { param($R) Get-FastLlmApiKeyStoreState -InstallRoot $R } @($storeRoot)
    Check ($unreadable.exists -and -not $unreadable.available -and $null -eq $unreadable.apiKeyId) 'store: an unreadable store file reads as existing but not available'
    $refusedOn = Get-Failure { InModule { param($R) Initialize-FastLlmApiKeyStore -InstallRoot $R } @($storeRoot) }
    Check ($null -ne $refusedOn -and [string]$refusedOn.Exception.Data['FastLlmFailureCode'] -ceq 'api-key-unavailable' -and [string]$refusedOn.Exception.Message -cmatch 'Create a new key') 'store: turning the key on with an unreadable store is refused (api-key-unavailable) and names the one action that helps'
    Check ((@([IO.File]::ReadAllBytes($storePath)) -join ',') -ceq '1,2,3,4,5,6,7,8') 'store: the refused action changed nothing: no key was created silently'
    Check ((Get-FailureCode { InModule { param($R) Get-FastLlmApiKeyForDisplay -InstallRoot $R } @($storeRoot) }) -ceq 'api-key-unavailable') 'store: showing an unreadable key is refused with api-key-unavailable'
    $recovered = InModule { param($R) Reset-FastLlmApiKeyStore -InstallRoot $R } @($storeRoot)
    Check ([string]$recovered.apiKeyId -cmatch '\A[0-9a-f]{8}\z' -and $null -eq $recovered.previousApiKeyId -and (InModule { param($R) Get-FastLlmApiKeyStoreState -InstallRoot $R } @($storeRoot)).available) 'store: the explicit create-a-new-key action recovers an unreadable store'
    Check ($null -eq (Get-Command -Module FastLlm -Name 'Read-FastLlmApiKeyStore', 'Write-FastLlmApiKeyStore', 'New-FastLlmApiKey', 'Get-FastLlmApiKeyText', 'Unprotect-FastLlmApiKey' -ErrorAction SilentlyContinue)) 'store: the functions that hand out a key holder or its text stay module-internal'
    Check (@(Get-Command -Module FastLlm -Name 'Get-FastLlmApiKeyStoreState', 'Assert-FastLlmApiKeyStore', 'Initialize-FastLlmApiKeyStore', 'Reset-FastLlmApiKeyStore', 'Get-FastLlmApiKeyForDisplay', 'ConvertTo-FastLlmKeyFreeText' -ErrorAction SilentlyContinue).Count -eq 6) 'store: the entry points get the six functions they need and no more'

    # ================= the run log event for an unauthorized idle read =================
    $eventRoot = New-Dir 'event'
    Check ([bool](Write-FastLlmRunLogEvent -InstallRoot $eventRoot -RunId $w2Run -Event 'idle-metrics-unauthorized' -Fields @{})) 'run log: idle-metrics-unauthorized is an allowed event'
    Check ((Get-FailureCode { Write-FastLlmRunLogEvent -InstallRoot $eventRoot -RunId $w2Run -Event 'idle-metrics-unauthorized' -Fields @{ status = 401 } }) -ceq 'untyped') 'run log: idle-metrics-unauthorized carries no field'

    # ================= supervised starts against the native mock server =================
    # The mock behaves as llama-server does with LLAMA_API_KEY set (every path but /health needs the bearer), prints the key tail at startup,
    # and in the marker modes also prints every Authorization header, as a verbose server could. <diagnostic>.auth records what each request
    # carried (none, ok or wrong; never the key).
    function New-KeyPlan([int]$Port, [string]$Mode, [string]$KeyMode, [string]$Diagnostic, [switch]$StandIn) {
        $plan = [pscustomobject]@{
            enginePath = (Get-Process -Id $PID).Path
            serverArguments = @('-NoLogo', '-NoProfile', '-File', (Join-Path $PSScriptRoot 'helpers/mock-server.ps1'), '-Port', "$Port", '-Mode', $Mode, '-Model', 'test-model', '-Context', '1024', '-DiagnosticPath', $Diagnostic, '-KeyMode', $KeyMode)
            endpoint = "http://127.0.0.1:$Port/v1"; selectedAdapters = @([pscustomobject]@{ device = 'Vulkan0' })
            hardwareFingerprint = 'synthetic'; engineVersion = 'test'; model = [pscustomobject]@{ id = 'test-model'; contextSize = 1024; sha256 = ('0' * 64) }
            catalogVersion = 'test'; backend = 'Vulkan'; splitMode = 'none'; tensorSplit = $null; modelPath = 'test-model'
            recipe = [pscustomobject]@{ id = 'r1'; origin = 'bitworks'; label = 'Measured'; evidenceUrl = 'https://bitworks.io/amd/results/x'; expected = $null }
            requestedThinking = 'auto'; requestedChatPage = 'off'; requestedServerPort = [int]$Port
        }
        $plan.model | Add-Member -NotePropertyMembers @{ parallel = 1; cacheTypeK = 'f16'; cacheTypeV = 'f16' }
        if ($StandIn) {
            $plan.recipe.id = 'vulkan-recipe'
            $plan | Add-Member -NotePropertyName fallback -NotePropertyValue ([pscustomobject]@{ fromRecipe = 'hip-recipe'; toRecipe = 'vulkan-recipe'; toModelId = 'test-model'; reason = 'hip-dll-missing'; applied = $true })
        }
        return $plan
    }
    # An independent client: waits for Ready, runs the extra code, then asks for a stop. Exit 3 when the run failed instead.
    function Start-ReadyClient([string]$InstallRoot, [string]$Extra, [hashtable]$Environment = @{}) {
        $esc = $InstallRoot.Replace("'", "''")
        $code = "Import-Module '$($root.Replace("'", "''"))/src/FastLlm.psm1'; for (`$i=0; `$i -lt 900; `$i++) { try { `$s=Get-FastLlmStatus '$esc'; if (`$s.phase -eq 'ready') { $Extra; Request-FastLlmStop '$esc'; exit 0 }; if (`$s.phase -eq 'failed') { exit 3 } } catch {}; Start-Sleep -Milliseconds 200 }; exit 1"
        $process = New-Object Diagnostics.Process
        $process.StartInfo.FileName = (Get-Process -Id $PID).Path
        $process.StartInfo.Arguments = '-NoLogo -NoProfile -OutputFormat Text -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
        $process.StartInfo.UseShellExecute = $false
        foreach ($name in $Environment.Keys) { $process.StartInfo.EnvironmentVariables[$name] = [string]$Environment[$name] }
        [void]$process.Start()
        return $process
    }
    function Test-PortClosed([int]$Port) {
        $probe = New-Object Net.Sockets.TcpClient
        try { $probe.Connect('127.0.0.1', $Port); return $false } catch [Net.Sockets.SocketException] { return $true } finally { $probe.Dispose() }
    }
    # One supervised start. -Holder $null means no key parameter at all (today's start). Returns the exit code or the failure, every console
    # line the start wrote, the mock's auth record and the final status.
    function Invoke-KeyRun {
        param([string]$Name, [string]$Mode = 'selftest-ok', [string]$KeyMode = 'enforce', $Holder, [switch]$SelfTest, [switch]$Canary, [int]$IdleMinutes = 0, [switch]$StandIn, [string]$Extra = '', [hashtable]$ClientEnvironment = @{}, [string]$Install = '')
        if (-not $Install) { $Install = New-Dir $Name }
        $port = Get-FreePort
        $diagnostic = Join-Path $temp ($Name + '-diagnostic.txt')
        $plan = New-KeyPlan $port $Mode $KeyMode $diagnostic -StandIn:$StandIn
        $options = @{ Plan = $plan; InstallRoot = $Install; LoadTimeoutSeconds = 120; CatalogPath = $catalog }
        if ($null -ne $Holder) { $options.ApiKeyHolder = $Holder }
        if ($SelfTest) { $options.SelfTest = $true }
        if ($Canary) { $options.ThroughputCanary = $true }
        if ($IdleMinutes -gt 0) { $options.IdleStopMinutes = $IdleMinutes }
        $lock = Enter-FastLlmOperation $Install
        $client = $null
        $failure = $null; $exit = $null
        $console = New-Object 'System.Collections.Generic.List[string]'
        try {
            $client = Start-ReadyClient $Install $Extra $ClientEnvironment
            try {
                foreach ($item in @(& $module { param($O) Invoke-FastLlmSupervisedServer @O } $options 6>&1 3>&1)) {
                    if ($item -is [Management.Automation.InformationRecord]) { $console.Add([string]$item.MessageData) }
                    elseif ($item -is [Management.Automation.WarningRecord]) { $console.Add([string]$item.Message) }
                    else { $exit = $item }
                }
            }
            catch { $failure = $_ }
        }
        finally {
            if ($client) { if (-not $client.WaitForExit(20000)) { try { $client.Kill() } catch { $null = $_ } }; $client.Dispose() }
            $lock.Dispose()
        }
        $auth = @()
        if (Test-Path -LiteralPath ($diagnostic + '.auth')) { $auth = @([IO.File]::ReadAllLines($diagnostic + '.auth') | Where-Object { $_ }) }
        $status = $null
        try { $status = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $Install 'state/status.json'))) } catch { $status = $null }
        return [pscustomobject]@{ install = $Install; port = $port; exit = $exit; failure = $failure; console = $console.ToArray(); auth = $auth; status = $status; plan = $plan; diagnostic = $diagnostic }
    }
    function Get-RunLogLines([string]$Install) {
        $lines = New-Object 'System.Collections.Generic.List[object]'
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $Install 'state/logs') -Filter 'run-*.jsonl' -ErrorAction SilentlyContinue | Sort-Object Name)) {
            foreach ($line in @([IO.File]::ReadAllLines($file.FullName) | Where-Object { $_ })) { $lines.Add(($line | ConvertFrom-Json)) }
        }
        return $lines.ToArray()
    }
    # Everything a run left behind and everything it printed or threw, for the leak sweep; with -Bundle the unzipped support bundle too.
    function Get-RunLeaks($Run, [switch]$Bundle) {
        $hits = New-Object 'System.Collections.Generic.List[string]'
        $folders = @($Run.install)
        if ($Bundle) {
            $zip = Join-Path $temp ([Guid]::NewGuid().ToString('N') + '.zip')
            $listing = New-FastLlmSupportBundle -InstallRoot $Run.install -AppRoot $root -OutputPath $zip -Doctor ([ordered]@{ installRoot = $Run.install; error = $null })
            if (-not $listing.saved) { throw 'the support bundle was not saved' }
            $unzipped = Join-Path $temp ([Guid]::NewGuid().ToString('N'))
            [IO.Compression.ZipFile]::ExtractToDirectory($zip, $unzipped)
            $folders += $unzipped
            if (@(Get-ChildItem -LiteralPath $unzipped -Recurse -File | Where-Object { $_.Name -like 'run-*.jsonl' }).Count -lt 1) { throw 'the support bundle holds no run log to scan' }
        }
        foreach ($hit in @(Find-LeakFiles $folders)) { $hits.Add($hit) }
        $spoken = ($Run.console -join "`n") + "`n" + (Get-FailureText $Run.failure)
        foreach ($word in $leakWords) { if ($spoken.IndexOf($word, [StringComparison]::Ordinal) -ge 0) { $hits.Add('console or failure text :: ' + $word) } }
        return $hits.ToArray()
    }
    function Get-AuthPaths($Run, [string]$State) { return @($Run.auth | Where-Object { $_ -cmatch (' ' + $State + '$') } | ForEach-Object { ($_ -split ' ')[1] }) }
    InModule { $script:FastLlmIdlePollSeconds = 1 }
    # The store is the source of the key, as in a real start: the first key is written, read back as a holder and handed to the supervisor.
    $runStore = New-Dir 'run-store'
    InModule { param($R, $K) Write-FastLlmApiKeyStore -InstallRoot $R -ApiKeyHolder $K } @($runStore, $markerHolder)
    $storedHolder = InModule { param($R) Read-FastLlmApiKeyStore -InstallRoot $R } @($runStore)
    $markerId = [string](InModule { param($K) Get-FastLlmApiKeyId -ApiKeyHolder $K } @(, $markerHolder))
    $waitForIdle = "for(`$j=0; `$j -lt 300; `$j++){ if (@(Select-String -LiteralPath '$(($temp + '/NAME-diagnostic.txt.auth').Replace("'", "''"))' -Pattern ' /metrics ' -SimpleMatch -ErrorAction SilentlyContinue).Count -ge 2) { break }; Start-Sleep -Milliseconds 200 }"

    # ---- proof 401/200: the key is on, with the self-test, the throughput canary and the idle read ----
    $run = Invoke-KeyRun -Name 'key-on' -Mode 'marker-selftest-ok' -Holder $storedHolder -SelfTest -Canary -IdleMinutes 15 -Extra ($waitForIdle.Replace('NAME', 'key-on')) -Install $runStore
    Check ($null -eq $run.failure -and $run.exit -eq 0) "proof 401/200: a start with the key reaches Ready and stops cleanly$(if ($run.failure) { ': ' + [string]$run.failure.Exception.Message })"
    Check ($run.auth[0] -ceq 'env key-present' -and @($run.auth | Where-Object { $_ -cmatch ' wrong$' }).Count -eq 0) 'start: the server child received the key in its environment, and FastLLM never sent a wrong key'
    Check ((@($run.plan.serverArguments) -join ' ').IndexOf('LEAKMARKER', [StringComparison]::Ordinal) -lt 0 -and (@($run.status.recipe.requestedArguments) -join ' ').IndexOf('LEAKMARKER', [StringComparison]::Ordinal) -lt 0 -and [IO.File]::ReadAllText($run.diagnostic) -cne 'api-key-in-arguments') 'start: the key is in no argument (the plan, the recorded arguments, the child command line)'
    $withoutKey = @(Get-AuthPaths $run 'none' | Where-Object { $_ -cne '/health' })
    Check ($withoutKey.Count -eq 1 -and $withoutKey[0] -ceq '/props') "proof 401/200: exactly one request went without the key, the proof's own (saw: $($withoutKey -join ','))"
    $withKey = @(Get-AuthPaths $run 'ok' | Select-Object -Unique)
    Check (@(@('/props', '/v1/models', '/completion', '/v1/chat/completions', '/tokenize', '/metrics') | Where-Object { $withKey -cnotcontains $_ }).Count -eq 0) "own requests: the API check, the self-test, the throughput canary and the idle read all carried the key (saw: $($withKey -join ','))"
    Check (@(Get-AuthPaths $run 'ok' | Where-Object { $_ -ceq '/health' }).Count -eq 0 -and @(Get-AuthPaths $run 'none' | Where-Object { $_ -ceq '/health' }).Count -ge 1) 'own requests: /health stays public and never carries the key'
    Check ([string]$run.status.apiKey -ceq 'on' -and [string]$run.status.apiKeyId -ceq $markerId -and $markerId -cmatch '\A[0-9a-f]{8}\z') 'status: apiKey is on with the key id (first 8 hex of the id function), only after the proof'
    Check ([string]$run.status.selfTest.status -ceq 'pass' -and $null -ne $run.status.throughputCanary -and [string]$run.status.throughputCanary.status -cne 'failed') 'own requests: the self-test passed and the throughput canary measured, both through the key'
    Check (@($run.console | Where-Object { $_ -clike "API key: on (key id $markerId)*" }).Count -eq 1) 'start: the console says the key is on, once, with the key id and never the key'
    $events = @(Get-RunLogLines $run.install)
    Check (@($events | Where-Object { [string]$_.event -ceq 'idle-metrics-unauthorized' -or [string]$_.event -ceq 'idle-check-failed' }).Count -eq 0 -and @(Get-AuthPaths $run 'ok' | Where-Object { $_ -ceq '/metrics' }).Count -ge 2) 'idle read: with the key the /metrics reads succeed (no failed or unauthorized read is logged)'
    $leaks = @(Get-RunLeaks $run -Bundle)
    Check ($leaks.Count -eq 0) "marker sweep (normal start): no key or tail in status.json, selftest.json, the run log, the support bundle, a console line or a failure ($($leaks -join '; '))"
    Check (Test-Path -LiteralPath (Join-Path $run.install 'state/selftest.json')) 'marker sweep (normal start): selftest.json was written, so the sweep covered it'

    # ---- rotation: an atomic replace, the old key dies at the next start ----
    InModule { param($R, $K) Write-FastLlmApiKeyStore -InstallRoot $R -ApiKeyHolder $K } @($runStore, $rotatedHolder)
    $rotatedId = [string](InModule { param($K) Get-FastLlmApiKeyId -ApiKeyHolder $K } @(, $rotatedHolder))
    $afterRotate = InModule { param($R) Get-FastLlmApiKeyStoreState -InstallRoot $R } @($runStore)
    Check ([string]$afterRotate.apiKeyId -ceq $rotatedId -and [string]$run.status.apiKeyId -cne $rotatedId) 'rotation: after the replace the stored key id differs from the id the last run recorded (the window says restart to use the new key)'
    $clientResult = Join-Path $temp 'rotation-client.txt'
    $clientCode = "foreach(`$which in @('OLD','NEW','NONE')){ `$headers=@{}; if(`$which -cne 'NONE'){ `$headers['Authorization']='Bearer ' + [Environment]::GetEnvironmentVariable('FLTEST_' + `$which) }; `$code=0; try { `$code=[int](Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:PORT/props' -Headers `$headers -TimeoutSec 30).StatusCode } catch { try { `$code=[int]`$_.Exception.Response.StatusCode } catch { `$code=-1 } }; Add-Content -LiteralPath '$($clientResult.Replace("'", "''"))' -Value (`$which + '=' + `$code) }"
    # The port is not known before the run, so the client reads it from the status endpoint.
    $clientCode = $clientCode.Replace("'http://127.0.0.1:PORT/props'", "((`$s.endpoint -replace '/v1`$','') + '/props')")
    $rotatedRun = Invoke-KeyRun -Name 'rotated' -Mode 'marker-selftest-ok' -Holder (InModule { param($R) Read-FastLlmApiKeyStore -InstallRoot $R } @($runStore)) -Extra $clientCode -ClientEnvironment @{ FLTEST_OLD = $marker; FLTEST_NEW = $rotated } -Install $runStore
    Check ($null -eq $rotatedRun.failure -and $rotatedRun.exit -eq 0 -and [string]$rotatedRun.status.apiKeyId -ceq $rotatedId) "rotation: the next start runs with the new key$(if ($rotatedRun.failure) { ': ' + [string]$rotatedRun.failure.Exception.Message })"
    $clientLines = @(if (Test-Path -LiteralPath $clientResult) { [IO.File]::ReadAllLines($clientResult) })
    Check (($clientLines -join ',') -ceq 'OLD=401,NEW=200,NONE=401') "rotation: at the next start the old key is refused, the new key works, and no key is refused (saw: $($clientLines -join ','))"
    $leaks = @(Get-RunLeaks $rotatedRun -Bundle)
    Check ($leaks.Count -eq 0) "marker sweep (rotation): neither the old nor the new key, nor a tail, in any file, console line or failure ($($leaks -join '; '))"
    Check (@(Get-ChildItem -LiteralPath $runStore -Force -File | Where-Object { $_.Name -like 'api-key*' }).Count -eq 1) 'rotation: one store file remains (no temporary copy of either key)'

    # ---- the stand-in start (W3 at the supervisor): the same key, and the proof again ----
    $standIn = Invoke-KeyRun -Name 'stand-in' -Mode 'marker-selftest-ok' -Holder $rotatedHolder -SelfTest -StandIn
    Check ($null -eq $standIn.failure -and $standIn.exit -eq 0 -and [string]$standIn.status.fallback.fromRecipe -ceq 'hip-recipe') "W3: a stand-in (fallback) plan starts with the key$(if ($standIn.failure) { ': ' + [string]$standIn.failure.Exception.Message })"
    $standInWithout = @(Get-AuthPaths $standIn 'none' | Where-Object { $_ -cne '/health' })
    Check ($standIn.auth[0] -ceq 'env key-present' -and $standInWithout.Count -eq 1 -and $standInWithout[0] -ceq '/props' -and [string]$standIn.status.apiKey -ceq 'on' -and [string]$standIn.status.apiKeyId -ceq $rotatedId) 'W3: the stand-in server got the key in its environment and the 401/200 proof ran again before its status said the key is on'
    $leaks = @(Get-RunLeaks $standIn -Bundle)
    Check ($leaks.Count -eq 0) "marker sweep (fallback): no key or tail anywhere after a stand-in start ($($leaks -join '; '))"

    # ---- proof failures: the key is not enforced ----
    foreach ($case in @(@{ name = 'ignored'; keyMode = 'ignore'; without = 200; with = 200 }, @{ name = 'rejected'; keyMode = 'reject'; without = 401; with = 401 })) {
        $bad = Invoke-KeyRun -Name ('not-enforced-' + $case.name) -Mode 'marker-selftest-ok' -KeyMode $case.keyMode -Holder $markerHolder -SelfTest
        $badCode = ''; $badReason = ''; $badMessage = ''
        if ($bad.failure) { $badCode = [string]$bad.failure.Exception.Data['FastLlmFailureCode']; $badReason = [string]$bad.failure.Exception.Data['FastLlmReason']; $badMessage = [string]$bad.failure.Exception.Message }
        Check ($badCode -ceq 'api-key-not-enforced' -and $badReason -ceq 'ApiKeyFailed') "proof $($case.without)/$($case.with): the start fails with api-key-not-enforced and the reason that is never retried or replaced (saw: $badCode / $badMessage)"
        Check ($badMessage -cmatch ("without the key got HTTP status $($case.without) ") -and $badMessage -cmatch ("with the key got $($case.with) ")) "proof $($case.without)/$($case.with): the refusal states both statuses"
        Check ([string]$bad.status.phase -ceq 'failed' -and [string]$bad.status.failureCode -ceq 'api-key-not-enforced' -and -not $bad.status.PSObject.Properties['apiKey'] -and -not $bad.status.PSObject.Properties['apiKeyId']) "proof $($case.without)/$($case.with): the status records the code and never says the key is on"
        Check (Test-PortClosed $bad.port) "proof $($case.without)/$($case.with): the server was stopped"
        Check (@($bad.console | Where-Object { $_ -clike 'API key: on*' -or $_ -clike 'Ready:*' }).Count -eq 0) "proof $($case.without)/$($case.with): nothing printed says Ready or key on"
        $badPaths = @($bad.auth | Where-Object { $_ -cnotmatch '^env ' } | ForEach-Object { ($_ -split ' ')[1] } | Where-Object { $_ -cne '/health' } | Select-Object -Unique)
        Check (($badPaths -join ',') -ceq '/props') "proof $($case.without)/$($case.with): no API check, self-test or other request followed the failed proof (saw: $($badPaths -join ','))"
        $end = @(Get-RunLogLines $bad.install | Where-Object { [string]$_.event -ceq 'end' })[0]
        Check ([string]$end.failureCode -ceq 'api-key-not-enforced' -and [string]$end.failedAtPhase -ceq 'loading') "proof $($case.without)/$($case.with): the run log ends with the code, before the API checks"
        $leaks = @(Get-RunLeaks $bad -Bundle)
        Check ($leaks.Count -eq 0) "marker sweep (not enforced, $($case.name)): no key or tail in any file, console line or failure ($($leaks -join '; '))"
    }

    # ---- other failure paths with the key on ----
    $early = Invoke-KeyRun -Name 'early-exit' -Mode 'marker-exit' -Holder $markerHolder -SelfTest
    Check ($null -ne $early.failure -and [string]$early.failure.Exception.Message -cmatch 'before readiness' -and [string]$early.status.phase -ceq 'failed' -and -not $early.status.PSObject.Properties['apiKey']) 'failure path: a server that exits before readiness fails as before, and the status never says the key is on'
    $leaks = @(Get-RunLeaks $early -Bundle)
    Check ($leaks.Count -eq 0) "marker sweep (server exit before readiness): no key or tail anywhere ($($leaks -join '; '))"
    $lateFail = Invoke-KeyRun -Name 'late-fail' -Mode 'marker-unstable' -Holder $markerHolder -SelfTest
    Check ($null -ne $lateFail.failure -and [string]$lateFail.failure.Exception.Message -cmatch 'not repeatable' -and [string]$lateFail.status.failureCode -ceq 'startup-or-runtime-check-failed' -and (Test-PortClosed $lateFail.port)) 'failure path: an API check that fails after the proof fails the start as before and stops the server'
    $leaks = @(Get-RunLeaks $lateFail -Bundle)
    Check ($leaks.Count -eq 0) "marker sweep (API check failure after the proof): no key or tail anywhere ($($leaks -join '; '))"
    # A failure whose own text holds the key: what is thrown on, recorded and printed is the scrubbed text.
    $savedCanary = InModule { (Get-Command Test-FastLlmApiCanary).ScriptBlock }
    try {
        InModule { param($K, $T) $script:FlWiringLeakText = "check failed while sending Bearer $K (server said api_keys: ****$T)"; function script:Test-FastLlmApiCanary { throw $script:FlWiringLeakText } } @($marker, $markerTail)
        $leaky = Invoke-KeyRun -Name 'leaky-failure' -Mode 'marker-selftest-ok' -Holder $markerHolder
    }
    finally { InModule { param($C) Set-Item -Path 'Function:script:Test-FastLlmApiCanary' -Value $C; $script:FlWiringLeakText = $null } @($savedCanary) }
    Check ($null -ne $leaky.failure -and [string]$leaky.failure.Exception.Message -ceq 'check failed while sending Bearer <api-key> (server said api_keys: <removed>' -and [string]$leaky.failure.Exception.Data['FastLlmReason'] -ceq 'RuntimeCheckFailed') 'W2: a failure whose text holds the key is passed on with the scrubbed text and the same failure data'
    $leaks = @(Get-RunLeaks $leaky -Bundle)
    Check ($leaks.Count -eq 0) "marker sweep (a failure that echoes the key): no key or tail in any file, console line or the failure itself ($($leaks -join '; '))"

    # ---- W4 inside a start: the listener is not this run's server ----
    Set-ListenerOwners { param($Port) return @(4242) }
    try { $foreign = Invoke-KeyRun -Name 'foreign-listener' -Mode 'marker-selftest-ok' -Holder $markerHolder -SelfTest }
    finally { Reset-ListenerOwners }
    $foreignCode = ''
    if ($foreign.failure) { $foreignCode = [string]$foreign.failure.Exception.Data['FastLlmFailureCode'] }
    Check ($foreignCode -ceq 'api-key-listener-not-verified' -and [string]$foreign.status.failureCode -ceq 'api-key-listener-not-verified' -and (Test-PortClosed $foreign.port)) "W4: a start whose port is owned by another process is refused with its own code and stopped (saw: $foreignCode)"
    Check (@($foreign.auth | Where-Object { $_ -cmatch ' (ok|wrong)$' }).Count -eq 0 -and -not $foreign.status.PSObject.Properties['apiKey']) 'W4: the key was never sent (no request carried a bearer), and the status never says the key is on'
    $leaks = @(Get-RunLeaks $foreign -Bundle)
    Check ($leaks.Count -eq 0) "marker sweep (listener not verified): no key or tail anywhere ($($leaks -join '; '))"

    # ---- a malformed or missing holder never becomes a keyless start ----
    foreach ($badHolder in @(@{ label = 'a plain string'; value = $marker }, @{ label = 'a holder with a malformed key'; value = (New-Holder 'fl-short') })) {
        $refusedRoot = New-Dir ('bad-holder-' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
        $refused = Get-Failure { InModule { param($P, $R, $C, $H) Invoke-FastLlmSupervisedServer -Plan $P -InstallRoot $R -LoadTimeoutSeconds 30 -CatalogPath $C -ApiKeyHolder $H } @((New-KeyPlan (Get-FreePort) 'ok' 'enforce' (Join-Path $refusedRoot 'd.txt')), $refusedRoot, $catalog, $badHolder.value) }
        Check ($null -ne $refused -and [string]$refused.Exception.Data['FastLlmFailureCode'] -ceq 'api-key-invalid' -and (Test-NoLeak (Get-FailureText $refused)) -and -not (Test-Path -LiteralPath (Join-Path $refusedRoot 'state/status.json')) -and -not (Test-Path -LiteralPath (Join-Path $refusedRoot 'd.txt.auth'))) "fail closed: $($badHolder.label) is refused (api-key-invalid) before anything is written or launched"
    }
    $nullRoot = New-Dir 'null-holder'
    $nullRefused = Get-Failure { InModule { param($P, $R, $C) Invoke-FastLlmSupervisedServer -Plan $P -InstallRoot $R -LoadTimeoutSeconds 30 -CatalogPath $C -ApiKeyHolder $null } @((New-KeyPlan (Get-FreePort) 'ok' 'enforce' (Join-Path $nullRoot 'd.txt')), $nullRoot, $catalog) }
    Check ($null -ne $nullRefused -and [string]$nullRefused.Exception.Data['FastLlmFailureCode'] -ceq 'api-key-invalid' -and -not (Test-Path -LiteralPath (Join-Path $nullRoot 'd.txt.auth'))) 'fail closed: a key that was asked for but is empty is refused; it never becomes a start without a key'

    # ---- no key: today's start, also with a key variable in the caller's environment (the bench path) ----
    $savedVariable = [Environment]::GetEnvironmentVariable('LLAMA_API_KEY')
    [Environment]::SetEnvironmentVariable('LLAMA_API_KEY', $marker)
    try { $plain = Invoke-KeyRun -Name 'key-off' -Mode 'marker-selftest-ok' -Holder $null -SelfTest -Canary -IdleMinutes 15 -Extra ($waitForIdle.Replace('NAME', 'key-off')) }
    finally { [Environment]::SetEnvironmentVariable('LLAMA_API_KEY', $savedVariable) }
    Check ($null -eq $plain.failure -and $plain.exit -eq 0) "no key: a start without the key parameter reaches Ready and stops$(if ($plain.failure) { ': ' + [string]$plain.failure.Exception.Message })"
    Check ($plain.auth[0] -ceq 'env key-absent' -and @($plain.auth | Where-Object { $_ -cnotmatch '^env ' -and $_ -cnotmatch ' none$' }).Count -eq 0 -and @(Get-AuthPaths $plain 'none' | Where-Object { $_ -ceq '/metrics' }).Count -ge 2) 'no key: the server child gets no key (an inherited LLAMA_API_KEY is removed) and no request carries a bearer'
    Check (-not $plain.status.PSObject.Properties['apiKey'] -and -not $plain.status.PSObject.Properties['apiKeyId'] -and @($plain.console | Where-Object { $_ -clike 'API key*' }).Count -eq 0) 'no key: the status has no apiKey field and the console says nothing about a key'
    Check (@(Find-LeakFiles @($plain.install)).Count -eq 0) 'no key: the inherited variable left no trace in any file'
    $benchCallers = @(Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter '*.ps1' | Where-Object { $_.Name -cnotin @('FastLlm.Runtime.ps1', 'FastLlm.ApiKey.ps1', 'FastLlm.BackgroundHost.ps1', 'FastLlm.ServingSettings.ps1', 'FastLlm.ConnectInfo.ps1', 'FastLlm.UiFlow.ps1', 'FastLlm.SupportBundle.ps1') } | Where-Object { [IO.File]::ReadAllText($_.FullName) -cmatch '(?<!FastLlm\.)ApiKey|LLAMA_API_KEY' })
    $benchTools = @(Get-ChildItem -LiteralPath (Join-Path $root 'tools') -Filter '*.ps1' | Where-Object { [IO.File]::ReadAllText($_.FullName) -cmatch '(?<!FastLlm\.)ApiKey|LLAMA_API_KEY' })
    $benchRefusal = InModule { try { Assert-FastLlmBenchmarkDefaultSetup -State ([pscustomobject]@{ active = $true; phase = 'ready'; apiKey = 'on'; apiKeyId = '0123abcd' }); 'accepted' } catch { [string]$_.Exception.Message } }
    Check ($benchRefusal -ceq 'Benchmarks measure the default setup. Turn the API key off, start again, then benchmark.') 'bench path: the benchmark tool refuses a run that was started with the API key on'
    Check ($benchCallers.Count -eq 0 -and $benchTools.Count -eq 0) "bench path: no benchmark, lab or tool script passes or reads a key (only the file name FastLlm.ApiKey.ps1 appears, in source lists) ($(@($benchCallers + $benchTools | ForEach-Object { $_.Name }) -join ','))"
    $planBody = InModule { (Get-Command Get-FastLlmPlan).ScriptBlock.ToString() + (Get-Command Invoke-FastLlmDeviceProbe).ScriptBlock.ToString() }
    Check ($planBody.Length -gt 1000 -and $planBody -cnotmatch 'ApiKey') 'bench path: the planner and the device probe never see the key'

    # ---- the idle read refused with 401: a failed read, logged once, never a stop ----
    $unauthorized = Invoke-KeyRun -Name 'metrics-401' -Mode 'selftest-ok' -KeyMode 'metrics-401' -Holder $markerHolder -IdleMinutes 15 -Extra (($waitForIdle.Replace('NAME', 'metrics-401')).Replace('-ge 2', '-ge 3'))
    Check ($null -eq $unauthorized.failure -and $unauthorized.exit -eq 0 -and [string]$unauthorized.status.stopReason -ceq 'user') "idle 401: three refused /metrics reads did not stop the server; it ran until the user stop$(if ($unauthorized.failure) { ': ' + [string]$unauthorized.failure.Exception.Message })"
    $idleEvents = @(Get-RunLogLines $unauthorized.install | Where-Object { [string]$_.event -clike 'idle-*' } | ForEach-Object { [string]$_.event })
    Check (@($idleEvents | Where-Object { $_ -ceq 'idle-metrics-unauthorized' }).Count -eq 1 -and @($idleEvents | Where-Object { $_ -ceq 'idle-stop' }).Count -eq 0) "idle 401: the run log has exactly one idle-metrics-unauthorized event for the run of refused reads and no idle stop (saw: $($idleEvents -join ','))"
    Check (@(Get-RunLeaks $unauthorized).Count -eq 0) 'idle 401: no key or tail in any file or console line'

    # ================= the setting: settings -ApiKey on|off|rotate|show =================
    function Read-SettingsText([string]$Root) { $path = Join-Path $Root 'settings.json'; if (Test-Path -LiteralPath $path) { return [IO.File]::ReadAllText($path) }; return '' }
    $setRoot = New-Dir 'setting'
    $initial = Get-FastLlmServingSettings -InstallRoot $setRoot
    Check ([string]$initial.apiKey -ceq 'off' -and -not $initial.apiKeyUndetermined -and -not (Test-Path -LiteralPath (Join-Path $setRoot 'api-key.dat'))) 'setting: the default is off, with no key store'
    $on = Invoke-FastLlmApiKeySetting -InstallRoot $setRoot -Action on
    $settingsAfterOn = Read-SettingsText $setRoot
    Check ([string]$on.apiKey -ceq 'on' -and $on.created -eq $true -and [string]$on.apiKeyId -cmatch '\A[0-9a-f]{8}\z' -and [string](ConvertFrom-Json $settingsAfterOn).apiKey -ceq 'on') 'setting on: the flag apiKey "on" is saved and a key is created when there is none'
    Check (-not $on.PSObject.Properties['key'] -and (@($on.lines) -join ' ') -cmatch 'from the next start' -and (@($on.lines) -join ' ') -cnotmatch 'fl-[A-Za-z0-9_-]{43}') 'setting on: the answer says it applies at the next start and does not hold the key'
    $show = Invoke-FastLlmApiKeySetting -InstallRoot $setRoot -Action show
    Check ([string]$show.key -cmatch '\Afl-[A-Za-z0-9_-]{43}\z' -and [string]$show.apiKeyId -ceq [string]$on.apiKeyId -and @($show.lines).Count -eq 0) 'setting show: the key is returned only on that explicit request'
    Check ($settingsAfterOn.IndexOf([string]$show.key, [StringComparison]::Ordinal) -lt 0 -and $settingsAfterOn -cnotmatch 'fl-[A-Za-z0-9_-]{20}') 'setting on: settings.json holds the flag and never the key'
    $onAgain = Invoke-FastLlmApiKeySetting -InstallRoot $setRoot -Action on
    Check ($onAgain.created -eq $false -and [string]$onAgain.apiKeyId -ceq [string]$on.apiKeyId) 'setting on: turning it on again keeps the key'
    $off = Invoke-FastLlmApiKeySetting -InstallRoot $setRoot -Action off
    Check ([string]$off.apiKey -ceq 'off' -and (Read-SettingsText $setRoot) -cnotmatch 'apiKey' -and [string](Get-FastLlmServingSettings -InstallRoot $setRoot).apiKey -ceq 'off') 'setting off: the flag is removed from settings.json'
    Check ([string]$off.apiKeyId -ceq [string]$on.apiKeyId -and [string](Invoke-FastLlmApiKeySetting -InstallRoot $setRoot -Action on).apiKeyId -ceq [string]$on.apiKeyId) 'setting off: the stored key is kept, so off and on again does not change the key'
    $rotate = Invoke-FastLlmApiKeySetting -InstallRoot $setRoot -Action rotate
    $shownAfter = Invoke-FastLlmApiKeySetting -InstallRoot $setRoot -Action show
    Check ([string]$rotate.apiKeyId -cne [string]$on.apiKeyId -and [string]$rotate.apiKey -ceq 'on' -and [string]$shownAfter.key -cne [string]$show.key -and (@($rotate.lines) -join ' ') -cmatch 'next start') 'setting rotate: a new key replaces the stored one, the flag is unchanged, and it applies at the next start'
    Check ((Read-SettingsText $setRoot).IndexOf([string]$shownAfter.key, [StringComparison]::Ordinal) -lt 0) 'setting rotate: settings.json still never holds the key'
    $null = Invoke-FastLlmApiKeySetting -InstallRoot $setRoot -Action off
    $rotateOff = Invoke-FastLlmApiKeySetting -InstallRoot $setRoot -Action rotate
    Check ([string]$rotateOff.apiKey -ceq 'off' -and (@($rotateOff.lines) -join ' ') -cmatch 'setting is off') 'setting rotate: with the key off it creates the key and says the setting is off'
    # An unreadable store: on is refused and changes nothing; show is refused.
    [IO.File]::WriteAllBytes((Join-Path $setRoot 'api-key.dat'), [byte[]](9, 9, 9, 9, 9))
    $beforeRefusal = Read-SettingsText $setRoot
    Check ((Get-FailureCode { Invoke-FastLlmApiKeySetting -InstallRoot $setRoot -Action on }) -ceq 'api-key-unavailable' -and (Read-SettingsText $setRoot) -ceq $beforeRefusal -and (@([IO.File]::ReadAllBytes((Join-Path $setRoot 'api-key.dat'))) -join ',') -ceq '9,9,9,9,9') 'setting on: with an unreadable store it is refused (api-key-unavailable); the flag is not saved and no key is created'
    Check ((Get-FailureCode { Invoke-FastLlmApiKeySetting -InstallRoot $setRoot -Action show }) -ceq 'api-key-unavailable') 'setting show: an unreadable store is refused (api-key-unavailable)'
    # A settings file that cannot be read: refused before a key is created.
    $badRoot = New-Dir 'setting-malformed'
    Set-Content -LiteralPath (Join-Path $badRoot 'settings.json') -Value '{ not json' -Encoding ASCII
    $malformedFailure = Get-Failure { Invoke-FastLlmApiKeySetting -InstallRoot $badRoot -Action on }
    Check ($null -ne $malformedFailure -and [string]$malformedFailure.Exception.Message -clike 'serving-settings-malformed:*' -and -not (Test-Path -LiteralPath (Join-Path $badRoot 'api-key.dat'))) 'setting on: a malformed settings.json is refused before any key is created'
    Check (-not (Get-FastLlmServingSettings -InstallRoot $badRoot).apiKeyUndetermined -and [string](Get-FastLlmServingSettings -InstallRoot $badRoot).apiKey -ceq 'off') 'flag: a malformed settings.json with no key store reads as off, as before (no key was ever turned on here)'
    InModule { param($R, $K) Write-FastLlmApiKeyStore -InstallRoot $R -ApiKeyHolder $K } @($badRoot, $markerHolder)
    $undetermined = Get-FastLlmServingSettings -InstallRoot $badRoot
    Check ($undetermined.apiKeyUndetermined -eq $true -and $undetermined.malformed -eq $true) 'flag: a malformed settings.json next to a key store cannot be read as off: the flag is undetermined'
    foreach ($badValue in @('true', '"ON"', '"yes"', '1', '"On"', '{"a":1}')) {
        $valueRoot = New-Dir ('flag-' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
        Set-Content -LiteralPath (Join-Path $valueRoot 'settings.json') -Value ('{ "apiKey": ' + $badValue + ' }') -Encoding ASCII
        $read = Get-FastLlmServingSettings -InstallRoot $valueRoot
        Check ([string]$read.apiKey -ceq 'off' -and $read.apiKeyUndetermined -eq $true) "flag: a stored apiKey value of $badValue is neither on nor off: undetermined, never a silent off"
    }
    $offRoot = New-Dir 'flag-off'
    Set-Content -LiteralPath (Join-Path $offRoot 'settings.json') -Value '{ "apiKey": "off", "serverPort": 18181 }' -Encoding ASCII
    Check ([string](Get-FastLlmServingSettings -InstallRoot $offRoot).apiKey -ceq 'off' -and -not (Get-FastLlmServingSettings -InstallRoot $offRoot).apiKeyUndetermined) 'flag: the exact stored text off is off'
    Check ((Get-Failure { Set-FastLlmServingSettings -InstallRoot $offRoot -ApiKey 'ON' }).Exception.Message -clike 'serving-settings-invalid-apikey:*' -and (Get-Failure { Set-FastLlmServingSettings -InstallRoot $offRoot -ApiKey $marker }).Exception.Message -cnotmatch 'LEAKMARKER') 'flag: the setter takes only on or off, and does not echo what it was given'
    # Resolution: the saved setting only; -IgnoreUserSettings (the bench path) never uses a key.
    $null = Invoke-FastLlmApiKeySetting -InstallRoot $setRoot -Action rotate
    $null = Invoke-FastLlmApiKeySetting -InstallRoot $setRoot -Action on
    $resolved = Resolve-FastLlmServingOptions -InstallRoot $setRoot -Bound @{}
    $ignored = Resolve-FastLlmServingOptions -InstallRoot $setRoot -Bound @{} -IgnoreUserSettings
    Check ([string]$resolved.apiKey -ceq 'on' -and [string]$resolved.source -ceq 'settings' -and [string]$ignored.apiKey -ceq 'off' -and -not $ignored.apiKeyUndetermined) 'start: the flag comes from the saved setting, and -IgnoreUserSettings gives off'
    $ignoredBad = Resolve-FastLlmServingOptions -InstallRoot $badRoot -Bound @{} -IgnoreUserSettings
    Check ([string]$ignoredBad.apiKey -ceq 'off' -and -not $ignoredBad.apiKeyUndetermined -and (Resolve-FastLlmServingOptions -InstallRoot $badRoot -Bound @{}).apiKeyUndetermined) 'start: -IgnoreUserSettings never reads the flag; without it an undetermined flag is reported'
    $hostOn = Get-FastLlmServingHostArguments -InstallRoot $setRoot
    $hostOff = Get-FastLlmServingHostArguments -InstallRoot $offRoot
    Check ([string]$hostOn.UseApiKey -ceq 'on' -and (@($hostOff.Keys | Sort-Object) -join ',') -ceq 'ChatPage,IdleStopMinutes,ServerPort,Thinking') 'background and sign-in start: the host arguments carry UseApiKey on only when the key is on; without it they are the four they always were'
    Check ((Get-FailureCode { Get-FastLlmServingHostArguments -InstallRoot $badRoot }) -ceq 'api-key-setting-unreadable') 'background and sign-in start: an undetermined flag is the typed refusal api-key-setting-unreadable, never a start without the key'

    # ================= the command line =================
    $cliPath = Join-Path $root 'fast-llm.ps1'
    $cliCommand = Get-Command $cliPath
    Check ($cliCommand.ResolveParameter('ApiKey').Name -ceq 'KeyAction' -and $cliCommand.ResolveParameter('ApiK').Name -ceq 'KeyAction') 'command line: -ApiKey binds the key action'
    Check ($cliCommand.ResolveParameter('Api').Name -ceq 'ApiCheck' -and $cliCommand.ResolveParameter('ApiC').Name -ceq 'ApiCheck' -and $cliCommand.ResolveParameter('ApiCheck').Name -ceq 'ApiCheck') 'command line: -Api and -ApiC still bind -ApiCheck, as before'
    function Invoke-Cli([string[]]$Arguments) {
        $saved = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $text = (& (Get-Process -Id $PID).Path -NoLogo -NoProfile -NonInteractive -File $cliPath @Arguments 2>&1 | Out-String) } finally { $ErrorActionPreference = $saved }
        # .flat: one line, without colour codes and without the console's error frame, so a message is found however it was wrapped.
        $flat = [regex]::Replace(([regex]::Replace([string]$text, '\x1b\[[0-9;]*m', '')), '\s*[\r\n]+[\s|]*', ' ')
        return [pscustomobject]@{ text = [string]$text; flat = $flat; exit = $LASTEXITCODE }
    }
    $cliRoot = New-Dir 'cli'
    # fast-llm.ps1 refuses a live operation under an elevated token (the CI runner is elevated), so the child cases run for a standard user
    # only, as in start-tests. The same actions run in-process below on every host, with the real per-user protector on Windows.
    $cliChildrenElevated = $false
    if ($isWindowsHost) { $cliChildrenElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    if ($isWindowsHost) {
        # The real per-user protector (DPAPI), through the same action the command line and the window call.
        Set-Protector $null
        try {
            $realRoot = New-Dir 'dpapi'
            $realOn = Invoke-FastLlmApiKeySetting -InstallRoot $realRoot -Action on
            $realShow = Invoke-FastLlmApiKeySetting -InstallRoot $realRoot -Action show
            Check ($realOn.created -eq $true -and [string]$realOn.apiKey -ceq 'on' -and [string]$realShow.key -cmatch '\Afl-[A-Za-z0-9_-]{43}\z' -and [string]$realShow.apiKeyId -ceq [string]$realOn.apiKeyId) 'DPAPI (Windows): turning the key on creates a key this user can read back'
            $realBytes = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes((Join-Path $realRoot 'api-key.dat')))
            Check ($realBytes.IndexOf([string]$realShow.key, [StringComparison]::Ordinal) -lt 0 -and (Read-SettingsText $realRoot).IndexOf([string]$realShow.key, [StringComparison]::Ordinal) -lt 0) 'DPAPI (Windows): neither the store nor settings.json holds the key as text'
            $realRotate = Invoke-FastLlmApiKeySetting -InstallRoot $realRoot -Action rotate
            Check ([string]$realRotate.apiKeyId -cne [string]$realOn.apiKeyId -and [string](Invoke-FastLlmApiKeySetting -InstallRoot $realRoot -Action show).key -cne [string]$realShow.key) 'DPAPI (Windows): creating a new key replaces the stored key'
            $realHolder = InModule { param($R) Read-FastLlmApiKeyStore -InstallRoot $R } @($realRoot)
            Check ($realHolder -is [Security.SecureString] -and [string](InModule { param($K) Get-FastLlmApiKeyId -ApiKeyHolder $K } @(, $realHolder)) -ceq [string]$realRotate.apiKeyId) 'DPAPI (Windows): the start reads the same key from the store'
        }
        finally { Set-Protector $fakeProtector }
    }
    if ($cliChildrenElevated) { Write-Host 'SKIP: the command-line child cases (fast-llm.ps1 refuses a live operation under an elevated token; they run as a standard user).' }
    else {
    $refusedStart = Invoke-Cli @('plan', '-InstallRoot', $cliRoot, '-ApiKey', 'on')
    Check ($refusedStart.exit -ne 0 -and $refusedStart.flat -cmatch '-ApiKey is supported only by settings') 'command line: -ApiKey is a settings action only (no start, plan or install takes it)'
    $refusedJson = Invoke-Cli @('settings', '-InstallRoot', $cliRoot, '-ApiKey', 'show', '-AsJson')
    Check ($refusedJson.exit -ne 0 -and $refusedJson.flat -cmatch 'cannot be combined with -AsJson') 'command line: settings -ApiKey show is refused with -AsJson, so no JSON document ever holds the key'
    $cliOff = Invoke-Cli @('settings', '-InstallRoot', $cliRoot, '-ApiKey', 'off')
    Check ($cliOff.exit -eq 0 -and $cliOff.text -cmatch '(?m)^apiKey: off\s*$' -and $cliOff.flat -cmatch 'off from the next start') 'command line: settings -ApiKey off saves off and lists apiKey: off'
    if ($isWindowsHost) {
        # The real per-user protector (DPAPI) through the real command line.
        $cliOn = Invoke-Cli @('settings', '-InstallRoot', $cliRoot, '-ApiKey', 'on')
        Check ($cliOn.exit -eq 0 -and $cliOn.text -cmatch '(?m)^apiKey: on \(key id [0-9a-f]{8}\)\s*$' -and $cliOn.text -cnotmatch 'fl-[A-Za-z0-9_-]{43}') 'command line (Windows): settings -ApiKey on creates a key, lists the key id and does not print the key'
        $cliShow = Invoke-Cli @('settings', '-InstallRoot', $cliRoot, '-ApiKey', 'show')
        $shownLines = @($cliShow.text -split "`r?`n" | Where-Object { $_ })
        Check ($cliShow.exit -eq 0 -and $shownLines.Count -eq 1 -and $shownLines[0] -cmatch '\Afl-[A-Za-z0-9_-]{43}\z') 'command line (Windows): settings -ApiKey show prints the key and nothing else'
        $cliJson = Invoke-Cli @('settings', '-InstallRoot', $cliRoot, '-AsJson')
        $cliDocument = ConvertFrom-Json $cliJson.text
        Check ([string]$cliDocument.apiKey -ceq 'on' -and [string]$cliDocument.apiKeyId -cmatch '\A[0-9a-f]{8}\z' -and $cliJson.text.IndexOf($shownLines[0], [StringComparison]::Ordinal) -lt 0) 'command line (Windows): settings -AsJson reports apiKey on and the key id, never the key'
        $null = Invoke-Cli @('settings', '-InstallRoot', $cliRoot, '-ApiKey', 'rotate')
        $cliShowAfter = Invoke-Cli @('settings', '-InstallRoot', $cliRoot, '-ApiKey', 'show')
        Check ($cliShowAfter.exit -eq 0 -and ($cliShowAfter.text.Trim()) -cmatch '\Afl-[A-Za-z0-9_-]{43}\z' -and $cliShowAfter.text.Trim() -cne $shownLines[0]) 'command line (Windows): settings -ApiKey rotate replaces the key'
        $storeText = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes((Join-Path $cliRoot 'api-key.dat')))
        Check ($storeText.IndexOf($cliShowAfter.text.Trim(), [StringComparison]::Ordinal) -lt 0 -and (Read-SettingsText $cliRoot).IndexOf($cliShowAfter.text.Trim(), [StringComparison]::Ordinal) -lt 0) 'command line (Windows): neither the DPAPI store nor settings.json holds the key as text'
    }
    else {
        # No per-user protector here: on must be refused, and the flag must not be saved (never "on" without a usable key).
        $cliOn = Invoke-Cli @('settings', '-InstallRoot', $cliRoot, '-ApiKey', 'on')
        Check ($cliOn.exit -ne 0 -and $cliOn.flat -cmatch 'api-key-unavailable' -and (Read-SettingsText $cliRoot) -cnotmatch 'apiKey' -and -not (Test-Path -LiteralPath (Join-Path $cliRoot 'api-key.dat'))) 'command line: when the key cannot be protected for this user, settings -ApiKey on is refused and the flag is not saved'
        Write-Host 'SKIP: the real DPAPI flow (on, show, rotate) runs only on Windows.'
    }
    }
    $cliSource = [IO.File]::ReadAllText($cliPath)
    $startClause = $cliSource.Substring($cliSource.IndexOf("        'start' {"), $cliSource.IndexOf("        'doctor' {") - $cliSource.IndexOf("        'start' {"))
    Check ($startClause.IndexOf('Assert-FastLlmApiKeyStore -InstallRoot $InstallRoot') -gt 0 -and $startClause.IndexOf('Assert-FastLlmApiKeyStore -InstallRoot $InstallRoot') -lt $startClause.IndexOf('for ($planAttempt = 1') -and $startClause.IndexOf('New-FastLlmApiKeySettingFailure') -lt $startClause.IndexOf('for ($planAttempt = 1')) 'command line: a live start checks the flag and the store before the first hardware probe or plan'
    Check ($cliSource -cnotmatch 'Get-FastLlmPlan[^\r\n]*ApiKey' -and $cliSource -cnotmatch 'selectionOptions\.ApiKey') 'command line: nothing about the key is ever passed to the planner'

    # ================= Connect an app =================
    function New-ConnectStatus([string]$Phase = 'ready', [bool]$Active = $true, $KeyOn = $true, [string]$KeyId = '0123abcd') {
        $status = [pscustomobject]@{ phase = $Phase; active = $Active; runId = 'aabbccdd11223344aabbccdd11223344'; modelId = 'fastllm-test-model'; endpoint = 'http://127.0.0.1:8080/v1'
            recipe = [pscustomobject]@{ catalogVersion = '1'; contextSize = 32768; id = $null } }
        if ($KeyOn) { $status | Add-Member -NotePropertyMembers @{ apiKey = 'on'; apiKeyId = $KeyId } }
        return $status
    }
    $settingsOn = [pscustomobject]@{ serverPort = 8080; apiKey = 'on' }
    $settingsOff = [pscustomobject]@{ serverPort = 8080; apiKey = 'off' }
    $keyed = Get-FastLlmConnectionInfo -Status (New-ConnectStatus) -Settings $settingsOn
    Check ($keyed.apiKeyRequired -eq $true -and [string]$keyed.apiKey -ceq 'on' -and [string]$keyed.apiKeyId -ceq '0123abcd') 'connect: a ready server whose status says apiKey on gives apiKeyRequired with the key id'
    foreach ($client in $keyed.clients) {
        Check ($client.snippet.Contains('{KEY}') -and $client.snippet -cnotmatch 'any text|any-text|sets no key|needs no key' -and $client.snippet -cnotmatch 'fl-[A-Za-z0-9_-]{10}') "connect: the $($client.id) card carries the unresolved {KEY} token and no longer says any text works"
    }
    $card = @{}; foreach ($client in $keyed.clients) { $card[[string]$client.id] = [string]$client.snippet }
    Check ($card['openai-compatible'] -cmatch '(?m)^API key: \{KEY\}$' -and $card['cline-roo'] -cmatch '(?m)^API Key: \{KEY\}$') 'connect: the OpenAI-compatible and Cline / Roo Code cards put the key in their documented API key field'
    Check ($card['claude-code'].Contains('$env:ANTHROPIC_AUTH_TOKEN = "{KEY}"') -and $card['claude-code'].Contains('$env:ANTHROPIC_BASE_URL = "http://127.0.0.1:8080"')) 'connect: the Claude Code card puts the key in ANTHROPIC_AUTH_TOKEN (its documented variable)'
    Check ($card['codex'].Contains('env_key = "FASTLLM_API_KEY"') -and $card['codex'].Contains('$env:FASTLLM_API_KEY = "{KEY}"') -and $card['codex'].Contains('wire_api = "responses"')) 'connect: the Codex card names the key through env_key (its documented setting), not in the file'
    Check ($card['open-webui'] -cmatch 'names no key setting' -and $card['open-webui'] -cnotmatch 'Auth: None' -and $card['continue'] -cmatch 'names no key setting for this provider') 'connect: where a client page names no key setting, the card says so and gives the key as FastLLM''s own fact'
    $plainInfo = Get-FastLlmConnectionInfo -Status (New-ConnectStatus -KeyOn $false) -Settings $settingsOff
    Check ($plainInfo.apiKeyRequired -eq $false -and [string]$plainInfo.apiKey -ceq 'off' -and $null -eq $plainInfo.apiKeyId -and @($plainInfo.clients | Where-Object { $_.snippet.Contains('{KEY}') }).Count -eq 0 -and $plainInfo.clients[0].snippet.Contains("API key: any text (FastLLM's own fact: it sets no key, so any text works)")) 'connect: without the key the cards are the ones they always were'
    Check ([string](Get-FastLlmConnectionInfo -Status ([pscustomobject]@{ phase = 'stopped'; active = $false }) -Settings $settingsOn).apiKey -ceq 'on-at-next-start' -and (Get-FastLlmConnectionInfo -Status ([pscustomobject]@{ phase = 'stopped'; active = $false }) -Settings $settingsOn).apiKeyRequired) 'connect: nothing running and the setting on: the cards carry the key for the next start, and it is not called on'
    Check ([string](Get-FastLlmConnectionInfo -Status (New-ConnectStatus -Phase 'loading' -KeyOn $false) -Settings $settingsOn).apiKey -ceq 'starting') 'connect: a start in progress with the setting on is starting, not on (nothing is proved yet) and not off'
    $readyNoKey = Get-FastLlmConnectionInfo -Status (New-ConnectStatus -KeyOn $false) -Settings $settingsOn
    Check ($readyNoKey.apiKeyRequired -eq $false -and [string]$readyNoKey.apiKey -ceq 'off') 'connect: a ready server that was started without the key is not called keyed because the setting is on now'
    Check ((Get-FastLlmConnectionInfo -Status (New-ConnectStatus) -Settings $settingsOff).apiKeyRequired -eq $true) 'connect: a ready server that proved the key stays keyed after the setting is turned off (until it stops)'
    Check ($null -eq (Get-FastLlmConnectionInfo -Status (New-ConnectStatus -KeyId ('fl-' + 'x' * 43)) -Settings $settingsOn).apiKeyId -and $null -eq (Get-FastLlmConnectionInfo -Status (New-ConnectStatus -KeyId 'ZZZZZZZZ') -Settings $settingsOn).apiKeyId) 'connect: a status key id that is not 8 hex characters is not passed on'
    # The connection info of an installation that HAS a key (the marker) never holds it: status, -AsJson and the support bundle cannot leak it.
    $connectRoot = New-Dir 'connect'
    InModule { param($R, $K) Write-FastLlmApiKeyStore -InstallRoot $R -ApiKeyHolder $K } @($connectRoot, $markerHolder)
    Set-FastLlmServingSettings -InstallRoot $connectRoot -ApiKey 'on'
    $connectJson = (Get-FastLlmConnectionInfo -Status (New-ConnectStatus -KeyId $markerId) -InstallRoot $connectRoot) | ConvertTo-Json -Depth 12
    Check ((Test-NoLeak $connectJson) -and $connectJson.Contains('{KEY}') -and $connectJson -cnotmatch 'fl-[A-Za-z0-9_-]{20}') 'connect: the connection info of an installation with a stored key serializes with the {KEY} token and without the key'
    $parameters = @((Get-Command Get-FastLlmConnectionInfo).Parameters.Keys | Where-Object { $_ -cin @('Status', 'InstallRoot', 'Settings') })
    Check ($parameters.Count -eq 3 -and @((Get-Command Get-FastLlmConnectionInfo).Parameters.Keys | Where-Object { $_ -cmatch 'Key' }).Count -eq 0) 'connect: the connection info takes a status, an install root and settings: no parameter can hand it a key'
    $shownCard = Get-FastLlmConnectDisplayText -Snippet $card['claude-code']
    Check ($shownCard.Contains('$env:ANTHROPIC_AUTH_TOKEN = "<your FastLLM key>"') -and -not $shownCard.Contains('{KEY}')) 'connect: on screen a card shows <your FastLLM key> where the key goes'
    $copiedCard = Get-FastLlmConnectCopyText -Snippet $card['claude-code'] -Key $marker
    Check ($copiedCard.Contains('$env:ANTHROPIC_AUTH_TOKEN = "' + $marker + '"') -and -not $copiedCard.Contains('{KEY}') -and -not $copiedCard.Contains('<your FastLLM key>')) 'connect: a card''s Copy puts the real key in'
    foreach ($unusable in @($null, '', 'fl-short', ($marker + 'x'), $markerHolder)) {
        $fallback = Get-FastLlmConnectCopyText -Snippet $card['claude-code'] -Key $unusable
        Check ($fallback -ceq $shownCard) 'connect: a card copied without a usable key copies the placeholder, never a partial or malformed key'
    }

    # ---- doctor -ApiCheck ----
    $apiCheck401 = Invoke-FastLlmApiCheck -BaseUrl 'http://127.0.0.1:8080/v1' -ModelName 'm' -Request { param($Root, $Path, $Body, $TimeoutMs) return [pscustomobject]@{ Status = 401; Body = '{"error":{"message":"Invalid API Key"}}'; ElapsedMs = 1.0 } }
    Check (@($apiCheck401.checks | Where-Object { [string]$_.status -ceq 'unauthorized' -and $_.httpStatus -eq 401 }).Count -eq 3) 'api check: a 401 is its own result (unauthorized), not a failed format'
    $mixedCalls = 0
    $apiCheckMixed = Invoke-FastLlmApiCheck -BaseUrl 'http://127.0.0.1:8080/v1' -ModelName 'm' -Request { param($Root, $Path, $Body, $TimeoutMs) if ($Path -ceq '/v1/messages') { return [pscustomobject]@{ Status = 500; Body = '{}'; ElapsedMs = 1.0 } }; return [pscustomobject]@{ Status = 401; Body = '{}'; ElapsedMs = 1.0 } }
    Check ((@($apiCheckMixed.checks | ForEach-Object { [string]$_.status }) -join ',') -ceq 'unauthorized,fail,unauthorized') 'api check: any other failure stays fail'
    $doctorRoot = New-Dir 'doctor'
    $doctorStatus = New-ConnectStatus -KeyId $markerId
    $doctorMissing = Invoke-FastLlmDoctorApiCheck -InstallRoot $doctorRoot -Status $doctorStatus
    Check ($doctorMissing.exitCode -eq 2 -and [string]$doctorMissing.message -clike 'api-key-unavailable:*' -and $null -eq $doctorMissing.result) 'api check: the server requires the key and the store cannot be read: the check is not run (api-key-unavailable)'
    $doctorUnauthorized = Invoke-FastLlmDoctorApiCheck -InstallRoot $doctorRoot -Status $doctorStatus -Request { param($Root, $Path, $Body, $TimeoutMs) return [pscustomobject]@{ Status = 401; Body = '{}'; ElapsedMs = 1.0 } }
    Check ($doctorUnauthorized.exitCode -eq 1 -and [string]$doctorUnauthorized.result.note -cmatch 'restart FastLLM' -and (Format-FastLlmApiCheckTable -Result $doctorUnauthorized.result) -cmatch 'UNAUTHORIZED HTTP 401') 'api check: the report and the window table say unauthorized, with the hint to restart after a new key'
    # The real path: doctor reads the store inside the module and sends the key only to the server process the status records.
    InModule { param($R, $K) Write-FastLlmApiKeyStore -InstallRoot $R -ApiKeyHolder $K } @($doctorRoot, $markerHolder)
    $doctorRecorder = New-Object FlApiKeyWiringRecorder
    $doctorSleeper = $null
    try {
        $liveStatus = New-ConnectStatus -KeyId $markerId
        $liveStatus.endpoint = "http://127.0.0.1:$($doctorRecorder.Port)/v1"
        $liveStatus | Add-Member -NotePropertyName processIdentity -NotePropertyValue (Get-Identity $PID)
        $doctorRun = Invoke-FastLlmDoctorApiCheck -InstallRoot $doctorRoot -Status $liveStatus
        $doctorSeen = @($doctorRecorder.Snapshot())
        Check ($doctorSeen.Count -eq 3 -and @($doctorSeen | Where-Object { $_ -cmatch ('(?im)^authorization: Bearer ' + [regex]::Escape($marker) + '\r?$') }).Count -eq 3) 'api check: with the key on, all three format requests carry the stored key'
        Check ((Test-NoLeak ($doctorRun | ConvertTo-Json -Depth 8)) -and (@(Find-LeakFiles @((Join-Path $doctorRoot 'state'))).Count -eq 0)) 'api check: neither the report nor the run-log events hold the key'
        $doctorSleeper = New-Object Diagnostics.Process
        $doctorSleeper.StartInfo.FileName = (Get-Process -Id $PID).Path
        $doctorSleeper.StartInfo.Arguments = '-NoLogo -NoProfile -Command "Start-Sleep -Seconds 600"'
        $doctorSleeper.StartInfo.UseShellExecute = $false
        [void]$doctorSleeper.Start()
        $liveStatus.processIdentity = Get-Identity $doctorSleeper.Id
        $connectionsBefore = $doctorRecorder.Connections
        $doctorForeign = Invoke-FastLlmDoctorApiCheck -InstallRoot $doctorRoot -Status $liveStatus
        Start-Sleep -Milliseconds 200
        Check ($doctorRecorder.Connections -eq $connectionsBefore -and @($doctorForeign.result.checks | Where-Object { [string]$_.status -ceq 'fail' -and $null -eq $_.httpStatus }).Count -eq 3 -and $doctorForeign.exitCode -eq 1) 'W4: the API check does not send the key when the port belongs to another program than the server the status records'
    }
    finally {
        $doctorRecorder.Dispose()
        if ($doctorSleeper) { try { if (-not $doctorSleeper.HasExited) { $doctorSleeper.Kill() } } catch { $null = $_ }; $doctorSleeper.Dispose() }
    }

    # ================= the window (its pure parts) =================
    $readyState = [pscustomobject]@{ phase = 'ready'; active = $true; apiKey = 'on'; apiKeyId = '0123abcd' }
    $plainState = [pscustomobject]@{ phase = 'ready'; active = $true }
    $sameStore = [pscustomobject]@{ exists = $true; available = $true; apiKeyId = '0123abcd' }
    $newStore = [pscustomobject]@{ exists = $true; available = $true; apiKeyId = 'ffff0000' }
    $lostStore = [pscustomobject]@{ exists = $true; available = $false; apiKeyId = $null }
    Check ((Get-FastLlmUiApiKeyStatusText -State $readyState -ApiKeyStore $sameStore) -ceq 'API key on.' -and (Get-FastLlmUiApiKeyStatusText -State $readyState -ApiKeyStore $null) -ceq 'API key on.') 'window: the status says the key is on when the running server proved it'
    Check ((Get-FastLlmUiApiKeyStatusText -State $plainState -ApiKeyStore $sameStore) -ceq '' -and (Get-FastLlmUiApiKeyStatusText -State ([pscustomobject]@{ phase = 'loading'; active = $true }) -ApiKeyStore $sameStore) -ceq '' -and (Get-FastLlmUiApiKeyStatusText -State ([pscustomobject]@{ apiKey = 'ON' }) -ApiKeyStore $null) -ceq '') 'window: without the proof in the status nothing says the key is on (a stored key or the setting alone is not enough)'
    Check ((Get-FastLlmUiApiKeyStatusText -State $readyState -ApiKeyStore $newStore) -cmatch 'restart to use the new key') 'window: when the stored key id differs from the running one it says restart to use the new key'
    Check ((Get-FastLlmUiApiKeyStatusText -State $readyState -ApiKeyStore $lostStore) -cmatch 'cannot be read') 'window: a running key whose store cannot be read is said so'
    Check ((Format-FastLlmUiReadyStatus -State $plainState) -ceq 'Ready - API smoke tests passed; GPU residency/performance unqualified.' -and (Format-FastLlmUiReadyStatus -State $plainState -ApiKeyStore $newStore) -ceq (Format-FastLlmUiReadyStatus -State $plainState)) 'window: the Ready line of a start without the key is the line it always was'
    Check ((Format-FastLlmUiReadyStatus -State $readyState -ApiKeyStore $sameStore) -ceq 'Ready - API smoke tests passed; GPU residency/performance unqualified. API key on.' -and (Format-FastLlmUiBackgroundReadyStatus -Text 'Ready.' -State $readyState -ApiKeyStore $newStore) -cmatch 'restart to use the new key') 'window: the Ready lines (foreground and background) carry the key sentence'
    Check ((Test-FastLlmUiApiKeyFailure -Code 'api-key-unavailable') -and (Test-FastLlmUiApiKeyFailure -Code 'api-key-not-enforced') -and (Test-FastLlmUiApiKeyFailure -Code 'api-key-setting-unreadable') -and -not (Test-FastLlmUiApiKeyFailure -Code 'self-test-failed') -and -not (Test-FastLlmUiApiKeyFailure -Code '') -and -not (Test-FastLlmUiApiKeyFailure -Code 'api-key-UNAVAILABLE')) 'window: an api-key failure code is recognised as typed (shown as its own message, never retried)'
    $offers = @('api-key-unavailable', 'api-key-not-enforced', 'api-key-listener-not-verified', 'api-key-setting-unreadable', 'api-key-invalid', 'api-key-other') | ForEach-Object { (Get-FastLlmUiApiKeyFailure -Code $_) }
    Check ((@($offers | Where-Object { $_.offerNewKey } | ForEach-Object { $_.code }) -join ',') -ceq 'api-key-unavailable,api-key-invalid' -and @($offers | Where-Object { [string]::IsNullOrWhiteSpace($_.text) }).Count -eq 0) 'window: Create a new key is offered exactly when the stored key cannot be used; every code has a plain text'
    Check ((Get-FastLlmUiApiKeyFailure -Code 'api-key-unavailable').text -cmatch 'does not start without the key' -and (Get-FastLlmUiNewKeyConfirmText -HasReadableKey $true) -cmatch 'current key stops working' -and (Get-FastLlmUiNewKeyConfirmText -HasReadableKey $false) -cmatch 'cannot be read') 'window: the refusal says FastLLM does not start without the key, and creating a key is asked first'
    $rowOn = Get-FastLlmUiApiKeyRow -Info $keyed -Settings $settingsOn -ApiKeyStore $sameStore
    Check ($rowOn.visible -and [string]$rowOn.mask -ceq '********' -and $rowOn.canShow -and [string]$rowOn.note -ceq 'This server requires the API key.') 'window: Connect an app shows API key: ******** with Show and Copy when the server requires the key'
    Check ((Get-FastLlmUiApiKeyRow -Info $keyed -Settings $settingsOn -ApiKeyStore $newStore).note -cmatch 'restart to use the new key' -and -not (Get-FastLlmUiApiKeyRow -Info $keyed -Settings $settingsOn -ApiKeyStore $lostStore).canShow) 'window: the key row says restart after a new key, and offers no Show or Copy when the store cannot be read'
    $rowOff = Get-FastLlmUiApiKeyRow -Info $plainInfo -Settings $settingsOff -ApiKeyStore $sameStore
    $rowLater = Get-FastLlmUiApiKeyRow -Info $readyNoKey -Settings $settingsOn -ApiKeyStore $sameStore
    Check (-not $rowOff.visible -and [string]$rowOff.note -ceq '' -and -not $rowLater.visible -and [string]$rowLater.note -cmatch 'started without it') 'window: no key row without a key; a server started before the setting was turned on says restart to use the key'
    $requestOn = New-FastLlmUiBackgroundRequest -SourceRoot $root -InstallRoot $root -ModelId 'm' -ContextSize 1 -BarMitigation 'auto' -Settings ([pscustomobject]@{ serverPort = 8080; apiKey = 'on'; apiKeyUndetermined = $false })
    $requestOff = New-FastLlmUiBackgroundRequest -SourceRoot $root -InstallRoot $root -ModelId 'm' -ContextSize 1 -BarMitigation 'auto' -Settings ([pscustomobject]@{ serverPort = 8080 })
    Check ([string]$requestOn.apiKey -ceq 'on' -and [string]$requestOff.apiKey -ceq 'off' -and [string](New-FastLlmUiBackgroundRequest -SourceRoot $root -InstallRoot $root -ModelId 'm' -ContextSize 1 -BarMitigation 'auto' -Settings ([pscustomobject]@{ apiKey = 'yes' })).apiKey -ceq 'off') 'window: the background request carries only the flag apiKey on or off'
    Check ((Get-FailureCode { New-FastLlmUiBackgroundRequest -SourceRoot $root -InstallRoot $root -ModelId 'm' -ContextSize 1 -BarMitigation 'auto' -Settings ([pscustomobject]@{ apiKey = 'off'; apiKeyUndetermined = $true }) }) -ceq 'api-key-setting-unreadable') 'window: a background start with an undetermined flag is refused (api-key-setting-unreadable)'
    Check ((@($requestOn.PSObject.Properties.Name) -join ',') -cnotmatch '(?i)holder|secret|bearer' -and (($requestOn | ConvertTo-Json -Depth 4) -cnotmatch 'fl-')) 'window: the background request has no field that could hold a key'
    $noteBefore = [pscustomobject]@{ serverPort = 8080; thinking = 'auto'; chatPage = 'off'; idleStopMinutes = 0; apiKey = 'off' }
    Check ((Get-FastLlmUiSettingsSavedNote -RunActive $true -Before $noteBefore -After ([pscustomobject]@{ serverPort = 8080; thinking = 'auto'; chatPage = 'off'; idleStopMinutes = 0; apiKey = 'on' })) -ceq 'The new API key setting applies at the next start.' -and (Get-FastLlmUiSettingsSavedNote -RunActive $true -Before $noteBefore -After ([pscustomobject]@{ serverPort = 8080; thinking = 'auto'; chatPage = 'off'; idleStopMinutes = 0 })) -ceq 'Settings saved.') 'window: a changed API key setting during a run says it applies at the next start'
    $uiSource = [IO.File]::ReadAllText((Join-Path $root 'fast-llm-ui.ps1'))
    Check ($uiSource.Contains("'Require an API key (off by default)'") -and $uiSource.Contains("Invoke-FastLlmApiKeySetting -InstallRoot `$script:installPath -Action on") -and $uiSource.Contains("Invoke-FastLlmApiKeySetting -InstallRoot `$script:installPath -Action off")) 'window: Settings has the Require an API key box and saves it through the same action as the command line'
    Check ($uiSource.Contains("'Create a new key'") -and $uiSource.Contains('Get-FastLlmUiNewKeyConfirmText') -and @([regex]::Matches($uiSource, '-Action rotate')).Count -eq 1) 'window: Create a new key is one action, asked before it runs'
    Check ($uiSource.Contains('$copy.Tag=[string]$client.snippet') -and $uiSource.Contains('Get-FastLlmConnectCopyText -Snippet ([string]$sender.Tag) -Key $cardKey') -and $uiSource.Contains('$snippetBox.Text=(Get-FastLlmConnectDisplayText -Snippet ([string]$client.snippet))')) 'window: a card shows the placeholder, keeps only the {KEY} token, and reads the key at the moment of its Copy'
    Check ($uiSource -cnotmatch '\.Tag\s*=[^;\r\n]*(ReadUiApiKey|Get-FastLlmApiKeyForDisplay)' -and $uiSource -cnotmatch '\$script:[A-Za-z]*\s*=\s*\(?\s*(ReadUiApiKey|Get-FastLlmApiKeyForDisplay)') 'window: the key is never kept in a control tag or a window-wide variable'
    $apiKeyFailureAt = $uiSource.IndexOf('if(Test-FastLlmUiApiKeyFailure -Code $failureCode){')
    $retryAt = $uiSource.IndexOf("`$script:flow=Move-FastLlmUiFlow -Flow `$script:flow -Event 'serving-failed'")
    Check ($apiKeyFailureAt -gt 0 -and $retryAt -gt $apiKeyFailureAt) 'window: an API key failure is handled before the retry path of a failed start (it is never retried)'
    Check ($uiSource.Contains('-IdleStopMinutes $IdleStop -UseApiKey $KeyFlag -NoWait') -and $uiSource.Contains('$Request.idleStopMinutes $Request.apiKey')) 'window: Start in background hands the flag to the background host'
    $backgroundText = . { . (Join-Path $root 'src/FastLlm.UiBackground.ps1'); $bgState = New-FastLlmUiBackgroundState; $bgState.observation = [pscustomobject]@{ occupied = $false; phase = 'stale'; requestId = ('a' * 32); failureCode = 'api-key-unavailable'; failureReason = 'x'; attachable = $false }; Get-FastLlmUiBackgroundText -State $bgState }
    Check ([string]$backgroundText -cmatch 'stored key cannot be read' -and [string]$backgroundText -cmatch 'Create a new key') 'window: a background run that ended on api-key-unavailable says so and names the action'

    # ================= the background host =================
    $hostSource = [IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.BackgroundHost.ps1'))
    Check ($hostSource.Contains("if (`$UseApiKey -ceq 'on') { `$request.apiKey = 'on' }") -and $hostSource -cnotmatch 'request\.[A-Za-z]*[Kk]ey\s*=(?!\s*''on'')' -and $hostSource.Contains("[ValidateSet('off','on')][string]`$UseApiKey='off'")) 'background: the request file carries only apiKey on, and only when the key is on'
    Check ($hostSource.Contains("if (`$UseApiKey -ceq 'on') { Assert-FastLlmApiKeyStore -InstallRoot `$install }") -and $hostSource.IndexOf('Assert-FastLlmApiKeyStore -InstallRoot $install') -lt $hostSource.IndexOf('Write-FastLlmBackgroundDocument -Path $requestPath -Value $request -CreateNew')) 'background: a store that cannot be read is refused before the request is written or the host is started'
    Check ($hostSource.Contains("throw 'Background request apiKey is invalid.'") -and $hostSource.Contains("if (`$requestedApiKey -ceq 'on') { `$serverOptions.ApiKey = 'on' }") -and $hostSource -cnotmatch 'Read-FastLlmApiKeyStore|Get-FastLlmApiKeyForDisplay|ApiKeyHolder') 'background: the host reads the flag strictly and passes only the flag on; the store is read inside the start, in the host process'
    Check ($hostSource.Contains('$failureText = ConvertTo-FastLlmKeyFreeText -Text $failureText') -and $hostSource.IndexOf('$failureText = ConvertTo-FastLlmKeyFreeText -Text $failureText') -lt $hostSource.IndexOf('$record.failureReason = ')) 'W2: the failure text of the background record passes the scrub before it is recorded'
    # The host's reading of the flag. The whole host path with the flag (and the start it hands it to) is exercised in
    # tests/background-host-tests.ps1 (api-key-rides-the-request).
    . (Join-Path $root 'src/FastLlm.BackgroundHost.ps1')
    Check ((Get-FastLlmBackgroundRequestApiKey -Request ([pscustomobject]@{ a = 1 })) -ceq 'off' -and (Get-FastLlmBackgroundRequestApiKey -Request ([pscustomobject]@{ apiKey = 'off' })) -ceq 'off' -and (Get-FastLlmBackgroundRequestApiKey -Request ([pscustomobject]@{ apiKey = 'on' })) -ceq 'on') 'background: a request without the field, or with off, starts without a key; on starts with it'
    foreach ($odd in @('ON', 'yes', $true, 1, '', $null, $marker)) {
        $oddFailure = Get-Failure { Get-FastLlmBackgroundRequestApiKey -Request ([pscustomobject]@{ apiKey = $odd }) }
        Check ($null -ne $oddFailure -and [string]$oddFailure.Exception.Message -ceq 'Background request apiKey is invalid.') "background: an apiKey value of '$(if ($odd -is [string] -and $odd.Length -gt 8) { 'a long text' } else { [string]$odd })' in a request is refused, never read as off"
    }
    Check ($hostSource.Contains('$requestedApiKey = Get-FastLlmBackgroundRequestApiKey -Request $request') -and $hostSource.IndexOf('$requestedApiKey = Get-FastLlmBackgroundRequestApiKey -Request $request') -lt $hostSource.IndexOf('$operation = Enter-FastLlmOperation -InstallRoot $install')) 'background: the host reads the flag before it takes the lock or starts anything'
    # W2: a background document (the host record, with its failure text) passes the scrub on its way to disk.
    $documentRoot = New-Dir 'background-document'
    New-Item -ItemType Directory -Path (Join-Path $documentRoot 'state') -Force | Out-Null
    $documentPath = Join-Path $documentRoot 'state/background-host.json'
    . { . (Join-Path $root 'src/FastLlm.BackgroundHost.ps1'); Write-FastLlmBackgroundDocument -Path $documentPath -Value ([ordered]@{ schemaVersion = 1; kind = 'fastllm-private-background-host'; phase = 'failed'; failureCode = 'x'; failureReason = "the server said $marker" }) }
    $documentText = [IO.File]::ReadAllText($documentPath)
    Check ((Test-NoLeak $documentText) -and [string](ConvertFrom-Json $documentText).failureReason -ceq 'the server said <api-key>' -and [string](ConvertFrom-Json $documentText).phase -ceq 'failed') 'W2: a background host document never reaches disk with a key in it, and stays valid JSON'

    # ================= the support bundle =================
    $bundleRoot = New-Dir 'bundle'
    InModule { param($R, $K) Write-FastLlmApiKeyStore -InstallRoot $R -ApiKeyHolder $K } @($bundleRoot, $markerHolder)
    Set-FastLlmServingSettings -InstallRoot $bundleRoot -ApiKey 'on'
    $bundleZip = Join-Path $temp 'bundle-with-key.zip'
    $bundleListing = New-FastLlmSupportBundle -InstallRoot $bundleRoot -AppRoot $root -OutputPath $bundleZip -Doctor ([ordered]@{ installRoot = $bundleRoot; error = "a report that quotes the key $marker" })
    $bundleOut = Join-Path $temp 'bundle-with-key'
    [IO.Compression.ZipFile]::ExtractToDirectory($bundleZip, $bundleOut)
    Check ($bundleListing.saved -and @(Find-LeakFiles @($bundleOut)).Count -eq 0 -and [int]$bundleListing.redactions -ge 1) 'support bundle: a key quoted in the doctor report is replaced, and counted as a redaction'
    Check (@($bundleListing.entries | Where-Object { [string]$_.name -match 'api-key' }).Count -eq 0 -and [string](ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $bundleOut 'settings.json')))).apiKey -ceq 'on' -and [string](ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $bundleOut 'doctor.json')))).error -ceq 'a report that quotes the key <api-key>') 'support bundle: it reports the flag apiKey on, and never includes the key store'
}
finally {
    Set-Protector $null
    Set-ListenerOwners $null
    & $module { $script:FastLlmIdlePollSeconds = 30 }
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "api-key-wiring-tests: $($script:count) checks passed"
