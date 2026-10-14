#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force -PassThru
$semantic=Join-Path $root 'src/FastLlm.SemanticSmoke.ps1'
$diagnostic=Join-Path $root 'src/FastLlm.JsonFormatDiagnostic.ps1'
$tool=Join-Path $root 'tools/json-format-diagnostic.ps1'
. $semantic
. $diagnostic
$count=0
function Check($Condition,$Message){if(-not $Condition){throw $Message};$script:count++}
function TempPath {Join-Path ([IO.Path]::GetTempPath()) ('fastllm-json-format-'+[Guid]::NewGuid().ToString('N')+'.json')}
function Response($Text,[string]$Finish='stop') {
    [pscustomobject]@{Status=200;Body=(@{choices=@(@{finish_reason=$Finish;message=@{role='assistant';content=$Text}});
        usage=@{completion_tokens=14}} | ConvertTo-Json -Depth 8 -Compress)}
}
$privateResolution=& $module {param($Semantic,$Diagnostic) . $Semantic; . $Diagnostic
    @('Invoke-FastLlmJsonFormatDiagnostic','Assert-FastLlmSemanticSmokeProcess','Invoke-FastLlmHttp') |
        ForEach-Object { [bool](Get-Command $_ -ErrorAction SilentlyContinue) }
} $semantic $diagnostic
Check (@($privateResolution|Where-Object {-not $_}).Count -eq 0) 'Private module helpers do not resolve.'
$script:state=[pscustomobject]@{
    schemaVersion=1;active=$true;phase='ready';runId='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';endpoint='http://127.0.0.1:8080/v1'
    modelId='qwen-test';modelSha256=('a'*64);engineVersion='b10698'
    processIdentity=[pscustomobject]@{pid=42;startUtcTicks=638000000000000000}
    canary=[pscustomobject]@{modelIdentity=$true;repeatableToken=$true;synchronousChat=$true;streaming=$true;
        effectiveContext=8192;semanticCorrectnessQualified=$false}
    placement=[pscustomobject]@{reportedLayers=66;totalLayers=66;reportedAllLayers=$true;devices=@('Vulkan0')}
    recipe=[pscustomobject]@{backend='Vulkan';contextSize=8192;slots=1;engineSha256=('b'*64);catalogSha256=('c'*64);
        requestedArguments=@('--host','127.0.0.1','--port','8080','--alias','qwen-test','--ctx-size','8192','--parallel','1')}
}
$script:responses=@((Response '{"name":"Ada","age":37}'),(Response '{"name":"Ada","age":37}'))
$script:requests=0;$script:bodies=@();$script:checks=0
$out=TempPath
try{
    $report=Invoke-FastLlmJsonFormatDiagnosticCore -OutputPath $out -ToolSourcePath $tool `
        -ReadState {$script:state} -CheckProcess {param($State)$script:checks++} `
        -Request {param($Path,$Body,$TimeoutMs)
            if($Path -cne '/v1/chat/completions' -or $TimeoutMs -lt 1 -or $TimeoutMs -gt 60000){throw 'Unexpected request endpoint or deadline.'}
            $script:bodies+=,$Body;$script:requests++;$script:responses[$script:requests-1]}
    Check ($report.results.Count -eq 2 -and $report.aborted -eq $false) 'The two fixed requests did not finish.'
    Check (@($report.methodology.requestVariants).Count -eq 2 -and
        $report.methodology.requestVariants[0] -ceq 'unconstrained' -and
        $report.methodology.requestVariants[1] -ceq 'json_object' -and
        -not (@($report.PSObject.Properties.Name) -contains 'diagnosticMode')) 'The default two-request protocol changed.'
    Check ($report.results[0].classification -ceq 'strict-pass' -and $report.results[1].classification -ceq 'strict-pass') 'Strict-valid JSON was not accepted.'
    Check ($script:requests -eq 2 -and $script:checks -ge 5) 'Requests lacked pre/post process checks.'
    $case=(Get-FastLlmSemanticSmokeCases)[1]
    Check ($script:bodies[0].messages[0].content -ceq $case.prompt -and $script:bodies[1].messages[0].content -ceq $case.prompt) 'Fixed prompt changed.'
    Check ($script:bodies[0].model -ceq 'qwen-test' -and $script:bodies[0].max_tokens -eq 96 -and
        $script:bodies[0].temperature -eq 0 -and $script:bodies[0].seed -eq 42 -and
        $script:bodies[0].stream -eq $false -and $script:bodies[0].cache_prompt -eq $false -and
        $script:bodies[0].chat_template_kwargs.enable_thinking -eq $false) 'Original fixed request body changed.'
    Check (-not $script:bodies[0].ContainsKey('response_format') -and $script:bodies[1].response_format.type -ceq 'json_object' -and
        $script:bodies[1].response_format.Count -eq 1 -and
        $script:bodies[1].Count -eq $script:bodies[0].Count+1) 'JSON-mode arm changed more than response_format.'
    $text=[IO.File]::ReadAllText($out)
    Check (-not $text.Contains('Ada') -and -not $text.Contains($case.prompt) -and
        $report.rawPromptOrResponseRetained -eq $false) 'Diagnostic retained answer/prompt text.'
    Check ($report.qualification.approved -eq $false -and $report.qualification.semanticQualified -eq $false -and
        $report.methodology.elapsedBudgetSeconds -eq 180) 'Report claimed qualification or lost deadline.'
}finally{if(Test-Path $out){Remove-Item -LiteralPath $out -Force}}

