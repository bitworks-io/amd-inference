#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'src/FastLlm.Runtime.ps1'
. $source

Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
namespace Bitworks.FastLlm {
    public sealed class FakeInventoryProcess {
        public bool ExitInTime = true;
        public int ExitCode = 0;
        public bool WaitForExit(int milliseconds) { return ExitInTime; }
    }
    public sealed class ProcessHost : IDisposable {
        public static bool FakeTruncated;
        public static bool FakeOutputCompleted = true;
        public static string FakeOutput = "";
        public static bool FakeExitInTime = true;
        public static int FakeExitCode;
        public FakeInventoryProcess Process { get; private set; }
        public bool OutputCompleted { get { return FakeOutputCompleted; } }
        public bool OutputTruncated { get { return FakeTruncated; } }
        public ProcessHost() { Process = new FakeInventoryProcess(); Process.ExitInTime = FakeExitInTime; Process.ExitCode = FakeExitCode; }
        public void Start(ProcessStartInfo info) { }
        public string Snapshot() { return FakeOutput; }
        public void Dispose() { }
    }
}
'@ -ErrorAction Stop
function Initialize-FastLlmProcessHost { }
function Join-FastLlmProcessArguments { param([object[]]$Arguments) return '' }
function Get-Process { param([int]$Id) return [pscustomobject]@{ Path = 'fake-pwsh.exe' } }

$script:checks = 0
function Check([bool]$condition, [string]$message) {
    if (-not $condition) { throw "FAIL: $message" }
    $script:checks++
    Write-Host "PASS: $message"
}
function Check-Throws([string]$message, [string]$pattern) {
    $caught = $false
    try { Get-FastLlmWindowsInventory | Out-Null }
    catch { $caught = $_.Exception.Message -match $pattern }
    Check $caught $message
}

$oldOs = $env:OS
try {
    $env:OS = 'Windows_NT'
    $valid = [ordered]@{
        applicable = $true; qualified = $false; nativeHost = [ordered]@{
            schemaVersion = 1; kind = 'windows-native-host-inventory'; qualified = $false; status = 'captured'
            physicalMemoryBytes = [ordered]@{ value = [long]34359738368; source = 'GlobalMemoryStatusEx.ullTotalPhys'; status = 'captured' }
            activeLogicalProcessors = [ordered]@{ value = 16; source = 'GetActiveProcessorCount.ALL_PROCESSOR_GROUPS'; status = 'captured' }
            os = [ordered]@{ major = 10; minor = 0; build = 26200; ubr = 9168; architecture = 'x64'; versionSource = 'RtlGetVersion'; ubrSource = 'HKLM.CurrentVersion.UBR'; architectureSource = 'GetNativeSystemInfo'; status = 'captured' }
            advisory = [ordered]@{
                cpuNames = [ordered]@{ value = @('Intel Core i5-13400F'); source = 'HKLM.HARDWARE.CentralProcessor.ProcessorNameString'; status = 'captured'; scanLimit = 256; enumeratedKeys = 16; completeScan = $true }
                systemManufacturer = [ordered]@{ value = 'Test'; source = 'HKLM.HARDWARE.System.BIOS.SystemManufacturer'; status = 'captured' }
                systemProductName = [ordered]@{ value = 'Board'; source = 'HKLM.HARDWARE.System.BIOS.SystemProductName'; status = 'captured' }
            }
        }
    }
    [Bitworks.FastLlm.ProcessHost]::FakeOutput = ConvertTo-Json $valid -Depth 8
    $parsed = Get-FastLlmWindowsInventory
    Check ($parsed.nativeHost.status -eq 'captured' -and $parsed.nativeHost.os.build -eq 26200) 'complete bounded native-host JSON is accepted'

    [Bitworks.FastLlm.ProcessHost]::FakeTruncated = $true
    Check-Throws 'truncated child output is rejected' 'truncated'
    [Bitworks.FastLlm.ProcessHost]::FakeTruncated = $false
    [Bitworks.FastLlm.ProcessHost]::FakeOutput = 'x' * 65537
    Check-Throws 'oversized child output is rejected' 'oversized'
    [Bitworks.FastLlm.ProcessHost]::FakeOutput = '{not-json'
    Check-Throws 'malformed child JSON is rejected' 'JSON|Unexpected|Invalid'
    $invalid = ConvertTo-Json $valid -Depth 8 | ConvertFrom-Json
    $invalid.nativeHost.physicalMemoryBytes.source = 'untrusted'
    [Bitworks.FastLlm.ProcessHost]::FakeOutput = ConvertTo-Json $invalid -Depth 8
    Check-Throws 'incorrect nested provenance is rejected' 'diagnostic schema'
    [Bitworks.FastLlm.ProcessHost]::FakeExitInTime = $false
    Check-Throws 'timed-out child is rejected' '30-second deadline'
} finally {
    $env:OS = $oldOs
}
Write-Host "$script:checks native host parent checks passed. No native process was launched."
