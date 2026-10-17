$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
. (Join-Path $PSScriptRoot '../src/FastLlm.UiBackground.ps1')
$passes=0
function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:passes++}
function Assert-Throws([scriptblock]$Action,[string]$Message){
    $caught=$false
    try{& $Action}catch{$caught=$true}
    Assert-True $caught $Message
}
function Wait-PollForTest($Poll) {
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    while(-not $Poll.handle.IsCompleted){
        if([DateTime]::UtcNow -ge $deadline){
            Close-FastLlmUiBackgroundPoll $Poll
            throw 'Asynchronous background poll test exceeded its ten-second deadline.'
        }
        Start-Sleep -Milliseconds 10
    }
}
$requestId='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$runId='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
$hostIdentity=[pscustomobject]@{pid=2468;startUtcTicks=123456789L}
$absent=[pscustomobject]@{phase='absent';active=$false;attachable=$false;occupied=$false}
$ready=[pscustomobject]@{phase='ready';active=$true;attachable=$true;occupied=$true;
    requestId=$requestId;runId=$runId;hostIdentity=$hostIdentity;readyIdentityVerified=$true}
$lightReady=[pscustomobject]@{phase='ready';active=$true;attachable=$false;occupied=$true;
    requestId=$requestId;runId=$runId;hostIdentity=$hostIdentity;readyIdentityVerified=$true}
$state=New-FastLlmUiBackgroundState
Assert-True (-not (Test-FastLlmUiBackgroundMayStart $state)) 'Start must await a real ownership observation.'
$null=Set-FastLlmUiBackgroundObservation $state $absent
Assert-True (Test-FastLlmUiBackgroundMayStart $state) 'Verified absence should allow opt-in start.'
$script:startCalls=0
$started=Invoke-FastLlmUiBackgroundStart -State $state -Request ([pscustomobject]@{modelId='qwen3.8-27b-ud-q4-k-m'}) -Start {
    param($Request)
    $script:startCalls++
    if($Request.modelId -cne 'qwen3.8-27b-ud-q4-k-m'){throw 'Selection changed.'}
    [pscustomobject]@{phase='starting';requestId=$requestId;hostIdentity=$hostIdentity;active=$false;attachable=$false}
}
Assert-True ($started.requestId -ceq $requestId -and $state.pendingRequestId -ceq $requestId) 'Start must retain exact request ID.'
Assert-Throws {Invoke-FastLlmUiBackgroundStart -State $state -Request @{} -Start {$script:startCalls++}} 'Duplicate start must be blocked while pending.'
Assert-True ($script:startCalls -eq 1) 'Duplicate start invoked the core.'
$null=Set-FastLlmUiBackgroundObservation $state $absent
Assert-True (-not (Test-FastLlmUiBackgroundMayStart $state)) 'An absent status race must not erase pending ownership.'
Assert-True (Test-FastLlmUiBackgroundPendingHost -State $state -TestProcess {param($Identity) $Identity.pid -eq 2468}) 'Live pending host should keep its request.'
$expired=New-FastLlmUiBackgroundState
$null=Set-FastLlmUiBackgroundObservation $expired $absent
$null=Invoke-FastLlmUiBackgroundStart -State $expired -Request @{} -Start {[pscustomobject]@{phase='starting';requestId=$requestId;hostIdentity=$hostIdentity}}
$expired.pendingStartedUtc=[DateTime]::UtcNow.AddSeconds(-40)
Assert-True (-not (Test-FastLlmUiBackgroundPendingHost -State $expired -TestProcess {$true} -RecordDeadlineSeconds 30)) 'Unrecorded owner should reach attention deadline.'
Assert-True (-not (Test-FastLlmUiBackgroundMayStart $expired)) 'Unrecorded live owner must block duplicate start.'
$dead=New-FastLlmUiBackgroundState
$null=Set-FastLlmUiBackgroundObservation $dead $absent
$null=Invoke-FastLlmUiBackgroundStart -State $dead -Request @{} -Start {[pscustomobject]@{phase='starting';requestId=$requestId;hostIdentity=$hostIdentity}}
Assert-True (-not (Test-FastLlmUiBackgroundPendingHost -State $dead -TestProcess {$false})) 'Dead owner before sidecar must report attention.'
Assert-True (-not $dead.pendingRequestId -and -not (Test-FastLlmUiBackgroundMayStart $dead)) 'Dead owner attention must require an explicit recheck.'
$null=Clear-FastLlmUiBackgroundAttention $dead
Assert-True (Test-FastLlmUiBackgroundMayStart $dead) 'Explicit recheck after verified absence should allow a fresh manual action.'
$null=Set-FastLlmUiBackgroundObservation $state $ready
$script:attachCalls=0
$attached=Invoke-FastLlmUiBackgroundAttach -State $state -Attach {
    param($ExpectedRequestId)
    $script:attachCalls++
    if($ExpectedRequestId -cne $requestId){throw 'Wrong attach request.'}
    $ready
}
Assert-True ($attached.runId -ceq $runId -and $state.attachedRunId -ceq $runId -and $script:attachCalls -eq 1) 'Attach must pin request and run.'
$script:stopCalls=0
$stopped=Invoke-FastLlmUiBackgroundStop -State $state -Stop {
    param($ExpectedRequestId,$ExpectedRunId)
    $script:stopCalls++
    if($ExpectedRequestId -cne $requestId -or $ExpectedRunId -cne $runId){throw 'Wrong stop correlation.'}
    [pscustomobject]@{stopRequested=$true;runId=$ExpectedRunId}
}
Assert-True ($stopped.stopRequested -and $script:stopCalls -eq 1) 'Stop must send exact request/run once.'
$wrong=[pscustomobject]@{phase='ready';active=$true;attachable=$true;occupied=$true;
    requestId='cccccccccccccccccccccccccccccccc';runId='dddddddddddddddddddddddddddddddd';hostIdentity=$hostIdentity}
