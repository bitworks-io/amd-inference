#requires -Version 5.1
# Off-screen WPF render and accessibility checks for the Fluent window pages: a clean sample page across a 40-case matrix (3 themes, scales,
# text sizes, window sizes, up to Windows' 225% text size), and one negative page per check to prove each one fires. Windows only; elsewhere it skips.
# PNGs go to FASTLLM_RENDER_DIR, else $env:RUNNER_TEMP\fastllm-fluent-render, else the temp folder. No window is shown and no message pump runs.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
$script:checks=0
$script:failures=New-Object System.Collections.ArrayList
function Check([bool]$Condition,[string]$Message){
    if($Condition){$script:checks++;Write-Host "PASS: $Message"}
    else{[void]$script:failures.Add($Message);Write-Host "FAIL: $Message"}
}

. (Join-Path $root 'src/FastLlm.UiTheme.ps1')
. (Join-Path $root 'src/FastLlm.UiWindow.ps1')
. (Join-Path $root 'src/FastLlm.UiXaml.ps1')
. (Join-Path $root 'tests/helpers/UiRenderHarness.ps1')

# Pure checks, any OS: they catch a matrix that is wrapped or shaped wrongly before the Windows-only part.
$matrix=@(Get-UiRenderMatrix)
$runStart=[DateTime]::UtcNow.AddSeconds(-2)
Check ($matrix.Count -eq 40) 'the matrix has 40 cases'
Check (@($matrix|Where-Object{$_ -is [hashtable]}).Count -eq 40) 'every matrix case is one hashtable'
Check (@($matrix|Where-Object{$_.theme -is [string] -and $_.scale -is [double] -and $_.textScale -is [double]}).Count -eq 40) 'every case has a single theme, scale and text scale'
Check (@($matrix|ForEach-Object{"$($_.theme)|$($_.scale)|$($_.textScale)|$($_.width)x$($_.height)"}|Sort-Object -Unique).Count -eq 40) 'the 40 cases are all different'
$bigText=@($matrix|Where-Object{[double]$_.textScale -eq 2.25})
Check ($bigText.Count -eq 1 -and $bigText[0].theme -ceq 'light' -and $bigText[0].scale -eq 1.0 -and $bigText[0].width -eq 640) 'the matrix has the one light 225% text case'
Check ((Remove-UiAccessKey '_Name') -ceq 'Name') 'an access key underscore is stripped'
Check ((Remove-UiAccessKey 'Na_me') -ceq 'Name') 'an access key underscore inside the text is stripped'
Check ((Remove-UiAccessKey 'a__b') -ceq 'a_b') 'a doubled underscore is one literal underscore'
Check ((Remove-UiAccessKey '__Name') -ceq '_Name') 'a doubled underscore at the start is kept as one'
Check ((Remove-UiAccessKey 'Plain') -ceq 'Plain') 'text without underscores is unchanged'
Check ((Remove-UiAccessKey 'a_b_c') -ceq 'ab_c') 'only the first single underscore is the access key'
Check ((Remove-UiAccessKey '_a__b') -ceq 'a_b') 'a key underscore plus a doubled underscore'
Check ((Remove-UiAccessKey 'a__b_c') -ceq 'a_bc') 'a doubled underscore, then the first single one is the key'
Check ((Remove-UiAccessKey 'x_') -ceq 'x_') 'a trailing lone underscore is literal'
$hcPal=Get-UiRenderHighContrastPalette
Check (@($hcPal.Values|Sort-Object -Unique).Count -eq 4) 'the high-contrast palette has four distinct colours'
# The x:Name values of a markup string that live in the page's own namescope: elements inside a ControlTemplate, DataTemplate, ItemsPanelTemplate,
# HierarchicalDataTemplate or Style (their Setters included) have a namescope of their own, which the page's FindName cannot reach.
function Get-UiPageElementNames([string]$Xaml){
    $xamlNs='http://schemas.microsoft.com/winfx/2006/xaml'
    $skip=@('ControlTemplate','DataTemplate','ItemsPanelTemplate','HierarchicalDataTemplate','Style')
    $doc=New-Object System.Xml.XmlDocument
    $doc.LoadXml($Xaml)
    $names=New-Object System.Collections.ArrayList
    $walk=$null
    $walk={
        param($node)
        if($node.NodeType -ne [System.Xml.XmlNodeType]::Element){return}
        $local=[string]$node.LocalName
        if($skip -contains $local){return}
        $nm=$node.GetAttribute('Name',$xamlNs)
        if(-not [string]::IsNullOrEmpty($nm)){[void]$names.Add([string]$nm)}
        foreach($c in $node.ChildNodes){& $walk $c}
    }
    & $walk $doc.DocumentElement
    return ,@($names.ToArray())
}
# Pure check on any OS, from the shell file's own markup text: the page names are found and the template part names are not.
$shellText=[IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.UiFluentShell.ps1'))
$shellMatch=[regex]::Match($shellText,"(?s)\`$script:FastLlmUiXaml\['FastLlm\.Shell'\]\s*=\s*@'\r?\n(.*?)\r?\n'@")
Check $shellMatch.Success 'the shell markup was found in the shell file'
$pageNames=Get-UiPageElementNames $shellMatch.Groups[1].Value
Check (($pageNames -contains 'PaneColumn') -and ($pageNames -contains 'NavList') -and ($pageNames -contains 'MessageScroll')) "the page names include PaneColumn, NavList and MessageScroll (got $($pageNames -join ', '))"
$partHits=@('Bd','Hd','Arrow','Body','Bar')|Where-Object{$pageNames -contains $_}
Check (@($partHits).Count -eq 0) "the page names hold no template part name (found: $(@($partHits) -join ', '))"
# The Models page (pure, any OS): every x:Name of its registered markup is in the hand list Initialize-FastLlmUiFluentModels collects into Els, and the list holds no
# other name, so the stand-in (which collects the names the same way, through FindName) and the window see the same elements.
$modelsText=[IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.UiFluentModels.ps1'))
$modelsMatch=[regex]::Match($modelsText,"(?s)\`$script:FastLlmUiXaml\['FastLlm\.Models'\]\s*=\s*@'\r?\n(.*?)\r?\n'@")
Check $modelsMatch.Success 'the Models markup was found in the Models file'
$listMatch=[regex]::Match($modelsText,'(?s)Add-FastLlmUiFluentElements -Els \$Els -Root \$Page -Names @\((.*?)\)')
Check $listMatch.Success 'the Models element name list was found in Initialize-FastLlmUiFluentModels'
if($modelsMatch.Success -and $listMatch.Success){
    $modelsRaw=Get-UiPageElementNames $modelsMatch.Groups[1].Value
    $modelsPageNames=@($modelsRaw|Sort-Object -Unique)
    $listedNames=@([regex]::Matches($listMatch.Groups[1].Value,"'([A-Za-z0-9]+)'")|ForEach-Object{$_.Groups[1].Value}|Sort-Object -Unique)
    $notListed=@($modelsPageNames|Where-Object{$listedNames -cnotcontains $_})
    $notInMarkup=@($listedNames|Where-Object{$modelsPageNames -cnotcontains $_})
    Check ($modelsPageNames.Count -ge 30 -and $modelsPageNames.Count -eq @($modelsRaw).Count) "the Models markup has at least 30 distinct page names (got $($modelsPageNames.Count) of $(@($modelsRaw).Count))"
    Check ($notListed.Count -eq 0) "every Models markup name is in the Initialize list (not listed: $($notListed -join ', '))"
    Check ($notInMarkup.Count -eq 0) "the Initialize list names no element that is not in the Models markup (extra: $($notInMarkup -join ', '))"
    Check (@('Bd','Hd','Arrow','Body','Bar'|Where-Object{$modelsPageNames -contains $_}).Count -eq 0) 'the Models page names hold no template part name'
}
if($script:failures.Count -gt 0){throw ('FAIL: '+($script:failures -join '; '))}
$onWindows=($PSVersionTable.PSVersion.Major -le 5) -or [bool](Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue)
if(-not $onWindows){Write-Host 'SKIP: Windows only';exit 0}

# A non-STA host, or a WPF that does not load, fails loudly; it never skips.
Check ([Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA') 'runs on an STA thread'
$interop=$false
try{$interop=[bool](Initialize-FastLlmUiWindowInterop -SourceRoot $root)}catch{Write-Host ('FAIL: interop threw: '+$_.Exception.Message)}
if(-not $interop){
    try{Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase -ErrorAction Stop}catch{Write-Host ('INFO: interop load error: '+$_.Exception.ToString())}
    try{Add-Type -Path (Join-Path $root 'src/WindowsFluentWindow.cs') -ErrorAction Stop}catch{Write-Host ('INFO: interop load error: '+$_.Exception.ToString())}
}
Check $interop 'WPF and the interop load'
if($script:failures.Count -gt 0){throw ('FAIL: '+($script:failures -join '; '))}

# Pin Remove-UiAccessKey against WPF's own rule, found by reflection (CI only; the log shows the real rule on a mismatch).
$wpfRule=@([System.Windows.Controls.AccessText].GetMethods('NonPublic,Static')|Where-Object{$_.Name -ceq 'RemoveAccessKeyMarker' -and @($_.GetParameters()).Count -eq 1 -and $_.GetParameters()[0].ParameterType -eq [string]})
if($wpfRule.Count -ne 1){
    $names=(@([System.Windows.Controls.AccessText].GetMethods('NonPublic,Static')|Where-Object{$_.Name -match 'Access'}|ForEach-Object{$_.Name}|Sort-Object -Unique) -join ', ')
    Check $false ("AccessText.RemoveAccessKeyMarker (one string parameter) found exactly once (found $($wpfRule.Count); NonPublic static AccessText methods with 'Access': $names)")
}else{
    foreach($t in '_Name','Na_me','a__b','__Name','Plain','a_b_c','_a__b','a__b_c','x_','_','__'){
        $want=[string]$wpfRule[0].Invoke($null,@([string]$t))
        $got=Remove-UiAccessKey $t
        Check ($got -ceq $want) "Remove-UiAccessKey matches WPF for '$t' (ours '$got', WPF '$want')"
    }
    # Product round trip: WinForms caption -> adapter conversion -> WPF access text -> the text WinForms shows.
    . (Join-Path $root 'src/FastLlm.UiFluentAdapter.ps1')
    $trips=@(
        @{text='Install && start';mn=$true;shown='Install & start'},
        @{text='&Save a_b';mn=$true;shown='Save a_b'},
        @{text='a_b &Save';mn=$true;shown='a_b Save'},
        @{text='model_a_b';mn=$false;shown='model_a_b'},
        @{text='a & b';mn=$false;shown='a & b'})
    foreach($trip in $trips){
        $conv=ConvertTo-FastLlmUiAccessText -Text $trip.text -UseMnemonic $trip.mn
        $shown=[string]$wpfRule[0].Invoke($null,@([string]$conv))
        Check ($shown -ceq $trip.shown) "access text round trip for '$($trip.text)' (UseMnemonic $($trip.mn)): converted '$conv', WPF shows '$shown', want '$($trip.shown)'"
    }
}
if($script:failures.Count -gt 0){throw ('FAIL: '+($script:failures -join '; '))}

$script:FastLlmUiXaml['Test.Sample']=@'
<StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="16" UseLayoutRounding="True">
  <TextBlock x:Name="TitleText" Text="Fluent harness check" TextWrapping="Wrap" FontSize="{DynamicResource FastLlm.TitleSize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}" Margin="0,0,0,8"/>
  <TextBlock x:Name="BodyText" TextWrapping="Wrap" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextSecondaryBrush}" Margin="0,0,0,12" Text="This sample page exists only to exercise the layout and accessibility checks. It holds a heading, a paragraph that wraps over several lines, a labelled text box, a check box and two buttons, one of them an icon button with a spoken name."/>
  <TextBlock x:Name="NameLabel" Text="Example field" TextWrapping="Wrap" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}" Margin="0,0,0,4"/>
  <TextBox x:Name="NameBox" AutomationProperties.Name="Example field" AutomationProperties.LabeledBy="{x:Reference NameLabel}" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}" Background="{DynamicResource FastLlm.CardBrush}" BorderBrush="{DynamicResource FastLlm.ControlStrongStrokeBrush}" Margin="0,0,0,12"/>
  <CheckBox x:Name="OptionBox" Content="Example option" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}" Margin="0,0,0,12"/>
  <StackPanel Orientation="Vertical">
    <Button x:Name="AccentButton" Content="Example action" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextOnAccentBrush}" Background="{DynamicResource FastLlm.AccentFillBrush}" HorizontalAlignment="Left" Padding="12,6,12,6" Margin="0,0,0,8"/>
    <Button x:Name="IconButton" Width="32" Height="32" HorizontalAlignment="Left" FontFamily="{DynamicResource FastLlm.IconFont}" FontSize="16" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}" Background="{DynamicResource FastLlm.CardBrush}" Content="&#xE8C8;" AutomationProperties.Name="Copy example" ToolTip="Copy example"/>
  </StackPanel>
