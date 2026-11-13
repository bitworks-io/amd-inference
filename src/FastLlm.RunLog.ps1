# Run log: one size-capped JSON-lines file per supervised run under <InstallRoot>\state\logs.
# PRIVACY: a line holds only FastLLM's own plan fields, phase names, failure codes, parsed numeric diagnostics, self-test numbers and the
# exit code, each from a fixed per-event allowlist. It never holds server output after Ready, request or response bodies, a prompt,
# a completion or chat text. Dot-sourced by FastLlm.psm1; it reads no user settings.
Set-StrictMode -Version 2.0

$script:FastLlmRunLogMaxFileBytes = 262144
$script:FastLlmRunLogEndReserveBytes = 2048
$script:FastLlmRunLogKeep = 20
$script:FastLlmRunLogMaxString = 200
$script:FastLlmRunLogFailureText = 'The run failed after the API checks started. The detail is not kept in logs; see the failure code.'
# Per-run bookkeeping for this process: path, bytes written and dropped events. Keyed by install root + run id.
$script:FastLlmRunLogRuns = @{}

# The fixed allowlist: the only field names an event may carry. Anything else is refused with run-log-field-not-allowed.
$script:FastLlmRunLogAllowedFields = @{
    'start'               = @('modelId', 'recipeId', 'backend', 'engineVersion', 'contextSize', 'port', 'thinking', 'chatPage', 'selfTest')
    'phase'               = @('phase', 'failureCode')
    'startup-diagnostics' = @('status', 'kvBufferCount', 'computeBufferCount', 'kvTotalMiB', 'computeTotalMiB', 'flashMode', 'flashResolved')
    'placement'           = @('reportedLayers', 'totalLayers', 'reportedAllLayers', 'deviceCount', 'devices', 'modelBufferTotalMiB')
    # The last five are the user-run API-format check (one event per endpoint): a fixed endpoint path, a verdict and numbers only.
    'api-check'           = @('status', 'modelIdentity', 'effectiveContext', 'repeatableToken', 'synchronousChat', 'streaming', 'endpoint', 'httpStatus', 'promptTokens', 'completionTokens', 'elapsedMs')
    'self-test'           = @('status', 'reasons', 'generationTokS', 'promptTokS', 'firstTextMs', 'expectedGenerationTokS', 'comparable')
    # Opt-in idle stop: the minutes setting and two times. The check-failed event has no field; it is written once per run.
    'idle-stop'           = @('idleStopMinutes', 'lastActivityUtc', 'stoppedAtUtc')
    'idle-check-failed'   = @()
    # GPU memory check: the state names and numbers only (MiB); no text.
    'spill-check'         = @('state', 'sharedMiB', 'dedicatedMiB', 'floorMiB')
    'spill-check-changed' = @('from', 'to', 'sharedMiB', 'dedicatedMiB')
    'end'                 = @('phase', 'failureCode', 'failedAtPhase', 'failureMessage', 'exitCode', 'serverExitCode', 'droppedEvents')
}

function Get-FastLlmRunLogFolder {
    param([Parameter(Mandatory = $true)][string] $InstallRoot)
    return (Join-Path (Get-FastLlmStateRoot -InstallRoot $InstallRoot) 'logs')
}

# A value is a number, a bool or a string (capped at 200 characters, control characters replaced by spaces). Anything else is refused.
function ConvertTo-FastLlmRunLogValue {
    param([string] $Name, $Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte]) { return $Value }
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        if ($Value -is [double] -and ([double]::IsNaN($Value) -or [double]::IsInfinity($Value))) { return $null }
        return $Value
    }
    if ($Value -is [string]) {
        $text = [regex]::Replace($Value, '[\x00-\x1f\x7f]', ' ')
        if ($text.Length -gt $script:FastLlmRunLogMaxString) { $text = $text.Substring(0, $script:FastLlmRunLogMaxString) }
        return $text
    }
    throw "run-log-value-not-allowed: field '$Name' must be a number, a bool or a string."
}

