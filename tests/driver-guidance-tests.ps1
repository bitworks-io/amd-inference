#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'src/FastLlm.DriverGuidance.ps1')

$script:checks = 0
function Check([bool]$condition, [string]$message) {
    if (-not $condition) { throw "FAIL: $message" }
    $script:checks++
    Write-Host "PASS: $message"
}
function Expect-Invalid([object]$data, [string]$message) {
    $path = Join-Path ([IO.Path]::GetTempPath()) ('fastllm-driver-guidance-test-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $writer = New-Object IO.StreamWriter($stream, (New-Object Text.UTF8Encoding($false)))
            try { $writer.Write(($data | ConvertTo-Json -Depth 10)) }
            finally { $writer.Dispose() }
        }
        finally { $stream.Dispose() }
        $failed = $false
        try { Import-FastLlmDriverGuidanceCatalog -Path $path | Out-Null }
        catch { $failed = $true }
        Check $failed $message
    }
    finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
}

$catalog = Import-FastLlmDriverGuidanceCatalog
Check ($catalog.models.Count -eq 7 -and $catalog.automaticDriverInstall -eq $false) 'dated guidance catalog has seven focus models and cannot auto-install'

$expect = @{
    'AMD Radeon RX 7900 XTX' = 'rx-7900-xtx'
    'Radeon RX 7900 XT' = 'rx-7900-xt'
    'AMD Radeon RX 7800 XT' = 'rx-7800-xt'
    'Radeon RX 9070 XT' = 'rx-9070-xt'
    'AMD Radeon RX 9070' = 'rx-9070'
    'Radeon RX 9060 XT' = 'rx-9060-xt'
    'AMD Radeon AI PRO R9700' = 'ai-pro-r9700'
}
foreach ($name in $expect.Keys) {
    $result = Get-FastLlmDriverGuidance -GpuName $name
    Check ($result.knownFocusModel -and $result.modelId -eq $expect[$name] -and
        $result.modelAssessment -eq 'exact-catalog-name-only-not-hardware-verified' -and
        -not $result.qualification -and -not $result.automaticDriverInstall -and
        -not $result.hasOwnTrustedMapping -and $result.productUrl -like 'https://www.amd.com/*') "exact catalog lookup: $name"
}

$xtx = Get-FastLlmDriverGuidance -GpuName 'AMD Radeon(TM) RX 7900 XTX' -PnpDriverVersion '32.0.31041.1004'
Check ($xtx.modelId -eq 'rx-7900-xtx' -and $xtx.reportedPnpDriverVersion -eq '32.0.31041.1004' -and
    $xtx.driverVersionAssessment -eq 'unknown-unmatched-pnp-to-serving-adapter' -and
    -not $xtx.hasOwnTrustedMapping) 'a matching package version is never joined to the serving GPU by name'
Check ($xtx.recommended.name -eq 'Adrenalin 26.8.1' -and $xtx.optional.name -eq 'Adrenalin 26.9.2' -and
    $xtx.suggestedInstallMode -eq 'Minimal') 'desktop defaults to Minimal and exposes distinct recommended/optional packages'

$dedicated = Get-FastLlmDriverGuidance -GpuName 'Radeon RX 7900 XTX' -DeploymentType dedicated-inference
Check ($dedicated.suggestedInstallMode -eq 'DriverOnly' -and $dedicated.installModeReason -match 'no TPS benefit') 'dedicated host defaults to Driver Only without throughput claim'
$chosen = Get-FastLlmDriverGuidance -GpuName 'Radeon RX 7900 XTX' -DeploymentType desktop -UserInstallModeChoice DriverOnly
Check ($chosen.suggestedInstallMode -eq 'DriverOnly' -and $chosen.installModeReason -match 'Explicit operator choice') 'explicit install-mode choice overrides desktop default'

$pro = Get-FastLlmDriverGuidance -GpuName 'AMD Radeon AI PRO R9700' -DeploymentType dedicated-inference
Check ($pro.installerFamily -eq 'pro' -and $pro.recommended.name -eq 'PRO Edition 26.Q3' -and
    $null -eq $pro.optional -and $pro.suggestedInstallMode -eq 'installer-dependent') 'R9700 PRO package is separate from Adrenalin mode policy'

$unknown = Get-FastLlmDriverGuidance -GpuName 'AMD Radeon RX 7900 XTX Experimental' -PnpDriverVersion '32.0.31041.1004'
Check (-not $unknown.knownFocusModel -and $unknown.modelAssessment -eq 'unknown-unmatched-focus-model' -and
    $null -eq $unknown.productUrl -and $null -eq $unknown.recommended -and
    $unknown.driverVersionAssessment -eq 'unknown-unmatched-pnp-to-serving-adapter' -and
    $unknown.suggestedInstallMode -eq 'unknown') 'unmatched name remains unknown without a guessed product URL or install mode'

