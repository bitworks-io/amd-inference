#requires -Version 5.1
# The Connect page of the Fluent window: the page XAML (FastLlm.Connect), the copied Connect text, and the code that fills the page the way
# ShowConnectDialog fills its dialog. Dot-sourced by FastLlm.UiFluentShell.ps1. No WPF or WinForms type is resolved at dot-source time, only inside function bodies.
# This is the only fluent file that touches the API key, and only through the three sites the wiring test pins: the key box text on Show, and the two
# hand-overs to the one copy routine (the key Copy and a client card Copy). The key box is a read-only TextBox with no adapter, never a password box.
# Its Ctrl+C, Ctrl+Insert and context-menu Copy run the key Copy function, so they carry the clipboard-history exclusion formats too; the native copy never runs.
Set-StrictMode -Version 2.0

# Today's Connect literals, copied from ShowConnectDialog (the flip deletes the dialog). The members suite pins each value to a constant of that function.
$script:FastLlmUiFluentConnectText = [ordered]@{
    Title            = 'Connect an app'
    IntroRunning     = 'FastLLM is running. Use these values in your app. They stay on this computer (127.0.0.1).'
    IntroNotRunning  = 'FastLLM is not running. The model name and context limit appear once it is running; the address below is where it will listen.'
    BaseUrl          = 'Base URL'
    AnthropicBaseUrl = 'Anthropic base URL'
    ModelName        = 'Model name'
    ContextLimit     = 'Context limit (tokens)'
    ShownWhenRunning = '(shown when running)'
    ApiKey           = 'API key'
    Show             = 'Show'
    Hide             = 'Hide'
    Copy             = 'Copy'
    KeyUnreadable    = 'The stored API key cannot be read.'
    CouldNotCopy     = 'Could not copy: '
    Endpoints        = 'Endpoints on the base URL:'
    EndpointIndent   = '  '
    EndpointSeparator = ' - '
    Documentation    = 'Documentation: '
    CheckFormats     = 'Check the API formats'
}

