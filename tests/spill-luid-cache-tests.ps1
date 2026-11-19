#requires -Version 5.1
# The private per-boot cache of the card's adapter LUID (GPU memory check, Vulkan on Windows). Everything is mocked at the module's
# replaceable seams (platform, boot identity, sleep delta, source hashes, the collection call), so nothing here needs Windows or a GPU.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force
$module = Get-Module FastLlm
. (Join-Path $root 'src/FastLlm.SupportBundle.ps1')
$script:count = 0
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; $script:count++ }
function InModule([scriptblock]$Block, [object[]]$Arguments = @()) { & $module $Block @Arguments }

$fakeLuid = '0123456789abcdef'
$freshLuid = 'fedcba9876543210'
$bootA = '2026-11-19T01:00:00.0000000Z'
$bootLater = '2026-11-19T01:02:00.0000000Z'
$shaA = ('a' * 64)
$shaB = ('b' * 64)
$cacheName = 'spill-luid-boot-cache.json'
$plan = [pscustomobject]@{ backend = 'vulkan'; selectedAdapters = @([pscustomobject]@{ name = 'AMD Radeon Test Card'; device = 'Vulkan0'; vramMiB = 16384 }) }
$planOther = [pscustomobject]@{ backend = 'vulkan'; selectedAdapters = @([pscustomobject]@{ name = 'AMD Radeon Other Card'; device = 'Vulkan0'; vramMiB = 16384 }) }
$self = [Diagnostics.Process]::GetCurrentProcess()
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('fastllm-luidcache-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
function New-Root { $r = Join-Path $scratch ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $r -Force | Out-Null; return $r }
function CachePath($Root) { Join-Path (Join-Path $Root 'state') $cacheName }

# Install the seams once (module scope); every test sets the mock state in $script:T and restores nothing until the end.
$originals = InModule {
    param($shaA)
    $names = @('Test-FastLlmSpillIsWindows', 'Get-FastLlmSpillBootIdentity', 'Get-FastLlmSpillSleepDelta', 'Get-FastLlmSpillLuidSourceHashes', 'Invoke-FastLlmSpillLuidCollection')
    $saved = @{}
    foreach ($n in $names) { $saved[$n] = (Get-Command $n).ScriptBlock }
    # The mocks run later, from module functions: they may only read module-scope state. A parameter of THIS block ($shaA) is gone by then,
    # and it only seemed to resolve when the suite ran with -File (whose top level is the global scope); run from another script (the CI
    # step wrapper) the read failed under StrictMode and the product's catch returned no LUID.
    $script:LuidCacheTestDefaultSha = $shaA
    function script:Test-FastLlmSpillIsWindows { return [bool] $script:T.windows }
    function script:Get-FastLlmSpillBootIdentity { return $script:T.boot }
    function script:Get-FastLlmSpillSleepDelta { return $script:T.sleep }
    function script:Get-FastLlmSpillLuidSourceHashes { return $script:T.hashes }
    function script:Invoke-FastLlmSpillLuidCollection {
        param($Plan, [string] $InstallRoot, $BarDecision)
        $script:T.collections++
        if ($script:T.probePath) { $script:T.existedAtCollect = [bool] (Test-Path -LiteralPath $script:T.probePath) }
        $next = $null
        if ($script:T.luids.Count -gt 0) { $next = $script:T.luids[0]; $script:T.luids = @($script:T.luids | Select-Object -Skip 1) }
        $h = $script:T.hashes
        $hs = $script:LuidCacheTestDefaultSha; $hj = $script:LuidCacheTestDefaultSha
        if ($h) { $hs = $h.script; $hj = $h.join }
        return [pscustomobject]@{ luid = $next; record = [pscustomobject]@{ collector = [pscustomobject]@{ scriptSha256 = $hs; joinSourceSha256 = $hj } } }
    }
    return $saved
} @($shaA)
function Set-Mock($Boot = $bootA, $Sleep = 1000, $ShaScript = $shaA, $ShaJoin = $shaA, $Luids = @($fakeLuid), [bool]$Windows = $true) {
    InModule { param($b, $s, $a, $j, $l, $w) $script:T = @{ windows = $w; boot = $b; sleep = $s; hashes = [pscustomobject]@{ script = $a; join = $j }; luids = @($l); collections = 0; probePath = $null; existedAtCollect = $null } } @($Boot, $Sleep, $ShaScript, $ShaJoin, $Luids, $Windows)
}
function Collections { InModule { [int] $script:T.collections } }
function Get-Luid($Root, $P = $plan, $Known = $null) {
    InModule { param($p, $r, $k) Get-FastLlmSpillCheckLuid -Plan $p -InstallRoot $r -KnownLuid $k -BarDecision $null } @($P, $Root, $Known)
}
function Get-Source($Root, $P = $plan) {
    InModule { param($p, $r) $f = @{}; $l = Get-FastLlmSpillCheckLuid -Plan $p -InstallRoot $r -KnownLuid $null -BarDecision $null -Found $f; [pscustomobject]@{ luid = $l; source = $f['luidSource'] } } @($P, $Root)
}
function Write-CacheText($Root, [string]$Text) {
    New-Item -ItemType Directory -Path (Join-Path $Root 'state') -Force | Out-Null
    [IO.File]::WriteAllText((CachePath $Root), $Text)
}
function Good-Entry([hashtable]$Override = @{}) {
    $e = [ordered]@{ schemaVersion = 1; kind = 'fastllm-spill-luid'; bootUtc = $bootA; bootTimeSource = 'native'; sleepDeltaMs = 1000; adapterKey = 'amd radeon test card|vulkan0|16384'; luid = $fakeLuid; collectorSha256 = $shaA; joinSourceSha256 = $shaA }
    foreach ($k in $Override.Keys) { if ($null -eq $Override[$k] -and $k -like '-*') { $e.Remove($k.Substring(1)) } else { $e[$k] = $Override[$k] } }
    return ($e | ConvertTo-Json -Compress)
}

try {
    # ---- 1. same boot: the second start runs zero collections ----
    $r1 = New-Root
    Set-Mock
    $first = Get-Source $r1
    $firstCollections = Collections
    Check ($first.luid -ceq $fakeLuid -and $first.source -ceq 'collected' -and $firstCollections -eq 1) ("a cache miss collects once and reports the source as collected (observed: luid=$($first.luid) source=$($first.source) collections=$firstCollections cacheFile=$(Test-Path -LiteralPath (CachePath $r1)))")
    Check (Test-Path -LiteralPath (CachePath $r1) -PathType Leaf) 'the first collection writes the cache file'
    $entry = Get-Content -LiteralPath (CachePath $r1) -Raw | ConvertFrom-Json
    Check ((($entry.PSObject.Properties.Name | Sort-Object) -join ',') -ceq 'adapterKey,bootTimeSource,bootUtc,collectorSha256,joinSourceSha256,kind,luid,schemaVersion,sleepDeltaMs' -and $entry.kind -ceq 'fastllm-spill-luid' -and $entry.schemaVersion -eq 1 -and $entry.bootTimeSource -ceq 'native' -and $entry.luid -ceq $fakeLuid) 'the entry has exactly the specified fields'
    Set-Mock -Luids @($freshLuid)
    $second = Get-Source $r1
    Check ($second.luid -ceq $fakeLuid -and $second.source -ceq 'cache' -and (Collections) -eq 0) 'the second start in the same boot runs 0 collections and returns the same LUID'
    Set-Mock -Boot '2026-11-19T01:00:59.0000000Z' -Luids @($freshLuid)
    Check ((Get-Luid $r1) -ceq $fakeLuid -and (Collections) -eq 0) 'a boot instant within the 60 second tolerance still hits'
    Set-Mock -Sleep 1100 -Luids @($freshLuid)
    Check ((Get-Luid $r1) -ceq $fakeLuid -and (Collections) -eq 0) 'sleep delta growth within the tolerance still hits'

    # ---- 2. a different boot: collect again, the old file is deleted first, then a new one written ----
    Set-Mock -Boot $bootLater -Luids @($freshLuid)
    # Observe the deletion: the collection seam checks that the old file is gone before it runs.
    InModule { param($pp) $script:T.probePath = $pp; $script:T.existedAtCollect = $null } @((CachePath $r1))
    $beforeBytes = [IO.File]::ReadAllText((CachePath $r1))
    $gotLater = Get-Luid $r1
    Check ($gotLater -ceq $freshLuid -and (Collections) -eq 1) 'a different boot (120 s later) collects again'
    $afterEntry = Get-Content -LiteralPath (CachePath $r1) -Raw | ConvertFrom-Json
    Check ((InModule { $script:T.existedAtCollect }) -eq $false) 'the old other-boot file was deleted BEFORE the new collection and write'
    Check ($afterEntry.luid -ceq $freshLuid -and [IO.File]::ReadAllText((CachePath $r1)) -cne $beforeBytes) 'the new entry replaced the old one'
    $r2 = New-Root
    Write-CacheText $r2 (Good-Entry @{ bootUtc = $bootA })
    Set-Mock -Boot $bootLater -Luids @() # the collection yields no LUID, so nothing new is written
    $null = Get-Luid $r2
    Check ((Collections) -eq 1 -and -not (Test-Path -LiteralPath (CachePath $r2))) 'an ignored (other boot) entry is deleted even when the new collection writes nothing'

    # ---- 3. sleep growth beyond the tolerance ----
    $r3 = New-Root
    Write-CacheText $r3 (Good-Entry)
    Set-Mock -Sleep 7000 -Luids @($freshLuid)
    Check ((Get-Luid $r3) -ceq $freshLuid -and (Collections) -eq 1) 'sleep or hibernation since the write (delta grew beyond 5 s) collects again'
    $r3b = New-Root
    Write-CacheText $r3b (Good-Entry @{ sleepDeltaMs = 9000 })
    Set-Mock -Sleep 1000 -Luids @($freshLuid)
    Check ((Get-Luid $r3b) -ceq $freshLuid -and (Collections) -eq 1) 'a sleep delta that went backwards collects again'

    # ---- 4. a different adapter key ----
    $r4 = New-Root
    Set-Mock
    $null = Get-Luid $r4
    Set-Mock -Luids @($freshLuid)
    Check ((Get-Luid $r4 $planOther) -ceq $freshLuid -and (Collections) -eq 1) 'a different selected adapter collects again'
    Set-Mock -Luids @('1111111111111111')
    Check ((Get-Luid $r4 $plan) -ceq '1111111111111111' -and (Collections) -eq 1) 'switching back to the first adapter does not reuse the other adapter''s LUID'
    $keyA = InModule { param($p) Get-FastLlmSpillLuidAdapterKey -Plan $p } @($plan)
    $keyB = InModule { param($p) Get-FastLlmSpillLuidAdapterKey -Plan $p } @($planOther)
    $keyNone = InModule { Get-FastLlmSpillLuidAdapterKey -Plan ([pscustomobject]@{ selectedAdapters = @() }) }
    Check ($keyA -ceq 'amd radeon test card|vulkan0|16384' -and $keyB -cne $keyA -and $null -eq $keyNone) 'the adapter key is deterministic, changes with the adapter, and is absent without one'

    # ---- 5. collector or join sha mismatch ----
    $r5 = New-Root
    Set-Mock
    $null = Get-Luid $r5
    Set-Mock -ShaScript $shaB -Luids @($freshLuid)
    Check ((Get-Luid $r5) -ceq $freshLuid -and (Collections) -eq 1) 'a changed collector script hash collects again'
    Set-Mock -ShaScript $shaB -ShaJoin $shaA -Luids @('2222222222222222')
    $r5b = New-Root
    Write-CacheText $r5b (Good-Entry @{ collectorSha256 = $shaB; joinSourceSha256 = $shaB })
    Check ((Get-Luid $r5b) -ceq '2222222222222222' -and (Collections) -eq 1) 'a changed join source hash collects again'
    Set-Mock -Luids @($freshLuid)
    InModule { $script:T.hashes = $null }
    $r5c = New-Root
    Check ((Get-Luid $r5c) -ceq $freshLuid -and (Collections) -eq 1 -and -not (Test-Path -LiteralPath (CachePath $r5c))) 'without the current source hashes there is no cache at all (no write)'

    # ---- 6. malformed, oversize, wrong-kind, bad-LUID files: ignored, deleted, no throw, then collect ----
    $bad = [ordered]@{
        'not json'               = '{ not json'
        'empty file'             = ''
        'an array'               = '[1,2,3]'
        'wrong kind'             = (Good-Entry @{ kind = 'fastllm-other' })
        'wrong schema'           = (Good-Entry @{ schemaVersion = 2 })
        'schema as text'         = (Good-Entry @{ schemaVersion = '1' })
        'bad LUID (uppercase)'   = (Good-Entry @{ luid = '0123456789ABCDEF' })
        'bad LUID (short)'       = (Good-Entry @{ luid = '0123' })
        'bad LUID (number)'      = (Good-Entry @{ luid = 1234567890123456 })
        'extra field'            = (Good-Entry @{ extra = 'x' })
        'missing field'          = (Good-Entry @{ '-luid' = $null })
        'wrong boot source'      = (Good-Entry @{ bootTimeSource = 'wmi' })
        'sleep as text'          = (Good-Entry @{ sleepDeltaMs = 'x' })
        'null sha'               = (Good-Entry @{ collectorSha256 = $null })
        'oversize'               = ('{"pad":"' + ('x' * 9000) + '"}')
    }
    foreach ($label in $bad.Keys) {
        $rb = New-Root
        Write-CacheText $rb $bad[$label]
        Set-Mock -Luids @($freshLuid)
        $threw = $false
        try { $got = Get-Luid $rb } catch { $threw = $true }
        $replaced = Get-Content -LiteralPath (CachePath $rb) -Raw | ConvertFrom-Json
        Check (-not $threw -and $got -ceq $freshLuid -and (Collections) -eq 1 -and $replaced.luid -ceq $freshLuid) ("a $label cache file is ignored, replaced by a fresh collection, and never throws")
        # And with a collection that yields nothing the bad file is simply gone.
        $rb2 = New-Root
        Write-CacheText $rb2 $bad[$label]
        Set-Mock -Luids @()
        $null = Get-Luid $rb2
        Check (-not (Test-Path -LiteralPath (CachePath $rb2))) ("a $label cache file is deleted")
    }
    # A directory in the file's place is not a file: ignored (collect), no throw.
    $rd = New-Root
    New-Item -ItemType Directory -Path (CachePath $rd) -Force | Out-Null
    Set-Mock -Luids @($freshLuid)
    Check ((Get-Luid $rd) -ceq $freshLuid -and (Collections) -eq 1) 'a directory named like the cache is ignored and a collection runs'
    # A reparse point (symbolic link) is refused, ignored and removed (the link, not its target).
    if ([Environment]::OSVersion.Platform -ne 'Win32NT') {
        $rl = New-Root
        New-Item -ItemType Directory -Path (Join-Path $rl 'state') -Force | Out-Null
        $target = Join-Path $scratch 'link-target.json'
        [IO.File]::WriteAllText($target, (Good-Entry))
        New-Item -ItemType SymbolicLink -Path (CachePath $rl) -Target $target | Out-Null
        Set-Mock -Luids @($freshLuid)
        $threw = $false
        try { $got = Get-Luid $rl } catch { $threw = $true }
        Check (-not $threw -and $got -ceq $freshLuid -and (Collections) -eq 1 -and (Test-Path -LiteralPath $target)) 'a symbolic-link cache file is refused (a collection runs) and the target is untouched'
    }
    # A read never creates the state directory.
    $rn = New-Root
    Set-Mock -Luids @()
    $null = Get-Luid $rn
    Check (-not (Test-Path -LiteralPath (Join-Path $rn 'state'))) 'a miss that yields no LUID creates no directory (read never creates one)'

    # ---- 7. re-collect once when the cached LUID's first read fails ----
    $script:readLuids = New-Object 'System.Collections.Generic.List[string]'
    $okSample = { param($l) [pscustomobject]@{ SharedBytes = [uint64](10MB); DedicatedBytes = [uint64](9000MB); Error = $null } }
    $failSample = { param($l) [pscustomobject]@{ SharedBytes = $null; DedicatedBytes = $null; Error = 'query-adapter-ntstatus-c0000022' } }
    $reader = {
        param($l, $p, $b)
        $script:readLuids.Add([string] $l)
        if ($l -ceq $fakeLuid) { return (& $failSample $l) }
        return (& $okSample $l)
    }.GetNewClosure()
    $r7 = New-Root
    Write-CacheText $r7 (Good-Entry)
    Set-Mock -Luids @($freshLuid)
    $step = InModule { param($p, $r, $pr, $rd) Invoke-FastLlmSpillCheckAtReady -Plan $p -InstallRoot $r -KnownLuid $null -BarDecision $null -Process $pr -Reader $rd } @($plan, $r7, $self, $reader)
    Check ((Collections) -eq 1 -and ($script:readLuids -join ',') -ceq ($fakeLuid + ',' + $freshLuid) -and $step.spillCheck.state -ceq 'ok' -and $step.luid -ceq $freshLuid) 'a failed first read of the cached LUID runs exactly 1 collection and retries the read with the fresh LUID'
    $rewritten = Get-Content -LiteralPath (CachePath $r7) -Raw | ConvertFrom-Json
    Check ($rewritten.luid -ceq $freshLuid) 'the fresh valid LUID replaced the stale cache entry'
    # The fresh read fails too: still exactly one collection, two reads, and unknown.
    $script:readLuids.Clear()
    $r7b = New-Root
    Write-CacheText $r7b (Good-Entry)
    Set-Mock -Luids @($freshLuid, '3333333333333333')
    $failAll = { param($l, $p, $b) $script:readLuids.Add([string] $l); (& $failSample $l) }.GetNewClosure()
    $step = InModule { param($p, $r, $pr, $rd) Invoke-FastLlmSpillCheckAtReady -Plan $p -InstallRoot $r -KnownLuid $null -BarDecision $null -Process $pr -Reader $rd } @($plan, $r7b, $self, $failAll)
    Check ((Collections) -eq 1 -and $script:readLuids.Count -eq 2 -and $step.spillCheck.state -ceq 'unknown') 'when the fresh read fails too there is no second collection'
    # A good cached LUID is read once and never re-collected.
    $script:readLuids.Clear()
    $r7c = New-Root
    Write-CacheText $r7c (Good-Entry @{ luid = $freshLuid })
    Set-Mock -Luids @('4444444444444444')
    $okAll = { param($l, $p, $b) $script:readLuids.Add([string] $l); (& $okSample $l) }.GetNewClosure()
    $step = InModule { param($p, $r, $pr, $rd) Invoke-FastLlmSpillCheckAtReady -Plan $p -InstallRoot $r -KnownLuid $null -BarDecision $null -Process $pr -Reader $rd } @($plan, $r7c, $self, $okAll)
    Check ((Collections) -eq 0 -and $script:readLuids.Count -eq 1 -and $step.spillCheck.state -ceq 'ok' -and $step.luid -ceq $freshLuid) 'a healthy cached LUID is read once with 0 collections'
    # A freshly collected LUID whose read fails is not retried.
    $script:readLuids.Clear()
    $r7d = New-Root
    Set-Mock -Luids @($fakeLuid, '5555555555555555')
    $step = InModule { param($p, $r, $pr, $rd) Invoke-FastLlmSpillCheckAtReady -Plan $p -InstallRoot $r -KnownLuid $null -BarDecision $null -Process $pr -Reader $rd } @($plan, $r7d, $self, $reader)
    Check ((Collections) -eq 1 -and $script:readLuids.Count -eq 1 -and $step.spillCheck.state -ceq 'unknown') 'a failed read of a freshly collected LUID is not retried'

    # ---- 8. -KnownLuid: the cache is never read or written ----
    $r8 = New-Root
    Write-CacheText $r8 (Good-Entry)
    $beforeText = [IO.File]::ReadAllText((CachePath $r8))
    Set-Mock -Boot $bootLater -Luids @($freshLuid)
    $known = Get-Luid $r8 $plan '000000000000AB12'
    Check ($known -ceq '000000000000ab12' -and (Collections) -eq 0 -and (Test-Path -LiteralPath (CachePath $r8)) -and [IO.File]::ReadAllText((CachePath $r8)) -ceq $beforeText) 'a known LUID never reads, deletes or writes the cache (an other-boot entry is untouched)'
    $r8b = New-Root
    $null = Get-Luid $r8b $plan '000000000000AB12'
    Check (-not (Test-Path -LiteralPath (Join-Path $r8b 'state'))) 'a known LUID writes no cache'

    # ---- 10. not Windows: no cache read or write at all ----
    $r10 = New-Root
    Write-CacheText $r10 (Good-Entry)
    $beforeText = [IO.File]::ReadAllText((CachePath $r10))
    Set-Mock -Windows $false -Luids @($freshLuid)
    Check ($null -eq (Get-Luid $r10) -and (Collections) -eq 0 -and [IO.File]::ReadAllText((CachePath $r10)) -ceq $beforeText) 'off Windows a Vulkan plan neither collects nor reads, deletes or writes the cache'
    $r10b = New-Root
    $null = Get-Luid $r10b
    Check (-not (Test-Path -LiteralPath (Join-Path $r10b 'state'))) 'off Windows no cache file or folder is created'
    # No boot identity or no sleep delta (the native calls failed): no cache either way, collection still works.
    $r10c = New-Root
    Set-Mock -Boot $null -Luids @($freshLuid)
    Check ((Get-Luid $r10c) -ceq $freshLuid -and (Collections) -eq 1 -and -not (Test-Path -LiteralPath (Join-Path $r10c 'state'))) 'without a native boot identity there is no cache (collection works as before)'
    Set-Mock -Sleep $null -Luids @($freshLuid)
    Check ((Get-Luid $r10c) -ceq $freshLuid -and (Collections) -eq 1 -and -not (Test-Path -LiteralPath (Join-Path $r10c 'state'))) 'without a sleep delta there is no cache'
    # A non-Vulkan plan never touches the cache.
    $r10d = New-Root
    Set-Mock -Luids @($freshLuid)
    $hipPlan = [pscustomobject]@{ backend = 'hip'; selectedAdapters = @([pscustomobject]@{ name = 'AMD Radeon Test Card'; device = 'ROCm0'; vramMiB = 16384 }) }
    $null = InModule { param($p, $r, $pr, $e) Get-FastLlmSpillCheckLuid -Plan $p -InstallRoot $r -KnownLuid $null -Process $pr -Enumerator $e -Reader { param($l, $q, $b) [pscustomobject]@{ SharedBytes = [uint64]0; DedicatedBytes = [uint64](2GB); Error = $null } } } @($hipPlan, $r10d, $self, { @('0000000000001234') })
    Check ((Collections) -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $r10d 'state'))) 'a HIP plan never uses the cache'

    # ---- 9. privacy: the LUID and the cache content never reach status, the support bundle, the run log fields or the console ----
    $r9 = New-Root
    Set-Mock -Luids @($fakeLuid)
    # The returned value is the LUID itself, so the console check discards the pipeline output and captures streams 2 to 6.
    $streams = & { $null = Get-Luid $r9 } *>&1 | Out-String
    Check ($streams -notmatch $fakeLuid -and (Test-Path -LiteralPath (CachePath $r9))) 'one call prints nothing (no Write-Host, Write-Output, Write-Warning) and leaves the cache in place'
    $stepForLog = InModule { param($p, $r, $pr, $rd) Invoke-FastLlmSpillCheckAtReady -Plan $p -InstallRoot $r -KnownLuid $null -BarDecision $null -Process $pr -Reader $rd } @($plan, $r9, $self, $okAll)
    $fields = InModule { param($s) Get-FastLlmSpillCheckEventFields -Step $s } @($stepForLog)
    $fieldsJson = $fields | ConvertTo-Json -Compress
    Check ($fieldsJson -notmatch $fakeLuid -and $fieldsJson -notmatch 'luid' -and $fieldsJson -notmatch 'cache') 'the spill-check run log fields hold no LUID and no cache word'
    $statusState = [ordered]@{ schemaVersion = 1; phase = 'ready'; spillCheck = $stepForLog.spillCheck }
    InModule { param($r, $s) Write-FastLlmState -InstallRoot $r -State $s } @($r9, $statusState)
    $statusJson = (InModule { param($r) Get-FastLlmStatus -InstallRoot $r } @($r9)) | ConvertTo-Json -Depth 12
    Check ($statusJson -notmatch $fakeLuid -and $statusJson -notmatch 'spill-luid') 'Get-FastLlmStatus output holds no LUID and no cache file name'
    $statusFile = Get-Content -LiteralPath (Join-Path (Join-Path $r9 'state') 'status.json') -Raw
    Check ($statusFile -notmatch $fakeLuid) 'status.json holds no LUID'
    $appRoot = Join-Path $scratch 'app'
    New-Item -ItemType Directory -Path $appRoot -Force | Out-Null
    $listing = New-FastLlmSupportBundle -InstallRoot $r9 -AppRoot $appRoot -OutputPath (Join-Path $scratch 'list.zip') -Doctor ([pscustomobject]@{ note = 'x' }) -ListOnly
    $listingText = $listing | ConvertTo-Json -Depth 8
    Check (@($listing.entries | Where-Object { $_.name -like '*spill*' -or $_.name -like '*luid*' -or $_.name -like "*$cacheName*" }).Count -eq 0 -and $listingText -notmatch $fakeLuid -and $listingText -notmatch 'spill-luid') 'the support bundle listing has no entry for the cache and no LUID'
    $null = New-FastLlmSupportBundle -InstallRoot $r9 -AppRoot $appRoot -OutputPath (Join-Path $scratch 'real.zip') -Doctor ([pscustomobject]@{ note = 'x'; spillCheck = $stepForLog.spillCheck })
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead((Join-Path $scratch 'real.zip'))
    try {
        $names = @($zip.Entries | ForEach-Object { $_.FullName })
        $all = New-Object Text.StringBuilder
        foreach ($e in $zip.Entries) { $sr = New-Object IO.StreamReader($e.Open()); [void]$all.Append($sr.ReadToEnd()); $sr.Dispose() }
    }
    finally { $zip.Dispose() }
    Check ($names.Count -gt 0 -and @($names | Where-Object { $_ -like '*spill*' -or $_ -like '*luid*' }).Count -eq 0 -and $all.ToString() -notmatch $fakeLuid -and $all.ToString() -notmatch 'spill-luid') 'a real support bundle holds no cache file, no LUID and no cache file name (entry names and contents)'
    # The source: no Write-Host / Write-Output / Write-Warning near the cache code and no LUID in a log call.
    $spillText = Get-Content -LiteralPath (Join-Path $root 'src/FastLlm.SpillCheck.ps1') -Raw
    $start = $spillText.IndexOf('# ---- Private per-boot LUID cache')
    $end = $spillText.IndexOf('function Get-FastLlmSpillCheckLuid')
    $cacheSource = $spillText.Substring($start, $end - $start)
    Check ($cacheSource -cnotmatch 'Write-Host|Write-Output|Write-Warning|Write-Verbose|Write-Debug|Add-FastLlmRunLogEvent|Write-Error') 'the cache code writes to no console stream and no run log'
    Check ([Text.Encoding]::UTF8.GetByteCount($spillText) -eq $spillText.Length) 'FastLlm.SpillCheck.ps1 stays ASCII-only'
}
finally {
    InModule { param($saved) foreach ($n in $saved.Keys) { Set-Item -Path ("Function:\script:" + $n) -Value $saved[$n] } } @($originals)
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

# ---- the cache's native reads must not add the BAR cache's compile (static, by AST command names) ----
$spillPath = Join-Path $root 'src/FastLlm.SpillCheck.ps1'
$tokens = $null; $errs = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($spillPath, [ref]$tokens, [ref]$errs)
Check ($errs.Count -eq 0) 'FastLlm.SpillCheck.ps1 parses'
function Get-FuncAst($Name) { $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name }, $true) }
$banned = @('Initialize-FastLlmVulkanBarNativeTypes', 'Get-FastLlmNativeBootIdentity', 'Get-FastLlmVulkanBarSleepDelta', 'Get-FastLlmVulkanBarBootIdentity', 'Initialize-FastLlmGpuIdentity')
foreach ($fn in @('Get-FastLlmSpillLuidCacheContext', 'Get-FastLlmSpillBootIdentity', 'Get-FastLlmSpillSleepDelta', 'Initialize-FastLlmSpillNativeTypes')) {
    $f = Get-FuncAst $fn
    Check ($null -ne $f) "$fn exists"
    $cmds = @($f.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
    Check (@($cmds | Where-Object { $banned -contains $_ }).Count -eq 0) "$fn calls no BAR-cache native helper"
    $strings = @($f.FindAll({ param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value })
    Check (@($strings | Where-Object { $_ -like '*WindowsGpuIdentity*' }).Count -eq 0) "$fn never names WindowsGpuIdentity"
}
$init = Get-FuncAst 'Initialize-FastLlmSpillNativeTypes'
$initStrings = @($init.FindAll({ param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value })
Check (@($initStrings | Where-Object { $_ -ceq 'WindowsBootTime.cs' }).Count -eq 1 -and @($initStrings | Where-Object { $_ -ceq 'WindowsGpuProcessMemory.cs' }).Count -eq 1 -and @($initStrings | Where-Object { $_ -like '*WindowsGpuIdentity*' }).Count -eq 0) 'the spill native compile lists WindowsBootTime.cs and WindowsGpuProcessMemory.cs, never WindowsGpuIdentity.cs'
$initCmds = @($init.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Add-Type' }, $true))
Check ($initCmds.Count -eq 1) 'the spill native compile is ONE Add-Type call'
Check ((Get-FuncAst 'Initialize-FastLlmGpuProcessMemory').Extent.Text -match 'Initialize-FastLlmSpillNativeTypes') 'the process-memory initializer shares the one compile'

Write-Host "$script:count spill-luid-cache checks passed."