$null=Set-FastLlmUiBackgroundObservation $state $wrong
Assert-True (-not $state.attachedRequestId -and [bool]$state.attention) 'Changed run must detach and show attention.'
Assert-Throws {Invoke-FastLlmUiBackgroundStop -State $state -Stop {$script:stopCalls++}} 'Stale attachment must not send stop.'
Assert-True ($script:stopCalls -eq 1) 'Stale attachment sent stop.'
$occupied=[pscustomobject]@{phase='occupied-unverified';active=$false;attachable=$false;occupied=$true}
$fresh=New-FastLlmUiBackgroundState
$null=Set-FastLlmUiBackgroundObservation $fresh $occupied
Assert-True (-not (Test-FastLlmUiBackgroundMayStart $fresh)) 'Unverified occupied state must block start.'
Assert-True ((Get-FastLlmUiBackgroundText $fresh) -notmatch 'Stopped') 'Occupied state must not claim stopped.'
$reopened=New-FastLlmUiBackgroundState
$null=Set-FastLlmUiBackgroundObservation $reopened $lightReady
$null=Invoke-FastLlmUiBackgroundAttach -State $reopened -Attach {param($ExpectedRequestId) if($ExpectedRequestId -cne $requestId){throw 'Wrong request.'};$ready}
Assert-True ($reopened.attachedRequestId -ceq $requestId) 'Reopened window must attach by verified request ID.'
Assert-Throws {Assert-FastLlmUiBackgroundObservation ([pscustomobject]@{phase='ready';active=$true;attachable=$true;occupied=$false;requestId=$requestId;runId=$runId;hostIdentity=$hostIdentity})} 'Impossible Ready state must fail.'
Assert-Throws {Assert-FastLlmUiBackgroundObservation ([pscustomobject]@{phase='ready';active=$true;attachable=$true;occupied=$true;requestId='bad';runId=$runId;hostIdentity=$hostIdentity})} 'Bad request ID must fail.'
$pollScript='param($source,$install,$checkHealth) [pscustomobject]@{phase=$source;install=$install;checkHealth=$checkHealth}'
$poll=Start-FastLlmUiBackgroundPoll -ScriptText $pollScript -SourceRoot 'source-a' -InstallRoot 'install-a' `
    -PendingRequestId $requestId -CheckHealth
Wait-PollForTest $poll
$pollResult=Complete-FastLlmUiBackgroundPoll -Poll $poll -SourceRoot 'source-a' -InstallRoot 'install-a' `
    -PendingRequestId $requestId
