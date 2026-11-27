# Shared helpers and stubs of the Fluent window Windows suites (ui-fluent-shell-tests, ui-fluent-pages-tests).
# Dot-sourced at file level by each suite, so every function here is a file-level function (plain scriptblock handlers can call them)
# and reads the suite's own $script: state ($script:pass, $script:fail, $script:objs, $script:native, $script:tick, $root ...).

function Check([bool]$Condition, [string]$Name, [string]$Detail = '') {
    if ($Condition) { $script:pass++; Write-Host "PASS: $Name" }
    else { $script:fail++; Write-Host "FAIL: $Name -- $Detail" }
}

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

# ---- Dialog answerer: Win32 message boxes (#32770) and WPF dialogs (PR 4) ----
# A WPF dialog is a Window in the main window's OwnedWindows (or, for a nested box, in an owned dialog's OwnedWindows) whose Title is the caption.
# It has no child hwnds, so it is read and clicked through its elements, never by GetDlgItem or coordinates.
# Buttons are found, in order, through: the dialog Window.Tag (the hashtable New-FastLlmUiFluentDialog returns: a 'Buttons' id -> Button map and an 'Els' map),
# then a Button whose Name or AutomationId equals the id, then a Button whose caption (without its access underscore) or automation name equals the id.

# The WPF dialog with this title below the main window (HwndSource root), or $null.
function Find-WpfBox([IntPtr]$Hwnd, [string]$Caption) {
    try {
        if ($Hwnd.ToInt64() -eq 0) { return $null }
        $src = [System.Windows.Interop.HwndSource]::FromHwnd($Hwnd)
        if ($null -eq $src) { return $null }
        $rootWin = $src.RootVisual
        if ($rootWin -isnot [System.Windows.Window]) { return $null }
        $stack = New-Object System.Collections.Stack
        $stack.Push($rootWin)
        while ($stack.Count -gt 0) {
            $w = $stack.Pop()
            foreach ($o in @($w.OwnedWindows)) {
                if ($null -eq $o) { continue }
                if ([string]$o.Title -ceq $Caption -and $o.IsVisible) { return $o }
                $stack.Push($o)
            }
        }
    }
    catch { $null = $_ }
    return $null
}

# The button id the dialogs use: the MessageBox ids 1/2/6/7 map to their names, anything else is the custom id as given.
function ConvertTo-WpfBoxKey($ButtonId) {
    switch ([string]$ButtonId) {
        '1' { return 'OK' }
        '2' { return 'Cancel' }
        '6' { return 'Yes' }
        '7' { return 'No' }
        default { return [string]$ButtonId }
    }
}

function Get-WpfBoxTagMap($Window, [string]$Name) {
    $tag = $Window.Tag
    if ($tag -is [System.Collections.IDictionary] -and $tag.Contains($Name)) { return $tag[$Name] }
    return $null
}

# The Button element for an id, or $null.
function Find-WpfBoxButton($Window, [string]$Key) {
    $map = Get-WpfBoxTagMap $Window 'Buttons'
    if ($map -is [System.Collections.IDictionary]) {
        foreach ($k in @($map.Keys)) {
            if ([string]$k -eq $Key -and $map[$k] -is [System.Windows.Controls.Button]) { return $map[$k] }
        }
    }
    $buttons = @(Get-ShellVisuals $Window | Where-Object { $_ -is [System.Windows.Controls.Button] })
    foreach ($b in $buttons) {
        if ([string]$b.Name -ceq $Key -or [System.Windows.Automation.AutomationProperties]::GetAutomationId($b) -ceq $Key) { return $b }
    }
    foreach ($b in $buttons) {
        $cap = ''
        if ($b.Content -is [string]) { $cap = [string]$b.Content } else { $cap = (@(Get-ShellTexts $b) -join '') }
        if (([string]$cap).Replace('_', '') -ceq $Key -or [System.Windows.Automation.AutomationProperties]::GetName($b) -ceq $Key) { return $b }
    }
    return $null
}

# Presses a Button the way a person or a UIA client does: Mode 0 the automation Invoke pattern, Mode 1 a routed Click. Never by coordinates.
# False when the button is missing, disabled or the press threw.
function Invoke-WpfBoxButton($Button, [int]$Mode) {
    if ($null -eq $Button) { return $false }
    try {
        if (-not $Button.IsEnabled) { return $false }
        if ($Mode -eq 0) {
            $peer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($Button)
            if ($null -eq $peer) { return $false }
            $pattern = $peer.GetPattern([System.Windows.Automation.Peers.PatternInterface]::Invoke)
            if ($null -eq $pattern) { return $false }
            $pattern.Invoke()
            return $true
        }
        $Button.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $Button)))
        return $true
    }
    catch { return $false }
}

