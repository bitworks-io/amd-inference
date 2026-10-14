#requires -Version 5.1
# Private already-Ready normal-run diagnostic; does not launch or alter the server.
[CmdletBinding()]
param([string]$InstallRoot=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Bitworks/FastLLM'),
      [Parameter(Mandatory=$true)][string]$OutputPath,
      [ValidateSet('compare','unconstrained-only','json-object-only','explicit-object-schema')][string]$Mode='compare')
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '../src/FastLlm.psm1') -Force -PassThru
$semantic=Join-Path $PSScriptRoot '../src/FastLlm.SemanticSmoke.ps1'
$diagnostic=Join-Path $PSScriptRoot '../src/FastLlm.JsonFormatDiagnostic.ps1'
$report=& $module {param($Semantic,$Diagnostic,$Root,$Destination,$Tool,$DiagnosticMode)
    . $Semantic
    . $Diagnostic
    Invoke-FastLlmJsonFormatDiagnostic -InstallRoot $Root -OutputPath $Destination -ToolSourcePath $Tool -Mode $DiagnosticMode
} $semantic $diagnostic $InstallRoot $OutputPath $PSCommandPath $Mode
Write-Host "Saved private JSON-format diagnostic: $OutputPath. Aborted $($report.aborted); no quality qualification."
