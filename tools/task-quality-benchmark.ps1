#requires -Version 5.1
# Private eight-task quality/throughput screen for a normal, single-slot Ready run.
[CmdletBinding()]
param(
    [string]$InstallRoot=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Bitworks/FastLLM'),
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [ValidateSet(0,32,128)][int]$DistractorCount=0,
    [ValidateRange(60,3600)][int]$DeadlineSeconds=1200,
    [ValidateRange(10,300)][int]$RequestTimeoutBaseSeconds=120,
    [switch]$WorkerMode,
    [string]$WorkerNonce
)
$ErrorActionPreference='Stop'
$script:FastLlmTaskQualityToolPath=$PSCommandPath

function Get-TaskQualitySourceHashes {
    $toolRoot=Split-Path $script:FastLlmTaskQualityToolPath -Parent
    $paths=[ordered]@{
        taskTool=$script:FastLlmTaskQualityToolPath
        workload=(Join-Path $toolRoot '../src/FastLlm.TaskWorkload.ps1')
        semantic=(Join-Path $toolRoot '../src/FastLlm.SemanticSmoke.ps1')
        concurrency=(Join-Path $toolRoot 'concurrency-benchmark.ps1')
        processHost=(Join-Path $toolRoot '../src/ProcessHost.cs')
        module=(Join-Path $toolRoot '../src/FastLlm.psm1')
        benchmark=(Join-Path $toolRoot '../src/FastLlm.Benchmark.ps1')
        runtime=(Join-Path $toolRoot '../src/FastLlm.Runtime.ps1')
        listener=(Join-Path $toolRoot '../src/WindowsGpuTelemetry.cs')
    }
    $hashes=[ordered]@{}
    foreach($key in $paths.Keys){$hashes[$key]=(Get-FileHash -LiteralPath $paths[$key] -Algorithm SHA256).Hash.ToLowerInvariant()}
    return $hashes
}

function Test-TaskQualitySourceHashes($Expected){
    try {
        $now=Get-TaskQualitySourceHashes
        foreach($key in $Expected.Keys){if([string]$now[$key] -cne [string]$Expected[$key]){return $false}}
        return $true
    }catch{return $false}
}

function Assert-TaskQualityCases([object[]]$Cases,[int]$DistractorCount){
    if(@($Cases).Count -ne 8){throw 'Task workload must contain exactly eight cases.'}
    $ids=@()
    foreach($case in $Cases){
        if([string]$case.id -cnotmatch '^[a-z][a-z0-9-]{0,63}$' -or $ids -ccontains [string]$case.id -or
           $case.prompt -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$case.prompt) -or
           ([string]$case.prompt).Length -gt 16384 -or
           [int]$case.maxOutputTokens -lt 1 -or [int]$case.maxOutputTokens -gt 128 -or
           [int]$case.distractorCount -ne $DistractorCount){throw 'Task workload case is outside fixed bounds.'}
        $ids+= [string]$case.id
    }
}

function New-TaskQualityRequestBody($State,$Case){
    $body=@{model=[string]$State.modelId;messages=@(@{role='user';content=[string]$Case.prompt});
        max_tokens=[int]$Case.maxOutputTokens;temperature=0;seed=42;stream=$false;cache_prompt=$false;
        chat_template_kwargs=@{enable_thinking=$false}}
    if($null -ne $Case.responseFormat){$body.response_format=$Case.responseFormat}
    return ConvertTo-Json -InputObject $body -Depth 16 -Compress
}

function Get-TaskQualityProperty {
    [CmdletBinding()]
    param($Object,[string]$Name)
    if($null -eq $Object){return $null}
    $property=$Object.PSObject.Properties[$Name]
    if($null -eq $property){return $null}
    $PSCmdlet.WriteObject($property.Value,$false)
}

