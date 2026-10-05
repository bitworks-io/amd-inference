#requires -Version 5.1
# Read-only child worker. The standard-user parent bounds runtime and captures its JSON.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2
if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) { throw '64-bit Windows is required.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Standard-user execution is required.' }
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'src/FastLlm.PrerequisiteDiagnostics.ps1')
Get-FastLlmPrerequisiteSnapshot | ConvertTo-Json -Depth 6 -Compress
