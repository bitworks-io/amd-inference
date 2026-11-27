#requires -Version 5.1
# Startup smoke of the real window script (PR 5a, plan D8(a)): fast-llm-ui.ps1 runs top to bottom in a fresh STA process with a temporary install root, the window
# is found by its title, closed with WM_CLOSE, and the run must end with exit code 0, an empty error stream and no fault reason code (theme-init, xaml-parse)
# in the run log or the output. No other suite runs the real top level of the script: the page suites take functions out of it by name and shell S19r replays its
# first statements, so a break in the top-level order (a StrictMode throw, a statement before the seam) would show first on a user's PC.
# The run is safe on CI: no RELEASE.json in a source tree (so no installed release, no update request and no integrity run) and updateCheck off in the temporary settings,
# the lab-app lifetime lease returns nothing for a source checkout, no benchmark (FASTLLM_TESTS_NO_BENCH=1),
# nothing is started by the window on its own (a model is started only by a click), and the temporary install root is the only folder it writes to.
# The script refuses to start as an administrator and CI is elevated, so the child runs a COPY of the script with exactly that one refusal statement cut out (found by
# syntax tree, exactly one required) and $PSScriptRoot replaced by the source folder; nothing else differs from the real file.
# The cross-platform helpers below (the copy builder and the verdict) run before the Windows-only part, with a control and mutants each.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$root = Split-Path $PSScriptRoot -Parent
$script:smokePass = 0
$script:smokeFail = 0
function Check([bool]$Condition, [string]$Name, [string]$Detail = '') {
    if ($Condition) { $script:smokePass++; Write-Host "PASS: $Name" }
    else { $script:smokeFail++; Write-Host "FAIL: $Name -- $Detail" }
}

# The text the child runs: the real script with the one administrator refusal removed and $PSScriptRoot made literal. Throws (a check fails) when the script
# has no such statement, more than one, or a $PSScriptRoot inside a string (a literal there would change the text).
function New-SmokeScriptText([string]$ScriptText, [string]$AppRoot) {
    $errs = $null
    $tree = [System.Management.Automation.Language.Parser]::ParseInput($ScriptText, [ref]$null, [ref]$errs)
    if ($errs.Count -gt 0) { throw "the script does not parse ($($errs.Count) error(s))" }
    $guards = @($tree.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and ([string]$_.Clauses[0].Item1.Extent.Text).Contains('IsInRole') })
    if ($guards.Count -ne 1) { throw "expected exactly one top-level administrator refusal, found $($guards.Count)" }
    $roots = @($tree.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and ([string]$n.VariablePath.UserPath) -ceq 'PSScriptRoot' }, $true))
    $literal = "'" + $AppRoot.Replace("'", "''") + "'"
    $edits = New-Object System.Collections.ArrayList
    [void]$edits.Add(@{ Start = [int]$guards[0].Extent.StartOffset; End = [int]$guards[0].Extent.EndOffset; Text = '' })
    foreach ($r in $roots) {
        if ($r.Parent -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) { throw "a PSScriptRoot inside a string at line $($r.Extent.StartLineNumber)" }
        [void]$edits.Add(@{ Start = [int]$r.Extent.StartOffset; End = [int]$r.Extent.EndOffset; Text = $literal })
    }
    $text = $ScriptText
    foreach ($e in @($edits | Sort-Object { [int]$_.Start } -Descending)) { $text = $text.Substring(0, [int]$e.Start) + [string]$e.Text + $text.Substring([int]$e.End) }
    $errs2 = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errs2)
    if ($errs2.Count -gt 0) { throw "the copy does not parse ($($errs2.Count) error(s)): $($errs2[0].Message)" }
    return $text
}

# The problems of one run (empty when the run is clean). Run: WindowFound, TimedOut, ExitCode, Stderr, Stdout, LogText.
function Get-SmokeProblems($Run) {
    $problems = New-Object System.Collections.ArrayList
    if (-not [bool]$Run.WindowFound) { [void]$problems.Add('the window titled ''Bitworks FastLLM (Preview)'' never appeared') }
    if ([bool]$Run.TimedOut) { [void]$problems.Add('the process did not end after WM_CLOSE and was stopped') }
    elseif ([string]$Run.ExitCode -cne '0') { [void]$problems.Add("exit code $($Run.ExitCode), expected 0") }
    if (([string]$Run.Stderr).Trim() -ne '') { [void]$problems.Add('the error stream is not empty') }
    foreach ($code in 'theme-init', 'xaml-parse') {
        if (([string]$Run.LogText).Contains($code)) { [void]$problems.Add("the run log names the fault reason code $code") }
        if (([string]$Run.Stdout).Contains($code)) { [void]$problems.Add("the output names the fault reason code $code") }
    }
    return $problems.ToArray()
}

