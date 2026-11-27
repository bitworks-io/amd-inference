#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'helpers/UiControlStatesMatrix.ps1')
$checks=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:checks++}

# The golden, generated once from the released window (fast-llm-ui.ps1 at 646ccb05).
$golden=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/ui-control-states-golden.json') -Raw|ConvertFrom-Json
$goldenRows=@{};foreach($p in $golden.rows.PSObject.Properties){$goldenRows[$p.Name]=[string]$p.Value}
$goldenTray=@{};foreach($p in $golden.tray.PSObject.Properties){$goldenTray[$p.Name]=[string]$p.Value}
Check ($golden.schema -ceq 'fastllm.ui-control-states-golden/v1') 'the golden has the expected schema'
Check ($golden.source -ceq 'fast-llm-ui.ps1@646ccb05') 'the golden was generated from the released window'
Check ((@($golden.columns) -join ',') -ceq ((Get-UiControlStatesColumns) -join ',')) 'golden columns are the 19 window actions in order'
$matrix=@(Get-UiControlStatesMatrix)
$matrixKeys=@($matrix|ForEach-Object{$_.key})
Check ($matrixKeys.Count -eq 2230 -and @($matrixKeys|Select-Object -Unique).Count -eq 2230) 'the matrix has 2,230 unique rows'
Check ($goldenRows.Count -eq 2230 -and @($matrixKeys|Where-Object{-not $goldenRows.ContainsKey($_)}).Count -eq 0) 'the matrix and the golden cover the same 2,230 rows'
$trayMatrix=@(Get-UiTrayMatrix)
Check ($trayMatrix.Count -eq 12 -and $goldenTray.Count -eq 12 -and @($trayMatrix|Where-Object{-not $goldenTray.ContainsKey($_.key)}).Count -eq 0) 'the tray matrix and the golden cover the same 12 rows'

$windowText=[IO.File]::ReadAllText((Join-Path $root 'fast-llm-ui.ps1'))
function Get-Mismatches([string]$SourceText,[switch]$First){
    $bad=New-Object System.Collections.ArrayList
    foreach($r in $matrix){
        $got=Invoke-UiWindowEnableRules -SourceText $SourceText -Row $r
        if(-not ($got -ceq $goldenRows[$r.key])){[void]$bad.Add($r.key+' got '+$got+' want '+$goldenRows[$r.key]);if($First){return ,@($bad.ToArray())}}
    }
    foreach($r in $trayMatrix){
        $got=Invoke-UiWindowTrayRule -SourceText $SourceText -Row $r
        if(-not ($got -ceq $goldenTray[$r.key])){[void]$bad.Add($r.key+' got '+$got+' want '+$goldenTray[$r.key]);if($First){return ,@($bad.ToArray())}}
    }
    return ,@($bad.ToArray())
}
$mismatches=Get-Mismatches $windowText
Check ($mismatches.Count -eq 0) ("the window's enable rules match 646ccb05 on every row (first mismatches: "+((@($mismatches)|Select-Object -First 3) -join ' | ')+')')

# The snapshot also carries a held failure and the flow phase (for the status card); the enable rules must ignore both. Every row again,
# with a failure held and a flow in its 'consent' phase: the bits must still equal the golden.
$ignoredBad=New-Object System.Collections.ArrayList
foreach($r in $matrix){
    $got=Invoke-UiWindowEnableRules -SourceText $windowText -Row $r -FailureHeld -FlowPhase 'consent'
    if(-not ($got -ceq $goldenRows[$r.key])){[void]$ignoredBad.Add($r.key+' got '+$got+' want '+$goldenRows[$r.key])}
}
Check ($ignoredBad.Count -eq 0) ('with a held failure and a consent-phase flow, all 2,230 rows still match the golden (first mismatches: '+((@($ignoredBad)|Select-Object -First 3) -join ' | ')+')')

# Readable anchors, hand-checked against the released code.
function Row([string]$Key){$m=@($matrix|Where-Object{$_.key -ceq $Key});if($m.Count -ne 1){throw "FAIL: no row $Key"};return $m[0]}
function Bit([string]$Bits,[string]$Column){return $Bits[[array]::IndexOf((Get-UiControlStatesColumns),$Column)]}
$idle=Invoke-UiWindowEnableRules -SourceText $windowText -Row (Row 'f=00000000000;b=absent')
Check ($idle -ceq '1111111111010111000') 'idle: every setup action, Stop and the tray are enabled; Choose another setup, Attach, Open chat, progress and API check are not'
$update=Invoke-UiWindowEnableRules -SourceText $windowText -Row (Row 'f=01000000000;b=absent')
Check ((Bit $update 'progressVisible') -ceq '1' -and (Bit $update 'install') -ceq '0' -and (Bit $update 'settings') -ceq '0' -and (Bit $update 'saveBundle') -ceq '0' -and (Bit $update 'stop') -ceq '1' -and (Bit $update 'apiCheck') -ceq '0') 'an update run makes the window busy but leaves Stop'
$gap=Invoke-UiWindowEnableRules -SourceText $windowText -Row (Row 'f=00000000100;b=unverified')
$noGap=Invoke-UiWindowEnableRules -SourceText $windowText -Row (Row 'f=00000000000;b=unverified')
Check ((Bit $gap 'stop') -ceq '1' -and (Bit $noGap 'stop') -ceq '0') 'the switch gap keeps Stop enabled while the background is unverified'
$trayOk=$true
foreach($r in $trayMatrix|Where-Object{$_.vcBroker}){$want=if($r.text -ceq 'Restore FastLLM'){'1'}else{'0'};if((Invoke-UiWindowTrayRule -SourceText $windowText -Row $r) -cne $want){$trayOk=$false}}
Check $trayOk 'Microsoft setup leaves only Restore in the tray'

# Self-check: the comparison is not vacuous.
$chooseLine='$chooseButton.Enabled=$states.chooseSetup'
Check ($windowText.Contains($chooseLine)) 'the self-check finds the Choose another setup rule'
$changed=$windowText.Replace($chooseLine,'$chooseButton.Enabled=$true')
$caught=Get-Mismatches $changed -First
Check ($caught.Count -gt 0) 'a changed rule is caught'