function Get-FastLlmRunLogRunState {
    param([string] $InstallRoot, [string] $RunId, [string] $Folder)
    $key = [IO.Path]::GetFullPath($InstallRoot) + '|' + $RunId
    if ($script:FastLlmRunLogRuns.ContainsKey($key)) { return $script:FastLlmRunLogRuns[$key] }
    $path = $null
    $bytes = 0L
    if (Test-Path -LiteralPath $Folder -PathType Container) {
        $existing = @(Get-ChildItem -LiteralPath $Folder -Filter "run-*-$RunId.jsonl" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)
        if ($existing.Count -gt 0) { $path = $existing[0].FullName; $bytes = [long] $existing[0].Length }
    }
    if ($null -eq $path) {
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmss') + 'Z'
        $path = Join-Path $Folder ("run-$stamp-$RunId.jsonl")
    }
    $runState = @{ path = $path; bytes = $bytes; dropped = 0; rotated = $false }
    # Keep the table small in a long-lived process (the background host).
    if ($script:FastLlmRunLogRuns.Count -ge 64) { $script:FastLlmRunLogRuns = @{} }
    $script:FastLlmRunLogRuns[$key] = $runState
    return $runState
}

# Appends one JSON line. Programmer errors (unknown event, field or value type) throw; every I/O problem is swallowed and reported as $false,
# so a log failure can never fail a run. Returns $true when the line was written.
function Write-FastLlmRunLogEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $InstallRoot,
        [Parameter(Mandatory = $true)][string] $RunId,
        [Parameter(Mandatory = $true)][string] $Event,
        [System.Collections.IDictionary] $Fields = @{}
    )
    if (-not $script:FastLlmRunLogAllowedFields.ContainsKey($Event)) { throw "run-log-event-not-allowed: '$Event'." }
    if ($RunId -cnotmatch '^[A-Za-z0-9-]{1,64}$') { throw 'run-log-run-id: the run id must be 1 to 64 letters, digits or dashes.' }
    $allowed = @($script:FastLlmRunLogAllowedFields[$Event])
    $line = [ordered] @{ ts = (Get-Date).ToUniversalTime().ToString('o'); runId = $RunId; event = $Event }
    foreach ($name in @($Fields.Keys)) {
        if ($allowed -cnotcontains [string] $name) { throw "run-log-field-not-allowed: '$name' is not a field of the '$Event' event." }
        $line[[string] $name] = ConvertTo-FastLlmRunLogValue -Name ([string] $name) -Value $Fields[$name]
    }
    # After the API checks start only a fixed text may describe a failure: the detail could echo request text.
    if ($Event -ceq 'end' -and $line.Contains('failureMessage')) {
        $failedAt = ''
        if ($line.Contains('failedAtPhase') -and $null -ne $line['failedAtPhase']) { $failedAt = [string] $line['failedAtPhase'] }
        if (@('preparing', 'loading') -cnotcontains $failedAt) { $line['failureMessage'] = $script:FastLlmRunLogFailureText }
    }
    try {
        $folder = Get-FastLlmRunLogFolder -InstallRoot $InstallRoot
        $runState = Get-FastLlmRunLogRunState -InstallRoot $InstallRoot -RunId $RunId -Folder $folder
        if ($Event -ceq 'end') { $line['droppedEvents'] = [int] $runState.dropped }
        $json = ConvertTo-Json -InputObject $line -Compress -Depth 4
        $bytes = [Text.Encoding]::UTF8.GetBytes($json + "`n")
        $limit = $script:FastLlmRunLogMaxFileBytes
        if ($Event -cne 'end') { $limit -= $script:FastLlmRunLogEndReserveBytes }
        if ($runState.bytes + $bytes.Length -gt $limit) { $runState.dropped = [int] $runState.dropped + 1; return $false }
        New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null
        $stream = [IO.File]::Open([string] $runState.path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() } finally { $stream.Dispose() }
        $runState.bytes = [long] $runState.bytes + $bytes.Length
        if (-not $runState.rotated) { $runState.rotated = $true; Invoke-FastLlmRunLogRotation -InstallRoot $InstallRoot }
        return $true
    }
    catch { return $false }
}