function ConvertFrom-TaskQualityResponse($Response,$Case,[int]$EffectiveContext){
    $answer=[ordered]@{grade='inconclusive';errorCode='invalid-response';classification='inconclusive';
        httpStatus=$null;actualPromptTokens=$null;actualOutputTokens=$null;finishReason=$null}
    if($null -eq $Response){return [pscustomobject]$answer}
    $status=Get-TaskQualityProperty $Response 'Status'
    if($status -isnot [int] -and $status -isnot [long]){return [pscustomobject]$answer}
    $answer.httpStatus=[int]$status
    if($answer.httpStatus -ne 200){$answer.errorCode='http-status';return [pscustomobject]$answer}
    $rawBody=Get-TaskQualityProperty $Response 'Body'
    if($rawBody -isnot [string] -or $rawBody.Length -gt 1048576){return [pscustomobject]$answer}
    try{$data=ConvertFrom-Json -InputObject $rawBody -ErrorAction Stop}catch{return [pscustomobject]$answer}
    $choices=Get-TaskQualityProperty $data 'choices'
    if($choices -isnot [array] -or $choices.Count -ne 1){return [pscustomobject]$answer}
    $choice=@($choices)[0]
    $message=Get-TaskQualityProperty $choice 'message'
    $role=Get-TaskQualityProperty $message 'role'
    if($null -eq $message -or $role -isnot [string] -or $role -cne 'assistant'){return [pscustomobject]$answer}
    $finish=Get-TaskQualityProperty $choice 'finish_reason'
    if($finish -isnot [string]){return [pscustomobject]$answer}
    $answer.finishReason=$finish
    $usage=Get-TaskQualityProperty $data 'usage'
    $promptUsage=Get-TaskQualityProperty $usage 'prompt_tokens'
    $outputUsage=Get-TaskQualityProperty $usage 'completion_tokens'
    if($null -eq $usage -or
       ($promptUsage -isnot [int] -and $promptUsage -isnot [long]) -or
       ($outputUsage -isnot [int] -and $outputUsage -isnot [long]) -or
       [long]$promptUsage -lt 1 -or [long]$promptUsage -gt 32768 -or
       [long]$outputUsage -lt 0 -or [long]$outputUsage -gt [int]$Case.maxOutputTokens){
        $answer.errorCode='missing-actual-usage';return [pscustomobject]$answer
    }
    $answer.actualPromptTokens=[int]$promptUsage
    $answer.actualOutputTokens=[int]$outputUsage
    if($answer.actualPromptTokens+[int]$Case.maxOutputTokens+8 -gt $EffectiveContext){
        $answer.errorCode='observed-context-overflow';return [pscustomobject]$answer
    }
    if($answer.finishReason -cne 'stop'){
        $answer.errorCode=$(if($answer.finishReason -ceq 'length'){'truncated'}else{'unexpected-finish'})
        return [pscustomobject]$answer
    }
    $reasoning=Get-TaskQualityProperty $message 'reasoning_content'
    $reasoningAlternate=Get-TaskQualityProperty $message 'reasoning'
    if(($null -ne $reasoning -and -not [string]::IsNullOrWhiteSpace([string]$reasoning)) -or
       ($null -ne $reasoningAlternate -and -not [string]::IsNullOrWhiteSpace([string]$reasoningAlternate))){
        $answer.errorCode='unexpected-reasoning';return [pscustomobject]$answer
    }
    $content=Get-TaskQualityProperty $message 'content'
    if($content -isnot [string]){$answer.errorCode='missing-content';return [pscustomobject]$answer}
    if($content -match '(?is)<think>|</think>'){$answer.errorCode='visible-reasoning';return [pscustomobject]$answer}
    try{$grade=Test-FastLlmTaskWorkloadAnswer -Case $Case -Content $content}
    catch{$answer.errorCode='grader-error';return [pscustomobject]$answer}
    if($null -eq $grade -or $grade.passed -isnot [bool] -or [string]$grade.classification -cnotmatch '^[a-z0-9-]{1,64}$' -or
       [string]$grade.errorCode -cnotmatch '^[A-Z0-9_]{1,64}$'){
        $answer.errorCode='grader-invalid';return [pscustomobject]$answer
    }
    $answer.grade=if($grade.passed){'correct'}else{'incorrect'}
    $answer.errorCode=if($grade.passed){$null}else{[string]$grade.errorCode}
    $answer.classification=[string]$grade.classification
    return [pscustomobject]$answer
}

function New-TaskQualityAbortRecord([string]$OutputPath,$State,[string]$ReasonCode){
    $target=if(Test-Path -LiteralPath $OutputPath){$OutputPath+'.controller-abort-'+[Guid]::NewGuid().ToString('N')+'.json'}else{$OutputPath}
    $record=[ordered]@{schemaVersion=1;resultKind='private-task-quality-controller-abort';reportStatus='aborted';
        recordedAt=[DateTime]::UtcNow.ToString('o');abortReasonCode=$ReasonCode;runId=$State.runId;
        processIdentity=$State.processIdentity;workerTerminatedConfirmed=$true;controllerOutcomeAuthoritative=$true;
        primaryReportPresent=(Test-Path -LiteralPath $OutputPath);
        qualification=@{approved=$false;qualityEvaluation=$false;performanceQualified=$false;physicalResidency=$false;parallelDecodeVerified=$false}}
    $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $record -Depth 8))
    $file=[IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$file.Write($bytes,0,$bytes.Length)}finally{$file.Dispose()}
    return $target
}

