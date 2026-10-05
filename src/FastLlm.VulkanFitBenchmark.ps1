# Private Vulkan experiment only. Never emits the normal benchmark result kind.
function Assert-FastLlmVulkanFitBenchmarkArgument {
    param([object[]]$Arguments,[string]$Name,[string]$Value)
    $hits=@(for($i=0;$i -lt $Arguments.Count;$i++){if([string]$Arguments[$i] -ceq $Name){$i}})
    return $hits.Count -eq 1 -and $hits[0]+1 -lt $Arguments.Count -and [string]$Arguments[$hits[0]+1] -ceq $Value
}

function Get-FastLlmVulkanFitBenchmarkBinding {
    param($State)
    $bound=[ordered]@{kind=$State.kind;runId=$State.runId;processIdentity=$State.processIdentity;
        modelId=$State.modelId;modelSha256=$State.modelSha256;engineVersion=$State.engineVersion;
        engineSha256=$State.engineSha256;catalogSha256=$State.catalogSha256;trialSourceSha256=$State.trialSourceSha256;endpoint=$State.endpoint;
        recipe=$State.recipe;selectedDevice=$State.selectedDevice;allowHostModelBuffer=$State.allowHostModelBuffer;
        placementClassification=$State.placementClassification;allWeightsOnGpuVerified=$State.allWeightsOnGpuVerified;
        allOperationsOnGpuVerified=$State.allOperationsOnGpuVerified;cpuInputEvidence=$State.cpuInputEvidence;
        placement=$State.placement;placementCounters=$State.placementCounters;
        placementEvidence=$State.placementEvidence;startupDiagnostics=$State.startupDiagnostics;canary=$State.canary}
    $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $bound -Depth 16 -Compress))
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}
    finally{$sha.Dispose()}
}

