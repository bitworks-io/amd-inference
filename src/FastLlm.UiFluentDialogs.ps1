#requires -Version 5.1
# The dialog host of the Fluent window: one constant-XAML dialog (title, body, right-aligned footer buttons), the owner rules, and the fluent message box.
# Dot-sourced by FastLlm.UiFluentShell.ps1. No WPF or WinForms type is resolved at dot-source time, only inside function bodies.
# Enter and Escape never come from IsDefault or IsCancel: the dialog Window reads them in PreviewKeyDown and answers through the key plan
# (Get-FastLlmUiDialogKeyPlan in FastLlm.UiState.ps1), so a dialog keeps exactly today's Enter and Escape targets.
Set-StrictMode -Version 2.0

# The message box answers, id to the [System.Windows.Forms.DialogResult] member name. The box returns the enum value, never the string, so every classic
# comparison (-ne 'Yes', -eq [Windows.Forms.DialogResult]::OK) behaves exactly as with a system MessageBox.
$script:FastLlmUiFluentDialogResultNames = @{ OK = 'OK'; Cancel = 'Cancel'; Yes = 'Yes'; No = 'No' }

# Message box icons: the glyph (drawn, never read) and the help text of the body (the role the system box announces: Warning, Information or nothing).
$script:FastLlmUiFluentDialogIcons = @{
    None        = @{ Glyph = 0;      Help = '' }
    Information = @{ Glyph = 0xE946; Help = 'Information' }
    Warning     = @{ Glyph = 0xE7BA; Help = 'Warning' }
    Question    = @{ Glyph = 0xE897; Help = '' }
    Error       = @{ Glyph = 0xEA39; Help = '' }
}

# The dialog: a Grid with a decorative icon slot, a scrolling body slot and a footer of buttons. Every visible string is set from code (Text, never markup).
# The footer is a UniformGrid, so a caption wraps inside its button at large text; its Resources carry the wrapping AccessText and TextBlock styles.
$script:FastLlmUiXaml['FastLlm.Dialog'] = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="SingleBorderWindow" ResizeMode="NoResize" ShowInTaskbar="False" SizeToContent="Height"
        UseLayoutRounding="True" SnapsToDevicePixels="True"
        KeyboardNavigation.TabNavigation="Cycle" KeyboardNavigation.ControlTabNavigation="Cycle"
        FontFamily="{DynamicResource FastLlm.TextFont}" FontSize="{DynamicResource FastLlm.BodySize}"
        Foreground="{DynamicResource FastLlm.TextPrimaryBrush}" Background="{DynamicResource FastLlm.LayerBrush}">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <Grid Grid.Row="0" Margin="24,24,24,20">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <Border x:Name="DlgIconHost" Grid.Column="0" VerticalAlignment="Top" Margin="0,0,16,0"/>
      <ScrollViewer x:Name="DlgBodyScroll" Grid.Column="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" IsTabStop="False"/>
    </Grid>
    <Border Grid.Row="1" Background="{DynamicResource FastLlm.CardBrush}" BorderBrush="{DynamicResource FastLlm.ControlStrokeBrush}" BorderThickness="0,1,0,0" Padding="24,16,24,16">
      <UniformGrid x:Name="DlgFooter" Rows="1" HorizontalAlignment="Right">
        <UniformGrid.Resources>
          <Style TargetType="AccessText"><Setter Property="TextWrapping" Value="Wrap"/></Style>
          <Style TargetType="TextBlock"><Setter Property="TextWrapping" Value="Wrap"/><Setter Property="TextAlignment" Value="Center"/></Style>
        </UniformGrid.Resources>
      </UniformGrid>
    </Border>
  </Grid>
</Window>
'@

# The window a dialog is owned by. The form adapter, $script:form, $null and anything else that is not a dialog mean the main window; an open dialog's
# hashtable (or a Window) means that window. Returns $null when there is no main window yet.
function Resolve-FastLlmUiFluentDialogOwner {
    [CmdletBinding()]
    param($Owner)
    if ($Owner -is [System.Collections.IDictionary] -and $Owner.Contains('Window')) { return $Owner['Window'] }
    if ($Owner -is [System.Windows.Window]) { return $Owner }
    $state = Get-Variable -Name FastLlmUiFluent -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($state -is [System.Collections.IDictionary] -and $state.Contains('Window')) { return $state['Window'] }
    return $null
}