</StackPanel>
'@

$script:FastLlmUiXaml['Test.Overlap']=@'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="16">
  <Button x:Name="BtnA" Content="First example" HorizontalAlignment="Left" VerticalAlignment="Top" Width="160" Height="32" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}"/>
  <Button x:Name="BtnB" Content="Second example" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="40,10,0,0" Width="160" Height="32" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}"/>
</Grid>
'@

$script:FastLlmUiXaml['Test.Clipped']=@'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="16">
  <TextBlock x:Name="ClippedText" Width="60" HorizontalAlignment="Left" VerticalAlignment="Top" TextWrapping="NoWrap" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}" Text="This text is much too long to fit in sixty device independent pixels."/>
</Grid>
'@

$script:FastLlmUiXaml['Test.ClippedButton']=@'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="16">
  <Button x:Name="NarrowButton" Content="A label too long for this button" Width="60" HorizontalAlignment="Left" VerticalAlignment="Top" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}"/>
</Grid>
'@

$script:FastLlmUiXaml['Test.Unnamed']=@'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="16">
  <Button x:Name="NoNameButton" Width="32" Height="32" HorizontalAlignment="Left" VerticalAlignment="Top" FontFamily="{DynamicResource FastLlm.IconFont}" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}" Content="&#xE8C8;"/>
</Grid>
'@

$script:FastLlmUiXaml['Test.TabOrder']=@'
<StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="16">
  <TextBox x:Name="UpperBox" TabIndex="1" AutomationProperties.Name="Upper example" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}" Margin="0,0,0,8"/>
  <TextBox x:Name="LowerBox" TabIndex="0" AutomationProperties.Name="Lower example" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}"/>
</StackPanel>
'@

$script:FastLlmUiXaml['Test.Outside']=@'
<Canvas xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Height="60">
  <Border x:Name="FarBox" Canvas.Left="2000" Canvas.Top="10" Width="50" Height="20" Background="{DynamicResource FastLlm.AccentFillBrush}"/>
</Canvas>
'@

$script:FastLlmUiXaml['Test.UnnamedTextBox']=@'
<StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="16">
  <TextBox x:Name="BareBox" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}"/>
</StackPanel>
'@

$script:FastLlmUiXaml['Test.LabeledByOnly']=@'
<StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="16">
  <TextBlock x:Name="OnlyLabel" Text="Only label" TextWrapping="Wrap" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}" Margin="0,0,0,4"/>
  <TextBox x:Name="OnlyBox" AutomationProperties.LabeledBy="{x:Reference OnlyLabel}" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}"/>
</StackPanel>
'@

$script:FastLlmUiXaml['Test.LabelMismatch']=@'
<StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="16">
  <TextBlock x:Name="MisLabel" Text="Visible text" TextWrapping="Wrap" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}" Margin="0,0,0,4"/>
  <TextBox x:Name="MisBox" AutomationProperties.Name="Other text" AutomationProperties.LabeledBy="{x:Reference MisLabel}" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}"/>
</StackPanel>
'@

# A viewer inside the page: its content below the fold is scrolled, not outside or clipped (the rules measure against the nearest scroll content).
# Only the element beyond the viewer's own width is a problem.
$script:FastLlmUiXaml['Test.Nested']=@'
<StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="16">
  <ScrollViewer x:Name="InnerScroll" Height="60" Focusable="False" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
    <StackPanel>
      <TextBlock x:Name="UpperText" Text="Inside the inner viewer." TextWrapping="Wrap" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}"/>
      <Border Height="700"/>
      <TextBlock x:Name="DeepText" Text="Text far below the inner fold. It is scrolled, not clipped." TextWrapping="Wrap" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}"/>
      <Button x:Name="DeepButton" Content="Deep action" HorizontalAlignment="Left" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}"/>
      <Canvas Height="20">
        <Border x:Name="InnerFar" Canvas.Left="2000" Canvas.Top="0" Width="50" Height="20" Background="{DynamicResource FastLlm.AccentFillBrush}"/>
      </Canvas>
    </StackPanel>
  </ScrollViewer>
</StackPanel>
'@

