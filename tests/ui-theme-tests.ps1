#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/FastLlm.UiTheme.ps1')
$checks=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:checks++}
$inv=[Globalization.CultureInfo]::InvariantCulture
$rows=New-Object System.Collections.ArrayList

# Colour parsing, composition and the WCAG ratio.
Check ((ConvertFrom-FastLlmUiColor '#B3FFFFFF').a -eq 179) 'ARGB parses alpha first'
Check ((ConvertFrom-FastLlmUiColor '#102030').a -eq 255 -and (ConvertFrom-FastLlmUiColor '#102030').g -eq 32) 'RGB parses as opaque'
foreach($bad in @('red','#12345','#GGGGGG','','#1234567890',' #FFFFFF')){
    $threw=$false;try{[void](ConvertFrom-FastLlmUiColor $bad)}catch{$threw=($_.Exception.Message -like 'Invalid colour*')}
    Check $threw ('an invalid colour throws: '+$bad)
}
Check ([Math]::Abs((Get-FastLlmUiContrastRatio '#FFFFFFFF' '#FF000000') - 21) -lt 0.01) 'white on black is 21:1'
Check ([Math]::Abs((Get-FastLlmUiContrastRatio '#FF767676' '#FFFFFFFF') - 4.54) -lt 0.01) 'the WCAG reference grey is 4.54:1'
Check ((Get-FastLlmUiContrastRatio '#FF000000' '#FFFFFFFF') -is [double]) 'the ratio is a double'
Check ((Get-FastLlmUiCompositeColor '#80000000' '#FFFFFFFF') -ceq '#FF7F7F7F') 'half black over white'
Check ((Get-FastLlmUiCompositeColor '#FF123456' '#FFFFFFFF') -ceq '#FF123456') 'opaque foreground wins'
$threw=$false;try{[void](Get-FastLlmUiCompositeColor '#80000000' '#80FFFFFF')}catch{$threw=$true}
Check $threw 'a translucent background is refused'

# Tokens, exact strings.
$expect=@{
 light=[ordered]@{Layer='#FFF3F3F3';Card='#B3FFFFFF';CardStroke='#0F000000';Flyout='#FFF9F9F9';TextPrimary='#E4000000';TextSecondary='#9E000000';ControlStroke='#0F000000';ControlStrongStroke='#72000000';TextOnAccent='#FFFFFFFF';SuccessText='#FF0F7B0F';CautionText='#FF9D5D00';CriticalText='#FFC42B1C';SuccessBackground='#FFDFF6DD';CautionBackground='#FFFFF4CE';CriticalBackground='#FFFDE7E9'}
 dark=[ordered]@{Layer='#FF202020';Card='#0DFFFFFF';CardStroke='#19000000';Flyout='#FF2C2C2C';TextPrimary='#FFFFFFFF';TextSecondary='#C5FFFFFF';ControlStroke='#12FFFFFF';ControlStrongStroke='#8BFFFFFF';TextOnAccent='#FF000000';SuccessText='#FF6CCB5F';CautionText='#FFFCE100';CriticalText='#FFFF99A4';SuccessBackground='#FF393D1B';CautionBackground='#FF433519';CriticalBackground='#FF442726'}
}
$keys='Layer,Card,CardStroke,Flyout,TextPrimary,TextSecondary,ControlStroke,ControlStrongStroke,AccentFill,TextOnAccent,SuccessText,CautionText,CriticalText,SuccessBackground,CautionBackground,CriticalBackground'
$tok=@{}
foreach($theme in 'light','dark'){
    $accent=if($theme -eq 'light'){'#FF005FB8'}else{'#FF60CDFF'}
    $t=Get-FastLlmUiThemeTokens -Theme $theme -AccentFill $accent
    $tok[$theme]=$t
    Check (($t.Keys -join ',') -ceq $keys) ($theme+' token keys and order')
    Check ($t.AccentFill -ceq $accent) ($theme+' AccentFill is passed through')
    foreach($k in $expect[$theme].Keys){Check ($t[$k] -ceq $expect[$theme][$k]) ($theme+' '+$k+' exact value')}
}
$threw=$false;try{[void](Get-FastLlmUiThemeTokens -Theme 'sepia' -AccentFill '#FF005FB8')}catch{$threw=$true}
Check $threw 'an unknown theme throws'

