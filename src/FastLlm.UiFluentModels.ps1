#requires -Version 5.1
# The Models page of the Fluent window: the page XAML (FastLlm.Models), the copied Models text, the pure list models, and the code that fills the page the way
# today's Models, Components and Switch dialogs fill themselves. Dot-sourced by FastLlm.UiFluentShell.ps1. No WPF or WinForms type is resolved at dot-source
# time, only inside function bodies. The three remove flows are today's functions in fast-llm-ui.ps1 (RemoveModelFromWindow, RemoveLeftoversFromWindow,
# RemoveComponentFromWindow); this page gives them a view hashtable of its own (New-FastLlmUiFluentModelsView / ...ComponentsView), so their confirmations,
# Button2, the operation lock and their texts stay single-source. Their list rebuild reaches this page through the view's refresh key.
Set-StrictMode -Version 2.0

# Today's Models literals, copied from fast-llm-ui.ps1 (the flip deletes the dialogs). The members suite pins each value to a constant or a format template of
# ShowUiSwitchPicker, ShowModelsWindow, FillModelsPanel or FillComponentsPanel, or to the first argument of a LabelAt call.
$script:FastLlmUiFluentModelsText = [ordered]@{
    Model                   = 'Model'
    Context                 = 'Context (0 = catalog default)'
    Folder                  = 'Install and model cache folder'
    Bar                     = 'Resizable BAR workaround'
    SwitchTitle             = 'Switch model'
    SwitchIntro             = 'FastLLM finishes the requests in progress, stops the running model and starts the one you pick. If the new model cannot start, the old one is started again. "Fits" is an estimate; FastLLM checks again when it switches.'
    SwitchNow               = 'Switch'
    DownloadedModels        = 'Downloaded models'
    RemoveLeftovers         = 'Remove leftover partial downloads'
    Remove                  = 'Remove'
    NoModels                = 'No models are downloaded.'
    NoComponents            = 'No engine components are installed.'
    FreeFormat              = 'Free disk space: {0} GB'
    ModelRowFormat          = '{0}  -  {1} GB'
    InUseFormat             = '  (in use: {0})'
    LeftoversFormat         = '{0} leftover file(s), {1} GB'
    ModelListReadFormat     = 'The model list could not be read: {0}'
    ComponentListReadFormat = 'The component list could not be read: {0}'
}

