#requires -Version 5.1
# The Fluent window shell: the window, the navigation pane, the message area, the theme, the 250 ms refresh and the message loop.
# Dot-sourced by fast-llm-ui.ps1 only with -Window fluent, right after the existing dot-sources. The seam calls Test-FastLlmUiFluentHost
# (FastLlm.UiFluentSupport.ps1), then Initialize-FastLlmUiFluentShell right after the control-creation block, then Start-FastLlmUiFluentLoop.
# No WPF or WinForms type is resolved at dot-source time, only inside function bodies. The new fluent-only strings are in
# FastLlm.UiFluentHome.ps1 ($script:FastLlmUiFluentStrings); today's captions come only from the adapters.
# FIRST: the accessibility switches, before any other statement or dot-source here (WPF caches them on first read; the support file touches no WPF type).
. (Join-Path $PSScriptRoot 'FastLlm.UiFluentSupport.ps1')
Set-FastLlmUiFluentAccessibilitySwitches
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'FastLlm.UiFluentAdapter.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.UiFluentForm.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.UiFluentBindings.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.UiTheme.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.UiWindow.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.UiXaml.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.UiFluentIcon.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.UiFluentHooks.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.UiFluentHome.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.UiFluentTools.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.UiFluentConnect.ps1')

$script:FastLlmUiFluentSourceRoot = Split-Path -Parent $PSScriptRoot
# State shared by the handlers: they are not closures, so nothing lives in a function's locals. Els: every named element; Keys: last-applied values.
$script:FastLlmUiFluent = @{ Window = $null; Els = @{}; Keys = @{}; Timer = $null; Tick = 0; Theme = ''; ThemeKey = ''; Interop = $false; Hooks = $null
    NavItems = @(); LastException = $null; InUnhandled = $false; TickError = ''; Pages = @{}; Current = '' }

# Window size in epx (spec 6.5). Set BEFORE the form adapter exists: creating it calls EnsureHandle(), after which some properties lock.
$script:FastLlmUiFluentWindowSize = @{ Width = 1000; Height = 680; MinWidth = 640; MinHeight = 480 }

