#requires -Version 5.1
# The drawn FastLLM app icon for the fluent window: a rounded square in the accent fill with a white chevron.
# New-FastLlmUiAppIconImage is vector (WPF Window.Icon); New-FastLlmUiTrayIcon draws the same mark with System.Drawing.
# No WPF or WinForms type is resolved at dot-source time, only inside function bodies.
Set-StrictMode -Version 2.0

$script:FastLlmUiFluentTrayIconCache = $null

function New-FastLlmUiAppIconImage {
    [CmdletBinding()]
    param([string] $AccentArgb = '#FF005FB8')
    $color = [System.Windows.Media.ColorConverter]::ConvertFromString($AccentArgb)
    $fill = New-Object System.Windows.Media.SolidColorBrush($color)
    $fill.Freeze()
    $white = [System.Windows.Media.Brushes]::White
    $pen = New-Object System.Windows.Media.Pen($white, 3.6)
    $pen.StartLineCap = [System.Windows.Media.PenLineCap]::Round
    $pen.EndLineCap = [System.Windows.Media.PenLineCap]::Round
    $pen.LineJoin = [System.Windows.Media.PenLineJoin]::Round
    $pen.Freeze()
    $square = New-Object System.Windows.Media.RectangleGeometry((New-Object System.Windows.Rect(0, 0, 32, 32)), 7, 7)
    $square.Freeze()
    $chevron = [System.Windows.Media.Geometry]::Parse('M12,9 L20,16 L12,23')
    $chevron.Freeze()
    $bg = New-Object System.Windows.Media.GeometryDrawing($fill, $null, $square)
    $bg.Freeze()
    $mark = New-Object System.Windows.Media.GeometryDrawing($null, $pen, $chevron)
    $mark.Freeze()
    $group = New-Object System.Windows.Media.DrawingGroup
    [void] $group.Children.Add($bg)
    [void] $group.Children.Add($mark)
    $group.Freeze()
    $image = New-Object System.Windows.Media.DrawingImage($group)
    $image.Freeze()
    return $image
}

function New-FastLlmUiTrayIcon {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [int] $Size,
        [string] $AccentArgb = '#FF005FB8'
    )
    if ($Size -lt 8) { $Size = 8 }
    $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $h = [IntPtr]::Zero
    $tmp = $null
    try {
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $g.Clear([System.Drawing.Color]::Transparent)
            $accent = [System.Drawing.ColorTranslator]::FromHtml('#' + $AccentArgb.TrimStart('#').Substring(2))
            $scale = [single] ($Size / 32.0)
            $radius = [single] (7 * $scale)
            $d = $radius * 2
            $w = [single] $Size
            $path = New-Object System.Drawing.Drawing2D.GraphicsPath
            try {
                $path.AddArc([single] 0, [single] 0, $d, $d, 180, 90)
                $path.AddArc([single] ($w - $d), [single] 0, $d, $d, 270, 90)
                $path.AddArc([single] ($w - $d), [single] ($w - $d), $d, $d, 0, 90)
                $path.AddArc([single] 0, [single] ($w - $d), $d, $d, 90, 90)
                $path.CloseFigure()
                $brush = New-Object System.Drawing.SolidBrush($accent)
                try { $g.FillPath($brush, $path) } finally { $brush.Dispose() }
            }
            finally { $path.Dispose() }
            $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, [single] (3.6 * $scale))
            try {
                $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
                $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
                $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
                $pts = [System.Drawing.PointF[]] @(
                    (New-Object System.Drawing.PointF([single] (12 * $scale), [single] (9 * $scale))),
                    (New-Object System.Drawing.PointF([single] (20 * $scale), [single] (16 * $scale))),
                    (New-Object System.Drawing.PointF([single] (12 * $scale), [single] (23 * $scale))))
                $g.DrawLines($pen, $pts)
            }
            finally { $pen.Dispose() }
        }
        finally { $g.Dispose() }
        $h = $bmp.GetHicon()
        $tmp = [System.Drawing.Icon]::FromHandle($h)
        $icon = $tmp.Clone()
    }
    finally {
        if ($null -ne $tmp) { $tmp.Dispose() }
        if ($h -ne [IntPtr]::Zero) { [void] [Bitworks.FastLlm.FluentWindowNative]::DestroyIconHandle($h) }
        $bmp.Dispose()
    }
    return $icon
}

function Get-FastLlmUiFluentTrayIcon {
    [CmdletBinding()]
    param()
    if ($null -eq $script:FastLlmUiFluentTrayIconCache) {
        $size = [System.Windows.Forms.SystemInformation]::SmallIconSize.Width
        $script:FastLlmUiFluentTrayIconCache = New-FastLlmUiTrayIcon -Size $size
    }
    return $script:FastLlmUiFluentTrayIconCache
}

function Clear-FastLlmUiFluentTrayIcon {
    [CmdletBinding()]
    param()
    if ($null -ne $script:FastLlmUiFluentTrayIconCache) {
        try { $script:FastLlmUiFluentTrayIconCache.Dispose() } catch { $null = $_ }
        $script:FastLlmUiFluentTrayIconCache = $null
    }
}
