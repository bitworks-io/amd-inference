#requires -Version 5.1
# The Settings page of the Fluent window: the page XAML (FastLlm.Settings), the copied Settings text, and the code that holds the Server edits until Save or
# Discard, copies today's Save sequence, and guards leaving the page and closing the window with a "Save your changes?" prompt. Dot-sourced by
# FastLlm.UiFluentShell.ps1. No WPF or WinForms type is resolved at dot-source time, only inside function bodies.
# The held edits and the exit decision are the pure functions in FastLlm.UiState.ps1. Save is a pinned COPY of BuildUiSettingsDialog's Save handler and of
# ShowUiSettings' after-OK block, in today's order (the members suite compares the effect sequences); the dialog is deleted at the flip, and this copy becomes the
# one source. Create a new key calls today's NewUiApiKey, so the rotate call stays single-source in fast-llm-ui.ps1.
Set-StrictMode -Version 2.0

# Today's Settings literals, copied from BuildUiSettingsDialog (the flip deletes the dialog). The members suite pins each value to a string constant of it.
$script:FastLlmUiFluentSettingsText = [ordered]@{
    Title            = 'FastLLM settings'
    Port             = 'Port (127.0.0.1 only)'
    Thinking         = 'Thinking'
    ThinkingAuto     = 'Auto (recommended)'
    ThinkingOff      = 'Off: faster answers. Quality with thinking off is not measured by Bitworks.'
    Chat             = 'Local chat page (off by default)'
    ChatHelp         = 'Chats are kept by your browser, not by FastLLM.'
    Idle             = 'Stop the model when idle'
    IdleNever        = 'Never (default)'
    IdleAfter15      = 'After 15 minutes'
    IdleAfter30      = 'After 30 minutes'
    IdleAfter60      = 'After 60 minutes'
    IdleHelp         = 'Frees the GPU memory. Apps get no answer until you start FastLLM again.'
    Key              = 'Require an API key (off by default)'
    KeyNotSet        = 'Require an API key (not set: tick or clear this box to choose)'
    KeyHelp          = 'Apps must then send the key. It keeps web pages and other Windows accounts on this PC out; it does not stop programs you run. Applies at the next start.'
    NewKey           = 'Create a new key' + [string][char]0x2026
    SignIn           = 'Start FastLLM when I sign in'
    SignInUnreadable = 'Start at sign-in could not be read on this PC.'
    Switch           = 'Allow switching models while FastLLM runs'
    SwitchHelp       = 'Off by default; applies from the next start. A switch checks the new model again and starts the old one if it cannot start. Stop always wins.'
    Save             = 'Save'
    Cancel           = 'Cancel'
    NotTurnedOn      = 'The API key was not turned on: the stored key cannot be read and no new key was created. Nothing was changed.'
}

