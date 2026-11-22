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
$hcPal=Get-UiRenderHighContrastPalette
Check (@($hcPal.Values|Sort-Object -Unique).Count -eq 4) 'the high-contrast palette has four distinct colours'
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

# 49 PNGs per run: 40 sample cases plus 9 negative pages. Only files written during this run count, so leftovers cannot inflate the number.
$written=@(Get-ChildItem -LiteralPath $out -Filter 'Test.*.png' -File | Where-Object { $_.LastWriteTimeUtc -ge $runStart })
Check ($written.Count -eq 49) ("the render folder holds 49 PNGs written by this run (got $($written.Count))")

if($script:failures.Count -gt 0){throw ("FAIL: $($script:failures.Count) check(s) failed: "+($script:failures -join ' | '))}
Write-Host "PASS: ui render tests ($($script:checks) checks)"
exit 0
