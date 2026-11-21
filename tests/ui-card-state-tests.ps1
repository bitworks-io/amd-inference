#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'helpers/UiControlStatesMatrix.ps1')
$checks=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:checks++}

# A snapshot from named overrides; the base is everything off with background 'absent'.
function Snap([hashtable]$O=@{}){
    $d=@{Busy=$false;UpdateKind='';ChildActive=$false;Step='';RunReady=$false;SideChildActive=$false;VcBrokerActive=$false;PreviewReady=$false
        SwitchGap=$false;ChatUrlSet=$false;BackgroundStopRequested=$false;Background='absent';FlowPhase='';FailureHeld=$false}
    foreach($k in $O.Keys){$d[$k]=$O[$k]}
    $bg=$d.Background; if($bg -is [string]){$bg=Get-UiBackgroundFixture -Name $bg}
    return New-FastLlmUiStateSnapshot -Busy $d.Busy -UpdateKind $d.UpdateKind -ChildActive $d.ChildActive -Step $d.Step -RunReady $d.RunReady `
        -SideChildActive $d.SideChildActive -VcBrokerActive $d.VcBrokerActive -PreviewReady $d.PreviewReady -SwitchGap $d.SwitchGap `
        -ChatUrlSet $d.ChatUrlSet -BackgroundStopRequested $d.BackgroundStopRequested -Background $bg -FlowPhase $d.FlowPhase -FailureHeld $d.FailureHeld
}
function Expect([string]$Label,[hashtable]$O,[string]$State,[string]$Tone,[string]$Reason,[string]$Action){
    $c=Get-FastLlmUiCardState -Snapshot (Snap $O)
    $got="$($c.state)/$($c.tone)/$($c.reason)/$($c.mainAction)"
    Check ($got -ceq "$State/$Tone/$Reason/$Action") "$Label : got $got want $State/$Tone/$Reason/$Action"
    return $c
}
function StepStates($c){return (@($c.steps|ForEach-Object{$_.state}) -join ',')}

$c=Expect '1 base' @{} 'not-running' 'neutral' '' 'start'
Check ($null -eq $c.steps -and $c.stepsText -ceq '' -and $c.headline -ceq 'Not running') '1 no steps, headline'
[void](Expect '2 vc broker' @{VcBrokerActive=$true;ChildActive=$true;Step='serving';RunReady=$true} 'waiting-microsoft' 'caution' '' 'none')
[void](Expect '3 update' @{UpdateKind='update';RunReady=$true} 'updating' 'accent' '' 'none')
[void](Expect '3 reinstall' @{UpdateKind='reinstall';RunReady=$true} 'reinstalling' 'accent' '' 'none')
[void](Expect '4 stop requested' @{BackgroundStopRequested=$true;Background='ready-attached'} 'stopping' 'neutral' '' 'stop')
[void](Expect '5 switch gap' @{SwitchGap=$true;RunReady=$true} 'switching' 'accent' '' 'stop')
$c=Expect '6 model download' @{ChildActive=$true;Step='model download'} 'starting' 'accent' '' 'stop'
Check ($c.stepsText -ceq 'Step 3 of 4, Model, in progress' -and (StepStates $c) -ceq 'done,done,in progress,not started') '6 steps'
Check ((@($c.steps|ForEach-Object{$_.name}) -join ',') -ceq 'Check this PC,Engine,Model,Server') '6 step names'
$c=Expect '7 setup check' @{ChildActive=$true;Step='setup check'} 'starting' 'accent' '' 'stop'
Check ($c.stepsText -ceq 'Step 1 of 4, Check this PC, in progress') '7 text'
$c=Expect '8 component install' @{ChildActive=$true;Step='component install'} 'starting' 'accent' '' 'stop'
Check ($c.stepsText -ceq 'Step 2 of 4, Engine, in progress') '8 text'
$c=Expect '9 serving' @{ChildActive=$true;Step='serving'} 'starting' 'accent' '' 'stop'
Check ($c.stepsText -ceq 'Step 4 of 4, Server, in progress' -and (StepStates $c) -ceq 'done,done,done,in progress') '9 text'
$c=Expect '10 setup-attention' @{FlowPhase='setup-attention'} 'starting' 'accent' '' 'stop'
Check ($c.stepsText -ceq 'Step 1 of 4, Check this PC, needs attention' -and (StepStates $c) -ceq 'needs attention,not started,not started,not started') '10 text'
$c=Expect '11 consent' @{FlowPhase='consent'} 'starting' 'accent' '' 'stop'
Check ($c.stepsText -ceq 'Step 3 of 4, Model, in progress') '11 text'
$c=Expect '12 consent + failure' @{FlowPhase='consent';FailureHeld=$true} 'needs-attention' 'critical' 'failure' 'start'
Check ($null -eq $c.steps) '12 no steps'
[void](Expect '13 flow engine, no child' @{FlowPhase='engine'} 'not-running' 'neutral' '' 'start')
$c=Expect '14 starting-own' @{Background='starting-own'} 'starting' 'accent' '' 'stop'
Check ($null -eq $c.steps -and $c.stepsText -ceq '') '14 no steps'
[void](Expect '15 unverified' @{Background='unverified'} 'needs-attention' 'caution' 'unverified' 'start')
[void](Expect '16 attention-only' @{Background='attention-only'} 'needs-attention' 'caution' 'attention' 'start')
[void](Expect '17 unhealthy' @{Background='ready-attached-unhealthy'} 'needs-attention' 'critical' 'health-failed' 'start')
[void](Expect '18 occupied-idle' @{Background='occupied-idle'} 'needs-attention' 'caution' 'occupied' 'start')
[void](Expect '19 ready-attached' @{Background='ready-attached'} 'running-background' 'success' '' 'stop')
[void](Expect '20 running' @{ChildActive=$true;Step='serving';RunReady=$true} 'running' 'success' '' 'stop')
[void](Expect '21 running + side child' @{RunReady=$true;SideChildActive=$true} 'running' 'success' '' 'stop')
[void](Expect '22 diagnostics child' @{ChildActive=$true;Step='diagnostics'} 'working' 'accent' '' 'stop')
[void](Expect '23 side child only' @{SideChildActive=$true} 'working' 'accent' '' 'start')
[void](Expect '24 failure only' @{FailureHeld=$true} 'needs-attention' 'critical' 'failure' 'start')
[void](Expect '25 ready-attachable' @{Background='ready-attachable'} 'background-found' 'neutral' '' 'attach')
[void](Expect '26 starting-other' @{Background='starting-other'} 'starting' 'accent' '' 'stop')
[void](Expect '26 starting-case' @{Background='starting-case'} 'starting' 'accent' '' 'stop')
$c=Expect '27 bare-ready' @{Background='bare-ready'} 'background-found' 'neutral' '' 'attach'

