#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force -PassThru
& $module {Initialize-FastLlmProcessHost}
$collectorSource=Get-Content -LiteralPath (Join-Path $root 'tools/concurrency-benchmark.ps1') -Raw
. (Join-Path $root 'src/FastLlm.SemanticSmoke.ps1')
. (Join-Path $root 'src/FastLlm.Benchmark.ps1')
. (Join-Path $root 'tools/concurrency-benchmark.ps1') -OutputPath (Join-Path $PSScriptRoot 'unused-concurrency-report.json')
$count=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:count++;Write-Host "PASS: $Message"}
Check (-not $collectorSource.Contains("'-ExecutionPolicy'") -and -not $collectorSource.Contains('PSExecutionPolicyPreference')) 'contained worker inherits the effective script policy without a weaker override'

$bad=$false
try{Assert-ConcurrencyArguments @(512,4096) 128 4096}catch{$bad=$true}
Check $bad 'context rejects a workload exceeding available tokens'
$bad=$false
try{Assert-ConcurrencyArguments @(512,512) 128 8192}catch{$bad=$true}
Check $bad 'duplicate prompt lengths are rejected'
Assert-ConcurrencyArguments @(512,4096,8192) 128 16384
Check $true 'short, normal and stress prompt lengths fit a recorded effective context'

$overlap=Get-ConcurrencyObservedOverlap @(
    [pscustomobject]@{startedMs=10;finishedMs=100},
    [pscustomobject]@{startedMs=20;finishedMs=90},
    [pscustomobject]@{startedMs=30;finishedMs=40},
    [pscustomobject]@{startedMs=100;finishedMs=110})
Check ($overlap -eq 3) 'overlap is based on measured HTTP intervals'
$missing=[pscustomobject]@{schemaVersion=1;active=$true;phase='ready';endpoint='http://127.0.0.1:8080/v1';runId=('a'*32);
    modelId='test';modelSha256=('b'*64);engineVersion='b10698';recipe=[pscustomobject]@{backend='Vulkan';engineSha256=('c'*64);catalogSha256=('d'*64);contextSize=8192;slots=1};processIdentity=$null}
$bad=$false
try{$null=Assert-FastLlmSemanticSmokeState $missing}catch{$bad=$true}
Check $bad 'missing supervised process identity fails closed'
$entryArgs=& $module {
    param($Tool)
    $InstallRoot='custom-cache';$OutputPath='custom-output.json';$PromptTokens=@(512,8192)
    $GenerationTokens=256;$Repetitions=7;$DeadlineSeconds=4200;$RequestTimeoutBaseSeconds=240
    . $Tool -InstallRoot $InstallRoot -OutputPath $OutputPath -PromptTokens $PromptTokens `
        -GenerationTokens $GenerationTokens -Repetitions $Repetitions -DeadlineSeconds $DeadlineSeconds `
        -RequestTimeoutBaseSeconds $RequestTimeoutBaseSeconds
    [pscustomobject]@{root=$InstallRoot;output=$OutputPath;prompts=$PromptTokens;generation=$GenerationTokens;
        repetitions=$Repetitions;deadline=$DeadlineSeconds;requestBase=$RequestTimeoutBaseSeconds}
} (Join-Path $root 'tools/concurrency-benchmark.ps1')
Check ($entryArgs.root -eq 'custom-cache' -and $entryArgs.output -eq 'custom-output.json' -and
    @($entryArgs.prompts).Count -eq 2 -and $entryArgs.prompts[1] -eq 8192 -and
    $entryArgs.generation -eq 256 -and $entryArgs.repetitions -eq 7 -and $entryArgs.deadline -eq 4200 -and
    $entryArgs.requestBase -eq 240) 'module-scope entry keeps all requested workload and timeout parameters'

$runId=('a'*32)
$recipe=[pscustomobject]@{backend='Vulkan';engineSha256=('c'*64);catalogSha256=('d'*64);contextSize=256;slots=1;
    requestedArguments=@('--host','127.0.0.1','--port','8080','--alias','test','--parallel','1','--ctx-size','256')}
$state=[pscustomobject]@{schemaVersion=1;active=$true;phase='ready';endpoint='http://127.0.0.1:8080/v1';runId=$runId;
    modelId='test';modelSha256=('b'*64);engineVersion='b10698';recipe=$recipe;
    processIdentity=[pscustomobject]@{pid=123;startUtcTicks=123456789};
    canary=[pscustomobject]@{modelIdentity=$true;repeatableToken=$true;synchronousChat=$true;streaming=$true;semanticCorrectnessQualified=$false;effectiveContext=256};
    placement=[pscustomobject]@{reportedAllLayers=$true;reportedLayers=1;totalLayers=1;devices=@('Vulkan0')}}
