# Private HIP semantic parity check. Reuses the unchanged fixed cases and
# response parser; this never enters the normal semantic/benchmark result lane.
function Invoke-FastLlmHipSemanticSmokeCore {
    param([string]$OutputPath,[string]$RunId,[scriptblock]$ReadState,[scriptblock]$Request,
          [scriptblock]$CheckProcess,[int]$DeadlineSeconds=240)
    if($RunId -cnotmatch '^[0-9a-f]{32}$' -or $DeadlineSeconds -lt 1 -or $DeadlineSeconds -gt 240){
        throw 'HIP semantic run ID or elapsed budget is invalid.'
    }
    if(Test-Path -LiteralPath $OutputPath){throw 'HIP semantic output already exists.'}
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $paths=[ordered]@{
        hipSemantic=Join-Path $PSScriptRoot 'FastLlm.HipSemanticSmoke.ps1'
        fixedCasesAndParser=Join-Path $PSScriptRoot 'FastLlm.SemanticSmoke.ps1'
        hipBindingAndProcess=Join-Path $PSScriptRoot 'FastLlm.HipBenchmark.ps1'
        hipTrial=Join-Path $PSScriptRoot 'FastLlm.HipModelTrial.ps1'
    }
    $hashes=[ordered]@{}
    foreach($key in $paths.Keys){$hashes[$key+'Sha256']=(Get-FileHash -LiteralPath $paths[$key] -Algorithm SHA256).Hash.ToLowerInvariant()}
    $first=& $ReadState
    if($first.runId -cne $RunId){throw 'HIP semantic run ID differs from the requested private trial.'}
    $binding=Assert-FastLlmHipBenchmarkState -State $first
    if($first.trialSourceSha256 -cne $hashes.hipTrialSha256){throw 'HIP trial launch-source hash differs from the measured source.'}
    & $CheckProcess $first
    $cases=@();$aborted=$false
    foreach($case in @(Get-FastLlmSemanticSmokeCases)){
        $outcome='inconclusive';$errorCode=$null;$outputTokens=$null;$fatal=$false
        try{
            $current=& $ReadState
            if($current.runId -cne $RunId){throw 'HIP run changed.'}
            $null=Assert-FastLlmHipBenchmarkState -State $current -ExpectedBinding $binding
            & $CheckProcess $current
            $remaining=[int][Math]::Floor(($DeadlineSeconds-$timer.Elapsed.TotalSeconds)*1000)
            if($remaining -le 0){$errorCode='deadline';$fatal=$true}
            else{
                $body=@{model=$first.modelId;messages=@(@{role='user';content=$case.prompt});max_tokens=96;
                    temperature=0;seed=42;stream=$false;cache_prompt=$false;
                    chat_template_kwargs=@{enable_thinking=$false}}
                try{$response=& $Request '/v1/chat/completions' $body ([Math]::Min(60000,$remaining))}
                catch{$errorCode='request-error'}
                $current=& $ReadState
                if($current.runId -cne $RunId){throw 'HIP run changed.'}
                $null=Assert-FastLlmHipBenchmarkState -State $current -ExpectedBinding $binding
                & $CheckProcess $current
                if(-not $errorCode){
                    $parsed=ConvertFrom-FastLlmSemanticSmokeResponse -Response $response -Case $case
                    $outcome=$parsed.outcome;$errorCode=$parsed.errorCode;$outputTokens=$parsed.outputTokens
                }
                if($timer.Elapsed.TotalSeconds -gt $DeadlineSeconds){$outcome='inconclusive';$errorCode='deadline';$fatal=$true}
            }
        }catch{$outcome='inconclusive';$errorCode='identity-changed';$fatal=$true}
        $cases+= [pscustomobject]@{caseId=$case.id;promptSha256=(Get-FastLlmSemanticSmokeSha256 $case.prompt);
            outcome=$outcome;errorCode=$errorCode;outputTokens=$outputTokens}
        if($fatal){$aborted=$true;break}
    }
    try{
        $current=& $ReadState
        if($current.runId -cne $RunId){throw 'HIP run changed.'}
        $null=Assert-FastLlmHipBenchmarkState -State $current -ExpectedBinding $binding
        & $CheckProcess $current
    }catch{$aborted=$true}
    foreach($key in $paths.Keys){
        if((Get-FileHash -LiteralPath $paths[$key] -Algorithm SHA256).Hash.ToLowerInvariant() -cne $hashes[$key+'Sha256']){
            throw 'HIP semantic source dependency changed during evaluation.'
        }
    }
    $passed=@($cases|Where-Object outcome -eq 'pass').Count
    $failed=@($cases|Where-Object outcome -eq 'fail').Count
    $inconclusive=@($cases|Where-Object outcome -eq 'inconclusive').Count
    $report=[ordered]@{
        schemaVersion=1;resultKind='native-windows-hip-semantic-smoke-experiment';recordedAt=(Get-Date).ToUniversalTime().ToString('o')
        runId=$first.runId;processIdentity=$first.processIdentity;modelId=$first.modelId;modelSha256=$first.modelSha256
        engineVersion=$first.engineVersion;engineSha256=$first.engineSha256;catalogSha256=$first.catalogSha256
        trialSourceSha256=$first.trialSourceSha256;endpoint=$first.endpoint;contextSize=[int]$first.recipe.contextSize
        evidenceBindingSha256=$binding;allowHostModelBuffer=$first.allowHostModelBuffer
        placementClassification=$first.placementClassification;placementEvidence=$first.placementEvidence
        reportedHostModelBufferMiB=if($first.allowHostModelBuffer){[double]@($first.placementEvidence.modelBuffers|Where-Object {$_.device -ceq 'CPU_Mapped'})[0].sizeMiB}else{$null}
        allWeightsOnGpuVerified=$false;allOperationsOnGpuVerified=$false;cpuInputEvidence='not-attested'
        sourceProvenance=@{hipSemanticSha256=$hashes.hipSemanticSha256;fixedCasesAndParserSha256=$hashes.fixedCasesAndParserSha256;
            hipBindingAndProcessSha256=$hashes.hipBindingAndProcessSha256;hipTrialSha256=$hashes.hipTrialSha256;
            scope='trial launch-source SHA matches on-disk source; all helper hashes checked start/end; loaded-code identity is not attested'}
        methodology=@{caseSet='fastllm-fixed-semantic-smoke-v1';sampling='temperature-0-seed-42';thinkingRequested=$false
            prefixCache=$false;maxOutputTokens=96;concurrency=1;elapsedBudgetSeconds=$DeadlineSeconds
            requestTimeoutMaximumSeconds=60;hardWallClockDeadline=$false
            interpretation='tiny hand-authored canary; elapsed request budget does not preempt OS process or file calls'}
        cases=$cases;passed=$passed;failed=$failed;inconclusive=$inconclusive;aborted=$aborted
        status=$(if($aborted){'aborted'}elseif($inconclusive -gt 0){'inconclusive'}elseif($failed -gt 0){'semantic-failures'}else{'smoke-passed'})
        qualification=@{approved=$false;semanticQualified=$false;qualityEvaluation=$false;performanceQualified=$false
            physicalResidency=$false;allWeightsOnGpuVerified=$false;allOperationsOnGpuVerified=$false}
    }
    $full=[IO.Path]::GetFullPath($OutputPath)
    New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force -ErrorAction Stop|Out-Null
    $file=[IO.File]::Open($full,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$bytes=[Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 16));$file.Write($bytes,0,$bytes.Length)}finally{$file.Dispose()}
    return [pscustomobject]$report
}

