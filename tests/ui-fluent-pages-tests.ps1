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
. (Join-Path $root 'src/FastLlm.ConnectInfo.ps1')
. (Join-Path $root 'src/FastLlm.UiFluentShell.ps1')

# The real stop function exits the process, so a startup fault would end the suite silently: its text is kept for one check (P99), then a throwing one stands in.
$script:realStopText = [string](Get-Command Stop-FastLlmUiFluentStartup -CommandType Function).Definition
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
$script:markerKey = 'fl-FLPAGESMARKERKEY0123456789abcdefghijklmnopq'   # a well-formed key, so the copy routine treats it as one
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
$script:keyReadNull = $false
function ReadUiApiKey { $script:keyReadCalls++; if ($script:keyReadNull) { return $null }; return [string]$script:markerKey }
function SetUiClipboardPayload($Payload) { [void]$script:clipboardPayloads.Add($Payload) }
function ReadSideSelection { $script:sideSelectionCalls++ }
$script:sideStepThrows = $false
function LaunchSideStep([string]$Step, [object[]]$Arguments) { if ($script:sideStepThrows) { throw 'side step boom' }; [void]$script:sideStepCalls.Add([pscustomobject]@{ Step = $Step; Arguments = @($Arguments) }) }
function ShowConnectDialog { $script:connectDialogCalls++ }
# The tray menu and reveal calls the driver-guidance dialog makes (fast-llm-ui.ps1 defines them); the suite records the tray calls.
$script:trayAvailability = New-Object System.Collections.ArrayList
function RevealUiForAction { }
function SetTrayMenuAvailable([bool]$Available) { [void]$script:trayAvailability.Add($Available) }
# The two first-time dialogs P13 checks are the real ones: their definitions are taken by name from fast-llm-ui.ps1 with the PowerShell parser (nothing is run
# from that file but these two functions), so the owner they pass is the one that ships. A missing function is a FAIL in P13.
$script:p13Missing = @()
$uiAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'fast-llm-ui.ps1'), [ref]$null, [ref]$null)
foreach ($fnName in 'ShowUiSideResult', 'ShowDriverGuidance') {
    $script:p13Want = $fnName
    $def = $uiAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $script:p13Want }, $true)
    if ($null -eq $def) { $script:p13Missing += $fnName; continue }
    . ([scriptblock]::Create([string]$def.Extent.Text))
}
# $script:child, $script:vcBroker and $script:updateRun are defined by Initialize-ShellEnv (the shared harness).
$script:selection = @()   # the side-step arguments the API check appends (fast-llm-ui.ps1 defines it)

# ---- PR 3b Task 8: the Models page's orchestration stand-ins ----
# The three Remove flows, the two list fills, ReadSelection and GetBarValue are the REAL functions of fast-llm-ui.ps1, taken by name with the PowerShell parser
# (nothing else is run from that file), so the tests run the code that ships, the two refresh lines included. Everything those functions CALL is a script-scope
# shadow below: the store, the operation lock, the picker, the settings writer and the three dialogs. All of them append to ONE ordered log.
$script:modelsLog = New-Object System.Collections.ArrayList
$script:modelsStore = New-Object System.Collections.ArrayList        # installed model rows: id, sizeBytes, inUse, inUseReason
$script:componentsStore = New-Object System.Collections.ArrayList    # installed component rows: id, label
$script:leftoverStore = New-Object System.Collections.ArrayList      # leftover partial downloads: name, sizeBytes, locked
$script:modelsLockThrows = $false      # true: another process holds the operation lock (the no-wait enter throws)
$script:modelsLockDepth = 0
$script:modelsLockMax = 0
$script:modelsRemoveCalls = 0
$script:modelsLockHeldSeen = New-Object System.Collections.ArrayList   # the -OperationLockHeld hand-off of every remove call
$script:modelsRebuilds = 0             # the model list rebuilds (wrapped below)
$script:componentsRebuilds = 0
$script:pickerCalls = 0
$script:pickerItems = @()
$script:pickerMessage = ''
$script:pickRequests = New-Object System.Collections.ArrayList
$script:settingsWrites = New-Object System.Collections.ArrayList       # the vulkanBarMitigation value of every Write-FastLlmUiSettings call
$script:dialogCalls = @{ switch = 0; models = 0; components = 0; recipe = 0 }
$script:modelsView = $null
$script:componentsView = $null
$script:barValues = @('auto', 'on', 'off')
# The real functions' script blocks, captured before the wrappers below replace them. Not Get-Command: a FunctionInfo is updated in place when the
# function is redefined in the same scope, so calling it from the wrapper would call the wrapper itself (endless recursion).
$script:realConfirmText = ${function:Get-FastLlmModelRemovalConfirmationText}
$script:realRefusalText = ${function:Get-FastLlmModelRemovalRefusalText}
$script:p22Missing = @()
foreach ($fnName in 'RemoveModelFromWindow', 'RemoveLeftoversFromWindow', 'RemoveComponentFromWindow', 'FillModelsPanel', 'FillComponentsPanel', 'ReadSelection', 'GetBarValue') {
    $script:p13Want = $fnName
    $def = $uiAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $script:p13Want }, $true)
    if ($null -eq $def) { $script:p22Missing += $fnName; continue }
    . ([scriptblock]::Create([string]$def.Extent.Text))
}
# The real classic wiring of the BAR box (its Add_SelectedIndexChanged statement), attached in P0 to the adapter.
$script:barWiringText = ''
$barStatement = $uiAst.Find({ param($node) $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$node.Member.Extent.Text -ceq 'Add_SelectedIndexChanged' -and [string]$node.Expression.Extent.Text -ceq '$barBox' }, $true)
if ($null -ne $barStatement) { $script:barWiringText = [string]$barStatement.Extent.Text }

function Get-FastLlmInstalledModels { param([string]$InstallRoot, [string]$CatalogPath) return @($script:modelsStore.ToArray()) }
function Remove-FastLlmInstalledModel {
    param([string]$InstallRoot, [string]$CatalogPath, [string]$ModelId, [switch]$OperationLockHeld)
    $script:modelsRemoveCalls++
    [void]$script:modelsLockHeldSeen.Add([bool]$OperationLockHeld)
    [void]$script:modelsLog.Add('remove:' + $ModelId)
    $hit = $null
    foreach ($installed in $script:modelsStore) { if ([string]$installed.id -ceq $ModelId) { $hit = $installed } }
    if ($null -eq $hit) { return [pscustomobject]@{ removed = $false; reason = 'not-installed' } }
    $script:modelsStore.Remove($hit)
    return [pscustomobject]@{ removed = $true; reason = 'ok' }
}
function Enter-FastLlmOperation {
    param([string]$InstallRoot)
    if ($script:modelsLockThrows) { [void]$script:modelsLog.Add('lock-refused'); throw 'The operation lock is held by another process.' }
    $script:modelsLockDepth++
    if ($script:modelsLockDepth -gt $script:modelsLockMax) { $script:modelsLockMax = $script:modelsLockDepth }
    [void]$script:modelsLog.Add('lock')
    $handle = [pscustomobject]@{ Kind = 'modelsLock' }
    Add-Member -InputObject $handle -MemberType ScriptMethod -Name Dispose -Value { $script:modelsLockDepth--; [void]$script:modelsLog.Add('release') }
    return $handle
}
function Get-FastLlmModelLeftovers { param([string]$InstallRoot) return @($script:leftoverStore.ToArray()) }
function Remove-FastLlmModelLeftovers {
    param([string]$InstallRoot, [string[]]$Names, [switch]$OperationLockHeld)
    [void]$script:modelsLockHeldSeen.Add([bool]$OperationLockHeld)
    [void]$script:modelsLog.Add('remove-leftovers:' + (@($Names) -join ','))
    $results = New-Object System.Collections.ArrayList
    foreach ($name in @($Names)) {
        $hit = $null
        foreach ($left in $script:leftoverStore) { if ([string]$left.name -ceq $name) { $hit = $left } }
        if ($null -ne $hit) { $script:leftoverStore.Remove($hit) }
        [void]$results.Add([pscustomobject]@{ removed = ($null -ne $hit); reason = '' })
    }
    return $results.ToArray()
}
function Get-FastLlmModelStoreFreeBytes { param([string]$InstallRoot) return [int64]123456789012 }
function Get-FastLlmComponentInventory { param([string]$ComponentsPath, [string]$InstallRoot) return @() }
function Get-FastLlmInstalledComponentRows { param([object[]]$Inventory) return @($script:componentsStore.ToArray()) }
function Remove-FastLlmComponent {
    param([string]$ComponentsPath, [string]$ComponentId, [string]$InstallRoot, [switch]$OperationLockHeld)
    $script:modelsRemoveCalls++
    [void]$script:modelsLockHeldSeen.Add([bool]$OperationLockHeld)
    [void]$script:modelsLog.Add('remove-component:' + $ComponentId)
    $hit = $null
    foreach ($comp in $script:componentsStore) { if ([string]$comp.id -ceq $ComponentId) { $hit = $comp } }
    if ($null -ne $hit) { $script:componentsStore.Remove($hit) }
}
# The confirmation text is the real function's; the wrapper only logs that the confirmation was asked for (the box shows right after this call).
function Get-FastLlmModelRemovalConfirmationText {
    param([string]$DisplayName, [int64]$SizeBytes)
    [void]$script:modelsLog.Add('confirm:' + $DisplayName)
    return (& $script:realConfirmText -DisplayName $DisplayName -SizeBytes $SizeBytes)
}
function Get-FastLlmStatus { param([string]$InstallRoot) return $null }
function Get-FastLlmUiSwitchPickerModel {
    param([string]$InstallRoot, [string]$CatalogPath, $Status, [scriptblock]$RowsProvider)
    $script:pickerCalls++
    return [pscustomobject]@{ items = @($script:pickerItems); message = [string]$script:pickerMessage }
}
function Invoke-FastLlmUiSwitchPick {
    param([string]$InstallRoot, [string]$CatalogPath, $Items, [string]$ModelId, [scriptblock]$Request)
    [void]$script:pickRequests.Add($ModelId)
    return [pscustomobject]@{ ok = $true; text = ('Switch to ' + $ModelId + ' requested (probe).') }
}
function Write-FastLlmUiSettings { param([string]$InstallRoot, $Settings) [void]$script:settingsWrites.Add([string]$Settings.vulkanBarMitigation) }
# The three dialogs the classic buttons open and the recipe list: counters only. Fluent mode must never reach the first three (P20, P99).
function ShowUiSwitchPicker { $script:dialogCalls['switch']++ }
function ShowModelsWindow { $script:dialogCalls['models']++ }
function ShowComponentsWindow { $script:dialogCalls['components']++ }
function StartRecipeList { $script:dialogCalls['recipe']++ }
# The list rebuilds, counted and logged (the real functions still run). The remove flows reach them through the view's refresh key, by name.
$script:origModelsList = ${function:Update-FastLlmUiFluentModelsList}
function Update-FastLlmUiFluentModelsList {
    $script:modelsRebuilds++
    [void]$script:modelsLog.Add('rebuild')
    & $script:origModelsList
}
$script:origComponentsList = ${function:Update-FastLlmUiFluentComponentsList}
function Update-FastLlmUiFluentComponentsList {
    $script:componentsRebuilds++
    [void]$script:modelsLog.Add('rebuild-components')
    & $script:origComponentsList
}

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
    # The real wiring of fast-llm-ui.ps1 (its `$connectButton.Add_Click` line), a plain scriptblock that calls the file-level stub. Home's Connect an app row has no
    # Event, so only a raised adapter Click can reach it: P2 asserts it stays at 0 while the page is registered, and proves with a control that the counter can move.
    $script:connectButton.Add_Click({ try { ShowConnectDialog } catch { ShowFailure $_.Exception.Message } })
    # The same real-shaped wiring for the buttons whose classic click opens a dialog (Task 8 counts them: Switch, Downloaded models and Components never open one from
    # the Fluent pages) and for Choose another setup (StartRecipeList), plus the BAR box's real SelectedIndexChanged statement taken from fast-llm-ui.ps1.
    $script:switchButton.Add_Click({ try { ShowUiSwitchPicker } catch { ShowFailure $_.Exception.Message } })
    $script:modelsButton.Add_Click({ try { ShowModelsWindow } catch { ShowFailure $_.Exception.Message } })
    $script:componentsButton.Add_Click({ try { ShowComponentsWindow } catch { ShowFailure $_.Exception.Message } })
    $script:chooseButton.Add_Click({ try { StartRecipeList } catch { ShowFailure $_.Exception.Message } })
    if ($script:barWiringText -ne '') { . ([scriptblock]::Create($script:barWiringText)) }
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

$script:FastLlmUiXaml['Test.PagesPage.Tools'] = @'
<StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <TextBlock x:Name="ToolsStatusText" AutomationProperties.LiveSetting="Polite"/>
</StackPanel>
'@
$script:FastLlmUiXaml['Test.PagesPage.Connect'] = @'
<StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <TextBlock x:Name="ConnectStatusText" AutomationProperties.LiveSetting="Polite"/>
</StackPanel>
'@

# A page the shell registered for real keeps its own hooks: they run through these recorders (the host tests count Enter, Leave and Update).
$script:pagesRealHooks = @{}
function Test-PagesEnterReal {
    [void]$script:pageEvents.Add('enter')
    $orig = $script:pagesRealHooks[(Get-FastLlmUiFluentCurrentPage)]
    if ([string]$orig['Enter'] -ne '') { $null = & ([string]$orig['Enter']) }
}
function Test-PagesLeaveReal {
    [void]$script:pageEvents.Add('leave')
    $orig = $script:pagesRealHooks[(Get-FastLlmUiFluentCurrentPage)]
    $answer = [bool]$script:pagesLeaveAnswer
    if ([string]$orig['Leave'] -ne '') { foreach ($a in @(& ([string]$orig['Leave']))) { if ($a -is [bool] -and -not $a) { $answer = $false } } }
    return $answer
}
function Test-PagesUpdateReal {
    [void]$script:pageEvents.Add('update')
    $orig = $script:pagesRealHooks[(Get-FastLlmUiFluentCurrentPage)]
    if ([string]$orig['Update'] -ne '') { $null = & ([string]$orig['Update']) }
}

