# Loaded into FastLlm.psm1. Vulkan Resizable-BAR mitigation policy (-VulkanBarMitigation), advisory Resizable-BAR
# detector and advisory post-Ready throughput canary. Every default is OFF; see docs/research/VULKAN-BAR-MITIGATION-IMPLEMENTATION.md.
# Nothing here changes the catalog, the engine arguments or any default child environment.

# off | on | auto. off = no mitigation; on = set GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM=1 on the Vulkan lane; auto = only when
# the detector confidently classifies Resizable BAR as off. The default MUST stay 'off' until the Resizable-BAR-on
# harm check has passed and been reviewed.
$script:FastLlmVulkanBarMitigationPolicy = 'off'
$script:FastLlmVulkanBarMitigationVariable = 'GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM'
# Bumped whenever the classification rules change; recorded in the policy record and part of the per-boot cache.
$script:FastLlmVulkanBarDetectorVersion = 'rebar-heap-layout-v2'
# The mitigation (explicit on or auto) is only applied to engine builds whose behaviour was measured.
$script:FastLlmVulkanBarVerifiedEngines = @('b10698')
$script:FastLlmVulkanBarCacheFileName = 'vulkan-rebar-detection-cache.json'
# Cache entry schema 5: key (detector, adapter name, present-device driver version, matched PnP InstanceIds), bootUtc
# (compared within 60 s), sleepDeltaMs (must not grow by more than 5 s), sleepDeltaSource (interrupt-time | tick-fallback) and the
# fixed sources. Schema 4 and older are invalidated.
$script:FastLlmVulkanBarCacheSchemaVersion = 5
$script:FastLlmVulkanBarSleepDeltaSources = @('interrupt-time', 'tick-fallback')
$script:FastLlmVulkanBarBootToleranceSeconds = 60
# Sleep accounting (QueryInterruptTime - QueryUnbiasedInterruptTime, or GetTickCount64 - QueryUnbiasedInterruptTime when the
# api-ms-win-core-realtime API set is unavailable): the entry is valid only while the current delta minus the stored one is within 0..5000 ms. Growth means the machine slept or hibernated (including a Fast Startup shutdown).
$script:FastLlmVulkanBarSleepDeltaToleranceMs = 5000
# A drop of up to this many ms is read jitter (the tick-based fallback), never a sleep: it still counts as no sleep.
$script:FastLlmVulkanBarSleepDeltaJitterMs = 50
$script:FastLlmVulkanBarSleepDeltaMaxMs = 1000000000000
# A separate DEVICE_LOCAL heap at or below this size is the BAR aperture seen when Resizable BAR is off (224/240/256/512 MiB).
$script:FastLlmRebarSmallHeapMaxBytes = [double]536870912
$script:FastLlmRebarLargeHeapMinBytes = [double]1073741824
# Reviewed prompt-processing floors for the advisory canary (tokens/s, fixed 512-token prompt), keyed by model id AND
# card. Only the 27B catalog models have a reviewed floor; any other model is unrated. Word boundaries matter:
# "RX 7900 XT" is a substring of "RX 7900 XTX".
$script:FastLlmThroughputFloors = @(
    [pscustomobject]@{ modelPattern = '^qwen3\.8-27b-'; card = 'RX 7900 XTX'; pattern = '(?i)\bRX 7900 XTX\b'; ppTokPerS = [double]200; source = 'reviewed-27b-card-floor' },
    [pscustomobject]@{ modelPattern = '^qwen3\.8-27b-'; card = 'RX 7900 XT'; pattern = '(?i)\bRX 7900 XT\b'; ppTokPerS = [double]200; source = 'reviewed-27b-card-floor' }
)
$script:FastLlmThroughputCanaryPromptTokens = 512
$script:FastLlmThroughputCanaryGenerationTokens = 16

function ConvertTo-FastLlmVulkanBarMitigationName {
    param([string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'off' }
    switch -Exact ($Value.Trim().ToLowerInvariant()) {
        'off' { return 'off' }
        'on' { return 'on' }
        'auto' { return 'auto' }
        default { throw "Unknown Vulkan Resizable BAR mitigation '$Value'. Use off, on or auto." }
    }
}

function Get-FastLlmVulkanBarOptional {
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    # The comma keeps a one-element array an array (it would otherwise be unrolled to its element).
    if ($property) { return ,$property.Value }
    return $null
}

# Pure classifier over Vulkan memory heaps ({sizeBytes, deviceLocal}) of ONE device. Returns {classification, reason}.
#   rebar-off: exactly one large (>= 1 GiB) device-local heap AND exactly one small (<= 512 MiB) device-local heap.
#   rebar-on:  exactly one device-local heap and it is large (any number of non-device-local heaps).
#   anything else is unknown with a precise reason (extra 768 MiB / 1 GiB heaps, partial-BAR splits, several large heaps).
function Get-FastLlmVulkanBarClassificationDetail {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()][object[]] $Heaps)
    $unknown = { param($Reason) [pscustomobject]@{ classification = 'unknown'; reason = $Reason } }
    $small = 0
    $middle = 0
    $large = 0
    $heapCount = 0
    foreach ($heap in @($Heaps)) {
        $heapCount++
        if ($null -eq $heap) { return (& $unknown 'heap-data-invalid') }
        $sizeProperty = $heap.PSObject.Properties['sizeBytes']
        $localProperty = $heap.PSObject.Properties['deviceLocal']
        if (-not $sizeProperty -or -not $localProperty -or $localProperty.Value -isnot [bool]) { return (& $unknown 'heap-data-invalid') }
        $size = 0.0
        if (-not [double]::TryParse([string]$sizeProperty.Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$size) -or
            [double]::IsNaN($size) -or [double]::IsInfinity($size) -or $size -lt 0) { return (& $unknown 'heap-data-invalid') }
        if (-not [bool]$localProperty.Value) { continue }
        if ($size -eq 0) { return (& $unknown 'heap-data-invalid') }
        if ($size -le $script:FastLlmRebarSmallHeapMaxBytes) { $small++ }
        elseif ($size -ge $script:FastLlmRebarLargeHeapMinBytes) { $large++ }
        else { $middle++ }
    }
    if ($heapCount -eq 0) { return (& $unknown 'no-heaps') }
    if ($large -eq 0) { return (& $unknown 'no-large-device-local-heap') }
    if ($large -ge 2) { return (& $unknown 'multiple-large-device-local-heaps') }
    if ($middle -ge 1) { return (& $unknown 'extra-device-local-heap-of-unrecognized-size') }
    if ($small -ge 2) { return (& $unknown 'multiple-small-device-local-heaps') }
    if ($small -eq 1) { return [pscustomobject]@{ classification = 'rebar-off'; reason = 'separate-small-device-local-heap' } }
    return [pscustomobject]@{ classification = 'rebar-on'; reason = 'no-separate-small-device-local-heap' }
}

