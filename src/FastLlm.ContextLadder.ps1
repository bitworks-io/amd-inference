#requires -Version 5.1
# W11 context-ladder tool: one client, one slot, one supervised normal server. Private lab report only; every qualification flag stays false.
# Spec: docs/research/CONTEXT-LADDER-TOOL-SPEC-2026-10-06.md. Dot-sourced inside the FastLlm module scope (see tools/context-ladder.ps1)
# so it can use the internal helpers (Get-FastLlmStatus, Invoke-FastLlmHttp, Get-FastLlmPromptArtifactSha256,
# ConvertFrom-FastLlmBenchmarkResponse, Get-FastLlmStatistics). It does not copy or modify the producer.
# No prompt, filler or completion text is ever stored in the report; failures use fixed codes, never exception text.

$script:FastLlmContextLadderSourcePath=$PSCommandPath

function Get-FastLlmContextLadderProtocol {
    # Declared by the tool, never tuned per run. Every value is recorded in the report.
    return [ordered]@{
        version='context-ladder-v1'
        speedCorpus='fastllm-repeated-prose-v1'
        outputSafetyMarginTokens=64
        retrievalOutputTokens=32
        retrievalSafetyMarginTokens=64
        minimumSpeedPromptTokens=16
        occupancyLowerFraction=0.90
        occupancyUsageToleranceTokens=4
        maxOccupancyProbes=12
        distractorLineFraction=0.01
        needleRounding='away-from-zero'
        requestShape='producer-token-array-completion'
    }
}

function Get-FastLlmContextLadderSha256 {
    param([AllowEmptyString()][string]$Text)
    $hasher=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant()}
    finally{$hasher.Dispose()}
}

function Get-FastLlmContextLadderProperty {
    param($Object,[string]$Name)
    if($null -eq $Object){return $null}
    $property=$Object.PSObject.Properties[$Name]
    if($null -eq $property){return $null}
    return $property.Value
}

function Get-FastLlmContextLadderUtcNow {return (Get-Date).ToUniversalTime().ToString('o')}

# ---------------------------------------------------------------- tiers
function Resolve-FastLlmContextLadderTierPlan {
    # Listed tiers above the effective per-slot context are recorded and never run. The effective context is added as a
    # tier when it is not listed and lies strictly between the smallest and largest listed tier (the catalog ceiling rule).
    param([int[]]$Tiers,[int]$EffectiveContext)
    if(-not $Tiers -or @($Tiers).Count -eq 0){throw 'At least one tier is required.'}
    $listed=@($Tiers | Sort-Object -Unique)
    if($listed.Count -ne @($Tiers).Count){throw 'Tiers must be unique.'}
    $items=@()
    foreach($tier in $listed){$items+=[pscustomobject]@{tier=[int]$tier;source='listed'}}
    $minimum=[int]$listed[0];$maximum=[int]$listed[$listed.Count-1]
    if($EffectiveContext -gt $minimum -and $EffectiveContext -lt $maximum -and $listed -notcontains $EffectiveContext){
        $items+=[pscustomobject]@{tier=[int]$EffectiveContext;source='catalog-ceiling'}
    }
    $plan=@()
    foreach($item in @($items | Sort-Object tier)){
        $status=if($item.tier -gt $EffectiveContext){'skipped-above-effective-context'}else{'pending'}
        $plan+=[pscustomobject]@{tier=$item.tier;source=$item.source;status=$status}
    }
    return $plan
}

