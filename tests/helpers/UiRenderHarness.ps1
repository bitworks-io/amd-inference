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

function Test-UiAuthored($Element) {
    return ($Element -is [System.Windows.FrameworkElement]) -and ($null -eq $Element.TemplatedParent)
}

# Natural size of a text block's text, measured on a fresh clone (never the live element).
function Get-UiTextNaturalSize($Text, [double]$Scale, [double]$ActualWidth) {
    $clone = New-Object System.Windows.Controls.TextBlock
    $clone.Text = $Text.Text
    $clone.FontFamily = $Text.FontFamily
    $clone.FontSize = $Text.FontSize
    $clone.FontWeight = $Text.FontWeight
    $clone.FontStyle = $Text.FontStyle
    $clone.FontStretch = $Text.FontStretch
    $clone.TextWrapping = $Text.TextWrapping
    $clone.Padding = $Text.Padding
    if (-not [double]::IsNaN([double]$Text.LineHeight)) {
        $clone.LineHeight = $Text.LineHeight
        $clone.LineStackingStrategy = $Text.LineStackingStrategy
    }
    [System.Windows.Media.VisualTreeHelper]::SetRootDpi($clone, (New-Object System.Windows.DpiScale($Scale, $Scale)))
    $inf = [double]::PositiveInfinity
    if ($Text.TextWrapping -eq [System.Windows.TextWrapping]::NoWrap) {
        $clone.Measure((New-Object System.Windows.Size($inf, $inf)))
    } else {
        $clone.Measure((New-Object System.Windows.Size($ActualWidth, $inf)))
    }
    return $clone.DesiredSize
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

function Invoke-UiRenderCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Case,
        [string]$OutFolder = ''
    )
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $theme = [string]$Case.theme
    $scale = [double]$Case.scale
    $textScale = [double]$Case.textScale
    $width = [int]$Case.width
    $height = [int]$Case.height
    $problems = New-Object System.Collections.ArrayList

    $page = New-FastLlmUiXamlElement -Name $Name
    $themeArgs = @{ Theme = $theme; AccentPair = (Get-FastLlmUiAccentPair -Palette $null); TextScale = $textScale }
    if ($theme -eq 'high-contrast') {
        $themeArgs['HighContrastPalette'] = @{ Window = '#000000'; WindowText = '#FFFFFF'; Highlight = '#1AEBFF'; HighlightText = '#000000' }
    }
    $dict = New-FastLlmUiThemeDictionary @themeArgs
    $page.Resources = $dict

    $sv = New-Object System.Windows.Controls.ScrollViewer
    $sv.Width = $width
    $sv.Height = $height
    $sv.HorizontalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Disabled
    $sv.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $sv.UseLayoutRounding = $true
    $sv.Background = $dict['FastLlm.LayerBrush']
    $sv.Content = $page
    [System.Windows.Media.VisualTreeHelper]::SetRootDpi($sv, (New-Object System.Windows.DpiScale($scale, $scale)))
    $sv.Measure((New-Object System.Windows.Size($width, $height)))
    $sv.Arrange((New-Object System.Windows.Rect(0, 0, $width, $height)))
    $sv.UpdateLayout()
    $sv.UpdateLayout()

    $png = ''
    if (-not [string]::IsNullOrEmpty($OutFolder)) {
        [void][System.IO.Directory]::CreateDirectory($OutFolder)
        $pw = [int][Math]::Ceiling($width * $scale)
        $ph = [int][Math]::Ceiling($height * $scale)
        $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($pw, $ph, (96.0 * $scale), (96.0 * $scale), [System.Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($sv)
        $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $fileName = [string]::Format($inv, '{0}-{1}-{2}-{3}-{4}x{5}.png', $Name, $theme, $scale.ToString('0.0#', $inv), $textScale.ToString('0.0#', $inv), $width, $height)
        $png = Join-Path $OutFolder $fileName
        $fs = [System.IO.File]::Create($png)
        try { $encoder.Save($fs) } finally { $fs.Dispose() }
    }

    $viewportWidth = [double]$sv.ViewportWidth
    # The content presenter stretches a short page to the viewport, so the bottom limit is the larger of the extent and the viewport.
    $bottomLimit = [Math]::Max([double]$sv.ExtentHeight, [double]$sv.ViewportHeight)
    $presenter = [System.Windows.Media.VisualTreeHelper]::GetParent($page)
    $all = Get-UiVisualElements $page
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

    # clipped: every shown TextBlock, including a button's content
    foreach ($text in @($all | Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and (Test-UiShown $_ $page) })) {
        $aw = [double]$text.ActualWidth
        $ah = [double]$text.ActualHeight
        if ($aw -le 0 -and $ah -le 0) { continue }
        $natural = Get-UiTextNaturalSize $text $scale $aw
        # Signal 1: Measure clamps DesiredSize to the constraint (Width, MaxWidth, a button's content area), so the live desired size minus margin
        # falls below the natural size. Signal 2: the visible rectangle (layout clip, ClipToBounds) is smaller than the natural size.
        $desired = $text.DesiredSize
        $mw = [double]$text.Margin.Left + [double]$text.Margin.Right
        $mh = [double]$text.Margin.Top + [double]$text.Margin.Bottom
        $isClipped = ($natural.Width -gt ($desired.Width - $mw + 0.5)) -or ($natural.Height -gt ($desired.Height - $mh + 0.5))
        if (-not $isClipped) {
            $vis = Get-UiVisibleRect $text $presenter
            if ($null -ne $vis) {
                if ($vis.IsEmpty) { $isClipped = $true }
                else { $isClipped = ($natural.Width -gt ($vis.Width + 0.5)) -or ($natural.Height -gt ($vis.Height + 0.5)) }
            }
        }
        if ($isClipped -and $text.TextTrimming -ne [System.Windows.TextTrimming]::None -and [string]$text.ToolTip -ceq [string]$text.Text) { $isClipped = $false }
        if ($isClipped) { [void]$problems.Add('clipped:' + (Get-UiElementLabel $text)) }
    }

    # outside: authored elements beyond the page's extent
    foreach ($el in $authored) {
        $r = Get-UiRelativeRect $el $presenter
        if ($null -eq $r) { continue }
        if ($r.Left -lt -0.5 -or $r.Right -gt ($viewportWidth + 0.5) -or $r.Bottom -gt ($bottomLimit + 0.5)) {
            [void]$problems.Add('outside:' + (Get-UiElementLabel $el))
        }
    }

    # unnamed: controls a screen reader would announce without a name
    foreach ($el in $authored) {
        $isNamed = $el -is [System.Windows.Controls.Button] -or $el -is [System.Windows.Controls.CheckBox] -or $el -is [System.Windows.Controls.ComboBox] -or
            $el -is [System.Windows.Controls.TextBox] -or $el -is [System.Windows.Controls.ListBoxItem] -or $el -is [System.Windows.Controls.RadioButton]
        if (-not $isNamed) { continue }
        $peer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($el)
        $name = ''
        if ($null -ne $peer) { $name = [string]$peer.GetName() }
        if (Test-UiNameMissing $name) { [void]$problems.Add('unnamed:' + $el.GetType().Name) }
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
                }
            }
        }
        $index++
    }
    if ($stops.Count -gt 1) {
        $byTab = @($stops | Sort-Object -Property @{ Expression = 'TabIndex' }, @{ Expression = 'Order' })
        $byRead = @($stops | Sort-Object -Property @{ Expression = 'Row' }, @{ Expression = 'Left' }, @{ Expression = 'Order' })
        $same = $true
        for ($i = 0; $i -lt $stops.Count; $i++) { if (-not [object]::ReferenceEquals($byTab[$i].El, $byRead[$i].El)) { $same = $false; break } }
        if (-not $same) { [void]$problems.Add('tab-order') }
    }

    return @{ problems = [string[]]@($problems.ToArray()); png = $png }
}
