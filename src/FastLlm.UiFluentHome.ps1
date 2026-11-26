#requires -Version 5.1
# The Home page of the Fluent window: the page XAML (FastLlm.Home), the ONE table of new fluent-only strings, and the code that binds the page to the
# adapters and keeps the status card current. Dot-sourced by FastLlm.UiFluentShell.ps1. No WPF or WinForms type is resolved at dot-source time,
# only inside function bodies. Every caption that comes from an adapter goes through ConvertTo-FastLlmUiAccessText; today's strings are never copied here.
Set-StrictMode -Version 2.0

# The ONE table of new fluent-only strings (shell and Home). The PR body lists exactly these. The card headlines are in Get-FastLlmUiCardState.
$script:FastLlmUiFluentStrings = [ordered]@{
    ComingLater      = 'Coming in a later update'
    NavPane          = 'Navigation'
    NavHome          = 'Home'
    NavModels        = 'Models'
    NavConnect       = 'Connect'
    NavTools         = 'Tools'
    NavSettings      = 'Settings'
    MoreStartOptions = 'More start options'
    CopyAddress      = 'Copy address'
    Address          = 'Address'
    WillStartFormat  = 'Will start with {0}, context {1}'
    ContextDefault   = 'catalog default'
    Change           = 'Change'
    QuickActions     = 'Quick actions'
    Activity         = 'Activity'
    OpenChatWhy      = 'Turn on the local chat page in Settings and start FastLLM'
    # PR 3a: page headings, the collapsed pane format, the Copy automation name and the greyed-reason lines of Tools and Connect.
    ToolsTroubleshooting = 'Troubleshooting'
    ToolsBackgroundRun   = 'Background run'
    ToolsDownloads       = 'Official downloads'
    ComingLaterFormat    = '{0}: Coming in a later update'
    CopyFieldFormat      = 'Copy {0}'
    WhyBusy              = 'Available when the current task has finished'
    WhyMicrosoftSetup    = 'Available when Microsoft setup has finished'
    WhySideStep          = 'Available when the running check has finished'
    WhyAttached          = 'Already attached to the background run'
    WhyNoBackgroundRun   = 'No background run is ready to attach'
    WhyNotRunning        = 'Start FastLLM first'
    # PR 3b: the automation name of the Copy full output button in the Activity header (the failure bar's keeps the adapter caption).
    CopyFullOutputActivity = 'Copy full output (Activity)'
    # PR 3b: the Models page headings, the Remove and spin button names and the three greyed-reason lines.
    ModelsStartWith      = 'Model to start with'
    ModelsStartOptions   = 'Start options'
    ModelsComponents     = 'Engine components'
    RemoveFormat         = 'Remove {0}'
    SpinUp               = 'Increase'
    SpinDown             = 'Decrease'
    WhyNoPreview         = 'Start once to preview a setup first'
    WhyBackgroundRun     = 'Available when the background run has ended'
    WhyNoLeftovers       = 'No leftover partial downloads were found'
    # PR 3c: the Settings page headings, the Discard action and the unsaved-changes prompt (its title, Save and Cancel are today's strings).
    SettingsServer       = 'Server'
    SettingsStarting     = 'Starting'
    SettingsComponents   = 'Components and updates'
    Discard              = 'Discard'
    SavePrompt           = 'Save your changes?'
    DontSave             = "Don't save"
}

# Icon glyphs (Segoe Fluent Icons, falling back to Segoe MDL2 Assets: the same code points exist in both). They are drawn, never read.
$script:FastLlmUiFluentGlyphs = @{
    Home = 0xE80F; Models = 0xE8F1; Connect = 0xE71B; Tools = 0xE90F; Settings = 0xE713; Copy = 0xE8C8; More = 0xE70D
    StepDone = 0xE73E; StepActive = 0xE768; StepWait = 0xE739; StepAttention = 0xE7BA
}

# Where the Activity header's Copy full output button is hosted. The button is built in code (registered XAML is constant markup only) and put in the slot
# this value names. 'Tag' (the plan's first choice) puts it in the Expander's Tag, which the shell's Expander style presents beside the toggle. If the Windows
# check (pages step P16) shows the Tag hosting fails, change this ONE value to 'Body': the button becomes the first child of the Expander's body (the named
# ActivityBody panel), right-aligned above the Activity box (the tab order stays toggle, copy, box). Nothing else changes.
$script:FastLlmUiFluentActivityCopySlot = 'Tag'

