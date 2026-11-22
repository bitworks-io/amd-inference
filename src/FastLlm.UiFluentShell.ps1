#requires -Version 5.1
# The Fluent window shell: the window, the navigation pane, the message area, the theme, the 250 ms refresh and the message loop.
# Dot-sourced by fast-llm-ui.ps1 only with -Window fluent, right after the existing dot-sources. The seam calls Test-FastLlmUiFluentHost
# (FastLlm.UiFluentSupport.ps1), then Initialize-FastLlmUiFluentShell right after the control-creation block, then Start-FastLlmUiFluentLoop.
# No WPF or WinForms type is resolved at dot-source time, only inside function bodies. The new fluent-only strings are in
# FastLlm.UiFluentHome.ps1 ($script:FastLlmUiFluentStrings); today's captions come only from the adapters.
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'FastLlm.UiFluentAdapter.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.UiFluentSupport.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.UiFluentForm.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.UiFluentBindings.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.UiTheme.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.UiWindow.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.UiXaml.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.UiFluentIcon.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.UiFluentHooks.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.UiFluentHome.ps1')

$script:FastLlmUiFluentSourceRoot = Split-Path -Parent $PSScriptRoot
# State shared by the handlers: they are not closures, so nothing lives in a function's locals. Els: every named element; Keys: last-applied values.
$script:FastLlmUiFluent = @{ Window = $null; Els = @{}; Keys = @{}; Timer = $null; Tick = 0; Theme = ''; ThemeKey = ''; Interop = $false; Hooks = $null
    NavItems = @(); LastException = $null; InUnhandled = $false; TickError = '' }

# Window size in epx (spec 6.5). Set BEFORE the form adapter exists: creating it calls EnsureHandle(), after which some properties lock.
$script:FastLlmUiFluentWindowSize = @{ Width = 1000; Height = 680; MinWidth = 640; MinHeight = 480 }

