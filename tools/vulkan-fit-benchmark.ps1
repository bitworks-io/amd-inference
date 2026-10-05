#requires -Version 5.1
[CmdletBinding()]
param([string]$RunRoot=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Bitworks/FastLLM-VulkanFitPrivateTrial'),
      [Parameter(Mandatory=$true)][string]$OutputPath)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $projectRoot 'src/FastLlm.psm1') -PassThru -ErrorAction Stop
$trial=Join-Path $projectRoot 'src/FastLlm.VulkanFitTrial.ps1'
$benchmark=Join-Path $projectRoot 'src/FastLlm.VulkanFitBenchmark.ps1'
& $module {param($Trial,$Benchmark,$Root,$Output)
    . $Trial;. $Benchmark
    Invoke-FastLlmVulkanFitBenchmark -RunRoot $Root -OutputPath $Output|Out-Null
} $trial $benchmark $RunRoot $OutputPath
Write-Host "Saved private Vulkan fit measurements to $OutputPath. They are not public fit, quality, residency or performance approval."
