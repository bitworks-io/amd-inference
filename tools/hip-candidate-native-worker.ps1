#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$CandidateRoot,
      [ValidateRange(5,60)][int]$TimeoutSeconds=20)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'src/FastLlm.HipCandidateProbe.ps1')
$result = Invoke-FastLlmHipNativePhase -CandidateRoot $CandidateRoot -TimeoutSeconds $TimeoutSeconds
$json = ConvertTo-Json -InputObject $result -Depth 8 -Compress
foreach ($line in (ConvertTo-FastLlmHipWorkerLines -Json $json)) { [Console]::Out.WriteLine($line) }
