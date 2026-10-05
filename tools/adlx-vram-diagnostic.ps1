# Private lab-only ADLX v2 VRAM diagnostic. Never part of the inference startup path.
param(
    [Parameter(Mandatory = $true)][string]$CollectorPath,
    [Parameter(Mandatory = $true)][string]$OutputPath
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) {
    throw 'ADLX telemetry requires standard-user, 64-bit Windows.'
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run the ADLX diagnostic as a standard user.'
}
if ([string]::IsNullOrWhiteSpace($OutputPath) -or -not [IO.Path]::IsPathRooted($OutputPath)) {
    throw 'OutputPath must be an absolute local file path.'
}
$reportPath = [IO.Path]::GetFullPath($OutputPath)
if ([IO.Path]::GetPathRoot($reportPath) -notmatch '^[A-Za-z]:\\$' -or
    [IO.Path]::GetExtension($reportPath) -ine '.json') {
    throw 'OutputPath must be a local-drive .json file.'
}
$reportParentPath = [IO.Path]::GetDirectoryName($reportPath)
$reportParent = Get-Item -LiteralPath $reportParentPath -ErrorAction Stop
if (-not $reportParent.PSIsContainer) { throw 'Output parent is not a directory.' }
$cursor = [IO.Path]::GetPathRoot($reportParentPath)
$segments = $reportParentPath.Substring($cursor.Length).Split([IO.Path]::DirectorySeparatorChar)
foreach ($segment in @('') + $segments) {
    if ($segment.Length -gt 0) { $cursor = Join-Path $cursor $segment }
    $pathPart = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
    if (($pathPart.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Output path traverses a reparse point.'
    }
}
if ([IO.File]::Exists($reportPath) -or [IO.Directory]::Exists($reportPath)) {
    throw 'OutputPath already exists; choose a fresh report filename.'
}
$wrapperSourceSha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()

$expectedCollectorSha256 = 'f21bcd16d6f73ed0587994016cf471310fdba014a5bbe6ed64079978441e78fb'
$collector = Get-Item -LiteralPath $CollectorPath -ErrorAction Stop
if ($collector.PSIsContainer -or (($collector.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
    throw 'Collector path is not a regular file.'
}
$collectorSha256 = (Get-FileHash -LiteralPath $collector.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
if ($collectorSha256 -ne $expectedCollectorSha256) { throw 'Private collector digest mismatch.' }

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
$dllSha256 = (Get-FileHash -LiteralPath $dll.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
$dllVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($dll.FullName).FileVersion
if ([string]::IsNullOrWhiteSpace($dllVersion)) { throw 'ADLX driver library has no file version.' }

$hostSource = Join-Path (Split-Path -Parent $PSScriptRoot) 'src/ProcessHost.cs'
if (-not (Test-Path -LiteralPath $hostSource -PathType Leaf)) { throw 'Bounded native process host source is unavailable.' }
if (-not ('Bitworks.FastLlm.ProcessHost' -as [type])) { Add-Type -Path $hostSource }

$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = $collector.FullName
$info.WorkingDirectory = [Environment]::SystemDirectory
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$hostProcess = New-Object Bitworks.FastLlm.ProcessHost
$startedUtc = [DateTime]::UtcNow.ToString('o')
$timer = [Diagnostics.Stopwatch]::StartNew()
$raw = $null
$exitCode = $null
try {
    $hostProcess.Start($info)
    while ($timer.ElapsedMilliseconds -lt 60000) {
        if ($hostProcess.Process.WaitForExit(100)) { break }
    }
    if (-not $hostProcess.Process.HasExited) { throw 'ADLX collector exceeded its 60-second deadline.' }
    $exitCode = $hostProcess.Process.ExitCode
    while (-not $hostProcess.OutputCompleted -and $timer.ElapsedMilliseconds -lt 60000) {
        Start-Sleep -Milliseconds 50
    }
    if (-not $hostProcess.OutputCompleted) { throw 'ADLX collector output did not complete before deadline.' }
    if ($hostProcess.OutputTruncated) { throw 'ADLX collector output exceeded its bound.' }
    $raw = $hostProcess.Snapshot()
} finally {
    $hostProcess.Dispose()
}
if ($exitCode -ne 0) { throw "ADLX collector failed with exit code $exitCode." }

$baseRows = @()
$vramRows = @()
foreach ($line in ($raw -split "`r?`n")) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    if ($line.Length -gt 4096 -or -not $line.StartsWith('{')) { throw 'Unexpected ADLX collector output.' }
    $row = $line | ConvertFrom-Json -ErrorAction Stop
    if ($row.qualification -ne $false -or $row.servingDeviceBound -ne $false -or
        $row.sample -lt 0 -or $row.sample -gt 9 -or $row.gpuIndex -lt 0 -or $row.gpuIndex -gt 7) {
        throw 'ADLX collector output schema mismatch.'
    }
    if ($row.schemaVersion -eq 1 -and $row.kind -eq 'adlx-gpu-sample') {
        $baseRows += $row
    } elseif ($row.schemaVersion -eq 2 -and $row.kind -eq 'adlx-vram-diagnostic-sample' -and
              $row.settingsProveEffectiveCap -eq $false) {
        $vramRows += $row
    } else {
        throw 'ADLX collector output kind mismatch.'
    }
}
if ($baseRows.Count -lt 10 -or $baseRows.Count -gt 80 -or $vramRows.Count -ne $baseRows.Count) {
    throw 'Incomplete paired ADLX sample set.'
}
foreach ($set in @($baseRows, $vramRows)) {
    $byGpu = @($set | Group-Object gpuIndex)
    foreach ($group in $byGpu) {
        if ($group.Count -ne 10) { throw 'Incomplete per-GPU ADLX sample set.' }
        $indices = @($group.Group | ForEach-Object { [int]$_.sample } | Sort-Object)
        for ($i = 0; $i -lt 10; $i++) { if ($indices[$i] -ne $i) { throw 'Duplicate or missing ADLX sample.' } }
    }
}
$baseKeys = @($baseRows | ForEach-Object { '{0}:{1}' -f $_.gpuIndex, $_.sample } | Sort-Object)
$vramKeys = @($vramRows | ForEach-Object { '{0}:{1}' -f $_.gpuIndex, $_.sample } | Sort-Object)
for ($i = 0; $i -lt $baseKeys.Count; $i++) {
    if ($baseKeys[$i] -ne $vramKeys[$i]) { throw 'ADLX base and VRAM samples are not paired.' }
}

$endedUtc = [DateTime]::UtcNow.ToString('o')
if ((Get-FileHash -LiteralPath $collector.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -ne $collectorSha256 -or
    (Get-FileHash -LiteralPath $dll.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -ne $dllSha256 -or
    (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $wrapperSourceSha256) {
    throw 'On-disk diagnostic inputs changed during sampling.'
}

$report = [ordered]@{
    schemaVersion = 2
    kind = 'adlx-private-vram-diagnostic'
    qualification = $false
    servingDeviceBound = $false
    startedUtc = $startedUtc
    endedUtc = $endedUtc
    wrapperSourceSha256 = $wrapperSourceSha256
    collectorSha256 = $collectorSha256
    adlxDriverVersion = $dllVersion
    adlxDriverSha256 = $dllSha256
    adlxDriverSigner = $signature.SignerCertificate.Subject
    baseSamples = $baseRows
    vramDiagnosticSamples = $vramRows
    observedClockIsConfiguredMaximum = $false
    settingsProveEffectiveCap = $false
}
$json = $report | ConvertTo-Json -Depth 8 -Compress
$utf8 = [Text.UTF8Encoding]::new($false)
$bytes = $utf8.GetBytes($json + "`n")
if ($bytes.Length -gt 262144) { throw 'ADLX report exceeds its 256 KiB bound.' }
$stream = $null
$created = $false
try {
    $stream = [IO.File]::Open($reportPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $created = $true
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
} catch {
    if ($null -ne $stream) { $stream.Dispose(); $stream = $null }
    if ($created) { [IO.File]::Delete($reportPath) }
    throw
} finally {
    if ($null -ne $stream) { $stream.Dispose() }
}
[pscustomobject]@{
    reportPath = $reportPath
    reportSha256 = (Get-FileHash -LiteralPath $reportPath -Algorithm SHA256).Hash.ToLowerInvariant()
    sampleCount = $vramRows.Count
    qualification = $false
}
