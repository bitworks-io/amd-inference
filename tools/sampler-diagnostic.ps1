#requires -Version 5.1
# Private fixed sampler comparison for an already-Ready normal Q4/32K/S1 run.
[CmdletBinding()]
param([string]$InstallRoot=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Bitworks/FastLLM'),
      [Parameter(Mandatory=$true)][string]$OutputPath,
      [ValidateRange(120,3600)][int]$DeadlineSeconds=1800,
      [ValidateRange(1,120)][int]$RequestTimeoutSeconds=45)
$ErrorActionPreference='Stop'
$sourceRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../src'))
$module=Import-Module (Join-Path $sourceRoot 'FastLlm.psm1') -Force -PassThru
$semantic=Join-Path $sourceRoot 'FastLlm.SemanticSmoke.ps1'
$workload=Join-Path $sourceRoot 'FastLlm.TaskWorkload.ps1'
$taskTool=Join-Path $PSScriptRoot 'task-quality-benchmark.ps1'
$diagnostic=Join-Path $sourceRoot 'FastLlm.SamplerDiagnostic.ps1'
$report=& $module {
    param($Semantic,$Workload,$TaskTool,$Diagnostic,$Install,$Destination,$Tool,$Deadline,$RequestTimeout)
    . $Semantic
    . $Workload
    # Dot-source only to reuse the unchanged fixed request constructor and strict parser.
    . $TaskTool -OutputPath $Destination
    . $Diagnostic
    Invoke-FastLlmSamplerDiagnostic -InstallRoot $Install -OutputPath $Destination -ToolPath $Tool `
        -TaskToolPath $TaskTool -DeadlineSeconds $Deadline -RequestTimeoutSeconds $RequestTimeout
} $semantic $workload $taskTool $diagnostic $InstallRoot $OutputPath $PSCommandPath $DeadlineSeconds $RequestTimeoutSeconds
Write-Host "Saved private sampler diagnostic: $OutputPath. Status $($report.reportStatus); $($report.methodology.issuedTaskRequests)/32 task requests issued. No qualification."
