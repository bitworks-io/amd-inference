#requires -Version 5.1
# Private lab-only, read-only ADLX identity / VRAM sampler wrapper. Never part of the inference
# startup path. Runs the pinned adlx-identity-vram.exe as a bounded, job-contained child and
# writes JSON lines (.jsonl) or, for identity mode only, one JSON document (.json).
# qualification and servingDeviceBound are false on every record.
[CmdletBinding()]
param(
    [string]$Mode,
    [Nullable[int]]$IntervalMs,
    [Nullable[int]]$Count,
    [string]$ExecutablePath,
    [string]$ExpectedExecutableSha256,
    [string]$OutputPath,
    [Nullable[int]]$TimeoutSeconds,
    # Test seam: define the helper functions and return before any host guard or collection.
    [switch]$LibraryOnly
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:AdlxMinIntervalMs = 200
$script:AdlxMaxIntervalMs = 5000
$script:AdlxMaxCount = 36000
$script:AdlxMaxWallMs = [long]7200000
$script:AdlxMaxGpus = 8
$script:AdlxMaxLineChars = 8192
$script:AdlxStatuses = @('available', 'unsupported', 'unsupported-interface', 'failed', 'invalid-value')
$script:AdlxIdentityFields = @(
    'pnpString', 'vendorId', 'deviceId', 'revisionId', 'subSystemId', 'subSystemVendorId', 'name',
    'totalVramMB', 'vramType', 'uniqueId', 'asicFamilyType', 'type', 'isExternal', 'hasDesktops',
    'driverPath', 'biosInfo', 'productName', 'pciBusType', 'pciBusLaneWidth', 'multiGpuMode',
    'isPowerOff', 'amdSoftwareEdition', 'amdSoftwareVersion', 'driverVersion',
    'amdWindowsDriverVersion', 'amdSoftwareReleaseDate', 'luid')
$script:AdlxSampleFields = @(
    'pnpString', 'gpuVramMB', 'gpuUsagePercent', 'gpuClockMHz', 'gpuVramClockMHz',
    'gpuTotalBoardPowerW', 'gpuTemperatureC', 'gpuHotspotTemperatureC')

# Streams collector stdout lines to a CreateNew file (or memory when path is null or empty; PowerShell marshals $null strings as empty), validating
# each line structurally and bounding line length, line count and bytes. Compiled with the
# Windows PowerShell 5.1 C# compiler, so no newer language features are used.
$script:AdlxLineSinkSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
namespace Bitworks.FastLlm {
    public sealed class AdlxLineSink : IDisposable {
        private readonly object sync = new object();
        private FileStream stream;
        private readonly string kindMarker;
        private readonly int maxLines;
        private readonly long maxBytes;
        private readonly List<string> first = new List<string>();
        private readonly List<string> collected = new List<string>();
        private readonly bool memoryOnly;
        private string last;
        private int lines;
        private long bytes;
        private string error;
        public readonly DataReceivedEventHandler Handler;
        public AdlxLineSink(string path, string kind, int maxLines, long maxBytes) {
            this.kindMarker = "\"kind\":\"" + kind + "\"";
            this.maxLines = maxLines;
            this.maxBytes = maxBytes;
            this.memoryOnly = String.IsNullOrEmpty(path);
            if (!memoryOnly) stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read);
            Handler = new DataReceivedEventHandler(OnLine);
        }
        private void OnLine(object sender, DataReceivedEventArgs args) {
            if (args.Data == null) return;
            lock (sync) {
                if (error != null) return;
                string line = args.Data;
                if (line.Length == 0) return;
                if (line.Length > 8192) { error = "line-too-long"; return; }
                if (!line.StartsWith("{", StringComparison.Ordinal) ||
                    !line.EndsWith(",\"qualification\":false,\"servingDeviceBound\":false}", StringComparison.Ordinal) ||
                    line.IndexOf("\"schemaVersion\":1,", StringComparison.Ordinal) < 0 ||
                    line.IndexOf(kindMarker, StringComparison.Ordinal) < 0) { error = "unexpected-collector-line"; return; }
                if (lines >= maxLines) { error = "too-many-lines"; return; }
                bytes += Encoding.UTF8.GetByteCount(line) + 1;
                if (bytes > maxBytes) { error = "output-byte-limit"; return; }
                lines++;
                if (first.Count < 16) first.Add(line);
                last = line;
                if (memoryOnly) collected.Add(line);
                else WriteLine(line);
            }
        }
        private void WriteLine(string line) {
            byte[] data = new UTF8Encoding(false).GetBytes(line + "\n");
            stream.Write(data, 0, data.Length);
            stream.Flush();
        }
        // Wrapper-authored header/footer lines; not counted as collector lines.
        public void WriteRaw(string line) {
            lock (sync) { if (!memoryOnly) WriteLine(line); }
        }
        public int Lines { get { lock (sync) { return lines; } } }
        public string Error { get { lock (sync) { return error; } } }
        public string[] First { get { lock (sync) { return first.ToArray(); } } }
        public string[] Collected { get { lock (sync) { return collected.ToArray(); } } }
        public string Last { get { lock (sync) { return last; } } }
        public void Dispose() {
            lock (sync) {
                if (stream != null) {
                    try { stream.Flush(true); } finally { stream.Dispose(); stream = null; }
                }
            }
        }
    }
}
'@