$script:FastLlmUiXaml['FastLlm.Settings'] = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Grid.RowDefinitions>
    <RowDefinition Height="*"/>
    <RowDefinition Height="Auto"/>
  </Grid.RowDefinitions>
  <ScrollViewer x:Name="SettingsScroll" Grid.Row="0" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Focusable="False">
    <StackPanel Margin="32,24,32,24" MaxWidth="900">
      <TextBlock x:Name="SettingsTitle" TextWrapping="Wrap" FontFamily="{DynamicResource FastLlm.DisplayFont}"
                 FontSize="{DynamicResource FastLlm.SubtitleSize}" FontWeight="{DynamicResource FastLlm.SubtitleWeight}"/>
      <TextBlock x:Name="SettingsStatusText" Margin="0,4,0,0" TextWrapping="Wrap" Foreground="{DynamicResource FastLlm.TextSecondaryBrush}"
                 AutomationProperties.LiveSetting="Polite"/>
      <TextBlock x:Name="SettingsUnavailableText" Margin="0,8,0,0" TextWrapping="Wrap" Visibility="Collapsed"
                 Foreground="{DynamicResource FastLlm.CautionTextBrush}"/>
      <Border x:Name="SettingsServerGroup" Margin="0,24,0,0" Padding="16" BorderThickness="1"
              Background="{DynamicResource FastLlm.CardBrush}" BorderBrush="{DynamicResource FastLlm.CardStrokeBrush}"
              CornerRadius="{DynamicResource FastLlm.OverlayCornerRadius}">
        <StackPanel>
          <TextBlock x:Name="SettingsServerHeading" FontWeight="{DynamicResource FastLlm.BodyStrongWeight}"/>
          <TextBlock x:Name="SettingsPortLabel" Margin="0,12,0,4" TextWrapping="Wrap"/>
          <Grid x:Name="SettingsPortRow" HorizontalAlignment="Left" MinWidth="260">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBox x:Name="SettingsPortBox" Grid.Column="0" Style="{DynamicResource FastLlm.TextBoxStyle}"/>
            <RepeatButton x:Name="SettingsPortUp" Grid.Column="1" Margin="4,0,0,0" Style="{DynamicResource FastLlm.SpinButtonStyle}"
                          IsEnabled="{Binding IsEnabled, ElementName=SettingsPortBox}"/>
            <RepeatButton x:Name="SettingsPortDown" Grid.Column="2" Margin="4,0,0,0" Style="{DynamicResource FastLlm.SpinButtonStyle}"
                          IsEnabled="{Binding IsEnabled, ElementName=SettingsPortBox}"/>
          </Grid>
          <TextBlock x:Name="SettingsThinkingLabel" Margin="0,12,0,4" TextWrapping="Wrap"/>
          <ComboBox x:Name="SettingsThinkingBox" Style="{DynamicResource FastLlm.ComboBoxStyle}"/>
          <CheckBox x:Name="SettingsChatBox" Margin="0,16,0,0" Style="{DynamicResource FastLlm.CheckBoxStyle}"/>
          <TextBlock x:Name="SettingsChatHelp" Margin="28,0,0,0" TextWrapping="Wrap" Foreground="{DynamicResource FastLlm.TextSecondaryBrush}"/>
          <TextBlock x:Name="SettingsIdleLabel" Margin="0,16,0,4" TextWrapping="Wrap"/>
          <ComboBox x:Name="SettingsIdleBox" HorizontalAlignment="Left" MinWidth="260" Style="{DynamicResource FastLlm.ComboBoxStyle}"/>
          <TextBlock x:Name="SettingsIdleHelp" Margin="0,4,0,0" TextWrapping="Wrap" Foreground="{DynamicResource FastLlm.TextSecondaryBrush}"/>
          <Border x:Name="SettingsKeyRow" Margin="0,16,0,0" Padding="8" BorderThickness="2" BorderBrush="Transparent"
                  CornerRadius="{DynamicResource FastLlm.OverlayCornerRadius}">
            <StackPanel>
              <CheckBox x:Name="SettingsKeyBox" Style="{DynamicResource FastLlm.CheckBoxStyle}"/>
              <TextBlock x:Name="SettingsKeyHelp" Margin="28,0,0,0" TextWrapping="Wrap" Foreground="{DynamicResource FastLlm.TextSecondaryBrush}"
                         AutomationProperties.LiveSetting="Polite"/>
              <Button x:Name="SettingsNewKeyButton" Margin="28,8,0,0" HorizontalAlignment="Left" Style="{DynamicResource FastLlm.ButtonStyle}"/>
            </StackPanel>
          </Border>
          <CheckBox x:Name="SettingsSwitchBox" Margin="0,16,0,0" Style="{DynamicResource FastLlm.CheckBoxStyle}"/>
          <TextBlock x:Name="SettingsSwitchHelp" Margin="28,0,0,0" TextWrapping="Wrap" Foreground="{DynamicResource FastLlm.TextSecondaryBrush}"/>
        </StackPanel>
      </Border>
      <Border x:Name="SettingsStartingGroup" Margin="0,16,0,0" Padding="16" BorderThickness="1"
              Background="{DynamicResource FastLlm.CardBrush}" BorderBrush="{DynamicResource FastLlm.CardStrokeBrush}"
              CornerRadius="{DynamicResource FastLlm.OverlayCornerRadius}">
        <StackPanel>
          <TextBlock x:Name="SettingsStartingHeading" FontWeight="{DynamicResource FastLlm.BodyStrongWeight}"/>
          <CheckBox x:Name="SettingsSignInToggle" Margin="0,8,0,0" HorizontalAlignment="Left" Style="{DynamicResource FastLlm.ToggleSwitchStyle}"/>
          <TextBlock x:Name="SettingsSignInState" Margin="0,4,0,0" TextWrapping="Wrap" Foreground="{DynamicResource FastLlm.TextSecondaryBrush}"/>
          <TextBlock x:Name="SettingsSignInLast" Margin="0,4,0,0" TextWrapping="Wrap" Foreground="{DynamicResource FastLlm.TextSecondaryBrush}"/>
        </StackPanel>
      </Border>
      <Border x:Name="SettingsComponentsGroup" Margin="0,16,0,0" Padding="16" BorderThickness="1"
              Background="{DynamicResource FastLlm.CardBrush}" BorderBrush="{DynamicResource FastLlm.CardStrokeBrush}"
              CornerRadius="{DynamicResource FastLlm.OverlayCornerRadius}">
        <StackPanel>
          <TextBlock x:Name="SettingsComponentsHeading" FontWeight="{DynamicResource FastLlm.BodyStrongWeight}"/>
          <CheckBox x:Name="SettingsUpdateToggle" Margin="0,8,0,0" HorizontalAlignment="Left" Style="{DynamicResource FastLlm.ToggleSwitchStyle}"/>
          <CheckBox x:Name="SettingsExperimentalToggle" Margin="0,8,0,0" HorizontalAlignment="Left" Style="{DynamicResource FastLlm.ToggleSwitchStyle}"/>
          <CheckBox x:Name="SettingsLicenseToggle" Margin="0,8,0,0" HorizontalAlignment="Left" Style="{DynamicResource FastLlm.ToggleSwitchStyle}"/>
        </StackPanel>
      </Border>
    </StackPanel>
  </ScrollViewer>
  <Border x:Name="SettingsFooter" Grid.Row="1" Padding="32,12,32,12" BorderThickness="0,1,0,0"
          Background="{DynamicResource FastLlm.LayerBrush}" BorderBrush="{DynamicResource FastLlm.CardStrokeBrush}">
    <Grid MaxWidth="900">
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Left">
        <Button x:Name="SettingsSaveButton" Margin="0,0,8,0" Style="{DynamicResource FastLlm.AccentButtonStyle}"/>
        <Button x:Name="SettingsDiscardButton" Style="{DynamicResource FastLlm.ButtonStyle}"/>
      </StackPanel>
    </Grid>
  </Border>
</Grid>
'@

