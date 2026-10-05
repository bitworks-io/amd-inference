# Private ROCm experiment only. Never emits the normal benchmark result kind.
function Assert-FastLlmHipBenchmarkArgument {
    param([object[]]$Arguments,[string]$Name,[string]$Value)
    $hits=@(for($i=0;$i -lt $Arguments.Count;$i++){if([string]$Arguments[$i] -ceq $Name){$i}})
    return $hits.Count -eq 1 -and $hits[0]+1 -lt $Arguments.Count -and [string]$Arguments[$hits[0]+1] -ceq $Value
}

function Get-FastLlmHipBenchmarkBinding {
    param($State)
    $bound=[ordered]@{kind=$State.kind;runId=$State.runId;processIdentity=$State.processIdentity;
        modelId=$State.modelId;modelSha256=$State.modelSha256;engineVersion=$State.engineVersion;
        engineSha256=$State.engineSha256;catalogSha256=$State.catalogSha256;trialSourceSha256=$State.trialSourceSha256;endpoint=$State.endpoint;
        recipe=$State.recipe;selectedDevice=$State.selectedDevice;allowHostModelBuffer=$State.allowHostModelBuffer;
        placementClassification=$State.placementClassification;allWeightsOnGpuVerified=$State.allWeightsOnGpuVerified;
        allOperationsOnGpuVerified=$State.allOperationsOnGpuVerified;cpuInputEvidence=$State.cpuInputEvidence;
        placement=$State.placement;
        placementEvidence=$State.placementEvidence;startupDiagnostics=$State.startupDiagnostics;canary=$State.canary}
    $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $bound -Depth 16 -Compress))
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}
    finally{$sha.Dispose()}
}