$script:FastLlmUiXaml['FastLlm.Models'] = @'
<ScrollViewer xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
              xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
              VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Focusable="False">
  <StackPanel Margin="32,24,32,24" MaxWidth="900">
    <TextBlock x:Name="ModelsTitle" TextWrapping="Wrap" FontFamily="{DynamicResource FastLlm.DisplayFont}"
               FontSize="{DynamicResource FastLlm.SubtitleSize}" FontWeight="{DynamicResource FastLlm.SubtitleWeight}"/>
    <TextBlock x:Name="ModelsStatusText" Margin="0,4,0,0" TextWrapping="Wrap" Foreground="{DynamicResource FastLlm.TextSecondaryBrush}"
               AutomationProperties.LiveSetting="Polite"/>
    <TextBlock x:Name="ModelsStartWithHeading" Margin="0,24,0,0" FontWeight="{DynamicResource FastLlm.BodyStrongWeight}"/>
    <TextBlock x:Name="ModelsModelLabel" Margin="0,8,0,4" TextWrapping="Wrap"/>
    <ComboBox x:Name="ModelsModelBox" Style="{DynamicResource FastLlm.ComboBoxStyle}"/>
    <Button x:Name="ModelsChooseButton" Margin="0,12,0,0" HorizontalAlignment="Left" Style="{DynamicResource FastLlm.ButtonStyle}"/>
    <Expander x:Name="ModelsStartOptions" Margin="0,16,0,0" IsExpanded="False" Style="{DynamicResource FastLlm.ExpanderStyle}">
      <Expander.Header>
        <TextBlock x:Name="ModelsStartOptionsHeader" FontWeight="{DynamicResource FastLlm.BodyStrongWeight}"/>
      </Expander.Header>
      <StackPanel Margin="0,8,0,0">
        <TextBlock x:Name="ModelsFolderLabel" Margin="0,0,0,4" TextWrapping="Wrap"/>
        <TextBox x:Name="ModelsFolderBox" Style="{DynamicResource FastLlm.TextBoxStyle}"/>
        <TextBlock x:Name="ModelsContextLabel" Margin="0,12,0,4" TextWrapping="Wrap"/>
        <Grid x:Name="ModelsContextRow" HorizontalAlignment="Left" MinWidth="260">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBox x:Name="ModelsContextBox" Grid.Column="0" Style="{DynamicResource FastLlm.TextBoxStyle}"/>
          <RepeatButton x:Name="ModelsContextUp" Grid.Column="1" Margin="4,0,0,0" Style="{DynamicResource FastLlm.SpinButtonStyle}"
                        IsEnabled="{Binding IsEnabled, ElementName=ModelsContextBox}"/>
          <RepeatButton x:Name="ModelsContextDown" Grid.Column="2" Margin="4,0,0,0" Style="{DynamicResource FastLlm.SpinButtonStyle}"
                        IsEnabled="{Binding IsEnabled, ElementName=ModelsContextBox}"/>
        </Grid>
        <TextBlock x:Name="ModelsBarLabel" Margin="0,12,0,4" TextWrapping="Wrap"/>
        <ComboBox x:Name="ModelsBarBox" HorizontalAlignment="Left" MinWidth="260" Style="{DynamicResource FastLlm.ComboBoxStyle}"/>
      </StackPanel>
    </Expander>
    <TextBlock x:Name="ModelsSwitchHeading" Margin="0,24,0,0" FontWeight="{DynamicResource FastLlm.BodyStrongWeight}"/>
    <TextBlock x:Name="ModelsSwitchIntro" Margin="0,8,0,0" TextWrapping="Wrap" Foreground="{DynamicResource FastLlm.TextSecondaryBrush}"/>
    <TextBlock x:Name="ModelsSwitchLine" Margin="0,8,0,0" TextWrapping="Wrap"/>
    <ListBox x:Name="ModelsSwitchList" Margin="0,8,0,0" MaxHeight="220" ScrollViewer.HorizontalScrollBarVisibility="Auto" ScrollViewer.CanContentScroll="False"
             FocusVisualStyle="{DynamicResource FastLlm.FocusVisual}" Background="{DynamicResource FastLlm.CardBrush}"
             Foreground="{DynamicResource FastLlm.TextPrimaryBrush}" BorderBrush="{DynamicResource FastLlm.ControlStrongStrokeBrush}">
      <ListBox.ItemContainerStyle>
        <Style TargetType="ListBoxItem">
          <Setter Property="Foreground" Value="{DynamicResource FastLlm.TextPrimaryBrush}"/>
          <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ListBoxItem">
                <Border x:Name="Bd" Padding="8,4,8,4" Background="Transparent" BorderBrush="Transparent" BorderThickness="2">
                  <ContentPresenter/>
                </Border>
                <ControlTemplate.Triggers>
                  <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Foreground" Value="{DynamicResource FastLlm.TextOnAccentBrush}"/>
                    <Setter TargetName="Bd" Property="Background" Value="{DynamicResource FastLlm.AccentFillBrush}"/>
                  </Trigger>
                  <Trigger Property="IsKeyboardFocused" Value="True">
                    <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource FastLlm.FocusBrush}"/>
                  </Trigger>
                </ControlTemplate.Triggers>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Style>
      </ListBox.ItemContainerStyle>
    </ListBox>
    <TextBlock x:Name="ModelsSwitchMessage" Margin="0,8,0,0" TextWrapping="Wrap" AutomationProperties.LiveSetting="Polite"/>
    <Button x:Name="ModelsSwitchNow" Margin="0,8,0,0" HorizontalAlignment="Left" Style="{DynamicResource FastLlm.ButtonStyle}"/>
    <Border x:Name="ModelsDownloadedSection" Margin="0,24,0,0">
      <StackPanel>
        <TextBlock x:Name="ModelsDownloadedHeading" FontWeight="{DynamicResource FastLlm.BodyStrongWeight}"/>
        <StackPanel x:Name="ModelsModelRows" Margin="0,8,0,0"/>
        <TextBlock x:Name="ModelsFreeText" Margin="0,8,0,0" TextWrapping="Wrap"/>
        <Button x:Name="ModelsLeftoverButton" Margin="0,8,0,0" HorizontalAlignment="Left" Style="{DynamicResource FastLlm.ButtonStyle}"/>
        <TextBlock x:Name="ModelsDownloadedMessage" Margin="0,8,0,0" TextWrapping="Wrap" AutomationProperties.LiveSetting="Polite"/>
      </StackPanel>
    </Border>
    <Border x:Name="ModelsComponentsSection" Margin="0,24,0,0">
      <StackPanel>
        <TextBlock x:Name="ModelsComponentsHeading" FontWeight="{DynamicResource FastLlm.BodyStrongWeight}"/>
        <StackPanel x:Name="ModelsComponentRows" Margin="0,8,0,0"/>
        <TextBlock x:Name="ModelsComponentsMessage" Margin="0,8,0,0" TextWrapping="Wrap" AutomationProperties.LiveSetting="Polite"/>
      </StackPanel>
    </Border>
  </StackPanel>
</ScrollViewer>
'@

