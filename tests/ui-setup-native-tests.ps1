#requires -Version 5.1
# Read-only Windows setup-to-flow integration against an existing engine-only root.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string] $InstallRoot)

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
if($env:OS -ne 'Windows_NT'){
    Write-Output 'SKIP: native UI setup integration requires Windows PowerShell 5.1 on Windows.'
    exit 0
}
if($PSVersionTable.PSVersion.Major -ne 5){
    Write-Output 'SKIP: native UI setup integration targets Windows PowerShell 5.1.'
    exit 0
}
if(-not [Environment]::Is64BitProcess){throw 'Run native UI setup integration in 64-bit Windows PowerShell.'}
$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    throw 'Run native UI setup integration as a standard Windows user.'
}
if(-not [IO.Path]::IsPathRooted($InstallRoot)){throw '-InstallRoot must be an absolute existing engine-only root.'}
$InstallRoot=[IO.Path]::GetFullPath($InstallRoot)
$rootItem=Get-Item -LiteralPath $InstallRoot -Force -ErrorAction Stop
if(-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)){
    throw '-InstallRoot must be a real directory, not a reparse point.'
}
$repo=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $repo 'src/FastLlm.psm1') -Force -PassThru
. (Join-Path $repo 'src/FastLlm.UiFlow.ps1')
& $module {Initialize-FastLlmProcessHost}
$catalog=Get-FastLlmCatalog (Join-Path $repo 'config/catalog.json')
if(-not (Test-FastLlmEngineInstallation -InstallRoot $InstallRoot -EngineVersion ([string]$catalog.engine.version) -BackendKey vulkan -Asset $catalog.engine.assets.vulkan)){
    throw 'The supplied root does not have a complete verified Vulkan engine.'
}
if(Test-Path -LiteralPath (Join-Path $InstallRoot 'models')){throw 'The supplied root is not engine-only: models directory exists.'}
if(Test-Path -LiteralPath (Join-Path $InstallRoot 'consents')){throw 'The supplied root is not engine-only: consents directory exists.'}

$cli=Join-Path $repo 'fast-llm.ps1'
$checks=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:checks++}
function Invoke-Doctor([string]$Path,[string]$Label){
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=(Get-Process -Id $PID).Path
    $argv=@('-NoLogo','-NoProfile','-NonInteractive','-OutputFormat','Text','-File',$cli,'doctor','-InstallRoot',$Path)
    $info.Arguments=& $module {param($A) Join-FastLlmProcessArguments $A} $argv
    $info.WorkingDirectory=$repo
    $info.UseShellExecute=$false
    $info.CreateNoWindow=$true
    $child=New-Object Bitworks.FastLlm.ProcessHost
    $watch=[Diagnostics.Stopwatch]::StartNew()
    try{
        $child.Start($info)
        while(-not $child.Process.HasExited -and $watch.Elapsed.TotalSeconds -lt 90){[void]$child.Process.WaitForExit(100)}
        if(-not $child.Process.HasExited){throw "$Label doctor exceeded 90 seconds."}
        while(-not $child.OutputCompleted -and $watch.Elapsed.TotalSeconds -lt 90){Start-Sleep -Milliseconds 20}
        if(-not $child.OutputCompleted -or $child.OutputTruncated){throw "$Label doctor output was incomplete or truncated."}
        $output=$child.Snapshot()
        if([string]::IsNullOrWhiteSpace($output) -or $output.Length -gt 65536){throw "$Label doctor output exceeded its JSON bound."}
        try{$diagnostic=ConvertFrom-Json -InputObject $output -ErrorAction Stop}
        catch{throw "$Label doctor did not return one unambiguous JSON report."}
        return [pscustomobject]@{exitCode=$child.Process.ExitCode;diagnostic=$diagnostic}
    }finally{$child.Dispose()}
}
function Assert-SetupTransition($Result,[bool]$ExpectedEngineVerified,[string]$ExpectedStartPhase,[string]$Label){
    if($Result.exitCode -notin @(0,2)){throw "$Label doctor returned an unexpected exit code."}
    $decision=Get-FastLlmUiSetupDecision -Diagnostic $Result.diagnostic -ExitCode $Result.exitCode
    Check ($decision.canProceed -and $decision.engineVerified -eq $ExpectedEngineVerified) "$Label setup decision mismatched the engine state."
    $start=New-FastLlmUiFlow -Mode start
    $start=Move-FastLlmUiFlow -Flow $start -Event setup-complete -SetupDecision $decision
    Check ($start.phase -ceq $ExpectedStartPhase -and $null -eq $start.pendingPlan -and $null -eq $start.pendingProvenance) "$Label Start transition was not fresh and expected."
    $install=New-FastLlmUiFlow -Mode install
    $install=Move-FastLlmUiFlow -Flow $install -Event setup-complete -SetupDecision $decision
    Check ($install.phase -ceq 'engine' -and $null -eq $install.pendingPlan -and $null -eq $install.pendingProvenance) "$Label Install transition did not enter engine provisioning."
    return $decision
}

$absentRoot=Join-Path ([IO.Path]::GetTempPath()) ('fastllm-ui-setup-absent-'+[Guid]::NewGuid().ToString('N'))
if(Test-Path -LiteralPath $absentRoot){throw 'The absent-root control unexpectedly exists.'}
$phase='verified-root doctor'
try{
    $verified=Invoke-Doctor -Path $InstallRoot -Label 'Verified-root'
    Check ($verified.exitCode -eq 0) 'Verified-root doctor did not complete a live probe and plan.'
    Check ($verified.diagnostic.vulkanVerified -and $verified.diagnostic.vulkanRuntimeReady -and
        $null -ne $verified.diagnostic.hardware -and $null -ne $verified.diagnostic.plan) 'Verified-root doctor did not report a usable engine and plan.'
    $null=Assert-SetupTransition -Result $verified -ExpectedEngineVerified $true -ExpectedStartPhase preview -Label 'Verified-root'

    $phase='absent-root doctor'
    $absent=Invoke-Doctor -Path $absentRoot -Label 'Absent-root'
    Check ($absent.exitCode -eq 2) 'Absent-root doctor did not report missing engine hardware.'
    Check (-not $absent.diagnostic.vulkanVerified -and $null -eq $absent.diagnostic.hardware -and
        $null -eq $absent.diagnostic.plan) 'Absent-root doctor unexpectedly verified an engine or plan.'
    $null=Assert-SetupTransition -Result $absent -ExpectedEngineVerified $false -ExpectedStartPhase engine -Label 'Absent-root'
    Check (-not (Test-Path -LiteralPath $absentRoot)) 'Read-only absent-root doctor created a directory.'

    $phase='postcheck'
    Check (Test-FastLlmEngineInstallation -InstallRoot $InstallRoot -EngineVersion ([string]$catalog.engine.version) -BackendKey vulkan -Asset $catalog.engine.assets.vulkan) 'Read-only setup changed the verified engine manifest.'
    Check (-not (Test-Path -LiteralPath (Join-Path $InstallRoot 'models')) -and
        -not (Test-Path -LiteralPath (Join-Path $InstallRoot 'consents'))) 'Read-only setup created model or receipt directories.'
    Write-Output "PASS: native UI setup flow consumed both real doctor reports ($checks checks); no download, model, consent, or GUI automation."
}catch{
    Write-Output "FAIL: native UI setup flow stopped during ${phase}: $($_.Exception.Message)"
    throw
}
