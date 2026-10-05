# Separate experimental measurement contract. Never emits the normal benchmark result kind.
function Test-FastLlmOffloadBenchmarkArg {
    param([object[]]$Arguments,[string]$Name,[string]$Expected)
    $indices=@(for($i=0;$i -lt $Arguments.Count;$i++){if([string]$Arguments[$i] -ceq $Name){$i}})
    return $indices.Count -eq 1 -and $indices[0]+1 -lt $Arguments.Count -and [string]$Arguments[$indices[0]+1] -ceq $Expected
}

function Initialize-FastLlmOffloadBenchmarkTcp {
    if(-not ('Bitworks.FastLlm.WindowsGpuTelemetry' -as [type])){
        Add-Type -Path (Join-Path $PSScriptRoot 'WindowsGpuTelemetry.cs') -ErrorAction Stop
    }
}

function ConvertFrom-FastLlmOffloadBenchmarkResponse {
    param($Response,[int]$ExpectedTokens)
    if($Response.Status -ne 200){throw 'Offload benchmark inference failed.'}
    $final=@()
    foreach($eventText in @($Response.Events)){
        if($eventText -eq '[DONE]'){continue}
        $item=ConvertFrom-Json $eventText
        $stop=$item.PSObject.Properties['stop']
        if($stop){
            if($stop.Value -isnot [bool]){throw 'Offload benchmark stream stop flags must be JSON booleans.'}
            if($stop.Value){$final+= $item}
        }
    }
    if($final.Count -ne 1 -or -not $final[0].PSObject.Properties['timings']){throw 'Offload benchmark requires one final timing event.'}
    $timings=$final[0].timings
    foreach($name in @('prompt_n','predicted_n')){
        $property=$timings.PSObject.Properties[$name]
        if(-not $property -or ($property.Value -isnot [int] -and $property.Value -isnot [long]) -or
           [long]$property.Value -lt 1 -or [long]$property.Value -gt [int]::MaxValue){
            throw 'Offload benchmark response token counts must be positive exact integers.'
        }
    }
    if([long]$timings.predicted_n -ne $ExpectedTokens){throw 'Offload benchmark generated token count changed.'}
    return ConvertFrom-FastLlmBenchmarkResponse -Response $Response -ExpectedTokens $ExpectedTokens
}

