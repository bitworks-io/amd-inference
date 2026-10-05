#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$LabRunRoot=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Bitworks/FastLLM-OffloadLab'),
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [int[]]$PromptTokens=@(512,2048),
    [ValidateRange(1,512)][int]$GenerationTokens=128,
    [ValidateRange(5,20)][int]$Repetitions=5
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../src/FastLlm.psm1') -Force
Invoke-FastLlmOffloadBenchmark -LabRunRoot $LabRunRoot -OutputPath $OutputPath -PromptTokens $PromptTokens -GenerationTokens $GenerationTokens -Repetitions $Repetitions | Out-Null
Write-Host "Saved experimental CPU-offload measurements to $OutputPath. These are not public fit, quality, residency or performance approval."
