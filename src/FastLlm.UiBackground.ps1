# Window-only coordination for the opt-in user-session host. The native host
# validates hardware, model bytes, consent, source pins, and run ownership.
function New-FastLlmUiBackgroundState {
    [pscustomobject]@{
        observation=$null
        pendingRequestId=$null
        pendingHostIdentity=$null
        pendingStartedUtc=$null
        attachedRequestId=$null
        attachedRunId=$null
        attention=$null
    }
}

function Assert-FastLlmUiBackgroundObservation {
    param([Parameter(Mandatory=$true)]$Observation)
    foreach($name in @('phase','active','attachable','occupied')){
        if($null -eq $Observation.PSObject.Properties[$name]){throw 'Background host status is incomplete.'}
    }
    if($Observation.active -isnot [bool] -or $Observation.attachable -isnot [bool] -or
       $Observation.occupied -isnot [bool] -or [string]::IsNullOrWhiteSpace([string]$Observation.phase)){
        throw 'Background host status has invalid types.'
    }
    if($Observation.active -and -not $Observation.occupied){throw 'Active background host must occupy its installation.'}
    if($Observation.PSObject.Properties['readyIdentityVerified'] -and
       $Observation.readyIdentityVerified -isnot [bool]){throw 'Background Ready identity flag has an invalid type.'}
    if($Observation.attachable -and (-not $Observation.active -or [string]$Observation.phase -cne 'ready')){
        throw 'Background host claimed attachability without verified Ready.'
    }
    if($Observation.PSObject.Properties['requestId'] -and $Observation.requestId -and
       [string]$Observation.requestId -cnotmatch '^[0-9a-f]{32}$'){
        throw 'Background request identity is invalid.'
    }
    if($Observation.active -and
       (-not $Observation.requestId -or -not $Observation.hostIdentity -or
        [int]$Observation.hostIdentity.pid -le 0 -or [long]$Observation.hostIdentity.startUtcTicks -le 0)){
        throw 'Active background host identity is incomplete.'
    }
    if(($Observation.attachable -or
        ($Observation.PSObject.Properties['readyIdentityVerified'] -and $Observation.readyIdentityVerified)) -and
       ([string]$Observation.phase -cne 'ready' -or [string]$Observation.runId -cnotmatch '^[0-9a-f]{32}$')){
        throw 'Ready background run identity is invalid.'
    }
    return $Observation
}

function Set-FastLlmUiBackgroundObservation {
    param([Parameter(Mandatory=$true)]$State,[Parameter(Mandatory=$true)]$Observation)
    $valid=Assert-FastLlmUiBackgroundObservation -Observation $Observation
    $State.observation=$valid
    $previousAttention=$State.attention
    $State.attention=$previousAttention
    $observedRequestId=if($valid.PSObject.Properties['requestId']){[string]$valid.requestId}else{$null}
    if($State.pendingRequestId){
        if($observedRequestId -and $observedRequestId -cne [string]$State.pendingRequestId){
            $State.attention='Another background request now owns this installation. Review Diagnostics.'
        }elseif($observedRequestId -ceq [string]$State.pendingRequestId -and $valid.active){
            $State.attention=$null
        }elseif($observedRequestId -ceq [string]$State.pendingRequestId -and
                -not $valid.occupied -and [string]$valid.phase -in @('stale','failed','stopped')){
            $State.pendingRequestId=$null;$State.pendingHostIdentity=$null;$State.pendingStartedUtc=$null
            $State.attention='Background host ended before attachment. Review Diagnostics.'
        }
    }
    if($State.attachedRequestId){
        if(-not $valid.active -or $observedRequestId -cne [string]$State.attachedRequestId -or
           [string]$valid.runId -cne [string]$State.attachedRunId){
            $State.attachedRequestId=$null;$State.attachedRunId=$null
            if(-not $State.attention){$State.attention='The attached background run changed or ended. Review its status.'}
        }
    }
    return $State
}

function Test-FastLlmUiBackgroundMayStart {
    param([Parameter(Mandatory=$true)]$State)
    return [bool]($State.observation -and -not $State.observation.occupied -and
        [string]$State.observation.phase -in @('absent','stale') -and
        -not $State.pendingRequestId -and -not $State.attachedRequestId -and -not $State.attention)
}

function Invoke-FastLlmUiBackgroundStart {
    param([Parameter(Mandatory=$true)]$State,[Parameter(Mandatory=$true)][scriptblock]$Start,
          [Parameter(Mandatory=$true)]$Request)
    if(-not (Test-FastLlmUiBackgroundMayStart -State $State)){
        throw 'Background ownership is unresolved; a second start was not sent.'
    }
    $result=& $Start $Request
    if(-not $result -or [string]$result.phase -cne 'starting' -or
       [string]$result.requestId -cnotmatch '^[0-9a-f]{32}$' -or
       -not $result.hostIdentity -or [int]$result.hostIdentity.pid -le 0 -or
       [long]$result.hostIdentity.startUtcTicks -le 0){
        $State.attention='Background launch result needs review. Check Diagnostics before starting again.'
        throw 'Background launch returned an invalid owner identity.'
    }
    $State.pendingRequestId=[string]$result.requestId
    $State.pendingHostIdentity=$result.hostIdentity
    $State.pendingStartedUtc=[DateTime]::UtcNow
    $State.attention=$null
    return $result
}