function Assert-FastLlmOffloadBenchmarkState {
    param($State,[string]$ExpectedBinding)
    $args=@($State.recipe.requestedArguments)
    if(-not $State.active -or [int]$State.schemaVersion -ne 1 -or $State.kind -ne 'fastllm-offload-lab-run' -or $State.phase -ne 'lab-ready' -or
       $State.endpoint -cne 'http://127.0.0.1:18080/v1' -or -not $State.recipe -or -not $State.placement -or
       -not $State.experimental -or $State.modelId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._+-]{0,199}$' -or
       $State.modelSha256 -cnotmatch '^[0-9a-f]{64}$' -or $State.engineSha256 -cnotmatch '^[0-9a-f]{64}$' -or
       $State.catalogSha256 -cnotmatch '^[0-9a-f]{64}$' -or $State.engineVersion -cne 'b10698' -or
       $State.recipe.backend -ne 'Vulkan' -or $State.recipe.fitMode -ne 'off' -or
       $State.recipe.engineSha256 -cne $State.engineSha256 -or $State.recipe.catalogSha256 -cne $State.catalogSha256 -or
       [int]$State.recipe.contextSize -ne [int]$State.requestedContextSize -or [int]$State.recipe.slots -ne 1 -or
       $State.recipe.splitMode -cne 'none' -or $State.recipe.speculation -cne 'none' -or
       $State.recipe.selectedAdapters.Count -ne 1 -or $State.recipe.device -cne $State.placement.selectedDevice -or
       $State.recipe.selectedAdapters[0].device -cne $State.recipe.device -or
       [long]$State.recipe.selectedAdapters[0].reportedTotalVramMiB -le 0 -or
       [string]::IsNullOrWhiteSpace([string]$State.recipe.selectedAdapters[0].name) -or
       -not (Test-FastLlmOffloadBenchmarkArg $args '--model' '<verified-model>') -or
       -not (Test-FastLlmOffloadBenchmarkArg $args '--alias' ([string]$State.modelId)) -or
       -not (Test-FastLlmOffloadBenchmarkArg $args '--host' '127.0.0.1') -or
       -not (Test-FastLlmOffloadBenchmarkArg $args '--port' '18080') -or
       -not (Test-FastLlmOffloadBenchmarkArg $args '--ctx-size' ([string]$State.recipe.contextSize)) -or
       -not (Test-FastLlmOffloadBenchmarkArg $args '--parallel' '1') -or
       -not (Test-FastLlmOffloadBenchmarkArg $args '--device' ([string]$State.recipe.device)) -or
       -not (Test-FastLlmOffloadBenchmarkArg $args '--n-gpu-layers' ([string]$State.recipe.gpuLayers)) -or
       -not (Test-FastLlmOffloadBenchmarkArg $args '--fit' 'off') -or
       -not (Test-FastLlmOffloadBenchmarkArg $args '--split-mode' 'none') -or
       -not (Test-FastLlmOffloadBenchmarkArg $args '--cache-type-k' ([string]$State.recipe.cacheTypeK)) -or
       -not (Test-FastLlmOffloadBenchmarkArg $args '--cache-type-v' ([string]$State.recipe.cacheTypeV)) -or
       [int]$State.recipe.gpuLayers -ne [int]$State.placement.requestedGpuLayers -or
       [int]$State.placement.reportedGpuLayers -ne [int]$State.placement.requestedGpuLayers -or
       [int]$State.placement.reportedTotalLayers -le [int]$State.placement.reportedGpuLayers -or
       -not $State.canary.modelIdentity -or -not $State.canary.repeatableToken -or
       -not $State.canary.synchronousChat -or -not $State.canary.streaming -or
       [int]$State.canary.effectiveContext -ne [int]$State.recipe.contextSize -or
       $State.canary.semanticCorrectnessQualified -or
       $State.placement.performanceQualified -or $State.placement.physicalResidencyVerified -or
       $State.performanceQualified -or $State.physicalResidencyVerified -or
       $State.runId -cnotmatch '^[0-9a-f]{32}$' -or [int]$State.processIdentity.pid -le 0 -or
       [long]$State.processIdentity.startUtcTicks -le 0){
        throw 'The exact supervised partial-offload lab run is not ready or its evidence is inconsistent.'
    }
    $binding=Get-FastLlmOffloadBenchmarkBinding $State
    if($ExpectedBinding -and $binding -cne $ExpectedBinding){throw 'Offload lab run, process, artifact, recipe or placement changed during measurement.'}
    return $binding
}

function Get-FastLlmOffloadBenchmarkBinding {
    param($State)
    $identity=[ordered]@{
        runId=$State.runId;pid=[int]$State.processIdentity.pid;startUtcTicks=[long]$State.processIdentity.startUtcTicks
        modelId=$State.modelId;modelSha256=$State.modelSha256;engineVersion=$State.engineVersion
        engineSha256=$State.engineSha256;catalogSha256=$State.catalogSha256;endpoint=$State.endpoint
        recipe=$State.recipe;placement=$State.placement;canary=$State.canary
    }
    $json=ConvertTo-Json -InputObject $identity -Depth 16 -Compress
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json)))).Replace('-','').ToLowerInvariant()}
    finally{$sha.Dispose()}
}

function Assert-FastLlmOffloadBenchmarkProcess {
    param($State)
    Initialize-FastLlmOffloadBenchmarkTcp
    $owners=@([Bitworks.FastLlm.WindowsGpuTelemetry]::GetLoopbackListenerOwners(18080))
    if($owners.Count -ne 1 -or [int]$owners[0] -ne [int]$State.processIdentity.pid){throw 'Loopback listener owner differs from the supervised lab child.'}
    $process=$null
    try{
        $process=[Diagnostics.Process]::GetProcessById([int]$State.processIdentity.pid)
        if($process.HasExited -or $process.ProcessName -cne 'llama-server' -or
           [long]$process.StartTime.ToUniversalTime().Ticks -ne [long]$State.processIdentity.startUtcTicks){
            throw 'Supervised lab child process identity changed.'
        }
    }catch{throw 'Supervised lab child process identity is unavailable or changed.'}
    finally{if($process){$process.Dispose()}}
}