# Keeps the newest 20 run logs (by last write, then name) and removes the rest. Other files in the folder are left alone. Never throws.
function Invoke-FastLlmRunLogRotation {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $InstallRoot)
    try {
        $folder = Get-FastLlmRunLogFolder -InstallRoot $InstallRoot
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { return }
        $files = @(Get-ChildItem -LiteralPath $folder -Filter 'run-*.jsonl' -File -ErrorAction Stop |
                Where-Object { $_.Name -cmatch '^run-\d{8}T\d{6}Z-[A-Za-z0-9-]{1,64}\.jsonl$' } |
                Sort-Object -Property @{ Expression = { $_.LastWriteTimeUtc }; Descending = $true }, @{ Expression = { $_.Name }; Descending = $true })
        if ($files.Count -le $script:FastLlmRunLogKeep) { return }
        foreach ($old in @($files | Select-Object -Skip $script:FastLlmRunLogKeep)) {
            try { Remove-Item -LiteralPath $old.FullName -Force -ErrorAction Stop } catch { $null = $_ }
        }
    }
    catch { $null = $_ }
}

# ---- the supervisor's side: best-effort emission and the field builders ----
# Every call is wrapped: a log problem, even a programming error in a builder, must never change a run.

function Add-FastLlmRunLogEvent {
    param([string] $InstallRoot, $State, [string] $Event, $Fields)
    try {
        $fieldTable = $Fields
        if ($fieldTable -is [scriptblock]) { $fieldTable = & $fieldTable }
        if ($null -eq $fieldTable) { $fieldTable = @{} }
        [void] (Write-FastLlmRunLogEvent -InstallRoot $InstallRoot -RunId ([string] $State.runId) -Event $Event -Fields $fieldTable)
    }
    catch { $null = $_ }
}

