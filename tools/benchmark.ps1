#requires -Version 5.1
[CmdletBinding()]
param([string]$InstallRoot=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Bitworks/FastLLM'),[Parameter(Mandatory=$true)][string]$OutputPath,[int[]]$PromptTokens=@(512,4096),[int]$GenerationTokens=128,[int]$Repetitions=5,
       # Optional ADLX identity and 1 Hz telemetry sidecar; both must be supplied together.
       [string]$AdlxExecutablePath,[string]$AdlxExecutableSha256,
       # Without either ADLX argument, an installed and verified ADLX probe component is used; this switch turns that lookup off.
       [switch]$NoAdlxProbe)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../src/FastLlm.psm1') -Force
$adlxArguments=@{}
$adlxDiscovered=$false
if($AdlxExecutablePath){$adlxArguments['AdlxExecutablePath']=$AdlxExecutablePath}
if($AdlxExecutableSha256){$adlxArguments['AdlxExecutableSha256']=$AdlxExecutableSha256}
# Explicit arguments always win and are never mixed with discovery. Only the installed, Full-verified probe component is used; nothing is downloaded.
if(-not $AdlxExecutablePath -and -not $AdlxExecutableSha256 -and -not $NoAdlxProbe){
    $adlxProbe=Get-FastLlmInstalledToolComponent -Id 'bitworks-adlx-probe' -InstallRoot $InstallRoot -ComponentsPath (Join-Path $PSScriptRoot '../config/components.json') -ExecutableName 'adlx-identity-vram.exe'
    if($adlxProbe){
        $adlxArguments['AdlxExecutablePath']=$adlxProbe.path
        $adlxArguments['AdlxExecutableSha256']=$adlxProbe.sha256
        $adlxDiscovered=$true
        Write-Host "Using the installed ADLX probe component $($adlxProbe.id) $($adlxProbe.version)."
    }
}
# Only a discovered probe is optional: if it cannot run here the benchmark continues without ADLX. Explicit arguments stay fail-closed.
if($adlxDiscovered){$adlxArguments['AdlxOptional']=$true}
try{
    Invoke-FastLlmBenchmark -InstallRoot $InstallRoot -OutputPath $OutputPath -PromptTokens $PromptTokens -GenerationTokens $GenerationTokens -Repetitions $Repetitions @adlxArguments | Out-Null
}catch{
    $benchmarkFailure=$_
    # A failed run writes <output stem>.failure.json beside the intended result (same stem rule as the producer); print where it is.
    $failureReport=$null
    try{
        $outputFull=[IO.Path]::GetFullPath($OutputPath)
        $failureReport=Join-Path ([IO.Path]::GetDirectoryName($outputFull)) ([IO.Path]::GetFileNameWithoutExtension($outputFull)+'.failure.json')
    }catch{}
    if($failureReport -and (Test-Path -LiteralPath $failureReport)){Write-Host "Benchmark failed. Failure report: $failureReport"}
    throw $benchmarkFailure
}
if($adlxDiscovered){
    try{
        $producedResult=Get-Content -LiteralPath $OutputPath -Raw|ConvertFrom-Json
        if($producedResult.binding.adlx.reason -eq 'optional-probe-failed'){Write-Host 'The installed ADLX probe could not run here; the result was measured without ADLX identity and telemetry.'}
    }catch{}
}
Write-Host "Saved $OutputPath. Results are measurements, not release approval. Keep other clients disconnected during the run."