# The body text of a WPF dialog: the Els body element when the dialog exposes one (Els 'Body'), otherwise every TextBlock outside a Button. Lines joined with LF.
function Get-WpfBoxText($Window) {
    try {
        $els = Get-WpfBoxTagMap $Window 'Els'
        if ($els -is [System.Collections.IDictionary]) {
            foreach ($n in @('Body', 'BodyText', 'BodyHost')) {
                if ($els.Contains($n) -and $els[$n] -is [System.Windows.UIElement]) { return (@(Get-ShellTexts $els[$n]) -join "`n") }
            }
        }
        $out = New-Object System.Collections.ArrayList
        foreach ($n in @(Get-ShellVisuals $Window)) {
            if ($n -isnot [System.Windows.Controls.TextBlock]) { continue }
            $inButton = $false
            $p = [System.Windows.Media.VisualTreeHelper]::GetParent($n)
            while ($null -ne $p) {
                if ($p -is [System.Windows.Controls.Button]) { $inButton = $true; break }
                $p = [System.Windows.Media.VisualTreeHelper]::GetParent($p)
            }
            if ($inButton) { continue }
            $t = [string]$n.Text
            if ($t -eq '') { $t = Get-ShellInlineText $n.Inlines }
            if ($t -ne '') { [void]$out.Add($t) }
        }
        return ($out.ToArray() -join "`n")
    }
    catch { return '' }
}

# The body text of the box with this caption, for either kind: a WPF dialog below the main window $Hwnd (or the -Dialog Window given), else a Win32 box found by title.
function Get-BoxText([string]$Caption, [IntPtr]$Hwnd = [IntPtr]::Zero, $Dialog = $null) {
    $w = $null
    if ($Dialog -is [System.Windows.Window]) { $w = $Dialog }
    elseif ($Dialog -is [System.Collections.IDictionary] -and $Dialog.Contains('Window')) { $w = $Dialog['Window'] }
    if ($null -eq $w) { $w = Find-WpfBox $Hwnd $Caption }
    if ($null -ne $w) { return [string](Get-WpfBoxText $w) }
    $h = $script:native::FindWindowByTitle($Caption)
    if ($h.ToInt64() -eq 0) { return '' }
    return [string]$script:native::GetText($h)
}

# Posts Return or Escape (WM_KEYDOWN + WM_KEYUP, PostMessage so the message loop and key filters see it) to a dialog hwnd.
# The target is a dialog Window or the hashtable New-FastLlmUiFluentDialog returns (-Dialog), a raw -Hwnd, or -Caption with the main window's -MainHwnd.
function Send-DialogKey([ValidateSet('Return', 'Escape')][string]$Key, $Dialog = $null, [IntPtr]$Hwnd = [IntPtr]::Zero, [string]$Caption = '', [IntPtr]$MainHwnd = [IntPtr]::Zero) {
    $w = $null
    if ($Dialog -is [System.Windows.Window]) { $w = $Dialog }
    elseif ($Dialog -is [System.Collections.IDictionary] -and $Dialog.Contains('Window')) { $w = $Dialog['Window'] }
    elseif ($Caption -ne '') { $w = Find-WpfBox $MainHwnd $Caption }
    $target = $Hwnd
    if ($null -ne $w) { $target = [System.Windows.Interop.WindowInteropHelper]::new($w).Handle }
    $vk = 0x0D
    if ($Key -eq 'Escape') { $vk = 0x1B }
    return [bool]$script:native::PostKey($target, $vk)
}

# Finds a message box or a WPF dialog by its caption, records the owner and the WPF window state, then closes it with an escalation
# ladder, one rung per second. Win32: BM_CLICK(id), WM_COMMAND(id), WM_COMMAND(FallbackId), WM_CLOSE. WPF: Invoke(id), routed Click(id), Invoke(FallbackId), Window.Close.
# A YesNo box ignores WM_CLOSE and has no IDCANCEL, so the ladder starts with the button and a Yes/No caller passes -FallbackId 7 (IDNO).
# $ButtonId is 1 OK, 2 Cancel, 6 Yes, 7 No, or (WPF only) a custom id string. FallbackId is an int id.
# Records which rung closed the box, whether buttons 1 and 2 exist (Win32), the path used ($St.path: 'win32' or 'wpf') and the body text read when it appeared ($St.text).
# After 6 s a still-open box gets WM_CLOSE / Window.Close and hardStop is set (the caller fails the case).
# Two timers drive one tick body: a WinForms timer (the proven path for a Win32 box) and a DispatcherTimer (a WPF ShowDialog is a nested dispatcher frame). Stop() stops both, Dispose() releases them.
# Closes a WPF dialog the last-resort way. A YesNo dialog refuses a plain Window.Close, so the answer is set first (the fallback button's own answer: No for
# the IDNO id 7, Cancel for 2, OK for 1), as Stop-PagesWpfBox does; the Closing handler then lets the close through.
function Close-BoxWindow($Wnd, [int]$FallbackId) {
    try {
        $tag = $Wnd.Tag
        if ($tag -is [System.Collections.IDictionary] -and $tag.Contains('State')) {
            $answer = ''
            if ($FallbackId -eq 7) { $answer = 'No' } elseif ($FallbackId -eq 2) { $answer = 'Cancel' } elseif ($FallbackId -eq 1) { $answer = 'OK' }
            if ($answer -cne '' -and [string]$tag['State']['Result'] -ceq '') { $tag['State']['Result'] = $answer }
        }
        $Wnd.Close()
    }
    catch { $null = $_ }
}

