#requires -Version 5.1
# Lab-only explicit Microsoft prerequisite installation. No silent consent.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$PreparedPath,[switch]$ConfirmInstall)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
if(-not $ConfirmInstall){throw 'Install Microsoft prerequisite requires an explicit confirmation.'}
$repo=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $repo 'src/FastLlm.psm1') -PassThru -ErrorAction Stop
$prepare=Join-Path $repo 'src/FastLlm.VcRedist.ps1'
$install=Join-Path $repo 'src/FastLlm.VcRedistInstall.ps1'
$manifest=Join-Path $repo 'config/windows-prerequisites.json'
$cache=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'Bitworks\FastLLM\prerequisites'
$result=& $module {param($PrepareSource,$InstallSource,$Config,$CacheRoot,$Path)
    . $PrepareSource
    . $InstallSource
    Invoke-FastLlmVcRedistInstall -PreparedPath $Path -ManifestPath $Config -CacheRoot $CacheRoot -ConfirmInstall
} $prepare $install $manifest $cache $PreparedPath
$result|ConvertTo-Json -Depth 3