$script:FastLlmUiXaml['FastLlm.Connect'] = @'
<ScrollViewer xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
              xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
              VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Focusable="False">
  <StackPanel Margin="32,24,32,24" MaxWidth="900">
    <TextBlock x:Name="ConnectTitle" TextWrapping="Wrap" FontFamily="{DynamicResource FastLlm.DisplayFont}"
               FontSize="{DynamicResource FastLlm.SubtitleSize}" FontWeight="{DynamicResource FastLlm.SubtitleWeight}"/>
    <TextBlock x:Name="ConnectStatusText" Margin="0,4,0,0" TextWrapping="Wrap" Foreground="{DynamicResource FastLlm.TextSecondaryBrush}"
               AutomationProperties.LiveSetting="Polite"/>
    <TextBlock x:Name="ConnectIntro" Margin="0,16,0,0" TextWrapping="Wrap"/>
    <TextBlock x:Name="ConnectBaseUrlLabel" Margin="0,16,0,4" TextWrapping="Wrap" FontWeight="{DynamicResource FastLlm.BodyStrongWeight}"/>
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBox x:Name="ConnectBaseUrlBox" Grid.Column="0" IsReadOnly="True" Padding="6,4,6,4" VerticalContentAlignment="Center"
               MinHeight="{DynamicResource FastLlm.ControlHeight}" FocusVisualStyle="{DynamicResource FastLlm.FocusVisual}" FontFamily="{DynamicResource FastLlm.MonoFont}"
               Background="{DynamicResource FastLlm.CardBrush}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}" BorderBrush="{DynamicResource FastLlm.ControlStrongStrokeBrush}"/>
      <Button x:Name="ConnectBaseUrlCopy" Grid.Column="1" Margin="8,0,0,0" Style="{DynamicResource FastLlm.ButtonStyle}"/>
    </Grid>
    <TextBlock x:Name="ConnectAnthropicUrlLabel" Margin="0,12,0,4" TextWrapping="Wrap" FontWeight="{DynamicResource FastLlm.BodyStrongWeight}"/>
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBox x:Name="ConnectAnthropicUrlBox" Grid.Column="0" IsReadOnly="True" Padding="6,4,6,4" VerticalContentAlignment="Center"
               MinHeight="{DynamicResource FastLlm.ControlHeight}" FocusVisualStyle="{DynamicResource FastLlm.FocusVisual}" FontFamily="{DynamicResource FastLlm.MonoFont}"
               Background="{DynamicResource FastLlm.CardBrush}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}" BorderBrush="{DynamicResource FastLlm.ControlStrongStrokeBrush}"/>
      <Button x:Name="ConnectAnthropicUrlCopy" Grid.Column="1" Margin="8,0,0,0" Style="{DynamicResource FastLlm.ButtonStyle}"/>
    </Grid>
    <TextBlock x:Name="ConnectModelNameLabel" Margin="0,12,0,4" TextWrapping="Wrap" FontWeight="{DynamicResource FastLlm.BodyStrongWeight}"/>
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBox x:Name="ConnectModelNameBox" Grid.Column="0" IsReadOnly="True" Padding="6,4,6,4" VerticalContentAlignment="Center"
               MinHeight="{DynamicResource FastLlm.ControlHeight}" FocusVisualStyle="{DynamicResource FastLlm.FocusVisual}" FontFamily="{DynamicResource FastLlm.MonoFont}"
               Background="{DynamicResource FastLlm.CardBrush}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}" BorderBrush="{DynamicResource FastLlm.ControlStrongStrokeBrush}"/>
      <Button x:Name="ConnectModelNameCopy" Grid.Column="1" Margin="8,0,0,0" Style="{DynamicResource FastLlm.ButtonStyle}"/>
    </Grid>
    <TextBlock x:Name="ConnectContextLimitLabel" Margin="0,12,0,4" TextWrapping="Wrap" FontWeight="{DynamicResource FastLlm.BodyStrongWeight}"/>
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBox x:Name="ConnectContextLimitBox" Grid.Column="0" IsReadOnly="True" Padding="6,4,6,4" VerticalContentAlignment="Center"
               MinHeight="{DynamicResource FastLlm.ControlHeight}" FocusVisualStyle="{DynamicResource FastLlm.FocusVisual}" FontFamily="{DynamicResource FastLlm.MonoFont}"
               Background="{DynamicResource FastLlm.CardBrush}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}" BorderBrush="{DynamicResource FastLlm.ControlStrongStrokeBrush}"/>
      <Button x:Name="ConnectContextLimitCopy" Grid.Column="1" Margin="8,0,0,0" Style="{DynamicResource FastLlm.ButtonStyle}"/>
    </Grid>
    <StackPanel x:Name="ConnectKeyRow" Visibility="Collapsed">
      <TextBlock x:Name="ConnectKeyLabel" Margin="0,12,0,4" TextWrapping="Wrap" FontWeight="{DynamicResource FastLlm.BodyStrongWeight}"/>
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBox x:Name="ConnectKeyBox" Grid.Column="0" IsReadOnly="True" IsUndoEnabled="False" Padding="6,4,6,4" VerticalContentAlignment="Center"
                 MinHeight="{DynamicResource FastLlm.ControlHeight}" FocusVisualStyle="{DynamicResource FastLlm.FocusVisual}" FontFamily="{DynamicResource FastLlm.MonoFont}"
                 Background="{DynamicResource FastLlm.CardBrush}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}" BorderBrush="{DynamicResource FastLlm.ControlStrongStrokeBrush}"/>
        <Button x:Name="ConnectKeyShow" Grid.Column="1" Margin="8,0,0,0" Style="{DynamicResource FastLlm.ButtonStyle}"/>
        <Button x:Name="ConnectKeyCopy" Grid.Column="2" Margin="8,0,0,0" Style="{DynamicResource FastLlm.ButtonStyle}"/>
      </Grid>
    </StackPanel>
    <TextBlock x:Name="ConnectKeyNote" Margin="0,12,0,0" TextWrapping="Wrap" Visibility="Collapsed"/>
    <Border x:Name="ConnectAgentWarning" Margin="0,12,0,0" Padding="12" BorderThickness="1" Visibility="Collapsed"
            Background="{DynamicResource FastLlm.CautionBackgroundBrush}" BorderBrush="{DynamicResource FastLlm.CautionTextBrush}"
            CornerRadius="{DynamicResource FastLlm.ControlCornerRadius}">
      <TextBlock x:Name="ConnectAgentWarningText" TextWrapping="Wrap" Foreground="{DynamicResource FastLlm.CautionTextBrush}"/>
    </Border>
    <TextBlock x:Name="ConnectEndpoints" Margin="0,16,0,0" TextWrapping="Wrap" FontFamily="{DynamicResource FastLlm.MonoFont}"/>
    <StackPanel x:Name="ConnectClients" Margin="0,4,0,0"/>
    <Button x:Name="ConnectCheckButton" Margin="0,20,0,0" HorizontalAlignment="Left" Style="{DynamicResource FastLlm.ButtonStyle}"/>
  </StackPanel>
