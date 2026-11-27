#requires -Version 5.1
# Binds the main-window control names to adapters for the Fluent window. fast-llm-ui.ps1 dot-sources this file (through the shell file), so
# "Script" scope below is the window script's own scope: each name is rebound there, and the orchestration code reads the adapters unchanged.
# The initial state replicates the classic creation block of fast-llm-ui.ps1 (labels, buttons, boxes, hidden and disabled defaults).
# The form is not touched here; the shell creates the form adapter.

# One row per control name: name, adapter kind, initial text (null: leave it empty).
function Get-FastLlmUiFluentControlTable {
    [CmdletBinding()] param()
    $ellipsis=[string][char]0x2026
    return @(
        @('title','Label','Local AMD inference, managed on this PC'),
        @('notice','Label','Preview. Windows + AMD Radeon. Vulkan or HIP engine. Text-only models.'),
        @('backgroundLabel','Label','Checking background host ownership.'),
        @('statusLabel','Label','Not running. Install & start sets up and starts the best setup for your card.'),
        @('switchLabel','Label',''),
        @('notesLabel','Label',''),
        @('bannerLabel','Label',''),
        @('installButton','Button','Install && start'),
        @('startButton','Button','Start / download'),
        @('stopButton','Button','Stop'),
        @('doctorButton','Button','Diagnostics'),
        @('copyButton','Button','Copy API URL'),
        @('backgroundStartButton','Button','Start in background'),
        @('backgroundAttachButton','Button','Attach running'),
        @('backgroundCheckButton','Button','Recheck background'),
        @('componentsButton','Button','Components'),
        @('chooseButton','Button','Choose another setup'),
        @('settingsButton','Button',('Settings'+$ellipsis)),
        @('connectButton','Button','Connect an app'),
        @('openChatButton','Button','Open chat'),
        @('modelsButton','Button','Downloaded models'),
        @('bundleButton','Button',('Save support bundle'+$ellipsis)),
        @('logsButton','Button','Open logs'),
        @('switchButton','Button',('Switch model'+$ellipsis)),
        @('trayButton','Button','Minimize to tray'),
        @('driverButton','Button','Driver guidance'),
        @('bannerButton','Button','Update'),
        @('reinstallButton','Button','Reinstall previous version'),
        @('resultsLink','LinkLabel','See results'),
        @('failureCopyLink','LinkLabel','Copy full output'),
        @('barLink','LinkLabel','How to turn it on'),
        @('vc','LinkLabel','Microsoft VC++ prerequisite'),
        @('amd','LinkLabel','AMD Windows drivers'),
        @('bannerNotes','LinkLabel','Release notes'),
        @('updateBox','CheckBox','Check for updates'),
        @('experimentalBox','CheckBox','Experimental community components'),
        @('licenseBox','CheckBox','Install engine components automatically (accept their licenses for me)'),
        @('modelBox','ComboBox',''),
        @('barBox','ComboBox',''),
        @('contextBox','NumericUpDown',''),
        @('pathBox','TextBox',''),
        @('output','TextBox',''),
        @('progress','ProgressBar','')
    )
}

function Initialize-FastLlmUiFluentBindings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)]$UiSettings
    )
    $made=[ordered]@{}
    foreach($row in (Get-FastLlmUiFluentControlTable)){
        $adapter=New-FastLlmUiAdapter -Kind $row[1] -Name $row[0]
        if($row[1] -ne 'ToolTip' -and $row[1] -ne 'ComboBox' -and $row[1] -ne 'NumericUpDown' -and $row[1] -ne 'ProgressBar'){$adapter.Text=[string]$row[2]}
        $made[$row[0]]=$adapter
    }
    # Labels made by LabelAt (and switchLabel) switch off the access key; notesLabel and bannerLabel keep the WinForms default.
    foreach($n in 'title','notice','backgroundLabel','statusLabel','switchLabel'){$made[$n].UseMnemonic=$false}
    $made['statusLabel'].AutoEllipsis=$true
    $made['switchLabel'].AutoEllipsis=$true

    $modelBox=$made['modelBox']
    [void]$modelBox.Items.Add('Recommended for installed GPU')
    foreach($pickerId in @(Get-FastLlmUiPickerModelIds -Catalog $Catalog)){ [void]$modelBox.Items.Add($pickerId) }
    $modelBox.SelectedIndex=0
    $made['contextBox'].Maximum=32768
    $made['contextBox'].Increment=1024
    $made['pathBox'].Text=$InstallRoot
    $barValues=@('auto','on','off')
    foreach($barItem in @('Auto (recommended)','On','Off')){[void]$made['barBox'].Items.Add($barItem)}
    $made['barBox'].SelectedIndex=[Array]::IndexOf($barValues,[string]$UiSettings.vulkanBarMitigation)
    $made['output'].Multiline=$true
    $made['output'].ReadOnly=$true
    $made['progress'].Style='Marquee'

    $made['updateBox'].Checked=([string]$UiSettings.updateCheck -ceq 'on')
    $made['experimentalBox'].Checked=([string]$UiSettings.experimentalComponents -ceq 'on')
    $made['licenseBox'].Checked=([string](Get-FastLlmComponentLicenseSettings -InstallRoot $InstallRoot).mode -ceq 'accept-automatically')

    foreach($n in 'openChatButton','chooseButton','switchButton'){$made[$n].Enabled=$false}
    foreach($n in 'progress','resultsLink','failureCopyLink','barLink','bannerLabel','bannerNotes','bannerButton','reinstallButton'){$made[$n].Visible=$false}

    foreach($n in $made.Keys){ Set-Variable -Name $n -Value $made[$n] -Scope Script }
    return $made
}
