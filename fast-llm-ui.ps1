#requires -Version 5.1
param([string]$InstallRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
if ($env:OS -ne 'Windows_NT') { throw 'The control window requires Windows PowerShell on Windows.' }
$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Open FastLLM as a standard user, not as administrator.' }
$labAppLifetime=$null
try {
. (Join-Path $PSScriptRoot 'src/FastLlm.LabApp.ps1')
$labAppLifetime=Enter-FastLlmLabAppLifetime -SourceRoot $PSScriptRoot
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Import-Module (Join-Path $PSScriptRoot 'src/FastLlm.psm1') -Force
. (Join-Path $PSScriptRoot 'src/FastLlm.UiFlow.ps1')
. (Join-Path $PSScriptRoot 'src/FastLlm.UiPrerequisite.ps1')
. (Join-Path $PSScriptRoot 'src/FastLlm.UiBackground.ps1')
. (Join-Path $PSScriptRoot 'src/FastLlm.UiState.ps1')
# Update and Trust are dot-sourced here, never imported through FastLlm.psm1.
. (Join-Path $PSScriptRoot 'src/FastLlm.Update.ps1')
# Components (the experimental switch and the list helpers) is dot-sourced here and in fast-llm.ps1, never imported through FastLlm.psm1.
. (Join-Path $PSScriptRoot 'src/FastLlm.Components.ps1')
# Serving settings (port) is dot-sourced here and in fast-llm.ps1, never imported through FastLlm.psm1.
. (Join-Path $PSScriptRoot 'src/FastLlm.ServingSettings.ps1')
# Start at sign-in: only the Settings checkbox (a user click) ever turns it on; no start path registers it.
. (Join-Path $PSScriptRoot 'src/FastLlm.SignInStart.ps1')
# The support bundle (reads settings.json) is dot-sourced here and in fast-llm.ps1, never imported through FastLlm.psm1.
. (Join-Path $PSScriptRoot 'src/FastLlm.SupportBundle.ps1')
# Connection info and the API-format check are dot-sourced here and in fast-llm.ps1, never imported through FastLlm.psm1.
. (Join-Path $PSScriptRoot 'src/FastLlm.ConnectInfo.ps1')
& (Get-Module FastLlm) { Initialize-FastLlmProcessHost }
if (-not $InstallRoot) { $InstallRoot=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Bitworks\FastLLM' }
# The Fluent window is checked before anything else is built; an unsupported PC opens no window.
. (Join-Path $PSScriptRoot 'src/FastLlm.UiFluentShell.ps1'); $fluentSupport=Test-FastLlmUiFluentHost; if (-not $fluentSupport.supported) { Show-FastLlmUiUnsupported -Reason $fluentSupport.reason -InstallRoot $InstallRoot -Folder $PSScriptRoot; exit 3 }
$catalog=Get-FastLlmCatalog (Join-Path $PSScriptRoot 'config/catalog.json')
# The UI settings file lives under the launch root only (never the editable folder box), so it is read and written from the same place.
$script:settingsRoot=$InstallRoot
$script:child=$null; $script:step='idle'; $script:selection=@(); $script:installPath=$InstallRoot; $script:flow=$null
$script:vcBroker=$null; $script:vcPrepared=$null
$script:vcCacheRoot=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Bitworks\FastLLM\prerequisites'
$script:vcManifestPath=Join-Path $PSScriptRoot 'config/windows-prerequisites.json'
$script:trayState=New-FastLlmUiTrayState; $script:trayIcon=$null; $script:trayMenu=$null
$script:bgState=New-FastLlmUiBackgroundState; $script:bgNextPollUtc=[DateTime]::MinValue
$script:bgStopRequested=$false
$script:bgEndedByUserStop=$false
$script:bgPoll=$null
$script:startupRun=$null; $script:updateRun=$null; $script:updateOffer=$null; $script:reinstallOffer=$null; $script:updateOutcome=$false; $script:bannerUrl=$null
$script:barValues=@('auto','on','off')
$script:uiSettings=Read-FastLlmUiSettings -InstallRoot $script:settingsRoot -AppRoot $PSScriptRoot
$script:lastUserStoppedRequestId=[string]$script:uiSettings.lastUserStoppedBackgroundRequestId
# Saved or cleared with the background run the user stopped; a failed write only means the cautious text later.
function SaveUserStoppedBackgroundRequestId([string]$RequestId) {
    $script:lastUserStoppedRequestId=$RequestId
    try{Write-FastLlmUiSettings -InstallRoot $script:settingsRoot -Settings ([pscustomobject]@{vulkanBarMitigation=(GetBarValue);lastUserStoppedBackgroundRequestId=$RequestId})}catch{}
}
function GetBarValue { return [string]$script:barValues[[Math]::Max(0,$barBox.SelectedIndex)] }
$script:chatUrl=$null
# A read-only side step (API check, support bundle) runs in its own slot, so a serving child keeps $script:child and $script:step to itself.
$script:sideChild=$null;$script:sideStep='idle';$script:runReady=$false;$script:servingSettingsNotice=''
# A chooser pick is pinned for the preview and the start of that workflow only; the plain Install / Start buttons clear it.
$script:previewReady=$false
$script:chosenRecipe=$null
$script:pendingRecipeRow=$null
$script:servingPreviousRunId='';$script:bundlePath=''
$script:identifiedVariant=''
$script:chooserNotice=''
$script:switchGap=$false
$script:evidenceUrl=$null
# "Copy full output": shown only while a failure from a child's capture is held; the copy is the raw capture, unchanged.
$script:failureCapture=$null
$script:failureHeld=$false;$script:failureViewText=''
function ClearFailureCapture {$script:failureCapture=$null;$script:failureHeld=$false;$script:failureViewText='';$failureCopyLink.Visible=$false}
function SetFailureCapture([string]$Capture) {$script:failureCapture=$Capture;$failureCopyLink.Visible=-not [string]::IsNullOrEmpty($Capture)}
$script:servingNotesDone=$false
# A new foreground start flow drops the previous run's notes and links so the preview does not show them.
function ClearPreviousRunNotes {$notesLabel.Text='';$resultsLink.Visible=$false;$barLink.Visible=$false;$script:evidenceUrl=$null;$script:servingNotesDone=$false}
$script:licenseRevert=$false
$script:fallbackRequest='';$script:setupNotice='';$script:planComponentInstall=$false
$script:uiDialogView=$null
Initialize-FastLlmUiFluentShell
function ShowUiMessageBox($Owner,[string]$Text,[string]$Caption,[string]$Buttons='OK',[string]$Icon='None',[string]$DefaultButton='Button1'){
    return & $script:uiDialogView['MessageBox'] -Owner $Owner -Text $Text -Caption $Caption -Buttons $Buttons -Icon $Icon -DefaultButton $DefaultButton
}
function SetUiBanner([string]$Text,[string]$Url,[bool]$IsError,[bool]$CanUpdate) {
    $script:bannerUrl=$Url
    if([string]::IsNullOrEmpty($Text)){$bannerLabel.Visible=$false;$bannerNotes.Visible=$false;$bannerButton.Visible=$false;return}
    $bannerLabel.Text=$Text
    $bannerLabel.Width=[Windows.Forms.TextRenderer]::MeasureText($Text,$bannerLabel.Font).Width+10
    $bannerLabel.ForeColor=if($IsError){[Drawing.Color]::Firebrick}else{[Drawing.SystemColors]::ControlText}
    $bannerLabel.Visible=$true
    $next=$bannerLabel.Right+8
    $bannerNotes.Text=if($IsError){'Releases page'}else{'Release notes'}
    $bannerNotes.Left=$next
    $bannerNotes.Visible=[bool]$Url
    if($Url){$next=$next+[Windows.Forms.TextRenderer]::MeasureText($bannerNotes.Text,$bannerNotes.Font).Width+24}
    $bannerButton.Left=$next
    $bannerButton.Visible=$CanUpdate
}
$vc.Add_LinkClicked({try{Start-Process 'https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist'}catch{$null=ShowUiMessageBox $form 'Unable to open Microsoft''s prerequisite page. Check your default browser. No software was installed.' 'Open prerequisite page' 'OK' 'Warning'}})
$amd.Add_LinkClicked({try{Start-Process 'https://www.amd.com/en/support/download/drivers.html'}catch{$null=ShowUiMessageBox $form 'Unable to open AMD''s driver page. Check your default browser. No driver changes were made.' 'Open AMD page' 'OK' 'Warning'}})
$failureCopyLink.Add_LinkClicked({try{[Windows.Forms.Clipboard]::SetText([string]$script:failureCapture)}catch{$statusLabel.Text='Could not copy: '+$_.Exception.Message}})
$resultsLink.Add_LinkClicked({
    try{
        $checked=Get-FastLlmUiEvidenceUrl -Plan ([pscustomobject]@{recipe=[pscustomobject]@{evidenceUrl=$script:evidenceUrl}})
        if($checked){Start-Process ([string]$checked)}
    }catch{$null=ShowUiMessageBox $form 'Unable to open the results page. Check your default browser.' 'Open results page' 'OK' 'Warning'}
})
$barLink.Add_LinkClicked({try{Start-Process 'https://github.com/bitworks-io/amd-inference/blob/main/docs/RESIZABLE-BAR.md'}catch{$null=ShowUiMessageBox $form 'Unable to open the Resizable BAR page. Check your default browser.' 'Open Resizable BAR page' 'OK' 'Warning'}})
$barBox.Add_SelectedIndexChanged({
    try{Write-FastLlmUiSettings -InstallRoot $script:settingsRoot -Settings ([pscustomobject]@{vulkanBarMitigation=(GetBarValue)})}
    catch{$statusLabel.Text='The Resizable BAR setting could not be saved.'}
})
$bannerNotes.Add_LinkClicked({
    try{
        $target=[string]$script:bannerUrl
        if($target.StartsWith('https://github.com/bitworks-io/amd-inference/releases',[StringComparison]::Ordinal)){Start-Process $target}
    }catch{$null=ShowUiMessageBox $form 'Unable to open the release page. Check your default browser.' 'Open release page' 'OK' 'Warning'}
})
$updateBox.Add_CheckedChanged({
    try{Set-FastLlmUpdateSettings -InstallRoot $script:settingsRoot -UpdateCheck $(if($updateBox.Checked){'on'}else{'off'})}
    catch{$statusLabel.Text='The update setting could not be saved.'}
})
# Turning the switch on shows the spec 2.7 paragraph in a Yes/No confirmation (default No); No leaves it off. Turning it off needs no confirmation.
$experimentalBox.Add_CheckedChanged({
    if($script:experimentalRevert){return}
    $wanted=if($experimentalBox.Checked){'on'}else{'off'}
    # What the box showed before this change; the stored value is rolled back to it with the box when the setting cannot be applied.
    $previousValue=if($wanted -ceq 'on'){'off'}else{'on'}
    try{
        if($wanted -ceq 'on'){
            $answer=ShowUiMessageBox $form $script:FastLlmExperimentalParagraph 'Experimental community components' 'YesNo' 'Warning' 'Button2'
            if($answer -ne [Windows.Forms.DialogResult]::Yes){
                $script:experimentalRevert=$true;$experimentalBox.Checked=$false;$script:experimentalRevert=$false
                return
            }
        }
        # The CLI children read the switch from the install folder shown in the window, so it is stored under the launch root and mirrored there.
        Set-FastLlmExperimentalSwitchMirrored -SourceRoot $script:settingsRoot -TargetRoot ([IO.Path]::GetFullPath($pathBox.Text)) -Value $wanted
    }
    catch{
        $statusLabel.Text='The experimental components setting could not be saved: '+$_.Exception.Message
        $script:experimentalRevert=$true;$experimentalBox.Checked=($previousValue -ceq 'on');$script:experimentalRevert=$false
    }
})
function ShowLicenseSettingConfirm($Disclosure) {
    return & $script:uiDialogView['ShowLicenseSettingConfirm'] -Disclosure $Disclosure
}
# The CLI children read the setting from the install folder shown in the window, so it is stored under the launch root and mirrored there. Cancel,
# or any failure, puts the box back to what it showed.
$licenseBox.Add_CheckedChanged({
    if($script:licenseRevert){return}
    $wantedOn=[bool]$licenseBox.Checked
    try{
        $target=[IO.Path]::GetFullPath($pathBox.Text)
        if($wantedOn){
            $disclosure=Get-FastLlmUiLicenseDisclosure -Components @(Get-FastLlmComponents -ComponentsPath (Join-Path $PSScriptRoot 'config/components.json'))
            if(-not (ShowLicenseSettingConfirm $disclosure)){
                $script:licenseRevert=$true;$licenseBox.Checked=$false;$script:licenseRevert=$false
                return
            }
            Set-FastLlmComponentLicenseSettingMirrored -SourceRoot $script:settingsRoot -TargetRoot $target -Mode 'accept-automatically' -Accepted @($disclosure.identities) -AcceptedAt ((Get-Date).ToUniversalTime().ToString('o'))
            # The user has changed their mind about the licenses, so earlier declines no longer apply.
            try{Clear-FastLlmUiDeclinedSetups -InstallRoot $script:settingsRoot}catch{}
        }else{
            Set-FastLlmComponentLicenseSettingMirrored -SourceRoot $script:settingsRoot -TargetRoot $target -Mode 'ask'
        }
    }
    catch{
        $statusLabel.Text='The automatic install setting could not be saved: '+$_.Exception.Message
        # Turning it off always stays off (the launch folder says ask); only a failed turn-on goes back to unticked.
        $script:licenseRevert=$true;$licenseBox.Checked=$false;$script:licenseRevert=$false
    }
})
# The one observation of everything the enable rules read; the rules themselves are in src/FastLlm.UiState.ps1.
function GetUiStateSnapshot([bool]$Busy) {
    $updateKind=if($null -eq $script:updateRun){''}else{[string]$script:updateRun.kind}
    return New-FastLlmUiStateSnapshot -Busy $Busy -UpdateKind $updateKind -ChildActive ([bool]$script:child) -Step ([string]$script:step) `
        -RunReady ([bool]$script:runReady) -SideChildActive ([bool]$script:sideChild) -VcBrokerActive ($null -ne $script:vcBroker) `
        -PreviewReady ([bool]$script:previewReady) -SwitchGap ([bool]$script:switchGap) -ChatUrlSet ([bool]$script:chatUrl) `
        -BackgroundStopRequested ([bool]$script:bgStopRequested) -Background $script:bgState `
        -FailureHeld ([bool]$script:failureHeld) -FlowPhase ([string]$(if($script:flow){$script:flow.phase}))
}
function SetBusy([bool]$Busy) {
    $states=Get-FastLlmUiControlStates -Snapshot (GetUiStateSnapshot $Busy)
    $installButton.Enabled=$states.install
    $startButton.Enabled=$states.start
    $modelBox.Enabled=$states.model
    $pathBox.Enabled=$states.path
    $contextBox.Enabled=$states.context
    $barBox.Enabled=$states.bar
    $doctorButton.Enabled=$states.diagnostics
    $driverButton.Enabled=$states.driverGuidance
    # A ready server (foreground or background) does not lock Settings or the support bundle; a launch, install, update or Microsoft setup does.
    $settingsButton.Enabled=$states.settings
    $bundleButton.Enabled=$states.saveBundle
    $chooseButton.Enabled=$states.chooseSetup
    $backgroundStartButton.Enabled=$states.backgroundStart
    $backgroundAttachButton.Enabled=$states.backgroundAttach
    $backgroundCheckButton.Enabled=$states.backgroundCheck
    $stopButton.Enabled=$states.stop
    $trayButton.Enabled=$states.tray
    $openChatButton.Enabled=$states.openChat
    $progress.Visible=$states.progressVisible
}
function GetUiActionAvailabilityNow([bool]$Busy) {
    return Get-FastLlmUiSnapshotAvailability -Snapshot (GetUiStateSnapshot $Busy)
}
# Reads the Open chat button and the ready flag from a run status (foreground child or background run). Returns $true when either changed.
function UpdateUiRunState($Status,[bool]$ForegroundChildActive) {
    $observation=$script:bgState.observation
    $chat=Get-FastLlmUiChatButtonState -Status $Status -ForegroundChildActive $ForegroundChildActive -BackgroundObservation $observation
    $ready=[bool](Test-FastLlmUiServingReady -Status $Status -ForegroundChildActive $ForegroundChildActive -BackgroundObservation $observation)
    $changed=([string]$script:chatUrl -cne [string]$chat.url) -or ([bool]$script:runReady -ne $ready)
    $script:chatUrl=$chat.url;$script:runReady=$ready
    return $changed
}
# The model switch controls follow the status the window already reads for this run (nothing extra is polled). The classification is Get-FastLlmUiSwitchWindowState.
function UpdateUiSwitchState($Status) {
    $switchState=Get-FastLlmUiSwitchWindowState -Status $Status -SettingOn ([bool]$script:uiSettings.allowSwitch)
    $script:switchGap=[bool]$switchState.gap
    $switchButton.Enabled=[bool]$switchState.switchButtonEnabled
    $switchLabel.Text=$(if($switchState.gap){''}elseif($switchState.line){[string]$switchState.line}elseif($switchState.switchButtonEnabled){''}else{[string]$switchState.switchButtonReason})
    if($switchState.gap){$statusLabel.Text=[string]$switchState.statusText}
}
function RefreshUiSwitchState {
    try{UpdateUiSwitchState (GetUiBackgroundRunStatus)}catch{UpdateUiSwitchState $null}
}
function GetUiBackgroundStatus([switch]$SkipHealth) {
    return & (Get-Module FastLlm) {param($Source,$Install,$Project,$Skip)
        . $Source
        Get-FastLlmBackgroundHostStatus -InstallRoot $Install -SourceRoot $Project -SkipHealth:$Skip
    } (Join-Path $PSScriptRoot 'src/FastLlm.BackgroundHost.ps1') $script:installPath $PSScriptRoot ([bool]$SkipHealth)
}
function TestUiBackgroundProcess($Identity) {
    try{
        $process=[Diagnostics.Process]::GetProcessById([int]$Identity.pid)
        try{return -not $process.HasExited -and $process.StartTime.ToUniversalTime().Ticks -eq [long]$Identity.startUtcTicks}
        finally{$process.Dispose()}
    }catch{return $false}
}
function GetUiBackgroundRunStatus {
    try{return Get-FastLlmStatus $script:installPath}catch{return $null}
}
function ApplyUiBackgroundStatus($observation,[bool]$HealthChecked=$false) {
    $wasAttached=[bool]$script:bgState.attachedRequestId
    $attachedBeforeId=[string]$script:bgState.attachedRequestId
    $wasPending=[bool]$script:bgState.pendingRequestId
    $observation | Add-Member -NotePropertyName uiHealthChecked -NotePropertyValue $HealthChecked -Force
    $null=Set-FastLlmUiBackgroundObservation -State $script:bgState -Observation $observation -StopRequested:$script:bgStopRequested
    $null=Test-FastLlmUiBackgroundPendingHost -State $script:bgState -TestProcess {
        param($Identity) TestUiBackgroundProcess $Identity
    }
    $backgroundLabel.Text=Get-FastLlmUiBackgroundText -State $script:bgState -StopRequested:($script:bgStopRequested -or $script:bgEndedByUserStop) -LastUserStoppedRequestId $script:lastUserStoppedRequestId
    if($wasAttached -and -not $script:bgState.attachedRequestId -and $script:bgStopRequested -and $script:bgState.observation -and -not $script:bgState.observation.active){
        $script:bgEndedByUserStop=$true
        if($attachedBeforeId -cmatch '^[0-9a-f]{32}$'){SaveUserStoppedBackgroundRequestId $attachedBeforeId}
        $statusLabel.Text='Stopped. The background run ended.'
    }elseif($wasAttached -and -not $script:bgState.attachedRequestId -and $script:bgState.observation -and -not $script:bgState.observation.active -and
            $script:bgState.observation.PSObject.Properties['stopReason'] -and [string]$script:bgState.observation.stopReason -ceq 'idle'){
        $statusLabel.Text=Get-FastLlmUiIdleStopText -Minutes $script:bgState.observation.idleStopMinutes
    }elseif($wasAttached -and -not $script:bgState.attachedRequestId){
        $statusLabel.Text='Background run ended or changed. Its ownership has not been silently replaced.'
    }elseif($script:bgState.attachedRequestId -and $HealthChecked -and
            $script:bgState.observation.PSObject.Properties['servingHealthy'] -and
            -not $script:bgState.observation.servingHealthy){
        $statusLabel.Text='Background run owner is verified, but the API health check failed.'
    }elseif($script:bgState.attachedRequestId -and $HealthChecked -and $script:bgState.observation.attachable){
        $statusLabel.Text=Format-FastLlmUiBackgroundReadyStatus -Text 'Ready background inference attached. API health passed; GPU residency/performance unqualified.' -State (GetUiBackgroundRunStatus) -ApiKeyStore (GetUiApiKeyStore)
    }elseif($wasPending -and -not $script:bgState.pendingRequestId -and $script:bgState.attention){
        $statusLabel.Text='Background launch needs attention. Review Diagnostics before another start.'
    }
    if($script:bgState.observation -and -not $script:bgState.observation.active){$script:bgStopRequested=$false}
    # A foreground child owns the run state through the timer; the background poll must not clear it.
    if(-not $script:child){try{[void](UpdateUiRunState (GetUiBackgroundRunStatus) $false)}catch{$script:chatUrl=$null;$script:runReady=$false}}
    if(-not $script:child){RefreshUiSwitchState}
    SetBusy ([bool]($script:child -or $script:vcBroker))
}
function SetUiBackgroundUnknown {
    $script:chatUrl=$null;$script:runReady=$false
    $script:bgState.observation=[pscustomobject]@{phase='occupied-unverified';active=$false;attachable=$false;occupied=$true}
    $script:bgState.attention='Background ownership could not be verified. Review Diagnostics; start and stop are disabled.'
    $backgroundLabel.Text=Get-FastLlmUiBackgroundText -State $script:bgState -LastUserStoppedRequestId $script:lastUserStoppedRequestId
    SetBusy ([bool]($script:child -or $script:vcBroker))
}
function RefreshUiBackgroundStatus {
    try{ApplyUiBackgroundStatus (GetUiBackgroundStatus -SkipHealth)}catch{SetUiBackgroundUnknown}
}
function StartUiBackgroundPoll {
    if($script:bgPoll){return}
    $source=@'
param($Project,$Install,$CheckHealth)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $Project 'src/FastLlm.psm1') -Force
& (Get-Module FastLlm) {
    param($Core,$Project,$Install)
    . $Core
    Get-FastLlmBackgroundHostStatus -InstallRoot $Install -SourceRoot $Project -SkipHealth:(-not $CheckHealth)
} (Join-Path $Project 'src/FastLlm.BackgroundHost.ps1') $Project $Install
'@
    try{
        $script:bgPoll=Start-FastLlmUiBackgroundPoll -ScriptText $source -SourceRoot $PSScriptRoot `
            -InstallRoot $script:installPath -PendingRequestId $script:bgState.pendingRequestId `
            -AttachedRequestId $script:bgState.attachedRequestId -AttachedRunId $script:bgState.attachedRunId `
            -CheckHealth:([bool]$script:bgState.attachedRequestId)
    }catch{SetUiBackgroundUnknown}
}
function CompleteUiBackgroundPoll {
    if(-not $script:bgPoll){return}
    $result=Complete-FastLlmUiBackgroundPoll -Poll $script:bgPoll -SourceRoot $PSScriptRoot `
        -InstallRoot $script:installPath -PendingRequestId $script:bgState.pendingRequestId `
        -AttachedRequestId $script:bgState.attachedRequestId -AttachedRunId $script:bgState.attachedRunId
    if(-not $result.completed){return}
    $script:bgPoll=$null
    if($result.discarded){$script:bgNextPollUtc=[DateTime]::MinValue;return}
    try{
        if($result.error){throw $result.error}
        ApplyUiBackgroundStatus $result.observation ([bool]$script:bgState.attachedRequestId)
    }catch{SetUiBackgroundUnknown}
}
function AssertUiBackgroundNotOccupied {
    RefreshUiBackgroundStatus
    if($script:bgState.pendingRequestId -or $script:bgState.attachedRequestId -or
       $script:bgState.attention -or ($script:bgState.observation -and $script:bgState.observation.occupied)){
        throw 'Background ownership is active or unresolved. Attach or review Diagnostics before starting another workflow.'
    }
}
function GetVcCandidate {
    return & (Get-Module FastLlm) {param($Source,$Manifest)
        . $Source
        Get-FastLlmVcRedistCandidate -ManifestPath $Manifest
    } (Join-Path $PSScriptRoot 'src/FastLlm.VcRedist.ps1') $script:vcManifestPath
}
function GetVcInstallDecision($Inventory,$Candidate) {
    return & (Get-Module FastLlm) {param($Source,$Observed,$Version)
        . $Source
        Get-FastLlmVcRedistInstallDecision -Inventory $Observed -CandidateVersion $Version
    } (Join-Path $PSScriptRoot 'src/FastLlm.VcRedistInstall.ps1') $Inventory ([version]$Candidate.version)
}
function ReadSelection {
    # A new workflow starts without the last one's fallback request, notice or pending component install.
    $script:fallbackRequest='';$script:setupNotice='';$script:planComponentInstall=$false
    $script:installPath=[IO.Path]::GetFullPath($pathBox.Text)
    $script:selection=@('-InstallRoot',$script:installPath,'-ContextSize',[string][int]$contextBox.Value)
    if($modelBox.SelectedIndex -gt 0){$script:selection+=@('-ModelId',[string]$modelBox.SelectedItem)}
}
function LaunchStep([string]$Step,[object[]]$Arguments) {
    if(Test-FastLlmUiStepStartsRun -Step $Step){$script:bgEndedByUserStop=$false}
    ClearFailureCapture
    $script:updateOutcome=$false
    if($script:child){throw 'A child operation is already active.'}
    if($script:vcBroker){throw 'Microsoft prerequisite setup is still running.'}
    if($Step -in @('engine','model download','serving','component install')){AssertUiBackgroundNotOccupied}
    # The experimental switch is stored under the launch root, but the child reads it from the install folder it is given: mirror it there first.
    # A mirror failure blocks only the steps that read the switch.
    if($script:installPath){try{[void](Sync-FastLlmExperimentalSwitch -SourceRoot $script:settingsRoot -TargetRoot $script:installPath)}catch{if(Test-FastLlmUiStepReadsExperimentalSwitch -Arguments $Arguments){throw "The experimental components setting could not be applied to the install folder: $($_.Exception.Message)"}}}
    # The automatic-install setting is mirrored the same way; a mirror failure blocks only the steps that read it.
    if($script:installPath){try{[void](Sync-FastLlmComponentLicenseSetting -SourceRoot $script:settingsRoot -TargetRoot $script:installPath)}catch{if(Test-FastLlmUiStepReadsLicenseSetting -Arguments $Arguments){throw "The automatic install setting could not be applied to the install folder: $($_.Exception.Message)"}}}
    if($Step -ceq 'vc prepare'){
        if(@($Arguments).Count -ne 0){throw 'VC++ preparation accepts no arbitrary child arguments.'}
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=(Get-Process -Id $PID).Path
        $argsList=Get-FastLlmUiVcPrepareArguments -ProjectRoot $PSScriptRoot -CacheRoot $script:vcCacheRoot
        $info.Arguments=& (Get-Module FastLlm) {param($A) Join-FastLlmProcessArguments $A} $argsList
    }else{
        # A fast-llm.ps1 child: the one helper that also asks it for UTF-8 on stderr (see the helper's contract in src/FastLlm.UiFlow.ps1).
        $info=New-FastLlmUiCliStartInfo -AppRoot $PSScriptRoot -Arguments $Arguments
    }
    if($Step -ceq 'serving'){
        # Remember the previous run so a failure code left by an earlier run is never blamed on this start.
        $script:servingPreviousRunId=''
        try{$previousStatus=Get-FastLlmStatus $script:installPath;if($previousStatus.PSObject.Properties['runId']){$script:servingPreviousRunId=[string]$previousStatus.runId}}catch{}
    }
    $script:child=New-Object Bitworks.FastLlm.ProcessHost
    $script:step=$Step
    try{$script:child.Start($info)}catch{$script:child.Dispose();$script:child=$null;$script:step='idle';SetBusy $false;throw}
    SetBusy $true;$statusLabel.Text=$Step;$output.Text=''
    if($Step -ceq 'serving'){
        $script:servingNotesDone=$false;$notesLabel.Text='';$barLink.Visible=$false
        # A settings file that cannot be read means defaults; say so, as the background start does.
        $script:servingSettingsNotice=''
        try{$script:servingSettingsNotice=Get-FastLlmUiMalformedSettingsNotice -Settings (Get-FastLlmServingSettings -InstallRoot $script:installPath)}catch{}
        if($script:servingSettingsNotice){$notesLabel.Text=$script:servingSettingsNotice}
    }
}
# A read-only doctor step (API check, support bundle list and save) in its own process slot, so it never touches the serving child, its step
# or its output. One at a time. Results are shown in a dialog because the serving output box and status line are rewritten by the timer.
function LaunchSideStep([string]$Step,[object[]]$Arguments) {
    ClearFailureCapture
    if($Step -cnotin @('api check','bundle list','bundle save')){throw 'That step cannot run beside a server.'}
    if($script:sideChild){throw 'Another check is still running. Wait for it to finish.'}
    $info=New-FastLlmUiCliStartInfo -AppRoot $PSScriptRoot -Arguments $Arguments
    $script:sideChild=New-Object Bitworks.FastLlm.ProcessHost
    $script:sideStep=$Step
    try{$script:sideChild.Start($info)}catch{$script:sideChild.Dispose();$script:sideChild=$null;$script:sideStep='idle';SetBusy ([bool]($script:child -or $script:vcBroker));throw}
    SetBusy ([bool]($script:child -or $script:vcBroker))
    $statusLabel.Text=$(if($Step -ceq 'api check'){'Checking the API formats...'}else{'Preparing the support bundle...'})
}
function ShowUiSideResult([string]$Title,[string]$Text) {
    & $script:uiDialogView['ShowUiSideResult'] -Title $Title -Text $Text
}
function CompleteUiSideStep {
    if(-not $script:sideChild){return}
    if(-not $script:sideChild.Process.HasExited){return}
    $script:sideChild.Process.WaitForExit();$text=$script:sideChild.Snapshot();$code=$script:sideChild.Process.ExitCode;$step=$script:sideStep
    $script:sideChild.Dispose();$script:sideChild=$null;$script:sideStep='idle'
    SetBusy ([bool]($script:child -or $script:vcBroker))
    try{
        switch($step){
            'api check'{
                # Exit 1: at least one format failed (the table says which). Exit 2: the server was not Ready (the child printed a plain message).
                $checkResult=$null;try{$checkResult=ConvertFrom-Json $text}catch{}
                $shown=$(if($checkResult){Format-FastLlmApiCheckTable -Result $checkResult}else{$text})
                $statusLabel.Text=$(if($code -eq 0){'API format check finished.'}elseif($code -eq 1){'API format check finished: at least one format failed.'}else{'API format check did not run.'})
                ShowUiSideResult 'API format check' $shown
            }
            'bundle list'{
                if($code -ne 0){$statusLabel.Text='The support bundle could not be prepared. Nothing was saved.';ShowUiSideResult 'Save support bundle' $text;return}
                $statusLabel.Text='Support bundle contents listed.';ContinueSupportBundle $text
            }
            'bundle save'{
                if($code -ne 0){$statusLabel.Text='The support bundle could not be saved.';ShowUiSideResult 'Save support bundle' $text;return}
                $statusLabel.Text='Support bundle saved.'
                ShowUiSideResult 'Save support bundle' ('Saved to '+$script:bundlePath+[Environment]::NewLine+'FastLLM did not upload it. Share it only with people you trust.')
            }
        }
    }catch{$statusLabel.Text='The check could not be shown: '+$_.Exception.Message}
}
function RevealUiForAction {
    if($script:trayState.visibility -eq 'tray'){RestoreFromTray}
    if(-not $form.Visible){throw 'The control window could not be made visible for an action requiring attention.'}
}
function SetTrayMenuAvailable([bool]$Available) {
    if($script:trayMenu){
        foreach($item in $script:trayMenu.Items){
            $item.Enabled=Get-FastLlmUiTrayItemEnabled -ItemText ([string]$item.Text) -Available $Available -VcBrokerActive ($null -ne $script:vcBroker)
        }
    }
}
function ShowFailure($Message,[string]$Capture){
    try{RevealUiForAction}catch{[void][Windows.Forms.MessageBox]::Show('FastLLM needs attention, but the control window could not be restored.','FastLLM','OK','Warning')}
    $script:failureHeld=$true
    # A failure from a child's capture shows the capture without PowerShell's error-record details and keeps it whole for "Copy full output";
    # fixed window text shows as is and holds nothing.
    if($PSBoundParameters.ContainsKey('Capture')){$view=Get-FastLlmUiFailureView -Message ([string]$Message) -Capture $Capture}else{$view=Get-FastLlmUiFailureView -Message ([string]$Message)}
    $output.Text=[string]$view.text
    $script:failureViewText=[string]$view.text
    SetFailureCapture ([string]$view.capture)
    if($script:child -or $script:vcBroker){
        $statusLabel.Text=if($script:vcBroker){'Microsoft setup is still running. Complete or cancel it in the Microsoft window.'}
            else{'Action needs attention. The active operation remains supervised; use Stop if needed.'}
        SetBusy $true
    }else{
        $statusLabel.Text=if($script:bgState.attention -or
            ($script:bgState.observation -and $script:bgState.observation.occupied)){
            'Background ownership needs attention. Review Diagnostics before another start.'
        }else{'Action stopped. Review diagnostics; no compatibility claim was made.'}
        SetBusy $false
    }
}
function DisposeTrayControls {
    if($script:trayIcon){
        try{$script:trayIcon.Visible=$false}catch{}
        try{$script:trayIcon.Dispose()}catch{}
        $script:trayIcon=$null
    }
    if($script:trayMenu){try{$script:trayMenu.Dispose()}catch{};$script:trayMenu=$null}
}
# The tray icon: the stock application icon, or the drawn one in the Fluent window.
function GetUiTrayIcon { return Get-FastLlmUiFluentTrayIcon }
function EnsureTrayIcon {
    if($script:trayIcon){return}
    try{
        $script:trayMenu=New-Object Windows.Forms.ContextMenuStrip
        $restoreItem=$script:trayMenu.Items.Add('Restore FastLLM')
        $stopItem=$script:trayMenu.Items.Add('Stop inference / download')
        $exitItem=$script:trayMenu.Items.Add('Exit FastLLM')
        $restoreItem.Add_Click({try{RestoreFromTray}catch{[void][Windows.Forms.MessageBox]::Show('Unable to restore the FastLLM window.','FastLLM tray','OK','Warning')}})
        $stopItem.Add_Click({try{StopUiOperation}catch{$message=$_.Exception.Message;try{RestoreFromTray}catch{};ShowFailure $message}})
        $exitItem.Add_Click({try{ExitFromTray}catch{ShowFailure $_.Exception.Message}})
        $script:trayIcon=New-Object Windows.Forms.NotifyIcon
        $script:trayIcon.Icon=GetUiTrayIcon
        $script:trayIcon.Text='Bitworks FastLLM (Preview)'
        $script:trayIcon.ContextMenuStrip=$script:trayMenu
        $script:trayIcon.Add_DoubleClick({try{RestoreFromTray}catch{[void][Windows.Forms.MessageBox]::Show('Unable to restore the FastLLM window.','FastLLM tray','OK','Warning')}})
        $script:trayIcon.Visible=$true
        $script:trayState=Move-FastLlmUiTrayState -State $script:trayState -Event 'icon-ready'
    }catch{DisposeTrayControls;throw}
}
function MinimizeToTray {
    if(-not (Test-FastLlmUiVcActionAllowed -BrokerActive ($null -ne $script:vcBroker) -Action minimize)){
        throw 'Keep FastLLM visible while Microsoft prerequisite setup is running.'
    }
    EnsureTrayIcon
    try{
        $form.Hide()
        $script:trayState=Move-FastLlmUiTrayState -State $script:trayState -Event 'minimize'
    }catch{
        if(-not $form.Visible){$form.Show()}
        throw
    }
}
function RestoreFromTray {
    if($script:trayState.visibility -ne 'tray'){return}
    $form.Show();$form.WindowState=[Windows.Forms.FormWindowState]::Normal;$form.Activate()
    $script:trayState=Move-FastLlmUiTrayState -State $script:trayState -Event 'restore'
}
function ExitFromTray {
    if($script:trayState.visibility -eq 'tray'){RestoreFromTray}
    $form.Close()
}
function StopUiOperation {
    if(-not (Test-FastLlmUiVcActionAllowed -BrokerActive ($null -ne $script:vcBroker) -Action stop)){
        throw 'Microsoft prerequisite setup is still running. Complete or cancel it in the Microsoft window; FastLLM will not terminate it.'
    }
    if($script:switchGap -and -not $script:child -and -not $script:bgState.attachedRequestId){
        # Between the two runs of a model switch the supervisor is alive: stop always wins, and it is asked the way the stop command asks.
        Request-FastLlmStop -InstallRoot ([IO.Path]::GetFullPath($pathBox.Text))
        $statusLabel.Text='Stop requested. FastLLM ends the switch and stops.'
        return
    }
    if($script:child){
        $script:child.Dispose();$script:child=$null;$script:step='idle'
        $script:chatUrl=$null;$script:runReady=$false;UpdateUiSwitchState $null
        if($script:flow){$script:flow=Move-FastLlmUiFlow -Flow $script:flow -Event stop}
        RefreshUiBackgroundStatus
        $statusLabel.Text=if($script:bgState.observation.occupied){
            'Foreground action ended; background ownership still needs review.'
        }else{'Stopped. Completed downloads remain; partial downloads can resume.'}
        SetBusy $false
    }elseif($script:bgState.attachedRequestId){
        RefreshUiBackgroundStatus
        $result=Invoke-FastLlmUiBackgroundStop -State $script:bgState -Stop {
            param($ExpectedRequestId,$ExpectedRunId)
            & (Get-Module FastLlm) {param($Source,$Install,$Project,$Request,$Run)
                . $Source
                Stop-FastLlmBackgroundHost -InstallRoot $Install -SourceRoot $Project `
                    -ExpectedRequestId $Request -ExpectedRunId $Run
            } (Join-Path $PSScriptRoot 'src/FastLlm.BackgroundHost.ps1') $script:installPath $PSScriptRoot `
                $ExpectedRequestId $ExpectedRunId
        }
        $script:bgStopRequested=$true
        $statusLabel.Text='Stop requested for the exact attached background run. Waiting for it to end.'
        SetBusy $false
    }else{
        RefreshUiBackgroundStatus
        if($script:bgState.pendingRequestId -or $script:bgState.attention -or
           ($script:bgState.observation -and $script:bgState.observation.occupied)){
            throw 'Background ownership is unresolved. Attach the verified Ready run before requesting Stop.'
        }
        Request-FastLlmStop -InstallRoot ([IO.Path]::GetFullPath($pathBox.Text))
    }
}
function ShowSetupAttention($Decision,$Diagnostic) {
    return & $script:uiDialogView['ShowSetupAttention'] -Decision $Decision -Diagnostic $Diagnostic
}
function ShowVcInstallReview($Receipt,$Candidate) {
    return & $script:uiDialogView['ShowVcInstallReview'] -Receipt $Receipt -Candidate $Candidate
}
function StartVcBroker($Receipt) {
    if($script:child -or $script:vcBroker -or -not $script:flow -or $script:flow.phase -cne 'setup-attention'){
        throw 'Microsoft setup cannot start outside the pending prerequisite action.'
    }
    $result=& (Get-Module FastLlm) {param($PrepareSource,$InstallSource,$PreparedPath,$Manifest,$Cache)
        . $PrepareSource
        . $InstallSource
        Start-FastLlmVcRedistInstall -PreparedPath $PreparedPath -ManifestPath $Manifest -CacheRoot $Cache -ConfirmInstall
    } (Join-Path $PSScriptRoot 'src/FastLlm.VcRedist.ps1') `
      (Join-Path $PSScriptRoot 'src/FastLlm.VcRedistInstall.ps1') `
      ([string]$Receipt.path) $script:vcManifestPath $script:vcCacheRoot
    if($result.status -ceq 'uac-cancelled'){
        HandleVcBrokerResult $result
        return
    }
    if($result.status -cne 'in-progress' -or $null -eq $result.process){throw 'The Microsoft setup broker returned an invalid start result.'}
    $script:vcBroker=$result.process
    SetBusy $true;SetTrayMenuAvailable $false
    $statusLabel.Text='Microsoft prerequisite setup is running. Finish or cancel in the Microsoft window.'
    $output.Text='The elevated Microsoft prerequisite process remains independent of this control window. FastLLM will wait for its result and will not terminate it.'
}
function HandleVcBrokerResult($Result) {
    $outcome=Get-FastLlmUiVcCompletion -Result $Result
    $script:vcPrepared=$null
    $output.Text=$outcome.message
    if($outcome.action -ceq 'recheck'){
        $script:flow=Move-FastLlmUiFlow -Flow $script:flow -Event 'setup-recheck'
        LaunchUiPhase
    }else{
        $script:flow=Move-FastLlmUiFlow -Flow $script:flow -Event 'setup-defer'
        SetBusy $false;$statusLabel.Text='Microsoft prerequisite setup needs attention. Review the message and Recheck after resolving it.'
    }
}
function ShowExactModelConsent($Plan) {
    return & $script:uiDialogView['ShowExactModelConsent'] -Plan $Plan
}
function LaunchUiPhase {
    if(-not $script:flow){throw 'No active control-window workflow.'}
    switch($script:flow.phase){
        'setup' { LaunchStep 'setup check' (@('doctor','-Compact')+$script:selection);return }
        'engine' { LaunchStep 'engine' (@('install','-EngineOnly')+$script:selection);return }
        'preview' { LaunchStep 'preview' (@('plan','-AsJson')+@(Get-FastLlmUiRecipeSelection -Selection $script:selection -Recipe $script:chosenRecipe)+@(Get-FastLlmUiPreviewRecipeArguments -Recipe $script:chosenRecipe -FallbackRequest $script:fallbackRequest));return }
        'model-download' {
            $plan=$script:flow.pendingPlan
            if(-not $plan -or (Get-FastLlmUiModelProvenanceDigest -Model $plan.model) -cne $script:flow.pendingProvenance){
                throw 'The model changed after license review; no acquisition was started.'
            }
            $args=@('install','-ModelId',[string]$plan.model.id,'-ContextSize',[string]$plan.model.contextSize,'-InstallRoot',$script:installPath,'-Unattended')
            if($script:flow.acceptNewConsent){
                $args+=@('-AcceptModelLicense','-ExpectedModelProvenanceSha256',[string]$script:flow.pendingProvenance)
            }
            LaunchStep 'model download' $args
            return
        }
        'serving' {
            # The preview's label and link describe the preview only; clear them until the running plan reports its own.
            $resultsLink.Visible=$false;$script:evidenceUrl=$null
            $statusLabel.Text='Starting the server...'
            LaunchStep 'serving' (@('start','-Unattended','-VulkanBarMitigation',(GetBarValue))+@(Get-FastLlmUiStartRecipeArguments -Plan $script:flow.pendingPlan -ChosenRecipe $script:chosenRecipe -FallbackRequest $script:fallbackRequest)+@(Get-FastLlmUiRecipeSelection -Selection $script:selection -Recipe $script:chosenRecipe)+@(Get-FastLlmUiSwitchArguments -AllowSwitch (Get-FastLlmUiAllowSwitch -InstallRoot $script:settingsRoot)));return
        }
        default { throw "The control-window workflow cannot launch phase '$($script:flow.phase)'." }
    }
}
function RepreviewForPendingSetup([string]$Request) {
    $script:fallbackRequest=$Request
    $script:flow=Move-FastLlmUiFlow -Flow $script:flow -Event 'components-handled'
    if($script:flow.phase -eq 'failed'){ShowFailure $script:flow.lastStartError;return}
    LaunchUiPhase
    if($script:setupNotice){$statusLabel.Text=$script:setupNotice}
}
function HandlePendingSetup($Plan,$Decision) {
    switch($Decision.action){
        'fallback' {$script:setupNotice=[string]$Decision.notice;RepreviewForPendingSetup ([string]$Decision.fallbackRequest)}
        'install-now' {
            $installArgs=@(Get-FastLlmUiAutomaticInstallArguments -EngineId ([string]$Decision.engineId) -InstallRoot $script:installPath)
            if($installArgs.Count -eq 0){throw 'The engine components could not be identified; nothing was installed.'}
            $script:planComponentInstall=$true
            LaunchStep 'component install' $installArgs
        }
        default {
            $row=[pscustomobject]@{model=[string]$Plan.model.id;contextText=(([int]$Plan.model.contextSize).ToString('N0',[Globalization.CultureInfo]::InvariantCulture)+' tokens')}
            $answer=ShowComponentConsent $row @($Decision.rows) $false
            $pendingCount=Get-FastLlmUiPendingConsentCount -ConsentRows @($Decision.rows)
            $installArgs=@(Get-FastLlmUiComponentInstallArguments -EngineId ([string]$Decision.engineId) -InstallRoot $script:installPath -Confirmed ([bool]$answer.confirmed) -RowCount $pendingCount -Ticked @($answer.ticked))
            if($installArgs.Count -eq 0){
                # Cancel remembers the decline for this setup and starts the Vulkan setup; picking the HIP setup in Choose another setup clears it.
                try{Add-FastLlmUiDeclinedSetup -InstallRoot $script:settingsRoot -RecipeId ([string]$Decision.recipeId)}catch{}
                $script:setupNotice=Get-FastLlmUiDeclineLine
                RepreviewForPendingSetup 'declined'
                return
            }
            $script:planComponentInstall=$true
            LaunchStep 'component install' $installArgs
        }
    }
}
function ContinueUiAfterPreview($Plan) {
    if(-not $script:chosenRecipe){
        $decision=Get-FastLlmUiPendingDecision -Plan $Plan -LicenseSettings (Get-FastLlmComponentLicenseSettings -InstallRoot $script:settingsRoot) -DeclinedSetups @(Get-FastLlmUiDeclinedSetups -InstallRoot $script:settingsRoot)
        if($decision.action -cne 'none'){HandlePendingSetup $Plan $decision;return}
    }
    $receipt=Test-FastLlmModelConsentReceipt -Model $Plan.model -InstallRoot $script:installPath
    $artifact=[bool]($Plan.modelPath -and (Test-Path -LiteralPath ([string]$Plan.modelPath) -PathType Leaf))
    $script:flow=Move-FastLlmUiFlow -Flow $script:flow -Event 'preview-complete' -Plan $Plan -HasConsent:$receipt -HasArtifact:$artifact
    if($script:flow.phase -eq 'failed'){ShowFailure $script:flow.lastStartError;return}
    $script:previewReady=$true
    # Kept for "Choose another setup" even if the flow later drops its plan (model license declined, Stop); a new preview replaces it.
    $script:identifiedVariant=Get-FastLlmUiIdentifiedVariant -Plan $Plan
    $statusLabel.Text=Format-FastLlmUiRecipeSummary -Plan $Plan
    $script:evidenceUrl=Get-FastLlmUiEvidenceUrl -Plan $Plan
    $resultsLink.Visible=[bool]$script:evidenceUrl
    if($script:flow.phase -eq 'consent'){
        $approved=ShowExactModelConsent $Plan
        $script:flow=Move-FastLlmUiFlow -Flow $script:flow -Event $(if($approved){'consent-approved'}else{'consent-declined'})
        if(-not $approved){SetBusy $false;$statusLabel.Text='Model download declined. No new license receipt was created.';return}
    }
    LaunchUiPhase
}
function ShowDriverGuidance($Diagnostic) {
    & $script:uiDialogView['ShowDriverGuidance'] -Diagnostic $Diagnostic
}
# The optional API key. The window never keeps the key: what it remembers is the store state (readable or not, and the key's public id),
# re-read only when the store file changed. The key itself is read from the store at the moment of a Show or a Copy and goes nowhere else.
$script:apiKeyStore=$null;$script:apiKeyStoreStamp=''
function GetUiApiKeyStore {
    $stamp=[string]$script:installPath+'|none'
    try{$storeItem=Get-Item -LiteralPath (Join-Path $script:installPath 'api-key.dat') -Force -ErrorAction Stop;$stamp=[string]$script:installPath+'|'+[string]$storeItem.LastWriteTimeUtc.Ticks+':'+[string]$storeItem.Length}catch{}
    if($null -eq $script:apiKeyStore -or $stamp -cne $script:apiKeyStoreStamp){
        try{$script:apiKeyStore=Get-FastLlmApiKeyStoreState -InstallRoot $script:installPath}catch{$script:apiKeyStore=$null}
        $script:apiKeyStoreStamp=$stamp
    }
    return $script:apiKeyStore
}
function ReadUiApiKey { try{return [string](Get-FastLlmApiKeyForDisplay -InstallRoot $script:installPath)}catch{return $null} }
# Puts one copy on the clipboard: the text, plus the formats that came with it. A copy that holds the key comes with the three formats that
# keep it out of the clipboard history and the cloud clipboard (Get-FastLlmUiKeyClipboardFormats); each is four raw bytes, hence the stream.
# What goes into the data object, and in which order, is Set-FastLlmUiClipboard (tested without a window); only the two Windows calls are here.
function SetUiClipboardPayload($Payload) {
    Set-FastLlmUiClipboard -Payload $Payload -NewDataObject {New-Object Windows.Forms.DataObject} -Publish {param($ClipboardData) [Windows.Forms.Clipboard]::SetDataObject($ClipboardData,$true)}
}
# The one "Create a new key" action: asked, never silent. Returns $true when a new key was created.
function NewUiApiKey($Owner) {
    $store=GetUiApiKeyStore
    $question=Get-FastLlmUiNewKeyConfirmText -HasReadableKey ([bool]($store -and $store.available))
    if((ShowUiMessageBox $Owner $question 'Create a new key' 'YesNo' 'Question') -ne [Windows.Forms.DialogResult]::Yes){return $false}
    $change=Invoke-FastLlmApiKeySetting -InstallRoot $script:installPath -Action rotate
    $script:apiKeyStore=$null
    $null=ShowUiMessageBox $Owner ((@($change.lines) -join [Environment]::NewLine).Replace('Show it with: fast-llm.ps1 settings -ApiKey show','Show or copy it in Connect an app.')) 'Create a new key' 'OK' 'Information'
    return $true
}
# A start that failed on the API key: its own plain message, no retry, and the offer to create a new key when that is what helps.
function ShowUiApiKeyFailure([string]$Code,[string]$Text) {
    $failure=Get-FastLlmUiApiKeyFailure -Code $Code -SettingsPath (Join-Path $script:installPath 'settings.json')
    ShowFailure (Format-FastLlmUiTypedFailure -Code $Code -Text ([string]$failure.text))
    if($failure.offerNewKey){
        try{if(NewUiApiKey $form){$statusLabel.Text='A new API key was created. Give it to your apps (Connect an app), then start again.'}}
        catch{$newKeyFailureText=[string]$_.Exception.Message;$output.Text=[string]$output.Text+[Environment]::NewLine+'A new key could not be created: '+(ConvertTo-FastLlmKeyFreeText -Text ([ref]$newKeyFailureText))}
    }
}
function StartUiBackground {
    if($script:child -or $script:vcBroker){throw 'Finish the active setup or foreground operation first.'}
    ReadSelection
    AssertUiBackgroundNotOccupied
    $script:bgEndedByUserStop=$false
    if($script:lastUserStoppedRequestId){SaveUserStoppedBackgroundRequestId ''}
    $selectedModel=if($modelBox.SelectedIndex -gt 0){[string]$modelBox.SelectedItem}else{$null}
    $serving=Get-FastLlmServingSettings -InstallRoot $script:installPath
    $settingsNotice=Get-FastLlmUiMalformedSettingsNotice -Settings $serving
    # The saved context profile, requests at once and embeddings come from the one resolution the sign-in start uses (as start applies them).
    # An unreadable key flag keeps its own refusal inside the request builder.
    $servingArguments=$null
    if(-not [bool]$serving.apiKeyUndetermined){$servingArguments=Get-FastLlmServingHostArguments -InstallRoot $script:installPath}
    $request=New-FastLlmUiBackgroundRequest -SourceRoot $PSScriptRoot -InstallRoot $script:installPath -ModelId $selectedModel `
        -ContextSize ([int]$contextBox.Value) -BarMitigation (GetBarValue) -Settings $serving -AllowSwitch (Get-FastLlmUiAllowSwitch -InstallRoot $script:settingsRoot) -ServingArguments $servingArguments
    $launched=Invoke-FastLlmUiBackgroundStart -State $script:bgState -Request $request -Start {
        param($Request)
        # Only the flag (on or off) is passed; the background host reads the key store itself.
        # The saved context profile, requests at once and embeddings go along only when they are not the default.
        $servingParameters=Get-FastLlmUiBackgroundServingArguments -Request $Request
        & (Get-Module FastLlm) {param($Source,$Project,$Install,$Profile,$Model,$Context,$BarMitigation,$Port,$Thinking,$ChatPage,$IdleStop,$KeyFlag,$SwitchAllowed,$ServingParameters)
            . $Source
            Start-FastLlmBackgroundHost -SourceRoot $Project -InstallRoot $Install -Profile $Profile `
                -ModelId $Model -ContextSize $Context -VulkanBarMitigation $BarMitigation -ServerPort $Port -Thinking $Thinking -ChatPage $ChatPage -IdleStopMinutes $IdleStop -UseApiKey $KeyFlag -SwitchAllowed:$SwitchAllowed -NoWait @ServingParameters
        } (Join-Path $PSScriptRoot 'src/FastLlm.BackgroundHost.ps1') $Request.sourceRoot $Request.installRoot `
            $Request.profile $Request.modelId $Request.contextSize $Request.vulkanBarMitigation $Request.serverPort $Request.thinking $Request.chatPage $Request.idleStopMinutes $Request.apiKey ([bool]($Request.PSObject.Properties['allowSwitch'] -and $Request.allowSwitch)) $servingParameters
    }
    $backgroundLabel.Text=Get-FastLlmUiBackgroundText -State $script:bgState -LastUserStoppedRequestId $script:lastUserStoppedRequestId
    $statusLabel.Text='Background host requested. It uses only a prepared, consented model and serves in this Windows user session.'
    $output.Text='This optional background mode is not a Windows service or auto-start task. Keep this user signed in; re-open FastLLM to attach later.'
    if($settingsNotice){$output.Text=$settingsNotice+"`r`n`r`n"+$output.Text;$statusLabel.Text=$settingsNotice}
    SetBusy $false
    return $launched
}
function AttachUiBackground {
    if($script:child -or $script:vcBroker){throw 'Finish the active setup or foreground operation first.'}
    ReadSelection
    RefreshUiBackgroundStatus
    # The port to expect comes from the running run's own endpoint, never from the saved setting.
    $expectedPort=Get-FastLlmUiRunningPort -Status (GetUiBackgroundRunStatus)
    $attached=Invoke-FastLlmUiBackgroundAttach -State $script:bgState -Attach {
        param($ExpectedRequestId)
        & (Get-Module FastLlm) {param($Source,$Project,$Install,$Request,$Port)
            . $Source
            Attach-FastLlmBackgroundHost -InstallRoot $Install -SourceRoot $Project -ExpectedRequestId $Request -ExpectedServerPort $Port
        } (Join-Path $PSScriptRoot 'src/FastLlm.BackgroundHost.ps1') $PSScriptRoot $script:installPath $ExpectedRequestId $expectedPort
    }
    $script:bgEndedByUserStop=$false
    $script:bgState.observation | Add-Member -NotePropertyName uiHealthChecked -NotePropertyValue $true -Force
    $backgroundLabel.Text=Get-FastLlmUiBackgroundText -State $script:bgState -LastUserStoppedRequestId $script:lastUserStoppedRequestId
    $statusLabel.Text=Format-FastLlmUiBackgroundReadyStatus -Text 'Ready background inference attached. API smoke checks passed; residency and performance remain unqualified.' -State (GetUiBackgroundRunStatus) -ApiKeyStore (GetUiApiKeyStore)
    $output.Text="Attached to exact request $($attached.requestId) and run $($attached.runId). Closing this window detaches; Stop ends this run."
    SetBusy $false
}
$installButton.Add_Click({try{ReadSelection;AssertUiBackgroundNotOccupied;$script:chosenRecipe=$null;ClearPreviousRunNotes;$script:flow=New-FastLlmUiFlow -Mode install;LaunchUiPhase}catch{ShowFailure $_.Exception.Message}})
$startButton.Add_Click({try{ReadSelection;AssertUiBackgroundNotOccupied;$script:chosenRecipe=$null;ClearPreviousRunNotes;$script:flow=New-FastLlmUiFlow -Mode start;LaunchUiPhase}catch{ShowFailure $_.Exception.Message}})
$backgroundStartButton.Add_Click({
    try{$null=StartUiBackground}
    catch{
        $startFailureText=[string]$_.Exception.Message
        $message=ConvertTo-FastLlmKeyFreeText -Text ([ref]$startFailureText)
        $backgroundFailureCode=[string]$_.Exception.Data['FastLlmFailureCode']
        RefreshUiBackgroundStatus
        # An API key refusal (the flag cannot be known, or the stored key cannot be read) is its own message; nothing was started.
        if(Test-FastLlmUiApiKeyFailure -Code $backgroundFailureCode){ShowUiApiKeyFailure $backgroundFailureCode $message}
        else{ShowFailure ($message+"`r`n"+(Get-FastLlmUiBackgroundFailureHint -Message $message))}
    }
})
$backgroundAttachButton.Add_Click({try{AttachUiBackground}catch{RefreshUiBackgroundStatus;ShowFailure $_.Exception.Message}})
$backgroundCheckButton.Add_Click({
    try{
        ReadSelection;RefreshUiBackgroundStatus
        if(-not $script:bgState.pendingRequestId -and -not $script:bgState.observation.occupied){
            $null=Clear-FastLlmUiBackgroundAttention -State $script:bgState
        }
        $backgroundLabel.Text=Get-FastLlmUiBackgroundText -State $script:bgState -LastUserStoppedRequestId $script:lastUserStoppedRequestId
        $statusLabel.Text='Background ownership check completed.'
        SetBusy $false
    }catch{ShowFailure $_.Exception.Message}
})
$doctorButton.Add_Click({try{ReadSelection;LaunchStep 'diagnostics' (@('doctor','-Compact')+$script:selection)}catch{ShowFailure $_.Exception.Message}})
$driverButton.Add_Click({try{ReadSelection;LaunchStep 'driver guidance' (@('doctor','-Compact')+$script:selection)}catch{ShowFailure $_.Exception.Message}})
# The installed components with their sizes and a Remove button per row. Removal is Remove-FastLlmComponent, which refuses while the server uses the component.
$script:componentsView=$null
function FillComponentsPanel {
    $view=$script:componentsView
    # The Fluent window's Models page rebuilds its own list: its view names the function (the classic view has no refresh key).
    if($null -ne $view -and $view['refresh']){& $view['refresh'];return}
}
function RemoveComponentFromWindow([string]$ComponentId) {
    $view=$script:componentsView
    $answer=ShowUiMessageBox $view.dialog "Remove the component '$ComponentId'? Its files are deleted from this PC. You can install it again later." 'Remove component' 'YesNo' 'Question' 'Button2'
    if($answer -ne [Windows.Forms.DialogResult]::Yes){return}
    # The operation lock is taken (without waiting) so a chain install or a start in preparation cannot be undone under it; a busy answer changes nothing.
    $removeLock=$null
    try{
        try{$removeLock=Enter-FastLlmOperation -InstallRoot $view.root}
        catch{throw 'FastLLM is busy with another install or start. Try again when it has finished; nothing was removed.'}
        [void](Remove-FastLlmComponent -ComponentsPath $view.file -ComponentId $ComponentId -InstallRoot $view.root -OperationLockHeld)
        $view.message.Text="Removed '$ComponentId'."
    }
    catch{$view.message.Text=[string]$_.Exception.Message}
    finally{if($removeLock){$removeLock.Dispose()}}
    # Rebuilt after this Click handler returns: FillComponentsPanel disposes the clicked button, which must not happen inside its own Click.
    [void]$view.dialog.BeginInvoke([Action]{FillComponentsPanel})
}
# The downloaded models with their sizes and a Remove button per row, the free disk space, and a button for leftover partial downloads.
# Removal is Remove-FastLlmInstalledModel under the operation lock (taken without waiting); a refusal is shown as a plain sentence.
$script:modelsView=$null
function FillModelsPanel {
    $view=$script:modelsView
    # The Fluent window's Models page rebuilds its own list: its view names the function (the classic view has no refresh key).
    if($null -ne $view -and $view['refresh']){& $view['refresh'];return}
}
function RemoveModelFromWindow([string]$ModelId) {
    $view=$script:modelsView
    $entry=@($catalog.models | Where-Object{[string]$_.id -ceq $ModelId})[0]
    $row=@(Get-FastLlmInstalledModels -InstallRoot $view.root -CatalogPath $view.file | Where-Object{$_.id -ceq $ModelId})[0]
    if($null -eq $entry -or $null -eq $row){$view.message.Text=Get-FastLlmModelRemovalRefusalText -Reason 'not-installed';[void]$view.dialog.BeginInvoke([Action]{FillModelsPanel});return}
    $text=Get-FastLlmModelRemovalConfirmationText -DisplayName (Get-FastLlmModelDisplayName -Model $entry) -SizeBytes ([int64]$row.sizeBytes)
    $answer=ShowUiMessageBox $view.dialog $text 'Remove model' 'YesNo' 'Question' 'Button2'
    if($answer -ne [Windows.Forms.DialogResult]::Yes){return}
    $removeLock=$null
    try{
        try{$removeLock=Enter-FastLlmOperation -InstallRoot $view.root}
        catch{$view.message.Text=Get-FastLlmModelRemovalRefusalText -Reason 'operation-in-progress';return}
        $result=Remove-FastLlmInstalledModel -InstallRoot $view.root -CatalogPath $view.file -ModelId $ModelId -OperationLockHeld
        $view.message.Text=if($result.removed){"Removed $(Get-FastLlmModelDisplayName -Model $entry)."}else{Get-FastLlmModelRemovalRefusalText -Reason ([string]$result.reason)}
    }
    catch{$view.message.Text="The model could not be removed: $($_.Exception.Message)"}
    finally{if($removeLock){$removeLock.Dispose()}}
    # Rebuilt after this Click handler returns: FillModelsPanel disposes the clicked button, which must not happen inside its own Click.
    [void]$view.dialog.BeginInvoke([Action]{FillModelsPanel})
}
function RemoveLeftoversFromWindow {
    $view=$script:modelsView
    $names=@($view.leftoverButton.Tag)
    if($names.Count -eq 0){return}
    $answer=ShowUiMessageBox $view.dialog "Deletes the leftover partial downloads ($($view.leftoverText)) from this PC. Downloaded models are not touched. Continue?" 'Remove leftover partial downloads' 'YesNo' 'Question' 'Button2'
    if($answer -ne [Windows.Forms.DialogResult]::Yes){return}
    $removeLock=$null
    try{
        try{$removeLock=Enter-FastLlmOperation -InstallRoot $view.root}
        catch{$view.message.Text=Get-FastLlmModelRemovalRefusalText -Reason 'operation-in-progress';return}
        $results=@(Remove-FastLlmModelLeftovers -InstallRoot $view.root -Names $names -OperationLockHeld)
        $kept=@($results | Where-Object{-not $_.removed})
        $view.message.Text=if($kept.Count -eq 0){"Removed $($results.Count) leftover file(s)."}else{"Removed $($results.Count-$kept.Count) leftover file(s); $($kept.Count) could not be removed ($($kept[0].reason))."}
    }
    catch{$view.message.Text="The leftover files could not be removed: $($_.Exception.Message)"}
    finally{if($removeLock){$removeLock.Dispose()}}
    [void]$view.dialog.BeginInvoke([Action]{FillModelsPanel})
}
# Open logs: the run logs folder (state\logs) in Explorer, created if it is not there yet.
function OpenLogsFolder {
    ReadSideSelection
    $stateRoot=& (Get-Module FastLlm) {param($Root) Get-FastLlmStateRoot -InstallRoot $Root -Create} $script:installPath
    $logsPath=Join-Path $stateRoot 'logs'
    if(-not (Test-Path -LiteralPath $logsPath -PathType Container)){New-Item -ItemType Directory -Path $logsPath -Force | Out-Null}
    Start-Process explorer.exe -ArgumentList @($logsPath)
}
$logsButton.Add_Click({try{OpenLogsFolder}catch{$statusLabel.Text='The logs folder could not be opened: '+$_.Exception.Message}})
# Save support bundle: a list-only step first (nothing is written), then the list and the redaction count in a dialog, then a Save dialog
# that defaults to the Desktop, then the write. The zip is local only; nothing is uploaded.
function ReadSideSelection {
    # While a run is going, its own selection stays; re-reading would reset the window's per-workflow notes.
    if(-not $script:child){ReadSelection}
}
function StartSupportBundle {
    ReadSideSelection
    $probe=Join-Path ([IO.Path]::GetTempPath()) ('fastllm-support-list-'+[Guid]::NewGuid().ToString('N')+'.zip')
    LaunchSideStep 'bundle list' (@('doctor','-SupportBundle',$probe,'-ListOnly')+$script:selection)
}
function ContinueSupportBundle([string]$Text) {
    $listing=ConvertFrom-Json $Text
    $answer=ShowUiMessageBox $form (Format-FastLlmUiSupportBundleList -Listing $listing) 'Save support bundle' ([Windows.Forms.MessageBoxButtons]::OKCancel) ([Windows.Forms.MessageBoxIcon]::Information)
    if($answer -ne [Windows.Forms.DialogResult]::OK){$statusLabel.Text='Support bundle cancelled. Nothing was saved.';return}
    $dialog=New-Object Windows.Forms.SaveFileDialog
    try{
        $dialog.Title='Save support bundle'
        $dialog.Filter='Zip file (*.zip)|*.zip'
        $dialog.DefaultExt='zip'
        $dialog.InitialDirectory=[Environment]::GetFolderPath('Desktop')
        $dialog.FileName=Get-FastLlmUiSupportBundleFileName -Now (Get-Date)
        $dialog.OverwritePrompt=$false
        $chosen=$null
        while($null -eq $chosen){
            if($dialog.ShowDialog($form) -ne [Windows.Forms.DialogResult]::OK){$statusLabel.Text='Support bundle cancelled. Nothing was saved.';return}
            if(Test-Path -LiteralPath $dialog.FileName){$null=ShowUiMessageBox $form 'That file already exists. A support bundle is never written over a file; choose a new name.' 'Save support bundle'}
            else{$chosen=$dialog.FileName}
        }
    }finally{$dialog.Dispose()}
    $script:bundlePath=$chosen
    LaunchSideStep 'bundle save' (@('doctor','-SupportBundle',$chosen)+$script:selection)
}
$bundleButton.Add_Click({try{StartSupportBundle}catch{ShowFailure $_.Exception.Message}})
# "Choose another setup": the recipes the CLI lists for this card (`recipes -Detail -AsJson`, read-only and offline), experimental ones only while the switch is on.
# Choosing one whose engine chain needs an AMD license opens the consent dialog; Install runs the component install as a child, then the start uses -Recipe.
# Both dialogs are disposed only after ShowDialog returns, never inside one of their own control handlers (as in the Components window).
function StartRecipeList {
    if(-not $script:previewReady){throw 'Preview a setup first (Start / download), then choose another.'}
    ReadSelection
    LaunchStep 'recipe list' @('recipes','-Detail','-AsJson','-InstallRoot',$script:installPath)
}
function ShowRecipeChooser($Rows) {
    return & $script:uiDialogView['ShowRecipeChooser'] -Rows $Rows
}
function ShowComponentConsent($Row,[object[]]$ConsentRows,[bool]$Chosen=$true) {
    return & $script:uiDialogView['ShowComponentConsent'] -Row $Row -ConsentRows $ConsentRows -Chosen $Chosen
}
function BeginChosenRecipe($Row) {
    ReadSelection
    AssertUiBackgroundNotOccupied
    $script:chosenRecipe=[pscustomobject]@{id=[string]$Row.id;origin=[string]$Row.origin}
    ClearPreviousRunNotes
    $script:flow=New-FastLlmUiFlow -Mode start
    LaunchUiPhase
}
function ContinueWithChosenRecipe($Row) {
    if(-not $Row){
        # A notice the chooser already put in the status line (no setup for this card, ...) stays visible.
        if(-not $script:chooserNotice){$statusLabel.Text='No other setup chosen. Nothing was changed.'}
        return
    }
    if($Row.experimental -and -not $experimentalBox.Checked){throw 'This setup is experimental. Turn on Experimental community components to use it. Nothing was changed.'}
    if(-not [string]::IsNullOrEmpty([string]$Row.chainError)){throw "This setup cannot be prepared: $([string]$Row.chainError) Nothing was changed."}
    # Picking a setup yourself ends a remembered decline of it.
    try{Remove-FastLlmUiDeclinedSetup -InstallRoot $script:settingsRoot -RecipeId ([string]$Row.id)}catch{}
    if($Row.installRequired){
        # Some component of the engine chain is missing: show the whole chain; Install needs every missing component accepted.
        $consentRows=@(Get-FastLlmUiConsentRows -Chain @($Row.chain))
        $answer=ShowComponentConsent $Row $consentRows
        $pendingCount=Get-FastLlmUiPendingConsentCount -ConsentRows $consentRows
        $installArgs=@(Get-FastLlmUiComponentInstallArguments -EngineId ([string]$Row.engineId) -InstallRoot $script:installPath -Confirmed ([bool]$answer.confirmed) -RowCount $pendingCount -Ticked @($answer.ticked))
        if($installArgs.Count -eq 0){$statusLabel.Text='Component install cancelled. Nothing was downloaded.';return}
        $script:pendingRecipeRow=$Row
        LaunchStep 'component install' $installArgs
        return
    }
    BeginChosenRecipe $Row
}
$chooseButton.Add_Click({try{StartRecipeList}catch{ShowFailure $_.Exception.Message}})
# Launch checks run on a background runspace (the same pattern as the background-host poll); the timer collects the result, so the window never waits on the network.
function StartUiStartupChecks {
    if($script:startupRun){return}
    $release=Read-FastLlmInstalledRelease -AppRoot $PSScriptRoot
    $runIntegrity=$false
    if($release){$runIntegrity=[bool](Test-FastLlmUiIntegrityDue -InstallRoot $script:settingsRoot -InstalledVersion ([string]$release.version))}
    $source=@'
param($Project,$Install,$App,$RunIntegrity)
$ErrorActionPreference='Stop'
. (Join-Path $Project 'src/FastLlm.Update.ps1')
$integrity=$null;$update=$null
if($RunIntegrity){try{$integrity=Test-FastLlmInstallIntegrity -AppRoot $App}catch{$integrity=$null}}
try{$update=Invoke-FastLlmUpdateCheck -InstallRoot $Install -AppRoot $App}catch{$update=$null}
$reinstall=$null
try{$reinstall=Resolve-FastLlmReinstall -InstallRoot $Install -AppRoot $App -OfferOnly -Check $update}catch{$reinstall=$null}
$updateMuted=$false
try{if($update -and $update.latest){$updateMuted=[bool](Test-FastLlmUpdateMuted -InstallRoot $Install -LatestVersion ([string]$update.latest.version))}}catch{$updateMuted=$false}
[pscustomobject]@{integrity=$integrity;update=$update;reinstall=$reinstall;updateMuted=$updateMuted}
'@
    $pipeline=[Management.Automation.PowerShell]::Create()
    try{
        $null=$pipeline.AddScript($source).AddArgument($PSScriptRoot).AddArgument($script:settingsRoot).AddArgument($PSScriptRoot).AddArgument($runIntegrity)
        $script:startupRun=[pscustomobject]@{pipeline=$pipeline;handle=$pipeline.BeginInvoke();version=$(if($release){[string]$release.version}else{''});integrityRan=$runIntegrity}
    }catch{$pipeline.Dispose();throw}
}
function CompleteUiStartupChecks {
    if(-not $script:startupRun -or -not $script:startupRun.handle.IsCompleted){return}
    $run=$script:startupRun;$script:startupRun=$null
    try{
        $values=@($run.pipeline.EndInvoke($run.handle))
        if($values.Count -eq 1){
            if($run.integrityRan){[void](Set-FastLlmUiIntegrityChecked -InstallRoot $script:settingsRoot -InstalledVersion $run.version -Result $values[0].integrity)}
            $failedIntegrity=Format-FastLlmUiIntegrityBanner -Result $values[0].integrity
            $offer=$null;if(-not $values[0].updateMuted){$offer=Format-FastLlmUiUpdateBanner -Check $values[0].update}
            if($failedIntegrity){SetUiBanner $failedIntegrity.text $failedIntegrity.url $true $false}
            elseif($offer){
                $script:updateOffer=[pscustomobject]@{version=[string]$values[0].update.latest.version;latest=$values[0].update.latest}
                SetUiBanner $offer.text $offer.url $false $true
            }
            $reinstallChoice=Get-FastLlmUiReinstallOffer -Resolved $values[0].reinstall
            if($reinstallChoice -and -not $failedIntegrity){$script:reinstallOffer=$reinstallChoice;$reinstallButton.Visible=$true}
        }
    }catch{}
    finally{try{$run.pipeline.Dispose()}catch{}}
}
function InvokeUiUpdate {
    if(-not $script:updateOffer -or $script:updateRun){return}
    if($script:child -or $script:sideChild -or $script:vcBroker){$statusLabel.Text='Finish or stop the current action before updating.';return}
    $version=[string]$script:updateOffer.version
    $choice=ShowUiMessageBox $form (Format-FastLlmUiUpdateConfirm -Version $version) 'Update FastLLM' 'YesNo' 'Question' 'Button2'
    if($choice -ne 'Yes'){return}
    $source=@'
param($Project,$Install,$App,$Latest)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $Project 'src/FastLlm.psm1') -Force
. (Join-Path $Project 'src/FastLlm.Update.ps1')
Invoke-FastLlmVerifiedUpdate -InstallRoot $Install -AppRoot $App -Latest $Latest
'@
    $pipeline=[Management.Automation.PowerShell]::Create()
    try{
        $null=$pipeline.AddScript($source).AddArgument($PSScriptRoot).AddArgument($script:settingsRoot).AddArgument($PSScriptRoot).AddArgument($script:updateOffer.latest)
        $script:updateOutcome=$false
        $script:updateRun=[pscustomobject]@{pipeline=$pipeline;handle=$pipeline.BeginInvoke();version=$version;kind='update'}
    }catch{$pipeline.Dispose();$statusLabel.Text=Format-FastLlmUiUpdateResult -Result ([pscustomobject]@{status='failed';reason=$_.Exception.Message}) -Version $version;return}
    $bannerButton.Enabled=$false
    $statusLabel.Text='Updating...'
    SetBusy $false
}
function CompleteUiUpdate {
    if(-not $script:updateRun -or -not $script:updateRun.handle.IsCompleted){return}
    $run=$script:updateRun
    $result=[pscustomobject]@{status='failed';reason='the update did not complete'}
    try{
        $values=@($run.pipeline.EndInvoke($run.handle))
        if($values.Count -ge 1){$result=$values[$values.Count-1]}
    }catch{$result=[pscustomobject]@{status='failed';reason=$_.Exception.Message}}
    finally{try{$run.pipeline.Dispose()}catch{};$script:updateRun=$null}
    # The stop inside the update ended any server this window supervised, so re-read ownership before showing the outcome.
    try{RefreshUiBackgroundStatus}catch{}
    SetBusy ([bool]($script:child -or $script:vcBroker))
    $script:updateOutcome=$true
    if([string]$run.kind -ceq 'reinstall'){
        $statusLabel.Text=Format-FastLlmUiReinstallResult -Result $result -To $run.version
        if([string]$result.status -ceq 'installed'){$script:reinstallOffer=$null;$script:updateOffer=$null;$reinstallButton.Visible=$false;SetUiBanner '' '' $false $false}
        elseif([string]$result.status -ceq 'refused' -and [string]$result.step -ceq 'decision'){$script:reinstallOffer=$null;$reinstallButton.Visible=$false;$bannerButton.Enabled=$true}
        elseif(Test-FastLlmUiUpdateIntegrityFailure -Result $result){$script:reinstallOffer=$null;$script:updateOffer=$null;$reinstallButton.Visible=$false;SetUiBanner $statusLabel.Text $script:FastLlmUiReleasesUrlPrefix $true $false}
        else{$reinstallButton.Enabled=$true;$bannerButton.Enabled=$true}
        return
    }
    $statusLabel.Text=Format-FastLlmUiUpdateResult -Result $result -Version $run.version
    if([string]$result.status -ceq 'installed'){$script:updateOffer=$null;SetUiBanner '' '' $false $false}
    elseif(Test-FastLlmUiUpdateIntegrityFailure -Result $result){$script:updateOffer=$null;SetUiBanner $statusLabel.Text $script:FastLlmUiReleasesUrlPrefix $true $false}
    else{$bannerButton.Enabled=$true}
}
$bannerButton.Add_Click({try{InvokeUiUpdate}catch{$statusLabel.Text='Update not installed: '+$_.Exception.Message+'. Nothing was changed.'}})
function InvokeUiReinstall {
    if(-not $script:reinstallOffer -or $script:updateRun){return}
    if($script:child -or $script:sideChild -or $script:vcBroker){$statusLabel.Text='Finish or stop the current action before reinstalling.';return}
    $offer=$script:reinstallOffer
    $choice=ShowUiMessageBox $form (Format-FastLlmUiReinstallConfirm -From ([string]$offer.from) -To ([string]$offer.to)) 'Reinstall previous version' 'YesNo' 'Question' 'Button2'
    if($choice -ne 'Yes'){return}
    # The run decides again from scratch and refuses when the previous version is no longer the one confirmed here.
    $source=@'
param($Project,$Install,$App,$Expected,$ExpectedFrom)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $Project 'src/FastLlm.psm1') -Force
. (Join-Path $Project 'src/FastLlm.Update.ps1')
Invoke-FastLlmReinstallPrevious -InstallRoot $Install -AppRoot $App -ExpectedTarget $Expected -ExpectedFrom $ExpectedFrom -Approve { param($From,$To) $true }
'@
    $pipeline=[Management.Automation.PowerShell]::Create()
    try{
        $null=$pipeline.AddScript($source).AddArgument($PSScriptRoot).AddArgument($script:settingsRoot).AddArgument($PSScriptRoot).AddArgument([string]$offer.to).AddArgument([string]$offer.from)
        $script:updateOutcome=$false
        $script:updateRun=[pscustomobject]@{pipeline=$pipeline;handle=$pipeline.BeginInvoke();version=[string]$offer.to;kind='reinstall'}
    }catch{$pipeline.Dispose();$statusLabel.Text=Format-FastLlmUiReinstallResult -Result ([pscustomobject]@{status='failed';step='start';reason=$_.Exception.Message}) -To ([string]$offer.to);return}
    $reinstallButton.Enabled=$false;$bannerButton.Enabled=$false
    $statusLabel.Text='Reinstalling...'
    SetBusy $false
}
$reinstallButton.Add_Click({try{InvokeUiReinstall}catch{$statusLabel.Text='Reinstall not done: '+$_.Exception.Message+'. Nothing was changed.'}})
$form.Add_Shown({try{StartUiStartupChecks}catch{}})
$copyButton.Add_Click({
    try{[Windows.Forms.Clipboard]::SetText((Get-FastLlmUiApiUrl -Status (GetUiBackgroundRunStatus) -Settings (Get-FastLlmServingSettings -InstallRoot $script:installPath)))}
    catch{$statusLabel.Text='The API URL could not be copied: '+$_.Exception.Message}
})
$openChatButton.Add_Click({
    try{
        $chatUrl=[string]$script:chatUrl
        if($chatUrl){Start-Process $chatUrl}else{$statusLabel.Text='The chat page is available only while a run started with the local chat page is running.'}
    }catch{$statusLabel.Text='The chat page could not be opened: '+$_.Exception.Message}
})
$stopButton.Add_Click({try{StopUiOperation}catch{ShowFailure $_.Exception.Message}})
$trayButton.Add_Click({
    try{MinimizeToTray}catch{
        if(-not $form.Visible){try{$form.Show()}catch{}}
        $statusLabel.Text='Tray unavailable. FastLLM remains in the visible window; the current operation is unchanged.'
    }
})
$timer=New-Object Windows.Forms.Timer;$timer.Interval=250
$timer.Add_Tick({
    try{CompleteUiStartupChecks;CompleteUiUpdate}catch{}
    if($script:vcBroker){
        $observation=Get-FastLlmUiVcBrokerObservation -Process $script:vcBroker
        if($observation -ne 'terminal'){
            if($observation -eq 'uncertain-live'){
                $statusLabel.Text='Microsoft setup status is temporarily unavailable. Keep this window open; FastLLM will keep checking without terminating it.'
                SetBusy $true;SetTrayMenuAvailable $false
            }
            return
        }
        try{
            $broker=$script:vcBroker
            $result=& (Get-Module FastLlm) {param($Source,$Process)
                . $Source
                Complete-FastLlmVcRedistInstall -Process $Process
            } (Join-Path $PSScriptRoot 'src/FastLlm.VcRedistInstall.ps1') $broker
            $script:vcBroker=$null
            SetTrayMenuAvailable $true
            HandleVcBrokerResult $result
        }catch{
            # A terminal observation preceded Complete; never probe a possibly disposed handle again.
            $script:vcBroker=$null
            SetTrayMenuAvailable $true
            if($script:flow -and $script:flow.phase -eq 'setup-attention'){
                $script:flow=Move-FastLlmUiFlow -Flow $script:flow -Event 'setup-defer'
            }
            ShowFailure ('Microsoft prerequisite result needs manual review: '+$_.Exception.Message)
        }
        return
    }
    CompleteUiBackgroundPoll
    $pollBackground=[bool]($script:bgState.pendingRequestId -or $script:bgState.attachedRequestId -or
        ($script:bgState.observation -and $script:bgState.observation.occupied -and -not $script:bgState.observation.attachable))
    if($pollBackground -and -not $script:bgPoll -and [DateTime]::UtcNow -ge $script:bgNextPollUtc){
        $script:bgNextPollUtc=[DateTime]::UtcNow.AddSeconds($(if($script:bgState.attachedRequestId){5}elseif($script:bgState.pendingRequestId){2}else{5}))
        StartUiBackgroundPoll
    }
    CompleteUiSideStep
    if(-not $script:child){return}
    try{
        $text=$script:child.Snapshot();$output.Text=$text;$output.SelectionStart=$output.TextLength;$output.ScrollToCaret()
        if(-not $script:child.Process.HasExited){
            if($script:step -eq 'serving'){
                try{$s=Get-FastLlmStatus $script:installPath;$isCurrentRun=Test-FastLlmUiStatusIsCurrentRun -Status $s -PreviousRunId $script:servingPreviousRunId
                    # Open chat and the ready-only actions follow this window's own run, not only a background one.
                    $runStatus=$null;if($isCurrentRun){$runStatus=$s}
                    if(UpdateUiRunState $runStatus $true){SetBusy $true}
                    UpdateUiSwitchState $runStatus
                    if($isCurrentRun -and $s.active -and $s.phase -eq 'ready'){$statusLabel.Text=Format-FastLlmUiReadyStatus -State $s -ApiKeyStore $(if($s.PSObject.Properties['apiKey']){GetUiApiKeyStore});$progress.Visible=$false;$script:evidenceUrl=Get-FastLlmUiRunEvidenceUrl -State $s;$resultsLink.Visible=[bool]$script:evidenceUrl}
                    if($isCurrentRun -and $s.active -and $s.phase -eq 'ready' -and -not $script:servingNotesDone){
                        $lines=@()
                        $setupLine=Get-FastLlmUiRunSetupLine -State $s
                        if($setupLine){$lines+=$setupLine}
                        if($script:setupNotice){$lines+=[string]$script:setupNotice}
                        if($script:servingSettingsNotice){$lines+=[string]$script:servingSettingsNotice}
                        if($s.PSObject.Properties['selfTest'] -and $s.selfTest){$lines+=Format-FastLlmUiSelfTest -SelfTest $s.selfTest -MeasurementNote $(if($s.PSObject.Properties['measurementNote']){[string]$s.measurementNote}else{''});$script:servingNotesDone=$true}
                        $barNote=Get-FastLlmUiBarNote -State $s
                        if($barNote){$lines+=$barNote;$barLink.Visible=$true}
                        if($lines.Count){$notesLabel.Text=($lines -join [Environment]::NewLine)}
                    }
                }catch{}
            }
            return
        }
        $script:child.Process.WaitForExit();$text=$script:child.Snapshot();$code=$script:child.Process.ExitCode;$step=$script:step
        $script:child.Dispose();$script:child=$null;$script:step='idle'
        $script:chatUrl=$null;$script:runReady=$false;UpdateUiSwitchState $null
        if($step -eq 'setup check'){
            if($code -notin @(0,2)){ShowFailure 'The read-only setup check could not complete. Open Diagnostics for details; no installation was attempted.';return}
            $diagnostic=ConvertFrom-FastLlmUiSetupCheckOutput -Text $text
            $decision=Get-FastLlmUiSetupDecision -Diagnostic $diagnostic -ExitCode $code
            $script:flow=Move-FastLlmUiFlow -Flow $script:flow -Event 'setup-complete' -SetupDecision $decision
            if($script:flow.phase -eq 'setup-attention'){
                SetBusy $false
                $statusLabel.Text='Setup action needed. Review prerequisite status.'
                $choice=ShowSetupAttention $decision $diagnostic
                switch($choice){
                    'recheck' {
                        $script:flow=Move-FastLlmUiFlow -Flow $script:flow -Event 'setup-recheck'
                        LaunchUiPhase
                    }
                    'prepare' {LaunchStep 'vc prepare' @()}
                    default {
                        $script:flow=Move-FastLlmUiFlow -Flow $script:flow -Event 'setup-defer'
                        $statusLabel.Text='Setup deferred. No software was installed.'
                    }
                }
                return
            }
            LaunchUiPhase
            if(@($decision.advisoryWarnings).Count -gt 0){
                $statusLabel.Text='Continuing with required files present. Detailed prerequisite observations are incomplete or inconsistent; compatibility is unqualified.'
            }
            return
        }
        # A missing engine can make doctor exit 2 while the independent PnP advisory is usable.
        if($step -eq 'driver guidance' -and $code -in @(0,2)){
            SetBusy $false;ShowDriverGuidance (ConvertFrom-FastLlmUiSetupCheckOutput -Text $text);return
        }
        if($code -ne 0){
            if($step -eq 'vc prepare'){
                if($script:flow -and $script:flow.phase -eq 'setup-attention'){
                    $script:flow=Move-FastLlmUiFlow -Flow $script:flow -Event 'setup-defer'
                }
                ShowFailure 'The Microsoft VC++ package could not be downloaded and verified. No installer was started. Use the official Microsoft link or try setup again later.'
                return
            }
            if($step -eq 'component install'){
                $ownInstall=[bool]$script:planComponentInstall
                $script:pendingRecipeRow=$null;$script:planComponentInstall=$false
                if($ownInstall -and $script:flow -and $script:flow.phase -eq 'preview'){
                    # The install the window started from its own plan failed: no decline is recorded; the Vulkan setup runs and the next Start tries again.
                    $script:setupNotice=Get-FastLlmUiInstallFailedLine
                    RepreviewForPendingSetup 'install-failed'
                    if($script:child){$output.Text=Format-FastLlmUiFailureDisplay -Text $text;SetFailureCapture $text}
                    return
                }
            }
            if($step -eq 'serving' -and $script:flow){
                # A typed failure (HIP backend unavailable, blocked DLL, device not found or ambiguous, a missing component) is shown as its own
                # message and is not retried: the window never falls back to another setup.
                $failureCode=''
                try{$failureCode=Get-FastLlmUiFailureCode -Status (Get-FastLlmStatus $script:installPath) -PreviousRunId ([string]$script:servingPreviousRunId)}catch{}
                if(Test-FastLlmUiTypedHipFailure -Code $failureCode){
                    $script:flow=Move-FastLlmUiFlow -Flow $script:flow -Event 'error' -ErrorMessage $text
                    ShowFailure (Format-FastLlmUiTypedFailure -Code $failureCode -Text (Format-FastLlmUiFailureDisplay -Text $text)) -Capture $text;return
                }
                # An API key failure is shown as its own message and is never retried: a second start must not run without the key.
                if(Test-FastLlmUiApiKeyFailure -Code $failureCode){
                    $script:flow=Move-FastLlmUiFlow -Flow $script:flow -Event 'error' -ErrorMessage ([string](Get-FastLlmUiApiKeyFailure -Code $failureCode -SettingsPath (Join-Path $script:installPath 'settings.json')).text)
                    ShowUiApiKeyFailure $failureCode $text;return
                }
                $script:flow=Move-FastLlmUiFlow -Flow $script:flow -Event 'serving-failed' -ErrorMessage $text
                if($script:flow.phase -eq 'preview'){LaunchUiPhase;return}
            }
            ShowFailure $text -Capture $text;return
        }
        switch($step){
            'vc prepare'{
                if(-not $script:flow -or $script:flow.phase -cne 'setup-attention'){
                    throw 'VC++ preparation completed outside the setup-attention state.'
                }
                if([string]::IsNullOrWhiteSpace($text) -or $text.Length -gt 8192){throw 'VC++ preparation returned no bounded receipt.'}
                $candidate=GetVcCandidate
                $receipt=Assert-FastLlmUiVcPreparedReceipt -Receipt (ConvertFrom-Json $text) -Candidate $candidate -CacheRoot $script:vcCacheRoot
                $script:vcPrepared=$receipt
                SetBusy $false
                if(ShowVcInstallReview $receipt $candidate){StartVcBroker $receipt}
                else{
                    $script:flow=Move-FastLlmUiFlow -Flow $script:flow -Event 'setup-defer'
                    $statusLabel.Text='Microsoft VC++ download prepared; installation deferred.'
                    $output.Text='The reviewed package remains in the dedicated user cache. No installer was started.'
                }
            }
            'engine'{$script:flow=Move-FastLlmUiFlow -Flow $script:flow -Event 'engine-complete';LaunchUiPhase}
            'preview'{ContinueUiAfterPreview (ConvertFrom-Json $text)}
            'recipe list'{SetBusy $false;$statusLabel.Text='Choose another setup.';ContinueWithChosenRecipe (ShowRecipeChooser @((ConvertFrom-Json $text) | ForEach-Object { $_ }))}
            'component install'{
                if($script:planComponentInstall){$script:planComponentInstall=$false;$output.Text=$text;RepreviewForPendingSetup ''}
                else{$chosen=$script:pendingRecipeRow;$script:pendingRecipeRow=$null;$output.Text=$text;BeginChosenRecipe $chosen}
            }
            'model download'{$script:flow=Move-FastLlmUiFlow -Flow $script:flow -Event 'model-complete';LaunchUiPhase}
            'serving'{$script:flow=Move-FastLlmUiFlow -Flow $script:flow -Event 'serving-complete';SetBusy $false;$output.Text=$text;if(-not $script:updateRun -and -not $script:updateOutcome){$statusLabel.Text=Get-FastLlmUiServiceStoppedText -Status (GetUiBackgroundRunStatus)}}
            'diagnostics'{
                SetBusy $false;$output.Text=$text;$statusLabel.Text='Operation finished.'
                if(Test-FastLlmUiOutputWasCut -Text $text){$output.AppendText([Environment]::NewLine+[Environment]::NewLine+'The window can show only part of this report. For the full report run: fast-llm.ps1 doctor')}
            }
            default{SetBusy $false;$output.Text=$text;$statusLabel.Text='Operation finished.'}
        }
    }catch{
        if($script:child){$script:child.Dispose();$script:child=$null;$script:chatUrl=$null;$script:runReady=$false}
        if(-not $script:vcBroker -and $script:flow -and $script:flow.phase -eq 'setup-attention'){
            $script:flow=Move-FastLlmUiFlow -Flow $script:flow -Event 'setup-defer'
        }
        ShowFailure ('Setup needs attention: '+$_.Exception.Message)
    }
})
$script:bgNextPollUtc=[DateTime]::UtcNow.AddSeconds(2)
RefreshUiSwitchState
# A start at sign-in that was refused for the saved embeddings (no approved embedding model) is said plainly when the window opens.
try{$signInAttention=Get-FastLlmSignInAttentionText -InstallRoot (Get-FastLlmSignInDefaultInstallRoot);if($signInAttention){$output.Text=$signInAttention;$statusLabel.Text=$signInAttention}}catch{$null=$_}
StartUiBackgroundPoll
$form.Add_FormClosing({param($sender,$event)
    SetTrayMenuAvailable $false
    if(-not (Test-FastLlmUiVcActionAllowed -BrokerActive ($null -ne $script:vcBroker) -Action close)){
        $event.Cancel=$true
        $statusLabel.Text='Microsoft prerequisite setup is still running. Complete or cancel it in the Microsoft window before closing FastLLM.'
        SetTrayMenuAvailable $true
        return
    }
    if($script:updateRun){
        $event.Cancel=$true
        $statusLabel.Text='An update is running. Wait for it to finish before closing FastLLM.'
        SetTrayMenuAvailable $true
        return
    }
    if($script:child){
        if((ShowUiMessageBox $form 'Closing stops this window''s active download or inference process. Continue?' 'Close FastLLM' 'YesNo' 'Question') -ne 'Yes'){
            $event.Cancel=$true;SetTrayMenuAvailable $true;return
        }
        $script:child.Dispose();$script:child=$null
        if($script:flow){$script:flow=Move-FastLlmUiFlow -Flow $script:flow -Event stop}
    }
    # A running check or bundle save is stopped only once closing is confirmed (or when no run needed a confirmation).
    if($script:sideChild){$script:sideChild.Dispose();$script:sideChild=$null;$script:sideStep='idle'}
    $script:trayState=Move-FastLlmUiTrayState -State $script:trayState -Event 'close'
    DisposeTrayControls
    $timer.Stop()
    Close-FastLlmUiBackgroundPoll $script:bgPoll
    $script:bgPoll=$null
    Close-FastLlmUiBackgroundPoll $script:startupRun
    $script:startupRun=$null
})
$timer.Start()
try{Start-FastLlmUiFluentLoop}finally{
    if($script:child){$script:child.Dispose()}
    if($script:sideChild){$script:sideChild.Dispose()}
    Close-FastLlmUiBackgroundPoll $script:bgPoll
    # An elevated Microsoft broker is outside the ProcessHost job. Never kill or dispose it here.
    DisposeTrayControls;$timer.Dispose();$form.Dispose()
}
}
finally { if($labAppLifetime){$labAppLifetime.Dispose()} }