function Assert-FastLlmVulkanFitBenchmarkState {
    param($State,[string]$ExpectedBinding)
    if($State.active -isnot [bool] -or -not $State.active -or [int]$State.schemaVersion -ne 1 -or
       $State.kind -cne 'fastllm-vulkan-fit-b10698-private-trial' -or $State.phase -cne 'vulkan-fit-ready' -or
       $State.endpoint -cne 'http://127.0.0.1:18083/v1' -or $State.experimental -isnot [bool] -or -not $State.experimental -or
       $State.performanceQualified -ne $false -or $State.physicalResidencyVerified -ne $false -or
       $State.dynamicClosureVerified -ne $false -or $State.semanticCorrectnessQualified -ne $false -or
       $State.allWeightsOnGpuVerified -ne $false -or $State.allOperationsOnGpuVerified -ne $false -or
       $State.cpuInputEvidence -cne 'not-attested' -or $State.allowHostModelBuffer -isnot [bool] -or
       $State.recipe.allowHostModelBuffer -ne $State.allowHostModelBuffer -or
       $State.runId -cnotmatch '^[0-9a-f]{32}$' -or [int]$State.processIdentity.pid -le 0 -or
       [long]$State.processIdentity.startUtcTicks -le 0 -or
       $State.modelId -cne 'qwen3.8-27b-ud-q4-k-m' -or
       $State.modelSha256 -cne '322e194ff79741c7baa497c240f677f54b201b0efab44ca8e50f122b39123482' -or
       $State.engineVersion -cne 'b10698' -or $State.engineSha256 -cnotmatch '^[0-9a-f]{64}$' -or
       $State.catalogSha256 -cnotmatch '^[0-9a-f]{64}$' -or $State.trialSourceSha256 -cnotmatch '^[0-9a-f]{64}$' -or
       $State.recipe.backend -cne 'Vulkan' -or $State.recipe.device -cne 'Vulkan0' -or
       $State.selectedDevice.device -cne 'Vulkan0' -or [string]::IsNullOrWhiteSpace([string]$State.selectedDevice.name) -or
       [int]$State.recipe.contextSize -ne 32768 -or [int]$State.recipe.slots -ne 1 -or
       $State.recipe.gpuLayers -cne 'all' -or $State.recipe.fitMode -cnotin @('on','off') -or
       [int]$State.recipe.fitTargetMiB -ne 768 -or $State.recipe.splitMode -cne 'none' -or
       $State.recipe.speculation -cne 'none' -or $State.recipe.flashAttention -cne 'auto' -or
       $State.recipe.cacheTypeK -cne 'f16' -or $State.recipe.cacheTypeV -cne 'f16'){
        throw 'Exact private Vulkan fit trial is not Ready or its fixed recipe/identity differs.'
    }
    $expected=@(New-FastLlmVulkanFitArguments -ModelPath '<verified-model>' -ModelId $State.modelId -FitMode $State.recipe.fitMode)
    $actual=@($State.recipe.requestedArguments)
    if($actual.Count -ne $expected.Count){throw 'Vulkan fit launch argument count differs from the fixed recipe.'}
    for($i=0;$i -lt $expected.Count;$i++){
        if([string]$actual[$i] -cne [string]$expected[$i]){throw 'Vulkan fit launch arguments differ from the fixed recipe.'}
    }
    if([int]$State.placement.reportedLayers -ne 66 -or [int]$State.placement.totalLayers -ne 66 -or
       $State.placement.reportedAllLayers -ne $true -or @($State.placement.devices).Count -ne 1 -or
       $State.placement.devices[0] -cne 'Vulkan0' -or @($State.placement.modelBufferMiB).Count -ne 1 -or
       $State.placement.modelBufferMiB[0].device -cne 'Vulkan0' -or
       [double]$State.placement.modelBufferMiB[0].sizeMiB -le 0 -or
       [double]::IsNaN([double]$State.placement.modelBufferMiB[0].sizeMiB) -or
       [double]::IsInfinity([double]$State.placement.modelBufferMiB[0].sizeMiB) -or
       $State.placement.physicalResidencyVerified -ne $false -or
       $State.placementEvidence.status -cne 'captured' -or
       [int]$State.placementEvidence.reportedGpuLayers -ne 66 -or
       [int]$State.placementEvidence.reportedTotalLayers -ne 66 -or
       $State.placementEvidence.gpuModelBuffer.device -cne 'Vulkan0' -or
       [double]$State.placementEvidence.gpuModelBuffer.sizeMiB -le 0 -or
       [double]::IsNaN([double]$State.placementEvidence.gpuModelBuffer.sizeMiB) -or
       [double]::IsInfinity([double]$State.placementEvidence.gpuModelBuffer.sizeMiB) -or
       [double]$State.placementEvidence.gpuModelBuffer.sizeMiB -ne [double]$State.placement.modelBufferMiB[0].sizeMiB -or
       $State.placementEvidence.physicalResidencyVerified -ne $false -or
       $State.placementEvidence.allWeightsOnGpuVerified -ne $false -or
       $State.placementEvidence.allOperationsOnGpuVerified -ne $false -or
       [int]$State.placementCounters.offloadLike -ne 1 -or
       [int]$State.placementCounters.bufferLike -ne $(if($null -eq $State.placementEvidence.hostModelBuffer){1}else{2}) -or
       [int]$State.placementCounters.captured -ne $(if($null -eq $State.placementEvidence.hostModelBuffer){2}else{3}) -or
       [int]$State.placementCounters.dropped -ne 0 -or
       $State.startupDiagnostics.physicalResidencyVerified -ne $false -or
       $State.canary.modelIdentity -ne $true -or $State.canary.repeatableToken -ne $true -or
       $State.canary.synchronousChat -ne $true -or $State.canary.streaming -ne $true -or
       [int]$State.canary.effectiveContext -ne 32768 -or
       $State.canary.semanticCorrectnessQualified -ne $false){
        throw 'Vulkan fit placement or API evidence is incomplete or inconsistent.'
    }
    $hostBuffer=$State.placementEvidence.hostModelBuffer
    if($null -eq $hostBuffer){
        if($State.placementClassification -cne 'all-reported-layers-no-host-model-buffer' -or
           $State.placementEvidence.classification -cne $State.placementClassification){
            throw 'Vulkan fit host-buffer classification differs from captured evidence.'
        }
    }else{
        if(-not $State.allowHostModelBuffer -or $hostBuffer.device -cne 'CPU_Mapped' -or
           [double]$hostBuffer.sizeMiB -le 0 -or [double]::IsNaN([double]$hostBuffer.sizeMiB) -or
           [double]::IsInfinity([double]$hostBuffer.sizeMiB) -or
           [double]$hostBuffer.sizeMiB -gt 1024.0 -or
           $State.placementClassification -cne 'all-reported-layers-with-host-model-buffer' -or
           $State.placementEvidence.classification -cne $State.placementClassification){
            throw 'Vulkan fit host-buffer classification or opt-in is invalid.'
        }
    }
    $binding=Get-FastLlmVulkanFitBenchmarkBinding $State
    if($ExpectedBinding -and $binding -cne $ExpectedBinding){
        throw 'Vulkan fit run, process, recipe or placement changed during measurement.'
    }
    return $binding
}

