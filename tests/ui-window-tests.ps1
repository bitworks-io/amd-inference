#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
$checks=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:checks++}

. (Join-Path $root 'src/FastLlm.UiTheme.ps1')
. (Join-Path $root 'src/FastLlm.UiWindow.ps1')

# Pure, any OS: a REG_BINARY byte[] must survive the property reader as a byte[] (the pipeline would unroll it to Object[]).
$fakeKey=[pscustomobject]@{AccentPalette=[byte[]](1..32);AppsUseLightTheme=0}
$bytes=Get-FastLlmUiPropertyValue $fakeKey 'AccentPalette'
Check ($bytes -is [byte[]] -and $bytes.Length -eq 32) 'a 32-byte palette stays a byte[] of 32'
$capture=[pscustomobject]@{accentPalette=Get-FastLlmUiPropertyValue $fakeKey 'AccentPalette'}
Check ($capture.accentPalette -is [byte[]] -and $capture.accentPalette.Length -eq 32) 'the palette stays a byte[] inside the theme object'
Check ($null -ne (ConvertFrom-FastLlmUiAccentPalette $capture.accentPalette)) 'the captured palette parses'
$dword=Get-FastLlmUiPropertyValue $fakeKey 'AppsUseLightTheme'
Check ($dword -is [int] -and $dword -eq 0) 'a DWORD stays an Int32'
Check ($null -eq (Get-FastLlmUiPropertyValue $fakeKey 'Missing')) 'a missing value is null'
Check ($null -eq (Get-FastLlmUiPropertyValue $null 'AccentPalette')) 'a missing key is null'

# Pure, any OS: the registry reader keeps a REG_BINARY byte[] intact, proven with a local Get-ItemProperty stand-in (removed right after).
function Get-ItemProperty{
    [CmdletBinding()]
    param([string]$LiteralPath)
    if($LiteralPath -ceq 'HKCU:\Mock\Present'){return [pscustomobject]@{AccentPalette=[byte[]](1..32)}}
    return [pscustomobject]@{Other=1}
}
try{
    $direct=Get-FastLlmUiRegistryValue 'HKCU:\Mock\Present' 'AccentPalette'
    Check ($direct -is [byte[]] -and $direct.Length -eq 32) 'the registry reader returns a 32-byte palette as a byte[]'
    $wrapped=[pscustomobject]@{v=(Get-FastLlmUiRegistryValue 'HKCU:\Mock\Present' 'AccentPalette')}
    Check ($wrapped.v -is [byte[]] -and $wrapped.v.Length -eq 32) 'the registry reader keeps the byte[] inside a theme object'
    Check ($null -eq (Get-FastLlmUiRegistryValue 'HKCU:\Mock\Present' 'NoSuchName')) 'the registry reader gives null for a missing name'
}finally{Remove-Item function:Get-ItemProperty -ErrorAction SilentlyContinue}
Check ((Get-Command Get-ItemProperty).CommandType -eq 'Cmdlet') 'the Get-ItemProperty stand-in is gone before the Windows part'

$onWindows=($PSVersionTable.PSVersion.Major -le 5) -or [bool](Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue)
if(-not $onWindows){Write-Host 'SKIP: Windows only';exit 0}

