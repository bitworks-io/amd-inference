#requires -Version 5.1
# Loaded by the Fluent window. The pure theme layer: colour parsing, alpha composition and the WCAG 2.x contrast ratio, the light and dark
# tokens and metrics, the type ramp with the text scale, the theme choice, the accent palette with its contrast fallback and the
# Mica-or-solid backdrop choice. It touches no registry, WPF or Windows API: the caller reads the raw values and passes them in, so every
# input may be $null or the wrong type and nothing throws except ConvertFrom-FastLlmUiColor on an invalid colour string.

function ConvertFrom-FastLlmUiColor {
    param($Color)
    if ($Color -isnot [string] -or $Color -notmatch '\A#(?:[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})\z') { throw 'Invalid colour' }
    $hex = $Color.Substring(1)
    if ($hex.Length -eq 6) { $hex = 'FF' + $hex }
    $v = @(0, 2, 4, 6 | ForEach-Object { [Convert]::ToInt32($hex.Substring($_, 2), 16) })
    return @{ a = [int]$v[0]; r = [int]$v[1]; g = [int]$v[2]; b = [int]$v[3] }
}

function Get-FastLlmUiCompositeColor {
    param($Foreground, $Background)
    $f = ConvertFrom-FastLlmUiColor $Foreground
    $b = ConvertFrom-FastLlmUiColor $Background
    if ($b.a -ne 255) { throw 'Invalid colour: the background must be opaque' }
    $out = foreach ($c in 'r', 'g', 'b') {
        [int][Math]::Round(($f[$c] * $f.a / 255.0) + ($b[$c] * (1 - $f.a / 255.0)), [MidpointRounding]::AwayFromZero)
    }
    return ('#FF{0:X2}{1:X2}{2:X2}' -f $out[0], $out[1], $out[2])
}

function Get-FastLlmUiRelativeLuminance {
    param($Color)
    $c = ConvertFrom-FastLlmUiColor $Color
    $lin = foreach ($k in 'r', 'g', 'b') {
        $s = $c[$k] / 255.0
        if ($s -le 0.03928) { $s / 12.92 } else { [Math]::Pow(($s + 0.055) / 1.055, 2.4) }
    }
    return [double](0.2126 * $lin[0] + 0.7152 * $lin[1] + 0.0722 * $lin[2])
}

function Get-FastLlmUiContrastRatio {
    param($Foreground, $Background, $Layer)
    $bg = $Background
    if ($null -ne $Layer) { $bg = Get-FastLlmUiCompositeColor $Background $Layer }
    $fg = Get-FastLlmUiCompositeColor $Foreground $bg
    $l1 = Get-FastLlmUiRelativeLuminance $fg
    $l2 = Get-FastLlmUiRelativeLuminance (Get-FastLlmUiCompositeColor $bg '#FF000000')
    $hi = [Math]::Max($l1, $l2)
    $lo = [Math]::Min($l1, $l2)
    return [double](($hi + 0.05) / ($lo + 0.05))
}

function Get-FastLlmUiThemeTokens {
    param([string]$Theme, [string]$AccentFill)
    $light = [ordered]@{
        Layer = '#FFF3F3F3'; Card = '#B3FFFFFF'; CardStroke = '#0F000000'; Flyout = '#FFF9F9F9'
        TextPrimary = '#E4000000'; TextSecondary = '#9E000000'
        ControlStroke = '#0F000000'; ControlStrongStroke = '#72000000'
        DisabledText = '#5C000000'; DisabledFill = '#4DF9F9F9'; DisabledStroke = '#37000000'
        TextOnAccent = '#FFFFFFFF'
        SuccessText = '#FF0F7B0F'; CautionText = '#FF9D5D00'; CriticalText = '#FFC42B1C'
        SuccessBackground = '#FFDFF6DD'; CautionBackground = '#FFFFF4CE'; CriticalBackground = '#FFFDE7E9'
    }
    $dark = [ordered]@{
        Layer = '#FF202020'; Card = '#0DFFFFFF'; CardStroke = '#19000000'; Flyout = '#FF2C2C2C'
        TextPrimary = '#FFFFFFFF'; TextSecondary = '#C5FFFFFF'
        ControlStroke = '#12FFFFFF'; ControlStrongStroke = '#8BFFFFFF'
        DisabledText = '#5DFFFFFF'; DisabledFill = '#0BFFFFFF'; DisabledStroke = '#28FFFFFF'
        TextOnAccent = '#FF000000'
        SuccessText = '#FF6CCB5F'; CautionText = '#FFFCE100'; CriticalText = '#FFFF99A4'
        SuccessBackground = '#FF393D1B'; CautionBackground = '#FF433519'; CriticalBackground = '#FF442726'
    }
    if ($Theme -ceq 'light') { $src = $light; $defaultAccent = '#FF005FB8' }
    elseif ($Theme -ceq 'dark') { $src = $dark; $defaultAccent = '#FF60CDFF' }
    else { throw 'Unknown theme' }
    if (-not $AccentFill) { $AccentFill = $defaultAccent }
    [void](ConvertFrom-FastLlmUiColor $AccentFill)
    $t = [ordered]@{}
    foreach ($k in 'Layer', 'Card', 'CardStroke', 'Flyout', 'TextPrimary', 'TextSecondary', 'ControlStroke', 'ControlStrongStroke', 'DisabledText', 'DisabledFill', 'DisabledStroke') { $t[$k] = $src[$k] }
    $t['AccentFill'] = $AccentFill
    foreach ($k in 'TextOnAccent', 'SuccessText', 'CautionText', 'CriticalText', 'SuccessBackground', 'CautionBackground', 'CriticalBackground') { $t[$k] = $src[$k] }
    return $t
}