# Builds a dialog. Buttons is an ordered id -> caption table (ids are strings: OK, Cancel, Yes, No, or a form's own). Enter and Escape are button ids or ''.
# CloseEnabled false means the close box and Alt+F4 are refused until a button answers. Returns @{ Window; Els; Buttons; State }; Buttons maps id -> Button.
function New-FastLlmUiFluentDialog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Title,
        [Parameter(Mandatory = $true)] $Body,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Buttons,
        [AllowEmptyString()][string] $Enter = '',
        [AllowEmptyString()][string] $Escape = '',
        [bool] $CloseEnabled = $true,
        $Owner = $null
    )
    $win = New-FastLlmUiXamlElement -Name 'FastLlm.Dialog'
    $ownerWindow = Resolve-FastLlmUiFluentDialogOwner -Owner $Owner
    $scale = 1.0
    if ($null -ne $ownerWindow) {
        # The owner's resources carry the styles and the live theme dictionary, so the dialog follows the theme.
        $win.Resources.MergedDictionaries.Add($ownerWindow.Resources)
        $size = $ownerWindow.TryFindResource('FastLlm.BodySize')
        if ($size -is [double] -and $size -gt 0) { $scale = [Math]::Min([Math]::Max($size / 14.0, 1.0), 2.25) }
    }
    $work = [System.Windows.SystemParameters]::WorkArea
    $win.Title = $Title
    [System.Windows.Automation.AutomationProperties]::SetName($win, $Title)
    $win.Width = [Math]::Min($work.Width * 0.9, 480.0 * $scale)
    $win.MaxHeight = $work.Height * 0.95
    $els = @{ Window = $win }
    foreach ($name in 'DlgIconHost', 'DlgBodyScroll', 'DlgFooter') { $els[$name] = $win.FindName($name) }
    # The body scrolls past about 60% of the work area; the footer stays in view.
    $els['DlgBodyScroll'].MaxHeight = $work.Height * 0.6
    $els['DlgBodyScroll'].Content = $Body
    $els['Body'] = $Body

    $state = @{ Result = ''; Enter = $Enter; Escape = $Escape; CloseEnabled = $CloseEnabled }
    $buttonMap = @{}
    $first = $true
    foreach ($id in @($Buttons.Keys)) {
        $caption = [string] $Buttons[$id]
        $button = New-Object System.Windows.Controls.Button
        # The accept button may be accent, but Enter is never IsDefault: the key plan answers it (so a focused button is pressed by Enter as itself).
        $styleKey = 'FastLlm.ButtonStyle'
        if ([string] $id -ceq $Enter) { $styleKey = 'FastLlm.AccentButtonStyle' }
        $button.SetResourceReference([System.Windows.FrameworkElement]::StyleProperty, $styleKey)
        $button.Content = ConvertTo-FastLlmUiAccessText -Text $caption -UseMnemonic $false
        $button.MinWidth = 88
        if (-not $first) { $button.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0) }
        $first = $false
        # A Button whose Content is not a plain string has no automation name, and AccessText content is not one: the caption names it.
        [System.Windows.Automation.AutomationProperties]::SetName($button, $caption)
        $button.Tag = [string] $id
        if ([string] $id -cmatch '^[A-Za-z][A-Za-z0-9_]*$') { $button.Name = [string] $id }
        $null = $els['DlgFooter'].Children.Add($button)
        $buttonMap[[string] $id] = $button
    }
    $els['DlgFooter'].Columns = [Math]::Max(1, $buttonMap.Count)

    $close = {
        param([string] $Id)
        if ([string] $state['Result'] -ceq '') { $state['Result'] = $Id }
        $win.Close()
    }.GetNewClosure()
    foreach ($id in @($buttonMap.Keys)) {
        $answer = [string] $id
        $buttonMap[$id].Add_Click({ & $close $answer }.GetNewClosure())
    }
    # Enter (unless a button has the focus, which presses itself, or a multi-line box wants the key) answers the Enter target; Escape answers the Escape target
    # and, with none, is swallowed so the dialog stays.
    $win.Add_PreviewKeyDown({
        param($sender, $e)
        $focused = [System.Windows.Input.Keyboard]::FocusedElement
        if ($e.Key -eq [System.Windows.Input.Key]::Return) {
            # A focused button is pressed by Enter as itself, as on a system box. The dialog does it here rather than leaving it to the Button, whose own
            # Enter handling depends on KeyboardNavigation.AcceptsReturn: a footer button answers its id; any other button gets its Click.
            if ($focused -is [System.Windows.Controls.Button]) {
                $e.Handled = $true
                $focusedId = [string] $focused.Tag
                if ($buttonMap.ContainsKey($focusedId) -and [object]::ReferenceEquals($buttonMap[$focusedId], $focused)) { & $close $focusedId }
                else { $focused.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)) }
                return
            }
            if ($focused -is [System.Windows.Controls.TextBox] -and [bool] $focused.AcceptsReturn) { return }
            if ([string] $state['Enter'] -cne '') { $e.Handled = $true; & $close ([string] $state['Enter']) }
        }
        elseif ($e.Key -eq [System.Windows.Input.Key]::Escape) {
            $e.Handled = $true
            if ([string] $state['Escape'] -cne '') { & $close ([string] $state['Escape']) }
        }
    }.GetNewClosure())
    # The close box, Alt+F4 and the owner closing all arrive here: with the close box enabled they answer the Escape target, otherwise they are refused.
    $win.Add_Closing({
        param($sender, $e)
        if ([string] $state['Result'] -cne '') { return }
        if ([bool] $state['CloseEnabled']) { $state['Result'] = [string] $state['Escape']; return }
        $e.Cancel = $true
    }.GetNewClosure())
    # The first focus is the Enter target (as a MessageBox focuses its default button), else the Escape target, else the first button.
    $target = $null
    foreach ($candidate in @($Enter, $Escape)) {
        if ($null -eq $target -and [string] $candidate -cne '' -and $buttonMap.ContainsKey([string] $candidate)) { $target = $buttonMap[[string] $candidate] }
    }
    if ($null -eq $target -and $buttonMap.Count -gt 0) { $target = $buttonMap[[string] @($Buttons.Keys)[0]] }
    $els['Focus'] = $target
    if ($null -ne $target) {
        $win.Add_Loaded({ $null = $target.Focus(); $null = [System.Windows.Input.Keyboard]::Focus($target) }.GetNewClosure())
    }

    # An owner that is shown owns the dialog (centred on it, no taskbar button). A hidden owner (the tray) is not set: the dialog still shows, centred on the screen.
    if ($null -ne $ownerWindow -and [bool] $ownerWindow.IsVisible) {
        try { $win.Owner = $ownerWindow; $win.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterOwner } catch { $win.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterScreen }
    }
    else {
        $win.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterScreen
        $win.ShowInTaskbar = $true
    }
    $result = @{ Window = $win; Els = $els; Buttons = $buttonMap; State = $state }
    # The test answerer finds the id -> Button map through Window.Tag.
    $win.Tag = $result
    return $result
}

