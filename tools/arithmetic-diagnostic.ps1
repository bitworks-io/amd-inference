#requires -Version 5.1
# Private one-request diagnostic for an already-Ready normal run; it never starts or changes inference.
[CmdletBinding()]
param([string]$InstallRoot=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Bitworks/FastLLM'),
      [Parameter(Mandatory=$true)][string]$OutputPath,
      [ValidateRange(1,180)][int]$DeadlineSeconds=90,
      [ValidateRange(1,60)][int]$RequestTimeoutSeconds=60)
$ErrorActionPreference='Stop'
$sourceRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../src'))
$module=Import-Module (Join-Path $sourceRoot 'FastLlm.psm1') -Force -PassThru
$semantic=Join-Path $sourceRoot 'FastLlm.SemanticSmoke.ps1'
$workload=Join-Path $sourceRoot 'FastLlm.TaskWorkload.ps1'
$taskQuality=Join-Path $PSScriptRoot 'task-quality-benchmark.ps1'
$diagnostic=Join-Path $sourceRoot 'FastLlm.ArithmeticDiagnostic.ps1'
$report=& $module {
    param($Semantic,$Workload,$TaskQuality,$Diagnostic,$Root,$Destination,$Tool,$Deadline,$RequestTimeout)
    . $Semantic
    . $Workload
    # InvocationName is '.', so the guarded task-quality controller does not run.
    . $TaskQuality -OutputPath $Destination
    . $Diagnostic
    Invoke-FastLlmArithmeticDiagnostic -InstallRoot $Root -OutputPath $Destination -ToolSourcePath $Tool `
        -TaskQualityToolSourcePath $TaskQuality -DeadlineSeconds $Deadline -RequestTimeoutSeconds $RequestTimeout
} $semantic $workload $taskQuality $diagnostic $InstallRoot $OutputPath $PSCommandPath $DeadlineSeconds $RequestTimeoutSeconds
Write-Host "Saved private arithmetic diagnostic: $OutputPath. Status $($report.reportStatus); classification $($report.result.diagnosticClassification); no qualification."