function Start-BoxAnswer([string]$Caption, $ButtonId, [IntPtr]$Hwnd, [hashtable]$St, [int]$FallbackId = 2) {
    $St.found = $false; $St.during = $null; $St.owner = [long]0; $St.timedOut = $false; $St.hardStop = $false; $St.rung = ''; $St.closedBy = ''; $St.path = ''; $St.text = ''
    $st = $St
    $nat = $script:native
    $findWpf = ${function:Find-WpfBox}
    $findBtn = ${function:Find-WpfBoxButton}
    $pressBtn = ${function:Invoke-WpfBoxButton}
    $readText = ${function:Get-WpfBoxText}
    $toKey = ${function:ConvertTo-WpfBoxKey}
    $closeWnd = ${function:Close-BoxWindow}
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $loc = @{ rung = -1; foundAt = [long]0; last = ''; path = '' }
    $winNames = @('BM_CLICK id', 'WM_COMMAND id', 'WM_COMMAND fallback', 'WM_CLOSE')
    $wpfNames = @('Invoke id', 'Click id', 'Invoke fallback', 'Window.Close')
    $winId = 0
    if (-not [int]::TryParse([string]$ButtonId, [ref]$winId)) { $winId = 0 }
    $wpfKey = & $toKey $ButtonId
    $wpfFallbackKey = & $toKey $FallbackId
    $body = {
        $ms = $sw.ElapsedMilliseconds
        $wnd = $null; $h = [IntPtr]::Zero
        if ($loc.path -ne 'win32') { $wnd = & $findWpf $Hwnd $Caption }
        if ($null -eq $wnd -and $loc.path -ne 'wpf') {
            $h = $nat::FindWindowByTitle($Caption)
            if ($h.ToInt64() -ne 0 -and $loc.path -eq '') {
                # a WPF dialog that is not in the owner chain still has an HwndSource: treat it as WPF, never as a Win32 box
                try { $src = [System.Windows.Interop.HwndSource]::FromHwnd($h); if ($null -ne $src -and $src.RootVisual -is [System.Windows.Window]) { $wnd = $src.RootVisual } } catch { $null = $_ }
            }
        }
        $isWpf = ($null -ne $wnd)
        $isWin = (-not $isWpf) -and ($h.ToInt64() -ne 0)
        if ($isWpf -or $isWin) {
            if (-not $st.found) {
                $st.found = $true; $loc.foundAt = $ms; $st.during = $nat::IsWindowEnabled($Hwnd)
                if ($isWpf) {
                    $loc.path = 'wpf'; $st.path = 'wpf'
                    $dh = [System.Windows.Interop.WindowInteropHelper]::new($wnd).Handle
                    $st.owner = $nat::GetOwner($dh).ToInt64()
                    $st.text = [string](& $readText $wnd)
                    $has = ($null -ne (& $findBtn $wnd $wpfKey))
                    Write-Host ("INFO: wpf box '" + $Caption + "' has button '" + $wpfKey + "'=" + $has)
                }
                else {
                    $loc.path = 'win32'; $st.path = 'win32'
                    $st.owner = $nat::GetOwner($h).ToInt64()
                    $st.text = [string]$nat::GetText($h)
                    $ok = ($nat::GetDlgItem($h, 1).ToInt64() -ne 0); $cancel = ($nat::GetDlgItem($h, 2).ToInt64() -ne 0)
                    Write-Host ("INFO: box '" + $Caption + "' has button id 1 (OK)=" + $ok + " id 2 (Cancel)=" + $cancel)
                }
            }
            $age = $ms - $loc.foundAt
            if ($age -ge 6000) {
                if (-not $st.hardStop) {
                    $st.hardStop = $true
                    if ($loc.path -eq 'wpf') { & $closeWnd $wnd $FallbackId } else { $null = $nat::PostClose($h) }
                }
            }
            else {
                $rung = [int][Math]::Floor($age / 1000)
                if ($rung -gt $loc.rung) {
                    $loc.rung = $rung
                    $idx = [Math]::Min($rung, 3)
                    if ($loc.path -eq 'wpf') {
                        $loc.last = $wpfNames[$idx]; $st.rung = $loc.last
                        if ($idx -eq 0) { $null = & $pressBtn (& $findBtn $wnd $wpfKey) 0 }
                        elseif ($idx -eq 1) { $null = & $pressBtn (& $findBtn $wnd $wpfKey) 1 }
                        elseif ($idx -eq 2) { $null = & $pressBtn (& $findBtn $wnd $wpfFallbackKey) 0 }
                        else { & $closeWnd $wnd $FallbackId }
                    }
                    else {
                        $loc.last = $winNames[$idx]; $st.rung = $loc.last
                        if ($idx -eq 0) { $null = $nat::PostButtonClick($h, $winId) }
                        elseif ($idx -eq 1) { $null = $nat::PostCommand($h, $winId) }
                        elseif ($idx -eq 2) { $null = $nat::PostCommand($h, $FallbackId) }
                        else { $null = $nat::PostClose($h) }
                    }
                }
            }
        }
        else {
            if ($st.found -and $st.closedBy -eq '') { $st.closedBy = $loc.last; Write-Host ("INFO: box '" + $Caption + "' closed by rung: " + $loc.last + " (" + $loc.path + ")") }
            elseif (-not $st.found -and $ms -gt 8000) { $st.timedOut = $true }
        }
    }.GetNewClosure()
    $wf = New-Object System.Windows.Forms.Timer
    $wf.Interval = 50
    $wf.Add_Tick(({ & $body }).GetNewClosure())
    $dt = New-Object System.Windows.Threading.DispatcherTimer
    $dt.Interval = [TimeSpan]::FromMilliseconds(50)
    $dt.Add_Tick(({ & $body }).GetNewClosure())
    $ctl = [pscustomobject]@{ Forms = $wf; Disp = $dt }
    Add-Member -InputObject $ctl -MemberType ScriptMethod -Name Stop -Value { try { $this.Forms.Stop() } catch { $null = $_ }; try { $this.Disp.Stop() } catch { $null = $_ } }
    Add-Member -InputObject $ctl -MemberType ScriptMethod -Name Dispose -Value { try { $this.Disp.Stop() } catch { $null = $_ }; try { $this.Forms.Dispose() } catch { $null = $_ } }
    $script:objs.Add($ctl)
    $wf.Start()
    $dt.Start()
    return $ctl
}

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
    return $list.ToArray()
}

