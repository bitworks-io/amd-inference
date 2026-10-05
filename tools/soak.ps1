#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallRoot=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Bitworks/FastLLM'),
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [int]$MinimumCycles=100,
    [int]$DurationSeconds=7200
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../src/FastLlm.psm1') -Force
Invoke-FastLlmSoak -InstallRoot $InstallRoot -OutputPath $OutputPath -MinimumCycles $MinimumCycles -DurationSeconds $DurationSeconds | Out-Null
Write-Host "Saved $OutputPath. API reliability evidence is not memory, quality, or release approval."
