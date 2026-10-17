#requires -Version 7.0
# Mock-only: runs on any OS. The native layer is replaced by an IPciLinkSource mock.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$repo=Split-Path $PSScriptRoot -Parent
$count=0
function Check($condition,$message){if(-not $condition){throw $message};$script:count++}
function Reject($block,$message){$threw=$false;try{& $block | Out-Null}catch{$threw=$true};Check $threw $message}
$mockSource=@'
using System;
using System.Collections.Generic;
using Bitworks.FastLlm;
public sealed class MockPciLinkSource : IPciLinkSource {
    public string[] Ids = new string[0];
    public Dictionary<string,PciLinkNode> Nodes = new Dictionary<string,PciLinkNode>(StringComparer.OrdinalIgnoreCase);
    public string[] EnumerateDisplayInstanceIds() { return Ids; }
    public PciLinkNode ReadNode(string id) { PciLinkNode n; if (id == "THROW") throw new InvalidOperationException("x"); return Nodes.TryGetValue(id, out n) ? n : null; }
}
'@
# Compile the mock together with the collector so both share one assembly.
$mockFile=Join-Path ([IO.Path]::GetTempPath()) ('MockPciLinkSource-'+[guid]::NewGuid().ToString('N')+'.cs')
[IO.File]::WriteAllText($mockFile,$mockSource)
try{Add-Type -Path @((Join-Path $repo 'src/WindowsPciLink.cs'),$mockFile) -ErrorAction Stop}finally{Remove-Item -LiteralPath $mockFile -Force -ErrorAction SilentlyContinue}
function U($v){[Bitworks.FastLlm.PciLinkProperty]@{Raw=[uint32]$v}}
function T($v){[Bitworks.FastLlm.PciLinkProperty]@{Text=$v}}
function L($v){[Bitworks.FastLlm.PciLinkProperty]@{List=[string[]]$v}}
function Node($id,$parent,$type,$cs,$cw,$ms,$mw,$hw){
    $n=New-Object Bitworks.FastLlm.PciLinkNode
    $n.InstanceId=$id
    if($parent){$n.Parent=T $parent}else{$n.Parent=[Bitworks.FastLlm.PciLinkProperty]::Fail('cr-0x25-property-unavailable',37)}
    if($null -ne $type){$n.DeviceType=U $type}
    if($null -ne $cs){$n.CurrentLinkSpeed=U $cs}
    if($null -ne $cw){$n.CurrentLinkWidth=U $cw}
    if($null -ne $ms){$n.MaxLinkSpeed=U $ms}
    if($null -ne $mw){$n.MaxLinkWidth=U $mw}
    if($hw){$n.HardwareIds=L $hw}
    $n.LocationPaths=L @("PCIROOT(0)#PCI(0101)#PCI(0000)")
    return $n
}
function NewMock($ids){$m=New-Object MockPciLinkSource;$m.Ids=[string[]]$ids;$m}

# --- speed / width / type decoding, raw preserved
$g=$null
Check ([Bitworks.FastLlm.WindowsPciLink]::DecodeSpeed(1,[ref]$g) -eq 'Gen1 2.5GT/s' -and $g -eq 1) 'Gen1 decode'
Check ([Bitworks.FastLlm.WindowsPciLink]::DecodeSpeed(2,[ref]$g) -eq 'Gen2 5GT/s' -and $g -eq 2) 'Gen2 decode'
Check ([Bitworks.FastLlm.WindowsPciLink]::DecodeSpeed(3,[ref]$g) -eq 'Gen3 8GT/s' -and $g -eq 3) 'Gen3 decode'
Check ([Bitworks.FastLlm.WindowsPciLink]::DecodeSpeed(4,[ref]$g) -eq 'Gen4 16GT/s' -and $g -eq 4) 'Gen4 decode'
Check ([Bitworks.FastLlm.WindowsPciLink]::DecodeSpeed(5,[ref]$g) -eq 'Gen5 32GT/s' -and $g -eq 5) 'Gen5 decode'
Check ([Bitworks.FastLlm.WindowsPciLink]::DecodeSpeed(6,[ref]$g) -eq 'Gen6 64GT/s' -and $g -eq 6) 'Gen6 decode'
Check ($null -eq [Bitworks.FastLlm.WindowsPciLink]::DecodeSpeed(0,[ref]$g) -and $null -eq $g -and
       $null -eq [Bitworks.FastLlm.WindowsPciLink]::DecodeSpeed(7,[ref]$g)) 'Unknown speed codes must not decode'