# Home reads its markup text only from the string table above and from the adapters; the markup itself carries no visible text.
$script:FastLlmUiXaml['FastLlm.Home'] = @'
<ScrollViewer xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
              xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
              VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Focusable="False">
  <Grid Margin="32,24,32,24" MaxWidth="900">
  <Grid.ColumnDefinitions>
    <ColumnDefinition Width="*"/>
    <ColumnDefinition Width="Auto"/>
  </Grid.ColumnDefinitions>
  <Grid.RowDefinitions>
    <RowDefinition Height="Auto"/>
    <RowDefinition Height="Auto"/>
  </Grid.RowDefinitions>
    <StackPanel x:Name="HeaderGrid" Grid.Row="0" Grid.Column="0" Margin="0,0,16,0">
      <TextBlock x:Name="TitleText" TextWrapping="Wrap" FontFamily="{DynamicResource FastLlm.DisplayFont}"
                 FontSize="{DynamicResource FastLlm.SubtitleSize}" FontWeight="{DynamicResource FastLlm.SubtitleWeight}"/>
      <TextBlock x:Name="NoticeText" TextWrapping="Wrap" Margin="0,4,0,0" Foreground="{DynamicResource FastLlm.TextSecondaryBrush}"/>
    </StackPanel>
  <Button x:Name="TrayButton" Grid.Row="0" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Top" Style="{DynamicResource FastLlm.ButtonStyle}"/>
  <StackPanel Grid.Row="1" Grid.Column="0" Grid.ColumnSpan="2">
    <Border x:Name="StatusCard" Margin="0,20,0,0" Padding="16" BorderThickness="1"
            Background="{DynamicResource FastLlm.CardBrush}" BorderBrush="{DynamicResource FastLlm.CardStrokeBrush}"
            CornerRadius="{DynamicResource FastLlm.OverlayCornerRadius}">
      <StackPanel>
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <Ellipse x:Name="StatusDot" Width="12" Height="12" Margin="0,0,10,0" VerticalAlignment="Center" StrokeThickness="2"/>
          <TextBlock x:Name="StatusHeadline" Grid.Column="1" VerticalAlignment="Center" TextWrapping="Wrap"
                     FontFamily="{DynamicResource FastLlm.DisplayFont}" FontSize="{DynamicResource FastLlm.SubtitleSize}"
                     FontWeight="{DynamicResource FastLlm.SubtitleWeight}"/>
          <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
            <StackPanel x:Name="StartSplit" Orientation="Horizontal">
              <Button x:Name="InstallButton" Style="{DynamicResource FastLlm.AccentButtonStyle}"/>
              <Button x:Name="MoreStartButton" Margin="2,0,0,0" MinWidth="32" Padding="0" Style="{DynamicResource FastLlm.AccentIconButtonStyle}"/>
            </StackPanel>
            <Button x:Name="StopButton" Visibility="Collapsed" Style="{DynamicResource FastLlm.ButtonStyle}"/>
            <Button x:Name="AttachButton" Visibility="Collapsed" Style="{DynamicResource FastLlm.AccentButtonStyle}"/>
          </StackPanel>
        </Grid>
        <TextBlock x:Name="StatusDetail" Margin="0,12,0,0" TextWrapping="Wrap" AutomationProperties.LiveSetting="Polite"/>
        <TextBlock x:Name="BackgroundLine" Margin="0,4,0,0" TextWrapping="Wrap" Foreground="{DynamicResource FastLlm.TextSecondaryBrush}"/>
        <ProgressBar x:Name="HomeProgress" Margin="0,12,0,0" Height="4" IsIndeterminate="True" Visibility="Collapsed"
                     Foreground="{DynamicResource FastLlm.AccentFillBrush}"/>
        <StackPanel x:Name="StepsBlock" Margin="0,12,0,0" Visibility="Collapsed">
          <TextBlock x:Name="StepsSummary" FontWeight="{DynamicResource FastLlm.BodyStrongWeight}"/>
          <StackPanel x:Name="StepsPanel" Margin="0,6,0,0"/>
        </StackPanel>
        <WrapPanel x:Name="FactsPanel" Margin="0,12,0,0" Visibility="Collapsed">
          <TextBlock x:Name="AddressLabel" VerticalAlignment="Center" Margin="0,0,8,0" Foreground="{DynamicResource FastLlm.TextSecondaryBrush}"/>
          <TextBlock x:Name="AddressText" VerticalAlignment="Center" FontFamily="{DynamicResource FastLlm.MonoFont}"/>
          <Button x:Name="CopyButton" Margin="8,0,0,0" Style="{DynamicResource FastLlm.IconButtonStyle}"/>
        </WrapPanel>
        <Grid x:Name="WillStartPanel" Margin="0,12,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock x:Name="WillStartText" Grid.Column="0" VerticalAlignment="Center" TextWrapping="Wrap" Margin="0,0,8,0"/>
          <Button x:Name="ChangeButton" Grid.Column="1" Style="{DynamicResource FastLlm.LinkButtonStyle}"/>
        </Grid>
        <TextBlock x:Name="NotesText" Margin="0,12,0,0" TextWrapping="Wrap"/>
        <WrapPanel Margin="0,4,0,0">
          <Button x:Name="ResultsLink" Margin="0,0,12,0" Style="{DynamicResource FastLlm.LinkButtonStyle}"/>
          <Button x:Name="BarLink" Style="{DynamicResource FastLlm.LinkButtonStyle}"/>
        </WrapPanel>
      </StackPanel>
    </Border>
    <StackPanel x:Name="QuickPanel" Margin="0,24,0,0">
      <TextBlock x:Name="QuickHeading" FontWeight="{DynamicResource FastLlm.BodyStrongWeight}"/>
      <WrapPanel Margin="0,8,0,0">
        <Button x:Name="OpenChatButton" Margin="0,0,8,8" Style="{DynamicResource FastLlm.ButtonStyle}"/>
        <Button x:Name="ConnectButton" Margin="0,0,8,8" Style="{DynamicResource FastLlm.ButtonStyle}"/>
        <Button x:Name="SwitchButton" Margin="0,0,8,8" Style="{DynamicResource FastLlm.ButtonStyle}"/>
      </WrapPanel>
      <TextBlock x:Name="SwitchLine" TextWrapping="Wrap" Foreground="{DynamicResource FastLlm.TextSecondaryBrush}"/>
    </StackPanel>
    <Expander x:Name="ActivityExpander" Margin="0,16,0,0" IsExpanded="False" Style="{DynamicResource FastLlm.ExpanderStyle}">
      <Expander.Header>
        <TextBlock x:Name="ActivityHeader" FontWeight="{DynamicResource FastLlm.BodyStrongWeight}"/>
      </Expander.Header>
      <StackPanel x:Name="ActivityBody">
        <TextBox x:Name="ActivityBox" Margin="0,8,0,0" FocusVisualStyle="{DynamicResource FastLlm.FocusVisual}" Height="220" IsReadOnly="True" TextWrapping="Wrap" AcceptsReturn="True"
                 VerticalScrollBarVisibility="Auto" FontFamily="{DynamicResource FastLlm.MonoFont}"
                 Background="{DynamicResource FastLlm.CardBrush}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}"
                 BorderBrush="{DynamicResource FastLlm.ControlStrongStrokeBrush}"/>
      </StackPanel>
    </Expander>
  </StackPanel>
  </Grid>