# Shows a dialog modally and returns the id that closed it. The owner is disabled while it is open, and the 250 ms tick keeps running in its nested frame.
function Show-FastLlmUiFluentDialog {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary] $Dialog)
    $null = $Dialog['Window'].ShowDialog()
    return [string] $Dialog['State']['Result']
}

# Puts the message box icon in the dialog's icon slot: a decorative glyph (UI Automation never sees it). None leaves the slot empty.
function Set-FastLlmUiFluentDialogIcon {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary] $Dialog, [string] $Icon = 'None')
    $row = $script:FastLlmUiFluentDialogIcons[$Icon]
    if ($null -eq $row) { $row = $script:FastLlmUiFluentDialogIcons['None'] }
    if ([int] $row['Glyph'] -eq 0) { $Dialog['Els']['DlgIconHost'].Visibility = [System.Windows.Visibility]::Collapsed; return }
    $glyph = New-Object Bitworks.FastLlm.DecorativeTextBlock
    $glyph.Text = New-FastLlmUiFluentGlyphText ([int] $row['Glyph'])
    $glyph.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe Fluent Icons, Segoe MDL2 Assets')
    $glyph.FontSize = 28
    $glyph.Foreground = $Dialog['Window'].TryFindResource('FastLlm.AccentFillBrush')
    $Dialog['Els']['DlgIconHost'].Child = $glyph
}