function Get-FastLlmUiMetrics {
    return @{
        ControlCornerRadius = 4; OverlayCornerRadius = 8; ControlHeight = 32; CardPadding = 16; FocusThickness = 2
        TextFont = 'Segoe UI Variable Text, Segoe UI'
        DisplayFont = 'Segoe UI Variable Display, Segoe UI'
        IconFont = 'Segoe Fluent Icons, Segoe MDL2 Assets'
        MonoFont = 'Cascadia Mono, Consolas'
    }
}

function Get-FastLlmUiTypeRamp {
    param([double]$TextScale = 1.0)
    $s = [Math]::Min([Math]::Max($TextScale, 1.0), 2.25)
    $row = {
        param([double]$Size, [double]$Line, [string]$Weight)
        @{ size = [double]($Size * $s); lineHeight = [double]($Line * $s); weight = $Weight }
    }
    return @{
        Caption = & $row 12 16 'Regular'
        Body = & $row 14 20 'Regular'
        BodyStrong = & $row 14 20 'SemiBold'
        Subtitle = & $row 20 28 'SemiBold'
        Title = & $row 28 36 'SemiBold'
    }
}

function Test-FastLlmUiInteger {
    param($Value)
    return ($Value -is [int] -or $Value -is [long])
}

function ConvertFrom-FastLlmUiTextScaleFactor {
    param($Value)
    if (-not (Test-FastLlmUiInteger $Value) -or $Value -lt 100) { return [double]1.0 }
    if ($Value -gt 225) { return [double]2.25 }
    return [double]([long]$Value / 100.0)
}

function Get-FastLlmUiThemeChoice {
    param($AppsUseLightTheme, [bool]$HighContrast = $false)
    if ($HighContrast) { return 'high-contrast' }
    if ((Test-FastLlmUiInteger $AppsUseLightTheme) -and $AppsUseLightTheme -eq 0) { return 'dark' }
    return 'light'
}

function ConvertFrom-FastLlmUiAccentPalette {
    param($Palette)
    if ($Palette -isnot [byte[]] -or $Palette.Length -ne 32) { return $null }
    return @{
        dark1 = ('#FF{0:X2}{1:X2}{2:X2}' -f $Palette[16], $Palette[17], $Palette[18])
        light2 = ('#FF{0:X2}{1:X2}{2:X2}' -f $Palette[4], $Palette[5], $Palette[6])
    }
}

function Get-FastLlmUiAccentPair {
    param($Palette)
    $lightFill = '#FF005FB8'; $darkFill = '#FF60CDFF'
    $lightSource = 'default'; $darkSource = 'default'
    $p = ConvertFrom-FastLlmUiAccentPalette $Palette
    if ($null -ne $p) {
        if ((Get-FastLlmUiContrastRatio '#FFFFFFFF' $p.dark1) -ge 4.5) { $lightFill = $p.dark1; $lightSource = 'system' }
        if ((Get-FastLlmUiContrastRatio '#FF000000' $p.light2) -ge 4.5) { $darkFill = $p.light2; $darkSource = 'system' }
    }
    return @{ lightFill = $lightFill; darkFill = $darkFill; lightSource = $lightSource; darkSource = $darkSource }
}

function Get-FastLlmUiBackdropChoice {
    param([int]$Build, $TransparencyEnabled, [bool]$HighContrast = $false)
    if ($HighContrast) { return 'solid' }
    if ($Build -lt 22621) { return 'solid' }
    if ((Test-FastLlmUiInteger $TransparencyEnabled) -and $TransparencyEnabled -eq 0) { return 'solid' }
    return 'mica'
}
