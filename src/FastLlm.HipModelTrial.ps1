#requires -Version 5.1
# Private b1339 ROCm experiment. Dot-source only inside an imported FastLlm module scope.
# No public catalog backend, installer, downloader, or benchmark qualification is changed.

function Assert-FastLlmHipTrialRoots {
    param([string]$ArtifactRoot,[string]$CandidateRoot,[string]$RunRoot)
    Assert-FastLlmOffloadRoots -ArtifactRoot $ArtifactRoot -LabRunRoot $RunRoot
    Assert-FastLlmHipNoReparseAncestors -Path $CandidateRoot
    Assert-FastLlmOffloadRootPath $CandidateRoot
    $candidate=[IO.Path]::GetFullPath($CandidateRoot).TrimEnd('\')
    $run=[IO.Path]::GetFullPath($RunRoot).TrimEnd('\')
    $artifact=[IO.Path]::GetFullPath($ArtifactRoot).TrimEnd('\')
    $profile=[IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')
    if(-not $candidate.StartsWith($profile+'\',[StringComparison]::OrdinalIgnoreCase) -or
       -not $run.StartsWith($profile+'\',[StringComparison]::OrdinalIgnoreCase)){
        throw 'Private HIP candidate and run roots must remain inside the current standard-user profile.'
    }
    foreach($other in @($run,$artifact)){
        if($candidate.Equals($other,[StringComparison]::OrdinalIgnoreCase) -or
            $candidate.StartsWith($other+'\',[StringComparison]::OrdinalIgnoreCase) -or
            $other.StartsWith($candidate+'\',[StringComparison]::OrdinalIgnoreCase)){
            throw 'HIP candidate, model artifact and run roots must be separate non-overlapping directories.'
        }
    }
}

function Get-FastLlmHipTrialCatalogModel {
    param([string]$CatalogPath,[string]$ModelId)
    $entry=Get-FastLlmOffloadModel -CatalogPath $CatalogPath -ModelId $ModelId
    $model=$entry.model
    if([string]$model.family -cne 'Qwen3.8' -or [string]$model.parameters -cne '27B' -or
        [string]$model.servingMode -notmatch '^text-only;'){
        throw 'The private HIP trial accepts only exact catalog Qwen3.8-27B text GGUF artifacts.'
    }
    return $entry
}

function Assert-FastLlmHipTrialModel {
    param($Model,[string]$ArtifactRoot)
    $modelRoot=Join-FastLlmContainedPath -Root $ArtifactRoot -Child 'models'
    Assert-FastLlmOffloadRootPath $modelRoot
    $path=Join-FastLlmContainedPath -Root $modelRoot -Child ([string]$Model.file)
    $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
       [int64]$item.Length -ne [int64]$Model.sizeBytes -or
       -not (Test-FastLlmFileHash -Path $path -Sha256 ([string]$Model.sha256))){
        throw 'Exact cached HIP trial model size/hash does not match the catalog.'
    }
    if(-not (Test-FastLlmOffloadExactConsent -Model $Model -ArtifactRoot $ArtifactRoot)){
        throw 'Exact prior catalog model consent is absent. HIP trial never accepts licenses.'
    }
    return $path
}

function Assert-FastLlmHipNormalServiceStopped {
    param([Parameter(Mandatory=$true)][string]$ArtifactRoot)
    # This must run BEFORE this trial obtains ArtifactRoot's operation lock.
    # Get-FastLlmStatus treats any held operation.lock as active, including our own.
    $normal=Get-FastLlmStatus -InstallRoot $ArtifactRoot
    if($normal.active){throw 'Stop the normal inference service before a private HIP GPU trial.'}
}

function Get-FastLlmHipTrialSourceSha256 {
    $path=Join-Path $PSScriptRoot 'FastLlm.HipModelTrial.ps1'
    $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
       $item.Length -le 0 -or $item.Length -gt 262144){throw 'HIP trial source file is unavailable or unsafe.'}
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Invoke-FastLlmHipTrialTextProbe {
    param([string]$EnginePath,[string]$CandidateRoot,[string]$Argument,[string]$RunRoot,[int]$TimeoutSeconds=20)
    Initialize-FastLlmProcessHost
    $sandbox=New-FastLlmRuntimeSandbox -InstallRoot $RunRoot
    $child=New-Object Bitworks.FastLlm.ProcessHost
    $timer=[Diagnostics.Stopwatch]::StartNew()
    try{
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=$EnginePath;$info.Arguments=$Argument;$info.WorkingDirectory=$CandidateRoot
        foreach($name in @($info.EnvironmentVariables.Keys)){
            if((Test-FastLlmEnvironmentNameRequiresClearing -Name $name) -or
               $name -match '^(?i:ROCR_|CUDA_|VULKAN_|AMD_)' -or $name -eq 'GPU_DEVICE_ORDINAL'){
                $info.EnvironmentVariables.Remove([string]$name)
            }
        }
        $info.EnvironmentVariables['APPDATA']=$sandbox.appData
        $info.EnvironmentVariables['PROGRAMDATA']=$sandbox.programData
        $info.EnvironmentVariables['PATH']="$CandidateRoot;$([Environment]::SystemDirectory);$env:SystemRoot"
        $child.Start($info)
        $deadline=$TimeoutSeconds*1000
        $remaining=[Math]::Max(1,$deadline-[int]$timer.ElapsedMilliseconds)
        if(-not $child.Process.WaitForExit($remaining)){throw "HIP $Argument probe exceeded deadline."}
        while(-not $child.OutputCompleted -and $timer.ElapsedMilliseconds -lt $deadline){Start-Sleep -Milliseconds 10}
        if(-not $child.OutputCompleted -or $child.OutputTruncated -or $child.Process.ExitCode -ne 0){
            throw "HIP $Argument probe failed or produced incomplete output."
        }
        $output=$child.Snapshot()
        if($output.Length -gt 200000){throw "HIP $Argument probe output exceeded limit."}
        return $output
    }finally{$child.Dispose();Remove-FastLlmRuntimeSandbox -Sandbox $sandbox}
}

function Assert-FastLlmHipTrialHelpFlags {
    param([string]$HelpText)
    $required=@('--model','--offline','--no-mmproj','--spec-type','--alias','--host','--port',
        '--cors-origins','--no-cors-credentials','--ctx-size','--parallel','--n-gpu-layers',
        '--fit','--device','--split-mode','--flash-attn','--cache-type-k','--cache-type-v',
        '--jinja','--metrics','--log-verbosity','--no-agent','--no-ui')
    foreach($flag in $required){
        if($HelpText -cnotmatch ('(?<![A-Za-z0-9-])'+[regex]::Escape($flag)+'(?![A-Za-z0-9-])')){
            throw "Pinned HIP candidate help does not advertise required flag $flag. No model launch."
        }
    }
}

function ConvertFrom-FastLlmHipTrialDeviceList {
    param([string]$Text,[string]$Device)
    if($Device -cne 'ROCm0' -or -not (Test-FastLlmHipDeviceRow -OutputText $Text)){
        throw 'Private HIP trial requires one exact discrete AMD ROCm0 device row.'
    }
    $rows=@(ConvertFrom-LlamaDeviceList -Text $Text -Backend 'ROCm' | Where-Object {
        $_.device -ceq $Device -and $_.isAmd -and -not $_.isIntegrated
    })
    if($rows.Count -ne 1){throw 'ROCm0 did not match exactly one AMD discrete catalog probe adapter.'}
    return $rows[0]
}

function Get-FastLlmHipTrialStatus {
    param([Parameter(Mandatory=$true)][string]$RunRoot)
    Assert-FastLlmHipLabIdentity
    Assert-FastLlmOffloadRootPath $RunRoot
    $state=Get-FastLlmStatus -InstallRoot $RunRoot
    if(-not $state.PSObject.Properties['schemaVersion'] -or
       -not $state.PSObject.Properties['kind'] -or
       $state.schemaVersion -ne 1 -or $state.kind -cne 'fastllm-hip-b1339-private-trial'){
        throw 'RunRoot does not contain a HIP private-trial state.'
    }
    if(-not $state.active -and $state.phase -in @('hip-lab-loading','hip-lab-checking','hip-lab-ready')){
        $state.phase='hip-lab-interrupted'
    }
    return $state
}

function Request-FastLlmHipTrialStop {
    param([Parameter(Mandatory=$true)][string]$RunRoot)
    Assert-FastLlmHipLabIdentity
    $state=Get-FastLlmHipTrialStatus -RunRoot $RunRoot
    if(-not $state.active -or $state.phase -notin @('hip-lab-loading','hip-lab-checking','hip-lab-ready') -or
       $state.runId -cnotmatch '^[0-9a-f]{32}$'){
        throw 'No active private HIP trial belongs to this run root.'
    }
    $root=Get-FastLlmStateRoot -InstallRoot $RunRoot
    $path=Join-FastLlmContainedPath -Root $root -Child ('stop-'+$state.runId)
    if(Test-Path -LiteralPath $path){
        if((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unsafe HIP stop path.'}
    }else{$stream=[IO.File]::Open($path,'CreateNew','Write','None');$stream.Dispose()}
    Write-Host 'Private HIP trial stop requested.'
}

function Assert-FastLlmHipTrialListenerOwner {
    param([Parameter(Mandatory=$true)][Diagnostics.Process]$Process,[long]$StartUtcTicks)
    if(-not ('Bitworks.FastLlm.WindowsGpuTelemetry' -as [type])){
        Add-Type -Path (Join-Path $PSScriptRoot 'WindowsGpuTelemetry.cs') -ErrorAction Stop
    }
    $owners=@([Bitworks.FastLlm.WindowsGpuTelemetry]::GetLoopbackListenerOwners(18081))
    if($owners.Count -ne 1 -or [int]$owners[0] -ne [int]$Process.Id -or
       $Process.HasExited -or [long]$Process.StartTime.ToUniversalTime().Ticks -ne $StartUtcTicks){
        throw 'HIP loopback listener owner differs from the exact supervised child.'
    }
}

function ConvertFrom-FastLlmHipTrialPlacementEvidence {
    param([string]$Text,[int]$CpuBufferLikeLines,[bool]$Overflow)
    $evidence=[ordered]@{status='missing';offloadRows=@();modelBuffers=@();cpuBufferLikeLines=$CpuBufferLikeLines;
        cpuModelBufferRows=0;physicalResidencyVerified=$false}
    if($Overflow){$evidence.status='overflow';return [pscustomobject]$evidence}
    if([string]::IsNullOrWhiteSpace($Text)){return [pscustomobject]$evidence}
    if($Text.Length -gt 8192 -or $CpuBufferLikeLines -lt 0 -or $CpuBufferLikeLines -gt 64){
        $evidence.status='invalid';return [pscustomobject]$evidence
    }
    $offload=New-Object System.Collections.Generic.List[object]
    $buffers=New-Object System.Collections.Generic.List[object]
    $lines=@($Text -split "`r?`n" | Where-Object {$_})
    if($lines.Count -gt 64){$evidence.status='invalid';return [pscustomobject]$evidence}
    foreach($line in $lines){
        if($line -cmatch '^load_tensors: offloaded ([0-9]{1,5})/([0-9]{1,5}) layers to GPU$'){
            $offload.Add([pscustomobject]@{reportedGpuLayers=[int]$Matches[1];reportedTotalLayers=[int]$Matches[2]})
        }elseif($line -cmatch '^load_tensors: (ROCm[0-9]+|CPU|CPU_Mapped) model buffer size = ([0-9]{1,32}(?:\.[0-9]{1,32})?) MiB$'){
            $size=[double]0
            if(-not [double]::TryParse($Matches[2],[Globalization.NumberStyles]::AllowDecimalPoint,
                [Globalization.CultureInfo]::InvariantCulture,[ref]$size) -or
                $size -le 0 -or [double]::IsNaN($size) -or [double]::IsInfinity($size)){
                $evidence.status='invalid';return [pscustomobject]$evidence
            }
            $buffers.Add([pscustomobject]@{device=$Matches[1];sizeMiB=$size})
        }else{$evidence.status='invalid';return [pscustomobject]$evidence}
    }
    $evidence.offloadRows=$offload.ToArray()
    $evidence.modelBuffers=$buffers.ToArray()
    $evidence.cpuModelBufferRows=@($buffers | Where-Object {$_.device -in @('CPU','CPU_Mapped')}).Count
    $evidence.status='captured'
    return [pscustomobject]$evidence
}

function Assert-FastLlmHipTrialPlacementGate {
    param([Parameter(Mandatory=$true)]$State,[Parameter(Mandatory=$true)]$Placement,
          [Parameter(Mandatory=$true)]$Evidence,[int]$CpuBufferLikeLines,
          [long]$ModelBytes,[bool]$AllowHostModelBuffer=$false)
    # Preserve the strict parser's numeric result before evaluating the experiment-specific 66/66 gate.
    $State.placement=$Placement
    if($Placement.reportedLayers -ne 66 -or $Placement.totalLayers -ne 66){
        $State.failureCode='placement-layer-count-mismatch'
        throw 'HIP placement did not report the expected 66/66 GPU layers.'
    }
    if($Evidence.status -cne 'captured' -or @($Evidence.offloadRows).Count -ne 1 -or
       $Evidence.offloadRows[0].reportedGpuLayers -ne 66 -or
       $Evidence.offloadRows[0].reportedTotalLayers -ne 66 -or
       $Evidence.cpuBufferLikeLines -ne $CpuBufferLikeLines){
        $State.failureCode='placement-evidence-inconsistent'
        throw 'HIP bounded placement evidence is incomplete or inconsistent.'
    }
    $gpu=@($Evidence.modelBuffers | Where-Object {$_.device -ceq 'ROCm0'})
    if($gpu.Count -ne 1 -or @($Evidence.modelBuffers | Where-Object {$_.device -match '^ROCm' -and $_.device -cne 'ROCm0'}).Count -ne 0 -or
       [double]$gpu[0].sizeMiB -le 0 -or [double]::IsNaN([double]$gpu[0].sizeMiB) -or
       [double]::IsInfinity([double]$gpu[0].sizeMiB)){
        $State.failureCode='gpu-model-buffer-evidence-invalid'
        throw 'HIP ROCm0 model-buffer evidence is missing or ambiguous.'
    }
    if(-not $AllowHostModelBuffer){
        if($CpuBufferLikeLines -ne 0 -or $Evidence.cpuModelBufferRows -ne 0 -or @($Evidence.modelBuffers).Count -ne 1){
            $State.failureCode='cpu-model-buffer-observed'
            throw 'HIP placement reported a CPU model-buffer line; explicit host-buffer opt-in was not supplied.'
        }
        $State.placementClassification='all-reported-layers-no-host-model-buffer'
        return
    }
    $host=@($Evidence.modelBuffers | Where-Object {$_.device -ceq 'CPU_Mapped'})
    $modelSizeMiB=[double]$ModelBytes / 1MB
    if($ModelBytes -le 0 -or $CpuBufferLikeLines -ne 1 -or $Evidence.cpuModelBufferRows -ne 1 -or
       @($Evidence.modelBuffers).Count -ne 2 -or $host.Count -ne 1 -or
       [double]$host[0].sizeMiB -le 0 -or [double]::IsNaN([double]$host[0].sizeMiB) -or
       [double]::IsInfinity([double]$host[0].sizeMiB) -or [double]$host[0].sizeMiB -gt $modelSizeMiB){
        $State.failureCode='host-model-buffer-evidence-invalid'
        throw 'HIP host-buffer opt-in requires exactly one bounded positive CPU_Mapped model buffer.'
    }
    $State.placementClassification='all-reported-layers-with-host-model-buffer'
}

function Start-FastLlmHipModelTrial {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$ArtifactRoot,
          [Parameter(Mandatory=$true)][string]$CandidateRoot,
          [Parameter(Mandatory=$true)][string]$RunRoot,
          [Parameter(Mandatory=$true)][string]$CatalogPath,
          [Parameter(Mandatory=$true)][string]$ModelId,
          [Parameter(Mandatory=$true)][ValidateRange(1,131072)][int]$ContextSize,
          [switch]$AllowHostModelBuffer,
          [ValidateRange(30,1800)][int]$LoadTimeoutSeconds=600)
    Assert-FastLlmHipLabIdentity
    Assert-FastLlmHipTrialRoots -ArtifactRoot $ArtifactRoot -CandidateRoot $CandidateRoot -RunRoot $RunRoot
    $entry=Get-FastLlmHipTrialCatalogModel -CatalogPath $CatalogPath -ModelId $ModelId
    $trialSourceSha256=Get-FastLlmHipTrialSourceSha256
    $model=$entry.model
    if($ContextSize -gt [int]$model.contextSize){throw 'HIP trial context exceeds the exact catalog model ceiling; no silent reduction.'}
    $manifest=Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'config/experiments/lemonade-hip-b1339-gfx110x.json') -Raw|ConvertFrom-Json
    if($manifest.id -cne 'lemonade-hip-b1339-windows-gfx110x' -or $manifest.executionEnabled -ne $false -or
       $manifest.archive.sha256 -cne 'cc9f6ce72a700507f0a1cb6b1e1a06481d7710a3bd433d0829e2f8762ee85a1d'){
        throw 'HIP trial requires the original disabled, exact b1339 candidate manifest.'
    }
    Assert-FastLlmHipNormalServiceStopped -ArtifactRoot $ArtifactRoot
    $artifactLock=Enter-FastLlmOperation $ArtifactRoot
    try{
        $runLock=Enter-FastLlmOperation $RunRoot
        try{
            $modelPath=Assert-FastLlmHipTrialModel -Model $model -ArtifactRoot $ArtifactRoot
            $enginePath=Assert-FastLlmHipExtraction -CandidateRoot $CandidateRoot -Manifest $manifest
            $help=Invoke-FastLlmHipTrialTextProbe -EnginePath $enginePath -CandidateRoot $CandidateRoot -Argument '--help' -RunRoot $RunRoot
            Assert-FastLlmHipTrialHelpFlags -HelpText $help
            $enginePath=Assert-FastLlmHipExtraction -CandidateRoot $CandidateRoot -Manifest $manifest
            $deviceText=Invoke-FastLlmHipTrialTextProbe -EnginePath $enginePath -CandidateRoot $CandidateRoot -Argument '--list-devices' -RunRoot $RunRoot
            $adapter=ConvertFrom-FastLlmHipTrialDeviceList -Text $deviceText -Device 'ROCm0'
            if([long]$adapter.freeVramMiB -lt [long]$model.requiredFreeVramMiB){
                throw 'Current reported free VRAM is below this catalog estimate; no CPU/offload fallback.'
            }
            # All checks after the metadata probes are repeated immediately before server launch.
            if((Get-FileHash -LiteralPath $CatalogPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.catalogSha256){throw 'Catalog changed during HIP trial preparation.'}
            $modelPath=Assert-FastLlmHipTrialModel -Model $model -ArtifactRoot $ArtifactRoot
            $enginePath=Assert-FastLlmHipExtraction -CandidateRoot $CandidateRoot -Manifest $manifest
            $freshText=Invoke-FastLlmHipTrialTextProbe -EnginePath $enginePath -CandidateRoot $CandidateRoot -Argument '--list-devices' -RunRoot $RunRoot
            $freshAdapter=ConvertFrom-FastLlmHipTrialDeviceList -Text $freshText -Device 'ROCm0'
            if([string]$freshAdapter.name -cne [string]$adapter.name -or
               [long]$freshAdapter.vramMiB -ne [long]$adapter.vramMiB -or
               [long]$freshAdapter.freeVramMiB -lt [long]$model.requiredFreeVramMiB){
                throw 'Selected ROCm0 identity or estimated free VRAM changed before launch.'
            }
            $enginePath=Assert-FastLlmHipExtraction -CandidateRoot $CandidateRoot -Manifest $manifest
            if((Get-FastLlmHipTrialSourceSha256) -cne $trialSourceSha256){throw 'HIP trial source changed during preparation.'}
            $arguments=@('--model',$modelPath,'--offline','--no-mmproj','--spec-type','none',
                '--alias',[string]$model.id,'--host','127.0.0.1','--port','18081',
                '--cors-origins','localhost','--no-cors-credentials','--ctx-size',[string]$ContextSize,
                '--parallel','1','--n-gpu-layers','all','--fit','off','--device','ROCm0',
                '--split-mode','none','--flash-attn','auto','--cache-type-k',[string]$model.cacheTypeK,
                '--cache-type-v',[string]$model.cacheTypeV,'--jinja','--metrics','--log-verbosity','4',
                '--no-agent','--no-ui')
            $plan=[pscustomobject]@{model=$model;modelPath=$modelPath;enginePath=$enginePath;
                candidateRoot=$CandidateRoot;endpoint='http://127.0.0.1:18081/v1';contextSize=$ContextSize;
                serverArguments=$arguments;catalogSha256=$entry.catalogSha256;adapter=$freshAdapter;
                trialSourceSha256=$trialSourceSha256;allowHostModelBuffer=[bool]$AllowHostModelBuffer;
                engineSha256=(Get-FileHash -LiteralPath $enginePath -Algorithm SHA256).Hash.ToLowerInvariant()}
            return Invoke-FastLlmHipTrialSupervisor -Plan $plan -RunRoot $RunRoot -LoadTimeoutSeconds $LoadTimeoutSeconds
        }finally{$runLock.Dispose()}
    }finally{$artifactLock.Dispose()}
}

function Invoke-FastLlmHipTrialSupervisor {
    param($Plan,[string]$RunRoot,[int]$LoadTimeoutSeconds)
    Initialize-FastLlmProcessHost
    $state=[ordered]@{schemaVersion=1;kind='fastllm-hip-b1339-private-trial';runId=[Guid]::NewGuid().ToString('N');
        phase='hip-lab-loading';updatedAt=(Get-Date).ToUniversalTime().ToString('o');endpoint=$Plan.endpoint;
        modelId=$Plan.model.id;modelSha256=$Plan.model.sha256;engineVersion='lemonade-b1339-gfx110X';
        engineSha256=$Plan.engineSha256;catalogSha256=$Plan.catalogSha256;trialSourceSha256=$Plan.trialSourceSha256;
        recipe=[ordered]@{backend='ROCm';device='ROCm0';contextSize=$Plan.contextSize;slots=1;
            gpuLayers='all';fitMode='off';splitMode='none';cacheTypeK=$Plan.model.cacheTypeK;
            cacheTypeV=$Plan.model.cacheTypeV;speculation='none';flashAttention='auto';
            allowHostModelBuffer=[bool]$Plan.allowHostModelBuffer;
            requestedArguments=@($Plan.serverArguments | ForEach-Object {if($_ -ceq $Plan.modelPath){'<verified-model>'}else{$_}});
            configurationIsolation='empty-per-run-config-roots-and-targeted-environment-sanitization'};
        selectedDevice=[ordered]@{device='ROCm0';name=$Plan.adapter.name;reportedFreeMiB=$Plan.adapter.freeVramMiB};
        placement=$null;placementEvidence=$null;placementClassification=$null;
        allowHostModelBuffer=[bool]$Plan.allowHostModelBuffer;allWeightsOnGpuVerified=$false;
        allOperationsOnGpuVerified=$false;cpuInputEvidence='not-attested';
        startupDiagnostics=$null;canary=$null;processIdentity=$null;
        experimental=$true;performanceQualified=$false;
        physicalResidencyVerified=$false;dynamicClosureVerified=$false;failureCode=$null;
        failureDiagnostics=@();failureOutputSha256=$null}
    $stateRoot=Get-FastLlmStateRoot -InstallRoot $RunRoot -Create
    $stopPath=Join-FastLlmContainedPath -Root $stateRoot -Child ('stop-'+$state.runId)
    $sandbox=New-FastLlmRuntimeSandbox -InstallRoot $RunRoot
    $child=New-Object Bitworks.FastLlm.ProcessHost
    $baseUrl='http://127.0.0.1:18081'
    try{
        $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,18081)
        try{$listener.Server.ExclusiveAddressUse=$true;$listener.Start()}finally{$listener.Stop()}
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=$Plan.enginePath
        $info.Arguments=Join-FastLlmProcessArguments -Arguments $Plan.serverArguments
        $info.WorkingDirectory=$Plan.candidateRoot
        foreach($name in @($info.EnvironmentVariables.Keys)){
            if((Test-FastLlmEnvironmentNameRequiresClearing -Name $name) -or
               $name -match '^(?i:ROCR_|CUDA_|VULKAN_|AMD_)' -or $name -eq 'GPU_DEVICE_ORDINAL'){
                $info.EnvironmentVariables.Remove([string]$name)
            }
        }
        $info.EnvironmentVariables['APPDATA']=$sandbox.appData
        $info.EnvironmentVariables['PROGRAMDATA']=$sandbox.programData
        $info.EnvironmentVariables['PATH']="$($Plan.candidateRoot);$([Environment]::SystemDirectory);$env:SystemRoot"
        if((Get-FastLlmHipTrialSourceSha256) -cne $Plan.trialSourceSha256){throw 'HIP trial source changed before process launch.'}
        Write-FastLlmState -InstallRoot $RunRoot -State $state
        $child.Start($info)
        if((Get-FastLlmHipTrialSourceSha256) -cne $Plan.trialSourceSha256){throw 'HIP trial source changed during process launch.'}
        $state.processIdentity=[ordered]@{pid=[int]$child.Process.Id;startUtcTicks=[long]$child.Process.StartTime.ToUniversalTime().Ticks}
        $state.updatedAt=(Get-Date).ToUniversalTime().ToString('o');Write-FastLlmState -InstallRoot $RunRoot -State $state
        $timer=[Diagnostics.Stopwatch]::StartNew();$healthy=$false
        while($timer.Elapsed.TotalSeconds -lt $LoadTimeoutSeconds){
            if(Test-Path -LiteralPath $stopPath){$state.phase='hip-lab-stopped';return 0}
            if($child.Process.HasExited){throw 'Private HIP server exited before readiness.'}
            try{$health=Invoke-FastLlmHttp -BaseUrl $baseUrl -Path '/health' -TimeoutMs 1000
                $healthy=$health.Status -eq 200 -and (ConvertFrom-Json $health.Body).status -eq 'ok'}catch{$healthy=$false}
            if($healthy){
                Assert-FastLlmHipTrialListenerOwner -Process $child.Process -StartUtcTicks ([long]$state.processIdentity.startUtcTicks)
                break
            }
            Start-Sleep -Milliseconds 200
        }
        if(-not $healthy){throw 'Private HIP model-load readiness deadline exceeded.'}
        $startupText=$child.FreezeStartupDiagnostics()
        $state.phase='hip-lab-checking';$state.updatedAt=(Get-Date).ToUniversalTime().ToString('o')
        $placementText=$child.PlacementSnapshot()
        $state.startupDiagnostics=ConvertFrom-FastLlmStartupDiagnostics -Text $startupText -Overflow $child.StartupDiagnosticsOverflow -RequestedFlashAttention 'auto'
        $state.placementEvidence=ConvertFrom-FastLlmHipTrialPlacementEvidence -Text $placementText -CpuBufferLikeLines $child.CpuBufferLikeLines -Overflow $child.PlacementOverflow
        Write-FastLlmState -InstallRoot $RunRoot -State $state
        if($child.PlacementOverflow){throw 'HIP placement log capture overflowed.'}
        $placement=ConvertFrom-FastLlmPlacementLog -Text $placementText -Devices @('ROCm0')
        Assert-FastLlmHipTrialPlacementGate -State $state -Placement $placement -Evidence $state.placementEvidence -CpuBufferLikeLines $child.CpuBufferLikeLines -ModelBytes ([long]$Plan.model.sizeBytes) -AllowHostModelBuffer ([bool]$Plan.allowHostModelBuffer)
        Write-FastLlmState -InstallRoot $RunRoot -State $state
        Assert-FastLlmHipTrialListenerOwner -Process $child.Process -StartUtcTicks ([long]$state.processIdentity.startUtcTicks)
        $state.canary=Test-FastLlmApiCanary -BaseUrl $baseUrl -ModelId $Plan.model.id -ContextSize $Plan.contextSize
        Assert-FastLlmHipTrialListenerOwner -Process $child.Process -StartUtcTicks ([long]$state.processIdentity.startUtcTicks)
        if($child.Process.HasExited){throw 'Private HIP server exited during canary.'}
        $child.DiscardOutput()
        $state.phase='hip-lab-ready';$state.updatedAt=(Get-Date).ToUniversalTime().ToString('o')
        Assert-FastLlmHipTrialListenerOwner -Process $child.Process -StartUtcTicks ([long]$state.processIdentity.startUtcTicks)
        Write-FastLlmState -InstallRoot $RunRoot -State $state
        Write-Host "Private HIP lab ready on $($Plan.endpoint); not qualified for fit, numerical quality, residency or performance."
        while(-not $child.Process.WaitForExit(250)){
            if(Test-Path -LiteralPath $stopPath){$state.phase='hip-lab-stopped';return 0}
            Assert-FastLlmHipTrialListenerOwner -Process $child.Process -StartUtcTicks ([long]$state.processIdentity.startUtcTicks)
        }
        if($child.Process.ExitCode -ne 0){throw 'Private HIP server exited unexpectedly.'}
        $state.phase='hip-lab-stopped';return 0
    }catch{
        $state.phase='hip-lab-failed'
        if(-not $state.failureCode){$state.failureCode='startup-or-runtime-check-failed'}
        $output=$child.Snapshot()
        $codes=New-Object System.Collections.Generic.List[string]
        if($output -match '(?i)\.dll|LoadLibrary'){ $codes.Add('dll-or-loader-message-present') }
        if($output -match '(?i)\bHIP\b|\bHSA\b|\bROCm\b'){ $codes.Add('hip-runtime-message-present') }
        if($output -match '(?i)error|fail'){ $codes.Add('error-or-failure-message-present') }
        $state.failureDiagnostics=$codes.ToArray()
        $state.failureOutputSha256=Get-FastLlmHipTextHash -Text $output
        throw
    }
    finally{
        try{$child.Dispose()}finally{
            try{$state.updatedAt=(Get-Date).ToUniversalTime().ToString('o');Write-FastLlmState -InstallRoot $RunRoot -State $state}
            finally{try{Remove-FastLlmRuntimeSandbox $sandbox}finally{if(Test-Path -LiteralPath $stopPath){Remove-Item -LiteralPath $stopPath -Force}}}
        }
    }
}
