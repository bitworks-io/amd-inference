#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallRoot=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Bitworks/FastLLM'),
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [int[]]$PromptTokens=@(512,4096),
    [ValidateRange(1,1024)][int]$GenerationTokens=128,
    [ValidateRange(1,10)][int]$Repetitions=5,
    [ValidateRange(60,7200)][int]$DeadlineSeconds=3600,
    [ValidateRange(30,300)][int]$RequestTimeoutBaseSeconds=180,
    [switch]$WorkerMode,
    [string]$WorkerNonce,
    [string]$WorkerPromptCsv
)
$ErrorActionPreference='Stop'
$script:FastLlmConcurrencySourcePath=$PSCommandPath

function Assert-ConcurrencyArguments {
    param([int[]]$Lengths,[int]$OutputTokens,[int]$Context)
    if(-not $Lengths -or $Lengths.Count -gt 4 -or @($Lengths|Select-Object -Unique).Count -ne $Lengths.Count){throw 'Supply one to four distinct prompt lengths.'}
    foreach($length in $Lengths){
        if($length -lt 16 -or $length -gt 32768 -or $length+$OutputTokens+8 -gt $Context){
            throw 'A requested prompt/output length exceeds the effective context or benchmark bounds.'
        }
    }
}

function Invoke-ConcurrencyContainedWorker {
    param([string]$Executable,[string[]]$Arguments,[string]$WorkingDirectory,[int]$DeadlineMilliseconds,[string]$Nonce)
    if($DeadlineMilliseconds -lt 1 -or $DeadlineMilliseconds -gt 7230000){throw 'Worker deadline is outside bounds.'}
    Initialize-FastLlmProcessHost
    $child=New-Object Bitworks.FastLlm.ProcessHost
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$Executable
    $info.Arguments=Join-FastLlmProcessArguments -Arguments $Arguments
    $info.WorkingDirectory=$WorkingDirectory
    $info.EnvironmentVariables['FASTLLM_CONCURRENCY_NONCE']=$Nonce
    $witness=$null;$timedOut=$false;$exitCode=$null;$pidValue=$null
    try {
        $child.Start($info)
        $pidValue=[int]$child.Process.Id
        $witness=[Diagnostics.Process]::GetProcessById($pidValue)
        $startTicks=[long]$witness.StartTime.ToUniversalTime().Ticks
        if(-not $child.Process.WaitForExit($DeadlineMilliseconds)){$timedOut=$true}
        else{$exitCode=[int]$child.Process.ExitCode}
    } finally {
        $child.Dispose()
        if($witness){
            # Keep the caller's benchmark lock until the process is actually gone.
            # A failed OS termination may exceed the requested deadline rather
            # than permitting a surviving request worker to escape the lock.
            while(-not $witness.WaitForExit(1000)){
                try{if([long]$witness.StartTime.ToUniversalTime().Ticks -eq $startTicks){$witness.Kill()}}catch{}
            }
            $witness.Dispose()
        }
    }
    return [pscustomobject]@{pid=$pidValue;exitCode=$exitCode;timedOut=$timedOut;terminatedConfirmed=$true}
}

function Save-ConcurrencyControllerFailure {
    param([string]$OutputPath,$State,[string]$ReasonCode)
    $target=if(Test-Path -LiteralPath $OutputPath){$OutputPath+'.controller-abort-'+[Guid]::NewGuid().ToString('N')+'.json'}else{$OutputPath}
    $report=[ordered]@{
        schemaVersion=1;resultKind='native-windows-api-private-concurrency-controller-abort'
        recordedAt=(Get-Date).ToUniversalTime().ToString('o');reportStatus='aborted';abortReasonCode=$ReasonCode
        runId=$State.runId;processIdentity=$State.processIdentity;modelId=$State.modelId;modelSha256=$State.modelSha256
        recipe=$State.recipe;endpoint=$State.endpoint;workerTerminatedConfirmed=$true
        controllerOutcomeAuthoritative=$true;primaryReportPresent=(Test-Path -LiteralPath $OutputPath)
        samples=@();warmupWaves=@();sampleEvidence='Controller abort governs this attempt even if a child report exists; no requests or outputs are inferred from it.'
        qualification=@{approved=$false;qualityEvaluation=$false;physicalResidency=$false;parallelDecodeVerified=$false}
    }
    $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $report -Depth 16))
    $stream=[IO.File]::Open($target,'CreateNew','Write','None')
    try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
    return $target
}