function New-ConcurrencyTestWave([int]$Clients){
    $out=@(for($i=1;$i -le $Clients;$i++){
        $response=[pscustomobject]@{Status=200;Events=@('{"content":"X","stop":false}',
            '{"content":"","stop":true,"timings":{"prompt_n":16,"prompt_ms":20,"predicted_n":8,"predicted_ms":40}}');
            EventTimesMs=@(10,80);ElapsedMs=90}
        [pscustomobject]@{client=$i;startedMs=0;finishedMs=100;response=$response;errorCode=$null}
    })
    return [pscustomobject]@{releasedMs=0;wallMs=100;requests=$out}
}
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('fastllm-concurrency-test-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($scratch)
try {
    $reportPath=Join-Path $scratch 'result.json'
    $report=Invoke-ConcurrencyBenchmarkCore -OutputPath $reportPath -PromptTokens @(16) -GenerationTokens 8 -Repetitions 1 -DeadlineSeconds 60 -RequestTimeoutBaseSeconds 30 `
        -ReadState {$state} -CheckProcess {param($Current) if($Current.runId -cne $runId){throw 'run changed'}} `
        -Request {param($Path,$Body,$Timeout) [pscustomobject]@{Status=200;Body=('{"tokens":['+((1..32)-join ',')+']}')} } `
        -Wave {
            param($Base,$Path,$Body,$Clients,$Timeout)
            $result=New-ConcurrencyTestWave $Clients
            if($Clients -eq 8){$result.requests[-1].response=$null;$result.requests[-1].errorCode='request-error'}
            $result
        }
    Check ($report.samples.Count -eq 3 -and $report.warmupWaves.Count -eq 4 -and $report.summary.Count -eq 4) 'completed measured waves and the failed warmup are retained'
    Check ($report.reportStatus -eq 'aborted' -and $report.abortReasonCode -eq 'failed-wave' -and
        $report.failedCondition.requestedClients -eq 8 -and $report.failedCondition.warmup -eq $true -and
        $report.warmupWaves[-1].aggregateGeneratedTokensPerSecond -eq 560 -and $report.warmupWaves[-1].failedRequests -eq 1) 'failed warmup halts escalation and retains its shared wall denominator'
    $disk=Get-Content -LiteralPath $reportPath -Raw
    Check ($disk.Contains('native-windows-api-private-concurrency-benchmark') -and -not $disk.Contains('"content":"X"')) 'private report is saved without completion text'

    $script:waveCount=0
    $deadlinePath=Join-Path $scratch 'deadline.json'
    $deadlineReport=Invoke-ConcurrencyBenchmarkCore -OutputPath $deadlinePath -PromptTokens @(16) -GenerationTokens 8 -Repetitions 1 -DeadlineSeconds 3 -RequestTimeoutBaseSeconds 1 `
        -ReadState {$state} -CheckProcess {param($Current)} `
        -Request {param($Path,$Body,$Timeout) [pscustomobject]@{Status=200;Body=('{"tokens":['+((1..32)-join ',')+']}')} } `
        -Wave {param($Base,$Path,$Body,$Clients,$Timeout) $script:waveCount++;if($script:waveCount -eq 2){Start-Sleep -Milliseconds 3500};New-ConcurrencyTestWave $Clients}
    Check ($deadlineReport.reportStatus -eq 'aborted' -and $deadlineReport.abortReasonCode -eq 'overall-deadline' -and
        $deadlineReport.samples.Count -eq 1 -and $deadlineReport.warmupWaves.Count -eq 1 -and (Test-Path -LiteralPath $deadlinePath)) 'deadline saves the completed measured wave and stops further levels'

    $changedState=$state|ConvertTo-Json -Depth 16|ConvertFrom-Json
    $changedState.runId=('f'*32)
    $script:readCount=0
    $identityPath=Join-Path $scratch 'identity.json'
    $identityReport=Invoke-ConcurrencyBenchmarkCore -OutputPath $identityPath -PromptTokens @(16) -GenerationTokens 8 -Repetitions 1 -DeadlineSeconds 60 -RequestTimeoutBaseSeconds 30 `
        -ReadState {$script:readCount++;if($script:readCount -ge 6){$changedState}else{$state}} -CheckProcess {param($Current)} `
        -Request {param($Path,$Body,$Timeout) [pscustomobject]@{Status=200;Body=('{"tokens":['+((1..32)-join ',')+']}')} } `
        -Wave {param($Base,$Path,$Body,$Clients,$Timeout) New-ConcurrencyTestWave $Clients}
    Check ($identityReport.reportStatus -eq 'aborted' -and $identityReport.abortReasonCode -eq 'binding-changed-after-wave' -and
        $identityReport.bindingStatus -eq 'compromised' -and $identityReport.samples.Count -eq 1 -and
        $identityReport.qualification.approved -eq $false) 'post-wave identity change persists prior sample but marks report compromised'

    $shapePath=Join-Path $scratch 'shape.json'
    $shapeReport=Invoke-ConcurrencyBenchmarkCore -OutputPath $shapePath -PromptTokens @(16) -GenerationTokens 8 -Repetitions 1 -DeadlineSeconds 60 -RequestTimeoutBaseSeconds 30 `
        -ReadState {$state} -CheckProcess {param($Current)} `
        -Request {param($Path,$Body,$Timeout) [pscustomobject]@{Status=200;Body=('{"tokens":['+((1..32)-join ',')+']}')} } `
        -Wave {param($Base,$Path,$Body,$Clients,$Timeout) $wave=New-ConcurrencyTestWave $Clients;if($Clients -eq 2){$wave.requests=@($wave.requests[0])};$wave}
    Check ($shapeReport.reportStatus -eq 'aborted' -and $shapeReport.abortReasonCode -eq 'malformed-wave' -and
        $shapeReport.failedCondition.requestedClients -eq 2 -and $shapeReport.failedCondition.warmup -eq $true -and
        $shapeReport.samples.Count -eq 1 -and $shapeReport.warmupWaves.Count -eq 1) 'malformed wave cardinality saves a partial report and prevents higher client levels'

    $controllerPath=Join-Path $scratch 'controller-failure.json'
    $saved=Save-ConcurrencyControllerFailure -OutputPath $controllerPath -State $state -ReasonCode 'contained-worker-deadline'
    $controllerReport=Get-Content -LiteralPath $saved -Raw|ConvertFrom-Json
    Check ($saved -eq $controllerPath -and $controllerReport.reportStatus -eq 'aborted' -and
        $controllerReport.workerTerminatedConfirmed -eq $true -and @($controllerReport.samples).Count -eq 0 -and
        $controllerReport.controllerOutcomeAuthoritative -eq $true -and $controllerReport.primaryReportPresent -eq $false -and
        $controllerReport.qualification.approved -eq $false) 'parent failure report has no invented samples or approval'
    $second=Save-ConcurrencyControllerFailure -OutputPath $controllerPath -State $state -ReasonCode 'contained-worker-invalid-report'
    $sidecar=Get-Content -LiteralPath $second -Raw|ConvertFrom-Json
    Check ($second -ne $controllerPath -and (Test-Path -LiteralPath $second) -and
        $sidecar.controllerOutcomeAuthoritative -eq $true -and $sidecar.primaryReportPresent -eq $true -and
        (Get-Content -LiteralPath $controllerPath -Raw|ConvertFrom-Json).abortReasonCode -eq 'contained-worker-deadline') 'controller sidecar is authoritative and never overwrites an existing child report'
    $lockCheck=& $module {
        param($Tool,$Scratch)
        . $Tool -OutputPath (Join-Path $Scratch 'unused-lock-check.json')
        $install=Join-Path $Scratch 'install'
        $stateRoot=Get-FastLlmStateRoot -InstallRoot $install -Create
        $lockPath=Join-Path $stateRoot 'benchmark.lock'
        $stream=[IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None')
        try{Assert-ConcurrencyControllerLock -InstallRoot $install;$whileHeld=$true}finally{$stream.Dispose()}
        $unlockedRejected=$false
        try{Assert-ConcurrencyControllerLock -InstallRoot $install}catch{$unlockedRejected=$true}
        [pscustomobject]@{whileHeld=$whileHeld;unlockedRejected=$unlockedRejected}
    } (Join-Path $root 'tools/concurrency-benchmark.ps1') $scratch
    Check ($lockCheck.whileHeld -and $lockCheck.unlockedRejected) 'worker-only path requires the controller benchmark lock to remain held'
} finally {
    if(Test-Path -LiteralPath $scratch){[IO.Directory]::Delete($scratch,$true)}
}

$listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
$listener.Start();$port=([Net.IPEndPoint]$listener.LocalEndpoint).Port;$listener.Stop()
$mock=Join-Path $PSScriptRoot 'helpers/mock-benchmark-server.ps1'
$process=$null
try {
    $process=Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-File',('"'+$mock+'"'),'-Port',$port,'-Mode','normal') -PassThru
    $url="http://127.0.0.1:$port/health"
    $healthy=$false
    for($attempt=0;$attempt -lt 50;$attempt++){
        try{if([Bitworks.FastLlm.LoopbackHttp]::Request($url,$null,1000,1048576).Status -eq 200){$healthy=$true;break}}catch{}
        Start-Sleep -Milliseconds 100
    }
    Check $healthy 'mock HTTP child is available for concurrent requests'
    $wave=Invoke-ConcurrencyWave -Url $url -Body '' -Clients 4 -TimeoutMs 5000
    Check ($wave.requests.Count -eq 4 -and @($wave.requests|Where-Object {$_.response.Status -eq 200}).Count -eq 4) 'four concurrent client calls complete against a serialized mock server'
    Check ((Get-ConcurrencyObservedOverlap $wave.requests) -ge 2 -and $wave.wallMs -gt 0) 'released clients have measured overlapping HTTP intervals and a positive shared wall time'
    Check (@($wave.requests|Where-Object errorCode).Count -eq 0) 'wave retains every client result without a synthetic failure'
} finally {
    if($process){try{$process.Kill()}catch{};try{$process.WaitForExit(5000)|Out-Null}catch{};$process.Dispose()}
}
$stallPortListener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
$stallPortListener.Start();$stallPort=([Net.IPEndPoint]$stallPortListener.LocalEndpoint).Port;$stallPortListener.Stop()
$stallScript=Join-Path $PSScriptRoot 'helpers/mock-concurrency-stall-server.ps1'
$stallProcess=$null
try {
    $stallProcess=Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-File',('"'+$stallScript+'"'),'-Port',$stallPort) -PassThru
    $reachable=$false
    for($attempt=0;$attempt -lt 50;$attempt++){
        $client=New-Object Net.Sockets.TcpClient
        try{$client.Connect([Net.IPAddress]::Loopback,$stallPort);$reachable=$true;break}catch{Start-Sleep -Milliseconds 100}finally{$client.Dispose()}
    }
    Check $reachable 'silent mock listener is ready for HTTP timeout test'
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $timedWave=Invoke-ConcurrencyWave -Url "http://127.0.0.1:$stallPort/completion" -Body '{"stream":true}' -Clients 4 -TimeoutMs 1000
    $timer.Stop()
    Check ($timedWave.requests.Count -eq 4 -and @($timedWave.requests|Where-Object errorCode -eq 'request-error').Count -eq 4 -and
        $timer.Elapsed.TotalSeconds -lt 10) 'silent HTTP child produces four bounded request failures without blocked cleanup'
} finally {
    if($stallProcess){try{$stallProcess.Kill()}catch{};try{$stallProcess.WaitForExit(5000)|Out-Null}catch{};$stallProcess.Dispose()}
}
$hungWorker=Join-Path $PSScriptRoot 'helpers/mock-concurrency-hung-worker.ps1'
$contained=& $module {
    param($Tool,$Executable,$Mock)
    . $Tool -OutputPath (Join-Path ([IO.Path]::GetTempPath()) 'unused-concurrency-container.json')
    Invoke-ConcurrencyContainedWorker -Executable $Executable -Arguments @('-NoProfile','-File',$Mock) `
        -WorkingDirectory (Split-Path $Mock -Parent) -DeadlineMilliseconds 1000 -Nonce ([Guid]::NewGuid().ToString('N'))
} (Join-Path $root 'tools/concurrency-benchmark.ps1') (Get-Process -Id $PID).Path $hungWorker
$stillAlive=$false
try{$aliveProcess=[Diagnostics.Process]::GetProcessById([int]$contained.pid);$stillAlive=-not $aliveProcess.HasExited;$aliveProcess.Dispose()}catch{}
Check ($contained.timedOut -and $contained.terminatedConfirmed -and -not $stillAlive) 'contained hung worker is terminated before parent can release the benchmark lock'
Write-Host "$count private concurrency checks passed; no GPU benchmark or qualification run."