# Part B: the pure functions in src/FastLlm.UiState.ps1 reproduce the golden on every row.
$bareReadyBackground=Get-UiBackgroundFixture -Name 'bare-ready'
function New-RowSnapshot($Row){
    return New-FastLlmUiStateSnapshot -Busy ([bool]$Row.busy) -UpdateKind ([string]$Row.updateKind) -ChildActive ([bool]$Row.child) -Step ([string]$Row.step) `
        -RunReady ([bool]$Row.runReady) -SideChildActive ([bool]$Row.sideChild) -VcBrokerActive ($null -ne $Row.vcBroker) -PreviewReady ([bool]$Row.previewReady) `
        -SwitchGap ([bool]$Row.switchGap) -ChatUrlSet ([bool]$Row.chatUrl) -BackgroundStopRequested ([bool]$Row.bgStopRequested) `
        -Background (Get-UiBackgroundFixture -Name $Row.background)
}
$fnMismatches=New-Object System.Collections.ArrayList
foreach($r in $matrix){
    $snap=New-RowSnapshot $r
    $states=Get-FastLlmUiControlStates -Snapshot $snap
    $availability=Get-FastLlmUiSnapshotAvailability -Snapshot $snap
    $got=(@($states.PSObject.Properties|ForEach-Object{if($_.Value){'1'}else{'0'}}) -join '')+$(if($availability.apiCheck){'1'}else{'0'})
    if(-not ($got -ceq $goldenRows[$r.key])){[void]$fnMismatches.Add($r.key+' got '+$got+' want '+$goldenRows[$r.key])}
}
Check ($fnMismatches.Count -eq 0) ('Get-FastLlmUiControlStates matches 646ccb05 on every row (first mismatches: '+((@($fnMismatches)|Select-Object -First 3) -join ' | ')+')')
$trayMismatches=New-Object System.Collections.ArrayList
foreach($r in $trayMatrix){
    $got=$(if(Get-FastLlmUiTrayItemEnabled -ItemText ([string]$r.text) -Available ([bool]$r.available) -VcBrokerActive ($null -ne $r.vcBroker)){'1'}else{'0'})
    if(-not ($got -ceq $goldenTray[$r.key])){[void]$trayMismatches.Add($r.key+' got '+$got+' want '+$goldenTray[$r.key])}
}
Check ($trayMismatches.Count -eq 0) 'Get-FastLlmUiTrayItemEnabled matches 646ccb05 on every tray row'
$emptyTray=$null;$emptyThrew=$false
try{$emptyTray=Get-FastLlmUiTrayItemEnabled -ItemText '' -Available $true -VcBrokerActive $false}catch{$emptyThrew=$true}
Check (-not $emptyThrew -and $emptyTray -eq $true) 'a tray item with empty text follows Available, like the old inline rule'
$bare=New-FastLlmUiStateSnapshot -Busy $false -UpdateKind '' -ChildActive $false -Step '' -RunReady $false -SideChildActive $false -VcBrokerActive $false `
    -PreviewReady $false -SwitchGap $false -ChatUrlSet $false -BackgroundStopRequested $false -Background $bareReadyBackground
Check ((Get-FastLlmUiControlStates -Snapshot $bare) -is [pscustomobject]) 'an observation missing optional properties does not throw under StrictMode 2'
Check ((@((Get-FastLlmUiControlStates -Snapshot $bare).PSObject.Properties.Name) -join ',') -ceq ((Get-UiControlStatesColumns)[0..17] -join ',')) 'the control states carry the first 18 columns in order'
Check ($bare.FlowPhase -ceq '' -and $bare.FailureHeld -eq $false) 'the snapshot carries FlowPhase and FailureHeld defaults'
$threw=$false;try{[void](New-FastLlmUiStateSnapshot -Busy $false -UpdateKind 'bogus' -ChildActive $false -Step '' -RunReady $false -SideChildActive $false -VcBrokerActive $false -PreviewReady $false -SwitchGap $false -ChatUrlSet $false -BackgroundStopRequested $false -Background $bareReadyBackground)}catch{$threw=$true}
Check $threw 'an unknown UpdateKind is refused'


# Greyed-reason codes: pure codes, '' exactly when the control state is true, over all 2,230 rows.
$reasonActions=@('diagnostics','driverGuidance','saveBundle','backgroundCheck','backgroundAttach','apiCheck','chooseSetup','startInputs','settings')
function Get-ReasonPropertyFailures([string]$Fn,[switch]$First){
    $bad=New-Object System.Collections.ArrayList
    foreach($r in $matrix){
        $snap=New-RowSnapshot $r
        $states=Get-FastLlmUiControlStates -Snapshot $snap
        $api=Get-FastLlmUiSnapshotAvailability -Snapshot $snap
        foreach($a in $reasonActions){
            foreach($running in @($true,$false)){
                if($a -ceq 'apiCheck'){$enabled=[bool]($running -and $api.apiCheck)}elseif($a -ceq 'startInputs'){if(-not $running){continue};$enabled=[bool]$states.model}else{if(-not $running){continue};$enabled=[bool]$states.$a}
                $code=[string](& $Fn -Action $a -Snapshot $snap -ConnectRunning $running)
                if(($code -ceq '') -ne $enabled){[void]$bad.Add($r.key+' '+$a+' running='+$running+' code='+$code+' enabled='+$enabled);if($First){return ,$bad}}
            }
        }
    }
    return ,$bad
}
$reasonBad=Get-ReasonPropertyFailures 'Get-FastLlmUiGreyedReason'
Check ($reasonBad.Count -eq 0) ('a greyed-reason code is empty exactly when the control state is true on every row (first: '+((@($reasonBad)|Select-Object -First 3) -join ' | ')+')')
$codeSet=@('','microsoft-setup','busy','side-step','attached','no-run','not-running','background','no-preview')
$unknownCodes=@(foreach($r in $matrix){$s=New-RowSnapshot $r;foreach($a in $reasonActions){$c=[string](Get-FastLlmUiGreyedReason -Action $a -Snapshot $s -ConnectRunning $true);if($codeSet -cnotcontains $c){$a+':'+$c}}})
Check ($unknownCodes.Count -eq 0) 'every greyed-reason code is one of the nine known codes'

function New-ReasonSnapshot([hashtable]$Over=@{},[string]$Background='none'){
    $p=@{Busy=$false;UpdateKind='';ChildActive=$false;Step='';RunReady=$false;SideChildActive=$false;VcBrokerActive=$false;PreviewReady=$false;SwitchGap=$false;ChatUrlSet=$false;BackgroundStopRequested=$false}
    foreach($k in $Over.Keys){$p[$k]=$Over[$k]}
    return New-FastLlmUiStateSnapshot @p -Background (Get-UiBackgroundFixture -Name $Background)
}
function Reason([string]$A,$S,[bool]$Run=$false){return [string](Get-FastLlmUiGreyedReason -Action $A -Snapshot $S -ConnectRunning $Run)}
Check ((Reason 'diagnostics' (New-ReasonSnapshot)) -ceq '') 'idle: diagnostics has no reason'
Check ((Reason 'backgroundCheck' (New-ReasonSnapshot @{VcBrokerActive=$true;Busy=$true})) -ceq 'microsoft-setup') 'Microsoft setup is the reason while it runs'
Check ((Reason 'diagnostics' (New-ReasonSnapshot @{Busy=$true})) -ceq 'busy') 'a busy window greys diagnostics with busy'
Check ((Reason 'backgroundCheck' (New-ReasonSnapshot @{UpdateKind='update'})) -ceq 'busy') 'an update run greys the background check with busy'
Check ((Reason 'saveBundle' (New-ReasonSnapshot @{Busy=$true})) -ceq 'busy') 'a launch in progress greys the bundle with busy'
Check ((Reason 'saveBundle' (New-ReasonSnapshot @{SideChildActive=$true})) -ceq 'side-step') 'a running side check greys the bundle with side-step'
Check ((Reason 'apiCheck' (New-ReasonSnapshot @{RunReady=$true;SideChildActive=$true}) $true) -ceq 'side-step') 'a running side check greys the API check with side-step'
Check ((Reason 'backgroundAttach' (New-ReasonSnapshot @{} 'ready-attached')) -ceq 'attached') 'an attached run greys Attach with attached'
Check ((Reason 'backgroundAttach' (New-ReasonSnapshot @{} 'none')) -ceq 'no-run') 'no attachable run greys Attach with no-run'
Check ((Reason 'backgroundAttach' (New-ReasonSnapshot @{} 'starting-other')) -ceq 'no-run') 'a run for another request greys Attach with no-run'
Check ((Reason 'backgroundAttach' (New-ReasonSnapshot @{} 'ready-attachable')) -ceq '') 'an attachable run leaves Attach enabled'
Check ((Reason 'apiCheck' (New-ReasonSnapshot @{RunReady=$true}) $false) -ceq 'not-running') 'Connect not running greys the API check with not-running'
Check ((Reason 'apiCheck' (New-ReasonSnapshot @{}) $true) -ceq 'not-running') 'a snapshot that is not serving greys the API check with not-running'
Check ((Reason 'apiCheck' (New-ReasonSnapshot @{RunReady=$true}) $true) -ceq '') 'a serving, running API check has no reason'
Check ((Reason 'chooseSetup' (New-ReasonSnapshot @{VcBrokerActive=$true;Busy=$true;PreviewReady=$true})) -ceq 'microsoft-setup') 'Microsoft setup greys Choose another setup with microsoft-setup'
Check ((Reason 'chooseSetup' (New-ReasonSnapshot @{Busy=$true;PreviewReady=$true})) -ceq 'busy') 'a busy window greys Choose another setup with busy'
Check ((Reason 'chooseSetup' (New-ReasonSnapshot @{UpdateKind='update';PreviewReady=$true})) -ceq 'busy') 'an update run greys Choose another setup with busy'
Check ((Reason 'chooseSetup' (New-ReasonSnapshot @{PreviewReady=$true} 'ready-attached')) -ceq 'background') 'an occupied background greys Choose another setup with background'
Check ((Reason 'chooseSetup' (New-ReasonSnapshot @{PreviewReady=$false})) -ceq 'no-preview') 'no preview greys Choose another setup with no-preview'
Check ((Reason 'chooseSetup' (New-ReasonSnapshot @{PreviewReady=$true})) -ceq '') 'an idle window with a preview leaves Choose another setup enabled'
Check ((Reason 'startInputs' (New-ReasonSnapshot @{VcBrokerActive=$true;Busy=$true})) -ceq 'microsoft-setup') 'Microsoft setup greys the start inputs with microsoft-setup'
Check ((Reason 'startInputs' (New-ReasonSnapshot @{Busy=$true})) -ceq 'busy') 'a busy window greys the start inputs with busy'
Check ((Reason 'startInputs' (New-ReasonSnapshot @{} 'ready-attached')) -ceq 'background') 'an occupied background greys the start inputs with background'
Check ((Reason 'startInputs' (New-ReasonSnapshot @{})) -ceq '') 'an idle window leaves the start inputs enabled'
$modelRowsDiffer=@(foreach($r in $matrix){$st=Get-FastLlmUiControlStates -Snapshot (New-RowSnapshot $r);if(-not ($st.model -eq $st.path -and $st.model -eq $st.context -and $st.model -eq $st.bar)){$r.key}})
Check ($modelRowsDiffer.Count -eq 0) 'the model, path, context and BAR states are equal on every row'
# The greyed-reason function copies the attachable and requestMatches expressions of the control-state function; the copies must stay text-identical.
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
    $b=Get-UiStateExpression 'Get-FastLlmUiGreyedReason' $v
    Check ($a.Length -gt 20 -and $a -ceq $b) "the greyed-reason $v expression is text-identical to the control-state one"
}
# A pending request id that differs only by case is a different request: Attach is disabled and says no-run (the comparison is case-sensitive).
$caseSnap=New-ReasonSnapshot @{} 'ready-attachable'
$caseSnap.Background.pendingRequestId=([string]$caseSnap.Background.observation.requestId).ToUpper()
Check (([string]$caseSnap.Background.pendingRequestId) -cne ([string]$caseSnap.Background.observation.requestId)) 'the case row has a pending id that differs only by case'
Check ((Reason 'backgroundAttach' $caseSnap) -ceq 'no-run') 'a pending request id that differs only by case greys Attach with no-run'
Check (-not (Get-FastLlmUiControlStates -Snapshot $caseSnap).backgroundAttach) 'a pending request id that differs only by case leaves the Attach state disabled'
$badAction=$false;try{[void](Get-FastLlmUiGreyedReason -Action 'DIAGNOSTICS' -Snapshot (New-ReasonSnapshot))}catch{$badAction=($_.Exception.Message -like "Unknown action*")}
Check $badAction 'an action in another case is refused, not silently treated as enabled'
$badAction2=$false;try{[void](Get-FastLlmUiGreyedReason -Action 'SAVEBUNDLE' -Snapshot (New-ReasonSnapshot @{Busy=$true}))}catch{$badAction2=($_.Exception.Message -like "Unknown action*")}
Check $badAction2 'a string-case action (SAVEBUNDLE) is refused, not matched case-insensitively'
# Mutation: a swapped sub-expression must make the property fail.
$fnText=${function:Get-FastLlmUiGreyedReason}.ToString()
function Test-ReasonMutant([string]$From,[string]$To){
    if(-not $fnText.Contains($From)){throw "FAIL: mutation anchor missing: $From"}
    Set-Item -Path function:script:Get-ReasonMutant -Value ([scriptblock]::Create($fnText.Replace($From,$To)))
    return (Get-ReasonPropertyFailures 'Get-ReasonMutant' -First).Count
}
# CONTROL: a mutant that changes nothing (the same text through the same mutation path) gives exactly 0 property failures, so a counter that is always positive fails here.
Check ((Test-ReasonMutant "return 'no-preview'" "return 'no-preview'") -eq 0) 'control: an unchanged copy of the greyed-reason function has no property failures through the mutation path'
Check ((Test-ReasonMutant "if (`$bg.attachedRequestId) { return 'attached' }" "if (`$false) { return 'attached' }") -gt 0) 'mutation: dropping the attached rule fails the property'
Check ((Test-ReasonMutant 'if ($availability.saveBundle) { return '''' }' 'if (-not $availability.saveBundle) { return '''' }') -gt 0) 'mutation: swapping the bundle availability sub-expression fails the property'
Check ((Test-ReasonMutant 'if ($busy -or $Snapshot.ChildActive)' 'if ($busy)') -gt 0) 'mutation: dropping ChildActive from the busy rules fails the property'

