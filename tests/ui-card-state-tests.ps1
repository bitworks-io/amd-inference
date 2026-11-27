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
$c=Expect '3 reinstall' @{UpdateKind='reinstall';RunReady=$true} 'reinstalling' 'accent' '' 'none'
Check ($c.headline -ceq 'Reinstalling') '3 reinstall headline'
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

# The attach-ready rule (the canary's "Starting" card that never offered Attach): a pending start whose Ready identity is observed is a background run to attach.
$r1=$script:UiMatrixR1;$r2=$script:UiMatrixR2
function New-AttachBg([bool]$Pending,[bool]$Attachable,[bool]$Verified,[bool]$Match,[bool]$Attached,[bool]$Attention,[string]$Phase='',[bool]$Active=$true){
    $bg=New-FastLlmUiBackgroundState
    $ready=[bool]($Attachable -or $Verified)
    if(-not $Phase){$Phase=$(if($ready){'ready'}else{'starting'})}
    $obs=[pscustomobject]@{phase=$Phase;active=$Active;attachable=$Attachable;occupied=$true;requestId=$r1
        runId=$script:UiMatrixRun;hostIdentity=@{pid=4242;startUtcTicks=1}}
    if($Verified){$obs|Add-Member -NotePropertyName readyIdentityVerified -NotePropertyValue $true}
    $bg.observation=$obs
    if($Pending){$bg.pendingRequestId=$(if($Match){$r1}else{$r2})}
    if($Attached){$bg.attachedRequestId=$r1}
    if($Attention){$bg.attention='x'}
    return $bg
}
$c=Expect '28 canary: pending start, Ready + attachable, same request' @{Background=(New-AttachBg $true $true $true $true $false $false)} 'background-found' 'neutral' '' 'attach'
Check ($c.headline -ceq 'Background run found') '28 canary headline'
$c=Expect '29 canary without the identity flag' @{Background=(New-AttachBg $true $true $false $true $false $false)} 'background-found' 'neutral' '' 'attach'
$c=Expect '30 verified-only (attachable false), same request' @{Background=(New-AttachBg $true $false $true $true $false $false)} 'background-found' 'neutral' '' 'attach'
Check ($c.headline -ceq 'Background run found') '30 verified-only headline'
[void](Expect '31 verified-only, nothing pending' @{Background=(New-AttachBg $false $false $true $true $false $false)} 'background-found' 'neutral' '' 'attach')
[void](Expect '32 mismatched request id stays starting' @{Background=(New-AttachBg $true $true $true $false $false $false)} 'starting' 'accent' '' 'stop')
[void](Expect '33 pending start not yet observed Ready stays starting' @{Background=(New-AttachBg $true $false $false $true $false $false)} 'starting' 'accent' '' 'stop')
$bgAtt=New-AttachBg $false $true $true $true $true $false
$bgAtt.observation|Add-Member -NotePropertyName uiHealthChecked -NotePropertyValue $true
$bgAtt.observation|Add-Member -NotePropertyName servingHealthy -NotePropertyValue $true
[void](Expect '34 attached and health checked stays running-background' @{Background=$bgAtt} 'running-background' 'success' '' 'stop')
[void](Expect '35 attached, health not yet checked is not offered Attach' @{Background=(New-AttachBg $false $true $true $true $true $false)} 'not-running' 'neutral' '' 'start')
# RunReady is what the window really computes: Test-FastLlmUiServingReady over the run status and the background observation (an ACTIVE background run
# whose status says ready is ready, attached or not). The #110 rows above left it false; the lab canary .2 card showed Running with Stop greyed and no Attach.
function Get-RealRunReady($Bg,[string]$StatusPhase){ return [bool](Test-FastLlmUiServingReady -Status ([pscustomobject]@{active=$true;phase=$StatusPhase}) -ForegroundChildActive $false -BackgroundObservation $Bg.observation) }
foreach($obsPhase in 'loading','ready'){
    $bgC2=New-AttachBg $true $true $true $true $false $false $obsPhase $true
    $rrC2=Get-RealRunReady $bgC2 'ready'
    Check $rrC2 "36 canary .2 ($obsPhase): the real RunReady is true for the active background host whose status says ready"
    $c=Expect "36 canary .2 ($obsPhase): pending start Ready, RunReady true, not attached" @{Background=$bgC2;RunReady=$rrC2} 'background-found' 'neutral' '' 'attach'
    Check ($c.headline -ceq 'Background run found') "36 canary .2 ($obsPhase) headline"
}
$bgAtt2=New-AttachBg $false $true $true $true $true $false 'ready' $true
$bgAtt2.observation|Add-Member -NotePropertyName uiHealthChecked -NotePropertyValue $true
$bgAtt2.observation|Add-Member -NotePropertyName servingHealthy -NotePropertyValue $true
$snapAtt2=Snap @{Background=$bgAtt2;RunReady=(Get-RealRunReady $bgAtt2 'ready')}
$c=Get-FastLlmUiCardState -Snapshot $snapAtt2
Check ($c.state -ceq 'running-background' -and $c.mainAction -ceq 'stop' -and [bool](Get-FastLlmUiControlStates -Snapshot $snapAtt2).stop) '37 attached, health checked, RunReady true: Running in background with Stop, and the Stop control is enabled'