# Two-column tab order with the pane as a region: pane first is clean, a content stop before the pane is flagged.
$script:FastLlmUiXaml['Test.RegionGood']=@'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="16">
  <Grid.ColumnDefinitions><ColumnDefinition Width="200"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
  <StackPanel x:Name="PaneRoot" Grid.Column="0"><Button x:Name="PaneButton" Content="Pane item" TabIndex="0" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}"/></StackPanel>
  <Button x:Name="ContentButton" Grid.Column="1" Content="Content item" TabIndex="1" HorizontalAlignment="Left" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}"/>
</Grid>
'@

$script:FastLlmUiXaml['Test.RegionBad']=@'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="16">
  <Grid.ColumnDefinitions><ColumnDefinition Width="200"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
  <StackPanel x:Name="PaneRoot" Grid.Column="0"><Button x:Name="PaneButton" Content="Pane item" TabIndex="1" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}"/></StackPanel>
  <Button x:Name="ContentButton" Grid.Column="1" Content="Content item" TabIndex="0" HorizontalAlignment="Left" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}"/>
</Grid>
'@

$out=$env:FASTLLM_RENDER_DIR
if([string]::IsNullOrEmpty($out)){
    if(-not [string]::IsNullOrEmpty($env:RUNNER_TEMP)){$out=Join-Path $env:RUNNER_TEMP 'fastllm-fluent-render'}
    else{$out=[IO.Path]::GetTempPath()}
}
[void][IO.Directory]::CreateDirectory($out)

$matrix=@(Get-UiRenderMatrix)

# Each negative page shows exactly its own problem.
$neg=@{Overlap='overlap:BtnA:BtnB';Clipped='clipped:ClippedText';ClippedButton='clipped:TextBlock';Unnamed='unnamed:Button';TabOrder='tab-order';Outside='outside:FarBox';UnnamedTextBox='unnamed:TextBox';LabeledByOnly='unnamed:TextBox';LabelMismatch='label-mismatch:MisBox';Nested='outside:InnerFar'}
$base=@{theme='light';scale=[double]1.0;textScale=[double]1.0;width=640;height=480}
foreach($n in 'Overlap','Clipped','ClippedButton','Unnamed','TabOrder','Outside','UnnamedTextBox','LabeledByOnly','LabelMismatch','Nested'){
    $found=@()
    $diag=@()
    try{$res=Invoke-UiRenderCase -Name ('Test.'+$n) -Case $base -OutFolder $out;$found=@($res.problems);$diag=@($res.diagnostics)}catch{$found=@('threw: '+$_.Exception.Message)}
    if($n -ceq 'LabeledByOnly'){
        # The root cause of the cold-page failure, recorded on green runs too: whether the label already had an automation peer.
        $peerState='unknown'
        foreach($d in $diag){if($d -match 'labelPeer=(\w+)'){$peerState=$Matches[1];break}}
        Write-Host ('INFO: render LabeledByOnly labelPeer='+$peerState)
    }
    $diagText=''
    $ok=($found.Count -eq 1 -and $found[0] -ceq $neg[$n])
    if(-not $ok -and $diag.Count -gt 0){$diagText=' | diag: '+($diag -join '; ')}
    Check $ok ("the harness catches $n (expected '"+$neg[$n]+"', got '"+($found -join '; ')+"')"+$diagText)
}

# Regions: a pane on the left whose stops come first is a clean two-column order; a content stop before the pane is flagged.
$regionOk=@();$regionBad=@()
try{$regionOk=@((Invoke-UiRenderCase -Name 'Test.RegionGood' -Case $base -OutFolder $out -TabRegions @('PaneRoot')).problems)}catch{$regionOk=@('threw: '+$_.Exception.Message)}
try{$regionBad=@((Invoke-UiRenderCase -Name 'Test.RegionBad' -Case $base -OutFolder $out -TabRegions @('PaneRoot')).problems)}catch{$regionBad=@('threw: '+$_.Exception.Message)}
Check (@($regionOk|Where-Object{$_ -ceq 'tab-order'}).Count -eq 0 -and $regionOk.Count -eq 0) "a page whose tab order puts the pane region first is clean (got '$($regionOk -join '; ')')"
Check (@($regionBad|Where-Object{$_ -ceq 'tab-order'}).Count -eq 1) "a content stop before the pane is still flagged tab-order (got '$($regionBad -join '; ')')"

$sw=[Diagnostics.Stopwatch]::StartNew()
foreach($case in $matrix){
    $label="$($case.theme) $($case.scale) $($case.textScale) $($case.width)x$($case.height)"
    $r=$null
    try{$r=Invoke-UiRenderCase -Name 'Test.Sample' -Case $case -OutFolder $out}catch{Check $false "sample page renders at ${label}: $($_.Exception.Message)";continue}
    $diagText=''
    if(@($r.diagnostics).Count -gt 0){$diagText=' | diag: '+(@($r.diagnostics) -join '; ')}
    Check (@($r.problems).Count -eq 0) "sample page clean at ${label}: $(@($r.problems) -join '; ')$diagText"
    $real=$false
    if(Test-Path -LiteralPath $r.png){
        $info=Get-UiPngInfo -Path $r.png
        $real=($info.width -eq [int][Math]::Ceiling($case.width*$case.scale)) -and ($info.height -eq [int][Math]::Ceiling($case.height*$case.scale)) -and $info.hasContent
    }
    Check $real "the render is real at $label"
    # Probes: the theme reached the page and every check had something to examine.
    $expTitle=28.0*[double]$case.textScale
    $expBody=14.0*[double]$case.textScale
    Check ($null -ne $r.titleFontSize -and [Math]::Abs([double]$r.titleFontSize-$expTitle) -le 0.01) "title font size follows the text scale at ${label} (got $($r.titleFontSize), want $expTitle)"
    Check ($null -ne $r.bodyFontSize -and [Math]::Abs([double]$r.bodyFontSize-$expBody) -le 0.01) "body font size follows the text scale at ${label} (got $($r.bodyFontSize), want $expBody)"
    $themeArgs=@{Theme=[string]$case.theme;AccentPair=(Get-FastLlmUiAccentPair -Palette $null);TextScale=[double]$case.textScale}
    if($case.theme -ceq 'high-contrast'){
        $expFg=([System.Windows.Media.ColorConverter]::ConvertFromString($hcPal.WindowText)).ToString()
        $darkText=(New-FastLlmUiThemeDictionary -Theme dark -AccentPair (Get-FastLlmUiAccentPair -Palette $null) -TextScale 1.0)['FastLlm.TextPrimaryBrush'].Color.ToString()
        Check ($expFg -cne $darkText) "the high-contrast probe colour differs from dark TextPrimary at ${label}"
    }else{$expFg=(New-FastLlmUiThemeDictionary @themeArgs)['FastLlm.TextPrimaryBrush'].Color.ToString()}
    Check ([string]$r.titleForeground -ceq $expFg) "title colour is the theme text colour at ${label} (got $($r.titleForeground), want $expFg)"
    Check ($r.labeledInputs -ge 1) "the label-mismatch check saw at least 1 labelled input at ${label} (got $($r.labeledInputs))"
    Check ($r.textBlocks -ge 6) "the clipped check examined at least 6 text blocks at ${label} (got $($r.textBlocks))"
    Check ($r.namedControls -ge 4) "the unnamed check examined at least 4 controls at ${label} (got $($r.namedControls))"
    Check ($r.tabStops -eq 4) "the tab-order check saw 4 tab stops at ${label} (got $($r.tabStops))"
    Check ($r.unmappedRects -eq 0) "no authored element was left unmapped at ${label} (got $($r.unmappedRects))"
}
Write-Host ('INFO: render matrix of {0} cases took {1:N1} s' -f $matrix.Count,$sw.Elapsed.TotalSeconds)