$script:FastLlmUiXaml['FastLlm.Shell'] = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        UseLayoutRounding="True" SnapsToDevicePixels="True"
        FontFamily="{DynamicResource FastLlm.TextFont}" FontSize="{DynamicResource FastLlm.BodySize}"
        Foreground="{DynamicResource FastLlm.TextPrimaryBrush}" Background="{DynamicResource FastLlm.LayerBrush}">
  <Window.Resources>
    <Style x:Key="FastLlm.FocusVisual">
      <Setter Property="Control.Template">
        <Setter.Value>
          <ControlTemplate>
            <Rectangle Margin="-3" StrokeThickness="2" RadiusX="4" RadiusY="4" SnapsToDevicePixels="True" Stroke="{DynamicResource FastLlm.FocusBrush}"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="FastLlm.ButtonStyle" TargetType="Button">
      <Setter Property="FocusVisualStyle" Value="{DynamicResource FastLlm.FocusVisual}"/>
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
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Foreground" Value="{DynamicResource FastLlm.DisabledTextBrush}"/>
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource FastLlm.DisabledFillBrush}"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource FastLlm.DisabledStrokeBrush}"/>
              </Trigger>
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
      <Setter Property="FocusVisualStyle" Value="{DynamicResource FastLlm.FocusVisual}"/>
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
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="{DynamicResource FastLlm.DisabledTextBrush}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="FastLlm.ExpanderStyle" TargetType="Expander">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Expander">
            <DockPanel>
              <Grid DockPanel.Dock="Top">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
              <ToggleButton x:Name="Hd" Grid.Column="0" Content="{TemplateBinding Header}" Foreground="{TemplateBinding Foreground}"
                            IsChecked="{Binding IsExpanded, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"
                            FocusVisualStyle="{DynamicResource FastLlm.FocusVisual}" Background="Transparent" Padding="4,6,4,6" HorizontalContentAlignment="Left">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
                      <StackPanel Orientation="Horizontal">
                        <TextBlock x:Name="Arrow" Text="&#xE70D;" FontFamily="{DynamicResource FastLlm.IconFont}" FontSize="12" Margin="0,0,8,0" VerticalAlignment="Center"/>
                        <ContentPresenter VerticalAlignment="Center"/>
                      </StackPanel>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsChecked" Value="True"><Setter TargetName="Arrow" Property="Text" Value="&#xE70E;"/></Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter x:Name="TagHost" Grid.Column="1" Content="{TemplateBinding Tag}" VerticalAlignment="Center" Margin="8,0,0,0"/>
              </Grid>
              <ContentPresenter x:Name="Body" Visibility="Collapsed"/>
            </DockPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsExpanded" Value="True"><Setter TargetName="Body" Property="Visibility" Value="Visible"/></Trigger>
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
      <Setter Property="FocusVisualStyle" Value="{DynamicResource FastLlm.FocusVisual}"/>
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
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="{DynamicResource FastLlm.DisabledTextBrush}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="FastLlm.TextBoxStyle" TargetType="TextBox">
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Foreground" Value="{DynamicResource FastLlm.TextPrimaryBrush}"/>
      <Setter Property="Background" Value="{DynamicResource FastLlm.CardBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource FastLlm.ControlStrongStrokeBrush}"/>
      <Setter Property="CaretBrush" Value="{DynamicResource FastLlm.TextPrimaryBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="8,5,8,5"/>
      <Setter Property="MinHeight" Value="{DynamicResource FastLlm.ControlHeight}"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Grid>
              <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                      BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4"/>
              <Border x:Name="Ring" BorderBrush="{DynamicResource FastLlm.FocusBrush}" BorderThickness="2" CornerRadius="4" Visibility="Collapsed" IsHitTestVisible="False"/>
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center" Focusable="False"
                            HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Hidden"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Ring" Property="Visibility" Value="Visible"/></Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Foreground" Value="{DynamicResource FastLlm.DisabledTextBrush}"/>
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource FastLlm.DisabledFillBrush}"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource FastLlm.DisabledStrokeBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="FastLlm.ComboBoxItemStyle" TargetType="ComboBoxItem">
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Foreground" Value="{DynamicResource FastLlm.TextPrimaryBrush}"/>
      <Setter Property="Padding" Value="8,5,8,5"/>
      <Setter Property="MinHeight" Value="{DynamicResource FastLlm.ControlHeight}"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="Bd" Background="Transparent" BorderBrush="Transparent" BorderThickness="2" CornerRadius="4">
              <ContentPresenter Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource FastLlm.ControlStrokeBrush}"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource FastLlm.FocusBrush}"/></Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter Property="Foreground" Value="{DynamicResource FastLlm.TextOnAccentBrush}"/>
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource FastLlm.AccentFillBrush}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="{DynamicResource FastLlm.DisabledTextBrush}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="FastLlm.ComboBoxStyle" TargetType="ComboBox">
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Foreground" Value="{DynamicResource FastLlm.TextPrimaryBrush}"/>
      <Setter Property="Background" Value="{DynamicResource FastLlm.CardBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource FastLlm.ControlStrongStrokeBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="8,5,32,5"/>
      <Setter Property="MinHeight" Value="{DynamicResource FastLlm.ControlHeight}"/>
      <Setter Property="ItemContainerStyle" Value="{StaticResource FastLlm.ComboBoxItemStyle}"/>
      <Setter Property="ScrollViewer.CanContentScroll" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                      BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4"/>
              <ContentPresenter Margin="{TemplateBinding Padding}" VerticalAlignment="Center" HorizontalAlignment="Left" IsHitTestVisible="False"
                                Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                ContentStringFormat="{TemplateBinding SelectionBoxItemStringFormat}"/>
              <TextBlock Text="&#xE70D;" FontFamily="{DynamicResource FastLlm.IconFont}" FontSize="12" Margin="0,0,10,0" HorizontalAlignment="Right"
                         VerticalAlignment="Center" IsHitTestVisible="False"/>
              <ToggleButton ClickMode="Press" Focusable="False" Background="Transparent" Opacity="0.01"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"/>
              <Border x:Name="Ring" BorderBrush="{DynamicResource FastLlm.FocusBrush}" BorderThickness="2" CornerRadius="4" Visibility="Collapsed" IsHitTestVisible="False"/>
              <Popup x:Name="PART_Popup" Placement="Bottom" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade"
                     IsOpen="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <Border Background="{DynamicResource FastLlm.CardBrush}" BorderBrush="{DynamicResource FastLlm.ControlStrongStrokeBrush}" BorderThickness="1" CornerRadius="4" Margin="0,2,0,0"
                        MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}" MaxHeight="{TemplateBinding MaxDropDownHeight}">
                  <ScrollViewer CanContentScroll="True" Padding="2">
                    <ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained" SnapsToDevicePixels="{TemplateBinding SnapsToDevicePixels}"/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocusWithin" Value="True"><Setter TargetName="Ring" Property="Visibility" Value="Visible"/></Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Foreground" Value="{DynamicResource FastLlm.DisabledTextBrush}"/>
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource FastLlm.DisabledFillBrush}"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource FastLlm.DisabledStrokeBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="FastLlm.SpinButtonStyle" TargetType="RepeatButton">
      <Setter Property="IsTabStop" Value="False"/>
      <Setter Property="FocusVisualStyle" Value="{DynamicResource FastLlm.FocusVisual}"/>
      <Setter Property="FontFamily" Value="{DynamicResource FastLlm.IconFont}"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="Foreground" Value="{DynamicResource FastLlm.TextPrimaryBrush}"/>
      <Setter Property="Background" Value="{DynamicResource FastLlm.CardBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource FastLlm.ControlStrokeBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="MinWidth" Value="24"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RepeatButton">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="{DynamicResource FastLlm.ControlCornerRadius}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.7"/></Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Foreground" Value="{DynamicResource FastLlm.DisabledTextBrush}"/>
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource FastLlm.DisabledFillBrush}"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource FastLlm.DisabledStrokeBrush}"/>
              </Trigger>
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
    <Grid Grid.Column="0" Margin="0,12,0,12">
      <Grid.RowDefinitions>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <ListBox x:Name="NavList" Grid.Row="0" Background="Transparent" BorderThickness="0" KeyboardNavigation.TabNavigation="Once" FocusVisualStyle="{DynamicResource FastLlm.FocusVisual}"
               ScrollViewer.HorizontalScrollBarVisibility="Disabled" ScrollViewer.VerticalScrollBarVisibility="Auto"/>
      <ListBox x:Name="NavSettingsList" Grid.Row="1" Background="Transparent" BorderThickness="0" KeyboardNavigation.TabNavigation="None" IsTabStop="False" FocusVisualStyle="{DynamicResource FastLlm.FocusVisual}"
               ScrollViewer.HorizontalScrollBarVisibility="Disabled" ScrollViewer.VerticalScrollBarVisibility="Disabled"/>
    </Grid>
    <Grid Grid.Column="1">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <ScrollViewer x:Name="MessageScroll" Grid.Row="0" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Focusable="False">
      <StackPanel>
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
      </ScrollViewer>
      <Border x:Name="PageHost" Grid.Row="1"/>
    </Grid>
  </Grid>