$script:FastLlmUiXaml['FastLlm.Shell'] = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        UseLayoutRounding="True" SnapsToDevicePixels="True"
        FontFamily="{DynamicResource FastLlm.TextFont}" FontSize="{DynamicResource FastLlm.BodySize}"
        Foreground="{DynamicResource FastLlm.TextPrimaryBrush}" Background="{DynamicResource FastLlm.LayerBrush}">
  <Window.Resources>
    <Style x:Key="FastLlm.ButtonStyle" TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource FastLlm.TextPrimaryBrush}"/>
      <Setter Property="Background" Value="{DynamicResource FastLlm.CardBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource FastLlm.ControlStrokeBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12,5,12,5"/>
      <Setter Property="MinHeight" Value="{DynamicResource FastLlm.ControlHeight}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="{DynamicResource FastLlm.ControlCornerRadius}">
              <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.7"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource FastLlm.TextPrimaryBrush}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="FastLlm.AccentButtonStyle" TargetType="Button" BasedOn="{StaticResource FastLlm.ButtonStyle}">
      <Setter Property="Foreground" Value="{DynamicResource FastLlm.TextOnAccentBrush}"/>
      <Setter Property="Background" Value="{DynamicResource FastLlm.AccentFillBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource FastLlm.AccentFillBrush}"/>
    </Style>
    <Style x:Key="FastLlm.IconButtonStyle" TargetType="Button" BasedOn="{StaticResource FastLlm.ButtonStyle}">
      <Setter Property="FontFamily" Value="{DynamicResource FastLlm.IconFont}"/>
      <Setter Property="Padding" Value="0"/>
      <Setter Property="MinWidth" Value="32"/>
      <Setter Property="MinHeight" Value="32"/>
    </Style>
    <Style x:Key="FastLlm.AccentIconButtonStyle" TargetType="Button" BasedOn="{StaticResource FastLlm.AccentButtonStyle}">
      <Setter Property="FontFamily" Value="{DynamicResource FastLlm.IconFont}"/>
    </Style>
    <Style x:Key="FastLlm.LinkButtonStyle" TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource FastLlm.AccentFillBrush}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="Padding" Value="2,2,2,2"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}">
              <ContentPresenter Margin="{TemplateBinding Padding}" RecognizesAccessKey="True">
                <ContentPresenter.Resources>
                  <Style TargetType="TextBlock"><Setter Property="TextDecorations" Value="Underline"/></Style>
                  <Style TargetType="AccessText"><Setter Property="TextDecorations" Value="Underline"/></Style>
                </ContentPresenter.Resources>
              </ContentPresenter>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.8"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource FastLlm.TextPrimaryBrush}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Opacity" Value="0.5"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="FastLlm.NavItemStyle" TargetType="ListBoxItem">
      <Setter Property="Foreground" Value="{DynamicResource FastLlm.TextPrimaryBrush}"/>
      <Setter Property="Margin" Value="8,1,8,1"/>
      <Setter Property="Padding" Value="12,0,8,0"/>
      <Setter Property="MinHeight" Value="40"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Grid>
              <Border x:Name="Bd" Background="Transparent" BorderBrush="Transparent" BorderThickness="1"
                      CornerRadius="{DynamicResource FastLlm.ControlCornerRadius}"/>
              <Rectangle x:Name="Bar" Width="3" Height="16" RadiusX="1.5" RadiusY="1.5" HorizontalAlignment="Left" VerticalAlignment="Center"
                         Fill="{DynamicResource FastLlm.AccentFillBrush}" Visibility="Collapsed"/>
              <ContentPresenter Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource FastLlm.CardBrush}"/></Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource FastLlm.CardBrush}"/>
                <Setter TargetName="Bar" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource FastLlm.TextPrimaryBrush}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.55"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition x:Name="PaneColumn" Width="220"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>
    <DockPanel Grid.Column="0" Margin="0,12,0,12" LastChildFill="True">
      <ListBox x:Name="NavSettingsList" DockPanel.Dock="Bottom" Background="Transparent" BorderThickness="0" KeyboardNavigation.TabNavigation="Once"/>
      <ListBox x:Name="NavList" Background="Transparent" BorderThickness="0" KeyboardNavigation.TabNavigation="Once"/>
    </DockPanel>
    <Grid Grid.Column="1">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <StackPanel Grid.Row="0">
        <Border x:Name="UpdateBar" Visibility="Collapsed" Margin="24,16,24,0" Padding="12,8,12,8" BorderThickness="1"
                Background="{DynamicResource FastLlm.CardBrush}" BorderBrush="{DynamicResource FastLlm.CardStrokeBrush}"
                CornerRadius="{DynamicResource FastLlm.ControlCornerRadius}">
          <WrapPanel VerticalAlignment="Center">
            <TextBlock x:Name="UpdateText" TextWrapping="Wrap" VerticalAlignment="Center" Margin="0,0,12,0"/>
            <Button x:Name="UpdateNotesButton" Margin="0,0,12,0" Style="{DynamicResource FastLlm.LinkButtonStyle}"/>
            <Button x:Name="UpdateButton" Margin="0,0,8,0" Style="{DynamicResource FastLlm.ButtonStyle}"/>
            <Button x:Name="ReinstallButton" Style="{DynamicResource FastLlm.ButtonStyle}"/>
          </WrapPanel>
        </Border>
        <Border x:Name="FailureBar" Visibility="Collapsed" Margin="24,16,24,0" Padding="12,8,12,8" BorderThickness="1"
                Background="{DynamicResource FastLlm.CriticalBackgroundBrush}" BorderBrush="{DynamicResource FastLlm.CriticalTextBrush}"
                CornerRadius="{DynamicResource FastLlm.ControlCornerRadius}">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="FailureText" TextWrapping="Wrap" VerticalAlignment="Center" Foreground="{DynamicResource FastLlm.CriticalTextBrush}"
                       AutomationProperties.LiveSetting="Assertive"/>
            <Button x:Name="FailureCopyButton" Grid.Column="1" Margin="12,0,0,0" Style="{DynamicResource FastLlm.LinkButtonStyle}"/>
          </Grid>
        </Border>
      </StackPanel>
      <Border x:Name="PageHost" Grid.Row="1"/>
    </Grid>
  </Grid>
