#requires -Version 5.1
# Windows-only checks of the Fluent window pages (Tools, Connect and the page host) in the real shell.
# Like ui-fluent-shell-tests, one dispatcher loop is driven by a step timer: step P0 starts the real shell and enters its Dispatcher.Run,
# and every later step runs from the 50 ms step timer INSIDE that nested frame. The shared helpers are in helpers/UiFluentShellHarness.ps1.
# Each check prints PASS or FAIL with a stable name; the suite ends with "N checks passed" and exits non-zero on any FAIL.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$root = Split-Path $PSScriptRoot -Parent

$onWindows = ($PSVersionTable.PSVersion.Major -le 5) -or [bool](Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue)
if (-not $onWindows) { Write-Host 'SKIP: ui-fluent-pages-tests (Windows only)'; exit 0 }

$script:pass = 0
$script:fail = 0
. (Join-Path $PSScriptRoot 'helpers/UiFluentShellHarness.ps1')

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { Write-Host 'FAIL: the suite must run on an STA thread (powershell -STA)'; exit 1 }
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
if (-not ('Bitworks.FastLlm.Tests.FluentHostNative' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'helpers/FluentHostNative.cs') -ErrorAction Stop }
if (-not ('Bitworks.FastLlm.FluentWindowNative' -as [type])) { Add-Type -Path (Join-Path $root 'src/WindowsFluentWindow.cs') -ErrorAction Stop }
$script:native = [Bitworks.FastLlm.Tests.FluentHostNative]

# Recorded, never shown: a throwing handler must not open a dialog that waits for a person.
$script:dispEx = New-Object System.Collections.Generic.List[string]
$script:threadEx = New-Object System.Collections.Generic.List[string]
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({ param($s, $e) $script:threadEx.Add($e.Exception.ToString()) })

$script:scns = New-Object System.Collections.Generic.List[object]   # windows, closed in cleanup
$script:objs = New-Object System.Collections.Generic.List[object]   # timers, disposed in cleanup
$script:loopStopped = $false
$script:busy = $false
$script:si = 0
$script:fatal = $null

Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force
. (Join-Path $root 'tests/helpers/UiControlStatesMatrix.ps1')
. (Join-Path $root 'src/FastLlm.Update.ps1')
. (Join-Path $root 'src/FastLlm.Components.ps1')
. (Join-Path $root 'src/FastLlm.ServingSettings.ps1')
. (Join-Path $root 'src/FastLlm.UiFluentShell.ps1')

# The real stop function exits the process, so a startup fault would end the suite silently: a throwing one stands in.
function Stop-FastLlmUiFluentStartup {
    param([string]$Reason)
    throw "startup stopped: $Reason"
}

# Counts what the shell's exception handlers record (plain code, a reference list), then runs the real one.
$script:unhandledLog = New-Object System.Collections.ArrayList
$script:origUnhandled = ${function:Invoke-FastLlmUiFluentUnhandled}
function Invoke-FastLlmUiFluentUnhandled {
    param($Exception)
    if ($null -ne $Exception) { [void]$script:unhandledLog.Add([string]$Exception.ToString()) } else { [void]$script:unhandledLog.Add('(null exception)') }
    & $script:origUnhandled -Exception $Exception
}
# After the shell starts, Application.ThreadException has ONE handler (the shell's replaces the suite's), so the exceptions the product recorded count too.
function Check-NoExceptions([string]$Name) {
    $d = @($script:dispEx.ToArray()); $t = @($script:threadEx.ToArray()); $u = @($script:unhandledLog.ToArray())
    Check (($d.Count -eq 0) -and ($t.Count -eq 0) -and ($u.Count -eq 0)) "$Name : no dispatcher or WinForms exception recorded" ("dispatcher=" + ($d -join ' | ') + " winforms=" + ($t -join ' | ') + " shell=" + ($u -join ' | '))
    $script:dispEx.Clear(); $script:threadEx.Clear(); $script:unhandledLog.Clear()
}

