#requires -Version 7
# Called by Inno Setup's SignTool during the compile, for the uninstaller and then for Setup.exe. Signs with Bitworks LLC
# through Azure Artifact Signing, using the Azure CLI login that azure/login created; never runs outside release.yml.
param([Parameter(Mandatory)][string]$Path)
$ErrorActionPreference = 'Stop'
foreach ($name in 'AZURE_ENDPOINT', 'AZURE_SIGNING_ACCOUNT', 'AZURE_SIGNING_CERTIFICATE') {
    if (-not [Environment]::GetEnvironmentVariable($name)) { throw "$name is not set" }
}
Import-Module ArtifactSigning -RequiredVersion 0.1.20
$params = @{
    Endpoint                           = $env:AZURE_ENDPOINT
    CodeSigningAccountName             = $env:AZURE_SIGNING_ACCOUNT
    CertificateProfileName             = $env:AZURE_SIGNING_CERTIFICATE
    Files                              = $Path
    FileDigest                         = 'SHA256'
    TimestampRfc3161                   = 'http://timestamp.acs.microsoft.com'
    TimestampDigest                    = 'SHA256'
    ExcludeEnvironmentCredential       = $true
    ExcludeManagedIdentityCredential   = $true
    ExcludeSharedTokenCacheCredential  = $true
    ExcludeVisualStudioCredential      = $true
    ExcludeVisualStudioCodeCredential  = $true
    ExcludeAzurePowerShellCredential   = $true
    ExcludeInteractiveBrowserCredential = $true
}
Invoke-ArtifactSigning @params
$sig = Get-AuthenticodeSignature -LiteralPath $Path
if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch '(^|, )O=Bitworks LLC(,|$)' -or -not $sig.TimeStamperCertificate) {
    throw "signing did not produce a valid, timestamped Bitworks LLC signature on $Path ($($sig.Status))"
}