Check ((Test-ReasonMutant "return 'no-preview'" "return ''") -gt 0) 'mutation: dropping the no-preview code fails the property'
Check ((Test-ReasonMutant "return 'background' }`n            if (-not `$Snapshot.PreviewReady)" "return '' }`n            if (-not `$Snapshot.PreviewReady)") -gt 0) 'mutation: dropping the chooseSetup background code fails the property'
Check ((Test-ReasonMutant "if (Test-FastLlmUiStateOccupied -Background `$bg) { return 'background' }`n            return ''" "return ''") -gt 0) 'mutation: dropping the start-inputs background rule fails the property'
Check ((Test-ReasonMutant "if (`$vc) { return 'microsoft-setup' }`n            if (`$busy) { return 'busy' }" "if (`$busy) { return 'busy' }") -gt 0) 'mutation: dropping the chooseSetup Microsoft rule fails the property'

# Settings greyed reason (PR 3c): microsoft-setup, else busy, else ''. The property loop above covers 'settings' on every row.
Check ((Reason 'settings' (New-ReasonSnapshot)) -ceq '') 'idle: settings has no reason'
Check ((Reason 'settings' (New-ReasonSnapshot @{VcBrokerActive=$true;Busy=$true})) -ceq 'microsoft-setup') 'Microsoft setup greys settings with microsoft-setup'
Check ((Reason 'settings' (New-ReasonSnapshot @{Busy=$true})) -ceq 'busy') 'a launch in progress greys settings with busy'
Check ((Reason 'settings' (New-ReasonSnapshot @{UpdateKind='update'})) -ceq 'busy') 'an update run greys settings with busy'
Check ($fnText.Contains("if (`$vc) { return 'microsoft-setup' }`n            return 'busy'")) 'the settings reason anchor is present'
Check ((Test-ReasonMutant "if (`$vc) { return 'microsoft-setup' }`n            return 'busy'" "if (`$vc) { return 'microsoft-setup' }`n            return ''") -gt 0) 'mutation: settings busy to empty fails the property'


