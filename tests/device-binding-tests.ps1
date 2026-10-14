#requires -Version 5.1
# Mock-only tests for W03 Phase A: per-start device binding, `record` and `enforce` modes (-DeviceBinding record|enforce).
# Every fixture is synthetic (no real LUID, PnP instance, UUID or host name). The join rows are produced by the real collector
# join function (tools/collect-vulkan-luid-join.ps1 -LibraryOnly) over synthetic observation rows, so the fixtures cannot drift
# from what the collector can actually emit. No Vulkan, no model and no GPU work: the supervised starts run against the mock server.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force
$module=Get-Module FastLlm
. (Join-Path $root 'tools/collect-vulkan-luid-join.ps1') -OutputPath 'unused.json' -LibraryOnly
$count=0
function Check($Condition,[string]$Message){if(-not [bool]$Condition){Write-Host "FAIL: $Message";throw "FAIL: $Message"};$script:count++;Write-Host "PASS: $Message"}
$MiB=[long]1048576;$GiB=[long]1073741824
# Every fast-llm-devbind-* scratch folder of THIS run is tracked here and removed in a finally, on success and on failure.
$devbindFolders=New-Object 'Collections.Generic.List[string]'
function Remove-DevbindFolders{
    foreach($path in @($devbindFolders)){
        for($try=0;$try -lt 10 -and (Test-Path -LiteralPath $path);$try++){
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
            if(Test-Path -LiteralPath $path){Start-Sleep -Milliseconds 300}
        }
    }
}

# ---------- synthetic observation rows ----------
$luidA='00000000000a1b2c';$luidB='00000000000a1b3d';$luidC='00000000000a1b4e'
$uuidA='aaaaaaaa-0000-0000-0000-00000000000a';$uuidB='bbbbbbbb-0000-0000-0000-00000000000b';$uuidC='cccccccc-0000-0000-0000-00000000000c'
$pnpA='PCI\VEN_1002&DEV_744C&SUBSYS_00000000&REV_C8\4&1&0&0008'
$pnpB='PCI\VEN_1002&DEV_744C&SUBSYS_00000000&REV_C8\4&1&0&0010'
$locA='PCI bus 3, device 0, function 0';$locB='PCI bus 7, device 0, function 0'
$xt='AMD Radeon RX 7900 XT';$xtx='AMD Radeon RX 7900 XTX'
function Vk($Index,$Luid,$Uuid,$Vendor,$Device,$Name,$Type=2,$Driver=1,$Valid=$true,$Node=1){
    [pscustomobject]@{index=$Index;deviceUuid=$Uuid;deviceLuid=$Luid;deviceLuidValid=$Valid;deviceNodeMask=$Node;vendorId=$Vendor;deviceId=$Device;deviceName=$Name;deviceType=$Type;driverId=$Driver;pciBusInfoAdvertised=$false;pciBusInfo=$null}
}
function Dx($Index,$Luid,$Vendor,$Device){[pscustomobject]@{index=$Index;adapterLuid=$Luid;vendorId=$Vendor;deviceId=$Device;flags=0}}
function Km($Luid,$Bus,$Dev,$Fn){[pscustomobject]@{luid=$Luid;bus=$Bus;device=$Dev;function=$Fn;error=$null}}
function Sa($Id,$Loc,$Version='32.0.1.1',$Name=$xt,$Vendor='1002',$Device='744C'){
    [pscustomobject]@{instanceId=$Id;description=$Name;locationInfo=$Loc;driverVersion=$Version;driverProvider='AMD'
        hardwareIds=@("PCI\VEN_$Vendor&DEV_$Device&SUBSYS_00000000&REV_C8","PCI\VEN_$Vendor&DEV_$Device&SUBSYS_00000000","PCI\VEN_$Vendor&DEV_$Device&REV_C8","PCI\VEN_$Vendor&DEV_$Device")}
}
function Hp($Index,$Size,$Local){[pscustomobject]@{heapIndex=$Index;sizeBytes=[long]$Size;flags=$(if($Local){1}else{0});deviceLocal=$Local}}
function New-Report {
    param([object[]]$Vulkan,[object[]]$DxgiRows,[object[]]$KmtRows,[object[]]$SetupRows,[hashtable]$Heaps=@{})
    $joins=@(Join-VulkanLuidDevices -Vulkan $Vulkan -Dxgi $DxgiRows -Kmt $KmtRows -SetupApi $SetupRows)
    $rows=@()
    foreach($v in $Vulkan){
        if($Heaps.ContainsKey([int]$v.index)){$h=@($Heaps[[int]$v.index])}else{$h=@((Hp 0 (20464*$MiB) $true),(Hp 1 (16*$GiB) $false))}
        $rows+=[pscustomobject]@{index=$v.index;deviceUuid=$v.deviceUuid;deviceLuid=$v.deviceLuid;memoryBudgetAdvertised=$true;status='ok';heaps=$h;identityMatchesInitialEnumeration=$true}
    }
    [pscustomobject]@{
        schema='synthetic';collector=[pscustomobject]@{sourceSha256=[pscustomobject]@{'tools/collect-vulkan-luid-join.ps1'=('a'*64);'src/WindowsVulkanLuidJoin.cs'=('b'*64);'src/WindowsPciAddress.cs'=('c'*64)}}
        devices=$Vulkan;dxgiAdapters=$DxgiRows;kmtAddresses=$KmtRows;setupApiDisplayDevices=$SetupRows;joins=$joins
        budgetSamples=@([pscustomobject]@{sampleIndex=0;vulkan=$rows})
    }
}
function New-XtReport($Version='32.0.1.1',$Loc=$locA,$Heaps=@{}){New-Report @(Vk 0 $luidA $uuidA 0x1002 0x744c $xt) @(Dx 3 $luidA 0x1002 0x744c) @(Km $luidA 3 0 0) @(Sa $pnpA $Loc $Version) $Heaps}
function New-Plan($Name,$Vram,$Backend='Vulkan'){[pscustomobject]@{backend=$Backend;selectedAdapters=@([pscustomobject]@{device='Vulkan0';name=$Name;vramMiB=$Vram})}}
function Bind($Plan,$Report,$Bar=$null){& $module {param($P,$R,$B) Resolve-FastLlmDeviceBindingFromReport -Plan $P -Report $R -BarDecision $B} $Plan $Report $Bar}
function Pick($Devices){& $module {param($D) Select-FastLlmGgmlVulkanDevice -Devices $D} $Devices}
function Entry($Index,$Uuid,$Luid,$LuidValid,$Vendor,$Driver){[pscustomobject]@{index=$Index;deviceUuid=$Uuid;deviceLuid=$Luid;deviceLuidValid=$LuidValid;vendorId=$Vendor;driverId=$Driver}}

# ---------- Phase A binding over a collector report ----------
$r=Bind (New-Plan $xt 20464) (New-XtReport)
Check ($r.status -ceq 'bound' -and $null -eq $r.reason -and $r.rawDeviceCount -eq 1 -and $r.distinctAdapterCount -eq 1 -and $r.duplicateLuidEntries -eq 0 -and $r.planMatch.name -and $r.planMatch.totalMiB -and $r.barSnapshot -ceq 'not-applicable') 'single dGPU, ReBAR on (one 20,464 MiB DEVICE_LOCAL heap): bound, plan matches'
Check ($r.device.rawVulkanIndex -eq 0 -and $r.device.name -ceq $xt -and $r.device.deviceType -eq 2 -and $r.device.pciIds -ceq 'VEN_1002&DEV_744C&SUBSYS_00000000&REV_C8' -and $r.device.pnpInstanceId -ceq $pnpA -and $r.device.driverVersion -ceq '32.0.1.1' -and $r.device.ggmlTotalMiB -eq 20464 -and $r.device.luidMatched -eq $true) 'the bound device carries index, name, type, the most specific PCI ids, PnP id, driver version, ggml total and luidMatched'
Check (-not (($r | ConvertTo-Json -Depth 8) -match $luidA)) 'the binding record stores no LUID value'

$xtxHeaps=@{0=@((Hp 0 (24304*$MiB) $true),(Hp 1 (256*$MiB) $true),(Hp 2 (31*$GiB) $false))}
$xtxReport=New-Report @(Vk 0 $luidA $uuidA 0x1002 0x744c $xtx) @(Dx 3 $luidA 0x1002 0x744c) @(Km $luidA 3 0 0) @(Sa $pnpA $locA '32.0.1.1' $xtx) $xtxHeaps
$r=Bind (New-Plan $xtx 24560) $xtxReport
Check ($r.status -ceq 'bound' -and $r.planMatch.totalMiB -and $r.device.ggmlTotalMiB -eq 24560) 'ReBAR off: 24,304 + 256 MiB DEVICE_LOCAL heaps sum to the plan total 24,560 (bound)'
$r=Bind (New-Plan $xtx 24304) $xtxReport
Check ($r.status -ceq 'unavailable' -and $r.reason -ceq 'plan-mismatch' -and $r.planMatch.name -and -not $r.planMatch.totalMiB) 'a plan total that ignores the 256 MiB heap is plan-mismatch'
$r=Bind (New-Plan $xt 20464) $xtxReport
Check ($r.status -ceq 'unavailable' -and $r.reason -ceq 'plan-mismatch' -and -not $r.planMatch.name) 'a different plan card name is plan-mismatch'
$r=Bind (New-Plan "  amd radeon RX 7900 xt " 20464) (New-XtReport)
Check ($r.status -ceq 'bound') 'plan name comparison is the planner''s: trim and ignore case'
$r=Bind (New-Plan 'AMD Radeon  RX 7900 XT' 20464) (New-XtReport)
Check ($r.status -ceq 'unavailable' -and $r.reason -ceq 'plan-mismatch' -and -not $r.planMatch.name) 'plan name comparison does not collapse internal spaces (nothing more lenient than the planner)'
$twoAdapters=[pscustomobject]@{backend='Vulkan';selectedAdapters=@([pscustomobject]@{name=$xt;vramMiB=20464},[pscustomobject]@{name=$xt;vramMiB=20464})}
$r=Bind $twoAdapters (New-XtReport)
Check ($r.status -ceq 'unavailable' -and $r.reason -ceq 'plan-mismatch' -and -not $r.planMatch.name) 'a plan that selects two adapters is plan-mismatch'
$noAdapters=[pscustomobject]@{backend='Vulkan';selectedAdapters=@()}
Check ((Bind $noAdapters (New-XtReport)).reason -ceq 'plan-mismatch') 'a plan with no selected adapter is plan-mismatch'
$bytesReport=New-Report @(Vk 0 $luidA $uuidA 0x1002 0x744c $xt) @(Dx 3 $luidA 0x1002 0x744c) @(Km $luidA 3 0 0) @(Sa $pnpA $locA) @{0=@((Hp 0 (20464*$MiB+7) $true))}
Check ((Bind (New-Plan $xt 20464) $bytesReport).status -ceq 'bound') 'the ggml total is floor(bytes / 1 MiB): a few extra bytes do not change it'
$json=(New-XtReport) | ConvertTo-Json -Depth 12 | ConvertFrom-Json
Check ((Bind (New-Plan $xt 20464) $json).status -ceq 'bound') 'a report that went through JSON (single-element arrays, parsed objects) binds the same'

# topology
$igpu=Vk 0 $luidB $uuidB 0x1002 0x164e 'AMD Radeon(TM) Graphics' 1 1
$dgpu=Vk 1 $luidA $uuidA 0x1002 0x744c $xt
$mixed=New-Report @($igpu,$dgpu) @((Dx 2 $luidB 0x1002 0x164e),(Dx 3 $luidA 0x1002 0x744c)) @((Km $luidB 5 0 0),(Km $luidA 3 0 0)) @((Sa $pnpA $locA),(Sa 'PCI\VEN_1002&DEV_164E&SUBSYS_00000000&REV_C1\4&1&0&0028' 'PCI bus 5, device 0, function 0' '32.0.1.1' 'AMD Radeon(TM) Graphics' '1002' '164E'))
$r=Bind (New-Plan $xt 20464) $mixed
Check ($r.status -ceq 'not-supported-topology' -and $r.reason -ceq 'multiple-adapters' -and $r.rawDeviceCount -eq 2 -and $r.distinctAdapterCount -eq 2 -and $null -eq $r.device) 'an iGPU first plus a dGPU is not-supported-topology / multiple-adapters'
$pair=New-Report @((Vk 0 $luidA $uuidA 0x1002 0x744c $xt),(Vk 1 $luidB $uuidB 0x1002 0x744c $xt)) @((Dx 3 $luidA 0x1002 0x744c),(Dx 4 $luidB 0x1002 0x744c)) @((Km $luidA 3 0 0),(Km $luidB 7 0 0)) @((Sa $pnpA $locA),(Sa $pnpB $locB))
$r=Bind (New-Plan $xt 20464) $pair
Check ($r.status -ceq 'not-supported-topology' -and $r.reason -ceq 'multiple-adapters' -and $r.distinctAdapterCount -eq 2) 'an identical pair is not-supported-topology'
$withCpu=New-Report @((Vk 0 $luidA $uuidA 0x1002 0x744c $xt),(Vk 1 $luidC $uuidC 0x10005 0 'llvmpipe' 4 13 $false)) @(Dx 3 $luidA 0x1002 0x744c) @(Km $luidA 3 0 0) @(Sa $pnpA $locA)
$r=Bind (New-Plan $xt 20464) $withCpu
Check ($r.status -ceq 'bound' -and $r.rawDeviceCount -eq 1) 'a CPU (type 4) Vulkan device is not a raw device'
$r=Bind (New-Plan $xt 20464) ([pscustomobject]@{devices=@((Vk 0 $luidC $uuidC 0x10005 0 'llvmpipe' 4 13 $false));joins=@();setupApiDisplayDevices=@();budgetSamples=@()})
Check ($r.status -ceq 'unavailable' -and $r.reason -ceq 'no-vulkan-device' -and $r.rawDeviceCount -eq 0) 'only a CPU device (or none) is unavailable / no-vulkan-device'
Check ((Bind (New-Plan $xt 20464) ([pscustomobject]@{})).reason -ceq 'no-vulkan-device') 'a report without devices is no-vulkan-device'

# duplicate entries of one adapter: the real collector marks a shared LUID ambiguous on its vulkan hop, so Phase A reports it as such
$dozen=New-Report @((Vk 0 $luidA $uuidA 0x1002 0x744c $xt 2 1),(Vk 1 $luidA $uuidA 0x1002 0x744c $xt 2 23)) @(Dx 3 $luidA 0x1002 0x744c) @(Km $luidA 3 0 0) @(Sa $pnpA $locA)
$r=Bind (New-Plan $xt 20464) $dozen
Check ($r.distinctAdapterCount -eq 1 -and $r.duplicateLuidEntries -eq 1 -and $r.rawDeviceCount -eq 2) 'a Dozen entry sharing the dGPU LUID is one adapter with duplicateLuidEntries 1'
Check ($r.status -ceq 'ambiguous' -and $r.reason -ceq 'join-vulkan-ambiguous' -and $r.joinReason -ceq 'vulkan-luid-shared-by-multiple-devices' -and $null -eq $r.device) 'the collector marks both entries of a shared LUID ambiguous (vulkan hop), so the Phase A result is ambiguous / join-vulkan-ambiguous, never a guessed bound'