function Initialize-AdlxLineSink {
    if (-not ('Bitworks.FastLlm.AdlxLineSink' -as [type])) {
        Add-Type -TypeDefinition $script:AdlxLineSinkSource -ErrorAction Stop
    }
}

function Assert-AdlxIdentityParameters {
    param(
        [string]$Mode,
        [Nullable[int]]$IntervalMs,
        [Nullable[int]]$Count,
        [Nullable[int]]$TimeoutSeconds
    )
    if ($Mode -cne 'identity' -and $Mode -cne 'sample') { throw 'Mode must be identity or sample.' }
    $wallMs = [long]0
    if ($Mode -ceq 'identity') {
        if ($null -ne $IntervalMs -or $null -ne $Count) { throw 'IntervalMs and Count apply only to sample mode.' }
        $effective = 60
        if ($null -ne $TimeoutSeconds) {
            if ($TimeoutSeconds -lt 5 -or $TimeoutSeconds -gt 300) { throw 'TimeoutSeconds must be 5-300 for identity mode.' }
            $effective = [int]$TimeoutSeconds
        }
        return [ordered]@{ Mode = 'identity'; IntervalMs = $null; Count = $null; TimeoutSeconds = $effective }
    }
    if ($null -eq $IntervalMs -or $null -eq $Count) { throw 'sample mode requires IntervalMs and Count.' }
    if ($IntervalMs -lt $script:AdlxMinIntervalMs -or $IntervalMs -gt $script:AdlxMaxIntervalMs) {
        throw 'IntervalMs must be 200-5000.'
    }
    if ($Count -lt 1 -or $Count -gt $script:AdlxMaxCount) { throw 'Count must be 1-36000.' }
    $wallMs = [long]$IntervalMs * [long]$Count
    if ($wallMs -gt $script:AdlxMaxWallMs) { throw 'Total sampling wall time must not exceed 2 hours.' }
    $minimum = [int][Math]::Ceiling($wallMs / 1000.0) + 5
    $effective = [int][Math]::Ceiling($wallMs / 1000.0) + 60
    if ($null -ne $TimeoutSeconds) {
        if ($TimeoutSeconds -lt $minimum -or $TimeoutSeconds -gt 7500) {
            throw ('TimeoutSeconds must be {0}-7500 for this sampling plan.' -f $minimum)
        }
        $effective = [int]$TimeoutSeconds
    }
    return [ordered]@{ Mode = 'sample'; IntervalMs = [int]$IntervalMs; Count = [int]$Count; TimeoutSeconds = $effective }
}