# Every state's headline.
$headlines=@{'not-running'='Not running';'starting'='Starting';'running'='Running';'running-background'='Running in background';'background-found'='Background run found'
    'needs-attention'='Needs attention';'switching'='Switching models';'stopping'='Stopping';'working'='Working';'waiting-microsoft'='Waiting for Microsoft setup'
    'updating'='Updating';'reinstalling'='Reinstalling'}
$seenStates=@{}

# Honest colour: success only when the run is really up, across the whole matrix and every flow phase.
$successRows=0
$matrix=@(Get-UiControlStatesMatrix)
foreach($r in $matrix){
    foreach($phase in @('','setup-attention','consent')){
        foreach($held in @($false,$true)){
            $snap=New-FastLlmUiStateSnapshot -Busy ([bool]$r.busy) -UpdateKind ([string]$r.updateKind) -ChildActive ([bool]$r.child) -Step ([string]$r.step) `
                -RunReady ([bool]$r.runReady) -SideChildActive ([bool]$r.sideChild) -VcBrokerActive ($null -ne $r.vcBroker) -PreviewReady ([bool]$r.previewReady) `
                -SwitchGap ([bool]$r.switchGap) -ChatUrlSet ([bool]$r.chatUrl) -BackgroundStopRequested ([bool]$r.bgStopRequested) `
                -Background (Get-UiBackgroundFixture -Name $r.background) -FlowPhase $phase -FailureHeld $held
            $card=Get-FastLlmUiCardState -Snapshot $snap
            $seenStates[$card.state]=$true
            if($card.headline -cne $headlines[$card.state]){throw "FAIL: headline for $($card.state) is '$($card.headline)'"}
            if($card.tone -ceq 'success'){
                $successRows++
                $bg=$snap.Background
                $obs=$bg.observation
                $why="$($r.key) phase='$phase' held=$held -> $($card.state)"
                if($card.state -cne 'running' -and $card.state -cne 'running-background'){throw "FAIL: success on $why"}
                if($card.state -ceq 'running' -and -not $snap.RunReady){throw "FAIL: running without RunReady on $why"}
                if($card.state -ceq 'running-background' -and -not ($bg.attachedRequestId -and (Get-FastLlmUiStateProperty $obs 'uiHealthChecked') -and (Get-FastLlmUiStateProperty $obs 'attachable'))){throw "FAIL: running-background without attach+health on $why"}
                if($snap.VcBrokerActive -or $snap.UpdateKind -or $snap.BackgroundStopRequested -or $snap.SwitchGap){throw "FAIL: success while busy-with-other on $why"}
            }
        }
    }
}
Check ($successRows -gt 0) 'the honest-colour property saw success rows'
# The matrix has no reinstall rows; that state is covered by case 3.
foreach($s in @($headlines.Keys|Where-Object{$_ -cne 'reinstalling'})){Check ($seenStates.ContainsKey($s)) "the matrix reaches state $s"}
Write-Host "honest-colour success rows: $successRows"

Write-Host "UI card state tests passed: $checks"
exit 0
