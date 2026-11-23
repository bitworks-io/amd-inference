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
. (Join-Path $PSScriptRoot 'helpers/module-log-tap.ps1')
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
function Get-SourceTree([string]$RelativePath) {
    $parseErrors = $null; $parseTokens = $null
    $tree = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $RelativePath), [ref]$parseTokens, [ref]$parseErrors)
    if (@($parseErrors).Count -ne 0) { throw "$RelativePath does not parse" }
    return $tree
}
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
    # The engine-surface fixtures record the log label(s) llama-server prints key material under, one list per audited tag. Every recorded
    # label, shaped like the engine's own line, must be dropped by the filter: a renamed label then fails here, not in a capture.
    function Get-UnfilteredSecretLabels($Fixtures) {
        $missed = New-Object System.Collections.Generic.List[string]
        foreach ($fixture in $Fixtures) {
            if ($null -eq $fixture.PSObject.Properties['secretLogLabels']) { $missed.Add($fixture.tag + ' :: no secretLogLabels'); continue }
            if (@($fixture.secretLogLabels).Count -eq 0) { $missed.Add($fixture.tag + ' :: empty secretLogLabels'); continue }
            foreach ($label in @($fixture.secretLogLabels)) {
                if (-not [Bitworks.FastLlm.ProcessHost]::IsSecretLine("0.00.123.456 I srv          main: ${label}: ****abcd", $null)) { $missed.Add($fixture.tag + ' :: ' + $label) }
            }
        }
        return , $missed.ToArray()
    }
    $surfaceFixtures = @(Get-ChildItem -LiteralPath (Join-Path $root 'tests/fixtures') -Filter 'engine-surface-b*.json' | Sort-Object Name | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json })
    Check ($surfaceFixtures.Count -ge 3) 'W1: the engine-surface fixtures are found (one per audited tag)'
    $unfiltered = Get-UnfilteredSecretLabels $surfaceFixtures
    Check ($unfiltered.Count -eq 0) ('W1: every secret log label recorded in every engine-surface fixture is a secret line (missed: ' + ($unfiltered -join ', ') + ')')
    # Mutation proof, kept permanent: a copy of a fixture (never the committed one) with a made-up label must be reported as missed.
    $mutated = ($surfaceFixtures[0] | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
    $mutated.secretLogLabels = @($mutated.secretLogLabels) + @('key_list')
    $mutatedMissed = Get-UnfilteredSecretLabels @($mutated)
    Check ($mutatedMissed.Count -eq 1 -and $mutatedMissed[0] -eq ($mutated.tag + ' :: key_list')) 'W1: a made-up label in a test copy of a fixture is reported as not filtered (mutation proof)'
    $noField = ($surfaceFixtures[0] | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
    $noField.PSObject.Properties.Remove('secretLogLabels')
    Check ((Get-UnfilteredSecretLabels @($noField)).Count -eq 1) 'W1: a fixture without secretLogLabels is reported, not passed'
    $emptyField = ($surfaceFixtures[0] | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
    $emptyField.secretLogLabels = @()
    $emptyMissed = Get-UnfilteredSecretLabels @($emptyField)
    Check ($emptyMissed.Count -eq 1 -and $emptyMissed[0] -eq ($emptyField.tag + ' :: empty secretLogLabels')) 'W1: a fixture with an empty secretLogLabels list is reported, not passed'
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
    # The scrub takes its text inside a [ref] (M2): what it is given has not been scrubbed yet, so it is never a plain parameter value.
    function Scrub([string]$Text, $Holder = $null, [switch]$Structured) { return [string](InModule { param($T, $H, $S) ConvertTo-FastLlmKeyFreeText -Text ([ref]$T) -ApiKeyHolder $H -Structured:$S } @($Text, $Holder, [bool]$Structured)) }
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
    Check ((Get-FailureCode { InModule { param($T) ConvertTo-FastLlmKeyFreeText -Text ([ref]$T) -ApiKeyHolder 'not a holder' } @("x $marker y") }) -ceq 'none' -and (Scrub "x $marker y" 'not a holder') -ceq 'x <api-key> y') 'W2: the scrub never throws, also when the holder is not usable'
    $scrubInput = "kept as it was: $marker"
    $scrubOutput = [string](InModule { param($R) ConvertTo-FastLlmKeyFreeText -Text $R } @(, ([ref]$scrubInput)))
    Check ($scrubOutput -ceq 'kept as it was: <api-key>' -and $scrubInput -ceq "kept as it was: $marker") 'W2: the scrub returns the scrubbed text and leaves the referenced variable as it was'
    $notText = 12345
    $nothingToScrub = $null
    Check ([string](InModule { param($R) ConvertTo-FastLlmKeyFreeText -Text $R } @(, ([ref]$notText))) -ceq '<text removed: it could not be checked for the API key>' -and [string](InModule { param($R) ConvertTo-FastLlmKeyFreeText -Text $R -Structured } @(, ([ref]$notText))) -ceq '{}' -and [string](InModule { param($R) ConvertTo-FastLlmKeyFreeText -Text $R } @(, ([ref]$nothingToScrub))) -ceq '') 'W2: a reference to something that is not text is replaced whole, and a reference to nothing is empty'
    Check ((Get-Failure { InModule { param($T) ConvertTo-FastLlmKeyFreeText -Text $T } @("plain $marker") }) -ne $null -and (Test-NoLeak (Get-FailureText (Get-Failure { InModule { param($T) ConvertTo-FastLlmKeyFreeText -Text $T } @("plain $marker") })))) 'W2: a plain string is not accepted as the text (it would be logged), and the refusal does not echo it'

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

        # ---- L1: the check and the request are two steps, so the same check runs again once the request is over ----
        $script:ownerCalls = 0
        Set-ListenerOwners { param($Port) $script:ownerCalls++; return @($PID) }
        $twice = Send-Keyed $own
        Check ($twice.Status -eq 200 -and $script:ownerCalls -eq 2) 'L1: a keyed request checks the listener twice: before it is sent and again after the answer'
        # The right owner before the request, another one after it: the key may have gone to that other program.
        $connectionsBefore = $recorder.Connections
        $script:ownerCalls = 0
        Set-ListenerOwners { param($Port) $script:ownerCalls++; if ($script:ownerCalls -eq 1) { return @($PID) }; return @(4242) }
        $changed = Get-Failure { Send-Keyed $own }
        Check ($null -ne $changed -and [string]$changed.Exception.Data['FastLlmFailureCode'] -ceq 'api-key-listener-changed' -and [string]$changed.Exception.Data['FastLlmReason'] -ceq 'ApiKeyFailed' -and $script:ownerCalls -eq 2 -and $recorder.Connections -eq ($connectionsBefore + 1)) 'L1: the right owner before the request and another one after it is the typed failure api-key-listener-changed (never retried)'
        Check ([string]$changed.Exception.Message -cmatch 'Another program may have received the key' -and [string]$changed.Exception.Message -cmatch 'Create a new key' -and [string]$changed.Exception.Message -cmatch 'settings -ApiKey rotate' -and (Test-NoLeak (Get-FailureText $changed))) 'L1: the failure says another program may have received the key and to create a new key, without any key text'
        # Answered, and afterwards nothing listens or a second listener is there: whoever answered cannot be confirmed. Those answers are
        # definite, so the table is read once after the request.
        foreach ($after in @(@{ label = 'nothing listens'; owners = { @() } }, @{ label = 'a second listener is there'; owners = { @($PID, 4242) } })) {
            $script:ownerCalls = 0; $script:ownersAfter = $after.owners
            Set-ListenerOwners { param($Port) $script:ownerCalls++; if ($script:ownerCalls -eq 1) { return @($PID) }; return @(& $script:ownersAfter) }
            $afterFailure = Get-Failure { Send-Keyed $own }
            Check ($null -ne $afterFailure -and [string]$afterFailure.Exception.Data['FastLlmFailureCode'] -ceq 'api-key-listener-changed' -and $script:ownerCalls -eq 2 -and (Test-NoLeak (Get-FailureText $afterFailure))) "L1: an answered request after which $($after.label) is api-key-listener-changed (one read after the request)"
        }
        # A listener table that cannot be read is not a definite answer: it is read again, up to twice. One failed read (or two) followed by
        # the right owner raises no alarm; a table that still cannot be read after that does.
        foreach ($transient in @(1, 2)) {
            $script:ownerCalls = 0; $script:ownerFailures = $transient
            Set-ListenerOwners { param($Port) $script:ownerCalls++; if ($script:ownerCalls -ge 2 -and $script:ownerCalls -le (1 + $script:ownerFailures)) { throw "table failed for $marker" }; return @($PID) }
            $recovered = Get-Failure { $script:recoveredReply = Send-Keyed $own }
            Check ($null -eq $recovered -and $script:recoveredReply.Status -eq 200 -and $script:ownerCalls -eq (2 + $transient)) "L1: $transient failed read(s) of the listener table after an answered request, then the right owner: no alarm, the answer is returned ($($script:ownerCalls) reads)"
        }
        $script:ownerCalls = 0
        Set-ListenerOwners { param($Port) $script:ownerCalls++; if ($script:ownerCalls -eq 1) { return @($PID) }; throw "table failed for $marker" }
        $unreadableAfter = Get-Failure { Send-Keyed $own }
        Check ($null -ne $unreadableAfter -and [string]$unreadableAfter.Exception.Data['FastLlmFailureCode'] -ceq 'api-key-listener-changed' -and $script:ownerCalls -eq 4 -and (Test-NoLeak (Get-FailureText $unreadableAfter))) "L1: an answered request after which the listener table cannot be read, three times in a row, is api-key-listener-changed ($($script:ownerCalls) reads)"
        $script:ownerCalls = 0
        Set-ListenerOwners { param($Port) $script:ownerCalls++; if ($script:ownerCalls -eq 1) { return @($PID) }; if ($script:ownerCalls -eq 2) { throw 'table failed' }; return @(4242) }
        $otherAfterRetry = Get-Failure { Send-Keyed $own }
        Check ($null -ne $otherAfterRetry -and [string]$otherAfterRetry.Exception.Data['FastLlmFailureCode'] -ceq 'api-key-listener-changed' -and $script:ownerCalls -eq 3) 'L1: a failed read followed by another owner is api-key-listener-changed (the retry does not hide a real change)'
        # A request that got no answer. With nothing listening afterwards the key went to nobody (the server itself ended): the request's own
        # failure stands. With another program on the port afterwards it is the same failure as above.
        $silentPort = Get-FreePort
        $silentBase = "http://127.0.0.1:$silentPort"
        $script:ownerCalls = 0
        Set-ListenerOwners { param($Port) $script:ownerCalls++; if ($script:ownerCalls -eq 1) { return @($PID) }; return @() }
        $unanswered = Get-Failure { InModule { param($B, $K, $I) Invoke-FastLlmHttp -BaseUrl $B -Path '/props' -TimeoutMs 2000 -ApiKeyHolder $K -ApiKeyServer $I } @($silentBase, $markerHolder, $own) }
        Check ($null -ne $unanswered -and -not $unanswered.Exception.Data['FastLlmFailureCode'] -and $script:ownerCalls -eq 2) 'L1: a request that got no answer, with nothing listening afterwards, fails as the request failed (no key alarm)'
        $script:ownerCalls = 0
        Set-ListenerOwners { param($Port) $script:ownerCalls++; if ($script:ownerCalls -eq 1) { return @($PID) }; return @(4242) }
        $unansweredTaken = Get-Failure { InModule { param($B, $K, $I) Invoke-FastLlmHttp -BaseUrl $B -Path '/props' -TimeoutMs 2000 -ApiKeyHolder $K -ApiKeyServer $I } @($silentBase, $markerHolder, $own) }
        Reset-ListenerOwners
        Check ($null -ne $unansweredTaken -and [string]$unansweredTaken.Exception.Data['FastLlmFailureCode'] -ceq 'api-key-listener-changed') 'L1: a request that got no answer, with another program on the port afterwards, is api-key-listener-changed'
        Check ((InModule { param($B, $I) Get-FastLlmApiKeyListenerVerdict -BaseUrl $B -ServerIdentity $I } @($base, $own)) -ceq 'verified' -and (InModule { param($B, $I) Get-FastLlmApiKeyListenerVerdict -BaseUrl $B -ServerIdentity $I } @($silentBase, $own)) -ceq 'none' -and (InModule { param($B, $I) Get-FastLlmApiKeyListenerVerdict -BaseUrl $B -ServerIdentity $I } @($base, $other)) -ceq 'other' -and (InModule { param($B) Get-FastLlmApiKeyListenerVerdict -BaseUrl $B -ServerIdentity $null } @($base)) -ceq 'unknown' -and (InModule { param($I) Get-FastLlmApiKeyListenerVerdict -BaseUrl 'http://example.invalid:8080' -ServerIdentity $I } @($own)) -ceq 'unknown') 'L1: the listener verdict tells the recorded server, nothing, another owner and "cannot be checked" apart, and never throws'
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
    # W1 inside a start. This mock prints one labelled line (api_keys: ****tail) and, for every request that carried the key, one line with
    # the whole Authorization header and no api_key label. Those are dropped only if the supervisor told the process host which key to
    # look for, and kept telling it: the count in the status must be well above the one labelled line.
    $keyedRequests = @(Get-AuthPaths $run 'ok').Count
    Check ($run.status.PSObject.Properties['apiKeyOutputLinesDropped'] -and [int]$run.status.apiKeyOutputLinesDropped -ge 3 -and $keyedRequests -ge 3) "W1 in a start: the server's lines that held the key itself (one per keyed request, no api_key label) were dropped and counted (dropped: $([int]$run.status.apiKeyOutputLinesDropped); keyed requests in the whole run: $keyedRequests)"
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
    Check ($null -ne $lateFail.failure -and [string]$lateFail.failure.Exception.Message -cmatch 'not repeatable' -and [string]$lateFail.status.failureCode -ceq 'startup-or-runtime-check-failed' -and (Test-PortClosed $lateFail.port)) "failure path: an API check that fails after the proof fails the start as before and stops the server (saw: $([string]$lateFail.status.failureCode); $(if ($lateFail.failure) { [regex]::Replace([string]$lateFail.failure.Exception.Message, '\s+', ' ') }))"
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

    # ---- L1 inside a start: the listener is this run's server before a keyed request and something else right after it ----
    # The real owners of the port, for a seam that changes its answer part of the way through a run.
    function Get-RealListenerOwners([int]$Port) {
        if (-not $isWindowsHost) { return @(Get-TestListenerOwners $Port) }
        if (-not ('Bitworks.FastLlm.WindowsGpuTelemetry' -as [type])) { Add-Type -Path (Join-Path $root 'src/WindowsGpuTelemetry.cs') }
        return @([Bitworks.FastLlm.WindowsGpuTelemetry]::GetLoopbackListenerOwners($Port))
    }
    # During the proof: the first keyed request of the run. The second listener read is the one after that request.
    $script:l1Reads = 0
    Set-ListenerOwners { param($Port) $script:l1Reads++; if ($script:l1Reads -eq 2) { return @(4242) }; return @(Get-RealListenerOwners $Port) }
    try { $exposedEarly = Invoke-KeyRun -Name 'listener-changed-proof' -Mode 'marker-selftest-ok' -Holder $markerHolder -SelfTest }
    finally { Reset-ListenerOwners }
    $exposedEarlyCode = ''
    if ($exposedEarly.failure) { $exposedEarlyCode = [string]$exposedEarly.failure.Exception.Data['FastLlmFailureCode'] }
    Check ($exposedEarlyCode -ceq 'api-key-listener-changed' -and [string]$exposedEarly.status.failureCode -ceq 'api-key-listener-changed' -and [string]$exposedEarly.status.phase -ceq 'failed' -and (Test-PortClosed $exposedEarly.port)) "L1 in a start: a listener that changed right after the proof's keyed request stops the start with api-key-listener-changed, and the server is stopped (saw: $exposedEarlyCode)"
    Check ([string]$exposedEarly.failure.Exception.Message -cmatch 'Create a new key' -and [string]$exposedEarly.failure.Exception.Data['FastLlmReason'] -ceq 'ApiKeyFailed' -and -not $exposedEarly.status.PSObject.Properties['apiKey'] -and @(Get-AuthPaths $exposedEarly 'ok').Count -eq 1) 'L1 in a start: the failure says to create a new key, is never retried, the status never says the key is on, and no further request carried the key'
    $leaks = @(Get-RunLeaks $exposedEarly -Bundle)
    Check ($leaks.Count -eq 0) "marker sweep (listener changed during the proof): no key or tail anywhere ($($leaks -join '; '))"
    # During the API check, which turns a failed request into its own failed check: the key failure still decides the outcome.
    $script:l1Reads = 0
    Set-ListenerOwners { param($Port) $script:l1Reads++; if ($script:l1Reads -eq 4) { return @(4242) }; return @(Get-RealListenerOwners $Port) }
    try { $exposedCheck = Invoke-KeyRun -Name 'listener-changed-check' -Mode 'marker-selftest-ok' -Holder $markerHolder -SelfTest }
    finally { Reset-ListenerOwners }
    $exposedCheckCode = ''
    if ($exposedCheck.failure) { $exposedCheckCode = [string]$exposedCheck.failure.Exception.Data['FastLlmFailureCode'] }
    Check ($exposedCheckCode -ceq 'api-key-listener-changed' -and [string]$exposedCheck.status.failureCode -ceq 'api-key-listener-changed' -and [string]$exposedCheck.failure.Exception.Message -cmatch 'Create a new key' -and [string]$exposedCheck.failure.Exception.Data['FastLlmReason'] -ceq 'ApiKeyFailed' -and (Test-PortClosed $exposedCheck.port)) "L1 in a start: the same during the API check, whatever that check made of its failed request (saw: $exposedCheckCode)"
    # While serving: the idle read treats a failed request as a failed read and carries on. This failure is not one of those: the run stops.
    $exposedFlag = Join-Path $temp 'listener-changed-idle.flag'
    $script:l1Flag = $exposedFlag
    $script:l1Reads = 0
    $script:l1Changed = $false
    # Every keyed request reads the listener twice (before and after), so an even read is always an "after" read.
    Set-ListenerOwners { param($Port)
        $script:l1Reads++
        if ($script:l1Changed -or (($script:l1Reads % 2) -eq 0 -and (Test-Path -LiteralPath $script:l1Flag))) { $script:l1Changed = $true; return @(4242) }
        return @(Get-RealListenerOwners $Port) }
    $waitForFailure = "[IO.File]::WriteAllText('$($exposedFlag.Replace("'", "''"))','x'); for(`$j=0; `$j -lt 300; `$j++){ if ((Get-FastLlmStatus '$((Join-Path $temp 'listener-changed-idle').Replace("'", "''"))').phase -ne 'ready') { break }; Start-Sleep -Milliseconds 200 }"
    try { $exposedIdle = Invoke-KeyRun -Name 'listener-changed-idle' -Mode 'marker-selftest-ok' -Holder $markerHolder -IdleMinutes 15 -Extra $waitForFailure }
    finally { Reset-ListenerOwners }
    $exposedIdleCode = ''
    if ($exposedIdle.failure) { $exposedIdleCode = [string]$exposedIdle.failure.Exception.Data['FastLlmFailureCode'] }
    Check ($exposedIdleCode -ceq 'api-key-listener-changed' -and [string]$exposedIdle.status.failureCode -ceq 'api-key-listener-changed' -and [string]$exposedIdle.status.phase -ceq 'failed' -and (Test-PortClosed $exposedIdle.port)) "L1 while serving: a listener that changed right after an idle read stops the run (it is not a failed read): api-key-listener-changed, server stopped (saw: $exposedIdleCode)"
    Check ([string]$exposedIdle.failure.Exception.Message -cmatch 'Another program may have received the key' -and [string]$exposedIdle.failure.Exception.Message -cmatch 'Create a new key' -and $exposedIdle.failure.Exception.Data['FastLlmAfterReady'] -eq $true -and @(Get-RunLogLines $exposedIdle.install | Where-Object { [string]$_.event -ceq 'idle-stop' }).Count -eq 0) 'L1 while serving: the failure says to create a new key; it is a failure after Ready, never an idle stop'
    $leaks = @(Get-RunLeaks $exposedIdle -Bundle)
    Check ($leaks.Count -eq 0) "marker sweep (listener changed while serving): no key or tail anywhere ($($leaks -join '; '))"

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
    Check (@($plain.status.PSObject.Properties.Name | Where-Object { $_ -match '(?i)apikey' }).Count -eq 0) 'no key: the status has no field about the key at all (the document of a start without the key is the one it always was)'
    Check (@(Find-LeakFiles @($plain.install)).Count -eq 0) 'no key: the inherited variable left no trace in any file'
    $benchCallers = @(Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter '*.ps1' | Where-Object { $_.Name -cnotin @('FastLlm.Runtime.ps1', 'FastLlm.ApiKey.ps1', 'FastLlm.Sidecar.ps1', 'FastLlm.BackgroundHost.ps1', 'FastLlm.ServingSettings.ps1', 'FastLlm.ConnectInfo.ps1', 'FastLlm.UiFlow.ps1', 'FastLlm.SupportBundle.ps1', 'FastLlm.UiFluentConnect.ps1') } | Where-Object { [IO.File]::ReadAllText($_.FullName) -cmatch '(?<!FastLlm\.)ApiKey|LLAMA_API_KEY' })
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
    $afterOff = Get-FastLlmServingSettings -InstallRoot $setRoot
    Check ([string]$off.apiKey -ceq 'off' -and -not $off.apiKeyUndetermined -and [string](ConvertFrom-Json (Read-SettingsText $setRoot)).apiKey -ceq 'off' -and [string]$afterOff.apiKey -ceq 'off' -and -not $afterOff.apiKeyUndetermined) 'setting off: with a key stored, off is saved as the explicit apiKey "off", which reads as off (not as unknown)'
    Check ([string]$off.apiKeyId -ceq [string]$on.apiKeyId -and [string](Invoke-FastLlmApiKeySetting -InstallRoot $setRoot -Action on).apiKeyId -ceq [string]$on.apiKeyId) 'setting off: the stored key is kept, so off and on again does not change the key'
    $rotate = Invoke-FastLlmApiKeySetting -InstallRoot $setRoot -Action rotate
    $shownAfter = Invoke-FastLlmApiKeySetting -InstallRoot $setRoot -Action show
    Check ([string]$rotate.apiKeyId -cne [string]$on.apiKeyId -and [string]$rotate.apiKey -ceq 'on' -and [string]$shownAfter.key -cne [string]$show.key -and (@($rotate.lines) -join ' ') -cmatch 'next start') 'setting rotate: a new key replaces the stored one, the flag is unchanged, and it applies at the next start'
    Check ((Read-SettingsText $setRoot).IndexOf([string]$shownAfter.key, [StringComparison]::Ordinal) -lt 0) 'setting rotate: settings.json still never holds the key'
    $null = Invoke-FastLlmApiKeySetting -InstallRoot $setRoot -Action off
    $rotateOff = Invoke-FastLlmApiKeySetting -InstallRoot $setRoot -Action rotate
    Check ([string]$rotateOff.apiKey -ceq 'off' -and -not $rotateOff.apiKeyUndetermined -and (@($rotateOff.lines) -join ' ') -cmatch 'setting is off') 'setting rotate: with the key off it creates the key and says the setting is off'
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

    # ---- M1: once a key store exists, the flag is never guessed ----
    function Get-StartVerdict([string]$Root) {
        try { $hostArguments = Get-FastLlmServingHostArguments -InstallRoot $Root }
        catch { return 'refused:' + [string]$_.Exception.Data['FastLlmFailureCode'] }
        if ($hostArguments.ContainsKey('UseApiKey')) { return 'key:' + [string]$hostArguments.UseApiKey }
        return 'keyless'
    }
    function Write-SettingsText([string]$Root, [string]$Text) { [IO.File]::WriteAllText((Join-Path $Root 'settings.json'), $Text, (New-Object Text.UTF8Encoding($false))) }
    function Get-SettingsBytes([string]$Root) { $path = Join-Path $Root 'settings.json'; if (Test-Path -LiteralPath $path -PathType Leaf) { return [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) }; return '<no file>' }
    # (1) An installation that never had a key (no key store): it starts without a key exactly as it always did, whatever its settings.json holds.
    $neverKeyed = [ordered]@{ 'no settings.json' = $null; 'an empty object' = '{}'; 'other settings only' = '{ "serverPort": 18181, "thinking": "off", "updateCheck": "off" }' }
    foreach ($shape in $neverKeyed.Keys) {
        $plainRoot = New-Dir ('never-keyed-' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
        if ($null -ne $neverKeyed[$shape]) { Write-SettingsText $plainRoot ([string]$neverKeyed[$shape]) }
        $plainBytes = Get-SettingsBytes $plainRoot
        $plainRead = Get-FastLlmServingSettings -InstallRoot $plainRoot
        $plainResolved = Resolve-FastLlmServingOptions -InstallRoot $plainRoot -Bound @{}
        $plainArguments = Get-FastLlmServingHostArguments -InstallRoot $plainRoot
        Check ([string]$plainRead.apiKey -ceq 'off' -and -not $plainRead.apiKeyUndetermined -and [string]$plainResolved.apiKey -ceq 'off' -and -not $plainResolved.apiKeyUndetermined -and (Get-StartVerdict $plainRoot) -ceq 'keyless' -and (@($plainArguments.Keys | Sort-Object) -join ',') -ceq 'ChatPage,IdleStopMinutes,ServerPort,Thinking') "never keyed ($shape): the flag is off, nothing is refused, and the start arguments are the four they always were"
        Check ((Get-SettingsBytes $plainRoot) -ceq $plainBytes -and -not (Test-Path -LiteralPath (Join-Path $plainRoot 'api-key.dat'))) "never keyed ($shape): reading the flag changes nothing on disk"
    }
    $plainOffRoot = New-Dir 'never-keyed-off'
    $null = Invoke-FastLlmApiKeySetting -InstallRoot $plainOffRoot -Action off
    Check ((Read-SettingsText $plainOffRoot) -cnotmatch 'apiKey' -and (Get-StartVerdict $plainOffRoot) -ceq 'keyless') 'never keyed: settings -ApiKey off with no key stored saves no apiKey value (the settings file of an installation without a key stays as it was)'
    # (2) A key store with no stored value: the flag cannot be known, and the start is refused.
    foreach ($shape in $neverKeyed.Keys) {
        $lostRoot = New-Dir ('lost-flag-' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
        InModule { param($R, $K) Write-FastLlmApiKeyStore -InstallRoot $R -ApiKeyHolder $K } @($lostRoot, $markerHolder)
        if ($null -ne $neverKeyed[$shape]) { Write-SettingsText $lostRoot ([string]$neverKeyed[$shape]) }
        $lostRead = Get-FastLlmServingSettings -InstallRoot $lostRoot
        Check ($lostRead.apiKeyUndetermined -eq $true -and [string]$lostRead.apiKey -ceq 'off' -and (Resolve-FastLlmServingOptions -InstallRoot $lostRoot -Bound @{}).apiKeyUndetermined -eq $true -and (Get-StartVerdict $lostRoot) -ceq 'refused:api-key-setting-unreadable') "key store, $shape`: the flag cannot be known and the start is refused (api-key-setting-unreadable), never keyless"
        Check ((Get-FailureCode { New-FastLlmUiBackgroundRequest -SourceRoot $root -InstallRoot $lostRoot -ModelId 'm' -ContextSize 1 -BarMitigation 'auto' -Settings $lostRead }) -ceq 'api-key-setting-unreadable' -and -not (Resolve-FastLlmServingOptions -InstallRoot $lostRoot -Bound @{} -IgnoreUserSettings).apiKeyUndetermined) "key store, $shape`: the window's background start is refused too; -IgnoreUserSettings (the bench path) still reads nothing"
    }
    # The scenario from the review: the key is on, settings.json is deleted. The key store stays, so the next start is refused.
    $deletedRoot = New-Dir 'deleted-settings'
    $null = Invoke-FastLlmApiKeySetting -InstallRoot $deletedRoot -Action on
    Check ((Get-StartVerdict $deletedRoot) -ceq 'key:on') 'deleted settings: with the key on the start asks for the key'
    Remove-Item -LiteralPath (Join-Path $deletedRoot 'settings.json') -Force
    Check ((Get-StartVerdict $deletedRoot) -ceq 'refused:api-key-setting-unreadable') 'deleted settings: deleting settings.json does not turn the key off: the start is refused until the user chooses'
    $choice = Invoke-FastLlmApiKeySetting -InstallRoot $deletedRoot -Action off
    Check ((Get-StartVerdict $deletedRoot) -ceq 'keyless' -and [string](ConvertFrom-Json (Read-SettingsText $deletedRoot)).apiKey -ceq 'off' -and -not $choice.apiKeyUndetermined) 'deleted settings: choosing off is stored as apiKey "off", and the start then runs without a key'
    $null = Invoke-FastLlmApiKeySetting -InstallRoot $deletedRoot -Action on
    Check ((Get-StartVerdict $deletedRoot) -ceq 'key:on') 'deleted settings: choosing on asks for the key again'
    # The refusal names the choice and does not suggest deleting the file.
    $refusalRoot = New-Dir 'refusal-text'
    InModule { param($R, $K) Write-FastLlmApiKeyStore -InstallRoot $R -ApiKeyHolder $K } @($refusalRoot, $markerHolder)
    $refusalText = [string](Get-Failure { Get-FastLlmServingHostArguments -InstallRoot $refusalRoot }).Exception.Message
    Check ($refusalText -clike 'api-key-setting-unreadable:*' -and $refusalText.Contains('fast-llm.ps1 settings -ApiKey on') -and $refusalText.Contains('fast-llm.ps1 settings -ApiKey off') -and $refusalText.Contains('"Require an API key" in Settings') -and $refusalText -notmatch '(?i)delet|remov') 'refusal: api-key-setting-unreadable tells the user to choose (-ApiKey on, -ApiKey off, or the box in Settings) and does not suggest deleting settings.json'
    # In the window the way out is Settings - but Settings cannot save while the file is not valid JSON. So the window's text names the
    # file by its full path and says to fix or delete it first, then to choose. (Deleting is safe now: see "deleted settings" above.)
    $windowSettingsPath = Join-Path $refusalRoot 'settings.json'
    $windowRefusal = Get-FastLlmUiApiKeyFailure -Code 'api-key-setting-unreadable' -SettingsPath $windowSettingsPath
    Check ([string]$windowRefusal.text -ceq (Get-FastLlmUiApiKeySettingText -SettingsPath $windowSettingsPath) -and $windowRefusal.text.Contains('(' + $windowSettingsPath + ')') -and $windowRefusal.text -cmatch 'If the settings file is not valid JSON, fix or delete it first' -and $windowRefusal.text -cmatch 'Then open Settings, tick or clear "Require an API key", and save\.' -and $windowRefusal.text.IndexOf('fix or delete it first') -lt $windowRefusal.text.IndexOf('Then open Settings') -and -not $windowRefusal.offerNewKey) 'refusal (window): the text names the settings file by its full path, says to fix or delete it first when it is not valid JSON, and then to choose in Settings'
    Check ((Get-FastLlmUiApiKeyFailure -Code 'api-key-setting-unreadable').text.Contains('(settings.json in the FastLLM data folder)') -and (Get-FastLlmUiApiKeyFailure -Code 'api-key-setting-unreadable').text -cmatch 'fix or delete it first') 'refusal (window): without a path the text still says which file, and what to do with it'
    $backgroundRefusal = Get-Failure { New-FastLlmUiBackgroundRequest -SourceRoot $root -InstallRoot $refusalRoot -ModelId 'm' -ContextSize 1 -BarMitigation 'auto' -Settings (Get-FastLlmServingSettings -InstallRoot $refusalRoot) }
    Check ($null -ne $backgroundRefusal -and [string]$backgroundRefusal.Exception.Data['FastLlmFailureCode'] -ceq 'api-key-setting-unreadable' -and [string]$backgroundRefusal.Exception.Message -ceq ('api-key-setting-unreadable: ' + (Get-FastLlmUiApiKeySettingText -SettingsPath $windowSettingsPath))) 'refusal (window, Start in background): the same text, with the full path of this installation''s settings file'
    $windowSource = [IO.File]::ReadAllText((Join-Path $root 'fast-llm-ui.ps1'))
    Check ($windowSource.Contains("`$failure=Get-FastLlmUiApiKeyFailure -Code `$Code -SettingsPath (Join-Path `$script:installPath 'settings.json')") -and @([regex]::Matches($windowSource, 'Get-FastLlmUiApiKeyFailure -Code \$[A-Za-z]+\b(?! -SettingsPath)')).Count -eq 0 -and @([regex]::Matches($windowSource, 'Get-FastLlmUiApiKeyFailure -Code ')).Count -eq 2) 'refusal (window): every place the window asks for a key failure text passes the settings file path'
    # Creating a key is not a choice between on and off.
    $rotateFreshRoot = New-Dir 'rotate-fresh'
    $rotateFresh = Invoke-FastLlmApiKeySetting -InstallRoot $rotateFreshRoot -Action rotate
    Check ([string]$rotateFresh.apiKey -ceq 'off' -and -not $rotateFresh.apiKeyUndetermined -and [string](ConvertFrom-Json (Read-SettingsText $rotateFreshRoot)).apiKey -ceq 'off' -and (Get-StartVerdict $rotateFreshRoot) -ceq 'keyless') 'create a new key, never keyed: the setting was off and stays off, now stored as apiKey "off" next to the new key store'
    $rotateLostRoot = New-Dir 'rotate-lost'
    InModule { param($R, $K) Write-FastLlmApiKeyStore -InstallRoot $R -ApiKeyHolder $K } @($rotateLostRoot, $markerHolder)
    $rotateLost = Invoke-FastLlmApiKeySetting -InstallRoot $rotateLostRoot -Action rotate
    Check ($rotateLost.apiKeyUndetermined -eq $true -and (Read-SettingsText $rotateLostRoot) -cnotmatch 'apiKey' -and (Get-StartVerdict $rotateLostRoot) -ceq 'refused:api-key-setting-unreadable' -and (@($rotateLost.lines) -join ' ') -cmatch 'not set yet' -and (@($rotateLost.lines) -join ' ') -cnotmatch 'setting is off') 'create a new key, flag unknown: the flag stays unknown (no on or off is written for the user) and the answer says to choose'

    # (3) A settings.json that cannot be read is never written over, by any writer. Each of the eight is tried on each unreadable form,
    # next to a key store: the file is byte-for-byte what it was, the flag is still unknown and the start is still refused. A writer that
    # has something to write throws; the two that only remove a remembered decline have nothing to do when they find none (quiet).
    $settingsWriters = [ordered]@{
        'Write-FastLlmUiSettings (the Resizable BAR box, stopping a background run)' = @{ run = { param($R) Write-FastLlmUiSettings -InstallRoot $R -Settings ([pscustomobject]@{ vulkanBarMitigation = 'auto'; lastUserStoppedBackgroundRequestId = ('a' * 32) }) } }
        'Set-FastLlmUiAllowSwitch (the window''s Allow switching models box)' = @{ run = { param($R) Set-FastLlmUiAllowSwitch -InstallRoot $R -Value $true } }
        'Set-FastLlmUpdateSettings (the update check box, settings -Channel)' = @{ run = { param($R) Set-FastLlmUpdateSettings -InstallRoot $R -UpdateCheck off } }
        'Set-FastLlmComponentSettings (the experimental components switch)' = @{ run = { param($R) Set-FastLlmComponentSettings -InstallRoot $R -ExperimentalComponents off } }
        'Set-FastLlmComponentLicenseSettings (settings -ComponentLicenses)' = @{ run = { param($R) Set-FastLlmComponentLicenseSettings -InstallRoot $R -Mode ask } }
        'Set-FastLlmServingSettings (port, thinking, chat page, idle stop)' = @{ run = { param($R) Set-FastLlmServingSettings -InstallRoot $R -ServerPort 18282 -Thinking off } }
        'Add-FastLlmUiDeclinedSetup (a declined automatic setup is remembered)' = @{ run = { param($R) Add-FastLlmUiDeclinedSetup -InstallRoot $R -RecipeId 'declined.setup-two' } }
        'Remove-FastLlmUiDeclinedSetup (a remembered decline is forgotten)' = @{ run = { param($R) Remove-FastLlmUiDeclinedSetup -InstallRoot $R -RecipeId 'declined.setup-one' }; quietUnless = 'over the size limit'; createsFile = $false }
        'Clear-FastLlmUiDeclinedSetups (the automatic install is turned on)' = @{ run = { param($R) Clear-FastLlmUiDeclinedSetups -InstallRoot $R }; createsFile = $false }
    }
    # "Not a JSON object" covers every other JSON value. An array matters most: Windows PowerShell 5.1 returns it in one piece, and like
    # a string, a number or true it then looks like an object with properties (Length, Count) to a careless type test.
    $unreadableForms = [ordered]@{
        'a torn write' = '{ "apiKey": "on", "serverPort": 8081,'
        'a JSON array' = '[ "apiKey", "on" ]'
        'a JSON array of objects' = '[ { "apiKey": "on" } ]'
        'a JSON string' = '"apiKey on"'
        'a JSON number' = '5'
        'the JSON value true' = 'true'
        'the JSON value null' = 'null'
        'empty' = ''
        'over the size limit' = ('{ "apiKey": "on", "declinedSetups": [ "declined.setup-one" ], "note": "' + ('x' * 17000) + '" }')
    }
    foreach ($formName in $unreadableForms.Keys) {
        $formRoot = New-Dir ('form-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        InModule { param($R, $K) Write-FastLlmApiKeyStore -InstallRoot $R -ApiKeyHolder $K } @($formRoot, $markerHolder)
        Write-SettingsText $formRoot ([string]$unreadableForms[$formName])
        $formRead = Get-FastLlmServingSettings -InstallRoot $formRoot
        Check ($formRead.malformed -eq $true -and $formRead.apiKeyUndetermined -eq $true -and (Read-FastLlmServingSettingsObject -InstallRoot $formRoot).object.Count -eq 0) "unreadable settings ($formName): it is read as not a JSON object (no setting is taken from it), and with a key store the flag is unknown"
    }
    foreach ($writerName in $settingsWriters.Keys) {
        $writer = $settingsWriters[$writerName]
        foreach ($formName in $unreadableForms.Keys) {
            $clobberRoot = New-Dir ('clobber-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
            $null = Invoke-FastLlmApiKeySetting -InstallRoot $clobberRoot -Action on
            Write-SettingsText $clobberRoot ([string]$unreadableForms[$formName])
            $bytesBefore = Get-SettingsBytes $clobberRoot
            $writerFailure = Get-Failure { & $writer.run $clobberRoot }
            $othersLeft = @(Get-ChildItem -LiteralPath $clobberRoot -Force | Where-Object { $_.Name -cnotin @('settings.json', 'api-key.dat') })
            $quiet = [bool]($writer.ContainsKey('quietUnless') -and [string]$writer.quietUnless -cne $formName)
            $refusedAsExpected = if ($quiet) { $null -eq $writerFailure } else { $null -ne $writerFailure -and [string]$writerFailure.Exception.Message -cmatch 'settings-malformed: settings\.json is not valid JSON' }
            Check ($refusedAsExpected -and (Get-SettingsBytes $clobberRoot) -ceq $bytesBefore -and $othersLeft.Count -eq 0 -and (Get-FastLlmServingSettings -InstallRoot $clobberRoot).apiKeyUndetermined -eq $true -and (Get-StartVerdict $clobberRoot) -ceq 'refused:api-key-setting-unreadable') "unreadable settings ($formName): $writerName $(if ($quiet) { 'finds nothing to do and writes nothing' } else { 'refuses' }), the file bytes are unchanged, the flag stays unknown and the start stays refused"
        }
    }
    # A folder in the place of the file is refused the same way.
    foreach ($writerName in $settingsWriters.Keys) {
        $writer = $settingsWriters[$writerName]
        $folderRoot = New-Dir ('clobber-folder-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = Invoke-FastLlmApiKeySetting -InstallRoot $folderRoot -Action on
        Remove-Item -LiteralPath (Join-Path $folderRoot 'settings.json') -Force
        New-Item -ItemType Directory -Path (Join-Path $folderRoot 'settings.json') | Out-Null
        $folderFailure = Get-Failure { & $writer.run $folderRoot }
        Check (($null -ne $folderFailure -or $writer.ContainsKey('quietUnless')) -and (Test-Path -LiteralPath (Join-Path $folderRoot 'settings.json') -PathType Container) -and @(Get-ChildItem -LiteralPath (Join-Path $folderRoot 'settings.json') -Force).Count -eq 0 -and (Get-StartVerdict $folderRoot) -ceq 'refused:api-key-setting-unreadable') "unreadable settings (a folder named settings.json): $writerName leaves it, and the start stays refused"
    }
    # A readable file is still merged: each writer keeps apiKey "on" and every other key. (One decline is remembered first, so the two
    # writers that remove declines have something to write.)
    foreach ($writerName in $settingsWriters.Keys) {
        $mergeRoot = New-Dir ('merge-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = Invoke-FastLlmApiKeySetting -InstallRoot $mergeRoot -Action on
        Set-FastLlmServingSettings -InstallRoot $mergeRoot -ChatPage on
        Add-FastLlmUiDeclinedSetup -InstallRoot $mergeRoot -RecipeId 'declined.setup-one'
        $mergeBytes = Get-SettingsBytes $mergeRoot
        & $settingsWriters[$writerName].run $mergeRoot
        $merged = ConvertFrom-Json (Read-SettingsText $mergeRoot)
        Check ((Get-SettingsBytes $mergeRoot) -cne $mergeBytes -and [string]$merged.apiKey -ceq 'on' -and [string]$merged.chatPage -ceq 'on' -and (Get-StartVerdict $mergeRoot) -ceq 'key:on') "readable settings: $writerName writes its change and keeps apiKey on and the other settings"
    }
    # An absent file is not "unreadable": a writer with something to write still creates it (as before), and without a key store the
    # result starts keyless.
    foreach ($writerName in $settingsWriters.Keys) {
        $writer = $settingsWriters[$writerName]
        $freshRoot = New-Dir ('fresh-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        & $writer.run $freshRoot
        $expectFile = -not ($writer.ContainsKey('createsFile') -and -not $writer.createsFile)
        Check ((Test-Path -LiteralPath (Join-Path $freshRoot 'settings.json') -PathType Leaf) -eq $expectFile -and (Read-SettingsText $freshRoot) -cnotmatch 'apiKey' -and (Get-StartVerdict $freshRoot) -ceq 'keyless') "no settings.json: $writerName $(if ($expectFile) { 'creates the file as before, with no apiKey value' } else { 'has nothing to remove and creates nothing' })"
    }
    # No function writes settings.json after a read that tolerates an unreadable file: every caller of the two shared writers reads
    # with -ForWrite (or through the serving reader's malformed verdict) in the same function.
    $writerScan = New-Object 'System.Collections.Generic.List[string]'
    foreach ($writerFile in @('src/FastLlm.Components.ps1', 'src/FastLlm.Update.ps1', 'src/FastLlm.UiFlow.ps1', 'src/FastLlm.ServingSettings.ps1')) {
        $writerTree = Get-SourceTree $writerFile
        foreach ($function in @($writerTree.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
            $functionText = [string]$function.Body.Extent.Text
            $writesFile = ($functionText -cmatch 'Write-FastLlmComponentSettingsObject\s+-InstallRoot' -or ($functionText -cmatch "Join-Path \`$InstallRoot 'settings\.json'" -and $functionText -cmatch 'WriteAllText\('))
            if (-not $writesFile -or $function.Name -ceq 'Write-FastLlmComponentSettingsObject') { continue }
            $strictRead = ($functionText -cmatch 'Read-FastLlm(Component)?SettingsObject -InstallRoot \$InstallRoot -ForWrite' -or $functionText -cmatch "if \(\`$read\.malformed\) \{ throw 'serving-settings-malformed:" -or $functionText -cmatch "if \(-not \`$readable\) \{ throw 'settings-malformed:")
            $lenientRead = ($functionText -cmatch 'Read-FastLlm(Component)?SettingsObject -InstallRoot \$InstallRoot(?! -ForWrite)')
            if (-not $strictRead -or $lenientRead) { $writerScan.Add("$writerFile $($function.Name)") }
            else { $writerScan.Add("ok $($function.Name)") }
        }
    }
    $writersFound = @($writerScan | Where-Object { $_ -clike 'ok *' } | ForEach-Object { $_.Substring(3) } | Sort-Object)
    Check (@($writerScan | Where-Object { $_ -cnotlike 'ok *' }).Count -eq 0 -and ($writersFound -join ',') -ceq 'Add-FastLlmUiDeclinedSetup,Clear-FastLlmUiDeclinedSetups,Remove-FastLlmUiDeclinedSetup,Set-FastLlmComponentLicenseSettings,Set-FastLlmComponentSettings,Set-FastLlmServingSettings,Set-FastLlmUpdateSettings,Write-FastLlmUiSettings') "settings writers: every function that writes settings.json reads it strictly first; these are all of them ($($writersFound -join ',')) $(@($writerScan | Where-Object { $_ -cnotlike 'ok *' }) -join '; ')"
    # The window's own triggers leave an unreadable file alone too: its lenient reads still give the defaults (no error), only the writes refuse.
    $lenientRoot = New-Dir 'lenient-read'
    Write-SettingsText $lenientRoot '{ broken'
    Check ((Get-FastLlmUpdateSettings -InstallRoot $lenientRoot).updateCheck -ceq 'on' -and (Get-FastLlmComponentSettings -InstallRoot $lenientRoot).experimentalComponents -ceq 'off' -and [string](Get-FastLlmComponentLicenseSettings -InstallRoot $lenientRoot).mode -ceq 'ask' -and [string](Read-FastLlmUiSettings -InstallRoot $lenientRoot -AppRoot $root).vulkanBarMitigation -ceq 'auto') 'unreadable settings: reading is as tolerant as before (the defaults apply); only writing is refused'
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
    $refusedEmbeddings = Invoke-Cli @('settings', '-InstallRoot', $cliRoot, '-ApiKey', 'show', '-Embeddings', 'on')
    Check ($refusedEmbeddings.exit -ne 0 -and $refusedEmbeddings.flat -cmatch 'cannot be combined with -AsJson or with another setting') 'command line: settings -ApiKey show is refused with -Embeddings, like the other settings'
    $refusedEmbeddingPort = Invoke-Cli @('settings', '-InstallRoot', $cliRoot, '-ApiKey', 'show', '-EmbeddingPort', '8082')
    Check ($refusedEmbeddingPort.exit -ne 0 -and $refusedEmbeddingPort.flat -cmatch 'cannot be combined with -AsJson or with another setting') 'command line: settings -ApiKey show is refused with -EmbeddingPort, like the other settings'
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
    $cardKeyText = $marker
    $copiedCard = Get-FastLlmConnectCopyText -Snippet $card['claude-code'] -Key ([ref]$cardKeyText)
    Check ($copiedCard.Contains('$env:ANTHROPIC_AUTH_TOKEN = "' + $marker + '"') -and -not $copiedCard.Contains('{KEY}') -and -not $copiedCard.Contains('<your FastLLM key>')) 'connect: a card''s Copy puts the real key in'
    foreach ($unusable in @($null, '', 'fl-short', ($marker + 'x'), $markerHolder)) {
        $fallback = Get-FastLlmConnectCopyText -Snippet $card['claude-code'] -Key ([ref]$unusable)
        Check ($fallback -ceq $shownCard) 'connect: a card copied without a usable key copies the placeholder, never a partial or malformed key'
    }
    Check ((Get-FastLlmConnectCopyText -Snippet $card['claude-code']) -ceq $shownCard -and [string](Get-Command Get-FastLlmConnectCopyText).Parameters['Key'].ParameterType.Name -ceq 'PSReference') 'connect: the card copy takes the key inside a [ref] (never as a plain value); without one it copies the placeholder'

    # ---- L3 and the one copy routine: what Copy puts on the clipboard, and what it never touches ----
    $clipboardFormats = Get-FastLlmUiKeyClipboardFormats
    Check ((@($clipboardFormats.Keys) -join ',') -ceq 'ExcludeClipboardContentFromMonitorProcessing,CanIncludeInClipboardHistory,CanUploadToCloudClipboard') 'clipboard: a copy that holds the key carries the three formats that keep it out of the clipboard history and the cloud clipboard'
    Check ((@($clipboardFormats['CanIncludeInClipboardHistory']) -join ',') -ceq '0,0,0,0' -and (@($clipboardFormats['CanUploadToCloudClipboard']) -join ',') -ceq '0,0,0,0' -and @($clipboardFormats['ExcludeClipboardContentFromMonitorProcessing']).Count -eq 4 -and @($clipboardFormats.Values | Where-Object { $_ -isnot [byte[]] }).Count -eq 0) 'clipboard: history and cloud upload are both set to 0 (a four-byte value each), and the exclusion format is present'
    # How the payload gets onto the clipboard: Set-FastLlmUiClipboard fills a data object and publishes it. Here the data object is a
    # recorder (the window passes a Windows.Forms.DataObject), so every call, its order and its arguments are checked.
    function Invoke-ClipboardProbe($Payload) {
        $script:clipboardProbe = @{ made = 0; published = (New-Object 'System.Collections.Generic.List[object]'); calls = (New-Object 'System.Collections.Generic.List[object]') }
        Set-FastLlmUiClipboard -Payload $Payload -NewDataObject {
            $script:clipboardProbe.made++
            $recorder = New-Object psobject
            $recorder | Add-Member -MemberType ScriptMethod -Name SetData -Value {
                $recorded = @{ at = 'set'; count = $args.Count; format = $args[0]; convert = $args[1]; data = $args[2]; bytes = $null; publishedBefore = $script:clipboardProbe.published.Count }
                if ($args[2] -is [IO.MemoryStream]) { $recorded.bytes = (@($args[2].ToArray()) -join ',') }
                $script:clipboardProbe.calls.Add($recorded)
            }
            return $recorder
        } -Publish { param($Data) $script:clipboardProbe.published.Add($Data) }
        return $script:clipboardProbe
    }
    $keyPayload = @{ text = $marker; formats = (Get-FastLlmUiKeyClipboardFormats) }
    $clipboardKey = Invoke-ClipboardProbe $keyPayload
    $clipboardCalls = @($clipboardKey.calls.ToArray())
    Check ($clipboardKey.made -eq 1 -and $clipboardKey.published.Count -eq 1 -and $clipboardCalls.Count -eq 4 -and @($clipboardCalls | Where-Object { $_.count -ne 3 -or $_.publishedBefore -ne 0 }).Count -eq 0) 'clipboard object: one data object is made, filled with four entries (the text and the three formats), and published once, after it was filled'
    Check ($clipboardCalls[0].format -ceq 'UnicodeText' -and $clipboardCalls[0].convert -eq $true -and $clipboardCalls[0].data -is [string] -and [string]$clipboardCalls[0].data -ceq $marker) 'clipboard object: the text is set first, as UnicodeText with conversion to the other text formats'
    $clipboardFormatCalls = @($clipboardCalls | Select-Object -Skip 1)
    Check ((@($clipboardFormatCalls | ForEach-Object { [string]$_.format + '=' + [string]$_.bytes + '/' + [string]$_.convert }) -join ';') -ceq 'ExcludeClipboardContentFromMonitorProcessing=1,0,0,0/False;CanIncludeInClipboardHistory=0,0,0,0/False;CanUploadToCloudClipboard=0,0,0,0/False' -and @($clipboardFormatCalls | Where-Object { $_.data -isnot [IO.MemoryStream] }).Count -eq 0) 'clipboard object: each exclusion format is set under its exact name, without conversion, as a stream of its four raw bytes'
    $clipboardPlain = Invoke-ClipboardProbe @{ text = 'curl http://127.0.0.1:8080/v1/models'; formats = ([ordered]@{}) }
    Check ($clipboardPlain.published.Count -eq 1 -and $clipboardPlain.calls.Count -eq 1 -and [string]$clipboardPlain.calls[0].data -ceq 'curl http://127.0.0.1:8080/v1/models') 'clipboard object: a copy without the key is the text alone'
    $clipboardFailed = Get-Failure { Set-FastLlmUiClipboard -Payload $keyPayload -NewDataObject { throw 'no data object' } -Publish { param($Data) $script:clipboardProbe.published.Add($Data) } }
    Check ($null -ne $clipboardFailed) 'clipboard object: a failure is passed on to the copy routine (which reports it in fixed text); nothing is swallowed'
    # The window's two Copy handlers call this one routine with three script blocks. Here the blocks record what they are given.
    function Invoke-CopyProbe([hashtable]$Arguments, $KeyToRead, [switch]$ClipboardFails) {
        $script:copyProbe = @{ clipboard = (New-Object 'System.Collections.Generic.List[object]'); status = (New-Object 'System.Collections.Generic.List[string]'); reads = 0; key = $KeyToRead; fail = [bool]$ClipboardFails }
        $returned = Invoke-FastLlmUiKeyCopy @Arguments -ReadKey { $script:copyProbe.reads++; return $script:copyProbe.key } -SetClipboard { param($Payload) if ($script:copyProbe.fail) { throw "clipboard busy $marker" }; $script:copyProbe.clipboard.Add($Payload) } -SetStatus { param($Text) $script:copyProbe.status.Add([string]$Text) }
        return [pscustomobject]@{ returned = $returned; clipboard = @($script:copyProbe.clipboard.ToArray()); status = @($script:copyProbe.status.ToArray()); reads = [int]$script:copyProbe.reads }
    }
    $keyCopy = Invoke-CopyProbe @{ KeyOnly = $true } $marker
    Check ($keyCopy.returned -eq $true -and $keyCopy.reads -eq 1 -and $keyCopy.clipboard.Count -eq 1 -and [string]$keyCopy.clipboard[0].text -ceq $marker -and (@($keyCopy.clipboard[0].formats.Keys) -join ',') -ceq (@($clipboardFormats.Keys) -join ',')) 'copy (the API key row): the key goes to the clipboard, once, together with the three exclusion formats'
    Check ($keyCopy.status.Count -eq 0) 'copy (the API key row): nothing else is given the key - the status line is not written at all on success'
    $cardCopy = Invoke-CopyProbe @{ Snippet = $card['claude-code'] } $marker
    Check ($cardCopy.returned -eq $true -and $cardCopy.reads -eq 1 -and [string]$cardCopy.clipboard[0].text -ceq $copiedCard -and (@($cardCopy.clipboard[0].formats.Keys) -join ',') -ceq (@($clipboardFormats.Keys) -join ',') -and $cardCopy.status.Count -eq 0) 'copy (a card with the key): the card text with the key goes to the clipboard with the three exclusion formats, and the status line is not written'
    $plainSnippet = 'curl http://127.0.0.1:8080/v1/models'
    $plainCopy = Invoke-CopyProbe @{ Snippet = $plainSnippet } $marker
    Check ($plainCopy.returned -eq $true -and $plainCopy.reads -eq 0 -and [string]$plainCopy.clipboard[0].text -ceq $plainSnippet -and @($plainCopy.clipboard[0].formats.Keys).Count -eq 0) 'copy (a card without the key): the key store is not read, and an ordinary copy carries no exclusion format'
    $lostKeyCopy = Invoke-CopyProbe @{ KeyOnly = $true } $null
    $lostCardCopy = Invoke-CopyProbe @{ Snippet = $card['claude-code'] } $null
    Check ($lostKeyCopy.returned -eq $false -and $lostKeyCopy.clipboard.Count -eq 0 -and ($lostKeyCopy.status -join '|') -ceq 'The stored API key cannot be read.' -and $lostCardCopy.returned -eq $true -and [string]$lostCardCopy.clipboard[0].text -ceq $shownCard -and @($lostCardCopy.clipboard[0].formats.Keys).Count -eq 0 -and ($lostCardCopy.status -join '|') -ceq 'The stored API key cannot be read, so the card was copied without it.') 'copy (the store cannot be read): the key row copies nothing; a card is copied with the placeholder; each says so in fixed text'
    $badKeyCopy = Invoke-CopyProbe @{ KeyOnly = $true } 'fl-short'
    Check ($badKeyCopy.returned -eq $false -and $badKeyCopy.clipboard.Count -eq 0) 'copy: something that is not a well-formed key is never put on the clipboard as the key'
    $failedKeyCopy = Invoke-CopyProbe @{ KeyOnly = $true } $marker -ClipboardFails
    $failedCardCopy = Invoke-CopyProbe @{ Snippet = $card['claude-code'] } $marker -ClipboardFails
    Check ($failedKeyCopy.returned -eq $false -and ($failedKeyCopy.status -join '|') -ceq 'Could not copy the API key.' -and $failedCardCopy.returned -eq $false -and ($failedCardCopy.status -join '|') -ceq 'Could not copy the card.') 'copy (the clipboard fails): the status line gets fixed text only, never the clipboard''s own error'
    $everyStatus = @($keyCopy.status) + @($cardCopy.status) + @($plainCopy.status) + @($lostKeyCopy.status) + @($lostCardCopy.status) + @($badKeyCopy.status) + @($failedKeyCopy.status) + @($failedCardCopy.status)
    Check ((Test-NoLeak ($everyStatus -join "`n")) -and @($everyStatus | Where-Object { $_ -cmatch 'fl-[A-Za-z0-9_-]{8}' }).Count -eq 0) 'copy: in every case the status line was given no key text (the only place the key goes is the clipboard)'

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
    $offers = @('api-key-unavailable', 'api-key-not-enforced', 'api-key-listener-not-verified', 'api-key-setting-unreadable', 'api-key-invalid', 'api-key-listener-changed', 'api-key-other') | ForEach-Object { (Get-FastLlmUiApiKeyFailure -Code $_) }
    Check ((@($offers | Where-Object { $_.offerNewKey } | ForEach-Object { $_.code }) -join ',') -ceq 'api-key-unavailable,api-key-invalid,api-key-listener-changed' -and @($offers | Where-Object { [string]::IsNullOrWhiteSpace($_.text) }).Count -eq 0) 'window: Create a new key is offered exactly when the stored key cannot be used or may have been seen; every code has a plain text'
    Check ((Test-FastLlmUiApiKeyFailure -Code 'api-key-listener-changed') -and (Get-FastLlmUiApiKeyFailure -Code 'api-key-listener-changed').text -cmatch 'Another program may have received the key' -and (Get-FastLlmUiApiKeyFailure -Code 'api-key-listener-changed').text -cmatch 'Create a new key') 'window (L1): a run stopped by api-key-listener-changed says another program may have received the key and offers Create a new key'

    # ---- L4: the Settings box when the flag cannot be known ----
    Check ((Get-FastLlmUiApiKeyBoxState -Settings ([pscustomobject]@{ apiKey = 'off'; apiKeyUndetermined = $true })) -ceq 'indeterminate' -and (Get-FastLlmUiApiKeyBoxState -Settings ([pscustomobject]@{ apiKey = 'on'; apiKeyUndetermined = $true })) -ceq 'indeterminate') 'settings box: when the flag cannot be known the box is neither ticked nor clear'
    Check ((Get-FastLlmUiApiKeyBoxState -Settings ([pscustomobject]@{ apiKey = 'on'; apiKeyUndetermined = $false })) -ceq 'checked' -and (Get-FastLlmUiApiKeyBoxState -Settings ([pscustomobject]@{ apiKey = 'off'; apiKeyUndetermined = $false })) -ceq 'unchecked' -and (Get-FastLlmUiApiKeyBoxState -Settings ([pscustomobject]@{ serverPort = 8080 })) -ceq 'unchecked' -and (Get-FastLlmUiApiKeyBoxState -Settings $null) -ceq 'unchecked') 'settings box: a known flag shows ticked for on and clear for off (also when the settings have no key fields at all)'
    $saveCases = @(
        @{ current = 'off'; undetermined = $true;  box = 'indeterminate'; touched = $false; expect = 'ask';  why = 'unknown and untouched: Save is refused' }
        @{ current = 'off'; undetermined = $true;  box = 'unchecked';     touched = $false; expect = 'ask';  why = 'unknown and untouched (whatever the box shows): Save is refused, off is never written for the user' }
        @{ current = 'off'; undetermined = $true;  box = 'checked';       touched = $false; expect = 'ask';  why = 'unknown and untouched (whatever the box shows): Save is refused' }
        @{ current = 'off'; undetermined = $true;  box = 'indeterminate'; touched = $true;  expect = 'ask';  why = 'unknown and clicked back to neither: Save is refused' }
        @{ current = 'off'; undetermined = $true;  box = 'unchecked';     touched = $true;  expect = 'off';  why = 'unknown, the user cleared the box: off is saved' }
        @{ current = 'off'; undetermined = $true;  box = 'checked';       touched = $true;  expect = 'on';   why = 'unknown, the user ticked the box: on is saved' }
        @{ current = 'off'; undetermined = $false; box = 'unchecked';     touched = $false; expect = 'none'; why = 'known off, box clear: nothing is written' }
        @{ current = 'off'; undetermined = $false; box = 'unchecked';     touched = $true;  expect = 'none'; why = 'known off, ticked and cleared again: nothing is written' }
        @{ current = 'off'; undetermined = $false; box = 'checked';       touched = $true;  expect = 'on';   why = 'known off, ticked: on' }
        @{ current = 'on';  undetermined = $false; box = 'checked';       touched = $false; expect = 'none'; why = 'known on, box ticked: nothing is written' }
        @{ current = 'on';  undetermined = $false; box = 'unchecked';     touched = $true;  expect = 'off';  why = 'known on, cleared: off' }
        @{ current = 'on';  undetermined = $false; box = 'indeterminate'; touched = $true;  expect = 'ask';  why = 'a box that is neither is never saved' }
        @{ current = 'on';  undetermined = $false; box = 'something';     touched = $true;  expect = 'ask';  why = 'an unknown box state is never saved' }
    )
    foreach ($saveCase in $saveCases) {
        $action = Get-FastLlmUiApiKeySaveAction -Current $saveCase.current -Undetermined $saveCase.undetermined -BoxState $saveCase.box -Touched $saveCase.touched
        Check ($action -ceq $saveCase.expect) "settings save ($($saveCase.why)): $($saveCase.expect) (saw: $action)"
    }
    Check ((Get-FastLlmUiApiKeyChoiceText) -cmatch 'Tick "Require an API key"' -and (Get-FastLlmUiApiKeyChoiceText) -cmatch 'Nothing was saved' -and (Get-FastLlmUiApiKeyChoiceText) -cmatch 'fix or delete that file first') 'settings save: the refusal tells the user to tick or clear the box, that nothing was saved, and what to do if saving then fails on a settings file that is not valid JSON'
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
    Check ($uiSource.Contains('$copy.Tag=[string]$client.snippet') -and $uiSource.Contains('[void](Invoke-FastLlmUiKeyCopy -Snippet ([string]$sender.Tag) -ReadKey {ReadUiApiKey} -SetClipboard {param($Payload) SetUiClipboardPayload $Payload} -SetStatus {param($Text) $statusLabel.Text=[string]$Text})') -and $uiSource.Contains('$snippetBox.Text=(Get-FastLlmConnectDisplayText -Snippet ([string]$client.snippet))')) 'window: a card shows the placeholder, keeps only the {KEY} token, and its Copy goes through the one copy routine'
    Check ($uiSource.Contains('[void](Invoke-FastLlmUiKeyCopy -KeyOnly -ReadKey {ReadUiApiKey} -SetClipboard {param($Payload) SetUiClipboardPayload $Payload} -SetStatus {param($Text) $statusLabel.Text=[string]$Text})') -and @([regex]::Matches($uiSource, 'Invoke-FastLlmUiKeyCopy ')).Count -eq 3 -and @([regex]::Matches($uiSource, 'Invoke-FastLlmUiKeyCopy -KeyOnly ')).Count -eq 2) 'window: the API key row''s Copy goes through the same routine (the callers are the card Copy, the key Copy button and the key box copy guard, which carries the same key-only call)'
    # Where the window touches the key at all: the reader, the two hand-overs to the copy routine, and Show (which fills the key box only).
    $readerUses = @([regex]::Matches($uiSource, '(?i)(?<![A-Za-z])ReadUiApiKey(?![A-Za-z])') | ForEach-Object { $lineStart = $uiSource.LastIndexOf("`n", $_.Index) + 1; $lineEnd = $uiSource.IndexOf("`n", $_.Index); $uiSource.Substring($lineStart, $lineEnd - $lineStart).Trim() })
    Check ($readerUses.Count -eq 5 -and @($readerUses | Where-Object { $_ -clike 'function ReadUiApiKey*' }).Count -eq 1 -and @($readerUses | Where-Object { $_ -clike '*Invoke-FastLlmUiKeyCopy*-ReadKey {ReadUiApiKey}*' }).Count -eq 3 -and @($readerUses | Where-Object { $_ -ceq '$shownKey=ReadUiApiKey' }).Count -eq 1) "window: the key is read in exactly four places - Show, and the three hand-overs to the copy routine (card Copy, key Copy button, key box copy guard) ($($readerUses.Count) uses)"
    $shownKeyUses = @([regex]::Matches($uiSource, '(?i)\$shownKey\b[^\r\n;{}]*') | ForEach-Object { $_.Value.Trim() })
    Check (($shownKeyUses -join ' | ') -ceq '$shownKey=ReadUiApiKey | $shownKey) | $shownKey | $shownKey=$null' -and $uiSource.Contains('if($shownKey){$keyBox.Text=$shownKey;$keyShow.Text=''Hide''}')) "window: Show puts the key into the key box and nowhere else, then drops it ($($shownKeyUses -join ' | '))"
    # The window's part of the clipboard is one function of one statement: the tested routine, a real data object and the real clipboard
    # (kept after the window closes). It is pinned whole, so nothing can be added to it or left out of it unnoticed.
    $uiTree = Get-SourceTree 'fast-llm-ui.ps1'
    $clipboardFunction = @($uiTree.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'SetUiClipboardPayload' }, $true))
    $clipboardStatements = @()
    if ($clipboardFunction.Count -eq 1) { $clipboardStatements = @($clipboardFunction[0].Body.EndBlock.Statements | ForEach-Object { [string]$_.Extent.Text }) }
    Check ($clipboardFunction.Count -eq 1 -and $clipboardStatements.Count -eq 1 -and $clipboardStatements[0] -ceq 'Set-FastLlmUiClipboard -Payload $Payload -NewDataObject {New-Object Windows.Forms.DataObject} -Publish {param($ClipboardData) [Windows.Forms.Clipboard]::SetDataObject($ClipboardData,$true)}' -and (@($clipboardFunction[0].Parameters | ForEach-Object { [string]$_.Extent.Text }) -join ',') -ceq '$Payload') "window (L3): SetUiClipboardPayload is exactly one statement - the tested routine with a Windows.Forms.DataObject and Clipboard.SetDataObject(data, keep after exit) ($($clipboardStatements -join ' | '))"
    Check ($uiSource -notmatch '(?i)Clipboard\]::SetText\([^)]*(Key|ReadUiApiKey)' -and @([regex]::Matches($uiSource, 'Clipboard\]::SetDataObject\(')).Count -eq 1 -and @([regex]::Matches($uiSource, '(?i)(?<![A-Za-z])SetUiClipboardPayload(?![A-Za-z])')).Count -eq 4) 'window (L3): no handler copies the key as plain text; the three copy sites (card Copy, key Copy button, key box copy guard) hand their payload to that one function'
    Check ($uiSource.Contains('$keyBoxState=Get-FastLlmUiApiKeyBoxState -Settings $current') -and $uiSource.Contains("if(`$keyBoxState -ceq 'indeterminate'){`$keyBox.ThreeState=`$true;`$keyBox.CheckState=[Windows.Forms.CheckState]::Indeterminate") -and $uiSource.Contains('$keyAction=Get-FastLlmUiApiKeySaveAction -Current ([string]$current.apiKey) -Undetermined ([bool]$current.apiKeyUndetermined) -BoxState ([string]$keyBox.CheckState).ToLowerInvariant() -Touched ([bool]$script:settingsKeyTouched)') -and $uiSource.Contains("if(`$keyAction -ceq 'ask'){throw (Get-FastLlmUiApiKeyChoiceText)}") -and $uiSource.IndexOf("if(`$keyAction -ceq 'ask'){throw") -lt $uiSource.IndexOf('Set-FastLlmServingSettings -InstallRoot $script:installPath -ServerPort')) 'window (L4): Settings shows an unknown flag as neither ticked nor clear, and Save is refused (before anything is written) until the user picks'
    # The key box copy guard: the key box is the one TextBox the guard is given, and the guard's -Copy is the Copy button's own key-only call.
    $connectFunction = @($uiTree.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'ShowConnectDialog' }, $true))
    $guardCalls = @(); $keyBoxCreations = @(); $shownKeyAssigns = @()
    if ($connectFunction.Count -eq 1) {
        $guardCalls = @($connectFunction[0].FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Register-FastLlmUiKeyBoxCopyGuard' }, $true))
        $keyBoxCreations = @($connectFunction[0].FindAll({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$keyBox' -and $node.Right.Extent.Text -ceq 'New-Object Windows.Forms.TextBox' }, $true))
        $shownKeyAssigns = @($connectFunction[0].FindAll({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Right.Extent.Text -ceq '$shownKey' }, $true))
    }
    $guardTextBox = ''; $guardCopyText = ''
    if ($guardCalls.Count -eq 1) {
        $guardElements = @($guardCalls[0].CommandElements)
        for ($ge = 0; $ge -lt $guardElements.Count - 1; $ge++) {
            if ($guardElements[$ge] -is [Management.Automation.Language.CommandParameterAst]) {
                if ($guardElements[$ge].ParameterName -ceq 'TextBox') { $guardTextBox = $guardElements[$ge + 1].Extent.Text }
                if ($guardElements[$ge].ParameterName -ceq 'Copy' -and $guardElements[$ge + 1] -is [Management.Automation.Language.ScriptBlockExpressionAst]) { $guardCopyText = ($guardElements[$ge + 1].ScriptBlock.EndBlock.Statements | ForEach-Object { [string]$_.Extent.Text }) -join ' | ' }
            }
        }
    }
    $keyCopyLine = '[void](Invoke-FastLlmUiKeyCopy -KeyOnly -ReadKey {ReadUiApiKey} -SetClipboard {param($Payload) SetUiClipboardPayload $Payload} -SetStatus {param($Text) $statusLabel.Text=[string]$Text})'
    Check ($connectFunction.Count -eq 1 -and $guardCalls.Count -eq 1 -and $keyBoxCreations.Count -eq 1 -and $guardTextBox -ceq '$keyBox' -and @($shownKeyAssigns | Where-Object { $_.Left.Extent.Text -ceq '$keyBox.Text' }).Count -eq 1 -and @([regex]::Matches($uiSource, 'Register-FastLlmUiKeyBoxCopyGuard')).Count -eq 1) 'window (copy guard): the key box - the one text box Show fills with the key - is passed to Register-FastLlmUiKeyBoxCopyGuard, once, and nothing else is'
    Check ($guardCopyText -ceq $keyCopyLine -and @([regex]::Matches($uiSource, [regex]::Escape($keyCopyLine))).Count -eq 2) 'window (copy guard): the guard copies through the exclusion path - its -Copy is exactly the Copy button''s own key-only call, and there are no other key copies'
    $guardTree = Get-SourceTree 'src/FastLlm.ConnectInfo.ps1'
    $guardFunction = @($guardTree.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Register-FastLlmUiKeyBoxCopyGuard' }, $true))
    $guardBody = ''; if ($guardFunction.Count -eq 1) { $guardBody = [string]$guardFunction[0].Body.Extent.Text }
    Check ($guardFunction.Count -eq 1 -and $guardBody.Contains('$TextBox.ShortcutsEnabled = $false') -and $guardBody -cnotmatch 'Clipboard|SetText|GetNewClosure' -and @([regex]::Matches($guardBody, '& \$sender\.Tag')).Count -eq 2 -and $guardBody.Contains('$e.SuppressKeyPress = $true') -and $guardBody.Contains("-ceq 'C'") -and $guardBody.Contains("-ceq 'Insert'")) 'window (copy guard): the guard turns the native copy off (ShortcutsEnabled = $false), writes nothing to the clipboard itself and only runs the block it was given (Ctrl+C, Ctrl+Insert, its menu item)'
    if ($isWindowsHost) {
        Add-Type -AssemblyName System.Windows.Forms
        $guardBox = New-Object System.Windows.Forms.TextBox
        $script:guardPayloads = New-Object 'System.Collections.Generic.List[object]'
        $guardCopy = { [void](Invoke-FastLlmUiKeyCopy -KeyOnly -ReadKey { $marker } -SetClipboard { param($Payload) $script:guardPayloads.Add($Payload) } -SetStatus { param($Text) }) }
        Check ($guardBox.ShortcutsEnabled -eq $true) 'copy guard (Windows): a new text box has its native copy on'
        Register-FastLlmUiKeyBoxCopyGuard -TextBox $guardBox -Copy $guardCopy
        $keyDownMethod = [System.Windows.Forms.Control].GetMethod('OnKeyDown', [Reflection.BindingFlags]'NonPublic,Instance')
        # Reflection's Invoke needs the raw objects: New-Object output and array elements stay PSObject-wrapped and do not convert.
        function Send-GuardKey($Keys) {
            $keyArgs = [System.Windows.Forms.KeyEventArgs]::new([System.Windows.Forms.Keys]$Keys)
            [void]$keyDownMethod.Invoke($guardBox.psobject.BaseObject, [object[]]@($keyArgs.psobject.BaseObject))
            return $keyArgs
        }
        $ctrl = [System.Windows.Forms.Keys]::Control
        Check ($guardBox.ShortcutsEnabled -eq $false) 'copy guard (Windows): the guard turns the text box''s native copy off (ShortcutsEnabled is false)'
        $guardArgs = Send-GuardKey ($ctrl -bor [System.Windows.Forms.Keys]::C)
        Check ($script:guardPayloads.Count -eq 1 -and $guardArgs.Handled -and $guardArgs.SuppressKeyPress) 'copy guard (Windows): Ctrl+C runs the copy once and is handled and suppressed'
        $guardArgs = Send-GuardKey ($ctrl -bor [System.Windows.Forms.Keys]::Insert)
        Check ($script:guardPayloads.Count -eq 2 -and $guardArgs.Handled -and $guardArgs.SuppressKeyPress) 'copy guard (Windows): Ctrl+Insert runs the copy once and is handled and suppressed'
        $guardArgs = Send-GuardKey ([System.Windows.Forms.Keys]::C)
        $guardArgs2 = Send-GuardKey ($ctrl -bor [System.Windows.Forms.Keys]::V)
        $guardArgs3 = Send-GuardKey ($ctrl -bor [System.Windows.Forms.Keys]::Shift -bor [System.Windows.Forms.Keys]::C)
        Check ($script:guardPayloads.Count -eq 2 -and -not $guardArgs.Handled -and -not $guardArgs2.Handled -and -not $guardArgs3.Handled) 'copy guard (Windows): C alone, Ctrl+V and Ctrl+Shift+C do not copy'
        $guardMenu = $guardBox.ContextMenuStrip
        Check ($null -ne $guardMenu -and $guardMenu.Items.Count -eq 1 -and [string]$guardMenu.Items[0].Text -ceq 'Copy') 'copy guard (Windows): the box has its own menu, with one Copy item'
        $guardMenu.Items[0].PerformClick()
        Check ($script:guardPayloads.Count -eq 3) 'copy guard (Windows): the menu''s Copy item runs the copy once'
        # The Copy button's path: the same call, so the same payload. All three copies carry the key and the three exclusion formats.
        $buttonPayloads = New-Object 'System.Collections.Generic.List[object]'
        [void](Invoke-FastLlmUiKeyCopy -KeyOnly -ReadKey { $marker } -SetClipboard { param($Payload) $buttonPayloads.Add($Payload) } -SetStatus { param($Text) })
        $describe = { param($Payload) (([string]$Payload.text) + '|' + ((@($Payload.formats.Keys) | ForEach-Object { $_ + '=' + (@($Payload.formats[$_]) -join ',') }) -join ';')) }
        $buttonShape = & $describe $buttonPayloads[0]
        Check ($buttonPayloads.Count -eq 1 -and ($script:guardPayloads | ForEach-Object { (& $describe $_) -ceq $buttonShape }) -notcontains $false -and [string]$buttonPayloads[0].text -ceq $marker -and (@($buttonPayloads[0].formats.Keys) -join ',') -ceq 'ExcludeClipboardContentFromMonitorProcessing,CanIncludeInClipboardHistory,CanUploadToCloudClipboard' -and (@($buttonPayloads[0].formats['ExcludeClipboardContentFromMonitorProcessing']) -join ',') -ceq '1,0,0,0') 'copy guard (Windows): Ctrl+C, Ctrl+Insert, the menu and the Copy button put the same payload on the clipboard - the key with the three exclusion formats'
        $guardBox.Dispose()
    }
    Check ($uiSource -notmatch '(?i)\.Tag\s*=[^;\r\n]*(ReadUiApiKey|Get-FastLlmApiKeyForDisplay)' -and $uiSource -notmatch '(?i)\$script:[A-Za-z]*\s*=\s*\(?\s*(ReadUiApiKey|Get-FastLlmApiKeyForDisplay)') 'window: the key is never kept in a control tag or a window-wide variable'
    $apiKeyFailureAt = $uiSource.IndexOf('if(Test-FastLlmUiApiKeyFailure -Code $failureCode){')
    $retryAt = $uiSource.IndexOf("`$script:flow=Move-FastLlmUiFlow -Flow `$script:flow -Event 'serving-failed'")
    Check ($apiKeyFailureAt -gt 0 -and $retryAt -gt $apiKeyFailureAt) 'window: an API key failure is handled before the retry path of a failed start (it is never retried)'
    Check ($uiSource.Contains('-IdleStopMinutes $IdleStop -UseApiKey $KeyFlag -SwitchAllowed:$SwitchAllowed -NoWait') -and $uiSource.Contains('$Request.idleStopMinutes $Request.apiKey ([bool]($Request.PSObject.Properties[''allowSwitch'']')) 'window: Start in background hands the flag to the background host'
    $backgroundText = . { . (Join-Path $root 'src/FastLlm.UiBackground.ps1'); $bgState = New-FastLlmUiBackgroundState; $bgState.observation = [pscustomobject]@{ occupied = $false; phase = 'stale'; requestId = ('a' * 32); failureCode = 'api-key-unavailable'; failureReason = 'x'; attachable = $false }; Get-FastLlmUiBackgroundText -State $bgState }
    Check ([string]$backgroundText -cmatch 'stored key cannot be read' -and [string]$backgroundText -cmatch 'Create a new key') 'window: a background run that ended on api-key-unavailable says so and names the action'

    # ================= the background host =================
    $hostSource = [IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.BackgroundHost.ps1'))
    Check ($hostSource.Contains("if (`$UseApiKey -ceq 'on') { `$request.apiKey = 'on' }") -and $hostSource -cnotmatch 'request\.[A-Za-z]*[Kk]ey\s*=(?!\s*''on'')' -and $hostSource.Contains("[ValidateSet('off','on')][string]`$UseApiKey='off'")) 'background: the request file carries only apiKey on, and only when the key is on'
    Check ($hostSource.Contains("if (`$UseApiKey -ceq 'on') { Assert-FastLlmApiKeyStore -InstallRoot `$install }") -and $hostSource.IndexOf('Assert-FastLlmApiKeyStore -InstallRoot $install') -lt $hostSource.IndexOf('Write-FastLlmBackgroundDocument -Path $requestPath -Value $request -CreateNew')) 'background: a store that cannot be read is refused before the request is written or the host is started'
    Check ($hostSource.Contains("throw 'Background request apiKey is invalid.'") -and $hostSource.Contains("if (`$requestedApiKey -ceq 'on') { `$serverOptions.ApiKey = 'on' }") -and $hostSource -cnotmatch 'Read-FastLlmApiKeyStore|Get-FastLlmApiKeyForDisplay|ApiKeyHolder') 'background: the host reads the flag strictly and passes only the flag on; the store is read inside the start, in the host process'
    Check ($hostSource.Contains('$failureText = ConvertTo-FastLlmKeyFreeText -Text ([ref] $failureText)') -and $hostSource.IndexOf('$failureText = ConvertTo-FastLlmKeyFreeText -Text ([ref] $failureText)') -lt $hostSource.IndexOf('$record.failureReason = ')) 'W2: the failure text of the background record passes the scrub before it is recorded'
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

    # ---- the background start checks the key store before it writes a request or launches anything ----
    # The real Start-FastLlmBackgroundHost runs here with its Windows-only checks and its status read replaced, and with a request writer
    # that records the request and stops there: nothing is ever launched by this test, whatever the function does.
    function Invoke-BackgroundStartProbe([string]$InstallRoot, [string]$KeyFlag) {
        $script:backgroundProbe = New-Object 'System.Collections.Generic.List[object]'
        $probeFailure = Get-Failure { & {
                . (Join-Path $root 'src/FastLlm.BackgroundHost.ps1')
                function Assert-FastLlmBackgroundNativeHost { }
                function Assert-FastLlmBackgroundPrivateState { param($InstallRoot) }
                function Get-FastLlmBackgroundHostStatus { param($InstallRoot, $SourceRoot) return [pscustomobject]@{ occupied = $false } }
                function Get-FastLlmBackgroundSourcePins { param($SourceRoot) return @{} }
                function Write-FastLlmBackgroundDocument { param($Path, $Value, [switch]$CreateNew) $script:backgroundProbe.Add($Value); throw 'background-start-probe: the request was written; this test launches nothing' }
                Start-FastLlmBackgroundHost -SourceRoot $root -InstallRoot $InstallRoot -UseApiKey $KeyFlag -NoWait
            } }
        return [pscustomobject]@{ failure = $probeFailure; requests = @($script:backgroundProbe.ToArray()) }
    }
    $backgroundLost = New-Dir 'background-start-unreadable'
    [IO.File]::WriteAllBytes((Join-Path $backgroundLost 'api-key.dat'), [byte[]](1, 2, 3, 4, 5, 6, 7, 8))
    $lostStart = Invoke-BackgroundStartProbe $backgroundLost 'on'
    Check ($null -ne $lostStart.failure -and [string]$lostStart.failure.Exception.Data['FastLlmFailureCode'] -ceq 'api-key-unavailable' -and $lostStart.requests.Count -eq 0 -and @(Get-ChildItem -LiteralPath $backgroundLost -Recurse -File -Force | Where-Object { $_.Name -clike 'background-request-*' }).Count -eq 0) 'background start: with the key on and a store that cannot be read it is refused (api-key-unavailable) before any request is written or anything is launched'
    $backgroundMissing = New-Dir 'background-start-missing'
    $missingStart = Invoke-BackgroundStartProbe $backgroundMissing 'on'
    Check ($null -ne $missingStart.failure -and [string]$missingStart.failure.Exception.Data['FastLlmFailureCode'] -ceq 'api-key-unavailable' -and $missingStart.requests.Count -eq 0) 'background start: with the key on and no store it is refused the same way'
    $backgroundReadable = New-Dir 'background-start-readable'
    InModule { param($R, $K) Write-FastLlmApiKeyStore -InstallRoot $R -ApiKeyHolder $K } @($backgroundReadable, $markerHolder)
    $readableStart = Invoke-BackgroundStartProbe $backgroundReadable 'on'
    Check ($readableStart.requests.Count -eq 1 -and [string]$readableStart.requests[0].apiKey -ceq 'on' -and [string]$readableStart.failure.Exception.Message -clike 'background-start-probe:*' -and (Test-NoLeak (ConvertTo-Json -InputObject $readableStart.requests[0] -Depth 6))) 'background start: with a readable store the request is written with apiKey on, and holds no key'
    $offStart = Invoke-BackgroundStartProbe $backgroundLost 'off'
    Check ($offStart.requests.Count -eq 1 -and -not $offStart.requests[0].Contains('apiKey')) 'background start: without the key the store is not consulted, and the request has no apiKey field (the document it always was)'

    # ================= M2: nothing on the key path is handed to PowerShell as a loggable value =================
    # PowerShell module logging records every bound parameter value of a module's functions and of cmdlets, and writes an array element
    # by element. So no function may take key material as a [string], [char[]] or [byte[]] parameter, and no cmdlet may be given key text.
    # Static part: every function in FastLlm.ApiKey.ps1, and the call sites in the files that handle key material.
    function Get-ParameterTypeName($Parameter) {
        $types = @($Parameter.Attributes | Where-Object { $_ -is [Management.Automation.Language.TypeConstraintAst] } | ForEach-Object { $_.TypeName.FullName })
        if ($types.Count -eq 0) { return '' }
        return ($types -join ',')
    }
    $keyTree = Get-SourceTree 'src/FastLlm.ApiKey.ps1'
    $keyFunctions = @($keyTree.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))
    $keyParameters = New-Object 'System.Collections.Generic.List[string]'
    foreach ($keyFunction in $keyFunctions) {
        $declared = @()
        if ($keyFunction.Body.ParamBlock) { $declared = @($keyFunction.Body.ParamBlock.Parameters) }
        elseif ($keyFunction.Parameters) { $declared = @($keyFunction.Parameters) }
        foreach ($parameter in $declared) { $keyParameters.Add($keyFunction.Name + ' ' + $parameter.Name.VariablePath.UserPath + ' ' + (Get-ParameterTypeName $parameter)) }
    }
    # Every parameter of every function in the file, by its declared type. A new parameter fails this list until it is classified here.
    $expectedKeyParameters = @(
        'New-FastLlmApiKeyFailure Code string', 'New-FastLlmApiKeyFailure Message string',
        'ConvertTo-FastLlmApiKeyHolder Chars ref',
        'Get-FastLlmApiKeyText ApiKeyHolder ',
        'Get-FastLlmApiKeyId ApiKeyHolder ',
        'Protect-FastLlmApiKey ApiKeyHolder ',
        'ConvertFrom-FastLlmApiKeyProtected Protected ref',
        'Unprotect-FastLlmApiKey Bytes byte[]',
        'Get-FastLlmApiKeyStorePath InstallRoot string',
        'Write-FastLlmApiKeyStore InstallRoot string', 'Write-FastLlmApiKeyStore ApiKeyHolder ',
        'Read-FastLlmApiKeyStore InstallRoot string',
        'Get-FastLlmApiKeyEnforcement WithoutKeyStatus int', 'Get-FastLlmApiKeyEnforcement WithKeyStatus int',
        'Get-FastLlmApiKeyStoreState InstallRoot string', 'Assert-FastLlmApiKeyStore InstallRoot string', 'New-FastLlmApiKeyStoreEntry InstallRoot string',
        'Initialize-FastLlmApiKeyStore InstallRoot string', 'Reset-FastLlmApiKeyStore InstallRoot string', 'Get-FastLlmApiKeyForDisplay InstallRoot string',
        'ConvertTo-FastLlmKeyFreeText Text ref', 'ConvertTo-FastLlmKeyFreeText ApiKeyHolder ', 'ConvertTo-FastLlmKeyFreeText Structured switch',
        'Get-FastLlmApiKeyListenerOwners Port int',
        'Get-FastLlmApiKeyListenerVerdict BaseUrl string', 'Get-FastLlmApiKeyListenerVerdict ServerIdentity ',
        'Assert-FastLlmApiKeyListener BaseUrl string', 'Assert-FastLlmApiKeyListener ServerIdentity ',
        'Assert-FastLlmApiKeyListenerAfterSend BaseUrl string', 'Assert-FastLlmApiKeyListenerAfterSend ServerIdentity ', 'Assert-FastLlmApiKeyListenerAfterSend Answered switch'
    )
    $unexpectedParameters = @($keyParameters | Where-Object { $expectedKeyParameters -cnotcontains $_ })
    $missingParameters = @($expectedKeyParameters | Where-Object { $keyParameters -cnotcontains $_ })
    Check ($keyFunctions.Count -eq 23 -and $unexpectedParameters.Count -eq 0 -and $missingParameters.Count -eq 0) "M2 static: every parameter of every function in FastLlm.ApiKey.ps1 ($($keyFunctions.Count) functions) is the one listed: the key travels in an untyped holder or a [ref] (unexpected: $($unexpectedParameters -join '; '); missing: $($missingParameters -join '; '))"
    # The text-typed and array-typed parameters that remain: an error code and fixed message, a folder, a URL - and the one [byte[]], which
    # is the PROTECTED store form on a function nothing in the product calls (the start reads the store through a [ref]).
    $loggable = @($keyParameters | Where-Object { $_ -cmatch ' (string|string\[\]|char\[\]|byte\[\]|object\[\]|object|array|char)$' -or $_ -cmatch '\[\]$' })
    Check (($loggable -join '; ') -ceq 'New-FastLlmApiKeyFailure Code string; New-FastLlmApiKeyFailure Message string; Unprotect-FastLlmApiKey Bytes byte[]; Get-FastLlmApiKeyStorePath InstallRoot string; Write-FastLlmApiKeyStore InstallRoot string; Read-FastLlmApiKeyStore InstallRoot string; Get-FastLlmApiKeyStoreState InstallRoot string; Assert-FastLlmApiKeyStore InstallRoot string; New-FastLlmApiKeyStoreEntry InstallRoot string; Initialize-FastLlmApiKeyStore InstallRoot string; Reset-FastLlmApiKeyStore InstallRoot string; Get-FastLlmApiKeyForDisplay InstallRoot string; Get-FastLlmApiKeyListenerVerdict BaseUrl string; Assert-FastLlmApiKeyListener BaseUrl string; Assert-FastLlmApiKeyListenerAfterSend BaseUrl string') "M2 static: no function in FastLlm.ApiKey.ps1 takes key material as [string], [char[]] or [byte[]]; the text and array parameters are codes, fixed messages, folders and URLs ($($loggable -join '; '))"
    $callSiteFiles = @('fast-llm.ps1', 'fast-llm-ui.ps1', 'src/FastLlm.psm1', 'src/FastLlm.ApiKey.ps1', 'src/FastLlm.Runtime.ps1', 'src/FastLlm.Sidecar.ps1', 'src/FastLlm.RunLog.ps1', 'src/FastLlm.ConnectInfo.ps1', 'src/FastLlm.BackgroundHost.ps1', 'src/FastLlm.ServingSettings.ps1', 'src/FastLlm.UiFlow.ps1', 'src/FastLlm.UiBackground.ps1', 'src/FastLlm.SupportBundle.ps1', 'src/FastLlm.SignInStart.ps1')
    # Every fluent window file is scanned too, as a glob, so a page added later is covered without touching this list.
    $fluentFiles = @(Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter 'FastLlm.UiFluent*.ps1' -File | Sort-Object Name | ForEach-Object { 'src/' + $_.Name })
    $callSiteFiles = @($callSiteFiles) + $fluentFiles
    $byReference = @{ 'ConvertTo-FastLlmKeyFreeText' = 'Text'; 'ConvertTo-FastLlmApiKeyHolder' = 'Chars'; 'ConvertFrom-FastLlmApiKeyProtected' = 'Protected'; 'Get-FastLlmConnectCopyText' = 'Key' }
    $keyTextSources = @('Get-FastLlmApiKeyText', 'Get-FastLlmApiKeyForDisplay', 'ReadUiApiKey')
    $referenceCalls = 0; $sourceCalls = 0
    $callProblems = New-Object 'System.Collections.Generic.List[string]'
    foreach ($callSiteFile in $callSiteFiles) {
        $callTree = Get-SourceTree $callSiteFile
        foreach ($command in @($callTree.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true))) {
            $commandName = [string]$command.GetCommandName()
            if ($byReference.ContainsKey($commandName)) {
                # The argument after the named parameter must be ([ref] $variable): a parenthesised conversion to [ref].
                $elements = @($command.CommandElements)
                for ($index = 1; $index -lt $elements.Count; $index++) {
                    if ($elements[$index] -is [Management.Automation.Language.CommandParameterAst] -and $elements[$index].ParameterName -ieq $byReference[$commandName]) {
                        $referenceCalls++
                        $argument = $null
                        if ($index + 1 -lt $elements.Count) { $argument = $elements[$index + 1] }
                        $isReference = ($argument -is [Management.Automation.Language.ParenExpressionAst] -and $argument.Extent.Text -cmatch '^\(\s*\[ref\]\s*\$[A-Za-z_][A-Za-z0-9_]*\s*\)$')
                        if (-not $isReference) { $callProblems.Add("${callSiteFile}:$($command.Extent.StartLineNumber) $commandName -$($byReference[$commandName]) is not ([ref] `$variable)") }
                    }
                }
            }
            if ($keyTextSources -icontains $commandName) {
                # What these return is the key as text. It may be assigned, returned or handed to a .NET method; it must never be an
                # argument of another command, nor flow on through a pipeline (a cmdlet's input is logged).
                $sourceCalls++
                $node = $command
                while ($null -ne $node.Parent) {
                    $parent = $node.Parent
                    if ($parent -is [Management.Automation.Language.PipelineAst] -and @($parent.PipelineElements).Count -gt 1) { $callProblems.Add("${callSiteFile}:$($command.Extent.StartLineNumber) the result of $commandName flows through a pipeline"); break }
                    if ($parent -is [Management.Automation.Language.CommandAst]) { $callProblems.Add("${callSiteFile}:$($command.Extent.StartLineNumber) the result of $commandName is an argument of $($parent.GetCommandName())"); break }
                    if ($parent -is [Management.Automation.Language.ScriptBlockAst] -or $parent -is [Management.Automation.Language.NamedBlockAst] -or $parent -is [Management.Automation.Language.StatementBlockAst]) { break }
                    $node = $parent
                }
            }
        }
    }
    Check ($callProblems.Count -eq 0 -and $referenceCalls -ge 14 -and $sourceCalls -ge 9) "M2 static: at every call site (fast-llm.ps1, the window, the module, Runtime, ConnectInfo and the rest) text that may hold the key is passed inside a [ref] ($referenceCalls calls), and the key as text is never an argument or pipeline input of a command ($sourceCalls uses) $($callProblems -join '; ')"
    # The fluent window block. Every key name starts at zero uses in every fluent file; the Connect page's exact read sites are set (RED
    # first) when that page is written. The classic window: checks read only fast-llm-ui.ps1 and are not changed here.
    $fluentKeyNames = @('ReadUiApiKey', 'Get-FastLlmApiKeyForDisplay', 'Get-FastLlmApiKeyText', 'Invoke-FastLlmUiKeyCopy', 'SetUiClipboardPayload', 'shownKey', 'PasswordBox', 'SetDataObject')
    # Every key-name pattern is case-insensitive: PowerShell command and variable names are, so a lower-case spelling is the same use.
    $fluentNamePattern = '(?i)(?<![A-Za-z0-9_-])(' + (($fluentKeyNames | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')(?![A-Za-z0-9_-])'
    $fluentSourcePattern = '(?i)(?<![A-Za-z0-9_-])(ReadUiApiKey|Get-FastLlmApiKeyForDisplay|Get-FastLlmApiKeyText)(?![A-Za-z0-9_-])'
    $fluentSinkPattern = '(?i)(\.Tag\s*=|\$script:[A-Za-z_][A-Za-z0-9_]*\s*=|SetName|SetHelpText|\.ToolTip\s*=|Clipboard\]::SetText\s*\()'
    $fluentSourceNames = '(?i)^(' + (($keyTextSources | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')$'
    $fluentWordPattern = { param([string]$Word) '(?i)(?<![A-Za-z0-9_-])' + [regex]::Escape($Word) + '(?![A-Za-z0-9_-])' }
    # Problems in one fluent-shaped text, each starting with its kind in brackets, so a self-check can name the rule that caught it:
    #   name        a key name at all (skipped with -NoNameRule, and with -AllowNames for the Connect page)
    #   sink        a key source and a sink on one line
    #   argument    a key source as a command argument
    #   pipeline    a key source as pipeline input
    #   method      a key source (or a variable holding one) as a method argument, such as SetValue(...)
    #   flow        a variable that holds a key source reaching a command, method, pipeline, sink variable or any control but the key box
    #   textcopy    a read of the key box's Text (a Text to Text copy)
    #   passwordbox a PasswordBox; copy the copy routine or the clipboard hand-over (skipped with -AllowNames); setdataobject SetDataObject
    function Get-FluentKeyProblems([string]$Label, [string]$Text, [switch]$AllowNames, [switch]$NoNameRule, [switch]$ConnectPage) {
        $found = New-Object 'System.Collections.Generic.List[string]'
        if (-not ($AllowNames -or $NoNameRule)) { foreach ($match in [regex]::Matches($Text, $fluentNamePattern)) { $found.Add("[name] $Label uses $($match.Value)") } }
        if ($Text -match (& $fluentWordPattern 'PasswordBox')) { $found.Add("[passwordbox] $Label has a PasswordBox") }
        if ($Text -match (& $fluentWordPattern 'SetDataObject')) { $found.Add("[setdataobject] $Label uses SetDataObject") }
        if (-not $AllowNames -and ($Text -match (& $fluentWordPattern 'Invoke-FastLlmUiKeyCopy') -or $Text -match (& $fluentWordPattern 'SetUiClipboardPayload'))) { $found.Add("[copy] $Label uses the key copy routine or the clipboard hand-over") }
        foreach ($line in @($Text -split "`r?`n")) { if ($line -match $fluentSourcePattern -and $line -match $fluentSinkPattern) { $found.Add("[sink] $Label gives a key source to a sink: $($line.Trim())") } }
        $parseErrors = $null; $parseTokens = $null
        $parsed = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$parseTokens, [ref]$parseErrors)
        if (@($parseErrors).Count -eq 0) {
            $isSource = { param($node) $node -is [Management.Automation.Language.CommandAst] -and [string]$node.GetCommandName() -match $fluentSourceNames }
            foreach ($command in @($parsed.FindAll($isSource, $true))) {
                $node = $command
                while ($null -ne $node.Parent) {
                    $parent = $node.Parent
                    if ($parent -is [Management.Automation.Language.PipelineAst] -and @($parent.PipelineElements).Count -gt 1) { $found.Add("[pipeline] $Label key source flows through a pipeline"); break }
                    if ($parent -is [Management.Automation.Language.CommandAst]) { $found.Add("[argument] $Label key source is an argument of $($parent.GetCommandName())"); break }
                    if ($parent -is [Management.Automation.Language.InvokeMemberExpressionAst] -and @($parent.Arguments) -contains $node) { $found.Add("[method] $Label key source is an argument of the method $($parent.Member.Extent.Text)"); break }
                    if ($parent -is [Management.Automation.Language.ScriptBlockAst] -or $parent -is [Management.Automation.Language.NamedBlockAst] -or $parent -is [Management.Automation.Language.StatementBlockAst]) { break }
                    $node = $parent
                }
            }
            # Variables that hold a key source (a source command not inside a script block on the right of an assignment), then every use of them.
            $held = @{}
            $assignments = @($parsed.FindAll({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] }, $true))
            for ($round = 0; $round -lt 4; $round++) {
                foreach ($assignment in $assignments) {
                    if ($assignment.Left -isnot [Management.Automation.Language.VariableExpressionAst]) { continue }
                    $name = $assignment.Left.VariablePath.UserPath.ToLowerInvariant()
                    $carries = @($assignment.Right.FindAll({ param($node) (& $isSource $node) -or ($node -is [Management.Automation.Language.VariableExpressionAst] -and $held.ContainsKey($node.VariablePath.UserPath.ToLowerInvariant())) }, $true)).Count -gt 0
                    if ($carries) { $held[$name] = $true }
                }
            }
            # A key source on the right of an assignment to anything but a plain variable (a control's Text, a property, an element) is a flow of its own.
            foreach ($assignment in $assignments) {
                if ($assignment.Left -is [Management.Automation.Language.VariableExpressionAst]) { continue }
                if (@($assignment.Right.FindAll($isSource, $true)).Count -gt 0) { $found.Add("[flow] $Label a key source is assigned to $($assignment.Left.Extent.Text)") }
            }
            foreach ($use in @($parsed.FindAll({ param($node) $node -is [Management.Automation.Language.VariableExpressionAst] -and $held.ContainsKey($node.VariablePath.UserPath.ToLowerInvariant()) }, $true))) {
                $node = $use
                while ($null -ne $node.Parent) {
                    $parent = $node.Parent
                    if ($parent -is [Management.Automation.Language.AssignmentStatementAst]) {
                        if ([object]::ReferenceEquals($parent.Left, $node)) { break }
                        if ($parent.Left -is [Management.Automation.Language.VariableExpressionAst]) {
                            if ($parent.Left.VariablePath.UserPath -match '^(?i)(script|global):') { $found.Add("[flow] $Label a variable holding the key reaches a window-wide variable: $($parent.Extent.Text.Trim())") }
                        }
                        elseif (-not ($ConnectPage -and $parent.Extent.Text -ceq '$keyBox.Text=$shownKey')) { $found.Add("[flow] $Label a variable holding the key reaches $($parent.Left.Extent.Text)") }
                        break
                    }
                    if ($parent -is [Management.Automation.Language.CommandAst]) { $found.Add("[flow] $Label a variable holding the key is an argument of $($parent.GetCommandName())"); break }
                    if ($parent -is [Management.Automation.Language.InvokeMemberExpressionAst] -and @($parent.Arguments) -contains $node) { $found.Add("[method] $Label a variable holding the key is an argument of the method $($parent.Member.Extent.Text)"); break }
                    if ($parent -is [Management.Automation.Language.PipelineAst] -and @($parent.PipelineElements).Count -gt 1) { $found.Add("[flow] $Label a variable holding the key flows through a pipeline"); break }
                    if ($parent -is [Management.Automation.Language.ScriptBlockAst] -or $parent -is [Management.Automation.Language.NamedBlockAst] -or $parent -is [Management.Automation.Language.StatementBlockAst]) { break }
                    $node = $parent
                }
            }
            # A read of the key box's Text (not the write of it) copies the key to wherever the value goes.
            foreach ($member in @($parsed.FindAll({ param($node) $node -is [Management.Automation.Language.MemberExpressionAst] -and $node -isnot [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Extent.Text -ieq 'Text' -and $node.Expression.Extent.Text -match '(?i)keybox|shownkey' }, $true))) {
                if ($member.Parent -is [Management.Automation.Language.AssignmentStatementAst] -and [object]::ReferenceEquals($member.Parent.Left, $member)) { continue }
                $found.Add("[textcopy] $Label reads the key box text: $($member.Parent.Extent.Text.Trim())")
            }
        }
        else { $found.Add("[parse] $Label does not parse, so the syntax rules could not run: $(@($parseErrors)[0].Message)") }
        return $found.ToArray()
    }
    $fluentProblems = New-Object 'System.Collections.Generic.List[string]'
    $connectFile = 'src/FastLlm.UiFluentConnect.ps1'
    foreach ($fluentFile in $fluentFiles) {
        # The Connect page is the one file that may use the key names; its exact sites are pinned below. Every other fluent file has none.
        $allowNames = ($fluentFile -ceq $connectFile)
        foreach ($problem in @(Get-FluentKeyProblems $fluentFile ([IO.File]::ReadAllText((Join-Path $root $fluentFile))) -AllowNames:$allowNames -ConnectPage:$allowNames)) { $fluentProblems.Add($problem) }
    }
    Check ($fluentFiles.Count -ge 8 -and $fluentProblems.Count -eq 0) "fluent window: the call-site scan covers $($fluentFiles.Count) src/FastLlm.UiFluent*.ps1 files, and no key name (ReadUiApiKey, Get-FastLlmApiKeyForDisplay, Get-FastLlmApiKeyText, Invoke-FastLlmUiKeyCopy, SetUiClipboardPayload, `$shownKey, PasswordBox, SetDataObject) is used in any of them $($fluentProblems -join '; ')"
    # Each planted file is scanned with the name rule OFF and must be caught by its own specific rule (the kind in the brackets). The last
    # plants are the shapes a name-only scan would miss on its own: two-line flows, SetValue, a Text to Text copy and lower-case spellings.
    $plantDir = Join-Path $temp 'fluent-planted'
    [void](New-Item -ItemType Directory -Path $plantDir -Force)
    $plantedFiles = [ordered]@{
        'pipeline.ps1'     = @('pipeline', '$x=ReadUiApiKey | Out-String')
        'pipeline-lc.ps1'  = @('pipeline', '$x = readuiapikey | Out-String')
        'argument.ps1'     = @('argument', 'Foo (ReadUiApiKey)')
        'argument-lc.ps1'  = @('argument', 'Foo (get-fastllmapikeytext)')
        'passwordbox.ps1'  = @('passwordbox', '<PasswordBox x:Name="K"/>')
        'tag.ps1'          = @('sink', '$box.Tag = ReadUiApiKey')
        'scriptvar.ps1'    = @('sink', '$script:held = (Get-FastLlmApiKeyForDisplay -InstallRoot $r)')
        'tooltip.ps1'      = @('sink', '$box.ToolTip = (Get-FastLlmApiKeyText)')
        'clipboard.ps1'    = @('sink', '[Windows.Clipboard]::SetText((ReadUiApiKey))')
        'copy.ps1'         = @('copy', '[void](Invoke-FastLlmUiKeyCopy -KeyOnly)')
        'handover.ps1'     = @('copy', '$h = { param($Payload) SetUiClipboardPayload $Payload }')
        'dataobject.ps1'   = @('setdataobject', '[Windows.Clipboard]::SetDataObject($d)')
        'twoline.ps1'      = @('flow', ('$k = ReadUiApiKey' + "`n" + '$box.Tag = $k'))
        'twoline-var.ps1'  = @('flow', ('$k = Get-FastLlmApiKeyText' + "`n" + '$script:held = $k'))
        'twoline-cmd.ps1'  = @('flow', ('$k = ReadUiApiKey' + "`n" + 'Set-Thing -Value $k'))
        'twoline-text.ps1' = @('flow', ('$k = ReadUiApiKey' + "`n" + '$other.Text = $k'))
        'setvalue.ps1'     = @('method', '$el.SetValue($prop, (ReadUiApiKey))')
        'setvalue2.ps1'    = @('method', ('$k = ReadUiApiKey' + "`n" + '$el.SetValue($prop, $k)'))
        'textcopy.ps1'     = @('textcopy', '$other.Text = $keyBox.Text')
        'textcopy2.ps1'    = @('textcopy', '$a.Text = $e[''ConnectKeyBox''].Text')
        'lowercase.ps1'    = @('flow', ('$k = readuiapikey' + "`n" + '$box.tag = $k; set-thing $k'))
    }
    $plantedMissed = New-Object 'System.Collections.Generic.List[string]'
    # Plants scanned the way the Connect page is (names allowed, the one Show line allowed): the reviewer's lower-case direct assignment, and a Text to Text copy.
    $connectPlants = [ordered]@{
        'connect-direct.ps1'  = @('flow', '$keyBox.Text = get-fastllmapikeyfordisplay -InstallRoot $script:installPath')
        'connect-other.ps1'   = @('flow', ('$shownKey=ReadUiApiKey' + "`n" + '$other.Text=$shownKey'))
        'connect-copy.ps1'    = @('textcopy', '$other.Text = $keyBox.Text')
        'connect-broken.ps1'  = @('parse', 'function Broken { $keyBox.Text = ')
    }
    foreach ($plantedName in $connectPlants.Keys) {
        $plantFindings = @(Get-FluentKeyProblems $plantedName ([string]$connectPlants[$plantedName][1]) -AllowNames -ConnectPage)
        if (@($plantFindings | Where-Object { $_.StartsWith("[$($connectPlants[$plantedName][0])] ", [StringComparison]::Ordinal) }).Count -eq 0) { $plantedMissed.Add("$plantedName (wanted $($connectPlants[$plantedName][0]), got: $($plantFindings -join ' / '))") }
    }
    $connectShowOk = @(Get-FluentKeyProblems 'show.ps1' ('$shownKey=ReadUiApiKey' + "`n" + 'if($shownKey){$keyBox.Text=$shownKey}' + "`n" + '$shownKey=$null') -AllowNames -ConnectPage)
    foreach ($plantedName in $plantedFiles.Keys) {
        $plantPath = Join-Path $plantDir $plantedName
        $plantKind = [string]$plantedFiles[$plantedName][0]
        [IO.File]::WriteAllText($plantPath, [string]$plantedFiles[$plantedName][1])
        $plantFindings = @(Get-FluentKeyProblems $plantedName ([IO.File]::ReadAllText($plantPath)) -NoNameRule)
        if (@($plantFindings | Where-Object { $_.StartsWith("[$plantKind] ", [StringComparison]::Ordinal) }).Count -eq 0) { $plantedMissed.Add("$plantedName (wanted $plantKind, got: $($plantFindings -join ' / '))") }
    }
    $nameRuleOn = @(Get-FluentKeyProblems 'name.ps1' '$x = readuiapikey')
    Check ($plantedMissed.Count -eq 0 -and $connectShowOk.Count -eq 0 -and $nameRuleOn.Count -eq 1 -and $nameRuleOn[0].StartsWith('[name] ', [StringComparison]::Ordinal) -and @(Get-FluentKeyProblems 'clean.ps1' 'function Show-Thing { param($Text) $box.Text = $Text }').Count -eq 0) "fluent window self-check: each of $($plantedFiles.Count) planted fluent-shaped files is flagged by its own specific rule with the name rule off (a key piped, as an argument, a PasswordBox, a sink, the clipboard, the copy routine, SetDataObject, two-line flows, SetValue, a Text to Text copy, lower-case spellings), a lower-case name is caught by the name rule, and a clean file is not $($plantedMissed -join '; ')"
    # The Connect page: the key is read by name at exactly three sites (Show and the two hand-overs to the copy routine). The key box's Ctrl+C, Ctrl+Insert
    # and context-menu Copy run the key Copy button's own function, so there is no fourth read and no third copy call site.
    $connectPath = Join-Path $root $connectFile
    $connectText = ''
    if (Test-Path -LiteralPath $connectPath) { $connectText = [IO.File]::ReadAllText($connectPath) }
    $connectNames = @{}
    foreach ($keyName in $fluentKeyNames) { $connectNames[$keyName] = @([regex]::Matches($connectText, '(?i)(?<![A-Za-z0-9_-])' + [regex]::Escape($keyName) + '(?![A-Za-z0-9_-])')).Count }
    $keyCopyText = '[void](Invoke-FastLlmUiKeyCopy -KeyOnly -ReadKey {ReadUiApiKey} -SetClipboard {param($Payload) SetUiClipboardPayload $Payload} -SetStatus {param($Text) $statusLabel.Text=[string]$Text})'
    $cardCopyText = '[void](Invoke-FastLlmUiKeyCopy -Snippet ([string]$Sender.Tag) -ReadKey {ReadUiApiKey} -SetClipboard {param($Payload) SetUiClipboardPayload $Payload} -SetStatus {param($Text) $statusLabel.Text=[string]$Text})'
    Check ($connectNames['ReadUiApiKey'] -eq 3 -and $connectNames['Invoke-FastLlmUiKeyCopy'] -eq 2 -and $connectNames['SetUiClipboardPayload'] -eq 2 -and $connectNames['shownKey'] -eq 4 -and $connectNames['Get-FastLlmApiKeyForDisplay'] -eq 0 -and $connectNames['Get-FastLlmApiKeyText'] -eq 0) "fluent window: Connect reads the key at exactly 3 sites and calls the copy routine at exactly 2, with 2 clipboard hand-overs ($(($fluentKeyNames | ForEach-Object { $_ + '=' + $connectNames[$_] }) -join ', '))"
    Check ($connectText.Contains($keyCopyText) -and $connectText.Contains($cardCopyText) -and @([regex]::Matches($connectText, 'Invoke-FastLlmUiKeyCopy ')).Count -eq 2) 'fluent window: the Key Copy and the Card Copy hand-overs are the exact texts of the classic window (the two copy sites are the only callers)'
    $connectReaders = @($connectText -split "`r?`n" | Where-Object { $_ -match '(?i)(?<![A-Za-z0-9_-])ReadUiApiKey(?![A-Za-z0-9_-])' } | ForEach-Object { $_.Trim() })
    Check ($connectReaders.Count -eq 3 -and @($connectReaders | Where-Object { $_ -ceq $keyCopyText }).Count -eq 1 -and @($connectReaders | Where-Object { $_ -ceq $cardCopyText }).Count -eq 1 -and @($connectReaders | Where-Object { $_ -ceq '$shownKey=ReadUiApiKey' }).Count -eq 1) "fluent window: the key is read in exactly three places, each an exact line - Show, and the two hand-overs ($($connectReaders.Count) lines)"
    $connectShownUses = @([regex]::Matches($connectText, '(?i)\$shownKey\b[^\r\n;{}]*') | ForEach-Object { $_.Value.Trim() })
    Check (($connectShownUses -join ' | ') -ceq '$shownKey=ReadUiApiKey | $shownKey) | $shownKey | $shownKey=$null' -and $connectText.Contains('if($shownKey){$keyBox.Text=$shownKey;')) "fluent window: Show puts the key into the key box and nowhere else, then drops it ($($connectShownUses -join ' | '))"
    # The clipboard hand-over: each -SetClipboard block is one statement, the command SetUiClipboardPayload with the payload; the window's function stays the only one that
    # touches the clipboard object, and the Connect page has no SetDataObject.
    $connectParse = [Management.Automation.Language.Parser]::ParseInput($connectText, [ref]$null, [ref]$null)
    $handOvers = @($connectParse.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and [string]$node.GetCommandName() -ieq 'Invoke-FastLlmUiKeyCopy' }, $true) | ForEach-Object {
        $elements = @($_.CommandElements); $block = $null
        for ($i = 0; $i -lt $elements.Count - 1; $i++) { if ($elements[$i] -is [Management.Automation.Language.CommandParameterAst] -and $elements[$i].ParameterName -ieq 'SetClipboard') { $block = $elements[$i + 1] } }
        if ($block -is [Management.Automation.Language.ScriptBlockExpressionAst]) { @($block.ScriptBlock.EndBlock.Statements | ForEach-Object { [string]$_.Extent.Text }) -join ' || ' } else { 'not a script block' }
    })
    Check ($handOvers.Count -eq 2 -and @($handOvers | Where-Object { $_ -ceq 'SetUiClipboardPayload $Payload' }).Count -eq 2 -and $connectNames['SetUiClipboardPayload'] -eq 2 -and $connectNames['SetDataObject'] -eq 0) "fluent window: SetUiClipboardPayload is the one statement of each of the 2 clipboard hand-overs (2 payload uses), with no SetDataObject in the Connect page (the plain-text wrapper for field Copy buttons is pinned below) ($($handOvers -join ' | '))"
    $keyBoxMarkup = [regex]::Match($connectText, '<TextBox\b[^>]*x:Name="ConnectKeyBox"[^>]*>').Value
    Check ($keyBoxMarkup -cmatch 'IsReadOnly="True"' -and $keyBoxMarkup -cmatch 'IsUndoEnabled="False"' -and $keyBoxMarkup -cnotmatch '\bText\s*=') 'fluent window: the key box is a read-only TextBox with undo off and no Text in the markup'
    $fluentOthers = 0
    foreach ($fluentFile in $fluentFiles) { $t = [IO.File]::ReadAllText((Join-Path $root $fluentFile)); foreach ($zeroName in @('PasswordBox', 'Get-FastLlmApiKeyForDisplay', 'Get-FastLlmApiKeyText', 'SetDataObject')) { $fluentOthers += @([regex]::Matches($t, '(?i)' + [regex]::Escape($zeroName))).Count } }
    Check ($fluentOthers -eq 0) "fluent window: PasswordBox, Get-FastLlmApiKeyForDisplay, Get-FastLlmApiKeyText and SetDataObject stay at 0 in every fluent file ($fluentOthers)"
    $clipboardLines = @($connectText -split "`r?`n" | Where-Object { $_ -cmatch 'Set-FastLlmUiFluentClipboardText' -and $_ -cnotmatch '^\s*function ' })
    Check ($clipboardLines.Count -eq 1 -and $clipboardLines[0] -cmatch '-Text \(\[string\]\$Sender\.Tag\)' -and $clipboardLines[0] -cnotmatch 'ReadUiApiKey|shownKey|keyBox') 'fluent window: the plain clipboard wrapper is called once, with a field Copy button tag, never a key source'
    Check ($connectText.Contains('ApplicationCommands]::Copy') -and $connectText.Contains('Invoke-FastLlmUiFluentConnectKeyCopy')) 'fluent window: the key box Copy command (Ctrl+C, Ctrl+Insert, context menu) is bound and runs the key Copy function'
    $cliTextForShow = [IO.File]::ReadAllText((Join-Path $root 'fast-llm.ps1'))
    Check ($cliTextForShow.Contains('[Console]::Out.WriteLine([string] $apiKeyChange.key)') -and $cliTextForShow -cnotmatch '(?m)^[^#\r\n]*\b(Write-Output|Write-Host|Write-Information|Write-Verbose|Out-String|Out-Host|Out-File|Set-Content|Add-Content|Tee-Object|Set-Clipboard|ConvertTo-Json)\b[^\r\n]*\.key\b') 'M2 static: settings -ApiKey show writes the key straight to standard output; no cmdlet is given it'
    $keySourceText = [IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.ApiKey.ps1'))
    $readStoreBody = [string]@($keyFunctions | Where-Object { $_.Name -ceq 'Read-FastLlmApiKeyStore' })[0].Extent.Text
    Check ($readStoreBody.Contains('ConvertFrom-FastLlmApiKeyProtected -Protected ([ref] $bytes)') -and $readStoreBody -cnotmatch 'Unprotect-FastLlmApiKey' -and @($callSiteFiles | Where-Object { $_ -cne 'src/FastLlm.ApiKey.ps1' -and [IO.File]::ReadAllText((Join-Path $root $_)) -cmatch 'Unprotect-FastLlmApiKey|ConvertTo-FastLlmApiKeyHolder|ConvertFrom-FastLlmApiKeyProtected' }).Count -eq 0) 'M2 static: the store read hands even the protected bytes on inside a [ref]; nothing outside FastLlm.ApiKey.ps1 builds a holder or unprotects'
    # No cmdlet inside the functions that hold the key as text or bytes (a cmdlet would be given it as input).
    $plainHolders = @('ConvertTo-FastLlmApiKeyHolder', 'Get-FastLlmApiKeyText', 'New-FastLlmApiKey', 'Get-FastLlmApiKeyId', 'Protect-FastLlmApiKey', 'ConvertFrom-FastLlmApiKeyProtected', 'Get-FastLlmApiKeyForDisplay')
    $cmdletUses = New-Object 'System.Collections.Generic.List[string]'
    foreach ($keyFunction in @($keyFunctions | Where-Object { $plainHolders -ccontains $_.Name })) {
        foreach ($command in @($keyFunction.Body.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true))) {
            $usedName = [string]$command.GetCommandName()
            if ($usedName -and $usedName -cnotin @('New-FastLlmApiKeyFailure', 'Get-FastLlmApiKeyText', 'ConvertTo-FastLlmApiKeyHolder', 'Read-FastLlmApiKeyStore', 'Add-Type')) { $cmdletUses.Add($keyFunction.Name + ' uses ' + $usedName) }
        }
    }
    Check ($cmdletUses.Count -eq 0) "M2 static: the functions that hold the key as text or bytes call no cmdlet with it (only their own typed-failure, holder and store functions) $($cmdletUses -join '; ')"
    # The text of a key failure is fixed text. New-FastLlmApiKeyFailure takes its code and message as plain strings (they are fixed, so
    # they may be logged); what must never happen is a message built from a value - the key, part of it, or an error text that could
    # echo it. So at every call, in every file, -Code is a literal api-key code and -Message is a string literal, or a literal with
    # nothing inserted but the two HTTP status numbers of the proof.
    $failureCalls = 0
    $failureProblems = New-Object 'System.Collections.Generic.List[string]'
    foreach ($callSiteFile in $callSiteFiles) {
        $failureTree = Get-SourceTree $callSiteFile
        foreach ($command in @($failureTree.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and [string]$node.GetCommandName() -ceq 'New-FastLlmApiKeyFailure' }, $true))) {
            $failureCalls++
            $where = "${callSiteFile}:$($command.Extent.StartLineNumber)"
            $elements = @($command.CommandElements)
            $named = @{}
            for ($index = 1; $index -lt $elements.Count; $index++) {
                if ($elements[$index] -is [Management.Automation.Language.CommandParameterAst] -and $index + 1 -lt $elements.Count) { $named[[string]$elements[$index].ParameterName] = $elements[$index + 1]; $index++ }
                else { $failureProblems.Add("$where has an argument that is not -Code or -Message with a value") }
            }
            if ((@($named.Keys | Sort-Object) -join ',') -cne 'Code,Message') { $failureProblems.Add("$where does not pass exactly -Code and -Message"); continue }
            $codeArgument = $named['Code']
            if (-not ($codeArgument -is [Management.Automation.Language.StringConstantExpressionAst] -and [string]$codeArgument.Value -cmatch '^api-key-[a-z-]{1,40}$')) { $failureProblems.Add("$where -Code is not a literal api-key code") }
            $messageArgument = $named['Message']
            if ($messageArgument -is [Management.Automation.Language.StringConstantExpressionAst]) { continue }
            if ($messageArgument -is [Management.Automation.Language.ExpandableStringExpressionAst]) {
                $inserted = @($messageArgument.NestedExpressions | ForEach-Object { [string]$_.Extent.Text })
                if (@($inserted | Where-Object { $_ -cnotin @('$proofWithout', '$proofWith') }).Count -eq 0) { continue }
            }
            $failureProblems.Add("$where -Message is not fixed text: $([string]$messageArgument.Extent.Text)")
        }
    }
    Check ($failureProblems.Count -eq 0 -and $failureCalls -ge 12) "M2 static: every key failure ($failureCalls calls) is built from a literal api-key code and fixed text; no message is assembled from a value that could hold the key $($failureProblems -join '; ')"
    # The same for what FastLlm.ApiKey.ps1 throws directly, and for the "flag cannot be known" failure: a typed key failure or a literal.
    $throwProblems = New-Object 'System.Collections.Generic.List[string]'
    foreach ($thrown in @($keyTree.FindAll({ param($node) $node -is [Management.Automation.Language.ThrowStatementAst] }, $true))) {
        $thrownText = [string]$thrown.Extent.Text
        if ($thrownText -cnotmatch "^throw \(New-FastLlmApiKeyFailure -Code '" -and $thrownText -cnotmatch "^throw '[^'`$]*'$") { $throwProblems.Add("line $($thrown.Extent.StartLineNumber): $thrownText") }
    }
    $proofNumbers = [IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.Runtime.ps1'))
    Check ($throwProblems.Count -eq 0 -and $proofNumbers.Contains('$proofWithout = 0') -and $proofNumbers.Contains('$proofWith = 0') -and @([regex]::Matches($proofNumbers, '\$proofWith(out)? = (?!0\b|\[int\] \()')).Count -eq 0) "M2 static: FastLlm.ApiKey.ps1 throws only typed key failures and literals, and the two numbers the proof's message carries are HTTP status numbers $($throwProblems -join '; ')"
    $settingFailureBody = [string]@((Get-SourceTree 'src/FastLlm.ServingSettings.ps1').FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'New-FastLlmApiKeySettingFailure' }, $true))[0].Body.Extent.Text
    Check ($settingFailureBody -cmatch "-ArgumentList 'api-key-setting-unreadable: [^'`$]+'\s*\r?\n" -and @([regex]::Matches($settingFailureBody, '\$[A-Za-z]+') | ForEach-Object { $_.Value } | Where-Object { $_ -cne '$failure' }).Count -eq 0) 'M2 static: the "flag cannot be known" failure is one literal text (nothing is inserted into it)'

    # Behavioural part: with module logging on for FastLLM and for PowerShell's own utility and management cmdlets, run the store read,
    # the store state, Show / Copy, settings -ApiKey show, the scrub, a keyed request and a whole keyed start with a marker key, and read
    # what PowerShell logged. On macOS that is the unified log of this process; on Windows a live capture of the PowerShell operational
    # event log (event 4103 of this process, tests/helpers/module-log-tap.ps1): a subscription that keeps each event as it is written, so
    # the size of that circular log cannot take anything out of the window. Two canary values, logged the same way before and after, mark
    # the window; on Windows every record between them must also have been delivered (a check of its own). Without the canaries (a host
    # where the log cannot be read) the check is skipped and says so.
    # The marker key of this check is random text made here (never a real key): PowerShell may also log script text, and a marker that is
    # written out in a test file would be found in that text and not because a value was logged.
    # The live capture's gap count and completeness rule are pure, so they are pinned here on every OS: a gap, an unsorted input with a
    # duplicate, a bad range, and each clause of the completeness rule failing alone.
    Check ((Get-ModuleLogMissingCount @(1, 2, 4) 1 4) -eq 1) 'module logging: gap count: ids 1,2,4 over 1..4 miss one'
    Check ((Get-ModuleLogMissingCount @(1, 2, 3) 1 3) -eq 0) 'module logging: gap count: ids 1,2,3 over 1..3 miss none'
    Check ((Get-ModuleLogMissingCount @(4, 1, 2, 2) 1 4) -eq 1) 'module logging: gap count: unsorted ids with a duplicate (4,1,2,2 over 1..4) miss one'
    Check ((Get-ModuleLogMissingCount @(1, 2, 3) -1 3) -eq -1) 'module logging: gap count: a first id below zero is -1'
    Check ((Get-ModuleLogMissingCount @(1, 2, 3) 3 2) -eq -1) 'module logging: gap count: a last id below the first is -1'
    $logGoodReport = @{ errors = 0; oneId = [long] 10; twoId = [long] 20; missing = [long] 0 }
    Check (Test-ModuleLogTapComplete ([pscustomobject] $logGoodReport)) 'module logging: completeness: a report with no error, both canaries and no gap is complete'
    foreach ($logBad in @(@('a subscription error', @{ errors = 1 }), @('canary one not seen', @{ oneId = [long] -1 }), @('canary two before canary one', @{ twoId = [long] 5 }), @('a missing record', @{ missing = [long] 1 }), @('an unusable range (-1 missing)', @{ missing = [long] -1 }))) {
        $logBadReport = $logGoodReport.Clone()
        foreach ($logKey in $logBad[1].Keys) { $logBadReport[$logKey] = $logBad[1][$logKey] }
        Check (-not (Test-ModuleLogTapComplete ([pscustomobject] $logBadReport))) "module logging: completeness: $($logBad[0]) alone makes the report incomplete"
    }
    $logMarker = 'fl-' + ([Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')).Substring(0, 43)
    $logMarkerHolder = New-Holder $logMarker
    $logMarkerId = [string](InModule { param($K) Get-FastLlmApiKeyId -ApiKeyHolder $K } @(, $logMarkerHolder))
    $logRoot = New-Dir 'module-log'
    $logCanaryOne = 'MODLOGCANARY1' + [Guid]::NewGuid().ToString('N')
    $logCanaryTwo = 'MODLOGCANARY2' + [Guid]::NewGuid().ToString('N')
    $logKind = 'none'
    $onMac = [bool](Test-Path Variable:IsMacOS) -and [bool](Get-Variable -Name IsMacOS -ValueOnly)
    if ($onMac -and (Test-Path -LiteralPath '/usr/bin/log')) { $logKind = 'mac' } elseif ($isWindowsHost) { $logKind = 'windows' }
    $logCapturePath = Join-Path $temp 'module-log-capture.txt'
    $logBegin = [DateTime]::UtcNow.AddSeconds(-1)
    $logBeginLocal = [DateTime]::Now.AddSeconds(-1).ToString('yyyy-MM-dd HH:mm:ss')
    $logEventLog = 'Microsoft-Windows-PowerShell/Operational'
    if ($PSVersionTable.PSVersion.Major -ge 6) { $logEventLog = 'PowerShellCore/Operational' }
    $logTap = $null
    $logTapReport = $null
    $logEvidence = @{ oneId = [long] -1; oneSnapshot = ''; lastWait = '' }
    # What PowerShell logged for this process since the capture began, as one text (Windows: the live capture's text).
    function Read-ModuleLog {
        if ($logKind -ceq 'mac') {
            # Everything this process logged since the check began, from the system log store.
            try { & '/usr/bin/log' show --style compact --start $logBeginLocal --predicate "processID == $PID" > $logCapturePath 2> ($logCapturePath + '.err'); return [IO.File]::ReadAllText($logCapturePath) } catch { return '' }
        }
        if ($logKind -ceq 'windows') {
            # The live capture: the 4103 events of this process, kept as they were written.
            if ($null -eq $logTap) { return '' }
            return $logTap.Text()
        }
        return ''
    }
    function Wait-ModuleLogCanary([string]$Canary, [int]$Seconds) {
        $canaryClock = [Diagnostics.Stopwatch]::StartNew()
        while ($canaryClock.Elapsed.TotalSeconds -lt $Seconds) {
            # A module function with the canary as a plain [string] parameter: logged exactly the way a key parameter would be.
            $null = InModule { param($R) Get-FastLlmApiKeyStoreState -InstallRoot $R } @((Join-Path $logRoot $Canary))
            Start-Sleep -Milliseconds 400
            $waitText = Read-ModuleLog
            $logEvidence.lastWait = Get-ModuleLogFlags $waitText $logCanaryOne $logCanaryTwo
            if ($waitText.IndexOf($Canary, [StringComparison]::Ordinal) -ge 0) { return $true }
        }
        return $false
    }
    $loggedModules = @($module)
    foreach ($builtIn in @('Microsoft.PowerShell.Utility', 'Microsoft.PowerShell.Management')) { $loggedModules += @(Import-Module $builtIn -PassThru) }
    $logStore = Join-Path $logRoot 'install'
    New-Item -ItemType Directory -Path $logStore | Out-Null
    $logResults = @{ ran = $false; sawOne = $false; sawTwo = $false; shown = $null; printed = $null; scrubbed = $null; keyedStatus = 0; start = $null; copy = $null; storeId = $null }
    $logText = ''
    $savedConsoleOut = [Console]::Out
    try {
        if ($logKind -cne 'none') {
            # The capture starts before logging is turned on, so compiling it and creating it log nothing.
            if ($logKind -ceq 'windows') { $logTap = Start-ModuleLogTap $logEventLog $PID }
            foreach ($loggedModule in $loggedModules) { $loggedModule.LogPipelineExecutionDetails = $true }
            $logResults.sawOne = Wait-ModuleLogCanary $logCanaryOne 30
            if ($logResults.sawOne -and $logKind -ceq 'windows') { $logEvidence.oneId = [long] $logTap.FindRecord($logCanaryOne); $logEvidence.oneSnapshot = Get-ModuleLogSnapshot $logEventLog }
        }
        if ($logResults.sawOne) {
            # From here to the second canary this test hands the marker to no cmdlet itself: results are kept and checked afterwards.
            $logResults.ran = $true
            InModule { param($R, $K) Write-FastLlmApiKeyStore -InstallRoot $R -ApiKeyHolder $K } @($logStore, $logMarkerHolder)
            $logResults.storeId = [string](InModule { param($R) (Get-FastLlmApiKeyStoreState -InstallRoot $R).apiKeyId } @($logStore))
            $logHolder = InModule { param($R) Read-FastLlmApiKeyStore -InstallRoot $R } @($logStore)
            InModule { param($R) Assert-FastLlmApiKeyStore -InstallRoot $R } @($logStore)
            $logResults.shown = InModule { param($R) Get-FastLlmApiKeyForDisplay -InstallRoot $R } @($logStore)
            # settings -ApiKey show: the action, then the command line's own statement that prints the key (taken from fast-llm.ps1).
            $apiKeyChange = Invoke-FastLlmApiKeySetting -InstallRoot $logStore -Action show
            $printWriter = New-Object IO.StringWriter
            [Console]::SetOut($printWriter)
            try { . ([scriptblock]::Create('[Console]::Out.WriteLine([string] $apiKeyChange.key)')) } finally { [Console]::SetOut($savedConsoleOut) }
            $logResults.printed = $printWriter.ToString()
            # Show / Copy in the window: the one copy routine, for the key row and for a card.
            $logClipboard = New-Object 'System.Collections.Generic.List[object]'
            $logCopyOne = Invoke-FastLlmUiKeyCopy -KeyOnly -ReadKey { InModule { param($R) Get-FastLlmApiKeyForDisplay -InstallRoot $R } @($logStore) } -SetClipboard { param($Payload) $logClipboard.Add($Payload) } -SetStatus { param($Text) }
            $logCopyTwo = Invoke-FastLlmUiKeyCopy -Snippet $card['claude-code'] -ReadKey { InModule { param($R) Get-FastLlmApiKeyForDisplay -InstallRoot $R } @($logStore) } -SetClipboard { param($Payload) $logClipboard.Add($Payload) } -SetStatus { param($Text) }
            $logResults.copy = @($logCopyOne, $logCopyTwo, $logClipboard.Count)
            # The scrub, given a text that holds the key; the state writer and the run log, each given a value that holds it.
            $logUnscrubbed = 'the server said ' + $logMarker
            $logResults.scrubbed = InModule { param($T, $K) ConvertTo-FastLlmKeyFreeText -Text $T -ApiKeyHolder $K } @(([ref]$logUnscrubbed), $logHolder)
            # A keyed request to a listener this process owns, and a whole keyed start against the mock server.
            $logRecorder = New-Object FlApiKeyWiringRecorder
            try { $logResults.keyedStatus = [int](InModule { param($B, $K, $I) Invoke-FastLlmHttp -BaseUrl $B -Path '/props' -TimeoutMs 5000 -ApiKeyHolder $K -ApiKeyServer $I } @("http://127.0.0.1:$($logRecorder.Port)", $logHolder, (Get-Identity $PID))).Status }
            finally { $logRecorder.Dispose() }
            $logResults.start = Invoke-KeyRun -Name 'module-log-start' -Mode 'ok' -Holder $logHolder -Install $logStore
            $logResults.sawTwo = Wait-ModuleLogCanary $logCanaryTwo 60
        }
    }
    finally {
        [Console]::SetOut($savedConsoleOut)
        foreach ($loggedModule in $loggedModules) { $loggedModule.LogPipelineExecutionDetails = $false }
        if ($logKind -cne 'none') { Start-Sleep -Milliseconds 500; $logText = Read-ModuleLog }
        # Canary two is in the capture when the wait saw it; delivery is in record order, so everything before it is in the text too.
        if ($null -ne $logTap) { $logTapReport = Get-ModuleLogTapReport $logTap $logCanaryOne $logCanaryTwo; Stop-ModuleLogTap $logTap }
    }
    foreach ($logInfoLine in @(Get-ModuleLogEvidenceLines $logKind $logEventLog $PID $logBegin $logEvidence $logText $logCanaryOne $logCanaryTwo $logTapReport)) { Write-Host $logInfoLine }
    if (-not $logResults.ran -or -not $logResults.sawTwo) {
        $logSkipText = "the module-logging check (M2, behavioural) did not run to the end on this host: log source '$logKind', first canary seen: $($logResults.sawOne), second canary seen: $($logResults.sawTwo), live capture start error: '$($script:moduleLogTapStartError)'."
        # On Windows PowerShell 5.1 - the PowerShell the product runs in - this check is not optional: it is the only one that sees a key
        # handed to a cmdlet or to a module function as a plain value wherever that happens. A host that cannot read its own PowerShell
        # operational log fails the suite here; it does not pass with a skip.
        Check (-not ($isWindowsHost -and $PSVersionTable.PSVersion.Major -lt 6)) "module logging: on Windows PowerShell 5.1 the check must run to the end, and $logSkipText (The log is $logEventLog, event 4103.)"
        Write-Host "SKIP: $logSkipText The static checks above still hold."
    }
    else {
        Check ([string]$logResults.shown -ceq $logMarker -and [string]$logResults.printed -ceq ($logMarker + [Environment]::NewLine) -and [string]$logResults.storeId -ceq $logMarkerId -and [string]$logResults.scrubbed -ceq 'the server said <api-key>' -and $logResults.keyedStatus -eq 200 -and $null -eq $logResults.start.failure -and [string]$logResults.start.status.apiKey -ceq 'on' -and $logResults.copy[0] -eq $true -and $logResults.copy[1] -eq $true -and $logResults.copy[2] -eq 2) "module logging: with logging on, the store read, Show, settings -ApiKey show, both copies, the scrub, a keyed request and a keyed start all worked$(if ($logResults.start.failure) { ': ' + [string]$logResults.start.failure.Exception.Message })"
        $logFunctions = @('Read-FastLlmApiKeyStore', 'Get-FastLlmApiKeyStoreState', 'Get-FastLlmApiKeyForDisplay', 'ConvertTo-FastLlmKeyFreeText', 'ConvertFrom-FastLlmApiKeyProtected', 'ConvertTo-FastLlmApiKeyHolder', 'Get-FastLlmApiKeyText', 'Invoke-FastLlmHttp', 'Invoke-FastLlmSupervisedServer', 'Initialize-FastLlmEngineStartInfo')
        $logMissing = @($logFunctions | Where-Object { $logText.IndexOf('ParameterBinding(' + $_ + ')', [StringComparison]::Ordinal) -lt 0 -and $logText.IndexOf('CommandInvocation(' + $_ + ')', [StringComparison]::Ordinal) -lt 0 })
        if ($logKind -ceq 'windows') { Check (Test-ModuleLogTapComplete $logTapReport) "module logging: the live capture lost nothing - no subscription error, and every record from canary one's to canary two's was delivered (records missing between them: $($logTapReport.missing), subscription errors: $($logTapReport.errors) $($logTapReport.errorType))" }
        Check ($logText.IndexOf($logCanaryOne, [StringComparison]::Ordinal) -ge 0 -and $logText.IndexOf($logCanaryTwo, [StringComparison]::Ordinal) -ge 0 -and $logMissing.Count -eq 0 -and $logText.IndexOf('System.Security.SecureString', [StringComparison]::Ordinal) -ge 0) "module logging: the log really recorded these calls - both canaries, the key functions and their holder parameters (as a type name) are in it ($(Get-ModuleLogFlags $logText $logCanaryOne $logCanaryTwo), not logged: $($logMissing -join ','))"
        # The key, parts of it, and the forms an array parameter is logged in: its characters, or its bytes, joined by ", ".
        $logCharacters = @($logMarker.ToCharArray() | ForEach-Object { [string]$_ })
        $logByteValues = @([Text.Encoding]::UTF8.GetBytes($logMarker) | ForEach-Object { [string][int]$_ })
        $logFindings = New-Object 'System.Collections.Generic.List[string]'
        $logForbidden = [ordered]@{
            'the key' = $logMarker
            'the first twelve characters after the prefix' = $logMarker.Substring(3, 12)
            'twelve characters from the middle' = $logMarker.Substring(17, 12)
            'the last eight characters (the tail the server prints is inside them)' = $logMarker.Substring(38, 8)
            'the key as comma-joined characters' = ($logCharacters -join ', ')
            'a run of eight comma-joined key characters' = (@($logCharacters[3..10]) -join ', ')
            'the key as comma-joined bytes' = ($logByteValues -join ', ')
            'a run of eight comma-joined key bytes' = (@($logByteValues[3..10]) -join ', ')
        }
        foreach ($what in $logForbidden.Keys) { if ($logText.IndexOf([string]$logForbidden[$what], [StringComparison]::Ordinal) -ge 0) { $logFindings.Add($what) } }
        Check ($logFindings.Count -eq 0) "module logging: what PowerShell logged ($($logText.Length) characters, source '$logKind') holds no key, no part of it, and no comma-joined characters or bytes of it ($($logFindings -join '; '))"
    }

    # ================= L2: the documented limits name the port that is free while FastLLM is stopped =================
    $securityText = [IO.File]::ReadAllText((Join-Path $root 'SECURITY.md'))
    $readmeText = [IO.File]::ReadAllText((Join-Path $root 'README.md'))
    $limitsText = ''
    $limitsAt = $securityText.IndexOf('Limits:', [StringComparison]::Ordinal)
    if ($limitsAt -ge 0) { $limitsText = $securityText.Substring($limitsAt) }
    Check ($limitsText -cmatch 'while FastLLM is not running' -and $limitsText -cmatch 'another Windows account' -and $limitsText -cmatch "listen on FastLLM's port" -and $limitsText -cmatch 'sends its key to that program' -and $limitsText -cmatch 'create a new key' -and $limitsText -cmatch 'api-key-listener-changed') 'docs: the SECURITY.md Limits name the case - while FastLLM is not running another program can listen on its port and be sent an app''s key - and the remedy (create a new key)'
    $readmeKeyAt = $readmeText.IndexOf('## API key (optional)', [StringComparison]::Ordinal)
    $readmeKeyText = ''
    if ($readmeKeyAt -ge 0) { $readmeKeyText = $readmeText.Substring($readmeKeyAt, [Math]::Min(6000, $readmeText.Length - $readmeKeyAt)) }
    Check ($readmeKeyText -cmatch 'When FastLLM is not running' -and $readmeKeyText -cmatch 'can listen on the same port' -and $readmeKeyText -cmatch 'sends its key to that program' -and $readmeKeyText -cmatch 'create a new key' -and $readmeKeyText -cmatch 'clipboard history') 'docs: the README API key section says the same, and says what Copy does with the clipboard'
    Check ($readmeKeyText.Contains('`"apiKey": "on"` or `"apiKey": "off"`') -and $readmeKeyText -cmatch 'FastLLM does not guess' -and $readmeKeyText -cmatch 'never had a key is not affected') 'docs: the README says the setting is stored as on or off, that a stored key without a setting is refused, and that an installation without a key is not affected'

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
