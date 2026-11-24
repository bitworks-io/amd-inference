#requires -Version 5.1
# The FastLLM window's enable rules as pure functions of one observed snapshot. Callers dot-source
# FastLlm.UiFlow.ps1 and FastLlm.UiBackground.ps1 first; this file dot-sources nothing.

# Reads a property of an observation that may not carry it; $null when absent (safe under StrictMode 2).
function Get-FastLlmUiStateProperty {
    param($Object,[string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

# True when a background run holds the machine: a pending or attached request, an attention note, or an occupied observation.
function Test-FastLlmUiStateOccupied {
    param($Background)
    $observation = $Background.observation
    return [bool]($Background.pendingRequestId -or $Background.attachedRequestId -or
        $Background.attention -or ($observation -and (Get-FastLlmUiStateProperty $observation 'occupied')))
}

# One immutable observation of everything the enable rules read. UpdateKind is '', 'update' or 'reinstall'.
function New-FastLlmUiStateSnapshot {
    param(
        [Parameter(Mandatory=$true)][bool]$Busy,
        [Parameter(Mandatory=$true)][AllowEmptyString()][ValidateSet('','update','reinstall')][string]$UpdateKind,
        [Parameter(Mandatory=$true)][bool]$ChildActive,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Step,
        [Parameter(Mandatory=$true)][bool]$RunReady,
        [Parameter(Mandatory=$true)][bool]$SideChildActive,
        [Parameter(Mandatory=$true)][bool]$VcBrokerActive,
        [Parameter(Mandatory=$true)][bool]$PreviewReady,
        [Parameter(Mandatory=$true)][bool]$SwitchGap,
        [Parameter(Mandatory=$true)][bool]$ChatUrlSet,
        [Parameter(Mandatory=$true)][bool]$BackgroundStopRequested,
        [Parameter(Mandatory=$true)]$Background,
        [AllowEmptyString()][string]$FlowPhase = '',
        [bool]$FailureHeld = $false
    )
    return [pscustomobject]@{
        Busy = $Busy
        UpdateKind = $UpdateKind
        ChildActive = $ChildActive
        Step = $Step
        RunReady = $RunReady
        SideChildActive = $SideChildActive
        VcBrokerActive = $VcBrokerActive
        PreviewReady = $PreviewReady
        SwitchGap = $SwitchGap
        ChatUrlSet = $ChatUrlSet
        BackgroundStopRequested = $BackgroundStopRequested
        Background = $Background
        FlowPhase = $FlowPhase
        FailureHeld = $FailureHeld
    }
}

# Which actions are usable for a given Busy value, as the window's GetUiActionAvailabilityNow computes it.
function Get-FastLlmUiStateAvailabilityFor {
    param([Parameter(Mandatory=$true)]$Snapshot,[Parameter(Mandatory=$true)][bool]$Busy)
    $updating = [bool]$Snapshot.UpdateKind
    $foregroundServing = [bool]($Snapshot.ChildActive -and $Snapshot.Step -ceq 'serving' -and $Snapshot.RunReady)
    $launch = [bool]($Busy -and (-not $foregroundServing -or $updating -or $Snapshot.VcBrokerActive))
    $occupied = Test-FastLlmUiStateOccupied -Background $Snapshot.Background
    return Get-FastLlmUiActionAvailability -LaunchInProgress $launch -Serving ([bool]$Snapshot.RunReady) -SideStepActive ([bool]$Snapshot.SideChildActive) -BackgroundOccupied $occupied
}

# Which actions are usable, from the raw Busy (not the update-normalized one), as the window's GetUiActionAvailabilityNow is asked for the API check.
function Get-FastLlmUiSnapshotAvailability {
    param([Parameter(Mandatory=$true)]$Snapshot)
    return Get-FastLlmUiStateAvailabilityFor -Snapshot $Snapshot -Busy ([bool]$Snapshot.Busy)
}

# The enabled state of each of the window's 18 controls (progressVisible is the progress bar's visibility), as SetBusy sets them.
function Get-FastLlmUiControlStates {
    param([Parameter(Mandatory=$true)]$Snapshot)
    $busy = [bool]($Snapshot.Busy -or [bool]$Snapshot.UpdateKind)
    $bg = $Snapshot.Background
    $observation = $bg.observation
    $occupied = Test-FastLlmUiStateOccupied -Background $bg
    # SetBusy hands the update-normalized Busy to the availability rule.
    $availability = Get-FastLlmUiStateAvailabilityFor -Snapshot $Snapshot -Busy $busy
    $idle = [bool](-not $busy -and -not $occupied)
    $attachable = [bool]($observation -and
        ((Get-FastLlmUiStateProperty $observation 'attachable') -or
         ((Get-FastLlmUiStateProperty $observation 'readyIdentityVerified'))))
    $requestMatches = [bool](-not $bg.pendingRequestId -or
        [string](Get-FastLlmUiStateProperty $observation 'requestId') -ceq [string]$bg.pendingRequestId)
    $states = [ordered]@{}
    $states['install'] = $idle
    $states['start'] = $idle
    $states['model'] = $idle
    $states['path'] = $idle
    $states['context'] = $idle
    $states['bar'] = $idle
    $states['diagnostics'] = [bool](-not $busy)
    $states['driverGuidance'] = [bool](-not $busy)
    $states['settings'] = [bool]$availability.settings
    $states['saveBundle'] = [bool]$availability.saveBundle
    $states['chooseSetup'] = [bool](-not $busy -and -not $occupied -and -not $Snapshot.VcBrokerActive -and $Snapshot.PreviewReady)
    $states['backgroundStart'] = [bool](-not $busy -and -not $Snapshot.VcBrokerActive -and -not $Snapshot.ChildActive -and
        (Test-FastLlmUiBackgroundMayStart -State $bg))
    $states['backgroundAttach'] = [bool](-not $busy -and -not $Snapshot.VcBrokerActive -and -not $Snapshot.ChildActive -and
        -not $bg.attachedRequestId -and $attachable -and $requestMatches)
    $states['backgroundCheck'] = [bool](-not $busy -and -not $Snapshot.VcBrokerActive -and -not $Snapshot.ChildActive)
    $states['stop'] = [bool](-not $Snapshot.VcBrokerActive -and -not $Snapshot.BackgroundStopRequested -and
        ($Snapshot.ChildActive -or $bg.attachedRequestId -or -not $occupied -or $Snapshot.SwitchGap))
    $states['tray'] = [bool](-not $Snapshot.VcBrokerActive)
    $states['openChat'] = [bool]$Snapshot.ChatUrlSet
    $states['progressVisible'] = $busy
    return [pscustomobject]$states
}

# Why an action is greyed, as a code only (never text; the view maps each code to its string). '' means the
# action is enabled. Codes: microsoft-setup, busy, side-step, attached, no-run, not-running. First match wins.
# The attachable and requestMatches expressions are copies of the ones in Get-FastLlmUiControlStates; the control-states suite pins them
# text-identical and checks that a code is empty exactly when the control state is true, so a drift between the two fails there.
# ConnectRunning is the Connect page's own "is FastLLM serving" flag and is read by apiCheck only.
function Get-FastLlmUiGreyedReason {
    param(
        [Parameter(Mandatory=$true)][ValidateSet('diagnostics','driverGuidance','saveBundle','backgroundCheck','backgroundAttach','apiCheck')][string]$Action,
        [Parameter(Mandatory=$true)]$Snapshot,
        [bool]$ConnectRunning = $false
    )
    $busy = [bool]($Snapshot.Busy -or [bool]$Snapshot.UpdateKind)
    $bg = $Snapshot.Background
    $observation = $bg.observation
    $vc = [bool]$Snapshot.VcBrokerActive
    switch -CaseSensitive ($Action) {
        { $_ -ceq 'diagnostics' -or $_ -ceq 'driverGuidance' } {
            if ($busy) { if ($vc) { return 'microsoft-setup' }; return 'busy' }
            return ''
        }
        'saveBundle' {
            $availability = Get-FastLlmUiStateAvailabilityFor -Snapshot $Snapshot -Busy $busy
            if ($availability.saveBundle) { return '' }
            if ($vc) { return 'microsoft-setup' }
            if (-not $availability.settings) { return 'busy' }
            return 'side-step'
        }
        'backgroundCheck' {
            if ($vc) { return 'microsoft-setup' }
            if ($busy -or $Snapshot.ChildActive) { return 'busy' }
            return ''
        }
        'backgroundAttach' {
            $attachable = [bool]($observation -and
                ((Get-FastLlmUiStateProperty $observation 'attachable') -or
                 ((Get-FastLlmUiStateProperty $observation 'readyIdentityVerified'))))
            $requestMatches = [bool](-not $bg.pendingRequestId -or
                [string](Get-FastLlmUiStateProperty $observation 'requestId') -ceq [string]$bg.pendingRequestId)
            if ($vc) { return 'microsoft-setup' }
            if ($busy -or $Snapshot.ChildActive) { return 'busy' }
            if ($bg.attachedRequestId) { return 'attached' }
            if (-not ($attachable -and $requestMatches)) { return 'no-run' }
            return ''
        }
        'apiCheck' {
            if (-not $ConnectRunning) { return 'not-running' }
            $availability = Get-FastLlmUiSnapshotAvailability -Snapshot $Snapshot
            if ($availability.apiCheck) { return '' }
            if ($Snapshot.SideChildActive) { return 'side-step' }
            return 'not-running'
        }
        default { throw "Unknown action '$Action'" }
    }
}

# Whether one tray menu item is enabled. During Microsoft setup only Restore stays usable; otherwise every item follows Available.
function Get-FastLlmUiTrayItemEnabled {
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$ItemText,[Parameter(Mandatory=$true)][bool]$Available,[Parameter(Mandatory=$true)][bool]$VcBrokerActive)
    if ($VcBrokerActive) { return [bool]($ItemText -ceq 'Restore FastLLM') }
    return [bool]$Available
}

# The four start steps the status card shows, in order.
$script:FastLlmUiCardStepNames = @('Check this PC','Engine','Model','Server')

# The status card's step list: steps before $Current are done, $Current is $CurrentState, later ones are not started.
function New-FastLlmUiCardSteps {
    param([int]$Current,[string]$CurrentState)
    $steps = @()
    for ($i = 1; $i -le 4; $i++) {
        $state = if ($i -lt $Current) { 'done' } elseif ($i -eq $Current) { $CurrentState } else { 'not started' }
        $steps += [pscustomobject]@{ name = $script:FastLlmUiCardStepNames[$i - 1]; state = $state }
    }
    return ,$steps
}

# The 1-based start step a Step or FlowPhase name belongs to; 0 when it is not a start step.
function Get-FastLlmUiCardStepIndex {
    param([AllowEmptyString()][string]$Name)
    switch -CaseSensitive ($Name) {
        { $_ -in @('setup check','setup','setup-attention') } { return 1 }
        { $_ -in @('engine','component install') } { return 2 }
        { $_ -in @('preview','consent','model download','model-download') } { return 3 }
        'serving' { return 4 }
        default { return 0 }
    }
}

# The status card: one state, its headline, tone, reason, main action and start steps, from one snapshot. First match wins.
function Get-FastLlmUiCardState {
    param([Parameter(Mandatory=$true)]$Snapshot)
    $headlines = @{
        'not-running' = 'Not running'; 'starting' = 'Starting'; 'running' = 'Running'; 'running-background' = 'Running in background'
        'background-found' = 'Background run found'; 'needs-attention' = 'Needs attention'; 'switching' = 'Switching models'
        'stopping' = 'Stopping'; 'working' = 'Working'; 'waiting-microsoft' = 'Waiting for Microsoft setup'
        'updating' = 'Updating'; 'reinstalling' = 'Reinstalling'
    }
    $bg = $Snapshot.Background
    $obs = $bg.observation
    $phase = [string](Get-FastLlmUiStateProperty $obs 'phase')
    $active = [bool](Get-FastLlmUiStateProperty $obs 'active')
    $attachable = [bool](Get-FastLlmUiStateProperty $obs 'attachable')
    $occupied = [bool](Get-FastLlmUiStateProperty $obs 'occupied')
    $healthChecked = [bool](Get-FastLlmUiStateProperty $obs 'uiHealthChecked')
    $servingHealthy = Get-FastLlmUiStateProperty $obs 'servingHealthy'
    $attached = [bool]$bg.attachedRequestId
    $stepIndex = Get-FastLlmUiCardStepIndex -Name ([string]$Snapshot.Step)
    $flowIndex = Get-FastLlmUiCardStepIndex -Name ([string]$Snapshot.FlowPhase)

    $state = 'not-running'; $tone = 'neutral'; $reason = ''; $action = 'start'; $steps = $null; $stepsText = ''
    if ($Snapshot.VcBrokerActive) {                                   # row 1: Microsoft setup is open
        $state = 'waiting-microsoft'; $tone = 'caution'; $action = 'none'
    } elseif ($Snapshot.UpdateKind -ceq 'update') {                   # row 2: an update run
        $state = 'updating'; $tone = 'accent'; $action = 'none'
    } elseif ($Snapshot.UpdateKind -ceq 'reinstall') {                # row 2: a reinstall run
        $state = 'reinstalling'; $tone = 'accent'; $action = 'none'
    } elseif ($Snapshot.BackgroundStopRequested) {                    # row 3: a background stop is in flight
        $state = 'stopping'; $tone = 'neutral'; $action = 'stop'
    } elseif ($Snapshot.SwitchGap) {                                  # row 4: between two models
        $state = 'switching'; $tone = 'accent'; $action = 'stop'
    } elseif ($Snapshot.ChildActive -and $stepIndex -gt 0 -and -not $Snapshot.RunReady) {   # row 5: foreground start
        $state = 'starting'; $tone = 'accent'; $action = 'stop'
        $steps = New-FastLlmUiCardSteps -Current $stepIndex -CurrentState 'in progress'
    } elseif (-not $Snapshot.ChildActive -and -not $Snapshot.FailureHeld -and
              ($Snapshot.FlowPhase -ceq 'setup-attention' -or $Snapshot.FlowPhase -ceq 'consent')) {   # row 5: flow waiting
        $state = 'starting'; $tone = 'accent'; $action = 'stop'
        $steps = New-FastLlmUiCardSteps -Current $flowIndex -CurrentState $(if ($Snapshot.FlowPhase -ceq 'setup-attention') { 'needs attention' } else { 'in progress' })
    } elseif (($bg.pendingRequestId -and -not $bg.attention) -or ($active -and $phase -cne 'ready')) {   # row 5: background start, no steps
        $state = 'starting'; $tone = 'accent'; $action = 'stop'
    } elseif ($attached -and $healthChecked -and $servingHealthy -eq $false) {   # row 6: attached run failed its health check
        $state = 'needs-attention'; $tone = 'critical'; $reason = 'health-failed'
    } elseif ($phase -ceq 'occupied-unverified') {                    # row 6: ownership not verified
        $state = 'needs-attention'; $tone = 'caution'; $reason = 'unverified'
    } elseif ($bg.attention) {                                        # row 6: an attention note
        $state = 'needs-attention'; $tone = 'caution'; $reason = 'attention'
    } elseif ($occupied -and -not $active) {                          # row 6: occupied while idle
        $state = 'needs-attention'; $tone = 'caution'; $reason = 'occupied'
    } elseif ($attached -and $healthChecked -and $attachable) {       # row 7: attached, health checked
        $state = 'running-background'; $tone = 'success'; $action = 'stop'
    } elseif ($Snapshot.RunReady) {                                   # row 7: serving
        $state = 'running'; $tone = 'success'; $action = 'stop'
    } elseif ($Snapshot.ChildActive) {                                # row 8: any other foreground step
        $state = 'working'; $tone = 'accent'; $action = 'stop'
    } elseif ($Snapshot.SideChildActive) {                            # row 8: a side step
        $state = 'working'; $tone = 'accent'
    } elseif ($Snapshot.FailureHeld) {                                # row 9: a held failure
        $state = 'needs-attention'; $tone = 'critical'; $reason = 'failure'
    } elseif ($attachable -and -not $attached) {                      # row 10: a run to attach to
        $state = 'background-found'; $action = 'attach'
    }                                                                 # row 11: not running (the defaults)

    if ($steps) {
        $current = @($steps | Where-Object { $_.state -cne 'done' -and $_.state -cne 'not started' })[0]
        $index = [array]::IndexOf(@($steps | ForEach-Object { $_.name }), $current.name) + 1
        $stepsText = 'Step ' + $index + ' of 4, ' + $current.name + ', ' + $current.state
    }
    return [pscustomobject]@{
        state = $state; headline = $headlines[$state]; tone = $tone; reason = $reason; mainAction = $action
        steps = $steps; stepsText = $stepsText
    }
}
