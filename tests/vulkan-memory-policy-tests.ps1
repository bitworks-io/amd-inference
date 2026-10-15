#requires -Version 5.1
# Mock-only tests for the Vulkan host-visible-VRAM mitigation switch, the advisory Resizable-BAR detector and the
# advisory throughput canary. Every default is off; nothing here qualifies hardware or changes a default.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force
$module=Get-Module FastLlm
$count=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:count++;Write-Host "PASS: $Message"}
function Heap([double]$Size,[bool]$Local){[pscustomobject]@{heapIndex=0;sizeBytes=$Size;flags=0;deviceLocal=$Local}}
$MiB=[double]1048576;$GiB=[double]1073741824
function Classify($Heaps){& $module {param($H) Get-FastLlmVulkanBarClassification -Heaps $H} $Heaps}
function State($Report,$Names){& $module {param($R,$N) Get-FastLlmVulkanRebarState -Report $R -AdapterNames $N} $Report $Names}

# ---- detector: pure classifier ----
Check ((Classify @((Heap (24*$GiB) $true),(Heap (16*$GiB) $false))) -eq 'rebar-on') 'one large DEVICE_LOCAL heap plus a host heap is rebar-on'
Check ((Classify @((Heap (24*$GiB) $true),(Heap (16*$GiB) $false),(Heap (256*$MiB) $true))) -eq 'rebar-off') 'a separate 256 MiB DEVICE_LOCAL heap beside a large one is rebar-off'
Check ((Classify @((Heap (24*$GiB) $true),(Heap (512*$MiB) $true))) -eq 'rebar-off') 'a DEVICE_LOCAL heap of exactly 512 MiB still counts as the BAR aperture'
Check ((Classify @((Heap (24*$GiB) $true),(Heap (513*$MiB) $true))) -eq 'unknown') 'a 513 MiB DEVICE_LOCAL heap is neither the BAR aperture nor a large heap: unknown'
Check ((Classify @((Heap (24*$GiB) $true),(Heap (256*$MiB) $false))) -eq 'rebar-on') 'a small host-only heap is not a BAR aperture'
Check ((Classify @((Heap (256*$MiB) $true))) -eq 'unknown') 'only a small DEVICE_LOCAL heap is unknown, not rebar-off'
Check ((Classify @()) -eq 'unknown' -and (Classify $null) -eq 'unknown') 'no heaps is unknown'
Check ((Classify @([pscustomobject]@{sizeBytes=(24*$GiB)})) -eq 'unknown') 'a heap without deviceLocal is unknown'
Check ((Classify @([pscustomobject]@{sizeBytes='bad';deviceLocal=$true})) -eq 'unknown') 'a non-numeric heap size is unknown'

# ---- detector: real XT host and XTX host heap layouts (trimmed from the 2026-10-06 LUID/budget reports) ----
$xtHost=Read-FastLlmJson (Join-Path $PSScriptRoot 'fixtures/vulkan-heaps-xt-rebar-on.json')
$xtxHost=Read-FastLlmJson (Join-Path $PSScriptRoot 'fixtures/vulkan-heaps-xtx-rebar-off.json')
Check ((State $xtHost @('AMD Radeon RX 7900 XT')).classification -eq 'rebar-on') 'XT host (single 21.5 GB device-local heap) classifies rebar-on'
Check ((State $xtxHost @('AMD Radeon RX 7900 XTX')).classification -eq 'rebar-off') 'XTX host (25.5 GB plus 268435456-byte device-local heaps) classifies rebar-off'
Check ((State $xtxHost @()).classification -eq 'rebar-off') 'a single-device report is unambiguous without an adapter name'
$two=$xtxHost | ConvertTo-Json -Depth 12 | ConvertFrom-Json
$second=$xtHost.devices[0] | ConvertTo-Json | ConvertFrom-Json;$second.index=1
$two.devices=@($two.devices[0],$second)
$sampleOne=$xtHost.budgetSamples[0].vulkan[0] | ConvertTo-Json -Depth 8 | ConvertFrom-Json;$sampleOne.index=1
$two.budgetSamples[0].vulkan=@($two.budgetSamples[0].vulkan[0],$sampleOne)
Check ((State $two @('AMD Radeon RX 7900 XT')).classification -eq 'rebar-on' -and (State $two @('AMD Radeon RX 7900 XTX')).classification -eq 'rebar-off') 'with two devices the adapter is matched by exact name, never by index or substring'
Check ((State $two @('AMD Radeon RX 7900 XTX','AMD Radeon RX 7900 XT')).classification -eq 'unknown' -and (State $two @('AMD Radeon RX 7900 XTX','AMD Radeon RX 7900 XT')).reason -eq 'selected-devices-disagree') 'with several selected adapters that disagree the detector is unknown (selected-devices-disagree), never rebar-off'
Check ((State $two @('Some Other Card')).classification -eq 'unknown' -and (State $two @()).classification -eq 'unknown') 'an unmatched or unnamed adapter among several devices is unknown'
$bad=$xtxHost | ConvertTo-Json -Depth 12 | ConvertFrom-Json;$bad.budgetSamples[0].vulkan[0].status='failed'
Check ((State $bad @('AMD Radeon RX 7900 XTX')).classification -eq 'unknown') 'a failed heap sample is unknown'
$bad=$xtxHost | ConvertTo-Json -Depth 12 | ConvertFrom-Json;$bad.budgetSamples[0].vulkan[0].identityMatchesInitialEnumeration=$false
Check ((State $bad @('AMD Radeon RX 7900 XTX')).classification -eq 'unknown') 'a device identity that changed between samples is unknown'
Check ((State $null @('x')).classification -eq 'unknown' -and (State ([pscustomobject]@{schema='x'}) @('x')).classification -eq 'unknown') 'a missing or malformed report is unknown'

# ---- detector v2: heap layouts, device kinds and identical-card joins (synthetic reports, no Vulkan) ----
$XTX='AMD Radeon RX 7900 XTX'
function Dev([int]$Index,[string]$Name,[string]$Kind,[string]$Luid,$Heaps){
    [pscustomobject]@{
        Device=[pscustomobject]@{index=$Index;deviceName=$Name;deviceTypeName=$Kind;vendorId=4098;deviceLuid=$Luid;deviceLuidValid=$true}
        Sample=[pscustomobject]@{index=$Index;status='ok';identityMatchesInitialEnumeration=$true;memoryBudgetAdvertised=$true;heaps=$Heaps}
    }
}
function Report($Devs,$Joins=@()){
    [pscustomobject]@{devices=@($Devs | ForEach-Object { $_.Device });budgetSamples=@([pscustomobject]@{sampleIndex=0;vulkan=@($Devs | ForEach-Object { $_.Sample })});joins=@($Joins)}
}
function Layout([double[]]$LocalSizes,[double[]]$HostSizes){ @($LocalSizes | ForEach-Object { Heap $_ $true }) + @($HostSizes | ForEach-Object { Heap $_ $false }) }
function StateA($Report,$Adapters){& $module {param($R,$A) Get-FastLlmVulkanRebarState -Report $R -Adapters $A} $Report $Adapters}
function Adapter([string]$Name,[string]$Luid='',[string]$Pnp=''){ $o=[ordered]@{device='Vulkan0';name=$Name};if($Luid){$o.luid=$Luid};if($Pnp){$o.pnpInstanceId=$Pnp};[pscustomobject]$o }
function One($Layout,[string]$Kind='discrete'){ State (Report @((Dev 0 $XTX $Kind 'aaaaaaaaaaaaaaaa' $Layout))) @($XTX) }
$r=State $xtHost @('AMD Radeon RX 7900 XT')
Check ($r.classification -eq 'rebar-on' -and $r.detectorVersion -ceq 'rebar-heap-layout-v2') 'the detector result carries the detector version'
foreach($apertureMiB in @(224,240,256,512)){
    $r=One (Layout @((24*$GiB),($apertureMiB*$MiB)) @((16*$GiB)))
    Check ($r.classification -eq 'rebar-off') "a $apertureMiB MiB device-local aperture beside one large heap is rebar-off"
}
$r=One (Layout @((24*$GiB),(768*$MiB)) @((16*$GiB)))
Check ($r.classification -eq 'unknown' -and $r.reason -eq 'extra-device-local-heap-of-unrecognized-size') 'an extra 768 MiB device-local heap is unknown with a precise reason'
$r=One (Layout @((24*$GiB),(1*$GiB)) @((16*$GiB)))
Check ($r.classification -eq 'unknown' -and $r.reason -eq 'multiple-large-device-local-heaps') 'an extra 1 GiB device-local heap is unknown (two large heaps)'
$r=One (Layout @((16*$GiB),(8*$GiB)) @((16*$GiB)))
Check ($r.classification -eq 'unknown' -and $r.reason -eq 'multiple-large-device-local-heaps') 'a partial-BAR split into two large device-local heaps is unknown'
$r=One (Layout @((24*$GiB),(256*$MiB),(768*$MiB)) @((16*$GiB)))
Check ($r.classification -eq 'unknown' -and $r.reason -eq 'extra-device-local-heap-of-unrecognized-size') 'an aperture plus an extra 768 MiB device-local heap is unknown'
$r=One (Layout @((24*$GiB),(256*$MiB),(256*$MiB)) @((16*$GiB)))
Check ($r.classification -eq 'unknown' -and $r.reason -eq 'multiple-small-device-local-heaps') 'two small device-local heaps are unknown'
$r=One (Layout @((8*$GiB),(8*$GiB),(8*$GiB)) @((16*$GiB)))
Check ($r.classification -eq 'unknown' -and $r.reason -eq 'multiple-large-device-local-heaps') 'several large device-local heaps are unknown'
$r=One (Layout @((2*$GiB)) @((16*$GiB))) 'integrated'
Check ($r.classification -eq 'unknown' -and $r.reason -eq 'excluded-integrated') 'an integrated GPU with a 2 GiB carve-out is excluded, never classified'
$r=One (Layout @((2*$GiB),(256*$MiB)) @((16*$GiB))) 'integrated'
Check ($r.classification -eq 'unknown' -and $r.reason -eq 'excluded-integrated') 'an integrated GPU is excluded even with a small separate heap'
$d=Dev 0 $XTX 'discrete' 'aaaaaaaaaaaaaaaa' (Layout @((24*$GiB),(256*$MiB)) @((16*$GiB)))
$d.Device.PSObject.Properties.Remove('deviceTypeName');$d.Device | Add-Member -NotePropertyName deviceType -NotePropertyValue 2
Check ((State (Report @($d)) @($XTX)).classification -eq 'rebar-off') 'a numeric Vulkan deviceType of 2 (discrete) is classified'
$d.Device.deviceType=1
Check ((State (Report @($d)) @($XTX)).reason -eq 'excluded-integrated') 'a numeric Vulkan deviceType of 1 (integrated) is excluded'
$d.Device.PSObject.Properties.Remove('deviceType')
Check ((State (Report @($d)) @($XTX)).reason -eq 'device-type-not-discrete') 'a device with no type information is never classified'
$offLayout=Layout @((24*$GiB),(256*$MiB)) @((16*$GiB))
$onLayout=Layout @((24*$GiB)) @((16*$GiB))
$withIgpu=Report @((Dev 0 'AMD Radeon(TM) Graphics' 'integrated' '0c0c0c0c0c0c0c0c' (Layout @((2*$GiB)) @((16*$GiB)))),(Dev 1 $XTX 'discrete' 'aaaaaaaaaaaaaaaa' $offLayout))
Check ((State $withIgpu @($XTX)).classification -eq 'rebar-off' -and (State $withIgpu @('AMD Radeon(TM) Graphics')).reason -eq 'excluded-integrated') 'an unselected integrated GPU is ignored; selecting it is excluded'
$luidA='0a0a0a0a0a0a0a0a';$luidB='0b0b0b0b0b0b0b0b'
$twoOff=Report @((Dev 0 $XTX 'discrete' $luidA $offLayout),(Dev 1 $XTX 'discrete' $luidB $offLayout))
$twoMixed=Report @((Dev 0 $XTX 'discrete' $luidA $offLayout),(Dev 1 $XTX 'discrete' $luidB $onLayout))
$r=StateA $twoOff @((Adapter $XTX),(Adapter $XTX))
Check ($r.classification -eq 'rebar-off' -and $r.deviceCount -eq 2) 'two identical selected cards that both classify rebar-off are rebar-off (every identical card is selected)'
Check ((StateA $twoOff @((Adapter $XTX $luidA),(Adapter $XTX $luidB))).classification -eq 'rebar-off') 'two identical selected cards joined by LUID that both classify rebar-off are rebar-off'
Check ((State $twoOff @($XTX,$XTX)).classification -eq 'rebar-off') 'two identical selected names (no adapter objects) that both classify rebar-off are rebar-off'
$r=StateA $twoOff @((Adapter $XTX))
Check ($r.classification -eq 'unknown' -and $r.reason -eq 'device-not-uniquely-matched') 'a name shared by two probe devices without a LUID match is unknown'
Check ((StateA $twoOff @((Adapter $XTX $luidA))).classification -eq 'rebar-off') 'a LUID selects exactly one of two identical cards'
Check ((StateA $twoOff @((Adapter $XTX 'ffffffffffffffff'))).reason -eq 'luid-not-found') 'a LUID that matches no probe device is unknown (luid-not-found), not a name fallback'
$r=StateA $twoMixed @((Adapter $XTX $luidA),(Adapter $XTX $luidB))
Check ($r.classification -eq 'unknown' -and $r.reason -eq 'selected-devices-disagree') 'two identical selected cards that disagree are unknown (selected-devices-disagree)'
$r=StateA $twoMixed @((Adapter $XTX),(Adapter $XTX))
Check ($r.classification -eq 'unknown' -and $r.reason -eq 'selected-devices-disagree') 'two identical selected cards by name that disagree are unknown (selected-devices-disagree)'
Check ((StateA $twoMixed @((Adapter $XTX $luidA))).classification -eq 'rebar-off' -and (StateA $twoMixed @((Adapter $XTX $luidB))).classification -eq 'rebar-on') 'with identical cards the LUID join picks the right device layout'
$r=StateA $twoMixed @((Adapter $XTX))
Check ($r.classification -eq 'unknown' -and $r.reason -eq 'device-not-uniquely-matched') 'name collision without a LUID match is unknown (never the first device)'
Check ((StateA $twoMixed @((Adapter $XTX $luidA),(Adapter $XTX $luidA))).reason -eq 'device-not-uniquely-matched') 'selecting the same LUID twice is unknown'
$pnpA='PCI\VEN_1002&DEV_744C&SUBSYS_0000&REV_C8\6&2A3B&0&00000008'
$joined=Report @((Dev 0 $XTX 'discrete' $luidA $offLayout),(Dev 1 $XTX 'discrete' $luidB $onLayout)) @([pscustomobject]@{vulkanIndex=1;status='unique';pnpInstanceId=$pnpA})
Check ((StateA $joined @((Adapter $XTX '' $pnpA.ToLowerInvariant()))).classification -eq 'rebar-on') 'a unique PnP join row selects the matching probe device (case-insensitive)'
$ambiguousJoin=Report @((Dev 0 $XTX 'discrete' $luidA $offLayout),(Dev 1 $XTX 'discrete' $luidB $onLayout)) @([pscustomobject]@{vulkanIndex=1;status='ambiguous';pnpInstanceId=$pnpA})
Check ((StateA $ambiguousJoin @((Adapter $XTX '' $pnpA))).reason -eq 'pnp-not-uniquely-joined') 'an ambiguous PnP join row is unknown'