function Assert-FastLlmHipBenchmarkState {
    param($State,[string]$ExpectedBinding)
    $args=@($State.recipe.requestedArguments)
    if($State.active -isnot [bool] -or -not $State.active -or [int]$State.schemaVersion -ne 1 -or
       $State.kind -cne 'fastllm-hip-b1339-private-trial' -or $State.phase -cne 'hip-lab-ready' -or
       $State.endpoint -cne 'http://127.0.0.1:18081/v1' -or $State.experimental -isnot [bool] -or -not $State.experimental -or
       $State.performanceQualified -ne $false -or $State.physicalResidencyVerified -ne $false -or
       $State.dynamicClosureVerified -ne $false -or $State.allowHostModelBuffer -isnot [bool] -or
       $State.recipe.allowHostModelBuffer -isnot [bool] -or
       $State.recipe.allowHostModelBuffer -ne $State.allowHostModelBuffer -or
       $State.allWeightsOnGpuVerified -isnot [bool] -or $State.allWeightsOnGpuVerified -ne $false -or
       $State.allOperationsOnGpuVerified -isnot [bool] -or $State.allOperationsOnGpuVerified -ne $false -or
       $State.cpuInputEvidence -cne 'not-attested' -or $State.runId -cnotmatch '^[0-9a-f]{32}$' -or
       [int]$State.processIdentity.pid -le 0 -or [long]$State.processIdentity.startUtcTicks -le 0 -or
       $State.modelId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._+-]{0,199}$' -or
       $State.modelSha256 -cnotmatch '^[0-9a-f]{64}$' -or $State.engineSha256 -cnotmatch '^[0-9a-f]{64}$' -or
       $State.catalogSha256 -cnotmatch '^[0-9a-f]{64}$' -or $State.trialSourceSha256 -cnotmatch '^[0-9a-f]{64}$' -or
       $State.engineVersion -cne 'lemonade-b1339-gfx110X' -or
       $State.recipe.backend -cne 'ROCm' -or $State.recipe.device -cne 'ROCm0' -or
       $State.selectedDevice.device -cne 'ROCm0' -or [string]::IsNullOrWhiteSpace([string]$State.selectedDevice.name) -or
       [int]$State.recipe.contextSize -lt 4232 -or [int]$State.recipe.slots -ne 1 -or
       $State.recipe.gpuLayers -cne 'all' -or $State.recipe.fitMode -cne 'off' -or
       $State.recipe.splitMode -cne 'none' -or $State.recipe.speculation -cne 'none' -or
       $State.recipe.flashAttention -cne 'auto' -or
       $State.recipe.cacheTypeK -notin @('f16','q8_0','q4_0') -or $State.recipe.cacheTypeV -notin @('f16','q8_0','q4_0') -or
       -not (Assert-FastLlmHipBenchmarkArgument $args '--model' '<verified-model>') -or
       -not (Assert-FastLlmHipBenchmarkArgument $args '--alias' ([string]$State.modelId)) -or
       -not (Assert-FastLlmHipBenchmarkArgument $args '--host' '127.0.0.1') -or
       -not (Assert-FastLlmHipBenchmarkArgument $args '--port' '18081') -or
       -not (Assert-FastLlmHipBenchmarkArgument $args '--ctx-size' ([string]$State.recipe.contextSize)) -or
       -not (Assert-FastLlmHipBenchmarkArgument $args '--parallel' '1') -or
       -not (Assert-FastLlmHipBenchmarkArgument $args '--device' 'ROCm0') -or
       -not (Assert-FastLlmHipBenchmarkArgument $args '--n-gpu-layers' 'all') -or
       -not (Assert-FastLlmHipBenchmarkArgument $args '--fit' 'off') -or
       -not (Assert-FastLlmHipBenchmarkArgument $args '--split-mode' 'none') -or
       -not (Assert-FastLlmHipBenchmarkArgument $args '--cache-type-k' ([string]$State.recipe.cacheTypeK)) -or
       -not (Assert-FastLlmHipBenchmarkArgument $args '--cache-type-v' ([string]$State.recipe.cacheTypeV)) -or
       [int]$State.placement.reportedLayers -ne 66 -or [int]$State.placement.totalLayers -ne 66 -or
       $State.placement.reportedAllLayers -ne $true -or @($State.placement.devices).Count -ne 1 -or
       $State.placement.devices[0] -cne 'ROCm0' -or @($State.placement.modelBufferMiB).Count -ne 1 -or
       $State.placement.modelBufferMiB[0].device -cne 'ROCm0' -or
       [double]$State.placement.modelBufferMiB[0].sizeMiB -le 0 -or
       $State.placement.physicalResidencyVerified -ne $false -or
       $State.placementEvidence.status -cne 'captured' -or
       @($State.placementEvidence.offloadRows).Count -ne 1 -or
       [int]$State.placementEvidence.offloadRows[0].reportedGpuLayers -ne 66 -or
       [int]$State.placementEvidence.offloadRows[0].reportedTotalLayers -ne 66 -or
       $State.placementEvidence.physicalResidencyVerified -ne $false -or
       $State.startupDiagnostics.physicalResidencyVerified -ne $false -or
       $State.canary.modelIdentity -ne $true -or $State.canary.repeatableToken -ne $true -or
       $State.canary.synchronousChat -ne $true -or $State.canary.streaming -ne $true -or
       [int]$State.canary.effectiveContext -ne [int]$State.recipe.contextSize -or
       $State.canary.semanticCorrectnessQualified -ne $false){
        throw 'Exact private HIP trial is not ready or its evidence is inconsistent.'
    }
    $buffers=@($State.placementEvidence.modelBuffers)
    $gpuBuffers=@($buffers|Where-Object {$_.device -ceq 'ROCm0'})
    $hostBuffers=@($buffers|Where-Object {$_.device -ceq 'CPU_Mapped'})
    $expectedHostRows=if($State.allowHostModelBuffer){1}else{0}
    $expectedClass=if($State.allowHostModelBuffer){'all-reported-layers-with-host-model-buffer'}else{'all-reported-layers-no-host-model-buffer'}
    if($State.placementClassification -cne $expectedClass -or
       [int]$State.placementEvidence.cpuBufferLikeLines -ne $expectedHostRows -or
       [int]$State.placementEvidence.cpuModelBufferRows -ne $expectedHostRows -or
       $buffers.Count -ne (1+$expectedHostRows) -or $gpuBuffers.Count -ne 1 -or
       $hostBuffers.Count -ne $expectedHostRows -or $gpuBuffers[0].sizeMiB -isnot [ValueType] -or
       [double]$gpuBuffers[0].sizeMiB -ne [double]$State.placement.modelBufferMiB[0].sizeMiB -or
       [double]::IsNaN([double]$gpuBuffers[0].sizeMiB) -or [double]::IsInfinity([double]$gpuBuffers[0].sizeMiB)){
        throw 'HIP host/GPU model-buffer classification is inconsistent.'
    }
    if($expectedHostRows){
        if($hostBuffers[0].sizeMiB -isnot [ValueType] -or
           [double]$hostBuffers[0].sizeMiB -le 0 -or [double]::IsNaN([double]$hostBuffers[0].sizeMiB) -or
           [double]::IsInfinity([double]$hostBuffers[0].sizeMiB)){
            throw 'HIP opt-in host model-buffer evidence is malformed.'
        }
    }
    $binding=Get-FastLlmHipBenchmarkBinding $State
    if($ExpectedBinding -and $binding -cne $ExpectedBinding){throw 'HIP trial run, process, artifact, recipe or placement changed during measurement.'}
    return $binding
}

