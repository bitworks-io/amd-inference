# Loaded into FastLlm.psm1. GPU memory check: has part of the model's memory moved from GPU memory into shared system memory?
#
# Windows can demote a process's GPU allocations to shared system memory when another app uses the GPU, even an app started after
# FastLLM. Every layer is still reported on the GPU, so the check reads the per-process memory split of the llama-server process
# FastLLM itself started, on the adapter the plan selected (the kernel graphics statistics, as the standard user; no elevation,
# no permission change, no performance counters). Above a fixed floor of shared bytes the state is 'spilled'.
#
# States: ok | spilled | unknown. 'unknown' (a failed read, a layout mismatch, not Windows, no adapter found) is never treated as ok.
# The check is advisory: serving continues whatever it says. It is never derived from layer counts.
$script:FastLlmSpillFloorMiB = 256
$script:FastLlmSpillCheckIntervalSeconds = 60
# Time boxes for one read. The kernel query takes milliseconds; the box keeps a stuck call from delaying the 250 ms stop-file check.
$script:FastLlmSpillFirstReadBudgetMs = 2000
$script:FastLlmSpillLoopReadBudgetMs = 200
# The HIP engine has no Vulkan adapter id, so the adapter is the one holding at least this much of the server process's memory
# (dedicated + shared, so a heavily spilled process is still found).
$script:FastLlmHipAdapterMinBytes = [uint64] 1073741824
$script:FastLlmSpillOkText = 'GPU memory check: no spill to system memory detected.'
$script:FastLlmSpillUnknownText = 'GPU memory check unavailable on this system.'

# The native sources of the GPU memory check and of its private LUID cache are compiled in ONE Add-Type call (one csc run instead of
# two), only for the types that are missing. WindowsGpuIdentity.cs is deliberately NOT part of it: nothing on this path needs it.
function Initialize-FastLlmSpillNativeTypes {
    $sources = @()
    if (-not ('Bitworks.FastLlm.WindowsGpuProcessMemory' -as [type])) { $sources += (Join-Path $PSScriptRoot 'WindowsGpuProcessMemory.cs') }
    if (-not ('Bitworks.FastLlm.WindowsBootTime' -as [type])) { $sources += (Join-Path $PSScriptRoot 'WindowsBootTime.cs') }
    if ($sources.Count -gt 0) { Add-Type -Path @($sources) -ErrorAction Stop }
}

function Initialize-FastLlmGpuProcessMemory {
    Initialize-FastLlmSpillNativeTypes
}

# Replaceable by tests: native boot instant (UTC round-trip text, whole seconds) for the LUID cache, or $null. Needs only WindowsBootTime.
function Get-FastLlmSpillBootIdentity {
    if ($env:OS -ne 'Windows_NT') { return $null }
    try {
        Initialize-FastLlmSpillNativeTypes
        $ticks = [long][Bitworks.FastLlm.WindowsBootTime]::BootUtcTicksTruncated()
        $ticks = $ticks - ($ticks % 10000000L)
        if ($ticks -le 0) { return $null }
        return ([datetime]::new($ticks, [DateTimeKind]::Utc)).ToString('o')
    }
    catch { return $null }
}

# Replaceable by tests: native sleep delta in milliseconds for the LUID cache, or $null.
function Get-FastLlmSpillSleepDelta {
    if ($env:OS -ne 'Windows_NT') { return $null }
    try {
        Initialize-FastLlmSpillNativeTypes
        return [long][Bitworks.FastLlm.WindowsBootTime]::SleepDeltaMilliseconds()
    }
    catch { return $null }
}

function Get-FastLlmSpillValue {
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] }; return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

# Only a short lowercase code may be recorded; anything else (free text from elsewhere) becomes read-failed.
function Get-FastLlmSpillErrorCode {
    param($Code)
    $text = [string] $Code
    if ($text.Length -ge 1 -and $text.Length -le 48 -and $text -cmatch '^[a-z0-9]+(-[a-z0-9]+)*$') { return $text }
    return 'read-failed'
}

