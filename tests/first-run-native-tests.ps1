#requires -Version 5.1
# Opt-in physical Windows first-run check. Downloads only the pinned Vulkan engine
# into a fresh disposable-by-name root, which is deliberately retained for review.
[CmdletBinding()]
param([switch] $AllowEngineDownload)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

if (-not $AllowEngineDownload) {
    Write-Output 'SKIP: pass -AllowEngineDownload to permit the pinned engine download into a fresh test root.'
    exit 0
}
if ($env:OS -ne 'Windows_NT') {
    Write-Output 'SKIP: physical first-run engine validation requires Windows.'
    exit 0
}
if ($PSVersionTable.PSVersion.Major -ne 5) {
    Write-Output 'SKIP: physical first-run engine validation targets Windows PowerShell 5.1.'
    exit 0
}
if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell 5.1.' }
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Use a standard Windows account; native engine execution must not be elevated.'
}

$repo = Split-Path $PSScriptRoot -Parent
$module = Import-Module (Join-Path $repo 'src/FastLlm.psm1') -Force -PassThru
$prerequisites = Get-FastLlmWindowsPrerequisiteStatus
if (-not $prerequisites.applicable -or -not $prerequisites.ready) {
    $missing = @($prerequisites.missingVcRuntimeFiles) -join ','
    Write-Output "SKIP: Windows engine prerequisites are not ready; missing VC files: $missing; Vulkan loader present: $([bool]$prerequisites.vulkanLoaderPresent). No test root or download created."
    exit 0
}
& $module { Initialize-FastLlmProcessHost }

$cli = Join-Path $repo 'fast-llm.ps1'
$catalog = Get-FastLlmCatalog (Join-Path $repo 'config/catalog.json')
if ([string]$catalog.engine.version -ne 'b10698' -or -not [bool]$catalog.engine.assets.vulkan.enabled -or
    [bool]$catalog.engine.assets.rocm.enabled) {
    throw 'This test permits only the reviewed b10698 Vulkan engine lane.'
}
$installRoot = Join-Path ([IO.Path]::GetTempPath()) ('fastllm-first-run-'+[Guid]::NewGuid().ToString('N'))
if (Test-Path -LiteralPath $installRoot) { throw 'The fresh test root unexpectedly exists.' }
$phase = 'doctor-before'
$checks = 0
function Check([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Invoke-BoundedCli([string] $PhaseName, [int] $DeadlineSeconds, [string[]] $CliArguments) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = (Get-Process -Id $PID).Path
    $argv = @('-NoLogo','-NoProfile','-NonInteractive','-OutputFormat','Text','-File',$cli) + $CliArguments
    $info.Arguments = & $module { param($A) Join-FastLlmProcessArguments $A } $argv
    $info.WorkingDirectory = $repo
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $child = New-Object Bitworks.FastLlm.ProcessHost
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $child.Start($info)
        while (-not $child.Process.HasExited -and $watch.Elapsed.TotalSeconds -lt $DeadlineSeconds) {
            [void]$child.Process.WaitForExit(100)
        }
        if (-not $child.Process.HasExited) { throw "$PhaseName exceeded its $DeadlineSeconds-second deadline." }
        while (-not $child.OutputCompleted -and $watch.Elapsed.TotalSeconds -lt $DeadlineSeconds) {
            Start-Sleep -Milliseconds 20
        }
        if (-not $child.OutputCompleted -or $child.OutputTruncated) {
            throw "$PhaseName child output was incomplete or truncated."
        }
        return [pscustomobject]@{ exitCode=$child.Process.ExitCode; text=$child.Snapshot() }
    }
    finally { $child.Dispose() }
}
function ConvertFrom-DoctorOutput([string] $Output, [string] $PhaseName) {
    # Doctor emits one JSON report. Warnings or unrelated console text must not
    # become a success signal or be guessed around by extracting a JSON fragment.
    try { $report = ConvertFrom-Json -InputObject $Output -ErrorAction Stop }
    catch { throw "$PhaseName did not return an unambiguous doctor JSON report." }
    if (-not $report -or -not $report.PSObject.Properties['windowsPrerequisites'] -or
        -not $report.PSObject.Properties['vulkanVerified'] -or
        -not $report.PSObject.Properties['hardware'] -or
        -not $report.PSObject.Properties['plan']) {
        throw "$PhaseName doctor report is missing required fields."
    }
    return $report
}