</ScrollViewer>
'@

# The Home rows of the binding table: adapter name, element name, how the caption is set, the adapter event a click raises, and flags.
#   Mode  : TextBlock (Text), Content (Content), Header (Header), Output (read-only box), Visual (visibility and enablement only)
#   Flags : NoVisible (the card logic owns the element's visibility), NoText (the element draws an icon, not the adapter caption)
function Get-FastLlmUiFluentHomeBindings {
    [CmdletBinding()] param()
    return @(
        @{ Name = 'title';                 Element = 'TitleText';           Mode = 'TextBlock'; Event = '';            Flags = @() },
        @{ Name = 'notice';                Element = 'NoticeText';          Mode = 'TextBlock'; Event = '';            Flags = @() },
        @{ Name = 'trayButton';            Element = 'TrayButton';          Mode = 'Content';   Event = 'Click';       Flags = @() },
        @{ Name = 'installButton';         Element = 'InstallButton';       Mode = 'Content';   Event = 'Click';       Flags = @('NoVisible') },
        @{ Name = 'startButton';           Element = 'StartMenuItem';       Mode = 'Header';    Event = 'Click';       Flags = @() },
        @{ Name = 'backgroundStartButton'; Element = 'BackgroundStartMenuItem'; Mode = 'Header'; Event = 'Click';      Flags = @() },
        @{ Name = 'stopButton';            Element = 'StopButton';          Mode = 'Content';   Event = 'Click';       Flags = @('NoVisible') },
        @{ Name = 'backgroundAttachButton'; Element = 'AttachButton';       Mode = 'Content';   Event = 'Click';       Flags = @('NoVisible') },
        @{ Name = 'copyButton';            Element = 'CopyButton';          Mode = 'Content';   Event = 'Click';       Flags = @('NoVisible', 'NoText') },
        @{ Name = 'statusLabel';           Element = 'StatusDetail';        Mode = 'TextBlock'; Event = '';            Flags = @() },
        @{ Name = 'backgroundLabel';       Element = 'BackgroundLine';      Mode = 'TextBlock'; Event = '';            Flags = @() },
        @{ Name = 'notesLabel';            Element = 'NotesText';           Mode = 'TextBlock'; Event = '';            Flags = @() },
        @{ Name = 'resultsLink';           Element = 'ResultsLink';         Mode = 'Content';   Event = 'LinkClicked'; Flags = @() },
        @{ Name = 'barLink';               Element = 'BarLink';             Mode = 'Content';   Event = 'LinkClicked'; Flags = @() },
        @{ Name = 'progress';              Element = 'HomeProgress';        Mode = 'Visual';    Event = '';            Flags = @() },
        @{ Name = 'output';                Element = 'ActivityBox';         Mode = 'Output';    Event = '';            Flags = @() },
        @{ Name = 'openChatButton';        Element = 'OpenChatButton';      Mode = 'Content';   Event = 'Click';       Flags = @() },
        @{ Name = 'connectButton';         Element = 'ConnectButton';       Mode = 'Content';   Event = '';            Flags = @() },
        @{ Name = 'switchButton';          Element = 'SwitchButton';        Mode = 'Content';   Event = '';            Flags = @() },
        @{ Name = 'switchLabel';           Element = 'SwitchLine';          Mode = 'TextBlock'; Event = '';            Flags = @() }
    )
}

function Get-FastLlmUiFluentElement {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Root, [Parameter(Mandatory = $true)][string] $Name)
    $element = $Root.FindName($Name)
    if ($null -eq $element) { throw ("The Fluent window markup has no element '" + $Name + "'.") }
    return $element
}

