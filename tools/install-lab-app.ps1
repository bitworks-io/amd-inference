#requires -Version 5.1
# Private, unsigned Windows lab companion. No download, elevation, or source-policy bypass.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) { throw 'FastLLM lab setup requires 64-bit Windows PowerShell on Windows.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Open FastLLM lab setup as a standard user, not as administrator.' }

$repo = Split-Path $PSScriptRoot -Parent
$corePath = Join-Path $repo 'src/FastLlm.LabApp.ps1'
if (-not (Test-Path -LiteralPath $corePath -PathType Leaf)) { throw 'The companion package is incomplete: the lab app installer helper is missing.' }
. $corePath
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Test-FastLlmLabInstallerInput {
    param([string]$Action,[string]$ArchivePath,[string]$ExpectedSha256)
    if ($Action -notin @('Install','Repair','Rollback')) { throw 'Choose Install, Repair, or Roll back.' }
    if ($Action -eq 'Rollback') {
        if ($ArchivePath -or $ExpectedSha256) { throw 'Roll back uses the retained previous version; clear the ZIP path and SHA-256 fields.' }
        return [pscustomobject]@{ action = 'Rollback'; archivePath = $null; expectedSha256 = $null }
    }
    if (-not $ArchivePath -or -not [IO.Path]::IsPathRooted($ArchivePath) -or
        ($env:OS -eq 'Windows_NT' -and $ArchivePath -cnotmatch '^[A-Za-z]:[\\/]') -or
        [IO.Path]::GetExtension($ArchivePath) -ine '.zip') {
        throw 'Choose an existing local ZIP file. No download is performed.'
    }
    # Reuse the core's fixed-drive policy before any filesystem probe can touch UNC/device paths.
    Assert-FastLlmLabLocalWindowsPath -Path $ArchivePath
    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        throw 'Choose an existing local ZIP file. No download is performed.'
    }
    $item = Get-Item -LiteralPath $ArchivePath -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'A ZIP reparse point or shortcut is not accepted.' }
    if ($ExpectedSha256 -cnotmatch '^[0-9a-fA-F]{64}$') { throw 'Enter the exact 64-character SHA-256 obtained independently from a trusted channel.' }
    return [pscustomobject]@{
        action = $Action
        archivePath = [IO.Path]::GetFullPath($item.FullName)
        expectedSha256 = $ExpectedSha256.ToLowerInvariant()
    }
}

function Format-FastLlmLabInstallerResult {
    param($Result)
    if (-not $Result -or -not $Result.appRoot -or -not $Result.currentVersion -or
        -not $Result.shortcutPath -or $Result.publisherAuthenticated -ne $false -or
        $Result.publicReleaseApproved -ne $false) {
        throw 'Lab setup returned an incomplete or unqualified result.'
    }
    $previous = if ($Result.previousVersion) { [string]$Result.previousVersion } else { 'None retained' }
    return "Current version: $($Result.currentVersion)`r`nPrevious version: $previous`r`nApp folder: $($Result.appRoot)`r`nStart Menu shortcut: $($Result.shortcutPath)`r`nPublisher authenticated: No`r`nPublic release approved: No`r`nNo model was downloaded or started."
}

