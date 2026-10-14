#requires -Version 5.1
# Private five-request backend-parity diagnostic (T1, T2, G1, G2, G3) for an already-Ready server. It never starts or
# changes inference. -Target Normal attaches to the normal run on 127.0.0.1:8080; -Target CpuReference attaches to the
# CPU-reference lab (tools/cpu-reference-lab.ps1) state and its loopback port.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidateSet('Normal','CpuReference')][string]$Target,
      [string]$InstallRoot=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Bitworks/FastLLM'),
      [string]$LabRunRoot=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Bitworks/FastLLM-CpuReferenceLab'),
      [Parameter(Mandatory=$true)][string]$OutputPath,
      [ValidateRange(0,1200)][int]$DeadlineSeconds=0,
      [ValidateRange(0,600)][int]$RequestTimeoutSeconds=0)
$ErrorActionPreference='Stop'
$sourceRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../src'))
$module=Import-Module (Join-Path $sourceRoot 'FastLlm.psm1') -Force -PassThru
$semantic=Join-Path $sourceRoot 'FastLlm.SemanticSmoke.ps1'
$workload=Join-Path $sourceRoot 'FastLlm.TaskWorkload.ps1'
$taskQuality=Join-Path $PSScriptRoot 'task-quality-benchmark.ps1'
$cpuLab=Join-Path $sourceRoot 'FastLlm.CpuReferenceLab.ps1'
$diagnostic=Join-Path $sourceRoot 'FastLlm.BackendParityDiagnostic.ps1'
$report=& $module {
    param($Semantic,$Workload,$TaskQuality,$CpuLab,$Diagnostic,$Mode,$Root,$LabRoot,$Destination,$Tool,$Deadline,$RequestTimeout)
    . $Semantic
    . $Workload
    # InvocationName is '.', so the guarded task-quality controller does not run.
    . $TaskQuality -OutputPath $Destination
    . $CpuLab
    . $Diagnostic
    Invoke-FastLlmBackendParityDiagnostic -Target $Mode -InstallRoot $Root -LabRunRoot $LabRoot -OutputPath $Destination `
        -ToolSourcePath $Tool -TaskQualityToolSourcePath $TaskQuality -DeadlineSeconds $Deadline -RequestTimeoutSeconds $RequestTimeout
} $semantic $workload $taskQuality $cpuLab $diagnostic $Target $InstallRoot $LabRunRoot $OutputPath $PSCommandPath $DeadlineSeconds $RequestTimeoutSeconds
Write-Host "Saved private backend parity report: $OutputPath. Target $Target; status $($report.reportStatus); valid $($report.valid); no qualification."
if($report.reportStatus -cne 'complete'){exit 1}
