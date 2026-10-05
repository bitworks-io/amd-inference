#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$repo=Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'src/FastLlm.PciIdentityJoin.ps1')
Add-Type -Path @((Join-Path $repo 'src/WindowsInventory.cs'),(Join-Path $repo 'src/WindowsGpuIdentity.cs'),
    (Join-Path $repo 'src/WindowsPciAddress.cs')) -ErrorAction Stop
$count=0
function Check($condition,$message){if(-not $condition){throw $message};$script:count++}
function Reject($block,$message){$threw=$false;try{& $block | Out-Null}catch{$threw=$true};Check $threw $message}
Check ([Bitworks.FastLlm.WindowsPciAddress]::LayoutIsExpected()) 'D3DKMT Win64 structure sizes differ from expected ABI.'
$single=ConvertFrom-FastLlmPciLocation 'PCI bus 3, device 0, function 0'
Check ($single.bus -eq 3 -and $single.device -eq 0 -and $single.function -eq 0 -and -not $single.segmentExplicit) 'Documented single-segment location did not parse without implying domain evidence.'
$multi=ConvertFrom-FastLlmPciLocation 'PCI segment 2 bus 3, device 0, function 0'
Check ($multi.segment -eq 2 -and $multi.segmentExplicit) 'Documented segment-aware location did not parse.'
Check ($null -eq (ConvertFrom-FastLlmPciLocation 'PCI bus 256, device 0, function 0') -and
       $null -eq (ConvertFrom-FastLlmPciLocation 'PCI bus 3, device 32, function 0') -and
       $null -eq (ConvertFrom-FastLlmPciLocation 'PCI bus 3, device 0, function 8')) 'Out-of-range PCI coordinates were accepted.'
Check ($null -eq (ConvertFrom-FastLlmPciLocation 'on PCI Express Root Port') -and
       $null -eq (ConvertFrom-FastLlmPciLocation 'pci bus 3, device 0, function 0')) 'Localized or non-PCI location was guessed.'
$ids=ConvertFrom-FastLlmPciInstanceId 'PCI\VEN_1002&DEV_744C&SUBSYS_00000000\1'
Check ($ids.vendorId -eq 0x1002 -and $ids.deviceId -eq 0x744c) 'Exact PCI instance ID vendor/device parsing failed.'
Check ($null -eq (ConvertFrom-FastLlmPciInstanceId 'DISPLAY\VEN_1002&DEV_744C') -and
       $null -eq (ConvertFrom-FastLlmPciInstanceId 'PCI\VEN_1002&DEV_744CX')) 'Non-PCI or malformed instance ID was accepted.'
$dxgi=@([pscustomobject]@{Luid='00000001000000ab';VendorId=0x1002;DeviceId=0x744c})
$pnp=@([pscustomobject]@{InstanceId='PCI\VEN_1002&DEV_744C&SUBSYS_00000000\1';LocationInfo='PCI bus 3, device 0, function 0';
    DriverVersion='32.0.31041.1004';LocationError=$null;DriverVersionError=$null})
$kmt=@([pscustomobject]@{Luid='00000001000000ab';Bus=3;Device=0;Function=0;Error=$null})
$result=@(Join-FastLlmPciAddressScope $dxgi $pnp $kmt)
Check ($result.Count -eq 1 -and $result[0].status -eq 'address-scope-dxgi-pnp' -and $result[0].driverVersion -eq '32.0.31041.1004') 'Exact address/PCI IDs did not identify one PnP driver record.'
Check (-not $result[0].pciSegmentKnown -and $null -eq $result[0].ggmlJoin -and $result[0].ggmlJoinReason -eq 'unknown-pci-segment' -and
       -not $result[0].serverProcessBound -and -not $result[0].qualificationApproved) 'Address-scope match was inflated into full BDF/server/qualification identity.'
$pnp[0].LocationInfo='PCI segment 2 bus 3, device 0, function 0'
$result=@(Join-FastLlmPciAddressScope $dxgi $pnp $kmt)
Check ($result[0].status -eq 'address-scope-dxgi-pnp' -and -not $result[0].pciSegmentKnown -and $null -eq $result[0].ggmlJoin) 'Explicit PnP segment was incorrectly attributed to the KMT/DXGI side.'
$pnp[0].LocationInfo='PCI bus 3, device 0, function 0'
$pnp+=($pnp[0] | Select-Object *)
Check ((@(Join-FastLlmPciAddressScope $dxgi $pnp $kmt)[0]).status -eq 'ambiguous-pnp-address') 'Duplicate PnP address was accepted.'
$pnp=@($pnp[0]);$pnp[0].InstanceId='PCI\VEN_10DE&DEV_744C&SUBSYS_00000000\1'
Check ((@(Join-FastLlmPciAddressScope $dxgi $pnp $kmt)[0]).status -eq 'pci-id-mismatch') 'Vendor mismatch was joined by address alone.'
$pnp[0].InstanceId='PCI\VEN_1002&DEV_744C&SUBSYS_00000000\1'
$pnp[0].DriverVersion=$null
Check ((@(Join-FastLlmPciAddressScope $dxgi $pnp $kmt)[0]).status -eq 'missing-driver-version') 'Missing exact driver version was represented as a match.'
$pnp[0].DriverVersion='32.0.31041.1004'
$pnp+=([pscustomobject]@{InstanceId='PCI\VEN_1002&DEV_744C&SUBSYS_00000000\2';LocationInfo=$null;
    DriverVersion='32.0.31041.1004';LocationError='property-unavailable';DriverVersionError=$null})
