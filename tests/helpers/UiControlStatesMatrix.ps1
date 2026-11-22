#requires -Version 5.1
# The control-state matrix for the window's enable rules, and a runner that applies a window script's own
# SetBusy / GetUiActionAvailabilityNow / SetTrayMenuAvailable to stub controls. Dot-source this file.
$script:UiMatrixRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $script:UiMatrixRoot 'src/FastLlm.UiFlow.ps1')
. (Join-Path $script:UiMatrixRoot 'src/FastLlm.UiBackground.ps1')
if (Test-Path -LiteralPath (Join-Path $script:UiMatrixRoot 'src/FastLlm.UiState.ps1')) {
    . (Join-Path $script:UiMatrixRoot 'src/FastLlm.UiState.ps1')
}

$script:UiMatrixColumns = @('install','start','model','path','context','bar','diagnostics','driverGuidance','settings','saveBundle','chooseSetup','backgroundStart','backgroundAttach','backgroundCheck','stop','tray','openChat','progressVisible','apiCheck')
# The window's control variable behind each of the first 18 columns, in column order.
$script:UiMatrixControlVars = @('installButton','startButton','modelBox','pathBox','contextBox','barBox','doctorButton','driverButton','settingsButton','bundleButton','chooseButton','backgroundStartButton','backgroundAttachButton','backgroundCheckButton','stopButton','trayButton','openChatButton','progress')
$script:UiMatrixFlags = @('busy','updateRun','child','stepServing','runReady','sideChild','vcBroker','previewReady','switchGap','chatUrl','bgStopRequested')
$script:UiMatrixFixtureNames = @('none','absent','stale','starting-own','starting-other','starting-case','ready-attachable','ready-attached','ready-attached-unhealthy','ready-verified-only','bare-ready','unverified','occupied-idle','attention-only')
$script:UiMatrixR1 = 'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1'
$script:UiMatrixR2 = 'b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2'
$script:UiMatrixRun = 'c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3'
$script:UiMatrixRuleCache = @{}

function Get-UiControlStatesColumns { return @($script:UiMatrixColumns) }

function Get-UiBackgroundFixture {
    param([Parameter(Mandatory=$true)][string]$Name)
    $r1 = $script:UiMatrixR1; $r2 = $script:UiMatrixR2
    $state = New-FastLlmUiBackgroundState
    switch ($Name) {
        'none' { }
        'absent' { $state.observation = [pscustomobject]@{phase='absent';active=$false;attachable=$false;occupied=$false} }
        'stale' { $state.observation = [pscustomobject]@{phase='stale';active=$false;attachable=$false;occupied=$false} }
        { $_ -in @('starting-own','starting-other','starting-case') } {
            $id = if ($Name -ceq 'starting-other') { $r2 } else { $r1 }
            $state.observation = [pscustomobject]@{phase='starting';active=$true;attachable=$false;occupied=$true;requestId=$id}
            $state.pendingRequestId = if ($Name -ceq 'starting-case') { $r1.ToUpper() } else { $r1 }
        }
        { $_ -in @('ready-attachable','ready-attached','ready-attached-unhealthy') } {
            $obs = [pscustomobject]@{phase='ready';active=$true;attachable=$true;occupied=$true;readyIdentityVerified=$true;requestId=$r1
                runId=$script:UiMatrixRun;hostIdentity=@{pid=4242;startUtcTicks=1}}
            if ($Name -cne 'ready-attachable') {
                $obs | Add-Member -NotePropertyName uiHealthChecked -NotePropertyValue $true
                $obs | Add-Member -NotePropertyName servingHealthy -NotePropertyValue ($Name -ceq 'ready-attached')
                $state.attachedRequestId = $r1
            }
            $state.observation = $obs
        }
        'ready-verified-only' {
            $state.observation = [pscustomobject]@{phase='ready';active=$true;attachable=$false;occupied=$true;readyIdentityVerified=$true;requestId=$r1
                runId=$script:UiMatrixRun;hostIdentity=@{pid=4242;startUtcTicks=1}}
        }
        'bare-ready' {
            $state.observation = [pscustomobject]@{phase='ready';active=$true;attachable=$true;occupied=$true
                runId=$script:UiMatrixRun;hostIdentity=@{pid=4242;startUtcTicks=1}}
        }
        'unverified' {
            # Exactly what the window's SetUiBackgroundUnknown builds.
            $state.observation = [pscustomobject]@{phase='occupied-unverified';active=$false;attachable=$false;occupied=$true}
            $state.attention = 'Background ownership could not be verified. Review Diagnostics; start and stop are disabled.'
        }
        'occupied-idle' { $state.observation = [pscustomobject]@{phase='occupied';active=$false;attachable=$false;occupied=$true} }
        'attention-only' {
            $state.observation = [pscustomobject]@{phase='absent';active=$false;attachable=$false;occupied=$false}
            $state.attention = 'x'
        }
        default { throw "Unknown background fixture '$Name'." }
    }
    return $state
}