# A message box answer id as the [System.Windows.Forms.DialogResult] a system MessageBox returns (a table, never a string).
function ConvertTo-FastLlmUiFluentDialogResult {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Id)
    $name = $script:FastLlmUiFluentDialogResultNames[$Id]
    if ($null -eq $name) { throw ("Unknown message box answer '" + $Id + "'") }
    return [System.Enum]::Parse([System.Windows.Forms.DialogResult], [string] $name)
}

# The fluent message box: the same arguments as a system MessageBox (Buttons OK, OKCancel or YesNo; Icon; DefaultButton Button1 or Button2) and the same
# answers, as [System.Windows.Forms.DialogResult]. Enter, Escape and the close box come from the key plan.
function Show-FastLlmUiFluentMessageBox {
    [CmdletBinding()]
    param(
        $Owner = $null,
        [string] $Text = '',
        [string] $Caption = '',
        [string] $Buttons = 'OK',
        [string] $Icon = 'None',
        [string] $DefaultButton = 'Button1'
    )
    $plan = Get-FastLlmUiDialogKeyPlan -Buttons $Buttons -DefaultButton $DefaultButton
    $s = $script:FastLlmUiFluentStrings
    $captions = @{ OK = [string] $s.BoxOK; Cancel = [string] $s.BoxCancel; Yes = [string] $s.BoxYes; No = [string] $s.BoxNo }
    $table = [ordered] @{}
    foreach ($id in @($plan['order'])) { $table[[string] $id] = [string] $captions[[string] $id] }
    $body = New-Object System.Windows.Controls.TextBlock
    $body.Text = $Text
    $body.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $iconRow = $script:FastLlmUiFluentDialogIcons[$Icon]
    if ($null -ne $iconRow -and [string] $iconRow['Help'] -cne '') { [System.Windows.Automation.AutomationProperties]::SetHelpText($body, [string] $iconRow['Help']) }
    $dialog = New-FastLlmUiFluentDialog -Title $Caption -Body $body -Buttons $table -Enter ([string] $plan['enter']) -Escape ([string] $plan['escape']) -CloseEnabled ([bool] $plan['closeEnabled']) -Owner $Owner
    Set-FastLlmUiFluentDialogIcon -Dialog $dialog -Icon $Icon
    $answer = Show-FastLlmUiFluentDialog -Dialog $dialog
    # No answer (the owner closed under the box): the close answer, else the last button (No, Cancel or OK), never an accept.
    if ($answer -ceq '') { $answer = [string] $plan['close'] }
    if ($answer -ceq '') { $answer = [string] @($plan['order'])[-1] }
    return (ConvertTo-FastLlmUiFluentDialogResult -Id $answer)
}

# The words of the side result and driver guidance dialogs, copied byte-identical from ShowUiSideResult and ShowDriverGuidance in fast-llm-ui.ps1
# (a members pin compares every value below with its classic literal). Url is the page the generic button opens. DetailsName is the one string that is not
# a classic literal: the guidance box has no label of its own today, so it takes the device label as its name and LabeledBy (one string, see below).
$script:FastLlmUiFluentDialogText = [ordered]@{
    SideClose     = 'Close'
    GuidanceTitle = 'AMD driver guidance - read-only'
    GuidanceLabel = 'Choose a detected display device (not a verified serving-GPU match)'
    OpenPage      = 'Open official AMD page'
    GuidanceClose = 'Close'
    NoReport      = 'No Windows driver guidance report was returned.'
    NoEntries     = 'No readable display-device guidance is available. Use Diagnostics for the inventory error and AMD Windows drivers to select your product manually.'
    NoEntriesStatus = 'Driver guidance unavailable. No driver changes made.'
    TooMany       = 'Driver guidance exceeds the display-device limit.'
    Invalid       = 'The advisory could not be validated. Use the main AMD Windows drivers link.'
    OpenFailed    = 'Unable to open the official AMD page. No driver changes were made.'
    Viewed        = 'Driver guidance viewed. No driver changes made.'
    Url           = 'https://www.amd.com/en/support/download/drivers.html'
}

