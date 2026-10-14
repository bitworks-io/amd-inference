#requires -Version 5.1
# Mock-only: runs on any OS. Join logic is exercised over fixture observation rows; no Vulkan, DXGI,
# D3DKMT or SetupAPI call is made.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$repo = Split-Path $PSScriptRoot -Parent
$toolPath = Join-Path $repo 'tools/collect-vulkan-luid-join.ps1'
. $toolPath -OutputPath 'unused.json' -LibraryOnly
$count = 0
function Check($condition, $message) { if (-not $condition) { throw $message }; $script:count++ }
function Reject($block, $message) { $threw = $false; try { & $block | Out-Null } catch { $threw = $true }; Check $threw $message }

# --- fixture builders (rows already in the normalized shape the wrapper produces) ---
function V($index, $luid, $vendor, $device, $name, $valid = $true, $pci = $null, $node = 1) {
    [pscustomobject]@{ index = $index; deviceLuid = $luid; deviceLuidValid = $valid; deviceNodeMask = $node; vendorId = $vendor
        deviceId = $device; deviceName = $name; pciBusInfoAdvertised = ($null -ne $pci); pciBusInfo = $pci; deviceType = 2 }
}
function D($index, $luid, $vendor, $device, $flags = 0) {
    [pscustomobject]@{ index = $index; adapterLuid = $luid; vendorId = $vendor; deviceId = $device; flags = $flags }
}
function K($luid, $bus, $dev, $fn, $err = $null) { [pscustomobject]@{ luid = $luid; bus = $bus; device = $dev; function = $fn; error = $err } }
function S($id, $loc, $ver = '32.0.31041.1004') {
    [pscustomobject]@{ instanceId = $id; locationInfo = $loc; hardwareIds = @('PCI\VEN_1002&DEV_744C'); driverVersion = $ver; driverProvider = 'AMD' }
}
$luidA = '00000000000a1b2c'; $luidB = '00000000000a1b3d'
$pnpA = 'PCI\VEN_1002&DEV_744C&SUBSYS_00000000&REV_C8\4&1&0&0008'
$pnpB = 'PCI\VEN_1002&DEV_744C&SUBSYS_00000000&REV_C8\4&1&0&0010'
function J($v, $d, $k, $s, $dxgiError = $null, $setupError = $null) {
    # Comma operator: a one-element result must stay an array for the caller under Windows PowerShell 5.1.
    , @(Join-VulkanLuidDevices -Vulkan @($v) -Dxgi @($d) -Kmt @($k) -SetupApi @($s) -DxgiError $dxgiError -SetupApiError $setupError)
}

# --- parsing helpers
Check ((ConvertFrom-VulkanLuidJoinLocation 'PCI bus 3, device 0, function 0').bus -eq 3) 'Location parse failed.'
Check ($null -eq (ConvertFrom-VulkanLuidJoinLocation 'PCI bus 256, device 0, function 0') -and
       $null -eq (ConvertFrom-VulkanLuidJoinLocation 'pci bus 3, device 0, function 0') -and
       $null -eq (ConvertFrom-VulkanLuidJoinLocation 'on PCI Express Root Port')) 'Invalid or localized location was accepted.'
Check ((ConvertFrom-VulkanLuidJoinInstanceId $pnpA).vendorId -eq 0x1002 -and $null -eq (ConvertFrom-VulkanLuidJoinInstanceId 'DISPLAY\X')) 'Instance id parse failed.'

# --- 1. unique chain
$r = J (V 0 $luidA 0x1002 0x744c 'AMD Radeon RX 9070 XT') @(D 3 $luidA 0x1002 0x744c) @(K $luidA 3 0 0) @(S $pnpA 'PCI bus 3, device 0, function 0')
Check ($r.Count -eq 1 -and $r[0].status -eq 'unique' -and $null -eq $r[0].failedHop -and $r[0].pnpInstanceId -eq $pnpA -and
       $r[0].driverVersion -eq '32.0.31041.1004' -and $r[0].dxgiAdapterIndex -eq 3 -and $r[0].kmtAddress.bus -eq 3 -and
       -not $r[0].kmtAddress.segmentKnown -and -not $r[0].pciSegmentKnown) 'Exact four-hop chain was not unique.'
Check (@('vulkan','dxgi','kmt','setupApi' | Where-Object { $r[0].hops.$_.status -eq 'ok' }).Count -eq 4) 'Not every hop recorded ok for a unique join.'

# --- 2. two identical cards, different LUIDs/BDFs (same name, vendor, device ids)
$vs = @((V 0 $luidA 0x1002 0x744c 'AMD Radeon RX 9070 XT'), (V 1 $luidB 0x1002 0x744c 'AMD Radeon RX 9070 XT'))
$ds = @((D 0 $luidB 0x1002 0x744c), (D 1 $luidA 0x1002 0x744c))   # DXGI order differs from Vulkan order
$ks = @((K $luidA 3 0 0), (K $luidB 7 0 0))
$ss = @((S $pnpA 'PCI bus 3, device 0, function 0'), (S $pnpB 'PCI bus 7, device 0, function 0'))
$r = @(Join-VulkanLuidDevices -Vulkan $vs -Dxgi $ds -Kmt $ks -SetupApi $ss)
Check ($r.Count -eq 2 -and $r[0].status -eq 'unique' -and $r[1].status -eq 'unique' -and $r[0].pnpInstanceId -eq $pnpA -and
       $r[1].pnpInstanceId -eq $pnpB -and $r[0].dxgiAdapterIndex -eq 1 -and $r[1].dxgiAdapterIndex -eq 0) 'Identical cards were not separated by LUID/BDF.'