# The suite's own stubs stand in for the orchestration the pages read (fast-llm-ui.ps1). They are plain file-level functions, the real shape.
# GetUiStateSnapshot is NOT defined here: fast-llm-ui.ps1 defines it after the seam, so the stub is defined after Initialize (P0), as there.
$script:shellSnap = $null
$script:shellFailMsg = ''
$script:shellOk = $false
$script:markerKey = 'FLPAGES-MARKER-KEY-0123456789'
$script:keyReadCalls = 0
$script:clipboardPayloads = New-Object System.Collections.ArrayList
$script:sideSelectionCalls = 0
$script:sideStepCalls = New-Object System.Collections.ArrayList
$script:connectDialogCalls = 0   # must stay 0 in fluent mode
function GetUiBackgroundRunStatus { return $null }
function ShowFailure($Message) { $script:shellFailMsg = [string]$Message }
function GetUiApiKeyStore { return $null }
function GetUiActionAvailabilityNow([bool]$Busy) { return Get-FastLlmUiSnapshotAvailability -Snapshot $script:shellSnap }
# Returns the marker key and counts the calls (a step that must never read the key checks the count did not move).
function ReadUiApiKey { $script:keyReadCalls++; return [string]$script:markerKey }
function SetUiClipboardPayload($Payload) { [void]$script:clipboardPayloads.Add($Payload) }
function ReadSideSelection { $script:sideSelectionCalls++ }
function LaunchSideStep([string]$Step, [object[]]$Arguments) { [void]$script:sideStepCalls.Add([pscustomobject]@{ Step = $Step; Arguments = @($Arguments) }) }
function ShowConnectDialog { $script:connectDialogCalls++ }

function Invoke-P0-ShellStart {
    Initialize-ShellEnv
    $err = ''
    $initWatch = [System.Diagnostics.Stopwatch]::StartNew()
    try { Initialize-FastLlmUiFluentShell } catch { $err = $_.Exception.Message }
    Write-Host ("INFO: P0 Initialize-FastLlmUiFluentShell took " + $initWatch.ElapsedMilliseconds + " ms")
    Check ($err -eq '') 'P0 the startup did not stop (Initialize-FastLlmUiFluentShell returned)' $err
    if ($err -ne '') { $script:shellOk = $false; return }
    $script:shellOk = $true
    $f = $script:FastLlmUiFluent
    $win = $f.Window
    # The orchestration functions the refresh reads exist only from here, as in fast-llm-ui.ps1.
    Check ([string]$f.TickError -eq '') 'P0 the first refresh in Initialize did not fail (TickError empty before the orchestration functions exist)' "TickError=$($f.TickError)"
    function script:GetUiStateSnapshot([bool]$Busy) { return $script:shellSnap }
    Check ($null -ne $script:form.FastLlmFormState) 'P0 the orchestration form is now the form adapter' 'form has no FastLlmFormState'
    $script:scns.Add([pscustomobject]@{ Window = $win; Form = $script:form; Hwnd = [System.Windows.Interop.WindowInteropHelper]::new($win).Handle; Closed = @{ n = 0 }; Title = $win.Title })
    Check-NoExceptions 'P0'
    # From here the loop owns the thread. A DispatcherTimer re-queues itself only after its Tick returns, and P0 does not return until the loop ends:
    # re-arm the step timer by hand so P1 onward run in the nested frame. The loop ends when the last step calls Stop-ShellLoop, so no step may follow that.
    $script:busy = $false
    $script:tick.Stop()
    $script:tick.Start()
    try { Start-FastLlmUiFluentLoop }
    catch { $script:fail++; Write-Host "FAIL: P0 Start-FastLlmUiFluentLoop threw -- $($_.Exception.ToString())" }
}

