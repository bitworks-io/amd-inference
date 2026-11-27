#requires -Version 5.1
# Off-screen WPF render and accessibility harness for the Fluent window pages. Windows only (WPF); the caller dot-sources
# src/FastLlm.UiTheme.ps1, src/FastLlm.UiWindow.ps1 and src/FastLlm.UiXaml.ps1 first, and loads WPF (Initialize-FastLlmUiWindowInterop).
# Nothing is shown: a page is wrapped in a ScrollViewer, measured, arranged and rendered as a standalone element (no window, no message pump).
# An element not connected to a presentation source reports IsVisible false, so visibility is judged from Visibility up the visual tree.

function Get-UiRenderMatrix {
    $cases = New-Object System.Collections.ArrayList
    foreach ($theme in 'light', 'dark', 'high-contrast') {
        foreach ($scale in 1.0, 1.25, 1.5, 2.0) {
            foreach ($text in 1.0, 1.5, 2.0) {
                [void]$cases.Add(@{ theme = $theme; scale = [double]$scale; textScale = [double]$text; width = 640; height = 480 })
            }
        }
    }
    foreach ($theme in 'light', 'dark', 'high-contrast') {
        [void]$cases.Add(@{ theme = $theme; scale = [double]1.0; textScale = [double]1.0; width = 1000; height = 680 })
    }
    [void]$cases.Add(@{ theme = 'light'; scale = [double]1.0; textScale = [double]2.25; width = 640; height = 480 })
    return $cases.ToArray()
}

# High-contrast palette for the probes: four DISTINCT colours, and WindowText differs from the dark theme's TextPrimary (white).
function Get-UiRenderHighContrastPalette {
    return @{ Window = '#000000'; WindowText = '#FFFF00'; Highlight = '#1AEBFF'; HighlightText = '#202020' }
}

# The text an access key label shows (WPF AccessText): a doubled underscore is one literal underscore; the FIRST single underscore marks the
# key and is dropped; any later single underscore, and a trailing lone one, show as text. The Windows run pins this against WPF itself.
function Remove-UiAccessKey([string]$Text) {
    $sb = New-Object System.Text.StringBuilder
    $keySeen = $false
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($c -ne '_') { [void]$sb.Append($c); continue }
        if ($i + 1 -lt $Text.Length -and $Text[$i + 1] -eq '_') { [void]$sb.Append('_'); $i++; continue }
        if ($i + 1 -ge $Text.Length) { [void]$sb.Append('_'); continue }
        if (-not $keySeen) { $keySeen = $true; continue }
        [void]$sb.Append('_')
    }
    return $sb.ToString()
}

function Get-UiElementLabel($Element) {
    $n = ''
    if ($Element -is [System.Windows.FrameworkElement]) { $n = [string]$Element.Name }
    if ([string]::IsNullOrEmpty($n)) { return $Element.GetType().Name }
    return $n
}

# Every element of the visual tree below $Root, in tree order (depth first), $Root included.
function Get-UiVisualElements($Root) {
    $list = New-Object System.Collections.ArrayList
    $walk = $null
    $walk = {
        param($node)
        [void]$list.Add($node)
        $count = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($node)
        for ($i = 0; $i -lt $count; $i++) { & $walk ([System.Windows.Media.VisualTreeHelper]::GetChild($node, $i)) }
    }
    & $walk $Root
    return ,@($list.ToArray())
}

# True when $Element and every visual ancestor up to $Stop (inclusive) has Visibility Visible.
function Test-UiShown($Element, $Stop) {
    $node = $Element
    while ($null -ne $node) {
        if ($node -is [System.Windows.UIElement] -and $node.Visibility -ne [System.Windows.Visibility]::Visible) { return $false }
        if ([object]::ReferenceEquals($node, $Stop)) { break }
        $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node)
    }
    return $true
}

# Bounds of $Element in the coordinates of $Page, or $null when it cannot be mapped.
function Get-UiRelativeRect($Element, $Page) {
    try {
        $w = [double]$Element.ActualWidth
        $h = [double]$Element.ActualHeight
        if ([object]::ReferenceEquals($Element, $Page)) { return (New-Object System.Windows.Rect(0, 0, $w, $h)) }
        $t = $Element.TransformToAncestor($Page)
        return $t.TransformBounds((New-Object System.Windows.Rect(0, 0, $w, $h)))
    } catch { return $null }
}

# The part of a text block that is actually on screen: its rectangle (in $Stop's coordinates) intersected with the layout clip and the
# ClipToBounds of itself and of every ancestor below $Stop. Layout never arranges an element below its unclipped size; it only clips it.
# $Stop (the scroll presenter) is excluded because it clips to the viewport, and text below the fold is scrolled, not clipped.
function Get-UiVisibleRect($Text, $Stop) {
    $visible = Get-UiRelativeRect $Text $Stop
    if ($null -eq $visible) { return $null }
    $node = $Text
    while ($null -ne $node -and -not [object]::ReferenceEquals($node, $Stop)) {
        $clip = $null
        if ($node -is [System.Windows.FrameworkElement]) {
            $geo = [System.Windows.Controls.Primitives.LayoutInformation]::GetLayoutClip($node)
            if ($null -ne $geo) { $clip = $geo.Bounds }
        }
        if ($null -eq $clip -and $node -is [System.Windows.UIElement] -and $node.ClipToBounds) {
            $clip = New-Object System.Windows.Rect(0, 0, [double]$node.RenderSize.Width, [double]$node.RenderSize.Height)
        }
        if ($null -ne $clip) {
            try { $clip = $node.TransformToAncestor($Stop).TransformBounds($clip) } catch { $clip = $null }
            if ($null -ne $clip) { $visible = [System.Windows.Rect]::Intersect($visible, $clip) }
            if ($visible.IsEmpty) { return $visible }
        }
        $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node)
    }
    return $visible
}

# Names of controls (a ListBox) whose own viewer a case treats as a content scroller (set by Invoke-UiRenderCase -ScrollOwners; empty by default, so every
# existing case is judged exactly as before). The Models switch list scrolls its long rows inside a fixed-height ListBox: a row below its fold or beyond its width
# is scrolled, not clipped or outside.
$script:UiRenderScrollOwners = @()

