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
$benchmark=Join-Path $repo 'src/FastLlm.HipBenchmark.ps1'
$soak=Join-Path $repo 'src/FastLlm.HipSoak.ps1'
$report=& $module {param($Probe,$Trial,$Benchmark,$Soak,$Root,$ExpectedRun,$Output)
    . $Probe;. $Trial;. $Benchmark;. $Soak
    Invoke-FastLlmHipSoak -RunRoot $Root -RunId $ExpectedRun -OutputPath $Output
} $probe $trial $benchmark $soak $RunRoot $RunId $OutputPath
Write-Host "Saved private HIP soak report: $OutputPath. Status $($report.outcome.status), cycles $($report.outcome.completedCycles). Not qualification."
if(-not $report.outcome.completed){throw 'Private HIP soak failed; failure-only report was saved.'}
