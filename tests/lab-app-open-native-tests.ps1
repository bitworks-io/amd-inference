#requires -Version 5.1
# Disposable Windows-only canary for the private lab companion's guarded Open.
# This never launches the real FastLLM UI, engine, model, or installer.
[CmdletBinding()]
param(
    [switch]$AllowNativeLabOpenCanary,
    [switch]$Worker,
    [string]$CanaryRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
if ($env:OS -cne 'Windows_NT') {
    Write-Host 'SKIP: guarded Open native canary requires Windows.'
    return
}
if ($PSVersionTable.PSVersion.Major -ne 5 -or -not [Environment]::Is64BitProcess) {
    throw 'Guarded Open native canary requires 64-bit Windows PowerShell 5.1.'
}
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run guarded Open canary as a standard Windows user.'
}
if (-not $AllowNativeLabOpenCanary) {
    Write-Host 'SKIP: explicitly pass -AllowNativeLabOpenCanary for disposable native process testing.'
    return
}
$repo = Split-Path $PSScriptRoot -Parent
$tool = Join-Path $repo 'tools/install-lab-app.ps1'
$self = $MyInvocation.MyCommand.Path
$local = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
$expectedPrefix = Join-Path $local 'Bitworks'
if (-not $CanaryRoot -and -not $Worker) {
    $CanaryRoot = Join-Path $expectedPrefix ('FastLLM Lab Open & Canary ' + [Guid]::NewGuid().ToString('N'))
}
if ([string]::IsNullOrWhiteSpace($CanaryRoot) -or
    -not [IO.Path]::GetFullPath($CanaryRoot).StartsWith(($expectedPrefix + [IO.Path]::DirectorySeparatorChar),[StringComparison]::OrdinalIgnoreCase) -or
    [IO.Path]::GetFileName($CanaryRoot) -cnotmatch '^FastLLM Lab Open & Canary [0-9a-f]{32}$') {
    throw 'Canary root must be an exact disposable Bitworks LocalAppData child.'
}
$CanaryRoot = [IO.Path]::GetFullPath($CanaryRoot)
$leasePath = Join-Path $CanaryRoot 'lab-app-lifetime.lock'
$childMarker = Join-Path $CanaryRoot 'child-owner.txt'
$cmdMarker = Join-Path $CanaryRoot 'cmd-owner.txt'
$cmdEntered = Join-Path $CanaryRoot 'cmd-entered.marker'
$childOutput = Join-Path $CanaryRoot 'child-output.txt'
$releasePath = Join-Path $CanaryRoot 'release.signal'