try {
    $beforeResult = Invoke-BoundedCli $phase 90 @('doctor','-InstallRoot',$installRoot)
    $before = ConvertFrom-DoctorOutput $beforeResult.text $phase
    Check ($beforeResult.exitCode -eq 2) 'Doctor before engine acquisition must report unavailable hardware.'
    Check ($before.windows -and $before.windowsPrerequisites.ready) 'Doctor before install must report ready Windows prerequisites.'
    Check (-not $before.vulkanVerified -and -not $before.vulkanRuntimeReady) 'The fresh root must not already have a verified Vulkan engine.'
    Check ($null -eq $before.hardware -and $null -eq $before.plan) 'Doctor before install unexpectedly produced a hardware plan.'
    Check (-not (Test-Path -LiteralPath $installRoot)) 'Doctor before install created the fresh root.'

    $phase = 'engine-only-install'
    $installResult = Invoke-BoundedCli $phase 600 @('install','-EngineOnly','-Unattended','-InstallRoot',$installRoot)
    Check ($installResult.exitCode -eq 0) 'Engine-only install child did not finish successfully.'
    Check ($installResult.text -match 'Verified engine installed. No model license was accepted and no weights were downloaded.') 'Engine-only install did not state its no-model outcome.'

    $phase = 'manifest-verification'
    Check (Test-FastLlmEngineInstallation -InstallRoot $installRoot -EngineVersion ([string]$catalog.engine.version) -BackendKey 'vulkan' -Asset $catalog.engine.assets.vulkan) 'Installed Vulkan tree failed the full catalog manifest.'
    Check (-not (Test-Path -LiteralPath (Join-Path $installRoot 'models'))) 'Engine-only install created model weights directory.'
    Check (-not (Test-Path -LiteralPath (Join-Path $installRoot 'consents'))) 'Engine-only install created model consent receipts.'
    $weights = @(Get-ChildItem -LiteralPath $installRoot -Recurse -File -Force -ErrorAction Stop | Where-Object { $_.Extension -ieq '.gguf' })
    Check ($weights.Count -eq 0) 'Engine-only install left GGUF weights.'

    $phase = 'doctor-after'
    $afterResult = Invoke-BoundedCli $phase 90 @('doctor','-InstallRoot',$installRoot)
    $after = ConvertFrom-DoctorOutput $afterResult.text $phase
    Check ($afterResult.exitCode -eq 0) 'Doctor after engine install did not produce a successful probe and plan.'
    Check ($after.vulkanVerified -and $after.vulkanRuntimeReady) 'Doctor after install did not verify the engine and prerequisites.'
    Check ($null -ne $after.hardware -and $null -ne $after.plan -and -not $after.error) 'Doctor after install did not produce a live hardware plan.'
    Check ([string]$after.plan.engineVersion -ceq [string]$catalog.engine.version -and
        [string]$after.plan.backend -ceq 'Vulkan') 'Doctor after install planned an unexpected engine backend or version.'
    Check (-not (Test-Path -LiteralPath (Join-Path $installRoot 'models')) -and
        -not (Test-Path -LiteralPath (Join-Path $installRoot 'consents'))) 'Doctor after install provisioned model or consent data.'
    $state = Get-FastLlmStatus -InstallRoot $installRoot
    Check ([string]$state.phase -ceq 'engine-installed') 'Engine-only install or doctor claimed a serving-ready state.'

    Write-Output "PASS: first-run engine-only validation completed ($checks checks). Pinned Vulkan manifest and live doctor plan verified; no model, consent, or Ready claim."
}
catch {
    Write-Output "FAIL: first-run engine-only validation stopped in phase '$phase': $($_.Exception.Message)"
    throw
}
finally {
    Write-Output "PRESERVED TEST INSTALL ROOT: $installRoot"
    Write-Output 'The fresh test root was not deleted. Review it before any manual cleanup.'
}