</ScrollViewer>
'@

# The four plain field rows: the text key of the label, the element name prefix, and the field of the connection info.
function Get-FastLlmUiFluentConnectFieldRows {
    [CmdletBinding()] param()
    return @(
        @{ Key = 'BaseUrl';          Prefix = 'ConnectBaseUrl' },
        @{ Key = 'AnthropicBaseUrl'; Prefix = 'ConnectAnthropicUrl' },
        @{ Key = 'ModelName';        Prefix = 'ConnectModelName' },
        @{ Key = 'ContextLimit';     Prefix = 'ConnectContextLimit' }
    )
}

# A caption for Content: underscores are doubled so a URL or a title is never read as an access key.
function Get-FastLlmUiFluentConnectCaption {
    [CmdletBinding()] param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text)
    return (ConvertTo-FastLlmUiAccessText -Text $Text -UseMnemonic $false)
}

# Name and LabeledBy from one string, for a read-only input and its label.
function Set-FastLlmUiFluentConnectInputName {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Box, [Parameter(Mandatory = $true)] $Label, [Parameter(Mandatory = $true)][string] $Text)
    $Label.Text = $Text
    [System.Windows.Automation.AutomationProperties]::SetName($Box, $Text)
    [System.Windows.Automation.AutomationProperties]::SetLabeledBy($Box, $Label)
}

# The one-statement wrapper every field Copy goes through (the suites shadow it). Plain text only: a field is never secret.
function Set-FastLlmUiFluentClipboardText {
    [CmdletBinding()] param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text)
    [Windows.Forms.Clipboard]::SetText($Text)
}