function Add-PagesTestPage([string]$Id, [string]$Nav, [string]$StatusName) {
    if (Test-FastLlmUiFluentPageRegistered -Id $Id) {
        # The real page steps aside for a test one: only its hooks are wrapped so the host checks can count them
        $entry = $script:FastLlmUiFluent.Pages[$Id]
        if (-not $script:pagesRealHooks.ContainsKey($Id)) {
            $script:pagesRealHooks[$Id] = @{ Enter = [string]$entry['Enter']; Leave = [string]$entry['Leave']; Update = [string]$entry['Update'] }
            $entry['Enter'] = 'Test-PagesEnterReal'; $entry['Leave'] = 'Test-PagesLeaveReal'; $entry['Update'] = 'Test-PagesUpdateReal'
        }
        return
    }
    # Registered XAML (literal here-strings), parsed by the one loader: the source-safety scan allows no other parse
    if ($Id -ceq 'Tools') { $page = New-FastLlmUiXamlElement -Name 'Test.PagesPage.Tools' } else { $page = New-FastLlmUiXamlElement -Name 'Test.PagesPage.Connect' }
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
    # PR 3b: Models is a registered page now, so only Settings stays greyed with the coming-later text.
    Check ([bool](Get-NavEntry 'NavModels')['Item'].IsEnabled -and $null -eq (Get-NavEntry 'NavModels')['Item'].ToolTip) 'P1 Models is enabled in the pane and carries no coming-later tooltip' "enabled=$((Get-NavEntry 'NavModels')['Item'].IsEnabled) tip='$((Get-NavEntry 'NavModels')['Item'].ToolTip)'"
    foreach ($id in 'NavSettings') {
        $item = (Get-NavEntry $id)['Item']
        $help = [System.Windows.Automation.AutomationProperties]::GetHelpText($item)
        Check ((-not $item.IsEnabled) -and [string]$item.ToolTip -ceq [string]$s.ComingLater -and $help -ceq [string]$s.ComingLater) "P1 $id is disabled with the ComingLater tooltip and help text" "enabled=$($item.IsEnabled) tip='$($item.ToolTip)' help='$help'"
    }
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Home' -and [object]::ReferenceEquals($els.PageHost.Child, $f.Pages['Home']['Element']) -and $els.NavHome.IsSelected) 'P1 Home is hosted and selected by default' "current=$(Get-FastLlmUiFluentCurrentPage)"
    # A duplicate element name throws
    $dupThrew = ''
    try { Add-FastLlmUiFluentElements -Els $els -Root $win -Names @('PageHost') } catch { $dupThrew = $_.Exception.Message }
    Check ($dupThrew -match 'already has an element') 'P1 Add-FastLlmUiFluentElements throws on a duplicate name' "message=$dupThrew"
    # The test pages
    Add-PagesTestPage 'Tools' 'NavTools' 'ToolsStatusText'
    Add-PagesTestPage 'Connect' 'NavConnect' 'ConnectStatusText'
    $enabled = @(@($f.NavItems) | Where-Object { [bool]$_['Item'].IsEnabled } | ForEach-Object { [string]$_['Id'] })
    Check (($enabled -join ',') -ceq 'NavHome,NavModels,NavConnect,NavTools') 'P1 the enabled set is Home, Models, Connect and Tools (only Settings stays disabled)' "enabled=$($enabled -join ',')"
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
    $r3 = Set-FastLlmUiFluentPage -Id 'Settings'
    Check (@($r3).Count -eq 1 -and $r3 -is [bool] -and -not $r3 -and (Get-FastLlmUiFluentCurrentPage) -ceq 'Tools') 'P1 an unregistered page (Settings) returns false and changes nothing' "value=$r3"
    $r4 = Set-FastLlmUiFluentPage -Id 'Connect'
    Check ($r4 -and (Get-FastLlmUiFluentCurrentPage) -ceq 'Connect' -and [object]::ReferenceEquals($els.PageHost.Child, $f.Pages['Connect']['Element']) -and $els.NavConnect.IsSelected) 'P1 Connect is hosted and selected' "current=$(Get-FastLlmUiFluentCurrentPage)"
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Invoke-Pump 100
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Home' -and $els.NavHome.IsSelected -and [object]::ReferenceEquals($els.PageHost.Child, $f.Pages['Home']['Element'])) 'P1 back on Home' ''
    # Down on Home selects Models (a registered page now, so the arrow keys reach it)
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
    if (-not $els.NavModels.IsSelected) {
        # The synthetic KeyDown did not reach the list navigation: post a real WM_KEYDOWN (VK_DOWN) to the window instead.
        $path = 'PostMessage WM_KEYDOWN VK_DOWN to the window'
        $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($win).Handle
        $nat = $script:native
        $null = $nat::PostMessage($hwnd, [uint32]0x0100, [IntPtr]0x28, [IntPtr]::Zero)
        Invoke-Pump 300 ({ $script:FastLlmUiFluent.Els.NavModels.IsSelected })
    }
    Write-Host ("INFO: P1 Down on Home: path used = " + $path + "; current page = " + (Get-FastLlmUiFluentCurrentPage))
    Check ($threw -eq '' -and $els.NavModels.IsSelected -and (Get-FastLlmUiFluentCurrentPage) -ceq 'Models' -and -not $els.NavHome.IsSelected -and -not $els.NavConnect.IsSelected) 'P1 Down on Home selects Models (a registered page now, no longer skipped)' "path=$path current=$(Get-FastLlmUiFluentCurrentPage) navModels=$($els.NavModels.IsSelected) navHome=$($els.NavHome.IsSelected) error=$threw"
    $null = Set-FastLlmUiFluentPage -Id 'Tools'
    Invoke-Pump 100
    # A null selection, an item with no page and a refused Leave all return the selection to the current page's item
    $els.NavList.SelectedItem = $null
    Invoke-Pump 150
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Tools' -and $els.NavTools.IsSelected) 'P1 a null selection re-selects the current page item' "current=$(Get-FastLlmUiFluentCurrentPage)"
    # Every item of the list has a page now (Settings, the one greyed item, lives in the other list), so the Models page is taken out of the registry for this
    # check and put back after it: its item then has no page, which is what a disabled item was before (the guard under test is the same one).
    $modelsEntry = $f.Pages['Models']
    $f.Pages.Remove('Models')
    try {
        $els.NavList.SelectedIndex = 1
        Invoke-Pump 150
        Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Tools' -and $els.NavTools.IsSelected -and -not $els.NavList.Items[1].IsSelected) 'P1 selecting an item that has no registered page re-selects the current page item' "current=$(Get-FastLlmUiFluentCurrentPage) toolsSelected=$($els.NavTools.IsSelected) item1Selected=$($els.NavList.Items[1].IsSelected)"
    }
    finally { $f.Pages['Models'] = $modelsEntry }
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

# ---- PR 3b Task 7: the Activity header's Copy full output button (the lead's flagged risk: Expander.Tag hosting) ----
# Run early (right after P1). Every check name starts with "P16 ACTIVITY-COPY-TAG" so the CI line is easy to find. If a check here fails, change the one
# value $script:FastLlmUiFluentActivityCopySlot in src/FastLlm.UiFluentHome.ps1 from 'Tag' to 'Body' (the plan's fallback slot) and rerun.
$script:activityCopyEvents = New-Object System.Collections.ArrayList
function Add-ActivityCopyEvent { [void]$script:activityCopyEvents.Add('LinkClicked') }
function Invoke-P16-ActivityCopyHeader {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $win = $f.Window
    $s = $script:FastLlmUiFluentStrings
    $slot = [string]$script:FastLlmUiFluentActivityCopySlot
    Write-Host "INFO: P16 the Activity copy slot is '$slot'"
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    $null = $win.Activate()
    $btn = $els['ActivityCopyButton']
    Check ($null -ne $btn -and $btn -is [System.Windows.Controls.Button] -and $btn.Name -ceq 'ActivityCopyButton') 'P16 ACTIVITY-COPY-TAG the code-built header button is in the shell element map (FindName does not find code-built elements)' ''
    if ($null -eq $btn) { return }
    # The failure link's visibility drives the header button (the same adapter), so show it for the checks and put it back after.
    $origVisible = [bool]$script:failureCopyLink.Visible
    $script:failureCopyLink.Visible = $true
    # In the Tag slot the button sits in the header and shows while Activity is collapsed; in the Body fallback it shows only when Activity is expanded.
    $els.ActivityExpander.IsExpanded = ($slot -ceq 'Body')
    Invoke-Pump 150
    Check ($btn.Visibility -eq [System.Windows.Visibility]::Visible -and $btn.IsVisible -and $btn.IsLoaded) 'P16 ACTIVITY-COPY-TAG the header button is visible and loaded (collapsed Activity in the Tag slot)' "visibility=$($btn.Visibility) isVisible=$($btn.IsVisible) loaded=$($btn.IsLoaded)"
    Check ($null -ne $btn.Style -and [object]::ReferenceEquals($btn.Style, $els.FailureCopyButton.Style)) 'P16 ACTIVITY-COPY-TAG the DynamicResource link style resolves (same style object as the failure bar copy link)' "style=$(if ($null -ne $btn.Style) { 'set but not the link style' } else { 'null' })"
    Check ($btn.FontSize -eq $els.FailureCopyButton.FontSize -and [string]$btn.FontFamily -ceq [string]$els.FailureCopyButton.FontFamily) 'P16 ACTIVITY-COPY-TAG the font is inherited as on the failure bar link' "size=$($btn.FontSize) family=$($btn.FontFamily) want size=$($els.FailureCopyButton.FontSize) family=$($els.FailureCopyButton.FontFamily)"
    Check ($btn.Focusable -and $btn.IsEnabled -and $btn.IsTabStop) 'P16 ACTIVITY-COPY-TAG the header button is focusable, enabled and a tab stop' "focusable=$($btn.Focusable) enabled=$($btn.IsEnabled) tabStop=$($btn.IsTabStop)"
    $peer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($btn)
    Check ($null -ne $peer -and $peer.GetName() -ceq [string]$s.CopyFullOutputActivity -and [string]$s.CopyFullOutputActivity -ceq 'Copy full output (Activity)') 'P16 ACTIVITY-COPY-TAG the header button has a peer named Copy full output (Activity)' "name='$(if ($null -ne $peer) { $peer.GetName() })'"
    Check ($null -ne $peer -and $peer.IsControlElement() -and $peer.IsKeyboardFocusable() -and $null -ne $peer.GetPattern([System.Windows.Automation.Peers.PatternInterface]::Invoke)) 'P16 ACTIVITY-COPY-TAG the peer is a control element, keyboard focusable, with the Invoke pattern' ''
    Check ([string]$btn.Content -ceq [string]$script:failureCopyLink.Text -or [string]$btn.Content -ceq (ConvertTo-FastLlmUiAccessText -Text ([string]$script:failureCopyLink.Text) -UseMnemonic ([bool]$script:failureCopyLink.UseMnemonic))) 'P16 ACTIVITY-COPY-TAG the visible text is the adapter caption' "content='$($btn.Content)'"
    # Tab order: toggle, then copy, then (expanded) the Activity box
    $toggle = $els.ActivityExpander.Template.FindName('Hd', $els.ActivityExpander)
    Check ($null -ne $toggle) 'P16 ACTIVITY-COPY-TAG the Expander toggle part is found' ''
    if ($null -ne $toggle) {
        $null = $toggle.Focus()
        Invoke-Pump 100
        $null = $toggle.MoveFocus((New-Object System.Windows.Input.TraversalRequest([System.Windows.Input.FocusNavigationDirection]::Next)))
        Invoke-Pump 100
        $now = [System.Windows.Input.Keyboard]::FocusedElement
        Check ([object]::ReferenceEquals($now, $btn)) 'P16 ACTIVITY-COPY-TAG Tab from the Activity toggle reaches the header button (reachable by Tab)' "focused=$(if ($null -ne $now) { $now.GetType().Name + ':' + [string]$now.Name } else { 'nothing' })"
        $els.ActivityExpander.IsExpanded = $true
        Invoke-Pump 150
        $null = $btn.Focus()
        $null = $btn.MoveFocus((New-Object System.Windows.Input.TraversalRequest([System.Windows.Input.FocusNavigationDirection]::Next)))
        Invoke-Pump 100
        $after = [System.Windows.Input.Keyboard]::FocusedElement
        Check ([object]::ReferenceEquals($after, $els.ActivityBox)) 'P16 ACTIVITY-COPY-TAG Tab from the header button reaches the Activity box (toggle, copy, box)' "focused=$(if ($null -ne $after) { $after.GetType().Name + ':' + [string]$after.Name } else { 'nothing' })"
        $els.ActivityExpander.IsExpanded = $false
    }
    # The copy runs: one adapter LinkClicked per click, by mouse-shaped click and by the UI Automation Invoke pattern
    [void]$script:failureCopyLink.PSObject.Methods['Add_LinkClicked'].Invoke([scriptblock]::Create('Add-ActivityCopyEvent'))
    $script:activityCopyEvents.Clear()
    $btn.RaiseEvent((New-ShellClick $btn ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Invoke-Pump 50
    Check ($script:activityCopyEvents.Count -eq 1) 'P16 ACTIVITY-COPY-TAG a click on the header button runs the copy (one adapter LinkClicked)' "events=$($script:activityCopyEvents.Count)"
    if ($null -ne $peer) { $peer.GetPattern([System.Windows.Automation.Peers.PatternInterface]::Invoke).Invoke() }
    Invoke-Pump 50
    Check ($script:activityCopyEvents.Count -eq 2) 'P16 ACTIVITY-COPY-TAG the UI Automation Invoke runs the copy too (one more LinkClicked)' "events=$($script:activityCopyEvents.Count)"
    # The failure bar's own link still raises exactly one and keeps its own name
    $script:activityCopyEvents.Clear()
    $els.FailureCopyButton.RaiseEvent((New-ShellClick $els.FailureCopyButton ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Invoke-Pump 50
    Check ($script:activityCopyEvents.Count -eq 1) 'P16 ACTIVITY-COPY-TAG the failure bar link still raises one LinkClicked' "events=$($script:activityCopyEvents.Count)"
    # Visible follows the adapter both ways
    $script:failureCopyLink.Visible = $false
    Check ($btn.Visibility -eq [System.Windows.Visibility]::Collapsed) 'P16 ACTIVITY-COPY-TAG the header button hides with the adapter' "visibility=$($btn.Visibility)"
    $script:failureCopyLink.Visible = $origVisible
    Check-NoExceptions 'P16'
}

# Home's Switch and Change go to Models once that page is registered (Task 6 registers it); until then Switch raises today's adapter click and Change does nothing.
$script:homeSwitchAdapterClicks = 0
function Add-HomeSwitchAdapterClick { $script:homeSwitchAdapterClicks++ }
function Invoke-P17-HomeSwitchAndChange {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $win = $f.Window
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    $null = $win.Activate()
    Check ($els.ChangeButton.IsEnabled -and $null -eq $els.ChangeButton.ToolTip) 'P17 Change is enabled and carries no coming-later tooltip' "enabled=$($els.ChangeButton.IsEnabled) tip='$($els.ChangeButton.ToolTip)'"
    if (Test-FastLlmUiFluentPageRegistered -Id 'Models') {
        $els.SwitchButton.RaiseEvent((New-ShellClick $els.SwitchButton ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Invoke-Pump 200
        $focused = [System.Windows.Input.FocusManager]::GetFocusedElement($win)
        Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Models' -and $els.NavModels.IsSelected -and ([object]::ReferenceEquals($focused, $els.NavModels) -or $els.NavModels.IsKeyboardFocused)) 'P17 Home Switch hosts Models and focuses the pane item' "current=$(Get-FastLlmUiFluentCurrentPage)"
        $null = Set-FastLlmUiFluentPage -Id 'Home'
        $els.ChangeButton.RaiseEvent((New-ShellClick $els.ChangeButton ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Invoke-Pump 200
        $box = $els['ModelsModelBox']
        Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Models' -and $null -ne $box -and $box.IsKeyboardFocusWithin) 'P17 Home Change hosts Models and focuses the model box' "current=$(Get-FastLlmUiFluentCurrentPage)"
        $null = Set-FastLlmUiFluentPage -Id 'Home'
    }
    else {
        [void]$script:switchButton.PSObject.Methods['Add_Click'].Invoke([scriptblock]::Create('Add-HomeSwitchAdapterClick'))
        $script:homeSwitchAdapterClicks = 0
        $els.SwitchButton.RaiseEvent((New-ShellClick $els.SwitchButton ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Invoke-Pump 100
        Check ($script:homeSwitchAdapterClicks -eq 1 -and (Get-FastLlmUiFluentCurrentPage) -ceq 'Home') 'P17 Models not registered yet: Home Switch raises today adapter click once and stays on Home' "clicks=$($script:homeSwitchAdapterClicks) current=$(Get-FastLlmUiFluentCurrentPage)"
        $els.ChangeButton.RaiseEvent((New-ShellClick $els.ChangeButton ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Invoke-Pump 100
        Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Home' -and $script:homeSwitchAdapterClicks -eq 1) 'P17 Models not registered yet: Home Change does nothing' "current=$(Get-FastLlmUiFluentCurrentPage)"
    }
    Check-NoExceptions 'P17'
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
    Check ($script:connectDialogCalls -eq 0 -and (Test-FastLlmUiFluentPageRegistered -Id 'Connect')) 'P2 ShowConnectDialog stays at 0 while the Connect page is registered' "calls=$($script:connectDialogCalls)"
    # Control: the counter can move. The adapter event raised directly reaches the real wiring once; then the counter is put back.
    Invoke-FastLlmUiAdapterEvent -Adapter $script:connectButton -Event 'Click'
    Check ($script:connectDialogCalls -eq 1) 'P2 control: a raised adapter Click reaches the wired ShowConnectDialog stub once (the counter can move)' "calls=$($script:connectDialogCalls)"
    $script:connectDialogCalls = 0
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

# ---- Task 6: the Tools page ----
$script:toolsClicks = New-Object System.Collections.ArrayList
function Add-ToolsClick([string]$Name) { [void]$script:toolsClicks.Add($Name) }
function Get-ToolsClickCount([string]$Name) { return @($script:toolsClicks.ToArray() | Where-Object { $_ -ceq $Name }).Count }

function Invoke-P3-ToolsBindings {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $null = Set-FastLlmUiFluentPage -Id 'Tools'
    Invoke-Pump 100
    $rows = @(Get-FastLlmUiFluentToolsBindings)
    Check ($rows.Count -eq 8) 'P3 the Tools table has its 8 rows' "rows=$($rows.Count)"
    foreach ($row in $rows) {
        $adapter = Get-Variable -Name ([string]$row.Name) -Scope Script -ValueOnly
        $el = $els[[string]$row.Element]
        $tag = [string]$row.Element
        $origText = [string]$adapter.Text
        $origEnabled = [bool]$adapter.Enabled
        $origVisible = [bool]$adapter.Visible
        # Text: the sink writes the access text of the adapter caption
        $adapter.Text = 'Probe &caption'
        $want = ConvertTo-FastLlmUiAccessText -Text 'Probe &caption' -UseMnemonic ([bool]$adapter.UseMnemonic)
        Check ([string]$el.Content -ceq [string]$want) "P3 $tag Text reaches the element as access text" "content='$($el.Content)' want='$want'"
        $adapter.Text = $origText
        # Enabled and Visible
        $adapter.Enabled = $false
        $offOk = (-not $el.IsEnabled)
        $adapter.Enabled = $true
        Check ($offOk -and $el.IsEnabled) "P3 $tag Enabled reaches the element both ways" "offOk=$offOk now=$($el.IsEnabled)"
        $adapter.Visible = $false
        $hidden = ($el.Visibility -eq [System.Windows.Visibility]::Collapsed)
        $adapter.Visible = $true
        Check ($hidden -and $el.Visibility -eq [System.Windows.Visibility]::Visible) "P3 $tag Visible reaches the element both ways" "hidden=$hidden now=$($el.Visibility)"
        $adapter.Enabled = $origEnabled
        $adapter.Visible = $origVisible
        # A real-shaped plain handler (a scriptblock that calls a file-level function, no closure) runs once per click
        $event = [string]$row.Event
        $handler = [scriptblock]::Create("Add-ToolsClick '" + [string]$row.Name + "'")
        [void]$adapter.PSObject.Methods[('Add_' + $event)].Invoke($handler)
        $el.RaiseEvent((New-ShellClick $el ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Invoke-Pump 50
        $expected = 1
        if ([string]$row.Name -ceq 'backgroundAttachButton') { $expected = 1 }
        Check ((Get-ToolsClickCount ([string]$row.Name)) -eq $expected) "P3 a click on $tag runs the plain handler once" "count=$(Get-ToolsClickCount ([string]$row.Name))"
    }
    Check ([string]$els.ToolsTitle.Text -ceq [string]$script:FastLlmUiFluentStrings.NavTools) 'P3 the page title is the Tools label' "title='$($els.ToolsTitle.Text)'"
    Check-NoExceptions 'P3'
}

function Invoke-P4-AttachFanOut {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $adapter = $script:backgroundAttachButton
    $origEnabled = [bool]$adapter.Enabled
    $origVisible = [bool]$adapter.Visible
    $homeVis = $els.AttachButton.Visibility
    $adapter.Enabled = $false
    Check ((-not $els.ToolsAttachButton.IsEnabled) -and (-not $els.AttachButton.IsEnabled)) 'P4 Enabled false reaches both the Tools and the Home Attach buttons' "tools=$($els.ToolsAttachButton.IsEnabled) home=$($els.AttachButton.IsEnabled)"
    $adapter.Enabled = $true
    Check ($els.ToolsAttachButton.IsEnabled -and $els.AttachButton.IsEnabled) 'P4 Enabled true reaches both' "tools=$($els.ToolsAttachButton.IsEnabled) home=$($els.AttachButton.IsEnabled)"
    $adapter.Visible = $false
    Check ($els.ToolsAttachButton.Visibility -eq [System.Windows.Visibility]::Collapsed -and $els.AttachButton.Visibility -eq $homeVis) 'P4 Visible follows the adapter on Tools while Home keeps the card visibility' "tools=$($els.ToolsAttachButton.Visibility) home=$($els.AttachButton.Visibility) (was $homeVis)"
    $adapter.Visible = $true
    Check ($els.AttachButton.Visibility -eq $homeVis) 'P4 Home Attach visibility is still the card own after the adapter shows' "home=$($els.AttachButton.Visibility) (was $homeVis)"
    # One click, one event, from either element (the P3 handler counts 'backgroundAttachButton')
    $before = Get-ToolsClickCount 'backgroundAttachButton'
    $els.ToolsAttachButton.RaiseEvent((New-ShellClick $els.ToolsAttachButton ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Invoke-Pump 50
    $afterTools = Get-ToolsClickCount 'backgroundAttachButton'
    $els.AttachButton.RaiseEvent((New-ShellClick $els.AttachButton ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Invoke-Pump 50
    $afterHome = Get-ToolsClickCount 'backgroundAttachButton'
    Check (($afterTools - $before) -eq 1 -and ($afterHome - $afterTools) -eq 1) 'P4 one click on either Attach button raises exactly one adapter event' "tools=$($afterTools - $before) home=$($afterHome - $afterTools)"
    $adapter.Enabled = $origEnabled
    $adapter.Visible = $origVisible
    Check-NoExceptions 'P4'
}

function Invoke-P5-GreyedReasons {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $s = $script:FastLlmUiFluentStrings
    $null = Set-FastLlmUiFluentPage -Id 'Tools'
    $doctor = $script:doctorButton
    $origEnabled = [bool]$doctor.Enabled
    $btn = $els.ToolsDiagnosticsButton
    Check ([System.Windows.Controls.ToolTipService]::GetShowOnDisabled($btn)) 'P5 the Diagnostics button shows its tooltip while disabled' ''
    # Busy: a disabled Diagnostics button says why
    $script:shellSnap = New-ShellSnap @{ Busy = $true }
    $doctor.Enabled = $false
    Invoke-FastLlmUiFluentTick
    $help = [System.Windows.Automation.AutomationProperties]::GetHelpText($btn)
    Check ([string]$btn.ToolTip -ceq [string]$s.WhyBusy -and $help -ceq [string]$s.WhyBusy) 'P5 a busy state shows WhyBusy as ToolTip and HelpText on Diagnostics' "tip='$($btn.ToolTip)' help='$help'"
    # Microsoft setup changes the code
    $script:shellSnap = New-ShellSnap @{ Busy = $true; VcBrokerActive = $true }
    Invoke-FastLlmUiFluentTick
    Check ([string]$btn.ToolTip -ceq [string]$s.WhyMicrosoftSetup) 'P5 Microsoft setup shows WhyMicrosoftSetup' "tip='$($btn.ToolTip)'"
    # Written on change only: a tooltip set by hand survives a tick with the same code
    $btn.ToolTip = 'hand-set'
    Invoke-FastLlmUiFluentTick
    Check ([string]$btn.ToolTip -ceq 'hand-set') 'P5 an unchanged code does not rewrite the tooltip' "tip='$($btn.ToolTip)'"
    # Idle with the button still disabled: an empty code shows nothing
    $script:shellSnap = New-ShellSnap
    Invoke-FastLlmUiFluentTick
    $help2 = [System.Windows.Automation.AutomationProperties]::GetHelpText($btn)
    Check ($null -eq $btn.ToolTip -and $help2 -ceq '') 'P5 an empty code (idle, still disabled) clears the reason and shows nothing' "tip='$($btn.ToolTip)' help='$help2'"
    # Enabled button shows nothing even when busy
    $doctor.Enabled = $true
    $script:shellSnap = New-ShellSnap @{ Busy = $true }
    Invoke-FastLlmUiFluentTick
    Check ($null -eq $btn.ToolTip) 'P5 an enabled button shows no reason' "tip='$($btn.ToolTip)'"
    $script:shellSnap = New-ShellSnap
    $doctor.Enabled = $origEnabled
    Invoke-FastLlmUiFluentTick
    Check ($null -eq $btn.ToolTip -and [System.Windows.Automation.AutomationProperties]::GetHelpText($btn) -ceq '') 'P5 idle clears the reason' "tip='$($btn.ToolTip)'"
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Check-NoExceptions 'P5'
}

# ---- Task 7: the Connect page ----
# The orchestration reads the Connect page makes when it opens are shadowed with fixtures, and the clipboard wrapper and Start-Process record instead of acting.
$script:connectFixture = $null
$script:connectKeyRow = $null
$script:connectInfoCalls = 0
$script:fieldClips = New-Object System.Collections.ArrayList
$script:fieldClipThrow = $false
$script:startedProcs = New-Object System.Collections.ArrayList
function Get-FastLlmConnectionInfo { param($Status, $InstallRoot, $Settings) $script:connectInfoCalls++; return $script:connectFixture }
function Get-FastLlmUiApiKeyRow { param($Info, $Settings, $ApiKeyStore) return $script:connectKeyRow }
function Set-FastLlmUiFluentClipboardText { param([string]$Text) if ($script:fieldClipThrow) { throw 'clipboard boom' }; [void]$script:fieldClips.Add($Text) }
function Start-Process { param([string]$FilePath) [void]$script:startedProcs.Add($FilePath) }

function New-ConnectFixture([hashtable]$O = @{}) {
    $d = @{ state = 'running'; baseUrl = 'http://127.0.0.1:8123/v1'; anthropicBaseUrl = 'http://127.0.0.1:8123'; modelName = 'probe-model'; contextTokens = 8192; apiKey = 'on'
        agentWarning = 'Probe agent warning'
        endpoints = @([pscustomobject]@{ path = '/v1/chat/completions'; label = 'Chat' }, [pscustomobject]@{ path = '/v1/messages'; label = 'Anthropic messages' })
        clients = @(
            [pscustomobject]@{ title = 'Probe client A'; snippet = "export K={KEY}`nexport U=http://127.0.0.1:8123"; docUrls = @('https://example.test/a', 'http://example.test/insecure') },
            [pscustomobject]@{ title = 'Probe client B'; snippet = 'plain snippet without a token'; docUrls = @() }) }
    foreach ($k in $O.Keys) { $d[$k] = $O[$k] }
    return [pscustomobject]$d
}
function New-ConnectRow([bool]$Visible = $true, [bool]$CanShow = $true, [string]$Note = 'Probe key note') {
    return [pscustomobject]@{ visible = $Visible; mask = '********'; canShow = $CanShow; note = $Note }
}
# Before any step opens Connect (P1 and P2 do), the page reads these defaults.
$script:connectFixture = New-ConnectFixture
$script:connectKeyRow = New-ConnectRow
# Sets the fixtures and opens Connect afresh (Home first, so the page is entered).
function Open-ConnectPage($Fixture, $Row) {
    $script:connectFixture = $Fixture
    $script:connectKeyRow = $Row
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    $null = Set-FastLlmUiFluentPage -Id 'Connect'
    Invoke-Pump 100
}
function Invoke-ConnectClick($Element) {
    $Element.RaiseEvent((New-ShellClick $Element ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Invoke-Pump 30
}

# Every place the marker could be: each text, name, help text, tooltip, tag and content in the window and the three pages, every adapter state, and the window's own state.
function Test-ConnectHasMarker($Value, [string]$Marker) {
    if ($null -eq $Value) { return $false }
    if ($Value -isnot [string]) { return $false }
    return ([string]$Value).Contains($Marker)
}
function Add-ConnectDictScan($Obj, [string]$Path, [string]$Marker, [hashtable]$Hits, [int]$Depth) {
    if ($null -eq $Obj -or $Depth -gt 6) { return }
    $base = $Obj.psobject.BaseObject
    if ($base -is [string]) { if (Test-ConnectHasMarker $base $Marker) { $Hits[$Path] = $true }; return }
    if ($base -is [System.Windows.DependencyObject] -or $base -is [Delegate] -or $base -is [scriptblock]) { return }
    if ($base -is [System.Collections.IDictionary]) {
        foreach ($key in @($base.Keys)) { Add-ConnectDictScan $base[$key] ($Path + '/' + [string]$key) $Marker $Hits ($Depth + 1) }
        return
    }
    if ($base -is [System.Management.Automation.PSCustomObject]) {
        foreach ($prop in @($base.psobject.Properties)) { Add-ConnectDictScan $prop.Value ($Path + '.' + [string]$prop.Name) $Marker $Hits ($Depth + 1) }
        return
    }
    if ($base -is [System.Collections.IEnumerable]) {
        $i = 0
        foreach ($item in $base) { Add-ConnectDictScan $item ($Path + '[' + $i + ']') $Marker $Hits ($Depth + 1); $i++ }
    }
}
function Add-ConnectWalk($Node, [string]$Marker, [hashtable]$Hits, [hashtable]$Seen) {
    $base = $Node.psobject.BaseObject
    $id = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($base)
    if ($Seen.ContainsKey($id)) { return }
    $Seen[$id] = $true
    $label = $base.GetType().Name
    if ($base -is [System.Windows.FrameworkElement]) { $label = $label + ':' + [string]$base.Name }
    if ($base -is [System.Windows.Controls.TextBlock] -and (Test-ConnectHasMarker $base.Text $Marker)) { $Hits[$label + '.Text'] = $true }
    if ($base -is [System.Windows.Controls.TextBox] -and (Test-ConnectHasMarker $base.Text $Marker)) { $Hits[$label + '.Text'] = $true }
    if ($base -is [System.Windows.Controls.ContentControl] -and (Test-ConnectHasMarker $base.Content $Marker)) { $Hits[$label + '.Content'] = $true }
    if ($base -is [System.Windows.Controls.HeaderedItemsControl] -and (Test-ConnectHasMarker $base.Header $Marker)) { $Hits[$label + '.Header'] = $true }
    if ($base -is [System.Windows.Window] -and (Test-ConnectHasMarker $base.Title $Marker)) { $Hits[$label + '.Title'] = $true }
    if ($base -is [System.Windows.FrameworkElement]) {
        if (Test-ConnectHasMarker $base.ToolTip $Marker) { $Hits[$label + '.ToolTip'] = $true }
        if (Test-ConnectHasMarker $base.Tag $Marker) { $Hits[$label + '.Tag'] = $true }
    }
    if (Test-ConnectHasMarker ([System.Windows.Automation.AutomationProperties]::GetName($base)) $Marker) { $Hits[$label + '.AutomationName'] = $true }
    if (Test-ConnectHasMarker ([System.Windows.Automation.AutomationProperties]::GetHelpText($base)) $Marker) { $Hits[$label + '.HelpText'] = $true }
    foreach ($child in [System.Windows.LogicalTreeHelper]::GetChildren($base)) {
        if ($child -is [System.Windows.DependencyObject]) { Add-ConnectWalk $child $Marker $Hits $Seen }
        # A TextBox's one non-element logical child is its own Text (already checked above as '.Text'); counting it again would report
        # the key box twice. Every other node's string child is still a holder.
        elseif ($base -is [System.Windows.Controls.TextBox]) { continue }
        elseif (Test-ConnectHasMarker $child $Marker) { $Hits[$label + '/child'] = $true }
    }
}
function Get-ConnectMarkerHolders([string]$Marker) {
    $f = $script:FastLlmUiFluent
    $hits = @{}
    $seen = @{}
    foreach ($root in @($f.Window, $f.Pages['Connect']['Element'], $f.Pages['Home']['Element'], $f.Pages['Tools']['Element'])) { Add-ConnectWalk $root $Marker $hits $seen }
    foreach ($row in (Get-FastLlmUiFluentControlTable)) {
        $adapter = Get-Variable -Name ([string]$row[0]) -Scope Script -ValueOnly
        Add-ConnectDictScan $adapter.__state ('adapter ' + [string]$row[0]) $Marker $hits 0
    }
    Add-ConnectDictScan $f 'state' $Marker $hits 0
    return @($hits.Keys | Sort-Object)
}

function Invoke-P7-ConnectContent {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $t = $script:FastLlmUiFluentConnectText
    $s = $script:FastLlmUiFluentStrings
    $fx = New-ConnectFixture
    Open-ConnectPage $fx (New-ConnectRow)
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Connect' -and [string]$els.ConnectTitle.Text -ceq 'Connect an app') 'P7 Connect is hosted and its title is Connect an app' "current=$(Get-FastLlmUiFluentCurrentPage) title='$($els.ConnectTitle.Text)'"
    $want = @(
        @{ P = 'ConnectBaseUrl'; L = 'Base URL'; V = 'http://127.0.0.1:8123/v1' },
        @{ P = 'ConnectAnthropicUrl'; L = 'Anthropic base URL'; V = 'http://127.0.0.1:8123' },
        @{ P = 'ConnectModelName'; L = 'Model name'; V = 'probe-model' },
        @{ P = 'ConnectContextLimit'; L = 'Context limit (tokens)'; V = '8192' })
    foreach ($w in $want) {
        $box = $els[$w.P + 'Box']; $copy = $els[$w.P + 'Copy']; $label = $els[$w.P + 'Label']
        Check ([string]$box.Text -ceq $w.V -and [string]$copy.Tag -ceq $w.V -and $box.IsReadOnly) "P7 $($w.L): the read-only box and the Copy tag hold the value" "box='$($box.Text)' tag='$($copy.Tag)'"
        Check ([string]$label.Text -ceq $w.L -and [System.Windows.Automation.AutomationProperties]::GetName($box) -ceq $w.L -and [object]::ReferenceEquals([System.Windows.Automation.AutomationProperties]::GetLabeledBy($box), $label)) "P7 $($w.L): the box name and LabeledBy come from the label" ''
        Check ([string]$copy.Content -ceq 'Copy' -and [System.Windows.Automation.AutomationProperties]::GetName($copy) -ceq (([string]$s.CopyFieldFormat) -f $w.L)) "P7 $($w.L): the Copy button says Copy and is named Copy plus the label" "content='$($copy.Content)' name='$([System.Windows.Automation.AutomationProperties]::GetName($copy))'"
    }
    Check ([string]$els.ConnectIntro.Text -ceq [string]$t.IntroRunning) 'P7 the intro follows a running state' "text='$($els.ConnectIntro.Text)'"
    $endpointWant = 'Endpoints on the base URL:' + [Environment]::NewLine + ((@($fx.endpoints) | ForEach-Object { '  ' + $_.path + ' - ' + $_.label }) -join [Environment]::NewLine)
    Check ([string]$els.ConnectEndpoints.Text -ceq $endpointWant) 'P7 the endpoint text is the classic formula' "text='$($els.ConnectEndpoints.Text)'"
    Check ([string]$els.ConnectAgentWarningText.Text -ceq 'Probe agent warning' -and $els.ConnectAgentWarning.Visibility -eq [System.Windows.Visibility]::Visible) 'P7 the agent warning shows in its caution border' ''
    Check ($els.ConnectKeyRow.Visibility -eq [System.Windows.Visibility]::Visible -and $els.ConnectKeyShow.IsEnabled -and $els.ConnectKeyCopy.IsEnabled -and [string]$els.ConnectKeyNote.Text -ceq 'Probe key note' -and $els.ConnectKeyNote.Visibility -eq [System.Windows.Visibility]::Visible) 'P7 a visible key row enables Show and Copy and shows its note' ''
    # The cards
    $cards = @($f.Connect['Cards'])
    Check ($cards.Count -eq 2 -and $els.ConnectClients.Children.Count -eq 2) 'P7 one card per client' "cards=$($cards.Count) children=$($els.ConnectClients.Children.Count)"
    $a = $cards[0]
    $snippetA = [string]$fx.clients[0].snippet
    $displayA = (Get-FastLlmConnectDisplayText -Snippet $snippetA) -replace "`n", [Environment]::NewLine
    Check ([string]$a.Copy.Tag -ceq $snippetA -and [string]$a.Copy.Tag -cmatch '\{KEY\}') 'P7 the card Copy keeps the snippet with its key token in Tag' "tag='$($a.Copy.Tag)'"
    Check ([string]$a.Box.Text -ceq $displayA -and $a.Box.IsReadOnly -and [string]$a.Box.Text -cnotmatch '\{KEY\}') 'P7 the card shows the snippet with the placeholder, read-only' "text='$($a.Box.Text)'"
    Check ([System.Windows.Automation.AutomationProperties]::GetName($a.Box) -ceq 'Probe client A' -and [object]::ReferenceEquals([System.Windows.Automation.AutomationProperties]::GetLabeledBy($a.Box), $a.Title) -and [System.Windows.Automation.AutomationProperties]::GetName($a.Copy) -ceq 'Copy Probe client A') 'P7 the card box is named and labelled by its title, and its Copy by Copy plus the title' ''
    Check (@($a.Links).Count -eq 2 -and @($cards[1].Links).Count -eq 0) 'P7 the doc links are one per url, none for a client without any' "links=$(@($a.Links).Count)"
    $script:startedProcs.Clear()
    $httpLink = @($a.Links | Where-Object { [string]$_.Tag -ceq 'http://example.test/insecure' })[0]
    $httpsLink = @($a.Links | Where-Object { [string]$_.Tag -ceq 'https://example.test/a' })[0]
    Invoke-ConnectClick $httpLink
    Check ($script:startedProcs.Count -eq 0) 'P7 an http doc link opens nothing' "started=$($script:startedProcs -join ',')"
    Invoke-ConnectClick $httpsLink
    Check ($script:startedProcs.Count -eq 1 -and [string]$script:startedProcs[0] -ceq 'https://example.test/a') 'P7 an https doc link opens its url' "started=$($script:startedProcs -join ',')"
    # Not running: the intro, and the two values that appear only once it runs
    Open-ConnectPage (New-ConnectFixture @{ state = 'not-running'; modelName = $null; contextTokens = $null; agentWarning = $null }) (New-ConnectRow $false $false '')
    Check ([string]$els.ConnectIntro.Text -ceq [string]$t.IntroNotRunning) 'P7 the intro follows a not-running state' "text='$($els.ConnectIntro.Text)'"
    Check ([string]$els.ConnectModelNameBox.Text -ceq '(shown when running)' -and [string]$els.ConnectContextLimitBox.Text -ceq '(shown when running)') 'P7 a model name and context limit that are not known say shown when running' ''
    Check ($els.ConnectKeyRow.Visibility -eq [System.Windows.Visibility]::Collapsed -and $els.ConnectKeyNote.Visibility -eq [System.Windows.Visibility]::Collapsed -and $els.ConnectAgentWarning.Visibility -eq [System.Windows.Visibility]::Collapsed) 'P7 no key row, note or warning when there is none' ''
    Open-ConnectPage (New-ConnectFixture) (New-ConnectRow $true $false 'Probe unreadable note')
    Check ($els.ConnectKeyRow.Visibility -eq [System.Windows.Visibility]::Visible -and -not $els.ConnectKeyShow.IsEnabled -and -not $els.ConnectKeyCopy.IsEnabled) 'P7 a key row that cannot be shown disables Show and Copy' ''
    Open-ConnectPage (New-ConnectFixture) (New-ConnectRow)
    Check-NoExceptions 'P7'
}

function Invoke-P8-ConnectKey {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $marker = [string]$script:markerKey
    Open-ConnectPage (New-ConnectFixture) (New-ConnectRow)
    $box = $els.ConnectKeyBox
    $show = $els.ConnectKeyShow
    $baseline = $script:keyReadCalls
    Check ([string]$box.Text -ceq '********' -and [string]$show.Content -ceq 'Show' -and $script:keyReadCalls -eq $baseline) 'P8 the key box starts masked and nothing has read the key' "text='$($box.Text)' reads=$($script:keyReadCalls - $baseline)"
    Check (($box -is [System.Windows.Controls.TextBox]) -and ($box -isnot [System.Windows.Controls.PasswordBox]) -and $box.IsReadOnly -and -not $box.IsUndoEnabled) 'P8 the key box is a read-only TextBox with undo off, not a PasswordBox' ''
    $peer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($box)
    $valuePattern = $peer.GetPattern([System.Windows.Automation.Peers.PatternInterface]::Value)
    Check ((Get-ShellPeerName $box) -ceq 'API key' -and $null -ne $valuePattern -and [bool]$valuePattern.IsReadOnly) 'P8 the key box peer is named API key and has a read-only ValuePattern' "name='$(Get-ShellPeerName $box)'"
    # Show: one read, the marker in the box, the caption is Hide
    Invoke-ConnectClick $show
    Check ($script:keyReadCalls -eq ($baseline + 1) -and [string]$box.Text -ceq $marker -and [string]$show.Content -ceq 'Hide') 'P8 Show reads the key once, the box holds it and the caption becomes Hide' "reads=$($script:keyReadCalls - $baseline) caption='$($show.Content)'"
    $holders = @(Get-ConnectMarkerHolders $marker)
    Check ($holders.Count -eq 1 -and $holders[0] -ceq 'TextBox:ConnectKeyBox.Text') 'P8 marker walk while shown: the marker is in the key box text and nowhere else' "holders=$($holders -join '; ')"
    # The Copy command of the shown box (Ctrl+C, Ctrl+Insert and the context menu are this command) goes through the key copy routine
    $script:fieldClips.Clear(); $script:clipboardPayloads.Clear()
    $target = $box.psobject.BaseObject
    $canCopy = [System.Windows.Input.ApplicationCommands]::Copy.CanExecute($null, $target)
    [System.Windows.Input.ApplicationCommands]::Copy.Execute($null, $target)
    Invoke-Pump 30
    $copied = @($script:clipboardPayloads.ToArray())
    $formatNames = @(); if ($copied.Count -eq 1) { $formatNames = @($copied[0].formats.Keys | Sort-Object) }
    Check ($canCopy -and $copied.Count -eq 1 -and [string]$copied[0].text -ceq $marker -and ($formatNames -join ',') -ceq 'CanIncludeInClipboardHistory,CanUploadToCloudClipboard,ExcludeClipboardContentFromMonitorProcessing' -and $script:fieldClips.Count -eq 0) 'P8 the Copy command on the shown box records the marker with the three exclusion formats and never the plain clipboard wrapper' "can=$canCopy payloads=$($copied.Count) formats=$($formatNames -join ',') plain=$($script:fieldClips.Count)"
    $menuItem = $box.ContextMenu.Items[0]
    Check ($box.ContextMenu.Items.Count -eq 1 -and [object]::ReferenceEquals($menuItem.Command, [System.Windows.Input.ApplicationCommands]::Copy) -and [object]::ReferenceEquals($menuItem.CommandTarget, $box) -and -not [System.Windows.Input.ApplicationCommands]::Cut.CanExecute($null, $target)) 'P8 the context menu is one Copy item bound to the Copy command, and Cut is blocked' ''
    # The context-menu Copy item itself is invoked (through its automation peer, the way a screen reader or a click runs it): the same key payload
    $script:fieldClips.Clear(); $script:clipboardPayloads.Clear()
    $menuPeer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($menuItem)
    $menuPeer.GetPattern([System.Windows.Automation.Peers.PatternInterface]::Invoke).Invoke()
    Invoke-Pump 100
    $menuCopied = @($script:clipboardPayloads.ToArray())
    $menuFormats = @(); if ($menuCopied.Count -eq 1) { $menuFormats = @($menuCopied[0].formats.Keys | Sort-Object) }
    Check ($menuCopied.Count -eq 1 -and [string]$menuCopied[0].text -ceq $marker -and ($menuFormats -join ',') -ceq 'CanIncludeInClipboardHistory,CanUploadToCloudClipboard,ExcludeClipboardContentFromMonitorProcessing' -and $script:fieldClips.Count -eq 0) 'P8 invoking the context-menu Copy item copies the key with the exclusion formats and nothing as plain text' "payloads=$($menuCopied.Count) formats=$($menuFormats -join ',')"
    # A drag of the key text: the DataObject.Copying event is raised with a constructed DataObjectCopyingEventArgs (a drag) and the handler cancels it
    $dragArgs = New-Object System.Windows.DataObjectCopyingEventArgs((New-Object System.Windows.DataObject), $true)
    $dragArgs.RoutedEvent = [System.Windows.DataObject]::CopyingEvent
    $dragArgs.Source = $box
    $box.RaiseEvent($dragArgs)
    Check ($dragArgs.CommandCancelled) 'P8 a drag of the key text (DataObject.Copying raised with a drag argument) is cancelled' ''
    # Select all, then copy: the page binding runs, not the TextBox's own copy (one key payload, no plain text)
    $script:fieldClips.Clear(); $script:clipboardPayloads.Clear()
    $null = $box.Focus()
    $box.SelectAll()
    [System.Windows.Input.ApplicationCommands]::Copy.Execute($null, $target)
    Invoke-Pump 50
    $selCopied = @($script:clipboardPayloads.ToArray())
    Check ($selCopied.Count -eq 1 -and [string]$selCopied[0].text -ceq $marker -and @($selCopied[0].formats.Keys).Count -eq 3 -and $script:fieldClips.Count -eq 0) 'P8 Copy after SelectAll still runs the page binding (the key payload with its formats, no plain text)' "payloads=$($selCopied.Count)"
    $box.Select(0, 0)
    # Hide masks without a read
    $before = $script:keyReadCalls
    Invoke-ConnectClick $show
    Check ([string]$box.Text -ceq '********' -and [string]$show.Content -ceq 'Show' -and $script:keyReadCalls -eq $before -and -not $box.CanUndo) 'P8 Hide masks the box without a read and CanUndo is false' "text='$($box.Text)' undo=$($box.CanUndo)"
    $holders = @(Get-ConnectMarkerHolders $marker)
    Check ($holders.Count -eq 0) 'P8 marker walk after Hide: the marker is nowhere' "holders=$($holders -join '; ')"
    # A failed read keeps the mask and says so
    $script:keyReadNull = $true
    Invoke-ConnectClick $show
    Check ([string]$box.Text -ceq '********' -and [string]$show.Content -ceq 'Show' -and ([string]$script:statusLabel.Text) -ceq 'The stored API key cannot be read.') 'P8 a failed read keeps the mask and sets the status text' "text='$($box.Text)' status='$($script:statusLabel.Text)'"
    $script:keyReadNull = $false
    # Re-masking: leave, IsVisibleChanged, a running-edge refresh
    $remask = @(
        @{ Name = 'leaving the page'; Do = { $null = Set-FastLlmUiFluentPage -Id 'Home' } },
        @{ Name = 'the page becoming invisible'; Do = { $pageElement = $script:FastLlmUiFluent.Pages['Connect']['Element']; $pageElement.Visibility = [System.Windows.Visibility]::Collapsed; $pageElement.Visibility = [System.Windows.Visibility]::Visible } },
        @{ Name = 'the tray path (form Hide)'; Do = { $script:form.Hide(); Invoke-Pump 100; $script:form.Show(); $script:form.Activate() } },
        @{ Name = 'a running-edge refresh'; Do = { $script:FastLlmUiFluent.Keys['Running'] = (-not [bool]$script:FastLlmUiFluent.Keys['Running']); Update-FastLlmUiFluentConnect } })
    foreach ($r in $remask) {
        $null = Set-FastLlmUiFluentPage -Id 'Connect'
        Invoke-Pump 50
        Invoke-ConnectClick $show
        $wasShown = ([string]$box.Text -ceq $marker)
        & $r.Do
        Invoke-Pump 50
        $holders = @(Get-ConnectMarkerHolders $marker)
        Check ($wasShown -and [string]$box.Text -ceq '********' -and [string]$show.Content -ceq 'Show' -and -not $box.CanUndo -and $holders.Count -eq 0) "P8 $($r.Name) masks a shown key (CanUndo false, the marker nowhere)" "wasShown=$wasShown text='$($box.Text)' undo=$($box.CanUndo) holders=$($holders -join '; ')"
    }
    # The refresh reads the content only on a running edge, never on another tick
    $null = Set-FastLlmUiFluentPage -Id 'Connect'
    Invoke-Pump 50
    # Bring the page in step with what the Home refresh will write (not running); that one change is an edge and may read.
    $f.Keys['Running'] = $false
    Update-FastLlmUiFluentConnect
    $calls = $script:connectInfoCalls
    Update-FastLlmUiFluentConnect
    Invoke-FastLlmUiFluentTick
    Update-FastLlmUiFluentConnect
    Check ($script:connectInfoCalls -eq $calls) 'P8 the connection info is not read again on a tick with no running edge' "calls=$($script:connectInfoCalls - $calls)"
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Check-NoExceptions 'P8'
}

function Invoke-P9-ConnectCopies {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $marker = [string]$script:markerKey
    $fx = New-ConnectFixture
    Open-ConnectPage $fx (New-ConnectRow)
    # A field Copy goes through the shadowed wrapper
    $script:fieldClips.Clear(); $script:clipboardPayloads.Clear()
    Invoke-ConnectClick $els.ConnectBaseUrlCopy
    Check ($script:fieldClips.Count -eq 1 -and [string]$script:fieldClips[0] -ceq 'http://127.0.0.1:8123/v1' -and $script:clipboardPayloads.Count -eq 0) 'P9 a field Copy sends its value through the plain clipboard wrapper' "clips=$($script:fieldClips -join ',')"
    $script:fieldClipThrow = $true
    Invoke-ConnectClick $els.ConnectModelNameCopy
    $script:fieldClipThrow = $false
    Check (([string]$script:statusLabel.Text) -ceq 'Could not copy: clipboard boom') 'P9 a failing field Copy sets the status text as the dialog does' "status='$($script:statusLabel.Text)'"
    # The key Copy: the marker plus the three exclusion formats
    $script:fieldClips.Clear(); $script:clipboardPayloads.Clear()
    Invoke-ConnectClick $els.ConnectKeyCopy
    $p = @($script:clipboardPayloads.ToArray())
    $names = @(); if ($p.Count -eq 1) { $names = @($p[0].formats.Keys | Sort-Object) }
    Check ($p.Count -eq 1 -and [string]$p[0].text -ceq $marker -and ($names -join ',') -ceq 'CanIncludeInClipboardHistory,CanUploadToCloudClipboard,ExcludeClipboardContentFromMonitorProcessing' -and $script:fieldClips.Count -eq 0) 'P9 the key Copy records the marker with the three exclusion formats, not through the plain wrapper' "payloads=$($p.Count) formats=$($names -join ',')"
    # A card Copy replaces the key token (with the key formats), and a card without a token copies plain
    $script:clipboardPayloads.Clear()
    $cards = @($f.Connect['Cards'])
    Invoke-ConnectClick $cards[0].Copy
    $p = @($script:clipboardPayloads.ToArray())
    $want = ([string]$fx.clients[0].snippet).Replace('{KEY}', $marker)
    Check ($p.Count -eq 1 -and [string]$p[0].text -ceq $want -and @($p[0].formats.Keys).Count -eq 3) 'P9 a card Copy replaces {KEY} with the key and carries the exclusion formats' "payloads=$($p.Count)"
    $script:clipboardPayloads.Clear()
    $readsBefore = $script:keyReadCalls
    Invoke-ConnectClick $cards[1].Copy
    $p = @($script:clipboardPayloads.ToArray())
    Check ($p.Count -eq 1 -and [string]$p[0].text -ceq 'plain snippet without a token' -and @($p[0].formats.Keys).Count -eq 0 -and $script:keyReadCalls -eq $readsBefore) 'P9 a card with no key token copies its text plain and reads no key' "payloads=$($p.Count) reads=$($script:keyReadCalls - $readsBefore)"
    # An unreadable key gives today's texts
    $script:keyReadNull = $true
    $script:clipboardPayloads.Clear()
    Invoke-ConnectClick $els.ConnectKeyCopy
    Check ($script:clipboardPayloads.Count -eq 0 -and ([string]$script:statusLabel.Text) -ceq 'The stored API key cannot be read.') 'P9 an unreadable key: the key Copy copies nothing and says so' "payloads=$($script:clipboardPayloads.Count) status='$($script:statusLabel.Text)'"
    Invoke-ConnectClick $cards[0].Copy
    $p = @($script:clipboardPayloads.ToArray())
    Check (([string]$script:statusLabel.Text) -ceq 'The stored API key cannot be read, so the card was copied without it.' -and $p.Count -eq 1 -and ([string]$p[0].text).Contains($marker) -eq $false) 'P9 an unreadable key: a card is copied without it and says so' "status='$($script:statusLabel.Text)' payloads=$($p.Count)"
    $script:keyReadNull = $false
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Check-NoExceptions 'P9'
}

function Invoke-P10-ConnectApiCheck {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $s = $script:FastLlmUiFluentStrings
    $btn = $els.ConnectCheckButton
    Check ([string]$btn.Content -ceq 'Check the API formats' -and [System.Windows.Controls.ToolTipService]::GetShowOnDisabled($btn)) 'P10 the check button says Check the API formats and shows its tooltip while disabled' "content='$($btn.Content)'"
    # Not running: disabled, with its reason
    $script:shellSnap = New-ShellSnap @{ RunReady = $true }
    Open-ConnectPage (New-ConnectFixture @{ state = 'not-running' }) (New-ConnectRow)
    $help = [System.Windows.Automation.AutomationProperties]::GetHelpText($btn)
    Check ((-not $btn.IsEnabled) -and [string]$btn.ToolTip -ceq [string]$s.WhyNotRunning -and $help -ceq [string]$s.WhyNotRunning) 'P10 not running: the button is disabled and says Start FastLLM first' "enabled=$($btn.IsEnabled) tip='$($btn.ToolTip)'"
    # Running, a side step in the way
    $script:shellSnap = New-ShellSnap @{ RunReady = $true; SideChildActive = $true }
    Open-ConnectPage (New-ConnectFixture) (New-ConnectRow)
    Check ((-not $btn.IsEnabled) -and [string]$btn.ToolTip -ceq [string]$s.WhySideStep) 'P10 during a side step: the button is disabled with the side-step reason' "enabled=$($btn.IsEnabled) tip='$($btn.ToolTip)'"
    # The rule is read on every tick: the side step ends, the button comes back and the reason goes
    $script:shellSnap = New-ShellSnap @{ RunReady = $true }
    Update-FastLlmUiFluentConnect
    Check ($btn.IsEnabled -and $null -eq $btn.ToolTip -and [System.Windows.Automation.AutomationProperties]::GetHelpText($btn) -ceq '') 'P10 running and idle: the button is enabled and shows no reason' "enabled=$($btn.IsEnabled) tip='$($btn.ToolTip)'"
    # Running with no run ready and no side step (a model load, an unattached background run): the reason is the tested function's code, never side-step
    $script:shellSnap = New-ShellSnap @{ RunReady = $false }
    Open-ConnectPage (New-ConnectFixture) (New-ConnectRow)
    $wantCode = [string](Get-FastLlmUiGreyedReason -Action 'apiCheck' -Snapshot $script:shellSnap -ConnectRunning $true)
    $wantText = [string](Get-FastLlmUiFluentToolsReasonText -Code $wantCode)
    Check ($wantCode -cne 'side-step' -and (-not $btn.IsEnabled) -and [string]$btn.ToolTip -ceq $wantText -and [string]$btn.ToolTip -cne [string]$s.WhySideStep) 'P10 running but no run ready and no side step: the shown reason is the function code, not the side-step reason' "code='$wantCode' tip='$($btn.ToolTip)'"
    $script:shellSnap = New-ShellSnap @{ RunReady = $true }
    Update-FastLlmUiFluentConnect
    # A click records ReadSideSelection, then the launch with its arguments
    $script:selection = @('--probe-selection')
    $selBefore = $script:sideSelectionCalls
    $script:sideStepCalls.Clear()
    Invoke-ConnectClick $btn
    $call = $null; if ($script:sideStepCalls.Count -eq 1) { $call = $script:sideStepCalls[0] }
    Check ($script:sideSelectionCalls -eq ($selBefore + 1) -and $null -ne $call -and [string]$call.Step -ceq 'api check' -and (@($call.Arguments) -join ' ') -ceq 'doctor -ApiCheck --probe-selection') 'P10 a click reads the side selection, then launches the api check side step with its arguments' "selection=$($script:sideSelectionCalls - $selBefore) calls=$($script:sideStepCalls.Count) args=$(if ($null -ne $call) { @($call.Arguments) -join ' ' })"
    # A throw reaches ShowFailure
    $script:sideStepThrows = $true
    $script:shellFailMsg = ''
    Invoke-ConnectClick $btn
    $script:sideStepThrows = $false
    Check ([string]$script:shellFailMsg -ceq 'side step boom') 'P10 a throw from the launch reaches ShowFailure' "message='$($script:shellFailMsg)'"
    $script:selection = @()
    $script:shellSnap = New-ShellSnap
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Check-NoExceptions 'P10'
}

# ---- Task 8: the keyboard, the control view and the first-time dialogs ----
function Get-PagesTabWalk($NavItem) {
    $win = $script:FastLlmUiFluent.Window
    $null = $win.Activate()
    $null = $NavItem.Focus()
    Invoke-Pump 200
    $cur = [System.Windows.Input.Keyboard]::FocusedElement
    $started = ($null -ne $cur) -and [object]::ReferenceEquals($cur, $NavItem)
    $stops = New-Object System.Collections.ArrayList
    if ($started) {
        for ($i = 0; $i -lt 60; $i++) {
            $null = $cur.MoveFocus((New-Object System.Windows.Input.TraversalRequest([System.Windows.Input.FocusNavigationDirection]::Next)))
            $cur = [System.Windows.Input.Keyboard]::FocusedElement
            if ($null -eq $cur) { break }
            if ([object]::ReferenceEquals($cur, $NavItem)) { break }
            $name = ''
            if ($cur -is [System.Windows.UIElement]) { $name = Get-ShellPeerName $cur }
            [void]$stops.Add([pscustomobject]@{ Element = $cur; Type = $cur.GetType().Name; Name = $name })
        }
    }
    return [pscustomobject]@{ Started = $started; Stops = $stops.ToArray() }
}

function Get-PagesStopsIn($Walk, $PageElement) {
    $in = New-Object System.Collections.ArrayList
    foreach ($stop in @($Walk.Stops)) {
        if ($stop.Element -is [System.Windows.DependencyObject] -and $PageElement.IsAncestorOf($stop.Element)) { [void]$in.Add($stop) }
    }
    return $in.ToArray()
}

# P11 walks the real window from a pane item with Tab: every stop has a readable name, and Connect's Copy buttons have distinct names.
function Invoke-P11-TabWalk {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $script:shellSnap = New-ShellSnap
    # Tools
    $null = Set-FastLlmUiFluentPage -Id 'Tools'
    Invoke-Pump 150
    $walk = Get-PagesTabWalk $els.NavTools
    $stops = @($walk.Stops)
    $unnamed = @($stops | Where-Object { -not (Test-ShellNameReadable ([string]$_.Name)) } | ForEach-Object { [string]$_.Type })
    $inPage = @(Get-PagesStopsIn $walk $f.Pages['Tools']['Element'])
    Write-Host ("INFO: P11 Tools tab stops: " + (($stops | ForEach-Object { [string]$_.Type + ':' + [string]$_.Name }) -join ' > '))
    Check ($walk.Started) 'P11 the focus can be placed on the Tools pane item (the window must be active for the walk)' "focused=$([System.Windows.Input.Keyboard]::FocusedElement)"
    Check ($inPage.Count -ge 3 -and $unnamed.Count -eq 0) 'P11 the Tools walk reaches the page and every tab stop has a readable name' "inPage=$($inPage.Count) stops=$($stops.Count) unnamed=[$($unnamed -join ',')]"
    # Connect: the field, key and card Copy buttons
    Open-ConnectPage (New-ConnectFixture) (New-ConnectRow)
    Invoke-Pump 150
    $walk = Get-PagesTabWalk $els.NavConnect
    $stops = @($walk.Stops)
    $unnamed = @($stops | Where-Object { -not (Test-ShellNameReadable ([string]$_.Name)) } | ForEach-Object { [string]$_.Type })
    $inPage = @(Get-PagesStopsIn $walk $f.Pages['Connect']['Element'])
    Write-Host ("INFO: P11 Connect tab stops: " + (($stops | ForEach-Object { [string]$_.Type + ':' + [string]$_.Name }) -join ' > '))
    Check ($walk.Started) 'P11 the focus can be placed on the Connect pane item' "focused=$([System.Windows.Input.Keyboard]::FocusedElement)"
    Check ($inPage.Count -ge 12 -and $unnamed.Count -eq 0) 'P11 the Connect walk reaches the page and every tab stop has a readable name' "inPage=$($inPage.Count) stops=$($stops.Count) unnamed=[$($unnamed -join ',')]"
    $copyNames = @($stops | Where-Object { $_.Element -is [System.Windows.Controls.Button] -and [string]$_.Element.Content -ceq 'Copy' } | ForEach-Object { [string]$_.Name })
    $distinct = @($copyNames | Sort-Object -Unique)
    Check ($copyNames.Count -eq 7 -and $distinct.Count -eq $copyNames.Count) 'P11 the seven Copy buttons (four fields, the key, two cards) have seven distinct names' "names=[$($copyNames -join ' | ')]"
    Check (@($copyNames | Where-Object { $_ -notmatch '^Copy ' }).Count -eq 0) 'P11 each Copy name says what it copies' "names=[$($copyNames -join ' | ')]"
    # Models: two models, one component and a leftover give the Remove buttons; the start options are expanded so their inputs are stops
    $fx = @(Reset-ModelsFixture)
    [void]$script:leftoverStore.Add([pscustomobject]@{ name = 'probe-leftover.part'; sizeBytes = [int64]1073741824; locked = $false })
    Open-ModelsPage
    $els.ModelsStartOptions.IsExpanded = $true
    Invoke-Pump 200
    $walk = Get-PagesTabWalk $els.NavModels
    $stops = @($walk.Stops)
    $unnamed = @($stops | Where-Object { -not (Test-ShellNameReadable ([string]$_.Name)) } | ForEach-Object { [string]$_.Type })
    $inPage = @(Get-PagesStopsIn $walk $f.Pages['Models']['Element'])
    Write-Host ("INFO: P11 Models tab stops: " + (($stops | ForEach-Object { [string]$_.Type + ':' + [string]$_.Name }) -join ' > '))
    Check ($walk.Started) 'P11 the focus can be placed on the Models pane item' "focused=$([System.Windows.Input.Keyboard]::FocusedElement)"
    Check ($inPage.Count -ge 8 -and $unnamed.Count -eq 0) 'P11 the Models walk reaches the page and every tab stop has a readable name' "inPage=$($inPage.Count) stops=$($stops.Count) unnamed=[$($unnamed -join ',')]"
    $removeNames = @($stops | Where-Object { $_.Element -is [System.Windows.Controls.Button] -and [string]$_.Element.Content -ceq 'Remove' } | ForEach-Object { [string]$_.Name })
    $removeDistinct = @($removeNames | Sort-Object -Unique)
    Check ($removeNames.Count -eq 3 -and $removeDistinct.Count -eq $removeNames.Count) 'P11 the three Remove buttons (two models, one component) are tab stops with three distinct names' "names=[$($removeNames -join ' | ')]"
    Check (@($removeNames | Where-Object { $_ -notmatch '^Remove .' }).Count -eq 0) 'P11 each Remove name says what it removes' "names=[$($removeNames -join ' | ')]"
    Check (@($stops | Where-Object { $_.Element -is [System.Windows.Controls.Primitives.RepeatButton] }).Count -eq 0) 'P11 the spin buttons are not tab stops' "types=[$((@($stops | ForEach-Object { [string]$_.Type }) -join ','))]"
    $namedStops = @($stops | Where-Object { $_.Element -is [System.Windows.DependencyObject] -and $f.Pages['Models']['Element'].IsAncestorOf($_.Element) } | ForEach-Object { [string]$_.Name })
    foreach ($want in 'Model', 'Install and model cache folder', 'Context (0 = catalog default)', 'Resizable BAR workaround', 'Remove leftover partial downloads') {
        Check ($namedStops -ccontains $want) "P11 the Models walk has a stop named $want" "stops=[$($namedStops -join ' | ')]"
    }
    $null = Reset-ModelsFixture
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Check-NoExceptions 'P11'
}

function Get-PagesNearestPeer($Element) {
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

function Test-PagesPuaText([string]$Text) {
    if ($Text.Length -eq 0) { return $false }
    foreach ($c in $Text.ToCharArray()) { if ([int]$c -lt 0xE000 -or [int]$c -gt 0xF8FF) { return $false } }
    return $true
}

# One pane item: its glyph is in the visual tree and visible, is not among the control-view peers, and the item still has a readable name.
function Test-PagesNavGlyphHidden([string]$CheckName, $Element) {
    $glyph = $null
    foreach ($n in @(Get-ShellVisuals $Element)) { if ($n -is [System.Windows.Controls.TextBlock] -and (Test-PagesPuaText ([string]$n.Text))) { $glyph = $n; break } }
    $peer = Get-PagesNearestPeer $Element
    if ($null -eq $peer) { Check $false $CheckName 'no automation peer for the element or any ancestor'; return }
    $name = [string]$peer.GetName()
    $bad = New-Object System.Collections.ArrayList
    foreach ($k in @(Get-ShellControlViewPeers $peer)) {
        if ($k -is [System.Windows.Automation.Peers.UIElementAutomationPeer]) {
            $o = $k.Owner
            if ($o -is [System.Windows.Controls.TextBlock] -and ((Test-PagesPuaText ([string]$o.Text)) -or ($null -ne $glyph -and [object]::ReferenceEquals($o, $glyph)))) { [void]$bad.Add($k.GetType().Name + ':' + [string]$o.Text) }
        }
    }
    $ok = ($null -ne $glyph) -and [bool]$glyph.IsVisible -and ($bad.Count -eq 0) -and (Test-ShellNameReadable $name)
    Check $ok $CheckName "glyphFound=$($null -ne $glyph) glyphVisible=$(if ($null -ne $glyph) { $glyph.IsVisible } else { 'n/a' }) glyphPeersInControlView=[$($bad -join ',')] name='$name'"
}

# The TextBlocks below a root whose text is only private-use glyphs and that are not the decorative type. A glyph that is a part of a named control's own template
# or content presenter (an Expander arrow, a glyph button's content) has a TemplatedParent: the control carries the name, so those are listed, not failed.
function Get-PagesPuaTextBlocks($Root) {
    $loose = New-Object System.Collections.ArrayList
    $templated = New-Object System.Collections.ArrayList
    foreach ($n in @(Get-ShellVisuals $Root)) {
        if ($n -isnot [System.Windows.Controls.TextBlock]) { continue }
        if ($n -is [Bitworks.FastLlm.DecorativeTextBlock]) { continue }
        if (-not (Test-PagesPuaText ([string]$n.Text))) { continue }
        if ($null -ne $n.TemplatedParent) { [void]$templated.Add($n) } else { [void]$loose.Add($n) }
    }
    return [pscustomobject]@{ Loose = $loose.ToArray(); Templated = $templated.ToArray() }
}

function Invoke-P12-ControlView {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Invoke-Pump 150
    $f.Window.UpdateLayout()
    # Every pane item, the disabled ones too (S9 covers Home only)
    foreach ($nav in @($f.NavItems)) { Test-PagesNavGlyphHidden ('P12 nav item ' + [string]$nav['Id'] + ': glyph not in the UIA control view; name present') $nav['Item'] }
    # No loose glyph TextBlock on any page or in the shell
    foreach ($pageId in 'Home', 'Tools', 'Connect', 'Models') {
        $null = Set-FastLlmUiFluentPage -Id $pageId
        Invoke-Pump 150
        $f.Window.UpdateLayout()
        $found = Get-PagesPuaTextBlocks $f.Window
        foreach ($t in @($found.Templated)) { Write-Host ("INFO: P12 $pageId templated glyph TextBlock in a " + $t.TemplatedParent.GetType().Name) }
        Check (@($found.Loose).Count -eq 0) "P12 no non-decorative TextBlock holds a private-use glyph with $pageId hosted" ("loose=" + ((@($found.Loose) | ForEach-Object { [string]$_.Name + ':' + [string]$_.Text.Length }) -join ','))
    }
    # The Models spin buttons draw icon glyphs: they are template or content-presenter parts (listed, not failed), never loose TextBlocks
    $null = Set-FastLlmUiFluentPage -Id 'Models'
    Invoke-Pump 150
    $f.Window.UpdateLayout()
    $modelsGlyphs = Get-PagesPuaTextBlocks $els.ModelsContextRow
    Check (@($modelsGlyphs.Loose).Count -eq 0) 'P12 the Models spin button glyphs are not loose TextBlocks (decorative or template parts)' ("loose=" + ((@($modelsGlyphs.Loose) | ForEach-Object { [string]$_.Name + ':' + [string]$_.Text.Length }) -join ',') + " templated=$(@($modelsGlyphs.Templated).Count)")
    # Negative control: a plain TextBlock with a glyph is found by the scan and IS in the control view
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Invoke-Pump 100
    $plain = New-Object System.Windows.Controls.TextBlock
    $plain.Text = [string][char]0xE80F
    [void]$els.QuickPanel.Children.Add($plain)
    try {
        Invoke-Pump 150
        $els.QuickPanel.UpdateLayout()
        $scan = Get-PagesPuaTextBlocks $f.Window
        $scanned = $false
        foreach ($t in @($scan.Loose)) { if ([object]::ReferenceEquals($t, $plain)) { $scanned = $true } }
        $holder = Get-PagesNearestPeer $els.QuickPanel
        $inView = $false
        if ($null -ne $holder) {
            foreach ($k in @(Get-ShellControlViewPeers $holder)) {
                if ($k -is [System.Windows.Automation.Peers.UIElementAutomationPeer] -and [object]::ReferenceEquals($k.Owner, $plain)) { $inView = $true }
            }
        }
        Check ($scanned -and $inView -and [bool]$plain.IsVisible) 'P12 negative control: a plain TextBlock glyph is found by the scan and IS in the UIA control view' "scanned=$scanned inView=$inView visible=$($plain.IsVisible)"
    }
    finally { $els.QuickPanel.Children.Remove($plain) }
    Check-NoExceptions 'P12'
}

# A dialog or box shown over the real window: its owner (GW_OWNER) must be the WPF window handle, the window is disabled while it is up, and the box ladder closes it.
function Invoke-PagesOwnerProbe([string]$Tag, [string]$Caption, [scriptblock]$Show) {
    $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($script:FastLlmUiFluent.Window).Handle
    $box = @{}
    $t = Start-BoxAnswer $Caption 2 $hwnd $box
    $err = ''
    try { $null = & $Show } catch { $err = $_.Exception.Message } finally { $t.Stop() }
    Invoke-Pump 100
    Write-Host ("INFO: P13 $Tag closed by rung: " + [string]$box.rung)
    Check ($err -eq '' -and $box.found -and -not $box.timedOut -and -not $box.hardStop) "P13 $Tag appeared and the box ladder closed it within 6 s" "error=$err found=$($box.found) timedOut=$($box.timedOut) hardStop=$($box.hardStop) lastRung=$($box.rung)"
    Check ($box.owner -eq $hwnd.ToInt64()) "P13 $Tag is owned by the WPF window handle" "GW_OWNER=$($box.owner) expected=$($hwnd.ToInt64())"
    Check ($box.during -eq $false) "P13 the WPF window is disabled while $Tag is up" "IsWindowEnabled during=$($box.during)"
}

function Invoke-P13-DialogOwners {
    if (-not $script:shellOk) { return }
    Check (@($script:p13Missing).Count -eq 0) 'P13 ShowUiSideResult and ShowDriverGuidance were found in fast-llm-ui.ps1' ("missing=" + (@($script:p13Missing) -join ','))
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    $win = $script:FastLlmUiFluent.Window
    $null = $win.Activate()
    Invoke-Pump 100
    # SaveFileDialog.ShowDialog($form): a CommonDialog (the support bundle's save dialog), never confirmed
    $script:p13Caption = 'FastLLM pages save ' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    Invoke-PagesOwnerProbe 'SaveFileDialog.ShowDialog($form)' $script:p13Caption {
        $dialog = New-Object System.Windows.Forms.SaveFileDialog
        try {
            $dialog.Title = $script:p13Caption
            $dialog.Filter = 'Zip file (*.zip)|*.zip'
            $dialog.DefaultExt = 'zip'
            $dialog.OverwritePrompt = $false
            [void]$dialog.ShowDialog($script:form)
        }
        finally { $dialog.Dispose() }
    }
    # The driver-guidance form: the real ShowDriverGuidance
    $script:trayAvailability.Clear()
    $script:p13Diagnostic = [pscustomobject]@{ windows = $true; driverGuidance = @([pscustomobject]@{ inputGpuName = 'Probe display device'; knownFocusModel = $false }) }
    Invoke-PagesOwnerProbe 'the driver-guidance form' 'AMD driver guidance - read-only' { ShowDriverGuidance $script:p13Diagnostic }
    Check (($script:trayAvailability.ToArray() -join ',') -ceq 'False,True') 'P13 the driver-guidance form turned the tray menu off while open and on again after' "calls=$($script:trayAvailability.ToArray() -join ',')"
    # ShowUiSideResult
    $script:p13Caption = 'FastLLM pages result ' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    Invoke-PagesOwnerProbe 'ShowUiSideResult' $script:p13Caption { ShowUiSideResult $script:p13Caption 'Probe result text' }
    Check ($win.IsVisible -and $script:native::IsWindowEnabled([System.Windows.Interop.WindowInteropHelper]::new($win).Handle)) 'P13 the window is open and enabled again after the three dialogs' "visible=$($win.IsVisible)"
    Check-NoExceptions 'P13'
}

# The binding table's order is part of its contract: Home, then the shell, then the pages (Tools, then Models). The REAL table is bound to scratch elements of the
# same types, in order (no throw), and then with the Tools and Models rows first: ToolsAttachButton (Also) binds the Attach adapter, so Home's own Attach row
# finds it bound and throws loudly.
function New-PagesScratchElements([object[]]$Rows) {
    $scratch = @{}
    foreach ($row in $Rows) {
        $type = $script:FastLlmUiFluent.Els[[string]$row.Element].GetType()
        $scratch[[string]$row.Element] = New-Object -TypeName $type.FullName
    }
    return $scratch
}
function Invoke-PagesBindRows([object[]]$Rows, [hashtable]$Scratch) {
    foreach ($row in $Rows) {
        $adapter = Get-Variable -Name ([string]$row.Name) -Scope Script -ValueOnly
        $also = ($row.ContainsKey('Also') -and [bool]$row['Also'])
        try { Connect-FastLlmUiFluentControl -Adapter $adapter -Element $Scratch[[string]$row.Element] -Mode ([string]$row.Mode) -Event ([string]$row.Event) -Flags @($row.Flags) -Also:$also }
        catch { return [pscustomobject]@{ Error = $_.Exception.Message; Element = [string]$row.Element } }
    }
    return [pscustomobject]@{ Error = ''; Element = '' }
}
function Invoke-P15-RealTableOrder {
    if (-not $script:shellOk) { return }
    $homeRows = @(Get-FastLlmUiFluentHomeBindings)
    $table = @(Get-FastLlmUiFluentBindingTable)
    $toolRows = @(Get-FastLlmUiFluentToolsBindings)
    $modelsRows = @(Get-FastLlmUiFluentModelsBindings)
    # The shell rows are what lies between the Home rows and the page rows in the table (its order is the contract this step pins)
    $shellRows = @($table | Select-Object -Skip $homeRows.Count -First ($table.Count - $homeRows.Count - $toolRows.Count - $modelsRows.Count))
    $reversed = @($toolRows) + @($modelsRows) + @($shellRows) + @($homeRows)
    $adapterNames = @(Get-FastLlmUiFluentControlTable | ForEach-Object { [string]$_[0] })
    $saved = @{}
    foreach ($n in $adapterNames) { $saved[$n] = Get-Variable -Name $n -Scope Script -ValueOnly }
    try {
        Check ($table.Count -eq ($homeRows.Count + $shellRows.Count + $toolRows.Count + $modelsRows.Count) -and $toolRows.Count -eq 8 -and $modelsRows.Count -eq 8 -and @($toolRows | Where-Object { $_.ContainsKey('Also') -and [bool]$_['Also'] }).Count -ge 1 -and @($modelsRows | Where-Object { $_.ContainsKey('Also') -and [bool]$_['Also'] }).Count -eq 1) 'P15 the real table is the Home rows, then the shell rows, then the Tools rows, then the Models rows, and each page group carries its Also row' "table=$($table.Count) home=$($homeRows.Count) shell=$($shellRows.Count) tools=$($toolRows.Count) models=$($modelsRows.Count)"
        # In order: every row binds
        $null = Initialize-FastLlmUiFluentBindings -InstallRoot $script:InstallRoot -Catalog $script:catalog -UiSettings $script:uiSettings
        $scratch = New-PagesScratchElements $table
        $ok = Invoke-PagesBindRows $table $scratch
        Check ($ok.Error -eq '') 'P15 control: the real table in its pinned order binds every row without a throw' "error=$($ok.Error) at=$($ok.Element)"
        # Reversed by group: the Tools rows first
        $null = Initialize-FastLlmUiFluentBindings -InstallRoot $script:InstallRoot -Catalog $script:catalog -UiSettings $script:uiSettings
        $scratch = New-PagesScratchElements $reversed
        $bad = Invoke-PagesBindRows $reversed $scratch
        Check ($bad.Error -match 'is bound twice' -and $bad.Element -ceq 'AttachButton') 'P15 the Tools and Models rows bound before Home throw loudly: Home Attach row finds its adapter already bound' "error=$($bad.Error) at=$($bad.Element)"
    }
    finally {
        foreach ($n in $adapterNames) { Set-Variable -Name $n -Value $saved[$n] -Scope Script }
    }
    Check-NoExceptions 'P15'
}

# ======================================================================================================================
# PR 3b Task 8: the Models page (P20 to P25). Every check name starts with its step id. The stubs are at the top of the file.
# ======================================================================================================================
$script:p21Events = @{ bar = 0; model = 0; path = 0; barElement = 0 }
$script:p21Attached = $false
$script:p20CopyEvents = 0
$script:p20CopyAttached = $false
function Add-P21Event([string]$Name) { $script:p21Events[$Name]++ }
function Add-P20CopyEvent { $script:p20CopyEvents++ }

# The first catalog models with distinct display names and no ampersand (a caption adapter would strip it), as { id, name }.
function Get-ModelsFixtureModels {
    $out = New-Object System.Collections.ArrayList
    $names = New-Object System.Collections.ArrayList
    foreach ($entry in @($script:catalog.models)) {
        $name = [string](Get-FastLlmModelDisplayName -Model $entry)
        if ($name -ne '' -and $name.IndexOf('&') -lt 0 -and -not $names.Contains($name) -and $out.Count -lt 3) {
            [void]$names.Add($name)
            [void]$out.Add([pscustomobject]@{ id = [string]$entry.id; name = $name })
        }
    }
    return $out.ToArray()
}
$script:modelSizeA = [int64]2684354560
$script:modelSizeB = [int64]3221225472
# Two installed models, one engine component, no leftovers; the lock free. Returns the two fixture models.
function Reset-ModelsFixture {
    $fx = @(Get-ModelsFixtureModels)
    $script:modelsStore.Clear(); $script:componentsStore.Clear(); $script:leftoverStore.Clear()
    $script:modelsLockThrows = $false
    if ($fx.Count -ge 2) {
        [void]$script:modelsStore.Add([pscustomobject]@{ id = [string]$fx[0].id; sizeBytes = $script:modelSizeA; inUse = $false; inUseReason = '' })
        [void]$script:modelsStore.Add([pscustomobject]@{ id = [string]$fx[1].id; sizeBytes = $script:modelSizeB; inUse = $false; inUseReason = '' })
    }
    [void]$script:componentsStore.Add([pscustomobject]@{ id = 'probe-engine'; label = 'probe-engine (engine, 1.0, 12 MB)' })
    Reset-ModelsCounters
    return $fx
}
function Reset-ModelsCounters {
    $script:modelsLog.Clear(); $script:modelsLockHeldSeen.Clear()
    $script:modelsRebuilds = 0; $script:componentsRebuilds = 0; $script:modelsRemoveCalls = 0
    $script:modelsLockDepth = 0; $script:modelsLockMax = 0
    $script:liveRaised.Clear()
}
function Open-ModelsPage {
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    $null = Set-FastLlmUiFluentPage -Id 'Models'
    Invoke-Pump 100
}
# The Remove buttons of a list panel, in row order. They are code-built, so FindName never sees them; the panel's own children are walked in place.
function Get-ModelsRowButtons($Panel) {
    $list = New-Object System.Collections.ArrayList
    foreach ($row in $Panel.Children) {
        if ($row -is [System.Windows.Controls.Grid]) {
            foreach ($cell in $row.Children) { if ($cell -is [System.Windows.Controls.Button]) { [void]$list.Add($cell) } }
        }
    }
    return $list.ToArray()
}
# The texts of a list panel: each row's label, or the one empty-list line.
function Get-ModelsRowTexts($Panel) {
    $list = New-Object System.Collections.ArrayList
    foreach ($row in $Panel.Children) {
        if ($row -is [System.Windows.Controls.Grid]) {
            foreach ($cell in $row.Children) { if ($cell -is [System.Windows.Controls.TextBlock]) { [void]$list.Add([string]$cell.Text) } }
        }
        elseif ($row -is [System.Windows.Controls.TextBlock]) { [void]$list.Add([string]$row.Text) }
    }
    return $list.ToArray()
}
function Get-ModelsLogText { return (@($script:modelsLog.ToArray()) -join ',') }
function Get-ModelsUiMessage([string]$Which) { return [string]$script:FastLlmUiFluent['Models'][$Which].Text }

# A WinForms timer that finds a message box by its caption, records its text (GetText), then answers it. Mode 'click' presses button $ButtonId (6 = Yes), the
# ladder of Start-BoxAnswer with IDNO as its fallback rung. Mode 'enter' posts VK_RETURN (PostKey, never SendMessage) and, only if the box is still open 1.5 s
# later, clicks IDNO so the suite cannot hang: St['fellBack'] then says Enter did not close it. After 6 s a still-open box gets WM_CLOSE (St['hardStop']).
function Start-ModelsBox([string]$Caption, [string]$Mode, [int]$ButtonId, [IntPtr]$Hwnd, [hashtable]$St) {
    $St['found'] = $false; $St['text'] = ''; $St['timedOut'] = $false; $St['hardStop'] = $false; $St['fellBack'] = $false; $St['rung'] = ''
    $st = $St
    $nat = $script:native
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $loc = @{ rung = -1; foundAt = [long]0; sentEnter = $false }
    $names = @('BM_CLICK id', 'WM_COMMAND id', 'WM_COMMAND IDNO', 'WM_CLOSE')
    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = 50
    $t.Add_Tick(({
        $h = $nat::FindWindowByTitle($Caption)
        $ms = $sw.ElapsedMilliseconds
        if ($h.ToInt64() -ne 0) {
            if (-not $st['found']) { $st['found'] = $true; $loc['foundAt'] = $ms; $st['text'] = [string]$nat::GetText($h) }
            $age = $ms - $loc['foundAt']
            if ($age -ge 6000) {
                if (-not $st['hardStop']) { $st['hardStop'] = $true; $null = $nat::PostClose($h) }
            }
            elseif ($Mode -ceq 'enter') {
                if (-not $loc['sentEnter']) { $loc['sentEnter'] = $true; $st['rung'] = 'PostKey VK_RETURN'; $null = $nat::PostKey($h, 0x0D) }
                elseif ($age -ge 1500 -and -not $st['fellBack']) { $st['fellBack'] = $true; $st['rung'] = 'Enter did not close the box; BM_CLICK id 7'; $null = $nat::PostButtonClick($h, 7) }
            }
            else {
                $rung = [int][Math]::Floor($age / 1000)
                if ($rung -gt $loc['rung']) {
                    $loc['rung'] = $rung
                    $idx = [Math]::Min($rung, 3)
                    $st['rung'] = $names[$idx]
                    if ($idx -eq 0) { $null = $nat::PostButtonClick($h, $ButtonId) }
                    elseif ($idx -eq 1) { $null = $nat::PostCommand($h, $ButtonId) }
                    elseif ($idx -eq 2) { $null = $nat::PostCommand($h, 7) }
                    else { $null = $nat::PostClose($h) }
                }
            }
        }
        elseif (-not $st['found'] -and $ms -gt 8000) { $st['timedOut'] = $true; $t.Stop() }
    }).GetNewClosure())
    $script:objs.Add($t)
    $t.Start()
    return $t
}
function Get-ModelsWindowHandle { return [System.Windows.Interop.WindowInteropHelper]::new($script:FastLlmUiFluent.Window).Handle }
# Clicks a code-built or named button the way a mouse click does (the routed Click event) while a box timer answers the confirmation, then pumps so the queued rebuild runs.
function Invoke-ModelsBoxClick($Button, [string]$Caption, [string]$Mode, [hashtable]$St) {
    $timer = Start-ModelsBox $Caption $Mode 6 (Get-ModelsWindowHandle) $St
    try { $Button.RaiseEvent((New-ShellClick $Button ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
    finally { $timer.Stop() }
    Invoke-Pump 300
}
function Get-ModelsBoxDetail([hashtable]$St) {
    return "found=$($St['found']) timedOut=$($St['timedOut']) hardStop=$($St['hardStop']) fellBack=$($St['fellBack']) rung='$($St['rung'])' text='$($St['text'])'"
}
function ConvertTo-ModelsPlainBoxText([string]$Text) { return $Text.Replace("`r`n", "`n").Trim() }

function Invoke-P20-HomeToModels {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $win = $f.Window
    Check (@($script:p22Missing).Count -eq 0) 'P20 the classic functions the Models steps run (the Remove flows, the two list fills, ReadSelection, GetBarValue) were found in fast-llm-ui.ps1' ("missing=" + (@($script:p22Missing) -join ','))
    Check ($script:barWiringText -ne '') 'P20 the BAR box classic wiring statement was found in fast-llm-ui.ps1' ''
    $fx = @(Reset-ModelsFixture)
    Check ($fx.Count -ge 2) 'P20 the catalog gives two fixture models with distinct display names' "count=$($fx.Count)"
    Check ([bool](Get-NavEntry 'NavModels')['Item'].IsEnabled -and (Get-FastLlmUiFluentPageIdByNav -NavId 'NavModels') -ceq 'Models') 'P20 Models is enabled in the pane and its page is registered' "enabled=$((Get-NavEntry 'NavModels')['Item'].IsEnabled) page='$(Get-FastLlmUiFluentPageIdByNav -NavId 'NavModels')'"
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    $null = $win.Activate()
    Invoke-Pump 100
    foreach ($k in @($script:dialogCalls.Keys)) { $script:dialogCalls[$k] = 0 }
    # Switch model on Home: Models is hosted and its pane item holds the focus
    $els.SwitchButton.RaiseEvent((New-ShellClick $els.SwitchButton ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Invoke-Pump 200
    $focused = [System.Windows.Input.FocusManager]::GetFocusedElement($win)
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Models' -and $els.NavModels.IsSelected -and ([object]::ReferenceEquals($focused, $els.NavModels) -or $els.NavModels.IsKeyboardFocused)) 'P20 Home Switch hosts Models and focuses the NavModels pane item' "current=$(Get-FastLlmUiFluentCurrentPage) navSelected=$($els.NavModels.IsSelected) focused=$(if ($null -ne $focused) { $focused.GetType().Name } else { 'nothing' })"
    # Change: Models is hosted and the model box has the focus
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    $els.ChangeButton.RaiseEvent((New-ShellClick $els.ChangeButton ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Invoke-Pump 200
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Models' -and $els.ModelsModelBox.IsKeyboardFocusWithin) 'P20 Home Change hosts Models and focuses the model box' "current=$(Get-FastLlmUiFluentCurrentPage) boxFocusWithin=$($els.ModelsModelBox.IsKeyboardFocusWithin)"
    # Change while the model box is disabled (a run is active): the focus is never lost, it rests on the Models pane item
    $origModelEnabled = [bool]$script:modelBox.Enabled
    $script:modelBox.Enabled = $false
    Invoke-FastLlmUiFluentTick
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    $els.ChangeButton.RaiseEvent((New-ShellClick $els.ChangeButton ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Invoke-Pump 200
    $focusedOff = [System.Windows.Input.FocusManager]::GetFocusedElement($win)
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Models' -and -not $els.ModelsModelBox.IsEnabled -and ([object]::ReferenceEquals($focusedOff, $els.NavModels) -or $els.NavModels.IsKeyboardFocused)) 'P20 Home Change with the model box disabled hosts Models and leaves the focus on the NavModels pane item' "current=$(Get-FastLlmUiFluentCurrentPage) boxEnabled=$($els.ModelsModelBox.IsEnabled) focused=$(if ($null -ne $focusedOff) { $focusedOff.GetType().Name } else { 'nothing' })"
    $script:modelBox.Enabled = $origModelEnabled
    Invoke-FastLlmUiFluentTick
    # The Models page and its rows never open today's dialogs
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Open-ModelsPage
    Check (($script:dialogCalls['switch'] + $script:dialogCalls['models'] + $script:dialogCalls['components']) -eq 0) 'P20 ShowUiSwitchPicker, ShowModelsWindow and ShowComponentsWindow stay at 0 after Switch, Change and the Models page opening' "switch=$($script:dialogCalls['switch']) models=$($script:dialogCalls['models']) components=$($script:dialogCalls['components'])"
    # Control: each counter can move (the real-shaped wiring of P0 is reached by a raised adapter Click), then it is put back
    $pairs = @(@('switchButton', 'switch'), @('modelsButton', 'models'), @('componentsButton', 'components'), @('chooseButton', 'recipe'))
    foreach ($pair in $pairs) {
        $before = [int]$script:dialogCalls[[string]$pair[1]]
        Invoke-FastLlmUiAdapterEvent -Adapter (Get-Variable -Name ([string]$pair[0]) -Scope Script -ValueOnly) -Event 'Click'
        Check ([int]$script:dialogCalls[[string]$pair[1]] -eq ($before + 1)) "P20 control: a raised $($pair[0]) Click reaches its wired dialog stub once (the counter can move)" "before=$before after=$($script:dialogCalls[[string]$pair[1]])"
        $script:dialogCalls[[string]$pair[1]] = 0
    }
    # The Activity copy button: one adapter LinkClicked per click, and its Visible follows failureCopyLink
    if (-not $script:p20CopyAttached) { [void]$script:failureCopyLink.PSObject.Methods['Add_LinkClicked'].Invoke([scriptblock]::Create('Add-P20CopyEvent')); $script:p20CopyAttached = $true }
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    $origVisible = [bool]$script:failureCopyLink.Visible
    $script:failureCopyLink.Visible = $true
    $copy = $els['ActivityCopyButton']
    Check ($null -ne $copy) 'P20 the Activity copy button is in the element map' ''
    if ($null -ne $copy) {
        $script:p20CopyEvents = 0
        $copy.RaiseEvent((New-ShellClick $copy ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Invoke-Pump 50
        Check ($script:p20CopyEvents -eq 1) 'P20 the Activity copy button raises exactly one LinkClicked per click' "events=$($script:p20CopyEvents)"
        $visibleOn = $copy.Visibility
        $script:failureCopyLink.Visible = $false
        $visibleOff = $copy.Visibility
        $script:failureCopyLink.Visible = $true
        $visibleBack = $copy.Visibility
        Check ($visibleOn -eq [System.Windows.Visibility]::Visible -and $visibleOff -eq [System.Windows.Visibility]::Collapsed -and $visibleBack -eq [System.Windows.Visibility]::Visible) 'P20 the Activity copy button Visible follows failureCopyLink both ways' "on=$visibleOn off=$visibleOff back=$visibleBack"
    }
    $script:failureCopyLink.Visible = $origVisible
    Check-NoExceptions 'P20'
}

# Two-way elements: one write, one adapter event, no echo. A key is routed the way WPF routes it: PreviewKeyDown first (the Number box reads Up, Down and Enter there),
# then KeyDown only if the preview was not marked Handled (the folder box reads Enter in KeyDown). One KeyEventArgs per raise. If the value did not follow, the same key is posted to the window.
function Send-ModelsKey($Element, $Key) {
    $src = [System.Windows.PresentationSource]::FromVisual($Element)
    if ($null -eq $src) { return $false }
    $preview = [System.Windows.Input.KeyEventArgs]::new([System.Windows.Input.Keyboard]::PrimaryDevice, $src, 0, $Key).psobject.BaseObject
    $preview.RoutedEvent = [System.Windows.Input.Keyboard]::PreviewKeyDownEvent
    $Element.RaiseEvent($preview)
    if (-not [bool]$preview.Handled) {
        $down = [System.Windows.Input.KeyEventArgs]::new([System.Windows.Input.Keyboard]::PrimaryDevice, $src, 0, $Key).psobject.BaseObject
        $down.RoutedEvent = [System.Windows.Input.Keyboard]::KeyDownEvent
        $Element.RaiseEvent($down)
    }
    return $true
}
function Send-ModelsKeyChecked($Element, $Key, [int]$Vk, [scriptblock]$Done) {
    $path = 'PreviewKeyDown then KeyDown routed events'
    $threw = ''
    try { $null = Send-ModelsKey $Element $Key } catch { $threw = $_.Exception.Message }
    Invoke-Pump 100
    if (-not [bool](& $Done)) {
        $path = 'PostMessage WM_KEYDOWN to the window (focus on the box)'
        $null = $script:FastLlmUiFluent.Window.Activate()
        $null = $Element.Focus()
        Invoke-Pump 100
        $null = $script:native::PostKey((Get-ModelsWindowHandle), $Vk)
        Invoke-Pump 250
    }
    Write-Host ("INFO: P21 key $Key on $($Element.Name): path used = $path $threw")
    return $path
}
function Invoke-P21-TwoWay {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $fx = @(Reset-ModelsFixture)
    Open-ModelsPage
    $els.ModelsStartOptions.IsExpanded = $true
    Invoke-Pump 150
    if (-not $script:p21Attached) {
        $script:p21Attached = $true
        [void]$script:barBox.PSObject.Methods['Add_SelectedIndexChanged'].Invoke([scriptblock]::Create('Add-P21Event ''bar'''))
        [void]$script:modelBox.PSObject.Methods['Add_SelectedIndexChanged'].Invoke([scriptblock]::Create('Add-P21Event ''model'''))
        [void]$script:pathBox.PSObject.Methods['Add_TextChanged'].Invoke([scriptblock]::Create('Add-P21Event ''path'''))
        $els.ModelsBarBox.Add_SelectionChanged({ $script:p21Events['barElement']++ })
    }
    $origBar = [int]$script:barBox.SelectedIndex
    $origPath = [string]$script:pathBox.Text
    # BAR: one pick is one settings write, one adapter event and one element SelectionChanged (no echo back from the adapter)
    $writes0 = $script:settingsWrites.Count; $bar0 = $script:p21Events['bar']; $el0 = $script:p21Events['barElement']
    $els.ModelsBarBox.SelectedIndex = 2
    Invoke-Pump 50
    $lastWrite = ''; if ($script:settingsWrites.Count -gt 0) { $lastWrite = [string]$script:settingsWrites[$script:settingsWrites.Count - 1] }
    Check (($script:settingsWrites.Count - $writes0) -eq 1 -and $lastWrite -ceq 'off' -and ($script:p21Events['bar'] - $bar0) -eq 1 -and ($script:p21Events['barElement'] - $el0) -eq 1 -and [int]$script:barBox.SelectedIndex -eq 2) 'P21 one BAR pick is one Write-FastLlmUiSettings (off), one adapter event and one element SelectionChanged' "writes=$($script:settingsWrites.Count - $writes0) last='$lastWrite' adapterEvents=$($script:p21Events['bar'] - $bar0) elementEvents=$($script:p21Events['barElement'] - $el0) adapterIndex=$($script:barBox.SelectedIndex)"
    # The orchestration sets the adapter: the element follows and nothing echoes back (one more write and event, from the adapter's own change)
    $writes1 = $script:settingsWrites.Count; $bar1 = $script:p21Events['bar']; $el1 = $script:p21Events['barElement']
    $script:barBox.SelectedIndex = 0
    Invoke-Pump 50
    Check ([int]$els.ModelsBarBox.SelectedIndex -eq 0 -and ($script:settingsWrites.Count - $writes1) -eq 1 -and ($script:p21Events['bar'] - $bar1) -eq 1 -and ($script:p21Events['barElement'] - $el1) -eq 1) 'P21 an adapter BAR set moves the element and echoes nothing back (one write, one adapter event, one element event)' "elementIndex=$($els.ModelsBarBox.SelectedIndex) writes=$($script:settingsWrites.Count - $writes1) adapterEvents=$($script:p21Events['bar'] - $bar1) elementEvents=$($script:p21Events['barElement'] - $el1)"
    $script:barBox.SelectedIndex = $origBar
    Invoke-Pump 50
    # The model pick: the adapter follows and the real ReadSelection puts -ModelId in the arguments
    $pickerIds = @($script:modelBox.Items)
    $model0 = $script:p21Events['model']
    $els.ModelsModelBox.SelectedIndex = 1
    Invoke-Pump 50
    Check ([int]$script:modelBox.SelectedIndex -eq 1 -and ($script:p21Events['model'] - $model0) -eq 1) 'P21 a model pick reaches the adapter once' "adapterIndex=$($script:modelBox.SelectedIndex) events=$($script:p21Events['model'] - $model0)"
    # The context box: typed 40000 and committed with Enter becomes 32768; abc reverts; Up from 32000 steps to 32768
    $ctx = $els.ModelsContextBox
    $ctx.Text = '40000'
    $p1 = Send-ModelsKeyChecked $ctx ([System.Windows.Input.Key]::Return) 0x0D ({ [decimal]$script:contextBox.Value -eq 32768 })
    Check ([decimal]$script:contextBox.Value -eq 32768 -and [string]$ctx.Text -ceq '32768') 'P21 a context typed as 40000 and committed with Enter is 32768 in the adapter and the box' "path=$p1 adapter=$($script:contextBox.Value) text='$($ctx.Text)'"
    $ctx.Text = 'abc'
    $p2 = Send-ModelsKeyChecked $ctx ([System.Windows.Input.Key]::Return) 0x0D ({ [string]$script:FastLlmUiFluent.Els.ModelsContextBox.Text -ceq '32768' })
    Check ([decimal]$script:contextBox.Value -eq 32768 -and [string]$ctx.Text -ceq '32768') 'P21 a context typed as abc reverts to the current value on Enter' "path=$p2 adapter=$($script:contextBox.Value) text='$($ctx.Text)'"
    $script:contextBox.Value = 32000
    Invoke-Pump 50
    Check ([string]$ctx.Text -ceq '32000') 'P21 an adapter Value set shows in the box (no echo write)' "text='$($ctx.Text)' adapter=$($script:contextBox.Value)"
    $p3 = Send-ModelsKeyChecked $ctx ([System.Windows.Input.Key]::Up) 0x26 ({ [decimal]$script:contextBox.Value -eq 32768 })
    Check ([decimal]$script:contextBox.Value -eq 32768 -and [string]$ctx.Text -ceq '32768') 'P21 Up from 32000 steps by the increment to the maximum 32768' "path=$p3 adapter=$($script:contextBox.Value) text='$($ctx.Text)'"
    # The spin buttons step the same way (not tab stops, named)
    $script:contextBox.Value = 1000
    Invoke-Pump 50
    $els.ModelsContextUp.RaiseEvent((New-ShellClick $els.ModelsContextUp ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Invoke-Pump 50
    Check ([decimal]$script:contextBox.Value -eq 2024 -and [string]$ctx.Text -ceq '2024') 'P21 the Increase spin button steps 1000 to 2024' "adapter=$($script:contextBox.Value) text='$($ctx.Text)'"
    $els.ModelsContextDown.RaiseEvent((New-ShellClick $els.ModelsContextDown ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Invoke-Pump 50
    Check ([decimal]$script:contextBox.Value -eq 1000 -and [string]$ctx.Text -ceq '1000') 'P21 the Decrease spin button steps 2024 back to 1000' "adapter=$($script:contextBox.Value) text='$($ctx.Text)'"
    Check ((-not $els.ModelsContextUp.IsTabStop) -and (-not $els.ModelsContextDown.IsTabStop)) 'P21 the spin buttons are not tab stops' "up=$($els.ModelsContextUp.IsTabStop) down=$($els.ModelsContextDown.IsTabStop)"
    # ReadSelection (the real function) reads the three adapters the way a launch does
    $origSelection = $script:selection
    ReadSelection
    $selectionText = (@($script:selection) -join ' ')
    $wantSelection = '-InstallRoot ' + [IO.Path]::GetFullPath($origPath) + ' -ContextSize 1000 -ModelId ' + [string]$pickerIds[1]
    Check ($selectionText -ceq $wantSelection) 'P21 ReadSelection reads the folder, the context and -ModelId from the adapters the elements wrote' "selection='$selectionText' want='$wantSelection'"
    $script:selection = $origSelection
    $script:modelBox.SelectedIndex = 0
    Invoke-Pump 50
    # The folder box: one keystroke is one adapter TextChanged; an adapter set shows in the box and echoes nothing
    $path0 = $script:p21Events['path']
    $els.ModelsFolderBox.Text = $origPath + '-edit'
    Invoke-Pump 50
    Check ([string]$script:pathBox.Text -ceq ($origPath + '-edit') -and ($script:p21Events['path'] - $path0) -eq 1) 'P21 a folder keystroke is one adapter TextChanged' "adapter='$($script:pathBox.Text)' events=$($script:p21Events['path'] - $path0)"
    $path1 = $script:p21Events['path']
    $script:pathBox.Text = $origPath
    Invoke-Pump 50
    Check ([string]$els.ModelsFolderBox.Text -ceq $origPath -and ($script:p21Events['path'] - $path1) -eq 1) 'P21 an adapter folder set shows in the box with exactly one adapter event (no echo)' "element='$($els.ModelsFolderBox.Text)' events=$($script:p21Events['path'] - $path1)"
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Check-NoExceptions 'P21'
}

# The Remove flows run the REAL functions of fast-llm-ui.ps1 (two refresh lines included) against the shadows; the log is one ordered list.
function Invoke-P22-RemoveFlows {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $win = $f.Window
    $hwnd = Get-ModelsWindowHandle
    $fx = @(Reset-ModelsFixture)
    if ($fx.Count -lt 2) { Check $false 'P22 the catalog gives two fixture models' "count=$($fx.Count)"; return }
    $a = $fx[0]; $b = $fx[1]
    $clickEvent = [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent
    Open-ModelsPage
    $buttons = @(Get-ModelsRowButtons $els.ModelsModelRows)
    $buttonDetail = "buttons=$($buttons.Count) tags=$((@($buttons | ForEach-Object { [string]$_.Tag }) -join ','))"
    Check ($buttons.Count -eq 2 -and [string]$buttons[0].Tag -ceq [string]$a.id -and [string]$buttons[1].Tag -ceq [string]$b.id) 'P22 the list has one Remove button per installed model, in store order' $buttonDetail
    if ($buttons.Count -ne 2) { return }
    Check ([System.Windows.Automation.AutomationProperties]::GetName($buttons[0]) -ceq ('Remove ' + [string]$a.name) -and [System.Windows.Automation.AutomationProperties]::GetName($buttons[1]) -ceq ('Remove ' + [string]$b.name) -and [string]$buttons[0].Content -ceq 'Remove') 'P22 each Remove says Remove and is named Remove plus its model' "name0='$([System.Windows.Automation.AutomationProperties]::GetName($buttons[0]))' name1='$([System.Windows.Automation.AutomationProperties]::GetName($buttons[1]))'"
    $btnA = $buttons[0]; $btnB = $buttons[1]
    Reset-ModelsCounters
    # Remove A, then B quickly. A is clicked synchronously (its confirmation answered Yes). B's click is queued at Input priority BEFORE the loop pumps, a model of a
    # click that is already waiting: the queued rebuild (Normal) must run first, then B's confirmation, lock, remove, release and rebuild.
    $boxA = @{}
    $timerA = Start-ModelsBox 'Remove model' 'click' 6 $hwnd $boxA
    try { $btnA.RaiseEvent((New-ShellClick $btnA $clickEvent)) } finally { $timerA.Stop() }
    $afterA = Get-ModelsLogText
    $boxB = @{}
    $timerB = Start-ModelsBox 'Remove model' 'click' 6 $hwnd $boxB
    $clickB = New-ShellClick $btnB $clickEvent
    $blockB = { $btnB.RaiseEvent($clickB) }.GetNewClosure()
    $actionB = [Action]$blockB
    $null = $win.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Input, $actionB)
    try {
        Invoke-Pump 8000 ({ $script:modelsRebuilds -ge 2 })
        Invoke-Pump 300
    }
    finally { $timerB.Stop() }
    $want = @("confirm:$($a.name)", 'lock', "remove:$($a.id)", 'release', 'rebuild', "confirm:$($b.name)", 'lock', "remove:$($b.id)", 'release', 'rebuild') -join ','
    $got = Get-ModelsLogText
    Check ($afterA -ceq "confirm:$($a.name),lock,remove:$($a.id),release") 'P22 after A is clicked synchronously the log is confirm, lock, remove, release and the rebuild is still queued' "log='$afterA'"
    Check ($got -ceq $want) 'P22 remove A then B: confirm A, lock, remove A, release, rebuild, confirm B, lock, remove B, release, rebuild' "log='$got' want='$want'"
    Check ($script:modelsRebuilds -eq 2 -and $script:modelsLockMax -eq 1 -and $script:modelsLockDepth -eq 0) 'P22 exactly 2 rebuilds, the lock never nested (maximum depth 1) and none is left held' "rebuilds=$($script:modelsRebuilds) maxDepth=$($script:modelsLockMax) depth=$($script:modelsLockDepth)"
    Check ((@($script:modelsLockHeldSeen.ToArray() | Where-Object { $_ }).Count -eq 2) -and $script:modelsLockHeldSeen.Count -eq 2) 'P22 both removes were handed the lock with -OperationLockHeld' "seen=$($script:modelsLockHeldSeen -join ',')"
    $texts = @(Get-ModelsRowTexts $els.ModelsModelRows)
    Check ($texts.Count -eq 1 -and [string]$texts[0] -ceq 'No models are downloaded.') 'P22 the list shows no model and No models are downloaded.' "texts=[$($texts -join ' | ')]"
    Check ((Get-ModelsUiMessage 'Message') -ceq "Removed $($b.name)." -and [string]$els.ModelsDownloadedMessage.Text -ceq "Removed $($b.name).") 'P22 the message is Removed and the name of model B' "adapter='$(Get-ModelsUiMessage 'Message')' element='$($els.ModelsDownloadedMessage.Text)'"
    Check ((Get-LiveCount $els.ModelsDownloadedMessage) -eq 2) 'P22 each message change was announced once (A removed, B removed)' "announcements=$(Get-LiveCount $els.ModelsDownloadedMessage)"
    $wantTextA = ConvertTo-ModelsPlainBoxText ([string](& $script:realConfirmText -DisplayName ([string]$a.name) -SizeBytes $script:modelSizeA))
    $wantTextB = ConvertTo-ModelsPlainBoxText ([string](& $script:realConfirmText -DisplayName ([string]$b.name) -SizeBytes $script:modelSizeB))
    Check ((ConvertTo-ModelsPlainBoxText ([string]$boxA['text'])) -ceq $wantTextA -and (ConvertTo-ModelsPlainBoxText ([string]$boxB['text'])) -ceq $wantTextB) 'P22 each box text is Get-FastLlmModelRemovalConfirmationText for its model' "A=$(Get-ModelsBoxDetail $boxA) B=$(Get-ModelsBoxDetail $boxB) wantA='$wantTextA' wantB='$wantTextB'"
    Check ($boxA['found'] -and -not $boxA['hardStop'] -and $boxB['found'] -and -not $boxB['hardStop']) 'P22 both confirmation boxes appeared and were answered within 6 s' "A=$(Get-ModelsBoxDetail $boxA) B=$(Get-ModelsBoxDetail $boxB)"
    # A stale click on A's old button: not-installed text, one rebuild, no confirmation, no lock, no remove
    Reset-ModelsCounters
    $btnA.RaiseEvent((New-ShellClick $btnA $clickEvent))
    Invoke-Pump 300
    Check ((Get-ModelsUiMessage 'Message') -ceq [string](& $script:realRefusalText -Reason 'not-installed') -and (Get-ModelsLogText) -ceq 'rebuild' -and $script:modelsRemoveCalls -eq 0) 'P22 a stale click on a removed model shows the not-installed text with one rebuild, no lock and no remove' "message='$(Get-ModelsUiMessage 'Message')' log='$(Get-ModelsLogText)' removes=$($script:modelsRemoveCalls)"
    Check ((Get-LiveCount $els.ModelsDownloadedMessage) -eq 1) 'P22 the not-installed message was announced once' "announcements=$(Get-LiveCount $els.ModelsDownloadedMessage)"

    # Lock held by another process: the operation-in-progress text, no rebuild, no remove (models and leftovers); the busy sentence and one rebuild (component)
    $refusal = [string](& $script:realRefusalText -Reason 'operation-in-progress')
    $busyComponent = 'FastLLM is busy with another install or start. Try again when it has finished; nothing was removed.'
    $leftover = [pscustomobject]@{ name = 'probe-leftover.part'; sizeBytes = [int64]1073741824; locked = $false }
    $leftoverText = "1 leftover file(s), $(Format-FastLlmModelStoreGigabytes -Bytes ([int64]1073741824)) GB"
    $wantLeftoverBox = "Deletes the leftover partial downloads ($leftoverText) from this PC. Downloaded models are not touched. Continue?"
    $wantComponentBox = "Remove the component 'probe-engine'? Its files are deleted from this PC. You can install it again later."
    $null = Reset-ModelsFixture
    [void]$script:leftoverStore.Add($leftover)
    Open-ModelsPage
    $script:modelsLockThrows = $true
    Reset-ModelsCounters
    $modelButton = @(Get-ModelsRowButtons $els.ModelsModelRows)[0]
    $st = @{}
    Invoke-ModelsBoxClick $modelButton 'Remove model' 'click' $st
    Check ((Get-ModelsLogText) -ceq "confirm:$($a.name),lock-refused" -and $script:modelsRebuilds -eq 0 -and $script:modelsRemoveCalls -eq 0 -and (Get-ModelsUiMessage 'Message') -ceq $refusal) 'P22 model remove with the lock held elsewhere: operation-in-progress text, 0 rebuilds, no remove' "log='$(Get-ModelsLogText)' rebuilds=$($script:modelsRebuilds) removes=$($script:modelsRemoveCalls) message='$(Get-ModelsUiMessage 'Message')'"
    Reset-ModelsCounters
    $st = @{}
    Invoke-ModelsBoxClick $els.ModelsLeftoverButton 'Remove leftover partial downloads' 'click' $st
    Check ((Get-ModelsLogText) -ceq 'lock-refused' -and $script:modelsRebuilds -eq 0 -and $script:modelsRemoveCalls -eq 0 -and (Get-ModelsUiMessage 'Message') -ceq $refusal) 'P22 leftovers remove with the lock held elsewhere: operation-in-progress text, 0 rebuilds, no remove' "log='$(Get-ModelsLogText)' rebuilds=$($script:modelsRebuilds) message='$(Get-ModelsUiMessage 'Message')' box=$(Get-ModelsBoxDetail $st)"
    Check ((ConvertTo-ModelsPlainBoxText ([string]$st['text'])) -ceq (ConvertTo-ModelsPlainBoxText $wantLeftoverBox)) 'P22 the leftovers box text is the classic sentence with the leftover size text' "box=$(Get-ModelsBoxDetail $st) want='$wantLeftoverBox'"
    Reset-ModelsCounters
    $componentButton = @(Get-ModelsRowButtons $els.ModelsComponentRows)[0]
    $st = @{}
    Invoke-ModelsBoxClick $componentButton 'Remove component' 'click' $st
    Check ((Get-ModelsLogText) -ceq 'lock-refused,rebuild-components' -and $script:componentsRebuilds -eq 1 -and $script:modelsRemoveCalls -eq 0 -and (Get-ModelsUiMessage 'ComponentsMessage') -ceq $busyComponent) 'P22 component remove with the lock held elsewhere: the busy sentence and exactly 1 rebuild, no remove' "log='$(Get-ModelsLogText)' componentRebuilds=$($script:componentsRebuilds) removes=$($script:modelsRemoveCalls) message='$(Get-ModelsUiMessage 'ComponentsMessage')'"
    Check ((ConvertTo-ModelsPlainBoxText ([string]$st['text'])) -ceq (ConvertTo-ModelsPlainBoxText $wantComponentBox)) 'P22 the component box text is the classic sentence' "box=$(Get-ModelsBoxDetail $st) want='$wantComponentBox'"
    $script:modelsLockThrows = $false

    # Enter on each confirmation is No (Button2): nothing is locked, removed or rebuilt
    $null = Reset-ModelsFixture
    [void]$script:leftoverStore.Add($leftover)
    Open-ModelsPage
    Reset-ModelsCounters
    $st = @{}
    Invoke-ModelsBoxClick (@(Get-ModelsRowButtons $els.ModelsModelRows)[0]) 'Remove model' 'enter' $st
    Check ((Get-ModelsLogText) -ceq "confirm:$($a.name)" -and $script:modelsRebuilds -eq 0 -and $script:modelsRemoveCalls -eq 0 -and $st['found'] -and -not $st['fellBack'] -and -not $st['hardStop']) 'P22 Enter on the model confirmation is No: no lock, no remove, 0 rebuilds' "log='$(Get-ModelsLogText)' $(Get-ModelsBoxDetail $st)"
    Reset-ModelsCounters
    $st = @{}
    Invoke-ModelsBoxClick $els.ModelsLeftoverButton 'Remove leftover partial downloads' 'enter' $st
    Check ((Get-ModelsLogText) -ceq '' -and $script:modelsRebuilds -eq 0 -and $st['found'] -and -not $st['fellBack'] -and -not $st['hardStop']) 'P22 Enter on the leftovers confirmation is No: no lock, no remove, 0 rebuilds' "log='$(Get-ModelsLogText)' $(Get-ModelsBoxDetail $st)"
    Reset-ModelsCounters
    $st = @{}
    Invoke-ModelsBoxClick (@(Get-ModelsRowButtons $els.ModelsComponentRows)[0]) 'Remove component' 'enter' $st
    Check ((Get-ModelsLogText) -ceq '' -and $script:componentsRebuilds -eq 0 -and $st['found'] -and -not $st['fellBack'] -and -not $st['hardStop']) 'P22 Enter on the component confirmation is No: no lock, no remove, 0 rebuilds' "log='$(Get-ModelsLogText)' $(Get-ModelsBoxDetail $st)"

    # Yes on leftovers and on the component: the removes run under the lock and rebuild once
    Reset-ModelsCounters
    $st = @{}
    Invoke-ModelsBoxClick $els.ModelsLeftoverButton 'Remove leftover partial downloads' 'click' $st
    Check ((Get-ModelsLogText) -ceq 'lock,remove-leftovers:probe-leftover.part,release,rebuild' -and $script:modelsRebuilds -eq 1 -and (Get-ModelsUiMessage 'Message') -ceq 'Removed 1 leftover file(s).' -and ((ConvertTo-ModelsPlainBoxText ([string]$st['text'])) -ceq (ConvertTo-ModelsPlainBoxText $wantLeftoverBox))) 'P22 leftovers Yes: lock, remove, release, one rebuild and the Removed text' "log='$(Get-ModelsLogText)' rebuilds=$($script:modelsRebuilds) message='$(Get-ModelsUiMessage 'Message')' $(Get-ModelsBoxDetail $st)"
    Reset-ModelsCounters
    $st = @{}
    Invoke-ModelsBoxClick (@(Get-ModelsRowButtons $els.ModelsComponentRows)[0]) 'Remove component' 'click' $st
    Check ((Get-ModelsLogText) -ceq 'lock,remove-component:probe-engine,release,rebuild-components' -and $script:componentsRebuilds -eq 1 -and (Get-ModelsUiMessage 'ComponentsMessage') -ceq "Removed 'probe-engine'.") 'P22 component Yes: lock, remove, release, one rebuild and the Removed text' "log='$(Get-ModelsLogText)' rebuilds=$($script:componentsRebuilds) message='$(Get-ModelsUiMessage 'ComponentsMessage')'"
    $componentTexts = @(Get-ModelsRowTexts $els.ModelsComponentRows)
    Check ($componentTexts.Count -eq 1 -and [string]$componentTexts[0] -ceq 'No engine components are installed.') 'P22 the component list then shows No engine components are installed.' "texts=[$($componentTexts -join ' | ')]"
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Check-NoExceptions 'P22'
}

# The switch picker is computed on page open and on the Switch button's availability edge, never by an ordinary tick.
function Invoke-P23-Picker {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $null = Reset-ModelsFixture
    $script:pickerItems = @(
        [pscustomobject]@{ id = 'probe-switch-a'; text = 'Probe A  -  fits'; canSwitch = $true },
        [pscustomobject]@{ id = 'probe-switch-b'; text = 'Probe B  -  does not fit'; canSwitch = $false })
    $script:pickerMessage = ''
    $script:pickRequests.Clear()
    $origSwitch = [bool]$script:switchButton.Enabled
    $origStatus = [string]$script:statusLabel.Text
    $script:shellSnap = New-ShellSnap
    $script:switchButton.Enabled = $true
    $script:pickerCalls = 0
    Open-ModelsPage
    Check ($script:pickerCalls -eq 1 -and $els.ModelsSwitchList.Items.Count -eq 2) 'P23 entering Models with switching on computes the picker once and lists its items' "calls=$($script:pickerCalls) items=$($els.ModelsSwitchList.Items.Count)"
    for ($i = 0; $i -lt 40; $i++) { Invoke-FastLlmUiFluentTick }
    Check ($script:pickerCalls -eq 1) 'P23 40 ordinary ticks do not compute the picker again' "calls=$($script:pickerCalls)"
    Open-ModelsPage
    Check ($script:pickerCalls -eq 2) 'P23 leaving and entering the page computes it once more' "calls=$($script:pickerCalls)"
    $script:switchButton.Enabled = $false
    Invoke-FastLlmUiFluentTick
    Check ($script:pickerCalls -eq 2 -and $els.ModelsSwitchList.Items.Count -eq 0 -and -not $els.ModelsSwitchNow.IsEnabled) 'P23 switching turned off empties the list without a store read' "calls=$($script:pickerCalls) items=$($els.ModelsSwitchList.Items.Count) switchEnabled=$($els.ModelsSwitchNow.IsEnabled)"
    $script:switchButton.Enabled = $true
    Invoke-FastLlmUiFluentTick
    Check ($script:pickerCalls -eq 3 -and $els.ModelsSwitchList.Items.Count -eq 2) 'P23 switching turned off and on again while shown computes the picker once (the edge)' "calls=$($script:pickerCalls) items=$($els.ModelsSwitchList.Items.Count)"
    for ($i = 0; $i -lt 10; $i++) { Invoke-FastLlmUiFluentTick }
    Check ($script:pickerCalls -eq 3) 'P23 ticks after the edge compute nothing' "calls=$($script:pickerCalls)"
    # Selection drives the Switch button; a row that cannot be switched to keeps it off
    Check (-not $els.ModelsSwitchNow.IsEnabled) 'P23 Switch is off while nothing is selected' "enabled=$($els.ModelsSwitchNow.IsEnabled)"
    $els.ModelsSwitchList.SelectedIndex = 1
    Invoke-Pump 50
    Check (-not $els.ModelsSwitchNow.IsEnabled) 'P23 Switch stays off on a row that cannot be switched to' "enabled=$($els.ModelsSwitchNow.IsEnabled)"
    $els.ModelsSwitchList.SelectedIndex = 0
    Invoke-Pump 50
    Check ($els.ModelsSwitchNow.IsEnabled) 'P23 Switch is on for a row that can be switched to' "enabled=$($els.ModelsSwitchNow.IsEnabled)"
    $els.ModelsSwitchNow.RaiseEvent((New-ShellClick $els.ModelsSwitchNow ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Invoke-Pump 100
    $wantText = 'Switch to probe-switch-a requested (probe).'
    Check ($script:pickRequests.Count -eq 1 -and [string]$script:pickRequests[0] -ceq 'probe-switch-a' -and (Get-ModelsUiMessage 'SwitchMessage') -ceq $wantText -and [string]$script:statusLabel.Text -ceq $wantText -and [string]$els.ModelsSwitchMessage.Text -ceq $wantText) 'P23 Switch runs Invoke-FastLlmUiSwitchPick once with the picked id and sets the picker message and the status text' "requests=$($script:pickRequests -join ',') message='$(Get-ModelsUiMessage 'SwitchMessage')' status='$($script:statusLabel.Text)' element='$($els.ModelsSwitchMessage.Text)'"
    Check (-not $els.ModelsSwitchNow.IsEnabled) 'P23 Switch is disabled after a successful request until the next computation' "enabled=$($els.ModelsSwitchNow.IsEnabled)"
    $els.ModelsSwitchList.SelectedIndex = -1
    Invoke-Pump 30
    $els.ModelsSwitchList.SelectedIndex = 0
    Invoke-Pump 30
    for ($i = 0; $i -lt 5; $i++) { Invoke-FastLlmUiFluentTick }
    Check (-not $els.ModelsSwitchNow.IsEnabled -and $script:pickerCalls -eq 3) 'P23 reselecting the row and ticking does not re-enable Switch or recompute' "enabled=$($els.ModelsSwitchNow.IsEnabled) calls=$($script:pickerCalls)"
    Open-ModelsPage
    $els.ModelsSwitchList.SelectedIndex = 0
    Invoke-Pump 50
    Check ($script:pickerCalls -eq 4 -and $els.ModelsSwitchNow.IsEnabled) 'P23 the next computation (page opened again) makes Switch available again' "calls=$($script:pickerCalls) enabled=$($els.ModelsSwitchNow.IsEnabled)"
    # The switch-off edge after a successful request (the real request disables the Switch button) keeps the request's result: no empty message, no empty announcement
    $els.ModelsSwitchList.SelectedIndex = 0
    Invoke-Pump 50
    $els.ModelsSwitchNow.RaiseEvent((New-ShellClick $els.ModelsSwitchNow ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Invoke-Pump 100
    $live0 = Get-LiveCount $els.ModelsSwitchMessage
    $script:switchButton.Enabled = $false
    for ($i = 0; $i -lt 3; $i++) { Invoke-FastLlmUiFluentTick }
    Check ((Get-ModelsUiMessage 'SwitchMessage') -ceq $wantText -and [string]$els.ModelsSwitchMessage.Text -ceq $wantText -and (Get-LiveCount $els.ModelsSwitchMessage) -eq $live0 -and $els.ModelsSwitchList.Items.Count -eq 0) 'P23 the switch-off edge after a request keeps its message and announces nothing new' "message='$(Get-ModelsUiMessage 'SwitchMessage')' element='$($els.ModelsSwitchMessage.Text)' announcements=$(Get-LiveCount $els.ModelsSwitchMessage) before=$live0 items=$($els.ModelsSwitchList.Items.Count)"
    $script:switchButton.Enabled = $origSwitch
    $script:statusLabel.Text = $origStatus
    $script:pickerItems = @()
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Check-NoExceptions 'P23'
}

function Invoke-P24-Reasons {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $s = $script:FastLlmUiFluentStrings
    $null = Reset-ModelsFixture
    Open-ModelsPage
    $choose = $script:chooseButton
    $btn = $els.ModelsChooseButton
    $origChoose = [bool]$choose.Enabled
    Check ([System.Windows.Controls.ToolTipService]::GetShowOnDisabled($btn) -and [System.Windows.Controls.ToolTipService]::GetShowOnDisabled($els.ModelsModelBox)) 'P24 Choose and the inputs show their tooltip while disabled' ''
    $cases = @(
        @{ Name = 'before a preview'; Snap = @{}; Want = [string]$s.WhyNoPreview },
        @{ Name = 'busy'; Snap = @{ Busy = $true }; Want = [string]$s.WhyBusy },
        @{ Name = 'occupied by a background run'; Snap = @{ Background = 'starting-own' }; Want = [string]$s.WhyBackgroundRun })
    foreach ($case in $cases) {
        $script:shellSnap = New-ShellSnap $case.Snap
        $choose.Enabled = $false
        Invoke-FastLlmUiFluentTick
        $help = [System.Windows.Automation.AutomationProperties]::GetHelpText($btn)
        Check ([string]$btn.ToolTip -ceq [string]$case.Want -and $help -ceq [string]$case.Want) "P24 Choose another setup $($case.Name) says why ($($case.Want))" "tip='$($btn.ToolTip)' help='$help' code='$(Get-FastLlmUiGreyedReason -Action 'chooseSetup' -Snapshot $script:shellSnap)'"
    }
    $script:shellSnap = New-ShellSnap @{ PreviewReady = $true }
    $choose.Enabled = $true
    Invoke-FastLlmUiFluentTick
    Check ($null -eq $btn.ToolTip -and [System.Windows.Automation.AutomationProperties]::GetHelpText($btn) -ceq '' -and $btn.IsEnabled) 'P24 Choose another setup is enabled with no reason once a preview is ready' "enabled=$($btn.IsEnabled) tip='$($btn.ToolTip)'"
    $script:dialogCalls['recipe'] = 0
    $btn.RaiseEvent((New-ShellClick $btn ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Invoke-Pump 100
    Check ($script:dialogCalls['recipe'] -eq 1) 'P24 a Choose click runs StartRecipeList once' "calls=$($script:dialogCalls['recipe'])"
    $script:dialogCalls['recipe'] = 0
    # The four inputs while a child runs
    $script:shellSnap = New-ShellSnap @{ Busy = $true; ChildActive = $true; Step = 'model download' }
    $inputs = @(@('modelBox', 'ModelsModelBox'), @('pathBox', 'ModelsFolderBox'), @('contextBox', 'ModelsContextBox'), @('barBox', 'ModelsBarBox'))
    $origEnabled = @{}
    foreach ($pair in $inputs) { $adapter = Get-Variable -Name ([string]$pair[0]) -Scope Script -ValueOnly; $origEnabled[[string]$pair[0]] = [bool]$adapter.Enabled; $adapter.Enabled = $false }
    Invoke-FastLlmUiFluentTick
    foreach ($pair in $inputs) {
        $el = $els[[string]$pair[1]]
        $help = [System.Windows.Automation.AutomationProperties]::GetHelpText($el)
        Check ((-not $el.IsEnabled) -and [string]$el.ToolTip -ceq [string]$s.WhyBusy -and $help -ceq [string]$s.WhyBusy) "P24 $($pair[1]) is disabled and says WhyBusy while a child runs" "enabled=$($el.IsEnabled) tip='$($el.ToolTip)' help='$help'"
    }
    $script:shellSnap = New-ShellSnap
    foreach ($pair in $inputs) { (Get-Variable -Name ([string]$pair[0]) -Scope Script -ValueOnly).Enabled = $origEnabled[[string]$pair[0]] }
    Invoke-FastLlmUiFluentTick
    foreach ($pair in $inputs) {
        $el = $els[[string]$pair[1]]
        Check ($el.IsEnabled -and $null -eq $el.ToolTip -and [System.Windows.Automation.AutomationProperties]::GetHelpText($el) -ceq '') "P24 $($pair[1]) is enabled again and shows no reason" "enabled=$($el.IsEnabled) tip='$($el.ToolTip)'"
    }
    $choose.Enabled = $origChoose
    $script:shellSnap = New-ShellSnap
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Check-NoExceptions 'P24'
}

function Invoke-P25-DisabledRows {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $s = $script:FastLlmUiFluentStrings
    $fx = @(Reset-ModelsFixture)
    if ($fx.Count -lt 2) { Check $false 'P25 the catalog gives two fixture models' "count=$($fx.Count)"; return }
    # No leftovers: the button is disabled and says why. The second model is in use: its Remove is disabled with the reason as help text.
    $script:modelsStore[1].inUse = $true
    $script:modelsStore[1].inUseReason = 'serving'
    Open-ModelsPage
    $left = $els.ModelsLeftoverButton
    $leftHelp = [System.Windows.Automation.AutomationProperties]::GetHelpText($left)
    Check ((-not $left.IsEnabled) -and [string]$left.ToolTip -ceq [string]$s.WhyNoLeftovers -and $leftHelp -ceq [string]$s.WhyNoLeftovers -and [System.Windows.Controls.ToolTipService]::GetShowOnDisabled($left)) 'P25 the leftover button with no leftovers is disabled and says WhyNoLeftovers' "enabled=$($left.IsEnabled) tip='$($left.ToolTip)' help='$leftHelp'"
    $buttons = @(Get-ModelsRowButtons $els.ModelsModelRows)
    Check ($buttons.Count -eq 2) 'P25 two model rows' "buttons=$($buttons.Count)"
    if ($buttons.Count -eq 2) {
        $help0 = [System.Windows.Automation.AutomationProperties]::GetHelpText($buttons[0])
        $help1 = [System.Windows.Automation.AutomationProperties]::GetHelpText($buttons[1])
        Check ($buttons[0].IsEnabled -and $null -eq $buttons[0].ToolTip -and $help0 -ceq '') 'P25 the model that is not in use has an enabled Remove with no reason' "enabled=$($buttons[0].IsEnabled) tip='$($buttons[0].ToolTip)' help='$help0'"
        Check ((-not $buttons[1].IsEnabled) -and [string]$buttons[1].ToolTip -ceq 'serving' -and $help1 -ceq 'serving' -and [System.Windows.Controls.ToolTipService]::GetShowOnDisabled($buttons[1])) 'P25 the in-use model has a disabled Remove with its reason as tooltip and help text' "enabled=$($buttons[1].IsEnabled) tip='$($buttons[1].ToolTip)' help='$help1'"
        $texts = @(Get-ModelsRowTexts $els.ModelsModelRows)
        Check ($texts.Count -eq 2 -and [string]$texts[1] -ceq ("$($fx[1].name)  -  $(Format-FastLlmModelStoreGigabytes -Bytes $script:modelSizeB) GB  (in use: serving)")) 'P25 the in-use row text is the classic row text with (in use: reason)' "texts=[$($texts -join ' | ')]"
    }
    # With a leftover the button turns on and the reason goes
    [void]$script:leftoverStore.Add([pscustomobject]@{ name = 'probe-leftover.part'; sizeBytes = [int64]1073741824; locked = $false })
    Open-ModelsPage
    Check ($left.IsEnabled -and $null -eq $left.ToolTip -and [System.Windows.Automation.AutomationProperties]::GetHelpText($left) -ceq '') 'P25 with a leftover the button is enabled and shows no reason' "enabled=$($left.IsEnabled) tip='$($left.ToolTip)'"
    $null = Reset-ModelsFixture
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Check-NoExceptions 'P25'
}

# Faults are injected last: each Initialize run replaces the shell state, so nothing after this may use the real shell.
function Invoke-P99-StartupFaults {
    if (-not $script:shellOk) { return }
    try { $script:FastLlmUiFluent.Timer.Stop() } catch { $null = $_ }
    Check ($script:connectDialogCalls -eq 0) 'P99 ShowConnectDialog was never called in fluent mode' "calls=$($script:connectDialogCalls)"
    # Text C is the same for a markup fault as for a theme fault, and the real stop function passes its reason on and exits 3
    $textXaml = Get-FastLlmUiUnsupportedText -Reason 'xaml-parse' -Folder 'C:\example'
    $textTheme = Get-FastLlmUiUnsupportedText -Reason 'theme-init' -Folder 'C:\example'
    Check (($textXaml -ceq $textTheme) -and $textXaml -match 'a fault in FastLLM') 'P99 a xaml-parse fault shows text C, the same as a theme-init fault' "xaml-parse='$textXaml'"
    Check ($script:realStopText -match 'Show-FastLlmUiUnsupported\s+-Reason\s+\$Reason' -and $script:realStopText -match 'exit 3') 'P99 the real Stop-FastLlmUiFluentStartup passes its reason to Show-FastLlmUiUnsupported and exits 3' $script:realStopText
    # An injected Tools markup fault: the Tools page does not parse, so the startup stops with xaml-parse (the suite's throwing double stands in for the exit)
    # The loader is shadowed for the one name (the XAML table is never written from a test): it throws the way a markup parse fault does.
    $script:realXamlLoader = ${function:New-FastLlmUiXamlElement}
    function New-FastLlmUiXamlElement { param([string]$Name) if ($Name -ceq 'FastLlm.Tools') { throw 'Exception calling "Parse" with "1" argument(s): injected Tools markup fault' }; return (& $script:realXamlLoader -Name $Name) }
    Initialize-ShellEnv
    $err = ''
    try { Initialize-FastLlmUiFluentShell } catch { $err = $_.Exception.Message }
    finally { Set-Item -Path Function:\New-FastLlmUiXamlElement -Value $script:realXamlLoader }
    Check ($err -ceq 'startup stopped: xaml-parse') 'P99 an injected Tools markup fault stops the startup with xaml-parse (text C, exit 3)' "error='$err'"
    Check ((${function:New-FastLlmUiXamlElement}).ToString() -ceq $script:realXamlLoader.ToString()) 'P99 the real XAML loader is restored' ''
    # The same for the Models page: its markup does not parse, so the startup stops with xaml-parse (text C, exit 3)
    function New-FastLlmUiXamlElement { param([string]$Name) if ($Name -ceq 'FastLlm.Models') { throw 'Exception calling "Parse" with "1" argument(s): injected Models markup fault' }; return (& $script:realXamlLoader -Name $Name) }
    Initialize-ShellEnv
    $errModels = ''
    try { Initialize-FastLlmUiFluentShell } catch { $errModels = $_.Exception.Message }
    finally { Set-Item -Path Function:\New-FastLlmUiXamlElement -Value $script:realXamlLoader }
    Check ($errModels -ceq 'startup stopped: xaml-parse') 'P99 an injected Models markup fault stops the startup with xaml-parse (text C, exit 3)' "error='$errModels'"
    Check ((${function:New-FastLlmUiXamlElement}).ToString() -ceq $script:realXamlLoader.ToString()) 'P99 the real XAML loader is restored after the Models fault' ''
    Check (($script:dialogCalls['switch'] + $script:dialogCalls['models'] + $script:dialogCalls['components']) -eq 0) 'P99 ShowUiSwitchPicker, ShowModelsWindow and ShowComponentsWindow were never called by a Fluent page action' "switch=$($script:dialogCalls['switch']) models=$($script:dialogCalls['models']) components=$($script:dialogCalls['components'])"
    Check-NoExceptions 'P99'
}

$script:steps = @(
    # P0 enters the shell's message loop; every step after it runs inside that loop's frame
    'Invoke-P0-ShellStart',
    'Invoke-P1-PageHostAndNav', 'Invoke-P16-ActivityCopyHeader', 'Invoke-P2-ConnectAnApp', 'Invoke-P17-HomeSwitchAndChange', 'Invoke-P6-PageStatusLine', 'Invoke-P14-TrayRestore',
    'Invoke-P3-ToolsBindings', 'Invoke-P4-AttachFanOut', 'Invoke-P5-GreyedReasons',
    'Invoke-P7-ConnectContent', 'Invoke-P8-ConnectKey', 'Invoke-P9-ConnectCopies', 'Invoke-P10-ConnectApiCheck',
    'Invoke-P20-HomeToModels', 'Invoke-P21-TwoWay', 'Invoke-P22-RemoveFlows', 'Invoke-P23-Picker', 'Invoke-P24-Reasons', 'Invoke-P25-DisabledRows',
    'Invoke-P11-TabWalk', 'Invoke-P12-ControlView', 'Invoke-P13-DialogOwners', 'Invoke-P15-RealTableOrder',
    # P-SLOT step names of the later tasks are added here, before P99
    'Invoke-P99-StartupFaults'
)

$tick = New-Object System.Windows.Threading.DispatcherTimer
$tick.Interval = [TimeSpan]::FromMilliseconds(50)
$script:tick = $tick
$deadline = New-Object System.Windows.Threading.DispatcherTimer
# 420 s: the Models steps (P20-P23) and the larger pages added since the 240 s figure took most of it on the slowest Windows CI runner
$deadline.Interval = [TimeSpan]::FromSeconds(420)
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
    Write-Host "FAIL: the 420 s suite deadline was hit during step $where"
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