# invalid LUID
$badLuid=New-Report @(Vk 0 $null $uuidA 0x1002 0x744c $xt 2 1 $false) @(Dx 3 $luidA 0x1002 0x744c) @(Km $luidA 3 0 0) @(Sa $pnpA $locA)
$r=Bind (New-Plan $xt 20464) $badLuid
Check ($r.status -ceq 'unavailable' -and $r.reason -ceq 'luid-invalid') 'an invalid LUID is unavailable / luid-invalid'
$badSecond=New-Report @((Vk 0 $luidA $uuidA 0x1002 0x744c $xt),(Vk 1 $null $uuidB 0x1002 0x164e 'AMD Radeon(TM) Graphics' 1 1 $false)) @(Dx 3 $luidA 0x1002 0x744c) @(Km $luidA 3 0 0) @(Sa $pnpA $locA)
Check ((Bind (New-Plan $xt 20464) $badSecond).reason -ceq 'luid-invalid') 'any non-CPU raw device without a valid LUID makes the binding luid-invalid'

# collector hop failures follow the collector's own join
$ambSetup=New-Report @(Vk 0 $luidA $uuidA 0x1002 0x744c $xt) @(Dx 3 $luidA 0x1002 0x744c) @(Km $luidA 3 0 0) @((Sa $pnpA $locA),(Sa $pnpB $locA))
$r=Bind (New-Plan $xt 20464) $ambSetup
Check ($r.status -ceq 'ambiguous' -and $r.reason -ceq 'join-setupApi-ambiguous' -and $r.joinReason -ceq 'setupapi-multiple-location-matches') 'an ambiguous SetupAPI hop is ambiguous / join-setupApi-ambiguous'
$noDxgi=New-Report @(Vk 0 $luidA $uuidA 0x1002 0x744c $xt) @() @() @(Sa $pnpA $locA)
$r=Bind (New-Plan $xt 20464) $noDxgi
Check ($r.status -ceq 'unavailable' -and $r.reason -ceq 'join-dxgi-unavailable' -and $r.joinReason -ceq 'dxgi-luid-not-found') 'a missing DXGI adapter is unavailable / join-dxgi-unavailable'
$noKmt=New-Report @(Vk 0 $luidA $uuidA 0x1002 0x744c $xt) @(Dx 3 $luidA 0x1002 0x744c) @() @(Sa $pnpA $locA)
Check ((Bind (New-Plan $xt 20464) $noKmt).reason -ceq 'join-kmt-unavailable') 'a missing D3DKMT address is unavailable / join-kmt-unavailable'

# BAR snapshot agreement
$autoNoPnp=[pscustomobject]@{requested='auto';effective='off';reason='rebar-on-no-mitigation-needed'}
$r=Bind (New-Plan $xt 20464) (New-XtReport) $autoNoPnp
Check ($r.status -ceq 'bound' -and $r.barSnapshot -ceq 'not-available') 'a BAR auto decision without a PnP instance gives barSnapshot not-available'
$r=Bind (New-Plan $xt 20464) (New-XtReport) ([pscustomobject]@{requested='auto';pnpInstanceId=$pnpA.ToLowerInvariant()})
Check ($r.status -ceq 'bound' -and $r.barSnapshot -ceq 'agree') 'a BAR auto decision on the same PnP instance (case-insensitive) agrees'
$r=Bind (New-Plan $xt 20464) (New-XtReport) ([pscustomobject]@{requested='auto';pnpInstanceId=$pnpB})
Check ($r.status -ceq 'unavailable' -and $r.reason -ceq 'snapshot-disagreement' -and $r.barSnapshot -ceq 'disagree') 'a BAR auto decision on a different PnP instance is unavailable / snapshot-disagreement'
$r=Bind (New-Plan $xt 20464) (New-XtReport) ([pscustomobject]@{requested='on';pnpInstanceId=$pnpB})
Check ($r.status -ceq 'bound' -and $r.barSnapshot -ceq 'not-applicable') 'a non-auto BAR policy never takes part in the snapshot comparison'
$r=Bind (New-Plan $xt 20464) (New-XtReport) $null
Check ($r.barSnapshot -ceq 'not-applicable') 'no BAR decision at all is not-applicable'
$liveDecision=& $module {Resolve-FastLlmVulkanBarMitigation -Plan ([pscustomobject]@{backend='Vulkan';engineVersion='b10698';selectedAdapters=@()}) -Requested 'on' -InstallRoot ''}
$offDecision=& $module {Resolve-FastLlmVulkanBarMitigation -Plan ([pscustomobject]@{backend='Vulkan'}) -Requested 'off' -InstallRoot ''}
Check ($null -eq $liveDecision.PSObject.Properties['pnpInstanceId'] -and $null -eq $offDecision.PSObject.Properties['pnpInstanceId']) 'the real BAR decision object exposes no PnP instance, so on a live start barSnapshot is never agree or disagree'

# ---------- ggml's entry choice among the entries of one GPU ----------
function Kept($Entries){,@(Pick $Entries)}
$k=Kept @((Entry 0 $uuidA $luidA $true 4098 1),(Entry 1 $uuidA $luidA $true 4098 3))
Check ($k.Count -eq 1 -and $k[0].index -eq 1) 'AMD: RADV (priority 1) replaces AMD proprietary (priority 3)'
$k=Kept @((Entry 0 $uuidA $luidA $true 4098 3),(Entry 1 $uuidA $luidA $true 4098 1))
Check ($k.Count -eq 1 -and $k[0].index -eq 0) 'AMD: RADV kept when proprietary comes later'
$k=Kept @((Entry 0 $uuidA $luidA $true 4098 2),(Entry 1 $uuidA $luidA $true 4098 1))
Check ($k[0].index -eq 0) 'AMD: open source (2) is kept over proprietary (3), and a later proprietary never replaces it'
$k=Kept @((Entry 0 $uuidA $luidA $true 4098 23),(Entry 1 $uuidA $luidA $true 4098 1))
Check ($k[0].index -eq 1) 'a later AMD proprietary driver replaces an earlier Dozen entry'
$k=Kept @((Entry 0 $uuidA $luidA $true 4098 1),(Entry 1 $uuidA $luidA $true 4098 23))
Check ($k[0].index -eq 0) 'a later Dozen entry never replaces the AMD driver'
$k=Kept @((Entry 0 $uuidA $luidA $true 4098 1),(Entry 1 $uuidA $luidA $true 4098 1))
Check ($k[0].index -eq 0) 'equal priorities keep the earlier entry'
$k=Kept @((Entry 0 $uuidA $luidA $true 4098 99),(Entry 1 $uuidA $luidA $true 4098 23))
Check ($k[0].index -eq 1) 'an unknown driver id (max int) is replaced by Dozen (100)'
$k=Kept @((Entry 0 $uuidA $luidA $true 4098 99),(Entry 1 $uuidA $luidA $true 4098 98))
Check ($k[0].index -eq 0) 'two unknown driver ids are equal and keep the earlier entry'
$k=Kept @((Entry 0 $uuidA $luidA $true 4098 $null),(Entry 1 $uuidA $luidA $true 4098 1))
Check ($k[0].index -eq 1) 'a missing driver id counts as max int'
$k=Kept @((Entry 0 $uuidA $luidA $true 32902 5),(Entry 1 $uuidA $luidA $true 32902 6))
Check ($k[0].index -eq 1) 'Intel: open source MESA (1) beats proprietary Windows (2)'
$k=Kept @((Entry 0 $uuidA $luidA $true 4318 24),(Entry 1 $uuidA $luidA $true 4318 4))
Check ($k[0].index -eq 1) 'NVIDIA: proprietary (1) beats NVK (2)'
$k=Kept @((Entry 0 $uuidA $luidA $true 20803 18),(Entry 1 $uuidA $luidA $true 20803 8))
Check ($k[0].index -eq 1) 'Qualcomm: proprietary (1) beats Turnip (2)'
$k=Kept @((Entry 0 $uuidA $luidA $true 4318 4),(Entry 1 $uuidA $luidA $true 4098 3))
Check ($k[0].index -eq 0) 'the priority table is chosen by the kept entry''s vendor'
$k=Kept @((Entry 0 $uuidA $luidA $true 4098 1),(Entry 1 $uuidA $luidB $true 4098 3))
Check ($k.Count -eq 1) 'an equal UUID with a different LUID is the same GPU'
$k=Kept @((Entry 0 $uuidA $luidA $true 4098 1),(Entry 1 $uuidB $luidA $true 4098 3))
Check ($k.Count -eq 1) 'an equal valid LUID with a different UUID is the same GPU'
$k=Kept @((Entry 0 $uuidA $luidA $false 4098 1),(Entry 1 $uuidB $luidA $true 4098 3))
Check ($k.Count -eq 2) 'an equal LUID counts only when both LUIDs are valid'
$k=Kept @((Entry 0 $uuidA $luidA $true 4098 1),(Entry 1 $uuidB $luidB $true 4098 1),(Entry 2 $uuidA $luidA $true 4098 3))
Check ($k.Count -eq 2) 'a third entry of the first GPU is grouped with it, not counted as a third adapter'

# ---------- DEVICE_LOCAL total ----------
function LocalTotal($Report,[int]$Index){& $module {param($R,$I) Get-FastLlmDeviceBindingLocalTotalMiB -Report $R -DeviceIndex $I} $Report $Index}
$bytes=New-Report @(Vk 0 $luidA $uuidA 0x1002 0x744c $xt) @(Dx 3 $luidA 0x1002 0x744c) @(Km $luidA 3 0 0) @(Sa $pnpA $locA) @{0=@((Hp 0 (24304*$MiB+1) $true),(Hp 1 (256*$MiB+5) $true),(Hp 2 (8*$GiB) $false))}
Check ((LocalTotal $bytes 0) -eq 24560) 'the DEVICE_LOCAL total is floor((24,304 MiB + 1) + (256 MiB + 5)) / MiB = 24,560, host heaps excluded'
Check ($null -eq (LocalTotal $bytes 5)) 'a device index without a sample row has no total'
Check ($null -eq (LocalTotal (New-Report @(Vk 0 $luidA $uuidA 0x1002 0x744c $xt) @() @() @() @{0=@((Hp 0 (8*$GiB) $false))}) 0)) 'no DEVICE_LOCAL heap means no total'