# P-steps for the later tasks go here, in order (each is a function named Invoke-P<n>-<Name> that returns early when $script:shellOk is false):
# P-SLOT task 5 filled below: P1, P2, P6, P14
# ---- Task 5: the page host, the navigation, the page status line ----
# Tools and Connect do not exist yet (Tasks 6 and 7 register the real pages). These steps register minimal test-only pages for them when the shell
# has not, so the host is tested with Home plus a page that is not Home. Each hook records what ran.
$script:pageEvents = New-Object System.Collections.ArrayList
$script:pagesLeaveAnswer = $true
$script:testPages = @{}
$script:liveRaised = New-Object System.Collections.ArrayList
$script:connectAdapterClicks = 0
function Test-PagesEnter { [void]$script:pageEvents.Add('enter') }
function Test-PagesLeave { [void]$script:pageEvents.Add('leave'); return [bool]$script:pagesLeaveAnswer }
function Test-PagesUpdate { [void]$script:pageEvents.Add('update') }

# Counts what the live region is raised on (the product function still runs).
$script:origLiveRegion = ${function:Send-FastLlmUiFluentLiveRegion}
function Send-FastLlmUiFluentLiveRegion {
    param($Element)
    [void]$script:liveRaised.Add($Element)
    & $script:origLiveRegion -Element $Element
}

function Get-LiveCount($Element) {
    $n = 0
    foreach ($e in @($script:liveRaised.ToArray())) { if ([object]::ReferenceEquals($e, $Element)) { $n++ } }
    return $n
}

function Add-PagesTestPage([string]$Id, [string]$Nav, [string]$StatusName) {
    if (Test-FastLlmUiFluentPageRegistered -Id $Id) { return }
    # Registered XAML, parsed by the one loader (the source-safety scan allows no other parse)
    $script:FastLlmUiXaml['Test.PagesPage.' + $Id] = '<StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"><TextBlock x:Name="' + $StatusName + '" AutomationProperties.LiveSetting="Polite"/></StackPanel>'
    $page = New-FastLlmUiXamlElement -Name ('Test.PagesPage.' + $Id)
    $els = $script:FastLlmUiFluent.Els
    Add-FastLlmUiFluentElements -Els $els -Root $page -Names @($StatusName)
    Register-FastLlmUiFluentPage -Id $Id -Element $page -Nav $Nav -Status $els[$StatusName] -Enter 'Test-PagesEnter' -Leave 'Test-PagesLeave' -Update 'Test-PagesUpdate'
    $script:testPages[$Id] = $page
}

function Get-NavEntry([string]$Id) {
    foreach ($n in @($script:FastLlmUiFluent.NavItems)) { if ([string]$n['Id'] -ceq $Id) { return $n } }
    return $null
}

