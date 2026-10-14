#requires -Version 5.1
# Read-only, standard-user Windows probe (acceptance row W03): per Vulkan physical device, in raw
# vkEnumeratePhysicalDevices() order, join Vulkan LUID -> DXGI adapter -> D3DKMT address -> SetupAPI
# display device. Each hop records success or a precise failure; a join is 'unique' only when every hop
# matched exactly one candidate. Nothing is guessed from names. This is a separate-process snapshot:
# it never starts or stops a process, never sets an environment variable, never creates a Vulkan logical
# device, and does not bind to any server process.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutputPath,
    # Re-read only the memory budget numbers this many times (no identity re-collection).
    [ValidateRange(1, 60)][int]$RepeatCount = 1,
    [ValidateRange(500, 10000)][int]$RepeatIntervalMs = 1000,
    # Test seam: define the helper functions and return before any host guard or collection.
    [switch]$LibraryOnly
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Assert-VulkanLuidJoinOutputPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) {
        throw 'OutputPath must be an absolute local file path.'
    }
    $full = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetExtension($full) -ine '.json') { throw 'OutputPath must be a .json file.' }
    if ($env:OS -eq 'Windows_NT' -and [IO.Path]::GetPathRoot($full) -notmatch '^[A-Za-z]:\\$') {
        throw 'OutputPath must be on a local drive.'
    }
    $parentPath = [IO.Path]::GetDirectoryName($full)
    $parent = Get-Item -LiteralPath $parentPath -ErrorAction Stop
    if (-not $parent.PSIsContainer) { throw 'Output parent is not a directory.' }
    $cursor = [IO.Path]::GetPathRoot($parentPath)
    $segments = $parentPath.Substring($cursor.Length).Split([IO.Path]::DirectorySeparatorChar)
    foreach ($segment in @('') + $segments) {
        if ($segment.Length -gt 0) { $cursor = Join-Path $cursor $segment }
        $part = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if (($part.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Output path traverses a reparse point.'
        }
    }
    if ([IO.File]::Exists($full) -or [IO.Directory]::Exists($full)) {
        throw 'OutputPath already exists; choose a fresh report filename.'
    }
    return $full
}

function Assert-VulkanLuidJoinRepeatOptions {
    param([int]$Count, [int]$IntervalMs)
    if ($Count -lt 1 -or $Count -gt 60) { throw 'RepeatCount must be between 1 and 60.' }
    if ($IntervalMs -lt 500 -or $IntervalMs -gt 10000) { throw 'RepeatIntervalMs must be between 500 and 10000.' }
}

function Get-VulkanLuidJoinFileSha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# --- location / instance-id parsing (exact, case-sensitive, English SetupAPI format only) ---
function ConvertFrom-VulkanLuidJoinLocation {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text) -or $Text.Length -gt 128) { return $null }
    $segment = 0; $explicit = $false
    if ($Text -cmatch '^PCI segment ([0-9]{1,5}) bus ([0-9]{1,3}), device ([0-9]{1,2}), function ([0-9])$') {
        $segment = [int]$Matches[1]; $bus = [int]$Matches[2]; $device = [int]$Matches[3]; $function = [int]$Matches[4]; $explicit = $true
    } elseif ($Text -cmatch '^PCI bus ([0-9]{1,3}), device ([0-9]{1,2}), function ([0-9])$') {
        $bus = [int]$Matches[1]; $device = [int]$Matches[2]; $function = [int]$Matches[3]
    } else { return $null }
    if ($segment -gt 65535 -or $bus -gt 255 -or $device -gt 31 -or $function -gt 7) { return $null }
    return [pscustomobject]@{ segment = $segment; segmentExplicit = $explicit; bus = $bus; device = $device; function = $function }
}

function ConvertFrom-VulkanLuidJoinInstanceId {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text) -or $Text.Length -gt 512 -or
        $Text -cnotmatch '^PCI\\VEN_([0-9A-Fa-f]{4})&DEV_([0-9A-Fa-f]{4})(?:&|\\)') { return $null }
    return [pscustomobject]@{ vendorId = [Convert]::ToUInt32($Matches[1], 16); deviceId = [Convert]::ToUInt32($Matches[2], 16) }
}

function New-VulkanLuidJoinHop {
    param([string]$Status, [string]$Reason, [int]$Candidates = 0)
    return [pscustomobject]@{ status = $Status; reason = $Reason; candidates = $Candidates }
}

