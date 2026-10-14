#requires -Version 5.1
[CmdletBinding()]
param([string]$InstallRoot=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Bitworks/FastLLM'),[Parameter(Mandatory=$true)][string]$OutputPath,[int[]]$PromptTokens=@(512,4096),[int]$GenerationTokens=128,[int]$Repetitions=5,
       # Optional ADLX identity and 1 Hz telemetry sidecar; both must be supplied together.
       [string]$AdlxExecutablePath,[string]$AdlxExecutableSha256)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../src/FastLlm.psm1') -Force
$adlxArguments=@{}
if($AdlxExecutablePath){$adlxArguments['AdlxExecutablePath']=$AdlxExecutablePath}
if($AdlxExecutableSha256){$adlxArguments['AdlxExecutableSha256']=$AdlxExecutableSha256}
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
Write-Host "Saved $OutputPath. Results are measurements, not release approval. Keep other clients disconnected during the run."
