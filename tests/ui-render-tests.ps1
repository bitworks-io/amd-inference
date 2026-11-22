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

$onWindows=($PSVersionTable.PSVersion.Major -le 5) -or [bool](Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue)
if(-not $onWindows){Write-Host 'SKIP: Windows only';exit 0}

# A non-STA host, or a WPF that does not load, fails loudly; it never skips.
Check ([Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA') 'runs on an STA thread'
$interop=$false
try{$interop=[bool](Initialize-FastLlmUiWindowInterop -SourceRoot $root)}catch{Write-Host ('FAIL: interop threw: '+$_.Exception.Message)}
Check $interop 'WPF and the interop load'
if($script:failures.Count -gt 0){throw ('FAIL: '+($script:failures -join '; '))}

$script:FastLlmUiXaml['Test.Sample']=@'
<StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="16" UseLayoutRounding="True">
  <TextBlock x:Name="TitleText" Text="Fluent harness check" TextWrapping="Wrap" FontSize="{DynamicResource FastLlm.TitleSize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}" Margin="0,0,0,8"/>
  <TextBlock x:Name="BodyText" TextWrapping="Wrap" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextSecondaryBrush}" Margin="0,0,0,12" Text="This sample page exists only to exercise the layout and accessibility checks. It holds a heading, a paragraph that wraps over several lines, a labelled text box, a check box and two buttons, one of them an icon button with a spoken name."/>
  <TextBlock x:Name="NameLabel" Text="Example field" TextWrapping="Wrap" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}" Margin="0,0,0,4"/>
  <TextBox x:Name="NameBox" AutomationProperties.LabeledBy="{Binding ElementName=NameLabel}" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}" Background="{DynamicResource FastLlm.CardBrush}" BorderBrush="{DynamicResource FastLlm.ControlStrongStrokeBrush}" Margin="0,0,0,12"/>
  <CheckBox x:Name="OptionBox" Content="Example option" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}" Margin="0,0,0,12"/>
  <StackPanel Orientation="Vertical">
    <Button x:Name="AccentButton" Content="Example action" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextOnAccentBrush}" Background="{DynamicResource FastLlm.AccentFillBrush}" HorizontalAlignment="Left" Padding="12,6,12,6" Margin="0,0,0,8"/>
    <Button x:Name="IconButton" Width="32" Height="32" HorizontalAlignment="Left" FontFamily="{DynamicResource FastLlm.IconFont}" FontSize="{DynamicResource FastLlm.CaptionSize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}" Background="{DynamicResource FastLlm.CardBrush}" Content="&#xE8C8;" AutomationProperties.Name="Copy example" ToolTip="Copy example"/>
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

$out=$env:FASTLLM_RENDER_DIR
if([string]::IsNullOrEmpty($out)){
    if(-not [string]::IsNullOrEmpty($env:RUNNER_TEMP)){$out=Join-Path $env:RUNNER_TEMP 'fastllm-fluent-render'}
    else{$out=[IO.Path]::GetTempPath()}
}
[void][IO.Directory]::CreateDirectory($out)

$matrix=@(Get-UiRenderMatrix)
Check ($matrix.Count -eq 40) 'the matrix has 40 cases'
Check (@($matrix|Where-Object{$_.textScale -eq 2.25}).Count -eq 1) 'the matrix has the 225% text case'

# Each negative page shows exactly its own problem.
$neg=@{Overlap='overlap:BtnA:BtnB';Clipped='clipped:ClippedText';Unnamed='unnamed:Button';TabOrder='tab-order';Outside='outside:FarBox'}
$base=@{theme='light';scale=[double]1.0;textScale=[double]1.0;width=640;height=480}
foreach($n in 'Overlap','Clipped','Unnamed','TabOrder','Outside'){
    $found=@()
    try{$found=@((Invoke-UiRenderCase -Name ('Test.'+$n) -Case $base).problems)}catch{$found=@('threw: '+$_.Exception.Message)}
    Check ($found.Count -eq 1 -and $found[0] -ceq $neg[$n]) ("the harness catches $n (expected '"+$neg[$n]+"', got '"+($found -join '; ')+"')")
}

$sw=[Diagnostics.Stopwatch]::StartNew()
foreach($case in $matrix){
    $label="$($case.theme) $($case.scale) $($case.textScale) $($case.width)x$($case.height)"
    $r=$null
    try{$r=Invoke-UiRenderCase -Name 'Test.Sample' -Case $case -OutFolder $out}catch{Check $false "sample page renders at ${label}: $($_.Exception.Message)";continue}
    Check (@($r.problems).Count -eq 0) "sample page clean at ${label}: $(@($r.problems) -join '; ')"
    $real=$false
    if(Test-Path -LiteralPath $r.png){
        $info=Get-UiPngInfo -Path $r.png
        $real=($info.width -eq [int][Math]::Ceiling($case.width*$case.scale)) -and ($info.height -eq [int][Math]::Ceiling($case.height*$case.scale)) -and $info.hasContent
    }
    Check $real "the render is real at $label"
}
Write-Host ('INFO: render matrix of {0} cases took {1:N1} s' -f $matrix.Count,$sw.Elapsed.TotalSeconds)

if($script:failures.Count -gt 0){throw ("FAIL: $($script:failures.Count) check(s) failed: "+($script:failures -join ' | '))}
Write-Host "PASS: ui render tests ($($script:checks) checks)"