function Test-VulkanLuidJoinSoftwareAdapter {
    param($Adapter)
    # DXGI_ADAPTER_FLAG_SOFTWARE = 2 (dxgi.h); 0x1414 is Microsoft (WARP / Basic Render Driver).
    if ((([uint32]$Adapter.flags) -band 2) -ne 0) { return 'dxgi-software-flag' }
    if ([uint32]$Adapter.vendorId -eq 0x1414) { return 'microsoft-software-adapter-vendor' }
    return $null
}

# Join over normalized observation rows. Pure function: no host access.
function Join-VulkanLuidDevices {
    param(
        [AllowEmptyCollection()][object[]]$Vulkan,
        [AllowEmptyCollection()][object[]]$Dxgi,
        [AllowEmptyCollection()][object[]]$Kmt,
        [AllowEmptyCollection()][object[]]$SetupApi,
        [string]$DxgiError,
        [string]$SetupApiError
    )
    if (@($Vulkan).Count -gt 64 -or @($Dxgi).Count -gt 64 -or @($Kmt).Count -gt 64 -or @($SetupApi).Count -gt 128) {
        throw 'Vulkan LUID join snapshot exceeds bounded counts.'
    }
    $vulkanRows = @($Vulkan); $dxgiRows = @($Dxgi); $kmtRows = @($Kmt); $pnpRows = @($SetupApi)
    $parsedPnp = @()
    foreach ($p in $pnpRows) {
        $parsedPnp += [pscustomobject]@{
            record   = $p
            location = (ConvertFrom-VulkanLuidJoinLocation ([string]$p.locationInfo))
            ids      = (ConvertFrom-VulkanLuidJoinInstanceId ([string]$p.instanceId))
        }
    }
    $results = @()
    foreach ($v in $vulkanRows) {
        $hops = [ordered]@{ vulkan = $null; dxgi = $null; kmt = $null; setupApi = $null }
        $dxgiHit = $null; $kmtHit = $null; $pnpHit = $null
        $failed = $null

        # Hop 1: Vulkan identity must carry a valid, unique, single-node LUID.
        $luid = [string]$v.deviceLuid
        if (-not [bool]$v.deviceLuidValid) {
            $hops.vulkan = New-VulkanLuidJoinHop 'unavailable' 'vulkan-luid-invalid'
        } elseif ($luid -cnotmatch '^[0-9a-f]{16}$') {
            $hops.vulkan = New-VulkanLuidJoinHop 'unavailable' 'vulkan-luid-malformed'
        } else {
            $sameLuid = @($vulkanRows | Where-Object { [bool]$_.deviceLuidValid -and ([string]$_.deviceLuid) -ceq $luid })
            if ($sameLuid.Count -gt 1) {
                $hops.vulkan = New-VulkanLuidJoinHop 'ambiguous' 'vulkan-luid-shared-by-multiple-devices' $sameLuid.Count
            } elseif ([uint32]$v.deviceNodeMask -ne 1) {
                $hops.vulkan = New-VulkanLuidJoinHop 'ambiguous' 'vulkan-node-mask-not-single-node' 1
            } else {
                $hops.vulkan = New-VulkanLuidJoinHop 'ok' $null 1
            }
        }

        # Hop 2: DXGI adapter with the same LUID (exact, never by name).
        if ($hops.vulkan.status -ne 'ok') {
            $hops.dxgi = New-VulkanLuidJoinHop 'skipped' 'previous-hop-not-ok'
        } else {
            $matches2 = @($dxgiRows | Where-Object { ([string]$_.adapterLuid).ToLowerInvariant() -ceq $luid })
            if ($matches2.Count -eq 0) {
                $reason = 'dxgi-luid-not-found'
                if ($DxgiError) { $reason = 'dxgi-enumeration-failed' }
                $hops.dxgi = New-VulkanLuidJoinHop 'unavailable' $reason 0
            } elseif ($matches2.Count -gt 1) {
                $hops.dxgi = New-VulkanLuidJoinHop 'ambiguous' 'dxgi-luid-shared-by-multiple-adapters' $matches2.Count
            } elseif (Test-VulkanLuidJoinSoftwareAdapter $matches2[0]) {
                $hops.dxgi = New-VulkanLuidJoinHop 'unavailable' 'dxgi-adapter-software-excluded' 1
            } elseif ([uint32]$matches2[0].vendorId -ne [uint32]$v.vendorId -or [uint32]$matches2[0].deviceId -ne [uint32]$v.deviceId) {
                $hops.dxgi = New-VulkanLuidJoinHop 'ambiguous' 'vulkan-dxgi-pci-id-mismatch' 1
            } else {
                $dxgiHit = $matches2[0]
                $hops.dxgi = New-VulkanLuidJoinHop 'ok' $null 1
            }
        }

        # Hop 3: D3DKMT adapter address for that LUID (bus/device/function, no PCI segment).
        if ($hops.dxgi.status -ne 'ok') {
            $hops.kmt = New-VulkanLuidJoinHop 'skipped' 'previous-hop-not-ok'
        } else {
            $k = @($kmtRows | Where-Object { ([string]$_.luid).ToLowerInvariant() -ceq $luid })
            if ($k.Count -eq 0) {
                $hops.kmt = New-VulkanLuidJoinHop 'unavailable' 'kmt-not-queried' 0
            } elseif ($k.Count -gt 1) {
                $hops.kmt = New-VulkanLuidJoinHop 'ambiguous' 'kmt-luid-duplicate' $k.Count
            } elseif ($k[0].error) {
                $hops.kmt = New-VulkanLuidJoinHop 'unavailable' ('kmt-' + [string]$k[0].error) 1
            } elseif ($null -eq $k[0].bus -or $null -eq $k[0].device -or $null -eq $k[0].function) {
                $hops.kmt = New-VulkanLuidJoinHop 'unavailable' 'kmt-address-missing' 1
            } else {
                $shared = @($kmtRows | Where-Object {
                    ([string]$_.luid).ToLowerInvariant() -cne $luid -and -not $_.error -and $null -ne $_.bus -and
                    [int]$_.bus -eq [int]$k[0].bus -and [int]$_.device -eq [int]$k[0].device -and [int]$_.function -eq [int]$k[0].function })
                if ($shared.Count -gt 0) {
                    $hops.kmt = New-VulkanLuidJoinHop 'ambiguous' 'kmt-address-shared-with-other-adapter' ($shared.Count + 1)
                } elseif ($v.pciBusInfoAdvertised -and $null -ne $v.pciBusInfo -and
                          ([int]$v.pciBusInfo.bus -ne [int]$k[0].bus -or [int]$v.pciBusInfo.device -ne [int]$k[0].device -or
                           [int]$v.pciBusInfo.function -ne [int]$k[0].function)) {
                    $hops.kmt = New-VulkanLuidJoinHop 'ambiguous' 'vulkan-pci-bus-info-disagrees-with-kmt' 1
                } else {
                    $kmtHit = $k[0]
                    $hops.kmt = New-VulkanLuidJoinHop 'ok' $null 1
                }
            }
        }

        # Hop 4: SetupAPI display-class device whose LocationInfo bus/device/function matches.
        if ($hops.kmt.status -ne 'ok') {
            $hops.setupApi = New-VulkanLuidJoinHop 'skipped' 'previous-hop-not-ok'
        } elseif ($SetupApiError) {
            $hops.setupApi = New-VulkanLuidJoinHop 'unavailable' 'setupapi-enumeration-failed' 0
        } else {
            $m = @($parsedPnp | Where-Object {
                $_.location -and $_.location.bus -eq [int]$kmtHit.bus -and $_.location.device -eq [int]$kmtHit.device -and
                $_.location.function -eq [int]$kmtHit.function })
            $unlocated = @($parsedPnp | Where-Object { -not $_.location })
            if ($m.Count -eq 0) {
                $reason = 'setupapi-no-location-match'
                if ($unlocated.Count -gt 0) { $reason = 'setupapi-no-location-match-unlocated-devices-present' }
                $hops.setupApi = New-VulkanLuidJoinHop 'unavailable' $reason 0
            } elseif ($m.Count -gt 1) {
                $hops.setupApi = New-VulkanLuidJoinHop 'ambiguous' 'setupapi-multiple-location-matches' $m.Count
            } elseif (-not $m[0].ids) {
                $hops.setupApi = New-VulkanLuidJoinHop 'unavailable' 'pnp-instance-id-not-pci' 1
            } elseif ($m[0].ids.vendorId -ne [uint32]$dxgiHit.vendorId -or $m[0].ids.deviceId -ne [uint32]$dxgiHit.deviceId) {
                $hops.setupApi = New-VulkanLuidJoinHop 'ambiguous' 'pnp-pci-id-mismatch' 1
            } elseif (@($unlocated | Where-Object { $_.ids -and $_.ids.vendorId -eq $m[0].ids.vendorId -and $_.ids.deviceId -eq $m[0].ids.deviceId }).Count -gt 0) {
                $hops.setupApi = New-VulkanLuidJoinHop 'ambiguous' 'setupapi-unlocated-peer-with-same-pci-ids' 2
            } elseif ($v.pciBusInfoAdvertised -and $null -ne $v.pciBusInfo -and $m[0].location.segmentExplicit -and
                      [int]$v.pciBusInfo.domain -ne $m[0].location.segment) {
                $hops.setupApi = New-VulkanLuidJoinHop 'ambiguous' 'pci-segment-mismatch' 1
            } elseif ([string]::IsNullOrWhiteSpace([string]$m[0].record.driverVersion)) {
                $hops.setupApi = New-VulkanLuidJoinHop 'unavailable' 'driver-version-unavailable' 1
            } else {
                $pnpHit = $m[0].record
                $hops.setupApi = New-VulkanLuidJoinHop 'ok' $null 1
            }
        }

        $status = 'unique'; $failedHop = $null; $reason = $null
        foreach ($name in @('vulkan', 'dxgi', 'kmt', 'setupApi')) {
            if ($hops[$name].status -ne 'ok') {
                $failedHop = $name; $reason = $hops[$name].reason
                if ($hops[$name].status -eq 'ambiguous') { $status = 'ambiguous' } else { $status = 'unavailable' }
                break
            }
        }
        $row = [ordered]@{
            vulkanIndex      = [int]$v.index
            deviceName       = [string]$v.deviceName
            status           = $status
            failedHop        = $failedHop
            reason           = $reason
            hops             = [pscustomobject]$hops
            dxgiAdapterIndex = $null
            kmtAddress       = $null
            pnpInstanceId    = $null
            hardwareIds      = $null
            driverVersion    = $null
            driverProvider   = $null
            pciSegmentKnown  = $false
        }
        if ($status -eq 'unique') {
            $row.dxgiAdapterIndex = [int]$dxgiHit.index
            $row.kmtAddress = [pscustomobject]@{ bus = [int]$kmtHit.bus; device = [int]$kmtHit.device; function = [int]$kmtHit.function; segmentKnown = $false }
            $row.pnpInstanceId = [string]$pnpHit.instanceId
            $row.hardwareIds = @($pnpHit.hardwareIds)
            $row.driverVersion = [string]$pnpHit.driverVersion
            $row.driverProvider = [string]$pnpHit.driverProvider
            $row.pciSegmentKnown = [bool]($v.pciBusInfoAdvertised -and $null -ne $v.pciBusInfo)
        }
        $results += [pscustomobject]$row
    }
    return @($results)
}

