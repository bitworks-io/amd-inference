#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$SourceDir,
    [Parameter(Mandatory)][string]$OutputDir,
    [string]$SignScript
)
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d{4}\.\d{2}\.\d{2}\.[1-9]\d{0,3}$') { throw "bad version: $Version" }
$iscc = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
if (-not (Test-Path -LiteralPath $iscc)) { throw "ISCC not found at $iscc (install Inno Setup 6.7.3)" }
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
& $iscc @isccArgs
if ($LASTEXITCODE) { throw "ISCC failed with exit code $LASTEXITCODE" }
$setup = Join-Path $OutputDir "FastLLM-Setup-$Version.exe"
if (-not (Test-Path -LiteralPath $setup)) { throw "installer not produced: $setup" }
Write-Host "built $setup"
