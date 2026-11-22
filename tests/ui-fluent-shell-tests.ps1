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
function Check([bool]$Condition, [string]$Name, [string]$Detail = '') {
    if ($Condition) { $script:pass++; Write-Host "PASS: $Name" }
    else { $script:fail++; Write-Host "FAIL: $Name -- $Detail" }
}

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

function Stop-ShellLoop {
    if ($script:loopStopped) { return }
    $script:loopStopped = $true
    try { $script:tick.Stop(); $script:deadline.Stop() } catch { $null = $_ }
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
}

# Runs the dispatcher for up to $Ms milliseconds, or until $Until returns true.
function Invoke-Pump([int]$Ms, [scriptblock]$Until = $null) {
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(20)
    $t.Add_Tick(({
        $done = ($sw.ElapsedMilliseconds -ge $Ms)
        if (-not $done -and $null -ne $Until) { $done = [bool](& $Until) }
        if ($done) { $t.Stop(); $frame.Continue = $false }
    }).GetNewClosure())
    $t.Start()
    try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $t.Stop() }
}

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

function Check-NoExceptions([string]$Name) {
    $d = @($script:dispEx.ToArray()); $t = @($script:threadEx.ToArray())
    Check (($d.Count -eq 0) -and ($t.Count -eq 0)) "$Name : no dispatcher or WinForms exception recorded" ("dispatcher=" + ($d -join ' | ') + " winforms=" + ($t -join ' | '))
    $script:dispEx.Clear(); $script:threadEx.Clear()
}