# --- normalization of .NET observation objects into plain rows ---
function ConvertTo-VulkanLuidJoinVulkanRow {
    param($Device)
    $pci = $null
    if ($Device.PciBusInfoAdvertised -and $null -ne $Device.PciBus) {
        $pci = [pscustomobject]@{ domain = [int]$Device.PciDomain; bus = [int]$Device.PciBus; device = [int]$Device.PciDevice; function = [int]$Device.PciFunction }
    }
    return [pscustomobject][ordered]@{
        index = [int]$Device.Index; deviceUuid = $Device.DeviceUuid; driverUuid = $Device.DriverUuid
        deviceLuid = $Device.DeviceLuid; deviceLuidValid = [bool]$Device.DeviceLuidValid; deviceNodeMask = [uint32]$Device.DeviceNodeMask
        vendorId = [uint32]$Device.VendorId; deviceId = [uint32]$Device.DeviceId; deviceName = $Device.DeviceName
        driverVersionRaw = [uint32]$Device.DriverVersionRaw; apiVersionRaw = [uint32]$Device.ApiVersionRaw; apiVersion = $Device.ApiVersion
        deviceType = [int]$Device.DeviceType; deviceTypeName = $Device.DeviceTypeName
        driverPropertiesAdvertised = [bool]$Device.DriverPropertiesAdvertised
        driverId = $Device.DriverId; driverName = $Device.DriverName; driverInfo = $Device.DriverInfo
        pciBusInfoAdvertised = [bool]$Device.PciBusInfoAdvertised; pciBusInfo = $pci
        extensionError = $Device.ExtensionError
        storageBuffer16BitAccess = $Device.StorageBuffer16BitAccess
        storageBuffer16BitAccessReason = $Device.StorageBuffer16BitAccessReason
    }
}