function New-UiMatrixRow {
    param([bool[]]$Flags, [string]$Background)
    $key = 'f=' + (($Flags | ForEach-Object { if ($_) { '1' } else { '0' } }) -join '') + ';b=' + $Background
    return @{
        key = $key
        busy = [bool]$Flags[0]
        updateKind = if ($Flags[1]) { 'update' } else { '' }
        child = if ($Flags[2]) { [pscustomobject]@{stub=1} } else { $null }
        step = if ($Flags[3]) { 'serving' } else { 'model download' }
        runReady = [bool]$Flags[4]
        sideChild = [bool]$Flags[5]
        vcBroker = if ($Flags[6]) { [pscustomobject]@{stub=1} } else { $null }
        previewReady = [bool]$Flags[7]
        switchGap = [bool]$Flags[8]
        chatUrl = if ($Flags[9]) { 'http://127.0.0.1:1/' } else { $null }
        bgStopRequested = [bool]$Flags[10]
        background = $Background
    }
}

function Get-UiControlStatesMatrix {
    $rows = New-Object System.Collections.ArrayList
    $seen = @{}
    $add = {
        param([bool[]]$Flags, [string]$Background)
        $row = New-UiMatrixRow -Flags $Flags -Background $Background
        if (-not $seen.ContainsKey($row.key)) { $seen[$row.key] = $true; [void]$rows.Add($row) }
    }
    $n = $script:UiMatrixFlags.Count
    # (a) every combination of the 11 flags with the background absent
    for ($i = 0; $i -lt (1 -shl $n); $i++) {
        $flags = New-Object 'bool[]' $n
        for ($b = 0; $b -lt $n; $b++) { $flags[$b] = [bool](($i -shr ($n - 1 - $b)) -band 1) }
        & $add $flags 'absent'
    }
    # (b) each fixture with all flags off and with each single flag on; (c) two combined shapes
    foreach ($name in $script:UiMatrixFixtureNames) {
        $flags = New-Object 'bool[]' $n
        & $add $flags $name
        for ($b = 0; $b -lt $n; $b++) {
            $flags = New-Object 'bool[]' $n
            $flags[$b] = $true
            & $add $flags $name
        }
        $flags = New-Object 'bool[]' $n
        $flags[2] = $true; $flags[3] = $true; $flags[4] = $true
        & $add $flags $name
        $flags = New-Object 'bool[]' $n
        $flags[0] = $true; $flags[2] = $true
        & $add $flags $name
    }
    return @($rows.ToArray())
}

