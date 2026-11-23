#requires -Version 5.1
# Windows-only checks of the Fluent window pieces that need a real WPF window and message loop: the form adapter (Part A),
# the app icon and window hooks (Part B1), the theme message hook (Part C). Part B (shell bindings, Home parity, render) is added later.
# One dispatcher loop is driven by a step timer; every step is a function that runs synchronously (nested pumps wait for events).
# Each check prints PASS or FAIL with a stable name; the suite ends with "N checks passed" and exits non-zero on any FAIL.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$root = Split-Path $PSScriptRoot -Parent

$onWindows = ($PSVersionTable.PSVersion.Major -le 5) -or [bool](Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue)
if (-not $onWindows) { Write-Host 'SKIP: ui-fluent-shell-tests (Windows only)'; exit 0 }

$script:pass = 0
$script:fail = 0
. (Join-Path $PSScriptRoot 'helpers/UiFluentShellHarness.ps1')

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { Write-Host 'FAIL: the suite must run on an STA thread (powershell -STA)'; exit 1 }
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
if (-not ('Bitworks.FastLlm.Tests.FluentHostNative' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'helpers/FluentHostNative.cs') -ErrorAction Stop }
if (-not ('Bitworks.FastLlm.FluentWindowNative' -as [type])) { Add-Type -Path (Join-Path $root 'src/WindowsFluentWindow.cs') -ErrorAction Stop }
$script:native = [Bitworks.FastLlm.Tests.FluentHostNative]
. (Join-Path $root 'src/FastLlm.UiFluentForm.ps1')
. (Join-Path $root 'src/FastLlm.UiFluentIcon.ps1')
. (Join-Path $root 'src/FastLlm.UiFluentHooks.ps1')

# Recorded, never shown: a throwing handler must not open a dialog that waits for a person.
$script:dispEx = New-Object System.Collections.Generic.List[string]
$script:threadEx = New-Object System.Collections.Generic.List[string]
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({ param($s, $e) $script:threadEx.Add($e.Exception.ToString()) })

$script:scns = New-Object System.Collections.Generic.List[object]   # scenarios, closed in cleanup
$script:objs = New-Object System.Collections.Generic.List[object]   # timers and icons, disposed in cleanup
$script:loopStopped = $false
$script:busy = $false
$script:si = 0
$script:fatal = $null

# A shown off-screen window with Content (ContentRendered fires only with Content) and a form adapter over it.
function New-Scn([string]$Name) {
    $w = [System.Windows.Window]::new()
    $w.Left = -32000; $w.Top = -32000; $w.Width = 400; $w.Height = 300
    $w.WindowStartupLocation = 'Manual'
    $w.ShowActivated = $false; $w.ShowInTaskbar = $false
    $w.Title = 'FastLLM shell check ' + $Name + ' ' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $w.Content = New-Object System.Windows.Controls.Border
    $form = New-FastLlmUiFormAdapter -Window $w
    $s = [pscustomobject]@{ Window = $w; Form = $form; Hwnd = [System.Windows.Interop.WindowInteropHelper]::new($w).Handle; Closed = @{ n = 0 }; Title = $w.Title }
    $closed = $s.Closed
    $w.Add_Closed(({ $closed.n++ }).GetNewClosure())
    $script:scns.Add($s)
    return $s
}

# After the shell starts, Application.ThreadException has ONE handler (the shell's replaces the suite's), so the exceptions the product recorded count too.
$script:unhandledLog = New-Object System.Collections.ArrayList
function Check-NoExceptions([string]$Name) {
    $d = @($script:dispEx.ToArray()); $t = @($script:threadEx.ToArray()); $u = @($script:unhandledLog.ToArray())
    Check (($d.Count -eq 0) -and ($t.Count -eq 0) -and ($u.Count -eq 0)) "$Name : no dispatcher or WinForms exception recorded" ("dispatcher=" + ($d -join ' | ') + " winforms=" + ($t -join ' | ') + " shell=" + ($u -join ' | '))
    $script:dispEx.Clear(); $script:threadEx.Clear(); $script:unhandledLog.Clear()
}

# A WinForms form shown modally over $Owner; its own timer reads the owner of the form and the WPF window state while it is up.
function Invoke-DialogProbe([object]$Owner, [IntPtr]$Hwnd) {
    $st = @{ opened = $false; during = $null; owner = [long]0; timedOut = $false; after = $null }
    $nat = $script:native
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'FastLLM shell dialog ' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $f.StartPosition = 'Manual'; $f.ShowInTaskbar = $false
    $f.Location = New-Object System.Drawing.Point(-32000, -32000)
    $f.Size = New-Object System.Drawing.Size(200, 100)
    $t = New-Object System.Windows.Forms.Timer; $t.Interval = 200
    $d = New-Object System.Windows.Forms.Timer; $d.Interval = 6000
    $t.Add_Tick(({ $t.Stop(); $st.during = $nat::IsWindowEnabled($Hwnd); $st.owner = $nat::GetOwner($f.Handle).ToInt64(); $f.Close() }).GetNewClosure())
    $d.Add_Tick(({ $d.Stop(); $st.timedOut = $true; $f.Close() }).GetNewClosure())
    $f.Add_Shown(({ $st.opened = $true; $t.Start() }).GetNewClosure())
    try {
        $d.Start()
        $null = $f.ShowDialog($Owner)
        $st.after = $nat::IsWindowEnabled($Hwnd)
    }
    finally { $t.Dispose(); $d.Dispose(); $f.Dispose() }
    return $st
}

function Show-Scn($Scn) { $Scn.Window.Show(); Invoke-Pump 150 }

# ======================================================================================================================
# Part A: the form adapter
# ======================================================================================================================

# File-level state and function: the real handlers in fast-llm-ui.ps1 are plain scriptblocks (no GetNewClosure) that call file-level
# functions and write $script: state. A closure cannot stand in for that, so A1 and A12 use this exact shape.
$script:shellMark = 0
$script:shellX = 0
$script:shellReason = ''
$script:shellSame = $false
$script:shellForm = $null
$script:shellCancel = $true
function Set-ShellTestMark { $script:shellMark++ }

function Invoke-A1-CloseCancelled {
    $script:shellMark = 0; $script:shellX = 0; $script:shellReason = ''; $script:shellSame = $false; $script:shellCancel = $true
    $s = New-Scn 'a1'; $form = $s.Form; $w = $s.Window
    $script:shellForm = $form
    $form.Add_FormClosing({ param($sender, $event)
        Set-ShellTestMark
        $script:shellX = 1
        $script:shellReason = [string]$event.CloseReason
        $script:shellSame = [object]::ReferenceEquals($sender.PSObject.BaseObject, $script:shellForm.PSObject.BaseObject)
        $event.Cancel = $true })
    Show-Scn $s
    $form.Close()
    Invoke-Pump 150
    Check ($script:shellMark -eq 1 -and $script:shellX -eq 1) 'A1 a cancelled close runs the plain-scriptblock FormClosing handler once (file-level function and $script: state)' "mark=$($script:shellMark) x=$($script:shellX) expected mark=1 x=1"
    Check ($script:shellReason -eq 'UserClosing') 'A1 a cancelled close reports CloseReason UserClosing' "actual=$($script:shellReason) expected=UserClosing"
    Check $script:shellSame 'A1 the handler sender is the form adapter' 'sender.PSObject.BaseObject was not form.PSObject.BaseObject'
    Check ($w.IsVisible -and $s.Closed.n -eq 0) 'A1 a cancelled close leaves the window open' "IsVisible=$($w.IsVisible) closedEvents=$($s.Closed.n)"
    Check-NoExceptions 'A1'
}

function Invoke-A1c-CloseCancelledClosure {
    $s = New-Scn 'a1c'; $form = $s.Form; $w = $s.Window
    $st = @{ n = 0; reason = ''; same = $false }
    $form.Add_FormClosing(({ param($sender, $event)
        $st.n++; $st.reason = [string]$event.CloseReason
        $st.same = [object]::ReferenceEquals($sender.PSObject.BaseObject, $form.PSObject.BaseObject)
        $st.x = 1
        $event.Cancel = $true }).GetNewClosure())
    Show-Scn $s
    $form.Close()
    Invoke-Pump 150
    Check ($st.n -eq 1 -and $st.x -eq 1) 'A1c closure variant: a cancelled close runs the FormClosing handler once' "n=$($st.n) x=$($st.x) expected n=1 x=1"
    Check ($st.reason -eq 'UserClosing') 'A1c closure variant: a cancelled close reports CloseReason UserClosing' "actual=$($st.reason) expected=UserClosing"
    Check $st.same 'A1c closure variant: the handler sender is the form adapter' 'sender.PSObject.BaseObject was not form.PSObject.BaseObject'
    Check ($w.IsVisible -and $s.Closed.n -eq 0) 'A1c closure variant: a cancelled close leaves the window open' "IsVisible=$($w.IsVisible) closedEvents=$($s.Closed.n)"
    Check-NoExceptions 'A1c'
}

function Invoke-A2-CloseAllowed {
    $s = New-Scn 'a2'; $form = $s.Form
    Show-Scn $s
    $form.Close()
    Invoke-Pump 150 ({ $s.Closed.n -ge 1 }).GetNewClosure()
    Check ($s.Closed.n -eq 1) 'A2 an allowed close fires Closed' "closedEvents=$($s.Closed.n) expected=1"
    Check ($form.Handle -eq [IntPtr]::Zero) 'A2 the adapter handle is zero after the close' "Handle=$($form.Handle)"
    $threw = ''
    try { $form.Dispose(); $form.Dispose(); [GC]::Collect(); [GC]::WaitForPendingFinalizers() } catch { $threw = $_.Exception.Message }
    Check ($threw -eq '') 'A2 Dispose twice then a full GC never throws' $threw
    Check-NoExceptions 'A2'
}

function Invoke-A3-BoxNo {
    $s = New-Scn 'a3'; $form = $s.Form; $w = $s.Window
    $cap = 'FastLLM shell guard A3 ' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $st = @{ answer = '' }
    $form.Add_FormClosing(({ param($sender, $event)
        $r = [System.Windows.Forms.MessageBox]::Show($form, 'Close?', $cap, 'YesNo', 'Question')
        $st.answer = [string]$r
        if ($r -ne 'Yes') { $event.Cancel = $true } }).GetNewClosure())
    Show-Scn $s
    $box = @{}
    $t = Start-BoxAnswer $cap 7 $s.Hwnd $box
    try { $form.Close() } finally { $t.Stop() }
    Invoke-Pump 100
    Check ($box.found -and -not $box.timedOut -and -not $box.hardStop) 'A3 the guard message box appeared and closed within 6 s' "found=$($box.found) timedOut=$($box.timedOut) hardStop=$($box.hardStop) lastRung=$($box.rung)"
    Check ($box.owner -eq $s.Hwnd.ToInt64()) 'A3 the guard box is owned by the WPF window handle' "GW_OWNER=$($box.owner) expected=$($s.Hwnd.ToInt64())"
    Check ($box.during -eq $false) 'A3 the WPF window is disabled while the guard box is up' "IsWindowEnabled during=$($box.during) expected=False"
    Check ($st.answer -eq 'No') 'A3 the box was answered No' "answer=$($st.answer)"
    Check ($w.IsVisible -and $s.Closed.n -eq 0 -and $script:native::IsWindowEnabled($s.Hwnd)) 'A3 after No the window is open and enabled' "IsVisible=$($w.IsVisible) closed=$($s.Closed.n) enabled=$($script:native::IsWindowEnabled($s.Hwnd))"
    $form.FastLlmFormState.FormClosing.Clear()
    $form.Close()
    Invoke-Pump 150 ({ $s.Closed.n -ge 1 }).GetNewClosure()
    Check ($s.Closed.n -eq 1) 'A3 a later close with no cancelling handler closes the window' "closedEvents=$($s.Closed.n)"
    Check-NoExceptions 'A3'
}

function Invoke-A4-BoxYes {
    $s = New-Scn 'a4'; $form = $s.Form
    $cap = 'FastLLM shell guard A4 ' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $st = @{ answer = '' }
    $form.Add_FormClosing(({ param($sender, $event)
        $r = [System.Windows.Forms.MessageBox]::Show($form, 'Close?', $cap, 'YesNo', 'Question')
        $st.answer = [string]$r
        if ($r -ne 'Yes') { $event.Cancel = $true } }).GetNewClosure())
    Show-Scn $s
    $box = @{}
    $t = Start-BoxAnswer $cap 6 $s.Hwnd $box
    try { $form.Close() } finally { $t.Stop() }
    Invoke-Pump 150 ({ $s.Closed.n -ge 1 }).GetNewClosure()
    Check ($box.found -and $st.answer -eq 'Yes') 'A4 the same box answered Yes' "found=$($box.found) answer=$($st.answer)"
    Check ($s.Closed.n -eq 1) 'A4 the close goes ahead after Yes' "closedEvents=$($s.Closed.n) expected=1"
    Check-NoExceptions 'A4'
}

function Invoke-A5-CloseInsideHandler {
    $s = New-Scn 'a5'; $form = $s.Form
    $st = @{ n = 0; threw = $false; msg = '' }
    $form.Add_FormClosing(({ param($sender, $event)
        $st.n++
        try { $form.Close() } catch { $st.threw = $true; $st.msg = $_.Exception.Message } }).GetNewClosure())
    Show-Scn $s
    $form.Close()
    Invoke-Pump 200 ({ $s.Closed.n -ge 1 }).GetNewClosure()
    Check (-not $st.threw) 'A5 Close() inside a FormClosing handler does not throw' $st.msg
    Check ($st.n -eq 1) 'A5 the handler ran once' "n=$($st.n) expected=1"
    Check ($s.Closed.n -eq 1) 'A5 the window closed' "closedEvents=$($s.Closed.n)"
    Check-NoExceptions 'A5'
}

function Invoke-A6-ThrowingHandler {
    $s = New-Scn 'a6'; $form = $s.Form; $w = $s.Window
    $st = @{ h2 = 0 }
    $form.Add_FormClosing(({ param($sender, $event) throw 'guard failed' }).GetNewClosure())
    $form.Add_FormClosing(({ param($sender, $event) $st.h2++ }).GetNewClosure())
    Show-Scn $s
    $de = $script:dispEx
    $form.Close()
    Invoke-Pump 400 ({ $de.Count -ge 1 }).GetNewClosure()
    Invoke-Pump 150
    Check ($w.IsVisible -and $s.Closed.n -eq 0) 'A6 a throwing guard keeps the window open' "IsVisible=$($w.IsVisible) closed=$($s.Closed.n)"
    Check ($st.h2 -eq 0) 'A6 the handler after a throwing one does not run' "h2 ran $($st.h2) times"
    $msgs = @($script:dispEx.ToArray())
    Check ($msgs.Count -eq 1 -and ($msgs -join ' ') -match 'guard failed') 'A6 exactly one dispatcher exception carries the guard message' "count=$($msgs.Count) text=$($msgs -join ' | ')"
    $script:dispEx.Clear()
    Check-NoExceptions 'A6'
}

function Invoke-A7-Visible {
    $s = New-Scn 'a7'; $form = $s.Form
    $form.Show(); $v1 = $form.Visible
    Check ($v1 -eq $true) 'A7 Visible reads true right after the very first Show' "Visible=$v1"
    Invoke-Pump 100
    $form.Hide(); $v2 = $form.Visible
    Check ($v2 -eq $false) 'A7 Visible reads false after Hide' "Visible=$v2"
    $form.Show(); $v3 = $form.Visible
    Check ($v3 -eq $true) 'A7 Show then Visible in the same tick reads true' "Visible=$v3"
    Check-NoExceptions 'A7'
}

function Invoke-A8-RestoreFromTray {
    $s = New-Scn 'a8'; $form = $s.Form; $w = $s.Window
    Show-Scn $s
    $w.WindowState = [System.Windows.WindowState]::Minimized
    $form.Hide()
    Invoke-Pump 100
    $form.Show()
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $form.Activate()
    Invoke-Pump 100
    Check ($w.WindowState -eq [System.Windows.WindowState]::Normal) 'A8 the RestoreFromTray sequence leaves the WPF WindowState Normal' "WindowState=$($w.WindowState)"
    $fs = $form.WindowState
    Check (($fs -is [System.Windows.Forms.FormWindowState]) -and $fs -eq [System.Windows.Forms.FormWindowState]::Normal) 'A8 the form WindowState reads a FormWindowState equal to Normal' "type=$($fs.GetType().FullName) value=$fs"
    $msg = ''
    try { $form.WindowState = 'Bogus' } catch { $msg = $_.Exception.Message }
    Check ($msg -match 'Unsupported WindowState') 'A8 an unknown WindowState throws Unsupported WindowState' "message=$msg"
    Check-NoExceptions 'A8'
}

function Invoke-A9-Shown {
    $s = New-Scn 'a9'; $form = $s.Form; $w = $s.Window
    $st = @{ n = 0; late = 0 }
    $form.Add_Shown(({ param($sender, $e) $st.n++ }).GetNewClosure())
    $w.Show()
    Invoke-Pump 1500 ({ $st.n -ge 1 }).GetNewClosure()
    $m = [System.Windows.Window].GetMethod('OnContentRendered', [System.Reflection.BindingFlags]'NonPublic,Instance')
    $second = ($null -ne $m)
    if ($second) { $null = $m.Invoke($w, @([EventArgs]::Empty)) }
    Invoke-Pump 100
    Check $second 'A9 a second ContentRendered can be raised through OnContentRendered' 'Window.OnContentRendered was not found by reflection'
    Check ($st.n -eq 1) 'A9 the Shown handler runs once after two ContentRendered events' "n=$($st.n) expected=1"
    $form.Add_Shown(({ param($sender, $e) $st.late++ }).GetNewClosure())
    if ($second) { $null = $m.Invoke($w, @([EventArgs]::Empty)) }
    Invoke-Pump 100
    Check ($st.late -eq 0) 'A9 a Shown handler added after the first Shown never runs' "late=$($st.late) expected=0"
    Check-NoExceptions 'A9'
}