# The matrix has no attachable run with a case-different pending id, so this mutant is caught by the direct case row.
$ceqFrom='-ceq [string]$bg.pendingRequestId'
Check ($fnText.Contains($ceqFrom)) 'the case-sensitive request comparison anchor is present'
Set-Item -Path function:script:Get-ReasonMutant -Value ([scriptblock]::Create($fnText.Replace($ceqFrom,$ceqFrom)))
Check ((Get-ReasonMutant -Action 'backgroundAttach' -Snapshot $caseSnap) -ceq 'no-run') 'control: an unchanged copy greys Attach with no-run on the case row'
Set-Item -Path function:script:Get-ReasonMutant -Value ([scriptblock]::Create($fnText.Replace($ceqFrom,'-eq [string]$bg.pendingRequestId')))
Check ((Get-ReasonMutant -Action 'backgroundAttach' -Snapshot $caseSnap) -cne 'no-run') 'mutation: a case-insensitive request comparison fails the case row'

# Settings held-edit machine (PR 3c Task 1): pure, no text.
function New-SettingsCurrent([hashtable]$Over=@{}){
    $c=[ordered]@{serverPort=11434;thinking='auto';chatPage='off';idleStopMinutes=0;apiKey='off';apiKeyUndetermined=$false;allowSwitch=$false}
    foreach($k in $Over.Keys){$c[$k]=$Over[$k]}
    return [pscustomobject]$c
}
function Copy-Held($H,[hashtable]$Over=@{}){
    $c=[ordered]@{};foreach($p in $H.PSObject.Properties){$c[$p.Name]=$p.Value}
    foreach($k in $Over.Keys){$c[$k]=$Over[$k]}
    return [pscustomobject]$c
}
$held0=ConvertTo-FastLlmUiSettingsHeld -Current (New-SettingsCurrent)
Check ($held0.port -is [int] -and $held0.port -eq 11434 -and $held0.thinkingIndex -eq 0 -and $held0.chatPage -eq $false -and $held0.idleIndex -eq 0 -and $held0.keyBox -ceq 'unchecked' -and $held0.keyTouched -eq $false -and $held0.allowSwitch -eq $false) 'the held edits start from the saved settings'
$heldOn=ConvertTo-FastLlmUiSettingsHeld -Current (New-SettingsCurrent @{thinking='off';chatPage='on';idleStopMinutes=30;apiKey='on';allowSwitch=$true;serverPort='8080'})
Check ($heldOn.port -eq 8080 -and $heldOn.thinkingIndex -eq 1 -and $heldOn.chatPage -eq $true -and $heldOn.idleIndex -eq 2 -and $heldOn.keyBox -ceq 'checked' -and $heldOn.allowSwitch -eq $true) 'held edits map thinking off, chat on, idle 30, key on and switch on'
Check ((ConvertTo-FastLlmUiSettingsHeld -Current (New-SettingsCurrent @{apiKey='on';apiKeyUndetermined=$true})).keyBox -ceq 'indeterminate') 'an undetermined key is held indeterminate'
# Round trip: every thinking and idle value comes back as saved; an unknown idle gives 0.
foreach($th in 'auto','off'){foreach($idle in 0,15,30,60,45,-1,999){
    $back=ConvertFrom-FastLlmUiSettingsHeld -Held (ConvertTo-FastLlmUiSettingsHeld -Current (New-SettingsCurrent @{thinking=$th;idleStopMinutes=$idle;chatPage='on';allowSwitch=$true;serverPort=9000}))
    $wantIdle=$(if(@(15,30,60) -contains $idle){$idle}else{0})
    Check ($back.thinking -ceq $th -and $back.idleStopMinutes -eq $wantIdle -and $back.serverPort -eq 9000 -and $back.chatPage -ceq 'on' -and $back.allowSwitch -eq $true) "round trip thinking=$th idle=$idle"
}}
$offBack=ConvertFrom-FastLlmUiSettingsHeld -Held $held0
Check ($offBack.chatPage -ceq 'off' -and $offBack.thinking -ceq 'auto' -and $offBack.serverPort -is [int]) 'the saved values from untouched held edits are chat off, thinking auto and an int port'
Check ((ConvertFrom-FastLlmUiSettingsHeld -Held (Copy-Held $held0 @{thinkingIndex=7})).thinking -ceq 'auto') 'only index 1 is thinking off'
Check ((ConvertFrom-FastLlmUiSettingsHeld -Held (Copy-Held $held0 @{idleIndex=-3})).idleStopMinutes -eq 0) 'a negative idle index saves 0'
# The key box states and the click sequence.
Check ((ConvertTo-FastLlmUiKeyBoxState -IsChecked $true) -ceq 'checked' -and (ConvertTo-FastLlmUiKeyBoxState -IsChecked $false) -ceq 'unchecked' -and (ConvertTo-FastLlmUiKeyBoxState -IsChecked $null) -ceq 'indeterminate') 'the key box maps true, false and null to checked, unchecked and indeterminate'
function Click-KeyBox($State){switch -CaseSensitive ($State){'indeterminate'{return 'unchecked'}'unchecked'{return 'checked'}default{return 'unchecked'}}}
$seq=@();$st='indeterminate';$touched=$false
for($i=0;$i -lt 4;$i++){$st=Click-KeyBox $st;$touched=$true;$seq+=$st}
Check (($seq -join ',') -ceq 'unchecked,checked,unchecked,checked') 'the key box goes indeterminate, unchecked, checked, unchecked and never back to indeterminate'
# Dirty.
$saved=$held0
Check ((Test-FastLlmUiSettingsDirty -Saved $saved -Held $held0) -is [bool]) 'dirty is one bool'
Check (-not (Test-FastLlmUiSettingsDirty -Saved $saved -Held $held0)) 'untouched edits are not dirty'
foreach($f in @(@{port=1},@{thinkingIndex=1},@{chatPage=$true},@{idleIndex=1},@{keyBox='checked'},@{allowSwitch=$true})){
    $name=@($f.Keys)[0]
    Check (Test-FastLlmUiSettingsDirty -Saved $saved -Held (Copy-Held $held0 $f)) "a changed $name is dirty"
}
$savedUnknown=ConvertTo-FastLlmUiSettingsHeld -Current (New-SettingsCurrent @{apiKeyUndetermined=$true})
Check (-not (Test-FastLlmUiSettingsDirty -Saved $savedUnknown -Held $savedUnknown)) 'an untouched indeterminate key is not dirty'
Check (Test-FastLlmUiSettingsDirty -Saved $savedUnknown -Held (Copy-Held $savedUnknown @{keyTouched=$true})) 'a touched key box on a saved indeterminate counts as dirty'
Check (-not (Test-FastLlmUiSettingsDirty -Saved $saved -Held (Copy-Held $held0 @{keyTouched=$true}))) 'a touched key box on a known saved key with the same state is not dirty'
# Settings additions (context profile, requests at once, embeddings and its port): held, saved, dirty.
$heldAdd=ConvertTo-FastLlmUiSettingsHeld -Current (New-SettingsCurrent)
Check ($heldAdd.contextProfile -ceq 'default' -and $heldAdd.slots -is [int] -and $heldAdd.slots -eq 1 -and $heldAdd.embeddings -ceq 'off' -and $heldAdd.embeddingPort -is [int] -and $heldAdd.embeddingPort -eq 8081) 'a current without the new fields is held as the store defaults (default, 1, off, 8081)'
foreach($cp in 'default','long'){foreach($sl in 1,2){foreach($em in 'off','on'){foreach($ep in 1024,8081,65535){
    $backAdd=ConvertFrom-FastLlmUiSettingsHeld -Held (ConvertTo-FastLlmUiSettingsHeld -Current (New-SettingsCurrent @{contextProfile=$cp;slots=$sl;embeddings=$em;embeddingPort=$ep}))
    Check ($backAdd.contextProfile -ceq $cp -and $backAdd.slots -is [int] -and $backAdd.slots -eq $sl -and $backAdd.embeddings -ceq $em -and $backAdd.embeddingPort -is [int] -and $backAdd.embeddingPort -eq $ep) "round trip contextProfile=$cp slots=$sl embeddings=$em embeddingPort=$ep"
}}}}
$backMissing=ConvertFrom-FastLlmUiSettingsHeld -Held (ConvertTo-FastLlmUiSettingsHeld -Current (New-SettingsCurrent))
Check ($backMissing.contextProfile -ceq 'default' -and $backMissing.slots -eq 1 -and $backMissing.embeddings -ceq 'off' -and $backMissing.embeddingPort -eq 8081) 'missing fields map to the default and come back as the default'
$oldHeld=[pscustomobject]@{port=1;thinkingIndex=0;chatPage=$false;idleIndex=0;keyBox='unchecked';keyTouched=$false;allowSwitch=$false}
$backOld=ConvertFrom-FastLlmUiSettingsHeld -Held $oldHeld
Check ($backOld.contextProfile -ceq 'default' -and $backOld.slots -eq 1 -and $backOld.embeddings -ceq 'off' -and $backOld.embeddingPort -eq 8081) 'a held without the new fields saves the defaults'
foreach($f in @(@{contextProfile='long'},@{slots=2},@{embeddings='on'},@{embeddingPort=9090})){
    $name=@($f.Keys)[0]
    Check (Test-FastLlmUiSettingsDirty -Saved $heldAdd -Held (Copy-Held $heldAdd $f)) "a changed $name is dirty"
    Check (Test-FastLlmUiSettingsDirty -Saved (Copy-Held $heldAdd $f) -Held $heldAdd) "a saved $name that differs from the held one is dirty"
}
Check (-not (Test-FastLlmUiSettingsDirty -Saved $heldAdd -Held (Copy-Held $heldAdd @{}))) 'equal additions are not dirty'
# Out-of-range saved values (a hand-edited or older settings.json): the held value is the store's default, the value the page's box shows. So a held
# rebuilt from the boxes after any other edit equals the saved one on these keys: the page is not dirty, and Save does not rewrite the saved value.
foreach($odd in @(
    @{Name='slots 3';Over=@{slots=3};Field='slots';Want=1},
    @{Name='slots 0';Over=@{slots=0};Field='slots';Want=1},
    @{Name="contextProfile 'weird'";Over=@{contextProfile='weird'};Field='contextProfile';Want='default'},
    @{Name="contextProfile 'Long'";Over=@{contextProfile='Long'};Field='contextProfile';Want='default'},
    @{Name="embeddings 'maybe'";Over=@{embeddings='maybe'};Field='embeddings';Want='off'},
    @{Name="embeddings 'ON'";Over=@{embeddings='ON'};Field='embeddings';Want='off'},
    @{Name='no embeddingPort';Over=@{};Field='embeddingPort';Want=8081}
)){
    $oddSaved=ConvertTo-FastLlmUiSettingsHeld -Current (New-SettingsCurrent $odd.Over)
    Check ([string]$oddSaved.($odd.Field) -ceq [string]$odd.Want) "a saved $($odd.Name) is held as $($odd.Want)"
    Check (-not (Test-FastLlmUiSettingsDirty -Saved $oddSaved -Held (Copy-Held $oddSaved @{$odd.Field=$odd.Want}))) "a saved $($odd.Name), with its box showing $($odd.Want) after another edit, is not dirty"
}

