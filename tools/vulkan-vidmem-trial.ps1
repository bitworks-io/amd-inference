#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true,Position=0)][ValidateSet('start','status','stop')][string]$Action,
      [string]$ArtifactRoot=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Bitworks/FastLLM'),
      [Parameter(Mandatory=$true)][string]$RunRoot,
      [ValidateSet('default','disable-host-visible-vidmem')][string]$Variant,
      [ValidateSet('A1','B1','B2','A2')][string]$Arm,
      [ValidateSet('xtx-q4-32k','xt-iq4-16k')][string]$Tuple,
      [ValidateRange(30,1800)][int]$LoadTimeoutSeconds=600)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $projectRoot 'src/FastLlm.psm1') -PassThru -ErrorAction Stop
$trialSource=Join-Path $projectRoot 'src/FastLlm.VulkanVidmemTrial.ps1'
$catalog=Join-Path $projectRoot 'config/catalog.json'
switch($Action){
    'start'{if(-not $Variant -or -not $Arm -or -not $Tuple){throw 'Start requires exact Variant, Arm and Tuple.'}
        $result=& $module {param($trial,$a,$r,$catalogPath,$variantName,$armLabel,$tupleName,$timeout)
            . $trial
            Start-FastLlmVulkanVidmemTrial -ArtifactRoot $a -RunRoot $r -CatalogPath $catalogPath -Variant $variantName -Arm $armLabel -Tuple $tupleName -LoadTimeoutSeconds $timeout
        } $trialSource $ArtifactRoot $RunRoot $catalog $Variant $Arm $Tuple $LoadTimeoutSeconds
        if($result -ne 0){exit 1}
    }
    'status'{if($Variant -or $Arm -or $Tuple){throw 'Status takes no variant or arm selection.'}
        & $module {param($trial,$root) . $trial;Get-FastLlmVulkanVidmemStatus -RunRoot $root} $trialSource $RunRoot |
            ConvertTo-Json -Depth 12
    }
    'stop'{if($Variant -or $Arm -or $Tuple){throw 'Stop takes no variant or arm selection.'}
        & $module {param($trial,$root) . $trial;Request-FastLlmVulkanVidmemStop -RunRoot $root} $trialSource $RunRoot
    }
}
