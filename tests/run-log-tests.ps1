#requires -Version 5.1
# Run log and support bundle tests (Task 7, A3). The marker tests drive a real supervised start against the native mock server and then
# scan EVERY file under the install root and the unzipped support bundle: no prompt, completion or request marker may appear anywhere.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force
$module=Get-Module FastLlm
. (Join-Path $root 'src/FastLlm.ServingSettings.ps1')
. (Join-Path $root 'src/FastLlm.Update.ps1')
. (Join-Path $root 'src/FastLlm.Components.ps1')
. (Join-Path $root 'src/FastLlm.SupportBundle.ps1')
. (Join-Path $PSScriptRoot 'helpers/New-FastLlmDefaultArgumentsGolden.ps1')
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$catalog=Join-Path $root 'config/catalog.json'
$script:count=0
function Check($Condition,[string]$Message){ if(-not $Condition){ throw "FAIL: $Message" }; $script:count++; Write-Host "PASS: $Message" }
function Throws([scriptblock]$Action,[string]$Pattern) {
    $caught=$false;$observed='no exception'
    try { & $Action | Out-Null } catch {
        $caught=[bool]([string]$_.Exception.Message -match $Pattern)
        $observed=[regex]::Replace([string]$_.Exception.Message,'[\x00-\x1f\x7f]',' ')
        if($observed.Length -gt 240){$observed=$observed.Substring(0,240)}
    }
    if(-not $caught){ throw "FAIL: rejects $Pattern (observed: $observed)" }
    Check $true "rejects $Pattern"
}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('run-log-tests-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp -Force | Out-Null
$markers=@('FLLM-MARKER-PROMPT-7f3a','FLLM-MARKER-COMPLETION-7f3a','FLLM-MARKER-CLIENT-7f3a','FLLM-MARKER-CHATPAGE-7f3a','FLLM-MARKER-FAILURE-7f3a',
    'A local inference system should produce accurate useful answers.','Measure speed consistently while preserving model quality.')
function New-Dir([string]$Name){ $p=Join-Path $temp $Name; New-Item -ItemType Directory -Path $p -Force | Out-Null; return $p }
function Get-LogDir([string]$Install){ return (Join-Path (Join-Path $Install 'state') 'logs') }
function Read-LogLines([string]$Path){ return @([IO.File]::ReadAllLines($Path) | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }) }
function Get-FreePort { $l=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0); $l.Start(); $p=$l.LocalEndpoint.Port; $l.Stop(); return $p }
# Every file under the folders, searched byte-wise (ASCII markers), so a leak in any format is found.
function Find-MarkerFiles([string[]]$Folders) {
    $hits=New-Object 'System.Collections.Generic.List[string]'
    foreach ($folder in $Folders) {
        foreach ($file in @(Get-ChildItem -LiteralPath $folder -Recurse -File -Force -ErrorAction SilentlyContinue)) {
            $text=[Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($file.FullName))
            foreach ($marker in $markers) { if ($text.IndexOf($marker,[StringComparison]::OrdinalIgnoreCase) -ge 0) { $hits.Add($file.FullName + ' :: ' + $marker) } }
        }
    }
    return $hits.ToArray()
}
function Expand-Bundle([string]$Zip,[string]$Name) {
    $dir=Join-Path $temp $Name
    [IO.Compression.ZipFile]::ExtractToDirectory($Zip,$dir)
    return $dir
}

