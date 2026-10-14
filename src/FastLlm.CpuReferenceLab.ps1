# Private CPU-reference lane for the Qwen3.8-27B Q4 backend-parity diagnostic. Loaded inside FastLlm.psm1 only.
# It runs exactly the catalog model qwen3.8-27b-ud-q4-k-m at context 32768, one slot, on a distinct loopback
# port with no offload device. It never calls the normal planner, normal supervisor or benchmark producer, and
# it changes nothing about the normal all-GPU serving path. No fit, residency, speed or quality claim follows.
function Get-FastLlmCpuReferenceFixed {
    # Fixed protocol inputs (QWEN38-BACKEND-PARITY-PROTOCOL-2026-10-06). Port 18089 is unused by every other
    # lab (8080 normal, 18080 offload, 18081 HIP, 18083 fit, 18084 multi-slot, 18085/18086 replicas, 18087 gateway;
    # 18088 is used by gateway test mocks).
    return [ordered]@{
        modelId='qwen3.8-27b-ud-q4-k-m';contextSize=32768;slots=1;port=18089;engineVersion='b10698'
        catalogSha256='65b8f2f9ca340dab273274086aba9e8f01cb14a2b8cf4bb65c5ed5f6e779caa6'
        engineSha256='9f4dd930c50cdd3f7946b679ff67eaa124343096abdb56f2978199cf035758c7'
        modelSha256='322e194ff79741c7baa497c240f677f54b201b0efab44ca8e50f122b39123482'
        stateKind='fastllm-cpu-reference-lab-run';memoryReserveBytes=[int64]4GB
    }
}

function Get-FastLlmCpuReferenceSha256 {
    param([string]$Value)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)))).Replace('-','').ToLowerInvariant()}
    finally{$sha.Dispose()}
}

function Assert-FastLlmCpuReferenceRootPath {
    param([string]$Root)
    $part=New-Object IO.DirectoryInfo([IO.Path]::GetFullPath($Root))
    while($null -ne $part){
        if($part.Exists -and ($part.Attributes -band [IO.FileAttributes]::ReparsePoint)){
            throw 'CPU reference lab roots cannot include junctions or symbolic links.'
        }
        $part=$part.Parent
    }
}