# The Models rows of the binding table (after Tools). ModelsSwitchLine joins switchLabel, which Home already binds (Also). The two sections bind Visual with no
# event, so today's Models and Components dialogs can never open from here; chooseButton keeps its click (StartRecipeList).
function Get-FastLlmUiFluentModelsBindings {
    [CmdletBinding()] param()
    return @(
        @{ Name = 'modelBox';         Element = 'ModelsModelBox';           Mode = 'Combo';     Event = '';      Flags = @() },
        @{ Name = 'pathBox';          Element = 'ModelsFolderBox';          Mode = 'Input';     Event = '';      Flags = @() },
        @{ Name = 'contextBox';       Element = 'ModelsContextBox';         Mode = 'Number';    Event = '';      Flags = @() },
        @{ Name = 'barBox';           Element = 'ModelsBarBox';             Mode = 'Combo';     Event = '';      Flags = @() },
        @{ Name = 'chooseButton';     Element = 'ModelsChooseButton';       Mode = 'Content';   Event = 'Click'; Flags = @() },
        @{ Name = 'switchLabel';      Element = 'ModelsSwitchLine';         Mode = 'TextBlock'; Event = '';      Flags = @(); Also = $true },
        @{ Name = 'modelsButton';     Element = 'ModelsDownloadedSection';  Mode = 'Visual';    Event = '';      Flags = @() },
        @{ Name = 'componentsButton'; Element = 'ModelsComponentsSection';  Mode = 'Visual';    Event = '';      Flags = @() }
    )
}

# The elements that can say why they are greyed: element, adapter, and the Get-FastLlmUiGreyedReason action.
function Get-FastLlmUiFluentModelsReasonRows {
    [CmdletBinding()] param()
    return @(
        @{ Element = 'ModelsChooseButton'; Adapter = 'chooseButton'; Action = 'chooseSetup' },
        @{ Element = 'ModelsModelBox';     Adapter = 'modelBox';     Action = 'startInputs' },
        @{ Element = 'ModelsFolderBox';    Adapter = 'pathBox';      Action = 'startInputs' },
        @{ Element = 'ModelsContextBox';   Adapter = 'contextBox';   Action = 'startInputs' },
        @{ Element = 'ModelsBarBox';       Adapter = 'barBox';       Action = 'startInputs' }
    )
}

# The reason code -> its line. The shared codes come from Tools' table; the two Models codes are here.
function Get-FastLlmUiFluentModelsReasonText {
    [CmdletBinding()] param([AllowEmptyString()][string] $Code)
    $s = $script:FastLlmUiFluentStrings
    switch -CaseSensitive ($Code) {
        'background' { return [string] $s.WhyBackgroundRun }
        'no-preview' { return [string] $s.WhyNoPreview }
    }
    return (Get-FastLlmUiFluentToolsReasonText -Code $Code)
}

# The root every list is read from and every remove acts on: the one place the folder box text becomes a full path. It throws for an unusable folder.
function Get-FastLlmUiFluentModelsRoot {
    [CmdletBinding()] param()
    return [IO.Path]::GetFullPath([string] $script:pathBox.Text)
}

# The view hashtable today's RemoveModelFromWindow and RemoveLeftoversFromWindow read. Made by the list update, so the view a Remove reads is always the one
# behind the rows on screen. The classic panel and free controls are absent: the list is rebuilt by refresh.
function New-FastLlmUiFluentModelsView {
    [CmdletBinding()] param()
    $e = $script:FastLlmUiFluent['Els']
    $m = $script:FastLlmUiFluent['Models']['Message']
    $view = @{dialog = $script:form; message = $m; leftoverButton = $e['ModelsLeftoverButton']; leftoverText = ''; root = (Get-FastLlmUiFluentModelsRoot); file = (Join-Path $script:FastLlmUiFluentSourceRoot 'config/catalog.json'); refresh = 'Update-FastLlmUiFluentModelsList' }
    $script:modelsView = $view
    return $view
}

# The view hashtable today's RemoveComponentFromWindow reads.
function New-FastLlmUiFluentComponentsView {
    [CmdletBinding()] param()
    $m = $script:FastLlmUiFluent['Models']['ComponentsMessage']
    $view = @{dialog = $script:form; message = $m; root = (Get-FastLlmUiFluentModelsRoot); file = (Join-Path $script:FastLlmUiFluentSourceRoot 'config/components.json'); refresh = 'Update-FastLlmUiFluentComponentsList' }
    $script:componentsView = $view
    return $view
}