# The additions view: every combination of its seven inputs (128); the lead's three named states are called out.
$viewCases=0
foreach($av in $true,$false){foreach($se in 'off','on'){foreach($lm in $true,$false){foreach($sp in 'default','long'){foreach($tm in $true,$false){foreach($ss in 1,2){foreach($cx in 0,4096){
    $v=Get-FastLlmUiSettingsAdditionsView -EmbeddingsAvailable $av -SavedEmbeddings $se -LongMeasured $lm -SavedContextProfile $sp -TwoMeasured $tm -SavedSlots $ss -ContextSize $cx
    $viewCases++
    $wantShow=($av -or $se -ceq 'on')
    $wantLong=(($lm -and $cx -le 0) -or $sp -ceq 'long')
    $wantTwo=(($tm -and $cx -le 0) -or $ss -eq 2)
    $wantLongReason=$(if($wantLong){''}elseif($cx -gt 0){'needs-catalog-context'}else{'long-not-measured'})
    $wantTwoReason=$(if($wantTwo){''}elseif($cx -gt 0){'needs-catalog-context'}else{'long-not-measured'})
    Check ($v -is [hashtable] -and $v.Count -eq 5 -and $v['showEmbeddings'] -is [bool] -and $v['longEnabled'] -is [bool] -and $v['twoEnabled'] -is [bool] -and $v['longReasonCode'] -is [string] -and $v['twoReasonCode'] -is [string] -and $v['showEmbeddings'] -eq $wantShow -and $v['longEnabled'] -eq $wantLong -and $v['twoEnabled'] -eq $wantTwo -and $v['longReasonCode'] -ceq $wantLongReason -and $v['twoReasonCode'] -ceq $wantTwoReason) "additions view available=$av savedEmb=$se longMeasured=$lm savedProfile=$sp twoMeasured=$tm savedSlots=$ss context=$cx"
}}}}}}}
Check ($viewCases -eq 128) 'the additions view was checked for all 128 combinations'
function Get-AddView([bool]$Av=$false,[string]$Se='off',[bool]$Lm=$false,[string]$Sp='default',[bool]$Tm=$false,[int]$Ss=1,[int]$Cx=0){return (Get-FastLlmUiSettingsAdditionsView -EmbeddingsAvailable $Av -SavedEmbeddings $Se -LongMeasured $Lm -SavedContextProfile $Sp -TwoMeasured $Tm -SavedSlots $Ss -ContextSize $Cx)}
Check ((Get-AddView -Av $true)['showEmbeddings'] -eq $true) 'embeddings state a: available shows the rows'
Check ((Get-AddView -Se 'on')['showEmbeddings'] -eq $true) 'embeddings state b: saved on shows the rows although unavailable'
Check ((Get-AddView)['showEmbeddings'] -eq $false) 'embeddings state neither: the rows are hidden'
Check ((Get-AddView -Se 'ON' -Sp 'Long')['showEmbeddings'] -eq $false -and (Get-AddView -Se 'ON' -Sp 'Long')['longEnabled'] -eq $false) 'the saved values are matched case-sensitively'
Check ((Get-AddView -Lm $true -Cx 4096)['longEnabled'] -eq $false -and (Get-AddView -Lm $true -Cx 4096)['longReasonCode'] -ceq 'needs-catalog-context') 'a measured Long with Context above 0 is disabled for the context'
Check ((Get-AddView -Tm $true -Cx 4096)['twoEnabled'] -eq $false -and (Get-AddView -Tm $true -Cx 4096)['twoReasonCode'] -ceq 'needs-catalog-context') 'a measured 2 with Context above 0 is disabled for the context'
Check ((Get-AddView -Sp 'long' -Cx 4096)['longEnabled'] -eq $true -and (Get-AddView -Ss 2 -Cx 4096)['twoEnabled'] -eq $true) 'a saved Long or a saved 2 stays enabled with Context above 0'
Check ((Get-AddView -Lm $false -Tm $false -Cx 0)['longReasonCode'] -ceq 'long-not-measured' -and (Get-AddView -Lm $false -Tm $false -Cx 0)['twoReasonCode'] -ceq 'long-not-measured') 'unmeasured with Context 0 says long-not-measured for both'
Check ((Get-AddView -Lm $false -Cx 4096)['longReasonCode'] -ceq 'needs-catalog-context') 'with both reasons the context reason wins (it is the actionable one)'