# The Settings rows of the binding table (after Models). The three groups follow settingsButton (Visual, no event: today's dialog can never open from here), so
# the Server group, the Starting group and the footer are unavailable exactly when today's dialog could not open. The three Components toggles are two-way
# Toggle rows on today's adapters, so today's CheckedChanged handlers (confirmations, mirroring, reverts) run unchanged.
function Get-FastLlmUiFluentSettingsBindings {
    [CmdletBinding()] param()
    return @(
        @{ Name = 'settingsButton';  Element = 'SettingsServerGroup';       Mode = 'Visual'; Event = ''; Flags = @() },
        @{ Name = 'settingsButton';  Element = 'SettingsStartingGroup';     Mode = 'Visual'; Event = ''; Flags = @(); Also = $true },
        @{ Name = 'settingsButton';  Element = 'SettingsFooter';            Mode = 'Visual'; Event = ''; Flags = @(); Also = $true },
        @{ Name = 'updateBox';       Element = 'SettingsUpdateToggle';      Mode = 'Toggle'; Event = ''; Flags = @() },
        @{ Name = 'experimentalBox'; Element = 'SettingsExperimentalToggle'; Mode = 'Toggle'; Event = ''; Flags = @() },
        @{ Name = 'licenseBox';      Element = 'SettingsLicenseToggle';     Mode = 'Toggle'; Event = ''; Flags = @() }
    )
}

# Collects the page's named elements, sets its static text and names, and attaches its handlers. Every name is Settings-prefixed.
function Initialize-FastLlmUiFluentSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Page, [Parameter(Mandatory = $true)][hashtable] $Els)
    $s = $script:FastLlmUiFluentStrings
    $t = $script:FastLlmUiFluentSettingsText
    Add-FastLlmUiFluentElements -Els $Els -Root $Page -Names @('SettingsScroll', 'SettingsTitle', 'SettingsStatusText', 'SettingsUnavailableText', 'SettingsServerGroup',
        'SettingsServerHeading', 'SettingsPortLabel', 'SettingsPortRow', 'SettingsPortBox', 'SettingsPortUp', 'SettingsPortDown', 'SettingsThinkingLabel', 'SettingsThinkingBox',
        'SettingsChatBox', 'SettingsChatHelp', 'SettingsIdleLabel', 'SettingsIdleBox', 'SettingsIdleHelp', 'SettingsKeyRow', 'SettingsKeyBox', 'SettingsKeyHelp',
        'SettingsNewKeyButton', 'SettingsSwitchBox', 'SettingsSwitchHelp', 'SettingsStartingGroup', 'SettingsStartingHeading', 'SettingsSignInToggle', 'SettingsSignInState',
        'SettingsSignInLast', 'SettingsComponentsGroup', 'SettingsComponentsHeading', 'SettingsUpdateToggle', 'SettingsExperimentalToggle', 'SettingsLicenseToggle',
        'SettingsFooter', 'SettingsSaveButton', 'SettingsDiscardButton')
    $Els['SettingsTitle'].Text = [string] $s.NavSettings
    $Els['SettingsServerHeading'].Text = [string] $s.SettingsServer
    $Els['SettingsStartingHeading'].Text = [string] $s.SettingsStarting
    $Els['SettingsComponentsHeading'].Text = [string] $s.SettingsComponents
    $Els['SettingsChatHelp'].Text = [string] $t.ChatHelp
    $Els['SettingsIdleHelp'].Text = [string] $t.IdleHelp
    $Els['SettingsKeyHelp'].Text = [string] $t.KeyHelp
    $Els['SettingsSwitchHelp'].Text = [string] $t.SwitchHelp
    # Each labelled input has its name and its label from one string.
    Set-FastLlmUiFluentConnectInputName -Box $Els['SettingsPortBox'] -Label $Els['SettingsPortLabel'] -Text ([string] $t.Port)
    Set-FastLlmUiFluentConnectInputName -Box $Els['SettingsThinkingBox'] -Label $Els['SettingsThinkingLabel'] -Text ([string] $t.Thinking)
    Set-FastLlmUiFluentConnectInputName -Box $Els['SettingsIdleBox'] -Label $Els['SettingsIdleLabel'] -Text ([string] $t.Idle)
    # A check box names itself with its own caption (the same string it shows).
    foreach ($pair in @(@('SettingsChatBox', 'Chat'), @('SettingsSwitchBox', 'Switch'), @('SettingsSignInToggle', 'SignIn'))) {
        $caption = [string] $t[[string] $pair[1]]
        $Els[[string] $pair[0]].Content = ConvertTo-FastLlmUiAccessText -Text $caption -UseMnemonic $false
        [System.Windows.Automation.AutomationProperties]::SetName($Els[[string] $pair[0]], $caption)
    }
    $Els['SettingsNewKeyButton'].Content = ConvertTo-FastLlmUiAccessText -Text ([string] $t.NewKey) -UseMnemonic $false
    $Els['SettingsSaveButton'].Content = ConvertTo-FastLlmUiAccessText -Text ([string] $t.Save) -UseMnemonic $false
    $Els['SettingsDiscardButton'].Content = ConvertTo-FastLlmUiAccessText -Text ([string] $s.Discard) -UseMnemonic $false
    foreach ($item in @($t.ThinkingAuto, $t.ThinkingOff)) { $null = $Els['SettingsThinkingBox'].Items.Add([string] $item) }
    foreach ($item in @($t.IdleNever, $t.IdleAfter15, $t.IdleAfter30, $t.IdleAfter60)) { $null = $Els['SettingsIdleBox'].Items.Add([string] $item) }
    # The spin buttons: icon glyphs (drawn, not read), named, never tab stops (their style).
    $Els['SettingsPortUp'].Content = New-FastLlmUiFluentGlyphText 0xE70E
    $Els['SettingsPortDown'].Content = New-FastLlmUiFluentGlyphText 0xE70D
    [System.Windows.Automation.AutomationProperties]::SetName($Els['SettingsPortUp'], [string] $s.SpinUp)
    [System.Windows.Automation.AutomationProperties]::SetName($Els['SettingsPortDown'], [string] $s.SpinDown)

    # The Server edits write the held values (Invoke-FastLlmUiFluentSettingsEdit). The Port box commits its text on Enter, on focus loss and through the spin
    # buttons; Up and Down are read in PreviewKeyDown because a TextBox handles them before instance KeyDown handlers.
    $Els['SettingsPortBox'].Add_PreviewKeyDown({
            param($sender, $routed)
            if ($routed.Key -eq [System.Windows.Input.Key]::Return) { Invoke-FastLlmUiFluentSettingsPortCommit -Direction '' }
            elseif ($routed.Key -eq [System.Windows.Input.Key]::Up) { $routed.Handled = $true; Invoke-FastLlmUiFluentSettingsPortCommit -Direction 'Up' }
            elseif ($routed.Key -eq [System.Windows.Input.Key]::Down) { $routed.Handled = $true; Invoke-FastLlmUiFluentSettingsPortCommit -Direction 'Down' }
        })
    $Els['SettingsPortBox'].Add_LostKeyboardFocus({ param($sender, $routed) Invoke-FastLlmUiFluentSettingsPortCommit -Direction '' })
    $Els['SettingsPortUp'].Add_Click({ param($sender, $routed) Invoke-FastLlmUiFluentSettingsPortCommit -Direction 'Up' })
    $Els['SettingsPortDown'].Add_Click({ param($sender, $routed) Invoke-FastLlmUiFluentSettingsPortCommit -Direction 'Down' })
    $Els['SettingsThinkingBox'].Add_SelectionChanged({ param($sender, $routed) Invoke-FastLlmUiFluentSettingsEdit })
    $Els['SettingsIdleBox'].Add_SelectionChanged({ param($sender, $routed) Invoke-FastLlmUiFluentSettingsEdit })
    foreach ($name in 'SettingsChatBox', 'SettingsSwitchBox') {
        $Els[$name].Add_Checked({ param($sender, $routed) Invoke-FastLlmUiFluentSettingsEdit })
        $Els[$name].Add_Unchecked({ param($sender, $routed) Invoke-FastLlmUiFluentSettingsEdit })
    }
    # The key box: today's click handler (touched, no more three-state). A UIA Toggle raises no Click, so a state change that is not a refill does the same.
    $Els['SettingsKeyBox'].Add_Click({ param($sender, $routed) Invoke-FastLlmUiFluentSettingsKeyClick })
    $Els['SettingsKeyBox'].Add_Checked({ param($sender, $routed) if (-not [bool] $script:FastLlmUiFluent['Settings']['Loading']) { Invoke-FastLlmUiFluentSettingsKeyClick } })
    $Els['SettingsKeyBox'].Add_Unchecked({ param($sender, $routed) if (-not [bool] $script:FastLlmUiFluent['Settings']['Loading']) { Invoke-FastLlmUiFluentSettingsKeyClick } })
    $Els['SettingsNewKeyButton'].Add_Click({ param($sender, $routed) Invoke-FastLlmUiFluentSettingsNewKey })
    # Sign-in start is immediate: Checked and Unchecked (never Click), skipped while the page itself writes the box.
    $Els['SettingsSignInToggle'].Add_Checked({ param($sender, $routed) Invoke-FastLlmUiFluentSettingsSignIn })
    $Els['SettingsSignInToggle'].Add_Unchecked({ param($sender, $routed) Invoke-FastLlmUiFluentSettingsSignIn })
    $Els['SettingsSaveButton'].Add_Click({ param($sender, $routed) $null = Invoke-FastLlmUiFluentSettingsSave })
    $Els['SettingsDiscardButton'].Add_Click({ param($sender, $routed) Invoke-FastLlmUiFluentSettingsDiscard })
    foreach ($name in 'SettingsPortBox', 'SettingsThinkingBox', 'SettingsIdleBox', 'SettingsChatBox', 'SettingsKeyBox', 'SettingsNewKeyButton', 'SettingsSwitchBox',
        'SettingsSignInToggle', 'SettingsSaveButton', 'SettingsDiscardButton') {
        [System.Windows.Controls.ToolTipService]::SetShowOnDisabled($Els[$name], $true)
    }
    $f = $script:FastLlmUiFluent
    $f['Settings'] = @{ Saved = $null; Held = $null; Current = $null; Dirty = $false; Loading = $false; KeyMarked = $false; PromptOpen = $false }
    return $Els
}