function Invoke-TaskQualityBenchmarkCore {
    param([string]$OutputPath,[int]$DistractorCount,[int]$DeadlineSeconds,[int]$RequestTimeoutBaseSeconds,
          [scriptblock]$ReadState,[scriptblock]$CheckProcess,[scriptblock]$Wave)
    if(Test-Path -LiteralPath $OutputPath){throw 'Task-quality report already exists.'}
    if($DistractorCount -notin @(0,32,128) -or $DeadlineSeconds -lt 60 -or $DeadlineSeconds -gt 3600 -or
       $RequestTimeoutBaseSeconds -lt 10 -or $RequestTimeoutBaseSeconds -gt 300 -or
       $RequestTimeoutBaseSeconds -gt $DeadlineSeconds){throw 'Task-quality bounds are invalid.'}
    $full=[IO.Path]::GetFullPath($OutputPath)
    if(-not (Test-Path -LiteralPath (Split-Path $full -Parent) -PathType Container)){throw 'Private output parent must already exist.'}
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $first=& $ReadState
    $binding=Assert-FastLlmSemanticSmokeState -State $first
    & $CheckProcess $first
    $effectiveContext=[int]$first.recipe.contextSize
    $source=Get-TaskQualitySourceHashes
    $cases=@(Get-FastLlmTaskWorkloadCases -DistractorCount $DistractorCount)
    Assert-TaskQualityCases $cases $DistractorCount
    $caseMetadata=@($cases|ForEach-Object {
        [pscustomobject]@{id=[string]$_.id;kind=[string]$_.kind;
            promptSha256=(Get-FastLlmTaskWorkloadPromptSha256 -Case $_);
            referenceSha256=(Get-FastLlmTaskWorkloadReferenceSha256 -Case $_);
            maxOutputTokens=[int]$_.maxOutputTokens;
            responseFormat=$(if($null -ne $_.responseFormat){'explicit'}else{'none'});
            responseFormatSha256=$(if($null -ne $_.responseFormat){Get-FastLlmTaskWorkloadSha256 -Text (ConvertTo-Json -InputObject $_.responseFormat -Depth 10 -Compress)}else{$null})}
    })
    $levels=@(1,2,4);$waves=@();$summary=@();$abortReason=$null;$failedCondition=$null
    $reportStatus='complete';$bindingStatus='verified';$sourceStatus='verified';$waveIssued=$false;$postChecked=$false
    $suiteVersion=Get-FastLlmTaskWorkloadSuiteVersion
    $currentLevel=$null;$currentOffset=$null;$suiteStartMs=$null;$suiteEndMs=$null
    $burst=@();$waveRecorded=$false
    try {
        foreach($clients in $levels){
            $currentLevel=$clients;$suiteStartMs=$clock.Elapsed.TotalMilliseconds;$suiteEndMs=$null
            for($offset=0;$offset -lt 8;$offset+=$clients){
                $currentOffset=$offset;$waveIssued=$false;$waveRecorded=$false;$postChecked=$false;$burst=@()
                $remaining=[int][Math]::Floor(($DeadlineSeconds-$clock.Elapsed.TotalSeconds)*1000)
                if($remaining -lt 1000){$abortReason='overall-deadline';throw 'Overall deadline.'}
                $state=& $ReadState
                $null=Assert-FastLlmSemanticSmokeState -State $state -ExpectedBinding $binding
                & $CheckProcess $state
                if(-not (Test-TaskQualitySourceHashes $source)){$abortReason='source-changed';throw 'Source changed.'}
                $burst=@($cases[$offset..($offset+$clients-1)])
                $bodies=@($burst|ForEach-Object {New-TaskQualityRequestBody -State $first -Case $_})
                $timeoutMs=[Math]::Min($remaining,[Math]::Min(900000,$RequestTimeoutBaseSeconds*1000*$clients))
                $waveIssued=$true
                $result=& $Wave ($first.endpoint -replace '/v1$','') '/v1/chat/completions' $bodies $clients $timeoutMs
                Assert-ConcurrencyWaveShape -Wave $result -Clients $clients
                $requests=@();$correct=0;$incorrect=0;$inconclusive=0
                foreach($request in @($result.requests)){
                    $case=$burst[[int]$request.client-1]
                    $parsed=if($request.errorCode){[pscustomobject]@{grade='inconclusive';errorCode='request-error';classification='inconclusive';
                        httpStatus=$null;actualPromptTokens=$null;actualOutputTokens=$null;finishReason=$null}}else{
                        ConvertFrom-TaskQualityResponse -Response $request.response -Case $case -EffectiveContext $effectiveContext
                    }
                    switch($parsed.grade){'correct'{$correct++};'incorrect'{$incorrect++};default{$inconclusive++}}
                    $requests+= [pscustomobject]@{client=[int]$request.client;taskId=[string]$case.id;
                        dispatchStartMs=[double]$request.startedMs;httpFinishMs=[double]$request.finishedMs;
                        endToEndLatencyMs=([double]$request.finishedMs-[double]$request.startedMs);
                        timeToFirstTextMs=$null;firstTextMeasurement='not-measured-nonstreaming';
                        httpStatus=$parsed.httpStatus;finishReason=$parsed.finishReason;
                        actualPromptTokens=$parsed.actualPromptTokens;actualOutputTokens=$parsed.actualOutputTokens;
                        grade=$parsed.grade;classification=$parsed.classification;errorCode=$parsed.errorCode}
                }
                $waveRecord=[pscustomobject]@{requestedClients=$clients;taskIds=@($burst|ForEach-Object id);
                    releasedMs=[double]$result.releasedMs;wallMs=[double]$result.wallMs;
                    overlappingHttpRequestsPeak=(Get-ConcurrencyObservedOverlap -Requests $result.requests);
                    serverParallelDecodeObserved=$false;correct=$correct;incorrect=$incorrect;inconclusive=$inconclusive;requests=$requests}
                $waves+=$waveRecord
                $waveRecorded=$true
                $state=& $ReadState
                $null=Assert-FastLlmSemanticSmokeState -State $state -ExpectedBinding $binding
                & $CheckProcess $state
                $postChecked=$true
                if(-not (Test-TaskQualitySourceHashes $source)){$abortReason='source-changed';throw 'Source changed.'}
                if($clock.Elapsed.TotalSeconds -gt $DeadlineSeconds){$abortReason='overall-deadline';throw 'Overall deadline.'}
                if($incorrect -gt 0 -or $inconclusive -gt 0){$abortReason='failed-or-inconclusive-wave';throw 'Stop escalation after a failed task wave.'}
            }
            $suiteEndMs=$clock.Elapsed.TotalMilliseconds
            $group=@($waves|Where-Object requestedClients -eq $clients)
            $suiteRequests=@($group|ForEach-Object requests)
            $suiteWallMs=$suiteEndMs-$suiteStartMs
            $summary+= [pscustomobject]@{requestedClients=$clients;planned=8;attempted=$suiteRequests.Count;
                correct=@($suiteRequests|Where-Object grade -eq 'correct').Count;
                incorrect=@($suiteRequests|Where-Object grade -eq 'incorrect').Count;
                inconclusive=@($suiteRequests|Where-Object grade -eq 'inconclusive').Count;
                unattempted=8-$suiteRequests.Count;wholeSuiteWallMs=$suiteWallMs;
                suiteStartCollectorMs=$suiteStartMs;suiteFinishCollectorMs=$suiteEndMs;complete=$true;
                usefulTasksPerSecond=$(if($suiteWallMs -gt 0){1000.0*@($suiteRequests|Where-Object grade -eq 'correct').Count/$suiteWallMs}else{$null});
                timingScope='level pre-dispatch checks through final post-wave checks, including inter-wave gaps'}
            Write-Host "Private task-quality: clients $clients, correct $(@($suiteRequests|Where-Object grade -eq 'correct').Count)/8"
        }
        $state=& $ReadState
        $null=Assert-FastLlmSemanticSmokeState -State $state -ExpectedBinding $binding
        & $CheckProcess $state
        if(-not (Test-TaskQualitySourceHashes $source)){$abortReason='source-changed';throw 'Source changed.'}
    }catch{
        $reportStatus='aborted'
        if(-not $abortReason){$abortReason=if($waveIssued -and -not $postChecked){'wave-or-postcheck-failed'}else{'binding-or-preparation-failed'}}
        if($waveIssued -and -not $waveRecorded -and @($burst).Count -gt 0){
            # Once a wave is issued, no client can honestly be called unattempted
            # merely because the shared HTTP collector or shape check failed.
            $unknown=@(for($i=0;$i -lt $burst.Count;$i++){
                [pscustomobject]@{client=$i+1;taskId=[string]$burst[$i].id;dispatchStartMs=$null;httpFinishMs=$null;
                    endToEndLatencyMs=$null;timeToFirstTextMs=$null;firstTextMeasurement='not-measured-nonstreaming';
                    httpStatus=$null;finishReason=$null;actualPromptTokens=$null;actualOutputTokens=$null;
                    grade='inconclusive';classification='issued-result-unknown';errorCode='wave-result-unavailable'}
            })
            $waves+= [pscustomobject]@{requestedClients=$currentLevel;taskIds=@($burst|ForEach-Object id);
                releasedMs=$null;wallMs=$null;overlappingHttpRequestsPeak=$null;serverParallelDecodeObserved=$false;
                correct=0;incorrect=0;inconclusive=$unknown.Count;requests=$unknown;waveStatus='issued-result-unknown'}
        }
        $failedCondition=[pscustomobject]@{requestedClients=$currentLevel;taskOffset=$currentOffset;
            reasonCode=$abortReason;waveIssued=$waveIssued;postChecked=$postChecked}
        if($waveIssued -and -not $postChecked){
            try{$state=& $ReadState;$null=Assert-FastLlmSemanticSmokeState -State $state -ExpectedBinding $binding;& $CheckProcess $state}
            catch{$bindingStatus='compromised';$abortReason='binding-changed-after-wave';$failedCondition.reasonCode=$abortReason}
        }
    }
    try{$state=& $ReadState;$null=Assert-FastLlmSemanticSmokeState -State $state -ExpectedBinding $binding;& $CheckProcess $state}
    catch{$bindingStatus='compromised';if($reportStatus -eq 'complete'){$reportStatus='aborted';$abortReason='binding-changed-at-finish'}}
    if(-not (Test-TaskQualitySourceHashes $source)){
        $sourceStatus='changed';$bindingStatus='compromised';$reportStatus='aborted';$abortReason='source-changed'
    }
    foreach($clients in $levels){
        if(@($summary|Where-Object requestedClients -eq $clients).Count){continue}
        $group=@($waves|Where-Object requestedClients -eq $clients)
        $suiteRequests=@($group|ForEach-Object requests)
        $wallMs=if($clients -eq $currentLevel -and $null -ne $suiteStartMs){$clock.Elapsed.TotalMilliseconds-$suiteStartMs}else{$null}
        $summary+= [pscustomobject]@{requestedClients=$clients;planned=8;attempted=$suiteRequests.Count;
            correct=@($suiteRequests|Where-Object grade -eq 'correct').Count;
            incorrect=@($suiteRequests|Where-Object grade -eq 'incorrect').Count;
            inconclusive=@($suiteRequests|Where-Object grade -eq 'inconclusive').Count;
            unattempted=8-$suiteRequests.Count;wholeSuiteWallMs=$wallMs;
            suiteStartCollectorMs=$(if($clients -eq $currentLevel){$suiteStartMs}else{$null});
            suiteFinishCollectorMs=$(if($clients -eq $currentLevel){$clock.Elapsed.TotalMilliseconds}else{$null});complete=$false;
            usefulTasksPerSecond=$null;
            timingScope='partial or unattempted; no completed full-suite rate'}
    }
    $all=@($waves|ForEach-Object requests)
    $totals=[ordered]@{planned=24;attempted=$all.Count;
        correct=@($all|Where-Object grade -eq 'correct').Count;
        incorrect=@($all|Where-Object grade -eq 'incorrect').Count;
        inconclusive=@($all|Where-Object grade -eq 'inconclusive').Count;
        unattempted=24-$all.Count}
    $report=[ordered]@{schemaVersion=1;resultKind='private-task-quality-screen';recordedAt=[DateTime]::UtcNow.ToString('o');
        reportStatus=$reportStatus;abortReasonCode=$abortReason;bindingStatus=$bindingStatus;failedCondition=$failedCondition;
        controllerOutcomeAuthoritative=$false;
        runId=$first.runId;processIdentity=$first.processIdentity;modelId=$first.modelId;modelSha256=$first.modelSha256;
        engineVersion=$first.engineVersion;recipe=$first.recipe;endpoint=$first.endpoint;evidenceBindingSha256=$binding;
        sourceProvenance=@{sha256=$source;endStatus=$sourceStatus;scope='On-disk hashes before/after; loaded code not attested'};
        methodology=@{suiteVersion=$suiteVersion;distractorCount=$DistractorCount;cases=$caseMetadata;
            conditionOrder='C1, C2, C4; same eight task IDs at each level; sequential bursts of C requests; no warmup';
            perLevelPlannedTasks=8;plannedTotalTasks=24;serverSlots=1;start='barrier release within each burst';
            stream=$false;firstText='not-measured';sampling='temperature-0-seed-42-thinking-disabled';prefixCache=$false;
            requestTimeoutBaseSeconds=$RequestTimeoutBaseSeconds;overallDeadlineSeconds=$DeadlineSeconds;
            actualUsageRequired=$true;contextEvidence='response usage only; no pretokenized or context qualification';
            interpretation='Single-slot queue-pressure and useful-task screen, not parallel GPU proof or quality qualification'};
        waves=$waves;summary=$summary;totals=$totals;
        qualification=@{approved=$false;qualityEvaluation=$false;performanceQualified=$false;physicalResidency=$false;
            parallelDecodeVerified=$false;exclusiveWorkloadConfirmed=$false;contextQualified=$false}}
    $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $report -Depth 20))
    if($bytes.Length -gt 2097152){throw 'Task-quality report exceeds its private size bound.'}
    $file=[IO.File]::Open($full,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$file.Write($bytes,0,$bytes.Length)}finally{$file.Dispose()}
    return [pscustomobject]$report
}