# The saved notes of the additions (while a run is going), in order, only when the value changed; the old keys alone give today's notes.
function New-NoteSide([hashtable]$Over=@{}){
    $c=[ordered]@{serverPort=8080;thinking='auto';chatPage='off';idleStopMinutes=0;apiKey='off';allowSwitch=$false;contextProfile='default';slots=1;embeddings='off';embeddingPort=8081}
    foreach($k in $Over.Keys){$c[$k]=$Over[$k]}
    return [pscustomobject]$c
}
$noteBase=New-NoteSide
Check ((Get-FastLlmUiSettingsSavedNote -RunActive $true -Before $noteBase -After (New-NoteSide @{contextProfile='long'})) -ceq 'The new context profile applies at the next start.') 'note: a changed context profile during a run'
Check ((Get-FastLlmUiSettingsSavedNote -RunActive $true -Before $noteBase -After (New-NoteSide @{slots=2})) -ceq 'The new requests at once setting applies at the next start.') 'note: a changed requests at once during a run'
Check ((Get-FastLlmUiSettingsSavedNote -RunActive $true -Before $noteBase -After (New-NoteSide @{embeddings='on'})) -ceq 'The new embeddings setting applies at the next start.') 'note: a changed embeddings setting during a run'
Check ((Get-FastLlmUiSettingsSavedNote -RunActive $true -Before $noteBase -After (New-NoteSide @{embeddingPort=9090})) -ceq 'The new embeddings port applies at the next start.') 'note: a changed embeddings port during a run'
Check ((Get-FastLlmUiSettingsSavedNote -RunActive $true -Before $noteBase -After (New-NoteSide @{contextProfile='long';slots=2;embeddings='on';embeddingPort=9090})) -ceq 'The new context profile applies at the next start.') 'note: several changed gives the first in order (profile, requests, embeddings, port)'
Check ((Get-FastLlmUiSettingsSavedNote -RunActive $true -Before $noteBase -After (New-NoteSide @{slots=2;embeddings='on';embeddingPort=9090})) -ceq 'The new requests at once setting applies at the next start.') 'note: requests at once comes before embeddings and the port'
Check ((Get-FastLlmUiSettingsSavedNote -RunActive $true -Before $noteBase -After (New-NoteSide @{embeddings='on';embeddingPort=9090})) -ceq 'The new embeddings setting applies at the next start.') 'note: embeddings comes before the port'
Check ((Get-FastLlmUiSettingsSavedNote -RunActive $true -Before $noteBase -After (New-NoteSide @{serverPort=9090;contextProfile='long'})) -ceq 'The new port applies at the next start.') 'note: the older keys come first'
Check ((Get-FastLlmUiSettingsSavedNote -RunActive $false -Before $noteBase -After (New-NoteSide @{contextProfile='long';slots=2;embeddings='on';embeddingPort=9090})) -ceq 'Settings saved.') 'note: no run going says saved, whatever the additions'
Check ((Get-FastLlmUiSettingsSavedNote -RunActive $true -Before $noteBase -After (New-NoteSide)) -ceq 'Settings saved.') 'note: nothing changed says saved'
$oldBefore=[pscustomobject]@{serverPort=8080;thinking='auto';chatPage='off';idleStopMinutes=0;apiKey='off';allowSwitch=$false}
Check ((Get-FastLlmUiSettingsSavedNote -RunActive $true -Before $oldBefore -After ([pscustomobject]@{serverPort=8080;thinking='auto';chatPage='off';idleStopMinutes=0;apiKey='off';allowSwitch=$false})) -ceq 'Settings saved.') 'classic notes: a pair with only the old keys and no change says saved'
foreach($oc in @(@{serverPort=9090;want='The new port applies at the next start.'},@{thinking='off';want='The new thinking setting applies at the next start.'},@{chatPage='on';want='The new chat page setting applies at the next start.'},@{idleStopMinutes=30;want='The new idle stop setting applies at the next start.'},@{apiKey='on';want='The new API key setting applies at the next start.'},@{allowSwitch=$true;want='The new switching setting applies at the next start.'})){
    $aft=[ordered]@{serverPort=8080;thinking='auto';chatPage='off';idleStopMinutes=0;apiKey='off';allowSwitch=$false}
    foreach($k in @($oc.Keys)){if($k -cne 'want'){$aft[$k]=$oc[$k]}}
    Check ((Get-FastLlmUiSettingsSavedNote -RunActive $true -Before $oldBefore -After ([pscustomobject]$aft)) -ceq $oc.want) "classic notes: a pair that differs only in an old key gives today's note ($($oc.want))"
}

