#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$InstallRoot,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [Parameter(Mandatory=$true)][ValidateSet('default','disable-coopmat')][string]$Variant,
    [switch]$AllowHostModelBuffer
)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $repo 'src/FastLlm.psm1') -PassThru -ErrorAction Stop
$source=Join-Path $repo 'src/FastLlm.VulkanCoopmatScreen.ps1'
& $module { param($Script,$Root,$Output,$Arm,$AllowHost)
    . $Script
    Invoke-FastLlmVulkanCoopmatScreen -InstallRoot $Root -OutputPath $Output -Variant $Arm -AllowHostModelBuffer:([bool]$AllowHost)
} $source $InstallRoot $OutputPath $Variant ([bool]$AllowHostModelBuffer)
Write-Host "Saved private synthetic Vulkan screen: $OutputPath (not API performance or qualification)."