# The scroll presenter an element scrolls in: the nearest ScrollContentPresenter above it that belongs to an authored ScrollViewer (one that is not a part of
# another control's template, as a TextBox's own is), else $Default. A page with a ScrollViewer of its own is judged against that viewer's content, not the
# harness wrapper's. The ScrollViewer is the presenter's TemplatedParent.
function Get-UiScrollPresenter($Element, $Default) {
    $node = [System.Windows.Media.VisualTreeHelper]::GetParent($Element)
    while ($null -ne $node) {
        if ($node -is [System.Windows.Controls.ScrollContentPresenter]) {
            $owner = $node.TemplatedParent
            if ($owner -is [System.Windows.Controls.ScrollViewer] -and $null -eq $owner.TemplatedParent) { return $node }
            if ($owner -is [System.Windows.Controls.ScrollViewer] -and $owner.TemplatedParent -is [System.Windows.FrameworkElement] -and (@($script:UiRenderScrollOwners) -ccontains [string]$owner.TemplatedParent.Name)) { return $node }
        }
        $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node)
    }
    return $Default
}

# The index of the first region whose root is the element or one of its visual ancestors; the region count when none (the last region).
function Get-UiTabRegion($Element, $Page, [string[]]$Regions) {
    for ($i = 0; $i -lt @($Regions).Count; $i++) {
        $node = $Element
        while ($null -ne $node) {
            if ($node -is [System.Windows.FrameworkElement] -and [string]$node.Name -ceq $Regions[$i]) { return $i }
            if ([object]::ReferenceEquals($node, $Page)) { break }
            $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node)
        }
    }
    return @($Regions).Count
}

function Test-UiAuthored($Element) {
    return ($Element -is [System.Windows.FrameworkElement]) -and ($null -eq $Element.TemplatedParent)
}

# ---- The clipped rule's arithmetic. These functions are pure (no WPF), so tests/ui-render-tests.ps1 pins them on every OS.
#
# Root cause of the PR 3c CI false positives (rounds 1 and 2), and why the bound below is not a guess:
#  1. With UseLayoutRounding on, WPF rounds a size to whole device pixels (FrameworkElement.MeasureCore: Math.Round(value * scale) / scale), with the DPI scale
#     of the ELEMENT ITSELF. A live block's DesiredSize is therefore its text's ideal size rounded to the nearest device pixel: at most half a device pixel
#     above it or below it. CI round 1 shows it: unrounded clones of 645.1, 548.7 and 967.7 beside live widths of 645.0, 549.0 and 968.0.
#  2. The page's blocks do NOT have the case's device scale. CI round 2 shows it: at case scales 1.25 and 1.5 every live size was a whole DIP (593.0, 97.0),
#     which is the scale 1.0 grid, while a clone given the case scale by SetRootDpi and the live block's UseLayoutRounding rounded to 0.8 and 0.667 DIP steps
#     (97.6 = 122 px / 1.25, against a live 97.0: two grids, up to 0.9 DIP apart). The likely mechanism: SetRootDpi on the harness host reaches the visuals
#     the host has at that moment, and the page's visual tree is built later, in Measure, so its elements keep the process DPI. Whatever the mechanism, the
#     rule reads each block's DPI from the block and assumes nothing about it, and the run fails when a live size is not on that block's pixel grid.
#  3. A wrapping block breaks its lines for the width it was MEASURED with and keeps them when it is arranged at its own desired width, which is its widest
#     line rounded, so sometimes rounded DOWN below that line (CI round 1: a one-line caption of 171.x DIP in a live block 171.0 wide). Round 1 measured the
#     clone at ActualWidth, so the clone wrapped where the live block did not. Round 2 measured it at ActualWidth + 1, wider than the live measure width, so
#     the clone fitted a word more per line than the live block and its lines came out wider than the live desired width (534.0 against 511.0).
# The rule now measures the clone unrounded, at the live block's own DPI, and for wrapping text at the live block's own desired text width plus the bound.

# Floating-point noise in a size difference (sizes are a few thousand DIP at most): a millionth of a DIP. Not a layout tolerance.
$script:UiTextFloatSlack = 0.000001

# WPF's layout rounding of one value (UIElement.RoundLayoutValue): the nearest device pixel, in DIP.
function Get-UiRoundedLayoutValue([double]$Value, [double]$Scale) {
    if ($Scale -le 0 -or [double]::IsNaN($Value) -or [double]::IsInfinity($Value)) { return $Value }
    return ([Math]::Round($Value * $Scale) / $Scale)
}

# True when a value is a whole number of device pixels at the scale (to a ten-thousandth of a pixel).
function Test-UiOnLayoutGrid([double]$Value, [double]$Scale) {
    if ($Scale -le 0) { return $false }
    $px = $Value * $Scale
    return ([Math]::Abs($px - [Math]::Round($px)) -le 0.0001)
}

# The DERIVED bound on one axis for: (clone natural size) - (live DesiredSize - margin), for a block whose text is not clipped.
# Half a device pixel of the live block's own DPI scale (rounding to the nearest pixel moves a value by at most half a pixel), plus the float noise. The margin
# is taken off the way WPF adds it: its sum rounded to the pixel grid. WPF's older compatibility mode adds the sum unrounded, which can move the result by what
# rounding the sum changes (zero for a margin that is whole pixels), so that is added to the bound and both modes are covered. Without layout rounding the
# live size is the ideal size, so only the float noise is left. A gap above this bound can only come from a clamped measure: the text is clipped.
function Get-UiTextGapBound([double]$Scale, [bool]$LayoutRounding, [double]$MarginSum) {
    if (-not $LayoutRounding -or $Scale -le 0) { return $script:UiTextFloatSlack }
    $marginSlack = [Math]::Abs((Get-UiRoundedLayoutValue $MarginSum $Scale) - $MarginSum)
    return ((0.5 / $Scale) + $marginSlack + $script:UiTextFloatSlack)
}

