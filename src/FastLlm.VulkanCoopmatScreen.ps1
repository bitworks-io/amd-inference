# Private, synthetic llama-bench screen. Dot-source inside the imported FastLlm module.
# Pinned b10698 CLI contract: https://github.com/ggml-org/llama.cpp/blob/b10698/tools/llama-bench/README.md
# Coopmat switch: https://github.com/ggml-org/llama.cpp/blob/b10698/ggml/src/ggml-vulkan/ggml-vulkan.cpp
function Assert-FastLlmCoopmatPathAncestors {
    param([string]$Path)
    $current=[IO.Path]::GetFullPath($Path)
    while($current){
        if(Test-Path -LiteralPath $current){
            $item=Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){
                throw 'Private screen path contains a reparse point.'
            }
        }
        $parent=Split-Path -Parent $current
        if(-not $parent -or $parent -ceq $current){break}
        $current=$parent
    }
}

function Set-FastLlmCoopmatChildEnvironment {
    param($Info,$Sandbox,[string]$EngineDirectory,[ValidateSet('default','disable-coopmat')][string]$Variant)
    foreach($name in @($Info.EnvironmentVariables.Keys)) {
        if((Test-FastLlmEnvironmentNameRequiresClearing -Name $name) -or
           $name -like 'VULKAN_*' -or $name -like 'AMD_VULKAN_*' -or
           $name -in @('VK_ICD_FILENAMES','VK_DRIVER_FILES','GPU_DEVICE_ORDINAL')) {
            $Info.EnvironmentVariables.Remove($name)
        }
    }
    $Info.EnvironmentVariables['APPDATA']=$Sandbox.appData
    $Info.EnvironmentVariables['PROGRAMDATA']=$Sandbox.programData
    $Info.EnvironmentVariables['PATH']="$EngineDirectory;$env:SystemRoot\System32;$env:SystemRoot"
    if($Variant -ceq 'disable-coopmat') { $Info.EnvironmentVariables['GGML_VK_DISABLE_COOPMAT']='1' }
}

