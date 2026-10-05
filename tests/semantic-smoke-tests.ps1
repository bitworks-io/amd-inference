#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force -PassThru
$source=Join-Path $root 'src/FastLlm.SemanticSmoke.ps1'
. $source
$count=0
function Check($Condition,$Message){if(-not $Condition){throw $Message};$script:count++}
function TempPath {Join-Path ([IO.Path]::GetTempPath()) ('fastllm-semantic-'+[Guid]::NewGuid().ToString('N')+'.json')}
$privateResolution=& $module {param($S) . $S; @('Get-FastLlmStateRoot','Join-FastLlmContainedPath','Invoke-FastLlmHttp','Invoke-FastLlmSemanticSmoke') | ForEach-Object { [bool](Get-Command $_ -ErrorAction SilentlyContinue) }} $source
Check (@($privateResolution|Where-Object { -not $_ }).Count -eq 0) 'Standalone evaluator cannot resolve private module helpers in tool scope.'
$script:state=[pscustomobject]@{
    schemaVersion=1;active=$true;phase='ready';runId='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';endpoint='http://127.0.0.1:8080/v1'
    modelId='qwen-test';modelSha256=('a'*64);engineVersion='b10698';engineSha256=('b'*64);catalogSha256=('c'*64)
    processIdentity=[pscustomobject]@{pid=42;startUtcTicks=638000000000000000}
    canary=[pscustomobject]@{modelIdentity=$true;repeatableToken=$true;synchronousChat=$true;streaming=$true;effectiveContext=8192;semanticCorrectnessQualified=$false}
    placement=[pscustomobject]@{reportedLayers=66;totalLayers=66;reportedAllLayers=$true;devices=@('Vulkan0')}
    recipe=[pscustomobject]@{backend='Vulkan';contextSize=8192;slots=1;engineSha256=('b'*64);catalogSha256=('c'*64);
        requestedArguments=@('--host','127.0.0.1','--port','8080','--alias','qwen-test','--ctx-size','8192','--parallel','1')}
}
$script:answers=@('12','{"name":"Ada","age":37}','READY')
$script:requests=0;$script:checks=0
$out=TempPath
try{
    $report=Invoke-FastLlmSemanticSmokeCore -OutputPath $out -ReadState { $script:state } -CheckProcess {param($State)$script:checks++} `
        -Request {param($Path,$Body,$TimeoutMs) $script:requests++; if($Path -cne '/v1/chat/completions' -or $Body.model -cne 'qwen-test' -or $Body.temperature -ne 0 -or $Body.seed -ne 42 -or $Body.stream -ne $false -or $Body.cache_prompt -ne $false -or $Body.chat_template_kwargs.enable_thinking -ne $false -or $TimeoutMs -gt 60000){throw 'Unexpected semantic request.'};
            [pscustomobject]@{Status=200;Body=(@{choices=@(@{finish_reason='stop';message=@{role='assistant';content=$script:answers[$script:requests-1]}});usage=@{completion_tokens=4}}|ConvertTo-Json -Depth 8)}}
    Check ($report.cases.Count -eq 3 -and $report.passed -eq 3 -and $report.failed -eq 0) 'Three fixed semantic cases did not pass.'
    Check ($script:requests -eq 3 -and $script:checks -ge 7) 'Each request lacked a process check before and after.'
    Check ($report.qualification.semanticQualified -eq $false -and $report.qualification.performanceQualified -eq $false) 'Smoke report claimed qualification.'
    $bytes=[IO.File]::ReadAllText($out)
    Check (-not $bytes.Contains('7 + 5') -and -not $bytes.Contains('"Ada"') -and -not $bytes.Contains('"READY"')) 'Smoke report disclosed prompt or completion content.'
    Check (@($report.cases|Where-Object {$_.promptSha256 -notmatch '^[0-9a-f]{64}$'}).Count -eq 0) 'Prompt digest absent.'
}finally{if(Test-Path $out){Remove-Item -LiteralPath $out -Force}}
$script:answers=@('13','{"name":"Ada","age":38}','ready');$script:requests=0
$out=TempPath
try{
    $report=Invoke-FastLlmSemanticSmokeCore -OutputPath $out -ReadState {$script:state} -CheckProcess {param($State)} `
      -Request {param($Path,$Body,$TimeoutMs) $script:requests++;[pscustomobject]@{Status=200;Body=(@{choices=@(@{finish_reason='stop';message=@{role='assistant';content=$script:answers[$script:requests-1]}});usage=@{completion_tokens=4}}|ConvertTo-Json -Depth 8)}}
    Check ($report.passed -eq 0 -and $report.failed -eq 3) 'Wrong semantic answers were accepted.'
}finally{if(Test-Path $out){Remove-Item -LiteralPath $out -Force}}
$script:answers=@('12','{"name":"Ada","age":37}','READY');$script:requests=0
$out=TempPath
try{
    $report=Invoke-FastLlmSemanticSmokeCore -OutputPath $out -ReadState {$script:state} -CheckProcess {param($State)} `
      -Request {param($Path,$Body,$TimeoutMs) $script:requests++;if($script:requests -eq 2){return [pscustomobject]@{Status=500;Body='private response should not leak'}};[pscustomobject]@{Status=200;Body=(@{choices=@(@{finish_reason='stop';message=@{role='assistant';content=$script:answers[$script:requests-1]}});usage=@{completion_tokens=4}}|ConvertTo-Json -Depth 8)}}
    Check ($report.passed -eq 2 -and $report.failed -eq 0 -and $report.inconclusive -eq 1 -and $report.cases[1].errorCode -eq 'http-status') 'HTTP error handling failed.'
    Check (-not ([IO.File]::ReadAllText($out)).Contains('private response')) 'HTTP body leaked.'
}finally{if(Test-Path $out){Remove-Item -LiteralPath $out -Force}}
$script:requests=0
$out=TempPath
try{
    $report=Invoke-FastLlmSemanticSmokeCore -OutputPath $out -ReadState {$script:state} `
      -CheckProcess {param($State) if($script:requests -ge 1){throw 'identity-changed'}} `
      -Request {param($Path,$Body,$TimeoutMs) $script:requests++;[pscustomobject]@{Status=200;Body='{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"12"}}]}'} }
    Check ($script:requests -eq 1 -and $report.aborted -eq $true -and $report.cases.Count -eq 1) 'Process change did not abort after first request.'
    Check ($report.cases[0].errorCode -eq 'identity-changed') 'Identity error code missing.'
}finally{if(Test-Path $out){Remove-Item -LiteralPath $out -Force}}
$fixed=(Get-FastLlmSemanticSmokeCases)[0]
$truncated=ConvertFrom-FastLlmSemanticSmokeResponse -Case $fixed -Response ([pscustomobject]@{Status=200;Body='{"choices":[{"finish_reason":"length","message":{"role":"assistant","content":"13"}}]}'})
Check ($truncated.outcome -eq 'inconclusive' -and $truncated.errorCode -eq 'truncated') 'Truncated reasoning or answer was scored as wrong.'
$reasoningOnly=ConvertFrom-FastLlmSemanticSmokeResponse -Case $fixed -Response ([pscustomobject]@{Status=200;Body='{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"","reasoning_content":"7+5=12"}}]}'})
Check ($reasoningOnly.outcome -eq 'inconclusive' -and $reasoningOnly.errorCode -eq 'reasoning-observed') 'Reasoning-only response was scored as a semantic failure.'
$missingFinish=ConvertFrom-FastLlmSemanticSmokeResponse -Case $fixed -Response ([pscustomobject]@{Status=200;Body='{"choices":[{"message":{"role":"assistant","content":"13"}}]}'})
Check ($missingFinish.outcome -eq 'inconclusive' -and $missingFinish.errorCode -eq 'invalid-response') 'Malformed response was scored as a semantic failure.'
$missingChoices=ConvertFrom-FastLlmSemanticSmokeResponse -Case $fixed -Response ([pscustomobject]@{Status=200;Body='{"usage":{"completion_tokens":2}}'})
Check ($missingChoices.outcome -eq 'inconclusive' -and $missingChoices.errorCode -eq 'invalid-response') 'Missing choices escaped strict response validation.'
$visibleThought=ConvertFrom-FastLlmSemanticSmokeResponse -Case $fixed -Response ([pscustomobject]@{Status=200;Body='{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"<think>7+5</think>12"}}]}'})
Check ($visibleThought.outcome -eq 'inconclusive' -and $visibleThought.errorCode -eq 'visible-reasoning') 'Visible thinking was scored as a semantic failure.'
$jsonCase=(Get-FastLlmSemanticSmokeCases)[1]
$duplicateJson=ConvertFrom-FastLlmSemanticSmokeResponse -Case $jsonCase -Response ([pscustomobject]@{Status=200;Body='{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"{\"name\":\"Ada\",\"age\":38,\"age\":37}"}}]}'})
Check ($duplicateJson.outcome -eq 'fail') 'Duplicate JSON keys were accepted as valid extraction.'
Write-Host "$count semantic smoke focused assertions passed."
