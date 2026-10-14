Set-StrictMode -Version 2
$script:DefaultRoot = 'F40042E2E5F7E8EF8189FED15519AECE42C3BFA2'
$script:DefaultEkus = @('1.3.6.1.4.1.311.97.1.0', '1.3.6.1.4.1.311.97.990689314.800187930.133508941.234438932')
$script:TolerableChainStatus = @('NoError', 'NotTimeValid', 'NotTimeNested')

function Test-FastLlmReleaseSignature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ExpectedOrganization = 'Bitworks LLC',
        [string]$ExpectedRootThumbprint = $script:DefaultRoot,
        [string[]]$RequiredEkus = $script:DefaultEkus,
        [switch]$AllowUntrustedRootForTests
    )
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    $statusOk = $sig.Status -eq 'Valid' -or ($AllowUntrustedRootForTests -and $sig.Status -eq 'UnknownError' -and $sig.SignerCertificate)
    if (-not $statusOk) { throw "signature not valid for ${Path}: $($sig.Status)" }
    $leaf = $sig.SignerCertificate
    if ($leaf.Subject -notmatch ('(^|, )O=' + [regex]::Escape($ExpectedOrganization) + '(,|$)')) { throw "unexpected signer for ${Path}: $($leaf.Subject)" }
    if (-not $sig.TimeStamperCertificate) { throw "no timestamp on ${Path}" }
    $ekus = @($leaf.Extensions | Where-Object { $_ -is [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] } |
        ForEach-Object { $_.EnhancedKeyUsages } | ForEach-Object { $_.Value })
    foreach ($eku in $RequiredEkus) { if ($ekus -notcontains $eku) { throw "missing EKU $eku on ${Path}" } }
    $chain = New-Object Security.Cryptography.X509Certificates.X509Chain
    try {
        $chain.ChainPolicy.RevocationMode = [Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        if ($AllowUntrustedRootForTests) {
            $chain.ChainPolicy.VerificationFlags = [Security.Cryptography.X509Certificates.X509VerificationFlags]::AllowUnknownCertificateAuthority
        }
        [void]$chain.Build($leaf)
        $bad = @($chain.ChainStatus | Where-Object {
                $status = [string]$_.Status
                ($script:TolerableChainStatus -notcontains $status) -and -not ($AllowUntrustedRootForTests -and $status -eq 'UntrustedRoot') })
        if ($bad.Count) { throw "chain status not allowed for ${Path}: $(($bad | ForEach-Object { [string]$_.Status }) -join ',')" }
        $root = $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate
        if ($root.Thumbprint -ne $ExpectedRootThumbprint) { throw "unexpected root for ${Path}: $($root.Thumbprint)" }
    } finally { $chain.Dispose() }
    return $sig
}

function Read-FastLlmSha256Sums {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $sums = @{}
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line -eq '') { continue }
        if ($line -notmatch '^([0-9a-f]{64})  ([A-Za-z0-9._-]+)$') { throw "malformed SHA256SUMS line: $line" }
        if ($sums.ContainsKey($Matches[2])) { throw "duplicate SHA256SUMS entry: $($Matches[2])" }
        $sums[$Matches[2]] = $Matches[1]
    }
    return $sums
}

function Resolve-FastLlmReleaseTag {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Tag, [Parameter(Mandatory)][string]$Version)
    if ($Tag -notmatch '^v(\d{4}\.\d{2}\.\d{2}\.[1-9]\d{0,3})(-canary)?$') { throw "malformed release tag: $Tag" }
    if ($Matches[1] -ne $Version) { throw "tag $Tag does not carry version $Version" }
    if ($Matches[2]) { return 'canary' } else { return 'stable' }
}