function Assert-FastLlmOffloadBenchmarkExecutable {
    param($State)
    $process=$null
    try{
        $process=[Diagnostics.Process]::GetProcessById([int]$State.processIdentity.pid)
        if($process.HasExited -or $process.ProcessName -cne 'llama-server' -or
           [long]$process.StartTime.ToUniversalTime().Ticks -ne [long]$State.processIdentity.startUtcTicks){throw 'Lab executable identity changed.'}
        $path=$process.MainModule.FileName
        if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$State.engineSha256){
            throw 'Lab executable file differs from the recorded engine digest.'
        }
    }finally{if($process){$process.Dispose()}}
}

function Invoke-FastLlmOffloadBenchmarkCore {
    param([string]$OutputPath,[int[]]$PromptTokens,[int]$GenerationTokens,[int]$Repetitions,
          [scriptblock]$ReadState,[scriptblock]$Request,[scriptblock]$CheckProcess,[scriptblock]$CheckExecutable,[int]$DeadlineSeconds=3600)
    if(-not $PromptTokens -or $PromptTokens.Count -gt 2 -or @($PromptTokens | Select-Object -Unique).Count -ne $PromptTokens.Count -or
       $Repetitions -lt 5 -or $Repetitions -gt 20 -or $GenerationTokens -lt 1 -or $GenerationTokens -gt 512 -or
       $DeadlineSeconds -lt 1 -or $DeadlineSeconds -gt 3600){throw 'Offload benchmark workload is outside its fixed bounds.'}
    if(-not $CheckExecutable){$CheckExecutable={param($State)}} # Internal mock seam; live entry always supplies the native verifier.
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $sourcePath=Join-Path $PSScriptRoot 'FastLlm.OffloadBenchmark.ps1'
    $helperPath=Join-Path $PSScriptRoot 'FastLlm.Benchmark.ps1'
    $labPath=Join-Path $PSScriptRoot 'FastLlm.OffloadLab.ps1'
    $sourceHash=(Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $helperHash=(Get-FileHash -LiteralPath $helperPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $labHash=(Get-FileHash -LiteralPath $labPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $first=& $ReadState
    $binding=Assert-FastLlmOffloadBenchmarkState -State $first
    & $CheckProcess $first
    & $CheckExecutable $first
    foreach($length in $PromptTokens){
        if($length -lt 16 -or $length -gt 4096 -or $length+$GenerationTokens+8 -gt [int]$first.recipe.contextSize){
            throw 'Offload prompt/output exceeds the effective context or fixed lab workload limit.'
        }
    }
    if(Test-Path -LiteralPath $OutputPath){throw 'Offload benchmark output already exists.'}
    $maxPrompt=($PromptTokens | Measure-Object -Maximum).Maximum
    $corpus=('A local inference system should produce accurate useful answers. Measure speed consistently while preserving model quality. '+[Environment]::NewLine)*([int][Math]::Ceiling($maxPrompt/16)+2)
    $remaining=[int][Math]::Floor(($DeadlineSeconds-$timer.Elapsed.TotalSeconds)*1000)
    if($remaining -le 0){throw 'Offload benchmark deadline exceeded.'}
    $tokenized=& $Request '/tokenize' @{content=$corpus;add_special=$false} ([Math]::Min(30000,$remaining))
    $current=& $ReadState;$null=Assert-FastLlmOffloadBenchmarkState -State $current -ExpectedBinding $binding;& $CheckProcess $current
    if($tokenized.Status -ne 200){throw 'Offload benchmark tokenization failed.'}
    $tokens=@((ConvertFrom-Json $tokenized.Body).tokens)
    if($tokens.Count -lt $maxPrompt){throw 'Fixed benchmark corpus produced too few tokens.'}
    $prompts=@{};$digests=@{}
    $artifacts=@(foreach($length in $PromptTokens){
        $array=@($tokens[0..($length-1)])
        $digest=Get-FastLlmPromptArtifactSha256 -TokenIds $array
        $prompts[$length]=$array;$digests[$length]=$digest
        [pscustomobject]@{requestedPromptTokens=$length;tokenCount=$array.Count;sha256=$digest;format='fastllm-prompt-tokens-v1'}
    })
    $samples=@();$evaluatedCounts=@{}
    # Exactly one discarded warmup per group, then interleaved measurements.
    for($round=0;$round -le $Repetitions;$round++){
        foreach($length in @($PromptTokens | Sort-Object {Get-Random})){
            $current=& $ReadState;$null=Assert-FastLlmOffloadBenchmarkState -State $current -ExpectedBinding $binding;& $CheckProcess $current
            if((Get-FastLlmPromptArtifactSha256 -TokenIds $prompts[$length]) -cne $digests[$length]){throw 'Fixed numeric prompt array changed before submission.'}
            $remaining=[int][Math]::Floor(($DeadlineSeconds-$timer.Elapsed.TotalSeconds)*1000)
            if($remaining -le 0){throw 'Offload benchmark deadline exceeded.'}
            $response=& $Request '/completion' @{prompt=$prompts[$length];n_predict=$GenerationTokens;temperature=0;seed=42;cache_prompt=$false;ignore_eos=$true;stream=$true} ([Math]::Min(300000,$remaining))
            if((Get-FastLlmPromptArtifactSha256 -TokenIds $prompts[$length]) -cne $digests[$length]){throw 'Fixed numeric prompt array changed during submission.'}
            $current=& $ReadState;$null=Assert-FastLlmOffloadBenchmarkState -State $current -ExpectedBinding $binding;& $CheckProcess $current
            if($timer.Elapsed.TotalSeconds -gt $DeadlineSeconds){throw 'Offload benchmark deadline exceeded.'}
            $sample=ConvertFrom-FastLlmOffloadBenchmarkResponse -Response $response -ExpectedTokens $GenerationTokens
            if($sample.promptTokens -notin @($length,($length+1))){throw 'Server evaluated a different prompt length, possibly due to truncation or cache reuse.'}
            if($evaluatedCounts.ContainsKey($length)){
                if($evaluatedCounts[$length] -ne $sample.promptTokens){throw 'Warmup and measured runs evaluated different prompt counts.'}
            }else{$evaluatedCounts[$length]=$sample.promptTokens}
            if($round -gt 0){
                $sample | Add-Member -NotePropertyMembers @{requestedPromptTokens=$length;repetition=$round;promptArtifactSha256=$digests[$length]}
                $samples+=$sample
            }
            Write-Host "Experimental prompt $length, run $round/${Repetitions}: $([Math]::Round($sample.generationTokensPerSecond,2)) generated tokens/s"
        }
    }
    $current=& $ReadState;$null=Assert-FastLlmOffloadBenchmarkState -State $current -ExpectedBinding $binding;& $CheckProcess $current
    & $CheckExecutable $current
    $summary=@(foreach($length in $PromptTokens){
        $group=@($samples | Where-Object requestedPromptTokens -eq $length)
        if($group.Count -ne $Repetitions -or @($group | Where-Object promptArtifactSha256 -ne $digests[$length]).Count -or
           @($group | Select-Object -ExpandProperty promptTokens -Unique).Count -ne 1){throw 'Offload sample group identity or evaluated prompt count is inconsistent.'}
        [pscustomobject]@{requestedPromptTokens=$length;evaluatedPromptTokens=$evaluatedCounts[$length];generation=Get-FastLlmStatistics $group.generationTokensPerSecond;
            prefill=Get-FastLlmStatistics $group.promptTokensPerSecond;firstText=Get-FastLlmStatistics $group.timeToFirstTextMs;
            completion=Get-FastLlmStatistics $group.completionMs}
    })
    if($timer.Elapsed.TotalSeconds -gt $DeadlineSeconds -or
       (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sourceHash -or
       (Get-FileHash -LiteralPath $helperPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $helperHash -or
       (Get-FileHash -LiteralPath $labPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $labHash){
        throw 'Offload benchmark deadline or source-provenance validation failed.'
    }
    $report=[ordered]@{
        schemaVersion=1;resultKind='native-windows-api-offload-lab-experiment';recordedAt=(Get-Date).ToUniversalTime().ToString('o')
        runId=$first.runId;processIdentity=$first.processIdentity;modelId=$first.modelId;modelSha256=$first.modelSha256
        engineVersion=$first.engineVersion;engineSha256=$first.engineSha256;catalogSha256=$first.catalogSha256
        endpoint=$first.endpoint;recipe=$first.recipe;placement=$first.placement;canary=$first.canary
        evidenceBindingSha256=$binding
        sourceProvenance=@{offloadBenchmarkSha256=$sourceHash;canonicalHelperSha256=$helperHash;offloadLabSha256=$labHash;
            scope='on-disk SHA-256 checked at measurement start/end; loaded-code identity is not attested'}
        methodology=@{corpus='fastllm-repeated-prose-v1';sampling='greedy-seed42';prefixCache=$false;warmupPerPrompt=1;
            generationTokens=$GenerationTokens;repetitions=$Repetitions;concurrency=1;promptArtifacts=$artifacts;
            samplePromptIdentity='exact token-array digest per group; reported prompt_n must be N or N+1'}
        samples=$samples;summary=$summary
        qualification=@{approved=$false;qualityEvaluation=$false;physicalResidency=$false;peakVramMeasured=$false;
            soak=$false;exclusiveWorkloadConfirmed=$false;experimentalCpuOffload=$true}
    }
    $full=[IO.Path]::GetFullPath($OutputPath)
    $parent=Split-Path $full -Parent
    New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
    $file=[IO.File]::Open($full,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$bytes=[Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 18));$file.Write($bytes,0,$bytes.Length)}finally{$file.Dispose()}
    return [pscustomobject]$report
}

function Invoke-FastLlmOffloadBenchmark {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$LabRunRoot,[Parameter(Mandatory=$true)][string]$OutputPath,
          [int[]]$PromptTokens=@(512,2048),[ValidateRange(1,512)][int]$GenerationTokens=128,
          [ValidateRange(5,20)][int]$Repetitions=5)
    Assert-FastLlmOffloadLabHost
    Assert-FastLlmOffloadRootPath $LabRunRoot
    if(-not [Environment]::Is64BitProcess){throw 'Offload benchmark requires 64-bit PowerShell.'}
    if(Test-Path -LiteralPath $OutputPath){throw 'Offload benchmark output already exists.'}
    $stateRoot=Get-FastLlmStateRoot -InstallRoot $LabRunRoot
    $lockPath=Join-FastLlmContainedPath -Root $stateRoot -Child 'offload-benchmark.lock'
    if((Test-Path -LiteralPath $lockPath) -and ((Get-Item -LiteralPath $lockPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Unsafe offload benchmark lock.'}
    try{$lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
    catch{throw 'Another offload benchmark is active.'}
    try{
        return Invoke-FastLlmOffloadBenchmarkCore -OutputPath $OutputPath -PromptTokens $PromptTokens -GenerationTokens $GenerationTokens -Repetitions $Repetitions `
            -ReadState {Get-FastLlmOffloadLabStatus -LabRunRoot $LabRunRoot} `
            -Request {param($Path,$Body,$TimeoutMs) Invoke-FastLlmHttp -BaseUrl 'http://127.0.0.1:18080' -Path $Path -Body $Body -TimeoutMs $TimeoutMs} `
            -CheckProcess {param($State) Assert-FastLlmOffloadBenchmarkProcess $State} `
            -CheckExecutable {param($State) Assert-FastLlmOffloadBenchmarkExecutable $State}
    }finally{$lock.Dispose()}
}