# Settings' entry in the page registry. Its status line is the card's composed text, announced only while Settings is the current page.
function Register-FastLlmUiFluentSettingsPage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Page, [Parameter(Mandatory = $true)][hashtable] $Els)
    Register-FastLlmUiFluentPage -Id 'Settings' -Element $Page -Nav 'NavSettings' -Status $Els['SettingsStatusText'] -Enter 'Enter-FastLlmUiFluentSettings' -Leave 'Exit-FastLlmUiFluentSettings' -Update 'Update-FastLlmUiFluentSettings'
}

# What ShowUiSettings reads when it opens (copied): the serving settings, with the window's allow-switch value added.
function Read-FastLlmUiFluentSettingsCurrent {
    [CmdletBinding()] param()
    $current=Get-FastLlmServingSettings -InstallRoot $script:installPath
    $current | Add-Member -NotePropertyName allowSwitch -NotePropertyValue ([bool]$script:uiSettings.allowSwitch) -Force
    return $current
}

# Writes the held values to the Server controls (the page's own writes: Loading keeps the change handlers quiet). The key box is three-state only while
# the saved setting is not known, with its "not set" caption.
function Set-FastLlmUiFluentSettingsView {
    [CmdletBinding()] param()
    $f = $script:FastLlmUiFluent
    $e = $f['Els']
    $st = $f['Settings']
    $t = $script:FastLlmUiFluentSettingsText
    $held = $st['Held']
    $st['Loading'] = $true
    try {
        $e['SettingsPortBox'].Text = ([decimal] $held.port).ToString('F0')
        $e['SettingsThinkingBox'].SelectedIndex = [int] $held.thinkingIndex
        $e['SettingsChatBox'].IsChecked = [bool] $held.chatPage
        $e['SettingsIdleBox'].SelectedIndex = [int] $held.idleIndex
        $e['SettingsSwitchBox'].IsChecked = [bool] $held.allowSwitch
        $keyBox = $e['SettingsKeyBox']
        $caption = [string] $t.Key
        if ([string] $held.keyBox -ceq 'indeterminate') {
            $caption = [string] $t.KeyNotSet
            $keyBox.IsThreeState = $true
            $keyBox.IsChecked = $null
        }
        else {
            $keyBox.IsThreeState = $false
            $keyBox.IsChecked = [bool] ([string] $held.keyBox -ceq 'checked')
        }
        $keyBox.Content = ConvertTo-FastLlmUiAccessText -Text $caption -UseMnemonic $false
        [System.Windows.Automation.AutomationProperties]::SetName($keyBox, $caption)
    }
    finally { $st['Loading'] = $false }
    $st['Dirty'] = [bool] (Test-FastLlmUiSettingsDirty -Saved $st['Saved'] -Held $held)
}