function Assert-FastLlmCpuReferenceRoots {
    param([string]$ArtifactRoot,[string]$LabRunRoot)
    $a=[IO.Path]::GetFullPath($ArtifactRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $b=[IO.Path]::GetFullPath($LabRunRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    Assert-FastLlmCpuReferenceRootPath $a
    Assert-FastLlmCpuReferenceRootPath $b
    $comparison=if($env:OS -eq 'Windows_NT'){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    $separator=[string][IO.Path]::DirectorySeparatorChar
    if($a.Equals($b,$comparison) -or $a.StartsWith($b+$separator,$comparison) -or $b.StartsWith($a+$separator,$comparison)){
        throw 'ArtifactRoot and LabRunRoot must be separate, non-overlapping directories.'
    }
}

function Assert-FastLlmCpuReferenceHost {
    if($env:OS -ne 'Windows_NT'){throw 'The CPU reference lab requires Windows.'}
    if(-not [Environment]::Is64BitProcess){throw 'The CPU reference lab requires 64-bit PowerShell.'}
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    if((New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
        throw 'Run the CPU reference lab as a standard user, not an administrator.'
    }
}

function Get-FastLlmCpuReferenceModel {
    param([string]$CatalogPath)
    $fixed=Get-FastLlmCpuReferenceFixed
    $catalogSha=(Get-FileHash -LiteralPath $CatalogPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $catalog=Get-FastLlmCatalog -CatalogPath $CatalogPath
    if((Get-FileHash -LiteralPath $CatalogPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $catalogSha){throw 'Catalog changed while resolving the CPU reference model.'}
    if($catalogSha -cne $fixed.catalogSha256){throw 'The catalog differs from the protocol-bound catalog.'}
    if([string]$catalog.engine.version -cne $fixed.engineVersion -or -not [bool]$catalog.engine.assets.vulkan.enabled){
        throw 'The CPU reference lab requires the pinned b10698 Vulkan engine archive.'
    }
    $matches=@($catalog.models | Where-Object { [string]$_.id -ceq $fixed.modelId })
    if($matches.Count -ne 1){throw 'The exact CPU reference model is not in the validated catalog.'}
    $model=$matches[0]
    if([string]$model.sha256 -cne $fixed.modelSha256 -or [int]$model.contextSize -ne $fixed.contextSize -or
       [int]$model.parallel -ne 1 -or [string]$model.cacheTypeK -cne 'f16' -or [string]$model.cacheTypeV -cne 'f16'){
        throw 'The catalog model differs from the protocol-bound Q4 recipe.'
    }
    return [pscustomobject]@{catalog=$catalog;model=$model;catalogSha256=$catalogSha}
}

function Test-FastLlmCpuReferenceExactConsent {
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

function Assert-FastLlmCpuReferenceMemoryBudget {
    param([long]$AvailableBytes,[long]$ModelBytes)
    $fixed=Get-FastLlmCpuReferenceFixed
    if($AvailableBytes -lt 0 -or $ModelBytes -le 0 -or $ModelBytes -gt ([long]::MaxValue-[int64]$fixed.memoryReserveBytes)){
        throw 'Invalid CPU reference RAM preflight values.'
    }
    $required=[int64]$ModelBytes+[int64]$fixed.memoryReserveBytes
    if($AvailableBytes -lt $required){
        throw ('CPU reference RAM preflight failed: available physical RAM is below model bytes plus a 4 GiB reserve. Required {0} bytes; available {1} bytes. This is not a fit prediction.' -f $required,$AvailableBytes)
    }
    return [pscustomobject]@{availableBytes=$AvailableBytes;requiredBytes=$required;fitVerified=$false}
}

function Get-FastLlmCpuReferenceAvailableRam {
    # GlobalMemoryStatusEx; deliberately not CIM/WMI.
    if(-not ('Bitworks.FastLlm.CpuReferenceMemory' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Bitworks.FastLlm {
  public static class CpuReferenceMemory {
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
    return [Bitworks.FastLlm.CpuReferenceMemory]::AvailablePhysicalBytes()
}

function Get-FastLlmCpuReferenceArguments {
    # The normal Q4 recipe (single-adapter plan arguments) with exactly these changes:
    #   --device Vulkan0 -> --device none; --n-gpu-layers all -> 0; --fit on -> --fit off;
    #   --no-op-offload and --no-kv-offload added; --port 8080 -> the distinct CPU lab port.
    # --fit-target and --split-mode none are retained so the remaining arguments are literally identical.
    param([Parameter(Mandatory=$true)]$Model,[Parameter(Mandatory=$true)][string]$ModelPath)
    $fixed=Get-FastLlmCpuReferenceFixed
    return @(
        '--model',$ModelPath,
        '--offline',
        '--no-mmproj',
        '--spec-type','none',
        '--alias',[string]$Model.id,
        '--host','127.0.0.1',
        '--port',[string]$fixed.port,
        '--cors-origins','localhost',
        '--no-cors-credentials',
        '--ctx-size',[string]$Model.contextSize,
        '--parallel',[string]$Model.parallel,
        '--n-gpu-layers','0',
        '--fit','off',
        '--fit-target',[string]$Model.fitTargetMiB,
        '--device','none',
        '--split-mode','none',
        '--no-op-offload',
        '--no-kv-offload',
        '--flash-attn','auto',
        '--cache-type-k',[string]$Model.cacheTypeK,
        '--cache-type-v',[string]$Model.cacheTypeV,
        '--jinja',
        '--metrics',
        '--log-verbosity','4',
        '--no-agent',
        '--no-ui'
    )
}

function ConvertFrom-FastLlmCpuReferencePlacementLog {
    # PlacementText: ProcessHost.PlacementSnapshot(); StartupText: FreezeStartupDiagnostics();
    # OutputText: ProcessHost.Snapshot() (bounded rolling capture); SelectedDeviceLikeLines: ProcessHost.SelectedDeviceLikeLines.
    # "offloaded 0/N layers" only echoes --n-gpu-layers, so it is never sufficient: the engine must also report CPU
    # model, KV and compute buffers, no selected GPU device, and no Vulkan/ROCm buffer line anywhere. Any capture
    # overflow or a truncated general output capture (the only place Vulkan_Host buffer lines can appear) is a refusal.
    param([string]$PlacementText,[string]$StartupText='',[string]$OutputText='',
          [bool]$PlacementOverflow=$false,[bool]$StartupOverflow=$false,[bool]$OutputTruncated=$false,
          [int]$CpuBufferLikeLines=-1,[int]$SelectedDeviceLikeLines=0)
    if($PlacementOverflow){throw 'CPU reference placement capture exceeded its bounded limit.'}
    if($StartupOverflow){throw 'CPU reference startup capture exceeded its bounded limit.'}
    if($OutputTruncated){throw 'The general output capture was truncated; Vulkan_Host buffer lines cannot be excluded.'}
    if($SelectedDeviceLikeLines -ne 0){throw 'The engine reported a selected GPU device; --device none was not honoured.'}
    $all=@($PlacementText,$StartupText,$OutputText) -join "`n"
    $selected=@([regex]::Matches($all,'(?im)^.*llama_prepare_model_devices:\s+using device\b.*$'))
    if($selected.Count -gt 0){throw 'The engine reported a selected GPU device; --device none was not honoured.'}
    $gpuBuffer=@([regex]::Matches($all,'(?im)^.*\b(?:Vulkan|ROCm)[A-Za-z0-9_]*\s+(?:[A-Za-z]+\s+){0,2}buffer\b.*$'))
    $gpuStartup=@([regex]::Matches($StartupText,'(?im)^\s*(?:kv|compute)\s+(?:Vulkan|ROCm)[A-Za-z0-9_]*\b.*$'))
    if($gpuBuffer.Count -gt 0 -or $gpuStartup.Count -gt 0){
        throw 'The engine reported a GPU model, KV or compute buffer; this is not a CPU-only placement.'
    }
    $offload=@([regex]::Matches($PlacementText,'(?m)^.*load_tensors: offloaded (\d+)/(\d+) layers to GPU\s*$'))
    if($offload.Count -ne 1){throw 'Missing or ambiguous offload-layer evidence.'}
    $loaded=[int]0;$total=[int]0
    if(-not [int]::TryParse($offload[0].Groups[1].Value,[ref]$loaded) -or
       -not [int]::TryParse($offload[0].Groups[2].Value,[ref]$total) -or $loaded -ne 0 -or $total -le 0){
        throw 'The engine reported a nonzero GPU layer count or an invalid layer total.'
    }
    $cpu=@([regex]::Matches($PlacementText,'(?m)^.*load_tensors:\s+(CPU|CPU_Mapped)\s+model buffer size\s*=\s*([0-9]+(?:\.[0-9]+)?) MiB\s*$'))
    if($CpuBufferLikeLines -lt 0){
        $CpuBufferLikeLines=@([regex]::Matches($PlacementText,'(?m)^.*load_tensors:\s+CPU(?:_Mapped)?\s+model buffer size\b.*$')).Count
    }
    if($cpu.Count -lt 1){throw 'Missing CPU model-buffer evidence.'}
    if($CpuBufferLikeLines -ne $cpu.Count -or $cpu.Count -gt 2){throw 'Malformed or ambiguous CPU model-buffer evidence.'}
    $kinds=@($cpu | ForEach-Object { $_.Groups[1].Value })
    if(@($kinds | Select-Object -Unique).Count -ne $kinds.Count){throw 'Duplicate CPU model-buffer evidence.'}
    $sizes=@($cpu | ForEach-Object { $_.Groups[2].Value })
    # CPU_REPACK is not in ProcessHost's placement allowlist; it can only be read from the (untruncated) general capture.
    $repack=@([regex]::Matches($OutputText,'(?m)^.*load_tensors:\s+CPU_REPACK\s+model buffer size\s*=\s*([0-9]+(?:\.[0-9]+)?) MiB\s*$'))
    $repackLike=@([regex]::Matches($OutputText,'(?m)^.*load_tensors:\s+CPU_REPACK\s+model buffer size\b.*$'))
    if($repack.Count -ne $repackLike.Count -or $repack.Count -gt 1){throw 'Malformed or ambiguous CPU_REPACK model-buffer evidence.'}
    if($repack.Count -eq 1){$kinds+='CPU_REPACK';$sizes+=$repack[0].Groups[1].Value}
    $sum=[double]0
    foreach($numeric in $sizes){
        $value=[double]0
        if($numeric.Length -gt 32 -or -not [double]::TryParse($numeric,[Globalization.NumberStyles]::AllowDecimalPoint,[Globalization.CultureInfo]::InvariantCulture,[ref]$value) -or
           $value -le 0 -or [double]::IsInfinity($value) -or [double]::IsNaN($value)){
            throw 'Invalid CPU model-buffer size evidence.'
        }
        $sum+=$value
    }
    $startupKv=@([regex]::Matches($StartupText,'(?m)^\s*kv\s+CPU(?:_[A-Za-z0-9]+)?\s+[0-9]+(?:\.[0-9]+)?\s*$'))
    $startupCompute=@([regex]::Matches($StartupText,'(?m)^\s*compute\s+CPU(?:_[A-Za-z0-9]+)?\s+[0-9]+(?:\.[0-9]+)?\s*$'))
    if($startupKv.Count -lt 1 -or $startupCompute.Count -lt 1){
        throw 'Missing CPU KV or compute buffer evidence in the startup capture.'
    }
    return [pscustomobject][ordered]@{
        requestedGpuLayers=0;reportedGpuLayers=$loaded;reportedTotalLayers=$total
        cpuModelBufferMiB=$sum;cpuModelBufferKinds=@($kinds);cpuModelBufferLineCount=@($kinds).Count
        cpuKvBufferLines=$startupKv.Count;cpuComputeBufferLines=$startupCompute.Count;selectedDeviceLines=0
        gpuBufferLinesObserved=0;fullOutputScanTruncated=$false
        evidence='reported by pinned engine log lines; allocation evidence, not physical residency'
        physicalResidencyVerified=$false;performanceQualified=$false
    }
}

function Get-FastLlmCpuReferencePlacementSummary {
    # Free-text-free refusal evidence: counts plus lines that match a strict normalized allowlist. Never throws.
    param([string]$PlacementText,[string]$StartupText='',[string]$OutputText='',
          [bool]$PlacementOverflow=$false,[bool]$StartupOverflow=$false,[bool]$OutputTruncated=$false,
          [int]$SelectedDeviceLikeLines=0)
    $placementLines=@();$startupLines=@()
    foreach($line in @(([string]$PlacementText) -split "`r?`n")){
        if($placementLines.Count -ge 64){break}
        $trimmed=$line.Trim()
        if($trimmed -cmatch '^load_tensors: (?:offloaded [0-9]{1,6}/[0-9]{1,6} layers to GPU|[A-Za-z0-9_]{1,32} model buffer size = [0-9]{1,32}(?:\.[0-9]{1,32})? MiB)$'){$placementLines+=$trimmed}
    }
    foreach($line in @(([string]$StartupText) -split "`r?`n")){
        if($startupLines.Count -ge 32){break}
        $trimmed=$line.Trim()
        if($trimmed -cmatch '^(?:(?:kv|compute) [A-Za-z0-9_]{1,32} [0-9]{1,32}(?:\.[0-9]{1,32})?|flash-mode (?:auto|enabled|disabled)|flash-resolved (?:enabled|disabled))$'){$startupLines+=$trimmed}
    }
    $all=@($PlacementText,$StartupText,$OutputText) -join "`n"
    return [ordered]@{
        placementLines=@($placementLines);startupLines=@($startupLines)
        gpuBufferLineCount=@([regex]::Matches($all,'(?im)^.*\b(?:Vulkan|ROCm)[A-Za-z0-9_]*\s+(?:[A-Za-z]+\s+){0,2}buffer\b.*$')).Count
        usingDeviceLineCount=@([regex]::Matches($all,'(?im)^.*llama_prepare_model_devices:\s+using device\b.*$')).Count
        selectedDeviceLikeLines=$SelectedDeviceLikeLines
        cpuReferenceBufferLineCount=@([regex]::Matches($all,'(?im)^.*\bCPU(?:_[A-Za-z0-9]+)?\s+(?:[A-Za-z]+\s+){0,2}buffer\b.*$')).Count
        placementOverflow=$PlacementOverflow;startupOverflow=$StartupOverflow;outputTruncated=$OutputTruncated
    }
}

function Assert-FastLlmCpuReferenceListenerOwner {
    param([int]$ProcessId,[int]$Port)
    if(-not ('Bitworks.FastLlm.WindowsGpuTelemetry' -as [type])){
        Add-Type -Path (Join-Path $PSScriptRoot 'WindowsGpuTelemetry.cs') -ErrorAction Stop
    }
    $owners=@([Bitworks.FastLlm.WindowsGpuTelemetry]::GetLoopbackListenerOwners($Port))
    if($owners.Count -ne 1 -or [int]$owners[0] -ne $ProcessId){throw 'The supervised CPU reference child does not own the loopback listener.'}
}

function Test-FastLlmCpuReferenceApiCanary {
    # Same checks as the normal readiness canary, with CPU-appropriate (longer, still bounded) timeouts.
    param([string]$BaseUrl,[string]$ModelId,[int]$ContextSize,[scriptblock]$Request=$null,[int]$TimeoutMs=180000)
    if($null -eq $Request){$Request={param($Path,$Body,$Timeout) Invoke-FastLlmHttp -BaseUrl $BaseUrl -Path $Path -Body $Body -TimeoutMs $Timeout}}
    $models=& $Request '/v1/models' $null 5000
    if($models.Status -ne 200 -or @((ConvertFrom-Json $models.Body).data | Where-Object { $_.id -eq $ModelId }).Count -ne 1){throw 'Served model identity does not match the plan.'}
    $props=& $Request '/props' $null 5000
    if($props.Status -ne 200){throw 'Server properties are unavailable.'}
    $properties=ConvertFrom-Json $props.Body
    if([int]$properties.default_generation_settings.n_ctx -ne $ContextSize -or [int]$properties.total_slots -ne 1){throw 'Effective context/slots differ from the requested configuration.'}
    $firstToken=$null
    for($i=0;$i -lt 2;$i++){
        $answer=& $Request '/completion' @{prompt='The capital of France is';n_predict=1;temperature=0;seed=42;cache_prompt=$false;return_tokens=$true;ignore_eos=$true;stream=$false} $TimeoutMs
        if($answer.Status -ne 200){throw 'One-token inference canary failed.'}
        $data=ConvertFrom-Json $answer.Body
        if(@($data.tokens).Count -ne 1 -or [long]$data.tokens[0] -lt 0){throw 'One-token canary returned an invalid token.'}
        if($i -eq 0){$firstToken=[long]$data.tokens[0]}
        elseif([long]$data.tokens[0] -ne $firstToken){throw 'Greedy one-token canary was not repeatable.'}
    }
    $chat=& $Request '/v1/chat/completions' @{model=$ModelId;messages=@(@{role='user';content='Say hello.'});max_tokens=8;temperature=0;seed=42;stream=$false} $TimeoutMs
    if($chat.Status -ne 200){throw 'Synchronous OpenAI chat canary failed.'}
    $chatData=ConvertFrom-Json $chat.Body
    if(@($chatData.choices).Count -ne 1){throw 'Synchronous chat returned an invalid choice count.'}
    $message=$chatData.choices[0].message
    if($message.role -ne 'assistant'){throw 'Synchronous chat returned an invalid role.'}
    $chatText=$false
    foreach($key in @('content','reasoning_content','reasoning')){
        $property=$message.PSObject.Properties[$key]
        if($property -and -not [string]::IsNullOrEmpty([string]$property.Value)){$chatText=$true}
    }
    if(-not $chatText){throw 'Synchronous chat returned no text.'}
    $stream=& $Request '/v1/chat/completions' @{model=$ModelId;messages=@(@{role='user';content='Say hello.'});max_tokens=8;temperature=0;seed=42;stream=$true} $TimeoutMs
    if($stream.Status -ne 200){throw 'OpenAI streaming canary failed.'}
    $hasText=$false;$done=$false
    foreach($line in ($stream.Body -split "`r?`n")){
        if($line -eq 'data: [DONE]'){$done=$true;continue}
        if($line.StartsWith('data: ')){
            $event=$line.Substring(6) | ConvertFrom-Json
            foreach($choice in @($event.choices)){
                foreach($key in @('content','reasoning_content','reasoning')){
                    $property=$choice.delta.PSObject.Properties[$key]
                    if($property -and -not [string]::IsNullOrEmpty([string]$property.Value)){$hasText=$true}
                }
            }
        }
    }
    if(-not $done -or -not $hasText){throw 'Streaming canary lacked text or its completion marker.'}
    return [pscustomobject]@{modelIdentity=$true;effectiveContext=$ContextSize;repeatableToken=$true;synchronousChat=$true;streaming=$true;semanticCorrectnessQualified=$false}
}

function Get-FastLlmCpuReferenceLabStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$LabRunRoot)
    Assert-FastLlmCpuReferenceRootPath $LabRunRoot
    $state=Get-FastLlmStatus -InstallRoot $LabRunRoot
    $fixed=Get-FastLlmCpuReferenceFixed
    if($state.phase -eq 'stopped' -and -not $state.PSObject.Properties['schemaVersion']){return $state}
    if($state.schemaVersion -ne 1 -or $state.kind -cne $fixed.stateKind){
        throw 'LabRunRoot does not contain a CPU reference lab state.'
    }
    if(-not $state.active -and $state.phase -in @('lab-loading','lab-checking','lab-ready')){$state.phase='lab-interrupted'}
    return $state
}

function Request-FastLlmCpuReferenceLabStop {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$LabRunRoot)
    $state=Get-FastLlmCpuReferenceLabStatus -LabRunRoot $LabRunRoot
    if(-not $state.active -or $state.phase -notin @('lab-loading','lab-checking','lab-ready') -or $state.runId -cnotmatch '^[0-9a-f]{32}$'){
        throw 'There is no active supervised CPU reference lab run to stop.'
    }
    $root=Get-FastLlmStateRoot -InstallRoot $LabRunRoot
    $path=Join-FastLlmContainedPath -Root $root -Child ('stop-'+$state.runId)
    if(Test-Path -LiteralPath $path){
        if((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unsafe lab stop request path.'}
    }else{$stream=[IO.File]::Open($path,'CreateNew','Write','None');$stream.Dispose()}
    Write-Host 'CPU reference lab stop requested; the owning supervisor will terminate its managed child.'
}

function Get-FastLlmCpuReferenceBinding {
    param($State)
    $identity=[ordered]@{
        runId=$State.runId;pid=[int]$State.processIdentity.pid;startUtcTicks=[long]$State.processIdentity.startUtcTicks
        modelId=$State.modelId;modelSha256=$State.modelSha256;engineVersion=$State.engineVersion
        engineSha256=$State.recipe.engineSha256;catalogSha256=$State.recipe.catalogSha256
        endpoint=$State.endpoint;recipe=$State.recipe;placement=$State.placement;canary=$State.canary
        startupDiagnostics=$(if($State.PSObject.Properties['startupDiagnostics']){$State.startupDiagnostics}else{$null})
    }
    return Get-FastLlmCpuReferenceSha256 (ConvertTo-Json -InputObject $identity -Depth 16 -Compress)
}

function Test-FastLlmCpuReferenceArgument {
    param([object[]]$Arguments,[string]$Name,[string]$Expected)
    $indices=@(for($i=0;$i -lt $Arguments.Count;$i++){if([string]$Arguments[$i] -ceq $Name){$i}})
    return $indices.Count -eq 1 -and $indices[0]+1 -lt $Arguments.Count -and [string]$Arguments[$indices[0]+1] -ceq $Expected
}

function Assert-FastLlmCpuReferenceState {
    param($State,[string]$ExpectedBinding)
    $fixed=Get-FastLlmCpuReferenceFixed
    $endpoint='http://127.0.0.1:'+$fixed.port+'/v1'
    if(-not $State -or [int]$State.schemaVersion -ne 1 -or $State.kind -cne $fixed.stateKind -or
       $State.active -isnot [bool] -or -not $State.active -or $State.phase -cne 'lab-ready' -or
       $State.endpoint -cne $endpoint -or $State.runId -cnotmatch '^[0-9a-f]{32}$' -or
       $State.modelId -cne $fixed.modelId -or $State.modelSha256 -cne $fixed.modelSha256 -or
       $State.engineVersion -cne $fixed.engineVersion -or -not $State.recipe -or
       $State.recipe.engineSha256 -cne $fixed.engineSha256 -or $State.recipe.catalogSha256 -cne $fixed.catalogSha256 -or
       [int]$State.recipe.contextSize -ne $fixed.contextSize -or [int]$State.recipe.slots -ne 1 -or
       [string]$State.recipe.device -cne 'none' -or [int]$State.recipe.gpuLayers -ne 0 -or
       [int]$State.processIdentity.pid -le 0 -or [long]$State.processIdentity.startUtcTicks -le 0 -or
       $State.canary.modelIdentity -isnot [bool] -or -not $State.canary.modelIdentity -or
       $State.canary.repeatableToken -isnot [bool] -or -not $State.canary.repeatableToken -or
       $State.canary.synchronousChat -isnot [bool] -or -not $State.canary.synchronousChat -or
       $State.canary.streaming -isnot [bool] -or -not $State.canary.streaming -or
       $State.canary.semanticCorrectnessQualified -isnot [bool] -or $State.canary.semanticCorrectnessQualified -or
       [int]$State.canary.effectiveContext -ne $fixed.contextSize -or
       -not $State.placement -or [int]$State.placement.reportedGpuLayers -ne 0 -or
       [int]$State.placement.reportedTotalLayers -le 0 -or [double]$State.placement.cpuModelBufferMiB -le 0 -or
       [int]$State.placement.gpuBufferLinesObserved -ne 0){
        throw 'The exact supervised CPU reference run is not ready or its state is inconsistent.'
    }
    $arguments=@($State.recipe.requestedArguments)
    foreach($pair in @(@('--host','127.0.0.1'),@('--port',[string]$fixed.port),@('--alias',$fixed.modelId),
        @('--parallel','1'),@('--ctx-size',[string]$fixed.contextSize),@('--device','none'),@('--n-gpu-layers','0'),
        @('--fit','off'),@('--spec-type','none'),@('--flash-attn','auto'),@('--cache-type-k','f16'),
        @('--cache-type-v','f16'),@('--model','<verified-model>'))){
        if(-not (Test-FastLlmCpuReferenceArgument $arguments $pair[0] $pair[1])){throw 'CPU reference recipe arguments differ from the fixed run.'}
    }
    foreach($flag in @('--no-op-offload','--no-kv-offload','--offline','--no-mmproj','--jinja')){
        if(@($arguments | Where-Object {$_ -ceq $flag}).Count -ne 1){throw 'CPU reference recipe is missing a fixed flag.'}
    }
    $binding=Get-FastLlmCpuReferenceBinding $State
    if($ExpectedBinding -and $binding -cne $ExpectedBinding){throw 'Supervised CPU reference run binding changed.'}
    return $binding
}

function Assert-FastLlmCpuReferenceProcess {
    param($State)
    $fixed=Get-FastLlmCpuReferenceFixed
    Assert-FastLlmCpuReferenceListenerOwner -ProcessId ([int]$State.processIdentity.pid) -Port ([int]$fixed.port)
    $process=$null
    try{
        $process=[Diagnostics.Process]::GetProcessById([int]$State.processIdentity.pid)
        if($process.HasExited -or $process.ProcessName -cne 'llama-server' -or
           [long]$process.StartTime.ToUniversalTime().Ticks -ne [long]$State.processIdentity.startUtcTicks){throw 'Serving process identity changed.'}
        if((Get-FileHash -LiteralPath $process.MainModule.FileName -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$State.recipe.engineSha256){
            throw 'Serving executable digest changed.'
        }
    }finally{if($process){$process.Dispose()}}
}

function Start-FastLlmCpuReferenceLab {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$ArtifactRoot,[Parameter(Mandatory=$true)][string]$LabRunRoot,
          [Parameter(Mandatory=$true)][string]$CatalogPath,[ValidateRange(30,3600)][int]$LoadTimeoutSeconds=1200)
    Assert-FastLlmCpuReferenceRoots $ArtifactRoot $LabRunRoot
    Assert-FastLlmCpuReferenceHost
    $fixed=Get-FastLlmCpuReferenceFixed
    $entry=Get-FastLlmCpuReferenceModel $CatalogPath
    $model=$entry.model;$catalog=$entry.catalog;$catalogSha=$entry.catalogSha256
    $artifactLock=Enter-FastLlmOperation $ArtifactRoot
    try{
        $labLock=Enter-FastLlmOperation $LabRunRoot
        try{
            $asset=$catalog.engine.assets.vulkan
            if(-not (Test-FastLlmEngineInstallation -InstallRoot $ArtifactRoot -EngineVersion ([string]$catalog.engine.version) -BackendKey 'vulkan' -Asset $asset)){
                throw 'The exact pinned Vulkan engine archive is not installed and verified. This lane never acquires artifacts.'
            }
            $enginePath=Get-FastLlmEngineExecutable -InstallRoot $ArtifactRoot -EngineVersion ([string]$catalog.engine.version) -BackendKey 'vulkan' -EntryPoint ([string]$asset.entryPoint)
            $engineSha=(Get-FileHash -LiteralPath $enginePath -Algorithm SHA256).Hash.ToLowerInvariant()
            if($engineSha -cne $fixed.engineSha256){throw 'The installed engine differs from the protocol-bound engine.'}
            $modelRoot=Join-FastLlmContainedPath -Root $ArtifactRoot -Child 'models'
            if((Get-Item -LiteralPath $modelRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Model cache root cannot be a junction or symbolic link.'}
            $modelPath=Join-FastLlmContainedPath -Root $modelRoot -Child ([string]$model.file)
            if(-not (Test-Path -LiteralPath $modelPath -PathType Leaf) -or
               ((Get-Item -LiteralPath $modelPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -or
               [int64](Get-Item -LiteralPath $modelPath -Force).Length -ne [int64]$model.sizeBytes -or
               -not (Test-FastLlmFileHash -Path $modelPath -Sha256 ([string]$model.sha256))){
                throw 'Exact cached model artifact is absent or failed verification. This lane never acquires artifacts.'
            }
            if(-not (Test-FastLlmCpuReferenceExactConsent -Model $model -ArtifactRoot $ArtifactRoot)){
                throw 'Exact model license consent receipt is missing or differs from the current catalog provenance.'
            }
            $memory=Assert-FastLlmCpuReferenceMemoryBudget -AvailableBytes (Get-FastLlmCpuReferenceAvailableRam) -ModelBytes ([long]$model.sizeBytes)
            if((Get-FileHash -LiteralPath $CatalogPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $catalogSha){
                throw 'Catalog changed during CPU reference preparation.'
            }
            if(-not (Test-FastLlmEngineInstallation -InstallRoot $ArtifactRoot -EngineVersion ([string]$catalog.engine.version) -BackendKey 'vulkan' -Asset $asset) -or
               -not (Test-FastLlmCpuReferenceExactConsent -Model $model -ArtifactRoot $ArtifactRoot)){
                throw 'Pinned engine or exact consent changed before launch.'
            }
            $arguments=Get-FastLlmCpuReferenceArguments -Model $model -ModelPath $modelPath
            $plan=[pscustomobject]@{model=$model;enginePath=$enginePath;modelPath=$modelPath;
                endpoint=('http://127.0.0.1:'+$fixed.port+'/v1');serverArguments=$arguments;
                contextSize=[int]$fixed.contextSize;memoryPreflight=$memory;catalogSha256=$catalogSha;engineSha256=$engineSha}
            return Invoke-FastLlmCpuReferenceLabSupervisor -Plan $plan -LabRunRoot $LabRunRoot -LoadTimeoutSeconds $LoadTimeoutSeconds
        }finally{$labLock.Dispose()}
    }finally{$artifactLock.Dispose()}
}

function Invoke-FastLlmCpuReferenceLabSupervisor {
    param($Plan,[string]$LabRunRoot,[int]$LoadTimeoutSeconds=1200,[int]$Port=0,[scriptblock]$OwnerCheck=$null)
    $fixed=Get-FastLlmCpuReferenceFixed
    if($Port -le 0){$Port=[int]$fixed.port}
    Initialize-FastLlmProcessHost
    $state=[ordered]@{schemaVersion=1;kind=$fixed.stateKind;runId=[Guid]::NewGuid().ToString('N');phase='lab-loading';
        updatedAt=(Get-Date).ToUniversalTime().ToString('o');endpoint=$Plan.endpoint;modelId=$Plan.model.id;
        modelSha256=$Plan.model.sha256;engineVersion=$fixed.engineVersion;catalogSha256=$Plan.catalogSha256;engineSha256=$Plan.engineSha256;
        recipe=[ordered]@{backend='Vulkan-engine-cpu-placement';contextSize=$Plan.contextSize;slots=1;device='none';
            gpuLayers=0;fitMode='off';opOffload=$false;kvOffload=$false;cacheTypeK=$Plan.model.cacheTypeK;cacheTypeV=$Plan.model.cacheTypeV;
            flashAttention='auto';speculation='none';splitMode='none';catalogSha256=$Plan.catalogSha256;
            engineSha256=$Plan.engineSha256;
            requestedArguments=@($Plan.serverArguments | ForEach-Object {if($_ -ceq $Plan.modelPath){'<verified-model>'}else{$_}});
            configurationIsolation='empty-per-run-config-roots-and-targeted-environment-sanitization'};
        memoryPreflight=$Plan.memoryPreflight;placement=$null;placementRefusal=$null;startupDiagnostics=$null;canary=$null;processIdentity=$null;
        experimental=$true;performanceQualified=$false;physicalResidencyVerified=$false;failureCode=$null}
    $stateRoot=Get-FastLlmStateRoot -InstallRoot $LabRunRoot -Create
    $stopPath=Join-FastLlmContainedPath -Root $stateRoot -Child ('stop-'+$state.runId)
    $sandbox=New-FastLlmRuntimeSandbox -InstallRoot $LabRunRoot
    $child=New-Object Bitworks.FastLlm.ProcessHost
    $baseUrl='http://127.0.0.1:'+$Port
    try{
        $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,$Port)
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
            if($child.Process.HasExited){throw 'CPU reference server exited before readiness.'}
            try{$health=Invoke-FastLlmHttp -BaseUrl $baseUrl -Path '/health' -TimeoutMs 1000
                $healthy=$health.Status -eq 200 -and (ConvertFrom-Json $health.Body).status -eq 'ok'}catch{$healthy=$false}
            if($healthy){break}
            Start-Sleep -Milliseconds 200
        }
        if(-not $healthy){throw 'CPU reference model-load readiness deadline exceeded.'}
        $startupText=$child.FreezeStartupDiagnostics()
        $state.startupDiagnostics=ConvertFrom-FastLlmStartupDiagnostics -Text $startupText -Overflow $child.StartupDiagnosticsOverflow -RequestedFlashAttention 'auto'
        $state.phase='lab-checking';$state.updatedAt=(Get-Date).ToUniversalTime().ToString('o')
        Write-FastLlmState -InstallRoot $LabRunRoot -State $state
        # The lab's own child must own the listener before anything is verified or requested.
        if($null -eq $OwnerCheck){Assert-FastLlmCpuReferenceListenerOwner -ProcessId ([int]$child.Process.Id) -Port $Port}
        else{& $OwnerCheck ([int]$child.Process.Id) $Port}
        # Placement is verified before any inference request. Failure throws; the finally block stops the child.
        $placementText=$child.PlacementSnapshot();$outputText=$child.Snapshot()
        try{
            $state.placement=ConvertFrom-FastLlmCpuReferencePlacementLog -PlacementText $placementText -StartupText $startupText `
                -OutputText $outputText -PlacementOverflow $child.PlacementOverflow -StartupOverflow $child.StartupDiagnosticsOverflow `
                -OutputTruncated $child.OutputTruncated -CpuBufferLikeLines $child.CpuBufferLikeLines `
                -SelectedDeviceLikeLines $child.SelectedDeviceLikeLines
        }catch{
            $reason=([string]$_.Exception.Message -replace '[\x00-\x1f\x7f]',' ')
            if($reason.Length -gt 200){$reason=$reason.Substring(0,200)}
            $state.placementRefusal=[ordered]@{reason=$reason;summary=(Get-FastLlmCpuReferencePlacementSummary -PlacementText $placementText `
                -StartupText $startupText -OutputText $outputText -PlacementOverflow $child.PlacementOverflow `
                -StartupOverflow $child.StartupDiagnosticsOverflow -OutputTruncated $child.OutputTruncated `
                -SelectedDeviceLikeLines $child.SelectedDeviceLikeLines)}
            throw
        }
        $state.canary=Test-FastLlmCpuReferenceApiCanary -BaseUrl $baseUrl -ModelId $Plan.model.id -ContextSize $Plan.contextSize
        if($child.Process.HasExited){throw 'CPU reference server exited during API canary.'}
        $child.DiscardOutput()
        $state.phase='lab-ready';$state.updatedAt=(Get-Date).ToUniversalTime().ToString('o')
        Write-FastLlmState -InstallRoot $LabRunRoot -State $state
        Write-Host "CPU reference lab ready: $($Plan.endpoint). This is not a fit, residency, quality or performance approval."
        while(-not $child.Process.WaitForExit(250)){
            if(Test-Path -LiteralPath $stopPath){$state.phase='lab-stopped';return 0}
        }
        if($child.Process.ExitCode -ne 0){throw 'CPU reference server exited unexpectedly after readiness.'}
        $state.phase='lab-stopped';return 0
    }catch{$state.phase='lab-failed';$state.failureCode='startup-or-placement-check-failed';throw}
    finally{
        try{$child.Dispose()}finally{
            try{$state.updatedAt=(Get-Date).ToUniversalTime().ToString('o');Write-FastLlmState -InstallRoot $LabRunRoot -State $state}
            finally{try{Remove-FastLlmRuntimeSandbox $sandbox}finally{if(Test-Path -LiteralPath $stopPath){Remove-Item -LiteralPath $stopPath -Force}}}
        }
    }
}