# ---- detector v2 hardening: name matching never falls back, counts must agree, AMD only ----
$r=State $xtxHost @('Some Other Card')
Check ($r.classification -eq 'unknown' -and $r.reason -eq 'device-not-uniquely-matched') 'a NAMED selection that does not match the only probe device is unknown (no sole-device fallback)'
$r=StateA $xtxHost @((Adapter 'AMD Radeon RX 7900 XT'))
Check ($r.classification -eq 'unknown' -and $r.reason -eq 'device-not-uniquely-matched') 'a named adapter object that differs from the only probe device is unknown'
Check ((State $xtxHost @()).classification -eq 'rebar-off' -and (StateA $xtxHost @((Adapter ''))).classification -eq 'rebar-off') 'an unnamed selection still resolves to the sole probe device'
$r=State $xtxHost @($XTX,$XTX)
Check ($r.classification -eq 'unknown' -and $r.reason -eq 'device-not-uniquely-matched') 'two selected cards with one name but a single matching probe device are unknown (exact count match required)'
$r=StateA $xtxHost @((Adapter $XTX),(Adapter $XTX))
Check ($r.classification -eq 'unknown' -and $r.reason -eq 'device-not-uniquely-matched') 'two selected adapter objects against one probe device are unknown'
$r=StateA $twoOff @((Adapter $XTX $luidA),(Adapter $XTX))
Check ($r.classification -eq 'unknown' -and $r.reason -eq 'device-not-uniquely-matched') 'a LUID selection plus a name selection that matches both probe devices is unknown (selected count must equal matched count)'
$r=StateA $twoOff @((Adapter $XTX $luidA),(Adapter $XTX $luidB),(Adapter $XTX))
Check ($r.classification -eq 'unknown' -and $r.reason -eq 'device-not-uniquely-matched') 'more selections than matched probe devices is unknown'
$nv=Report @((Dev 0 'NVIDIA GeForce RTX 4090' 'discrete' 'aaaaaaaaaaaaaaaa' $offLayout))
$nv.devices[0].vendorId=4318
$r=State $nv @('NVIDIA GeForce RTX 4090')
Check ($r.classification -eq 'unknown' -and $r.reason -eq 'device-vendor-not-amd') 'a discrete non-AMD device (vendor 0x10DE) is never classified'
$noVendor=Report @((Dev 0 $XTX 'discrete' 'aaaaaaaaaaaaaaaa' $offLayout))
$noVendor.devices[0].PSObject.Properties.Remove('vendorId')
Check ((State $noVendor @($XTX)).reason -eq 'device-vendor-not-amd') 'a device without a vendor id is never classified'
$noVendor.devices[0] | Add-Member -NotePropertyName vendorId -NotePropertyValue 'junk'
Check ((State $noVendor @($XTX)).reason -eq 'device-vendor-not-amd') 'a non-numeric vendor id is never classified'
$mixedVendors=Report @((Dev 0 $XTX 'discrete' $luidA $offLayout),(Dev 1 'Other Card' 'discrete' $luidB $offLayout))
$mixedVendors.devices[1].vendorId=4318
Check ((State $mixedVendors @($XTX,'Other Card')).reason -eq 'device-vendor-not-amd' -and (State $mixedVendors @($XTX)).classification -eq 'rebar-off') 'every selected device must be AMD; an unselected non-AMD device is ignored'