# The width a wrapping block's clone is measured with. The live block broke its lines for the width it was MEASURED with, which is not readable from outside,
# but is bounded: it is on the pixel grid, at least the desired text width (the widest line, rounded), and inside the block's own limits (FrameworkElement's
# MinMax: MinWidth and MaxWidth, and an explicit Width is both). Every live line is at most (desired text width + bound) wide and line breaking is greedy, so
# a clone measured at that width, kept inside the same limits, breaks exactly as the live block whenever that width is not above the live measure width;
# it never wraps where the live block did not. A fixed-width box is measured at exactly its own width, also when its slot cut its desired size.
function Get-UiWrapMeasureWidth([double]$DesiredTextWidth, [double]$Bound, [double]$Width, [double]$MinWidth, [double]$MaxWidth, [double]$Scale, [bool]$LayoutRounding) {
    $high = $MaxWidth
    $low = $MinWidth
    if (-not [double]::IsNaN($Width)) {
        $high = [Math]::Min($Width, $MaxWidth)
        $low = [Math]::Max($high, $MinWidth)
    }
    $high = [Math]::Max($high, $low)
    if ($LayoutRounding) {
        $low = Get-UiRoundedLayoutValue $low $Scale
        $high = Get-UiRoundedLayoutValue $high $Scale
    }
    $w = [Math]::Max(0.0, $DesiredTextWidth) + $Bound
    return [Math]::Max($low, [Math]::Min($w, $high))
}

# One axis of one block. over: the clone needs more than the live block was given (clipped). under: the clone is smaller than the live block by more than the
# bound, so the clone does not reproduce the live text. sized: the same, but the axis has an explicit or minimum size, which makes the live block larger by design.
function Get-UiTextGapState([double]$Gap, [double]$Bound, [bool]$Sized) {
    if ($Gap -gt $Bound) { return 'over' }
    if ($Gap -lt (-$Bound)) { if ($Sized) { return 'sized' }; return 'under' }
    return 'ok'
}

function New-UiTextGapStat { return @{ n = 0; minW = $null; maxW = $null; minH = $null; maxH = $null } }

function Add-UiTextGapValue($Stat, [string]$Axis, [double]$Gap) {
    $lo = 'min' + $Axis
    $hi = 'max' + $Axis
    if ($null -eq $Stat[$lo] -or $Gap -lt [double]$Stat[$lo]) { $Stat[$lo] = $Gap }
    if ($null -eq $Stat[$hi] -or $Gap -gt [double]$Stat[$hi]) { $Stat[$hi] = $Gap }
}

function Format-UiTextGapRange($Low, $High) {
    if ($null -eq $Low -or $null -eq $High) { return 'none' }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    return ('[' + ([double]$Low).ToString('0.000', $inv) + ', ' + ([double]$High).ToString('0.000', $inv) + ']')
}

# Every render case of the run adds its text gap record here (Invoke-UiRenderCase); Get-UiTextGapSummary folds them per device scale and text scale.
$script:UiRenderTextGapLog = New-Object System.Collections.ArrayList

# One row per (device scale, text scale), in that order: the clone-against-live gaps of every examined block of every case, for NoWrap and for wrapping text,
# the largest bound used, the DPI scales the live blocks really had, and the counts the run fails on. The line is what the log prints.
function Get-UiTextGapSummary($Records) {
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $groups = @{}
    foreach ($rec in @($Records)) {
        if ($null -eq $rec) { continue }
        $key = ([double]$rec['scale']).ToString('0.0#', $inv) + '|' + ([double]$rec['textScale']).ToString('0.0#', $inv)
        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = @{
                scale = [double]$rec['scale']; textScale = [double]$rec['textScale']; cases = 0; bound = [double]0
                nowrap = (New-UiTextGapStat); wrap = (New-UiTextGapStat); liveScales = @{}
                over = 0; under = 0; offGrid = 0; sized = 0; accessKey = 0; trimmed = 0; remeasured = 0
                notes = (New-Object System.Collections.ArrayList)
            }
        }
        $g = $groups[$key]
        $g['cases'] = [int]$g['cases'] + 1
        if ([double]$rec['bound'] -gt [double]$g['bound']) { $g['bound'] = [double]$rec['bound'] }
        foreach ($k in 'over', 'under', 'offGrid', 'sized', 'accessKey', 'trimmed', 'remeasured') { $g[$k] = [int]$g[$k] + [int]$rec[$k] }
        foreach ($s in @($rec['liveScales'])) { $g['liveScales'][[string]$s] = $true }
        foreach ($kind in 'nowrap', 'wrap') {
            $from = $rec[$kind]
            $to = $g[$kind]
            $to['n'] = [int]$to['n'] + [int]$from['n']
            foreach ($axis in 'W', 'H') {
                if ($null -ne $from['min' + $axis]) { Add-UiTextGapValue $to $axis ([double]$from['min' + $axis]) }
                if ($null -ne $from['max' + $axis]) { Add-UiTextGapValue $to $axis ([double]$from['max' + $axis]) }
            }
        }
        foreach ($note in @($rec['notes'])) { if ($g['notes'].Count -lt 8) { [void]$g['notes'].Add([string]$rec['label'] + ': ' + [string]$note) } }
    }
    $rows = New-Object System.Collections.ArrayList
    foreach ($g in @($groups.Values | Sort-Object -Property @{ Expression = { [double]$_['scale'] } }, @{ Expression = { [double]$_['textScale'] } })) {
        $live = (@($g['liveScales'].Keys | Sort-Object) -join ', ')
        if ([string]::IsNullOrEmpty($live)) { $live = 'none' }
        $line = 'scale ' + ([double]$g['scale']).ToString('0.0#', $inv) + ' text ' + ([double]$g['textScale']).ToString('0.0#', $inv) +
            ': cases ' + [int]$g['cases'] + '; live layout scale ' + $live + '; bound ' + ([double]$g['bound']).ToString('0.000', $inv) +
            '; NoWrap n=' + [int]$g['nowrap']['n'] + ' gap W ' + (Format-UiTextGapRange $g['nowrap']['minW'] $g['nowrap']['maxW']) + ' H ' + (Format-UiTextGapRange $g['nowrap']['minH'] $g['nowrap']['maxH']) +
            '; Wrap n=' + [int]$g['wrap']['n'] + ' gap W ' + (Format-UiTextGapRange $g['wrap']['minW'] $g['wrap']['maxW']) + ' H ' + (Format-UiTextGapRange $g['wrap']['minH'] $g['wrap']['maxH']) +
            '; above the bound (reported clipped) ' + [int]$g['over'] + '; below the bound ' + [int]$g['under'] + '; off the pixel grid ' + [int]$g['offGrid'] +
            '; below it by an explicit size ' + [int]$g['sized'] + '; below it by an access key split ' + [int]$g['accessKey'] + '; trimmed with a tooltip ' + [int]$g['trimmed'] + '; wraps re-measured ' + [int]$g['remeasured']
        [void]$rows.Add(@{
            scale = [double]$g['scale']; textScale = [double]$g['textScale']; cases = [int]$g['cases']; bound = [double]$g['bound']; liveScales = $live
            nowrap = $g['nowrap']; wrap = $g['wrap']; over = [int]$g['over']; under = [int]$g['under']; offGrid = [int]$g['offGrid']; sized = [int]$g['sized']
            accessKey = [int]$g['accessKey']; trimmed = [int]$g['trimmed']; remeasured = [int]$g['remeasured']; notes = [string[]]@($g['notes'].ToArray()); line = $line
        })
    }
    # One hashtable per row on the pipeline: the caller collects them with @( ).
    return $rows.ToArray()
}