Check ([Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA') 'runs on an STA thread'
$interop=[bool](Initialize-FastLlmUiWindowInterop -SourceRoot $root)
if(-not $interop){
    try{Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase -ErrorAction Stop}catch{Write-Host ('INFO: interop load error: '+$_.Exception.ToString())}
    try{Add-Type -Path (Join-Path $root 'src/WindowsFluentWindow.cs') -ErrorAction Stop}catch{Write-Host ('INFO: interop load error: '+$_.Exception.ToString())}
}
Check $interop 'the interop compiles'
Check (Initialize-FastLlmUiWindowInterop -SourceRoot $root) 'a second load is a no-op'
Check ([Bitworks.FastLlm.FluentWindowNative]::GetOsBuild() -ge 10240) 'the OS build is read'
Check ([Bitworks.FastLlm.FluentWindowNative]::SetDarkTitleBar([IntPtr]::Zero,$true) -ne 0) 'a zero window fails with an HRESULT, not an exception'
Check ([Bitworks.FastLlm.FluentWindowNative]::SetSystemBackdrop([IntPtr]::Zero,2) -ne 0) 'backdrop on a zero window fails softly'
Check (-not [Bitworks.FastLlm.FluentWindowNative]::DestroyIconHandle([IntPtr]::Zero)) 'destroying no icon is false'
Check ([Bitworks.FastLlm.FluentWindowNative]::ExtendFrameIntoClientArea([IntPtr]::Zero) -ne 0) 'frame extension on a zero window fails softly'
Add-Type -AssemblyName System.Drawing
$gdiBefore=[Bitworks.FastLlm.FluentWindowNative]::GetGdiObjectCount()
$bmp=New-Object System.Drawing.Bitmap 16,16
try{
    $hIcon=$bmp.GetHicon()
    $gdiAfter=[Bitworks.FastLlm.FluentWindowNative]::GetGdiObjectCount()
    Check ($gdiAfter -gt $gdiBefore) 'creating an icon adds GDI objects'
    Check ([Bitworks.FastLlm.FluentWindowNative]::DestroyIconHandle($hIcon)) 'a real icon handle is destroyed'
}finally{$bmp.Dispose()}

# A real WPF window, far off screen, to prove the calls return an int on a live handle.
$win=New-Object System.Windows.Window
$win.Left=-32000;$win.Top=-32000;$win.Width=200;$win.Height=120
$win.ShowActivated=$false;$win.ShowInTaskbar=$false
try{
    $win.Show()
    $hwnd=(New-Object System.Windows.Interop.WindowInteropHelper $win).Handle
    Check ($hwnd -ne [IntPtr]::Zero) 'the window has a handle'
    $hrDark=[Bitworks.FastLlm.FluentWindowNative]::SetDarkTitleBar($hwnd,$true)
    $hrMica=[Bitworks.FastLlm.FluentWindowNative]::SetSystemBackdrop($hwnd,2)
    $hrFrame=[Bitworks.FastLlm.FluentWindowNative]::ExtendFrameIntoClientArea($hwnd)
    Check ($hrDark -is [int] -and $hrMica -is [int] -and $hrFrame -is [int]) 'the three window calls return an int'
    Write-Host ('INFO: build {0}; dark title bar 0x{1:X8}; backdrop 0x{2:X8}; frame 0x{3:X8}' -f [Bitworks.FastLlm.FluentWindowNative]::GetOsBuild(),$hrDark,$hrMica,$hrFrame)
}finally{$win.Close()}

$theme=Read-FastLlmUiSystemTheme
Check ($null -eq $theme.accentPalette -or $theme.accentPalette -is [byte[]]) 'the accent palette is read as bytes'
if($null -ne $theme.accentPalette){Check ($theme.accentPalette -is [byte[]] -and $theme.accentPalette.Length -eq 32) 'a present accent palette is 32 bytes'}
Check ($theme.build -gt 0 -and $theme.highContrast -is [bool]) 'the system theme is read without throwing'

# Cross-check the accent palette indexes against the WinRT UISettings (Windows PowerShell 5.1 only). One greppable CROSSCHECK line says what happened.
$crossSkip=''
if($PSVersionTable.PSVersion.Major -gt 5){$crossSkip='runs on Windows PowerShell 5.1 only'}
else{
    $ui=$null
    try{
        $uiType='Windows.UI.ViewManagement.UISettings,Windows.UI.ViewManagement,ContentType=WindowsRuntime' -as [type]
        if($null -eq $uiType){$crossSkip='UISettings type not available'}
        else{$ui=[Activator]::CreateInstance($uiType)}
    }catch{$crossSkip='UISettings not available: '+$_.Exception.Message}
    $pal=$theme.accentPalette
    if($crossSkip -cne ''){}
    elseif($null -eq $pal){$crossSkip='no AccentPalette value'}
    elseif($pal -isnot [byte[]]){Check $false 'a present AccentPalette is a byte[]'}
    else{
        $conv=ConvertFrom-FastLlmUiAccentPalette $pal
        if($null -eq $conv){$crossSkip='AccentPalette is not 32 bytes'}
        else{
            $argb={param($c) '#FF{0:X2}{1:X2}{2:X2}' -f $c.R,$c.G,$c.B}
            $ud1=''
            $ul2=''
            try{
                $ud1=& $argb ($ui.GetColorValue('AccentDark1'))
                $ul2=& $argb ($ui.GetColorValue('AccentLight2'))
            }catch{$crossSkip='UISettings colour read failed: '+$_.Exception.Message}
            if($crossSkip -ceq ''){
                Check ($conv.dark1 -ceq $ud1) ('dark1 matches UISettings AccentDark1 ('+$conv.dark1+' vs '+$ud1+')')
                Check ($conv.light2 -ceq $ul2) ('light2 matches UISettings AccentLight2 ('+$conv.light2+' vs '+$ul2+')')
            }
        }
    }
}
if($crossSkip -ceq ''){Write-Host 'CROSSCHECK: ran'}else{Write-Host ('CROSSCHECK: skipped ('+$crossSkip+')')}

# The dictionary.
$pair=Get-FastLlmUiAccentPair $null
$tokenNames=@((Get-FastLlmUiThemeTokens -Theme light).Keys)
$keys=New-Object System.Collections.ArrayList
foreach($t in $tokenNames){[void]$keys.Add('FastLlm.'+$t+'Brush')}
foreach($s in 'Caption','Body','BodyStrong','Subtitle','Title'){foreach($x in 'Size','LineHeight','Weight'){[void]$keys.Add('FastLlm.'+$s+$x)}}
foreach($k in 'TextFont','DisplayFont','IconFont','MonoFont','ControlCornerRadius','OverlayCornerRadius','ControlHeight','FocusThickness'){[void]$keys.Add('FastLlm.'+$k)}
foreach($theme in 'light','dark'){
    $d=New-FastLlmUiThemeDictionary -Theme $theme -AccentPair $pair -TextScale 1.0
    Check ($d -is [System.Windows.ResourceDictionary]) ($theme+' dictionary is a ResourceDictionary')
    foreach($k in $keys){Check ($d.Contains($k)) ($theme+' dictionary has '+$k)}
    foreach($t in $tokenNames){Check ($d['FastLlm.'+$t+'Brush'].IsFrozen) ($theme+' '+$t+' brush is frozen')}
    Check ($d['FastLlm.BodySize'] -is [double] -and $d['FastLlm.BodySize'] -eq 14.0) ($theme+' body size is a double 14')
    Check ($d['FastLlm.TitleWeight'] -eq [System.Windows.FontWeights]::SemiBold -and $d['FastLlm.BodyWeight'] -eq [System.Windows.FontWeights]::Regular) ($theme+' weights map')
}
$custom=@{lightFill='#FF123456';darkFill='#FF654321';lightSource='system';darkSource='system'}
$dl=New-FastLlmUiThemeDictionary -Theme light -AccentPair $custom -TextScale 1.0
$dd=New-FastLlmUiThemeDictionary -Theme dark -AccentPair $custom -TextScale 1.0
Check ($dl['FastLlm.AccentFillBrush'].Color.ToString() -ceq '#FF123456') 'light uses the light accent fill from the pair'
Check ($dd['FastLlm.AccentFillBrush'].Color.ToString() -ceq '#FF654321') 'dark uses the dark accent fill from the pair'
$d225=New-FastLlmUiThemeDictionary -Theme light -AccentPair $pair -TextScale 2.25
Check ($d225['FastLlm.BodySize'] -eq 31.5) 'the text scale reaches the dictionary'

$hc=New-FastLlmUiThemeDictionary -Theme high-contrast -AccentPair $pair -TextScale 1.0
foreach($k in $keys){Check ($hc.Contains($k)) ('high-contrast dictionary has '+$k)}
Check ([object]::ReferenceEquals($hc['FastLlm.TextPrimaryBrush'],[System.Windows.SystemColors]::WindowTextBrush)) 'high contrast text is the system WindowText brush itself'
Check ([object]::ReferenceEquals($hc['FastLlm.LayerBrush'],[System.Windows.SystemColors]::WindowBrush)) 'high contrast layer is the system Window brush itself'
Check ([object]::ReferenceEquals($hc['FastLlm.AccentFillBrush'],[System.Windows.SystemColors]::HighlightBrush)) 'high contrast accent is the system Highlight brush itself'
Check ([object]::ReferenceEquals($hc['FastLlm.TextOnAccentBrush'],[System.Windows.SystemColors]::HighlightTextBrush)) 'high contrast text on accent is the system HighlightText brush itself'
$pal=@{Window='#000000';WindowText='#FFFF00';Highlight='#1AEBFF';HighlightText='#000000'}
$hp=New-FastLlmUiThemeDictionary -Theme high-contrast -AccentPair $pair -TextScale 1.0 -HighContrastPalette $pal
Check ($hp['FastLlm.LayerBrush'].Color.ToString() -ceq '#FF000000') 'the palette Window colour reaches the layer brush'
Check ($hp['FastLlm.TextPrimaryBrush'].Color.ToString() -ceq '#FFFFFF00') 'the palette WindowText colour reaches the text brush'
Check ($hp['FastLlm.AccentFillBrush'].Color.ToString() -ceq '#FF1AEBFF') 'the palette Highlight colour reaches the accent brush'
Check ($hp['FastLlm.TextOnAccentBrush'].Color.ToString() -ceq '#FF000000') 'the palette HighlightText colour reaches the text-on-accent brush'
Check ($hp['FastLlm.LayerBrush'].IsFrozen -and $hp['FastLlm.TextPrimaryBrush'].IsFrozen) 'palette brushes are frozen'

$dl2=New-FastLlmUiThemeDictionary -Theme light -AccentPair $pair -TextScale 1.0
$dd2=New-FastLlmUiThemeDictionary -Theme dark -AccentPair $pair -TextScale 1.0

# Behavioural check: the dictionary must work when APPLIED to an element (a wrapped value is rejected by WPF at assignment).
$applyCases=@(
    @{name='light';dict=$dl2;theme='light'},
    @{name='dark';dict=$dd2;theme='dark'},
    @{name='high-contrast palette';dict=$hp;theme='high-contrast'}
)
foreach($case in $applyCases){
    $err=$null
    try{
        $tb=[System.Windows.Controls.TextBlock]::new()
        $border=[System.Windows.Controls.Border]::new()
        $border.Child=$tb
        $border.Resources=$case.dict
        $tb.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty,'FastLlm.TextPrimaryBrush')
        $tb.SetResourceReference([System.Windows.Controls.TextBlock]::FontFamilyProperty,'FastLlm.TextFont')
        $tb.SetResourceReference([System.Windows.Controls.TextBlock]::FontSizeProperty,'FastLlm.BodySize')
        $tb.SetResourceReference([System.Windows.Controls.TextBlock]::FontWeightProperty,'FastLlm.BodyWeight')
        $border.SetResourceReference([System.Windows.Controls.Border]::CornerRadiusProperty,'FastLlm.ControlCornerRadius')
        $border.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty,'FastLlm.CardBrush')
        $border.Measure([System.Windows.Size]::new(200,100))
        $border.Arrange([System.Windows.Rect]::new(0,0,200,100))
    }catch{$err=$_.Exception.Message}
    Check ($null -eq $err) ($case.name+' dictionary applies to elements without an exception: '+$err)
    $expectText=if($case.theme -ceq 'high-contrast'){'#FFFFFF00'}else{(Get-FastLlmUiThemeTokens -Theme $case.theme).TextPrimary}
    Check ($tb.Foreground -is [System.Windows.Media.SolidColorBrush]) ($case.name+' resolved Foreground is a SolidColorBrush')
    Check ($tb.Foreground.Color.ToString() -ceq ([System.Windows.Media.ColorConverter]::ConvertFromString($expectText)).ToString()) ($case.name+' resolved Foreground is the TextPrimary colour')
    Check ($tb.FontSize -eq [double](Get-FastLlmUiTypeRamp -TextScale 1.0).Body.size) ($case.name+' resolved FontSize is the ramp Body size')
    Check ($tb.FontFamily.Source -ceq [string](Get-FastLlmUiMetrics).TextFont) ($case.name+' resolved FontFamily is the TextFont metric')
    Check ($border.CornerRadius.TopLeft -eq 4) ($case.name+' resolved CornerRadius is 4')
    Check ($border.Background -is [System.Windows.Media.SolidColorBrush]) ($case.name+' resolved Background is a SolidColorBrush')
}