</Window>
'@

# The shell rows of the binding table (the Home rows are in FastLlm.UiFluentHome.ps1). The bars' own visibility is the refresh's, not an adapter's.
function Get-FastLlmUiFluentBindingTable {
    [CmdletBinding()] param()
    $shell = @(
        @{ Name = 'bannerLabel';       Element = 'UpdateText';        Mode = 'TextBlock'; Event = '';            Flags = @() },
        @{ Name = 'bannerNotes';       Element = 'UpdateNotesButton'; Mode = 'Content';   Event = 'LinkClicked'; Flags = @() },
        @{ Name = 'bannerButton';      Element = 'UpdateButton';      Mode = 'Content';   Event = 'Click';       Flags = @() },
        @{ Name = 'reinstallButton';   Element = 'ReinstallButton';   Mode = 'Content';   Event = 'Click';       Flags = @() },
        @{ Name = 'failureCopyLink';   Element = 'FailureCopyButton'; Mode = 'Content';   Event = 'LinkClicked'; Flags = @() }
    )
    return @(@(Get-FastLlmUiFluentHomeBindings) + $shell)
}

# An unsupported-at-initialisation window (the theme or the markup failed) is a fault in FastLLM: the approved text, the run-log reason, exit code 3.
function Stop-FastLlmUiFluentStartup {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Reason)
    Show-FastLlmUiUnsupported -Reason $Reason -InstallRoot $InstallRoot -Folder $script:FastLlmUiFluentSourceRoot
    exit 3
}

# What the system theme says now, as one object plus a key that changes when anything the look depends on changes.
function Get-FastLlmUiFluentThemeState {
    [CmdletBinding()] param()
    $system = Read-FastLlmUiSystemTheme
    $choice = Get-FastLlmUiThemeChoice -AppsUseLightTheme $system.appsUseLightTheme -HighContrast ([bool] $system.highContrast)
    $pair = Get-FastLlmUiAccentPair $system.accentPalette
    $scale = ConvertFrom-FastLlmUiTextScaleFactor $system.textScaleFactor
    $backdrop = Get-FastLlmUiBackdropChoice -Build ([int] $system.build) -TransparencyEnabled $system.enableTransparency -HighContrast ([bool] $system.highContrast)
    return [pscustomobject] @{
        Choice = [string] $choice; Pair = $pair; Scale = [double] $scale; Backdrop = [string] $backdrop
        Key = ([string] $choice + '|' + [string] $pair.lightFill + '|' + [string] $pair.darkFill + '|' + [string] $scale + '|' + [string] $backdrop)
    }
}

# Dark title bar, Mica and the frame extension, or the solid layer. An interop failure only changes the look.
function Set-FastLlmUiFluentWindowLook {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $ThemeState)
    $f = $script:FastLlmUiFluent
    $win = $f.Window
    $mica = $false
    $source = $null
    try {
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
        $source = [System.Windows.Interop.HwndSource]::FromHwnd($hwnd)
        if ($f.Interop -and $hwnd -ne [IntPtr]::Zero) {
            $native = [Bitworks.FastLlm.FluentWindowNative]
            [void] $native::SetDarkTitleBar($hwnd, ([string] $ThemeState.Choice -ceq 'dark'))
            if ([string] $ThemeState.Backdrop -ceq 'mica') {
                $frame = [int] $native::ExtendFrameIntoClientArea($hwnd)
                $backdropResult = [int] $native::SetSystemBackdrop($hwnd, 2)
                $mica = ($frame -eq 0 -and $backdropResult -eq 0)
            }
            if (-not $mica) { [void] $native::SetSystemBackdrop($hwnd, 1) }
        }
    }
    catch { $mica = $false }
    try {
        if ($mica -and $null -ne $source) {
            $source.CompositionTarget.BackgroundColor = [System.Windows.Media.Colors]::Transparent
            $win.Background = [System.Windows.Media.Brushes]::Transparent
        }
        else {
            $win.SetResourceReference([System.Windows.Window]::BackgroundProperty, 'FastLlm.LayerBrush')
            if ($null -ne $source) { $source.CompositionTarget.BackgroundColor = [System.Windows.Media.Colors]::White }
        }
    }
    catch { $null = $_ }
}