function Invoke-A10-Owner {
    $s = New-Scn 'a10'; $form = $s.Form
    Show-Scn $s
    $hw = $s.Hwnd.ToInt64()
    $dlg = Invoke-DialogProbe $form $s.Hwnd
    Check ($dlg.opened -and -not $dlg.timedOut) 'A10 ShowDialog($form) opened' "opened=$($dlg.opened) timedOut=$($dlg.timedOut)"
    Check ($dlg.owner -eq $hw) 'A10 ShowDialog($form) owner is the WPF window handle' "GW_OWNER=$($dlg.owner) expected=$hw"
    Check ($dlg.during -eq $false -and $dlg.after -eq $true) 'A10 ShowDialog($form) disables the WPF window and re-enables it after' "during=$($dlg.during) after=$($dlg.after)"
    $cases = @(
        @{ tag = 'MessageBox YesNo Question'; id = 7; call = { param($cap) [System.Windows.Forms.MessageBox]::Show($form, 't', $cap, 'YesNo', 'Question') } },
        @{ tag = 'MessageBox OK Warning (owner, text, caption, buttons, icon)'; id = 1; call = { param($cap) [System.Windows.Forms.MessageBox]::Show($form, 't', $cap, 'OK', 'Warning') } },
        @{ tag = 'MessageBox OK (owner, text, caption, buttons)'; id = 1; call = { param($cap) [System.Windows.Forms.MessageBox]::Show($form, 't', $cap, 'OK') } })
    foreach ($c in $cases) {
        $cap = 'FastLLM shell owner ' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $box = @{}
        $t = Start-BoxAnswer $cap $c.id $s.Hwnd $box
        try { $null = & $c.call $cap } finally { $t.Stop() }
        Check ($box.found -and -not $box.timedOut -and -not $box.hardStop) ("A10 " + $c.tag + ' appeared and closed within 6 s') "found=$($box.found) timedOut=$($box.timedOut) hardStop=$($box.hardStop) lastRung=$($box.rung) closedBy=$($box.closedBy)"
        Check ($box.owner -eq $hw) ("A10 " + $c.tag + ' owner is the WPF window handle') "GW_OWNER=$($box.owner) expected=$hw"
    }
    Check-NoExceptions 'A10'
}

function Invoke-A11-ScreenGap {
    $s = New-Scn 'a11'; $form = $s.Form
    $msg = ''
    try { $null = [System.Windows.Forms.Screen]::FromControl($form) } catch { $msg = $_.Exception.Message }
    Check ($msg -ne '') 'A11 known gap, carried to PR 3: Screen.FromControl($form) throws on the adapter' 'FromControl returned without throwing; the gap at GetUiSettingsDialogMaxHeight may be closed, update the pin'
    Check-NoExceptions 'A11'
}

function Invoke-A12-SessionEnd {
    $s = New-Scn 'a12'; $form = $s.Form; $w = $s.Window
    $st = @{ n = 0; reason = ''; cancel = $true }
    $form.Add_FormClosing(({ param($sender, $event) $st.n++; $st.reason = [string]$event.CloseReason; if ($st.cancel) { $event.Cancel = $true } }).GetNewClosure())
    $cnt = @{ n = 0 }
    $reg = Register-FastLlmUiWindowHooks -Window $w -Form $form -OnThemeChanged ({ $cnt.n++ }).GetNewClosure()
    Show-Scn $s
    Check ($reg.hooked -eq $true) 'A12 the window hooks register for the session-end check' "hooked=$($reg.hooked) error=$($reg.error)"
    $none = [IntPtr]::Zero
    $r1 = $script:native::SendMessage($s.Hwnd, [uint32]0x0011, $none, $none).ToInt64()
    Invoke-Pump 100
    Check ($r1 -eq 0 -and $w.IsVisible -and $s.Closed.n -eq 0) 'A12 a guard cancel refuses the sign-out (WM_QUERYENDSESSION returns 0, window stays open)' "result=$r1 expected=0 IsVisible=$($w.IsVisible) closed=$($s.Closed.n)"
    Check ($st.n -eq 1 -and $st.reason -eq 'WindowsShutDown') 'A12 the session-end FormClosing runs once with CloseReason WindowsShutDown' "n=$($st.n) reason=$($st.reason)"
    Check ($form.FastLlmFormState['Closing'] -eq $false) 'A12 the Closing flag is reset after the session-end query' "Closing=$($form.FastLlmFormState['Closing'])"
    $st.cancel = $false
    $r2 = $script:native::SendMessage($s.Hwnd, [uint32]0x0011, $none, $none).ToInt64()
    Invoke-Pump 100
    Check ($r2 -ne 0 -and $st.reason -eq 'WindowsShutDown') 'A12 an allowed close proceeds (WM_QUERYENDSESSION returns non-zero)' "result=$r2 expected non-zero reason=$($st.reason)"
    Check ($w.IsVisible -and $s.Closed.n -eq 0) 'A12 WM_QUERYENDSESSION is only a query: the window is not closed' "IsVisible=$($w.IsVisible) closed=$($s.Closed.n)"
    Unregister-FastLlmUiWindowHooks -Window $w
    Check-NoExceptions 'A12'
}

function Invoke-A12b-SessionEndPlain {
    $script:shellMark = 0; $script:shellX = 0; $script:shellReason = ''; $script:shellCancel = $true
    $s = New-Scn 'a12b'; $form = $s.Form; $w = $s.Window
    $form.Add_FormClosing({ param($sender, $event)
        Set-ShellTestMark
        $script:shellX = 1
        $script:shellReason = [string]$event.CloseReason
        if ($script:shellCancel) { $event.Cancel = $true } })
    $null = Register-FastLlmUiWindowHooks -Window $w -Form $form -OnThemeChanged { }
    Show-Scn $s
    $none = [IntPtr]::Zero
    $r1 = $script:native::SendMessage($s.Hwnd, [uint32]0x0011, $none, $none).ToInt64()
    Invoke-Pump 100
    Check ($r1 -eq 0 -and $w.IsVisible -and $s.Closed.n -eq 0) 'A12b plain-scriptblock guard cancel refuses the sign-out (WM_QUERYENDSESSION returns 0, window stays open)' "result=$r1 expected=0 IsVisible=$($w.IsVisible) closed=$($s.Closed.n)"
    Check ($script:shellMark -eq 1 -and $script:shellX -eq 1 -and $script:shellReason -eq 'WindowsShutDown') 'A12b the plain handler ran once through the hook with file-level function and $script: state, CloseReason WindowsShutDown' "mark=$($script:shellMark) x=$($script:shellX) reason=$($script:shellReason)"
    $script:shellCancel = $false
    $r2 = $script:native::SendMessage($s.Hwnd, [uint32]0x0011, $none, $none).ToInt64()
    Invoke-Pump 100
    Check ($r2 -ne 0 -and $script:shellMark -eq 2) 'A12b plain-scriptblock allowed close proceeds (WM_QUERYENDSESSION returns non-zero)' "result=$r2 expected non-zero mark=$($script:shellMark) expected=2"
    Unregister-FastLlmUiWindowHooks -Window $w
    Check-NoExceptions 'A12b'
}

function Invoke-A13-Members {
    $s = New-Scn 'a13'; $form = $s.Form
    $g = ''; try { $null = & { Set-StrictMode -Version 2; $form.Nope } } catch { $g = $_.Exception.Message }
    Check ($g -ne '') 'A13 reading an unknown member throws' 'no exception'
    $p = ''; try { $form.Nope = 'x' } catch { $p = $_.Exception.Message }
    Check ($p -ne '') 'A13 writing an unknown member throws' 'no exception'
    $v = ''; try { $form.Visible = $false } catch { $v = $_.Exception.Message }
    Check ($v -ne '') 'A13 Visible is get-only: writing it throws' 'no exception'
    Check ($form.Font.Name -eq 'Segoe UI' -and [Math]::Abs($form.Font.SizeInPoints - 10) -lt 0.01) 'A13 Font is Segoe UI 10 pt' "name=$($form.Font.Name) size=$($form.Font.SizeInPoints)"
    $bold = $null; $fe = ''
    try { $bold = New-Object System.Drawing.Font -ArgumentList @($form.Font.PSObject.BaseObject, [System.Drawing.FontStyle]::Bold); $script:objs.Add($bold) } catch { $fe = $_.Exception.Message }
    Check ($null -ne $bold -and $bold.Bold) 'A13 a bold Font can be made from the adapter Font' $fe
    $ce = ''; try { $form.Controls.Add((New-Object System.Windows.Forms.Label)) } catch { $ce = $_.Exception.Message }
    Check ($ce -eq '') 'A13 Controls.Add does not throw' $ce
    $form.Size = New-Object System.Drawing.Size(640, 480)
    $form.MinimumSize = New-Object System.Drawing.Size(320, 240)
    $form.StartPosition = 'CenterScreen'
    $form.BackColor = [System.Drawing.Color]::FromArgb(12, 34, 56)
    Check ($form.Size.Width -eq 640 -and $form.Size.Height -eq 480) 'A13 Size reads back what was set' "size=$($form.Size)"
    Check ($form.MinimumSize.Width -eq 320 -and $form.MinimumSize.Height -eq 240) 'A13 MinimumSize reads back what was set' "size=$($form.MinimumSize)"
    Check ([string]$form.StartPosition -eq 'CenterScreen') 'A13 StartPosition reads back what was set' "value=$($form.StartPosition)"
    Check ($form.BackColor.R -eq 12 -and $form.BackColor.G -eq 34 -and $form.BackColor.B -eq 56) 'A13 BackColor reads back what was set' "value=$($form.BackColor)"
    Check-NoExceptions 'A13'
}

function Invoke-A14-LeakyHandler {
    $s = New-Scn 'a14'; $form = $s.Form
    $form.Add_FormClosing(({ param($sender, $event) 1; 'x' }).GetNewClosure())
    Show-Scn $s
    $r = @(Invoke-FastLlmUiFormClosing -Form $form -CloseReason ([System.Windows.Forms.CloseReason]::UserClosing))
    Check ($r.Count -eq 1 -and $r[0] -is [bool] -and $r[0] -eq $false) 'A14 a leaky non-cancelling handler returns a single false' "count=$($r.Count) values=$(($r | ForEach-Object { [string]$_ }) -join ',')"
    $form.Close()
    Invoke-Pump 150 ({ $s.Closed.n -ge 1 }).GetNewClosure()
    Check ($s.Closed.n -eq 1) 'A14 the window closes after a leaky non-cancelling handler' "closedEvents=$($s.Closed.n)"
    Check-NoExceptions 'A14'
}

# ======================================================================================================================
# Part B1: icon and hooks (the pieces that need no shell)
# ======================================================================================================================

function Invoke-B1-GdiLeak {
    $nat = $script:native
    foreach ($z in 16, 20, 24, 32, 48) { $i = New-FastLlmUiTrayIcon -Size $z; $i.Dispose() }
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    $before = $nat::GetGdiObjectCount()
    for ($n = 0; $n -lt 50; $n++) {
        $z = (16, 20, 24, 32, 48)[$n % 5]
        $i = New-FastLlmUiTrayIcon -Size $z
        $i.Dispose()
    }
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    $after = $nat::GetGdiObjectCount()
    Check ($before -ge 0 -and $after -ge 0 -and ($after - $before) -le 2) 'B1 icon GDI: 50 create and dispose cycles leak at most 2 GDI objects' "before=$before after=$after delta=$($after - $before)"
}

function Invoke-B2-IconSizes {
    foreach ($z in 16, 20, 24, 32) {
        $i = New-FastLlmUiTrayIcon -Size $z
        try { Check ($i.Width -eq $z -and $i.Height -eq $z) "B2 tray icon size $z has that width and height" "width=$($i.Width) height=$($i.Height) expected=$z" }
        finally { $i.Dispose() }
    }
    Clear-FastLlmUiFluentTrayIcon
    $a = Get-FastLlmUiFluentTrayIcon
    $small = [System.Windows.Forms.SystemInformation]::SmallIconSize.Width
    Check ($a.Width -eq $small) 'B2 the cached tray icon width equals SmallIconSize' "width=$($a.Width) SmallIconSize=$small"
    $b = Get-FastLlmUiFluentTrayIcon
    Check ([object]::ReferenceEquals($a, $b)) 'B2 the tray icon is cached between calls' 'two calls returned different objects'
    Clear-FastLlmUiFluentTrayIcon
    $c = Get-FastLlmUiFluentTrayIcon
    Check (-not [object]::ReferenceEquals($a, $c)) 'B2 Clear then Get returns a new icon object' 'the same object came back after Clear'
    Clear-FastLlmUiFluentTrayIcon
}

