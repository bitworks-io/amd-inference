#requires -Version 7
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AssetsDir, [Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$Tag,
    [Parameter(Mandatory)][string]$FixtureHardware, [Parameter(Mandatory)][string]$ReportPath
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ReleaseVerify.psm1') -Force
$report = [ordered]@{ version = $Version; tag = $Tag; checks = [ordered]@{} }
function Pass([string]$Name, $Detail = $true) { $report.checks[$Name] = $Detail; Write-Host "PASS $Name" }
try {
    $channel = Resolve-FastLlmReleaseTag -Tag $Tag -Version $Version; Pass 'tag' $channel

    $expected = @("FastLLM-Setup-$Version.exe", "fastllm-$Version.zip", "fastllm-$Version.offer.json", "fastllm-$Version.signing-report.json",
        "fastllm-$Version.cdx.json", 'THIRD_PARTY_NOTICES.md') | Sort-Object
    $sums = Read-FastLlmSha256Sums -Path (Join-Path $AssetsDir 'SHA256SUMS')
    if (Compare-Object $expected @($sums.Keys | Sort-Object)) { throw "SHA256SUMS lists $(@($sums.Keys) -join ', ')" }
    $present = @(Get-ChildItem -LiteralPath $AssetsDir -File | Where-Object Name -ne 'SHA256SUMS' | ForEach-Object Name | Sort-Object)
    if (Compare-Object $expected $present) { throw "assets present: $($present -join ', ')" }
    foreach ($name in $expected) {
        if ((Get-FileHash -LiteralPath (Join-Path $AssetsDir $name) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sums[$name]) { throw "hash mismatch: $name" }
    }
    Pass 'sha256sums'

    $setup = Join-Path $AssetsDir "FastLLM-Setup-$Version.exe"
    Test-FastLlmReleaseSignature -Path $setup | Out-Null; Pass 'setup-signature'
    $productVersion = (Get-Item -LiteralPath $setup).VersionInfo.ProductVersion
    if ($productVersion -ne $Version) { throw "installer ProductVersion $productVersion != $Version" }
    Pass 'setup-product-version'

    $pkg = Join-Path ([IO.Path]::GetTempPath()) ('fastllm-verify-' + [guid]::NewGuid().ToString('N'))
    Expand-Archive -LiteralPath (Join-Path $AssetsDir "fastllm-$Version.zip") -DestinationPath $pkg
    $release = Get-Content -LiteralPath (Join-Path $pkg 'RELEASE.json') -Raw | ConvertFrom-Json
    if ($release.version -ne $Version -or $release.channel -ne $channel) { throw "RELEASE.json says $($release.version)/$($release.channel)" }
    Test-FastLlmReleaseSignature -Path (Join-Path $pkg 'FastLLM.cat') | Out-Null
    Test-FastLlmCatalogTree -CatalogPath (Join-Path $pkg 'FastLLM.cat') -TreePath $pkg
    $scripts = @(Get-ChildItem -LiteralPath $pkg -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' } |
        Where-Object { $rel = $_.FullName.Substring($pkg.Length + 1); $rel -notmatch '\\' -or $rel -match '^(src|tools)\\' })
    foreach ($s in $scripts) { Test-FastLlmReleaseSignature -Path $s.FullName | Out-Null }
    Pass 'package' @{ scripts = $scripts.Count }

    $sbom = Get-Content -LiteralPath (Join-Path $AssetsDir "fastllm-$Version.cdx.json") -Raw | ConvertFrom-Json
    if ($sbom.bomFormat -ne 'CycloneDX') { throw 'SBOM is not CycloneDX' }
    if ((Get-Content -LiteralPath (Join-Path $AssetsDir "fastllm-$Version.cdx.json") -Raw) -notmatch '"Apache-2\.0"') { throw 'SBOM does not declare FastLLM Apache-2.0' }
    Pass 'sbom'

    $app = Join-Path $env:LOCALAPPDATA 'Programs\Bitworks FastLLM'
    $data = Join-Path $env:LOCALAPPDATA 'Bitworks\FastLLM'
    New-Item -ItemType Directory -Force -Path $data | Out-Null
    $marker = Join-Path $data 'verify-marker.txt'; Set-Content -LiteralPath $marker -Value 'keep' -Encoding ascii
    $p = Start-Process -FilePath $setup -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/CURRENTUSER', '/NORESTART' -Wait -PassThru
    if ($p.ExitCode) { throw "silent install exited $($p.ExitCode)" }
    Test-FastLlmReleaseSignature -Path (Join-Path $app '_uninstall\unins000.exe') | Out-Null; Pass 'uninstaller-signature'
    Test-FastLlmCatalogTree -CatalogPath (Join-Path $app 'FastLLM.cat') -TreePath $app -SkipNames 'unins000.exe', 'unins000.dat', 'unins000.msg' -SkipPrefixes '_uninstall\'
    Pass 'installed-catalog'

    $planOut = & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File (Join-Path $app 'fast-llm.ps1') plan -HardwareFile $FixtureHardware -AsJson
    if ($LASTEXITCODE) { throw "offline plan exited $LASTEXITCODE" }
    $null = ($planOut -join "`n") | ConvertFrom-Json
    Pass 'offline-plan'

    $p = Start-Process -FilePath (Join-Path $app '_uninstall\unins000.exe') -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait -PassThru
    if ($p.ExitCode) { throw "silent uninstall exited $($p.ExitCode)" }
    $deadline = (Get-Date).AddSeconds(60)
    while ((Test-Path -LiteralPath (Join-Path $app 'fast-llm.ps1')) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    if (Test-Path -LiteralPath (Join-Path $app 'fast-llm.ps1')) { throw 'app files remain after uninstall' }
    if (-not (Test-Path -LiteralPath $marker)) { throw 'uninstall removed user data' }
    Pass 'uninstall-keeps-data'
    $report.result = 'pass'
} catch {
    $report.result = 'fail'; $report.error = $_.Exception.Message
    throw
} finally {
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ReportPath -Encoding utf8
}