try {
    # ---- field-allowlist -------------------------------------------------------------------------------------------------------
    $r=New-Dir 'allow'
    $id='0123456789abcdef0123456789abcdef'
    Throws { Write-FastLlmRunLogEvent -InstallRoot $r -RunId $id -Event 'phase' -Fields @{ phase='loading'; prompt='hello' } } 'run-log-field-not-allowed'
    Throws { Write-FastLlmRunLogEvent -InstallRoot $r -RunId $id -Event 'phase' -Fields @{ completion='x' } } 'run-log-field-not-allowed'
    Throws { Write-FastLlmRunLogEvent -InstallRoot $r -RunId $id -Event 'start' -Fields @{ phase='loading' } } 'run-log-field-not-allowed'
    Throws { Write-FastLlmRunLogEvent -InstallRoot $r -RunId $id -Event 'chat' -Fields @{} } 'run-log-event-not-allowed'
    Throws { Write-FastLlmRunLogEvent -InstallRoot $r -RunId $id -Event 'phase' -Fields @{ phase=@('a','b') } } 'run-log-value-not-allowed'
    Throws { Write-FastLlmRunLogEvent -InstallRoot $r -RunId $id -Event 'phase' -Fields @{ phase=@{ a=1 } } } 'run-log-value-not-allowed'
    Throws { Write-FastLlmRunLogEvent -InstallRoot $r -RunId '..\evil' -Event 'phase' -Fields @{ phase='loading' } } 'run-log-run-id'
    Check (-not (Test-Path -LiteralPath (Get-LogDir $r))) 'field-allowlist: a refused event creates no log folder or file'
    $allowed=[ordered]@{
        'start'=@{ modelId='m'; recipeId='r'; backend='vulkan'; engineVersion='b1'; contextSize=8192; port=18181; thinking='off'; chatPage='on'; selfTest=$true }
        'phase'=@{ phase='ready'; failureCode='x-y' }
        'startup-diagnostics'=@{ status='captured'; kvBufferCount=1; computeBufferCount=1; kvTotalMiB=256.5; computeTotalMiB=64; flashMode='auto'; flashResolved=$true }
        'placement'=@{ reportedLayers=41; totalLayers=41; reportedAllLayers=$true; deviceCount=1; devices='Vulkan0'; modelBufferTotalMiB=1200 }
        'api-check'=@{ status='pass'; modelIdentity=$true; effectiveContext=1024; repeatableToken=$true; synchronousChat=$true; streaming=$true }
        'self-test'=@{ status='pass'; reasons='a-b'; generationTokS=50.5; promptTokS=900; firstTextMs=120; expectedGenerationTokS=48; comparable=$true }
        'end'=@{ phase='stopped'; failureCode='x'; failedAtPhase='loading'; failureMessage='Server exited before readiness.'; exitCode=0; droppedEvents=0 }
    }
    foreach ($eventName in $allowed.Keys) {
        Write-FastLlmRunLogEvent -InstallRoot $r -RunId $id -Event $eventName -Fields $allowed[$eventName] | Out-Null
    }
    $files=@(Get-ChildItem -LiteralPath (Get-LogDir $r) -Filter 'run-*.jsonl')
    Check ($files.Count -eq 1 -and $files[0].Name -cmatch '^run-\d{8}T\d{6}Z-0123456789abcdef0123456789abcdef\.jsonl$') 'field-allowlist: one file run-<yyyyMMddTHHmmssZ>-<runId>.jsonl'
    $lines=@(Read-LogLines $files[0].FullName)
    Check ($lines.Count -eq 7) 'field-allowlist: every allowed event is one JSON line'
    $envelope=@('ts','runId','event')
    $mismatch=0
    foreach ($line in $lines) {
        $expected=@($envelope + @($allowed[[string]$line.event].Keys) | Sort-Object)
        $actual=@($line.PSObject.Properties.Name | Sort-Object)
        if (($expected -join ',') -cne ($actual -join ',')) { $mismatch++ }
    }
    Check ($mismatch -eq 0) 'field-allowlist: a line carries exactly ts, runId, event and the fields given, nothing else'
    $long=Join-Path (New-Dir 'allow-long') 'x'
    Write-FastLlmRunLogEvent -InstallRoot $long -RunId $id -Event 'start' -Fields @{ modelId=('a'*500) } | Out-Null
    $longLine=@(Read-LogLines (@(Get-ChildItem -LiteralPath (Get-LogDir $long) -Filter 'run-*.jsonl')[0].FullName))[0]
    Check (([string]$longLine.modelId).Length -le 200) 'field-allowlist: a string value is capped at 200 characters'

    # ---- end event: the failure text rule --------------------------------------------------------------------------------------
    $fixedText='The run failed after the API checks started. The detail is not kept in logs; see the failure code.'
    foreach ($case in @(@{phase='preparing';keep=$true},@{phase='loading';keep=$true},@{phase='checking';keep=$false},@{phase='ready';keep=$false},@{phase='';keep=$false})) {
        $rr=Join-Path (New-Dir ('fail-'+$case.phase+'x')) 'i'
        $fields=@{ failureCode='startup-or-runtime-check-failed'; failureMessage='Detail with FLLM-MARKER-FAILURE-7f3a inside'; exitCode=1 }
        if ($case.phase) { $fields.failedAtPhase=$case.phase }
        Write-FastLlmRunLogEvent -InstallRoot $rr -RunId $id -Event 'end' -Fields $fields | Out-Null
        $endLine=@(Read-LogLines (@(Get-ChildItem -LiteralPath (Get-LogDir $rr) -Filter 'run-*.jsonl')[0].FullName))[0]
        if ($case.keep) { Check ([string]$endLine.failureMessage -ceq 'Detail with FLLM-MARKER-FAILURE-7f3a inside') "failure text kept before the first API request (phase '$($case.phase)')" }
        else { Check ([string]$endLine.failureMessage -ceq $fixedText) "failure text replaced by the fixed text after the API checks start (phase '$($case.phase)')" }
    }

    # ---- rotation-keeps-20 -----------------------------------------------------------------------------------------------------
    $r=New-Dir 'rot'
    $logs=Get-LogDir $r
    New-Item -ItemType Directory -Path $logs -Force | Out-Null
    $stamp=[DateTime]::UtcNow.AddHours(-100)
    for ($i=1; $i -le 25; $i++) {
        $name='run-2026110{0}T0000{1:00}Z-{2}.jsonl' -f 1,$i,('{0:x32}' -f $i)
        $path=Join-Path $logs $name
        [IO.File]::WriteAllText($path,'{"x":1}'+"`n")
        (Get-Item -LiteralPath $path).LastWriteTimeUtc=$stamp.AddMinutes($i)
    }
    [IO.File]::WriteAllText((Join-Path $logs 'notes.txt'),'not a run log')
    Invoke-FastLlmRunLogRotation -InstallRoot $r
    $kept=@(Get-ChildItem -LiteralPath $logs -Filter 'run-*.jsonl' | Sort-Object LastWriteTimeUtc)
    Check ($kept.Count -eq 20) 'rotation-keeps-20: 25 files rotate to 20'
    Check ($kept[0].Name -ceq ('run-20261101T000006Z-{0:x32}.jsonl' -f 6) -and $kept[19].Name -ceq ('run-20261101T000025Z-{0:x32}.jsonl' -f 25)) 'rotation-keeps-20: the newest 20 are kept, the oldest 5 removed'
    Check (Test-Path -LiteralPath (Join-Path $logs 'notes.txt')) 'rotation-keeps-20: a file that is not a run log is left alone'
    Invoke-FastLlmRunLogRotation -InstallRoot $r
    Check (@(Get-ChildItem -LiteralPath $logs -Filter 'run-*.jsonl').Count -eq 20) 'rotation-keeps-20: a second rotation changes nothing'
    Invoke-FastLlmRunLogRotation -InstallRoot (Join-Path $temp 'no-such-install')
    Check $true 'rotation-keeps-20: a missing install root is not an error'
    # A new run rotates on its first event, so 20 old files + the new run leave 20.
    $rot2=New-Dir 'rot2'
    $logs2=Get-LogDir $rot2
    New-Item -ItemType Directory -Path $logs2 -Force | Out-Null
    for ($i=1; $i -le 20; $i++) {
        $path=Join-Path $logs2 ('run-20261101T0000{0:00}Z-{1:x32}.jsonl' -f $i,$i)
        [IO.File]::WriteAllText($path,'{"x":1}'+"`n"); (Get-Item -LiteralPath $path).LastWriteTimeUtc=$stamp.AddMinutes($i)
    }
    Write-FastLlmRunLogEvent -InstallRoot $rot2 -RunId $id -Event 'start' -Fields @{ modelId='m' } | Out-Null
    $after=@(Get-ChildItem -LiteralPath $logs2 -Filter 'run-*.jsonl')
    Check ($after.Count -eq 20 -and @($after | Where-Object { $_.Name -like "*$id*" }).Count -eq 1 -and -not (Test-Path -LiteralPath (Join-Path $logs2 ('run-20261101T000001Z-{0:x32}.jsonl' -f 1)))) 'rotation-keeps-20: a new run keeps itself and drops the oldest'

    # ---- file-cap-256k ---------------------------------------------------------------------------------------------------------
    $r=New-Dir 'cap'
    $capId='fedcba9876543210fedcba9876543210'
    for ($i=0; $i -lt 3000; $i++) { Write-FastLlmRunLogEvent -InstallRoot $r -RunId $capId -Event 'phase' -Fields @{ phase='loading'; failureCode=('c'*150) } | Out-Null }
    $capFile=@(Get-ChildItem -LiteralPath (Get-LogDir $r) -Filter 'run-*.jsonl')[0]
    Check ($capFile.Length -le 262144) "file-cap-256k: the file stays within 256 KiB ($($capFile.Length) bytes)"
    Check ($capFile.Length -gt 200000) 'file-cap-256k: the cap was actually reached by the test'
    Write-FastLlmRunLogEvent -InstallRoot $r -RunId $capId -Event 'end' -Fields @{ phase='stopped'; exitCode=0 } | Out-Null
    $capFile=@(Get-ChildItem -LiteralPath (Get-LogDir $r) -Filter 'run-*.jsonl')[0]
    $capLines=@(Read-LogLines $capFile.FullName)
    $endCap=$capLines[$capLines.Count-1]
    Check ($capFile.Length -le 262144 -and [string]$endCap.event -ceq 'end' -and [int]$endCap.droppedEvents -gt 0) 'file-cap-256k: events past the cap are dropped and the end event still lands, counting them'
    Check (@($capLines | Where-Object { [string]$_.event -ceq 'phase' }).Count + [int]$endCap.droppedEvents -eq 3000) 'file-cap-256k: kept + dropped equals the events sent'

    # ---- log-failure-never-fails-start (unit level) ------------------------------------------------------------------------------
    $r=New-Dir 'blocked'
    New-Item -ItemType Directory -Path (Join-Path $r 'state') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path (Join-Path $r 'state') 'logs'),'a file where the log folder should be')
    $outcome=Write-FastLlmRunLogEvent -InstallRoot $r -RunId $id -Event 'phase' -Fields @{ phase='loading' }
    Check ($outcome -eq $false) 'log-failure-never-fails-start: an unwritable log folder returns $false and does not throw'
    Invoke-FastLlmRunLogRotation -InstallRoot $r
    Check $true 'log-failure-never-fails-start: rotation over an unwritable log folder does not throw'
    Remove-Item -LiteralPath (Join-Path (Join-Path $r 'state') 'logs') -Force

    # ---- supervised starts against the marker mock ----------------------------------------------------------------------------
    function New-MarkerPlan([int]$Port,[string]$Mode) {
        $plan=[pscustomobject]@{
            enginePath=(Get-Process -Id $PID).Path
            serverArguments=@('-NoLogo','-NoProfile','-File',(Join-Path $PSScriptRoot 'helpers/mock-server.ps1'),'-Port',"$Port",'-Mode',$Mode,'-Model','test-model','-Context','1024')
            endpoint="http://127.0.0.1:$Port/v1"; selectedAdapters=@([pscustomobject]@{device='Vulkan0'})
            hardwareFingerprint='synthetic';engineVersion='test';model=[pscustomobject]@{id='test-model';contextSize=1024;sha256=('0'*64)}
            catalogVersion='test';backend='Vulkan';splitMode='none';tensorSplit=$null;modelPath='test-model'
            recipe=[pscustomobject]@{id='r1';origin='bitworks';label='Measured';evidenceUrl='https://bitworks.io/amd/results/x';expected=$null}
            requestedThinking='off';requestedChatPage='on';requestedServerPort=[int]$Port
        }
        $plan.model | Add-Member -NotePropertyMembers @{parallel=1;cacheTypeK='f16';cacheTypeV='f16'}
        return $plan
    }
    function Start-ReadyClient([string]$InstallRoot,[int]$Port,[string]$ResponseFile,[bool]$SendClients) {
        $esc=$InstallRoot.Replace("'","''")
        $clients=''
        if ($SendClients) {
            $clients="try { `$a=Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:$Port/v1/chat/completions' -Method Post -ContentType 'application/json' -Body '{\`"model\`":\`"test-model\`",\`"messages\`":[{\`"role\`":\`"user\`",\`"content\`":\`"FLLM-MARKER-CLIENT-7f3a\`"}],\`"stream\`":false}' -TimeoutSec 20; Add-Content -LiteralPath '$ResponseFile' -Value `$a.Content } catch { Add-Content -LiteralPath '$ResponseFile' -Value ('client-error ' + `$_.Exception.Message) }; " +
                "try { `$b=Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:$Port/completion' -Method Post -ContentType 'application/json' -Body '{\`"prompt\`":\`"FLLM-MARKER-CHATPAGE-7f3a\`",\`"n_predict\`":8,\`"stream\`":false}' -TimeoutSec 20; Add-Content -LiteralPath '$ResponseFile' -Value `$b.Content } catch { Add-Content -LiteralPath '$ResponseFile' -Value ('client-error ' + `$_.Exception.Message) }; "
        }
        $code="Import-Module '$($root.Replace("'","''"))/src/FastLlm.psm1'; for (`$i=0; `$i -lt 200; `$i++) { try { `$s=Get-FastLlmStatus '$esc'; if (`$s.phase -eq 'ready') { $clients Request-FastLlmStop '$esc'; exit 0 } } catch {}; Start-Sleep -Milliseconds 200 }; exit 1"
        $process=New-Object Diagnostics.Process
        $process.StartInfo.FileName=(Get-Process -Id $PID).Path
        $process.StartInfo.Arguments='-NoLogo -NoProfile -OutputFormat Text -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
        $process.StartInfo.UseShellExecute=$false
        $process.Start() | Out-Null
        return $process
    }
    # Runs one supervised start with the self-test; the self-test requests carry the prompt marker through the module's own request seam.
    function Invoke-MarkerRun([string]$Name,[string]$Mode,[bool]$SendClients,[bool]$FailCanary,[bool]$ReadyAndStop=$true) {
        $install=New-Dir $Name
        $port=Get-FreePort
        $responses=Join-Path $temp ($Name+'-responses.txt')
        $lock=Enter-FastLlmOperation $install
        $plan=New-MarkerPlan $port $Mode
        $stopper=$null
        $savedCanary=& $module { (Get-Command Test-FastLlmApiCanary).ScriptBlock }
        $savedSelfTest=& $module { (Get-Command Invoke-FastLlmSelfTest).ScriptBlock }
        $failure=$null;$exit=$null
        try {
            & $module {
                param($Original)
                $script:markerOriginalSelfTest=$Original
                function script:Invoke-FastLlmSelfTest {
                    param([string]$BaseUrl,[int]$ContextSize,$Expected,[string]$EngineBuild,[string]$MitigationEffective,[scriptblock]$Request)
                    $script:markerBase=$BaseUrl
                    $seam={ param($Path,$Body,$TimeoutMs)
                        $Body['note']='FLLM-MARKER-PROMPT-7f3a'
                        return (Invoke-FastLlmHttp -BaseUrl $script:markerBase -Path $Path -Body $Body -TimeoutMs $TimeoutMs) }
                    return (& $script:markerOriginalSelfTest -BaseUrl $BaseUrl -ContextSize $ContextSize -Expected $Expected -EngineBuild $EngineBuild -MitigationEffective $MitigationEffective -Request $seam)
                }
            } $savedSelfTest
            if ($FailCanary) {
                & $module { function script:Test-FastLlmApiCanary { throw 'canary failed: the request text was FLLM-MARKER-FAILURE-7f3a and FLLM-MARKER-PROMPT-7f3a' } }
            }
            if ($ReadyAndStop) { $stopper=Start-ReadyClient $install $port $responses $SendClients }
            try { $exit=& $module { param($P,$R,$C) Invoke-FastLlmSupervisedServer -Plan $P -InstallRoot $R -LoadTimeoutSeconds 20 -CatalogPath $C -SelfTest } $plan $install $catalog }
            catch { $failure=$_.Exception }
        } finally {
            & $module { param($C,$S) Set-Item -Path 'Function:script:Test-FastLlmApiCanary' -Value $C; Set-Item -Path 'Function:script:Invoke-FastLlmSelfTest' -Value $S } $savedCanary $savedSelfTest
            if ($stopper) { if (-not $stopper.HasExited) { $stopper.Kill() }; $stopper.Dispose() }
            $lock.Dispose()
        }
        return [pscustomobject]@{ install=$install; exit=$exit; failure=$failure; responses=$responses; port=$port }
    }

    # ---- marker-selftest-never-logged -----------------------------------------------------------------------------------------
    $run=Invoke-MarkerRun 'marker-selftest' 'marker-selftest-ok' $false $false
    Check ($null -eq $run.failure -and $run.exit -eq 0) "marker-selftest-never-logged: the start reaches Ready with the self-test and stops cleanly$(if($run.failure){': '+$run.failure.Message})"
    $runLogs=@(Get-ChildItem -LiteralPath (Get-LogDir $run.install) -Filter 'run-*.jsonl' -ErrorAction SilentlyContinue)
    Check ($runLogs.Count -eq 1) 'marker-selftest-never-logged: a run produces exactly one run log'
    $runLines=@(Read-LogLines $runLogs[0].FullName)
    $eventNames=@($runLines | ForEach-Object { [string]$_.event })
    foreach ($needed in @('start','phase','startup-diagnostics','placement','api-check','self-test','end')) { Check ($eventNames -contains $needed) "run log has a '$needed' event" }
    $phases=@($runLines | Where-Object { [string]$_.event -ceq 'phase' } | ForEach-Object { [string]$_.phase })
    Check (($phases -join ',') -ceq 'preparing,loading,checking,ready,stopped') "run log phases in order: $($phases -join ',')"
    $selfTestLine=@($runLines | Where-Object { [string]$_.event -ceq 'self-test' })[0]
    Check ([string]$selfTestLine.status -ceq 'pass' -and $null -ne $selfTestLine.generationTokS) 'the self-test event carries the verdict and numbers'
    $startLine=@($runLines | Where-Object { [string]$_.event -ceq 'start' })[0]
    Check ([string]$startLine.modelId -ceq 'test-model' -and [string]$startLine.recipeId -ceq 'r1' -and [string]$startLine.thinking -ceq 'off' -and [string]$startLine.chatPage -ceq 'on' -and [int]$startLine.port -eq $run.port -and [int]$startLine.contextSize -eq 1024) 'the start event carries the plan fields including the effective port, thinking and chatPage'
    $endLine=@($runLines | Where-Object { [string]$_.event -ceq 'end' })[0]
    Check ([int]$endLine.droppedEvents -eq 0 -and $null -ne $endLine.exitCode) 'the end event carries the exit code and the dropped count'
    foreach ($name in @('status.json','selftest.json')) { Check (Test-Path -LiteralPath (Join-Path (Join-Path $run.install 'state') $name)) "state/$name exists to be scanned" }
    $doctor=[pscustomobject]@{ installRoot=$run.install; note='doctor stand-in' }
    $appRoot=New-Dir 'app-root'
    $configDir=Join-Path $appRoot 'config'; New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'config/components.json') -Destination $configDir
    [IO.File]::WriteAllText((Join-Path $appRoot 'RELEASE.json'),'{"version":"2026.11.08.1","channel":"stable"}')
    $zip=Join-Path $temp 'marker-selftest.zip'
    New-FastLlmSupportBundle -InstallRoot $run.install -AppRoot $appRoot -OutputPath $zip -Doctor $doctor | Out-Null
    $unz=Expand-Bundle $zip 'marker-selftest-unzipped'
    $leaks=@(Find-MarkerFiles @($run.install,$unz))
    Check ($leaks.Count -eq 0) "marker-selftest-never-logged: no marker in state\ or the unzipped bundle ($($leaks -join '; '))"

    # ---- marker-client-and-chatpage-never-logged ------------------------------------------------------------------------------
    $run=Invoke-MarkerRun 'marker-clients' 'marker-selftest-ok' $true $false
    Check ($null -eq $run.failure -and $run.exit -eq 0) "marker-client-and-chatpage-never-logged: the start reaches Ready and stops$(if($run.failure){': '+$run.failure.Message})"
    $clientText=''
    if (Test-Path -LiteralPath $run.responses) { $clientText=[IO.File]::ReadAllText($run.responses) }
    Check ($clientText.Contains('FLLM-MARKER-COMPLETION-7f3a') -and $clientText -notmatch 'client-error') 'marker-client-and-chatpage-never-logged: the clients really reached the mock and got the completion marker (the test is not vacuous)'
    $zip=Join-Path $temp 'marker-clients.zip'
    New-FastLlmSupportBundle -InstallRoot $run.install -AppRoot $appRoot -OutputPath $zip -Doctor $doctor | Out-Null
    $unz=Expand-Bundle $zip 'marker-clients-unzipped'
    $leaks=@(Find-MarkerFiles @($run.install,$unz))
    Check ($leaks.Count -eq 0) "marker-client-and-chatpage-never-logged: no marker in state\ or the unzipped bundle ($($leaks -join '; '))"

    # ---- marker-in-failure-after-canary ---------------------------------------------------------------------------------------
    $run=Invoke-MarkerRun 'marker-canary' 'marker-selftest-ok' $false $true $false
    Check ($null -ne $run.failure) 'marker-in-failure-after-canary: the canary failure fails the start'
    $runLogs=@(Get-ChildItem -LiteralPath (Get-LogDir $run.install) -Filter 'run-*.jsonl' -ErrorAction SilentlyContinue)
    $runLines=@(Read-LogLines $runLogs[0].FullName)
    $endLine=@($runLines | Where-Object { [string]$_.event -ceq 'end' })[0]
    Check ([string]$endLine.failureMessage -ceq $fixedText -and [string]$endLine.failureCode -ceq 'startup-or-runtime-check-failed') 'marker-in-failure-after-canary: the end event carries only the fixed text and the failure code'
    $phases=@($runLines | Where-Object { [string]$_.event -ceq 'phase' } | ForEach-Object { [string]$_.phase })
    Check ($phases -contains 'checking' -and $phases[$phases.Count-1] -ceq 'failed') 'marker-in-failure-after-canary: the phases reach checking, then failed'
    $leaks=@(Find-MarkerFiles @($run.install))
    Check ($leaks.Count -eq 0) "marker-in-failure-after-canary: no marker anywhere under the install root ($($leaks -join '; '))"

    # ---- a failure before the API checks keeps its message --------------------------------------------------------------------
    $run=Invoke-MarkerRun 'early-failure' 'marker-exit' $false $false $false
    Check ($null -ne $run.failure) 'early failure: a server that exits before readiness fails the start'
    $runLogs=@(Get-ChildItem -LiteralPath (Get-LogDir $run.install) -Filter 'run-*.jsonl' -ErrorAction SilentlyContinue)
    $endLine=@((Read-LogLines $runLogs[0].FullName) | Where-Object { [string]$_.event -ceq 'end' })[0]
    Check ([string]$endLine.failureMessage -ceq 'Server exited before readiness.' -and [string]$endLine.failedAtPhase -ceq 'loading') 'early failure: the message is kept when the failure comes before the first API request'

    # ---- log-failure-never-fails-start (real start) ----------------------------------------------------------------------------
    $blockedInstall=New-Dir 'blocked-start'
    New-Item -ItemType Directory -Path (Join-Path $blockedInstall 'state') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path (Join-Path $blockedInstall 'state') 'logs'),'blocks the log folder')
    $port=Get-FreePort
    $lock=Enter-FastLlmOperation $blockedInstall
    $stopper=Start-ReadyClient $blockedInstall $port (Join-Path $temp 'blocked-responses.txt') $false
    $blockedExit=$null;$blockedFailure=$null
    try { $blockedExit=& $module { param($P,$R,$C) Invoke-FastLlmSupervisedServer -Plan $P -InstallRoot $R -LoadTimeoutSeconds 20 -CatalogPath $C } (New-MarkerPlan $port 'ok') $blockedInstall $catalog }
    catch { $blockedFailure=$_.Exception }
    finally { if (-not $stopper.HasExited) { $stopper.Kill() }; $stopper.Dispose(); $lock.Dispose() }
    Check ($null -eq $blockedFailure -and $blockedExit -eq 0) "log-failure-never-fails-start: a start with an unwritable log folder still reaches Ready and stops with exit 0$(if($blockedFailure){': '+$blockedFailure.Message})"
    Check ((Get-FastLlmStatus $blockedInstall).phase -ceq 'stopped') 'log-failure-never-fails-start: status.json is still written'

    # ---- bundle fixtures ---------------------------------------------------------------------------------------------------------
    $sep=[string][char]92
    $profile='C:'+$sep+'Users'+$sep+'J'+[char]0xF6+'rg'
    $computer='DESKTOP-'+'AB12CDE'
    $userName='J'+[char]0xF6+'rg'
    $sid='S-1-5-21-'+'1234567890-'+'987654321-'+'1122334455'
    $mac=((@('00','1A','2b','3C','4d','5E')) -join ':')
    $pnp='PCI'+$sep+'VEN_1002&DEV_744C&SUBSYS_0E391002&REV_C8'+$sep+'6&1A2B3C4D&0&00000019'
    $pnpEscaped=$pnp.Replace($sep,$sep+$sep)

    # ---- bundle-redacts-path-variants -----------------------------------------------------------------------------------------
    $redactionCount=0
    $variants=[ordered]@{
        'backslash'=$profile+$sep+'AppData'+$sep+'Local'+$sep+'x'
        'json-escaped'=$profile.Replace($sep,$sep+$sep)+$sep+$sep+'AppData'
        'forward-slash'=$profile.Replace($sep,'/')+'/AppData/x'
        'lower-case'=$profile.ToLowerInvariant()+$sep+'appdata'
        'upper-case'=$profile.ToUpperInvariant()+$sep+'APPDATA'
        'onedrive-desktop'=$profile+$sep+'OneDrive'+$sep+'Desktop'+$sep+'notes.txt'
    }
    foreach ($key in $variants.Keys) {
        $redacted=0
        $out=ConvertTo-FastLlmRedactedText -Text ('path=' + $variants[$key] + ' end') -ProfilePath $profile -ComputerName $computer -UserName $userName -RedactionCount ([ref]$redacted)
        $redactionCount+=$redacted
        Check ($out.StartsWith('path=%USERPROFILE%') -and $redacted -ge 1 -and $out.IndexOf($userName,[StringComparison]::OrdinalIgnoreCase) -lt 0) "bundle-redacts-path-variants: $key variant becomes %USERPROFILE%"
    }
    $forwardOut=ConvertTo-FastLlmRedactedText -Text ($profile.Replace($sep,'/')+'/AppData/x') -ProfilePath $profile -ComputerName $computer -UserName $userName
    Check ($forwardOut -ceq '%USERPROFILE%/AppData/x') 'bundle-redacts-path-variants: the forward-slash form keeps its separators'
    $slashProfile=ConvertTo-FastLlmRedactedText -Text ($profile+$sep+'x') -ProfilePath ($profile.Replace($sep,'/')) -ComputerName $computer -UserName $userName
    Check ($slashProfile -ceq '%USERPROFILE%'+$sep+'x') 'bundle-redacts-path-variants: a profile path given with forward slashes still matches backslash text'
    $textAll="host $computer user $userName sid $sid mac $mac pnp $pnp esc $pnpEscaped"
    $redacted=0
    $outAll=ConvertTo-FastLlmRedactedText -Text $textAll -ProfilePath $profile -ComputerName $computer -UserName $userName -RedactionCount ([ref]$redacted)
    Check ($outAll.IndexOf($computer,[StringComparison]::OrdinalIgnoreCase) -lt 0 -and $outAll.Contains('<computer>')) 'bundle-redacts-path-variants: the machine name is redacted'
    Check ($outAll.IndexOf($userName,[StringComparison]::OrdinalIgnoreCase) -lt 0 -and $outAll.Contains('<user>')) 'bundle-redacts-path-variants: the user name is redacted'
    Check (-not $outAll.Contains($sid) -and $outAll.Contains('<sid>')) 'bundle-redacts-path-variants: the Windows SID is redacted'
    Check (-not $outAll.Contains($mac) -and $outAll.Contains('<mac>')) 'bundle-redacts-path-variants: the MAC address is redacted'
    Check (-not $outAll.Contains('6&1A2B3C4D&0&00000019') -and $outAll.Contains('VEN_1002&DEV_744C') -and $outAll.Contains('<instance>')) 'bundle-redacts-path-variants: the PnP instance suffix is redacted and the hardware id kept (plain and JSON-escaped)'
    Check ($redacted -eq 6) "bundle-redacts-path-variants: the count is the total replacements ($redacted)"
    $clean=ConvertTo-FastLlmRedactedText -Text 'nothing personal here: Vulkan0 24560 MiB' -ProfilePath $profile -ComputerName $computer -UserName $userName
    Check ($clean -ceq 'nothing personal here: Vulkan0 24560 MiB') 'bundle-redacts-path-variants: clean text is unchanged'
    $word=ConvertTo-FastLlmRedactedText -Text ('the j'+[char]0xF6+'rgensen path') -ProfilePath $profile -ComputerName $computer -UserName $userName
    Check ($word -ceq ('the j'+[char]0xF6+'rgensen path')) 'bundle-redacts-path-variants: a user name inside a longer word is not touched'

    # ---- bundle fixtures: install root with logs, settings -------------------------------------------------------------------
    $bundleInstall=New-Dir 'bundle-install'
    $bundleLogs=Get-LogDir $bundleInstall
    New-Item -ItemType Directory -Path $bundleLogs -Force | Out-Null
    for ($i=1; $i -le 7; $i++) {
        $path=Join-Path $bundleLogs ('run-20261101T0000{0:00}Z-{1:x32}.jsonl' -f $i,$i)
        [IO.File]::WriteAllText($path,('{"event":"phase","note":"' + ($profile.Replace($sep,$sep+$sep)) + $sep + $sep + 'x ' + $computer + '"}' + "`n"))
        (Get-Item -LiteralPath $path).LastWriteTimeUtc=[DateTime]::UtcNow.AddMinutes($i-100)
    }
    $settingsText='{"vulkanBarMitigation":"auto","updateCheck":"on","updateChannel":"canary","experimentalComponents":"off","serverPort":18181,"thinking":"off","chatPage":"on","secretKey":"nope","componentLicenses":{"mode":"accept-automatically","acceptedAt":"2026-11-01T00:00:00Z","accepted":[{"title":"Some licence title","host":"example.invalid"}]}}'
    [IO.File]::WriteAllText((Join-Path $bundleInstall 'settings.json'),$settingsText)
    $bigDoctor=[pscustomobject]@{ installRoot=($profile+$sep+'FastLLM'); owner=$computer; adapter=$pnp; sid=$sid }

    # ---- bundle-lists-before-save ---------------------------------------------------------------------------------------------
    $outputDir=New-Dir 'bundle-out'
    $zipPath=Join-Path $outputDir 'support.zip'
    $before=@(Get-ChildItem -LiteralPath $outputDir -Force).Count
    $listing=New-FastLlmSupportBundle -InstallRoot $bundleInstall -AppRoot $appRoot -OutputPath $zipPath -Doctor $bigDoctor -ProfilePath $profile -ComputerName $computer -UserName $userName -ListOnly
    Check (-not (Test-Path -LiteralPath $zipPath) -and @(Get-ChildItem -LiteralPath $outputDir -Force).Count -eq $before) 'bundle-lists-before-save: -ListOnly writes nothing (no zip, no temp file)'
    $names=@($listing.entries | ForEach-Object { [string]$_.name })
    Check ($names -ccontains 'doctor.json' -and $names -ccontains 'settings.json' -and $names -ccontains 'components.json' -and $names -ccontains 'version.json') 'bundle-lists-before-save: the listing names doctor, settings, components and version'
    $logNames=@($names | Where-Object { $_ -like 'logs/run-*.jsonl' })
    Check ($logNames.Count -eq 5 -and ($logNames -ccontains ('logs/run-20261101T000007Z-{0:x32}.jsonl' -f 7)) -and ($logNames -cnotcontains ('logs/run-20261101T000001Z-{0:x32}.jsonl' -f 1))) 'bundle-lists-before-save: only the newest 5 run logs are listed'
    Check (@($listing.entries | Where-Object { $_.sizeBytes -isnot [int] -and $_.sizeBytes -isnot [long] -or $_.sizeBytes -le 0 }).Count -eq 0) 'bundle-lists-before-save: every entry has a positive size'
    Check ($listing.redactions -is [int] -and $listing.redactions -ge 1) "bundle-lists-before-save: a redaction count is reported ($($listing.redactions))"
    Throws { New-FastLlmSupportBundle -InstallRoot $bundleInstall -AppRoot $appRoot -OutputPath (Join-Path $outputDir 'no-such-folder/x.zip') -Doctor $bigDoctor -ProfilePath $profile -ComputerName $computer -UserName $userName -ListOnly } 'support-bundle-output-folder-missing'

    # save, then compare with the listing
    $saved=New-FastLlmSupportBundle -InstallRoot $bundleInstall -AppRoot $appRoot -OutputPath $zipPath -Doctor $bigDoctor -ProfilePath $profile -ComputerName $computer -UserName $userName
    Check (Test-Path -LiteralPath $zipPath) 'bundle save: the zip is written'
    Check ((($saved.entries | ForEach-Object { $_.name + ':' + $_.sizeBytes }) -join '|') -ceq (($listing.entries | ForEach-Object { $_.name + ':' + $_.sizeBytes }) -join '|')) 'bundle save: returns the same entry list the listing showed'
    Check (@(Get-ChildItem -LiteralPath $outputDir -Force).Count -eq 1) 'bundle save: no temp file is left beside the zip'
    Throws { New-FastLlmSupportBundle -InstallRoot $bundleInstall -AppRoot $appRoot -OutputPath $zipPath -Doctor $bigDoctor -ProfilePath $profile -ComputerName $computer -UserName $userName } 'support-bundle-output-exists'
    Throws { New-FastLlmSupportBundle -InstallRoot $bundleInstall -AppRoot $appRoot -OutputPath $zipPath -Doctor $bigDoctor -ProfilePath $profile -ComputerName $computer -UserName $userName -ListOnly } 'support-bundle-output-exists'
    $unz=Expand-Bundle $zipPath 'bundle-unzipped'
    $zipNames=@(Get-ChildItem -LiteralPath $unz -Recurse -File | ForEach-Object { $_.FullName.Substring($unz.Length+1).Replace('\','/') } | Sort-Object)
    Check (($zipNames -join '|') -ceq ((@($names) | Sort-Object) -join '|')) 'bundle save: the zip holds exactly the listed entries'
    $allText=((Get-ChildItem -LiteralPath $unz -Recurse -File | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n")
    Check ($allText.IndexOf($computer,[StringComparison]::OrdinalIgnoreCase) -lt 0 -and $allText.IndexOf($userName,[StringComparison]::OrdinalIgnoreCase) -lt 0 -and -not $allText.Contains($sid) -and -not $allText.Contains('6&1A2B3C4D&0&00000019')) 'bundle-redacts-path-variants: nothing identifying survives in any bundle entry'
    $settingsOut=[IO.File]::ReadAllText((Join-Path $unz 'settings.json')) | ConvertFrom-Json
    $settingsNames=@($settingsOut.PSObject.Properties.Name | Sort-Object)
    Check (($settingsNames -join ',') -ceq 'chatPage,componentLicenses,experimentalComponents,serverPort,thinking,updateChannel,updateCheck,vulkanBarMitigation') 'bundle settings: only the allowlisted keys are kept'
    Check ((@($settingsOut.componentLicenses.PSObject.Properties.Name) -join ',') -ceq 'mode' -and $settingsOut.componentLicenses.mode -ceq 'accept-automatically' -and $settingsOut.serverPort -eq 18181) 'bundle settings: componentLicenses keeps only the mode; accepted titles and hosts are dropped'
    Check ((Get-Content -LiteralPath (Join-Path $unz 'settings.json') -Raw) -notmatch 'secretKey|Some licence title|example.invalid') 'bundle settings: unknown keys and licence titles are absent'
    $versionOut=[IO.File]::ReadAllText((Join-Path $unz 'version.json')) | ConvertFrom-Json
    Check ([string]$versionOut.release.version -ceq '2026.11.08.1' -and [string]$versionOut.release.channel -ceq 'stable') 'bundle version.json: the installed release'
    $componentsOut=[IO.File]::ReadAllText((Join-Path $unz 'components.json')) | ConvertFrom-Json
    Check ($null -ne $componentsOut.PSObject.Properties['installed']) 'bundle components.json: lists installed components'
    $doctorOut=[IO.File]::ReadAllText((Join-Path $unz 'doctor.json')) | ConvertFrom-Json
    Check ($doctorOut.installRoot -like '%USERPROFILE%*') 'bundle doctor.json: the doctor report is included, redacted'

    # a missing settings file, missing logs, missing release all still produce a bundle
    $bareInstall=New-Dir 'bundle-bare'
    $bareApp=New-Dir 'bundle-bare-app'
    $bare=New-FastLlmSupportBundle -InstallRoot $bareInstall -AppRoot $bareApp -OutputPath (Join-Path $outputDir 'bare.zip') -Doctor ([pscustomobject]@{a=1})
    Check (@($bare.entries | Where-Object { $_.name -like 'logs/*' }).Count -eq 0 -and (Test-Path -LiteralPath (Join-Path $outputDir 'bare.zip'))) 'bundle: tolerant of missing logs, settings, components file and release'

    # ---- structural redaction: values are redacted, JSON structure never is --------------------------------------------------------
    $parseFailures=@()
    foreach ($entryFile in @(Get-ChildItem -LiteralPath $unz -Recurse -File)) {
        try {
            if ($entryFile.Extension -ceq '.jsonl') { foreach ($jl in @([IO.File]::ReadAllLines($entryFile.FullName) | Where-Object { $_ })) { $null = $jl | ConvertFrom-Json } }
            else { $null = [IO.File]::ReadAllText($entryFile.FullName) | ConvertFrom-Json }
        } catch { $parseFailures += $entryFile.Name }
    }
    Check ($parseFailures.Count -eq 0 -and @(Get-ChildItem -LiteralPath $unz -Recurse -File).Count -ge 8) "bundle: every entry still parses as JSON after redaction ($($parseFailures -join ', '))"
    $quoteProfile='C:'+$sep+'Users'+$sep+'O'+[char]39+'Brien'
    $quoteInstall=New-Dir 'bundle-quote'
    $quoteLogs=Get-LogDir $quoteInstall
    New-Item -ItemType Directory -Path $quoteLogs -Force | Out-Null
    # Windows PowerShell 5.1 writes an apostrophe as the six characters backslash-u-0-0-2-7, and a backslash as two.
    $escapedLine='{"event":"phase","note":"C:'+$sep+$sep+'Users'+$sep+$sep+'O'+$sep+'u0027Brien'+$sep+$sep+'AppData","ctx":1024}'
    [IO.File]::WriteAllText((Join-Path $quoteLogs 'run-20261101T000001Z-aaaa.jsonl'),$escapedLine+"`n")
    $quoteZip=Join-Path $outputDir 'quote.zip'
    $quoteResult=New-FastLlmSupportBundle -InstallRoot $quoteInstall -AppRoot $appRoot -OutputPath $quoteZip -Doctor ([pscustomobject]@{ctx=1024}) -ProfilePath $quoteProfile -ComputerName $computer -UserName 'x1'
    $quoteUnz=Expand-Bundle $quoteZip 'bundle-quote-unzipped'
    $quoteRaw=[IO.File]::ReadAllText((Join-Path $quoteUnz 'logs/run-20261101T000001Z-aaaa.jsonl'))
    $quoteObj=$quoteRaw | ConvertFrom-Json
    Check ($quoteRaw.IndexOf('Brien',[StringComparison]::OrdinalIgnoreCase) -lt 0 -and [string]$quoteObj.note -ceq '%USERPROFILE%'+$sep+'AppData' -and $quoteObj.ctx -eq 1024) 'bundle-redacts-path-variants: a JSONL line with the apostrophe written as a unicode escape (as Windows PowerShell 5.1 does) is redacted'
    Check ($quoteResult.redactions -ge 1) 'bundle: the redaction count reflects the values replaced'
    $numInstall=New-Dir 'bundle-numeric'
    $numZip=Join-Path $outputDir 'numeric.zip'
    $numDoctor=[pscustomobject]@{ ctx=1024; port=1024; tokens=@(1024,2048); label='user 1024 here'; nested=[pscustomobject]@{ n=1024 } }
    $numResult=New-FastLlmSupportBundle -InstallRoot $numInstall -AppRoot $appRoot -OutputPath $numZip -Doctor $numDoctor -ProfilePath $profile -ComputerName $computer -UserName '1024'
    $numUnz=Expand-Bundle $numZip 'bundle-numeric-unzipped'
    $numText=[IO.File]::ReadAllText((Join-Path $numUnz 'doctor.json'))
    $numObj=$numText | ConvertFrom-Json
    Check ($numObj.ctx -eq 1024 -and $numObj.port -eq 1024 -and @($numObj.tokens).Count -eq 2 -and $numObj.nested.n -eq 1024 -and [string]$numObj.label -ceq 'user <user> here') 'bundle-redacts-path-variants: a numeric user name does not touch numbers and the output still parses'
    Check ($numResult.redactions -eq 1) "bundle: only the one string value that held the user name is counted ($($numResult.redactions))"

    # ---- M1: other accounts, 8.3 short forms ---------------------------------------------------------------------------------------
    $other=ConvertTo-FastLlmRedactedText -Text ('see D:'+$sep+'Users'+$sep+'Someone'+$sep+'x and d:/'+'users/other.name/y and C:'+$sep+$sep+'Users'+$sep+$sep+'Third'+$sep+$sep+'z') -ProfilePath $profile -ComputerName $computer -UserName $userName
    Check ($other -ceq ('see %USERPROFILE%'+$sep+'x and %USERPROFILE%/y and %USERPROFILE%'+$sep+$sep+'z')) "bundle-redacts-path-variants: any X:\\Users\\<name> is redacted ($other)"
    $keep='C:'+$sep+'Users'+$sep+'Public'+$sep+'Documents and C:'+$sep+'Users'+$sep+'Default'+$sep+'x'
    Check ((ConvertTo-FastLlmRedactedText -Text $keep -ProfilePath $profile -ComputerName $computer -UserName $userName) -ceq $keep) 'bundle-redacts-path-variants: Public and Default keep the leak-scan exclusions'
    $short='D:'+$sep+'Docs'+$sep+'J'+'RGSMI~1'
    $shortOut=ConvertTo-FastLlmRedactedText -Text ('at '+$short+$sep+'AppData and C:'+$sep+'Users'+$sep+'JRGSMI~1'+$sep+'x') -ProfilePath $profile -ComputerName $computer -UserName $userName -ShortProfilePath $short
    Check ($shortOut -ceq ('at %USERPROFILE%'+$sep+'AppData and %USERPROFILE%'+$sep+'x')) "bundle-redacts-path-variants: the 8.3 short form of the profile folder is redacted ($shortOut)"

    # ---- M2: a relative path resolves against the PowerShell location -------------------------------------------------------------
    $relDir=New-Dir 'bundle-relative'
    Push-Location -LiteralPath $relDir
    try { $rel=New-FastLlmSupportBundle -InstallRoot $bundleInstall -AppRoot $appRoot -OutputPath 'rel.zip' -Doctor ([pscustomobject]@{a=1}) }
    finally { Pop-Location }
    Check ((Test-Path -LiteralPath (Join-Path $relDir 'rel.zip')) -and [IO.Path]::GetFullPath([string]$rel.path) -ceq [IO.Path]::GetFullPath((Join-Path $relDir 'rel.zip')) -and $rel.saved -eq $true) 'bundle save: a relative -SupportBundle path resolves against the PowerShell location and the resolved path is returned'

    # ---- M3: the final move never overwrites -------------------------------------------------------------------------------------
    $raceDir=New-Dir 'bundle-race'
    $raceZip=Join-Path $raceDir 'race.zip'
    $script:FastLlmSupportBundleBeforeMove={ param($Target) [IO.File]::WriteAllText($Target,'precious') }
    try { Throws { New-FastLlmSupportBundle -InstallRoot $bundleInstall -AppRoot $appRoot -OutputPath $raceZip -Doctor ([pscustomobject]@{a=1}) } 'support-bundle-output-exists' }
    finally { $script:FastLlmSupportBundleBeforeMove=$null }
    Check ([IO.File]::ReadAllText($raceZip) -ceq 'precious' -and @(Get-ChildItem -LiteralPath $raceDir -Force).Count -eq 1) 'bundle save: a target created between the check and the move is not replaced and no temp file is left'

    # ---- M4: wording ---------------------------------------------------------------------------------------------------------------
    $uiText=Get-Content -LiteralPath (Join-Path $root 'fast-llm-ui.ps1') -Raw
    Check ($uiText.Contains('Share it only with people you trust') -and -not $uiText.Contains('stays on this PC')) 'window: the saved-bundle text makes no claim about where the file lives'

    # ---- bundle-size-cap ---------------------------------------------------------------------------------------------------------
    $capOut=Join-Path $outputDir 'cap.zip'
    $hugeDoctor=[pscustomobject]@{ blob=('x'*(9*1024*1024)) }
    Throws { New-FastLlmSupportBundle -InstallRoot $bundleInstall -AppRoot $appRoot -OutputPath $capOut -Doctor $hugeDoctor } 'support-bundle-too-large'
    Throws { New-FastLlmSupportBundle -InstallRoot $bundleInstall -AppRoot $appRoot -OutputPath $capOut -Doctor $hugeDoctor -ListOnly } 'support-bundle-too-large'
    Check (-not (Test-Path -LiteralPath $capOut) -and @(Get-ChildItem -LiteralPath $outputDir -Force | Where-Object { $_.Name -like 'cap*' }).Count -eq 0) 'bundle-size-cap: an oversize bundle writes nothing'
    $edgeDoctor=[pscustomobject]@{ blob=('x'*(7*1024*1024)) }
    $edge=New-FastLlmSupportBundle -InstallRoot $bundleInstall -AppRoot $appRoot -OutputPath (Join-Path $outputDir 'edge.zip') -Doctor $edgeDoctor
    Check ((Test-Path -LiteralPath (Join-Path $outputDir 'edge.zip')) -and (Get-Item -LiteralPath (Join-Path $outputDir 'edge.zip')).Length -lt 8*1024*1024) 'bundle-size-cap: a bundle under the cap is written'

    # ---- G3: no network surface in the bundle code ----------------------------------------------------------------------------
    $bundleSource=Get-Content -LiteralPath (Join-Path $root 'src/FastLlm.SupportBundle.ps1') -Raw
    Check ($bundleSource -notmatch 'Invoke-WebRequest|Invoke-RestMethod|System\.Net\.|WebClient|Start-BitsTransfer|Send-MailMessage') 'the support bundle code has no network call (nothing leaves the PC)'

    # ---- no-log-file-flag --------------------------------------------------------------------------------------------------------
    $combos=0;$offenders=@()
    foreach ($port in @(0,18181)) { foreach ($thinking in @('auto','off')) { foreach ($chat in @('off','on')) {
        $matrixRows=@(Get-FastLlmDefaultArgumentsMatrix -Root $root -InstallRoot (Join-Path $temp 'matrix-install') -PlanParameters @{ ServerPort=$port; Thinking=$thinking; ChatPage=$chat })
        $combos++
        foreach ($row in $matrixRows) { foreach ($argument in @($row.arguments)) { if ([string]$argument -match '^--log-(file|disable|prefix|timestamps)$|^-lf$|^--log-file') { $offenders += "$port/$thinking/$chat/$($row.tier)/$argument" } } }
        Check ($matrixRows.Count -gt 20) "no-log-file-flag: matrix port=$port thinking=$thinking chatPage=$chat produced $($matrixRows.Count) rows"
    } } }
    Check ($combos -eq 8 -and $offenders.Count -eq 0) "no-log-file-flag: no argument list contains --log-file over all 8 setting combinations ($($offenders -join ', '))"
    $runtimeSource=Get-Content -LiteralPath (Join-Path $root 'src/FastLlm.Runtime.ps1') -Raw
    $recipesSource=Get-Content -LiteralPath (Join-Path $root 'src/FastLlm.Recipes.ps1') -Raw
    Check ($runtimeSource -notmatch '--log-file' -and $recipesSource -notmatch '--log-file' -and $runtimeSource.Contains('$hostProcess.DiscardOutput()')) 'no-log-file-flag: the source never builds --log-file and still discards server output after the canary'

    # ---- CLI: doctor -SupportBundle <zip> [-ListOnly] ----------------------------------------------------------------------------
    $cli=Join-Path $root 'fast-llm.ps1'
    $elevated=$false
    if ($env:OS -eq 'Windows_NT') { $elevated=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    if ($elevated) { Write-Host 'SKIP: CLI doctor cases (elevated token)' }
    else {
        $cliInstall=Join-Path (New-Dir 'cli') 'install'
        $cliZip=Join-Path $temp 'cli-support.zip'
        $pwshPath=(Get-Process -Id $PID).Path
        function Invoke-CliChild([string[]]$CliArguments) {
            $info=New-Object Diagnostics.ProcessStartInfo
            $info.FileName=$pwshPath
            $info.Arguments=(@('-NoLogo','-NoProfile','-NonInteractive','-File',('"'+$cli+'"')) + @($CliArguments | ForEach-Object { if ($_ -match '\s') { '"'+$_+'"' } else { $_ } })) -join ' '
            $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.UseShellExecute=$false
            $child=[Diagnostics.Process]::Start($info)
            $out=$child.StandardOutput.ReadToEnd();$err=$child.StandardError.ReadToEnd()
            if (-not $child.WaitForExit(120000)) { $child.Kill(); throw 'CLI child timed out' }
            return [pscustomobject]@{ exit=$child.ExitCode; out=$out; err=$err }
        }
        $listed=Invoke-CliChild @('doctor','-InstallRoot',$cliInstall,'-SupportBundle',$cliZip,'-ListOnly')
        $listedJson=$null
        try { $listedJson=$listed.out | ConvertFrom-Json } catch { }
        Check ($listed.exit -eq 0 -and $null -ne $listedJson -and @($listedJson.entries).Count -ge 4 -and $listedJson.redactions -ge 0) "bundle-lists-before-save: doctor -SupportBundle -ListOnly prints the entries and the redaction count as JSON ($($listed.err))"
        Check (-not (Test-Path -LiteralPath $cliZip)) 'bundle-lists-before-save: the CLI -ListOnly writes no zip'
        $savedCli=Invoke-CliChild @('doctor','-InstallRoot',$cliInstall,'-SupportBundle',$cliZip)
        Check ($savedCli.exit -eq 0 -and (Test-Path -LiteralPath $cliZip)) "bundle save: doctor -SupportBundle writes the zip ($($savedCli.err))"
        $again=Invoke-CliChild @('doctor','-InstallRoot',$cliInstall,'-SupportBundle',$cliZip)
        Check ($again.exit -ne 0 -and ($again.err + $again.out) -match 'support-bundle-output-exists') 'bundle save: the CLI refuses an existing output path'
        $misuse=Invoke-CliChild @('plan','-InstallRoot',$cliInstall,'-SupportBundle',(Join-Path $temp 'x.zip'))
        Check ($misuse.exit -ne 0 -and ($misuse.err + $misuse.out) -match 'supported only by doctor') 'bundle save: -SupportBundle is refused outside doctor'
        $misuse2=Invoke-CliChild @('doctor','-InstallRoot',$cliInstall,'-ListOnly')
        Check ($misuse2.exit -ne 0 -and ($misuse2.err + $misuse2.out) -match 'only with doctor -SupportBundle') 'bundle save: -ListOnly alone is refused'
    }

    # ---- window: the pure helpers and the wiring ------------------------------------------------------------------------------
    . (Join-Path $root 'src/FastLlm.UiFlow.ps1')
    Check ((Get-FastLlmUiSupportBundleFileName -Now ([DateTime]'2026-11-08T09:05:00')) -ceq 'FastLLM-support-20261108-0905.zip') 'window: the default file name is FastLLM-support-<yyyyMMdd-HHmm>.zip'
    $listText=Format-FastLlmUiSupportBundleList -Listing ([pscustomobject]@{ entries=@([pscustomobject]@{name='doctor.json';sizeBytes=2188},[pscustomobject]@{name='logs/run-x.jsonl';sizeBytes=10}); redactions=3 })
    Check ($listText.Contains('doctor.json  (3 KiB)') -and $listText.Contains('logs/run-x.jsonl  (1 KiB)') -and $listText.Contains('3 item(s)') -and $listText.Contains('does not upload it')) 'window: the list dialog shows every entry with its size, the redaction count and the local-only statement'
    $ui=Get-Content -LiteralPath (Join-Path $root 'fast-llm-ui.ps1') -Raw
    Check ($ui.Contains('$bundleButton=ButtonAt (''Save support bundle''+[string][char]0x2026) $rowSlotX[4] $rowY $rowWidth') -and $ui.Contains('$logsButton=ButtonAt ''Open logs'' $rowSlotX[5] $rowY $rowWidth')) 'window: Save support bundle... is in slot 4 and Open logs in slot 5'
    Check ($ui.Contains("LaunchSideStep 'bundle list' (@('doctor','-SupportBundle',`$probe,'-ListOnly')+`$script:selection)") -and $ui.Contains("LaunchSideStep 'bundle save' (@('doctor','-SupportBundle',`$chosen)+`$script:selection)")) 'window: the list-only step runs first, the save step after the dialogs'
    Check ($ui.Contains("InitialDirectory=[Environment]::GetFolderPath('Desktop')") -and $ui.Contains('FastLlm.SupportBundle.ps1')) 'window: the Save dialog defaults to the Desktop and the bundle file is dot-sourced'
    $parseErrors=$null;$tokens=$null
    [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'fast-llm-ui.ps1'),[ref]$tokens,[ref]$parseErrors)
    Check (@($parseErrors).Count -eq 0) 'window: fast-llm-ui.ps1 parses'
    $psmSource=Get-Content -LiteralPath (Join-Path $root 'src/FastLlm.psm1') -Raw
    Check ($psmSource.Contains("'FastLlm.RunLog.ps1'") -and -not $psmSource.Contains('FastLlm.SupportBundle.ps1') -and (Get-Command Write-FastLlmRunLogEvent).Source -ceq 'FastLlm' -and (Get-Command Invoke-FastLlmRunLogRotation).Source -ceq 'FastLlm') 'the run log is in the module and exported; the support bundle is entry-layer only'

    Write-Host "Run log tests passed: $script:count checks."
}
finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