# One scriptblock that carries an adapter's property writes to its WPF element. It is a closure that calls only .NET and one captured
# scriptblock (the access-text converter), never a function by name, so it runs the same wherever the adapter raises it from.
function New-FastLlmUiFluentSink {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Adapter,
        [Parameter(Mandatory = $true)] $Element,
        [Parameter(Mandatory = $true)][ValidateSet('TextBlock', 'Content', 'Header', 'Output', 'Visual', 'Combo', 'Number', 'Input', 'Toggle')][string] $Mode,
        [string[]] $Flags = @()
    )
    $convert = ${function:ConvertTo-FastLlmUiAccessText}
    $display = ${function:ConvertTo-FastLlmUiDisplayText}
    $noVisible = ($Flags -contains 'NoVisible')
    $noText = ($Flags -contains 'NoText')
    $sink = {
        param($Property, $Value)
        # The two-way modes. An element write that came from the element itself (FromElement) is skipped, and so is one the element already shows.
        if ($Mode -ceq 'Combo') {
            if ($Adapter.__state['FromElement']) { return }
            if ([string] $Property -ceq 'SelectedIndex') { if ($Element.SelectedIndex -ne [int] $Value) { $Element.SelectedIndex = [int] $Value }; return }
            if ([string] $Property -ceq 'Enabled') { $Element.IsEnabled = [bool] $Value; return }
            if ([string] $Property -ceq 'Text') { return }
        }
        if ($Mode -ceq 'Number') {
            if ($Adapter.__state['FromElement']) { return }
            if ([string] $Property -ceq 'Value') { $shown = ([decimal] $Value).ToString('F0'); if ($Element.Text -cne $shown) { $Element.Text = $shown }; return }
            if ([string] $Property -ceq 'Enabled') { $Element.IsEnabled = [bool] $Value; return }
            if ([string] $Property -ceq 'Text') { return }
        }
        if ($Mode -ceq 'Input') {
            if ($Adapter.__state['FromElement']) { return }
            if ([string] $Property -ceq 'Text') { if ($Element.Text -cne [string] $Value) { $Element.Text = [string] $Value }; return }
            if ([string] $Property -ceq 'Enabled') { $Element.IsEnabled = [bool] $Value; return }
        }
        if ($Mode -ceq 'Toggle') {
            # The adapter's Checked, written to IsChecked unless it came from the element or the element already shows it. Text goes through the shared Content branch.
            if ([string] $Property -ceq 'Checked') {
                if ($Adapter.__state['FromElement']) { return }
                if ($Element.IsChecked -ne [bool] $Value) { $Element.IsChecked = [bool] $Value }
                return
            }
        }
        switch -CaseSensitive ([string] $Property) {
            'Text' {
                if ($noText -or $Mode -ceq 'Visual') { break }
                if ($Mode -ceq 'Output') { if ($Element.Text -cne [string] $Value) { $Element.Text = [string] $Value }; break }
                # A TextBlock has no access keys: it gets the plain text WinForms shows. Content and Header (templates with RecognizesAccessKey) get access text.
                if ($Mode -ceq 'TextBlock') {
                    $shown = & $display -Text ([string] $Value) -UseMnemonic ([bool] $Adapter.UseMnemonic)
                    if ($Element.Text -cne $shown) { $Element.Text = $shown }
                }
                else {
                    $caption = & $convert -Text ([string] $Value) -UseMnemonic ([bool] $Adapter.UseMnemonic)
                    if ($Mode -ceq 'Content' -or $Mode -ceq 'Toggle') { $Element.Content = $caption } else { $Element.Header = $caption }
                }
            }
            'Enabled' { $Element.IsEnabled = [bool] $Value }
            'Visible' {
                if ($noVisible) { break }
                if ([bool] $Value) { $Element.Visibility = [System.Windows.Visibility]::Visible } else { $Element.Visibility = [System.Windows.Visibility]::Collapsed }
            }
            'ScrollToEnd' { if ($Mode -ceq 'Output') { $Element.ScrollToEnd() } }
            'SelectionStart' { if ($Mode -ceq 'Output') { $Element.SelectionStart = [Math]::Max(0, [Math]::Min([int] $Value, $Element.Text.Length)) } }
        }
    }.GetNewClosure()
    return $sink
}