foreach($singleMode in @('unconstrained-only','json-object-only')){
    $script:requests=0;$script:bodies=@();$script:checks=0;$out=TempPath
    try{
        $report=Invoke-FastLlmJsonFormatDiagnosticCore -Mode $singleMode -OutputPath $out -ToolSourcePath $tool `
            -ReadState {$script:state} -CheckProcess {param($State)$script:checks++} `
            -Request {param($Path,$Body,$TimeoutMs)
                $script:requests++;$script:bodies+=,$Body
                if($Path -cne '/v1/chat/completions' -or $TimeoutMs -lt 1 -or $TimeoutMs -gt 60000){throw 'Single-request endpoint or deadline changed.'}
                Response '{"name":"Ada","age":37}'}
        $expectedVariant=if($singleMode -ceq 'unconstrained-only'){'unconstrained'}else{'json_object'}
        Check ($script:requests -eq 1 -and $script:checks -ge 3 -and $report.aborted -eq $false -and
            @($report.results).Count -eq 1 -and $report.results[0].variant -ceq $expectedVariant -and
            $report.results[0].strictOutcome -ceq 'pass' -and $report.diagnosticMode -ceq $singleMode -and
            @($report.methodology.requestVariants).Count -eq 1 -and
            $report.methodology.requestVariants[0] -ceq $expectedVariant) 'Single-request mode issued the wrong case or number of requests.'
        Check ($script:bodies[0].messages[0].content -ceq (Get-FastLlmSemanticSmokeCases)[1].prompt) 'Single-request mode changed the fixed case.'
        Check (($singleMode -ceq 'unconstrained-only' -and -not $script:bodies[0].ContainsKey('response_format')) -or
            ($singleMode -ceq 'json-object-only' -and $script:bodies[0].response_format.type -ceq 'json_object' -and
             $script:bodies[0].response_format.Count -eq 1)) 'Single-request mode changed response_format.'
        Check (-not ([IO.File]::ReadAllText($out)).Contains('Ada') -and $report.qualification.approved -eq $false) 'Single-request report leaked text or claimed qualification.'
    }finally{if(Test-Path $out){Remove-Item -LiteralPath $out -Force}}
}

foreach($singleMode in @('unconstrained-only','json-object-only')){
    $script:requests=0;$out=TempPath
    try{
        $report=Invoke-FastLlmJsonFormatDiagnosticCore -Mode $singleMode -OutputPath $out -ToolSourcePath $tool `
            -ReadState {$script:state} -CheckProcess {param($State)} `
            -Request {param($Path,$Body,$TimeoutMs)$script:requests++;throw 'synthetic request failure'}
        Check ($script:requests -eq 1 -and @($report.results).Count -eq 1 -and
            $report.results[0].strictErrorCode -ceq 'request-error' -and
            $report.results[0].strictOutcome -ceq 'inconclusive' -and
            $null -eq $report.results[0].httpStatus) 'One-request transport failure was not recorded without a second request.'
    }finally{if(Test-Path $out){Remove-Item -LiteralPath $out -Force}}
}

$fenced=[string]::Join("`n",@('```json','{"name":"Ada","age":37}','```'))
$jsonCase=(Get-FastLlmSemanticSmokeCases)[1]
$script:responses=@((Response $fenced))
$script:requests=0;$script:bodies=@();$script:checks=0;$out=TempPath
try{
    $report=Invoke-FastLlmJsonFormatDiagnosticCore -Mode 'explicit-object-schema' -OutputPath $out -ToolSourcePath $tool `
        -ReadState {$script:state} -CheckProcess {param($State)$script:checks++} `
        -Request {param($Path,$Body,$TimeoutMs)
            if($Path -cne '/v1/chat/completions' -or $TimeoutMs -lt 1 -or $TimeoutMs -gt 60000){throw 'Unexpected explicit-schema request.'}
            $script:bodies+=,$Body;$script:requests++;$script:responses[0]}
    Check ($script:requests -eq 1 -and $script:checks -ge 3 -and @($report.results).Count -eq 1 -and
        $report.aborted -eq $false) 'Explicit-schema mode must make exactly one supervised request.'
    Check ($report.results[0].variant -ceq 'explicit-object-schema' -and
        $report.results[0].responseFormat -ceq 'json_object' -and
        $report.results[0].schema.type -ceq 'object' -and
        $report.methodology.requestVariants.Count -eq 1 -and
        $report.methodology.responseFormatSchema.type -ceq 'object' -and
        $report.diagnosticMode -ceq 'explicit-object-schema') 'Exact explicit-schema variant was not recorded.'
    Check ($script:bodies[0].Count -eq 9 -and
        $script:bodies[0].response_format.Count -eq 2 -and
        $script:bodies[0].response_format.type -ceq 'json_object' -and
        $script:bodies[0].response_format.schema.Count -eq 1 -and
        $script:bodies[0].response_format.schema.type -ceq 'object' -and
        -not $script:bodies[0].ContainsKey('json_schema')) 'Explicit-schema request shape changed.'
    Check ($script:bodies[0].messages[0].content -ceq $jsonCase.prompt -and
        $script:bodies[0].model -ceq 'qwen-test' -and $script:bodies[0].max_tokens -eq 96 -and
        $script:bodies[0].temperature -eq 0 -and $script:bodies[0].seed -eq 42 -and
        $script:bodies[0].stream -eq $false -and $script:bodies[0].cache_prompt -eq $false -and
        $script:bodies[0].chat_template_kwargs.enable_thinking -eq $false) 'Fixed case or sampling changed in explicit-schema mode.'
    Check ($report.results[0].strictOutcome -ceq 'fail' -and
        $report.results[0].classification -ceq 'fenced-valid-json' -and
        -not ([IO.File]::ReadAllText($out)).Contains('Ada') -and
        -not ([IO.File]::ReadAllText($out)).Contains($jsonCase.prompt) -and
        -not ([IO.File]::ReadAllText($out)).Contains('```') -and
        $report.rawPromptOrResponseRetained -eq $false -and
        $report.qualification.approved -eq $false) 'Explicit-schema mode relaxed grading, leaked text, or claimed qualification.'
}finally{if(Test-Path $out){Remove-Item -LiteralPath $out -Force}}

