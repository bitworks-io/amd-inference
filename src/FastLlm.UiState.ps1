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

# Whether one tray menu item is enabled. During Microsoft setup only Restore stays usable; otherwise every item follows Available.
function Get-FastLlmUiTrayItemEnabled {
    param([Parameter(Mandatory=$true)][string]$ItemText,[Parameter(Mandatory=$true)][bool]$Available,[Parameter(Mandatory=$true)][bool]$VcBrokerActive)
    if ($VcBrokerActive) { return [bool]($ItemText -ceq 'Restore FastLLM') }
    return [bool]$Available
}
