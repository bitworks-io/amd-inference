#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Split-Path $PSScriptRoot -Parent
$source=Join-Path $root 'src/FastLlm.HipSemanticSmoke.ps1'
$tokens=$null;$errors=$null
$null=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw 'HIP semantic smoke source has parser errors.'}
$module=Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force -PassThru
$count=0
function Check($ok,$message){if(-not $ok){throw $message};$script:count++}
function Reject($action,$message){$threw=$false;try{& $action|Out-Null}catch{$threw=$true};Check $threw $message}
function TempPath {Join-Path ([IO.Path]::GetTempPath()) ('fastllm-hip-semantic-'+[Guid]::NewGuid().ToString('N')+'.json')}
$trialHash=(Get-FileHash (Join-Path $root 'src/FastLlm.HipModelTrial.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()
$script:state=[pscustomobject]@{
    schemaVersion=1;active=$true;kind='fastllm-hip-b1339-private-trial';phase='hip-lab-ready';
    endpoint='http://127.0.0.1:18081/v1';runId=('a'*32);experimental=$true
    modelId='qwen-test';modelSha256=('b'*64);engineVersion='lemonade-b1339-gfx110X';
    engineSha256=('c'*64);catalogSha256=('d'*64);trialSourceSha256=$trialHash
    processIdentity=[pscustomobject]@{pid=23456;startUtcTicks=638000000000000000}
    selectedDevice=[pscustomobject]@{device='ROCm0';name='AMD Radeon';reportedFreeMiB=20000}
    allowHostModelBuffer=$true;placementClassification='all-reported-layers-with-host-model-buffer';
    allWeightsOnGpuVerified=$false;allOperationsOnGpuVerified=$false;cpuInputEvidence='not-attested';
    performanceQualified=$false;physicalResidencyVerified=$false;dynamicClosureVerified=$false
    recipe=[pscustomobject]@{backend='ROCm';device='ROCm0';contextSize=8192;slots=1;gpuLayers='all';fitMode='off';
        splitMode='none';cacheTypeK='f16';cacheTypeV='f16';speculation='none';flashAttention='auto';allowHostModelBuffer=$true;
        requestedArguments=@('--model','<verified-model>','--alias','qwen-test','--host','127.0.0.1','--port','18081',
            '--ctx-size','8192','--parallel','1','--device','ROCm0','--n-gpu-layers','all','--fit','off',
            '--split-mode','none','--cache-type-k','f16','--cache-type-v','f16')}
    placement=[pscustomobject]@{reportedLayers=66;totalLayers=66;reportedAllLayers=$true;devices=@('ROCm0');
        modelBufferMiB=@([pscustomobject]@{device='ROCm0';sizeMiB=14674.45});physicalResidencyVerified=$false}
    placementEvidence=[pscustomobject]@{status='captured';cpuBufferLikeLines=1;cpuModelBufferRows=1;
        offloadRows=@([pscustomobject]@{reportedGpuLayers=66;reportedTotalLayers=66});
        modelBuffers=@([pscustomobject]@{device='ROCm0';sizeMiB=14674.45},[pscustomobject]@{device='CPU_Mapped';sizeMiB=682.03});
        physicalResidencyVerified=$false}
    startupDiagnostics=[pscustomobject]@{status='captured';physicalResidencyVerified=$false}
    canary=[pscustomobject]@{modelIdentity=$true;repeatableToken=$true;synchronousChat=$true;streaming=$true;
        effectiveContext=8192;semanticCorrectnessQualified=$false}
}
$script:answers=@('12','{"name":"Ada","age":37}','READY');$script:requests=0;$script:checks=0
$request={param($path,$body,$timeoutMs)
    $script:requests++
    if($path -cne '/v1/chat/completions' -or $body.model -cne 'qwen-test' -or $body.max_tokens -ne 96 -or
       $body.temperature -ne 0 -or $body.seed -ne 42 -or $body.stream -ne $false -or
       $body.cache_prompt -ne $false -or $body.chat_template_kwargs.enable_thinking -ne $false -or
       $timeoutMs -le 0 -or $timeoutMs -gt 60000){throw 'Unexpected HIP semantic request.'}
    return [pscustomobject]@{Status=200;Body=(@{choices=@(@{finish_reason='stop';
        message=@{role='assistant';content=$script:answers[$script:requests-1]}});usage=@{completion_tokens=4}}|ConvertTo-Json -Depth 8)}
}
$read={return $script:state}
$check={param($s) $script:checks++;if($s.processIdentity.pid -ne 23456){throw 'process changed'}}
$semanticSource=Join-Path $root 'src/FastLlm.SemanticSmoke.ps1'
$hipBenchmarkSource=Join-Path $root 'src/FastLlm.HipBenchmark.ps1'
$invoke={param($Path,$Read,$Request,$Check) & $module {param($S,$Semantic,$HipBenchmark,$O,$Run,$R,$Q,$C) . $Semantic;. $HipBenchmark;. $S;
    Invoke-FastLlmHipSemanticSmokeCore -OutputPath $O -RunId $Run -ReadState $R -Request $Q -CheckProcess $C -DeadlineSeconds 60
} $source $semanticSource $hipBenchmarkSource $Path ('a'*32) $Read $Request $Check}
$out=TempPath
try{
    $report=& $invoke $out $read $request $check
    Check ($report.resultKind -eq 'native-windows-hip-semantic-smoke-experiment' -and $report.passed -eq 3 -and $report.status -eq 'smoke-passed') 'Three fixed HIP semantic cases did not pass in a distinct report.'
    Check ($script:requests -eq 3 -and $script:checks -ge 7) 'Each HIP request lacked before/after identity checks.'
    Check ($report.allowHostModelBuffer -eq $true -and $report.reportedHostModelBufferMiB -eq 682.03 -and
           -not $report.allWeightsOnGpuVerified -and -not $report.allOperationsOnGpuVerified -and
           $report.cpuInputEvidence -eq 'not-attested') 'Host model-buffer caveat was lost or overclaimed.'
    Check ($report.qualification.approved -eq $false -and $report.qualification.semanticQualified -eq $false -and
           $report.methodology.maxOutputTokens -eq 96 -and $report.methodology.hardWallClockDeadline -eq $false) 'Smoke report claimed qualification or a false hard deadline.'
    $saved=[IO.File]::ReadAllText($out)
    Check ($saved -notmatch '7 \+ 5|"Ada"|"READY"|private response' -and $saved -match 'native-windows-hip-semantic-smoke-experiment') 'Prompt/completion text leaked.'
    Check (@($report.cases|Where-Object {$_.promptSha256 -notmatch '^[0-9a-f]{64}$'}).Count -eq 0) 'Fixed case prompt hashes missing.'
    Reject {& $invoke $out $read $request $check} 'Existing report was overwritten.'
}finally{if(Test-Path $out){Remove-Item -LiteralPath $out -Force}}
$script:answers=@('13','{"name":"Ada","age":38}','ready');$script:requests=0
$out=TempPath
try{$report=& $invoke $out $read $request $check
    Check ($report.failed -eq 3 -and $report.status -eq 'semantic-failures') 'Wrong HIP answers were accepted.'
}finally{if(Test-Path $out){Remove-Item -LiteralPath $out -Force}}
$script:answers=@('12','{"name":"Ada","age":37}','READY');$script:requests=0
$badRequest={param($path,$body,$timeoutMs)
    $script:requests++
    if($script:requests -eq 2){return [pscustomobject]@{Status=500;Body='private response should not leak'}}
    return [pscustomobject]@{Status=200;Body=(@{choices=@(@{finish_reason='stop';message=@{role='assistant';content=$script:answers[$script:requests-1]}})}|ConvertTo-Json -Depth 8)}
}
$out=TempPath
try{$report=& $invoke $out $read $badRequest $check
    Check ($report.passed -eq 2 -and $report.inconclusive -eq 1 -and $report.cases[1].errorCode -eq 'http-status') 'HTTP failure was mislabeled semantic failure.'
    Check (-not ([IO.File]::ReadAllText($out)).Contains('private response')) 'HTTP error body leaked.'
}finally{if(Test-Path $out){Remove-Item -LiteralPath $out -Force}}
$script:requests=0
$changed={param($path,$body,$timeoutMs)
    $script:requests++
    $script:state.runId=('f'*32)
    return [pscustomobject]@{Status=200;Body='{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"12"}}]}'}
}
$out=TempPath
try{$report=& $invoke $out $read $changed $check
    Check ($report.aborted -and $report.cases.Count -eq 1 -and $report.cases[0].errorCode -eq 'identity-changed') 'Changed HIP run was not aborted.'
}finally{if(Test-Path $out){Remove-Item -LiteralPath $out -Force};$script:state.runId=('a'*32)}
$script:requests=0
$changedProcess={param($path,$body,$timeoutMs)
    $script:requests++;$script:state.processIdentity.pid=99999
    return [pscustomobject]@{Status=200;Body='{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"12"}}]}'}
}
$out=TempPath
try{$report=& $invoke $out $read $changedProcess $check
    Check ($report.aborted -and $report.cases[0].errorCode -eq 'identity-changed') 'Changed HIP process was not aborted.'
}finally{if(Test-Path $out){Remove-Item -LiteralPath $out -Force};$script:state.processIdentity.pid=23456}
$script:state.trialSourceSha256=('0'*64)
Reject {& $invoke (TempPath) $read $request $check} 'Wrong trial launch-source hash was accepted.'
$script:state.trialSourceSha256=$trialHash
$script:requests=0
$changedSource={param($path,$body,$timeoutMs)
    $script:requests++;$script:state.trialSourceSha256=('0'*64)
    return [pscustomobject]@{Status=200;Body='{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"12"}}]}'}
}
$out=TempPath
try{$report=& $invoke $out $read $changedSource $check
    Check ($report.aborted -and $report.cases.Count -eq 1 -and $report.cases[0].errorCode -eq 'identity-changed') 'Changed trial source binding was not aborted.'
}finally{if(Test-Path $out){Remove-Item -LiteralPath $out -Force};$script:state.trialSourceSha256=$trialHash}
Check ((Get-FileHash (Join-Path $root 'src/FastLlm.SemanticSmoke.ps1') -Algorithm SHA256).Hash.ToLowerInvariant() -match '^[0-9a-f]{64}$') 'Fixed semantic source dependency missing.'
Write-Host "$count HIP semantic smoke assertions passed. Mock requests only."
