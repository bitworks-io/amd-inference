#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$worker = Join-Path (Split-Path $PSScriptRoot -Parent) 'src/WindowsInventory.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($worker, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Windows inventory worker does not parse.' }

# Load only the worker's data function. Its Windows-only entry point is never run here.
$function = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Get-FastLlmWindowsInventorySnapshot'
}, $true)
if (-not $function) { throw 'Missing Windows inventory data function.' }
. ([scriptblock]::Create($function.Extent.Text))

$script:checks = 0
function Check([bool]$condition, [string]$message) {
    if (-not $condition) { throw "FAIL: $message" }
    $script:checks++
    Write-Host "PASS: $message"
}

$script:dxgiDenied = $false
$script:pnpDisplayDenied = $false
$script:cimDenied = $false
$script:nativeHostPartial = $false
$script:adapter = [pscustomobject]@{
    Name = 'AMD Radeon RX 7900 XTX'
    VendorId = 0x1002
    DedicatedVideoBytes = [uint64]25769803776
    Luid = '0000000000000001'
}
function Get-FastLlmDxgiAdapters {
    if ($script:dxgiDenied) { throw 'Simulated DXGI failure.' }
    return $script:adapter
}
function Get-FastLlmPnpDisplayDevices {
    if ($script:pnpDisplayDenied) { throw 'Simulated SetupAPI access denied.' }
    return [pscustomobject]@{
        InstanceId = 'PCI\VEN_1002&DEV_744C&SUBSYS_E4711DA2&REV_C8\TEST'
        Description = 'AMD Radeon RX 7900 XTX'
        DriverVersion = '32.0.31041.1004'
        DriverVersionSource = 'SetupDiGetDevicePropertyW:DEVPKEY_Device_DriverVersion:{a8b865dd-2e3d-4094-ad97-e593a70c75d6}:3'
        DxgiCorrelation = 'unmatched'
    }
}
function Get-FastLlmNativeHostInventory {
    return [ordered]@{
        schemaVersion = 1; kind = 'windows-native-host-inventory'; qualified = $false
        status = $(if ($script:nativeHostPartial) { 'partial' } else { 'captured' })
        physicalMemoryBytes = [ordered]@{ value = [long]34359738368; source = 'GlobalMemoryStatusEx.ullTotalPhys'; status = 'captured' }
        activeLogicalProcessors = [ordered]@{ value = 16; source = 'GetActiveProcessorCount.ALL_PROCESSOR_GROUPS'; status = 'captured' }
        os = [ordered]@{ major = 10; minor = 0; build = 26200; ubr = 9168; architecture = 'x64'; versionSource = 'RtlGetVersion'; ubrSource = 'HKLM.CurrentVersion.UBR'; architectureSource = 'GetNativeSystemInfo'; status = 'captured' }
        advisory = [ordered]@{}
    }
}
function Get-CimInstance {
    [CmdletBinding()]
    param([string]$ClassName, [int]$OperationTimeoutSec)
    if ($script:cimDenied) { throw "Simulated WMI access denied: $ClassName" }
    return [pscustomobject]@{
        Name = $ClassName
        PNPDeviceID = 'PCI\VEN_1002&DEV_0000'
        DriverVersion = 'test'
        DriverDate = [datetime]'2026-01-01'
        Status = 'OK'
        NumberOfCores = 8
        NumberOfLogicalProcessors = 16
        Manufacturer = 'test'
        Model = 'test'
        TotalPhysicalMemory = [uint64]34359738368
        Version = 'test'
        BuildNumber = 'test'
        OSArchitecture = '64-bit'
    }
}

