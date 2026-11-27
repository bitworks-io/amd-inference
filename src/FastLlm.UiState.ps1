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
# action is enabled. Codes: microsoft-setup, busy, side-step, attached, no-run, not-running, background, no-preview. First match wins.
# The attachable and requestMatches expressions are copies of the ones in Get-FastLlmUiControlStates; the control-states suite pins them
# text-identical and checks that a code is empty exactly when the control state is true, so a drift between the two fails there.
# ConnectRunning is the Connect page's own "is FastLLM serving" flag and is read by apiCheck only.
function Get-FastLlmUiGreyedReason {
    param(
        [Parameter(Mandatory=$true)][ValidateSet('diagnostics','driverGuidance','saveBundle','backgroundCheck','backgroundAttach','apiCheck','chooseSetup','startInputs','settings')][string]$Action,
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
        'chooseSetup' {
            if ($vc) { return 'microsoft-setup' }
            if ($busy) { return 'busy' }
            if (Test-FastLlmUiStateOccupied -Background $bg) { return 'background' }
            if (-not $Snapshot.PreviewReady) { return 'no-preview' }
            return ''
        }
        'startInputs' {
            if ($busy) { if ($vc) { return 'microsoft-setup' }; return 'busy' }
            if (Test-FastLlmUiStateOccupied -Background $bg) { return 'background' }
            return ''
        }
        'settings' {
            $availability = Get-FastLlmUiStateAvailabilityFor -Snapshot $Snapshot -Busy $busy
            if ($availability.settings) { return '' }
            if ($vc) { return 'microsoft-setup' }
            return 'busy'
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

# One attach-ready rule: a run is attachable (or its Ready identity is verified), it is our pending request (or none is pending) and nothing is attached.
# The attachable and requestMatches expressions are copies of the ones in Get-FastLlmUiControlStates; the card-state suite pins them text-identical and checks
# the card offers Attach exactly when the Attach control is enabled, so the two cannot drift apart.
function Test-FastLlmUiBackgroundAttachReady {
    param([Parameter(Mandatory=$true)]$Background)
    $bg = $Background
    $observation = $bg.observation
    $attachable = [bool]($observation -and
        ((Get-FastLlmUiStateProperty $observation 'attachable') -or
         ((Get-FastLlmUiStateProperty $observation 'readyIdentityVerified'))))
    $requestMatches = [bool](-not $bg.pendingRequestId -or
        [string](Get-FastLlmUiStateProperty $observation 'requestId') -ceq [string]$bg.pendingRequestId)
    return [bool](-not $bg.attachedRequestId -and $attachable -and $requestMatches)
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
    $attachReady = Test-FastLlmUiBackgroundAttachReady -Background $bg
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
    } elseif (-not $attachReady -and (($bg.pendingRequestId -and -not $bg.attention) -or ($active -and $phase -cne 'ready'))) {   # row 5: background start, no steps (not once Attach is ready)
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
    } elseif ($attachReady) {                                         # row 10: a run to attach to
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

# The Settings page's held edits (PR 3c). Every expression is today's: the dialog's initial values and its Save handler.
# The held thinking and idle values are combo indexes: thinking 1 is 'off', idle indexes 0..3 are never, 15, 30 and 60 minutes.
function ConvertTo-FastLlmUiSettingsHeld {
    param([Parameter(Mandatory=$true)]$Current)
    return [pscustomobject][ordered]@{
        port          = [int]$Current.serverPort
        thinkingIndex = [int]$(if ([string]$Current.thinking -ceq 'off') { 1 } else { 0 })
        chatPage      = [bool]([string]$Current.chatPage -ceq 'on')
        idleIndex     = [int]$(switch ([int]$Current.idleStopMinutes) { 15 { 1 } 30 { 2 } 60 { 3 } default { 0 } })
        keyBox        = [string](Get-FastLlmUiApiKeyBoxState -Settings $Current)
        keyTouched    = $false
        allowSwitch   = [bool]$Current.allowSwitch
        # The serving keys of the Settings additions, as the reader normalises them. A missing one is the store's default.
        contextProfile = [string]$(if ($Current.PSObject.Properties['contextProfile'] -and [string]$Current.contextProfile -ceq 'long') { 'long' } else { 'default' })
        slots          = [int]$(if ($Current.PSObject.Properties['slots'] -and [int]$Current.slots -eq 2) { 2 } else { 1 })
        embeddings     = [string]$(if ($Current.PSObject.Properties['embeddings'] -and [string]$Current.embeddings -ceq 'on') { 'on' } else { 'off' })
        embeddingPort  = [int]$(if ($Current.PSObject.Properties['embeddingPort']) { [int]$Current.embeddingPort } else { 8081 })
    }
}

# The values Save writes, from the held edits (the dialog's Save expressions).
function ConvertFrom-FastLlmUiSettingsHeld {
    param([Parameter(Mandatory=$true)]$Held)
    return [pscustomobject][ordered]@{
        serverPort      = [int]$Held.port
        thinking        = [string]$(if ([int]$Held.thinkingIndex -eq 1) { 'off' } else { 'auto' })
        chatPage        = [string]$(if ([bool]$Held.chatPage) { 'on' } else { 'off' })
        idleStopMinutes = [int]@(0,15,30,60)[[Math]::Max(0,[int]$Held.idleIndex)]
        allowSwitch     = [bool]$Held.allowSwitch
        contextProfile  = [string]$(if ($Held.PSObject.Properties['contextProfile']) { [string]$Held.contextProfile } else { 'default' })
        slots           = [int]$(if ($Held.PSObject.Properties['slots']) { [int]$Held.slots } else { 1 })
        embeddings      = [string]$(if ($Held.PSObject.Properties['embeddings']) { [string]$Held.embeddings } else { 'off' })
        embeddingPort   = [int]$(if ($Held.PSObject.Properties['embeddingPort']) { [int]$Held.embeddingPort } else { 8081 })
    }
}

# The "Require an API key" box as one of three strings, from a checkbox IsChecked ($true, $false or $null for the indeterminate state).
function ConvertTo-FastLlmUiKeyBoxState {
    param([AllowNull()]$IsChecked)
    if ($null -eq $IsChecked) { return 'indeterminate' }
    if ([bool]$IsChecked) { return 'checked' }
    return 'unchecked'
}

# Whether the held edits differ from the saved ones. Touching the box while the saved key setting is unknown counts as an edit.
function Test-FastLlmUiSettingsDirty {
    param([Parameter(Mandatory=$true)]$Saved,[Parameter(Mandatory=$true)]$Held)
    if ([int]$Saved.port -ne [int]$Held.port) { return $true }
    if ([int]$Saved.thinkingIndex -ne [int]$Held.thinkingIndex) { return $true }
    if ([bool]$Saved.chatPage -ne [bool]$Held.chatPage) { return $true }
    if ([int]$Saved.idleIndex -ne [int]$Held.idleIndex) { return $true }
    if ([bool]$Saved.allowSwitch -ne [bool]$Held.allowSwitch) { return $true }
    if ([string]$Saved.keyBox -cne [string]$Held.keyBox) { return $true }
    # The Settings additions are read tolerantly: a side that has none holds the store's defaults.
    $savedProfile = if ($Saved.PSObject.Properties['contextProfile']) { [string]$Saved.contextProfile } else { 'default' }
    $heldProfile = if ($Held.PSObject.Properties['contextProfile']) { [string]$Held.contextProfile } else { 'default' }
    if ($savedProfile -cne $heldProfile) { return $true }
    $savedSlots = if ($Saved.PSObject.Properties['slots']) { [int]$Saved.slots } else { 1 }
    $heldSlots = if ($Held.PSObject.Properties['slots']) { [int]$Held.slots } else { 1 }
    if ($savedSlots -ne $heldSlots) { return $true }
    $savedEmb = if ($Saved.PSObject.Properties['embeddings']) { [string]$Saved.embeddings } else { 'off' }
    $heldEmb = if ($Held.PSObject.Properties['embeddings']) { [string]$Held.embeddings } else { 'off' }
    if ($savedEmb -cne $heldEmb) { return $true }
    $savedEmbPort = if ($Saved.PSObject.Properties['embeddingPort']) { [int]$Saved.embeddingPort } else { 8081 }
    $heldEmbPort = if ($Held.PSObject.Properties['embeddingPort']) { [int]$Held.embeddingPort } else { 8081 }
    if ($savedEmbPort -ne $heldEmbPort) { return $true }
    if ([string]$Saved.keyBox -ceq 'indeterminate' -and [bool]$Held.keyTouched) { return $true }
    return $false
}

# What the Settings additions rows show. Both Embeddings rows show when an approved, measured embedding model is available or the saved setting is
# already on (so it can be turned off); otherwise they are hidden. Long and "2 requests at once" are each enabled when the install has a measured row for
# them (LongMeasured: Long at the held slots; TwoMeasured: the held profile at 2) AND the Models page's Context is 0 (a Context above 0 is refused by the
# planner for either), or when that value is already the saved one. A disabled one gets a reason code: 'needs-catalog-context' (the actionable one, so it
# wins when both apply) or 'long-not-measured' (matching the start's refusal).
function Get-FastLlmUiSettingsAdditionsView {
    param(
        [Parameter(Mandatory=$true)][bool]$EmbeddingsAvailable,
        [Parameter(Mandatory=$true)][string]$SavedEmbeddings,
        [Parameter(Mandatory=$true)][bool]$LongMeasured,
        [Parameter(Mandatory=$true)][string]$SavedContextProfile,
        [Parameter(Mandatory=$true)][bool]$TwoMeasured,
        [Parameter(Mandatory=$true)][int]$SavedSlots,
        [Parameter(Mandatory=$true)][int]$ContextSize
    )
    $showEmbeddings = [bool]($EmbeddingsAvailable -or ($SavedEmbeddings -ceq 'on'))
    $catalogContext = [bool]($ContextSize -le 0)
    $longEnabled = [bool](($LongMeasured -and $catalogContext) -or ($SavedContextProfile -ceq 'long'))
    $twoEnabled = [bool](($TwoMeasured -and $catalogContext) -or ($SavedSlots -eq 2))
    $longReason = ''
    if (-not $longEnabled) { $longReason = 'long-not-measured'; if (-not $catalogContext) { $longReason = 'needs-catalog-context' } }
    $twoReason = ''
    if (-not $twoEnabled) { $twoReason = 'long-not-measured'; if (-not $catalogContext) { $twoReason = 'needs-catalog-context' } }
    return @{ showEmbeddings = $showEmbeddings; longEnabled = $longEnabled; longReasonCode = $longReason; twoEnabled = $twoEnabled; twoReasonCode = $twoReason }
}

# What leaving the Settings page does: go, stay, save (run Save first) or discard-go (drop the edits and go).
# Not dirty goes. Hiding the window keeps the edits. Signing out discards them. Otherwise the answer to the save prompt decides;
# cancel (or no answer yet) stays. A save answer without SaveOk says save (run it); with SaveOk it goes, or stays when Save was refused.
function Get-FastLlmUiSettingsExitDecision {
    param(
        [Parameter(Mandatory=$true)][bool]$Dirty,
        [Parameter(Mandatory=$true)][ValidateSet('save','discard','cancel','none')][string]$Answer,
        [AllowNull()]$SaveOk = $null,
        [Parameter(Mandatory=$true)][ValidateSet('leave','close','signout','hide')][string]$Reason
    )
    if (-not $Dirty) { return 'go' }
    if ($Reason -ceq 'hide') { return 'go' }
    if ($Reason -ceq 'signout') { return 'discard-go' }
    switch -CaseSensitive ($Answer) {
        'save' { if ($null -eq $SaveOk) { return 'save' }; if ([bool]$SaveOk) { return 'go' }; return 'stay' }
        'discard' { return 'discard-go' }
        default { return 'stay' }
    }
}

# The Enter, Escape and close-box answers of a message box, as a pure function of its button set and default button (what Windows does for a MessageBox).
# DefaultButton is MessageBox's own default, Button1, for a call site that passes none. An id is OK, Cancel, Yes or No; '' means "nothing happens".
# OK: Enter, Escape and the close box answer OK. OKCancel: Enter answers the default button, Escape and the close box answer Cancel.
# YesNo: Enter answers the default button; Escape does nothing and the close box is disabled (closeEnabled is false, close is '').
function Get-FastLlmUiDialogKeyPlan {
    param(
        [Parameter(Mandatory=$true)][ValidateSet('OK','OKCancel','YesNo')][string]$Buttons,
        [ValidateSet('Button1','Button2')][string]$DefaultButton='Button1'
    )
    $second=($DefaultButton -ceq 'Button2')
    switch -CaseSensitive ($Buttons) {
        'OK' { return @{ order=[string[]]@('OK'); enter='OK'; escape='OK'; close='OK'; closeEnabled=$true } }
        'OKCancel' {
            $enter='OK'; if($second){$enter='Cancel'}
            return @{ order=[string[]]@('OK','Cancel'); enter=$enter; escape='Cancel'; close='Cancel'; closeEnabled=$true }
        }
        default {
            $enter='Yes'; if($second){$enter='No'}
            return @{ order=[string[]]@('Yes','No'); enter=$enter; escape=''; close=''; closeEnabled=$false }
        }
    }
}