Check ((@(Join-FastLlmPciAddressScope $dxgi $pnp $kmt)[0]).status -eq 'unlocated-pnp-peer') 'Unlocated same-ID PnP peer was ignored.'
$pnp=@($pnp[0])
$kmt+=([pscustomobject]@{Luid='00000002000000cd';Bus=3;Device=0;Function=0;Error=$null})
Check ((@(Join-FastLlmPciAddressScope $dxgi $pnp $kmt)[0]).status -eq 'ambiguous-kmt-address') 'Duplicate KMT address was accepted.'
$kmt=@($kmt[0]);$dxgi+=($dxgi[0] | Select-Object *)
Check ((@(Join-FastLlmPciAddressScope $dxgi $pnp $kmt)[0]).status -eq 'ambiguous-dxgi-luid') 'Duplicate DXGI LUID was accepted.'
Reject {Join-FastLlmPciAddressScope -Dxgi @(1..65) -Pnp @() -Kmt @()} 'Oversized DXGI inventory was not rejected.'
$tool=Get-Content -LiteralPath (Join-Path $repo 'tools/collect-pci-identity-join.ps1') -Raw
$native=Get-Content -LiteralPath (Join-Path $repo 'src/WindowsPciAddress.cs') -Raw
Check ($tool.Contains('WaitForExit(60000)') -and $tool.Contains('$child.OutputTruncated') -and
       $tool.Contains('Get-FastLlmGgmlVulkanIdentity') -and $tool.Contains('$stable=$beforeJson -ceq $afterJson')) 'Collector lacks bounded isolated execution or stability check.'
Check ($native.Contains('D3DKMTOpenAdapterFromLuid') -and $native.Contains('D3DKMTQueryAdapterInfo') -and
       $native.Contains('D3DKMTCloseAdapter') -and $native.Contains('DllImportSearchPath.System32')) 'KMT reader lacks documented handle/query/close and system DLL restriction.'
Add-Type -Path (Join-Path $repo 'src/ProcessHost.cs') -ErrorAction Stop
foreach($mode in @('single','duplicate','overflow','oversized-record')){
    $child=New-Object Bitworks.FastLlm.ProcessHost
    try{
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=(Get-Process -Id $PID).Path
        $info.Arguments='-NoLogo -NoProfile -File "'+(Join-Path $PSScriptRoot 'helpers/mock-pci-identity-output.ps1')+'" -Mode '+$mode
        $child.Start($info)
        Check ($child.Process.WaitForExit(5000)) "Mock $mode worker exceeded deadline."
        $wait=[Diagnostics.Stopwatch]::StartNew()
        while(-not $child.OutputCompleted -and $wait.ElapsedMilliseconds -lt 5000){Start-Sleep -Milliseconds 10}
        Check $child.OutputCompleted "Mock $mode worker output did not reach EOF."
        if($mode -eq 'single'){
            $parsed=ConvertFrom-FastLlmPciJoinOutput -OutputText ($child.Snapshot()) -WasTruncated $child.OutputTruncated
            Check ($parsed.matches[0].status -eq 'address-scope-dxgi-pnp' -and $null -eq $parsed.matches[0].ggmlJoin) 'Single advisory worker record failed to parse.'
            $parsed.matches[0].ggmlJoin='Vulkan0'
            Reject {Assert-FastLlmPciIdentityDocument $parsed} 'Forged backend join passed advisory schema.'
            $parsed.matches[0].ggmlJoin=$null
            $parsed.qualified='false'
            Reject {Assert-FastLlmPciIdentityDocument $parsed} 'String-valued qualification flag passed advisory schema.'
        }elseif($mode -eq 'duplicate'){
            Reject {ConvertFrom-FastLlmPciJoinOutput -OutputText ($child.Snapshot()) -WasTruncated $child.OutputTruncated} 'Duplicate worker records were accepted.'
        }elseif($mode -eq 'overflow'){
            Check $child.OutputTruncated 'Oversized worker output did not mark truncation.'
            Reject {ConvertFrom-FastLlmPciJoinOutput -OutputText ($child.Snapshot()) -WasTruncated $child.OutputTruncated} 'Truncated worker output was accepted.'
        }else{
            Check (-not $child.OutputTruncated) 'Per-line truncation unexpectedly set total-output flag.'
            Reject {ConvertFrom-FastLlmPciJoinOutput -OutputText ($child.Snapshot()) -WasTruncated $child.OutputTruncated} 'Silently shortened overlong JSON record was accepted.'
        }
    }finally{$child.Dispose()}
}
if($env:OS -ne 'Windows_NT'){
    Reject {[Bitworks.FastLlm.WindowsPciAddress]::Read('00000001000000ab')} 'Native KMT query must reject non-Windows hosts.'
    Write-Host 'SKIP: live KMT/DXGI/SetupAPI GPU calls require Windows after soaks.'
}
Write-Host "$count PCI address-scope identity checks passed; no full BDF or serving-process binding is claimed."