# The downloaded models, as data (pure: the store functions are read through their names only). It runs today's FillModelsPanel steps in today's order. A
# folder that cannot be used (-RootError) shows the list-read text and reads nothing.
function Get-FastLlmUiFluentModelsListModel {
    [CmdletBinding()]
    param([AllowEmptyString()][string] $Root = '', [AllowEmptyString()][string] $File = '', $Catalog, [AllowEmptyString()][string] $RootError = '')
    $t = $script:FastLlmUiFluentModelsText
    $message = ''
    $installed = @()
    $leftovers = @()
    $free = $null
    if ($RootError -ne '') { $message = ([string] $t.ModelListReadFormat) -f $RootError }
    else {
        try { $installed = @(Get-FastLlmInstalledModels -InstallRoot $Root -CatalogPath $File) }
        catch { $message = ([string] $t.ModelListReadFormat) -f $_.Exception.Message }
        try { $leftovers = @(Get-FastLlmModelLeftovers -InstallRoot $Root) } catch { $null = $_ }
        $free = Get-FastLlmModelStoreFreeBytes -InstallRoot $Root
    }
    $freeText = ''
    if ($null -ne $free) { $freeText = ([string] $t.FreeFormat) -f (Format-FastLlmModelStoreGigabytes -Bytes $free) }
    $leftoverBytes = [int64] 0
    foreach ($leftover in $leftovers) { $leftoverBytes += [int64] $leftover.sizeBytes }
    $leftoverNames = @($leftovers | Where-Object { -not $_.locked } | ForEach-Object { [string] $_.name })
    $leftoverText = ''
    if ($leftovers.Count -gt 0) { $leftoverText = ([string] $t.LeftoversFormat) -f $leftovers.Count, (Format-FastLlmModelStoreGigabytes -Bytes $leftoverBytes) }
    $rows = New-Object System.Collections.ArrayList
    foreach ($row in $installed) {
        $entry = @($Catalog.models | Where-Object { [string] $_.id -ceq [string] $row.id })[0]
        $name = Get-FastLlmModelDisplayName -Model $entry
        $text = ([string] $t.ModelRowFormat) -f $name, (Format-FastLlmModelStoreGigabytes -Bytes $row.sizeBytes)
        if ($row.inUse) { $text += ([string] $t.InUseFormat) -f $row.inUseReason }
        [void] $rows.Add([pscustomobject] @{ id = [string] $row.id; name = [string] $name; text = $text; removable = [bool] (-not $row.inUse); inUseReason = [string] $row.inUseReason })
    }
    return [pscustomobject] @{ rows = $rows.ToArray(); freeText = $freeText; leftoverNames = $leftoverNames; leftoverText = $leftoverText; leftoverEnabled = [bool] ($leftovers.Count -gt 0); message = $message }
}

# The installed engine components, as data (pure), by today's FillComponentsPanel steps.
function Get-FastLlmUiFluentComponentsListModel {
    [CmdletBinding()]
    param([AllowEmptyString()][string] $Root = '', [AllowEmptyString()][string] $File = '', [AllowEmptyString()][string] $RootError = '')
    $t = $script:FastLlmUiFluentModelsText
    $message = ''
    $source = @()
    if ($RootError -ne '') { $message = ([string] $t.ComponentListReadFormat) -f $RootError }
    else {
        try { $source = @(Get-FastLlmInstalledComponentRows -Inventory @(Get-FastLlmComponentInventory -ComponentsPath $File -InstallRoot $Root)) }
        catch { $source = @(); $message = ([string] $t.ComponentListReadFormat) -f $_.Exception.Message }
    }
    $rows = New-Object System.Collections.ArrayList
    foreach ($row in $source) { [void] $rows.Add([pscustomobject] @{ id = [string] $row.id; text = [string] $row.label }) }
    return [pscustomobject] @{ rows = $rows.ToArray(); message = $message }
}

# One row of a list: the text and a Remove button (Tag = id, the automation name names the row, the visible text stays Remove).
function New-FastLlmUiFluentModelsRow {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Text, [Parameter(Mandatory = $true)][string] $Id, [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][bool] $Enabled, [AllowEmptyString()][string] $Reason = '', [Parameter(Mandatory = $true)][ValidateSet('Model', 'Component')][string] $Kind)
    $s = $script:FastLlmUiFluentStrings
    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = New-Object System.Windows.Thickness(0, 0, 0, 8)
    $col1 = New-Object System.Windows.Controls.ColumnDefinition
    $col1.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
    $col2 = New-Object System.Windows.Controls.ColumnDefinition
    $col2.Width = [System.Windows.GridLength]::Auto
    [void] $grid.ColumnDefinitions.Add($col1)
    [void] $grid.ColumnDefinitions.Add($col2)
    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $Text
    $label.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $label.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $remove = New-Object System.Windows.Controls.Button
    $remove.SetResourceReference([System.Windows.FrameworkElement]::StyleProperty, 'FastLlm.ButtonStyle')
    $remove.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0)
    $remove.Content = ConvertTo-FastLlmUiAccessText -Text ([string] $script:FastLlmUiFluentModelsText.Remove) -UseMnemonic $false
    $remove.Tag = $Id
    $remove.IsEnabled = $Enabled
    [System.Windows.Automation.AutomationProperties]::SetName($remove, ([string] $s.RemoveFormat) -f $Name)
    [System.Windows.Controls.ToolTipService]::SetShowOnDisabled($remove, $true)
    if (-not $Enabled -and $Reason -ne '') {
        $remove.ToolTip = $Reason
        [System.Windows.Automation.AutomationProperties]::SetHelpText($remove, $Reason)
    }
    if ($Kind -ceq 'Model') { $remove.Add_Click({ param($sender, $routed) Invoke-FastLlmUiFluentModelsRemoveModel -Sender $sender }) }
    else { $remove.Add_Click({ param($sender, $routed) Invoke-FastLlmUiFluentModelsRemoveComponent -Sender $sender }) }
    [System.Windows.Controls.Grid]::SetColumn($remove, 1)
    [void] $grid.Children.Add($label)
    [void] $grid.Children.Add($remove)
    return $grid
}

# A one-line TextBlock for an empty list.
function New-FastLlmUiFluentModelsEmptyLine {
    [CmdletBinding()] param([Parameter(Mandatory = $true)][string] $Text)
    $block = New-Object System.Windows.Controls.TextBlock
    $block.Text = $Text
    $block.TextWrapping = [System.Windows.TextWrapping]::Wrap
    return $block
}

