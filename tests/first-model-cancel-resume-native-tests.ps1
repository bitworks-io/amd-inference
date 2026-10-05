#requires -Version 5.1
# Opt-in physical cancellation/resume test. This acquires the owner's previously
# approved exact Qwen3.5-4B artifact in a new root; no model is served.
[CmdletBinding()]
param([switch]$AllowModelDownload)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
if(-not $AllowModelDownload){Write-Output 'SKIP: pass -AllowModelDownload to exercise the approved 2.48 GB model transfer in a fresh private cache.';exit 0}
if($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSVersion.Major -ne 5){Write-Output 'SKIP: this physical transfer test requires Windows PowerShell 5.1.';exit 0}
if(-not [Environment]::Is64BitProcess){throw 'Use 64-bit Windows PowerShell 5.1.'}
$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Use a standard Windows account.'}

$repo=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $repo 'src/FastLlm.psm1') -Force -PassThru
. (Join-Path $repo 'src/FastLlm.UiFlow.ps1')
$prerequisites=Get-FastLlmWindowsPrerequisiteStatus
if(-not $prerequisites.applicable -or -not $prerequisites.ready){Write-Output 'SKIP: required Windows engine prerequisites are missing; no acquisition attempted.';exit 0}
$catalog=Get-FastLlmCatalog (Join-Path $repo 'config/catalog.json')
$models=@($catalog.models|Where-Object id -ceq 'qwen3.5-4b-iq4-xs')
if($models.Count -ne 1){throw 'Expected one exact reviewed model.'}
$model=$models[0]
$digest=Get-FastLlmUiModelProvenanceDigest -Model $model
if($digest -cne 'baf3ddb9254c6fef7048f1ef710afcae43e5bbb49b34407c05fbf33460c3b292' -or
    $catalog.engine.version -cne 'b10698' -or -not $catalog.engine.assets.vulkan.enabled -or $catalog.engine.assets.rocm.enabled){
    throw 'Reviewed first-model acquisition provenance or engine policy changed.'
}
$installRoot=Join-Path ([IO.Path]::GetTempPath()) ('fastllm-cancel-resume-'+[Guid]::NewGuid().ToString('N'))
if(Test-Path -LiteralPath $installRoot){throw 'Fresh test root unexpectedly exists.'}
$drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($installRoot))
if($drive.AvailableFreeSpace -lt 8GB){throw 'At least 8 GiB free disk space is required for this isolated transfer check.'}
& $module {Initialize-FastLlmProcessHost}
$cli=Join-Path $repo 'fast-llm.ps1'
$destination=[IO.Path]::GetFullPath((Join-Path (Join-Path $installRoot 'models') ([string]$model.file)))
$partial="$destination.$($model.sha256.Substring(0,16)).partial"
$artifactLock="$destination.$($model.sha256.Substring(0,16)).lock"
$operationLock=Join-Path (Join-Path $installRoot 'state') 'operation.lock'
$receiptPath=& $module {param($m,$r) Get-FastLlmModelConsentPath -Model $m -InstallRoot $r} $model $installRoot
$installArgs=@('install','-InstallRoot',$installRoot,'-ModelId','qwen3.5-4b-iq4-xs','-ContextSize','8192',
    '-Unattended','-AcceptModelLicense','-ExpectedModelProvenanceSha256',$digest)