$full = Get-FastLlmWindowsInventorySnapshot
Check (-not $full.partial -and $full.errors.Count -eq 0) 'all successful sections report a complete inventory'
Check ($full.dxgi.Count -eq 1 -and $full.dxgi[0].DedicatedVideoBytes -eq [uint64]25769803776) '64-bit dedicated VRAM is retained'
Check ($full.pnpControllers.Count -eq 1 -and $full.processors.Count -eq 1 -and $null -ne $full.os) 'successful WMI sections remain available'
Check ($full.pnpDisplayDevices.Count -eq 1 -and $full.pnpDisplayDevices[0].DriverVersion -eq '32.0.31041.1004') 'SetupAPI display driver version remains a separate section'
Check ($full.pnpDisplayDevices[0].DxgiCorrelation -eq 'unmatched' -and $full.pnpDisplayDevices[0].DriverVersionSource -match 'DEVPKEY_Device_DriverVersion') 'PnP result records its driver-property source without a DXGI join'
Check ($full.nativeHost.status -eq 'captured' -and $full.nativeHost.physicalMemoryBytes.value -eq [long]34359738368) 'native host section is independent and source-labeled'

$script:cimDenied = $true
$partial = Get-FastLlmWindowsInventorySnapshot
Check ($partial.partial -and $partial.errors.Count -eq 4) 'WMI denial produces four section errors and partial status'
Check ($partial.dxgi.Count -eq 1 -and $partial.dxgi[0].VendorId -eq 0x1002) 'DXGI survives WMI denial'
Check ($partial.pnpDisplayDevices.Count -eq 1 -and $partial.pnpDisplayDevices[0].DriverVersion -eq '32.0.31041.1004') 'SetupAPI survives WMI denial'
Check ((@($partial.errors | ForEach-Object section) -join ',') -eq 'pnpControllers,processors,system,os') 'each denied WMI section is identified'
Check ($null -eq $partial.os -and $partial.pnpControllers.Count -eq 0) 'failed WMI sections are empty without fabricated data'
Check ($partial.nativeHost.status -eq 'captured') 'native host facts remain available when CIM is denied'

$script:nativeHostPartial = $true
$withNativePartial = Get-FastLlmWindowsInventorySnapshot
Check ($withNativePartial.partial -and @($withNativePartial.errors | Where-Object section -eq 'nativeHost').Count -eq 1) 'partial native host is explicitly marked without hiding other sections'
$script:nativeHostPartial = $false

$script:cimDenied = $false
$script:dxgiDenied = $true
$withoutDxgi = Get-FastLlmWindowsInventorySnapshot
Check ($withoutDxgi.partial -and $withoutDxgi.errors.Count -eq 1 -and $withoutDxgi.errors[0].section -eq 'dxgi') 'DXGI failure preserves successful WMI sections'
Check ($withoutDxgi.dxgi.Count -eq 0 -and $withoutDxgi.pnpControllers.Count -eq 1) 'DXGI failure is not mistaken for WMI failure'

$script:dxgiDenied = $false
$script:pnpDisplayDenied = $true
$withoutPnpDisplay = Get-FastLlmWindowsInventorySnapshot
Check ($withoutPnpDisplay.partial -and $withoutPnpDisplay.errors.Count -eq 1 -and $withoutPnpDisplay.errors[0].section -eq 'pnpDisplayDevices') 'SetupAPI failure is optional and section-scoped'
Check ($withoutPnpDisplay.pnpDisplayDevices.Count -eq 0 -and $withoutPnpDisplay.dxgi.Count -eq 1) 'SetupAPI failure does not hide DXGI'

$script:pnpDisplayDenied = $true
$script:dxgiDenied = $true
$script:cimDenied = $true
$script:nativeHostPartial = $true
$caught = $false
try { Get-FastLlmWindowsInventorySnapshot | Out-Null }
catch { $caught = $_.Exception.Message -match 'every section: dxgi, pnpDisplayDevices, nativeHost, pnpControllers, processors, system, os' }
Check $caught 'all sections failing produces an explicit worker failure'

Write-Host "$script:checks inventory checks passed. The Windows-only worker entry point was not executed."