# A WinForms timer that finds a message box by its caption, records the owner and the WPF window state, then presses a button.
function Start-BoxAnswer([string]$Caption, [int]$ButtonId, [IntPtr]$Hwnd, [hashtable]$St) {
    $St.found = $false; $St.during = $null; $St.owner = [long]0; $St.timedOut = $false
    $st = $St
    $nat = $script:native
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $loc = @{ clickAt = [long]-100000; foundAt = [long]0 }
    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = 50
    $t.Add_Tick(({
        $h = $nat::FindWindowByTitle($Caption)
        $ms = $sw.ElapsedMilliseconds
        if ($h.ToInt64() -ne 0) {
            if (-not $st.found) { $st.found = $true; $loc.foundAt = $ms; $st.during = $nat::IsWindowEnabled($Hwnd); $st.owner = $nat::GetOwner($h).ToInt64() }
            if (($ms - $loc.clickAt) -gt 1000) {
                $loc.clickAt = $ms
                # BM_CLICK first; if the box is still there a second later, WM_COMMAND to the box itself
                if (($ms - $loc.foundAt) -lt 1000) { $null = $nat::PostButtonClick($h, $ButtonId) } else { $null = $nat::PostCommand($h, $ButtonId) }
            }
        }
        elseif (-not $st.found -and $ms -gt 8000) { $st.timedOut = $true; $t.Stop() }
    }).GetNewClosure())
    $script:objs.Add($t)
    $t.Start()
    return $t
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

function Invoke-A1-CloseCancelled {
    $s = New-Scn 'a1'; $form = $s.Form; $w = $s.Window
    $st = @{ n = 0; reason = ''; same = $false }
    $form.Add_FormClosing(({ param($sender, $event)
        $st.n++; $st.reason = [string]$event.CloseReason
        $st.same = [object]::ReferenceEquals($sender.PSObject.BaseObject, $form.PSObject.BaseObject)
        $st.x = 1
        $event.Cancel = $true }).GetNewClosure())
    Show-Scn $s
    $form.Close()
    Invoke-Pump 150
    Check ($st.n -eq 1 -and $st.x -eq 1) 'A1 a cancelled close runs the FormClosing handler once' "n=$($st.n) x=$($st.x) expected n=1 x=1"
    Check ($st.reason -eq 'UserClosing') 'A1 a cancelled close reports CloseReason UserClosing' "actual=$($st.reason) expected=UserClosing"
    Check $st.same 'A1 the handler sender is the form adapter' 'sender.PSObject.BaseObject was not form.PSObject.BaseObject'
    Check ($w.IsVisible -and $s.Closed.n -eq 0) 'A1 a cancelled close leaves the window open' "IsVisible=$($w.IsVisible) closedEvents=$($s.Closed.n)"
    Check-NoExceptions 'A1'
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
    Check ($box.found -and -not $box.timedOut) 'A3 the guard message box appeared' "found=$($box.found) timedOut=$($box.timedOut)"
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
        Check ($box.found -and -not $box.timedOut) ("A10 " + $c.tag + ' appeared') "found=$($box.found) timedOut=$($box.timedOut)"
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
    Check ($r1 -eq 0 -and $w.IsVisible -and $s.Closed.n -eq 0) 'A12 a guard cancel refuses WM_QUERYENDSESSION and the window stays open' "result=$r1 expected=0 IsVisible=$($w.IsVisible) closed=$($s.Closed.n)"
    Check ($st.n -eq 1 -and $st.reason -eq 'WindowsShutDown') 'A12 the session-end FormClosing runs once with CloseReason WindowsShutDown' "n=$($st.n) reason=$($st.reason)"
    Check ($form.FastLlmFormState['Closing'] -eq $false) 'A12 the Closing flag is reset after the session-end query' "Closing=$($form.FastLlmFormState['Closing'])"
    $st.cancel = $false
    $r2 = $script:native::SendMessage($s.Hwnd, [uint32]0x0011, $none, $none).ToInt64()
    Invoke-Pump 100
    Check ($r2 -ne 0 -and $st.reason -eq 'WindowsShutDown') 'A12 an allowing handler lets WM_QUERYENDSESSION return non-zero' "result=$r2 expected non-zero reason=$($st.reason)"
    Check ($w.IsVisible -and $s.Closed.n -eq 0) 'A12 WM_QUERYENDSESSION is only a query: the window is not closed' "IsVisible=$($w.IsVisible) closed=$($s.Closed.n)"
    Unregister-FastLlmUiWindowHooks -Window $w
    Check-NoExceptions 'A12'
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
# Part B (added later): shell bindings, Home parity and render checks. Append their step functions below and add them to $script:steps.
# ======================================================================================================================

$script:steps = @(
    'Invoke-A1-CloseCancelled', 'Invoke-A2-CloseAllowed', 'Invoke-A3-BoxNo', 'Invoke-A4-BoxYes', 'Invoke-A5-CloseInsideHandler',
    'Invoke-A6-ThrowingHandler', 'Invoke-A7-Visible', 'Invoke-A8-RestoreFromTray', 'Invoke-A9-Shown', 'Invoke-A10-Owner',
    'Invoke-A11-ScreenGap', 'Invoke-A12-SessionEnd', 'Invoke-A13-Members', 'Invoke-A14-LeakyHandler',
    'Invoke-B1-GdiLeak', 'Invoke-B2-IconSizes', 'Invoke-B3-AppIcon', 'Invoke-B4-ThemeHook', 'Invoke-B5-SettingChangeString',
    'Invoke-B6-HookFailure', 'Invoke-B7-Unregister'
)

$tick = New-Object System.Windows.Threading.DispatcherTimer
$tick.Interval = [TimeSpan]::FromMilliseconds(50)
$script:tick = $tick
$deadline = New-Object System.Windows.Threading.DispatcherTimer
$deadline.Interval = [TimeSpan]::FromSeconds(150)
$script:deadline = $deadline

$tick.Add_Tick({
    if ($script:busy -or $script:loopStopped) { return }
    $script:busy = $true
    try {
        if ($script:si -ge $script:steps.Count) { Stop-ShellLoop; return }
        $name = $script:steps[$script:si]
        $script:si++
        try { $null = & $name }
        catch { $script:fail++; Write-Host "FAIL: step $name threw -- $($_.Exception.ToString())" }
        if ($script:si -ge $script:steps.Count) { Stop-ShellLoop }
    }
    finally { $script:busy = $false }
})
$deadline.Add_Tick({
    $script:deadline.Stop()
    $where = if ($script:si -gt 0 -and $script:si -le $script:steps.Count) { $script:steps[$script:si - 1] } else { 'before the first step' }
    Write-Host "FAIL: the 150 s suite deadline was hit during step $where"
    # a step may be stuck in a modal loop: ending the process is the only way out and it must not hang CI
    [Environment]::Exit(1)
})

[System.Windows.Threading.Dispatcher]::CurrentDispatcher.add_UnhandledException({ param($s, $e) $script:dispEx.Add($e.Exception.ToString()); $e.Handled = $true })
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