# Binds one adapter to one element: the sink, the initial state pushed once, and the click raising the adapter event the orchestration listens to.
function Connect-FastLlmUiFluentControl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Adapter,
        [Parameter(Mandatory = $true)] $Element,
        [Parameter(Mandatory = $true)][string] $Mode,
        [string] $Event = '',
        [string[]] $Flags = @(),
        [switch] $Also
    )
    $sink = New-FastLlmUiFluentSink -Adapter $Adapter -Element $Element -Mode $Mode -Flags $Flags
    # Also joins an adapter that is already bound (each element keeps its own Mode and Flags); without it a second bind throws.
    Add-FastLlmUiAdapterSink -Adapter $Adapter -Sink $sink -Also:$Also
    if ($Mode -ceq 'Combo') {
        # Fill the element's items once from the adapter's strings, then push the selection.
        foreach ($item in $Adapter.Items) { $null = $Element.Items.Add([string] $item) }
        foreach ($property in 'SelectedIndex', 'Enabled', 'Visible') { & $sink $property $Adapter.$property }
    }
    elseif ($Mode -ceq 'Number') {
        foreach ($property in 'Value', 'Enabled', 'Visible') { & $sink $property $Adapter.$property }
    }
    elseif ($Mode -ceq 'Toggle') {
        foreach ($property in 'Checked', 'Text', 'Enabled', 'Visible') { & $sink $property $Adapter.$property }
    }
    else {
        foreach ($property in 'Text', 'Enabled', 'Visible') { & $sink $property $Adapter.$property }
    }
    $setFrom = ${function:Set-FastLlmUiAdapterFromElement}
    if ($Mode -ceq 'Combo') {
        $Element.Add_SelectionChanged({ param($sender, $routed) & $setFrom -Adapter $Adapter -Property 'SelectedIndex' -Value ([int] $Element.SelectedIndex) }.GetNewClosure())
    }
    elseif ($Mode -ceq 'Toggle') {
        # Checked, Unchecked and Indeterminate, never Click: a UIA Toggle (Narrator) does not raise Click. Each handler writes the adapter once, then re-syncs the element:
        # a handler of the adapter that reverts it (Checked = $false) ran while FromElement was set, so the sink skipped the element and it would stay on.
        $Element.Add_Checked({ param($sender, $routed) & $setFrom -Adapter $Adapter -Property 'Checked' -Value ([bool] ($Element.IsChecked -eq $true)); if ($Element.IsChecked -ne [bool] $Adapter.Checked) { $Element.IsChecked = [bool] $Adapter.Checked } }.GetNewClosure())
        $Element.Add_Unchecked({ param($sender, $routed) & $setFrom -Adapter $Adapter -Property 'Checked' -Value ([bool] ($Element.IsChecked -eq $true)); if ($Element.IsChecked -ne [bool] $Adapter.Checked) { $Element.IsChecked = [bool] $Adapter.Checked } }.GetNewClosure())
        $Element.Add_Indeterminate({ param($sender, $routed) & $setFrom -Adapter $Adapter -Property 'Checked' -Value ([bool] ($Element.IsChecked -eq $true)); if ($Element.IsChecked -ne [bool] $Adapter.Checked) { $Element.IsChecked = [bool] $Adapter.Checked } }.GetNewClosure())
    }
    elseif ($Mode -ceq 'Input') {
        $Element.Add_TextChanged({ param($sender, $routed) & $setFrom -Adapter $Adapter -Property 'Text' -Value ([string] $Element.Text) }.GetNewClosure())
    }
    elseif ($Mode -ceq 'Number') {
        # Commits the typed text through the WinForms clamp (minimum 0; Maximum and Increment come from the adapter), or steps first when
        # $direction is Up or Down. The shown text is then normalised to the committed value. The page Leave calls the same block (kept on the adapter).
        $parse = ${function:ConvertTo-FastLlmUiNumericValue}
        $step = ${function:Step-FastLlmUiNumericValue}
        $commit = {
            param($direction)
            $maximum = [decimal] $Adapter.Maximum
            $value = & $parse -Text ([string] $Element.Text) -Current ([decimal] $Adapter.Value) -Minimum ([decimal] 0) -Maximum $maximum
            if ($direction -ceq 'Up') { $value = & $step -Current $value -Increment ([decimal] $Adapter.Increment) -Minimum ([decimal] 0) -Maximum $maximum -Up }
            elseif ($direction -ceq 'Down') { $value = & $step -Current $value -Increment ([decimal] $Adapter.Increment) -Minimum ([decimal] 0) -Maximum $maximum }
            & $setFrom -Adapter $Adapter -Property 'Value' -Value $value
            $shown = $value.ToString('F0')
            if ($Element.Text -cne $shown) { $Element.Text = $shown }
        }.GetNewClosure()
        $Adapter.__state['CommitEdit'] = $commit
        # PreviewKeyDown, not KeyDown: a TextBox's class handler marks Up and Down handled (caret moves) before instance KeyDown handlers run.
        # Up and Down step like the WinForms spin box and are marked handled here; Return commits and is left unhandled, as the WinForms box leaves it.
        $Element.Add_PreviewKeyDown({
                param($sender, $routed)
                $direction = $null
                if ($routed.Key -eq [System.Windows.Input.Key]::Return) { $direction = '' }
                elseif ($routed.Key -eq [System.Windows.Input.Key]::Up) { $direction = 'Up'; $routed.Handled = $true }
                elseif ($routed.Key -eq [System.Windows.Input.Key]::Down) { $direction = 'Down'; $routed.Handled = $true }
                if ($null -ne $direction) { & $commit $direction }
            }.GetNewClosure())
        $Element.Add_LostKeyboardFocus({ param($sender, $routed) & $commit '' }.GetNewClosure())
    }
    # A Toggle never listens to Click (see above); its state travels on the Checked adapter property.
    if ($Event -and $Mode -cne 'Toggle') {
        $invoke = ${function:Invoke-FastLlmUiAdapterEvent}
        $adapterEvent = $Event
        $handler = { param($sender, $routed) & $invoke -Adapter $Adapter -Event $adapterEvent }.GetNewClosure()
        $Element.Add_Click($handler)
    }
}

function New-FastLlmUiFluentGlyphText {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int] $CodePoint)
    return [string][char] $CodePoint
}

# Raises the polite or assertive live-region notification for an element. Callers do this only when the composed text changed.
function Send-FastLlmUiFluentLiveRegion {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Element)
    try {
        $peer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($Element)
        if ($null -ne $peer) { $peer.RaiseAutomationEvent([System.Windows.Automation.Peers.AutomationEvents]::LiveRegionChanged) }
    }
    catch { $null = $_ }
}

