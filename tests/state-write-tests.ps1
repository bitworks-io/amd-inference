#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
if($env:OS -cne 'Windows_NT'){ Write-Host 'state-write-tests: skipped (Windows only).'; exit 0 }
Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force
$module=Get-Module FastLlm
$count=0
function Check([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; $script:count++; Write-Host "PASS: $Message" }
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('fastllm-state-write-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$ps=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$ok=$false
function Open-Holder([string]$Path,[IO.FileShare]$Share) {
    return (New-Object IO.FileStream($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,$Share))
}
function Write-State([string]$Install,$State,[string]$Name='status.json') {
    & $module { param($i,$s,$n) Write-FastLlmState -InstallRoot $i -State $s -FileName $n } $Install $State $Name
}
function New-Install([string]$Name) {
    $dir=Join-Path $scratch $Name
    $state=Join-Path $dir 'state'
    New-Item -ItemType Directory -Path $state -Force | Out-Null
    return $dir
}
try {
    # a. Characterization of the old pattern (never fails the suite).
    $charDir=Join-Path $scratch 'char'; New-Item -ItemType Directory -Path $charDir | Out-Null
    $charDest=Join-Path $charDir 'status.json'; Set-Content -LiteralPath $charDest -Value '{"v":0}' -Encoding UTF8
    $holder=Open-Holder $charDest ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    $outcome='succeeded'
    try {
        $tmp=Join-Path $charDir 'old.tmp'; Set-Content -LiteralPath $tmp -Value '{"v":1}' -Encoding UTF8
        try { Move-Item -LiteralPath $tmp -Destination $charDest -Force } catch { $outcome=($_.Exception.Message -replace '\s+',' ') }
    } finally { $holder.Dispose() }
    Write-Host "CHARACTERIZATION: old Move-Item -Force with a share-delete holder -> $outcome"

    # b. Share-delete holder does not block the new write.
    $install=New-Install 'b'; $dest=Join-Path $install 'state\status.json'
    Write-State $install @{v=0}
    $holder=Open-Holder $dest ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try { Write-State $install @{v=1} } finally { $holder.Dispose() }
    Check ((Read-FastLlmJson $dest).v -eq 1) 'Write-FastLlmState succeeds over a share-delete holder and the file holds the new JSON'
    Check (@(Get-ChildItem -LiteralPath (Join-Path $install 'state') -Filter '*.tmp').Count -eq 0) 'no temp file remains after replace over a holder'

    # c. Read-only share holder in another process for about 300 ms.
    $install=New-Install 'c'; $dest=Join-Path $install 'state\status.json'
    Write-State $install @{v=0}
    $ready=Join-Path $scratch 'c.ready'
    $holderScript=Join-Path $scratch 'holder.ps1'
    Set-Content -LiteralPath $holderScript -Encoding ASCII -Value @'
param([string]$Path,[string]$Ready)
$s=New-Object IO.FileStream($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
Set-Content -LiteralPath $Ready -Value 'ready'
Start-Sleep -Milliseconds 300
$s.Dispose()
'@
    $child=Start-Process -FilePath $ps -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$holderScript,$dest,$ready) -PassThru -WindowStyle Hidden
    $wait=[Diagnostics.Stopwatch]::StartNew()
    while(-not (Test-Path -LiteralPath $ready) -and $wait.ElapsedMilliseconds -lt 15000){ Start-Sleep -Milliseconds 20 }
    Check (Test-Path -LiteralPath $ready) 'read-only holder process reported ready'
    $timer=[Diagnostics.Stopwatch]::StartNew()
    Write-State $install @{v=2}
    $timer.Stop()
    Check ((Read-FastLlmJson $dest).v -eq 2) ('write succeeded after a short read-only holder released (' + $timer.ElapsedMilliseconds + ' ms)')
    Check ($timer.ElapsedMilliseconds -lt 1500) 'short read-only holder resolved within the retry budget'
    [void]$child.WaitForExit(10000)

    # c2. Reader handle WITHOUT FILE_SHARE_DELETE (as Get-Content in 5.1 opens) while writes repeat; released after ~300 ms.
    $install=New-Install 'c2'; $dest=Join-Path $install 'state\status.json'
    Write-State $install @{v=0}
    $ready2=Join-Path $scratch 'c2.ready'
    $holderScript2=Join-Path $scratch 'holder-rw.ps1'
    Set-Content -LiteralPath $holderScript2 -Encoding ASCII -Value @'
param([string]$Path,[string]$Ready)
$s=New-Object IO.FileStream($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
Set-Content -LiteralPath $Ready -Value 'ready'
Start-Sleep -Milliseconds 300
$s.Dispose()
'@
    $child=Start-Process -FilePath $ps -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$holderScript2,$dest,$ready2) -PassThru -WindowStyle Hidden
    $wait=[Diagnostics.Stopwatch]::StartNew()
    while(-not (Test-Path -LiteralPath $ready2) -and $wait.ElapsedMilliseconds -lt 15000){ Start-Sleep -Milliseconds 20 }
    $timer=[Diagnostics.Stopwatch]::StartNew(); $writeError=$null
    try { for($i=1;$i -le 10;$i++){ Write-State $install @{v=$i} } } catch { $writeError=$_.Exception.Message }
    $timer.Stop()
    Check ($writeError -eq $null) ('repeated writes succeed while a no-delete-share reader is released after ~300 ms (' + $timer.ElapsedMilliseconds + ' ms)' + $(if($writeError){': '+$writeError}))
    Check ((Read-FastLlmJson $dest).v -eq 10) 'last repeated write is the current state'
    [void]$child.WaitForExit(10000)

    # d. Holder beyond the budget: throws, no temp left, previous content intact.
    $install=New-Install 'd'; $dest=Join-Path $install 'state\status.json'
    Write-State $install @{v=0}
    $holder=Open-Holder $dest ([IO.FileShare]::None)
    $message=$null
    $timer=[Diagnostics.Stopwatch]::StartNew()
    try { try { Write-State $install @{v=9} } catch { $message=$_.Exception.Message } } finally { $holder.Dispose() }
    $timer.Stop()
    Check ($message -and $message.StartsWith('state-replace-failed: status.json')) ('exclusive holder produced state-replace-failed (' + $message + ')')
    Check (-not $message.Contains($install)) 'failure message carries the file name only'
    Check ($timer.ElapsedMilliseconds -le 3000) ('retry budget bounded (' + $timer.ElapsedMilliseconds + ' ms)')
    $keptTmps=@(Get-ChildItem -LiteralPath (Join-Path $install 'state') -Filter '*.tmp')
    Check ($keptTmps.Count -eq 1 -and ((Get-Content -LiteralPath $keptTmps[0].FullName -Raw) -match '"v":\s*9')) 'a failed replace KEEPS the fully written temp even though the destination exists (never decided by File.Exists(destination))'
    Check ((Read-FastLlmJson $dest).v -eq 0) 'previous content intact after budget failure'

    # e. Writer process replaces status.json 200 times while this process reads in a loop.
    $install=New-Install 'e'; $dest=Join-Path $install 'state\status.json'
    Write-State $install @{v=0}
    $writerScript=Join-Path $scratch 'writer.ps1'
    $writerDone=Join-Path $scratch 'writer.done'
    Set-Content -LiteralPath $writerScript -Encoding ASCII -Value @'
param([string]$Root,[string]$Install,[string]$Done)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
try {
    Import-Module (Join-Path $Root 'src/FastLlm.psm1') -Force
    $m=Get-Module FastLlm
    for($i=1;$i -le 200;$i++){ & $m { param($a,$b) Write-FastLlmState -InstallRoot $a -State @{v=$b} } $Install $i }
    Set-Content -LiteralPath $Done -Value 'ok'
} catch { Set-Content -LiteralPath $Done -Value ('error: ' + $_.Exception.Message) }
'@
    $writer=Start-Process -FilePath $ps -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$writerScript,$root,$install,$writerDone) -PassThru -WindowStyle Hidden
    $total=[Diagnostics.Stopwatch]::StartNew()
    $reads=0; $readError=$null; $last=0
    while(-not (Test-Path -LiteralPath $writerDone) -and $total.Elapsed.TotalSeconds -lt 25){
        try { $v=(Read-FastLlmJson $dest).v; if($v -lt $last){ throw "version went backwards $last -> $v" }; $last=$v; $reads++ } catch { $readError=$_.Exception.Message; break }
    }
    [void]$writer.WaitForExit(5000)
    $writerResult=if(Test-Path -LiteralPath $writerDone){(Get-Content -LiteralPath $writerDone -Raw).Trim()}else{'timeout'}
    Check ($readError -eq $null) ('concurrent reader saw no exception over ' + $reads + ' reads' + $(if($readError){': '+$readError}))
    Check ($writerResult -eq 'ok') ('writer process completed 200 replaces: ' + $writerResult)
    Check ((Read-FastLlmJson $dest).v -eq 200) 'final state holds the last write'
    Check ($total.Elapsed.TotalSeconds -le 30) ('concurrent replace/read test bounded (' + [int]$total.Elapsed.TotalSeconds + ' s)')

    # f. Read-FastLlmJson encodings, missing file, empty file.
    $bom=Join-Path $scratch 'bom.json'; $nobom=Join-Path $scratch 'nobom.json'
    [IO.File]::WriteAllBytes($bom,([Text.Encoding]::UTF8.GetPreamble()+[Text.Encoding]::UTF8.GetBytes('{"name":"caf'+[char]0xE9+'","n":3}')))
    [IO.File]::WriteAllBytes($nobom,[Text.Encoding]::UTF8.GetBytes('{"name":"caf'+[char]0xE9+'","n":3}'))
    foreach($file in @($bom,$nobom)){
        $r=Read-FastLlmJson $file
        Check ($r.n -eq 3 -and $r.name -ceq ('caf'+[char]0xE9)) ('Read-FastLlmJson parses ' + (Split-Path $file -Leaf))
    }
    $missing=Join-Path $scratch 'missing.json'; $msg=$null
    try { Read-FastLlmJson $missing } catch { $msg=$_.Exception.Message }
    Check ($msg -ceq "JSON file was not found: $missing") 'missing file throws the original message'
    $empty=Join-Path $scratch 'empty.json'; [IO.File]::WriteAllBytes($empty,[byte[]]@())
    $oldValue='<none>'; $oldError=$null
    try { $oldValue=(Get-Content -LiteralPath $empty -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $oldError=$_.Exception.Message }
    $newValue='<none>'; $newError=$null
    try { $newValue=(Read-FastLlmJson $empty) } catch { $newError=$_.Exception.Message }
    Write-Host ("INFO: empty file old=" + $(if($oldError){'throws'}elseif($oldValue -eq $null){'null'}else{'value'}) + " new=" + $(if($newError){'throws'}elseif($newValue -eq $null){'null'}else{'value'}))
    Check (([bool]$oldError) -eq ([bool]$newError) -and ($oldValue -eq $null) -eq ($newValue -eq $null)) 'empty file behaves as the previous Get-Content based reader'
    # f2. Read-FastLlmJson -MaxBytes: exactly at the cap is read, cap+1 throws the typed error; unbounded callers are unchanged.
    $capDir=Join-Path $scratch 'cap'; New-Item -ItemType Directory -Path $capDir | Out-Null
    $atCap=Join-Path $capDir 'at-cap.json'; $overCap=Join-Path $capDir 'over-cap.json'; $bomCap=Join-Path $capDir 'bom-cap.json'
    [IO.File]::WriteAllBytes($atCap,[Text.Encoding]::ASCII.GetBytes('{"p":"'+('a'*92)+'"}'))
    [IO.File]::WriteAllBytes($overCap,[Text.Encoding]::ASCII.GetBytes('{"p":"'+('a'*93)+'"}'))
    [IO.File]::WriteAllBytes($bomCap,([Text.Encoding]::UTF8.GetPreamble()+[Text.Encoding]::ASCII.GetBytes('{"p":"'+('a'*89)+'"}')))
    Check ((Get-Item -LiteralPath $atCap).Length -eq 100 -and (Get-Item -LiteralPath $overCap).Length -eq 101 -and (Get-Item -LiteralPath $bomCap).Length -eq 100) 'the cap fixtures are exactly 100, 101 and 100 bytes'
    Check ((Read-FastLlmJson -Path $atCap -MaxBytes 100).p.Length -eq 92) 'a file exactly at MaxBytes is read'
    Check ((Read-FastLlmJson -Path $bomCap -MaxBytes 100).p.Length -eq 89) 'a BOM file exactly at MaxBytes is read and the BOM is stripped'
    $capError=$null
    try { Read-FastLlmJson -Path $overCap -MaxBytes 100 | Out-Null } catch { $capError=$_.Exception }
    Check ($capError -is [IO.InvalidDataException] -and $capError.Data['FastLlmJsonTooLarge'] -eq $true -and -not $capError.Message.Contains($capDir)) 'a file one byte over MaxBytes throws the typed InvalidDataException (file name only)'
    Check ((Read-FastLlmJson -Path $overCap).p.Length -eq 93) 'without MaxBytes the reader is unbounded as before'
    # The typed over-cap error is never retried: it surfaces at once through Get-FastLlmStatus.
    $install=New-Install 'cap-status'; $dest=Join-Path $install 'state\status.json'
    [IO.File]::WriteAllBytes($dest,[Text.Encoding]::ASCII.GetBytes('{"p":"'+('a'*70000)+'"}'))
    $capTimer=[Diagnostics.Stopwatch]::StartNew(); $capError=$null
    try { Get-FastLlmStatus $install | Out-Null } catch { $capError=$_.Exception }
    $capTimer.Stop()
    Check ($capError -is [IO.InvalidDataException] -and $capError.Data['FastLlmJsonTooLarge'] -eq $true) ('a status.json over 65536 bytes throws the typed over-cap error (' + $capTimer.ElapsedMilliseconds + ' ms)')

    # f3. Consent receipt reader has a size cap (16384): a normal receipt verifies, an oversized one counts as no receipt.
    $consentInstall=Join-Path $scratch 'consent'
    $consentModel=[pscustomobject]@{id='cap-model';revision='r1';upstreamModel='u';upstreamRevision='ur';upstreamLicense='l';upstreamLicenseSha256=('a'*64);repository='repo';artifactLicense='al';sha256=('b'*64)}
    & $module { param($m,$i) Write-FastLlmModelConsentReceipt -Model $m -InstallRoot $i -AcceptanceMode 'explicit-switch' } $consentModel $consentInstall
    $consentPath=& $module { param($m,$i) Get-FastLlmModelConsentPath -Model $m -InstallRoot $i } $consentModel $consentInstall
    Check (& $module { param($m,$i) Test-FastLlmModelConsentReceipt -Model $m -InstallRoot $i } $consentModel $consentInstall) 'a normal consent receipt verifies under the size cap'
    $consentBytes=[IO.File]::ReadAllBytes($consentPath)
    $padded=[Text.Encoding]::UTF8.GetString($consentBytes).TrimEnd()
    $padded=$padded.Substring(0,$padded.LastIndexOf('}'))+(' ' * 17000)+'}'
    [IO.File]::WriteAllBytes($consentPath,[Text.Encoding]::UTF8.GetBytes($padded))
    Check ((Get-Item -LiteralPath $consentPath).Length -gt 16384 -and -not (& $module { param($m,$i) Test-FastLlmModelConsentReceipt -Model $m -InstallRoot $i } $consentModel $consentInstall)) 'an oversized consent receipt is rejected (no receipt) without being parsed'

    # g. Seam: simulate ReplaceFile Win32 1176 (original already gone, temp still present).
    $install=New-Install 'g'; $dest=Join-Path $install 'state\status.json'; $stateDir=Join-Path $install 'state'
    Write-State $install @{v=0}
    $sim1176={param($s,$d) [IO.File]::Delete($d); throw (New-Object IO.IOException('simulated ReplaceFile 1176',-2147023720)) }
    & $module { param($B) $script:FastLlmFileReplaceInvoker=$B } $sim1176
    try {
        Write-State $install @{v=1}
        Check ((Read-FastLlmJson $dest).v -eq 1 -and @(Get-ChildItem -LiteralPath $stateDir -Filter '*.tmp').Count -eq 0) 'ReplaceFile 1176 falls back to Move: the new state is in place and no temp remains'
        # Both calls fail: the original is gone, so the temp is the sole copy and must survive; the failure is typed.
        & $module { param($B) $script:FastLlmFileMoveInvoker=$B } { param($s,$d) throw (New-Object IO.IOException('simulated move failure')) }
        $thrown=$null
        try { Write-State $install @{v=2} } catch { $thrown=$_.Exception }
        $leftover=@(Get-ChildItem -LiteralPath $stateDir -Filter '*.tmp')
        Check ($thrown -and $thrown.Message.StartsWith('state-replace-failed: status.json') -and $thrown.Data['FastLlmStateWrite'] -eq $true) 'a failed 1176 recovery throws the typed state-replace-failed error with the FastLlmStateWrite flag'
        Check ($leftover.Count -eq 1 -and -not (Test-Path -LiteralPath $dest) -and ((Get-Content -LiteralPath $leftover[0].FullName -Raw) -match '"v":\s*2')) 'the temp file is kept as the sole surviving copy when the destination is gone'
    } finally { & $module { $script:FastLlmFileReplaceInvoker=$null; $script:FastLlmFileMoveInvoker=$null } }
    Write-State $install @{v=3}
    Check ((Read-FastLlmJson $dest).v -eq 3) 'a later write succeeds once the seams are cleared'

    # h. Delete-pending destination: a share-delete holder in another process plus a DeleteOnClose handle that is closed.
    $holdShare=Join-Path $scratch 'holder-share.ps1'
    Set-Content -LiteralPath $holdShare -Encoding ASCII -Value @'
param([string]$Path,[string]$Ready,[int]$HoldMs)
$s=New-Object IO.FileStream($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
Set-Content -LiteralPath $Ready -Value 'ready'
Start-Sleep -Milliseconds $HoldMs
$s.Dispose()
'@
    function New-DeletePending([string]$Dest,[string]$Name,[int]$HoldMs) {
        Set-Content -LiteralPath $Dest -Value '{"v":0}' -Encoding UTF8
        $readyFile=Join-Path $scratch ($Name+'.ready')
        $proc=Start-Process -FilePath $ps -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$holdShare,$Dest,$readyFile,"$HoldMs") -PassThru -WindowStyle Hidden
        $w=[Diagnostics.Stopwatch]::StartNew()
        while(-not (Test-Path -LiteralPath $readyFile) -and $w.ElapsedMilliseconds -lt 15000){ Start-Sleep -Milliseconds 20 }
        $a=New-Object IO.FileStream($Dest,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete),4096,[IO.FileOptions]::DeleteOnClose)
        $a.Dispose()
        return $proc
    }
    # Characterize the old pattern against a delete-pending destination.
    $cdir=Join-Path $scratch 'dp-char'; New-Item -ItemType Directory -Path $cdir | Out-Null
    $cdest=Join-Path $cdir 'status.json'
    $proc=New-DeletePending $cdest 'dpc' 400
    $oldOutcome='succeeded'
    try { $ctmp=Join-Path $cdir 'old.tmp'; Set-Content -LiteralPath $ctmp -Value '{"v":1}' -Encoding UTF8; Move-Item -LiteralPath $ctmp -Destination $cdest -Force } catch { $oldOutcome=($_.Exception.Message -replace '\s+',' ') }
    Write-Host "CHARACTERIZATION: old Move-Item -Force against a delete-pending destination -> $oldOutcome"
    [void]$proc.WaitForExit(10000)
    # The new helper against the same state.
    $install=New-Install 'h'; $dest=Join-Path $install 'state\status.json'; $stateDir=Join-Path $install 'state'
    $proc=New-DeletePending $dest 'dph' 300
    $failure=$null; $timer=[Diagnostics.Stopwatch]::StartNew()
    try { Write-State $install @{v=5} } catch { $failure=$_.Exception }
    $timer.Stop(); [void]$proc.WaitForExit(10000)
    $tmps=@(Get-ChildItem -LiteralPath $stateDir -Filter '*.tmp')
    Check ($null -eq $failure) ('delete-pending destination held ~300 ms: the write must succeed within the budget' + $(if($failure){': '+$failure.Message}))
    Check ((Read-FastLlmJson $dest).v -eq 5 -and $tmps.Count -eq 0 -and $timer.ElapsedMilliseconds -le 3000) ('delete-pending destination: new state in place, no temp left (' + $timer.ElapsedMilliseconds + ' ms)')
    # A hold LONGER than the ~1.4 s budget must fail typed and keep the temp (the destination vanishes when the holder closes).
    $install=New-Install 'h2'; $dest=Join-Path $install 'state\status.json'; $stateDir=Join-Path $install 'state'
    $proc=New-DeletePending $dest 'dph2' 5000
    $failure=$null; $timer=[Diagnostics.Stopwatch]::StartNew()
    try { Write-State $install @{v=6} } catch { $failure=$_.Exception }
    $timer.Stop(); [void]$proc.WaitForExit(15000)
    $tmps=@(Get-ChildItem -LiteralPath $stateDir -Filter '*.tmp')
    # Deterministic: the pre-write check no longer gives up early (GetAttributes sees the delete-pending entry), so the write always
    # reaches the replace, which exhausts its ~1.4 s budget typed and keeps the temp as the only copy.
    $typedFlag=($failure -and $failure.Data['FastLlmStateWrite'] -eq $true -and $failure.Message.StartsWith('state-replace-failed: status.json'))
    Check ($typedFlag) ('a delete-pending hold beyond the budget fails typed with the FastLlmStateWrite flag (' + $(if($failure){$failure.GetType().Name + ': ' + $failure.Message}else{'it SUCCEEDED'}) + ' after ' + $timer.ElapsedMilliseconds + ' ms)')
    Check ($failure -and $failure.Message.StartsWith('state-replace-failed: status.json') -and $tmps.Count -eq 1 -and ((Get-Content -LiteralPath $tmps[0].FullName -Raw) -match '"v":\s*6') -and $timer.ElapsedMilliseconds -ge 800 -and $timer.ElapsedMilliseconds -le 3400) ('the long hold fails in the REPLACE after its ~1.4 s budget (not early in the pre-check) and keeps the temp as the only copy (' + $tmps.Count + ' temp, ' + $timer.ElapsedMilliseconds + ' ms)')
    # A hold of ~0.8 s (between the old 0.5 s pre-check and the 1.4 s replace budget) must NOT abort a healthy start.
    $install=New-Install 'h3'; $dest=Join-Path $install 'state\status.json'; $stateDir=Join-Path $install 'state'
    $proc=New-DeletePending $dest 'dph3' 800
    $failure=$null; $timer=[Diagnostics.Stopwatch]::StartNew()
    try { Write-State $install @{v=7} } catch { $failure=$_.Exception }
    $timer.Stop(); [void]$proc.WaitForExit(10000)
    Check ($null -eq $failure -and (Read-FastLlmJson $dest).v -eq 7 -and @(Get-ChildItem -LiteralPath $stateDir -Filter '*.tmp').Count -eq 0) ('a delete-pending hold of ~0.8 s no longer aborts the write (' + $timer.ElapsedMilliseconds + ' ms)' + $(if($failure){': '+$failure.Message}))

    # i. Get-FastLlmStatus in a loop while another process replaces status.json 200 times.
    $install=New-Install 'i'; $dest=Join-Path $install 'state\status.json'
    Write-State $install @{v=0;phase='failed'}
    $statusWriter=Join-Path $scratch 'writer-status.ps1'
    $statusDone=Join-Path $scratch 'writer-status.done'
    Set-Content -LiteralPath $statusWriter -Encoding ASCII -Value @'
param([string]$Root,[string]$Install,[string]$Done)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
try {
    Import-Module (Join-Path $Root 'src/FastLlm.psm1') -Force
    $m=Get-Module FastLlm
    for($i=1;$i -le 200;$i++){ & $m { param($a,$b) Write-FastLlmState -InstallRoot $a -State @{v=$b;phase='failed'} } $Install $i }
    Set-Content -LiteralPath $Done -Value 'ok'
} catch { Set-Content -LiteralPath $Done -Value ('error: ' + $_.Exception.Message) }
'@
    $writer=Start-Process -FilePath $ps -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$statusWriter,$root,$install,$statusDone) -PassThru -WindowStyle Hidden
    $total=[Diagnostics.Stopwatch]::StartNew(); $reads=0; $phantom=0; $statusError=$null
    while(-not (Test-Path -LiteralPath $statusDone) -and $total.Elapsed.TotalSeconds -lt 25){
        try { $st=Get-FastLlmStatus $install; if($st.phase -ne 'failed'){ $phantom++ }; $reads++ } catch { $statusError=$_.Exception.Message; break }
    }
    [void]$writer.WaitForExit(5000)
    Check ($statusError -eq $null -and $phantom -eq 0 -and $reads -gt 0) ('Get-FastLlmStatus saw no exception and no phantom stopped over ' + $reads + ' reads' + $(if($statusError){': '+$statusError}))
    Check ((Test-Path -LiteralPath $statusDone) -and (Get-Content -LiteralPath $statusDone -Raw).Trim() -eq 'ok') 'status writer process completed 200 replaces'

    # j. Behavioural supervisor classification: a state-write failure injected right after the child is spawned.
    $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0); $listener.Start(); $port=$listener.LocalEndpoint.Port; $listener.Stop()
    $runRoot=Join-Path $scratch 'sup'; New-Item -ItemType Directory -Path $runRoot | Out-Null
    $plan=[pscustomobject]@{
        enginePath=(Get-Process -Id $PID).Path
        serverArguments=@('-NoLogo','-NoProfile','-File',(Join-Path $PSScriptRoot 'helpers/mock-server.ps1'),'-Port',"$port",'-Mode','timeout')
        endpoint="http://127.0.0.1:$port/v1"; selectedAdapters=@([pscustomobject]@{device='Vulkan0'})
        hardwareFingerprint='synthetic';engineVersion='test';model=[pscustomobject]@{id='test-model';contextSize=1024;sha256=('0'*64)}
    }
    $savedWrite=& $module {(Get-Command Write-FastLlmState).ScriptBlock}
    & $module {
        param($W)
        $script:supWrites=0; $script:supSaved=$W
        function script:Write-FastLlmState {
            param([string] $InstallRoot, $State, [string] $FileName='status.json')
            $script:supWrites++
            if ($script:supWrites -eq 2) {
                $e = New-Object IO.IOException('state-replace-failed: status.json (HResult 0x80070020) [injected]')
                $e.Data['FastLlmStateWrite'] = $true
                throw $e
            }
            & $script:supSaved -InstallRoot $InstallRoot -State $State -FileName $FileName
        }
    } $savedWrite
    $caught=$null
    try { & $module { param($P,$R) Invoke-FastLlmSupervisedServer -Plan $P -InstallRoot $R -LoadTimeoutSeconds 10 } $plan $runRoot | Out-Null } catch { $caught=$_.Exception }
    finally { & $module { param($W) Set-Item -Path Function:script:Write-FastLlmState -Value $W } $savedWrite }
    $supStatus=Get-FastLlmStatus $runRoot
    Check ($caught -and $caught.Data['FastLlmReason'] -ceq 'StateWriteFailed' -and $caught.Data['FastLlmReason'] -cne 'RuntimeCheckFailed') 'an injected state-write failure after spawn is tagged StateWriteFailed, never RuntimeCheckFailed (no recovery)'
    Check ($supStatus.failureCode -ceq 'state-write-failed') 'the recorded failure code is state-write-failed'
    $cliText=Get-Content -LiteralPath (Join-Path $root 'fast-llm.ps1') -Raw
    Check ($cliText -match "FastLlmReason'\] -eq 'RuntimeCheckFailed'" -and $cliText -notmatch "StateWriteFailed") 'the CLI recovery path keys only on RuntimeCheckFailed'

    # ---- Get-Item shadow (module scope): deterministic transient / unsafe verdicts ----
    function Set-GetItemShadow([hashtable]$Box) {
        & $module {
            param($B)
            $script:giBox = $B
            function script:Get-Item {
                [CmdletBinding()]
                param([Parameter(Position=0)][string]$LiteralPath,[switch]$Force)
                $box = $script:giBox
                if ($null -ne $box -and $LiteralPath -like $box.pattern) {
                    $box.calls++
                    if ($box.calls -le $box.count) { return [pscustomobject]@{ Attributes=[int]$box.attributes; Length=1L; PSIsContainer=$false } }
                }
                Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath -Force:$Force -ErrorAction Stop
            }
        } $Box
    }
    # The shadow stays installed as a pure pass-through once cleared (removing a module-scope function by drive path is unreliable).
    function Clear-GetItemShadow { & $module { $script:giBox = $null } }

    # k. Write-FastLlmState pre-check: it reads Attributes through the module seam [IO.File]::GetAttributes (which sees delete-pending
    #    entries); Attributes -1 is never retried here (the replace owns the wait); a real reparse point is unsafe at once.
    $realAttributesFn=& $module {(Get-Command Get-FastLlmStateFileAttributes -CommandType Function).ScriptBlock}
    function Set-AttributesShadow([hashtable]$Box) {
        & $module {
            param($B,$R)
            $script:attrBox = $B
            $script:attrReal = $R
            function script:Get-FastLlmStateFileAttributes {
                param([string]$Path)
                $box = $script:attrBox
                if ($null -ne $box -and $Path -like $box.pattern) { $box.calls++; return $box.attributes }
                return (& $script:attrReal -Path $Path)
            }
        } $Box $realAttributesFn
    }
    function Clear-AttributesShadow { & $module { $script:attrBox = $null } }
    $install=New-Install 'k1'; $dest=Join-Path $install 'state\status.json'
    Write-State $install @{v=0}
    $box=@{pattern='*status.json';attributes=-1;calls=0}
    Set-AttributesShadow $box
    $timer=[Diagnostics.Stopwatch]::StartNew()
    try { Write-State $install @{v=1} } finally { Clear-AttributesShadow }
    $timer.Stop()
    Check ($box.calls -eq 1 -and (Read-FastLlmJson $dest).v -eq 1 -and $timer.ElapsedMilliseconds -lt 400) ('writer pre-check does not retry Attributes -1: one check, then the replace owns the wait (' + $box.calls + ' check, ' + $timer.ElapsedMilliseconds + ' ms)')
    $box=@{pattern='*status.json';attributes=$null;calls=0}
    Set-AttributesShadow $box
    try { Write-State $install @{v=2} } finally { Clear-AttributesShadow }
    Check ($box.calls -eq 1 -and (Read-FastLlmJson $dest).v -eq 2) 'an unreadable destination (attributes null) does not block the write'
    $box=@{pattern='*status.json';attributes=1024;calls=0}
    Set-AttributesShadow $box
    $thrown=$null; $timer=[Diagnostics.Stopwatch]::StartNew()
    try { Write-State $install @{v=3} } catch { $thrown=$_.Exception } finally { Clear-AttributesShadow }
    $timer.Stop()
    Check ($thrown -and $thrown.Message -ceq 'Unsafe status path.' -and $thrown.Data['FastLlmStateWrite'] -eq $true -and $box.calls -eq 1 -and $timer.ElapsedMilliseconds -lt 400 -and (Read-FastLlmJson $dest).v -eq 2) 'a real reparse point is refused at once (one check, no retry) and typed as a state-write failure'
    Check (@(Get-ChildItem -LiteralPath (Join-Path $install 'state') -Filter '*.tmp').Count -eq 0) 'no temp is left when the unsafe verdict stopped the write before any temp was written'
    $realAttributes=& $module { Get-FastLlmStateFileAttributes -Path (Join-Path ([IO.Path]::GetTempPath()) ('fastllm-no-such-file-' + [Guid]::NewGuid().ToString('N'))) }
    Check ($null -eq $realAttributes) 'the real attribute reader returns null for a missing file'

    # k2. Get-FastLlmStatus: same verdicts.
    $install=New-Install 'k2'; $dest=Join-Path $install 'state\status.json'
    Write-State $install @{v=7;phase='failed'}
    $box=@{pattern='*status.json';attributes=-1;count=3;calls=0}
    Set-GetItemShadow $box
    try { $st=Get-FastLlmStatus $install } finally { Clear-GetItemShadow }
    Check ($st.phase -ceq 'failed' -and $st.v -eq 7 -and $box.calls -eq 4) 'Get-FastLlmStatus retries Attributes -1 and then reads the real state (no phantom stopped)'
    $box=@{pattern='*status.json';attributes=-1;count=1000;calls=0}
    Set-GetItemShadow $box
    try { $st=Get-FastLlmStatus $install } finally { Clear-GetItemShadow }
    Check ($st.phase -ceq 'stopped' -and -not $st.active -and $box.calls -eq 10) 'a persistent Attributes -1 reads as missing (stopped) after the bounded retry'
    $box=@{pattern='*status.json';attributes=1024;count=1000;calls=0}
    Set-GetItemShadow $box
    $thrown=$null
    try { Get-FastLlmStatus $install | Out-Null } catch { $thrown=$_.Exception } finally { Clear-GetItemShadow }
    Check ($thrown -and $thrown.Message -ceq 'Unsafe status document.' -and $box.calls -eq 1) 'a real reparse point on status.json throws at once without the 150 ms retry'

    # k3. Request-FastLlmStop retry: Attributes -1 retried, real reparse point refused at once, and a concurrent create/delete.
    $install=New-Install 'k3'; $stateDir=Join-Path $install 'state'
    $runId=('c'*32); $stopPath=Join-Path $stateDir ('stop-'+$runId)
    Write-State $install @{runId=$runId;phase='ready'}
    $lockHolder=[IO.File]::Open((Join-Path $stateDir 'operation.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        Set-Content -LiteralPath $stopPath -Value 'x'
        $box=@{pattern='*stop-*';attributes=-1;count=2;calls=0}
        Set-GetItemShadow $box
        try { Request-FastLlmStop $install 6>$null } finally { Clear-GetItemShadow }
        Check ($box.calls -eq 3 -and (Test-Path -LiteralPath $stopPath)) 'Request-FastLlmStop retried Attributes -1 twice and then succeeded'
        $box=@{pattern='*stop-*';attributes=1024;count=1000;calls=0}
        Set-GetItemShadow $box
        $thrown=$null
        try { Request-FastLlmStop $install 6>$null } catch { $thrown=$_.Exception } finally { Clear-GetItemShadow }
        Check ($thrown -and $thrown.Message -ceq 'Unsafe stop request path.' -and $box.calls -eq 1) 'Request-FastLlmStop refuses a real reparse point at once'
        Remove-Item -LiteralPath $stopPath -Force
        # Concurrent create/delete of the request file from another process while requests repeat.
        $togglerScript=Join-Path $scratch 'toggler.ps1'; $togglerDone=Join-Path $scratch 'toggler.done'
        Set-Content -LiteralPath $togglerScript -Encoding ASCII -Value @'
param([string]$Path,[string]$Done,[int]$Ms)
$sw=[Diagnostics.Stopwatch]::StartNew()
while($sw.ElapsedMilliseconds -lt $Ms){
    try { $s=[IO.File]::Open($Path,'OpenOrCreate','Write','ReadWrite'); $s.Dispose() } catch { }
    Start-Sleep -Milliseconds 4
    try { [IO.File]::Delete($Path) } catch { }
    Start-Sleep -Milliseconds 4
}
Set-Content -LiteralPath $Done -Value 'done'
'@
        $toggler=Start-Process -FilePath $ps -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$togglerScript,$stopPath,$togglerDone,'2500') -PassThru -WindowStyle Hidden
        $total=[Diagnostics.Stopwatch]::StartNew(); $requests=0; $stopError=$null
        while(-not (Test-Path -LiteralPath $togglerDone) -and $total.Elapsed.TotalSeconds -lt 20){
            try { Request-FastLlmStop $install 6>$null; $requests++ } catch { $stopError=$_.Exception.Message; break }
        }
        [void]$toggler.WaitForExit(5000)
        Check ($stopError -eq $null -and $requests -gt 0) ('Request-FastLlmStop saw no exception over ' + $requests + ' requests while another process created and deleted the request file' + $(if($stopError){': '+$stopError}))
    } finally { $lockHolder.Dispose() }

    # l. Keep-temp on a failed replace where File.Exists(destination) is misleadingly true, then the stale-temp sweep.
    $install=New-Install 'l'; $dest=Join-Path $install 'state\status.json'; $stateDir=Join-Path $install 'state'
    Write-State $install @{v=0}
    & $module { param($B) $script:FastLlmFileReplaceInvoker=$B } { param($s,$d) throw (New-Object IO.IOException('simulated sharing violation',-2147024864)) }
    $thrown=$null
    try { Write-State $install @{v=1} } catch { $thrown=$_.Exception } finally { & $module { $script:FastLlmFileReplaceInvoker=$null } }
    $kept=@(Get-ChildItem -LiteralPath $stateDir -Filter '*.tmp')
    Check ($thrown -and $thrown.Message.StartsWith('state-replace-failed: status.json') -and $thrown.Data['FastLlmStateWrite'] -eq $true -and [IO.File]::Exists($dest)) 'the replace failed typed while File.Exists(destination) is true'
    Check ($kept.Count -eq 1 -and ((Get-Content -LiteralPath $kept[0].FullName -Raw) -match '"v":\s*1') -and (Read-FastLlmJson $dest).v -eq 0) 'the temp is kept on ANY failed replace and the destination is untouched'
    $oldTmp=$kept[0].FullName
    [IO.File]::SetLastWriteTimeUtc($oldTmp,[DateTime]::UtcNow.AddMinutes(-11))
    $freshTmp=Join-Path $stateDir ([Guid]::NewGuid().ToString('N')+'.tmp'); Set-Content -LiteralPath $freshTmp -Value '{"v":99}'
    $otherName=Join-Path $stateDir 'notes.tmp'; Set-Content -LiteralPath $otherName -Value 'x'; [IO.File]::SetLastWriteTimeUtc($otherName,[DateTime]::UtcNow.AddMinutes(-30))
    $upperName=Join-Path $stateDir (([Guid]::NewGuid().ToString('N')).ToUpperInvariant()+'.tmp'); Set-Content -LiteralPath $upperName -Value 'x'; [IO.File]::SetLastWriteTimeUtc($upperName,[DateTime]::UtcNow.AddMinutes(-30))
    $edgeTmp=Join-Path $stateDir ([Guid]::NewGuid().ToString('N')+'.tmp'); Set-Content -LiteralPath $edgeTmp -Value '{"v":98}'; [IO.File]::SetLastWriteTimeUtc($edgeTmp,[DateTime]::UtcNow.AddMinutes(-9))
    Write-State $install @{v=2}
    Check ((Read-FastLlmJson $dest).v -eq 2 -and -not (Test-Path -LiteralPath $oldTmp)) 'after the next SUCCESSFUL write the stale (older than 10 minutes) GUID temp is swept'
    Check ((Test-Path -LiteralPath $freshTmp) -and (Test-Path -LiteralPath $edgeTmp)) 'a fresh temp and a 9-minute-old temp (a concurrent writer in flight) are kept'
    Check ((Test-Path -LiteralPath $otherName) -and (Test-Path -LiteralPath $upperName)) 'files that do not match the writer GUID .tmp pattern are never swept, however old'
    # A failed write never sweeps.
    [IO.File]::SetLastWriteTimeUtc($freshTmp,[DateTime]::UtcNow.AddMinutes(-20))
    & $module { param($B) $script:FastLlmFileReplaceInvoker=$B } { param($s,$d) throw (New-Object IO.IOException('simulated sharing violation',-2147024864)) }
    try { Write-State $install @{v=3} } catch { } finally { & $module { $script:FastLlmFileReplaceInvoker=$null } }
    Check (Test-Path -LiteralPath $freshTmp) 'a failed write does not sweep (only the next successful write does)'
    Write-State $install @{v=4}
    Check (-not (Test-Path -LiteralPath $freshTmp)) 'the next successful write sweeps it once it is stale'

    # l2. Same rules for the consent receipt writer.
    $install=New-Install 'l2'
    $model=[pscustomobject]@{id='consent-model';revision='r1';upstreamModel='u';upstreamRevision='ur';upstreamLicense='l';upstreamLicenseSha256=('1'*64);repository='repo';artifactLicense='al';sha256=('2'*64)}
    $writeReceipt={ param($M,$R) Write-FastLlmModelConsentReceipt -Model $M -InstallRoot $R -AcceptanceMode explicit-switch }
    & $module $writeReceipt $model $install
    $receiptPath=& $module { param($M,$R) Get-FastLlmModelConsentPath -Model $M -InstallRoot $R } $model $install
    $receiptDir=Split-Path -Parent $receiptPath
    & $module { param($B) $script:FastLlmFileReplaceInvoker=$B } { param($s,$d) throw (New-Object IO.IOException('simulated sharing violation',-2147024864)) }
    $thrown=$null
    try { & $module $writeReceipt $model $install } catch { $thrown=$_.Exception } finally { & $module { $script:FastLlmFileReplaceInvoker=$null } }
    $keptReceipt=@(Get-ChildItem -LiteralPath $receiptDir -Filter '*.tmp.*')
    Check ($thrown -and $thrown.Message.StartsWith('state-replace-failed:') -and $keptReceipt.Count -eq 1) 'a failed consent receipt replace keeps its temp'
    [IO.File]::SetLastWriteTimeUtc($keptReceipt[0].FullName,[DateTime]::UtcNow.AddMinutes(-11))
    $freshReceiptTmp=$receiptPath+'.tmp.'+[Guid]::NewGuid().ToString('N'); Set-Content -LiteralPath $freshReceiptTmp -Value 'x'
    & $module $writeReceipt $model $install
    Check (-not (Test-Path -LiteralPath $keptReceipt[0].FullName) -and (Test-Path -LiteralPath $freshReceiptTmp) -and (& $module { param($M,$R) Test-FastLlmModelConsentReceipt $M $R } $model $install)) 'the next successful receipt write sweeps the stale temp and keeps a fresh one'

    # m. Final status write downgrade: a flagged failure becomes a warning and exit 0; an unflagged one is rethrown.
    function New-FinalWritePlan([string]$RunRoot) {
        $l=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0); $l.Start(); $port=$l.LocalEndpoint.Port; $l.Stop()
        [pscustomobject]@{
            enginePath=(Get-Process -Id $PID).Path
            serverArguments=@('-NoLogo','-NoProfile','-File',(Join-Path $PSScriptRoot 'helpers/mock-server.ps1'),'-Port',"$port",'-Mode','ok','-Model','test-model','-DiagnosticPath',(Join-Path $RunRoot 'diag.txt'))
            endpoint="http://127.0.0.1:$port/v1"; backend='Vulkan'; selectedAdapters=@([pscustomobject]@{device='Vulkan0'})
            hardwareFingerprint='synthetic';engineVersion='test';model=[pscustomobject]@{id='test-model';contextSize=1024;sha256=('0'*64)}
        }
    }
    function Invoke-FinalWriteRun([string]$Name,[string]$Mode) {
        $runRoot=Join-Path $scratch $Name; New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
        $plan=New-FinalWritePlan $runRoot
        $saved=& $module {(Get-Command Write-FastLlmState).ScriptBlock}
        & $module {
            param($W,$M)
            $script:fwSaved=$W; $script:fwMode=$M
            function script:Write-FastLlmState {
                param([string] $InstallRoot, $State, [string] $FileName='status.json')
                if ($FileName -ceq 'status.json' -and $State.phase -ceq 'stopped') {
                    $e = New-Object IO.IOException('final status write failed [injected]')
                    if ($script:fwMode -ceq 'flagged') { $e.Data['FastLlmStateWrite'] = $true }
                    throw $e
                }
                & $script:fwSaved -InstallRoot $InstallRoot -State $State -FileName $FileName
                if ($FileName -ceq 'status.json' -and $State.phase -ceq 'ready') {
                    # Stand-in for an independent stop client: publish the run-scoped stop request once Ready is recorded.
                    Set-Content -LiteralPath (Join-Path (Join-Path $InstallRoot 'state') ('stop-' + $State.runId)) -Value 'stop'
                }
            }
        } $saved $Mode
        $result=[ordered]@{output=@();error=$null}
        try { $result.output=@(& $module { param($P,$R) Invoke-FastLlmSupervisedServer -Plan $P -InstallRoot $R -LoadTimeoutSeconds 30 } $plan $runRoot 3>&1) }
        catch { $result.error=$_.Exception }
        finally { & $module { param($W) Set-Item -Path Function:script:Write-FastLlmState -Value $W } $saved }
        return [pscustomobject]$result
    }
    $flagged=Invoke-FinalWriteRun 'final-flagged' 'flagged'
    $flaggedWarnings=@($flagged.output | Where-Object { $_ -is [Management.Automation.WarningRecord] })
    $flaggedExit=@($flagged.output | Where-Object { $_ -is [int] })
    Check ($null -eq $flagged.error -and $flaggedExit.Count -ge 1 -and $flaggedExit[-1] -eq 0 -and $flaggedWarnings.Count -eq 1 -and $flaggedWarnings[0].Message -match 'final status write failed') 'a flagged failure of the final status write downgrades to a warning and the supervisor still exits 0'
    $plain=Invoke-FinalWriteRun 'final-plain' 'plain'
    Check ($plain.error -and $plain.error.Message -ceq 'final status write failed [injected]') 'an unflagged failure of the final status write is rethrown'

    $ok=$true
} finally {
    if($ok){ Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
    else { Write-Warning "State write test scratch retained for diagnostics: $scratch" }
}
Write-Host "$count state write checks passed."
