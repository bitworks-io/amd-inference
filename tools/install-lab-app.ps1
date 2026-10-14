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
function Assert-FastLlmLabCompanionLocation {
    param([string]$SourceRoot)
    $full = [IO.Path]::GetFullPath($SourceRoot).TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar))
    $parentName = [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($full))
    if ($parentName -ieq 'versions') {
        throw 'Run the reviewed external setup companion, not the copy inside an installed app version. This window must not repair, move or restore its own source.'
    }
}
$null = Assert-FastLlmLabCompanionLocation -SourceRoot (Assert-FastLlmLabAppPath $repo)
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

function Format-FastLlmLabRemovalPreview {
    param($Preview)
    if (-not $Preview -or $Preview.ready -isnot [bool]) { throw 'The removal preview is incomplete.' }
    if (-not $Preview.ready) {
        if ($Preview.reason -isnot [string] -or [string]::IsNullOrWhiteSpace($Preview.reason) -or
            $Preview.reason.Length -gt 4096) { throw 'The refused preview lacks a bounded reason.' }
        return "Uninstall is unavailable: $($Preview.reason)`r`nNo files were moved."
    }
    if ($Preview.digest -cnotmatch '^[0-9a-f]{64}$' -or @($Preview.items).Count -lt 1 -or
        @($Preview.items).Count -gt 2048) { throw 'The removal preview lacks its exact reviewed item set.' }
    foreach ($item in @($Preview.items)) {
        if ($item -isnot [string] -or $item.Length -lt 1 -or $item.Length -gt 1024 -or
            $item -match '[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]') { throw 'The removal preview contains an unsafe display item.' }
    }
    return "Verified app items to move into recoverable quarantine: $(@($Preview.items).Count)`r`nPreview SHA-256: $($Preview.digest)`r`n`r`n$(@($Preview.items) -join "`r`n")`r`n`r`nModel caches, consent receipts and benchmark reports stay in place. Automatic busy detection covers the managed control window and main CLI only. Close separately launched developer tools yourself; run experiments from a separate reviewed checkout."
}

function Test-FastLlmLabRestoreInput {
    param([string]$QuarantinePath)
    if ([string]::IsNullOrWhiteSpace($QuarantinePath) -or -not [IO.Path]::IsPathRooted($QuarantinePath) -or
        ($env:OS -eq 'Windows_NT' -and $QuarantinePath -cnotmatch '^[A-Za-z]:[\\/]')) {
        throw 'Choose the exact local quarantine folder recorded by a previous uninstall.'
    }
    Assert-FastLlmLabLocalWindowsPath -Path $QuarantinePath
    # The fixed-path core additionally checks ownership, journal, contents and destinations.
    return [IO.Path]::GetFullPath($QuarantinePath)
}

function Format-FastLlmLabRemovalResult {
    param($Result,[ValidateSet('Uninstall','Restore')][string]$Action)
    if (-not $Result -or $Result.modelCacheUntouched -isnot [bool] -or $Result.modelCacheUntouched -ne $true -or
        $Result.publicReleaseApproved -isnot [bool] -or $Result.publicReleaseApproved -ne $false) {
        throw 'The lifecycle operation returned an incomplete result; success is not confirmed.'
    }
    if ($Action -eq 'Uninstall') {
        if (-not $Result.quarantinePath) { throw 'Uninstall did not report a recoverable quarantine path.' }
        return "App files moved to recoverable quarantine:`r`n$($Result.quarantinePath)`r`n`r`nKeep this folder for Restore. Model caches, consent receipts and benchmark reports were not removed. No public release is approved."
    }
    if (-not $Result.appRoot) { throw 'Restore did not report the restored application folder.' }
    return "App files restored to:`r`n$($Result.appRoot)`r`n`r`nThe app was not started. Model caches, consent receipts and benchmark reports were not changed. No public release is approved."
}