</Window>
'@

# The shell rows of the binding table (the Home rows are in FastLlm.UiFluentHome.ps1). The bars' own visibility is the refresh's, not an adapter's.
# The table order is pinned: Home, then the shell, then the pages. A row with Also = $true joins an adapter that is already bound (a second element
# on one adapter); a row without it on a bound adapter throws, so a reordered table fails loudly.
function Get-FastLlmUiFluentBindingTable {
    [CmdletBinding()] param()
    $shell = @(
        @{ Name = 'bannerLabel';       Element = 'UpdateText';        Mode = 'TextBlock'; Event = '';            Flags = @() },
        @{ Name = 'bannerNotes';       Element = 'UpdateNotesButton'; Mode = 'Content';   Event = 'LinkClicked'; Flags = @() },
        @{ Name = 'bannerButton';      Element = 'UpdateButton';      Mode = 'Content';   Event = 'Click';       Flags = @() },
        @{ Name = 'reinstallButton';   Element = 'ReinstallButton';   Mode = 'Content';   Event = 'Click';       Flags = @() },
        @{ Name = 'failureCopyLink';   Element = 'FailureCopyButton'; Mode = 'Content';   Event = 'LinkClicked'; Flags = @() },
        @{ Name = 'failureCopyLink';   Element = 'ActivityCopyButton'; Mode = 'Content';  Event = 'LinkClicked'; Flags = @(); Also = $true }
    )
    return @(@(Get-FastLlmUiFluentHomeBindings) + $shell + @(Get-FastLlmUiFluentToolsBindings))
}

# An unsupported-at-initialisation window (the theme or the markup failed) is a fault in FastLLM: the approved text, the run-log reason, exit code 3.
function Stop-FastLlmUiFluentStartup {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Reason)
    Show-FastLlmUiUnsupported -Reason $Reason -InstallRoot $InstallRoot -Folder $script:FastLlmUiFluentSourceRoot
    exit 3
}

# Compiles the decorative text type once, after WPF is loaded. References are given by assembly path (names do not resolve on pwsh 7).
function Initialize-FastLlmUiFluentAutomation {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $SourceRoot)
    if ('Bitworks.FastLlm.DecorativeTextBlock' -as [type]) { return }
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
    $refs = @(
        [System.Windows.Controls.TextBlock].Assembly.Location,
        [System.Windows.UIElement].Assembly.Location,
        [System.Windows.DependencyObject].Assembly.Location,
        [System.Xaml.XamlSchemaContext].Assembly.Location
    )
    Add-Type -Path (Join-Path $SourceRoot 'src/WindowsFluentAutomation.cs') -ReferencedAssemblies $refs -WarningAction SilentlyContinue -ErrorAction Stop
}

# What the system theme says now, as one object plus a key that changes when anything the look depends on changes.
function Get-FastLlmUiFluentThemeState {
    [CmdletBinding()] param()
    $system = Read-FastLlmUiSystemTheme
    $choice = Get-FastLlmUiThemeChoice -AppsUseLightTheme $system.appsUseLightTheme -HighContrast ([bool] $system.highContrast)
    $pair = Get-FastLlmUiAccentPair $system.accentPalette
    $scale = ConvertFrom-FastLlmUiTextScaleFactor $system.textScaleFactor
    $backdrop = Get-FastLlmUiBackdropChoice -Build ([int] $system.build) -TransparencyEnabled $system.enableTransparency -HighContrast ([bool] $system.highContrast)
    # A switch between two high-contrast palettes changes only the system colours, so they are part of the key.
    $hcKey = ''
    if ([string] $choice -ceq 'high-contrast') {
        $sc = [System.Windows.SystemColors]
        $hcKey = '|' + (@($sc::WindowColor, $sc::WindowTextColor, $sc::HighlightColor, $sc::HighlightTextColor, $sc::GrayTextColor, $sc::HotTrackColor) -join ',')
    }
    return [pscustomobject] @{
        Choice = [string] $choice; Pair = $pair; Scale = [double] $scale; Backdrop = [string] $backdrop
        Key = ([string] $choice + '|' + [string] $pair.lightFill + '|' + [string] $pair.darkFill + '|' + [string] $scale + '|' + [string] $backdrop + $hcKey)
    }
}

