#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/FastLlm.HipCandidateProbe.ps1')
$checks=0
function Check([bool]$condition,[string]$message) { if(-not $condition){throw $message}; $script:checks++ }
$manifest=Get-Content -LiteralPath (Join-Path $root 'config/experiments/lemonade-hip-b1339-gfx110x.json') -Raw|ConvertFrom-Json
Check ($manifest.executionEnabled -eq $false) 'Candidate must remain disabled in the experiment manifest.'
$probeText=Get-Content -LiteralPath (Join-Path $root 'src/FastLlm.HipCandidateProbe.ps1') -Raw
Check ($probeText.Contains('Assert-FastLlmHipArchive') -and $probeText.Contains('Assert-FastLlmHipExtraction')) 'Archive and entire extracted file-set gates required.'
Check ($probeText.Contains('ProcessHost') -and $probeText.Contains('OutputCompleted') -and $probeText.Contains('OutputTruncated')) 'Bounded child/job and complete output required.'
Check ($probeText.Contains('Assert-FastLlmHipLabIdentity') -and $probeText.Contains('Administrator')) 'Standard user guard required.'
Check ($probeText.Contains('Get-FastLlmHipModuleSnapshot') -and $probeText.Contains('dynamicClosureVerified=$false')) 'Module snapshots must remain advisory, not closure proof.'
Check ($probeText.Contains("'--help','--list-devices'") -and -not $probeText.Contains(' -m ')) 'Only metadata/device probes allowed.'
Check ($probeText.Contains('Assert-FastLlmHipNoReparseAncestors') -and
       $probeText.Contains('foreach ($argument') -and
       $probeText.Contains('Assert-FastLlmHipExtraction -CandidateRoot $candidate -Manifest $manifest')) 'Each launch must recheck the complete extraction and ancestor paths.'
Check ($probeText.Contains('HIP native worker exceeded its 120-second deadline.') -and
       $probeText.Contains('hip-candidate-native-worker.ps1')) 'The native phase and module inspection must have an outer kill-on-close deadline.'
Check ((Test-FastLlmHipDeviceRow -OutputText 'ROCm0: AMD Radeon RX 7900 XTX (24576 MiB, 20000 MiB free)')) 'Exact discrete ROCm row should pass.'
Check (-not (Test-FastLlmHipDeviceRow -OutputText 'ERROR ROCm0 failed to initialize')) 'Error text mentioning ROCm0 must not count as a device.'
Check (-not (Test-FastLlmHipDeviceRow -OutputText 'ROCm0: AMD Radeon Graphics (24576 MiB, 20000 MiB free)')) 'Integrated-name row must not pass.'
Check (-not (Test-FastLlmHipDeviceRow -OutputText 'ROCm0: AMD Radeon RX 7900 XTX (24576 MiB, 25000 MiB free)')) 'Impossible free memory must not pass.'
Check (-not (Test-FastLlmHipDeviceRow -OutputText "ROCm0: AMD Radeon RX 7900 XTX (24576 MiB, 20000 MiB free)`nROCm0: AMD Radeon RX 7900 XTX (24576 MiB, 20000 MiB free)")) 'Duplicate ROCm0 rows must not pass.'
Check ($probeText.Contains('noncandidateRuntimeStatus=$ambientStatus') -and $probeText.Contains("else { 'unknown' }")) 'No module capture must not be reported as absent ambient runtime.'
$largeJson = '{"padding":"' + ('x' * 22000) + '"}'
$transportLines = @(ConvertTo-FastLlmHipWorkerLines -Json $largeJson)
Check ($transportLines.Count -gt 3 -and @($transportLines | Where-Object { $_.Length -gt 8192 }).Count -eq 0) 'Worker transport must use multiple lines below ProcessHost per-line cap.'
Check ((ConvertFrom-FastLlmHipWorkerLines -OutputText ($transportLines -join "`n") -WasTruncated $false) -ceq $largeJson) 'Large chunked worker report must round-trip exactly.'
$tamperedLines = @($transportLines)
$tamperedLines[1] = $tamperedLines[1].Replace('eHh4','eHh5')
$reject = $false
try { ConvertFrom-FastLlmHipWorkerLines -OutputText ($tamperedLines -join "`n") -WasTruncated $false | Out-Null }
catch { $reject = $true }
Check $reject 'Corrupt chunked worker report must fail closed.'
Check ((Get-FastLlmHipTextHash -Text 'test') -ceq '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08') 'SHA text helper mismatch.'
$old=$manifest.archive.sha256
try {
    $manifest.archive.sha256=('0'*64)
    $rejected=$false
    try { Assert-FastLlmHipArchive -ArchivePath (Join-Path $root 'config/experiments/lemonade-hip-b1339-gfx110x.json') -Manifest $manifest }
    catch { $rejected=$true }
    Check $rejected 'Edited manifest must be rejected before a native launch.'
} finally { $manifest.archive.sha256=$old }
$archive=$env:FASTLLM_TEST_HIP_ARCHIVE
$extracted=$env:FASTLLM_TEST_HIP_EXTRACTED
if ($archive -and $extracted -and (Test-Path -LiteralPath $archive -PathType Leaf) -and (Test-Path -LiteralPath $extracted -PathType Container)) {
    Assert-FastLlmHipArchive -ArchivePath $archive -Manifest $manifest
    $server=Assert-FastLlmHipExtraction -CandidateRoot $extracted -Manifest $manifest
    Check ($server.EndsWith('llama-server.exe')) 'Exact local audited ZIP/extraction must pass.'
}
"HIP candidate probe checks: $checks passed"