function Get-FastLlmLabOpenPlan {
    param([string]$AppRoot,[string]$ShortcutPath)
    # The core plan verifies owner/state/ledger agreement, all retained source
    # manifests, and the exact owned shortcut bytes and current-version target.
    $owned = Get-FastLlmLabAppRemovalPlan -AppRoot $AppRoot -ShortcutPath $ShortcutPath
    $state = Get-FastLlmLabAppState $AppRoot
    if (-not $state -or $owned.appRoot -cne $AppRoot -or $owned.shortcutPath -cne $ShortcutPath -or
        $owned.installId -cne $state.installId -or
        @($owned.versions | Where-Object { $_.version -ceq $state.currentVersion -and
            $_.manifestSha256 -ceq $state.currentManifestSha256 }).Count -ne 1) {
        throw 'The current installed version is not bound to the owned app and shortcut ledger.'
    }
    $versionRoot = Assert-FastLlmLabAppPath (Join-Path (Join-Path $AppRoot 'versions') $state.currentVersion)
    $target = Assert-FastLlmLabAppPath (Join-Path $versionRoot 'FastLLM.cmd')
    return [pscustomobject]@{ appRoot=$AppRoot; version=$state.currentVersion; versionRoot=$versionRoot; target=$target }
}

function Start-FastLlmLabGuardedCommand {
    param([IO.FileStream]$Lease,[string]$Target,[string]$WorkingDirectory)
    if ($env:OS -cne 'Windows_NT' -or -not $Lease -or -not $Target -or -not $WorkingDirectory) {
        throw 'The managed application launch requires a verified Windows target and lifetime lease.'
    }
    if (-not ('FastLlmLabLeaseNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
public static class FastLlmLabLeaseNative {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfo {
        public uint cb;
        public string reserved;
        public string desktop;
        public string title;
        public uint x, y, xSize, ySize, xCountChars, yCountChars, fillAttribute, flags;
        public ushort showWindow, reserved2;
        public IntPtr reservedBytes, stdInput, stdOutput, stdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInfo {
        public IntPtr process, thread;
        public uint processId, threadId;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateProcessW(string application, StringBuilder commandLine,
        IntPtr processAttributes, IntPtr threadAttributes, [MarshalAs(UnmanagedType.Bool)] bool inheritHandles,
        uint creationFlags, IntPtr environment, string currentDirectory, ref StartupInfo startup,
        out ProcessInfo process);
    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DuplicateHandle(IntPtr sourceProcess, IntPtr sourceHandle,
        IntPtr targetProcess, out IntPtr targetHandle, uint desiredAccess,
        [MarshalAs(UnmanagedType.Bool)] bool inheritHandle, uint options);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool TerminateProcess(IntPtr process, uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);

    public static uint Launch(string target, string workingDirectory, IntPtr leaseHandle) {
        // Percent and command-control characters are not allowed in the
        // cmd.exe command line. Quoted spaces and ampersands remain supported.
        if (String.IsNullOrEmpty(target) || target.IndexOfAny(new char[] {'"','%','!','^','\r','\n'}) >= 0 ||
            target.Length > 16000 || String.IsNullOrEmpty(workingDirectory))
            throw new ArgumentException("The managed app path cannot be safely passed to the Windows command launcher.");
        string cmd = Path.Combine(Environment.SystemDirectory, "cmd.exe");
        string text = "\"" + cmd + "\" /d /v:off /s /c \"\"" + target + "\"\"";
        var line = new StringBuilder(text, text.Length + 1);
        var start = new StartupInfo();
        start.cb = (uint)Marshal.SizeOf(typeof(StartupInfo));
        ProcessInfo child;
        // Create the command process suspended in a separate console. It
        // cannot start PowerShell until the exact lease has been copied.
        if (!CreateProcessW(cmd, line, IntPtr.Zero, IntPtr.Zero, false,
            0x00000004u | 0x00000010u, IntPtr.Zero, workingDirectory, ref start, out child))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not create the guarded FastLLM command process.");
        bool resumed = false;
        try {
            IntPtr copied;
            if (!DuplicateHandle(GetCurrentProcess(), leaseHandle, child.process, out copied, 0u, false, 0x00000002u))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not give the FastLLM command process its lifetime lease.");
            if (ResumeThread(child.thread) == UInt32.MaxValue)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not resume the guarded FastLLM command process.");
            resumed = true;
            return child.processId;
        } finally {
            if (!resumed) {
                // Before ResumeThread this process has had no opportunity to
                // launch a PowerShell descendant. The copied lease, if any,
                // stays in it until termination or process teardown.
                TerminateProcess(child.process, 1u);
                WaitForSingleObject(child.process, 5000u);
            }
            CloseHandle(child.thread);
            CloseHandle(child.process);
        }
    }
}
'@
    }
    return [FastLlmLabLeaseNative]::Launch($Target,$WorkingDirectory,$Lease.SafeFileHandle.DangerousGetHandle())
}

function Invoke-FastLlmLabOpenForUser {
    $paths = Get-FastLlmLabAppUserPaths
    $app = Assert-FastLlmLabAppPath $paths.appRoot
    $shortcut = Assert-FastLlmLabAppPath $paths.shortcutPath
    if ($env:OS -ceq 'Windows_NT') {
        Assert-FastLlmLabLocalWindowsPath $app
        Assert-FastLlmLabLocalWindowsPath $shortcut
    }
    # Do not create an app root merely because Open was clicked before Install.
    $operation = [IO.File]::Open((Assert-FastLlmLabAppPath (Join-Path $app 'lab-app.lock')),
        [IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $lifetime = $null
    try {
        $plan = Get-FastLlmLabOpenPlan -AppRoot $app -ShortcutPath $shortcut
        $lifetime = Enter-FastLlmLabAppLifetime -SourceRoot $plan.versionRoot
        if (-not $lifetime) { throw 'The managed application lifetime lease was not acquired.' }
        # The verified .cmd target starts only after it owns a duplicate of the
        # exact lease. The child UI then obtains its own checked lease on entry.
        $launchedProcessId = Start-FastLlmLabGuardedCommand -Lease $lifetime -Target $plan.target -WorkingDirectory $plan.versionRoot
        return [pscustomobject]@{ version=$plan.version; target=$plan.target; processId=$launchedProcessId }
    } finally {
        if ($lifetime) { $lifetime.Dispose() }
        $operation.Dispose()
    }
}

$form = New-Object Windows.Forms.Form
$form.Text = 'Bitworks FastLLM - private lab setup'
$form.Size = New-Object Drawing.Size(760,780)
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
$installButton = AddButton 'Install' 22 137
$repairButton = AddButton 'Repair' 171 137
$rollbackButton = AddButton 'Roll back' 320 137
$openButton = AddButton 'Open FastLLM' 469 150
$closeButton = AddButton 'Close' 631 99
$previewButton = AddButton 'Preview uninstall' 22 220
$previewButton.Location = New-Object Drawing.Point(22,405)
$removeButton = AddButton 'Uninstall app' 260 220
$removeButton.Location = New-Object Drawing.Point(260,405)
$restoreButton = AddButton 'Restore app' 500 230
$restoreButton.Location = New-Object Drawing.Point(500,405)
$status = AddLabel 'No action has been taken.' 22 454 700 30
$output = New-Object Windows.Forms.TextBox
$output.Location = New-Object Drawing.Point(22,489)
$output.Size = New-Object Drawing.Size(708,105)
$output.Multiline = $true
$output.ReadOnly = $true
$output.ScrollBars = 'Vertical'
$form.Controls.Add($output)
$null = AddLabel 'Quarantine folder (only used by Restore)' 22 606 700
$quarantineBox = New-Object Windows.Forms.TextBox
$quarantineBox.Location = New-Object Drawing.Point(22,638)
$quarantineBox.Size = New-Object Drawing.Size(596,30)
$form.Controls.Add($quarantineBox)
$quarantineBrowse = New-Object Windows.Forms.Button
$quarantineBrowse.Text = 'Browse...'
$quarantineBrowse.Location = New-Object Drawing.Point(625,636)
$quarantineBrowse.Size = New-Object Drawing.Size(105,34)
$form.Controls.Add($quarantineBrowse)
$null = AddLabel 'Uninstall preserves model caches and reports. It refuses active, modified or uncertain installations; it never force-stops a model.' 22 686 708 50

function SetInstallerBusy([bool]$Busy) {
    foreach ($button in @($installButton,$repairButton,$rollbackButton,$openButton,$closeButton,$browse,
        $previewButton,$removeButton,$restoreButton,$quarantineBrowse)) { $button.Enabled = -not $Busy }
    $quarantineBox.Enabled = -not $Busy
    $form.UseWaitCursor = $Busy
}

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
$quarantineBrowse.Add_Click({
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    try {
        $dialog.Description = 'Select the exact FastLLM quarantine folder recorded by Uninstall.'
        $dialog.ShowNewFolderButton = $false
        if ($dialog.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) { $quarantineBox.Text = $dialog.SelectedPath }
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
        SetInstallerBusy $true
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
        SetInstallerBusy $false
    }
}

function InvokeLifecycleUiAction([ValidateSet('Preview','Uninstall','Restore')][string]$Action) {
    try {
        SetInstallerBusy $true
        $status.Text = 'Checking exact app ownership and lifecycle state; this window may briefly stop responding.'
        $form.Refresh()
        if ($Action -eq 'Restore') {
            $quarantine = Test-FastLlmLabRestoreInput -QuarantinePath $quarantineBox.Text.Trim()
            $message = "Restore the recorded app from this quarantine folder?`r`n`r`n$quarantine`r`n`r`nExisting destination files will not be overwritten. The core will verify the journal and every owned item. No model is started."
        } else {
            $preview = Get-FastLlmLabAppRemovalPreviewForUser
            $output.Text = Format-FastLlmLabRemovalPreview $preview
            if (-not $preview.ready) {
                $status.Text = 'Uninstall refused. No files were moved.'
                $pending = Get-FastLlmLabAppPendingRecoveryForUser
                if ($pending) {
                    $quarantineBox.Text = [string]$pending.quarantinePath
                    $output.AppendText("`r`n`r`nA verified pending removal can be restored from:`r`n$($pending.quarantinePath)`r`nUse Restore app to recover that transaction; no recovery was started automatically.")
                }
                return
            }
            if ($Action -eq 'Preview') { $status.Text = 'Preview only. No files were moved.'; return }
            $message = "Move $(@($preview.items).Count) verified app items to recoverable quarantine?`r`n`r`nPreview SHA-256:`r`n$($preview.digest)`r`n`r`nThe full item list is in the preview. Model caches and benchmark reports stay in place. Close the app and all separately launched developer tools; those tools are not detected automatically. Nothing is permanently deleted."
        }
        $answer = [Windows.Forms.MessageBox]::Show($form,$message,'Confirm private lab lifecycle action',
            [Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Warning,
            [Windows.Forms.MessageBoxDefaultButton]::Button2)
        if ($answer -ne [Windows.Forms.DialogResult]::Yes) { $status.Text = 'Cancelled. No action was taken.'; return }
        $result = if ($Action -eq 'Restore') { Invoke-FastLlmLabAppRestore -QuarantinePath $quarantine }
            else { Invoke-FastLlmLabAppRemoval -ExpectedPreviewDigest $preview.digest }
        $output.Text = Format-FastLlmLabRemovalResult -Result $result -Action $Action
        if ($Action -eq 'Uninstall') { $quarantineBox.Text = [string]$result.quarantinePath }
        $status.Text = "$Action completed. Models and reports were kept."
    } catch {
        $status.Text = "$Action was not confirmed. Review the error; do not remove files manually."
        $output.Text = [string]$_.Exception.Message
    } finally { SetInstallerBusy $false }
}
function InvokeOpenUiAction {
    try {
        SetInstallerBusy $true
        $status.Text = 'Verifying the committed app and shortcut; this window may briefly stop responding.'
        $output.Text = ''
        $form.Refresh()
        $result = Invoke-FastLlmLabOpenForUser
        $status.Text = 'Open FastLLM was requested. The control window may take a moment to appear.'
        $output.Text = "Opened managed version: $($result.version)`r`nEntry point: $($result.target)`r`nNo model or server was started by setup. The FastLLM control window handles any later consent or start action. Keep its console open while serving."
    } catch {
        $status.Text = 'FastLLM did not open from a verified managed installation.'
        $output.Text = [string]$_.Exception.Message
    } finally { SetInstallerBusy $false }
}
$installButton.Add_Click({ InvokeUiAction 'Install' })
$repairButton.Add_Click({ InvokeUiAction 'Repair' })
$rollbackButton.Add_Click({ InvokeUiAction 'Rollback' })
$openButton.Add_Click({ InvokeOpenUiAction })
$previewButton.Add_Click({ InvokeLifecycleUiAction 'Preview' })
$removeButton.Add_Click({ InvokeLifecycleUiAction 'Uninstall' })
$restoreButton.Add_Click({ InvokeLifecycleUiAction 'Restore' })
$closeButton.Add_Click({ $form.Close() })
[Windows.Forms.Application]::Run($form)