$phase='engine-only'
$checks=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:checks++}
function New-OwnedChild([string[]]$CliArguments){
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=(Get-Process -Id $PID).Path
    $argv=@('-NoLogo','-NoProfile','-NonInteractive','-OutputFormat','Text','-File',$cli)+$CliArguments
    $info.Arguments=& $module {param($a) Join-FastLlmProcessArguments $a} $argv
    $info.WorkingDirectory=$repo;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $child=New-Object Bitworks.FastLlm.ProcessHost
    $child.Start($info)
    return $child
}
function Wait-OwnedChild($Child,[int]$DeadlineSeconds,[string]$Label){
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while(-not $Child.Process.HasExited -and $watch.Elapsed.TotalSeconds -lt $DeadlineSeconds){[void]$Child.Process.WaitForExit(250)}
    if(-not $Child.Process.HasExited){throw "$Label exceeded its $DeadlineSeconds-second deadline."}
    while(-not $Child.OutputCompleted -and $watch.Elapsed.TotalSeconds -lt $DeadlineSeconds){Start-Sleep -Milliseconds 20}
    if(-not $Child.OutputCompleted -or $Child.OutputTruncated){throw "$Label output was incomplete or truncated."}
    return [pscustomobject]@{exitCode=$Child.Process.ExitCode;text=$Child.Snapshot()}
}
function Assert-ExclusivePath([string]$Path,[string]$Label,[bool]$MustExist){
    if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){
        if($MustExist){throw "$Label is absent."}
        return
    }
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw "$Label is a reparse point."}
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while($watch.Elapsed.TotalSeconds -lt 15){
        $stream=$null
        try{$stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);return}
        catch{Start-Sleep -Milliseconds 100}
        finally{if($stream){$stream.Dispose()}}
    }
    throw "$Label remained locked after cancellation."
}
$child=$null
try{
    Write-Output 'Preparing the pinned engine in a fresh private cache; no model is started.'
    $child=New-OwnedChild @('install','-EngineOnly','-Unattended','-InstallRoot',$installRoot)
    $engineResult=Wait-OwnedChild $child 600 'Engine-only preparation'
    Check ($engineResult.exitCode -eq 0) 'Engine-only preparation failed.'
    $child.Dispose();$child=$null
    Check (Test-FastLlmEngineInstallation -InstallRoot $installRoot -EngineVersion $catalog.engine.version -BackendKey vulkan -Asset $catalog.engine.assets.vulkan) 'Pinned Vulkan engine manifest is not verified.'
    Check (-not (Test-Path -LiteralPath $destination) -and -not (Test-Path -LiteralPath $receiptPath)) 'Engine-only preparation acquired model or consent data.'

    $phase='partial-transfer'
    $child=New-OwnedChild $installArgs
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $minimum=[long](8MB)
    $observed=[long]0
    while($watch.Elapsed.TotalSeconds -lt 900){
        if($child.Process.HasExited){throw 'Model transfer ended before the intentional cancellation point.'}
        if(Test-Path -LiteralPath $partial -PathType Leaf){
            $part=Get-Item -LiteralPath $partial -Force -ErrorAction Stop
            if(($part.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Partial transfer path became a reparse point.'}
            $observed=[long]$part.Length
            if($observed -ge $minimum){break}
        }
        Start-Sleep -Milliseconds 250
    }
    Check ($observed -ge $minimum -and $observed -lt [long]$model.sizeBytes -and -not $child.Process.HasExited) 'A live incomplete model transfer did not reach the bounded cancellation point.'
    $child.Dispose();$child=$null
    $phase='cancelled-state'
    Check ((Test-Path -LiteralPath $partial -PathType Leaf) -and -not (Test-Path -LiteralPath $destination) -and
        -not (Test-Path -LiteralPath $receiptPath)) 'Cancellation must retain only an incomplete SHA-bound partial, not promote a model or receipt.'
    # Exclusive handles and stable bytes are observed cleanup evidence. They do
    # not independently enumerate or prove every former downloader PID exited.
    Assert-ExclusivePath $partial 'SHA-bound partial' $true
    Assert-ExclusivePath $operationLock 'Installation operation lock' $true
    Assert-ExclusivePath $artifactLock 'Artifact acquisition lock' $false
    $before=[long](Get-Item -LiteralPath $partial -Force).Length
    Start-Sleep -Seconds 3
    $after=[long](Get-Item -LiteralPath $partial -Force).Length
    Check ($before -eq $after -and $before -ge $minimum -and $before -lt [long]$model.sizeBytes) 'Partial file did not remain stable after owned-child disposal.'
    $status=Get-FastLlmStatus -InstallRoot $installRoot
    Check (-not $status.active -and [string]$status.phase -ceq 'interrupted') 'Interrupted operation remained active or did not report interrupted state.'

    $phase='resumed-transfer'
    Write-Output "Retrying the exact approved artifact from a retained $before-byte partial."
    $child=New-OwnedChild $installArgs
    $retry=Wait-OwnedChild $child 1200 'Resumed model acquisition'
    Check ($retry.exitCode -eq 0 -and -not $child.OutputTruncated) 'Resumed model acquisition did not complete.'
    # This establishes the application's resume branch, not on-wire HTTP Range efficiency.
    Check ($retry.text -match '(?m)^Resuming download \(' -and $retry.text -notmatch '(?m)^Starting download \(') 'The retry did not report use of the retained partial.'
    $child.Dispose();$child=$null

    $phase='verification'
    Check (Test-FastLlmModelConsentReceipt -Model $model -InstallRoot $installRoot) 'Exact model consent receipt is missing after successful retry.'
    $receipt=Get-Content -LiteralPath $receiptPath -Raw|ConvertFrom-Json
    Check ([string]$receipt.acceptanceMode -ceq 'explicit-switch') 'Retry consent was not recorded as explicit approval.'
    Check ((Test-Path -LiteralPath $destination -PathType Leaf) -and -not (Test-Path -LiteralPath $partial)) 'Resume did not promote the verified partial to the exact model path.'
    $weights=Get-Item -LiteralPath $destination -Force
    $modelFiles=@(Get-ChildItem -LiteralPath (Join-Path $installRoot 'models') -Recurse -File -Force -Filter '*.gguf')
    Check ($modelFiles.Count -eq 1 -and $modelFiles[0].FullName -ceq $destination) 'Retry created an unexpected model artifact.'
    Check ((($weights.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) -and
        $weights.Length -eq [long]$model.sizeBytes -and
        (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $model.sha256) 'Final model size or SHA-256 does not match the catalog.'
    $status=Get-FastLlmStatus -InstallRoot $installRoot
    Check (-not $status.active -and [string]$status.phase -ceq 'installed' -and
        [string]$status.modelId -ceq [string]$model.id) 'Final state is not the expected inactive installed model.'
    Check (Test-FastLlmEngineInstallation -InstallRoot $installRoot -EngineVersion $catalog.engine.version -BackendKey vulkan -Asset $catalog.engine.assets.vulkan) 'Engine manifest changed during transfer.'
    Write-Output "PASS: observed cleanup left an exclusive stable partial, and the exact verified model/receipt installed after the application's reported resume branch ($checks checks). No downloader-PID, HTTP-range-efficiency, serving, fit, or throughput claim."
}catch{
    Write-Output "FAIL: cancel/resume native test stopped during ${phase}: $($_.Exception.Message)"
    throw
}finally{
    if($child){$child.Dispose()}
    Write-Output "PRESERVED TEST INSTALL ROOT: $installRoot"
    Write-Output 'This fresh private cache was not removed. Child deadlines do not cover parent-side final hashing.'
}
