#requires -Version 5.1
# Private, read-only snapshot of Vulkan/AMD DLLs loaded in one supervised server.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$InstallRoot,
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{32}$')][string]$RunId,
    [string]$OutputPath,
    [switch]$Worker
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version 2

if($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess){throw 'This diagnostic requires 64-bit Windows PowerShell.'}
$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run as the same standard user as the server.'}
if(-not $Worker -and [string]::IsNullOrWhiteSpace($OutputPath)){throw 'A fresh private output file is required.'}
$root=Split-Path $PSScriptRoot -Parent
$helperPath=Join-Path $root 'src/FastLlm.VulkanModuleBinding.ps1'
$sourceHash=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
$helperHash=(Get-FileHash -LiteralPath $helperPath -Algorithm SHA256).Hash.ToLowerInvariant()
Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force -DisableNameChecking -ErrorAction Stop
Add-Type -Path (Join-Path $root 'src/WindowsGpuTelemetry.cs') -ErrorAction Stop
. $helperPath

function Assert-ModuleTarget {
    param([string]$ExpectedRunId,[int]$ExpectedPid=0,[long]$ExpectedTicks=0,[string]$ExpectedEngineHash='')
    $state=Get-FastLlmStatus -InstallRoot $InstallRoot
    Assert-FastLlmVulkanModuleState -State $state -RunId $ExpectedRunId -ExpectedPid $ExpectedPid -ExpectedTicks $ExpectedTicks -ExpectedEngineHash $ExpectedEngineHash
    $pidValue=[int]$state.processIdentity.pid
    $ticks=[long]$state.processIdentity.startUtcTicks
    $owners=@([Bitworks.FastLlm.WindowsGpuTelemetry]::GetLoopbackListenerOwners(8080))
    $process=$null
    try{
        $process=[Diagnostics.Process]::GetProcessById($pidValue)
        if($process.HasExited){throw 'The server process has exited.'}
        $exe=[IO.Path]::GetFullPath($process.MainModule.FileName)
        $name=[string]$process.ProcessName
        $observedTicks=[long]$process.StartTime.ToUniversalTime().Ticks
    }finally{if($process){$process.Dispose()}}
    $catalog=Get-FastLlmCatalog -CatalogPath (Join-Path $root 'config/catalog.json')
    $asset=$catalog.engine.assets.vulkan
    if($catalog.engine.version -cne 'b10698' -or $asset.enabled -ne $true -or
        $asset.entryPoint -cne 'llama-server.exe' -or
        $asset.sha256 -cne '31e2fe70d4864a4ae6a4e7d8e102ee9203ba18963077e7727c54f9bd6ae3bea5'){
        throw 'The installed engine catalog is not the pinned Vulkan lane.'
    }
    if((Get-FileHash -LiteralPath (Join-Path $root 'config/catalog.json') -Algorithm SHA256).Hash.ToLowerInvariant() -cne
        [string]$state.recipe.catalogSha256){throw 'The current catalog differs from the supervised run recipe.'}
    if(-not (Test-FastLlmEngineInstallation -InstallRoot $InstallRoot -EngineVersion 'b10698' -BackendKey 'vulkan' -Asset $asset)){
        throw 'The pinned engine installation did not pass its complete file manifest.'
    }
    $expected=[IO.Path]::GetFullPath((Get-FastLlmEngineExecutable -InstallRoot $InstallRoot -EngineVersion 'b10698' -BackendKey 'vulkan'))
    $observedSha=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-FastLlmVulkanModuleProcess -State $state -ListenerOwners $owners -ProcessName $name -ProcessTicks $observedTicks -ActualExe $exe -ExpectedExe $expected -ActualExeSha256 $observedSha
    return [pscustomobject]@{pid=$pidValue;startUtcTicks=$ticks;engineSha256=[string]$state.recipe.engineSha256;
        catalogSha256=[string]$state.recipe.catalogSha256;modelSha256=[string]$state.modelSha256;
        executablePath=$exe;state=$state}
}

function Read-SelectedLoadedModules {
    param([int]$ServerPid,[long]$StartTicks)
    $process=$null
    try{
        $process=[Diagnostics.Process]::GetProcessById($ServerPid)
        if($process.HasExited -or [long]$process.StartTime.ToUniversalTime().Ticks -ne $StartTicks){throw 'The server changed before module enumeration.'}
        $modules=@($process.Modules)
        $selected=@(Select-FastLlmVulkanModulePaths -Modules $modules)
        return [pscustomobject]@{totalModuleCount=$modules.Count;paths=$selected}
    }finally{if($process){$process.Dispose()}}
}