# Rebuilds the downloaded-models list (the view's refresh target, so a Remove's queued rebuild lands here). It makes the view first, then renders the model.
function Update-FastLlmUiFluentModelsList {
    [CmdletBinding()] param()
    $f = $script:FastLlmUiFluent
    $e = $f['Els']
    $m = $f['Models']
    $s = $script:FastLlmUiFluentStrings
    $t = $script:FastLlmUiFluentModelsText
    $view = $null
    $rootError = ''
    try { $view = New-FastLlmUiFluentModelsView }
    catch { $rootError = [string] $_.Exception.Message }
    if ($null -ne $view) { $model = Get-FastLlmUiFluentModelsListModel -Root ([string] $view['root']) -File ([string] $view['file']) -Catalog $catalog }
    else { $model = Get-FastLlmUiFluentModelsListModel -Catalog $catalog -RootError $rootError }
    $m['Folder'] = [string] $script:pathBox.Text
    if ([string] $model.message -ne '') { $m['Message'].Text = [string] $model.message }
    $e['ModelsFreeText'].Text = [string] $model.freeText
    $leftoverButton = $e['ModelsLeftoverButton']
    $leftoverButton.Tag = @($model.leftoverNames)
    $leftoverButton.IsEnabled = [bool] $model.leftoverEnabled
    if ([bool] $model.leftoverEnabled) {
        $leftoverButton.ToolTip = $null
        [System.Windows.Automation.AutomationProperties]::SetHelpText($leftoverButton, '')
    }
    else {
        $leftoverButton.ToolTip = [string] $s.WhyNoLeftovers
        [System.Windows.Automation.AutomationProperties]::SetHelpText($leftoverButton, [string] $s.WhyNoLeftovers)
    }
    if ($null -ne $view) { $view['leftoverText'] = [string] $model.leftoverText }
    $panel = $e['ModelsModelRows']
    $panel.Children.Clear()
    $rows = @($model.rows)
    if ($rows.Count -eq 0) { [void] $panel.Children.Add((New-FastLlmUiFluentModelsEmptyLine -Text ([string] $t.NoModels))) }
    foreach ($row in $rows) {
        [void] $panel.Children.Add((New-FastLlmUiFluentModelsRow -Text ([string] $row.text) -Id ([string] $row.id) -Name ([string] $row.name) -Enabled ([bool] $row.removable) -Reason ([string] $row.inUseReason) -Kind 'Model'))
    }
}

# Rebuilds the engine-component list (the components view's refresh target).
function Update-FastLlmUiFluentComponentsList {
    [CmdletBinding()] param()
    $f = $script:FastLlmUiFluent
    $e = $f['Els']
    $m = $f['Models']
    $t = $script:FastLlmUiFluentModelsText
    $view = $null
    $rootError = ''
    try { $view = New-FastLlmUiFluentComponentsView }
    catch { $rootError = [string] $_.Exception.Message }
    if ($null -ne $view) { $model = Get-FastLlmUiFluentComponentsListModel -Root ([string] $view['root']) -File ([string] $view['file']) }
    else { $model = Get-FastLlmUiFluentComponentsListModel -RootError $rootError }
    if ([string] $model.message -ne '') { $m['ComponentsMessage'].Text = [string] $model.message }
    $panel = $e['ModelsComponentRows']
    $panel.Children.Clear()
    $rows = @($model.rows)
    if ($rows.Count -eq 0) { [void] $panel.Children.Add((New-FastLlmUiFluentModelsEmptyLine -Text ([string] $t.NoComponents))) }
    foreach ($row in $rows) {
        [void] $panel.Children.Add((New-FastLlmUiFluentModelsRow -Text ([string] $row.text) -Id ([string] $row.id) -Name ([string] $row.id) -Enabled $true -Kind 'Component'))
    }
}

