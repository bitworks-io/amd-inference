#requires -Version 5.1
[CmdletBinding()]
param([string]$InstallRoot=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Bitworks/FastLLM'),[Parameter(Mandatory=$true)][string]$OutputPath,[int[]]$PromptTokens=@(512,4096),[int]$GenerationTokens=128,[int]$Repetitions=5)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../src/FastLlm.psm1') -Force
Invoke-FastLlmBenchmark -InstallRoot $InstallRoot -OutputPath $OutputPath -PromptTokens $PromptTokens -GenerationTokens $GenerationTokens -Repetitions $Repetitions | Out-Null
Write-Host "Saved $OutputPath. Results are measurements, not release approval. Keep other clients disconnected during the run."
