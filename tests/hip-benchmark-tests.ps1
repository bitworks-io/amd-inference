#requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$source=Join-Path $root 'src/FastLlm.HipBenchmark.ps1'
$tokens=$null;$errors=$null
$null=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw 'HIP benchmark source has PowerShell parser errors.'}
Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force
$module=Get-Module FastLlm
$count=0
function Check($ok,$message){if(-not $ok){throw $message};$script:count++}
function Reject($action,$message){$threw=$false;try{& $action|Out-Null}catch{$threw=$true};Check $threw $message}
$state=[pscustomobject]@{
    active=$true;schemaVersion=1;kind='fastllm-hip-b1339-private-trial';phase='hip-lab-ready';endpoint='http://127.0.0.1:18081/v1'
    experimental=$true;performanceQualified=$false;physicalResidencyVerified=$false;dynamicClosureVerified=$false
    allowHostModelBuffer=$false;placementClassification='all-reported-layers-no-host-model-buffer'
    allWeightsOnGpuVerified=$false;allOperationsOnGpuVerified=$false;cpuInputEvidence='not-attested'
    runId=('a'*32);processIdentity=[pscustomobject]@{pid=23456;startUtcTicks=10000000}
    modelId='mock-qwen';modelSha256=('b'*64);engineVersion='lemonade-b1339-gfx110X';engineSha256=('c'*64);catalogSha256=('d'*64)
    trialSourceSha256=(Get-FileHash (Join-Path $root 'src/FastLlm.HipModelTrial.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()
    selectedDevice=[pscustomobject]@{device='ROCm0';name='AMD Radeon RX 7900 XTX';reportedFreeMiB=20000}
    recipe=[pscustomobject]@{backend='ROCm';device='ROCm0';contextSize=8192;slots=1;gpuLayers='all';fitMode='off';splitMode='none';allowHostModelBuffer=$false;
        cacheTypeK='f16';cacheTypeV='f16';speculation='none';flashAttention='auto';requestedArguments=@('--model','<verified-model>',
            '--alias','mock-qwen','--host','127.0.0.1','--port','18081','--ctx-size','8192','--parallel','1',
            '--device','ROCm0','--n-gpu-layers','all','--fit','off','--split-mode','none','--cache-type-k','f16','--cache-type-v','f16')}
    placement=[pscustomobject]@{reportedLayers=66;totalLayers=66;devices=@('ROCm0');reportedAllLayers=$true;
        modelBufferMiB=@([pscustomobject]@{device='ROCm0';sizeMiB=17000});physicalResidencyVerified=$false}
    placementEvidence=[pscustomobject]@{status='captured';cpuBufferLikeLines=0;cpuModelBufferRows=0;
        offloadRows=@([pscustomobject]@{reportedGpuLayers=66;reportedTotalLayers=66});
        modelBuffers=@([pscustomobject]@{device='ROCm0';sizeMiB=17000.0});physicalResidencyVerified=$false}
    startupDiagnostics=[pscustomobject]@{status='partial';physicalResidencyVerified=$false}
    canary=[pscustomobject]@{modelIdentity=$true;repeatableToken=$true;synchronousChat=$true;streaming=$true;
        effectiveContext=8192;semanticCorrectnessQualified=$false}
}
$script:fakeState=$state;$script:requestCount=0;$script:checkCount=0
$readState={return $script:fakeState}
$check={param($s) $script:checkCount++;if($s.processIdentity.pid -ne 23456){throw 'PID changed'}}
$request={param($path,$body,$timeoutMs)
    $script:requestCount++
    if($timeoutMs -le 0 -or $timeoutMs -gt $(if($path -eq '/completion'){180000}else{30000})){throw 'Unbounded timeout'}
    if($path -eq '/tokenize'){
        $phrase='A local inference system should produce accurate useful answers. Measure speed consistently while preserving model quality. '+[Environment]::NewLine
        if($body.content -cne ($phrase*258)){throw 'HIP corpus differs from the normal producer input.'}
        return [pscustomobject]@{Status=200;Body=(@{tokens=@(0..4999)}|ConvertTo-Json -Compress -Depth 4)}
    }
    if($path -ne '/completion' -or $body.prompt.Count -notin @(512,4096) -or $body.n_predict -ne 128 -or
       $body.cache_prompt -ne $false -or $body.temperature -ne 0){throw 'Wrong fixed HIP workload'}
    $n=$body.prompt.Count
    return [pscustomobject]@{Status=200;Events=@('{"content":"first"}',
        ('{"stop":true,"timings":{"prompt_n":'+$n+',"prompt_ms":100,"predicted_n":128,"predicted_ms":200}}'),'[DONE]');
        EventTimesMs=@(10,250,250);ElapsedMs=250}
}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('fastllm-hip-benchmark-'+[guid]::NewGuid().ToString('N'))
try{
    $out=Join-Path $temp 'hip.json'
    $report=& $module {param($S,$O,$R,$Q,$C) . $S;Invoke-FastLlmHipBenchmarkCore -OutputPath $O -ReadState $R -Request $Q -CheckProcess $C -CheckExecutable $C -DeadlineSeconds 60} $source $out $readState $request $check
    Check ($report.resultKind -eq 'native-windows-api-hip-lab-experiment' -and $report.qualification.approved -eq $false -and $report.qualification.privateHipExperiment) 'HIP report was not distinct and unqualified.'
    Check ($report.methodology.randomizedPromptOrder -eq $true -and $report.methodology.completionRequestTimeoutMs -eq 180000 -and $report.placementEvidence.cpuBufferLikeLines -eq 0) 'HIP methodology or actual startup placement diagnostics missing.'
    Check ($report.samples.Count -eq 10 -and $script:requestCount -eq 13 -and $script:checkCount -gt 12) 'Fixed HIP warmup/repetition/identity checks missing.'
    Check (@($report.summary|Select-Object -ExpandProperty requestedPromptTokens) -join ',' -eq '512,4096') 'HIP workload prompt groups changed.'
    Check (@($report.samples|Where-Object {$_.promptArtifactSha256 -notin @($report.methodology.promptArtifacts.sha256)}).Count -eq 0) 'Sample prompt digests were not bound.'
    Check ($report.sourceProvenance.hipTrialSha256 -eq (Get-FileHash (Join-Path $root 'src/FastLlm.HipModelTrial.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()) 'Exact HIP trial source hash missing.'
    Check ($report.sourceProvenance.strictResponseParserSha256 -eq (Get-FileHash (Join-Path $root 'src/FastLlm.OffloadBenchmark.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()) 'Strict response parser source hash missing.'
    $saved=Get-Content -LiteralPath $out -Raw
    Check ($saved -notmatch 'accurate useful answers|"first"' -and $saved -match 'native-windows-api-hip-lab-experiment') 'HIP output leaked text or lost private result kind.'
    $script:fakeState.allowHostModelBuffer=$true
    $script:fakeState.recipe.allowHostModelBuffer=$true
    $script:fakeState.placementClassification='all-reported-layers-with-host-model-buffer'
    $script:fakeState.placementEvidence.cpuBufferLikeLines=1
    $script:fakeState.placementEvidence.cpuModelBufferRows=1
    $script:fakeState.placementEvidence.modelBuffers+= [pscustomobject]@{device='CPU_Mapped';sizeMiB=682.03}
    $hostOutput=Join-Path $temp 'hip-host-buffer.json'
    $hostReport=& $module {param($S,$O,$R,$Q,$C) . $S;Invoke-FastLlmHipBenchmarkCore -OutputPath $O -ReadState $R -Request $Q -CheckProcess $C -CheckExecutable $C -DeadlineSeconds 60} $source $hostOutput $readState $request $check
    Check ($hostReport.placementClassification -eq 'all-reported-layers-with-host-model-buffer' -and
           $hostReport.reportedHostModelBufferRows -eq 1 -and $hostReport.reportedHostModelBufferMiB -eq 682.03 -and
           -not $hostReport.allWeightsOnGpuVerified -and -not $hostReport.allOperationsOnGpuVerified -and
           $hostReport.cpuInputEvidence -eq 'not-attested') 'Explicit host-buffer trial was hidden or overstated.'
    $script:fakeState.recipe.allowHostModelBuffer=$false
    Reject {& $module {param($S,$O,$R,$Q,$C) . $S;Invoke-FastLlmHipBenchmarkCore -OutputPath $O -ReadState $R -Request $Q -CheckProcess $C} $source (Join-Path $temp 'recipe-opt-in-mismatch.json') $readState $request $check} 'Recipe and top-level host-buffer opt-in disagreed.'
    $script:fakeState.recipe.allowHostModelBuffer=$true
    $script:fakeState.placementEvidence.modelBuffers=@($script:fakeState.placementEvidence.modelBuffers[1],$script:fakeState.placementEvidence.modelBuffers[0])
    $reversed=& $module {param($S,$O,$R,$Q,$C) . $S;Invoke-FastLlmHipBenchmarkCore -OutputPath $O -ReadState $R -Request $Q -CheckProcess $C -CheckExecutable $C -DeadlineSeconds 60} $source (Join-Path $temp 'hip-host-reordered.json') $readState $request $check
    Check ($reversed.reportedHostModelBufferMiB -eq 682.03) 'Valid CPU_Mapped/GPU row order changed the reported host MiB.'
    $script:fakeState.placementEvidence.modelBuffers=@($script:fakeState.placementEvidence.modelBuffers[1],$script:fakeState.placementEvidence.modelBuffers[0])
    $script:fakeState.placementEvidence.modelBuffers[1].device='CPU'
    Reject {& $module {param($S,$O,$R,$Q,$C) . $S;Invoke-FastLlmHipBenchmarkCore -OutputPath $O -ReadState $R -Request $Q -CheckProcess $C} $source (Join-Path $temp 'wrong-host-kind.json') $readState $request $check} 'Non-CPU_Mapped host row passed.'
    $script:fakeState.placementEvidence.modelBuffers[1].device='CPU_Mapped'
    $script:fakeState.placementEvidence.modelBuffers[1].sizeMiB='NaN'
    Reject {& $module {param($S,$O,$R,$Q,$C) . $S;Invoke-FastLlmHipBenchmarkCore -OutputPath $O -ReadState $R -Request $Q -CheckProcess $C} $source (Join-Path $temp 'malformed-host.json') $readState $request $check} 'Malformed host MiB passed.'
    $script:fakeState.placementEvidence.modelBuffers[1].sizeMiB=682.03
    $script:fakeState.placementEvidence.cpuBufferLikeLines=2
    Reject {& $module {param($S,$O,$R,$Q,$C) . $S;Invoke-FastLlmHipBenchmarkCore -OutputPath $O -ReadState $R -Request $Q -CheckProcess $C} $source (Join-Path $temp 'duplicate-host.json') $readState $request $check} 'Multiple host-like lines passed.'
    $script:fakeState.placementEvidence.cpuBufferLikeLines=1
    $script:fakeState.allowHostModelBuffer=$false
    Reject {& $module {param($S,$O,$R,$Q,$C) . $S;Invoke-FastLlmHipBenchmarkCore -OutputPath $O -ReadState $R -Request $Q -CheckProcess $C} $source (Join-Path $temp 'host-without-opt-in.json') $readState $request $check} 'Host buffer entered non-opt-in benchmark.'
    $script:fakeState.allowHostModelBuffer=$false
    $script:fakeState.recipe.allowHostModelBuffer=$false
    $script:fakeState.placementClassification='all-reported-layers-no-host-model-buffer'
    $script:fakeState.placementEvidence.cpuBufferLikeLines=0
    $script:fakeState.placementEvidence.cpuModelBufferRows=0
    $script:fakeState.placementEvidence.modelBuffers=@($script:fakeState.placementEvidence.modelBuffers[0])
    Reject {& $module {param($S,$O,$R,$Q,$C) . $S;Invoke-FastLlmHipBenchmarkCore -OutputPath $O -ReadState $R -Request $Q -CheckProcess $C -CheckExecutable $C} $source $out $readState $request $check} 'Existing HIP output was overwritten.'
    $script:fakeState.phase='ready'
    Reject {& $module {param($S,$O,$R,$Q,$C) . $S;Invoke-FastLlmHipBenchmarkCore -OutputPath $O -ReadState $R -Request $Q -CheckProcess $C} $source (Join-Path $temp 'normal.json') $readState $request $check} 'Normal ready state entered HIP report.'
    $script:fakeState.phase='hip-lab-ready';$script:fakeState.placement.reportedLayers=65
    Reject {& $module {param($S,$O,$R,$Q,$C) . $S;Invoke-FastLlmHipBenchmarkCore -OutputPath $O -ReadState $R -Request $Q -CheckProcess $C} $source (Join-Path $temp 'partial.json') $readState $request $check} 'Partial layer placement entered HIP report.'
    $script:fakeState.placement.reportedLayers=66
    $script:fakeState.trialSourceSha256='0'*64
    Reject {& $module {param($S,$O,$R,$Q,$C) . $S;Invoke-FastLlmHipBenchmarkCore -OutputPath $O -ReadState $R -Request $Q -CheckProcess $C} $source (Join-Path $temp 'wrong-trial-source.json') $readState $request $check} 'Trial launch-source mismatch was accepted.'
    $script:fakeState.trialSourceSha256=(Get-FileHash (Join-Path $root 'src/FastLlm.HipModelTrial.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()
    $script:mutation=0
    $mutate={param($path,$body,$timeoutMs)
        $answer=& $request $path $body $timeoutMs
        $script:mutation++
        if($script:mutation -eq 2){$script:fakeState.processIdentity.pid=99999}
        return $answer
    }
    Reject {& $module {param($S,$O,$R,$Q,$C) . $S;Invoke-FastLlmHipBenchmarkCore -OutputPath $O -ReadState $R -Request $Q -CheckProcess $C} $source (Join-Path $temp 'changed.json') $readState $mutate $check} 'Changed HIP child was accepted mid-measurement.'
    Check (-not (Test-Path -LiteralPath (Join-Path $temp 'changed.json'))) 'Changed HIP child produced a report.'
    $script:fakeState.processIdentity.pid=23456
    $script:mixedCountCalls=0
    $mixed={param($path,$body,$timeoutMs)
        $answer=& $request $path $body $timeoutMs
        if($path -eq '/completion' -and $body.prompt.Count -eq 512){
            $script:mixedCountCalls++
            if($script:mixedCountCalls -eq 2){$answer.Events[1]=$answer.Events[1].Replace('"prompt_n":512','"prompt_n":513')}
        }
        return $answer
    }
    Reject {& $module {param($S,$O,$R,$Q,$C) . $S;Invoke-FastLlmHipBenchmarkCore -OutputPath $O -ReadState $R -Request $Q -CheckProcess $C} $source (Join-Path $temp 'mixed.json') $readState $mixed $check} 'Warmup/measured prompt-count mismatch was accepted.'
    Check (-not (Test-Path -LiteralPath (Join-Path $temp 'mixed.json'))) 'Mixed HIP prompt-count run produced a report.'
    $bad=& $request '/completion' @{prompt=@(0..511);n_predict=128;cache_prompt=$false;temperature=0} 1000
    $bad.Events[1]=$bad.Events[1].Replace('"prompt_n":512','"prompt_n":512.5')
    Reject {& $module {param($R) ConvertFrom-FastLlmOffloadBenchmarkResponse -Response $R -ExpectedTokens 128} $bad} 'Fractional HIP prompt count passed.'
    $bad.Events[1]=$bad.Events[1].Replace('"prompt_n":512.5','"prompt_n":512').Replace('"stop":true','"stop":"false"')
    Reject {& $module {param($R) ConvertFrom-FastLlmOffloadBenchmarkResponse -Response $R -ExpectedTokens 128} $bad} 'String stop flag passed.'
    $text=Get-Content -LiteralPath $source -Raw
    Check ($text.Contains('GetLoopbackListenerOwners(18081)') -and $text.Contains('MainModule.FileName') -and -not $text.Contains('Invoke-FastLlmBenchmark -')) 'Live HIP listener/executable boundary missing.'
    Check ((Get-FileHash (Join-Path $root 'src/FastLlm.Benchmark.ps1') -Algorithm SHA256).Hash.ToLowerInvariant() -eq 'c8b64fe0a2e78e3974b63a127da9ae385ca84b51fba69505ee323ab5d464a43b') 'Normal benchmark producer changed.'
}finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}}
Write-Host "HIP private benchmark checks passed: $count. Mock requests only; no GPU benchmark executed."