function Get-FastLlmRunLogProperty {
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-FastLlmRunLogSum {
    param($Entries)
    $total = 0.0
    foreach ($entry in @($Entries)) {
        $size = Get-FastLlmRunLogProperty $entry 'sizeMiB'
        if ($null -ne $size) { $total += [double] $size }
    }
    return $total
}

function Get-FastLlmRunLogStartFields {
    param($Plan, $State, [bool] $SelfTest)
    $fields = [ordered] @{}
    $modelId = Get-FastLlmRunLogProperty (Get-FastLlmRunLogProperty $Plan 'model') 'id'
    if ($null -ne $modelId) { $fields.modelId = [string] $modelId }
    $recipeId = Get-FastLlmRunLogProperty (Get-FastLlmRunLogProperty $Plan 'recipe') 'id'
    if ($null -ne $recipeId) { $fields.recipeId = [string] $recipeId }
    $backend = Get-FastLlmRunLogProperty $Plan 'backend'
    if ($null -ne $backend) { $fields.backend = ([string] $backend).ToLowerInvariant() }
    $engineVersion = Get-FastLlmRunLogProperty $Plan 'engineVersion'
    if ($null -ne $engineVersion) { $fields.engineVersion = [string] $engineVersion }
    $contextSize = Get-FastLlmRunLogProperty (Get-FastLlmRunLogProperty $Plan 'model') 'contextSize'
    if ($null -ne $contextSize) { $fields.contextSize = [int] $contextSize }
    $endpoint = Get-FastLlmRunLogProperty $Plan 'endpoint'
    if ($null -ne $endpoint) { try { $fields.port = [int] ([Uri] ([string] $endpoint)).Port } catch { $null = $_ } }
    $fields.thinking = [string] $State.thinking
    $fields.chatPage = [string] $State.chatPage
    $fields.selfTest = [bool] $SelfTest
    return $fields
}

function Get-FastLlmRunLogDiagnosticsFields {
    param($Diagnostics)
    $fields = [ordered] @{ status = [string] (Get-FastLlmRunLogProperty $Diagnostics 'status') }
    $kv = @(Get-FastLlmRunLogProperty $Diagnostics 'kvBuffers')
    $compute = @(Get-FastLlmRunLogProperty $Diagnostics 'computeBuffers')
    $fields.kvBufferCount = [int] @($kv | Where-Object { $_ }).Count
    $fields.computeBufferCount = [int] @($compute | Where-Object { $_ }).Count
    $fields.kvTotalMiB = [Math]::Round((Get-FastLlmRunLogSum $kv), 2)
    $fields.computeTotalMiB = [Math]::Round((Get-FastLlmRunLogSum $compute), 2)
    $mode = Get-FastLlmRunLogProperty $Diagnostics 'reportedFlashAttentionMode'
    if ($null -ne $mode -and ([string] $mode) -cmatch '^(auto|enabled|disabled)$') { $fields.flashMode = [string] $mode }
    $resolved = Get-FastLlmRunLogProperty $Diagnostics 'reportedFlashAttentionResolved'
    if ($resolved -is [bool]) { $fields.flashResolved = $resolved }
    return $fields
}

function Get-FastLlmRunLogPlacementFields {
    param($Placement)
    $fields = [ordered] @{}
    foreach ($name in @('reportedLayers', 'totalLayers')) {
        $value = Get-FastLlmRunLogProperty $Placement $name
        if ($null -ne $value) { $fields[$name] = [int] $value }
    }
    $all = Get-FastLlmRunLogProperty $Placement 'reportedAllLayers'
    if ($all -is [bool]) { $fields.reportedAllLayers = $all }
    $devices = @(@(Get-FastLlmRunLogProperty $Placement 'devices') | Where-Object { $_ -and ([string] $_) -cmatch '^[A-Za-z]{2,10}\d{0,3}$' } | ForEach-Object { [string] $_ })
    $fields.deviceCount = [int] $devices.Count
    $fields.devices = ($devices -join ',')
    $fields.modelBufferTotalMiB = [Math]::Round((Get-FastLlmRunLogSum (Get-FastLlmRunLogProperty $Placement 'modelBufferMiB')), 2)
    return $fields
}

function Get-FastLlmRunLogApiCheckFields {
    param($Canary)
    $fields = [ordered] @{ status = 'pass' }
    foreach ($name in @('modelIdentity', 'repeatableToken', 'synchronousChat', 'streaming')) {
        $value = Get-FastLlmRunLogProperty $Canary $name
        if ($value -is [bool]) { $fields[$name] = $value }
    }
    $context = Get-FastLlmRunLogProperty $Canary 'effectiveContext'
    if ($null -ne $context) { $fields.effectiveContext = [int] $context }
    return $fields
}

# Only the verdict, the reason codes (short lowercase codes; anything else is dropped) and the server-reported numbers.
function Get-FastLlmRunLogSelfTestFields {
    param($Result)
    $fields = [ordered] @{ status = [string] (Get-FastLlmRunLogProperty $Result 'status') }
    $reasons = @(@(Get-FastLlmRunLogProperty $Result 'reasons') | Where-Object { $_ -and ([string] $_) -cmatch '^[a-z0-9-]{1,40}$' } | ForEach-Object { [string] $_ })
    if ($reasons.Count -gt 0) { $fields.reasons = ($reasons -join ',') }
    foreach ($name in @('generationTokS', 'promptTokS', 'firstTextMs', 'expectedGenerationTokS')) {
        $value = Get-FastLlmRunLogProperty $Result $name
        if ($value -is [double] -or $value -is [int] -or $value -is [long] -or $value -is [decimal]) { $fields[$name] = $value }
    }
    $comparable = Get-FastLlmRunLogProperty $Result 'comparable'
    if ($comparable -is [bool]) { $fields.comparable = $comparable }
    return $fields
}