$form = New-Object Windows.Forms.Form
$form.Text = 'Bitworks FastLLM - private lab setup'
$form.Size = New-Object Drawing.Size(760,610)
$form.MinimumSize = $form.Size
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font('Segoe UI',10)
$form.BackColor = [Drawing.Color]::FromArgb(245,247,250)
function AddLabel([string]$Text,[int]$X,[int]$Y,[int]$Width,[int]$Height=28) {
    $label = New-Object Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object Drawing.Point($X,$Y)
    $label.Size = New-Object Drawing.Size($Width,$Height)
    $form.Controls.Add($label)
    return $label
}
$title = AddLabel 'Install the reviewed FastLLM lab app on this PC' 22 20 705 36
$title.Font = New-Object Drawing.Font('Segoe UI',17,[Drawing.FontStyle]::Bold)
$notice = AddLabel 'PRIVATE LAB BUILD - unsigned source; no authenticated publisher or public release approval.' 22 66 705 28
$notice.ForeColor = [Drawing.Color]::DarkRed
$note = AddLabel 'Review the source and obtain the ZIP SHA-256 from a separate trusted channel. Setup will not install drivers, accept licenses, or download models.' 22 99 705 57
$null = AddLabel 'Local reviewed source ZIP' 22 166 700
$zipBox = New-Object Windows.Forms.TextBox
$zipBox.Location = New-Object Drawing.Point(22,195)
$zipBox.Size = New-Object Drawing.Size(596,30)
$form.Controls.Add($zipBox)
$browse = New-Object Windows.Forms.Button
$browse.Text = 'Browse...'
$browse.Location = New-Object Drawing.Point(625,193)
$browse.Size = New-Object Drawing.Size(105,34)
$form.Controls.Add($browse)
$null = AddLabel 'Expected SHA-256 (64 hex characters, supplied independently)' 22 244 700
$shaBox = New-Object Windows.Forms.TextBox
$shaBox.Location = New-Object Drawing.Point(22,273)
$shaBox.Size = New-Object Drawing.Size(708,30)
$form.Controls.Add($shaBox)
$reviewed = New-Object Windows.Forms.CheckBox
$reviewed.Text = 'I reviewed this lab source and verified where the expected ZIP hash came from.'
$reviewed.Location = New-Object Drawing.Point(22,314)
$reviewed.Size = New-Object Drawing.Size(705,31)
$form.Controls.Add($reviewed)
function AddButton([string]$Text,[int]$X,[int]$Width) {
    $button = New-Object Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object Drawing.Point($X,356)
    $button.Size = New-Object Drawing.Size($Width,38)
    $form.Controls.Add($button)
    return $button
}
$installButton = AddButton 'Install' 22 155
$repairButton = AddButton 'Repair' 190 155
$rollbackButton = AddButton 'Roll back' 358 155
$closeButton = AddButton 'Close' 575 155
$status = AddLabel 'No action has been taken.' 22 410 700 30
$output = New-Object Windows.Forms.TextBox
$output.Location = New-Object Drawing.Point(22,445)
$output.Size = New-Object Drawing.Size(708,107)
$output.Multiline = $true
$output.ReadOnly = $true
$output.ScrollBars = 'Vertical'
$form.Controls.Add($output)

$browse.Add_Click({
    $dialog = New-Object Windows.Forms.OpenFileDialog
    try {
        $dialog.Title = 'Choose a reviewed local FastLLM source ZIP'
        $dialog.Filter = 'ZIP archives (*.zip)|*.zip'
        $dialog.CheckFileExists = $true
        $dialog.Multiselect = $false
        if ($dialog.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) { $zipBox.Text = $dialog.FileName }
    } finally { $dialog.Dispose() }
})

function InvokeUiAction([string]$Action) {
    try {
        $path = if ($Action -eq 'Rollback') { $null } else { $zipBox.Text.Trim() }
        $digest = if ($Action -eq 'Rollback') { $null } else { $shaBox.Text.Trim() }
        if (-not $reviewed.Checked) { throw 'Check the source/hash review box before a lab setup action.' }
        $choice = Test-FastLlmLabInstallerInput -Action $Action -ArchivePath $path -ExpectedSha256 $digest
        $details = if ($Action -eq 'Rollback') { 'Restore the previously retained version. No ZIP or hash will be used.' }
            else { "ZIP: $($choice.archivePath)`r`nExpected SHA-256: $($choice.expectedSha256)" }
        $message = "$Action FastLLM private lab app?`r`n`r`n$details`r`n`r`nThis unsigned setup has no publisher authentication. No model/prerequisite license is accepted."
        $answer = [Windows.Forms.MessageBox]::Show($form,$message,'Confirm private lab setup',
            [Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Warning,
            [Windows.Forms.MessageBoxDefaultButton]::Button2)
        if ($answer -ne [Windows.Forms.DialogResult]::Yes) { $status.Text = 'Cancelled. No action was taken.'; return }
        foreach ($button in @($installButton,$repairButton,$rollbackButton,$closeButton,$browse)) { $button.Enabled = $false }
        $status.Text = "$Action in progress. Verification is bounded; this window may briefly stop responding."
        $output.Text = ''
        $form.UseWaitCursor = $true
        $form.Refresh()
        $result = if ($Action -eq 'Rollback') { Invoke-FastLlmLabApp -Action Rollback }
            else { Invoke-FastLlmLabApp -Action $Action -ArchivePath $choice.archivePath -ExpectedSha256 $choice.expectedSha256 }
        $output.Text = Format-FastLlmLabInstallerResult $result
        $status.Text = "$Action completed. The app was not started automatically."
        $reviewed.Checked = $false
    } catch {
        $status.Text = "$Action could not be confirmed. Review the error below; no success was claimed."
        $output.Text = [string]$_.Exception.Message
    } finally {
        $form.UseWaitCursor = $false
        foreach ($button in @($installButton,$repairButton,$rollbackButton,$closeButton,$browse)) { $button.Enabled = $true }
    }
}
$installButton.Add_Click({ InvokeUiAction 'Install' })
$repairButton.Add_Click({ InvokeUiAction 'Repair' })
$rollbackButton.Add_Click({ InvokeUiAction 'Rollback' })
$closeButton.Add_Click({ $form.Close() })
[Windows.Forms.Application]::Run($form)