try {
# ---------- identity fingerprint and the change line ----------
$idRoot=Join-Path ([IO.Path]::GetTempPath()) ('fast-llm-devbind-id-'+[Guid]::NewGuid().ToString('N'))
$devbindFolders.Add($idRoot)
New-Item -ItemType Directory -Path $idRoot | Out-Null
function Ident($Report){& $module {param($R) Get-FastLlmDeviceIdentityFromReport -Report $R} $Report}
function Save-Ident($Identity,[string]$Dir){& $module {param($D,$I) Write-FastLlmDeviceIdentityRecord -InstallRoot $D -Identity $I} $Dir $Identity}
function Load-Ident([string]$Dir){& $module {param($D) Read-FastLlmDeviceIdentityRecord -InstallRoot $D} $Dir}
function Compare-Ident($Stored,$Current){& $module {param($S,$C) Compare-FastLlmDeviceIdentity -Stored $S -Current $C} $Stored $Current}
$base=Ident (New-XtReport)
Check ($base.fingerprint -cmatch '^[0-9a-f]{64}$' -and $base.adapters.Count -eq 1 -and $base.adapters[0].name -ceq $xt -and $base.adapters[0].pciIds -ceq 'VEN_1002&DEV_744C&SUBSYS_00000000&REV_C8' -and $base.adapters[0].driverVersion -ceq '32.0.1.1' -and $base.adapters[0].slotHash -cmatch '^[0-9a-f]{64}$') 'the identity is the present AMD adapter: PCI ids, name, driver and a slot hash'
Check (-not (($base | ConvertTo-Json -Depth 6) -match 'PCI bus')) 'the slot key itself is never part of the identity'
Check ((Ident (New-XtReport)).fingerprint -ceq $base.fingerprint) 'the fingerprint is deterministic'
Check ((Ident (New-XtReport -Version '32.0.2.2')).fingerprint -cne $base.fingerprint -and (Ident (New-XtReport -Loc $locB)).fingerprint -cne $base.fingerprint) 'the fingerprint changes with the driver version and with the slot'
$nonAmd=New-Report @(Vk 0 $luidA $uuidA 0x1002 0x744c $xt) @(Dx 3 $luidA 0x1002 0x744c) @(Km $luidA 3 0 0) @((Sa $pnpA $locA),(Sa 'PCI\VEN_10DE&DEV_2684&SUBSYS_00000000&REV_A1\4&1&0&0030' 'PCI bus 9, device 0, function 0' '31.0.1.1' 'Synthetic Other Vendor' '10DE' '2684'))
Check ((Ident $nonAmd).adapters.Count -eq 1) 'only VEN_1002 display adapters take part in the identity'
Check ($null -eq (Ident ([pscustomobject]@{setupApiDisplayDevices=@()}))) 'no present AMD adapter means no identity'

# the compare is exercised through the real file (round trip) so the stored shape is the on-disk shape
$none=Compare-Ident (Load-Ident $idRoot) $base
Check (-not $none.card -and -not $none.slot -and -not $none.driver -and @($none.lines).Count -eq 0 -and $null -eq (Load-Ident $idRoot)) 'first start: no stored file, no line'
Save-Ident $base $idRoot
$stored=Load-Ident $idRoot
$onDisk=Get-Content -LiteralPath (Join-Path (Join-Path $idRoot 'state') 'device-identity.json') -Raw | ConvertFrom-Json
Check ($stored -and $onDisk.schema -ceq 'fastllm.device-identity.v1' -and $onDisk.identityFingerprint -ceq $base.fingerprint -and $onDisk.recordedUtc -and $onDisk.adapters[0].slotHash -ceq $base.adapters[0].slotHash -and $null -eq $onDisk.adapters[0].PSObject.Properties['slotKey']) 'device-identity.json has the documented shape and keeps only the slot hash'
$same=Compare-Ident $stored (Ident (New-XtReport))
Check (-not $same.card -and -not $same.slot -and -not $same.driver -and @($same.lines).Count -eq 0) 'no change: nothing is printed'
$card=Compare-Ident $stored (Ident (New-Report @(Vk 0 $luidA $uuidA 0x1002 0x744c $xtx) @(Dx 3 $luidA 0x1002 0x744c) @(Km $luidA 3 0 0) @(Sa $pnpA $locA '32.0.1.1' $xtx '1002' '744C2')))
Check ($card.card -and -not $card.slot -and -not $card.driver -and @($card.lines).Count -eq 1 -and $card.lines[0] -ceq "GPU changed since the last recorded start: $xt -> $xtx") 'a card change prints the GPU changed line with the old and new names'
$slot=Compare-Ident $stored (Ident (New-XtReport -Loc $locB))
Check (-not $slot.card -and $slot.slot -and -not $slot.driver -and @($slot.lines).Count -eq 1 -and $slot.lines[0] -ceq "GPU moved to another slot since the last recorded start: $xt") 'a slot move prints the moved line with the name only'
$driver=Compare-Ident $stored (Ident (New-XtReport -Version '32.0.2.2'))
Check (-not $driver.card -and -not $driver.slot -and $driver.driver -and @($driver.lines).Count -eq 1 -and $driver.lines[0] -ceq "Driver updated since the last recorded start: $xt 32.0.1.1 -> 32.0.2.2") 'a driver update prints the name and the old and new versions'
$both=Compare-Ident $stored (Ident (New-Report @(Vk 0 $luidA $uuidA 0x1002 0x744c $xtx) @(Dx 3 $luidA 0x1002 0x744c) @(Km $luidA 3 0 0) @(Sa $pnpA $locA '32.0.2.2' $xtx '1002' '744C2')))
Check ($both.card -and $both.driver -and @($both.lines).Count -eq 2 -and $both.lines[0] -like 'GPU changed since*' -and $both.lines[1] -like 'Driver updated since*') 'a card change plus a driver update prints both lines'
# identity text is sanitised on write (printable ASCII, at most 128 characters), so a real adapter name stays readable and change detection works
$tmName='AMD Radeon'+[string][char]0x2122+' RX 7900 XT'+[string][char]0xAE
$tmReport=New-Report @(Vk 0 $luidA $uuidA 0x1002 0x744c $tmName) @(Dx 3 $luidA 0x1002 0x744c) @(Km $luidA 3 0 0) @(Sa $pnpA $locA '32.0.1.1' $tmName '1002' '744C')
$tmIdent=Ident $tmReport
$tmRoot=Join-Path ([IO.Path]::GetTempPath()) ('fast-llm-devbind-tm-'+[Guid]::NewGuid().ToString('N'))
$devbindFolders.Add($tmRoot)
New-Item -ItemType Directory -Path $tmRoot | Out-Null
Check ($tmIdent.adapters[0].name -ceq 'AMD Radeon? RX 7900 XT?') 'the identity builder replaces a trademark or registered sign with ?'
$tmWritten=Save-Ident $tmIdent $tmRoot
$tmStored=Load-Ident $tmRoot
Check ($tmWritten -eq $true -and $null -ne $tmStored -and $tmStored.adapters[0].name -ceq 'AMD Radeon? RX 7900 XT?') 'a name with a trademark sign is written, read back (the reader accepts it) and round-trips as ?'
$tmCard=Compare-Ident $tmStored (Ident (New-Report @(Vk 0 $luidA $uuidA 0x1002 0x744c $xtx) @(Dx 3 $luidA 0x1002 0x744c) @(Km $luidA 3 0 0) @(Sa $pnpA $locA '32.0.1.1' $xtx '1002' '744C2')))
Check ($tmCard.card -and @($tmCard.lines).Count -eq 1 -and $tmCard.lines[0] -ceq "GPU changed since the last recorded start: AMD Radeon? RX 7900 XT? -> $xtx") 'a record written with a sanitised name gives the change line on a later card change'
$rawIdentity=[pscustomobject]@{fingerprint=('a'*64);adapters=@([ordered]@{name=('N'+[string][char]0x2122+('x'*199));pciIds=$base.adapters[0].pciIds;slotHash=$base.adapters[0].slotHash;driverVersion='32.0.1.1'})}
$longRoot=Join-Path ([IO.Path]::GetTempPath()) ('fast-llm-devbind-long-'+[Guid]::NewGuid().ToString('N'))
$devbindFolders.Add($longRoot)
New-Item -ItemType Directory -Path $longRoot | Out-Null
$longWritten=Save-Ident $rawIdentity $longRoot
$longStored=Load-Ident $longRoot
Check ($longWritten -eq $true -and $null -ne $longStored -and $longStored.adapters[0].name.Length -eq 128 -and $longStored.adapters[0].name.StartsWith('N?xx')) 'a 200-character name is truncated to 128 characters on write and still reads'
$badRoot=Join-Path ([IO.Path]::GetTempPath()) ('fast-llm-devbind-badid-'+[Guid]::NewGuid().ToString('N'))
$devbindFolders.Add($badRoot)
New-Item -ItemType Directory -Path $badRoot | Out-Null
foreach($badField in @('pciIds','driverVersion')){
    $badAdapter=[ordered]@{name='N';pciIds=$base.adapters[0].pciIds;slotHash=$base.adapters[0].slotHash;driverVersion='32.0.1.1'}
    $badAdapter[$badField]='bad'+[string][char]0x2122
    $badWritten=Save-Ident ([pscustomobject]@{fingerprint=('a'*64);adapters=@($badAdapter)}) $badRoot
    Check ($badWritten -eq $false -and -not (Test-Path -LiteralPath (Join-Path (Join-Path $badRoot 'state') 'device-identity.json')) -and $null -eq (Load-Ident $badRoot)) "a non-ASCII $badField writes no record (never a file the reader rejects)"
}
foreach($sample in @($card,$slot,$driver,$both)){foreach($line in @($sample.lines)){Check (($line -notmatch '[0-9a-fA-F]{32}') -and ($line -notmatch 'PCI') -and ($line -notmatch 'VEN_')) 'a change line carries names and driver versions only (no hash, slot key, PnP or PCI id)'}}
$corrupt=Join-Path ([IO.Path]::GetTempPath()) ('fast-llm-devbind-bad-'+[Guid]::NewGuid().ToString('N'))
$devbindFolders.Add($corrupt)
New-Item -ItemType Directory -Path (Join-Path $corrupt 'state') -Force | Out-Null
Set-Content -LiteralPath (Join-Path (Join-Path $corrupt 'state') 'device-identity.json') -Value '{"schema":"other","adapters":[]}'
Check ($null -eq (Load-Ident $corrupt)) 'a record with the wrong schema is treated as no record'
Set-Content -LiteralPath (Join-Path (Join-Path $corrupt 'state') 'device-identity.json') -Value 'not json'
Check ($null -eq (Load-Ident $corrupt)) 'an unparseable record is treated as no record'
# stored identity text reaches the console: printable ASCII only, at most 128 characters, a 64-hex slot hash; anything else is no record
$identFile=Join-Path (Join-Path $corrupt 'state') 'device-identity.json'
function Write-IdentFile($Name='Synthetic GPU',$Pci='VEN_1002&DEV_744C&SUBSYS_00000000&REV_C8',$Slot=('a'*64),$Driver='32.0.1.1'){
    $doc=[ordered]@{schema='fastllm.device-identity.v1';identityFingerprint=('f'*64);adapters=@([ordered]@{name=$Name;pciIds=$Pci;slotHash=$Slot;driverVersion=$Driver});recordedUtc='2026-10-07T00:00:00.0000000Z'}
    [IO.File]::WriteAllText($identFile,(ConvertTo-Json -InputObject $doc -Depth 6),(New-Object Text.UTF8Encoding($false)))
}
Write-IdentFile
$clean=Load-Ident $corrupt
Check ($null -ne $clean -and $clean.adapters[0].name -ceq 'Synthetic GPU') 'a clean stored record is read back (control for the sanitising cases)'
Write-IdentFile -Name ('N'*128)
Check ($null -ne (Load-Ident $corrupt)) 'a 128-character stored name is accepted (the limit is inclusive)'
Write-IdentFile -Name ('Synthetic '+[char]27+'[31mGPU')
Check ($null -eq (Load-Ident $corrupt)) 'a stored name with an ANSI escape sequence is treated as no record (no change lines)'
Write-IdentFile -Name "Synthetic`nGPU"
Check ($null -eq (Load-Ident $corrupt)) 'a stored name with a newline is treated as no record'
Write-IdentFile -Name "Synthetic GPU`n"
Check ($null -eq (Load-Ident $corrupt)) 'a stored name with a TRAILING newline is treated as no record (the check anchors with \z, not $)'
Write-IdentFile -Name ('N'*129)
Check ($null -eq (Load-Ident $corrupt)) 'a 129-character stored name is treated as no record'
Write-IdentFile -Name ('Synthetic GPU'+[char]0x7F)
Check ($null -eq (Load-Ident $corrupt)) 'a stored name with a DEL character is treated as no record'
Write-IdentFile -Name ('Synthetic G'+[char]0xE9+'PU')
Check ($null -eq (Load-Ident $corrupt)) 'a stored name with a non-ASCII character is treated as no record'
Write-IdentFile -Pci "VEN_1002`r`nDEV_744C"
Check ($null -eq (Load-Ident $corrupt)) 'stored pciIds with a line break are treated as no record'
Write-IdentFile -Driver ('3'*129)
Check ($null -eq (Load-Ident $corrupt)) 'a 129-character stored driverVersion is treated as no record'
Write-IdentFile -Driver ('32.0.1.1'+[char]27+'[0m')
Check ($null -eq (Load-Ident $corrupt)) 'a stored driverVersion with an ANSI escape sequence is treated as no record'
foreach($badSlot in @(('a'*63),('a'*65),('A'*64),(('a'*64)+"`n"),('g'*64),'')){
    Write-IdentFile -Slot $badSlot
    Check ($null -eq (Load-Ident $corrupt)) "a stored slotHash that is not 64 lowercase hex characters ($($badSlot.Length) characters) is treated as no record"
}
Write-IdentFile -Name 7
Check ($null -eq (Load-Ident $corrupt)) 'a stored name that is not text is treated as no record'
$dirtyCompare=Compare-Ident (Load-Ident $corrupt) $base
Check (@($dirtyCompare.lines).Count -eq 0 -and -not $dirtyCompare.card) 'a rejected record produces no change lines'
Write-IdentFile -Name ('Synthetic '+[char]27+'[31mGPU')
Save-Ident $base $corrupt
$rewritten=Load-Ident $corrupt
Check ($null -ne $rewritten -and $rewritten.adapters[0].name -ceq $xt) 'the file is rewritten clean by the next Ready write'
Set-Content -LiteralPath $identFile -Value 'not json'

# ---------- the bounded collector wrapper and the orchestrator (module seams replaced by mocks) ----------
$bt=@{collectorCalls=0;probeCalls=0;report=$null;failure=$null;probeThrow=$null;order=(New-Object 'Collections.Generic.List[string]')}
$saved=@{}
foreach($name in @('Invoke-FastLlmDeviceBindingCollector','Invoke-FastLlmVulkanHeapProbe','Resolve-FastLlmDeviceBindingFromReport','Write-FastLlmDeviceIdentityRecord','Get-FastLlmDeviceBindingLoaderVersion','ConvertFrom-FastLlmServerDeviceListEntries')){$saved[$name]=& $module {param($N) (Get-Command $N).ScriptBlock} $name}
function Restore-Mocks{foreach($name in $saved.Keys){& $module {param($N,$B) Set-Item -Path ('Function:script:'+$N) -Value $B} $name $saved[$name]}}
& $module {
    param($S)
    $script:bindTest=$S
    function script:Invoke-FastLlmVulkanHeapProbe {
        param($TimeoutSeconds,$CollectorPath)
        $script:bindTest.probeCalls++
        if($script:bindTest.probeThrow){$e=New-Object InvalidOperationException 'secret-probe-message-text';$e.Data['FastLlmProbeCategory']=$script:bindTest.probeThrow;throw $e}
        return $script:bindTest.report
    }
    function script:Get-FastLlmDeviceBindingLoaderVersion { return '1.3.999.0' }
} $bt
function Run-Binding($Plan,[string]$Dir,$Bar=$null){& $module {param($P,$D,$B) Invoke-FastLlmDeviceBinding -Plan $P -InstallRoot $D -BarDecision $B} $Plan $Dir $Bar}
if($true){
    $bt.report=New-XtReport
    $o=Run-Binding (New-Plan $xt 20464) $corrupt
    Check ($o.record.mode -ceq 'record' -and $o.record.status -ceq 'bound' -and $bt.probeCalls -eq 1) 'the orchestrator runs the bounded collector child exactly once and binds'
    foreach($typedMode in @('Enforce','ENFORCE','Record','RECORD')){
        $om=& $module {param($P,$D,$M) Invoke-FastLlmDeviceBinding -Plan $P -InstallRoot $D -BarDecision $null -Mode $M} (New-Plan $xt 20464) $corrupt $typedMode
        Check ($om.record.mode -ceq $typedMode.ToLowerInvariant()) "the orchestrator records the mode lowercase when it is typed '$typedMode'"
    }
    Check ($o.record.collector.scriptSha256 -ceq ('a'*64) -and $o.record.collector.joinSourceSha256 -ceq ('b'*64) -and $o.record.collector.loaderVersion -ceq '1.3.999.0' -and $o.record.collector.segmentKnown -eq $false -and $o.record.collector.durationMs -ge 0) 'the collector block records the script and join source hashes, loader version, duration and segmentKnown false'
    Check ($null -ne $o.identity -and $o.identity.fingerprint -ceq $base.fingerprint -and @($o.lines).Count -eq 0) 'the orchestrator returns the Ready-time identity and no line on a first start'
    foreach($mode in @(@('timeout','collector-timeout'),@('child-exit','collector-failed'),@('parse','collector-failed'),@('other','collector-failed'),@('not-windows','collector-failed'))){
        $bt.probeThrow=$mode[0];$o=Run-Binding (New-Plan $xt 20464) $corrupt
        Check ($o.record.status -ceq 'unavailable' -and $o.record.reason -ceq $mode[1] -and $null -eq $o.identity -and @($o.lines).Count -eq 0) "a collector failure of category $($mode[0]) is unavailable / $($mode[1]) with no identity"
        Check (-not (($o.record | ConvertTo-Json -Depth 8) -match 'secret-probe-message-text')) 'a collector failure never records the exception message'
    }
    $bt.probeThrow=$null;$bt.report=$null
    $o=Run-Binding (New-Plan $xt 20464) $corrupt
    Check ($o.record.status -ceq 'unavailable' -and $o.record.reason -ceq 'collector-failed') 'a collector that returns nothing is collector-failed'
    $bt.report=New-XtReport;$before=$bt.probeCalls
    $o=Run-Binding (New-Plan $xt 20464 'ROCm') $corrupt
    Check ($o.record.status -ceq 'unavailable' -and $o.record.reason -ceq 'unsupported-backend' -and $bt.probeCalls -eq $before -and $null -eq $o.identity) 'a non-Vulkan backend runs no child: unavailable / unsupported-backend'
    $savedOs=[Environment]::GetEnvironmentVariable('OS')
    try {
        [Environment]::SetEnvironmentVariable('OS','Linux')
        $o=Run-Binding (New-Plan $xt 20464) $corrupt
    } finally { [Environment]::SetEnvironmentVariable('OS',$savedOs) }
    Check ($o.record.status -ceq 'unavailable' -and $o.record.reason -ceq 'unsupported-platform' -and $bt.probeCalls -eq $before) 'a non-Windows host runs no child: unavailable / unsupported-platform'

    # an exception inside the binder is contained
    & $module { function script:Resolve-FastLlmDeviceBindingFromReport { throw (New-Object InvalidOperationException 'secret-binder-message-text') } }
    $o=Run-Binding (New-Plan $xt 20464) $corrupt
    $recordText=$o.record | ConvertTo-Json -Depth 8
    Check ($o.record.status -ceq 'unavailable' -and $o.record.reason -ceq 'binding-internal-error' -and $o.record.errorType -ceq 'InvalidOperationException' -and $recordText -notmatch 'secret-binder-message-text' -and $null -eq $o.identity) 'an exception in the binder is unavailable / binding-internal-error with the exception type name only'
    & $module {param($B) Set-Item -Path Function:script:Resolve-FastLlmDeviceBindingFromReport -Value $B} $saved['Resolve-FastLlmDeviceBindingFromReport']

    # a stored record produces the change lines through the orchestrator
    Save-Ident $base $idRoot
    $bt.report=New-XtReport -Version '32.0.2.2'
    $o=Run-Binding (New-Plan $xt 20464) $idRoot
    Check ($o.change.driver -and @($o.lines).Count -eq 1 -and $o.lines[0] -ceq "Driver updated since the last recorded start: $xt 32.0.1.1 -> 32.0.2.2") 'the orchestrator compares with the stored record before launch'
}
Check (@(Get-ChildItem -LiteralPath (Join-Path $idRoot 'state') -Filter '*.tmp' -ErrorAction SilentlyContinue).Count -eq 0) 'no temporary file is left next to the identity record'

# ---------- source-level guards ----------
$runtimeSource=Get-Content -LiteralPath (Join-Path $root 'src/FastLlm.Runtime.ps1') -Raw
$bindingSource=Get-Content -LiteralPath (Join-Path $root 'src/FastLlm.DeviceBinding.ps1') -Raw
Check ($bindingSource -notmatch '(?i)failureCode|FastLlmReason') 'the binding code never sets a failure code or a recovery reason'
Check ($bindingSource -notmatch 'ConvertTo-FastLlmDeviceBindingModeName') 'the unused mode-name converter is gone'
Check ($bindingSource -notmatch '(?i)private text') 'the public-export-eligible binding file does not call itself private'
$barAt=$runtimeSource.IndexOf('Resolve-FastLlmVulkanBarMitigation -Plan');$bindAt=$runtimeSource.IndexOf('Invoke-FastLlmDeviceBinding -Plan');$spawnAt=$runtimeSource.IndexOf('$hostProcess.Start($info)')
Check ($barAt -gt 0 -and $bindAt -gt $barAt -and $spawnAt -gt $bindAt) 'the binding runs after the BAR resolve and before the spawn'
$readyAt=$runtimeSource.IndexOf("kind='api-smoke-only'");$identityAt=$runtimeSource.IndexOf('Write-FastLlmDeviceIdentityRecord -InstallRoot')
Check ($readyAt -gt 0 -and $identityAt -gt $readyAt) 'the identity record is written only after the ready write and the last-ready record'


# ---------- W03 Phase A enforce: the post-load check over the frozen server device-list capture (pure function) ----------
function Post($Plan,$Binding,$Capture){& $module {param($P,$B,$C) Test-FastLlmDeviceBindingPostLoad -Plan $P -Binding $B -Capture $C} $Plan $Binding $Capture}
function New-Cap([hashtable]$Over=@{}){
    $c=[ordered]@{deviceInfoLikeLines=1;deviceInfoMalformedLines=0;deviceInfoOverflow=$false;usingDeviceLikeLines=1;usingDeviceMalformedLines=0;usingDeviceOverflow=$false;diagnostics='synthetic'
        deviceInfo=@([ordered]@{name='Vulkan0';description=$xt;totalMiB=20464;freeMiB=20304});usingDevice=@([ordered]@{name='Vulkan0';id='unknown';freeMiB=20304;description=$xt})}
    foreach($k in $Over.Keys){$c[$k]=$Over[$k]}
    return $c
}
function Gpu($Name,$Desc,$Total){[ordered]@{name=$Name;description=$Desc;totalMiB=$Total;freeMiB=1}}
function UseDev($Name,$Id){[ordered]@{name=$Name;id=$Id;freeMiB=1;description=$xt}}
$pbPlan=New-Plan $xt 20464
$pbBinding=[pscustomobject]@{device=(Bind $pbPlan (New-XtReport)).device}
$pass=Post $pbPlan $pbBinding (New-Cap)
Check ($pass.result -ceq 'passed' -and $null -eq $pass.PSObject.Properties['item']) 'post-load: the real shapes (one Vulkan0 entry, name, description, total, one using-device with unknown id) pass'
Check ((Post $pbPlan $pbBinding (New-Cap @{usingDevice=@(UseDev 'Vulkan0' '0000:03:00.0')})).result -ceq 'passed') 'post-load: a PCI BDF using-device id passes'
Check ((Post $pbPlan $pbBinding (New-Cap @{deviceInfo=@((Gpu 'CPU' 'Synthetic CPU' 65536),(Gpu 'Vulkan0' $xt 20464))})).result -ceq 'passed') 'post-load: a CPU entry is ignored'
Check ((Post $pbPlan $pbBinding (New-Cap @{deviceInfo=@((Gpu 'Vulkan0' "  AMD RADEON rx 7900 XT " 20464))})).result -ceq 'passed') 'post-load: the description comparison is the planner''s (trim, ignore case)'
$jsonCap=(New-Cap) | ConvertTo-Json -Depth 8 | ConvertFrom-Json
Check ((Post $pbPlan $pbBinding $jsonCap).result -ceq 'passed') 'post-load: a capture that went through JSON passes the same'
function Expect-Item($Result,[string]$Item,[string]$Message){Check ($Result.result -ceq 'failed' -and $Result.item -ceq $Item) ("post-load item $Item fails: "+$Message)}
Expect-Item (Post $pbPlan $pbBinding ([ordered]@{error='InvalidOperationException'})) '1' 'a capture error'
Expect-Item (Post $pbPlan $pbBinding $null) '1' 'no capture at all'
Expect-Item (Post $pbPlan $pbBinding (New-Cap @{deviceInfoMalformedLines=1})) '1' 'a malformed device_info line'
Expect-Item (Post $pbPlan $pbBinding (New-Cap @{usingDeviceMalformedLines=1})) '1' 'a malformed using-device line'
Expect-Item (Post $pbPlan $pbBinding (New-Cap @{deviceInfoOverflow=$true})) '1' 'device_info overflow'
Expect-Item (Post $pbPlan $pbBinding (New-Cap @{usingDeviceOverflow=$true})) '1' 'using-device overflow'
Expect-Item (Post $pbPlan $pbBinding (New-Cap @{deviceInfoMalformedLines='not-a-number'})) 'internal-error' 'a check that itself throws fails closed (never passes)'
Expect-Item (Post $pbPlan $pbBinding (New-Cap @{deviceInfo=@()})) '2' 'zero device_info entries'
Expect-Item (Post $pbPlan $pbBinding (New-Cap @{deviceInfo=@((Gpu 'CPU' 'Synthetic CPU' 65536))})) '2' 'only a CPU entry'
Expect-Item (Post $pbPlan $pbBinding (New-Cap @{deviceInfo=@((Gpu 'Vulkan0' $xt 20464),(Gpu 'Vulkan1' $xt 20464))})) '2' 'two Vulkan entries'
Expect-Item (Post $pbPlan $pbBinding (New-Cap @{deviceInfo=@((Gpu 'Vulkan1' $xt 20464));usingDevice=@(UseDev 'Vulkan1' 'unknown')})) '3' 'the entry name is not the plan''s selected device'
Expect-Item (Post $pbPlan $pbBinding (New-Cap @{deviceInfo=@((Gpu 'Vulkan0' 'AMD Radeon RX 7900 XTX' 20464))})) '4' 'a different description'
Expect-Item (Post $pbPlan $pbBinding (New-Cap @{deviceInfo=@((Gpu 'Vulkan0' 'AMD Radeon  RX 7900 XT' 20464))})) '4' 'a description that differs in internal spacing (nothing more lenient than the planner)'
Expect-Item (Post $pbPlan $pbBinding (New-Cap @{deviceInfo=@((Gpu 'Vulkan0' $xt 20465))})) '5' 'a total one MiB above'
Expect-Item (Post $pbPlan $pbBinding (New-Cap @{deviceInfo=@((Gpu 'Vulkan0' $xt 20463))})) '5' 'a total one MiB below'
Expect-Item (Post $pbPlan ([pscustomobject]@{device=[ordered]@{name=$xt;ggmlTotalMiB=$null}}) (New-Cap)) '5' 'a binding without a ggml total'
Expect-Item (Post $pbPlan $pbBinding (New-Cap @{usingDevice=@()})) '6' 'no using-device entry'
Expect-Item (Post $pbPlan $pbBinding (New-Cap @{usingDevice=@((UseDev 'Vulkan0' 'unknown'),(UseDev 'Vulkan0' 'unknown'))})) '6' 'two using-device entries'
Expect-Item (Post $pbPlan $pbBinding (New-Cap @{usingDevice=@(UseDev 'Vulkan1' 'unknown')})) '6' 'a using-device name that is not the GPU entry''s'
Expect-Item (Post $pbPlan $pbBinding (New-Cap @{usingDevice=@(UseDev 'Vulkan0' '0000:03:00')})) '6' 'a using-device id that is neither unknown nor a BDF'
Expect-Item (Post ([pscustomobject]@{backend='Vulkan';selectedAdapters=@()}) $pbBinding (New-Cap)) '3' 'a plan without a selected device'

function Invoke-Cli([string]$Arguments){
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=(Get-Process -Id $PID).Path
    $info.Arguments='-NoLogo -NoProfile -NonInteractive -File "'+(Join-Path $root 'fast-llm.ps1')+'" '+$Arguments
    $info.UseShellExecute=$false;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $child=[Diagnostics.Process]::Start($info)
    $out=$child.StandardOutput.ReadToEndAsync();$err=$child.StandardError.ReadToEndAsync()
    $exited=$child.WaitForExit(60000)
    if(-not $exited){$child.Kill()}
    return [pscustomobject]@{exited=$exited;exit=$child.ExitCode;text=($out.Result+$err.Result)}
}
# ---------- real supervised starts against the native HTTP mock ----------
& $module { Initialize-FastLlmProcessHost }
Add-Type -Path (Join-Path $PSScriptRoot 'helpers/MockServer.cs')
$temp=Join-Path ([IO.Path]::GetTempPath()) ('fast-llm-devbind-'+[Guid]::NewGuid().ToString('N'))
$devbindFolders.Add($temp)
New-Item -ItemType Directory -Path $temp | Out-Null
$wrapper=Join-Path $temp 'engine-wrapper.ps1'
$helperRoot=(Join-Path $PSScriptRoot 'helpers').Replace("'","''")
Set-Content -LiteralPath $wrapper -Encoding UTF8 -Value @"
param([int]`$Port,[string]`$Mode='ok',[string]`$Model='test-model',[int]`$Context=1024,[string]`$DiagnosticPath='',[string]`$DumpPath='')
`$lines=@('ARGS='+([Environment]::GetCommandLineArgs() -join ' '))
foreach(`$key in ([Environment]::GetEnvironmentVariables().Keys | Sort-Object)){`$lines+=('ENV:'+`$key+'='+[Environment]::GetEnvironmentVariable(`$key))}
[IO.File]::WriteAllLines(`$DumpPath,`$lines)
& '$helperRoot\mock-server.ps1' -Port `$Port -Mode `$Mode -Model `$Model -Context `$Context -DiagnosticPath `$DiagnosticPath
"@
$suitePassed=$false
$lock=$null
function Invoke-BindRun {
    param([string]$Name,[string]$Binding='record',[string]$Policy='off',[string]$Mode='ok',[string]$Backend='Vulkan',[string]$RunRoot,[switch]$AutoStop)
    $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
    $listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
    if($RunRoot){$runRoot=$RunRoot}else{$runRoot=Join-Path $temp $Name}
    $script:lock=Enter-FastLlmOperation $runRoot
    $dump=Join-Path $runRoot 'dump.txt'
    $enginePlan=[pscustomobject]@{
        enginePath=(Get-Process -Id $PID).Path
        serverArguments=@('-NoLogo','-NoProfile','-File',$wrapper,'-Port',"$port",'-Mode',$Mode,'-Model','test-model','-DiagnosticPath',(Join-Path $runRoot 'diag.txt'),'-DumpPath',$dump)
        endpoint="http://127.0.0.1:$port/v1";backend=$Backend;selectedAdapters=@([pscustomobject]@{device='Vulkan0';name=$xtx;vramMiB=24560})
        hardwareFingerprint='synthetic';engineVersion='b10698';model=[pscustomobject]@{id='test-model';contextSize=1024;sha256=('0'*64)}
    }
    $stopper=$null
    if($Mode -ceq 'ok' -or $AutoStop){
        $stopper=New-Object Diagnostics.Process
        $stopper.StartInfo.FileName=(Get-Process -Id $PID).Path
        $stopCode="Import-Module '$($root.Replace("'","''"))/src/FastLlm.psm1'; for (`$i=0; `$i -lt 300; `$i++) { try { `$s=Get-FastLlmStatus '$($runRoot.Replace("'","''"))'; if (`$s.phase -eq 'ready') { Request-FastLlmStop '$($runRoot.Replace("'","''"))'; exit 0 } } catch {}; Start-Sleep -Milliseconds 200 }; exit 1"
        $stopper.StartInfo.Arguments='-NoLogo -NoProfile -OutputFormat Text -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($stopCode))
        $stopper.StartInfo.UseShellExecute=$false
        $stopper.Start()|Out-Null
    }
    $exit=$null;$failure=$null;$console=@()
    try {
        $options=@{Plan=$enginePlan;InstallRoot=$runRoot;LoadTimeoutSeconds=30}
        if($Policy -ne 'off'){$options.VulkanBarMitigation=$Policy}
        if($Binding -cne 'off'){$options.DeviceBinding=$Binding}
        try {
            $out=@(& $module { param($O) Invoke-FastLlmSupervisedServer @O } $options 6>&1)
            foreach($item in $out){if($item -is [Management.Automation.InformationRecord]){$console+=[string]$item}elseif($item -is [int]){$exit=$item}}
        } catch { $failure=$_.Exception }
        $stopperOk=$true
        if($stopper){$stopperOk=$stopper.WaitForExit(10000) -and $stopper.ExitCode -eq 0}
        $dumpText='';if(Test-Path -LiteralPath $dump){$dumpText=[IO.File]::ReadAllText($dump)}
        $dumpText=$dumpText.Replace($runRoot,'<root>') -replace "(?<![0-9])$port(?![0-9])",'<port>' -replace 'runtime-sandboxes\\[0-9a-f]{32}','runtime-sandboxes\<id>'
        return [pscustomobject]@{exit=$exit;failure=$failure;console=@($console);state=(Get-FastLlmStatus $runRoot);dump=$dumpText;runRoot=$runRoot;stopperOk=$stopperOk;plan=$enginePlan}
    } finally {
        if($stopper){if(-not $stopper.HasExited){$stopper.Kill()};$stopper.Dispose()}
        $script:lock.Dispose();$script:lock=$null
    }
}
function Get-DumpDiff([string]$Left,[string]$Right){
    $a=@($Left -split "`r?`n");$b=@($Right -split "`r?`n");$out=@()
    $max=[Math]::Max($a.Count,$b.Count)
    for($i=0;$i -lt $max;$i++){
        $x='';$y='';if($i -lt $a.Count){$x=$a[$i]};if($i -lt $b.Count){$y=$b[$i]}
        if($x -cne $y){$out+=("[$i] <"+$x+"> vs <"+$y+">")}
    }
    return ($out -join ' || ')
}
function Get-Leaves($Node){
    if($null -eq $Node){return}
    if($Node -is [string] -or $Node -is [ValueType]){[string]$Node;return}
    if($Node -is [Collections.IEnumerable] -and $Node -isnot [Collections.IDictionary]){foreach($item in $Node){Get-Leaves $item};return}
    foreach($property in $Node.PSObject.Properties){Get-Leaves $property.Value}
}
function Test-NoPrivateLeaf($Node,[string[]]$Needles){
    foreach($leaf in @(Get-Leaves $Node)){foreach($needle in $Needles){if($leaf.IndexOf($needle,[StringComparison]::OrdinalIgnoreCase) -ge 0){return $false}}}
    return $true
}
function Set-RealProbe($Report){$bt.report=$Report;$bt.probeCalls=0;$bt.probeThrow=$null}
try {
    $bt.collectorCalls=0
    Set-RealProbe $xtxReport

    # off: no child, no field, no file, and the very same server argv and environment as record
    $off=Invoke-BindRun -Name 'off' -Binding 'off'
    Check ($off.exit -eq 0 -and $off.stopperOk -and $off.state.phase -ceq 'stopped' -and $bt.probeCalls -eq 0) 'off: the start completes and no collector child runs'
    Check ($null -eq $off.state.PSObject.Properties['deviceBinding'] -and $null -eq $off.state.PSObject.Properties['identityFingerprint'] -and $null -eq $off.state.PSObject.Properties['identityFingerprintKind'] -and $null -eq $off.state.PSObject.Properties['identityChange'] -and $null -eq $off.state.PSObject.Properties['identityRecord']) 'off: status.json has no deviceBinding, identityFingerprint, identityChange or identityRecord field'
    Check (-not (Test-Path -LiteralPath (Join-Path (Join-Path $off.runRoot 'state') 'device-identity.json'))) 'off: device-identity.json is neither read nor written'
    $offDefault=Invoke-BindRun -Name 'off-default' -Binding 'off'
    Check (($off.state.PSObject.Properties.Name -join ',') -ceq ($offDefault.state.PSObject.Properties.Name -join ',')) 'off: the state field set is the same on every start'

    $rec=Invoke-BindRun -Name 'record' -Binding 'record'
    Check ($rec.exit -eq 0 -and $rec.stopperOk -and $rec.state.phase -ceq 'stopped' -and $null -eq $rec.state.failureCode -and $bt.probeCalls -eq 1) 'record: the start completes normally with exactly one collector child'
    $dumpNote='record launches the server with the same argv and environment as off'
    if($off.dump -cne $rec.dump){$dumpNote+=(' DIFF '+(Get-DumpDiff $off.dump $rec.dump))}
    Check ($off.dump.Length -gt 0 -and $off.dump -ceq $rec.dump) $dumpNote
    $db=$rec.state.deviceBinding
    Check ($db.mode -ceq 'record' -and $db.status -ceq 'bound' -and $null -eq $db.reason -and $db.planMatch.name -and $db.planMatch.totalMiB -and $db.device.ggmlTotalMiB -eq 24560 -and $db.device.luidMatched -eq $true -and $db.barSnapshot -ceq 'not-applicable') 'record: status.json carries a bound deviceBinding with the plan cross-check'
    Check ($db.postLoadCheck.result -ceq 'passed' -and $null -eq $db.postLoadCheck.PSObject.Properties['item']) 'record: the post-load check is recorded (passed) on the real mock shapes'
    Check ($rec.state.identityFingerprintKind -ceq 'pci-ids+slot+driver' -and $rec.state.identityFingerprint -cmatch '^[0-9a-f]{64}$' -and $rec.state.identityRecord -ceq 'recorded' -and $null -eq $rec.state.PSObject.Properties['identityChange']) 'record: identityFingerprint, kind and identityRecord=recorded are set and identityChange is absent on a first start'
    $identityPath=Join-Path (Join-Path $rec.runRoot 'state') 'device-identity.json'
    Check ((Test-Path -LiteralPath $identityPath) -and (Load-Ident $rec.runRoot)) 'record: device-identity.json is written at Ready'
    Check (@($rec.console | Where-Object { $_ -like 'GPU changed*' -or $_ -like 'GPU moved*' -or $_ -like 'Driver updated*' }).Count -eq 0) 'record: a first start prints no change line'
    $rawStatus=Get-Content -LiteralPath (Join-Path (Join-Path $rec.runRoot 'state') 'status.json') -Raw
    Check ($rawStatus -notmatch $luidA -and $rawStatus -notmatch 'PCI bus' -and $rawStatus -notmatch 'slotHash') 'privacy: status.json holds no LUID value, slot key or slot hash'
    $view=(Remove-FastLlmDeviceBindingPrivateFields -Status (Get-FastLlmStatus $rec.runRoot)) | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    Check ($null -eq $view.PSObject.Properties['identityFingerprint'] -and $null -eq $view.deviceBinding.device.PSObject.Properties['pnpInstanceId'] -and $view.deviceBinding.status -ceq 'bound' -and $view.identityFingerprintKind -ceq 'pci-ids+slot+driver') 'privacy: the status action output drops identityFingerprint and the PnP id but still shows the binding'
    Check ((Test-NoPrivateLeaf $view @($pnpA,'4&1&0&0008',$luidA,'PCI bus',$rec.state.identityFingerprint)) -and -not (Test-NoPrivateLeaf ($rec.state) @($pnpA))) 'privacy: no value in the status action output is a PnP id, LUID, slot key or fingerprint (status.json itself keeps the PnP id and fingerprint, private)'
    $identityDoc=Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json
    Check (Test-NoPrivateLeaf $identityDoc @($pnpA,'4&1&0&0008',$luidA,'PCI bus')) 'privacy: device-identity.json holds no LUID, slot key or PnP id'
    Check (@($rec.console | Where-Object { $_ -match $luidA -or $_ -match 'PCI bus' -or $_ -match [regex]::Escape($pnpA) -or $_ -match '[0-9a-f]{64}' }).Count -eq 0) 'privacy: the console carries no LUID, PnP id, slot key or hash'

    # the real `status` action: redacted for a record root, identical to the plain document for an off root
    $cliStatus=Invoke-Cli ('status -InstallRoot "'+$rec.runRoot+'"')
    $cliView=$null;try{$cliView=$cliStatus.text | ConvertFrom-Json}catch{}
    Check ($cliStatus.exited -and $cliStatus.exit -eq 0 -and $null -ne $cliView -and $cliView.deviceBinding.status -ceq 'bound' -and $null -eq $cliView.PSObject.Properties['identityFingerprint'] -and $null -eq $cliView.deviceBinding.device.PSObject.Properties['pnpInstanceId'] -and (Test-NoPrivateLeaf $cliView @($pnpA,'4&1&0&0008',$luidA,'PCI bus',$rec.state.identityFingerprint))) 'the real status action shows the binding without the PnP id, fingerprint, LUID or slot key'
    $cliOff=Invoke-Cli ('status -InstallRoot "'+$off.runRoot+'"')
    $directOff=((Get-FastLlmStatus $off.runRoot) | ConvertTo-Json -Depth 12)
    Check ($cliOff.exited -and $cliOff.exit -eq 0 -and ($cliOff.text.Trim() -replace '\s+','') -ceq ($directOff.Trim() -replace '\s+','')) 'the status action output for an off root is exactly the plain status document'

    # a second start on the same install root: unchanged, then a driver update
    $again=Invoke-BindRun -Name 'record-same' -Binding 'record' -RunRoot $rec.runRoot
    Check ($again.exit -eq 0 -and $null -eq $again.state.PSObject.Properties['identityChange'] -and @($again.console | Where-Object { $_ -like 'GPU*' -or $_ -like 'Driver*' }).Count -eq 0 -and $again.state.identityRecord -ceq 'recorded') 'record: an unchanged second start prints nothing and sets no identityChange'
    $newDriver=New-Report @(Vk 0 $luidA $uuidA 0x1002 0x744c $xtx) @(Dx 3 $luidA 0x1002 0x744c) @(Km $luidA 3 0 0) @(Sa $pnpA $locA '32.0.9.9' $xtx) $xtxHeaps
    Set-RealProbe $newDriver
    $upd=Invoke-BindRun -Name 'record-driver' -Binding 'record' -RunRoot $rec.runRoot
    $driverLines=@($upd.console | Where-Object { $_ -like 'Driver updated since the last recorded start:*' })
    Check ($upd.exit -eq 0 -and $driverLines.Count -eq 1 -and $driverLines[0] -ceq "Driver updated since the last recorded start: $xtx 32.0.1.1 -> 32.0.9.9" -and $upd.state.identityChange.driver -eq $true -and $upd.state.identityChange.card -eq $false -and $upd.state.identityChange.slot -eq $false) 'record: a driver update prints one line before launch and records identityChange'
    $afterUpdate=Load-Ident $rec.runRoot
    Check ($afterUpdate.adapters[0].driverVersion -ceq '32.0.9.9') 'record: the new identity replaces the stored one at Ready'
    $moved=New-Report @(Vk 0 $luidA $uuidA 0x1002 0x744c $xtx) @(Dx 3 $luidA 0x1002 0x744c) @(Km $luidA 3 0 0) @(Sa $pnpA $locB '32.0.9.9' $xtx) $xtxHeaps
    Set-RealProbe $moved
    $mv=Invoke-BindRun -Name 'record-slot' -Binding 'record' -RunRoot $rec.runRoot
    Check ($mv.exit -eq 0 -and @($mv.console | Where-Object { $_ -ceq "GPU moved to another slot since the last recorded start: $xtx" }).Count -eq 1 -and $mv.state.identityChange.slot -eq $true) 'record: a slot move prints one line before launch'

    # a failed start leaves the stored record untouched
    Set-RealProbe $xtxReport
    $beforeBytes=[IO.File]::ReadAllBytes($identityPath)
    $failed=Invoke-BindRun -Name 'record-fail' -Binding 'record' -Mode 'exit' -RunRoot $rec.runRoot
    Check ($null -ne $failed.failure -and $failed.state.phase -ceq 'failed' -and $failed.state.deviceBinding.status -ceq 'bound') 'a failed start still records its binding in status.json'
    Check ([Convert]::ToBase64String([IO.File]::ReadAllBytes($identityPath)) -ceq [Convert]::ToBase64String($beforeBytes)) 'a failed start leaves device-identity.json untouched'

    # the identity write at Ready can fail without touching the start
    & $module { function script:Write-FastLlmDeviceIdentityRecord { $script:bindTest.order.Add('identity-write');$e=New-Object InvalidOperationException 'secret-write-message';$e.Data['FastLlmStateWrite']=$true;throw $e } }
    $wf=Invoke-BindRun -Name 'record-write-fail' -Binding 'record'
    Check ($wf.exit -eq 0 -and $wf.stopperOk -and $wf.state.phase -ceq 'stopped' -and $null -eq $wf.state.failureCode -and $wf.state.identityRecord -ceq 'write-failed' -and $bt.order.Contains('identity-write')) 'a write failure at Ready is identityRecord=write-failed: the start runs on, no failure code, no state-write-failed'
    & $module {param($B) Set-Item -Path Function:script:Write-FastLlmDeviceIdentityRecord -Value $B} $saved['Write-FastLlmDeviceIdentityRecord']

    # N6: a writer that reports failure by returning $false (no throw) is identityRecord=unavailable in status.json, end to end; the start is unaffected
    & $module { function script:Write-FastLlmDeviceIdentityRecord { $script:bindTest.order.Add('identity-write-false');return $false } }
    $wu=Invoke-BindRun -Name 'record-write-false' -Binding 'record'
    Check ($wu.exit -eq 0 -and $wu.stopperOk -and $wu.state.phase -ceq 'stopped' -and $null -eq $wu.state.failureCode -and $wu.state.identityRecord -ceq 'unavailable' -and $bt.order.Contains('identity-write-false')) 'a writer that returns $false at Ready is identityRecord=unavailable in status.json: the start runs on and no failure code is set'
    & $module {param($B) Set-Item -Path Function:script:Write-FastLlmDeviceIdentityRecord -Value $B} $saved['Write-FastLlmDeviceIdentityRecord']

    # N10: a throw while parsing or persisting the server device-list capture is recorded as { error = <type name> } and never touches the Ready gate
    & $module { function script:ConvertFrom-FastLlmServerDeviceListEntries { throw (New-Object InvalidOperationException 'secret-device-list-message') } }
    $dl=Invoke-BindRun -Name 'record-devicelist-throw' -Binding 'record'
    Check ($dl.exit -eq 0 -and $dl.stopperOk -and $dl.state.phase -ceq 'stopped' -and $null -eq $dl.state.failureCode -and $dl.state.serverDeviceListCapture.error -ceq 'InvalidOperationException' -and @($dl.state.serverDeviceListCapture.PSObject.Properties.Name).Count -eq 1 -and ($dl.state|ConvertTo-Json -Depth 8) -notmatch 'secret-device-list-message') 'a device-list capture failure is serverDeviceListCapture={error=<type name>} with no exception text, and the start still reaches Ready and runs on'
    & $module {param($B) Set-Item -Path Function:script:ConvertFrom-FastLlmServerDeviceListEntries -Value $B} $saved['ConvertFrom-FastLlmServerDeviceListEntries']

    # an exception inside the binder does not stop the start
    & $module { function script:Resolve-FastLlmDeviceBindingFromReport { throw (New-Object InvalidOperationException 'secret-binder-message-text') } }
    $ie=Invoke-BindRun -Name 'record-binder-throws' -Binding 'record'
    Check ($ie.exit -eq 0 -and $ie.stopperOk -and $null -eq $ie.state.failureCode -and $ie.state.deviceBinding.status -ceq 'unavailable' -and $ie.state.deviceBinding.reason -ceq 'binding-internal-error' -and $ie.state.identityRecord -ceq 'unavailable') 'an exception inside the binder: the start proceeds, failureCode unaffected, no recovery'
    Check ($ie.dump -ceq $off.dump) 'an exception inside the binder leaves the server argv and environment identical to off'
    & $module {param($B) Set-Item -Path Function:script:Resolve-FastLlmDeviceBindingFromReport -Value $B} $saved['Resolve-FastLlmDeviceBindingFromReport']

    # the Runtime glue around the binder is contained too (the binder itself never throws; this proves the glue cannot reach the start's catch)
    $glueBinding=& $module {(Get-Command Invoke-FastLlmDeviceBinding).ScriptBlock}
    try {
        & $module { function script:Invoke-FastLlmDeviceBinding { throw (New-Object InvalidOperationException 'secret-glue-message-text') } }
        $gt=Invoke-BindRun -Name 'record-glue-throws' -Binding 'record'
        Check ($gt.exit -eq 0 -and $gt.stopperOk -and $null -eq $gt.state.failureCode -and $gt.state.deviceBinding.status -ceq 'unavailable' -and $gt.state.deviceBinding.reason -ceq 'binding-internal-error' -and $gt.state.identityRecord -ceq 'unavailable' -and $gt.state.deviceBinding.errorType -ceq 'InvalidOperationException') 'an exception thrown inside the glue (binder call): the start proceeds with deviceBinding unavailable / binding-internal-error and identityRecord unavailable'
        Check ($null -eq $gt.state.PSObject.Properties['identityFingerprint'] -and $null -eq $gt.state.PSObject.Properties['identityChange'] -and $gt.dump -ceq $off.dump -and -not (($gt.state | ConvertTo-Json -Depth 8) -match 'secret-glue-message-text')) 'a glue exception sets no identity field, leaves argv and environment identical to off, and never records the message'
        # halfway through the glue: the identity fields are already set when the missing `change` property throws under strict mode
        & $module {
            function script:Invoke-FastLlmDeviceBinding {
                [pscustomobject]@{ record=[pscustomobject]@{ mode='record'; status='bound' }; identity=[pscustomobject]@{ fingerprint=('f'*64); adapters=@() }; lines=@() }
            }
        }
        $gf=Invoke-BindRun -Name 'record-glue-fingerprint-throws' -Binding 'record'
        Check ($gf.exit -eq 0 -and $gf.stopperOk -and $null -eq $gf.state.failureCode -and $gf.state.deviceBinding.status -ceq 'unavailable' -and $gf.state.deviceBinding.reason -ceq 'binding-internal-error' -and $gf.state.identityRecord -ceq 'unavailable' -and $null -eq $gf.state.PSObject.Properties['identityFingerprint'] -and $null -eq $gf.state.PSObject.Properties['identityFingerprintKind'] -and $gf.dump -ceq $off.dump) 'an exception thrown halfway through the glue (identity fields already set) leaves no partial identity state and the start proceeds'
    } finally {
        & $module {param($B) Set-Item -Path Function:script:Invoke-FastLlmDeviceBinding -Value $B} $glueBinding
    }

    # collector failure and timeout never gate the start

    foreach($category in @('timeout','child-exit')){
        Set-RealProbe $xtxReport;$bt.probeThrow=$category
        $cf=Invoke-BindRun -Name "record-probe-$category" -Binding 'record'
        $expected=@{'timeout'='collector-timeout';'child-exit'='collector-failed'}[$category]
        Check ($cf.exit -eq 0 -and $cf.stopperOk -and $null -eq $cf.state.failureCode -and $cf.state.deviceBinding.reason -ceq $expected -and $cf.state.identityRecord -ceq 'unavailable' -and $cf.dump -ceq $off.dump) "a collector $category is unavailable / $expected and the start runs on with the same argv and environment"
    }
    Set-RealProbe $xtxReport

    # non-Vulkan backend: no child
    $rocm=Invoke-BindRun -Name 'record-rocm' -Binding 'record' -Backend 'ROCm'
    Check ($rocm.exit -eq 0 -and $bt.probeCalls -eq 0 -and $rocm.state.deviceBinding.reason -ceq 'unsupported-backend' -and $rocm.state.identityRecord -ceq 'unavailable') 'record on a non-Vulkan lane: unavailable / unsupported-backend and no child'
    Check ($null -eq $rocm.state.deviceBinding.PSObject.Properties['postLoadCheck']) 'record: an unbound binding records no postLoadCheck'

    # the BAR policy still resolves exactly as before; auto plus record runs the collector twice (BAR probe, then the binding)
    Set-RealProbe $xtxReport
    $autoOff=Invoke-BindRun -Name 'auto-off' -Binding 'off' -Policy 'auto'
    $autoOffProbeCalls=$bt.probeCalls
    Set-RealProbe $xtxReport
    $autoRec=Invoke-BindRun -Name 'auto-record' -Binding 'record' -Policy 'auto'
    Check ($autoOff.exit -eq 0 -and $autoRec.exit -eq 0 -and $autoOffProbeCalls -eq 1 -and $bt.probeCalls -eq 2) 'BAR auto: one child for the BAR probe; with record a second child for the binding (two in total)'
    Check ($autoRec.state.vulkanMemoryPolicy.requested -ceq 'auto' -and $autoRec.state.vulkanMemoryPolicy.effective -ceq $autoOff.state.vulkanMemoryPolicy.effective -and $autoRec.state.vulkanMemoryPolicy.reason -ceq $autoOff.state.vulkanMemoryPolicy.reason -and $autoRec.state.vulkanMemoryPolicy.rebarDetected -ceq $autoOff.state.vulkanMemoryPolicy.rebarDetected) 'the BAR decision is the same with and without record'
    Check ($autoRec.dump -ceq $autoOff.dump) 'BAR auto: record launches with the same argv and environment as off'
    Check ($autoRec.state.deviceBinding.barSnapshot -ceq 'not-available') 'BAR auto on a live start: barSnapshot is not-available because the decision carries no PnP instance'

    # ================= W03 Phase A enforce =================
    Set-RealProbe $xtxReport
    $enfPass=Invoke-BindRun -Name 'enforce-pass' -Binding 'enforce'
    Check ($enfPass.exit -eq 0 -and $enfPass.stopperOk -and $enfPass.state.phase -ceq 'stopped' -and $null -eq $enfPass.state.failureCode -and $bt.probeCalls -eq 1) 'enforce: a bound device whose server device list matches reaches Ready and stops cleanly, with one collector child'
    Check ($enfPass.state.deviceBinding.mode -ceq 'enforce' -and $enfPass.state.deviceBinding.status -ceq 'bound' -and $enfPass.state.deviceBinding.postLoadCheck.result -ceq 'passed' -and $null -eq $enfPass.state.deviceBinding.postLoadCheck.PSObject.Properties['item'] -and $enfPass.state.identityRecord -ceq 'recorded') 'enforce: status.json carries mode enforce, status bound and postLoadCheck passed'
    Check ($off.dump.Length -gt 0 -and $off.dump -ceq $enfPass.dump) 'enforce launches the server with the same argv and environment as off'
    Check (@($enfPass.console | Where-Object { $_ -match $luidA -or $_ -match 'PCI bus' -or $_ -match [regex]::Escape($pnpA) -or $_ -match '[0-9a-f]{64}' }).Count -eq 0) 'enforce privacy: the console carries no LUID, PnP id, slot key or hash'
    $enfView=(Remove-FastLlmDeviceBindingPrivateFields -Status (Get-FastLlmStatus $enfPass.runRoot)) | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    Check ($enfView.deviceBinding.postLoadCheck.result -ceq 'passed' -and (Test-NoPrivateLeaf $enfView @($pnpA,'4&1&0&0008',$luidA,'PCI bus',$enfPass.state.identityFingerprint))) 'enforce privacy: the status action output shows postLoadCheck and no PnP id, LUID, slot key or fingerprint'
    $enfCli=Invoke-Cli ('status -InstallRoot "'+$enfPass.runRoot+'"')
    Check ($enfCli.exited -and $enfCli.exit -eq 0 -and $enfCli.text -match '"postLoadCheck"' -and $enfCli.text -notmatch [regex]::Escape($pnpA) -and $enfCli.text -notmatch $luidA -and $enfCli.text -notmatch 'PCI bus') 'enforce privacy: the real status action shows postLoadCheck and none of the private values'
    $enfUnknown=Invoke-BindRun -Name 'enforce-pass-unknown' -Binding 'enforce' -Mode 'pl-ok-unknown' -AutoStop
    Check ($enfUnknown.exit -eq 0 -and $enfUnknown.stopperOk -and $enfUnknown.state.deviceBinding.postLoadCheck.result -ceq 'passed') 'enforce: the real "(unknown id) - N MiB free" using-device shape passes'

    # pre-launch gate: each non-bound status fails BEFORE launch with the typed code, survives the catch, and spawns nothing
    function Test-EnforcePreLaunch($Run,[string]$Status,[string]$Reason,[string]$What){
        $f=$Run.failure
        $okType=($null -ne $f -and $f.Data['FastLlmFailureCode'] -ceq "device-binding-$Status" -and $f.Data['FastLlmReason'] -ceq 'DeviceBindingFailed')
        $okState=($Run.state.phase -ceq 'failed' -and $Run.state.failureCode -ceq "device-binding-$Status" -and $Run.state.deviceBinding.mode -ceq 'enforce' -and $Run.state.deviceBinding.status -ceq $Status -and $Run.state.deviceBinding.reason -ceq $Reason -and $null -eq $Run.state.deviceBinding.PSObject.Properties['postLoadCheck'])
        $okNoSpawn=($Run.dump.Length -eq 0 -and $null -eq $Run.state.processIdentity -and $null -eq $Run.exit -and $Run.state.identityRecord -cne 'recorded')
        $okMessage=($null -ne $f -and $f.Message -match "status '$Status'" -and $f.Message -match "reason '$Reason'" -and $f.Message -match '-DeviceBinding record' -and $f.Message -match '-DeviceBinding off' -and $f.Message -notmatch $luidA -and $f.Message -notmatch [regex]::Escape($pnpA) -and $f.Message -notmatch 'PCI bus' -and $f.Message -notmatch '[0-9a-f]{64}' -and $f.Message -cnotmatch 'RuntimeCheckFailed')
        Check ($okType -and $okState -and $okNoSpawn -and $okMessage) ("enforce pre-launch: $What fails before launch as device-binding-$Status (typed, kept by the catch, no server spawned, message names status and reason)")
    }
    Set-RealProbe $xtxReport;$bt.probeThrow='timeout'
    Test-EnforcePreLaunch (Invoke-BindRun -Name 'enforce-unavailable-collector' -Binding 'enforce') 'unavailable' 'collector-timeout' 'a collector timeout'
    Set-RealProbe $xtxReport;$bt.probeThrow='child-exit'
    Test-EnforcePreLaunch (Invoke-BindRun -Name 'enforce-unavailable-failed' -Binding 'enforce') 'unavailable' 'collector-failed' 'a collector failure'
    Set-RealProbe (New-XtReport)
    Test-EnforcePreLaunch (Invoke-BindRun -Name 'enforce-unavailable-plan' -Binding 'enforce') 'unavailable' 'plan-mismatch' 'a plan mismatch (the collector''s card is not the plan''s)'
    Set-RealProbe $xtxReport
    Test-EnforcePreLaunch (Invoke-BindRun -Name 'enforce-unavailable-rocm' -Binding 'enforce' -Backend 'ROCm') 'unavailable' 'unsupported-backend' 'a non-Vulkan lane'
    Check ($bt.probeCalls -eq 0) 'enforce: a non-Vulkan lane never starts a collector child'
    Set-RealProbe $dozen
    Test-EnforcePreLaunch (Invoke-BindRun -Name 'enforce-ambiguous' -Binding 'enforce') 'ambiguous' 'join-vulkan-ambiguous' 'an ambiguous join'
    Set-RealProbe $pair
    Test-EnforcePreLaunch (Invoke-BindRun -Name 'enforce-topology' -Binding 'enforce') 'not-supported-topology' 'multiple-adapters' 'two adapters'
    Set-RealProbe $xtxReport
    & $module { function script:Resolve-FastLlmDeviceBindingFromReport { throw (New-Object InvalidOperationException 'secret-binder-message-text') } }
    $enfBinderThrow=Invoke-BindRun -Name 'enforce-binder-throws' -Binding 'enforce'
    Test-EnforcePreLaunch $enfBinderThrow 'unavailable' 'binding-internal-error' 'an exception inside the binder (fail closed)'
    Check (-not (($enfBinderThrow.state | ConvertTo-Json -Depth 8) -match 'secret-binder-message-text') -and $enfBinderThrow.failure.Message -notmatch 'secret-binder-message-text') 'enforce: an internal binder error records only its type, never its message'
    & $module {param($B) Set-Item -Path Function:script:Resolve-FastLlmDeviceBindingFromReport -Value $B} $saved['Resolve-FastLlmDeviceBindingFromReport']
    $glueBindingEnf=& $module {(Get-Command Invoke-FastLlmDeviceBinding).ScriptBlock}
    try {
        & $module { function script:Invoke-FastLlmDeviceBinding { throw (New-Object InvalidOperationException 'secret-glue-message-text') } }
        $enfGlue=Invoke-BindRun -Name 'enforce-glue-throws' -Binding 'enforce'
        Test-EnforcePreLaunch $enfGlue 'unavailable' 'binding-internal-error' 'an exception inside the glue (fail closed)'
        Check ($enfGlue.state.deviceBinding.errorType -ceq 'InvalidOperationException' -and -not (($enfGlue.state | ConvertTo-Json -Depth 8) -match 'secret-glue-message-text')) 'enforce: a glue exception records only its type'
    } finally { & $module {param($B) Set-Item -Path Function:script:Invoke-FastLlmDeviceBinding -Value $B} $glueBindingEnf }
    Set-RealProbe $xtxReport

    # M-1 case normalisation: ValidateSet is case-insensitive, so a capitalised value must behave exactly like its lowercase form
    foreach($typed in @('Enforce','ENFORCE')){
        Set-RealProbe $xtxReport;$bt.probeThrow='timeout'
        Test-EnforcePreLaunch (Invoke-BindRun -Name "enforce-case-$typed-timeout" -Binding $typed) 'unavailable' 'collector-timeout' "a collector timeout typed as -DeviceBinding $typed"
    }
    Set-RealProbe $xtxReport
    foreach($typed in @('Record','RECORD')){
        Set-RealProbe $xtxReport;$bt.probeThrow='timeout'
        $recCase=Invoke-BindRun -Name "record-case-$typed-timeout" -Binding $typed
        Check ($recCase.exit -eq 0 -and $recCase.stopperOk -and $null -eq $recCase.failure -and $null -eq $recCase.state.failureCode -and $recCase.state.deviceBinding.mode -ceq 'record' -and $recCase.state.deviceBinding.reason -ceq 'collector-timeout' -and $recCase.dump -ceq $off.dump) "-DeviceBinding $typed records mode 'record', never gates on a collector timeout and launches like off"
    }
    Set-RealProbe $xtxReport
    $offCase=Invoke-BindRun -Name 'off-case-upper' -Binding 'OFF'
    Check ($offCase.exit -eq 0 -and $offCase.stopperOk -and $bt.probeCalls -eq 0 -and $null -eq $offCase.state.PSObject.Properties['deviceBinding'] -and $offCase.dump -ceq $off.dump -and ($off.state.PSObject.Properties.Name -join ',') -ceq ($offCase.state.PSObject.Properties.Name -join ',')) "-DeviceBinding OFF is byte-identical to off: no collector child, no deviceBinding field, same argv, environment and state field set"
    Set-RealProbe $xtxReport
    $enfCasePass=Invoke-BindRun -Name 'enforce-case-pass' -Binding 'Enforce'
    Check ($enfCasePass.exit -eq 0 -and $enfCasePass.stopperOk -and $enfCasePass.state.deviceBinding.mode -ceq 'enforce' -and $enfCasePass.state.deviceBinding.postLoadCheck.result -ceq 'passed') '-DeviceBinding Enforce on a matching device list reaches Ready and records mode enforce (lowercase)'

    # post-load check: each failing case stops the server and fails with the typed post-load code; never recovery, never Ready
    function Test-EnforcePostLoad($Run,[string]$Item,[string]$What){
        $f=$Run.failure
        $okType=($null -ne $f -and $f.Data['FastLlmFailureCode'] -ceq 'device-binding-post-load-mismatch' -and $f.Data['FastLlmReason'] -ceq 'DeviceBindingFailed')
        $okState=($Run.state.phase -ceq 'failed' -and $Run.state.failureCode -ceq 'device-binding-post-load-mismatch' -and $Run.state.deviceBinding.mode -ceq 'enforce' -and $Run.state.deviceBinding.postLoadCheck.result -ceq 'failed' -and $Run.state.deviceBinding.postLoadCheck.item -ceq $Item)
        $okNotReady=($null -eq $Run.state.canary -and $null -eq $Run.state.placement -and $Run.state.identityRecord -cne 'recorded' -and $null -eq $Run.exit -and -not (Test-Path -LiteralPath (Join-Path (Join-Path $Run.runRoot 'state') 'device-identity.json')))
        $childPid=[int]$Run.state.processIdentity.pid;$gone=$false
        for($i=0;$i -lt 50 -and -not $gone;$i++){if($null -eq (Get-Process -Id $childPid -ErrorAction SilentlyContinue)){$gone=$true}else{Start-Sleep -Milliseconds 100}}
        $okMessage=($null -ne $f -and $f.Message -match "check $Item" -and $f.Message -match '-DeviceBinding record' -and $f.Message -match '-DeviceBinding off' -and $f.Message -notmatch $luidA -and $f.Message -notmatch [regex]::Escape($pnpA) -and $f.Message -notmatch 'AMD Radeon')
        Check ($okType -and $okState -and $okNotReady -and $gone -and $okMessage) ("enforce post-load item ${Item}: $What stops the server and fails as device-binding-post-load-mismatch (typed, kept by the catch, before the canary and Ready)")
    }
    $postCases=@(
        @('pl-malformed','1','a malformed device_info line'),@('pl-overflow','1','device_info overflow'),
        @('pl-no-gpu','2','no GPU entry'),@('pl-two-gpu','2','two GPU entries'),
        @('pl-name','3','a wrong device name'),@('pl-desc','4','a wrong description'),@('pl-total','5','a total off by one'),
        @('pl-using-missing','6','a missing using-device line'),@('pl-using-double','6','a doubled using-device line'),@('pl-using-name','6','a using-device name mismatch'))
    foreach($case in $postCases){
        Set-RealProbe $xtxReport
        Test-EnforcePostLoad (Invoke-BindRun -Name ('enforce-'+$case[0]) -Binding 'enforce' -Mode $case[0]) $case[1] $case[2]
    }
    foreach($typed in @('Enforce','ENFORCE')){
        Set-RealProbe $xtxReport
        Test-EnforcePostLoad (Invoke-BindRun -Name "enforce-case-$typed-pl-total" -Binding $typed -Mode 'pl-total') '5' "a total off by one typed as -DeviceBinding $typed"
    }
    Set-RealProbe $xtxReport
    $recCasePl=Invoke-BindRun -Name 'record-case-pl-total' -Binding 'Record' -Mode 'pl-total' -AutoStop
    Check ($recCasePl.exit -eq 0 -and $recCasePl.stopperOk -and $null -eq $recCasePl.failure -and $recCasePl.state.deviceBinding.mode -ceq 'record' -and $recCasePl.state.deviceBinding.postLoadCheck.result -ceq 'failed' -and $recCasePl.state.identityRecord -ceq 'recorded') '-DeviceBinding Record never gates a failing post-load check and records mode record'

    # N-2: the two routes from enforce into recovery are closed. (a) a postLoadCheck Add-Member failure becomes the typed post-load failure in enforce
    # and is only swallowed in record; (b) the catch keys on the reason alone and sanitises the code.
    & $module {
        $script:FrAddMemberFails=$true
        function script:Add-Member {
            [CmdletBinding()]
            param([Parameter(ValueFromPipeline=$true)]$InputObject,[Parameter(Position=0)]$MemberType,[Parameter(Position=1)]$Name,[Parameter(Position=2)]$Value,$NotePropertyName,$NotePropertyValue,$NotePropertyMembers,[switch]$Force,[switch]$PassThru)
            process {
                if($script:FrAddMemberFails -eq $true -and $PSBoundParameters['NotePropertyName'] -ceq 'postLoadCheck'){ throw (New-Object InvalidOperationException 'secret-add-member-message') }
                Microsoft.PowerShell.Utility\Add-Member @PSBoundParameters
            }
        }
    }
    try {
        Set-RealProbe $xtxReport
        $enfAdd=Invoke-BindRun -Name 'enforce-add-member-throws' -Binding 'enforce' -Mode 'pl-ok-unknown'
        $addChild=[int]$enfAdd.state.processIdentity.pid;$addGone=$false
        for($i=0;$i -lt 50 -and -not $addGone;$i++){if($null -eq (Get-Process -Id $addChild -ErrorAction SilentlyContinue)){$addGone=$true}else{Start-Sleep -Milliseconds 100}}
        Check ($null -ne $enfAdd.failure -and $enfAdd.failure.Data['FastLlmFailureCode'] -ceq 'device-binding-post-load-mismatch' -and $enfAdd.failure.Data['FastLlmReason'] -ceq 'DeviceBindingFailed' -and $enfAdd.failure.Message -match 'internal-error' -and $enfAdd.failure.Message -notmatch 'secret-add-member-message' -and $enfAdd.state.phase -ceq 'failed' -and $enfAdd.state.failureCode -ceq 'device-binding-post-load-mismatch' -and $null -eq $enfAdd.state.canary -and $null -eq $enfAdd.state.placement -and $null -eq $enfAdd.exit -and $addGone -and -not (($enfAdd.state | ConvertTo-Json -Depth 8) -match 'secret-add-member-message')) 'enforce: a postLoadCheck Add-Member failure is the typed device-binding-post-load-mismatch (internal-error), stops the server and is never an untyped error'
        Set-RealProbe $xtxReport
        $recAdd=Invoke-BindRun -Name 'record-add-member-throws' -Binding 'record'
        Check ($recAdd.exit -eq 0 -and $recAdd.stopperOk -and $null -eq $recAdd.failure -and $null -eq $recAdd.state.failureCode -and $recAdd.state.deviceBinding.mode -ceq 'record' -and $null -eq $recAdd.state.deviceBinding.PSObject.Properties['postLoadCheck']) 'record: a postLoadCheck Add-Member failure is swallowed and the start reaches Ready'
    } finally { & $module { $script:FrAddMemberFails=$false; Remove-Item -LiteralPath 'Function:\Add-Member' -Force -ErrorAction SilentlyContinue } }
    Check ((& $module { (Get-Command Add-Member).CommandType.ToString() }) -ceq 'Cmdlet') 'the Add-Member test proxy is removed from the module scope after its test (Get-Command Add-Member resolves to the cmdlet)'
    # Item 1 (a): the REAL New-FastLlmDeviceBindingFailure maps a code outside the pattern to device-binding-unavailable at the source, so neither Data nor the message prefix carries it.
    $srcOdd=& $module { New-FastLlmDeviceBindingFailure -Code 'bad code C:\Users\rawtoken-zq7\secret.txt' -Message 'the binding is not bound' }
    Check ($srcOdd.Data['FastLlmFailureCode'] -ceq 'device-binding-unavailable' -and $srcOdd.Data['FastLlmReason'] -ceq 'DeviceBindingFailed' -and $srcOdd.Message.StartsWith('device-binding-unavailable: ',[StringComparison]::Ordinal) -and $srcOdd.Message -notmatch 'rawtoken-zq7' -and $srcOdd.Message -notmatch 'bad code') 'New-FastLlmDeviceBindingFailure maps a non-conforming code to device-binding-unavailable (Data code and message prefix), keeping the reason'
    $srcOk=& $module { New-FastLlmDeviceBindingFailure -Code 'device-binding-ambiguous' -Message 'two candidates' }
    Check ($srcOk.Data['FastLlmFailureCode'] -ceq 'device-binding-ambiguous' -and $srcOk.Message -ceq 'device-binding-ambiguous: two candidates') 'New-FastLlmDeviceBindingFailure leaves a conforming code and its message unchanged'
    Check ((& $module { ConvertTo-FastLlmDeviceBindingCode -Code 'Device-Binding-X' }) -ceq 'device-binding-unavailable' -and (& $module { ConvertTo-FastLlmDeviceBindingCode -Code 'device-binding-' }) -ceq 'device-binding-unavailable' -and (& $module { ConvertTo-FastLlmDeviceBindingCode -Code 'device-binding-post-load-mismatch' }) -ceq 'device-binding-post-load-mismatch') 'the shared device-binding code helper is case-sensitive and requires 1..40 lower-case letters or hyphens after the prefix'
    $newFailureBinding=& $module {(Get-Command New-FastLlmDeviceBindingFailure).ScriptBlock}
    try {
        & $module {
            function script:New-FastLlmDeviceBindingFailure {
                param([string]$Code,[string]$Message)
                $e=New-FastLlmTypedFailure -Code 'BAD code_1' -Message $Message
                $e.Data['FastLlmReason']='DeviceBindingFailed'
                return $e
            }
        }
        Set-RealProbe $xtxReport;$bt.probeThrow='timeout'
        $oddPre=Invoke-BindRun -Name 'enforce-odd-code-pre-launch' -Binding 'enforce'
        Check ($null -ne $oddPre.failure -and $oddPre.failure.Data['FastLlmReason'] -ceq 'DeviceBindingFailed' -and $oddPre.state.phase -ceq 'failed' -and $oddPre.state.failureCode -ceq 'device-binding-unavailable' -and $oddPre.dump.Length -eq 0) 'enforce: a DeviceBindingFailed with a code outside the pattern keeps its reason and is recorded as device-binding-unavailable (pre-launch)'
        Set-RealProbe $xtxReport
        $oddPost=Invoke-BindRun -Name 'enforce-odd-code-post-load' -Binding 'enforce' -Mode 'pl-total'
        Check ($null -ne $oddPost.failure -and $oddPost.failure.Data['FastLlmReason'] -ceq 'DeviceBindingFailed' -and $oddPost.state.phase -ceq 'failed' -and $oddPost.state.failureCode -ceq 'device-binding-unavailable') 'enforce: a DeviceBindingFailed with a code outside the pattern is recorded as device-binding-unavailable (post-load)'
        # T-2: the sanitised code is written back to Data, so the CLI's outer catch (fast-llm.ps1, which records Data['FastLlmFailureCode'] into
        # status.json) carries the sanitised value and the raw token never reaches status.json.
        Check ($oddPre.failure.Data['FastLlmFailureCode'] -ceq 'device-binding-unavailable' -and $oddPost.failure.Data['FastLlmFailureCode'] -ceq 'device-binding-unavailable') 'enforce: the sanitised code is written back to the exception Data (pre-launch and post-load)'
        & $module {
            function script:New-FastLlmDeviceBindingFailure {
                param([string]$Code,[string]$Message)
                $e=New-FastLlmTypedFailure -Code 'bad code C:\Users\rawtoken-zq7\secret.txt' -Message $Message
                $e.Data['FastLlmReason']='DeviceBindingFailed'
                return $e
            }
        }
        Set-RealProbe $xtxReport;$bt.probeThrow='timeout'
        $rawRun=Invoke-BindRun -Name 'enforce-raw-code-cli-status' -Binding 'enforce'
        Check ($null -ne $rawRun.failure -and $rawRun.failure.Data['FastLlmFailureCode'] -ceq 'device-binding-unavailable' -and $rawRun.state.failureCode -ceq 'device-binding-unavailable') 'enforce: a code with a space and a path-like token is sanitised in both the supervisor state and the exception Data'
        # Run the REAL CLI outer-catch status update: extracted from fast-llm.ps1 through the PowerShell AST (the start-tests.ps1 pattern), bound to the failure and the same
        # state root. Exactly one matching catch and one matching if-statement must be found; anything else fails (it never skips).
        $cliTokens=$null;$cliErrors=$null
        $cliTree=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'fast-llm.ps1'),[ref]$cliTokens,[ref]$cliErrors)
        Check (@($cliErrors).Count -eq 0) 'fast-llm.ps1 parses (T-2 catch extraction)'
        $cliCatches=@($cliTree.FindAll({param($n) $n -is [Management.Automation.Language.CatchClauseAst] -and $n.Body.Extent.Text.Contains("Data['FastLlmFailureCode']") -and $n.Body.Extent.Text.Contains('Write-FastLlmState')},$true))
        Check ($cliCatches.Count -eq 1) 'T-2: exactly one fast-llm.ps1 catch block records the typed failure code (the real catch is extracted, never skipped)'
        $cliStatusIfs=@($cliCatches[0].Body.FindAll({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses.Count -eq 1 -and $n.Clauses[0].Item1.Extent.Text -ceq '$operationLock'},$true))
        Check ($cliStatusIfs.Count -eq 1 -and $cliStatusIfs[0].Extent.Text.Contains('Add-Member -NotePropertyName failureCode')) 'T-2: exactly one status-update branch (if ($operationLock)) is found in that catch'
        # The status branch depends on the statements before it in the catch (the binding-code computation), so the block is those statements plus the branch.
        $cliLockIndex=[array]::IndexOf(@($cliCatches[0].Body.Statements),$cliStatusIfs[0])
        Check ($cliLockIndex -ge 1) 'T-2: the status-update branch is a direct statement of the catch (the statements before it are extracted with it)'
        $cliPreStatements=@($cliCatches[0].Body.Statements | Select-Object -First $cliLockIndex | Where-Object { $_.Extent.Text -cne '$failure = $_' })
        # The wrong-binding discrimination case below must still reach the branch's own try (and warn), so a throw in the extracted statements before it falls back to defaults here.
        $cliPreText=(@($cliPreStatements | ForEach-Object { $_.Extent.Text }) -join [Environment]::NewLine)
        $cliCatchBlock=[scriptblock]::Create('$isBindingFailure=$false;$bindingCode=$null;try {'+[Environment]::NewLine+$cliPreText+[Environment]::NewLine+'} catch { $isBindingFailure=$false;$bindingCode=$null }'+[Environment]::NewLine+$cliStatusIfs[0].Extent.Text)
        # Runs the extracted branch after overwriting the run's status with a sentinel (so only the CLI branch can make it 'failed'), with the warning stream captured.
        $runCliCatch={
            param($Failure)
            & $module {
                param($Block,$Root,$Fail)
                $sentinel=Get-FastLlmStatus -InstallRoot $Root
                $sentinel.phase='stopped'
                $sentinel | Add-Member -NotePropertyName failureCode -NotePropertyValue 'sentinel-before-cli' -Force
                Write-FastLlmState -InstallRoot $Root -State $sentinel
                $InstallRoot=$Root;$failure=$Fail;$operationLock=[pscustomobject]@{held=$true}
                $warnings=@(. $Block 3>&1 | Where-Object { $_ -is [Management.Automation.WarningRecord] } | ForEach-Object { [string]$_.Message })
                [pscustomobject]@{warnings=$warnings;text=[IO.File]::ReadAllText((Join-Path (Get-FastLlmStateRoot -InstallRoot $Root) 'status.json'))}
            } $cliCatchBlock $rawRun.runRoot $Failure
        }
        # The real catch binds $failure to the ErrorRecord ($failure = $_), so the branch reads $failure.Exception.Data[...]; bind it the same way.
        $cliRecord=New-Object System.Management.Automation.ErrorRecord($rawRun.failure,'FastLlmTest','NotSpecified',$null)
        $cliRun=& $runCliCatch $cliRecord
        $cliState=$cliRun.text | ConvertFrom-Json
        Check (@($cliRun.warnings | Where-Object { $_ -match 'Failure status could not be saved' }).Count -eq 0 -and $cliRun.warnings.Count -eq 0) 'T-2: the extracted CLI catch branch emits no "Failure status could not be saved" warning'
        Check ($cliState.phase -ceq 'failed' -and $cliState.failureCode -ceq 'device-binding-unavailable' -and $cliRun.text -notmatch 'sentinel-before-cli') 'T-2: the CLI branch itself wrote status.json (sentinel overwritten, phase failed) with the sanitised code'
        Check ($cliRun.text -notmatch 'rawtoken-zq7' -and $cliRun.text -notmatch 'bad code' -and $cliRun.text -notmatch 'secret\.txt') 'the status.json the CLI catch writes carries no part of the raw code (the raw token appears nowhere in it)'
        # Discrimination: the wrong binding (the raw exception, which has no .Exception) must make the branch warn and write nothing, so the check above can tell the two apart.
        $wrongRun=& $runCliCatch $rawRun.failure
        $wrongState=$wrongRun.text | ConvertFrom-Json
        Check (@($wrongRun.warnings | Where-Object { $_ -match 'Failure status could not be saved' }).Count -eq 1 -and $wrongState.phase -cne 'failed' -and $wrongState.failureCode -ceq 'sentinel-before-cli') 'T-2 discrimination: binding $failure to the raw exception emits the warning and writes nothing (sentinel intact), unlike the ErrorRecord binding'
        # Item 1 (b): the REAL console print path of the same outer catch (everything in it except the status update, the $failure assignment and the exit), extracted through the AST.
        # $failure is bound to an ErrorRecord as in the CLI, StrictMode 2.0 is on, and the error stream is captured.
        $cliPostStatements=@($cliCatches[0].Body.Statements | Select-Object -Skip ($cliLockIndex+1) | Where-Object { $_ -isnot [Management.Automation.Language.ExitStatementAst] })
        $cliPrintStatements=@($cliPreStatements)+@($cliPostStatements)
        Check ((@($cliPrintStatements | Where-Object { $_.Extent.Text.StartsWith('Write-Error') }).Count -eq 1) -and (@($cliPrintStatements | Where-Object { $_.Extent.Text.Contains("'DeviceBindingFailed'") }).Count -eq 1) -and $cliPostStatements.Count -ge 2) 'item 1 (b): the real console print path is extracted from the fast-llm.ps1 outer catch (one Write-Error, one DeviceBindingFailed test)'
        $cliPrintBlock=[scriptblock]::Create((($cliPrintStatements | ForEach-Object { $_.Extent.Text }) -join [Environment]::NewLine))
        $runCliPrint={
            param($Failure)
            & {
                param($failure,$Block)
                Set-StrictMode -Version 2
                $ErrorActionPreference='Stop'
                $operationLock=$null
                @(& $Block 2>&1 | ForEach-Object { [string]$_ })
            } $Failure $cliPrintBlock
        }
        $printed=@(& $runCliPrint $cliRecord)
        Check ($printed.Count -eq 1 -and $printed[0].StartsWith('device-binding-unavailable: ',[StringComparison]::Ordinal) -and $printed[0] -notmatch 'rawtoken-zq7' -and $printed[0] -notmatch 'bad code' -and $printed[0] -notmatch 'secret\.txt') 'item 1 (b): the CLI prints the sanitised code and none of the raw token for a device-binding failure whose message carries a raw code'
        # Discrimination: the same message and Data code without FastLlmReason prints unchanged (the raw prefix is not touched).
        $plainFailure=New-Object System.InvalidOperationException -ArgumentList $rawRun.failure.Message
        $plainFailure.Data['FastLlmFailureCode']='device-binding-unavailable'
        $plainRecord=New-Object System.Management.Automation.ErrorRecord($plainFailure,'FastLlmTest','NotSpecified',$null)
        $printedPlain=@(& $runCliPrint $plainRecord)
        Check ($printedPlain.Count -eq 1 -and $printedPlain[0] -ceq $rawRun.failure.Message -and $printedPlain[0] -match 'rawtoken-zq7') 'item 1 (b) discrimination: the same failure without FastLlmReason prints exactly as before (message unchanged)'
        # A conforming code already carries the sanitised prefix: printed unchanged.
        $okFailure=New-Object System.InvalidOperationException -ArgumentList 'device-binding-ambiguous: two candidates'
        $okFailure.Data['FastLlmFailureCode']='device-binding-ambiguous';$okFailure.Data['FastLlmReason']='DeviceBindingFailed'
        $printedOk=@(& $runCliPrint (New-Object System.Management.Automation.ErrorRecord($okFailure,'FastLlmTest','NotSpecified',$null)))
        Check ($printedOk.Count -eq 1 -and $printedOk[0] -ceq 'device-binding-ambiguous: two candidates') 'item 1 (b): a conforming device-binding failure prints exactly as before'
        # Round 9b: the CLI does not trust the Data code to be clean. A RAW Data code and a message '<raw code with a ": " inside>: detail' print the fixed withheld text,
        # status.json gets device-binding-unavailable, and no part of the raw token appears in either. (Real catch, $failure bound to an ErrorRecord.)
        $rawCode='bad: code C:\Users\rawtoken-zq7\secret.txt'
        $rawFailure=New-Object System.InvalidOperationException -ArgumentList ($rawCode+': detail-qq9')
        $rawFailure.Data['FastLlmFailureCode']=$rawCode;$rawFailure.Data['FastLlmReason']='DeviceBindingFailed'
        $rawFailRecord=New-Object System.Management.Automation.ErrorRecord($rawFailure,'FastLlmTest','NotSpecified',$null)
        $printedRaw=@(& $runCliPrint $rawFailRecord)
        Check ($printedRaw.Count -eq 1 -and $printedRaw[0] -ceq 'device-binding-unavailable: device binding failed (details withheld; see status)' -and $printedRaw[0] -notmatch 'rawtoken-zq7' -and $printedRaw[0] -notmatch 'bad' -and $printedRaw[0] -notmatch 'detail-qq9' -and $printedRaw[0] -notmatch 'secret') 'item 1 (b): a raw Data code with a ": " inside prints exactly the fixed withheld text (no part of the raw code or the detail)'
        $rawStatusRun=& $runCliCatch $rawFailRecord
        $rawStatus=$rawStatusRun.text | ConvertFrom-Json
        Check ($rawStatus.phase -ceq 'failed' -and $rawStatus.failureCode -ceq 'device-binding-unavailable' -and $rawStatusRun.text -notmatch 'rawtoken-zq7' -and $rawStatusRun.text -notmatch 'secret' -and $rawStatusRun.text -notmatch 'detail-qq9' -and $rawStatusRun.warnings.Count -eq 0) 'item 1 (b): the CLI catch records device-binding-unavailable in status.json for a raw Data code, with no part of the raw token in the file'
        $emptyFailure=New-Object System.InvalidOperationException -ArgumentList 'something: else'
        $emptyFailure.Data['FastLlmReason']='DeviceBindingFailed'
        $emptyRecord=New-Object System.Management.Automation.ErrorRecord($emptyFailure,'FastLlmTest','NotSpecified',$null)
        $emptyStatus=(& $runCliCatch $emptyRecord).text | ConvertFrom-Json
        Check ($emptyStatus.failureCode -ceq 'device-binding-unavailable' -and @(& $runCliPrint $emptyRecord)[0] -ceq 'device-binding-unavailable: device binding failed (details withheld; see status)') 'item 1 (b): an empty Data code on a DeviceBindingFailed failure becomes device-binding-unavailable in status.json and on the console'
        # (ii) conforming code and message: console and status.json unchanged
        $okStatus=(& $runCliCatch (New-Object System.Management.Automation.ErrorRecord($okFailure,'FastLlmTest','NotSpecified',$null))).text | ConvertFrom-Json
        Check ($okStatus.failureCode -ceq 'device-binding-ambiguous') 'item 1 (b): a conforming code is recorded unchanged in status.json'
        # (iii) discrimination: without FastLlmReason both the console and status.json behave exactly as before (no sanitising, even for a non-conforming code)
        $plain2=New-Object System.InvalidOperationException -ArgumentList 'plain code X: plain detail'
        $plain2.Data['FastLlmFailureCode']='plain code X'
        $plain2Record=New-Object System.Management.Automation.ErrorRecord($plain2,'FastLlmTest','NotSpecified',$null)
        $plain2Status=(& $runCliCatch $plain2Record).text | ConvertFrom-Json
        Check (@(& $runCliPrint $plain2Record)[0] -ceq 'plain code X: plain detail' -and $plain2Status.failureCode -ceq 'plain code X') 'item 1 (b) discrimination: without FastLlmReason the console prints and status.json records exactly as before'
        # The inline pattern in fast-llm.ps1 and the shared pattern in src/FastLlm.Runtime.ps1 are the same string (they cannot drift).
        $patternRx='''(\^device-binding-\[a-z-\]\{1,40\}\$)'''
        $cliPatterns=@([regex]::Matches([IO.File]::ReadAllText((Join-Path $root 'fast-llm.ps1')),$patternRx)|ForEach-Object { $_.Groups[1].Value })
        $rtPatterns=@([regex]::Matches([IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.Runtime.ps1')),$patternRx)|ForEach-Object { $_.Groups[1].Value })
        Check ($cliPatterns.Count -eq 1 -and $rtPatterns.Count -eq 1 -and $cliPatterns[0] -ceq $rtPatterns[0] -and $cliPatterns[0] -ceq '^device-binding-[a-z-]{1,40}$') 'item 1 (b): the device-binding code pattern in fast-llm.ps1 is the same string as the shared one in src/FastLlm.Runtime.ps1 (one occurrence each)'
    } finally { & $module {param($B) Set-Item -Path Function:script:New-FastLlmDeviceBindingFailure -Value $B} $newFailureBinding }
    Set-RealProbe $xtxReport
    & $module { function script:ConvertFrom-FastLlmServerDeviceListEntries { throw (New-Object InvalidOperationException 'secret-device-list-message') } }
    $enfCapErr=Invoke-BindRun -Name 'enforce-capture-error' -Binding 'enforce' -Mode 'pl-name'
    Test-EnforcePostLoad $enfCapErr '1' 'a capture error'
    Check ($enfCapErr.state.serverDeviceListCapture.error -ceq 'InvalidOperationException' -and -not (($enfCapErr.state | ConvertTo-Json -Depth 8) -match 'secret-device-list-message')) 'enforce: a capture error is the recorded type name only'
    & $module {param($B) Set-Item -Path Function:script:ConvertFrom-FastLlmServerDeviceListEntries -Value $B} $saved['ConvertFrom-FastLlmServerDeviceListEntries']

    # record is unchanged: the same failing server never gates, the start completes, the failed check is only recorded
    foreach($case in @(@('pl-total','5'),@('pl-name','3'),@('pl-using-missing','6'))){
        Set-RealProbe $xtxReport
        $recFail=Invoke-BindRun -Name ('record-'+$case[0]) -Binding 'record' -Mode $case[0] -AutoStop
        Check ($recFail.exit -eq 0 -and $recFail.stopperOk -and $recFail.state.phase -ceq 'stopped' -and $null -eq $recFail.state.failureCode -and $null -eq $recFail.failure -and $recFail.state.deviceBinding.mode -ceq 'record' -and $recFail.state.deviceBinding.postLoadCheck.result -ceq 'failed' -and $recFail.state.deviceBinding.postLoadCheck.item -ceq $case[1] -and $recFail.state.identityRecord -ceq 'recorded') ("record never gates: "+$case[0]+" is recorded as postLoadCheck failed item "+$case[1]+" and the start reaches Ready")
    }
    # off is untouched by the new mock shapes and modes
    Set-RealProbe $xtxReport
    $offAgain=Invoke-BindRun -Name 'off-after-enforce' -Binding 'off' -Mode 'pl-total' -AutoStop
    Check ($offAgain.exit -eq 0 -and $offAgain.stopperOk -and $null -eq $offAgain.state.PSObject.Properties['deviceBinding'] -and ($off.state.PSObject.Properties.Name -join ',') -ceq ($offAgain.state.PSObject.Properties.Name -join ',')) 'off: no deviceBinding even against a server whose device list would fail the check; same state field set'
    Set-RealProbe $xtxReport
    $suitePassed=$true
} finally {
    Restore-Mocks
    if($lock){$lock.Dispose()}
    # The scratch is removed on success AND on failure (the failure itself is reported by the throw, never by leftover folders).
    Remove-DevbindFolders
}

# ---------- usage ----------
$cli=Get-Content -LiteralPath (Join-Path $root 'fast-llm.ps1') -Raw
Check ($cli -match "(?s)\[ValidateSet\('off', 'record', 'enforce'\)\]\s*\[string\] \`$DeviceBinding = 'off'") 'the CLI declares -DeviceBinding off|record|enforce with the default off'
$u=Invoke-Cli 'plan -DeviceBinding record'
Check ($u.exited -and $u.exit -ne 0 -and $u.text -match 'supported only by a live start') 'usage: -DeviceBinding with a non-start action is rejected'
$u=Invoke-Cli 'start -DryRun -DeviceBinding record'
Check ($u.exited -and $u.exit -ne 0 -and $u.text -match 'supported only by a live start') 'usage: -DeviceBinding with -DryRun is rejected'
$u=Invoke-Cli 'doctor -DeviceBinding off'
Check ($u.exited -and $u.exit -ne 0 -and $u.text -match 'supported only by a live start') 'usage: an explicit -DeviceBinding off is rejected outside a live start, like -VulkanBarMitigation'
$u=Invoke-Cli 'plan -DeviceBinding enforce'
Check ($u.exited -and $u.exit -ne 0 -and $u.text -match 'supported only by a live start') 'usage: -DeviceBinding enforce with a non-start action is rejected'
$u=Invoke-Cli 'start -DryRun -DeviceBinding enforce'
Check ($u.exited -and $u.exit -ne 0 -and $u.text -match 'supported only by a live start') 'usage: -DeviceBinding enforce with -DryRun is rejected'
$u=Invoke-Cli 'start -DeviceBinding bogus'
Check ($u.exited -and $u.exit -ne 0 -and $u.text -match 'bogus|ValidateSet|enforce') 'usage: an unknown -DeviceBinding value is rejected by the parameter validation'

Check (@($devbindFolders | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0 -and $devbindFolders.Count -eq 6) 'none of this run''s fast-llm-devbind-* scratch folders remain'
} finally {
    Remove-DevbindFolders
}

Write-Host "$count device-binding checks passed. Mock services only; record observes and gates nothing, enforce fails a start only with a typed, never-recovered failure, and every default stays off."