function Assert-FastLlmHipBenchmarkProcess {
    param($State,[switch]$HashExecutable)
    if(-not ('Bitworks.FastLlm.WindowsGpuTelemetry' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'WindowsGpuTelemetry.cs') -ErrorAction Stop}
    $owners=@([Bitworks.FastLlm.WindowsGpuTelemetry]::GetLoopbackListenerOwners(18081))
    if($owners.Count -ne 1 -or [int]$owners[0] -ne [int]$State.processIdentity.pid){throw 'HIP listener owner differs from the supervised child.'}
    $process=$null
    try{
        $process=[Diagnostics.Process]::GetProcessById([int]$State.processIdentity.pid)
        if($process.HasExited -or $process.ProcessName -cne 'llama-server' -or
           [long]$process.StartTime.ToUniversalTime().Ticks -ne [long]$State.processIdentity.startUtcTicks){throw 'HIP child process identity changed.'}
        if($HashExecutable){
            if((Get-FileHash -LiteralPath $process.MainModule.FileName -Algorithm SHA256).Hash.ToLowerInvariant() -cne $State.engineSha256){
                throw 'HIP executable file hash differs from the recorded engine.'
            }
        }
    }finally{if($process){$process.Dispose()}}
}

function Invoke-FastLlmHipBenchmarkCore {
    param([string]$OutputPath,[scriptblock]$ReadState,[scriptblock]$Request,[scriptblock]$CheckProcess,
          [scriptblock]$CheckExecutable,[int]$DeadlineSeconds=3600)
    if($DeadlineSeconds -lt 1 -or $DeadlineSeconds -gt 3600){throw 'HIP benchmark deadline outside bound.'}
    $promptLengths=@(512,4096);$generationTokens=128;$repetitions=5
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $sourcePath=Join-Path $PSScriptRoot 'FastLlm.HipBenchmark.ps1'
    $helperPath=Join-Path $PSScriptRoot 'FastLlm.Benchmark.ps1'
    $responseParserPath=Join-Path $PSScriptRoot 'FastLlm.OffloadBenchmark.ps1'
    $trialPath=Join-Path $PSScriptRoot 'FastLlm.HipModelTrial.ps1'
    $sourceHash=(Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $helperHash=(Get-FileHash -LiteralPath $helperPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $responseParserHash=(Get-FileHash -LiteralPath $responseParserPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $trialHash=(Get-FileHash -LiteralPath $trialPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $first=& $ReadState
    $binding=Assert-FastLlmHipBenchmarkState $first
    if($first.trialSourceSha256 -cne $trialHash){throw 'HIP trial launch-source hash differs from the measured source.'}
    & $CheckProcess $first;& $CheckExecutable $first
    if(Test-Path -LiteralPath $OutputPath){throw 'HIP benchmark output already exists.'}
    $corpus=('A local inference system should produce accurate useful answers. Measure speed consistently while preserving model quality. '+[Environment]::NewLine)*([int][Math]::Ceiling(4096/16)+2)
    $remaining=[int][Math]::Floor(($DeadlineSeconds-$timer.Elapsed.TotalSeconds)*1000)
    if($remaining -le 0){throw 'HIP benchmark deadline exceeded.'}
    $tokenized=& $Request '/tokenize' @{content=$corpus;add_special=$false} ([Math]::Min(30000,$remaining))
    $current=& $ReadState;$null=Assert-FastLlmHipBenchmarkState $current $binding;& $CheckProcess $current
    if($tokenized.Status -ne 200){throw 'HIP benchmark tokenization failed.'}
    $tokens=@((ConvertFrom-Json $tokenized.Body).tokens)
    if($tokens.Count -lt 4096 -or $tokens.Count -gt 100000){throw 'HIP fixed corpus tokenization outside bounds.'}
    $prompts=@{};$digests=@{}
    $artifacts=@(foreach($length in $promptLengths){
        $array=@($tokens[0..($length-1)]);$digest=Get-FastLlmPromptArtifactSha256 -TokenIds $array
        $prompts[$length]=$array;$digests[$length]=$digest
        [pscustomobject]@{requestedPromptTokens=$length;tokenCount=$length;sha256=$digest;format='fastllm-prompt-tokens-v1'}
    })
    $samples=@();$evaluated=@{}
    for($round=0;$round -le $repetitions;$round++){
        foreach($length in @($promptLengths | Sort-Object {Get-Random})){
            $current=& $ReadState;$null=Assert-FastLlmHipBenchmarkState $current $binding;& $CheckProcess $current
            if((Get-FastLlmPromptArtifactSha256 -TokenIds $prompts[$length]) -cne $digests[$length]){throw 'HIP numeric prompt changed before submission.'}
            $remaining=[int][Math]::Floor(($DeadlineSeconds-$timer.Elapsed.TotalSeconds)*1000)
            if($remaining -le 0){throw 'HIP benchmark deadline exceeded.'}
            $response=& $Request '/completion' @{prompt=$prompts[$length];n_predict=$generationTokens;temperature=0;seed=42;cache_prompt=$false;ignore_eos=$true;stream=$true} ([Math]::Min(180000,$remaining))
            if((Get-FastLlmPromptArtifactSha256 -TokenIds $prompts[$length]) -cne $digests[$length]){throw 'HIP numeric prompt changed during submission.'}
            $current=& $ReadState;$null=Assert-FastLlmHipBenchmarkState $current $binding;& $CheckProcess $current
            if($timer.Elapsed.TotalSeconds -gt $DeadlineSeconds){throw 'HIP benchmark deadline exceeded.'}
            $sample=ConvertFrom-FastLlmOffloadBenchmarkResponse -Response $response -ExpectedTokens $generationTokens
            if($sample.promptTokens -notin @($length,($length+1))){throw 'HIP server evaluated an unexpected prompt length.'}
            if($evaluated.ContainsKey($length)){
                if($evaluated[$length] -ne $sample.promptTokens){throw 'HIP warmup and measured evaluations differ.'}
            }else{$evaluated[$length]=$sample.promptTokens}
            if($round -gt 0){
                $sample|Add-Member -NotePropertyMembers @{requestedPromptTokens=$length;repetition=$round;promptArtifactSha256=$digests[$length]}
                $samples+=$sample
            }
            Write-Host "Private HIP prompt $length run $round/${repetitions}: $([Math]::Round($sample.generationTokensPerSecond,2)) generated tokens/s"
        }
    }
    $current=& $ReadState;$null=Assert-FastLlmHipBenchmarkState $current $binding;& $CheckProcess $current;& $CheckExecutable $current
    $summary=@(foreach($length in $promptLengths){
        $group=@($samples|Where-Object requestedPromptTokens -eq $length)
        if($group.Count -ne $repetitions -or @($group|Where-Object promptArtifactSha256 -ne $digests[$length]).Count -or
           @($group|Select-Object -ExpandProperty promptTokens -Unique).Count -ne 1){throw 'HIP sample group evidence is inconsistent.'}
        [pscustomobject]@{requestedPromptTokens=$length;evaluatedPromptTokens=$evaluated[$length];
            generation=Get-FastLlmStatistics $group.generationTokensPerSecond;prefill=Get-FastLlmStatistics $group.promptTokensPerSecond;
            firstText=Get-FastLlmStatistics $group.timeToFirstTextMs;completion=Get-FastLlmStatistics $group.completionMs}
    })
    if($timer.Elapsed.TotalSeconds -gt $DeadlineSeconds -or
       (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $sourceHash -or
       (Get-FileHash -LiteralPath $helperPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $helperHash -or
       (Get-FileHash -LiteralPath $responseParserPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $responseParserHash -or
       (Get-FileHash -LiteralPath $trialPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $trialHash){throw 'HIP benchmark deadline or source provenance changed.'}
    $report=[ordered]@{schemaVersion=1;resultKind='native-windows-api-hip-lab-experiment';recordedAt=(Get-Date).ToUniversalTime().ToString('o');
        runId=$first.runId;processIdentity=$first.processIdentity;modelId=$first.modelId;modelSha256=$first.modelSha256;
        engineVersion=$first.engineVersion;engineSha256=$first.engineSha256;catalogSha256=$first.catalogSha256;
        trialSourceSha256=$first.trialSourceSha256;
        endpoint=$first.endpoint;recipe=$first.recipe;selectedDevice=$first.selectedDevice;
        allowHostModelBuffer=$first.allowHostModelBuffer;placementClassification=$first.placementClassification;
        reportedHostModelBufferRows=[int]$first.placementEvidence.cpuModelBufferRows;
        reportedHostModelBufferMiB=if($first.allowHostModelBuffer){[double]@($first.placementEvidence.modelBuffers|Where-Object {$_.device -ceq 'CPU_Mapped'})[0].sizeMiB}else{$null};
        allWeightsOnGpuVerified=$false;allOperationsOnGpuVerified=$false;cpuInputEvidence='not-attested';
        placement=$first.placement;
        placementEvidence=$first.placementEvidence;startupDiagnostics=$first.startupDiagnostics;canary=$first.canary;
        evidenceBindingSha256=$binding;
        sourceProvenance=@{hipBenchmarkSha256=$sourceHash;hipTrialSha256=$trialHash;canonicalHelperSha256=$helperHash;
            strictResponseParserSha256=$responseParserHash;
            scope='trial launch-source SHA matches on-disk source at measurement start/end; loaded-code identity is not attested'};
        methodology=@{corpus='fastllm-repeated-prose-v1';sampling='greedy-seed42';prefixCache=$false;warmupPerPrompt=1;
            generationTokens=$generationTokens;repetitions=$repetitions;concurrency=1;randomizedPromptOrder=$true;
            completionRequestTimeoutMs=180000;overallDeadlineSeconds=$DeadlineSeconds;promptArtifacts=$artifacts;
            samplePromptIdentity='exact token-array digest; reported prompt_n must be N or N+1 uniformly across warmup and samples'};
        samples=$samples;summary=$summary;
        qualification=@{approved=$false;qualityEvaluation=$false;physicalResidency=$false;peakVramMeasured=$false;
            soak=$false;exclusiveWorkloadConfirmed=$false;privateHipExperiment=$true;
            allWeightsOnGpuVerified=$false;allOperationsOnGpuVerified=$false}}
    $full=[IO.Path]::GetFullPath($OutputPath)
    New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force -ErrorAction Stop|Out-Null
    $file=[IO.File]::Open($full,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$bytes=[Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 18));$file.Write($bytes,0,$bytes.Length)}finally{$file.Dispose()}
    return [pscustomobject]$report
}

function Invoke-FastLlmHipBenchmark {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$RunRoot,[Parameter(Mandatory=$true)][string]$OutputPath)
    Assert-FastLlmHipLabIdentity
    Assert-FastLlmOffloadRootPath $RunRoot
    if(-not [Environment]::Is64BitProcess){throw 'HIP benchmark requires 64-bit PowerShell.'}
    if(Test-Path -LiteralPath $OutputPath){throw 'HIP benchmark output already exists.'}
    $stateRoot=Get-FastLlmStateRoot -InstallRoot $RunRoot
    $lockPath=Join-FastLlmContainedPath -Root $stateRoot -Child 'hip-benchmark.lock'
    if((Test-Path -LiteralPath $lockPath) -and ((Get-Item -LiteralPath $lockPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Unsafe HIP benchmark lock.'}
    try{$lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
    catch{throw 'Another HIP benchmark is active.'}
    try{
        return Invoke-FastLlmHipBenchmarkCore -OutputPath $OutputPath -ReadState {Get-FastLlmHipTrialStatus -RunRoot $RunRoot} `
            -Request {param($Path,$Body,$TimeoutMs) Invoke-FastLlmHttp -BaseUrl 'http://127.0.0.1:18081' -Path $Path -Body $Body -TimeoutMs $TimeoutMs} `
            -CheckProcess {param($State) Assert-FastLlmHipBenchmarkProcess $State} `
            -CheckExecutable {param($State) Assert-FastLlmHipBenchmarkProcess $State -HashExecutable}
    }finally{$lock.Dispose()}
}
