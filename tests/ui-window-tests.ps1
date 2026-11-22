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

$onWindows=($PSVersionTable.PSVersion.Major -le 5) -or [bool](Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue)
if(-not $onWindows){Write-Host 'SKIP: Windows only';exit 0}

Check ([Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA') 'runs on an STA thread'
Check (Initialize-FastLlmUiWindowInterop -SourceRoot $root) 'the interop compiles'
Check (Initialize-FastLlmUiWindowInterop -SourceRoot $root) 'a second load is a no-op'
Check ([Bitworks.FastLlm.FluentWindowNative]::GetOsBuild() -ge 10240) 'the OS build is read'
Check ([Bitworks.FastLlm.FluentWindowNative]::SetDarkTitleBar([IntPtr]::Zero,$true) -ne 0) 'a zero window fails with an HRESULT, not an exception'
Check ([Bitworks.FastLlm.FluentWindowNative]::SetSystemBackdrop([IntPtr]::Zero,2) -ne 0) 'backdrop on a zero window fails softly'
Check (-not [Bitworks.FastLlm.FluentWindowNative]::DestroyIconHandle([IntPtr]::Zero)) 'destroying no icon is false'
Check ([Bitworks.FastLlm.FluentWindowNative]::GetGdiObjectCount() -gt 0) 'GDI objects are counted'

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

# Cross-check the accent palette indexes against the WinRT UISettings (Windows PowerShell 5.1 only).
if($PSVersionTable.PSVersion.Major -le 5){
    $ui=$null
    try{
        [void][Windows.UI.ViewManagement.UISettings,Windows.UI.ViewManagement,ContentType=WindowsRuntime]
        $ui=New-Object Windows.UI.ViewManagement.UISettings
    }catch{Write-Host ('INFO: UISettings not available: '+$_.Exception.Message)}
    $pal=$theme.accentPalette
    if($null -eq $ui){Write-Host 'INFO: accent palette cross-check skipped (no UISettings)'}
    elseif($null -eq $pal){Write-Host 'INFO: accent palette cross-check skipped (no AccentPalette value)'}
    elseif($pal -isnot [byte[]]){Check $false 'a present AccentPalette is a byte[]'}
    else{
        $conv=ConvertFrom-FastLlmUiAccentPalette $pal
        if($null -eq $conv){Write-Host 'INFO: accent palette cross-check skipped (AccentPalette is not 32 bytes)'}
        else{
            $argb={param($c) '#FF{0:X2}{1:X2}{2:X2}' -f $c.R,$c.G,$c.B}
            $ud1=& $argb ($ui.GetColorValue([Windows.UI.ViewManagement.UIColorType]::AccentDark1))
            $ul2=& $argb ($ui.GetColorValue([Windows.UI.ViewManagement.UIColorType]::AccentLight2))
            Check ($conv.dark1 -ceq $ud1) ('dark1 matches UISettings AccentDark1 ('+$conv.dark1+' vs '+$ud1+')')
            Check ($conv.light2 -ceq $ul2) ('light2 matches UISettings AccentLight2 ('+$conv.light2+' vs '+$ul2+')')
        }
    }
}else{Write-Host 'INFO: accent palette cross-check runs on Windows PowerShell 5.1 only'}

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
$dl=New-FastLlmUiThemeDictionary -Theme light -AccentPair $pair -TextScale 1.0
$dd=New-FastLlmUiThemeDictionary -Theme dark -AccentPair $pair -TextScale 1.0
Check ($dl['FastLlm.AccentFillBrush'].Color.ToString() -ceq '#FF005FB8') 'light uses the light accent fill'
Check ($dd['FastLlm.AccentFillBrush'].Color.ToString() -ceq '#FF60CDFF') 'dark uses the dark accent fill'
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
Check ($hp['FastLlm.LayerBrush'].IsFrozen -and $hp['FastLlm.TextPrimaryBrush'].IsFrozen) 'palette brushes are frozen'

Write-Host "UI window tests passed: $checks"