# Collects the page's named elements, sets its static text and names, and attaches its plain handlers. Every name is Models-prefixed.
function Initialize-FastLlmUiFluentModels {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Page, [Parameter(Mandatory = $true)][hashtable] $Els)
    $s = $script:FastLlmUiFluentStrings
    $t = $script:FastLlmUiFluentModelsText
    Add-FastLlmUiFluentElements -Els $Els -Root $Page -Names @('ModelsTitle', 'ModelsStatusText', 'ModelsStartWithHeading', 'ModelsModelLabel', 'ModelsModelBox', 'ModelsChooseButton',
        'ModelsStartOptions', 'ModelsStartOptionsHeader', 'ModelsFolderLabel', 'ModelsFolderBox', 'ModelsContextLabel', 'ModelsContextRow', 'ModelsContextBox', 'ModelsContextUp',
        'ModelsContextDown', 'ModelsBarLabel', 'ModelsBarBox', 'ModelsSwitchHeading', 'ModelsSwitchIntro', 'ModelsSwitchLine', 'ModelsSwitchList', 'ModelsSwitchMessage',
        'ModelsSwitchNow', 'ModelsDownloadedSection', 'ModelsDownloadedHeading', 'ModelsModelRows', 'ModelsFreeText', 'ModelsLeftoverButton', 'ModelsDownloadedMessage',
        'ModelsComponentsSection', 'ModelsComponentsHeading', 'ModelsComponentRows', 'ModelsComponentsMessage')
    $Els['ModelsTitle'].Text = [string] $s.NavModels
    $Els['ModelsStartWithHeading'].Text = [string] $s.ModelsStartWith
    $Els['ModelsStartOptionsHeader'].Text = [string] $s.ModelsStartOptions
    $Els['ModelsSwitchHeading'].Text = [string] $t.SwitchTitle
    $Els['ModelsSwitchIntro'].Text = [string] $t.SwitchIntro
    $Els['ModelsDownloadedHeading'].Text = [string] $t.DownloadedModels
    $Els['ModelsComponentsHeading'].Text = [string] $s.ModelsComponents
    # Each input has its name and its label from one string.
    Set-FastLlmUiFluentConnectInputName -Box $Els['ModelsModelBox'] -Label $Els['ModelsModelLabel'] -Text ([string] $t.Model)
    Set-FastLlmUiFluentConnectInputName -Box $Els['ModelsFolderBox'] -Label $Els['ModelsFolderLabel'] -Text ([string] $t.Folder)
    Set-FastLlmUiFluentConnectInputName -Box $Els['ModelsContextBox'] -Label $Els['ModelsContextLabel'] -Text ([string] $t.Context)
    Set-FastLlmUiFluentConnectInputName -Box $Els['ModelsBarBox'] -Label $Els['ModelsBarLabel'] -Text ([string] $t.Bar)
    Set-FastLlmUiFluentConnectInputName -Box $Els['ModelsSwitchList'] -Label $Els['ModelsSwitchHeading'] -Text ([string] $t.SwitchTitle)
    $Els['ModelsSwitchNow'].Content = ConvertTo-FastLlmUiAccessText -Text ([string] $t.SwitchNow) -UseMnemonic $false
    # The leftover caption is the page's longest button text: it wraps inside the button at large text instead of clipping.
    $leftoverCaption = New-Object System.Windows.Controls.AccessText
    $leftoverCaption.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $leftoverCaption.Text = ConvertTo-FastLlmUiAccessText -Text ([string] $t.RemoveLeftovers) -UseMnemonic $false
    $Els['ModelsLeftoverButton'].Content = $leftoverCaption
    # A button names itself from string content only; with an AccessText content it needs its name set (the caption, as on every other button).
    [System.Windows.Automation.AutomationProperties]::SetName($Els['ModelsLeftoverButton'], [string] $t.RemoveLeftovers)
    $Els['ModelsSwitchNow'].IsEnabled = $false
    $Els['ModelsLeftoverButton'].IsEnabled = $false
    # The spin buttons: icon glyphs (drawn, not read), named, never tab stops (their style).
    $icon = New-Object System.Windows.Media.FontFamily('Segoe Fluent Icons, Segoe MDL2 Assets')
    $Els['ModelsContextUp'].Content = New-FastLlmUiFluentGlyphText 0xE70E
    $Els['ModelsContextDown'].Content = New-FastLlmUiFluentGlyphText 0xE70D
    [System.Windows.Automation.AutomationProperties]::SetName($Els['ModelsContextUp'], [string] $s.SpinUp)
    [System.Windows.Automation.AutomationProperties]::SetName($Els['ModelsContextDown'], [string] $s.SpinDown)
    foreach ($name in 'ModelsChooseButton', 'ModelsModelBox', 'ModelsFolderBox', 'ModelsContextBox', 'ModelsBarBox', 'ModelsLeftoverButton') {
        [System.Windows.Controls.ToolTipService]::SetShowOnDisabled($Els[$name], $true)
    }
    # The three message lines are Label adapters (UseMnemonic keeps the WinForms default, as the classic dialogs' labels do); a result written with a plain .Text
    # is announced once through the polite live region.
    $messageAdapter = New-FastLlmUiAdapter -Kind Label -Name 'modelsMessage'
    $componentsAdapter = New-FastLlmUiAdapter -Kind Label -Name 'componentsMessage'
    $switchAdapter = New-FastLlmUiAdapter -Kind Label -Name 'switchMessage'
    $switchAdapter.UseMnemonic = $false
    Connect-FastLlmUiFluentControl -Adapter $messageAdapter -Element $Els['ModelsDownloadedMessage'] -Mode 'TextBlock'
    Connect-FastLlmUiFluentControl -Adapter $componentsAdapter -Element $Els['ModelsComponentsMessage'] -Mode 'TextBlock'
    Connect-FastLlmUiFluentControl -Adapter $switchAdapter -Element $Els['ModelsSwitchMessage'] -Mode 'TextBlock'
    $messageAdapter.Add_TextChanged({ param($sender, $routed) Send-FastLlmUiFluentLiveRegion -Element $script:FastLlmUiFluent['Els']['ModelsDownloadedMessage'] })
    $componentsAdapter.Add_TextChanged({ param($sender, $routed) Send-FastLlmUiFluentLiveRegion -Element $script:FastLlmUiFluent['Els']['ModelsComponentsMessage'] })
    $switchAdapter.Add_TextChanged({ param($sender, $routed) Send-FastLlmUiFluentLiveRegion -Element $script:FastLlmUiFluent['Els']['ModelsSwitchMessage'] })
    $Els['ModelsSwitchList'].Add_SelectionChanged({ param($sender, $routed) Invoke-FastLlmUiFluentModelsSwitchSelect })
    $Els['ModelsSwitchNow'].Add_Click({ param($sender, $routed) Invoke-FastLlmUiFluentModelsSwitchNow })
    $Els['ModelsLeftoverButton'].Add_Click({ param($sender, $routed) Invoke-FastLlmUiFluentModelsRemoveLeftovers })
    $Els['ModelsContextUp'].Add_Click({ param($sender, $routed) Invoke-FastLlmUiFluentModelsSpin -Direction 'Up' })
    $Els['ModelsContextDown'].Add_Click({ param($sender, $routed) Invoke-FastLlmUiFluentModelsSpin -Direction 'Down' })
    # A folder edit commits (Enter or focus loss, changed text only): both lists are read again from the new folder.
    $Els['ModelsFolderBox'].Add_KeyDown({ param($sender, $keyArgs) if ($keyArgs.Key -eq [System.Windows.Input.Key]::Return) { Invoke-FastLlmUiFluentModelsFolderCommit } })
    $Els['ModelsFolderBox'].Add_LostKeyboardFocus({ param($sender, $routed) Invoke-FastLlmUiFluentModelsFolderCommit })
    $f = $script:FastLlmUiFluent
    $f['Models'] = @{ Picker = $null; SwitchWas = $false; Picked = $false; Folder = ''; Message = $messageAdapter; ComponentsMessage = $componentsAdapter; SwitchMessage = $switchAdapter }
    return $Els
}