function Assert-ConcurrencyControllerLock {
    param([string]$InstallRoot)
    $root=Get-FastLlmStateRoot $InstallRoot
    $path=Join-Path $root 'benchmark.lock'
    if(-not (Test-Path -LiteralPath $path -PathType Leaf) -or
       ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){
        throw 'Contained worker has no safe controller lock.'
    }
    $probe=$null
    try {$probe=[IO.File]::Open($path,'Open','ReadWrite','None')}
    catch [IO.IOException] {return}
    finally {if($probe){$probe.Dispose()}}
    throw 'Contained worker must run while its controller holds the benchmark lock.'
}

function Invoke-ConcurrencyWave {
    param([string]$Url,[string]$Body,[int]$Clients,[int]$TimeoutMs)
    $pool=[RunspaceFactory]::CreateRunspacePool(1,$Clients)
    $pool.Open()
    $gate=New-Object Threading.ManualResetEventSlim($false)
    $ready=New-Object Threading.CountdownEvent($Clients)
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $workers=New-Object Collections.ArrayList
    $source=@'
param($Gate,$Ready,$Clock,$Url,$Body,$TimeoutMs)
[void]$Ready.Signal()
$Gate.Wait()
$start=$Clock.Elapsed.TotalMilliseconds
try {
    $response=[Bitworks.FastLlm.LoopbackHttp]::Request($Url,$Body,$TimeoutMs,1048576)
    [pscustomobject]@{startedMs=$start;finishedMs=$Clock.Elapsed.TotalMilliseconds;response=$response;errorCode=$null}
} catch {
    [pscustomobject]@{startedMs=$start;finishedMs=$Clock.Elapsed.TotalMilliseconds;response=$null;errorCode='request-error'}
}
'@
    try {
        for($i=0;$i -lt $Clients;$i++){
            $shell=[PowerShell]::Create();$shell.RunspacePool=$pool
            [void]$shell.AddScript($source).AddArgument($gate).AddArgument($ready).AddArgument($clock).AddArgument($Url).AddArgument($Body).AddArgument($TimeoutMs)
            $handle=$shell.BeginInvoke()
            [void]$workers.Add([pscustomobject]@{shell=$shell;handle=$handle})
        }
        if(-not $ready.Wait(10000)){throw 'Concurrent workers did not reach the start barrier.'}
        $releasedMs=$clock.Elapsed.TotalMilliseconds
        $gate.Set()
        $waveDeadlineMs=$releasedMs+$TimeoutMs+5000
        $result=@()
        foreach($worker in $workers){
            $waitMs=[Math]::Max(0,[int][Math]::Ceiling($waveDeadlineMs-$clock.Elapsed.TotalMilliseconds))
            if(-not $worker.handle.AsyncWaitHandle.WaitOne($waitMs)){throw 'Concurrent request exceeded the shared wave deadline.'}
            $items=@($worker.shell.EndInvoke($worker.handle))
            if($items.Count -ne 1){throw "Concurrent worker returned an invalid result (items=$($items.Count), errors=$($worker.shell.Streams.Error.Count))."}
            $result+= [pscustomobject]@{client=($result.Count+1);startedMs=$items[0].startedMs;finishedMs=$items[0].finishedMs;response=$items[0].response;errorCode=$items[0].errorCode}
        }
        $terminalMs=($result|Measure-Object finishedMs -Maximum).Maximum
        return [pscustomobject]@{releasedMs=$releasedMs;wallMs=[double]$terminalMs-$releasedMs;
            collectorElapsedMs=$clock.Elapsed.TotalMilliseconds-$releasedMs;requests=$result}
    } finally {
        $gate.Set()
        $cleanupDeadlineMs=$clock.Elapsed.TotalMilliseconds+5000
        $stops=@()
        foreach($worker in $workers){
            if(-not $worker.handle.IsCompleted){
                try {$stops+= [pscustomobject]@{shell=$worker.shell;handle=$worker.shell.BeginStop($null,$null)}}catch{}
            }
        }
        foreach($stop in $stops){
            $waitMs=[Math]::Max(0,[int][Math]::Ceiling($cleanupDeadlineMs-$clock.Elapsed.TotalMilliseconds))
            if($stop.handle.AsyncWaitHandle.WaitOne($waitMs)){try{$stop.shell.EndStop($stop.handle)}catch{}}
        }
        $allDone=@($workers|Where-Object {-not $_.handle.IsCompleted}).Count -eq 0
        if($allDone){
            foreach($worker in $workers){$worker.shell.Dispose()}
            $pool.Dispose()
        }
        $ready.Dispose();$gate.Dispose();$clock.Stop()
        if(-not $allDone){throw 'Concurrent worker cleanup exceeded the shared deadline.'}
    }
}

