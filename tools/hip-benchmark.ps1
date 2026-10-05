#requires -Version 5.1
[CmdletBinding()]
param([string]$RunRoot=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Bitworks/FastLLM-HipPrivateTrial'),
      [Parameter(Mandatory=$true)][string]$OutputPath)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $repo 'src/FastLlm.psm1') -PassThru -ErrorAction Stop
$probe=Join-Path $repo 'src/FastLlm.HipCandidateProbe.ps1'
$trial=Join-Path $repo 'src/FastLlm.HipModelTrial.ps1'
$benchmark=Join-Path $repo 'src/FastLlm.HipBenchmark.ps1'
& $module {param($Probe,$Trial,$Benchmark,$Root,$Output)
    . $Probe;. $Trial;. $Benchmark
    Invoke-FastLlmHipBenchmark -RunRoot $Root -OutputPath $Output|Out-Null
} $probe $trial $benchmark $RunRoot $OutputPath
Write-Host "Saved private HIP measurements to $OutputPath. These are not public fit, quality, residency or performance approval."
