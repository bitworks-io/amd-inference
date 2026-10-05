#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Split-Path $PSScriptRoot -Parent
$source=Join-Path $root 'src/FastLlm.HipSoak.ps1'
$tokens=$null;$errors=$null
$null=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw 'HIP soak source has parser errors.'}
$module=Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force -PassThru
$count=0
function Check($ok,$message){if(-not $ok){throw $message};$script:count++}
function TempPath {Join-Path ([IO.Path]::GetTempPath()) ('fastllm-hip-soak-'+[Guid]::NewGuid().ToString('N')+'.json')}
$trialHash=(Get-FileHash (Join-Path $root 'src/FastLlm.HipModelTrial.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()
$script:state=[pscustomobject]@{
    schemaVersion=1;active=$true;kind='fastllm-hip-b1339-private-trial';phase='hip-lab-ready'
    endpoint='http://127.0.0.1:18081/v1';runId=('a'*32);experimental=$true
    modelId='qwen-test';modelSha256=('b'*64);engineVersion='lemonade-b1339-gfx110X'
    engineSha256=('c'*64);catalogSha256=('d'*64);trialSourceSha256=$trialHash
    processIdentity=[pscustomobject]@{pid=23456;startUtcTicks=638000000000000000}
    selectedDevice=[pscustomobject]@{device='ROCm0';name='AMD Radeon';reportedFreeMiB=20000}
    allowHostModelBuffer=$true;placementClassification='all-reported-layers-with-host-model-buffer'
    allWeightsOnGpuVerified=$false;allOperationsOnGpuVerified=$false;cpuInputEvidence='not-attested'
    performanceQualified=$false;physicalResidencyVerified=$false;dynamicClosureVerified=$false
    recipe=[pscustomobject]@{backend='ROCm';device='ROCm0';contextSize=8192;slots=1;gpuLayers='all';fitMode='off'
        splitMode='none';cacheTypeK='f16';cacheTypeV='f16';speculation='none';flashAttention='auto';allowHostModelBuffer=$true
        requestedArguments=@('--model','<verified-model>','--alias','qwen-test','--host','127.0.0.1','--port','18081',
            '--ctx-size','8192','--parallel','1','--device','ROCm0','--n-gpu-layers','all','--fit','off',
            '--split-mode','none','--cache-type-k','f16','--cache-type-v','f16')}
    placement=[pscustomobject]@{reportedLayers=66;totalLayers=66;reportedAllLayers=$true;devices=@('ROCm0')
        modelBufferMiB=@([pscustomobject]@{device='ROCm0';sizeMiB=14674.45});physicalResidencyVerified=$false}
    placementEvidence=[pscustomobject]@{status='captured';cpuBufferLikeLines=1;cpuModelBufferRows=1
        offloadRows=@([pscustomobject]@{reportedGpuLayers=66;reportedTotalLayers=66})
        modelBuffers=@([pscustomobject]@{device='ROCm0';sizeMiB=14674.45},[pscustomobject]@{device='CPU_Mapped';sizeMiB=682.03})
        physicalResidencyVerified=$false}
    startupDiagnostics=[pscustomobject]@{status='captured';physicalResidencyVerified=$false}
    canary=[pscustomobject]@{modelIdentity=$true;repeatableToken=$true;synchronousChat=$true;streaming=$true
        effectiveContext=8192;semanticCorrectnessQualified=$false}
}
$script:elapsed=0.0;$script:checks=0;$script:canaries=0
$read={return $script:state}
$check={param($s) $script:checks++;if($s.processIdentity.pid -ne 23456){throw 'PID changed'}}
$clock={return $script:elapsed}
$pause={$script:elapsed+=0.01}
$canary={param($s) $script:canaries++;$script:elapsed+=1.0;return [pscustomobject]@{
    modelIdentity=$true;repeatableToken=$true;synchronousChat=$true;streaming=$true
    effectiveContext=$s.recipe.contextSize;semanticCorrectnessQualified=$false}}
$invoke={param($Output,$Read,$CheckProcess,$Canary,$Cycles,$Duration,$Max)
    & $module {param($BenchmarkSource,$S,$O,$Run,$R,$C,$A,$N,$D,$M,$Clock,$Pause)
        . $BenchmarkSource;. $S
        Invoke-FastLlmHipSoakCore -OutputPath $O -RunId $Run -ReadState $R -CheckProcess $C -Canary $A `
            -MinimumCycles $N -DurationSeconds $D -MaximumSeconds $M -GetElapsed $Clock -Pause $Pause
    } (Join-Path $root 'src/FastLlm.HipBenchmark.ps1') $source $Output ('a'*32) $Read $CheckProcess $Canary $Cycles $Duration $Max $clock $pause
}
$out=TempPath
try{
    $report=& $invoke $out $read $check $canary 3 2 10
    Check (-not $report.outcome.completed -and $report.outcome.diagnosticFinished -and $report.outcome.completedCycles -eq 3 -and
           $report.outcome.status -eq 'short-diagnostic-only') 'Short injected test was mislabeled as a 2-hour soak.'
    Check ($script:canaries -eq 3 -and $script:checks -ge 8) 'Pre/post live identity checks missing.'
    Check ($report.allowHostModelBuffer -and $report.placementClassification -eq 'all-reported-layers-with-host-model-buffer' -and
           -not $report.allWeightsOnGpuVerified -and -not $report.allOperationsOnGpuVerified -and
           $report.cpuInputEvidence -eq 'not-attested') 'Host-buffer caveat was omitted.'
    Check (-not $report.qualification.approved -and -not $report.qualification.soakQualified -and
           -not $report.qualification.exclusiveWorkloadConfirmed) 'Private soak claimed qualification.'
    Check (-not $report.methodology.completionGateRequires100CyclesAnd2Hours -and
           $report.methodology.inferenceRequestsPerCycle -eq 4 -and $report.methodology.httpRequestsPerCycle -eq 6) 'Short injected diagnostic claimed production gate or wrong request count.'
    $saved=[IO.File]::ReadAllText($out)
    Check ($saved -notmatch 'The capital of France|Say hello|secret answer|private exception' -and
           $saved -match 'native-windows-hip-private-soak-experiment') 'Private prompt, response, or exception leaked.'
    $before=(Get-FileHash $out -Algorithm SHA256).Hash
    $threw=$false;try{& $invoke $out $read $check $canary 1 0 10|Out-Null}catch{$threw=$true}
    Check ($threw -and (Get-FileHash $out -Algorithm SHA256).Hash -eq $before) 'Existing private report was overwritten.'
}finally{if(Test-Path $out){Remove-Item -LiteralPath $out -Force}}

$script:canaries=0
$missing=Join-Path (Join-Path ([IO.Path]::GetTempPath()) ('fastllm-missing-'+[Guid]::NewGuid().ToString('N'))) 'soak.json'
$threw=$false
try{& $invoke $missing $read $check $canary 1 0 10|Out-Null}catch{$threw=$true}
Check ($threw -and $script:canaries -eq 0 -and -not (Test-Path $missing)) 'Missing output parent was not rejected before canary.'

$script:elapsed=0.0;$script:canaries=0
$badRequest={param($s) $script:canaries++;throw 'private exception and secret answer'}
$out=TempPath
try{
    $report=& $invoke $out $read $check $badRequest 2 2 10
    Check (-not $report.outcome.completed -and $report.outcome.failureCode -eq 'identity-source-process-or-canary-failed' -and
           $report.outcome.completedCycles -eq 0) 'Request failure was accepted.'
    Check (-not ([IO.File]::ReadAllText($out)).Contains('private exception')) 'Exception leaked to failure report.'
}finally{if(Test-Path $out){Remove-Item -LiteralPath $out -Force}}

$script:elapsed=0.0;$script:canaries=0
$changed={param($s) $script:canaries++;$script:state.processIdentity.pid=99999;$script:elapsed+=1;return [pscustomobject]@{
    modelIdentity=$true;repeatableToken=$true;synchronousChat=$true;streaming=$true
    effectiveContext=8192;semanticCorrectnessQualified=$false}}
$out=TempPath
try{
    $report=& $invoke $out $read $check $changed 2 2 10
    Check (-not $report.outcome.completed -and $report.outcome.completedCycles -eq 0 -and
           $report.processIdentity.pid -eq 23456) 'Changed child PID was accepted or rewrote initial evidence.'
}finally{if(Test-Path $out){Remove-Item -LiteralPath $out -Force};$script:state.processIdentity.pid=23456}

$script:elapsed=0.0;$script:canaries=0
$slow={param($s) $script:canaries++;$script:elapsed=11;return [pscustomobject]@{
    modelIdentity=$true;repeatableToken=$true;synchronousChat=$true;streaming=$true
    effectiveContext=8192;semanticCorrectnessQualified=$false}}
$out=TempPath
try{
    $report=& $invoke $out $read $check $slow 2 2 10
    Check (-not $report.outcome.completed -and $report.outcome.failureCode -eq 'elapsed-deadline') 'Elapsed overrun was accepted.'
}finally{if(Test-Path $out){Remove-Item -LiteralPath $out -Force}}

$script:elapsed=0.0;$script:canaries=0
$productionClockCanary={param($s) $script:canaries++;$script:elapsed+=72.0;return [pscustomobject]@{
    modelIdentity=$true;repeatableToken=$true;synchronousChat=$true;streaming=$true
    effectiveContext=8192;semanticCorrectnessQualified=$false}}
$out=TempPath
try{
    $report=& $invoke $out $read $check $productionClockCanary 100 7200 10800
    Check ($report.outcome.completed -and $report.outcome.status -eq 'private-soak-completed' -and
           $report.outcome.completedCycles -eq 100 -and $report.outcome.elapsedSeconds -ge 7200 -and
           $report.methodology.completionGateRequires100CyclesAnd2Hours) '100-cycle/2-hour gate was not enforced.'
}finally{if(Test-Path $out){Remove-Item -LiteralPath $out -Force}}

$tool=[IO.File]::ReadAllText((Join-Path $root 'tools/hip-soak.ps1'))
$code=[IO.File]::ReadAllText($source)
Check ($code.Contains("'hip-benchmark.lock'") -and $code.Contains('-HashExecutable') -and
       $code.Contains('-MinimumCycles 100 -DurationSeconds 7200 -MaximumSeconds 10800')) 'Production lock or minimum soak gate missing.'
Check ($tool.Contains('Invoke-FastLlmHipSoak') -and -not $tool.Contains('Stop-FastLlm')) 'HIP tool does not invoke isolated soak.'
$lockRoot=Join-Path ([IO.Path]::GetTempPath()) ('fastllm-hip-lock-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $lockRoot -ErrorAction Stop|Out-Null
try{
    $firstLock=& $module {param($Source,$StateRoot) . $Source;Enter-FastLlmHipSoakLock -StateRoot $StateRoot} $source $lockRoot
    try{
        $contended=$false
        try{& $module {param($Source,$StateRoot) . $Source;Enter-FastLlmHipSoakLock -StateRoot $StateRoot} $source $lockRoot|Out-Null}
        catch{$contended=$true}
        Check $contended 'Shared HIP lock allowed concurrent acquisition.'
    }finally{$firstLock.Dispose()}
    $released=& $module {param($Source,$StateRoot) . $Source;Enter-FastLlmHipSoakLock -StateRoot $StateRoot} $source $lockRoot
    try{Check ($null -ne $released) 'Shared HIP lock remained held after release.'}finally{$released.Dispose()}
}finally{Remove-Item -LiteralPath $lockRoot -Recurse -Force}
Write-Host "HIP private soak assertions passed: $count. Injected canaries only; no GPU soak executed."