function Get-ConcurrencyObservedOverlap {
    param([object[]]$Requests)
    $events=@()
    foreach($request in $Requests){
        $events+= [pscustomobject]@{ms=[double]$request.startedMs;delta=1}
        $events+= [pscustomobject]@{ms=[double]$request.finishedMs;delta=-1}
    }
    $active=0;$peak=0
    foreach($event in @($events|Sort-Object ms,delta)){
        $active+=$event.delta
        if($active -gt $peak){$peak=$active}
    }
    return $peak
}

function Assert-ConcurrencyWaveShape {
    param($Wave,[int]$Clients)
    if($null -eq $Wave -or @($Wave.requests).Count -ne $Clients -or
       -not (Test-FastLlmBenchmarkFiniteNumber $Wave.releasedMs) -or
       -not (Test-FastLlmBenchmarkFiniteNumber $Wave.wallMs $true)){
        throw 'Wave cardinality or common wall interval is invalid.'
    }
    $ids=@();$lastFinish=[double]$Wave.releasedMs
    foreach($request in @($Wave.requests)){
        if($request.client -isnot [int] -and $request.client -isnot [long]){throw 'Wave client ID is invalid.'}
        if([int]$request.client -lt 1 -or [int]$request.client -gt $Clients -or $ids -contains [int]$request.client){throw 'Wave client IDs are missing or duplicated.'}
        $ids+= [int]$request.client
        if(-not (Test-FastLlmBenchmarkFiniteNumber $request.startedMs) -or
           -not (Test-FastLlmBenchmarkFiniteNumber $request.finishedMs) -or
           [double]$request.startedMs -lt [double]$Wave.releasedMs -or
           [double]$request.finishedMs -lt [double]$request.startedMs){throw 'Wave request interval is invalid.'}
        if([double]$request.finishedMs -gt $lastFinish){$lastFinish=[double]$request.finishedMs}
    }
    if([Math]::Abs(($lastFinish-[double]$Wave.releasedMs)-[double]$Wave.wallMs) -gt 0.1){
        throw 'Wave wall interval differs from the last HTTP completion.'
    }
}