# The text of an inline collection (Run, Span, Hyperlink, Bold, LineBreak), depth first. Pure over the object shape: a member with Inlines is walked, a member
# with Text is read, a LineBreak is a newline. Any other inline (an InlineUIContainer) has neither and adds nothing.
function Get-UiInlineText($Inlines) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($inline in @($Inlines)) {
        if ($null -eq $inline) { continue }
        if ($inline.GetType().Name -ceq 'LineBreak') { [void]$sb.Append("`n"); continue }
        $props = $inline.PSObject.Properties
        if ($null -ne $props['Inlines']) { [void]$sb.Append((Get-UiInlineText $inline.Inlines)) }
        elseif ($null -ne $props['Text']) { [void]$sb.Append([string]$inline.Text) }
    }
    return $sb.ToString()
}

# The whole text of a block, the way the clone must measure it. A block whose content is inlines only (a Hyperlink, runs) has an EMPTY Text on Windows (CI round 1 of
# PR 4a: the NoWrap Hyperlink block in a 60-wide box was measured as empty, a zero-width clone, so its clipping was never reported), so the inlines are read instead.
function Get-UiBlockText($Block) {
    $t = [string]$Block.Text
    if (-not [string]::IsNullOrEmpty($t)) { return $t }
    if ($null -ne $Block.PSObject.Properties['Inlines']) { return (Get-UiInlineText $Block.Inlines) }
    return ''
}

# Dialog and page reading order: the stops sorted by tab region first, then row, then left edge, then tree order (Sort-Object is not stable, so the tree order is a key).
# A stop below the fold of a scrolling region still belongs to that region, so it comes before the footer's stops whatever its unclipped Top. Pure: rows are
# objects with Region, Row, Left and Order. Callers collect with @( ).
function Sort-UiReadingRows($Rows) {
    return (@($Rows) | Sort-Object -Property @{ Expression = { [int]$_.Region } }, @{ Expression = { [double]$_.Row } }, @{ Expression = { [double]$_.Left } }, @{ Expression = { [int]$_.Order } })
}

# A fresh, unparented copy of a text block's text and of everything that sizes it (never the live element). It is NOT layout rounded, so its DesiredSize is the
# text's ideal size, and it is given the live block's own DPI (not the case's scale: see the root cause above), which matters only for display-mode text metrics.
function New-UiTextClone($Text, $Dpi) {
    $clone = New-Object System.Windows.Controls.TextBlock
    $clone.Text = Get-UiBlockText $Text
    $clone.FontFamily = $Text.FontFamily
    $clone.FontSize = $Text.FontSize
    $clone.FontWeight = $Text.FontWeight
    $clone.FontStyle = $Text.FontStyle
    $clone.FontStretch = $Text.FontStretch
    $clone.TextWrapping = $Text.TextWrapping
    $clone.Padding = $Text.Padding
    $clone.FlowDirection = $Text.FlowDirection
    [System.Windows.Media.TextOptions]::SetTextFormattingMode($clone, [System.Windows.Media.TextOptions]::GetTextFormattingMode($Text))
    if (-not [double]::IsNaN([double]$Text.LineHeight)) {
        $clone.LineHeight = $Text.LineHeight
        $clone.LineStackingStrategy = $Text.LineStackingStrategy
    }
    $clone.UseLayoutRounding = $false
    [System.Windows.Media.VisualTreeHelper]::SetRootDpi($clone, $Dpi)
    return $clone
}

# The clone's size for a width (infinite for NoWrap text); the height is never limited.
function Measure-UiTextClone($Clone, [double]$Width) {
    $Clone.Measure((New-Object System.Windows.Size($Width, [double]::PositiveInfinity)))
    return $Clone.DesiredSize
}

function Get-UiHyperlinkName($Link) {
    $n = [string][System.Windows.Automation.AutomationProperties]::GetName($Link)
    if (-not [string]::IsNullOrWhiteSpace($n)) { return $n }
    $range = New-Object System.Windows.Documents.TextRange($Link.ContentStart, $Link.ContentEnd)
    return [string]$range.Text
}

function Test-UiNameMissing([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return $true }
    # Icon glyphs live in the Private Use Area (U+E000 to U+F8FF).
    foreach ($c in $Name.ToCharArray()) { if (-not [char]::IsWhiteSpace($c) -and ([int]$c -lt 0xE000 -or [int]$c -gt 0xF8FF)) { return $false } }
    return $true
}

