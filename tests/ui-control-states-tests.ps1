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

Write-Host "UI control states tests passed: $checks"
exit 0