function Assert-AdlxIdentityOutputPath {
    param([string]$Path, [string]$Mode)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) {
        throw 'OutputPath must be an absolute local file path.'
    }
    $full = [IO.Path]::GetFullPath($Path)
    $extension = [IO.Path]::GetExtension($full)
    if ($extension -ine '.json' -and $extension -ine '.jsonl') { throw 'OutputPath must be a .json or .jsonl file.' }
    if ($Mode -ceq 'sample' -and $extension -ine '.jsonl') { throw 'sample mode writes JSON lines; use a .jsonl OutputPath.' }
    if ($env:OS -eq 'Windows_NT' -and [IO.Path]::GetPathRoot($full) -notmatch '^[A-Za-z]:\\$') {
        throw 'OutputPath must be on a local drive.'
    }
    $parentPath = [IO.Path]::GetDirectoryName($full)
    $parent = Get-Item -LiteralPath $parentPath -ErrorAction Stop
    if (-not $parent.PSIsContainer) { throw 'Output parent is not a directory.' }
    $cursor = [IO.Path]::GetPathRoot($parentPath)
    $segments = $parentPath.Substring($cursor.Length).Split([IO.Path]::DirectorySeparatorChar)
    foreach ($segment in @('') + $segments) {
        if ($segment.Length -gt 0) { $cursor = Join-Path $cursor $segment }
        $part = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if (($part.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Output path traverses a reparse point.'
        }
    }
    # A dangling link reports as non-existent to File.Exists, so also look at the entry itself.
    $existing = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
    if ($null -ne $existing -or [IO.File]::Exists($full) -or [IO.Directory]::Exists($full)) {
        throw 'OutputPath already exists; choose a fresh report filename.'
    }
    return $full
}

function Get-AdlxIdentityFileSha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-AdlxExecutable {
    param([string]$Path, [string]$ExpectedSha256)
    if ([string]::IsNullOrWhiteSpace($ExpectedSha256) -or $ExpectedSha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'ExpectedExecutableSha256 must be a 64-character hexadecimal SHA-256.'
    }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) {
        throw 'ExecutablePath must be an absolute file path.'
    }
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw 'Executable path is not a regular file.'
    }
    $actual = Get-AdlxIdentityFileSha256 -Path $item.FullName
    if ($actual -ne $ExpectedSha256.ToLowerInvariant()) { throw 'Executable digest mismatch.' }
    return [pscustomobject]@{ Path = $item.FullName; Sha256 = $actual }
}