function Test-FastLlmCatalogTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CatalogPath,
        [Parameter(Mandatory)][string]$TreePath,
        [string[]]$SkipNames = @(),
        [string[]]$SkipPrefixes = @()
    )
    $skip = @('FastLLM.cat') + $SkipNames
    $check = Test-FileCatalog -CatalogFilePath $CatalogPath -Path $TreePath -FilesToSkip $skip -Detailed
    $catKeys = @($check.CatalogItems.Keys | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object)
    $pathKeys = @($check.PathItems.Keys | ForEach-Object { $_.ToLowerInvariant() } | Where-Object {
            $key = $_; -not @($SkipPrefixes | Where-Object { $key.StartsWith($_.ToLowerInvariant()) }).Count } | Sort-Object)
    if ($check.Status -ne 'Valid' -or (Compare-Object $catKeys $pathKeys)) { throw "catalog does not match the tree exactly: $($check.Status)" }
}

function Get-FastLlmTreeHashList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TreePath,
        [string[]]$SkipNames = @(),
        [string[]]$SkipPrefixes = @()
    )
    $root = (Resolve-Path -LiteralPath $TreePath).ProviderPath.TrimEnd('\', '/')
    $lines = @(foreach ($f in Get-ChildItem -LiteralPath $root -Recurse -File -Force) {
        $rel = $f.FullName.Substring($root.Length + 1).Replace('/', '\').ToLowerInvariant()
        if (@($SkipNames | Where-Object { $f.Name -ieq $_ }).Count) { continue }
        if (@($SkipPrefixes | Where-Object { $rel.StartsWith($_.ToLowerInvariant().Replace('/', '\'), [StringComparison]::Ordinal) }).Count) { continue }
        $rel + '  ' + (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    })
    [Array]::Sort($lines, [StringComparer]::Ordinal)
    return $lines
}

function Test-FastLlmTreeMatchesPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackagePath,
        [Parameter(Mandatory)][string]$InstalledPath,
        [string[]]$SkipNames = @(),
        [string[]]$SkipPrefixes = @()
    )
    $want = @(Get-FastLlmTreeHashList -TreePath $PackagePath -SkipNames $SkipNames -SkipPrefixes $SkipPrefixes)
    $got = @(Get-FastLlmTreeHashList -TreePath $InstalledPath -SkipNames $SkipNames -SkipPrefixes $SkipPrefixes)
    $diff = @(Compare-Object -ReferenceObject $want -DifferenceObject $got)
    if ($diff.Count) {
        $detail = ($diff | Select-Object -First 10 | ForEach-Object { $(if ($_.SideIndicator -eq '<=') { 'package only' } else { 'installed only' }) + ': ' + $_.InputObject }) -join '; '
        throw "installed tree does not equal the signed package tree ($($diff.Count) differences): $detail"
    }
    return $want.Count
}

function Test-FastLlmFileHashEqual {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$ReferencePath)
    $a = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    $b = (Get-FileHash -LiteralPath $ReferencePath -Algorithm SHA256).Hash
    if ($a -ne $b) { throw "$Path (sha256 $a) differs from the package copy $ReferencePath (sha256 $b)" }
}

function Test-FastLlmPackageScriptsSigned {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackagePath,
        [hashtable]$SignatureArgs = @{}
    )
    $root = (Resolve-Path -LiteralPath $PackagePath).ProviderPath.TrimEnd('\', '/')
    $scripts = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force | Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' })
    foreach ($s in $scripts) { Test-FastLlmReleaseSignature -Path $s.FullName @SignatureArgs | Out-Null }
    return $scripts.Count
}

function ConvertTo-FastLlmVersionInfoText {
    [CmdletBinding()]
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    # Inno Setup patches the setup loader's version resource in place, so its strings come back padded with trailing spaces and NULs.
    return $Text.TrimEnd([char]' ', [char]0)
}

function Get-FastLlmInstallerProductVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return ConvertTo-FastLlmVersionInfoText ((Get-Item -LiteralPath $Path).VersionInfo.ProductVersion)
}

Export-ModuleMember -Function Test-FastLlmReleaseSignature, Read-FastLlmSha256Sums, Resolve-FastLlmReleaseTag, Test-FastLlmCatalogTree, ConvertTo-FastLlmVersionInfoText, Get-FastLlmInstallerProductVersion, Get-FastLlmTreeHashList, Test-FastLlmTreeMatchesPackage, Test-FastLlmFileHashEqual, Test-FastLlmPackageScriptsSigned
