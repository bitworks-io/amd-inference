# Loaded into FastLlm.psm1. W03 Phase A: per-start device binding (-DeviceBinding off|record|enforce).
# Nothing here changes the plan, the selected adapters, the server argv, the child environment or the Resizable-BAR resolver's
# inputs or decision. record is observation only: it never fails a start, sets a failure code or triggers model recovery.
# enforce (the supervisor, Runtime.ps1) fails a start whose binding is not bound, or whose post-load device check fails, with a typed
# DeviceBindingFailed failure that is never routed to model recovery. Default is off; with off none of this code runs (no collector
# child, no state field, no device-identity.json access).
# Design: docs/research/W03-PER-START-DEVICE-BINDING-DESIGN-2026-10-07.md (revision 2); build spec:
# docs/superpowers/specs/2026-10-07-w03-phase-a-build-spec.md. No host values are embedded in this file.

$script:FastLlmDeviceIdentityFileName = 'device-identity.json'
$script:FastLlmDeviceIdentitySchema = 'fastllm.device-identity.v1'
$script:FastLlmDeviceIdentityKind = 'pci-ids+slot+driver'
$script:FastLlmDeviceIdentityMaxBytes = 16384
$script:FastLlmDeviceIdentityMaxAdapters = 16

# Strict-mode safe property read. Returns the value, or $null when the object or the property is absent.
function Get-FastLlmDeviceBindingValue {
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

# Strict-mode safe list read: null elements dropped. Callers always wrap the call in @( ... ).
function Get-FastLlmDeviceBindingList {
    param($Object, [string] $Name)
    $value = Get-FastLlmDeviceBindingValue -Object $Object -Name $Name
    $items = New-Object 'System.Collections.Generic.List[object]'
    if ($null -ne $value) { foreach ($item in @($value)) { if ($null -ne $item) { [void]$items.Add($item) } } }
    return $items.ToArray()
}

function Get-FastLlmDeviceBindingSha256 {
    param([string] $Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) }
    finally { $sha.Dispose() }
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

# Same normalisation as the planner (FastLlm.psm1, the adapter sort key): trim, then lower-case invariant. Nothing more lenient.
function ConvertTo-FastLlmDeviceBindingName {
    param($Value)
    return (([string]$Value).Trim().ToLowerInvariant())
}

# ggml's driver priority for a duplicate GPU entry (ggml-vulkan.cpp b10698, ggml_vk_instance_init, "Default to using all
# dedicated GPUs"). The table is chosen by the vendor of the entry ggml already KEPT; MESA_DOZEN is 100 for every vendor;
# any other or missing driver id is max int. Smaller wins. The keys are VkDriverId values (Khronos vulkan_core.h), NOT ggml priorities.
function Get-FastLlmGgmlVulkanDriverPriority {
    param($KeptVendorId, $DriverId)
    $max = [int]::MaxValue
    if ($null -eq $DriverId) { return $max }
    $driver = 0L
    if (-not [long]::TryParse([string]$DriverId, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$driver)) { return $max }
    if ($driver -eq 23) { return 100 }   # VK_DRIVER_ID_MESA_DOZEN
    $vendor = 0L
    if (-not [long]::TryParse([string]$KeptVendorId, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$vendor)) { return $max }
    $table = $null
    switch ($vendor) {
        4098  { $table = @{ 3 = 1; 2 = 2; 1 = 3 } }    # AMD 0x1002: MESA_RADV, AMD_OPEN_SOURCE, AMD_PROPRIETARY
        32902 { $table = @{ 6 = 1; 5 = 2 } }           # Intel 0x8086: INTEL_OPEN_SOURCE_MESA, INTEL_PROPRIETARY_WINDOWS
        4318  { $table = @{ 4 = 1; 24 = 2 } }          # NVIDIA 0x10de: NVIDIA_PROPRIETARY, MESA_NVK
        20803 { $table = @{ 8 = 1; 18 = 2 } }          # Qualcomm 0x5143: QUALCOMM_PROPRIETARY, MESA_TURNIP
    }
    if ($null -ne $table -and $table.ContainsKey([int]$driver)) { return [int]$table[[int]$driver] }
    return $max
}

# Same physical GPU the way ggml de-duplicates: an equal device UUID, or both LUIDs valid and equal.
function Test-FastLlmDeviceBindingSameGpu {
    param($Left, $Right)
    $leftUuid = [string](Get-FastLlmDeviceBindingValue $Left 'deviceUuid')
    $rightUuid = [string](Get-FastLlmDeviceBindingValue $Right 'deviceUuid')
    if ($leftUuid -and $rightUuid -and [string]::Equals($leftUuid, $rightUuid, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $leftValid = (Get-FastLlmDeviceBindingValue $Left 'deviceLuidValid') -eq $true
    $rightValid = (Get-FastLlmDeviceBindingValue $Right 'deviceLuidValid') -eq $true
    if ($leftValid -and $rightValid) {
        $leftLuid = [string](Get-FastLlmDeviceBindingValue $Left 'deviceLuid')
        $rightLuid = [string](Get-FastLlmDeviceBindingValue $Right 'deviceLuid')
        if ($leftLuid -and $rightLuid -and [string]::Equals($leftLuid, $rightLuid, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# Replays ggml's walk over the raw devices (raw order): the first entry of a GPU is kept; a later entry of the SAME GPU replaces the
# kept one only when its priority is STRICTLY lower (equal keeps the earlier). Returns the kept entries (one per distinct GPU).
function Select-FastLlmGgmlVulkanDevice {
    param([object[]] $Devices)
    $kept = New-Object 'System.Collections.Generic.List[object]'
    foreach ($candidate in @($Devices)) {
        $matchIndex = -1
        for ($i = 0; $i -lt $kept.Count; $i++) {
            if (Test-FastLlmDeviceBindingSameGpu -Left $kept[$i] -Right $candidate) { $matchIndex = $i; break }
        }
        if ($matchIndex -lt 0) { [void]$kept.Add($candidate); continue }
        $old = $kept[$matchIndex]
        $oldVendor = Get-FastLlmDeviceBindingValue $old 'vendorId'
        $oldPriority = Get-FastLlmGgmlVulkanDriverPriority -KeptVendorId $oldVendor -DriverId (Get-FastLlmDeviceBindingValue $old 'driverId')
        $newPriority = Get-FastLlmGgmlVulkanDriverPriority -KeptVendorId $oldVendor -DriverId (Get-FastLlmDeviceBindingValue $candidate 'driverId')
        if ($newPriority -lt $oldPriority) {
            $kept.RemoveAt($matchIndex)
            [void]$kept.Add($candidate)
        }
    }
    return $kept.ToArray()
}

# floor(sum of the device's DEVICE_LOCAL heap sizes / 1 MiB), ggml's total, from the first budget sample that has an ok row for
# the device. Integer arithmetic only. $null when the heaps are unavailable.
function Get-FastLlmDeviceBindingLocalTotalMiB {
    param($Report, [int] $DeviceIndex)
    foreach ($sample in @(Get-FastLlmDeviceBindingList $Report 'budgetSamples')) {
        foreach ($row in @(Get-FastLlmDeviceBindingList $sample 'vulkan')) {
            $rowIndex = Get-FastLlmDeviceBindingValue $row 'index'
            if ($null -eq $rowIndex -or [int]$rowIndex -ne $DeviceIndex) { continue }
            if ([string](Get-FastLlmDeviceBindingValue $row 'status') -cne 'ok') { continue }
            $heaps = @(Get-FastLlmDeviceBindingList $row 'heaps')
            if ($heaps.Count -eq 0) { continue }
            [long]$sum = 0
            $seen = $false
            foreach ($heap in $heaps) {
                if ((Get-FastLlmDeviceBindingValue $heap 'deviceLocal') -ne $true) { continue }
                $size = Get-FastLlmDeviceBindingValue $heap 'sizeBytes'
                if ($null -eq $size) { return $null }
                $sum += [long]$size
                $seen = $true
            }
            if (-not $seen) { return $null }
            $mib = [long]1048576
            return [long](($sum - ($sum % $mib)) / $mib)
        }
    }
    return $null
}

# Most specific PCI hardware id (the longest `PCI\VEN_xxxx&DEV_xxxx...` entry), as `VEN_xxxx&DEV_xxxx&SUBSYS_xxxxxxxx&REV_xx`
# (upper case). $null when none.
function ConvertTo-FastLlmDevicePciIds {
    param($HardwareIds)
    $best = $null
    foreach ($id in @($HardwareIds)) {
        $text = [string]$id
        if ($text -notmatch '(?i)^PCI\\VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4}') { continue }
        if ($null -eq $best -or $text.Length -gt $best.Length) { $best = $text }
    }
    if ($null -eq $best) { return $null }
    return $best.Substring(4).ToUpperInvariant()
}

# The join's recorded reason is an enumerated collector string; keep it only when it has that shape.
function ConvertTo-FastLlmDeviceBindingJoinReason {
    param($Value)
    $text = [string]$Value
    if ($text -cmatch '^[a-z0-9][a-z0-9-]{0,95}$') { return $text }
    return $null
}

# Pure Phase A binding over one parsed collector report. Never throws for a bad report shape of its own; callers wrap it anyway.
# $BarDecision is the in-memory Resizable-BAR decision (requested, ... and, only if it ever carries one, pnpInstanceId).
function Resolve-FastLlmDeviceBindingFromReport {
    param($Plan, $Report, $BarDecision)
    $result = [ordered]@{
        status = 'unavailable'; reason = $null; rawDeviceCount = 0; distinctAdapterCount = 0; duplicateLuidEntries = 0
        device = $null; planMatch = $null; barSnapshot = 'not-applicable'
    }
    $barRequested = [string](Get-FastLlmDeviceBindingValue $BarDecision 'requested')
    if ($barRequested -ceq 'auto') { $result.barSnapshot = 'not-available' }

    $raw = @(@(Get-FastLlmDeviceBindingList $Report 'devices') | Where-Object {
        $type = Get-FastLlmDeviceBindingValue $_ 'deviceType'
        $null -eq $type -or [int]$type -ne 4
    })
    $result.rawDeviceCount = $raw.Count
    if ($raw.Count -eq 0) { $result.reason = 'no-vulkan-device'; return [pscustomobject]$result }
    foreach ($entry in $raw) {
        if ((Get-FastLlmDeviceBindingValue $entry 'deviceLuidValid') -ne $true) { $result.reason = 'luid-invalid'; return [pscustomobject]$result }
    }
    $kept = @(Select-FastLlmGgmlVulkanDevice -Devices $raw)
    $result.distinctAdapterCount = $kept.Count
    if ($kept.Count -gt 1) {
        $result.status = 'not-supported-topology'; $result.reason = 'multiple-adapters'
        $result.duplicateLuidEntries = $raw.Count - $kept.Count
        return [pscustomobject]$result
    }
    $result.duplicateLuidEntries = $raw.Count - 1
    $chosen = $kept[0]
    $chosenIndex = [int](Get-FastLlmDeviceBindingValue $chosen 'index')

    # Follow the collector's own join row for that device, hop by hop. Nothing is re-joined here.
    $join = $null
    foreach ($row in @(Get-FastLlmDeviceBindingList $Report 'joins')) {
        $rowIndex = Get-FastLlmDeviceBindingValue $row 'vulkanIndex'
        if ($null -ne $rowIndex -and [int]$rowIndex -eq $chosenIndex) { $join = $row; break }
    }
    if ($null -eq $join) { $result.reason = 'join-row-missing'; return [pscustomobject]$result }
    $hops = Get-FastLlmDeviceBindingValue $join 'hops'
    $failedHop = $null
    foreach ($hopName in @('vulkan', 'dxgi', 'kmt', 'setupApi')) {
        $hop = Get-FastLlmDeviceBindingValue $hops $hopName
        if ([string](Get-FastLlmDeviceBindingValue $hop 'status') -cne 'ok') { $failedHop = $hopName; break }
    }
    $joinStatus = [string](Get-FastLlmDeviceBindingValue $join 'status')
    if ($null -ne $failedHop -or $joinStatus -cne 'unique') {
        if ($null -eq $failedHop) { $result.reason = 'join-inconsistent'; return [pscustomobject]$result }
        $hopRecord = Get-FastLlmDeviceBindingValue $hops $failedHop
        $hopStatus = [string](Get-FastLlmDeviceBindingValue $hopRecord 'status')
        if ($hopStatus -cnotmatch '^[a-z]{1,24}$') { $hopStatus = 'unavailable' }
        $result.reason = 'join-' + $failedHop + '-' + $hopStatus
        if ($hopStatus -ceq 'ambiguous') { $result.status = 'ambiguous' }
        $joinReason = ConvertTo-FastLlmDeviceBindingJoinReason (Get-FastLlmDeviceBindingValue $hopRecord 'reason')
        if ($joinReason) { $result.joinReason = $joinReason }
        return [pscustomobject]$result
    }

    $pnp = [string](Get-FastLlmDeviceBindingValue $join 'pnpInstanceId')
    $totalMiB = Get-FastLlmDeviceBindingLocalTotalMiB -Report $Report -DeviceIndex $chosenIndex
    $result.device = [ordered]@{
        rawVulkanIndex = $chosenIndex
        name = [string](Get-FastLlmDeviceBindingValue $chosen 'deviceName')
        deviceType = Get-FastLlmDeviceBindingValue $chosen 'deviceType'
        pciIds = ConvertTo-FastLlmDevicePciIds (Get-FastLlmDeviceBindingValue $join 'hardwareIds')
        pnpInstanceId = $pnp
        driverVersion = [string](Get-FastLlmDeviceBindingValue $join 'driverVersion')
        ggmlTotalMiB = $totalMiB
        luidMatched = $true
    }
    $result.status = 'bound'

    # Plan cross-check: exactly one selected adapter, same name, same ggml total.
    $planAdapters = @(@(Get-FastLlmDeviceBindingList $Plan 'selectedAdapters'))
    $nameMatch = $false
    $totalMatch = $false
    if ($planAdapters.Count -eq 1) {
        $planName = ConvertTo-FastLlmDeviceBindingName (Get-FastLlmDeviceBindingValue $planAdapters[0] 'name')
        $deviceName = ConvertTo-FastLlmDeviceBindingName $result.device.name
        $nameMatch = ($planName.Length -gt 0) -and [string]::Equals($planName, $deviceName, [StringComparison]::OrdinalIgnoreCase)
        $planTotal = 0L
        $planTotalText = [string](Get-FastLlmDeviceBindingValue $planAdapters[0] 'vramMiB')
        if ($null -ne $totalMiB -and [long]::TryParse($planTotalText, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$planTotal)) { $totalMatch = ($planTotal -eq [long]$totalMiB) }
    }
    $result.planMatch = [ordered]@{ name = $nameMatch; totalMiB = $totalMatch }
    if (-not ($nameMatch -and $totalMatch)) { $result.status = 'unavailable'; $result.reason = 'plan-mismatch' }

    # BAR snapshot agreement, only when the policy resolved as auto AND its decision carries the PnP instance.
    if ($barRequested -ceq 'auto') {
        $barPnp = [string](Get-FastLlmDeviceBindingValue $BarDecision 'pnpInstanceId')
        if ($barPnp) {
            if ([string]::Equals($barPnp, $pnp, [StringComparison]::OrdinalIgnoreCase)) { $result.barSnapshot = 'agree' }
            else {
                $result.barSnapshot = 'disagree'
                if ($result.status -ceq 'bound') { $result.status = 'unavailable'; $result.reason = 'snapshot-disagreement' }
            }
        }
    }
    return [pscustomobject]$result
}

# Identity text written to disk follows the rule the reader applies: printable ASCII, at most 128 characters. Any non-printable or
# non-ASCII character becomes '?' and the text is truncated, so a real adapter name (a trademark sign, say) stays readable and the
# change detection keeps working.
function ConvertTo-FastLlmDeviceIdentityText {
    param([string] $Text)
    $clean = [regex]::Replace([string]$Text, '[^\x20-\x7E]', '?')
    if ($clean.Length -gt 128) { $clean = $clean.Substring(0, 128) }
    return $clean
}

# Present AMD display adapters from the SAME collector snapshot (SetupAPI rows are present devices only). Per adapter: pciIds,
# name, driverVersion and slotHash = SHA-256(locationInfo). The slot key itself is never stored. Returns $null when there is
# nothing to fingerprint. Sorted by instance id (ordinal).
function Get-FastLlmDeviceIdentityFromReport {
    param($Report)
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($row in @(Get-FastLlmDeviceBindingList $Report 'setupApiDisplayDevices')) {
        $ids = @(Get-FastLlmDeviceBindingList $row 'hardwareIds')
        $isAmd = $false
        foreach ($id in $ids) { if (([string]$id) -match '(?i)VEN_1002') { $isAmd = $true; break } }
        if (-not $isAmd) { continue }
        $instance = [string](Get-FastLlmDeviceBindingValue $row 'instanceId')
        [void]$rows.Add([pscustomobject]@{
            instanceId = $instance
            name = (ConvertTo-FastLlmDeviceIdentityText (([string](Get-FastLlmDeviceBindingValue $row 'description')).Trim()))
            pciIds = [string](ConvertTo-FastLlmDevicePciIds $ids)
            slotHash = Get-FastLlmDeviceBindingSha256 ([string](Get-FastLlmDeviceBindingValue $row 'locationInfo'))
            driverVersion = [string](Get-FastLlmDeviceBindingValue $row 'driverVersion')
        })
    }
    if ($rows.Count -eq 0 -or $rows.Count -gt $script:FastLlmDeviceIdentityMaxAdapters) { return $null }
    $ordered = @($rows.ToArray() | Sort-Object -Property instanceId)
    $entries = [string[]]@($ordered | ForEach-Object { $_.pciIds + '|' + $_.slotHash + '|' + $_.driverVersion })
    [Array]::Sort($entries, [StringComparer]::Ordinal)
    return [pscustomobject]@{
        fingerprint = Get-FastLlmDeviceBindingSha256 ($entries -join ';')
        adapters = @($ordered | ForEach-Object { [ordered]@{ name = $_.name; pciIds = $_.pciIds; slotHash = $_.slotHash; driverVersion = $_.driverVersion } })
    }
}

# Reads the last recorded identity. Any problem (missing, oversized, reparse point, wrong schema, unparseable) is "no record".
function Read-FastLlmDeviceIdentityRecord {
    param([string] $InstallRoot)
    try {
        $path = Join-Path (Get-FastLlmStateRoot -InstallRoot $InstallRoot) $script:FastLlmDeviceIdentityFileName
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
        $item = Get-Item -LiteralPath $path -Force
        if ([int]$item.Attributes -eq -1 -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt $script:FastLlmDeviceIdentityMaxBytes) { return $null }
        $record = Read-FastLlmJson -Path $path -MaxBytes $script:FastLlmDeviceIdentityMaxBytes
        if ([string](Get-FastLlmDeviceBindingValue $record 'schema') -cne $script:FastLlmDeviceIdentitySchema) { return $null }
        $adapters = @(Get-FastLlmDeviceBindingList $record 'adapters')
        if ($adapters.Count -eq 0 -or $adapters.Count -gt $script:FastLlmDeviceIdentityMaxAdapters) { return $null }
        foreach ($adapter in $adapters) {
            foreach ($field in @('name', 'pciIds', 'slotHash', 'driverVersion')) {
                if ($null -eq $adapter.PSObject.Properties[$field]) { return $null }
                # The stored text reaches the console: printable ASCII only, at most 128 characters. Anything else is no record
                # (the file is rewritten clean at the next Ready).
                $text = $adapter.PSObject.Properties[$field].Value
                if ($text -isnot [string] -or $text.Length -gt 128 -or $text -cnotmatch '^[\x20-\x7E]*\z') { return $null }
            }
            if ([string]$adapter.slotHash -cnotmatch '^[0-9a-f]{64}\z') { return $null }
        }
        return [pscustomobject]@{ adapters = $adapters }
    }
    catch { return $null }
}

# Test seam: the Ready-time write. Atomic replace through Write-FastLlmState (same-folder temp + Move-FastLlmFileReplacing).
function Write-FastLlmDeviceIdentityRecord {
    param([string] $InstallRoot, $Identity)
    # The name is sanitised on write (same rule as the reader). pciIds, slotHash and driverVersion are kept as they are (ASCII in
    # practice); if one fails the rule, no record is written (returns $false) - never a file the reader would reject.
    $adapters = New-Object 'System.Collections.Generic.List[object]'
    foreach ($adapter in @($Identity.adapters)) {
        $entry = [ordered]@{
            name = (ConvertTo-FastLlmDeviceIdentityText ([string]$adapter.name))
            pciIds = [string]$adapter.pciIds
            slotHash = [string]$adapter.slotHash
            driverVersion = [string]$adapter.driverVersion
        }
        foreach ($field in @('pciIds', 'driverVersion')) {
            if ($entry[$field].Length -gt 128 -or $entry[$field] -cnotmatch '^[\x20-\x7E]*\z') { return $false }
        }
        if ($entry.slotHash -cnotmatch '^[0-9a-f]{64}\z') { return $false }
        [void]$adapters.Add($entry)
    }
    if ($adapters.Count -eq 0 -or $adapters.Count -gt $script:FastLlmDeviceIdentityMaxAdapters) { return $false }
    $null = Write-FastLlmState -InstallRoot $InstallRoot -FileName $script:FastLlmDeviceIdentityFileName -State ([ordered]@{
        schema = $script:FastLlmDeviceIdentitySchema
        identityFingerprint = [string]$Identity.fingerprint
        adapters = $adapters.ToArray()
        recordedUtc = (Get-Date).ToUniversalTime().ToString('o')
    })
    return $true
}

# Compares the stored record with the current identity. Returns { card, slot, driver, lines }. Console lines carry names and driver
# versions only. Adapters are paired after a stable sort, which is exact for the single-adapter Phase A hosts.
function Compare-FastLlmDeviceIdentity {
    param($Stored, $Current)
    $none = [pscustomobject]@{ card = $false; slot = $false; driver = $false; lines = @() }
    if ($null -eq $Stored -or $null -eq $Current) { return $none }
    $old = @(@($Stored.adapters) | ForEach-Object { [pscustomobject]@{ name = [string]$_.name; pciIds = [string]$_.pciIds; slotHash = [string]$_.slotHash; driverVersion = [string]$_.driverVersion; key = ([string]$_.pciIds + '|' + [string]$_.slotHash + '|' + [string]$_.driverVersion) } } | Sort-Object -Property key)
    $new = @(@($Current.adapters) | ForEach-Object { [pscustomobject]@{ name = [string]$_.name; pciIds = [string]$_.pciIds; slotHash = [string]$_.slotHash; driverVersion = [string]$_.driverVersion; key = ([string]$_.pciIds + '|' + [string]$_.slotHash + '|' + [string]$_.driverVersion) } } | Sort-Object -Property key)
    $oldIds = [string[]]@($old | ForEach-Object { [string]$_.pciIds }); [Array]::Sort($oldIds, [StringComparer]::Ordinal)
    $newIds = [string[]]@($new | ForEach-Object { [string]$_.pciIds }); [Array]::Sort($newIds, [StringComparer]::Ordinal)
    $card = (($oldIds -join ';') -cne ($newIds -join ';'))
    $slot = $false; $driver = $false
    $lines = @()
    if ($card) {
        $lines += ('GPU changed since the last recorded start: ' + ((@($old | ForEach-Object { [string]$_.name })) -join ', ') + ' -> ' + ((@($new | ForEach-Object { [string]$_.name })) -join ', '))
    }
    if ($old.Count -eq $new.Count) {
        $movedNames = @(); $driverNotes = @()
        for ($i = 0; $i -lt $new.Count; $i++) {
            if (-not $card -and ([string]$old[$i].slotHash) -cne ([string]$new[$i].slotHash)) { $slot = $true; $movedNames += [string]$new[$i].name }
            if (([string]$old[$i].driverVersion) -cne ([string]$new[$i].driverVersion)) { $driver = $true; $driverNotes += ([string]$new[$i].name + ' ' + [string]$old[$i].driverVersion + ' -> ' + [string]$new[$i].driverVersion) }
        }
        if ($slot) { $lines += ('GPU moved to another slot since the last recorded start: ' + ($movedNames -join ', ')) }
        if ($driver) { $lines += ('Driver updated since the last recorded start: ' + ($driverNotes -join '; ')) }
    }
    return [pscustomobject]@{ card = $card; slot = $slot; driver = $driver; lines = $lines }
}

# Test seam: file version of the Windows Vulkan loader, or $null.
function Get-FastLlmDeviceBindingLoaderVersion {
    try {
        if ($env:OS -ne 'Windows_NT') { return $null }
        $item = Get-Item -LiteralPath (Join-Path ([Environment]::SystemDirectory) 'vulkan-1.dll') -ErrorAction Stop
        $text = [string]$item.VersionInfo.FileVersion
        if ($text -match '^[0-9A-Za-z .,()_-]{1,64}$') { return $text.Trim() }
        return $null
    }
    catch { return $null }
}

# Test seam: the ONE bounded collector child for the binding (the same child the BAR probe uses, Invoke-FastLlmVulkanHeapProbe:
# kill-on-close job, 30 s deadline, sanitised environment, per-call temp folder removed in finally). Never throws; returns
# { report, failure } with failure $null | 'collector-timeout' | 'collector-failed'.
function Invoke-FastLlmDeviceBindingCollector {
    $outcome = [pscustomobject]@{ report = $null; failure = $null }
    try {
        $report = Invoke-FastLlmVulkanHeapProbe
        if ($null -eq $report) { $outcome.failure = 'collector-failed' } else { $outcome.report = $report }
    }
    catch {
        $category = $null
        try { $category = $_.Exception.Data['FastLlmProbeCategory'] } catch { }
        if ($category -ceq 'timeout') { $outcome.failure = 'collector-timeout' } else { $outcome.failure = 'collector-failed' }
    }
    return $outcome
}

function Get-FastLlmDeviceBindingSourceHash {
    param($Report, [string] $Name)
    $sources = Get-FastLlmDeviceBindingValue (Get-FastLlmDeviceBindingValue $Report 'collector') 'sourceSha256'
    $value = [string](Get-FastLlmDeviceBindingValue $sources $Name)
    if ($value -cmatch '^[0-9a-f]{64}$') { return $value }
    return $null
}

# One start's binding. NEVER throws and never gates (the enforce gate is the caller's): any exception becomes unavailable /
# binding-internal-error with only the exception type name recorded. Returns { record (for status.json), identity ($null or the
# Ready-time record), change, lines }. $Mode only labels the record (record is the default).
function Invoke-FastLlmDeviceBinding {
    param($Plan, [string] $InstallRoot, $BarDecision, [ValidateSet('record', 'enforce')][string] $Mode = 'record')
    # ValidateSet ignores case and keeps the typed value; the recorded mode is always lowercase.
    $Mode = $Mode.ToLowerInvariant()
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $collector = [ordered]@{ scriptSha256 = $null; joinSourceSha256 = $null; durationMs = 0; loaderVersion = $null; segmentKnown = $false }
    $record = [ordered]@{
        mode = $Mode; status = 'unavailable'; reason = $null; rawDeviceCount = 0; distinctAdapterCount = 0; duplicateLuidEntries = 0
        device = $null; planMatch = $null; barSnapshot = 'not-applicable'; collector = $collector
    }
    $outcome = [pscustomobject]@{ record = $null; identity = $null; change = $null; lines = @() }
    try {
        if ($env:OS -ne 'Windows_NT') { $record.reason = 'unsupported-platform' }
        else {
            $backend = [string](Get-FastLlmDeviceBindingValue $Plan 'backend')
            if ($backend -ine 'vulkan') { $record.reason = 'unsupported-backend' }
            else {
                $collected = Invoke-FastLlmDeviceBindingCollector
                $collector.durationMs = [int]$watch.ElapsedMilliseconds
                if ($null -ne $collected.failure) { $record.reason = [string]$collected.failure }
                else {
                    $report = $collected.report
                    $resolved = Resolve-FastLlmDeviceBindingFromReport -Plan $Plan -Report $report -BarDecision $BarDecision
                    foreach ($property in $resolved.PSObject.Properties) { $record[$property.Name] = $property.Value }
                    $collector.scriptSha256 = Get-FastLlmDeviceBindingSourceHash -Report $report -Name 'tools/collect-vulkan-luid-join.ps1'
                    $collector.joinSourceSha256 = Get-FastLlmDeviceBindingSourceHash -Report $report -Name 'src/WindowsVulkanLuidJoin.cs'
                    $collector.loaderVersion = Get-FastLlmDeviceBindingLoaderVersion
                    $outcome.identity = Get-FastLlmDeviceIdentityFromReport -Report $report
                    if ($null -ne $outcome.identity) {
                        $stored = Read-FastLlmDeviceIdentityRecord -InstallRoot $InstallRoot
                        $change = Compare-FastLlmDeviceIdentity -Stored $stored -Current $outcome.identity
                        $outcome.change = $change
                        $outcome.lines = @($change.lines)
                    }
                }
            }
        }
    }
    catch {
        $errorType = 'Exception'
        try { $errorType = [string]$_.Exception.GetType().Name } catch { }
        $record = [ordered]@{
            mode = $Mode; status = 'unavailable'; reason = 'binding-internal-error'; rawDeviceCount = 0; distinctAdapterCount = 0; duplicateLuidEntries = 0
            device = $null; planMatch = $null; barSnapshot = 'not-applicable'; collector = $collector; errorType = $errorType
        }
        $outcome.identity = $null; $outcome.change = $null; $outcome.lines = @()
    }
    $record.collector = $collector
    $outcome.record = [pscustomobject]$record
    return $outcome
}

# Removes the private-by-policy fields from a status document that is about to be shown to a person. status.json keeps them;
# the `status` action never prints them. Mutates and returns the object it is given (a freshly parsed document).
function Remove-FastLlmDeviceBindingPrivateFields {
    param($Status)
    if ($null -eq $Status) { return $Status }
    $hash = $Status.PSObject.Properties['identityFingerprint']
    if ($hash) { [void]$Status.PSObject.Properties.Remove('identityFingerprint') }
    $binding = Get-FastLlmDeviceBindingValue $Status 'deviceBinding'
    $device = Get-FastLlmDeviceBindingValue $binding 'device'
    if ($null -ne $device -and $device.PSObject.Properties['pnpInstanceId']) { [void]$device.PSObject.Properties.Remove('pnpInstanceId') }
    return $Status
}

# Strict-mode safe read that also works on the ordered dictionaries the supervisor keeps in its state.
function Get-FastLlmDeviceBindingEntryValue {
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] }; return $null }
    return (Get-FastLlmDeviceBindingValue -Object $Object -Name $Name)
}

# W03 Phase A enforce: the post-load check over the frozen server device-list capture. Returns { result = 'passed' } or
# { result = 'failed'; item = '1'..'6' } (item 'internal-error' if the check itself threw: fail closed). Pure; no console, no state.
#   1 the capture is clean (no error, malformed = 0, overflow = false for both shapes)
#   2 exactly one device_info entry named Vulkan<n> (CPU and other entries are ignored)
#   3 its name equals the plan's selected device
#   4 its description equals the bound device name (the planner's normalisation)
#   5 its total MiB equals the bound ggml total, exactly
#   6 exactly one using-device entry, named like that GPU entry, whose id is unknown or a PCI BDF
function Test-FastLlmDeviceBindingPostLoad {
    param($Plan, $Binding, $Capture)
    try {
        if ($Capture -is [Collections.IDictionary]) { $Capture = [pscustomobject]$Capture }
        if ($null -eq $Capture -or $null -ne $Capture.PSObject.Properties['error']) { return [pscustomobject][ordered]@{ result = 'failed'; item = '1' } }
        foreach ($name in @('deviceInfoMalformedLines', 'usingDeviceMalformedLines')) {
            $value = Get-FastLlmDeviceBindingValue $Capture $name
            if ($null -eq $value -or [long]$value -ne 0) { return [pscustomobject][ordered]@{ result = 'failed'; item = '1' } }
        }
        foreach ($name in @('deviceInfoOverflow', 'usingDeviceOverflow')) {
            if ((Get-FastLlmDeviceBindingValue $Capture $name) -ne $false) { return [pscustomobject][ordered]@{ result = 'failed'; item = '1' } }
        }
        $gpus = @(@(Get-FastLlmDeviceBindingList $Capture 'deviceInfo') | Where-Object { [string](Get-FastLlmDeviceBindingEntryValue $_ 'name') -cmatch '^Vulkan[0-9]+$' })
        if ($gpus.Count -ne 1) { return [pscustomobject][ordered]@{ result = 'failed'; item = '2' } }
        $gpu = $gpus[0]
        $gpuName = [string](Get-FastLlmDeviceBindingEntryValue $gpu 'name')
        $planAdapters = @(Get-FastLlmDeviceBindingList $Plan 'selectedAdapters')
        if ($planAdapters.Count -ne 1) { return [pscustomobject][ordered]@{ result = 'failed'; item = '3' } }
        $planDevice = [string](Get-FastLlmDeviceBindingEntryValue $planAdapters[0] 'device')
        if ($planDevice.Length -eq 0 -or $gpuName -cne $planDevice) { return [pscustomobject][ordered]@{ result = 'failed'; item = '3' } }
        $bound = Get-FastLlmDeviceBindingEntryValue $Binding 'device'
        $boundName = ConvertTo-FastLlmDeviceBindingName (Get-FastLlmDeviceBindingEntryValue $bound 'name')
        $description = ConvertTo-FastLlmDeviceBindingName (Get-FastLlmDeviceBindingEntryValue $gpu 'description')
        if ($boundName.Length -eq 0 -or $description -cne $boundName) { return [pscustomobject][ordered]@{ result = 'failed'; item = '4' } }
        $expectedTotal = Get-FastLlmDeviceBindingEntryValue $bound 'ggmlTotalMiB'
        $actualTotal = Get-FastLlmDeviceBindingEntryValue $gpu 'totalMiB'
        if ($null -eq $expectedTotal -or $null -eq $actualTotal -or [long]$actualTotal -ne [long]$expectedTotal) { return [pscustomobject][ordered]@{ result = 'failed'; item = '5' } }
        $using = @(Get-FastLlmDeviceBindingList $Capture 'usingDevice')
        if ($using.Count -ne 1) { return [pscustomobject][ordered]@{ result = 'failed'; item = '6' } }
        $usingName = [string](Get-FastLlmDeviceBindingEntryValue $using[0] 'name')
        $usingId = [string](Get-FastLlmDeviceBindingEntryValue $using[0] 'id')
        if ($usingName -cne $gpuName -or $usingId -cnotmatch '^(unknown|[0-9A-Fa-f]{4}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}\.[0-7])$') { return [pscustomobject][ordered]@{ result = 'failed'; item = '6' } }
        return [pscustomobject][ordered]@{ result = 'passed' }
    }
    catch { return [pscustomobject][ordered]@{ result = 'failed'; item = 'internal-error' } }
}