Assert-True ($pollResult.completed -and $null -eq $pollResult.error -and
    $pollResult.observation.phase -ceq 'source-a' -and $pollResult.observation.install -ceq 'install-a' -and
    $pollResult.observation.checkHealth) `
    'Asynchronous poll must return its exact source and install observation.'
$unhealthy=[pscustomobject]@{phase='ready';active=$true;attachable=$false;occupied=$true;
    requestId=$requestId;runId=$runId;hostIdentity=$hostIdentity;readyIdentityVerified=$true;
    servingHealthy=$false;uiHealthChecked=$true}
$healthState=New-FastLlmUiBackgroundState
$null=Set-FastLlmUiBackgroundObservation $healthState $ready
$healthState.attachedRequestId=$requestId;$healthState.attachedRunId=$runId
$null=Set-FastLlmUiBackgroundObservation $healthState $unhealthy
Assert-True ((Get-FastLlmUiBackgroundText $healthState) -match 'health failed') `
    'Attached owner with failed full health must not display Ready serving.'
$stalePoll=Start-FastLlmUiBackgroundPoll -ScriptText $pollScript -SourceRoot 'source-a' -InstallRoot 'install-a' `
    -PendingRequestId $requestId
Wait-PollForTest $stalePoll
$staleResult=Complete-FastLlmUiBackgroundPoll -Poll $stalePoll -SourceRoot 'source-a' -InstallRoot 'install-b' `
    -PendingRequestId $requestId
Assert-True ($staleResult.completed -and $staleResult.discarded -and $null -eq $staleResult.observation) `
    'Poll completion must discard an observation after the install path changes.'
$changedRequest=Start-FastLlmUiBackgroundPoll -ScriptText $pollScript -SourceRoot 'source-a' -InstallRoot 'install-a' `
    -PendingRequestId $requestId
Wait-PollForTest $changedRequest
$changedResult=Complete-FastLlmUiBackgroundPoll -Poll $changedRequest -SourceRoot 'source-a' -InstallRoot 'install-a' `
    -PendingRequestId 'cccccccccccccccccccccccccccccccc'
Assert-True ($changedResult.completed -and $changedResult.discarded) `
    'Poll completion must discard an observation after request ownership changes.'