# One read of the server process's memory split. NEVER throws. Returns { SharedBytes; DedicatedBytes; Error }; Error is $null on success.
# $Reader is a test seam: & $Reader $Luid $Process $BudgetMs returning an object (or dictionary) with the same three fields.
function Read-FastLlmSpillSample {
    param([string] $Luid, $Process, [int] $BudgetMs = 200, [scriptblock] $Reader)
    $failed = { param($code) [pscustomobject]@{ SharedBytes = $null; DedicatedBytes = $null; Error = $code } }
    if ([string]::IsNullOrEmpty($Luid) -or $Luid -cnotmatch '^[0-9a-f]{16}$') { return (& $failed 'no-luid') }
    if ($null -eq $Process) { return (& $failed 'no-process') }
    try {
        if ($Reader) { $observation = & $Reader $Luid $Process $BudgetMs }
        else {
            if ($env:OS -ne 'Windows_NT') { return (& $failed 'not-windows') }
            try { Initialize-FastLlmGpuProcessMemory } catch { return (& $failed 'compile-failed') }
            $observation = [Bitworks.FastLlm.WindowsGpuProcessMemory]::ReadWithin($Luid, $Process, $BudgetMs)
        }
        $errorValue = Get-FastLlmSpillValue $observation 'Error'
        if ($null -ne $errorValue -and -not [string]::IsNullOrEmpty([string] $errorValue)) { return (& $failed (Get-FastLlmSpillErrorCode $errorValue)) }
        $shared = Get-FastLlmSpillValue $observation 'SharedBytes'
        $dedicated = Get-FastLlmSpillValue $observation 'DedicatedBytes'
        if ($null -eq $shared -or $null -eq $dedicated) { return (& $failed 'no-data') }
        return [pscustomobject]@{ SharedBytes = [uint64] $shared; DedicatedBytes = [uint64] $dedicated; Error = $null }
    }
    catch { return (& $failed 'read-failed') }
}

# Pure rule: which adapter holds the server process's memory? Readings are { luid; dedicatedBytes; sharedBytes } from a successful read of
# the process on each adapter. Exactly one adapter with dedicated + shared at or above the minimum is the adapter; none or several is
# never a guess. Returns { luid; reason } with reason selected | adapter-not-identified | adapter-ambiguous | no-readings.
function Select-FastLlmProcessAdapter {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()][object[]] $Readings,
        [uint64] $MinTotalBytes = $script:FastLlmHipAdapterMinBytes
    )
    try {
        $counted = 0
        $candidates = @()
        foreach ($reading in @($Readings)) {
            if ($null -eq $reading) { continue }
            $luidValue = Get-FastLlmSpillValue $reading 'luid'
            $dedicatedValue = Get-FastLlmSpillValue $reading 'dedicatedBytes'
            $sharedValue = Get-FastLlmSpillValue $reading 'sharedBytes'
            if ($null -eq $dedicatedValue -or $null -eq $sharedValue -or [string]::IsNullOrEmpty([string] $luidValue)) { continue }
            [uint64] $dedicated = 0
            [uint64] $shared = 0
            try { $dedicated = [uint64] $dedicatedValue; $shared = [uint64] $sharedValue } catch { continue }
            $counted++
            # Saturating sum: it never wraps.
            [uint64] $total = [uint64]::MaxValue
            if ($dedicated -le ([uint64]::MaxValue - $shared)) { $total = $dedicated + $shared }
            if ($total -ge $MinTotalBytes) { $candidates += ([string] $luidValue).ToLowerInvariant() }
        }
        if ($counted -eq 0) { return [pscustomobject]@{ luid = $null; reason = 'no-readings' } }
        if ($candidates.Count -eq 1) { return [pscustomobject]@{ luid = $candidates[0]; reason = 'selected' } }
        if ($candidates.Count -eq 0) { return [pscustomobject]@{ luid = $null; reason = 'adapter-not-identified' } }
        return [pscustomobject]@{ luid = $null; reason = 'adapter-ambiguous' }
    }
    catch { return [pscustomobject]@{ luid = $null; reason = 'no-readings' } }
}

# Every adapter LUID the system knows (16 lowercase hex digits). Never throws; an empty list on any failure.
function Get-FastLlmGpuAdapterLuids {
    try {
        if ($env:OS -ne 'Windows_NT') { return @() }
        Initialize-FastLlmGpuProcessMemory
        $enumeration = [Bitworks.FastLlm.WindowsGpuProcessMemory]::EnumerateAdapterLuids()
        if ($null -eq $enumeration -or $null -eq $enumeration.Luids) { return @() }
        return @($enumeration.Luids)
    }
    catch { return @() }
}

