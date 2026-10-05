#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true,Position=0)][ValidateSet('prepare','start','status','stop')][string]$Action,
    [string]$ArtifactRoot=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Bitworks/FastLLM'),
    [string]$LabRunRoot=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Bitworks/FastLLM-OffloadLab'),
    [string]$ModelId,
    [string]$Device,
    [int]$GpuLayers=0,
    [ValidateRange(1,8192)][int]$ContextSize=8192,
    [ValidateRange(30,1800)][int]$LoadTimeoutSeconds=600,
    [switch]$AcceptModelLicense,
    [switch]$Unattended
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../src/FastLlm.psm1') -Force
$catalog=Join-Path $PSScriptRoot '../config/catalog.json'
switch($Action){
    'prepare' {
        if(-not $ModelId -or $Device -or $GpuLayers){throw 'Prepare requires ModelId and no device/layer arguments.'}
        Initialize-FastLlmOffloadLab -ArtifactRoot $ArtifactRoot -LabRunRoot $LabRunRoot -CatalogPath $catalog -ModelId $ModelId -AcceptModelLicense:$AcceptModelLicense -Unattended:$Unattended | Out-Null
    }
    'start' {
        if(-not $ModelId -or -not $Device -or $GpuLayers -le 0){throw 'Start requires exact ModelId, explicit Vulkan device and positive GpuLayers.'}
        if($AcceptModelLicense -or $Unattended){throw 'Start never acquires artifacts or accepts a license. Use prepare first.'}
        $result=Start-FastLlmOffloadLab -ArtifactRoot $ArtifactRoot -LabRunRoot $LabRunRoot -CatalogPath $catalog -ModelId $ModelId -Device $Device -GpuLayers $GpuLayers -ContextSize $ContextSize -LoadTimeoutSeconds $LoadTimeoutSeconds
        if($result -ne 0){exit 1}
    }
    'status' {
        if($ModelId -or $Device -or $GpuLayers -or $AcceptModelLicense -or $Unattended){throw 'Status takes no model, device, layer or license arguments.'}
        Get-FastLlmOffloadLabStatus -LabRunRoot $LabRunRoot | ConvertTo-Json -Depth 12
    }
    'stop' {
        if($ModelId -or $Device -or $GpuLayers -or $AcceptModelLicense -or $Unattended){throw 'Stop takes no model, device, layer or license arguments.'}
        Request-FastLlmOffloadLabStop -LabRunRoot $LabRunRoot
    }
}