function Read-SelectedModuleFile {
    param([string]$Path)
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -lt 1 -or $item.Length -gt 268435456){throw 'A selected module is absent, linked, or exceeds the file limit.'}
    $signature=Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    $fileVersion=[string]$item.VersionInfo.FileVersion
    $productVersion=[string]$item.VersionInfo.ProductVersion
    if($fileVersion.Length -gt 128 -or $fileVersion -match '[\x00-\x1f\x7f]'){$fileVersion=$null}
    if($productVersion.Length -gt 128 -or $productVersion -match '[\x00-\x1f\x7f]'){$productVersion=$null}
    $signer=$null
    if($signature.SignerCertificate){
        $subject=[string]$signature.SignerCertificate.Subject
        if($subject.Length -le 512 -and $subject -notmatch '[\x00-\x1f\x7f]'){$signer=$subject}
    }
    return [pscustomobject]@{name=$item.Name;path=$item.FullName;sizeBytes=[long]$item.Length;
        fileVersion=$fileVersion;productVersion=$productVersion;
        sha256=(Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant();
        signatureStatus=[string]$signature.Status;signer=$signer}
}

if($Worker){
    $first=Assert-ModuleTarget -ExpectedRunId $RunId
    $capturedAt=(Get-Date).ToUniversalTime().ToString('o')
    $snapshot=Read-SelectedLoadedModules -ServerPid $first.pid -StartTicks $first.startUtcTicks
    $files=New-Object System.Collections.Generic.List[object]
    foreach($path in $snapshot.paths){$files.Add((Read-SelectedModuleFile -Path $path))}
    $last=Assert-ModuleTarget -ExpectedRunId $RunId -ExpectedPid $first.pid -ExpectedTicks $first.startUtcTicks -ExpectedEngineHash $first.engineSha256
    if($last.catalogSha256 -cne $first.catalogSha256 -or $last.modelSha256 -cne $first.modelSha256 -or
        -not [string]::Equals($last.executablePath,$first.executablePath,[StringComparison]::OrdinalIgnoreCase)){
        throw 'The run provenance changed during module collection.'
    }
    if((Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $sourceHash -or
        (Get-FileHash -LiteralPath $helperPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $helperHash){
        throw 'The diagnostic source changed during module collection.'
    }
    $report=[ordered]@{
        schemaVersion=1;kind='private-windows-vulkan-loaded-modules';runId=$RunId
        capturedAtUtc=$capturedAt;finishedAtUtc=(Get-Date).ToUniversalTime().ToString('o')
        serverPid=$first.pid;serverStartUtcTicks=$first.startUtcTicks
        engineSha256=$first.engineSha256;catalogSha256=$first.catalogSha256;modelSha256=$first.modelSha256
        collectorSourceSha256=$sourceHash;bindingHelperSha256=$helperHash
        executablePath=$first.executablePath;enumeratedModuleCount=$snapshot.totalModuleCount
        selectedModules=$files.ToArray();snapshotComplete=$true
        identityBinding='Ready run ID, owner of port 8080, PID/start ticks, exact installed executable path and SHA-256, before and after module snapshot'
        qualified=$false;gpuAdapterBound=$false;dynamicDependencyClosureVerified=$false
        note='A momentary loaded-module snapshot and on-disk file metadata. It does not attest mapped image bytes, the active physical GPU, the ICD selected by Vulkan, or all DLL dependencies.'
    }
    $json=$report | ConvertTo-Json -Depth 8 -Compress
    $bytes=[Text.Encoding]::UTF8.GetBytes($json)
    if($bytes.Length -gt 60000){throw 'Module report exceeds its byte limit.'}
    for($offset=0;$offset -lt $bytes.Length;$offset+=4096){
        $count=[Math]::Min(4096,$bytes.Length-$offset)
        [Console]::Out.WriteLine('FASTLLM_MODULE_CHUNK:'+($offset/4096)+':'+[Convert]::ToBase64String($bytes,$offset,$count))
    }
    return
}

$full=$null
Assert-FastLlmVulkanModuleOutputSyntax -Path $OutputPath
$full=[IO.Path]::GetFullPath($OutputPath)
$driveRoot=[IO.Path]::GetPathRoot($full)
Assert-FastLlmVulkanModuleOutputComponents -FullPath $full -Root $driveRoot
$initial=Assert-ModuleTarget -ExpectedRunId $RunId
$module=Get-Module FastLlm
& $module {Initialize-FastLlmProcessHost}
$child=New-Object Bitworks.FastLlm.ProcessHost
try{
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=(Get-Process -Id $PID).Path
    $workerArguments=@('-NoLogo','-NoProfile','-NonInteractive','-OutputFormat','Text','-File',$PSCommandPath,
        '-InstallRoot',$InstallRoot,'-RunId',$RunId,'-Worker')
    $info.Arguments=& $module {param($Arguments) Join-FastLlmProcessArguments $Arguments} $workerArguments
    $child.Start($info)
    $clock=[Diagnostics.Stopwatch]::StartNew()
    if(-not $child.Process.WaitForExit(60000)){throw 'Module worker exceeded its 60-second deadline.'}
    while(-not $child.OutputCompleted -and $clock.ElapsedMilliseconds -lt 60000){Start-Sleep -Milliseconds 20}
    if($child.Process.ExitCode -ne 0 -or -not $child.OutputCompleted -or $child.OutputTruncated){throw 'Module worker failed or returned incomplete output.'}
    $lines=@($child.Snapshot() -split "`r?`n" | Where-Object {$_ -ne ''})
    if($lines.Count -lt 1 -or $lines.Count -gt 15){throw 'Module worker returned an invalid chunk count.'}
    $parts=New-Object System.Collections.Generic.List[byte[]]
    [long]$total=0
    foreach($line in $lines){
        if($line -cnotmatch '^FASTLLM_MODULE_CHUNK:([0-9]{1,2}):([A-Za-z0-9+/=]{1,5464})$' -or [int]$Matches[1] -ne $parts.Count){
            throw 'Module worker returned an invalid or out-of-order chunk.'
        }
        $part=[Convert]::FromBase64String($Matches[2])
        if($part.Length -lt 1 -or $part.Length -gt 4096){throw 'Module worker chunk exceeds its limit.'}
        $parts.Add($part);$total+=$part.Length
        if($total -gt 60000){throw 'Module worker output exceeds its limit.'}
    }
    $buffer=New-Object byte[] $total
    $offset=0
    foreach($part in $parts){[Array]::Copy($part,0,$buffer,$offset,$part.Length);$offset+=$part.Length}
    $report=[Text.Encoding]::UTF8.GetString($buffer) | ConvertFrom-Json -ErrorAction Stop
    if($report.kind -cne 'private-windows-vulkan-loaded-modules' -or $report.runId -cne $RunId -or
        $report.serverPid -ne $initial.pid -or [long]$report.serverStartUtcTicks -ne $initial.startUtcTicks -or
        $report.engineSha256 -cne $initial.engineSha256 -or
        $report.catalogSha256 -cne $initial.catalogSha256 -or $report.modelSha256 -cne $initial.modelSha256 -or
        $report.collectorSourceSha256 -cne $sourceHash -or $report.bindingHelperSha256 -cne $helperHash -or
        -not [string]::Equals([string]$report.executablePath,$initial.executablePath,[StringComparison]::OrdinalIgnoreCase) -or
        $report.snapshotComplete -ne $true -or
        $report.qualified -ne $false -or $report.gpuAdapterBound -ne $false){
        throw 'Module worker report does not match the active supervised run.'
    }
    Assert-FastLlmVulkanModuleReportRows -Report $report
    Assert-ModuleTarget -ExpectedRunId $RunId -ExpectedPid $initial.pid -ExpectedTicks $initial.startUtcTicks -ExpectedEngineHash $initial.engineSha256 | Out-Null
    Assert-FastLlmVulkanModuleOutputComponents -FullPath $full -Root $driveRoot
    if((Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $sourceHash -or
        (Get-FileHash -LiteralPath $helperPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $helperHash){
        throw 'The diagnostic source changed before report publication.'
    }
    $temporary=Join-Path ([IO.Path]::GetDirectoryName($full)) ('.fastllm-modules-'+[guid]::NewGuid().ToString('N')+'.tmp')
    try{
        $stream=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$stream.Write($buffer,0,$buffer.Length);$stream.Flush($true)}finally{$stream.Dispose()}
        [IO.File]::Move($temporary,$full)
    }finally{
        if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}
    }
    Write-Host "Saved private Vulkan module snapshot: $full"
}finally{$child.Dispose()}
