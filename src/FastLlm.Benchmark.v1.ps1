function Get-FastLlmStatistics {
    param([double[]]$Values)
    if (-not $Values -or @($Values | Where-Object { [double]::IsNaN($_) -or [double]::IsInfinity($_) -or $_ -lt 0 }).Count) { throw 'Statistics require finite non-negative samples.' }
    $sorted=@($Values | Sort-Object)
    $count=$sorted.Count
    $median=if($count%2){$sorted[[int][Math]::Floor($count/2)]}else{($sorted[$count/2-1]+$sorted[$count/2])/2}
    return [pscustomobject]@{count=$count;median=$median;minimum=$sorted[0];maximum=$sorted[-1];p95=$sorted[[int][Math]::Ceiling($count*0.95)-1];p95Caution=($count -lt 20)}
}

function Get-FastLlmPromptArtifactSha256 {
    param([object[]]$TokenIds)
    if(-not $TokenIds -or $TokenIds.Count -eq 0){throw 'Prompt token artifact must not be empty.'}
    $culture=[Globalization.CultureInfo]::InvariantCulture
    $builder=New-Object Text.StringBuilder
    [void]$builder.Append("fastllm-prompt-tokens-v1`n")
    [void]$builder.Append($TokenIds.Count.ToString($culture))
    [void]$builder.Append("`n")
    foreach($token in $TokenIds){
        if(($token -isnot [int] -and $token -isnot [long]) -or [long]$token -lt 0 -or [long]$token -gt [int]::MaxValue){
            throw 'Prompt token artifact contains an invalid token ID.'
        }
        $value=[long]$token
        [void]$builder.Append($value.ToString($culture))
        [void]$builder.Append("`n")
    }
    $hash=[Security.Cryptography.SHA256]::Create()
    try {
        $bytes=[Text.Encoding]::ASCII.GetBytes($builder.ToString())
        return ([BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
    } finally { $hash.Dispose() }
}

function Test-FastLlmBenchmarkFiniteNumber {
    param($Value,[bool]$Positive=$false)
    if($Value -isnot [int] -and $Value -isnot [long] -and $Value -isnot [double] -and
       $Value -isnot [single] -and $Value -isnot [decimal]){return $false}
    $number=[double]$Value
    if([double]::IsNaN($number) -or [double]::IsInfinity($number)){return $false}
    return $(if($Positive){$number -gt 0}else{$number -ge 0})
}

function ConvertFrom-FastLlmBenchmarkResponse {
    param($Response, [int]$ExpectedTokens)
    if ($Response.Status -ne 200) { throw 'Benchmark inference failed.' }
    if(-not $Response.Events -or -not $Response.EventTimesMs -or
       $Response.Events.Count -ne $Response.EventTimesMs.Count -or
       -not (Test-FastLlmBenchmarkFiniteNumber $Response.ElapsedMs)){
        throw 'Benchmark event timing shape is invalid.'
    }
    $priorMs=[double]0
    foreach($eventMs in $Response.EventTimesMs){
        if(-not (Test-FastLlmBenchmarkFiniteNumber $eventMs) -or
           [double]$eventMs -lt $priorMs -or [double]$eventMs -gt [double]$Response.ElapsedMs){
            throw 'Benchmark event timestamps are invalid.'
        }
        $priorMs=[double]$eventMs
    }
    $firstMs=$null;$last=$null;$finalCount=0
    for($i=0;$i -lt $Response.Events.Count;$i++) {
        if($Response.Events[$i] -eq '[DONE]'){continue}
        $item=ConvertFrom-Json $Response.Events[$i]
        $content=$item.PSObject.Properties['content']
        if($null -eq $firstMs -and $content -and -not [string]::IsNullOrEmpty([string]$content.Value)){$firstMs=$Response.EventTimesMs[$i]}
        $stop=$item.PSObject.Properties['stop']
        if($stop){
            if($stop.Value -isnot [bool]){throw 'Benchmark stream stop flags must be JSON booleans.'}
            if($stop.Value){$last=$item;$finalCount++}
        }
    }
    if($null -eq $firstMs -or $finalCount -ne 1 -or -not $last.PSObject.Properties['timings']){throw 'Benchmark stream requires first text and exactly one final stop with timings.'}
    $timing=$last.timings
    foreach($name in @('prompt_n','predicted_n')){
        $property=$timing.PSObject.Properties[$name]
        if(-not $property -or ($property.Value -isnot [int] -and $property.Value -isnot [long]) -or
           [long]$property.Value -lt 1 -or [long]$property.Value -gt [int]::MaxValue){
            throw 'Benchmark response token counts must be positive exact integers.'
        }
    }
    foreach($name in @('prompt_ms','predicted_ms')){
        $property=$timing.PSObject.Properties[$name]
        if(-not $property -or -not (Test-FastLlmBenchmarkFiniteNumber $property.Value $true)){
            throw 'Benchmark response durations must be finite positive numbers.'
        }
    }
    if([int]$timing.predicted_n -ne $ExpectedTokens -or [double]$timing.predicted_ms -le 0 -or [double]$timing.prompt_ms -le 0 -or [int]$timing.prompt_n -le 0){throw 'Benchmark token count/timings do not match the fixed workload.'}
    $pp=1000*[double]$timing.prompt_n/[double]$timing.prompt_ms
    $tg=1000*[double]$timing.predicted_n/[double]$timing.predicted_ms
    foreach($number in @($pp,$tg,$firstMs,$Response.ElapsedMs)){if([double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt 0){throw 'Non-finite benchmark measurement.'}}
    return [pscustomobject]@{promptTokens=[int]$timing.prompt_n;outputTokens=[int]$timing.predicted_n;promptTokensPerSecond=$pp;generationTokensPerSecond=$tg;timeToFirstTextMs=[double]$firstMs;completionMs=[double]$Response.ElapsedMs}
}

function Invoke-FastLlmBenchmark {
    [CmdletBinding()]
    param([string]$InstallRoot,[string]$OutputPath,[int[]]$PromptTokens=@(512,4096),[ValidateRange(1,1024)][int]$GenerationTokens=128,[ValidateRange(5,100)][int]$Repetitions=5)
    if($env:OS -ne 'Windows_NT'){throw 'Physical qualification runs require native Windows.'}
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run benchmarks as a standard user.'}
    if (-not $PromptTokens -or @($PromptTokens | Select-Object -Unique).Count -ne $PromptTokens.Count) { throw 'Prompt sizes must be nonempty and unique.' }
    $state=Get-FastLlmStatus $InstallRoot
    if(-not $state.active -or $state.phase -ne 'ready' -or -not $state.recipe){throw 'Start a supervised FastLLM server and wait for ready before benchmarking.'}
    foreach($length in $PromptTokens){if($length -lt 16 -or $length+$GenerationTokens+8 -gt $state.recipe.contextSize){throw 'Requested prompt/output exceeds the effective context budget.'}}
    if(Test-Path -LiteralPath $OutputPath){throw 'Benchmark output already exists; choose a new result file.'}
    $benchLockPath=Join-Path (Get-FastLlmStateRoot $InstallRoot) 'benchmark.lock'
    if((Test-Path $benchLockPath) -and ((Get-Item $benchLockPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Unsafe benchmark lock.'}
    $benchLock=[IO.File]::Open($benchLockPath,'OpenOrCreate','ReadWrite','None')
    try{
        $baseUrl=$state.endpoint -replace '/v1$',''
        $maximumPrompt=($PromptTokens | Measure-Object -Maximum).Maximum
        $corpus=('A local inference system should produce accurate useful answers. Measure speed consistently while preserving model quality. '+[Environment]::NewLine)*([int][Math]::Ceiling($maximumPrompt/16)+2)
        $tokenized=Invoke-FastLlmHttp -BaseUrl $baseUrl -Path '/tokenize' -Body @{content=$corpus;add_special=$false} -TimeoutMs 30000
        if($tokenized.Status -ne 200){throw 'Benchmark tokenization failed.'}
        $tokens=@((ConvertFrom-Json $tokenized.Body).tokens)
        if($tokens.Count -lt ($PromptTokens | Measure-Object -Maximum).Maximum){throw 'Benchmark corpus did not produce enough tokens.'}
        $promptArrays=@{}
        $promptHashes=@{}
        $promptArtifacts=@(foreach($length in $PromptTokens){
            $prompt=@($tokens[0..($length-1)])
            $promptArrays[$length]=$prompt
            $promptHashes[$length]=Get-FastLlmPromptArtifactSha256 $prompt
            [pscustomobject]@{requestedPromptTokens=$length;tokenCount=$prompt.Count;sha256=$promptHashes[$length];format='fastllm-prompt-tokens-v1'}
        })
        $samples=@();$evaluatedCounts=@{}
        # One discarded warmup per prompt size, then interleaved randomized repetitions.
        for($round=0;$round -le $Repetitions;$round++){
            foreach($length in @($PromptTokens | Sort-Object {Get-Random})){
                $current=Get-FastLlmStatus $InstallRoot
                if(-not $current.active -or $current.phase -ne 'ready' -or $current.runId -ne $state.runId){throw 'Server identity changed during benchmark.'}
                $response=Invoke-FastLlmHttp -BaseUrl $baseUrl -Path '/completion' -TimeoutMs 180000 -Body @{
                    prompt=$promptArrays[$length];n_predict=$GenerationTokens;temperature=0;seed=42;cache_prompt=$false;ignore_eos=$true;stream=$true
                }
                $sample=ConvertFrom-FastLlmBenchmarkResponse $response $GenerationTokens
                if ($sample.promptTokens -notin @($length, ($length+1))) { throw 'Server evaluated a different prompt length (possible cache reuse or truncation).' }
                if($evaluatedCounts.ContainsKey($length)){
                    if($evaluatedCounts[$length] -ne $sample.promptTokens){throw 'Warmup and measured runs evaluated different prompt counts.'}
                }else{$evaluatedCounts[$length]=$sample.promptTokens}
                if($round -gt 0){
                    $sample|Add-Member -NotePropertyName requestedPromptTokens -NotePropertyValue $length
                    $sample|Add-Member -NotePropertyName repetition -NotePropertyValue $round
                    $sample|Add-Member -NotePropertyName promptArtifactSha256 -NotePropertyValue $promptHashes[$length]
                    $samples+=$sample
                }
                Write-Host "Prompt $length, run $round/${Repetitions}: $([Math]::Round($sample.generationTokensPerSecond,2)) generated tokens/s"
            }
        }
        $current=Get-FastLlmStatus $InstallRoot
        if(-not $current.active -or $current.phase -ne 'ready' -or $current.runId -ne $state.runId){throw 'Server changed before benchmark completion.'}
        $summary=@(foreach($length in $PromptTokens){$group=@($samples|Where-Object requestedPromptTokens -eq $length);[pscustomobject]@{promptTokens=$length;generation=Get-FastLlmStatistics $group.generationTokensPerSecond;prefill=Get-FastLlmStatistics $group.promptTokensPerSecond;firstText=Get-FastLlmStatistics $group.timeToFirstTextMs;completion=Get-FastLlmStatistics $group.completionMs}})
        $inventory=$null;$inventoryError=$null
        try { $inventory=Get-FastLlmWindowsInventory } catch { $inventoryError='windows-inventory-unavailable' }
        $result=[ordered]@{
            schemaVersion=1;resultKind='native-windows-api-benchmark-not-full-qualification';recordedAt=(Get-Date).ToUniversalTime().ToString('o')
            modelId=$state.modelId;modelSha256=$state.modelSha256;engineVersion=$state.engineVersion;recipe=$state.recipe
            os=[Environment]::OSVersion.VersionString;processorCount=[Environment]::ProcessorCount;powerPlan=(& "$env:SystemRoot\System32\powercfg.exe" /getactivescheme | Out-String).Trim()
            windowsInventory=$inventory;inventoryError=$inventoryError
            methodology=@{corpus='fastllm-repeated-prose-v1';sampling='greedy-seed42';prefixCache=$false;warmupPerPrompt=1;generationTokens=$GenerationTokens;repetitions=$Repetitions;concurrency=1;randomizedPromptOrder=$true;promptArtifacts=$promptArtifacts}
            canary=$state.canary;placement=$state.placement;samples=$samples;summary=$summary
            qualification=@{approved=$false;qualityEvaluation=$false;physicalResidency=$false;peakVramMeasured=$false;soak=$false;exclusiveWorkloadConfirmed=$false}
        }
        $parent=Split-Path ([IO.Path]::GetFullPath($OutputPath)) -Parent
        New-Item -ItemType Directory -Path $parent -Force|Out-Null
        # CreateNew prevents replacing another experiment. No prompt/completion text is exported.
        $file=[IO.File]::Open([IO.Path]::GetFullPath($OutputPath),'CreateNew','Write','None')
        try{$bytes=[Text.Encoding]::UTF8.GetBytes(($result|ConvertTo-Json -Depth 16));$file.Write($bytes,0,$bytes.Length)}finally{$file.Dispose()}
        return $result
    }finally{$benchLock.Dispose()}
}