Check ([Bitworks.FastLlm.WindowsPciLink]::DecodeWidth(16) -eq 'x16' -and [Bitworks.FastLlm.WindowsPciLink]::DecodeWidth(4) -eq 'x4' -and
       $null -eq [Bitworks.FastLlm.WindowsPciLink]::DecodeWidth(0) -and $null -eq [Bitworks.FastLlm.WindowsPciLink]::DecodeWidth(3)) 'Width decode'
Check ([Bitworks.FastLlm.WindowsPciLink]::DecodeDeviceType(8) -eq 'BridgePciExpressRootPort' -and
       [Bitworks.FastLlm.WindowsPciLink]::DecodeDeviceType(9) -eq 'BridgePciExpressUpstreamSwitchPort' -and
       [Bitworks.FastLlm.WindowsPciLink]::DecodeDeviceType(2) -eq 'PciExpressEndpoint' -and
       $null -eq [Bitworks.FastLlm.WindowsPciLink]::DecodeDeviceType(99)) 'Device type decode'
Check ([Bitworks.FastLlm.WindowsPciLink]::ParseVendorId('PCI\VEN_1002&DEV_744C&SUBSYS_0\1') -eq '1002' -and
       $null -eq [Bitworks.FastLlm.WindowsPciLink]::ParseVendorId('ACPI\PNP0A08\0') -and
       $null -eq [Bitworks.FastLlm.WindowsPciLink]::ParseVendorId('PCI\VEN_ZZZZ&DEV_1')) 'Vendor parse'

# --- null-vs-zero, non-AMD marking, root port, level separation
$m=NewMock @('PCI\VEN_1002&DEV_744C\A','PCI\VEN_10DE&DEV_2684\B')
$m.Nodes['PCI\VEN_1002&DEV_744C\A']=Node 'PCI\VEN_1002&DEV_744C\A' 'PCI\VEN_1002&DEV_1478\U' 2 2 4 4 16 @('PCI\VEN_1002&DEV_744C')
$m.Nodes['PCI\VEN_1002&DEV_1478\U']=Node 'PCI\VEN_1002&DEV_1478\U' 'PCI\VEN_1022&DEV_1634\R' 9 $null $null 4 16 $null
$m.Nodes['PCI\VEN_1022&DEV_1634\R']=Node 'PCI\VEN_1022&DEV_1634\R' $null 8 4 8 4 16 @('PCI\VEN_1022&DEV_1634')
$m.Nodes['PCI\VEN_10DE&DEV_2684\B']=Node 'PCI\VEN_10DE&DEV_2684\B' $null 2 0 0 4 16 $null
$r=@([Bitworks.FastLlm.WindowsPciLink]::Collect($m))
Check ($r.Count -eq 2) 'Two display devices expected'
Check ($r[0].IsAmd -and $r[0].VendorClassification -eq 'amd' -and -not $r[1].IsAmd -and $r[1].VendorClassification -eq 'non-amd') 'AMD / non-AMD marking'
Check ($r[0].Device.CurrentLinkSpeed.Raw -eq 2 -and $r[0].Device.CurrentLinkSpeed.Generation -eq 2 -and $r[0].Device.CurrentLinkWidth.Decoded -eq 'x4' -and
       $r[0].Device.MaxLinkSpeed.Generation -eq 4 -and $r[0].Device.MaxLinkWidth.Decoded -eq 'x16') 'Device level link properties'