# Collects the page's named elements, sets its static text and names, and attaches its plain handlers. Every name is Connect-prefixed.
function Initialize-FastLlmUiFluentConnect {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Page, [Parameter(Mandatory = $true)][hashtable] $Els)
    $s = $script:FastLlmUiFluentStrings
    $t = $script:FastLlmUiFluentConnectText
    $names = @('ConnectTitle', 'ConnectStatusText', 'ConnectIntro', 'ConnectKeyRow', 'ConnectKeyLabel', 'ConnectKeyBox', 'ConnectKeyShow', 'ConnectKeyCopy',
        'ConnectKeyNote', 'ConnectAgentWarning', 'ConnectAgentWarningText', 'ConnectEndpoints', 'ConnectClients', 'ConnectCheckButton')
    foreach ($row in (Get-FastLlmUiFluentConnectFieldRows)) { foreach ($suffix in 'Label', 'Box', 'Copy') { $names += ([string] $row.Prefix + $suffix) } }
    Add-FastLlmUiFluentElements -Els $Els -Root $Page -Names $names
    $Els['ConnectTitle'].Text = [string] $t.Title
    foreach ($row in (Get-FastLlmUiFluentConnectFieldRows)) {
        $label = [string] $t[[string] $row.Key]
        $prefix = [string] $row.Prefix
        Set-FastLlmUiFluentConnectInputName -Box $Els[$prefix + 'Box'] -Label $Els[$prefix + 'Label'] -Text $label
        $copy = $Els[$prefix + 'Copy']
        $copy.Content = Get-FastLlmUiFluentConnectCaption -Text ([string] $t.Copy)
        [System.Windows.Automation.AutomationProperties]::SetName($copy, ([string] $s.CopyFieldFormat) -f $label)
        $copy.Add_Click({ param($sender, $routed) Invoke-FastLlmUiFluentConnectFieldCopy -Sender $sender })
    }
    # The key row: label, box, Show and Copy. The box has no adapter and holds only the mask until Show.
    $keyBox = $Els['ConnectKeyBox']
    Set-FastLlmUiFluentConnectInputName -Box $keyBox -Label $Els['ConnectKeyLabel'] -Text ([string] $t.ApiKey)
    $keyBox.Text = '********'
    $Els['ConnectKeyShow'].Content = Get-FastLlmUiFluentConnectCaption -Text ([string] $t.Show)
    $Els['ConnectKeyCopy'].Content = Get-FastLlmUiFluentConnectCaption -Text ([string] $t.Copy)
    [System.Windows.Automation.AutomationProperties]::SetName($Els['ConnectKeyCopy'], ([string] $s.CopyFieldFormat) -f [string] $t.ApiKey)
    $Els['ConnectKeyShow'].Add_Click({ param($sender, $routed) Invoke-FastLlmUiFluentConnectKeyShow })
    $Els['ConnectKeyCopy'].Add_Click({ param($sender, $routed) Invoke-FastLlmUiFluentConnectKeyCopy })
    # Ctrl+C, Ctrl+Insert and the context-menu Copy are the Copy command: it runs the key Copy function (history-exclusion formats) and is handled,
    # so WPF's own copy, which sets plain text only, never runs. Cut is blocked. A drag out of the box is cancelled too.
    $copyBinding = [System.Windows.Input.CommandBinding]::new([System.Windows.Input.ApplicationCommands]::Copy)
    $copyBinding.Add_CanExecute({ param($sender, $routed) Invoke-FastLlmUiFluentConnectKeyCanCopy -Routed $routed })
    $copyBinding.Add_Executed({ param($sender, $routed) Invoke-FastLlmUiFluentConnectKeyCommand -Routed $routed })
    [void] $keyBox.CommandBindings.Add($copyBinding)
    $cutBinding = [System.Windows.Input.CommandBinding]::new([System.Windows.Input.ApplicationCommands]::Cut)
    $cutBinding.Add_CanExecute({ param($sender, $routed) $routed.CanExecute = $false; $routed.Handled = $true })
    $cutBinding.Add_Executed({ param($sender, $routed) $routed.Handled = $true })
    [void] $keyBox.CommandBindings.Add($cutBinding)
    [System.Windows.DataObject]::AddCopyingHandler($keyBox, [System.Windows.DataObjectCopyingEventHandler] { param($sender, $routed) $routed.CancelCommand() })
    $menu = New-Object System.Windows.Controls.ContextMenu
    $menuCopy = New-Object System.Windows.Controls.MenuItem
    $menuCopy.Header = Get-FastLlmUiFluentConnectCaption -Text ([string] $t.Copy)
    $menuCopy.Command = [System.Windows.Input.ApplicationCommands]::Copy
    $menuCopy.CommandTarget = $keyBox
    [void] $menu.Items.Add($menuCopy)
    $menu.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, 'FastLlm.LayerBrush')
    $menu.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'FastLlm.TextPrimaryBrush')
    $menu.SetResourceReference([System.Windows.Controls.Control]::BorderBrushProperty, 'FastLlm.ControlStrongStrokeBrush')
    $menuCopy.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'FastLlm.TextPrimaryBrush')
    $menuCopy.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, 'FastLlm.LayerBrush')
    $keyBox.ContextMenu = $menu
    $Els['ConnectCheckButton'].Content = Get-FastLlmUiFluentConnectCaption -Text ([string] $t.CheckFormats)
    [System.Windows.Controls.ToolTipService]::SetShowOnDisabled($Els['ConnectCheckButton'], $true)
    $Els['ConnectCheckButton'].Add_Click({ param($sender, $routed) Invoke-FastLlmUiFluentConnectApiCheck })
    $f = $script:FastLlmUiFluent
    $f['Connect'] = @{ KeyShown = $false; Mask = '********'; Info = $null; Row = $null; LastRunning = $false; Why = ''; Cards = @() }
    # A page that is no longer visible (left, window hidden or minimised to the tray) always shows the mask.
    $Page.Add_IsVisibleChanged({ param($sender, $routed) Invoke-FastLlmUiFluentConnectVisibleChanged -Routed $routed })
    return $Els
}