# The exit decision table (lead rulings: signout discards, hide keeps the edits).
function Decide([bool]$Dirty,[string]$Answer,[bool]$SaveOk,[string]$Reason){return [string](Get-FastLlmUiSettingsExitDecision -Dirty $Dirty -Answer $Answer -SaveOk $SaveOk -Reason $Reason)}
foreach($rs in 'leave','close'){Check ([string](Get-FastLlmUiSettingsExitDecision -Dirty $true -Answer 'save' -Reason $rs) -ceq 'save') "$rs save answered before Save ran says save"}
Check ([string](Get-FastLlmUiSettingsExitDecision -Dirty $true -Answer 'save' -Reason 'hide') -ceq 'go') 'hide never needs Save'
Check ([string](Get-FastLlmUiSettingsExitDecision -Dirty $true -Answer 'save' -Reason 'signout') -ceq 'discard-go') 'sign-out never needs Save'
foreach($rs in 'leave','close','signout','hide'){foreach($an in 'save','discard','cancel','none'){foreach($ok in $true,$false){
    Check ((Decide $false $an $ok $rs) -ceq 'go') "not dirty goes ($rs/$an/$ok)"
}}}
foreach($an in 'save','discard','cancel','none'){foreach($ok in $true,$false){
    Check ((Decide $true $an $ok 'hide') -ceq 'go') "hide keeps the edits and goes ($an/$ok)"
    Check ((Decide $true $an $ok 'signout') -ceq 'discard-go') "sign-out with edits discards ($an/$ok)"
}}
foreach($rs in 'leave','close'){
    Check ((Decide $true 'save' $true $rs) -ceq 'go') "$rs save ok goes"
    Check ((Decide $true 'save' $false $rs) -ceq 'stay') "$rs save refused stays"
    Check ((Decide $true 'discard' $true $rs) -ceq 'discard-go') "$rs discard goes and drops the edits"
    Check ((Decide $true 'discard' $false $rs) -ceq 'discard-go') "$rs discard ignores SaveOk"
    Check ((Decide $true 'cancel' $true $rs) -ceq 'stay') "$rs cancel stays"
    Check ((Decide $true 'cancel' $false $rs) -ceq 'stay') "$rs cancel stays whatever SaveOk"
    Check ((Decide $true 'none' $true $rs) -ceq 'stay') "$rs dirty with no answer stays"
}
# Mutants on scratch copies of the functions: each must fail a check above.
function Test-SettingsMutant([string]$Fn,[string]$From,[string]$To,[scriptblock]$Probe){
    $text=(Get-Command $Fn -CommandType Function).ScriptBlock.ToString()
    if(-not $text.Contains($From)){throw "FAIL: mutation anchor missing in ${Fn}: $From"}
    Set-Item -Path function:script:Get-SettingsMutant -Value ([scriptblock]::Create($text.Replace($From,$To)))
    return [bool](& $Probe)
}
# CONTROL: an unchanged copy through the same mutation path passes both probes, so the probes below can fail.
Check (Test-SettingsMutant 'Get-FastLlmUiSettingsExitDecision' "default { return 'stay' }" "default { return 'stay' }" {(Get-SettingsMutant -Dirty $true -Answer 'cancel' -SaveOk $true -Reason 'leave') -ceq 'stay'}) 'control: an unchanged exit-decision copy passes the cancel probe through the mutation path'
Check (Test-SettingsMutant 'Test-FastLlmUiSettingsDirty' "-ceq 'indeterminate' -and [bool]`$Held.keyTouched" "-ceq 'indeterminate' -and [bool]`$Held.keyTouched" {[bool](Get-SettingsMutant -Saved $savedUnknown -Held (Copy-Held $savedUnknown @{keyTouched=$true}))}) 'control: an unchanged dirty-test copy passes the touched-indeterminate probe through the mutation path'
Check (-not (Test-SettingsMutant 'Get-FastLlmUiSettingsExitDecision' "default { return 'stay' }" "default { return 'go' }" {(Get-SettingsMutant -Dirty $true -Answer 'cancel' -SaveOk $true -Reason 'leave') -ceq 'stay'})) 'mutation: cancel to go fails the table'
Check (-not (Test-SettingsMutant 'Test-FastLlmUiSettingsDirty' "-ceq 'indeterminate' -and [bool]`$Held.keyTouched" "-ceq 'indeterminate' -and `$false" {[bool](Get-SettingsMutant -Saved $savedUnknown -Held (Copy-Held $savedUnknown @{keyTouched=$true}))})) 'mutation: dirty ignoring keyTouched fails the touched-indeterminate check'

Check (-not (Test-SettingsMutant 'Test-FastLlmUiSettingsDirty' "if (`$savedSlots -ne `$heldSlots) { return `$true }" "if (`$false) { return `$true }" {[bool](Get-SettingsMutant -Saved $heldAdd -Held (Copy-Held $heldAdd @{slots=2}))})) 'mutation: dirty ignoring slots fails the dirty-slots check'
Check (-not (Test-SettingsMutant 'Get-FastLlmUiSettingsAdditionsView' '[bool]($EmbeddingsAvailable -or ($SavedEmbeddings -ceq ''on''))' '$true' {-not (Get-SettingsMutant -EmbeddingsAvailable $false -SavedEmbeddings 'off' -LongMeasured $false -SavedContextProfile 'default' -TwoMeasured $false -SavedSlots 1 -ContextSize 0)['showEmbeddings']})) 'mutation: showEmbeddings unconditional fails the neither-state check'
Check (-not (Test-SettingsMutant 'Get-FastLlmUiSettingsAdditionsView' '-or ($SavedContextProfile -ceq ''long''))' ')' {(Get-SettingsMutant -EmbeddingsAvailable $false -SavedEmbeddings 'off' -LongMeasured $false -SavedContextProfile 'long' -TwoMeasured $false -SavedSlots 1 -ContextSize 0)['longEnabled']})) 'mutation: longEnabled ignoring the saved value fails the saved-long check'
Check (-not (Test-SettingsMutant 'Get-FastLlmUiSettingsAdditionsView' '-or ($SavedSlots -eq 2))' ')' {(Get-SettingsMutant -EmbeddingsAvailable $false -SavedEmbeddings 'off' -LongMeasured $false -SavedContextProfile 'default' -TwoMeasured $false -SavedSlots 2 -ContextSize 0)['twoEnabled']})) 'mutation: twoEnabled ignoring the saved 2 fails the saved-2 check'
Check (-not (Test-SettingsMutant 'Get-FastLlmUiSettingsAdditionsView' '$twoEnabled = [bool](($TwoMeasured -and $catalogContext)' '$twoEnabled = [bool](($true -and $catalogContext)' {-not (Get-SettingsMutant -EmbeddingsAvailable $false -SavedEmbeddings 'off' -LongMeasured $false -SavedContextProfile 'default' -TwoMeasured $false -SavedSlots 1 -ContextSize 0)['twoEnabled']})) 'mutation: item 2 always enabled fails the unmeasured-2 check'
Check (-not (Test-SettingsMutant 'Get-FastLlmUiSettingsAdditionsView' '$longEnabled = [bool](($LongMeasured -and $catalogContext)' '$longEnabled = [bool](($LongMeasured)' {-not (Get-SettingsMutant -EmbeddingsAvailable $false -SavedEmbeddings 'off' -LongMeasured $true -SavedContextProfile 'default' -TwoMeasured $true -SavedSlots 1 -ContextSize 4096)['longEnabled']})) 'mutation: the Long context condition dropped fails the context check'
Check (-not (Test-SettingsMutant 'Get-FastLlmUiSettingsAdditionsView' '$twoEnabled = [bool](($TwoMeasured -and $catalogContext)' '$twoEnabled = [bool](($TwoMeasured)' {-not (Get-SettingsMutant -EmbeddingsAvailable $false -SavedEmbeddings 'off' -LongMeasured $true -SavedContextProfile 'default' -TwoMeasured $true -SavedSlots 1 -ContextSize 4096)['twoEnabled']})) 'mutation: the 2 context condition dropped fails the context check'
Check (-not (Test-SettingsMutant 'Get-FastLlmUiSettingsAdditionsView' "if (-not `$catalogContext) { `$longReason = 'needs-catalog-context' }" "if (`$false) { `$longReason = 'needs-catalog-context' }" {(Get-SettingsMutant -EmbeddingsAvailable $false -SavedEmbeddings 'off' -LongMeasured $false -SavedContextProfile 'default' -TwoMeasured $false -SavedSlots 1 -ContextSize 4096)['longReasonCode'] -ceq 'needs-catalog-context'})) 'mutation: wrong reason precedence (not-measured wins) fails the precedence check'
Check (-not (Test-SettingsMutant 'Get-FastLlmUiSettingsSavedNote' "return 'The new embeddings setting applies at the next start.'" "return ''" {(Get-SettingsMutant -RunActive $true -Before $noteBase -After (New-NoteSide @{embeddings='on'})) -ceq 'The new embeddings setting applies at the next start.'})) 'mutation: the embeddings note missing fails the note check'
# The normalisations above can fail: each mutant keeps the out-of-range saved value as it is (control: an unchanged copy passes).
Check (Test-SettingsMutant 'ConvertTo-FastLlmUiSettingsHeld' "-and [int]`$Current.slots -eq 2) { 2 } else { 1 }" "-and [int]`$Current.slots -eq 2) { 2 } else { 1 }" {[int](Get-SettingsMutant -Current (New-SettingsCurrent @{slots=3})).slots -eq 1}) 'control: an unchanged held conversion maps a saved slots 3 to 1'
Check (-not (Test-SettingsMutant 'ConvertTo-FastLlmUiSettingsHeld' "if (`$Current.PSObject.Properties['slots'] -and [int]`$Current.slots -eq 2) { 2 } else { 1 }" "if (`$Current.PSObject.Properties['slots']) { [int]`$Current.slots } else { 1 }" {[int](Get-SettingsMutant -Current (New-SettingsCurrent @{slots=3})).slots -eq 1})) 'mutation: a held conversion that keeps a saved slots 3 fails'
Check (-not (Test-SettingsMutant 'ConvertTo-FastLlmUiSettingsHeld' "if (`$Current.PSObject.Properties['contextProfile'] -and [string]`$Current.contextProfile -ceq 'long') { 'long' } else { 'default' }" "if (`$Current.PSObject.Properties['contextProfile']) { [string]`$Current.contextProfile } else { 'default' }" {[string](Get-SettingsMutant -Current (New-SettingsCurrent @{contextProfile='weird'})).contextProfile -ceq 'default'})) 'mutation: a held conversion that keeps a saved contextProfile weird fails'
Check (-not (Test-SettingsMutant 'ConvertTo-FastLlmUiSettingsHeld' "if (`$Current.PSObject.Properties['embeddings'] -and [string]`$Current.embeddings -ceq 'on') { 'on' } else { 'off' }" "if (`$Current.PSObject.Properties['embeddings']) { [string]`$Current.embeddings } else { 'off' }" {[string](Get-SettingsMutant -Current (New-SettingsCurrent @{embeddings='maybe'})).embeddings -ceq 'off'})) 'mutation: a held conversion that keeps a saved embeddings maybe fails'
Check (-not (Test-SettingsMutant 'ConvertTo-FastLlmUiSettingsHeld' "if (`$Current.PSObject.Properties['embeddingPort']) { [int]`$Current.embeddingPort } else { 8081 }" "if (`$Current.PSObject.Properties['embeddingPort']) { [int]`$Current.embeddingPort } else { 0 }" {[int](Get-SettingsMutant -Current (New-SettingsCurrent)).embeddingPort -eq 8081})) 'mutation: a held conversion that gives a missing embeddingPort another value fails'

