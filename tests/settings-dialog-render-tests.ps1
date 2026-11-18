#requires -Version 5.1
# Renders the real Settings dialog and checks its layout. Windows only (WinForms); elsewhere it skips cleanly.
# The dialog is built by BuildUiSettingsDialog in fast-llm-ui.ps1, the same function the window runs (taken from the file by its syntax tree, with
# only the application folder variable pointed at this checkout), with FitUiSettingsDialog and GetUiSettingsDialogMaxHeight. No ShowDialog, no Show().
# PNGs are saved into FASTLLM_RENDER_DIR, else $env:RUNNER_TEMP\fastllm-settings-dialog, else the user's temp folder, for four cases: 100%, 150% with
# the real screen's working area as the height cap, 150% with a 720 px cap and 100% with a 560 px cap (simulated small screens).
# Every case is rendered from a window shown only off every screen, without activation, and captured with PrintWindow (PW_RENDERFULLCONTENT).
# A dialog that is never shown (Control.DrawToBitmap) leaves the Thinking and idle lists blank; the CI run that settled this printed
# "case b", so the never-shown render is no longer used. A blank Port, Thinking or idle value fails.
# 150% is made by Form.Scale(1.5, 1.5) plus the fonts at 1.5 times (what a DPI-aware window gets).
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
if ($env:OS -ne 'Windows_NT') {
    Write-Host 'SKIP: settings-dialog-render-tests need Windows (WinForms); nothing was rendered.'
    exit 0
}
$root = Split-Path -Parent $PSScriptRoot
$script:checks = 0
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; $script:checks++; Write-Host "PASS: $Message" }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
# The window turns visual styles on before it creates any control (fast-llm-ui.ps1); so does this test, so the PNGs show the themed controls users see.
[Windows.Forms.Application]::EnableVisualStyles()
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FastLlmRenderNative {
    [DllImport("user32.dll", SetLastError = true)] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
}
'@
# Control.Visible is the effective visibility: it is false for every control on a form that is not shown, and the layout checks below run on
# dialogs that are never shown (only the pictures come from a dialog shown off-screen).
# What the dialog shows once it is opened is each control's own visible flag, which WinForms keeps as the state bit STATE_VISIBLE (0x2)
# behind the non-public Control.GetState. If this WinForms has no such method, the check below fails rather than skipping.
$script:controlGetState = [Windows.Forms.Control].GetMethod('GetState', [Reflection.BindingFlags]'NonPublic, Instance', $null, [Type[]]@([int]), $null)
Check ($null -ne $script:controlGetState) "WinForms has Control.GetState(int), which this test reads for a control's own visible flag"
function Test-OwnVisible($Control) { return [bool]$script:controlGetState.Invoke($Control, @([int]2)) }
# The controls get their windows before the dialog is shown off-screen (a control without one is not painted); accessing Handle creates them.
function Initialize-ControlHandles($Control) { [void]$Control.Handle; foreach ($child in @($Control.Controls)) { Initialize-ControlHandles $child } }
Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force
. (Join-Path $root 'src/FastLlm.UiFlow.ps1')
. (Join-Path $root 'src/FastLlm.Update.ps1')
. (Join-Path $root 'src/FastLlm.Components.ps1')
. (Join-Path $root 'src/FastLlm.ServingSettings.ps1')
. (Join-Path $root 'src/FastLlm.SignInStart.ps1')

