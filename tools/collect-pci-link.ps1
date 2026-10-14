#requires -Version 5.1
# Read-only, standard-user PCIe link-state collector for present display adapters and their
# ancestors. SetupAPI/Configuration Manager device properties only: no CIM/WMI, no process
# start/stop, no admin. Link state is a point-in-time reading, not a statement about load.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutputPath,
    # Test seam: define the helper functions and return before any host guard or collection.
    [switch]$LibraryOnly
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Assert-PciLinkOutputPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) {
        throw 'OutputPath must be an absolute local file path.'
    }
    $full = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetExtension($full) -ine '.json') { throw 'OutputPath must be a .json file.' }
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
    if ([IO.File]::Exists($full) -or [IO.Directory]::Exists($full)) {
        throw 'OutputPath already exists; choose a fresh report filename.'
    }
    return $full
}

function Get-PciLinkFileSha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function New-PciLinkReport {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Devices,
        [Parameter(Mandatory = $true)][string]$HostName,
        [Parameter(Mandatory = $true)][string]$Account,
        [Parameter(Mandatory = $true)][hashtable]$SourceSha256,
        [datetime]$Now = ([datetime]::UtcNow)
    )
    return [ordered]@{
        schema        = 'fastllm.pci-link.v1'
        recordedAtUtc = $Now.ToUniversalTime().ToString('o')
        hostName      = $HostName
        account       = $Account
        collector     = [ordered]@{ sourceSha256 = $SourceSha256 }
        deviceCount   = @($Devices).Count
        devices       = @($Devices)
        note          = 'Point-in-time link properties per device level. Each level is reported separately; no slot-link or CPU-vs-chipset attachment is inferred. ASPM may downshift idle links.'
    }
}

function Write-PciLinkReport {
    param([Parameter(Mandatory = $true)]$Report, [Parameter(Mandatory = $true)][string]$Path)
    $full = Assert-PciLinkOutputPath -Path $Path
    $json = ConvertTo-Json -InputObject $Report -Depth 12
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json)
    # CreateNew refuses to overwrite even if the file appears after the check above.
    $stream = [IO.File]::Open($full, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    return $full
}

if ($LibraryOnly) { return }

try {
    if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) {
        throw 'PCI link collector requires 64-bit Windows.'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run the PCI link collector as a standard user.'
    }
    # Validate the destination first so a bad path fails before any collection.
    $null = Assert-PciLinkOutputPath -Path $OutputPath
    $repo = Split-Path $PSScriptRoot -Parent
    $source = Join-Path $repo 'src/WindowsPciLink.cs'
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw 'src/WindowsPciLink.cs is unavailable.' }
    $hashes = @{
        'src/WindowsPciLink.cs'    = Get-PciLinkFileSha256 -Path $source
        'tools/collect-pci-link.ps1' = Get-PciLinkFileSha256 -Path $PSCommandPath
    }
    if (-not ('Bitworks.FastLlm.WindowsPciLink' -as [type])) { Add-Type -Path $source -ErrorAction Stop }
    $devices = @([Bitworks.FastLlm.WindowsPciLink]::Collect())
    $report = New-PciLinkReport -Devices $devices -HostName ([Environment]::MachineName) `
        -Account $identity.Name -SourceSha256 $hashes
    $written = Write-PciLinkReport -Report $report -Path $OutputPath
    Write-Host ('Saved PCI link report: {0} ({1} display device(s)). No qualification implied.' -f $written, $devices.Count)
}
catch {
    [Console]::Error.WriteLine('collect-pci-link failed: ' + $_.Exception.Message)
    exit 1
}