# Find the adapter by the server process's own memory: read the process on every adapter inside ONE time budget (each read gets only
# what is left of it, and no read starts once it is spent), then apply the rule. Never throws.
# Seams (tests): $Enumerator returns the LUID list; $Reader is the Read-FastLlmSpillSample reader; $Clock returns elapsed milliseconds.
# Returns { luid; reason; sample }; sample is the read on the selected adapter, $null otherwise.
function Find-FastLlmProcessAdapter {
    param($Process, [int] $BudgetMs = 2000, [scriptblock] $Enumerator, [scriptblock] $Reader, [scriptblock] $Clock)
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $elapsed = { if ($Clock) { [double] (& $Clock) } else { [double] $stopwatch.Elapsed.TotalMilliseconds } }
    $none = { param($reason) [pscustomobject]@{ luid = $null; reason = $reason; sample = $null } }
    try {
        $startedAt = & $elapsed
        $luids = @()
        try { if ($Enumerator) { $luids = @(& $Enumerator) } else { $luids = @(Get-FastLlmGpuAdapterLuids) } } catch { $luids = @() }
        $readings = @()
        $samples = @{}
        foreach ($candidate in $luids) {
            $remaining = $BudgetMs - ((& $elapsed) - $startedAt)
            if ($remaining -lt 1) { break }
            $sample = Read-FastLlmSpillSample -Luid ([string] $candidate) -Process $Process -BudgetMs ([int] [math]::Floor($remaining)) -Reader $Reader
            if ($null -ne $sample.Error) { continue }
            $key = ([string] $candidate).ToLowerInvariant()
            $readings += [pscustomobject]@{ luid = $key; dedicatedBytes = $sample.DedicatedBytes; sharedBytes = $sample.SharedBytes }
            $samples[$key] = $sample
        }
        $selection = Select-FastLlmProcessAdapter -Readings $readings
        if ([string] $selection.reason -ceq 'selected') { return [pscustomobject]@{ luid = [string] $selection.luid; reason = 'selected'; sample = $samples[[string] $selection.luid] } }
        return (& $none ([string] $selection.reason))
    }
    catch { return (& $none 'no-readings') }
}

# The sample to the status block { state, sharedMiB, dedicatedMiB, floorMiB, checkedAtUtc, error }. Pure.
function ConvertTo-FastLlmSpillCheck {
    param($Sample, [datetime] $Now)
    $floor = [int] $script:FastLlmSpillFloorMiB
    $state = 'unknown'
    $shared = $null
    $dedicated = $null
    $errorCode = $null
    $sampleError = Get-FastLlmSpillValue $Sample 'Error'
    $sharedBytes = Get-FastLlmSpillValue $Sample 'SharedBytes'
    $dedicatedBytes = Get-FastLlmSpillValue $Sample 'DedicatedBytes'
    if ($null -eq $Sample) { $errorCode = 'no-data' }
    elseif ($null -ne $sampleError -and -not [string]::IsNullOrEmpty([string] $sampleError)) { $errorCode = Get-FastLlmSpillErrorCode $sampleError }
    elseif ($null -eq $sharedBytes -or $null -eq $dedicatedBytes) { $errorCode = 'no-data' }
    else {
        $shared = [math]::Round(([double] $sharedBytes) / 1048576, 1)
        $dedicated = [math]::Round(([double] $dedicatedBytes) / 1048576, 1)
        # The comparison is on bytes: exactly the floor is ok, one byte more is spilled.
        if ([uint64] $sharedBytes -gt ([uint64] $floor * 1048576)) { $state = 'spilled' } else { $state = 'ok' }
    }
    return [pscustomobject][ordered]@{
        state = $state; sharedMiB = $shared; dedicatedMiB = $dedicated; floorMiB = $floor
        checkedAtUtc = $Now.ToUniversalTime().ToString('o'); error = $errorCode
    }
}

# The detector step: the new block plus the event to log. The first result is 'spill-check'; later results log only a change of state
# ('spill-check-changed'). Pure.
function Step-FastLlmSpillCheck {
    param($Previous, $Sample, [datetime] $Now)
    $next = ConvertTo-FastLlmSpillCheck -Sample $Sample -Now $Now
    $from = $null
    if ($null -ne $Previous) { $from = [string] (Get-FastLlmSpillValue $Previous 'state') }
    $eventName = $null
    if ($null -eq $Previous) { $eventName = 'spill-check' }
    elseif ($from -cne [string] $next.state) { $eventName = 'spill-check-changed' }
    return [pscustomobject][ordered]@{ spillCheck = $next; event = $eventName; from = $from; to = [string] $next.state }
}

# Run-log fields for a step's event: numbers and the state names only, no text.
function Get-FastLlmSpillCheckEventFields {
    param($Step)
    if ([string] $Step.event -ceq 'spill-check-changed') {
        return [ordered]@{ from = [string] $Step.from; to = [string] $Step.to; sharedMiB = $Step.spillCheck.sharedMiB; dedicatedMiB = $Step.spillCheck.dedicatedMiB }
    }
    return [ordered]@{ state = [string] $Step.spillCheck.state; sharedMiB = $Step.spillCheck.sharedMiB; dedicatedMiB = $Step.spillCheck.dedicatedMiB; floorMiB = $Step.spillCheck.floorMiB }
}

