#requires -Version 5.1
# Private, supervised b10698 Vulkan fit A/B diagnostic. Never a normal serving or qualification state.

function Get-FastLlmVulkanFitTrialSourceSha256 {
    $path=Join-Path $PSScriptRoot 'FastLlm.VulkanFitTrial.ps1'
    $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
       $item.Length -le 0 -or $item.Length -gt 262144){throw 'Vulkan fit trial source is unavailable or unsafe.'}
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-FastLlmVulkanFitRoots {
    param([string]$ArtifactRoot,[string]$RunRoot)
    Assert-FastLlmOffloadRoots -ArtifactRoot $ArtifactRoot -LabRunRoot $RunRoot
    $profile=[IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')
    $run=[IO.Path]::GetFullPath($RunRoot).TrimEnd('\')
    if(-not $run.StartsWith($profile+'\',[StringComparison]::OrdinalIgnoreCase)){
        throw 'Private Vulkan fit run root must be inside the current standard-user profile.'
    }
}

function Get-FastLlmVulkanFitModel {
    param([string]$CatalogPath)
    $entry=Get-FastLlmOffloadModel -CatalogPath $CatalogPath -ModelId 'qwen3.8-27b-ud-q4-k-m'
    $model=$entry.model
    if([string]$model.sha256 -cne '322e194ff79741c7baa497c240f677f54b201b0efab44ca8e50f122b39123482' -or
       [long]$model.sizeBytes -ne 16464440224 -or [int]$model.contextSize -ne 32768 -or
       [int]$model.fitTargetMiB -ne 768 -or [string]$model.cacheTypeK -cne 'f16' -or
       [string]$model.cacheTypeV -cne 'f16' -or [string]$model.servingMode -notmatch '^text-only;'){
        throw 'Vulkan fit trial requires the exact catalog Qwen3.8-27B UD-Q4_K_M context-32768 artifact.'
    }
    return $entry
}

function Assert-FastLlmVulkanFitCachedModel {
    param($Model,[string]$ArtifactRoot)
    $modelRoot=Join-FastLlmContainedPath -Root $ArtifactRoot -Child 'models'
    Assert-FastLlmOffloadRootPath $modelRoot
    $path=Join-FastLlmContainedPath -Root $modelRoot -Child ([string]$Model.file)
    $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
       [long]$item.Length -ne [long]$Model.sizeBytes -or
       -not (Test-FastLlmFileHash -Path $path -Sha256 ([string]$Model.sha256)) -or
       -not (Test-FastLlmOffloadExactConsent -Model $Model -ArtifactRoot $ArtifactRoot)){
        throw 'Exact Qwen model hash or consent is absent; this trial never downloads or accepts licenses.'
    }
    return $path
}

function Get-FastLlmVulkanFitLiveAdapter {
    param([string]$CatalogPath,[string]$ArtifactRoot,[string]$EnginePath,[long]$RequiredFreeMiB)
    $hardware=Get-FastLlmHardware -CatalogPath $CatalogPath -InstallRoot $ArtifactRoot
    $adapters=@($hardware.adapters)
    if($hardware.backend -cne 'Vulkan' -or $hardware.enginePath -cne $EnginePath -or
       $adapters.Count -ne 1 -or $adapters[0].device -cne 'Vulkan0' -or
       -not $adapters[0].isAmd -or $adapters[0].isIntegrated -or
       [long]$adapters[0].freeVramMiB -lt $RequiredFreeMiB){
        throw 'Private Vulkan fit trial requires exactly one current discrete AMD Vulkan0 meeting the catalog free-VRAM estimate.'
    }
    return $adapters[0]
}

function New-FastLlmVulkanFitArguments {
    param([string]$ModelPath,[string]$ModelId,[string]$FitMode)
    if($FitMode -cnotin @('on','off')){throw 'Fit mode must be exactly on or off.'}
    return @('--model',$ModelPath,'--offline','--no-mmproj','--spec-type','none',
        '--alias',$ModelId,'--host','127.0.0.1','--port','18083',
        '--cors-origins','localhost','--no-cors-credentials','--ctx-size','32768',
        '--parallel','1','--n-gpu-layers','all','--fit',$FitMode,'--fit-target','768',
        '--device','Vulkan0','--split-mode','none','--flash-attn','auto',
        '--cache-type-k','f16','--cache-type-v','f16','--jinja','--metrics',
        '--log-verbosity','4','--no-agent','--no-ui')
}

function ConvertFrom-FastLlmVulkanFitBufferEvidence {
    param([string]$Text,[int]$CpuBufferLikeLines,[bool]$Overflow,[long]$ModelBytes,
          [bool]$AllowHostModelBuffer)
    if($Overflow -or $Text.Length -gt 8192 -or $CpuBufferLikeLines -lt 0 -or $CpuBufferLikeLines -gt 64){
        throw 'Bounded Vulkan model-buffer capture overflowed or is malformed.'
    }
    $rows=@($Text -split "`r?`n" | Where-Object {$_})
    if($rows.Count -gt 64){throw 'Vulkan model-buffer capture has too many lines.'}
    $gpu=@();$hostBuffers=@();$offload=@()
    foreach($line in $rows){
        if($line -cmatch '^load_tensors: offloaded ([0-9]{1,5})/([0-9]{1,5}) layers to GPU$'){
            $offload+= [pscustomobject]@{loaded=[int]$Matches[1];total=[int]$Matches[2]}
        }elseif($line -cmatch '^load_tensors: (Vulkan0|CPU_Mapped|CPU) model buffer size = ([0-9]{1,32}(?:\.[0-9]{1,32})?) MiB$'){
            $size=[double]0
            if(-not [double]::TryParse($Matches[2],[Globalization.NumberStyles]::AllowDecimalPoint,
                [Globalization.CultureInfo]::InvariantCulture,[ref]$size) -or
                $size -le 0 -or [double]::IsNaN($size) -or [double]::IsInfinity($size)){
                throw 'Vulkan model-buffer size is not positive finite numeric evidence.'
            }
            $entry=[pscustomobject]@{device=$Matches[1];sizeMiB=$size}
            if($Matches[1] -ceq 'Vulkan0'){$gpu+= $entry}else{$hostBuffers+= $entry}
        }else{throw 'Vulkan model-buffer capture contains an unrecognized row.'}
    }
    if($offload.Count -ne 1 -or $offload[0].loaded -ne 66 -or $offload[0].total -ne 66 -or
       $gpu.Count -ne 1 -or $CpuBufferLikeLines -ne $hostBuffers.Count){
        throw 'Vulkan fit placement did not report exactly 66/66 layers and one selected GPU buffer.'
    }
    if($hostBuffers.Count){
        if(-not $AllowHostModelBuffer -or $hostBuffers.Count -ne 1 -or $hostBuffers[0].device -cne 'CPU_Mapped' -or
           $hostBuffers[0].sizeMiB -gt 1024.0 -or $hostBuffers[0].sizeMiB -gt ([double]$ModelBytes / 1MB)){
            throw 'CPU_Mapped model buffer requires explicit opt-in and must not exceed the 1024 MiB trial cap.'
        }
    }
    $hostBuffer=if($hostBuffers.Count){$hostBuffers[0]}else{$null}
    $classification=if($hostBuffers.Count){'all-reported-layers-with-host-model-buffer'}else{'all-reported-layers-no-host-model-buffer'}
    return [pscustomobject]@{status='captured';reportedGpuLayers=66;reportedTotalLayers=66;
        gpuModelBuffer=$gpu[0];hostModelBuffer=$hostBuffer;
        classification=$classification;
        physicalResidencyVerified=$false;allWeightsOnGpuVerified=$false;allOperationsOnGpuVerified=$false}
}

function Assert-FastLlmVulkanFitPlacementCounters {
    param([string]$Diagnostics,$Evidence)
    if($Diagnostics -cnotmatch '^tensorLines=([0-9]{1,5}), offloadLike=([0-9]{1,5}), bufferLike=([0-9]{1,5}), captured=([0-9]{1,5}), dropped=([0-9]{1,5}), generalOutputTruncated=(True|False)$'){
        throw 'Private Vulkan placement counters are malformed.'
    }
    $tensor=[int]$Matches[1];$offload=[int]$Matches[2];$buffers=[int]$Matches[3]
    $captured=[int]$Matches[4];$dropped=[int]$Matches[5]
    $expectedBuffers=if($null -eq $Evidence.hostModelBuffer){1}else{2}
    if($tensor -lt ($expectedBuffers+1) -or $tensor -gt 1024 -or $offload -ne 1 -or
       $buffers -ne $expectedBuffers -or $captured -ne ($expectedBuffers+1) -or $dropped -ne 0){
        throw 'Unrecognized or ambiguous model placement lines were observed outside bounded capture.'
    }
    return [pscustomobject]@{offloadLike=$offload;bufferLike=$buffers;captured=$captured;dropped=$dropped}
}

function Get-FastLlmVulkanFitStatus {
    param([Parameter(Mandatory=$true)][string]$RunRoot)
    Assert-FastLlmOffloadLabHost
    Assert-FastLlmOffloadRootPath $RunRoot
    $state=Get-FastLlmStatus -InstallRoot $RunRoot
    if([int]$state.schemaVersion -ne 1 -or [string]$state.kind -cne 'fastllm-vulkan-fit-b10698-private-trial'){
        throw 'RunRoot does not contain a Vulkan fit private-trial state.'
    }
    if(-not $state.active -and $state.phase -in @('vulkan-fit-loading','vulkan-fit-checking','vulkan-fit-ready')){
        $state.phase='vulkan-fit-interrupted'
    }
    return $state
}

function Request-FastLlmVulkanFitStop {
    param([Parameter(Mandatory=$true)][string]$RunRoot)
    $state=Get-FastLlmVulkanFitStatus -RunRoot $RunRoot
    if(-not $state.active -or $state.phase -notin @('vulkan-fit-loading','vulkan-fit-checking','vulkan-fit-ready') -or
       $state.runId -cnotmatch '^[0-9a-f]{32}$'){
        throw 'No active private Vulkan fit trial belongs to this run root.'
    }
    $root=Get-FastLlmStateRoot -InstallRoot $RunRoot
    $path=Join-FastLlmContainedPath -Root $root -Child ('stop-'+$state.runId)
    if(Test-Path -LiteralPath $path){
        if((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unsafe Vulkan fit stop path.'}
    }else{$stream=[IO.File]::Open($path,'CreateNew','Write','None');$stream.Dispose()}
}

function Assert-FastLlmVulkanFitListenerOwner {
    param([Diagnostics.Process]$Process,[long]$StartUtcTicks)
    if(-not ('Bitworks.FastLlm.WindowsGpuTelemetry' -as [type])){
        Add-Type -Path (Join-Path $PSScriptRoot 'WindowsGpuTelemetry.cs') -ErrorAction Stop
    }
    $owners=@([Bitworks.FastLlm.WindowsGpuTelemetry]::GetLoopbackListenerOwners(18083))
    if($owners.Count -ne 1 -or [int]$owners[0] -ne [int]$Process.Id -or
       $Process.HasExited -or [long]$Process.StartTime.ToUniversalTime().Ticks -ne $StartUtcTicks){
        throw 'Vulkan fit loopback listener owner differs from the exact supervised child.'
    }
}

function Start-FastLlmVulkanFitTrial {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$ArtifactRoot,
          [Parameter(Mandatory=$true)][string]$RunRoot,
          [Parameter(Mandatory=$true)][string]$CatalogPath,
          [Parameter(Mandatory=$true)][ValidateSet('on','off')][string]$FitMode,
          [switch]$AllowHostModelBuffer,
          [ValidateRange(30,1800)][int]$LoadTimeoutSeconds=600)
    Assert-FastLlmOffloadLabHost
    Assert-FastLlmVulkanFitRoots -ArtifactRoot $ArtifactRoot -RunRoot $RunRoot
    $entry=Get-FastLlmVulkanFitModel -CatalogPath $CatalogPath
    $sourceSha=Get-FastLlmVulkanFitTrialSourceSha256
    $normal=Get-FastLlmStatus -InstallRoot $ArtifactRoot
    if($normal.active){throw 'Stop normal inference before a private Vulkan fit trial.'}
    $artifactLock=Enter-FastLlmOperation $ArtifactRoot
    try{
        $runLock=Enter-FastLlmOperation $RunRoot
        try{
            $model=$entry.model;$catalog=$entry.catalog;$asset=$catalog.engine.assets.vulkan
            if(-not (Test-FastLlmEngineInstallation -InstallRoot $ArtifactRoot -EngineVersion 'b10698' -BackendKey 'vulkan' -Asset $asset)){
                throw 'Exact pinned b10698 Vulkan engine is not installed and verified.'
            }
            $enginePath=Get-FastLlmEngineExecutable -InstallRoot $ArtifactRoot -EngineVersion 'b10698' -BackendKey 'vulkan' -EntryPoint ([string]$asset.entryPoint)
            $initial=Get-FastLlmVulkanFitLiveAdapter -CatalogPath $CatalogPath -ArtifactRoot $ArtifactRoot -EnginePath $enginePath -RequiredFreeMiB ([long]$model.requiredFreeVramMiB)
            $modelPath=Assert-FastLlmVulkanFitCachedModel -Model $model -ArtifactRoot $ArtifactRoot
            $fresh=Get-FastLlmVulkanFitLiveAdapter -CatalogPath $CatalogPath -ArtifactRoot $ArtifactRoot -EnginePath $enginePath -RequiredFreeMiB ([long]$model.requiredFreeVramMiB)
            if([string]$fresh.name -cne [string]$initial.name -or [long]$fresh.vramMiB -ne [long]$initial.vramMiB){
                throw 'Vulkan0 identity changed during private trial preparation.'
            }
            if((Get-FileHash -LiteralPath $CatalogPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.catalogSha256 -or
               -not (Test-FastLlmEngineInstallation -InstallRoot $ArtifactRoot -EngineVersion 'b10698' -BackendKey 'vulkan' -Asset $asset)){
                throw 'Pinned catalog or engine changed before private process launch.'
            }
            $modelPath=Assert-FastLlmVulkanFitCachedModel -Model $model -ArtifactRoot $ArtifactRoot
            if((Get-FastLlmVulkanFitTrialSourceSha256) -cne $sourceSha){throw 'Vulkan fit trial source changed during preparation.'}
            $args=New-FastLlmVulkanFitArguments -ModelPath $modelPath -ModelId ([string]$model.id) -FitMode $FitMode
            $plan=[pscustomobject]@{model=$model;modelPath=$modelPath;enginePath=$enginePath;
                serverArguments=$args;fitMode=$FitMode;adapter=$fresh;catalogSha256=$entry.catalogSha256;
                sourceSha256=$sourceSha;allowHostModelBuffer=[bool]$AllowHostModelBuffer;
                engineSha256=(Get-FileHash -LiteralPath $enginePath -Algorithm SHA256).Hash.ToLowerInvariant()}
            return Invoke-FastLlmVulkanFitSupervisor -Plan $plan -RunRoot $RunRoot -LoadTimeoutSeconds $LoadTimeoutSeconds
        }finally{$runLock.Dispose()}
    }finally{$artifactLock.Dispose()}
}

function Invoke-FastLlmVulkanFitSupervisor {
    param($Plan,[string]$RunRoot,[int]$LoadTimeoutSeconds)
    Initialize-FastLlmProcessHost
    $state=[ordered]@{schemaVersion=1;kind='fastllm-vulkan-fit-b10698-private-trial';runId=[Guid]::NewGuid().ToString('N');
        phase='vulkan-fit-loading';updatedAt=(Get-Date).ToUniversalTime().ToString('o');endpoint='http://127.0.0.1:18083/v1';
        modelId=$Plan.model.id;modelSha256=$Plan.model.sha256;engineVersion='b10698';engineSha256=$Plan.engineSha256;
        catalogSha256=$Plan.catalogSha256;trialSourceSha256=$Plan.sourceSha256;
        recipe=[ordered]@{backend='Vulkan';device='Vulkan0';contextSize=32768;slots=1;gpuLayers='all';
            fitMode=$Plan.fitMode;fitTargetMiB=768;splitMode='none';cacheTypeK='f16';cacheTypeV='f16';
            flashAttention='auto';speculation='none';allowHostModelBuffer=[bool]$Plan.allowHostModelBuffer;
            requestedArguments=@($Plan.serverArguments | ForEach-Object {if($_ -ceq $Plan.modelPath){'<verified-model>'}else{$_}});
            configurationIsolation='empty-per-run-config-roots-and-targeted-environment-sanitization'};
        selectedDevice=[ordered]@{device='Vulkan0';name=$Plan.adapter.name;reportedFreeMiB=$Plan.adapter.freeVramMiB};
        placement=$null;placementEvidence=$null;placementCounters=$null;placementClassification=$null;allowHostModelBuffer=[bool]$Plan.allowHostModelBuffer;
        allWeightsOnGpuVerified=$false;allOperationsOnGpuVerified=$false;cpuInputEvidence='not-attested';physicalResidencyVerified=$false;
        dynamicClosureVerified=$false;semanticCorrectnessQualified=$false;performanceQualified=$false;
        experimental=$true;processIdentity=$null;canary=$null;failureCode=$null}
    $stateRoot=Get-FastLlmStateRoot -InstallRoot $RunRoot -Create
    $stopPath=Join-FastLlmContainedPath -Root $stateRoot -Child ('stop-'+$state.runId)
    $sandbox=New-FastLlmRuntimeSandbox -InstallRoot $RunRoot
    $child=New-Object Bitworks.FastLlm.ProcessHost
    $baseUrl='http://127.0.0.1:18083'
    try{
        $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,18083)
        try{$listener.Server.ExclusiveAddressUse=$true;$listener.Start()}finally{$listener.Stop()}
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=$Plan.enginePath
        $info.Arguments=Join-FastLlmProcessArguments -Arguments $Plan.serverArguments
        $info.WorkingDirectory=Split-Path -Parent $Plan.enginePath
        foreach($name in @($info.EnvironmentVariables.Keys)){
            if(Test-FastLlmEnvironmentNameRequiresClearing -Name $name){$info.EnvironmentVariables.Remove([string]$name)}
        }
        $info.EnvironmentVariables['APPDATA']=$sandbox.appData
        $info.EnvironmentVariables['PROGRAMDATA']=$sandbox.programData
        $info.EnvironmentVariables['PATH']="$($info.WorkingDirectory);$([Environment]::SystemDirectory);$env:SystemRoot"
        if((Get-FastLlmVulkanFitTrialSourceSha256) -cne $Plan.sourceSha256){throw 'Vulkan fit source changed before spawn.'}
        Write-FastLlmState -InstallRoot $RunRoot -State $state
        $child.Start($info)
        if((Get-FastLlmVulkanFitTrialSourceSha256) -cne $Plan.sourceSha256){throw 'Vulkan fit source changed during process launch.'}
        $state.processIdentity=[ordered]@{pid=[int]$child.Process.Id;startUtcTicks=[long]$child.Process.StartTime.ToUniversalTime().Ticks}
        $state.updatedAt=(Get-Date).ToUniversalTime().ToString('o');Write-FastLlmState -InstallRoot $RunRoot -State $state
        $timer=[Diagnostics.Stopwatch]::StartNew();$healthy=$false
        while($timer.Elapsed.TotalSeconds -lt $LoadTimeoutSeconds){
            if(Test-Path -LiteralPath $stopPath){$state.phase='vulkan-fit-stopped';return 0}
            if($child.Process.HasExited){throw 'Private Vulkan fit server exited before readiness.'}
            try{$health=Invoke-FastLlmHttp -BaseUrl $baseUrl -Path '/health' -TimeoutMs 1000
                $healthy=$health.Status -eq 200 -and (ConvertFrom-Json $health.Body).status -eq 'ok'}catch{$healthy=$false}
            if($healthy){Assert-FastLlmVulkanFitListenerOwner -Process $child.Process -StartUtcTicks ([long]$state.processIdentity.startUtcTicks);break}
            Start-Sleep -Milliseconds 200
        }
        if(-not $healthy){throw 'Private Vulkan fit model-load deadline exceeded.'}
        $startupText=$child.FreezeStartupDiagnostics()
        $state.phase='vulkan-fit-checking';$state.updatedAt=(Get-Date).ToUniversalTime().ToString('o')
        $state.startupDiagnostics=ConvertFrom-FastLlmStartupDiagnostics -Text $startupText -Overflow $child.StartupDiagnosticsOverflow -RequestedFlashAttention 'auto'
        $placementText=$child.PlacementSnapshot()
        if($child.PlacementOverflow){throw 'Vulkan fit bounded placement capture overflowed.'}
        $state.placement=ConvertFrom-FastLlmPlacementLog -Text $placementText -Devices @('Vulkan0')
        $state.placementEvidence=ConvertFrom-FastLlmVulkanFitBufferEvidence -Text $placementText -CpuBufferLikeLines $child.CpuBufferLikeLines -Overflow $child.PlacementOverflow -ModelBytes ([long]$Plan.model.sizeBytes) -AllowHostModelBuffer ([bool]$Plan.allowHostModelBuffer)
        $state.placementCounters=Assert-FastLlmVulkanFitPlacementCounters -Diagnostics ($child.PlacementDiagnostics()) -Evidence $state.placementEvidence
        $state.placementClassification=$state.placementEvidence.classification
        Write-FastLlmState -InstallRoot $RunRoot -State $state
        Assert-FastLlmVulkanFitListenerOwner -Process $child.Process -StartUtcTicks ([long]$state.processIdentity.startUtcTicks)
        $state.canary=Test-FastLlmApiCanary -BaseUrl $baseUrl -ModelId $Plan.model.id -ContextSize 32768
        Assert-FastLlmVulkanFitListenerOwner -Process $child.Process -StartUtcTicks ([long]$state.processIdentity.startUtcTicks)
        if($child.Process.HasExited){throw 'Vulkan fit server exited during API canaries.'}
        $child.DiscardOutput()
        $state.phase='vulkan-fit-ready';$state.updatedAt=(Get-Date).ToUniversalTime().ToString('o');Write-FastLlmState -InstallRoot $RunRoot -State $state
        Write-Host "Private Vulkan fit $($Plan.fitMode) lab ready on $($state.endpoint); not fit/residency/quality/performance qualified."
        while(-not $child.Process.WaitForExit(250)){
            if(Test-Path -LiteralPath $stopPath){$state.phase='vulkan-fit-stopped';return 0}
            Assert-FastLlmVulkanFitListenerOwner -Process $child.Process -StartUtcTicks ([long]$state.processIdentity.startUtcTicks)
        }
        if($child.Process.ExitCode -ne 0){throw 'Private Vulkan fit server exited unexpectedly.'}
        $state.phase='vulkan-fit-stopped';return 0
    }catch{$state.phase='vulkan-fit-failed';$state.failureCode='private-startup-or-runtime-check-failed';throw}
    finally{
        try{$child.Dispose()}finally{
            try{$state.updatedAt=(Get-Date).ToUniversalTime().ToString('o');Write-FastLlmState -InstallRoot $RunRoot -State $state}
            finally{try{Remove-FastLlmRuntimeSandbox $sandbox}finally{if(Test-Path -LiteralPath $stopPath){Remove-Item -LiteralPath $stopPath -Force}}}
        }
    }
}