function ConvertTo-VulkanLuidJoinDxgiRow {
    param($Adapter)
    $row = [pscustomobject][ordered]@{
        index = [int]$Adapter.Index; description = $Adapter.Description; vendorId = [uint32]$Adapter.VendorId
        deviceId = [uint32]$Adapter.DeviceId; subSysId = [uint32]$Adapter.SubSysId; revision = [uint32]$Adapter.Revision
        dedicatedVideoMemory = [uint64]$Adapter.DedicatedVideoMemory; adapterLuid = $Adapter.AdapterLuid
        flags = [uint32]$Adapter.Flags; software = $false; softwareReason = $null
    }
    $why = Test-VulkanLuidJoinSoftwareAdapter $row
    if ($why) { $row.software = $true; $row.softwareReason = $why }
    return $row
}

function ConvertTo-VulkanLuidJoinSetupApiRow {
    param($Record)
    return [pscustomobject][ordered]@{
        instanceId = $Record.InstanceId; description = $Record.Description; locationInfo = $Record.LocationInfo
        locationError = $Record.LocationError; hardwareIds = @($Record.HardwareIds); hardwareIdsError = $Record.HardwareIdsError
        driverVersion = $Record.DriverVersion; driverVersionError = $Record.DriverVersionError; driverProvider = $Record.DriverProvider
        driverVersionSource = 'SetupDiGetDevicePropertyW:DEVPKEY_Device_DriverVersion:{a8b865dd-2e3d-4094-ad97-e593a70c75d6}:3'
    }
}

