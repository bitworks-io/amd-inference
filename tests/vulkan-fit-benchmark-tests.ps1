#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $root 'src/FastLlm.psm1') -PassThru -ErrorAction Stop
$trial=Join-Path $root 'src/FastLlm.VulkanFitTrial.ps1'
$benchmark=Join-Path $root 'src/FastLlm.VulkanFitBenchmark.ps1'
$count=0
function Check([bool]$ok,[string]$message){if(-not $ok){throw $message};$script:count++}
function Reject([scriptblock]$action,[string]$message){$failed=$false;try{& $action | Out-Null}catch{$failed=$true};Check $failed $message}
$argv=& $module {param($t) . $t;New-FastLlmVulkanFitArguments -ModelPath '<verified-model>' -ModelId 'qwen3.8-27b-ud-q4-k-m' -FitMode on} $trial
$state=[pscustomobject]@{
    active=$true;schemaVersion=1;kind='fastllm-vulkan-fit-b10698-private-trial';phase='vulkan-fit-ready';endpoint='http://127.0.0.1:18083/v1'
    experimental=$true;performanceQualified=$false;physicalResidencyVerified=$false;dynamicClosureVerified=$false;semanticCorrectnessQualified=$false
    allowHostModelBuffer=$false;placementClassification='all-reported-layers-no-host-model-buffer'
    allWeightsOnGpuVerified=$false;allOperationsOnGpuVerified=$false;cpuInputEvidence='not-attested'
    runId=('a'*32);processIdentity=[pscustomobject]@{pid=23456;startUtcTicks=10000000}
    modelId='qwen3.8-27b-ud-q4-k-m';modelSha256='322e194ff79741c7baa497c240f677f54b201b0efab44ca8e50f122b39123482'
    engineVersion='b10698';engineSha256=('c'*64);catalogSha256=('d'*64)
    trialSourceSha256=(Get-FileHash -LiteralPath $trial -Algorithm SHA256).Hash.ToLowerInvariant()
    selectedDevice=[pscustomobject]@{device='Vulkan0';name='AMD Radeon RX 7900 XTX';reportedFreeMiB=20000}
    recipe=[pscustomobject]@{backend='Vulkan';device='Vulkan0';contextSize=32768;slots=1;gpuLayers='all';fitMode='on';fitTargetMiB=768;
        splitMode='none';allowHostModelBuffer=$false;cacheTypeK='f16';cacheTypeV='f16';speculation='none';flashAttention='auto';requestedArguments=@($argv)}
    placement=[pscustomobject]@{reportedLayers=66;totalLayers=66;devices=@('Vulkan0');reportedAllLayers=$true;
        modelBufferMiB=@([pscustomobject]@{device='Vulkan0';sizeMiB=15000.0});physicalResidencyVerified=$false}
    placementEvidence=[pscustomobject]@{status='captured';reportedGpuLayers=66;reportedTotalLayers=66;
        gpuModelBuffer=[pscustomobject]@{device='Vulkan0';sizeMiB=15000.0};hostModelBuffer=$null;
        classification='all-reported-layers-no-host-model-buffer';
        physicalResidencyVerified=$false;allWeightsOnGpuVerified=$false;allOperationsOnGpuVerified=$false}
    placementCounters=[pscustomobject]@{offloadLike=1;bufferLike=1;captured=2;dropped=0}
    startupDiagnostics=[pscustomobject]@{status='partial';physicalResidencyVerified=$false}
    canary=[pscustomobject]@{modelIdentity=$true;repeatableToken=$true;synchronousChat=$true;streaming=$true;
        effectiveContext=32768;semanticCorrectnessQualified=$false}
}
$script:fakeState=$state;$script:requestCount=0;$script:checkCount=0
$readState={return $script:fakeState}
$check={param($s) $script:checkCount++;if($s.processIdentity.pid -ne 23456){throw 'PID changed'}}
$request={param($path,$body,$timeoutMs)
    $script:requestCount++
    if($timeoutMs -le 0 -or $timeoutMs -gt $(if($path -eq '/completion'){180000}else{30000})){throw 'Unbounded request deadline.'}
    if($path -eq '/tokenize'){
        $phrase='A local inference system should produce accurate useful answers. Measure speed consistently while preserving model quality. '+[Environment]::NewLine
        if($body.content -cne ($phrase*258)){throw 'Fixed benchmark corpus changed.'}
        return [pscustomobject]@{Status=200;Body=(@{tokens=@(0..4999)}|ConvertTo-Json -Compress -Depth 4)}
    }
    if($path -ne '/completion' -or $body.prompt.Count -notin @(512,4096) -or $body.n_predict -ne 128 -or
       $body.cache_prompt -ne $false -or $body.temperature -ne 0 -or -not $body.stream){throw 'Wrong fixed benchmark workload.'}
    $n=$body.prompt.Count
    return [pscustomobject]@{Status=200;Events=@('{"content":"first"}',
        ('{"stop":true,"timings":{"prompt_n":'+$n+',"prompt_ms":100,"predicted_n":128,"predicted_ms":200}}'),'[DONE]');
        EventTimesMs=@(10,250,250);ElapsedMs=250}
}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('fastllm-vulkan-fit-benchmark-'+[guid]::NewGuid().ToString('N'))
try{
    $out=Join-Path $temp 'fit-on.json'
    $report=& $module {param($T,$B,$O,$R,$Q,$C) . $T;. $B;Invoke-FastLlmVulkanFitBenchmarkCore -OutputPath $O -ReadState $R -Request $Q -CheckProcess $C -CheckExecutable $C -DeadlineSeconds 60} $trial $benchmark $out $readState $request $check
    Check ($report.resultKind -ceq 'native-windows-api-vulkan-fit-lab-experiment' -and -not $report.qualification.approved -and $report.qualification.privateVulkanFitExperiment) 'Distinct unqualified result kind missing.'
    Check ($report.samples.Count -eq 10 -and $script:requestCount -eq 13 -and $script:checkCount -gt 12) 'Fixed warmup/repetition or identity checks missing.'
    Check (($report.summary.requestedPromptTokens -join ',') -ceq '512,4096' -and $report.recipe.fitMode -ceq 'on') 'Prompt groups or fit mode changed.'
    Check (-not $report.methodology.randomizedPromptOrder -and @($report.methodology.promptOrderByRound).Count -eq 6 -and
           ($report.methodology.promptOrderByRound[0] -join ',') -ceq '512,4096' -and
           ($report.methodology.promptOrderByRound[1] -join ',') -ceq '4096,512') 'Fixed balanced A/B prompt order missing.'
    Check (@($report.samples|Where-Object {$_.promptArtifactSha256 -notin @($report.methodology.promptArtifacts.sha256)}).Count -eq 0) 'Prompt digests not bound.'
    Check ($report.sourceProvenance.vulkanFitTrialSha256 -ceq (Get-FileHash -LiteralPath $trial -Algorithm SHA256).Hash.ToLowerInvariant()) 'Trial source hash absent.'
    $saved=Get-Content -LiteralPath $out -Raw
    Check ($saved -notmatch 'accurate useful answers|"first"' -and $saved -match 'native-windows-api-vulkan-fit-lab-experiment') 'Raw text leaked into benchmark.'
    $script:fakeState.allowHostModelBuffer=$true;$script:fakeState.recipe.allowHostModelBuffer=$true
    $script:fakeState.placementClassification='all-reported-layers-with-host-model-buffer'
    $script:fakeState.placementEvidence.classification='all-reported-layers-with-host-model-buffer'
    $script:fakeState.placementEvidence.hostModelBuffer=[pscustomobject]@{device='CPU_Mapped';sizeMiB=682.03}
    $script:fakeState.placementCounters.bufferLike=2;$script:fakeState.placementCounters.captured=3
    $hostReport=& $module {param($T,$B,$O,$R,$Q,$C) . $T;. $B;Invoke-FastLlmVulkanFitBenchmarkCore -OutputPath $O -ReadState $R -Request $Q -CheckProcess $C -CheckExecutable $C -DeadlineSeconds 60} $trial $benchmark (Join-Path $temp 'host.json') $readState $request $check
    Check ($hostReport.reportedHostModelBufferRows -eq 1 -and $hostReport.reportedHostModelBufferMiB -eq 682.03 -and -not $hostReport.allWeightsOnGpuVerified) 'Host buffer hidden or overstated.'
    $script:fakeState.recipe.allowHostModelBuffer=$false
    Reject {& $module {param($T,$B,$S) . $T;. $B;Assert-FastLlmVulkanFitBenchmarkState $S} $trial $benchmark $script:fakeState} 'Host opt-in mismatch accepted.'
    $script:fakeState.recipe.allowHostModelBuffer=$true;$script:fakeState.placementEvidence.hostModelBuffer.device='CPU'
    Reject {& $module {param($T,$B,$S) . $T;. $B;Assert-FastLlmVulkanFitBenchmarkState $S} $trial $benchmark $script:fakeState} 'Nonmapped CPU buffer accepted.'
    $script:fakeState.placementEvidence.hostModelBuffer.device='CPU_Mapped';$script:fakeState.placementEvidence.hostModelBuffer.sizeMiB='NaN'
    Reject {& $module {param($T,$B,$S) . $T;. $B;Assert-FastLlmVulkanFitBenchmarkState $S} $trial $benchmark $script:fakeState} 'Malformed host size accepted.'
    $script:fakeState.placementEvidence.hostModelBuffer.sizeMiB=1024.01
    Reject {& $module {param($T,$B,$S) . $T;. $B;Assert-FastLlmVulkanFitBenchmarkState $S} $trial $benchmark $script:fakeState} 'Above-cap host buffer accepted.'
    $script:fakeState.placementEvidence.hostModelBuffer.sizeMiB=682.03;$script:fakeState.placementCounters.bufferLike=3
    Reject {& $module {param($T,$B,$S) . $T;. $B;Assert-FastLlmVulkanFitBenchmarkState $S} $trial $benchmark $script:fakeState} 'Unrecognized model buffer counter accepted.'
    $script:fakeState.placementCounters.bufferLike=2
    $script:fakeState.placementEvidence.classification='all-reported-layers-no-host-model-buffer'
    Reject {& $module {param($T,$B,$S) . $T;. $B;Assert-FastLlmVulkanFitBenchmarkState $S} $trial $benchmark $script:fakeState} 'Contradictory placement classification accepted.'
    $script:fakeState.placementEvidence.classification='all-reported-layers-with-host-model-buffer'
    $script:fakeState.placement.modelBufferMiB[0].sizeMiB='NaN';$script:fakeState.placementEvidence.gpuModelBuffer.sizeMiB='NaN'
    Reject {& $module {param($T,$B,$S) . $T;. $B;Assert-FastLlmVulkanFitBenchmarkState $S} $trial $benchmark $script:fakeState} 'Nonfinite GPU buffer accepted.'
    $script:fakeState.placement.modelBufferMiB[0].sizeMiB=15000.0;$script:fakeState.placementEvidence.gpuModelBuffer.sizeMiB=15000.0
    $script:fakeState.placementEvidence.hostModelBuffer.sizeMiB=682.03;$script:fakeState.phase='ready'
    Reject {& $module {param($T,$B,$S) . $T;. $B;Assert-FastLlmVulkanFitBenchmarkState $S} $trial $benchmark $script:fakeState} 'Normal Ready state accepted.'
    $script:fakeState.phase='vulkan-fit-ready';$script:fakeState.recipe.requestedArguments[($script:fakeState.recipe.requestedArguments.IndexOf('--fit')+1)]='off'
    Reject {& $module {param($T,$B,$S) . $T;. $B;Assert-FastLlmVulkanFitBenchmarkState $S} $trial $benchmark $script:fakeState} 'Altered fit argument accepted.'
}finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}}
"Vulkan fit benchmark checks: $count passed"
