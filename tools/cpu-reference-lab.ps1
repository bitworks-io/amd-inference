#requires -Version 5.1
# Private CPU-reference lane (qwen3.8-27b-ud-q4-k-m, context 32768, one slot, loopback port 18089).
# It never acquires artifacts or accepts a license, and it is not a fit, residency, quality or performance claim.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true,Position=0)][ValidateSet('start','status','stop')][string]$Action,
    [string]$ArtifactRoot=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Bitworks/FastLLM'),
    [string]$LabRunRoot=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Bitworks/FastLLM-CpuReferenceLab'),
    [ValidateRange(30,3600)][int]$LoadTimeoutSeconds=1200
)
$ErrorActionPreference='Stop'
$sourceRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../src'))
$module=Import-Module (Join-Path $sourceRoot 'FastLlm.psm1') -Force -PassThru
$lab=Join-Path $sourceRoot 'FastLlm.CpuReferenceLab.ps1'
$catalog=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../config/catalog.json'))
switch($Action){
    'start' {
        $result=& $module {
            param($Lab,$Artifact,$Run,$Catalog,$Timeout)
            . $Lab
            Start-FastLlmCpuReferenceLab -ArtifactRoot $Artifact -LabRunRoot $Run -CatalogPath $Catalog -LoadTimeoutSeconds $Timeout
        } $lab $ArtifactRoot $LabRunRoot $catalog $LoadTimeoutSeconds
        if($result -ne 0){exit 1}
    }
    'status' {
        & $module {param($Lab,$Run) . $Lab; Get-FastLlmCpuReferenceLabStatus -LabRunRoot $Run} $lab $LabRunRoot | ConvertTo-Json -Depth 12
    }
    'stop' {
        & $module {param($Lab,$Run) . $Lab; Request-FastLlmCpuReferenceLabStop -LabRunRoot $Run} $lab $LabRunRoot
    }
}
