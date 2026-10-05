#requires -Version 5.1
[CmdletBinding()]
param([string]$RunRoot=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Bitworks/FastLLM-HipPrivateTrial'),
      [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{32}$')][string]$RunId,
      [Parameter(Mandatory=$true)][string]$OutputPath)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $repo 'src/FastLlm.psm1') -PassThru -ErrorAction Stop
$probe=Join-Path $repo 'src/FastLlm.HipCandidateProbe.ps1'
$trial=Join-Path $repo 'src/FastLlm.HipModelTrial.ps1'
$hipBenchmark=Join-Path $repo 'src/FastLlm.HipBenchmark.ps1'
$semantic=Join-Path $repo 'src/FastLlm.SemanticSmoke.ps1'
$hipSemantic=Join-Path $repo 'src/FastLlm.HipSemanticSmoke.ps1'
$report=& $module {param($Probe,$Trial,$HipBenchmark,$Semantic,$HipSemantic,$Root,$ExpectedRun,$Output)
    . $Probe;. $Trial;. $HipBenchmark;. $Semantic;. $HipSemantic
    Invoke-FastLlmHipSemanticSmoke -RunRoot $Root -RunId $ExpectedRun -OutputPath $Output
} $probe $trial $hipBenchmark $semantic $hipSemantic $RunRoot $RunId $OutputPath
Write-Host "Saved private HIP semantic smoke report: $OutputPath. Passed $($report.passed), failed $($report.failed), inconclusive $($report.inconclusive). Not quality qualification."
