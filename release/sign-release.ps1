[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Prepare','AfterScripts','AfterCatalog')][string]$Phase,
    [Parameter(Mandatory)][string]$WorkDir,
    [string]$Version, [string]$UnsignedZip, [string]$ExpectedSha256,
    [string]$ExpectedOrganization = 'Bitworks LLC',
    [switch]$AllowUntrustedRootForTests
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$tree = Join-Path $WorkDir 'tree'
$catalog = Join-Path $WorkDir 'FastLLM.cat'
$maxFiles = 10000; $maxBytes = 512MB

function Assert-Signed([string]$path) {
    $sig = Get-AuthenticodeSignature -LiteralPath $path
    $ok = $sig.Status -eq 'Valid' -or ($AllowUntrustedRootForTests -and $sig.Status -eq 'UnknownError' -and $sig.SignerCertificate)
    if (-not $ok) { throw "signature not valid for ${path}: $($sig.Status) $($sig.StatusMessage)" }
    if ($sig.SignerCertificate.Subject -notmatch ('(^|, )O=' + [regex]::Escape($ExpectedOrganization) + '(,|$)')) { throw "unexpected signer for ${path}: $($sig.SignerCertificate.Subject)" }
    if (-not $sig.TimeStamperCertificate) { throw "no timestamp on ${path}" }
    return $sig
}

function Get-TreeFiles([string]$root) {
    # Paths start with $root exactly as given (Get-ChildItem may return long-form paths for 8.3 short roots).
    [IO.Directory]::EnumerateFiles($root, '*', [IO.SearchOption]::AllDirectories)
}
function Get-RelPath([string]$full, [string]$root) { $full.Substring($root.Length + 1) }

switch ($Phase) {
  'Prepare' {
    if ((Get-FileHash -LiteralPath $UnsignedZip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $ExpectedSha256.ToLowerInvariant()) { throw 'unsigned zip sha256 mismatch' }
    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    if (Test-Path $tree) { throw "work tree already exists: $tree" }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($UnsignedZip)
    try {
      if ($zip.Entries.Count -gt $maxFiles) { throw 'too many entries' }
      $seen = @{}; $total = 0
      foreach ($e in $zip.Entries) {
        $name = $e.FullName
        if ($name.EndsWith('/')) { continue }
        if ($name -match '(^[\\/])|(^[A-Za-z]:)|(\.\.[\\/])|([\\/]\.\.$)|\\') { throw "unsafe entry: $name" }
        $key = $name.ToLowerInvariant(); if ($seen.ContainsKey($key)) { throw "duplicate entry: $name" }; $seen[$key] = 1
        $total += $e.Length; if ($total -gt $maxBytes) { throw 'expanded size cap exceeded' }
        $dest = Join-Path $tree ($name -replace '/', '\')
        New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
        [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dest)
      }
    } finally { $zip.Dispose() }
    $release = Get-Content -LiteralPath (Join-Path $tree 'RELEASE.json') -Raw | ConvertFrom-Json
    if ($release.schema -ne 'bitworks.fastllm-release/v1' -or $release.component -ne 'fastllm-lab') { throw 'RELEASE.json schema/component' }
    if ($release.version -ne $Version) { throw "RELEASE.json version $($release.version) != $Version" }
    if (Test-Path (Join-Path $tree 'FastLLM.cat')) { throw 'unsigned package already contains FastLLM.cat' }
    $sign = @(Get-TreeFiles $tree | Where-Object {
        $rel = Get-RelPath $_ $tree
        [IO.Path]::GetExtension($_) -in '.ps1','.psm1','.psd1' -and ($rel -notmatch '\\' -or $rel -match '^(src|tools)\\') })
    if ($sign.Count -eq 0) { throw 'no scripts selected for signing' }
    $sign | Set-Content -LiteralPath (Join-Path $WorkDir 'sign-list.txt') -Encoding ascii
    Write-Host "prepared $($sign.Count) scripts to sign"
  }
  'AfterScripts' {
    $list = Get-Content -LiteralPath (Join-Path $WorkDir 'sign-list.txt')
    foreach ($f in $list) { Assert-Signed $f | Out-Null }
    & python (Join-Path $here 'release_json.py') regen-manifest $tree | Out-Null; if ($LASTEXITCODE) { throw 'regen-manifest failed' }
    & python (Join-Path $here 'release_json.py') update-release $tree; if ($LASTEXITCODE) { throw 'update-release failed' }
    if (Test-Path $catalog) { throw 'catalog already exists' }
    New-FileCatalog -Path $tree -CatalogFilePath $catalog -CatalogVersion 2 | Out-Null
    Write-Host "signed scripts verified: $($list.Count); catalog created"
  }
  'AfterCatalog' {
    $catSig = Assert-Signed $catalog
    Move-Item -LiteralPath $catalog -Destination (Join-Path $tree 'FastLLM.cat')
    $check = Test-FileCatalog -CatalogFilePath (Join-Path $tree 'FastLLM.cat') -Path $tree -FilesToSkip 'FastLLM.cat' -Detailed
    $catKeys = @($check.CatalogItems.Keys | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object)
    $pathKeys = @($check.PathItems.Keys | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object)
    if ($check.Status -ne 'Valid' -or (Compare-Object $catKeys $pathKeys)) { throw "catalog does not match the tree exactly: $($check.Status)" }
    $release = Get-Content -LiteralPath (Join-Path $tree 'RELEASE.json') -Raw | ConvertFrom-Json
    if ($release.version -ne $Version) { throw 'version changed' }
    $out = Join-Path $WorkDir 'out'; New-Item -ItemType Directory -Force -Path $out | Out-Null
    $zipPath = Join-Path $out 'package.zip'
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $stamp = [DateTimeOffset]::Parse($release.builtAtUtc).UtcDateTime
    $fs = [IO.File]::Open($zipPath, 'CreateNew')
    try {
      $archive = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
      try {
        Get-TreeFiles $tree | Sort-Object { (Get-RelPath $_ $tree).Replace('\','/') } -CaseSensitive | ForEach-Object {
          $name = (Get-RelPath $_ $tree).Replace('\','/')
          $entry = $archive.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal); $entry.LastWriteTime = $stamp
          $src = [IO.File]::OpenRead($_); $dst = $entry.Open()
          try { $src.CopyTo($dst) } finally { $dst.Dispose(); $src.Dispose() } }
      } finally { $archive.Dispose() }
    } finally { $fs.Dispose() }
    & python (Join-Path $here 'release_json.py') write-offer $tree $zipPath (Join-Path $out 'OFFER.json'); if ($LASTEXITCODE) { throw 'write-offer failed' }
    $sha = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath (Join-Path $out 'package.sha256') -Value $sha -Encoding ascii
    if ((Get-Item $zipPath).Length -gt 64MB) { throw 'package exceeds the 64 MiB agent limit' }
    $signed = Get-Content -LiteralPath (Join-Path $WorkDir 'sign-list.txt') | ForEach-Object {
      $s = Get-AuthenticodeSignature -LiteralPath $_
      [ordered]@{ path = (Get-RelPath $_ $tree).Replace('\','/'); subject = $s.SignerCertificate.Subject; timestamp = [string]$s.TimeStamperCertificate.Subject } }
    $ekus = @($catSig.SignerCertificate.Extensions | Where-Object { $_ -is [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] } | ForEach-Object { $_.EnhancedKeyUsages } | ForEach-Object { $_.Value })
    [ordered]@{ version = $Version; packageSha256 = $sha; catalogSubject = $catSig.SignerCertificate.Subject; catalogEkus = $ekus; scripts = @($signed) } |
      ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $out 'signing-report.json') -Encoding utf8
    Write-Host "package.zip sha256=$sha"
  }
}