# The one scheduled tick of the post-Ready loop: $null when the check is not due, otherwise the detector step plus the next due time.
# Never throws. The read is time-boxed (FastLlmSpillLoopReadBudgetMs), so the loop's 250 ms stop-file cadence is kept.
function Invoke-FastLlmSpillCheckTick {
    param($Previous, [datetime] $Now, [datetime] $NextDueUtc, [string] $Luid, $Process, [scriptblock] $Reader, [scriptblock] $Reidentify)
    if ($Now -lt $NextDueUtc) { return $null }
    $sample = Read-FastLlmSpillSample -Luid $Luid -Process $Process -BudgetMs ([int] $script:FastLlmSpillLoopReadBudgetMs) -Reader $Reader
    $newLuid = $null
    # A non-Vulkan plan found its adapter by the process's memory. A failed read on it re-identifies once; if that fails too the check is unknown.
    if ($null -ne $sample.Error -and $Reidentify) {
        try {
            $found = & $Reidentify
            if ($null -ne $found -and [string] (Get-FastLlmSpillValue $found 'reason') -ceq 'selected' -and $null -ne (Get-FastLlmSpillValue $found 'sample')) {
                $sample = Get-FastLlmSpillValue $found 'sample'
                $newLuid = [string] (Get-FastLlmSpillValue $found 'luid')
            }
        }
        catch { $null = $_ }
    }
    $step = Step-FastLlmSpillCheck -Previous $Previous -Sample $sample -Now $Now
    $step | Add-Member -NotePropertyName nextDueUtc -NotePropertyValue $Now.AddSeconds([int] $script:FastLlmSpillCheckIntervalSeconds)
    if ($null -ne $newLuid) { $step | Add-Member -NotePropertyName luid -NotePropertyValue $newLuid }
    return $step
}

# The first check, once, right after the self-test (so the KV buffer exists). Never throws.
function Invoke-FastLlmSpillCheckInitial {
    param([string] $Luid, $Process, [scriptblock] $Reader)
    $sample = Read-FastLlmSpillSample -Luid $Luid -Process $Process -BudgetMs ([int] $script:FastLlmSpillFirstReadBudgetMs) -Reader $Reader
    return (Step-FastLlmSpillCheck -Previous $null -Sample $sample -Now (Get-Date).ToUniversalTime())
}

# The first check for a start: resolves the LUID, then reads once. Returns the step with the LUID kept as 'luid' for the loop's re-checks.
function Invoke-FastLlmSpillCheckAtReady {
    param($Plan, [string] $InstallRoot, $KnownLuid, $BarDecision, $Process, [scriptblock] $Reader, [scriptblock] $Enumerator, [scriptblock] $Clock)
    $found = @{}
    $luid = Get-FastLlmSpillCheckLuid -Plan $Plan -InstallRoot $InstallRoot -KnownLuid $KnownLuid -BarDecision $BarDecision -Process $Process -Reader $Reader -Enumerator $Enumerator -Clock $Clock -Found $found
    if ($null -ne $found['sample']) {
        # The identifying read is the first read: the process was already read on the selected adapter inside the first-read budget.
        $step = Step-FastLlmSpillCheck -Previous $null -Sample $found['sample'] -Now (Get-Date).ToUniversalTime()
    }
    else { $step = Invoke-FastLlmSpillCheckInitial -Luid ([string] $luid) -Process $Process -Reader $Reader }
    # A LUID that came from the private cache and whose first read failed may be stale: drop the cache, collect once (fresh), read once
    # more. Never more than one retry.
    if ($found['luidSource'] -ceq 'cache' -and $null -ne $step.spillCheck.error) {
        Remove-FastLlmSpillLuidCache -InstallRoot $InstallRoot
        $retry = @{}
        $luid = Get-FastLlmSpillCheckLuid -Plan $Plan -InstallRoot $InstallRoot -KnownLuid $KnownLuid -BarDecision $BarDecision -Process $Process -Reader $Reader -Enumerator $Enumerator -Clock $Clock -Found $retry -NoCache
        $step = Invoke-FastLlmSpillCheckInitial -Luid ([string] $luid) -Process $Process -Reader $Reader
    }
    $step | Add-Member -NotePropertyName luid -NotePropertyValue ([string] $luid)
    return $step
}

# The text for a status block (window status line, CLI after Ready, background status). $null without a block.
function Get-FastLlmSpillCheckText {
    param($SpillCheck)
    if ($null -eq $SpillCheck) { return $null }
    switch ([string] (Get-FastLlmSpillValue $SpillCheck 'state')) {
        'ok' { return $script:FastLlmSpillOkText }
        'spilled' {
            $sharedMiB = Get-FastLlmSpillValue $SpillCheck 'sharedMiB'
            $gb = ([double] $sharedMiB / 1024).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)
            return "Part of the model's memory spilled to system RAM (about $gb GB), probably because another app is using the GPU. Long chats will be slower. Close GPU apps and restart FastLLM."
        }
        'unknown' { return $script:FastLlmSpillUnknownText }
    }
    return $null
}

