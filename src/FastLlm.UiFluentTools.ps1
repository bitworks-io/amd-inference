#requires -Version 5.1
# The Tools page of the Fluent window: the page XAML (FastLlm.Tools), its rows of the binding table, and the code that gives every greyed button its reason.
# Dot-sourced by FastLlm.UiFluentShell.ps1. No WPF or WinForms type is resolved at dot-source time, only inside function bodies. Every caption comes from
# the adapters (ConvertTo-FastLlmUiAccessText through the sinks); the headings and the reason lines are in $script:FastLlmUiFluentStrings (Home.ps1).
Set-StrictMode -Version 2.0

$script:FastLlmUiXaml['FastLlm.Tools'] = @'
<ScrollViewer xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
              xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
              VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Focusable="False">
  <StackPanel Margin="32,24,32,24" MaxWidth="900">
    <TextBlock x:Name="ToolsTitle" TextWrapping="Wrap" FontFamily="{DynamicResource FastLlm.DisplayFont}"
               FontSize="{DynamicResource FastLlm.SubtitleSize}" FontWeight="{DynamicResource FastLlm.SubtitleWeight}"/>
    <TextBlock x:Name="ToolsStatusText" Margin="0,4,0,0" TextWrapping="Wrap" Foreground="{DynamicResource FastLlm.TextSecondaryBrush}"
               AutomationProperties.LiveSetting="Polite"/>
    <TextBlock x:Name="ToolsTroubleshootingHeading" Margin="0,24,0,0" FontWeight="{DynamicResource FastLlm.BodyStrongWeight}"/>
    <WrapPanel Margin="0,8,0,0">
      <Button x:Name="ToolsDiagnosticsButton" Margin="0,0,8,8" Style="{DynamicResource FastLlm.ButtonStyle}"/>
      <Button x:Name="ToolsDriverButton" Margin="0,0,8,8" Style="{DynamicResource FastLlm.ButtonStyle}"/>
      <Button x:Name="ToolsBundleButton" Margin="0,0,8,8" Style="{DynamicResource FastLlm.ButtonStyle}"/>
      <Button x:Name="ToolsLogsButton" Margin="0,0,8,8" Style="{DynamicResource FastLlm.ButtonStyle}"/>
    </WrapPanel>
    <TextBlock x:Name="ToolsBackgroundHeading" Margin="0,16,0,0" FontWeight="{DynamicResource FastLlm.BodyStrongWeight}"/>
    <WrapPanel Margin="0,8,0,0">
      <Button x:Name="ToolsRecheckButton" Margin="0,0,8,8" Style="{DynamicResource FastLlm.ButtonStyle}"/>
      <Button x:Name="ToolsAttachButton" Margin="0,0,8,8" Style="{DynamicResource FastLlm.ButtonStyle}"/>
    </WrapPanel>
    <TextBlock x:Name="ToolsDownloadsHeading" Margin="0,16,0,0" FontWeight="{DynamicResource FastLlm.BodyStrongWeight}"/>
    <WrapPanel Margin="0,8,0,0">
      <Button x:Name="ToolsVcLink" Margin="0,0,16,8" Style="{DynamicResource FastLlm.LinkButtonStyle}"/>
      <Button x:Name="ToolsAmdLink" Margin="0,0,16,8" Style="{DynamicResource FastLlm.LinkButtonStyle}"/>
    </WrapPanel>
  </StackPanel>
</ScrollViewer>
'@

# The Tools rows of the binding table. ToolsAttachButton joins backgroundAttachButton, which Home already binds (Also); the card owns Home's visibility, not Tools'.
function Get-FastLlmUiFluentToolsBindings {
    [CmdletBinding()] param()
    return @(
        @{ Name = 'doctorButton';           Element = 'ToolsDiagnosticsButton'; Mode = 'Content'; Event = 'Click';       Flags = @() },
        @{ Name = 'driverButton';           Element = 'ToolsDriverButton';      Mode = 'Content'; Event = 'Click';       Flags = @() },
        @{ Name = 'bundleButton';           Element = 'ToolsBundleButton';      Mode = 'Content'; Event = 'Click';       Flags = @() },
        @{ Name = 'logsButton';             Element = 'ToolsLogsButton';        Mode = 'Content'; Event = 'Click';       Flags = @() },
        @{ Name = 'backgroundCheckButton';  Element = 'ToolsRecheckButton';     Mode = 'Content'; Event = 'Click';       Flags = @() },
        @{ Name = 'backgroundAttachButton'; Element = 'ToolsAttachButton';      Mode = 'Content'; Event = 'Click';       Flags = @(); Also = $true },
        @{ Name = 'vc';                     Element = 'ToolsVcLink';            Mode = 'Content'; Event = 'LinkClicked'; Flags = @() },
        @{ Name = 'amd';                    Element = 'ToolsAmdLink';           Mode = 'Content'; Event = 'LinkClicked'; Flags = @() }
    )
}