# ---- The Home page of the Fluent window. The page is bound to the real adapters and shown in one card state per case.
# The prepare step does what the shell does for Home (Initialize-FastLlmUiFluentHome, the binding table, one refresh of the card); the orchestration
# the refresh reads (the snapshot, the background status) is a stub here.
Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force
. (Join-Path $root 'tests/helpers/UiControlStatesMatrix.ps1')
. (Join-Path $root 'src/FastLlm.Update.ps1')
. (Join-Path $root 'src/FastLlm.Components.ps1')
. (Join-Path $root 'src/FastLlm.ServingSettings.ps1')
. (Join-Path $root 'src/FastLlm.ConnectInfo.ps1')
. (Join-Path $root 'src/FastLlm.UiFluentAdapter.ps1')
. (Join-Path $root 'src/FastLlm.UiFluentBindings.ps1')
. (Join-Path $root 'src/FastLlm.UiFluentShell.ps1')
Initialize-FastLlmUiFluentAutomation -SourceRoot $root
$script:homeDir=Join-Path ([IO.Path]::GetTempPath()) ('fastllm-render-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $script:homeDir)
$script:InstallRoot=$script:homeDir
$script:installPath=$script:homeDir
$script:homeCatalog=Get-FastLlmCatalog (Join-Path $root 'config/catalog.json')
$script:homeSettings=Read-FastLlmUiSettings -InstallRoot $script:homeDir -AppRoot $root
$script:homeSnap=$null
$script:homeCaseTheme='light'
$script:homeState='not-running'
# What the pages read from the orchestration (fast-llm-ui.ps1): the snapshot, the background run status, the key store and the action availability.
# A Connect case sets the status and the store so the real Get-FastLlmConnectionInfo and Get-FastLlmUiApiKeyRow produce its facts.
$script:renderRunStatus=$null
$script:renderKeyStore=$null
$script:renderFail=''
$script:child=$null
$script:vcBroker=$null
$script:updateRun=$null
function GetUiStateSnapshot([bool]$Busy){return $script:homeSnap}
function GetUiBackgroundRunStatus{return $script:renderRunStatus}
function GetUiApiKeyStore{return $script:renderKeyStore}
function GetUiActionAvailabilityNow([bool]$Busy){return Get-FastLlmUiSnapshotAvailability -Snapshot $script:homeSnap}
function ShowFailure($Message){$script:renderFail=[string]$Message}
function New-HomeSnap([hashtable]$O=@{}){
    $d=@{Busy=$false;UpdateKind='';ChildActive=$false;Step='';RunReady=$false;SideChildActive=$false;VcBrokerActive=$false;PreviewReady=$false
        SwitchGap=$false;ChatUrlSet=$false;BackgroundStopRequested=$false;Background='absent';FlowPhase='';FailureHeld=$false}
    foreach($k in $O.Keys){$d[$k]=$O[$k]}
    $bg=$d.Background; if($bg -is [string]){$bg=Get-UiBackgroundFixture -Name $bg}
    return New-FastLlmUiStateSnapshot -Busy $d.Busy -UpdateKind $d.UpdateKind -ChildActive $d.ChildActive -Step $d.Step -RunReady $d.RunReady `
        -SideChildActive $d.SideChildActive -VcBrokerActive $d.VcBrokerActive -PreviewReady $d.PreviewReady -SwitchGap $d.SwitchGap `
        -ChatUrlSet $d.ChatUrlSet -BackgroundStopRequested $d.BackgroundStopRequested -Background $bg -FlowPhase $d.FlowPhase -FailureHeld $d.FailureHeld
}
# The card states the render covers, by the snapshot that produces each one.
$homeSnaps=[ordered]@{
    'not-running'=@{}
    'starting'=@{ChildActive=$true;Step='model download'}
    'running'=@{ChildActive=$true;Step='serving';RunReady=$true}
    'needs-attention'=@{FailureHeld=$true}
    'background-found'=@{Background='ready-attachable'}
    'waiting-microsoft'=@{VcBrokerActive=$true}
}
$homeStatusText=@{
    'not-running'='Not running. Install & start sets up and starts the best setup for your card.'
    'starting'='Downloading the model. This can take a while on a first start.'
    'running'='Running. Connect an app with the address below.'
    'needs-attention'='Action needs attention. Use Copy full output, then review Diagnostics.'
    'background-found'='A FastLLM run is already active in the background. Attach to use it.'
    'waiting-microsoft'='Microsoft setup is still running. Complete or cancel it in the Microsoft window.'
}
# The ONE binding loop of the render test. It mirrors the shell's loop in Initialize-FastLlmUiFluentShell (the same Mode, Event, Flags and Also handling),
# so a table row is bound here exactly as the window binds it.
function Connect-RenderBindingRows([object[]]$Rows,[hashtable]$Els){
    foreach($row in $Rows){
        $adapter=Get-Variable -Name ([string]$row.Name) -Scope Script -ValueOnly
        $also=($row.ContainsKey('Also') -and [bool]$row['Also'])
        Connect-FastLlmUiFluentControl -Adapter $adapter -Element $Els[[string]$row.Element] -Mode ([string]$row.Mode) -Event ([string]$row.Event) -Flags @($row.Flags) -Also:$also
    }
}
function Initialize-HomeRenderPage($Page){
    $els=@{}
    [void](Initialize-FastLlmUiFluentHome -Page $Page -Els $els)
    $null=Initialize-FastLlmUiFluentBindings -InstallRoot $script:InstallRoot -Catalog $script:homeCatalog -UiSettings $script:homeSettings
    Connect-RenderBindingRows @(Get-FastLlmUiFluentHomeBindings) $els
    $script:FastLlmUiFluent=@{Window=$null;Els=$els;Keys=@{};Tick=1;Theme=[string]$script:homeCaseTheme}
    $script:statusLabel.Text=[string]$homeStatusText[$script:homeState]
    $script:homeSnap=New-HomeSnap $homeSnaps[$script:homeState]
    Update-FastLlmUiFluentHome
    $script:FastLlmUiFluent.Tick=2
}
$homePrepare={param($page) Initialize-HomeRenderPage $page}
function Test-HomeCase([string]$State,$case){
    $script:homeState=$State
    $script:homeCaseTheme=[string]$case.theme
    $label="Home $State $($case.theme) $($case.scale) $($case.textScale) $($case.width)x$($case.height)"
    $r=$null
    try{$r=Invoke-UiRenderCase -Name 'FastLlm.Home' -Case $case -OutFolder $out -Prepare $homePrepare}catch{Check $false "Home renders at ${label}: $($_.Exception.Message)";return}
    $diagText=''
    if(@($r.diagnostics).Count -gt 0){$diagText=' | diag: '+(@($r.diagnostics) -join '; ')}
    Check (@($r.problems).Count -eq 0) "Home clean at ${label}: $(@($r.problems) -join '; ')$diagText"
    $real=$false
    if($r.png -and (Test-Path -LiteralPath $r.png)){$info=Get-UiPngInfo -Path $r.png;$real=$info.hasContent}
    Check $real "the Home render is real at $label"
}
$homeSw=[Diagnostics.Stopwatch]::StartNew()
foreach($case in $matrix){Test-HomeCase 'not-running' $case}
foreach($state in 'starting','running','needs-attention','background-found','waiting-microsoft'){
    foreach($theme in 'light','dark','high-contrast'){
        foreach($text in 1.0,2.25){
            $case=@{theme=$theme;scale=[double]1.0;textScale=[double]$text;width=640;height=480}
            Test-HomeCase $state $case
        }
    }
}
Write-Host ('INFO: Home render of {0} cases took {1:N1} s' -f ($matrix.Count+30),$homeSw.Elapsed.TotalSeconds)

# ---- Overlap pin: Home at text 1.0, 2.0 and 2.25 has no overlap, the Minimize to tray button is the first tab stop, and the whole tab sequence is the reading order.
foreach($text in 1.0,2.0,2.25){
    $case=@{theme='light';scale=[double]1.0;textScale=[double]$text;width=640;height=480}
    $script:homeState='not-running'
    $script:homeCaseTheme='light'
    $script:pinPage=$null
    $pinPrepare={param($page) $script:pinPage=$page; Initialize-HomeRenderPage $page}
    $r=$null
    try{$r=Invoke-UiRenderCase -Name 'FastLlm.Home' -Case $case -OutFolder $out -Prepare $pinPrepare}catch{Check $false "Home overlap pin renders at text ${text}: $($_.Exception.Message)";continue}
    $overlaps=@(@($r.problems)|Where-Object{$_ -like 'overlap:*'})
    Check ($overlaps.Count -eq 0) "Home has no overlap at text ${text}: $($overlaps -join '; ')"
    $all=Get-UiVisualElements $script:pinPage
    $stops=New-Object System.Collections.ArrayList
    foreach($el in $all){
        if($el -is [System.Windows.Controls.Control] -and (Test-UiAuthored $el) -and $el.Focusable -and $el.IsTabStop -and $el.IsEnabled -and (Test-UiShown $el $script:pinPage)){[void]$stops.Add($el)}
    }
    $firstName=''
    if($stops.Count -gt 0){$firstName=[string]$stops[0].Name}
    Check ($firstName -ceq 'TrayButton') "TrayButton is the first tab stop in Home at text ${text} (first is '$firstName' of $($stops.Count) stops)"
    $rows=@()
    $order=0
    foreach($el in $stops){
        $rect=Get-UiRelativeRect $el $script:pinPage
        if($null -ne $rect){$rows+=[pscustomobject]@{Name=(Get-UiElementLabel $el);Row=[double][Math]::Round($rect.Top/8.0);Left=[double]$rect.Left;Order=$order}}
        $order++
    }
    $byRead=@($rows|Sort-Object -Property @{Expression='Row'},@{Expression='Left'},@{Expression='Order'})
    $treeNames=(@($rows|ForEach-Object{$_.Name}) -join ', ')
    $readNames=(@($byRead|ForEach-Object{$_.Name}) -join ', ')
    Write-Host "INFO: Home tab sequence at text ${text}: tree [$treeNames] reading [$readNames]"
    Check ($treeNames -ceq $readNames -and $rows.Count -eq $stops.Count) "the Home tab sequence is the reading order at text ${text}"
}

# ---- The Tools page: idle across the 40-case matrix, and busy (every disabled button with its reason) at 640x480 x 3 themes x text 1.0 and 2.25.
# The prepare step is what the shell does for the page: Initialize-FastLlmUiFluentTools, the page's rows of the binding table, then one reasons refresh.
$script:toolsBusy=$false
$script:toolsEls=$null
function Initialize-ToolsRenderPage($Page){
    $els=@{}
    $script:FastLlmUiFluent=@{Window=$null;Els=$els;Keys=@{};Tick=1;Theme=[string]$script:homeCaseTheme;Pages=@{};Current=''}
    [void](Initialize-FastLlmUiFluentTools -Page $Page -Els $els)
    $null=Initialize-FastLlmUiFluentBindings -InstallRoot $script:InstallRoot -Catalog $script:homeCatalog -UiSettings $script:homeSettings
    Connect-RenderBindingRows @(Get-FastLlmUiFluentToolsBindings) $els
    $els['ToolsStatusText'].Text='Not running. Install & start sets up and starts the best setup for your card.'
    if($script:toolsBusy){
        $script:homeSnap=New-HomeSnap @{Busy=$true;ChildActive=$true;Step='model download'}
        foreach($row in (Get-FastLlmUiFluentToolsReasonRows)){(Get-Variable -Name ([string]$row.Adapter) -Scope Script -ValueOnly).Enabled=$false}
        Update-FastLlmUiFluentTools
    }else{$script:homeSnap=New-HomeSnap @{}}
    $script:toolsEls=$els
}
$toolsPrepare={param($page) Initialize-ToolsRenderPage $page}
function Test-ToolsCase([bool]$Busy,$case){
    $script:toolsBusy=$Busy
    $script:homeCaseTheme=[string]$case.theme
    $kind='idle'
    $pngName='FastLlm.Tools'
    if($Busy){$kind='busy';$pngName='FastLlm.ToolsBusy'}
    $label="Tools $kind $($case.theme) $($case.scale) $($case.textScale) $($case.width)x$($case.height)"
    $r=$null
    try{$r=Invoke-UiRenderCase -Name 'FastLlm.Tools' -Case $case -OutFolder $out -Prepare $toolsPrepare -PngName $pngName}catch{Check $false "Tools renders at ${label}: $($_.Exception.Message)";return}
    $diagText=''
    if(@($r.diagnostics).Count -gt 0){$diagText=' | diag: '+(@($r.diagnostics) -join '; ')}
    Check (@($r.problems).Count -eq 0) "Tools clean at ${label}: $(@($r.problems) -join '; ')$diagText"
    $real=$false
    if($r.png -and (Test-Path -LiteralPath $r.png)){$info=Get-UiPngInfo -Path $r.png;$real=$info.hasContent}
    Check $real "the Tools render is real at $label"
    $e=$script:toolsEls
    Check (@(@('ToolsDiagnosticsButton','ToolsDriverButton','ToolsBundleButton','ToolsLogsButton','ToolsRecheckButton','ToolsAttachButton')|Where-Object{[string]$e[$_].Content -eq ''}).Count -eq 0) "every Tools button has its adapter caption at $label"
    if($Busy){
        $noReason=@(Get-FastLlmUiFluentToolsReasonRows|Where-Object{-not $e[[string]$_.Element].IsEnabled -and [string]::IsNullOrEmpty([string]$e[[string]$_.Element].ToolTip)}|ForEach-Object{[string]$_.Element})
        Check ($noReason.Count -eq 0) "every disabled Tools button says why at ${label}: no reason on $($noReason -join ', ')"
    }
}
$toolsSw=[Diagnostics.Stopwatch]::StartNew()
foreach($case in $matrix){Test-ToolsCase $false $case}
foreach($theme in 'light','dark','high-contrast'){
    foreach($text in 1.0,2.25){Test-ToolsCase $true @{theme=$theme;scale=[double]1.0;textScale=[double]$text;width=640;height=480}}
}
Write-Host ('INFO: Tools render of {0} cases took {1:N1} s' -f ($matrix.Count+6),$toolsSw.Elapsed.TotalSeconds)

# ---- The Connect page. The facts come from the real Get-FastLlmConnectionInfo (a run status in) and the real Get-FastLlmUiApiKeyRow (the store state in).
# Running with the key on shows every client card, the agent warning (a 16K context) and the key row; "not running" has no key row; "key unreadable"
# is running with the key on and a store this user cannot read.
function New-ConnectRunStatus{
    return [pscustomobject]@{phase='ready';active=$true;runId='aabbccdd11223344aabbccdd11223344';modelId='render-model-q4';endpoint='http://127.0.0.1:8123/v1';apiKey='on';apiKeyId='0123abcd'
        recipe=[pscustomobject]@{catalogVersion='1';contextSize=16384;id=$null}}
}
function Set-ConnectRenderState([string]$State){
    switch -CaseSensitive ($State){
        'running'{
            $script:renderRunStatus=New-ConnectRunStatus
            $script:renderKeyStore=[pscustomobject]@{exists=$true;available=$true;apiKeyId='0123abcd'}
            $script:homeSnap=New-HomeSnap @{RunReady=$true;ChildActive=$true;Step='serving'}
        }
        'not-running'{
            $script:renderRunStatus=$null
            $script:renderKeyStore=[pscustomobject]@{exists=$false;available=$false;apiKeyId=$null}
            $script:homeSnap=New-HomeSnap @{}
        }
        'key-unreadable'{
            $script:renderRunStatus=New-ConnectRunStatus
            $script:renderKeyStore=[pscustomobject]@{exists=$true;available=$false;apiKeyId=$null}
            $script:homeSnap=New-HomeSnap @{RunReady=$true;ChildActive=$true;Step='serving'}
        }
        default{throw "unknown Connect render state $State"}
    }
}
$script:connectState='running'
$script:connectEls=$null
function Initialize-ConnectRenderPage($Page){
    $els=@{}
    $script:FastLlmUiFluent=@{Window=$null;Els=$els;Keys=@{};Tick=1;Theme=[string]$script:homeCaseTheme;Pages=@{};Current=''}
    [void](Initialize-FastLlmUiFluentConnect -Page $Page -Els $els)
    Set-ConnectRenderState $script:connectState
    $els['ConnectStatusText'].Text='Running. Connect an app with the address below.'
    $script:renderFail=''
    Enter-FastLlmUiFluentConnect
    $script:connectEls=$els
}
$connectPrepare={param($page) Initialize-ConnectRenderPage $page}
function Test-ConnectCase([string]$State,$case){
    $script:connectState=$State
    $script:homeCaseTheme=[string]$case.theme
    $pngName='FastLlm.Connect'
    if($State -ceq 'not-running'){$pngName='FastLlm.ConnectNotRunning'}
    elseif($State -ceq 'key-unreadable'){$pngName='FastLlm.ConnectKeyUnreadable'}
    $label="Connect $State $($case.theme) $($case.scale) $($case.textScale) $($case.width)x$($case.height)"
    $r=$null
    try{$r=Invoke-UiRenderCase -Name 'FastLlm.Connect' -Case $case -OutFolder $out -Prepare $connectPrepare -PngName $pngName}catch{Check $false "Connect renders at ${label}: $($_.Exception.Message)";return}
    $diagText=''
    if(@($r.diagnostics).Count -gt 0){$diagText=' | diag: '+(@($r.diagnostics) -join '; ')}
    Check (@($r.problems).Count -eq 0) "Connect clean at ${label}: $(@($r.problems) -join '; ')$diagText"
    $real=$false
    if($r.png -and (Test-Path -LiteralPath $r.png)){$info=Get-UiPngInfo -Path $r.png;$real=$info.hasContent}
    Check $real "the Connect render is real at $label"
    $e=$script:connectEls
    Check ($script:renderFail -ceq '') "the Connect page filled without a failure at ${label}: '$($script:renderFail)'"
    $running=($State -cne 'not-running')
    $keyRow=($e['ConnectKeyRow'].Visibility -eq [System.Windows.Visibility]::Visible)
    Check ($keyRow -eq $running) "the Connect key row is shown exactly when the key is on at $label"
    if($State -ceq 'key-unreadable'){Check (-not $e['ConnectKeyShow'].IsEnabled -and -not $e['ConnectKeyCopy'].IsEnabled) "an unreadable key disables Show and Copy at $label"}
    if($State -ceq 'running'){
        Check ([string]$e['ConnectBaseUrlBox'].Text -ceq 'http://127.0.0.1:8123/v1' -and $e['ConnectClients'].Children.Count -ge 2 -and $e['ConnectAgentWarning'].Visibility -eq [System.Windows.Visibility]::Visible) "a running Connect page shows its address, the client cards and the agent warning at $label"
    }
}
$connectSw=[Diagnostics.Stopwatch]::StartNew()
foreach($case in $matrix){Test-ConnectCase 'running' $case}
foreach($state in 'not-running','key-unreadable'){
    foreach($theme in 'light','dark','high-contrast'){
        foreach($text in 1.0,2.25){Test-ConnectCase $state @{theme=$theme;scale=[double]1.0;textScale=[double]$text;width=640;height=480}}
    }
}
Write-Host ('INFO: Connect render of {0} cases took {1:N1} s' -f ($matrix.Count+12),$connectSw.Elapsed.TotalSeconds)

# ---- The Models page. The store reads, the engine components and the switch picker are shadows over a fixture; the page, its lists, its reasons and the
# bindings are the product's. 'long' is the stress case (long names, in-use rows, leftovers, components, picker items with long verdicts, a long folder path,
# the Start options open and long messages); 'empty' has nothing installed, switching off with its reason line and the Start options closed.
$script:form=$null
$script:catalog=$script:homeCatalog
$script:modelsFx=$null
$script:modelsEls=$null
function Get-FastLlmInstalledModels{param([string]$InstallRoot,[string]$CatalogPath)return @($script:modelsFx.models)}
function Get-FastLlmModelLeftovers{param([string]$InstallRoot)return @($script:modelsFx.leftovers)}
function Get-FastLlmModelStoreFreeBytes{param([string]$InstallRoot)return [int64]123456789012}
function Get-FastLlmComponentInventory{param([string]$ComponentsPath,[string]$InstallRoot)return @()}
function Get-FastLlmInstalledComponentRows{param([object[]]$Inventory)return @($script:modelsFx.components)}
function Get-FastLlmStatus{param([string]$InstallRoot)return $null}
function Get-FastLlmUiSwitchPickerModel{param([string]$InstallRoot,[string]$CatalogPath,$Status,[scriptblock]$RowsProvider)return [pscustomobject]@{items=@($script:modelsFx.pickerItems);message=''}}
function New-ModelsRenderFixture([string]$Kind){
    if($Kind -ceq 'empty'){
        return @{kind='empty';catalog=$script:homeCatalog;models=@();leftovers=@();components=@();pickerItems=@();switchOn=$false;expanded=$false;folder=[string]$script:InstallRoot
            switchLine='Model switching is off. Turn it on in the settings to switch models while FastLLM runs.';longMessages=$false;models_n=0;components_n=0;picker_n=0}
    }
    $entries=New-Object System.Collections.ArrayList
    $installed=New-Object System.Collections.ArrayList
    $picker=New-Object System.Collections.ArrayList
    for($i=1;$i -le 10;$i++){
        $id=('render-model-{0:D2}' -f $i)
        [void]$entries.Add([pscustomobject]@{id=$id;upstreamModel=('example-org/Very-Long-Model-Name-For-Layout-Checks-{0:D2}-Instruct-Extended-Context' -f $i);quantization='Q4_K_M'})
        $reason='';if($i -le 2){$reason='FastLLM is serving this model right now, so it cannot be removed.'}
        [void]$installed.Add([pscustomobject]@{id=$id;sizeBytes=[int64](1500000000+$i*250000000);inUse=($i -le 2);inUseReason=$reason})
    }
    for($i=1;$i -le 8;$i++){
        [void]$picker.Add([pscustomobject]@{id=('render-model-{0:D2}' -f $i);text=('Very-Long-Model-Name-For-Layout-Checks-{0:D2}-Instruct Q4_K_M  -  fits with room for the context you picked, about 30 GB needed of 48 GB free' -f $i);canSwitch=(($i % 2) -eq 1)})
    }
    $components=@()
    for($i=1;$i -le 5;$i++){$components+=[pscustomobject]@{id=('render-engine-{0}' -f $i);label=('render-engine-{0} (engine, 1.{0}.0, {0}40 MB) - a long component label to wrap on a narrow window' -f $i)}}
    $leftovers=@([pscustomobject]@{name='a.part';sizeBytes=[int64]1073741824;locked=$false},[pscustomobject]@{name='b.part';sizeBytes=[int64]536870912;locked=$false})
    $catalog=[pscustomobject]@{models=@($entries.ToArray())}
    return @{kind='long';catalog=$catalog;models=@($installed.ToArray());leftovers=$leftovers;components=$components;pickerItems=@($picker.ToArray());switchOn=$true;expanded=$true
        folder='D:\Programs and Data With A Long Name\FastLLM\models and caches\a-very-long-folder-name-for-the-layout-checks-and-one-more-part-to-make-it-longer';switchLine='';longMessages=$true;models_n=10;components_n=5;picker_n=8}
}
function Set-ModelsRenderFixtureState($Fx,$Els){
    $script:pathBox.Text=[string]$Fx.folder
    $script:switchButton.Enabled=[bool]$Fx.switchOn
    if([string]$Fx.switchLine -ne ''){$script:switchLabel.Text=[string]$Fx.switchLine}
    $Els['ModelsStartOptions'].IsExpanded=[bool]$Fx.expanded
}
function Set-ModelsRenderMessages($Fx){
    if(-not [bool]$Fx.longMessages){return}
    $long='The model list could not be read because the folder is on a drive that is not ready, and this sentence is long on purpose so that it wraps at a narrow window width and at the largest text size. '
    $m=$script:FastLlmUiFluent['Models']
    $m['Message'].Text=$long.Substring(0,180)
    $m['ComponentsMessage'].Text=$long.Substring(0,180)
    $m['SwitchMessage'].Text=$long.Substring(0,180)
}
function Initialize-ModelsRenderPage($Page){
    $fx=$script:modelsFx
    $els=@{}
    $script:FastLlmUiFluent=@{Window=$null;Els=$els;Keys=@{};Tick=1;Theme=[string]$script:homeCaseTheme;Pages=@{};Current=''}
    [void](Initialize-FastLlmUiFluentModels -Page $Page -Els $els)
    # The names the stand-in holds are exactly the page's x:Names (resolved through FindName by the product's own collection, checked against the markup here).
    $pageNames=Get-UiPageElementNames ([string]$script:FastLlmUiXaml['FastLlm.Models'])
    $absent=@($pageNames|Where-Object{-not $els.ContainsKey([string]$_)})
    if($absent.Count -gt 0){throw ('Models names missing from the element map: '+($absent -join ', '))}
    $null=Initialize-FastLlmUiFluentBindings -InstallRoot $script:InstallRoot -Catalog $script:homeCatalog -UiSettings $script:homeSettings
    Connect-RenderBindingRows @(Get-FastLlmUiFluentModelsBindings) $els
    Set-ModelsRenderFixtureState $fx $els
    $script:catalog=$fx.catalog
    $script:homeSnap=New-HomeSnap @{}
    $script:renderFail=''
    Enter-FastLlmUiFluentModels
    Set-ModelsRenderMessages $fx
    $script:modelsEls=$els
}
$modelsPrepare={param($page) Initialize-ModelsRenderPage $page}
function Get-RenderRemoveButtons($Panel){
    $list=New-Object System.Collections.ArrayList
    foreach($row in $Panel.Children){
        if($row -is [System.Windows.Controls.Grid]){foreach($cell in $row.Children){if($cell -is [System.Windows.Controls.Button]){[void]$list.Add($cell)}}}
    }
    return $list.ToArray()
}
function Test-ModelsCase([string]$Kind,$case){
    $script:modelsFx=New-ModelsRenderFixture $Kind
    $script:homeCaseTheme=[string]$case.theme
    $pngName='FastLlm.Models'
    if($Kind -ceq 'empty'){$pngName='FastLlm.ModelsEmpty'}
    $label="Models $Kind $($case.theme) $($case.scale) $($case.textScale) $($case.width)x$($case.height)"
    $r=$null
    try{$r=Invoke-UiRenderCase -Name 'FastLlm.Models' -Case $case -OutFolder $out -Prepare $modelsPrepare -PngName $pngName -ScrollOwners @('ModelsSwitchList')}catch{Check $false "Models renders at ${label}: $($_.Exception.Message)";return}
    $diagText=''
    if(@($r.diagnostics).Count -gt 0){$diagText=' | diag: '+(@($r.diagnostics) -join '; ')}
    Check (@($r.problems).Count -eq 0) "Models clean at ${label}: $(@($r.problems) -join '; ')$diagText"
    $real=$false
    if($r.png -and (Test-Path -LiteralPath $r.png)){$info=Get-UiPngInfo -Path $r.png;$real=$info.hasContent}
    Check $real "the Models render is real at $label"
    $e=$script:modelsEls
    $fx=$script:modelsFx
    Check ($script:renderFail -ceq '') "the Models page filled without a failure at ${label}: '$($script:renderFail)'"
    $modelButtons=@(Get-RenderRemoveButtons $e['ModelsModelRows'])
    $componentButtons=@(Get-RenderRemoveButtons $e['ModelsComponentRows'])
    $wantModelChildren=[Math]::Max(1,[int]$fx.models_n)
    $wantComponentChildren=[Math]::Max(1,[int]$fx.components_n)
    Check ($e['ModelsModelRows'].Children.Count -eq $wantModelChildren -and $modelButtons.Count -eq [int]$fx.models_n) "the Models list has its fixture rows at ${label} (children $($e['ModelsModelRows'].Children.Count) of $wantModelChildren, buttons $($modelButtons.Count) of $($fx.models_n))"
    Check ($e['ModelsComponentRows'].Children.Count -eq $wantComponentChildren -and $componentButtons.Count -eq [int]$fx.components_n) "the component list has its fixture rows at ${label} (children $($e['ModelsComponentRows'].Children.Count) of $wantComponentChildren, buttons $($componentButtons.Count) of $($fx.components_n))"
    $names=@($modelButtons+$componentButtons|ForEach-Object{[string][System.Windows.Automation.AutomationProperties]::GetName($_)})
    Check (@($names|Where-Object{$_ -notmatch '^Remove .'}).Count -eq 0 -and @($names|Sort-Object -Unique).Count -eq $names.Count) "every Remove button has its own name at ${label} (names: $($names -join ' | '))"
    Check ($e['ModelsSwitchList'].Items.Count -eq [int]$fx.picker_n) "the switch list has its fixture items at ${label} (got $($e['ModelsSwitchList'].Items.Count) of $($fx.picker_n))"
    Check ([bool]$e['ModelsStartOptions'].IsExpanded -eq [bool]$fx.expanded) "the Start options are $(if($fx.expanded){'open'}else{'closed'}) at $label"
    $disabledModels=@($modelButtons|Where-Object{-not $_.IsEnabled})
    if($Kind -ceq 'long'){
        Check ($disabledModels.Count -eq 2 -and @($disabledModels|Where-Object{[string]::IsNullOrEmpty([string]$_.ToolTip)}).Count -eq 0) "the two in-use models have a disabled Remove with a reason at $label"
        Check ($e['ModelsLeftoverButton'].IsEnabled) "the leftover button is enabled with leftovers at $label"
    }else{
        Check (-not $e['ModelsLeftoverButton'].IsEnabled -and [string]$e['ModelsLeftoverButton'].ToolTip -ceq [string]$script:FastLlmUiFluentStrings.WhyNoLeftovers) "the leftover button says why it is off at $label"
    }
}
$modelsSw=[Diagnostics.Stopwatch]::StartNew()
foreach($case in $matrix){Test-ModelsCase 'long' $case}
foreach($theme in 'light','dark','high-contrast'){
    foreach($text in 1.0,2.25){Test-ModelsCase 'empty' @{theme=$theme;scale=[double]1.0;textScale=[double]$text;width=640;height=480}}
}
Write-Host ('INFO: Models render of {0} cases took {1:N1} s' -f ($matrix.Count+6),$modelsSw.Elapsed.TotalSeconds)

# ---- Reading order of the Tools, Connect and Models pages at text 1.0, 2.0 and 2.25: no overlap, and the whole tab sequence is the reading order.
function Test-PageReadingOrder([string]$Label,[string]$XamlName,[string]$PngName,[scriptblock]$Prepare,[int]$MinStops,[string[]]$ScrollOwners=@()){
    foreach($text in 1.0,2.0,2.25){
        $case=@{theme='light';scale=[double]1.0;textScale=[double]$text;width=640;height=480}
        $script:homeCaseTheme='light'
        $script:pinPage=$null
        # A plain scriptblock (not a closure), so $script: is this file's scope; the page's own prepare step is handed over in $script:pinInner.
        $script:pinInner=$Prepare
        $pinPrepare={param($page) $script:pinPage=$page; & $script:pinInner $page}
        $r=$null
        try{$r=Invoke-UiRenderCase -Name $XamlName -Case $case -OutFolder $out -Prepare $pinPrepare -PngName $PngName -ScrollOwners $ScrollOwners}catch{Check $false "$Label reading order renders at text ${text}: $($_.Exception.Message)";continue}
        $overlaps=@(@($r.problems)|Where-Object{$_ -like 'overlap:*'})
        Check ($overlaps.Count -eq 0) "$Label has no overlap at text ${text}: $($overlaps -join '; ')"
        $stops=New-Object System.Collections.ArrayList
        foreach($el in (Get-UiVisualElements $script:pinPage)){
            if($el -is [System.Windows.Controls.Control] -and (Test-UiAuthored $el) -and $el.Focusable -and $el.IsTabStop -and $el.IsEnabled -and (Test-UiShown $el $script:pinPage)){[void]$stops.Add($el)}
        }
        $rows=@()
        $order=0
        foreach($el in $stops){
            $rect=Get-UiRelativeRect $el $script:pinPage
            if($null -ne $rect){$rows+=[pscustomobject]@{Name=(Get-UiElementLabel $el);Row=[double][Math]::Round($rect.Top/8.0);Left=[double]$rect.Left;Order=$order}}
            $order++
        }
        $byRead=@($rows|Sort-Object -Property @{Expression='Row'},@{Expression='Left'},@{Expression='Order'})
        $treeNames=(@($rows|ForEach-Object{$_.Name}) -join ', ')
        $readNames=(@($byRead|ForEach-Object{$_.Name}) -join ', ')
        Write-Host "INFO: $Label tab sequence at text ${text}: tree [$treeNames] reading [$readNames]"
        Check ($treeNames -ceq $readNames -and $rows.Count -eq $stops.Count -and $stops.Count -ge $MinStops) "the $Label tab sequence is the reading order at text ${text} ($($stops.Count) stops, at least $MinStops)"
    }
}
$orderSw=[Diagnostics.Stopwatch]::StartNew()
$script:toolsBusy=$false
Test-PageReadingOrder 'Tools' 'FastLlm.Tools' 'FastLlm.ToolsReading' $toolsPrepare 6
$script:connectState='running'
Test-PageReadingOrder 'Connect' 'FastLlm.Connect' 'FastLlm.ConnectReading' $connectPrepare 10
# Models at the long fixture (the Start options open, so the whole page is in the tab sequence): the model box, the three start inputs, the switch list, the leftover
# button and the 13 Remove buttons, at least 12 stops
$script:modelsFx=New-ModelsRenderFixture 'long'
Test-PageReadingOrder 'Models' 'FastLlm.Models' 'FastLlm.ModelsReading' $modelsPrepare 12 @('ModelsSwitchList')
Write-Host ('INFO: Tools, Connect and Models reading order of 9 cases took {0:N1} s' -f $orderSw.Elapsed.TotalSeconds)

# ---- The shell and Home together: the window content (navigation pane, message area, page host with Home) is rendered like a page.
# The Window element cannot be measured inside the harness, so its content is taken off it and its styles are merged into the theme dictionary.
# The update bar is visible and the failure bar holds 400 characters in every case.
$script:shellRp=$null
function New-ShellRenderPage($Case,[string]$PageId='Home'){
    $sw=New-FastLlmUiXamlElement -Name 'FastLlm.Shell'
    $homePage=New-FastLlmUiXamlElement -Name 'FastLlm.Home'
    $els=@{}
    # Every x:Name in the registered shell markup, resolved through the XAML namescope (FindName), so ColumnDefinitions and other non-visuals resolve too.
    $missing=@()
    foreach($n in (Get-UiPageElementNames ([string]$script:FastLlmUiXaml['FastLlm.Shell']))){
        $found=$sw.FindName($n)
        if($null -eq $found){$missing+=$n}else{$els[$n]=$found}
    }
    if($missing.Count -gt 0){throw ('shell names that did not resolve: '+($missing -join ', '))}
    [void](Initialize-FastLlmUiFluentHome -Page $homePage -Els $els)
    $els.PageHost.Child=$homePage
    $script:FastLlmUiFluent=@{Window=[pscustomobject]@{ActualWidth=[double]$Case.width;ActualHeight=[double]$Case.height};Els=$els;Keys=@{};Timer=$null;Tick=1;Theme=[string]$Case.theme;ThemeKey='';Interop=$false;Hooks=$null
        NavItems=@();LastException=$null;InUnhandled=$false;TickError='';Pages=@{};Current=''}
    # The binding table includes the Tools rows, so the Tools page is parsed, initialised and registered as the shell does (before the pane).
    $toolsPage=New-FastLlmUiXamlElement -Name 'FastLlm.Tools'
    [void](Initialize-FastLlmUiFluentTools -Page $toolsPage -Els $els)
    $connectPage=New-FastLlmUiXamlElement -Name 'FastLlm.Connect'
    [void](Initialize-FastLlmUiFluentConnect -Page $connectPage -Els $els)
    # PR 3b: Models is registered the same way (the binding table includes its rows, bound by the same loop below as Tools and Connect).
    $modelsPage=New-FastLlmUiXamlElement -Name 'FastLlm.Models'
    [void](Initialize-FastLlmUiFluentModels -Page $modelsPage -Els $els)
    Register-FastLlmUiFluentHomePage -Page $homePage -Els $els
    Register-FastLlmUiFluentToolsPage -Page $toolsPage -Els $els
    Register-FastLlmUiFluentConnectPage -Page $connectPage -Els $els
    Register-FastLlmUiFluentModelsPage -Page $modelsPage -Els $els
    Initialize-FastLlmUiFluentPane
    $null=Initialize-FastLlmUiFluentBindings -InstallRoot $script:InstallRoot -Catalog $script:homeCatalog -UiSettings $script:homeSettings
    Connect-RenderBindingRows @(Get-FastLlmUiFluentBindingTable) $els
    $long=('Engine start failed while loading the model. '*10).Substring(0,400)
    $script:bannerLabel.Text='An update to FastLLM is available.'
    $script:bannerLabel.Visible=$true
    $script:bannerButton.Visible=$true
    $script:bannerNotes.Visible=$true
    $script:failureHeld=$true
    $script:failureViewText=$long
    $script:output.Text=$long
    $script:failureCopyLink.Visible=$true
    $script:homeSnap=New-HomeSnap @{FailureHeld=$true}
    Update-FastLlmUiFluentHome
    Update-FastLlmUiFluentMessages
    Update-FastLlmUiFluentPane
    # The page under test is hosted the way the window hosts it (Leave, host, nav selection, Enter). Models is hosted with the long fixture.
    if($PageId -ceq 'Models'){
        $script:modelsFx=New-ModelsRenderFixture 'long'
        Set-ModelsRenderFixtureState $script:modelsFx $els
        $script:catalog=$script:modelsFx.catalog
    }
    if($PageId -cne 'Home'){
        $script:renderFail=''
        $hosted=Set-FastLlmUiFluentPage -Id $PageId
        if(-not [bool]$hosted -or $script:renderFail -cne ''){throw ("the shell could not host $PageId (hosted=$hosted, failure='$($script:renderFail)')")}
        if($PageId -ceq 'Models'){Set-ModelsRenderMessages $script:modelsFx}
    }
    $res=$sw.Resources
    $content=$sw.Content
    $sw.Content=$null
    return @{Content=$content;Resources=$res;Els=$els}
}
$shellPrepare={
    param($page)
    foreach($k in @($script:shellRp.Resources.Keys)){$page.Resources[$k]=([object]$script:shellRp.Resources[$k]).psobject.BaseObject}
}
$shellSw=[Diagnostics.Stopwatch]::StartNew()
foreach($pageId in 'Home','Tools','Connect','Models'){
    $pageSw=[Diagnostics.Stopwatch]::StartNew()
    $shellPng='FastLlm.Shell'
    if($pageId -cne 'Home'){$shellPng='FastLlm.Shell'+$pageId}
    foreach($theme in 'light','dark','high-contrast'){
        foreach($size in @(@(640,480),@(1000,680))){
            foreach($text in 1.0,2.25){
                $case=@{theme=$theme;scale=[double]1.0;textScale=[double]$text;width=[int]$size[0];height=[int]$size[1]}
                $label="Shell $pageId $theme $($case.scale) $text $($case.width)x$($case.height)"
                $script:homeCaseTheme=$theme
                Set-ConnectRenderState 'running'
                $r=$null
                try{
                    $script:shellRp=New-ShellRenderPage $case $pageId
                    $r=Invoke-UiRenderCase -Name 'FastLlm.Shell' -Case $case -OutFolder $out -Element $script:shellRp.Content -Prepare $shellPrepare -PngName $shellPng -TabRegions @('NavList') -ScrollOwners @('ModelsSwitchList')
                }catch{Check $false "Shell renders at ${label}: $($_.Exception.Message)";continue}
                $diagText=''
                if(@($r.diagnostics).Count -gt 0){$diagText=' | diag: '+(@($r.diagnostics) -join '; ')}
                Check (@($r.problems).Count -eq 0) "Shell clean at ${label}: $(@($r.problems) -join '; ')$diagText"
                $badBars=@()
                foreach($ln in 'NavList','NavSettingsList'){
                    $lb=$script:shellRp.Els[$ln]
                    $mode=[System.Windows.Controls.ScrollViewer]::GetHorizontalScrollBarVisibility($lb)
                    if($mode -ne [System.Windows.Controls.ScrollBarVisibility]::Disabled){$badBars+="$ln mode=$mode"}
                    foreach($v in (Get-UiVisualElements $lb)){
                        if($v -is [System.Windows.Controls.Primitives.ScrollBar] -and $v.Orientation -eq [System.Windows.Controls.Orientation]::Horizontal -and $v.Visibility -eq [System.Windows.Visibility]::Visible){$badBars+="$ln horizontal bar visible"}
                    }
                }
                Check ($badBars.Count -eq 0) "the navigation lists have no horizontal scrolling at ${label}: $($badBars -join '; ')"
                $hostedChild=$script:shellRp.Els['PageHost'].Child
                $hostedOk=$false
                if($null -ne $hostedChild){$hostedOk=[object]::ReferenceEquals($hostedChild,$script:FastLlmUiFluent['Pages'][$pageId]['Element'])}
                Check $hostedOk "the shell hosts the $pageId page at $label"
            }
        }
    }
    Write-Host ('INFO: Shell with {0} render of 12 cases took {1:N1} s' -f $pageId,$pageSw.Elapsed.TotalSeconds)
}
Write-Host ('INFO: Shell render of 48 cases took {0:N1} s' -f $shellSw.Elapsed.TotalSeconds)

# PNGs per run, counted by prefix: Test.* is 40 sample cases plus 10 negative pages plus 2 region pages. Only files written during this run count, so leftovers cannot inflate a number.
function Get-RenderPngCount([string]$Prefix){
    return @(Get-ChildItem -LiteralPath $out -Filter ($Prefix+'-*.png') -File | Where-Object { $_.LastWriteTimeUtc -ge $runStart }).Count
}
Check ((Get-RenderPngCount 'Test.*') -eq 52) ("the render folder holds 52 Test.* PNGs written by this run (got $(Get-RenderPngCount 'Test.*'))")
$pngExpect=[ordered]@{'FastLlm.Tools'=40;'FastLlm.ToolsBusy'=6;'FastLlm.ToolsReading'=3;'FastLlm.Connect'=40;'FastLlm.ConnectNotRunning'=6;'FastLlm.ConnectKeyUnreadable'=6;'FastLlm.ConnectReading'=3
    'FastLlm.Models'=40;'FastLlm.ModelsEmpty'=6;'FastLlm.ModelsReading'=3
    'FastLlm.Shell'=12;'FastLlm.ShellTools'=12;'FastLlm.ShellConnect'=12;'FastLlm.ShellModels'=12}
foreach($prefix in $pngExpect.Keys){
    $got=Get-RenderPngCount $prefix
    Check ($got -eq $pngExpect[$prefix]) ("the render folder holds $($pngExpect[$prefix]) $prefix PNGs written by this run (got $got)")
}
Write-Host ('INFO: render PNG counts: Test.* {0}; {1}' -f (Get-RenderPngCount 'Test.*'),((@($pngExpect.Keys|ForEach-Object{$_+' '+(Get-RenderPngCount $_)})) -join '; '))

if($script:failures.Count -gt 0){throw ("FAIL: $($script:failures.Count) check(s) failed: "+($script:failures -join ' | '))}
Write-Host "PASS: ui render tests ($($script:checks) checks)"
exit 0