# ---- policy resolution (probe replaced; Vulkan is never loaded here) ----
function Names($Value){& $module {param($V) ConvertTo-FastLlmVulkanBarMitigationName $V} $Value}
Check ((Names 'off') -eq 'off' -and (Names '') -eq 'off' -and (Names 'on') -eq 'on' -and (Names 'ON') -eq 'on' -and (Names 'auto') -eq 'auto') 'policy names are off, on and auto'
$threw=$false;try{Names 'disable'|Out-Null}catch{$threw=$true}
Check $threw 'the old disable vocabulary is gone'
$threw=$false;try{Names 'bogus'|Out-Null}catch{$threw=$true}
Check $threw 'an unknown policy name is rejected'
Check ((& $module {$script:FastLlmVulkanBarMitigationPolicy}) -eq 'off') 'the module-level policy default is off'
# Hermetic by default: the REAL present-device driver lookup and boot identity are replaced with fixed fixture values so no
# mocked test depends on the host's GPUs, boot time or WMI. The real functions are kept for the labelled unmocked block only.
$realBootFn=& $module {(Get-Command Get-FastLlmVulkanBarBootIdentity).ScriptBlock}
$realPnpFn=& $module {(Get-Command Get-FastLlmVulkanBarPnpRecords).ScriptBlock}
$realSleepFn=& $module {(Get-Command Get-FastLlmVulkanBarSleepDelta).ScriptBlock}
$realSleepSourceFn=& $module {(Get-Command Get-FastLlmVulkanBarSleepDeltaSource).ScriptBlock}
$sleepBox=@{delta=[long]1000;source='interrupt-time'}
& $module {
    param($S)
    $script:policySleep=$S
    function script:Get-FastLlmVulkanBarSleepDelta { return $script:policySleep.delta }
    function script:Get-FastLlmVulkanBarSleepDeltaSource { return $script:policySleep.source }
} $sleepBox
& $module {
    function script:Get-FastLlmVulkanBarBootIdentity { return '2026-10-06T06:00:00.0000000Z' }
    # Resolvable on purpose (same name as the fixture adapter): leakage between tests would show on ANY host.
    function script:Get-FastLlmVulkanBarPnpRecords { return @([pscustomobject]@{InstanceId='PCI\VEN_1002&DEV_744C&SUBSYS_00000000&REV_C8\4&0&0&0';Description='AMD Radeon RX 7900 XTX';DriverVersion='32.0.1'}) }
}
$policyRoots=New-Object 'Collections.Generic.List[string]'
$saved=& $module {(Get-Command Invoke-FastLlmVulkanHeapProbe).ScriptBlock}
$probe=@{calls=0;report=$null;fail=$false;category=$null}
& $module {
    param($P)
    $script:policyProbe=$P
    function script:Invoke-FastLlmVulkanHeapProbe {
        param($TimeoutSeconds,$CollectorPath)
        $script:policyProbe.calls++
        if($script:policyProbe.category){$e=New-Object InvalidOperationException 'synthetic probe failure';$e.Data['FastLlmProbeCategory']=$script:policyProbe.category;throw $e}
        if($script:policyProbe.fail){throw 'synthetic probe failure'}
        return $script:policyProbe.report
    }
} $probe
# Every call gets a FRESH install root so a cache written by one case can never be read by another.
function Resolve([string]$Requested,$Plan){$fresh=Join-Path ([IO.Path]::GetTempPath()) ('fast-llm-vkpolicy-'+[Guid]::NewGuid().ToString('N'));$policyRoots.Add($fresh);& $module {param($P,$R,$I) Resolve-FastLlmVulkanBarMitigation -Plan $P -Requested $R -InstallRoot $I} $Plan $Requested $fresh}
$vulkanPlan=[pscustomobject]@{backend='Vulkan';engineVersion='b10698';selectedAdapters=@([pscustomobject]@{device='Vulkan0';name='AMD Radeon RX 7900 XTX'})}
$rocmPlan=[pscustomobject]@{backend='ROCm';engineVersion='b10698';selectedAdapters=@([pscustomobject]@{device='ROCm0';name='AMD Radeon RX 7900 XTX'})}
try {
    $r=Resolve 'off' ([pscustomobject]@{})
    Check ($r.requested -eq 'off' -and $r.effective -eq 'off' -and $r.reason -eq 'policy-off' -and $r.rebarDetected -eq 'not-probed' -and $probe.calls -eq 0) 'policy off never probes, never reads the plan and records not-probed'
    $probe.report=$xtHost;$probe.calls=0
    $r=Resolve 'on' $vulkanPlan
    Check ($r.requested -eq 'on' -and $r.effective -eq 'on' -and $r.reason -eq 'explicit-on' -and $r.rebarDetected -eq 'not-probed-explicit-on' -and $null -eq $r.probeStatus -and $probe.calls -eq 0) 'on forces the mitigation on the Vulkan lane and never runs the probe (not-probed-explicit-on)'
    $probe.report=$xtxHost
    $r=Resolve 'auto' $vulkanPlan
    Check ($r.requested -eq 'auto' -and $r.effective -eq 'on' -and $r.reason -eq 'rebar-off-detected' -and $r.rebarDetected -eq 'rebar-off' -and $r.probeStatus -eq 'ok' -and $r.probeDurationMs -ge 0 -and $probe.calls -eq 1) 'auto applies the mitigation when the detector says rebar-off and records probe status and duration'
    $probe.report=$xtHost
    $xtPlan=[pscustomobject]@{backend='Vulkan';engineVersion='b10698';selectedAdapters=@([pscustomobject]@{device='Vulkan0';name='AMD Radeon RX 7900 XT'})}
    $r=Resolve 'auto' $xtPlan
    Check ($r.effective -eq 'off' -and $r.reason -eq 'rebar-on-no-mitigation-needed' -and $r.rebarDetected -eq 'rebar-on') 'auto leaves the default alone on a rebar-on host'
    $probe.report=$null
    $r=Resolve 'auto' $vulkanPlan
    Check ($r.effective -eq 'off' -and $r.rebarDetected -eq 'unknown' -and $r.reason -eq 'rebar-unknown-no-mitigation' -and $r.probeStatus -eq 'not-windows') 'auto never applies the mitigation when the detector has no answer (probe returned nothing: not-windows)'
    # Regression: with a resolvable cache key, two policy cases in a row must not leak through a shared root.
    $probe.report=$xtxHost;$probe.calls=0
    $leakA=Resolve 'auto' $vulkanPlan
    $probe.report=$null
    $leakB=Resolve 'auto' $vulkanPlan
    Check ($leakA.effective -eq 'on' -and $leakA.detectionCache -eq 'miss' -and $leakB.detectionCache -eq 'miss' -and $leakB.effective -eq 'off' -and $leakB.rebarDetected -eq 'unknown' -and $probe.calls -eq 2) 'consecutive policy cases with a resolvable cache key do not leak a cached answer into each other (fresh roots)'
    $probe.fail=$true
    $r=Resolve 'auto' $vulkanPlan
    Check ($r.effective -eq 'off' -and $r.rebarDetected -eq 'unknown' -and $r.probeStatus -eq 'other') 'a failing probe is advisory: unknown, no mitigation, no exception, category other'
    $probe.fail=$false
    foreach($category in @('timeout','child-exit','parse','not-windows','other')){
        $probe.category=$category
        $r=Resolve 'auto' $vulkanPlan
        Check ($r.effective -eq 'off' -and $r.rebarDetected -eq 'unknown' -and $r.probeStatus -eq $category) "probe failure category $category is recorded"
    }
    $probe.category=$null
    $noBudget=$xtxHost | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $noBudget.budgetSamples[0].vulkan[0].status='no-memory-budget';$noBudget.budgetSamples[0].vulkan[0] | Add-Member -NotePropertyName memoryBudgetAdvertised -NotePropertyValue $false -Force
    $probe.report=$noBudget
    $r=Resolve 'auto' $vulkanPlan
    Check ($r.effective -eq 'off' -and $r.rebarDetected -eq 'unknown' -and $r.probeStatus -eq 'no-budget-extension') 'a device without VK_EXT_memory_budget is the no-budget-extension category'
    $probe.report=$xtxHost;$before=$probe.calls
    foreach($mode in @('on','auto')){
        $r=Resolve $mode $rocmPlan
        Check ($r.effective -eq 'off' -and $r.reason -eq 'non-vulkan-lane' -and $r.rebarDetected -eq 'not-probed') "$mode never applies to a non-Vulkan lane"
    }
    $r=Resolve 'on' ([pscustomobject]@{})
    Check ($r.effective -eq 'off' -and $r.reason -eq 'non-vulkan-lane') 'a plan without a backend is treated as non-Vulkan'
    Check ($r.detectorVersion -ceq 'rebar-heap-layout-v2') 'the policy record carries the detector version'
    Check ($probe.calls -eq $before) 'non-Vulkan lanes never run the heap probe'
    # doctor view: default is configured policy only
    $probe.report=$xtxHost;$before=$probe.calls
    $d=Get-FastLlmVulkanMemoryDiagnostic -AdapterNames @('AMD Radeon RX 7900 XTX') -Backend 'Vulkan'
    Check ($d.rebarDetected -eq 'not-probed' -and $d.configuredPolicy -eq 'off' -and $null -eq $d.guidance -and $probe.calls -eq $before -and $d.advisoryOnly) 'default doctor reports the configured policy and not-probed: no probe, no BIOS text'
    $d=Get-FastLlmVulkanMemoryDiagnostic -AdapterNames @('AMD Radeon RX 7900 XTX') -Backend 'Vulkan' -Probe
    $expectedGuidance='Resizable BAR appears to be disabled for AMD Radeon RX 7900 XTX, based on the Vulkan memory layout. FastLLM can work around this automatically (-VulkanBarMitigation auto); enabling it in BIOS/UEFI may still help. FastLLM changes no BIOS or driver settings.'
    Check ($d.rebarDetected -eq 'rebar-off' -and $d.guidance -ceq $expectedGuidance -and $d.configuredPolicy -eq 'off' -and $d.probeStatus -eq 'ok' -and $probe.calls -eq $before + 1) 'opt-in doctor surfaces rebar-off with the plain-language guidance naming the card'
    $probe.report=$xtHost
    $d=Get-FastLlmVulkanMemoryDiagnostic -AdapterNames @('AMD Radeon RX 7900 XT') -Backend 'Vulkan' -Probe
    Check ($d.rebarDetected -eq 'rebar-on' -and $null -eq $d.guidance) 'opt-in doctor gives no guidance on a rebar-on host'
    $before=$probe.calls
    foreach($case in @(@('ROCm',@('AMD Radeon RX 7900 XTX')),@('',@()),@('Vulkan',@()),@('Vulkan',@('')))){
        $d=Get-FastLlmVulkanMemoryDiagnostic -AdapterNames $case[1] -Backend $case[0] -Probe
        Check ($d.rebarDetected -eq 'no-vulkan-plan' -and $d.rebarDetectionReason -eq 'no-vulkan-plan' -and $null -eq $d.guidance) "opt-in doctor without a Vulkan plan ($($case[0]) / $(@($case[1]).Count) adapters) reports no-vulkan-plan"
    }
    Check ($probe.calls -eq $before) 'opt-in doctor never probes without a Vulkan plan (no single-device fallback)'
    # ---- identical cards through the policy, the engine gate and the per-boot cache (probe and boot identity replaced) ----
    $twoXtxPlan=[pscustomobject]@{backend='Vulkan';engineVersion='b10698';selectedAdapters=@((Adapter $XTX),(Adapter $XTX))}
    $probe.report=$twoOff;$probe.calls=0
    $r=Resolve 'auto' $twoXtxPlan
    Check ($r.effective -eq 'on' -and $r.reason -eq 'rebar-off-detected' -and $r.rebarDetected -eq 'rebar-off') 'two identical selected cards that both classify rebar-off: auto applies the mitigation'
    $probe.report=$twoMixed
    $r=Resolve 'auto' $twoXtxPlan
    Check ($r.effective -eq 'off' -and $r.rebarDetected -eq 'unknown' -and $r.rebarDetectionReason -eq 'selected-devices-disagree' -and $r.reason -eq 'rebar-unknown-no-mitigation') 'two identical selected cards that disagree: auto applies nothing (selected-devices-disagree)'
    $r=Resolve 'auto' $vulkanPlan
    Check ($r.effective -eq 'off' -and $r.rebarDetected -eq 'unknown' -and $r.rebarDetectionReason -eq 'device-not-uniquely-matched') 'one selected card whose name is shared by two probe devices: auto applies nothing'
    $probe.report=$xtxHost;$before=$probe.calls
    $mixedEnginePlans=@()
    foreach($engine in @('b10829','test','B10698','')){$mixedEnginePlans+=[pscustomobject]@{backend='Vulkan';engineVersion=$engine;selectedAdapters=@((Adapter $XTX))}}
    $mixedEnginePlans+=[pscustomobject]@{backend='Vulkan';selectedAdapters=@((Adapter $XTX))}
    foreach($gatePlan in $mixedEnginePlans){
        foreach($mode in @('on','auto')){
            $r=Resolve $mode $gatePlan
            Check ($r.effective -eq 'off' -and $r.reason -eq 'engine-not-verified' -and $r.rebarDetected -eq 'not-probed') "$mode on an engine that is not b10698 stays off (engine-not-verified)"
        }
    }
    Check ($probe.calls -eq $before) 'an unverified engine never runs the heap probe'
    $r=Resolve 'off' $mixedEnginePlans[0]
    Check ($r.effective -eq 'off' -and $r.reason -eq 'policy-off') 'policy off is unaffected by the engine gate'
    $r=Resolve 'on' $vulkanPlan
    Check ($r.effective -eq 'on' -and $r.reason -eq 'explicit-on') 'the verified engine b10698 still allows an explicit on'
    $cacheRoot=Join-Path ([IO.Path]::GetTempPath()) ('fast-llm-vkcache-'+[Guid]::NewGuid().ToString('N'))
    $coldRoot=Join-Path ([IO.Path]::GetTempPath()) ('fast-llm-vkcold-'+[Guid]::NewGuid().ToString('N'))
    $corruptRoot=Join-Path ([IO.Path]::GetTempPath()) ('fast-llm-vkcorrupt-'+[Guid]::NewGuid().ToString('N'))
    $cachePath=Join-Path (Join-Path $cacheRoot 'state') 'vulkan-rebar-detection-cache.json'
    $bootBox=@{boot='2026-10-06T06:00:00.0000000Z'};$unknownRoot=$null
    $savedBoot=& $module {(Get-Command Get-FastLlmVulkanBarBootIdentity).ScriptBlock}
    $savedSleep=& $module {(Get-Command Get-FastLlmVulkanBarSleepDelta).ScriptBlock}
    $savedSleepSource=& $module {(Get-Command Get-FastLlmVulkanBarSleepDeltaSource).ScriptBlock}
    & $module {
        param($B)
        $script:policyBoot=$B
        function script:Get-FastLlmVulkanBarBootIdentity { return $script:policyBoot.boot }
    } $bootBox
    # The cache key reads present-device driver versions through Get-FastLlmVulkanBarPnpRecords (never the plan or WMI).
    $pnpBox=@{}
    $savedPnp=& $module {(Get-Command Get-FastLlmVulkanBarPnpRecords).ScriptBlock}
    $instanceBox=@{id='PCI\VEN_1002&DEV_744C&SUBSYS_00000000&REV_C8\4&0&0&0'}
    & $module {
        param($B,$I)
        $script:policyPnp=$B
        $script:policyPnpInstance=$I
        function script:Get-FastLlmVulkanBarPnpRecords { return @($script:policyPnp.Keys | ForEach-Object { [pscustomobject]@{InstanceId=[string]$script:policyPnpInstance.id;Description=[string]$_;DriverVersion=[string]$script:policyPnp[$_]} }) }
    } $pnpBox $instanceBox
    function CachePlan([string]$Driver='32.0.1',[string]$Name=$XTX){$pnpBox[$Name]=$Driver;[pscustomobject]@{backend='Vulkan';engineVersion='b10698';selectedAdapters=@([pscustomobject]@{device='Vulkan0';name=$Name;driverVersion=$null})}}
    function ResolveAt([string]$Requested,$Plan,[string]$Root){& $module {param($P,$R,$I) Resolve-FastLlmVulkanBarMitigation -Plan $P -Requested $R -InstallRoot $I} $Plan $Requested $Root}
    try {
        $probe.report=$xtxHost;$probe.calls=0
        $r=ResolveAt 'auto' (CachePlan) $cacheRoot
        Check ($r.detectionCache -eq 'miss' -and $r.effective -eq 'on' -and $r.probeStatus -eq 'ok' -and $r.probeDurationMs -ge 0 -and $probe.calls -eq 1 -and (Test-Path -LiteralPath $cachePath -PathType Leaf)) 'cache miss: a live auto start probes once, records the latency and writes the per-boot cache in the state folder'
        $r=ResolveAt 'auto' (CachePlan) $cacheRoot
        Check ($r.detectionCache -eq 'hit' -and $probe.calls -eq 1 -and $r.probeStatus -eq 'cached' -and $r.probeDurationMs -eq 0 -and $null -ne $r.cachedProbeDurationMs -and $r.effective -eq 'on' -and $r.rebarDetected -eq 'rebar-off') 'cache hit: the same boot, adapter and driver reuse the classification without probing'
        $bootBox.boot='2026-10-07T06:00:00.0000000Z'
        $r=ResolveAt 'auto' (CachePlan) $cacheRoot
        Check ($r.detectionCache -eq 'invalidated' -and $probe.calls -eq 2 -and $r.effective -eq 'on') 'a new boot time invalidates the cache and probes again'
        $r=ResolveAt 'auto' (CachePlan) $cacheRoot
        Check ($r.detectionCache -eq 'hit' -and $probe.calls -eq 2) 'the cache is valid again for the new boot'
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        Check ($r.detectionCache -eq 'invalidated' -and $probe.calls -eq 3) 'a new driver version invalidates the cache'
        $probe.report=$xtHost
        $r=ResolveAt 'auto' (CachePlan '32.0.2' 'AMD Radeon RX 7900 XT') $cacheRoot
        Check ($r.detectionCache -eq 'invalidated' -and $probe.calls -eq 4 -and $r.rebarDetected -eq 'rebar-on' -and $r.effective -eq 'off') 'a different adapter invalidates the cache and the new answer replaces it'
        $r=ResolveAt 'auto' (CachePlan '32.0.2' 'AMD Radeon RX 7900 XT') $cacheRoot
        Check ($r.detectionCache -eq 'hit' -and $probe.calls -eq 4 -and $r.rebarDetected -eq 'rebar-on' -and $r.effective -eq 'off') 'a cached rebar-on answer is reused and applies no mitigation'
        $probe.report=$xtxHost
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        Check ($r.detectionCache -eq 'invalidated' -and $probe.calls -eq 5 -and $r.rebarDetected -eq 'rebar-off') 'switching back to the first adapter invalidates the cache (only one entry is kept)'
        Set-Content -LiteralPath $cachePath -Value 'not json' -Encoding ASCII
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        Check ($r.detectionCache -eq 'miss' -and $probe.calls -eq 6 -and $r.rebarDetected -eq 'rebar-off') 'an unreadable cache file is a miss and is replaced'
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        Check ($r.detectionCache -eq 'hit' -and $probe.calls -eq 6) 'the replaced cache file is valid'
        $bootBox.boot=$null
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        $r2=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        Check ($r.detectionCache -eq 'unavailable' -and $r2.detectionCache -eq 'unavailable' -and $probe.calls -eq 8 -and $r.effective -eq 'on') 'without a boot identity nothing is cached: every start probes'
        $bootBox.boot='2026-10-07T06:00:00.0000000Z'
        $r=ResolveAt 'auto' (CachePlan '') $cacheRoot
        Check ($r.detectionCache -eq 'unavailable' -and $probe.calls -eq 9) 'an adapter without a driver version is never cached'
        $r=ResolveAt 'auto' $vulkanPlan $cacheRoot
        Check ($r.detectionCache -eq 'unavailable' -and $probe.calls -eq 10) 'an adapter record without a driver version (the default plan fixture) is never cached'
        # ---- schema 4: native boot (stored, 60 s tolerance, not keyed), present-device driver version, PnP instance, sleep delta ----
        $bootBox.boot='2026-10-07T06:00:00.0000000Z'
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        Check ($r.detectionCache -eq 'hit' -and $r.bootTimeSource -ceq 'native' -and $r.driverVersionSource -ceq 'setupapi-present') 'the policy record names the native boot and present-device driver sources'
        $written=[IO.File]::ReadAllText($cachePath)|ConvertFrom-Json
        Check ($written.schemaVersion -eq 5 -and $written.sleepDeltaSource -ceq 'interrupt-time' -and $r.sleepDeltaSource -ceq 'interrupt-time' -and $written.sleepDeltaMs -eq 1000 -and $written.sleepDeltaMs -is [int] -and $written.bootTimeSource -ceq 'native' -and $written.driverVersionSource -ceq 'setupapi-present' -and $written.bootUtc -and $written.key -notmatch '2026') 'the entry is schema 5, stores bootUtc, sleepDeltaMs, sleepDeltaSource and sources, and the key does not contain the boot time'
        $bootBox.boot='2026-10-07T06:00:45.0000000Z'
        $before=$probe.calls
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        Check ($r.detectionCache -eq 'hit' -and $probe.calls -eq $before) 'a boot instant within 60 s of the stored one is a hit (time-sync tolerant)'
        $bootBox.boot='2026-10-07T06:01:30.0000000Z'
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        Check ($r.detectionCache -eq 'invalidated' -and $probe.calls -eq ($before+1)) 'a boot instant beyond 60 s invalidates the entry and re-probes'
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        Check ($r.detectionCache -eq 'hit') 'the replaced entry carries the new boot instant'
        # Exact 60 s boundary and negative differences (stored entry boot is now 06:01:30.0000000Z).
        $before=$probe.calls
        $bootBox.boot='2026-10-07T06:02:30.0000000Z'
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        Check ($r.detectionCache -eq 'hit' -and $probe.calls -eq $before) 'a current boot exactly +60 s after the stored one is still a hit'
        $bootBox.boot='2026-10-07T06:02:30.0000001Z'
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        Check ($r.detectionCache -eq 'invalidated' -and $probe.calls -eq ($before+1)) 'a current boot one tick beyond +60 s invalidates the entry (stored boot is now 06:02:30.0000001)'
        $bootBox.boot='2026-10-07T06:01:30.0000001Z'
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        Check ($r.detectionCache -eq 'hit' -and $probe.calls -eq ($before+1)) 'a NEGATIVE difference of exactly -60 s is still a hit'
        $bootBox.boot='2026-10-07T06:01:30.0000000Z'
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        Check ($r.detectionCache -eq 'invalidated' -and $probe.calls -eq ($before+2)) 'a negative difference one tick beyond -60 s invalidates the entry'
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        Check ($r.detectionCache -eq 'hit' -and $probe.calls -eq ($before+2)) 'the entry replaced after the negative-difference invalidation is valid'
        # Sleep accounting: the stored sleepDeltaMs may be outgrown by at most 5000 ms and never undercut.
        $sleepBox.delta=[long]1000
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        Check ($r.detectionCache -eq 'hit' -and $probe.calls -eq ($before+2)) 'a stable sleep delta (unchanged) is a hit'
        $sleepBox.delta=[long]6000
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        Check ($r.detectionCache -eq 'hit' -and $probe.calls -eq ($before+2)) 'a sleep delta that grew by exactly 5000 ms is still a hit'
        $sleepBox.delta=[long]6001
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        Check ($r.detectionCache -eq 'invalidated' -and $probe.calls -eq ($before+3) -and $r.effective -eq 'on') 'a sleep delta that grew by more than 5000 ms (sleep, hibernate or Fast Startup) invalidates the entry and re-probes'
        $stored=[IO.File]::ReadAllText($cachePath)|ConvertFrom-Json
        Check ($stored.sleepDeltaMs -eq 6001) 'the re-probed entry stores the new sleep delta'
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        Check ($r.detectionCache -eq 'hit' -and $probe.calls -eq ($before+3)) 'the new sleep delta is stable and hits'
        $sleepBox.delta=[long]6000
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        Check ($r.detectionCache -eq 'hit' -and $probe.calls -eq ($before+3)) 'a small drop of the sleep delta (1 ms, read jitter) still hits'
        $sleepBox.delta=[long]5951
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        Check ($r.detectionCache -eq 'hit' -and $probe.calls -eq ($before+3)) 'a drop of exactly 50 ms is still read as no sleep (hit)'
        $sleepBox.delta=[long]5950
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        Check ($r.detectionCache -eq 'invalidated' -and $probe.calls -eq ($before+4)) 'a sleep delta more than 50 ms below the stored one (it can only grow within one boot) invalidates the entry'
        $sleepBox.delta=[long]7200000
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        Check ($r.detectionCache -eq 'invalidated' -and $probe.calls -eq ($before+5)) 'a large sleep (two hours) invalidates the entry'
        $sleepBox.delta=$null
        $beforeNoSleep=$probe.calls
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        Check ($r.detectionCache -eq 'unavailable' -and $r.bootTimeSource -eq $null -and $probe.calls -eq ($beforeNoSleep+1)) 'without a sleep delta nothing is cached or reused (unavailable, probes)'
        $sleepBox.delta=[long]7200000
        $bootBox.boot='2026-10-07T06:01:30.0000000Z'
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        Check ($r.detectionCache -eq 'hit') 'the cache is usable again once the sleep delta is available'
        # PnP InstanceId is part of the key: the same model and driver on another physical device is a different key.
        $keyBlockA={param($A) Get-FastLlmVulkanBarCacheKey -Adapters $A}
        $pnpBox[$XTX]='32.0.2'
        $keyA=& $module $keyBlockA @([pscustomobject]@{name=$XTX})
        $instanceBox.id='PCI\VEN_1002&DEV_744C&SUBSYS_00000000&REV_C8\4&AAAA&0&0'
        $keyB=& $module $keyBlockA @([pscustomobject]@{name=$XTX})
        $instanceBox.id='PCI\VEN_1002&DEV_744C&SUBSYS_00000000&REV_C8\4&0&0&0'
        $keyA2=& $module $keyBlockA @([pscustomobject]@{name=$XTX})
        Check ($keyA -and $keyB -and $keyA -cne $keyB -and $keyA -ceq $keyA2 -and $keyA.Contains('pci\ven_1002&dev_744c&subsys_00000000&rev_c8\4&0&0&0') -and $keyB.Contains('4&aaaa&0&0')) 'the matched present-device PnP InstanceId (lower case) is part of the key'
        $instanceBox.id='PCI\VEN_1002&DEV_744C&SUBSYS_00000000&REV_C8\4&BBBB&0&0'
        $before=$probe.calls
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        Check ($r.detectionCache -eq 'invalidated' -and $probe.calls -eq ($before+1)) 'a different PnP instance for the same model and driver invalidates the entry and re-probes'
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        Check ($r.detectionCache -eq 'hit' -and $probe.calls -eq ($before+1)) 'the entry for the new instance is valid'
        $instanceBox.id='PCI\VEN_1002&DEV_744C&SUBSYS_00000000&REV_C8\4&0&0&0'
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        Check ($r.detectionCache -eq 'invalidated' -and $probe.calls -eq ($before+2)) 'switching back to the first instance invalidates the entry again (one entry is kept)'
        # Two matching present records (two functions of one device or two instances): all matched ids are keyed, sorted.
        $dev=& $module { param($R) Get-FastLlmVulkanBarPresentDevice -AdapterName 'AMD Radeon RX 7900 XTX' -Records $R } @(
            [pscustomobject]@{InstanceId='PCI\VEN_1002&DEV_744C\4&ZZ';Description=$XTX;DriverVersion='32.0.2'},
            [pscustomobject]@{InstanceId='PCI\VEN_1002&DEV_744C\4&AA';Description=$XTX;DriverVersion='32.0.2'},
            [pscustomobject]@{InstanceId='PCI\VEN_10DE&DEV_2684\4&NV';Description=$XTX;DriverVersion='99'})
        Check ($dev.driverVersion -ceq '32.0.2' -and (@($dev.instanceIds) -join ',') -ceq 'pci\ven_1002&dev_744c\4&aa,pci\ven_1002&dev_744c\4&zz') 'the present device lists every matched AMD instance id lower case and sorted, ignoring non-AMD records'
        Check ($null -eq (& $module { param($R) Get-FastLlmVulkanBarPresentDevice -AdapterName 'AMD Radeon RX 7900 XTX' -Records $R } @())) 'no matching present device gives null'
        # Strict validation of the new sleepDeltaMs field.
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        foreach($badSleep in @('5','abc',-1,1.5,99999999999999999999,@(1,2))){
            $m=[IO.File]::ReadAllText($cachePath)|ConvertFrom-Json;$m.sleepDeltaMs=$badSleep
            [IO.File]::WriteAllText($cachePath,($m|ConvertTo-Json -Depth 4))
            $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
            Check ($r.detectionCache -eq 'invalidated') ('an invalid sleepDeltaMs value (' + (ConvertTo-Json $badSleep -Compress) + ') invalidates the entry')
        }
        $m=[IO.File]::ReadAllText($cachePath)|ConvertFrom-Json;$m.PSObject.Properties.Remove('sleepDeltaMs')
        [IO.File]::WriteAllText($cachePath,($m|ConvertTo-Json -Depth 4))
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        Check ($r.detectionCache -eq 'invalidated' -and (([IO.File]::ReadAllText($cachePath)|ConvertFrom-Json).sleepDeltaMs -eq 7200000)) 'an entry without sleepDeltaMs is invalidated and replaced'
        # Both sleep-delta paths (mocked source): each is recorded in the entry and the status record, any other source is unusable.
        foreach($pathName in @('interrupt-time','tick-fallback')){
            $sleepBox.source=$pathName
            Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
            $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
            $w=[IO.File]::ReadAllText($cachePath)|ConvertFrom-Json
            Check ($r.sleepDeltaSource -ceq $pathName -and $w.sleepDeltaSource -ceq $pathName) "the $pathName path is recorded in the status record and the cache entry"
            $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
            Check ($r.detectionCache -eq 'hit' -and $r.sleepDeltaSource -ceq $pathName) "the $pathName entry is a cache hit"
        }
        # N1: an entry written by the other sleep path is a MISS (never reused, never invalidated), and is replaced by the current path's entry.
        $sleepBox.source='interrupt-time'
        Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        $sourceCalls=$probe.calls
        $sleepBox.source='tick-fallback'
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        Check ($r.detectionCache -eq 'miss' -and $probe.calls -eq ($sourceCalls+1) -and $r.sleepDeltaSource -ceq 'tick-fallback' -and (([IO.File]::ReadAllText($cachePath)|ConvertFrom-Json).sleepDeltaSource -ceq 'tick-fallback')) 'an entry written by the interrupt-time path is a miss for the tick-fallback path, is re-probed and replaced'
        $sleepBox.source='interrupt-time'
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        Check ($r.detectionCache -eq 'miss' -and $probe.calls -eq ($sourceCalls+2) -and (([IO.File]::ReadAllText($cachePath)|ConvertFrom-Json).sleepDeltaSource -ceq 'interrupt-time')) 'and back again: the tick-fallback entry is a miss for the interrupt-time path'
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        Check ($r.detectionCache -eq 'hit' -and $probe.calls -eq ($sourceCalls+2)) 'the same source is still a hit'
        foreach($badSource in @($null,'','wmi','kernel32')){
            $sleepBox.source=$badSource
            $before=$probe.calls
            $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
            Check ($r.detectionCache -eq 'unavailable' -and $r.sleepDeltaSource -eq $null -and $probe.calls -eq ($before+1)) ('an unknown sleep-delta source (' + (ConvertTo-Json $badSource -Compress) + ') caches nothing and reuses nothing')
        }
        $sleepBox.source='interrupt-time'
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        # bootUtc must be the exact round-trip format (ParseExact), not whatever the lenient parser accepts.
        $m=[IO.File]::ReadAllText($cachePath)|ConvertFrom-Json;$m.bootUtc='10/7/2026 6:01:30 AM'
        [IO.File]::WriteAllText($cachePath,($m|ConvertTo-Json -Depth 4))
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        Check ($r.detectionCache -eq 'invalidated') 'a lenient non-round-trip bootUtc text is invalidated'
        foreach($oldSchema in @(1,2,3,4)){
            $m=[IO.File]::ReadAllText($cachePath)|ConvertFrom-Json;$m.schemaVersion=$oldSchema
            [IO.File]::WriteAllText($cachePath,($m|ConvertTo-Json -Depth 4))
            $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
            Check ($r.detectionCache -eq 'invalidated' -and (([IO.File]::ReadAllText($cachePath)|ConvertFrom-Json).schemaVersion -eq 5)) ("a schema $oldSchema cache file is invalidated and replaced with schema 5")
        }
        foreach($bad in @(@{f='sleepDeltaSource';v='wmi'},@{f='sleepDeltaSource';v=5},@{f='sleepDeltaSource';v='Interrupt-Time'},@{f='bootTimeSource';v='wmi'},@{f='driverVersionSource';v='registry'},@{f='bootUtc';v='not-a-date'},@{f='bootUtc';v=5})){
            $m=[IO.File]::ReadAllText($cachePath)|ConvertFrom-Json;$m.($bad.f)=$bad.v
            [IO.File]::WriteAllText($cachePath,($m|ConvertTo-Json -Depth 4))
            $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
            Check ($r.detectionCache -eq 'invalidated') ('an invalid ' + $bad.f + ' value invalidates the entry')
        }
        $m=[IO.File]::ReadAllText($cachePath)|ConvertFrom-Json;$m.PSObject.Properties.Remove('bootUtc')
        [IO.File]::WriteAllText($cachePath,($m|ConvertTo-Json -Depth 4))
        $r=ResolveAt 'auto' (CachePlan '32.0.2') $cacheRoot
        Check ($r.detectionCache -eq 'invalidated') 'an entry without bootUtc is invalidated'
        # Present-device driver version resolution (pure).
        $pnp=[scriptblock]{param($N,$R) Get-FastLlmVulkanBarPresentDriverVersion -AdapterName $N -Records $R}
        $recA=[pscustomobject]@{InstanceId='PCI\VEN_1002&DEV_744C&SUBSYS_0&REV_C8\4&0';Description='AMD Radeon RX 7900 XTX';DriverVersion='32.0.1'}
        $recNv=[pscustomobject]@{InstanceId='PCI\VEN_10DE&DEV_2684&SUBSYS_0&REV_A1\4&0';Description='AMD Radeon RX 7900 XTX';DriverVersion='99.9'}
        $recOther=[pscustomobject]@{InstanceId='PCI\VEN_1002&DEV_744C&SUBSYS_0&REV_C8\4&1';Description='AMD Radeon RX 7900 XTX';DriverVersion='32.0.2'}
        Check ((& $module $pnp 'amd radeon rx 7900 xtx' @($recA)) -ceq '32.0.1') 'present-device resolution matches the whole adapter name case-insensitively'
        Check ($null -eq (& $module $pnp 'AMD Radeon RX 7900 XT' @($recA)) -and $null -eq (& $module $pnp 'Radeon RX 7900 XTX' @($recA)) -and $null -eq (& $module $pnp 'AMD Radeon RX 7900 XTX (x)' @($recA))) 'present-device resolution never matches loosely (no substring either way)'
        Check ($null -eq (& $module $pnp $XTX @($recNv))) 'a non-AMD PCI vendor record is ignored'
        Check ((& $module $pnp $XTX @($recA,$recNv)) -ceq '32.0.1') 'a non-AMD record does not disturb an AMD match'
        Check ($null -eq (& $module $pnp $XTX @($recA,$recOther))) 'matching records that disagree on the driver version give null'
        Check ((& $module $pnp $XTX @($recA,[pscustomobject]@{InstanceId='PCI\VEN_1002&DEV_744C&SUBSYS_0&REV_C8\4&2';Description=$XTX;DriverVersion='32.0.1'})) -ceq '32.0.1') 'matching records that agree resolve'
        Check ($null -eq (& $module $pnp $XTX @([pscustomobject]@{InstanceId='PCI\VEN_1002&DEV_744C\4&0';Description=$XTX;DriverVersion=''})) -and $null -eq (& $module $pnp $XTX @())) 'an empty driver version or no record gives null'
        # The key never depends on WMI or the plan's driver version.
        $keyBlock={param($A) Get-FastLlmVulkanBarCacheKey -Adapters $A}
        $keyAdapters=@([pscustomobject]@{name=$XTX;driverVersion='1.1.1'})
        $pnpBox[$XTX]='32.0.2'
        & $module { function script:Get-CimInstance { [pscustomobject]@{LastBootUpTime=[datetime]'2026-10-06T06:00:00';Name='AMD Radeon RX 7900 XTX';DriverVersion='7.7.7'} } }
        $keyWmiOk=& $module $keyBlock $keyAdapters
        & $module { function script:Get-CimInstance { throw 'Access denied (mock)' } }
        $keyWmiDenied=& $module $keyBlock $keyAdapters
        $keyNoPlanDriver=& $module $keyBlock @([pscustomobject]@{name=$XTX;driverVersion=$null})
        & $module { Remove-Item -Path Function:script:Get-CimInstance -ErrorAction SilentlyContinue }
        Check ($keyWmiOk -and $keyWmiOk -ceq $keyWmiDenied -and $keyWmiOk -ceq $keyNoPlanDriver -and $keyWmiOk -match '32\.0\.2') 'the key is identical with WMI available, WMI denied and any plan driverVersion (it uses the present-device driver version only)'
        # Default path: the plan adapter driverVersion stays null when WMI is denied (no registry/SetupAPI value is written to it).
        if($env:OS -ceq 'Windows_NT'){
            & $module { function script:Get-CimInstance { throw 'Access denied (mock)' } }
            try {
                $deniedAdapters=@([pscustomobject]@{device='Vulkan0';name=$XTX;driverVersion=$null})
                $filled=& $module { param($A) Add-FastLlmDriverVersions -Adapters $A } $deniedAdapters
                Check ($null -eq $filled[0].driverVersion) 'with WMI denied the plan adapter driverVersion stays null (default path unchanged)'
            } finally { & $module { Remove-Item -Path Function:script:Get-CimInstance -ErrorAction SilentlyContinue } }
        }
        # A cached answer is never trusted across a changed probe report: it is only valid for its exact key.
        $probe.report=$null;$unknownRoot=Join-Path ([IO.Path]::GetTempPath()) ('fast-llm-vkunknown-'+[Guid]::NewGuid().ToString('N'))
        $r=ResolveAt 'auto' (CachePlan) $unknownRoot
        Check ($r.detectionCache -eq 'miss' -and $r.rebarDetected -eq 'unknown' -and -not (Test-Path -LiteralPath $unknownRoot)) 'an unknown or failed detection is never cached and creates no state folder'
        # No cache, no state folder and no probe unless a live auto start asks for one.
        $probe.report=$xtxHost;$before=$probe.calls
        $r=ResolveAt 'off' (CachePlan) $coldRoot
        $r2=ResolveAt 'on' (CachePlan) $coldRoot
        $r3=ResolveAt 'auto' ([pscustomobject]@{backend='ROCm';engineVersion='b10698';selectedAdapters=@()}) $coldRoot
        $r4=ResolveAt 'auto' ([pscustomobject]@{backend='Vulkan';engineVersion='b10829';selectedAdapters=@()}) $coldRoot
        Check ($probe.calls -eq $before -and -not (Test-Path -LiteralPath $coldRoot) -and $r.detectionCache -eq 'not-used' -and $r2.detectionCache -eq 'not-used' -and $r3.detectionCache -eq 'not-used' -and $r4.detectionCache -eq 'not-used') 'off, on, a non-Vulkan lane and an unverified engine never probe, never read the cache and never create the state folder'
        $d=Get-FastLlmVulkanMemoryDiagnostic -AdapterNames @($XTX) -Backend 'Vulkan' -Probe -Adapters @((CachePlan).selectedAdapters)
        $d2=Get-FastLlmVulkanMemoryDiagnostic -AdapterNames @($XTX) -Backend 'Vulkan'
        Check ($d.detectorVersion -ceq 'rebar-heap-layout-v2' -and $d.rebarDetected -eq 'rebar-off' -and $d2.rebarDetected -eq 'not-probed' -and -not (Test-Path -LiteralPath $coldRoot)) 'doctor reports the detector version; its opt-in probe is never cached and creates nothing'
        # ---- M2: a corrupted detector cache can never fail a start; every field is validated, never cast ----
        $corruptPath=Join-Path (Join-Path $corruptRoot 'state') 'vulkan-rebar-detection-cache.json'
        $probe.report=$xtxHost;$probe.calls=0
        $r=ResolveAt 'auto' (CachePlan) $corruptRoot
        Check ($r.detectionCache -eq 'miss' -and (Test-Path -LiteralPath $corruptPath -PathType Leaf)) 'corruption tests start from a valid written cache'
        $validText=[IO.File]::ReadAllText($corruptPath)
        $valid=$validText | ConvertFrom-Json
        $shapes=[ordered]@{
            'string probeDurationMs'=@{text=($validText -replace '"probeDurationMs":\s*\d+','"probeDurationMs": "abc"')}
            'numeric-string probeDurationMs'=@{text=($validText -replace '"probeDurationMs":\s*\d+','"probeDurationMs": "5"')}
            'overflowing probeDurationMs'=@{text=($validText -replace '"probeDurationMs":\s*\d+','"probeDurationMs": 99999999999999999999999')}
            'negative probeDurationMs'=@{text=($validText -replace '"probeDurationMs":\s*\d+','"probeDurationMs": -5')}
            'fractional probeDurationMs'=@{text=($validText -replace '"probeDurationMs":\s*\d+','"probeDurationMs": 1.5')}
            'array probeDurationMs'=@{text=($validText -replace '"probeDurationMs":\s*\d+','"probeDurationMs": [1,2]')}
            'null probeDurationMs'=@{text=($validText -replace '"probeDurationMs":\s*\d+','"probeDurationMs": null')}
            'object probeDurationMs'=@{text=($validText -replace '"probeDurationMs":\s*\d+','"probeDurationMs": {"a":1}')}
            'missing probeDurationMs'=@{text=($validText -replace ',?\s*"probeDurationMs":\s*\d+','')}
            'missing reason'=@{mutate={param($o) $o.PSObject.Properties.Remove('reason')}}
            'missing recordedAtUtc'=@{mutate={param($o) $o.PSObject.Properties.Remove('recordedAtUtc')}}
            'array reason'=@{mutate={param($o) $o.reason=@('a','b')}}
            'numeric reason'=@{mutate={param($o) $o.reason=7}}
            'bad-character reason'=@{mutate={param($o) $o.reason='Bad Reason!'}}
            'oversized reason'=@{mutate={param($o) $o.reason=('a'*200)}}
            'array classification'=@{mutate={param($o) $o.classification=@('rebar-off')}}
            'unknown classification'=@{mutate={param($o) $o.classification='unknown'}}
            'string schemaVersion'=@{mutate={param($o) $o.schemaVersion='1'}}
            'array key'=@{mutate={param($o) $o.key=@($o.key)}}
            'garbage recordedAtUtc'=@{mutate={param($o) $o.recordedAtUtc='not a date'}}
            'array recordedAtUtc'=@{mutate={param($o) $o.recordedAtUtc=@('2026-10-07T06:00:00Z')}}
            'top-level array'=@{text='[1,2,3]'}
            'top-level string'=@{text='"hello"'}
            'top-level number'=@{text='42'}
            'oversized file (valid fields plus padding)'=@{mutate={param($o) $o | Add-Member -NotePropertyName padding -NotePropertyValue ('x'*20000)}}
        }
        foreach($name in @($shapes.Keys)){
            $shape=$shapes[$name]
            if($shape.ContainsKey('text')){[IO.File]::WriteAllText($corruptPath,[string]$shape.text)}
            else{$copy=$validText | ConvertFrom-Json;& $shape.mutate $copy;[IO.File]::WriteAllText($corruptPath,($copy | ConvertTo-Json -Depth 6))}
            $before=$probe.calls
            $threw=$false;$r=$null
            try{$r=ResolveAt 'auto' (CachePlan) $corruptRoot}catch{$threw=$true}
            Check (-not $threw -and $r.detectionCache -eq 'invalidated' -and $probe.calls -eq $before+1 -and $r.effective -eq 'on' -and $r.reason -eq 'rebar-off-detected' -and $r.probeStatus -eq 'ok') "corrupt cache ($name) is invalidated, re-probed and replaced; the start is unaffected"
            $r=ResolveAt 'auto' (CachePlan) $corruptRoot
            Check ($r.detectionCache -eq 'hit' -and $probe.calls -eq $before+1) "the cache replaced after the $name corruption is valid again"
        }
        Check ((Get-Item -LiteralPath $corruptPath).Length -le 16384) 'the cache file the module writes is far below the 16 KiB read cap'
        # a reparse-point or a cache read that throws is never fatal either
        $savedKey=& $module {(Get-Command Get-FastLlmVulkanBarCacheKey).ScriptBlock}
        & $module { function script:Get-FastLlmVulkanBarCacheKey { throw 'synthetic policy failure' } }
        try {
            $threw=$false;$before=$probe.calls
            try{$r=ResolveAt 'auto' (CachePlan) $corruptRoot}catch{$threw=$true}
            Check (-not $threw -and $r.requested -eq 'auto' -and $r.effective -eq 'off' -and $r.reason -eq 'policy-error' -and $r.rebarDetected -eq 'not-probed' -and $r.detectorVersion -ceq 'rebar-heap-layout-v2' -and $probe.calls -eq $before) 'any exception while resolving auto yields effective=off, reason=policy-error and never throws'
            $r=ResolveAt 'on' (CachePlan) $corruptRoot
            Check ($r.effective -eq 'on' -and $r.reason -eq 'explicit-on') 'explicit on does not depend on the detector cache'
        } finally { & $module {param($B) Set-Item -Path Function:script:Get-FastLlmVulkanBarCacheKey -Value $B} $savedKey }
        $r=ResolveAt 'auto' (CachePlan) $corruptRoot
        Check ($r.detectionCache -eq 'hit' -and $r.effective -eq 'on') 'after the failure injection is removed the policy resolves normally again'
        $threw=$false;try{Resolve 'bogus' $vulkanPlan | Out-Null}catch{$threw=$true}
        Check $threw 'an unknown policy NAME is still rejected up front (a configuration error, not a policy-error)'
        # ---- Unmocked real-environment checks (native-test.sh runs as a standard account over SSH, where WMI is denied) ----
        if($env:OS -ceq 'Windows_NT'){
            & $module { param($B,$P,$S,$SS) Set-Item -Path Function:script:Get-FastLlmVulkanBarBootIdentity -Value $B; Set-Item -Path Function:script:Get-FastLlmVulkanBarPnpRecords -Value $P; Set-Item -Path Function:script:Get-FastLlmVulkanBarSleepDelta -Value $S; Set-Item -Path Function:script:Get-FastLlmVulkanBarSleepDeltaSource -Value $SS } $realBootFn $realPnpFn $realSleepFn $realSleepSourceFn
            # Real sleep accounting (kernel32 QueryUnbiasedInterruptTime and GetTickCount64), compiled by the module's single Add-Type call.
            & $module { Initialize-FastLlmVulkanBarNativeTypes }
            $isAdmin=(New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            $realUnbiased=[Bitworks.FastLlm.WindowsBootTime]::QueryUnbiasedInterruptTime100ns()
            $realUptime=[Bitworks.FastLlm.WindowsBootTime]::UptimeMilliseconds()
            Check ($realUnbiased -gt 0 -and ($realUnbiased / 10000) -le ($realUptime + 1000)) ('real QueryUnbiasedInterruptTime works in this account (admin=' + $isAdmin + '): ' + [long]($realUnbiased / 10000) + ' ms unbiased, ' + $realUptime + ' ms uptime')
            $realDelta1=[Bitworks.FastLlm.WindowsBootTime]::SleepDeltaMilliseconds()
            Start-Sleep -Milliseconds 1200
            $realDelta2=[Bitworks.FastLlm.WindowsBootTime]::SleepDeltaMilliseconds()
            Write-Host ('REAL: sleep delta ' + $realDelta1 + ' ms then ' + $realDelta2 + ' ms')
            Check ($realDelta1 -ge 0 -and $realDelta2 -ge 0 -and [math]::Abs($realDelta2 - $realDelta1) -le 5000) 'real SleepDeltaMilliseconds is non-negative and stable across two reads within 5 s'
            $realViaModule=& $module { Get-FastLlmVulkanBarSleepDelta }
            Check ($realViaModule -is [long] -and $realViaModule -ge 0 -and [math]::Abs($realViaModule - $realDelta2) -le 5000) 'the module sleep-delta reader returns the real non-negative delta'
            # UNMOCKED: which sleep-delta path ran, and whether the QueryInterruptTime export exists in the API set (GetProcAddress, no call).
            $realSource=[Bitworks.FastLlm.WindowsBootTime]::SleepDeltaSource
            $realExport=[Bitworks.FastLlm.WindowsBootTime]::QueryInterruptTimeExportPresent()
            $realSourceViaModule=& $module { Get-FastLlmVulkanBarSleepDeltaSource }
            Write-Host ('REAL: sleep delta path=' + $realSource + ' export-present(api-ms-win-core-realtime-l1-1-1.dll!QueryInterruptTime)=' + $realExport)
            Check ($realSource -cin @('interrupt-time','tick-fallback') -and $realSourceViaModule -ceq $realSource) 'the real sleep-delta path is recorded and the module reader returns it'
            $realBuild=[Environment]::OSVersion.Version.Build
            if($realBuild -ge 10240){
                # Windows 10 or later always has the realtime API set and the export: the fallback path here is a defect, not an environment.
                Check ($realSource -ceq 'interrupt-time' -and $realExport -eq $true) ('Windows 10+ (build ' + $realBuild + ') uses the interrupt-time path (' + $realSource + ') and the QueryInterruptTime export is present (' + $realExport + ')')
            } else {
                Check (($realSource -ceq 'interrupt-time') -eq $realExport) ('the path that ran (' + $realSource + ') agrees with the GetProcAddress check for the export (' + $realExport + ') on a pre-Windows-10 build (' + $realBuild + ')')
            }
            $realRecords=@(& $module { Get-FastLlmVulkanBarPnpRecords })
            $realAmd=@($realRecords | Where-Object { $_.InstanceId -like 'PCI\VEN_1002*' -and -not [string]::IsNullOrWhiteSpace($_.Description) })
            if($realAmd.Count -eq 0){ Write-Host 'SKIP: no present AMD display adapter via SetupAPI' }
            else {
                Check (@($realAmd | Where-Object { [string]::IsNullOrWhiteSpace($_.DriverVersion) }).Count -eq 0) ('real ReadPnP returns present AMD adapters with driver versions: ' + (($realAmd | ForEach-Object { $_.Description + '=' + $_.DriverVersion }) -join '; '))
            }
            $realBoot=& $module { Get-FastLlmVulkanBarBootIdentity }
            $parsedReal=[datetime]::MinValue
            $okParse=[datetime]::TryParse([string]$realBoot,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsedReal)
            Check ($okParse -and $parsedReal.Kind -eq [DateTimeKind]::Utc -and $parsedReal -lt [datetime]::UtcNow -and $parsedReal -gt [datetime]::UtcNow.AddDays(-400)) ('real native boot identity is a plausible UTC round-trip time: ' + $realBoot)
            if($realAmd.Count -gt 0){
                $realName=[string]$realAmd[0].Description
                $k1=& $module { param($A) Get-FastLlmVulkanBarCacheKey -Adapters $A } @([pscustomobject]@{name=$realName})
                $k2=& $module { param($A) Get-FastLlmVulkanBarCacheKey -Adapters $A } @([pscustomobject]@{name=$realName})
                Write-Host ('REAL: cache key for ' + $realName + ' -> ' + $k1)
                Check ($k1 -and $k1 -ceq $k2) 'two consecutive real key computations are equal'
                $wmiWorks=$true
                try { $null=Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop } catch { $wmiWorks=$false }
                if($wmiWorks){ Write-Host 'SKIP: real WMI works in this context; the WMI-denied default-path check is not exercised unmocked' }
                else {
                    $defaultAdapters=@([pscustomobject]@{device='Vulkan0';name=$realName;driverVersion=$null})
                    $filled=& $module { param($A) Add-FastLlmDriverVersions -Adapters $A } $defaultAdapters
                    Write-Host ('REAL: WMI denied; default-path driverVersion for ' + $realName + ' = ' + $(if($null -eq $filled[0].driverVersion){'<null>'}else{$filled[0].driverVersion}))
                    Check ($null -eq $filled[0].driverVersion) 'real default path: with WMI denied the adapter driverVersion stays null'
                }
            }
        }
    } finally {
        & $module {param($B,$P,$S,$SS) Set-Item -Path Function:script:Get-FastLlmVulkanBarBootIdentity -Value $B; Set-Item -Path Function:script:Get-FastLlmVulkanBarPnpRecords -Value $P; Set-Item -Path Function:script:Get-FastLlmVulkanBarSleepDelta -Value $S; Set-Item -Path Function:script:Get-FastLlmVulkanBarSleepDeltaSource -Value $SS} $savedBoot $savedPnp $savedSleep $savedSleepSource
        foreach($path in @($cacheRoot,$coldRoot,$unknownRoot,$corruptRoot)){if($path -and (Test-Path -LiteralPath $path)){Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue}}
    }
} finally {
    & $module {param($B,$Pn,$Bt,$Sl,$Ss) Set-Item -Path Function:script:Invoke-FastLlmVulkanHeapProbe -Value $B; Set-Item -Path Function:script:Get-FastLlmVulkanBarPnpRecords -Value $Pn; Set-Item -Path Function:script:Get-FastLlmVulkanBarBootIdentity -Value $Bt; Set-Item -Path Function:script:Get-FastLlmVulkanBarSleepDelta -Value $Sl; Set-Item -Path Function:script:Get-FastLlmVulkanBarSleepDeltaSource -Value $Ss} $saved $realPnpFn $realBootFn $realSleepFn $realSleepSourceFn
    foreach($path in @($policyRoots)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue}}
}