$r = @(Join-VulkanLuidDevices -Vulkan $vs -Dxgi $ds -Kmt $ks -SetupApi @($ss[0]))
Check ($r[0].status -eq 'unique' -and $r[1].status -eq 'unavailable' -and $r[1].failedHop -eq 'setupApi' -and $null -eq $r[1].pnpInstanceId) 'Missing second PnP device was filled by guessing.'
# identical cards, one with identical LUID reported twice by Vulkan
$dup = @((V 0 $luidA 0x1002 0x744c 'X'), (V 1 $luidA 0x1002 0x744c 'X'))
$r = @(Join-VulkanLuidDevices -Vulkan $dup -Dxgi @($ds[1]) -Kmt @($ks[0]) -SetupApi @($ss[0]))
Check ($r[0].status -eq 'ambiguous' -and $r[1].status -eq 'ambiguous' -and $r[0].reason -eq 'vulkan-luid-shared-by-multiple-devices') 'Duplicate Vulkan LUID was not ambiguous.'

# --- 3. LUID invalid: never fall back to names or ids
$r = J (V 0 $null 0x1002 0x744c 'AMD Radeon RX 9070 XT' $false) (D 3 $luidA 0x1002 0x744c) (K $luidA 3 0 0) (S $pnpA 'PCI bus 3, device 0, function 0')
Check ($r[0].status -eq 'unavailable' -and $r[0].failedHop -eq 'vulkan' -and $r[0].reason -eq 'vulkan-luid-invalid' -and
       $r[0].hops.dxgi.status -eq 'skipped' -and $null -eq $r[0].pnpInstanceId) 'Invalid LUID was joined anyway.'
$r = J (V 0 'ABC' 0x1002 0x744c 'n') (D 3 $luidA 0x1002 0x744c) (K $luidA 3 0 0) (S $pnpA 'PCI bus 3, device 0, function 0')
Check ($r[0].reason -eq 'vulkan-luid-malformed') 'Malformed LUID was accepted.'
$r = J (V 0 $luidA 0x1002 0x744c 'n' $true $null 3) (D 3 $luidA 0x1002 0x744c) (K $luidA 3 0 0) (S $pnpA 'PCI bus 3, device 0, function 0')
Check ($r[0].status -eq 'ambiguous' -and $r[0].reason -eq 'vulkan-node-mask-not-single-node') 'Multi-node mask was accepted.'

# --- 4. DXGI missing
$r = @(Join-VulkanLuidDevices -Vulkan @(V 0 $luidA 0x1002 0x744c 'n') -Dxgi @() -Kmt @() -SetupApi @(S $pnpA 'PCI bus 3, device 0, function 0'))
Check ($r[0].status -eq 'unavailable' -and $r[0].failedHop -eq 'dxgi' -and $r[0].reason -eq 'dxgi-luid-not-found' -and $r[0].hops.kmt.status -eq 'skipped') 'Missing DXGI adapter did not fail at the DXGI hop.'
$r = @(Join-VulkanLuidDevices -Vulkan @(V 0 $luidA 0x1002 0x744c 'n') -Dxgi @() -Kmt @() -SetupApi @() -DxgiError 'x')
Check ($r[0].reason -eq 'dxgi-enumeration-failed') 'DXGI enumeration failure was not distinguished.'
$r = J (V 0 $luidA 0x1002 0x744c 'n') (D 3 $luidB 0x1002 0x744c) (K $luidB 3 0 0) (S $pnpA 'PCI bus 3, device 0, function 0')
Check ($r[0].reason -eq 'dxgi-luid-not-found') 'A different-LUID DXGI adapter with identical ids was joined.'
$r = @(Join-VulkanLuidDevices -Vulkan @(V 0 $luidA 0x1002 0x744c 'n') -Dxgi @((D 3 $luidA 0x1002 0x744c), (D 4 $luidA 0x1002 0x744c)) -Kmt @() -SetupApi @())
Check ($r[0].status -eq 'ambiguous' -and $r[0].reason -eq 'dxgi-luid-shared-by-multiple-adapters') 'Duplicate DXGI LUID was not ambiguous.'
$r = J (V 0 $luidA 0x1002 0x744c 'n') (D 3 $luidA 0x10de 0x744c) (K $luidA 3 0 0) (S $pnpA 'PCI bus 3, device 0, function 0')
Check ($r[0].status -eq 'ambiguous' -and $r[0].reason -eq 'vulkan-dxgi-pci-id-mismatch') 'Vulkan/DXGI vendor mismatch was joined.'