# A start whose check is not ok has self-test numbers that are not comparable with other runs.
function Set-FastLlmSelfTestSpillMark {
    param($SelfTest, $SpillCheck)
    if ($null -eq $SelfTest) { return $null }
    if ([string] (Get-FastLlmSpillValue $SpillCheck 'state') -cne 'ok' -and $null -ne $SelfTest.PSObject.Properties['comparable']) { $SelfTest.comparable = $false }
    return $SelfTest
}

# Exported for callers that gate on the check (the benchmark here, the bench path elsewhere).
# Returns 'ok', 'spilled' or 'unknown' from a status document; a missing or unrecognised block is 'unknown', never 'ok'.
#
# FOR CALLERS: a verdict of 'spilled' at ANY point during a bench test run is a test-validity stop. The measurements taken so far
# cannot be compared with healthy runs, so the run is not graded. Re-read the status during the run (the server re-checks every
# 60 seconds), not only at its start. 'unknown' is recorded as a note on the result ("GPU memory check unavailable"); it is
# never a stop and never treated as ok (no residency claim is made from it).
function Get-FastLlmSpillCheckVerdict {
    [CmdletBinding()]
    param($Status)
    $block = Get-FastLlmSpillValue $Status 'spillCheck'
    $state = [string] (Get-FastLlmSpillValue $block 'state')
    if ($state -ceq 'ok' -or $state -ceq 'spilled') { return $state }
    return 'unknown'
}

# For the bench path: 'ok', 'validity-stop' (spilled) or 'note' (unknown, including a missing block). Never a stop for unknown.
function Get-FastLlmSpillCheckBenchOutcome {
    [CmdletBinding()]
    param($Status)
    $verdict = Get-FastLlmSpillCheckVerdict -Status $Status
    if ($verdict -ceq 'ok') { return 'ok' }
    if ($verdict -ceq 'spilled') { return 'validity-stop' }
    return 'note'
}

# Benchmark tracker. A spill refuses the run at the start and fails it during the run. An unavailable check (for example an engine whose
# adapter could not be identified) never refuses: the track records the worst state seen and the result is labelled.
# Returns the updated track { state = ok|unknown; label = $null|'GPU memory check unavailable'; checks = count }. A $null Track starts one.
function Step-FastLlmBenchmarkSpillTrack {
    param($Track, $Status, [ValidateSet('start', 'run')][string] $Phase = 'start')
    $verdict = Get-FastLlmSpillCheckVerdict -Status $Status
    if ($verdict -ceq 'spilled') {
        if ($Phase -ceq 'run') { throw (New-FastLlmBenchmarkFailure 'gpu-memory-spill' 'Part of the model memory spilled to system RAM during the benchmark; the result is invalid. Close other GPU apps and restart FastLLM.') }
        throw (New-FastLlmBenchmarkFailure 'gpu-memory-spill' 'Part of the model memory spilled to system RAM, so measurements would not be comparable. Close other GPU apps and restart FastLLM.')
    }
    $checks = 0
    $wasUnknown = $false
    if ($null -ne $Track) {
        $checks = [int] $Track.checks
        $wasUnknown = ([string] $Track.state -ceq 'unknown')
    }
    $unknown = ($wasUnknown -or $verdict -cne 'ok')
    $state = 'ok'
    $label = $null
    if ($unknown) { $state = 'unknown'; $label = 'GPU memory check unavailable' }
    return [pscustomobject][ordered]@{ state = $state; label = $label; checks = ($checks + 1) }
}

# The adapter LUID (16 lowercase hex digits) of the device the binding resolved, from the Vulkan to DXGI join report. $null unless the
# binding is bound. Pure.
function Get-FastLlmDeviceBindingLuid {
    param($Report, $Resolved)
    if ($null -eq $Resolved -or [string] $Resolved.status -cne 'bound' -or $null -eq $Resolved.device) { return $null }
    $index = $Resolved.device.rawVulkanIndex
    if ($null -eq $index) { return $null }
    $matches2 = @(@(Get-FastLlmDeviceBindingList $Report 'devices') | Where-Object {
            $candidate = Get-FastLlmDeviceBindingValue $_ 'index'
            $null -ne $candidate -and [int] $candidate -eq [int] $index })
    if ($matches2.Count -ne 1) { return $null }
    $value = [string] (Get-FastLlmDeviceBindingValue $matches2[0] 'deviceLuid')
    if ((Get-FastLlmDeviceBindingValue $matches2[0] 'deviceLuidValid') -eq $false) { return $null }
    if ($value -cmatch '^[0-9a-fA-F]{16}$') { return $value.ToLowerInvariant() }
    return $null
}

