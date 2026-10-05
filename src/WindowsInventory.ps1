#requires -Version 5.1
# Diagnostic-only worker. Parent bounds lifetime and captures JSON without a shell.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2

function Get-FastLlmDxgiAdapters {
    return [Bitworks.FastLlm.WindowsInventory]::Read()
}

function Get-FastLlmPnpDisplayDevices {
    return [Bitworks.FastLlm.WindowsGpuIdentity]::ReadPnP()
}

function Get-FastLlmNativePhysicalMemoryBytes { return [Bitworks.FastLlm.WindowsHostInventory]::ReadPhysicalMemoryBytes() }
function Get-FastLlmNativeActiveLogicalProcessors { return [Bitworks.FastLlm.WindowsHostInventory]::ReadActiveLogicalProcessors() }
function Get-FastLlmNativeOsVersion { return [Bitworks.FastLlm.WindowsHostInventory]::ReadOsVersion() }
function Get-FastLlmNativeArchitecture { return [Bitworks.FastLlm.WindowsHostInventory]::ReadNativeArchitecture() }

function Get-FastLlmBoundedHostString {
    param($Value)
    if ($Value -isnot [string]) { return $null }
    $bounded = $Value.Trim()
    if ($bounded.Length -eq 0 -or $bounded.Length -gt 128 -or $bounded -match '[\x00-\x1f\x7f]') { return $null }
    return $bounded
}

function Get-FastLlmNativeHostInventory {
    # Each fact is independent: a denied registry value must not hide RAM/CPU/OS APIs.
    $memory = [ordered]@{ value = $null; source = 'GlobalMemoryStatusEx.ullTotalPhys'; status = 'unavailable' }
    $logical = [ordered]@{ value = $null; source = 'GetActiveProcessorCount.ALL_PROCESSOR_GROUPS'; status = 'unavailable' }
    $os = [ordered]@{
        major = $null; minor = $null; build = $null; ubr = $null; architecture = $null
        versionSource = 'RtlGetVersion'; ubrSource = 'HKLM.CurrentVersion.UBR'
        architectureSource = 'GetNativeSystemInfo'; status = 'unavailable'
    }
    $cpuNames = [ordered]@{
        value = @(); source = 'HKLM.HARDWARE.CentralProcessor.ProcessorNameString'; status = 'unavailable'
        enumeratedKeys = 0; scanLimit = 256; completeScan = $false
    }
    $manufacturer = [ordered]@{ value = $null; source = 'HKLM.HARDWARE.System.BIOS.SystemManufacturer'; status = 'unavailable' }
    $product = [ordered]@{ value = $null; source = 'HKLM.HARDWARE.System.BIOS.SystemProductName'; status = 'unavailable' }

    try {
        $number = Get-FastLlmNativePhysicalMemoryBytes
        if ($number -is [long] -and $number -gt 0) { $memory.value = $number; $memory.status = 'captured' }
    } catch { }
    try {
        $number = Get-FastLlmNativeActiveLogicalProcessors
        if ($number -is [int] -and $number -gt 0) { $logical.value = $number; $logical.status = 'captured' }
    } catch { }
    try {
        $version = Get-FastLlmNativeOsVersion
        if ($version.Major -gt 0 -and $version.Build -gt 0) {
            $os.major = [int]$version.Major
            $os.minor = [int]$version.Minor
            $os.build = [int]$version.Build
        }
    } catch { }
    try {
        $revision = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name UBR -ErrorAction Stop).UBR
        if ($revision -is [int] -and $revision -ge 0) { $os.ubr = $revision }
    } catch { }
    try {
        $arch = Get-FastLlmNativeArchitecture
        if ($arch -in @('x64','arm64','x86')) { $os.architecture = $arch }
    } catch { }
    $osPieces = @($os.major, $os.minor, $os.build, $os.ubr, $os.architecture)
    $presentPieces = @($osPieces | Where-Object { $null -ne $_ }).Count
    if ($presentPieces -eq 5) { $os.status = 'captured' }
    elseif ($presentPieces -gt 0) { $os.status = 'partial' }

    try {
        $base = 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor'
        $names = New-Object 'System.Collections.Generic.List[string]'
        $keys = @(Get-ChildItem -LiteralPath $base -ErrorAction Stop | Select-Object -First 257)
        $cpuNames.enumeratedKeys = $keys.Count
        $incomplete = ($keys.Count -eq 0 -or $keys.Count -gt $cpuNames.scanLimit)
        if (-not $incomplete) {
            foreach ($key in $keys) {
                if ($key.PSChildName -notmatch '^\d{1,3}$' -or -not $key.PSPath) { $incomplete = $true; break }
            }
        }
        if (-not $incomplete) {
            foreach ($key in @($keys | Sort-Object { [int]$_.PSChildName })) {
                $candidate = $null
                try {
                    $candidate = Get-FastLlmBoundedHostString (Get-ItemProperty -LiteralPath $key.PSPath -Name ProcessorNameString -ErrorAction Stop).ProcessorNameString
                } catch { $incomplete = $true; break }
                if (-not $candidate) { $incomplete = $true; break }
                if (-not $names.Contains($candidate)) {
                    if ($names.Count -ge 4) { $incomplete = $true; break }
                    $names.Add($candidate)
                }
            }
        }
        $cpuNames.value = @($names.ToArray())
        $cpuNames.completeScan = -not $incomplete
        if ($names.Count -gt 0) { $cpuNames.status = $(if ($incomplete) { 'partial' } else { 'captured' }) }
        elseif ($incomplete -and $keys.Count -gt 0) { $cpuNames.status = 'partial' }
    } catch {
        if ($cpuNames.enumeratedKeys -gt 0) { $cpuNames.status = 'partial' }
    }
    $bios = $null
    try { $bios = Get-ItemProperty -LiteralPath 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -ErrorAction Stop } catch { }
    if ($bios) {
        try {
            $value = Get-FastLlmBoundedHostString $bios.SystemManufacturer
            if ($value) { $manufacturer.value = $value; $manufacturer.status = 'captured' }
        } catch { }
        try {
            $value = Get-FastLlmBoundedHostString $bios.SystemProductName
            if ($value) { $product.value = $value; $product.status = 'captured' }
        } catch { }
    }

    $state = if ($memory.status -eq 'captured' -and $logical.status -eq 'captured' -and $os.status -eq 'captured') { 'captured' }
        elseif ($memory.status -eq 'unavailable' -and $logical.status -eq 'unavailable' -and $os.status -eq 'unavailable') { 'unavailable' }
        else { 'partial' }
    return [ordered]@{
        schemaVersion = 1
        kind = 'windows-native-host-inventory'
        qualified = $false
        status = $state
        physicalMemoryBytes = $memory
        activeLogicalProcessors = $logical
        os = $os
        advisory = [ordered]@{ cpuNames = $cpuNames; systemManufacturer = $manufacturer; systemProductName = $product }
    }
}

