#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true,Position=0)][ValidateSet('start','status','stop')][string]$Action,
      [string]$ArtifactRoot=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Bitworks/FastLLM'),
      [string]$RunRoot=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Bitworks/FastLLM-VulkanFitPrivateTrial'),
      [ValidateSet('on','off')][string]$FitMode,
      [switch]$AllowHostModelBuffer,
      [ValidateRange(30,1800)][int]$LoadTimeoutSeconds=600)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $projectRoot 'src/FastLlm.psm1') -PassThru -ErrorAction Stop
$trialSource=Join-Path $projectRoot 'src/FastLlm.VulkanFitTrial.ps1'
$catalog=Join-Path $projectRoot 'config/catalog.json'
switch($Action){
    'start'{if(-not $FitMode){throw 'Start requires exact FitMode on or off.'}
        $result=& $module {param($trial,$a,$r,$catalogPath,$fit,$timeout,$allowHost)
            . $trial
            Start-FastLlmVulkanFitTrial -ArtifactRoot $a -RunRoot $r -CatalogPath $catalogPath -FitMode $fit -LoadTimeoutSeconds $timeout -AllowHostModelBuffer:$allowHost
        } $trialSource $ArtifactRoot $RunRoot $catalog $FitMode $LoadTimeoutSeconds ([bool]$AllowHostModelBuffer)
        if($result -ne 0){exit 1}
    }
    'status'{if($FitMode -or $AllowHostModelBuffer){throw 'Status takes no fit or host-buffer selection.'}
        & $module {param($trial,$root) . $trial;Get-FastLlmVulkanFitStatus -RunRoot $root} $trialSource $RunRoot |
            ConvertTo-Json -Depth 12
    }
    'stop'{if($FitMode -or $AllowHostModelBuffer){throw 'Stop takes no fit or host-buffer selection.'}
        & $module {param($trial,$root) . $trial;Request-FastLlmVulkanFitStop -RunRoot $root} $trialSource $RunRoot
    }
}