# Models' entry in the page registry. Its status line is the card's composed text, announced only while Models is the current page.
function Register-FastLlmUiFluentModelsPage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Page, [Parameter(Mandatory = $true)][hashtable] $Els)
    Register-FastLlmUiFluentPage -Id 'Models' -Element $Page -Nav 'NavModels' -Status $Els['ModelsStatusText'] -Enter 'Enter-FastLlmUiFluentModels' -Leave 'Exit-FastLlmUiFluentModels' -Update 'Update-FastLlmUiFluentModels'
}

# Opening the page does what the three dialogs do when they open: the two lists, and the switch picker (computed once, here).
function Enter-FastLlmUiFluentModels {
    [CmdletBinding()] param()
    try {
        $m = $script:FastLlmUiFluent['Models']
        $m['Message'].Text = ''
        $m['ComponentsMessage'].Text = ''
        $m['SwitchMessage'].Text = ''
        Update-FastLlmUiFluentModelsList
        Update-FastLlmUiFluentComponentsList
        Update-FastLlmUiFluentModelsPicker
        Update-FastLlmUiFluentModels
    }
    catch { ShowFailure $_.Exception.Message }
}

# Leaving the page commits a number edit that is still pending (Enter or focus loss may not have run). It never refuses.
function Exit-FastLlmUiFluentModels {
    [CmdletBinding()] param()
    $commit = $script:contextBox.__state['CommitEdit']
    if ($null -ne $commit) { $null = & $commit '' }
}

# The switch picker, computed when the page opens and on the availability edge of the Switch button, never on an ordinary tick. The two statements are
# ShowUiSwitchPicker's, with the source root in place of $PSScriptRoot; the call is made only while the Switch button is enabled, otherwise the list is empty.
function Update-FastLlmUiFluentModelsPicker {
    [CmdletBinding()] param()
    $f = $script:FastLlmUiFluent
    $e = $f['Els']
    $m = $f['Models']
    $enabled = [bool] $script:switchButton.Enabled
    $m['SwitchWas'] = $enabled
    $m['Picked'] = $false
    $picker = [pscustomobject] @{ items = @(); message = '' }
    if ([bool] $script:switchButton.Enabled) {
        $status=$null;try{$status=Get-FastLlmStatus -InstallRoot $script:installPath}catch{}
        $picker=Get-FastLlmUiSwitchPickerModel -InstallRoot $script:installPath -CatalogPath (Join-Path $script:FastLlmUiFluentSourceRoot 'config/catalog.json') -Status $status
        # The picker's message is written only when the picker is computed: a switch-off edge (a successful Switch disables the button) must not wipe the request's result.
        $m['SwitchMessage'].Text = [string] $picker.message
    }
    $m['Picker'] = $picker
    $list = $e['ModelsSwitchList']
    $list.Items.Clear()
    foreach ($pickerItem in @($picker.items)) { $null = $list.Items.Add([string] $pickerItem.text) }
    Update-FastLlmUiFluentModelsSwitchState
}