# ---- Private per-boot LUID cache (Vulkan on Windows) ----
# The Vulkan to DXGI join that identifies the card's adapter LUID costs about 1.3 s cold and about 1.0 s warm on every start (measured
# on a real AMD host as a standard user). The LUID only changes across a reboot (or a driver or adapter change), so it is kept in
# <state>\spill-luid-boot-cache.json, a private file: the LUID is never shown, logged, put in status or exported, and the support
# bundle (an allowlist) does not include the file. Modelled on the Resizable BAR detection cache (FastLlm.VulkanMemoryPolicy.ps1):
# same native boot identity (60 s tolerance), same sleep-delta growth rule, strict shape, reparse-point refusal, never creates a
# directory on read. Any entry that is not valid is ignored AND deleted. Nothing here throws: the worst case is "no cache".
$script:FastLlmSpillLuidCacheFileName = 'spill-luid-boot-cache.json'
$script:FastLlmSpillLuidCacheSchemaVersion = 1
$script:FastLlmSpillLuidCacheKind = 'fastllm-spill-luid'
$script:FastLlmSpillLuidCacheMaxBytes = 4096
$script:FastLlmSpillLuidCacheFields = @('adapterKey', 'bootTimeSource', 'bootUtc', 'collectorSha256', 'joinSourceSha256', 'kind', 'luid', 'schemaVersion', 'sleepDeltaMs')

# Replaceable by tests: is this a Windows host (the only place the Vulkan join and the cache apply)?
function Test-FastLlmSpillIsWindows {
    return ($env:OS -eq 'Windows_NT')
}

# Replaceable by tests: the one collection (the bounded collector child through the device binding, record mode). Returns the outcome.
function Invoke-FastLlmSpillLuidCollection {
    param($Plan, [string] $InstallRoot, $BarDecision)
    return (Invoke-FastLlmDeviceBinding -Plan $Plan -InstallRoot $InstallRoot -BarDecision $BarDecision -Mode record)
}

# Replaceable by tests: SHA-256 (lowercase hex) of the two files the collector hashes into its report, as { script; join }, or $null.
function Get-FastLlmSpillLuidSourceHashes {
    try {
        $projectRoot = Split-Path -Parent $PSScriptRoot
        $result = [ordered]@{}
        foreach ($pair in @(@('script', 'tools/collect-vulkan-luid-join.ps1'), @('join', 'src/WindowsVulkanLuidJoin.cs'))) {
            $file = Join-Path $projectRoot $pair[1]
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $hash = $sha.ComputeHash([IO.File]::ReadAllBytes($file)) } finally { $sha.Dispose() }
            $result[$pair[0]] = (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
        }
        return [pscustomobject]$result
    }
    catch { return $null }
}

# Deterministic key of the plan's selected adapter(s): name (trimmed, lower case), Vulkan device id and VRAM, sorted, joined. $null
# (no caching) when the plan has no selected adapter or one without a name.
function Get-FastLlmSpillLuidAdapterKey {
    param($Plan)
    $parts = @()
    foreach ($adapter in @(Get-FastLlmSpillValue $Plan 'selectedAdapters')) {
        if ($null -eq $adapter) { continue }
        $name = ([string] (Get-FastLlmSpillValue $adapter 'name')).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($name)) { return $null }
        $device = ([string] (Get-FastLlmSpillValue $adapter 'device')).Trim().ToLowerInvariant()
        $parts += ($name + '|' + $device + '|' + [string] (Get-FastLlmSpillValue $adapter 'vramMiB'))
    }
    if ($parts.Count -eq 0) { return $null }
    $ordered = [string[]] @($parts)
    [Array]::Sort($ordered, [StringComparer]::Ordinal)
    $text = ($ordered -join ';')
    if ($text.Length -gt 1024) { return $null }
    return $text
}

# What a start needs to use the cache: { path; bootUtc; sleepDeltaMs; adapterKey; hashes }, or $null (no cache this start).
function Get-FastLlmSpillLuidCacheContext {
    param($Plan, [string] $InstallRoot)
    try {
        if ([string]::IsNullOrWhiteSpace($InstallRoot)) { return $null }
        $key = Get-FastLlmSpillLuidAdapterKey -Plan $Plan
        if ($null -eq $key) { return $null }
        $boot = Get-FastLlmSpillBootIdentity
        if ([string]::IsNullOrWhiteSpace([string] $boot)) { return $null }
        $sleep = Get-FastLlmSpillSleepDelta
        if ($null -eq $sleep -or ($sleep -isnot [int] -and $sleep -isnot [long]) -or $sleep -lt 0) { return $null }
        $hashes = Get-FastLlmSpillLuidSourceHashes
        if ($null -eq $hashes) { return $null }
        $path = Join-Path (Get-FastLlmStateRoot -InstallRoot $InstallRoot) $script:FastLlmSpillLuidCacheFileName
        return [pscustomobject]@{ path = $path; bootUtc = [string] $boot; sleepDeltaMs = [long] $sleep; adapterKey = $key; hashes = $hashes }
    }
    catch { return $null }
}