# The text scale of the dialogs (the owner's body size over 14, clamped to 1.0 .. 2.25), as New-FastLlmUiFluentDialog derives it.
function Get-FastLlmUiFluentDialogScale {
    [CmdletBinding()]
    param($Owner = $null)
    $scale = 1.0
    $ownerWindow = Resolve-FastLlmUiFluentDialogOwner -Owner $Owner
    if ($null -ne $ownerWindow) {
        $size = $ownerWindow.TryFindResource('FastLlm.BodySize')
        if ($size -is [double] -and $size -gt 0) { $scale = [Math]::Min([Math]::Max($size / 14.0, 1.0), 2.25) }
    }
    return [double] $scale
}

# A read-only, wrapping, mono TextBox for a dialog body: its own scrollbar once it passes MaxHeight, no undo, never in markup.
function New-FastLlmUiFluentDialogReadBox {
    [CmdletBinding()]
    param([AllowEmptyString()][string] $Text = '', [double] $MinHeight = 96, [double] $MaxHeight = 360)
    $box = New-Object System.Windows.Controls.TextBox
    $box.IsReadOnly = $true
    $box.IsUndoEnabled = $false
    $box.AcceptsReturn = $true
    $box.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $box.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $box.HorizontalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Disabled
    $box.SetResourceReference([System.Windows.Controls.Control]::FontFamilyProperty, 'FastLlm.MonoFont')
    $box.MinHeight = $MinHeight
    $box.MaxHeight = $MaxHeight
    $box.Text = $Text
    return $box
}

# A side result (API format check, support bundle list): the text in a read-only mono box, and Close, which answers Enter and Escape as today. Returns nothing.
function Show-FastLlmUiFluentSideResult {
    [CmdletBinding()]
    param([string] $Title, [string] $Text)
    $t = $script:FastLlmUiFluentDialogText
    $scale = Get-FastLlmUiFluentDialogScale -Owner $script:form
    $box = New-FastLlmUiFluentDialogReadBox -Text $Text -MinHeight (96 * $scale) -MaxHeight (360 * $scale)
    $box.Name = 'SideResultText'
    [System.Windows.Automation.AutomationProperties]::SetName($box, $Title)
    $buttons = [ordered] @{ Close = [string] $t.SideClose }
    $dialog = New-FastLlmUiFluentDialog -Title $Title -Body $box -Buttons $buttons -Enter 'Close' -Escape 'Close' -Owner $script:form
    $work = [System.Windows.SystemParameters]::WorkArea
    $dialog['Window'].Width = [Math]::Min($work.Width * 0.9, 760.0 * $scale)
    $null = Show-FastLlmUiFluentDialog -Dialog $dialog
}

