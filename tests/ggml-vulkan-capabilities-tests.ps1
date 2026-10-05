#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'tools/collect-ggml-vulkan-capabilities.ps1')
Add-Type -Path (Join-Path $root 'src/WindowsGgmlVulkanCapabilities.cs') -ErrorAction Stop
$checks = 0
function Check([bool]$Value,[string]$Message) { if (-not $Value) { throw $Message }; $script:checks++ }
function Reject([scriptblock]$Action,[string]$Message) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    Check $failed $Message
}

$device = [pscustomobject]@{
    DeviceName='Vulkan0';Description='AMD Radeon RX 7900 XTX';DeviceId='0000:03:00.0';DeviceIdStatus='bdf-reported'
    TotalMiB=[long]24560;FreeMiB=[long]23123;DriverName='AMD proprietary driver'
    Uma=$false;Fp16='1';Bf16=$true;Fp4=$false;WarpSize=64
    SharedMemoryBytes=32768;IntegerDotProduct=$true;MatrixCores='KHR_coopmat'
}
$snapshot = [pscustomobject]@{ReportedDeviceCount=1;Devices=@($device)}
Assert-GgmlCapabilitySnapshot -Snapshot $snapshot
Check $true 'Valid bounded GGML capability snapshot should pass.'
$device.MatrixCores = 'made-up'; Reject { Assert-GgmlCapabilitySnapshot $snapshot } 'Unknown matrix mode must fail.'
$device.MatrixCores = 'KHR_coopmat'
$device.DriverName = 'AMD proprietary driver;secret'; Reject { Assert-GgmlCapabilitySnapshot $snapshot } 'Free-form driver name must fail.'
$device.DriverName = 'AMD proprietary driver'
$device.TotalMiB = '24560'; Reject { Assert-GgmlCapabilitySnapshot $snapshot } 'String memory value must fail.'
$device.TotalMiB = [long]24560
$device.FreeMiB = [long]24561; Reject { Assert-GgmlCapabilitySnapshot $snapshot } 'Impossible free memory must fail.'
$device.FreeMiB = [long]23123
$device.DeviceId = 'PCI\\VEN_1002'; Reject { Assert-GgmlCapabilitySnapshot $snapshot } 'Unvalidated free-form identity must fail.'
$device.DeviceId = '0000:03:00.0'
$device.DeviceIdStatus = 'unavailable'; Reject { Assert-GgmlCapabilitySnapshot $snapshot } 'Reported BDF cannot have unavailable status.'
$device.DeviceId = $null; Assert-GgmlCapabilitySnapshot $snapshot
$device.DeviceIdStatus = 'invalid-format'; Assert-GgmlCapabilitySnapshot $snapshot
$device.DeviceIdStatus = 'bdf-reported'; Reject { Assert-GgmlCapabilitySnapshot $snapshot } 'A BDF claim needs an actual BDF.'
$device.DeviceId = '0000:03:00.0'; $device.DeviceIdStatus = 'bdf-reported'
$snapshot.ReportedDeviceCount = 2; Reject { Assert-GgmlCapabilitySnapshot $snapshot } 'Device count mismatch must fail.'
$snapshot.ReportedDeviceCount = 1
$record = [ordered]@{schemaVersion=1;kind='fastllm-private-ggml-vulkan-capability-worker';
    qualified=$false;servingDeviceBinding=$false;modelLoaded=$false;snapshot=$snapshot}
$json = $record | ConvertTo-Json -Compress -Depth 7
$marker = 'FASTLLM_GGML_CAPABILITY_JSON:' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
$decoded = ConvertFrom-GgmlCapabilityWorkerOutput -Text $marker -Truncated:$false
Check ($decoded.snapshot.Devices.Count -eq 1 -and $decoded.snapshot.Devices[0].MatrixCores -ceq 'KHR_coopmat') 'Complete worker transport should round-trip.'
Reject { ConvertFrom-GgmlCapabilityWorkerOutput -Text "$marker`n$marker" -Truncated:$false } 'Duplicate worker markers must fail.'
Reject { ConvertFrom-GgmlCapabilityWorkerOutput -Text $marker -Truncated:$true } 'Output-truncated worker marker must fail.'
Reject { ConvertFrom-GgmlCapabilityWorkerOutput -Text 'no marker' -Truncated:$false } 'Missing worker marker must fail.'
Check ((Get-GgmlCapabilityWorkerFailureCode -Text "FASTLLM_GGML_CAPABILITY_ERROR:isolation`n") -ceq 'isolation') 'A single bounded worker stage should be classified.'
Check ((Get-GgmlCapabilityWorkerFailureCode -Text "FASTLLM_GGML_CAPABILITY_ERROR:isolation`nFASTLLM_GGML_CAPABILITY_ERROR:native-read-other`n") -ceq 'no-unique-stage') 'Ambiguous failure stages must not be trusted.'
Check ((Get-GgmlCapabilityWorkerFailureCode -Text "FASTLLM_GGML_CAPABILITY_ERROR:isolation`nFASTLLM_GGML_CAPABILITY_ERROR:unreviewed`n") -ceq 'no-unique-stage') 'An unreviewed second marker must invalidate the failure record.'
Check ((Get-GgmlCapabilityWorkerFailureCode -Text 'FASTLLM_GGML_CAPABILITY_ERROR:C:\private\user') -ceq 'no-unique-stage') 'Failure reporting must not relay free-form paths.'
Check ((Get-GgmlCapabilityWorkerFailureCode -Text 'FASTLLM_GGML_CAPABILITY_ERROR:native-read-set-incomplete') -ceq 'native-read-set-incomplete') 'Reviewed callback-set failure should survive bounded transport.'
Check ((Get-GgmlCapabilityNativeFailureCode -Exception ([Exception]::new('PowerShell wrapper', [IO.InvalidDataException]::new('GGML Vulkan callback did not provide a complete device set.')))) -ceq 'native-read-set-incomplete') 'Wrapped reviewed native errors must map to fixed codes.'
Check ((Get-GgmlCapabilityNativeFailureCode -Exception ([Exception]::new('C:\private\secret'))) -ceq 'native-read-other') 'Unreviewed native error text must never appear in code.'
Check ((Get-GgmlCapabilityNativeFailureCode -Exception ([Exception]::new('ggml vulkan callback did not provide a complete device set.'))) -ceq 'native-read-other') 'Reviewed native message matching must be ordinal and exact.'
Check ((Get-GgmlCapabilityNativeFailureCode -Exception ([Exception]::new('Required GGML ABI symbol is absent: ggml_backend_load'))) -ceq 'native-read-symbol') 'Only fixed symbol names can be classified.'
$record.qualified = $true
$badMarker = 'FASTLLM_GGML_CAPABILITY_JSON:' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Compress -Depth 7)))
Reject { ConvertFrom-GgmlCapabilityWorkerOutput -Text $badMarker -Truncated:$false } 'Worker may not claim qualification.'