function Invoke-B3-AppIcon {
    $img = New-FastLlmUiAppIconImage
    Check $img.IsFrozen 'B3 the app icon image is frozen' 'IsFrozen=False'
    $w = [System.Windows.Window]::new()
    $threw = ''
    try { $w.Icon = $img } catch { $threw = $_.Exception.Message }
    Check ($threw -eq '' -and $null -ne $w.Icon) 'B3 the app icon image is usable as Window.Icon' $threw
    $dv = New-Object System.Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen()
    $dc.DrawImage($img, (New-Object System.Windows.Rect(0, 0, 64, 64)))
    $dc.Close()
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(64, 64, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($dv)
    $px = New-Object 'byte[]' (64 * 64 * 4)
    $rtb.CopyPixels($px, 256, 0)
    $get = { param($x, $y) $o = ($y * 256) + ($x * 4); @([int]$px[$o + 2], [int]$px[$o + 1], [int]$px[$o], [int]$px[$o + 3]) }   # R G B A
    $inset = & $get 8 8
    Check ([Math]::Abs($inset[0] - 0x00) -le 4 -and [Math]::Abs($inset[1] - 0x5F) -le 4 -and [Math]::Abs($inset[2] - 0xB8) -le 4 -and $inset[3] -ge 250) 'B3 the accent fills the corner inset' "RGBA at (8,8)=$($inset -join ',') expected about 0,95,184,255"
    $chev = & $get 40 32
    Check ($chev[0] -ge 240 -and $chev[1] -ge 240 -and $chev[2] -ge 240 -and $chev[3] -ge 250) 'B3 the white chevron is drawn at its apex' "RGBA at (40,32)=$($chev -join ',') expected about 255,255,255,255"
    $corner = & $get 0 0
    Check ($corner[3] -lt 60) 'B3 the outer corner is transparent (rounded square)' "alpha at (0,0)=$($corner[3]) expected below 60"
}

function Invoke-B4-ThemeHook {
    $s = New-Scn 'b4'; $form = $s.Form; $w = $s.Window
    $cnt = @{ n = 0 }
    $reg = Register-FastLlmUiWindowHooks -Window $w -Form $form -OnThemeChanged ({ $cnt.n++ }).GetNewClosure()
    Show-Scn $s
    Check ($reg.hooked -eq $true -and $reg.error -eq '') 'B4 the theme hook registers' "hooked=$($reg.hooked) error=$($reg.error)"
    $none = [IntPtr]::Zero
    foreach ($m in @(@('WM_SETTINGCHANGE', 0x001A), @('WM_SYSCOLORCHANGE', 0x0015), @('WM_DWMCOLORIZATIONCOLORCHANGED', 0x0320))) {
        $pre = $cnt.n
        $null = $script:native::SendMessage($s.Hwnd, [uint32]$m[1], $none, $none)
        Invoke-Pump 1000 ({ $cnt.n -gt $pre }).GetNewClosure()
        Invoke-Pump 150
        Check (($cnt.n - $pre) -eq 1) ("B4 " + $m[0] + ' bumps the theme counter by exactly 1') "before=$pre after=$($cnt.n)"
    }
    Unregister-FastLlmUiWindowHooks -Window $w
    Check-NoExceptions 'B4'
}

function Invoke-B5-SettingChangeString {
    $s = New-Scn 'c1'; $form = $s.Form; $w = $s.Window
    $cnt = @{ n = 0 }
    $null = Register-FastLlmUiWindowHooks -Window $w -Form $form -OnThemeChanged ({ $cnt.n++ }).GetNewClosure()
    Show-Scn $s
    $ptr = [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni('ImmersiveColorSet')
    try {
        $pre = $cnt.n
        $null = $script:native::SendMessage($s.Hwnd, [uint32]0x001A, [IntPtr]::Zero, $ptr)
        Invoke-Pump 1000 ({ $cnt.n -gt $pre }).GetNewClosure()
        Invoke-Pump 150
        Check (($cnt.n - $pre) -eq 1) 'C WM_SETTINGCHANGE with the ImmersiveColorSet string raises the theme counter by exactly 1' "before=$pre after=$($cnt.n)"
    }
    finally { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptr) }
    Unregister-FastLlmUiWindowHooks -Window $w
    Check-NoExceptions 'C'
}

function Invoke-B6-HookFailure {
    $r = Register-FastLlmUiWindowHooks -Window ([pscustomobject]@{ Dispatcher = $null }) -Form ([pscustomobject]@{}) -OnThemeChanged { }
    Check ($r.hooked -eq $false -and [string]$r.error -ne '') 'B6 AddHook failure: an object that is not a window reports hooked=false with an error' "hooked=$($r.hooked) error=$($r.error)"
    # evidence only: a closed window (no HwndSource may be left); the outcome is printed, not asserted
    $s = New-Scn 'b6'
    Show-Scn $s
    $s.Form.FastLlmFormState.FormClosing.Clear()
    $s.Window.Close()
    Invoke-Pump 100
    $r2 = Register-FastLlmUiWindowHooks -Window $s.Window -Form $s.Form -OnThemeChanged { }
    Write-Host "INFO: B6 a closed window registers as hooked=$($r2.hooked) error=$($r2.error)"
    Check-NoExceptions 'B6'
}

function Invoke-B7-Unregister {
    $s = New-Scn 'b7'; $form = $s.Form; $w = $s.Window
    $cnt = @{ n = 0 }
    $none = [IntPtr]::Zero
    $null = Register-FastLlmUiWindowHooks -Window $w -Form $form -OnThemeChanged ({ $cnt.n++ }).GetNewClosure()
    $r2 = Register-FastLlmUiWindowHooks -Window $w -Form $form -OnThemeChanged ({ $cnt.n++ }).GetNewClosure()
    Show-Scn $s
    $pre = $cnt.n
    $null = $script:native::SendMessage($s.Hwnd, [uint32]0x0320, $none, $none)
    Invoke-Pump 1000 ({ $cnt.n -gt $pre }).GetNewClosure()
    Invoke-Pump 150
    Check ($r2.hooked -eq $true -and ($cnt.n - $pre) -eq 1) 'B7 registering twice on one window replaces the older hook (one bump per message)' "hooked=$($r2.hooked) before=$pre after=$($cnt.n)"
    Unregister-FastLlmUiWindowHooks -Window $w
    $pre = $cnt.n
    foreach ($m in 0x001A, 0x0015, 0x0320) { $null = $script:native::SendMessage($s.Hwnd, [uint32]$m, $none, $none) }
    Invoke-Pump 300
    Check ($cnt.n -eq $pre) 'B7 after Unregister the messages no longer bump the counter' "before=$pre after=$($cnt.n)"
    $e1 = ''; try { Unregister-FastLlmUiWindowHooks -Window $w; Unregister-FastLlmUiWindowHooks -Window $w } catch { $e1 = $_.Exception.Message }
    Check ($e1 -eq '') 'B7 calling Unregister twice is a no-op' $e1
    $s2 = New-Scn 'b7b'
    $e2 = ''; try { Unregister-FastLlmUiWindowHooks -Window $s2.Window } catch { $e2 = $_.Exception.Message }
    Check ($e2 -eq '') 'B7 Unregister on a window that was never registered is a no-op' $e2
    Check-NoExceptions 'B7'
}

# ======================================================================================================================
# Part B2: hook semantics (behaviour through SendMessage to our own hwnd; handlers are plain scriptblocks, the real shape)
# ======================================================================================================================

$script:hAnswer = ''
$script:hCap = ''
$script:hForm = $null
$script:hWin = $null
$script:hRunsRef = @{ n = 0 }
# The counter is a reference object: a timer closure runs in its own module scope and cannot read $script: state.
function Step-ShellRun([hashtable]$Counter) { $Counter.n++ }

function Invoke-H1-ReentrantQuery {
    $s = New-Scn 'h1'; $form = $s.Form; $w = $s.Window
    $runs = @{ n = 0 }
    $script:hRunsRef = $runs
    $script:hAnswer = ''; $script:hForm = $form
    $script:hCap = 'FastLLM shell hook H1 ' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $form.Add_FormClosing({ param($sender, $event)
        Step-ShellRun $script:hRunsRef
        $r = [System.Windows.Forms.MessageBox]::Show($script:hForm, 'Close?', $script:hCap, 'YesNo', 'Question')
        $script:hAnswer = [string]$r
        if ($r -ne 'Yes') { $event.Cancel = $true } })
    $null = Register-FastLlmUiWindowHooks -Window $w -Form $form -OnThemeChanged { }
    Show-Scn $s
    $nat = $script:native
    $hw = $s.Hwnd
    $cap = $script:hCap
    $st = @{ q = $false; result = [long]-1; runsAtQuery = -1; at = [long]0; timedOut = $false }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = 50
    $t.Add_Tick(({
        $h = $nat::FindWindowByTitle($cap)
        $ms = $sw.ElapsedMilliseconds
        if ($h.ToInt64() -ne 0) {
            if (-not $st.q) {
                $st.q = $true; $st.at = $ms
                $st.runsAtQuery = $runs.n
                $st.result = $nat::SendMessage($hw, [uint32]0x0011, [IntPtr]::Zero, [IntPtr]::Zero).ToInt64()
            }
            elseif (($ms - $st.at) -gt 300) { $null = $nat::PostButtonClick($h, 7); if (($ms - $st.at) -gt 2000) { $null = $nat::PostCommand($h, 7) } }
        }
        elseif (-not $st.q -and $ms -gt 8000) { $st.timedOut = $true; $t.Stop() }
    }).GetNewClosure())
    $script:objs.Add($t)
    $t.Start()
    try { $form.Close() } finally { $t.Stop() }
    Invoke-Pump 150
    Check ($st.q -and -not $st.timedOut) 'H1 the guard box appeared and the query was sent from inside its modal loop' "q=$($st.q) timedOut=$($st.timedOut)"
    Check ($st.result -eq 0) 'H1 WM_QUERYENDSESSION while a guard box is up returns 0 (refused)' "result=$($st.result) expected=0"
    Check ($runs.n -eq 1 -and $st.runsAtQuery -eq 1) 'H1 no second guard box opened: the handler ran once' "runs=$($runs.n) runsAtQuery=$($st.runsAtQuery) expected=1"
    Check ($script:hAnswer -eq 'No' -and $w.IsVisible -and $s.Closed.n -eq 0) 'H1 after No the window is open' "answer=$($script:hAnswer) IsVisible=$($w.IsVisible) closed=$($s.Closed.n)"
    $form.FastLlmFormState.FormClosing.Clear()
    $msg = ''
    try { $form.Close() } catch { $msg = $_.Exception.Message }
    Invoke-Pump 200 ({ $s.Closed.n -ge 1 }).GetNewClosure()
    Check ($msg -eq '' -and $s.Closed.n -eq 1) 'H1 a later Close() with no cancelling handler closes it without an exception' "message=$msg closed=$($s.Closed.n)"
    Check-NoExceptions 'H1'
}

function Invoke-H2-ThrowingQuery {
    $s = New-Scn 'h2'; $form = $s.Form; $w = $s.Window
    $form.Add_FormClosing({ param($sender, $event) throw 'query failed' })
    $null = Register-FastLlmUiWindowHooks -Window $w -Form $form -OnThemeChanged { }
    Show-Scn $s
    $de = $script:dispEx
    $r = $script:native::SendMessage($s.Hwnd, [uint32]0x0011, [IntPtr]::Zero, [IntPtr]::Zero).ToInt64()
    Invoke-Pump 600 ({ $de.Count -ge 1 }).GetNewClosure()
    Invoke-Pump 200
    $msgs = @($script:dispEx.ToArray())
    Check ($r -eq 0) 'H2 a throwing handler on WM_QUERYENDSESSION refuses it (returns 0)' "result=$r expected=0"
    Check ($msgs.Count -eq 1 -and ($msgs -join ' ') -match 'query failed') 'H2 exactly one dispatcher exception is recorded for it' "count=$($msgs.Count) text=$($msgs -join ' | ')"
    Check ($w.IsVisible -and $s.Closed.n -eq 0) 'H2 the window stays open' "IsVisible=$($w.IsVisible) closed=$($s.Closed.n)"
    $script:dispEx.Clear()
    Unregister-FastLlmUiWindowHooks -Window $w
    Check-NoExceptions 'H2'
}

# How many hook entries the hooks file holds for this window (matched by reference).
function Get-ShellHookEntryCount($Window) {
    $n = 0
    foreach ($e in @($script:FastLlmUiHookEntries)) { if ([object]::ReferenceEquals($e.Window.PSObject.BaseObject, $Window.PSObject.BaseObject)) { $n++ } }
    return $n
}

function Invoke-H3-UnregisterOnClosed {
    $s = New-Scn 'h3'; $form = $s.Form; $w = $s.Window
    $script:hWin = $w
    $null = Register-FastLlmUiWindowHooks -Window $w -Form $form -OnThemeChanged { }
    $w.Add_Closed({ Unregister-FastLlmUiWindowHooks -Window $script:hWin })
    Show-Scn $s
    Check ((Get-ShellHookEntryCount $w) -eq 1) 'H3 the hook state holds one entry for the window after Register' "entries=$(Get-ShellHookEntryCount $w)"
    $form.Close()
    Invoke-Pump 300 ({ $s.Closed.n -ge 1 }).GetNewClosure()
    Invoke-Pump 100
    Check ($s.Closed.n -eq 1) 'H3 the window closed' "closed=$($s.Closed.n)"
    Check ((Get-ShellHookEntryCount $w) -eq 0) 'H3 Unregister called from Closed leaves no hook state entry for the window' "entries=$(Get-ShellHookEntryCount $w)"
    $e1 = ''; try { Unregister-FastLlmUiWindowHooks -Window $w } catch { $e1 = $_.Exception.Message }
    Check ($e1 -eq '') 'H3 a second Unregister is a no-op' $e1
    Check-NoExceptions 'H3'
}

function Invoke-H4-ThemeCallbackThrows {
    $s = New-Scn 'h4'; $form = $s.Form; $w = $s.Window
    $null = Register-FastLlmUiWindowHooks -Window $w -Form $form -OnThemeChanged { throw 'theme boom' }
    Show-Scn $s
    $de = $script:dispEx
    $null = $script:native::SendMessage($s.Hwnd, [uint32]0x0015, [IntPtr]::Zero, [IntPtr]::Zero)
    Invoke-Pump 800 ({ $de.Count -ge 1 }).GetNewClosure()
    Invoke-Pump 300
    $msgs = @($script:dispEx.ToArray())
    Check ($msgs.Count -eq 1 -and ($msgs -join ' ') -match 'theme boom') 'H4 a throwing theme callback records exactly one dispatcher exception' "count=$($msgs.Count) text=$($msgs -join ' | ')"
    Check ($w.IsVisible -and $s.Closed.n -eq 0) 'H4 the window stays open' "IsVisible=$($w.IsVisible) closed=$($s.Closed.n)"
    $script:dispEx.Clear()
    Unregister-FastLlmUiWindowHooks -Window $w
    Check-NoExceptions 'H4'
}

function Invoke-H5-EndSession {
    $script:shellMark = 0
    $s = New-Scn 'h5'; $form = $s.Form; $w = $s.Window
    $form.Add_FormClosing({ param($sender, $event) Set-ShellTestMark; $event.Cancel = $true })
    $null = Register-FastLlmUiWindowHooks -Window $w -Form $form -OnThemeChanged { }
    Show-Scn $s
    $null = $script:native::SendMessage($s.Hwnd, [uint32]0x0016, [IntPtr]1, [IntPtr]::Zero)
    Invoke-Pump 300
    Check ($script:shellMark -eq 0) 'H5 WM_ENDSESSION (wParam 1) does not run FormClosing' "runs=$($script:shellMark) expected=0"
    Check ($w.IsVisible -and $s.Closed.n -eq 0) 'H5 WM_ENDSESSION leaves the window as it was' "IsVisible=$($w.IsVisible) closed=$($s.Closed.n)"
    Unregister-FastLlmUiWindowHooks -Window $w
    Check-NoExceptions 'H5'
}

function Invoke-H6-PassThrough {
    $s = New-Scn 'h6'; $form = $s.Form; $w = $s.Window
    $null = Register-FastLlmUiWindowHooks -Window $w -Form $form -OnThemeChanged { }
    Show-Scn $s
    $len = $script:native::SendMessage($s.Hwnd, [uint32]0x000E, [IntPtr]::Zero, [IntPtr]::Zero).ToInt64()
    Check ($len -eq [long]$s.Title.Length) 'H6 an unrelated message passes through: WM_GETTEXTLENGTH returns the title length' "result=$len expected=$($s.Title.Length)"
    Unregister-FastLlmUiWindowHooks -Window $w
    Check-NoExceptions 'H6'
}

function Invoke-H7-DpiEvidence {
    $a = $script:native::GetDpiAwareness()
    $names = @{ '0' = 'unaware'; '1' = 'system'; '2' = 'per-monitor'; '-1' = 'invalid'; '-2' = 'not available' }
    $small = [System.Windows.Forms.SystemInformation]::SmallIconSize
    Write-Host ("INFO: H7 process DPI awareness=" + $a + " (" + $names[[string]$a] + ") SmallIconSize=" + $small.Width + "x" + $small.Height)
}

# ======================================================================================================================
# Part B: the shell (bindings, access text, Home parity, Shown, theme, resources, split menu, nav, dispatcher handler)
# ======================================================================================================================
# The suite's own stubs stand in for the orchestration the shell reads (fast-llm-ui.ps1): the snapshot, the failure display and the settings.
# Initialize-FastLlmUiFluentShell and Start-FastLlmUiFluentLoop run for real. Step S0 enters the loop's Dispatcher.Run: every later step
# runs from the 50 ms step timer INSIDE that nested frame, which ends when Stop-ShellLoop shuts the dispatcher down.

Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force
. (Join-Path $root 'tests/helpers/UiControlStatesMatrix.ps1')
. (Join-Path $root 'src/FastLlm.Update.ps1')
. (Join-Path $root 'src/FastLlm.Components.ps1')
. (Join-Path $root 'src/FastLlm.ServingSettings.ps1')
. (Join-Path $root 'src/FastLlm.UiFluentShell.ps1')

# The real stop function exits the process, so a startup fault would end the suite silently: keep its text for one check, then stand a throwing one in.
$script:realStopText = [string](Get-Command Stop-FastLlmUiFluentStartup -CommandType Function).Definition
function Stop-FastLlmUiFluentStartup {
    param([string]$Reason)
    throw "startup stopped: $Reason"
}
# Counts the runs of the shell's theme update (the window-message hook calls it by name) and then runs the real one.
$script:origUpdateTheme = ${function:Update-FastLlmUiFluentTheme}
$script:themeCalls = 0
function Update-FastLlmUiFluentTheme {
    $script:themeCalls++
    & $script:origUpdateTheme
}

$script:shellSnap = $null
$script:shellFailMsg = ''
$script:failureHeld = $false
$script:shellOk = $false
$script:shellShown = 0
$script:shellMenuMark = 0
$script:shellTitle = ''
# GetUiStateSnapshot is NOT defined here: fast-llm-ui.ps1 defines it after the seam, so the stub is defined after Initialize (S0), as there.
$script:snapOverride = $null
$script:failureViewText = ''
# Counts what the shell's exception handlers record (plain code, a reference list), then runs the real one.
$script:origUnhandled = ${function:Invoke-FastLlmUiFluentUnhandled}
function Invoke-FastLlmUiFluentUnhandled {
    param($Exception)
    if ($null -ne $Exception) { [void]$script:unhandledLog.Add([string]$Exception.ToString()) } else { [void]$script:unhandledLog.Add('(null exception)') }
    & $script:origUnhandled -Exception $Exception
}
# Live-region events, recorded by name in a reference object (the wrapper is plain code; a closure could not read $script:).
$script:liveLog = New-Object System.Collections.ArrayList
$script:origLive = ${function:Send-FastLlmUiFluentLiveRegion}
function Send-FastLlmUiFluentLiveRegion {
    param($Element)
    [void]$script:liveLog.Add([string]$Element.Name)
    & $script:origLive -Element $Element
}
function Get-ShellLiveCount([string]$Name) {
    $n = 0
    foreach ($x in @($script:liveLog.ToArray())) { if ($x -ceq $Name) { $n++ } }
    return $n
}
function GetUiBackgroundRunStatus { return $null }
function ShowFailure($Message) { $script:shellFailMsg = [string]$Message }

function Invoke-S0-ShellStart {
    Initialize-ShellEnv

    $textC1 = Get-FastLlmUiUnsupportedText -Reason 'theme-init' -Folder 'C:\example'
    $textC2 = Get-FastLlmUiUnsupportedText -Reason 'xaml-parse' -Folder 'C:\example'
    $shellSource = [System.IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.UiFluentShell.ps1'))
    Check (($textC1 -ceq $textC2) -and $textC1 -match 'a fault in FastLLM') 'S0 the reasons theme-init and xaml-parse give the same text C (a fault in FastLLM)' "theme-init='$textC1' xaml-parse='$textC2'"
    Check ($script:realStopText -match 'Show-FastLlmUiUnsupported\s+-Reason\s+\$Reason' -and $script:realStopText -match 'exit 3') 'S0 the real Stop-FastLlmUiFluentStartup passes its reason to Show-FastLlmUiUnsupported and exits 3' $script:realStopText
    Check (($shellSource -match "'theme-init'") -and ($shellSource -match "'xaml-parse'")) 'S0 both startup reasons (theme-init, xaml-parse) appear in the shell file; the behaviour is proven by the S99 injected faults' 'a reason literal was not found in the shell file'

    $err = ''
    $initWatch = [System.Diagnostics.Stopwatch]::StartNew()
    try { Initialize-FastLlmUiFluentShell } catch { $err = $_.Exception.Message }
    Write-Host ("INFO: S0 Initialize-FastLlmUiFluentShell took " + $initWatch.ElapsedMilliseconds + " ms")
    Check ($err -eq '') 'S0 the startup did not stop (Initialize-FastLlmUiFluentShell returned)' $err
    if ($err -ne '') { $script:shellOk = $false; return }
    $script:shellOk = $true
    $f = $script:FastLlmUiFluent
    $win = $f.Window
    # The orchestration functions the refresh reads exist only from here, as in fast-llm-ui.ps1; the first tick must not need them yet.
    Check ([string]$f.TickError -eq '') 'S0 the first refresh in Initialize did not fail (TickError empty before the orchestration functions exist)' "TickError=$($f.TickError)"
    function script:GetUiStateSnapshot([bool]$Busy) { if ($null -ne $script:snapOverride) { return $script:snapOverride.cur }; return $script:shellSnap }
    Check ([System.Windows.Forms.Application]::RenderWithVisualStyles) 'S0 WinForms visual styles are on after Initialize (RenderWithVisualStyles)' "RenderWithVisualStyles=$([System.Windows.Forms.Application]::RenderWithVisualStyles)"
    Check (([double]$win.Width -eq 1000) -and ([double]$win.Height -eq 680) -and ([double]$win.MinWidth -eq 640) -and ([double]$win.MinHeight -eq 480)) 'S0 the window is 1000x680 with a 640x480 minimum' "size=$($win.Width)x$($win.Height) min=$($win.MinWidth)x$($win.MinHeight)"
    Check (($null -ne $win.Icon) -and ($win.WindowStartupLocation -eq [System.Windows.WindowStartupLocation]::CenterScreen)) 'S0 the window has an icon and starts centred on the screen' "icon=$($null -ne $win.Icon) location=$($win.WindowStartupLocation)"
    Check ($win.Title -ceq $script:shellTitle) 'S0 the shell window carries the classic form title' "title=$($win.Title) expected=$($script:shellTitle)"
    Check ($null -ne $f.Hooks -and $f.Hooks['hooked'] -eq $true) 'S0 the window hooks registered' "hooks=$($f.Hooks)"
    Check ($null -ne $script:form.FastLlmFormState) 'S0 the orchestration form is now the form adapter' 'form has no FastLlmFormState'
    $script:scns.Add([pscustomobject]@{ Window = $win; Form = $script:form; Hwnd = [System.Windows.Interop.WindowInteropHelper]::new($win).Handle; Closed = @{ n = 0 }; Title = $win.Title })
    $script:form.Add_Shown({ $script:shellShown++ })
    Check-NoExceptions 'S0'
    # From here the loop owns the thread. The step timer is not busy any more, so S1 onward run inside the loop's nested frame.
    $script:busy = $false
    # A DispatcherTimer re-queues itself only after its Tick returns, and S0 does not return until the loop ends: re-arm the step timer by hand so S1 onward run in the nested frame.
    # The loop ends when the last step calls Stop-ShellLoop (InvokeShutdown ends the nested frame and the outer one together), so no step may follow that.
    $script:tick.Stop()
    $script:tick.Start()
    try { Start-FastLlmUiFluentLoop }
    catch { $script:fail++; Write-Host "FAIL: S0 Start-FastLlmUiFluentLoop threw -- $($_.Exception.ToString())" }
}

function Invoke-S1-Shown {
    if (-not $script:shellOk) { return }
    $win = $script:FastLlmUiFluent.Window
    Check ($script:liveLog.Count -eq 0) 'S1 the first tick raised no live-region event' "events=$($script:liveLog.Count) [$(@($script:liveLog.ToArray()) -join ',')]"
    Invoke-Pump 5000 ({ $script:shellShown -ge 1 })
    Invoke-Pump 700
    Check ($script:shellShown -eq 1) 'S1 a Shown handler added through form.Add_Shown runs exactly once after the real shell window renders' "runs=$($script:shellShown) expected=1"
    Check ($win.IsVisible) 'S1 the shell window is visible' "IsVisible=$($win.IsVisible)"
    Check ([string]$script:FastLlmUiFluent.TickError -eq '') 'S1 no refresh has failed up to the first show (TickError empty)' "TickError=$($script:FastLlmUiFluent.TickError)"
    Check-NoExceptions 'S1'
}

function Invoke-S2-Bindings {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    # the detail line
    $script:statusLabel.Text = 'detail line check one'
    Check ($els.StatusDetail.Text -ceq 'detail line check one') 'S2 setting statusLabel.Text updates the card detail' "text=$($els.StatusDetail.Text)"
    # the split button's main part
    $script:installButton.Enabled = $false
    Check ($els.InstallButton.IsEnabled -eq $false) 'S2 installButton.Enabled=false disables the main part of the split button' "IsEnabled=$($els.InstallButton.IsEnabled)"
    $script:installButton.Enabled = $true
    Check ($els.InstallButton.IsEnabled -eq $true) 'S2 installButton.Enabled=true enables it again' "IsEnabled=$($els.InstallButton.IsEnabled)"
    # a WPF click runs the plain-scriptblock Click handler of the adapter
    $script:shellMark = 0
    $script:installButton.Add_Click({ param($sender, $ea) Set-ShellTestMark })
    $els.InstallButton.RaiseEvent((New-ShellClick $els.InstallButton ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Check ($script:shellMark -eq 1) 'S2 a WPF click (ButtonBase.ClickEvent) on the main part runs the installButton Click handler once' "runs=$($script:shellMark) expected=1"
    $peer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($els.InstallButton)
    $invoke = [System.Windows.Automation.Provider.IInvokeProvider]($peer.GetPattern([System.Windows.Automation.Peers.PatternInterface]::Invoke))
    $invoke.Invoke()
    Invoke-Pump 300 ({ $script:shellMark -ge 2 })
    Check ($script:shellMark -eq 2) 'S2 an automation Invoke on the main part runs the handler too' "runs=$($script:shellMark) expected=2"
    # the card headline follows Get-FastLlmUiCardState for three snapshots
    $snaps = @(
        @{ Label = 'not running'; Snap = (New-ShellSnap @{}); Held = $false },
        @{ Label = 'running'; Snap = (New-ShellSnap @{ ChildActive = $true; Step = 'serving'; RunReady = $true }); Held = $false },
        @{ Label = 'needs attention with a held failure'; Snap = (New-ShellSnap @{ FailureHeld = $true }); Held = $true })
    $seen = @{}
    foreach ($c in $snaps) {
        $script:shellSnap = $c.Snap
        $script:failureHeld = [bool]$c.Held
        if ($c.Held) { $script:output.Text = 'failure output check'; $script:failureViewText = 'failure output check' }
        Invoke-FastLlmUiFluentTick
        $want = [string](Get-FastLlmUiCardState -Snapshot $c.Snap).headline
        $seen[$want] = $true
        Check ($want -ne '' -and $els.StatusHeadline.Text -ceq $want) ("S2 the card headline follows Get-FastLlmUiCardState: " + $c.Label) "headline=$($els.StatusHeadline.Text) expected=$want"
    }
    Check ($seen.Count -eq 3) 'S2 the three snapshots gave three different headlines' "distinct=$($seen.Count) expected=3"
    Check ($els.FailureBar.Visibility -eq [System.Windows.Visibility]::Visible -and $els.FailureText.Text -ceq 'failure output check') 'S2 the held failure shows in the message area' "visibility=$($els.FailureBar.Visibility) text=$($els.FailureText.Text)"
    $script:shellSnap = New-ShellSnap
    $script:failureHeld = $false
    $script:failureViewText = ''
    $script:output.Text = ''
    Invoke-FastLlmUiFluentTick
    Check ($els.FailureBar.Visibility -eq [System.Windows.Visibility]::Collapsed) 'S2 the failure bar hides when no failure is held' "visibility=$($els.FailureBar.Visibility)"

    # access text, end to end
    $script:notesLabel.Text = 'a && b _c'
    Check ($els.NotesText.Text -ceq 'a & b _c') 'S2 notesLabel (UseMnemonic true) shows what WinForms shows: a & b _c' "text=$($els.NotesText.Text)"
    $script:notesLabel.Text = ''
    $script:statusLabel.Text = 'model_a_b'
    Check ($els.StatusDetail.Text -ceq 'model_a_b') 'S2 statusLabel (UseMnemonic false) shows model_a_b unchanged' "text=$($els.StatusDetail.Text)"
    $btn = $els.ConnectButton
    $script:connectButton.UseMnemonic = $false
    $script:connectButton.Text = 'my_model_id'
    Invoke-Pump 200
    $btn.UpdateLayout()
    $texts = @(Get-ShellTexts $btn)
    $accessKeys = @(Get-ShellVisuals $btn | Where-Object { $_ -is [System.Windows.Controls.AccessText] } | ForEach-Object { [int][char]$_.AccessKey })
    Check (@($accessKeys | Where-Object { $_ -ne 0 }).Count -eq 0) 'S2 a caption with underscores sets no access key on its AccessText' "accessKeys=[$($accessKeys -join ',')]"
    Check (($texts -ccontains 'my_model_id') -and -not (@($texts | Where-Object { $_ -match '__' }).Count -gt 0)) 'S2 a Content-mode caption with underscores renders with none lost' ("rendered=[$($texts -join '|')] content='$($btn.Content)' visibility=$($btn.Visibility) size=$($btn.ActualWidth)x$($btn.ActualHeight) tree: " + (Get-ShellTreeText $btn))
    $script:connectButton.UseMnemonic = $true
    $script:connectButton.Text = 'Connect an app'
    $inst = @(Get-ShellTexts $els.InstallButton)
    Check ($inst -ccontains 'Install & start') 'S2 the Install && start caption renders as Install & start' "rendered=[$($inst -join '|')]"
    Check-NoExceptions 'S2'
}

# element, adapter, mode, kind (named: an interactive element with a name a screen reader speaks; text: a non-interactive TextBlock; visual: a non-interactive bar),
# and the flags: noText (the element draws an icon, not the caption), noVisible (the card logic owns its visibility)
$script:shellParity = @(
    @{ El = 'TitleText'; Ad = 'title'; Mode = 'TextBlock'; Kind = 'text'; NoText = $false; NoVisible = $false },
    @{ El = 'NoticeText'; Ad = 'notice'; Mode = 'TextBlock'; Kind = 'text'; NoText = $false; NoVisible = $false },
    @{ El = 'TrayButton'; Ad = 'trayButton'; Mode = 'Content'; Kind = 'named'; NoText = $false; NoVisible = $false },
    @{ El = 'InstallButton'; Ad = 'installButton'; Mode = 'Content'; Kind = 'named'; NoText = $false; NoVisible = $true },
    @{ El = 'StartMenuItem'; Ad = 'startButton'; Mode = 'Header'; Kind = 'named'; NoText = $false; NoVisible = $false },
    @{ El = 'BackgroundStartMenuItem'; Ad = 'backgroundStartButton'; Mode = 'Header'; Kind = 'named'; NoText = $false; NoVisible = $false },
    @{ El = 'StopButton'; Ad = 'stopButton'; Mode = 'Content'; Kind = 'named'; NoText = $false; NoVisible = $true },
    @{ El = 'AttachButton'; Ad = 'backgroundAttachButton'; Mode = 'Content'; Kind = 'named'; NoText = $false; NoVisible = $true },
    @{ El = 'CopyButton'; Ad = 'copyButton'; Mode = 'Content'; Kind = 'named'; NoText = $true; NoVisible = $true },
    @{ El = 'StatusDetail'; Ad = 'statusLabel'; Mode = 'TextBlock'; Kind = 'text'; NoText = $false; NoVisible = $false },
    @{ El = 'BackgroundLine'; Ad = 'backgroundLabel'; Mode = 'TextBlock'; Kind = 'text'; NoText = $false; NoVisible = $false },
    @{ El = 'NotesText'; Ad = 'notesLabel'; Mode = 'TextBlock'; Kind = 'text'; NoText = $false; NoVisible = $false },
    @{ El = 'ResultsLink'; Ad = 'resultsLink'; Mode = 'Content'; Kind = 'named'; NoText = $false; NoVisible = $false },
    @{ El = 'BarLink'; Ad = 'barLink'; Mode = 'Content'; Kind = 'named'; NoText = $false; NoVisible = $false },
    @{ El = 'HomeProgress'; Ad = 'progress'; Mode = 'Visual'; Kind = 'visual'; NoText = $true; NoVisible = $false },
    @{ El = 'ActivityBox'; Ad = 'output'; Mode = 'Output'; Kind = 'named'; NoText = $false; NoVisible = $false },
    @{ El = 'OpenChatButton'; Ad = 'openChatButton'; Mode = 'Content'; Kind = 'named'; NoText = $false; NoVisible = $false },
    @{ El = 'ConnectButton'; Ad = 'connectButton'; Mode = 'Content'; Kind = 'named'; NoText = $false; NoVisible = $false },
    @{ El = 'SwitchButton'; Ad = 'switchButton'; Mode = 'Content'; Kind = 'named'; NoText = $false; NoVisible = $false },
    @{ El = 'SwitchLine'; Ad = 'switchLabel'; Mode = 'TextBlock'; Kind = 'text'; NoText = $false; NoVisible = $false },
    @{ El = 'UpdateText'; Ad = 'bannerLabel'; Mode = 'TextBlock'; Kind = 'text'; NoText = $false; NoVisible = $false },
    @{ El = 'UpdateNotesButton'; Ad = 'bannerNotes'; Mode = 'Content'; Kind = 'named'; NoText = $false; NoVisible = $false },
    @{ El = 'UpdateButton'; Ad = 'bannerButton'; Mode = 'Content'; Kind = 'named'; NoText = $false; NoVisible = $false },
    @{ El = 'ReinstallButton'; Ad = 'reinstallButton'; Mode = 'Content'; Kind = 'named'; NoText = $false; NoVisible = $false },
    @{ El = 'FailureCopyButton'; Ad = 'failureCopyLink'; Mode = 'Content'; Kind = 'named'; NoText = $false; NoVisible = $false }
)

function Get-ShellElementText($Element, [string]$Mode) {
    if ($Mode -ceq 'Content') { return [string]$Element.Content }
    if ($Mode -ceq 'Header') { return [string]$Element.Header }
    return [string]$Element.Text
}

function Invoke-S3-HomeParity {
    if (-not $script:shellOk) { return }
    $els = $script:FastLlmUiFluent.Els
    foreach ($row in $script:shellParity) {
        $n = $row.El
        $el = $els[$n]
        Check ($null -ne $el) "S3 $n exists" 'no such element'
        if ($null -eq $el) { continue }
        $ad = Get-Variable -Name $row.Ad -Scope Script -ValueOnly
        if ($row.Kind -ceq 'named') {
            $name = Get-ShellPeerName $el
            Check ((-not ($el -is [System.Windows.Controls.TextBlock])) -and (Test-ShellNameReadable $name)) "S3 $n is interactive and has a spoken name" "name='$name'"
        }
        elseif ($row.Kind -ceq 'text') { Check ($el -is [System.Windows.Controls.TextBlock]) "S3 $n is a non-interactive text element" "type=$($el.GetType().Name)" }
        else { Check ($el -is [System.Windows.Controls.ProgressBar]) "S3 $n is a non-interactive progress bar" "type=$($el.GetType().Name)" }
        $origText = [string]$ad.Text; $origEnabled = [bool]$ad.Enabled; $origVisible = [bool]$ad.Visible
        # Text
        if ($row.Mode -cne 'Visual') {
            $before = Get-ShellElementText $el $row.Mode
            $ad.Text = 'zz parity ' + $row.Ad
            $after = Get-ShellElementText $el $row.Mode
            if ($row.NoText) { Check ($after -ceq $before) "S3 $n keeps its icon when $($row.Ad).Text is written" "before='$before' after='$after'" }
            else { Check ($after -ceq ('zz parity ' + $row.Ad)) "S3 $($row.Ad).Text reaches $n" "element text='$after'" }
        }
        # Enabled
        $ad.Enabled = $false
        $off = [bool]$el.IsEnabled
        $ad.Enabled = $true
        $on = [bool]$el.IsEnabled
        Check (($off -eq $false) -and ($on -eq $true)) "S3 $($row.Ad).Enabled reaches $n" "after false=$off after true=$on"
        # Visible
        $v0 = $el.Visibility
        $ad.Visible = $false
        $v1 = $el.Visibility
        $ad.Visible = $true
        $v2 = $el.Visibility
        if ($row.NoVisible) { Check (($v1 -eq $v0) -and ($v2 -eq $v0)) "S3 $n visibility stays with the card or message logic when $($row.Ad).Visible is written" "start=$v0 after false=$v1 after true=$v2" }
        else { Check (($v1 -eq [System.Windows.Visibility]::Collapsed) -and ($v2 -eq [System.Windows.Visibility]::Visible)) "S3 $($row.Ad).Visible reaches $n" "after false=$v1 after true=$v2" }
        $ad.Text = $origText; $ad.Enabled = $origEnabled; $ad.Visible = $origVisible
        if (-not $row.NoVisible) { $el.Visibility = $v0 }
    }
    # the update BAR follows the message logic: the offer shows it, no offer hides it
    $origBanner = [bool]$script:bannerLabel.Visible; $origReinstall = [bool]$script:reinstallButton.Visible
    $script:bannerLabel.Visible = $true
    Invoke-FastLlmUiFluentTick
    $barOn = $els.UpdateBar.Visibility
    $script:bannerLabel.Visible = $false; $script:reinstallButton.Visible = $false
    Invoke-FastLlmUiFluentTick
    $barOff = $els.UpdateBar.Visibility
    Check (($barOn -eq [System.Windows.Visibility]::Visible) -and ($barOff -eq [System.Windows.Visibility]::Collapsed)) 'S3 the update bar follows the message logic (an offer shows it, none hides it)' "with offer=$barOn without=$barOff"
    $script:bannerLabel.Visible = $origBanner; $script:reinstallButton.Visible = $origReinstall
    Invoke-FastLlmUiFluentTick
    Check-NoExceptions 'S3'
}

function Invoke-S4-Resources {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $dict = $f.Window.Resources.MergedDictionaries[0]
    $same = {
        param($Brush, [string]$Key)
        $want = $dict[$Key]
        return (($Brush -is [System.Windows.Media.SolidColorBrush]) -and ($want -is [System.Windows.Media.SolidColorBrush]) -and ($Brush.Color.ToString() -ceq $want.Color.ToString()))
    }
    $rows = @(
        @{ N = 'InstallButton'; Fg = 'FastLlm.TextOnAccentBrush'; Bg = 'FastLlm.AccentFillBrush' },
        @{ N = 'ConnectButton'; Fg = 'FastLlm.TextPrimaryBrush'; Bg = 'FastLlm.CardBrush' },
        @{ N = 'ActivityBox'; Fg = 'FastLlm.TextPrimaryBrush'; Bg = 'FastLlm.CardBrush' })
    $bodySize = [double]$dict['FastLlm.BodySize']
    foreach ($r in $rows) {
        $el = $els[$r.N]
        Check (& $same $el.Foreground $r.Fg) "S4 Home $($r.N) Foreground is the theme value $($r.Fg)" "actual=$($el.Foreground)"
        Check (& $same $el.Background $r.Bg) "S4 Home $($r.N) Background is the theme value $($r.Bg)" "actual=$($el.Background)"
        Check ([Math]::Abs([double]$el.FontSize - $bodySize) -lt 0.01) "S4 Home $($r.N) FontSize is the theme body size" "actual=$($el.FontSize) expected=$bodySize"
    }
    # a disabled button (Open chat is disabled at start): text and fill come from the theme's disabled keys
    $dis = $els.OpenChatButton
    $disBd = $dis.Template.FindName('Bd', $dis)
    Check ((-not $dis.IsEnabled) -and (& $same $dis.Foreground 'FastLlm.DisabledTextBrush')) 'S4 a disabled button (Open chat) draws its text in the theme disabled text colour' "enabled=$($dis.IsEnabled) foreground=$($dis.Foreground)"
    Check (($null -ne $disBd) -and (& $same $disBd.Background 'FastLlm.DisabledFillBrush')) 'S4 a disabled button fills with the theme disabled fill colour' "Bd=$($null -ne $disBd) background=$(if ($null -ne $disBd) { $disBd.Background })"
    Check (& $same $els.StatusCard.Background 'FastLlm.CardBrush') 'S4 the status card Background is the theme card colour' "actual=$($els.StatusCard.Background)"
    $sub = [double]$dict['FastLlm.SubtitleSize']
    Check ([Math]::Abs([double]$els.TitleText.FontSize - $sub) -lt 0.01 -and $sub -ne $bodySize) 'S4 the Home title FontSize is the theme subtitle size, not the body size' "actual=$($els.TitleText.FontSize) expected=$sub body=$bodySize"
    Check-NoExceptions 'S4'
}

function Invoke-S5-SplitMenu {
    if (-not $script:shellOk) { return }
    $els = $script:FastLlmUiFluent.Els
    $script:shellMenuMark = 0
    $script:startButton.Add_Click({ param($sender, $ea) $script:shellMenuMark++ })
    $script:backgroundStartButton.Add_Click({ param($sender, $ea) $script:shellMenuMark += 10 })
    $more = $els.MoreStartButton
    $menu = $els.StartMenuItem.Parent
    Check ($menu -is [System.Windows.Controls.ContextMenu] -and $menu.Items.Count -eq 2) 'S5 the two start items live in one ContextMenu' "parent=$($menu.GetType().Name)"
    $more.RaiseEvent((New-ShellClick $more ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Invoke-Pump 300
    Check ($menu.IsOpen) 'S5 clicking the split arrow opens the menu' "IsOpen=$($menu.IsOpen)"
    Check ([object]::ReferenceEquals($menu.PlacementTarget.PSObject.BaseObject, $more.PSObject.BaseObject)) 'S5 the menu is placed against the split arrow' "target=$($menu.PlacementTarget)"
    foreach ($key in 'StartMenuItem', 'BackgroundStartMenuItem') {
        $item = $els[$key]
        Check (Test-ShellNameReadable (Get-ShellPeerName $item)) "S5 $key has an automation name" "name='$(Get-ShellPeerName $item)'"
    }
    $item = $els.StartMenuItem
    $item.RaiseEvent((New-ShellClick $item ([System.Windows.Controls.MenuItem]::ClickEvent)))
    Check ($script:shellMenuMark -eq 1) 'S5 a click on the first menu item runs the startButton handler' "marks=$($script:shellMenuMark) expected=1"
    $item2 = $els.BackgroundStartMenuItem
    $peer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($item2)
    $inv = [System.Windows.Automation.Provider.IInvokeProvider]($peer.GetPattern([System.Windows.Automation.Peers.PatternInterface]::Invoke))
    $threw = ''
    try { $inv.Invoke() } catch { $threw = $_.Exception.Message }
    Invoke-Pump 400 ({ $script:shellMenuMark -ge 11 })
    Check ($threw -eq '' -and $script:shellMenuMark -eq 11) 'S5 an automation Invoke on the second item runs the backgroundStartButton handler' "marks=$($script:shellMenuMark) expected=11 error=$threw"
    $menu.IsOpen = $false
    Invoke-Pump 100
    Check-NoExceptions 'S5'
}

function Invoke-S6-Nav {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $list = $els.NavList
    $home1 = $els.NavHome
    $list.UpdateLayout()
    $bd = $home1.Template.FindName('Bd', $home1)
    $bar = $home1.Template.FindName('Bar', $home1)
    Check ($null -ne $bd -and $null -ne $bar) 'S6 the nav item template renders its parts (Bd and Bar)' "bd=$bd bar=$bar"
    Check ($home1.ActualHeight -ge 40 -and $home1.IsSelected -and $bar.Visibility -eq [System.Windows.Visibility]::Visible) 'S6 the selected Home item is at least 40 high and shows its bar' "height=$($home1.ActualHeight) selected=$($home1.IsSelected) bar=$($bar.Visibility)"
    $threw = ''
    try {
        $src = [System.Windows.PresentationSource]::FromVisual($home1)
        $ke = New-Object System.Windows.Input.KeyEventArgs([System.Windows.Input.Keyboard]::PrimaryDevice, $src, 0, [System.Windows.Input.Key]::Down)
        $ke.RoutedEvent = [System.Windows.Input.Keyboard]::KeyDownEvent
        $home1.RaiseEvent($ke)
    }
    catch { $threw = $_.Exception.Message }
    Invoke-Pump 150
    Check ($threw -eq '') 'S6 a Down arrow KeyDown on the nav item raises no exception' $threw
    # selection moves: Connect (index 2) is enabled only once its page is registered, so a stand-in page is registered for it when the shell has none
    # (the real Connect page replaces this stand-in in a later task); Models stays disabled
    $second = $f.NavItems[2]['Item']
    $standIn = $false
    if (-not (Test-FastLlmUiFluentPageRegistered -Id 'Connect')) {
        $standIn = $true
        $stub = New-Object System.Windows.Controls.StackPanel
        $stubStatus = New-Object System.Windows.Controls.TextBlock
        Register-FastLlmUiFluentPage -Id 'Connect' -Element $stub -Nav 'NavConnect' -Status $stubStatus
    }
    $list.SelectedIndex = 2
    Invoke-Pump 150
    $bar2 = $second.Template.FindName('Bar', $second)
    Check ($second.IsSelected -and -not $home1.IsSelected -and $null -ne $bar2 -and $bar2.Visibility -eq [System.Windows.Visibility]::Visible -and $bar.Visibility -eq [System.Windows.Visibility]::Collapsed) 'S6 a selection change moves the bar from Home to Connect' "second=$($second.IsSelected) home=$($home1.IsSelected) bar2=$($bar2.Visibility) bar=$($bar.Visibility)"
    $list.SelectedIndex = 0
    Invoke-Pump 100
    if ($standIn) { $f.Pages.Remove('Connect'); $second.IsEnabled = $false; $f.NavItems[2]['Enabled'] = $false; Set-FastLlmUiFluentNavTip -Nav $f.NavItems[2] }
    Check ($home1.IsSelected) 'S6 Home is selected again' "selected=$($home1.IsSelected)"
    Check-NoExceptions 'S6'
}

function Invoke-S7-ShellTheme {
    if (-not $script:shellOk) { return }
    $win = $script:FastLlmUiFluent.Window
    $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($win).Handle
    $ptr = [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni('ImmersiveColorSet')
    try {
        $pre = $script:themeCalls
        $null = $script:native::SendMessage($hwnd, [uint32]0x001A, [IntPtr]::Zero, $ptr)
        Invoke-Pump 1500 ({ $script:themeCalls -gt $pre })
        Invoke-Pump 400
        Check (($script:themeCalls - $pre) -eq 1) 'S7 WM_SETTINGCHANGE with ImmersiveColorSet on the shell window runs the shell theme update exactly once' "before=$pre after=$($script:themeCalls)"
    }
    finally { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptr) }
    Check-NoExceptions 'S7'
}

function Invoke-S8-DispatcherHandler {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $win = $f.Window
    $disp = $win.Dispatcher
    # The suite's recorder sets Handled too, so it is taken off while the handler registered by Start-FastLlmUiFluentLoop is looked at.
    # The probe is registered last (it runs after the shell's) and reads Handled before it sets it itself.
    $script:probeSeen = $null
    $script:probeText = ''
    $script:shellFailMsg = ''
    $f.LastException = $null
    $probe = [System.Windows.Threading.DispatcherUnhandledExceptionEventHandler] { param($s, $e) $script:probeSeen = [bool]$e.Handled; $script:probeText = $e.Exception.ToString(); $e.Handled = $true }
    $disp.remove_UnhandledException($script:dispHandler)
    $disp.add_UnhandledException($probe)
    try {
        $boom = [Action] { throw 'shell dispatcher boom' }
        $null = $disp.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Normal, $boom)
        Invoke-Pump 1500 ({ $null -ne $script:probeSeen })
        Invoke-Pump 300
    }
    finally {
        $disp.remove_UnhandledException($probe)
        $disp.add_UnhandledException($script:dispHandler)
    }
    Check ($script:probeText -match 'shell dispatcher boom') 'S8 an exception thrown in a dispatcher callback reaches the dispatcher handlers' "text=$($script:probeText)"
    Check ($null -ne $f.LastException -and ([string]$f.LastException.ToString()) -match 'shell dispatcher boom') 'S8 the shell records the exception' "last=$($f.LastException)"
    Check ($script:shellFailMsg -match 'shell dispatcher boom') 'S8 the shell shows the exception through ShowFailure' "shown=$($script:shellFailMsg)"
    Check ($script:probeSeen -eq $true) 'S8 the shell handler marked the exception Handled' "Handled seen by the later handler=$($script:probeSeen)"
    Check ($win.IsVisible) 'S8 the window stays open' "IsVisible=$($win.IsVisible)"
    Check ($script:unhandledLog.Count -eq 1 -and (($script:unhandledLog.ToArray() -join ' ') -match 'shell dispatcher boom')) 'S8 the shell handler recorded exactly that exception' "recorded=$($script:unhandledLog.Count)"
    $script:unhandledLog.Clear()
    Check-NoExceptions 'S8'
}

# The element's own peer, or the peer of its nearest ancestor that has one (a StackPanel has none).
function Get-ShellNearestPeer($Element) {
    $up = $Element
    while ($null -ne $up) {
        if ($up -is [System.Windows.UIElement]) {
            $peer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($up)
            if ($null -ne $peer) { return $peer }
        }
        $up = [System.Windows.Media.VisualTreeHelper]::GetParent($up)
    }
    return $null
}

function Test-ShellPrivateUseText([string]$Text) {
    if ($Text.Length -eq 0) { return $false }
    foreach ($c in $Text.ToCharArray()) { if ([int]$c -lt 0xE000 -or [int]$c -gt 0xF8FF) { return $false } }
    return $true
}

# One decorative glyph below an element: the glyph is in the visual tree and visible, is not among the control-view peers, and the element still has a name.
function Test-ShellGlyphHidden([string]$CheckName, $Element) {
    $glyph = $null
    foreach ($n in @(Get-ShellVisuals $Element)) { if ($n -is [System.Windows.Controls.TextBlock] -and (Test-ShellPrivateUseText ([string]$n.Text))) { $glyph = $n; break } }
    $peer = Get-ShellNearestPeer $Element
    if ($null -eq $peer) { Check $false $CheckName 'no automation peer for the element or any ancestor'; return }
    $name = [string]$peer.GetName()
    $kept = @(Get-ShellControlViewPeers $peer)
    $bad = New-Object System.Collections.ArrayList
    foreach ($k in $kept) {
        Write-Host ("INFO: " + $CheckName + " control-view peer " + $k.GetType().Name + " class=" + $k.GetClassName() + " name='" + $k.GetName() + "'")
        if ($k -is [System.Windows.Automation.Peers.UIElementAutomationPeer]) {
            $o = $k.Owner
            if ($o -is [System.Windows.Controls.TextBlock] -and ((Test-ShellPrivateUseText ([string]$o.Text)) -or ($null -ne $glyph -and [object]::ReferenceEquals($o, $glyph)))) { [void]$bad.Add($k.GetType().Name + ':' + [string]$o.Text) }
        }
    }
    Write-Host ("INFO: " + $CheckName + " own peer " + $peer.GetType().Name + " name='" + $name + "' control-view peers=" + $kept.Count)
    $ok = ($null -ne $glyph) -and [bool]$glyph.IsVisible -and ($bad.Count -eq 0) -and (Test-ShellNameReadable $name)
    Check $ok $CheckName "glyphFound=$($null -ne $glyph) glyphVisible=$(if ($null -ne $glyph) { $glyph.IsVisible } else { 'n/a' }) glyphPeersInControlView=[$($bad -join ',')] name='$name'"
}

function Invoke-S9-GlyphControlView {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    Test-ShellGlyphHidden 'S9 nav item: glyph not in the UIA control view; name present' $els.NavHome
    $script:shellSnap = New-ShellSnap @{ ChildActive = $true; Step = 'model download' }
    Invoke-FastLlmUiFluentTick
    Invoke-Pump 250
    $els.StepsPanel.UpdateLayout()
    $row = $null
    $rows = @(Get-ShellStepRows $els.StepsPanel)
    if ($rows.Count -gt 0) { $row = $rows[0] }
    if ($null -eq $row) { Check $false 'S9 Home step row: mark not in the UIA control view; name present' 'the starting state produced no step rows' }
    else { Test-ShellStepRow 'S9 Home step row: mark not in the UIA control view; name present' $row }
    $script:shellSnap = New-ShellSnap
    Invoke-FastLlmUiFluentTick

    # Negative control: a plain TextBlock with a private-use glyph IS in the control view, so the walker can see glyphs at all.
    $plain = New-Object System.Windows.Controls.TextBlock
    $plain.Text = [string][char]0xE80F
    [void]$els.QuickPanel.Children.Add($plain)
    try {
        Invoke-Pump 150
        $els.QuickPanel.UpdateLayout()
        $holder = Get-ShellNearestPeer $els.QuickPanel
        $found = $false
        if ($null -ne $holder) {
            foreach ($k in @(Get-ShellControlViewPeers $holder)) {
                if ($k -is [System.Windows.Automation.Peers.UIElementAutomationPeer] -and [object]::ReferenceEquals($k.Owner, $plain)) { $found = $true }
            }
        }
        Check ($found -and [bool]$plain.IsVisible) 'S9 negative control: a plain TextBlock glyph IS in the UIA control view' "holder=$($null -ne $holder) found=$found visible=$($plain.IsVisible)"
    }
    finally { $els.QuickPanel.Children.Remove($plain) }

    # The peer of the decorative type reports neither a control nor a content element.
    $deco = New-Object Bitworks.FastLlm.DecorativeTextBlock
    $deco.Text = [string][char]0xE80F
    $dp = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($deco)
    Check ($null -ne $dp -and $dp.IsControlElement() -eq $false -and $dp.IsContentElement() -eq $false) 'S9 DecorativeTextBlock peer is neither a control nor a content element' "peer=$dp control=$(if ($null -ne $dp) { $dp.IsControlElement() }) content=$(if ($null -ne $dp) { $dp.IsContentElement() })"

    # A second load of the automation source must hit the type guard: Windows PowerShell 5.1 throws on a duplicate type.
    $typeBefore = 'Bitworks.FastLlm.DecorativeTextBlock' -as [type]
    $script:addTypeCalls = 0
    function Add-Type { $script:addTypeCalls++; Microsoft.PowerShell.Utility\Add-Type @args }
    $loadErr = ''
    try { Initialize-FastLlmUiFluentAutomation -SourceRoot $root } catch { $loadErr = $_.Exception.Message }
    Remove-Item -Path Function:\Add-Type -ErrorAction SilentlyContinue
    $typeAfter = 'Bitworks.FastLlm.DecorativeTextBlock' -as [type]
    Check ($loadErr -eq '' -and $script:addTypeCalls -eq 0 -and $null -ne $typeBefore -and [object]::ReferenceEquals($typeBefore, $typeAfter)) 'S9 a second load of the automation source hits the type guard (no Add-Type)' "error=$loadErr addTypeCalls=$($script:addTypeCalls) sameType=$([object]::ReferenceEquals($typeBefore, $typeAfter))"
    Check-NoExceptions 'S9'
}

# ======================================================================================================================
# Round B: more checks on the real shell (live regions, expander, tab order, steps peer, high contrast, split menu, pane, tray, timer, faults)
# ======================================================================================================================

function Reset-ShellState {
    $script:snapOverride = $null
    $script:failureHeld = $false
    $script:failureViewText = ''
    $script:output.Text = ''
    $script:shellSnap = New-ShellSnap
    Invoke-FastLlmUiFluentTick
}

function Invoke-S10-LiveRegions {
    if (-not $script:shellOk) { return }
    Reset-ShellState
    $c0 = Get-ShellLiveCount 'StatusDetail'
    $script:shellSnap = New-ShellSnap @{ ChildActive = $true; Step = 'serving'; RunReady = $true }
    Invoke-FastLlmUiFluentTick
    $c1 = Get-ShellLiveCount 'StatusDetail'
    Check ($c1 -eq $c0 + 1) 'S10 a composed text change (the headline) raises exactly one live-region event' "before=$c0 after=$c1"
    $script:statusLabel.Text = 'live text two'
    Invoke-FastLlmUiFluentTick
    $c2 = Get-ShellLiveCount 'StatusDetail'
    Check ($c2 -eq $c1 + 1) 'S10 a new detail text raises exactly one event' "before=$c1 after=$c2"
    $script:statusLabel.Text = 'live text two'
    Invoke-FastLlmUiFluentTick; Invoke-FastLlmUiFluentTick
    $c3 = Get-ShellLiveCount 'StatusDetail'
    Check ($c3 -eq $c2) 'S10 rewriting identical text and ticking again raises no event' "before=$c2 after=$c3"
    Reset-ShellState
    Check-NoExceptions 'S10'
}

function Invoke-S10b-FailureAnnouncement {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    Reset-ShellState
    $snapA = New-ShellSnap @{ FailureHeld = $true }
    $snapB = New-ShellSnap @{ FailureHeld = $true; SideChildActive = $true }
    $ref = @{ n = 0; cur = $snapA; a = $snapA; b = $snapB; out = $script:output }
    $script:snapOverride = $ref
    $script:failureHeld = $true
    $script:failureViewText = 'X failed'
    $script:output.Text = 'log line 0'
    $tick0 = [int]$f.Tick
    $ev0 = Get-ShellLiveCount 'FailureText'
    # A WinForms timer plays the child: each of its ticks changes the snapshot and the log text, as a running child does.
    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = 100
    $t.Add_Tick(({ $ref.n++; if (($ref.n % 2) -eq 1) { $ref.cur = $ref.b } else { $ref.cur = $ref.a }; $ref.out.Text = 'log line ' + $ref.n }).GetNewClosure())
    $script:objs.Add($t)
    $t.Start()
    try { Invoke-Pump 1700 } finally { $t.Stop() }
    $ticks = [int]$f.Tick - $tick0
    $ev = (Get-ShellLiveCount 'FailureText') - $ev0
    Check ($ticks -ge 4 -and $ev -eq 1 -and [string]$els.FailureText.Text -ceq 'X failed') 'one failure gives one assertive announcement; later 250 ms snapshot ticks do not re-announce' "shellTicks=$ticks (need 4 or more) events=$ev (expected 1) failureText='$($els.FailureText.Text)' (expected 'X failed') childTicks=$($ref.n)"
    Reset-ShellState
    Check-NoExceptions 'S10b'
}

function Invoke-S11-Expander {
    if (-not $script:shellOk) { return }
    $els = $script:FastLlmUiFluent.Els
    Reset-ShellState
    $els.ActivityExpander.IsExpanded = $false
    $script:shellSnap = New-ShellSnap @{ FailureHeld = $true }
    $script:failureHeld = $true; $script:failureViewText = 'expander check'
    Invoke-FastLlmUiFluentTick
    Check ($els.ActivityExpander.IsExpanded -eq $true) 'S11 the Activity expander opens when failureHeld flips from false to true' "IsExpanded=$($els.ActivityExpander.IsExpanded)"
    $els.ActivityExpander.IsExpanded = $false
    Invoke-FastLlmUiFluentTick; Invoke-FastLlmUiFluentTick
    Check ($els.ActivityExpander.IsExpanded -eq $false) 'S11 a collapsed expander stays collapsed on later ticks while the failure is held' "IsExpanded=$($els.ActivityExpander.IsExpanded)"
    Reset-ShellState
    $script:shellSnap = New-ShellSnap @{ FailureHeld = $true }
    $script:failureHeld = $true; $script:failureViewText = 'expander check'
    Invoke-FastLlmUiFluentTick
    Check ($els.ActivityExpander.IsExpanded -eq $true) 'S11 the next false-to-true flip opens it again' "IsExpanded=$($els.ActivityExpander.IsExpanded)"
    Reset-ShellState
    Check-NoExceptions 'S11'
}

# The suite process used WPF in Part A, long before S0, so WPF has already read and cached its accessibility switches as legacy on Windows PowerShell 5.1,
# whatever the product sets later. In-suite switch and peer results are therefore evidence only; the proof is the fresh child process in S19r.
# The step rows of the Home card, whether the panel is a plain StackPanel (Children) or an ItemsControl (Items).
function Get-ShellStepRows($Panel) {
    $rows = New-Object System.Collections.ArrayList
    if ($Panel -is [System.Windows.Controls.ItemsControl]) { foreach ($r in $Panel.Items) { [void]$rows.Add($r) } }
    else { foreach ($r in $Panel.Children) { [void]$rows.Add($r) } }
    return $rows.ToArray()
}

# The label (a TextBlock whose text is not a private-use glyph) and the mark (private-use glyph) of one step row.
function Get-ShellStepParts($Row) {
    $label = $null; $mark = $null
    foreach ($n in @(Get-ShellVisuals $Row)) {
        if ($n -is [System.Windows.Controls.TextBlock]) {
            if (Test-ShellPrivateUseText ([string]$n.Text)) { if ($null -eq $mark) { $mark = $n } }
            elseif ($null -eq $label) { $label = $n }
        }
    }
    return @{ Label = $label; Mark = $mark }
}

# A printable outline of an element's visual tree (type, name, visibility), for a failure message.
function Get-ShellTreeText($Root) {
    $lines = New-Object System.Collections.ArrayList
    $walk = $null
    $walk = {
        param($n, [int]$depth)
        $nm = ''
        if ($n -is [System.Windows.FrameworkElement]) { $nm = [string]$n.Name }
        $vis = ''
        if ($n -is [System.Windows.UIElement]) { $vis = [string]$n.Visibility + ' ' + [int]$n.ActualWidth + 'x' + [int]$n.ActualHeight }
        [void]$lines.Add((' ' * $depth) + $n.GetType().Name + $(if ($nm -ne '') { " '$nm'" }) + $(if ($vis -ne '') { " ($vis)" }))
        $c = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($n)
        for ($i = 0; $i -lt $c; $i++) { & $walk ([System.Windows.Media.VisualTreeHelper]::GetChild($n, $i)) ($depth + 1) }
    }
    & $walk $Root 0
    return ($lines.ToArray() -join ' / ')
}

function Test-ShellStepRow([string]$CheckName, $Row) {
    $parts = Get-ShellStepParts $Row
    $peer = Get-ShellNearestPeer $Row
    $kept = @()
    if ($null -ne $peer) { $kept = @(Get-ShellControlViewPeers $peer) }
    $bad = New-Object System.Collections.ArrayList
    foreach ($k in $kept) {
        Write-Host ("INFO: " + $CheckName + " control-view peer " + $k.GetType().Name + " name='" + $k.GetName() + "'")
        if ($k -is [System.Windows.Automation.Peers.UIElementAutomationPeer] -and $null -ne $parts.Mark -and [object]::ReferenceEquals($k.Owner, $parts.Mark)) { [void]$bad.Add('mark') }
    }
    $labelName = ''
    $labelText = ''
    if ($null -ne $parts.Label) { $labelText = [string]$parts.Label.Text; $labelName = Get-ShellPeerName $parts.Label }
    $ok = ($null -ne $parts.Mark) -and [bool]$parts.Mark.IsVisible -and ($bad.Count -eq 0) -and ($labelText -ne '') -and ($labelName -ceq $labelText)
    Check $ok $CheckName "markFound=$($null -ne $parts.Mark) markInControlView=$($bad.Count -gt 0) labelPeerName='$labelName' labelText='$labelText'"
}

function Get-ShellInSuiteLegacy {
    $names = @()
    try { $st = Get-FastLlmUiFluentAccessibilityState; $names = @($st.legacy) } catch { $names = @() }
    return , $names
}

function Invoke-S12-StepsPeer {
    if (-not $script:shellOk) { return }
    $els = $script:FastLlmUiFluent.Els
    $snap = New-ShellSnap @{ ChildActive = $true; Step = 'model download' }
    $script:shellSnap = $snap
    Invoke-FastLlmUiFluentTick
    Invoke-Pump 200
    $want = [string](Get-FastLlmUiCardState -Snapshot $snap).stepsText
    $summary = $els['StepsSummary']
    $peer = $null
    if ($null -ne $summary) { $peer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($summary) }
    $got = ''
    if ($null -ne $peer) { $got = [string]$peer.GetName() }
    Check ($want -ne '' -and $null -ne $peer -and $got -ceq $want) 'S12 the steps summary has a peer whose name is the composed steps text' "summary=$($null -ne $summary) peer=$($null -ne $peer) name='$got' expected='$want'"
    Reset-ShellState
    Check-NoExceptions 'S12'
}

function Invoke-S13-TabOrder {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $win = $f.Window
    Reset-ShellState
    $script:openChatButton.Enabled = $true
    $script:resultsLink.Visible = $true
    Invoke-FastLlmUiFluentTick
    $null = $win.Activate()
    Invoke-Pump 300
    $win.UpdateLayout()
    $tracked = @(
        @{ N = 'pane (Home)'; E = $els.NavHome }, @{ N = 'main action'; E = $els.InstallButton }, @{ N = 'arrow'; E = $els.MoreStartButton },
        @{ N = 'Copy address'; E = $els.CopyButton }, @{ N = 'results link'; E = $els.ResultsLink }, @{ N = 'bar link'; E = $els.BarLink },
        @{ N = 'quick action Open chat'; E = $els.OpenChatButton }, @{ N = 'quick action Connect'; E = $els.ConnectButton },
        @{ N = 'quick action Switch'; E = $els.SwitchButton }, @{ N = 'Activity'; E = $els.ActivityExpander })
    $expected = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $tracked.Count; $i++) {
        $e = $tracked[$i].E
        if ($e.IsVisible -and $e.IsEnabled -and $e.Focusable) { [void]$expected.Add($i) }
    }
    $null = $els.NavHome.Focus()
    Invoke-Pump 150
    $cur = [System.Windows.Input.Keyboard]::FocusedElement
    $homeFocused = ($null -ne $cur) -and [object]::ReferenceEquals($cur, $els.NavHome)
    Check $homeFocused 'S13 keyboard focus can be placed on the Home pane item (the window must be active for the walk)' "focused=$cur active=$($win.IsActive)"
    if ($homeFocused) {
        $seq = New-Object System.Collections.ArrayList
        $unnamed = New-Object System.Collections.ArrayList
        $last = -1
        [void]$seq.Add(0); $last = 0
        for ($step = 0; $step -lt 40; $step++) {
            $null = $cur.MoveFocus((New-Object System.Windows.Input.TraversalRequest([System.Windows.Input.FocusNavigationDirection]::Next)))
            $cur = [System.Windows.Input.Keyboard]::FocusedElement
            if ($null -eq $cur) { break }
            $idx = -1
            for ($i = 0; $i -lt $tracked.Count; $i++) {
                $e = $tracked[$i].E
                if ([object]::ReferenceEquals($e, $cur) -or $e.IsAncestorOf($cur)) { $idx = $i; break }
            }
            $name = ''
            if ($cur -is [System.Windows.UIElement]) { $name = Get-ShellPeerName $cur }
            if (-not (Test-ShellNameReadable $name) -and $idx -ge 0) { $name = Get-ShellPeerName $tracked[$idx].E }
            if (-not (Test-ShellNameReadable $name)) { [void]$unnamed.Add($cur.GetType().Name) }
            Write-Host ("INFO: S13 tab stop " + ($step + 1) + ": " + $cur.GetType().Name + " name='" + $name + "' tracked=" + $(if ($idx -ge 0) { $tracked[$idx].N } else { 'other' }))
            if ($idx -eq 0) { break }
            if ($idx -ge 0 -and $idx -ne $last) { [void]$seq.Add($idx); $last = $idx }
        }
        $got = ($seq.ToArray() | ForEach-Object { $tracked[$_].N }) -join ' > '
        $want = ($expected.ToArray() | ForEach-Object { $tracked[$_].N }) -join ' > '
        Check ($got -ceq $want) 'S13 the tab order is pane, main action, arrow, then the card links, quick actions and Activity' "walked='$got' expected='$want'"
        Check ($unnamed.Count -eq 0) 'S13 every tab stop has a non-empty automation name' "unnamed=[$($unnamed -join ',')]"
    }
    $script:openChatButton.Enabled = $false
    $script:resultsLink.Visible = $false
    Reset-ShellState
    Check-NoExceptions 'S13'
}

function Invoke-S14-HighContrast {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $win = $f.Window
    $origRead = ${function:Read-FastLlmUiSystemTheme}
    $origState = ${function:Get-FastLlmUiFluentThemeState}
    $origDict = ${function:New-FastLlmUiThemeDictionary}
    $black = @{ Window = '#000000'; WindowText = '#FFFFFF'; Highlight = '#1AEBFF'; HighlightText = '#000000' }
    $white = @{ Window = '#FFFFFF'; WindowText = '#000000'; Highlight = '#37006E'; HighlightText = '#FFFFFF' }
    $script:hcPal = $black
    # The injected high contrast: the system theme says high contrast, the theme state key carries the injected palette (the product's own key carries the real
    # system colours, which a test cannot change), and the dictionary is built from the injected palette.
    function Read-FastLlmUiSystemTheme {
        $o = & $origRead
        $o.highContrast = $true
        return $o
    }
    function Get-FastLlmUiFluentThemeState {
        $st = & $origState
        $st.Key = [string]$st.Key + '|inject:' + (($script:hcPal.Keys | Sort-Object | ForEach-Object { [string]$script:hcPal[$_] }) -join ',')
        return $st
    }
    function New-FastLlmUiThemeDictionary {
        param([string]$Theme, [hashtable]$AccentPair, [double]$TextScale = 1.0, [hashtable]$HighContrastPalette)
        if ($Theme -ceq 'high-contrast') { return & $origDict -Theme $Theme -AccentPair $AccentPair -TextScale $TextScale -HighContrastPalette $script:hcPal }
        return & $origDict -Theme $Theme -AccentPair $AccentPair -TextScale $TextScale
    }
    try {
        Update-FastLlmUiFluentTheme
        Reset-ShellState
        $dict1 = $win.Resources.MergedDictionaries[0]
        $text1 = $dict1['FastLlm.TextPrimaryBrush'].Color.ToString()
        $wantText1 = ([System.Windows.Media.ColorConverter]::ConvertFromString($black.WindowText)).ToString()
        $fill = $els.StatusDot.Fill
        $stroke = $els.StatusDot.Stroke
        $fillClear = ($null -eq $fill) -or (($fill -is [System.Windows.Media.SolidColorBrush]) -and $fill.Color.A -eq 0)
        $strokeText = ($stroke -is [System.Windows.Media.SolidColorBrush]) -and ($stroke.Color.ToString() -ceq $text1)
        $hcState = & $origState
        $sc = [System.Windows.SystemColors]
        $six = (@($sc::WindowColor, $sc::WindowTextColor, $sc::HighlightColor, $sc::HighlightTextColor, $sc::GrayTextColor, $sc::HotTrackColor) -join ',')
        Check (([string]$hcState.Choice -ceq 'high-contrast') -and ([string]$hcState.Key).Contains($six)) 'S14 the high-contrast theme key contains the six system colours' "choice=$($hcState.Choice) key=$($hcState.Key) expected to contain $six"
        Check (([string]$f.Theme -ceq 'high-contrast') -and $fillClear -and $strokeText) 'S14 in high contrast the status dot is an outline: transparent fill, stroke in the text colour' "theme=$($f.Theme) fill=$fill stroke=$stroke text=$text1"
        $script:hcPal = $white
        Update-FastLlmUiFluentTheme
        Reset-ShellState
        $dict2 = $win.Resources.MergedDictionaries[0]
        $text2 = $dict2['FastLlm.TextPrimaryBrush'].Color.ToString()
        $wantText2 = ([System.Windows.Media.ColorConverter]::ConvertFromString($white.WindowText)).ToString()
        Check (($text1 -ceq $wantText1) -and ($text2 -ceq $wantText2) -and ($text1 -cne $text2) -and -not [object]::ReferenceEquals($dict1, $dict2)) 'S14 changing the high-contrast palette rebuilds the dictionary with the new colours' "text before=$text1 (expected $wantText1) after=$text2 (expected $wantText2)"
    }
    finally {
        foreach ($fn in 'Read-FastLlmUiSystemTheme', 'Get-FastLlmUiFluentThemeState', 'New-FastLlmUiThemeDictionary') { Remove-Item -Path ('Function:\' + $fn) -ErrorAction SilentlyContinue }
        Update-FastLlmUiFluentTheme
        Reset-ShellState
    }
    Check-NoExceptions 'S14'
}

function Invoke-S15-SplitKeyboard {
    if (-not $script:shellOk) { return }
    $els = $script:FastLlmUiFluent.Els
    $more = $els.MoreStartButton
    $menu = $els.StartMenuItem.Parent
    Write-Host 'INFO: S15 Alt+Down cannot be synthesised (KeyEventArgs.SystemKey has no public setter), so the menu is opened from the arrow click; the key handler is covered by Down and Escape below'
    $more.RaiseEvent((New-ShellClick $more ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Invoke-Pump 300
    Check ($menu.IsOpen) 'S15 the split menu is open after the arrow is activated' "IsOpen=$($menu.IsOpen)"
    $src = [System.Windows.PresentationSource]::FromVisual($more)
    $threw = ''
    try {
        $ke = New-Object System.Windows.Input.KeyEventArgs([System.Windows.Input.Keyboard]::PrimaryDevice, $src, 0, [System.Windows.Input.Key]::Down)
        $ke.RoutedEvent = [System.Windows.Input.Keyboard]::KeyDownEvent
        $menu.RaiseEvent($ke)
    }
    catch { $threw = $_.Exception.Message }
    Invoke-Pump 200
    $fe = [System.Windows.Input.Keyboard]::FocusedElement
    Write-Host ("INFO: S15 after Down the keyboard focus is on " + $(if ($null -ne $fe) { $fe.GetType().Name } else { 'nothing' }) + " (a menu item is expected; a programmatically opened menu may not take focus on CI)")
    Check ($threw -eq '' -and $menu.IsOpen) 'S15 Down on the open menu raises no exception and leaves it open' "error=$threw IsOpen=$($menu.IsOpen)"
    $threw = ''
    try {
        $ke2 = New-Object System.Windows.Input.KeyEventArgs([System.Windows.Input.Keyboard]::PrimaryDevice, $src, 0, [System.Windows.Input.Key]::Escape)
        $ke2.RoutedEvent = [System.Windows.Input.Keyboard]::KeyDownEvent
        $menu.RaiseEvent($ke2)
    }
    catch { $threw = $_.Exception.Message }
    Invoke-Pump 300
    $closed = (-not $menu.IsOpen)
    if (-not $closed) { $menu.IsOpen = $false; Invoke-Pump 100 }
    Check ($threw -eq '' -and $closed) 'S15 Escape closes the split menu' "error=$threw closedByEscape=$closed"
    $fe2 = [System.Windows.Input.Keyboard]::FocusedElement
    Write-Host ("INFO: S15 after Escape keyboard focus is on " + $(if ($null -ne $fe2) { $fe2.GetType().Name } else { 'nothing' }) + "; the arrow has focus: " + [bool]$more.IsKeyboardFocused)
    Check-NoExceptions 'S15'
}

function Invoke-S16-PaneCollapse {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $win = $f.Window
    $els = $f.Els
    $later = [string]$script:FastLlmUiFluentStrings.ComingLater
    $win.Width = 800
    Invoke-Pump 800 ({ [double]$script:FastLlmUiFluent.Els.PaneColumn.Width.Value -lt 100 })
    $col = [double]$els.PaneColumn.Width.Value
    $labelsHidden = $true
    foreach ($nav in $f.NavItems) { if ($nav['Label'].Visibility -ne [System.Windows.Visibility]::Collapsed) { $labelsHidden = $false } }
    $homeTip = [string]$f.NavItems[0]['Item'].ToolTip
    $homeText = [string]$f.NavItems[0]['Text']
    $disabledTip = [string]$f.NavItems[1]['Item'].ToolTip
    Check ($col -lt 100 -and $labelsHidden -and $homeTip -ceq $homeText -and $disabledTip -ceq $later) 'S16 below 900 wide the pane collapses: narrow column, labels hidden, Home tooltip is its label, disabled items keep their tooltip' "column=$col labelsHidden=$labelsHidden homeTip='$homeTip' (expected '$homeText') disabledTip='$disabledTip' (expected '$later') width=$($win.ActualWidth)"
    $win.Width = 1000
    Invoke-Pump 800 ({ [double]$script:FastLlmUiFluent.Els.PaneColumn.Width.Value -gt 100 })
    $col2 = [double]$els.PaneColumn.Width.Value
    $labelsShown = $true
    foreach ($nav in $f.NavItems) { if ($nav['Label'].Visibility -ne [System.Windows.Visibility]::Visible) { $labelsShown = $false } }
    $disabledTip2 = [string]$f.NavItems[1]['Item'].ToolTip
    Check ($col2 -gt 100 -and $labelsShown -and $null -eq $f.NavItems[0]['Item'].ToolTip -and $disabledTip2 -ceq $later) 'S16 at 900 and above the pane expands again: wide column, labels shown, no Home tooltip' "column=$col2 labelsShown=$labelsShown homeTip='$($f.NavItems[0]['Item'].ToolTip)' disabledTip='$disabledTip2' width=$($win.ActualWidth)"
    Check-NoExceptions 'S16'
}

# One tray-menu keyboard run: a strip as the classic tray builds it, shown, then Down and Enter POSTED to its handle (SendMessage skips the message
# loop, so the ToolStrip key handling would never run). $Mode 'winforms' runs a real WinForms loop; 'dispatcher' pumps the shell's Dispatcher.
function Step-ShellRun2([hashtable]$Counter) { $Counter.n++ }
function Invoke-TrayVariant([string]$Mode) {
    $ref = @{ n = 0 }
    $script:trayRef = $ref
    $strip = New-Object System.Windows.Forms.ContextMenuStrip
    $first = $strip.Items.Add('Restore FastLLM')
    $null = $strip.Items.Add('Stop inference / download')
    $first.Add_Click({ Step-ShellRun2 $script:trayRef })
    $nat = $script:native
    $err = ''
    try {
        if ($Mode -ceq 'winforms') {
            $ctx = New-Object System.Windows.Forms.Form
            $ctx.ShowInTaskbar = $false; $ctx.Opacity = 0; $ctx.StartPosition = 'Manual'
            $ctx.Location = New-Object System.Drawing.Point(-32000, -32000); $ctx.Size = New-Object System.Drawing.Size(50, 50)
            $st = @{ stage = 0 }
            $t = New-Object System.Windows.Forms.Timer
            $t.Interval = 150
            $t.Add_Tick(({
                $st.stage++
                if ($st.stage -eq 1) { $strip.Show((New-Object System.Drawing.Point(40, 40))) }
                elseif ($st.stage -eq 3) { $null = $nat::PostMessage($strip.Handle, [uint32]0x0100, [IntPtr]0x28, [IntPtr]::Zero) }
                elseif ($st.stage -eq 5) { $null = $nat::PostMessage($strip.Handle, [uint32]0x0100, [IntPtr]0x0D, [IntPtr]::Zero) }
                elseif ($st.stage -ge 9) { $t.Stop(); $ctx.Close() }
            }).GetNewClosure())
            $dead = New-Object System.Windows.Forms.Timer
            $dead.Interval = 6000
            $dead.Add_Tick(({ $dead.Stop(); $t.Stop(); $ctx.Close() }).GetNewClosure())
            $dead.Start(); $t.Start()
            try { [System.Windows.Forms.Application]::Run($ctx) } finally { $t.Dispose(); $dead.Dispose(); $ctx.Dispose() }
        }
        else {
            $strip.Show((New-Object System.Drawing.Point(40, 40)))
            Invoke-Pump 400
            $null = $nat::PostMessage($strip.Handle, [uint32]0x0100, [IntPtr]0x28, [IntPtr]::Zero)
            Invoke-Pump 300
            $null = $nat::PostMessage($strip.Handle, [uint32]0x0100, [IntPtr]0x0D, [IntPtr]::Zero)
            Invoke-Pump 500
        }
    }
    catch { $err = $_.Exception.Message }
    try { $strip.Close() } catch { $null = $_ }
    $strip.Dispose()
    return @{ ok = ($err -eq '' -and $ref.n -eq 1); clicks = $ref.n; error = $err }
}

function Invoke-S17-TrayKeyboard {
    $a = Invoke-TrayVariant 'winforms'
    $b = Invoke-TrayVariant 'dispatcher'
    $c = @{ ok = $false; clicks = 0; error = '' }
    try {
        Add-Type -AssemblyName WindowsFormsIntegration
        [System.Windows.Forms.Integration.WindowsFormsHost]::EnableWindowsFormsInterop()
        $c = Invoke-TrayVariant 'dispatcher'
    }
    catch { $c = @{ ok = $false; clicks = 0; error = $_.Exception.Message } }
    $word = { param($r) if ($r.ok) { 'pass' } else { 'fail' } }
    Write-Host ("INFO: S17 tray keyboard control=" + (& $word $a) + " dispatcher=" + (& $word $b) + " dispatcher+interop=" + (& $word $c))
    Write-Host ("INFO: S17 details control clicks=" + $a.clicks + " error='" + $a.error + "'; dispatcher clicks=" + $b.clicks + " error='" + $b.error + "'; dispatcher+interop clicks=" + $c.clicks + " error='" + $c.error + "'")
    Check $a.ok 'S17 control: under a real WinForms loop, Down then Enter (PostMessage to the strip) runs the first tray item' "clicks=$($a.clicks) expected=1 error=$($a.error) (if this fails the test itself is not valid: do not read (b) as a product result)"
    if ($a.ok) { Check $b.ok 'S17 under the shell Dispatcher.Run (no interop), Down then Enter (PostMessage to the strip) runs the first tray item' "clicks=$($b.clicks) expected=1 error=$($b.error)" }
    else { Write-Host 'INFO: S17 the control failed, so the dispatcher result is not counted as a product result' }
    Check-NoExceptions 'S17'
}

function Invoke-S18-WinFormsTimer {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    # under the shell loop
    $st = @{ n = 0 }
    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = 50
    $t.Add_Tick(({ $st.n++ }).GetNewClosure())
    $script:objs.Add($t)
    $t.Start()
    try { Invoke-Pump 900 } finally { $t.Stop() }
    Check ($st.n -ge 3) 'S18 a WinForms Timer ticks under the real shell loop' "ticks=$($st.n) expected 3 or more"
    # inside a nested ShowDialog, with a deadline so a stuck dialog fails
    $d = @{ n = 0; timedOut = $false }
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'FastLLM shell timer ' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $dlg.StartPosition = 'Manual'; $dlg.ShowInTaskbar = $false
    $dlg.Location = New-Object System.Drawing.Point(-32000, -32000)
    $dlg.Size = New-Object System.Drawing.Size(200, 100)
    $t2 = New-Object System.Windows.Forms.Timer; $t2.Interval = 50
    $t3 = New-Object System.Windows.Forms.Timer; $t3.Interval = 5000
    $t2.Add_Tick(({ $d.n++; if ($d.n -ge 4) { $t2.Stop(); $dlg.Close() } }).GetNewClosure())
    $t3.Add_Tick(({ $t3.Stop(); $d.timedOut = $true; $dlg.Close() }).GetNewClosure())
    $dlg.Add_Shown(({ $t2.Start() }).GetNewClosure())
    try { $t3.Start(); $null = $dlg.ShowDialog($script:form) } finally { $t2.Dispose(); $t3.Dispose(); $dlg.Dispose() }
    Check ($d.n -ge 4 -and -not $d.timedOut) 'S18 a WinForms Timer ticks inside a nested ShowDialog' "ticks=$($d.n) timedOut=$($d.timedOut)"
    # a throw in a tick reaches the fluent ThreadException handler and opens no dialog
    $f.LastException = $null
    $script:shellFailMsg = ''
    $forms0 = [System.Windows.Forms.Application]::OpenForms.Count
    $t4 = New-Object System.Windows.Forms.Timer
    $t4.Interval = 50
    $t4.Add_Tick(({ $t4.Stop(); throw 'winforms timer boom' }).GetNewClosure())
    $script:objs.Add($t4)
    $t4.Start()
    try { Invoke-Pump 2500 ({ $null -ne $script:FastLlmUiFluent.LastException }) } finally { $t4.Stop() }
    Invoke-Pump 300
    $forms1 = [System.Windows.Forms.Application]::OpenForms.Count
    $recorded = ($null -ne $f.LastException) -and (([string]$f.LastException.ToString()) -match 'winforms timer boom')
    Check ($recorded -and ($script:shellFailMsg -match 'winforms timer boom') -and $forms1 -eq $forms0) 'S18 a throw in a WinForms Timer tick reaches the fluent ThreadException handler and opens no dialog' "recorded=$recorded shown='$($script:shellFailMsg)' openForms before=$forms0 after=$forms1"
    $shellSaw = @($script:unhandledLog.ToArray())
    Check ($shellSaw.Count -eq 1 -and ($shellSaw -join ' ') -match 'winforms timer boom') 'S18 the shell recorded exactly that one ThreadException' "count=$($shellSaw.Count)"
    $mine = @($script:threadEx.ToArray())
    Check ($mine.Count -eq 0) 'S18 after the shell starts the suite ThreadException recorder no longer receives it (the add replaces the thread single handler)' "suite recorder saw $($mine.Count)"
    $script:threadEx.Clear(); $script:unhandledLog.Clear()
    Check-NoExceptions 'S18'
}

function Invoke-S19-StepsEvidence {
    if (-not $script:shellOk) { return }
    $els = $script:FastLlmUiFluent.Els
    # N2 evidence: the WPF accessibility switches this runtime holds
    $switches = New-Object System.Collections.ArrayList
    $legacy = New-Object System.Collections.ArrayList
    foreach ($asm in @([System.Windows.UIElement].Assembly, [System.Windows.DependencyObject].Assembly, [System.Windows.Controls.Button].Assembly)) {
        $types = @()
        try { $types = @($asm.GetTypes()) } catch [System.Reflection.ReflectionTypeLoadException] { $types = @($_.Exception.Types | Where-Object { $null -ne $_ }) } catch { $types = @() }
        foreach ($t in $types) {
            if ($t.Name -like '*AccessibilitySwitches') {
                $flags = [System.Reflection.BindingFlags]'Static,Public,NonPublic'
                foreach ($pr in $t.GetProperties($flags)) {
                    $val = '(unreadable)'
                    try { $val = [string]$pr.GetValue($null, $null) } catch { $null = $_ }
                    [void]$switches.Add($t.FullName + '.' + $pr.Name + '=' + $val)
                    if ($pr.PropertyType -eq [bool] -and $pr.Name -match 'Legacy|DoesNotSupport') { [void]$legacy.Add(@{ Name = $pr.Name; Value = $val; Bool = $true }) }
                }
                foreach ($fl in $t.GetFields($flags)) {
                    $val = '(unreadable)'
                    try { $val = [string]$fl.GetValue($null) } catch { $null = $_ }
                    [void]$switches.Add($t.FullName + '.' + $fl.Name + '=' + $val)
                    if ($fl.Name -match '^_useLegacyAccessibilityFeatures[1-5]?$|^_ItemsControlDoesNotSupportAutomation$') { [void]$legacy.Add(@{ Name = $fl.Name; Value = $val; Bool = $false }) }
                }
            }
        }
    }
    $badSw = New-Object System.Collections.ArrayList
    foreach ($l in $legacy) {
        if ($l.Bool) { if ($l.Value -cne 'False') { [void]$badSw.Add($l.Name + '=' + $l.Value) } }
        elseif ($l.Value -cne '-1') { [void]$badSw.Add($l.Name + '=' + $l.Value) }
    }
    Write-Host ("INFO: S19 in-suite switches (cached before the product could set them; the proof is S19r): found=" + $legacy.Count + " legacy-looking=[" + ($badSw -join ', ') + "]")
    foreach ($sw in $switches) { Write-Host ("INFO: S19 accessibility switch " + $sw) }
    if ($switches.Count -eq 0) { Write-Host 'INFO: S19 no type named *AccessibilitySwitches was found in WindowsBase, PresentationCore or PresentationFramework' }
    foreach ($name in 'Switch.UseLegacyAccessibilityFeatures', 'Switch.UseLegacyAccessibilityFeatures.2', 'Switch.UseLegacyAccessibilityFeatures.3') {
        $v = $false
        $known = $false
        try { $known = [AppContext]::TryGetSwitch($name, [ref]$v) } catch { $known = $false }
        Write-Host ("INFO: S19 AppContext " + $name + " set=" + $known + " value=" + $v)
    }
    Write-Host ("INFO: S19 runtime " + $PSVersionTable.PSVersion + " clr " + [Environment]::Version + " " + [System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription)
    $snap = New-ShellSnap @{ ChildActive = $true; Step = 'model download' }
    $script:shellSnap = $snap
    Invoke-FastLlmUiFluentTick
    Invoke-Pump 250
    $peer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($els.StepsPanel)
    Write-Host ("INFO: S19 steps panel " + $els.StepsPanel.GetType().Name + " peer present=" + ($null -ne $peer))
    # step rows: each label TextBlock's UIA name is its text (TextBlock peers do not depend on the accessibility switches)
    $bad = New-Object System.Collections.ArrayList
    $count = 0
    foreach ($row in @(Get-ShellStepRows $els.StepsPanel)) {
        $count++
        $parts = Get-ShellStepParts $row
        $labelText = ''; $name = ''
        if ($null -ne $parts.Label) { $labelText = [string]$parts.Label.Text; $name = Get-ShellPeerName $parts.Label }
        Write-Host ("INFO: S19 step row label='" + $labelText + "' label peer name='" + $name + "'")
        if ($labelText -eq '' -or $name -cne $labelText -or $name -match '^System\.|StackPanel|TextBlock|ContentPresenter') { [void]$bad.Add("name='$name' label='$labelText'") }
    }
    Check ($count -ge 1 -and $bad.Count -eq 0) 'S19 every step row label has its text as its UIA name (for example "Model, in progress"), never a type name' "rows=$count bad=[$($bad -join '; ')]"
    Reset-ShellState
    Check-NoExceptions 'S19'
}

# S19r: the proof in a fresh process, in the startup order of fast-llm-ui.ps1 (its lines 1-34: the assembly loads and dot-sources, then the shell file),
# without the administrator refusal (CI is elevated) and without the lab-app lifetime. Each shell runs its own leg with its own executable.
$script:s19rChild = @'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
__PRE__
$root = '__ROOT__'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force
. (Join-Path $root 'src/FastLlm.UiFlow.ps1')
. (Join-Path $root 'src/FastLlm.UiPrerequisite.ps1')
. (Join-Path $root 'src/FastLlm.UiBackground.ps1')
. (Join-Path $root 'src/FastLlm.UiState.ps1')
. (Join-Path $root 'src/FastLlm.Update.ps1')
. (Join-Path $root 'src/FastLlm.Components.ps1')
. (Join-Path $root 'src/FastLlm.ServingSettings.ps1')
. (Join-Path $root 'src/FastLlm.SignInStart.ps1')
. (Join-Path $root 'src/FastLlm.SupportBundle.ps1')
. (Join-Path $root 'src/FastLlm.ConnectInfo.ps1')
& (Get-Module FastLlm) { Initialize-FastLlmProcessHost }
. (Join-Path $root 'src/FastLlm.UiFluentShell.ps1')
$support = Test-FastLlmUiFluentHost
$out = [ordered]@{ supported = [bool]$support.supported; reason = [string]$support.reason; edition = [string]$PSVersionTable.PSEdition; productLegacy = @(); copies = @(); fields = @{}; modern = $false
    itemsControlPeer = $false; listBoxPeer = $false }
$cmd = Get-Command Get-FastLlmUiFluentAccessibilityState -ErrorAction SilentlyContinue
if ($null -ne $cmd) { $st = Get-FastLlmUiFluentAccessibilityState; $out.productLegacy = @($st.legacy); $out['productTypeFound'] = [bool]$st.typeFound }
# "modern": every static bool property of every copy of the AccessibilitySwitches class (WindowsBase, PresentationCore, PresentationFramework) reads False.
# The backing fields stay 0 until first read, so they are listed as evidence only.
$bad = 0
$seen = 0
$copies = New-Object System.Collections.ArrayList
$flags = [System.Reflection.BindingFlags]'Static,Public,NonPublic'
foreach ($asm in @([System.Windows.UIElement].Assembly, [System.Windows.DependencyObject].Assembly, [System.Windows.Controls.Button].Assembly)) {
    $types = @()
    try { $types = @($asm.GetTypes()) } catch [System.Reflection.ReflectionTypeLoadException] { $types = @($_.Exception.Types | Where-Object { $null -ne $_ }) }
    foreach ($t in $types) {
        if ($t.Name -ne 'AccessibilitySwitches') { continue }
        [void]$copies.Add($asm.GetName().Name + ':' + $t.FullName)
        foreach ($fl in $t.GetFields($flags)) { $out.fields[$asm.GetName().Name + '.' + $fl.Name] = [string]$fl.GetValue($null) }
        foreach ($pr in $t.GetProperties($flags)) {
            if ($pr.PropertyType -ne [bool]) { continue }
            $v = [string]$pr.GetValue($null, $null)
            $out.fields[$asm.GetName().Name + '.' + $pr.Name] = $v
            $seen++
            if ($v -cne 'False') { $bad++ }
        }
    }
}
$out.copies = @($copies.ToArray())
$out.modern = ($seen -gt 0 -and $bad -eq 0 -and @($out.productLegacy).Count -eq 0)
$ic = New-Object System.Windows.Controls.ItemsControl
[void]$ic.Items.Add('one'); [void]$ic.Items.Add('two')
$out.itemsControlPeer = ($null -ne [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($ic))
$lb = New-Object System.Windows.Controls.ListBox
[void]$lb.Items.Add('one'); [void]$lb.Items.Add('two')
$out.listBoxPeer = ($null -ne [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($lb))
Write-Output ('S19R-JSON ' + ($out | ConvertTo-Json -Compress -Depth 4))
'@

# The variant child sets the switches as its very first statement, before any dot-source (evidence only: does timing matter).
$script:s19rFirst = "foreach (`$n in 'Switch.UseLegacyAccessibilityFeatures', 'Switch.UseLegacyAccessibilityFeatures.2', 'Switch.UseLegacyAccessibilityFeatures.3', 'Switch.UseLegacyAccessibilityFeatures.4', 'Switch.UseLegacyAccessibilityFeatures.5', 'Switch.UseLegacyToolTipDisplay', 'Switch.System.Windows.Controls.ItemsControlDoesNotSupportAutomation', 'Switch.System.Windows.Controls.OptOutOfGridColumnResizeUsingKeyboard') { [System.AppContext]::SetSwitch(`$n, `$false) }"

function Invoke-S19rChild([string]$Variant, [string]$Pre) {
    $exe = (Get-Process -Id $PID).Path
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('fastllm-s19r-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    $file = Join-Path $dir 'child.ps1'
    [System.IO.File]::WriteAllText($file, $script:s19rChild.Replace('__PRE__', $Pre).Replace('__ROOT__', $root.Replace("'", "''")), (New-Object System.Text.UTF8Encoding($false)))
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = '-STA -NoLogo -NoProfile -File "' + $file + '"'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['FASTLLM_TESTS_NO_BENCH'] = '1'
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $script:s19rProc = $p
    $null = $p.Start()
    $ownPid = $p.Id
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    Invoke-Pump 60000 ({ $script:s19rProc.HasExited })
    $timedOut = -not $p.HasExited
    if ($timedOut) { try { $p.Kill() } catch { $null = $_ }; $null = $p.WaitForExit(5000) }
    $text = ''; $errText = ''
    try { $text = [string]$outTask.Result; $errText = [string]$errTask.Result } catch { $null = $_ }
    $json = $null
    foreach ($line in ($text -split "`r?`n")) { if ($line.StartsWith('S19R-JSON ')) { $json = $line.Substring(10) } }
    $r = $null
    if ($null -ne $json) { try { $r = $json | ConvertFrom-Json } catch { $r = $null } }
    Write-Host ("INFO: S19r " + $Variant + " child pid " + $ownPid + " exit " + $(if ($timedOut) { 'timed out and killed' } else { $p.ExitCode }) + " result: " + $(if ($null -ne $json) { $json } else { '(none)' }))
    $script:s19rProc = $null
    return @{ r = $r; text = $text; err = $errText; timedOut = $timedOut; code = $(if ($timedOut) { 'timeout' } else { $p.ExitCode }) }
}

function Invoke-S19r-FreshProcess {
    $edition = if ($PSVersionTable.PSVersion.Major -le 5) { 'Windows PowerShell 5.1' } else { 'PowerShell 7' }
    $real = Invoke-S19rChild 'real-order' ''
    $r = $real.r
    $name = "S19r $edition fresh process, startup order of fast-llm-ui.ps1: supported, every accessibility switch property reads False in every copy of the class"
    if ($null -eq $r) { Check $false $name ("no result line; exit=" + $real.code + " stderr=" + $real.err + " stdout=" + $real.text) }
    else {
        Check (($r.supported -eq $true) -and ($r.modern -eq $true)) $name ("supported=$($r.supported) reason=$($r.reason) modern=$($r.modern) copies=[$(@($r.copies) -join ',')] productLegacy=[$(@($r.productLegacy) -join ',')] fields=$($r.fields | ConvertTo-Json -Compress)")
        Write-Host ("INFO: S19r " + $edition + " real-order ItemsControl peer=" + $r.itemsControlPeer + " ListBox peer=" + $r.listBoxPeer + " (evidence, not asserted)")
    }
    $first = Invoke-S19rChild 'switches-first' $script:s19rFirst
    if ($null -ne $first.r) { Write-Host ("INFO: S19r " + $edition + " switches-first modern=" + $first.r.modern + " ItemsControl peer=" + $first.r.itemsControlPeer + " ListBox peer=" + $first.r.listBoxPeer) }
    else { Write-Host ("INFO: S19r " + $edition + " switches-first child gave no result; exit=" + $first.code + " stderr=" + $first.err) }
    Check-NoExceptions 'S19r'
}

function Invoke-S20-MessageArea {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $win = $f.Window
    $els = $f.Els
    $origRead = ${function:Read-FastLlmUiSystemTheme}
    function Read-FastLlmUiSystemTheme {
        $o = & $origRead
        $o.textScaleFactor = 225
        return $o
    }
    $long = ('Engine start failed while loading the model. ' * 10).Substring(0, 400)
    try {
        Update-FastLlmUiFluentTheme
        $win.Width = 640
        $win.Height = 480
        $script:bannerLabel.Text = 'An update to FastLLM is available.'
        $script:bannerLabel.Visible = $true
        $script:shellSnap = New-ShellSnap @{ FailureHeld = $true }
        $script:failureHeld = $true
        $script:failureViewText = $long
        Invoke-FastLlmUiFluentTick
        Invoke-Pump 800
        $win.UpdateLayout()
        Invoke-FastLlmUiFluentTick
        Invoke-Pump 300
        $sv = $els.MessageScroll
        $h = [double]$win.ActualHeight
        $want = $h * 0.4
        Check ($h -gt 0 -and [Math]::Abs([double]$sv.MaxHeight - $want) -lt 1.0) 'S20 at 640x480 the message area is capped at 40 percent of the window height' "MaxHeight=$($sv.MaxHeight) expected=$want windowHeight=$h width=$($win.ActualWidth)"
        Check ([double]$sv.ScrollableHeight -gt 0) 'S20 with a 400-character failure at text 2.25 the message area scrolls inside its cap' "ScrollableHeight=$($sv.ScrollableHeight) ExtentHeight=$($sv.ExtentHeight) ViewportHeight=$($sv.ViewportHeight)"
    }
    finally {
        Remove-Item -Path Function:\Read-FastLlmUiSystemTheme -ErrorAction SilentlyContinue
        $win.Width = 1000
        $win.Height = 680
        $script:bannerLabel.Visible = $false
        Update-FastLlmUiFluentTheme
        Reset-ShellState
        Invoke-Pump 300
    }
    Check-NoExceptions 'S20'
}

function Invoke-S21-ExpanderTemplate {
    if (-not $script:shellOk) { return }
    $els = $script:FastLlmUiFluent.Els
    $exp = $els.ActivityExpander
    Reset-ShellState
    $exp.IsExpanded = $false
    Invoke-Pump 200
    $exp.UpdateLayout()
    $toggle = $exp.Template.FindName('Hd', $exp)
    Check ($null -ne $toggle) 'S21 the Expander template has its header toggle (Hd)' 'FindName Hd returned null'
    if ($null -ne $toggle) {
        # a click on the header: ButtonBase.OnClick toggles and raises Click
        $onClick = [System.Windows.Controls.Primitives.ButtonBase].GetMethod('OnClick', [System.Reflection.BindingFlags]'NonPublic,Instance')
        $null = $onClick.Invoke($toggle, @())
        Invoke-Pump 150
        Check ($exp.IsExpanded -eq $true) 'S21 a click on the header expands the Expander' "IsExpanded=$($exp.IsExpanded)"
        $null = $onClick.Invoke($toggle, @())
        Invoke-Pump 150
        Check ($exp.IsExpanded -eq $false) 'S21 a second click collapses it' "IsExpanded=$($exp.IsExpanded)"
        # the keyboard: Space on the focused header toggles it (Enter is recorded)
        $null = $toggle.Focus()
        Invoke-Pump 150
        if ($toggle.IsKeyboardFocused) {
            $src = [System.Windows.PresentationSource]::FromVisual($toggle)
            foreach ($key in [System.Windows.Input.Key]::Space, [System.Windows.Input.Key]::Return) {
                $before = $exp.IsExpanded
                $kd = New-Object System.Windows.Input.KeyEventArgs([System.Windows.Input.Keyboard]::PrimaryDevice, $src, 0, $key)
                $kd.RoutedEvent = [System.Windows.Input.Keyboard]::KeyDownEvent
                $toggle.RaiseEvent($kd)
                $ku = New-Object System.Windows.Input.KeyEventArgs([System.Windows.Input.Keyboard]::PrimaryDevice, $src, 0, $key)
                $ku.RoutedEvent = [System.Windows.Input.Keyboard]::KeyUpEvent
                $toggle.RaiseEvent($ku)
                Invoke-Pump 150
                $changed = ($exp.IsExpanded -ne $before)
                if ($key -eq [System.Windows.Input.Key]::Space) { Check $changed 'S21 Space on the focused header toggles the Expander' "before=$before after=$($exp.IsExpanded)" }
                else { Write-Host ("INFO: S21 Enter on the header toggled it: " + $changed) }
                if ($changed -and $key -eq [System.Windows.Input.Key]::Space) { $exp.IsExpanded = $before }
            }
        }
        else { Write-Host 'INFO: S21 the header could not take keyboard focus here (window not active), so the Space and Enter checks were skipped' }
    }
    $exp.IsExpanded = $false
    $peer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($exp)
    $pattern = $null
    if ($null -ne $peer) { $pattern = $peer.GetPattern([System.Windows.Automation.Peers.PatternInterface]::ExpandCollapse) }
    Check ($null -ne $pattern) 'S21 the Expander peer supports the ExpandCollapse pattern' "peer=$($null -ne $peer) pattern=$($null -ne $pattern)"
    if ($null -ne $pattern) {
        $ec = [System.Windows.Automation.Provider.IExpandCollapseProvider]$pattern
        $ec.Expand()
        Invoke-Pump 100
        $afterExpand = $exp.IsExpanded
        $ec.Collapse()
        Invoke-Pump 100
        Check ($afterExpand -eq $true -and $exp.IsExpanded -eq $false) 'S21 Expand() and Collapse() through the pattern change IsExpanded' "after Expand=$afterExpand after Collapse=$($exp.IsExpanded)"
    }
    Reset-ShellState
    Check-NoExceptions 'S21'
}

# Faults are injected last: each Initialize run replaces the shell state, so nothing after these may use the real shell.
function Invoke-S99-StartupFaults {
    if (-not $script:shellOk) { return }
    try { $script:FastLlmUiFluent.Timer.Stop() } catch { $null = $_ }
    $script:stopSeen = ''
    function Stop-FastLlmUiFluentStartup { param([string]$Reason) $script:stopSeen = $Reason; throw "startup stopped: $Reason" }
    # a fault in a step after the markup parsed
    Initialize-ShellEnv
    function Get-FastLlmUiFluentElement { param($Root, [string]$Name) throw 'injected element fault' }
    $err = ''
    try { Initialize-FastLlmUiFluentShell } catch { $err = $_.Exception.Message }
    Remove-Item -Path Function:\Get-FastLlmUiFluentElement -ErrorAction SilentlyContinue
    Check ($script:stopSeen -ceq 'xaml-parse') 'S99 a fault after the XAML parse stops the startup with xaml-parse (text C)' "stopReason='$($script:stopSeen)' error='$err'"
    # a hook failure
    $script:stopSeen = ''
    Initialize-ShellEnv
    function Register-FastLlmUiWindowHooks { param($Window, $Form, $OnThemeChanged) return @{ hooked = $false; error = 'x' } }
    $err = ''
    try { Initialize-FastLlmUiFluentShell } catch { $err = $_.Exception.Message }
    Remove-Item -Path Function:\Register-FastLlmUiWindowHooks -ErrorAction SilentlyContinue
    Check ($script:stopSeen -ceq 'theme-init') 'S99 a window-hook failure stops the startup with theme-init (text C)' "stopReason='$($script:stopSeen)' error='$err'"
    try { $script:FastLlmUiFluent.Timer.Stop() } catch { $null = $_ }
    Check-NoExceptions 'S99'
}

# B2 additions that need no shell
function Invoke-H8-HookWithoutFormState {
    $s = New-Scn 'h8'; $w = $s.Window
    $null = Register-FastLlmUiWindowHooks -Window $w -Form ([pscustomobject]@{}) -OnThemeChanged { }
    Show-Scn $s
    $de = $script:dispEx
    $r = $script:native::SendMessage($s.Hwnd, [uint32]0x0011, [IntPtr]::Zero, [IntPtr]::Zero).ToInt64()
    Invoke-Pump 600 ({ $de.Count -ge 1 }).GetNewClosure()
    Invoke-Pump 200
    $msgs = @($script:dispEx.ToArray())
    Check ($r -eq 0) 'H8 a form without FastLlmFormState refuses WM_QUERYENDSESSION (returns 0)' "result=$r expected=0"
    Check ($msgs.Count -eq 1) 'H8 exactly one dispatcher exception is recorded for it' "count=$($msgs.Count) text=$($msgs -join ' | ')"
    $script:dispEx.Clear()
    Unregister-FastLlmUiWindowHooks -Window $w
    Check-NoExceptions 'H8'
}

# The trailing-ampersand oracle: WinForms' own measurement. The raw text with prefix processing must measure like the display text without it.
function Invoke-H9-DisplayTextOracle {
    $font = New-Object System.Drawing.Font('Segoe UI', [single]10)
    $script:objs.Add($font)
    $big = New-Object System.Drawing.Size([int]::MaxValue, [int]::MaxValue)
    $raw = [System.Windows.Forms.TextFormatFlags]::NoPadding
    $plain = [System.Windows.Forms.TextFormatFlags]::NoPadding -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix
    foreach ($text in 'a&', 'a&&b', '&x', 'Install && start') {
        $display = ConvertTo-FastLlmUiDisplayText -Text $text -UseMnemonic $true
        $w1 = [System.Windows.Forms.TextRenderer]::MeasureText($text, $font, $big, $raw).Width
        $w2 = [System.Windows.Forms.TextRenderer]::MeasureText($display, $font, $big, $plain).Width
        Write-Host ("INFO: H9 '" + $text + "' -> display '" + $display + "' widths raw(prefix on)=" + $w1 + " display(NoPrefix)=" + $w2)
        Check ($w1 -eq $w2) "H9 display text for '$text' measures like what WinForms shows" "raw width=$w1 display width=$w2 display='$display'"
    }
}

$script:steps = @(
    'Invoke-A1-CloseCancelled', 'Invoke-A1c-CloseCancelledClosure', 'Invoke-A2-CloseAllowed', 'Invoke-A3-BoxNo', 'Invoke-A4-BoxYes', 'Invoke-A5-CloseInsideHandler',
    'Invoke-A6-ThrowingHandler', 'Invoke-A7-Visible', 'Invoke-A8-RestoreFromTray', 'Invoke-A9-Shown', 'Invoke-A10-Owner',
    'Invoke-A11-ScreenGap', 'Invoke-A12-SessionEnd', 'Invoke-A12b-SessionEndPlain', 'Invoke-A13-Members', 'Invoke-A14-LeakyHandler',
    'Invoke-B1-GdiLeak', 'Invoke-B2-IconSizes', 'Invoke-B3-AppIcon', 'Invoke-B4-ThemeHook', 'Invoke-B5-SettingChangeString',
    'Invoke-B6-HookFailure', 'Invoke-B7-Unregister',
    'Invoke-H1-ReentrantQuery', 'Invoke-H2-ThrowingQuery', 'Invoke-H3-UnregisterOnClosed', 'Invoke-H4-ThemeCallbackThrows', 'Invoke-H5-EndSession',
    'Invoke-H6-PassThrough', 'Invoke-H7-DpiEvidence', 'Invoke-H8-HookWithoutFormState', 'Invoke-H9-DisplayTextOracle',
    # S0 enters the shell's message loop; every step after it runs inside that loop's frame
    'Invoke-S0-ShellStart', 'Invoke-S1-Shown', 'Invoke-S2-Bindings', 'Invoke-S3-HomeParity', 'Invoke-S4-Resources', 'Invoke-S5-SplitMenu', 'Invoke-S6-Nav',
    'Invoke-S7-ShellTheme', 'Invoke-S8-DispatcherHandler', 'Invoke-S9-GlyphControlView',
    'Invoke-S10-LiveRegions', 'Invoke-S10b-FailureAnnouncement', 'Invoke-S11-Expander', 'Invoke-S12-StepsPeer', 'Invoke-S13-TabOrder', 'Invoke-S14-HighContrast',
    'Invoke-S15-SplitKeyboard', 'Invoke-S16-PaneCollapse', 'Invoke-S18-WinFormsTimer',
    'Invoke-S19-StepsEvidence', 'Invoke-S19r-FreshProcess', 'Invoke-S20-MessageArea', 'Invoke-S21-ExpanderTemplate', 'Invoke-S17-TrayKeyboard', 'Invoke-S99-StartupFaults'
)

$tick = New-Object System.Windows.Threading.DispatcherTimer
$tick.Interval = [TimeSpan]::FromMilliseconds(50)
$script:tick = $tick
$deadline = New-Object System.Windows.Threading.DispatcherTimer
$deadline.Interval = [TimeSpan]::FromSeconds(240)
$script:deadline = $deadline

$tick.Add_Tick({
    if ($script:busy -or $script:loopStopped) { return }
    $script:busy = $true
    try {
        if ($script:si -ge $script:steps.Count) { Stop-ShellLoop; return }
        $name = $script:steps[$script:si]
        $script:si++
        Write-Host "INFO: step $name started"
        try { $null = & $name }
        catch { $script:fail++; Write-Host "FAIL: step $name threw -- $($_.Exception.ToString())" }
        if ($script:si -ge $script:steps.Count) { Stop-ShellLoop }
    }
    finally { $script:busy = $false }
})
$deadline.Add_Tick({
    $script:deadline.Stop()
    $where = if ($script:si -gt 0 -and $script:si -le $script:steps.Count) { $script:steps[$script:si - 1] } else { 'before the first step' }
    Write-Host "FAIL: the 240 s suite deadline was hit during step $where"
    # a step may be stuck in a modal loop: ending the process is the only way out and it must not hang CI
    [Environment]::Exit(1)
})

# Kept in a variable so the dispatcher-handler check (S8) can take it off while it looks at the shell's own handler.
$script:dispHandler = [System.Windows.Threading.DispatcherUnhandledExceptionEventHandler] { param($s, $e) $script:dispEx.Add($e.Exception.ToString()); $e.Handled = $true }
[System.Windows.Threading.Dispatcher]::CurrentDispatcher.add_UnhandledException($script:dispHandler)
try {
    $tick.Start()
    $deadline.Start()
    [System.Windows.Threading.Dispatcher]::Run()
}
finally { Stop-ShellLoop }

# Results are printed BEFORE cleanup; cleanup is by index and warn-only.
if ($script:fail -eq 0) { Write-Host "$($script:pass) checks passed" } else { Write-Host "$($script:fail) checks FAILED, $($script:pass) passed" }

try {
    for ($i = 0; $i -lt $script:scns.Count; $i++) {
        try { Unregister-FastLlmUiWindowHooks -Window $script:scns[$i].Window } catch { Write-Host "WARN: cleanup: $($_.Exception.Message)" }
        try { $script:scns[$i].Form.FastLlmFormState.FormClosing.Clear() } catch { Write-Host "WARN: cleanup: $($_.Exception.Message)" }
        try { $script:scns[$i].Window.Close() } catch { Write-Host "WARN: cleanup: $($_.Exception.Message)" }
    }
    for ($i = 0; $i -lt $script:objs.Count; $i++) {
        try { $script:objs[$i].Dispose() } catch { Write-Host "WARN: cleanup: $($_.Exception.Message)" }
    }
    try { Clear-FastLlmUiFluentTrayIcon } catch { Write-Host "WARN: cleanup: $($_.Exception.Message)" }
}
catch { Write-Host "WARN: cleanup: $($_.Exception.Message)" }

if ($script:fail -gt 0) { exit 1 }
exit 0