$badDate = $catalog | ConvertTo-Json -Depth 10 | ConvertFrom-Json
$badDate.asOf = '2026-02-30'
Expect-Invalid $badDate 'invalid calendar date is rejected'
$badUrl = $catalog | ConvertTo-Json -Depth 10 | ConvertFrom-Json
$badUrl.models[0].productUrl = 'https://www.amd.com.evil.test/en/support/download'
Expect-Invalid $badUrl 'lookalike vendor domain is rejected'
$badScheme = $catalog | ConvertTo-Json -Depth 10 | ConvertFrom-Json
$badScheme.models[0].recommended.notesUrl = 'http://www.amd.com/en/resources/support-articles/release-notes/no.html'
Expect-Invalid $badScheme 'non-HTTPS URL is rejected'
$collision = $catalog | ConvertTo-Json -Depth 10 | ConvertFrom-Json
$collision.models[1].names[0] = $collision.models[0].names[0]
Expect-Invalid $collision 'ambiguous normalized alias is rejected'

$badQuery = $catalog | ConvertTo-Json -Depth 10 | ConvertFrom-Json
$badQuery.models[0].productUrl += '?download=1'
Expect-Invalid $badQuery 'official AMD URL with query string is rejected'

$oversizedPath = Join-Path ([IO.Path]::GetTempPath()) ('fastllm-driver-guidance-large-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    $stream = [IO.File]::Open($oversizedPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.SetLength(131073) }
    finally { $stream.Dispose() }
    $failed = $false
    try { Import-FastLlmDriverGuidanceCatalog -Path $oversizedPath | Out-Null }
    catch { $failed = $true }
    Check $failed 'guidance file above 128 KiB is rejected before parsing'
}
finally { Remove-Item -LiteralPath $oversizedPath -Force -ErrorAction SilentlyContinue }

$linkPath = Join-Path ([IO.Path]::GetTempPath()) ('fastllm-driver-guidance-link-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    $targetPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'config/driver-guidance.json'
    try { New-Item -ItemType SymbolicLink -Path $linkPath -Target $targetPath -ErrorAction Stop | Out-Null }
    catch { Write-Host 'SKIP: symbolic-link creation unavailable in this test environment' }
    if (Test-Path -LiteralPath $linkPath) {
        $failed = $false
        try { Import-FastLlmDriverGuidanceCatalog -Path $linkPath | Out-Null }
        catch { $failed = $true }
        Check $failed 'guidance reparse-point target is rejected'
    }
}
finally { Remove-Item -LiteralPath $linkPath -Force -ErrorAction SilentlyContinue }

$invalid = Get-FastLlmDriverGuidance -GpuName 'Radeon RX 7900 XTX' -PnpDriverVersion "32.0.31041.1004`nINJECTED"
Check ($null -eq $invalid.reportedPnpDriverVersion -and
    $invalid.driverVersionAssessment -eq 'unknown-invalid-pnp-version') 'control-text PnP version is not reflected'
$tooLong = Get-FastLlmDriverGuidance -GpuName 'Radeon RX 7900 XTX' -PnpDriverVersion '123456.0.0.0'
Check ($null -eq $tooLong.reportedPnpDriverVersion -and
    $tooLong.driverVersionAssessment -eq 'unknown-invalid-pnp-version') 'oversized numeric component is not reflected'

$inventory = [pscustomobject]@{
    pnpDisplayDevices = @(
        [pscustomobject]@{ Description = 'AMD Radeon RX 7900 XTX'; InstanceId = 'PCI\\VEN_1002&DEV_TEST1'; DriverVersion = '32.0.31041.1004' },
        [pscustomobject]@{ Description = 'AMD Radeon RX 7900 XT'; InstanceId = 'PCI\\VEN_1002&DEV_TEST2'; DriverVersion = "unsafe`nversion" }
    )
    dxgi = @([pscustomobject]@{ Name = 'AMD Radeon RX 9070 XT'; Luid = '0' })
    hardware = @([pscustomobject]@{ Name = 'AMD Radeon RX 9060 XT' })
}
$inventoryGuidance = @(Get-FastLlmInventoryDriverGuidance -WindowsInventory $inventory)
Check ($inventoryGuidance.Count -eq 2 -and $inventoryGuidance[0].modelId -eq 'rx-7900-xtx' -and
    $inventoryGuidance[1].modelId -eq 'rx-7900-xt' -and
    $inventoryGuidance[0].source -eq 'pnp-display-name-only' -and
    $inventoryGuidance[0].sourceInstanceId -eq 'PCI\\VEN_1002&DEV_TEST1' -and
    -not $inventoryGuidance[0].hasOwnTrustedMapping) 'inventory wrapper uses only PnP display names and preserves instance provenance'
Check ($null -eq $inventoryGuidance[1].reportedPnpDriverVersion -and
    $inventoryGuidance[1].driverVersionAssessment -eq 'unknown-invalid-pnp-version') 'inventory wrapper does not reflect invalid PnP driver version'
$none = @(Get-FastLlmInventoryDriverGuidance -WindowsInventory ([pscustomobject]@{ dxgi = @([pscustomobject]@{ Name = 'AMD Radeon RX 7900 XTX' }) }))
Check ($none.Count -eq 0) 'DXGI-only inventory cannot generate PnP driver guidance'

Write-Host "Driver guidance checks passed: $script:checks"