# The text of every TextBlock in an element's visual tree (an AccessText draws its text in an inner TextBlock, without the key underscore).
function Get-ShellInlineText($Inlines) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($i in $Inlines) {
        if ($i -is [System.Windows.Documents.Run]) { [void]$sb.Append([string]$i.Text) }
        elseif ($i -is [System.Windows.Documents.Span]) { [void]$sb.Append((Get-ShellInlineText $i.Inlines)) }
        elseif ($i -is [System.Windows.Documents.LineBreak]) { [void]$sb.Append("`n") }
    }
    return $sb.ToString()
}

# The text a TextBlock draws: its Text, or (an AccessText draws through Run inlines and leaves Text empty) the joined text of its inlines.
function Get-ShellTexts($Root) {
    $out = New-Object System.Collections.ArrayList
    foreach ($n in @(Get-ShellVisuals $Root)) {
        if ($n -is [System.Windows.Controls.TextBlock]) {
            $t = [string]$n.Text
            if ($t -eq '') { $t = Get-ShellInlineText $n.Inlines }
            [void]$out.Add($t)
        }
    }
    return $out.ToArray()
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

# Stand-ins for the two orchestration functions the Connect page reads when it opens and refreshes (a suite that needs more defines its own after this file).
function GetUiApiKeyStore { return $null }
function GetUiActionAvailabilityNow([bool]$Busy) { return Get-FastLlmUiSnapshotAvailability -Snapshot $script:shellSnap }

# The settings, the install folder and a classic-form stand-in (Initialize reads its title and disposes it).
function Initialize-ShellEnv {
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
    # The window script's own state variables the page Update hooks read (fast-llm-ui.ps1 defines them; StrictMode 2 throws on a missing one).
    $script:child = $null
    $script:vcBroker = $null
    $script:updateRun = $null
}

# The peers the UIA ControlViewWalker would reach below a peer: every descendant peer whose IsControlElement() is true (the walk passes through
# the ones that are not, as UIA does).
function Get-ShellControlViewPeers($Peer) {
    $out = New-Object System.Collections.ArrayList
    $walk = $null
    $walk = {
        param($p)
        try { $p.ResetChildrenCache() } catch { $null = $_ }
        foreach ($c in @($p.GetChildren())) {
            if ($null -eq $c) { continue }
            if ($c.IsControlElement()) { [void]$out.Add($c) }
            & $walk $c
        }
    }
    & $walk $Peer
    return $out.ToArray()
}
