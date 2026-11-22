#requires -Version 5.1
# The form adapter for the fluent window. In fluent mode the window script's $form is rebound to the object this file returns.
# It is a System.Windows.Forms.NativeWindow that has taken over the WPF window's hwnd, so it is an IWin32Window: ShowDialog($form)
# and MessageBox.Show($form, ...) work unchanged (proven in PR 2a). No WPF or WinForms type is resolved at dot-source time, only inside function bodies.
Set-StrictMode -Version 2.0

function ConvertTo-FastLlmUiWpfWindowState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Value)
    switch ([string] $Value) {
        'Normal' { return [System.Windows.WindowState]::Normal }
        'Minimized' { return [System.Windows.WindowState]::Minimized }
        'Maximized' { return [System.Windows.WindowState]::Maximized }
        default { throw ('Unsupported WindowState: ' + [string] $Value) }
    }
}

function ConvertTo-FastLlmUiFormWindowState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Value)
    switch ([string] $Value) {
        'Normal' { return [System.Windows.Forms.FormWindowState]::Normal }
        'Minimized' { return [System.Windows.Forms.FormWindowState]::Minimized }
        'Maximized' { return [System.Windows.Forms.FormWindowState]::Maximized }
        default { throw ('Unsupported WindowState: ' + [string] $Value) }
    }
}

function New-FastLlmUiFormAdapter {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Window)

    Add-Type -AssemblyName System.Windows.Forms, System.Drawing, PresentationFramework, PresentationCore, WindowsBase
    $native = New-Object System.Windows.Forms.NativeWindow
    $native.AssignHandle([System.Windows.Interop.WindowInteropHelper]::new($Window).EnsureHandle())

    # Captured scriptblocks: a closure runs in its own module scope and cannot see this file's functions.
    $toForm = ${function:ConvertTo-FastLlmUiFormWindowState}
    $toWpf = ${function:ConvertTo-FastLlmUiWpfWindowState}
    $state = @{ Shown = (New-Object System.Collections.ArrayList); FormClosing = (New-Object System.Collections.ArrayList); ShownDone = $false; Closing = $false; Window = $Window; Form = $native }

    # Same font as the classic form (fast-llm-ui.ps1 line 51). The title is not set here; the Text member maps to Window.Title.
    $font = New-Object System.Drawing.Font('Segoe UI', 10)
    $controls = [pscustomobject] @{}
    $controls | Add-Member -MemberType ScriptMethod -Name Add -Value { param($c) }

    # Closing is hooked once. The handler-running code is Invoke-FastLlmUiFormClosing (also called by the session-end hook with WindowsShutDown).
    # It is captured as a scriptblock because a closure runs in its own module scope and cannot see this file's functions.
    $invokeClosing = ${function:Invoke-FastLlmUiFormClosing}
    $closing = {
        param($sender, $e)
        $cancel = [bool] (@(& $invokeClosing -Form $state.Form -CloseReason ([System.Windows.Forms.CloseReason]::UserClosing)) | Select-Object -Last 1)
        if ($cancel) { $e.Cancel = $true }
    }.GetNewClosure()
    $Window.add_Closing($closing)

    # Shown runs once, on the first ContentRendered.
    $rendered = {
        param($sender, $e)
        if ($state.ShownDone) { return }
        $state.ShownDone = $true
        foreach ($h in @($state.Shown)) { & $h $state.Form $e }
    }.GetNewClosure()
    $Window.add_ContentRendered($rendered)

    $native | Add-Member -MemberType NoteProperty -Name FastLlmFormState -Value $state
    $native | Add-Member -MemberType ScriptProperty -Name Text -Value ({ [string] $Window.Title }.GetNewClosure()) -SecondValue ({ param($v) $Window.Title = [string] $v }.GetNewClosure())
    $native | Add-Member -MemberType ScriptProperty -Name Visible -Value ({ [bool] $Window.IsVisible }.GetNewClosure())
    $native | Add-Member -MemberType NoteProperty -Name Font -Value $font
    $native | Add-Member -MemberType ScriptProperty -Name WindowState -Value ({ & $toForm $Window.WindowState }.GetNewClosure()) -SecondValue ({ param($v) $Window.WindowState = & $toWpf $v }.GetNewClosure())
    # WPF forbids Show() and Close() while a Window is closing (InvalidOperationException), so both do nothing during the FormClosing handlers:
    # RevealUiForAction, ExitFromTray or a timer path can run while a guard's MessageBox is open.
    $native | Add-Member -MemberType ScriptMethod -Name Hide -Value ({ $Window.Hide() }.GetNewClosure())
    $native | Add-Member -MemberType ScriptMethod -Name Show -Value ({ if ($state['Closing']) { return }; $Window.Show() }.GetNewClosure())
    $native | Add-Member -MemberType ScriptMethod -Name Activate -Value ({ [void] $Window.Activate() }.GetNewClosure())
    $native | Add-Member -MemberType ScriptMethod -Name Close -Value ({ if ($state['Closing']) { return }; $Window.Close() }.GetNewClosure())
    $native | Add-Member -MemberType ScriptMethod -Name Dispose -Value ({ if ($this.Handle -ne [IntPtr]::Zero) { $this.ReleaseHandle() } })
    $native | Add-Member -MemberType ScriptMethod -Name Add_Shown -Value ({ param($handler) [void] $state.Shown.Add($handler) }.GetNewClosure())
    $native | Add-Member -MemberType ScriptMethod -Name Add_FormClosing -Value ({ param($handler) [void] $state.FormClosing.Add($handler) }.GetNewClosure())
    $native | Add-Member -MemberType NoteProperty -Name Controls -Value $controls
    # Stored, never applied: the XAML window owns its size, start position and colours.
    foreach ($name in 'Size', 'MinimumSize', 'StartPosition', 'BackColor') { $native | Add-Member -MemberType NoteProperty -Name $name -Value $null }
    return $native
}

# Contract: the function returns exactly ONE [bool] (handler output is discarded), so callers (the Closing closure, the session-end hook) can use it in an if.
# Runs every FormClosing handler in order as ( $form, FormClosingEventArgs ). Returns $true when the close is cancelled.
# A throwing handler cancels the close (the guards fail safe) and the exception is re-raised on the dispatcher with BeginInvoke,
# because an exception thrown inside a WPF event handler would otherwise be lost; this keeps it visible.
function Invoke-FastLlmUiFormClosing {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Form,
        [Parameter(Mandatory = $true)] $CloseReason
    )
    $state = $Form.FastLlmFormState
    $fcArgs = New-Object System.Windows.Forms.FormClosingEventArgs($CloseReason, $false)
    $prev = $state['Closing']
    $state['Closing'] = $true
    try {
        foreach ($h in @($state.FormClosing)) { $null = & $h $Form $fcArgs }
    }
    catch {
        $ex = $_
        $rethrow = { throw $ex }.GetNewClosure()
        [void] $state.Window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Normal, [Action] $rethrow)
        return $true
    }
    finally { $state['Closing'] = $prev }
    return [bool] $fcArgs.Cancel
}

# For tests only: the handler lists the adapter collected.
function Get-FastLlmUiFormAdapterHandlers {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Form)
    return @{ Shown = @($Form.FastLlmFormState.Shown); FormClosing = @($Form.FastLlmFormState.FormClosing) }
}
