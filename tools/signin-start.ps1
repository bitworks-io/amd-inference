#requires -Version 5.1
# Start-at-sign-in launcher: one attempt to start the background host from the saved request, then record the result in
# state\signin-start.json. Started by FastLLM.cmd /signin from the per-user Run value. It never retries and never downloads.
[CmdletBinding()]
param([string]$InstallRoot,
      [ValidateRange(0,120)][int]$DelaySeconds = 20)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$source = Split-Path -Parent $PSScriptRoot
. (Join-Path $source 'src\FastLlm.BackgroundHost.ps1')
. (Join-Path $source 'src\FastLlm.SignInStart.ps1')
if ([string]::IsNullOrWhiteSpace($InstallRoot)) { $InstallRoot = Get-FastLlmSignInDefaultInstallRoot }
$outcome = Invoke-FastLlmSignInLaunch -SourceRoot $source -InstallRoot $InstallRoot -DelaySeconds $DelaySeconds
if ($outcome.result -cin @('started', 'skipped-occupied')) { exit 0 }
exit 1