function Check([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Get-ExactOwnedProcess([string]$Marker) {
    if (-not (Test-Path -LiteralPath $Marker -PathType Leaf)) { return $null }
    $raw = [IO.File]::ReadAllText($Marker).Trim()
    if ($raw -cnotmatch '^([1-9][0-9]{0,9})\|([1-9][0-9]{0,19})$') { throw 'Disposable process marker is malformed.' }
    $id = [int]$Matches[1]
    $ticks = [long]$Matches[2]
    try {
        $process = [Diagnostics.Process]::GetProcessById($id)
        if ($process.HasExited -or $process.StartTime.ToUniversalTime().Ticks -ne $ticks) {
            $process.Dispose()
            return $null
        }
        return $process
    } catch [ArgumentException] { return $null }
}
function Test-ExclusiveLease([string]$Path) {
    $exclusive = $null
    try {
        $exclusive = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        return $true
    } catch [IO.IOException] { return $false }
    finally { if ($exclusive) { $exclusive.Dispose() } }
}

if ($Worker) {
    $checks = 0
    $lease = $null
    $cmdProcess = $null
    try {
        # The outer ProcessHost's kill-on-close job must exist before the go marker.
        $goPath = Join-Path $CanaryRoot 'go.signal'
        $goWatch = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath $goPath) -and $goWatch.Elapsed.TotalSeconds -lt 8) {
            Start-Sleep -Milliseconds 50
        }
        Check (Test-Path -LiteralPath $goPath) 'outer ProcessHost job was not ready'
        $tokens = $null; $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($tool,[ref]$tokens,[ref]$parseErrors)
        Check (@($parseErrors).Count -eq 0) 'reviewed companion source did not parse'
        $guard = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Start-FastLlmLabGuardedCommand' },$true)
        Check ($null -ne $guard) 'guarded Open function is absent'
        . ([scriptblock]::Create($guard.Extent.Text))

        $childScript = Join-Path $CanaryRoot 'child.ps1'
        $cmdPath = Join-Path $CanaryRoot 'FastLLM.cmd'
        $childSource = @'
param([string]$CanaryRoot)
$ErrorActionPreference = 'Stop'
$me = [Diagnostics.Process]::GetCurrentProcess()
[IO.File]::WriteAllText((Join-Path $CanaryRoot 'child-owner.txt'),
    ([string]$PID + '|' + [string]$me.StartTime.ToUniversalTime().Ticks))
$deadline = [DateTime]::UtcNow.AddSeconds(16)
while (-not (Test-Path -LiteralPath (Join-Path $CanaryRoot 'release.signal')) -and [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 50
}
if (-not (Test-Path -LiteralPath (Join-Path $CanaryRoot 'release.signal'))) { exit 42 }
exit 0
'@
        $cmdSource = @'
@echo off
setlocal
> "%~dp0cmd-entered.marker" echo entered
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -File "%~dp0child.ps1" -CanaryRoot "%~dp0." > "%~dp0child-output.txt" 2>&1
exit /b %errorlevel%
'@
        $cmdSource = [regex]::Replace($cmdSource.TrimEnd([char[]]@([char]13,[char]10)),"\r?\n","`r`n") + "`r`n"
        [IO.File]::WriteAllText($childScript,$childSource,[Text.Encoding]::ASCII)
        [IO.File]::WriteAllText($cmdPath,$cmdSource,[Text.Encoding]::ASCII)
        Check ([Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($cmdPath)).Contains("`r`n")) 'self-authored command fixture lacks Windows line endings'
        [IO.File]::WriteAllBytes($leasePath,[byte[]]@())
        $lease = [IO.File]::Open($leasePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)

        # Both refusals occur before the primary thread can run. Neither may
        # create the child marker or release the caller's lease.
        $unsafe = $false
        try { Start-FastLlmLabGuardedCommand -Lease $lease -Target ($cmdPath + '%') -WorkingDirectory $CanaryRoot | Out-Null }
        catch { $unsafe = ([string]$_.Exception.Message).Contains('cannot be safely passed') }
        Check $unsafe 'cmd expansion character was not refused'
        $duplicateFailed = $false
        try { [FastLlmLabLeaseNative]::Launch($cmdPath,$CanaryRoot,[IntPtr]::Zero) | Out-Null }
        catch { $duplicateFailed = ([string]$_.Exception.Message).Contains('lifetime lease') }
        Check $duplicateFailed 'suspended-process duplicate failure was not refused'
        Check (-not (Test-Path -LiteralPath $childMarker) -and -not (Test-ExclusiveLease $leasePath)) 'pre-resume failure ran a child or released the parent lease'

        $cmdId = Start-FastLlmLabGuardedCommand -Lease $lease -Target $cmdPath -WorkingDirectory $CanaryRoot
        # Simulate the setup window closing at the earliest possible instant,
        # before the PowerShell child has necessarily reached its own lease.
        $lease.Dispose(); $lease = $null
        Check (-not (Test-ExclusiveLease $leasePath)) 'immediate setup lease close exposed a launch/uninstall gap'
        $cmdProcess = [Diagnostics.Process]::GetProcessById([int]$cmdId)
        $cmdTicks = $cmdProcess.StartTime.ToUniversalTime().Ticks
        [IO.File]::WriteAllText($cmdMarker,([string]$cmdId + '|' + [string]$cmdTicks))
        Check ($cmdProcess.ProcessName -ieq 'cmd') 'guarded launcher did not return its command process'
        $readyWatch = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath $childMarker) -and $readyWatch.Elapsed.TotalSeconds -lt 8) {
            if ($cmdProcess.HasExited) { break }
            Start-Sleep -Milliseconds 50
        }
        Check (Test-Path -LiteralPath $cmdEntered) 'guarded command process did not enter the disposable batch fixture'
        if (-not (Test-Path -LiteralPath $childMarker)) {
            $diagnostic = '<no child output>'
            if (Test-Path -LiteralPath $childOutput) {
                try {
                    $captured = [IO.File]::ReadAllText($childOutput)
                    $diagnostic = $captured.Substring(0,[Math]::Min($captured.Length,2048)).Trim()
                } catch { $diagnostic = '<child output could not be read>' }
            }
            throw "FAIL: synchronous PowerShell child did not start. Bounded child output: $diagnostic"
        }
        $checks++
        $child = Get-ExactOwnedProcess $childMarker
        Check ($null -ne $child -and -not $cmdProcess.HasExited) 'command did not remain alive while its child ran'
        if ($child) { $child.Dispose() }

        Check (-not (Test-ExclusiveLease $leasePath)) 'owned command released its lease while synchronous child was active'
        [IO.File]::WriteAllText($releasePath,'release')
        Check ($cmdProcess.WaitForExit(8000)) 'owned command did not exit after child release'
        Check ($null -eq (Get-ExactOwnedProcess $childMarker)) 'owned PowerShell child remains alive after command exit'
        Check (Test-ExclusiveLease $leasePath) 'lease remained held after command and child exited'
        Write-Host "PASS: guarded Open native canary ($checks checks), disposable root $CanaryRoot"
    } catch {
        Write-Host "FAIL: guarded Open native canary at $CanaryRoot : $($_.Exception.Message)"
        throw
    } finally {
        if ($lease) { $lease.Dispose() }
        if (-not (Test-Path -LiteralPath $releasePath)) { [IO.File]::WriteAllText($releasePath,'release') }
        if ($cmdProcess) { $cmdProcess.Dispose() }
        # The outer kill-on-close job is the primary bounded containment. This
        # exact PID/start cleanup is a second line of defense, never a PID-only kill.
        foreach ($marker in @($cmdMarker,$childMarker)) {
            try {
                $owned = Get-ExactOwnedProcess $marker
                if ($owned) {
                    try { $owned.Kill(); [void]$owned.WaitForExit(3000) }
                    finally { $owned.Dispose() }
                }
            } catch { Write-Warning "Exact process cleanup could not read $marker; the outer job remains the containment boundary." }
        }
    }
    return
}

