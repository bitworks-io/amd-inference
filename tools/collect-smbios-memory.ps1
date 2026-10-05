#requires -Version 5.1
# Private read-only firmware memory diagnostic; never emits raw SMBIOS or strings.
[CmdletBinding()]
param([switch]$Worker)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) {
    throw 'SMBIOS memory diagnostic requires 64-bit Windows PowerShell on Windows.'
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this diagnostic as a standard user, not as administrator.'
}
$sourceRoot = Split-Path $PSScriptRoot -Parent
if ($Worker) {
    Add-Type -Path (Join-Path $sourceRoot 'src/WindowsSmbiosMemory.cs')
    $report = [Bitworks.FastLlm.WindowsSmbiosMemory]::Read()
    $json = ConvertTo-Json -InputObject $report -Depth 5 -Compress
    if ($json.Length -gt 7000) { throw 'Bounded memory report exceeds the output limit.' }
    [Console]::Out.WriteLine('SMBIOS_MEMORY_JSON:' + $json)
    return
}

Add-Type -Path (Join-Path $sourceRoot 'src/ProcessHost.cs')
$powershell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
if (-not [IO.File]::Exists($powershell)) { throw 'System32 Windows PowerShell is unavailable.' }
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = $powershell
$info.Arguments = '-NoLogo -NoProfile -NonInteractive -File "' + $MyInvocation.MyCommand.Path + '" -Worker'
$info.WorkingDirectory = $PSScriptRoot
$hostProcess = New-Object Bitworks.FastLlm.ProcessHost
try {
    $hostProcess.Start($info)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.ElapsedMilliseconds -lt 30000) {
        if ($hostProcess.Process.HasExited -and $hostProcess.OutputCompleted) { break }
        Start-Sleep -Milliseconds 25
    }
    if (-not $hostProcess.Process.HasExited -or -not $hostProcess.OutputCompleted) {
        throw 'SMBIOS memory worker did not finish within 30 seconds.'
    }
    $captured = $hostProcess.Snapshot()
    if ($hostProcess.Process.ExitCode -ne 0 -or $hostProcess.OutputTruncated -or $captured.Length -gt 8192) {
        throw 'SMBIOS memory worker failed or exceeded its output limit.'
    }
    $lines = @($captured -split "`r?`n" | Where-Object { $_.Length -gt 0 })
    if ($lines.Count -ne 1 -or -not $lines[0].StartsWith('SMBIOS_MEMORY_JSON:',[StringComparison]::Ordinal)) {
        throw 'SMBIOS memory worker returned an unexpected report shape.'
    }
    $report = ConvertFrom-Json -InputObject $lines[0].Substring(19) -ErrorAction Stop
    if ($report.schemaVersion -ne 1 -or $report.kind -cne 'windows-smbios-type17-memory' -or
        $report.qualified -ne $false -or @($report.devices).Count -gt 32) {
        throw 'SMBIOS memory worker returned an unrecognized report.'
    }
    $report | ConvertTo-Json -Depth 5
}
finally { $hostProcess.Dispose() }