# Builds the resource dictionary for a theme state and swaps it into the window; the DynamicResource references follow live.
function Set-FastLlmUiFluentTheme {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $ThemeState)
    $f = $script:FastLlmUiFluent
    $dictionary = New-FastLlmUiThemeDictionary -Theme $ThemeState.Choice -AccentPair $ThemeState.Pair -TextScale $ThemeState.Scale
    $merged = $f.Window.Resources.MergedDictionaries
    $merged.Clear()
    $merged.Add($dictionary)
    $f.Theme = [string] $ThemeState.Choice
    $f.ThemeKey = [string] $ThemeState.Key
    $f.Keys.Dot = $null
}

# Called from the window-message hook, or every 20 ticks when the hook could not be installed.
function Update-FastLlmUiFluentTheme {
    [CmdletBinding()] param()
    $f = $script:FastLlmUiFluent
    $state = Get-FastLlmUiFluentThemeState
    if ([string] $state.Key -ceq [string] $f.ThemeKey) { return }
    Set-FastLlmUiFluentTheme -ThemeState $state
    Set-FastLlmUiFluentWindowLook -ThemeState $state
}

# The navigation pane: expanded below the breakpoints it shows icons and labels; under about 900 epx only icons (the label is then the tooltip).
function Initialize-FastLlmUiFluentPane {
    [CmdletBinding()] param()
    $f = $script:FastLlmUiFluent
    $s = $script:FastLlmUiFluentStrings
    $g = $script:FastLlmUiFluentGlyphs
    [System.Windows.Automation.AutomationProperties]::SetName($f.Els.NavList, [string] $s.NavPane)
    $rows = @(
        @{ List = 'NavList';         Id = 'NavHome';     Label = $s.NavHome;     Glyph = $g.Home;     Enabled = $true },
        @{ List = 'NavList';         Id = 'NavModels';   Label = $s.NavModels;   Glyph = $g.Models;   Enabled = $false },
        @{ List = 'NavList';         Id = 'NavConnect';  Label = $s.NavConnect;  Glyph = $g.Connect;  Enabled = $false },
        @{ List = 'NavList';         Id = 'NavTools';    Label = $s.NavTools;    Glyph = $g.Tools;    Enabled = $false },
        @{ List = 'NavSettingsList'; Id = 'NavSettings'; Label = $s.NavSettings; Glyph = $g.Settings; Enabled = $false }
    )
    $items = New-Object System.Collections.ArrayList
    foreach ($row in $rows) {
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.SetResourceReference([System.Windows.FrameworkElement]::StyleProperty, 'FastLlm.NavItemStyle')
        $panel = New-Object System.Windows.Controls.StackPanel
        $panel.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        $glyph = New-Object System.Windows.Controls.TextBlock
        $glyph.Text = New-FastLlmUiFluentGlyphText $row.Glyph
        $glyph.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe Fluent Icons, Segoe MDL2 Assets')
        $glyph.FontSize = 16
        $glyph.Width = 24
        $glyph.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        [System.Windows.Automation.AutomationProperties]::SetAccessibilityView($glyph, [System.Windows.Automation.Peers.AccessibilityView]::Raw)
        $label = New-Object System.Windows.Controls.TextBlock
        $label.Text = [string] $row.Label
        $label.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0)
        $label.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        [System.Windows.Automation.AutomationProperties]::SetAccessibilityView($label, [System.Windows.Automation.Peers.AccessibilityView]::Raw)
        [void] $panel.Children.Add($glyph)
        [void] $panel.Children.Add($label)
        $item.Content = $panel
        [System.Windows.Automation.AutomationProperties]::SetName($item, [string] $row.Label)
        $item.IsEnabled = [bool] $row.Enabled
        if (-not $row.Enabled) {
            $item.ToolTip = [string] $s.ComingLater
            [System.Windows.Controls.ToolTipService]::SetShowOnDisabled($item, $true)
        }
        [void] $f.Els[$row.List].Items.Add($item)
        [void] $items.Add(@{ Item = $item; Label = $label; Text = [string] $row.Label; Enabled = [bool] $row.Enabled })
    }
    $f.Els.NavHome = $items[0].Item
    $f.Els.NavHome.IsSelected = $true
    $f.NavItems = $items.ToArray()
}