Check ($r[0].Ancestors.Count -eq 2 -and $r[0].Ancestors[0].Level -eq 1 -and $r[0].Ancestors[1].Level -eq 2 -and $r[0].AncestorStopReason -eq 'no-parent') 'Ancestor chain and levels'
$up=$r[0].Ancestors[0]
Check ($null -eq $up.CurrentLinkSpeed.Raw -and $null -ne $up.CurrentLinkSpeed.Error -and $null -eq $up.CurrentLinkWidth.Raw -and $up.MaxLinkSpeed.Generation -eq 4) 'Missing property must be null with error, never zero'
Check ($r[0].RootPortInstanceId -eq 'PCI\VEN_1022&DEV_1634\R' -and $r[0].RootPortLocationPath -eq 'PCIROOT(0)#PCI(0101)#PCI(0000)' -and $r[0].Ancestors[1].VendorId -eq '1022') 'Raw root-port data'
Check ($r[0].Device.CurrentLinkSpeed.Raw -ne $r[0].Ancestors[1].CurrentLinkSpeed.Raw -or $r[0].Device.CurrentLinkWidth.Raw -ne $r[0].Ancestors[1].CurrentLinkWidth.Raw) 'Levels stay separate (fixture differs per level)'
Check ($r[1].Device.CurrentLinkSpeed.Raw -eq 0 -and $null -eq $r[1].Device.CurrentLinkSpeed.Decoded -and $r[1].Device.CurrentLinkSpeed.DecodeNote -eq 'unknown-speed-code') 'Reported zero stays zero, undecoded'
$members=$r[0] | Get-Member -MemberType Property | ForEach-Object Name
Check (-not ($members -match 'SlotLink|Attachment|CpuAttached|Chipset')) 'No slot-link or CPU-vs-chipset inference fields'

# --- ancestor-walk bounds
$m=NewMock @('D0')
$m.Nodes['D0']=Node 'D0' 'P1' 2 1 1 1 1 $null
for($i=1;$i -le 9;$i++){$m.Nodes["P$i"]=Node "P$i" "P$($i+1)" 10 1 1 1 1 $null}
$r=@([Bitworks.FastLlm.WindowsPciLink]::Collect($m))
Check ($r[0].Ancestors.Count -eq 6 -and $r[0].AncestorsTruncated -and $r[0].AncestorStopReason -eq 'max-depth') 'Ancestor walk must stop at 6 levels'
$m=NewMock @('C0')
$m.Nodes['C0']=Node 'C0' 'C1' 2 1 1 1 1 $null
$m.Nodes['C1']=Node 'C1' 'C0' 10 1 1 1 1 $null
$r=@([Bitworks.FastLlm.WindowsPciLink]::Collect($m))
Check ($r[0].AncestorStopReason -eq 'cycle' -and $r[0].Ancestors.Count -eq 1) 'Parent cycle must stop'
$m=NewMock @('M0')
$m.Nodes['M0']=Node 'M0' 'GONE' 2 1 1 1 1 $null
$r=@([Bitworks.FastLlm.WindowsPciLink]::Collect($m))
Check ($r[0].AncestorStopReason -eq 'read-error' -and $r[0].Error -eq 'ancestor-read-returned-null') 'Unreadable ancestor must be reported'
$m=NewMock @('THROW')
$r=@([Bitworks.FastLlm.WindowsPciLink]::Collect($m))
Check ($r[0].Error -like 'read-failed:*' -and $null -eq $r[0].Device.CurrentLinkSpeed.Raw) 'Read exception must be reported not thrown'
$m=NewMock @(1..129 | ForEach-Object {"X$_"})
Reject {[Bitworks.FastLlm.WindowsPciLink]::Collect($m)} 'Oversized device list not rejected'
# The native platform-refusal assertion applies only on non-Windows hosts.
if(-not $IsWindows){Reject {[Bitworks.FastLlm.WindowsPciLink]::Collect()} 'Native Collect must reject non-Windows host'}