# Dark title bar, Mica and the frame extension, or the solid layer. An interop failure only changes the look.
function Set-FastLlmUiFluentWindowLook {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $ThemeState)
    $f = $script:FastLlmUiFluent
    $win = $f['Window']
    $mica = $false
    $source = $null
    try {
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
        $source = [System.Windows.Interop.HwndSource]::FromHwnd($hwnd)
        if ($f['Interop'] -and $hwnd -ne [IntPtr]::Zero) {
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
            # The theme's layer colour (the system Window colour in high contrast, where the layer is that brush).
            $layer = $win.TryFindResource('FastLlm.LayerBrush')
            if ($null -ne $source -and $layer -is [System.Windows.Media.SolidColorBrush]) { $source.CompositionTarget.BackgroundColor = $layer.Color }
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
    # The focus ring and the disabled text: accent and secondary text, or the system Highlight and GrayText colours in high contrast.
    if ([string] $ThemeState.Choice -ceq 'high-contrast') {
        Set-FastLlmUiResourceValue -Dictionary $dictionary -Key 'FastLlm.FocusBrush' -Value ([System.Windows.SystemColors]::HighlightBrush)
        Set-FastLlmUiResourceValue -Dictionary $dictionary -Key 'FastLlm.DisabledTextBrush' -Value ([System.Windows.SystemColors]::GrayTextBrush)
        Set-FastLlmUiResourceValue -Dictionary $dictionary -Key 'FastLlm.DisabledFillBrush' -Value ([System.Windows.SystemColors]::ControlBrush)
        Set-FastLlmUiResourceValue -Dictionary $dictionary -Key 'FastLlm.DisabledStrokeBrush' -Value ([System.Windows.SystemColors]::GrayTextBrush)
    }
    else {
        Set-FastLlmUiResourceValue -Dictionary $dictionary -Key 'FastLlm.FocusBrush' -Value $dictionary['FastLlm.AccentFillBrush']
        Set-FastLlmUiResourceValue -Dictionary $dictionary -Key 'FastLlm.DisabledTextBrush' -Value $dictionary['FastLlm.TextSecondaryBrush']
        Set-FastLlmUiResourceValue -Dictionary $dictionary -Key 'FastLlm.DisabledFillBrush' -Value $dictionary['FastLlm.CardBrush']
        Set-FastLlmUiResourceValue -Dictionary $dictionary -Key 'FastLlm.DisabledStrokeBrush' -Value $dictionary['FastLlm.ControlStrokeBrush']
    }
    $merged = $f['Window'].Resources.MergedDictionaries
    $merged.Clear()
    $merged.Add($dictionary)
    $f['Theme'] = [string] $ThemeState.Choice
    $f['ThemeKey'] = [string] $ThemeState.Key
    $f['Keys']['Dot'] = $null
}

# Called from the window-message hook (a start without the hook is refused, so there is no polling fallback).
function Update-FastLlmUiFluentTheme {
    [CmdletBinding()] param()
    $f = $script:FastLlmUiFluent
    $state = Get-FastLlmUiFluentThemeState
    if ([string] $state.Key -ceq [string] $f['ThemeKey']) { return }
    Set-FastLlmUiFluentTheme -ThemeState $state
    Set-FastLlmUiFluentWindowLook -ThemeState $state
}

# The page registry ($f['Pages']): page id -> @{Element; Nav; Status; Enter; Leave; Update; KeepsText}. Element is the page root, Nav the id of its pane item,
# Status the page's status TextBlock, and Enter/Leave/Update function names called with &. A page is enabled in the pane exactly when it is registered.
function Register-FastLlmUiFluentPage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Id,
        [Parameter(Mandatory = $true)] $Element,
        [Parameter(Mandatory = $true)][string] $Nav,
        [Parameter(Mandatory = $true)] $Status,
        [string] $Enter = '',
        [string] $Leave = '',
        [string] $Update = '',
        [switch] $StatusKeepsText
    )
    $f = $script:FastLlmUiFluent
    if ($null -eq $f['Pages']) { $f['Pages'] = @{} }
    # The status line is a polite live region on every page; a page without that would announce nothing (or too much), so it is refused.
    if ([System.Windows.Automation.AutomationProperties]::GetLiveSetting($Status) -ne [System.Windows.Automation.AutomationLiveSetting]::Polite) {
        throw ("The status line of page '" + $Id + "' must have AutomationProperties.LiveSetting Polite.")
    }
    $f['Pages'][$Id] = @{ Element = $Element; Nav = $Nav; Status = $Status; Enter = $Enter; Leave = $Leave; Update = $Update; KeepsText = [bool] $StatusKeepsText }
    # A page registered after the first composed line is seeded with it, so it never shows an empty status line.
    $seed = $f['Keys']['Composed']
    if ($null -ne $seed) {
        if (-not [bool] $StatusKeepsText -and $Status.Text -cne [string] $seed) { $Status.Text = [string] $seed }
        [System.Windows.Automation.AutomationProperties]::SetName($Status, [string] $seed)
    }
    # A page that registers after the pane was built (a test-only page, or a late page) enables its item now.
    foreach ($nav in @($f['NavItems'])) {
        if ([string] $nav['Id'] -ceq $Nav -and -not [bool] $nav['Enabled']) {
            $nav['Enabled'] = $true
            $nav['Item'].IsEnabled = $true
            Set-FastLlmUiFluentNavTip -Nav $nav
        }
    }
}

function Test-FastLlmUiFluentPageRegistered {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Id)
    $pages = $script:FastLlmUiFluent['Pages']
    return ($null -ne $pages -and $pages.ContainsKey($Id))
}

function Get-FastLlmUiFluentCurrentPage {
    [CmdletBinding()] param()
    $current = $script:FastLlmUiFluent['Current']
    if ($null -eq $current) { return '' }
    return [string] $current
}

# The id of the registered page whose pane item is $NavId, or '' when none is registered for it.
function Get-FastLlmUiFluentPageIdByNav {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $NavId)
    $pages = $script:FastLlmUiFluent['Pages']
    if ($null -eq $pages) { return '' }
    foreach ($id in @($pages.Keys)) { if ([string] $pages[$id]['Nav'] -ceq $NavId) { return [string] $id } }
    return ''
}

