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

$out=$env:FASTLLM_RENDER_DIR
if([string]::IsNullOrEmpty($out)){
    if(-not [string]::IsNullOrEmpty($env:RUNNER_TEMP)){$out=Join-Path $env:RUNNER_TEMP 'fastllm-fluent-render'}
    else{$out=[IO.Path]::GetTempPath()}
}
[void][IO.Directory]::CreateDirectory($out)

$matrix=@(Get-UiRenderMatrix)

# Each negative page shows exactly its own problem.
$neg=@{Overlap='overlap:BtnA:BtnB';Clipped='clipped:ClippedText';ClippedButton='clipped:TextBlock';Unnamed='unnamed:Button';TabOrder='tab-order';Outside='outside:FarBox';UnnamedTextBox='unnamed:TextBox';LabeledByOnly='unnamed:TextBox';LabelMismatch='label-mismatch:MisBox'}
$base=@{theme='light';scale=[double]1.0;textScale=[double]1.0;width=640;height=480}
foreach($n in 'Overlap','Clipped','ClippedButton','Unnamed','TabOrder','Outside','UnnamedTextBox','LabeledByOnly','LabelMismatch'){
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
function GetUiStateSnapshot([bool]$Busy){return $script:homeSnap}
function GetUiBackgroundRunStatus{return $null}
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
function Initialize-HomeRenderPage($Page){
    $els=@{}
    [void](Initialize-FastLlmUiFluentHome -Page $Page -Els $els)
    $null=Initialize-FastLlmUiFluentBindings -InstallRoot $script:InstallRoot -Catalog $script:homeCatalog -UiSettings $script:homeSettings
    foreach($row in (Get-FastLlmUiFluentHomeBindings)){
        $adapter=Get-Variable -Name ([string]$row.Name) -Scope Script -ValueOnly
        Connect-FastLlmUiFluentControl -Adapter $adapter -Element $els[[string]$row.Element] -Mode ([string]$row.Mode) -Event ([string]$row.Event) -Flags @($row.Flags)
    }
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

# ---- The shell and Home together: the window content (navigation pane, message area, page host with Home) is rendered like a page.
# The Window element cannot be measured inside the harness, so its content is taken off it and its styles are merged into the theme dictionary.
# The update bar is visible and the failure bar holds 400 characters in every case.
$script:shellRp=$null
function New-ShellRenderPage($Case){
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
    Register-FastLlmUiFluentHomePage -Page $homePage -Els $els
    Initialize-FastLlmUiFluentPane
    $null=Initialize-FastLlmUiFluentBindings -InstallRoot $script:InstallRoot -Catalog $script:homeCatalog -UiSettings $script:homeSettings
    foreach($row in (Get-FastLlmUiFluentBindingTable)){
        $adapter=Get-Variable -Name ([string]$row.Name) -Scope Script -ValueOnly
        Connect-FastLlmUiFluentControl -Adapter $adapter -Element $els[[string]$row.Element] -Mode ([string]$row.Mode) -Event ([string]$row.Event) -Flags @($row.Flags)
    }
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
foreach($theme in 'light','dark','high-contrast'){
    foreach($size in @(@(640,480),@(1000,680))){
        foreach($text in 1.0,2.25){
            $case=@{theme=$theme;scale=[double]1.0;textScale=[double]$text;width=[int]$size[0];height=[int]$size[1]}
            $label="Shell $theme $($case.scale) $text $($case.width)x$($case.height)"
            $script:homeCaseTheme=$theme
            $r=$null
            try{
                $script:shellRp=New-ShellRenderPage $case
                $r=Invoke-UiRenderCase -Name 'FastLlm.Shell' -Case $case -OutFolder $out -Element $script:shellRp.Content -Prepare $shellPrepare
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
        }
    }
}
Write-Host ('INFO: Shell render of 12 cases took {0:N1} s' -f $shellSw.Elapsed.TotalSeconds)

# 49 PNGs per run: 40 sample cases plus 9 negative pages. Only files written during this run count, so leftovers cannot inflate the number.
$written=@(Get-ChildItem -LiteralPath $out -Filter 'Test.*.png' -File | Where-Object { $_.LastWriteTimeUtc -ge $runStart })
Check ($written.Count -eq 49) ("the render folder holds 49 PNGs written by this run (got $($written.Count))")

if($script:failures.Count -gt 0){throw ("FAIL: $($script:failures.Count) check(s) failed: "+($script:failures -join ' | '))}
Write-Host "PASS: ui render tests ($($script:checks) checks)"
exit 0