# ===== PR 4a: the dialog key plan (Enter, Escape and the close box of a message box), against the box-kind table =====
# The table of the plan's Global Constraints, written out: kind/default -> order, Enter, Escape, close box answer, close box enabled.
$planTable=@(
    @{b='OK';d='Button1';order='OK';enter='OK';escape='OK';close='OK';closeEnabled=$true}
    @{b='OK';d='Button2';order='OK';enter='OK';escape='OK';close='OK';closeEnabled=$true}
    @{b='OKCancel';d='Button1';order='OK,Cancel';enter='OK';escape='Cancel';close='Cancel';closeEnabled=$true}
    @{b='OKCancel';d='Button2';order='OK,Cancel';enter='Cancel';escape='Cancel';close='Cancel';closeEnabled=$true}
    @{b='YesNo';d='Button1';order='Yes,No';enter='Yes';escape='';close='';closeEnabled=$false}
    @{b='YesNo';d='Button2';order='Yes,No';enter='No';escape='';close='';closeEnabled=$false}
)
function Get-KeyPlanProblems([scriptblock]$Plan){
    $bad=New-Object System.Collections.ArrayList
    foreach($row in $planTable){
        $p=& $Plan -Buttons $row.b -DefaultButton $row.d
        $got=((@($p['order']) -join ',')+'|'+$p['enter']+'|'+$p['escape']+'|'+$p['close']+'|'+$p['closeEnabled'])
        $want=($row.order+'|'+$row.enter+'|'+$row.escape+'|'+$row.close+'|'+$row.closeEnabled)
        if($got -cne $want){[void]$bad.Add("$($row.b)/$($row.d) got $got want $want")}
    }
    $noDefault=& $Plan -Buttons 'YesNo'
    if($noDefault['enter'] -cne 'Yes'){[void]$bad.Add('a call with no default argument is not Button1 (YesNo Enter is not Yes)')}
    return ,@($bad.ToArray())
}
$planProblems=Get-KeyPlanProblems ${function:Get-FastLlmUiDialogKeyPlan}
Check ($planProblems.Count -eq 0) ('the key plan equals the box-kind table for every kind and default button: '+($planProblems -join ' | '))
foreach($row in $planTable){
    $p=Get-FastLlmUiDialogKeyPlan -Buttons $row.b -DefaultButton $row.d
    Check (@($p['order']|Where-Object{$_ -ceq $p['enter']}).Count -eq 1) "the Enter target of $($row.b)/$($row.d) is one of its buttons"
    Check ($p['escape'] -ceq '' -or @($p['order']|Where-Object{$_ -ceq $p['escape']}).Count -eq 1) "the Escape target of $($row.b)/$($row.d) is one of its buttons or nothing"
    Check ($p['closeEnabled'] -is [bool]) "closeEnabled of $($row.b)/$($row.d) is exactly one bool"
}
Check ((Get-FastLlmUiDialogKeyPlan -Buttons 'YesNo' -DefaultButton 'Button1')['escape'] -ceq '' -and -not (Get-FastLlmUiDialogKeyPlan -Buttons 'YesNo')['closeEnabled']) 'a YesNo box has no Escape answer and its close box is disabled'
Check ((Get-FastLlmUiDialogKeyPlan -Buttons 'OK')['escape'] -ceq 'OK') 'an OK box answers OK on Escape'
$threw=$false; try{$null=Get-FastLlmUiDialogKeyPlan -Buttons 'YesNoCancel'}catch{$threw=$true}
Check $threw 'an unsupported button set is refused'
# Mutants on scratch copies of the function: each must fail the table check above.
function Test-KeyPlanMutant([string]$From,[string]$To){
    $text=${function:Get-FastLlmUiDialogKeyPlan}.ToString()
    if(-not $text.Contains($From)){throw "FAIL: mutation anchor missing in the key plan: $From"}
    $mutant=[scriptblock]::Create($text.Replace($From,$To))
    return (Get-KeyPlanProblems $mutant).Count
}
# CONTROL: an unchanged copy through the same mutation path gives exactly 0 key-plan problems.
Check ((Test-KeyPlanMutant "closeEnabled=`$false" "closeEnabled=`$false") -eq 0) 'control: an unchanged copy of the key plan has no table problems through the mutation path'
Check ((Test-KeyPlanMutant "order=[string[]]@('Yes','No'); enter=`$enter; escape=''" "order=[string[]]@('Yes','No'); enter=`$enter; escape='No'") -gt 0) 'mutation: a YesNo box answering No on Escape fails the key-plan table'
Check ((Test-KeyPlanMutant "`$enter='Yes'; if(`$second){`$enter='No'}" "`$enter='Yes'") -gt 0) 'mutation: Button2 on a YesNo box answering Yes on Enter fails the key-plan table'
Check ((Test-KeyPlanMutant "closeEnabled=`$false" "closeEnabled=`$true") -gt 0) 'mutation: an enabled YesNo close box fails the key-plan table'
Check ((Test-KeyPlanMutant "`$enter='OK'; if(`$second){`$enter='Cancel'}" "`$enter='OK'") -gt 0) 'mutation: Button2 on an OKCancel box answering OK on Enter fails the key-plan table'
Check ((Test-KeyPlanMutant "escape='Cancel'; close='Cancel'" "escape='OK'; close='OK'") -gt 0) 'mutation: an OKCancel box answering OK on Escape fails the key-plan table'
# ===== end PR 4a: the dialog key plan =====

Write-Host "UI control states tests passed: $checks"
exit 0