function Assert-FastLlmVulkanFitBenchmarkProcess {
    param($State,[switch]$HashExecutable)
    if(-not ('Bitworks.FastLlm.WindowsGpuTelemetry' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'WindowsGpuTelemetry.cs') -ErrorAction Stop}
    $owners=@([Bitworks.FastLlm.WindowsGpuTelemetry]::GetLoopbackListenerOwners(18083))
    if($owners.Count -ne 1 -or [int]$owners[0] -ne [int]$State.processIdentity.pid){throw 'Vulkan fit listener owner differs from the supervised child.'}
    $process=$null
    try{
        $process=[Diagnostics.Process]::GetProcessById([int]$State.processIdentity.pid)
        if($process.HasExited -or $process.ProcessName -cne 'llama-server' -or
           [long]$process.StartTime.ToUniversalTime().Ticks -ne [long]$State.processIdentity.startUtcTicks){throw 'Vulkan fit child process identity changed.'}
        if($HashExecutable){
            if((Get-FileHash -LiteralPath $process.MainModule.FileName -Algorithm SHA256).Hash.ToLowerInvariant() -cne $State.engineSha256){
                throw 'Vulkan fit executable file hash differs from the recorded engine.'
            }
        }
    }finally{if($process){$process.Dispose()}}
}

