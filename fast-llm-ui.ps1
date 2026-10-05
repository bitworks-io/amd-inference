#requires -Version 5.1
param([string]$InstallRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
if ($env:OS -ne 'Windows_NT') { throw 'The control window requires Windows PowerShell on Windows.' }
$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Open FastLLM as a standard user, not as administrator.' }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Import-Module (Join-Path $PSScriptRoot 'src/FastLlm.psm1') -Force
. (Join-Path $PSScriptRoot 'src/FastLlm.UiFlow.ps1')
. (Join-Path $PSScriptRoot 'src/FastLlm.UiPrerequisite.ps1')
& (Get-Module FastLlm) { Initialize-FastLlmProcessHost }
if (-not $InstallRoot) { $InstallRoot=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Bitworks\FastLLM' }
$catalog=Get-FastLlmCatalog (Join-Path $PSScriptRoot 'config/catalog.json')
$script:child=$null; $script:step='idle'; $script:selection=@(); $script:installPath=$InstallRoot; $script:flow=$null
$script:vcBroker=$null; $script:vcPrepared=$null
$script:vcCacheRoot=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Bitworks\FastLLM\prerequisites'
$script:vcManifestPath=Join-Path $PSScriptRoot 'config/windows-prerequisites.json'
$script:trayState=New-FastLlmUiTrayState; $script:trayIcon=$null; $script:trayMenu=$null
$form=New-Object Windows.Forms.Form
$form.Text='Bitworks FastLLM - Windows lab alpha'
$form.Size=New-Object Drawing.Size(880,690)
$form.MinimumSize=$form.Size
$form.StartPosition='CenterScreen'
$form.Font=New-Object Drawing.Font('Segoe UI',10)
$form.BackColor=[Drawing.Color]::FromArgb(245,247,250)
function LabelAt($Text,$X,$Y,$Width=800) {
    $control=New-Object Windows.Forms.Label
    $control.Text=$Text;$control.Location=New-Object Drawing.Point($X,$Y);$control.Size=New-Object Drawing.Size($Width,27)
    $form.Controls.Add($control);return $control
}
$title=LabelAt 'Local AMD inference, managed on this PC' 24 20
$title.Font=New-Object Drawing.Font('Segoe UI',18,[Drawing.FontStyle]::Bold);$title.Height=40
$notice=LabelAt 'LAB ALPHA - No Windows/GPU performance certification yet. Vulkan only. Text-only models.' 24 68
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
$pathBox.Location=New-Object Drawing.Point(24,208);$pathBox.Size=New-Object Drawing.Size(796,30);$pathBox.Text=$InstallRoot;$form.Controls.Add($pathBox)
function ButtonAt($Text,$X,$Y,$Width=150) {
    $button=New-Object Windows.Forms.Button;$button.Text=$Text;$button.Location=New-Object Drawing.Point($X,$Y);$button.Size=New-Object Drawing.Size($Width,38);$form.Controls.Add($button);return $button
}
$installButton=ButtonAt 'Install && start' 24 255 180
$startButton=ButtonAt 'Start / download' 220 255 180
$stopButton=ButtonAt 'Stop' 416 255 110
$doctorButton=ButtonAt 'Diagnostics' 542 255 130
$copyButton=ButtonAt 'Copy API URL' 688 255 132
$statusLabel=LabelAt 'Stopped. Install the AMD Vulkan driver and Microsoft VC++ x64 runtime first.' 24 309
$progress=New-Object Windows.Forms.ProgressBar
$progress.Location=New-Object Drawing.Point(24,341);$progress.Size=New-Object Drawing.Size(796,8);$progress.Style='Marquee';$progress.Visible=$false;$form.Controls.Add($progress)
$output=New-Object Windows.Forms.TextBox
$output.Location=New-Object Drawing.Point(24,368);$output.Size=New-Object Drawing.Size(796,214);$output.Multiline=$true;$output.ReadOnly=$true;$output.ScrollBars='Vertical';$form.Controls.Add($output)
$vc=New-Object Windows.Forms.LinkLabel;$vc.Text='Microsoft VC++ prerequisite';$vc.Location=New-Object Drawing.Point(24,598);$vc.AutoSize=$true;$form.Controls.Add($vc)
$amd=New-Object Windows.Forms.LinkLabel;$amd.Text='AMD Windows drivers';$amd.Location=New-Object Drawing.Point(290,598);$amd.AutoSize=$true;$form.Controls.Add($amd)
$trayButton=ButtonAt 'Minimize to tray' 440 591 175
$driverButton=ButtonAt 'Driver guidance' 630 591 190
$vc.Add_LinkClicked({try{Start-Process 'https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist'}catch{[void][Windows.Forms.MessageBox]::Show($form,'Unable to open Microsoft''s prerequisite page. Check your default browser. No software was installed.','Open prerequisite page','OK','Warning')}})
$amd.Add_LinkClicked({try{Start-Process 'https://www.amd.com/en/support/download/drivers.html'}catch{[void][Windows.Forms.MessageBox]::Show($form,'Unable to open AMD''s driver page. Check your default browser. No driver changes were made.','Open AMD page','OK','Warning')}})
function SetBusy([bool]$Busy) {
    foreach($control in @($installButton,$startButton,$doctorButton,$driverButton,$modelBox,$pathBox,$contextBox)){$control.Enabled=-not $Busy}
    $stopButton.Enabled=($null -eq $script:vcBroker)
    $trayButton.Enabled=($null -eq $script:vcBroker)
    $progress.Visible=$Busy
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
    $script:installPath=[IO.Path]::GetFullPath($pathBox.Text)
    $script:selection=@('-InstallRoot',$script:installPath,'-ContextSize',[string][int]$contextBox.Value)
    if($modelBox.SelectedIndex -gt 0){$script:selection+=@('-ModelId',[string]$modelBox.SelectedItem)}
}
function LaunchStep([string]$Step,[object[]]$Arguments) {
    if($script:child){throw 'A child operation is already active.'}
    if($script:vcBroker){throw 'Microsoft prerequisite setup is still running.'}
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=(Get-Process -Id $PID).Path
    if($Step -ceq 'vc prepare'){
        if(@($Arguments).Count -ne 0){throw 'VC++ preparation accepts no arbitrary child arguments.'}
        $argsList=Get-FastLlmUiVcPrepareArguments -ProjectRoot $PSScriptRoot -CacheRoot $script:vcCacheRoot
    }else{
        $argsList=@('-NoLogo','-NoProfile','-NonInteractive','-OutputFormat','Text','-File',(Join-Path $PSScriptRoot 'fast-llm.ps1'))+$Arguments
    }
    $info.Arguments=& (Get-Module FastLlm) {param($A) Join-FastLlmProcessArguments $A} $argsList
    $script:child=New-Object Bitworks.FastLlm.ProcessHost
    $script:step=$Step
    try{$script:child.Start($info)}catch{$script:child.Dispose();$script:child=$null;$script:step='idle';SetBusy $false;throw}
    SetBusy $true;$statusLabel.Text=$Step;$output.Text=''
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
        $statusLabel.Text='Action stopped. Review diagnostics; no compatibility claim was made.'
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
        $script:trayIcon.Text='Bitworks FastLLM - lab alpha'
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
        SetBusy $false;$statusLabel.Text='Stopped. Completed downloads remain; partial downloads can resume.'
    }else{Request-FastLlmStop -InstallRoot ([IO.Path]::GetFullPath($pathBox.Text))}
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
        'setup' { LaunchStep 'setup check' (@('doctor')+$script:selection);return }
        'engine' { LaunchStep 'engine' (@('install','-EngineOnly')+$script:selection);return }
        'preview' { LaunchStep 'preview' (@('plan','-AsJson')+$script:selection);return }
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
        'serving' { LaunchStep 'serving' (@('start','-Unattended')+$script:selection);return }
        default { throw "The control-window workflow cannot launch phase '$($script:flow.phase)'." }
    }
}
function ContinueUiAfterPreview($Plan) {
    $receipt=Test-FastLlmModelConsentReceipt -Model $Plan.model -InstallRoot $script:installPath
    $artifact=[bool]($Plan.modelPath -and (Test-Path -LiteralPath ([string]$Plan.modelPath) -PathType Leaf))
    $script:flow=Move-FastLlmUiFlow -Flow $script:flow -Event 'preview-complete' -Plan $Plan -HasConsent:$receipt -HasArtifact:$artifact
    if($script:flow.phase -eq 'failed'){ShowFailure $script:flow.lastStartError;return}
    $gpuNames=(@($Plan.selectedAdapters | ForEach-Object { [string]$_.name }) -join ' + ')
    $statusLabel.Text="Selected $($Plan.model.id) on $gpuNames; context $($Plan.model.contextSize)."
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
$installButton.Add_Click({try{ReadSelection;$script:flow=New-FastLlmUiFlow -Mode install;LaunchUiPhase}catch{ShowFailure $_.Exception.Message}})
$startButton.Add_Click({try{ReadSelection;$script:flow=New-FastLlmUiFlow -Mode start;LaunchUiPhase}catch{ShowFailure $_.Exception.Message}})
$doctorButton.Add_Click({try{ReadSelection;LaunchStep 'diagnostics' (@('doctor')+$script:selection)}catch{ShowFailure $_.Exception.Message}})
$driverButton.Add_Click({try{ReadSelection;LaunchStep 'driver guidance' (@('doctor')+$script:selection)}catch{ShowFailure $_.Exception.Message}})
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
    if(-not $script:child){return}
    try{
        $text=$script:child.Snapshot();$output.Text=$text;$output.SelectionStart=$output.TextLength;$output.ScrollToCaret()
        if(-not $script:child.Process.HasExited){
            if($script:step -eq 'serving'){
                try{$s=Get-FastLlmStatus $script:installPath;if($s.active -and $s.phase -eq 'ready'){$statusLabel.Text='Ready - API smoke tests passed; GPU residency/performance unqualified.';$progress.Visible=$false}}catch{}
            }
            return
        }
        $script:child.Process.WaitForExit();$text=$script:child.Snapshot();$code=$script:child.Process.ExitCode;$step=$script:step
        $script:child.Dispose();$script:child=$null;$script:step='idle'
        if($step -eq 'setup check'){
            if($code -notin @(0,2)){ShowFailure 'The read-only setup check could not complete. Open Diagnostics for details; no installation was attempted.';return}
            if([string]::IsNullOrWhiteSpace($text) -or $text.Length -gt 65536){throw 'The setup check returned no usable bounded diagnostic.'}
            $diagnostic=ConvertFrom-Json $text
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
            if($step -eq 'serving' -and $script:flow){
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
            'model download'{$script:flow=Move-FastLlmUiFlow -Flow $script:flow -Event 'model-complete';LaunchUiPhase}
            'serving'{$script:flow=Move-FastLlmUiFlow -Flow $script:flow -Event 'serving-complete';SetBusy $false;$output.Text=$text;$statusLabel.Text='Service stopped.'}
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
$form.Add_FormClosing({param($sender,$event)
    SetTrayMenuAvailable $false
    if(-not (Test-FastLlmUiVcActionAllowed -BrokerActive ($null -ne $script:vcBroker) -Action close)){
        $event.Cancel=$true
        $statusLabel.Text='Microsoft prerequisite setup is still running. Complete or cancel it in the Microsoft window before closing FastLLM.'
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
})
$timer.Start()
try{[Windows.Forms.Application]::EnableVisualStyles();[Windows.Forms.Application]::Run($form)}finally{
    if($script:child){$script:child.Dispose()}
    # An elevated Microsoft broker is outside the ProcessHost job. Never kill or dispose it here.
    DisposeTrayControls;$timer.Dispose();$form.Dispose()
}
