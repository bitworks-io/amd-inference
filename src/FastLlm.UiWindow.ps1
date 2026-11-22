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

# PowerShell keeps a PSObject wrapper when it assigns New-Object output (or anything returned through a scriptblock) through an IDictionary
# indexer, and WPF rejects a wrapper for a Brush, FontFamily or CornerRadius property. Every resource value goes in as its raw .NET object.
# The unwrap is .psobject.BaseObject: [PSObject]::AsPSObject($v).BaseObject throws under StrictMode 2.
function Set-FastLlmUiResourceValue {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Dictionary,
        [Parameter(Mandatory = $true)][string]$Key,
        $Value
    )
    if ($null -eq $Value) { $Dictionary[$Key] = $null; return }
    $Dictionary[$Key] = $Value.psobject.BaseObject
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
        $brush = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($Argb))
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
        foreach ($k in $map.Keys) { Set-FastLlmUiResourceValue $d ('FastLlm.' + $k + 'Brush') ($map[$k]) }
    } else {
        if ($null -eq $AccentPair) { $AccentPair = Get-FastLlmUiAccentPair $null }
        $fill = if ($Theme -ceq 'dark') { [string]$AccentPair['darkFill'] } else { [string]$AccentPair['lightFill'] }
        $tokens = Get-FastLlmUiThemeTokens -Theme $Theme -AccentFill $fill
        foreach ($k in $tokens.Keys) { Set-FastLlmUiResourceValue $d ('FastLlm.' + $k + 'Brush') (& $newBrush ([string]$tokens[$k])) }
    }
    $ramp = Get-FastLlmUiTypeRamp -TextScale $TextScale
    foreach ($style in 'Caption', 'Body', 'BodyStrong', 'Subtitle', 'Title') {
        $row = $ramp[$style]
        Set-FastLlmUiResourceValue $d ('FastLlm.' + $style + 'Size') ([double]$row.size)
        Set-FastLlmUiResourceValue $d ('FastLlm.' + $style + 'LineHeight') ([double]$row.lineHeight)
        if ($row.weight -ceq 'SemiBold') { Set-FastLlmUiResourceValue $d ('FastLlm.' + $style + 'Weight') ([System.Windows.FontWeights]::SemiBold) }
        else { Set-FastLlmUiResourceValue $d ('FastLlm.' + $style + 'Weight') ([System.Windows.FontWeights]::Regular) }
    }
    $m = Get-FastLlmUiMetrics
    foreach ($f in 'TextFont', 'DisplayFont', 'IconFont', 'MonoFont') { Set-FastLlmUiResourceValue $d ('FastLlm.' + $f) ([System.Windows.Media.FontFamily]::new([string]$m[$f])) }
    Set-FastLlmUiResourceValue $d 'FastLlm.ControlCornerRadius' ([System.Windows.CornerRadius]::new([double]$m['ControlCornerRadius']))
    Set-FastLlmUiResourceValue $d 'FastLlm.OverlayCornerRadius' ([System.Windows.CornerRadius]::new([double]$m['OverlayCornerRadius']))
    Set-FastLlmUiResourceValue $d 'FastLlm.ControlHeight' ([double]$m['ControlHeight'])
    Set-FastLlmUiResourceValue $d 'FastLlm.FocusThickness' ([double]$m['FocusThickness'])
    return $d
}
