#requires -Version 5.1
# Opt-in lab acquisition only; this does not load a model or qualify GPU fit.
[CmdletBinding()]
param([switch]$AllowModelDownload)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
if(-not $AllowModelDownload){Write-Output 'SKIP: pass -AllowModelDownload for the approved 2.48 GB Qwen3.5 4B acquisition.';exit 0}
if($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSVersion.Major -ne 5){Write-Output 'SKIP: this acquisition test requires Windows PowerShell 5.1.';exit 0}
if(-not [Environment]::Is64BitProcess){throw 'Use 64-bit Windows PowerShell.'}
$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Use a standard Windows account.'}
$repo=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $repo 'src/FastLlm.psm1') -Force -PassThru
. (Join-Path $repo 'src/FastLlm.UiFlow.ps1')
$prerequisites=Get-FastLlmWindowsPrerequisiteStatus
if(-not $prerequisites.ready){Write-Output 'SKIP: required Windows engine prerequisites are missing; no download attempted.';exit 0}
$catalog=Get-FastLlmCatalog (Join-Path $repo 'config/catalog.json')
$models=@($catalog.models|Where-Object id -ceq 'qwen3.5-4b-iq4-xs')
if($models.Count -ne 1){throw 'Expected one exact reviewed model.'}
$model=$models[0]
$digest=Get-FastLlmUiModelProvenanceDigest -Model $model
if($digest -cne 'baf3ddb9254c6fef7048f1ef710afcae43e5bbb49b34407c05fbf33460c3b292' -or
    $catalog.engine.version -cne 'b10698' -or -not $catalog.engine.assets.vulkan.enabled -or $catalog.engine.assets.rocm.enabled){
    throw 'Reviewed first-model acquisition provenance or engine policy changed.'
}
$installRoot=Join-Path ([IO.Path]::GetTempPath()) ('fastllm-first-model-'+[Guid]::NewGuid().ToString('N'))
if(Test-Path -LiteralPath $installRoot){throw 'Fresh model install root unexpectedly exists.'}
$drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($installRoot))
if($drive.AvailableFreeSpace -lt 8GB){throw 'At least 8 GiB free disk space is required for this isolated acquisition check.'}
& $module {Initialize-FastLlmProcessHost}
$info=New-Object Diagnostics.ProcessStartInfo
$info.FileName=(Get-Process -Id $PID).Path
$argv=@('-NoLogo','-NoProfile','-NonInteractive','-OutputFormat','Text','-File',(Join-Path $repo 'fast-llm.ps1'),
    'install','-InstallRoot',$installRoot,'-ModelId','qwen3.5-4b-iq4-xs','-ContextSize','8192',
    '-Unattended','-AcceptModelLicense','-ExpectedModelProvenanceSha256',$digest)
$info.Arguments=& $module {param($a) Join-FastLlmProcessArguments $a} $argv
$info.WorkingDirectory=$repo;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
$child=New-Object Bitworks.FastLlm.ProcessHost
$watch=[Diagnostics.Stopwatch]::StartNew()
$phase='acquisition'
try{
    Write-Output 'Starting the exact reviewed engine and 2.48 GB model acquisition in a new private cache.'
    $child.Start($info)
    while(-not $child.Process.HasExited -and $watch.Elapsed.TotalSeconds -lt 1200){[void]$child.Process.WaitForExit(250)}
    if(-not $child.Process.HasExited){throw 'First-model acquisition exceeded 1200 seconds.'}
    while(-not $child.OutputCompleted -and $watch.Elapsed.TotalSeconds -lt 1200){Start-Sleep -Milliseconds 20}
    if(-not $child.OutputCompleted -or $child.OutputTruncated){throw 'First-model child output was incomplete or truncated.'}
    if($child.Process.ExitCode -ne 0){Write-Output $child.Snapshot();throw 'First-model install child failed.'}
    $phase='verification'
    if(-not (Test-FastLlmModelConsentReceipt -Model $model -InstallRoot $installRoot)){throw 'Exact model consent receipt is missing.'}
    $receiptPath=& $module {param($m,$r) Get-FastLlmModelConsentPath -Model $m -InstallRoot $r} $model $installRoot
    $receipt=Get-Content -LiteralPath $receiptPath -Raw|ConvertFrom-Json
    if([string]$receipt.acceptanceMode -cne 'explicit-switch'){throw 'The new consent was not recorded as explicit approval.'}
    if(-not (Test-FastLlmEngineInstallation -InstallRoot $installRoot -EngineVersion $catalog.engine.version -BackendKey vulkan -Asset $catalog.engine.assets.vulkan)){
        throw 'Engine manifest verification failed after model acquisition.'
    }
    $expectedModelPath=[IO.Path]::GetFullPath((Join-Path (Join-Path $installRoot 'models') ([string]$model.file)))
    $weights=@(Get-ChildItem -LiteralPath (Join-Path $installRoot 'models') -Recurse -File -Force -Filter '*.gguf')
    if($weights.Count -ne 1 -or $weights[0].FullName -cne $expectedModelPath -or
        ($weights[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        $weights[0].Length -ne [long]$model.sizeBytes -or
        (Get-FileHash -LiteralPath $weights[0].FullName -Algorithm SHA256).Hash.ToLowerInvariant() -cne $model.sha256){
        throw 'Exact model artifact verification failed.'
    }
    $state=Get-FastLlmStatus -InstallRoot $installRoot
    if([string]$state.phase -cne 'installed' -or [string]$state.modelId -cne [string]$model.id -or $state.active){
        throw 'Acquisition did not finish in the expected inactive installed-model state.'
    }
    Write-Output 'PASS: first-time exact Qwen3.5 4B artifact, provenance-bound consent and full Vulkan engine manifest verified. No inference, fit or performance claim.'
}catch{
    Write-Output "FAIL: first-model native test stopped during ${phase}: $($_.Exception.Message)"
    throw
}finally{
    $child.Dispose()
    Write-Output "PRESERVED MODEL ROOT: $installRoot"
    Write-Output 'The test retains its cache for review; the child deadline does not cover parent-side verification.'
}
