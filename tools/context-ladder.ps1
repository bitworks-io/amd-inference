#requires -Version 5.1
# Thin CLI for the W11 context ladder (one client, one slot, one supervised normal server). Private lab report, never a qualification.
[CmdletBinding()]
param([string]$InstallRoot=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Bitworks/FastLLM'),
      [Parameter(Mandatory=$true)][string]$OutputPath,
      [int[]]$Tiers=@(1024,2048,4096,8192,16384,32768),
      [ValidateRange(64,1024)][int]$OutputTokens=256,
      [ValidateRange(1,10)][int]$Repetitions=3,
      [double[]]$NeedleDepths=@(0.1,0.5,0.9),
      [ValidateRange(1,1800)][int]$RequestTimeoutSeconds=900,
      [ValidateRange(1,14400)][int]$RunDeadlineSeconds=7200,
      [int]$Seed=42)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $projectRoot 'src/FastLlm.psm1') -Force -PassThru -ErrorAction Stop
$ladderSource=Join-Path $projectRoot 'src/FastLlm.ContextLadder.ps1'
$parameters=@{InstallRoot=$InstallRoot;OutputPath=$OutputPath;Tiers=$Tiers;OutputTokens=$OutputTokens;Repetitions=$Repetitions
    NeedleDepths=$NeedleDepths;RequestTimeoutSeconds=$RequestTimeoutSeconds;RunDeadlineSeconds=$RunDeadlineSeconds;Seed=$Seed
    CliSourcePath=$PSCommandPath}
$report=& $module {param($source,$arguments) . $source;Invoke-FastLlmContextLadder @arguments} $ladderSource $parameters
Write-Host "Saved $OutputPath (completed=$($report.completed), abortReason=$($report.abortReason)). A private lab measurement, not a qualification. Keep other clients disconnected during the run."
if(-not $report.completed){exit 1}