# --- 5. BDF matching two SetupAPI devices
$r = @(Join-VulkanLuidDevices -Vulkan @(V 0 $luidA 0x1002 0x744c 'n') -Dxgi @(D 3 $luidA 0x1002 0x744c) -Kmt @(K $luidA 3 0 0) `
    -SetupApi @((S $pnpA 'PCI bus 3, device 0, function 0'), (S $pnpB 'PCI bus 3, device 0, function 0')))
Check ($r[0].status -eq 'ambiguous' -and $r[0].failedHop -eq 'setupApi' -and $r[0].reason -eq 'setupapi-multiple-location-matches' -and
       $r[0].hops.setupApi.candidates -eq 2 -and $null -eq $r[0].pnpInstanceId) 'Two SetupAPI BDF matches were not ambiguous.'
$r = J (V 0 $luidA 0x1002 0x744c 'n') (D 3 $luidA 0x1002 0x744c) (K $luidA 3 0 0) (S $pnpA 'PCI bus 9, device 0, function 0')
Check ($r[0].status -eq 'unavailable' -and $r[0].reason -eq 'setupapi-no-location-match') 'No SetupAPI BDF match was not unavailable.'
$r = @(Join-VulkanLuidDevices -Vulkan @(V 0 $luidA 0x1002 0x744c 'n') -Dxgi @(D 3 $luidA 0x1002 0x744c) -Kmt @(K $luidA 3 0 0) `
    -SetupApi @((S $pnpA 'PCI bus 3, device 0, function 0'), (S $pnpB $null)))
Check ($r[0].status -eq 'ambiguous' -and $r[0].reason -eq 'setupapi-unlocated-peer-with-same-pci-ids') 'Unlocated same-ID PnP peer was ignored.'
$r = J (V 0 $luidA 0x1002 0x744c 'n') (D 3 $luidA 0x1002 0x744c) (K $luidA 3 0 0) (S 'PCI\VEN_10DE&DEV_744C&X\1' 'PCI bus 3, device 0, function 0')
Check ($r[0].status -eq 'ambiguous' -and $r[0].reason -eq 'pnp-pci-id-mismatch') 'PnP vendor mismatch was joined by address alone.'
$r = J (V 0 $luidA 0x1002 0x744c 'n') (D 3 $luidA 0x1002 0x744c) (K $luidA 3 0 0) (S $pnpA 'PCI bus 3, device 0, function 0' $null)
Check ($r[0].status -eq 'unavailable' -and $r[0].reason -eq 'driver-version-unavailable') 'Missing driver version was reported as a unique join.'
$r = J (V 0 $luidA 0x1002 0x744c 'n') (D 3 $luidA 0x1002 0x744c) (K $luidA 3 0 0) (S $pnpA 'PCI bus 3, device 0, function 0') $null 'x'
Check ($r[0].reason -eq 'setupapi-enumeration-failed') 'SetupAPI enumeration failure was not distinguished.'

# --- KMT hop and VK_EXT_pci_bus_info cross-checks
$r = J (V 0 $luidA 0x1002 0x744c 'n') (D 3 $luidA 0x1002 0x744c) (K $luidA $null $null $null 'open-adapter-ntstatus-c0000001') (S $pnpA 'PCI bus 3, device 0, function 0')
Check ($r[0].status -eq 'unavailable' -and $r[0].failedHop -eq 'kmt' -and $r[0].reason -eq 'kmt-open-adapter-ntstatus-c0000001') 'KMT failure reason was not recorded precisely.'
$r = @(Join-VulkanLuidDevices -Vulkan @(V 0 $luidA 0x1002 0x744c 'n') -Dxgi @((D 3 $luidA 0x1002 0x744c), (D 4 $luidB 0x1002 0x744c)) `
    -Kmt @((K $luidA 3 0 0), (K $luidB 3 0 0)) -SetupApi @(S $pnpA 'PCI bus 3, device 0, function 0'))
Check ($r[0].status -eq 'ambiguous' -and $r[0].reason -eq 'kmt-address-shared-with-other-adapter') 'Shared KMT address was accepted.'
$pci = [pscustomobject]@{ domain = 0; bus = 3; device = 0; function = 0 }
$r = J (V 0 $luidA 0x1002 0x744c 'n' $true $pci) (D 3 $luidA 0x1002 0x744c) (K $luidA 3 0 0) (S $pnpA 'PCI bus 3, device 0, function 0')
Check ($r[0].status -eq 'unique' -and $r[0].pciSegmentKnown) 'Agreeing advertised PCI bus info was rejected.'
$bad = [pscustomobject]@{ domain = 0; bus = 4; device = 0; function = 0 }
$r = J (V 0 $luidA 0x1002 0x744c 'n' $true $bad) (D 3 $luidA 0x1002 0x744c) (K $luidA 3 0 0) (S $pnpA 'PCI bus 3, device 0, function 0')
Check ($r[0].status -eq 'ambiguous' -and $r[0].reason -eq 'vulkan-pci-bus-info-disagrees-with-kmt') 'Disagreeing Vulkan PCI bus info was ignored.'
$r = J (V 0 $luidA 0x1002 0x744c 'n' $true $pci) (D 3 $luidA 0x1002 0x744c) (K $luidA 3 0 0) (S $pnpA 'PCI segment 2 bus 3, device 0, function 0')
Check ($r[0].status -eq 'ambiguous' -and $r[0].reason -eq 'pci-segment-mismatch') 'Conflicting PCI segment was ignored.'

# --- 6. software / WARP adapters are excluded from candidates
$warp = D 2 $luidB 0x1414 0x8c 2
$r = @(Join-VulkanLuidDevices -Vulkan @(V 0 $luidB 0x1414 0x8c 'Microsoft Basic Render Driver') -Dxgi @($warp) -Kmt @() -SetupApi @())
Check ($r[0].status -eq 'unavailable' -and $r[0].reason -eq 'dxgi-adapter-software-excluded') 'Software adapter was joined.'
Check ((Test-VulkanLuidJoinSoftwareAdapter (D 2 $luidB 0x1414 0x8c 0)) -eq 'microsoft-software-adapter-vendor' -and
       (Test-VulkanLuidJoinSoftwareAdapter (D 2 $luidB 0x1002 0x1 2)) -eq 'dxgi-software-flag' -and
       $null -eq (Test-VulkanLuidJoinSoftwareAdapter (D 2 $luidA 0x1002 0x744c 0))) 'Software adapter detection is wrong.'
$real = D 3 $luidA 0x1002 0x744c
$r = @(Join-VulkanLuidDevices -Vulkan @((V 0 $luidA 0x1002 0x744c 'n'), (V 1 $luidB 0x1414 0x8c 'WARP')) -Dxgi @($warp, $real) `
    -Kmt @(K $luidA 3 0 0) -SetupApi @(S $pnpA 'PCI bus 3, device 0, function 0'))