# Reads the settings again: a fresh Current, Saved = Held (two objects with the same values), the controls filled. Enter and a saved Save both run it, so the
# three-state key box is re-derived and a second Save on the same visit is not refused as undetermined.
function Update-FastLlmUiFluentSettingsLoad {
    [CmdletBinding()] param()
    $st = $script:FastLlmUiFluent['Settings']
    $current = Read-FastLlmUiFluentSettingsCurrent
    $st['Current'] = $current
    $st['Saved'] = ConvertTo-FastLlmUiSettingsHeld -Current $current
    $st['Held'] = ConvertTo-FastLlmUiSettingsHeld -Current $current
    Set-FastLlmUiFluentSettingsView
}

# The sign-in rows from a view (today's $showSignIn): the toggle shows what was read back, written by the page (Loading keeps its handler quiet).
function Show-FastLlmUiFluentSettingsSignIn {
    [CmdletBinding()] param([Parameter(Mandatory = $true)] $View)
    $f = $script:FastLlmUiFluent
    $e = $f['Els']
    $st = $f['Settings']
    $previous = [bool] $st['Loading']
    $st['Loading'] = $true
    try {
        $e['SettingsSignInToggle'].IsChecked = [bool] $View.checked
        $e['SettingsSignInState'].Text = [string] $View.stateText
        $e['SettingsSignInLast'].Text = [string] $View.lastResultText
    }
    finally { $st['Loading'] = $previous }
}

# The key row's mark after a refused key decision: a caution border and the key-free text in the row's help. Cleared by a key click, Discard and a saved Save.
function Set-FastLlmUiFluentSettingsKeyMark {
    [CmdletBinding()] param([Parameter(Mandatory = $true)][bool] $On, [AllowEmptyString()][string] $Text = '')
    $f = $script:FastLlmUiFluent
    $e = $f['Els']
    $st = $f['Settings']
    $t = $script:FastLlmUiFluentSettingsText
    if ($On) {
        $e['SettingsKeyRow'].SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'FastLlm.CautionTextBrush')
        $e['SettingsKeyHelp'].Text = $Text
        [System.Windows.Automation.AutomationProperties]::SetHelpText($e['SettingsKeyBox'], $Text)
    }
    else {
        if (-not [bool] $st['KeyMarked']) { return }
        $e['SettingsKeyRow'].BorderBrush = [System.Windows.Media.Brushes]::Transparent
        $e['SettingsKeyHelp'].Text = [string] $t.KeyHelp
        [System.Windows.Automation.AutomationProperties]::SetHelpText($e['SettingsKeyBox'], '')
    }
    $st['KeyMarked'] = $On
}

# Opening the page does what ShowUiSettings does when it opens: reads the settings, fills the controls, reads the sign-in view (today's try/catch).
function Enter-FastLlmUiFluentSettings {
    [CmdletBinding()] param()
    try {
        $e = $script:FastLlmUiFluent['Els']
        $t = $script:FastLlmUiFluentSettingsText
        Set-FastLlmUiFluentSettingsKeyMark -On $false
        Update-FastLlmUiFluentSettingsLoad
        # The three immediate toggles name themselves with the caption their adapter shows.
        foreach ($pair in @(@('SettingsUpdateToggle', 'updateBox'), @('SettingsExperimentalToggle', 'experimentalBox'), @('SettingsLicenseToggle', 'licenseBox'))) {
            [System.Windows.Automation.AutomationProperties]::SetName($e[[string] $pair[0]], [string] (Get-Variable -Name ([string] $pair[1]) -Scope Script -ValueOnly).Text)
        }
        $e['SettingsSignInToggle'].IsEnabled = $true
        try { Show-FastLlmUiFluentSettingsSignIn -View (Get-FastLlmSignInSettingsView -AppRoot $script:FastLlmUiFluentSourceRoot -InstallRoot (Get-FastLlmSignInDefaultInstallRoot)) }
        catch { $e['SettingsSignInToggle'].IsEnabled = $false; $e['SettingsSignInState'].Text = [string] $t.SignInUnreadable }
        Update-FastLlmUiFluentSettings
    }
    catch { ShowFailure $_.Exception.Message }
}

# Leaving the page: not dirty goes; otherwise the save prompt decides. Returns exactly one [bool] ($false keeps the page).
function Exit-FastLlmUiFluentSettings {
    [CmdletBinding()] param()
    return [bool] (Resolve-FastLlmUiFluentSettingsExit -Reason 'leave')
}