function Get-FastLlmVulkanBarClassification {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()][object[]] $Heaps)
    return [string](Get-FastLlmVulkanBarClassificationDetail -Heaps $Heaps).classification
}

# Vulkan deviceType: discrete (2) is classified; integrated (1) is excluded; anything else is not classified.
function Get-FastLlmVulkanBarDeviceKind {
    param($Device)
    $name = Get-FastLlmVulkanBarOptional $Device 'deviceTypeName'
    if ($null -ne $name -and -not [string]::IsNullOrWhiteSpace([string]$name)) {
        switch -Exact (([string]$name).Trim().ToLowerInvariant()) {
            'discrete' { return 'discrete' }
            'integrated' { return 'integrated' }
            default { return 'other' }
        }
    }
    $type = Get-FastLlmVulkanBarOptional $Device 'deviceType'
    if ($null -ne $type) {
        $number = 0
        if ([int]::TryParse([string]$type, [ref]$number)) {
            if ($number -eq 2) { return 'discrete' }
            if ($number -eq 1) { return 'integrated' }
            return 'other'
        }
    }
    return 'unavailable'
}

# Classifies the selected adapter(s) from a collect-vulkan-luid-join report. The ggml device index is not assumed to
# equal the raw vkEnumeratePhysicalDevices index. A selected adapter is joined to a probe device by, in order:
#   1. adapter LUID (luid / deviceLuid / vulkanLuid, 16 hex digits) == the report device's deviceLuid;
#   2. adapter PnP instance id == a unique report join row's pnpInstanceId (its vulkanIndex);
#   3. exact name: the number of probe devices with that name must equal the number of selections with that name (identical
#      cards all selected); a sole probe device matches only an unnamed selection, never a named one that differs.
# Anything ambiguous is unknown, and the matched device count must equal the number of selections. Only discrete AMD
# (vendor 0x1002) devices are classified. All selected devices must agree; a disagreement is
# unknown with reason selected-devices-disagree (the mitigation is process-wide, so it is never applied on a partial match).
function Get-FastLlmVulkanRebarState {
    [CmdletBinding()]
    param($Report, [string[]] $AdapterNames, [object[]] $Adapters)
    $version = $script:FastLlmVulkanBarDetectorVersion
    $unknown = { param($Reason) [pscustomobject]@{ classification = 'unknown'; reason = $Reason; detectorVersion = $version; deviceCount = 0 } }
    if ($null -eq $Report) { return (& $unknown 'no-report') }
    $devicesProperty = $Report.PSObject.Properties['devices']
    $samplesProperty = $Report.PSObject.Properties['budgetSamples']
    if (-not $devicesProperty -or -not $samplesProperty) { return (& $unknown 'report-shape') }
    $devices = @($devicesProperty.Value)
    $samples = @($samplesProperty.Value)
    if ($devices.Count -eq 0 -or $samples.Count -eq 0 -or -not $samples[0].PSObject.Properties['vulkan']) { return (& $unknown 'no-vulkan-device') }
    $rows = @($samples[0].vulkan)
    $joinRows = @()
    $joinsProperty = $Report.PSObject.Properties['joins']
    if ($joinsProperty) { $joinRows = @($joinsProperty.Value) }

    $selections = @()
    if ($Adapters -and @($Adapters).Count -gt 0) {
        foreach ($adapter in @($Adapters)) {
            $luid = ''
            foreach ($key in @('luid', 'deviceLuid', 'vulkanLuid')) {
                $candidate = Get-FastLlmVulkanBarOptional $adapter $key
                if ($candidate -and ([string]$candidate) -cmatch '^[0-9a-fA-F]{16}$') { $luid = ([string]$candidate).ToLowerInvariant(); break }
            }
            $pnp = [string](Get-FastLlmVulkanBarOptional $adapter 'pnpInstanceId')
            $adapterName = [string](Get-FastLlmVulkanBarOptional $adapter 'name')
            $selections += [pscustomobject]@{ name = $adapterName.Trim(); luid = $luid; pnp = $pnp }
        }
    }
    else {
        foreach ($adapterName in @($AdapterNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            $selections += [pscustomobject]@{ name = ([string]$adapterName).Trim(); luid = ''; pnp = '' }
        }
    }
    if ($selections.Count -eq 0) { $selections = @([pscustomobject]@{ name = ''; luid = ''; pnp = '' }) }

    # Resolve every selection to a set of probe-device indexes (or a precise unknown reason).
    $selectedIndexes = New-Object 'System.Collections.Generic.List[int]'
    $nameOnly = @($selections | Where-Object { -not $_.luid -and -not $_.pnp })
    foreach ($selection in @($selections | Where-Object { $_.luid -or $_.pnp })) {
        if ($selection.luid) {
            $byLuid = @($devices | Where-Object { ([string](Get-FastLlmVulkanBarOptional $_ 'deviceLuid')).ToLowerInvariant() -ceq $selection.luid -and (Get-FastLlmVulkanBarOptional $_ 'deviceLuidValid') -ne $false })
            if ($byLuid.Count -eq 0) { return (& $unknown 'luid-not-found') }
            if ($byLuid.Count -ne 1) { return (& $unknown 'luid-ambiguous') }
            [void]$selectedIndexes.Add([int]$byLuid[0].index)
        }
        else {
            $byPnp = @($joinRows | Where-Object { [string](Get-FastLlmVulkanBarOptional $_ 'status') -ceq 'unique' -and ([string](Get-FastLlmVulkanBarOptional $_ 'pnpInstanceId')) -ieq $selection.pnp })
            if ($byPnp.Count -ne 1) { return (& $unknown 'pnp-not-uniquely-joined') }
            [void]$selectedIndexes.Add([int]$byPnp[0].vulkanIndex)
        }
    }
    foreach ($group in @($nameOnly | Group-Object -Property { $_.name.ToLowerInvariant() })) {
        $groupName = [string]$group.Name
        if ($groupName -eq '') {
            if ($devices.Count -ne 1 -or $nameOnly.Count -ne 1) { return (& $unknown 'device-not-uniquely-matched') }
            [void]$selectedIndexes.Add([int]$devices[0].index)
            continue
        }
        # A named selection matches only probe devices of exactly that name (no fallback to a sole probe device), and the
        # number of matching probe devices must equal the number of selections that share the name.
        $matches2 = @($devices | Where-Object { ([string](Get-FastLlmVulkanBarOptional $_ 'deviceName')).Trim() -ieq $groupName })
        if ($matches2.Count -eq 0 -or $matches2.Count -ne @($group.Group).Count) { return (& $unknown 'device-not-uniquely-matched') }
        foreach ($device in $matches2) { [void]$selectedIndexes.Add([int]$device.index) }
    }
    $uniqueIndexes = @($selectedIndexes | Sort-Object -Unique)
    if ($uniqueIndexes.Count -ne $selectedIndexes.Count -or $uniqueIndexes.Count -ne $selections.Count) { return (& $unknown 'device-not-uniquely-matched') }

    $perDevice = @()
    foreach ($index in $uniqueIndexes) {
        $device = @($devices | Where-Object { [int]$_.index -eq $index })
        if ($device.Count -ne 1) { return (& $unknown 'device-not-uniquely-matched') }
        $kind = Get-FastLlmVulkanBarDeviceKind -Device $device[0]
        if ($kind -eq 'integrated') { return (& $unknown 'excluded-integrated') }
        if ($kind -ne 'discrete') { return (& $unknown 'device-type-not-discrete') }
        # The mitigation variable is only reviewed for AMD GPUs (PCI vendor 0x1002).
        $vendor = 0L
        if (-not [long]::TryParse([string](Get-FastLlmVulkanBarOptional $device[0] 'vendorId'), [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$vendor) -or $vendor -ne 4098) { return (& $unknown 'device-vendor-not-amd') }
        $row = @($rows | Where-Object { [int]$_.index -eq $index })
        if ($row.Count -ne 1) { return (& $unknown 'heap-sample-unavailable') }
        if ([string]$row[0].status -cne 'ok') {
            $advertised = $row[0].PSObject.Properties['memoryBudgetAdvertised']
            if ($advertised -and $advertised.Value -eq $false) { return (& $unknown 'no-budget-extension') }
            return (& $unknown 'heap-sample-unavailable')
        }
        $match = $row[0].PSObject.Properties['identityMatchesInitialEnumeration']
        if ($match -and $null -ne $match.Value -and $match.Value -ne $true) { return (& $unknown 'device-identity-changed') }
        $detail = Get-FastLlmVulkanBarClassificationDetail -Heaps @($row[0].heaps)
        $perDevice += [pscustomobject]@{ index = [int]$index; classification = [string]$detail.classification; reason = [string]$detail.reason }
    }
    $unrecognized = @($perDevice | Where-Object { $_.classification -eq 'unknown' })
    if ($unrecognized.Count -gt 0) {
        $answer = & $unknown ([string]$unrecognized[0].reason)
        $answer.deviceCount = $perDevice.Count
        return $answer
    }
    $kinds = @($perDevice | ForEach-Object { $_.classification } | Sort-Object -Unique)
    if ($kinds.Count -ne 1) {
        $answer = & $unknown 'selected-devices-disagree'
        $answer.deviceCount = $perDevice.Count
        return $answer
    }
    return [pscustomobject]@{ classification = [string]$kinds[0]; reason = [string]$perDevice[0].reason; detectorVersion = $version; deviceCount = $perDevice.Count }
}

function New-FastLlmVulkanProbeError {
    param([string] $Category, [string] $Message)
    $problem = New-Object InvalidOperationException $Message
    $problem.Data['FastLlmProbeCategory'] = $Category
    return $problem
}

# Bounded child collector. Replaceable by tests. Vulkan is loaded only inside the child, never in this process.
# Mirrors Get-FastLlmGgmlVulkanIdentity: RemoteSigned child, kill-on-close job, bounded output, sandboxed
# PATH/APPDATA/PROGRAMDATA, and a per-call temp folder (never the install root) that is always removed. Failures
# throw with Data['FastLlmProbeCategory'] = timeout | child-exit | parse | not-windows | other.
function Invoke-FastLlmVulkanHeapProbe {
    [CmdletBinding()]
    param(
        [ValidateRange(5, 120)][int] $TimeoutSeconds = 30,
        [string] $CollectorPath
    )
    if ($env:OS -ne 'Windows_NT') { throw (New-FastLlmVulkanProbeError 'not-windows' 'The Vulkan heap probe requires Windows.') }
    $projectRoot = Split-Path -Parent $PSScriptRoot
    $collector = $CollectorPath
    if ([string]::IsNullOrWhiteSpace($collector)) { $collector = Join-Path (Join-Path $projectRoot 'tools') 'collect-vulkan-luid-join.ps1' }
    if (-not (Test-Path -LiteralPath $collector -PathType Leaf)) { throw (New-FastLlmVulkanProbeError 'other' 'The Vulkan heap collector is not installed.') }
    Initialize-FastLlmProcessHost
    $sandbox = Join-Path ([IO.Path]::GetTempPath()) ('FastLlm-VkHeap-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $sandbox -ErrorAction Stop | Out-Null
    $output = Join-Path $sandbox 'report.json'
    $child = New-Object Bitworks.FastLlm.ProcessHost
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = (Get-Process -Id $PID).Path
        $info.Arguments = Join-FastLlmProcessArguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-OutputFormat', 'Text', '-ExecutionPolicy', 'RemoteSigned', '-File', $collector, '-OutputPath', $output)
        $info.WorkingDirectory = $projectRoot
        foreach ($name in @($info.EnvironmentVariables.Keys)) {
            if (Test-FastLlmEnvironmentNameRequiresClearing -Name ([string]$name)) { $info.EnvironmentVariables.Remove([string]$name) }
        }
        $info.EnvironmentVariables['APPDATA'] = $sandbox
        $info.EnvironmentVariables['PROGRAMDATA'] = $sandbox
        $info.EnvironmentVariables['PATH'] = ([Environment]::SystemDirectory + ';' + $env:SystemRoot)
        try { $child.Start($info) }
        catch { throw (New-FastLlmVulkanProbeError 'other' 'The Vulkan heap collector did not start.') }
        $remaining = [Math]::Max(1, $TimeoutSeconds * 1000 - [int]$watch.ElapsedMilliseconds)
        if (-not $child.Process.WaitForExit($remaining)) { throw (New-FastLlmVulkanProbeError 'timeout' 'The Vulkan heap collector exceeded its deadline.') }
        if ($child.Process.ExitCode -ne 0) { throw (New-FastLlmVulkanProbeError 'child-exit' 'The Vulkan heap collector failed.') }
        while (-not $child.OutputCompleted -and $watch.ElapsedMilliseconds -lt $TimeoutSeconds * 1000) { Start-Sleep -Milliseconds 20 }
        if (-not $child.OutputCompleted) { throw (New-FastLlmVulkanProbeError 'timeout' 'The Vulkan heap collector output did not reach EOF within its deadline.') }
        if (-not (Test-Path -LiteralPath $output -PathType Leaf)) { throw (New-FastLlmVulkanProbeError 'parse' 'The Vulkan heap collector wrote no report.') }
        $item = Get-Item -LiteralPath $output -Force
        if ($item.Length -gt 4194304 -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw (New-FastLlmVulkanProbeError 'parse' 'The Vulkan heap report is unsafe or oversized.') }
        try { return (Read-FastLlmJson -Path $output) }
        catch { throw (New-FastLlmVulkanProbeError 'parse' 'The Vulkan heap report could not be parsed.') }
    }
    finally {
        # Dispose kills the whole child tree (kill-on-close job) before the report folder is removed.
        $child.Dispose()
        for ($attempt = 0; $attempt -lt 5 -and (Test-Path -LiteralPath $sandbox); $attempt++) {
            Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $sandbox) { Start-Sleep -Milliseconds 200 }
        }
    }
}

# Advisory detector entry point: never throws, always returns a classification, a probe status
# (ok | timeout | child-exit | parse | no-budget-extension | not-windows | other) and the probe duration.
function Get-FastLlmVulkanRebarDetection {
    [CmdletBinding()]
    param([string[]] $AdapterNames, [object[]] $Adapters)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $result = { param($Classification, $Reason, $Status) [pscustomobject]@{ classification = $Classification; reason = $Reason; probeStatus = $Status; probeDurationMs = [int]$watch.ElapsedMilliseconds; detectorVersion = $script:FastLlmVulkanBarDetectorVersion } }
    try {
        $report = Invoke-FastLlmVulkanHeapProbe
        if ($null -eq $report) { return (& $result 'unknown' 'probe-unavailable' 'not-windows') }
        $state = Get-FastLlmVulkanRebarState -Report $report -AdapterNames $AdapterNames -Adapters $Adapters
        $status = 'ok'
        if ($state.classification -eq 'unknown') {
            if ($state.reason -eq 'no-budget-extension') { $status = 'no-budget-extension' }
            elseif ($state.reason -in @('no-report', 'report-shape')) { $status = 'parse' }
        }
        return (& $result ([string]$state.classification) ([string]$state.reason) $status)
    }
    catch {
        $status = 'other'
        $category = $_.Exception.Data['FastLlmProbeCategory']
        if ($category -in @('timeout', 'child-exit', 'parse', 'not-windows', 'other')) { $status = [string]$category }
        return (& $result 'unknown' 'probe-failed' $status)
    }
}

# The two native sources used by the cache are compiled in ONE Add-Type call (one csc run instead of two) and only for the
# types that are missing. Throws when the compile fails; every caller catches it and degrades to "no cache".
function Initialize-FastLlmVulkanBarNativeTypes {
    $sources = @()
    if (-not ('Bitworks.FastLlm.WindowsBootTime' -as [type])) { $sources += (Join-Path $PSScriptRoot 'WindowsBootTime.cs') }
    if (-not ('Bitworks.FastLlm.WindowsGpuIdentity' -as [type])) { $sources += (Join-Path $PSScriptRoot 'WindowsGpuIdentity.cs') }
    if ($sources.Count -gt 0) { Add-Type -Path @($sources) -ErrorAction Stop }
}

# Native boot instant (UTC, round-trip text, whole seconds; the C# source truncates it to 10 s first) from GetTickCount64,
# or $null. Replaceable by tests.
# Native only, in every session type: the cache must behave the same interactively and over SSH (no WMI on this path).
function Get-FastLlmNativeBootIdentity {
    if ($env:OS -ne 'Windows_NT') { return $null }
    try {
        Initialize-FastLlmVulkanBarNativeTypes
        $ticks = [long][Bitworks.FastLlm.WindowsBootTime]::BootUtcTicksTruncated()
        $ticks = $ticks - ($ticks % 10000000L)
        if ($ticks -le 0) { return $null }
        return ([datetime]::new($ticks, [DateTimeKind]::Utc)).ToString('o')
    }
    catch { return $null }
}

# Boot instant used by the BAR cache (UTC round-trip text) or $null. Replaceable by tests. The Resizable BAR setting
# only changes across a reboot; the boot instant is stored in the entry and compared with a 60 s tolerance, not keyed.
function Get-FastLlmVulkanBarBootIdentity {
    return (Get-FastLlmNativeBootIdentity)
}

# Native sleep delta in milliseconds (QueryInterruptTime - QueryUnbiasedInterruptTime, or the GetTickCount64 fallback; never negative)
# or $null. Replaceable by tests.
# The boot instant survives a Fast Startup power-off (the tick count includes sleep and hibernation); this delta does not.
function Get-FastLlmVulkanBarSleepDelta {
    if ($env:OS -ne 'Windows_NT') { return $null }
    try {
        Initialize-FastLlmVulkanBarNativeTypes
        return [long][Bitworks.FastLlm.WindowsBootTime]::SleepDeltaMilliseconds()
    }
    catch { return $null }
}

# Which path produced the last sleep delta (interrupt-time | tick-fallback) or $null. Replaceable by tests. Call after the delta read.
function Get-FastLlmVulkanBarSleepDeltaSource {
    if ($env:OS -ne 'Windows_NT') { return $null }
    try {
        Initialize-FastLlmVulkanBarNativeTypes
        return [string][Bitworks.FastLlm.WindowsBootTime]::SleepDeltaSource
    }
    catch { return $null }
}

# Present display-class PnP records (SetupAPI, DIGCF_PRESENT; never WMI, never absent devices). Replaceable by tests.
function Get-FastLlmVulkanBarPnpRecords {
    if ($env:OS -ne 'Windows_NT') { return @() }
    try {
        Initialize-FastLlmVulkanBarNativeTypes
        return @([Bitworks.FastLlm.WindowsGpuIdentity]::ReadPnP())
    }
    catch { return @() }
}

# Present device for one adapter name: exact case-insensitive whole-string Description match, AMD PCI vendor only, and every
# match must agree on a non-empty DriverVersion; otherwise $null (the cache then stays unavailable). Returns the agreed
# driver version and the matched InstanceIds (lower case, sorted, unique).
function Get-FastLlmVulkanBarPresentDevice {
    param([string] $AdapterName, [object[]] $Records)
    if ([string]::IsNullOrWhiteSpace($AdapterName)) { return $null }
    $versions = @()
    $instances = @()
    foreach ($record in @($Records)) {
        if ($null -eq $record) { continue }
        $instance = [string](Get-FastLlmVulkanBarOptional $record 'InstanceId')
        $description = [string](Get-FastLlmVulkanBarOptional $record 'Description')
        $version = [string](Get-FastLlmVulkanBarOptional $record 'DriverVersion')
        if (-not $instance.StartsWith('PCI\VEN_1002', [StringComparison]::OrdinalIgnoreCase)) { continue }
        if (-not [string]::Equals($description, $AdapterName, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ([string]::IsNullOrWhiteSpace($version)) { return $null }
        if ($versions -cnotcontains $version.Trim()) { $versions += $version.Trim() }
        $lowered = $instance.Trim().ToLowerInvariant()
        if ($instances -cnotcontains $lowered) { $instances += $lowered }
    }
    if ($versions.Count -ne 1 -or $instances.Count -eq 0) { return $null }
    $sorted = [string[]]@($instances)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    return [pscustomobject]@{ driverVersion = $versions[0]; instanceIds = $sorted }
}

# Driver version for one adapter name (see Get-FastLlmVulkanBarPresentDevice), or $null.
function Get-FastLlmVulkanBarPresentDriverVersion {
    param([string] $AdapterName, [object[]] $Records)
    $device = Get-FastLlmVulkanBarPresentDevice -AdapterName $AdapterName -Records $Records
    if ($null -eq $device) { return $null }
    return [string]$device.driverVersion
}

# Cache key: detector version + each selected adapter's name, present-device driver version and matched present-device PnP
# InstanceId(s) (SetupAPI). $null (no caching) when any adapter's device cannot be proven. The plan's driverVersion and WMI
# are never used here.
function Get-FastLlmVulkanBarCacheKey {
    param([object[]] $Adapters)
    $records = @(Get-FastLlmVulkanBarPnpRecords)
    $parts = @()
    foreach ($adapter in @($Adapters)) {
        $adapterName = [string](Get-FastLlmVulkanBarOptional $adapter 'name')
        if ([string]::IsNullOrWhiteSpace($adapterName)) { return $null }
        $device = Get-FastLlmVulkanBarPresentDevice -AdapterName $adapterName -Records $records
        if ($null -eq $device -or [string]::IsNullOrWhiteSpace([string]$device.driverVersion)) { return $null }
        $parts += ($adapterName.Trim().ToLowerInvariant() + '|' + [string]$device.driverVersion + '|' + (@($device.instanceIds) -join ','))
    }
    if ($parts.Count -eq 0) { return $null }
    $orderedParts = [string[]]@($parts)
    [Array]::Sort($orderedParts, [StringComparer]::Ordinal)
    return ($script:FastLlmVulkanBarDetectorVersion + '#' + ($orderedParts -join ';'))
}

$script:FastLlmVulkanBarCacheMaxBytes = 16384

function Test-FastLlmVulkanBarInteger {
    param($Value, [long] $Minimum, [long] $Maximum)
    if ($null -eq $Value -or ($Value -isnot [int] -and $Value -isnot [long])) { return $false }
    return ([long]$Value -ge $Minimum -and [long]$Value -le $Maximum)
}

# Strict shape check of a cached detection entry: every field must have the exact type and range this module writes.
# Anything odd (strings where numbers belong, overflow, arrays, missing fields) is rejected, never cast.
function Test-FastLlmVulkanBarCacheEntry {
    param($Entry, [string] $Key, [string] $BootUtc, [long] $SleepDeltaMs)
    if ($null -eq $Entry -or $Entry.GetType().FullName -cne 'System.Management.Automation.PSCustomObject') { return $false }
    if (-not (Test-FastLlmVulkanBarInteger (Get-FastLlmVulkanBarOptional $Entry 'schemaVersion') $script:FastLlmVulkanBarCacheSchemaVersion $script:FastLlmVulkanBarCacheSchemaVersion)) { return $false }
    $entryKey = Get-FastLlmVulkanBarOptional $Entry 'key'
    if ($entryKey -isnot [string] -or $entryKey -cne $Key) { return $false }
    $classification = Get-FastLlmVulkanBarOptional $Entry 'classification'
    if ($classification -isnot [string] -or $classification -cnotin @('rebar-off', 'rebar-on')) { return $false }
    $bootSource = Get-FastLlmVulkanBarOptional $Entry 'bootTimeSource'
    if ($bootSource -isnot [string] -or $bootSource -cne 'native') { return $false }
    $driverSource = Get-FastLlmVulkanBarOptional $Entry 'driverVersionSource'
    if ($driverSource -isnot [string] -or $driverSource -cne 'setupapi-present') { return $false }
    # The entry is only valid for the same boot: |entry.bootUtc - current native boot| <= 60 s (time-sync tolerant).
    $entryBoot = Get-FastLlmVulkanBarOptional $Entry 'bootUtc'
    $entryBootTime = [datetime]::MinValue
    if ($entryBoot -is [datetime]) { $entryBootTime = $entryBoot.ToUniversalTime() }
    elseif ($entryBoot -isnot [string] -or $entryBoot.Length -gt 40 -or -not [datetime]::TryParseExact($entryBoot, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$entryBootTime)) { return $false }
    $currentBootTime = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($BootUtc, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$currentBootTime)) { return $false }
    if ([math]::Abs(($entryBootTime.ToUniversalTime() - $currentBootTime.ToUniversalTime()).TotalSeconds) -gt $script:FastLlmVulkanBarBootToleranceSeconds) { return $false }
    # Sleep or hibernation since the entry was written (Fast Startup keeps the boot instant): the sleep delta only grows.
    $entrySleep = Get-FastLlmVulkanBarOptional $Entry 'sleepDeltaMs'
    if (-not (Test-FastLlmVulkanBarInteger $entrySleep 0 $script:FastLlmVulkanBarSleepDeltaMaxMs)) { return $false }
    $sleepGrowth = [long]$SleepDeltaMs - [long]$entrySleep
    if ($sleepGrowth -lt (-1 * $script:FastLlmVulkanBarSleepDeltaJitterMs) -or $sleepGrowth -gt $script:FastLlmVulkanBarSleepDeltaToleranceMs) { return $false }
    $entrySleepSource = Get-FastLlmVulkanBarOptional $Entry 'sleepDeltaSource'
    if ($entrySleepSource -isnot [string] -or $entrySleepSource -cnotin @($script:FastLlmVulkanBarSleepDeltaSources)) { return $false }
    $reason = Get-FastLlmVulkanBarOptional $Entry 'reason'
    if ($reason -isnot [string] -or $reason -cnotmatch '^[a-z0-9][a-z0-9-]{0,95}$') { return $false }
    if (-not (Test-FastLlmVulkanBarInteger (Get-FastLlmVulkanBarOptional $Entry 'probeDurationMs') 0 3600000)) { return $false }
    $recorded = Get-FastLlmVulkanBarOptional $Entry 'recordedAtUtc'
    if ($recorded -is [datetime]) { return $true }
    if ($recorded -isnot [string] -or $recorded.Length -gt 40) { return $false }
    $parsed = [datetime]::MinValue
    return [datetime]::TryParse($recorded, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)
}

# Returns @{ status = hit | miss | invalidated; entry }. Read-only; never creates a directory. A file that is a reparse
# point, larger than 16 KiB, unparseable-but-present-with-bad-shape or otherwise odd is invalidated (re-probed and replaced).
function Read-FastLlmVulkanBarCache {
    param([string] $InstallRoot, [string] $Key, [string] $BootUtc, [long] $SleepDeltaMs, [string] $SleepDeltaSource)
    $none = @{ status = 'miss'; entry = $null }
    $invalid = @{ status = 'invalidated'; entry = $null }
    try {
        $path = Join-Path (Get-FastLlmStateRoot -InstallRoot $InstallRoot) $script:FastLlmVulkanBarCacheFileName
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $none }
        $item = Get-Item -LiteralPath $path -Force
        # Attributes -1 (every bit set) is the vanished-name transient: missing, not a reparse point.
        if ([int]$item.Attributes -eq -1) { return $none }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $invalid }
        if ($item.Length -gt $script:FastLlmVulkanBarCacheMaxBytes) { return $invalid }
        $entry = Read-FastLlmJson -Path $path -MaxBytes $script:FastLlmVulkanBarCacheMaxBytes
        if (-not (Test-FastLlmVulkanBarCacheEntry -Entry $entry -Key $Key -BootUtc $BootUtc -SleepDeltaMs $SleepDeltaMs)) { return $invalid }
        # An entry written by the other sleep path (interrupt-time vs tick-fallback) is never reused: the deltas are not comparable. A miss, then replaced.
        if ([string](Get-FastLlmVulkanBarOptional $entry 'sleepDeltaSource') -cne $SleepDeltaSource) { return $none }
        return @{ status = 'hit'; entry = $entry }
    }
    catch {
        if ($_.Exception.Data['FastLlmJsonTooLarge'] -eq $true) { return $invalid }
        return $none
    }
}