# Contrast pairs.
function Pair([string]$Theme,[string]$Name,[string]$Fg,[string]$Bg,[string]$Layer,[double]$Min,[bool]$AtLeast){
    $r=if($Layer){Get-FastLlmUiContrastRatio $Fg $Bg $Layer}else{Get-FastLlmUiContrastRatio $Fg $Bg}
    [void]$rows.Add(('{0}|{1}|{2}' -f $Theme,$Name,$r.ToString('0.00',$inv)))
    if($AtLeast){Check ($r -ge $Min) ($Theme+' '+$Name+' >= '+$Min.ToString($inv)+' (got '+$r.ToString('0.00',$inv)+')')}
    else{Check ($r -lt $Min) ($Theme+' '+$Name+' < '+$Min.ToString($inv)+' (got '+$r.ToString('0.00',$inv)+')')}
}
foreach($theme in 'light','dark'){
    $t=$tok[$theme]
    foreach($n in 'TextPrimary','TextSecondary','SuccessText','CautionText','CriticalText'){Pair $theme ($n+' on Card') $t[$n] $t.Card $t.Layer 4.5 $true}
    Pair $theme 'TextPrimary on Flyout' $t.TextPrimary $t.Flyout '' 4.5 $true
    Pair $theme 'TextSecondary on Flyout' $t.TextSecondary $t.Flyout '' 4.5 $true
    Pair $theme 'TextSecondary on Layer' $t.TextSecondary $t.Layer '' 4.5 $true
    foreach($s in 'Success','Caution','Critical'){Pair $theme ($s+'Text on '+$s+'Background') $t[$s+'Text'] $t[$s+'Background'] '' 4.5 $true}
    Pair $theme 'TextOnAccent on AccentFill' $t.TextOnAccent $t.AccentFill '' 4.5 $true
    Pair $theme 'ControlStrongStroke on Card' $t.ControlStrongStroke $t.Card $t.Layer 3.0 $true
    Pair $theme 'ControlStrongStroke on Layer' $t.ControlStrongStroke $t.Layer '' 3.0 $true
    Pair $theme 'ControlStroke on Card' $t.ControlStroke $t.Card $t.Layer 3.0 $false
}

# The Flyout surface is a popup's own window, so it is opaque (alpha FF); Card stays translucent. A translucent Flyout must fail the check.
function Test-FlyoutOpaque([string]$Argb){ return ($Argb -cmatch '^#FF[0-9A-F]{6}$') }
foreach($theme in 'light','dark'){
    Check (Test-FlyoutOpaque $tok[$theme].Flyout) ($theme+' Flyout is opaque (alpha FF)')
    Check (-not (Test-FlyoutOpaque $tok[$theme].Card)) ($theme+' Card stays translucent (not a popup surface)')
    Check (-not (Test-FlyoutOpaque ('#B3'+$tok[$theme].Flyout.Substring(3)))) ($theme+' mutant: a translucent Flyout fails the opaque check')
}

# Metrics.
$m=Get-FastLlmUiMetrics
Check ($m.ControlCornerRadius -eq 4 -and $m.OverlayCornerRadius -eq 8 -and $m.ControlHeight -eq 32 -and $m.CardPadding -eq 16 -and $m.FocusThickness -eq 2) 'metrics numbers'
Check ($m.TextFont -ceq 'Segoe UI Variable Text, Segoe UI' -and $m.DisplayFont -ceq 'Segoe UI Variable Display, Segoe UI' -and $m.IconFont -ceq 'Segoe Fluent Icons, Segoe MDL2 Assets' -and $m.MonoFont -ceq 'Cascadia Mono, Consolas') 'metrics fonts'

# Type ramp.
$r1=Get-FastLlmUiTypeRamp 1.0
$want=@{Caption=@(12,16,'Regular');Body=@(14,20,'Regular');BodyStrong=@(14,20,'SemiBold');Subtitle=@(20,28,'SemiBold');Title=@(28,36,'SemiBold')}
foreach($k in $want.Keys){
    Check ($r1[$k].size -eq $want[$k][0] -and $r1[$k].lineHeight -eq $want[$k][1] -and $r1[$k].weight -ceq $want[$k][2]) ('ramp 1.0 '+$k)
    Check ($r1[$k].size -is [double] -and $r1[$k].lineHeight -is [double]) ('ramp doubles '+$k)
}
Check ((Get-FastLlmUiTypeRamp 1.5).Body.size -eq 21 -and (Get-FastLlmUiTypeRamp 1.5).Body.lineHeight -eq 30) 'ramp at 1.5'
Check ((Get-FastLlmUiTypeRamp 9).Title.size -eq 63 -and (Get-FastLlmUiTypeRamp 9).Title.lineHeight -eq 81) 'ramp clamps high to 2.25'
Check ((Get-FastLlmUiTypeRamp 0.5).Title.size -eq 28 -and (Get-FastLlmUiTypeRamp).Caption.size -eq 12) 'ramp clamps low to 1.0 and defaults to 1.0'

# Text scale.
Check ((ConvertFrom-FastLlmUiTextScaleFactor 150) -eq 1.5 -and (ConvertFrom-FastLlmUiTextScaleFactor 300) -eq 2.25 -and (ConvertFrom-FastLlmUiTextScaleFactor 50) -eq 1.0 -and (ConvertFrom-FastLlmUiTextScaleFactor $null) -eq 1.0) 'text scale'
Check ((ConvertFrom-FastLlmUiTextScaleFactor 100) -eq 1.0 -and (ConvertFrom-FastLlmUiTextScaleFactor 225) -eq 2.25 -and (ConvertFrom-FastLlmUiTextScaleFactor 226) -eq 2.25 -and (ConvertFrom-FastLlmUiTextScaleFactor 99) -eq 1.0) 'text scale edges'
Check ((ConvertFrom-FastLlmUiTextScaleFactor '150') -eq 1.0 -and (ConvertFrom-FastLlmUiTextScaleFactor 150.0) -eq 1.0 -and (ConvertFrom-FastLlmUiTextScaleFactor ([long]150)) -eq 1.5 -and (ConvertFrom-FastLlmUiTextScaleFactor @(150)) -eq 1.0) 'text scale wrong types'

