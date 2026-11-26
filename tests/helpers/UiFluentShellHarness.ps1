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

# A WinForms timer that finds a message box by its caption, records the owner and the WPF window state, then closes it with an escalation
# ladder, one rung per second: BM_CLICK(id), WM_COMMAND(id), WM_COMMAND(FallbackId), WM_CLOSE. A YesNo box ignores WM_CLOSE and has no IDCANCEL, so the ladder starts with the button and a Yes/No caller passes -FallbackId 7 (IDNO).
# Records which rung closed the box and whether buttons 1 and 2 exist. After 6 s a still-open box gets WM_CLOSE and hardStop is set (the caller fails the case).
function Start-BoxAnswer([string]$Caption, [int]$ButtonId, [IntPtr]$Hwnd, [hashtable]$St, [int]$FallbackId = 2) {
    $St.found = $false; $St.during = $null; $St.owner = [long]0; $St.timedOut = $false; $St.hardStop = $false; $St.rung = ''; $St.closedBy = ''
    $st = $St
    $nat = $script:native
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $loc = @{ rung = -1; foundAt = [long]0; last = '' }
    $names = @('BM_CLICK id', 'WM_COMMAND id', 'WM_COMMAND fallback', 'WM_CLOSE')
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
                    elseif ($idx -eq 2) { $null = $nat::PostCommand($h, $FallbackId) }
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