# ---- canary core (scriptblock request seam; no server) ----
function FakeResponse([double]$PromptMs=100,[int]$PromptN=512,[int]$Status=200){
    $final='{"content":"","stop":true,"timings":{"prompt_n":'+$PromptN+',"prompt_ms":'+$PromptMs+',"predicted_n":16,"predicted_ms":160}}'
    [pscustomobject]@{Status=$Status;Body='';ElapsedMs=40.0;Events=@('{"content":"x","stop":false}',$final,'[DONE]');EventTimesMs=@(10.0,20.0,30.0)}
}
$Model27B='qwen3.8-27b-ud-q4-k-m'
function Canary($Names,[scriptblock]$Request,[int]$Context=1024,[string]$Model=$Model27B){& $module {param($N,$R,$C,$M) Invoke-FastLlmThroughputCanary -BaseUrl 'http://127.0.0.1:1' -ContextSize $C -AdapterNames $N -Request $R -ModelId $M} $Names $Request $Context $Model}
$tokenBody='{"tokens":['+((1..600) -join ',')+']}'
function NewMock([double]$PromptMs=100,[int]$PromptN=512){
    $tb=$tokenBody  # GetNewClosure copies only locals; script-level $tokenBody is not visible when run from another script (CI)
    $recorded=@{paths=(New-Object 'Collections.Generic.List[string]');completion=$null;completions=0}
    $response=FakeResponse $PromptMs $PromptN
    $request={param($Path,$Body,$TimeoutMs)
        $recorded.paths.Add($Path)
        if($Path -eq '/tokenize'){return [pscustomobject]@{Status=200;Body=$tb;Events=@();EventTimesMs=@();ElapsedMs=1.0}}
        $recorded.completion=$Body
        $recorded.completions++
        return $response
    }.GetNewClosure()
    return @{recorded=$recorded;request=$request}
}
$m=NewMock 100
$r=Canary @('AMD Radeon RX 7900 XTX') $m.request
Check ($r.status -eq 'ok' -and $r.ppTokPerS -eq 5120 -and $r.floor -eq 200 -and $r.promptTokens -eq 512) 'canary ok: 512 tokens in 100 ms on an RX 7900 XTX with a 27B model is above the 200 tok/s floor'
Check ($m.recorded.completions -eq 2 -and $r.floorSource -ceq 'reviewed-27b-card-floor' -and $r.warmupPpTokPerS -eq 5120) 'canary sends one discarded warm-up request before the measured one and records the floor source and the warm-up speed'
$body=$m.recorded.completion
$expectedHash=& $module {param($T) Get-FastLlmPromptArtifactSha256 @($T[0..511])} (1..600)
Check ($body.prompt.Count -eq 512 -and $body.prompt[0] -eq 1 -and $body.prompt[511] -eq 512 -and $body.n_predict -eq 16 -and $body.cache_prompt -eq $false -and $body.stream -eq $true -and $body.ignore_eos -eq $true -and $body.temperature -eq 0 -and $body.seed -eq 42) 'canary sends the fixed exact 512-token streaming workload'
Check ($r.promptArtifactSha256 -eq $expectedHash) 'canary records the shared prompt-artifact digest of the exact tokens it sent'
$r=Canary @('AMD Radeon RX 7900 XTX') (NewMock 5000).request
Check ($r.status -eq 'degraded' -and $r.ppTokPerS -eq 102.4 -and $r.floor -eq 200 -and $r.reason -eq 'below-floor') 'canary degraded: 512 tokens in 5 s is below the floor'
$r=Canary @('AMD Radeon RX 7900 XT') (NewMock 2560).request
Check ($r.status -eq 'ok' -and $r.ppTokPerS -eq 200 -and $r.floor -eq 200) 'canary ok exactly at the floor on an RX 7900 XT'
$r=Canary @('AMD Radeon RX 7900 XT') (NewMock 5000).request
Check ($r.status -eq 'degraded') 'an RX 7900 XT matches only the XT floor'
$r=Canary @('AMD Radeon RX 9999') (NewMock 100).request
Check ($r.status -eq 'unrated' -and $null -eq $r.floor -and $null -eq $r.floorSource -and $r.ppTokPerS -eq 5120) 'unknown card: unrated, but the measurement is still recorded'
$r=Canary @('AMD Radeon RX 7900 XTX','AMD Radeon RX 7900 XT') (NewMock 5000).request
Check ($r.status -eq 'unrated') 'several adapters: unrated, never degraded'
$r=Canary @() (NewMock 100).request
Check ($r.status -eq 'unrated') 'no adapter names: unrated'
foreach($other in @('qwen3.5-9b-q4-k-m','qwen3.5-4b-iq4-xs','test-model','')){
    $r=Canary @('AMD Radeon RX 7900 XTX') (NewMock 5000).request 1024 $other
    Check ($r.status -eq 'unrated' -and $null -eq $r.floor -and $null -eq $r.floorSource -and $r.reason -eq 'no-floor-for-model-card' -and $r.ppTokPerS -eq 102.4) "a slow measurement for model '$other' without a reviewed floor is unrated, never degraded"
}
foreach($id in @('qwen3.8-27b-ud-iq4-xs','qwen3.8-27b-ud-q4-k-m','qwen3.8-27b-q8-0')){
    $r=Canary @('AMD Radeon RX 7900 XT') (NewMock 5000).request 1024 $id
    Check ($r.status -eq 'degraded' -and $r.floor -eq 200) "27B model $id keeps the existing card floors"
}
# warm-up: the first request is discarded, only the second one is rated
$warmSlow=@((FakeResponse 5000),(FakeResponse 100))
function NewSequence($Responses){
    $tb=$tokenBody  # GetNewClosure copies only locals; script-level $tokenBody is not visible when run from another script (CI)
    $sequence=@{n=0;paths=(New-Object 'Collections.Generic.List[string]')}
    $request={param($Path,$Body,$TimeoutMs)
        $sequence.paths.Add($Path)
        if($Path -eq '/tokenize'){return [pscustomobject]@{Status=200;Body=$tb;Events=@();EventTimesMs=@();ElapsedMs=1.0}}
        $item=$Responses[[Math]::Min($sequence.n,$Responses.Count-1)]
        $sequence.n++
        if($item -is [scriptblock]){return (& $item)}
        return $item
    }.GetNewClosure()
    return @{sequence=$sequence;request=$request}
}
$seq=NewSequence $warmSlow
$r=Canary @('AMD Radeon RX 7900 XTX') $seq.request
Check ($r.status -eq 'ok' -and $r.ppTokPerS -eq 5120 -and $r.warmupPpTokPerS -eq 102.4 -and (@($seq.sequence.paths) -join ',') -ceq '/tokenize,/completion,/completion') 'a slow warm-up is discarded: the measured request alone is rated (ok), the warm-up speed is only recorded'
$seq=NewSequence @((FakeResponse 100),(FakeResponse 5000))
$r=Canary @('AMD Radeon RX 7900 XTX') $seq.request
Check ($r.status -eq 'degraded' -and $r.ppTokPerS -eq 102.4 -and $r.warmupPpTokPerS -eq 5120) 'a slow measured request after a fast warm-up is degraded'
# timeouts: degraded with reason timeout when a reviewed floor exists, never failed; never degraded without a floor
$timeoutFailure={throw (New-Object TimeoutException 'The operation has timed out.')}
$webTimeout={throw (New-Object Net.WebException 'The operation has timed out.',([Net.WebExceptionStatus]::Timeout))}
$webCanceled={throw (New-Object Net.WebException 'The request was canceled.',([Net.WebExceptionStatus]::RequestCanceled))}
$socketTimeout={throw (New-Object IO.IOException 'Unable to read data from the transport connection.',(New-Object Net.Sockets.SocketException 10060))}
$socketTimeoutDeep={throw (New-Object InvalidOperationException 'wrapper',(New-Object IO.IOException 'io',(New-Object Net.Sockets.SocketException 10060)))}
foreach($failure in @($timeoutFailure,$webTimeout,$webCanceled,$socketTimeout,$socketTimeoutDeep)){
    $seq=NewSequence @((FakeResponse 100),$failure)
    $r=Canary @('AMD Radeon RX 7900 XTX') $seq.request
    Check ($r.status -eq 'degraded' -and $r.reason -eq 'timeout' -and $null -eq $r.ppTokPerS -and $r.floor -eq 200 -and $r.warmupPpTokPerS -eq 5120) 'a timeout of the measured request is degraded with reason timeout, not failed'
    $seq=NewSequence @($failure,(FakeResponse 100))
    $r=Canary @('AMD Radeon RX 7900 XTX') $seq.request
    Check ($r.status -eq 'degraded' -and $r.reason -eq 'timeout' -and $null -eq $r.ppTokPerS) 'a timeout of the warm-up request is degraded with reason timeout, not failed'
}
$seq=NewSequence @((FakeResponse 100),$timeoutFailure)
$r=Canary @('AMD Radeon RX 7900 XTX') $seq.request 1024 'qwen3.5-9b-q4-k-m'
Check ($r.status -eq 'unrated' -and $r.reason -eq 'timeout' -and $null -eq $r.floor) 'a timeout without a reviewed floor is unrated, never degraded'
# detection is typed: a timeout-sounding message alone, or a non-timeout SocketException, is not a timeout
foreach($notTimeout in @({throw (New-Object InvalidOperationException 'The operation has timed out.')},{throw (New-Object IO.IOException 'reset',(New-Object Net.Sockets.SocketException 10054))},{throw (New-Object Net.WebException 'The request was canceled.',([Net.WebExceptionStatus]::ConnectFailure))})){
    $seq=NewSequence @((FakeResponse 100),$notTimeout)
    $r=Canary @('AMD Radeon RX 7900 XTX') $seq.request
    Check ($r.status -eq 'failed' -and $r.reason -eq 'canary-error') 'timeout detection is typed: message text alone or a non-timeout socket/web status is a failure, not a timeout'
}
$seq=NewSequence @((FakeResponse 100),{throw 'synthetic transport failure'})
$r=Canary @('AMD Radeon RX 7900 XTX') $seq.request
Check ($r.status -eq 'failed' -and $r.reason -eq 'canary-error') 'a non-timeout transport failure of the measured request is failed'
$seq=NewSequence @((FakeResponse 100 512 500),(FakeResponse 100))
$r=Canary @('AMD Radeon RX 7900 XTX') $seq.request
Check ($r.status -eq 'failed' -and $r.reason -eq 'warmup-failed' -and $null -eq $r.ppTokPerS) 'a failed warm-up response is failed'
$r=Canary @('AMD Radeon RX 7900 XTX') (NewMock 100 513).request
Check ($r.status -eq 'ok' -and $r.promptTokens -eq 513) 'a server that evaluates 513 prompt tokens (special token) is accepted'
$r=Canary @('AMD Radeon RX 7900 XTX') (NewMock 100 600).request
Check ($r.status -eq 'failed' -and $r.reason -eq 'unexpected-prompt-length' -and $null -eq $r.ppTokPerS) 'a different evaluated prompt length is failed, not a measurement'
$r=Canary @('AMD Radeon RX 7900 XTX') {param($Path,$Body,$TimeoutMs) [pscustomobject]@{Status=500;Body='{}';Events=@();EventTimesMs=@();ElapsedMs=1.0}}
Check ($r.status -eq 'failed' -and $r.reason -eq 'tokenize-failed') 'tokenize failure is failed'
$r=Canary @('AMD Radeon RX 7900 XTX') {param($Path,$Body,$TimeoutMs) throw 'synthetic transport failure'}
Check ($r.status -eq 'failed' -and $r.reason -eq 'canary-error') 'a throwing transport never escapes the canary'
$completionFails={param($Path,$Body,$TimeoutMs) if($Path -eq '/tokenize'){[pscustomobject]@{Status=200;Body=$tokenBody;Events=@();EventTimesMs=@();ElapsedMs=1.0}}else{[pscustomobject]@{Status=500;Body='{}';Events=@();EventTimesMs=@();ElapsedMs=1.0}}}.GetNewClosure()
$r=Canary @('AMD Radeon RX 7900 XTX') $completionFails
Check ($r.status -eq 'failed') 'a failed completion is failed'
$short={param($Path,$Body,$TimeoutMs) [pscustomobject]@{Status=200;Body='{"tokens":[1,2,3]}';Events=@();EventTimesMs=@();ElapsedMs=1.0}}
$r=Canary @('AMD Radeon RX 7900 XTX') $short
Check ($r.status -eq 'failed' -and $r.reason -eq 'corpus-too-short') 'a too-short tokenization is failed'
$never=NewMock 100
$r=Canary @('AMD Radeon RX 7900 XTX') $never.request 400
Check ($r.status -eq 'failed' -and $r.reason -eq 'context-too-small' -and $never.recorded.paths.Count -eq 0) 'a context too small for the fixed workload fails before any request'

