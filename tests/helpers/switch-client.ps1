# The independent client of tests/model-switch-tests.ps1. The suite's own process is blocked inside the supervised start, so this process plays
# the user: it waits for a status condition, then asks for a switch (through the shipped request writer), writes a raw request, plants an unsafe
# object, or asks for a stop. Every status change it sees is recorded, with whether the operation lock was held at that moment.
param(
    [Parameter(Mandatory = $true)][string] $Root,
    [Parameter(Mandatory = $true)][string] $InstallRoot,
    [Parameter(Mandatory = $true)][string] $WorldPath,
    [Parameter(Mandatory = $true)][string] $StepsPath,
    [Parameter(Mandatory = $true)][string] $ResultPath,
    # The deadline of a step that names none: a condition that never comes true ends the scenario as failed after this long.
    [ValidateRange(1, 3600)][int] $StepTimeoutSeconds = 240
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $Root 'src/FastLlm.psm1') -Force
$module = Get-Module FastLlm
. (Join-Path $PSScriptRoot 'SwitchTestWorld.ps1')
Install-SwitchTestWorld -Module $module -WorldPath $WorldPath
$catalogPath = Join-Path $Root 'config/catalog.json'
$stateRoot = Join-Path $InstallRoot 'state'
$document = Get-Content -LiteralPath $StepsPath -Raw | ConvertFrom-Json
$steps = @($document.steps)
$observations = New-Object 'System.Collections.Generic.List[object]'
$outcomes = New-Object 'System.Collections.Generic.List[object]'
$script:lastKey = ''
$clock = [Diagnostics.Stopwatch]::StartNew()

