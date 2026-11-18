#requires -Version 5.1
# Renders the real Settings dialog off-screen and checks its layout. Windows only (WinForms); elsewhere it skips cleanly.
# The dialog is built by BuildUiSettingsDialog in fast-llm-ui.ps1, the same function the window runs (taken from the file by its syntax tree, with
# only the application folder variable pointed at this checkout). Nothing is shown: no ShowDialog, no window on the desktop, no process, no network.
# Two PNGs are saved with Control.DrawToBitmap, at 100% and at 150%, into FASTLLM_RENDER_DIR, else $env:RUNNER_TEMP\fastllm-settings-dialog,
# else the user's temp folder. 150% is made by Form.Scale(1.5, 1.5) plus the fonts at 1.5 times on a second instance (what a DPI-aware window gets).
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
# Control.Visible is the effective visibility: it is false for every control on a form that is not shown, and this dialog is never shown.
# What the dialog shows once it is opened is each control's own visible flag, which WinForms keeps as the state bit STATE_VISIBLE (0x2)
# behind the non-public Control.GetState. If this WinForms has no such method, the check below fails rather than skipping.
$script:controlGetState = [Windows.Forms.Control].GetMethod('GetState', [Reflection.BindingFlags]'NonPublic, Instance', $null, [Type[]]@([int]), $null)
Check ($null -ne $script:controlGetState) "WinForms has Control.GetState(int), which this test reads for a control's own visible flag"
function Test-OwnVisible($Control) { return [bool]$script:controlGetState.Invoke($Control, @([int]2)) }
# DrawToBitmap paints only child controls that have a window; on a dialog that is never shown, accessing Handle creates them.
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
$builderText = [string]$builders[0].Extent.Text
Check ($builderText -notmatch '\.Visible\s*=' -and $builderText -notmatch '\.Hide\(\)') 'BuildUiSettingsDialog hides no control (it never sets .Visible or calls .Hide())'
$script:renderAppRoot = $root
Invoke-Expression ([string]$builders[0].Extent.Text.Replace('$PSScriptRoot', '$script:renderAppRoot'))

# What the window gives the dialog (its form for the font, the install folder, the saved window settings). The dialog is never shown.
$renderRoot = Join-Path ([IO.Path]::GetTempPath()) ('fastllm-settings-render-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $renderRoot | Out-Null
$script:installPath = $renderRoot
$script:settingsRoot = $renderRoot
$script:uiSettings = [pscustomobject]@{ allowSwitch = $true }
function NewUiApiKey($Owner) { return $false }
function SetTrayMenuAvailable($Value) { }

function Build-SettingsDialog([double]$Scale) {
    $form = New-Object Windows.Forms.Form
    $form.Font = New-Object Drawing.Font('Segoe UI', 10)
    $current = Get-FastLlmServingSettings -InstallRoot $script:installPath
    $current | Add-Member -NotePropertyName allowSwitch -NotePropertyValue ([bool]$script:uiSettings.allowSwitch) -Force
    . BuildUiSettingsDialog
    if ($Scale -ne 1.0) {
        $dialog.Scale((New-Object Drawing.SizeF([single]$Scale, [single]$Scale)))
        foreach ($control in @($dialog.Controls)) { $control.Font = New-Object Drawing.Font($control.Font.FontFamily, [single]($control.Font.Size * $Scale), $control.Font.Style) }
    }
    [void]$dialog.Handle
    foreach ($control in @($dialog.Controls)) { Initialize-ControlHandles $control }
    return [pscustomobject]@{
        form = $form; dialog = $dialog; save = $saveButton; cancel = $cancelButton
        keyBox = $keyBox; keyHelp = $keyHelp; newKeyButton = $newKeyButton; startBox = $startBox; startState = $startState; startLast = $startLast
        switchBox = $switchBox; switchHelp = $switchHelp
    }
}

function Save-Render($Built, [string]$Path) {
    $bitmap = New-Object Drawing.Bitmap($Built.dialog.Width, $Built.dialog.Height)
    try {
        $Built.dialog.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0, 0, $Built.dialog.Width, $Built.dialog.Height)))
        $bitmap.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
    } finally { $bitmap.Dispose() }
}

$outputFolder = $env:FASTLLM_RENDER_DIR
if ([string]::IsNullOrWhiteSpace($outputFolder)) {
    $base = $env:RUNNER_TEMP
    if ([string]::IsNullOrWhiteSpace($base)) { $base = [IO.Path]::GetTempPath() }
    $outputFolder = Join-Path $base 'fastllm-settings-dialog'
}
New-Item -ItemType Directory -Path $outputFolder -Force | Out-Null