$source = Get-Content -LiteralPath (Join-Path $root 'tools/collect-ggml-vulkan-capabilities.ps1') -Raw
$native = Get-Content -LiteralPath (Join-Path $root 'src/WindowsGgmlVulkanCapabilities.cs') -Raw
Check ($source.Contains('65b8f2f9ca340dab273274086aba9e8f01cb14a2b8cf4bb65c5ed5f6e779caa6') -and
       ((Get-FileHash -LiteralPath (Join-Path $root 'config/catalog.json') -Algorithm SHA256).Hash.ToLowerInvariant() -ceq '65b8f2f9ca340dab273274086aba9e8f01cb14a2b8cf4bb65c5ed5f6e779caa6')) 'Exact reviewed catalog, including manifest, must stay pinned.'
Check (([regex]::Matches($source,'Test-FastLlmEngineInstallation')).Count -ge 3 -and $source.Contains('Assert-FastLlmWindowsPrerequisites')) 'Both processes must verify exact installed manifest and Windows prerequisites.'
Check ($source.Contains('OutputCompleted') -and $source.Contains('OutputTruncated') -and $source.Contains('WaitForExit(100)') -and -not $source.Contains('WaitForExit()')) 'Native worker and output completion must be deadline-bounded.'
Check ($source.Contains('[IO.FileMode]::CreateNew') -and $source.Contains('servingDeviceBinding=$false') -and $source.Contains('modelLoaded=$false')) 'Fresh report must make no serving or model claim.'
Check ($source.Contains('Test-FastLlmEnvironmentNameRequiresClearing') -and $source.Contains('APPDATA') -and $source.Contains('PROGRAMDATA')) 'Worker must use isolated config and environment.'
Check ($source.Contains('FASTLLM_GGML_CAPABILITY_RUN_TOKEN') -and $source.Contains('GGML capability worker requires its supervised parent invocation.') -and $source.Contains('GGML capability worker did not receive its isolated environment.')) 'Accidental direct worker calls and unisolated worker environment must fail.'
Check ($source.Contains('FASTLLM_GGML_CAPABILITY_ERROR:') -and $source.Contains('output-incomplete') -and $source.Contains('output-truncated') -and -not $source.Contains('throw $_')) 'Worker failures must expose only bounded stage codes, not raw output.'
Check ($source.Contains('Get-GgmlCapabilityNativeFailureCode') -and $source.Contains('native-read-other')) 'Native-read detail must be limited to reviewed fixed categories.'
Check ($native.Contains('GetModuleHandleW') -and $native.Contains('SetDefaultDllDirectories') -and $native.Contains('AddDllDirectory') -and $native.Contains('LoadLibraryExW')) 'Native loader must reject preloaded GGML and restrict library search.'
Check ($native.Contains('ggml_log_get') -and $native.Contains('ggml_log_set') -and $native.IndexOf('logSet(callbackPointer', [StringComparison]::Ordinal) -lt $native.IndexOf('load(path)', [StringComparison]::Ordinal)) 'GGML callback must be attached before exact Vulkan backend load.'
Check ($native.Contains('ggml_backend_load') -and $native.Contains('ggml_backend_dev_get_props') -and -not $native.Contains('ggml_backend_dev_init')) 'Only GGML C-ABI enumeration is permitted; no model or backend stream.'
Check ($native.Contains('GC.KeepAlive(collector)') -and $native.Contains('logSet(previousCallback') -and $native.Contains('messages.Count >= 10')) 'Callback lifetime, restoration, and bounded capture must be explicit.'
Check ($native.Contains('RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100)') -and $native.Contains('foundCount > 8')) 'Capability parsing must be bounded and reject excess devices.'
Check ($native.Contains('pciStatus = "unavailable"') -and $native.Contains('pciStatus = "invalid-format"; pci = null') -and $native.Contains('DeviceIdStatus = pciStatus')) 'Absent or invalid PCI ID must not erase capability evidence or claim identity.'
if ($env:OS -ne 'Windows_NT') {
    Reject { [Bitworks.FastLlm.WindowsGgmlVulkanCapabilities]::Read('/not/windows') } 'Native capability worker must reject non-Windows hosts.'
}
Write-Output "GGML Vulkan capability tests passed: $checks"