# The real dialog builder, from the window's script.
$parseErrors = $null
$tree = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'fast-llm-ui.ps1'), [ref]$null, [ref]$parseErrors)
Check ($parseErrors.Count -eq 0) 'fast-llm-ui.ps1 parses'
$builders = @($tree.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'BuildUiSettingsDialog' }, $true))
Check ($builders.Count -eq 1) 'fast-llm-ui.ps1 defines BuildUiSettingsDialog once'
$fitFunctions = @($tree.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'FitUiSettingsDialog' }, $true))
Check ($fitFunctions.Count -eq 1) 'fast-llm-ui.ps1 defines FitUiSettingsDialog once'
$maxHeightFunctions = @($tree.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'GetUiSettingsDialogMaxHeight' }, $true))
Check ($maxHeightFunctions.Count -eq 1) 'fast-llm-ui.ps1 defines GetUiSettingsDialogMaxHeight once'
$builderText = [string]$builders[0].Extent.Text
Check ($builderText -notmatch '\.Visible\s*=' -and $builderText -notmatch '\.Hide\(\)') 'BuildUiSettingsDialog hides no control (it never sets .Visible or calls .Hide())'
$script:renderAppRoot = $root
Invoke-Expression ([string]$builders[0].Extent.Text.Replace('$PSScriptRoot', '$script:renderAppRoot'))
Invoke-Expression ([string]$fitFunctions[0].Extent.Text)
Invoke-Expression ([string]$maxHeightFunctions[0].Extent.Text)