# Home static text, names and the split button. $Els collects every named element (the shell adds the menu items to it).
function Initialize-FastLlmUiFluentHome {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Page, [Parameter(Mandatory = $true)][hashtable] $Els)
    $s = $script:FastLlmUiFluentStrings
    foreach ($name in 'HeaderGrid', 'TitleText', 'NoticeText', 'TrayButton', 'StatusCard', 'StatusDot', 'StatusHeadline', 'StartSplit', 'InstallButton',
        'MoreStartButton', 'StopButton', 'AttachButton', 'StatusDetail', 'BackgroundLine', 'HomeProgress', 'StepsBlock', 'StepsSummary', 'StepsPanel', 'FactsPanel', 'AddressLabel',
        'AddressText', 'CopyButton', 'WillStartPanel', 'WillStartText', 'ChangeButton', 'NotesText', 'ResultsLink', 'BarLink', 'QuickPanel', 'QuickHeading',
        'OpenChatButton', 'ConnectButton', 'SwitchButton', 'SwitchLine', 'ActivityExpander', 'ActivityHeader', 'ActivityBody', 'ActivityBox') {
        $Els[$name] = Get-FastLlmUiFluentElement -Root $Page -Name $name
    }

    # The split button's arrow: its own tab stop with its own name; Enter and Space click it, Alt+Down opens the same menu.
    $Els['MoreStartButton'].Content = New-FastLlmUiFluentGlyphText $script:FastLlmUiFluentGlyphs.More
    $Els['MoreStartButton'].FontFamily = New-Object System.Windows.Media.FontFamily('Segoe Fluent Icons, Segoe MDL2 Assets')
    [System.Windows.Automation.AutomationProperties]::SetName($Els['MoreStartButton'], [string] $s.MoreStartOptions)
    $Els['MoreStartButton'].ToolTip = [string] $s.MoreStartOptions
    $Els['MoreStartButton'].MinHeight = 32
    $Els['MoreStartButton'].FontSize = 16

    $menu = New-Object System.Windows.Controls.ContextMenu
    $startItem = New-Object System.Windows.Controls.MenuItem
    $backgroundItem = New-Object System.Windows.Controls.MenuItem
    [void] $menu.Items.Add($startItem)
    [void] $menu.Items.Add($backgroundItem)
    $Els['StartMenuItem'] = $startItem
    $Els['BackgroundStartMenuItem'] = $backgroundItem
    $more = $Els['MoreStartButton']
    # The arrow's own ContextMenu, so the menu inherits the window's resources; it is styled from the theme.
    $more.ContextMenu = $menu
    $menu.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, 'FastLlm.LayerBrush')
    $menu.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'FastLlm.TextPrimaryBrush')
    $menu.SetResourceReference([System.Windows.Controls.Control]::BorderBrushProperty, 'FastLlm.ControlStrongStrokeBrush')
    $menu.SetResourceReference([System.Windows.Controls.Control]::FontSizeProperty, 'FastLlm.BodySize')
    $menu.SetResourceReference([System.Windows.Controls.Control]::FontFamilyProperty, 'FastLlm.TextFont')
    foreach ($menuItem in @($startItem, $backgroundItem)) {
        $menuItem.SetResourceReference([System.Windows.FrameworkElement]::FocusVisualStyleProperty, 'FastLlm.FocusVisual')
        $menuItem.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'FastLlm.TextPrimaryBrush')
        $menuItem.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, 'FastLlm.LayerBrush')
    }
    $openMenu = {
        $menu.PlacementTarget = $more
        $menu.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
        $menu.IsOpen = $true
    }.GetNewClosure()
    $Els['MoreStartButton'].Add_Click({ param($sender, $routed) & $openMenu }.GetNewClosure())
    $Els['MoreStartButton'].Add_PreviewKeyDown({
            param($sender, $keyArgs)
            if ($keyArgs.Key -eq [System.Windows.Input.Key]::System -and $keyArgs.SystemKey -eq [System.Windows.Input.Key]::Down) { & $openMenu; $keyArgs.Handled = $true }
        }.GetNewClosure())

    # The copy button is an icon button of at least 32 x 32, named and with a tooltip.
    $Els['CopyButton'].Content = New-FastLlmUiFluentGlyphText $script:FastLlmUiFluentGlyphs.Copy
    [System.Windows.Automation.AutomationProperties]::SetName($Els['CopyButton'], [string] $s.CopyAddress)
    $Els['CopyButton'].ToolTip = [string] $s.CopyAddress
    $Els['CopyButton'].MinWidth = 32
    $Els['CopyButton'].MinHeight = 32

    $Els['AddressLabel'].Text = [string] $s.Address
    $Els['ChangeButton'].Content = [string] $s.Change
    $Els['QuickHeading'].Text = [string] $s.QuickActions

    # The only input on Home is the read-only Activity box: explicit name and LabeledBy, both from one constant.
    $activity = [string] $s.Activity
    $Els['ActivityHeader'].Text = $activity
    [System.Windows.Automation.AutomationProperties]::SetName($Els['ActivityBox'], $activity)
    [System.Windows.Automation.AutomationProperties]::SetLabeledBy($Els['ActivityBox'], $Els['ActivityHeader'])
    [System.Windows.Controls.ToolTipService]::SetShowOnDisabled($Els['OpenChatButton'], $true)
    # Connect an app: a plain handler (the row has no adapter event), so the page opens once Connect is registered and the dialog stays until then.
    $Els['ConnectButton'].Add_Click({ param($sender, $routed) Invoke-FastLlmUiFluentHomeConnect })
    # Switch and Change go to the Models page (plain handlers; the Switch row has no adapter event, so today's picker dialog never opens from here).
    $Els['SwitchButton'].Add_Click({ param($sender, $routed) Invoke-FastLlmUiFluentHomeSwitch })
    $Els['ChangeButton'].Add_Click({ param($sender, $routed) Invoke-FastLlmUiFluentHomeChange })
    # The Activity header's Copy full output button is built in code, with the failure bar link's style; its caption is bound by the shell row, its name is its own.
    $copy = New-Object System.Windows.Controls.Button
    $copy.Name = 'ActivityCopyButton'
    $copy.SetResourceReference([System.Windows.FrameworkElement]::StyleProperty, 'FastLlm.LinkButtonStyle')
    [System.Windows.Automation.AutomationProperties]::SetName($copy, [string] $s.CopyFullOutputActivity)
    if ($script:FastLlmUiFluentActivityCopySlot -ceq 'Body') {
        $copy.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
        $copy.Margin = New-Object System.Windows.Thickness(0, 8, 0, 0)
        $Els['ActivityBody'].Children.Insert(0, $copy)
    }
    else { $Els['ActivityExpander'].Tag = $copy }
    $Els['ActivityCopyButton'] = $copy
    return $Els
}

