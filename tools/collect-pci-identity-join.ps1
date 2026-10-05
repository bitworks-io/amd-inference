#requires -Version 5.1
# Advisory only. No planner, benchmark, or serving-process identity is inferred.
[CmdletBinding()]
param([string]$InstallRoot=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Bitworks/FastLLM'),[switch]$Worker)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
if($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess){throw 'PCI identity diagnostic requires 64-bit Windows.'}
$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'PCI identity diagnostic requires a standard user.'}
$repo=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/FastLlm.psm1') -Force -DisableNameChecking
. (Join-Path $repo 'src/FastLlm.PciIdentityJoin.ps1')

if(-not $Worker){
    # The native D3DKMT/SetupAPI calls have no per-call timeout. Bound the
    # complete collector in a disposable kill-on-close child instead.
    if(-not ('Bitworks.FastLlm.ProcessHost' -as [type])){Add-Type -Path (Join-Path $repo 'src/ProcessHost.cs') -ErrorAction Stop}
    $child=New-Object Bitworks.FastLlm.ProcessHost
    try{
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=(Get-Process -Id $PID).Path
        $args=@('-NoLogo','-NoProfile','-NonInteractive','-OutputFormat','Text','-ExecutionPolicy','RemoteSigned',
            '-File',$PSCommandPath,'-InstallRoot',$InstallRoot,'-Worker')
        $module=Get-Module FastLlm
        $info.Arguments=& $module {param($Items) Join-FastLlmProcessArguments -Arguments $Items} $args
        $info.WorkingDirectory=$repo
        $child.Start($info)
        $watch=[Diagnostics.Stopwatch]::StartNew()
        if(-not $child.Process.WaitForExit(60000)){throw 'PCI identity worker exceeded its 60-second deadline.'}
        if($child.Process.ExitCode -ne 0){throw 'PCI identity worker failed.'}
        while(-not $child.OutputCompleted -and $watch.ElapsedMilliseconds -lt 60000){Start-Sleep -Milliseconds 20}
        if(-not $child.OutputCompleted){throw 'PCI identity worker output did not reach EOF.'}
        $document=ConvertFrom-FastLlmPciJoinOutput -OutputText ($child.Snapshot()) -WasTruncated $child.OutputTruncated
        $document | ConvertTo-Json -Depth 8
    }finally{$child.Dispose()}
    return
}

Add-Type -Path @((Join-Path $repo 'src/WindowsInventory.cs'),(Join-Path $repo 'src/WindowsGpuIdentity.cs'),
    (Join-Path $repo 'src/WindowsPciAddress.cs')) -ErrorAction Stop
if(-not [Bitworks.FastLlm.WindowsPciAddress]::LayoutIsExpected()){throw 'Win64 D3DKMT ABI layout check failed.'}
function Read-AddressSnapshot {
    $dxgi=@([Bitworks.FastLlm.WindowsInventory]::Read())
    $pnp=@([Bitworks.FastLlm.WindowsGpuIdentity]::ReadPnP())
    if($dxgi.Count -gt 64 -or $pnp.Count -gt 128){throw 'GPU identity inventory exceeded its bound.'}
    $d=@(foreach($a in $dxgi){[pscustomobject]@{Luid=[string]$a.Luid;VendorId=[long]$a.VendorId;DeviceId=[long]$a.DeviceId}})
    $p=@(foreach($a in $pnp){[pscustomobject]@{InstanceId=[string]$a.InstanceId;LocationInfo=[string]$a.LocationInfo;
        DriverVersion=[string]$a.DriverVersion;LocationError=[string]$a.LocationError;DriverVersionError=[string]$a.DriverVersionError}})
    $k=@(foreach($a in $d){[Bitworks.FastLlm.WindowsPciAddress]::Read($a.Luid)})
    return [pscustomobject]@{dxgi=$d;pnp=$p;kmt=$k}
}

$before=Read-AddressSnapshot
# GGML's independently guarded pinned b10698 worker is read once between two
# address inventories. Its optional full BDF is not joined: KMT lacks segment.
. (Join-Path $repo 'src/FastLlm.GgmlVulkanIdentity.ps1')
$ggml=$null;$ggmlStatus='unavailable'
try{$ggml=Get-FastLlmGgmlVulkanIdentity -InstallRoot $InstallRoot -TimeoutSeconds 20;$ggmlStatus='captured'}
catch{$ggmlStatus='unavailable-or-unverified'}
$after=Read-AddressSnapshot
$beforeJson=ConvertTo-Json -InputObject $before -Depth 8 -Compress
$afterJson=ConvertTo-Json -InputObject $after -Depth 8 -Compress
$stable=$beforeJson -ceq $afterJson
$matches=if($stable){@(Join-FastLlmPciAddressScope -Dxgi $after.dxgi -Pnp $after.pnp -Kmt $after.kmt)}else{@()}
$result=[ordered]@{
    schemaVersion=1;applicable=$true;qualified=$false;stableAcrossCollection=$stable
    identityScope='independent-process-address-scope-advisory'
    source='DXGI-LUID + D3DKMT_ADAPTERADDRESS + exact SetupAPI PCI location and VEN/DEV'
    pciSegmentKnown=$false;ggmlJoin=$null;ggmlJoinReason='unknown-pci-segment'
    ggmlEvidenceStatus=$ggmlStatus;ggmlDeviceCount=if($ggml){@($ggml.devices).Count}else{$null}
    matches=$matches
    note='Only unique bus/device/function plus PCI VEN/DEV identify an address-scope PnP record. KMT supplies no PCI segment; no full BDF, GGML adapter, serving-process, or benchmark adapter binding is claimed.'
}
$record='FASTLLM_PCI_IDENTITY_JSON:'+($result|ConvertTo-Json -Depth 8 -Compress)
if($record.Length -gt 7800){throw 'PCI advisory result exceeds the 7800-character transport limit; no partial identity evidence is emitted.'}
Write-Output $record