function Invoke-P1-PageHostAndNav {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $s = $script:FastLlmUiFluentStrings
    $win = $f.Window
    # Before any test page: an item is enabled exactly when its page is registered
    $mismatch = @()
    foreach ($n in @($f.NavItems)) {
        $registered = ((Get-FastLlmUiFluentPageIdByNav -NavId ([string]$n['Id'])) -ne '')
        if ($registered -ne [bool]$n['Item'].IsEnabled -or $registered -ne [bool]$n['Enabled']) { $mismatch += [string]$n['Id'] }
    }
    Check ($mismatch.Count -eq 0) 'P1 a pane item is enabled exactly when a page is registered for it' ("mismatch=" + ($mismatch -join ','))
    Check ([bool](Get-NavEntry 'NavHome')['Item'].IsEnabled) 'P1 Home is enabled' ''
    foreach ($id in 'NavModels', 'NavSettings') {
        $item = (Get-NavEntry $id)['Item']
        $help = [System.Windows.Automation.AutomationProperties]::GetHelpText($item)
        Check ((-not $item.IsEnabled) -and [string]$item.ToolTip -ceq [string]$s.ComingLater -and $help -ceq [string]$s.ComingLater) "P1 $id is disabled with the ComingLater tooltip and help text" "enabled=$($item.IsEnabled) tip='$($item.ToolTip)' help='$help'"
    }
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Home' -and [object]::ReferenceEquals($els.PageHost.Child, $f.Pages['Home']['Element']) -and $els.NavHome.IsSelected) 'P1 Home is hosted and selected by default' "current=$(Get-FastLlmUiFluentCurrentPage)"
    # Home's Connect an app before the Connect page exists: the adapter click (today's dialog path), the page stays Home
    if (-not (Test-FastLlmUiFluentPageRegistered -Id 'Connect')) {
        $script:connectButton.Add_Click({ $script:connectAdapterClicks++ })
        $els.ConnectButton.RaiseEvent((New-ShellClick $els.ConnectButton ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Invoke-Pump 100
        Check ($script:connectAdapterClicks -eq 1 -and (Get-FastLlmUiFluentCurrentPage) -ceq 'Home') 'P1 with no Connect page registered, Connect an app raises the adapter click once and stays on Home' "clicks=$($script:connectAdapterClicks) current=$(Get-FastLlmUiFluentCurrentPage)"
    }
    # A duplicate element name throws
    $dupThrew = ''
    try { Add-FastLlmUiFluentElements -Els $els -Root $win -Names @('PageHost') } catch { $dupThrew = $_.Exception.Message }
    Check ($dupThrew -match 'already has an element') 'P1 Add-FastLlmUiFluentElements throws on a duplicate name' "message=$dupThrew"
    # The test pages
    Add-PagesTestPage 'Tools' 'NavTools' 'ToolsStatusText'
    Add-PagesTestPage 'Connect' 'NavConnect' 'ConnectStatusText'
    $enabled = @(@($f.NavItems) | Where-Object { [bool]$_['Item'].IsEnabled } | ForEach-Object { [string]$_['Id'] })
    Check (($enabled -join ',') -ceq 'NavHome,NavConnect,NavTools') 'P1 the enabled set is Home, Connect and Tools (Models and Settings stay disabled)' "enabled=$($enabled -join ',')"
    Check ($null -eq (Get-NavEntry 'NavTools')['Item'].ToolTip -and [string]::IsNullOrEmpty([System.Windows.Automation.AutomationProperties]::GetHelpText((Get-NavEntry 'NavTools')['Item']))) 'P1 a page that registers drops its coming-later tooltip and help text' ''
    # Set-FastLlmUiFluentPage returns exactly one bool
    $script:pageEvents.Clear()
    $r = Set-FastLlmUiFluentPage -Id 'Tools'
    Check (@($r).Count -eq 1 -and $r -is [bool] -and $r) 'P1 Set-FastLlmUiFluentPage returns exactly one bool (true) for a registered page' "count=$(@($r).Count) value=$r"
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Tools' -and [object]::ReferenceEquals($els.PageHost.Child, $f.Pages['Tools']['Element']) -and $els.NavTools.IsSelected -and -not $els.NavHome.IsSelected) 'P1 Tools is hosted and its item is selected' "current=$(Get-FastLlmUiFluentCurrentPage)"
    Check (($script:pageEvents -join ',') -ceq 'enter') 'P1 Enter ran once on arrival' "events=$($script:pageEvents -join ',')"
    $script:pageEvents.Clear()
    $r2 = Set-FastLlmUiFluentPage -Id 'Tools'
    Check (@($r2).Count -eq 1 -and $r2 -and $script:pageEvents.Count -eq 0) 'P1 the current page does nothing (no Leave, no Enter)' "events=$($script:pageEvents -join ',')"
    $r3 = Set-FastLlmUiFluentPage -Id 'Models'
    Check (@($r3).Count -eq 1 -and $r3 -is [bool] -and -not $r3 -and (Get-FastLlmUiFluentCurrentPage) -ceq 'Tools') 'P1 an unregistered page returns false and changes nothing' "value=$r3"
    $r4 = Set-FastLlmUiFluentPage -Id 'Connect'
    Check ($r4 -and (Get-FastLlmUiFluentCurrentPage) -ceq 'Connect' -and [object]::ReferenceEquals($els.PageHost.Child, $f.Pages['Connect']['Element']) -and $els.NavConnect.IsSelected) 'P1 Connect is hosted and selected' "current=$(Get-FastLlmUiFluentCurrentPage)"
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Invoke-Pump 100
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Home' -and $els.NavHome.IsSelected -and [object]::ReferenceEquals($els.PageHost.Child, $f.Pages['Home']['Element'])) 'P1 back on Home' ''
    # Down on Home selects Connect and skips Models
    $win.Activate()
    $null = $els.NavHome.Focus()
    Invoke-Pump 100
    $path = 'KeyDown routed event on the Home item'
    $threw = ''
    try {
        $src = [System.Windows.PresentationSource]::FromVisual($els.NavHome)
        $ke = New-Object System.Windows.Input.KeyEventArgs([System.Windows.Input.Keyboard]::PrimaryDevice, $src, 0, [System.Windows.Input.Key]::Down)
        $ke.RoutedEvent = [System.Windows.Input.Keyboard]::KeyDownEvent
        $els.NavHome.RaiseEvent($ke)
    }
    catch { $threw = $_.Exception.Message }
    Invoke-Pump 150
    if (-not $els.NavConnect.IsSelected) {
        # The synthetic KeyDown did not reach the list navigation: post a real WM_KEYDOWN (VK_DOWN) to the window instead.
        $path = 'PostMessage WM_KEYDOWN VK_DOWN to the window'
        $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($win).Handle
        $nat = $script:native
        $null = $nat::PostMessage($hwnd, [uint32]0x0100, [IntPtr]0x28, [IntPtr]::Zero)
        Invoke-Pump 300 ({ $script:FastLlmUiFluent.Els.NavConnect.IsSelected })
    }
    Write-Host ("INFO: P1 Down on Home: path used = " + $path + "; current page = " + (Get-FastLlmUiFluentCurrentPage))
    Check ($threw -eq '' -and $els.NavConnect.IsSelected -and (Get-FastLlmUiFluentCurrentPage) -ceq 'Connect' -and -not $els.NavList.Items[1].IsSelected) 'P1 Down on Home selects Connect and skips the disabled Models' "path=$path current=$(Get-FastLlmUiFluentCurrentPage) error=$threw"
    $null = Set-FastLlmUiFluentPage -Id 'Tools'
    Invoke-Pump 100
    # A null selection, a disabled item and a refused Leave all return the selection to the current page's item
    $els.NavList.SelectedItem = $null
    Invoke-Pump 150
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Tools' -and $els.NavTools.IsSelected) 'P1 a null selection re-selects the current page item' "current=$(Get-FastLlmUiFluentCurrentPage)"
    $els.NavList.SelectedIndex = 1
    Invoke-Pump 150
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Tools' -and $els.NavTools.IsSelected -and -not $els.NavList.Items[1].IsSelected) 'P1 selecting a disabled item re-selects the current page item' "current=$(Get-FastLlmUiFluentCurrentPage)"
    $script:pagesLeaveAnswer = $false
    $script:pageEvents.Clear()
    $els.NavList.SelectedIndex = 0
    Invoke-Pump 150
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Tools' -and $els.NavTools.IsSelected -and -not $els.NavHome.IsSelected -and [object]::ReferenceEquals($els.PageHost.Child, $f.Pages['Tools']['Element']) -and $script:pageEvents.Contains('leave')) 'P1 a Leave that refuses keeps the page and re-selects its item' "current=$(Get-FastLlmUiFluentCurrentPage) events=$($script:pageEvents -join ',')"
    $r5 = Set-FastLlmUiFluentPage -Id 'Home'
    Check (@($r5).Count -eq 1 -and $r5 -is [bool] -and -not $r5) 'P1 Set-FastLlmUiFluentPage returns false when Leave refuses' "value=$r5"
    $script:pagesLeaveAnswer = $true
    $els.NavList.SelectedIndex = 0
    Invoke-Pump 150
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Home' -and $els.NavHome.IsSelected) 'P1 a click on Home leaves Tools once Leave allows it' "current=$(Get-FastLlmUiFluentCurrentPage)"
    Check-NoExceptions 'P1'
}

function Invoke-P2-ConnectAnApp {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $win = $f.Window
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    $win.Activate()
    $script:pageEvents.Clear()
    $els.ConnectButton.RaiseEvent((New-ShellClick $els.ConnectButton ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Invoke-Pump 200
    $focused = [System.Windows.Input.FocusManager]::GetFocusedElement($win)
    $hasFocus = ([object]::ReferenceEquals($focused, $els.NavConnect) -or $els.NavConnect.IsKeyboardFocused)
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Connect' -and $els.NavConnect.IsSelected) 'P2 Connect an app hosts the Connect page' "current=$(Get-FastLlmUiFluentCurrentPage)"
    Check $hasFocus 'P2 Connect an app puts the focus on the Connect pane item' "focused=$(if ($null -ne $focused) { $focused.GetType().Name } else { 'nothing' })"
    Check ($script:connectDialogCalls -eq 0) 'P2 ShowConnectDialog stays at 0' "calls=$($script:connectDialogCalls)"
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Check-NoExceptions 'P2'
}

function Invoke-P6-PageStatusLine {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $null = Set-FastLlmUiFluentPage -Id 'Tools'
    Invoke-FastLlmUiFluentTick
    $script:liveRaised.Clear(); $script:pageEvents.Clear()
    $script:statusLabel.Text = 'Pages status line one'
    Invoke-FastLlmUiFluentTick
    $composed = [string]$f.Keys['Composed']
    $toolsText = [string]$els.ToolsStatusText.Text
    $toolsName = [System.Windows.Automation.AutomationProperties]::GetName($els.ToolsStatusText)
    Check ($composed -match 'Pages status line one' -and $toolsText -ceq $composed -and $toolsName -ceq $composed) 'P6 a statusLabel change on Tools writes the composed line to the Tools status text and its name' "composed='$composed' text='$toolsText' name='$toolsName'"
    Check ((Get-LiveCount $els.ToolsStatusText) -eq 1 -and (Get-LiveCount $els.StatusDetail) -eq 0) 'P6 one event on the Tools status text and none on StatusDetail' "tools=$(Get-LiveCount $els.ToolsStatusText) detail=$(Get-LiveCount $els.StatusDetail)"
    Check (([string]$els.ConnectStatusText.Text) -ceq $composed) 'P6 every registered page shows the composed line, not only the current one' "connect='$($els.ConnectStatusText.Text)'"
    Check (@($script:pageEvents | Where-Object { $_ -ceq 'update' }).Count -ge 1) 'P6 the current page Update hook ran in the tick' "events=$($script:pageEvents -join ',')"
    $script:liveRaised.Clear()
    Invoke-FastLlmUiFluentTick
    Check ($script:liveRaised.Count -eq 0) 'P6 an unchanged line raises nothing' "raised=$($script:liveRaised.Count)"
    # A page swap raises nothing
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Invoke-Pump 100
    Check ($script:liveRaised.Count -eq 0) 'P6 a page swap raises no live-region event' "raised=$($script:liveRaised.Count)"
    # On Home the announcement is on StatusDetail only; Tools gets the text without an event
    $script:pageEvents.Clear()
    $script:statusLabel.Text = 'Pages status line two'
    Invoke-FastLlmUiFluentTick
    $composed2 = [string]$f.Keys['Composed']
    Check ((Get-LiveCount $els.StatusDetail) -eq 1 -and (Get-LiveCount $els.ToolsStatusText) -eq 0 -and ([string]$els.ToolsStatusText.Text) -ceq $composed2) 'P6 on Home the event is on StatusDetail only and Tools still gets the new text' "detail=$(Get-LiveCount $els.StatusDetail) tools=$(Get-LiveCount $els.ToolsStatusText) text='$($els.ToolsStatusText.Text)'"
    Check (@($script:pageEvents | Where-Object { $_ -ceq 'update' }).Count -eq 0) 'P6 a page that is not current gets no Update' "events=$($script:pageEvents -join ',')"
    Check (([string]$els.StatusDetail.Text) -ceq 'Pages status line two') 'P6 Home keeps the adapter text on StatusDetail (the page status only names it)' "text='$($els.StatusDetail.Text)'"
    Check-NoExceptions 'P6'
}

function Invoke-P14-TrayRestore {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $win = $f.Window
    # The tray button still raises the adapter click the orchestration listens to (once), and does not move the page
    $script:trayClicks = 0
    $script:trayButton.Add_Click({ $script:trayClicks++ })
    $null = Set-FastLlmUiFluentPage -Id 'Tools'
    $els.TrayButton.RaiseEvent((New-ShellClick $els.TrayButton ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Invoke-Pump 100
    Check ($script:trayClicks -eq 1 -and (Get-FastLlmUiFluentCurrentPage) -ceq 'Tools') 'P14 the Minimize to tray button raises its adapter click once and keeps the page' "clicks=$($script:trayClicks) current=$(Get-FastLlmUiFluentCurrentPage)"
    # The RestoreFromTray sequence (as the orchestration runs it) keeps the current page
    $win.WindowState = [System.Windows.WindowState]::Minimized
    $script:form.Hide()
    Invoke-Pump 100
    $script:form.Show()
    $script:form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $script:form.Activate()
    Invoke-Pump 150
    Check ($win.WindowState -eq [System.Windows.WindowState]::Normal -and (Get-FastLlmUiFluentCurrentPage) -ceq 'Tools' -and [object]::ReferenceEquals($els.PageHost.Child, $f.Pages['Tools']['Element']) -and $els.NavTools.IsSelected) 'P14 Restore from the tray keeps the page that was current' "state=$($win.WindowState) current=$(Get-FastLlmUiFluentCurrentPage)"
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Check-NoExceptions 'P14'
}

# P-SLOT task 6 (Tools page): later P-steps
# P-SLOT task 7 (Connect page, the API key): later P-steps
# P-SLOT task 8 (Connect page, the remaining actions and first-time dialogs): later P-steps

# Faults are injected last: each Initialize run replaces the shell state, so nothing after this may use the real shell.
function Invoke-P99-StartupFaults {
    if (-not $script:shellOk) { return }
    try { $script:FastLlmUiFluent.Timer.Stop() } catch { $null = $_ }
    Check ($script:connectDialogCalls -eq 0) 'P99 ShowConnectDialog was never called in fluent mode' "calls=$($script:connectDialogCalls)"
    Check-NoExceptions 'P99'
}

$script:steps = @(
    # P0 enters the shell's message loop; every step after it runs inside that loop's frame
    'Invoke-P0-ShellStart',
    'Invoke-P1-PageHostAndNav', 'Invoke-P2-ConnectAnApp', 'Invoke-P6-PageStatusLine', 'Invoke-P14-TrayRestore',
    # P-SLOT step names of the later tasks are added here, before P99
    'Invoke-P99-StartupFaults'
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
        $stepWatch = [System.Diagnostics.Stopwatch]::StartNew()
        try { $null = & $name }
        catch { $script:fail++; Write-Host "FAIL: step $name threw -- $($_.Exception.ToString())" }
        Write-Host ("INFO: step $name took " + $stepWatch.ElapsedMilliseconds + " ms")
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