# The window is closing. Returns exactly one [bool]: $true refuses the close (the prompt was cancelled or Save was refused). It runs whether or not Settings is
# the current page (edits exist only while it is, because leaving always asks), and before the FormClosing guards, so a Cancel runs none of them.
function Test-FastLlmUiFluentSettingsCloseRefused {
    [CmdletBinding()] param()
    return [bool] (-not [bool] (Resolve-FastLlmUiFluentSettingsExit -Reason 'close'))
}

# The decision for leaving or closing with the held edits (the pure table is Get-FastLlmUiSettingsExitDecision). Returns exactly one [bool]: $true = go.
function Resolve-FastLlmUiFluentSettingsExit {
    [CmdletBinding()] param([Parameter(Mandatory = $true)][ValidateSet('leave', 'close')][string] $Reason)
    $st = $script:FastLlmUiFluent['Settings']
    if ($null -eq $st -or $null -eq $st['Held']) { return $true }
    Invoke-FastLlmUiFluentSettingsPortCommit -Direction ''
    $dirty = [bool] $st['Dirty']
    if (-not $dirty) { return $true }
    # One prompt at a time: a second close while it is open is refused.
    if ([bool] $st['PromptOpen']) { return $false }
    $st['PromptOpen'] = $true
    try {
        $available = [bool] $script:settingsButton.Enabled
        $answer = Show-FastLlmUiFluentSavePrompt -SaveEnabled $available -Reason (Get-FastLlmUiFluentSettingsUnavailableText)
    }
    finally { $st['PromptOpen'] = $false }
    $decision = [string] (Get-FastLlmUiSettingsExitDecision -Dirty $dirty -Answer $answer -Reason $Reason)
    if ($decision -ceq 'save') {
        $saved = [bool] (@(Invoke-FastLlmUiFluentSettingsSave) | Select-Object -Last 1)
        $decision = [string] (Get-FastLlmUiSettingsExitDecision -Dirty $dirty -Answer $answer -SaveOk $saved -Reason $Reason)
    }
    if ($decision -ceq 'discard-go') {
        # Only leaving the page discards. A close goes without discarding: the edits die with the window, and survive if a FormClosing guard keeps it open.
        if ($Reason -ceq 'leave') { Invoke-FastLlmUiFluentSettingsDiscard }
        return $true
    }
    return [bool] ($decision -ceq 'go')
}

# The greyed reason for Settings as a line ('' while Settings is available).
function Get-FastLlmUiFluentSettingsUnavailableText {
    [CmdletBinding()] param()
    if ([bool] $script:settingsButton.Enabled) { return '' }
    $snapshot = GetUiStateSnapshot ([bool]($script:child -or $script:vcBroker -or $script:updateRun))
    return [string] (Get-FastLlmUiFluentToolsReasonText -Code ([string] (Get-FastLlmUiGreyedReason -Action 'settings' -Snapshot $snapshot)))
}

# Once per tick while Settings shows: the reason line is visible exactly while the Server group, the Starting group and the footer are unavailable. It is
# written on change only. The held edits are never touched here.
function Update-FastLlmUiFluentSettings {
    [CmdletBinding()] param()
    $f = $script:FastLlmUiFluent
    $e = $f['Els']
    $keys = $f['Keys']
    $text = Get-FastLlmUiFluentSettingsUnavailableText
    if ($keys['SettingsWhy'] -ceq $text) { return }
    $keys['SettingsWhy'] = $text
    $line = $e['SettingsUnavailableText']
    $line.Text = $text
    if ($text -ne '') { $line.Visibility = [System.Windows.Visibility]::Visible } else { $line.Visibility = [System.Windows.Visibility]::Collapsed }
    [System.Windows.Automation.AutomationProperties]::SetHelpText($e['SettingsServerHeading'], $text)
}

# A Server control changed: the held values are read from the controls (never while the page itself writes them), and Dirty is recomputed.
function Invoke-FastLlmUiFluentSettingsEdit {
    [CmdletBinding()] param()
    $f = $script:FastLlmUiFluent
    $st = $f['Settings']
    if ($null -eq $st['Held'] -or [bool] $st['Loading']) { return }
    $e = $f['Els']
    $held = $st['Held']
    $held.thinkingIndex = [int] $e['SettingsThinkingBox'].SelectedIndex
    $held.chatPage = [bool] ($e['SettingsChatBox'].IsChecked -eq $true)
    $held.idleIndex = [int] $e['SettingsIdleBox'].SelectedIndex
    $held.keyBox = [string] (ConvertTo-FastLlmUiKeyBoxState -IsChecked $e['SettingsKeyBox'].IsChecked)
    $held.allowSwitch = [bool] ($e['SettingsSwitchBox'].IsChecked -eq $true)
    $st['Dirty'] = [bool] (Test-FastLlmUiSettingsDirty -Saved $st['Saved'] -Held $held)
}

# The Port box commits through the clamp (1024..65535, step 1): the typed text, or a step first for Up and Down; the shown text is then normalised.
function Invoke-FastLlmUiFluentSettingsPortCommit {
    [CmdletBinding()] param([AllowEmptyString()][string] $Direction = '')
    $f = $script:FastLlmUiFluent
    $st = $f['Settings']
    if ($null -eq $st['Held'] -or [bool] $st['Loading']) { return }
    $box = $f['Els']['SettingsPortBox']
    $held = $st['Held']
    $value = ConvertTo-FastLlmUiNumericValue -Text ([string] $box.Text) -Current ([decimal] $held.port) -Minimum ([decimal] 1024) -Maximum ([decimal] 65535)
    if ($Direction -ceq 'Up') { $value = Step-FastLlmUiNumericValue -Current $value -Increment ([decimal] 1) -Minimum ([decimal] 1024) -Maximum ([decimal] 65535) -Up }
    elseif ($Direction -ceq 'Down') { $value = Step-FastLlmUiNumericValue -Current $value -Increment ([decimal] 1) -Minimum ([decimal] 1024) -Maximum ([decimal] 65535) }
    $held.port = [int] $value
    $shown = ([decimal] $value).ToString('F0')
    if ($box.Text -cne $shown) { $box.Text = $shown }
    $st['Dirty'] = [bool] (Test-FastLlmUiSettingsDirty -Saved $st['Saved'] -Held $held)
}