function Invoke-FastLlmUiBackgroundAttach {
    param([Parameter(Mandatory=$true)]$State,[Parameter(Mandatory=$true)][scriptblock]$Attach)
    $status=Assert-FastLlmUiBackgroundObservation -Observation $State.observation
    $readyIdentity=[bool]($status.PSObject.Properties['readyIdentityVerified'] -and $status.readyIdentityVerified)
    if((-not $status.attachable -and -not $readyIdentity) -or -not $status.active -or
       -not $status.occupied -or [string]$status.phase -cne 'ready' -or
       ($State.pendingRequestId -and [string]$status.requestId -cne [string]$State.pendingRequestId)){
        throw 'Only the exact verified Ready background request can be attached.'
    }
    $result=& $Attach ([string]$status.requestId)
    $valid=Assert-FastLlmUiBackgroundObservation -Observation $result
    if(-not $valid.attachable -or [string]$valid.requestId -cne [string]$status.requestId -or
       [string]$valid.runId -cne [string]$status.runId -or
       [int]$valid.hostIdentity.pid -ne [int]$status.hostIdentity.pid -or
       [long]$valid.hostIdentity.startUtcTicks -ne [long]$status.hostIdentity.startUtcTicks){
        throw 'Background host changed during attach.'
    }
    $State.observation=$valid
    $State.pendingRequestId=$null
    $State.pendingHostIdentity=$null
    $State.pendingStartedUtc=$null
    $State.attachedRequestId=[string]$valid.requestId
    $State.attachedRunId=[string]$valid.runId
    $State.attention=$null
    return $valid
}

function Test-FastLlmUiBackgroundPendingHost {
    param([Parameter(Mandatory=$true)]$State,[Parameter(Mandatory=$true)][scriptblock]$TestProcess,
          [DateTime]$NowUtc=[DateTime]::UtcNow,[ValidateRange(1,300)][int]$RecordDeadlineSeconds=30)
    if(-not $State.pendingRequestId){return $true}
    $observedRequestId=if($State.observation -and $State.observation.PSObject.Properties['requestId']){
        [string]$State.observation.requestId
    }else{$null}
    if($observedRequestId -ceq [string]$State.pendingRequestId){return $true}
    if(-not $State.pendingHostIdentity -or -not $State.pendingStartedUtc){
        $State.attention='Background launch identity is incomplete. Review Diagnostics.'
        return $false
    }
    $alive=[bool](& $TestProcess $State.pendingHostIdentity)
    if(-not $alive){
        $State.pendingRequestId=$null;$State.pendingHostIdentity=$null;$State.pendingStartedUtc=$null
        $State.attention='Background host exited before recording ownership. Review Diagnostics before trying again.'
        return $false
    }
    if(($NowUtc.ToUniversalTime()-([DateTime]$State.pendingStartedUtc).ToUniversalTime()).TotalSeconds -gt $RecordDeadlineSeconds){
        $State.attention='Background host has not recorded ownership within its startup deadline. Review Diagnostics.'
        return $false
    }
    return $true
}

function Clear-FastLlmUiBackgroundAttention {
    param([Parameter(Mandatory=$true)]$State)
    if($State.pendingRequestId -or ($State.observation -and $State.observation.occupied)){
        throw 'Background ownership remains unresolved; attention cannot be cleared.'
    }
    $State.attention=$null
    return $State
}

function Invoke-FastLlmUiBackgroundStop {
    param([Parameter(Mandatory=$true)]$State,[Parameter(Mandatory=$true)][scriptblock]$Stop)
    $status=Assert-FastLlmUiBackgroundObservation -Observation $State.observation
    if(-not $State.attachedRequestId -or -not $State.attachedRunId -or -not $status.active -or
       [string]$status.requestId -cne [string]$State.attachedRequestId -or
       [string]$status.runId -cne [string]$State.attachedRunId){
        throw 'The attached background request or run changed; stop was not sent.'
    }
    $result=& $Stop ([string]$State.attachedRequestId) ([string]$State.attachedRunId)
    if(-not $result -or $result.stopRequested -ne $true -or
       [string]$result.runId -cne [string]$State.attachedRunId){
        throw 'Background host did not confirm the exact stop request.'
    }
    return $result
}