# --- wrapper helpers: schema shape and overwrite refusal
. (Join-Path $repo 'tools/collect-pci-link.ps1') -OutputPath '/unused.json' -LibraryOnly
$m=NewMock @('PCI\VEN_1002&DEV_744C\A')
$m.Nodes['PCI\VEN_1002&DEV_744C\A']=Node 'PCI\VEN_1002&DEV_744C\A' $null 2 2 4 4 16 $null
$devices=@([Bitworks.FastLlm.WindowsPciLink]::Collect($m))
$report=New-PciLinkReport -Devices $devices -HostName 'bench' -Account 'DOM\user' -SourceSha256 @{'src/WindowsPciLink.cs'='ab'}
$tmpBase=[IO.Path]::GetTempPath().TrimEnd('/','\')
if(-not $IsWindows){$tmpBase=(& realpath $tmpBase)}  # macOS temp lives behind a /var symlink
$tmp=Join-Path $tmpBase ('pci-link-tests-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $out=Join-Path $tmp 'report.json'
    $null=Write-PciLinkReport -Report $report -Path $out
    $doc=Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
    Check ($doc.schema -eq 'fastllm.pci-link.v1' -and $doc.hostName -eq 'bench' -and $doc.account -eq 'DOM\user' -and
           (Get-Content -LiteralPath $out -Raw) -match '"recordedAtUtc": "\d{4}-\d\d-\d\dT[^"]*Z"' -and $doc.deviceCount -eq 1) 'Schema header shape'
    Check ($null -ne $doc.collector.sourceSha256 -and @($doc.devices).Count -eq 1 -and $null -ne $doc.devices[0].PSObject.Properties['Ancestors'] -and
           $doc.devices[0].Device.CurrentLinkSpeed.Raw -eq 2 -and $doc.devices[0].Device.CurrentLinkSpeed.Decoded -eq 'Gen2 5GT/s') 'Devices/ancestors shape'
    Check ($null -eq $doc.devices[0].Device.HardwareIds.List -and $null -ne $doc.devices[0].Device.HardwareIds.Error) 'Null property serialized as null with error'
    Reject {Write-PciLinkReport -Report $report -Path $out} 'Existing report must not be overwritten'
    Reject {Write-PciLinkReport -Report $report -Path (Join-Path $tmp 'report.txt')} 'Non-.json path accepted'
    Reject {Write-PciLinkReport -Report $report -Path 'relative.json'} 'Relative path accepted'
    Reject {Write-PciLinkReport -Report $report -Path (Join-Path $tmp 'missing-dir/x.json')} 'Missing parent accepted'
    if(-not $IsWindows){
        $real=Join-Path $tmp 'real';New-Item -ItemType Directory $real|Out-Null
        $link=Join-Path $tmp 'link';New-Item -ItemType SymbolicLink -Path $link -Target $real|Out-Null
        Reject {Write-PciLinkReport -Report $report -Path (Join-Path $link 'x.json')} 'Reparse-point parent accepted'
    }
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

# --- static: no CIM/WMI, no process control, no admin requirement
foreach($f in @('src/WindowsPciLink.cs','tools/collect-pci-link.ps1')){
    $text=Get-Content -LiteralPath (Join-Path $repo $f) -Raw
    Check ($text -notmatch '(?i)Get-CimInstance|Get-WmiObject|Invoke-CimMethod|Invoke-WmiMethod|ManagementObjectSearcher|Win32_|Start-Process|Stop-Process|Set-Service|RunAs') "$f uses forbidden CIM/WMI/process API"
}
$native=Get-Content -LiteralPath (Join-Path $repo 'src/WindowsPciLink.cs') -Raw
Check ($native.Contains('3ab22e31-8264-4b4e-9af5-a8d2d8e33e62') -and $native.Contains('DllImportSearchPath.System32') -and $native.Contains('CM_Get_DevNode_PropertyW')) 'Native reader lacks documented GUID/System32 restriction'
Write-Host "pci-link-tests: $count checks passed"