# Expanded or collapsed by the window width; the Home item shows its label as a tooltip only while collapsed.
function Update-FastLlmUiFluentPane {
    [CmdletBinding()] param()
    $f = $script:FastLlmUiFluent
    if ($null -eq $f.Window -or $f.NavItems.Count -eq 0) { return }
    $collapsed = ([double] $f.Window.ActualWidth -lt 900)
    if ($f.Keys.PaneCollapsed -eq $collapsed) { return }
    $f.Keys.PaneCollapsed = $collapsed
    $f.Els.PaneColumn.Width = New-Object System.Windows.GridLength($(if ($collapsed) { 56 } else { 220 }))
    foreach ($nav in $f.NavItems) {
        $nav.Label.Visibility = if ($collapsed) { [System.Windows.Visibility]::Collapsed } else { [System.Windows.Visibility]::Visible }
        if ($nav.Enabled) { $nav.Item.ToolTip = $(if ($collapsed) { [string] $nav.Text } else { $null }) }
    }
}

# The message area: the update or reinstall offer and the held failure. An announcement is raised only when the composed text changes.
function Update-FastLlmUiFluentMessages {
    [CmdletBinding()] param()
    $f = $script:FastLlmUiFluent
    $e = $f.Els
    $keys = $f.Keys
    $offer = ([bool] $script:bannerLabel.Visible -or [bool] $script:reinstallButton.Visible)
    $e.UpdateBar.Visibility = if ($offer) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    # SetUiBanner writes ForeColor Firebrick for an error offer; the adapter stores it, the bar shows it as the critical colours.
    $foreColor = $script:bannerLabel.ForeColor
    $isError = ($null -ne $foreColor -and [string] $foreColor.Name -ceq 'Firebrick')
    if ($keys.BannerError -ne $isError) {
        $keys.BannerError = $isError
        if ($isError) {
            $e.UpdateBar.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'FastLlm.CriticalBackgroundBrush')
            $e.UpdateText.SetResourceReference([System.Windows.Documents.TextElement]::ForegroundProperty, 'FastLlm.CriticalTextBrush')
        }
        else {
            $e.UpdateBar.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'FastLlm.CardBrush')
            $e.UpdateText.SetResourceReference([System.Windows.Documents.TextElement]::ForegroundProperty, 'FastLlm.TextPrimaryBrush')
        }
    }

    $held = [bool] $script:failureHeld
    if ($held) {
        $raw = [string] $script:output.Text
        $failureText = $raw.Trim()
        if ($failureText.Length -gt 400) { $failureText = $failureText.Substring(0, 400) }
        if ($keys.Failure -cne $failureText) {
            $keys.Failure = $failureText
            $e.FailureText.Text = $failureText
            Send-FastLlmUiFluentLiveRegion -Element $e.FailureText
        }
        if ($keys.Held -ne $true) { $e.ActivityExpander.IsExpanded = $true }
        $e.FailureBar.Visibility = [System.Windows.Visibility]::Visible
    }
    else {
        $e.FailureBar.Visibility = [System.Windows.Visibility]::Collapsed
        $keys.Failure = $null
    }
    $keys.Held = $held
}