$badPoll=Start-FastLlmUiBackgroundPoll -ScriptText 'throw "failed"' -SourceRoot 'source-a' -InstallRoot 'install-a'
Wait-PollForTest $badPoll
$badResult=Complete-FastLlmUiBackgroundPoll -Poll $badPoll -SourceRoot 'source-a' -InstallRoot 'install-a'
Assert-True ($badResult.completed -and [bool]$badResult.error) 'Poll failures must not masquerade as verified absence.'
# An end that follows the user's own Stop is an expected end; any other end keeps the cautious wording.
$stoppedObs=[pscustomobject]@{phase='stopped';active=$false;attachable=$false;occupied=$false}
$afterStop=New-FastLlmUiBackgroundState
$afterStop.attachedRequestId=$requestId;$afterStop.attachedRunId=$runId
$null=Set-FastLlmUiBackgroundObservation $afterStop $stoppedObs -StopRequested
Assert-True (-not $afterStop.attachedRequestId -and -not $afterStop.attention) 'A run that ended after the user Stop clears the attachment without raising attention.'
Assert-True ((Get-FastLlmUiBackgroundText -State $afterStop -StopRequested) -ceq 'Stopped. The background run ended.') 'A run that ended after the user Stop reads as stopped.'
$noStop=New-FastLlmUiBackgroundState
$noStop.attachedRequestId=$requestId;$noStop.attachedRunId=$runId
$null=Set-FastLlmUiBackgroundObservation $noStop $stoppedObs
Assert-True ($noStop.attention -ceq 'The attached background run changed or ended. Review its status.') 'A run that ends without a user Stop keeps the cautious wording.'
Assert-True ((Get-FastLlmUiBackgroundText -State $noStop) -ceq 'The attached background run changed or ended. Review its status.') 'The cautious text is unchanged without a user Stop.'
$noStopFallback=New-FastLlmUiBackgroundState
$null=Set-FastLlmUiBackgroundObservation $noStopFallback $stoppedObs
Assert-True ((Get-FastLlmUiBackgroundText -State $noStopFallback) -ceq 'No active background host. Review the previous host status before starting again.') 'The fallback text is unchanged without a user Stop.'
$otherRun=New-FastLlmUiBackgroundState
$otherRun.attachedRequestId=$requestId;$otherRun.attachedRunId='cccccccccccccccccccccccccccccccc'
$null=Set-FastLlmUiBackgroundObservation $otherRun $ready -StopRequested
Assert-True ($otherRun.attention -ceq 'The attached background run changed or ended. Review its status.') 'A different run that is still active is not reported as the stopped run.'
$stickyState=New-FastLlmUiBackgroundState
$null=Set-FastLlmUiBackgroundObservation $stickyState $stoppedObs
Assert-True ((Get-FastLlmUiBackgroundText -State $stickyState -StopRequested) -ceq 'Stopped. The background run ended.') 'An inactive, unoccupied, non-absent observation reads as stopped with the switch.'
Assert-True ((Get-FastLlmUiBackgroundText -State $stickyState) -ceq 'No active background host. Review the previous host status before starting again.') 'The same observation keeps the cautious text without the switch.'
$stoppedId='dddddddddddddddddddddddddddddddd'
$deadObs=[pscustomobject]@{phase='stale';active=$false;attachable=$false;occupied=$false;requestId=$stoppedId}
$reopened=New-FastLlmUiBackgroundState
$null=Set-FastLlmUiBackgroundObservation $reopened $deadObs
$neutral='No background run. Start in background to start one.'
$cautious='No active background host. Review the previous host status before starting again.'
Assert-True ((Get-FastLlmUiBackgroundText -State $reopened -LastUserStoppedRequestId $stoppedId) -ceq $neutral) 'A host record matching the last user-stopped request reads as no background run.'
# A host that ended with no Stop and no recorded failure (for example a sign-out) reads as a plain end, not something to review.
$signedOut='The last background run ended without Stop (for example when you signed out). Start in background to start a new one.'
Assert-True ((Get-FastLlmUiBackgroundText -State $reopened -LastUserStoppedRequestId 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee') -ceq $signedOut) 'A dead host with no failure code and a different request reads as ended without Stop.'
Assert-True ((Get-FastLlmUiBackgroundText -State $reopened -LastUserStoppedRequestId '') -ceq $signedOut -and (Get-FastLlmUiBackgroundText -State $reopened) -ceq $signedOut) 'No saved stop reads as ended without Stop for a clean dead host.'
$cleanEmpty=[pscustomobject]@{phase='stale';active=$false;attachable=$false;occupied=$false;requestId=$stoppedId;failureCode='';failureReason=$null}
$cleanState=New-FastLlmUiBackgroundState
$null=Set-FastLlmUiBackgroundObservation $cleanState $cleanEmpty
Assert-True ((Get-FastLlmUiBackgroundText -State $cleanState) -ceq $signedOut) 'Empty failure fields count as no recorded failure.'
foreach($recorded in @(@{failureCode='host-exited'},@{failureReason='something happened'})){
    $withFailure=[pscustomobject]@{phase='stale';active=$false;attachable=$false;occupied=$false;requestId=$stoppedId}
    foreach($key in $recorded.Keys){$withFailure|Add-Member -NotePropertyName $key -NotePropertyValue $recorded[$key]}
    $failState=New-FastLlmUiBackgroundState
    $null=Set-FastLlmUiBackgroundObservation $failState $withFailure
    Assert-True ((Get-FastLlmUiBackgroundText -State $failState) -ceq $cautious) 'A recorded failure code or reason keeps the cautious text.'
}
$noId=New-FastLlmUiBackgroundState
$null=Set-FastLlmUiBackgroundObservation $noId $stoppedObs
Assert-True ((Get-FastLlmUiBackgroundText -State $noId -LastUserStoppedRequestId $stoppedId) -ceq $cautious) 'An observation without a request id keeps the cautious text.'
Assert-True ((Get-FastLlmUiBackgroundText -State $reopened -StopRequested -LastUserStoppedRequestId 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee') -ceq 'Stopped. The background run ended.') 'The in-session stop wording still wins.'
# After a sign-out: a stale record of an older request must not read as another owner while the new request is pending.
$oldId='ffffffffffffffffffffffffffffffff'
$staleOld=[pscustomobject]@{phase='stale';active=$false;attachable=$false;occupied=$false;requestId=$oldId;failureCode='';failureReason=$null;hostIdentity=[pscustomobject]@{pid=111;startUtcTicks=5L}}
$afterSignOut=New-FastLlmUiBackgroundState
$null=Set-FastLlmUiBackgroundObservation $afterSignOut $absent
$null=Invoke-FastLlmUiBackgroundStart -State $afterSignOut -Request @{} -Start {[pscustomobject]@{phase='starting';requestId=$requestId;hostIdentity=$hostIdentity}}
$null=Set-FastLlmUiBackgroundObservation $afterSignOut $staleOld
Assert-True (-not $afterSignOut.attention -and $afterSignOut.pendingRequestId -ceq $requestId) 'A stale record of an older request keeps waiting for the pending request.'
Assert-True ((Get-FastLlmUiBackgroundText -State $afterSignOut) -ceq 'Background host is starting in this Windows user session. Waiting for its verified Ready state.') 'The window keeps saying the new host is starting.'
$null=Set-FastLlmUiBackgroundObservation $afterSignOut $lightReady
Assert-True (-not $afterSignOut.attention -and (Get-FastLlmUiBackgroundText -State $afterSignOut) -like 'Ready background identity observed*') 'When the new record arrives the ready path is unchanged.'
$liveOther=[pscustomobject]@{phase='loading';active=$true;attachable=$false;occupied=$true;requestId=$oldId;runId=$runId;hostIdentity=[pscustomobject]@{pid=222;startUtcTicks=6L}}
$otherOwner=New-FastLlmUiBackgroundState
$null=Set-FastLlmUiBackgroundObservation $otherOwner $absent
$null=Invoke-FastLlmUiBackgroundStart -State $otherOwner -Request @{} -Start {[pscustomobject]@{phase='starting';requestId=$requestId;hostIdentity=$hostIdentity}}
$null=Set-FastLlmUiBackgroundObservation $otherOwner $liveOther
Assert-True ($otherOwner.attention -ceq 'Another background request now owns this installation. Review Diagnostics.') 'A live other owner still raises the attention.'
$occupiedOther=[pscustomobject]@{phase='occupied-unverified';active=$false;attachable=$false;occupied=$true;requestId=$oldId;hostIdentity=[pscustomobject]@{pid=333;startUtcTicks=7L}}
$otherOccupied=New-FastLlmUiBackgroundState
$null=Set-FastLlmUiBackgroundObservation $otherOccupied $absent
$null=Invoke-FastLlmUiBackgroundStart -State $otherOccupied -Request @{} -Start {[pscustomobject]@{phase='starting';requestId=$requestId;hostIdentity=$hostIdentity}}
$null=Set-FastLlmUiBackgroundObservation $otherOccupied $occupiedOther
Assert-True ($otherOccupied.attention -ceq 'Another background request now owns this installation. Review Diagnostics.') 'An occupying other owner still raises the attention.'
"UI background operational coordination checks passed: $passes"