# Driver guidance: the same checks, texts and flow as ShowDriverGuidance. A device list, the guidance of the chosen device, "Open official AMD page" (never
# closes) and Close (Escape). There is no Enter target, as today (the classic form has no AcceptButton). Returns nothing.
function Show-FastLlmUiFluentDriverGuidance {
    [CmdletBinding()]
    param($Diagnostic)
    RevealUiForAction
    $t = $script:FastLlmUiFluentDialogText
    if (-not $Diagnostic.PSObject.Properties['driverGuidance'] -or -not $Diagnostic.windows) {
        throw [string] $t.NoReport
    }
    $entries = @($Diagnostic.driverGuidance)
    if ($entries.Count -eq 0) {
        $script:output.Text = [string] $t.NoEntries
        $script:statusLabel.Text = [string] $t.NoEntriesStatus
        return
    }
    if ($entries.Count -gt 128) { throw [string] $t.TooMany }
    $format = ${function:Format-FastLlmDriverGuidance}
    $invalidText = [string] $t.Invalid
    $openFailedText = [string] $t.OpenFailed
    $pageUrl = [string] $t.Url
    $scale = Get-FastLlmUiFluentDialogScale -Owner $script:form

    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = [string] $t.GuidanceLabel
    $label.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $label.Margin = New-Object System.Windows.Thickness(0, 0, 0, 8)
    $devices = New-Object System.Windows.Controls.ComboBox
    $devices.Name = 'DriverDevice'
    [System.Windows.Controls.ScrollViewer]::SetCanContentScroll($devices, $false)
    for ($i = 0; $i -lt $entries.Count; $i++) { $null = $devices.Items.Add("$($i+1). $($entries[$i].inputGpuName)") }
    $details = New-FastLlmUiFluentDialogReadBox -Text '' -MinHeight (160 * $scale) -MaxHeight (320 * $scale)
    $details.Name = 'DriverGuidanceText'
    $details.Margin = New-Object System.Windows.Thickness(0, 8, 0, 8)
    # Name and LabeledBy from one string: the visible label of the list. The guidance box has no label of its own, so it shares that one.
    $labelText = [string] $t.GuidanceLabel
    foreach ($field in @($devices, $details)) {
        [System.Windows.Automation.AutomationProperties]::SetName($field, $labelText)
        [System.Windows.Automation.AutomationProperties]::SetLabeledBy($field, $label)
    }
    $openPage = New-Object System.Windows.Controls.Button
    $openPage.Name = 'OpenAmdPage'
    $openPage.SetResourceReference([System.Windows.FrameworkElement]::StyleProperty, 'FastLlm.ButtonStyle')
    $openPage.Content = ConvertTo-FastLlmUiAccessText -Text ([string] $t.OpenPage) -UseMnemonic $false
    [System.Windows.Automation.AutomationProperties]::SetName($openPage, [string] $t.OpenPage)
    $openPage.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
    $openPage.MinWidth = 88

    $panel = New-Object System.Windows.Controls.StackPanel
    foreach ($child in @($label, $devices, $details, $openPage)) { $null = $panel.Children.Add($child) }

    $devices.Add_SelectionChanged({
        try { $details.Text = & $format -Guidance $entries[$devices.SelectedIndex]; $openPage.IsEnabled = $true }
        catch { $details.Text = $invalidText; $openPage.IsEnabled = $false }
    }.GetNewClosure())
    $openPage.Add_Click({
        try {
            $chosen = $entries[$devices.SelectedIndex]
            if ($chosen.knownFocusModel) {
                # Revalidate before opening; do not execute a URL from an unvalidated diagnostic.
                $null = & $format -Guidance $chosen
                Start-Process ([string] $chosen.productUrl)
            }
            else { Start-Process $pageUrl }
        }
        catch { $details.Text = $openFailedText }
    }.GetNewClosure())

    $buttons = [ordered] @{ Close = [string] $t.GuidanceClose }
    # No Enter target (the classic form has no AcceptButton); Escape closes. The first focus is the list, the first tab stop of the classic form.
    $dialog = New-FastLlmUiFluentDialog -Title ([string] $t.GuidanceTitle) -Body $panel -Buttons $buttons -Enter '' -Escape 'Close' -Owner $script:form
    $work = [System.Windows.SystemParameters]::WorkArea
    $dialog['Window'].Width = [Math]::Min($work.Width * 0.9, 780.0 * $scale)
    $dialog['Window'].Add_Loaded({ $null = $devices.Focus() }.GetNewClosure())
    SetTrayMenuAvailable $false
    try { $devices.SelectedIndex = 0; $null = Show-FastLlmUiFluentDialog -Dialog $dialog }
    finally { SetTrayMenuAvailable $true }
    $script:statusLabel.Text = [string] $t.Viewed
}