# Parity: over background snapshots the card offers Attach only when the Attach control is enabled, and (without an attention note, which the card shows first) whenever it is.
$parityRows=0;$parityAttach=0;$parityExcused=0
foreach($pending in $false,$true){foreach($att in $false,$true){foreach($ver in $false,$true){foreach($match in $true,$false){foreach($attached in $false,$true){foreach($attn in $false,$true){foreach($obsPhase in 'ready','loading','starting'){foreach($obsActive in $true,$false){foreach($statusPhase in 'ready','loading'){
    if(-not $pending -and -not $match){continue}
    $pbg=New-AttachBg $pending $att $ver $match $attached $attn $obsPhase $obsActive
    $prr=Get-RealRunReady $pbg $statusPhase
    $snap=Snap @{Background=$pbg;RunReady=$prr}
    $card=Get-FastLlmUiCardState -Snapshot $snap
    $ctl=[bool](Get-FastLlmUiControlStates -Snapshot $snap).backgroundAttach
    $why="pending=$pending attachable=$att verified=$ver match=$match attached=$attached attention=$attn phase=$obsPhase active=$obsActive status=$statusPhase runReady=$prr card=$($card.state)/$($card.mainAction) control=$ctl"
    $parityRows++
    if($card.mainAction -ceq 'attach'){$parityAttach++;Check $ctl "parity: the card offers Attach only when the control is enabled ($why)"}
    # A Needs-attention row (an attention note, an occupied run that is not active) is shown before Attach (lead ruling); only there may an enabled control go unoffered.
    if($ctl -and $card.state -ceq 'needs-attention'){$parityExcused++}
    if($ctl -and -not $attn -and $card.state -cne 'needs-attention'){Check ($card.mainAction -ceq 'attach') "parity: an enabled Attach control is offered on the card ($why)"}
}}}}}}}}}
Check ($parityRows -ge 500 -and $parityAttach -gt 0) "the parity matrix ran ($parityRows rows, $parityAttach with Attach, $parityExcused enabled-but-Needs-attention)"
Check ((Get-RealRunReady (New-AttachBg $true $true $true $true $false $false 'ready' $true) 'ready') -and -not (Get-RealRunReady (New-AttachBg $true $true $true $true $false $false 'ready' $false) 'ready')) 'the parity matrix covers RunReady true and false (the real computation varies with the observation)'
# The helper's two expressions are copies of the control-state ones.
$uiStateAst=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'src/FastLlm.UiState.ps1'),[ref]$null,[ref]$null)
function Get-UiStateExpression([string]$Function,[string]$Variable){
    $fn=@($uiStateAst.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Function},$true))
    if($fn.Count -ne 1){throw "FAIL: function $Function not found once"}
    $as=@($fn[0].FindAll({param($n)$n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq ('$'+$Variable)},$true))
    if($as.Count -ne 1){throw "FAIL: $Function does not assign `$$Variable exactly once"}
    return ([regex]::Replace($as[0].Right.Extent.Text,'\s+',' ')).Trim()
}
foreach($v in 'attachable','requestMatches'){
    $a=Get-UiStateExpression 'Get-FastLlmUiControlStates' $v
    $b=Get-UiStateExpression 'Test-FastLlmUiBackgroundAttachReady' $v
    Check ($a.Length -gt 20 -and $a -ceq $b) "the attach-ready helper $v expression is text-identical to the control-state one"
}
Check ((Get-Command Get-FastLlmUiCardState -CommandType Function).ScriptBlock.ToString().Contains('Test-FastLlmUiBackgroundAttachReady')) 'the card state uses the attach-ready helper'
# Mutants on a scratch copy of the card function: each must fail its probe.
function Test-CardMutant([string]$From,[string]$To,[scriptblock]$Probe){
    $text=(Get-Command Get-FastLlmUiCardState -CommandType Function).ScriptBlock.ToString()
    if(-not $text.Contains($From)){throw "FAIL: mutation anchor missing: $From"}
    Set-Item -Path function:script:Get-CardMutant -Value ([scriptblock]::Create($text.Replace($From,$To)))
    return [bool](& $Probe)
}
$canarySnap=Snap @{Background=(New-AttachBg $true $true $true $true $false $false)}
$verifiedSnap=Snap @{Background=(New-AttachBg $false $false $true $true $false $false)}
$canaryProbe={$x=Get-CardMutant -Snapshot $canarySnap;$x.state -ceq 'background-found' -and $x.mainAction -ceq 'attach'}
$verifiedProbe={$x=Get-CardMutant -Snapshot $verifiedSnap;$x.state -ceq 'background-found' -and $x.mainAction -ceq 'attach'}
Check (Test-CardMutant 'elseif ($attachReady) {' 'elseif ($attachReady) {' $canaryProbe) 'control: an unchanged card copy passes the canary probe through the mutation path'
Check (Test-CardMutant 'elseif ($attachReady) {' 'elseif ($attachReady) {' $verifiedProbe) 'control: an unchanged card copy passes the verified-only probe through the mutation path'
Check (-not (Test-CardMutant '-not $attachReady -and ((' '$true -and ((' $canaryProbe)) 'mutation: the old row 5 (a pending start wins over attach-ready) fails the canary probe'
Check (-not (Test-CardMutant 'elseif ($attachReady) {' 'elseif ($attachable -and -not $attached) {' $verifiedProbe)) 'mutation: the old row 10 (observation.attachable only) fails the verified-only probe'
$bgC2m=New-AttachBg $true $true $true $true $false $false 'loading' $true
$canary2Snap=Snap @{Background=$bgC2m;RunReady=(Get-RealRunReady $bgC2m 'ready')}
$canary2Probe={$x=Get-CardMutant -Snapshot $canary2Snap;$x.state -ceq 'background-found' -and $x.mainAction -ceq 'attach'}
Check (Test-CardMutant 'elseif ($Snapshot.RunReady -and -not $attachReady) {' 'elseif ($Snapshot.RunReady -and -not $attachReady) {' $canary2Probe) 'control: an unchanged card copy passes the canary .2 probe through the mutation path'
Check (-not (Test-CardMutant 'elseif ($Snapshot.RunReady -and -not $attachReady) {' 'elseif ($Snapshot.RunReady) {' $canary2Probe)) 'mutation: the old row 7 (serving wins over attach-ready) fails the canary .2 probe'

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
