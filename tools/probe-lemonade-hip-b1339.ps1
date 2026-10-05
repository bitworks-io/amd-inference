#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ArchivePath,
      [Parameter(Mandatory=$true)][string]$OutputParent,
      [ValidateRange(5,60)][int]$TimeoutSeconds=20)
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'src/FastLlm.HipCandidateProbe.ps1')
Invoke-FastLlmHipCandidateProbe -ArchivePath $ArchivePath -OutputParent $OutputParent -TimeoutSeconds $TimeoutSeconds |
    ConvertTo-Json -Depth 8 -Compress