function Get-Value($Object, [string] $Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Read-Status {
    try { return (Get-FastLlmStatus -InstallRoot $InstallRoot) } catch { return $null }
}

function Add-Observation($Status) {
    if ($null -eq $Status) { return }
    $block = Get-Value $Status 'switch'
    $blockText = ''
    if ($null -ne $block) { $blockText = ConvertTo-Json -InputObject $block -Compress -Depth 4 }
    $key = @([string] (Get-Value $Status 'runId'), [string] (Get-Value $Status 'phase'), [string] (Get-Value $Status 'modelId'), [string] (Get-Value $Status 'stopReason'), $blockText, [string] (Get-Value $Status 'active')) -join '|'
    if ($key -ceq $script:lastKey) { return }
    $script:lastKey = $key
    $selfTest = Get-Value $Status 'selfTest'
    $identity = Get-Value $Status 'processIdentity'
    $observations.Add([ordered] @{
            ms = [int] $clock.ElapsedMilliseconds; runId = [string] (Get-Value $Status 'runId'); phase = [string] (Get-Value $Status 'phase'); modelId = [string] (Get-Value $Status 'modelId')
            stopReason = (Get-Value $Status 'stopReason'); active = [bool] (Get-Value $Status 'active'); 'switch' = $block; switchAllowed = (Get-Value $Status 'switchAllowed')
            canary = [bool] ($null -ne (Get-Value $Status 'canary')); placement = [bool] ($null -ne (Get-Value $Status 'placement'))
            selfTest = $(if ($null -ne $selfTest) { [string] (Get-Value $selfTest 'status') } else { $null })
            pid = $(if ($null -ne $identity) { [int] (Get-Value $identity 'pid') } else { 0 })
            idleStopMinutes = (Get-Value $Status 'idleStopMinutes'); failureCode = (Get-Value $Status 'failureCode')
            keys = (@($Status.PSObject.Properties.Name | Sort-Object) -join ',')
        })
}

function Test-Wait($Status, $Wait) {
    if ($null -eq $Wait) { return $true }
    $block = Get-Value $Status 'switch'
    foreach ($property in @($Wait.PSObject.Properties)) {
        $expected = $property.Value
        switch -CaseSensitive ($property.Name) {
            'phase' { if ([string] (Get-Value $Status 'phase') -cne [string] $expected) { return $false } }
            'modelId' { if ([string] (Get-Value $Status 'modelId') -cne [string] $expected) { return $false } }
            'stopReason' { if ([string] (Get-Value $Status 'stopReason') -cne [string] $expected) { return $false } }
            'switchResult' { if ([string] (Get-Value $block 'result') -cne [string] $expected) { return $false } }
            'switchFailureCode' { if ([string] (Get-Value $block 'failureCode') -cne [string] $expected) { return $false } }
            'switchPending' { if ([bool] (Get-Value $block 'pending') -ne [bool] $expected) { return $false } }
            'fileExists' { if (-not (Test-Path -LiteralPath ([string] $expected))) { return $false } }
            default { throw "Unknown wait condition '$($property.Name)'." }
        }
    }
    return $true
}

function Write-RawRequest([string] $Path, [string] $Text) {
    $temporary = Join-Path (Split-Path -Parent $Path) ([Guid]::NewGuid().ToString('N') + '.client')
    [IO.File]::WriteAllText($temporary, $Text, (New-Object Text.UTF8Encoding($false)))
    [IO.File]::Move($temporary, $Path)
}

function Invoke-Step($Step, $Status) {
    $runId = [string] (Get-Value $Status 'runId')
    $requestPath = Join-Path $stateRoot ('switch-' + $runId + '.json')
    $stopPath = Join-Path $stateRoot ('stop-' + $runId)
    switch -CaseSensitive ([string] $Step.action) {
        'none' { }
        'sleep' { Start-Sleep -Milliseconds ([int] $Step.milliseconds) }
        'switch' {
            $arguments = @{ InstallRoot = $InstallRoot; CatalogPath = $catalogPath }
            if (Get-Value $Step 'recipeId') { $arguments.RecipeId = [string] $Step.recipeId } else { $arguments.ModelId = [string] $Step.modelId }
            if ([bool] (Get-Value $Step 'force')) { $arguments.Force = $true }
            Request-FastLlmSwitch @arguments 6>$null | Out-Null
        }
        'raw' {
            $text = [string] $Step.text
            $pad = Get-Value $Step 'padBytes'
            if ($null -ne $pad -and [int] $pad -gt 0) { $text = $text + (' ' * [int] $pad) }
            Write-RawRequest -Path $requestPath -Text $text
        }
        'link' {
            # A reparse point at the request path. Windows: a directory junction (no privilege needed). Elsewhere: a symbolic link to a file that
            # holds a VALID request, so following it would switch.
            if ($env:OS -ceq 'Windows_NT') { New-Item -ItemType Junction -Path $requestPath -Target (Split-Path -Parent ([string] $Step.target)) | Out-Null }
            else { New-Item -ItemType SymbolicLink -Path $requestPath -Target ([string] $Step.target) | Out-Null }
        }
        'unlink' {
            if ($env:OS -ceq 'Windows_NT') { [IO.Directory]::Delete($requestPath) } else { [IO.File]::Delete($requestPath) }
        }
        'directory' { New-Item -ItemType Directory -Path $requestPath | Out-Null }
        'remove-directory' { [IO.Directory]::Delete($requestPath) }
        'stop' { Request-FastLlmStop -InstallRoot $InstallRoot 6>$null | Out-Null }
        'stop-then-raw' {
            # Both requests are on disk before the supervisor's next pass can end: the stop file first, the switch request right after it.
            [IO.File]::WriteAllText($stopPath, '')
            Write-RawRequest -Path $requestPath -Text ([string] $Step.text)
        }
        default { throw "Unknown action '$($Step.action)'." }
    }
}

$failed = $false
$index = 0
try {
    foreach ($step in $steps) {
        $timeoutSeconds = $StepTimeoutSeconds
        $configured = Get-Value $step 'timeoutSeconds'
        if ($null -ne $configured) { $timeoutSeconds = [int] $configured }
        $deadline = [Diagnostics.Stopwatch]::StartNew()
        $matched = $false
        $status = $null
        while ($deadline.Elapsed.TotalSeconds -lt $timeoutSeconds) {
            $status = Read-Status
            Add-Observation $status
            if ($null -ne $status -and (Test-Wait $status (Get-Value $step 'wait'))) { $matched = $true; break }
            Start-Sleep -Milliseconds 40
        }
        $outcome = [ordered] @{ index = $index; action = [string] $step.action; matched = $matched; error = $null; runId = [string] (Get-Value $status 'runId'); ms = [int] $clock.ElapsedMilliseconds }
        if (-not $matched) { $outcomes.Add($outcome); $failed = $true; break }
        try { Invoke-Step $step $status }
        catch { $outcome.error = [regex]::Replace([string] $_.Exception.Message, '[\x00-\x1f\x7f]', ' ') }
        $outcomes.Add($outcome)
        $index++
    }
}
finally {
    # Never leave the suite blocked in a supervised start: whatever is still served (or still switching) after the steps is asked to stop.
    $release = [Diagnostics.Stopwatch]::StartNew()
    $quiet = 0
    while ($release.Elapsed.TotalSeconds -lt 300 -and $quiet -lt 4) {
        $status = Read-Status
        Add-Observation $status
        $serving = [bool] ($null -ne $status -and [bool] (Get-Value $status 'active') -and @('loading', 'checking', 'ready') -ccontains [string] (Get-Value $status 'phase'))
        $switching = [bool] ($null -ne $status -and [bool] (Get-Value $status 'active') -and [bool] (Get-Value (Get-Value $status 'switch') 'pending'))
        if ($serving -or $switching) {
            $quiet = 0
            try { Request-FastLlmStop -InstallRoot $InstallRoot 6>$null | Out-Null } catch { $null = $_ }
        }
        else { $quiet++ }
        Start-Sleep -Milliseconds 200
    }
    $result = [ordered] @{ completed = (-not $failed); steps = @($outcomes.ToArray()); observations = @($observations.ToArray()) }
    [IO.File]::WriteAllText($ResultPath, (ConvertTo-Json -InputObject $result -Depth 8), (New-Object Text.UTF8Encoding($false)))
}