try {
    $cases = @(@{ scale = 1.0; name = '100' }, @{ scale = 1.5; name = '150' })
    # The pictures first, so both are saved for a person to look at even when a check below fails.
    foreach ($case in $cases) {
        $built = Build-SettingsDialog $case.scale
        try { Save-Render $built (Join-Path $outputFolder ('settings-dialog-' + $case.name + '.png')) }
        finally { $built.dialog.Dispose(); $built.form.Dispose() }
    }
    foreach ($case in $cases) {
        $built = Build-SettingsDialog $case.scale
        try {
            $dialog = $built.dialog
            $label = "at $($case.name)%"
            Check (-not $dialog.Visible) "the dialog is built off-screen and not shown ($label)"
            if ($case.scale -eq 1.0) { Check ($dialog.Height -eq 628 -and $built.save.Top -eq 544 -and $built.cancel.Top -eq 544) "the dialog is the 628 px layout with Save and Cancel at y=544 ($label)" }
            $outside = @($dialog.Controls | Where-Object { -not $dialog.ClientRectangle.Contains($_.Bounds) } | ForEach-Object { [string]$_.GetType().Name + '@' + $_.Bounds })
            Check ($outside.Count -eq 0) "every control lies within the client area ($label) [$($outside -join '; ')]"
            $overlapping = @()
            foreach ($control in @($dialog.Controls)) {
                foreach ($button in @($built.save, $built.cancel)) {
                    if ([object]::ReferenceEquals($control, $button)) { continue }
                    if ($control.Bounds.IntersectsWith($button.Bounds)) { $overlapping += ([string]$control.GetType().Name + '@' + $control.Bounds) }
                }
            }
            Check ($overlapping.Count -eq 0) "nothing overlaps Save or Cancel ($label) [$($overlapping -join '; ')]"
            Check ($built.save.Bounds.Right -le $built.cancel.Bounds.Left -or $built.save.Bounds.Bottom -le $built.cancel.Bounds.Top) "Save and Cancel do not overlap each other ($label)"
            foreach ($required in @(
                    @{ name = 'the API key box'; control = $built.keyBox; text = 'Require an API key*' },
                    @{ name = 'Create a new key'; control = $built.newKeyButton; text = 'Create a new key*' },
                    @{ name = 'the start at sign-in box'; control = $built.startBox; text = 'Start FastLLM when I sign in' },
                    @{ name = 'the switching box'; control = $built.switchBox; text = 'Allow switching models while FastLLM runs' })) {
                Check ($dialog.Controls.Contains($required.control) -and (Test-OwnVisible $required.control) -and $required.control.Width -gt 0 -and $required.control.Height -gt 0 -and $required.control.Text -clike $required.text) "$($required.name) is present and visible ($label)"
            }
            foreach ($help in @($built.keyHelp, $built.startState, $built.startLast, $built.switchHelp)) {
                Check ($dialog.Controls.Contains($help) -and (Test-OwnVisible $help)) "the text under the key, sign-in and switching controls is present ($label): $($help.GetType().Name)@$($help.Bounds)"
            }
            # Reading order: the switching controls sit below the sign-in ones and above Save and Cancel.
            Check ($built.switchBox.Top -ge $built.startLast.Bottom -and $built.switchHelp.Bottom -le $built.save.Top) "the switching controls sit below the sign-in controls and above Save and Cancel ($label)"
            if ($case.scale -eq 1.0) {
                # The switching text must fit its label (informational for the older labels: printed, not asserted).
                $flags = [Windows.Forms.TextFormatFlags]::WordBreak -bor [Windows.Forms.TextFormatFlags]::NoPadding
                $needed = [Windows.Forms.TextRenderer]::MeasureText([string]$built.switchHelp.Text, $built.switchHelp.Font, (New-Object Drawing.Size($built.switchHelp.Width, 0)), $flags).Height
                Check ($needed -le $built.switchHelp.Height) "the switching help text fits its label ($needed px needed, $($built.switchHelp.Height) px available)"
                foreach ($other in @($built.keyHelp, $built.startState, $built.startLast)) {
                    $otherNeeded = [Windows.Forms.TextRenderer]::MeasureText([string]$other.Text, $other.Font, (New-Object Drawing.Size($other.Width, 0)), $flags).Height
                    Write-Host "INFO: $($other.GetType().Name) at y=$($other.Top) needs $otherNeeded px of $($other.Height)"
                }
            }
            $png = Join-Path $outputFolder ('settings-dialog-' + $case.name + '.png')
            Check ((Test-Path -LiteralPath $png -PathType Leaf) -and (Get-Item -LiteralPath $png).Length -gt 1000) "the render was saved: $png"
            # The picture shows the controls, not an empty frame: inside each control's bounds the saved render has text and border
            # pixels that differ from the dialog background. The client area starts after the left border and the title bar
            # (the borders of this fixed dialog are the same width on the left, right and bottom).
            $image = New-Object Drawing.Bitmap($png)
            try {
                $offsetX = [int](($dialog.Width - $dialog.ClientSize.Width) / 2)
                $offsetY = [int]($dialog.Height - $dialog.ClientSize.Height - $offsetX)
                $background = $dialog.BackColor
                foreach ($painted in @(
                        @{ name = 'the API key box'; control = $built.keyBox },
                        @{ name = 'the start at sign-in box'; control = $built.startBox },
                        @{ name = 'the switching box'; control = $built.switchBox },
                        @{ name = 'Save'; control = $built.save })) {
                    $bounds = $painted.control.Bounds
                    $ink = 0
                    for ($y = [Math]::Max(0, $bounds.Top + $offsetY); $y -lt [Math]::Min($image.Height, $bounds.Bottom + $offsetY); $y++) {
                        for ($x = [Math]::Max(0, $bounds.Left + $offsetX); $x -lt [Math]::Min($image.Width, $bounds.Right + $offsetX); $x++) {
                            $pixel = $image.GetPixel($x, $y)
                            if (([Math]::Abs([int]$pixel.R - [int]$background.R) + [Math]::Abs([int]$pixel.G - [int]$background.G) + [Math]::Abs([int]$pixel.B - [int]$background.B)) -gt 96) { $ink++ }
                        }
                    }
                    Check ($ink -ge 40) "the render shows $($painted.name) ($label): $ink text or border pixels in its bounds"
                }
            } finally { $image.Dispose() }
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