# ---- real supervisor against the native HTTP mock: environment, state and canary ----
& $module { Initialize-FastLlmProcessHost }
Add-Type -Path (Join-Path $PSScriptRoot 'helpers/MockServer.cs')
$temp=Join-Path ([IO.Path]::GetTempPath()) ('fast-llm-vkpolicy-'+[Guid]::NewGuid().ToString('N'))
$suitePassed=$false
$lock=$null
function Invoke-PolicyRun {
    param([string]$Name,[string]$Policy='off',[string]$Backend='Vulkan',[switch]$Canary,[switch]$Recipe,[string]$Mode='ok',[string]$Expect='absent',[string]$Card='AMD Radeon RX 7900 XTX',[string]$Engine='b10698',[string]$ModelId='qwen3.8-27b-ud-q4-k-m')
    $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
    $listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
    $runRoot=Join-Path $temp $Name
    $script:lock=Enter-FastLlmOperation $runRoot
    $plan=[pscustomobject]@{
        enginePath=(Get-Process -Id $PID).Path
        serverArguments=@('-NoLogo','-NoProfile','-File',(Join-Path $PSScriptRoot 'helpers/mock-server.ps1'),'-Port',"$port",'-Mode',$Mode,'-Model',$ModelId,'-DiagnosticPath',(Join-Path $runRoot 'diag.txt'))
        endpoint="http://127.0.0.1:$port/v1";backend=$Backend;selectedAdapters=@([pscustomobject]@{device='Vulkan0';name=$Card})
        hardwareFingerprint='synthetic';engineVersion=$Engine;model=[pscustomobject]@{id=$ModelId;contextSize=1024;sha256=('0'*64)}
    }
    if($Recipe){
        $plan | Add-Member -NotePropertyMembers @{catalogVersion='test';splitMode='none';tensorSplit=$null;modelPath=$ModelId}
        $plan.model | Add-Member -NotePropertyMembers @{parallel=1;cacheTypeK='f16';cacheTypeV='f16'}
    }
    $names=@('GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM','GGML_VK_PREFER_HOST_MEMORY','FASTLLM_TEST_EXPECT_VK_HOST_VISIBLE')
    $savedEnvironment=@{}
    foreach($n in $names){$savedEnvironment[$n]=[Environment]::GetEnvironmentVariable($n)}
    # Hostile inherited values: a disabled-value '0' must be cleared, then set to exactly '1' only when the policy resolves.
    [Environment]::SetEnvironmentVariable('GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM','0')
    [Environment]::SetEnvironmentVariable('GGML_VK_PREFER_HOST_MEMORY','1')
    [Environment]::SetEnvironmentVariable('FASTLLM_TEST_EXPECT_VK_HOST_VISIBLE',$Expect)
    $stopper=New-Object Diagnostics.Process
    $stopper.StartInfo.FileName=(Get-Process -Id $PID).Path
    $stopCode="Import-Module '$($root.Replace("'","''"))/src/FastLlm.psm1'; for (`$i=0; `$i -lt 300; `$i++) { try { `$s=Get-FastLlmStatus '$($runRoot.Replace("'","''"))'; if (`$s.phase -eq 'ready') { Request-FastLlmStop '$($runRoot.Replace("'","''"))'; exit 0 } } catch {}; Start-Sleep -Milliseconds 200 }; exit 1"
    $stopper.StartInfo.Arguments='-NoLogo -NoProfile -OutputFormat Text -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($stopCode))
    $stopper.StartInfo.UseShellExecute=$false
    $stopper.Start()|Out-Null
    try {
        $options=@{Plan=$plan;InstallRoot=$runRoot;LoadTimeoutSeconds=30}
        if($Policy -ne 'off'){$options.VulkanBarMitigation=$Policy}
        if($Recipe){$options.CatalogPath=(Join-Path $root 'config/catalog.json')}
        if($Canary){$options.ThroughputCanary=$true}
        $exit=& $module { param($O) Invoke-FastLlmSupervisedServer @O } $options
        $diag='';$diagPath=Join-Path $runRoot 'diag.txt'
        if(Test-Path -LiteralPath $diagPath){$diag=[string](Get-Content -LiteralPath $diagPath -Raw)}
        $ok=$stopper.WaitForExit(10000) -and $stopper.ExitCode -eq 0
        return [pscustomobject]@{exit=$exit;state=(Get-FastLlmStatus $runRoot);diag=$diag;stopperOk=$ok;runRoot=$runRoot}
    } finally {
        foreach($n in $names){[Environment]::SetEnvironmentVariable($n,$savedEnvironment[$n])}
        if(-not $stopper.HasExited){$stopper.Kill()};$stopper.Dispose()
        $script:lock.Dispose();$script:lock=$null
    }
}
try {
    $probe.report=$xtxHost;$probe.fail=$false
    & $module {
        param($P)
        function script:Invoke-FastLlmVulkanHeapProbe {
            param($TimeoutSeconds,$CollectorPath)
            $script:policyProbe.calls++
            if($script:policyProbe.fail){throw 'synthetic probe failure'}
            return $script:policyProbe.report
        }
    } $probe
    $probe.calls=0
    $run=Invoke-PolicyRun -Name 'default-off' -Expect 'absent'
    Check ($run.exit -eq 0 -and $run.stopperOk -and $run.state.phase -eq 'stopped' -and $run.diag -notmatch 'unexpected|extra-ggml') 'default policy: the child sees neither mitigation variable and no other GGML_* (hostile 0 and PREFER_HOST_MEMORY cleared)'
    Check ($run.state.vulkanMemoryPolicy.requested -eq 'off' -and $run.state.vulkanMemoryPolicy.effective -eq 'off' -and $run.state.vulkanMemoryPolicy.reason -eq 'policy-off' -and $run.state.vulkanMemoryPolicy.rebarDetected -eq 'not-probed') 'default policy is recorded in run state as off / not-probed'
    Check ($probe.calls -eq 0) 'the default start runs no heap probe'
    Check (-not $run.state.PSObject.Properties['throughputCanary']) 'the default start records no canary field and runs no canary'
    $run=Invoke-PolicyRun -Name 'on' -Policy 'on' -Expect '1'
    Check ($probe.calls -eq 0) 'an explicit on never runs the heap probe'
    Check ($run.exit -eq 0 -and $run.stopperOk -and $run.diag -notmatch 'unexpected|extra-ggml') 'on: the child environment has exactly GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM=1 set after sanitisation and no other GGML_*'
    Check ($run.state.vulkanMemoryPolicy.requested -eq 'on' -and $run.state.vulkanMemoryPolicy.effective -eq 'on' -and $run.state.vulkanMemoryPolicy.reason -eq 'explicit-on' -and $run.state.vulkanMemoryPolicy.rebarDetected -eq 'not-probed-explicit-on') 'on is recorded with its reason and no detector result'
    $run=Invoke-PolicyRun -Name 'auto-off' -Policy 'auto' -Expect '1'
    Check ($run.exit -eq 0 -and $run.diag -notmatch 'unexpected|extra-ggml' -and $run.state.vulkanMemoryPolicy.effective -eq 'on' -and $run.state.vulkanMemoryPolicy.reason -eq 'rebar-off-detected' -and $run.state.vulkanMemoryPolicy.probeStatus -eq 'ok') 'auto on a rebar-off fixture sets the variable and records why'
    Check ($run.state.barGuidance.shown -eq $true -and $run.state.barGuidance.text -ceq "Resizable BAR (AMD Smart Access Memory) appears to be off on this PC. FastLLM applied a workaround so models run at full speed. Turning on Resizable BAR / Smart Access Memory in your BIOS is AMD's recommended setup and may help further. See docs/RESIZABLE-BAR.md.") 'a rebar-off-detected start records the exact BIOS guidance in state.barGuidance'
    $probe.report=$xtHost
    $run=Invoke-PolicyRun -Name 'auto-on' -Policy 'auto' -Expect 'absent' -Card 'AMD Radeon RX 7900 XT'
    Check ($run.exit -eq 0 -and $run.diag -notmatch 'unexpected|extra-ggml' -and $run.state.vulkanMemoryPolicy.effective -eq 'off' -and $run.state.vulkanMemoryPolicy.rebarDetected -eq 'rebar-on') 'auto on a rebar-on fixture leaves the child environment untouched'
    Check ($run.state.barGuidance.shown -eq $false -and $null -eq $run.state.barGuidance.text) 'no BIOS guidance is shown when Resizable BAR is on'
    $probe.report=$null
    $run=Invoke-PolicyRun -Name 'auto-unknown' -Policy 'auto' -Expect 'absent'
    Check ($run.exit -eq 0 -and $run.diag -notmatch 'unexpected|extra-ggml' -and $run.state.vulkanMemoryPolicy.effective -eq 'off' -and $run.state.vulkanMemoryPolicy.rebarDetected -eq 'unknown') 'auto with an unknown detector result leaves the child environment untouched'
    $probe.report=$xtxHost;$probe.calls=0
    foreach($mode in @('on','auto')){
        $run=Invoke-PolicyRun -Name "engine-$mode" -Policy $mode -Engine 'b10829' -Expect 'absent'
        Check ($run.exit -eq 0 -and $run.diag -notmatch 'unexpected|extra-ggml' -and $run.state.vulkanMemoryPolicy.effective -eq 'off' -and $run.state.vulkanMemoryPolicy.reason -eq 'engine-not-verified' -and $run.state.vulkanMemoryPolicy.detectorVersion -ceq 'rebar-heap-layout-v2') "$mode on an engine other than b10698 never sets the variable (engine-not-verified)"
    }
    Check ($probe.calls -eq 0) 'an unverified engine never runs the heap probe in a real start'
    foreach($mode in @('on','auto')){
        $run=Invoke-PolicyRun -Name "rocm-$mode" -Policy $mode -Backend 'ROCm' -Expect 'absent'
        Check ($run.exit -eq 0 -and $run.diag -notmatch 'unexpected|extra-ggml' -and $run.state.vulkanMemoryPolicy.effective -eq 'off' -and $run.state.vulkanMemoryPolicy.reason -eq 'non-vulkan-lane') "$mode on a non-Vulkan lane never sets the variable"
    }
    Check ($probe.calls -eq 0) 'non-Vulkan lanes never run the heap probe'

    # recipe binding: the override is recorded only when the mitigation is in effect; the default recipe is unchanged
    $recipeNames=@('catalogVersion','catalogSha256','engineSha256','backend','contextSize','slots','cacheTypeK','cacheTypeV','speculation','flashAttention','splitMode','tensorSplit','adapters','requestedArguments','configurationIsolation')
    $probe.report=$xtxHost
    # Ports and scratch paths legitimately differ per run, so requestedArguments is compared by shape only; the rebar-on run uses a different (XT) card, so adapters are excluded.
    function RecipeComparable($Recipe){($Recipe | Select-Object -Property * -ExcludeProperty requestedArguments,environmentOverride,adapters | ConvertTo-Json -Depth 8 -Compress)}
    $recipeOff=Invoke-PolicyRun -Name 'recipe-off' -Recipe -Expect 'absent'
    $recipeOn=Invoke-PolicyRun -Name 'recipe-on' -Recipe -Policy 'on' -Expect '1'
    $recipeAuto=Invoke-PolicyRun -Name 'recipe-auto' -Recipe -Policy 'auto' -Expect '1'
    $probe.report=$xtHost
    $recipeAutoOn=Invoke-PolicyRun -Name 'recipe-auto-rebar-on' -Recipe -Policy 'auto' -Expect 'absent' -Card 'AMD Radeon RX 7900 XT'
    Check (($recipeOff.state.recipe.PSObject.Properties.Name -join ',') -ceq ($recipeNames -join ',')) 'the default recipe has exactly the pre-existing fields (no environmentOverride)'
    Check (-not $recipeAutoOn.state.recipe.PSObject.Properties['environmentOverride'] -and ((RecipeComparable $recipeAutoOn.state.recipe) -ceq (RecipeComparable $recipeOff.state.recipe))) 'auto that does not apply the mitigation leaves the recipe byte-identical to the default'
    foreach($applied in @($recipeOn,$recipeAuto)){
        $override=$applied.state.recipe.PSObject.Properties['environmentOverride']
        Check ($override -and (@($override.Value.PSObject.Properties.Name) -join ',') -ceq 'GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM' -and $override.Value.GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM -ceq '1') 'an applied mitigation records recipe.environmentOverride'
        Check ((($applied.state.recipe.PSObject.Properties.Name | Where-Object { $_ -ne 'environmentOverride' }) -join ',') -ceq ($recipeNames -join ',') -and $applied.state.recipe.requestedArguments.Count -eq $recipeOff.state.recipe.requestedArguments.Count -and (RecipeComparable $applied.state.recipe) -ceq (RecipeComparable $recipeOff.state.recipe)) 'the rest of the recipe is unchanged by the mitigation'
    }

    # canary through the real HTTP transport
    $run=Invoke-PolicyRun -Name 'canary-ok' -Canary -Expect 'absent'
    Check ($run.exit -eq 0 -and $run.state.phase -eq 'stopped' -and $run.state.throughputCanary.status -eq 'ok' -and $run.state.throughputCanary.ppTokPerS -eq 5120 -and $run.state.throughputCanary.floor -eq 200) 'canary ok over real HTTP is recorded in run state'
    Check ($run.state.canary.streaming -and $run.state.placement.reportedAllLayers) 'the canary leaves the normal Ready evidence intact'
    $run=Invoke-PolicyRun -Name 'canary-slow' -Canary -Mode 'canary-slow' -Expect 'absent'
    Check ($run.exit -eq 0 -and $run.state.phase -eq 'stopped' -and $run.state.throughputCanary.status -eq 'degraded' -and $run.state.throughputCanary.ppTokPerS -lt 200) 'a slow canary is degraded but the start still completes'
    $run=Invoke-PolicyRun -Name 'canary-nofloor' -Canary -Expect 'absent' -Card 'AMD Radeon RX 9999'
    Check ($run.exit -eq 0 -and $run.state.throughputCanary.status -eq 'unrated' -and $run.state.throughputCanary.ppTokPerS -eq 5120) 'an unknown card records unrated with its measurement'
    Check (($run.state.throughputCanary.PSObject.Properties.Name -join ',') -ceq 'ppTokPerS,floor,floorSource,warmupPpTokPerS,status,promptTokens,promptArtifactSha256,reason') 'the canary result has the documented field set'
    Check ($run.state.throughputCanary.warmupPpTokPerS -eq 5120) 'the real-transport canary records the warm-up speed'
    $run=Invoke-PolicyRun -Name 'canary-nofloor-model' -Canary -Mode 'canary-slow' -Expect 'absent' -ModelId 'test-model'
    Check ($run.exit -eq 0 -and $run.state.throughputCanary.status -eq 'unrated' -and $null -eq $run.state.throughputCanary.floor -and $run.state.throughputCanary.ppTokPerS -lt 200) 'a slow canary for a model without a reviewed floor is unrated, never degraded'
    $run=Invoke-PolicyRun -Name 'canary-fail' -Canary -Mode 'canary-fail' -Expect 'absent'
    Check ($run.exit -eq 0 -and $run.state.phase -eq 'stopped' -and $run.state.throughputCanary.status -eq 'failed' -and $null -eq $run.state.failureCode) 'a failing canary never fails the start or triggers recovery'
    $suitePassed=$true
} finally {
    & $module {param($B) Set-Item -Path Function:script:Invoke-FastLlmVulkanHeapProbe -Value $B} $saved
    if($lock){$lock.Dispose()}
    if($suitePassed -and (Test-Path -LiteralPath $temp)){Remove-Item -LiteralPath $temp -Recurse -Force}
    elseif(-not $suitePassed){Write-Warning "Vulkan memory-policy scratch retained for failure diagnostics: $temp"}
}