Check ($r[0].status -eq 'unique' -and $r[1].status -eq 'unavailable' -and $r[1].reason -eq 'dxgi-adapter-software-excluded') 'WARP exclusion disturbed the hardware join.'
Check (@(Join-VulkanLuidDevices -Vulkan @() -Dxgi @() -Kmt @() -SetupApi @()).Count -eq 0) 'Empty snapshot produced rows.'
Reject { Join-VulkanLuidDevices -Vulkan @(1..65) -Dxgi @() -Kmt @() -SetupApi @() } 'Oversized snapshot was not rejected.'

# --- output path refusals
$base = $null
if ($env:OS -ne 'Windows_NT' -and (Test-Path -LiteralPath '/private/tmp' -PathType Container)) { $base = '/private/tmp' } else { $base = [IO.Path]::GetTempPath() }
$work = Join-Path $base ('vulkan-luid-join-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    Reject { Assert-VulkanLuidJoinOutputPath 'relative.json' } 'Relative output path was accepted.'
    Reject { Assert-VulkanLuidJoinOutputPath '' } 'Empty output path was accepted.'
    Reject { Assert-VulkanLuidJoinOutputPath (Join-Path $work 'report.txt') } 'Non-.json output path was accepted.'
    Reject { Assert-VulkanLuidJoinOutputPath (Join-Path (Join-Path $work 'missing') 'report.json') } 'Missing parent directory was accepted.'
    $existing = Join-Path $work 'existing.json'
    [IO.File]::WriteAllText($existing, '{}')
    Reject { Assert-VulkanLuidJoinOutputPath $existing } 'Existing file was not refused.'
    Reject { Assert-VulkanLuidJoinOutputPath $work } 'Directory output path was accepted.'
    $linkTarget = Join-Path $work 'real'; New-Item -ItemType Directory -Path $linkTarget | Out-Null
    $link = Join-Path $work 'link'
    $linked = $false
    try { New-Item -ItemType SymbolicLink -Path $link -Target $linkTarget -ErrorAction Stop | Out-Null; $linked = $true } catch { }
    if ($linked) { Reject { Assert-VulkanLuidJoinOutputPath (Join-Path $link 'report.json') } 'Reparse-point parent was accepted.' }
    else { Write-Host 'SKIP: symbolic link creation unavailable; reparse refusal not exercised.' }

    # --- schema shape, written once, never overwritten
    $report = New-VulkanLuidJoinReport -Devices @(V 0 $luidA 0x1002 0x744c 'n') -DxgiAdapters @(D 3 $luidA 0x1002 0x744c) `
        -KmtAddresses @(K $luidA 3 0 0) -SetupApiDevices @(S $pnpA 'PCI bus 3, device 0, function 0') `
        -Joins (J (V 0 $luidA 0x1002 0x744c 'n') (D 3 $luidA 0x1002 0x744c) (K $luidA 3 0 0) (S $pnpA 'PCI bus 3, device 0, function 0')) `
        -HostName 'bench-host' -SourceSha256 @{ 'src/x.cs' = ('a' * 64) } -CollectionErrors @{ vulkan = $null; dxgi = $null; setupApi = $null } `
        -DedicatedGpuCount 1 -Now ([datetime]'2026-10-06T00:00:00Z')
    $out = Join-Path $work 'report.json'
    $written = Write-VulkanLuidJoinReport -Report $report -Path $out
    Check ($written -eq [IO.Path]::GetFullPath($out) -and (Test-Path -LiteralPath $out)) 'Report was not written.'
    Reject { Write-VulkanLuidJoinReport -Report $report -Path $out } 'Second write overwrote an existing report.'
    $doc = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
    Check ($doc.schema -ceq 'fastllm.vulkan-luid-join.v1') 'Schema id differs.'
    foreach ($name in @('recordedAtUtc', 'hostName', 'devices', 'dxgiAdapters', 'setupApiDisplayDevices', 'joins', 'sameProcessAsServer',
                        'servingDeviceBound', 'qualified', 'defaultSelection', 'joinSummary', 'collector', 'collectionErrors')) {
        Check ($null -ne $doc.PSObject.Properties[$name]) ('Report lacks ' + $name + '.')
    }
    Check ($doc.sameProcessAsServer -eq $false -and $doc.servingDeviceBound -eq $false -and $doc.qualified -eq $false -and
           $doc.sameProcessAsServer -is [bool] -and $doc.servingDeviceBound -is [bool] -and $doc.qualified -is [bool]) 'Binding/qualification flags are not literal false.'
    Check (@($doc.devices).Count -eq 1 -and @($doc.joins).Count -eq 1 -and $doc.joins[0].status -ceq 'unique' -and
           $doc.joinSummary.unique -eq 1 -and $doc.defaultSelection.dedicatedGpuCount -eq 1 -and $doc.hostName -ceq 'bench-host') 'Report content shape differs.'
    Check ((Get-Content -LiteralPath $out -Raw) -match '"recordedAtUtc":\s*"2026-10-06T00:00:00\.0000000Z"') 'recordedAtUtc not UTC ISO-8601.'
    Check (@(Get-ChildItem -LiteralPath $work -File | Where-Object { $_.Name -like '*.tmp' }).Count -eq 0) 'Temporary files were left behind.'
} finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }

