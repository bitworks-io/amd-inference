#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true,Position=0)][ValidateSet('start','status','stop')][string]$Action,
      [string]$ArtifactRoot=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Bitworks/FastLLM'),
      [string]$RunRoot=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Bitworks/FastLLM-HipPrivateTrial'),
      [string]$CandidateRoot,
      [string]$ModelId,
      [ValidateRange(0,131072)][int]$ContextSize=0,
      [switch]$AllowHostModelBuffer,
      [ValidateRange(30,1800)][int]$LoadTimeoutSeconds=600)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $projectRoot 'src/FastLlm.psm1') -PassThru -ErrorAction Stop
$trialSource=Join-Path $projectRoot 'src/FastLlm.HipModelTrial.ps1'
$probeSource=Join-Path $projectRoot 'src/FastLlm.HipCandidateProbe.ps1'
$catalog=Join-Path $projectRoot 'config/catalog.json'
switch($Action){
    'start'{if(-not $CandidateRoot -or -not $ModelId -or $ContextSize -le 0){throw 'Start requires CandidateRoot, exact ModelId and explicit positive ContextSize.'}
        $result=& $module {param($trial,$probe,$a,$c,$r,$catalogPath,$id,$context,$timeout,$allowHostBuffer)
            . $probe;. $trial
            Start-FastLlmHipModelTrial -ArtifactRoot $a -CandidateRoot $c -RunRoot $r -CatalogPath $catalogPath -ModelId $id -ContextSize $context -LoadTimeoutSeconds $timeout -AllowHostModelBuffer:$allowHostBuffer
        } $trialSource $probeSource $ArtifactRoot $CandidateRoot $RunRoot $catalog $ModelId $ContextSize $LoadTimeoutSeconds ([bool]$AllowHostModelBuffer)
        if($result -ne 0){exit 1}
    }
    'status'{if($CandidateRoot -or $ModelId -or $ContextSize -or $AllowHostModelBuffer){throw 'Status takes no candidate/model/context/host-buffer selection.'}
        & $module {param($trial,$probe,$root) . $probe;. $trial;Get-FastLlmHipTrialStatus -RunRoot $root} $trialSource $probeSource $RunRoot |
            ConvertTo-Json -Depth 12
    }
    'stop'{if($CandidateRoot -or $ModelId -or $ContextSize -or $AllowHostModelBuffer){throw 'Stop takes no candidate/model/context/host-buffer selection.'}
        & $module {param($trial,$probe,$root) . $probe;. $trial;Request-FastLlmHipTrialStop -RunRoot $root} $trialSource $probeSource $RunRoot
    }
}