# One 250 ms refresh. A fault in one part never stops the others and never reaches the message loop; the last one is kept for the lead's logs.
function Invoke-FastLlmUiFluentTick {
    [CmdletBinding()] param()
    $f = $script:FastLlmUiFluent
    $f.Tick = [int] $f.Tick + 1
    try { Update-FastLlmUiFluentHome } catch { $f.TickError = [string] $_.Exception.Message }
    try { Update-FastLlmUiFluentMessages } catch { $f.TickError = [string] $_.Exception.Message }
    try { Update-FastLlmUiFluentPane } catch { $f.TickError = [string] $_.Exception.Message }
    $hooked = ($null -ne $f.Hooks) -and [bool] $f.Hooks['hooked']
    if (-not $hooked -and ([int] $f.Tick % 20) -eq 0) {
        try { Update-FastLlmUiFluentTheme } catch { $f.TickError = [string] $_.Exception.Message }
    }
}

# Shows an exception the way WinForms' default ThreadException would: through ShowFailure, or a message box owned by the window.
function Invoke-FastLlmUiFluentUnhandled {
    [CmdletBinding()]
    param($Exception)
    $f = $script:FastLlmUiFluent
    $f.LastException = $Exception
    if ($f.InUnhandled) { return }
    $f.InUnhandled = $true
    try {
        $message = if ($null -ne $Exception) { [string] $Exception.Message } else { 'An unknown error occurred.' }
        try { ShowFailure $message }
        catch {
            try { [void] [System.Windows.Forms.MessageBox]::Show($script:form, $message, 'FastLLM', 'OK', 'Error') } catch { $null = $_ }
        }
    }
    finally { $f.InUnhandled = $false }
}

