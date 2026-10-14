#requires -Version 5.1
# Local comparator: checks four A1/B1/B2/A2 reports share one launch environment except the single override.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$A1,[Parameter(Mandatory=$true)][string]$B1,
      [Parameter(Mandatory=$true)][string]$B2,[Parameter(Mandatory=$true)][string]$A2)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $projectRoot 'src/FastLlm.psm1') -PassThru -ErrorAction Stop
$trial=Join-Path $projectRoot 'src/FastLlm.VulkanVidmemTrial.ps1'
$benchmark=Join-Path $projectRoot 'src/FastLlm.VulkanVidmemBenchmark.ps1'
$reports=@(foreach($path in @($A1,$B1,$B2,$A2)){ConvertFrom-Json -InputObject (Get-Content -LiteralPath $path -Raw)})
$result=& $module {param($Trial,$Benchmark,$R) . $Trial;. $Benchmark;Compare-FastLlmVulkanVidmemArmReports -Reports $R} $trial $benchmark $reports
$result|ConvertTo-Json -Depth 4
if(-not $result.ok){exit 1}
