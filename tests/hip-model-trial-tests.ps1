#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $root 'src/FastLlm.psm1') -PassThru -ErrorAction Stop
$trial=Join-Path $root 'src/FastLlm.HipModelTrial.ps1'
$probe=Join-Path $root 'src/FastLlm.HipCandidateProbe.ps1'
$catalog=Join-Path $root 'config/catalog.json'
$checks=0
function Check([bool]$condition,[string]$message){if(-not $condition){throw $message};$script:checks++}
& $module {param($trialPath,$probePath,$catalogPath)
    . $probePath
    . $trialPath
    $sourceSha=Get-FastLlmHipTrialSourceSha256
    if($sourceSha -cne (Get-FileHash -LiteralPath $trialPath -Algorithm SHA256).Hash.ToLowerInvariant()){
        throw 'HIP trial launch source digest does not match actual source file.'
    }
    $entry=Get-FastLlmHipTrialCatalogModel -CatalogPath $catalogPath -ModelId 'qwen3.8-27b-ud-q4-k-m'
    if($entry.model.id -cne 'qwen3.8-27b-ud-q4-k-m' -or [int]$entry.model.contextSize -ne 32768){throw 'Exact Qwen3.8 27B model/context failed under module scope.'}
    $bad=$false
    try{Get-FastLlmHipTrialCatalogModel -CatalogPath $catalogPath -ModelId 'qwen3.5-9b-q4-k-m'|Out-Null}catch{$bad=$true}
    if(-not $bad){throw 'Non-Qwen3.8 artifact accepted by HIP trial.'}
    $all=@('--model','--offline','--no-mmproj','--spec-type','--alias','--host','--port','--cors-origins',
        '--no-cors-credentials','--ctx-size','--parallel','--n-gpu-layers','--fit','--device','--split-mode',
        '--flash-attn','--cache-type-k','--cache-type-v','--jinja','--metrics','--log-verbosity','--no-agent','--no-ui')
    Assert-FastLlmHipTrialHelpFlags -HelpText ($all -join "`n")
    $bad=$false
    try{Assert-FastLlmHipTrialHelpFlags -HelpText (($all | Where-Object {$_ -ne '--fit'}) -join "`n")}catch{$bad=$true}
    if(-not $bad){throw 'Unsupported launch flag was not rejected.'}
    $device='ROCm0: AMD Radeon RX 7900 XTX (24576 MiB, 22000 MiB free)'
    $adapter=ConvertFrom-FastLlmHipTrialDeviceList -Text $device -Device 'ROCm0'
    if($adapter.device -cne 'ROCm0' -or [long]$adapter.freeVramMiB -ne 22000){throw 'Pinned ROCm device parse failed.'}
    $bad=$false
    try{ConvertFrom-FastLlmHipTrialDeviceList -Text 'ERROR ROCm0 failed' -Device 'ROCm0'|Out-Null}catch{$bad=$true}
    if(-not $bad){throw 'Diagnostic text was accepted as device.'}
    $placement=ConvertFrom-FastLlmPlacementLog -Text "load_tensors: offloaded 66/66 layers to GPU`nload_tensors: ROCm0 model buffer size = 12000.00 MiB" -Devices @('ROCm0')
    if($placement.reportedLayers -ne 66 -or $placement.modelBufferMiB.Count -ne 1){throw 'Existing strict full-GPU parser failed ROCm evidence.'}
    $normalized="load_tensors: offloaded 66/66 layers to GPU`nload_tensors: ROCm0 model buffer size = 12000.00 MiB`nload_tensors: CPU_Mapped model buffer size = 245.25 MiB"
    $evidence=ConvertFrom-FastLlmHipTrialPlacementEvidence -Text $normalized -CpuBufferLikeLines 1 -Overflow $false
    if($evidence.status -ne 'captured' -or $evidence.offloadRows[0].reportedGpuLayers -ne 66 -or
       $evidence.cpuModelBufferRows -ne 1 -or $evidence.modelBuffers[1].sizeMiB -ne 245.25){
        throw 'HIP failure evidence lost bounded numeric CPU/model-buffer details.'
    }
    $fake=[ordered]@{placement=$null;failureCode=$null;placementEvidence=$evidence;placementClassification=$null}
    $rejected=$false
    try{Assert-FastLlmHipTrialPlacementGate -State $fake -Placement $placement -Evidence $evidence -CpuBufferLikeLines 1 -ModelBytes 1GB}catch{$rejected=$true}
    if(-not $rejected -or $fake.failureCode -cne 'cpu-model-buffer-observed' -or
       $null -eq $fake.placement -or $fake.placement.reportedLayers -ne 66 -or
       $fake.placementEvidence.cpuModelBufferRows -ne 1){
        throw 'Strict CPU-buffer gate did not preserve placement evidence before rejecting.'
    }
    $allowed=[ordered]@{placement=$null;failureCode=$null;placementClassification=$null}
    Assert-FastLlmHipTrialPlacementGate -State $allowed -Placement $placement -Evidence $evidence -CpuBufferLikeLines 1 -ModelBytes 1GB -AllowHostModelBuffer $true
    if($allowed.placementClassification -cne 'all-reported-layers-with-host-model-buffer' -or $allowed.failureCode){
        throw 'Exact positive CPU_Mapped model-buffer opt-in was not classified correctly.'
    }
    $noHost=ConvertFrom-FastLlmHipTrialPlacementEvidence -Text "load_tensors: offloaded 66/66 layers to GPU`nload_tensors: ROCm0 model buffer size = 12000.00 MiB" -CpuBufferLikeLines 0 -Overflow $false
    $strict=[ordered]@{placement=$null;failureCode=$null;placementClassification=$null}
    Assert-FastLlmHipTrialPlacementGate -State $strict -Placement $placement -Evidence $noHost -CpuBufferLikeLines 0 -ModelBytes 1GB
    if($strict.placementClassification -cne 'all-reported-layers-no-host-model-buffer'){throw 'Default zero-host classification changed.'}
    $badCpu=ConvertFrom-FastLlmHipTrialPlacementEvidence -Text ($normalized.Replace('CPU_Mapped','CPU')) -CpuBufferLikeLines 1 -Overflow $false
    $fake=[ordered]@{placement=$null;failureCode=$null;placementClassification=$null}
    $rejected=$false
    try{Assert-FastLlmHipTrialPlacementGate -State $fake -Placement $placement -Evidence $badCpu -CpuBufferLikeLines 1 -ModelBytes 1GB -AllowHostModelBuffer $true}catch{$rejected=$true}
    if(-not $rejected -or $fake.failureCode -cne 'host-model-buffer-evidence-invalid'){throw 'Non-mapped CPU buffer was accepted.'}
    $fake=[ordered]@{placement=$null;failureCode=$null;placementClassification=$null}
    $rejected=$false
    try{Assert-FastLlmHipTrialPlacementGate -State $fake -Placement $placement -Evidence $evidence -CpuBufferLikeLines 1 -ModelBytes 200MB -AllowHostModelBuffer $true}catch{$rejected=$true}
    if(-not $rejected -or $fake.failureCode -cne 'host-model-buffer-evidence-invalid'){throw 'Host buffer larger than exact model file was accepted.'}
    $duplicate=ConvertFrom-FastLlmHipTrialPlacementEvidence -Text ($normalized+"`nload_tensors: CPU_Mapped model buffer size = 1.00 MiB") -CpuBufferLikeLines 2 -Overflow $false
    $fake=[ordered]@{placement=$null;failureCode=$null;placementClassification=$null}
    $rejected=$false
    try{Assert-FastLlmHipTrialPlacementGate -State $fake -Placement $placement -Evidence $duplicate -CpuBufferLikeLines 2 -ModelBytes 1GB -AllowHostModelBuffer $true}catch{$rejected=$true}
    if(-not $rejected -or $fake.failureCode -cne 'host-model-buffer-evidence-invalid'){throw 'Duplicate host buffer was accepted.'}
    $malformed=ConvertFrom-FastLlmHipTrialPlacementEvidence -Text ($normalized.Replace('245.25 MiB','not-a-number MiB')) -CpuBufferLikeLines 1 -Overflow $false
    $fake=[ordered]@{placement=$null;failureCode=$null;placementClassification=$null}
    $rejected=$false
    try{Assert-FastLlmHipTrialPlacementGate -State $fake -Placement $placement -Evidence $malformed -CpuBufferLikeLines 1 -ModelBytes 1GB -AllowHostModelBuffer $true}catch{$rejected=$true}
    if(-not $rejected -or $fake.failureCode -cne 'placement-evidence-inconsistent'){throw 'Malformed host buffer evidence was accepted.'}
    $extra=ConvertFrom-FastLlmHipTrialPlacementEvidence -Text ($normalized+"`nload_tensors: Vulkan0 model buffer size = 1.00 MiB") -CpuBufferLikeLines 1 -Overflow $false
    $fake=[ordered]@{placement=$null;failureCode=$null;placementClassification=$null}
    $rejected=$false
    try{Assert-FastLlmHipTrialPlacementGate -State $fake -Placement $placement -Evidence $extra -CpuBufferLikeLines 1 -ModelBytes 1GB -AllowHostModelBuffer $true}catch{$rejected=$true}
    if(-not $rejected -or $fake.failureCode -cne 'placement-evidence-inconsistent'){throw 'Extra model-buffer evidence was accepted.'}
    $rejected=$false
    try{ConvertFrom-FastLlmPlacementLog -Text "load_tensors: offloaded 65/66 layers to GPU`nload_tensors: ROCm0 model buffer size = 12000.00 MiB" -Devices @('ROCm0')|Out-Null}catch{$rejected=$true}
    if(-not $rejected){throw 'Partial GPU-layer placement was accepted.'}
    $wrong=[pscustomobject]@{reportedLayers=65;totalLayers=65}
    $fake=[ordered]@{placement=$null;failureCode=$null}
    $rejected=$false
    try{Assert-FastLlmHipTrialPlacementGate -State $fake -Placement $wrong -Evidence $noHost -CpuBufferLikeLines 0 -ModelBytes 1GB}catch{$rejected=$true}
    if(-not $rejected -or $fake.failureCode -cne 'placement-layer-count-mismatch' -or
       $fake.placement.reportedLayers -ne 65){throw 'Layer-count gate relaxed or dropped numeric evidence.'}
    $temp=Join-Path ([IO.Path]::GetTempPath()) ('fastllm-hip-self-lock-'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp -ErrorAction Stop|Out-Null
    try{
        Write-FastLlmState -InstallRoot $temp -State ([ordered]@{schemaVersion=1;phase='stopped';runId='test'})
        Assert-FastLlmHipNormalServiceStopped -ArtifactRoot $temp
        $lock=Enter-FastLlmOperation $temp
        try{
            $seen=Get-FastLlmStatus -InstallRoot $temp
            if(-not $seen.active){throw 'Test did not reproduce own-lock active status.'}
        }finally{$lock.Dispose()}
    }finally{Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}
} $trial $probe $catalog
$checks+=19
$text=Get-Content -LiteralPath $trial -Raw
Check ($text.Contains("kind='fastllm-hip-b1339-private-trial'") -and $text.Contains("phase='hip-lab-ready'")) 'Distinct HIP state kind/phase required.'
Check ($text.Contains("'--port','18081'") -and $text.Contains("'--n-gpu-layers','all'") -and $text.Contains("'--fit','off'")) 'Explicit loopback port/full GPU/fit-off recipe required.'
Check ($text.Contains('Assert-FastLlmHipTrialModel') -and $text.Contains('Test-FastLlmOffloadExactConsent') -and $text.Contains('Assert-FastLlmHipExtraction')) 'Exact cached model consent and full engine manifest required.'
Check ($text.Contains('Test-FastLlmApiCanary') -and $text.Contains('ConvertFrom-FastLlmPlacementLog') -and $text.Contains('CpuBufferLikeLines')) 'Canary and existing full GPU placement parser required.'
Check (-not $text.Contains('Install-FastLlmModel') -and -not $text.Contains('Write-FastLlmModelConsentReceipt')) 'Trial may not download or accept licenses.'
Check ($text.Contains('dynamicClosureVerified=$false') -and $text.Contains('performanceQualified=$false')) 'Trial may not claim closure or qualification.'
Check ($text.Contains('GetLoopbackListenerOwners(18081)') -and $text.Contains('StartUtcTicks') -and
       ([regex]::Matches($text,'Assert-FastLlmHipTrialListenerOwner -Process \$child.Process')).Count -ge 4) 'Health, canary and ready must bind to the exact supervised listener owner.'
Check ($text.Contains('function Get-FastLlmHipTrialStatus') -and $text.Contains('function Request-FastLlmHipTrialStop') -and
       ([regex]::Matches($text,'Assert-FastLlmHipLabIdentity')).Count -ge 3) 'Start, status and stop must require the standard-user identity.'
Check ($text.Contains('failureOutputSha256') -and -not $text.Contains('$state.failureDiagnostics=$lines')) 'Failure state must not persist raw native logs or request text.'
Check ($text.Contains('ConvertFrom-FastLlmHipTrialPlacementEvidence') -and
       $text.Contains('ConvertFrom-FastLlmStartupDiagnostics') -and
       $text.Contains('Assert-FastLlmHipTrialPlacementGate')) 'Structured startup and placement evidence must be captured before strict gate.'
Check ($text.Contains('trialSourceSha256=$Plan.trialSourceSha256') -and
       $text.Contains("throw 'HIP trial source changed before process launch.'") -and
       $text.Contains("throw 'HIP trial source changed during process launch.'")) 'Trial state must bind and recheck the launch-time source digest.'
Check ($text.Contains('allowHostModelBuffer=[bool]$Plan.allowHostModelBuffer') -and
       $text.Contains('$State.placementClassification=''all-reported-layers-with-host-model-buffer''') -and
       $text.Contains('$State.placementClassification=''all-reported-layers-no-host-model-buffer''') -and
       $text.Contains("cpuInputEvidence='not-attested'")) 'Host-buffer opt-in and honest classification must be recorded in state.'
$toolText=Get-Content -LiteralPath (Join-Path $root 'tools/hip-model-trial.ps1') -Raw
Check ($toolText.Contains('[switch]$AllowHostModelBuffer') -and
       $toolText.Contains('-AllowHostModelBuffer:$allowHostBuffer')) 'Private host-buffer switch must be explicit and forwarded only by start.'
$startSource=$text.Substring($text.IndexOf('function Start-FastLlmHipModelTrial'))
Check ($startSource.IndexOf('Assert-FastLlmHipNormalServiceStopped -ArtifactRoot $ArtifactRoot') -lt
       $startSource.IndexOf('$artifactLock=Enter-FastLlmOperation $ArtifactRoot') -and
       $startSource.IndexOf('Assert-FastLlmHipNormalServiceStopped -ArtifactRoot $ArtifactRoot') -ge 0) 'Normal-service status must be read before acquiring trial own artifact lock.'
"HIP model trial checks: $checks passed"