function ConvertTo-VulkanLuidJoinSegmentRow {
    param($Segment)
    if ($null -eq $Segment) { return $null }
    $row = [ordered]@{ group = $Segment.Group; status = $Segment.Status; hresult = $Segment.Hresult
        budgetBytes = $null; currentUsageBytes = $null; availableForReservationBytes = $null; currentReservationBytes = $null }
    if ($Segment.Status -ceq 'ok') {
        $row.budgetBytes = [uint64]$Segment.Budget; $row.currentUsageBytes = [uint64]$Segment.CurrentUsage
        $row.availableForReservationBytes = [uint64]$Segment.AvailableForReservation; $row.currentReservationBytes = [uint64]$Segment.CurrentReservation
    }
    return [pscustomobject]$row
}

# Normalizes one native budget sample. InitialVulkanRows (identity snapshot) lets each repeat confirm that the
# raw enumeration order still carries the same deviceUUID/LUID at every index.
function ConvertTo-VulkanLuidJoinBudgetSample {
    param($Sample, [int]$SampleIndex, [AllowEmptyCollection()][object[]]$InitialVulkanRows = @())
    $initial = @($InitialVulkanRows)
    $dxgi = @()
    foreach ($d in @($Sample.Dxgi)) {
        $dxgi += [pscustomobject][ordered]@{
            adapterIndex = [int]$d.AdapterIndex; adapterLuid = $d.AdapterLuid; timestampUtc = $d.TimestampUtc
            adapter3Status = $d.Adapter3Status; adapter3Hresult = $d.Adapter3Hresult
            local = (ConvertTo-VulkanLuidJoinSegmentRow $d.Local); nonLocal = (ConvertTo-VulkanLuidJoinSegmentRow $d.NonLocal)
        }
    }
    $vulkan = @()
    foreach ($v in @($Sample.Vulkan)) {
        $heaps = @()
        foreach ($h in @($v.Heaps)) {
            $heaps += [pscustomobject][ordered]@{
                heapIndex = [int]$h.HeapIndex; sizeBytes = [uint64]$h.Size; flags = [uint32]$h.Flags; deviceLocal = [bool]$h.DeviceLocal
                heapBudgetBytes = [uint64]$h.HeapBudget; heapUsageBytes = [uint64]$h.HeapUsage
            }
        }
        $match = $null
        $ref = @($initial | Where-Object { [int]$_.index -eq [int]$v.Index })
        if ($ref.Count -eq 1) {
            $match = (([string]$ref[0].deviceUuid) -ceq ([string]$v.DeviceUuid) -and ([string]$ref[0].deviceLuid) -ceq ([string]$v.DeviceLuid))
        }
        $vulkan += [pscustomobject][ordered]@{
            index = [int]$v.Index; deviceUuid = $v.DeviceUuid; deviceLuid = $v.DeviceLuid; timestampUtc = $v.TimestampUtc
            memoryBudgetAdvertised = [bool]$v.MemoryBudgetAdvertised; status = $v.Status; heaps = $heaps
            identityMatchesInitialEnumeration = $match
        }
    }
    return [pscustomobject][ordered]@{
        sampleIndex = $SampleIndex; timestampUtc = $Sample.TimestampUtc; dxgi = $dxgi; vulkan = $vulkan
        errors = [pscustomobject]@{ dxgi = $Sample.DxgiError; vulkan = $Sample.VulkanError }
    }
}