$realText = [System.IO.File]::ReadAllText((Join-Path $root 'fast-llm-ui.ps1'))
$copyText = ''
try { $copyText = New-SmokeScriptText $realText $root } catch { Check $false 'the smoke copy of fast-llm-ui.ps1 is built' $_.Exception.Message }
if ($copyText -ne '') {
    Check ($copyText -cnotmatch 'IsInRole' -and $realText -cmatch 'IsInRole') 'the smoke copy has the administrator refusal cut out (the real script has it)' ''
    Check ($copyText -cnotmatch '\$PSScriptRoot\b') 'the smoke copy has no $PSScriptRoot left (every use is the literal source folder)' ''
    # what remains is the real script: every other non-blank line of the real file is in the copy unchanged
    $copySet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($l in @($copyText -split "`r?`n")) { [void]$copySet.Add($l) }
    $lost = @($realText -split "`r?`n" | Where-Object { $_.Trim() -ne '' -and $_ -cnotmatch 'IsInRole' -and $_ -cnotmatch 'PSScriptRoot' -and -not $copySet.Contains($_) })
    Check ($lost.Count -eq 0) 'the smoke copy keeps every other line of the real script unchanged' "lines lost or changed: $($lost.Count), first: $(if ($lost.Count -gt 0) { $lost[0] })"
}
# mutants of the builder: a script without the refusal, with two refusals, or with a PSScriptRoot inside a string is refused; the real text is the control
$noGuard = ($realText -split "`r?`n" | Where-Object { $_ -cnotmatch 'IsInRole' }) -join "`n"
$twoGuards = $realText + "`nif (`$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'again' }`n"
$inString = $realText + "`n`$smokeProbe = `"`$PSScriptRoot/x`"`n"
foreach ($case in @(@('a script without the refusal', $noGuard), @('a script with two refusals', $twoGuards), @('a script with a PSScriptRoot inside a string', $inString))) {
    $threw = $false
    try { [void](New-SmokeScriptText ([string]$case[1]) $root) } catch { $threw = $true }
    Check $threw "mutation check: the copy builder refuses $($case[0])"
}
Check (@(Get-SmokeProblems @{ WindowFound = $true; TimedOut = $false; ExitCode = 0; Stderr = ''; Stdout = 'started'; LogText = '{"event":"start"}' }).Count -eq 0) 'mutation control: a clean run has no problems'
foreach ($case in @(
        @('no window', @{ WindowFound = $false; TimedOut = $false; ExitCode = 0; Stderr = ''; Stdout = ''; LogText = '' }),
        @('a process that does not end', @{ WindowFound = $true; TimedOut = $true; ExitCode = 0; Stderr = ''; Stdout = ''; LogText = '' }),
        @('a non-zero exit code', @{ WindowFound = $true; TimedOut = $false; ExitCode = 3; Stderr = ''; Stdout = ''; LogText = '' }),
        @('an error on the error stream', @{ WindowFound = $true; TimedOut = $false; ExitCode = 0; Stderr = 'Cannot index into a null array.'; Stdout = ''; LogText = '' }),
        @('theme-init in the run log', @{ WindowFound = $true; TimedOut = $false; ExitCode = 0; Stderr = ''; Stdout = ''; LogText = '{"event":"window-unsupported","reason":"theme-init"}' }),
        @('xaml-parse in the output', @{ WindowFound = $true; TimedOut = $false; ExitCode = 0; Stderr = ''; Stdout = 'startup stopped: xaml-parse'; LogText = '' }))) {
    Check (@(Get-SmokeProblems $case[1]).Count -ge 1) "mutation check: the verdict flags $($case[0])"
}