# Home's entry in the page registry. Its status line is StatusDetail, whose text the statusLabel adapter writes: the page status keeps only its name.
function Register-FastLlmUiFluentHomePage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Page, [Parameter(Mandatory = $true)][hashtable] $Els)
    Register-FastLlmUiFluentPage -Id 'Home' -Element $Page -Nav 'NavHome' -Status $Els['StatusDetail'] -StatusKeepsText
}

# The Connect an app quick action. Once the Connect page is registered it opens that page and puts the focus on its pane item; until then (Task 7
# registers it) it raises the adapter click, which runs the orchestration's dialog exactly as before. Nothing here changes when Connect registers.
function Invoke-FastLlmUiFluentHomeConnect {
    [CmdletBinding()] param()
    if (Test-FastLlmUiFluentPageRegistered -Id 'Connect') { $null = Set-FastLlmUiFluentPage -Id 'Connect' -FocusNav }
    else { Invoke-FastLlmUiAdapterEvent -Adapter $script:connectButton -Event 'Click' }
}

# Switch model on Home. Once the Models page is registered it opens that page and puts the focus on its pane item; until then (Task 6 registers it)
# it raises the adapter click, which runs the orchestration's picker dialog exactly as before.
function Invoke-FastLlmUiFluentHomeSwitch {
    [CmdletBinding()] param()
    if (Test-FastLlmUiFluentPageRegistered -Id 'Models') { $null = Set-FastLlmUiFluentPage -Id 'Models' -FocusNav }
    else { Invoke-FastLlmUiAdapterEvent -Adapter $script:switchButton -Event 'Click' }
}

# Change (the model to start with). Once the Models page is registered it opens that page and focuses the model box; until then it does nothing.
function Invoke-FastLlmUiFluentHomeChange {
    [CmdletBinding()] param()
    if (-not (Test-FastLlmUiFluentPageRegistered -Id 'Models')) { return }
    $null = Set-FastLlmUiFluentPage -Id 'Models'
    $box = $script:FastLlmUiFluent['Els']['ModelsModelBox']
    $nav = $script:FastLlmUiFluent['Els']['NavModels']
    # Keyboard focus is never lost: a model box that is missing or disabled (a run is active), or one that cannot take the focus, leaves it on the Models pane item.
    if ($null -eq $box -or -not [bool] $box.IsEnabled) {
        if ($null -ne $nav) { $null = $nav.Focus() }
        return
    }
    if (-not [bool] $box.Focus()) {
        # The page was only just attached: focus once its layout has run, and fall back to the pane item if the box still cannot take it.
        $focusLater = { if (-not [bool] $box.Focus() -and $null -ne $nav) { $null = $nav.Focus() } }.GetNewClosure()
        $null = $box.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Input, [Action] $focusLater)
    }
}