# Adds named elements found under $Root to the one flat Els map. A duplicate name throws, so pages prefix their names.
function Add-FastLlmUiFluentElements {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable] $Els, [Parameter(Mandatory = $true)] $Root, [Parameter(Mandatory = $true)][string[]] $Names)
    foreach ($name in $Names) {
        if ($Els.ContainsKey($name)) { throw ("The Fluent window already has an element named '" + $name + "'.") }
        $Els[$name] = Get-FastLlmUiFluentElement -Root $Root -Name $name
    }
}

# Hosts a page: leaves the current one (its Leave may refuse), shows the page, selects its pane item, runs Enter. Returns exactly one [bool]:
# $true when the page is now current, $false when the id is not registered or the current page refused to be left.
function Set-FastLlmUiFluentPage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Id, [switch] $FocusNav)
    $f = $script:FastLlmUiFluent
    $pages = $f['Pages']
    if ($null -eq $pages -or -not $pages.ContainsKey($Id)) { return $false }
    $current = Get-FastLlmUiFluentCurrentPage
    if ($current -ceq $Id) { return $true }
    if ($pages.ContainsKey($current) -and [string] $pages[$current]['Leave'] -ne '') {
        $leaveName = [string] $pages[$current]['Leave']
        foreach ($answer in @(& $leaveName)) { if ($answer -is [bool] -and -not $answer) { return $false } }
    }
    $page = $pages[$Id]
    $f['Current'] = $Id
    $pageHost = $f['Els']['PageHost']
    $pageHost.Child = $null
    $pageHost.Child = $page['Element']
    $item = $null
    foreach ($nav in @($f['NavItems'])) { if ([string] $nav['Id'] -ceq [string] $page['Nav']) { $item = $nav['Item'] } }
    if ($null -ne $item) {
        # Selecting the item raises the NavList handler, which must not navigate again.
        $keys = $f['Keys']
        $previous = [bool] $keys['NavGuard']
        $keys['NavGuard'] = $true
        try { $item.IsSelected = $true } finally { $keys['NavGuard'] = $previous }
    }
    if ([string] $page['Enter'] -ne '') { $enterName = [string] $page['Enter']; $null = & $enterName }
    if ($FocusNav -and $null -ne $item) { $null = $item.Focus() }
    return $true
}

# The NavList SelectionChanged handler. A registered item navigates; a null selection, an item with no page or a refused Leave puts the selection
# back on the current page's item. NavGuard stops the re-selection from running this again.
function Invoke-FastLlmUiFluentNavSelection {
    [CmdletBinding()] param()
    $f = $script:FastLlmUiFluent
    $keys = $f['Keys']
    if ([bool] $keys['NavGuard']) { return }
    $keys['NavGuard'] = $true
    try {
        $selected = $f['Els']['NavList'].SelectedItem
        $target = ''
        if ($null -ne $selected) {
            foreach ($nav in @($f['NavItems'])) {
                if ([object]::ReferenceEquals($nav['Item'], $selected)) { $target = Get-FastLlmUiFluentPageIdByNav -NavId ([string] $nav['Id']) }
            }
        }
        $moved = $false
        if ($target -ne '') {
            # Set-FastLlmUiFluentPage sets the guard again around its own selection and restores it.
            $moved = [bool] (Set-FastLlmUiFluentPage -Id $target)
        }
        if (-not $moved) {
            $current = Get-FastLlmUiFluentCurrentPage
            if ($current -ne '' -and $f['Pages'].ContainsKey($current)) {
                foreach ($nav in @($f['NavItems'])) {
                    if ([string] $nav['Id'] -ceq [string] $f['Pages'][$current]['Nav']) { $nav['Item'].IsSelected = $true }
                }
            }
        }
    }
    finally { $keys['NavGuard'] = $false }
}

# The tooltip and help text of one pane item: enabled items show their label as a tooltip only while collapsed; a disabled item says it is coming.
function Set-FastLlmUiFluentNavTip {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable] $Nav)
    $s = $script:FastLlmUiFluentStrings
    $collapsed = [bool] $script:FastLlmUiFluent['Keys']['PaneCollapsed']
    $item = $Nav['Item']
    if ([bool] $Nav['Enabled']) {
        $item.ToolTip = $(if ($collapsed) { [string] $Nav['Text'] } else { $null })
        [System.Windows.Automation.AutomationProperties]::SetHelpText($item, '')
    }
    else {
        $item.ToolTip = $(if ($collapsed) { ([string] $s.ComingLaterFormat) -f [string] $Nav['Text'] } else { [string] $s.ComingLater })
        [System.Windows.Automation.AutomationProperties]::SetHelpText($item, [string] $s.ComingLater)
        [System.Windows.Controls.ToolTipService]::SetShowOnDisabled($item, $true)
    }
}