$fenced=[string]::Join("`n",@('```json','{"name":"Ada","age":37}','```'))
$script:responses=@((Response $fenced),(Response '{"name":"Ada","age":37}'))
$script:requests=0;$out=TempPath
try{
    $report=Invoke-FastLlmJsonFormatDiagnosticCore -OutputPath $out -ToolSourcePath $tool `
        -ReadState {$script:state} -CheckProcess {param($State)} `
        -Request {param($Path,$Body,$TimeoutMs)$script:requests++;$script:responses[$script:requests-1]}
    Check ($report.results[0].strictOutcome -ceq 'fail' -and $report.results[0].classification -ceq 'fenced-valid-json') 'One exact Markdown fence was not distinguished from wrong values.'
    Check ($report.results[1].classification -ceq 'strict-pass') 'Explicit JSON arm failed strict parser.'
    Check (-not ([IO.File]::ReadAllText($out)).Contains('```')) 'Fenced raw output leaked into report.'
}finally{if(Test-Path $out){Remove-Item -LiteralPath $out -Force}}

$jsonCase=(Get-FastLlmSemanticSmokeCases)[1]
$wrong=Get-FastLlmJsonFormatClassification -Case $jsonCase -Response (Response '{"name":"Ada","age":38}')
Check ($wrong.strictOutcome -ceq 'fail' -and $wrong.classification -ceq 'wrong-or-invalid') 'Wrong value was treated as valid JSON.'
$malformed=Get-FastLlmJsonFormatClassification -Case $jsonCase -Response (Response '{"name":')
Check ($malformed.strictOutcome -ceq 'fail' -and $malformed.classification -ceq 'wrong-or-invalid') 'Malformed answer was treated as valid JSON.'
$badBody=Get-FastLlmJsonFormatClassification -Case $jsonCase -Response ([pscustomobject]@{Status=200;Body='not-json'})
Check ($badBody.strictOutcome -ceq 'inconclusive' -and $badBody.strictErrorCode -ceq 'invalid-response') 'Malformed API body was scored as a wrong answer.'
$unfinished=Get-FastLlmJsonFormatClassification -Case $jsonCase -Response (Response '{"name":"Ada","age":37}' 'length')
Check ($unfinished.strictOutcome -ceq 'inconclusive' -and $unfinished.strictErrorCode -ceq 'truncated') 'Unexpected finish was scored as strict success.'
$twoFences=[string]::Join("`n",@('```json','{"name":"Ada","age":37}','```','```json','{"name":"Ada","age":37}','```'))
$doubleFence=Get-FastLlmJsonFormatClassification -Case $jsonCase -Response (Response $twoFences)
Check ($doubleFence.classification -ceq 'wrong-or-invalid') 'Multiple fences were accepted.'

$script:requests=0;$out=TempPath
try{
    $report=Invoke-FastLlmJsonFormatDiagnosticCore -OutputPath $out -ToolSourcePath $tool `
        -ReadState {$script:state} -CheckProcess {param($State)if($script:requests -ge 1){throw 'changed'}} `
        -Request {param($Path,$Body,$TimeoutMs)$script:requests++;Response '{"name":"Ada","age":37}'}
    Check ($script:requests -eq 1 -and $report.aborted -eq $true -and $report.failureCode -ceq 'identity-changed') 'Identity change did not abort before JSON-mode request.'
    Check ($report.results.Count -eq 1 -and $report.results[0].strictErrorCode -ceq 'identity-changed') 'Identity-change evidence missing.'
}finally{if(Test-Path $out){Remove-Item -LiteralPath $out -Force}}
Write-Host "$count JSON-format diagnostic focused assertions passed."