function Get-UiWindowRuleFunctionText {
    param([Parameter(Mandatory=$true)][string]$SourceText)
    $cacheKey = [string]$SourceText.Length + ':' + [string]$SourceText.GetHashCode()
    if ($script:UiMatrixRuleCache.ContainsKey($cacheKey)) { return $script:UiMatrixRuleCache[$cacheKey] }
    $parseErrors = $null
    $tree = [System.Management.Automation.Language.Parser]::ParseInput($SourceText, [ref]$null, [ref]$parseErrors)
    if ($parseErrors.Count -ne 0) { throw 'The window script does not parse.' }
    $texts = @()
    foreach ($name in @('SetBusy','GetUiActionAvailabilityNow','SetTrayMenuAvailable','GetUiStateSnapshot')) {
        $found = @($tree.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name }, $true))
        if ($found.Count -gt 1) { throw "The window script defines $name more than once." }
        if ($found.Count -eq 0) {
            if ($name -ceq 'GetUiStateSnapshot') { continue }
            throw "The window script does not define $name."
        }
        $texts += [string]$found[0].Extent.Text
    }
    $script:UiMatrixRuleCache[$cacheKey] = $texts
    return $texts
}

function Invoke-UiWindowEnableRules {
    param([Parameter(Mandatory=$true)][string]$SourceText, [Parameter(Mandatory=$true)]$Row)
    foreach ($text in (Get-UiWindowRuleFunctionText -SourceText $SourceText)) { Invoke-Expression $text }
    foreach ($name in $script:UiMatrixControlVars) {
        Set-Variable -Name $name -Value ([pscustomobject]@{Enabled=$null;Visible=$null})
    }
    $script:bgState = Get-UiBackgroundFixture -Name $Row.background
    $script:updateRun = if ($Row.updateKind) { [pscustomobject]@{kind=[string]$Row.updateKind} } else { $null }
    $script:child = $Row.child
    $script:step = [string]$Row.step
    $script:runReady = [bool]$Row.runReady
    $script:sideChild = [bool]$Row.sideChild
    $script:vcBroker = $Row.vcBroker
    $script:previewReady = [bool]$Row.previewReady
    $script:switchGap = [bool]$Row.switchGap
    $script:chatUrl = $Row.chatUrl
    $script:bgStopRequested = [bool]$Row.bgStopRequested
    SetBusy ([bool]$Row.busy)
    $bits = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $script:UiMatrixControlVars.Count; $i++) {
        $control = Get-Variable -Name $script:UiMatrixControlVars[$i] -ValueOnly
        $value = if ($script:UiMatrixControlVars[$i] -ceq 'progress') { $control.Visible } else { $control.Enabled }
        if ($null -eq $value) { throw ('SetBusy did not set ' + $script:UiMatrixControlVars[$i] + '.') }
        [void]$bits.Append($(if ([bool]$value) { '1' } else { '0' }))
    }
    $availability = GetUiActionAvailabilityNow ([bool]$Row.busy)
    [void]$bits.Append($(if ([bool]$availability.apiCheck) { '1' } else { '0' }))
    return $bits.ToString()
}

function Get-UiTrayMatrix {
    $rows = @()
    foreach ($text in @('Restore FastLLM','Stop inference / download','Exit FastLLM')) {
        foreach ($available in @(0, 1)) {
            foreach ($broker in @(0, 1)) {
                $rows += @{ key = ('t=' + $text + ';a=' + $available + ';v=' + $broker); text = $text; available = [bool]$available; vcBroker = $(if ($broker) { [pscustomobject]@{stub=1} } else { $null }) }
            }
        }
    }
    return $rows
}

function Invoke-UiWindowTrayRule {
    param([Parameter(Mandatory=$true)][string]$SourceText, [Parameter(Mandatory=$true)]$Row)
    foreach ($text in (Get-UiWindowRuleFunctionText -SourceText $SourceText)) { Invoke-Expression $text }
    $item = [pscustomobject]@{Text=[string]$Row.text;Enabled=$null}
    $script:trayMenu = [pscustomobject]@{Items=@($item)}
    $script:vcBroker = $Row.vcBroker
    SetTrayMenuAvailable ([bool]$Row.available)
    if ($null -eq $item.Enabled) { throw 'SetTrayMenuAvailable did not set the item.' }
    return $(if ([bool]$item.Enabled) { '1' } else { '0' })
}
