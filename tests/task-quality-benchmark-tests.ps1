#requires -Version 5.1
# Local mock-only tests. Never launches a model, engine, or physical benchmark.
$ErrorActionPreference='Stop'
$tool=Join-Path $PSScriptRoot '../tools/task-quality-benchmark.ps1'
$workload=Join-Path $PSScriptRoot '../src/FastLlm.TaskWorkload.ps1'
$concurrency=Join-Path $PSScriptRoot '../tools/concurrency-benchmark.ps1'
. $tool -OutputPath (Join-Path ([IO.Path]::GetTempPath()) 'unused-task-quality-test.json')
. $workload
. $concurrency -OutputPath (Join-Path ([IO.Path]::GetTempPath()) 'unused-concurrency-test.json')
Set-StrictMode -Version 2.0
$script:checks=0
function Check($Condition,[string]$Label){if(-not $Condition){throw "FAILED: $Label"};$script:checks++}
function Test-FastLlmBenchmarkFiniteNumber($Value,[bool]$AllowZero=$false){
    if($null -eq $Value){return $false}
    try{$number=[double]$Value;return -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number) -and ($number -gt 0 -or ($AllowZero -and $number -eq 0))}
    catch{return $false}
}
function Assert-FastLlmSemanticSmokeState($State,[string]$ExpectedBinding){
    if($State.active -ne $true -or $State.phase -cne 'ready' -or
       ($ExpectedBinding -and $State.runId -cne $ExpectedBinding)){throw 'mock-binding-change'}
    return [string]$State.runId
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('task-quality-mock-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
try {
    $script:mockState=[pscustomobject]@{active=$true;phase='ready';runId='1234567890abcdef1234567890abcdef';
        recipe=[pscustomobject]@{contextSize=8192};endpoint='http://127.0.0.1:8080/v1';
        processIdentity=[pscustomobject]@{pid=42;startUtcTicks=123};modelId='mock-model';
        modelSha256=('a'*64);engineVersion='b10698'}
    $cases=@(Get-FastLlmTaskWorkloadCases)
    Check ($cases.Count -eq 8) 'exact eight canonical tasks'
    $byPrompt=@{};foreach($case in $cases){$byPrompt[[string]$case.prompt]=$case}
    Check ((Get-TaskQualitySourceHashes).Keys.Count -ge 9) 'source provenance covers dependent status, benchmark, listener code'
    Check (Test-TaskQualitySourceHashes (Get-TaskQualitySourceHashes)) 'same-source hash check'
    $wrong=Get-TaskQualitySourceHashes;$wrong['taskTool']='0'*64
    Check (-not (Test-TaskQualitySourceHashes $wrong)) 'changed source refused'
    $bad=@($cases);$bad[0]=[pscustomobject]@{id=$cases[0].id;prompt=('x'*16385);maxOutputTokens=96;distractorCount=0}
    $rejected=$false;try{Assert-TaskQualityCases $bad 0}catch{$rejected=$true}
    Check $rejected 'oversized prompt rejected before dispatch'
    $jsonCase=$cases[0]
    $okBody=New-TaskQualityRequestBody $script:mockState $jsonCase|ConvertFrom-Json
    Check ($okBody.stream -eq $false -and $okBody.temperature -eq 0 -and $okBody.seed -eq 42 -and
        $okBody.cache_prompt -eq $false -and $okBody.chat_template_kwargs.enable_thinking -eq $false -and
        $okBody.response_format.type -ceq 'json_object') 'request controls and explicit JSON format'
    $nonJson=New-TaskQualityRequestBody $script:mockState $cases[1]|ConvertFrom-Json
    Check ($null -eq $nonJson.PSObject.Properties['response_format']) 'non-JSON task has no response format'
    $raw=[pscustomobject]@{Status=200;Body=('{"choices":[{"message":{"role":"assistant","content":"'+$cases[1].expected+'"},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":4}}')}
    $parsed=ConvertFrom-TaskQualityResponse $raw $cases[1] 8192
    Check ($parsed.grade -ceq 'correct' -and $parsed.actualPromptTokens -eq 100) 'strict success and actual usage'
    foreach($usage in @('{"prompt_tokens":1.0,"completion_tokens":4}',
        '{"prompt_tokens":"100","completion_tokens":4}',
        '{"prompt_tokens":[100],"completion_tokens":4}',
        '{"prompt_tokens":999999999999999999999,"completion_tokens":4}',
        '{"prompt_tokens":100,"completion_tokens":1.5}',
        '{"prompt_tokens":100,"completion_tokens":[4]}',
        '{}')){
        $badRaw=[pscustomobject]@{Status=200;Body=('{"choices":[{"message":{"role":"assistant","content":"K2,K4"},"finish_reason":"stop"}],"usage":'+$usage+'}')}
        $parsed=ConvertFrom-TaskQualityResponse $badRaw $cases[1] 8192
        Check ($parsed.grade -ceq 'inconclusive' -and $null -eq $parsed.actualPromptTokens) 'non-integer or missing usage inconclusive'
    }
    $length=[pscustomobject]@{Status=200;Body='{"choices":[{"message":{"role":"assistant","content":"K2,K4"},"finish_reason":"length"}],"usage":{"prompt_tokens":100,"completion_tokens":4}}'}
    $parsed=ConvertFrom-TaskQualityResponse $length $cases[1] 8192
    Check ($parsed.errorCode -ceq 'truncated' -and $parsed.actualPromptTokens -eq 100 -and $parsed.finishReason -ceq 'length') 'length retains usage and finish evidence'
    $think=[pscustomobject]@{Status=200;Body='{"choices":[{"message":{"role":"assistant","content":"<think>x</think>K2,K4"},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":4}}'}
    Check ((ConvertFrom-TaskQualityResponse $think $cases[1] 8192).errorCode -ceq 'visible-reasoning') 'visible reasoning rejected'
    $overflow=[pscustomobject]@{Status=200;Body='{"choices":[{"message":{"role":"assistant","content":"K2,K4"},"finish_reason":"stop"}],"usage":{"prompt_tokens":8160,"completion_tokens":4}}'}
    Check ((ConvertFrom-TaskQualityResponse $overflow $cases[1] 8192).errorCode -ceq 'observed-context-overflow') 'context headroom guarded using observed usage'
    Check ((ConvertFrom-TaskQualityResponse ([pscustomobject]@{Status=200;Body='{}'}) $cases[1] 8192).grade -ceq 'inconclusive') 'malformed choices contained'
    $objectChoices=[pscustomobject]@{Status=200;Body='{"choices":{"message":{"role":"assistant","content":"K2,K4"},"finish_reason":"stop"},"usage":{"prompt_tokens":100,"completion_tokens":4}}'}
    Check ((ConvertFrom-TaskQualityResponse $objectChoices $cases[1] 8192).grade -ceq 'inconclusive') 'choices object is not a one-element array'
    $arrayRole=[pscustomobject]@{Status=200;Body='{"choices":[{"message":{"role":["assistant"],"content":"K2,K4"},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":4}}'}
    Check ((ConvertFrom-TaskQualityResponse $arrayRole $cases[1] 8192).grade -ceq 'inconclusive') 'array role is not scalar assistant'
    $arrayContent=[pscustomobject]@{Status=200;Body='{"choices":[{"message":{"role":"assistant","content":["K2,K4"]},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":4}}'}
    Check ((ConvertFrom-TaskQualityResponse $arrayContent $cases[1] 8192).grade -ceq 'inconclusive') 'array content is not scalar text'
    $script:seenLevels=@();$script:seenPrompts=@();$script:waveCalls=0
    $goodWave={param($Base,$Path,$Bodies,$Count,$TimeoutMs)
        $script:seenLevels+=$Count;$script:waveCalls++
        $requests=@();for($i=0;$i -lt $Count;$i++){
            $body=ConvertFrom-Json $Bodies[$i];$case=$byPrompt[[string]$body.messages[0].content]
            $script:seenPrompts+= [string]$case.id
            $content=[string]$case.expected
            $response=[pscustomobject]@{Status=200;Body=(ConvertTo-Json -InputObject @{
                choices=@(@{message=@{role='assistant';content=$content};finish_reason='stop'});
                usage=@{prompt_tokens=100;completion_tokens=4}} -Depth 8 -Compress)}
            $requests+= [pscustomobject]@{client=$i+1;startedMs=1.0;finishedMs=(2.0+$i);response=$response;errorCode=$null}
        }
        [pscustomobject]@{releasedMs=1.0;wallMs=[double]$Count;requests=$requests}
    }
    $reportPath=Join-Path $root 'complete.json'
    $report=Invoke-TaskQualityBenchmarkCore -OutputPath $reportPath -DistractorCount 0 -DeadlineSeconds 60 -RequestTimeoutBaseSeconds 10 `
        -ReadState {$script:mockState} -CheckProcess {param($State) if($State.runId -cne $script:mockState.runId){throw 'mock-process-change'}} -Wave $goodWave
    Check ($report.reportStatus -ceq 'complete' -and $report.resultKind -ceq 'private-task-quality-screen') 'complete report kind'
    Check (($script:seenLevels -join ',') -ceq '1,1,1,1,1,1,1,1,2,2,2,2,4,4') 'fixed burst shape'
    Check ($script:waveCalls -eq 14 -and $script:seenPrompts.Count -eq 24) 'same eight tasks at three levels'
    foreach($n in @(0,1,2)){Check (($script:seenPrompts[($n*8)..($n*8+7)] -join ',') -ceq (@($cases|ForEach-Object id) -join ',')) 'same canonical suite per condition'}
    Check ($report.totals.planned -eq 24 -and $report.totals.correct -eq 24 -and $report.totals.unattempted -eq 0) 'complete denominator'
    Check (@($report.summary).Count -eq 3 -and @($report.summary|Where-Object complete -eq $true).Count -eq 3) 'all levels complete'
    Check (@($report.summary|Where-Object { $_.wholeSuiteWallMs -gt 0 -and $_.usefulTasksPerSecond -gt 0 }).Count -eq 3) 'whole-suite rates'
    Check ($report.methodology.firstText -ceq 'not-measured' -and $report.qualification.approved -eq $false) 'no TTFT or qualification claim'
    Check ((Get-Content -LiteralPath $reportPath -Raw) -notmatch 'AUTHORITATIVE ledger|K1 score|<think>') 'no raw prompts or completions in report'
    $script:waveCalls=0
    $abortPath=Join-Path $root 'wave-abort.json'
    $abortWave={param($Base,$Path,$Bodies,$Count,$TimeoutMs)
        $script:waveCalls++;throw 'mock missing result (private text must not escape)'
    }
    $aborted=Invoke-TaskQualityBenchmarkCore -OutputPath $abortPath -DistractorCount 0 -DeadlineSeconds 60 -RequestTimeoutBaseSeconds 10 `
        -ReadState {$script:mockState} -CheckProcess {param($State)} -Wave $abortWave
    Check ($aborted.reportStatus -ceq 'aborted' -and $script:waveCalls -eq 1) 'stop escalation on first failed wave'
    Check ($aborted.totals.attempted -eq 1 -and $aborted.totals.inconclusive -eq 1 -and $aborted.totals.unattempted -eq 23) 'issued missing result is inconclusive, not unattempted'
    Check ($null -eq $aborted.summary[0].usefulTasksPerSecond -and $aborted.summary[0].complete -eq $false) 'no partial-suite rate'
    $serialized=Get-Content -LiteralPath $abortPath -Raw
    Check ($serialized -notmatch 'mock missing result|AUTHORITATIVE ledger line') 'private error and prompt not serialized'
    $module=Import-Module (Join-Path $PSScriptRoot '../src/FastLlm.psm1') -Force -PassThru
    $moduleResult=& $module {
        param($Tool,$Workload,$Semantic,$Concurrency,$Output)
        . $Semantic
        . $Workload
        . $Concurrency -OutputPath (Join-Path ([IO.Path]::GetTempPath()) 'unused-task-quality-integration-concurrency.json')
        . $Tool -OutputPath (Join-Path ([IO.Path]::GetTempPath()) 'unused-task-quality-integration-tool.json')
        $moduleState=[pscustomobject]@{schemaVersion=1;active=$true;phase='ready';runId=('a'*32);
            endpoint='http://127.0.0.1:8080/v1';modelId='mock-model';modelSha256=('b'*64);engineVersion='b10698';
            recipe=[pscustomobject]@{backend='Vulkan';engineSha256=('c'*64);catalogSha256=('d'*64);
                contextSize=8192;slots=1;requestedArguments=@('--host','127.0.0.1','--port','8080',
                    '--alias','mock-model','--parallel','1','--ctx-size','8192')};
            processIdentity=[pscustomobject]@{pid=42;startUtcTicks=638000000000000000};
            canary=[pscustomobject]@{modelIdentity=$true;repeatableToken=$true;synchronousChat=$true;
                streaming=$true;semanticCorrectnessQualified=$false;effectiveContext=8192};
            placement=[pscustomobject]@{reportedAllLayers=$true;reportedLayers=66;totalLayers=66;devices=@('Vulkan0')}}
        $lookup=@{};foreach($item in @(Get-FastLlmTaskWorkloadCases)){$lookup[[string]$item.prompt]=$item}
        $mockWave={param($Base,$Path,$Bodies,$Count,$TimeoutMs)
            $responses=@(for($i=0;$i -lt $Count;$i++){
                $body=ConvertFrom-Json $Bodies[$i]
                $item=$lookup[[string]$body.messages[0].content]
                $reply=[pscustomobject]@{Status=200;Body=(ConvertTo-Json -InputObject @{
                    choices=@(@{message=@{role='assistant';content=$item.expected};finish_reason='stop'});
                    usage=@{prompt_tokens=100;completion_tokens=4}} -Depth 8 -Compress)}
                [pscustomobject]@{client=$i+1;startedMs=1.0;finishedMs=2.0+$i;response=$reply;errorCode=$null}
            })
            [pscustomobject]@{releasedMs=1.0;wallMs=[double]$Count;requests=$responses}
        }
        Invoke-TaskQualityBenchmarkCore -OutputPath $Output -DistractorCount 0 -DeadlineSeconds 60 -RequestTimeoutBaseSeconds 10 `
            -ReadState {$moduleState} -CheckProcess {param($Current) if($Current.processIdentity.pid -ne 42){throw 'identity changed'}} -Wave $mockWave
    } $tool $workload (Join-Path $PSScriptRoot '../src/FastLlm.SemanticSmoke.ps1') $concurrency (Join-Path $root 'module-integration.json')
    Check ($moduleResult.reportStatus -ceq 'complete' -and $moduleResult.totals.correct -eq 24) 'full mock core works in strict imported module scope'
    $script:waveCalls=0
    $wrongWave={param($Base,$Path,$Bodies,$Count,$TimeoutMs)
        $result=& $goodWave $Base $Path $Bodies $Count $TimeoutMs
        if($script:waveCalls -eq 9){
            $result.requests[0].response.Body='{"choices":[{"message":{"role":"assistant","content":"wrong"},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":4}}'
        }
        $result
    }
    $wrong=Invoke-TaskQualityBenchmarkCore -OutputPath (Join-Path $root 'wrong.json') -DistractorCount 0 -DeadlineSeconds 60 -RequestTimeoutBaseSeconds 10 `
        -ReadState {$script:mockState} -CheckProcess {param($State)} -Wave $wrongWave
    Check ($wrong.reportStatus -ceq 'aborted' -and $wrong.abortReasonCode -ceq 'failed-or-inconclusive-wave') 'wrong answer stops before C4'
    Check ($wrong.totals.attempted -eq 10 -and $wrong.totals.correct -eq 9 -and $wrong.totals.incorrect -eq 1 -and
        $wrong.totals.unattempted -eq 14 -and $script:waveCalls -eq 9) 'wrong answer denominators and no escalation'
    $script:waveCalls=0
    $assessmentWave={param($Base,$Path,$Bodies,$Count,$TimeoutMs)
        $result=& $goodWave $Base $Path $Bodies $Count $TimeoutMs
        $result.requests[0].response.Body='{"choices":[{"message":{"role":"assistant","content":"wrong"},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":4}}'
        $result
    }
    $assessment=Invoke-TaskQualityBenchmarkCore -OutputPath (Join-Path $root 'assessment.json') -DistractorCount 0 `
        -DeadlineSeconds 60 -RequestTimeoutBaseSeconds 10 -AssessmentMode `
        -ReadState {$script:mockState} -CheckProcess {param($State)} -Wave $assessmentWave
    Check ($assessment.resultKind -ceq 'private-task-quality-assessment' -and
        $assessment.methodology.protocolVersion -ceq 'task-quality-assessment-v1' -and
        $assessment.methodology.answerPolicy -ceq 'continue-incorrect-stop-inconclusive') 'assessment identity and policy are explicit'
    Check ($assessment.reportStatus -ceq 'complete' -and $assessment.qualityPass -eq $false -and
        $assessment.qualification.approved -eq $false -and $assessment.qualification.qualityEvaluation -eq $false) 'assessment completion is not quality pass or qualification'
    Check ($assessment.totals.attempted -eq 24 -and $assessment.totals.correct -eq 10 -and
        $assessment.totals.incorrect -eq 14 -and $assessment.totals.inconclusive -eq 0 -and
        $script:waveCalls -eq 14) 'assessment retains all wrong answers and completes all 24 tasks'
    Check (@($assessment.summary|Where-Object { $_.complete -and $_.attempted -eq 8 -and $_.incorrect -gt 0 -and
        $null -ne $_.usefulTasksPerSecond -and $_.usefulTasksPerSecond -ge 0 }).Count -eq 3 -and
        $assessment.summary[0].usefulTasksPerSecond -eq 0) 'each assessment level has full denominator and nonnegative correct-task rate'
    Check (Test-TaskQualityControllerReport $assessment $script:mockState $true 0) 'controller accepts completed assessment with wrong answers'
    Check (-not (Test-TaskQualityControllerReport $assessment $script:mockState $false 0)) 'controller rejects assessment as default smoke'
    $spoof=Get-Content -LiteralPath (Join-Path $root 'assessment.json') -Raw|ConvertFrom-Json
    $spoof.methodology.answerPolicy='stop-incorrect-or-inconclusive'
    Check (-not (Test-TaskQualityControllerReport $spoof $script:mockState $true 0)) 'controller rejects policy mismatch'
    $spoof=Get-Content -LiteralPath (Join-Path $root 'assessment.json') -Raw|ConvertFrom-Json
    $spoof.waves[0].requests[0].grade='inconclusive'
    Check (-not (Test-TaskQualityControllerReport $spoof $script:mockState $true 0)) 'controller rejects contradictory request grades'
    $spoof=Get-Content -LiteralPath (Join-Path $root 'assessment.json') -Raw|ConvertFrom-Json
    $spoof.sourceProvenance.endStatus='changed'
    Check (-not (Test-TaskQualityControllerReport $spoof $script:mockState $true 0)) 'controller rejects source mismatch'
    $spoof=Get-Content -LiteralPath (Join-Path $root 'assessment.json') -Raw|ConvertFrom-Json
    $spoof.processIdentity.pid=99
    Check (-not (Test-TaskQualityControllerReport $spoof $script:mockState $true 0)) 'controller rejects process mismatch'
    $spoof=Get-Content -LiteralPath (Join-Path $root 'assessment.json') -Raw|ConvertFrom-Json
    $spoof.waves[0].requests[0].taskId=$spoof.waves[1].requests[0].taskId
    Check (-not (Test-TaskQualityControllerReport $spoof $script:mockState $true 0)) 'controller rejects duplicated task identity'
    $spoof=Get-Content -LiteralPath (Join-Path $root 'assessment.json') -Raw|ConvertFrom-Json
    $spoof.totals.correct='10'
    Check (-not (Test-TaskQualityControllerReport $spoof $script:mockState $true 0)) 'controller rejects stringified counts'
    $script:waveCalls=0
    $inconclusiveWave={param($Base,$Path,$Bodies,$Count,$TimeoutMs)
        $result=& $assessmentWave $Base $Path $Bodies $Count $TimeoutMs
        $result.requests[0].response.Body='{"choices":[{"message":{"role":"assistant","content":"wrong"},"finish_reason":"length"}],"usage":{"prompt_tokens":100,"completion_tokens":4}}'
        $result
    }
    $assessmentAbort=Invoke-TaskQualityBenchmarkCore -OutputPath (Join-Path $root 'assessment-truncated.json') -DistractorCount 0 `
        -DeadlineSeconds 60 -RequestTimeoutBaseSeconds 10 -AssessmentMode `
        -ReadState {$script:mockState} -CheckProcess {param($State)} -Wave $inconclusiveWave
    Check ($assessmentAbort.reportStatus -ceq 'aborted' -and $assessmentAbort.abortReasonCode -ceq 'inconclusive-wave' -and
        $assessmentAbort.totals.attempted -eq 1 -and $script:waveCalls -eq 1) 'assessment stops on truncation despite wrong-answer continuation'
    $script:waveCalls=0
    $assessmentTransport=Invoke-TaskQualityBenchmarkCore -OutputPath (Join-Path $root 'assessment-transport.json') -DistractorCount 0 `
        -DeadlineSeconds 60 -RequestTimeoutBaseSeconds 10 -AssessmentMode `
        -ReadState {$script:mockState} -CheckProcess {param($State)} -Wave $abortWave
    Check ($assessmentTransport.reportStatus -ceq 'aborted' -and $assessmentTransport.totals.inconclusive -eq 1 -and
        $script:waveCalls -eq 1) 'assessment stops after unavailable transport result'
    $script:reads=0;$script:waveCalls=0
    $changedBinding=Invoke-TaskQualityBenchmarkCore -OutputPath (Join-Path $root 'identity-change.json') -DistractorCount 0 -DeadlineSeconds 60 -RequestTimeoutBaseSeconds 10 `
        -ReadState {$script:reads++;if($script:reads -ge 3){[pscustomobject]@{active=$true;phase='ready';runId='ffffffffffffffffffffffffffffffff';
            recipe=[pscustomobject]@{contextSize=8192};endpoint='http://127.0.0.1:8080/v1'}}else{$script:mockState}} `
        -CheckProcess {param($State)} -Wave $goodWave
    Check ($changedBinding.reportStatus -ceq 'aborted' -and $changedBinding.bindingStatus -ceq 'compromised' -and
        $changedBinding.totals.attempted -eq 1 -and $script:waveCalls -eq 1) 'changed binding stops after first issued wave'
    $savedSourceFunction=(Get-Command Get-TaskQualitySourceHashes).ScriptBlock
    try {
        $script:sourceReads=0
        Set-Item Function:Get-TaskQualitySourceHashes -Value {
            $script:sourceReads++
            [ordered]@{taskTool=$(if($script:sourceReads -gt 2){'b'*64}else{'a'*64})}
        }
        $script:waveCalls=0
        $changedSource=Invoke-TaskQualityBenchmarkCore -OutputPath (Join-Path $root 'source-change.json') -DistractorCount 0 -DeadlineSeconds 60 -RequestTimeoutBaseSeconds 10 `
            -ReadState {$script:mockState} -CheckProcess {param($State)} -Wave $goodWave
        Check ($changedSource.reportStatus -ceq 'aborted' -and $changedSource.sourceProvenance.endStatus -ceq 'changed' -and
            $changedSource.totals.attempted -eq 1 -and $script:waveCalls -eq 1) ("changed source stops after first issued wave: $($changedSource.reportStatus)/$($changedSource.sourceProvenance.endStatus)/$($changedSource.totals.attempted)/$script:waveCalls")
    }finally{Set-Item Function:Get-TaskQualitySourceHashes -Value $savedSourceFunction}
    $abortSidecar=New-TaskQualityAbortRecord -OutputPath $reportPath -State $script:mockState -ReasonCode 'mock-controller-failure'
    $abortItem=Get-Content -LiteralPath $abortSidecar -Raw|ConvertFrom-Json
    Check ($abortSidecar -cne $reportPath -and $abortItem.controllerOutcomeAuthoritative -eq $true -and
        $abortItem.primaryReportPresent -eq $true -and $abortItem.reportStatus -ceq 'aborted') 'authoritative controller abort does not replace completed child report'
    Write-Host "PASS: $script:checks task-quality mock checks. No engine or model invoked."
}finally{
    # Test-created files only, under a uniquely named temp directory.
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
}
