# Trust: the one home for the release signing pins, the pinned-signature check and the install-integrity check.
# Loaded by release/ReleaseVerify.psm1 and the entry scripts; deliberately not loaded by src/FastLlm.psm1.
$script:FastLlmTrustRootThumbprint = 'F40042E2E5F7E8EF8189FED15519AECE42C3BFA2'
$script:FastLlmTrustEkus = @('1.3.6.1.4.1.311.97.1.0', '1.3.6.1.4.1.311.97.990689314.800187930.133508941.234438932')
$script:FastLlmTrustOrganization = 'Bitworks LLC'
$script:FastLlmTrustTolerableChainStatus = @('NoError', 'NotTimeValid', 'NotTimeNested')

function ConvertTo-FastLlmVersionInfoText {
    [CmdletBinding()]
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    # Inno Setup patches the setup loader's version resource in place, so its strings come back padded with trailing spaces and NULs.
    return $Text.TrimEnd([char]' ', [char]0)
}

function Get-FastLlmFileProductVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return ConvertTo-FastLlmVersionInfoText ((Get-Item -LiteralPath $Path).VersionInfo.ProductVersion)
}

function Test-FastLlmPinnedSignatureData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SignerSubject,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RootThumbprint,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Ekus,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ChainStatuses,
        [Parameter(Mandatory)][bool]$HasTimestamp,
        # Overrides exist only so release/ReleaseVerify.psm1 can keep its test-signer parameters; the defaults are the pins.
        [string]$ExpectedOrganization = $script:FastLlmTrustOrganization,
        [string]$ExpectedRootThumbprint = $script:FastLlmTrustRootThumbprint,
        [string[]]$RequiredEkus = $script:FastLlmTrustEkus
    )
    $fail = { param([string]$Reason, [string]$Detail) [pscustomobject]@{ ok = $false; reason = $Reason; detail = $Detail } }
    if ($Status -ne 'Valid') { return (& $fail 'not-valid' $Status) }
    if ($SignerSubject -notmatch ('(^|, )O=' + [regex]::Escape($ExpectedOrganization) + '(,|$)')) { return (& $fail 'wrong-publisher' $SignerSubject) }
    if ($RootThumbprint -ne $ExpectedRootThumbprint) { return (& $fail 'wrong-root' $RootThumbprint) }
    foreach ($eku in $RequiredEkus) {
        if (@($Ekus) -notcontains $eku) { return (& $fail 'missing-eku' $eku) }
    }
    $badStatuses = @(foreach ($chainStatus in @($ChainStatuses)) {
            if ($chainStatus -eq 'NoError') { continue }
            if ($HasTimestamp -and ($chainStatus -eq 'NotTimeValid' -or $chainStatus -eq 'NotTimeNested')) { continue }
            $chainStatus
        })
    if ($badStatuses.Count) { return (& $fail 'bad-chain-status' ($badStatuses -join ',')) }
    return [pscustomobject]@{ ok = $true; reason = $null; detail = $null }
}