# --- memory budget normalization (fixtures mimic the native record shape)
function Seg($group, $status, $hr, $b = 0, $u = 0, $a = 0, $r = 0) {
    [pscustomobject]@{ Group = $group; Status = $status; Hresult = $hr; Budget = [uint64]$b; CurrentUsage = [uint64]$u
        AvailableForReservation = [uint64]$a; CurrentReservation = [uint64]$r }
}
function Heap($i, $size, $flags, $budget, $usage) {
    [pscustomobject]@{ HeapIndex = $i; Size = [uint64]$size; Flags = [uint32]$flags; DeviceLocal = (($flags -band 1) -ne 0); HeapBudget = [uint64]$budget; HeapUsage = [uint64]$usage }
}
$big = [uint64]17163091968
$sample = [pscustomobject]@{
    TimestampUtc = '2026-10-06T10:00:00.0000000Z'; DxgiError = $null; VulkanError = $null
    Dxgi = @(
        [pscustomobject]@{ AdapterIndex = 0; AdapterLuid = $luidA; TimestampUtc = '2026-10-06T10:00:00.1000000Z'; Adapter3Status = 'ok'; Adapter3Hresult = '00000000'
            Local = (Seg 'LOCAL' 'ok' '00000000' $big 1048576 $big 0); NonLocal = (Seg 'NON_LOCAL' 'query-failed' '80070057') },
        [pscustomobject]@{ AdapterIndex = 1; AdapterLuid = $luidB; TimestampUtc = '2026-10-06T10:00:00.2000000Z'; Adapter3Status = 'adapter3-unavailable'; Adapter3Hresult = '80004002'
            Local = $null; NonLocal = $null })
    Vulkan = @(
        [pscustomobject]@{ Index = 0; DeviceUuid = 'u0'; DeviceLuid = $luidA; TimestampUtc = '2026-10-06T10:00:00.3000000Z'; MemoryBudgetAdvertised = $true; Status = 'ok'
            Heaps = @((Heap 0 $big 1 15000000000 2097152), (Heap 1 8589934592 0 8000000000 0)) },
        [pscustomobject]@{ Index = 1; DeviceUuid = 'u1'; DeviceLuid = $luidB; TimestampUtc = '2026-10-06T10:00:00.4000000Z'; MemoryBudgetAdvertised = $false
            Status = 'memory-budget-not-advertised'; Heaps = @() })
}
$initial = @([pscustomobject]@{ index = 0; deviceUuid = 'u0'; deviceLuid = $luidA }, [pscustomobject]@{ index = 1; deviceUuid = 'uX'; deviceLuid = $luidB })
$b = ConvertTo-VulkanLuidJoinBudgetSample -Sample $sample -SampleIndex 2 -InitialVulkanRows $initial
Check ($b.sampleIndex -eq 2 -and $b.timestampUtc -eq '2026-10-06T10:00:00.0000000Z' -and @($b.dxgi).Count -eq 2 -and @($b.vulkan).Count -eq 2) 'Budget sample shape differs.'
Check ($b.dxgi[0].local.budgetBytes -eq $big -and $b.dxgi[0].local.currentUsageBytes -eq 1048576 -and $b.dxgi[0].local.availableForReservationBytes -eq $big -and
       $b.dxgi[0].local.currentReservationBytes -eq 0 -and $b.dxgi[0].local.status -eq 'ok' -and $b.dxgi[0].timestampUtc -like '*.1000000Z') 'DXGI LOCAL budget bytes were not preserved above 32 bits.'
Check ($b.dxgi[0].nonLocal.status -eq 'query-failed' -and $b.dxgi[0].nonLocal.hresult -eq '80070057' -and $null -eq $b.dxgi[0].nonLocal.budgetBytes) 'Failed NON_LOCAL query was reported with numbers.'
Check ($b.dxgi[1].adapter3Status -eq 'adapter3-unavailable' -and $b.dxgi[1].adapter3Hresult -eq '80004002' -and $null -eq $b.dxgi[1].local -and $null -eq $b.dxgi[1].nonLocal) 'Missing IDXGIAdapter3 was not recorded with its HRESULT.'
Check ($b.vulkan[0].status -eq 'ok' -and @($b.vulkan[0].heaps).Count -eq 2 -and $b.vulkan[0].heaps[0].deviceLocal -and -not $b.vulkan[0].heaps[1].deviceLocal -and
       $b.vulkan[0].heaps[0].sizeBytes -eq $big -and $b.vulkan[0].heaps[0].heapBudgetBytes -eq 15000000000 -and $b.vulkan[0].heaps[0].heapUsageBytes -eq 2097152 -and
       $b.vulkan[0].heaps[0].heapIndex -eq 0 -and $b.vulkan[0].heaps[1].flags -eq 0) 'Vulkan heap budget parsing differs.'
