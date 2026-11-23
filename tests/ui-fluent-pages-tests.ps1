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
# P-SLOT task 5 (page host, navigation, page status line): P1, P2, P6, P14
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
