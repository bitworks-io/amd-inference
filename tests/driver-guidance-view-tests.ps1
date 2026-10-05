#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
Import-Module (Join-Path $PSScriptRoot '../src/FastLlm.psm1') -Force
$script:checks=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++;Write-Host "PASS: $Message"}
$xtx=Get-FastLlmDriverGuidance -GpuName 'AMD Radeon RX 7900 XTX' -PnpDriverVersion '32.0.31041.1004'
$text=Format-FastLlmDriverGuidance $xtx
Check ($text.Contains('2026-10-05') -and $text.Contains('Adrenalin 26.8.1') -and $text.Contains('Adrenalin 26.9.2')) 'view exposes snapshot date and distinct baseline/optional packages'
Check ($text.Contains('Reported driver version: 32.0.31041.1004') -and $text.Contains('not certified or marked current')) 'reported version is not presented as verified/current'
Check ($text.Contains('Minimal') -and $text.Contains('not a measured speed improvement')) 'view explains install style without speed claim'
Check ($text.Contains('No driver is downloaded or installed here')) 'view is explicit about no machine changes'
$pro=Get-FastLlmDriverGuidance -GpuName 'AMD Radeon AI PRO R9700'
$text=Format-FastLlmDriverGuidance $pro
Check ($text.Contains('PRO Edition 26.Q3') -and $text.Contains('installer-dependent') -and $text.Contains('No optional package')) 'PRO guidance does not imply an Adrenalin optional package or install style'
$unknown=Get-FastLlmDriverGuidance -GpuName 'Unknown display'
$text=Format-FastLlmDriverGuidance $unknown
Check ($text.Contains('No exact focus-model match') -and $text.Contains('Reported driver version: Unavailable') -and -not $text.Contains('AMD baseline:')) 'unknown display has no guessed recommendation'
$bad=$xtx | ConvertTo-Json -Depth 10 | ConvertFrom-Json
$bad.productUrl='https://www.amd.com.evil.test/en/support/download'
$failed=$false;try{Format-FastLlmDriverGuidance $bad|Out-Null}catch{$failed=$true}
Check $failed 'lookalike URL cannot reach the open-page action'
$bad=$xtx | ConvertTo-Json -Depth 10 | ConvertFrom-Json
$bad.qualification=$true
$failed=$false;try{Format-FastLlmDriverGuidance $bad|Out-Null}catch{$failed=$true}
Check $failed 'unexpected qualification flag is rejected'
$ui=Get-Content -LiteralPath (Join-Path $PSScriptRoot '../fast-llm-ui.ps1') -Raw
Check ($ui.Contains("LaunchStep 'driver guidance'") -and $ui.Contains('$code -in @(0,2)')) 'guidance is asynchronous and permits a missing-engine doctor report'
Write-Host "$script:checks driver-guidance view checks passed. Native Windows dialog not exercised."