function Get-UiPngInfo {
    param([string]$Path)
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $decoder = New-Object System.Windows.Media.Imaging.PngBitmapDecoder($stream, [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat, [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $frame = $decoder.Frames[0]
        $conv = New-Object System.Windows.Media.Imaging.FormatConvertedBitmap($frame, [System.Windows.Media.PixelFormats]::Pbgra32, $null, 0)
        $w = [int]$conv.PixelWidth
        $h = [int]$conv.PixelHeight
        $stride = $w * 4
        $pixels = New-Object byte[] ($stride * $h)
        $conv.CopyPixels($pixels, $stride, 0)
        $different = $false
        for ($i = 4; $i -lt $pixels.Length; $i += 4) {
            if ($pixels[$i] -ne $pixels[0] -or $pixels[$i + 1] -ne $pixels[1] -or $pixels[$i + 2] -ne $pixels[2] -or $pixels[$i + 3] -ne $pixels[3]) { $different = $true; break }
        }
        return @{ width = $w; height = $h; hasContent = $different }
    } finally { $stream.Dispose() }
}

# Merges the shell Window's style resources into a theme dictionary: the registered FastLlm.Shell markup is parsed through the same safe loader as the app and its
# Window.Resources entries (the Button, TextBox, ComboBox, CheckBox, switch and spin button styles) are added, each stored as its raw object (a PSObject wrapper is
# rejected by WPF). A key the dictionary already holds is kept, so the theme's own brushes are never replaced. Nothing is added when the shell markup is not registered.
function Add-UiShellStyleResources($Dictionary) {
    if (-not $script:FastLlmUiXaml.ContainsKey('FastLlm.Shell')) { return }
    $shellWindow = New-FastLlmUiXamlElement -Name 'FastLlm.Shell'
    foreach ($k in @($shellWindow.Resources.Keys)) {
        if (-not $Dictionary.Contains($k)) { $Dictionary[$k] = ([object]$shellWindow.Resources[$k]).psobject.BaseObject }
    }
}

function Invoke-UiRenderCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Case,
        [string]$OutFolder = '',
        # Optional: runs once on the page (after its theme dictionary is set, before it is measured), e.g. to bind adapters and apply a state.
        [scriptblock]$Prepare = $null,
        # Optional: an element built by the caller, used instead of parsing the registered markup for $Name ($Name then only names the PNG).
        $Element = $null,
        # Optional: names the PNG instead of $Name, so two states of one page (same size, theme and scales) never write the same file.
        [string]$PngName = '',
        # Optional: names of region roots (in order). Stops inside a region are one contiguous block, in that order, each in reading order; the rest come last.
        [string[]]$TabRegions = @(),
        # Optional: names of ListBoxes whose own viewer is a content scroller for the clipped and outside rules (see $script:UiRenderScrollOwners).
        [string[]]$ScrollOwners = @()
    )
    $script:UiRenderScrollOwners = @($ScrollOwners)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $theme = [string]$Case.theme
    $scale = [double]$Case.scale
    $textScale = [double]$Case.textScale
    $width = [int]$Case.width
    $height = [int]$Case.height
    $problems = New-Object System.Collections.ArrayList

    if ($null -ne $Element) { $page = $Element } else { $page = New-FastLlmUiXamlElement -Name $Name }
    $themeArgs = @{ Theme = $theme; AccentPair = (Get-FastLlmUiAccentPair -Palette $null); TextScale = $textScale }
    if ($theme -eq 'high-contrast') {
        $themeArgs['HighContrastPalette'] = Get-UiRenderHighContrastPalette
    }
    $dict = New-FastLlmUiThemeDictionary @themeArgs
    # PR 3c CI round 1 (F4): the Fluent control styles live in the shell Window's Resources, so a page rendered outside the shell takes them from the host the same way.
    Add-UiShellStyleResources $dict
    $page.Resources = $dict
    if ($null -ne $Prepare) { & $Prepare $page }

    $sv = New-Object System.Windows.Controls.ScrollViewer
    $sv.Width = $width
    $sv.Height = $height
    $sv.HorizontalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Disabled
    $sv.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $sv.UseLayoutRounding = $true
    $sv.Background = $dict['FastLlm.LayerBrush']
    $sv.Content = $page
    # In the app a page inherits its font, size and colour from the Window (FontFamily, FontSize and Foreground there are the same three resources). The host
    # takes them from the case's theme dictionary, shared with the page, so body text in every case scales with the text scale the way it does in the app.
    $sv.Resources = $dict
    $sv.SetResourceReference([System.Windows.Documents.TextElement]::FontSizeProperty, 'FastLlm.BodySize')
    $sv.SetResourceReference([System.Windows.Documents.TextElement]::FontFamilyProperty, 'FastLlm.TextFont')
    $sv.SetResourceReference([System.Windows.Documents.TextElement]::ForegroundProperty, 'FastLlm.TextPrimaryBrush')
    [System.Windows.Media.VisualTreeHelper]::SetRootDpi($sv, (New-Object System.Windows.DpiScale($scale, $scale)))
    $sv.Measure((New-Object System.Windows.Size($width, $height)))
    $sv.Arrange((New-Object System.Windows.Rect(0, 0, $width, $height)))
    $sv.UpdateLayout()
    $sv.UpdateLayout()

    # The DPI every text block was laid out with, read from the element right after layout (before anything else touches the tree): the clipped rule's bound
    # is half a device pixel of THIS scale, whatever the case's scale is.
    $all = Get-UiVisualElements $page
    $textEntries = New-Object System.Collections.ArrayList
    foreach ($el in $all) {
        if ($el -is [System.Windows.Controls.TextBlock]) { [void]$textEntries.Add(@{ element = $el; dpi = [System.Windows.Media.VisualTreeHelper]::GetDpi($el) }) }
    }

    $png = ''
    if (-not [string]::IsNullOrEmpty($OutFolder)) {
        [void][System.IO.Directory]::CreateDirectory($OutFolder)
        $pw = [int][Math]::Ceiling($width * $scale)
        $ph = [int][Math]::Ceiling($height * $scale)
        $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($pw, $ph, (96.0 * $scale), (96.0 * $scale), [System.Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($sv)
        $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $pngBase = $Name
        if (-not [string]::IsNullOrEmpty($PngName)) { $pngBase = $PngName }
        $fileName = [string]::Format($inv, '{0}-{1}-{2}-{3}-{4}x{5}.png', $pngBase, $theme, $scale.ToString('0.0#', $inv), $textScale.ToString('0.0#', $inv), $width, $height)
        $png = Join-Path $OutFolder $fileName
        $fs = [System.IO.File]::Create($png)
        try { $encoder.Save($fs) } finally { $fs.Dispose() }
    }

    $presenter = [System.Windows.Media.VisualTreeHelper]::GetParent($page)
    if ($presenter -isnot [System.Windows.Controls.ScrollContentPresenter]) {
        $got = if ($null -eq $presenter) { 'null' } else { $presenter.GetType().FullName }
        throw ('Harness: the page visual parent must be a ScrollContentPresenter, got ' + $got)
    }
    $authored = @($all | Where-Object { (Test-UiAuthored $_) -and (Test-UiShown $_ $page) })

    # overlap: visible, sized siblings of one authored Panel
    foreach ($panel in @($authored | Where-Object { $_ -is [System.Windows.Controls.Panel] })) {
        $kids = @()
        foreach ($child in $panel.Children) {
            if ($child -is [System.Windows.FrameworkElement] -and $child.Visibility -eq [System.Windows.Visibility]::Visible -and $child.ActualWidth -gt 0 -and $child.ActualHeight -gt 0) { $kids += $child }
        }
        for ($i = 0; $i -lt $kids.Count; $i++) {
            for ($j = $i + 1; $j -lt $kids.Count; $j++) {
                $a = Get-UiRelativeRect $kids[$i] $panel
                $b = Get-UiRelativeRect $kids[$j] $panel
                if ($null -eq $a -or $null -eq $b) { continue }
                $ix = [Math]::Min($a.Right, $b.Right) - [Math]::Max($a.Left, $b.Left)
                $iy = [Math]::Min($a.Bottom, $b.Bottom) - [Math]::Max($a.Top, $b.Top)
                if ($ix -gt 0 -and $iy -gt 0 -and ($ix * $iy) -gt 0.5) {
                    [void]$problems.Add('overlap:' + (Get-UiElementLabel $kids[$i]) + ':' + (Get-UiElementLabel $kids[$j]))
                }
            }
        }
    }

    $diagnostics = New-Object System.Collections.ArrayList
    $textBlocksSeen = 0
    $namedControlsSeen = 0
    $unmappedRects = 0
    # clipped: every shown TextBlock, including a button's content. The arithmetic and its derivation are above (Get-UiTextGapBound).
    # Signal 1: Measure clamps DesiredSize to the constraint (Width, MaxWidth, a button's content area), so the live desired size minus margin falls below the
    # clone's natural size by more than the bound. Signal 2: the visible rectangle (layout clip, ClipToBounds) is smaller than the natural size by more than
    # the bound (an unclipped block is arranged at its desired size or more, so the same bound holds). Every block's gap is recorded as evidence.
    $gapNoWrap = New-UiTextGapStat
    $gapWrap = New-UiTextGapStat
    $gapNotes = New-Object System.Collections.ArrayList
    $gapLiveScales = @{}
    $gapBound = [double]0
    $gapOver = 0
    $gapUnder = 0
    $gapOffGrid = 0
    $gapSized = 0
    $gapAccessKey = 0
    $gapTrimmed = 0
    $gapRemeasured = 0
    foreach ($entry in $textEntries) {
        $text = $entry['element']
        if (-not (Test-UiShown $text $page)) { continue }
        $aw = [double]$text.ActualWidth
        $ah = [double]$text.ActualHeight
        if ($aw -le 0 -and $ah -le 0) { continue }
        $textBlocksSeen++
        $shownText = [string]$text.Text
        if ($shownText.Length -gt 32) { $shownText = $shownText.Substring(0, 32) }
        $ident = [string]$text.Name
        if ([string]::IsNullOrEmpty($ident)) { $ident = "text '" + $shownText + "'" }
        # The live block's own layout DPI and rounding: read from the element (after layout, above), never assumed from the case's scale.
        $liveDpi = $entry['dpi']
        $sx = [double]$liveDpi.DpiScaleX
        $sy = [double]$liveDpi.DpiScaleY
        $rounding = [bool]$text.UseLayoutRounding
        $gapLiveScales[$sx.ToString('0.0##', $inv)] = $true
        $desired = $text.DesiredSize
        $mw = [double]$text.Margin.Left + [double]$text.Margin.Right
        $mh = [double]$text.Margin.Top + [double]$text.Margin.Bottom
        $tolW = Get-UiTextGapBound $sx $rounding $mw
        $tolH = Get-UiTextGapBound $sy $rounding $mh
        if ($tolW -gt $gapBound) { $gapBound = $tolW }
        if ($tolH -gt $gapBound) { $gapBound = $tolH }
        # The live block's desired text size: DesiredSize without the margin, the margin sum rounded as WPF rounds it (see Get-UiTextGapBound).
        $mwLaid = $mw
        $mhLaid = $mh
        if ($rounding) {
            $mwLaid = Get-UiRoundedLayoutValue $mw $sx
            $mhLaid = Get-UiRoundedLayoutValue $mh $sy
        }
        $desiredTextW = [double]$desired.Width - $mwLaid
        $desiredTextH = [double]$desired.Height - $mhLaid
        # The bound rests on this: a layout-rounded live size is a whole number of the block's own device pixels. A size off that grid fails the run.
        if ($rounding -and (-not (Test-UiOnLayoutGrid ([double]$desired.Width) $sx) -or -not (Test-UiOnLayoutGrid ([double]$desired.Height) $sy))) {
            $gapOffGrid++
            if ($gapNotes.Count -lt 8) { [void]$gapNotes.Add('off the pixel grid: ' + $ident + (' desired {0:N3}x{1:N3} at live scale {2:N3}x{3:N3}' -f $desired.Width, $desired.Height, $sx, $sy)) }
        }
        # An explicit or minimum size makes the live block larger than its text by design, so only "the clone needs more" is judged on that axis.
        $sizedW = (-not [double]::IsNaN([double]$text.Width)) -or ([double]$text.MinWidth -gt 0)
        $sizedH = (-not [double]::IsNaN([double]$text.Height)) -or ([double]$text.MinHeight -gt 0)
        $clone = New-UiTextClone $text $liveDpi
        $isWrap = ($text.TextWrapping -ne [System.Windows.TextWrapping]::NoWrap)
        $measureWidth = [double]::PositiveInfinity
        if ($isWrap) {
            $measureWidth = Get-UiWrapMeasureWidth $desiredTextW $tolW ([double]$text.Width) ([double]$text.MinWidth) ([double]$text.MaxWidth) $sx $rounding
            $natural = Measure-UiTextClone $clone $measureWidth
            # When the widest line fills the live measure width to within the bound, the clone's width is up to the bound above it and can fit a word more
            # (fewer lines than the live block). The desired text width itself is then the live measure width, so the clone is measured there, and that
            # measure is taken only when it reproduces the live height.
            $floorWidth = [Math]::Max(0.0, $desiredTextW)
            $inBound = ($measureWidth -gt $floorWidth) -and (($measureWidth - $floorWidth) -le ($tolW + $script:UiTextFloatSlack))
            if (-not $sizedH -and $inBound -and [double]$natural.Height -lt ($desiredTextH - $tolH)) {
                $second = Measure-UiTextClone $clone $floorWidth
                if ([Math]::Abs([double]$second.Height - $desiredTextH) -le $tolH) { $natural = $second; $measureWidth = $floorWidth; $gapRemeasured++ }
            }
        } else {
            $natural = Measure-UiTextClone $clone $measureWidth
        }
        $gapW = [double]$natural.Width - $desiredTextW
        $gapH = [double]$natural.Height - $desiredTextH
        $stateW = Get-UiTextGapState $gapW $tolW $sizedW
        $stateH = Get-UiTextGapState $gapH $tolH $sizedH
        $overGap = ($stateW -ceq 'over') -or ($stateH -ceq 'over')
        $isClipped = $overGap
        if (-not $isClipped) {
            $vis = Get-UiVisibleRect $text (Get-UiScrollPresenter $text $presenter)
            if ($null -ne $vis) {
                if ($vis.IsEmpty) { $isClipped = $true }
                else { $isClipped = ($natural.Width -gt ($vis.Width + $tolW)) -or ($natural.Height -gt ($vis.Height + $tolH)) }
            }
        }
        $trimmedWithTip = ($text.TextTrimming -ne [System.Windows.TextTrimming]::None -and [string]$text.ToolTip -ceq [string]$text.Text)
        if ($isClipped -and $trimmedWithTip) { $isClipped = $false }
        $measuredAt = 'unlimited width'
        if ($isWrap) { $measuredAt = ('width {0:N2}' -f $measureWidth) }
        $numbers = (' natural {0:N2}x{1:N2} desired {2:N1}x{3:N1} actual {4:N1}x{5:N1} margin {6:N1}x{7:N1} gap {8:N3}x{9:N3} bound {10:N3}x{11:N3} live scale {12:N2} measured at ' -f $natural.Width, $natural.Height, $desired.Width, $desired.Height, $aw, $ah, $mw, $mh, $gapW, $gapH, $tolW, $tolH, $sx) + $measuredAt
        # Evidence: the gap of every block, per kind. A gap above the bound is the clipped signal itself (or a trimmed line that shows its full text in a tooltip).
        if ($overGap) {
            if ($trimmedWithTip) { $gapTrimmed++ } else { $gapOver++ }
        } else {
            $stat = $gapNoWrap
            if ($isWrap) { $stat = $gapWrap }
            $stat['n'] = [int]$stat['n'] + 1
            # A caption with an access key is drawn as separate runs (the key is its own run), so the clone's single run can be a little narrower: not a clone fault.
            $textHost = [System.Windows.Media.VisualTreeHelper]::GetParent($text)
            $keySplit = ($textHost -is [System.Windows.Controls.AccessText]) -and ([int][char]$textHost.AccessKey -ne 0)
            foreach ($axis in @(@('W', $stateW, $gapW), @('H', $stateH, $gapH))) {
                if ([string]$axis[1] -ceq 'sized') { $gapSized++; continue }
                if ([string]$axis[1] -ceq 'under' -and $keySplit) { $gapAccessKey++; continue }
                Add-UiTextGapValue $stat ([string]$axis[0]) ([double]$axis[2])
                if ([string]$axis[1] -ceq 'under') {
                    $gapUnder++
                    if ($gapNotes.Count -lt 8) { [void]$gapNotes.Add('below the bound on ' + [string]$axis[0] + ': ' + $ident + $numbers) }
                }
            }
        }
        if ($isClipped) {
            [void]$problems.Add('clipped:' + (Get-UiElementLabel $text))
            [void]$diagnostics.Add('clipped: ' + $ident + $numbers)
        }
    }
    $gapName = $Name
    if (-not [string]::IsNullOrEmpty($PngName)) { $gapName = $PngName }
    $textGap = @{
        label = [string]::Format($inv, '{0} {1} {2} {3} {4}x{5}', $gapName, $theme, $scale.ToString('0.0#', $inv), $textScale.ToString('0.0#', $inv), $width, $height)
        scale = $scale; textScale = $textScale; bound = $gapBound; liveScales = [string[]]@($gapLiveScales.Keys | Sort-Object)
        nowrap = $gapNoWrap; wrap = $gapWrap; over = $gapOver; under = $gapUnder; offGrid = $gapOffGrid; sized = $gapSized
        accessKey = $gapAccessKey; trimmed = $gapTrimmed; remeasured = $gapRemeasured; notes = [string[]]@($gapNotes.ToArray())
    }
    [void]$script:UiRenderTextGapLog.Add($textGap)

    # outside: authored elements beyond the page's extent
    foreach ($el in $authored) {
        # Judged against the nearest scroll content: an element below the fold of a viewer inside the page is scrolled, not outside.
        $scroller = Get-UiScrollPresenter $el $presenter
        $scrollOwner = $scroller.TemplatedParent
        $elViewportWidth = [double]$scrollOwner.ViewportWidth
        # Only a viewer the case names (-ScrollOwners, a ListBox that scrolls sideways) holds a row wider than its viewport in its extent; every other viewer is judged as before.
        $ownerParent = $scrollOwner.TemplatedParent
        if ($ownerParent -is [System.Windows.FrameworkElement] -and (@($script:UiRenderScrollOwners) -ccontains [string]$ownerParent.Name) -and $scrollOwner.HorizontalScrollBarVisibility -ne [System.Windows.Controls.ScrollBarVisibility]::Disabled) {
            $elViewportWidth = [Math]::Max($elViewportWidth, [double]$scrollOwner.ExtentWidth)
        }
        # The content presenter stretches a short page to the viewport, so the bottom limit is the larger of the extent and the viewport.
        $elBottomLimit = [Math]::Max([double]$scrollOwner.ExtentHeight, [double]$scrollOwner.ViewportHeight)
        $r = Get-UiRelativeRect $el $scroller
        if ($null -eq $r) { $unmappedRects++; continue }
        if ($r.Left -lt -0.5 -or $r.Right -gt ($elViewportWidth + 0.5) -or $r.Bottom -gt ($elBottomLimit + 0.5)) {
            [void]$problems.Add('outside:' + (Get-UiElementLabel $el))
        }
    }

    # label-mismatch: an input's explicit name must equal the visible text of the label it points at. Each label's existing peer is read
    # first (FromElement never creates one), before any peer is created below, so the diagnostics show what a cold page really has.
    $labelPeerState = @{}
    $mismatched = @{}
    $labeledInputs = 0
    foreach ($el in $authored) {
        $label = [System.Windows.Automation.AutomationProperties]::GetLabeledBy($el)
        if ($null -eq $label) { continue }
        $labeledInputs++
        if ($null -ne [System.Windows.Automation.Peers.UIElementAutomationPeer]::FromElement($label)) { $labelPeerState[$el] = 'exists' } else { $labelPeerState[$el] = 'none' }
        $explicit = [string][System.Windows.Automation.AutomationProperties]::GetName($el)
        if ([string]::IsNullOrEmpty($explicit)) { continue }
        $labelText = $null
        if ($label -is [System.Windows.Controls.TextBlock]) { $labelText = [string]$label.Text }
        elseif ($label -is [System.Windows.Controls.Label]) {
            if ($label.Content -is [string]) { $labelText = Remove-UiAccessKey ([string]$label.Content) }
            else { [void]$diagnostics.Add((Get-UiElementLabel $el) + ': label-content-not-text (' + (Get-UiElementLabel $label) + ')') }
        }
        if ($null -ne $labelText -and -not $labelText.Trim().Equals($explicit.Trim(), [System.StringComparison]::Ordinal)) {
            [void]$problems.Add('label-mismatch:' + (Get-UiElementLabel $el))
            $mismatched[$el] = $true
        }
    }

    # unnamed: controls a screen reader would announce without a name
    foreach ($el in $authored) {
        $isNamed = $el -is [System.Windows.Controls.Button] -or $el -is [System.Windows.Controls.CheckBox] -or $el -is [System.Windows.Controls.ComboBox] -or
            $el -is [System.Windows.Controls.TextBox] -or $el -is [System.Windows.Controls.ListBoxItem] -or $el -is [System.Windows.Controls.RadioButton]
        if (-not $isNamed) { continue }
        $namedControlsSeen++
        $peer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($el)
        $name = ''
        if ($null -ne $peer) { $name = [string]$peer.GetName() }
        $nameMissing = Test-UiNameMissing $name
        if ($nameMissing) { [void]$problems.Add('unnamed:' + $el.GetType().Name) }
        if ($nameMissing -or $mismatched.ContainsKey($el)) {
            $labelDesc = 'none'
            $labelPeerText = 'none'
            $labeledBy = [System.Windows.Automation.AutomationProperties]::GetLabeledBy($el)
            if ($null -ne $labeledBy) {
                $labelName = 'none'
                if ($labeledBy -is [System.Windows.FrameworkElement] -and -not [string]::IsNullOrEmpty([string]$labeledBy.Name)) { $labelName = [string]$labeledBy.Name }
                $labelDesc = $labeledBy.GetType().Name + ':' + $labelName
                $labelPeerText = [string]$labelPeerState[$el]
            }
            [void]$diagnostics.Add((Get-UiElementLabel $el) + ": GetName='" + [string][System.Windows.Automation.AutomationProperties]::GetName($el) + "' LabeledBy=" + $labelDesc + ' labelPeer=' + $labelPeerText + " peerName='" + $name + "'")
        }
    }
    foreach ($tb in @($all | Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and (Test-UiAuthored $_) -and (Test-UiShown $_ $page) })) {
        foreach ($inline in $tb.Inlines) {
            if ($inline -is [System.Windows.Documents.Hyperlink] -and (Test-UiNameMissing (Get-UiHyperlinkName $inline))) { [void]$problems.Add('unnamed:Hyperlink') }
        }
    }

    # tab-order: tab sequence against reading order
    $stops = @()
    $index = 0
    foreach ($el in $all) {
        if ($el -is [System.Windows.Controls.Control] -and -not [object]::ReferenceEquals($el, $sv) -and (Test-UiAuthored $el) -and $el.Focusable -and $el.IsTabStop -and $el.IsEnabled -and (Test-UiShown $el $page)) {
            $rect = Get-UiRelativeRect $el $page
            if ($null -ne $rect) {
                $stops += [pscustomobject]@{
                    El = $el; Order = $index
                    TabIndex = [int][System.Windows.Input.KeyboardNavigation]::GetTabIndex($el)
                    Row = [double][Math]::Round($rect.Top / 8.0); Left = [double]$rect.Left
                    Region = (Get-UiTabRegion $el $page $TabRegions)
                }
            }
        }
        $index++
    }
    if ($stops.Count -gt 1) {
        $byTab = @($stops | Sort-Object -Property @{ Expression = 'TabIndex' }, @{ Expression = 'Order' })
        $byRead = @($stops | Sort-Object -Property @{ Expression = 'Region' }, @{ Expression = 'Row' }, @{ Expression = 'Left' }, @{ Expression = 'Order' })
        $same = $true
        for ($i = 0; $i -lt $stops.Count; $i++) { if (-not [object]::ReferenceEquals($byTab[$i].El, $byRead[$i].El)) { $same = $false; break } }
        if (-not $same) {
            [void]$problems.Add('tab-order')
            [void]$diagnostics.Add('tab-order: by tab order [' + ((@($byTab | ForEach-Object { Get-UiElementLabel $_.El }) -join ', ')) + '] by reading order [' + ((@($byRead | ForEach-Object { Get-UiElementLabel $_.El }) -join ', ')) + ']')
        }
    }

    # Probes: proof that the theme and the checks really reached the page. They never add a problem.
    $titleFontSize = $null
    $bodyFontSize = $null
    $titleForeground = ''
    $inheritedFontSize = $null
    $inheritedFontFamily = ''
    $inheritedForeground = ''
    foreach ($el in $all) {
        if ($el -is [System.Windows.FrameworkElement] -and $el -is [System.Windows.Controls.TextBlock]) {
            if ($el.Name -ceq 'TitleText') {
                $titleFontSize = [double]$el.FontSize
                if ($el.Foreground -is [System.Windows.Media.SolidColorBrush]) { $titleForeground = $el.Foreground.Color.ToString() }
            } elseif ($el.Name -ceq 'BodyText') { $bodyFontSize = [double]$el.FontSize }
            elseif ($el.Name -ceq 'InheritedText') {
                # a text block with no size, family or colour of its own: what the host hands down
                $inheritedFontSize = [double]$el.FontSize
                $inheritedFontFamily = [string]$el.FontFamily.Source
                if ($el.Foreground -is [System.Windows.Media.SolidColorBrush]) { $inheritedForeground = $el.Foreground.Color.ToString() }
            }
        }
    }
    return @{
        problems = [string[]]@($problems.ToArray()); diagnostics = [string[]]@($diagnostics.ToArray()); png = $png
        titleFontSize = $titleFontSize; bodyFontSize = $bodyFontSize; titleForeground = $titleForeground
        inheritedFontSize = $inheritedFontSize; inheritedFontFamily = $inheritedFontFamily; inheritedForeground = $inheritedForeground
        labeledInputs = $labeledInputs; textBlocks = $textBlocksSeen; namedControls = $namedControlsSeen; tabStops = @($stops).Count; unmappedRects = $unmappedRects
        textGap = $textGap
    }
}
