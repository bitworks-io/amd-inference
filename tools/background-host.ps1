#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{32}$')][string]$RequestId,
      [Parameter(Mandatory=$true)][string]$InstallRoot)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$source = Split-Path -Parent $PSScriptRoot
. (Join-Path $source 'src\FastLlm.BackgroundHost.ps1')
$exitCode = Invoke-FastLlmBackgroundServe -RequestId $RequestId -InstallRoot $InstallRoot -SourceRoot $source
if ($exitCode -ne 0) { exit 1 }
