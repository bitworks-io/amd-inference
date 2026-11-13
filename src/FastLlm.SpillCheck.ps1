# Loaded into FastLlm.psm1. GPU memory check: has part of the model's memory moved from GPU memory into shared system memory?
#
# Windows can demote a process's GPU allocations to shared system memory when another app uses the GPU, even an app started after
# FastLLM. Every layer is still reported on the GPU, so the check reads the per-process memory split of the llama-server process
# FastLLM itself started, on the adapter the plan selected (the kernel graphics statistics, as the standard user; no elevation,
# no permission change, no performance counters). Above a fixed floor of shared bytes the state is 'spilled'.
#
# States: ok | spilled | unknown. 'unknown' (a failed read, a layout mismatch, not Windows, no adapter LUID) is never treated as ok.
# The check is advisory: serving continues whatever it says. It is never derived from layer counts.
$script:FastLlmSpillFloorMiB = 256
$script:FastLlmSpillCheckIntervalSeconds = 60
# Time boxes for one read. The kernel query takes milliseconds; the box keeps a stuck call from delaying the 250 ms stop-file check.
$script:FastLlmSpillFirstReadBudgetMs = 2000
$script:FastLlmSpillLoopReadBudgetMs = 200
$script:FastLlmSpillOkText = 'GPU memory check: no spill to system memory detected.'
$script:FastLlmSpillUnknownText = 'GPU memory check unavailable on this system.'

function Initialize-FastLlmGpuProcessMemory {
    if (-not ('Bitworks.FastLlm.WindowsGpuProcessMemory' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'WindowsGpuProcessMemory.cs') -ErrorAction Stop
    }
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
    param($Previous, [datetime] $Now, [datetime] $NextDueUtc, [string] $Luid, $Process, [scriptblock] $Reader)
    if ($Now -lt $NextDueUtc) { return $null }
    $sample = Read-FastLlmSpillSample -Luid $Luid -Process $Process -BudgetMs ([int] $script:FastLlmSpillLoopReadBudgetMs) -Reader $Reader
    $step = Step-FastLlmSpillCheck -Previous $Previous -Sample $sample -Now $Now
    $step | Add-Member -NotePropertyName nextDueUtc -NotePropertyValue $Now.AddSeconds([int] $script:FastLlmSpillCheckIntervalSeconds)
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
    param($Plan, [string] $InstallRoot, $KnownLuid, $BarDecision, $Process, [scriptblock] $Reader)
    $luid = Get-FastLlmSpillCheckLuid -Plan $Plan -InstallRoot $InstallRoot -KnownLuid $KnownLuid -BarDecision $BarDecision
    $step = Invoke-FastLlmSpillCheckInitial -Luid ([string] $luid) -Process $Process -Reader $Reader
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

# Benchmark tracker. A spill refuses the run at the start and fails it during the run. An unavailable check (for example the HIP
# engine, which has no adapter LUID) never refuses: the track records the worst state seen and the result is labelled.
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

# The LUID for this run: the one the device binding already produced, else the same Vulkan to DXGI join once (the bounded collector
# child the Resizable BAR check uses). Never throws; $null means the check reports unknown.
function Get-FastLlmSpillCheckLuid {
    param($Plan, [string] $InstallRoot, $KnownLuid, $BarDecision)
    try {
        if ($KnownLuid -and ([string] $KnownLuid) -cmatch '^[0-9a-fA-F]{16}$') { return ([string] $KnownLuid).ToLowerInvariant() }
        if ($env:OS -ne 'Windows_NT') { return $null }
        if (([string] (Get-FastLlmSpillValue $Plan 'backend')) -ine 'vulkan') { return $null }
        $outcome = Invoke-FastLlmDeviceBinding -Plan $Plan -InstallRoot $InstallRoot -BarDecision $BarDecision -Mode record
        $luid = Get-FastLlmSpillValue $outcome 'luid'
        if ($luid -and ([string] $luid) -cmatch '^[0-9a-f]{16}$') { return [string] $luid }
    }
    catch { $null = $_ }
    return $null
}