# Today's $keyBox.Add_Click body: the box was touched and is no longer three-state (the first click clears it, the next one ticks it). A key click also
# clears the mark of a refused key decision.
function Invoke-FastLlmUiFluentSettingsKeyClick {
    [CmdletBinding()] param()
    $f = $script:FastLlmUiFluent
    $st = $f['Settings']
    if ($null -eq $st['Held']) { return }
    $st['Held'].keyTouched = $true
    $f['Els']['SettingsKeyBox'].IsThreeState = $false
    Set-FastLlmUiFluentSettingsKeyMark -On $false
    Invoke-FastLlmUiFluentSettingsEdit
}

# Discard: the held edits go back to the saved values, the controls are refilled, the key row mark and keyTouched are cleared, and the three-state is
# restored when the saved key setting is not known.
function Invoke-FastLlmUiFluentSettingsDiscard {
    [CmdletBinding()] param()
    $st = $script:FastLlmUiFluent['Settings']
    if ($null -eq $st['Held']) { return }
    $st['Held'] = [pscustomobject][ordered]@{
        port = [int] $st['Saved'].port; thinkingIndex = [int] $st['Saved'].thinkingIndex; chatPage = [bool] $st['Saved'].chatPage; idleIndex = [int] $st['Saved'].idleIndex
        keyBox = [string] $st['Saved'].keyBox; keyTouched = $false; allowSwitch = [bool] $st['Saved'].allowSwitch
    }
    Set-FastLlmUiFluentSettingsKeyMark -On $false
    Set-FastLlmUiFluentSettingsView
}

# Create a new key...: today's handler with the owner changed. It takes effect at once, as today, and is not a held edit.
function Invoke-FastLlmUiFluentSettingsNewKey {
    [CmdletBinding()] param()
    try{[void](NewUiApiKey $script:form)}
    catch{$newKeyFailureText=[string]$_.Exception.Message;[void](Show-FastLlmUiFluentMessageBox -Owner $script:form -Text (ConvertTo-FastLlmKeyFreeText -Text ([ref]$newKeyFailureText)) -Caption 'FastLLM settings' -Buttons 'OK' -Icon 'Warning')}
}

# Start FastLLM when I sign in: today's startBox handler with the owner changed and the source root as AppRoot. It is immediate: the Run entry is the truth.
function Invoke-FastLlmUiFluentSettingsSignIn {
    [CmdletBinding()] param()
    $f = $script:FastLlmUiFluent
    $st = $f['Settings']
    if ($null -eq $st['Held'] -or [bool] $st['Loading']) { return }
    $startBox = $f['Els']['SettingsSignInToggle']
    try{Show-FastLlmUiFluentSettingsSignIn -View (Set-FastLlmSignInStartEnabled -AppRoot $script:FastLlmUiFluentSourceRoot -InstallRoot (Get-FastLlmSignInDefaultInstallRoot) -Enabled ([bool]($startBox.IsChecked -eq $true)))}
    catch{
        $signInFailureText=[string]$_.Exception.Message
        [void](Show-FastLlmUiFluentMessageBox -Owner $script:form -Text (ConvertTo-FastLlmKeyFreeText -Text ([ref]$signInFailureText)) -Caption 'FastLLM settings' -Buttons 'OK' -Icon 'Warning')
        try{Show-FastLlmUiFluentSettingsSignIn -View (Get-FastLlmSignInSettingsView -AppRoot $script:FastLlmUiFluentSourceRoot -InstallRoot (Get-FastLlmSignInDefaultInstallRoot))}catch{$null=$_}
    }
}