function Get-FastLlmUiBackgroundText {
    param([Parameter(Mandatory=$true)]$State)
    if($State.attention){return [string]$State.attention}
    if($State.attachedRequestId){
        if($State.observation -and $State.observation.PSObject.Properties['uiHealthChecked'] -and
           $State.observation.uiHealthChecked -and $State.observation.PSObject.Properties['servingHealthy'] -and
           -not $State.observation.servingHealthy){
            return 'Attached background owner is verified, but API health failed. Review Diagnostics or use Stop.'
        }
        if(-not $State.observation.PSObject.Properties['uiHealthChecked'] -or -not $State.observation.uiHealthChecked){
            return 'Attached to verified background owner. Checking API health; use Stop to end this run.'
        }
        return 'Attached to Ready background inference. Closing this window detaches; use Stop to end serving.'
    }
    if($State.pendingRequestId){
        if($State.observation -and ($State.observation.attachable -or
            ($State.observation.PSObject.Properties['readyIdentityVerified'] -and $State.observation.readyIdentityVerified)) -and
           [string]$State.observation.requestId -ceq [string]$State.pendingRequestId){
            return 'Ready background identity observed. Choose Attach running to verify health and manage this exact run.'
        }
        return 'Background host is starting in this Windows user session. Waiting for its verified Ready state.'
    }
    if(-not $State.observation){return 'Checking background host ownership. Start is unavailable until the check completes.'}
    if($State.observation.occupied){
        if($State.observation.attachable -or
           ($State.observation.PSObject.Properties['readyIdentityVerified'] -and $State.observation.readyIdentityVerified)){
            return 'Ready background identity found. Choose Attach running to verify health and manage this run.'
        }
        return 'Background serving or an unverified operation occupies this installation. Review Diagnostics.'
    }
    if([string]$State.observation.phase -eq 'absent'){
        return 'Prepare with Install & start, then Stop. Background mode runs only while this Windows user is signed in.'
    }
    return 'No active background host. Review the previous host status before starting again.'
}

function Start-FastLlmUiBackgroundPoll {
    param([Parameter(Mandatory=$true)][string]$ScriptText,
          [Parameter(Mandatory=$true)][string]$SourceRoot,
          [Parameter(Mandatory=$true)][string]$InstallRoot,
          [string]$PendingRequestId,[string]$AttachedRequestId,[string]$AttachedRunId,
          [switch]$CheckHealth)
    $pipeline=[Management.Automation.PowerShell]::Create()
    try{
        $null=$pipeline.AddScript($ScriptText).AddArgument($SourceRoot).AddArgument($InstallRoot).AddArgument([bool]$CheckHealth)
        $handle=$pipeline.BeginInvoke()
        return [pscustomobject]@{
            pipeline=$pipeline;handle=$handle;sourceRoot=$SourceRoot;installRoot=$InstallRoot;
            pendingRequestId=$PendingRequestId;attachedRequestId=$AttachedRequestId;attachedRunId=$AttachedRunId
        }
    }catch{$pipeline.Dispose();throw}
}

function Complete-FastLlmUiBackgroundPoll {
    param([Parameter(Mandatory=$true)]$Poll,[Parameter(Mandatory=$true)][string]$SourceRoot,
          [Parameter(Mandatory=$true)][string]$InstallRoot,
          [string]$PendingRequestId,[string]$AttachedRequestId,[string]$AttachedRunId)
    if(-not $Poll.handle.IsCompleted){return [pscustomobject]@{completed=$false;discarded=$false;error=$null;observation=$null}}
    try{
        $values=@($Poll.pipeline.EndInvoke($Poll.handle))
        $sameContext=([string]$Poll.sourceRoot -ceq $SourceRoot -and
            [string]$Poll.installRoot -ceq $InstallRoot -and
            [string]$Poll.pendingRequestId -ceq [string]$PendingRequestId -and
            [string]$Poll.attachedRequestId -ceq [string]$AttachedRequestId -and
            [string]$Poll.attachedRunId -ceq [string]$AttachedRunId)
        if(-not $sameContext){return [pscustomobject]@{completed=$true;discarded=$true;error=$null;observation=$null}}
        if($Poll.pipeline.HadErrors -or $values.Count -ne 1){
            return [pscustomobject]@{completed=$true;discarded=$false;error='Background ownership check returned an invalid result.';observation=$null}
        }
        return [pscustomobject]@{completed=$true;discarded=$false;error=$null;observation=$values[0]}
    }catch{
        return [pscustomobject]@{completed=$true;discarded=$false;error='Background ownership check did not complete.';observation=$null}
    }finally{$Poll.pipeline.Dispose()}
}

function Close-FastLlmUiBackgroundPoll {
    param($Poll)
    if(-not $Poll){return}
    try{
        if(-not $Poll.handle.IsCompleted){$null=$Poll.pipeline.BeginStop($null,$null)}
    }catch{}
    try{$Poll.pipeline.Dispose()}catch{}
}
