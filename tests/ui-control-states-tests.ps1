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
$reasonActions=@('diagnostics','driverGuidance','saveBundle','backgroundCheck','backgroundAttach','apiCheck')
function Get-ReasonPropertyFailures([string]$Fn,[switch]$First){
    $bad=New-Object System.Collections.ArrayList
    foreach($r in $matrix){
        $snap=New-RowSnapshot $r
        $states=Get-FastLlmUiControlStates -Snapshot $snap
        $api=Get-FastLlmUiSnapshotAvailability -Snapshot $snap
        foreach($a in $reasonActions){
            foreach($running in @($true,$false)){
                if($a -ceq 'apiCheck'){$enabled=[bool]($running -and $api.apiCheck)}else{if(-not $running){continue};$enabled=[bool]$states.$a}
                $code=[string](& $Fn -Action $a -Snapshot $snap -ConnectRunning $running)
                if(($code -ceq '') -ne $enabled){[void]$bad.Add($r.key+' '+$a+' running='+$running+' code='+$code+' enabled='+$enabled);if($First){return ,$bad}}
            }
        }
    }
    return ,$bad
}
$reasonBad=Get-ReasonPropertyFailures 'Get-FastLlmUiGreyedReason'
Check ($reasonBad.Count -eq 0) ('a greyed-reason code is empty exactly when the control state is true on every row (first: '+((@($reasonBad)|Select-Object -First 3) -join ' | ')+')')
$codeSet=@('','microsoft-setup','busy','side-step','attached','no-run','not-running')
$unknownCodes=@(foreach($r in $matrix){$s=New-RowSnapshot $r;foreach($a in $reasonActions){$c=[string](Get-FastLlmUiGreyedReason -Action $a -Snapshot $s -ConnectRunning $true);if($codeSet -cnotcontains $c){$a+':'+$c}}})
Check ($unknownCodes.Count -eq 0) 'every greyed-reason code is one of the seven known codes'

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
# Mutation: a swapped sub-expression must make the property fail.
$fnText=${function:Get-FastLlmUiGreyedReason}.ToString()
function Test-ReasonMutant([string]$From,[string]$To){
    if(-not $fnText.Contains($From)){throw "FAIL: mutation anchor missing: $From"}
    Set-Item -Path function:script:Get-ReasonMutant -Value ([scriptblock]::Create($fnText.Replace($From,$To)))
    return (Get-ReasonPropertyFailures 'Get-ReasonMutant' -First).Count
}
Check ((Test-ReasonMutant "if (`$bg.attachedRequestId) { return 'attached' }" "if (`$false) { return 'attached' }") -gt 0) 'mutation: dropping the attached rule fails the property'
Check ((Test-ReasonMutant 'if ($availability.saveBundle) { return '''' }' 'if (-not $availability.saveBundle) { return '''' }') -gt 0) 'mutation: swapping the bundle availability sub-expression fails the property'
Check ((Test-ReasonMutant 'if ($busy -or $Snapshot.ChildActive)' 'if ($busy)') -gt 0) 'mutation: dropping ChildActive from the busy rules fails the property'

# The matrix has no attachable run with a case-different pending id, so this mutant is caught by the direct case row.
$ceqFrom='-ceq [string]$bg.pendingRequestId'
Check ($fnText.Contains($ceqFrom)) 'the case-sensitive request comparison anchor is present'
Set-Item -Path function:script:Get-ReasonMutant -Value ([scriptblock]::Create($fnText.Replace($ceqFrom,'-eq [string]$bg.pendingRequestId')))
Check ((Get-ReasonMutant -Action 'backgroundAttach' -Snapshot $caseSnap) -cne 'no-run') 'mutation: a case-insensitive request comparison fails the case row'

Write-Host "UI control states tests passed: $checks"
exit 0