# Connect's entry in the page registry. Its status line is the card's composed text, announced only while Connect is the current page.
function Register-FastLlmUiFluentConnectPage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Page, [Parameter(Mandatory = $true)][hashtable] $Els)
    Register-FastLlmUiFluentPage -Id 'Connect' -Element $Page -Nav 'NavConnect' -Status $Els['ConnectStatusText'] -Enter 'Enter-FastLlmUiFluentConnect' -Leave 'Exit-FastLlmUiFluentConnect' -Update 'Update-FastLlmUiFluentConnect'
}

function Invoke-FastLlmUiFluentConnectVisibleChanged {
    [CmdletBinding()] param($Routed)
    if (-not [bool] $Routed.NewValue) { Hide-FastLlmUiFluentConnectKey }
}

# Masks the key box again. The caption goes back to Show. With undo off there is nothing to undo back to the key.
function Hide-FastLlmUiFluentConnectKey {
    [CmdletBinding()] param()
    $f = $script:FastLlmUiFluent
    $c = $f['Connect']
    if ($null -eq $c) { return }
    $e = $f['Els']
    $keyBox = $e['ConnectKeyBox']
    $keyBox.Text = [string] $c['Mask']
    $keyBox.Select(0, 0)
    $e['ConnectKeyShow'].Content = Get-FastLlmUiFluentConnectCaption -Text ([string] $script:FastLlmUiFluentConnectText.Show)
    $c['KeyShown'] = $false
}