function Invoke-FastLlmHipSemanticSmoke {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$RunRoot,[Parameter(Mandatory=$true)][string]$RunId,
          [Parameter(Mandatory=$true)][string]$OutputPath)
    Assert-FastLlmHipLabIdentity
    Assert-FastLlmOffloadRootPath $RunRoot
    if(Test-Path -LiteralPath $OutputPath){throw 'HIP semantic output already exists.'}
    $stateRoot=Get-FastLlmStateRoot -InstallRoot $RunRoot
    $lockPath=Join-FastLlmContainedPath -Root $stateRoot -Child 'hip-benchmark.lock'
    if((Test-Path -LiteralPath $lockPath) -and ((Get-Item -LiteralPath $lockPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){
        throw 'Unsafe HIP benchmark lock.'
    }
    try{$lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
    catch{throw 'Another HIP benchmark or semantic smoke is active.'}
    try{
        return Invoke-FastLlmHipSemanticSmokeCore -OutputPath $OutputPath -RunId $RunId `
            -ReadState {Get-FastLlmHipTrialStatus -RunRoot $RunRoot} `
            -Request {param($Path,$Body,$TimeoutMs) Invoke-FastLlmHttp -BaseUrl 'http://127.0.0.1:18081' -Path $Path -Body $Body -TimeoutMs $TimeoutMs} `
            -CheckProcess {param($State) Assert-FastLlmHipBenchmarkProcess -State $State -HashExecutable}
    }finally{$lock.Dispose()}
}