function Invoke-FastLlmVulkanFitBenchmarkCore {
    param([string]$OutputPath,[scriptblock]$ReadState,[scriptblock]$Request,[scriptblock]$CheckProcess,
          [scriptblock]$CheckExecutable,[int]$DeadlineSeconds=3600)
    if($DeadlineSeconds -lt 1 -or $DeadlineSeconds -gt 3600){throw 'Vulkan fit benchmark deadline outside bound.'}
    $promptLengths=@(512,4096);$generationTokens=128;$repetitions=5
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $sourcePath=Join-Path $PSScriptRoot 'FastLlm.VulkanFitBenchmark.ps1'
    $helperPath=Join-Path $PSScriptRoot 'FastLlm.Benchmark.ps1'
    $responseParserPath=Join-Path $PSScriptRoot 'FastLlm.OffloadBenchmark.ps1'
    $trialPath=Join-Path $PSScriptRoot 'FastLlm.VulkanFitTrial.ps1'
    $sourceHash=(Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $helperHash=(Get-FileHash -LiteralPath $helperPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $responseParserHash=(Get-FileHash -LiteralPath $responseParserPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $trialHash=(Get-FileHash -LiteralPath $trialPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $first=& $ReadState
    $binding=Assert-FastLlmVulkanFitBenchmarkState $first
    if($first.trialSourceSha256 -cne $trialHash){throw 'Vulkan fit trial launch-source hash differs from the measured source.'}
    & $CheckProcess $first;& $CheckExecutable $first
    if(Test-Path -LiteralPath $OutputPath){throw 'Vulkan fit benchmark output already exists.'}
    $corpus=('A local inference system should produce accurate useful answers. Measure speed consistently while preserving model quality. '+[Environment]::NewLine)*([int][Math]::Ceiling(4096/16)+2)
    $remaining=[int][Math]::Floor(($DeadlineSeconds-$timer.Elapsed.TotalSeconds)*1000)
    if($remaining -le 0){throw 'Vulkan fit benchmark deadline exceeded.'}
    $tokenized=& $Request '/tokenize' @{content=$corpus;add_special=$false} ([Math]::Min(30000,$remaining))
    $current=& $ReadState;$null=Assert-FastLlmVulkanFitBenchmarkState $current $binding;& $CheckProcess $current
    if($tokenized.Status -ne 200){throw 'Vulkan fit benchmark tokenization failed.'}
    $tokens=@((ConvertFrom-Json $tokenized.Body).tokens)
    if($tokens.Count -lt 4096 -or $tokens.Count -gt 100000){throw 'Vulkan fit fixed corpus tokenization outside bounds.'}
    $prompts=@{};$digests=@{}
    $artifacts=@(foreach($length in $promptLengths){
        $array=@($tokens[0..($length-1)]);$digest=Get-FastLlmPromptArtifactSha256 -TokenIds $array
        $prompts[$length]=$array;$digests[$length]=$digest
        [pscustomobject]@{requestedPromptTokens=$length;tokenCount=$length;sha256=$digest;format='fastllm-prompt-tokens-v1'}
    })
    $samples=@();$evaluated=@{};$promptOrderByRound=@()
    for($round=0;$round -le $repetitions;$round++){
        $roundOrder=if(($round % 2) -eq 0){@(512,4096)}else{@(4096,512)}
        $promptOrderByRound+= ,$roundOrder
        foreach($length in $roundOrder){
            $current=& $ReadState;$null=Assert-FastLlmVulkanFitBenchmarkState $current $binding;& $CheckProcess $current
            if((Get-FastLlmPromptArtifactSha256 -TokenIds $prompts[$length]) -cne $digests[$length]){throw 'Vulkan fit numeric prompt changed before submission.'}
            $remaining=[int][Math]::Floor(($DeadlineSeconds-$timer.Elapsed.TotalSeconds)*1000)
            if($remaining -le 0){throw 'Vulkan fit benchmark deadline exceeded.'}
            $response=& $Request '/completion' @{prompt=$prompts[$length];n_predict=$generationTokens;temperature=0;seed=42;cache_prompt=$false;ignore_eos=$true;stream=$true} ([Math]::Min(180000,$remaining))
            if((Get-FastLlmPromptArtifactSha256 -TokenIds $prompts[$length]) -cne $digests[$length]){throw 'Vulkan fit numeric prompt changed during submission.'}
            $current=& $ReadState;$null=Assert-FastLlmVulkanFitBenchmarkState $current $binding;& $CheckProcess $current
            if($timer.Elapsed.TotalSeconds -gt $DeadlineSeconds){throw 'Vulkan fit benchmark deadline exceeded.'}
            $sample=ConvertFrom-FastLlmOffloadBenchmarkResponse -Response $response -ExpectedTokens $generationTokens
            if($sample.promptTokens -notin @($length,($length+1))){throw 'Vulkan fit server evaluated an unexpected prompt length.'}
            if($evaluated.ContainsKey($length)){
                if($evaluated[$length] -ne $sample.promptTokens){throw 'Vulkan fit warmup and measured evaluations differ.'}
            }else{$evaluated[$length]=$sample.promptTokens}
            if($round -gt 0){
                $sample|Add-Member -NotePropertyMembers @{requestedPromptTokens=$length;repetition=$round;promptArtifactSha256=$digests[$length]}
                $samples+=$sample
            }
            Write-Host "Private Vulkan fit prompt $length run $round/${repetitions}: $([Math]::Round($sample.generationTokensPerSecond,2)) generated tokens/s"
        }
    }
    $current=& $ReadState;$null=Assert-FastLlmVulkanFitBenchmarkState $current $binding;& $CheckProcess $current;& $CheckExecutable $current
    $summary=@(foreach($length in $promptLengths){
        $group=@($samples|Where-Object requestedPromptTokens -eq $length)
        if($group.Count -ne $repetitions -or @($group|Where-Object promptArtifactSha256 -ne $digests[$length]).Count -or
           @($group|Select-Object -ExpandProperty promptTokens -Unique).Count -ne 1){throw 'Vulkan fit sample group evidence is inconsistent.'}
        [pscustomobject]@{requestedPromptTokens=$length;evaluatedPromptTokens=$evaluated[$length];
            generation=Get-FastLlmStatistics $group.generationTokensPerSecond;prefill=Get-FastLlmStatistics $group.promptTokensPerSecond;
            firstText=Get-FastLlmStatistics $group.timeToFirstTextMs;completion=Get-FastLlmStatistics $group.completionMs}
    })
    if($timer.Elapsed.TotalSeconds -gt $DeadlineSeconds -or
       (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $sourceHash -or
       (Get-FileHash -LiteralPath $helperPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $helperHash -or
       (Get-FileHash -LiteralPath $responseParserPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $responseParserHash -or
       (Get-FileHash -LiteralPath $trialPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $trialHash){throw 'Vulkan fit benchmark deadline or source provenance changed.'}
    $report=[ordered]@{schemaVersion=1;resultKind='native-windows-api-vulkan-fit-lab-experiment';recordedAt=(Get-Date).ToUniversalTime().ToString('o');
        runId=$first.runId;processIdentity=$first.processIdentity;modelId=$first.modelId;modelSha256=$first.modelSha256;
        engineVersion=$first.engineVersion;engineSha256=$first.engineSha256;catalogSha256=$first.catalogSha256;
        trialSourceSha256=$first.trialSourceSha256;
        endpoint=$first.endpoint;recipe=$first.recipe;selectedDevice=$first.selectedDevice;
        allowHostModelBuffer=$first.allowHostModelBuffer;placementClassification=$first.placementClassification;
        reportedHostModelBufferRows=if($null -ne $first.placementEvidence.hostModelBuffer){1}else{0};
        reportedHostModelBufferMiB=if($null -ne $first.placementEvidence.hostModelBuffer){[double]$first.placementEvidence.hostModelBuffer.sizeMiB}else{$null};
        allWeightsOnGpuVerified=$false;allOperationsOnGpuVerified=$false;cpuInputEvidence='not-attested';
        placement=$first.placement;placementCounters=$first.placementCounters;
        placementEvidence=$first.placementEvidence;startupDiagnostics=$first.startupDiagnostics;canary=$first.canary;
        evidenceBindingSha256=$binding;
        sourceProvenance=@{vulkanFitBenchmarkSha256=$sourceHash;vulkanFitTrialSha256=$trialHash;canonicalHelperSha256=$helperHash;
            strictResponseParserSha256=$responseParserHash;
            scope='trial launch-source SHA matches on-disk source at measurement start/end; loaded-code identity is not attested'};
        methodology=@{corpus='fastllm-repeated-prose-v1';sampling='greedy-seed42';prefixCache=$false;warmupPerPrompt=1;
            generationTokens=$generationTokens;repetitions=$repetitions;concurrency=1;randomizedPromptOrder=$false;
            promptOrderByRound=$promptOrderByRound;
            completionRequestTimeoutMs=180000;overallDeadlineSeconds=$DeadlineSeconds;promptArtifacts=$artifacts;
            samplePromptIdentity='exact token-array digest; reported prompt_n must be N or N+1 uniformly across warmup and samples'};
        samples=$samples;summary=$summary;
        qualification=@{approved=$false;qualityEvaluation=$false;physicalResidency=$false;peakVramMeasured=$false;
            soak=$false;exclusiveWorkloadConfirmed=$false;privateVulkanFitExperiment=$true;
            allWeightsOnGpuVerified=$false;allOperationsOnGpuVerified=$false}}
    $full=[IO.Path]::GetFullPath($OutputPath)
    New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force -ErrorAction Stop|Out-Null
    $file=[IO.File]::Open($full,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$bytes=[Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 18));$file.Write($bytes,0,$bytes.Length)}finally{$file.Dispose()}
    return [pscustomobject]$report
}

function Invoke-FastLlmVulkanFitBenchmark {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$RunRoot,[Parameter(Mandatory=$true)][string]$OutputPath)
    Assert-FastLlmOffloadLabHost
    Assert-FastLlmOffloadRootPath $RunRoot
    if(-not [Environment]::Is64BitProcess){throw 'Vulkan fit benchmark requires 64-bit PowerShell.'}
    if(Test-Path -LiteralPath $OutputPath){throw 'Vulkan fit benchmark output already exists.'}
    $stateRoot=Get-FastLlmStateRoot -InstallRoot $RunRoot
    $lockPath=Join-FastLlmContainedPath -Root $stateRoot -Child 'vulkan-fit-benchmark.lock'
    if((Test-Path -LiteralPath $lockPath) -and ((Get-Item -LiteralPath $lockPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Unsafe Vulkan fit benchmark lock.'}
    try{$lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
    catch{throw 'Another Vulkan fit benchmark is active.'}
    try{
        return Invoke-FastLlmVulkanFitBenchmarkCore -OutputPath $OutputPath -ReadState {Get-FastLlmVulkanFitStatus -RunRoot $RunRoot} `
            -Request {param($Path,$Body,$TimeoutMs) Invoke-FastLlmHttp -BaseUrl 'http://127.0.0.1:18083' -Path $Path -Body $Body -TimeoutMs $TimeoutMs} `
            -CheckProcess {param($State) Assert-FastLlmVulkanFitBenchmarkProcess $State} `
            -CheckExecutable {param($State) Assert-FastLlmVulkanFitBenchmarkProcess $State -HashExecutable}
    }finally{$lock.Dispose()}
}