# Only called from a live start (Resolve-FastLlmVulkanBarMitigation with policy auto). Failure is advisory.
function Write-FastLlmVulkanBarCache {
    param([string] $InstallRoot, [string] $Key, $Detection, [string] $BootUtc, [long] $SleepDeltaMs, [string] $SleepDeltaSource)
    try {
        Write-FastLlmState -InstallRoot $InstallRoot -FileName $script:FastLlmVulkanBarCacheFileName -State ([ordered]@{
            schemaVersion = $script:FastLlmVulkanBarCacheSchemaVersion; key = $Key; bootUtc = $BootUtc; sleepDeltaMs = [long]$SleepDeltaMs; sleepDeltaSource = $SleepDeltaSource
            bootTimeSource = 'native'; driverVersionSource = 'setupapi-present'
            classification = [string]$Detection.classification; reason = [string]$Detection.reason
            probeDurationMs = [int]$Detection.probeDurationMs; recordedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        })
        return $true
    }
    catch { return $false }
}

# Decides the effective mitigation for one start. Policy 'off' (the default) never probes. 'on' and 'auto' only apply on
# the Vulkan lane and only on a verified engine build; 'on' never probes; 'auto' probes (or reuses this boot's cache).
# Advisory: any exception while resolving a non-off policy yields effective=off, reason=policy-error and never reaches the
# supervisor (an unknown policy NAME is a caller/config error and is still rejected up front).
function Resolve-FastLlmVulkanBarMitigation {
    [CmdletBinding()]
    param($Plan, [string] $Requested = 'off', [string] $InstallRoot)
    $requestedName = ConvertTo-FastLlmVulkanBarMitigationName $Requested
    if ($requestedName -ne 'off') {
        try { return (Resolve-FastLlmVulkanBarMitigationCore -Plan $Plan -RequestedName $requestedName -InstallRoot $InstallRoot) }
        catch {
            return [pscustomobject][ordered]@{ requested = $requestedName; effective = 'off'; reason = 'policy-error'; rebarDetected = 'not-probed'; rebarDetectionReason = $null; probeStatus = $null; probeDurationMs = $null; cachedProbeDurationMs = $null; detectionCache = 'not-used'; bootTimeSource = $null; driverVersionSource = $null; sleepDeltaSource = $null; detectorVersion = $script:FastLlmVulkanBarDetectorVersion }
        }
    }
    return [pscustomobject][ordered]@{ requested = 'off'; effective = 'off'; reason = 'policy-off'; rebarDetected = 'not-probed'; rebarDetectionReason = $null; probeStatus = $null; probeDurationMs = $null; cachedProbeDurationMs = $null; detectionCache = 'not-used'; bootTimeSource = $null; driverVersionSource = $null; sleepDeltaSource = $null; detectorVersion = $script:FastLlmVulkanBarDetectorVersion }
}

