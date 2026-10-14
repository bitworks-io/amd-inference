[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$WorkDir, [Parameter(Mandatory)][string]$InstallerDir,
    [Parameter(Mandatory)][string]$UnsignedDir, [Parameter(Mandatory)][string]$NoticesPath, [Parameter(Mandatory)][string]$OutDir
)
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $OutDir) { throw "OutDir already exists: $OutDir" }
New-Item -ItemType Directory -Path $OutDir | Out-Null
$out = Join-Path $WorkDir 'out'
$pkgSha = (Get-Content -LiteralPath (Join-Path $out 'package.sha256') -Raw).Trim()
if ((Get-FileHash -LiteralPath (Join-Path $out 'package.zip') -Algorithm SHA256).Hash.ToLowerInvariant() -ne $pkgSha) { throw 'package.sha256 mismatch' }
$map = [ordered]@{
    (Join-Path $InstallerDir "FastLLM-Setup-$Version.exe") = "FastLLM-Setup-$Version.exe"
    (Join-Path $out 'package.zip')                         = "fastllm-$Version.zip"
    (Join-Path $out 'OFFER.json')                          = "fastllm-$Version.offer.json"
    (Join-Path $out 'signing-report.json')                 = "fastllm-$Version.signing-report.json"
    (Join-Path $UnsignedDir "fastllm-$Version.cdx.json")   = "fastllm-$Version.cdx.json"
    $NoticesPath                                           = 'THIRD_PARTY_NOTICES.md'
}
foreach ($source in $map.Keys) { Copy-Item -LiteralPath $source -Destination (Join-Path $OutDir $map[$source]) }
$lines = Get-ChildItem -LiteralPath $OutDir -File | Sort-Object Name -CaseSensitive | ForEach-Object {
    (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $_.Name }
[IO.File]::WriteAllText((Join-Path $OutDir 'SHA256SUMS'), (($lines -join "`n") + "`n"), [Text.Encoding]::ASCII)
Write-Host "collected $($map.Count) assets plus SHA256SUMS in $OutDir"