# One 250 ms refresh of the card from the state the window already holds. The text of the detail line comes from the statusLabel adapter's sink.
function Update-FastLlmUiFluentHome {
    [CmdletBinding()] param()
    $f = $script:FastLlmUiFluent
    $e = $f['Els']
    $keys = $f['Keys']
    $s = $script:FastLlmUiFluentStrings
    $glyphs = $script:FastLlmUiFluentGlyphs
    $snapshot = GetUiStateSnapshot $false
    $card = Get-FastLlmUiCardState -Snapshot $snapshot
    $highContrast = ([string] $f['Theme'] -ceq 'high-contrast')

    # The headline and the dot. The dot is a filled circle, or an outline in high contrast; the state word carries the meaning either way.
    $e['StatusHeadline'].Text = [string] $card.headline
    $toneKey = switch ([string] $card.tone) {
        'success' { 'FastLlm.SuccessTextBrush' } 'caution' { 'FastLlm.CautionTextBrush' } 'critical' { 'FastLlm.CriticalTextBrush' }
        'accent' { 'FastLlm.AccentFillBrush' } default { 'FastLlm.TextSecondaryBrush' }
    }
    $dotKey = $toneKey + '|' + $highContrast
    if ($keys['Dot'] -cne $dotKey) {
        $keys['Dot'] = $dotKey
        if ($highContrast) {
            $e['StatusDot'].Fill = [System.Windows.Media.Brushes]::Transparent
            $e['StatusDot'].SetResourceReference([System.Windows.Shapes.Shape]::StrokeProperty, 'FastLlm.TextPrimaryBrush')
        }
        else {
            $e['StatusDot'].Stroke = $null
            $e['StatusDot'].SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, $toneKey)
        }
    }

    # The detail line is a polite live region: its automation name is the composed text, raised only when that text changes.
    # The headline is not repeated when the detail already opens with it ("Not running. Install and start ...").
    $detail = [string] $script:statusLabel.Text
    $composed = if ($detail.StartsWith([string] $card.headline, [System.StringComparison]::OrdinalIgnoreCase)) { $detail } else { [string] $card.headline + '. ' + $detail }
    if ($keys['Composed'] -cne $composed) {
        $first = ($null -eq $keys['Composed'])
        # Every page shows the composed line; only the current page announces it. The key is written only after the loop succeeded.
        Update-FastLlmUiFluentPageStatus -Composed $composed -Announce (-not $first)
        $keys['Composed'] = $composed
    }

    # The main action: the card says which one shows; whether it can be pressed is only the adapter's Enabled (SetBusy).
    $action = [string] $card.mainAction
    $e['StartSplit'].Visibility = if ($action -ceq 'start') { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    $e['StopButton'].Visibility = if ($action -ceq 'stop') { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    $e['AttachButton'].Visibility = if ($action -ceq 'attach') { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    $e['MoreStartButton'].IsEnabled = ([bool] $script:startButton.Enabled -or [bool] $script:backgroundStartButton.Enabled)

    # The steps, only while starting. The list has its own automation text ("Step 3 of 4, Model, in progress").
    $stepRows = @($card.steps)
    $stepsKey = [string] $card.stepsText + '|' + (@($stepRows | ForEach-Object { if ($null -ne $_) { [string] $_.name + '=' + [string] $_.state } }) -join ';')
    if ($keys['Steps'] -cne $stepsKey) {
        $keys['Steps'] = $stepsKey
        $e['StepsPanel'].Children.Clear()
        if ($null -ne $card.steps -and $stepRows.Count -gt 0) {
            foreach ($step in $stepRows) {
                $row = New-Object System.Windows.Controls.StackPanel
                $row.Orientation = [System.Windows.Controls.Orientation]::Horizontal
                $row.Margin = New-Object System.Windows.Thickness(0, 0, 0, 4)
                $mark = New-Object Bitworks.FastLlm.DecorativeTextBlock
                $code = switch ([string] $step.state) { 'done' { $glyphs.StepDone } 'in progress' { $glyphs.StepActive } 'needs attention' { $glyphs.StepAttention } default { $glyphs.StepWait } }
                $mark.Text = New-FastLlmUiFluentGlyphText $code
                $mark.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe Fluent Icons, Segoe MDL2 Assets')
                $mark.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
                $mark.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
                $label = New-Object System.Windows.Controls.TextBlock
                $rowText = [string] $step.name + ', ' + [string] $step.state
                $label.Text = $rowText
                [void] $row.Children.Add($mark)
                [void] $row.Children.Add($label)
                [void] $e['StepsPanel'].Children.Add($row)
            }
            # Plain TextBlocks always have a peer (Name = Text): the summary names the whole step state, the rows name each step.
            $e['StepsSummary'].Text = [string] $card.stepsText
            [System.Windows.Automation.AutomationProperties]::SetName($e['StepsSummary'], [string] $card.stepsText)
            $e['StepsBlock'].Visibility = [System.Windows.Visibility]::Visible
        }
        else { $e['StepsBlock'].Visibility = [System.Windows.Visibility]::Collapsed }
    }

    # The facts line: the address, only while a run is up. The URL is the one Copy puts on the clipboard; it is read on a change and every 5 seconds.
    $running = ([string] $card.state -ceq 'running' -or [string] $card.state -ceq 'running-background')
    if ($running) {
        if ($keys['Running'] -ne $true -or ([int] $f['Tick'] % 20) -eq 0) {
            try { $e['AddressText'].Text = [string] (Get-FastLlmUiApiUrl -Status (GetUiBackgroundRunStatus) -Settings (Get-FastLlmServingSettings -InstallRoot $script:installPath)) }
            catch { $null = $_ }
        }
        $e['FactsPanel'].Visibility = [System.Windows.Visibility]::Visible
    }
    else { $e['FactsPanel'].Visibility = [System.Windows.Visibility]::Collapsed }
    $keys['Running'] = $running

    # What a start will use: the model box value and the context value, so the inputs ReadSelection reads are never invisible.
    $contextValue = [int] $script:contextBox.Value
    $contextText = if ($contextValue -eq 0) { [string] $s.ContextDefault } else { [string] $contextValue }
    $e['WillStartText'].Text = ([string] $s.WillStartFormat) -f [string] $script:modelBox.SelectedItem, $contextText
    $e['WillStartPanel'].Visibility = if ($action -ceq 'start') { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }

    # A greyed Open chat says why.
    $chatOff = -not [bool] $script:openChatButton.Enabled
    if ($keys['ChatOff'] -ne $chatOff) {
        $keys['ChatOff'] = $chatOff
        if ($chatOff) {
            $e['OpenChatButton'].ToolTip = [string] $s.OpenChatWhy
            [System.Windows.Automation.AutomationProperties]::SetHelpText($e['OpenChatButton'], [string] $s.OpenChatWhy)
        }
        else {
            $e['OpenChatButton'].ToolTip = $null
            [System.Windows.Automation.AutomationProperties]::SetHelpText($e['OpenChatButton'], '')
        }
    }
}
