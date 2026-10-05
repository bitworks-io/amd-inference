# Isolated, read-only Windows standard-user probe. It does not install or change drivers.
$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'src/WindowsGpuIdentity.cs'
if (-not (Test-Path -LiteralPath $source)) {
    # Supports a copied diagnostic pair in a separate user-owned bench folder.
    $source = Join-Path $PSScriptRoot 'WindowsGpuIdentity.cs'
}
Add-Type -Path $source -ErrorAction Stop

if (-not $IsWindows -and $PSVersionTable.PSVersion.Major -ge 6) {
    try {
        [Bitworks.FastLlm.WindowsGpuIdentity]::ReadPnP() | Out-Null
        throw 'Non-Windows probe unexpectedly succeeded.'
    } catch {
        if ($_.Exception -isnot [System.PlatformNotSupportedException] -and $_.Exception.InnerException -isnot [System.PlatformNotSupportedException]) {
            throw
        }
        Write-Host 'GPU identity helper compiles and rejects non-Windows hosts.'
    }
    return
}

$records = @([Bitworks.FastLlm.WindowsGpuIdentity]::ReadPnP())
foreach ($record in $records) {
    if ([string]::IsNullOrWhiteSpace($record.InstanceId)) {
        throw 'A present display record lacks an instance ID.'
    }
}
Write-Host ('Present display-class PnP records: {0}' -f $records.Count)
$records | Select-Object InstanceId, Description, LocationInfo, DriverVersion, DriverProvider, DriverVersionError, LocationError | Format-List
Write-Host 'Records are not correlated to DXGI LUIDs; no per-adapter qualification is implied.'
