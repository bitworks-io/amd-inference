#requires -Version 5.1
# Build mode (default): compiles the installer with the pinned Inno Setup.
# -InstallTools: installs Inno Setup (vendor installer) and, with -WithSigningModule, the ArtifactSigning module, each
# verified against installer/tool-pins.json; any mismatch or null pin throws. Release jobs run it BEFORE azure/login.
[CmdletBinding(DefaultParameterSetName = 'Build')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Install')][switch]$InstallTools,
    [Parameter(ParameterSetName = 'Install')][switch]$WithSigningModule,
    [Parameter(Mandatory, ParameterSetName = 'Build')][string]$Version,
    [Parameter(Mandatory, ParameterSetName = 'Build')][string]$SourceDir,
    [Parameter(Mandatory, ParameterSetName = 'Build')][string]$OutputDir,
    [Parameter(ParameterSetName = 'Build')][string]$SignScript
)
$ErrorActionPreference = 'Stop'
$pinsPath = Join-Path $PSScriptRoot 'tool-pins.json'

function Get-Pins {
    $pins = Get-Content -LiteralPath $pinsPath -Raw | ConvertFrom-Json
    foreach ($pair in @(@('inno', 'installerSha256'), @('inno', 'signerCommonName'), @('inno', 'installerUrl'), @('artifactSigningModule', 'packageSha512Base64'), @('artifactSigningModule', 'packageUrl'))) {
        if (-not $pins.($pair[0]).($pair[1])) { throw "tool-pins.json: $($pair[0]).$($pair[1]) is not pinned (null); refusing to install unpinned code" }
    }
    $pins
}

function Assert-Signer([string]$Path, [string]$CommonName) {
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    if ($sig.Status -ne 'Valid') { throw "${Path}: Authenticode status is $($sig.Status), want Valid" }
    if ($sig.SignerCertificate.Subject -notmatch ('(^|, )CN=' + [regex]::Escape($CommonName) + '(,|$)')) {
        throw "${Path}: signer is '$($sig.SignerCertificate.Subject)', want CN=$CommonName"
    }
}

function Install-Tools([bool]$WithModule) {
    $pins = Get-Pins
    $dl = Join-Path ([IO.Path]::GetTempPath()) ('fastllm-tools-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $dl | Out-Null
    $setup = Join-Path $dl 'innosetup.exe'
    Invoke-WebRequest -Uri $pins.inno.installerUrl -OutFile $setup -UseBasicParsing
    $got = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash
    if ($got -ne $pins.inno.installerSha256.ToUpperInvariant()) { throw "Inno installer SHA-256 mismatch: got $got, pinned $($pins.inno.installerSha256)" }
    Assert-Signer $setup $pins.inno.signerCommonName
    $p = Start-Process -FilePath $setup -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-' -Wait -PassThru
    if ($p.ExitCode) { throw "Inno installer failed: $($p.ExitCode)" }
    $installed = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
    Assert-Signer $installed $pins.inno.signerCommonName
    if (-not (Get-Item -LiteralPath $installed).VersionInfo.FileVersion.StartsWith($pins.inno.version)) { throw "ISCC.exe version is not $($pins.inno.version)" }
    Write-Host "Inno Setup $($pins.inno.version) installed and verified"
    if ($WithModule) {
        $nupkg = Join-Path $dl 'ArtifactSigning.nupkg'
        Invoke-WebRequest -Uri $pins.artifactSigningModule.packageUrl -OutFile $nupkg -UseBasicParsing
        $sha = [System.Security.Cryptography.SHA512]::Create()
        $hash = [Convert]::ToBase64String($sha.ComputeHash([IO.File]::ReadAllBytes($nupkg)))
        if ($hash -ne $pins.artifactSigningModule.packageSha512Base64) { throw "ArtifactSigning nupkg SHA-512 mismatch: got $hash" }
        $modRoot = Join-Path ([Environment]::GetFolderPath('MyDocuments')) ('PowerShell\Modules\ArtifactSigning\' + $pins.artifactSigningModule.version)
        New-Item -ItemType Directory -Force -Path $modRoot | Out-Null
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($nupkg, $modRoot)
        Write-Host "ArtifactSigning $($pins.artifactSigningModule.version) installed from the verified package"
    }
}

if ($PSCmdlet.ParameterSetName -eq 'Install') { Install-Tools $WithSigningModule.IsPresent; return }
if ($Version -notmatch '^\d{4}\.\d{2}\.\d{2}\.[1-9]\d{0,3}$') { throw "bad version: $Version" }
$iscc = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
if (-not (Test-Path -LiteralPath $iscc)) { throw "ISCC not found at $iscc (run -InstallTools)" }
$pins = Get-Pins
Assert-Signer $iscc $pins.inno.signerCommonName
$source = (Resolve-Path -LiteralPath $SourceDir).Path
if (-not (Test-Path -LiteralPath (Join-Path $source 'LICENSE'))) { throw 'SourceDir has no LICENSE: not a FastLLM package tree' }
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$isccArgs = @("/DAppVersion=$Version", "/DSourceDir=$source", "/DOutputDir=$((Resolve-Path -LiteralPath $OutputDir).Path)")
if ($SignScript) {
    $script = (Resolve-Path -LiteralPath $SignScript).Path
    # Inno replaces $q with a double quote and $f with the quoted file path to sign.
    $isccArgs += ('/Sartifactsign=pwsh.exe -NoProfile -ExecutionPolicy RemoteSigned -File $q' + $script + '$q -Path $f')
    $isccArgs += '/DSignToolName=artifactsign'
}
$isccArgs += (Join-Path $PSScriptRoot 'FastLLM.iss')
& $iscc @isccArgs | Out-Host
if ($LASTEXITCODE) { throw "ISCC failed with exit code $LASTEXITCODE" }
$setup = Join-Path $OutputDir "FastLLM-Setup-$Version.exe"
if (-not (Test-Path -LiteralPath $setup)) { throw "installer not produced: $setup" }
Write-Host "built $setup"