if($MyInvocation.InvocationName -ne '.'){
    if($env:OS -cne 'Windows_NT' -or -not [Environment]::Is64BitProcess){throw 'Private task-quality screen requires native 64-bit Windows.'}
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run as a standard user.'}
    if($WorkerMode){
        if($WorkerNonce -cnotmatch '^[0-9a-f]{32}$' -or $env:FASTLLM_CONCURRENCY_NONCE -cne $WorkerNonce){throw 'Unbound private task worker.'}
    }elseif($WorkerNonce){throw 'Worker-only nonce was supplied to controller.'}
    $sourceRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../src'))
    $module=Import-Module (Join-Path $sourceRoot 'FastLlm.psm1') -Force -PassThru
    $semanticSource=Join-Path $sourceRoot 'FastLlm.SemanticSmoke.ps1'
    $workloadSource=Join-Path $sourceRoot 'FastLlm.TaskWorkload.ps1'
    $concurrencyTool=Join-Path $PSScriptRoot 'concurrency-benchmark.ps1'
    if($WorkerMode){
        $result=& $module {
            param($Tool,$Semantic,$Workload,$Concurrency,$Root,$Destination,$Distractors,$Deadline,$Timeout)
            . $Semantic
            . $Workload
            . $Concurrency -OutputPath (Join-Path ([IO.Path]::GetTempPath()) 'unused-task-quality-helper.json')
            . $Tool -OutputPath $Destination -DistractorCount $Distractors -DeadlineSeconds $Deadline -RequestTimeoutBaseSeconds $Timeout
            Initialize-FastLlmProcessHost
            Assert-ConcurrencyControllerLock -InstallRoot $Root
            Invoke-TaskQualityBenchmarkCore -OutputPath $Destination -DistractorCount $Distractors -DeadlineSeconds $Deadline -RequestTimeoutBaseSeconds $Timeout `
                -ReadState {Get-FastLlmStatus -InstallRoot $Root} -CheckProcess {param($State) Assert-FastLlmSemanticSmokeProcess -State $State} `
                -Wave {param($Base,$Path,$Bodies,$Count,$TimeoutMs) Invoke-ConcurrencyWave -Url ($Base+$Path) -Bodies $Bodies -Clients $Count -TimeoutMs $TimeoutMs}
        } $PSCommandPath $semanticSource $workloadSource $concurrencyTool $InstallRoot $OutputPath $DistractorCount $DeadlineSeconds $RequestTimeoutBaseSeconds
        if($result.reportStatus -cne 'complete'){throw "Private task-quality screen aborted; report saved with reason $($result.abortReasonCode)."}
    }else{
        $outFull=[IO.Path]::GetFullPath($OutputPath)
        if(Test-Path -LiteralPath $outFull){throw 'Task-quality report already exists.'}
        $status=& $module {param($Root,$Semantic) . $Semantic; $state=Get-FastLlmStatus -InstallRoot $Root;
            $null=Assert-FastLlmSemanticSmokeState -State $state;Assert-FastLlmSemanticSmokeProcess -State $state;$state} $InstallRoot $semanticSource
        $controllerSource=Get-TaskQualitySourceHashes
        $root=& $module {param($Root)Get-FastLlmStateRoot -InstallRoot $Root} $InstallRoot
        $lockPath=Join-Path $root 'benchmark.lock'
        if((Test-Path -LiteralPath $lockPath) -and ((Get-Item -LiteralPath $lockPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Unsafe benchmark lock.'}
        $lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try {
            $nonce=[Guid]::NewGuid().ToString('N')
            $exe=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            $workerArguments=@('-NoLogo','-NoProfile','-NonInteractive','-File',$PSCommandPath,'-WorkerMode','-WorkerNonce',$nonce,
                '-InstallRoot',$InstallRoot,'-OutputPath',$outFull,'-DistractorCount',([string]$DistractorCount),
                '-DeadlineSeconds',([string]$DeadlineSeconds),'-RequestTimeoutBaseSeconds',([string]$RequestTimeoutBaseSeconds))
            $worker=& $module {
                param($Tool,$Concurrency,$Exe,$WorkerArguments,$Directory,$Seconds,$Nonce)
                . $Concurrency -OutputPath (Join-Path ([IO.Path]::GetTempPath()) 'unused-task-quality-helper.json')
                Invoke-ConcurrencyContainedWorker -Executable $Exe -Arguments $WorkerArguments -WorkingDirectory $Directory `
                    -DeadlineMilliseconds (($Seconds+15)*1000) -Nonce $Nonce
            } $PSCommandPath $concurrencyTool $exe $workerArguments $PSScriptRoot $DeadlineSeconds $nonce
            if($worker.timedOut){$failure=New-TaskQualityAbortRecord $outFull $status 'contained-task-worker-deadline';throw "Contained task worker timed out; private failure: $failure"}
            if($worker.exitCode -ne 0){
                $failure=New-TaskQualityAbortRecord $outFull $status 'contained-task-worker-nonzero-exit'
                throw "Contained task worker failed; authoritative private failure: $failure"
            }
            if(-not (Test-Path -LiteralPath $outFull -PathType Leaf)){$failure=New-TaskQualityAbortRecord $outFull $status 'contained-task-worker-missing-report';throw "Contained task worker omitted report: $failure"}
            $item=Get-Item -LiteralPath $outFull -Force
            if($item.Length -gt 2097152 -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){
                $failure=New-TaskQualityAbortRecord $outFull $status 'contained-task-worker-unsafe-report';throw "Unsafe task worker report: $failure"
            }
            try{$final=Get-Content -LiteralPath $outFull -Raw|ConvertFrom-Json}catch{
                $failure=New-TaskQualityAbortRecord $outFull $status 'contained-task-worker-invalid-report';throw "Invalid task worker report: $failure"
            }
            if(-not (Test-TaskQualitySourceHashes $controllerSource)){
                $failure=New-TaskQualityAbortRecord $outFull $status 'controller-source-changed';throw "Source changed while task worker ran: $failure"
            }
            if($final.resultKind -cne 'private-task-quality-screen' -or $final.reportStatus -cne 'complete' -or
               $final.bindingStatus -cne 'verified' -or $final.runId -cne $status.runId -or
               @($final.summary).Count -ne 3 -or
               (@($final.summary|ForEach-Object requestedClients) -join ',') -cne '1,2,4' -or
               [int]$final.totals.attempted -ne 24 -or [int]$final.totals.correct -ne 24 -or
               [int]$final.totals.incorrect -ne 0 -or [int]$final.totals.inconclusive -ne 0){
                $failure=New-TaskQualityAbortRecord $outFull $status 'contained-task-worker-report-rejected'
                throw "Task worker report did not pass controller checks: $failure"
            }
            Write-Host "Saved private task-quality screen: $outFull. No qualification granted."
        }finally{$lock.Dispose()}
    }
}