Write-Host ("INFO: startup smoke helper pins: $($script:smokePass) passed, $($script:smokeFail) failed")
if ($script:smokeFail -gt 0) { Write-Host "$($script:smokeFail) checks FAILED"; exit 1 }
$onWindows = ($PSVersionTable.PSVersion.Major -le 5) -or [bool](Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue)
if (-not $onWindows) { Write-Host 'SKIP: ui-fluent-startup-smoke-tests (Windows only)'; exit 0 }

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class FastLlmStartupSmokeNative {
    public delegate bool EnumProc(IntPtr hwnd, IntPtr lparam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string className, string title);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr lparam);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int max);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr wparam, IntPtr lparam);
    public static uint PidOf(IntPtr hwnd) { uint pid; GetWindowThreadProcessId(hwnd, out pid); return pid; }
    // The window titled exactly this that belongs to this process: FindWindow first, then every top-level window (another process may own a window of the same title).
    public static IntPtr FindByTitleAndPid(string title, uint pid) {
        IntPtr h = FindWindow(null, title);
        if (h != IntPtr.Zero && PidOf(h) == pid) return h;
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate (IntPtr w, IntPtr l) {
            StringBuilder sb = new StringBuilder(256);
            GetWindowText(w, sb, 256);
            if (sb.ToString() == title && PidOf(w) == pid) { found = w; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
'@

$windowTitle = 'Bitworks FastLLM (Preview)'
$work = Join-Path ([IO.Path]::GetTempPath()) ('fastllm-startup-smoke-' + [guid]::NewGuid().ToString('N'))
$install = Join-Path $work 'install'
[void](New-Item -ItemType Directory -Path $install -Force)
$script:smokeProc = $null
$run = @{ WindowFound = $false; TimedOut = $false; ExitCode = 'none'; Stderr = ''; Stdout = ''; LogText = '' }
$notes = New-Object System.Collections.ArrayList
try {
    $copyPath = Join-Path $work 'fast-llm-ui-smoke.ps1'
    [System.IO.File]::WriteAllText($copyPath, $copyText, (New-Object System.Text.UTF8Encoding($false)))
    # no update request: the check is off in the settings of the temporary root (a source tree has no release record either)
    [System.IO.File]::WriteAllText((Join-Path $install 'settings.json'), '{"updateCheck":"off"}', (New-Object System.Text.UTF8Encoding($false)))
    $exe = (Get-Process -Id $PID).Path
    $childArgs = @('-STA', '-NoLogo', '-NoProfile', '-File', $copyPath)
    # 5b-delete-begin
    $childArgs += @('-Window', 'fluent')
    # 5b-delete-end
    $childArgs += @('-InstallRoot', $install)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = (@($childArgs | ForEach-Object { if (([string]$_) -match '\s') { '"' + [string]$_ + '"' } else { [string]$_ } }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['FASTLLM_TESTS_NO_BENCH'] = '1'
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $script:smokeProc = $p
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $null = $p.Start()
    $ownPid = [uint32]$p.Id
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    [void]$notes.Add("child pid $ownPid, $exe $($psi.Arguments)")
    # the window: up to 120 s (WPF load on the slowest runner), found by its title among this process's windows
    $hwnd = [IntPtr]::Zero
    while ($watch.Elapsed.TotalSeconds -lt 120 -and -not $p.HasExited) {
        $hwnd = [FastLlmStartupSmokeNative]::FindByTitleAndPid($windowTitle, $ownPid)
        if ($hwnd -ne [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 250
    }
    $run.WindowFound = ($hwnd -ne [IntPtr]::Zero)
    [void]$notes.Add("window found=$($run.WindowFound) after $([int]$watch.Elapsed.TotalSeconds) s, process exited early=$($p.HasExited)")
    if ($run.WindowFound) {
        # let the 250 ms refresh run a few times (a fault in the first refresh or in the startup checks shows by then), then close the window the way the system does
        Start-Sleep -Seconds 4
        [void][FastLlmStartupSmokeNative]::PostMessage($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
    }
    if (-not $p.HasExited) { $null = $p.WaitForExit(60000) }
    if (-not $p.HasExited) {
        $run.TimedOut = $true
        # only this child (by its own process id) is stopped
        try { $p.Kill() } catch { $null = $_ }
        $null = $p.WaitForExit(10000)
    }
    else { $run.ExitCode = [string]$p.ExitCode }
    try { $run.Stdout = [string]$outTask.Result; $run.Stderr = [string]$errTask.Result } catch { $null = $_ }
    # the run log under the temporary install root (every file of it; the fault reason codes are one closed set of words)
    $logs = New-Object System.Text.StringBuilder
    foreach ($f in @(Get-ChildItem -LiteralPath $install -Recurse -File -ErrorAction SilentlyContinue)) {
        [void]$notes.Add("install file: $($f.FullName.Substring($install.Length)) ($($f.Length) bytes)")
        try { [void]$logs.AppendLine([System.IO.File]::ReadAllText($f.FullName)) } catch { $null = $_ }
    }
    $run.LogText = $logs.ToString()
    $problems = @(Get-SmokeProblems $run)
    $tail = [string]$run.Stdout; if ($tail.Length -gt 1500) { $tail = $tail.Substring($tail.Length - 1500) }
    $errText = [string]$run.Stderr; if ($errText.Length -gt 1500) { $errText = $errText.Substring(0, 1500) }
    $detail = (@($problems) -join '; ') + " | exit=$($run.ExitCode) timedOut=$($run.TimedOut) | " + (@($notes) -join ' | ') + " | stderr=[$errText] | stdout tail=[$tail]"
    Check ($problems.Count -eq 0) 'the real window script starts, shows its window, closes on WM_CLOSE and exits 0 with an empty error stream and no fault reason code in the run log' $detail
}
finally {
    if ($null -ne $script:smokeProc -and -not $script:smokeProc.HasExited) { try { $script:smokeProc.Kill() } catch { $null = $_ } }
    foreach ($f in @(Get-ChildItem -LiteralPath $work -Recurse -File -ErrorAction SilentlyContinue)) { try { Remove-Item -LiteralPath $f.FullName -Force } catch { $null = $_ } }
    foreach ($d in @(Get-ChildItem -LiteralPath $work -Recurse -Directory -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending)) { try { Remove-Item -LiteralPath $d.FullName -Force } catch { $null = $_ } }
    try { Remove-Item -LiteralPath $work -Force } catch { $null = $_ }
}
Write-Host "INFO: startup smoke: $($script:smokePass) passed, $($script:smokeFail) failed"
if ($script:smokeFail -gt 0) { Write-Host "$($script:smokeFail) checks FAILED"; exit 1 }
Write-Host "UI fluent startup smoke tests passed: $($script:smokePass)"