# Fills the page the way the dialog fills itself when it opens (the three statements), then the rows. Always masks the key first.
function Update-FastLlmUiFluentConnectContent {
    [CmdletBinding()] param()
    $f = $script:FastLlmUiFluent
    $e = $f['Els']
    $c = $f['Connect']
    $t = $script:FastLlmUiFluentConnectText
    $s = $script:FastLlmUiFluentStrings
    Hide-FastLlmUiFluentConnectKey
    $connectSettings=Get-FastLlmServingSettings -InstallRoot $script:installPath
    $info=Get-FastLlmConnectionInfo -Status (GetUiBackgroundRunStatus) -InstallRoot $script:installPath -Settings $connectSettings
    $script:apiKeyStore=$null
    $keyRow=Get-FastLlmUiApiKeyRow -Info $info -Settings $connectSettings -ApiKeyStore (GetUiApiKeyStore)
    $c['Info'] = $info
    $c['Row'] = $keyRow
    $c['Mask'] = [string] $keyRow.mask
    $c['LastRunning'] = [bool] $f['Keys']['Running']
    $c['Why'] = $null
    $e['ConnectIntro'].Text = $(if ([string] $info.state -ceq 'running') { [string] $t.IntroRunning } else { [string] $t.IntroNotRunning })
    $values = @{
        'BaseUrl'          = [string] $info.baseUrl
        'AnthropicBaseUrl' = [string] $info.anthropicBaseUrl
        'ModelName'        = $(if ($null -ne $info.modelName) { [string] $info.modelName } else { [string] $t.ShownWhenRunning })
        'ContextLimit'     = $(if ($null -ne $info.contextTokens) { [string] $info.contextTokens } else { [string] $t.ShownWhenRunning })
    }
    foreach ($row in (Get-FastLlmUiFluentConnectFieldRows)) {
        $value = [string] $values[[string] $row.Key]
        $e[[string] $row.Prefix + 'Box'].Text = $value
        $e[[string] $row.Prefix + 'Copy'].Tag = $value
    }
    # The key row: shown only when the row says so; Show and Copy follow canShow.
    $e['ConnectKeyBox'].Text = [string] $c['Mask']
    $e['ConnectKeyRow'].Visibility = $(if ([bool] $keyRow.visible) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed })
    $e['ConnectKeyShow'].IsEnabled = [bool] $keyRow.canShow
    $e['ConnectKeyCopy'].IsEnabled = [bool] $keyRow.canShow
    $note = [string] $keyRow.note
    $e['ConnectKeyNote'].Text = $note
    $e['ConnectKeyNote'].Visibility = $(if ($note -ne '') { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed })
    $warning = ''
    if ($info.agentWarning) { $warning = [string] $info.agentWarning }
    $e['ConnectAgentWarningText'].Text = $warning
    $e['ConnectAgentWarning'].Visibility = $(if ($warning -ne '') { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed })
    $endpointLines = @(@($info.endpoints) | ForEach-Object { [string] $t.EndpointIndent + $_.path + [string] $t.EndpointSeparator + $_.label })
    $e['ConnectEndpoints'].Text = [string] $t.Endpoints + [Environment]::NewLine + ($endpointLines -join [Environment]::NewLine)
    # One card per client, built in code (no ItemsControl): title, Copy with the snippet and its key token in Tag, the snippet as a read-only box, the doc links.
    $e['ConnectClients'].Children.Clear()
    $cards = New-Object System.Collections.ArrayList
    foreach ($client in @($info.clients)) {
        $title = [string] $client.title
        $border = New-Object System.Windows.Controls.Border
        $border.Margin = New-Object System.Windows.Thickness(0, 12, 0, 0)
        $border.Padding = New-Object System.Windows.Thickness(16)
        $border.BorderThickness = New-Object System.Windows.Thickness(1)
        $border.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'FastLlm.CardBrush')
        $border.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'FastLlm.CardStrokeBrush')
        $border.SetResourceReference([System.Windows.Controls.Border]::CornerRadiusProperty, 'FastLlm.OverlayCornerRadius')
        $stack = New-Object System.Windows.Controls.StackPanel
        $head = New-Object System.Windows.Controls.Grid
        $col1 = New-Object System.Windows.Controls.ColumnDefinition
        $col1.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
        $col2 = New-Object System.Windows.Controls.ColumnDefinition
        $col2.Width = [System.Windows.GridLength]::Auto
        [void] $head.ColumnDefinitions.Add($col1)
        [void] $head.ColumnDefinitions.Add($col2)
        $titleBlock = New-Object System.Windows.Controls.TextBlock
        $titleBlock.Text = $title
        $titleBlock.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $titleBlock.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $titleBlock.SetResourceReference([System.Windows.Controls.TextBlock]::FontWeightProperty, 'FastLlm.BodyStrongWeight')
        $copy = New-Object System.Windows.Controls.Button
        $copy.SetResourceReference([System.Windows.FrameworkElement]::StyleProperty, 'FastLlm.ButtonStyle')
        $copy.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0)
        $copy.Content = Get-FastLlmUiFluentConnectCaption -Text ([string] $t.Copy)
        $copy.Tag = [string] $client.snippet
        [System.Windows.Automation.AutomationProperties]::SetName($copy, ([string] $s.CopyFieldFormat) -f $title)
        $copy.Add_Click({ param($sender, $routed) Invoke-FastLlmUiFluentConnectCardCopy -Sender $sender })
        [System.Windows.Controls.Grid]::SetColumn($copy, 1)
        [void] $head.Children.Add($titleBlock)
        [void] $head.Children.Add($copy)
        [void] $stack.Children.Add($head)
        $box = New-Object System.Windows.Controls.TextBox
        $box.IsReadOnly = $true
        $box.AcceptsReturn = $true
        $box.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $box.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
        $box.MaxHeight = 190
        $box.Margin = New-Object System.Windows.Thickness(0, 8, 0, 0)
        $box.Padding = New-Object System.Windows.Thickness(6, 4, 6, 4)
        $box.SetResourceReference([System.Windows.FrameworkElement]::FocusVisualStyleProperty, 'FastLlm.FocusVisual')
        $box.SetResourceReference([System.Windows.Controls.Control]::FontFamilyProperty, 'FastLlm.MonoFont')
        $box.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, 'FastLlm.CardBrush')
        $box.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'FastLlm.TextPrimaryBrush')
        $box.SetResourceReference([System.Windows.Controls.Control]::BorderBrushProperty, 'FastLlm.ControlStrongStrokeBrush')
        $box.Text = (Get-FastLlmConnectDisplayText -Snippet ([string] $client.snippet)) -replace "`n", [Environment]::NewLine
        [System.Windows.Automation.AutomationProperties]::SetName($box, $title)
        [System.Windows.Automation.AutomationProperties]::SetLabeledBy($box, $titleBlock)
        [void] $stack.Children.Add($box)
        $links = New-Object System.Collections.ArrayList
        foreach ($docUrl in @($client.docUrls)) {
            $link = New-Object System.Windows.Controls.Button
            $link.SetResourceReference([System.Windows.FrameworkElement]::StyleProperty, 'FastLlm.LinkButtonStyle')
            $link.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
            $link.Margin = New-Object System.Windows.Thickness(0, 6, 0, 0)
            $linkText = [string] $t.Documentation + [string] $docUrl
            $link.Content = Get-FastLlmUiFluentConnectCaption -Text $linkText
            $link.Tag = [string] $docUrl
            [System.Windows.Automation.AutomationProperties]::SetName($link, $linkText)
            $link.Add_Click({ param($sender, $routed) Invoke-FastLlmUiFluentConnectDocLink -Sender $sender })
            [void] $stack.Children.Add($link)
            [void] $links.Add($link)
        }
        $border.Child = $stack
        [void] $e['ConnectClients'].Children.Add($border)
        [void] $cards.Add(@{ Border = $border; Title = $titleBlock; Copy = $copy; Box = $box; Links = $links.ToArray() })
    }
    $c['Cards'] = $cards.ToArray()
    Update-FastLlmUiFluentConnectCheck
}