# ---- real probe against fake collectors: categories, sandbox, no leftovers (no Vulkan is loaded) ----
$probeTemp=Join-Path ([IO.Path]::GetTempPath()) ('fast-llm-vkprobe-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $probeTemp | Out-Null
function Get-ProbeSandboxes{@(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'FastLlm-VkHeap-*' -ErrorAction SilentlyContinue | ForEach-Object{$_.FullName})}
function New-FakeCollector([string]$Name,[string]$Body){
    $path=Join-Path $probeTemp ($Name+'.ps1')
    [IO.File]::WriteAllText($path,"param([Parameter(Mandatory=`$true)][string]`$OutputPath)`n`$ErrorActionPreference='Stop'`n$Body`n")
    return $path
}
function Invoke-RealProbe([string]$Collector,[int]$Timeout=30){
    $category=$null;$report=$null
    try{$report=& $module {param($C,$T) Invoke-FastLlmVulkanHeapProbe -CollectorPath $C -TimeoutSeconds $T} $Collector $Timeout}
    catch{$category=[string]$_.Exception.Data['FastLlmProbeCategory']}
    return [pscustomobject]@{report=$report;category=$category}
}
$envNames=@('GGML_VK_PREFER_HOST_MEMORY','VK_ICD_FILENAMES','LLAMA_ARG_MODEL')
$savedProbeEnvironment=@{};foreach($n in $envNames){$savedProbeEnvironment[$n]=[Environment]::GetEnvironmentVariable($n)}
try {
    $sandboxesBefore=Get-ProbeSandboxes
    foreach($n in $envNames){[Environment]::SetEnvironmentVariable($n,'hostile')}
    $fixturePath=(Join-Path $PSScriptRoot 'fixtures/vulkan-heaps-xtx-rebar-off.json').Replace("'","''")
    $okCollector=New-FakeCollector 'ok' "Copy-Item -LiteralPath '$fixturePath' -Destination `$OutputPath"
    # A report that echoes the child's own environment instead of a heap report.
    $envCollector=New-FakeCollector 'env' @"
`$info=[ordered]@{policy=[string](Get-ExecutionPolicy -Scope Process);path=`$env:PATH;appData=`$env:APPDATA;programData=`$env:PROGRAMDATA;ggml=[string]`$env:GGML_VK_PREFER_HOST_MEMORY;vk=[string]`$env:VK_ICD_FILENAMES;llama=[string]`$env:LLAMA_ARG_MODEL;outputDirectory=(Split-Path -Parent `$OutputPath)}
[IO.File]::WriteAllText(`$OutputPath,(`$info | ConvertTo-Json))
"@
    $r=Invoke-RealProbe $okCollector
    Check ($null -ne $r.report -and $null -eq $r.category -and $r.report.devices.Count -ge 1) 'the real probe runs a collector in a child and returns its parsed report'
    $r=Invoke-RealProbe $envCollector
    $outputDirectory=[string]$r.report.outputDirectory
    Check ($r.report.policy -eq [string](Get-ExecutionPolicy -Scope Process)) 'the probe child inherits this process''s script policy instead of overriding it'
    Check ($r.report.ggml -eq '' -and $r.report.vk -eq '' -and $r.report.llama -eq '') 'the probe child has inherited GGML_/VK_/LLAMA_ variables cleared'
    Check ($r.report.path -eq ([Environment]::SystemDirectory+';'+$env:SystemRoot)) 'the probe child PATH is the sandboxed system directories only'
    Check ($r.report.appData -eq $r.report.programData -and $r.report.appData -like (Join-Path ([IO.Path]::GetTempPath()) 'FastLlm-VkHeap-*') -and $outputDirectory -eq $r.report.appData) 'the probe child APPDATA/PROGRAMDATA and report folder are the per-call temp sandbox, not the install root'
    Check (-not (Test-Path -LiteralPath $outputDirectory)) 'the per-call report folder is removed after a successful probe'
    $timeoutCollector=New-FakeCollector 'timeout' @"
