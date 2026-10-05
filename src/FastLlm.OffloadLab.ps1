# Experimental, single-device CPU-offload lane. Loaded inside FastLlm.psm1 only.
# It never calls the normal planner, normal supervisor, or benchmark producer.
function Assert-FastLlmOffloadRootPath {
    param([string]$Root)
    $part=New-Object IO.DirectoryInfo([IO.Path]::GetFullPath($Root))
    while($null -ne $part){
        if($part.Exists -and ($part.Attributes -band [IO.FileAttributes]::ReparsePoint)){
            throw 'Offload lab roots cannot include junctions or symbolic links.'
        }
        $part=$part.Parent
    }
}

function Assert-FastLlmOffloadRoots {
    param([string]$ArtifactRoot,[string]$LabRunRoot)
    $a=[IO.Path]::GetFullPath($ArtifactRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $b=[IO.Path]::GetFullPath($LabRunRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    Assert-FastLlmOffloadRootPath $a
    Assert-FastLlmOffloadRootPath $b
    $comparison=if($env:OS -eq 'Windows_NT'){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    $separator=[string][IO.Path]::DirectorySeparatorChar
    if($a.Equals($b,$comparison) -or $a.StartsWith($b+$separator,$comparison) -or $b.StartsWith($a+$separator,$comparison)){
        throw 'ArtifactRoot and LabRunRoot must be separate, non-overlapping directories.'
    }
}

function Assert-FastLlmOffloadLabHost {
    if($env:OS -ne 'Windows_NT'){throw 'Live offload experiments require Windows.'}
    if(-not [Environment]::Is64BitProcess){throw 'Live offload experiments require 64-bit PowerShell.'}
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    if((New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
        throw 'Run the offload lab as a standard user, not an administrator.'
    }
}

function Get-FastLlmOffloadModel {
    param([string]$CatalogPath,[string]$ModelId)
    Assert-FastLlmLeafName -Value $ModelId -Label 'Model ID'
    $catalogSha=(Get-FileHash -LiteralPath $CatalogPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $catalog=Get-FastLlmCatalog -CatalogPath $CatalogPath
    if((Get-FileHash -LiteralPath $CatalogPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $catalogSha){throw 'Catalog changed while resolving the exact lab model.'}
    if([string]$catalog.engine.version -ne 'b10698' -or -not [bool]$catalog.engine.assets.vulkan.enabled){
        throw 'The offload lab requires the pinned b10698 Vulkan engine.'
    }
    $matches=@($catalog.models | Where-Object { [string]$_.id -ceq $ModelId })
    if($matches.Count -ne 1){throw 'Select exactly one model ID from the validated catalog.'}
    return [pscustomobject]@{catalog=$catalog;model=$matches[0];catalogSha256=$catalogSha}
}

function Test-FastLlmOffloadExactConsent {
    param($Model,[string]$ArtifactRoot)
    $path=Get-FastLlmModelConsentPath -Model $Model -InstallRoot $ArtifactRoot
    try{
        $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if($item.Length -gt 16384 -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){return $false}
        if(-not (Test-FastLlmModelConsentReceipt -Model $Model -InstallRoot $ArtifactRoot)){return $false}
        $receipt=Read-FastLlmJson -Path $path
        return [string]$receipt.artifactRepository -ceq [string]$Model.repository -and
            [string]$receipt.artifactLicense -ceq [string]$Model.artifactLicense -and
            [string]$receipt.upstreamModel -ceq [string]$Model.upstreamModel -and
            [string]$receipt.upstreamLicense -ceq [string]$Model.upstreamLicense
    }catch{return $false}
}

function Get-FastLlmOffloadConsentRefreshMode {
    param($Model,[string]$ArtifactRoot,[bool]$AcceptModelLicense,[bool]$Unattended)
    $receiptPath=Get-FastLlmModelConsentPath -Model $Model -InstallRoot $ArtifactRoot
    if(-not (Test-Path -LiteralPath $receiptPath)){return $null}
    if(Test-FastLlmOffloadExactConsent -Model $Model -ArtifactRoot $ArtifactRoot){return $null}
    try{
        $item=Get-Item -LiteralPath $receiptPath -Force -ErrorAction Stop
        if($item.PSIsContainer -or $item.Length -gt 16384 -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){
            throw 'Existing lab consent receipt is unsafe.'
        }
        $prior=Read-FastLlmJson -Path $receiptPath
        if([int]$prior.schemaVersion -ne 1 -or [string]$prior.modelId -cne [string]$Model.id){
            throw 'Existing lab consent receipt is not a valid v1 receipt for this model.'
        }
    }catch{throw 'Existing lab consent receipt is malformed; refusing to replace it.'}
    if($AcceptModelLicense){return 'explicit-switch'}
    if($Unattended){throw 'Catalog provenance changed; unattended lab prepare requires fresh explicit license acceptance.'}
    Write-Host "Consent needs renewal for model $($Model.id)."
    Write-Host "Upstream: $($Model.upstreamModel) @ $($Model.upstreamRevision)"
    Write-Host "Community artifact: $($Model.repository) @ $($Model.revision)"
    Write-Host "Artifact SHA-256: $($Model.sha256)"
    Write-Host "Upstream license: $($Model.upstreamLicense) ($($Model.upstreamLicenseUrl))"
    Write-Host "Artifact license: $($Model.artifactLicense) (declared by $($Model.artifactProvider))"
    $answer=Read-Host 'Renew consent for this exact catalog provenance? [y/N]'
    if($answer -notmatch '^(?i)y(es)?$'){throw 'Catalog provenance change was not approved.'}
    return 'interactive'
}

function Save-FastLlmOffloadPriorConsent {
    param($Model,[string]$ArtifactRoot)
    $path=Get-FastLlmModelConsentPath -Model $Model -InstallRoot $ArtifactRoot
    $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if($item.Length -gt 16384 -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){
        throw 'Unsafe prior consent receipt; refusing renewal.'
    }
    $backup=$path+'.previous.'+[Guid]::NewGuid().ToString('N')+'.json'
    [IO.File]::Copy($path,$backup,$false)
    return $backup
}

function Assert-FastLlmOffloadMemoryBudget {
    param([long]$AvailableBytes,[long]$ModelBytes)
    if($AvailableBytes -lt 0 -or $ModelBytes -le 0 -or $ModelBytes -gt ([long]::MaxValue-8GB)){
        throw 'Invalid offload RAM preflight values.'
    }
    $required=$ModelBytes+8GB
    if($AvailableBytes -lt $required){throw ('Offload RAM preflight failed: available physical RAM is below model bytes plus an 8 GiB reserve. Required {0} bytes; available {1} bytes. This is not a fit prediction.' -f $required,$AvailableBytes)}
    return [pscustomobject]@{availableBytes=$AvailableBytes;requiredBytes=$required;fitVerified=$false}
}

function Get-FastLlmOffloadAvailableRam {
    if(-not ('Bitworks.FastLlm.LabMemory' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Bitworks.FastLlm {
  public static class LabMemory {
    [StructLayout(LayoutKind.Sequential)] private struct MemoryStatus {
      public uint Length, MemoryLoad;
      public ulong TotalPhysical, AvailablePhysical, TotalPageFile, AvailablePageFile, TotalVirtual, AvailableVirtual, AvailableExtendedVirtual;
    }
    [DllImport("kernel32.dll", SetLastError=true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static extern bool GlobalMemoryStatusEx(ref MemoryStatus status);
    public static long AvailablePhysicalBytes() {
      var status = new MemoryStatus();
      status.Length = (uint)Marshal.SizeOf(typeof(MemoryStatus));
      if (!GlobalMemoryStatusEx(ref status)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
      if (status.AvailablePhysical > Int64.MaxValue) throw new InvalidOperationException("RAM counter overflow.");
      return (long)status.AvailablePhysical;
    }
  }
}
'@ -ErrorAction Stop
    }
    return [Bitworks.FastLlm.LabMemory]::AvailablePhysicalBytes()
}

function ConvertFrom-FastLlmOffloadPlacementLog {
    param([string]$Text,[string]$Device,[int]$RequestedLayers,[bool]$Overflow=$false,
          [int]$CpuBufferLikeLines=-1)
    if($Overflow){throw 'Offload placement capture exceeded its bounded limit.'}
    $offload=@([regex]::Matches($Text,'(?m)^.*load_tensors: offloaded (\d+)/(\d+) layers to GPU\s*$'))
    if($offload.Count -ne 1){throw 'Missing or ambiguous offload-layer evidence.'}
    $loaded=[int]0;$total=[int]0
    if(-not [int]::TryParse($offload[0].Groups[1].Value,[ref]$loaded) -or -not [int]::TryParse($offload[0].Groups[2].Value,[ref]$total) -or
       $loaded -ne $RequestedLayers -or $total -le $loaded){throw 'Reported partial GPU layer placement differs from the fixed request.'}
    $buffers=@([regex]::Matches($Text,'(?m)^.*load_tensors:\s+(Vulkan\d+)\s+model buffer size\s*=\s*([0-9]+(?:\.[0-9]+)?) MiB\s*$'))
    if($buffers.Count -ne 1 -or $buffers[0].Groups[1].Value -cne $Device){throw 'Missing or ambiguous selected-device GPU model-buffer evidence.'}
    $amount=[double]0;$numeric=$buffers[0].Groups[2].Value
    if($numeric.Length -gt 32 -or -not [double]::TryParse($numeric,[Globalization.NumberStyles]::AllowDecimalPoint,[Globalization.CultureInfo]::InvariantCulture,[ref]$amount) -or
       $amount -le 0 -or [double]::IsInfinity($amount) -or [double]::IsNaN($amount)){throw 'Invalid GPU model-buffer size evidence.'}
    $cpuBuffers=@([regex]::Matches($Text,'(?m)^.*load_tensors:\s+(CPU|CPU_Mapped)\s+model buffer size\s*=\s*([0-9]+(?:\.[0-9]+)?) MiB\s*$'))
    if($CpuBufferLikeLines -lt 0){
        $CpuBufferLikeLines=@([regex]::Matches($Text,'(?m)^.*load_tensors:\s+CPU(?:_Mapped)?\s+model buffer size\b.*$')).Count
    }
    if($CpuBufferLikeLines -ne $cpuBuffers.Count -or $cpuBuffers.Count -gt 1){
        throw 'Malformed or ambiguous CPU model-buffer evidence.'
    }
    $cpuAmount=$null;$cpuKind=$null;$cpuEvidence='unavailable: no CPU model-buffer line reported'
    if($cpuBuffers.Count -eq 1){
        $cpuKind=$cpuBuffers[0].Groups[1].Value
        $cpuNumeric=$cpuBuffers[0].Groups[2].Value
        $parsedCpu=[double]0
        if($cpuNumeric.Length -gt 32 -or -not [double]::TryParse($cpuNumeric,[Globalization.NumberStyles]::AllowDecimalPoint,[Globalization.CultureInfo]::InvariantCulture,[ref]$parsedCpu) -or
           $parsedCpu -le 0 -or [double]::IsInfinity($parsedCpu) -or [double]::IsNaN($parsedCpu)){
            throw 'Invalid CPU model-buffer size evidence.'
        }
        $cpuAmount=$parsedCpu
        $cpuEvidence='reported by pinned engine load_tensors model-buffer line; allocation estimate, not physical residency'
    }
    return [pscustomobject]@{
        requestedGpuLayers=$RequestedLayers;reportedGpuLayers=$loaded;reportedTotalLayers=$total
        selectedDevice=$Device;gpuModelBufferMiB=$amount;cpuModelBufferMiB=$cpuAmount;cpuModelBufferKind=$cpuKind
        cpuModelBufferEvidence=$cpuEvidence
        physicalResidencyVerified=$false;performanceQualified=$false
    }
}

function Get-FastLlmOffloadLabStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$LabRunRoot)
    Assert-FastLlmOffloadRootPath $LabRunRoot
    $state=Get-FastLlmStatus -InstallRoot $LabRunRoot
    if($state.phase -eq 'stopped' -and -not $state.PSObject.Properties['schemaVersion']){return $state}
    if($state.schemaVersion -ne 1 -or $state.kind -ne 'fastllm-offload-lab-run'){
        throw 'LabRunRoot does not contain an offload-lab state.'
    }
    if(-not $state.active -and $state.phase -in @('lab-loading','lab-checking','lab-ready')){$state.phase='lab-interrupted'}
    return $state
}

function Request-FastLlmOffloadLabStop {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$LabRunRoot)
    $state=Get-FastLlmOffloadLabStatus -LabRunRoot $LabRunRoot
    if(-not $state.active -or $state.phase -notin @('lab-loading','lab-checking','lab-ready') -or $state.runId -cnotmatch '^[0-9a-f]{32}$'){
        throw 'There is no active supervised offload lab run to stop.'
    }
    $root=Get-FastLlmStateRoot -InstallRoot $LabRunRoot
    $path=Join-FastLlmContainedPath -Root $root -Child ('stop-'+$state.runId)
    if(Test-Path -LiteralPath $path){
        if((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unsafe lab stop request path.'}
    }else{$stream=[IO.File]::Open($path,'CreateNew','Write','None');$stream.Dispose()}
    Write-Host 'Lab stop requested; the owning supervisor will terminate its managed child.'
}

function Initialize-FastLlmOffloadLab {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$ArtifactRoot,[Parameter(Mandatory=$true)][string]$LabRunRoot,
          [Parameter(Mandatory=$true)][string]$CatalogPath,[Parameter(Mandatory=$true)][string]$ModelId,
          [switch]$AcceptModelLicense,[switch]$Unattended)
    Assert-FastLlmOffloadRoots $ArtifactRoot $LabRunRoot
    Assert-FastLlmOffloadLabHost
    $entry=Get-FastLlmOffloadModel $CatalogPath $ModelId
    $artifactLock=Enter-FastLlmOperation $ArtifactRoot
    try{
        $labLock=Enter-FastLlmOperation $LabRunRoot
        try{
            Install-FastLlmEngines -CatalogPath $CatalogPath -InstallRoot $ArtifactRoot
            $refreshMode=Get-FastLlmOffloadConsentRefreshMode -Model $entry.model -ArtifactRoot $ArtifactRoot -AcceptModelLicense ([bool]$AcceptModelLicense) -Unattended ([bool]$Unattended)
            $prior=$null
            if($refreshMode){$prior=Save-FastLlmOffloadPriorConsent -Model $entry.model -ArtifactRoot $ArtifactRoot}
            $plan=[pscustomobject]@{model=$entry.model}
            $approvedForInstall=([bool]$AcceptModelLicense -or [bool]$refreshMode)
            $modelPath=Install-FastLlmModel -Plan $plan -InstallRoot $ArtifactRoot -AcceptModelLicense:$approvedForInstall -Unattended:$Unattended
            if($refreshMode){
                Write-Host "Prior consent remains recoverable at $prior."
            }
            if(-not (Test-FastLlmOffloadExactConsent -Model $entry.model -ArtifactRoot $ArtifactRoot)){
                throw 'The existing consent receipt differs from the current catalog provenance; no lab run is authorized.'
            }
            Write-Host "Experimental offload artifact prepared: $ModelId. No fit or performance claim."
            return $modelPath
        }finally{$labLock.Dispose()}
    }finally{$artifactLock.Dispose()}
}

function Start-FastLlmOffloadLab {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$ArtifactRoot,[Parameter(Mandatory=$true)][string]$LabRunRoot,
          [Parameter(Mandatory=$true)][string]$CatalogPath,[Parameter(Mandatory=$true)][string]$ModelId,
          [Parameter(Mandatory=$true)][ValidatePattern('^Vulkan\d+$')][string]$Device,
          [Parameter(Mandatory=$true)][ValidateRange(1,4096)][int]$GpuLayers,
          [ValidateRange(1,8192)][int]$ContextSize=8192,[ValidateRange(30,1800)][int]$LoadTimeoutSeconds=600)
    Assert-FastLlmOffloadRoots $ArtifactRoot $LabRunRoot
    Assert-FastLlmOffloadLabHost
    $entry=Get-FastLlmOffloadModel $CatalogPath $ModelId
    $model=$entry.model;$catalog=$entry.catalog
    $catalogSha=$entry.catalogSha256
    if($ContextSize -gt [int]$model.contextSize){throw 'Lab context exceeds the selected catalog model context ceiling.'}
    $artifactLock=Enter-FastLlmOperation $ArtifactRoot
    try{
        $labLock=Enter-FastLlmOperation $LabRunRoot
        try{
            $asset=$catalog.engine.assets.vulkan
            if(-not (Test-FastLlmEngineInstallation -InstallRoot $ArtifactRoot -EngineVersion ([string]$catalog.engine.version) -BackendKey 'vulkan' -Asset $asset)){
                throw 'The exact pinned Vulkan engine is not installed and verified. Run lab prepare.'
            }
            $enginePath=Get-FastLlmEngineExecutable -InstallRoot $ArtifactRoot -EngineVersion ([string]$catalog.engine.version) -BackendKey 'vulkan' -EntryPoint ([string]$asset.entryPoint)
            $hardware=Get-FastLlmHardware -CatalogPath $CatalogPath -InstallRoot $ArtifactRoot
            if($hardware.backend -ne 'Vulkan' -or $hardware.enginePath -ne $enginePath){throw 'Fresh live probe did not select the exact pinned Vulkan engine.'}
            $selected=@($hardware.adapters | Where-Object { $_.device -ceq $Device -and $_.isAmd -and -not $_.isIntegrated })
            if($selected.Count -ne 1){throw 'Explicit device must match exactly one live Vulkan adapter passing the alpha AMD/discrete-name heuristic.'}
            $initialAdapter=$selected[0]
            $modelRoot=Join-FastLlmContainedPath -Root $ArtifactRoot -Child 'models'
            if((Get-Item -LiteralPath $modelRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Model cache root cannot be a junction or symbolic link.'}
            $modelPath=Join-FastLlmContainedPath -Root $modelRoot -Child ([string]$model.file)
            if(-not (Test-Path -LiteralPath $modelPath -PathType Leaf) -or
               ((Get-Item -LiteralPath $modelPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -or
               [int64](Get-Item -LiteralPath $modelPath -Force).Length -ne [int64]$model.sizeBytes -or
               -not (Test-FastLlmFileHash -Path $modelPath -Sha256 ([string]$model.sha256))){throw 'Exact model artifact is absent or failed verification. Run lab prepare.'}
            if(-not (Test-FastLlmOffloadExactConsent -Model $model -ArtifactRoot $ArtifactRoot)){throw 'Exact model license consent receipt is missing or differs from the current catalog provenance. Run lab prepare.'}
            $memory=Assert-FastLlmOffloadMemoryBudget -AvailableBytes (Get-FastLlmOffloadAvailableRam) -ModelBytes ([long]$model.sizeBytes)
            # Reprobe immediately before launch. No fixture and no recovery substitution.
            $fresh=Get-FastLlmHardware -CatalogPath $CatalogPath -InstallRoot $ArtifactRoot
            $freshSelected=@($fresh.adapters | Where-Object { $_.device -ceq $Device -and $_.isAmd -and -not $_.isIntegrated })
            if($fresh.backend -ne 'Vulkan' -or $fresh.enginePath -ne $enginePath -or $freshSelected.Count -ne 1 -or
               [string]$freshSelected[0].name -cne [string]$initialAdapter.name -or
               [long]$freshSelected[0].vramMiB -ne [long]$initialAdapter.vramMiB){
                throw 'Selected live Vulkan device changed before launch.'
            }
            if((Get-FileHash -LiteralPath $CatalogPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $catalogSha){
                throw 'Catalog changed during offload preparation.'
            }
            if(-not (Test-FastLlmEngineInstallation -InstallRoot $ArtifactRoot -EngineVersion ([string]$catalog.engine.version) -BackendKey 'vulkan' -Asset $asset) -or
               -not (Test-FastLlmOffloadExactConsent -Model $model -ArtifactRoot $ArtifactRoot)){
                throw 'Pinned engine or exact consent changed before launch.'
            }
            $arguments=@('--model',$modelPath,'--offline','--no-mmproj','--spec-type','none','--alias',[string]$model.id,
                '--host','127.0.0.1','--port','18080','--cors-origins','localhost','--no-cors-credentials',
                '--ctx-size',[string]$ContextSize,'--parallel','1','--n-gpu-layers',[string]$GpuLayers,'--fit','off',
                '--device',$Device,'--split-mode','none','--flash-attn','auto','--cache-type-k',[string]$model.cacheTypeK,
                '--cache-type-v',[string]$model.cacheTypeV,'--jinja','--metrics','--log-verbosity','4','--no-agent','--no-ui')
            $plan=[pscustomobject]@{model=$model;enginePath=$enginePath;modelPath=$modelPath;endpoint='http://127.0.0.1:18080/v1';
                serverArguments=$arguments;device=$Device;gpuLayers=$GpuLayers;contextSize=$ContextSize;memoryPreflight=$memory;
                selectedAdapter=[pscustomobject]@{device=$Device;name=[string]$freshSelected[0].name;
                    reportedTotalVramMiB=[long]$freshSelected[0].vramMiB;reportedFreeVramMiB=[long]$freshSelected[0].freeVramMiB};
                catalogSha256=$catalogSha;
                engineSha256=(Get-FileHash -LiteralPath $enginePath -Algorithm SHA256).Hash.ToLowerInvariant()}
            return Invoke-FastLlmOffloadLabSupervisor -Plan $plan -LabRunRoot $LabRunRoot -LoadTimeoutSeconds $LoadTimeoutSeconds
        }finally{$labLock.Dispose()}
    }finally{$artifactLock.Dispose()}
}

function Invoke-FastLlmOffloadLabSupervisor {
    param($Plan,[string]$LabRunRoot,[int]$LoadTimeoutSeconds=600)
    Initialize-FastLlmProcessHost
    $state=[ordered]@{schemaVersion=1;kind='fastllm-offload-lab-run';runId=[Guid]::NewGuid().ToString('N');phase='lab-loading';
        updatedAt=(Get-Date).ToUniversalTime().ToString('o');endpoint=$Plan.endpoint;modelId=$Plan.model.id;
        modelSha256=$Plan.model.sha256;engineVersion='b10698';catalogSha256=$Plan.catalogSha256;engineSha256=$Plan.engineSha256;
        recipe=[ordered]@{backend='Vulkan';contextSize=$Plan.contextSize;slots=1;device=$Plan.device;
            gpuLayers=$Plan.gpuLayers;fitMode='off';cacheTypeK=$Plan.model.cacheTypeK;cacheTypeV=$Plan.model.cacheTypeV;
            flashAttention='auto';speculation='none';splitMode='none';catalogSha256=$Plan.catalogSha256;
            engineSha256=$Plan.engineSha256;tensorSplit=$null;selectedAdapters=@($Plan.selectedAdapter);
            requestedArguments=@($Plan.serverArguments | ForEach-Object {if($_ -ceq $Plan.modelPath){'<verified-model>'}else{$_}});
            configurationIsolation='empty-per-run-config-roots-and-targeted-environment-sanitization'};
        requestedGpuLayers=$Plan.gpuLayers;requestedDevice=$Plan.device;requestedContextSize=$Plan.contextSize;
        fitMode='off';memoryPreflight=$Plan.memoryPreflight;placement=$null;canary=$null;processIdentity=$null;
        experimental=$true;performanceQualified=$false;physicalResidencyVerified=$false;failureCode=$null}
    $stateRoot=Get-FastLlmStateRoot -InstallRoot $LabRunRoot -Create
    $stopPath=Join-FastLlmContainedPath -Root $stateRoot -Child ('stop-'+$state.runId)
    $sandbox=New-FastLlmRuntimeSandbox -InstallRoot $LabRunRoot
    $child=New-Object Bitworks.FastLlm.ProcessHost
    $baseUrl='http://127.0.0.1:18080'
    try{
        $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,18080)
        try{$listener.Server.ExclusiveAddressUse=$true;$listener.Start()}finally{$listener.Stop()}
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=$Plan.enginePath
        $info.Arguments=Join-FastLlmProcessArguments -Arguments $Plan.serverArguments
        $info.WorkingDirectory=Split-Path -Parent $Plan.enginePath
        foreach($name in @($info.EnvironmentVariables.Keys)){if(Test-FastLlmEnvironmentNameRequiresClearing $name){$info.EnvironmentVariables.Remove($name)}}
        $info.EnvironmentVariables['APPDATA']=$sandbox.appData
        $info.EnvironmentVariables['PROGRAMDATA']=$sandbox.programData
        if($env:OS -eq 'Windows_NT'){$info.EnvironmentVariables['PATH']="$($info.WorkingDirectory);$env:SystemRoot\System32;$env:SystemRoot"}
        Write-FastLlmState -InstallRoot $LabRunRoot -State $state
        $child.Start($info)
        $state.processIdentity=[ordered]@{pid=[int]$child.Process.Id;startUtcTicks=[long]$child.Process.StartTime.ToUniversalTime().Ticks}
        $state.updatedAt=(Get-Date).ToUniversalTime().ToString('o')
        Write-FastLlmState -InstallRoot $LabRunRoot -State $state
        $timer=[Diagnostics.Stopwatch]::StartNew();$healthy=$false
        while($timer.Elapsed.TotalSeconds -lt $LoadTimeoutSeconds){
            if(Test-Path -LiteralPath $stopPath){$state.phase='lab-stopped';return 0}
            if($child.Process.HasExited){throw 'Lab server exited before readiness.'}
            try{$health=Invoke-FastLlmHttp -BaseUrl $baseUrl -Path '/health' -TimeoutMs 1000
                $healthy=$health.Status -eq 200 -and (ConvertFrom-Json $health.Body).status -eq 'ok'}catch{$healthy=$false}
            if($healthy){break}
            Start-Sleep -Milliseconds 200
        }
        if(-not $healthy){throw 'Lab model-load readiness deadline exceeded.'}
        $null=$child.FreezeStartupDiagnostics()
        $state.phase='lab-checking';$state.updatedAt=(Get-Date).ToUniversalTime().ToString('o')
        Write-FastLlmState -InstallRoot $LabRunRoot -State $state
        $state.placement=ConvertFrom-FastLlmOffloadPlacementLog -Text $child.PlacementSnapshot() -Device $Plan.device -RequestedLayers $Plan.gpuLayers -Overflow $child.PlacementOverflow -CpuBufferLikeLines $child.CpuBufferLikeLines
        $state.canary=Test-FastLlmApiCanary -BaseUrl $baseUrl -ModelId $Plan.model.id -ContextSize $Plan.contextSize
        if($child.Process.HasExited){throw 'Lab server exited during API canary.'}
        $child.DiscardOutput()
        $state.phase='lab-ready';$state.updatedAt=(Get-Date).ToUniversalTime().ToString('o')
        Write-FastLlmState -InstallRoot $LabRunRoot -State $state
        Write-Host "Experimental CPU-offload lab ready: $($Plan.endpoint). This is not a fit, residency, quality or performance approval."
        while(-not $child.Process.WaitForExit(250)){
            if(Test-Path -LiteralPath $stopPath){$state.phase='lab-stopped';return 0}
        }
        if($child.Process.ExitCode -ne 0){throw 'Lab server exited unexpectedly after readiness.'}
        $state.phase='lab-stopped';return 0
    }catch{$state.phase='lab-failed';$state.failureCode='startup-or-runtime-check-failed';throw}
    finally{
        try{$child.Dispose()}finally{
            try{$state.updatedAt=(Get-Date).ToUniversalTime().ToString('o');Write-FastLlmState -InstallRoot $LabRunRoot -State $state}
            finally{try{Remove-FastLlmRuntimeSandbox $sandbox}finally{if(Test-Path -LiteralPath $stopPath){Remove-Item -LiteralPath $stopPath -Force}}}
        }
    }
}