# The navigation pane: expanded below the breakpoints it shows icons and labels; under about 900 epx only icons (the label is then the tooltip).
# An item is enabled exactly when a page is registered for it (pages register before the pane is built).
function Initialize-FastLlmUiFluentPane {
    [CmdletBinding()] param()
    $f = $script:FastLlmUiFluent
    $s = $script:FastLlmUiFluentStrings
    $g = $script:FastLlmUiFluentGlyphs
    [System.Windows.Automation.AutomationProperties]::SetName($f['Els']['NavList'], [string] $s.NavPane)
    $rows = @(
        @{ List = 'NavList';         Id = 'NavHome';     Label = $s.NavHome;     Glyph = $g.Home },
        @{ List = 'NavList';         Id = 'NavModels';   Label = $s.NavModels;   Glyph = $g.Models },
        @{ List = 'NavList';         Id = 'NavConnect';  Label = $s.NavConnect;  Glyph = $g.Connect },
        @{ List = 'NavList';         Id = 'NavTools';    Label = $s.NavTools;    Glyph = $g.Tools },
        @{ List = 'NavSettingsList'; Id = 'NavSettings'; Label = $s.NavSettings; Glyph = $g.Settings }
    )
    $items = New-Object System.Collections.ArrayList
    foreach ($row in $rows) {
        $enabled = ((Get-FastLlmUiFluentPageIdByNav -NavId ([string] $row.Id)) -ne '')
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.SetResourceReference([System.Windows.FrameworkElement]::StyleProperty, 'FastLlm.NavItemStyle')
        $panel = New-Object System.Windows.Controls.StackPanel
        $panel.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        $glyph = New-Object Bitworks.FastLlm.DecorativeTextBlock
        $glyph.Text = New-FastLlmUiFluentGlyphText $row.Glyph
        $glyph.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe Fluent Icons, Segoe MDL2 Assets')
        $glyph.FontSize = 16
        $glyph.Width = 24
        $glyph.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $label = New-Object Bitworks.FastLlm.DecorativeTextBlock
        $label.Text = [string] $row.Label
        $label.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0)
        $label.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        [void] $panel.Children.Add($glyph)
        [void] $panel.Children.Add($label)
        $item.Content = $panel
        [System.Windows.Automation.AutomationProperties]::SetName($item, [string] $row.Label)
        $item.IsEnabled = $enabled
        $nav = @{ Item = $item; Label = $label; Text = [string] $row.Label; Enabled = $enabled; Id = [string] $row.Id }
        Set-FastLlmUiFluentNavTip -Nav $nav
        [void] $f['Els'][$row.List].Items.Add($item)
        [void] $items.Add($nav)
    }
    $f['Els']['NavHome'] = $items[0].Item
    $f['Els']['NavConnect'] = $items[2].Item
    $f['Els']['NavTools'] = $items[3].Item
    # The Settings list has one item, disabled for now: it is named so it is never an anonymous list. Home stays selected (Ctrl+Click cannot empty it).
    [System.Windows.Automation.AutomationProperties]::SetName($f['Els']['NavSettingsList'], [string] $s.NavSettings)
    $f['NavItems'] = $items.ToArray()
    if ((Get-FastLlmUiFluentCurrentPage) -ceq '') { $f['Current'] = 'Home' }
    $keys = $f['Keys']
    $keys['NavGuard'] = $true
    try { $f['Els']['NavHome'].IsSelected = $true } finally { $keys['NavGuard'] = $false }
    $f['Els']['NavList'].Add_SelectionChanged({ Invoke-FastLlmUiFluentNavSelection })
}

# Expanded or collapsed by the window width; an enabled item shows its label as a tooltip only while collapsed, a disabled one says it is coming.
function Update-FastLlmUiFluentPane {
    [CmdletBinding()] param()
    $f = $script:FastLlmUiFluent
    if ($null -eq $f['Window'] -or $null -eq $f['NavItems'] -or @($f['NavItems']).Count -eq 0) { return }
    # The message area (update offer, failure) never takes more than about 40 percent of the window; it scrolls inside that.
    if ([double] $f['Window'].ActualHeight -gt 0) { $f['Els']['MessageScroll'].MaxHeight = [double] $f['Window'].ActualHeight * 0.4 }
    $collapsed = ([double] $f['Window'].ActualWidth -lt 900)
    if ($f['Keys']['PaneCollapsed'] -eq $collapsed) { return }
    $f['Keys']['PaneCollapsed'] = $collapsed
    $f['Els']['PaneColumn'].Width = New-Object System.Windows.GridLength($(if ($collapsed) { 64 } else { 220 }))
    foreach ($nav in $f['NavItems']) {
        $nav['Label'].Visibility = if ($collapsed) { [System.Windows.Visibility]::Collapsed } else { [System.Windows.Visibility]::Visible }
        Set-FastLlmUiFluentNavTip -Nav $nav
    }
}

# Writes the card's composed status line to every registered page and announces it only on the current page (a page swap raises nothing).
function Update-FastLlmUiFluentPageStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Composed, [bool] $Announce = $false)
    $f = $script:FastLlmUiFluent
    $pages = $f['Pages']
    if ($null -eq $pages) { return }
    foreach ($id in @($pages.Keys)) {
        $page = $pages[$id]
        $status = $page['Status']
        if ($null -eq $status) { continue }
        if (-not [bool] $page['KeepsText'] -and $status.Text -cne $Composed) { $status.Text = $Composed }
        [System.Windows.Automation.AutomationProperties]::SetName($status, $Composed)
    }
    $current = Get-FastLlmUiFluentCurrentPage
    if ($Announce -and $current -ne '' -and $pages.ContainsKey($current) -and $null -ne $pages[$current]['Status']) {
        Send-FastLlmUiFluentLiveRegion -Element $pages[$current]['Status']
    }
}

# The current page's Update hook, once per tick.
function Update-FastLlmUiFluentPages {
    [CmdletBinding()] param()
    $f = $script:FastLlmUiFluent
    $current = Get-FastLlmUiFluentCurrentPage
    if ($current -eq '' -or $null -eq $f['Pages'] -or -not $f['Pages'].ContainsKey($current)) { return }
    $hook = [string] $f['Pages'][$current]['Update']
    if ($hook -ne '') { $null = & $hook }
}