function Initialize-FastLlmUiFluentShell {
    [CmdletBinding()] param()
    $f = $script:FastLlmUiFluent
    # Before any WinForms handle exists, if that is still possible: the dispatcher and ThreadException handlers decide what an exception shows.
    try { [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException) } catch { $null = $_ }

    $classicForm = $script:form
    $windowTitle = [string] $classicForm.Text

    try { $f.Interop = [bool] (Initialize-FastLlmUiWindowInterop -SourceRoot $script:FastLlmUiFluentSourceRoot) } catch { $f.Interop = $false }

    $themeState = $null
    try { $themeState = Get-FastLlmUiFluentThemeState } catch { Stop-FastLlmUiFluentStartup -Reason 'theme-init' }
    $win = $null
    $page = $null
    try {
        $win = New-FastLlmUiXamlElement -Name 'FastLlm.Shell'
        $page = New-FastLlmUiXamlElement -Name 'FastLlm.Home'
    }
    catch { Stop-FastLlmUiFluentStartup -Reason 'xaml-parse' }
    $f.Window = $win
    try { Set-FastLlmUiFluentTheme -ThemeState $themeState } catch { Stop-FastLlmUiFluentStartup -Reason 'theme-init' }

    # Everything that locks once the handle exists comes first: New-FastLlmUiFormAdapter calls EnsureHandle().
    $size = $script:FastLlmUiFluentWindowSize
    $win.Title = $windowTitle
    $win.Width = [double] $size.Width
    $win.Height = [double] $size.Height
    $win.MinWidth = [double] $size.MinWidth
    $win.MinHeight = [double] $size.MinHeight
    $win.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterScreen
    try {
        $accent = if ([string] $themeState.Choice -ceq 'dark') { [string] $themeState.Pair.darkFill } else { [string] $themeState.Pair.lightFill }
        $win.Icon = New-FastLlmUiAppIconImage -AccentArgb $accent
    }
    catch { $null = $_ }

    # The named elements of the shell and of Home, the Home static text and the split button, then the adapters.
    foreach ($name in 'PaneColumn', 'NavList', 'NavSettingsList', 'UpdateBar', 'UpdateText', 'UpdateNotesButton', 'UpdateButton', 'ReinstallButton',
        'FailureBar', 'FailureText', 'FailureCopyButton', 'PageHost') {
        $f.Els[$name] = Get-FastLlmUiFluentElement -Root $win -Name $name
    }
    [void] (Initialize-FastLlmUiFluentHome -Page $page -Els $f.Els)
    $f.Els.PageHost.Child = $page
    Initialize-FastLlmUiFluentPane

    $null = Initialize-FastLlmUiFluentBindings -InstallRoot $InstallRoot -Catalog $catalog -UiSettings $script:uiSettings
    foreach ($row in (Get-FastLlmUiFluentBindingTable)) {
        $adapter = Get-Variable -Name ([string]$row.Name) -Scope Script -ValueOnly
        Connect-FastLlmUiFluentControl -Adapter $adapter -Element $f.Els[[string]$row.Element] -Mode ([string]$row.Mode) -Event ([string]$row.Event) -Flags @($row.Flags)
    }
    # Home's TrayButton, the failure link and the quick actions keep the adapter caption; the failure link names itself as the classic one does.
    [System.Windows.Automation.AutomationProperties]::SetName($f.Els.FailureCopyButton, [string] $script:failureCopyLink.Text)

    # The form adapter takes over the window's handle; from here the orchestration's $form is the adapter (owner of every dialog and message box).
    $formAdapter = New-FastLlmUiFormAdapter -Window $win
    Set-Variable -Name form -Scope Script -Value $formAdapter
    try { $classicForm.Dispose() } catch { $null = $_ }

    Set-FastLlmUiFluentWindowLook -ThemeState $themeState
    $f.Hooks = Register-FastLlmUiWindowHooks -Window $win -Form $formAdapter -OnThemeChanged { Update-FastLlmUiFluentTheme }
    $win.Add_SizeChanged({ try { Update-FastLlmUiFluentPane } catch { $null = $_ } })

    $uiTimer = New-Object System.Windows.Threading.DispatcherTimer
    $uiTimer.Interval = [TimeSpan]::FromMilliseconds(250)
    $uiTimer.Add_Tick({ Invoke-FastLlmUiFluentTick })
    $f.Timer = $uiTimer
    # The first paint of the card, so the window never opens showing the empty markup.
    Invoke-FastLlmUiFluentTick
}

# The message loop. On Closed: the window hooks, the tray icon and the dispatcher go; the seam's finally disposes the rest.
function Start-FastLlmUiFluentLoop {
    [CmdletBinding()] param()
    $f = $script:FastLlmUiFluent
    $win = $f.Window
    # Every exception on the dispatcher is recorded and shown, then marked handled: a handler's fault never ends the app.
    $win.Dispatcher.add_UnhandledException({
            param($sender, $unhandled)
            try { Invoke-FastLlmUiFluentUnhandled -Exception $unhandled.Exception } catch { $null = $_ }
            $unhandled.Handled = $true
        })
    # WinForms callbacks (the timer, the tray icon and its menu) reach this instead.
    try {
        [System.Windows.Forms.Application]::add_ThreadException({
                param($sender, $threadArgs)
                try { Invoke-FastLlmUiFluentUnhandled -Exception $threadArgs.Exception } catch { $null = $_ }
            })
    }
    catch { $null = $_ }
    $win.Add_Closed({
            $state = $script:FastLlmUiFluent
            try { $state.Timer.Stop() } catch { $null = $_ }
            try { Unregister-FastLlmUiWindowHooks -Window $state.Window } catch { $null = $_ }
            try { Clear-FastLlmUiFluentTrayIcon } catch { $null = $_ }
            [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
        })
    $f.Timer.Start()
    $win.Show()
    [System.Windows.Threading.Dispatcher]::Run()
}
