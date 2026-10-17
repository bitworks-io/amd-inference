#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$repoRoot=Split-Path $PSScriptRoot -Parent
$semantic=Join-Path $repoRoot 'src/FastLlm.SemanticSmoke.ps1'
$workload=Join-Path $repoRoot 'src/FastLlm.TaskWorkload.ps1'
$taskQuality=Join-Path $repoRoot 'tools/task-quality-benchmark.ps1'
$diagnostic=Join-Path $repoRoot 'src/FastLlm.ArithmeticDiagnostic.ps1'
$tool=Join-Path $repoRoot 'tools/arithmetic-diagnostic.ps1'
. $semantic
. $workload
. $taskQuality -OutputPath (Join-Path ([IO.Path]::GetTempPath()) 'unused-arithmetic-task-quality.json')
. $diagnostic
$script:checks=0
function Check($Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
function New-TestRoot {
    $path=Join-Path ([IO.Path]::GetTempPath()) ('fastllm-arithmetic-'+[Guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory -Path $path
    return $path
}
function New-TestResponse([string]$Content,[string]$Finish='stop',$Usage=$null,$Reasoning=$null){
    if($null -eq $Usage){$Usage=@{prompt_tokens=100;completion_tokens=1}}
    $message=[ordered]@{role='assistant';content=$Content}
    if($null -ne $Reasoning){$message.reasoning_content=$Reasoning}
    [pscustomobject]@{Status=200;Body=(@{choices=@(@{message=$message;finish_reason=$Finish});usage=$Usage}|ConvertTo-Json -Depth 8 -Compress)}
}
$script:state=[pscustomobject]@{
    schemaVersion=1;active=$true;phase='ready';runId=('a'*32);endpoint='http://127.0.0.1:8080/v1'
    modelId='qwen-test';modelSha256=('b'*64);engineVersion='b10698'
    processIdentity=[pscustomobject]@{pid=42;startUtcTicks=638000000000000000}
    canary=[pscustomobject]@{modelIdentity=$true;repeatableToken=$true;synchronousChat=$true;streaming=$true;
        effectiveContext=8192;semanticCorrectnessQualified=$false}
    placement=[pscustomobject]@{reportedLayers=66;totalLayers=66;reportedAllLayers=$true;devices=@('Vulkan0')}
    recipe=[pscustomobject]@{backend='Vulkan';contextSize=8192;slots=1;engineSha256=('c'*64);catalogSha256=('d'*64);
        requestedArguments=@('--host','127.0.0.1','--port','8080','--alias','qwen-test','--ctx-size','8192','--parallel','1')}
}
$case=Get-FastLlmArithmeticDiagnosticCase
Check ($case.id -ceq 'arithmetic-steps-v1' -and $case.expected -ceq '63' -and $case.maxOutputTokens -eq 32) 'canonical case changed'
Check ((Get-FastLlmTaskWorkloadPromptSha256 $case) -ceq '8075c10d5c487b7976efbbb22ef8d50fcef17697aa6b12559945459d1c04c028' -and
    (Get-FastLlmTaskWorkloadReferenceSha256 $case) -ceq '3f6195f88d915f645e3a63eab36fed5bfc54e67f80152c1e178e359b7bb7eef9') 'prior assessment case identity changed'
$savedCases=(Get-Command Get-FastLlmTaskWorkloadCases).ScriptBlock
try{
    Set-Item Function:Get-FastLlmTaskWorkloadCases -Value {
        param([int]$DistractorCount=0)
        $items=@(& $savedCases -DistractorCount $DistractorCount)
        $changed=@()
        foreach($item in $items){
            if($item.id -ceq 'arithmetic-steps-v1'){
                $copy=$item.PSObject.Copy();$copy.prompt=([string]$item.prompt)+' changed';$changed+=$copy
            }else{$changed+=$item}
        }
        $changed
    }
    $promptDriftRejected=$false
    try{Get-FastLlmArithmeticDiagnosticCase|Out-Null}catch{$promptDriftRejected=$true}
    Check $promptDriftRejected 'changed historical arithmetic prompt was accepted'
}finally{Set-Item Function:Get-FastLlmTaskWorkloadCases -Value $savedCases}
$savedReferenceHasher=(Get-Command Get-FastLlmTaskWorkloadReferenceSha256).ScriptBlock
try{
    Set-Item Function:Get-FastLlmTaskWorkloadReferenceSha256 -Value {param($Case)('f'*64)}
    $referenceDriftRejected=$false
    try{Get-FastLlmArithmeticDiagnosticCase|Out-Null}catch{$referenceDriftRejected=$true}
    Check $referenceDriftRejected 'changed historical arithmetic reference identity was accepted'
}finally{Set-Item Function:Get-FastLlmTaskWorkloadReferenceSha256 -Value $savedReferenceHasher}
$hashes=Get-FastLlmArithmeticDiagnosticSourceHashes -ToolSourcePath $tool -TaskQualityToolSourcePath $taskQuality
foreach($key in @('diagnostic','tool','taskQualityParser','workload','semanticSmoke','module','benchmark','runtime','httpHost','listener')){
    Check ($hashes.Contains($key) -and [string]$hashes[$key] -cmatch '^[0-9a-f]{64}$') "missing source hash $key"
}
Check (Test-FastLlmArithmeticDiagnosticSourceHashes $hashes $tool $taskQuality) 'unchanged sources rejected'
$diagnosticSource=[IO.File]::ReadAllText($diagnostic)
$toolSource=[IO.File]::ReadAllText($tool)
foreach($required in @("`$env:OS -cne 'Windows_NT'",'[Environment]::Is64BitProcess',
                       'WindowsBuiltInRole]::Administrator',"'benchmark.lock'",'[IO.FileMode]::CreateNew',
                       '[IO.FileAttributes]::ReparsePoint')){
    Check ($diagnosticSource.Contains($required)) "wrapper safety contract missing $required"
}
Check ($toolSource.Contains('. $TaskQuality -OutputPath $Destination') -and
    $toolSource.Contains('Invoke-FastLlmArithmeticDiagnostic')) 'tool does not load the guarded canonical parser path'

$sampleIndex=0
foreach($sample in @(
    @{text='63';grade='correct';error=$null;class='strict-pass'},
    @{text='64';grade='incorrect';error='WRONG_ANSWER';class='wrong-numeric-value'},
    @{text='-63';grade='incorrect';error='WRONG_ANSWER';class='wrong-numeric-value'},
    @{text='+64';grade='incorrect';error='WRONG_ANSWER';class='wrong-numeric-value'},
    @{text='+063';grade='incorrect';error='WRONG_ANSWER';class='correct-value-noncanonical-format'},
    @{text='063';grade='incorrect';error='WRONG_ANSWER';class='correct-value-noncanonical-format'},
    @{text='63.';grade='incorrect';error='WRONG_ANSWER';class='correct-value-noncanonical-format'},
    @{text='`63`';grade='incorrect';error='WRONG_ANSWER';class='correct-value-noncanonical-format'},
    @{text=([string]::Join("`n",@('```','63','```')));grade='incorrect';error='FENCED_OUTPUT';class='correct-value-noncanonical-format'},
    @{text='The answer is 63';grade='incorrect';error='WRONG_ANSWER';class='wrong-or-unclassified'},
    @{text='21*3';grade='incorrect';error='WRONG_ANSWER';class='wrong-or-unclassified'},
    @{text='`64`';grade='incorrect';error='WRONG_ANSWER';class='wrong-or-unclassified'},
    @{text=([string]::Join("`n",@('```','64','```')));grade='incorrect';error='FENCED_OUTPUT';class='wrong-or-unclassified'},
    @{text='63.0';grade='incorrect';error='WRONG_ANSWER';class='wrong-or-unclassified'}
)){
    $parsed=Get-FastLlmArithmeticDiagnosticClassification -Response (New-TestResponse $sample.text) -Case $case -EffectiveContext 8192
    Check ($parsed.originalGrade -ceq $sample.grade -and $parsed.originalErrorCode -ceq $sample.error -and
        $parsed.diagnosticClassification -ceq $sample.class) "classification changed for bounded injection index $sampleIndex ($($sample.class))"
    $sampleIndex++
}
$malformed=Get-FastLlmArithmeticDiagnosticClassification -Response ([pscustomobject]@{Status=200;Body='not-json'}) -Case $case -EffectiveContext 8192
Check ($malformed.originalGrade -ceq 'inconclusive' -and $malformed.originalErrorCode -ceq 'invalid-response' -and
    $malformed.diagnosticClassification -ceq 'inconclusive') 'malformed response was not inconclusive'
$truncated=Get-FastLlmArithmeticDiagnosticClassification -Response (New-TestResponse '63' 'length') -Case $case -EffectiveContext 8192
Check ($truncated.originalErrorCode -ceq 'truncated' -and $truncated.diagnosticClassification -ceq 'inconclusive') 'truncation was reclassified'
$missingUsage=Get-FastLlmArithmeticDiagnosticClassification -Response (New-TestResponse '63' 'stop' @{}) -Case $case -EffectiveContext 8192
Check ($missingUsage.originalErrorCode -ceq 'missing-actual-usage' -and $missingUsage.diagnosticClassification -ceq 'inconclusive') 'missing usage was reclassified'
$reasoning=Get-FastLlmArithmeticDiagnosticClassification -Response (New-TestResponse '63' 'stop' $null 'private chain') -Case $case -EffectiveContext 8192
Check ($reasoning.originalErrorCode -ceq 'unexpected-reasoning' -and $reasoning.diagnosticClassification -ceq 'inconclusive') 'reasoning was reclassified'
$visible=Get-FastLlmArithmeticDiagnosticClassification -Response (New-TestResponse '<think>x</think>63') -Case $case -EffectiveContext 8192
Check ($visible.originalErrorCode -ceq 'visible-reasoning' -and $visible.diagnosticClassification -ceq 'inconclusive') 'visible reasoning was reclassified'

$root=New-TestRoot
try{
    $script:requests=0;$script:checksSeen=0;$script:bodies=@();$script:timeouts=@()
    $out=Join-Path $root 'strict.json'
    $report=Invoke-FastLlmArithmeticDiagnosticCore -OutputPath $out -ToolSourcePath $tool -TaskQualityToolSourcePath $taskQuality `
        -DeadlineSeconds 30 -RequestTimeoutSeconds 5 -ReadState {$script:state} `
        -CheckProcess {param($State)$script:checksSeen++;if($State.processIdentity.pid -ne 42){throw 'identity changed'}} `
        -Request {param($Path,$Body,$TimeoutMs)
            $script:requests++;$script:bodies+=,$Body;$script:timeouts+=$TimeoutMs
            if($Path -cne '/v1/chat/completions'){throw 'wrong path'}
            New-TestResponse '63'}
    Check ($script:requests -eq 1 -and $report.methodology.issuedRequests -eq 1 -and $report.methodology.retryCount -eq 0) 'diagnostic did not issue exactly one request'
    Check ($script:checksSeen -ge 4 -and $report.bindingStatus -ceq 'verified' -and $report.sourceProvenance.endStatus -ceq 'verified') 'pre/post/final binding checks missing'
    $body=$script:bodies[0]
    Check ($body.model -ceq 'qwen-test' -and @($body.messages).Count -eq 1 -and $body.messages[0].content -ceq $case.prompt -and
        [int]$body.max_tokens -eq 32 -and [int]$body.temperature -eq 0 -and [int]$body.seed -eq 42 -and
        $body.stream -eq $false -and $body.cache_prompt -eq $false -and $body.chat_template_kwargs.enable_thinking -eq $false -and
        $null -eq $body.PSObject.Properties['response_format']) 'canonical task-assessment request changed'
    Check ($script:timeouts.Count -eq 1 -and $script:timeouts[0] -gt 0 -and $script:timeouts[0] -le 5000) 'hard request timeout was not bounded'
    Check ($report.reportStatus -ceq 'complete' -and $report.result.originalGrade -ceq 'correct' -and
        $report.result.diagnosticClassification -ceq 'strict-pass' -and $report.diagnosticConclusive -eq $true) 'strict pass was not retained'
    Check ($report.methodology.hardRequestTimeout -eq $true -and $report.methodology.hardWallClockDeadline -eq $false -and
        $report.methodology.outerProcessDeadlineOwner -eq $false) 'deadline ownership was overstated'
    $serialized=[IO.File]::ReadAllText($out)
    Check (-not $serialized.Contains($case.prompt) -and -not $serialized.Contains('"content":"63"') -and
        $report.rawPromptOrResponseRetained -eq $false -and $report.answerTextRetained -eq $false -and
        $report.answerSha256Retained -eq $false) 'prompt or answer material leaked'
    Check ($report.qualification.approved -eq $false -and $report.qualification.qualityEvaluation -eq $false) 'diagnostic claimed qualification'

    $script:requests=0
    $format=Invoke-FastLlmArithmeticDiagnosticCore -OutputPath (Join-Path $root 'format.json') -ToolSourcePath $tool `
        -TaskQualityToolSourcePath $taskQuality -DeadlineSeconds 30 -RequestTimeoutSeconds 5 `
        -ReadState {$script:state} -CheckProcess {param($State)} `
        -Request {param($Path,$Body,$TimeoutMs)$script:requests++;New-TestResponse '+063'}
    Check ($script:requests -eq 1 -and $format.result.originalGrade -ceq 'incorrect' -and
        $format.result.originalErrorCode -ceq 'WRONG_ANSWER' -and $format.result.originalClassification -ceq 'wrong-answer' -and
        $format.result.diagnosticClassification -ceq 'correct-value-noncanonical-format' -and
        $format.diagnosticConclusive -eq $true) 'strict failure was overwritten by secondary classification'

    $script:requests=0
    $unclassified=Invoke-FastLlmArithmeticDiagnosticCore -OutputPath (Join-Path $root 'unclassified.json') -ToolSourcePath $tool `
        -TaskQualityToolSourcePath $taskQuality -DeadlineSeconds 30 -RequestTimeoutSeconds 5 `
        -ReadState {$script:state} -CheckProcess {param($State)} `
        -Request {param($Path,$Body,$TimeoutMs)$script:requests++;New-TestResponse 'The answer is 63'}
    Check ($script:requests -eq 1 -and $unclassified.reportStatus -ceq 'complete' -and
        $unclassified.result.originalGrade -ceq 'incorrect' -and
        $unclassified.result.diagnosticClassification -ceq 'wrong-or-unclassified' -and
        $unclassified.diagnosticConclusive -eq $false) 'unclassified prose was overstated as conclusive'

    $script:requests=0
    $transport=Invoke-FastLlmArithmeticDiagnosticCore -OutputPath (Join-Path $root 'request-error.json') -ToolSourcePath $tool `
        -TaskQualityToolSourcePath $taskQuality -DeadlineSeconds 30 -RequestTimeoutSeconds 5 `
        -ReadState {$script:state} -CheckProcess {param($State)} `
        -Request {param($Path,$Body,$TimeoutMs)$script:requests++;throw 'private transport text'}
    Check ($script:requests -eq 1 -and $transport.reportStatus -ceq 'aborted' -and
        $transport.failureCode -ceq 'request-error' -and $transport.result.diagnosticClassification -ceq 'inconclusive') 'request error retried or escaped'
    Check (-not ([IO.File]::ReadAllText((Join-Path $root 'request-error.json'))).Contains('private transport text')) 'private error text leaked'

    $script:requests=0;$script:reads=0
    $identity=Invoke-FastLlmArithmeticDiagnosticCore -OutputPath (Join-Path $root 'identity.json') -ToolSourcePath $tool `
        -TaskQualityToolSourcePath $taskQuality -DeadlineSeconds 30 -RequestTimeoutSeconds 5 `
        -ReadState {$script:reads++;if($script:reads -eq 3){
            $changed=$script:state.PSObject.Copy();$changed.runId=('f'*32);$changed
        }else{$script:state}} -CheckProcess {param($State)} `
        -Request {param($Path,$Body,$TimeoutMs)$script:requests++;New-TestResponse '63'}
    Check ($script:requests -eq 1 -and $identity.reportStatus -ceq 'aborted' -and
        $identity.failureCode -ceq 'identity-changed' -and $identity.bindingStatus -ceq 'compromised') 'identity change did not invalidate issued result'

    $savedHashes=(Get-Command Get-FastLlmArithmeticDiagnosticSourceHashes).ScriptBlock
    try{
        $script:sourceReads=0;$script:requests=0
        Set-Item Function:Get-FastLlmArithmeticDiagnosticSourceHashes -Value {
            param($ToolSourcePath,$TaskQualityToolSourcePath)
            $script:sourceReads++
            [ordered]@{diagnostic=$(if($script:sourceReads -ge 3){'f'*64}else{'e'*64})}
        }
        $sourceChanged=Invoke-FastLlmArithmeticDiagnosticCore -OutputPath (Join-Path $root 'source.json') -ToolSourcePath $tool `
            -TaskQualityToolSourcePath $taskQuality -DeadlineSeconds 30 -RequestTimeoutSeconds 5 `
            -ReadState {$script:state} -CheckProcess {param($State)} `
            -Request {param($Path,$Body,$TimeoutMs)$script:requests++;New-TestResponse '63'}
        Check ($script:requests -eq 1 -and $sourceChanged.reportStatus -ceq 'aborted' -and
            $sourceChanged.failureCode -ceq 'source-changed' -and $sourceChanged.sourceProvenance.endStatus -ceq 'changed') 'source change did not invalidate issued result'
    }finally{Set-Item Function:Get-FastLlmArithmeticDiagnosticSourceHashes -Value $savedHashes}

    $script:requests=0
    $deadline=Invoke-FastLlmArithmeticDiagnosticCore -OutputPath (Join-Path $root 'deadline.json') -ToolSourcePath $tool `
        -TaskQualityToolSourcePath $taskQuality -DeadlineSeconds 1 -RequestTimeoutSeconds 1 `
        -ReadState {$script:state} -CheckProcess {param($State)} `
        -Request {param($Path,$Body,$TimeoutMs)$script:requests++;Start-Sleep -Milliseconds 1100;New-TestResponse '63'}
    Check ($script:requests -eq 1 -and $deadline.reportStatus -ceq 'aborted' -and
        $deadline.failureCode -ceq 'deadline' -and $deadline.result.diagnosticClassification -ceq 'inconclusive') 'elapsed deadline was treated as a hard-core success'

    $existsRejected=$false
    try{
        Invoke-FastLlmArithmeticDiagnosticCore -OutputPath $out -ToolSourcePath $tool -TaskQualityToolSourcePath $taskQuality `
            -ReadState {$script:state} -CheckProcess {param($State)} -Request {param($Path,$Body,$TimeoutMs)New-TestResponse '63'}|Out-Null
    }catch{$existsRejected=$true}
    Check $existsRejected 'CreateNew output was not protected'

    $module=Import-Module (Join-Path $repoRoot 'src/FastLlm.psm1') -Force -PassThru
    $moduleOut=Join-Path $root 'module.json'
    $moduleResult=& $module {
        param($Semantic,$Workload,$TaskQuality,$Diagnostic,$Tool,$Output,$State,$Response)
        . $Semantic;. $Workload;. $TaskQuality -OutputPath $Output;. $Diagnostic
        Invoke-FastLlmArithmeticDiagnosticCore -OutputPath $Output -ToolSourcePath $Tool `
            -TaskQualityToolSourcePath $TaskQuality -DeadlineSeconds 30 -RequestTimeoutSeconds 5 `
            -ReadState {$State} -CheckProcess {param($Current)if($Current.processIdentity.pid -ne 42){throw 'changed'}} `
            -Request $Response
    } $semantic $workload $taskQuality $diagnostic $tool $moduleOut $script:state {param($Path,$Body,$TimeoutMs)New-TestResponse '63'}
    Check ($moduleResult.reportStatus -ceq 'complete' -and $moduleResult.result.diagnosticClassification -ceq 'strict-pass') 'strict imported-module integration failed'
    Write-Host "PASS: $script:checks arithmetic diagnostic focused assertions. No engine or model invoked."
}finally{
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
}