# The message area: the update or reinstall offer and the held failure. An announcement is raised only when the composed text changes.
function Update-FastLlmUiFluentMessages {
    [CmdletBinding()] param()
    $f = $script:FastLlmUiFluent
    $e = $f['Els']
    $keys = $f['Keys']
    $offer = ([bool] $script:bannerLabel.Visible -or [bool] $script:reinstallButton.Visible)
    $e['UpdateBar'].Visibility = if ($offer) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    # SetUiBanner writes ForeColor Firebrick for an error offer; the adapter stores it, the bar shows it as the critical colours.
    $foreColor = $script:bannerLabel.ForeColor
    $isError = ($null -ne $foreColor -and [string] $foreColor.Name -ceq 'Firebrick')
    if ($keys['BannerError'] -ne $isError) {
        $keys['BannerError'] = $isError
        if ($isError) {
            $e['UpdateBar'].SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'FastLlm.CriticalBackgroundBrush')
            $e['UpdateText'].SetResourceReference([System.Windows.Documents.TextElement]::ForegroundProperty, 'FastLlm.CriticalTextBrush')
        }
        else {
            $e['UpdateBar'].SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'FastLlm.CardBrush')
            $e['UpdateText'].SetResourceReference([System.Windows.Documents.TextElement]::ForegroundProperty, 'FastLlm.TextPrimaryBrush')
        }
    }

    $held = [bool] $script:failureHeld
    if ($held) {
        $raw = [string] $script:failureViewText
        $failureText = $raw.Trim()
        if ($failureText.Length -gt 400) { $failureText = $failureText.Substring(0, 400) }
        if ($keys['Failure'] -cne $failureText) {
            $keys['Failure'] = $failureText
            $e['FailureText'].Text = $failureText
            Send-FastLlmUiFluentLiveRegion -Element $e['FailureText']
        }
        if ($keys['Held'] -ne $true) { $e['ActivityExpander'].IsExpanded = $true }
        $e['FailureBar'].Visibility = [System.Windows.Visibility]::Visible
    }
    else {
        $e['FailureBar'].Visibility = [System.Windows.Visibility]::Collapsed
        $keys['Failure'] = $null
    }
    $keys['Held'] = $held
}

# One 250 ms refresh. A fault in one part never stops the others and never reaches the message loop; the last one is kept for the lead's logs.
function Invoke-FastLlmUiFluentTick {
    [CmdletBinding()] param()
    $f = $script:FastLlmUiFluent
    $f['Tick'] = [int] $f['Tick'] + 1
    try { Update-FastLlmUiFluentHome } catch { $f['TickError'] = [string] $_.Exception.Message }
    try { Update-FastLlmUiFluentPages } catch { $f['TickError'] = [string] $_.Exception.Message }
    try { Update-FastLlmUiFluentMessages } catch { $f['TickError'] = [string] $_.Exception.Message }
    try { Update-FastLlmUiFluentPane } catch { $f['TickError'] = [string] $_.Exception.Message }
}

# Shows an exception the way WinForms' default ThreadException would: through ShowFailure, or a message box owned by the window.
function Invoke-FastLlmUiFluentUnhandled {
    [CmdletBinding()]
    param($Exception)
    $f = $script:FastLlmUiFluent
    $f['LastException'] = $Exception
    if ($f['InUnhandled']) { return }
    $f['InUnhandled'] = $true
    try {
        $message = if ($null -ne $Exception) { [string] $Exception.Message } else { 'An unknown error occurred.' }
        try { ShowFailure $message }
        catch {
            try { [void] [System.Windows.Forms.MessageBox]::Show($script:form, $message, 'FastLLM', 'OK', 'Error') } catch { $null = $_ }
        }
    }
    finally { $f['InUnhandled'] = $false }
}