# RED self-check: a dictionary built the OLD way (a New-Object brush returned through a scriptblock and stored through the indexer, which keeps
# the PSObject wrapper) must fail to apply, so the apply test above can catch that bug. The same brush stored as its raw object must resolve.
function Test-FastLlmApplyBrush($Dict){
    $r=@{err=$null;fg=$null}
    try{
        $tb=[System.Windows.Controls.TextBlock]::new()
        $border=[System.Windows.Controls.Border]::new()
        $border.Child=$tb
        $border.Resources=$Dict
        $tb.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty,'FastLlm.TextPrimaryBrush')
        $border.Measure([System.Windows.Size]::new(200,100))
        $border.Arrange([System.Windows.Rect]::new(0,0,200,100))
        $r.fg=$tb.Foreground
    }catch{$r.err=$_.Exception.Message}
    return $r
}
$oldNewBrush={
    param([string]$Argb)
    $b=New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Argb))
    $b.Freeze()
    return $b
}
$wrapped=& $oldNewBrush '#FF112233'
$dOld=New-Object System.Windows.ResourceDictionary
$dOld['FastLlm.TextPrimaryBrush']=$wrapped
$rOld=Test-FastLlmApplyBrush $dOld
$oldResolves=($null -eq $rOld.err) -and ($rOld.fg -is [System.Windows.Media.SolidColorBrush]) -and ($rOld.fg.Color.ToString() -ceq '#FF112233')
Check (-not $oldResolves) 'a wrapped resource value fails to resolve (the old bug is caught)'
$dNew=New-Object System.Windows.ResourceDictionary
$dNew['FastLlm.TextPrimaryBrush']=[System.Management.Automation.PSObject]::AsPSObject($wrapped).BaseObject
$rNew=Test-FastLlmApplyBrush $dNew
Check (($null -eq $rNew.err) -and ($rNew.fg -is [System.Windows.Media.SolidColorBrush]) -and ($rNew.fg.Color.ToString() -ceq '#FF112233')) ('the same brush stored as its raw object resolves: '+$rNew.err)

Write-Host "UI window tests passed: $checks"
exit 0