function Resolve-FastLlmVulkanBarMitigationCore {
    param($Plan, [string] $RequestedName, [string] $InstallRoot)
    $requestedName = $RequestedName
    $record = [ordered]@{ requested = $requestedName; effective = 'off'; reason = 'policy-off'; rebarDetected = 'not-probed'; rebarDetectionReason = $null; probeStatus = $null; probeDurationMs = $null; cachedProbeDurationMs = $null; detectionCache = 'not-used'; bootTimeSource = $null; driverVersionSource = $null; sleepDeltaSource = $null; detectorVersion = $script:FastLlmVulkanBarDetectorVersion }
    $backendProperty = $Plan.PSObject.Properties['backend']
    if (-not $backendProperty -or [string]$backendProperty.Value -ine 'vulkan') {
        $record.reason = 'non-vulkan-lane'
        return [pscustomobject]$record
    }
    $engineVersion = [string](Get-FastLlmVulkanBarOptional $Plan 'engineVersion')
    if ($engineVersion -cnotin @($script:FastLlmVulkanBarVerifiedEngines)) {
        $record.reason = 'engine-not-verified'
        return [pscustomobject]$record
    }
    if ($requestedName -eq 'on') {
        $record.effective = 'on'
        $record.reason = 'explicit-on'
        $record.rebarDetected = 'not-probed-explicit-on'
        return [pscustomobject]$record
    }
    $adapters = @()
    $adaptersProperty = $Plan.PSObject.Properties['selectedAdapters']
    if ($adaptersProperty) { $adapters = @(@($adaptersProperty.Value) | Where-Object { $null -ne $_ }) }
    $names = @($adapters | ForEach-Object { if ($_.PSObject.Properties['name']) { [string]$_.name } })
    $key = $null
    $bootUtc = $null
    $sleepDelta = $null
    $sleepSource = $null
    $cached = $null
    if (-not [string]::IsNullOrWhiteSpace($InstallRoot)) {
        $key = Get-FastLlmVulkanBarCacheKey -Adapters $adapters
        # The boot and sleep reads (and their native compile) are skipped whenever the key is already unusable.
        if ($key) {
            $bootUtc = [string](Get-FastLlmVulkanBarBootIdentity)
            $sleepDelta = Get-FastLlmVulkanBarSleepDelta
            $sleepSource = [string](Get-FastLlmVulkanBarSleepDeltaSource)
            if ([string]::IsNullOrWhiteSpace($bootUtc) -or ($sleepDelta -isnot [int] -and $sleepDelta -isnot [long]) -or $sleepDelta -lt 0 -or $sleepSource -cnotin @($script:FastLlmVulkanBarSleepDeltaSources)) { $key = $null }
        }
        if ($key) {
            $record.bootTimeSource = 'native'
            $record.driverVersionSource = 'setupapi-present'
            $record.sleepDeltaSource = $sleepSource
            $lookup = Read-FastLlmVulkanBarCache -InstallRoot $InstallRoot -Key $key -BootUtc $bootUtc -SleepDeltaMs ([long]$sleepDelta) -SleepDeltaSource $sleepSource
            $record.detectionCache = $lookup.status
            if ($lookup.status -eq 'hit') { $cached = $lookup.entry }
        }
        else { $record.detectionCache = 'unavailable' }
    }
    if ($cached) {
        $record.rebarDetected = [string]$cached.classification
        $record.rebarDetectionReason = [string](Get-FastLlmVulkanBarOptional $cached 'reason')
        $record.probeStatus = 'cached'
        $record.probeDurationMs = 0
        $record.cachedProbeDurationMs = [int](Get-FastLlmVulkanBarOptional $cached 'probeDurationMs')
    }
    else {
        $detection = Get-FastLlmVulkanRebarDetection -AdapterNames $names -Adapters $adapters
        $record.rebarDetected = [string]$detection.classification
        $record.rebarDetectionReason = [string]$detection.reason
        $record.probeStatus = [string]$detection.probeStatus
        $record.probeDurationMs = [int]$detection.probeDurationMs
        # Only a confident answer is cached, and only here (a live auto start); failures and unknowns are re-probed.
        if ($key -and $detection.classification -in @('rebar-off', 'rebar-on') -and $detection.probeStatus -eq 'ok') {
            if (-not (Write-FastLlmVulkanBarCache -InstallRoot $InstallRoot -Key $key -Detection $detection -BootUtc $bootUtc -SleepDeltaMs ([long]$sleepDelta) -SleepDeltaSource $sleepSource)) { $record.detectionCache = 'write-failed' }
        }
    }
    if ($record.rebarDetected -eq 'rebar-off') {
        $record.effective = 'on'
        $record.reason = 'rebar-off-detected'
    }
    elseif ($record.rebarDetected -eq 'rebar-on') { $record.reason = 'rebar-on-no-mitigation-needed' }
    else { $record.reason = 'rebar-unknown-no-mitigation' }
    return [pscustomobject]$record
}

