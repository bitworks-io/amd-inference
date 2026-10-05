#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'tools/vulkan-capabilities.ps1')
$checks = 0
function Check([bool]$Value,[string]$Message) { if (-not $Value) { throw $Message }; $script:checks++ }
function Must-Reject([string]$Text,[string]$Message) {
    $rejected = $false
    try { ConvertFrom-FastLlmVulkanCapabilityOutput -Text $Text | Out-Null }
    catch { $rejected = $true }
    Check $rejected $Message
}
$cap = 'ggml_vulkan: 0 = AMD Radeon RX 7900 XTX (AMD proprietary driver) | uma: 0 | fp16: 1 | bf16: 1 | fp4: 0 | warp size: 64 | shared memory: 32768 | int dot: 1 | matrix cores: KHR_coopmat'
$listed = '  Vulkan0: AMD Radeon RX 7900 XTX (24576 MiB, 21123 MiB free)'
$sample = "ggml_vulkan: Found 1 Vulkan devices:`n$cap`nAvailable devices:`n$listed"
$devices = @(ConvertFrom-FastLlmVulkanCapabilityOutput -Text $sample)
Check ($devices.Count -eq 1 -and $devices[0].device -ceq 'Vulkan0' -and $devices[0].driverName -ceq 'AMD proprietary driver') 'Expected one sanitized Vulkan device.'
Check ($devices[0].matrixCores -ceq 'KHR_coopmat' -and $devices[0].integerDotProduct -eq $true -and $devices[0].sharedMemoryBytes -eq 32768) 'Expected exact backend capability values.'
Check ($devices[0].freeMiB -eq 21123 -and $devices[0].totalMiB -eq 24576) 'Expected bounded numeric engine memory values.'
Must-Reject "$sample`n$cap" 'Duplicate capability row must fail.'
Must-Reject "$sample`n$listed" 'Duplicate device-list row must fail.'
Must-Reject ($sample.Replace('Found 1', 'Found 2')) 'Backend-reported device count must match parsed rows.'
Must-Reject "$sample`nggml_vulkan: Found 1 Vulkan devices:" 'Duplicate backend device-count rows must fail.'
Must-Reject 'Available devices:  (none)' 'Empty capability output must fail.'
$countsOnly = $null
try { ConvertFrom-FastLlmVulkanCapabilityOutput -Text "Available devices:`n$listed" | Out-Null }
catch { $countsOnly = $_.Exception.Message }
Check ($countsOnly -ceq 'Missing or inconsistent Vulkan capability/device-list rows (capability=0, listed=1, found=absent).') 'Failure should reveal only bounded diagnostic counts, never raw native output.'
Must-Reject ($sample.Replace('Vulkan0:', 'Vulkan8:')) 'Ninth Vulkan device must fail.'
Must-Reject ($sample.Replace('21123 MiB free', '30000 MiB free')) 'Free memory greater than total must fail.'
Must-Reject ($sample.Replace('KHR_coopmat', 'not-a-known-mode')) 'Unknown matrix mode must fail.'
Must-Reject ($sample.Replace('warp size: 64', 'warp size: 999')) 'Impossible warp size must fail.'
Must-Reject ($sample.Replace('Vulkan0: AMD Radeon', 'Vulkan0: NVIDIA Radeon')) 'Capability/listed name mismatch must fail.'
Must-Reject ($sample.Replace('AMD proprietary driver', 'AMD proprietary driver;echo unsafe')) 'Free-form driver text must fail.'
Must-Reject ($sample + ('x' * 65536)) 'Oversized output must fail.'
Must-Reject ($sample + "`n" + ('x' * 8192)) 'Potentially truncated line must fail.'
$source = Get-Content -LiteralPath (Join-Path $root 'tools/vulkan-capabilities.ps1') -Raw
Check ($source.Contains("'--log-verbosity 5 --device Vulkan0 --log-disable --list-devices'") -and
       $source.Contains("@('--log-verbosity','5','--device','Vulkan0','--log-disable','--list-devices')")) 'Fixed arguments must enumerate Vulkan0 and drain queued debug rows before early list exit.'
Check ($source.Contains('65b8f2f9ca340dab273274086aba9e8f01cb14a2b8cf4bb65c5ed5f6e779caa6') -and
       ((Get-FileHash -LiteralPath (Join-Path $root 'config/catalog.json') -Algorithm SHA256).Hash.ToLowerInvariant() -ceq '65b8f2f9ca340dab273274086aba9e8f01cb14a2b8cf4bb65c5ed5f6e779caa6')) 'Reviewed whole-catalog digest must pin the engine file manifest.'
Check (([regex]::Matches($source,'Test-FastLlmEngineInstallation')).Count -ge 2) 'Exact installed file set must be verified before and after.'
Check ($source.Contains('Test-FastLlmEnvironmentNameRequiresClearing') -and $source.Contains('New-FastLlmRuntimeSandbox')) 'Probe must reuse normal environment and config isolation.'
Check ($source.Contains('Assert-FastLlmWindowsPrerequisites') -and $source.Contains('AMD_VULKAN_*') -and $source.Contains('normal-targeted-environment-plus-vulkan-vendor-overrides')) 'Native probe must check prerequisites and label extra vendor-environment clearing.'
Check ($source.Contains('ProcessHost') -and $source.Contains('OutputCompleted') -and $source.Contains('OutputTruncated') -and -not $source.Contains('WaitForExit()')) 'Probe must use bounded complete native output.'
Check ($source.Contains('[IO.FileMode]::CreateNew') -and $source.Contains('performanceQualification = $false')) 'Diagnostic must never overwrite or claim qualification.'
Check ($source.Contains('Run as a standard user') -and $source.Contains('20000')) 'Diagnostic must reject elevation and impose a deadline.'
Write-Output "Vulkan capability diagnostic tests passed: $checks"