function New-VulkanLuidJoinReport {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Devices,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$DxgiAdapters,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$KmtAddresses,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$SetupApiDevices,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Joins,
        [Parameter(Mandatory = $true)][string]$HostName,
        [Parameter(Mandatory = $true)][hashtable]$SourceSha256,
        [Parameter(Mandatory = $true)][hashtable]$CollectionErrors,
        [int]$DedicatedGpuCount = 0,
        [string]$VulkanLoaderPath,
        [AllowEmptyCollection()][object[]]$BudgetSamples = @(),
        [int]$RepeatCount = 1,
        [int]$RepeatIntervalMs = 1000,
        [datetime]$Now = ([datetime]::UtcNow)
    )
    $joins = @($Joins)
    return [ordered]@{
        schema                 = 'fastllm.vulkan-luid-join.v1'
        recordedAtUtc          = $Now.ToUniversalTime().ToString('o')
        hostName               = $HostName
        sameProcessAsServer    = $false
        servingDeviceBound     = $false
        qualified              = $false
        collector              = [ordered]@{ sourceSha256 = $SourceSha256; vulkanLoaderPath = $VulkanLoaderPath }
        collectionErrors       = $CollectionErrors
        defaultSelection       = [ordered]@{
            dedicatedGpuCount = $DedicatedGpuCount
            note = 'Informational: Vulkan devices of type discrete or integrated, no environment variable set. llama.cpp b10698 additionally deduplicates by deviceUUID/LUID and applies its own support check, which is not reproduced here.'
        }
        repeat                 = [ordered]@{ count = $RepeatCount; intervalMs = $RepeatIntervalMs }
        joinSummary            = [ordered]@{
            unique      = @($joins | Where-Object { $_.status -eq 'unique' }).Count
            ambiguous   = @($joins | Where-Object { $_.status -eq 'ambiguous' }).Count
            unavailable = @($joins | Where-Object { $_.status -eq 'unavailable' }).Count
        }
        devices                = @($Devices)
        dxgiAdapters           = @($DxgiAdapters)
        kmtAddresses           = @($KmtAddresses)
        setupApiDisplayDevices = @($SetupApiDevices)
        joins                  = $joins
        budgetSamples          = @($BudgetSamples)
        note                   = 'Separate-process snapshot in raw vkEnumeratePhysicalDevices order. It does not prove that a later server process used any listed device; repeat the probe and verify inside the server. Memory budget samples (DXGI IDXGIAdapter3::QueryVideoMemoryInfo, Vulkan VK_EXT_memory_budget) report THIS probe process''s own usage and the OS budget available to it. A drop in LOCAL Budget or heapBudget while another process (the inference server) holds VRAM is an indirect, adapter-level occupancy signal; it is not per-process attribution and not proof of which allocations are resident.'
    }
}

function Write-VulkanLuidJoinReport {
    param([Parameter(Mandatory = $true)]$Report, [Parameter(Mandatory = $true)][string]$Path)
    $full = Assert-VulkanLuidJoinOutputPath -Path $Path
    $json = ConvertTo-Json -InputObject $Report -Depth 12
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json)
    # CreateNew refuses to overwrite even if the file appears after the check above.
    $stream = [IO.File]::Open($full, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    return $full
}

if ($LibraryOnly) { return }

