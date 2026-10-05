#requires -Version 5.1
[CmdletBinding()]
param([string]$InstallRoot=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Bitworks/FastLLM'),
      [Parameter(Mandatory=$true)][string]$OutputPath)
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '../src/FastLlm.psm1') -Force -PassThru
$source=Join-Path $PSScriptRoot '../src/FastLlm.SemanticSmoke.ps1'
# The standalone evaluator uses private runtime/status/HTTP helpers. Run it in
# the imported module's scope rather than changing the public module exports.
$report=& $module {param($Source,$Root,$Destination) . $Source; Invoke-FastLlmSemanticSmoke -InstallRoot $Root -OutputPath $Destination} $source $InstallRoot $OutputPath
Write-Host "Saved private semantic smoke report: $OutputPath. Passed $($report.passed), failed $($report.failed), inconclusive $($report.inconclusive). This tiny check is not quality qualification."