function Invoke-ConcurrencyBenchmarkCore {
    param([string]$OutputPath,[int[]]$PromptTokens,[int]$GenerationTokens,[int]$Repetitions,[int]$DeadlineSeconds,[int]$RequestTimeoutBaseSeconds=180,
          [scriptblock]$ReadState,[scriptblock]$CheckProcess,[scriptblock]$Request,[scriptblock]$Wave)
    if(Test-Path -LiteralPath $OutputPath){throw 'Concurrency report already exists.'}
    if($RequestTimeoutBaseSeconds -lt 1 -or $RequestTimeoutBaseSeconds -gt 300 -or $RequestTimeoutBaseSeconds -gt $DeadlineSeconds){throw 'Request timeout base exceeds benchmark bounds or overall deadline.'}
    $full=[IO.Path]::GetFullPath($OutputPath)
    $directory=Split-Path $full -Parent
    if(-not (Test-Path -LiteralPath $directory -PathType Container)){throw 'Report parent directory must already exist.'}
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $first=& $ReadState
    $binding=Assert-FastLlmSemanticSmokeState $first
    & $CheckProcess $first
    Assert-ConcurrencyArguments $PromptTokens $GenerationTokens ([int]$first.recipe.contextSize)
    $sourcePath=$script:FastLlmConcurrencySourcePath
    $sourceHash=(Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $canonicalPath=Join-Path $PSScriptRoot '../src/FastLlm.Benchmark.ps1'
    $canonicalHash=(Get-FileHash -LiteralPath $canonicalPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $bindingPath=Join-Path $PSScriptRoot '../src/FastLlm.SemanticSmoke.ps1'
    $bindingHash=(Get-FileHash -LiteralPath $bindingPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $httpPath=Join-Path $PSScriptRoot '../src/ProcessHost.cs'
    $httpHash=(Get-FileHash -LiteralPath $httpPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $samples=@();$warmups=@();$summary=@();$levels=@(1,2,4,8);$artifacts=@()
    $reportStatus='complete';$abortReasonCode=$null;$bindingStatus='verified';$failedCondition=$null
    $failureCode='preparation-failed';$currentLength=$null;$currentClients=$null;$currentRound=$null
    $waveIssued=$false;$postChecked=$false;$precedingFailureCode=$null
    try {
    $max=($PromptTokens|Measure-Object -Maximum).Maximum
    $corpus=('A local inference system should produce accurate useful answers. Measure speed consistently while preserving model quality. '+[Environment]::NewLine)*([int][Math]::Ceiling($max/16)+2)
    $remaining=[int][Math]::Floor(($DeadlineSeconds-$clock.Elapsed.TotalSeconds)*1000)
    if($remaining -le 0){$failureCode='overall-deadline';throw 'Deadline.'}
    $failureCode='tokenization-failed'
    $tokenized=& $Request '/tokenize' @{content=$corpus;add_special=$false} ([Math]::Min(30000,$remaining))
    $failureCode='binding-changed-after-tokenization'
    $current=& $ReadState
    $null=Assert-FastLlmSemanticSmokeState $current $binding
    & $CheckProcess $current
    $failureCode='tokenization-failed'
    if($tokenized.Status -ne 200){throw 'Benchmark tokenization failed.'}
    $tokens=@((ConvertFrom-Json $tokenized.Body).tokens)
    if($tokens.Count -lt $max -or $tokens.Count -gt 100000){throw 'Tokenized corpus length outside benchmark bounds.'}
    $prompts=@{}
    foreach($length in $PromptTokens){
        $ids=@($tokens[0..($length-1)])
        $digest=Get-FastLlmPromptArtifactSha256 $ids
        $prompts[$length]=$ids
        $artifacts+= [pscustomobject]@{requestedPromptTokens=$length;tokenCount=$length;sha256=$digest;format='fastllm-prompt-tokens-v1'}
    }
    foreach($length in $PromptTokens){
        foreach($clients in $levels){
            for($round=0;$round -le $Repetitions;$round++){
                $currentLength=$length;$currentClients=$clients;$currentRound=$round
                $waveIssued=$false;$postChecked=$false
                if($clock.Elapsed.TotalSeconds -ge $DeadlineSeconds){$failureCode='overall-deadline';throw 'Deadline.'}
                $failureCode='binding-changed-before-wave'
                $current=& $ReadState
                $null=Assert-FastLlmSemanticSmokeState $current $binding
                & $CheckProcess $current
                $remaining=[int][Math]::Floor(($DeadlineSeconds-$clock.Elapsed.TotalSeconds)*1000)
                if($remaining -lt 1000){$failureCode='overall-deadline';throw 'Deadline.'}
                $body=@{prompt=$prompts[$length];n_predict=$GenerationTokens;temperature=0;seed=42;cache_prompt=$false;ignore_eos=$true;stream=$true}|ConvertTo-Json -Depth 8 -Compress
                $timeoutMs=[Math]::Min($remaining,[Math]::Min(1800000,$RequestTimeoutBaseSeconds*1000*$clients))
                $failureCode='wave-execution-failed'
                $waveIssued=$true
                $waveResult=& $Wave ($first.endpoint -replace '/v1$','') '/completion' $body $clients $timeoutMs
                $failureCode='malformed-wave'
                Assert-ConcurrencyWaveShape $waveResult $clients
                $requests=@();$successful=0;$totalOutput=0
                foreach($requestResult in @($waveResult.requests)){
                    $code=$requestResult.errorCode;$parsed=$null
                    if(-not $code){
                        try {
                            $parsed=ConvertFrom-FastLlmBenchmarkResponse $requestResult.response $GenerationTokens
                            if($parsed.promptTokens -notin @($length,($length+1))){throw 'Wrong prompt length.'}
                        }catch{$code='invalid-stream-or-count'}
                    }
                    if(-not $code){$successful++;$totalOutput+=$parsed.outputTokens}
                    $requests+= [pscustomobject]@{
                        client=$requestResult.client;dispatchStartMs=$requestResult.startedMs;httpFinishMs=$requestResult.finishedMs
                        status=$(if($code){'error'}else{'complete'});errorCode=$code
                        promptTokens=$(if($parsed){$parsed.promptTokens}else{$null});outputTokens=$(if($parsed){$parsed.outputTokens}else{$null})
                        timeToFirstTextMs=$(if($parsed){$parsed.timeToFirstTextMs}else{$null})
                        completionMs=$(if($parsed){$parsed.completionMs}else{$null})
                    }
                }
                $overlap=Get-ConcurrencyObservedOverlap $waveResult.requests
                $sample=[pscustomobject]@{
                    requestedPromptTokens=$length;promptArtifactSha256=($artifacts|Where-Object requestedPromptTokens -eq $length|Select-Object -First 1).sha256
                    requestedClients=$clients;serverSlots=[int]$first.recipe.slots;repetition=$round;warmup=($round -eq 0)
                    requestTimeoutMs=$timeoutMs
                    dispatchSpanMs=([double](@($waveResult.requests.startedMs|Measure-Object -Maximum).Maximum)-[double](@($waveResult.requests.startedMs|Measure-Object -Minimum).Minimum))
                    overlappingHttpRequestsPeak=$overlap;serverParallelDecodeObserved=$false
                    wallMs=[double]$waveResult.wallMs;successfulRequests=$successful;failedRequests=$clients-$successful
                    aggregateGeneratedTokensPerSecond=$(if($waveResult.wallMs -gt 0){1000.0*$totalOutput/[double]$waveResult.wallMs}else{$null})
                    requests=$requests
                }
                if($round -gt 0){$samples+=$sample}else{$warmups+=$sample}
                Write-Host "Private concurrency: prompt $length, clients $clients, repetition $round/$Repetitions, successes $successful/$clients"
                $failureCode='binding-changed-after-wave'
                $current=& $ReadState
                $null=Assert-FastLlmSemanticSmokeState $current $binding
                & $CheckProcess $current
                $postChecked=$true
                if($clock.Elapsed.TotalSeconds -gt $DeadlineSeconds){$failureCode='overall-deadline';throw 'Deadline.'}
                if($sample.failedRequests -gt 0){$failureCode='failed-wave';throw 'Wave has failed requests.'}
            }
        }
    }
    $failureCode='binding-changed-at-finish'
    $current=& $ReadState
    $null=Assert-FastLlmSemanticSmokeState $current $binding
    & $CheckProcess $current
    $failureCode='source-changed'
    if((Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $sourceHash -or
       (Get-FileHash -LiteralPath $canonicalPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $canonicalHash -or
       (Get-FileHash -LiteralPath $bindingPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $bindingHash -or
       (Get-FileHash -LiteralPath $httpPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $httpHash){throw 'Benchmark source changed during run.'}
    } catch {
        $reportStatus='aborted';$abortReasonCode=$failureCode
        if($failureCode -like 'binding-changed-*' -or $failureCode -eq 'source-changed'){$bindingStatus='compromised'}
        if($waveIssued -and -not $postChecked){
            try {
                $current=& $ReadState
                $null=Assert-FastLlmSemanticSmokeState $current $binding
                & $CheckProcess $current
            } catch {
                $precedingFailureCode=$abortReasonCode
                $abortReasonCode='binding-changed-after-wave'
                $bindingStatus='compromised'
            }
        }
        $failedCondition=[pscustomobject]@{requestedPromptTokens=$currentLength;requestedClients=$currentClients;
            repetition=$currentRound;warmup=($currentRound -eq 0);reasonCode=$abortReasonCode}
    }
    if($reportStatus -eq 'aborted' -and $bindingStatus -ne 'compromised'){
        try {
            $current=& $ReadState
            $null=Assert-FastLlmSemanticSmokeState $current $binding
            & $CheckProcess $current
        } catch {
            $precedingFailureCode=$abortReasonCode
            $abortReasonCode='binding-changed-after-abort'
            $bindingStatus='compromised'
            $failedCondition.reasonCode=$abortReasonCode
        }
    }
    $sourceStatus='verified'
    try {
        if((Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $sourceHash -or
           (Get-FileHash -LiteralPath $canonicalPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $canonicalHash -or
           (Get-FileHash -LiteralPath $bindingPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $bindingHash -or
           (Get-FileHash -LiteralPath $httpPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $httpHash){$sourceStatus='changed'}
    }catch{$sourceStatus='unavailable'}
    if($sourceStatus -ne 'verified'){
        $bindingStatus='compromised'
        if($reportStatus -eq 'complete'){$reportStatus='aborted';$abortReasonCode='source-changed';$failedCondition=[pscustomobject]@{requestedPromptTokens=$null;requestedClients=$null;repetition=$null;warmup=$null;reasonCode=$abortReasonCode}}
    }
    foreach($length in $PromptTokens){
        foreach($clients in $levels){
            $group=@($samples|Where-Object {$_.requestedPromptTokens -eq $length -and $_.requestedClients -eq $clients})
            $valid=@($group|Where-Object failedRequests -eq 0)
            $completed=@($group|ForEach-Object requests|Where-Object status -eq 'complete')
            $summary+= [pscustomobject]@{requestedPromptTokens=$length;requestedClients=$clients;serverSlots=1;repetitions=$Repetitions;
                successfulWaves=$valid.Count;failedWaves=$group.Count-$valid.Count;
                aggregateGeneratedTokensPerSecondIncludingFailures=$(if($group.Count){Get-FastLlmStatistics @($group|ForEach-Object aggregateGeneratedTokensPerSecond)}else{$null});
                wallMsIncludingFailures=$(if($group.Count){Get-FastLlmStatistics @($group|ForEach-Object wallMs)}else{$null});
                successfulRequestFirstTextMs=$(if($completed.Count){Get-FastLlmStatistics @($completed|ForEach-Object timeToFirstTextMs)}else{$null});
                successfulRequestCompletionMs=$(if($completed.Count){Get-FastLlmStatistics @($completed|ForEach-Object completionMs)}else{$null})}
        }
    }
    $report=[ordered]@{
        schemaVersion=1;resultKind='native-windows-api-private-concurrency-benchmark';recordedAt=(Get-Date).ToUniversalTime().ToString('o')
        reportStatus=$reportStatus;abortReasonCode=$abortReasonCode;precedingFailureCode=$precedingFailureCode;
        bindingStatus=$bindingStatus;failedCondition=$failedCondition
        runId=$first.runId;processIdentity=$first.processIdentity;modelId=$first.modelId;modelSha256=$first.modelSha256;engineVersion=$first.engineVersion
        recipe=$first.recipe;endpoint=$first.endpoint;placement=$first.placement;canary=$first.canary;evidenceBindingSha256=$binding
        sourceProvenance=@{concurrencyScriptSha256=$sourceHash;canonicalBenchmarkParserSha256=$canonicalHash;
            runBindingHelperSha256=$bindingHash;httpHelperSourceSha256=$httpHash;
            endStatus=$sourceStatus;scope='On-disk source hashes observed at start and end; loaded-code identity is not attested.'}
        methodology=@{corpus='fastllm-repeated-prose-v1';sampling='greedy-seed42';prefixCache=$false;warmupWavesPerCondition=1;
            repetitions=$Repetitions;promptArtifacts=$artifacts;generationTokens=$GenerationTokens;requestedClientLevels=$levels;
            clientPromptPolicy='same fixed numeric prompt array per client at each length; a mixed subagent task workload is not represented';
            conditionOrder='prompt lengths in supplied order; clients 1,2,4,8 within each length; one warmup then repetitions; unrandomized';
            start='client threads released from a shared barrier';serverSlots=1;interpretation='Overlapping HTTP calls may queue at the single server slot; parallel decode is unverified.';
            aggregateRate='sum of successful generated token counts divided by common wave wall time, including failed request deadlines';
            requestTimeoutBaseSeconds=$RequestTimeoutBaseSeconds;requestTimeoutRule='minimum of overall time remaining, 1800 seconds, and base seconds times requested clients';
            overallDeadlineSeconds=$DeadlineSeconds}
        warmupWaves=$warmups;samples=$samples;summary=$summary
        qualification=@{approved=$false;qualityEvaluation=$false;physicalResidency=$false;peakVramMeasured=$false;exclusiveWorkloadConfirmed=$false;parallelDecodeVerified=$false}
    }
    $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $report -Depth 20))
    $stream=[IO.File]::Open($full,'CreateNew','Write','None')
    try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
    return $report
}

if($MyInvocation.InvocationName -ne '.'){
    if($env:OS -ne 'Windows_NT'){throw 'Private concurrency benchmarks require native Windows.'}
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run as a standard user.'}
    # Worker-only flags are an internal controller protocol, not an access-control
    # boundary. The caller must hold benchmark.lock and contain this child in its
    # kill-on-close job for the entire measurement.
    if($WorkerMode){
        if($WorkerNonce -cnotmatch '^[0-9a-f]{32}$' -or $env:FASTLLM_CONCURRENCY_NONCE -cne $WorkerNonce){throw 'Unbound concurrency worker invocation.'}
        if($WorkerPromptCsv -cnotmatch '^[0-9]{1,5}(,[0-9]{1,5}){0,3}$'){throw 'Worker prompt lengths are invalid.'}
        $PromptTokens=@($WorkerPromptCsv.Split(',')|ForEach-Object {[int]$_})
    }elseif($WorkerNonce -or $WorkerPromptCsv){throw 'Worker-only parameters are not accepted for the controller.'}
    $module=Import-Module (Join-Path $PSScriptRoot '../src/FastLlm.psm1') -Force -PassThru
    if($WorkerMode){
        $result=& $module {
            param($ScriptPath,$InstallRoot,$OutputPath,$PromptTokens,$GenerationTokens,$Repetitions,$DeadlineSeconds,$RequestTimeoutBaseSeconds)
            . (Join-Path $PSScriptRoot 'FastLlm.SemanticSmoke.ps1')
            . $ScriptPath -InstallRoot $InstallRoot -OutputPath $OutputPath -PromptTokens $PromptTokens `
                -GenerationTokens $GenerationTokens -Repetitions $Repetitions -DeadlineSeconds $DeadlineSeconds `
                -RequestTimeoutBaseSeconds $RequestTimeoutBaseSeconds
            Initialize-FastLlmProcessHost
            Assert-ConcurrencyControllerLock -InstallRoot $InstallRoot
            Invoke-ConcurrencyBenchmarkCore -OutputPath $OutputPath -PromptTokens $PromptTokens -GenerationTokens $GenerationTokens -Repetitions $Repetitions -DeadlineSeconds $DeadlineSeconds -RequestTimeoutBaseSeconds $RequestTimeoutBaseSeconds `
                -ReadState {Get-FastLlmStatus $InstallRoot} -CheckProcess {param($State) Assert-FastLlmSemanticSmokeProcess $State} `
                -Request {param($Path,$Body,$Timeout) Invoke-FastLlmHttp -BaseUrl 'http://127.0.0.1:8080' -Path $Path -Body $Body -TimeoutMs $Timeout} `
                -Wave {param($Base,$Path,$Body,$Count,$Timeout) Invoke-ConcurrencyWave -Url ($Base+$Path) -Body $Body -Clients $Count -TimeoutMs $Timeout}
        } $PSCommandPath $InstallRoot $OutputPath $PromptTokens $GenerationTokens $Repetitions $DeadlineSeconds $RequestTimeoutBaseSeconds
        if($result.reportStatus -ne 'complete'){throw "Concurrency benchmark aborted; report saved with reason code $($result.abortReasonCode)."}
    }else{
        Assert-ConcurrencyArguments $PromptTokens $GenerationTokens 32768
        $outFull=[IO.Path]::GetFullPath($OutputPath)
        if(Test-Path -LiteralPath $outFull){throw 'Concurrency report already exists.'}
        $status=& $module {param($Root) Get-FastLlmStatus $Root} $InstallRoot
        $null=& $module {param($ScriptPath,$State) . (Join-Path $PSScriptRoot 'FastLlm.SemanticSmoke.ps1'); Assert-FastLlmSemanticSmokeState $State} $PSCommandPath $status
        $root=& $module {param($Root) Get-FastLlmStateRoot $Root} $InstallRoot
        $lockPath=Join-Path $root 'benchmark.lock'
        if((Test-Path -LiteralPath $lockPath) -and ((Get-Item -LiteralPath $lockPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Unsafe benchmark lock.'}
        $lock=[IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None')
        try {
            $nonce=[Guid]::NewGuid().ToString('N')
            $exe=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            $workerArguments=@('-NoLogo','-NoProfile','-NonInteractive','-File',$PSCommandPath,
                '-WorkerMode','-WorkerNonce',$nonce,'-WorkerPromptCsv',($PromptTokens -join ','),
                '-InstallRoot',$InstallRoot,'-OutputPath',$outFull,'-GenerationTokens',([string]$GenerationTokens),
                '-Repetitions',([string]$Repetitions),'-DeadlineSeconds',([string]$DeadlineSeconds),
                '-RequestTimeoutBaseSeconds',([string]$RequestTimeoutBaseSeconds))
            $worker=& $module {
                param($ScriptPath,$Exe,$ArgumentVector,$Seconds,$Nonce)
                . $ScriptPath -OutputPath (Join-Path ([IO.Path]::GetTempPath()) 'unused-concurrency-worker.json')
                Invoke-ConcurrencyContainedWorker -Executable $Exe -Arguments $ArgumentVector -WorkingDirectory (Split-Path $ScriptPath -Parent) `
                    -DeadlineMilliseconds (($Seconds+15)*1000) -Nonce $Nonce
            } $PSCommandPath $exe $workerArguments $DeadlineSeconds $nonce
            if($worker.timedOut){
                $failure=Save-ConcurrencyControllerFailure -OutputPath $outFull -State $status -ReasonCode 'contained-worker-deadline'
                throw "Contained concurrency worker reached its deadline and was terminated. Private failure metadata: $failure"
            }
            if($worker.exitCode -ne 0){
                if(Test-Path -LiteralPath $outFull){Write-Host "Private concurrency report saved: $outFull (aborted)."}
                else{$failure=Save-ConcurrencyControllerFailure -OutputPath $outFull -State $status -ReasonCode 'contained-worker-failed-before-report';Write-Host "Private failure metadata: $failure"}
                throw 'Contained concurrency worker failed; inspect only its private report status.'
            }
            if(-not (Test-Path -LiteralPath $outFull -PathType Leaf)){
                $failure=Save-ConcurrencyControllerFailure -OutputPath $outFull -State $status -ReasonCode 'contained-worker-missing-report'
                throw "Contained worker exited without a report. Private failure metadata: $failure"
            }
            $item=Get-Item -LiteralPath $outFull -Force
            if($item.Length -gt 16777216 -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){
                $failure=Save-ConcurrencyControllerFailure -OutputPath $outFull -State $status -ReasonCode 'contained-worker-unsafe-report'
                throw "Unsafe or oversized concurrency report. Private failure metadata: $failure"
            }
            try{$final=Get-Content -LiteralPath $outFull -Raw|ConvertFrom-Json}
            catch{$failure=Save-ConcurrencyControllerFailure -OutputPath $outFull -State $status -ReasonCode 'contained-worker-invalid-report';throw "Invalid contained-worker report. Private failure metadata: $failure"}
            if($final.reportStatus -cne 'complete' -or $final.runId -cne $status.runId){throw 'Contained worker report is aborted or bound to a different run.'}
            Write-Host "Saved private concurrency report $outFull (complete). This server has one slot. No qualification granted."
        }finally{$lock.Dispose()}
    }
}