try {
    if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) {
        throw 'Vulkan LUID join probe requires 64-bit Windows.'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run the Vulkan LUID join probe as a standard user.'
    }
    # Validate the destination first so a bad path fails before any collection.
    $null = Assert-VulkanLuidJoinOutputPath -Path $OutputPath
    $repo = Split-Path $PSScriptRoot -Parent
    $sources = @('src/WindowsVulkanLuidJoin.cs', 'src/WindowsPciAddress.cs')
    $hashes = @{}
    foreach ($relative in $sources) {
        $file = Join-Path $repo $relative
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw ($relative + ' is unavailable.') }
        $hashes[$relative] = Get-VulkanLuidJoinFileSha256 -Path $file
    }
    $hashes['tools/collect-vulkan-luid-join.ps1'] = Get-VulkanLuidJoinFileSha256 -Path $PSCommandPath
    if (-not ('Bitworks.FastLlm.WindowsVulkanLuidJoin' -as [type])) { Add-Type -Path (Join-Path $repo $sources[0]) -ErrorAction Stop }
    if (-not ('Bitworks.FastLlm.WindowsPciAddress' -as [type])) { Add-Type -Path (Join-Path $repo $sources[1]) -ErrorAction Stop }

    $snapshot = [Bitworks.FastLlm.WindowsVulkanLuidJoin]::Collect()
    $vulkanRows = @($snapshot.Vulkan | ForEach-Object { ConvertTo-VulkanLuidJoinVulkanRow $_ })
    $dxgiRows = @($snapshot.Dxgi | ForEach-Object { ConvertTo-VulkanLuidJoinDxgiRow $_ })
    $pnpRows = @($snapshot.SetupApi | ForEach-Object { ConvertTo-VulkanLuidJoinSetupApiRow $_ })
    $kmtRows = @()
    foreach ($adapter in $dxgiRows) {
        if ($adapter.software) { continue }
        $entry = [ordered]@{ luid = $adapter.adapterLuid; bus = $null; device = $null; function = $null; error = $null }
        try {
            $observation = [Bitworks.FastLlm.WindowsPciAddress]::Read([string]$adapter.adapterLuid)
            if ($observation.Error) { $entry.error = [string]$observation.Error }
            else { $entry.bus = [int]$observation.Bus; $entry.device = [int]$observation.Device; $entry.function = [int]$observation.Function }
        } catch { $entry.error = 'kmt-read-failed-' + $_.Exception.GetType().Name }
        $kmtRows += [pscustomobject]$entry
    }
    Assert-VulkanLuidJoinRepeatOptions -Count $RepeatCount -IntervalMs $RepeatIntervalMs
    $joins = @(Join-VulkanLuidDevices -Vulkan $vulkanRows -Dxgi $dxgiRows -Kmt $kmtRows -SetupApi $pnpRows `
        -DxgiError $snapshot.DxgiError -SetupApiError $snapshot.SetupApiError)
    # Budget-only re-reads: no identity re-collection, no logical device, no process or environment change.
    $budgetSamples = @()
    for ($n = 0; $n -lt $RepeatCount; $n++) {
        if ($n -gt 0) { Start-Sleep -Milliseconds $RepeatIntervalMs }
        $budgetSamples += (ConvertTo-VulkanLuidJoinBudgetSample -Sample ([Bitworks.FastLlm.WindowsVulkanLuidJoin]::CollectBudgetSample()) `
            -SampleIndex $n -InitialVulkanRows $vulkanRows)
    }
    $errors = @{ vulkan = $snapshot.VulkanError; dxgi = $snapshot.DxgiError; setupApi = $snapshot.SetupApiError }
    $report = New-VulkanLuidJoinReport -Devices $vulkanRows -DxgiAdapters $dxgiRows -KmtAddresses $kmtRows `
        -SetupApiDevices $pnpRows -Joins $joins -HostName ([Environment]::MachineName) -SourceSha256 $hashes `
        -CollectionErrors $errors -DedicatedGpuCount ([int]$snapshot.DefaultSelectionDedicatedGpuCount) `
        -VulkanLoaderPath $snapshot.VulkanLoaderPath -BudgetSamples $budgetSamples -RepeatCount $RepeatCount -RepeatIntervalMs $RepeatIntervalMs
    $written = Write-VulkanLuidJoinReport -Report $report -Path $OutputPath
    Write-Host ('Saved Vulkan LUID join report: {0} ({1} Vulkan device(s), {2} unique). No qualification or server binding implied.' -f `
        $written, $vulkanRows.Count, $report.joinSummary.unique)
}
catch {
    [Console]::Error.WriteLine('collect-vulkan-luid-join failed: ' + $_.Exception.Message)
    exit 1
}