if (Test-Path -LiteralPath $CanaryRoot) { throw 'Disposable canary root unexpectedly exists.' }
[void][IO.Directory]::CreateDirectory($CanaryRoot)
Add-Type -Path (Join-Path $repo 'src/ProcessHost.cs') -ErrorAction Stop
$hosted = New-Object Bitworks.FastLlm.ProcessHost
$passed = $false
try {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = (Get-Process -Id $PID).Path
    # Paths cannot contain a double quote on Windows. ProcessHost uses
    # CreateProcess directly, so ampersands are not shell operators here.
    if ($self.Contains('"') -or $CanaryRoot.Contains('"')) { throw 'Unsafe worker argument path.' }
    $info.Arguments = '-NoLogo -NoProfile -NonInteractive -File "' + $self +
        '" -Worker -AllowNativeLabOpenCanary -CanaryRoot "' + $CanaryRoot + '"'
    $info.WorkingDirectory = $repo
    $hosted.Start($info)
    [IO.File]::WriteAllText((Join-Path $CanaryRoot 'go.signal'),'go')
    if (-not $hosted.Process.WaitForExit(35000)) { throw 'Guarded Open worker exceeded its 35-second parent deadline.' }
    $outputWatch = [Diagnostics.Stopwatch]::StartNew()
    while (-not $hosted.OutputCompleted -and $outputWatch.Elapsed.TotalSeconds -lt 3) {
        Start-Sleep -Milliseconds 20
    }
    if (-not $hosted.OutputCompleted -or $hosted.OutputTruncated) { throw 'Guarded Open worker output was incomplete or truncated.' }
    $snapshot = [string]$hosted.Snapshot()
    if ($hosted.Process.ExitCode -ne 0 -or $snapshot -notmatch 'PASS: guarded Open native canary \([0-9]+ checks\)') {
        throw "Guarded Open worker failed: $($snapshot.Substring(0,[Math]::Min($snapshot.Length,4096)))"
    }
    $passed = $true
    Write-Host $snapshot.Trim()
} catch {
    Write-Host "Native canary evidence retained: $CanaryRoot"
    throw
} finally {
    $hosted.Dispose()
    foreach ($marker in @($cmdMarker,$childMarker)) {
        try {
            $owned = Get-ExactOwnedProcess $marker
            if ($owned) {
                try { $owned.Kill(); [void]$owned.WaitForExit(3000) }
                finally { $owned.Dispose() }
            }
        } catch { Write-Warning "Exact process cleanup could not read $marker after job disposal." }
    }
    if ($passed -and (Test-Path -LiteralPath $CanaryRoot)) {
        Remove-Item -LiteralPath $CanaryRoot -Recurse -Force
    }
}