# Deletes the cache file (exact path). Never throws.
function Remove-FastLlmSpillLuidCache {
    param([string] $InstallRoot)
    try {
        $path = Join-Path (Get-FastLlmStateRoot -InstallRoot $InstallRoot) $script:FastLlmSpillLuidCacheFileName
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
    }
    catch { $null = $_ }
}

function Test-FastLlmSpillLuidInteger {
    param($Value, [long] $Minimum, [long] $Maximum)
    if ($null -eq $Value -or ($Value -isnot [int] -and $Value -isnot [long])) { return $false }
    return ([long] $Value -ge $Minimum -and [long] $Value -le $Maximum)
}

# Strict shape and freshness check of one cache entry. Pure given the context.
function Test-FastLlmSpillLuidCacheEntry {
    param($Entry, $Context)
    if ($null -eq $Entry -or $Entry.GetType().FullName -cne 'System.Management.Automation.PSCustomObject') { return $false }
    $names = [string[]] @($Entry.PSObject.Properties | ForEach-Object { $_.Name })
    [Array]::Sort($names, [StringComparer]::Ordinal)
    if (($names -join ',') -cne ($script:FastLlmSpillLuidCacheFields -join ',')) { return $false }
    if (-not (Test-FastLlmSpillLuidInteger $Entry.schemaVersion $script:FastLlmSpillLuidCacheSchemaVersion $script:FastLlmSpillLuidCacheSchemaVersion)) { return $false }
    if ($Entry.kind -isnot [string] -or $Entry.kind -cne $script:FastLlmSpillLuidCacheKind) { return $false }
    if ($Entry.bootTimeSource -isnot [string] -or $Entry.bootTimeSource -cne 'native') { return $false }
    $entryBoot = $Entry.bootUtc
    $entryBootTime = [datetime]::MinValue
    if ($entryBoot -is [datetime]) { $entryBootTime = $entryBoot.ToUniversalTime() }
    elseif ($entryBoot -isnot [string] -or $entryBoot.Length -gt 40 -or -not [datetime]::TryParseExact($entryBoot, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref] $entryBootTime)) { return $false }
    $currentBootTime = [datetime]::MinValue
    if (-not [datetime]::TryParseExact([string] $Context.bootUtc, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref] $currentBootTime)) { return $false }
    if ([math]::Abs(($entryBootTime.ToUniversalTime() - $currentBootTime.ToUniversalTime()).TotalSeconds) -gt $script:FastLlmVulkanBarBootToleranceSeconds) { return $false }
    if (-not (Test-FastLlmSpillLuidInteger $Entry.sleepDeltaMs 0 $script:FastLlmVulkanBarSleepDeltaMaxMs)) { return $false }
    $growth = [long] $Context.sleepDeltaMs - [long] $Entry.sleepDeltaMs
    if ($growth -lt (-1 * $script:FastLlmVulkanBarSleepDeltaJitterMs) -or $growth -gt $script:FastLlmVulkanBarSleepDeltaToleranceMs) { return $false }
    if ($Entry.adapterKey -isnot [string] -or $Entry.adapterKey -cne [string] $Context.adapterKey) { return $false }
    if ($Entry.luid -isnot [string] -or $Entry.luid -cnotmatch '^[0-9a-f]{16}$') { return $false }
    if ($Entry.collectorSha256 -isnot [string] -or $Entry.collectorSha256 -cnotmatch '^[0-9a-f]{64}$' -or $Entry.collectorSha256 -cne [string] $Context.hashes.script) { return $false }
    if ($Entry.joinSourceSha256 -isnot [string] -or $Entry.joinSourceSha256 -cnotmatch '^[0-9a-f]{64}$' -or $Entry.joinSourceSha256 -cne [string] $Context.hashes.join) { return $false }
    return $true
}

# The cached LUID for this boot and adapter, or $null. Read-only except that an entry that is not valid is deleted; never creates a
# directory; a file that is a reparse point, too large, unreadable or malformed is ignored and deleted. Never throws.
function Read-FastLlmSpillLuidCache {
    param([string] $InstallRoot, $Context)
    try {
        $path = [string] $Context.path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
        $item = Get-Item -LiteralPath $path -Force
        # Attributes -1 (every bit set) is the vanished-name transient: missing, not a reparse point.
        if ([int] $item.Attributes -eq -1) { return $null }
        $valid = $false
        $entry = $null
        if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $item.Length -le $script:FastLlmSpillLuidCacheMaxBytes) {
            try { $entry = Read-FastLlmJson -Path $path -MaxBytes $script:FastLlmSpillLuidCacheMaxBytes } catch { $entry = $null }
            $valid = (Test-FastLlmSpillLuidCacheEntry -Entry $entry -Context $Context)
        }
        if ($valid) { return [string] $entry.luid }
        Remove-FastLlmSpillLuidCache -InstallRoot $InstallRoot
    }
    catch { Remove-FastLlmSpillLuidCache -InstallRoot $InstallRoot }
    return $null
}

