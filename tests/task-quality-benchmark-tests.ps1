#requires -Version 5.1
# Local mock-only tests. Never launches a model, engine, or physical benchmark.
$ErrorActionPreference='Stop'
$tool=Join-Path $PSScriptRoot '../tools/task-quality-benchmark.ps1'
$workload=Join-Path $PSScriptRoot '../src/FastLlm.TaskWorkload.ps1'
$concurrency=Join-Path $PSScriptRoot '../tools/concurrency-benchmark.ps1'
. $tool -OutputPath (Join-Path ([IO.Path]::GetTempPath()) 'unused-task-quality-test.json')
. $workload
. $concurrency -OutputPath (Join-Path ([IO.Path]::GetTempPath()) 'unused-concurrency-test.json')
# The lane table is read from its one source; the state check below is replaced by a recording mock.
. (Join-Path $PSScriptRoot '../src/FastLlm.SemanticSmoke.ps1')
. (Join-Path $PSScriptRoot 'helpers/task-quality-masked-json.ps1')
Set-StrictMode -Version 2.0
$script:checks=0
function Check($Condition,[string]$Label){if(-not $Condition){throw "FAILED: $Label"};$script:checks++}
function Test-FastLlmBenchmarkFiniteNumber($Value,[bool]$AllowZero=$false){
    if($null -eq $Value){return $false}
    try{$number=[double]$Value;return -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number) -and ($number -gt 0 -or ($AllowZero -and $number -eq 0))}
    catch{return $false}
}
$script:assertCalls=@()
function Assert-FastLlmSemanticSmokeState($State,[string]$ExpectedBinding,[string[]]$AcceptedLanes=@('vulkan-b10698'),[switch]$AllowServingProfile){
    $script:assertCalls+= [pscustomobject]@{lanes=(@($AcceptedLanes) -join ',');allow=[bool]$AllowServingProfile}
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
    # --- Serving-profile runs ---
    # Default report: the same bytes main writes (a fixture generated from main), after masking only what differs between any two runs.
    $defaultReportText=Get-Content -LiteralPath $reportPath -Raw
    $fixtureText=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/task-quality-default-report.json') -Raw
    Check ((Get-TaskQualityMaskedReportText $defaultReportText) -ceq (Get-TaskQualityMaskedReportText $fixtureText)) 'default report is identical to the report main writes for the same inputs'
    Check (-not $defaultReportText.Contains('servingSetup') -and $report.methodology.serverSlots -eq 1 -and
        $report.methodology.interpretation -ceq 'Single-slot queue-pressure and useful-task measurement, not parallel GPU proof or quality qualification') 'default report has no serving setup and keeps the single-slot wording'
    # The serving-profile file is a dependency of the state check, so it is one of the reported source hashes, checked at the same points.
    Check ((Get-TaskQualitySourceHashes).Contains('servingProfile') -and (Get-TaskQualitySourceHashes)['servingProfile'] -cmatch '^[0-9a-f]{64}$') 'source provenance covers the serving-profile file'
    Check ((@($report.sourceProvenance.sha256.PSObject.Properties.Name|Sort-Object) -join ',') -ceq (@(((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/task-quality-default-report.json') -Raw|ConvertFrom-Json).sourceProvenance.sha256.PSObject.Properties.Name)|Sort-Object) -join ',') -and
        $report.sourceProvenance.sha256.servingProfile -cmatch '^[0-9a-f]{64}$') 'default report source entries are the fixture entries, including the serving-profile file'
    $copyRoot=Join-Path $root 'copy'
    foreach($relative in @('tools','src')){$null=New-Item -ItemType Directory -Path (Join-Path $copyRoot $relative) -Force}
    $copied=@('tools/task-quality-benchmark.ps1','tools/concurrency-benchmark.ps1','src/FastLlm.TaskWorkload.ps1','src/FastLlm.SemanticSmoke.ps1','src/ProcessHost.cs',
        'src/FastLlm.psm1','src/FastLlm.Benchmark.ps1','src/FastLlm.Runtime.ps1','src/WindowsGpuTelemetry.cs','src/FastLlm.ServingProfileRun.ps1')
    foreach($relative in $copied){Copy-Item -LiteralPath (Join-Path $PSScriptRoot ('../'+$relative)) -Destination (Join-Path $copyRoot $relative)}
    $savedToolPath=$script:FastLlmTaskQualityToolPath
    try{
        $script:FastLlmTaskQualityToolPath=Join-Path $copyRoot 'tools/task-quality-benchmark.ps1'
        $script:waveCalls=0
        $editWave={param($Base,$Path,$Bodies,$Count,$TimeoutMs)
            $script:waveCalls++
            if($script:waveCalls -eq 1){[IO.File]::AppendAllText((Join-Path $copyRoot 'src/FastLlm.ServingProfileRun.ps1'),"`n# edited during the run")}
            & $goodWave $Base $Path $Bodies $Count $TimeoutMs
        }
        $edited=Invoke-TaskQualityBenchmarkCore -OutputPath (Join-Path $root 'profile-file-edit.json') -DistractorCount 0 -DeadlineSeconds 60 -RequestTimeoutBaseSeconds 10 `
            -ReadState {$script:mockState} -CheckProcess {param($State)} -Wave $editWave
        Check ($edited.reportStatus -ceq 'aborted' -and $edited.sourceProvenance.endStatus -ceq 'changed' -and $edited.bindingStatus -ceq 'compromised' -and $script:waveCalls -eq 1) 'an edit to the serving-profile file during the run leaves the source status not verified'
    }finally{$script:FastLlmTaskQualityToolPath=$savedToolPath}
    # Every state check the tool makes carries the lane list and the switch.
    $script:assertCalls=@()
    $null=Invoke-TaskQualityBenchmarkCore -OutputPath (Join-Path $root 'calls-default.json') -DistractorCount 0 -DeadlineSeconds 60 -RequestTimeoutBaseSeconds 10 `
        -ReadState {$script:mockState} -CheckProcess {param($State)} -Wave $goodWave
    Check ($script:assertCalls.Count -ge 31 -and @($script:assertCalls|Where-Object {$_.lanes -cne 'vulkan-b10698' -or $_.allow}).Count -eq 0) 'default run passes the default lane and no switch to every state check'
    $script:assertCalls=@()
    $profileState=[pscustomobject]@{active=$true;phase='ready';runId='1234567890abcdef1234567890abcdef';
        recipe=[pscustomobject]@{contextSize=8192;slots=2;contextPerSlot=4096;profile='long';
            requestedArguments=@('--host','127.0.0.1','--port','8080','--ctx-size','8192','--parallel','2','--cache-type-k','q8_0','--cache-type-v','q8_0')};
        endpoint='http://127.0.0.1:8080/v1';processIdentity=[pscustomobject]@{pid=42;startUtcTicks=123};modelId='mock-model';
        modelSha256=('a'*64);engineVersion='b10698'}
    $optInPath=Join-Path $root 'opt-in.json'
    $optIn=Invoke-TaskQualityBenchmarkCore -OutputPath $optInPath -DistractorCount 0 -DeadlineSeconds 60 -RequestTimeoutBaseSeconds 10 `
        -ReadState {$profileState} -CheckProcess {param($State)} -Wave $goodWave -AcceptedLanes @('vulkan-b10698','hip-b11658') -AllowServingProfile
    Check ($optIn.reportStatus -ceq 'complete' -and $script:assertCalls.Count -ge 31 -and
        @($script:assertCalls|Where-Object {$_.lanes -cne 'vulkan-b10698,hip-b11658' -or -not $_.allow}).Count -eq 0) 'opt-in run passes its lanes and the switch to every state check'
    Check ($optIn.methodology.serverSlots -eq 2 -and $optIn.methodology.servingSetup.profile -ceq 'long' -and
        $optIn.methodology.servingSetup.contextTotal -eq 8192 -and $optIn.methodology.servingSetup.contextPerSlot -eq 4096 -and
        $optIn.methodology.servingSetup.slots -eq 2 -and $optIn.methodology.servingSetup.cacheTypeK -ceq 'q8_0' -and
        $optIn.methodology.servingSetup.cacheTypeV -ceq 'q8_0') 'opt-in report carries the state serving setup and its slot count'
    Check ($optIn.methodology.interpretation -cne $report.methodology.interpretation -and
        $optIn.methodology.interpretation -clike 'Two-slot*' -and $optIn.methodology.interpretation -clike '*not parallel GPU proof or quality qualification') 'two-slot wording keeps the not-qualification disclaimer'
    Check (Test-TaskQualityControllerReport (Get-Content -LiteralPath $optInPath -Raw|ConvertFrom-Json) $profileState $false 0 $true) 'controller accepts an opt-in report that matches the state'
    Check (-not (Test-TaskQualityControllerReport (Get-Content -LiteralPath $optInPath -Raw|ConvertFrom-Json) $profileState $false 0)) 'controller without the switch still rejects a two-slot report'
    foreach($tamper in @(
        @{label='serverSlots';apply={param($r) $r.methodology.serverSlots=1}},
        @{label='servingSetup removed';apply={param($r) $r.methodology.PSObject.Properties.Remove('servingSetup')}},
        @{label='profile';apply={param($r) $r.methodology.servingSetup.profile='default'}},
        @{label='contextTotal';apply={param($r) $r.methodology.servingSetup.contextTotal=4096}},
        @{label='contextPerSlot';apply={param($r) $r.methodology.servingSetup.contextPerSlot=8192}},
        @{label='slots';apply={param($r) $r.methodology.servingSetup.slots=1}},
        @{label='cacheTypeK';apply={param($r) $r.methodology.servingSetup.cacheTypeK='f16'}},
        @{label='cacheTypeV';apply={param($r) $r.methodology.servingSetup.cacheTypeV='f16'}})){
        $copy=Get-Content -LiteralPath $optInPath -Raw|ConvertFrom-Json
        & $tamper.apply $copy
        Check (-not (Test-TaskQualityControllerReport $copy $profileState $false 0 $true)) "controller rejects an opt-in report whose $($tamper.label) differs from the state"
    }
    # A default run with the switch on still states its setup; absent cache arguments mean f16.
    $defaultOptIn=Invoke-TaskQualityBenchmarkCore -OutputPath (Join-Path $root 'default-opt-in.json') -DistractorCount 0 -DeadlineSeconds 60 -RequestTimeoutBaseSeconds 10 `
        -ReadState {$script:mockState} -CheckProcess {param($State)} -Wave $goodWave -AllowServingProfile
    Check ($defaultOptIn.methodology.serverSlots -eq 1 -and $defaultOptIn.methodology.servingSetup.profile -ceq 'default' -and
        $defaultOptIn.methodology.servingSetup.contextTotal -eq 8192 -and $defaultOptIn.methodology.servingSetup.contextPerSlot -eq 8192 -and
        $defaultOptIn.methodology.servingSetup.slots -eq 1 -and $defaultOptIn.methodology.servingSetup.cacheTypeK -ceq 'f16' -and
        $defaultOptIn.methodology.servingSetup.cacheTypeV -ceq 'f16' -and $defaultOptIn.methodology.interpretation -ceq $report.methodology.interpretation) 'default state under the switch reads as default, one slot, f16, with the one-slot wording'
    # The context a request may use is its slot, not the total.
    $overflowWave={param($Base,$Path,$Bodies,$Count,$TimeoutMs)
        $result=& $goodWave $Base $Path $Bodies $Count $TimeoutMs
        $result.requests[0].response.Body=($result.requests[0].response.Body -replace '"prompt_tokens":100','"prompt_tokens":4090')
        $result
    }
    $slotOverflow=Invoke-TaskQualityBenchmarkCore -OutputPath (Join-Path $root 'slot-overflow.json') -DistractorCount 0 -DeadlineSeconds 60 -RequestTimeoutBaseSeconds 10 `
        -ReadState {$profileState} -CheckProcess {param($State)} -Wave $overflowWave -AllowServingProfile
    Check ($slotOverflow.reportStatus -ceq 'aborted' -and $slotOverflow.waves[0].requests[0].errorCode -ceq 'observed-context-overflow') 'opt-in run guards headroom against the per-slot context'
    # Lanes: unknown names are refused before any state check or request.
    foreach($badLanes in @(@('nonsense'),@('vulkan-b10698','nonsense'),@('VULKAN-B10698'),@(),@('vulkan-b10698','vulkan-b10698'))){
        $script:assertCalls=@();$script:waveCalls=0;$refusal=$null
        try{
            $null=Invoke-TaskQualityBenchmarkCore -OutputPath (Join-Path $root 'bad-lane.json') -DistractorCount 0 -DeadlineSeconds 60 -RequestTimeoutBaseSeconds 10 `
                -ReadState {$script:mockState} -CheckProcess {param($State)} -Wave {$script:waveCalls++} -AcceptedLanes $badLanes
        }catch{$refusal=$_.Exception}
        Check ($null -ne $refusal -and $refusal.Data['FastLlmFailureCode'] -ceq 'task-quality-lane-unknown' -and $script:waveCalls -eq 0 -and
            $script:assertCalls.Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $root 'bad-lane.json'))) "unknown lane list '$($badLanes -join ',')' is refused with a typed error before any check or request"
    }
    Check ((@(Expand-TaskQualityLanes @('hip-b11658,vulkan-b10698')) -join '|') -ceq 'hip-b11658|vulkan-b10698' -and
        (@(Expand-TaskQualityLanes @('vulkan-b10698','hip-b11658')) -join '|') -ceq 'vulkan-b10698|hip-b11658') 'a lane list survives the one-string form a child host receives'
    # The tool's own surface and every state check call.
    $toolText=Get-Content -LiteralPath $tool -Raw
    $toolAst=[Management.Automation.Language.Parser]::ParseInput($toolText,[ref]$null,[ref]$null)
    $toolParams=@($toolAst.ParamBlock.Parameters)
    $lanesParam=@($toolParams|Where-Object {$_.Name.VariablePath.UserPath -ceq 'AcceptedLanes'})
    $switchParam=@($toolParams|Where-Object {$_.Name.VariablePath.UserPath -ceq 'AllowServingProfile'})
    Check ($lanesParam.Count -eq 1 -and $lanesParam[0].StaticType -eq [string[]] -and $lanesParam[0].DefaultValue.Extent.Text -ceq "@('vulkan-b10698')") 'tool takes -AcceptedLanes <string[]> defaulting to the Vulkan lane'
    Check ($switchParam.Count -eq 1 -and $switchParam[0].StaticType -eq [switch]) 'tool takes the -AllowServingProfile switch (off by default)'
    $assertCalls=@([regex]::Matches($toolText,'(?m)^[^#\r\n]*Assert-FastLlmSemanticSmokeState\b[^\r\n]*'))
    Check ($assertCalls.Count -ge 7 -and @($assertCalls|Where-Object {$_.Value -notmatch '-AcceptedLanes \$\w+ -AllowServingProfile:\$\w+'}).Count -eq 0) 'every state check in the tool passes the lanes and the switch'
    Check ($toolText.Contains("'-AcceptedLanes'") -and $toolText.Contains("'-AllowServingProfile'")) 'the contained worker receives both settings'
    $abortSidecar=New-TaskQualityAbortRecord -OutputPath $reportPath -State $script:mockState -ReasonCode 'mock-controller-failure'
    $abortItem=Get-Content -LiteralPath $abortSidecar -Raw|ConvertFrom-Json
    Check ($abortSidecar -cne $reportPath -and $abortItem.controllerOutcomeAuthoritative -eq $true -and
        $abortItem.primaryReportPresent -eq $true -and $abortItem.reportStatus -ceq 'aborted') 'authoritative controller abort does not replace completed child report'
    Write-Host "PASS: $script:checks task-quality mock checks. No engine or model invoked."
}finally{
    # Test-created files only, under a uniquely named temp directory.
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
}