# ---------------------------------------------------------------- binding
function Get-FastLlmContextLadderBinding {
    param($State)
    if($null -eq $State -or -not [bool](Get-FastLlmContextLadderProperty $State 'active') -or
       [string](Get-FastLlmContextLadderProperty $State 'phase') -cne 'ready'){
        throw 'Start a supervised FastLLM server and wait for ready before running the context ladder.'
    }
    $runId=[string](Get-FastLlmContextLadderProperty $State 'runId')
    $identity=Get-FastLlmContextLadderProperty $State 'processIdentity'
    $pidValue=Get-FastLlmContextLadderProperty $identity 'pid'
    $ticksValue=Get-FastLlmContextLadderProperty $identity 'startUtcTicks'
    $recipe=Get-FastLlmContextLadderProperty $State 'recipe'
    if($runId -notmatch '^[0-9a-f]{32}$' -or $null -eq $recipe -or
       ($pidValue -isnot [int] -and $pidValue -isnot [long]) -or [long]$pidValue -le 0 -or
       ($ticksValue -isnot [int] -and $ticksValue -isnot [long]) -or [long]$ticksValue -le 0){
        throw 'The supervised run state lacks a run id, recipe or process identity.'
    }
    $endpoint=[string](Get-FastLlmContextLadderProperty $State 'endpoint')
    $uri=$null
    if(-not [Uri]::TryCreate($endpoint,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'http' -or $uri.Host -ne '127.0.0.1' -or $uri.UserInfo){
        throw 'The context ladder requires a loopback (127.0.0.1) http endpoint.'
    }
    $baseUrl=$endpoint -replace '/v1/?$',''
    return [pscustomobject]@{
        runId=$runId;pid=[int]$pidValue;startUtcTicks=[long]$ticksValue;endpoint=$endpoint;baseUrl=$baseUrl
        modelId=[string](Get-FastLlmContextLadderProperty $State 'modelId')
        modelSha256=[string](Get-FastLlmContextLadderProperty $State 'modelSha256')
        engineVersion=[string](Get-FastLlmContextLadderProperty $State 'engineVersion')
        recipe=$recipe
    }
}

function Test-FastLlmContextLadderIdentity {
    param($Binding,$Current)
    if($null -eq $Current -or -not [bool](Get-FastLlmContextLadderProperty $Current 'active') -or
       [string](Get-FastLlmContextLadderProperty $Current 'phase') -cne 'ready' -or
       [string](Get-FastLlmContextLadderProperty $Current 'runId') -cne $Binding.runId){return $false}
    $identity=Get-FastLlmContextLadderProperty $Current 'processIdentity'
    $pidValue=Get-FastLlmContextLadderProperty $identity 'pid'
    $ticksValue=Get-FastLlmContextLadderProperty $identity 'startUtcTicks'
    if($null -eq $pidValue -or $null -eq $ticksValue){return $false}
    return ([long]$pidValue -eq [long]$Binding.pid -and [long]$ticksValue -eq [long]$Binding.startUtcTicks)
}

# ---------------------------------------------------------------- HTTP (never stores exception text)
function Test-FastLlmContextLadderTimeout {
    param($ErrorObject,[double]$ElapsedMs,[int]$TimeoutMs)
    $cursor=$ErrorObject
    while($null -ne $cursor){
        if($cursor -is [TimeoutException]){return $true}
        if($cursor -is [Net.WebException] -and ($cursor.Status -eq [Net.WebExceptionStatus]::Timeout -or $cursor.Status -eq [Net.WebExceptionStatus]::RequestCanceled)){return $true}
        $cursor=$cursor.InnerException
    }
    return ($ElapsedMs -ge ($TimeoutMs-250))
}

function Invoke-FastLlmContextLadderRequest {
    # Outcome is one of ok, request-timeout, request-error, run-deadline. The request timeout is capped at the time left
    # before the run deadline; a timeout caused by that cap is a run-deadline abort, not a tier failure.
    param([hashtable]$Run,[string]$Path,$Body,[int]$TimeoutMs)
    $remaining=[int]($Run.deadlineMs-$Run.clock.ElapsedMilliseconds)
    if($remaining -le 0){return [pscustomobject]@{outcome='run-deadline';response=$null;elapsedMs=[double]0}}
    $effective=[Math]::Min($TimeoutMs,$remaining)
    $capped=($remaining -lt $TimeoutMs)
    $watch=[Diagnostics.Stopwatch]::StartNew()
    try{
        if($null -ne $Body){$response=Invoke-FastLlmHttp -BaseUrl $Run.baseUrl -Path $Path -Body $Body -TimeoutMs $effective}
        else{$response=Invoke-FastLlmHttp -BaseUrl $Run.baseUrl -Path $Path -TimeoutMs $effective}
        return [pscustomobject]@{outcome='ok';response=$response;elapsedMs=$watch.Elapsed.TotalMilliseconds}
    }catch{
        $timedOut=Test-FastLlmContextLadderTimeout -ErrorObject $_.Exception -ElapsedMs $watch.Elapsed.TotalMilliseconds -TimeoutMs $effective
        $outcome='request-error'
        if($timedOut){$outcome=$(if($capped){'run-deadline'}else{'request-timeout'})}
        return [pscustomobject]@{outcome=$outcome;response=$null;elapsedMs=$watch.Elapsed.TotalMilliseconds}
    }
}

# ---------------------------------------------------------------- metrics
function ConvertFrom-FastLlmContextLadderMetrics {
    param([string]$Text)
    $values=@{}
    $culture=[Globalization.CultureInfo]::InvariantCulture
    foreach($line in @($Text -split "`r?`n")){
        if($line -match '^(llamacpp:[A-Za-z0-9_]+)(?:\{[^}]*\})?\s+([-+]?[0-9]+(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?)\s*$'){
            $number=[double]0
            if([double]::TryParse($Matches[2],[Globalization.NumberStyles]::Float,$culture,[ref]$number)){$values[$Matches[1]]=$number}
        }
    }
    $pick={param($n) if($values.ContainsKey($n)){return $values[$n]};return $null}
    $prompt=& $pick 'llamacpp:prompt_tokens_total'
    $predicted=& $pick 'llamacpp:tokens_predicted_total'
    return [ordered]@{
        available=($null -ne $prompt -and $null -ne $predicted)
        promptTokensTotal=$prompt;tokensPredictedTotal=$predicted
        kvCacheUsageRatio=(& $pick 'llamacpp:kv_cache_usage_ratio');kvCacheTokens=(& $pick 'llamacpp:kv_cache_tokens')
        label='engine-reported-not-residency'
    }
}

function Read-FastLlmContextLadderMetrics {
    param([hashtable]$Run)
    $snapshot=[ordered]@{atUtc=(Get-FastLlmContextLadderUtcNow);available=$false;reason=$null;promptTokensTotal=$null;tokensPredictedTotal=$null;kvCacheUsageRatio=$null;kvCacheTokens=$null;label='engine-reported-not-residency'}
    $call=Invoke-FastLlmContextLadderRequest -Run $Run -Path '/metrics' -Body $null -TimeoutMs 10000
    if($call.outcome -ne 'ok'){$snapshot.reason=$call.outcome;return $snapshot}
    if($call.response.Status -ne 200){$snapshot.reason='http-status';return $snapshot}
    $parsed=ConvertFrom-FastLlmContextLadderMetrics -Text ([string]$call.response.Body)
    if(-not $parsed.available){$snapshot.reason='metrics-unparseable';return $snapshot}
    foreach($key in @('promptTokensTotal','tokensPredictedTotal','kvCacheUsageRatio','kvCacheTokens')){$snapshot[$key]=$parsed[$key]}
    $snapshot.available=$true
    return $snapshot
}

# ---------------------------------------------------------------- Panel 1: occupied-context speed
function ConvertFrom-FastLlmContextLadderSpeedResponse {
    # The strict producer parser requires predicted_n to equal its expected count, so the final stop event's predicted_n is
    # read first and handed to the unmodified parser; every other strict check still applies. The ladder rules follow.
    param($Response,[int]$PromptTarget,[int]$OutputTokens)
    $sample=[ordered]@{valid=$false;classification='response-parse-failed';httpStatus=$null;evaluatedPromptTokens=$null;predictedTokens=$null
        prefillTokensPerSecond=$null;generationTokensPerSecond=$null;timeToFirstTextMs=$null;completionMs=$null
        truncated=$null;contextShift=$null;stopReason=$null}
    $sample.httpStatus=[int]$Response.Status
    if($Response.Status -ne 200){$sample.classification='http-status';return $sample}
    $final=$null;$finals=0
    try{
        foreach($eventText in @($Response.Events)){
            if($eventText -eq '[DONE]'){continue}
            $item=ConvertFrom-Json -InputObject $eventText
            $stop=$item.PSObject.Properties['stop']
            if($stop -and $stop.Value -is [bool] -and $stop.Value){$final=$item;$finals++}
        }
    }catch{return $sample}
    if($finals -ne 1){return $sample}
    $predictedN=Get-FastLlmContextLadderProperty (Get-FastLlmContextLadderProperty $final 'timings') 'predicted_n'
    if(($predictedN -isnot [int] -and $predictedN -isnot [long]) -or [long]$predictedN -lt 1 -or [long]$predictedN -gt [int]::MaxValue){return $sample}
    try{$parsed=ConvertFrom-FastLlmBenchmarkResponse $Response ([int]$predictedN)}catch{return $sample}
    $truncated=Get-FastLlmContextLadderProperty $final 'truncated'
    $sample.truncated=$(if($truncated -is [bool]){$truncated}else{$null})
    $shift=$false
    foreach($name in @('context_shift','context_shifted')){if((Get-FastLlmContextLadderProperty $final $name) -eq $true){$shift=$true}}
    $sample.contextShift=$shift
    $stopType=Get-FastLlmContextLadderProperty $final 'stop_type'
    $reason='unknown'
    if($stopType -is [string] -and $stopType.Length -gt 0){$reason=$stopType}
    elseif((Get-FastLlmContextLadderProperty $final 'stopped_eos') -eq $true){$reason='eos'}
    elseif((Get-FastLlmContextLadderProperty $final 'stopped_limit') -eq $true){$reason='limit'}
    elseif((Get-FastLlmContextLadderProperty $final 'stopped_word') -eq $true){$reason='word'}
    $sample.stopReason=$reason
    $sample.evaluatedPromptTokens=[int]$parsed.promptTokens
    $sample.predictedTokens=[int]$parsed.outputTokens
    $sample.prefillTokensPerSecond=[double]$parsed.promptTokensPerSecond
    $sample.generationTokensPerSecond=[double]$parsed.generationTokensPerSecond
    $sample.timeToFirstTextMs=[double]$parsed.timeToFirstTextMs
    $sample.completionMs=[double]$parsed.completionMs
    if(@($PromptTarget,($PromptTarget+1)) -notcontains [int]$parsed.promptTokens){$sample.classification='evaluated-prompt-mismatch'}
    elseif($sample.truncated -eq $true){$sample.classification='truncated'}
    elseif($shift){$sample.classification='context-shift'}
    elseif([int]$parsed.outputTokens -lt $OutputTokens){
        if($reason -ceq 'eos'){$sample.classification='early-eos';$sample.valid=$true}
        else{$sample.classification='short-output-non-eos'}
    }
    elseif([int]$parsed.outputTokens -gt $OutputTokens){$sample.classification='output-exceeds-request'}
    else{$sample.classification='ok';$sample.valid=$true}
    return $sample
}

function Get-FastLlmContextLadderStats {
    param([double[]]$Values)
    if($null -eq $Values -or @($Values).Count -eq 0){return $null}
    return Get-FastLlmStatistics $Values
}

# ---------------------------------------------------------------- Panel 2: retrieval construction, search, grading
function Get-FastLlmContextLadderCode {
    # Two letters, a hyphen and four digits, derived from SHA-256 of the case identity (never Get-Random).
    param([int]$Seed,[int]$Tier,[double]$Depth,[string]$Role,[int]$Index,[int]$Attempt)
    $text=[string]::Format([Globalization.CultureInfo]::InvariantCulture,'fastllm-context-ladder-v1|code|{0}|{1}|{2:F4}|{3}|{4}|{5}',$Seed,$Tier,$Depth,$Role,$Index,$Attempt)
    $hex=Get-FastLlmContextLadderSha256 $text
    $letters='ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    $first=$letters[[Convert]::ToInt32($hex.Substring(0,2),16)%26]
    $second=$letters[[Convert]::ToInt32($hex.Substring(2,2),16)%26]
    $number=1000+([Convert]::ToInt32($hex.Substring(4,6),16)%9000)
    return ([string]$first+[string]$second+'-'+$number.ToString([Globalization.CultureInfo]::InvariantCulture))
}

function New-FastLlmContextLadderCase {
    param([int]$Seed,[int]$Tier,[double]$Depth,[int]$LineCount,[string]$NeedleCode)
    if($LineCount -lt 1){throw 'A retrieval case needs at least one filler line.'}
    $culture=[Globalization.CultureInfo]::InvariantCulture
    $seedHex=Get-FastLlmContextLadderSha256 ([string]::Format($culture,'fastllm-context-ladder-v1|filler|{0}|{1}|{2:F4}',$Seed,$Tier,$Depth))
    $state=[Convert]::ToInt64($seedHex.Substring(0,7),16)
    $colors=@('blue','red','green','yellow','white','black','orange','gray')
    $items=@('copper wire','steel bolts','glass jars','paper reels','rubber seals','wool blankets','tin cans','oak planks')
    $labels=@('locker','badge','dock','cabinet','gate','garage')
    $distractorCount=[Math]::Max(1,[int][Math]::Ceiling($LineCount*0.01))
    $positions=New-Object 'System.Collections.Generic.HashSet[int]'
    for($k=0;$k -lt $distractorCount;$k++){
        $h=Get-FastLlmContextLadderSha256 ([string]::Format($culture,'fastllm-context-ladder-v1|distractor-position|{0}|{1}|{2:F4}|{3}',$Seed,$Tier,$Depth,$k))
        $position=1+([Convert]::ToInt32($h.Substring(0,7),16)%$LineCount)
        while(-not $positions.Add($position)){$position=($position%$LineCount)+1}
    }
    $usedCodes=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    [void]$usedCodes.Add($NeedleCode)
    $distractorCodes=@()
    $lines=New-Object 'System.Collections.Generic.List[string]'
    $distractorIndex=0
    for($i=1;$i -le $LineCount;$i++){
        $state=($state*1103515245L+12345L)%2147483648L
        $color=$colors[[int](($state -shr 8)%$colors.Count)]
        $state=($state*1103515245L+12345L)%2147483648L
        $bay=1+[int](($state -shr 8)%40)
        $state=($state*1103515245L+12345L)%2147483648L
        $item=$items[[int](($state -shr 8)%$items.Count)]
        if($positions.Contains($i)){
            $attempt=0
            do{$distractor=Get-FastLlmContextLadderCode -Seed $Seed -Tier $Tier -Depth $Depth -Role 'distractor' -Index $distractorIndex -Attempt $attempt;$attempt++}
            while(-not $usedCodes.Add($distractor))
            $label=$labels[$distractorIndex%$labels.Count]
            $distractorIndex++
            $distractorCodes+=$distractor
            $lines.Add(('The {0} code is {1}.' -f $label,$distractor))
        }else{
            $lines.Add(('Record {0}: the {1} crate in bay {2} holds {3}.' -f $i.ToString('D4',$culture),$color,$bay,$item))
        }
    }
    $needleIndex=[int][Math]::Round($Depth*$LineCount,[MidpointRounding]::AwayFromZero)
    if($needleIndex -gt $LineCount){$needleIndex=$LineCount}
    $lines.Insert($needleIndex,('The vault access code is {0}.' -f $NeedleCode))
    $content=([string]::Join("`n",$lines.ToArray()))+"`n"+'What is the vault access code? Reply with the code only.'
    return [pscustomobject]@{content=$content;needleCode=$NeedleCode;needleLineIndex=$needleIndex;lineCount=$LineCount;distractorCount=$distractorCount;distractorCodes=$distractorCodes}
}

function Get-FastLlmContextLadderConstructionSha256 {
    # Digest of the construction templates, so the report identifies the generator without containing its text.
    $templates="fastllm-context-ladder-v1`nRecord {0:D4}: the {color} crate in bay {bay} holds {item}.`nThe {label} code is {code}.`nThe vault access code is {code}.`nWhat is the vault access code? Reply with the code only."
    return Get-FastLlmContextLadderSha256 $templates
}

function Find-FastLlmContextLadderLineCount {
    # Bounded search for the filler line count whose measured prompt token count lies in [lower*max, max].
    # Proportional extrapolation until the window is bracketed, then bisection. Never accepts a count above max.
    param([int]$MaxTokens,[double]$LowerFraction,[scriptblock]$Measure,[int]$MaxProbes=12)
    $lowTokens=$LowerFraction*$MaxTokens
    $target=($lowTokens+$MaxTokens)/2
    $below=0;$above=[int]::MaxValue
    $lineCount=[Math]::Max(1,[int][Math]::Floor($MaxTokens/16))
    $probes=0
    while($probes -lt $MaxProbes){
        $count=[int](& $Measure $lineCount)
        $probes++
        if($count -le $MaxTokens -and $count -ge $lowTokens){
            return [pscustomobject]@{found=$true;lineCount=$lineCount;tokenCount=$count;probes=$probes;reason=$null}
        }
        if($count -gt $MaxTokens){$above=$lineCount}else{$below=$lineCount}
        if($above -le $below+1){return [pscustomobject]@{found=$false;lineCount=$null;tokenCount=$null;probes=$probes;reason='window-unreachable'}}
        if($above -eq [int]::MaxValue){$next=[int][Math]::Floor($lineCount*$target/[Math]::Max(1,$count));if($next -le $lineCount){$next=$lineCount+1}}
        elseif($below -eq 0){$next=[int][Math]::Floor($lineCount*$target/[Math]::Max(1,$count))}
        else{$next=[int][Math]::Floor(($below+$above)/2)}
        if($next -lt $below+1){$next=$below+1}
        if($next -gt $above-1){$next=$above-1}
        $lineCount=$next
    }
    return [pscustomobject]@{found=$false;lineCount=$null;tokenCount=$null;probes=$probes;reason='probe-limit'}
}

function Get-FastLlmContextLadderGrade {
    # The grader is fixed and is never softened: reasoning present is invalid-mode; otherwise trim, remove at most one
    # trailing period, and compare case-sensitively (ordinal) with the needle code. An empty response is incorrect.
    param([AllowNull()][string]$Content,[string]$ExpectedCode,[bool]$ReasoningPresent)
    if($ReasoningPresent){return 'invalid-mode'}
    $text=$(if($null -eq $Content){''}else{$Content.Trim()})
    if($text.EndsWith('.',[StringComparison]::Ordinal)){$text=$text.Substring(0,$text.Length-1)}
    if([string]::Equals($text,$ExpectedCode,[StringComparison]::Ordinal)){return 'correct'}
    return 'incorrect'
}

function ConvertFrom-FastLlmContextLadderChatResponse {
    param($Response)
    $result=[ordered]@{ok=$false;errorCode='response-parse-failed';content=$null;reasoningPresent=$false;finishReason=$null;promptTokens=$null;completionTokens=$null}
    if($null -eq $Response -or [int]$Response.Status -ne 200){$result.errorCode='http-status';return $result}
    try{
        $data=ConvertFrom-Json -InputObject ([string]$Response.Body)
        $choices=Get-FastLlmContextLadderProperty $data 'choices'
        if($null -eq $choices){return $result}
        $choices=@($choices)
        if($choices.Count -lt 1){return $result}
        $message=Get-FastLlmContextLadderProperty $choices[0] 'message'
        if($null -eq $message -or $null -eq $message.PSObject.Properties['content']){return $result}
        $content=$message.content
        if($null -ne $content -and $content -isnot [string]){return $result}
        $result.content=$(if($null -eq $content){''}else{[string]$content})
        foreach($field in @('reasoning_content','reasoning')){
            $value=Get-FastLlmContextLadderProperty $message $field
            if($null -ne $value -and -not ($value -is [string] -and $value.Length -eq 0)){$result.reasoningPresent=$true}
        }
        $finish=Get-FastLlmContextLadderProperty $choices[0] 'finish_reason'
        if($finish -is [string]){$result.finishReason=$finish}
        $usage=Get-FastLlmContextLadderProperty $data 'usage'
        $promptTokens=Get-FastLlmContextLadderProperty $usage 'prompt_tokens'
        $completionTokens=Get-FastLlmContextLadderProperty $usage 'completion_tokens'
        if($promptTokens -is [int] -or $promptTokens -is [long]){$result.promptTokens=[int]$promptTokens}
        if($completionTokens -is [int] -or $completionTokens -is [long]){$result.completionTokens=[int]$completionTokens}
        $result.ok=$true;$result.errorCode=$null
    }catch{$result.ok=$false;$result.errorCode='response-parse-failed'}
    return $result
}

function Invoke-FastLlmContextLadderRetrievalCase {
    param([hashtable]$Run,[int]$Tier,[double]$Depth,[hashtable]$Flow)
    $protocol=$Run.protocol
    $maxTokens=$Tier-$protocol.retrievalOutputTokens-$protocol.retrievalSafetyMarginTokens
    $case=[ordered]@{depth=$Depth;status='ran';grade=$null;reason=$null;startUtc=(Get-FastLlmContextLadderUtcNow);endUtc=$null
        needleLineIndex=$null;lineCount=$null;distractorCount=$null;occupancyProbes=0;measuredPromptTokens=$null
        usagePromptTokens=$null;usageCompletionTokens=$null;usageDifference=$null;finishReason=$null;reasoningPresent=$null
        promptSha256=$null;userContentSha256=$null;responseSha256=$null;responseLength=$null;expectedCodeSha256=$null;completionMs=$null}
    $attempt=0
    do{$code=Get-FastLlmContextLadderCode -Seed $Run.seed -Tier $Tier -Depth $Depth -Role 'needle' -Index 0 -Attempt $attempt;$attempt++}
    while(-not $Run.usedCodes.Add($code))
    $case.expectedCodeSha256=Get-FastLlmContextLadderSha256 $code
    $probe=@{error=$null;byLine=@{};cases=@{}}
    $fail={param($grade,$reason)
        $case.grade=$grade;$case.reason=$reason;$case.endUtc=(Get-FastLlmContextLadderUtcNow)
        if($null -eq $Flow.failure){$Flow.failure=@{tier=$Tier;panel='retrieval';reason=$reason}}
    }
    $measure={
        param([int]$LineCount)
        $c=New-FastLlmContextLadderCase -Seed $Run.seed -Tier $Tier -Depth $Depth -LineCount $LineCount -NeedleCode $code
        $messages=@(@{role='user';content=$c.content})
        $applied=Invoke-FastLlmContextLadderRequest -Run $Run -Path '/apply-template' -Body @{messages=$messages;chat_template_kwargs=@{enable_thinking=$false}} -TimeoutMs $Run.timeoutMs
        if($applied.outcome -ne 'ok'){$probe.error=$applied.outcome;throw 'occupancy-probe-stopped'}
        if([int]$applied.response.Status -ne 200){$probe.error='occupancy-unverifiable';throw 'occupancy-probe-stopped'}
        $rendered=$null
        try{$rendered=Get-FastLlmContextLadderProperty (ConvertFrom-Json -InputObject ([string]$applied.response.Body)) 'prompt'}catch{$rendered=$null}
        if($rendered -isnot [string] -or $rendered.Length -eq 0){$probe.error='occupancy-unverifiable';throw 'occupancy-probe-stopped'}
        $tokenized=Invoke-FastLlmContextLadderRequest -Run $Run -Path '/tokenize' -Body @{content=$rendered;add_special=$true;parse_special=$true} -TimeoutMs $Run.timeoutMs
        if($tokenized.outcome -ne 'ok'){$probe.error=$tokenized.outcome;throw 'occupancy-probe-stopped'}
        $tokenCount=$null
        if([int]$tokenized.response.Status -eq 200){
            try{$tokens=Get-FastLlmContextLadderProperty (ConvertFrom-Json -InputObject ([string]$tokenized.response.Body)) 'tokens';if($null -ne $tokens){$tokenCount=@($tokens).Count}}catch{$tokenCount=$null}
        }
        if($null -eq $tokenCount){$probe.error='occupancy-unverifiable';throw 'occupancy-probe-stopped'}
        $probe.byLine[$LineCount]=@{count=$tokenCount;promptSha256=(Get-FastLlmContextLadderSha256 $rendered)}
        $probe.cases[$LineCount]=$c
        return $tokenCount
    }
    $search=$null
    try{$search=Find-FastLlmContextLadderLineCount -MaxTokens $maxTokens -LowerFraction $protocol.occupancyLowerFraction -Measure $measure -MaxProbes $protocol.maxOccupancyProbes}
    catch{
        if($null -eq $probe.error){throw}
        $case.occupancyProbes=$probe.byLine.Count
        if($probe.error -ceq 'run-deadline'){$case.status='aborted-at-run-deadline';$case.endUtc=(Get-FastLlmContextLadderUtcNow);$Flow.abort='run-deadline';return $case}
        if($probe.error -ceq 'occupancy-unverifiable'){& $fail 'invalid-occupancy-unverifiable' 'occupancy-unverifiable';return $case}
        & $fail 'invalid-request' $probe.error;return $case
    }
    $case.occupancyProbes=$search.probes
    if(-not $search.found){& $fail 'invalid-occupancy' $search.reason;return $case}
    $built=$probe.cases[$search.lineCount]
    $case.lineCount=$built.lineCount;$case.distractorCount=$built.distractorCount;$case.needleLineIndex=$built.needleLineIndex
    $case.measuredPromptTokens=$search.tokenCount
    $case.promptSha256=$probe.byLine[$search.lineCount].promptSha256
    $case.userContentSha256=Get-FastLlmContextLadderSha256 $built.content
    $body=@{model=$Run.modelId;messages=@(@{role='user';content=$built.content});max_tokens=$protocol.retrievalOutputTokens;temperature=0;seed=$Run.seed
        stream=$false;cache_prompt=$false;chat_template_kwargs=@{enable_thinking=$false}}
    $call=Invoke-FastLlmContextLadderRequest -Run $Run -Path '/v1/chat/completions' -Body $body -TimeoutMs $Run.timeoutMs
    $case.completionMs=$call.elapsedMs
    if($call.outcome -ceq 'run-deadline'){$case.status='aborted-at-run-deadline';$case.endUtc=(Get-FastLlmContextLadderUtcNow);$Flow.abort='run-deadline';return $case}
    if($call.outcome -cne 'ok'){& $fail 'invalid-request' $call.outcome;return $case}
    $parsed=ConvertFrom-FastLlmContextLadderChatResponse -Response $call.response
    if(-not $parsed.ok){
        if($parsed.errorCode -ceq 'http-status'){& $fail 'invalid-request' 'http-status'}else{& $fail 'invalid-response' $parsed.errorCode}
        return $case
    }
    $case.finishReason=$parsed.finishReason;$case.reasoningPresent=[bool]$parsed.reasoningPresent
    $case.usagePromptTokens=$parsed.promptTokens;$case.usageCompletionTokens=$parsed.completionTokens
    $case.responseSha256=Get-FastLlmContextLadderSha256 ([string]$parsed.content)
    $case.responseLength=([string]$parsed.content).Length
    if($parsed.reasoningPresent){& $fail 'invalid-mode' 'reasoning-present';return $case}
    if($null -eq $parsed.promptTokens){& $fail 'invalid-occupancy' 'usage-missing';return $case}
    $case.usageDifference=[int]$parsed.promptTokens-[int]$search.tokenCount
    if([Math]::Abs($case.usageDifference) -gt $protocol.occupancyUsageToleranceTokens){& $fail 'invalid-occupancy' 'usage-mismatch';return $case}
    $grade=Get-FastLlmContextLadderGrade -Content $parsed.content -ExpectedCode $code -ReasoningPresent $false
    if($grade -ceq 'correct'){$case.grade='correct';$case.endUtc=(Get-FastLlmContextLadderUtcNow)}
    else{& $fail $grade 'wrong-answer'}
    return $case
}

# ---------------------------------------------------------------- one tier
function Invoke-FastLlmContextLadderTier {
    param([hashtable]$Run,[int]$Tier,[string]$Source,[hashtable]$Flow)
    $protocol=$Run.protocol
    $outputTokens=$Run.outputTokens
    $promptTokens=$Tier-$outputTokens-$protocol.outputSafetyMarginTokens
    $retrievalMaximum=$Tier-$protocol.retrievalOutputTokens-$protocol.retrievalSafetyMarginTokens
    $prompt=@($Run.tokens[0..($promptTokens-1)])
    $digest=Get-FastLlmPromptArtifactSha256 $prompt
    $samples=New-Object System.Collections.ArrayList
    $cases=New-Object System.Collections.ArrayList
    $entry=[ordered]@{tier=$Tier;source=$Source;status='running';startUtc=(Get-FastLlmContextLadderUtcNow);endUtc=$null
        speed=[ordered]@{promptTokensTarget=$promptTokens;outputTokens=$outputTokens
            promptArtifact=[ordered]@{format='fastllm-prompt-tokens-v1';tokenCount=$prompt.Count;sha256=$digest};samples=$null;summary=$null}
        retrieval=[ordered]@{outputTokens=$protocol.retrievalOutputTokens;occupancyMaximumTokens=$retrievalMaximum
            occupancyMinimumTokens=($protocol.occupancyLowerFraction*$retrievalMaximum);cases=$null}
        metricsAfter=$null;failure=$null}
    $skipStatus={$(if($null -ne $Flow.abort){'not-run-run-aborted'}else{'not-run-after-failure'})}
    for($i=0;$i -le $Run.repetitions;$i++){
        $kind=$(if($i -eq 0){'warmup'}else{'measured'})
        if($null -ne $Flow.failure -or $null -ne $Flow.abort){
            [void]$samples.Add([ordered]@{kind=$kind;repetition=$i;status=(& $skipStatus)})
            continue
        }
        $startUtc=Get-FastLlmContextLadderUtcNow
        $call=Invoke-FastLlmContextLadderRequest -Run $Run -Path '/completion' -TimeoutMs $Run.timeoutMs -Body @{
            prompt=$prompt;n_predict=$outputTokens;temperature=0;seed=$Run.seed;cache_prompt=$false;ignore_eos=$true;stream=$true}
        $sample=[ordered]@{kind=$kind;repetition=$i;status='ran';startUtc=$startUtc;endUtc=(Get-FastLlmContextLadderUtcNow)}
        if($call.outcome -ceq 'run-deadline'){
            $sample.status='aborted-at-run-deadline';$Flow.abort='run-deadline'
        }elseif($call.outcome -cne 'ok'){
            $sample.status='request-failed';$sample.errorCode=$call.outcome;$sample.valid=$false
            $Flow.failure=@{tier=$Tier;panel='speed';reason=$call.outcome}
        }else{
            $parsed=ConvertFrom-FastLlmContextLadderSpeedResponse -Response $call.response -PromptTarget $promptTokens -OutputTokens $outputTokens
            foreach($key in @($parsed.Keys)){$sample[$key]=$parsed[$key]}
            if(-not $parsed.valid){$Flow.failure=@{tier=$Tier;panel='speed';reason=[string]$parsed.classification}}
        }
        [void]$samples.Add($sample)
    }
    $measured=@($samples | Where-Object {$_.kind -eq 'measured' -and $_.status -eq 'ran' -and $_.valid})
    $generation=@($measured | Where-Object {$_.classification -eq 'ok'})
    $entry.speed.samples=@($samples)
    $entry.speed.summary=[ordered]@{measuredValidCount=$measured.Count;earlyEosCount=@($measured | Where-Object {$_.classification -eq 'early-eos'}).Count
        prefill=(Get-FastLlmContextLadderStats ([double[]]@($measured | ForEach-Object {$_.prefillTokensPerSecond})))
        generation=(Get-FastLlmContextLadderStats ([double[]]@($generation | ForEach-Object {$_.generationTokensPerSecond})))
        timeToFirstText=(Get-FastLlmContextLadderStats ([double[]]@($measured | ForEach-Object {$_.timeToFirstTextMs})))
        completion=(Get-FastLlmContextLadderStats ([double[]]@($measured | ForEach-Object {$_.completionMs})))}
    foreach($depth in $Run.depths){
        if($null -ne $Flow.failure -or $null -ne $Flow.abort){
            [void]$cases.Add([ordered]@{depth=$depth;status=(& $skipStatus)})
            continue
        }
        [void]$cases.Add((Invoke-FastLlmContextLadderRetrievalCase -Run $Run -Tier $Tier -Depth $depth -Flow $Flow))
    }
    $entry.retrieval.cases=@($cases)
    if($null -ne $Flow.failure -and $Flow.failure.tier -eq $Tier){
        $entry.failure=[ordered]@{panel=$Flow.failure.panel;reason=$Flow.failure.reason}
    }
    if($Flow.abort -ceq 'run-deadline'){$entry.status='aborted'}
    elseif($null -ne $entry.failure){$entry.status=$(if($entry.failure.reason -ceq 'occupancy-unverifiable'){'occupancy-unverifiable'}else{'failed'})}
    else{$entry.status='passed'}
    if($Flow.abort -cne 'run-deadline'){$entry.metricsAfter=Read-FastLlmContextLadderMetrics -Run $Run}
    $entry.endUtc=Get-FastLlmContextLadderUtcNow
    return $entry
}

# ---------------------------------------------------------------- report
function Write-FastLlmContextLadderReport {
    # Atomic and never overwriting: write a same-directory temporary file, then File.Move, which refuses an existing target.
    param([string]$Path,$Report)
    $full=[IO.Path]::GetFullPath($Path)
    $directory=Split-Path $full -Parent
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temporary=Join-Path $directory ('.'+[Guid]::NewGuid().ToString('N')+'.tmp')
    try{
        [IO.File]::WriteAllText($temporary,(ConvertTo-Json -InputObject $Report -Depth 20),(New-Object Text.UTF8Encoding($false)))
        [IO.File]::Move($temporary,$full)
    }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue}}
}

