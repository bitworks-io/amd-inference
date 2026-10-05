#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$cs = Join-Path $root 'src/WindowsVulkanPnPBridge.cs'
$tool = Join-Path $root 'tools/collect-windows-vulkan-pnp-bridge.ps1'
$tokens = $null; $errors = $null
$null = [Management.Automation.Language.Parser]::ParseFile($tool, [ref]$tokens, [ref]$errors)
if (@($errors).Count) { throw ('Bridge script parser errors: ' + (@($errors | ForEach-Object Message) -join ' | ')) }
if (-not ('Bitworks.FastLlm.WindowsVulkanPnPBridge' -as [type])) { Add-Type -Path $cs -ErrorAction Stop }
$passes = 0
function Check($ok, $message) { if (-not $ok) { throw $message }; $script:passes++ }
Check ([Bitworks.FastLlm.WindowsVulkanPnPBridge]::AbiSizes() -ceq '48,64,8,20,276,32,32,20') 'Windows x64 interop struct sizes drifted.'
Check ([Bitworks.FastLlm.WindowsVulkanPnPBridge]::FormatLuid([byte[]]@(0x78,0x56,0x34,0x12,0xef,0xcd,0xab,0x90)) -ceq '90abcdef12345678') 'Vulkan LUID bytes were not normalized to existing DXGI high32-low32 form.'
$source = Get-Content -LiteralPath $cs -Raw
$scriptText = Get-Content -LiteralPath $tool -Raw
$guid = [regex]::Match($source, 'new Guid\("([0-9a-f-]+)"\)')
Check ($guid.Success -and ([Guid]::Parse($guid.Groups[1].Value)).ToString() -ceq 'a8b865dd-2e3d-4094-ad97-e593a70c75d6') 'Device driver property GUID is not the Windows SDK value.'
Check ($source.Contains('VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES') -and
       $source.Contains('VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PCI_BUS_INFO_PROPERTIES_EXT')) 'Vulkan identity chain source contract changed.'
Check ($source.Contains('matches != 1') -and $source.Contains('vulkan-luid-invalid') -and
       $source.Contains('vulkan-node-mask-invalid') -and $source.Contains('ambiguous-vulkan-bdf') -and
       $source.Contains('linked-adapter-luid-unresolved')) 'Ambiguous/invalid Vulkan identity was not rejected.'
Check ($source.Contains('DisplayConfigGetDeviceInfo') -and $source.Contains('SetupDiOpenDeviceInterface') -and
       $source.Contains('SetupDiGetDeviceInterfaceDetail') -and $source.Contains('SetupDiGetDeviceInstanceId') -and
       $source.Contains('pnp-instance-not-amd-pci')) 'Documented LUID to PnP interface chain missing.'
Check ($source.Contains('GetModuleFileNameW') -and $source.Contains('vulkan-loader-provenance-mismatch') -and
       $source.Contains('LOAD_LIBRARY_SEARCH_SYSTEM32')) 'Explicit System32 Vulkan loader check missing.'
Check ($scriptText.Contains('WaitForExit(60000)') -and $scriptText.Contains('OutputCompleted') -and
       $scriptText.Contains('OutputTruncated') -and $scriptText.Contains('ProcessHost')) 'Bounded kill-on-close worker contract missing.'
Check ($scriptText.Contains('GetBytes($json)') -and $scriptText.Contains('$encoded.Length -gt 5600') -and
       $scriptText.Contains('{1,7468}')) 'Transport line can exceed ProcessHost capture bound.'
Check ($scriptText.Contains('Run as a standard Windows user') -and $scriptText.Contains('LabOnly') -and
       $scriptText.Contains('driverIdentityQualified=$false') -and $scriptText.Contains('sameProcess=$false')) 'Private unqualified standard-user contract missing.'
Check ($scriptText.Contains('EnvironmentVariables') -and $scriptText.Contains('VK_|VULKAN_') -and
       $scriptText.Contains("['PATH']")) 'Vulkan override scrub or controlled loader search path missing.'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    $failed = $false
    try { [Bitworks.FastLlm.WindowsVulkanPnPBridge]::Probe('0000:03:00.0') | Out-Null } catch { $failed = $_.Exception.Message -match 'windows-x64-required' }
    Check $failed 'Native bridge unexpectedly ran on a non-Windows host.'
}
Write-Host "Private Vulkan/PnP bridge assertions passed: $passes (no native Windows device call performed)."