function ConvertFrom-FastLlmCoopmatBenchRows {
    param([string]$Text,[string]$ExpectedModelPath,[string]$Workload)
    if($Text.Length -gt 262144){throw 'Synthetic bench output exceeds the bounded capture.'}
    $rows=@()
    foreach($line in ($Text -split "`r?`n")) {
        $candidate=$line.Trim()
        if(-not $candidate.StartsWith('{')){continue}
        if($candidate.Length -ge 8192 -or -not $candidate.EndsWith('}')){throw 'Synthetic bench JSONL row is truncated or malformed.'}
        try{$row=ConvertFrom-Json -InputObject $candidate -ErrorAction Stop}catch{throw 'Synthetic bench JSONL row is malformed.'}
        $rows+=,$row
    }
    $validKeys=@(if($Workload -ceq 'pp'){'512/0/0';'4096/0/0'}else{'0/128/4096'})
    if($rows.Count -ne $validKeys.Count){throw 'Synthetic bench row count is missing or ambiguous.'}
    $normalized=@()
    foreach($row in $rows){
        foreach($field in @('n_prompt','n_gen','n_depth','n_gpu_layers','n_batch','n_ubatch','fit_target','fit_min_ctx','n_cpu_moe','avg_ns','stddev_ns','avg_ts','stddev_ts')){
            $property=$row.PSObject.Properties[$field]
            if(-not $property -or $null -eq $property.Value -or $property.Value -isnot [ValueType] -or $property.Value -is [bool]){
                throw 'Synthetic bench numeric field is absent or has the wrong type.'
            }
            $numeric=[double]$property.Value
            if([double]::IsNaN($numeric) -or [double]::IsInfinity($numeric) -or $numeric -lt 0){
                throw 'Synthetic bench numeric field is invalid.'
            }
        }
        foreach($field in @('n_prompt','n_gen','n_depth','n_gpu_layers','n_batch','n_ubatch','fit_target','fit_min_ctx','n_cpu_moe')){
            $integer=[double]$row.$field
            if($integer -gt [int]::MaxValue -or $integer -ne [Math]::Truncate($integer)){
                throw 'Synthetic bench recipe field must be an exact bounded integer.'
            }
        }
        $triple=@([int]$row.n_prompt,[int]$row.n_gen,[int]$row.n_depth)
        $key=$triple -join '/'
        if($key -notin $validKeys -or $key -in @($normalized|ForEach-Object {$_.workloadKey})){
            throw 'Synthetic bench output contains mixed or duplicate workload rows.'
        }
        if([string]$row.model_filename -cne $ExpectedModelPath -or
           [string]$row.devices -cne 'Vulkan0' -or [int]$row.n_gpu_layers -ne 999 -or
           [int]$row.n_batch -ne 2048 -or [int]$row.n_ubatch -ne 512 -or
           [string]$row.type_k -cne 'f16' -or [string]$row.type_v -cne 'f16' -or
           [string]$row.split_mode -cne 'none' -or [int]$row.fit_target -ne 0 -or
           [int]$row.fit_min_ctx -ne 0 -or [int]$row.n_cpu_moe -ne 0 -or
           [string]$row.backends -cnotmatch 'Vulkan'){
            throw 'Synthetic bench row does not match the reviewed fixed recipe.'
        }
        $samples=@($row.samples_ts)
        if($samples.Count -ne 5 -or @($row.samples_ns).Count -ne 5){throw 'Synthetic bench repetition count is invalid.'}
        foreach($value in @($row.samples_ns)){
            if($null -eq $value -or $value -isnot [ValueType] -or $value -is [bool] -or [double]$value -le 0){
                throw 'Synthetic bench latency sample is invalid.'
            }
        }
        foreach($value in @($row.avg_ts,$row.stddev_ts)+$samples){
            if($null -eq $value -or $value -isnot [ValueType]){throw 'Synthetic bench throughput is not numeric.'}
            $number=[double]$value
            if([double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt 0){throw 'Synthetic bench throughput is invalid.'}
        }
        if([double]$row.avg_ts -le 0){throw 'Synthetic bench average throughput must be positive.'}
        $normalized+= [pscustomobject]@{workloadKey=$key;promptTokens=$triple[0];generatedTokens=$triple[1];depthTokens=$triple[2];averageTokensPerSecond=[double]$row.avg_ts;stddevTokensPerSecond=[double]$row.stddev_ts;samplesTokensPerSecond=@($samples|ForEach-Object {[double]$_})}
    }
    return $normalized
}

function Get-FastLlmCoopmatPlacementFailureSummary {
    param([string]$Placement,[bool]$Overflow,[int]$CpuBufferLikeLines)
    # ProcessHost.PlacementSnapshot contains only normalized loader numerics/devices.
    # Re-parse an even narrower allowlist here; never echo a raw native line or path.
    $rows=@()
    foreach($line in @($Placement -split "`r?`n" | Where-Object {$_})){
        if($rows.Count -ge 8){break}
        if($line -cmatch '^load_tensors: offloaded ([0-9]{1,3})/([0-9]{1,3}) layers to GPU$'){
            $rows+=('offload={0}/{1}' -f $Matches[1],$Matches[2])
        }elseif($line -cmatch '^load_tensors: (Vulkan[0-9]{1,2}|ROCm[0-9]{1,2}|CPU|CPU_Mapped) model buffer size = ([0-9]{1,8}(?:\.[0-9]{1,4})?) MiB$'){
            $rows+=('buffer={0}:{1}MiB' -f $Matches[1],$Matches[2])
        }else{$rows+='unparsed-normalized-row'}
    }
    $reason=if($Overflow){'placement-overflow'}elseif($CpuBufferLikeLines -ne 0){'host-model-buffer'}else{'unknown-placement-rejection'}
    return ('reason={0}; overflow={1}; cpuBufferLikeLines={2}; rows=[{3}]' -f
        $reason,([string]$Overflow).ToLowerInvariant(),$CpuBufferLikeLines,($rows -join ','))
}

function ConvertFrom-FastLlmCoopmatPlacement {
    param([string]$Placement,[string]$GeneralOutput,[int]$CpuBufferLikeLines,
          [bool]$Overflow,[bool]$AllowHostModelBuffer)
    if($Overflow){throw 'Synthetic bench placement capture overflowed.'}
    if($Placement.Length -gt 4096 -or $GeneralOutput.Length -gt 262144){
        throw 'Synthetic bench placement evidence exceeds bounds.'
    }
    $lines=@($Placement -split "`r?`n" | Where-Object {$_})
    if($lines.Count -lt 2 -or $lines.Count -gt 3){throw 'Synthetic bench normalized placement row count is invalid.'}
    $cpuRows=@()
    foreach($line in $lines){
        if($line -cmatch '^load_tensors: (CPU|CPU_Mapped) model buffer size = ([0-9]{1,8}(?:\.[0-9]{1,4})?) MiB$'){
            $size=[double]0
            if(-not [double]::TryParse($Matches[2],[Globalization.NumberStyles]::AllowDecimalPoint,
                [Globalization.CultureInfo]::InvariantCulture,[ref]$size) -or $size -le 0 -or $size -gt 1024){
                throw 'Synthetic bench host model-buffer size is invalid or exceeds the private 1024 MiB bound.'
            }
            $cpuRows+= [pscustomobject]@{device=$Matches[1];sizeMiB=$size}
        }elseif($line -cnotmatch '^load_tensors: offloaded [0-9]{1,3}/[0-9]{1,3} layers to GPU$' -and
                $line -cnotmatch '^load_tensors: Vulkan0 model buffer size = [0-9]{1,8}(?:\.[0-9]{1,4})? MiB$'){
            throw 'Synthetic bench normalized placement has an unexpected row.'
        }
    }
    # ProcessHost counts every recognized CPU/CPU_Mapped model-buffer line, even
    # when a malformed numeric value prevents a normalized placement row.
    # The raw general output is inspected only for unrecognized CPU buffer names;
    # none of that output is copied to the report or error.
    $rawCpuRows=[regex]::Matches($GeneralOutput,'(?i)load_tensors:\s+CPU[^\r\n]{0,128}model buffer size\b')
    if($rawCpuRows.Count -ne $CpuBufferLikeLines -or $cpuRows.Count -ne $CpuBufferLikeLines){
        throw 'Synthetic bench CPU model-buffer evidence is missing, malformed, or inconsistent.'
    }
    if($AllowHostModelBuffer){
        if($cpuRows.Count -ne 1){throw 'Opt-in host model-buffer experiment requires exactly one bounded CPU/CPU_Mapped buffer.'}
    }elseif($cpuRows.Count -ne 0){
        throw 'Default synthetic screen rejects any host model buffer.'
    }
    $placementEvidence=ConvertFrom-FastLlmPlacementLog -Text $Placement -Devices @('Vulkan0')
    if([int]$placementEvidence.reportedLayers -ne 66 -or [int]$placementEvidence.totalLayers -ne 66 -or
       @($placementEvidence.modelBufferMiB).Count -ne 1){
        throw 'Synthetic bench did not report exactly 66/66 layers and one Vulkan0 model buffer.'
    }
    $classification=if($cpuRows.Count){'all-reported-layers-with-host-model-buffer'}else{'all-reported-layers-no-host-model-buffer'}
    return [pscustomobject]@{placement=$placementEvidence;hostModelBuffers=@($cpuRows);
        placementClassification=$classification;allowHostModelBuffer=$AllowHostModelBuffer;
        cpuBufferLikeLines=$CpuBufferLikeLines;physicalResidencyVerified=$false;
        allWeightsOnGpuVerified=$false;allOperationsOnGpuVerified=$false}
}

function Invoke-FastLlmCoopmatChild {
    param([string]$Executable,[string[]]$Arguments,[string]$InstallRoot,[string]$EngineDirectory,
          [ValidateSet('default','disable-coopmat')][string]$Variant,[int]$TimeoutSeconds=900)
    Initialize-FastLlmProcessHost
    $sandbox=New-FastLlmRuntimeSandbox -InstallRoot $InstallRoot
    $child=New-Object Bitworks.FastLlm.ProcessHost
    try{
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=$Executable
        $info.Arguments=Join-FastLlmProcessArguments -Arguments $Arguments
        $info.WorkingDirectory=$EngineDirectory
        Set-FastLlmCoopmatChildEnvironment -Info $info -Sandbox $sandbox -EngineDirectory $EngineDirectory -Variant $Variant
        $started=(Get-Date).ToUniversalTime().ToString('o')
        $child.Start($info)
        $clock=[Diagnostics.Stopwatch]::StartNew()
        while(-not $child.Process.HasExited -or -not $child.OutputCompleted){
            if($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds){throw 'Synthetic bench child exceeded its deadline or output did not complete.'}
            Start-Sleep -Milliseconds 100
        }
        if($child.OutputTruncated){throw 'Synthetic bench child output was truncated.'}
        if($child.Process.ExitCode -ne 0){throw 'Synthetic bench child exited unsuccessfully.'}
        return [pscustomobject]@{text=$child.Snapshot();placement=$child.PlacementSnapshot();
            cpuBufferLikeLines=$child.CpuBufferLikeLines;placementOverflow=$child.PlacementOverflow;
            startedAt=$started;endedAt=(Get-Date).ToUniversalTime().ToString('o')}
    }finally{
        # Return only copied evidence; ProcessHost is disposed before the caller consumes it.
        $child.Dispose()
        Remove-FastLlmRuntimeSandbox -Sandbox $sandbox
    }
}

function Invoke-FastLlmVulkanCoopmatScreen {
    param([Parameter(Mandatory=$true)][string]$InstallRoot,[Parameter(Mandatory=$true)][string]$OutputPath,
          [Parameter(Mandatory=$true)][ValidateSet('default','disable-coopmat')][string]$Variant,
          [switch]$AllowHostModelBuffer)
    if($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess){throw 'Private screen requires 64-bit Windows standard-user PowerShell.'}
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Private screen refuses elevation.'}
    $sourcePath=Join-Path $PSScriptRoot 'FastLlm.VulkanCoopmatScreen.ps1'
    $sourceSha=(Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $repo=Split-Path $PSScriptRoot -Parent
    $toolPath=Join-Path $repo 'tools/vulkan-coopmat-screen.ps1'
    $modulePath=Join-Path $PSScriptRoot 'FastLlm.psm1'
    $hostPath=Join-Path $PSScriptRoot 'ProcessHost.cs'
    $toolSha=(Get-FileHash -LiteralPath $toolPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $moduleSha=(Get-FileHash -LiteralPath $modulePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $hostSha=(Get-FileHash -LiteralPath $hostPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $catalogPath=Join-Path $repo 'config/catalog.json'
    $catalogSha=(Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if($catalogSha -cne '65b8f2f9ca340dab273274086aba9e8f01cb14a2b8cf4bb65c5ed5f6e779caa6'){
        throw 'Private screen catalog pin changed; re-review before use.'
    }
    Assert-FastLlmWindowsPrerequisites
    $catalog=Get-FastLlmCatalog -CatalogPath $catalogPath
    if([string]$catalog.engine.version -cne 'b10698' -or
       [string]$catalog.engine.assets.vulkan.sha256 -cne '31e2fe70d4864a4ae6a4e7d8e102ee9203ba18963077e7727c54f9bd6ae3bea5'){
        throw 'Private screen requires the reviewed b10698 Vulkan archive.'
    }
    $model=@($catalog.models|Where-Object {[string]$_.id -ceq 'qwen3.8-27b-ud-q4-k-m'})
    if($model.Count -ne 1){throw 'Private screen exact model is unavailable.'}
    $model=$model[0]
    $root=[IO.Path]::GetFullPath($InstallRoot)
    $output=[IO.Path]::GetFullPath($OutputPath)
    Assert-FastLlmCoopmatPathAncestors -Path $root
    Assert-FastLlmCoopmatPathAncestors -Path $output
    if(Test-Path -LiteralPath $output){throw 'Private screen output path already exists.'}
    $outputParent=Split-Path -Parent $output
    if(-not (Test-Path -LiteralPath $outputParent -PathType Container)){throw 'Private screen output parent is absent.'}
    $parentItem=Get-Item -LiteralPath $outputParent -Force
    if(($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Private screen output parent is a reparse point.'}
    $normal=Get-FastLlmStatus -InstallRoot $root
    if($normal.active){throw 'Stop the normal inference service before synthetic GPU screening.'}
    $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,8080)
    try{$listener.Server.ExclusiveAddressUse=$true;$listener.Start()}finally{$listener.Stop()}
    $lock=Enter-FastLlmOperation -InstallRoot $root
    try{
        if(-not (Test-FastLlmEngineInstallation -InstallRoot $root -EngineVersion 'b10698' -BackendKey 'vulkan' -Asset $catalog.engine.assets.vulkan)){
            throw 'Pinned Vulkan engine exact file set is not installed.'
        }
        $bench=Get-FastLlmEngineExecutable -InstallRoot $root -EngineVersion 'b10698' -BackendKey 'vulkan' -EntryPoint 'llama-bench.exe'
        $engineDirectory=Split-Path -Parent $bench
        $modelPath=Join-FastLlmContainedPath -Root (Join-FastLlmContainedPath -Root $root -Child 'models') -Child ([string]$model.file)
        Assert-FastLlmCoopmatPathAncestors -Path $modelPath
        $modelItem=Get-Item -LiteralPath $modelPath -Force -ErrorAction Stop
        if($modelItem.PSIsContainer -or ($modelItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
           [int64]$modelItem.Length -ne [int64]$model.sizeBytes -or
           -not (Test-FastLlmFileHash -Path $modelPath -Sha256 ([string]$model.sha256))){
            throw 'Exact cached model size/hash verification failed.'
        }
        if(-not (Test-FastLlmOffloadExactConsent -Model $model -ArtifactRoot $root)){
            throw 'Exact existing model consent is required; this screen never accepts a license.'
        }
        $hardware=Get-FastLlmHardware -CatalogPath $catalogPath -InstallRoot $root
        $adapters=@($hardware.adapters|Where-Object {$_.device -ceq 'Vulkan0'})
        if($adapters.Count -ne 1 -or @($hardware.adapters).Count -ne 1){throw 'Private screen requires exactly one eligible Vulkan0 adapter.'}
        if([int64]$adapters[0].freeVramMiB -lt [int64]$model.requiredFreeVramMiB){throw 'Fresh reported free VRAM is below catalog estimate.'}
        $help=Invoke-FastLlmCoopmatChild -Executable $bench -Arguments @('--help') -InstallRoot $root -EngineDirectory $engineDirectory -Variant $Variant -TimeoutSeconds 20
        foreach($flag in @('--offline','-v','-m','-p','-n','-d','-b','-ub','-ctk','-ctv','-ngl','-sm','-fa','-dev','-r','-o')){
            if($help.text -cnotmatch ('(?m)(?<![A-Za-z0-9])'+[regex]::Escape($flag)+'(?=[,\s])')){throw 'Pinned llama-bench does not advertise a required fixed option.'}
        }
        # b10698 llama-bench calls llama_log_set(null) without -v, hiding placement.
        $common=@('--offline','-v','-m',$modelPath,'-b','2048','-ub','512','-ctk','f16','-ctv','f16','-ngl','999','-sm','none','-fa','auto','-dev','Vulkan0','-r','5','-o','jsonl')
        $recipes=@(
            [pscustomobject]@{name='pp';arguments=@($common+@('-p','512,4096','-n','0','-d','0'))},
            [pscustomobject]@{name='tg';arguments=@($common+@('-p','0','-n','128','-d','4096'))}
        )
        $results=@()
        foreach($recipe in $recipes){
            if(-not (Test-FastLlmEngineInstallation -InstallRoot $root -EngineVersion 'b10698' -BackendKey 'vulkan' -Asset $catalog.engine.assets.vulkan) -or
               -not (Test-FastLlmFileHash -Path $modelPath -Sha256 ([string]$model.sha256)) -or
               (Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $catalogSha -or
               (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $sourceSha -or
               (Get-FileHash -LiteralPath $toolPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $toolSha -or
               (Get-FileHash -LiteralPath $modulePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $moduleSha -or
               (Get-FileHash -LiteralPath $hostPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $hostSha){
                throw 'Private screen source, catalog, engine, or model changed before child launch.'
            }
            $run=Invoke-FastLlmCoopmatChild -Executable $bench -Arguments $recipe.arguments -InstallRoot $root -EngineDirectory $engineDirectory -Variant $Variant
            # ProcessHost has already copied bounded output and disposed its job.
            if($run.placementOverflow -or ($run.cpuBufferLikeLines -ne 0 -and -not $AllowHostModelBuffer)){
                $safeSummary=Get-FastLlmCoopmatPlacementFailureSummary -Placement $run.placement -Overflow ([bool]$run.placementOverflow) -CpuBufferLikeLines ([int]$run.cpuBufferLikeLines)
                throw "Synthetic bench placement rejected ($($recipe.name)): $safeSummary"
            }
            $placement=ConvertFrom-FastLlmCoopmatPlacement -Placement $run.placement -GeneralOutput $run.text -CpuBufferLikeLines ([int]$run.cpuBufferLikeLines) -Overflow ([bool]$run.placementOverflow) -AllowHostModelBuffer ([bool]$AllowHostModelBuffer)
            $rows=ConvertFrom-FastLlmCoopmatBenchRows -Text $run.text -ExpectedModelPath $modelPath -Workload $recipe.name
            $redactedArgs=@($recipe.arguments|ForEach-Object {if($_ -ceq $modelPath){'<verified-model>'}else{$_}})
            $results+= [pscustomobject]@{name=$recipe.name;startedAt=$run.startedAt;endedAt=$run.endedAt;
                argv=$redactedArgs;environmentOverride=if($Variant -ceq 'disable-coopmat'){@{GGML_VK_DISABLE_COOPMAT='1'}}else{@{}};
                placement=$placement.placement;placementClassification=$placement.placementClassification;
                allowHostModelBuffer=$placement.allowHostModelBuffer;hostModelBuffers=@($placement.hostModelBuffers);
                cpuBufferLikeLines=$placement.cpuBufferLikeLines;allWeightsOnGpuVerified=$false;
                allOperationsOnGpuVerified=$false;physicalResidencyVerified=$false;rows=@($rows)}
        }
        if((Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $sourceSha -or
           (Get-FileHash -LiteralPath $toolPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $toolSha -or
           (Get-FileHash -LiteralPath $modulePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $moduleSha -or
           (Get-FileHash -LiteralPath $hostPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $hostSha -or
           (Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $catalogSha -or
           -not (Test-FastLlmEngineInstallation -InstallRoot $root -EngineVersion 'b10698' -BackendKey 'vulkan' -Asset $catalog.engine.assets.vulkan) -or
           -not (Test-FastLlmFileHash -Path $modelPath -Sha256 ([string]$model.sha256))){throw 'Private screen provenance changed during run.'}
        $manifest=@($catalog.engine.assets.vulkan.manifest)
        $implPath=Join-Path $engineDirectory 'llama-bench-impl.dll'
        $report=[ordered]@{schemaVersion=2;resultKind='native-windows-llama-bench-vulkan-coopmat-screen-v2';
            experimental=$true;synthetic=$true;apiPerformance=$false;performanceQualified=$false;
            modelFitQualified=$false;physicalResidencyVerified=$false;servingDeviceBinding=$false;
            allWeightsOnGpuVerified=$false;allOperationsOnGpuVerified=$false;
            allowHostModelBuffer=[bool]$AllowHostModelBuffer;hostModelBufferLimitMiB=1024;
            variant=$Variant;sourceSha256=$sourceSha;toolSha256=$toolSha;
            moduleSha256=$moduleSha;processHostSha256=$hostSha;
            catalogSha256=$catalogSha;
            engineVersion='b10698';engineArchiveSha256=$catalog.engine.assets.vulkan.sha256;
            engineManifestFileCount=$manifest.Count;benchExeSha256=(Get-FileHash -LiteralPath $bench -Algorithm SHA256).Hash.ToLowerInvariant();
            benchImplSha256=(Get-FileHash -LiteralPath $implPath -Algorithm SHA256).Hash.ToLowerInvariant();
            modelId=$model.id;modelSha256=$model.sha256;modelSizeBytes=$model.sizeBytes;
            probe=[ordered]@{device='Vulkan0';name=$adapters[0].name;reportedFreeVramMiB=$adapters[0].freeVramMiB;authoritativeIdentity=$false};
            recipe=[ordered]@{fitMode='off';gpuLayerRequest=999;expectedReportedLayers=66;repetitions=5;
                outputFormat='jsonl';promptProcessingTokens=@(512,4096);generationTokens=128;generationDepthTokens=4096};
            isolation='empty-config-roots-targeted-scrub-plus-vendor-overrides';
            workloadNote='Synthetic random token IDs; no tokenization, sampling, chat API, semantic canary, or ctx32768 equivalence.';
            results=$results;completedAt=(Get-Date).ToUniversalTime().ToString('o')}
        $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $report -Depth 12 -Compress))
        if($bytes.Length -gt 65536){throw 'Private screen report exceeds its size limit.'}
        $stream=[IO.File]::Open($output,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush()}finally{$stream.Dispose()}
    }finally{$lock.Dispose()}
}