function Get-FastLlmContextLadderFileSha256 {
    param([string]$Path)
    if([string]::IsNullOrEmpty($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Invoke-FastLlmContextLadder {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$InstallRoot,[Parameter(Mandatory=$true)][string]$OutputPath,
          [int[]]$Tiers=@(1024,2048,4096,8192,16384,32768),
          [ValidateRange(64,1024)][int]$OutputTokens=256,
          [ValidateRange(1,10)][int]$Repetitions=3,
          [double[]]$NeedleDepths=@(0.1,0.5,0.9),
          [ValidateRange(1,1800)][int]$RequestTimeoutSeconds=900,
          [ValidateRange(1,14400)][int]$RunDeadlineSeconds=7200,
          [int]$Seed=42,[string]$CliSourcePath)
    $protocol=Get-FastLlmContextLadderProtocol
    $outputFull=[IO.Path]::GetFullPath($OutputPath)
    if(Test-Path -LiteralPath $outputFull){throw 'Context ladder output already exists; choose a new result file.'}
    if(-not $Tiers -or @($Tiers).Count -eq 0 -or @($Tiers | Select-Object -Unique).Count -ne @($Tiers).Count){throw 'Tiers must be nonempty and unique.'}
    $minimumTier=$OutputTokens+$protocol.outputSafetyMarginTokens+$protocol.minimumSpeedPromptTokens
    foreach($tier in $Tiers){if([int]$tier -lt $minimumTier){throw "Every tier must be at least $minimumTier tokens for this output reservation."}}
    if(-not $NeedleDepths -or @($NeedleDepths).Count -eq 0 -or @($NeedleDepths | Select-Object -Unique).Count -ne @($NeedleDepths).Count){throw 'Needle depths must be nonempty and unique.'}
    foreach($depth in $NeedleDepths){if([double]::IsNaN($depth) -or $depth -lt 0 -or $depth -gt 1){throw 'Needle depths must lie in [0,1].'}}
    $state=Get-FastLlmStatus $InstallRoot
    $binding=Get-FastLlmContextLadderBinding -State $state
    $benchLockPath=Join-Path (Get-FastLlmStateRoot $InstallRoot) 'benchmark.lock'
    if((Test-Path -LiteralPath $benchLockPath) -and ((Get-Item -LiteralPath $benchLockPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Unsafe benchmark lock.'}
    $benchLock=[IO.File]::Open($benchLockPath,'OpenOrCreate','ReadWrite','None')
    try{
        $run=@{baseUrl=$binding.baseUrl;clock=[Diagnostics.Stopwatch]::StartNew();deadlineMs=[int64]$RunDeadlineSeconds*1000
            timeoutMs=$RequestTimeoutSeconds*1000;modelId=$binding.modelId;seed=$Seed;outputTokens=$OutputTokens;repetitions=$Repetitions
            depths=[double[]]@($NeedleDepths);protocol=$protocol;tokens=$null
            usedCodes=(New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal))}
        $startedUtc=Get-FastLlmContextLadderUtcNow
        # Run binding: /props must describe exactly one slot. These are configuration refusals made before any workload request.
        $propsCall=Invoke-FastLlmContextLadderRequest -Run $run -Path '/props' -Body $null -TimeoutMs 10000
        if($propsCall.outcome -ne 'ok' -or [int]$propsCall.response.Status -ne 200){throw 'The server /props endpoint was unavailable.'}
        $props=ConvertFrom-Json -InputObject ([string]$propsCall.response.Body)
        $effectiveContext=Get-FastLlmContextLadderProperty (Get-FastLlmContextLadderProperty $props 'default_generation_settings') 'n_ctx'
        $totalSlots=Get-FastLlmContextLadderProperty $props 'total_slots'
        if(($effectiveContext -isnot [int] -and $effectiveContext -isnot [long]) -or [long]$effectiveContext -lt 1){throw 'The server did not report an effective per-slot context.'}
        if(($totalSlots -isnot [int] -and $totalSlots -isnot [long]) -or [long]$totalSlots -ne 1){throw 'The context ladder supports exactly one server slot (concurrency is W10).'}
        $effectiveContext=[int]$effectiveContext
        $plan=@(Resolve-FastLlmContextLadderTierPlan -Tiers $Tiers -EffectiveContext $effectiveContext)
        $metricsBefore=Read-FastLlmContextLadderMetrics -Run $run
        $cold=[ordered]@{metricsAvailable=[bool]$metricsBefore.available;promptTokensTotal=$metricsBefore.promptTokensTotal;tokensPredictedTotal=$metricsBefore.tokensPredictedTotal
            firstRequestAfterReady=$false;warmState='metrics-unavailable'}
        if($metricsBefore.available){
            if([double]$metricsBefore.promptTokensTotal -eq 0 -and [double]$metricsBefore.tokensPredictedTotal -eq 0){$cold.firstRequestAfterReady=$true;$cold.warmState='cold-first-request-after-ready'}
            else{$cold.warmState='server-previously-used'}
        }
        $identityChecks=New-Object System.Collections.ArrayList
        [void]$identityChecks.Add([ordered]@{after='start';matches=$true})
        $flow=@{failure=$null;abort=$null}
        $tierEntries=New-Object System.Collections.ArrayList
        $pendingError=$null
        try{
            $runnable=@($plan | Where-Object {$_.status -eq 'pending'})
            if($runnable.Count -gt 0){
                $maxPrompt=($runnable | ForEach-Object {$_.tier-$OutputTokens-$protocol.outputSafetyMarginTokens} | Measure-Object -Maximum).Maximum
                $unit='A local inference system should produce accurate useful answers. Measure speed consistently while preserving model quality. '+[Environment]::NewLine
                $repeat=[int][Math]::Ceiling($maxPrompt/16)+2
                for($attempt=0;$attempt -lt 4 -and $null -eq $run.tokens;$attempt++){
                    $tokenized=Invoke-FastLlmContextLadderRequest -Run $run -Path '/tokenize' -Body @{content=($unit*$repeat);add_special=$false} -TimeoutMs 60000
                    if($tokenized.outcome -ceq 'run-deadline'){$flow.abort='run-deadline';break}
                    if($tokenized.outcome -ne 'ok' -or [int]$tokenized.response.Status -ne 200){$flow.abort='corpus-tokenization-failed';break}
                    $corpusTokens=@((ConvertFrom-Json -InputObject ([string]$tokenized.response.Body)).tokens)
                    if($corpusTokens.Count -ge $maxPrompt){$run.tokens=$corpusTokens}else{$repeat=$repeat*2}
                }
                if($null -eq $run.tokens -and $null -eq $flow.abort){$flow.abort='corpus-tokenization-failed'}
            }
            foreach($item in $plan){
                if($item.status -ceq 'skipped-above-effective-context'){
                    [void]$tierEntries.Add([ordered]@{tier=$item.tier;source=$item.source;status='skipped-above-effective-context'})
                    continue
                }
                if($null -ne $flow.abort){[void]$tierEntries.Add([ordered]@{tier=$item.tier;source=$item.source;status='not-run-run-aborted'});continue}
                if($null -ne $flow.failure){[void]$tierEntries.Add([ordered]@{tier=$item.tier;source=$item.source;status='not-run-escalation-stopped'});continue}
                $entry=Invoke-FastLlmContextLadderTier -Run $run -Tier $item.tier -Source $item.source -Flow $flow
                $identityOk=Test-FastLlmContextLadderIdentity -Binding $binding -Current (Get-FastLlmStatus $InstallRoot)
                [void]$identityChecks.Add([ordered]@{after=('tier-'+$item.tier);matches=$identityOk})
                if(-not $identityOk){
                    $entry.status='failed'
                    $entry.failure=[ordered]@{panel='binding';reason='server-identity-changed'}
                    if($null -eq $flow.failure){$flow.failure=@{tier=$item.tier;panel='binding';reason='server-identity-changed'}}
                    $flow.abort='server-identity-changed'
                }
                [void]$tierEntries.Add($entry)
                Write-Host ("Context tier {0}: {1}" -f $item.tier,$entry.status)
            }
            $finalMatches=Test-FastLlmContextLadderIdentity -Binding $binding -Current (Get-FastLlmStatus $InstallRoot)
            [void]$identityChecks.Add([ordered]@{after='end';matches=$finalMatches})
            if(-not $finalMatches -and $null -eq $flow.abort){$flow.abort='server-identity-changed'}
        }catch{
            $pendingError=$_
            if($null -eq $flow.abort){$flow.abort='internal-error'}
        }
        $firstFailure=$null
        if($null -ne $flow.failure){$firstFailure=[ordered]@{tier=$flow.failure.tier;panel=$flow.failure.panel;reason=$flow.failure.reason}}
        $recipeCatalog=Get-FastLlmContextLadderProperty $binding.recipe 'catalogSha256'
        $parserPath=$null
        try{$parserPath=(Get-Command ConvertFrom-FastLlmBenchmarkResponse -CommandType Function).ScriptBlock.File}catch{$parserPath=$null}
        $report=[ordered]@{
            schema='fastllm.context-ladder.v1'
            resultKind='native-windows-api-context-ladder-not-full-qualification'
            startedUtc=$startedUtc;endedUtc=(Get-FastLlmContextLadderUtcNow);elapsedSeconds=[Math]::Round($run.clock.Elapsed.TotalSeconds,3)
            completed=($null -eq $flow.abort -and $null -eq $flow.failure)
            abortReason=$flow.abort
            binding=[ordered]@{runId=$binding.runId;processIdentity=[ordered]@{pid=$binding.pid;startUtcTicks=$binding.startUtcTicks}
                endpoint=$binding.endpoint;modelId=$binding.modelId;modelSha256=$binding.modelSha256;engineVersion=$binding.engineVersion
                recipe=$binding.recipe;catalogSha256=$recipeCatalog
                props=[ordered]@{effectivePerSlotContext=$effectiveContext;totalSlots=[int]$totalSlots}
                identityChecks=@($identityChecks)}
            source=[ordered]@{moduleSha256=(Get-FastLlmContextLadderFileSha256 $script:FastLlmContextLadderSourcePath)
                cliSha256=(Get-FastLlmContextLadderFileSha256 $CliSourcePath)
                responseParserSha256=(Get-FastLlmContextLadderFileSha256 $parserPath)
                responseParserFile=$(if($parserPath){Split-Path $parserPath -Leaf}else{$null})
                reusedHelpers=@('ConvertFrom-FastLlmBenchmarkResponse','Get-FastLlmPromptArtifactSha256','Get-FastLlmStatistics','Get-FastLlmStatus','Invoke-FastLlmHttp')
                promptArtifactFormat='fastllm-prompt-tokens-v1';catalogSha256=$recipeCatalog}
            methodology=[ordered]@{
                protocol=$protocol
                tiersRequested=@($Tiers);tiersEvaluated=@($plan | ForEach-Object {[ordered]@{tier=$_.tier;source=$_.source}})
                outputTokens=$OutputTokens;repetitions=$Repetitions;warmupPerTier=1;needleDepths=@($NeedleDepths)
                requestTimeoutSeconds=$RequestTimeoutSeconds;runDeadlineSeconds=$RunDeadlineSeconds;seed=$Seed;concurrency=1;slots=1
                speedPanel=[ordered]@{corpus=$protocol.speedCorpus;endpoint='/completion';promptForm='token-array-from-server-tokenize';stream=$true
                    sampling='greedy-seed';temperature=0;seed=$Seed;cachePrompt=$false;ignoreEos=$true;nPredict=$OutputTokens
                    promptTokensRule='tier - outputTokens - outputSafetyMarginTokens'
                    validEvaluatedPromptTokens='N_T or N_T+1';earlyEos='kept, excluded from the generation median'}
                retrievalPanel=[ordered]@{endpoint='/v1/chat/completions';nonThinking=$true;chatTemplateKwargs=[ordered]@{enable_thinking=$false}
                    sampling='greedy-seed';temperature=0;seed=$Seed;maxTokens=$protocol.retrievalOutputTokens;stream=$false;cachePrompt=$false
                    constructionVersion='fastllm-context-ladder-v1';constructionSha256=(Get-FastLlmContextLadderConstructionSha256)
                    codesDerivedFrom='sha256(seed, tier, depth, role)';needleLineRule='round(depth x lineCount), midpoint away from zero'
                    distractorLineFraction=$protocol.distractorLineFraction
                    occupancyMeasurement='/apply-template then /tokenize (add_special=true, parse_special=true), bounded search'
                    occupancyWindow='[0.90 x (tier - 32 - 64), tier - 32 - 64] tokens'
                    usageToleranceTokens=$protocol.occupancyUsageToleranceTokens;maxOccupancyProbes=$protocol.maxOccupancyProbes
                    grader='trim; remove at most one trailing period; ordinal case-sensitive equality; reasoning field present is invalid-mode; thresholds are not tunable'}
                coldWarm=$cold;metricsBefore=$metricsBefore}
            tiers=@($tierEntries)
            stopping=[ordered]@{escalationStopped=($null -ne $flow.failure -or $null -ne $flow.abort);firstFailure=$firstFailure;abortReason=$flow.abort
                rule='a failed tier stops escalation; the failure is retained, never retried, and context, output length and quantization are never reduced'}
            privacy='No prompt, filler or completion text is stored; prompt and response content appear only as SHA-256 digests and lengths.'
            qualification=[ordered]@{approved=$false;qualityEvaluation=$false;physicalResidency=$false;peakVramMeasured=$false;soak=$false;exclusiveWorkloadConfirmed=$false;concurrency=$false}
        }
        Write-FastLlmContextLadderReport -Path $outputFull -Report $report
        if($null -ne $pendingError){throw $pendingError}
        return $report
    }finally{$benchLock.Dispose()}
}