# The buttons that can say why they are greyed: element, adapter, and the Get-FastLlmUiGreyedReason action. Open logs has no reason code (it is never greyed
# by the state), and the two links are never disabled.
function Get-FastLlmUiFluentToolsReasonRows {
    [CmdletBinding()] param()
    return @(
        @{ Element = 'ToolsDiagnosticsButton'; Adapter = 'doctorButton';           Action = 'diagnostics' },
        @{ Element = 'ToolsDriverButton';      Adapter = 'driverButton';           Action = 'driverGuidance' },
        @{ Element = 'ToolsBundleButton';      Adapter = 'bundleButton';           Action = 'saveBundle' },
        @{ Element = 'ToolsRecheckButton';     Adapter = 'backgroundCheckButton';  Action = 'backgroundCheck' },
        @{ Element = 'ToolsAttachButton';      Adapter = 'backgroundAttachButton'; Action = 'backgroundAttach' }
    )
}

# The reason code from Get-FastLlmUiGreyedReason -> the key of its line in the string table. An empty code has no line.
function Get-FastLlmUiFluentToolsReasonText {
    [CmdletBinding()] param([AllowEmptyString()][string] $Code)
    $s = $script:FastLlmUiFluentStrings
    switch -CaseSensitive ($Code) {
        'busy' { return [string] $s.WhyBusy }
        'microsoft-setup' { return [string] $s.WhyMicrosoftSetup }
        'side-step' { return [string] $s.WhySideStep }
        'attached' { return [string] $s.WhyAttached }
        'no-run' { return [string] $s.WhyNoBackgroundRun }
        'not-running' { return [string] $s.WhyNotRunning }
    }
    return ''
}

# Collects the page's named elements into the flat Els map and sets its static text. Every name is Tools-prefixed (Els is one flat map).
function Initialize-FastLlmUiFluentTools {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Page, [Parameter(Mandatory = $true)][hashtable] $Els)
    $s = $script:FastLlmUiFluentStrings
    Add-FastLlmUiFluentElements -Els $Els -Root $Page -Names @('ToolsTitle', 'ToolsStatusText', 'ToolsTroubleshootingHeading', 'ToolsBackgroundHeading', 'ToolsDownloadsHeading',
        'ToolsDiagnosticsButton', 'ToolsDriverButton', 'ToolsBundleButton', 'ToolsLogsButton', 'ToolsRecheckButton', 'ToolsAttachButton', 'ToolsVcLink', 'ToolsAmdLink')
    $Els['ToolsTitle'].Text = [string] $s.NavTools
    $Els['ToolsTroubleshootingHeading'].Text = [string] $s.ToolsTroubleshooting
    $Els['ToolsBackgroundHeading'].Text = [string] $s.ToolsBackgroundRun
    $Els['ToolsDownloadsHeading'].Text = [string] $s.ToolsDownloads
    foreach ($row in (Get-FastLlmUiFluentToolsReasonRows)) {
        [System.Windows.Controls.ToolTipService]::SetShowOnDisabled($Els[[string] $row.Element], $true)
    }
    return $Els
}

# Tools' entry in the page registry. Its status line is the card's composed text, announced only while Tools is the current page.
function Register-FastLlmUiFluentToolsPage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Page, [Parameter(Mandatory = $true)][hashtable] $Els)
    Register-FastLlmUiFluentPage -Id 'Tools' -Element $Page -Nav 'NavTools' -Status $Els['ToolsStatusText'] -Update 'Update-FastLlmUiFluentTools'
}

# Once per tick while Tools shows: every disabled button says why, written to its ToolTip and HelpText only when the code changes. An enabled button, or a
# code with no line, shows nothing, so a shown reason is never wrong.
function Update-FastLlmUiFluentTools {
    [CmdletBinding()] param()
    $f = $script:FastLlmUiFluent
    $e = $f['Els']
    $keys = $f['Keys']
    $snapshot = GetUiStateSnapshot ([bool]($script:child -or $script:vcBroker -or $script:updateRun))
    foreach ($row in (Get-FastLlmUiFluentToolsReasonRows)) {
        $adapter = Get-Variable -Name ([string] $row.Adapter) -Scope Script -ValueOnly
        $code = ''
        if (-not [bool] $adapter.Enabled) { $code = [string] (Get-FastLlmUiGreyedReason -Action ([string] $row.Action) -Snapshot $snapshot) }
        $key = 'ToolsWhy:' + [string] $row.Element
        if ($keys[$key] -ceq $code) { continue }
        $keys[$key] = $code
        $element = $e[[string] $row.Element]
        $text = Get-FastLlmUiFluentToolsReasonText -Code $code
        if ($text -ne '') {
            $element.ToolTip = $text
            [System.Windows.Automation.AutomationProperties]::SetHelpText($element, $text)
        }
        else {
            $element.ToolTip = $null
            [System.Windows.Automation.AutomationProperties]::SetHelpText($element, '')
        }
    }
}