[IO.File]::WriteAllText(`$OutputPath,'{}')
Start-Sleep -Seconds 120
"@
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $r=Invoke-RealProbe $timeoutCollector 5
    $timeoutSeconds=$watch.Elapsed.TotalSeconds
    Check ($r.category -eq 'timeout' -and $timeoutSeconds -lt 20) ("a hung collector is killed at its deadline and categorized timeout (took {0:N1} s for a 5 s deadline)" -f $timeoutSeconds)
    $r=Invoke-RealProbe (New-FakeCollector 'exit' "[IO.File]::WriteAllText(`$OutputPath,'{}');exit 3")
    Check ($r.category -eq 'child-exit') 'a non-zero collector exit is categorized child-exit'
    $r=Invoke-RealProbe (New-FakeCollector 'badjson' "[IO.File]::WriteAllText(`$OutputPath,'{not json')")
    Check ($r.category -eq 'parse') 'an unparseable report is categorized parse'
    $r=Invoke-RealProbe (New-FakeCollector 'nooutput' "Write-Output 'no report'")
    Check ($r.category -eq 'parse') 'a missing report is categorized parse'
    $r=Invoke-RealProbe (Join-Path $probeTemp 'missing.ps1')
    Check ($r.category -eq 'other') 'a missing collector is categorized other'
    Check (@(Get-ProbeSandboxes | Where-Object { $sandboxesBefore -notcontains $_ }).Count -eq 0) 'no vk-heap report folder is left behind after success, timeout, exit, parse or missing-collector failures'
    $loose=@(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'vk-heap-*.json' -ErrorAction SilentlyContinue)
    Check ($loose.Count -eq 0) 'no loose vk-heap-*.json report exists in the temp folder'
} finally {
    foreach($n in $envNames){[Environment]::SetEnvironmentVariable($n,$savedProbeEnvironment[$n])}
    if(Test-Path -LiteralPath $probeTemp){Remove-Item -LiteralPath $probeTemp -Recurse -Force -ErrorAction SilentlyContinue}
}
$policySource=Get-Content -LiteralPath (Join-Path $root 'src/FastLlm.VulkanMemoryPolicy.ps1') -Raw
Check ($policySource -notmatch 'ExecutionPolicy' -and $policySource -notmatch 'Bypass' -and $policySource -notmatch 'ReadToEndAsync') 'the probe source sets no execution policy (the child inherits it) and uses ProcessHost'
$probeBody=[regex]::Match($policySource,'(?s)function Invoke-FastLlmVulkanHeapProbe.*?\r?\n}\r?\n').Value
$doctorBody=[regex]::Match($policySource,'(?s)function Get-FastLlmVulkanMemoryDiagnostic.*?\r?\n}\r?\n').Value
$resolveBody=[regex]::Match($policySource,'(?s)function Resolve-FastLlmVulkanBarMitigation \{.*?\r?\n}\r?\n').Value+[regex]::Match($policySource,'(?s)function Resolve-FastLlmVulkanBarMitigationCore \{.*?\r?\n}\r?\n').Value
Check ($probeBody.Length -gt 500 -and $doctorBody.Length -gt 300 -and $resolveBody.Length -gt 500 -and $probeBody -notmatch 'StateRoot|Write-FastLlmState|Cache' -and $doctorBody -notmatch 'StateRoot|Write-FastLlmState|Cache|InstallRoot') 'neither the probe nor the doctor view touches the install state root or the cache'
Check (([regex]::Matches($policySource,'Add-Type -Path')).Count -eq 1 -and $policySource.Contains('Add-Type -Path @($sources)') -and $policySource -match "(?s)function Get-FastLlmNativeBootIdentity.*?Initialize-FastLlmVulkanBarNativeTypes" -and $policySource -match "(?s)function Get-FastLlmVulkanBarSleepDelta.*?Initialize-FastLlmVulkanBarNativeTypes" -and $policySource -match "(?s)function Get-FastLlmVulkanBarPnpRecords.*?Initialize-FastLlmVulkanBarNativeTypes") 'WindowsBootTime.cs and WindowsGpuIdentity.cs are compiled by ONE Add-Type -Path @(...) call shared by the boot, sleep and PnP readers'
Check (([regex]::Matches($policySource,'\[StringComparer\]::Ordinal')).Count -ge 2 -and $policySource -notmatch '\$parts \| Sort-Object' -and $policySource -notmatch '\$instances \| Sort-Object') 'PnP instance IDs and key parts are sorted ordinally (culture independent)'
$bootSource=[IO.File]::ReadAllText((Join-Path $root 'src/WindowsBootTime.cs'))
Check ($bootSource.Contains('[DllImport("api-ms-win-core-realtime-l1-1-1.dll")]') -and $bootSource.Contains('private static extern void QueryInterruptTime(out ulong interruptTime)') -and $bootSource.Contains('catch (DllNotFoundException)') -and $bootSource.Contains('EntryPointNotFoundException') -and $bootSource.Contains('"interrupt-time"') -and $bootSource.Contains('"tick-fallback"') -and $bootSource.Contains('(unchecked((long)interrupt) - unchecked((long)unbiased)) / 10000L')) 'the sleep delta is QueryInterruptTime minus QueryUnbiasedInterruptTime (100 ns), with a GetTickCount64 fallback when the API set or the export is missing, and records the path that ran'
Check (([regex]::Matches($policySource,'Write-FastLlmVulkanBarCache')).Count -eq 2 -and $resolveBody -match 'Write-FastLlmVulkanBarCache' -and $policySource -match "FastLlmVulkanBarVerifiedEngines = @\('b10698'\)") 'the per-boot cache is written only by the live-start resolver and only b10698 is verified'