# The API check button: enabled by the dialog's rule, and a disabled button says why (not running, or a side step in the way). Written on change only.
function Update-FastLlmUiFluentConnectCheck {
    [CmdletBinding()] param()
    $f = $script:FastLlmUiFluent
    $e = $f['Els']
    $c = $f['Connect']
    $info = $c['Info']
    if ($null -eq $info) { return }
    $running = ([string] $info.state -ceq 'running')
    $available = [bool] (GetUiActionAvailabilityNow ([bool]($script:child -or $script:vcBroker -or $script:updateRun))).apiCheck
    $enabled = ($running -and $available)
    $button = $e['ConnectCheckButton']
    if ($button.IsEnabled -ne $enabled) { $button.IsEnabled = $enabled }
    $code = ''
    if (-not $enabled) { $code = $(if (-not $running) { 'not-running' } else { 'side-step' }) }
    if ($c['Why'] -ceq $code) { return }
    $c['Why'] = $code
    $text = Get-FastLlmUiFluentToolsReasonText -Code $code
    if ($text -ne '') {
        $button.ToolTip = $text
        [System.Windows.Automation.AutomationProperties]::SetHelpText($button, $text)
    }
    else {
        $button.ToolTip = $null
        [System.Windows.Automation.AutomationProperties]::SetHelpText($button, '')
    }
}

# The page registry's Enter: what the dialog does when it opens. A fault is shown the way the dialog's own button shows it.
function Enter-FastLlmUiFluentConnect {
    [CmdletBinding()] param()
    try { Update-FastLlmUiFluentConnectContent }
    catch { ShowFailure $_.Exception.Message }
}

# Leaving the page masks the key. It never refuses.
function Exit-FastLlmUiFluentConnect {
    [CmdletBinding()] param()
    Hide-FastLlmUiFluentConnectKey
}

# Once per tick while Connect shows. The content is read again only when Running changes (the Home refresh keeps it), never on any other tick; the check button's rule is
# evaluated every tick.
function Update-FastLlmUiFluentConnect {
    [CmdletBinding()] param()
    $f = $script:FastLlmUiFluent
    $c = $f['Connect']
    $running = [bool] $f['Keys']['Running']
    if ($running -ne [bool] $c['LastRunning']) { Update-FastLlmUiFluentConnectContent }
    else { Update-FastLlmUiFluentConnectCheck }
}

