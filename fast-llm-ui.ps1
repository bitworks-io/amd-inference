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
# Update and Trust are dot-sourced here, never imported through FastLlm.psm1.
. (Join-Path $PSScriptRoot 'src/FastLlm.Update.ps1')
# Components (the experimental switch and the list helpers) is dot-sourced here and in fast-llm.ps1, never imported through FastLlm.psm1.
. (Join-Path $PSScriptRoot 'src/FastLlm.Components.ps1')
& (Get-Module FastLlm) { Initialize-FastLlmProcessHost }
if (-not $InstallRoot) { $InstallRoot=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Bitworks\FastLLM' }
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
$script:bgPoll=$null
$script:startupRun=$null; $script:updateRun=$null; $script:updateOffer=$null; $script:updateOutcome=$false; $script:bannerUrl=$null
$form=New-Object Windows.Forms.Form
$form.Text='Bitworks FastLLM (Preview)'
$form.Size=New-Object Drawing.Size(880,941)
$form.MinimumSize=$form.Size
$form.StartPosition='CenterScreen'
$form.Font=New-Object Drawing.Font('Segoe UI',10)
$form.BackColor=[Drawing.Color]::FromArgb(245,247,250)
function LabelAt($Text,$X,$Y,$Width=800) {
    $control=New-Object Windows.Forms.Label
    $control.Text=$Text;$control.Location=New-Object Drawing.Point($X,$Y);$control.Size=New-Object Drawing.Size($Width,27)
    $control.UseMnemonic=$false
    $form.Controls.Add($control);return $control
}
$title=LabelAt 'Local AMD inference, managed on this PC' 24 20
$title.Font=New-Object Drawing.Font('Segoe UI',18,[Drawing.FontStyle]::Bold);$title.Height=40
$notice=LabelAt 'Preview. Windows + AMD Radeon. Vulkan or HIP engine. Text-only models.' 24 68
$notice.ForeColor=[Drawing.Color]::DarkRed
$null=LabelAt 'Model' 24 110 220
$modelBox=New-Object Windows.Forms.ComboBox
$modelBox.Location=New-Object Drawing.Point(24,138);$modelBox.Size=New-Object Drawing.Size(510,30);$modelBox.DropDownStyle='DropDownList'
$modelBox.Items.Add('Recommended for installed GPU')|Out-Null
foreach($model in $catalog.models) { if(-not $model.PSObject.Properties['autoEligible'] -or $model.autoEligible){$modelBox.Items.Add([string]$model.id)|Out-Null} }
$modelBox.SelectedIndex=0;$form.Controls.Add($modelBox)
$null=LabelAt 'Context (0 = catalog default)' 560 110 280
$contextBox=New-Object Windows.Forms.NumericUpDown
$contextBox.Location=New-Object Drawing.Point(560,138);$contextBox.Size=New-Object Drawing.Size(260,30);$contextBox.Maximum=32768;$contextBox.Increment=1024;$form.Controls.Add($contextBox)
$null=LabelAt 'Install and model cache folder' 24 180
$pathBox=New-Object Windows.Forms.TextBox
$pathBox.Location=New-Object Drawing.Point(24,208);$pathBox.Size=New-Object Drawing.Size(510,30);$pathBox.Text=$InstallRoot;$form.Controls.Add($pathBox)
$null=LabelAt 'Resizable BAR workaround' 560 180 260
$barBox=New-Object Windows.Forms.ComboBox
$barBox.Location=New-Object Drawing.Point(560,208);$barBox.Size=New-Object Drawing.Size(260,30);$barBox.DropDownStyle='DropDownList'
$script:barValues=@('auto','on','off')
foreach($barItem in @('Auto (recommended)','On','Off')){[void]$barBox.Items.Add($barItem)}
$script:uiSettings=Read-FastLlmUiSettings -InstallRoot $script:settingsRoot -AppRoot $PSScriptRoot
$barBox.SelectedIndex=[Array]::IndexOf($script:barValues,[string]$script:uiSettings.vulkanBarMitigation)
$form.Controls.Add($barBox)
function GetBarValue { return [string]$script:barValues[[Math]::Max(0,$barBox.SelectedIndex)] }
function ButtonAt($Text,$X,$Y,$Width=150) {
    $button=New-Object Windows.Forms.Button;$button.Text=$Text;$button.Location=New-Object Drawing.Point($X,$Y);$button.Size=New-Object Drawing.Size($Width,38);$form.Controls.Add($button);return $button
}
$installButton=ButtonAt 'Install && start' 24 255 180
$startButton=ButtonAt 'Start / download' 220 255 180
$stopButton=ButtonAt 'Stop' 416 255 110
$doctorButton=ButtonAt 'Diagnostics' 542 255 130
$copyButton=ButtonAt 'Copy API URL' 688 255 132
$backgroundStartButton=ButtonAt 'Start in background' 24 303 170
$backgroundAttachButton=ButtonAt 'Attach running' 202 303 130
$backgroundCheckButton=ButtonAt 'Recheck background' 340 303 160
$componentsButton=ButtonAt 'Components' 508 303 120
$chooseButton=ButtonAt 'Choose another setup' 636 303 184
# A chooser pick is pinned for the preview and the start of that workflow only; the plain Install / Start buttons clear it.
$script:previewReady=$false
$script:chosenRecipe=$null
$script:pendingRecipeRow=$null
$script:servingPreviousRunId=''
$script:identifiedVariant=''
$script:chooserNotice=''
$chooseButton.Enabled=$false
$backgroundLabel=LabelAt 'Checking background host ownership.' 24 350
$statusLabel=LabelAt 'Stopped. Install the AMD Vulkan driver and Microsoft VC++ x64 runtime first.' 24 382
$progress=New-Object Windows.Forms.ProgressBar
$progress.Location=New-Object Drawing.Point(24,414);$progress.Size=New-Object Drawing.Size(796,8);$progress.Style='Marquee';$progress.Visible=$false;$form.Controls.Add($progress)
$output=New-Object Windows.Forms.TextBox
$output.Location=New-Object Drawing.Point(24,440);$output.Size=New-Object Drawing.Size(796,206);$output.Multiline=$true;$output.ReadOnly=$true;$output.ScrollBars='Vertical';$form.Controls.Add($output)
$script:evidenceUrl=$null
$resultsLink=New-Object Windows.Forms.LinkLabel;$resultsLink.Text='See results';$resultsLink.Location=New-Object Drawing.Point(24,652);$resultsLink.AutoSize=$true;$resultsLink.Visible=$false;$form.Controls.Add($resultsLink)
$notesLabel=New-Object Windows.Forms.Label
$notesLabel.Location=New-Object Drawing.Point(24,676);$notesLabel.Size=New-Object Drawing.Size(796,80);$notesLabel.Text='';$form.Controls.Add($notesLabel)
$barLink=New-Object Windows.Forms.LinkLabel;$barLink.Text='How to turn it on';$barLink.Location=New-Object Drawing.Point(24,758);$barLink.AutoSize=$true;$barLink.Visible=$false;$form.Controls.Add($barLink)
$script:servingNotesDone=$false
$vc=New-Object Windows.Forms.LinkLabel;$vc.Text='Microsoft VC++ prerequisite';$vc.Location=New-Object Drawing.Point(24,785);$vc.AutoSize=$true;$form.Controls.Add($vc)
$amd=New-Object Windows.Forms.LinkLabel;$amd.Text='AMD Windows drivers';$amd.Location=New-Object Drawing.Point(290,785);$amd.AutoSize=$true;$form.Controls.Add($amd)
$trayButton=ButtonAt 'Minimize to tray' 440 778 175
$driverButton=ButtonAt 'Driver guidance' 630 778 190
$updateBox=New-Object Windows.Forms.CheckBox
$updateBox.Text='Check for updates';$updateBox.Location=New-Object Drawing.Point(300,757);$updateBox.AutoSize=$true
$updateBox.Checked=([string]$script:uiSettings.updateCheck -ceq 'on');$form.Controls.Add($updateBox)
$experimentalBox=New-Object Windows.Forms.CheckBox
$experimentalBox.Text='Experimental community components';$experimentalBox.Location=New-Object Drawing.Point(480,757);$experimentalBox.AutoSize=$true
$experimentalBox.Checked=([string]$script:uiSettings.experimentalComponents -ceq 'on');$form.Controls.Add($experimentalBox)
$script:experimentalRevert=$false
$licenseBox=New-Object Windows.Forms.CheckBox
$licenseBox.Text='Install engine components automatically (accept their licenses for me)';$licenseBox.Location=New-Object Drawing.Point(24,822);$licenseBox.AutoSize=$true
$licenseBox.Checked=([string](Get-FastLlmComponentLicenseSettings -InstallRoot $script:settingsRoot).mode -ceq 'accept-automatically');$form.Controls.Add($licenseBox)
$script:licenseRevert=$false
$script:useFallback=$false;$script:setupNotice='';$script:planComponentInstall=$false
# The top row is reserved for the banner, so everything above is shifted down by its height. Banner controls are added after the shift.
$script:bannerHeight=36
foreach($shifted in @($form.Controls)){$shifted.Top+=$script:bannerHeight}
$bannerLabel=New-Object Windows.Forms.Label
$bannerLabel.Location=New-Object Drawing.Point(24,6);$bannerLabel.Size=New-Object Drawing.Size(300,26);$bannerLabel.TextAlign='MiddleLeft';$bannerLabel.Visible=$false;$form.Controls.Add($bannerLabel)
$bannerNotes=New-Object Windows.Forms.LinkLabel
$bannerNotes.Text='Release notes';$bannerNotes.Location=New-Object Drawing.Point(340,11);$bannerNotes.AutoSize=$true;$bannerNotes.Visible=$false;$form.Controls.Add($bannerNotes)
$bannerButton=New-Object Windows.Forms.Button
$bannerButton.Text='Update';$bannerButton.Location=New-Object Drawing.Point(480,4);$bannerButton.Size=New-Object Drawing.Size(110,28);$bannerButton.Visible=$false;$form.Controls.Add($bannerButton)
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
$vc.Add_LinkClicked({try{Start-Process 'https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist'}catch{[void][Windows.Forms.MessageBox]::Show($form,'Unable to open Microsoft''s prerequisite page. Check your default browser. No software was installed.','Open prerequisite page','OK','Warning')}})
$amd.Add_LinkClicked({try{Start-Process 'https://www.amd.com/en/support/download/drivers.html'}catch{[void][Windows.Forms.MessageBox]::Show($form,'Unable to open AMD''s driver page. Check your default browser. No driver changes were made.','Open AMD page','OK','Warning')}})
$resultsLink.Add_LinkClicked({
    try{
        $checked=Get-FastLlmUiEvidenceUrl -Plan ([pscustomobject]@{recipe=[pscustomobject]@{evidenceUrl=$script:evidenceUrl}})
        if($checked){Start-Process ([string]$checked)}
    }catch{[void][Windows.Forms.MessageBox]::Show($form,'Unable to open the results page. Check your default browser.','Open results page','OK','Warning')}
})
$barLink.Add_LinkClicked({try{Start-Process 'https://github.com/bitworks-io/amd-inference/blob/main/docs/RESIZABLE-BAR.md'}catch{[void][Windows.Forms.MessageBox]::Show($form,'Unable to open the Resizable BAR page. Check your default browser.','Open Resizable BAR page','OK','Warning')}})
$barBox.Add_SelectedIndexChanged({
    try{Write-FastLlmUiSettings -InstallRoot $script:settingsRoot -Settings ([pscustomobject]@{vulkanBarMitigation=(GetBarValue)})}
    catch{$statusLabel.Text='The Resizable BAR setting could not be saved.'}
})
$bannerNotes.Add_LinkClicked({
    try{
        $target=[string]$script:bannerUrl
        if($target.StartsWith('https://github.com/bitworks-io/amd-inference/releases',[StringComparison]::Ordinal)){Start-Process $target}
    }catch{[void][Windows.Forms.MessageBox]::Show($form,'Unable to open the release page. Check your default browser.','Open release page','OK','Warning')}
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
            $answer=[Windows.Forms.MessageBox]::Show($form,$script:FastLlmExperimentalParagraph,'Experimental community components','YesNo','Warning','Button2')
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
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text='Install engine components automatically';$dialog.Size=New-Object Drawing.Size(700,420)
    $dialog.MinimumSize=$dialog.Size;$dialog.StartPosition='CenterParent';$dialog.Font=$form.Font
    $intro=New-Object Windows.Forms.Label
    $intro.Text='With this on, FastLLM installs engine components without asking again, and counts that as accepting the licenses below. Open each link and read it first. You can turn this off at any time.'
    $intro.Location=New-Object Drawing.Point(20,14);$intro.Size=New-Object Drawing.Size(640,64);$dialog.Controls.Add($intro)
    $top=86
    foreach($licenseLink in @($Disclosure.links)){
        if($licenseLink.url){
            $link=New-Object Windows.Forms.LinkLabel
            $link.Text=[string]$licenseLink.linkText;$link.Tag=[string]$licenseLink.url
            $link.Location=New-Object Drawing.Point(30,$top);$link.AutoSize=$true
            $link.Add_LinkClicked({param($sender,$clickArgs)
                try{
                    $target=Get-FastLlmUiSafeLicenseUrl -Url ([string]$sender.Tag)
                    if($target){Start-Process $target}
                }catch{[void][Windows.Forms.MessageBox]::Show($form,'Unable to open the license page. Check your default browser. Nothing was changed.','Open license page','OK','Warning')}
            })
            $dialog.Controls.Add($link)
        }else{
            $plain=New-Object Windows.Forms.Label
            $plain.Text=("{0} (this link cannot be opened from here)" -f [string]$licenseLink.title);$plain.Location=New-Object Drawing.Point(30,$top);$plain.AutoSize=$true
            $dialog.Controls.Add($plain)
        }
        $top+=26
    }
    $accept=New-Object Windows.Forms.Button
    $accept.Text='I accept these licenses';$accept.Location=New-Object Drawing.Point(300,330);$accept.Size=New-Object Drawing.Size(210,38)
    $accept.Anchor='Bottom,Right';$accept.Enabled=[bool]$Disclosure.canAccept
    $accept.DialogResult=[Windows.Forms.DialogResult]::OK;$dialog.Controls.Add($accept)
    $cancel=New-Object Windows.Forms.Button
    $cancel.Text='Cancel';$cancel.Location=New-Object Drawing.Point(530,330);$cancel.Size=New-Object Drawing.Size(120,38)
    $cancel.Anchor='Bottom,Right';$cancel.DialogResult=[Windows.Forms.DialogResult]::Cancel;$dialog.Controls.Add($cancel)
    # Enter and Escape cancel; accepting needs a click on the accept button.
    $dialog.AcceptButton=$cancel;$dialog.CancelButton=$cancel
    SetTrayMenuAvailable $false
    try{return $dialog.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK}finally{$dialog.Dispose();SetTrayMenuAvailable $true}
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
        }else{
            Set-FastLlmComponentLicenseSettingMirrored -SourceRoot $script:settingsRoot -TargetRoot $target -Mode 'ask'
        }
    }
    catch{
        $statusLabel.Text='The automatic install setting could not be saved: '+$_.Exception.Message
        $script:licenseRevert=$true;$licenseBox.Checked=(-not $wantedOn);$script:licenseRevert=$false
    }
})
function SetBusy([bool]$Busy) {
    $Busy=[bool]($Busy -or $script:updateRun)
    $occupied=[bool]($script:bgState.pendingRequestId -or $script:bgState.attachedRequestId -or
        $script:bgState.attention -or ($script:bgState.observation -and $script:bgState.observation.occupied))
    foreach($control in @($installButton,$startButton,$modelBox,$pathBox,$contextBox,$barBox)){$control.Enabled=(-not $Busy -and -not $occupied)}
    foreach($control in @($doctorButton,$driverButton)){$control.Enabled=-not $Busy}
    $chooseButton.Enabled=[bool](-not $Busy -and -not $occupied -and -not $script:vcBroker -and $script:previewReady)
    $backgroundStartButton.Enabled=(-not $Busy -and -not $script:vcBroker -and -not $script:child -and
        (Test-FastLlmUiBackgroundMayStart -State $script:bgState))
    $backgroundAttachButton.Enabled=(-not $Busy -and -not $script:vcBroker -and -not $script:child -and
        -not $script:bgState.attachedRequestId -and $script:bgState.observation -and
        ($script:bgState.observation.attachable -or
         ($script:bgState.observation.PSObject.Properties['readyIdentityVerified'] -and
          $script:bgState.observation.readyIdentityVerified)) -and
        (-not $script:bgState.pendingRequestId -or [string]$script:bgState.observation.requestId -ceq [string]$script:bgState.pendingRequestId))
    $backgroundCheckButton.Enabled=(-not $Busy -and -not $script:vcBroker -and -not $script:child)
    $stopButton.Enabled=($null -eq $script:vcBroker -and -not $script:bgStopRequested -and
        ($script:child -or $script:bgState.attachedRequestId -or -not $occupied))
    $trayButton.Enabled=($null -eq $script:vcBroker)
    $progress.Visible=$Busy
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
function ApplyUiBackgroundStatus($observation,[bool]$HealthChecked=$false) {
    $wasAttached=[bool]$script:bgState.attachedRequestId
    $wasPending=[bool]$script:bgState.pendingRequestId
    $observation | Add-Member -NotePropertyName uiHealthChecked -NotePropertyValue $HealthChecked -Force
    $null=Set-FastLlmUiBackgroundObservation -State $script:bgState -Observation $observation
    $null=Test-FastLlmUiBackgroundPendingHost -State $script:bgState -TestProcess {
        param($Identity) TestUiBackgroundProcess $Identity
    }
    $backgroundLabel.Text=Get-FastLlmUiBackgroundText -State $script:bgState
    if($wasAttached -and -not $script:bgState.attachedRequestId){
        $statusLabel.Text='Background run ended or changed. Its ownership has not been silently replaced.'
    }elseif($script:bgState.attachedRequestId -and $HealthChecked -and
            $script:bgState.observation.PSObject.Properties['servingHealthy'] -and
            -not $script:bgState.observation.servingHealthy){
        $statusLabel.Text='Background run owner is verified, but the API health check failed.'
    }elseif($script:bgState.attachedRequestId -and $HealthChecked -and $script:bgState.observation.attachable){
        $statusLabel.Text='Ready background inference attached. API health passed; GPU residency/performance unqualified.'
    }elseif($wasPending -and -not $script:bgState.pendingRequestId -and $script:bgState.attention){
        $statusLabel.Text='Background launch needs attention. Review Diagnostics before another start.'
    }
    if($script:bgState.observation -and -not $script:bgState.observation.active){$script:bgStopRequested=$false}
    SetBusy ([bool]($script:child -or $script:vcBroker))
}
function SetUiBackgroundUnknown {
    $script:bgState.observation=[pscustomobject]@{phase='occupied-unverified';active=$false;attachable=$false;occupied=$true}
    $script:bgState.attention='Background ownership could not be verified. Review Diagnostics; start and stop are disabled.'
    $backgroundLabel.Text=Get-FastLlmUiBackgroundText -State $script:bgState
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
    $script:useFallback=$false;$script:setupNotice='';$script:planComponentInstall=$false
    $script:installPath=[IO.Path]::GetFullPath($pathBox.Text)
    $script:selection=@('-InstallRoot',$script:installPath,'-ContextSize',[string][int]$contextBox.Value)
    if($modelBox.SelectedIndex -gt 0){$script:selection+=@('-ModelId',[string]$modelBox.SelectedItem)}
}
function LaunchStep([string]$Step,[object[]]$Arguments) {
    $script:updateOutcome=$false
    if($script:child){throw 'A child operation is already active.'}
    if($script:vcBroker){throw 'Microsoft prerequisite setup is still running.'}
    if($Step -in @('engine','model download','serving','component install')){AssertUiBackgroundNotOccupied}
    # The experimental switch is stored under the launch root, but the child reads it from the install folder it is given: mirror it there first.
    # A mirror failure blocks only the steps that read the switch.
    if($script:installPath){try{[void](Sync-FastLlmExperimentalSwitch -SourceRoot $script:settingsRoot -TargetRoot $script:installPath)}catch{if(Test-FastLlmUiStepReadsExperimentalSwitch -Arguments $Arguments){throw "The experimental components setting could not be applied to the install folder: $($_.Exception.Message)"}}}
    # The automatic-install setting is mirrored the same way; a mirror failure blocks only the steps that read it.
    if($script:installPath){try{[void](Sync-FastLlmComponentLicenseSetting -SourceRoot $script:settingsRoot -TargetRoot $script:installPath)}catch{if(Test-FastLlmUiStepReadsLicenseSetting -Arguments $Arguments){throw "The automatic install setting could not be applied to the install folder: $($_.Exception.Message)"}}}
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=(Get-Process -Id $PID).Path
    if($Step -ceq 'vc prepare'){
        if(@($Arguments).Count -ne 0){throw 'VC++ preparation accepts no arbitrary child arguments.'}
        $argsList=Get-FastLlmUiVcPrepareArguments -ProjectRoot $PSScriptRoot -CacheRoot $script:vcCacheRoot
    }else{
        $argsList=@('-NoLogo','-NoProfile','-NonInteractive','-OutputFormat','Text','-File',(Join-Path $PSScriptRoot 'fast-llm.ps1'))+$Arguments
    }
    $info.Arguments=& (Get-Module FastLlm) {param($A) Join-FastLlmProcessArguments $A} $argsList
    if($Step -ceq 'serving'){
        # Remember the previous run so a failure code left by an earlier run is never blamed on this start.
        $script:servingPreviousRunId=''
        try{$previousStatus=Get-FastLlmStatus $script:installPath;if($previousStatus.PSObject.Properties['runId']){$script:servingPreviousRunId=[string]$previousStatus.runId}}catch{}
    }
    $script:child=New-Object Bitworks.FastLlm.ProcessHost
    $script:step=$Step
    try{$script:child.Start($info)}catch{$script:child.Dispose();$script:child=$null;$script:step='idle';SetBusy $false;throw}
    SetBusy $true;$statusLabel.Text=$Step;$output.Text=''
    if($Step -ceq 'serving'){$script:servingNotesDone=$false;$notesLabel.Text='';$barLink.Visible=$false}
}
function RevealUiForAction {
    if($script:trayState.visibility -eq 'tray'){RestoreFromTray}
    if(-not $form.Visible){throw 'The control window could not be made visible for an action requiring attention.'}
}
function SetTrayMenuAvailable([bool]$Available) {
    if($script:trayMenu){
        foreach($item in $script:trayMenu.Items){
            $item.Enabled=if($script:vcBroker){$item.Text -ceq 'Restore FastLLM'}else{$Available}
        }
    }
}
function ShowFailure($Message){
    try{RevealUiForAction}catch{[void][Windows.Forms.MessageBox]::Show('FastLLM needs attention, but the control window could not be restored.','FastLLM','OK','Warning')}
    $output.Text=[string]$Message
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
        $script:trayIcon.Icon=[Drawing.SystemIcons]::Application
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
    if($script:child){
        $script:child.Dispose();$script:child=$null;$script:step='idle'
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
    RevealUiForAction
    $lines=New-Object 'System.Collections.Generic.List[string]'
    [void]$lines.Add('This PC is missing a required component for the current Vulkan lane. Review the latest setup check before continuing.')
    [void]$lines.Add('')
    if($Decision.missing64BitHost){[void]$lines.Add('Use 64-bit Windows PowerShell or PowerShell 7.')}
    if(@($Decision.missingVcRuntimeFiles).Count -gt 0){
        [void]$lines.Add("Install the current Microsoft Visual C++ 2015-2022 Redistributable (x64). Missing: $(@($Decision.missingVcRuntimeFiles) -join ', ').")
    }
    $candidate=GetVcCandidate
    $offer=Get-FastLlmUiVcOffer -Decision $Decision -InstallDecision (GetVcInstallDecision $Diagnostic.prerequisiteInventory $candidate)
    if(@($Decision.missingVcRuntimeFiles).Count -gt 0){[void]$lines.Add($offer.message)}
    if($Decision.missingVulkanLoader){[void]$lines.Add('Install an AMD Windows driver with Vulkan support. The System32 Vulkan loader is not present.')}
    [void]$lines.Add('')
    [void]$lines.Add('After prerequisite setup and any required reboot, choose Recheck. This reruns read-only diagnostics. Compatibility and GPU performance remain unqualified.')
    foreach($warning in @($Decision.advisoryWarnings)){[void]$lines.Add([string]$warning)}
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text='FastLLM setup check';$dialog.Size=New-Object Drawing.Size(720,450)
    $dialog.MinimumSize=$dialog.Size;$dialog.StartPosition='CenterParent';$dialog.Font=$form.Font
    $details=New-Object Windows.Forms.TextBox
    $details.Location=New-Object Drawing.Point(20,20);$details.Size=New-Object Drawing.Size(660,280)
    $details.Multiline=$true;$details.ReadOnly=$true;$details.ScrollBars='Vertical';$details.Text=($lines -join "`r`n")
    $dialog.Controls.Add($details)
    $msLink=New-Object Windows.Forms.LinkLabel
    $msLink.Text='Official Microsoft VC++ download information';$msLink.Location=New-Object Drawing.Point(20,315)
    $msLink.AutoSize=$true;$dialog.Controls.Add($msLink)
    $amdLink=New-Object Windows.Forms.LinkLabel
    $amdLink.Text='Official AMD driver downloads';$amdLink.Location=New-Object Drawing.Point(360,315)
    $amdLink.AutoSize=$true;$dialog.Controls.Add($amdLink)
    $msLink.Add_LinkClicked({try{Start-Process 'https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist'}catch{$details.Text='Unable to open the official Microsoft page. No software was installed.'}})
    $amdLink.Add_LinkClicked({try{Start-Process 'https://www.amd.com/en/support/download/drivers.html'}catch{$details.Text='Unable to open the official AMD page. No driver changes were made.'}})
    $recheck=New-Object Windows.Forms.Button
    $recheck.Text='Recheck';$recheck.Location=New-Object Drawing.Point(390,355);$recheck.Size=New-Object Drawing.Size(130,38)
    $recheck.DialogResult=[Windows.Forms.DialogResult]::Retry;$dialog.Controls.Add($recheck)
    $later=New-Object Windows.Forms.Button
    $later.Text='Do later';$later.Location=New-Object Drawing.Point(540,355);$later.Size=New-Object Drawing.Size(140,38)
    $later.DialogResult=[Windows.Forms.DialogResult]::Cancel;$dialog.Controls.Add($later)
    $prepare=New-Object Windows.Forms.Button
    $prepare.Text='Prepare && review VC++';$prepare.Location=New-Object Drawing.Point(20,355);$prepare.Size=New-Object Drawing.Size(225,38)
    $prepare.DialogResult=[Windows.Forms.DialogResult]::Yes;$prepare.Enabled=$offer.canPrepare
    $dialog.Controls.Add($prepare)
    $dialog.AcceptButton=$recheck;$dialog.CancelButton=$later
    SetTrayMenuAvailable $false
    try{
        $choice=$dialog.ShowDialog($form)
        if($choice -eq [Windows.Forms.DialogResult]::Retry){return 'recheck'}
        if($choice -eq [Windows.Forms.DialogResult]::Yes -and $offer.canPrepare){return 'prepare'}
        return 'defer'
    }finally{$dialog.Dispose();SetTrayMenuAvailable $true}
}
function ShowVcInstallReview($Receipt,$Candidate) {
    RevealUiForAction
    $review=Format-FastLlmUiVcReview -Receipt $Receipt -Candidate $Candidate -CacheRoot $script:vcCacheRoot
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text='Review Microsoft VC++ package and installation';$dialog.Size=New-Object Drawing.Size(850,680)
    $dialog.MinimumSize=$dialog.Size;$dialog.StartPosition='CenterParent';$dialog.Font=$form.Font
    $details=New-Object Windows.Forms.TextBox
    $details.Location=New-Object Drawing.Point(20,20);$details.Size=New-Object Drawing.Size(790,545)
    $details.Anchor='Top,Bottom,Left,Right';$details.Multiline=$true;$details.ReadOnly=$true
    $details.WordWrap=$true;$details.ScrollBars='Vertical';$details.Text=$review;$dialog.Controls.Add($details)
    $install=New-Object Windows.Forms.Button
    $install.Text='Install Microsoft runtime';$install.Location=New-Object Drawing.Point(465,585)
    $install.Size=New-Object Drawing.Size(210,42);$install.Anchor='Bottom,Right'
    $install.DialogResult=[Windows.Forms.DialogResult]::OK;$dialog.Controls.Add($install)
    $cancel=New-Object Windows.Forms.Button
    $cancel.Text='Do later';$cancel.Location=New-Object Drawing.Point(690,585)
    $cancel.Size=New-Object Drawing.Size(120,42);$cancel.Anchor='Bottom,Right'
    $cancel.DialogResult=[Windows.Forms.DialogResult]::Cancel;$dialog.Controls.Add($cancel)
    $dialog.AcceptButton=$cancel;$dialog.CancelButton=$cancel
    SetTrayMenuAvailable $false
    try{return $dialog.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK}
    finally{$dialog.Dispose();SetTrayMenuAvailable $true}
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
    RevealUiForAction
    $reviewText=Format-FastLlmUiModelConsent -Plan $Plan
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text='Review exact model license and artifact';$dialog.Size=New-Object Drawing.Size(850,680)
    $dialog.MinimumSize=$dialog.Size;$dialog.StartPosition='CenterParent';$dialog.Font=$form.Font
    $details=New-Object Windows.Forms.TextBox
    $details.Location=New-Object Drawing.Point(20,20);$details.Size=New-Object Drawing.Size(790,545)
    $details.Anchor='Top,Bottom,Left,Right';$details.Multiline=$true;$details.ReadOnly=$true
    $details.WordWrap=$true;$details.ScrollBars='Vertical';$details.Text=$reviewText
    $dialog.Controls.Add($details)
    $accept=New-Object Windows.Forms.Button
    $accept.Text='Accept license && download';$accept.Location=New-Object Drawing.Point(470,585)
    $accept.Size=New-Object Drawing.Size(205,42);$accept.Anchor='Bottom,Right'
    $accept.DialogResult=[Windows.Forms.DialogResult]::OK;$dialog.Controls.Add($accept)
    $cancel=New-Object Windows.Forms.Button
    $cancel.Text='Cancel';$cancel.Location=New-Object Drawing.Point(690,585)
    $cancel.Size=New-Object Drawing.Size(120,42);$cancel.Anchor='Bottom,Right'
    $cancel.DialogResult=[Windows.Forms.DialogResult]::Cancel;$dialog.Controls.Add($cancel)
    # Enter initially invokes Cancel. A deliberately focused Accept button remains
    # keyboard-accessible; Escape and closing without acceptance cancel.
    $dialog.AcceptButton=$cancel;$dialog.CancelButton=$cancel
    SetTrayMenuAvailable $false
    try{return $dialog.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK}finally{$dialog.Dispose();SetTrayMenuAvailable $true}
}
function LaunchUiPhase {
    if(-not $script:flow){throw 'No active control-window workflow.'}
    switch($script:flow.phase){
        'setup' { LaunchStep 'setup check' (@('doctor','-Compact')+$script:selection);return }
        'engine' { LaunchStep 'engine' (@('install','-EngineOnly')+$script:selection);return }
        'preview' { LaunchStep 'preview' (@('plan','-AsJson')+@(Get-FastLlmUiRecipeSelection -Selection $script:selection -Recipe $script:chosenRecipe)+@(Get-FastLlmUiPreviewRecipeArguments -Recipe $script:chosenRecipe -UseFallback:$script:useFallback));return }
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
            LaunchStep 'serving' (@('start','-Unattended','-VulkanBarMitigation',(GetBarValue))+@(Get-FastLlmUiStartRecipeArguments -Plan $script:flow.pendingPlan -ChosenRecipe $script:chosenRecipe)+@(Get-FastLlmUiRecipeSelection -Selection $script:selection -Recipe $script:chosenRecipe));return
        }
        default { throw "The control-window workflow cannot launch phase '$($script:flow.phase)'." }
    }
}
function RepreviewForPendingSetup([bool]$UseFallback) {
    $script:useFallback=$UseFallback
    $script:flow=Move-FastLlmUiFlow -Flow $script:flow -Event 'components-handled'
    if($script:flow.phase -eq 'failed'){ShowFailure $script:flow.lastStartError;return}
    LaunchUiPhase
    if($script:setupNotice){$statusLabel.Text=$script:setupNotice}
}
function HandlePendingSetup($Plan,$Decision) {
    switch($Decision.action){
        'fallback' {$script:setupNotice=[string]$Decision.notice;RepreviewForPendingSetup $true}
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
                RepreviewForPendingSetup $true
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
    RevealUiForAction
    if (-not $Diagnostic.PSObject.Properties['driverGuidance'] -or -not $Diagnostic.windows) {
        throw 'No Windows driver guidance report was returned.'
    }
    $entries=@($Diagnostic.driverGuidance)
    if ($entries.Count -eq 0) {
        $output.Text='No readable display-device guidance is available. Use Diagnostics for the inventory error and AMD Windows drivers to select your product manually.'
        $statusLabel.Text='Driver guidance unavailable. No driver changes made.'
        return
    }
    if ($entries.Count -gt 128) { throw 'Driver guidance exceeds the display-device limit.' }
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text='AMD driver guidance - read-only';$dialog.Size=New-Object Drawing.Size(780,590)
    $dialog.MinimumSize=$dialog.Size;$dialog.StartPosition='CenterParent';$dialog.Font=$form.Font
    $label=New-Object Windows.Forms.Label
    $label.Text='Choose a detected display device (not a verified serving-GPU match)'
    $label.Location=New-Object Drawing.Point(20,18);$label.Size=New-Object Drawing.Size(720,28);$dialog.Controls.Add($label)
    $devices=New-Object Windows.Forms.ComboBox
    $devices.Location=New-Object Drawing.Point(20,52);$devices.Size=New-Object Drawing.Size(720,30);$devices.DropDownStyle='DropDownList'
    for($i=0;$i -lt $entries.Count;$i++){[void]$devices.Items.Add("$($i+1). $($entries[$i].inputGpuName)")}
    $dialog.Controls.Add($devices)
    $details=New-Object Windows.Forms.TextBox
    $details.Location=New-Object Drawing.Point(20,96);$details.Size=New-Object Drawing.Size(720,390)
    $details.Multiline=$true;$details.ReadOnly=$true;$details.ScrollBars='Vertical';$dialog.Controls.Add($details)
    $openPage=New-Object Windows.Forms.Button
    $openPage.Text='Open official AMD page';$openPage.Location=New-Object Drawing.Point(20,498);$openPage.Size=New-Object Drawing.Size(220,36);$dialog.Controls.Add($openPage)
    $close=New-Object Windows.Forms.Button
    $close.Text='Close';$close.Location=New-Object Drawing.Point(620,498);$close.Size=New-Object Drawing.Size(120,36)
    $close.DialogResult=[Windows.Forms.DialogResult]::OK;$dialog.Controls.Add($close);$dialog.CancelButton=$close
    $devices.Add_SelectedIndexChanged({
        try{$details.Text=Format-FastLlmDriverGuidance -Guidance $entries[$devices.SelectedIndex];$openPage.Enabled=$true}
        catch{$details.Text='The advisory could not be validated. Use the main AMD Windows drivers link.';$openPage.Enabled=$false}
    })
    $openPage.Add_Click({
        try{
            $chosen=$entries[$devices.SelectedIndex]
            if($chosen.knownFocusModel){
                # Revalidate before opening; do not execute a URL from an unvalidated diagnostic.
                $null=Format-FastLlmDriverGuidance -Guidance $chosen
                Start-Process ([string]$chosen.productUrl)
            }else{Start-Process 'https://www.amd.com/en/support/download/drivers.html'}
        }catch{$details.Text='Unable to open the official AMD page. No driver changes were made.'}
    })
    SetTrayMenuAvailable $false
    try{$devices.SelectedIndex=0;[void]$dialog.ShowDialog($form)}finally{$dialog.Dispose();SetTrayMenuAvailable $true}
    $statusLabel.Text='Driver guidance viewed. No driver changes made.'
}
function StartUiBackground {
    if($script:child -or $script:vcBroker){throw 'Finish the active setup or foreground operation first.'}
    ReadSelection
    AssertUiBackgroundNotOccupied
    $selectedModel=if($modelBox.SelectedIndex -gt 0){[string]$modelBox.SelectedItem}else{$null}
    $request=[pscustomobject]@{sourceRoot=$PSScriptRoot;installRoot=$script:installPath;profile='balanced';
        modelId=$selectedModel;contextSize=[int]$contextBox.Value;vulkanBarMitigation=(GetBarValue)}
    $launched=Invoke-FastLlmUiBackgroundStart -State $script:bgState -Request $request -Start {
        param($Request)
        & (Get-Module FastLlm) {param($Source,$Project,$Install,$Profile,$Model,$Context,$BarMitigation)
            . $Source
            Start-FastLlmBackgroundHost -SourceRoot $Project -InstallRoot $Install -Profile $Profile `
                -ModelId $Model -ContextSize $Context -VulkanBarMitigation $BarMitigation -NoWait
        } (Join-Path $PSScriptRoot 'src/FastLlm.BackgroundHost.ps1') $Request.sourceRoot $Request.installRoot `
            $Request.profile $Request.modelId $Request.contextSize $Request.vulkanBarMitigation
    }
    $backgroundLabel.Text=Get-FastLlmUiBackgroundText -State $script:bgState
    $statusLabel.Text='Background host requested. It uses only a prepared, consented model and serves in this Windows user session.'
    $output.Text='This optional background mode is not a Windows service or auto-start task. Keep this user signed in; re-open FastLLM to attach later.'
    SetBusy $false
    return $launched
}
function AttachUiBackground {
    if($script:child -or $script:vcBroker){throw 'Finish the active setup or foreground operation first.'}
    ReadSelection
    RefreshUiBackgroundStatus
    $attached=Invoke-FastLlmUiBackgroundAttach -State $script:bgState -Attach {
        param($ExpectedRequestId)
        & (Get-Module FastLlm) {param($Source,$Project,$Install,$Request)
            . $Source
            Attach-FastLlmBackgroundHost -InstallRoot $Install -SourceRoot $Project -ExpectedRequestId $Request
        } (Join-Path $PSScriptRoot 'src/FastLlm.BackgroundHost.ps1') $PSScriptRoot $script:installPath $ExpectedRequestId
    }
    $script:bgState.observation | Add-Member -NotePropertyName uiHealthChecked -NotePropertyValue $true -Force
    $backgroundLabel.Text=Get-FastLlmUiBackgroundText -State $script:bgState
    $statusLabel.Text='Ready background inference attached. API smoke checks passed; residency and performance remain unqualified.'
    $output.Text="Attached to exact request $($attached.requestId) and run $($attached.runId). Closing this window detaches; Stop ends this run."
    SetBusy $false
}
$installButton.Add_Click({try{ReadSelection;AssertUiBackgroundNotOccupied;$script:chosenRecipe=$null;$script:flow=New-FastLlmUiFlow -Mode install;LaunchUiPhase}catch{ShowFailure $_.Exception.Message}})
$startButton.Add_Click({try{ReadSelection;AssertUiBackgroundNotOccupied;$script:chosenRecipe=$null;$script:flow=New-FastLlmUiFlow -Mode start;LaunchUiPhase}catch{ShowFailure $_.Exception.Message}})
$backgroundStartButton.Add_Click({
    try{$null=StartUiBackground}
    catch{
        $message=$_.Exception.Message
        RefreshUiBackgroundStatus
        ShowFailure ($message+"`r`nBackground mode needs an already prepared, consented model. Use Install & start first, then Stop and try Start in background.")
    }
})
$backgroundAttachButton.Add_Click({try{AttachUiBackground}catch{RefreshUiBackgroundStatus;ShowFailure $_.Exception.Message}})
$backgroundCheckButton.Add_Click({
    try{
        ReadSelection;RefreshUiBackgroundStatus
        if(-not $script:bgState.pendingRequestId -and -not $script:bgState.observation.occupied){
            $null=Clear-FastLlmUiBackgroundAttention -State $script:bgState
        }
        $backgroundLabel.Text=Get-FastLlmUiBackgroundText -State $script:bgState
        $statusLabel.Text='Background ownership check completed.'
        SetBusy $false
    }catch{ShowFailure $_.Exception.Message}
})
$doctorButton.Add_Click({try{ReadSelection;LaunchStep 'diagnostics' (@('doctor')+$script:selection)}catch{ShowFailure $_.Exception.Message}})
$driverButton.Add_Click({try{ReadSelection;LaunchStep 'driver guidance' (@('doctor')+$script:selection)}catch{ShowFailure $_.Exception.Message}})
# The installed components with their sizes and a Remove button per row. Removal is Remove-FastLlmComponent, which refuses while the server uses the component.
$script:componentsView=$null
function FillComponentsPanel {
    $view=$script:componentsView
    foreach($old in @($view.panel.Controls)){$old.Dispose()}
    try{$rows=@(Get-FastLlmInstalledComponentRows -Inventory @(Get-FastLlmComponentInventory -ComponentsPath $view.file -InstallRoot $view.root))}
    catch{$rows=@();$view.message.Text="The component list could not be read: $($_.Exception.Message)"}
    if($rows.Count -eq 0){
        $none=New-Object Windows.Forms.Label
        $none.Text='No community components are installed.';$none.Location=New-Object Drawing.Point(8,12);$none.Size=New-Object Drawing.Size(640,26)
        $view.panel.Controls.Add($none)
        return
    }
    $top=8
    foreach($row in $rows){
        $rowLabel=New-Object Windows.Forms.Label
        $rowLabel.Text=[string]$row.label;$rowLabel.Location=New-Object Drawing.Point(8,($top+6));$rowLabel.Size=New-Object Drawing.Size(530,26)
        $removeButton=New-Object Windows.Forms.Button
        $removeButton.Text='Remove';$removeButton.Tag=[string]$row.id;$removeButton.Location=New-Object Drawing.Point(548,$top);$removeButton.Size=New-Object Drawing.Size(110,32)
        $removeButton.Add_Click({param($sender,$clickArgs)RemoveComponentFromWindow ([string]$sender.Tag)})
        $view.panel.Controls.Add($rowLabel);$view.panel.Controls.Add($removeButton)
        $top+=40
    }
}
function RemoveComponentFromWindow([string]$ComponentId) {
    $view=$script:componentsView
    $answer=[Windows.Forms.MessageBox]::Show($view.dialog,"Remove the component '$ComponentId'? Its files are deleted from this PC. You can install it again later.",'Remove component','YesNo','Question','Button2')
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
function ShowComponentsWindow {
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text='FastLLM components';$dialog.Size=New-Object Drawing.Size(720,440)
    $dialog.MinimumSize=$dialog.Size;$dialog.StartPosition='CenterParent';$dialog.Font=$form.Font
    $panel=New-Object Windows.Forms.Panel
    $panel.Location=New-Object Drawing.Point(20,20);$panel.Size=New-Object Drawing.Size(660,270);$panel.AutoScroll=$true;$panel.BorderStyle='FixedSingle'
    $message=New-Object Windows.Forms.Label
    $message.Location=New-Object Drawing.Point(20,300);$message.Size=New-Object Drawing.Size(660,50);$message.Text=''
    $close=New-Object Windows.Forms.Button
    $close.Text='Close';$close.Location=New-Object Drawing.Point(570,360);$close.Size=New-Object Drawing.Size(110,32);$close.DialogResult='Cancel'
    $dialog.Controls.Add($panel);$dialog.Controls.Add($message);$dialog.Controls.Add($close)
    $dialog.CancelButton=$close
    $script:componentsView=@{dialog=$dialog;panel=$panel;message=$message;root=[IO.Path]::GetFullPath($pathBox.Text);file=(Join-Path $PSScriptRoot 'config/components.json')}
    try{FillComponentsPanel;[void]$dialog.ShowDialog($form)}
    finally{$script:componentsView=$null;$dialog.Dispose()}
}
$componentsButton.Add_Click({try{ShowComponentsWindow}catch{ShowFailure $_.Exception.Message}})
# "Choose another setup": the recipes the CLI lists for this card (`recipes -Detail -AsJson`, read-only and offline), experimental ones only while the switch is on.
# Choosing one whose engine chain needs an AMD license opens the consent dialog; Install runs the component install as a child, then the start uses -Recipe.
# Both dialogs are disposed only after ShowDialog returns, never inside one of their own control handlers (as in the Components window).
function StartRecipeList {
    if(-not $script:previewReady){throw 'Preview a setup first (Start / download), then choose another.'}
    ReadSelection
    LaunchStep 'recipe list' @('recipes','-Detail','-AsJson','-InstallRoot',$script:installPath)
}
function ShowRecipeChooser($Rows) {
    RevealUiForAction
    $switchValue=if($experimentalBox.Checked){'on'}else{'off'}
    $variant=[string]$script:identifiedVariant
    $shown=@(Get-FastLlmUiChooserRows -Rows @($Rows) -ExperimentalComponents $switchValue -Variant $variant)
    # What the list lacks is said out loud (an unidentified card, no setup for this card, the switch on without any experimental setup).
    $script:chooserNotice=[string](Get-FastLlmUiChooserNotice -Shown $shown -ExperimentalComponents $switchValue -Variant $variant)
    if($script:chooserNotice){$statusLabel.Text=$script:chooserNotice}
    if($shown.Count -eq 0){return $null}
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text='Choose another setup';$dialog.Size=New-Object Drawing.Size(960,470)
    $dialog.MinimumSize=$dialog.Size;$dialog.StartPosition='CenterParent';$dialog.Font=$form.Font
    $intro=New-Object Windows.Forms.Label
    $intro.Text='Setups for your card. Pick one, then Choose. Experimental setups are shown only while Experimental community components is on. Nothing is downloaded until you confirm.'
    if($script:chooserNotice){$intro.Text+=" $($script:chooserNotice)"}
    $intro.Location=New-Object Drawing.Point(20,14);$intro.Size=New-Object Drawing.Size(900,40)
    $list=New-Object Windows.Forms.ListView
    $list.Location=New-Object Drawing.Point(20,60);$list.Size=New-Object Drawing.Size(900,290);$list.View='Details'
    $list.FullRowSelect=$true;$list.MultiSelect=$false;$list.HideSelection=$false;$list.GridLines=$true
    [void]$list.Columns.Add('Setup',250);[void]$list.Columns.Add('Model',170);[void]$list.Columns.Add('Context',100);[void]$list.Columns.Add('Engine and sources',360)
    foreach($row in $shown){
        $item=New-Object Windows.Forms.ListViewItem ([string]$row.label)
        [void]$item.SubItems.Add([string]$row.model);[void]$item.SubItems.Add([string]$row.contextText);[void]$item.SubItems.Add([string]$row.engineText)
        $item.Tag=[string]$row.id
        [void]$list.Items.Add($item)
    }
    $choose=New-Object Windows.Forms.Button
    $choose.Text='Choose';$choose.Location=New-Object Drawing.Point(660,370);$choose.Size=New-Object Drawing.Size(130,36);$choose.Enabled=$false
    $choose.DialogResult=[Windows.Forms.DialogResult]::OK
    $cancel=New-Object Windows.Forms.Button
    $cancel.Text='Cancel';$cancel.Location=New-Object Drawing.Point(800,370);$cancel.Size=New-Object Drawing.Size(120,36)
    $cancel.DialogResult=[Windows.Forms.DialogResult]::Cancel
    $list.Add_SelectedIndexChanged({$choose.Enabled=($list.SelectedItems.Count -eq 1)}.GetNewClosure())
    $list.Add_DoubleClick({if($list.SelectedItems.Count -eq 1){$dialog.DialogResult=[Windows.Forms.DialogResult]::OK}}.GetNewClosure())
    $dialog.Controls.Add($intro);$dialog.Controls.Add($list);$dialog.Controls.Add($choose);$dialog.Controls.Add($cancel)
    # Enter chooses the selected row (the Choose button is disabled until a row is selected); Esc cancels.
    $dialog.AcceptButton=$choose;$dialog.CancelButton=$cancel
    $picked=$null
    SetTrayMenuAvailable $false
    try{
        if($dialog.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK -and $list.SelectedItems.Count -eq 1){
            $pickedId=[string]$list.SelectedItems[0].Tag
            $picked=@($shown|Where-Object{[string]$_.id -ceq $pickedId})[0]
        }
    }finally{$dialog.Dispose();SetTrayMenuAvailable $true}
    return $picked
}
# The consent dialog: one row per component the install would download, with its source host, its license links (opened in the browser, no license text
# here) and an "I accept" box. Install is enabled only while every box is ticked; Cancel downloads nothing.
$script:consentView=$null
function UpdateConsentInstallState {
    $view=$script:consentView
    if(-not $view){return}
    $ticked=@($view.boxes|ForEach-Object{[bool]$_.Checked})
    $view.install.Enabled=[bool](Test-FastLlmUiConsentComplete -RowCount $view.boxes.Count -Ticked $ticked)
}
function ShowComponentConsent($Row,[object[]]$ConsentRows,[bool]$Chosen=$true) {
    RevealUiForAction
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text='Install engine components';$dialog.Size=New-Object Drawing.Size(800,620)
    $dialog.MinimumSize=$dialog.Size;$dialog.StartPosition='CenterParent';$dialog.Font=$form.Font
    $boldFont=New-Object Drawing.Font($form.Font,[Drawing.FontStyle]::Bold)
    $intro=New-Object Windows.Forms.Label
    $intro.Text=Get-FastLlmUiComponentIntro -Model ([string]$Row.model) -ContextText ([string]$Row.contextText) -Chosen $Chosen
    $intro.Location=New-Object Drawing.Point(20,14);$intro.Size=New-Object Drawing.Size(740,58)
    $panel=New-Object Windows.Forms.Panel
    $panel.Location=New-Object Drawing.Point(20,80);$panel.Size=New-Object Drawing.Size(740,420);$panel.AutoScroll=$true;$panel.BorderStyle='FixedSingle'
    $boxes=New-Object 'System.Collections.Generic.List[object]'
    $top=10
    foreach($consentRow in $ConsentRows){
        $nameLabel=New-Object Windows.Forms.Label
        $nameLabel.Text=("{0} ({1}) - {2}" -f [string]$consentRow.name,[string]$consentRow.version,[string]$consentRow.statusText);$nameLabel.Font=$boldFont
        $nameLabel.Location=New-Object Drawing.Point(10,$top);$nameLabel.Size=New-Object Drawing.Size(700,24)
        $sourceText="Source: $([string]$consentRow.sourceText)"
        if(@($consentRow.redirectHosts).Count -gt 0){$sourceText+="; the download may be redirected via $(@($consentRow.redirectHosts) -join ', ')"}
        $sourceLabel=New-Object Windows.Forms.Label
        $sourceLabel.Text=$sourceText;$sourceLabel.Location=New-Object Drawing.Point(10,($top+26));$sourceLabel.Size=New-Object Drawing.Size(700,40)
        $panel.Controls.Add($nameLabel);$panel.Controls.Add($sourceLabel)
        $top+=68
        foreach($licenseLink in @($consentRow.links)){
            if($licenseLink.url){
                $link=New-Object Windows.Forms.LinkLabel
                $link.Text=[string]$licenseLink.linkText;$link.Tag=[string]$licenseLink.url
                $link.Location=New-Object Drawing.Point(24,$top);$link.AutoSize=$true
                $link.Add_LinkClicked({param($sender,$clickArgs)
                    try{
                        $target=Get-FastLlmUiSafeLicenseUrl -Url ([string]$sender.Tag)
                        if($target){Start-Process $target}
                    }catch{[void][Windows.Forms.MessageBox]::Show($form,'Unable to open the license page. Check your default browser. Nothing was downloaded.','Open license page','OK','Warning')}
                })
                $panel.Controls.Add($link)
            }else{
                $plain=New-Object Windows.Forms.Label
                $plain.Text=("{0} (this link cannot be opened from here, so this component cannot be accepted)" -f [string]$licenseLink.title);$plain.Location=New-Object Drawing.Point(24,$top);$plain.AutoSize=$true
                $panel.Controls.Add($plain)
            }
            $top+=24
        }
        # An installed or built-in component is a read-only row; only a missing one has a box, and a blocked one cannot be ticked.
        if($consentRow.needsAccept){
            $box=New-Object Windows.Forms.CheckBox
            $box.Text=[string]$consentRow.acceptText;$box.Tag=[string]$consentRow.id;$box.Enabled=(-not $consentRow.blocked)
            $box.Location=New-Object Drawing.Point(10,($top+4));$box.Size=New-Object Drawing.Size(700,26)
            $box.Add_CheckedChanged({UpdateConsentInstallState})
            $panel.Controls.Add($box);$boxes.Add($box)
        }
        $top+=48
    }
    $install=New-Object Windows.Forms.Button
    $install.Text='Install';$install.Location=New-Object Drawing.Point(500,520);$install.Size=New-Object Drawing.Size(130,38);$install.Enabled=$false
    $install.DialogResult=[Windows.Forms.DialogResult]::OK
    $cancel=New-Object Windows.Forms.Button
    $cancel.Text='Cancel';$cancel.Location=New-Object Drawing.Point(640,520);$cancel.Size=New-Object Drawing.Size(120,38)
    $cancel.DialogResult=[Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($intro);$dialog.Controls.Add($panel);$dialog.Controls.Add($install);$dialog.Controls.Add($cancel)
    # Enter and Escape cancel; Install is reached only by clicking it once enabled.
    $dialog.AcceptButton=$cancel;$dialog.CancelButton=$cancel
    $script:consentView=@{install=$install;boxes=$boxes}
    $confirmed=$false
    $ticked=@()
    SetTrayMenuAvailable $false
    try{
        $confirmed=[bool]($dialog.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK)
        $ticked=@($boxes|ForEach-Object{[bool]$_.Checked})
    }finally{$script:consentView=$null;$boldFont.Dispose();$dialog.Dispose();SetTrayMenuAvailable $true}
    return [pscustomobject]@{confirmed=$confirmed;ticked=$ticked}
}
function BeginChosenRecipe($Row) {
    ReadSelection
    AssertUiBackgroundNotOccupied
    $script:chosenRecipe=[pscustomobject]@{id=[string]$Row.id;origin=[string]$Row.origin}
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
[pscustomobject]@{integrity=$integrity;update=$update}
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
            $offer=Format-FastLlmUiUpdateBanner -Check $values[0].update
            if($failedIntegrity){SetUiBanner $failedIntegrity.text $failedIntegrity.url $true $false}
            elseif($offer){
                $script:updateOffer=[pscustomobject]@{version=[string]$values[0].update.latest.version;latest=$values[0].update.latest}
                SetUiBanner $offer.text $offer.url $false $true
            }
        }
    }catch{}
    finally{try{$run.pipeline.Dispose()}catch{}}
}
function InvokeUiUpdate {
    if(-not $script:updateOffer -or $script:updateRun){return}
    if($script:child -or $script:vcBroker){$statusLabel.Text='Finish or stop the current action before updating.';return}
    $version=[string]$script:updateOffer.version
    $choice=[Windows.Forms.MessageBox]::Show($form,(Format-FastLlmUiUpdateConfirm -Version $version),'Update FastLLM','YesNo','Question','Button2')
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
        $script:updateRun=[pscustomobject]@{pipeline=$pipeline;handle=$pipeline.BeginInvoke();version=$version}
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
    $statusLabel.Text=Format-FastLlmUiUpdateResult -Result $result -Version $run.version
    if([string]$result.status -ceq 'installed'){$script:updateOffer=$null;SetUiBanner '' '' $false $false}
    elseif(Test-FastLlmUiUpdateIntegrityFailure -Result $result){$script:updateOffer=$null;SetUiBanner $statusLabel.Text $script:FastLlmUiReleasesUrlPrefix $true $false}
    else{$bannerButton.Enabled=$true}
}
$bannerButton.Add_Click({try{InvokeUiUpdate}catch{$statusLabel.Text='Update not installed: '+$_.Exception.Message+'. Nothing was changed.'}})
$form.Add_Shown({try{StartUiStartupChecks}catch{}})
$copyButton.Add_Click({[Windows.Forms.Clipboard]::SetText('http://127.0.0.1:8080/v1')})
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
    if(-not $script:child){return}
    try{
        $text=$script:child.Snapshot();$output.Text=$text;$output.SelectionStart=$output.TextLength;$output.ScrollToCaret()
        if(-not $script:child.Process.HasExited){
            if($script:step -eq 'serving'){
                try{$s=Get-FastLlmStatus $script:installPath;if($s.active -and $s.phase -eq 'ready'){$statusLabel.Text=Format-FastLlmUiReadyStatus -State $s;$progress.Visible=$false;$script:evidenceUrl=Get-FastLlmUiRunEvidenceUrl -State $s;$resultsLink.Visible=[bool]$script:evidenceUrl}
                    if($s.active -and $s.phase -eq 'ready' -and -not $script:servingNotesDone){
                        $lines=@()
                        $setupLine=Get-FastLlmUiRunSetupLine -State $s
                        if($setupLine){$lines+=$setupLine}
                        if($script:setupNotice){$lines+=[string]$script:setupNotice}
                        if($s.PSObject.Properties['selfTest'] -and $s.selfTest){$lines+=Format-FastLlmUiSelfTest -SelfTest $s.selfTest;$script:servingNotesDone=$true}
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
            SetBusy $false;ShowDriverGuidance (ConvertFrom-Json $text);return
        }
        if($code -ne 0){
            if($step -eq 'vc prepare'){
                if($script:flow -and $script:flow.phase -eq 'setup-attention'){
                    $script:flow=Move-FastLlmUiFlow -Flow $script:flow -Event 'setup-defer'
                }
                ShowFailure 'The Microsoft VC++ package could not be downloaded and verified. No installer was started. Use the official Microsoft link or try setup again later.'
                return
            }
            if($step -eq 'component install'){$script:pendingRecipeRow=$null;$script:planComponentInstall=$false}
            if($step -eq 'serving' -and $script:flow){
                # A typed failure (HIP backend unavailable, blocked DLL, device not found or ambiguous, a missing component) is shown as its own
                # message and is not retried: the window never falls back to another setup.
                $failureCode=''
                try{$failureCode=Get-FastLlmUiFailureCode -Status (Get-FastLlmStatus $script:installPath) -PreviousRunId ([string]$script:servingPreviousRunId)}catch{}
                if(Test-FastLlmUiTypedHipFailure -Code $failureCode){
                    $script:flow=Move-FastLlmUiFlow -Flow $script:flow -Event 'error' -ErrorMessage $text
                    ShowFailure (Format-FastLlmUiTypedFailure -Code $failureCode -Text $text);return
                }
                $script:flow=Move-FastLlmUiFlow -Flow $script:flow -Event 'serving-failed' -ErrorMessage $text
                if($script:flow.phase -eq 'preview'){LaunchUiPhase;return}
            }
            ShowFailure $text;return
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
                if($script:planComponentInstall){$script:planComponentInstall=$false;$output.Text=$text;RepreviewForPendingSetup $false}
                else{$chosen=$script:pendingRecipeRow;$script:pendingRecipeRow=$null;$output.Text=$text;BeginChosenRecipe $chosen}
            }
            'model download'{$script:flow=Move-FastLlmUiFlow -Flow $script:flow -Event 'model-complete';LaunchUiPhase}
            'serving'{$script:flow=Move-FastLlmUiFlow -Flow $script:flow -Event 'serving-complete';SetBusy $false;$output.Text=$text;if(-not $script:updateRun -and -not $script:updateOutcome){$statusLabel.Text='Service stopped.'}}
            default{SetBusy $false;$output.Text=$text;$statusLabel.Text='Operation finished.'}
        }
    }catch{
        if($script:child){$script:child.Dispose();$script:child=$null}
        if(-not $script:vcBroker -and $script:flow -and $script:flow.phase -eq 'setup-attention'){
            $script:flow=Move-FastLlmUiFlow -Flow $script:flow -Event 'setup-defer'
        }
        ShowFailure ('Setup needs attention: '+$_.Exception.Message)
    }
})
$script:bgNextPollUtc=[DateTime]::UtcNow.AddSeconds(2)
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
        if([Windows.Forms.MessageBox]::Show($form,'Closing stops this window''s active download or inference process. Continue?','Close FastLLM','YesNo','Question') -ne 'Yes'){
            $event.Cancel=$true;SetTrayMenuAvailable $true;return
        }
        $script:child.Dispose();$script:child=$null
        if($script:flow){$script:flow=Move-FastLlmUiFlow -Flow $script:flow -Event stop}
    }
    $script:trayState=Move-FastLlmUiTrayState -State $script:trayState -Event 'close'
    DisposeTrayControls
    $timer.Stop()
    Close-FastLlmUiBackgroundPoll $script:bgPoll
    $script:bgPoll=$null
    Close-FastLlmUiBackgroundPoll $script:startupRun
    $script:startupRun=$null
})
$timer.Start()
try{[Windows.Forms.Application]::EnableVisualStyles();[Windows.Forms.Application]::Run($form)}finally{
    if($script:child){$script:child.Dispose()}
    Close-FastLlmUiBackgroundPoll $script:bgPoll
    # An elevated Microsoft broker is outside the ProcessHost job. Never kill or dispose it here.
    DisposeTrayControls;$timer.Dispose();$form.Dispose()
}
}
finally { if($labAppLifetime){$labAppLifetime.Dispose()} }