# Theme choice.
Check ((Get-FastLlmUiThemeChoice $null $false) -ceq 'light' -and (Get-FastLlmUiThemeChoice 'x' $false) -ceq 'light' -and (Get-FastLlmUiThemeChoice 0 $false) -ceq 'dark' -and (Get-FastLlmUiThemeChoice 1 $false) -ceq 'light' -and (Get-FastLlmUiThemeChoice 0 $true) -ceq 'high-contrast') 'theme choice'
Check ((Get-FastLlmUiThemeChoice '0' $false) -ceq 'light' -and (Get-FastLlmUiThemeChoice ([long]0) $false) -ceq 'dark' -and (Get-FastLlmUiThemeChoice $null $true) -ceq 'high-contrast') 'theme choice types'

# Accent palette.
Check ($null -eq (ConvertFrom-FastLlmUiAccentPalette ([byte[]]::new(31))) -and $null -eq (ConvertFrom-FastLlmUiAccentPalette $null) -and $null -eq (ConvertFrom-FastLlmUiAccentPalette ([byte[]]::new(33))) -and $null -eq (ConvertFrom-FastLlmUiAccentPalette 'x')) 'a malformed palette is ignored'
function New-Palette([byte[]]$Light2,[byte[]]$Dark1){
    $p=[byte[]]::new(32);for($i=0;$i -lt 3;$i++){$p[4+$i]=$Light2[$i];$p[16+$i]=$Dark1[$i]};$p[7]=1;$p[19]=2;return ,$p
}
$good=New-Palette ([byte[]](0x60,0xCD,0xFF)) ([byte[]](0x00,0x5F,0xB8))
$pp=ConvertFrom-FastLlmUiAccentPalette $good
Check ($pp.dark1 -ceq '#FF005FB8' -and $pp.light2 -ceq '#FF60CDFF') 'palette indexes (alpha ignored)'
$pair=Get-FastLlmUiAccentPair $good
Check ($pair.lightSource -ceq 'system' -and $pair.darkSource -ceq 'system' -and $pair.lightFill -ceq '#FF005FB8' -and $pair.darkFill -ceq '#FF60CDFF') 'a good palette is used'
$yellow=New-Palette ([byte[]](0x60,0xCD,0xFF)) ([byte[]](0xFF,0xE6,0x80))
$pair=Get-FastLlmUiAccentPair $yellow
Check ($pair.lightSource -ceq 'default' -and $pair.lightFill -ceq '#FF005FB8' -and $pair.darkSource -ceq 'system') 'a pale dark1 falls back for light only'
$darkL2=New-Palette ([byte[]](0x20,0x20,0x20)) ([byte[]](0x00,0x5F,0xB8))
$pair=Get-FastLlmUiAccentPair $darkL2
Check ($pair.darkSource -ceq 'default' -and $pair.darkFill -ceq '#FF60CDFF' -and $pair.lightSource -ceq 'system') 'a dark light2 falls back for dark only'
$pair=Get-FastLlmUiAccentPair $null
Check ($pair.lightSource -ceq 'default' -and $pair.darkSource -ceq 'default' -and $pair.lightFill -ceq '#FF005FB8' -and $pair.darkFill -ceq '#FF60CDFF') 'no palette gives the default pair'
$pair=Get-FastLlmUiAccentPair ([byte[]]::new(5))
Check ($pair.lightSource -ceq 'default' -and $pair.darkSource -ceq 'default') 'a short palette gives the default pair'
Pair 'light' 'default accent text-on-accent' '#FFFFFFFF' '#FF005FB8' '' 4.5 $true
Pair 'dark' 'default accent text-on-accent' '#FF000000' '#FF60CDFF' '' 4.5 $true

# Backdrop.
Check ((Get-FastLlmUiBackdropChoice 22621 $null $false) -ceq 'mica' -and (Get-FastLlmUiBackdropChoice 22000 1 $false) -ceq 'solid' -and (Get-FastLlmUiBackdropChoice 22621 0 $false) -ceq 'solid' -and (Get-FastLlmUiBackdropChoice 26200 1 $true) -ceq 'solid') 'backdrop choice'
Check ((Get-FastLlmUiBackdropChoice 22620 $null $false) -ceq 'solid' -and (Get-FastLlmUiBackdropChoice 22621 '0' $false) -ceq 'mica' -and (Get-FastLlmUiBackdropChoice 26200 ([long]0) $false) -ceq 'solid') 'backdrop edges'

Write-Host 'Contrast pairs:'
$rows|ForEach-Object{Write-Host ('  '+$_)}
Write-Host "UI theme tests passed: $checks"
exit 0
