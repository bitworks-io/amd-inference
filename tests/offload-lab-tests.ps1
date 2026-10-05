#requires -Version 5.1
$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot '../src/FastLlm.OffloadLab.ps1'
$tokens=$null;$errors=$null
$null=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw ('Offload lab parser errors: '+(@($errors | ForEach-Object Message) -join ' | '))}
. $source
$passes=0
function Assert($condition,$message){if(-not $condition){throw $message};$script:passes++}
function Fails($operation,$message){$failed=$false;try{& $operation}catch{$failed=$true};Assert $failed $message}
function Wait-OffloadSupervisorReady($Worker,[scriptblock]$ReadState,[int]$TimeoutSeconds){
    $deadline=[Diagnostics.Stopwatch]::StartNew()
    while($deadline.Elapsed.TotalSeconds -lt $TimeoutSeconds){
        if($Worker.Process.HasExited){
            $tail=([string]$Worker.Snapshot() -replace '[\r\n\x00-\x1f]+',' ')
            throw ('Offload supervisor worker exited before lab-ready (exit '+$Worker.Process.ExitCode+'). Output: '+$tail.Substring(0,[Math]::Min(400,$tail.Length)))
        }
        $state=$null
        try{$state=& $ReadState}catch{}
        if($state.phase -eq 'lab-ready'){return $state}
        if($state.phase -eq 'lab-failed'){throw 'Offload supervisor worker reported lab-failed before lab-ready.'}
        Start-Sleep -Milliseconds 100
    }
    $tail=([string]$Worker.Snapshot() -replace '[\r\n\x00-\x1f]+',' ')
    throw ('Offload supervisor worker did not reach lab-ready before the test deadline. Output: '+$tail.Substring(0,[Math]::Min(400,$tail.Length)))
}
$good="0.01 I llama load_tensors: offloaded 20/66 layers to GPU`n0.02 I llama load_tensors: Vulkan0 model buffer size = 6144.00 MiB"
$placement=ConvertFrom-FastLlmOffloadPlacementLog -Text $good -Device 'Vulkan0' -RequestedLayers 20
Assert ($placement.reportedGpuLayers -eq 20 -and $placement.reportedTotalLayers -eq 66 -and $placement.gpuModelBufferMiB -eq 6144) 'Exact partial placement failed.'
Assert (-not $placement.physicalResidencyVerified -and -not $placement.performanceQualified -and $null -eq $placement.cpuModelBufferMiB) 'Experimental evidence was overstated.'
Assert ($placement.cpuModelBufferEvidence -match '^unavailable:' -and $null -eq $placement.cpuModelBufferKind) 'Missing CPU evidence was not explicitly unavailable.'
$cpuLine='load_tensors: CPU model buffer size = 8123.45 MiB'
$mappedLine='load_tensors: CPU_Mapped model buffer size = 8123.45 MiB'
$cpuPlacement=ConvertFrom-FastLlmOffloadPlacementLog -Text ($good+"`n"+$cpuLine) -Device 'Vulkan0' -RequestedLayers 20
Assert ($cpuPlacement.cpuModelBufferMiB -eq 8123.45 -and $cpuPlacement.cpuModelBufferKind -ceq 'CPU' -and -not $cpuPlacement.physicalResidencyVerified) 'CPU model-buffer evidence was lost or overstated.'
$mappedPlacement=ConvertFrom-FastLlmOffloadPlacementLog -Text ($good+"`n"+$mappedLine) -Device 'Vulkan0' -RequestedLayers 20
Assert ($mappedPlacement.cpuModelBufferMiB -eq 8123.45 -and $mappedPlacement.cpuModelBufferKind -ceq 'CPU_Mapped') 'CPU_Mapped model-buffer evidence was lost.'
Fails {ConvertFrom-FastLlmOffloadPlacementLog -Text ($good+"`n"+$cpuLine+"`n"+$mappedLine) -Device 'Vulkan0' -RequestedLayers 20} 'Ambiguous CPU and CPU_Mapped buffers passed.'
Fails {ConvertFrom-FastLlmOffloadPlacementLog -Text ($good+"`n"+$cpuLine+"`n"+$cpuLine) -Device 'Vulkan0' -RequestedLayers 20} 'Duplicate CPU buffer passed.'
Fails {ConvertFrom-FastLlmOffloadPlacementLog -Text ($good+"`n"+'load_tensors: CPU model buffer size = NaN MiB') -Device 'Vulkan0' -RequestedLayers 20} 'Malformed CPU numeric buffer passed.'
Fails {ConvertFrom-FastLlmOffloadPlacementLog -Text ($good+"`n"+$cpuLine+"`n"+'load_tensors: CPU model buffer size = NaN MiB') -Device 'Vulkan0' -RequestedLayers 20} 'Valid plus malformed CPU buffer passed.'
Fails {ConvertFrom-FastLlmOffloadPlacementLog -Text ($good+"`n"+$cpuLine) -Device 'Vulkan0' -RequestedLayers 20 -CpuBufferLikeLines 2} 'Native CPU-like count mismatch passed.'
Fails {ConvertFrom-FastLlmOffloadPlacementLog -Text ($good+"`n"+($cpuLine -replace '8123.45','0.00')) -Device 'Vulkan0' -RequestedLayers 20} 'Zero CPU buffer passed.'
Fails {ConvertFrom-FastLlmOffloadPlacementLog -Text ($good+"`n"+($cpuLine -replace '8123.45','999999999999999999999999999999999999')) -Device 'Vulkan0' -RequestedLayers 20} 'Oversized CPU numeric buffer passed.'
Fails {ConvertFrom-FastLlmOffloadPlacementLog -Text $good -Device 'Vulkan0' -RequestedLayers 21} 'Wrong layer count passed.'
Fails {ConvertFrom-FastLlmOffloadPlacementLog -Text $good -Device 'Vulkan1' -RequestedLayers 20} 'Wrong device passed.'
Fails {ConvertFrom-FastLlmOffloadPlacementLog -Text ($good+"`n"+$good) -Device 'Vulkan0' -RequestedLayers 20} 'Duplicate evidence passed.'
Fails {ConvertFrom-FastLlmOffloadPlacementLog -Text $good -Device 'Vulkan0' -RequestedLayers 20 -Overflow $true} 'Overflow passed.'
Fails {ConvertFrom-FastLlmOffloadPlacementLog -Text ($good -replace '20/66','66/66') -Device 'Vulkan0' -RequestedLayers 66} 'All-GPU run was accepted as partial offload.'
Fails {ConvertFrom-FastLlmOffloadPlacementLog -Text ($good -replace '6144.00','9999999999999999999999999999999999999999999') -Device 'Vulkan0' -RequestedLayers 20} 'Oversized numeric evidence passed.'
Fails {Assert-FastLlmOffloadRoots '/tmp/artifacts' '/tmp/artifacts/lab'} 'Nested roots passed.'
Fails {Assert-FastLlmOffloadRoots '/tmp/artifacts' '/tmp/artifacts'} 'Identical roots passed.'
Assert ((Assert-FastLlmOffloadMemoryBudget -AvailableBytes 30000000000 -ModelBytes 16000000000).fitVerified -eq $false) 'RAM gate claimed fit.'
Fails {Assert-FastLlmOffloadMemoryBudget -AvailableBytes 20000000000 -ModelBytes 16000000000} 'Insufficient RAM passed.'
$text=Get-Content -LiteralPath $source -Raw
Assert ($text.Contains("kind='fastllm-offload-lab-run'") -and $text.Contains("phase='lab-loading'") -and $text.Contains("$"+'state.phase='+"'lab-ready'")) 'Lab-only phase contract missing.'
Assert ($text.Contains("'--fit','off'") -and $text.Contains("'--port','18080'") -and $text.Contains('Test-FastLlmModelConsentReceipt')) 'Fixed launch/consent contract missing.'
Assert (-not $text.Contains('Get-FastLlmPlan') -and -not $text.Contains('Invoke-FastLlmSupervisedServer') -and -not $text.Contains('Start-FastLlmServer')) 'Normal all-GPU path leaked into lab.'
$repo=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/FastLlm.psm1') -Force
$module=Get-Module FastLlm
& $module { Initialize-FastLlmProcessHost }
$captureHost=New-Object Bitworks.FastLlm.ProcessHost
try{
    $captureInfo=New-Object Diagnostics.ProcessStartInfo
    $captureInfo.FileName=(Get-Process -Id $PID).Path
    $captureCommand="Write-Output 'load_tensors: CPU model buffer size = 12.50 MiB'; Write-Output 'load_tensors: CPU_Mapped model buffer size = 3.25 MiB'; Write-Output 'load_tensors: CPU model buffer size = NaN MiB'; Write-Output 'unsafe-path /tmp/not-placement'"
    $captureInfo.Arguments=& $module {param($A) Join-FastLlmProcessArguments $A} @('-NoLogo','-NoProfile','-Command',$captureCommand)
    $captureHost.Start($captureInfo)
    Assert ($captureHost.Process.WaitForExit(10000)) 'Bounded CPU capture child did not exit.'
    $captureHost.Process.WaitForExit()
    $captured=$captureHost.PlacementSnapshot()
    Assert ($captured -match 'load_tensors: CPU model buffer size = 12.50 MiB' -and
        $captured -match 'load_tensors: CPU_Mapped model buffer size = 3.25 MiB' -and
        $captured -notmatch 'NaN|unsafe-path' -and $captureHost.CpuBufferLikeLines -eq 3) 'CPU placement capture included untrusted text or lost malformed-line count.'
    Fails {ConvertFrom-FastLlmOffloadPlacementLog -Text ($good+"`n"+$captured) -Device 'Vulkan0' -RequestedLayers 20 -CpuBufferLikeLines $captureHost.CpuBufferLikeLines} 'Native malformed/duplicate CPU capture passed parsing.'
}finally{$captureHost.Dispose()}
$earlyWorker=New-Object Bitworks.FastLlm.ProcessHost
try{
    $earlyInfo=New-Object Diagnostics.ProcessStartInfo
    $earlyInfo.FileName=(Get-Process -Id $PID).Path
    $earlyInfo.Arguments=& $module {param($A) Join-FastLlmProcessArguments $A} @('-NoLogo','-NoProfile','-Command','exit 7')
    $earlyWorker.Start($earlyInfo)
    $earlyReason=$null
    try{Wait-OffloadSupervisorReady $earlyWorker { [pscustomobject]@{phase='lab-loading'} } 3}catch{$earlyReason=$_.Exception.Message}
    Assert ($earlyReason -match 'exited before lab-ready \(exit 7\)') 'An exited supervisor worker was not rejected before readiness.'
}finally{$earlyWorker.Dispose()}
$neverReadyWorker=New-Object Bitworks.FastLlm.ProcessHost
$neverReadyPid=$null
$neverReadyStartTicks=$null
try{
    $neverReadyInfo=New-Object Diagnostics.ProcessStartInfo
    $neverReadyInfo.FileName=(Get-Process -Id $PID).Path
    $neverReadyInfo.Arguments=& $module {param($A) Join-FastLlmProcessArguments $A} @('-NoLogo','-NoProfile','-Command','Start-Sleep -Seconds 30')
    $neverReadyWorker.Start($neverReadyInfo)
    $neverReadyPid=$neverReadyWorker.Process.Id
    $neverReadyStartTicks=[long]$neverReadyWorker.Process.StartTime.ToUniversalTime().Ticks
    $neverReadyReason=$null
    try{Wait-OffloadSupervisorReady $neverReadyWorker { [pscustomobject]@{phase='lab-loading'} } 1}catch{$neverReadyReason=$_.Exception.Message}
    Assert ($neverReadyReason -match '^Offload supervisor worker did not reach lab-ready before the test deadline\.') 'A never-ready supervisor worker escaped its test deadline.'
}finally{$neverReadyWorker.Dispose()}
$cleanupEvidence='unverified'
$cleanupClock=[Diagnostics.Stopwatch]::StartNew()
do{
    $probe=$null
    try{
        $probe=[Diagnostics.Process]::GetProcessById($neverReadyPid)
        if($probe.HasExited){$cleanupEvidence='exited';break}
        $observedStartTicks=[long]$probe.StartTime.ToUniversalTime().Ticks
        if($observedStartTicks -ne $neverReadyStartTicks){$cleanupEvidence='pid-reused';break}
        $cleanupEvidence='same-instance-alive'
    }catch [ArgumentException]{$cleanupEvidence='missing';break}
    catch{$cleanupEvidence='unverified-'+$_.Exception.GetType().Name}
    finally{if($probe){$probe.Dispose()}}
    if($cleanupClock.ElapsedMilliseconds -ge 2000){break}
    Start-Sleep -Milliseconds 100
}while($true)
Assert ($neverReadyPid -gt 0 -and $neverReadyStartTicks -gt 0 -and $cleanupEvidence -in @('missing','exited','pid-reused')) ('Timed-out test worker cleanup could not be verified: '+$cleanupEvidence)
$mock=Join-Path $PSScriptRoot 'helpers/mock-server.ps1'
$tempParent=if($env:OS -eq 'Windows_NT'){[IO.Path]::GetTempPath()}elseif(Test-Path -LiteralPath '/private/tmp' -PathType Container){'/private/tmp'}else{[IO.Path]::GetTempPath()}
$temp=Join-Path $tempParent ('fast-llm-offload-test-'+[Guid]::NewGuid().ToString('N'))
try{
    $catalog=Get-FastLlmCatalog (Join-Path $repo 'config/catalog.json')
    $original=@($catalog.models | Where-Object { $_.id -eq 'qwen3.8-27b-ud-q4-k-m' })[0]
    $changed=($original | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
    $changed.repository='different-provider/conversion'
    $consentRoot=Join-Path $temp 'consent'
    & $module {param($M,$R) Write-FastLlmModelConsentReceipt -Model $M -InstallRoot $R -AcceptanceMode explicit-switch} $original $consentRoot
    Assert (& $module {param($S,$M,$R) . $S; Test-FastLlmOffloadExactConsent -Model $M -ArtifactRoot $R} $source $original $consentRoot) 'Unchanged exact consent failed.'
    Assert (-not (& $module {param($S,$M,$R) . $S; Test-FastLlmOffloadExactConsent -Model $M -ArtifactRoot $R} $source $changed $consentRoot)) 'Changed artifact provenance inherited old consent.'
    Fails {& $module {param($S,$M,$R) . $S; Get-FastLlmOffloadConsentRefreshMode -Model $M -ArtifactRoot $R -AcceptModelLicense $false -Unattended $true} $source $changed $consentRoot} 'Unattended changed provenance passed without new acceptance.'
    Assert ((& $module {param($S,$M,$R) . $S; Get-FastLlmOffloadConsentRefreshMode -Model $M -ArtifactRoot $R -AcceptModelLicense $true -Unattended $true} $source $changed $consentRoot) -eq 'explicit-switch') 'Explicit refreshed consent was not available.'
    $receiptPath=& $module {param($M,$R) Get-FastLlmModelConsentPath -Model $M -InstallRoot $R} $changed $consentRoot
    $receiptBytes=[IO.File]::ReadAllBytes($receiptPath)
    try{
        [IO.File]::WriteAllText($receiptPath, ('x'*20000))
        Fails {& $module {param($S,$M,$R) . $S; Get-FastLlmOffloadConsentRefreshMode -Model $M -ArtifactRoot $R -AcceptModelLicense $true -Unattended $true} $source $changed $consentRoot} 'Oversized existing consent was read or renewed.'
    }finally{[IO.File]::WriteAllBytes($receiptPath,$receiptBytes)}
    $prior=& $module {param($S,$M,$R) . $S; Save-FastLlmOffloadPriorConsent -Model $M -ArtifactRoot $R} $source $changed $consentRoot
    Assert ((Test-Path -LiteralPath $prior -PathType Leaf) -and ((Read-FastLlmJson $prior).artifactRepository -eq $original.repository)) 'Prior consent backup was not recoverable.'
    & $module {param($M,$R) Write-FastLlmModelConsentReceipt -Model $M -InstallRoot $R -AcceptanceMode explicit-switch} $changed $consentRoot
    $liveReceipt=& $module {param($M,$R) Read-FastLlmJson (Get-FastLlmModelConsentPath -Model $M -InstallRoot $R)} $changed $consentRoot
    Assert (((Read-FastLlmJson $prior).artifactRepository -ceq $original.repository) -and
        ($liveReceipt.artifactRepository -ceq $changed.repository)) 'Renewed receipt replaced the live file while retaining the old recoverable receipt.'
    Assert (& $module {param($S,$M,$R) . $S; Test-FastLlmOffloadExactConsent -Model $M -ArtifactRoot $R} $source $changed $consentRoot) 'Renewed exact consent was not recognized.'
    Assert ($text.IndexOf('if($refreshMode){$prior=Save-FastLlmOffloadPriorConsent') -lt $text.IndexOf('$modelPath=Install-FastLlmModel -Plan $plan')) 'Offload renewal must preserve the prior receipt before acquisition can replace it.'
    $plan=[pscustomobject]@{
        model=[pscustomobject]@{id='lab-mock';sha256=('a'*64);cacheTypeK='f16';cacheTypeV='f16'}
        enginePath=(Get-Process -Id $PID).Path
        serverArguments=@('-NoLogo','-NoProfile','-File',$mock,'-Port','18080','-Mode','exit','-Model','lab-mock','-Context','1024')
        endpoint='http://127.0.0.1:18080/v1';device='Vulkan0';gpuLayers=39;contextSize=1024
        modelPath='mock-model';selectedAdapter=[pscustomobject]@{device='Vulkan0';name='mock AMD';reportedTotalVramMiB=20480;reportedFreeVramMiB=18000}
        memoryPreflight=[pscustomobject]@{fitVerified=$false};catalogSha256=('b'*64);engineSha256=('c'*64)
    }
    $runRoot=Join-Path $temp 'failed'
    $lock=Enter-FastLlmOperation $runRoot
    try{
        Fails { & $module {param($S,$P,$R) . $S; Invoke-FastLlmOffloadLabSupervisor -Plan $P -LabRunRoot $R -LoadTimeoutSeconds 5} $source $plan $runRoot } 'Early-exiting native child was accepted.'
        $status=Read-FastLlmJson (Join-Path $runRoot 'state/status.json')
        Assert ($status.kind -eq 'fastllm-offload-lab-run' -and $status.phase -eq 'lab-failed' -and $status.processIdentity.pid -gt 0) 'Failed lab child state/identity was not retained.'
        Assert (-not (Test-Path (Join-Path $runRoot 'runtime-sandboxes') -PathType Leaf)) 'Sandbox shape became unsafe.'
    }finally{$lock.Dispose()}
    $runRoot=Join-Path $temp 'success'
    $plan.serverArguments=@('-NoLogo','-NoProfile','-File',$mock,'-Port','18080','-Mode','partial','-Model','lab-mock','-Context','1024')
    $lock=Enter-FastLlmOperation $runRoot
    $worker=New-Object Bitworks.FastLlm.ProcessHost
    try{
        $planPath=Join-Path $runRoot 'synthetic-plan.json'
        [IO.File]::WriteAllText($planPath,($plan|ConvertTo-Json -Depth 12))
        $workerInfo=New-Object Diagnostics.ProcessStartInfo
        $workerInfo.FileName=(Get-Process -Id $PID).Path
        $workerInfo.Arguments=& $module {param($A) Join-FastLlmProcessArguments $A} @('-NoLogo','-NoProfile','-File',(Join-Path $PSScriptRoot 'helpers/offload-supervisor-worker.ps1'),'-PlanPath',$planPath,'-LabRunRoot',$runRoot,'-SourcePath',$source,'-ModulePath',(Join-Path $repo 'src/FastLlm.psm1'))
        $worker.Start($workerInfo)
        $ready=Wait-OffloadSupervisorReady $worker { & $module {param($S,$R) . $S; Get-FastLlmOffloadLabStatus -LabRunRoot $R} $source $runRoot } 20
        Assert ($ready.phase -eq 'lab-ready' -and $ready.active) 'Healthy partial mock did not reach active lab-ready.'
        & $module {param($S,$R) . $S; Request-FastLlmOffloadLabStop -LabRunRoot $R} $source $runRoot
        Assert ($worker.Process.WaitForExit(10000)) 'Offload supervisor worker ignored its run-scoped stop deadline.'
        Assert ($worker.Process.ExitCode -eq 0) 'Healthy partial mock worker did not stop cleanly.'
        $status=Read-FastLlmJson (Join-Path $runRoot 'state/status.json')
        Assert ($status.phase -eq 'lab-stopped' -and $status.placement.reportedGpuLayers -eq 39 -and $status.placement.reportedTotalLayers -eq 41) 'Partial reported placement was not persisted.'
        Assert ($status.recipe.selectedAdapters[0].reportedTotalVramMiB -eq 20480 -and $status.recipe.requestedArguments -contains '-Mode') 'Lab recipe did not preserve requested arguments and probed adapter.'
        Assert ($status.canary.streaming -and -not $status.performanceQualified -and -not $status.physicalResidencyVerified) 'Lab canary or qualification state was incorrect.'
        Assert (-not (Test-Path (Join-Path $runRoot ('state/stop-'+$status.runId)))) 'Run-scoped stop request was not cleaned up.'
    }finally{
        $worker.Dispose()
        $lock.Dispose()
    }
}finally{
    if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}
}
Write-Host "$passes offload lab focused assertions passed. Native Windows loading and placement remain unqualified."