# What the window gives the dialog (its form for the font, the install folder, the saved window settings).
$renderRoot = Join-Path ([IO.Path]::GetTempPath()) ('fastllm-settings-render-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $renderRoot | Out-Null
$script:installPath = $renderRoot
$script:settingsRoot = $renderRoot
$script:uiSettings = [pscustomobject]@{ allowSwitch = $true }
function NewUiApiKey($Owner) { return $false }
function SetTrayMenuAvailable($Value) { }

function Build-SettingsDialog([double]$Scale, [int]$MaxHeight, [switch]$EmptyLists) {
    $form = New-Object Windows.Forms.Form
    $form.Font = New-Object Drawing.Font('Segoe UI', 10)
    $current = Get-FastLlmServingSettings -InstallRoot $script:installPath
    $current | Add-Member -NotePropertyName allowSwitch -NotePropertyValue ([bool]$script:uiSettings.allowSwitch) -Force
    . BuildUiSettingsDialog
    # The self-check build: both lists with no selection, so the text-area measurement can be shown to read below the threshold.
    if ($EmptyLists) { $thinkingBox.SelectedIndex = -1; $idleBox.SelectedIndex = -1 }
    # Placed far off every screen and kept out of the taskbar before the window handle exists, in case this dialog is rendered from a shown window.
    $dialog.StartPosition = 'Manual'; $dialog.Location = New-Object Drawing.Point(-32000, -32000); $dialog.ShowInTaskbar = $false
    if ($Scale -ne 1.0) {
        $dialog.Scale((New-Object Drawing.SizeF([single]$Scale, [single]$Scale)))
        # The settings panel and the button row are the dialog's children; the controls in them take their font when they set none.
        foreach ($control in @($dialog.Controls)) { $control.Font = New-Object Drawing.Font($control.Font.FontFamily, [single]($control.Font.Size * $Scale), $control.Font.Style) }
    }
    $dialog.PerformLayout()
    if ($MaxHeight -gt 0) { FitUiSettingsDialog $dialog $MaxHeight }
    $dialog.PerformLayout()
    $settingsPanel.PerformLayout()
    [void]$dialog.Handle
    foreach ($control in @($dialog.Controls)) { Initialize-ControlHandles $control }
    return [pscustomobject]@{
        form = $form; dialog = $dialog; save = $saveButton; cancel = $cancelButton; buttonRow = $buttonRow; current = $current
        settingsPanel = $settingsPanel; portBox = $portBox; thinkingBox = $thinkingBox; idleBox = $idleBox; chatBox = $chatBox
        keyBox = $keyBox; keyHelp = $keyHelp; newKeyButton = $newKeyButton; startBox = $startBox; startState = $startState; startLast = $startLast
        switchBox = $switchBox; switchHelp = $switchHelp
    }
}

function Test-OnAnyScreen([Drawing.Rectangle]$Rectangle) {
    foreach ($screen in @([Windows.Forms.Screen]::AllScreens)) { if ($screen.Bounds.IntersectsWith($Rectangle)) { return $true } }
    return $false
}

# Shown only off every screen: placed with SetWindowPos at (-32000, -32000) without activation (SWP_NOACTIVATE | SWP_SHOWWINDOW | SWP_NOZORDER),
# painted by a bounded message pump, captured with PrintWindow and PW_RENDERFULLCONTENT (what the window painted, native edit and combo text
# included), then hidden, closed and disposed. Never Show(), never ShowDialog(), never a position on a screen.
function Save-ShownRender($Built, [string]$Path, [string]$Label) {
    $dialog = $Built.dialog
    $hwnd = $dialog.Handle
    $width = $dialog.Width; $height = $dialog.Height
    $afterBounds = [Drawing.Rectangle]::Empty; $captured = $false
    try {
        # Moved to (-32000, -32000) while still hidden (SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOSIZE), checked to be on no screen, and only then
        # shown where it is (SWP_SHOWWINDOW | SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOMOVE | SWP_NOSIZE).
        [void][FastLlmRenderNative]::SetWindowPos($hwnd, [IntPtr]::Zero, -32000, -32000, 0, 0, [uint32](0x0010 -bor 0x0004 -bor 0x0001))
        Check (-not (Test-OnAnyScreen $dialog.Bounds)) "the dialog is placed on no screen before it is shown ($Label): $($dialog.Bounds)"
        [void][FastLlmRenderNative]::SetWindowPos($hwnd, [IntPtr]::Zero, 0, 0, 0, 0, [uint32](0x0040 -bor 0x0010 -bor 0x0004 -bor 0x0002 -bor 0x0001))
        $afterBounds = $dialog.Bounds
        Check (-not (Test-OnAnyScreen $afterBounds)) "the shown dialog is on no screen ($Label): $afterBounds"
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while ($watch.ElapsedMilliseconds -lt 1500) { [Windows.Forms.Application]::DoEvents(); $dialog.Update(); Start-Sleep -Milliseconds 50 }
        Check (-not (Test-OnAnyScreen $dialog.Bounds)) "the dialog is still on no screen after it painted ($Label): $($dialog.Bounds)"
        $bitmap = New-Object Drawing.Bitmap($width, $height)
        try {
            $graphics = [Drawing.Graphics]::FromImage($bitmap)
            try {
                $hdc = $graphics.GetHdc()
                try { $captured = [FastLlmRenderNative]::PrintWindow($hwnd, $hdc, 2) } finally { $graphics.ReleaseHdc($hdc) }
            } finally { $graphics.Dispose() }
            Check $captured "PrintWindow (PW_RENDERFULLCONTENT) captured the shown dialog ($Label)"
            $bitmap.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
        } finally { $bitmap.Dispose() }
    } finally {
        # Always: hide (SWP_HIDEWINDOW | SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE), close, dispose.
        try { [void][FastLlmRenderNative]::SetWindowPos($hwnd, [IntPtr]::Zero, 0, 0, 0, 0, [uint32](0x0080 -bor 0x0010 -bor 0x0002 -bor 0x0001)) } catch { $null = $_ }
        try { $dialog.Close() } catch { $null = $_ }
        try { $dialog.Dispose() } catch { $null = $_ }
    }
    Check ($dialog.IsDisposed) "the dialog was shown only off-screen, on no screen, and is closed after ($Label)"
}

function Get-InkCount($Image, [Drawing.Rectangle]$Bounds, $Background) {
    $ink = 0
    for ($y = [Math]::Max(0, $Bounds.Top); $y -lt [Math]::Min($Image.Height, $Bounds.Bottom); $y++) {
        for ($x = [Math]::Max(0, $Bounds.Left); $x -lt [Math]::Min($Image.Width, $Bounds.Right); $x++) {
            $pixel = $Image.GetPixel($x, $y)
            if (([Math]::Abs([int]$pixel.R - [int]$Background.R) + [Math]::Abs([int]$pixel.G - [int]$Background.G) + [Math]::Abs([int]$pixel.B - [int]$Background.B)) -gt 96) { $ink++ }
        }
    }
    return $ink
}

# Ink inside a control's bounds in a saved render. The client area starts after the left border and the title bar (the borders of this fixed
# dialog are the same width on the left, right and bottom). Panel children are panel-relative and the panel sits at (0,0) at scroll 0.
function Get-ControlInk($Built, [string]$Png, $Control, [switch]$TextArea) {
    $dialog = $Built.dialog
    $offsetX = [int](($dialog.Width - $dialog.ClientSize.Width) / 2)
    $offsetY = [int]($dialog.Height - $dialog.ClientSize.Height - $offsetX)
    $bounds = $Control.Bounds
    if ($Control.Parent -is [Windows.Forms.Panel]) { $bounds = New-Object Drawing.Rectangle(($bounds.Left + $Control.Parent.Left), ($bounds.Top + $Control.Parent.Top), $bounds.Width, $bounds.Height) }
    if ($TextArea) {
        # Only where the value's text is drawn: inside the border and left of the drop-down or up-down buttons (about a scroll bar wide), so a
        # border or an arrow alone never counts as painted text.
        $inset = 4; $buttonsWidth = [Windows.Forms.SystemInformation]::VerticalScrollBarWidth + 4
        $bounds = New-Object Drawing.Rectangle(($bounds.Left + $inset), ($bounds.Top + $inset), [Math]::Max(0, $bounds.Width - 2 * $inset - $buttonsWidth), [Math]::Max(0, $bounds.Height - 2 * $inset))
    }
    $shifted = New-Object Drawing.Rectangle(($bounds.Left + $offsetX), ($bounds.Top + $offsetY), $bounds.Width, $bounds.Height)
    $image = New-Object Drawing.Bitmap($Png)
    try { return (Get-InkCount $image $shifted $dialog.BackColor) } finally { $image.Dispose() }
}

$outputFolder = $env:FASTLLM_RENDER_DIR
if ([string]::IsNullOrWhiteSpace($outputFolder)) {
    $base = $env:RUNNER_TEMP
    if ([string]::IsNullOrWhiteSpace($base)) { $base = [IO.Path]::GetTempPath() }
    $outputFolder = Join-Path $base 'fastllm-settings-dialog'
}
New-Item -ItemType Directory -Path $outputFolder -Force | Out-Null

try {
    $probeForm = New-Object Windows.Forms.Form
    try { $screenCap = [int](GetUiSettingsDialogMaxHeight $probeForm) } finally { $probeForm.Dispose() }
    Check ($screenCap -gt 0) "the working-area height of the screen is read ($screenCap px)"
    $cases = @(
        @{ scale = 1.0; name = '100'; cap = 0 },
        @{ scale = 1.5; name = '150'; cap = $screenCap },
        @{ scale = 1.5; name = '150-small'; cap = 720 },
        @{ scale = 1.0; name = '100-small'; cap = 560 })
    # Self-check of the measurement first: the same dialog with both lists empty, rendered the same way, must read below the threshold in their
    # text areas, so a border, an arrow or a bad capture can never pass as painted text.
    $emptyShownPng = Join-Path $renderRoot 'self-check-empty-lists-shown.png'
    $emptyBuilt = Build-SettingsDialog 1.0 0 -EmptyLists
    try {
        Save-ShownRender $emptyBuilt $emptyShownPng 'self-check'
        $emptyCheck = Build-SettingsDialog 1.0 0 -EmptyLists
        try { $emptyShownInk = @((Get-ControlInk $emptyCheck $emptyShownPng $emptyCheck.thinkingBox -TextArea), (Get-ControlInk $emptyCheck $emptyShownPng $emptyCheck.idleBox -TextArea)) }
        finally { $emptyCheck.dialog.Dispose(); $emptyCheck.form.Dispose() }
    } finally { $emptyBuilt.dialog.Dispose(); $emptyBuilt.form.Dispose(); if (Test-Path -LiteralPath $emptyShownPng) { [IO.File]::Delete($emptyShownPng) } }
    Check ($emptyShownInk[0] -lt 40 -and $emptyShownInk[1] -lt 40) "self-check: empty Thinking and idle lists read below the text threshold in the shown render ($($emptyShownInk -join ', ') pixels)"
    # The pictures next, so they are saved for a person to look at even when a layout check below fails.
    foreach ($case in $cases) {
        $built = Build-SettingsDialog $case.scale $case.cap
        try { Save-ShownRender $built (Join-Path $outputFolder ('settings-dialog-' + $case.name + '.png')) "$($case.name)%" }
        finally { $built.dialog.Dispose(); $built.form.Dispose() }
    }
    foreach ($case in $cases) {
        $built = Build-SettingsDialog $case.scale $case.cap
        try {
            $dialog = $built.dialog
            $panel = $built.settingsPanel
            $label = "at $($case.name)%"
            Check (-not $dialog.Visible) "the dialog under layout checks is built off-screen and not shown ($label)"
            $row = $built.buttonRow
            # Save and Cancel in dialog coordinates (they sit in the button row).
            $saveRect = New-Object Drawing.Rectangle(($row.Left + $built.save.Left), ($row.Top + $built.save.Top), $built.save.Width, $built.save.Height)
            $cancelRect = New-Object Drawing.Rectangle(($row.Left + $built.cancel.Left), ($row.Top + $built.cancel.Top), $built.cancel.Width, $built.cancel.Height)
            if ($case.scale -eq 1.0 -and $case.cap -eq 0) { Check ($dialog.Height -eq 628 -and $saveRect.Top -eq 544 -and $cancelRect.Top -eq 544 -and $saveRect.Left -eq 300 -and $cancelRect.Left -eq 420 -and $panel.Width -eq $dialog.ClientSize.Width -and $panel.Height -eq 536) "the dialog is the 628 px layout: settings 536 px tall, Save at (300,544) and Cancel at (420,544) ($label): $saveRect $cancelRect panel $($panel.Bounds)" }
            if ($case.scale -eq 1.5) { Check ([Math]::Abs($built.keyBox.Font.Size - 15.0) -lt 0.1) "the settings text is 1.5 times larger ($label): $($built.keyBox.Font.Size) pt" }
            if ($case.cap -gt 0) { Check ($dialog.Height -le $case.cap) "the dialog is no taller than its cap ($label): $($dialog.Height) px of $($case.cap)" }
            # Save and Cancel pinned and visible; the panel sits above them.
            Check ($dialog.ClientRectangle.Contains($saveRect) -and $dialog.ClientRectangle.Contains($cancelRect)) "Save and Cancel lie fully inside the client area ($label): $saveRect $cancelRect in $($dialog.ClientRectangle)"
            Check ($row.Bottom -eq $dialog.ClientSize.Height -and $row.Left -eq 0 -and $row.Width -eq $dialog.ClientSize.Width -and $row.ClientRectangle.Contains($built.save.Bounds) -and $row.ClientRectangle.Contains($built.cancel.Bounds)) "the button row is docked to the bottom edge, full width, and holds Save and Cancel inside it ($label): row $($row.Bounds)"
            Check ($panel.Top -eq 0 -and $panel.Bottom -eq $row.Top -and -not $panel.Bounds.IntersectsWith($saveRect) -and -not $panel.Bounds.IntersectsWith($cancelRect)) "the settings panel fills the dialog down to the button row and overlaps neither button ($label): panel $($panel.Bounds)"
            Check ($dialog.ClientRectangle.Contains($panel.Bounds)) "the settings panel lies within the client area ($label)"
            Check ($built.save.Bounds.Right -le $built.cancel.Bounds.Left -or $built.save.Bounds.Bottom -le $built.cancel.Bounds.Top) "Save and Cancel do not overlap each other ($label)"
            Check ($panel.AutoScroll) "the settings panel scrolls ($label)"
            # Every settings control is the panel's child and can be reached by scrolling.
            $dialogChildren = @($dialog.Controls | ForEach-Object { $_ })
            Check ($dialogChildren.Count -eq 2 -and $dialog.Controls.Contains($panel) -and $dialog.Controls.Contains($row)) "the dialog holds only the settings panel and the button row ($label)"
            $rowChildren = @($row.Controls | ForEach-Object { $_ })
            Check ($rowChildren.Count -eq 2 -and $row.Controls.Contains($built.save) -and $row.Controls.Contains($built.cancel)) "the button row holds only Save and Cancel ($label)"
            $panel.PerformLayout()
            $display = $panel.DisplayRectangle
            $unreachable = @($panel.Controls | Where-Object { -not $display.Contains($_.Bounds) } | ForEach-Object { [string]$_.GetType().Name + '@' + $_.Bounds })
            Check ($unreachable.Count -eq 0) "every settings control is in the panel and inside its scrollable area ($label) [$($unreachable -join '; ')] display=$display"
            $contentBottom = [int](@($panel.Controls | ForEach-Object { $_.Bottom }) | Measure-Object -Maximum).Maximum
            if ($contentBottom -gt $panel.ClientSize.Height) {
                Check ($display.Height -gt $panel.ClientSize.Height) "the content is taller than the panel, so it scrolls ($label): content $contentBottom px, panel $($panel.ClientSize.Height) px, scroll area $($display.Height) px"
            }
            if ($case.scale -eq 1.0 -and $case.cap -eq 0) { Check ($display.Height -le $panel.ClientSize.Height) "at 100% nothing needs scrolling ($label): scroll area $($display.Height) px, panel $($panel.ClientSize.Height) px" }
            $contentRight = [int](@($panel.Controls | ForEach-Object { $_.Right }) | Measure-Object -Maximum).Maximum
            Write-Host "INFO: horizontal fit ($label): widest setting ends at $contentRight px; panel shows $($panel.ClientSize.Width) px; scroll area $($display.Width) px"
            foreach ($required in @(
                    @{ name = 'the API key box'; control = $built.keyBox; text = 'Require an API key*' },
                    @{ name = 'Create a new key'; control = $built.newKeyButton; text = 'Create a new key*' },
                    @{ name = 'the start at sign-in box'; control = $built.startBox; text = 'Start FastLLM when I sign in' },
                    @{ name = 'the switching box'; control = $built.switchBox; text = 'Allow switching models while FastLLM runs' })) {
                Check ($panel.Controls.Contains($required.control) -and (Test-OwnVisible $required.control) -and $required.control.Width -gt 0 -and $required.control.Height -gt 0 -and $required.control.Text -clike $required.text) "$($required.name) is present and visible ($label)"
            }
            foreach ($help in @($built.keyHelp, $built.startState, $built.startLast, $built.switchHelp)) {
                Check ($panel.Controls.Contains($help) -and (Test-OwnVisible $help)) "the text under the key, sign-in and switching controls is present ($label): $($help.GetType().Name)@$($help.Bounds)"
            }
            # The values are set on the Port box and the two lists (what the PNG then has to show).
            Check ([int]$built.portBox.Value -eq [int]$built.current.serverPort) "the Port box holds the serving settings' port ($label): $($built.portBox.Value)"
            Check ($built.thinkingBox.SelectedIndex -ge 0 -and -not [string]::IsNullOrWhiteSpace([string]$built.thinkingBox.Text)) "the Thinking list has a selection and text ($label): $($built.thinkingBox.Text)"
            Check ($built.idleBox.SelectedIndex -ge 0 -and -not [string]::IsNullOrWhiteSpace([string]$built.idleBox.Text)) "the idle list has a selection and text ($label): $($built.idleBox.Text)"
            # Reading order: the switching controls sit below the sign-in ones, and the panel that holds them is above Save and Cancel.
            Check ($built.switchBox.Top -ge $built.startLast.Bottom) "the switching controls sit below the sign-in controls ($label)"
            if ($case.cap -eq 0) { Check ($built.switchHelp.Bottom -le $row.Top) "the switching help sits above Save and Cancel when nothing is capped ($label)" }
            if ($case.scale -eq 1.0) {
                # The switching text must fit its label (informational for the older labels: printed, not asserted).
                $flags = [Windows.Forms.TextFormatFlags]::WordBreak -bor [Windows.Forms.TextFormatFlags]::NoPadding
                $needed = [Windows.Forms.TextRenderer]::MeasureText([string]$built.switchHelp.Text, $built.switchHelp.Font, (New-Object Drawing.Size($built.switchHelp.Width, 0)), $flags).Height
                Check ($needed -le $built.switchHelp.Height) "the switching help text fits its label ($needed px needed, $($built.switchHelp.Height) px available)"
                foreach ($other in @($built.keyHelp, $built.startState, $built.startLast)) {
                    $otherNeeded = [Windows.Forms.TextRenderer]::MeasureText([string]$other.Text, $other.Font, (New-Object Drawing.Size($other.Width, 0)), $flags).Height
                    Write-Host "INFO: $($other.GetType().Name) at y=$($other.Top) needs $otherNeeded px of $($other.Height) by TextRenderer (GDI)"
                }
            }
            # Each help label's text fits its box as the label itself lays it out. TextRenderer measures with GDI, but these labels draw with GDI+
            # (the window never calls SetCompatibleTextRenderingDefault(false), so UseCompatibleTextRendering stays on), which sets text narrower;
            # GetPreferredSize at the label's width uses the label's own engine and padding.
            foreach ($help in @($built.keyHelp, $built.startState, $built.startLast, $built.switchHelp)) {
                $ownNeeded = $help.GetPreferredSize((New-Object Drawing.Size($help.Width, 0))).Height
                Check ($ownNeeded -le $help.Height) "the help text at y=$($help.Top) fits its label as the label lays it out ($label): $ownNeeded px of $($help.Height), compatible text rendering $($help.UseCompatibleTextRendering)"
            }
            $png = Join-Path $outputFolder ('settings-dialog-' + $case.name + '.png')
            Check ((Test-Path -LiteralPath $png -PathType Leaf) -and (Get-Item -LiteralPath $png).Length -gt 1000) "the render was saved: $png"
            # The picture shows the controls, not an empty frame: inside each control's bounds the saved render has text and border pixels that
            # differ from the dialog background. Panel children only where they lie in the visible panel area at scroll 0.
            foreach ($painted in @(
                    @{ name = 'Save'; control = $built.save; always = $true },
                    @{ name = 'Cancel'; control = $built.cancel; always = $true },
                    @{ name = 'the API key box'; control = $built.keyBox; always = $false },
                    @{ name = 'the start at sign-in box'; control = $built.startBox; always = $false },
                    @{ name = 'the switching box'; control = $built.switchBox; always = $false })) {
                if (-not $painted.always -and $painted.control.Bottom -gt $panel.ClientSize.Height) { Write-Host "INFO: $($painted.name) is below the visible panel area at scroll 0 ($label); not read from the picture"; continue }
                $ink = Get-ControlInk $built $png $painted.control
                Check ($ink -ge 40) "the render shows $($painted.name) ($label): $ink text or border pixels in its bounds"
            }
            $valueInk = [ordered]@{}
            foreach ($valueField in @(@{ name = 'the Port box'; control = $built.portBox }, @{ name = 'the Thinking list'; control = $built.thinkingBox }, @{ name = 'the idle list'; control = $built.idleBox })) {
                $valueInk[$valueField.name] = @{ ink = (Get-ControlInk $built $png $valueField.control -TextArea); visible = ($valueField.control.Bottom -le $panel.ClientSize.Height) }
            }
            Write-Host ("INFO: values ($label): Port=$($built.portBox.Value) Thinking='$($built.thinkingBox.Text)' idle='$($built.idleBox.Text)'; ink " + ((@($valueInk.Keys | ForEach-Object { "$_=$($valueInk[$_].ink)" })) -join ', '))
            foreach ($name in @($valueInk.Keys)) {
                if ($valueInk[$name].visible) { Check ($valueInk[$name].ink -ge 40) "the render paints $name ($label): $($valueInk[$name].ink) text pixels" }
            }
        } finally {
            $built.dialog.Dispose()
            $built.form.Dispose()
        }
    }
} finally {
    # The folder this run created is empty (nothing is written to it): removed as the one path recorded above.
    try { [IO.Directory]::Delete($renderRoot) } catch { $null = $_ }
}
Write-Host "settings-dialog-render-tests: $script:checks checks passed. PNGs in $outputFolder"
