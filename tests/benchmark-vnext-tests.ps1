#requires -Version 5.1
# Mock-only tests for the v-next benchmark producer. No GPU benchmark is executed.
# Pure tests run on any OS. The end-to-end mock-server worker runs on native Windows only,
# as a standard user, like tests/benchmark-integration-tests.ps1.
# -SeamFree runs one benchmark against the mock HTTP server with NO seams installed: the real
# collectors, the real ADLX executable and its SHA-256. It needs native Windows, a standard user,
# and prints which seams were active (it fails unless that list is empty).
param([switch]$Worker,[string]$FixtureRoot,[switch]$SeamFree,[string]$AdlxExecutablePath,[string]$AdlxExecutableSha256,[int]$RecipeVramMiB=0,[string]$RecipeAdapterName,[string]$KeepPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
if($RecipeAdapterName -and $RecipeVramMiB -le 0){throw 'Usage error: -RecipeAdapterName requires -RecipeVramMiB (the name check needs the VRAM cross-check as well).'}

$repo=Split-Path $PSScriptRoot -Parent
# The worker's console output is not reliably captured by the parent; keep its failure text in a file.
trap{if($Worker -and $FixtureRoot){[IO.File]::WriteAllText((Join-Path $FixtureRoot 'worker-error.txt'),('at WORKER-FAILURE: '+$_.Exception.Message.Replace("`r",' ').Replace("`n",' ')+' STACK: '+$_.ScriptStackTrace.Replace("`r",' ').Replace("`n",' ')))};break}
$script:count=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:count++;Write-Host "PASS: $Message"}
function Reject([scriptblock]$Block,[string]$Pattern,[string]$Message){
    $text=$null
    try{& $Block|Out-Null}catch{$text=$_.Exception.Message}
    Check ($null -ne $text -and $text -match $Pattern) "$Message (got: $text)"
}
# Windows PowerShell 5.1 ConvertFrom-Json already turns ISO timestamps into local DateTime values.
function T($Value){
    if($Value -is [DateTime]){return $Value.ToUniversalTime()}
    return ([DateTime]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime()
}

Import-Module (Join-Path $repo 'src/FastLlm.psm1') -Force
$module=Get-Module FastLlm
function Set-Seam([string]$Name,$Block){& $module {param($n,$b) if($null -eq $b){$script:FastLlmBenchmarkSeams.Remove($n)}else{$script:FastLlmBenchmarkSeams[$n]=$b;$script:FastLlmBenchmarkAllowSeams=$true}} $Name $Block}
function Clear-Seams{& $module {$script:FastLlmBenchmarkSeams.Clear();$script:FastLlmBenchmarkAllowSeams=$false}}

# The join library is dot-sourced exactly as the producer does (read-only, mock rows only).
. (Join-Path $repo 'tools/collect-vulkan-luid-join.ps1') -OutputPath 'unused.json' -LibraryOnly

# ---------------------------------------------------------------- fixture builders
$sentinel='SENTINEL-7f3a91-raw-exception-text'
function global:H32([string]$Hex){return [uint32]::Parse($Hex,[Globalization.NumberStyles]::HexNumber)}
function global:New-FxVulkan($Index,$Luid,$Vendor,$Device,$Name,$Pci=$null,$Type=2){
    [pscustomobject]@{index=$Index;deviceLuid=$Luid;deviceLuidValid=$true;deviceNodeMask=1;vendorId=[uint32]$Vendor;deviceId=[uint32]$Device
        deviceName=$Name;pciBusInfoAdvertised=($null -ne $Pci);pciBusInfo=$Pci;deviceType=$Type}
}
function global:New-FxDxgi($Index,$Luid,$Vendor,$Device,$Sub,$Rev){
    [pscustomobject]@{index=$Index;adapterLuid=$Luid;vendorId=[uint32]$Vendor;deviceId=[uint32]$Device;subSysId=(H32 $Sub);revision=(H32 $Rev);flags=[uint32]0}
}
function global:New-FxKmt($Luid,$Bus,$Dev,$Fn){[pscustomobject]@{luid=$Luid;bus=$Bus;device=$Dev;function=$Fn;error=$null}}
function global:New-FxPnp($Id,$Location,$Version='32.0.31041.1004'){
    [pscustomobject]@{instanceId=$Id;locationInfo=$Location;hardwareIds=@('PCI\VEN_1002&DEV_744C');driverVersion=$Version;driverProvider='AMD'}
}
$luidA='00000000000a1b2c'
$luidB='00000000000a1b3d'
$pnpA='PCI\VEN_1002&DEV_744C&SUBSYS_E4711DA2&REV_C8\SYNTHETIC-00000008'
$pnpB='PCI\VEN_1002&DEV_744C&SUBSYS_E4711DA2&REV_C8\SYNTHETIC-00000010'
function global:New-FxSnapshot([object[]]$Vulkan,[object[]]$Dxgi,[object[]]$Kmt,[object[]]$Pnp,[bool]$VulkanError=$false){
    $joins=@(Join-VulkanLuidDevices -Vulkan $Vulkan -Dxgi $Dxgi -Kmt $Kmt -SetupApi $Pnp)
    [pscustomobject]@{vulkan=@($Vulkan);dxgi=@($Dxgi);pnp=@($Pnp);kmt=@($Kmt);joins=$joins;vulkanError=$VulkanError;dxgiError=$false;setupApiError=$false}
}
function global:New-FxUniqueSnapshot($Pci=$null,$Location='PCI bus 3, device 0, function 0',$Driver='32.0.31041.1004'){
    New-FxSnapshot @((New-FxVulkan 0 $luidA 0x1002 0x744c 'AMD Radeon RX 7900 XTX' $Pci)) @((New-FxDxgi 0 $luidA 0x1002 0x744c 'E4711DA2' 'C8')) @((New-FxKmt $luidA 3 0 0)) @((New-FxPnp $pnpA $Location $Driver))
}
function global:New-FxTwoAmdSnapshot{
    New-FxSnapshot @((New-FxVulkan 0 $luidA 0x1002 0x744c 'AMD Radeon RX 7900 XTX'),(New-FxVulkan 1 $luidB 0x1002 0x744c 'AMD Radeon RX 7900 XTX')) `
        @((New-FxDxgi 0 $luidA 0x1002 0x744c 'E4711DA2' 'C8'),(New-FxDxgi 1 $luidB 0x1002 0x744c 'E4711DA2' 'C8')) `
        @((New-FxKmt $luidA 3 0 0),(New-FxKmt $luidB 7 0 0)) @((New-FxPnp $pnpA 'PCI bus 3, device 0, function 0'),(New-FxPnp $pnpB 'PCI bus 7, device 0, function 0'))
}
function global:F($Value){[pscustomobject]@{status='available';adlxResult=0;value=$Value}}
function global:New-FxAdlx([string]$Pnp=$pnpA,$Low=662316,$High=0,[string]$Driver='32.0.31041.1004',[string]$Bus='PCIE_4_0',$Lanes=16,$TotalVram=24560){
    $record=[pscustomobject]@{
        gpuIndex=0;pnpString=(F $Pnp);luid=(F ([pscustomobject]@{lowPart=$Low;highPart=$High}));amdWindowsDriverVersion=(F $Driver)
        amdSoftwareVersion=(F '26.8.1');totalVramMB=(F $TotalVram);pciBusType=(F ([pscustomobject]@{raw=6;name=$Bus}));pciBusLaneWidth=(F $Lanes)
        biosInfo=(F ([pscustomobject]@{partNumber='113-4E4710U-T52';version='022.001.002.034';date='2024/01/16 00:00'}))
    }
    [pscustomobject]@{status='captured';reason=$null;records=@($record);header=[pscustomobject]@{collectorSha256=('a'*64);adlxDriverVersion='1.5.0.124';wrapperSourceSha256=('b'*64)}}
}
function Resolve-Fx($Snapshot,$Adlx=$null,$ProbeReason=$null){& $module {param($s,$a,$r) Resolve-FastLlmBenchmarkBinding $s $a $r} $Snapshot $Adlx $ProbeReason}
function New-FxHardware($Resolved,$PciLink,$Vram,$Mcfg=@(0)){& $module {param($r,$p,$v,$m) New-FastLlmBenchmarkHardwareIdentity $r.Binding $r.Joined $p $v $m} $Resolved $PciLink $Vram $Mcfg}
function global:New-FxHostInventory([bool]$WithErrors=$true){
    [pscustomobject]@{applicable=$true;qualified=$false;partial=$WithErrors
        errors=@(if($WithErrors){[pscustomobject]@{section='os';message=$global:FxSentinel;reason='access-denied'}})
        nativeHost=[pscustomobject]@{status='captured';advisory=[pscustomobject]@{cpuNames=[pscustomobject]@{status='captured';completeScan=$true;value=@('Synthetic CPU')}}}}
}
function global:New-FxNvidiaSnapshot{
    New-FxSnapshot @((New-FxVulkan 0 $luidA 0x10de 0x2684 'NVIDIA GeForce RTX 4090')) @((New-FxDxgi 0 $luidA 0x10de 0x2684 '00000000' '00')) @((New-FxKmt $luidA 1 0 0)) @((New-FxPnp 'PCI\VEN_10DE&DEV_2684&SUBSYS_00000000&REV_00\4&1' 'PCI bus 1, device 0, function 0'))
}
$rootPortLink=[pscustomobject]@{current=[pscustomobject]@{width=16;generation=4;speed='Gen4 16GT/s'};max=[pscustomobject]@{width=16;generation=4;speed='Gen4 16GT/s'}}
$rootPortA=[pscustomobject]@{InstanceId=$pnpA;RootPortInstanceId='PCI\VEN_8086&DEV_A70D&SUBSYS_88821043&REV_01\3&11583659&0&08';RootPortLocationPath='PCIROOT(0)#PCI(0100)';RootPortLink=$rootPortLink}
$domain0=[pscustomobject]@{domain=0;bus=3;device=0;function=0}
$global:FxSentinel=$sentinel
$global:FxRootPort=$rootPortA
$global:FxPnpB=$pnpB

# Telemetry rows use the real ADLX sample line shape.
function global:M($Value){'{"status":"available","adlxResult":0,"value":'+([double]$Value).ToString([Globalization.CultureInfo]::InvariantCulture)+'}'}
function global:New-FxTelemetryLine([DateTime]$Utc,$Sample,[string]$Pnp,$Usage=50){
    '{"schemaVersion":1,"kind":"adlx-sample","gpuIndex":0,"gpuCount":1,"utcFileTime":'+$Utc.ToFileTimeUtc()+',"sample":'+$Sample+
    ',"pnpString":{"status":"available","adlxResult":0,"value":"'+$Pnp.Replace('\','\\')+'"},"metricsResult":0,"gpuVramMB":{"status":"unsupported","adlxResult":0,"value":null}'+
    ',"gpuUsagePercent":'+(M $Usage)+',"gpuClockMHz":'+(M 2400)+',"gpuVramClockMHz":'+(M 1249)+',"gpuTotalBoardPowerW":'+(M 250)+
    ',"gpuTemperatureC":'+(M 60)+',"gpuHotspotTemperatureC":'+(M 80)+',"qualification":false,"servingDeviceBound":false}'
}

if(-not $Worker){
  if(-not $SeamFree){
    # ============================================================ preservation of the reviewed producer
    $v1Path=Join-Path $repo 'src/FastLlm.Benchmark.v1.ps1'
    $nextPath=Join-Path $repo 'src/FastLlm.Benchmark.ps1'
    Check ((Get-FileHash -LiteralPath $v1Path -Algorithm SHA256).Hash.ToLowerInvariant() -eq 'c8b64fe0a2e78e3974b63a127da9ae385ca84b51fba69505ee323ab5d464a43b') 'the preserved v1 producer is byte-identical to the reviewed c8b64fe0 producer'
    Check ((Get-Content -LiteralPath (Join-Path $repo 'src/FastLlm.psm1') -Raw) -notmatch 'Benchmark\.v1') 'the preserved v1 producer is not wired into the module'
    $v1Tokens=$null;$v1Errors=$null
    $v1Ast=[Management.Automation.Language.Parser]::ParseFile($v1Path,[ref]$v1Tokens,[ref]$v1Errors)
    $nextTokens=$null;$nextErrors=$null
    $nextAst=[Management.Automation.Language.Parser]::ParseFile($nextPath,[ref]$nextTokens,[ref]$nextErrors)
    Check ($v1Errors.Count -eq 0 -and $nextErrors.Count -eq 0) 'both producers parse under the running PowerShell parser'
    foreach($parsed in @('tools/benchmark.ps1','src/FastLlm.Runtime.ps1','tools/collect-vulkan-luid-join.ps1')){
        $parsedTokens=$null;$parsedErrors=$null
        [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $parsed),[ref]$parsedTokens,[ref]$parsedErrors)|Out-Null
        Check (@($parsedErrors).Count -eq 0) "$parsed parses under the running PowerShell parser"
    }
    foreach($name in @('Get-FastLlmStatistics','Get-FastLlmPromptArtifactSha256','Test-FastLlmBenchmarkFiniteNumber','ConvertFrom-FastLlmBenchmarkResponse')){
        $a=$v1Ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
        $b=$nextAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
        Check ($null -ne $a -and $null -ne $b -and $a.Extent.Text -ceq $b.Extent.Text) "$name is textually identical to the reviewed producer"
    }
    $forbidden=@($nextTokens|Where-Object {$_.Text -in @('??','?.','&&','||','??=')})
    Check ($forbidden.Count -eq 0) 'the producer uses no PowerShell 7 only operators'
    $ps7Pattern='-As'+'Hashtable|-Paral'+'lel|\[sh'+'ort\]'
    foreach($file in @('src/FastLlm.Benchmark.ps1','src/FastLlm.Runtime.ps1','src/WindowsInventory.ps1','src/ProcessHost.cs','src/WindowsVulkanLuidJoin.cs','tools/benchmark.ps1','tools/collect-vulkan-luid-join.ps1','tests/benchmark-vnext-tests.ps1','tests/process-host-device-list-tests.ps1')){
        $text=[IO.File]::ReadAllText((Join-Path $repo $file))
        Check ($text -notmatch '[^\x00-\x7f]') "$file is ASCII only (BOM-less file must parse under Windows PowerShell 5.1)"
        Check ($text -notmatch $ps7Pattern) "$file avoids PowerShell 6+ only constructs"
    }
    Add-Type -Path (Join-Path $repo 'src/WindowsCpuTopology.cs')
    Check $true 'Windows CPU topology helper compiles'

    # ============================================================ refusal typing
    Clear-Seams
    function Get-Reason($Item){& $module {param($e) Get-FastLlmBenchmarkErrorReason $e} $Item}
    Check ((Get-Reason (New-Object UnauthorizedAccessException('x'))) -eq 'access-denied') 'UnauthorizedAccessException is access-denied'
    Check ((Get-Reason (New-Object Security.SecurityException('x'))) -eq 'access-denied') 'SecurityException is access-denied'
    Check ((Get-Reason (New-Object TimeoutException('x'))) -eq 'timeout') 'TimeoutException is timeout'
    Check ((Get-Reason (New-Object IO.FileNotFoundException('x'))) -eq 'not-found') 'FileNotFoundException is not-found'
    Check ((Get-Reason (New-Object ComponentModel.Win32Exception(5))) -eq 'access-denied') 'Win32 error 5 is access-denied'
    Check ((Get-Reason (New-Object ComponentModel.Win32Exception(1460))) -eq 'timeout') 'Win32 error 1460 is timeout'
    Check ((Get-Reason (New-Object InvalidOperationException($sentinel))) -eq 'other') 'an unrecognized failure is other and its text is never consulted'
    Check ((Get-Reason (New-Object InvalidOperationException('wrapper',(New-Object UnauthorizedAccessException('inner'))))) -eq 'access-denied') 'an access-denied inner exception is found'
    Check ((Get-Reason (New-Object InvalidOperationException('Access is denied.'))) -eq 'other') 'message text alone never produces access-denied'
    $record=New-Object Management.Automation.ErrorRecord((New-Object Exception($sentinel)),'id',[Management.Automation.ErrorCategory]::PermissionDenied,$null)
    Check ((Get-Reason $record) -eq 'access-denied') 'a PermissionDenied error category is access-denied'
    $record=New-Object Management.Automation.ErrorRecord((New-Object Exception($sentinel)),'id',[Management.Automation.ErrorCategory]::OperationTimeout,$null)
    Check ((Get-Reason $record) -eq 'timeout') 'an OperationTimeout error category is timeout'

    $inventory=[pscustomobject]@{applicable=$true;qualified=$false;partial=$true;nativeHost=[pscustomobject]@{status='captured'}
        errors=@([pscustomobject]@{section='pnpControllers';message=$sentinel;reason='access-denied'},[pscustomobject]@{section='processors';message=$sentinel;reason='timeout'},
                 [pscustomobject]@{section='system';message=$sentinel;reason='not-found'},[pscustomobject]@{section='os';message=$sentinel;reason='bogus-reason'},
                 [pscustomobject]@{section='dxgi';message=$sentinel;reason='other'})}
    $clean=& $module {param($i) ConvertTo-FastLlmBenchmarkSanitizedInventory $i 'post'} $inventory
    $cleanJson=$clean.Inventory|ConvertTo-Json -Depth 8
    Check ($cleanJson -notmatch 'SENTINEL' -and $cleanJson -notmatch '"message"') 'sanitized inventory carries no raw message'
    Check (@($clean.Inventory.errors).Count -eq 5 -and @($clean.Inventory.errors|Where-Object {$_.PSObject.Properties['message']}).Count -eq 0) 'every error keeps its section and loses its message'
    Check (@($clean.Refusals).Count -eq 4 -and (@($clean.Refusals|ForEach-Object item) -join ',') -eq 'cim-video-controller,cim-processors,cim-system,cim-os') 'refusals use the closed cim list in section order'
    Check ((@($clean.Refusals|ForEach-Object reason) -join ',') -eq 'access-denied,timeout,not-found,other') 'refusal reasons are typed and an unknown reason collapses to other'
    Check (@($clean.Refusals|Where-Object {$_.phase -ne 'post'}).Count -eq 0) 'refusals record their capture phase'
    Check (@($inventory.errors|Where-Object {$_.message -eq $sentinel}).Count -eq 5) 'sanitizing does not modify its input'

    # ============================================================ host capture fields
    Check ((& $module {ConvertFrom-FastLlmBenchmarkPowerPlanText 'Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced)'}).plan -eq 'balanced') 'Balanced GUID maps to balanced'
    Check ((& $module {ConvertFrom-FastLlmBenchmarkPowerPlanText 'GUID: 8C5E7FDA-E8BF-4A96-9A85-A6E23A8C635C (x)'}).plan -eq 'high-performance') 'High performance GUID maps case-insensitively'
    Check ((& $module {ConvertFrom-FastLlmBenchmarkPowerPlanText 'a1841308-3541-4fab-bc81-f71556f20b4a'}).plan -eq 'power-saver') 'Power saver GUID maps'
    Check ((& $module {ConvertFrom-FastLlmBenchmarkPowerPlanText 'e9a42b02-d5df-448d-aa00-03f14749eb61'}).plan -eq 'ultimate-performance') 'Ultimate performance GUID maps'
    Check ((& $module {ConvertFrom-FastLlmBenchmarkPowerPlanText 'Power Scheme GUID: 11111111-2222-3333-4444-555555555555 (Custom)'}).plan -eq 'other') 'an unlisted GUID maps to other'
    Check ($null -eq (& $module {ConvertFrom-FastLlmBenchmarkPowerPlanText 'no guid here'})) 'text without a GUID is not parsed'

    Set-Seam 'BiosRegistry' {@{BaseBoardManufacturer='ASUSTeK COMPUTER INC.';BaseBoardProduct='System Product Name';BIOSVendor='American Megatrends Inc.';BIOSVersion='1801';BIOSReleaseDate='03/12/2024';SystemManufacturer='ASUS';SystemProductName=("x"*200)}}
    $bios=& $module {Get-FastLlmBenchmarkBiosField}
    Check ($bios.status -eq 'captured' -and $bios.value.BaseBoardProduct.value -eq 'System Product Name' -and $bios.value.BaseBoardProduct.placeholder -eq $true) 'a firmware placeholder passes through unchanged and is flagged'
    Check ($bios.value.BaseBoardManufacturer.placeholder -eq $false -and $bios.value.BIOSVersion.value -eq '1801') 'real firmware strings are not flagged'
    Check ($bios.value.SystemProductName.status -eq 'unknown' -and $bios.value.SystemProductName.reason -eq 'not-reported') 'an over-long firmware string is unknown, not truncated'
    Set-Seam 'BiosRegistry' {throw (New-Object UnauthorizedAccessException($global:FxSentinel))}
    $bios=& $module {Get-FastLlmBenchmarkBiosField}
    Check ($bios.status -eq 'refused' -and $bios.reason -eq 'access-denied' -and ($bios|ConvertTo-Json -Depth 5) -notmatch 'SENTINEL') 'a denied BIOS registry read is refused/access-denied without message text'
    Set-Seam 'BiosRegistry' {throw (New-Object InvalidOperationException($global:FxSentinel))}
    $bios=& $module {Get-FastLlmBenchmarkBiosField}
    Check ($bios.status -eq 'refused' -and $bios.reason -eq 'other' -and ($bios|ConvertTo-Json -Depth 5) -notmatch 'SENTINEL') 'another BIOS registry failure is refused/other without message text'
    Set-Seam 'Smbios' {throw (New-Object TimeoutException($global:FxSentinel))}
    $smbios=& $module {Get-FastLlmBenchmarkSmbiosField}
    Check ($smbios.status -eq 'refused' -and $smbios.reason -eq 'timeout') 'an SMBIOS timeout is refused/timeout'
    Set-Seam 'Smbios' {[pscustomobject]@{SmbiosMajor=3;SmbiosMinor=5;Type17Structures=2;PopulatedCount=2;EmptyCount=0;LogicalDeviceCountExcluded=0;InstalledCapacityComplete=$true;KnownInstalledCapacityBytes=[long]34359738368
        Devices=@([pscustomobject]@{Ordinal=0;CapacityStatus='reported';InstalledCapacityBytes=[long]17179869184;RatedSpeedStatus='reported';RatedSpeedMTps=[uint32]4800;ConfiguredSpeedStatus='reported';ConfiguredSpeedMTps=[uint32]4800},
                  [pscustomobject]@{Ordinal=1;CapacityStatus='reported';InstalledCapacityBytes=[long]17179869184;RatedSpeedStatus='reported';RatedSpeedMTps=[uint32]4800;ConfiguredSpeedStatus='reported';ConfiguredSpeedMTps=[uint32]4800})}}
    $smbios=& $module {Get-FastLlmBenchmarkSmbiosField}
    Check ($smbios.status -eq 'captured' -and @($smbios.value.devices).Count -eq 2 -and $smbios.value.devices[0].configuredSpeedMTps -eq 4800) 'in-run SMBIOS memory devices are captured'
    Set-Seam 'CpuTopology' {[pscustomobject]@{PhysicalCores=10;Packages=1;LogicalProcessors=16}}
    $topology=& $module {Get-FastLlmBenchmarkCpuTopologyField}
    Check ($topology.status -eq 'captured' -and $topology.value.physicalCores -eq 10 -and $topology.value.packages -eq 1) 'physical cores and packages come from the native topology reader'
    Set-Seam 'CpuTopology' {throw (New-Object InvalidOperationException($global:FxSentinel))}
    $topology=& $module {Get-FastLlmBenchmarkCpuTopologyField}
    Check ($topology.status -eq 'refused' -and $topology.reason -eq 'other') 'a topology failure is refused/other'
    Set-Seam 'CpuTopology' {[pscustomobject]@{PhysicalCores=10;Packages=1;LogicalProcessors=16}}
    # Pure topology parser over a synthesized GetLogicalProcessorInformationEx buffer.
    $buffer=New-Object byte[] 144
    foreach($spec in @(@(0,0,3),@(48,0,12),@(96,3,15))){
        [BitConverter]::GetBytes([int]$spec[1]).CopyTo($buffer,$spec[0]);[BitConverter]::GetBytes([int]48).CopyTo($buffer,$spec[0]+4)
        [BitConverter]::GetBytes([uint16]1).CopyTo($buffer,$spec[0]+30);[BitConverter]::GetBytes([uint64]$spec[2]).CopyTo($buffer,$spec[0]+32)
    }
    $parsed=[Bitworks.FastLlm.WindowsCpuTopology]::Parse($buffer,$buffer.Length)
    Check ($parsed.PhysicalCores -eq 2 -and $parsed.Packages -eq 1 -and $parsed.LogicalProcessors -eq 4) 'topology parser counts cores, packages and logical processors'
    $threw=$false;try{[Bitworks.FastLlm.WindowsCpuTopology]::Parse($buffer,100)|Out-Null}catch{$threw=$true}
    Check $threw 'topology parser rejects a truncated buffer'

    Set-Seam 'HostInventory' {New-FxHostInventory}
    Set-Seam 'PowerPlanText' {'Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced)'}
    Set-Seam 'BiosRegistry' {@{BIOSVendor='Vendor'}}
    $pre=& $module {Get-FastLlmBenchmarkHostCapture 'pre'}
    $capture=$pre.Capture
    Check ($capture.phase -eq 'pre' -and (T $capture.startUtc) -le (T $capture.endUtc)) 'host capture records its phase and start/end UTC'
    Check ($capture.fields.nativeHost.status -eq 'captured' -and $capture.fields.cpuLabel.status -eq 'captured' -and $capture.fields.powerPlan.value.plan -eq 'balanced' -and $capture.fields.cpuTopology.status -eq 'captured') 'host capture fields are captured independently'
    Check ($pre.PowerPlanText -match 'Balanced' -and @($pre.Refusals).Count -eq 1 -and $pre.Refusals[0].item -eq 'cim-os' -and $pre.Refusals[0].phase -eq 'pre') 'inventory refusals become typed records for the capture phase'
    Check (($pre.Inventory|ConvertTo-Json -Depth 8) -notmatch 'SENTINEL') 'the captured inventory has no raw message'
    Set-Seam 'HostInventory' {throw (New-Object UnauthorizedAccessException($global:FxSentinel))}
    $post=& $module {Get-FastLlmBenchmarkHostCapture 'post'}
    Check ($post.Capture.phase -eq 'post' -and $post.Capture.fields.nativeHost.status -eq 'refused' -and $post.Capture.fields.nativeHost.reason -eq 'access-denied' -and $post.Capture.fields.powerPlan.status -eq 'captured') 'a denied inventory is refused/access-denied and does not hide other fields'
    Check (($post.Capture|ConvertTo-Json -Depth 10) -notmatch 'SENTINEL' -and $null -eq $post.Inventory) 'a failed inventory leaves no raw text in the capture'
    Set-Seam 'PowerPlanText' {throw (New-Object InvalidOperationException($global:FxSentinel))}
    $post=& $module {Get-FastLlmBenchmarkHostCapture 'post'}
    Check ($post.Capture.fields.powerPlan.status -eq 'refused' -and $null -eq $post.PowerPlanText) 'an unreadable power plan is refused'
    Clear-Seams

    # ============================================================ binding
    Check ((& $module {ConvertTo-FastLlmBenchmarkLuidHex 1486082 0}) -eq '000000000016ad02') 'ADLX LUID low/high converts to DXGI hex'
    Check ((& $module {ConvertTo-FastLlmBenchmarkLuidHex 5 -1}) -eq 'ffffffff00000005') 'a negative ADLX LUID high part converts without overflow'
    $unique=Resolve-Fx (New-FxUniqueSnapshot)
    $b=$unique.Binding
    Check ($b.status -eq 'bound' -and $b.method -eq 'single-adapter-elimination+luid-chain' -and $b.amdAdapterCount -eq 1 -and $b.adapters[0].pnpInstanceId -eq $pnpA) 'a unique single AMD join is bound with the documented method'
    Check ($b.adapters[0].pci.vendorId -eq '1002' -and $b.adapters[0].pci.deviceId -eq '744C' -and $b.adapters[0].pci.subsystemId -eq 'E4711DA2' -and $b.adapters[0].pci.revision -eq 'C8' -and $b.adapters[0].dxgiLuid -eq $luidA -and $b.adapters[0].kmt.bus -eq 3 -and $b.adapters[0].kmt.segmentKnown -eq $false) 'the binding records PnP instance, PCI IDs, LUID and KMT address'
    Check ($b.adapters[0].driverVersion -eq '32.0.31041.1004' -and $b.adapters[0].driverVersionSources.crossCheck -eq 'not-run' -and $b.adlx.status -eq 'unknown' -and $b.adlx.reason -eq 'not-configured') 'without ADLX the cross-check is not-run and the ADLX facts are unknown'
    Check ($b.adapters[0].amdSoftwareVersion.status -eq 'unknown' -and $b.adapters[0].pcieBus.status -eq 'unknown' -and $b.adapters[0].vbios.status -eq 'unknown') 'ADLX-only fields are unknown when ADLX is absent'
    # optional ADLX probe: the argument check and the unavailable-probe binding (pure; the end-to-end runs are in the Windows worker below)
    Reject {& $module {Assert-FastLlmBenchmarkAdlxConfig '' '' -Optional}} 'AdlxOptional requires AdlxExecutablePath and AdlxExecutableSha256\.' 'AdlxOptional without either ADLX argument is an argument error'
    Reject {& $module {Assert-FastLlmBenchmarkAdlxConfig 'C:\x\adlx.exe' $null -Optional}} 'AdlxOptional requires AdlxExecutablePath and AdlxExecutableSha256\.' 'AdlxOptional with only the ADLX path is an argument error'
    Check ((& $module {Assert-FastLlmBenchmarkAdlxConfig '' ''}) -eq $false) 'without AdlxOptional and without ADLX arguments the check is unchanged (not configured)'
    $optionalUnavailable=[pscustomobject]@{status='unknown';reason='optional-probe-failed';optionalFailureReason='adlx-identity-collection-failed';records=@();header=$null}
    $optionalBinding=(Resolve-Fx (New-FxUniqueSnapshot) $optionalUnavailable).Binding
    Check ($optionalBinding.status -eq 'bound' -and $optionalBinding.adlx.status -eq 'unknown' -and $optionalBinding.adlx.reason -eq 'optional-probe-failed' -and $optionalBinding.adlx.optionalFailureReason -eq 'adlx-identity-collection-failed' -and $optionalBinding.adlx.crossCheck -eq 'not-run') 'an unavailable optional probe is recorded as unknown with reason optional-probe-failed and its specific failure reason'
    Check ($null -eq (Resolve-Fx (New-FxUniqueSnapshot)).Binding.adlx.PSObject.Properties['optionalFailureReason'] -and (& $module {param($x,$y) Assert-FastLlmBenchmarkBindingAgreement $x $y} $optionalBinding (Resolve-Fx (New-FxUniqueSnapshot) $optionalUnavailable).Binding) -match '^[0-9a-f]{64}$') 'optionalFailureReason is absent when ADLX was not attempted, and the pre/post agreement still holds with the same unavailable record'
    $stepCases=@(
        @('ADLX driver library is not a regular System32 file.','driver-not-regular'),
        @('ADLX driver library does not have a valid AMD publisher signature.','driver-signature'),
        @('ADLX driver library has no file version.','driver-version'),
        @('Executable digest mismatch.','executable-digest'),
        @('Executable path is not a regular file.','executable-missing'),
        @('Bounded native process host source is unavailable.','host-source-missing'),
        @('OutputPath already exists; choose a fresh report filename.','output-path'),
        @('OutputPath must be an absolute local file path.','output-path'),
        @('ADLX collector output rejected: too many lines.','collector-output'),
        @('Unexpected ADLX collector output.','collector-output'),
        @('ADLX collector output kind mismatch.','collector-output'),
        @('Get-Item: Cannot find path ''C:\Windows\System32\amdadlx64.dll'' because it does not exist.','driver-missing'),
        @('Add-Type: something failed','host-compile'),
        @('x.cs(3,4): error CS1002: ; expected','host-compile'),
        @('some entirely different failure text at /home/someone/secret.txt','unrecognized')
    )
    foreach($case in $stepCases){
        $stepGot=& $module {param($t) Get-FastLlmBenchmarkAdlxFailureStep $t} $case[0]
        Check ($stepGot -ceq $case[1]) "the ADLX failure step for '$($case[0])' is the token $($case[1])"
    }
    Check ((& $module {Get-FastLlmBenchmarkAdlxFailureStep 'anything' $true}) -ceq 'timeout' -and (& $module {Get-FastLlmBenchmarkAdlxFailureStep $null}) -ceq 'unknown') 'a timeout maps to timeout and no child output maps to unknown'
    $stepBinding=(Resolve-Fx (New-FxUniqueSnapshot) ([pscustomobject]@{status='unknown';reason='optional-probe-failed';optionalFailureReason='adlx-identity-collection-failed';optionalFailureExitCode=3;optionalFailureStep='driver-signature';records=@();header=$null})).Binding
    Check ($stepBinding.adlx.optionalFailureExitCode -eq 3 -and $stepBinding.adlx.optionalFailureStep -ceq 'driver-signature') 'the binding carries the exit code and the step token next to the failure reason'
    $badStepBinding=(Resolve-Fx (New-FxUniqueSnapshot) ([pscustomobject]@{status='unknown';reason='optional-probe-failed';optionalFailureReason='adlx-identity-collection-failed';optionalFailureExitCode='x';optionalFailureStep='C:\raw\text';records=@();header=$null})).Binding
    Check ($null -eq $badStepBinding.adlx.optionalFailureExitCode -and $badStepBinding.adlx.optionalFailureStep -ceq 'unknown') 'a non-integer exit code and a non-token step are never copied into the binding'
    $withAdlx=Resolve-Fx (New-FxUniqueSnapshot) (New-FxAdlx)
    $b=$withAdlx.Binding
    Check ($b.status -eq 'bound' -and $b.adlx.status -eq 'captured' -and $b.adlx.crossCheck -eq 'passed' -and $b.adlx.pnpMatch -eq $true -and $b.adlx.luidMatch -eq $true -and $b.adlx.driverVersionMatch -eq $true) 'ADLX PnP, LUID and driver cross-check passes'
    Check ($b.adapters[0].amdSoftwareVersion.value -eq '26.8.1' -and $b.adapters[0].pcieBus.value.generation -eq 4 -and $b.adapters[0].pcieBus.value.laneWidth -eq 16 -and $b.adapters[0].pcieBus.value.provenance -eq 'adlx-driver-reported' -and $b.adapters[0].vbios.value.partNumber -eq '113-4E4710U-T52') 'AMD software version, driver-reported PCIe link and VBIOS are recorded'
    Reject {Resolve-Fx (New-FxUniqueSnapshot) (New-FxAdlx -Driver '31.0.1.1')} 'differs from the SetupAPI driver version' 'an ADLX versus SetupAPI driver version mismatch is a hard failure'
    Reject {Resolve-Fx (New-FxUniqueSnapshot) (New-FxAdlx -Pnp ($pnpA.Replace('00000008','00000099')))} 'does not match the joined adapter' 'an ADLX identity that matches no joined PnP instance is a hard failure'
    Reject {Resolve-Fx (New-FxUniqueSnapshot) (New-FxAdlx -Low 999)} 'LUID does not match' 'an ADLX LUID that contradicts the DXGI LUID is a hard failure'
    $two=Resolve-Fx (New-FxTwoAmdSnapshot) (New-FxAdlx)
    Check ($two.Binding.status -eq 'ambiguous' -and $two.Binding.reason -eq 'multiple-amd-adapters' -and $two.Binding.selection -eq 'unbound' -and $two.Binding.amdAdapterCount -eq 2 -and @($two.Binding.adapters).Count -eq 2 -and $null -eq $two.Joined) 'multiple AMD adapters are ambiguous and unbound, with no guessed device'
    Check ($two.Binding.method -eq $null -and $two.Binding.note -match 'does not prove') 'an ambiguous binding carries no binding method'
    $nvidia=New-FxNvidiaSnapshot
    $none=Resolve-Fx $nvidia
    Check ($none.Binding.status -eq 'unbound' -and $none.Binding.reason -eq 'no-amd-adapter' -and $none.Binding.amdAdapterCount -eq 0 -and $none.Binding.vulkanDeviceCount -eq 1) 'a host with no AMD adapter is unbound'
    $failed=Resolve-Fx (New-FxSnapshot @() @() @() @() $true)
    Check ($failed.Binding.status -eq 'unbound' -and $failed.Binding.reason -eq 'vulkan-enumeration-failed') 'a failed Vulkan enumeration is unbound'
    $nojoin=Resolve-Fx (New-FxSnapshot @((New-FxVulkan 0 $luidA 0x1002 0x744c 'AMD')) @((New-FxDxgi 0 $luidA 0x1002 0x744c 'E4711DA2' 'C8')) @() @((New-FxPnp $pnpA 'PCI bus 3, device 0, function 0')))
    Check ($nojoin.Binding.status -eq 'unbound' -and $nojoin.Binding.reason -eq 'join-kmt-unavailable' -and $null -eq $nojoin.Joined) 'a single AMD adapter whose join is not unique is unbound with the failing hop'
    $probe=Resolve-Fx $null $null 'access-denied'
    Check ($probe.Binding.status -eq 'unbound' -and $probe.Binding.reason -eq 'identity-probe-failed' -and $probe.Binding.probeFailureReason -eq 'access-denied') 'a failed identity probe is unbound with a typed reason'
    $json=$unique.Binding|ConvertTo-Json -Depth 10
    Check ($json -notmatch '"prompt"|"content"|"tokens"') 'the binding block has no prompt/content/tokens keys'

    function Get-Agreement($A,$B){& $module {param($a,$b) Assert-FastLlmBenchmarkBindingAgreement $a $b} $A $B}
    Check ((Get-Agreement $unique.Binding (Resolve-Fx (New-FxUniqueSnapshot)).Binding) -match '^[0-9a-f]{64}$') 'identical pre and post snapshots agree'
    Reject {Get-Agreement $unique.Binding (Resolve-Fx (New-FxUniqueSnapshot -Driver '32.0.99999.1')).Binding} 'changed during' 'a driver change between snapshots is a hard failure'
    Reject {Get-Agreement $unique.Binding $two.Binding} 'changed during' 'a bound to ambiguous change is a hard failure'
    Reject {Get-Agreement $unique.Binding (Resolve-Fx $null $null 'other').Binding} 'changed during' 'a bound snapshot followed by a failed probe is a hard failure'
    Check ((Get-Agreement $none.Binding (Resolve-Fx $nvidia).Binding) -match '^[0-9a-f]{64}$') 'two unbound snapshots with the same reason agree'
    Reject {Get-Agreement $none.Binding $failed.Binding} 'changed during' 'unbound snapshots with different reasons disagree'

    # ============================================================ cross-check, S3, recipe driver
    $noLuid=New-FxAdlx;$noLuid.records[0].luid=[pscustomobject]@{status='unsupported';adlxResult=0;value=$null}
    $partial=Resolve-Fx (New-FxUniqueSnapshot $domain0) $noLuid
    Check ($partial.Binding.status -eq 'bound' -and $partial.Binding.adlx.crossCheck -eq 'partial' -and $partial.Binding.adlx.luidMatch -eq $null) 'a missing ADLX LUID gives a partial cross-check, not passed'
    Check ((New-FxHardware $partial @($rootPortA) 24576).OmitReason -eq 'cross-check-incomplete') 'hardwareIdentity requires a passed cross-check'
    $noDriver=New-FxAdlx;$noDriver.records[0].amdWindowsDriverVersion=[pscustomobject]@{status='unsupported';adlxResult=0;value=$null}
    Check ((Resolve-Fx (New-FxUniqueSnapshot $domain0) $noDriver).Binding.adlx.crossCheck -eq 'partial') 'a missing ADLX driver version gives a partial cross-check'
    Check ((Resolve-Fx (New-FxUniqueSnapshot $domain0) (New-FxAdlx)).Binding.adlx.crossCheck -eq 'passed') 'PNP, LUID and driver matches give a passed cross-check'
    $mixed=New-FxSnapshot @((New-FxVulkan 0 $luidA 0x1002 0x744c 'AMD Radeon RX 7900 XTX'),(New-FxVulkan 1 $luidB 0x10de 0x2684 'NVIDIA GeForce RTX 4090')) @((New-FxDxgi 0 $luidA 0x1002 0x744c 'E4711DA2' 'C8'),(New-FxDxgi 1 $luidB 0x10de 0x2684 '00000000' '00')) @((New-FxKmt $luidA 3 0 0),(New-FxKmt $luidB 7 0 0)) @((New-FxPnp $pnpA 'PCI bus 3, device 0, function 0'))
    $mixedResolved=Resolve-Fx $mixed (New-FxAdlx)
    Check ($mixedResolved.Binding.status -eq 'ambiguous' -and $mixedResolved.Binding.reason -eq 'multiple-vulkan-gpus' -and $mixedResolved.Binding.amdAdapterCount -eq 1 -and $mixedResolved.Binding.vulkanGpuCount -eq 2) 'an AMD plus a non-AMD GPU is ambiguous'
    $withCpu=New-FxSnapshot @((New-FxVulkan 0 $luidA 0x1002 0x744c 'AMD Radeon RX 7900 XTX'),(New-FxVulkan 1 $luidB 0x10005 0x0 'llvmpipe' $null 4)) @((New-FxDxgi 0 $luidA 0x1002 0x744c 'E4711DA2' 'C8')) @((New-FxKmt $luidA 3 0 0)) @((New-FxPnp $pnpA 'PCI bus 3, device 0, function 0'))
    Check ((Resolve-Fx $withCpu).Binding.status -eq 'bound') 'a CPU Vulkan device does not count as a second GPU'
    function Set-Driver($Resolved,$Recipe){& $module {param($r,$b) Set-FastLlmBenchmarkRecipeDriverVersion $r $b.Binding} $Recipe $Resolved}
    $noAdlxBound=Resolve-Fx (New-FxUniqueSnapshot $domain0)
    $bound=Resolve-Fx (New-FxUniqueSnapshot $domain0) (New-FxAdlx)
    $recipe=[pscustomobject]@{adapters=@([pscustomobject]@{device='Vulkan0';name='x';vramMiB=24576;driverVersion=$null;backend='Vulkan'})}
    $filled=Set-Driver $bound $recipe
    Check ($filled.status -eq 'filled' -and $recipe.adapters[0].driverVersion -eq '32.0.31041.1004' -and $recipe.adapters[0].driverVersionSource -eq 'setupapi-device-property+adlx-cross-check') 'the proven driver version fills a null recipe adapter driver version with provenance'
    $same=[pscustomobject]@{adapters=@([pscustomobject]@{device='Vulkan0';driverVersion='32.0.31041.1004'})}
    Check ((Set-Driver $bound $same).status -eq 'filled') 'an agreeing existing driver version is accepted'
    $differs=[pscustomobject]@{adapters=@([pscustomobject]@{device='Vulkan0';driverVersion='31.0.1.1'})}
    Reject {Set-Driver $bound $differs} 'disagrees with the proven' 'a disagreeing existing driver version is a hard failure'
    $untouched=[pscustomobject]@{adapters=@([pscustomobject]@{device='Vulkan0';driverVersion=$null})}
    $partialFill=Set-Driver $partial $untouched
    Check ($partialFill.status -eq 'not-filled' -and $partialFill.reason -eq 'cross-check-not-passed' -and $null -eq $untouched.adapters[0].driverVersion) 'a partial cross-check does not fill the driver version'
    $notBound=Set-Driver $two (([pscustomobject]@{adapters=@([pscustomobject]@{device='Vulkan0';driverVersion=$null})}))
    Check ($notBound.reason -eq 'binding-not-bound') 'an unbound adapter does not fill the driver version'
    $twoAdapters=[pscustomobject]@{adapters=@([pscustomobject]@{device='Vulkan0';driverVersion=$null},[pscustomobject]@{device='Vulkan1';driverVersion=$null})}
    Check ((Set-Driver $bound $twoAdapters).reason -eq 'recipe-adapter-count-not-one') 'two recipe adapters do not fill the driver version'
    Check ((Set-Driver $noAdlxBound ([pscustomobject]@{adapters=@([pscustomobject]@{device='Vulkan0';driverVersion=$null})})).reason -eq 'cross-check-not-passed') 'without ADLX the driver version is not filled'
    Check ((& $module {(New-FastLlmBenchmarkField 'captured' 1)|ConvertTo-Json -Compress}) -match '"reason":null') 'a field without a reason serializes null, not an empty string'
    Check ((& $module {(Resolve-FastLlmBenchmarkBinding $null $null $null).Binding|ConvertTo-Json -Depth 5 -Compress}) -match '"probeFailureReason":null') 'an absent probe failure reason serializes null'

    # ============================================================ hardwareIdentity
    $expected=(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/vnext-hardware-identity.json') -Raw|ConvertFrom-Json).expectedHardwareIdentity
    $bound=Resolve-Fx (New-FxUniqueSnapshot $domain0) (New-FxAdlx)
    $hardware=New-FxHardware $bound @($rootPortA) 24576
    Check ($null -ne $hardware.HardwareIdentity -and $null -eq $hardware.OmitReason) 'a fully proven bound adapter yields a hardware identity'
    $identity=$hardware.HardwareIdentity
    Check ((@($identity.Keys) -join ',') -eq 'adapters,topology') 'hardwareIdentity has exactly the adapters and topology keys'
    $actual=$identity.adapters[0]
    $names=@($expected.adapters[0].PSObject.Properties|ForEach-Object Name)
    Check ((@($actual.Keys) -join ',') -eq ($names -join ',')) 'the adapter keys equal the recipe schema adapter keys in order'
    foreach($name in $names){Check ($actual[$name] -ceq $expected.adapters[0].$name) "hardwareIdentity adapter $name equals the shared fixture"}
    Check (@($identity.topology.gpuLinks).Count -eq 0 -and $identity.topology.peerToPeer -eq $false -and @($expected.topology.gpuLinks).Count -eq 0) 'a single adapter has an empty link list and no peer-to-peer'
    Check ($hardware.Provenance.linkWidth -eq 'adlx-driver-reported' -and $hardware.Provenance.linkGeneration -eq 'adlx-driver-reported' -and $hardware.Provenance.pciSegment -eq 'acpi-mcfg-single-segment-0' -and @($hardware.Provenance.pciSegmentCorroboration) -contains 'vulkan-pci-bus-info-domain-0') 'provenance sits beside the identity; the segment is proven by MCFG and corroborated by Vulkan'
    foreach($deviceId in @('460D','A70D')){
        $port=[pscustomobject]@{InstanceId=$pnpA;RootPortInstanceId="PCI\VEN_8086&DEV_$deviceId&SUBSYS_88821043&REV_01\3&1&0&08";RootPortLocationPath='PCIROOT(0)#PCI(0100)'}
        Check ((New-FxHardware $bound @($port) 24576).HardwareIdentity.adapters[0].attachment -eq 'cpu') "Intel PEG root port $deviceId is classified cpu"
    }
    $explicit=Resolve-Fx (New-FxUniqueSnapshot $null 'PCI segment 0 bus 3, device 0, function 0') (New-FxAdlx)
    $viaLocation=New-FxHardware $explicit @($rootPortA) 24576
    Check ($null -ne $viaLocation.HardwareIdentity -and $viaLocation.Provenance.pciSegment -eq 'acpi-mcfg-single-segment-0' -and @($viaLocation.Provenance.pciSegmentCorroboration) -contains 'setupapi-location-explicit-segment-0') 'an explicit SetupAPI segment 0 is corroboration only'
    Check ((New-FxHardware $explicit @($rootPortA) 24576 @()).OmitReason -eq 'pci-segment-unknown') 'an explicit SetupAPI segment 0 alone does not prove the segment'
    Check ((New-FxHardware $bound @($rootPortA) 24576 @()).OmitReason -eq 'pci-segment-unknown') 'a Vulkan domain 0 alone does not prove the segment'
    # omit reasons, each in isolation
    Check ((New-FxHardware $two @($rootPortA) 24576).OmitReason -eq 'binding-not-bound') 'omit reason binding-not-bound'
    Check ((New-FxHardware (Resolve-Fx (New-FxUniqueSnapshot) (New-FxAdlx)) @($rootPortA) 24576).OmitReason -eq $null) 'MCFG single segment 0 proves the segment without any Vulkan or SetupAPI segment'
    Check ((New-FxHardware (Resolve-Fx (New-FxUniqueSnapshot ([pscustomobject]@{domain=1;bus=3;device=0;function=0})) (New-FxAdlx)) @($rootPortA) 24576).OmitReason -eq 'pci-segment-conflict') 'omit reason pci-segment-conflict when the Vulkan domain disagrees with MCFG'
    Check ((New-FxHardware (Resolve-Fx (New-FxUniqueSnapshot $null 'PCI segment 1 bus 3, device 0, function 0') (New-FxAdlx)) @($rootPortA) 24576).OmitReason -eq 'pci-segment-conflict') 'omit reason pci-segment-conflict when an explicit SetupAPI segment disagrees with MCFG'
    $disagree=Resolve-Fx (New-FxUniqueSnapshot ([pscustomobject]@{domain=0;bus=4;device=0;function=0})) (New-FxAdlx)
    Check ($disagree.Binding.status -ne 'bound' -and (New-FxHardware $disagree @($rootPortA) 24576).OmitReason -eq 'binding-not-bound') 'a Vulkan versus KMT address disagreement never binds, so no hardware identity is emitted'
    Check ((New-FxHardware $bound @($rootPortA) $null).OmitReason -eq 'vram-unknown') 'omit reason vram-unknown'
    Check ((New-FxHardware $bound @($rootPortA) 0).OmitReason -eq 'vram-unknown') 'omit reason vram-unknown for a zero total'
    Check ((New-FxHardware $bound @() 24576).OmitReason -eq 'root-port-unknown') 'omit reason root-port-unknown'
    $noPort=[pscustomobject]@{InstanceId=$pnpA;RootPortInstanceId=$null;RootPortLocationPath=$null}
    Check ((New-FxHardware $bound @($noPort) 24576).OmitReason -eq 'root-port-unknown') 'omit reason root-port-unknown for a device without an identified root port'
    foreach($vendorDevice in @('VEN_8086&DEV_1234','VEN_1022&DEV_1453')){
        $port=[pscustomobject]@{InstanceId=$pnpA;RootPortInstanceId="PCI\$vendorDevice&SUBSYS_00000000&REV_00\3&1&0&08";RootPortLocationPath='PCIROOT(0)#PCI(0100)'}
        $result=New-FxHardware $bound @($port) 24576
        Check ($result.OmitReason -eq 'attachment-unclassified' -and $null -eq $result.HardwareIdentity) "omit reason attachment-unclassified for $vendorDevice (chipset is never assumed)"
    }
    $noAdlxBound=Resolve-Fx (New-FxUniqueSnapshot $domain0)
    Check ((New-FxHardware $noAdlxBound @($rootPortA) 24576).OmitReason -eq 'link-unknown') 'omit reason link-unknown without ADLX'
    $badLink=Resolve-Fx (New-FxUniqueSnapshot $domain0) (New-FxAdlx -Bus 'PCIE_UNKNOWN')
    Check ((New-FxHardware $badLink @($rootPortA) 24576).OmitReason -eq 'link-unknown') 'omit reason link-unknown for an unparsable bus type'

    # ============================================================ ACPI MCFG segment proof
    Add-Type -Path (Join-Path $repo 'src/WindowsAcpiMcfg.cs')
    function New-FxMcfg([int[]]$Segments,[bool]$FixChecksum=$true){
        $bytes=New-Object byte[] (44+16*$Segments.Count)
        [Text.Encoding]::ASCII.GetBytes('MCFG').CopyTo($bytes,0)
        [BitConverter]::GetBytes([uint32]$bytes.Length).CopyTo($bytes,4)
        $bytes[8]=1
        for($i=0;$i -lt $Segments.Count;$i++){
            $o=44+16*$i
            [BitConverter]::GetBytes([uint64](3758096384+$i*268435456)).CopyTo($bytes,$o)
            [BitConverter]::GetBytes([uint16]$Segments[$i]).CopyTo($bytes,$o+8)
            $bytes[$o+10]=0;$bytes[$o+11]=255
        }
        if($FixChecksum){$sum=0;foreach($b in $bytes){$sum=($sum+$b) -band 255};$bytes[9]=[byte]((256-$sum) -band 255)}
        return ,$bytes
    }
    $one=[Bitworks.FastLlm.WindowsAcpiMcfg]::ParseSegments((New-FxMcfg @(0)))
    Check ($one.Length -eq 1 -and $one[0] -eq 0) 'MCFG with one segment group 0 parses to [0]'
    $two=[Bitworks.FastLlm.WindowsAcpiMcfg]::ParseSegments((New-FxMcfg @(0,1)))
    Check ($two.Length -eq 2 -and $two[0] -eq 0 -and $two[1] -eq 1) 'MCFG with two segment groups parses to both'
    $dup=[Bitworks.FastLlm.WindowsAcpiMcfg]::ParseSegments((New-FxMcfg @(0,0)))
    Check ($dup.Length -eq 1) 'repeated allocation entries for one segment collapse to one segment'
    $badTables=@{
        'truncated'=[byte[]](1,2,3)
        'bad checksum'=(New-FxMcfg @(0) $false)
        'wrong signature'=([byte[]](,0x58*60))
    }
    $wrongLength=[byte[]](New-FxMcfg @(0));[BitConverter]::GetBytes([uint32]99).CopyTo($wrongLength,4);$badTables['wrong length']=$wrongLength
    $noEntries=New-Object byte[] 44;[Text.Encoding]::ASCII.GetBytes('MCFG').CopyTo($noEntries,0);[BitConverter]::GetBytes([uint32]44).CopyTo($noEntries,4);$badTables['no entries']=$noEntries
    foreach($name in $badTables.Keys){
        $threw=$false;try{[Bitworks.FastLlm.WindowsAcpiMcfg]::ParseSegments([byte[]]$badTables[$name])|Out-Null}catch{$threw=$true}
        Check $threw "malformed MCFG ($name) is rejected"
    }
    $nosegBound=Resolve-Fx (New-FxUniqueSnapshot) (New-FxAdlx)
    $viaMcfg=& $module {param($r,$p) New-FastLlmBenchmarkHardwareIdentity $r.Binding $r.Joined $p 24576 @(0)} $nosegBound @($rootPortA)
    Check ($null -ne $viaMcfg.HardwareIdentity -and $viaMcfg.Provenance.pciSegment -eq 'acpi-mcfg-single-segment-0') 'a single MCFG segment 0 proves the segment'
    foreach($segments in @(@(),@(1),@(0,1))){
        $r=& $module {param($r,$p,$m) New-FastLlmBenchmarkHardwareIdentity $r.Binding $r.Joined $p 24576 $m} $nosegBound @($rootPortA) $segments
        Check ($r.OmitReason -eq 'pci-segment-unknown') ("MCFG segments [$($segments -join ',')] leave the segment unknown")
    }
    Set-Seam 'Mcfg' {throw (New-Object UnauthorizedAccessException($global:FxSentinel))}
    $evidence=& $module {Get-FastLlmBenchmarkMcfgEvidence}
    Check ($evidence.status -eq 'unknown' -and $evidence.reason -eq 'access-denied' -and ($evidence|ConvertTo-Json) -notmatch 'SENTINEL') 'an MCFG read failure is typed and carries no message'
    Set-Seam 'Mcfg' {@(0)}
    Check ((& $module {Get-FastLlmBenchmarkMcfgEvidence}).segments[0] -eq 0) 'MCFG evidence lists the segments'
    Clear-Seams

    # ============================================================ telemetry accounting
    $t0=[DateTime]::SpecifyKind((T '2026-10-06T10:00:00.0000000Z'),[DateTimeKind]::Utc)
    function Get-FxRows([string[]]$Lines){@($Lines|ForEach-Object {& $module {param($l) ConvertFrom-FastLlmBenchmarkTelemetryLine $l} $_})}
    function Get-FxAccounting($Times,$Start,$End){& $module {param($t,$i,$s,$e) Get-FastLlmBenchmarkTelemetryAccounting $t $i $s $e} ([DateTime[]]@($Times)) 1000 $Start $End}
    $steady=@(-1..10|ForEach-Object {$t0.AddSeconds($_)})
    $acc=Get-FxAccounting $steady $t0 $t0.AddSeconds(9)
    $ov=$acc.overlapWithTimedWindow
    Check ($acc.sampleCount -eq 12 -and $acc.largestGapMs -eq 1000 -and $acc.droppedCount -eq 0 -and $acc.observedMedianIntervalMs -eq 1000) 'a steady 1 Hz series has no drops and a 1000 ms largest gap'
    Check ($ov.overlapMs -eq 9000 -and $ov.coverageFraction -eq 1 -and $ov.firstSampleAtOrBeforeWindowStart -and $ov.lastSampleAtOrAfterWindowEnd -and $ov.rowsInsideWindow -eq 10) 'overlap with the timed window is accounted'
    $gapped=@($steady|Where-Object {$_ -ne $t0.AddSeconds(4) -and $_ -ne $t0.AddSeconds(5)})
    $acc=Get-FxAccounting $gapped $t0 $t0.AddSeconds(9)
    Check ($acc.largestGapMs -eq 3000 -and $acc.droppedCount -eq 2 -and $acc.overlapWithTimedWindow.largestGapAroundWindowMs -eq 3000) 'a missing pair of ticks is a 3000 ms gap and two dropped samples'
    $early=@(-1..5|ForEach-Object {$t0.AddSeconds($_)})
    $acc=Get-FxAccounting $early $t0 $t0.AddSeconds(9)
    Check ($acc.overlapWithTimedWindow.overlapMs -eq 5000 -and -not $acc.overlapWithTimedWindow.lastSampleAtOrAfterWindowEnd -and [Math]::Abs($acc.overlapWithTimedWindow.coverageFraction-5/9) -lt 1e-9) 'a sampler that stopped early shows partial overlap'
    $acc=Get-FxAccounting @() $t0 $t0.AddSeconds(9)
    Check ($acc.sampleCount -eq 0 -and $null -eq $acc.firstSampleUtc -and $acc.overlapWithTimedWindow.overlapMs -eq 0) 'no rows give an empty accounting'
    $acc=Get-FxAccounting @($t0.AddSeconds(20),$t0.AddSeconds(21)) $t0 $t0.AddSeconds(9)
    Check ($acc.overlapWithTimedWindow.overlapMs -eq 0 -and $acc.overlapWithTimedWindow.rowsInsideWindow -eq 0) 'rows entirely after the window do not overlap it'

    $sidecarPath=Join-Path ([IO.Path]::GetTempPath()) ('fastllm-vnext-sidecar-'+[Guid]::NewGuid().ToString('N')+'.jsonl')
    try{
        $lines=@('{"schemaVersion":1,"kind":"adlx-run-header","qualification":false,"servingDeviceBound":false,"mode":"sample"}')
        $n=0
        foreach($t in $steady){$lines+=(New-FxTelemetryLine $t $n $pnpA (10+$n));$lines+=(New-FxTelemetryLine $t $n $pnpB 1);$n++}
        $torn=New-FxTelemetryLine $t0.AddSeconds(11) 12 $pnpA 5
        [IO.File]::WriteAllText($sidecarPath,(($lines+$torn.Substring(0,60)) -join "`n"))
        $read=& $module {param($p) Read-FastLlmBenchmarkTelemetrySidecar $p} $sidecarPath
        Check (@($read.Rows).Count -eq 24 -and $read.TornLastLine -eq $true -and $read.MalformedLines -eq 0 -and -not $read.FooterSeen) 'a torn final line is counted, not fatal, and a missing footer is tolerated'
        $withFooter=$sidecarPath+'.footer'
        [IO.File]::WriteAllText($withFooter,((@($lines)+'{"schemaVersion":1,"kind":"adlx-run-footer","qualification":false,"servingDeviceBound":false,"status":"failed","collectorLines":3}') -join "`n"))
        $footer=& $module {param($p) Read-FastLlmBenchmarkTelemetrySidecar $p} $withFooter
        Remove-Item -LiteralPath $withFooter -Force
        Check ($footer.FooterSeen -eq $true -and $footer.FooterStatus -eq 'failed') 'the sampler footer status is surfaced'
        $sha=& $module {param($p) Get-FastLlmBenchmarkFileSha256 $p} $sidecarPath
        Check ($sha -eq (Get-FileHash -LiteralPath $sidecarPath -Algorithm SHA256).Hash.ToLowerInvariant()) 'the sidecar digest equals SHA-256 of the file'
        $windows=@([pscustomobject]@{requestedPromptTokens=16;repetition=1;start=$t0.AddMilliseconds(1500);end=$t0.AddMilliseconds(3500)},
                   [pscustomobject]@{requestedPromptTokens=16;repetition=2;start=$t0.AddMilliseconds(3600);end=$t0.AddMilliseconds(3900)})
        $report=& $module {param($s,$p,$a,$b,$w,$h) New-FastLlmBenchmarkTelemetryReport $s $p 1000 $a $b $w $true 'x.telemetry.jsonl' $h 1234} $read $pnpA $t0 $t0.AddSeconds(9) $windows $sha
        Check ($report.status -eq 'captured' -and $report.sampleCount -eq 12 -and $report.droppedCount -eq 0 -and $report.cadenceMs -eq 1000 -and $report.terminatedByProducer -eq $true -and $report.tornLastLine -eq $true) 'the telemetry block filters to the bound device and records accounting'
        Check ($report.sidecar.sha256 -eq $sha -and $report.sidecar.fileName -eq 'x.telemetry.jsonl' -and $report.observer -eq 'adlx-driver-reported') 'the sidecar is bound by SHA-256 and labelled driver-reported'
        $first=$report.perSample[0];$second=$report.perSample[1]
        Check ($first.rowCount -eq 2 -and $first.metrics.gpuUsagePercent.count -eq 2 -and $first.metrics.gpuUsagePercent.minimum -eq 13 -and $first.metrics.gpuUsagePercent.maximum -eq 14 -and $first.metrics.gpuUsagePercent.median -eq 13.5 -and $first.metrics.gpuUsagePercent.mean -eq 13.5) 'per-sample statistics summarize the rows inside the sample window'
        Check ($first.metrics.gpuClockMHz.median -eq 2400 -and $first.metrics.gpuTotalBoardPowerW.maximum -eq 250 -and $first.metrics.gpuHotspotTemperatureC.minimum -eq 80) 'every telemetry metric has statistics'
        Check ($second.rowCount -eq 0 -and $second.metrics.gpuUsagePercent.count -eq 0 -and $null -eq $second.metrics.gpuUsagePercent.median) 'a sample window with no row has empty statistics, not invented values'
        $other=& $module {param($s,$a,$b,$w) New-FastLlmBenchmarkTelemetryReport $s 'PCI\VEN_1002&DEV_FFFF\none' 1000 $a $b $w $false 'x' ('a'*64) 1} $read $t0 $t0.AddSeconds(9) $windows
        Check ($other.status -eq 'unknown' -and $other.reason -eq 'no-rows-for-bound-device' -and $other.sampleCount -eq 0) 'rows of another GPU are never attributed to the bound device'
        $partial=& $module {param($s,$p,$a,$b,$w) New-FastLlmBenchmarkTelemetryReport $s $p 1000 $a $b $w $false 'x' ('a'*64) 1} $read $pnpA $t0 $t0.AddSeconds(30) $windows
        Check ($partial.status -eq 'partial') 'a sampler that ends before the window ends is partial'
    } finally { Remove-Item -LiteralPath $sidecarPath -Force -ErrorAction SilentlyContinue }

    # ============================================================ ADLX parameter validation
    $adlxFile=Join-Path ([IO.Path]::GetTempPath()) ('fastllm-vnext-adlx-'+[Guid]::NewGuid().ToString('N')+'.bin')
    try{
        [IO.File]::WriteAllBytes($adlxFile,[byte[]](1,2,3,4))
        $adlxSha=(Get-FileHash -LiteralPath $adlxFile -Algorithm SHA256).Hash.ToLowerInvariant()
        function Test-AdlxConfig($p,$s){& $module {param($p,$s) Assert-FastLlmBenchmarkAdlxConfig $p $s} $p $s}
        Check ((Test-AdlxConfig '' '') -eq $false) 'absent ADLX configuration is simply not configured'
        Reject {Test-AdlxConfig $adlxFile ''} 'supplied together' 'a path without a digest is rejected'
        Reject {Test-AdlxConfig '' $adlxSha} 'supplied together' 'a digest without a path is rejected'
        Reject {Test-AdlxConfig $adlxFile 'abc'} '64-character' 'a malformed digest is rejected'
        Reject {Test-AdlxConfig $adlxFile ('0'*64)} 'digest does not match' 'a digest mismatch is a hard failure'
        Check ((Test-AdlxConfig $adlxFile $adlxSha.ToUpperInvariant()) -eq $true) 'a matching executable digest is accepted'
    } finally { Remove-Item -LiteralPath $adlxFile -Force -ErrorAction SilentlyContinue }

    # ============================================================ producer v-next.1 additions
    function Get-FxFailureReason([scriptblock]$Block){
        try{& $Block|Out-Null}catch{return (& $module {param($e) Get-FastLlmBenchmarkFailureReason $e} $_)}
        return $null
    }
    Check ((& $module {$script:FastLlmProducerVersion}) -eq 'vnext.4') 'the producer version constant is vnext.4'

    # 1. a partial Vulkan enumeration never binds
    $partialEnum=New-FxUniqueSnapshot $domain0;$partialEnum.vulkanError=$true
    $pe=Resolve-Fx $partialEnum (New-FxAdlx)
    Check ($pe.Binding.status -eq 'unbound' -and $pe.Binding.reason -eq 'vulkan-enumeration-failed' -and $null -eq $pe.Joined -and $pe.Binding.amdAdapterCount -eq 1) 'a Vulkan enumeration error with one AMD device visible is unbound with a typed reason'
    $partialTwo=New-FxTwoAmdSnapshot;$partialTwo.vulkanError=$true
    Check ((Resolve-Fx $partialTwo).Binding.reason -eq 'vulkan-enumeration-failed') 'a Vulkan enumeration error takes precedence over the multi-adapter ambiguity'

    # 2. the join child environment is cleaned like the server launch, and policy is explicit
    $savedVk=$env:VK_ICD_FILENAMES;$savedGgml=$env:GGML_VK_VISIBLE_DEVICES;$savedKeep=$env:FASTLLM_VNEXT_KEEP
    try{
        $env:VK_ICD_FILENAMES='fixture-icd';$env:GGML_VK_VISIBLE_DEVICES='0';$env:FASTLLM_VNEXT_KEEP='keep'
        $cleaned=& $module {param($t) New-FastLlmBenchmarkChildStartInfo $t @('-OutputPath','C:\out\join.json') -ClearEngineEnvironment} 'C:\tools\join.ps1'
        $plain=& $module {param($t) New-FastLlmBenchmarkChildStartInfo $t @('-Mode','identity')} 'C:\tools\adlx.ps1'
        Check (-not $cleaned.EnvironmentVariables.ContainsKey('VK_ICD_FILENAMES') -and -not $cleaned.EnvironmentVariables.ContainsKey('GGML_VK_VISIBLE_DEVICES') -and $cleaned.EnvironmentVariables.ContainsKey('FASTLLM_VNEXT_KEEP')) 'the join child environment drops VK_* and GGML_* and keeps unrelated variables'
        Check ($plain.EnvironmentVariables.ContainsKey('VK_ICD_FILENAMES')) 'a child that is not cleaned keeps the inherited environment'
        Check ($cleaned.Arguments -notmatch 'ExecutionPolicy' -and $plain.Arguments -notmatch 'ExecutionPolicy' -and $cleaned.Arguments -notmatch 'Bypass' -and $plain.Arguments -notmatch 'Bypass') 'child PowerShell processes set no -ExecutionPolicy and inherit the entry policy, never Bypass'
        Check ($cleaned.Arguments -match '-OutputPath' -and $plain.Arguments -match '-Mode' -and $cleaned.UseShellExecute -eq $false) 'child arguments are preserved'
    } finally {
        $env:VK_ICD_FILENAMES=$savedVk;$env:GGML_VK_VISIBLE_DEVICES=$savedGgml;$env:FASTLLM_VNEXT_KEEP=$savedKeep
        Remove-Item Env:\FASTLLM_VNEXT_KEEP -ErrorAction SilentlyContinue
        if($null -eq $savedVk){Remove-Item Env:\VK_ICD_FILENAMES -ErrorAction SilentlyContinue}
        if($null -eq $savedGgml){Remove-Item Env:\GGML_VK_VISIBLE_DEVICES -ErrorAction SilentlyContinue}
    }

    # 2b. recipe adapter name and VRAM versus the bound device and ADLX
    function Get-RecipeAgreement($Recipe,$Resolved){& $module {param($r,$x) Test-FastLlmBenchmarkRecipeAdapterAgreement $r $x} $Recipe $Resolved}
    function New-FxRecipe($Name='AMD Radeon RX 7900 XTX',$Vram=24576){[pscustomobject]@{adapters=@([pscustomobject]@{device='Vulkan0';name=$Name;vramMiB=$Vram})}}
    $agreeBound=Resolve-Fx (New-FxUniqueSnapshot $domain0) (New-FxAdlx)
    $agree=Get-RecipeAgreement (New-FxRecipe) $agreeBound
    Check ($agree.status -eq 'agree' -and $agree.name.status -eq 'agree' -and $agree.vram.status -eq 'agree' -and $agree.vram.adlxTotalMiB -eq 24560) 'a recipe adapter that matches the bound device name and ADLX VRAM agrees'
    Check ((Get-RecipeAgreement (New-FxRecipe '  amd  RADEON rx 7900 xtx ') $agreeBound).name.status -eq 'agree') 'the name comparison ignores case and whitespace'
    Check ($agree.name.recipe -ceq 'amd radeon rx 7900 xtx' -and $agree.name.bound -ceq 'amd radeon rx 7900 xtx' -and $agree.name.recipeRaw -ceq 'AMD Radeon RX 7900 XTX' -and $agree.name.boundRaw -ceq 'AMD Radeon RX 7900 XTX') 'name.recipe and name.bound are both normalized and the raw strings are kept in separate fields'
    $messyName=(Get-RecipeAgreement (New-FxRecipe '  amd  RADEON rx 7900 xtx ') $agreeBound).name
    Check ($messyName.recipe -ceq $messyName.bound -and $messyName.recipeRaw -ceq '  amd  RADEON rx 7900 xtx ') 'a messy recipe name is normalized in recipe and preserved in recipeRaw'
    Check ((Get-RecipeAgreement (New-FxRecipe 'AMD Radeon RX 7900 XTX' 23100) $agreeBound).vram.status -eq 'agree') 'a VRAM difference inside 6 percent agrees'
    $nameBad=Get-RecipeAgreement (New-FxRecipe 'AMD Radeon RX 6800') $agreeBound
    Check ($nameBad.status -eq 'mismatch' -and $nameBad.reason -eq 'recipe-adapter-name-mismatch') 'a recipe adapter name that differs from the bound device is a mismatch'
    $vramBad=Get-RecipeAgreement (New-FxRecipe 'AMD Radeon RX 7900 XTX' 23000) $agreeBound
    Check ($vramBad.status -eq 'mismatch' -and $vramBad.reason -eq 'recipe-adapter-vram-mismatch') 'a VRAM difference beyond 6 percent is a mismatch'
    $noAdlxAgree=Get-RecipeAgreement (New-FxRecipe) (Resolve-Fx (New-FxUniqueSnapshot $domain0))
    Check ($noAdlxAgree.status -eq 'agree' -and $noAdlxAgree.vram.status -eq 'not-checked' -and $noAdlxAgree.vram.reason -eq 'adlx-vram-unavailable') 'without ADLX only the name is checked'
    Check ((Get-RecipeAgreement ([pscustomobject]@{adapters=@()}) $agreeBound).reason -eq 'recipe-adapter-count-not-one') 'a recipe without one adapter is not checked'
    Check ((Get-RecipeAgreement (New-FxRecipe) (Resolve-Fx (New-FxTwoAmdSnapshot))).reason -eq 'binding-not-bound') 'an unbound binding is not checked'
    $applyResolved=Resolve-Fx (New-FxUniqueSnapshot $domain0) (New-FxAdlx)
    $applied=& $module {param($r,$rec) Set-FastLlmBenchmarkBindingRecipeCrossCheck $r $rec} $applyResolved (New-FxRecipe 'Some Other GPU')
    Check ($applyResolved.Binding.status -eq 'ambiguous' -and $applyResolved.Binding.reason -eq 'recipe-adapter-name-mismatch' -and $applyResolved.Binding.selection -eq 'unbound' -and $null -eq $applyResolved.Binding.method -and $null -eq $applyResolved.Joined -and $applyResolved.Binding.recipeAdapterCrossCheck.status -eq 'mismatch') 'a recipe mismatch makes the binding ambiguous with a typed reason and drops the joined device'
    Check ((New-FxHardware $applyResolved @($rootPortA) 24576).OmitReason -eq 'binding-not-bound' -and (Set-Driver $applyResolved (New-FxRecipe)).reason -eq 'binding-not-bound') 'an ambiguous recipe mismatch yields no hardware identity and no driver fill'
    $okResolved=Resolve-Fx (New-FxUniqueSnapshot $domain0) (New-FxAdlx)
    & $module {param($r,$rec) Set-FastLlmBenchmarkBindingRecipeCrossCheck $r $rec|Out-Null} $okResolved (New-FxRecipe)
    Check ($okResolved.Binding.status -eq 'bound' -and $okResolved.Binding.recipeAdapterCrossCheck.status -eq 'agree' -and $null -ne $okResolved.Joined) 'an agreeing recipe leaves the binding bound'

    # 2c. engine-reported serving device versus the bound adapter's D3DKMT address
    function Get-ServingAgreement($Capture,$Resolved){& $module {param($c,$r) Test-FastLlmBenchmarkServingDeviceAgreement $c $r} $Capture $Resolved}
    function Set-ServingCrossCheck($Resolved,$Capture){& $module {param($r,$c) Set-FastLlmBenchmarkBindingServingDeviceCrossCheck $r $c} $Resolved $Capture}
    function New-FxCapture($Id='0000:03:00.0'){[pscustomobject]@{deviceInfo=@();usingDevice=@([pscustomobject]@{name='ROCm0';id=$Id;freeMiB=1;description='x'});usingDeviceLikeLines=1;usingDeviceMalformedLines=0;usingDeviceOverflow=$false}}
    function New-FxServingBound(){Resolve-Fx (New-FxUniqueSnapshot $domain0) (New-FxAdlx)}
    $servingMethod='engine-reported-pci-address-vs-d3dkmt-address'
    $sAgree=Get-ServingAgreement (New-FxCapture) (New-FxServingBound)
    Check ($sAgree.status -eq 'agree' -and $null -eq $sAgree.reason -and $sAgree.servedDeviceId -ceq '0000:03:00.0' -and $sAgree.method -ceq $servingMethod -and (@($sAgree.Keys) -join ',') -eq 'status,reason,servedDeviceId,method') 'an engine-reported address equal to the bound D3DKMT address agrees'
    $sAgreeResolved=New-FxServingBound
    Set-ServingCrossCheck $sAgreeResolved (New-FxCapture)|Out-Null
    Check ($sAgreeResolved.Binding.status -eq 'bound' -and $sAgreeResolved.Binding.servingDeviceCrossCheck.status -eq 'agree' -and $null -ne $sAgreeResolved.Joined) 'an agreeing serving device leaves the binding bound and records the evidence'
    $sBadResolved=New-FxServingBound
    $sBadResolved.Binding.adapters[0].kmt.bus=4
    $sBad=Get-ServingAgreement (New-FxCapture) $sBadResolved
    Check ($sBad.status -eq 'mismatch' -and $sBad.reason -eq 'serving-device-mismatch' -and $sBad.servedDeviceId -ceq '0000:03:00.0') 'an engine-reported address that differs from the bound D3DKMT address is a mismatch'
    Set-ServingCrossCheck $sBadResolved (New-FxCapture)|Out-Null
    Check ($sBadResolved.Binding.status -eq 'ambiguous' -and $sBadResolved.Binding.reason -eq 'serving-device-mismatch' -and $sBadResolved.Binding.selection -eq 'unbound' -and $null -eq $sBadResolved.Binding.method -and $null -eq $sBadResolved.Joined -and $sBadResolved.Binding.servingDeviceCrossCheck.status -eq 'mismatch') 'a serving device mismatch makes the binding ambiguous with a typed reason and drops the joined device'
    $sUnknownResolved=New-FxServingBound
    $sUnknown=Get-ServingAgreement (New-FxCapture 'unknown') $sUnknownResolved
    Check ($sUnknown.status -eq 'not-available' -and $sUnknown.reason -eq 'engine-reported-unknown-device-id' -and $sUnknown.servedDeviceId -ceq 'unknown') 'a Vulkan engine device id of unknown is not available'
    Set-ServingCrossCheck $sUnknownResolved (New-FxCapture 'UNKNOWN')|Out-Null
    Check ($sUnknownResolved.Binding.status -eq 'bound' -and $sUnknownResolved.Binding.servingDeviceCrossCheck.reason -eq 'engine-reported-unknown-device-id' -and $null -ne $sUnknownResolved.Joined) 'an unknown engine device id (any case) leaves the binding bound'
    $sBound=New-FxServingBound
    $sAbsent=Get-ServingAgreement $null $sBound
    Check ($sAbsent.status -eq 'not-available' -and $sAbsent.reason -eq 'capture-absent' -and $null -eq $sAbsent.servedDeviceId) 'an absent capture is not available'
    $sError=Get-ServingAgreement ([pscustomobject]@{error='IOException'}) $sBound
    Check ($sError.status -eq 'not-available' -and $sError.reason -eq 'capture-error') 'a failed capture is not available'
    $overflowCapture=New-FxCapture;$overflowCapture.usingDeviceOverflow=$true
    $malformedCapture=New-FxCapture;$malformedCapture.usingDeviceMalformedLines=1
    Check ((Get-ServingAgreement $overflowCapture $sBound).reason -eq 'capture-incomplete' -and (Get-ServingAgreement $overflowCapture $sBound).status -eq 'not-available') 'an overflowed capture is incomplete'
    Check ((Get-ServingAgreement $malformedCapture $sBound).reason -eq 'capture-incomplete' -and (Get-ServingAgreement $malformedCapture $sBound).status -eq 'not-available') 'a capture with malformed lines is incomplete'
    $emptyCapture=New-FxCapture;$emptyCapture.usingDevice=@()
    $sEmpty=Get-ServingAgreement $emptyCapture $sBound
    Check ($sEmpty.status -eq 'not-available' -and $sEmpty.reason -eq 'no-using-device' -and $null -eq $sEmpty.servedDeviceId) 'a capture without a using device is not available'
    $twoCapture=New-FxCapture;$twoCapture.usingDevice=@([pscustomobject]@{name='ROCm0';id='0000:03:00.0'},[pscustomobject]@{name='ROCm1';id='0000:04:00.0'})
    $sTwoResolved=New-FxServingBound
    $sTwo=Get-ServingAgreement $twoCapture $sTwoResolved
    Check ($sTwo.status -eq 'mismatch' -and $sTwo.reason -eq 'multiple-using-devices' -and $null -eq $sTwo.servedDeviceId) 'two engine devices cannot be attributed to one bound adapter'
    Set-ServingCrossCheck $sTwoResolved $twoCapture|Out-Null
    Check ($sTwoResolved.Binding.status -eq 'ambiguous' -and $sTwoResolved.Binding.reason -eq 'multiple-using-devices' -and $null -eq $sTwoResolved.Joined) 'multiple engine devices make the binding ambiguous'
    $sGarbage=Get-ServingAgreement (New-FxCapture 'garbage') $sBound
    Check ($sGarbage.status -eq 'not-available' -and $sGarbage.reason -eq 'served-device-id-unparsed' -and $sGarbage.servedDeviceId -ceq 'garbage') 'an unparseable engine device id is not available'
    $nonString=New-FxCapture;$nonString.usingDevice[0].id=7
    Check ((Get-ServingAgreement $nonString $sBound).reason -eq 'engine-reported-unknown-device-id' -and $null -eq (Get-ServingAgreement $nonString $sBound).servedDeviceId) 'a non-string engine device id is not available and not echoed'
    $sDomain=Get-ServingAgreement (New-FxCapture '0001:03:00.0') $sBound
    Check ($sDomain.status -eq 'not-available' -and $sDomain.reason -eq 'served-device-pci-domain-nonzero') 'a nonzero PCI domain is not comparable to a segment-less D3DKMT address'
    $sUnboundResolved=Resolve-Fx (New-FxTwoAmdSnapshot)
    $sUnboundStatus=$sUnboundResolved.Binding.status;$sUnboundReason=$sUnboundResolved.Binding.reason
    $sUnbound=Get-ServingAgreement (New-FxCapture) $sUnboundResolved
    Set-ServingCrossCheck $sUnboundResolved (New-FxCapture)|Out-Null
    Check ($sUnbound.status -eq 'not-available' -and $sUnbound.reason -eq 'binding-not-bound' -and $sUnboundResolved.Binding.status -eq $sUnboundStatus -and $sUnboundStatus -ne 'bound' -and $sUnboundResolved.Binding.reason -eq $sUnboundReason -and $sUnboundResolved.Binding.servingDeviceCrossCheck.reason -eq 'binding-not-bound') 'an unbound binding is not checked and left unchanged'
    $sNoKmtResolved=New-FxServingBound
    $sNoKmtResolved.Binding.adapters[0].Remove('kmt')
    $sNoKmt=Get-ServingAgreement (New-FxCapture) $sNoKmtResolved
    Check ($sNoKmt.status -eq 'not-available' -and $sNoKmt.reason -eq 'bound-address-unavailable') 'a bound adapter without a D3DKMT address is not comparable'
    $sUpperResolved=New-FxServingBound
    $sUpperResolved.Binding.adapters[0].kmt.bus=10
    $sUpper=Get-ServingAgreement (New-FxCapture '0000:0A:00.0') $sUpperResolved
    Check ($sUpper.status -eq 'agree' -and $null -eq $sUpper.reason -and $sUpper.servedDeviceId -ceq '0000:0A:00.0') 'uppercase hex is parsed and compared as integers'
    $fpA=New-FxServingBound;$fpB=New-FxServingBound
    Set-ServingCrossCheck $fpA (New-FxCapture)|Out-Null;Set-ServingCrossCheck $fpB (New-FxCapture)|Out-Null
    Check ((& $module {param($b) Get-FastLlmBenchmarkBindingFingerprint $b} $fpA.Binding) -ceq (& $module {param($b) Get-FastLlmBenchmarkBindingFingerprint $b} $fpB.Binding)) 'two identical bindings with the same agreeing capture produce equal fingerprints'

    # 3. host capture pre/post stability
    Set-Seam 'HostInventory' {New-FxHostInventory}
    Set-Seam 'PowerPlanText' {'Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced)'}
    Set-Seam 'BiosRegistry' {@{BIOSVendor='Vendor';BIOSVersion='1801'}}
    Set-Seam 'CpuTopology' {[pscustomobject]@{PhysicalCores=10;Packages=1;LogicalProcessors=16}}
    Set-Seam 'Smbios' {[pscustomobject]@{SmbiosMajor=3;SmbiosMinor=5;Type17Structures=1;PopulatedCount=1;EmptyCount=0;LogicalDeviceCountExcluded=0;InstalledCapacityComplete=$true;KnownInstalledCapacityBytes=[long]17179869184
        Devices=@([pscustomobject]@{Ordinal=0;CapacityStatus='reported';InstalledCapacityBytes=[long]17179869184;RatedSpeedStatus='reported';RatedSpeedMTps=[uint32]4800;ConfiguredSpeedStatus='reported';ConfiguredSpeedMTps=[uint32]4800})}}
    $stablePre=& $module {Get-FastLlmBenchmarkHostCapture 'pre'}
    $stablePost=& $module {Get-FastLlmBenchmarkHostCapture 'post'}
    $comparedFields=& $module {param($a,$b) Assert-FastLlmBenchmarkHostCaptureStable $a $b} $stablePre.Capture $stablePost.Capture
    Check ((@($comparedFields) -join ',') -eq 'powerPlan,cpuTopology,smbiosMemory,boardBios') 'identical pre and post host captures are stable and report the compared fields'
    function Get-HostChange([scriptblock]$Mutate){
        & $Mutate
        $changedPost=& $module {Get-FastLlmBenchmarkHostCapture 'post'}
        return @(& $module {param($a,$b) Get-FastLlmBenchmarkHostCaptureChanges $a $b} $stablePre.Capture $changedPost.Capture)
    }
    Check (((Get-HostChange {Set-Seam 'PowerPlanText' {'Power Scheme GUID: 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c  (High performance)'}}) -join ',') -eq 'powerPlan') 'a changed power plan GUID is detected'
    Set-Seam 'PowerPlanText' {'Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced)'}
    Check (((Get-HostChange {Set-Seam 'BiosRegistry' {@{BIOSVendor='Vendor';BIOSVersion='1802'}}}) -join ',') -eq 'boardBios') 'a changed BIOS string is detected'
    Set-Seam 'BiosRegistry' {@{BIOSVendor='Vendor';BIOSVersion='1801'}}
    Check (((Get-HostChange {Set-Seam 'CpuTopology' {[pscustomobject]@{PhysicalCores=8;Packages=1;LogicalProcessors=16}}}) -join ',') -eq 'cpuTopology') 'a changed CPU topology is detected'
    Set-Seam 'CpuTopology' {[pscustomobject]@{PhysicalCores=10;Packages=1;LogicalProcessors=16}}
    Check (((Get-HostChange {Set-Seam 'Smbios' {[pscustomobject]@{SmbiosMajor=3;SmbiosMinor=5;Type17Structures=1;PopulatedCount=1;EmptyCount=0;LogicalDeviceCountExcluded=0;InstalledCapacityComplete=$true;KnownInstalledCapacityBytes=[long]8589934592
        Devices=@([pscustomobject]@{Ordinal=0;CapacityStatus='reported';InstalledCapacityBytes=[long]8589934592;RatedSpeedStatus='reported';RatedSpeedMTps=[uint32]4800;ConfiguredSpeedStatus='reported';ConfiguredSpeedMTps=[uint32]4800})}}}) -join ',') -eq 'smbiosMemory') 'changed SMBIOS memory is detected'
    Set-Seam 'PowerPlanText' {'Power Scheme GUID: 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c  (High performance)'}
    $changedPost=& $module {Get-FastLlmBenchmarkHostCapture 'post'}
    Reject {& $module {param($a,$b) Assert-FastLlmBenchmarkHostCaptureStable $a $b} $stablePre.Capture $changedPost.Capture} 'Host capture changed' 'a power plan change between captures is a hard failure'
    Check ((Get-FxFailureReason {& $module {param($a,$b) Assert-FastLlmBenchmarkHostCaptureStable $a $b} $stablePre.Capture $changedPost.Capture}) -eq 'host-capture-changed') 'the host capture failure has the typed reason host-capture-changed'

    # S3 (v-next.2): a field is compared only when both phases captured it; a status flip has its own typed reason
    function New-FxStableCap($Power='balanced',$Topology=10,$Smbios='a',$Bios='1801',[hashtable]$Override=@{}){
        $f=[ordered]@{
            powerPlan=[ordered]@{status='captured';reason=$null;value=[ordered]@{guid='x';plan=$Power}}
            cpuTopology=[ordered]@{status='captured';reason=$null;value=[ordered]@{physicalCores=$Topology}}
            smbiosMemory=[ordered]@{status='captured';reason=$null;value=[ordered]@{kind=$Smbios}}
            boardBios=[ordered]@{status='captured';reason=$null;value=[ordered]@{BIOSVersion=$Bios}}
        }
        foreach($k in @($Override.Keys)){$f[$k]=$Override[$k]}
        return [pscustomobject]@{fields=$f}
    }
    function Get-FxComparison($Pre,$Post){& $module {param($a,$b) Get-FastLlmBenchmarkHostCaptureComparison $a $b} $Pre $Post}
    function Get-FxStableError($Pre,$Post){try{& $module {param($a,$b) Assert-FastLlmBenchmarkHostCaptureStable $a $b} $Pre $Post|Out-Null}catch{return $_};return $null}
    function Get-FxReasonOf($ErrorRecord){& $module {param($e) Get-FastLlmBenchmarkFailureReason $e} $ErrorRecord}
    $refusedDenied=[ordered]@{status='refused';reason='access-denied';value=$null}
    $refusedTimeout=[ordered]@{status='refused';reason='timeout';value=$null}
    $unknownField=[ordered]@{status='unknown';reason='not-reported';value=$null}
    $flip=Get-FxComparison (New-FxStableCap) (New-FxStableCap -Override @{cpuTopology=$refusedDenied})
    Check (@($flip.Changes).Count -eq 1 -and $flip.Changes[0].field -eq 'cpuTopology' -and $flip.Changes[0].reason -eq 'host-capture-status-changed' -and (@($flip.ComparedFields) -join ',') -eq 'powerPlan,smbiosMemory,boardBios') 'a captured to refused flip is host-capture-status-changed, not a value change'
    $flipError=Get-FxStableError (New-FxStableCap) (New-FxStableCap -Override @{cpuTopology=$refusedDenied})
    Check ($null -ne $flipError -and (Get-FxReasonOf $flipError) -eq 'host-capture-status-changed' -and $flipError.Exception.Message -match 'Host capture changed' -and $flipError.Exception.Message -notmatch 'access-denied') 'the status flip is a hard failure with its own typed reason and no refusal text'
    $flipChanges=@(& $module {param($e) Get-FastLlmBenchmarkFailureHostChanges $e} $flipError)
    Check ($flipChanges.Count -eq 1 -and $flipChanges[0].field -eq 'cpuTopology' -and $flipChanges[0].reason -eq 'host-capture-status-changed') 'the failure carries the per-field change list for the failure report'
    Check ((@(& $module {param($a,$b) Get-FastLlmBenchmarkHostCaptureChanges $a $b} (New-FxStableCap) (New-FxStableCap -Override @{cpuTopology=$refusedDenied})) -join ',') -eq 'cpuTopology') 'the change name list names a flipped field'
    $both=Get-FxComparison (New-FxStableCap -Override @{smbiosMemory=$refusedDenied}) (New-FxStableCap -Override @{smbiosMemory=$refusedTimeout})
    Check (@($both.Changes).Count -eq 0 -and (@($both.ComparedFields) -join ',') -eq 'powerPlan,cpuTopology,boardBios') 'a field refused in both phases is no change and is not listed as compared, even when the refusal reasons differ'
    $bothAssert=& $module {param($a,$b) Assert-FastLlmBenchmarkHostCaptureStable $a $b} (New-FxStableCap -Override @{smbiosMemory=$refusedDenied}) (New-FxStableCap -Override @{smbiosMemory=$refusedDenied})
    Check ((@($bothAssert) -join ',') -eq 'powerPlan,cpuTopology,boardBios') 'a field refused in both phases passes and only the compared fields are returned'
    $unk=Get-FxComparison (New-FxStableCap -Override @{boardBios=$unknownField}) (New-FxStableCap -Override @{boardBios=$refusedDenied})
    Check (@($unk.Changes).Count -eq 1 -and $unk.Changes[0].reason -eq 'host-capture-status-changed') 'unknown versus refused is a status flip'
    $mix=Get-FxComparison (New-FxStableCap) (New-FxStableCap -Topology 8 -Override @{boardBios=$refusedDenied})
    Check (@($mix.Changes).Count -eq 2) 'a value change and a flip are both listed'
    Check ((Get-FxReasonOf (Get-FxStableError (New-FxStableCap) (New-FxStableCap -Topology 8 -Override @{boardBios=$refusedDenied}))) -eq 'host-capture-changed') 'a real value change takes precedence in the typed reason'
    $sameCap=Get-FxComparison (New-FxStableCap -Topology 8) (New-FxStableCap -Topology 8)
    Check (@($sameCap.Changes).Count -eq 0 -and @($sameCap.ComparedFields).Count -eq 4) 'identical captured fields are compared and listed'
    Clear-Seams

    # 4. root-port link corroboration
    function Add-LinkEvidence($Link,$Pcie){& $module {param($l,$p) Add-FastLlmBenchmarkRootPortLinkEvidence ([ordered]@{status='captured';reason=$null}) $l $p} $Link $Pcie}
    $adlxPcie=[pscustomobject]@{laneWidth=16;generation=4}
    $linkAgree=Add-LinkEvidence $rootPortA $adlxPcie
    Check ($linkAgree.provenance -eq 'setupapi-root-port-link' -and $linkAgree.current.width -eq 16 -and $linkAgree.current.generation -eq 4 -and $linkAgree.current.speed -eq 'Gen4 16GT/s' -and $linkAgree.max.width -eq 16 -and $linkAgree.adlxComparison.status -eq 'agree' -and $linkAgree.status -eq 'captured') 'the root-port current and max link are recorded with provenance and compared with ADLX'
    $narrow=[pscustomobject]@{RootPortLink=[pscustomobject]@{current=[pscustomobject]@{width=8;generation=1;speed='Gen1 2.5GT/s'};max=[pscustomobject]@{width=16;generation=4;speed='Gen4 16GT/s'}}}
    $linkDisagree=Add-LinkEvidence $narrow $adlxPcie
    Check ($linkDisagree.adlxComparison.status -eq 'disagree' -and $linkDisagree.adlxComparison.widthMatchesCurrent -eq $false -and $linkDisagree.adlxComparison.generationMatchesCurrent -eq $false -and $linkDisagree.status -eq 'captured') 'a link disagreement is recorded, not fatal'
    $noLink=Add-LinkEvidence ([pscustomobject]@{RootPortLink=$null}) $adlxPcie
    Check ($noLink.adlxComparison.status -eq 'not-compared' -and $null -eq $noLink.current -and $noLink.provenance -eq 'setupapi-root-port-link') 'an unread root-port link is not compared'
    $noAdlxLink=Add-LinkEvidence $rootPortA $null
    Check ($noAdlxLink.adlxComparison.status -eq 'not-compared' -and $noAdlxLink.adlxComparison.reason -eq 'adlx-link-unavailable' -and $noAdlxLink.current.width -eq 16) 'without an ADLX link the corroboration is recorded and not compared'
    $node=[pscustomobject]@{CurrentLinkWidth=[pscustomobject]@{Raw=[uint32]16;Decoded='x16'};CurrentLinkSpeed=[pscustomobject]@{Raw=[uint32]4;Generation=4;Decoded='Gen4 16GT/s'}
        MaxLinkWidth=[pscustomobject]@{Raw=[uint32]16;Decoded='x16'};MaxLinkSpeed=[pscustomobject]@{Raw=$null;Generation=$null;Decoded=$null}}
    $converted=& $module {param($n) ConvertTo-FastLlmBenchmarkRootPortLink $n} $node
    Check ($converted.current.width -eq 16 -and $converted.current.generation -eq 4 -and $converted.max.width -eq 16 -and $null -eq $converted.max.generation -and $null -eq $converted.max.speed) 'the root-port node properties convert to numbers, with unread values null'
    Check ($null -eq (& $module {ConvertTo-FastLlmBenchmarkRootPortLink $null})) 'no root-port node gives no link'

    # S1/S8 (v-next.2): the real all-null root-port shape, typed reasons, per-device isolation
    if(-not ('Bitworks.FastLlm.PciLinkNode' -as [type])){Add-Type -Path (Join-Path $repo 'src/WindowsPciLink.cs')}
    function New-FxRealPciDevice([uint32]$Width=0,[bool]$Unreadable=$true){
        $root=New-Object Bitworks.FastLlm.PciLinkNode
        $root.InstanceId='PCI\VEN_8086&DEV_A70D&SUBSYS_88821043&REV_01\3&11583659&0&08'
        foreach($name in @('CurrentLinkSpeed','CurrentLinkWidth','MaxLinkSpeed','MaxLinkWidth')){$root.$name=[Bitworks.FastLlm.PciLinkProperty]::Fail('cr-0x25-property-unavailable',37)}
        if(-not $Unreadable){$property=New-Object Bitworks.FastLlm.PciLinkProperty;$property.Raw=$Width;$root.CurrentLinkWidth=$property}
        $endpoint=New-Object Bitworks.FastLlm.PciLinkNode
        $endpoint.InstanceId=$pnpA
        $device=New-Object Bitworks.FastLlm.PciLinkDevice
        $device.Device=$endpoint;$device.RootPortInstanceId=$root.InstanceId;$device.RootPortLocationPath='PCIROOT(0)#PCI(0100)'
        $device.Ancestors=New-Object 'System.Collections.Generic.List[Bitworks.FastLlm.PciLinkNode]'
        $device.Ancestors.Add($root)
        return $device
    }
    function ConvertTo-FxPciEntry($Device){& $module {param($d) ConvertTo-FastLlmBenchmarkPciLinkEntry $d} $Device}
    function Get-FxLinkReason($Property){& $module {param($x) Get-FastLlmBenchmarkLinkPropertyReason $x} $Property}
    $realEntry=ConvertTo-FxPciEntry (New-FxRealPciDevice)
    $realLink=$realEntry.RootPortLink
    Check ($null -ne $realLink -and $null -eq $realLink.current.width -and $null -eq $realLink.current.generation -and $null -eq $realLink.current.speed -and $null -eq $realLink.max.width -and $null -eq $realLink.max.generation -and $null -eq $realLink.max.speed) 'the real all-null root-port shape (every link property error code 37) converts to a link with null values'
    Check ($realLink.current.widthReason -eq 'property-unavailable' -and $realLink.current.speedReason -eq 'property-unavailable' -and $realLink.max.widthReason -eq 'property-unavailable' -and $realLink.max.speedReason -eq 'property-unavailable') 'each null value carries the typed reason derived from error code 37'
    $realEvidence=Add-LinkEvidence $realEntry $adlxPcie
    Check ($realEvidence.status -eq 'captured' -and $null -eq $realEvidence.current.width -and $realEvidence.current.widthReason -eq 'property-unavailable' -and $realEvidence.max.speedReason -eq 'property-unavailable' -and $realEvidence.adlxComparison.status -eq 'not-compared' -and $realEvidence.adlxComparison.reason -eq 'root-port-current-link-unreadable' -and $realEvidence.adlxComparison.currentLinkReason -eq 'property-unavailable' -and $null -eq $realEvidence.linkReason) 'the all-null shape ends at not-compared with the typed unreadable reasons recorded'
    Check (($realEvidence|ConvertTo-Json -Depth 6) -notmatch 'cr-0x25|SENTINEL') 'the evidence carries only typed reasons, not the collector error strings'
    Check ((Get-FxLinkReason ([Bitworks.FastLlm.PciLinkProperty]::Fail('cr-0x1a-property-over-limit',26))) -eq 'property-over-limit' -and
           (Get-FxLinkReason ([Bitworks.FastLlm.PciLinkProperty]::Fail('unexpected-property-type-or-length',$null))) -eq 'unexpected-type-or-length' -and
           (Get-FxLinkReason ([Bitworks.FastLlm.PciLinkProperty]::Fail('cr-0x0d',13))) -eq 'property-read-failed' -and
           (Get-FxLinkReason ([Bitworks.FastLlm.PciLinkProperty]::Fail('not-read',$null))) -eq 'property-not-read' -and
           (Get-FxLinkReason ([Bitworks.FastLlm.PciLinkProperty]::Fail('not-read',$null))) -ne 'property-read-failed' -and
           (Get-FxLinkReason $null) -eq 'property-not-read' -and $null -eq (Get-FxLinkReason ([pscustomobject]@{Raw=[uint32]4}))) 'link property reasons come from the error code and are closed typed values'
    $noMatch=Add-LinkEvidence ([pscustomobject]@{RootPortLink=$null;RootPortLinkReason='root-port-node-not-found'}) $adlxPcie
    Check ($noMatch.linkReason -eq 'root-port-node-not-found' -and $null -eq $noMatch.current) 'a missing link records why it is missing'
    $overflowEntry=ConvertTo-FxPciEntry (New-FxRealPciDevice -Width 4294967295 -Unreadable $false)
    Check ($null -eq $overflowEntry.RootPortLink -and $overflowEntry.RootPortLinkReason -eq 'root-port-link-conversion-failed' -and $overflowEntry.InstanceId -eq $pnpA -and $overflowEntry.RootPortInstanceId -match 'DEV_A70D' -and $overflowEntry.RootPortLocationPath -eq 'PCIROOT(0)#PCI(0100)') 'a root-port conversion failure leaves the link null with a typed reason and keeps the root port identity'
    $overflowHardware=New-FxHardware $bound @($overflowEntry) 24576
    Check ($null -ne $overflowHardware.HardwareIdentity -and $overflowHardware.HardwareIdentity.adapters[0].attachment -eq 'cpu' -and $null -eq $overflowHardware.OmitReason) 'hardwareIdentity survives a root-port link conversion failure'
    Check ((Add-LinkEvidence $overflowEntry $adlxPcie).linkReason -eq 'root-port-link-conversion-failed') 'the failed conversion is recorded in the link evidence'
    $realHardware=New-FxHardware $bound @($realEntry) 24576
    Check ($null -ne $realHardware.HardwareIdentity) 'hardwareIdentity is emitted with the real all-null link shape'

    # 5. failure report content
    $failureError=$null
    try{& $module {param($m) throw (New-FastLlmBenchmarkFailure 'binding-changed' $m)} $sentinel}catch{$failureError=$_}
    $failurePart=Join-Path ([IO.Path]::GetTempPath()) ('fastllm-vnext-failure-'+[Guid]::NewGuid().ToString('N')+'.txt')
    try{
        [IO.File]::WriteAllText($failurePart,'partial sidecar')
        $doc=& $module {param($e,$p) New-FastLlmBenchmarkFailureReport $e 'post-timing' ('c'*64) @($p,($p+'.absent')) ([ordered]@{completedMeasuredSamples=3})} $failureError $failurePart
        $docJson=$doc|ConvertTo-Json -Depth 8
        Check ($doc.status -eq 'failed' -and $doc.reason -eq 'binding-changed' -and $doc.stage -eq 'post-timing' -and $doc.errorClass -eq 'other' -and $doc.producer.version -eq 'vnext.4' -and $doc.partial.completedMeasuredSamples -eq 3) 'a failure report carries status, typed reason, stage and partial evidence'
        Check ($docJson -notmatch 'SENTINEL' -and $doc.sidecars[0].exists -eq $true -and $doc.sidecars[0].sha256 -eq (Get-FileHash -LiteralPath $failurePart -Algorithm SHA256).Hash.ToLowerInvariant() -and $doc.sidecars[1].exists -eq $false) 'the failure report binds sidecars by SHA-256 and carries no exception text'
    } finally { Remove-Item -LiteralPath $failurePart -Force -ErrorAction SilentlyContinue }
    $plainError=$null
    try{& $module {param($m) throw (New-Object InvalidOperationException($m))} $sentinel}catch{$plainError=$_}
    $plainDoc=& $module {param($e) New-FastLlmBenchmarkFailureReport $e 'pre-timing' $null @() $null} $plainError
    Check ($plainDoc.reason -eq 'unclassified' -and $plainDoc.errorClass -eq 'other' -and ($plainDoc|ConvertTo-Json -Depth 8) -notmatch 'SENTINEL') 'an untyped failure is unclassified with its text never recorded'

    # 6. telemetry sidecar read: shared with a live writer, bounded retries
    $sharedPath=Join-Path ([IO.Path]::GetTempPath()) ('fastllm-vnext-shared-'+[Guid]::NewGuid().ToString('N')+'.jsonl')
    try{
        [IO.File]::WriteAllText($sharedPath,((New-FxTelemetryLine $t0 0 $pnpA 5)+"`n"+(New-FxTelemetryLine $t0.AddSeconds(1) 1 $pnpA 6)+"`n"))
        $writer=[IO.File]::Open($sharedPath,'Open','ReadWrite','ReadWrite')
        try{$sharedRead=& $module {param($p) Read-FastLlmBenchmarkTelemetrySidecar $p 3 10} $sharedPath}finally{$writer.Dispose()}
        Check (@($sharedRead.Rows).Count -eq 2 -and $sharedRead.LineCount -eq 2) 'the telemetry sidecar is readable while the sampler still holds it open for writing'
        $exclusive=[IO.File]::Open($sharedPath,'Open','ReadWrite','None')
        $readFailed=$false;$timer=[Diagnostics.Stopwatch]::StartNew()
        try{& $module {param($p) Read-FastLlmBenchmarkTelemetrySidecar $p 3 50} $sharedPath|Out-Null}catch{$readFailed=$true}finally{$exclusive.Dispose()}
        Check ($readFailed -and $timer.ElapsedMilliseconds -ge 90 -and $timer.ElapsedMilliseconds -lt 10000) 'a persistently locked sidecar fails after bounded retries'
    } finally { Remove-Item -LiteralPath $sharedPath -Force -ErrorAction SilentlyContinue }

    # 8. input hashes: taken at the start, verified at the end, missing input is a hard failure
    $inputRoot=Join-Path ([IO.Path]::GetTempPath()) ('fastllm-vnext-inputs-'+[Guid]::NewGuid().ToString('N'))
    try{
        $relatives=@(& $module {$script:FastLlmBenchmarkInputRelativePaths})
        Check ($relatives.Count -eq 31 -and ($relatives -contains 'tools/benchmark.ps1') -and ($relatives -contains 'src/FastLlm.psm1') -and ($relatives -contains 'src/FastLlm.Runtime.ps1') -and ($relatives -contains 'src/FastLlm.FileReplace.ps1') -and ($relatives -contains 'src/FastLlm.DeviceBinding.ps1') -and ($relatives -contains 'src/FastLlm.VulkanMemoryPolicy.ps1') -and ($relatives -contains 'src/WindowsBootTime.cs') -and ($relatives -contains 'src/WindowsGpuTelemetry.cs')) 'the required input list has 31 entries and covers the producer inputs and the files the module loads'
        Check (@($relatives|Select-Object -Unique).Count -eq $relatives.Count -and @($relatives|Where-Object {-not (Test-Path -LiteralPath (Join-Path $repo $_) -PathType Leaf)}).Count -eq 0) 'every input is unique and exists in the tree'
        $classification=& $module {Get-FastLlmBenchmarkInputClassification}
        $identityNow=@($relatives|Where-Object {$classification[$_] -eq 'identity'})
        $runtimeNow=@($relatives|Where-Object {$classification[$_] -eq 'runtime'})
        Check (@($classification.Keys).Count -eq $relatives.Count -and $identityNow.Count -eq 14 -and $runtimeNow.Count -eq 17) 'every input is classified: 14 identity, 17 runtime'
        Check (@(@('src/FastLlm.Runtime.ps1','src/FastLlm.psm1','src/FastLlm.FileReplace.ps1','src/WindowsInventory.ps1','tools/benchmark.ps1')|Where-Object {$classification[$_] -ne 'runtime'}).Count -eq 0) 'the runtime inputs named by the spec are runtime'
        Check (@(@('tools/collect-vulkan-luid-join.ps1','tools/adlx-identity-vram.ps1','src/WindowsVulkanLuidJoin.cs','src/WindowsPciLink.cs','src/WindowsCpuTopology.cs','src/ProcessHost.cs')|Where-Object {$classification[$_] -ne 'identity'}).Count -eq 0) 'the collectors and the C# sources are identity'
        Check (@($relatives|Where-Object {$_ -like '*.cs' -and $classification[$_] -ne 'identity'}).Count -eq 0 -and @($relatives|Where-Object {$_ -like 'tools/*' -and $_ -cne 'tools/benchmark.ps1' -and $classification[$_] -ne 'identity'}).Count -eq 0 -and @($relatives|Where-Object {$_ -like 'src/*.ps1' -and $classification[$_] -ne 'runtime'}).Count -eq 0 -and @($relatives|Where-Object {$_ -like 'src/*.psm1' -and $classification[$_] -ne 'runtime'}).Count -eq 0) 'the classification follows its rule: C# and the collector tools are identity, module scripts and the tools/benchmark.ps1 entry script are runtime'

        # Guard: every file the module loads at import (dot-sourced scripts, transitively, and the C# they compile) and every file the producer's child tools
        # run or compile must be listed. Path literals are recognised inside any path-building command or call (Join-Path including Join-Path (Split-Path ...),
        # [IO.Path]::Combine, Add-Type, Import-Module, Test-Path, a dot-source), resolved against the walked file's directory (or the repo root for 'src/'/'tools/'
        # literals), and in a tools/ script also anywhere in an array such as $sources = @('src/X.cs').
        function Resolve-FxRelativePath([string]$Directory,[string]$Literal){
            $stack=New-Object 'System.Collections.Generic.List[string]'
            foreach($part in (($Directory+'/'+$Literal) -split '/')){
                if($part -eq '' -or $part -eq '.'){continue}
                if($part -eq '..'){if($stack.Count -gt 0){$stack.RemoveAt($stack.Count-1)};continue}
                $stack.Add($part)
            }
            return ($stack -join '/')
        }
        function Get-FxLiteralContext($Node){
            $path=$false;$dot=$false
            $pathCommands=@('Join-Path','Add-Type','Import-Module','Test-Path','Resolve-Path','Get-Content')
            $pathMethods=@('Combine','GetFullPath','ReadAllText','ReadAllBytes','Exists')
            $ancestor=$Node.Parent
            while($null -ne $ancestor){
                if($ancestor -is [Management.Automation.Language.CommandAst]){
                    if($ancestor.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Dot){$dot=$true;$path=$true}
                    # A literal passed as the argument of a -File parameter (a child script the file runs) is a path context too.
                    $elements=@($ancestor.CommandElements)
                    for($e=1;$e -lt $elements.Count;$e++){
                        if([object]::ReferenceEquals($elements[$e],$Node) -and $elements[$e-1] -is [Management.Automation.Language.CommandParameterAst] -and $elements[$e-1].ParameterName -ieq 'File'){$path=$true}
                    }
                    if($pathCommands -contains $ancestor.GetCommandName()){$path=$true}
                }
                if($ancestor -is [Management.Automation.Language.CommandParameterAst] -and $ancestor.ParameterName -ieq 'File' -and $null -ne $ancestor.Argument -and [object]::ReferenceEquals($ancestor.Argument,$Node)){$path=$true} # -File:'x.ps1' and -File:"x.ps1"
                if($ancestor -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $ancestor.Member -is [Management.Automation.Language.StringConstantExpressionAst] -and $pathMethods -contains $ancestor.Member.Value){$path=$true}
                $ancestor=$ancestor.Parent
            }
            return [pscustomobject]@{Path=$path;Dot=$dot}
        }
        function Get-FxLoadedModuleFiles([string]$Root,[string[]]$ExtraScripts=@(),[string]$Producer='src/FastLlm.Benchmark.ps1'){
            $scripts=@();$csFiles=@();$unresolved=@();$seen=@{}
            $queue=New-Object 'System.Collections.Generic.Queue[string]'
            $queue.Enqueue('src/FastLlm.psm1')
            foreach($extra in $ExtraScripts){$queue.Enqueue($extra)}
            while($queue.Count -gt 0){
                $relative=$queue.Dequeue()
                if($seen.ContainsKey($relative)){continue}
                $seen[$relative]=$true
                $scripts+=$relative
                $directory=$relative.Substring(0,$relative.LastIndexOf('/'))
                $isTool=$relative -like 'tools/*'
                $tokens=$null;$errors=$null
                $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Root $relative),[ref]$tokens,[ref]$errors)
                foreach($node in @($ast.FindAll({param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst]},$true))){
                    $literal=[string]$node.Value
                    # A double-quoted literal is a path only when it expands nothing: no '$' and no backtick escape in its source text (an interpolated "tools/$name.ps1" is a different AST node and is never queued).
                    if($node.StringConstantType -eq [Management.Automation.Language.StringConstantType]::DoubleQuoted -and ($node.Extent.Text.Contains('$') -or $node.Extent.Text.Contains([string][char]96))){continue}
                    # Backslash separators are normalised to '/' before resolution.
                    $literal=$literal.Replace('\','/')
                    if($literal -cnotmatch '^[A-Za-z0-9_./-]+\.(cs|ps1|psm1)$'){continue}
                    $rootRelative=$literal -cmatch '^(src|tools)/'
                    $context=Get-FxLiteralContext $node
                    if(-not $context.Path -and -not ($isTool -and $rootRelative)){continue}
                    $resolved=if($rootRelative){$literal}else{Resolve-FxRelativePath $directory $literal}
                    if($resolved -like '*.cs'){$csFiles+=$resolved}
                    else{
                        # A path-context .ps1 literal that does not resolve (for example the nested Join-Path (Join-Path $projectRoot 'tools') 'x.ps1') is never silently dropped:
                        # fall back to its file name under tools/ and src/; exactly one match is queued, none or several fail the guard and name the literal and its line.
                        if(-not (Test-Path -LiteralPath (Join-Path $Root $resolved) -PathType Leaf)){
                            $leaf=$literal.Substring($literal.LastIndexOf('/')+1)
                            $matches2=@(@('tools','src')|ForEach-Object {$_+'/'+$leaf}|Where-Object {Test-Path -LiteralPath (Join-Path $Root $_) -PathType Leaf})
                            if($matches2.Count -eq 1){$resolved=$matches2[0]}
                            elseif($matches2.Count -eq 0){$unresolved+=('UNRESOLVED: '+$literal+' ('+$relative+':'+$node.Extent.StartLineNumber+')');continue}
                            else{$unresolved+=('AMBIGUOUS: '+$literal+' ('+$relative+':'+$node.Extent.StartLineNumber+') matches '+($matches2 -join ' and '));continue}
                        }
                        elseif(-not $rootRelative){
                            # The literal resolved against this file's own directory to a file that exists. If a file with the same name also exists under tools/ or src/ at a different path,
                            # taking the nearest one could silently pick the wrong file: fail as ambiguous.
                            $leafName=$literal.Substring($literal.LastIndexOf('/')+1)
                            $shadows=@(@('tools','src')|ForEach-Object {$_+'/'+$leafName}|Where-Object {$_ -cne $resolved -and (Test-Path -LiteralPath (Join-Path $Root $_) -PathType Leaf)})
                            if($shadows.Count -gt 0){$unresolved+=('AMBIGUOUS: '+$literal+' ('+$relative+':'+$node.Extent.StartLineNumber+') matches '+((@($resolved)+$shadows) -join ' and '));continue}
                        }
                        $queue.Enqueue($resolved)
                    }
                }
            }
            return [pscustomobject]@{Scripts=@($scripts);Cs=@($csFiles|Select-Object -Unique);Unresolved=@($unresolved|Select-Object -Unique)}
        }
        function Get-FxMissingInputs([string]$Root,[string[]]$List,[string[]]$Exempt){
            $extra=@($List|Where-Object {($_ -like 'src/*.ps1' -or $_ -like 'tools/*.ps1') -and (Test-Path -LiteralPath (Join-Path $Root $_))})
            $loaded=Get-FxLoadedModuleFiles $Root $extra
            return @(@(@($loaded.Scripts)+@($loaded.Cs)|Where-Object {$_ -notin $Exempt -and $_ -notin $List}|Select-Object -Unique)+@($loaded.Unresolved))
        }
        # Exemption table (exactly one entry). The producer's input list is frozen; this worker is reached from a module-loaded file but never run by the producer.
        # Each entry drives its own tripwire: Gate is the (case-insensitive) token that may appear only at its definition and export entry, and the entry path
        # (or its basename) may appear in exactly one walked location, inside the Gate function in DefinedIn. A second exemption must be a deliberate edit here.
        $fxExemptions=[ordered]@{
            'tools/collect-prerequisite-inventory.ps1'=[pscustomobject]@{Reason='doctor-only worker, reached only through Get-FastLlmPrerequisiteInventory';Gate='Get-FastLlmPrerequisiteInventory';DefinedIn='src/FastLlm.PrerequisiteDiagnostics.ps1'}
        }
        Check (@($fxExemptions.Keys).Count -eq 1) 'the exemption table has exactly one entry (a second exemption is a deliberate edit with its own tripwire)'
        $fxExemptPaths=@('src/FastLlm.Benchmark.ps1')+@($fxExemptions.Keys)
        function Get-FxGateTokenHits([string]$Relative,[string]$Text,[string]$Gate,[string]$DefinedIn){
            $hits=@();$lineNo=0
            foreach($line in ($Text -split "`n")){
                $lineNo++
                if($line -inotmatch [regex]::Escape($Gate)){continue}
                $isDefinition=$Relative -ceq $DefinedIn -and $line -imatch ('^\s*function\s+'+[regex]::Escape($Gate)+'\s*\{?\s*$')
                $isExport=$Relative -ceq 'src/FastLlm.psm1' -and $line -imatch ('^\s*''' +[regex]::Escape($Gate)+ '''\s*,?\s*$')
                if(-not ($isDefinition -or $isExport)){$hits+=($Relative+':'+$lineNo)}
            }
            return @($hits)
        }
        # Direct path reach: the worker path (or its basename, case-insensitive) may appear only inside the Gate function in DefinedIn.
        function Get-FxPathReach([string]$Relative,[string]$Text,[string]$WorkerPath,[string]$Gate,[string]$DefinedIn){
            $baseName=$WorkerPath.Substring($WorkerPath.LastIndexOf('/')+1)
            $first=0;$last=0
            if($Relative -ceq $DefinedIn){
                $tk=$null;$er=$null
                $tree=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tk,[ref]$er)
                $fn=@($tree.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ieq $Gate},$true))
                if($fn.Count -eq 1){$first=$fn[0].Extent.StartLineNumber;$last=$fn[0].Extent.EndLineNumber}
            }
            $hits=@();$allowed=0;$lineNo=0
            foreach($line in ($Text -split "`n")){
                $lineNo++
                if($line -inotmatch [regex]::Escape($baseName)){continue}
                if($first -gt 0 -and $lineNo -ge $first -and $lineNo -le $last){$allowed++}else{$hits+=($Relative+':'+$lineNo)}
            }
            return [pscustomobject]@{Hits=@($hits);Allowed=$allowed}
        }
        $walkedForGate=Get-FxLoadedModuleFiles $repo @($relatives|Where-Object {$_ -like 'src/*.ps1' -or $_ -like 'tools/*.ps1'})
        $walkedText=@{};foreach($walked in @($walkedForGate.Scripts)){$walkedText[$walked]=[IO.File]::ReadAllText((Join-Path $repo $walked))}
        $producerText=$walkedText['src/FastLlm.Benchmark.ps1']
        $runtimeText=$walkedText['src/FastLlm.Runtime.ps1']
        foreach($exemptPath in @($fxExemptions.Keys)){
            $entry=$fxExemptions[$exemptPath];$gate=$entry.Gate;$definedIn=$entry.DefinedIn
            $gateHits=@(foreach($walked in @($walkedForGate.Scripts)){Get-FxGateTokenHits $walked $walkedText[$walked] $gate $definedIn})
            Check ($gateHits.Count -eq 0) ('the exempted worker '+$exemptPath+' is gated by '+$gate+', which appears only in its definition and the export entry (other occurrences: '+($gateHits -join ', ')+')')
            $injected=@(Get-FxGateTokenHits 'src/FastLlm.Benchmark.ps1' ($producerText+"`n"+'$inventory = '+$gate+"`n") $gate $definedIn)
            Check ($injected.Count -eq 1 -and $injected[0] -ceq ('src/FastLlm.Benchmark.ps1:'+(($producerText -split "`n").Count+1))) 'tripwire self-test: an injected call in a copy of the producer text fires and names the file and line'
            $injectedCase=@(Get-FxGateTokenHits 'src/FastLlm.Benchmark.ps1' ($producerText+"`n"+'$inventory = '+$gate.ToLowerInvariant()+"`n") $gate $definedIn)
            Check ($injectedCase.Count -eq 1) 'tripwire self-test: a different-case injected call fires (command names are case-insensitive)'
            $injectedHelper=@(Get-FxGateTokenHits 'src/FastLlm.Runtime.ps1' ($runtimeText+"`n"+'  $x = '+$gate+"`n") $gate $definedIn)
            Check ($injectedHelper.Count -eq 1) 'tripwire self-test: an injected call in a walked helper fires'
            $reachHits=@();$reachAllowed=0
            foreach($walked in @($walkedForGate.Scripts)){$r=Get-FxPathReach $walked $walkedText[$walked] $exemptPath $gate $definedIn;$reachHits+=@($r.Hits);$reachAllowed+=$r.Allowed}
            Check ($reachHits.Count -eq 0 -and $reachAllowed -eq 1) ('the exempted worker path '+$exemptPath+' appears in exactly one walked location, inside '+$gate+' in '+$definedIn+' (other occurrences: '+($reachHits -join ', ')+'; allowed seen: '+$reachAllowed+')')
            $reachInjected=@((Get-FxPathReach 'src/FastLlm.Benchmark.ps1' ($producerText+"`n"+'$tool = Join-Path (Split-Path $PSScriptRoot -Parent) '''+$exemptPath+''''+"`n") $exemptPath $gate $definedIn).Hits)
            Check ($reachInjected.Count -eq 1 -and $reachInjected[0] -ceq ('src/FastLlm.Benchmark.ps1:'+(($producerText -split "`n").Count+1))) 'tripwire self-test: an injected path reach to the worker in a copy of the producer text fires and names the file and line'
            $reachBase=@((Get-FxPathReach 'src/FastLlm.Runtime.ps1' ($runtimeText+"`n"+'$t = Join-Path $PSScriptRoot ''COLLECT-Prerequisite-Inventory.PS1'''+"`n") $exemptPath $gate $definedIn).Hits)
            Check ($reachBase.Count -eq 1) 'tripwire self-test: a basename-only, different-case path reach in a walked helper fires'
            # The allowed window is the Gate function's own extent: the unmodified definition file passes, and the worker path added OUTSIDE that function (a new top-level line) fires and names the file and line.
            $definedText=$walkedText[$definedIn]
            $definedClean=Get-FxPathReach $definedIn $definedText $exemptPath $gate $definedIn
            Check ($definedClean.Hits.Count -eq 0 -and $definedClean.Allowed -eq 1) ('tripwire self-test: the unmodified '+$definedIn+' has no reach to the worker outside '+$gate+' (one allowed occurrence inside it)')
            $windowInjected=Get-FxPathReach $definedIn ($definedText+"`n"+'$worker = '''+$exemptPath+''''+"`n") $exemptPath $gate $definedIn
            Check (@($windowInjected.Hits).Count -eq 1 -and $windowInjected.Hits[0] -ceq ($definedIn+':'+(($definedText -split "`n").Count+1)) -and $windowInjected.Allowed -eq 1) ('tripwire self-test: the worker path added as a new top-level line in a copy of '+$definedIn+' (outside '+$gate+') fires and names that file and line')
            Check ((Test-Path -LiteralPath (Join-Path $repo $exemptPath) -PathType Leaf) -and $walkedForGate.Scripts -contains $exemptPath) ('stale-exemption check: '+$exemptPath+' still exists and is still found by the walk')
        }
        $loadedReal=Get-FxLoadedModuleFiles $repo @($relatives|Where-Object {$_ -like 'src/*.ps1' -or $_ -like 'tools/*.ps1'})
        Check (@($loadedReal.Scripts).Count -ge 13 -and $loadedReal.Scripts -contains 'src/FastLlm.FileReplace.ps1' -and $loadedReal.Scripts -contains 'src/FastLlm.Benchmark.ps1' -and $loadedReal.Cs -contains 'src/WindowsBootTime.cs' -and $loadedReal.Cs -contains 'src/WindowsGpuTelemetry.cs' -and $loadedReal.Cs -contains 'src/ProcessHost.cs' -and $loadedReal.Cs -contains 'src/WindowsInventory.cs') 'the guard parser finds the transitive dot-sources and the C# sources, including the Add-Type -Path @($sources) form'
        $loadedFromModule=Get-FxLoadedModuleFiles $repo @()
        Check ($loadedFromModule.Scripts -contains 'tools/collect-vulkan-luid-join.ps1' -and $loadedFromModule.Scripts -contains 'tools/adlx-identity-vram.ps1' -and $loadedFromModule.Cs -contains 'src/WindowsVulkanLuidJoin.cs' -and $loadedFromModule.Cs -contains 'src/WindowsPciAddress.cs' -and $loadedFromModule.Cs -contains 'src/ProcessHost.cs') 'the guard walks the tools/*.ps1 children the producer runs (found from the producer alone) and the C# files those children compile'
        $missingReal=@(Get-FxMissingInputs $repo $relatives $fxExemptPaths)
        # N-b negative self-test on the real tree: the src .ps1 child WindowsInventory.ps1 (reached from Runtime through a Join-Path inside a -File argument list)
        # and the C# it compiles must be found by the walk and named, even when the list is the only thing that stopped listing them.
        $withoutInventory=@($relatives|Where-Object {$_ -notin @('src/WindowsInventory.ps1','src/WindowsInventory.cs','src/WindowsHostInventory.cs')})
        $missingInventory=@(Get-FxMissingInputs $repo $withoutInventory $fxExemptPaths|Sort-Object)
        $newlyNamed=@($missingInventory|Where-Object {$_ -notin $missingReal}|Sort-Object)
        Check (($newlyNamed -join ',') -ceq 'src/WindowsHostInventory.cs,src/WindowsInventory.cs,src/WindowsInventory.ps1') ('guard self-test: removing WindowsInventory.ps1, WindowsInventory.cs and WindowsHostInventory.cs from a copy of the list fails the guard and names exactly them (newly named: '+($newlyNamed -join ', ')+')')
        $walkedReal=Get-FxLoadedModuleFiles $repo @($withoutInventory|Where-Object {$_ -like 'src/*.ps1' -or $_ -like 'tools/*.ps1'})
        Check ($walkedReal.Scripts -contains 'src/WindowsInventory.ps1' -and $walkedReal.Cs -contains 'src/WindowsInventory.cs' -and $walkedReal.Cs -contains 'src/WindowsHostInventory.cs') 'the guard walk reaches the src .ps1 child WindowsInventory.ps1 and its C# without them being listed'
        Check ($missingReal.Count -eq 0) ('every file the module loads at import and every child tool run by the producer (with the C# they compile) is in the input list (missing: '+($missingReal -join ', ')+')')
        $guardRoot=Join-Path ([IO.Path]::GetTempPath()) ('fastllm-vnext2-guard-'+[Guid]::NewGuid().ToString('N'))
        try{
            New-Item -ItemType Directory -Path (Join-Path $guardRoot 'src') -Force|Out-Null
            New-Item -ItemType Directory -Path (Join-Path $guardRoot 'tools') -Force|Out-Null
            [IO.File]::WriteAllText((Join-Path $guardRoot 'src/FastLlm.psm1'),('. (Join-Path $PSScriptRoot ''A.ps1'')'+"`n"+'. (Join-Path $PSScriptRoot ''FastLlm.Benchmark.ps1'')'))
            [IO.File]::WriteAllText((Join-Path $guardRoot 'src/A.ps1'),('Add-Type -Path (Join-Path $PSScriptRoot ''B.cs'')'+"`n"+'$sources = @(); $sources += (Join-Path $PSScriptRoot ''C.cs'')'+"`n"+'. (Join-Path $PSScriptRoot ''D.ps1'')'+"`n"+'Add-Type -Path ([IO.Path]::Combine($PSScriptRoot, ''E.cs''))'+"`n"+'Add-Type -Path (Join-Path (Split-Path $PSScriptRoot -Parent) ''src/F.cs'')'+"`n"+'$notAPath = ''Z.cs'''))
            [IO.File]::WriteAllText((Join-Path $guardRoot 'src/D.ps1'),'Write-Output 1')
            [IO.File]::WriteAllText((Join-Path $guardRoot 'src/FastLlm.Benchmark.ps1'),'$tool = Join-Path (Split-Path $PSScriptRoot -Parent) ''tools/t.ps1''')
            [IO.File]::WriteAllText((Join-Path $guardRoot 'tools/t.ps1'),('$repo = Split-Path $PSScriptRoot -Parent'+"`n"+'$sources = @(''src/G.cs'')'+"`n"+'Add-Type -Path (Join-Path $repo $sources[0])'+"`n"+'Add-Type -Path (Join-Path $RepoDirectory ''src/H.cs'')'+"`n"+'Add-Type -Path (Join-Path $PSScriptRoot ''../src/I.cs'')'))
            $allFixture=@('src/FastLlm.psm1','src/A.ps1','src/B.cs','src/C.cs','src/D.ps1','src/E.cs','src/F.cs','src/FastLlm.Benchmark.ps1','tools/t.ps1','src/G.cs','src/H.cs','src/I.cs')
            $negative=@(Get-FxMissingInputs $guardRoot @('src/FastLlm.psm1') @())
            Check ((($negative|Sort-Object) -join ',') -eq 'src/A.ps1,src/B.cs,src/C.cs,src/D.ps1,src/E.cs,src/F.cs,src/FastLlm.Benchmark.ps1,src/G.cs,src/H.cs,src/I.cs,tools/t.ps1') 'guard self-test: unlisted dot-sourced and compiled files, [IO.Path]::Combine and Join-Path (Split-Path ...) forms, the child tools/*.ps1 and the C# the child compiles are all reported (a plain string literal is not)'
            Check (@(Get-FxMissingInputs $guardRoot $allFixture @()).Count -eq 0) 'guard self-test: a complete list passes'
            Check ((@(Get-FxMissingInputs $guardRoot @($allFixture|Where-Object {$_ -ne 'src/D.ps1'}) @('src/D.ps1')) -join ',') -eq '' -and ((@(Get-FxMissingInputs $guardRoot @($allFixture|Where-Object {$_ -notin @('src/C.cs','src/D.ps1')}) @())|Sort-Object) -join ',') -eq 'src/C.cs,src/D.ps1') 'guard self-test: only an explicit exemption is skipped and each omission is named'
            Check (((@(Get-FxMissingInputs $guardRoot @($allFixture|Where-Object {$_ -notin @('tools/t.ps1','src/G.cs','src/H.cs','src/I.cs')}) @())|Sort-Object) -join ',') -eq 'src/G.cs,src/H.cs,src/I.cs,tools/t.ps1') 'guard self-test: omitting the child tool and the C# it compiles is reported'
            # Resolution fallback: a literal that resolves nowhere is never dropped silently.
            New-Item -ItemType Directory -Path (Join-Path $guardRoot 'r/src') -Force|Out-Null
            New-Item -ItemType Directory -Path (Join-Path $guardRoot 'r/tools') -Force|Out-Null
            [IO.File]::WriteAllText((Join-Path $guardRoot 'r/src/FastLlm.psm1'),('. (Join-Path $PSScriptRoot ''Chain.ps1'')'))
            [IO.File]::WriteAllText((Join-Path $guardRoot 'r/src/Chain.ps1'),('$a = Join-Path (Join-Path $root ''tools'') ''Moved.ps1'''+"`n"+'$b = Join-Path $PSScriptRoot ''Ghost.ps1'''+"`n"+'$c = Join-Path $PSScriptRoot ''sub/Twin.ps1'''))
            [IO.File]::WriteAllText((Join-Path $guardRoot 'r/tools/Moved.ps1'),'Write-Output 1')
            [IO.File]::WriteAllText((Join-Path $guardRoot 'r/tools/Twin.ps1'),'Write-Output 1')
            [IO.File]::WriteAllText((Join-Path $guardRoot 'r/src/Twin.ps1'),'Write-Output 1')
            $resolvedFx=@(Get-FxMissingInputs (Join-Path $guardRoot 'r') @('src/FastLlm.psm1') @())
            Check ($resolvedFx -contains 'tools/Moved.ps1' -and $resolvedFx -contains 'UNRESOLVED: Ghost.ps1 (src/Chain.ps1:2)' -and @($resolvedFx|Where-Object {$_ -like 'AMBIGUOUS: sub/Twin.ps1 (src/Chain.ps1:3)*'}).Count -eq 1) 'guard self-test: a nested-join literal that exists once under tools/ is queued, a synthetic literal with no match fails naming the literal and line, and several matches fail as ambiguous'
            # -File detection: the separate-argument form and the colon forms (single and double quoted) are path contexts.
            New-Item -ItemType Directory -Path (Join-Path $guardRoot 'f/src') -Force|Out-Null
            [IO.File]::WriteAllText((Join-Path $guardRoot 'f/src/FastLlm.psm1'),('Start-Process pwsh -ArgumentList x; & pwsh -File ''X.ps1'''+"`n"+'& pwsh -File:''Y.ps1'''+"`n"+'& pwsh -File:"Z.ps1"'+"`n"+'$notAPath = ''W.ps1'''))
            foreach($fileName in @('X.ps1','Y.ps1','Z.ps1','W.ps1')){[IO.File]::WriteAllText((Join-Path $guardRoot ('f/src/'+$fileName)),'Write-Output 1')}
            $fileForms=@(Get-FxMissingInputs (Join-Path $guardRoot 'f') @('src/FastLlm.psm1') @()|Sort-Object)
            Check (($fileForms -join ',') -ceq 'src/X.ps1,src/Y.ps1,src/Z.ps1') 'guard self-test: -File ''x.ps1'', -File:''x.ps1'' and -File:"x.ps1" are all walked (a plain literal is not)'
            # Item 3: double-quoted (no expansion) and backslash path literals are queued, normalised to '/'; an interpolated literal is not.
            New-Item -ItemType Directory -Path (Join-Path $guardRoot 'q/src') -Force|Out-Null
            New-Item -ItemType Directory -Path (Join-Path $guardRoot 'q/tools') -Force|Out-Null
            [IO.File]::WriteAllText((Join-Path $guardRoot 'q/src/FastLlm.psm1'),(('$a = Join-Path $root "tools\X.ps1"'),('$b = Join-Path $root ''tools\Y.ps1'''),('$c = Join-Path $root "tools/Z.ps1"'),('$d = Join-Path $root "tools/$name.ps1"') -join "`n"))
            foreach($fileName in @('X.ps1','Y.ps1','Z.ps1','W.ps1')){[IO.File]::WriteAllText((Join-Path $guardRoot ('q/tools/'+$fileName)),'Write-Output 1')}
            $quoteForms=@(Get-FxMissingInputs (Join-Path $guardRoot 'q') @('src/FastLlm.psm1') @()|Sort-Object)
            Check (($quoteForms -join ',') -ceq 'tools/X.ps1,tools/Y.ps1,tools/Z.ps1') 'guard self-test: "tools\X.ps1", ''tools\Y.ps1'' and "tools/Z.ps1" are all queued; the interpolated "tools/$name.ps1" is not'
            # Item 4: a nested join that resolves against the file's own directory to an existing file, while the same file name also exists under the other of src/ and tools/, fails as ambiguous.
            New-Item -ItemType Directory -Path (Join-Path $guardRoot 's/src') -Force|Out-Null
            New-Item -ItemType Directory -Path (Join-Path $guardRoot 's/tools') -Force|Out-Null
            [IO.File]::WriteAllText((Join-Path $guardRoot 's/src/FastLlm.psm1'),('. (Join-Path $PSScriptRoot ''X.ps1'')'))
            [IO.File]::WriteAllText((Join-Path $guardRoot 's/src/X.ps1'),'Write-Output 1')
            [IO.File]::WriteAllText((Join-Path $guardRoot 's/tools/X.ps1'),'Write-Output 1')
            $shadowed=@(Get-FxMissingInputs (Join-Path $guardRoot 's') @('src/FastLlm.psm1','src/X.ps1') @())
            Check (@($shadowed|Where-Object {$_ -like 'AMBIGUOUS: X.ps1 (src/FastLlm.psm1:1)*'}).Count -eq 1) 'guard self-test: src/X.ps1 and tools/X.ps1 both exist and a src file joins ''X.ps1'' against its own directory: the guard fails as AMBIGUOUS naming the literal, file and line'
            Remove-Item -LiteralPath (Join-Path $guardRoot 's/tools/X.ps1') -Force
            Check (@(Get-FxMissingInputs (Join-Path $guardRoot 's') @('src/FastLlm.psm1','src/X.ps1') @()).Count -eq 0) 'guard self-test: without the shadowing file the same join resolves normally'
        } finally { Remove-Item -LiteralPath $guardRoot -Recurse -Force -ErrorAction SilentlyContinue }
        foreach($relative in $relatives){$full=Join-Path $inputRoot $relative;New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force|Out-Null;[IO.File]::WriteAllText($full,"content of $relative")}
        $startInputs=& $module {param($r) Get-FastLlmBenchmarkInputHashes $r} $inputRoot
        Check (@($startInputs.Missing).Count -eq 0 -and @($startInputs.Hashes.Keys).Count -eq $relatives.Count -and $startInputs.Hashes['src/FastLlm.psm1'] -match '^[0-9a-f]{64}$') 'input hashes are computed for every required file'
        & $module {param($a) Assert-FastLlmBenchmarkInputsPresent $a} $startInputs
        $sameInputs=& $module {param($r) Get-FastLlmBenchmarkInputHashes $r} $inputRoot
        & $module {param($a,$b) Assert-FastLlmBenchmarkInputsUnchanged $a $b} $startInputs $sameInputs
        Check $true 'unchanged inputs verify at the end'
        [IO.File]::WriteAllText((Join-Path $inputRoot 'tools/adlx-identity-vram.ps1'),'changed')
        $changedInputs=& $module {param($r) Get-FastLlmBenchmarkInputHashes $r} $inputRoot
        Reject {& $module {param($a,$b) Assert-FastLlmBenchmarkInputsUnchanged $a $b} $startInputs $changedInputs} 'changed during the run' 'an input that changes during the run is a hard failure'
        Check ((Get-FxFailureReason {& $module {param($a,$b) Assert-FastLlmBenchmarkInputsUnchanged $a $b} $startInputs $changedInputs}) -eq 'input-changed') 'the changed-input failure has the typed reason input-changed'
        $changedPathError=$null;try{& $module {param($a,$b) Assert-FastLlmBenchmarkInputsUnchanged $a $b} $startInputs $changedInputs}catch{$changedPathError=$_}
        Check ((@(& $module {param($e) Get-FastLlmBenchmarkFailurePaths $e} $changedPathError) -join ',') -eq 'tools/adlx-identity-vram.ps1') 'the input-changed failure names the changed relative path'
        Remove-Item -LiteralPath (Join-Path $inputRoot 'src/WindowsPciLink.cs') -Force
        $missingInputs=& $module {param($r) Get-FastLlmBenchmarkInputHashes $r} $inputRoot
        Check (@($missingInputs.Missing) -contains 'src/WindowsPciLink.cs' -and $null -eq $missingInputs.Hashes['src/WindowsPciLink.cs']) 'a missing input is listed and its hash is null'
        Reject {& $module {param($a) Assert-FastLlmBenchmarkInputsPresent $a} $missingInputs} 'input file is missing' 'a missing required input is a hard failure'
        Check ((Get-FxFailureReason {& $module {param($a) Assert-FastLlmBenchmarkInputsPresent $a} $missingInputs}) -eq 'input-missing') 'the missing-input failure has the typed reason input-missing'
        $missingPathError=$null;try{& $module {param($a) Assert-FastLlmBenchmarkInputsPresent $a} $missingInputs}catch{$missingPathError=$_}
        Check ((@(& $module {param($e) Get-FastLlmBenchmarkFailurePaths $e} $missingPathError) -join ',') -eq 'src/WindowsPciLink.cs') 'the input-missing failure names the missing relative path'
        Reject {& $module {param($a,$b) Assert-FastLlmBenchmarkInputsUnchanged $a $b} $startInputs $missingInputs} 'missing' 'an input that vanishes during the run is a hard failure'
    } finally { Remove-Item -LiteralPath $inputRoot -Recurse -Force -ErrorAction SilentlyContinue }

    # 9. overlapMs keeps its fractional milliseconds
    $fractional=Get-FxAccounting @($t0.AddTicks(5000),$t0.AddMilliseconds(1000)) $t0 $t0.AddMilliseconds(1500)
    Check ($fractional.overlapWithTimedWindow.overlapMs -eq 999.5 -and [Math]::Abs($fractional.overlapWithTimedWindow.coverageFraction-999.5/1500) -lt 1e-9) 'overlapMs and the coverage fraction are not rounded to whole milliseconds'

    # ============================================================ v-next.2 additions (pure)
    # S2: the result is written from pre-serialized bytes; a failed write deletes only the file this call created
    $outDir=Join-Path ([IO.Path]::GetTempPath()) ('fastllm-vnext2-out-'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $outDir -Force|Out-Null
    try{
        $payload=[Text.Encoding]::UTF8.GetBytes('{"ok":true}')
        $okPath=Join-Path $outDir 'ok.json'
        & $module {param($p,$b) Write-FastLlmBenchmarkOutputFile $p $b} $okPath $payload
        Check ([IO.File]::ReadAllText($okPath) -ceq '{"ok":true}') 'the result file is written from pre-serialized bytes'
        $faultPath=Join-Path $outDir 'fault.json'
        Set-Seam 'OutputWriteFault' {throw (New-Object IO.IOException('fixture write fault'))}
        Reject {& $module {param($p,$b) Write-FastLlmBenchmarkOutputFile $p $b} $faultPath $payload} 'fixture write fault' 'a write that fails after the file was created propagates the failure'
        Check (-not (Test-Path -LiteralPath $faultPath)) 'no partial output file is left behind after a failed write'
        $existingPath=Join-Path $outDir 'existing.json'
        [IO.File]::WriteAllText($existingPath,'keep')
        Reject {& $module {param($p,$b) Write-FastLlmBenchmarkOutputFile $p $b} $existingPath $payload} 'already exists' 'an existing output is refused (CreateNew)'
        Check ([IO.File]::ReadAllText($existingPath) -ceq 'keep') 'a file this call did not create is never deleted or modified'
        Clear-Seams
    } finally { Clear-Seams;Remove-Item -LiteralPath $outDir -Recurse -Force -ErrorAction SilentlyContinue }

    # S6, the ADLX child environment, and the dead-code nits, from the producer and runtime sources
    $producerSource=[IO.File]::ReadAllText((Join-Path $repo 'src/FastLlm.Benchmark.ps1'))
    $runtimeSource=[IO.File]::ReadAllText((Join-Path $repo 'src/FastLlm.Runtime.ps1'))
    $inventoryLine=@($runtimeSource -split "`n"|Where-Object {$_ -match "WindowsInventory\.ps1"})
    Check ($inventoryLine.Count -eq 1 -and $inventoryLine[0] -notmatch 'ExecutionPolicy' -and $inventoryLine[0] -notmatch 'Bypass') 'the inventory child (both captures call it) sets no -ExecutionPolicy and inherits the entry policy'
    $parseTokens=$null;$parseErrors=$null
    $producerAst=[Management.Automation.Language.Parser]::ParseInput($producerSource,[ref]$parseTokens,[ref]$parseErrors)
    $childCalls=@($producerAst.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'New-FastLlmBenchmarkChildStartInfo'},$true))
    $clearing=@($childCalls|Where-Object {@($_.CommandElements|Where-Object {$_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'ClearEngineEnvironment'}).Count -eq 1})
    Check ($childCalls.Count -eq 3 -and $clearing.Count -eq 3) 'every child PowerShell start (join, ADLX identity, ADLX sampler) clears the engine and token environment'
    Check ($producerSource -match 'catch \{ \$child\.Dispose\(\); Wait-FastLlmBenchmarkSidecarRelease' -and $producerSource -notmatch '\$completed' -and @([regex]::Matches($producerSource,'\$preFingerprint=')).Count -eq 1) 'the telemetry start-failure path waits for the sampler, and the dead assignments are gone'

    # nits: sidecar release wait and the hashed sidecar on a read failure
    $waitFile=Join-Path ([IO.Path]::GetTempPath()) ('fastllm-vnext2-wait-'+[Guid]::NewGuid().ToString('N')+'.jsonl')
    try{
        [IO.File]::WriteAllText($waitFile,'sidecar bytes')
        $watch=[Diagnostics.Stopwatch]::StartNew()
        Check ((& $module {param($p) Wait-FastLlmBenchmarkSidecarRelease $p 2000} $waitFile) -eq $true -and $watch.ElapsedMilliseconds -lt 1500) 'a released sidecar is reported free at once'
        Check ((& $module {param($p) Wait-FastLlmBenchmarkSidecarRelease $p 2000} ($waitFile+'.absent')) -eq $true) 'an absent sidecar needs no wait'
        $holder=[IO.File]::Open($waitFile,'Open','ReadWrite','None')
        try{$watch.Restart();$held=& $module {param($p) Wait-FastLlmBenchmarkSidecarRelease $p 300} $waitFile}finally{$holder.Dispose()}
        Check ($held -eq $false -and $watch.ElapsedMilliseconds -ge 250 -and $watch.ElapsedMilliseconds -lt 5000) 'a sidecar the killed sampler still holds is waited for, within the bound'
        $readError=$null;try{throw (New-Object UnauthorizedAccessException($sentinel))}catch{$readError=$_}
        $unreadable=& $module {param($e,$p) New-FastLlmBenchmarkTelemetryReadFailure $e $p $true $null} $readError $waitFile
        $waitSha=(Get-FileHash -LiteralPath $waitFile -Algorithm SHA256).Hash.ToLowerInvariant()
        Check ($unreadable.status -eq 'unknown' -and $unreadable.reason -eq 'sidecar-read-failed' -and $unreadable.readFailureReason -eq 'access-denied' -and $unreadable.terminatedByProducer -eq $true -and $unreadable.sidecar.sha256 -eq $waitSha -and $unreadable.sidecar.bytes -eq 13 -and $unreadable.sidecar.fileName -eq ([IO.Path]::GetFileName($waitFile))) 'a telemetry sidecar whose read failed is still bound by SHA-256'
        Check (($unreadable|ConvertTo-Json -Depth 6) -notmatch 'SENTINEL') 'the read failure block carries no exception text'
        $lockHold=[IO.File]::Open($waitFile,'Open','ReadWrite','None')
        try{$lockedFailure=& $module {param($e,$p) New-FastLlmBenchmarkTelemetryReadFailure $e $p $false $null} $readError $waitFile}finally{$lockHold.Dispose()}
        Check ($null -eq $lockedFailure.sidecar.sha256 -and $lockedFailure.sidecar.hashFailureReason -eq 'other' -and $lockedFailure.sidecar.fileName -eq ([IO.Path]::GetFileName($waitFile))) 'a sidecar that cannot even be hashed is listed with a typed hash failure reason'
    } finally { Remove-Item -LiteralPath $waitFile -Force -ErrorAction SilentlyContinue }

    # S4: failures record fixed relative input paths only
    $pathError=$null;try{& $module {throw (New-FastLlmBenchmarkFailure 'input-changed' 'm' @('src/FastLlm.psm1','C:\secret\x.txt','src/WindowsPciLink.cs'))}}catch{$pathError=$_}
    Check ((@(& $module {param($e) Get-FastLlmBenchmarkFailurePaths $e} $pathError) -join ',') -eq 'src/FastLlm.psm1,src/WindowsPciLink.cs') 'only entries of the fixed input list can be recorded as failure paths'
    Check (@(& $module {param($e) Get-FastLlmBenchmarkFailurePaths $e} $null).Count -eq 0) 'a failure without paths records none'

    # binding collection error flags are recorded and never part of the pre/post fingerprint
    Check ($unique.Binding.collectionErrors.vulkan -eq $false -and $unique.Binding.collectionErrors.dxgi -eq $false -and $unique.Binding.collectionErrors.setupApi -eq $false) 'the binding records the Vulkan, DXGI and SetupAPI collection error flags'
    $flaggedSnapshot=New-FxUniqueSnapshot;$flaggedSnapshot.dxgiError=$true;$flaggedSnapshot.setupApiError=$true
    $flagged=Resolve-Fx $flaggedSnapshot
    Check ($flagged.Binding.collectionErrors.dxgi -eq $true -and $flagged.Binding.collectionErrors.setupApi -eq $true -and $flagged.Binding.collectionErrors.vulkan -eq $false) 'DXGI and SetupAPI error flags are recorded'
    Check ((Get-Agreement $unique.Binding $flagged.Binding) -match '^[0-9a-f]{64}$') 'the collection error flags do not change the pre/post agreement fingerprint'
    Check ($null -eq (Resolve-Fx $null $null 'other').Binding.collectionErrors) 'a failed probe has no collection error flags'

  }
    # ============================================================ native Windows end-to-end mock run
    if($env:OS -ne 'Windows_NT'){
        Write-Host 'SKIP: native-Windows-only v-next producer mock-server run; no physical benchmark executed.'
        Write-Host "$script:count v-next producer checks passed (pure tests only)."
        exit 0
    }
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
        Write-Host 'SKIP: the v-next producer mock-server run needs a standard Windows user because the production guard stays enabled.'
        Write-Host "$script:count v-next producer checks passed (pure tests only)."
        exit 0
    }
    if(-not ('Bitworks.FastLlm.ProcessHost' -as [type])){Add-Type -Path (Join-Path $repo 'src/ProcessHost.cs')}
    $root=Join-Path ([IO.Path]::GetTempPath()) ('fastllm-vnext-'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force|Out-Null
    try{
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=(Get-Process -Id $PID).Path
        $source="& '$($PSCommandPath.Replace("'","''"))' -Worker -FixtureRoot '$($root.Replace("'","''"))'"
        if($SeamFree){
            $source+=" -SeamFree -AdlxExecutablePath '$($AdlxExecutablePath.Replace("'","''"))' -AdlxExecutableSha256 '$AdlxExecutableSha256' -RecipeVramMiB $RecipeVramMiB"
            if($RecipeAdapterName){$source+=" -RecipeAdapterName '$($RecipeAdapterName.Replace("'","''"))'"}
            if($KeepPath){$source+=" -KeepPath '$($KeepPath.Replace("'","''"))'"}
        }
        $info.Arguments='-NoLogo -NoProfile -NonInteractive -OutputFormat Text -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($source))
        $info.UseShellExecute=$false
        $child=New-Object Bitworks.FastLlm.ProcessHost
        $child.Start($info)
        try{
            if(-not $child.Process.WaitForExit(300000)){throw 'FAIL: v-next producer worker exceeded 300 seconds.'}
            $drain=[Diagnostics.Stopwatch]::StartNew();while(-not $child.OutputCompleted -and $drain.ElapsedMilliseconds -lt 5000){Start-Sleep -Milliseconds 50}
            Write-Host $child.Snapshot()
            Write-Host "worker exit code: $($child.Process.ExitCode)"
            $errorFile=Join-Path $root 'worker-error.txt'
            if(Test-Path -LiteralPath $errorFile){Write-Host ([IO.File]::ReadAllText($errorFile))}
            Check ($child.Process.ExitCode -eq 0) 'v-next producer mock-server worker completed'
        } finally { $child.Dispose() }
    } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host "$script:count v-next producer checks passed. Synthetic fixtures only; no GPU benchmark executed."
    exit 0
}

# ================================================================ worker: mock server end-to-end
if($env:OS -ne 'Windows_NT'){throw 'The v-next worker requires native Windows.'}
if(-not ('Bitworks.FastLlm.ProcessHost' -as [type])){Add-Type -Path (Join-Path $repo 'src/ProcessHost.cs')}
& $module {Initialize-FastLlmProcessHost}
function Invoke-TestChild([string]$Script,[string]$Arguments){
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=(Get-Process -Id $PID).Path
    $text="& '$($Script.Replace("'","''"))' $Arguments"
    $info.Arguments='-NoLogo -NoProfile -NonInteractive -OutputFormat Text -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($text))
    $info.UseShellExecute=$false
    $started=New-Object Bitworks.FastLlm.ProcessHost
    $started.Start($info)
    return $started
}
function Get-TestHash([int[]]$Ids){
    $canonical="fastllm-prompt-tokens-v1`n$($Ids.Count)`n"+(($Ids|ForEach-Object {"$_`n"}) -join '')
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($canonical)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}

$caseRoot=Join-Path $FixtureRoot 'vnext'
New-Item -ItemType Directory -Path $caseRoot -Force|Out-Null
$listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
$listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
$logPath=Join-Path $caseRoot 'requests.txt'
$installRoot=Join-Path $caseRoot 'install'
$runId='a'*32
$statePath=Join-Path $installRoot 'state/status.json'
$fixture=Join-Path $PSScriptRoot 'helpers/mock-benchmark-server.ps1'
$server=Invoke-TestChild $fixture "-Port $port -Mode 'success' -LogPath '$($logPath.Replace("'","''"))' -StatusPath '$($statePath.Replace("'","''"))' -OriginalRunId '$runId'"
$lock=$null
try{
    $ready=$false
    for($i=0;$i -lt 100;$i++){
        if($server.Process.HasExited){throw "Mock HTTP server exited before readiness: $($server.Snapshot())"}
        try{$health=[Bitworks.FastLlm.LoopbackHttp]::Request("http://127.0.0.1:$port/health",$null,200,1024);if($health.Status -eq 200){$ready=$true;break}}catch{}
        Start-Sleep -Milliseconds 100
    }
    Check $ready 'mock server ready within 10 seconds'
    $lock=Enter-FastLlmOperation $installRoot
    function Write-State($WithAdapters=$false,$AdapterDriver=$null,$Vram=24576,$AdapterName='AMD Radeon RX 7900 XTX'){
        $recipe=@{contextSize=256;backend='mock';requestedArguments=@('mock-argument')}
        if($WithAdapters){$recipe['adapters']=@(@{device='Vulkan0';name=$AdapterName;vramMiB=$Vram;driverVersion=$AdapterDriver;backend='mock'})}
        Write-FastLlmState -InstallRoot $installRoot -State @{
            schemaVersion=1;runId=$runId;phase='ready';endpoint="http://127.0.0.1:$port/v1"
            modelId='synthetic-mock-only';modelSha256=('0'*64);engineVersion='mock-only'
            recipe=$recipe;canary=@{mockOnly=$true};placement=@{mockOnly=$true}
        }
    }
    function Get-RequestCount{if(Test-Path -LiteralPath $logPath){return @(Get-Content -LiteralPath $logPath).Count};return 0}

    # Seam scriptblocks run from module scope, so they use only $global: state and built-in cmdlets.
    $global:Fx=@{powerCalls=0;adlxCalls=0;adlxList=@();inventoryCalls=0;snapshotCalls=0;telemetryStarts=0;telemetryStops=0;snapshots=@();adlx=$null;boundPnp=$pnpA;hostInventory=$null}
    $global:FxSnapNormal=New-FxUniqueSnapshot
    $global:FxSnapDomain0=New-FxUniqueSnapshot $domain0
    $global:FxSnapDriverChanged=New-FxUniqueSnapshot $null 'PCI bus 3, device 0, function 0' '32.0.99999.1'
    $global:FxSnapTwo=New-FxTwoAmdSnapshot
    $global:FxSnapNvidia=New-FxNvidiaSnapshot
    $global:FxSnapMixed=New-FxSnapshot @((New-FxVulkan 0 $luidA 0x1002 0x744c 'AMD Radeon RX 7900 XTX'),(New-FxVulkan 1 $luidB 0x10de 0x2684 'NVIDIA GeForce RTX 4090')) @((New-FxDxgi 0 $luidA 0x1002 0x744c 'E4711DA2' 'C8'),(New-FxDxgi 1 $luidB 0x10de 0x2684 '00000000' '00')) @((New-FxKmt $luidA 3 0 0),(New-FxKmt $luidB 7 0 0)) @((New-FxPnp $pnpA 'PCI bus 3, device 0, function 0'))
    $global:FxAdlxOk=New-FxAdlx
    $global:FxAdlxBadDriver=New-FxAdlx -Driver '31.0.1.1'
    $global:FxHostInventory=New-FxHostInventory
    $adlxExe=Join-Path $caseRoot 'adlx.bin'
    [IO.File]::WriteAllBytes($adlxExe,[byte[]](9,8,7))
    $adlxExeSha=(Get-FileHash -LiteralPath $adlxExe -Algorithm SHA256).Hash.ToLowerInvariant()

    function Install-Seams{
        $global:Fx.inventoryCalls=0;$global:Fx.snapshotCalls=0;$global:Fx.telemetryStarts=0;$global:Fx.telemetryStops=0
        $global:Fx.snapshots=@($global:FxSnapNormal)
        $global:Fx.adlxList=@($global:FxAdlxOk);$global:Fx.adlxCalls=0
        Clear-Seams
        Set-Seam 'HostInventory' {$global:Fx.inventoryCalls++;$global:FxHostInventory}
        Set-Seam 'CpuTopology' {[pscustomobject]@{PhysicalCores=10;Packages=1;LogicalProcessors=16}}
        Set-Seam 'PowerPlanText' {'Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced)'}
        Set-Seam 'Smbios' {[pscustomobject]@{SmbiosMajor=3;SmbiosMinor=5;Type17Structures=1;PopulatedCount=1;EmptyCount=0;LogicalDeviceCountExcluded=0;InstalledCapacityComplete=$true;KnownInstalledCapacityBytes=[long]17179869184
            Devices=@([pscustomobject]@{Ordinal=0;CapacityStatus='reported';InstalledCapacityBytes=[long]17179869184;RatedSpeedStatus='reported';RatedSpeedMTps=[uint32]4800;ConfiguredSpeedStatus='reported';ConfiguredSpeedMTps=[uint32]4800})}}
        Set-Seam 'BiosRegistry' {@{BIOSVendor='Synthetic';SystemProductName='System Product Name'}}
        Set-Seam 'IdentitySnapshot' {
            $global:Fx.snapshotCalls++
            $index=[Math]::Min($global:Fx.snapshotCalls,@($global:Fx.snapshots).Count)-1
            @($global:Fx.snapshots)[$index]}
        Set-Seam 'PciLink' {@($global:FxRootPort)}
        Set-Seam 'Mcfg' {@(0,1)}
        Set-Seam 'AdlxIdentity' {param($exe,$sha,$out)
            [IO.File]::WriteAllText($out,'{"synthetic":true}')
            $global:Fx.adlxCalls++
            $list=@($global:Fx.adlxList)
            $adlx=$list[[Math]::Min($global:Fx.adlxCalls,$list.Count)-1]
            [pscustomobject]@{status='captured';reason=$null;records=$adlx.records;header=$adlx.header;path=$out}}
        Set-Seam 'TelemetryStart' {param($path,$interval,$planned) $global:Fx.telemetryStarts++;[pscustomobject]@{Host=$null;SidecarPath=$path;StartedUtc=[DateTime]::UtcNow;IntervalMs=$interval;PlannedCount=$planned;Readiness=[ordered]@{polls=3;openFailures=2;openFailureReasons=[ordered]@{other=2};emptyReads=0}}}
        Set-Seam 'TelemetryStop' {param($handle)
            $global:Fx.telemetryStops++
            $lines=@('{"schemaVersion":1,"kind":"adlx-run-header","qualification":false,"servingDeviceBound":false,"mode":"sample"}')
            $t=$handle.StartedUtc.AddMilliseconds(-500);$end=[DateTime]::UtcNow.AddMilliseconds(1500);$n=0
            while($t -le $end){$lines+=(New-FxTelemetryLine $t $n $global:Fx.boundPnp 55);$lines+=(New-FxTelemetryLine $t $n $global:FxPnpB 1);$t=$t.AddSeconds(1);$n++}
            [IO.File]::WriteAllText($handle.SidecarPath,(($lines -join "`
")+"`
"))
            [pscustomobject]@{TerminatedByProducer=$true}}
    }
    function Invoke-Vnext([string]$Name,[hashtable]$Extra=@{}){
        $out=Join-Path $caseRoot ($Name+'.json')
        $errorText=$null
        try{& $module {param($i,$o,$x) Invoke-FastLlmBenchmark -InstallRoot $i -OutputPath $o -PromptTokens @(16,32) -GenerationTokens 8 -Repetitions 5 @x|Out-Null} $installRoot $out $Extra}
        catch{$errorText=$_.Exception.Message}
        $raw=$null;$report=$null
        if(Test-Path -LiteralPath $out){$raw=Get-Content -LiteralPath $out -Raw;$report=$raw|ConvertFrom-Json}
        return [pscustomobject]@{Error=$errorText;Path=$out;Raw=$raw;Report=$report}
    }
    function Get-FxFailure([string]$Name){
        $failurePath=Join-Path $caseRoot ($Name+'.failure.json')
        if(-not (Test-Path -LiteralPath $failurePath)){return $null}
        $raw=Get-Content -LiteralPath $failurePath -Raw
        return [pscustomobject]@{Raw=$raw;Doc=($raw|ConvertFrom-Json)}
    }
    if($SeamFree){
        Clear-Seams
        Write-State ($RecipeVramMiB -gt 0) $null $RecipeVramMiB $(if($RecipeAdapterName){$RecipeAdapterName}else{$null})
        $activeNow=@(& $module {@($script:FastLlmBenchmarkSeams.Keys|ForEach-Object{[string]$_})})
        Check ($activeNow.Count -eq 0) 'seam-free run: no test seam is installed'
        $realArguments=@{}
        if($AdlxExecutablePath){$realArguments['AdlxExecutablePath']=$AdlxExecutablePath;$realArguments['AdlxExecutableSha256']=$AdlxExecutableSha256}
        $run=Invoke-Vnext 'seamfree' $realArguments
        Check ($null -eq $run.Error) "seam-free benchmark completed: $($run.Error)"
        $r=$run.Report
        function Get-FxProp($o,$n){if($null -ne $o -and $null -ne $o.PSObject.Properties[$n]){return $o.PSObject.Properties[$n].Value};return $null}
        Check (@($r.producer.activeSeams).Count -eq 0) 'seam-free run: the report lists no active seams'
        if($KeepPath){
            New-Item -ItemType Directory -Path $KeepPath -Force|Out-Null
            Get-ChildItem -LiteralPath $caseRoot -Filter 'seamfree*'|ForEach-Object{Copy-Item -LiteralPath $_.FullName -Destination $KeepPath}
        }
        try{
        $summary=@(
            "SEAMFREE activeSeams=[$(@($r.producer.activeSeams) -join ',')]",
            "SEAMFREE binding=$($r.binding.status) reason=$($r.binding.reason) crossCheck=$(Get-FxProp $r.binding.adlx 'crossCheck') adlx=$($r.binding.adlx.status)",
            "SEAMFREE driver=$(Get-FxProp @($r.binding.adapters)[0] 'driverVersion') recipeDriver=$($r.recipeDriverEvidence.status)/$($r.recipeDriverEvidence.reason)",
            "SEAMFREE telemetry=$($r.telemetry.status) reason=$($r.telemetry.reason) samples=$(Get-FxProp $r.telemetry 'sampleCount') dropped=$(Get-FxProp $r.telemetry 'droppedCount') footer=$(Get-FxProp $r.telemetry 'footerStatus')",
            "SEAMFREE readiness=$(if($null -ne (Get-FxProp $r.telemetry 'readiness')){ConvertTo-Json -InputObject (Get-FxProp $r.telemetry 'readiness') -Compress}else{'null'})",
            "SEAMFREE hardwareIdentity=$(if($r.PSObject.Properties['hardwareIdentity']){'emitted'}else{'omitted:'+$r.hardwareIdentityOmitted.reason}) mcfg=$(@($r.pciSegmentEvidence.segments) -join ',') pciLink=$($r.pciLinkEvidence.status)/$($r.pciLinkEvidence.reason)",
            "SEAMFREE refusals=$(@($r.refusals|ForEach-Object{$_.item+':'+$_.reason+':'+$_.phase}) -join ',')",
            "SEAMFREE producerVersion=$(Get-FxProp $r.producer 'version') recipeCrossCheck=$(Get-FxProp (Get-FxProp $r.binding 'recipeAdapterCrossCheck') 'status')/$(Get-FxProp (Get-FxProp $r.binding 'recipeAdapterCrossCheck') 'reason') hostStability=$(Get-FxProp (Get-FxProp $r 'hostCaptureStability') 'status')",
            "SEAMFREE rootPortLink=$(if($null -ne (Get-FxProp $r.pciLinkEvidence 'current')){ConvertTo-Json -InputObject (Get-FxProp $r.pciLinkEvidence 'current') -Compress}else{'null'}) adlxComparison=$(if($null -ne (Get-FxProp $r.pciLinkEvidence 'adlxComparison')){ConvertTo-Json -InputObject (Get-FxProp $r.pciLinkEvidence 'adlxComparison') -Compress}else{'null'})"
        )
        foreach($line in $summary){Write-Host $line}
        }catch{Write-Host ('SEAMFREE summary-error: '+([string]$_.Exception.Message -replace '[\r\n]',' '))}
        if($lock){$lock.Dispose()}
        $server.Dispose()
        Write-Host "$script:count seam-free checks passed."
        exit 0
    }
    $adlxArguments=@{AdlxExecutablePath=$adlxExe;AdlxExecutableSha256=$adlxExeSha}

    # ---- 1. phase ordering, per-sample timing, timed window (no ADLX)
    Write-State
    Install-Seams
    $before=Get-RequestCount
    $run=Invoke-Vnext 'phases'
    Check ($null -eq $run.Error) "v-next report completed: $($run.Error)"
    $report=$run.Report
    Check ($report.schemaVersion -eq 1 -and $report.resultKind -eq 'native-windows-api-benchmark-not-full-qualification' -and $report.qualification.approved -eq $false -and $report.qualification.physicalResidency -eq $false) 'v-next report keeps schemaVersion 1, the result kind and false qualification flags'
    Check ($global:Fx.inventoryCalls -eq 2) 'host inventory is captured exactly twice, before and after'
    Check (@($report.hostCapture).Count -eq 2 -and $report.hostCapture[0].phase -eq 'pre' -and $report.hostCapture[1].phase -eq 'post') 'hostCapture holds a pre and a post capture in order'
    $starts=@($report.samples|ForEach-Object {T $_.startUtc});$ends=@($report.samples|ForEach-Object {T $_.endUtc})
    $firstStart=($starts|Sort-Object|Select-Object -First 1);$lastEnd=($ends|Sort-Object|Select-Object -Last 1)
    $ordered=0;$detail=''
    for($k=0;$k -lt $starts.Count;$k++){if($starts[$k] -le $ends[$k]){$ordered++}else{$detail+=" [$k $($starts[$k].Ticks) $($ends[$k].Ticks)]"}}
    Check ($report.samples.Count -eq 10 -and $ordered -eq 10) ("every measured sample has startUtc not later than endUtc (ordered=$ordered$detail)")
    Check ((T $report.hostCapture[0].endUtc) -le $firstStart) 'the pre capture finished before the first timed sample started'
    Check ((T $report.hostCapture[1].startUtc) -ge $lastEnd) 'the post capture started after the last timed sample ended'
    Check ((T $report.hostCapture[0].startUtc) -le (T $report.hostCapture[0].endUtc) -and (T $report.hostCapture[1].startUtc) -le (T $report.hostCapture[1].endUtc)) 'each capture has ordered start and end UTC'
    Check ((T $report.timedWindow.firstStartUtc) -eq $firstStart -and (T $report.timedWindow.lastEndUtc) -eq $lastEnd -and $report.timedWindow.sampleCount -eq 10) 'timedWindow spans the measured samples'
    Check ((T $report.timedWindow.includingWarmup.firstStartUtc) -le $firstStart -and (T $report.timedWindow.includingWarmup.lastEndUtc) -ge $lastEnd) 'timedWindow also records the warmup-inclusive span'
    Check ($report.hostCapture[0].fields.smbiosMemory.status -eq 'captured' -and $report.hostCapture[0].fields.boardBios.value.SystemProductName.placeholder -eq $true -and $report.hostCapture[1].fields.cpuTopology.value.physicalCores -eq 10) 'SMBIOS, board/BIOS and topology are captured in-run in both phases'
    Check ($report.powerPlan -match 'Balanced' -and $report.os -and $report.processorCount -gt 0 -and $null -ne $report.windowsInventory.nativeHost) 'v1 compatibility fields powerPlan, os, processorCount and windowsInventory are present'
    Check (@($report.refusals).Count -eq 2 -and @($report.refusals|Where-Object item -eq 'cim-os').Count -eq 2 -and $report.refusals[0].reason -eq 'access-denied') 'typed refusals are reported for each phase'
    Check ($run.Raw -notmatch 'SENTINEL' -and @($report.windowsInventory.errors|Where-Object {$_.PSObject.Properties['message']}).Count -eq 0) 'no raw exception text reaches the report'
    Check ($report.binding.status -eq 'bound' -and $report.binding.snapshots.agree -eq $true -and $report.binding.snapshots.pre.fingerprintSha256 -eq $report.binding.snapshots.post.fingerprintSha256 -and $global:Fx.snapshotCalls -eq 2) 'the identity join runs before and after the window and agrees'
    Check ($report.binding.adlx.status -eq 'unknown' -and $report.telemetry.status -eq 'unknown' -and $report.telemetry.reason -eq 'not-configured' -and $global:Fx.telemetryStarts -eq 0) 'without ADLX the run proceeds with unknown ADLX facts and no telemetry'
    Check ($report.PSObject.Properties['hardwareIdentity'] -eq $null -and $report.hardwareIdentityOmitted.reason -eq 'pci-segment-unknown') 'hardwareIdentity is omitted with its reason when the PCI segment is not proven'
    Check ($report.producer.version -eq 'vnext.4' -and $report.hostCaptureStability.status -eq 'stable' -and (@($report.hostCaptureStability.comparedFields) -join ',') -eq 'powerPlan,cpuTopology,smbiosMemory,boardBios') 'the report carries the producer version and the host capture stability result'
    Check ($report.binding.recipeAdapterCrossCheck.status -eq 'not-checked' -and $report.binding.recipeAdapterCrossCheck.reason -eq 'recipe-adapter-count-not-one') 'the binding records the recipe adapter cross-check even when it cannot run'
    Check ($report.producer.name -eq 'fastllm-benchmark-vnext' -and $report.producer.sourceSha256 -eq (Get-FileHash -LiteralPath (Join-Path $repo 'src/FastLlm.Benchmark.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()) 'the producer is identified by its source SHA-256'
    Check ((Get-RequestCount)-$before -eq 13) 'v-next makes exactly one tokenize call plus 12 completions (no extra server calls)'
    Check ($run.Raw -notmatch '"prompt"\s*:|"content"\s*:|"tokens"\s*:|synthetic-completion-text-SECRET') 'the v-next report has no prompt, content or token-array keys'
    Check (@(Get-ChildItem -LiteralPath $caseRoot -Filter 'phases*').Count -eq 1) 'without ADLX no sidecar files are written'

    # ---- 2. v1 versus v-next on the same mock server: identical sample semantics
    $psm1=[IO.File]::ReadAllText((Join-Path $repo 'src/FastLlm.psm1'))
    $sourceDirectory=(Join-Path $repo 'src').Replace("'","''")
    $text=$psm1.Replace('FastLlm.Benchmark.ps1','FastLlm.Benchmark.v1.ps1').Replace('$PSScriptRoot',"'"+$sourceDirectory+"'")
    $v1Module=New-Module -Name FastLlmV1 -ScriptBlock ([scriptblock]::Create($text))
    Install-Seams
    $v1Path=Join-Path $caseRoot 'v1.json'
    $mark=Get-RequestCount
    & $v1Module {param($i,$o) Invoke-FastLlmBenchmark -InstallRoot $i -OutputPath $o -PromptTokens @(16,32) -GenerationTokens 8 -Repetitions 5|Out-Null} $installRoot $v1Path
    $afterV1=Get-RequestCount
    $nextRun=Invoke-Vnext 'compare'
    Check ($null -eq $nextRun.Error) "v-next comparison run completed: $($nextRun.Error)"
    $afterNext=Get-RequestCount
    $v1Report=Get-Content -LiteralPath $v1Path -Raw|ConvertFrom-Json
    $next=$nextRun.Report
    $allRequests=@(Get-Content -LiteralPath $logPath)
    $v1Requests=@($allRequests[$mark..($afterV1-1)]|Sort-Object);$nextRequests=@($allRequests[$afterV1..($afterNext-1)]|Sort-Object)
    Check ($v1Requests.Count -eq 13 -and $nextRequests.Count -eq 13 -and (($v1Requests -join '|') -ceq ($nextRequests -join '|'))) 'v1 and v-next send identical tokenize and completion requests'
    $v1Samples=@($v1Report.samples|Sort-Object requestedPromptTokens,repetition);$nextSamples=@($next.samples|Sort-Object requestedPromptTokens,repetition)
    Check ($v1Samples.Count -eq 10 -and $nextSamples.Count -eq 10) 'both producers keep five repetitions per prompt after discarding warmups'
    $v1Names=@($v1Samples[0].PSObject.Properties|ForEach-Object Name)
    $nextNames=@($nextSamples[0].PSObject.Properties|ForEach-Object Name)
    Check ((@($nextNames|Where-Object {$_ -notin @('startUtc','endUtc')}) -join ',') -ceq ($v1Names -join ',')) 'v-next samples have the v1 fields in the v1 order plus only startUtc and endUtc'
    Check (@($nextNames|Where-Object {$_ -notin $v1Names}).Count -eq 2) 'the only new sample fields are the two timing fields'
    $same=$true
    for($i=0;$i -lt 10;$i++){
        foreach($name in @('promptTokens','outputTokens','promptTokensPerSecond','generationTokensPerSecond','requestedPromptTokens','repetition','promptArtifactSha256')){
            if($v1Samples[$i].$name -cne $nextSamples[$i].$name){$same=$false}
        }
        foreach($name in @('timeToFirstTextMs','completionMs')){
            $a=[double]$v1Samples[$i].$name;$b=[double]$nextSamples[$i].$name
            if($a -le 0 -or $b -le 0 -or [double]::IsNaN($a) -or [double]::IsNaN($b) -or [double]::IsInfinity($a) -or [double]::IsInfinity($b)){$same=$false}
        }
    }
    Check $same 'sample token counts, rates, repetition, prompt size and prompt digest are identical; wall-clock timings are finite and positive'
    Check ((($v1Report.methodology.promptArtifacts|ConvertTo-Json -Depth 5 -Compress) -ceq ($next.methodology.promptArtifacts|ConvertTo-Json -Depth 5 -Compress))) 'prompt artifacts are identical'
    foreach($n in @(16,32)){
        $expectedDigest=Get-TestHash @(1..$n)
        Check (@($nextSamples|Where-Object {$_.requestedPromptTokens -eq $n -and $_.promptArtifactSha256 -eq $expectedDigest}).Count -eq 5) "v-next prompt $n digest binds its five samples to the canonical token artifact"
    }
    Check ((($v1Report.methodology|ConvertTo-Json -Depth 8 -Compress) -ceq ($next.methodology|ConvertTo-Json -Depth 8 -Compress)) -and (($v1Report.qualification|ConvertTo-Json -Compress) -ceq ($next.qualification|ConvertTo-Json -Compress)) -and $v1Report.resultKind -ceq $next.resultKind) 'methodology, qualification flags and result kind are identical'
    $v1Keys=@($v1Report.PSObject.Properties|ForEach-Object Name);$nextKeys=@($next.PSObject.Properties|ForEach-Object Name)
    Check (@($v1Keys|Where-Object {$_ -notin $nextKeys}).Count -eq 0) 'every v1 top-level key is still present'
    Check (@(@('producer','hostCapture','binding','telemetry','timedWindow','refusals')|Where-Object {$_ -notin $nextKeys}).Count -eq 0) 'the new top-level keys are present'

    # ---- 3. sentinel: no raw exception text anywhere
    Install-Seams
    foreach($seamName in @('HostInventory','CpuTopology','Smbios','BiosRegistry','IdentitySnapshot','PciLink')){Set-Seam $seamName {throw (New-Object InvalidOperationException($global:FxSentinel))}}
    $run=Invoke-Vnext 'sentinel'
    Check ($null -eq $run.Error) "a run with every probe failing still completes: $($run.Error)"
    Check ($run.Raw -notmatch 'SENTINEL') 'an injected exception message never appears in the report'
    $report=$run.Report
    Check ($report.hostCapture[0].fields.nativeHost.status -eq 'refused' -and $report.hostCapture[0].fields.nativeHost.reason -eq 'other' -and $report.hostCapture[0].fields.smbiosMemory.reason -eq 'other' -and $report.hostCapture[0].fields.boardBios.reason -eq 'other' -and $report.hostCapture[0].fields.cpuTopology.reason -eq 'other') 'failed probes are typed refusals'
    Check ($report.binding.status -eq 'unbound' -and $report.binding.reason -eq 'identity-probe-failed' -and $report.binding.probeFailureReason -eq 'other' -and $null -eq $report.windowsInventory -and $report.inventoryError -eq 'windows-inventory-unavailable') 'a failed identity probe is unbound and a failed inventory is recorded without text'
    Check ((@($report.hostCaptureStability.comparedFields) -join ',') -eq 'powerPlan') 'fields refused in both phases are not listed as compared'
    Install-Seams
    Set-Seam 'HostInventory' {throw (New-Object UnauthorizedAccessException($global:FxSentinel))}
    $run=Invoke-Vnext 'denied'
    Check ($null -eq $run.Error -and $run.Raw -notmatch 'SENTINEL' -and $run.Report.hostCapture[1].fields.nativeHost.reason -eq 'access-denied') 'access denied versus other failures are distinguished'

    # ---- 4. binding scenarios with ADLX and telemetry
    Install-Seams
    $global:Fx.snapshots=@($global:FxSnapDomain0)
    Set-Seam 'Mcfg' {@(0)}
    $before=Get-RequestCount
    $run=Invoke-Vnext 'adlx' $adlxArguments
    Check ($null -eq $run.Error) "a bound run with ADLX and telemetry completed: $($run.Error)"
    $report=$run.Report
    Check ($report.binding.status -eq 'bound' -and $report.binding.adlx.status -eq 'captured' -and $report.binding.adlx.crossCheck -eq 'passed' -and $report.binding.adapters[0].driverVersion -eq '32.0.31041.1004') 'a bound run records the ADLX cross-check and driver version'
    Check ($report.binding.adapters[0].pcieBus.value.laneWidth -eq 16 -and $report.binding.adapters[0].pcieBus.value.provenance -eq 'adlx-driver-reported' -and $report.binding.adapters[0].amdSoftwareVersion.value -eq '26.8.1') 'driver-reported PCIe link and AMD software version are in the binding'
    Check ($global:Fx.telemetryStarts -eq 1 -and $global:Fx.telemetryStops -eq 1) 'telemetry starts once and stops once'
    Check ($report.telemetry.status -eq 'captured' -and $report.telemetry.cadenceMs -eq 1000 -and $report.telemetry.sampleCount -gt 0 -and $report.telemetry.droppedCount -eq 0 -and $report.telemetry.boundDevicePnpInstanceId -eq $pnpA) 'telemetry is bound to the joined device with cadence and drop accounting'
    Check ($report.telemetry.overlapWithTimedWindow.firstSampleAtOrBeforeWindowStart -eq $true -and $report.telemetry.overlapWithTimedWindow.lastSampleAtOrAfterWindowEnd -eq $true -and @($report.telemetry.perSample).Count -eq 10) 'telemetry overlaps the timed window and has one summary per sample'
    $sidecar=Join-Path $caseRoot 'adlx.telemetry.jsonl'
    Check ((Test-Path -LiteralPath $sidecar) -and $report.telemetry.sidecar.sha256 -eq (Get-FileHash -LiteralPath $sidecar -Algorithm SHA256).Hash.ToLowerInvariant() -and $report.telemetry.sidecar.fileName -eq 'adlx.telemetry.jsonl') 'the telemetry sidecar exists and is bound by SHA-256'
    Check ((Test-Path -LiteralPath (Join-Path $caseRoot 'adlx.adlx-identity.json')) -and $report.binding.adlx.identityDocument.sha256 -eq (Get-FileHash -LiteralPath (Join-Path $caseRoot 'adlx.adlx-identity.json') -Algorithm SHA256).Hash.ToLowerInvariant()) 'the ADLX identity document is bound by SHA-256'
    Check ($report.hardwareIdentityOmitted.reason -eq 'vram-unknown') 'a bound run with a proven segment but no recipe VRAM still omits hardwareIdentity'
    Check ($global:Fx.adlxCalls -eq 2 -and (Test-Path -LiteralPath (Join-Path $caseRoot 'adlx.adlx-identity-post.json')) -and $report.binding.adlx.identityDocumentPost.sha256 -eq (Get-FileHash -LiteralPath (Join-Path $caseRoot 'adlx.adlx-identity-post.json') -Algorithm SHA256).Hash.ToLowerInvariant()) 'the ADLX identity is read again after the window and its document is bound by SHA-256'
    Check ($report.telemetry.readiness.openFailures -eq 2 -and $report.telemetry.readiness.openFailureReasons.other -eq 2 -and $report.telemetry.readiness.polls -eq 3) 'sampler readiness retries are counted and typed in the report'
    Check ($report.telemetry.PSObject.Properties['footerStatus'] -ne $null -and $report.telemetry.footerSeen -eq $false) 'the sampler footer state is reported'
    Check ($report.pciLinkEvidence.status -eq 'captured' -and $null -eq $report.pciLinkEvidence.reason) 'PCI link evidence is recorded'
    Check ($report.pciLinkEvidence.provenance -eq 'setupapi-root-port-link' -and $report.pciLinkEvidence.current.width -eq 16 -and $report.pciLinkEvidence.current.generation -eq 4 -and $report.pciLinkEvidence.max.width -eq 16 -and $report.pciLinkEvidence.adlxComparison.status -eq 'agree' -and $report.binding.adapters[0].pcieBus.value.provenance -eq 'adlx-driver-reported') 'root-port link corroboration is recorded beside the unchanged ADLX-labelled link'
    Check ($report.producer.activeSeams -contains 'Mcfg' -and $report.producer.inputSha256.'src/WindowsInventory.ps1' -match '^[0-9a-f]{64}$' -and $report.producer.inputSha256.'src/ProcessHost.cs' -match '^[0-9a-f]{64}$' -and $report.producer.inputSha256.'src/FastLlm.psm1' -match '^[0-9a-f]{64}$') 'active seams and the extended input hashes are recorded'
    Check ($report.recipeDriverEvidence.status -eq 'not-filled' -and $report.recipeDriverEvidence.reason -eq 'recipe-adapter-count-not-one') 'a recipe without adapters does not get a driver version'

    # hardwareIdentity emitted: segment proven, recipe VRAM present
    Write-State $true
    Install-Seams
    $global:Fx.snapshots=@($global:FxSnapDomain0)
    Set-Seam 'Mcfg' {@(0)}
    $run=Invoke-Vnext 'identity' $adlxArguments
    Check ($null -eq $run.Error) "a run with a proven hardware identity completed: $($run.Error)"
    $hardwareExpected=(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/vnext-hardware-identity.json') -Raw|ConvertFrom-Json).expectedHardwareIdentity
    Check ((($run.Report.hardwareIdentity|ConvertTo-Json -Depth 8 -Compress) -ceq ($hardwareExpected|ConvertTo-Json -Depth 8 -Compress)) -and $run.Report.PSObject.Properties['hardwareIdentityOmitted'] -eq $null) 'the emitted hardwareIdentity equals the fixture binding exactly'
    Check ($run.Report.hardwareIdentityProvenance.linkWidth -eq 'adlx-driver-reported' -and $run.Report.hardwareIdentityProvenance.pciSegment -eq 'acpi-mcfg-single-segment-0') 'link provenance is a sibling field and the segment is MCFG-proven'
    Check ($run.Report.binding.recipeAdapterCrossCheck.status -eq 'agree' -and $run.Report.binding.recipeAdapterCrossCheck.name.status -eq 'agree' -and $run.Report.binding.recipeAdapterCrossCheck.vram.status -eq 'agree') 'the recipe adapter name and VRAM agree with the bound device and ADLX'
    Check ($run.Report.recipe.adapters[0].driverVersion -eq '32.0.31041.1004' -and $run.Report.recipe.adapters[0].driverVersionSource -eq 'setupapi-device-property+adlx-cross-check' -and $run.Report.recipeDriverEvidence.status -eq 'filled') 'the proven driver version reaches recipe.adapters[0].driverVersion with provenance'
    # MCFG listing two segments: no 0000 bus id may be emitted
    Install-Seams
    $global:Fx.snapshots=@($global:FxSnapDomain0)
    $run=Invoke-Vnext 'twoseg' $adlxArguments
    Check ($null -eq $run.Error -and $run.Report.PSObject.Properties['hardwareIdentity'] -eq $null -and $run.Report.hardwareIdentityOmitted.reason -eq 'pci-segment-unknown') 'MCFG with two segments omits hardwareIdentity'
    # no ADLX: the recipe driver version stays null
    Install-Seams
    $global:Fx.snapshots=@($global:FxSnapDomain0)
    $run=Invoke-Vnext 'nodriver'
    Check ($null -eq $run.Error -and $null -eq $run.Report.recipe.adapters[0].driverVersion -and $run.Report.recipeDriverEvidence.reason -eq 'cross-check-not-passed') 'without a passed cross-check the recipe driver version stays null'
    # a conflicting pre-existing driver version is a hard failure before timing
    Write-State $true '31.0.1.1'
    Install-Seams
    $global:Fx.snapshots=@($global:FxSnapDomain0)
    $before=Get-RequestCount
    $run=Invoke-Vnext 'driverconflict' $adlxArguments
    Check ($run.Error -match 'disagrees with the proven driver version' -and $null -eq $run.Report -and (Get-RequestCount)-$before -eq 1) 'a conflicting recipe driver version fails before any timed request'
    Write-State
    # production guard: seams installed without the test allowance are refused
    Install-Seams
    & $module {$script:FastLlmBenchmarkAllowSeams=$false}
    $run=Invoke-Vnext 'noseams'
    Check ($run.Error -match 'test seams are active' -and $null -eq $run.Report) 'a run with test seams installed is refused unless tests allow them'
    # an existing sidecar path aborts before any request
    Install-Seams
    [IO.File]::WriteAllText((Join-Path $caseRoot 'exists.telemetry.jsonl'),'x')
    $before=Get-RequestCount
    $run=Invoke-Vnext 'exists'
    Check ($run.Error -match 'sidecar file already exists' -and (Get-RequestCount) -eq $before) 'an existing sidecar path aborts before any request'
    # a one-GPU ambiguity from a second non-AMD GPU
    Install-Seams
    $global:Fx.snapshots=@($global:FxSnapMixed)
    $run=Invoke-Vnext 'mixed'
    Check ($null -eq $run.Error -and $run.Report.binding.status -eq 'ambiguous' -and $run.Report.binding.reason -eq 'multiple-vulkan-gpus') 'an extra non-AMD GPU makes the end-to-end binding ambiguous'
    # post-window ADLX identity change is a hard failure
    Install-Seams
    $changed=New-FxAdlx;$changed.records[0].amdSoftwareVersion=(F '26.9.9')
    $global:Fx.adlxList=@($global:FxAdlxOk,$changed)
    $global:Fx.snapshots=@($global:FxSnapDomain0)
    $run=Invoke-Vnext 'adlxchange' $adlxArguments
    Check ($run.Error -match 'changed during the benchmark' -and $null -eq $run.Report -and (Test-Path -LiteralPath (Join-Path $caseRoot 'adlxchange.adlx-identity-post.json'))) 'an ADLX identity change after the window is a hard failure and its sidecars are preserved'
    $failed=Get-FxFailure 'adlxchange'
    Check ($null -ne $failed -and $failed.Doc.status -eq 'failed' -and $failed.Doc.reason -eq 'binding-changed' -and $failed.Doc.stage -eq 'post-timing' -and $failed.Doc.partial.completedMeasuredSamples -eq 10 -and @($failed.Doc.partial.hostCapture).Count -eq 2) 'the failure report carries the typed reason, the stage and the partial evidence'
    Check (@($failed.Doc.sidecars|Where-Object {$_.exists -and $_.sha256 -match '^[0-9a-f]{64}$'}).Count -ge 3 -and $failed.Raw -notmatch 'SENTINEL') 'the failure report lists the preserved sidecars with digests'

    # two AMD adapters: ambiguous, no telemetry
    Install-Seams
    $global:Fx.snapshots=@($global:FxSnapTwo)
    $run=Invoke-Vnext 'ambiguous' $adlxArguments
    Check ($null -eq $run.Error -and $run.Report.binding.status -eq 'ambiguous' -and $run.Report.binding.reason -eq 'multiple-amd-adapters' -and $run.Report.binding.selection -eq 'unbound') 'two AMD adapters are reported ambiguous and unbound'
    Check ($global:Fx.telemetryStarts -eq 0 -and $run.Report.telemetry.status -eq 'unknown' -and $run.Report.telemetry.reason -eq 'binding-not-bound' -and $run.Report.hardwareIdentityOmitted.reason -eq 'binding-not-bound') 'an unbound device gets no telemetry and no hardware identity'

    # no AMD adapter, no ADLX: unbound
    Install-Seams
    $global:Fx.snapshots=@($global:FxSnapNvidia)
    $run=Invoke-Vnext 'unbound'
    Check ($null -eq $run.Error -and $run.Report.binding.status -eq 'unbound' -and $run.Report.binding.reason -eq 'no-amd-adapter') 'a host without an AMD adapter is reported unbound'

    # driver-version mismatch: hard failure before any timed sample
    Install-Seams
    $global:Fx.adlxList=@($global:FxAdlxBadDriver)
    $before=Get-RequestCount
    $run=Invoke-Vnext 'mismatch' $adlxArguments
    Check ($run.Error -match 'differs from the SetupAPI driver version' -and $null -eq $run.Report) 'an ADLX versus SetupAPI driver mismatch fails the run'
    Check ((Get-RequestCount)-$before -eq 1 -and $global:Fx.telemetryStarts -eq 0) 'the mismatch fails before any timed completion request or telemetry'
    Check ((Test-Path -LiteralPath (Join-Path $caseRoot 'mismatch.adlx-identity.json')) -and (Get-FxFailure 'mismatch').Doc.reason -eq 'adlx-driver-mismatch' -and (Get-FxFailure 'mismatch').Doc.stage -eq 'pre-timing') 'a failed run keeps its ADLX sidecar and writes a typed failure report'

    # pre/post snapshot disagreement: hard failure after the window, sidecars removed
    Install-Seams
    $global:Fx.snapshots=@($global:FxSnapNormal,$global:FxSnapDriverChanged)
    $run=Invoke-Vnext 'disagree' $adlxArguments
    Check ($run.Error -match 'differs from the SetupAPI driver version|changed during the benchmark' -and $null -eq $run.Report) 'a post-window identity change fails the run'
    Check ($global:Fx.telemetryStops -ge 1 -and (Test-Path -LiteralPath (Join-Path $caseRoot 'disagree.telemetry.jsonl')) -and (Test-Path -LiteralPath (Join-Path $caseRoot 'disagree.adlx-identity.json')) -and (Get-FxFailure 'disagree').Doc.status -eq 'failed') 'telemetry is stopped and sidecars are preserved on failure'
    Install-Seams
    $global:Fx.snapshots=@($global:FxSnapNormal,$global:FxSnapTwo)
    $run=Invoke-Vnext 'disagree2'
    Check ($run.Error -match 'changed during the benchmark' -and $null -eq $run.Report) 'a bound to ambiguous change after the window fails the run'

    # ADLX parameter hard failures before any request
    Install-Seams
    $before=Get-RequestCount
    $run=Invoke-Vnext 'onlypath' @{AdlxExecutablePath=$adlxExe}
    Check ($run.Error -match 'supplied together' -and (Get-RequestCount) -eq $before) 'a lone ADLX path fails before any request'
    $run=Invoke-Vnext 'badsha' @{AdlxExecutablePath=$adlxExe;AdlxExecutableSha256=('0'*64)}
    Check ($run.Error -match 'digest does not match' -and (Get-RequestCount) -eq $before) 'an ADLX digest mismatch fails before any request'

    # unreadable power plan is a hard failure, as in v1
    Install-Seams
    Set-Seam 'PowerPlanText' {throw (New-Object InvalidOperationException($global:FxSentinel))}
    $run=Invoke-Vnext 'power'
    Check ($run.Error -match 'power plan' -and $run.Error -notmatch 'SENTINEL' -and $null -eq $run.Report) 'an unreadable power plan fails without raw exception text'
    Check ((Get-FxFailure 'power').Doc.reason -eq 'power-plan-unreadable-pre' -and (Get-FxFailure 'power').Raw -notmatch 'SENTINEL') 'the unreadable power plan failure report is typed and carries no exception text'

    # v-next.1: a power plan that changes between the captures is a hard failure with a typed reason
    Install-Seams
    $global:Fx.powerCalls=0
    Set-Seam 'PowerPlanText' {$global:Fx.powerCalls++;if($global:Fx.powerCalls -gt 1){'Power Scheme GUID: 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c  (High performance)'}else{'Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced)'}}
    $run=Invoke-Vnext 'hostchange'
    $failed=Get-FxFailure 'hostchange'
    Check ($run.Error -match 'Host capture changed' -and $null -eq $run.Report -and $null -ne $failed -and $failed.Doc.reason -eq 'host-capture-changed' -and $failed.Doc.stage -eq 'post-timing' -and $failed.Doc.partial.completedMeasuredSamples -eq 10) 'a power plan change between captures fails before any result with host-capture-changed'

    # v-next.1: an untyped failure is recorded as unclassified and its text never reaches the report
    Install-Seams
    Set-Seam 'AdlxIdentity' {param($exe,$sha,$out) [IO.File]::WriteAllText($out,'{"synthetic":true}');throw (New-Object InvalidOperationException($global:FxSentinel))}
    $run=Invoke-Vnext 'untyped' $adlxArguments
    $failed=Get-FxFailure 'untyped'
    Check ($null -eq $run.Report -and $null -ne $failed -and $failed.Doc.reason -eq 'unclassified' -and $failed.Doc.errorClass -eq 'other' -and $failed.Raw -notmatch 'SENTINEL' -and (Test-Path -LiteralPath (Join-Path $caseRoot 'untyped.adlx-identity.json'))) 'an untyped failure is unclassified, keeps its sidecar and records no exception text'
    $global:FxModule=$module
    # optional (discovered) ADLX probe: a probe that cannot run before the window no longer stops the benchmark
    $optionalArguments=@{AdlxExecutablePath=$adlxExe;AdlxExecutableSha256=$adlxExeSha;AdlxOptional=$true}
    foreach($optionalReason in @('adlx-identity-collection-failed','adlx-identity-report-invalid')){
        Install-Seams
        $global:Fx.adlxCalls=0;$global:FxOptionalReason=$optionalReason
        if($optionalReason -eq 'adlx-identity-collection-failed'){$global:FxOptionalExit=5;$global:FxOptionalStep='driver-signature'}else{$global:FxOptionalExit=$null;$global:FxOptionalStep='C:\\raw\\SENTINEL-stderr-text'}
        Set-Seam 'AdlxIdentity' {param($exe,$sha,$out) $global:Fx.adlxCalls++;throw (& $global:FxModule {param($r,$e,$st) $f=New-FastLlmBenchmarkFailure $r 'synthetic probe failure';if($null -ne $e){$f.Data['fastllmAdlxExitCode']=$e};$f.Data['fastllmAdlxStep']=$st;$f} $global:FxOptionalReason $global:FxOptionalExit $global:FxOptionalStep)}
        $global:Fx.snapshots=@($global:FxSnapDomain0)
        Set-Seam 'Mcfg' {@(0)}
        $name='optional-'+$optionalReason
        $run=Invoke-Vnext $name $optionalArguments
        Check ($null -eq $run.Error -and $null -ne $run.Report) "optional probe, $optionalReason before the window: the run completes ($($run.Error))"
        $report=$run.Report
        Check ($report.binding.adlx.status -eq 'unknown' -and $report.binding.adlx.reason -eq 'optional-probe-failed' -and $report.binding.adlx.optionalFailureReason -eq $optionalReason -and $report.binding.adlx.crossCheck -eq 'not-run') "optional probe, $optionalReason`: the binding records ADLX as unknown, optional-probe-failed and the specific reason"
        if($optionalReason -eq 'adlx-identity-collection-failed'){Check ($report.binding.adlx.optionalFailureExitCode -eq 5 -and $report.binding.adlx.optionalFailureStep -ceq 'driver-signature') 'optional probe: the exit code and the step token from the failure are recorded'}
        else{Check ($report.binding.adlx.optionalFailureExitCode -eq 0 -and $report.binding.adlx.optionalFailureStep -ceq 'unknown' -and $run.Raw -notmatch 'SENTINEL-stderr-text' -and $run.Raw -notmatch 'stderr-text') 'optional probe: a report-invalid failure records exit code 0, and a non-token step (raw text) is never copied into the report'}
        Check ($report.telemetry.status -eq 'unknown' -and $report.telemetry.reason -eq 'optional-probe-failed' -and $global:Fx.telemetryStarts -eq 0 -and $global:Fx.telemetryStops -eq 0) "optional probe, $optionalReason`: no telemetry is started and its unknown reason is optional-probe-failed"
        Check ($global:Fx.adlxCalls -eq 1 -and -not (Test-Path -LiteralPath (Join-Path $caseRoot ($name+'.adlx-identity-post.json'))) -and $null -eq $report.binding.adlx.PSObject.Properties['identityDocument'] -and $null -eq $report.binding.adlx.PSObject.Properties['identityDocumentPost']) "optional probe, $optionalReason`: the identity is read once (no post read) and no identity document is bound"
        Check ($report.binding.status -eq 'bound' -and $report.binding.snapshots.agree -eq $true -and $report.samples.Count -eq 10 -and -not (Test-Path -LiteralPath (Join-Path $caseRoot ($name+'.failure.json')))) "optional probe, $optionalReason`: the binding still agrees, all samples are kept and no failure report is written"
    }
    # the same probe failure without AdlxOptional is unchanged: it fails the run with its typed reason
    Install-Seams
    $global:FxOptionalReason='adlx-identity-collection-failed'
    Set-Seam 'AdlxIdentity' {param($exe,$sha,$out) throw (& $global:FxModule {param($r) New-FastLlmBenchmarkFailure $r 'synthetic probe failure'} $global:FxOptionalReason)}
    $before=Get-RequestCount
    $run=Invoke-Vnext 'notoptional' $adlxArguments
    Check ($null -eq $run.Report -and $run.Error -match 'ADLX identity collection failed|synthetic probe failure' -and (Get-FxFailure 'notoptional').Doc.reason -eq 'adlx-identity-collection-failed' -and (Get-RequestCount)-$before -eq 1) 'without AdlxOptional an ADLX probe failure still fails the run with its typed reason'
    # an identity disagreement stays a hard failure even when the probe is optional
    Install-Seams
    $global:Fx.adlxList=@($global:FxAdlxBadDriver)
    $global:Fx.snapshots=@($global:FxSnapDomain0)
    $run=Invoke-Vnext 'optional-mismatch' $optionalArguments
    Check ($null -eq $run.Report -and (Get-FxFailure 'optional-mismatch').Doc.reason -eq 'adlx-driver-mismatch') 'optional probe: a captured identity that disagrees (driver mismatch) is still a hard failure'
    Install-Seams
    $badPnp=New-FxAdlx 'PCI\VEN_1002&DEV_744C&SUBSYS_E4711DA2&REV_C8\SYNTHETIC-99999999'
    $global:Fx.adlxList=@($badPnp)
    $global:Fx.snapshots=@($global:FxSnapDomain0)
    $run=Invoke-Vnext 'optional-identity' $optionalArguments
    Check ($null -eq $run.Report -and (Get-FxFailure 'optional-identity').Doc.reason -eq 'adlx-identity-mismatch') 'optional probe: a captured identity for a different adapter (adlx-identity-mismatch) is still a hard failure'
    # a post-window read that fails after a successful pre read stays a hard failure
    Install-Seams
    $global:Fx.adlxCalls=0;$global:FxOptionalReason='adlx-identity-collection-failed'
    Set-Seam 'AdlxIdentity' {param($exe,$sha,$out)
        $global:Fx.adlxCalls++
        if($global:Fx.adlxCalls -gt 1){throw (& $global:FxModule {param($r) New-FastLlmBenchmarkFailure $r 'synthetic probe failure'} $global:FxOptionalReason)}
        [IO.File]::WriteAllText($out,'{"synthetic":true}')
        [pscustomobject]@{status='captured';reason=$null;records=$global:FxAdlxOk.records;header=$global:FxAdlxOk.header;path=$out}}
    $global:Fx.snapshots=@($global:FxSnapDomain0)
    $run=Invoke-Vnext 'optional-post' $optionalArguments
    Check ($null -eq $run.Report -and $global:Fx.adlxCalls -eq 2 -and (Get-FxFailure 'optional-post').Doc.reason -eq 'adlx-identity-collection-failed' -and (Get-FxFailure 'optional-post').Doc.stage -eq 'post-timing') 'optional probe: a post-window read failure after a successful pre read is still a hard failure'
    # AdlxOptional without both ADLX arguments is an argument error before any request
    Install-Seams
    $before=Get-RequestCount
    $run=Invoke-Vnext 'optional-noargs' @{AdlxOptional=$true}
    Check ($run.Error -match 'AdlxOptional requires AdlxExecutablePath and AdlxExecutableSha256' -and (Get-RequestCount) -eq $before) 'AdlxOptional without the ADLX arguments fails before any request'
    $run=Invoke-Vnext 'optional-pathonly' @{AdlxOptional=$true;AdlxExecutablePath=$adlxExe}
    Check ($run.Error -match 'AdlxOptional requires AdlxExecutablePath and AdlxExecutableSha256' -and (Get-RequestCount) -eq $before) 'AdlxOptional with only the ADLX path fails before any request'
    # The REAL child path, no seam: the wrapper checks, in order, the platform, the parameters, the output path, then the executable digest, and only afterwards looks for
    # the AMD driver evidence. A regular file with a deliberately wrong digest therefore fails on 'Executable digest mismatch.' on any standard-user Windows box, with no AMD hardware.
    Clear-Seams
    $realExe=Join-Path $caseRoot 'real-child-probe.exe'
    [IO.File]::WriteAllBytes($realExe,[byte[]](1,2,3,4))
    $realOut=Join-Path $caseRoot 'real-child-identity.json'
    $realFailure=$null
    try{& $module {param($e,$o) Get-FastLlmBenchmarkAdlxIdentity $e ('0'*64) $o|Out-Null} $realExe $realOut}catch{$realFailure=$_}
    $realData=$null;if($null -ne $realFailure){$realData=$realFailure.Exception.Data}
    Check ($null -ne $realFailure -and (& $module {param($f) Get-FastLlmBenchmarkFailureReason $f} $realFailure) -ceq 'adlx-identity-collection-failed') 'the real ADLX child failing its digest check raises adlx-identity-collection-failed'
    Check ($null -ne $realData -and $realData['fastllmAdlxExitCode'] -is [int] -and $realData['fastllmAdlxExitCode'] -ne 0) 'the real child failure carries a non-zero integer exit code'
    Check ($null -ne $realData -and $realData['fastllmAdlxStep'] -ceq 'executable-digest') 'the real child failure maps its stderr to the executable-digest step'
    Check (-not (Test-Path -LiteralPath $realOut)) 'the failed real child wrote no report file'
    # an existing failure report path aborts before any request
    Install-Seams
    [IO.File]::WriteAllText((Join-Path $caseRoot 'failexists.failure.json'),'x')
    $before=Get-RequestCount
    $run=Invoke-Vnext 'failexists'
    Check ($run.Error -match 'sidecar file already exists' -and (Get-RequestCount) -eq $before) 'an existing failure report path aborts before any request'

    # v-next.1: a recipe adapter that does not match the bound device makes the binding ambiguous
    Write-State $true $null 24576 'Some Other GPU'
    Install-Seams
    $global:Fx.snapshots=@($global:FxSnapDomain0)
    Set-Seam 'Mcfg' {@(0)}
    $run=Invoke-Vnext 'recipename' $adlxArguments
    Check ($null -eq $run.Error -and $run.Report.binding.status -eq 'ambiguous' -and $run.Report.binding.reason -eq 'recipe-adapter-name-mismatch' -and $run.Report.binding.recipeAdapterCrossCheck.status -eq 'mismatch' -and $global:Fx.telemetryStarts -eq 0 -and $run.Report.recipeDriverEvidence.reason -eq 'binding-not-bound' -and $run.Report.hardwareIdentityOmitted.reason -eq 'binding-not-bound' -and $null -eq $run.Report.recipe.adapters[0].driverVersion) 'a recipe name mismatch is ambiguous: no telemetry, no driver fill, no hardware identity'
    Write-State $true $null 12000
    Install-Seams
    $global:Fx.snapshots=@($global:FxSnapDomain0)
    $run=Invoke-Vnext 'recipevram' $adlxArguments
    Check ($null -eq $run.Error -and $run.Report.binding.status -eq 'ambiguous' -and $run.Report.binding.reason -eq 'recipe-adapter-vram-mismatch') 'a recipe VRAM mismatch beyond the tolerance is ambiguous'
    Write-State

    # v-next.1: a telemetry sidecar the sampler still holds is a typed telemetry reason, not an aborted run
    Install-Seams
    $global:Fx.snapshots=@($global:FxSnapDomain0)
    $global:FxOrigStop=& $module {$script:FastLlmBenchmarkSeams['TelemetryStop']}
    Set-Seam 'TelemetryStop' {param($handle) $result=& $global:FxOrigStop $handle;$global:FxHold=[IO.File]::Open($handle.SidecarPath,'Open','ReadWrite','None');$result}
    try{$run=Invoke-Vnext 'telemetrylock' $adlxArguments}finally{if($global:FxHold){$global:FxHold.Dispose();$global:FxHold=$null}}
    Check ($null -eq $run.Error -and $null -ne $run.Report -and @($run.Report.samples).Count -eq 10 -and $run.Report.telemetry.status -eq 'unknown' -and $run.Report.telemetry.reason -eq 'sidecar-read-failed' -and $run.Report.telemetry.readFailureReason -eq 'other') 'a persistently locked telemetry sidecar gives a typed telemetry reason and keeps the timed samples'
    Check ($run.Report.telemetry.sidecar.fileName -eq 'telemetrylock.telemetry.jsonl' -and $run.Report.telemetry.sidecar.format -eq 'adlx-sample-jsonl' -and $null -eq $run.Report.telemetry.sidecar.sha256 -and $run.Report.telemetry.sidecar.hashFailureReason -eq 'other') 'the unreadable sidecar is still listed, with a typed hash failure while it is held'

    # ---- v-next.2: classification, normalized names, collection flags, S3 flip, S4 input evidence, S2 write fault, S5 missing directory
    Write-State $true
    Install-Seams
    $global:Fx.snapshots=@($global:FxSnapDomain0)
    Set-Seam 'Mcfg' {@(0)}
    $run=Invoke-Vnext 'v2base' $adlxArguments
    Check ($null -eq $run.Error) "a v-next.2 run completed: $($run.Error)"
    $r2=$run.Report
    $hashNames=@($r2.producer.inputSha256.PSObject.Properties|ForEach-Object Name)
    $classNames=@($r2.producer.inputClassification.PSObject.Properties|ForEach-Object Name)
    Check ($r2.producer.version -eq 'vnext.4' -and $hashNames.Count -eq 31 -and $classNames.Count -eq 31 -and (($hashNames -join ',') -ceq ($classNames -join ',')) -and @($hashNames|Where-Object {$r2.producer.inputSha256.$_ -notmatch '^[0-9a-f]{64}$'}).Count -eq 0) 'the report lists 31 input hashes and classifies every one'
    Check ($r2.producer.inputClassification.'src/ProcessHost.cs' -eq 'identity' -and $r2.producer.inputClassification.'tools/collect-vulkan-luid-join.ps1' -eq 'identity' -and $r2.producer.inputClassification.'src/FastLlm.psm1' -eq 'runtime' -and $r2.producer.inputClassification.'src/WindowsInventory.ps1' -eq 'runtime' -and $r2.producer.inputClassification.'src/FastLlm.FileReplace.ps1' -eq 'runtime' -and $r2.producer.inputClassification.'tools/benchmark.ps1' -eq 'runtime' -and $r2.producer.inputSha256.'tools/benchmark.ps1' -match '^[0-9a-f]{64}$') 'the report classifies collectors and C# as identity, the module scripts and the tools/benchmark.ps1 entry script as runtime, and pins tools/benchmark.ps1'
    $nameEvidence=$r2.binding.recipeAdapterCrossCheck.name
    Check ($nameEvidence.status -eq 'agree' -and $nameEvidence.recipe -ceq 'amd radeon rx 7900 xtx' -and $nameEvidence.bound -ceq 'amd radeon rx 7900 xtx' -and $nameEvidence.recipeRaw -ceq 'AMD Radeon RX 7900 XTX' -and $nameEvidence.boundRaw -ceq 'AMD Radeon RX 7900 XTX') 'name.recipe and name.bound are both normalized, with the raw strings kept in separate fields'
    Check ($r2.binding.collectionErrors.vulkan -eq $false -and $r2.binding.collectionErrors.dxgi -eq $false -and $r2.binding.collectionErrors.setupApi -eq $false) 'the report binding records the collection error flags'
    Check ((@($r2.hostCaptureStability.comparedFields) -join ',') -eq 'powerPlan,cpuTopology,smbiosMemory,boardBios') 'a fully captured host lists all four compared fields'

    # S3 end to end: a captured to refused flip fails with its own typed reason; refused in both phases is not compared
    Install-Seams
    $global:Fx.topologyCalls=0
    Set-Seam 'CpuTopology' {$global:Fx.topologyCalls++;if($global:Fx.topologyCalls -gt 1){throw (New-Object UnauthorizedAccessException($global:FxSentinel))};[pscustomobject]@{PhysicalCores=10;Packages=1;LogicalProcessors=16}}
    $run=Invoke-Vnext 'flip'
    $failed=Get-FxFailure 'flip'
    $flipPartial=$failed.Doc.partial.hostCaptureChanges
    Check ($run.Error -match 'Host capture changed' -and $null -eq $run.Report -and $null -ne $failed -and $failed.Doc.reason -eq 'host-capture-status-changed' -and $failed.Doc.stage -eq 'post-timing' -and @($flipPartial).Count -eq 1 -and $flipPartial[0].field -eq 'cpuTopology' -and $flipPartial[0].reason -eq 'host-capture-status-changed' -and $failed.Raw -notmatch 'SENTINEL') 'a captured to refused topology flip fails with host-capture-status-changed and the failure report names the field'
    Install-Seams
    Set-Seam 'CpuTopology' {throw (New-Object UnauthorizedAccessException($global:FxSentinel))}
    $run=Invoke-Vnext 'bothrefused'
    Check ($null -eq $run.Error -and $run.Report.hostCaptureStability.status -eq 'stable' -and (@($run.Report.hostCaptureStability.comparedFields) -join ',') -eq 'powerPlan,smbiosMemory,boardBios' -and $run.Report.hostCapture[0].fields.cpuTopology.status -eq 'refused') 'a field refused in both phases is not listed in comparedFields and does not fail the run'

    # S4 end to end: input failures are traceable from the failure report (fixed relative paths and hashes, never exception text)
    $relativesNow=@(& $module {$script:FastLlmBenchmarkInputRelativePaths})
    function New-FxInputTree([string]$Root,[string]$Omit){
        foreach($rel in $relativesNow){
            if($rel -eq $Omit){continue}
            $full=Join-Path $Root $rel
            New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force|Out-Null
            [IO.File]::WriteAllText($full,"fixture $rel")
        }
    }
    $global:FxInputRoot=Join-Path $caseRoot 'inputs-missing'
    New-FxInputTree $global:FxInputRoot 'src/WindowsPciLink.cs'
    Install-Seams
    Set-Seam 'InputRoot' {$global:FxInputRoot}
    $before=Get-RequestCount
    $run=Invoke-Vnext 'inmissing'
    $failed=Get-FxFailure 'inmissing'
    $evidenceMissing=$failed.Doc.partial.inputEvidence
    Check ($run.Error -match 'input file is missing' -and $null -ne $failed -and $failed.Doc.reason -eq 'input-missing' -and $failed.Doc.stage -eq 'pre-timing' -and (@($evidenceMissing.paths) -join ',') -eq 'src/WindowsPciLink.cs' -and $evidenceMissing.startSha256.'src/FastLlm.psm1' -match '^[0-9a-f]{64}$' -and $null -eq $evidenceMissing.startSha256.'src/WindowsPciLink.cs' -and $null -eq $evidenceMissing.endSha256 -and (Get-RequestCount) -eq $before -and $failed.Raw -notmatch 'SENTINEL') 'a missing input is traceable: the failure report names the path and carries the start hashes'
    $global:FxInputRoot=Join-Path $caseRoot 'inputs-changed'
    New-FxInputTree $global:FxInputRoot ''
    Install-Seams
    Set-Seam 'InputRoot' {$global:FxInputRoot}
    $global:Fx.snapshots=@($global:FxSnapNormal)
    Set-Seam 'IdentitySnapshot' {$global:Fx.snapshotCalls++;if($global:Fx.snapshotCalls -eq 2){[IO.File]::WriteAllText((Join-Path $global:FxInputRoot 'src/FastLlm.psm1'),'mutated during the run')};$global:FxSnapNormal}
    $run=Invoke-Vnext 'inchanged'
    $failed=Get-FxFailure 'inchanged'
    $evidenceChanged=$failed.Doc.partial.inputEvidence
    Check ($run.Error -match 'changed during the run' -and $null -ne $failed -and $failed.Doc.reason -eq 'input-changed' -and $failed.Doc.stage -eq 'post-timing' -and (@($evidenceChanged.paths) -join ',') -eq 'src/FastLlm.psm1' -and $evidenceChanged.startSha256.'src/FastLlm.psm1' -match '^[0-9a-f]{64}$' -and $evidenceChanged.endSha256.'src/FastLlm.psm1' -match '^[0-9a-f]{64}$' -and $evidenceChanged.startSha256.'src/FastLlm.psm1' -ne $evidenceChanged.endSha256.'src/FastLlm.psm1' -and $evidenceChanged.startSha256.'src/FastLlm.Runtime.ps1' -eq $evidenceChanged.endSha256.'src/FastLlm.Runtime.ps1') 'a changed input is traceable: the failure report names the path and carries the start and end hashes'

    # S2 end to end: a write failure leaves no output file, and the failure report is written
    Install-Seams
    Set-Seam 'OutputWriteFault' {throw (New-Object IO.IOException($global:FxSentinel))}
    $run=Invoke-Vnext 'writefault'
    $failed=Get-FxFailure 'writefault'
    Check ($null -ne $run.Error -and -not (Test-Path -LiteralPath (Join-Path $caseRoot 'writefault.json')) -and $null -ne $failed -and $failed.Doc.reason -eq 'unclassified' -and $failed.Doc.stage -eq 'post-timing' -and $failed.Doc.partial.completedMeasuredSamples -eq 10 -and $failed.Raw -notmatch 'SENTINEL') 'a failed result write leaves no output file and the failure report is written without exception text'

    # N1 end to end: failure.json is serialized before it is opened, so a serialization fault never leaves an empty failure.json (the original failure is still raised)
    $global:FxInputRoot=Join-Path $caseRoot 'inputs-n1'
    New-FxInputTree $global:FxInputRoot 'src/WindowsPciLink.cs'
    Install-Seams
    Set-Seam 'InputRoot' {$global:FxInputRoot}
    Set-Seam 'FailureSerializeFault' {throw (New-Object IO.IOException($global:FxSentinel))}
    $run=Invoke-Vnext 'n1fault'
    Check ($run.Error -match 'input file is missing' -and $run.Error -notmatch 'SENTINEL' -and -not (Test-Path -LiteralPath (Join-Path $caseRoot 'n1fault.failure.json')) -and -not (Test-Path -LiteralPath (Join-Path $caseRoot 'n1fault.json'))) 'a failure.json serialization fault leaves no failure.json (not an empty one) and the original failure is still raised'

    # N1 end to end, write side: a fault after failure.json was created deletes that file (never an empty or partial one is left)
    Install-Seams
    Set-Seam 'InputRoot' {$global:FxInputRoot}
    Set-Seam 'FailureWriteFault' {throw (New-Object IO.IOException($global:FxSentinel))}
    $run=Invoke-Vnext 'n1writefault'
    Check ($run.Error -match 'input file is missing' -and -not (Test-Path -LiteralPath (Join-Path $caseRoot 'n1writefault.failure.json'))) 'a failure.json write fault after the file was created deletes it (no empty or partial failure.json) and the original failure is still raised'

    # S5 end to end: an early failure still produces a failure report when the output directory does not exist yet
    Install-Seams
    $s5Dir=Join-Path $caseRoot ('missing-dir-'+[Guid]::NewGuid().ToString('N'))
    $s5Out=Join-Path $s5Dir 's5.json'
    $s5Error=$null
    try{& $module {param($i,$o) Invoke-FastLlmBenchmark -InstallRoot $i -OutputPath $o -PromptTokens @(16,100) -GenerationTokens 8 -Repetitions 5|Out-Null} $installRoot $s5Out}catch{$s5Error=$_.Exception.Message}
    $s5Report=Join-Path $s5Dir 's5.failure.json'
    $s5Doc=$null
    if(Test-Path -LiteralPath $s5Report){$s5Doc=Get-Content -LiteralPath $s5Report -Raw|ConvertFrom-Json}
    Check ($s5Error -match 'did not produce enough tokens' -and $null -ne $s5Doc -and $s5Doc.reason -eq 'corpus-too-short' -and $s5Doc.stage -eq 'pre-timing' -and -not (Test-Path -LiteralPath $s5Out)) 'a failure before the output directory existed still writes the failure report (corpus check)'
    Write-State
    Clear-Seams
}finally{
    Clear-Seams
    if($lock){$lock.Dispose()}
    $server.Dispose()
}
Write-Host "$script:count v-next producer checks passed in the worker."