function Get-FastLlmWindowsInventorySnapshot {
    $errors = New-Object 'System.Collections.Generic.List[object]'
    $successfulSections = 0
    $dxgi = @()
    $pnpDisplayDevices = @()
    $nativeHost = $null
    $controllers = @()
    $processors = @()
    $system = $null
    $operatingSystem = $null

    try {
        $dxgi = @(Get-FastLlmDxgiAdapters)
        $successfulSections++
    }
    catch {
        $errors.Add([pscustomobject]@{ section = 'dxgi'; message = $_.Exception.Message })
    }

    try {
        $pnpDisplayDevices = @(Get-FastLlmPnpDisplayDevices)
        $successfulSections++
    }
    catch {
        $errors.Add([pscustomobject]@{ section = 'pnpDisplayDevices'; message = $_.Exception.Message })
    }

    try {
        $nativeHost = Get-FastLlmNativeHostInventory
        if ($nativeHost.status -eq 'captured') { $successfulSections++ }
        else { $errors.Add([pscustomobject]@{ section = 'nativeHost'; message = 'Native host inventory was incomplete.' }) }
    }
    catch {
        $errors.Add([pscustomobject]@{ section = 'nativeHost'; message = 'Native host inventory unavailable.' })
    }

    try {
        $controllers = @(Get-CimInstance -ClassName Win32_VideoController -OperationTimeoutSec 10 -ErrorAction Stop |
            Select-Object Name, PNPDeviceID, DriverVersion, DriverDate, Status)
        $successfulSections++
    }
    catch {
        $errors.Add([pscustomobject]@{ section = 'pnpControllers'; message = $_.Exception.Message })
    }

    try {
        $processors = @(Get-CimInstance -ClassName Win32_Processor -OperationTimeoutSec 10 -ErrorAction Stop |
            Select-Object Name, NumberOfCores, NumberOfLogicalProcessors)
        $successfulSections++
    }
    catch {
        $errors.Add([pscustomobject]@{ section = 'processors'; message = $_.Exception.Message })
    }

    try {
        $system = Get-CimInstance -ClassName Win32_ComputerSystem -OperationTimeoutSec 10 -ErrorAction Stop |
            Select-Object Manufacturer, Model, TotalPhysicalMemory
        $successfulSections++
    }
    catch {
        $errors.Add([pscustomobject]@{ section = 'system'; message = $_.Exception.Message })
    }

    try {
        $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -OperationTimeoutSec 10 -ErrorAction Stop |
            Select-Object Version, BuildNumber, OSArchitecture
        $successfulSections++
    }
    catch {
        $errors.Add([pscustomobject]@{ section = 'os'; message = $_.Exception.Message })
    }

    if ($successfulSections -eq 0) {
        $failedSections = ($errors | ForEach-Object { $_.section }) -join ', '
        throw "Windows inventory failed in every section: $failedSections."
    }

    return [ordered]@{
        applicable = $true
        qualified = $false
        partial = ($errors.Count -gt 0)
        errors = @($errors.ToArray())
        dxgi = $dxgi
        pnpDisplayDevices = $pnpDisplayDevices
        nativeHost = $nativeHost
        pnpControllers = $controllers
        processors = $processors
        system = $system
        os = $operatingSystem
        note = 'DXGI LUID is boot-scoped. Budget/usage belong to this probe process, not llama-server. SetupAPI PnP display driver versions are keyed by exact PnP instance, not correlated to DXGI or backend adapters. Server residency requires physical validation.'
    }
}

if ($env:OS -ne 'Windows_NT') { throw 'Windows inventory is Windows-only.' }
Add-Type -Path (Join-Path $PSScriptRoot 'WindowsInventory.cs')
Add-Type -Path (Join-Path $PSScriptRoot 'WindowsGpuIdentity.cs')
Add-Type -Path (Join-Path $PSScriptRoot 'WindowsHostInventory.cs')
Get-FastLlmWindowsInventorySnapshot | ConvertTo-Json -Depth 8
