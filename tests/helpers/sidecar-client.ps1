# The independent client of tests/sidecar-tests.ps1. The suite's own process is blocked inside the supervised start, so this process plays
# the user and the apps: it waits for a status condition (the text model's phase, the embedding sidecar's phase), then asks for a switch or a
# stop through the shipped request writers, ends the sidecar process as a crash would, sends a request as an app would, or changes what the
# mock engine answers. Every status change it sees is recorded, with the sidecar block as the status document had it.
param(
    [Parameter(Mandatory = $true)][string] $Root,
    [Parameter(Mandatory = $true)][string] $InstallRoot,
    [Parameter(Mandatory = $true)][string] $WorldPath,
    [Parameter(Mandatory = $true)][string] $StepsPath,
    [Parameter(Mandatory = $true)][string] $ResultPath,
    [Parameter(Mandatory = $true)][string] $CatalogPath,
    [ValidateRange(1, 3600)][int] $StepTimeoutSeconds = 240
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $Root 'src/FastLlm.psm1') -Force
$module = Get-Module FastLlm
. (Join-Path $PSScriptRoot 'SwitchTestWorld.ps1')
Install-SwitchTestWorld -Module $module -WorldPath $WorldPath
& $module { Initialize-FastLlmProcessHost }
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
function Read-Status { try { return (Get-FastLlmStatus -InstallRoot $InstallRoot) } catch { return $null } }
function Get-Sidecar($Status) {
    $list = Get-Value $Status 'sidecars'
    if ($null -eq $list) { return $null }
    $entries = @($list)
    if ($entries.Count -lt 1) { return $null }
    return $entries[0]
}
function Add-Observation($Status) {
    if ($null -eq $Status) { return }
    $sidecar = Get-Sidecar $Status
    $sidecarText = ''
    if ($null -ne $sidecar) { $sidecarText = ConvertTo-Json -InputObject $sidecar -Compress -Depth 5 }
    $block = Get-Value $Status 'switch'
    $blockText = ''
    if ($null -ne $block) { $blockText = ConvertTo-Json -InputObject $block -Compress -Depth 4 }
    $key = @([string] (Get-Value $Status 'runId'), [string] (Get-Value $Status 'phase'), [string] (Get-Value $Status 'modelId'), [string] (Get-Value $Status 'stopReason'), $blockText, $sidecarText, [string] (Get-Value $Status 'active')) -join '|'
    if ($key -ceq $script:lastKey) { return }
    $script:lastKey = $key
    $identity = Get-Value $Status 'processIdentity'
    $sidecarIdentity = Get-Value $sidecar 'processIdentity'
    $observations.Add([ordered] @{
            ms = [int] $clock.ElapsedMilliseconds; runId = [string] (Get-Value $Status 'runId'); phase = [string] (Get-Value $Status 'phase'); modelId = [string] (Get-Value $Status 'modelId')
            stopReason = (Get-Value $Status 'stopReason'); active = [bool] (Get-Value $Status 'active'); 'switch' = $block
            pid = $(if ($null -ne $identity) { [int] (Get-Value $identity 'pid') } else { 0 })
            hasSidecars = [bool] ($null -ne (Get-Value $Status 'sidecars'))
            sidecarPhase = $(if ($null -ne $sidecar) { [string] (Get-Value $sidecar 'phase') } else { $null })
            sidecarFailureCode = $(if ($null -ne $sidecar) { Get-Value $sidecar 'failureCode' } else { $null })
            sidecarPid = $(if ($null -ne $sidecarIdentity) { [int] (Get-Value $sidecarIdentity 'pid') } else { 0 })
            sidecarTicks = $(if ($null -ne $sidecarIdentity) { [string] (Get-Value $sidecarIdentity 'startUtcTicks') } else { '' })
            sidecar = $sidecar
            keys = (@($Status.PSObject.Properties.Name | Sort-Object) -join ',')
        })
}
function Test-Wait($Status, $Wait) {
    if ($null -eq $Wait) { return $true }
    $block = Get-Value $Status 'switch'
    $sidecar = Get-Sidecar $Status
    foreach ($property in @($Wait.PSObject.Properties)) {
        $expected = $property.Value
        switch -CaseSensitive ($property.Name) {
            'phase' { if ([string] (Get-Value $Status 'phase') -cne [string] $expected) { return $false } }
            'modelId' { if ([string] (Get-Value $Status 'modelId') -cne [string] $expected) { return $false } }
            'stopReason' { if ([string] (Get-Value $Status 'stopReason') -cne [string] $expected) { return $false } }
            'switchResult' { if ([string] (Get-Value $block 'result') -cne [string] $expected) { return $false } }
            'switchPending' { if ([bool] (Get-Value $block 'pending') -ne [bool] $expected) { return $false } }
            'sidecarPhase' { if ([string] (Get-Value $sidecar 'phase') -cne [string] $expected) { return $false } }
            'sidecarFailureCode' { if ([string] (Get-Value $sidecar 'failureCode') -cne [string] $expected) { return $false } }
            'fileExists' { if (-not (Test-Path -LiteralPath ([string] $expected))) { return $false } }
            default { throw "Unknown wait condition '$($property.Name)'." }
        }
    }
    return $true
}
# Every address something listens on at a port. On Windows the system's listener table; elsewhere lsof answers the same question
# ("*" is every address).
function Get-ListenerAddresses([int] $Port) {
    if ($env:OS -ceq 'Windows_NT') {
        return @([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object { [int] $_.Port -eq $Port } | ForEach-Object { [string] $_.Address })
    }
    $found = @()
    foreach ($line in @(& lsof -nP "-iTCP:$Port" -sTCP:LISTEN -Fn 2>$null)) { if ([string] $line -match '^n(.+):(\d+)$' -and [int] $Matches[2] -eq $Port) { $found += [string] $Matches[1] } }
    return @($found)
}
# A request as an app sends it: literal loopback only, no key. The answer's status is recorded, never its body.
function Send-Request([string] $Url, $Body) {
    $json = $null
    if ($null -ne $Body) { $json = [string] $Body }
    try { return [int] ([Bitworks.FastLlm.LoopbackHttp]::Request($Url, $json, 5000, 1048576)).Status } catch { return 0 }
}
function Invoke-Step($Step, $Status, $Outcome) {
    $sidecar = Get-Sidecar $Status
    switch -CaseSensitive ([string] $Step.action) {
        'none' { }
        'sleep' { Start-Sleep -Milliseconds ([int] $Step.milliseconds) }
        'switch' { Request-FastLlmSwitch -InstallRoot $InstallRoot -CatalogPath $CatalogPath -ModelId ([string] $Step.modelId) 6>$null | Out-Null }
        'stop' { Request-FastLlmStop -InstallRoot $InstallRoot 6>$null | Out-Null }
        'kill-sidecar' {
            # The sidecar process ends as a crash would: the client ends the process the status document names.
            $identity = Get-Value $sidecar 'processIdentity'
            $Outcome.killedPid = [int] (Get-Value $identity 'pid')
            Stop-Process -Id ([int] (Get-Value $identity 'pid')) -Force
        }
        'kill-text' {
            # The text server ends as a crash would.
            $identity = Get-Value $Status 'processIdentity'
            $Outcome.killedPid = [int] (Get-Value $identity 'pid')
            Stop-Process -Id ([int] (Get-Value $identity 'pid')) -Force
        }
        'write' { [IO.File]::WriteAllText([string] $Step.path, [string] $Step.text) }
        'copy' { [IO.File]::Copy([string] $Step.from, [string] $Step.to, $true) }
        'request' {
            # What the two servers answer right now, as status numbers: the text server on its endpoint and the sidecar on its own.
            $textBase = ([string] (Get-Value $Status 'endpoint')) -replace '/v1$', ''
            $Outcome.textHealth = Send-Request ($textBase + '/health') $null
            $Outcome.textModels = Send-Request ($textBase + '/v1/models') $null
            if ($null -ne $sidecar) {
                $sidecarBase = ([string] (Get-Value $sidecar 'endpoint')) -replace '/v1$', ''
                $Outcome.sidecarHealth = Send-Request ($sidecarBase + '/health') $null
                # Like the engine, the sidecar answers the model list without a key.
                $Outcome.sidecarModelsOpen = Send-Request ($sidecarBase + '/v1/models') $null
                # Every address something listens on at the sidecar's port, from the system's own listener table.
                $sidecarPort = ([Uri] $sidecarBase).Port
                $Outcome.sidecarListeners = (@(Get-ListenerAddresses ([int] $sidecarPort) | Sort-Object -Unique) -join ',')
                if (Get-Value $Step 'embedBody') { $Outcome.sidecarEmbed = Send-Request ($sidecarBase + '/v1/embeddings') ([string] $Step.embedBody) }
            }
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
        try { Invoke-Step $step $status $outcome }
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
