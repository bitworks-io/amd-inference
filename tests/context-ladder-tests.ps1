#requires -Version 5.1
# Mock-only tests for the W11 context-ladder tool. No engine, model or GPU is used. The in-process loopback mock is
# tests/helpers/ContextLadderMockServer.cs (separate from MockServer.cs). The tool runs against a fake supervised run state.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force -PassThru -ErrorAction Stop
$source=Join-Path $root 'src/FastLlm.ContextLadder.ps1'
$cliPath=Join-Path $root 'tools/context-ladder.ps1'
$script:count=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:count++;Write-Host "PASS: $Message"}
function Reject([scriptblock]$Block,[string]$Pattern,[string]$Message){
    $text=$null
    try{& $Block | Out-Null}catch{$text=$_.Exception.Message}
    Check ($null -ne $text -and $text -match $Pattern) "$Message (got: $text)"
}
# Runs a block inside the FastLlm module scope with the ladder source dot-sourced, as the CLI does.
function Invoke-InModule([scriptblock]$Block,[object[]]$Arguments=@()){
    $bound=$module.NewBoundScriptBlock($Block)
    return & $module {param($src,$blk,$argv) . $src;& $blk @argv} $source $bound $Arguments
}
function Get-Sha256Text([string]$Text){
    $hasher=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant()}finally{$hasher.Dispose()}
}

Add-Type -Path (Join-Path $PSScriptRoot 'helpers/ContextLadderMockServer.cs')
$mock=[FastLlmTests.ContextLadderMockServer]
$port=$mock::Start()
# Compile the loopback HTTP host once, outside any timed run-deadline test.
& $module {Initialize-FastLlmProcessHost}

$work=Join-Path ([IO.Path]::GetTempPath()) ('context-ladder-tests-'+[Guid]::NewGuid().ToString('N'))
$installRoot=Join-Path $work 'install'
New-Item -ItemType Directory -Path $work -Force | Out-Null
$runId=('a'*32)
$otherRunId=('b'*32)
$statusPath=Join-Path $installRoot 'state/status.json'
$lock=$null
$script:caseNumber=0

function Write-LadderStatus([string]$Id=$runId,[string]$Phase='ready'){
    $state=[ordered]@{schemaVersion=1;runId=$Id;phase=$Phase;endpoint="http://127.0.0.1:$port/v1";modelId='synthetic-mock-only'
        modelSha256=('0'*64);engineVersion='mock-only'
        processIdentity=[ordered]@{pid=4242;startUtcTicks=[long]638000000000000000}
        recipe=[ordered]@{catalogSha256=('1'*64);engineSha256=('2'*64);backend='mock';contextSize=4096;slots=1;cacheTypeK='f16';cacheTypeV='f16';flashAttention='auto'}}
    & $module {param($r,$s) Write-FastLlmState -InstallRoot $r -State $s} $installRoot $state
}
function New-Case{$mock::Reset();Write-LadderStatus $runId}
function Run-Ladder([hashtable]$Overrides=@{}){
    $script:caseNumber++
    $out=Join-Path $work ("report-$($script:caseNumber).json")
    $params=@{InstallRoot=$installRoot;OutputPath=$out;Tiers=[int[]]@(256,512);OutputTokens=64;Repetitions=2;RequestTimeoutSeconds=20;RunDeadlineSeconds=300;CliSourcePath=$cliPath}
    foreach($key in @($Overrides.Keys)){$params[$key]=$Overrides[$key]}
    $failure=$null
    try{& $module {param($src,$p) . $src;Invoke-FastLlmContextLadder @p | Out-Null} $source $params}catch{$failure=$_.Exception.Message}
    $raw=$null;$report=$null
    if(Test-Path -LiteralPath $out){$raw=[IO.File]::ReadAllText($out);$report=ConvertFrom-Json -InputObject $raw}
    return [pscustomobject]@{failure=$failure;path=$out;raw=$raw;report=$report}
}
function Assert-NoText($Result,[string]$Label){
    $offenders=@()
    foreach($code in $mock::GetSeenCodes()){if($Result.raw.Contains($code)){$offenders+=$code}}
    foreach($phrase in @('crate in bay','holds copper','holds steel','access code','locker code','badge code','dock code','What is the vault','Reply with the code',
        'A local inference system','accurate useful answers','preserving model quality','private thinking','TPLBEGIN','TPLEND')){
        if($Result.raw.Contains($phrase)){$offenders+=$phrase}
    }
    Check ($offenders.Count -eq 0 -and $mock::GetSeenCodes().Count -gt 0) "$Label report holds no needle, distractor, filler or completion text (offenders: $($offenders -join ','))"
}
function Assert-TierFailed($Result,[string]$Reason,[string]$Label){
    $r=$Result.report
    Check ($null -eq $Result.failure -and $null -ne $r) "$Label wrote a report without throwing (got: $($Result.failure))"
    Check ($r.tiers[0].status -eq 'failed' -and $r.tiers[0].failure.reason -eq $Reason) "$Label fails the tier with reason $Reason (got: $($r.tiers[0].status)/$($r.tiers[0].failure.reason))"
    Check ($r.tiers[1].status -eq 'not-run-escalation-stopped') "$Label does not escalate"
    Check ($r.stopping.escalationStopped -eq $true -and $r.stopping.firstFailure.tier -eq 256 -and $r.stopping.firstFailure.reason -eq $Reason -and $r.completed -eq $false) "$Label records the first failure"
    Check (@($mock::GetPromptLengths() | Where-Object {$_ -eq 384}).Count -eq 0) "$Label never sent the next tier's prompt"
}