Check ($b.vulkan[1].status -eq 'memory-budget-not-advertised' -and -not $b.vulkan[1].memoryBudgetAdvertised -and @($b.vulkan[1].heaps).Count -eq 0) 'Missing VK_EXT_memory_budget was not recorded without heap numbers.'
Check ($b.vulkan[0].identityMatchesInitialEnumeration -eq $true -and $b.vulkan[1].identityMatchesInitialEnumeration -eq $false) 'Repeat identity cross-check differs.'
$b2 = ConvertTo-VulkanLuidJoinBudgetSample -Sample $sample -SampleIndex 0
Check ($null -eq $b2.vulkan[0].identityMatchesInitialEnumeration) 'Identity cross-check claimed a result without an initial snapshot.'

# --- repeat bounds
foreach ($pair in @(@(0, 1000), @(61, 1000), @(1, 499), @(1, 10001), @(-1, 1000))) {
    $c = $pair[0]; $i = $pair[1]
    Reject { Assert-VulkanLuidJoinRepeatOptions -Count $c -IntervalMs $i } ('Out-of-range repeat options accepted: ' + $c + ',' + $i)
}
foreach ($pair in @(@(1, 500), @(60, 10000), @(10, 1000))) {
    $c = $pair[0]; $i = $pair[1]
    Assert-VulkanLuidJoinRepeatOptions -Count $c -IntervalMs $i; $count++
}
$parameters = (Get-Command $toolPath).Parameters
$rc = @($parameters['RepeatCount'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] })[0]
$ri = @($parameters['RepeatIntervalMs'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] })[0]
Check ($rc.MinRange -eq 1 -and $rc.MaxRange -eq 60 -and $ri.MinRange -eq 500 -and $ri.MaxRange -eq 10000) 'Script parameter ranges differ.'
Check ($RepeatCount -eq 1 -and $RepeatIntervalMs -eq 1000) 'Dot-sourced defaults differ (RepeatCount 1).'
$selfExe = (Get-Process -Id $PID).Path
foreach ($bad in @(@('-RepeatCount', '0'), @('-RepeatCount', '61'), @('-RepeatIntervalMs', '499'), @('-RepeatIntervalMs', '10001'))) {
    # Windows PowerShell 5.1 turns native stderr into a terminating error under Stop; the exit code is what is checked.
    $savedPreference = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $null = & $selfExe -NoLogo -NoProfile -File $toolPath -OutputPath '/nonexistent/x.json' $bad[0] $bad[1] 2>&1 } finally { $ErrorActionPreference = $savedPreference }
    Check ($LASTEXITCODE -ne 0) ('Wrapper accepted ' + $bad[0] + ' ' + $bad[1])
}
$rep = New-VulkanLuidJoinReport -Devices @() -DxgiAdapters @() -KmtAddresses @() -SetupApiDevices @() -Joins @() -HostName 'h' `
    -SourceSha256 @{} -CollectionErrors @{} -BudgetSamples @($b) -RepeatCount 3 -RepeatIntervalMs 750
$repDoc = ($rep | ConvertTo-Json -Depth 12) | ConvertFrom-Json
Check ($repDoc.repeat.count -eq 3 -and $repDoc.repeat.intervalMs -eq 750 -and @($repDoc.budgetSamples).Count -eq 1 -and
       $repDoc.budgetSamples[0].dxgi[0].local.budgetBytes -eq 17163091968) 'Report repeat/budget fields differ.'
Check ($repDoc.note -match 'THIS probe process' -and $repDoc.note -match 'not per-process attribution' -and $repDoc.note -match 'not proof of which allocations are resident' -and
       $repDoc.note -match 'indirect, adapter-level occupancy signal') 'Report note lacks the budget semantics statement.'

# --- static checks on the native source and the wrapper
$cs = Get-Content -LiteralPath (Join-Path $repo 'src/WindowsVulkanLuidJoin.cs') -Raw
$tool = Get-Content -LiteralPath $toolPath -Raw
Check ($cs.Contains('LoadLibraryExW') -and $cs.Contains('LOAD_LIBRARY_SEARCH_SYSTEM32 = 0x800') -and
       $cs.Contains('LoadLibraryExW(loaderPath, IntPtr.Zero, LOAD_LIBRARY_SEARCH_SYSTEM32)') -and
       $cs.Contains('GetSystemDirectoryW') -and $cs.Contains('vulkan-loader-provenance-mismatch')) 'vulkan-1.dll is not loaded via System32 search flag with provenance check.'
Check ([regex]::Matches($cs, 'LoadLibrary\w*\(').Count -eq 2 -and $cs -notmatch 'DllImport\("vulkan' -and
       $cs -notmatch 'LoadLibrary(?!ExW)\w*\(' -and $cs -notmatch 'NativeLibrary') 'Another library-loading path exists in the native source.'
Check (@([regex]::Matches($cs, '"vulkan-1\.dll"')).Count -eq 1) 'vulkan-1.dll must be named exactly once.'
Check ($cs -notmatch 'vkCreateDevice' -and $cs -notmatch 'vkQueue' -and $cs -notmatch 'vkAllocateMemory') 'Native source creates a logical device or allocates device memory.'
Check ($cs.Contains('vkGetPhysicalDeviceFeatures2') -and $cs.Contains('1000059000') -and $cs.Contains('1000083000') -and $cs.Contains('TryFunction<GetPhysicalDeviceFeatures2>') -and
       $cs.Contains('features-query-failed') -and $cs.Contains('ReadStorageBuffer16BitAccess(features2, dev, record)')) '16-bit storage query is not a non-throwing, per-device feature read.'
Check ($cs.Contains('vkDestroyInstance') -and $cs.Contains('destroy(instance, IntPtr.Zero)') -and $cs.Contains('enabledLayerCount') -and
       $cs -notmatch 'enabledLayerCount\s*=' -and $cs -notmatch 'enabledExtensionCount\s*=') 'Instance is not destroyed or enables layers/extensions.'
Check ($cs.Contains('DllImportSearchPath.System32') -and $cs.Contains('CreateDXGIFactory1') -and $cs.Contains('VtableSlot(factory, 12)') -and
       $cs.Contains('VtableSlot(adapter, 10)')) 'DXGI vtable pattern is not restricted to System32 or slots changed.'
Check ($cs.Contains('VK_EXT_memory_budget') -and $cs.Contains('vkGetPhysicalDeviceMemoryProperties2') -and $cs.Contains('1000237000') -and
       $cs.Contains('VtableSlot(adapter3, 14)') -and $cs.Contains('645967a4-1392-4310-a798-8053ce3e93fd') -and $cs -notmatch 'vkCreateDevice') 'Budget probe layout/entrypoints differ or create a device.'
foreach ($forbidden in @('Start-Process', 'Stop-Process', 'Stop-Service', 'Start-Service', 'SetEnvironmentVariable', 'Invoke-Expression', 'Invoke-WebRequest')) {
    Check (-not $tool.Contains($forbidden)) ('Wrapper uses ' + $forbidden + '.')
}
Check ($tool -notmatch '\$env:\w+\s*=' -and $tool -notmatch '\[Diagnostics\.Process\]' -and $tool -notmatch 'ProcessStartInfo' -and
       $tool -notmatch 'Process\]::Start') 'Wrapper sets an environment variable or starts a process.'
Check ($tool -notmatch '\?\?' -and $tool -notmatch '\s\?\s' -and $tool -notmatch '\[short\]' -and $tool -notmatch '\?\.') 'Wrapper uses PowerShell 7-only syntax.'
Check ($tool.Contains('IsInRole') -and $tool.Contains('Is64BitProcess') -and $tool.Contains('Windows_NT') -and $tool.Contains('CreateNew') -and
       $tool.Contains('ReparsePoint') -and $tool.Contains('fastllm.vulkan-luid-join.v1')) 'Wrapper guards or schema id missing.'

# --- native source compiles; non-Windows hosts are rejected before any native call
Add-Type -Path @((Join-Path $repo 'src/WindowsVulkanLuidJoin.cs'), (Join-Path $repo 'src/WindowsPciAddress.cs')) -ErrorAction Stop
$native = [Bitworks.FastLlm.WindowsVulkanLuidJoin]
Check ($native::FormatLuid([byte[]](0x2c, 0x1b, 0x0a, 0, 1, 0, 0, 0)) -ceq '000000010 00a1b2c'.Replace(' ', '')) 'LUID formatting is not high-then-low.'
Check ($native::FormatUuid([byte[]](0..15)) -ceq '00010203-0405-0607-0809-0a0b0c0d0e0f') 'UUID formatting differs.'
Check ($native::FormatApiVersion(0x00401000) -ceq '1.1.0' -and $native::DeviceTypeName(2) -ceq 'discrete' -and $native::DeviceTypeName(1) -ceq 'integrated' -and
       $native::DeviceTypeName(4) -ceq 'cpu' -and $native::DeviceTypeName(99) -ceq 'unknown') 'Decoding helpers differ.'

# --- storageBuffer16BitAccess (producer v-next.2): additive, typed null reasons, nothing escapes the device read
Check ($null -eq $native::StorageBuffer16BitUnavailableReason($true, 0x00401000) -and $null -eq $native::StorageBuffer16BitUnavailableReason($true, 0x00402000)) 'A Vulkan 1.1+ device with the entry point must be queried.'
Check ($native::StorageBuffer16BitUnavailableReason($true, 0x00400fff) -ceq 'vulkan-1.1-unavailable' -and $native::StorageBuffer16BitUnavailableReason($true, 0) -ceq 'vulkan-1.1-unavailable' -and
       $native::StorageBuffer16BitUnavailableReason($false, 0x00400000) -ceq 'vulkan-1.1-unavailable') 'A device below Vulkan 1.1 must give the vulkan-1.1-unavailable reason.'
Check ($native::StorageBuffer16BitUnavailableReason($false, 0x00401000) -ceq 'features2-entrypoint-unavailable') 'A missing vkGetPhysicalDeviceFeatures2 must give its own reason.'
$sbRecord = New-Object Bitworks.FastLlm.VulkanLuidDeviceRecord
$sbRecord.Index = 0; $sbRecord.DeviceName = 'fixture'; $sbRecord.StorageBuffer16BitAccess = $true
$sbRow = ConvertTo-VulkanLuidJoinVulkanRow -Device $sbRecord
Check ($sbRow.storageBuffer16BitAccess -eq $true -and $null -eq $sbRow.storageBuffer16BitAccessReason) 'A readable storageBuffer16BitAccess must reach the row.'
$sbRecord.StorageBuffer16BitAccess = $null; $sbRecord.StorageBuffer16BitAccessReason = 'vulkan-1.1-unavailable'
$sbRowNull = ConvertTo-VulkanLuidJoinVulkanRow -Device $sbRecord
Check ($null -eq $sbRowNull.storageBuffer16BitAccess -and $sbRowNull.storageBuffer16BitAccessReason -ceq 'vulkan-1.1-unavailable') 'An unreadable storageBuffer16BitAccess must be null with its typed reason.'
$sbKeys = @($sbRow.PSObject.Properties | ForEach-Object Name)
$oldKeys = @('index','deviceUuid','driverUuid','deviceLuid','deviceLuidValid','deviceNodeMask','vendorId','deviceId','deviceName','driverVersionRaw','apiVersionRaw','apiVersion',
    'deviceType','deviceTypeName','driverPropertiesAdvertised','driverId','driverName','driverInfo','pciBusInfoAdvertised','pciBusInfo','extensionError')
Check ((($sbKeys | Select-Object -First $oldKeys.Count) -join ',') -ceq ($oldKeys -join ',') -and (($sbKeys | Select-Object -Skip $oldKeys.Count) -join ',') -ceq 'storageBuffer16BitAccess,storageBuffer16BitAccessReason') 'The new fields must be appended after every existing row field.'
# The join ignores the new fields: iGPU-first APU, identical pair and duplicate-LUID (Dozen) shapes with the fields present join as before.
function V16($index, $luid, $vendor, $device, $name, $type, $sb16) {
    $row = V $index $luid $vendor $device $name; $row.deviceType = $type
    $row | Add-Member -NotePropertyName storageBuffer16BitAccess -NotePropertyValue $sb16; $row | Add-Member -NotePropertyName storageBuffer16BitAccessReason -NotePropertyValue $null
    $row
}
$apu = @(Join-VulkanLuidDevices -Vulkan @((V16 0 $luidA 0x1002 0x164e 'AMD Radeon Graphics' 1 $true), (V16 1 $luidB 0x1002 0x744c 'AMD Radeon RX 7900 XTX' 2 $true)) `
    -Dxgi @((D 0 $luidA 0x1002 0x164e), (D 1 $luidB 0x1002 0x744c)) -Kmt @((K $luidA 14 0 0), (K $luidB 3 0 0)) `
    -SetupApi @((S 'PCI\VEN_1002&DEV_164E&SUBSYS_00000000&REV_C1\4&1&0&0009' 'PCI bus 14, device 0, function 0'), (S $pnpA 'PCI bus 3, device 0, function 0')))
Check ($apu.Count -eq 2 -and $apu[0].status -eq 'unique' -and $apu[1].status -eq 'unique' -and $apu[0].vulkanIndex -eq 0 -and $apu[1].vulkanIndex -eq 1) 'The iGPU-first APU shape must join unchanged with the new fields present.'
$pair = @(Join-VulkanLuidDevices -Vulkan @((V16 0 $luidA 0x1002 0x744c 'AMD Radeon RX 7900 XTX' 2 $true), (V16 1 $luidB 0x1002 0x744c 'AMD Radeon RX 7900 XTX' 2 $true)) -Dxgi @((D 0 $luidB 0x1002 0x744c), (D 1 $luidA 0x1002 0x744c)) `
    -Kmt @((K $luidA 3 0 0), (K $luidB 7 0 0)) -SetupApi @((S $pnpA 'PCI bus 3, device 0, function 0'), (S $pnpB 'PCI bus 7, device 0, function 0')))