function Test-FastLlmPinnedSignature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        # Overrides and the untrusted-root switch exist only for release/ReleaseVerify.psm1 and its tests; the defaults are the pins.
        [string]$ExpectedOrganization = $script:FastLlmTrustOrganization,
        [string]$ExpectedRootThumbprint = $script:FastLlmTrustRootThumbprint,
        [string[]]$RequiredEkus = $script:FastLlmTrustEkus,
        [switch]$AllowUntrustedRootForTests
    )
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    $statusOk = $sig.Status -eq 'Valid' -or ($AllowUntrustedRootForTests -and $sig.Status -eq 'UnknownError' -and $sig.SignerCertificate)
    $dataArgs = @{
        Status = $(if ($statusOk) { 'Valid' } else { [string]$sig.Status })
        SignerSubject = ''
        RootThumbprint = ''
        Ekus = @()
        ChainStatuses = @()
        HasTimestamp = [bool]$sig.TimeStamperCertificate
        ExpectedOrganization = $ExpectedOrganization
        ExpectedRootThumbprint = $ExpectedRootThumbprint
        RequiredEkus = $RequiredEkus
    }
    if ($statusOk) {
        $leaf = $sig.SignerCertificate
        $dataArgs.SignerSubject = [string]$leaf.Subject
        $dataArgs.Ekus = @($leaf.Extensions | Where-Object { $_ -is [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] } |
            ForEach-Object { $_.EnhancedKeyUsages } | ForEach-Object { $_.Value })
        $chain = New-Object Security.Cryptography.X509Certificates.X509Chain
        try {
            $chain.ChainPolicy.RevocationMode = [Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
            if ($AllowUntrustedRootForTests) {
                $chain.ChainPolicy.VerificationFlags = [Security.Cryptography.X509Certificates.X509VerificationFlags]::AllowUnknownCertificateAuthority
            }
            [void]$chain.Build($leaf)
            $dataArgs.ChainStatuses = @($chain.ChainStatus | ForEach-Object { [string]$_.Status } |
                Where-Object { -not ($AllowUntrustedRootForTests -and $_ -eq 'UntrustedRoot') })
            $dataArgs.RootThumbprint = [string]$chain.ChainElements[$chain.ChainElements.Count - 1].Certificate.Thumbprint
        } finally { $chain.Dispose() }
    }
    $result = Test-FastLlmPinnedSignatureData @dataArgs
    $result | Add-Member -NotePropertyName signature -NotePropertyValue $sig
    return $result
}

function Test-FastLlmInstallIntegrity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        # test seam: the signature path is covered by Test-FastLlmPinnedSignatureData and the release verify job
        [switch]$SkipSignatureForTest
    )
    $catalogPath = Join-Path $AppRoot 'FastLLM.cat'
    if (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) {
        return [pscustomobject]@{ status = 'not-installed'; reason = 'no-catalog'; catalogSignature = $null; mismatches = @() }
    }
    if ($SkipSignatureForTest) {
        $catalogSignature = [pscustomobject]@{ ok = $false; reason = 'skipped-for-test' }
    } else {
        $catalogSignature = Test-FastLlmPinnedSignature -Path $catalogPath
        if (-not $catalogSignature.ok) {
            return [pscustomobject]@{ status = 'failed'; reason = 'catalog-signature'; catalogSignature = $catalogSignature; mismatches = @() }
        }
    }
    $skipFiles = @('FastLLM.cat', 'unins000.exe', 'unins000.dat', 'unins000.msg')
    $check = Test-FileCatalog -CatalogFilePath $catalogPath -Path $AppRoot -FilesToSkip $skipFiles -Detailed
    $uninstallPrefix = '_uninstall\'
    $catItems = @{}
    foreach ($k in @($check.CatalogItems.Keys)) { $catItems[([string]$k).ToLowerInvariant()] = [string]$check.CatalogItems[$k] }
    $pathItems = @{}
    foreach ($k in @($check.PathItems.Keys)) { $pathItems[([string]$k).ToLowerInvariant()] = [string]$check.PathItems[$k] }
    $allKeys = @($catItems.Keys) + @($pathItems.Keys) | Sort-Object -Unique
    $excludedCount = 0
    $differing = @(foreach ($key in $allKeys) {
            if ($key.StartsWith($uninstallPrefix, [StringComparison]::Ordinal)) { $excludedCount++; continue }
            if (-not $catItems.ContainsKey($key) -or -not $pathItems.ContainsKey($key) -or $catItems[$key] -ne $pathItems[$key]) { $key }
        })
    if (-not $differing.Count -and $excludedCount -eq 0 -and [string]$check.Status -ne 'Valid') {
        $differing = @('catalog status: ' + [string]$check.Status)
    }
    if ($differing.Count) {
        return [pscustomobject]@{ status = 'failed'; reason = 'tree'; catalogSignature = $catalogSignature; mismatches = @($differing | Select-Object -First 20) }
    }
    return [pscustomobject]@{ status = 'ok'; reason = $null; catalogSignature = $catalogSignature; mismatches = @() }
}