try{
    $lock=& $module {param($r) Enter-FastLlmOperation $r} $installRoot
    Write-LadderStatus $runId

    # ------------------------------------------------------------ pure: tier plan, grading, construction, search, metrics, identity
    $ceilingPlan=@(Invoke-InModule {param($t,$e) Resolve-FastLlmContextLadderTierPlan -Tiers $t -EffectiveContext $e} @(([int[]]@(1024,2048,4096,8192,16384,32768)),12000))
    Check ((@($ceilingPlan | ForEach-Object {$_.tier}) -join ',') -eq '1024,2048,4096,8192,12000,16384,32768') 'an n_ctx of 12000 adds a 12000 tier between listed tiers'
    $inserted=@($ceilingPlan | Where-Object {$_.tier -eq 12000})[0]
    Check ($inserted.source -eq 'catalog-ceiling' -and $inserted.status -eq 'pending') 'the inserted catalog-ceiling tier is runnable'
    Check ((@($ceilingPlan | Where-Object {$_.status -eq 'skipped-above-effective-context'} | ForEach-Object {$_.tier}) -join ',') -eq '16384,32768') 'tiers above the effective context are recorded as skipped'
    $equalPlan=@(Invoke-InModule {param($t,$e) Resolve-FastLlmContextLadderTierPlan -Tiers $t -EffectiveContext $e} @(([int[]]@(1024,2048,4096)),2048))
    Check (@($equalPlan).Count -eq 3 -and @($equalPlan | Where-Object {$_.tier -eq 2048})[0].status -eq 'pending') 'a listed tier equal to the effective context runs and inserts nothing'
    $lowPlan=@(Invoke-InModule {param($t,$e) Resolve-FastLlmContextLadderTierPlan -Tiers $t -EffectiveContext $e} @(([int[]]@(1024,2048)),512))
    $highPlan=@(Invoke-InModule {param($t,$e) Resolve-FastLlmContextLadderTierPlan -Tiers $t -EffectiveContext $e} @(([int[]]@(1024,2048)),65536))
    Check (@($lowPlan).Count -eq 2 -and @($highPlan).Count -eq 2) 'an effective context outside the listed range is not inserted'

    $grades=Invoke-InModule {
        $g=[ordered]@{}
        $g.exact=Get-FastLlmContextLadderGrade -Content 'QX-7314' -ExpectedCode 'QX-7314' -ReasoningPresent $false
        $g.period=Get-FastLlmContextLadderGrade -Content 'QX-7314.' -ExpectedCode 'QX-7314' -ReasoningPresent $false
        $g.padded=Get-FastLlmContextLadderGrade -Content "  QX-7314.`n" -ExpectedCode 'QX-7314' -ReasoningPresent $false
        $g.twoPeriods=Get-FastLlmContextLadderGrade -Content 'QX-7314..' -ExpectedCode 'QX-7314' -ReasoningPresent $false
        $g.lower=Get-FastLlmContextLadderGrade -Content 'qx-7314' -ExpectedCode 'QX-7314' -ReasoningPresent $false
        $g.distractor=Get-FastLlmContextLadderGrade -Content 'KT-2290' -ExpectedCode 'QX-7314' -ReasoningPresent $false
        $g.sentence=Get-FastLlmContextLadderGrade -Content 'The code is QX-7314' -ExpectedCode 'QX-7314' -ReasoningPresent $false
        $g.empty=Get-FastLlmContextLadderGrade -Content '' -ExpectedCode 'QX-7314' -ReasoningPresent $false
        $g.nullContent=Get-FastLlmContextLadderGrade -Content $null -ExpectedCode 'QX-7314' -ReasoningPresent $false
        $g.reasoning=Get-FastLlmContextLadderGrade -Content 'QX-7314' -ExpectedCode 'QX-7314' -ReasoningPresent $true
        $g
    }
    Check ($grades.exact -eq 'correct' -and $grades.period -eq 'correct' -and $grades.padded -eq 'correct') 'grader accepts the code, a trailing period and surrounding whitespace'
    Check ($grades.twoPeriods -eq 'incorrect' -and $grades.lower -eq 'incorrect' -and $grades.sentence -eq 'incorrect') 'grader removes at most one period and is case-sensitive and exact'
    Check ($grades.distractor -eq 'incorrect' -and $grades.empty -eq 'incorrect' -and $grades.nullContent -eq 'incorrect') 'a distractor code and an empty response are incorrect'
    Check ($grades.reasoning -eq 'invalid-mode') 'a present reasoning field is invalid-mode even with the right code'

    $construction=Invoke-InModule {
        $a=New-FastLlmContextLadderCase -Seed 42 -Tier 1024 -Depth 0.5 -LineCount 40 -NeedleCode 'QX-7314'
        $b=New-FastLlmContextLadderCase -Seed 42 -Tier 1024 -Depth 0.5 -LineCount 40 -NeedleCode 'QX-7314'
        $c=New-FastLlmContextLadderCase -Seed 42 -Tier 1024 -Depth 0.5 -LineCount 300 -NeedleCode 'QX-7314'
        $d=New-FastLlmContextLadderCase -Seed 42 -Tier 1024 -Depth 0.5 -LineCount 5 -NeedleCode 'QX-7314'
        $e=New-FastLlmContextLadderCase -Seed 42 -Tier 1024 -Depth 0 -LineCount 10 -NeedleCode 'QX-7314'
        $f=New-FastLlmContextLadderCase -Seed 42 -Tier 1024 -Depth 1 -LineCount 10 -NeedleCode 'QX-7314'
        $codes=@()
        foreach($tier in @(1024,2048,4096)){foreach($depth in @(0.1,0.5,0.9)){$codes+=Get-FastLlmContextLadderCode -Seed 42 -Tier $tier -Depth $depth -Role 'needle' -Index 0 -Attempt 0}}
        [pscustomobject]@{a=$a;b=$b;c=$c;d=$d;e=$e;f=$f;codes=$codes}
    }
    Check ($construction.a.content -ceq $construction.b.content) 'case construction is deterministic from the seed'
    $lines=@($construction.a.content -split "`n")
    Check ($lines.Count -eq 42 -and $lines[20] -ceq 'The vault access code is QX-7314.' -and $construction.a.needleLineIndex -eq 20) 'the needle sits at line round(depth x lineCount) with the question last'
    Check ($construction.d.needleLineIndex -eq 3) 'midpoint rounding is away from zero (2.5 -> 3)'
    Check ($construction.e.needleLineIndex -eq 0 -and $construction.f.needleLineIndex -eq 10) 'depth 0 and depth 1 bracket the filler'
    Check ($construction.a.distractorCount -eq 1 -and $construction.c.distractorCount -eq 3 -and @($construction.c.distractorCodes).Count -eq 3) 'about 1% of filler lines carry other codes (at least one)'
    Check (@($construction.c.distractorCodes | Where-Object {$_ -ceq 'QX-7314'}).Count -eq 0 -and (@($construction.c.distractorCodes | Select-Object -Unique).Count -eq 3)) 'distractor codes differ from the needle and from each other'
    Check (@($construction.codes | Select-Object -Unique).Count -eq 9 -and @($construction.codes | Where-Object {$_ -cnotmatch '^[A-Z]{2}-[0-9]{4}$'}).Count -eq 0) 'needle codes differ for every tier and depth'

    $search=Invoke-InModule {
        $results=@()
        foreach($max in @(160,416,928,1952,4000,8000,30000)){
            foreach($slope in @(7,11,14,19,23)){
                foreach($offset in @(0,13,60)){
                    # A window narrower than one step of the synthetic count can legitimately contain no line count.
                    if(0.1*$max -lt $slope){continue}
                    $counter=@{n=0}
                    $measure={param($lineCount) $counter.n=$counter.n+1;return ($slope*$lineCount+$offset)}.GetNewClosure()
                    $r=Find-FastLlmContextLadderLineCount -MaxTokens $max -LowerFraction 0.9 -Measure $measure -MaxProbes 12
                    $results+=[pscustomobject]@{max=$max;slope=$slope;offset=$offset;found=$r.found;count=$r.tokenCount;probes=$r.probes;calls=$counter.n}
                }
            }
        }
        $step={param($lineCount) if($lineCount -lt 50){return 100}else{return 1000}}
        $unreachable=Find-FastLlmContextLadderLineCount -MaxTokens 500 -LowerFraction 0.9 -Measure $step -MaxProbes 12
        [pscustomobject]@{results=$results;unreachable=$unreachable}
    }
    $searchBad=@($search.results | Where-Object {-not $_.found -or $_.count -gt $_.max -or $_.count -lt 0.9*$_.max -or $_.probes -gt 12 -or $_.calls -ne $_.probes})
    Check ($searchBad.Count -eq 0) "the occupancy search always lands inside [0.90 x max, max] within 12 probes ($($search.results.Count) scenarios; bad: $($searchBad.Count))"
    Check ($search.unreachable.found -eq $false -and $search.unreachable.reason -eq 'window-unreachable' -and $search.unreachable.probes -le 12) 'an unreachable occupancy window is reported, not guessed'

    $metrics=Invoke-InModule {ConvertFrom-FastLlmContextLadderMetrics -Text "# HELP x y`n# TYPE llamacpp:prompt_tokens_total counter`nllamacpp:prompt_tokens_total 12`nllamacpp:tokens_predicted_total{a=`"b`"} 3.5`nllamacpp:kv_cache_usage_ratio 0.5`nother 9`n"}
    Check ($metrics.available -and $metrics.promptTokensTotal -eq 12 -and $metrics.tokensPredictedTotal -eq 3.5 -and $metrics.kvCacheUsageRatio -eq 0.5 -and $null -eq $metrics.kvCacheTokens) 'Prometheus text is parsed and absent fields stay null'

    $identity=Invoke-InModule {
        $binding=[pscustomobject]@{runId=('a'*32);pid=1;startUtcTicks=[long]5}
        $ok=[pscustomobject]@{active=$true;phase='ready';runId=('a'*32);processIdentity=[pscustomobject]@{pid=1;startUtcTicks=[long]5}}
        $runChanged=[pscustomobject]@{active=$true;phase='ready';runId=('b'*32);processIdentity=[pscustomobject]@{pid=1;startUtcTicks=[long]5}}
        $pidChanged=[pscustomobject]@{active=$true;phase='ready';runId=('a'*32);processIdentity=[pscustomobject]@{pid=2;startUtcTicks=[long]5}}
        $ticksChanged=[pscustomobject]@{active=$true;phase='ready';runId=('a'*32);processIdentity=[pscustomobject]@{pid=1;startUtcTicks=[long]6}}
        $phase=[pscustomobject]@{active=$true;phase='stopped';runId=('a'*32);processIdentity=[pscustomobject]@{pid=1;startUtcTicks=[long]5}}
        $inactive=[pscustomobject]@{active=$false;phase='ready';runId=('a'*32);processIdentity=[pscustomobject]@{pid=1;startUtcTicks=[long]5}}
        [pscustomobject]@{ok=(Test-FastLlmContextLadderIdentity $binding $ok);run=(Test-FastLlmContextLadderIdentity $binding $runChanged)
            pid=(Test-FastLlmContextLadderIdentity $binding $pidChanged);ticks=(Test-FastLlmContextLadderIdentity $binding $ticksChanged)
            phase=(Test-FastLlmContextLadderIdentity $binding $phase);inactive=(Test-FastLlmContextLadderIdentity $binding $inactive)}
    }
    Check ($identity.ok -and -not $identity.run -and -not $identity.pid -and -not $identity.ticks -and -not $identity.phase -and -not $identity.inactive) 'identity requires the same run id, pid, start ticks, ready phase and an active supervisor'

    # ------------------------------------------------------------ happy path (also N_T, digest stability, privacy, cold state)
    New-Case
    $ok=Run-Ladder
    $r=$ok.report
    Check ($null -eq $ok.failure -and $null -ne $r) "a clean mock ladder completes (got: $($ok.failure))"
    Check ($r.schema -eq 'fastllm.context-ladder.v1' -and $r.resultKind -eq 'native-windows-api-context-ladder-not-full-qualification' -and $r.completed -eq $true -and $null -eq $r.abortReason) 'report schema, result kind and completion'
    $falseFlags=@('approved','qualityEvaluation','physicalResidency','peakVramMeasured','soak','exclusiveWorkloadConfirmed','concurrency')
    Check (@($falseFlags | Where-Object {$r.qualification.$_ -ne $false}).Count -eq 0) 'every qualification flag is false, including physicalResidency'
    Check ($r.tiers.Count -eq 2 -and $r.tiers[0].status -eq 'passed' -and $r.tiers[1].status -eq 'passed') 'both tiers pass'
    Check ($r.tiers[0].speed.promptTokensTarget -eq 128 -and $r.tiers[1].speed.promptTokensTarget -eq 384) 'N_T = tier - output - 64'
    Check ((@($mock::GetPromptLengths()) -join ',') -eq '128,128,128,384,384,384') 'the server received exact token arrays of N_T tokens (1 warmup + 2 measured per tier)'
    $expectedDigest=Invoke-InModule {Get-FastLlmPromptArtifactSha256 @(1..128)}
    Check ($r.tiers[0].speed.promptArtifact.sha256 -eq $expectedDigest -and $r.tiers[0].speed.promptArtifact.format -eq 'fastllm-prompt-tokens-v1' -and $r.tiers[0].speed.promptArtifact.tokenCount -eq 128) 'the prompt artifact digest is the producer digest of the N_T token ids'
    $s=$r.tiers[0].speed.samples
    Check ($s.Count -eq 3 -and $s[0].kind -eq 'warmup' -and $s[1].kind -eq 'measured' -and @($s | Where-Object {-not $_.valid -or $_.classification -ne 'ok' -or $_.evaluatedPromptTokens -ne 128 -or $_.predictedTokens -ne 64}).Count -eq 0) 'one warmup then measured samples, all valid, with evaluated and predicted tokens'
    Check ($null -ne $s[1].startUtc -and $null -ne $s[1].endUtc -and $s[1].truncated -eq $false -and $s[1].stopReason -eq 'limit' -and $s[1].completionMs -gt 0 -and $s[1].timeToFirstTextMs -gt 0 -and $s[1].prefillTokensPerSecond -gt 0 -and $s[1].generationTokensPerSecond -gt 0) 'each sample records its window, truncation, stop reason, latencies and rates'
    $sum=$r.tiers[0].speed.summary
    Check ($r.methodology.speedPanel.ignoreEos -eq $true) 'the speed panel sends ignore_eos like the producer (fixed output length)'
    Check ($sum.generation.count -eq 2 -and $sum.prefill.count -eq 2 -and $null -ne $sum.generation.median -and $null -ne $sum.generation.minimum -and $null -ne $sum.generation.maximum -and $sum.earlyEosCount -eq 0) 'summaries use the producer statistics helper with counts'
    foreach($tierEntry in $r.tiers){
        $maximum=$tierEntry.tier-32-64
        Check ($tierEntry.retrieval.cases.Count -eq 3 -and @($tierEntry.retrieval.cases | Where-Object {$_.grade -ne 'correct'}).Count -eq 0) "tier $($tierEntry.tier) has three correct retrieval cases"
        Check (@($tierEntry.retrieval.cases | Where-Object {$_.measuredPromptTokens -gt $maximum -or $_.measuredPromptTokens -lt 0.9*$maximum -or $_.usageDifference -ne 0 -or $_.occupancyProbes -gt 12}).Count -eq 0) "tier $($tierEntry.tier) retrieval occupancy is inside the window with matching usage"
        Check ((@($tierEntry.retrieval.cases | ForEach-Object {$_.depth}) -join ',') -eq '0.1,0.5,0.9' -and @($tierEntry.retrieval.cases | Where-Object {[Math]::Round($_.depth*$_.lineCount,[MidpointRounding]::AwayFromZero) -ne $_.needleLineIndex}).Count -eq 0) "tier $($tierEntry.tier) needle line indexes follow round(depth x lineCount)"
    }
    $digests=@($r.tiers | ForEach-Object {$_.retrieval.cases} | ForEach-Object {$_.expectedCodeSha256})
    Check ((@($digests | Select-Object -Unique).Count -eq 6) -and @($digests | Where-Object {$_ -notmatch '^[0-9a-f]{64}$'}).Count -eq 0) 'expected codes are stored only as digests and differ for every tier and depth'
    Check ($r.methodology.coldWarm.firstRequestAfterReady -eq $true -and $r.methodology.coldWarm.warmState -eq 'cold-first-request-after-ready' -and $r.methodology.metricsBefore.available -eq $true) 'zero metric totals mark the first request as cold'
    Check ($r.tiers[0].metricsAfter.available -eq $true -and $r.tiers[0].metricsAfter.kvCacheTokens -eq 512 -and $r.tiers[0].metricsAfter.label -eq 'engine-reported-not-residency' -and $r.tiers[1].metricsAfter.promptTokensTotal -gt 0) 'metrics are re-read after every tier and labelled engine-reported'
    Check (@($r.binding.identityChecks | ForEach-Object {$_.after}) -join ',' -eq 'start,tier-256,tier-512,end' -and @($r.binding.identityChecks | Where-Object {-not $_.matches}).Count -eq 0) 'identity is checked at start, after every tier and at the end'
    Check ($r.binding.runId -eq $runId -and $r.binding.processIdentity.pid -eq 4242 -and $r.binding.modelSha256 -eq ('0'*64) -and $r.binding.catalogSha256 -eq ('1'*64) -and $r.binding.recipe.flashAttention -eq 'auto' -and $r.binding.props.effectivePerSlotContext -eq 4096 -and $r.binding.props.totalSlots -eq 1) 'binding block records run, process, model, recipe, catalog and /props'
    Check ($r.source.moduleSha256 -eq (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -and
           $r.source.cliSha256 -eq (Get-FileHash -LiteralPath $cliPath -Algorithm SHA256).Hash.ToLowerInvariant() -and
           $r.source.responseParserSha256 -eq (Get-FileHash -LiteralPath (Join-Path $root 'src/FastLlm.Benchmark.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()) 'source block carries the module, CLI and loaded parser SHA-256 values'
    $m=$r.methodology
    Check ($m.protocol.outputSafetyMarginTokens -eq 64 -and $m.protocol.retrievalOutputTokens -eq 32 -and $m.protocol.occupancyLowerFraction -eq 0.9 -and $m.protocol.occupancyUsageToleranceTokens -eq 4 -and $m.protocol.maxOccupancyProbes -eq 12 -and
           $m.retrievalPanel.nonThinking -eq $true -and $m.retrievalPanel.chatTemplateKwargs.enable_thinking -eq $false -and $m.retrievalPanel.maxTokens -eq 32 -and $m.retrievalPanel.cachePrompt -eq $false -and $m.speedPanel.cachePrompt -eq $false -and $m.speedPanel.seed -eq 42) 'margins, thresholds and request settings are recorded'
    Assert-NoText $ok 'clean ladder'
    $repeat=Run-Ladder
    Check ($repeat.report.tiers[0].speed.promptArtifact.sha256 -eq $r.tiers[0].speed.promptArtifact.sha256 -and $repeat.report.tiers[1].speed.promptArtifact.sha256 -eq $r.tiers[1].speed.promptArtifact.sha256) 'prompt artifact digests are stable across runs'
    Check ($mock::CountLog('/metrics') -ge 3 -and $mock::CountLog('/apply-template') -ge 6) 'metrics and apply-template were exercised'
    $codesA=@($r.tiers | ForEach-Object {$_.retrieval.cases} | ForEach-Object {$_.promptSha256})
    $codesB=@($repeat.report.tiers | ForEach-Object {$_.retrieval.cases} | ForEach-Object {$_.promptSha256})
    Check (($codesA -join ',') -eq ($codesB -join ',')) 'retrieval prompts are reproducible from the seed'

    # warm state and missing metrics
    New-Case;$mock::MetricsPromptTotal=500
    $warm=Run-Ladder @{Tiers=[int[]]@(256);NeedleDepths=[double[]]@(0.5);Repetitions=1}
    Check ($warm.report.methodology.coldWarm.firstRequestAfterReady -eq $false -and $warm.report.methodology.coldWarm.warmState -eq 'server-previously-used') 'non-zero totals are reported as server-previously-used'
    New-Case;$mock::MetricsEnabled=$false
    $noMetrics=Run-Ladder @{Tiers=[int[]]@(256);NeedleDepths=[double[]]@(0.5);Repetitions=1}
    Check ($noMetrics.report.completed -eq $true -and $noMetrics.report.methodology.coldWarm.metricsAvailable -eq $false -and $noMetrics.report.tiers[0].metricsAfter.available -eq $false) 'unavailable metrics are recorded without failing the run'

    # ------------------------------------------------------------ tier filtering and ceiling insertion against /props
    New-Case;$mock::NContext=700
    $ceil=Run-Ladder @{Tiers=[int[]]@(256,512,1024);NeedleDepths=[double[]]@(0.5);Repetitions=1}
    $ct=@($ceil.report.tiers)
    Check ((@($ct | ForEach-Object {$_.tier}) -join ',') -eq '256,512,700,1024' -and $ct[2].source -eq 'catalog-ceiling' -and $ct[2].status -eq 'passed') 'a 700-token effective context inserts and runs a 700 tier'
    Check ($ct[3].status -eq 'skipped-above-effective-context' -and $null -eq $ct[3].PSObject.Properties['speed'] -and @($mock::GetPromptLengths() | Where-Object {$_ -eq 896}).Count -eq 0 -and @($mock::GetPromptLengths() | Where-Object {$_ -eq 572}).Count -gt 0) 'the tier above the effective context is recorded and never run'
    Check ($ceil.report.completed -eq $true -and $ceil.report.stopping.escalationStopped -eq $false) 'a skipped tier is a configuration refusal, not a failure'

    # ------------------------------------------------------------ speed-panel failures stop escalation
    New-Case;$mock::PromptNDelta=1
    $plus1=Run-Ladder
    Check ($plus1.report.tiers[0].status -eq 'passed') 'an evaluated prompt of N_T + 1 tokens is accepted'
    New-Case;$mock::PromptNDelta=5
    $mismatch=Run-Ladder
    Assert-TierFailed $mismatch 'evaluated-prompt-mismatch' 'evaluated-prompt mismatch'
    Check (@($mismatch.report.tiers[0].speed.samples | Where-Object {$_.status -eq 'not-run-after-failure'}).Count -eq 2 -and @($mismatch.report.tiers[0].retrieval.cases | Where-Object {$_.status -eq 'not-run-after-failure'}).Count -eq 3) 'the remaining cases of the failed tier are not-run-after-failure'
    New-Case;$mock::Truncated=$true
    Assert-TierFailed (Run-Ladder) 'truncated' 'a truncated sample'
    New-Case;$mock::ContextShift=$true
    Assert-TierFailed (Run-Ladder) 'context-shift' 'a context shift'
    New-Case;$mock::CompletionStatus=500
    Assert-TierFailed (Run-Ladder) 'http-status' 'an HTTP 500'
    New-Case;$mock::PredictedNOverride=10
    Assert-TierFailed (Run-Ladder) 'short-output-non-eos' 'a short non-eos output'
    New-Case;$mock::PredictedNOverride=200
    Assert-TierFailed (Run-Ladder) 'output-exceeds-request' 'an output longer than requested'
    New-Case;$mock::CompletionDelayMs=2500
    $timeout=Run-Ladder @{RequestTimeoutSeconds=1}
    Assert-TierFailed $timeout 'request-timeout' 'a request timeout'
    Check ($timeout.report.tiers[0].speed.samples[0].status -eq 'request-failed' -and $timeout.report.tiers[0].speed.samples[0].errorCode -eq 'request-timeout') 'the timed-out request is recorded with a fixed code'
    $mock::CompletionDelayMs=0

    # early EOS is kept but excluded from the generation median
    New-Case;$mock::EarlyEosOrdinal=3
    $eos=Run-Ladder @{Tiers=[int[]]@(256);Repetitions=3;NeedleDepths=[double[]]@(0.5)}
    $es=$eos.report.tiers[0].speed.samples
    Check ($eos.report.tiers[0].status -eq 'passed' -and $es.Count -eq 4 -and @($es | Where-Object {$_.classification -eq 'early-eos'}).Count -eq 1) 'an early-eos sample is valid and kept'
    $eosSample=@($es | Where-Object {$_.classification -eq 'early-eos'})[0]
    Check ($eosSample.valid -eq $true -and $eosSample.stopReason -eq 'eos' -and $eosSample.predictedTokens -eq 32) 'the early-eos sample records its stop reason and predicted tokens'
    Check ($eos.report.tiers[0].speed.summary.earlyEosCount -eq 1 -and $eos.report.tiers[0].speed.summary.generation.count -eq 2 -and $eos.report.tiers[0].speed.summary.prefill.count -eq 3 -and $eos.report.tiers[0].speed.summary.measuredValidCount -eq 3) 'the generation median excludes early-eos while other summaries keep it'

    # ------------------------------------------------------------ retrieval occupancy, template availability, grading end to end
    New-Case;$mock::UsageDelta=6
    $usage=Run-Ladder
    Assert-TierFailed $usage 'usage-mismatch' 'a usage difference of 6'
    Check ($usage.report.tiers[0].retrieval.cases[0].grade -eq 'invalid-occupancy' -and $usage.report.tiers[0].retrieval.cases[0].usageDifference -eq 6 -and @($usage.report.tiers[0].retrieval.cases | Where-Object {$_.status -eq 'not-run-after-failure'}).Count -eq 2) 'a usage difference over 4 is invalid-occupancy'
    New-Case;$mock::UsageDelta=4
    $four=Run-Ladder @{Tiers=[int[]]@(256);Repetitions=1}
    Check ($four.report.tiers[0].status -eq 'passed' -and $four.report.tiers[0].retrieval.cases[0].usageDifference -eq 4) 'a usage difference of exactly 4 is accepted'
    New-Case;$mock::UsageDelta=-5
    Assert-TierFailed (Run-Ladder) 'usage-mismatch' 'a usage difference of -5'

    New-Case;$mock::ApplyTemplateStatus=404
    $noTemplate=Run-Ladder
    $nr=$noTemplate.report
    Check ($null -eq $noTemplate.failure -and $nr.tiers[0].status -eq 'occupancy-unverifiable' -and $nr.tiers[0].retrieval.cases[0].grade -eq 'invalid-occupancy-unverifiable') 'a missing /apply-template makes the tier occupancy-unverifiable'
    Check ($nr.tiers[1].status -eq 'not-run-escalation-stopped' -and $nr.stopping.firstFailure.reason -eq 'occupancy-unverifiable' -and @($nr.tiers[0].speed.samples | Where-Object {$_.status -eq 'ran'}).Count -eq 3) 'occupancy-unverifiable stops escalation after the speed panel was recorded'

    foreach($mode in @(@('period','correct'),@('whitespace','correct'),@('lower','incorrect'),@('twoperiods','incorrect'),@('distractor','incorrect'),@('wrong','incorrect'),@('empty','incorrect'),@('reasoning','invalid-mode'))){
        New-Case;$mock::ChatMode=$mode[0]
        $g=Run-Ladder @{Tiers=[int[]]@(256);Repetitions=1;NeedleDepths=[double[]]@(0.5)}
        Check ($g.report.tiers[0].retrieval.cases[0].grade -eq $mode[1]) "mock answer mode '$($mode[0])' grades as $($mode[1]) (got: $($g.report.tiers[0].retrieval.cases[0].grade))"
        if($mode[1] -eq 'invalid-mode'){Check ($g.report.tiers[0].retrieval.cases[0].reasoningPresent -eq $true -and $g.report.tiers[0].status -eq 'failed') 'reasoning present is recorded and fails the tier'}
        if($mode[0] -eq 'reasoning' -or $mode[0] -eq 'distractor'){Assert-NoText $g "mode $($mode[0])"}
    }
    New-Case;$mock::ChatMode='wrong'
    $wrong=Run-Ladder
    Assert-TierFailed $wrong 'wrong-answer' 'an incorrect retrieval answer'
    Check ($wrong.report.tiers[0].retrieval.cases[0].grade -eq 'incorrect' -and @($wrong.report.tiers[0].retrieval.cases | Where-Object {$_.status -eq 'not-run-after-failure'}).Count -eq 2) 'the other depths are not run after an incorrect answer'
    New-Case;$mock::ChatStatus=500
    $chat500=Run-Ladder
    Assert-TierFailed $chat500 'http-status' 'a chat HTTP 500'
    Check ($chat500.report.tiers[0].retrieval.cases[0].grade -eq 'invalid-request') 'a chat HTTP 500 is an invalid-request case'
    New-Case;$mock::ChatDelayMs=2500
    $chatSlow=Run-Ladder @{RequestTimeoutSeconds=1}
    Assert-TierFailed $chatSlow 'request-timeout' 'a chat timeout'
    $mock::ChatDelayMs=0

    New-Case;$mock::TokenizeStatus=500
    $noTokenize=Run-Ladder
    Check ($null -eq $noTokenize.failure -and $noTokenize.report.abortReason -eq 'corpus-tokenization-failed' -and $noTokenize.report.tiers[0].status -eq 'not-run-run-aborted' -and $noTokenize.report.completed -eq $false) 'a failed corpus tokenization aborts with a partial report'

    # ------------------------------------------------------------ run binding, abort and deadline
    New-Case;$mock::IdentityChangeAfter=6;$mock::StatusPath=$statusPath;$mock::IdentityFrom=$runId;$mock::IdentityTo=$otherRunId
    $changed=Run-Ladder
    $cr=$changed.report
    Check ($null -eq $changed.failure -and $null -ne $cr -and $cr.abortReason -eq 'server-identity-changed' -and $cr.completed -eq $false) 'an identity change aborts with server-identity-changed and still writes a partial report'
    Check ($cr.tiers[0].status -eq 'failed' -and $cr.tiers[0].failure.reason -eq 'server-identity-changed' -and $cr.tiers[1].status -eq 'not-run-run-aborted') 'the tier whose check fails is failed and the next tier is not run'
    Check (@($cr.binding.identityChecks | Where-Object {-not $_.matches}).Count -ge 1 -and $cr.stopping.abortReason -eq 'server-identity-changed') 'the failed identity check is recorded'
    Write-LadderStatus $runId

    New-Case;$mock::CompletionDelayMs=600
    $deadline=Run-Ladder @{RunDeadlineSeconds=1}
    Check ($null -eq $deadline.failure -and $deadline.report.abortReason -eq 'run-deadline' -and $deadline.report.completed -eq $false) 'the run deadline aborts with a partial report'
    Check ($deadline.report.tiers[0].status -eq 'aborted' -and $deadline.report.tiers[1].status -eq 'not-run-run-aborted') 'the in-flight tier is aborted and later tiers are not run'
    $mock::CompletionDelayMs=0

    New-Case
    $existing=Join-Path $work 'existing.json'
    [IO.File]::WriteAllText($existing,'keep')
    $beforeLog=$mock::GetLog().Count
    $overwrite=Run-Ladder @{OutputPath=$existing}
    Check ($null -ne $overwrite.failure -and $overwrite.failure -match 'already exists' -and [IO.File]::ReadAllText($existing) -eq 'keep' -and $mock::GetLog().Count -eq $beforeLog) 'an existing output file is refused untouched before any request'
    Check (@(Get-ChildItem -LiteralPath $work -Filter '*.tmp' -Force).Count -eq 0) 'no temporary report files are left behind'

    New-Case;$mock::TotalSlots=2
    $slots=Run-Ladder
    Check ($null -ne $slots.failure -and $slots.failure -match 'exactly one server slot' -and $null -eq $slots.report -and $mock::CountLog('/completion') -eq 0) 'a server with more than one slot is refused before any workload request'
    New-Case;Write-LadderStatus $runId 'loading'
    $loading=Run-Ladder
    Check ($null -ne $loading.failure -and $loading.failure -match 'wait for ready' -and $null -eq $loading.report -and $mock::GetLog().Count -eq 0) 'a server that is not ready is refused before any request'
    Write-LadderStatus $runId
    Reject {Run-Ladder @{OutputTokens=32} | ForEach-Object {if($_.failure){throw $_.failure}}} 'OutputTokens|64' 'an output reservation below 64 is rejected'
    $small=Run-Ladder @{Tiers=[int[]]@(100)}
    Check ($null -ne $small.failure -and $small.failure -match 'at least') 'a tier too small for the output reservation is refused'
    $dupe=Run-Ladder @{Tiers=[int[]]@(256,256)}
    Check ($null -ne $dupe.failure -and $dupe.failure -match 'unique') 'duplicate tiers are refused'

    # ------------------------------------------------------------ CLI parses and runs as a thin wrapper
    $parseErrors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($cliPath,[ref]$null,[ref]$parseErrors)
    Check (@($parseErrors).Count -eq 0) 'the CLI parses cleanly'
    $psExe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if($env:OS -eq 'Windows_NT' -and (Test-Path -LiteralPath $psExe)){
        New-Case
        $cliOut=Join-Path $work 'cli-report.json'
        $child=Start-Process -FilePath $psExe -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$cliPath,'-InstallRoot',$installRoot,'-OutputPath',$cliOut,
            '-Tiers','256','-OutputTokens','64','-Repetitions','1','-NeedleDepths','0.5','-RequestTimeoutSeconds','30','-RunDeadlineSeconds','300') -NoNewWindow -PassThru `
            -RedirectStandardOutput (Join-Path $work 'cli.out.txt') -RedirectStandardError (Join-Path $work 'cli.err.txt')
        $null=$child.Handle
        if(-not $child.WaitForExit(180000)){& taskkill.exe /PID $child.Id /T /F | Out-Null}
        $cliReport=$null
        if(Test-Path -LiteralPath $cliOut){$cliReport=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($cliOut))}
        Check ($child.ExitCode -eq 0 -and $null -ne $cliReport -and $cliReport.completed -eq $true -and $cliReport.source.cliSha256 -eq (Get-FileHash -LiteralPath $cliPath -Algorithm SHA256).Hash.ToLowerInvariant()) 'the CLI runs the module in module scope and binds its own SHA-256'
    }

    Write-Host "context-ladder-tests: $($script:count) checks passed"
}finally{
    if($null -ne $lock){$lock.Dispose()}
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