# Writes the entry after a fresh, valid collection. Advisory: any failure is silent. Without both source hashes from the collector
# nothing is written (an entry without them could never be reused).
function Write-FastLlmSpillLuidCache {
    param([string] $InstallRoot, $Context, [string] $Luid, $Outcome)
    try {
        if ($Luid -cnotmatch '^[0-9a-f]{16}$') { return }
        $collector = Get-FastLlmSpillValue (Get-FastLlmSpillValue $Outcome 'record') 'collector'
        $scriptSha = [string] (Get-FastLlmSpillValue $collector 'scriptSha256')
        $joinSha = [string] (Get-FastLlmSpillValue $collector 'joinSourceSha256')
        if ($scriptSha -cnotmatch '^[0-9a-f]{64}$' -or $joinSha -cnotmatch '^[0-9a-f]{64}$') { return }
        Write-FastLlmState -InstallRoot $InstallRoot -FileName $script:FastLlmSpillLuidCacheFileName -State ([ordered]@{
                schemaVersion = $script:FastLlmSpillLuidCacheSchemaVersion; kind = $script:FastLlmSpillLuidCacheKind
                bootUtc = [string] $Context.bootUtc; bootTimeSource = 'native'; sleepDeltaMs = [long] $Context.sleepDeltaMs
                adapterKey = [string] $Context.adapterKey; luid = $Luid; collectorSha256 = $scriptSha; joinSourceSha256 = $joinSha
            })
    }
    catch { $null = $_ }
}

# The LUID for this run: the one the device binding already produced, else for Vulkan the same Vulkan to DXGI join once (the bounded
# collector child the Resizable BAR check uses), else (any other engine, such as HIP) the adapter that holds the server process's own
# memory (Find-FastLlmProcessAdapter, inside the first-read budget). Never throws; $null means the check reports unknown. $Found, when given,
# receives { reason; sample } from the process-memory rule so the caller can reuse the identifying read.
function Get-FastLlmSpillCheckLuid {
    param($Plan, [string] $InstallRoot, $KnownLuid, $BarDecision, $Process, [scriptblock] $Reader, [scriptblock] $Enumerator, [scriptblock] $Clock, [hashtable] $Found, [switch] $NoCache)
    try {
        if ($KnownLuid -and ([string] $KnownLuid) -cmatch '^[0-9a-fA-F]{16}$') { return ([string] $KnownLuid).ToLowerInvariant() }
        if (([string] (Get-FastLlmSpillValue $Plan 'backend')) -ieq 'vulkan') {
            if (-not (Test-FastLlmSpillIsWindows)) { return $null }
            # The private per-boot cache (see above). The Found table only carries where the LUID came from, never the LUID itself.
            $context = Get-FastLlmSpillLuidCacheContext -Plan $Plan -InstallRoot $InstallRoot
            if ($null -ne $context -and -not $NoCache) {
                $cached = Read-FastLlmSpillLuidCache -InstallRoot $InstallRoot -Context $context
                if ($null -ne $cached) {
                    if ($null -ne $Found) { $Found['luidSource'] = 'cache' }
                    return [string] $cached
                }
            }
            $outcome = Invoke-FastLlmSpillLuidCollection -Plan $Plan -InstallRoot $InstallRoot -BarDecision $BarDecision
            $luid = Get-FastLlmSpillValue $outcome 'luid'
            if ($luid -and ([string] $luid) -cmatch '^[0-9a-f]{16}$') {
                if ($null -ne $Found) { $Found['luidSource'] = 'collected' }
                if ($null -ne $context) { Write-FastLlmSpillLuidCache -InstallRoot $InstallRoot -Context $context -Luid ([string] $luid) -Outcome $outcome }
                return [string] $luid
            }
            return $null
        }
        if ($null -eq $Process) { return $null }
        if ($env:OS -ne 'Windows_NT' -and -not $Enumerator) { return $null }
        $selection = Find-FastLlmProcessAdapter -Process $Process -BudgetMs ([int] $script:FastLlmSpillFirstReadBudgetMs) -Enumerator $Enumerator -Reader $Reader -Clock $Clock
        if ($null -ne $Found) { $Found['reason'] = [string] $selection.reason; $Found['sample'] = $selection.sample }
        if ([string] $selection.reason -ceq 'selected') { return [string] $selection.luid }
    }
    catch { $null = $_ }
    return $null
}