# Save: a pinned copy of BuildUiSettingsDialog's Save handler (the try body and the catch) and of ShowUiSettings' after-OK block, in today's order, with the
# held values in place of the dialog's controls. Returns exactly one [bool]: $true when the settings were written. The page stays on a refusal, with the edits kept.
function Invoke-FastLlmUiFluentSettingsSave {
    [CmdletBinding()] param()
    $f = $script:FastLlmUiFluent
    $e = $f['Els']
    $st = $f['Settings']
    if ($null -eq $st['Held']) { return $false }
    Invoke-FastLlmUiFluentSettingsPortCommit -Direction ''
    # A fluent-only guard: Settings is not available (a run, an install or Microsoft setup), so nothing is written; the reason line already says why.
    if (-not [bool] $script:settingsButton.Enabled) {
        Update-FastLlmUiFluentSettings
        return $false
    }
    $current = $st['Current']
    $before = $current
    $held = $st['Held']
    $keyBox = $e['SettingsKeyBox']
    $stage = 'key'
    $saved = $false
    try{
        $values = ConvertFrom-FastLlmUiSettingsHeld -Held $held
        $savedThinking=[string]$values.thinking
        $savedIdle=[int]$values.idleStopMinutes
        # The API key first, so a refusal leaves every setting as it was. On creates a key only when there is none; when the stored key
        # cannot be read it is refused, and the one offer is to create a new key (asked, never silent).
        $keyAction=Get-FastLlmUiApiKeySaveAction -Current ([string]$current.apiKey) -Undetermined ([bool]$current.apiKeyUndetermined) -BoxState (ConvertTo-FastLlmUiKeyBoxState -IsChecked $keyBox.IsChecked) -Touched ([bool]$held.keyTouched)
        if($keyAction -ceq 'ask'){throw (Get-FastLlmUiApiKeyChoiceText)}
        $wantKey=[bool]($keyBox.IsChecked -eq $true)
        if($keyAction -ceq 'on'){
            try{$null=Invoke-FastLlmApiKeySetting -InstallRoot $script:installPath -Action on}
            catch{
                if([string]$_.Exception.Data['FastLlmFailureCode'] -cne 'api-key-unavailable'){throw}
                if(-not (NewUiApiKey $script:form)){throw ([string]$script:FastLlmUiFluentSettingsText.NotTurnedOn)}
                $null=Invoke-FastLlmApiKeySetting -InstallRoot $script:installPath -Action on
            }
        }elseif($keyAction -ceq 'off'){
            $null=Invoke-FastLlmApiKeySetting -InstallRoot $script:installPath -Action off
        }
        $stage = 'serving'
        $savedApiKey=$(if($wantKey){'on'}else{'off'})
        $script:apiKeyStore=$null
        Set-FastLlmServingSettings -InstallRoot $script:installPath -ServerPort ([int]$values.serverPort) -Thinking $savedThinking -ChatPage ([string]$values.chatPage) -IdleStopMinutes $savedIdle
        Set-FastLlmUiAllowSwitch -InstallRoot $script:settingsRoot -Value ([bool]$values.allowSwitch)
        $script:uiSettings.allowSwitch=[bool]$values.allowSwitch
        $after=[pscustomobject]@{serverPort=[int]$values.serverPort;thinking=$savedThinking;chatPage=[string]$values.chatPage;idleStopMinutes=$savedIdle;apiKey=[string]$savedApiKey;allowSwitch=[bool]$values.allowSwitch}
        $saved = $true
    }catch{
        $saveFailureText=[string]$_.Exception.Message
        [void](Show-FastLlmUiFluentMessageBox -Owner $script:form -Text (ConvertTo-FastLlmKeyFreeText -Text ([ref]$saveFailureText)) -Caption 'FastLLM settings' -Buttons 'OK' -Icon 'Warning')
        # A refusal before the serving write is about the key: the key row is marked, with the key-free text.
        if($stage -ceq 'key'){
            $markText = ConvertTo-FastLlmKeyFreeText -Text ([ref]$saveFailureText)
            Set-FastLlmUiFluentSettingsKeyMark -On $true -Text ([string]$markText)
        }
    }
    if(-not $saved){return $false}
    # The writes are done: read the settings again (Saved = Held, keyTouched cleared, the three-state re-derived), so a second Save is not refused.
    try{
        Set-FastLlmUiFluentSettingsKeyMark -On $false
        Update-FastLlmUiFluentSettingsLoad
    }catch{ShowFailure $_.Exception.Message}
    # The after-OK block of ShowUiSettings, with its own failure path: a late throw never turns a completed save into a refused one.
    try{
        RefreshUiSwitchState
        $runActive=[bool]($script:child -or $script:bgState.attachedRequestId -or ($script:bgState.observation -and $script:bgState.observation.occupied))
        $script:statusLabel.Text=Get-FastLlmUiSettingsSavedNote -RunActive $runActive -Before $before -After $after
        if([string]$before.chatPage -ceq 'on' -and [string]$after.chatPage -ceq 'off'){
            $script:statusLabel.Text=([string]$script:statusLabel.Text+' '+(Get-FastLlmUiChatPageOffNote -Port ([int]$after.serverPort)))
        }
        # The 250 ms tick rewrites the status line while a run is active, so the notes are also shown where they stay put.
        if($runActive -and -not [string]::IsNullOrWhiteSpace([string]$script:statusLabel.Text)){
            [void](Show-FastLlmUiFluentMessageBox -Owner $script:form -Text ([string]$script:statusLabel.Text) -Caption 'FastLLM settings' -Buttons 'OK' -Icon 'Information')
        }
    }catch{ShowFailure $_.Exception.Message}
    return $true
}

# The "Save your changes?" prompt, on the dialog host (a MessageBox cannot caption Save, Don't save and Cancel). Enter and Escape both mean Cancel (nothing is
# written, nothing is lost), and the first focus is Cancel, the Enter target. Save is disabled while Settings is unavailable, and the reason is shown.
# Returns exactly one string: save, discard or cancel.
function Show-FastLlmUiFluentSavePrompt {
    [CmdletBinding()]
    param([bool] $SaveEnabled = $true, [AllowEmptyString()][string] $Reason = '')
    $s = $script:FastLlmUiFluentStrings
    $t = $script:FastLlmUiFluentSettingsText
    $text = [string] $s.SavePrompt
    if ($Reason -ne '') { $text = $text + [Environment]::NewLine + $Reason }
    $body = New-Object System.Windows.Controls.TextBlock
    $body.Text = $text
    $body.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $buttons = [ordered] @{ Save = [string] $t.Save; DontSave = [string] $s.DontSave; Cancel = [string] $t.Cancel }
    $dialog = New-FastLlmUiFluentDialog -Title ([string] $t.Title) -Body $body -Buttons $buttons -Enter 'Cancel' -Escape 'Cancel' -Owner $script:form
    $dialog['Buttons']['Save'].IsEnabled = $SaveEnabled
    SetTrayMenuAvailable $false
    $answer = 'Cancel'
    try { $answer = [string] (Show-FastLlmUiFluentDialog -Dialog $dialog) } finally { SetTrayMenuAvailable $true }
    if ($answer -ceq 'Save') { return 'save' }
    if ($answer -ceq 'DontSave') { return 'discard' }
    return 'cancel'
}