function Get-AdlxRecordProperty {
    param($Row, [string]$Name)
    $property = $Row.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

# Parses and validates one collector line. Throws on any schema deviation.
function ConvertFrom-AdlxCollectorLine {
    param([string]$Line, [string]$Mode)
    if ([string]::IsNullOrWhiteSpace($Line) -or $Line.Length -gt $script:AdlxMaxLineChars -or -not $Line.StartsWith('{')) {
        throw 'Unexpected ADLX collector output.'
    }
    $row = $Line | ConvertFrom-Json -ErrorAction Stop
    $expectedKind = 'adlx-identity'
    $fields = $script:AdlxIdentityFields
    if ($Mode -ceq 'sample') { $expectedKind = 'adlx-sample'; $fields = $script:AdlxSampleFields }
    if ((Get-AdlxRecordProperty $row 'schemaVersion') -ne 1 -or (Get-AdlxRecordProperty $row 'kind') -cne $expectedKind) {
        throw 'ADLX collector output kind mismatch.'
    }
    if ((Get-AdlxRecordProperty $row 'qualification') -ne $false -or (Get-AdlxRecordProperty $row 'servingDeviceBound') -ne $false) {
        throw 'ADLX collector output must carry qualification=false and servingDeviceBound=false.'
    }
    $gpuIndex = Get-AdlxRecordProperty $row 'gpuIndex'
    $gpuCount = Get-AdlxRecordProperty $row 'gpuCount'
    if ($null -eq $gpuIndex -or $null -eq $gpuCount -or $gpuCount -lt 1 -or $gpuCount -gt $script:AdlxMaxGpus -or
        $gpuIndex -lt 0 -or $gpuIndex -ge $gpuCount) {
        throw 'ADLX collector GPU index out of bounds.'
    }
    if ($null -eq (Get-AdlxRecordProperty $row 'utcFileTime')) { throw 'ADLX collector record has no timestamp.' }
    if ($Mode -ceq 'sample') {
        $sample = Get-AdlxRecordProperty $row 'sample'
        if ($null -eq $sample -or $sample -lt 0 -or $sample -ge $script:AdlxMaxCount) { throw 'ADLX sample index out of bounds.' }
    }
    foreach ($name in $fields) {
        $field = Get-AdlxRecordProperty $row $name
        if ($null -eq $field) { throw ('ADLX collector record is missing field {0}.' -f $name) }
        $status = Get-AdlxRecordProperty $field 'status'
        if ($null -eq $status -or $script:AdlxStatuses -cnotcontains [string]$status) {
            throw ('ADLX field {0} has no valid status.' -f $name)
        }
        if ($null -eq $field.PSObject.Properties['adlxResult'] -or $null -eq $field.PSObject.Properties['value']) {
            throw ('ADLX field {0} lacks adlxResult or value.' -f $name)
        }
        if ([string]$status -ceq 'failed' -and $null -eq $field.adlxResult) {
            throw ('ADLX failed field {0} lacks the raw result code.' -f $name)
        }
    }
    return $row
}

function Get-AdlxDriverEvidence {
    $dllPath = Join-Path ([Environment]::SystemDirectory) 'amdadlx64.dll'
    $dll = Get-Item -LiteralPath $dllPath -ErrorAction Stop
    if ($dll.PSIsContainer -or (($dll.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw 'ADLX driver library is not a regular System32 file.'
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $dll.FullName
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch '(^|,)\s*O=Advanced Micro Devices(,|$)') {
        throw 'ADLX driver library does not have a valid AMD publisher signature.'
    }
    $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($dll.FullName).FileVersion
    if ([string]::IsNullOrWhiteSpace($version)) { throw 'ADLX driver library has no file version.' }
    return [pscustomobject]@{
        Path = $dll.FullName
        Version = $version
        Sha256 = Get-AdlxIdentityFileSha256 -Path $dll.FullName
        Signer = $signature.SignerCertificate.Subject
    }
}

function New-AdlxHeaderRecord {
    param($Plan, [string]$WrapperSha256, $Executable, $Driver, [string]$StartedUtc)
    return [ordered]@{
        schemaVersion = 1
        kind = 'adlx-run-header'
        qualification = $false
        servingDeviceBound = $false
        mode = $Plan.Mode
        intervalMs = $Plan.IntervalMs
        count = $Plan.Count
        timeoutSeconds = $Plan.TimeoutSeconds
        startedUtc = $StartedUtc
        wrapperSourceSha256 = $WrapperSha256
        collectorSha256 = $Executable.Sha256
        adlxDriverPath = $Driver.Path
        adlxDriverVersion = $Driver.Version
        adlxDriverSha256 = $Driver.Sha256
        adlxDriverSigner = $Driver.Signer
        readOnly = $true
    }
}

function New-AdlxFooterRecord {
    param([string]$Status, [int]$CollectorLines, $ExitCode, [string]$ErrorText, [string]$EndedUtc)
    return [ordered]@{
        schemaVersion = 1
        kind = 'adlx-run-footer'
        qualification = $false
        servingDeviceBound = $false
        status = $Status
        collectorLines = $CollectorLines
        exitCode = $ExitCode
        error = $ErrorText
        endedUtc = $EndedUtc
    }
}

function ConvertTo-AdlxJsonLine {
    param($Value)
    return (ConvertTo-Json -InputObject $Value -Depth 6 -Compress)
}

# Builds the single-document identity report (.json) from validated raw lines.
function New-AdlxIdentityDocument {
    param([string]$HeaderLine, [string[]]$RecordLines, [string]$FooterLine)
    return ('{{"schemaVersion":1,"kind":"adlx-identity-report","qualification":false,"servingDeviceBound":false,"header":{0},"records":[{1}],"footer":{2}}}' -f
        $HeaderLine, ($RecordLines -join ','), $FooterLine)
}

function Invoke-AdlxIdentityVram {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$OutputFile,
        [Parameter(Mandatory = $true)]$Executable,
        [Parameter(Mandatory = $true)]$Driver,
        [Parameter(Mandatory = $true)][string]$WrapperSha256,
        [Parameter(Mandatory = $true)][string]$RepoDirectory
    )
    $hostSource = Join-Path $RepoDirectory 'src/ProcessHost.cs'
    if (-not (Test-Path -LiteralPath $hostSource -PathType Leaf)) { throw 'Bounded native process host source is unavailable.' }
    if (-not ('Bitworks.FastLlm.ProcessHost' -as [type])) { Add-Type -Path $hostSource }
    Initialize-AdlxLineSink

    $isDocument = ([IO.Path]::GetExtension($OutputFile) -ieq '.json')
    $expectedKind = 'adlx-identity'
    $maxLines = $script:AdlxMaxGpus
    $arguments = 'identity'
    if ($Plan.Mode -ceq 'sample') {
        $expectedKind = 'adlx-sample'
        $maxLines = [int]$Plan.Count * $script:AdlxMaxGpus
        $arguments = 'sample --interval-ms {0} --count {1}' -f $Plan.IntervalMs, $Plan.Count
    }
    $sinkPath = $OutputFile
    if ($isDocument) { $sinkPath = $null }
    # CreateNew refuses to overwrite even if the file appears after the earlier check.
    $sink = New-Object Bitworks.FastLlm.AdlxLineSink($sinkPath, $expectedKind, $maxLines, [long]536870912)
    $startedUtc = [DateTime]::UtcNow.ToString('o')
    $headerLine = ConvertTo-AdlxJsonLine (New-AdlxHeaderRecord -Plan $Plan -WrapperSha256 $WrapperSha256 `
        -Executable $Executable -Driver $Driver -StartedUtc $startedUtc)
    $status = 'failed'
    $errorText = $null
    $exitCode = $null
    $hostProcess = $null
    $recordLines = @()
    try {
        $sink.WriteRaw($headerLine)
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $Executable.Path
        $info.Arguments = $arguments
        $info.WorkingDirectory = [Environment]::SystemDirectory
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $hostProcess = New-Object Bitworks.FastLlm.ProcessHost
        $hostProcess.Process.add_OutputDataReceived($sink.Handler)
        $deadlineMs = [long]$Plan.TimeoutSeconds * 1000
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $hostProcess.Start($info)
        while ($timer.ElapsedMilliseconds -lt $deadlineMs) {
            if ($hostProcess.Process.WaitForExit(100)) { break }
            if ($null -ne $sink.Error) { break }
        }
        if ($null -ne $sink.Error) { throw ('ADLX collector output rejected: {0}.' -f $sink.Error) }
        if (-not $hostProcess.Process.HasExited) { throw 'ADLX collector exceeded its deadline.' }
        $exitCode = $hostProcess.Process.ExitCode
        while (-not $hostProcess.OutputCompleted -and $timer.ElapsedMilliseconds -lt $deadlineMs) {
            Start-Sleep -Milliseconds 50
        }
        if (-not $hostProcess.OutputCompleted) { throw 'ADLX collector output did not complete before deadline.' }
        if ($null -ne $sink.Error) { throw ('ADLX collector output rejected: {0}.' -f $sink.Error) }
        if ($exitCode -ne 0) {
            $stderrHint = $hostProcess.Snapshot()
            if ($stderrHint.Length -gt 300) { $stderrHint = $stderrHint.Substring(0, 300) }
            throw ('ADLX collector failed with exit code {0}: {1}' -f $exitCode, ($stderrHint -replace '[^\x20-\x7e]', ' '))
        }
        $linesSeen = $sink.Lines
        if ($linesSeen -lt 1) { throw 'ADLX collector produced no records.' }
        $firstRow = ConvertFrom-AdlxCollectorLine -Line $sink.First[0] -Mode $Plan.Mode
        $gpuCount = [int]$firstRow.gpuCount
        if ($Plan.Mode -ceq 'identity') {
            $recordLines = @($sink.Collected)
            if ($recordLines.Count -ne $gpuCount) { throw 'Identity record count does not match the GPU count.' }
            $seen = @{}
            foreach ($line in $recordLines) {
                $row = ConvertFrom-AdlxCollectorLine -Line $line -Mode 'identity'
                if ([int]$row.gpuCount -ne $gpuCount -or $seen.ContainsKey([int]$row.gpuIndex)) {
                    throw 'Identity records are duplicated or inconsistent.'
                }
                $seen[[int]$row.gpuIndex] = $true
            }
        } else {
            if ($linesSeen -ne ($gpuCount * [int]$Plan.Count)) { throw 'Sample record count does not match count x GPUs.' }
            # Full per-line JSON parsing of up to 288000 lines is too slow; the sink checked every
            # line structurally, and the first and last records are parsed in full here.
            foreach ($line in @($sink.First)) { $null = ConvertFrom-AdlxCollectorLine -Line $line -Mode 'sample' }
            $lastRow = ConvertFrom-AdlxCollectorLine -Line $sink.Last -Mode 'sample'
            if ([int]$lastRow.sample -ne ([int]$Plan.Count - 1) -or [int]$lastRow.gpuIndex -ne ($gpuCount - 1)) {
                throw 'Final sample record does not match the requested count.'
            }
        }
        if ((Get-AdlxIdentityFileSha256 -Path $Executable.Path) -ne $Executable.Sha256 -or
            (Get-AdlxIdentityFileSha256 -Path $Driver.Path) -ne $Driver.Sha256 -or
            (Get-AdlxIdentityFileSha256 -Path $PSCommandPath) -ne $WrapperSha256) {
            throw 'On-disk collector inputs changed during the run.'
        }
        $status = 'complete'
    } catch {
        $errorText = $_.Exception.Message
        throw
    } finally {
        if ($null -ne $hostProcess) { $hostProcess.Dispose() }
        $footerLine = ConvertTo-AdlxJsonLine (New-AdlxFooterRecord -Status $status -CollectorLines $sink.Lines `
            -ExitCode $exitCode -ErrorText $errorText -EndedUtc ([DateTime]::UtcNow.ToString('o')))
        if ($isDocument) {
            if ($status -ceq 'complete') {
                $document = New-AdlxIdentityDocument -HeaderLine $headerLine -RecordLines $recordLines -FooterLine $footerLine
                $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($document + "`n")
                $stream = [IO.File]::Open($OutputFile, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
            }
        } else {
            $sink.WriteRaw($footerLine)
        }
        $sink.Dispose()
    }
    return [pscustomobject]@{
        reportPath = $OutputFile
        reportSha256 = Get-AdlxIdentityFileSha256 -Path $OutputFile
        collectorLines = $linesSeen
        qualification = $false
    }
}

if ($LibraryOnly) { return }

try {
    if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) {
        throw 'ADLX identity collector requires standard-user, 64-bit Windows.'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run the ADLX identity collector as a standard user.'
    }
    $plan = Assert-AdlxIdentityParameters -Mode $Mode -IntervalMs $IntervalMs -Count $Count -TimeoutSeconds $TimeoutSeconds
    $outputFile = Assert-AdlxIdentityOutputPath -Path $OutputPath -Mode $plan.Mode
    $wrapperSha256 = Get-AdlxIdentityFileSha256 -Path $PSCommandPath
    $executable = Assert-AdlxExecutable -Path $ExecutablePath -ExpectedSha256 $ExpectedExecutableSha256
    $driver = Get-AdlxDriverEvidence
    $result = Invoke-AdlxIdentityVram -Plan $plan -OutputFile $outputFile -Executable $executable -Driver $driver `
        -WrapperSha256 $wrapperSha256 -RepoDirectory (Split-Path -Parent $PSScriptRoot)
    $result
} catch {
    [Console]::Error.WriteLine('adlx-identity-vram failed: ' + $_.Exception.Message)
    exit 1
}