# doctor view. Default: configured policy only, nothing probed, no child, no directory, no cache. -Probe opts in to the
# live advisory detection (never cached), and only when a Vulkan plan with a named selected adapter exists.
function Get-FastLlmVulkanMemoryDiagnostic {
    [CmdletBinding()]
    param([string[]] $AdapterNames, [string] $Backend, [switch] $Probe, [object[]] $Adapters)
    $detected = 'not-probed'
    $reason = 'probe-not-requested'
    $probeStatus = $null
    $probeDurationMs = $null
    $names = @($AdapterNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($Probe) {
        if ($Backend -ine 'vulkan' -or $names.Count -eq 0) {
            $detected = 'no-vulkan-plan'
            $reason = 'no-vulkan-plan'
        }
        else {
            $detection = Get-FastLlmVulkanRebarDetection -AdapterNames $names -Adapters $Adapters
            $detected = [string]$detection.classification
            $reason = [string]$detection.reason
            $probeStatus = [string]$detection.probeStatus
            $probeDurationMs = [int]$detection.probeDurationMs
        }
    }
    $guidance = $null
    if ($detected -eq 'rebar-off') {
        $card = $names -join ', '
        $guidance = "Resizable BAR appears to be disabled for $card, based on the Vulkan memory layout. FastLLM can work around this automatically (-VulkanBarMitigation auto); enabling it in BIOS/UEFI may still help. FastLLM changes no BIOS or driver settings."
    }
    return [pscustomobject][ordered]@{
        configuredPolicy = ConvertTo-FastLlmVulkanBarMitigationName $script:FastLlmVulkanBarMitigationPolicy
        environmentVariable = $script:FastLlmVulkanBarMitigationVariable
        detectorVersion = $script:FastLlmVulkanBarDetectorVersion
        rebarDetected = $detected
        rebarDetectionReason = $reason
        probeStatus = $probeStatus
        probeDurationMs = $probeDurationMs
        guidance = $guidance
        advisoryOnly = $true
    }
}

# Typed checks only (TimeoutException, WebException status, SocketException.SocketErrorCode); message text is never inspected.
function Test-FastLlmCanaryTimeout {
    param($ErrorRecord)
    $exception = $ErrorRecord.Exception
    for ($depth = 0; $null -ne $exception -and $depth -lt 6; $depth++) {
        if ($exception -is [TimeoutException]) { return $true }
        if ($exception -is [Net.WebException] -and $exception.Status -in @([Net.WebExceptionStatus]::Timeout, [Net.WebExceptionStatus]::RequestCanceled)) { return $true }
        if ($exception -is [Net.Sockets.SocketException] -and $exception.SocketErrorCode -eq [Net.Sockets.SocketError]::TimedOut) { return $true }
        $exception = $exception.InnerException
    }
    return $false
}

# Advisory canary: one fixed 512-token prompt-processing measurement timed by server timings, preceded by one discarded
# identical warm-up request. Never throws. Status: ok | degraded | unrated | failed. A request timeout is degraded
# (reason timeout) when the model/card has a reviewed floor, otherwise unrated; a model/card without a reviewed floor is
# never degraded.
function Invoke-FastLlmThroughputCanary {
    [CmdletBinding()]
    param([string] $BaseUrl, [int] $ContextSize, [string[]] $AdapterNames, [scriptblock] $Request, [string] $ModelId)
    $result = [ordered]@{ ppTokPerS = $null; floor = $null; floorSource = $null; warmupPpTokPerS = $null; status = 'failed'; promptTokens = $null; promptArtifactSha256 = $null; reason = $null }
    try {
        function Send-CanaryRequest {
            param($Path, $Body, $TimeoutMs)
            if ($Request) { return (& $Request $Path $Body $TimeoutMs) }
            return (Invoke-FastLlmHttp -BaseUrl $BaseUrl -Path $Path -Body $Body -TimeoutMs $TimeoutMs)
        }
        $promptTokens = [int]$script:FastLlmThroughputCanaryPromptTokens
        $generation = [int]$script:FastLlmThroughputCanaryGenerationTokens
        if ($ContextSize -gt 0 -and $promptTokens + $generation + 8 -gt $ContextSize) { $result.reason = 'context-too-small'; return [pscustomobject]$result }
        # Reviewed floor for this model AND card; nothing else is ever rated.
        $floor = $null
        $names = @($AdapterNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($names.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace($ModelId)) {
            $floorMatches = @($script:FastLlmThroughputFloors | Where-Object { $ModelId -match $_.modelPattern -and $names[0] -match $_.pattern })
            if ($floorMatches.Count -eq 1) {
                $floor = [double]$floorMatches[0].ppTokPerS
                $result.floor = $floor
                $result.floorSource = [string]$floorMatches[0].source
            }
        }
        $timedOut = { if ($null -ne $floor) { $result.status = 'degraded' } else { $result.status = 'unrated' }; $result.reason = 'timeout'; return [pscustomobject]$result }
        # Same fixed corpus and token-slicing as the benchmark producer (fastllm-repeated-prose-v1).
        $corpus = ('A local inference system should produce accurate useful answers. Measure speed consistently while preserving model quality. ' + [Environment]::NewLine) * ([int][Math]::Ceiling($promptTokens / 16) + 2)
        $tokenized = Send-CanaryRequest '/tokenize' @{ content = $corpus; add_special = $false } 20000
        if ($tokenized.Status -ne 200) { $result.reason = 'tokenize-failed'; return [pscustomobject]$result }
        $tokens = @((ConvertFrom-Json $tokenized.Body).tokens)
        if ($tokens.Count -lt $promptTokens) { $result.reason = 'corpus-too-short'; return [pscustomobject]$result }
        $prompt = @($tokens[0..($promptTokens - 1)])
        $result.promptArtifactSha256 = Get-FastLlmPromptArtifactSha256 $prompt
        $completion = @{ prompt = $prompt; n_predict = $generation; temperature = 0; seed = 42; cache_prompt = $false; ignore_eos = $true; stream = $true }
        # Discarded warm-up (first-request shader/pipeline and page-in cost); its speed is recorded but never rated.
        try {
            $warmup = Send-CanaryRequest '/completion' $completion 60000
            $warmupSample = ConvertFrom-FastLlmBenchmarkResponse $warmup $generation
        }
        catch {
            if (Test-FastLlmCanaryTimeout $_) { return (& $timedOut) }
            $result.reason = 'warmup-failed'
            return [pscustomobject]$result
        }
        if ($warmupSample.promptTokens -notin @($promptTokens, ($promptTokens + 1))) { $result.reason = 'unexpected-prompt-length'; return [pscustomobject]$result }
        $result.warmupPpTokPerS = [Math]::Round([double]$warmupSample.promptTokensPerSecond, 1)
        try {
            $response = Send-CanaryRequest '/completion' $completion 60000
            $sample = ConvertFrom-FastLlmBenchmarkResponse $response $generation
        }
        catch {
            if (Test-FastLlmCanaryTimeout $_) { return (& $timedOut) }
            $result.reason = 'canary-error'
            return [pscustomobject]$result
        }
        if ($sample.promptTokens -notin @($promptTokens, ($promptTokens + 1))) { $result.reason = 'unexpected-prompt-length'; return [pscustomobject]$result }
        $result.promptTokens = [int]$sample.promptTokens
        $result.ppTokPerS = [Math]::Round([double]$sample.promptTokensPerSecond, 1)
        if ($null -eq $floor) { $result.status = 'unrated'; $result.reason = 'no-floor-for-model-card' }
        elseif ([double]$sample.promptTokensPerSecond -lt $floor) { $result.status = 'degraded'; $result.reason = 'below-floor' }
        else { $result.status = 'ok'; $result.reason = $null }
    }
    catch {
        $result.status = 'failed'; $result.reason = 'canary-error'
        return [pscustomobject]$result
    }
    return [pscustomobject]$result
}
