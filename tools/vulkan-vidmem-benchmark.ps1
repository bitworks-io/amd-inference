#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RunRoot,
      [Parameter(Mandatory=$true)][string]$OutputPath,
      [Parameter(Mandatory=$true)][ValidateSet('A1','B1','B2','A2')][string]$Arm,
      [string]$ReferenceReport)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $projectRoot 'src/FastLlm.psm1') -PassThru -ErrorAction Stop
$trial=Join-Path $projectRoot 'src/FastLlm.VulkanVidmemTrial.ps1'
$benchmark=Join-Path $projectRoot 'src/FastLlm.VulkanVidmemBenchmark.ps1'
& $module {param($Trial,$Benchmark,$Root,$Output,$ArmLabel,$Reference)
    . $Trial;. $Benchmark
    Invoke-FastLlmVulkanVidmemBenchmark -RunRoot $Root -OutputPath $Output -Arm $ArmLabel -ReferenceReport $Reference|Out-Null
} $trial $benchmark $RunRoot $OutputPath $Arm $ReferenceReport
Write-Host "Saved private Vulkan vidmem measurements to $OutputPath. They are not public fit, quality, residency or performance approval."
