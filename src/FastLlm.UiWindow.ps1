#requires -Version 5.1
# Loaded by the Fluent window. The Windows side of the theme layer: the interop loader (dark title bar, Mica, OS build), the system theme
# reader and the WPF ResourceDictionary builder. The pure token, ramp and accent functions live in FastLlm.UiTheme.ps1, which the caller
# dot-sources first. Nothing here throws except New-FastLlmUiThemeDictionary on a bad argument.

function Initialize-FastLlmUiWindowInterop {
    param([string]$SourceRoot)
    try {
        if (-not ('Bitworks.FastLlm.FluentWindowNative' -as [type])) {
            $path = Join-Path $SourceRoot 'src/WindowsFluentWindow.cs'
            Add-Type -Path $path -ErrorAction Stop
        }
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
        return [bool]('Bitworks.FastLlm.FluentWindowNative' -as [type])
    } catch {
        return $false
    }
}

# The comma keeps a REG_BINARY byte[] from being unrolled into Object[] by the pipeline; a DWORD stays Int32 and a missing value stays $null.
function Get-FastLlmUiPropertyValue {
    param($Properties, [string]$Name)
    if ($null -eq $Properties) { return $null }
    $prop = $Properties.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return ,$prop.Value
}

function Get-FastLlmUiRegistryValue {
    param([string]$Path, [string]$Name)
    try {
        $p = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
        $v = Get-FastLlmUiPropertyValue $p $Name
        return ,$v
    } catch {
        return $null
    }
}

function Read-FastLlmUiSystemTheme {
    $personalize = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    $highContrast = $false
    try { $highContrast = [bool][System.Windows.SystemParameters]::HighContrast } catch { $highContrast = $false }
    $build = 0
    try {
        if ('Bitworks.FastLlm.FluentWindowNative' -as [type]) { $build = [int][Bitworks.FastLlm.FluentWindowNative]::GetOsBuild() }
    } catch { $build = 0 }
    if ($build -le 0) {
        $build = 0
        try {
            $cb = Get-FastLlmUiRegistryValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'CurrentBuild'
            if ($null -ne $cb) { $build = [int]([string]$cb) }
        } catch { $build = 0 }
    }
    return [pscustomobject]@{
        appsUseLightTheme = Get-FastLlmUiRegistryValue $personalize 'AppsUseLightTheme'
        highContrast = $highContrast
        accentPalette = Get-FastLlmUiRegistryValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' 'AccentPalette'
        textScaleFactor = Get-FastLlmUiRegistryValue 'HKCU:\Software\Microsoft\Accessibility' 'TextScaleFactor'
        enableTransparency = Get-FastLlmUiRegistryValue $personalize 'EnableTransparency'
        build = $build
    }
}

function New-FastLlmUiThemeDictionary {
    param(
        [string]$Theme,
        [hashtable]$AccentPair,
        [double]$TextScale = 1.0,
        [hashtable]$HighContrastPalette
    )
    $newBrush = {
        param([string]$Argb)
        $brush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Argb))
        $brush.Freeze()
        return $brush
    }
    $d = New-Object System.Windows.ResourceDictionary
    if ($Theme -ceq 'high-contrast') {
        $sc = [System.Windows.SystemColors]
        if ($null -ne $HighContrastPalette) {
            $win = & $newBrush ([string]$HighContrastPalette['Window'])
            $text = & $newBrush ([string]$HighContrastPalette['WindowText'])
            $hi = & $newBrush ([string]$HighContrastPalette['Highlight'])
            $hiText = & $newBrush ([string]$HighContrastPalette['HighlightText'])
        } else {
            $win = $sc::WindowBrush
            $text = $sc::WindowTextBrush
            $hi = $sc::HighlightBrush
            $hiText = $sc::HighlightTextBrush
        }
        $map = [ordered]@{
            Layer = $win; Card = $win; CardStroke = $text
            TextPrimary = $text; TextSecondary = $text
            ControlStroke = $text; ControlStrongStroke = $text
            AccentFill = $hi; TextOnAccent = $hiText
            SuccessText = $text; CautionText = $text; CriticalText = $text
            SuccessBackground = $win; CautionBackground = $win; CriticalBackground = $win
        }
        foreach ($k in $map.Keys) { $d['FastLlm.' + $k + 'Brush'] = $map[$k] }
    } else {
        if ($null -eq $AccentPair) { $AccentPair = Get-FastLlmUiAccentPair $null }
        $fill = if ($Theme -ceq 'dark') { [string]$AccentPair['darkFill'] } else { [string]$AccentPair['lightFill'] }
        $tokens = Get-FastLlmUiThemeTokens -Theme $Theme -AccentFill $fill
        foreach ($k in $tokens.Keys) { $d['FastLlm.' + $k + 'Brush'] = & $newBrush ([string]$tokens[$k]) }
    }
    $ramp = Get-FastLlmUiTypeRamp -TextScale $TextScale
    foreach ($style in 'Caption', 'Body', 'BodyStrong', 'Subtitle', 'Title') {
        $row = $ramp[$style]
        $d['FastLlm.' + $style + 'Size'] = [double]$row.size
        $d['FastLlm.' + $style + 'LineHeight'] = [double]$row.lineHeight
        if ($row.weight -ceq 'SemiBold') { $d['FastLlm.' + $style + 'Weight'] = [System.Windows.FontWeights]::SemiBold }
        else { $d['FastLlm.' + $style + 'Weight'] = [System.Windows.FontWeights]::Regular }
    }
    $m = Get-FastLlmUiMetrics
    foreach ($f in 'TextFont', 'DisplayFont', 'IconFont', 'MonoFont') { $d['FastLlm.' + $f] = New-Object System.Windows.Media.FontFamily ([string]$m[$f]) }
    $d['FastLlm.ControlCornerRadius'] = New-Object System.Windows.CornerRadius ([double]$m['ControlCornerRadius'])
    $d['FastLlm.OverlayCornerRadius'] = New-Object System.Windows.CornerRadius ([double]$m['OverlayCornerRadius'])
    $d['FastLlm.ControlHeight'] = [double]$m['ControlHeight']
    $d['FastLlm.FocusThickness'] = [double]$m['FocusThickness']
    return $d
}
