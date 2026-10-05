#requires -Version 5.1
# Diagnostic-only worker; the caller must bound its process lifetime and output.
param([Parameter(Mandatory=$true)][string]$InstallRoot)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2

if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) { throw '64-bit Windows is required.' }
$principal = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Standard-user execution is required.' }

$projectRoot = Split-Path $PSScriptRoot -Parent
$catalogPath = Join-Path $projectRoot 'config/catalog.json'
Import-Module (Join-Path $projectRoot 'src/FastLlm.psm1') -Force -DisableNameChecking -ErrorAction Stop
$catalog = Get-FastLlmCatalog -CatalogPath $catalogPath
$asset = $catalog.engine.assets.vulkan
if ($catalog.engine.version -cne 'b10698' -or $asset.enabled -ne $true -or
    $asset.entryPoint -cne 'llama-server.exe' -or
    $asset.sha256 -cne '31e2fe70d4864a4ae6a4e7d8e102ee9203ba18963077e7727c54f9bd6ae3bea5') {
    throw 'Diagnostic permits only the pinned b10698 Vulkan engine.'
}
if (-not (Test-FastLlmEngineInstallation -InstallRoot $InstallRoot -EngineVersion 'b10698' -BackendKey 'vulkan' -Asset $asset)) {
    throw 'Pinned Vulkan engine failed its complete extracted-file manifest.'
}
$server = Get-FastLlmEngineExecutable -InstallRoot $InstallRoot -EngineVersion 'b10698' -BackendKey 'vulkan'
$engineRoot = Split-Path -Parent $server
foreach ($name in @([Environment]::GetEnvironmentVariables().Keys)) {
    $key = [string]$name
    if ($key -like 'LLAMA_*' -or $key -like 'GGML_*' -or $key -like 'VK_*' -or
        $key -like 'VULKAN_*' -or $key -like 'HIP_*' -or $key -like 'ROCM_*' -or
        $key -like 'HSA_*' -or $key -like 'ROCBLAS_*' -or $key -like 'SMITHY_*' -or
        $key -like 'AIP_*' -or $key -in @('MTMD_BACKEND_DEVICE','HF_TOKEN')) {
        [Environment]::SetEnvironmentVariable($key, $null, 'Process')
    }
}
Add-Type -Path (Join-Path $projectRoot 'src/WindowsGgmlVulkanIdentity.cs') -ErrorAction Stop
$devices = @([Bitworks.FastLlm.WindowsGgmlVulkanIdentity]::Read($engineRoot))
$snapshot = [ordered]@{
    schemaVersion = 1
    applicable = $true
    qualified = $false
    source = 'pinned-b10698-ggml-c-abi-independent-worker'
    sourceEngineArchiveSha256 = [string]$asset.sha256
    identityScope = 'independent-process-advisory'
    deviceIdSource = 'VK_EXT_pci_bus_info when supported; otherwise null'
    devices = $devices
    note = 'These are GGML Vulkan backend properties in this isolated worker, not an identity observation from the serving process or a validated DXGI/PnP join.'
}
Write-Output ('FASTLLM_GGML_IDENTITY_JSON:' + ($snapshot | ConvertTo-Json -Depth 5 -Compress))