Check ($pair.Count -eq 2 -and $pair[0].status -eq 'unique' -and $pair[1].status -eq 'unique' -and $pair[0].pnpInstanceId -eq $pnpA -and $pair[1].pnpInstanceId -eq $pnpB) 'The identical-pair shape must join unchanged with the new fields present.'
$dozen = @(Join-VulkanLuidDevices -Vulkan @((V16 0 $luidA 0x1002 0x744c 'AMD Radeon RX 7900 XTX' 2 $true), (V16 1 $luidA 0x1002 0x744c 'Microsoft Direct3D12 (AMD Radeon RX 7900 XTX)' 2 $false)) `
    -Dxgi @((D 0 $luidA 0x1002 0x744c)) -Kmt @((K $luidA 3 0 0)) -SetupApi @((S $pnpA 'PCI bus 3, device 0, function 0')))
Check ($dozen.Count -eq 2 -and $dozen[0].status -eq 'ambiguous' -and $dozen[1].status -eq 'ambiguous' -and $dozen[0].reason -eq 'vulkan-luid-shared-by-multiple-devices') 'The duplicate-LUID (Dozen) shape must stay ambiguous with the new fields present (shared-LUID unique hop is deferred).'
if ($env:OS -ne 'Windows_NT') {
    Reject { $native::Collect() } 'Native collection must reject non-Windows hosts.'
    # The wrapper itself must fail closed on a non-Windows host without creating output.
    $probeOut = Join-Path $base ('vulkan-luid-join-refusal-' + [guid]::NewGuid().ToString('N') + '.json')
    $self = (Get-Process -Id $PID).Path
    $stderr = & $self -NoLogo -NoProfile -File $toolPath -OutputPath $probeOut 2>&1
    Check ($LASTEXITCODE -eq 1 -and -not (Test-Path -LiteralPath $probeOut) -and (($stderr | Out-String) -match 'requires 64-bit Windows')) 'Wrapper did not fail closed on non-Windows.'
    Write-Host 'SKIP: live Vulkan/DXGI/D3DKMT/SetupAPI calls require Windows.'
}
Write-Host "$count Vulkan LUID join checks passed; no serving-process binding or qualification is claimed."