# ---- doctor: default is read-only and probe-free; opt-in probes only with a Vulkan plan ----
$cliPath=Join-Path $root 'fast-llm.ps1'
function Invoke-DoctorCli([string]$InstallRoot,[string[]]$Extra,[int]$Deadline=180){
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=(Get-Process -Id $PID).Path
    $info.Arguments=& $module {param($A) Join-FastLlmProcessArguments $A} (@('-NoLogo','-NoProfile','-NonInteractive','-OutputFormat','Text','-File',$cliPath,'doctor','-InstallRoot',$InstallRoot)+$Extra)
    $info.WorkingDirectory=$root
    $host_=New-Object Bitworks.FastLlm.ProcessHost
    $watch=[Diagnostics.Stopwatch]::StartNew()
    try{
        $host_.Start($info)
        if(-not $host_.Process.WaitForExit($Deadline*1000)){throw "doctor exceeded $Deadline s"}
        while(-not $host_.OutputCompleted -and $watch.Elapsed.TotalSeconds -lt $Deadline){Start-Sleep -Milliseconds 20}
        $text=$host_.Snapshot()
        $report=$null;try{$report=ConvertFrom-Json -InputObject $text -ErrorAction Stop}catch{}
        return [pscustomobject]@{exitCode=$host_.Process.ExitCode;text=$text;report=$report;seconds=$watch.Elapsed.TotalSeconds}
    } finally {$host_.Dispose()}
}
$absentRoot=Join-Path ([IO.Path]::GetTempPath()) ('fast-llm-vkdoctor-'+[Guid]::NewGuid().ToString('N'))
$sandboxesBefore=Get-ProbeSandboxes
$defaultDoctor=Invoke-DoctorCli $absentRoot @()
Check (-not (Test-Path -LiteralPath $absentRoot)) 'an absent install root stays absent after the default doctor'
Check ($defaultDoctor.exitCode -eq 2 -and $defaultDoctor.report -and $defaultDoctor.report.vulkanMemory.rebarDetected -eq 'not-probed' -and $defaultDoctor.report.vulkanMemory.configuredPolicy -eq 'off' -and $null -eq $defaultDoctor.report.vulkanMemory.guidance -and $null -eq $defaultDoctor.report.vulkanMemory.probeStatus -and $null -eq $defaultDoctor.report.vulkanMemoryError) 'the default doctor reports the configured policy and not-probed with no BIOS text; its exit code is unchanged'
$probeDoctor=Invoke-DoctorCli $absentRoot @('-ProbeVulkanMemory')
Check (-not (Test-Path -LiteralPath $absentRoot)) 'an absent install root stays absent after the opt-in doctor'
Check ($probeDoctor.exitCode -eq 2 -and $probeDoctor.report -and $probeDoctor.report.vulkanMemory.rebarDetected -eq 'no-vulkan-plan' -and $null -eq $probeDoctor.report.vulkanMemory.guidance -and $null -eq $probeDoctor.report.vulkanMemory.probeStatus) 'the opt-in doctor without a Vulkan plan reports no-vulkan-plan and runs no probe'
Check (@(Get-ProbeSandboxes | Where-Object { $sandboxesBefore -notcontains $_ }).Count -eq 0) 'neither doctor run leaves a probe folder behind'
$startMisuseInfo=New-Object Diagnostics.ProcessStartInfo
$startMisuseInfo.FileName=(Get-Process -Id $PID).Path
$startMisuseInfo.Arguments='-NoLogo -NoProfile -NonInteractive -File "'+$cliPath+'" plan -ProbeVulkanMemory'
$startMisuseInfo.UseShellExecute=$false;$startMisuseInfo.RedirectStandardOutput=$true;$startMisuseInfo.RedirectStandardError=$true
$startMisuse=[Diagnostics.Process]::Start($startMisuseInfo)
$startMisuseOut=$startMisuse.StandardOutput.ReadToEndAsync();$startMisuseErr=$startMisuse.StandardError.ReadToEndAsync()
Check ($startMisuse.WaitForExit(60000) -and $startMisuse.ExitCode -ne 0 -and (($startMisuseOut.Result+$startMisuseErr.Result) -match 'supported only by doctor')) 'the CLI rejects -ProbeVulkanMemory for any action other than doctor'
$doctorTiming=("Doctor timing (absent root, mock environment): default {0:N1} s, opt-in {1:N1} s; worst-case real opt-in probe is bounded by its 30 s collector deadline plus up to 5 s teardown." -f $defaultDoctor.seconds,$probeDoctor.seconds)
Write-Host $doctorTiming

# ---- static guards: default path, ordering, catalog, CLI ----
$runtimeSource=Get-Content -LiteralPath (Join-Path $root 'src/FastLlm.Runtime.ps1') -Raw
# The child environment is built by Get-FastLlmEngineEnvironment (scrub, then PATH, then the BAR variable) and applied by
# Initialize-FastLlmEngineStartInfo (removals before sets), which the launch calls before it starts the child.
$envBuilderIndex=$runtimeSource.IndexOf('function Get-FastLlmEngineEnvironment')
$clearIndex=$runtimeSource.IndexOf('Test-FastLlmEnvironmentNameRequiresClearing -Name',$envBuilderIndex)
$pathIndex=$runtimeSource.IndexOf("`$set['PATH'] =",$envBuilderIndex)
$setIndex=$runtimeSource.IndexOf('$set[$script:FastLlmVulkanBarMitigationVariable] =',$envBuilderIndex)
$applyIndex=$runtimeSource.IndexOf('function Initialize-FastLlmEngineStartInfo')
$applyRemoveIndex=$runtimeSource.IndexOf('$StartInfo.EnvironmentVariables.Remove($name)',$applyIndex)
$applySetIndex=$runtimeSource.IndexOf('$StartInfo.EnvironmentVariables[[string] $name] =',$applyIndex)
$launchApplyIndex=$runtimeSource.IndexOf('Initialize-FastLlmEngineStartInfo -StartInfo $info')
$startIndex=$runtimeSource.IndexOf('$hostProcess.Start($info)')
Check ($envBuilderIndex -gt 0 -and $clearIndex -gt $envBuilderIndex -and $clearIndex -lt $pathIndex -and $pathIndex -lt $setIndex -and $setIndex -lt $applyIndex -and $applyRemoveIndex -gt $applyIndex -and $applyRemoveIndex -lt $applySetIndex -and $launchApplyIndex -gt 0 -and $launchApplyIndex -lt $startIndex) 'the mitigation variable is set after sanitisation and before the child starts'
Check ($runtimeSource.Contains("`$state.vulkanMemoryPolicy.effective -eq 'on'")) 'only the resolved effective decision can set the variable'
$readyIndex=$runtimeSource.IndexOf("Write-Host `"Ready:")
$canaryIndex=$runtimeSource.IndexOf('Invoke-FastLlmThroughputCanary -BaseUrl')
$canaryTry=$runtimeSource.LastIndexOf('try {',$canaryIndex)
Check ($readyIndex -gt 0 -and $canaryIndex -gt $readyIndex -and $canaryTry -gt $readyIndex) 'the canary runs after Ready and inside its own try block'
Check ((Get-Content -LiteralPath (Join-Path $root 'config/catalog.json') -Raw) -notmatch 'HOST_VISIBLE') 'the catalog is unchanged by the mitigation'
$catalogEngineVersion=[string](Read-FastLlmJson (Join-Path $root 'config/catalog.json')).engine.version
Check ($catalogEngineVersion -and ((& $module {@($script:FastLlmVulkanBarVerifiedEngines)}) -ccontains $catalogEngineVersion)) "the catalog engine version ($catalogEngineVersion) is in FastLlmVulkanBarVerifiedEngines: an engine bump must re-verify the mitigation or knowingly leave it skipped"
Check ($runtimeSource -notmatch 'slightly slower' -and $runtimeSource.Contains('Model load time may differ.')) 'the console wording says model load time may differ'
Check ($runtimeSource.Contains("reason -eq 'engine-not-verified'") -and $runtimeSource.Contains('has not been verified for it; no mitigation was applied')) 'a skipped on/auto prints one engine-not-verified console line'
Check ($runtimeSource.Contains("requested -eq 'auto' -and `$state.vulkanMemoryPolicy.reason -eq 'rebar-unknown-no-mitigation'") -and $runtimeSource.Contains('did not run or was inconclusive; no mitigation was applied')) 'auto with a failed or inconclusive check prints one console line; policy off prints none'
Check ($policySource -notmatch '(?i)timed\? \?out\|') 'canary timeout detection never inspects message text'
$cli=Get-Content -LiteralPath (Join-Path $root 'fast-llm.ps1') -Raw
Check ($cli -match "(?s)\[ValidateSet\('off', 'on', 'auto'\)\]\s*\[string\] \`$VulkanBarMitigation = 'auto'" -and $cli -match '\[switch\] \$ThroughputCanary' -and $cli -match '\[switch\] \$ProbeVulkanMemory') 'the CLI mitigation default is auto (owner decision 12); the canary and doctor probe stay opt-in'
Check ($cli.Contains('$startPolicyOptions.VulkanBarMitigation = $VulkanBarMitigation') -and -not $cli.Contains('ContainsKey(''VulkanBarMitigation'')) { $startPolicyOptions')) 'the CLI always forwards the mitigation policy to the start, so the auto default reaches it'
Check ($runtimeSource.Contains('Write-Host $guidance') -and $runtimeSource.Contains('$guidance = "Resizable BAR (AMD Smart Access Memory) appears to be off on this PC. FastLLM applied a workaround so models run at full speed. Turning on Resizable BAR / Smart Access Memory in your BIOS is AMD''s recommended setup and may help further. See docs/RESIZABLE-BAR.md."')) 'the exact BIOS guidance line is printed to the console when rebar-off is detected'
Check ((Get-Content -LiteralPath (Join-Path $root 'docs/RESIZABLE-BAR.md') -Raw).Contains('-VulkanBarMitigation off')) 'the Resizable BAR doc names the opt-out'
$processInfo=New-Object Diagnostics.ProcessStartInfo
$processInfo.FileName=(Get-Process -Id $PID).Path
$processInfo.Arguments='-NoLogo -NoProfile -NonInteractive -File "'+(Join-Path $root 'fast-llm.ps1')+'" plan -VulkanBarMitigation on'
$processInfo.UseShellExecute=$false;$processInfo.RedirectStandardOutput=$true;$processInfo.RedirectStandardError=$true
$child=[Diagnostics.Process]::Start($processInfo)
$childOut=$child.StandardOutput.ReadToEndAsync();$childErr=$child.StandardError.ReadToEndAsync()
$childExited=$child.WaitForExit(60000)
Check ($childExited -and $child.ExitCode -ne 0 -and (($childOut.Result+$childErr.Result) -match 'supported only by a live start')) 'the CLI rejects the mitigation switch for any action other than a live start'
Write-Host "$count Vulkan memory-policy checks passed. Mock services only; this is not hardware qualification. The CLI mitigation default is auto; the canary and doctor probe stay off. $doctorTiming"
