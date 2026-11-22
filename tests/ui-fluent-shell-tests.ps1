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

# A WinForms timer that finds a message box by its caption, records the owner and the WPF window state, then closes it with an escalation
# ladder, one rung per second: BM_CLICK(id), WM_COMMAND(id), WM_COMMAND(IDCANCEL), WM_CLOSE. A YesNo box ignores WM_CLOSE, so the ladder starts with the button.
# Records which rung closed the box and whether buttons 1 and 2 exist. After 6 s a still-open box gets WM_CLOSE and hardStop is set (the caller fails the case).
function Start-BoxAnswer([string]$Caption, [int]$ButtonId, [IntPtr]$Hwnd, [hashtable]$St) {
    $St.found = $false; $St.during = $null; $St.owner = [long]0; $St.timedOut = $false; $St.hardStop = $false; $St.rung = ''; $St.closedBy = ''
    $st = $St
    $nat = $script:native
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $loc = @{ rung = -1; foundAt = [long]0; last = '' }
    $names = @('BM_CLICK id', 'WM_COMMAND id', 'WM_COMMAND IDCANCEL', 'WM_CLOSE')
    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = 50
    $t.Add_Tick(({
        $h = $nat::FindWindowByTitle($Caption)
        $ms = $sw.ElapsedMilliseconds
        if ($h.ToInt64() -ne 0) {
            if (-not $st.found) {
                $st.found = $true; $loc.foundAt = $ms; $st.during = $nat::IsWindowEnabled($Hwnd); $st.owner = $nat::GetOwner($h).ToInt64()
                $ok = ($nat::GetDlgItem($h, 1).ToInt64() -ne 0); $cancel = ($nat::GetDlgItem($h, 2).ToInt64() -ne 0)
                Write-Host ("INFO: box '" + $Caption + "' has button id 1 (OK)=" + $ok + " id 2 (Cancel)=" + $cancel)
            }
            $age = $ms - $loc.foundAt
            if ($age -ge 6000) {
                if (-not $st.hardStop) { $st.hardStop = $true; $null = $nat::PostClose($h) }
            }
            else {
                $rung = [int][Math]::Floor($age / 1000)
                if ($rung -gt $loc.rung) {
                    $loc.rung = $rung
                    $idx = [Math]::Min($rung, 3)
                    $loc.last = $names[$idx]; $st.rung = $loc.last
                    if ($idx -eq 0) { $null = $nat::PostButtonClick($h, $ButtonId) }
                    elseif ($idx -eq 1) { $null = $nat::PostCommand($h, $ButtonId) }
                    elseif ($idx -eq 2) { $null = $nat::PostCommand($h, 2) }
                    else { $null = $nat::PostClose($h) }
                }
            }
        }
        else {
            if ($st.found -and $st.closedBy -eq '') { $st.closedBy = $loc.last; Write-Host ("INFO: box '" + $Caption + "' closed by rung: " + $loc.last) }
            elseif (-not $st.found -and $ms -gt 8000) { $st.timedOut = $true; $t.Stop() }
        }
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

$script:hRuns = 0
$script:hAnswer = ''
$script:hCap = ''
$script:hForm = $null
$script:hWin = $null

function Invoke-H1-ReentrantQuery {
    $s = New-Scn 'h1'; $form = $s.Form; $w = $s.Window
    $script:hRuns = 0; $script:hAnswer = ''; $script:hForm = $form
    $script:hCap = 'FastLLM shell hook H1 ' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $form.Add_FormClosing({ param($sender, $event)
        $script:hRuns++
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
                $st.runsAtQuery = $script:hRuns
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
    Check ($script:hRuns -eq 1 -and $st.runsAtQuery -eq 1) 'H1 no second guard box opened: the handler ran once' "runs=$($script:hRuns) runsAtQuery=$($st.runsAtQuery) expected=1"
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

function Invoke-H3-UnregisterOnClosed {
    $s = New-Scn 'h3'; $form = $s.Form; $w = $s.Window
    $script:hWin = $w
    $key = [string]$s.Hwnd.ToInt64()
    $null = Register-FastLlmUiWindowHooks -Window $w -Form $form -OnThemeChanged { }
    $w.Add_Closed({ Unregister-FastLlmUiWindowHooks -Window $script:hWin })
    Show-Scn $s
    Check ($script:FastLlmUiHookState.ContainsKey($key)) 'H3 the hook state holds an entry for the window after Register' "key=$key"
    $form.Close()
    Invoke-Pump 300 ({ $s.Closed.n -ge 1 }).GetNewClosure()
    Invoke-Pump 100
    Check ($s.Closed.n -eq 1) 'H3 the window closed' "closed=$($s.Closed.n)"
    Check (-not $script:FastLlmUiHookState.ContainsKey($key)) 'H3 Unregister called from Closed leaves no hook state entry for the window' "key=$key still present"
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
function GetUiStateSnapshot([bool]$Busy) { return $script:shellSnap }
function GetUiBackgroundRunStatus { return $null }
function ShowFailure($Message) { $script:shellFailMsg = [string]$Message }

function New-ShellSnap([hashtable]$O = @{}) {
    $d = @{ Busy = $false; UpdateKind = ''; ChildActive = $false; Step = ''; RunReady = $false; SideChildActive = $false; VcBrokerActive = $false; PreviewReady = $false
        SwitchGap = $false; ChatUrlSet = $false; BackgroundStopRequested = $false; Background = 'absent'; FlowPhase = ''; FailureHeld = $false }
    foreach ($k in $O.Keys) { $d[$k] = $O[$k] }
    $bg = $d.Background
    if ($bg -is [string]) { $bg = Get-UiBackgroundFixture -Name $bg }
    return New-FastLlmUiStateSnapshot -Busy $d.Busy -UpdateKind $d.UpdateKind -ChildActive $d.ChildActive -Step $d.Step -RunReady $d.RunReady `
        -SideChildActive $d.SideChildActive -VcBrokerActive $d.VcBrokerActive -PreviewReady $d.PreviewReady -SwitchGap $d.SwitchGap `
        -ChatUrlSet $d.ChatUrlSet -BackgroundStopRequested $d.BackgroundStopRequested -Background $bg -FlowPhase $d.FlowPhase -FailureHeld $d.FailureHeld
}

function Get-ShellVisuals($Root) {
    $list = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $n = $stack.Pop()
        [void]$list.Add($n)
        $c = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($n)
        for ($i = 0; $i -lt $c; $i++) { $stack.Push([System.Windows.Media.VisualTreeHelper]::GetChild($n, $i)) }
    }
    return , $list.ToArray()
}

# The text of every TextBlock in an element's visual tree (an AccessText draws its text in an inner TextBlock, without the key underscore).
function Get-ShellTexts($Root) {
    $out = New-Object System.Collections.ArrayList
    foreach ($n in @(Get-ShellVisuals $Root)) { if ($n -is [System.Windows.Controls.TextBlock]) { [void]$out.Add([string]$n.Text) } }
    return , $out.ToArray()
}

function Get-ShellPeerName($Element) {
    $peer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($Element)
    if ($null -eq $peer) { return '' }
    return [string]$peer.GetName()
}

# True when the name has a character that is not whitespace and not an icon glyph (Private Use Area).
function Test-ShellNameReadable([string]$Name) {
    foreach ($c in $Name.ToCharArray()) { if (-not [char]::IsWhiteSpace($c) -and ([int]$c -lt 0xE000 -or [int]$c -gt 0xF8FF)) { return $true } }
    return $false
}

function New-ShellClick($Element, $RoutedEvent) {
    return New-Object System.Windows.RoutedEventArgs($RoutedEvent, $Element)
}

function Invoke-S0-ShellStart {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('fastllm-shell-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    $script:InstallRoot = $dir
    $script:settingsRoot = $dir
    $script:installPath = $dir
    $script:catalog = Get-FastLlmCatalog (Join-Path $root 'config/catalog.json')
    $script:uiSettings = Read-FastLlmUiSettings -InstallRoot $dir -AppRoot $root
    $script:shellSnap = New-ShellSnap
    $classic = New-Object System.Windows.Forms.Form
    $classic.Text = 'FastLLM shell check ' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $script:shellTitle = [string]$classic.Text
    $script:form = $classic

    $textC1 = Get-FastLlmUiUnsupportedText -Reason 'theme-init' -Folder 'C:\example'
    $textC2 = Get-FastLlmUiUnsupportedText -Reason 'xaml-parse' -Folder 'C:\example'
    $shellSource = [System.IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.UiFluentShell.ps1'))
    Check (($textC1 -ceq $textC2) -and $textC1 -match 'a fault in FastLLM') 'S0 the reasons theme-init and xaml-parse give the same text C (a fault in FastLLM)' "theme-init='$textC1' xaml-parse='$textC2'"
    Check ($script:realStopText -match 'Show-FastLlmUiUnsupported\s+-Reason\s+\$Reason' -and $script:realStopText -match 'exit 3') 'S0 the real Stop-FastLlmUiFluentStartup passes its reason to Show-FastLlmUiUnsupported and exits 3' $script:realStopText
    Check (($shellSource -match "Stop-FastLlmUiFluentStartup -Reason 'theme-init'") -and ($shellSource -match "Stop-FastLlmUiFluentStartup -Reason 'xaml-parse'")) 'S0 the shell stops with theme-init and xaml-parse on a theme or markup fault' 'a call with one of the two reasons was not found in the shell file'

    $err = ''
    try { Initialize-FastLlmUiFluentShell } catch { $err = $_.Exception.Message }
    Check ($err -eq '') 'S0 the startup did not stop (Initialize-FastLlmUiFluentShell returned)' $err
    if ($err -ne '') { $script:shellOk = $false; return }
    $script:shellOk = $true
    $f = $script:FastLlmUiFluent
    $win = $f.Window
    Check ($win.Title -ceq $script:shellTitle) 'S0 the shell window carries the classic form title' "title=$($win.Title) expected=$($script:shellTitle)"
    Check ($null -ne $f.Hooks -and $f.Hooks['hooked'] -eq $true) 'S0 the window hooks registered' "hooks=$($f.Hooks)"
    Check ($null -ne $script:form.FastLlmFormState) 'S0 the orchestration form is now the form adapter' 'form has no FastLlmFormState'
    $script:scns.Add([pscustomobject]@{ Window = $win; Form = $script:form; Hwnd = [System.Windows.Interop.WindowInteropHelper]::new($win).Handle; Closed = @{ n = 0 }; Title = $win.Title })
    $script:form.Add_Shown({ $script:shellShown++ })
    Check-NoExceptions 'S0'
    # From here the loop owns the thread. The step timer is not busy any more, so S1 onward run inside the loop's nested frame.
    $script:busy = $false
    try { Start-FastLlmUiFluentLoop }
    catch { $script:fail++; Write-Host "FAIL: S0 Start-FastLlmUiFluentLoop threw -- $($_.Exception.ToString())" }
}

function Invoke-S1-Shown {
    if (-not $script:shellOk) { return }
    $win = $script:FastLlmUiFluent.Window
    Invoke-Pump 5000 ({ $script:shellShown -ge 1 })
    Invoke-Pump 700
    Check ($script:shellShown -eq 1) 'S1 a Shown handler added through form.Add_Shown runs exactly once after the real shell window renders' "runs=$($script:shellShown) expected=1"
    Check ($win.IsVisible) 'S1 the shell window is visible' "IsVisible=$($win.IsVisible)"
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
        if ($c.Held) { $script:output.Text = 'failure output check' }
        Invoke-FastLlmUiFluentTick
        $want = [string](Get-FastLlmUiCardState -Snapshot $c.Snap).headline
        $seen[$want] = $true
        Check ($want -ne '' -and $els.StatusHeadline.Text -ceq $want) ("S2 the card headline follows Get-FastLlmUiCardState: " + $c.Label) "headline=$($els.StatusHeadline.Text) expected=$want"
    }
    Check ($seen.Count -eq 3) 'S2 the three snapshots gave three different headlines' "distinct=$($seen.Count) expected=3"
    Check ($els.FailureBar.Visibility -eq [System.Windows.Visibility]::Visible -and $els.FailureText.Text -ceq 'failure output check') 'S2 the held failure shows in the message area' "visibility=$($els.FailureBar.Visibility) text=$($els.FailureText.Text)"
    $script:shellSnap = New-ShellSnap
    $script:failureHeld = $false
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
    Check (($texts -ccontains 'my_model_id') -and -not (@($texts | Where-Object { $_ -match '__' }).Count -gt 0)) 'S2 a Content-mode caption with underscores renders with none lost' "rendered=[$($texts -join '|')]"
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
    @{ El = 'UpdateText'; Ad = 'bannerLabel'; Mode = 'TextBlock'; Kind = 'text'; NoText = $false; NoVisible = $true },
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
        @{ N = 'OpenChatButton'; Fg = 'FastLlm.TextPrimaryBrush'; Bg = 'FastLlm.CardBrush' },
        @{ N = 'ActivityBox'; Fg = 'FastLlm.TextPrimaryBrush'; Bg = 'FastLlm.CardBrush' })
    $bodySize = [double]$dict['FastLlm.BodySize']
    foreach ($r in $rows) {
        $el = $els[$r.N]
        Check (& $same $el.Foreground $r.Fg) "S4 Home $($r.N) Foreground is the theme value $($r.Fg)" "actual=$($el.Foreground)"
        Check (& $same $el.Background $r.Bg) "S4 Home $($r.N) Background is the theme value $($r.Bg)" "actual=$($el.Background)"
        Check ([Math]::Abs([double]$el.FontSize - $bodySize) -lt 0.01) "S4 Home $($r.N) FontSize is the theme body size" "actual=$($el.FontSize) expected=$bodySize"
    }
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
    $second = $f.NavItems[1]['Item']
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
    # selection moves: the second item is enabled for this check only (all but Home are disabled in this build)
    $second.IsEnabled = $true
    $list.SelectedIndex = 1
    Invoke-Pump 150
    $bar2 = $second.Template.FindName('Bar', $second)
    Check ($second.IsSelected -and -not $home1.IsSelected -and $null -ne $bar2 -and $bar2.Visibility -eq [System.Windows.Visibility]::Visible -and $bar.Visibility -eq [System.Windows.Visibility]::Collapsed) 'S6 a selection change moves the bar from Home to the second item' "second=$($second.IsSelected) home=$($home1.IsSelected) bar2=$($bar2.Visibility) bar=$($bar.Visibility)"
    $list.SelectedIndex = 0
    $second.IsEnabled = $false
    Invoke-Pump 100
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
    Check-NoExceptions 'S8'
}

$script:steps = @(
    'Invoke-A1-CloseCancelled', 'Invoke-A1c-CloseCancelledClosure', 'Invoke-A2-CloseAllowed', 'Invoke-A3-BoxNo', 'Invoke-A4-BoxYes', 'Invoke-A5-CloseInsideHandler',
    'Invoke-A6-ThrowingHandler', 'Invoke-A7-Visible', 'Invoke-A8-RestoreFromTray', 'Invoke-A9-Shown', 'Invoke-A10-Owner',
    'Invoke-A11-ScreenGap', 'Invoke-A12-SessionEnd', 'Invoke-A12b-SessionEndPlain', 'Invoke-A13-Members', 'Invoke-A14-LeakyHandler',
    'Invoke-B1-GdiLeak', 'Invoke-B2-IconSizes', 'Invoke-B3-AppIcon', 'Invoke-B4-ThemeHook', 'Invoke-B5-SettingChangeString',
    'Invoke-B6-HookFailure', 'Invoke-B7-Unregister',
    'Invoke-H1-ReentrantQuery', 'Invoke-H2-ThrowingQuery', 'Invoke-H3-UnregisterOnClosed', 'Invoke-H4-ThemeCallbackThrows', 'Invoke-H5-EndSession',
    'Invoke-H6-PassThrough', 'Invoke-H7-DpiEvidence',
    # S0 enters the shell's message loop; every step after it runs inside that loop's frame
    'Invoke-S0-ShellStart', 'Invoke-S1-Shown', 'Invoke-S2-Bindings', 'Invoke-S3-HomeParity', 'Invoke-S4-Resources', 'Invoke-S5-SplitMenu', 'Invoke-S6-Nav',
    'Invoke-S7-ShellTheme', 'Invoke-S8-DispatcherHandler'
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