# A field Copy: the plain text of its Tag, through the one wrapper.
function Invoke-FastLlmUiFluentConnectFieldCopy {
    [CmdletBinding()] param([Parameter(Mandatory = $true)] $Sender)
    try{Set-FastLlmUiFluentClipboardText -Text ([string]$Sender.Tag)}catch{$script:statusLabel.Text=[string]$script:FastLlmUiFluentConnectText.CouldNotCopy+$_.Exception.Message}
}

# Show reads the key from the store and puts it in the key box only; a second click hides it again.
function Invoke-FastLlmUiFluentConnectKeyShow {
    [CmdletBinding()] param()
    $f = $script:FastLlmUiFluent
    $e = $f['Els']
    $c = $f['Connect']
    $keyBox = $e['ConnectKeyBox']
    if (-not [bool] $c['KeyShown']) {
        $shownKey=ReadUiApiKey
        if($shownKey){$keyBox.Text=$shownKey;$c['KeyShown']=$true;$e['ConnectKeyShow'].Content=Get-FastLlmUiFluentConnectCaption -Text ([string]$script:FastLlmUiFluentConnectText.Hide)}else{$keyBox.Text=[string]$c['Mask'];$script:statusLabel.Text=[string]$script:FastLlmUiFluentConnectText.KeyUnreadable}
        $shownKey=$null
    }
    else { Hide-FastLlmUiFluentConnectKey }
}

# Copy goes through the one copy routine: it reads the key for this one copy and hands it to the clipboard only. This function never holds the key.
function Invoke-FastLlmUiFluentConnectKeyCopy {
    [CmdletBinding()] param()
    [void](Invoke-FastLlmUiKeyCopy -KeyOnly -ReadKey {ReadUiApiKey} -SetClipboard {param($Payload) SetUiClipboardPayload $Payload} -SetStatus {param($Text) $statusLabel.Text=[string]$Text})
}

# The key box's Copy command (Ctrl+C, Ctrl+Insert, the context menu): the same function as the Copy button, and always handled.
function Invoke-FastLlmUiFluentConnectKeyCommand {
    [CmdletBinding()] param($Routed)
    $Routed.Handled = $true
    if ([bool] $script:FastLlmUiFluent['Els']['ConnectKeyCopy'].IsEnabled) { Invoke-FastLlmUiFluentConnectKeyCopy }
}

function Invoke-FastLlmUiFluentConnectKeyCanCopy {
    [CmdletBinding()] param($Routed)
    $Routed.CanExecute = [bool] $script:FastLlmUiFluent['Els']['ConnectKeyCopy'].IsEnabled
    $Routed.Handled = $true
}

# A client card Copy: the card text with its key token replaced at that moment, by the same routine.
function Invoke-FastLlmUiFluentConnectCardCopy {
    [CmdletBinding()] param([Parameter(Mandatory = $true)] $Sender)
    [void](Invoke-FastLlmUiKeyCopy -Snippet ([string]$Sender.Tag) -ReadKey {ReadUiApiKey} -SetClipboard {param($Payload) SetUiClipboardPayload $Payload} -SetStatus {param($Text) $statusLabel.Text=[string]$Text})
}

# A documentation link: https only, as the dialog's link label.
function Invoke-FastLlmUiFluentConnectDocLink {
    [CmdletBinding()] param([Parameter(Mandatory = $true)] $Sender)
    try{if(([string]$Sender.Tag).StartsWith('https://')){Start-Process ([string]$Sender.Tag)}}catch{$null=$_}
}

# Check the API formats: a side step beside a serving run; its result comes through the side-step completion as today.
function Invoke-FastLlmUiFluentConnectApiCheck {
    [CmdletBinding()] param()
    try{ReadSideSelection;LaunchSideStep 'api check' (@('doctor','-ApiCheck')+$script:selection)}catch{ShowFailure $_.Exception.Message}
}