function Initialize-FastLlmUiFluentShell {
    [CmdletBinding()] param()
    $f = $script:FastLlmUiFluent
    # Visual styles first, before any WinForms handle exists, so the dialogs the orchestration still opens are not drawn in the Windows 2000 style.
    try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { $null = $_ }
    # Then the dispatcher and ThreadException handlers decide what an exception shows.
    try { [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException) } catch { $null = $_ }

    # Every step up to Show is one try: any fault is no window, the approved text C and exit 3 (the error text goes to the console only).
    # The stage names the run-log reason: theme-init for the theme, the native types and the hooks, xaml-parse for the markup, elements and bindings.
    $stage = 'theme-init'
    try {
        $classicForm = $script:form
        $windowTitle = [string] $classicForm.Text

        # Fail-closed: without the native types or the message hook the sign-out guard would silently be missing.
        $f['Interop'] = [bool] (Initialize-FastLlmUiWindowInterop -SourceRoot $script:FastLlmUiFluentSourceRoot)
        if (-not $f['Interop']) { throw 'The window interop types could not be loaded.' }
        $themeState = Get-FastLlmUiFluentThemeState

        $stage = 'xaml-parse'
        # The decorative text type (src/WindowsFluentAutomation.cs).
        Initialize-FastLlmUiFluentAutomation -SourceRoot $script:FastLlmUiFluentSourceRoot
        $win = New-FastLlmUiXamlElement -Name 'FastLlm.Shell'
        # The order from here is fixed: 1 parse every page, 2 initialise each page into Els, 3 register the pages and build the pane, 4 bindings, 5 the form adapter.
        $homePage = New-FastLlmUiXamlElement -Name 'FastLlm.Home'
        $toolsPage = New-FastLlmUiXamlElement -Name 'FastLlm.Tools'
        $connectPage = New-FastLlmUiXamlElement -Name 'FastLlm.Connect'
        $f['Window'] = $win
        $stage = 'theme-init'
        Set-FastLlmUiFluentTheme -ThemeState $themeState

        # Everything that locks once the handle exists comes first: New-FastLlmUiFormAdapter calls EnsureHandle().
        $stage = 'xaml-parse'
        $size = $script:FastLlmUiFluentWindowSize
        $win.Title = $windowTitle
        $win.Width = [double] $size.Width
        $win.Height = [double] $size.Height
        $win.MinWidth = [double] $size.MinWidth
        $win.MinHeight = [double] $size.MinHeight
        $win.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterScreen
        try { $win.Icon = New-FastLlmUiAppIconImage } catch { $null = $_ }

        # The named elements of the shell and of Home, the Home static text and the split button, then the adapters.
        # A second startup in the same process (the shell suite) starts from an empty element map, so no page name is a duplicate.
        $f['Els'] = @{}
        foreach ($name in 'PaneColumn', 'NavList', 'NavSettingsList', 'MessageScroll', 'UpdateBar', 'UpdateText', 'UpdateNotesButton', 'UpdateButton', 'ReinstallButton',
            'FailureBar', 'FailureText', 'FailureCopyButton', 'PageHost') {
            $f['Els'][$name] = Get-FastLlmUiFluentElement -Root $win -Name $name
        }
        $f['Pages'] = @{}
        $f['Current'] = ''
        [void] (Initialize-FastLlmUiFluentHome -Page $homePage -Els $f['Els'])
        [void] (Initialize-FastLlmUiFluentTools -Page $toolsPage -Els $f['Els'])
        [void] (Initialize-FastLlmUiFluentConnect -Page $connectPage -Els $f['Els'])
        Register-FastLlmUiFluentHomePage -Page $homePage -Els $f['Els']
        Register-FastLlmUiFluentToolsPage -Page $toolsPage -Els $f['Els']
        Register-FastLlmUiFluentConnectPage -Page $connectPage -Els $f['Els']
        $f['Current'] = 'Home'
        $f['Els']['PageHost'].Child = $homePage
        Initialize-FastLlmUiFluentPane

        $null = Initialize-FastLlmUiFluentBindings -InstallRoot $InstallRoot -Catalog $catalog -UiSettings $script:uiSettings
        foreach ($row in (Get-FastLlmUiFluentBindingTable)) {
            $adapter = Get-Variable -Name ([string]$row.Name) -Scope Script -ValueOnly
            $also = ($row.ContainsKey('Also') -and [bool]$row['Also'])
            Connect-FastLlmUiFluentControl -Adapter $adapter -Element $f['Els'][[string]$row.Element] -Mode ([string]$row.Mode) -Event ([string]$row.Event) -Flags @($row.Flags) -Also:$also
        }
        # The failure link names itself as the classic one does.
        [System.Windows.Automation.AutomationProperties]::SetName($f['Els']['FailureCopyButton'], [string] $script:failureCopyLink.Text)

        # The form adapter takes over the window's handle; from here the orchestration's $form is the adapter (owner of every dialog and message box).
        $formAdapter = New-FastLlmUiFormAdapter -Window $win
        Set-Variable -Name form -Scope Script -Value $formAdapter
        try { $classicForm.Dispose() } catch { $null = $_ }

        $stage = 'theme-init'
        Set-FastLlmUiFluentWindowLook -ThemeState $themeState
        $f['Hooks'] = Register-FastLlmUiWindowHooks -Window $win -Form $formAdapter -OnThemeChanged { Update-FastLlmUiFluentTheme }
        if (-not [bool] $f['Hooks']['hooked']) { throw ('The window message hook could not be installed: ' + [string] $f['Hooks']['error']) }

        $stage = 'xaml-parse'
        $win.Add_SizeChanged({ try { Update-FastLlmUiFluentPane } catch { $null = $_ } })
        $uiTimer = New-Object System.Windows.Threading.DispatcherTimer
        $uiTimer.Interval = [TimeSpan]::FromMilliseconds(250)
        $uiTimer.Add_Tick({ Invoke-FastLlmUiFluentTick })
        $f['Timer'] = $uiTimer
    }
    catch {
        Write-Host ([string] $_.Exception.Message)
        Stop-FastLlmUiFluentStartup -Reason $stage
    }
}

# The message loop. On Closed: the window hooks, the tray icon and the dispatcher go; the seam's finally disposes the rest.
function Start-FastLlmUiFluentLoop {
    [CmdletBinding()] param()
    $f = $script:FastLlmUiFluent
    $win = $f['Window']
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
            try { $state['Timer'].Stop() } catch { $null = $_ }
            try { Unregister-FastLlmUiWindowHooks -Window $state['Window'] } catch { $null = $_ }
            try { Clear-FastLlmUiFluentTrayIcon } catch { $null = $_ }
            [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
        })
    # The first paint of the card (GetUiStateSnapshot exists only after the seam), so the window never opens showing the empty markup.
    Invoke-FastLlmUiFluentTick
    $f['Timer'].Start()
    $win.Show()
    [System.Windows.Threading.Dispatcher]::Run()
}