# The Switch button's state from the stored picker and the list selection (no store read): the Switch button of the window, the selected row, and not yet picked.
function Update-FastLlmUiFluentModelsSwitchState {
    [CmdletBinding()] param()
    $f = $script:FastLlmUiFluent
    $e = $f['Els']
    $m = $f['Models']
    $picker = $m['Picker']
    $enabled = $false
    if ($null -ne $picker -and [bool] $script:switchButton.Enabled -and -not [bool] $m['Picked']) {
        $selectedId = $null
        $index = [int] $e['ModelsSwitchList'].SelectedIndex
        if ($index -ge 0) { $selectedId = [string] @($picker.items)[$index].id }
        $enabled = [bool] (Get-FastLlmUiSwitchPickerButtonState -Items $picker.items -SelectedId $selectedId).enabled
    }
    if ($e['ModelsSwitchNow'].IsEnabled -ne $enabled) { $e['ModelsSwitchNow'].IsEnabled = $enabled }
}

function Invoke-FastLlmUiFluentModelsSwitchSelect {
    [CmdletBinding()] param()
    Update-FastLlmUiFluentModelsSwitchState
}

# Switch: the same request function the dialog's button calls. A success shows its text on the status line and locks the button until the next computation.
function Invoke-FastLlmUiFluentModelsSwitchNow {
    [CmdletBinding()] param()
    $f = $script:FastLlmUiFluent
    $e = $f['Els']
    $m = $f['Models']
    $picker = $m['Picker']
    if ($null -eq $picker) { return }
    $selectedId = $null
    $index = [int] $e['ModelsSwitchList'].SelectedIndex
    if ($index -ge 0) { $selectedId = [string] @($picker.items)[$index].id }
    $outcome=Invoke-FastLlmUiSwitchPick -InstallRoot $script:installPath -CatalogPath (Join-Path $script:FastLlmUiFluentSourceRoot 'config/catalog.json') -Items $picker.items -ModelId $selectedId
    $m['SwitchMessage'].Text = [string] $outcome.text
    if ($outcome.ok) {
        $script:statusLabel.Text = [string] $outcome.text
        $m['Picked'] = $true
    }
    Update-FastLlmUiFluentModelsSwitchState
}

# The Remove buttons call today's functions, with today's shapes.
function Invoke-FastLlmUiFluentModelsRemoveModel {
    [CmdletBinding()] param([Parameter(Mandatory = $true)] $Sender)
    RemoveModelFromWindow ([string] $Sender.Tag)
}

function Invoke-FastLlmUiFluentModelsRemoveLeftovers {
    [CmdletBinding()] param()
    RemoveLeftoversFromWindow
}

function Invoke-FastLlmUiFluentModelsRemoveComponent {
    [CmdletBinding()] param([Parameter(Mandatory = $true)] $Sender)
    RemoveComponentFromWindow ([string] $Sender.Tag)
}

# A spin button steps the context box through the clamp and the step function, by the commit block the Number binding keeps on the adapter.
function Invoke-FastLlmUiFluentModelsSpin {
    [CmdletBinding()] param([Parameter(Mandatory = $true)][ValidateSet('Up', 'Down')][string] $Direction)
    $commit = $script:contextBox.__state['CommitEdit']
    if ($null -ne $commit) { $null = & $commit $Direction }
}

# A committed folder edit with changed text reads both lists again.
function Invoke-FastLlmUiFluentModelsFolderCommit {
    [CmdletBinding()] param()
    $m = $script:FastLlmUiFluent['Models']
    if ([string] $script:pathBox.Text -ceq [string] $m['Folder']) { return }
    Update-FastLlmUiFluentModelsList
    Update-FastLlmUiFluentComponentsList
}

# Once per tick while Models shows: every disabled input says why (written on change only), the picker is computed again only on the Switch button's edge,
# and the Switch button follows the stored picker. No store is read here.
function Update-FastLlmUiFluentModels {
    [CmdletBinding()] param()
    $f = $script:FastLlmUiFluent
    $e = $f['Els']
    $keys = $f['Keys']
    $m = $f['Models']
    $snapshot = GetUiStateSnapshot ([bool]($script:child -or $script:vcBroker -or $script:updateRun))
    foreach ($row in (Get-FastLlmUiFluentModelsReasonRows)) {
        $adapter = Get-Variable -Name ([string] $row.Adapter) -Scope Script -ValueOnly
        $code = ''
        if (-not [bool] $adapter.Enabled) { $code = [string] (Get-FastLlmUiGreyedReason -Action ([string] $row.Action) -Snapshot $snapshot) }
        $key = 'ModelsWhy:' + [string] $row.Element
        if ($keys[$key] -ceq $code) { continue }
        $keys[$key] = $code
        $element = $e[[string] $row.Element]
        $text = Get-FastLlmUiFluentModelsReasonText -Code $code
        if ($text -ne '') {
            $element.ToolTip = $text
            [System.Windows.Automation.AutomationProperties]::SetHelpText($element, $text)
        }
        else {
            $element.ToolTip = $null
            [System.Windows.Automation.AutomationProperties]::SetHelpText($element, '')
        }
    }
    if ([bool] $script:switchButton.Enabled -ne [bool] $m['SwitchWas']) { Update-FastLlmUiFluentModelsPicker }
    Update-FastLlmUiFluentModelsSwitchState
}
