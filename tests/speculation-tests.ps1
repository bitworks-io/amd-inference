#requires -Version 5.1
# The speculation option (-Speculation off|ngram|mtp): default off, gated by measured add-on rows, never on the bench path. This release ships no
# row, so on a real install every speculation start is refused. These tests use TEST rows only (tests/fixtures/speculation-profiles-test.json and
# tests/fixtures/speculation-components-test.json); config/ ships neither a row nor a draft component. Pure planner and mock-server work: no
# engine, GPU or network, and nothing here reaches a bench.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force -ErrorAction Stop
$module=Get-Module FastLlm
$script:count=0
function Check($Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:count++;Write-Host "PASS: $Message"}
function Get-RefusalCode([scriptblock]$Action){
    $observed=[ordered]@{threw=$false;code='';message='';reason=''}
    try { & $Action | Out-Null } catch { $observed.threw=$true;$observed.message=[string]$_.Exception.Message;$observed.code=[string]$_.Exception.Data['FastLlmFailureCode'];$observed.reason=[string]$_.Exception.Data['FastLlmReason'] }
    return [pscustomobject]$observed
}
function Write-Utf8([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object Text.UTF8Encoding($false)))}
function Test-SameArguments($Expected,$Actual){$e=@($Expected);$a=@($Actual);if($e.Count -ne $a.Count){return $false};for($k=0;$k -lt $e.Count;$k++){if(-not ($e[$k] -ceq $a[$k])){return $false}};return $true}

$work=Join-Path ([IO.Path]::GetTempPath()) ('speculation-tests-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
try {
    $installRoot=Join-Path $work 'install'
    $catalogPath=Join-Path $root 'config/catalog.json'
    $specProfiles=Join-Path $root 'tests/fixtures/speculation-profiles-test.json'
    $specComponents=Join-Path $root 'tests/fixtures/speculation-components-test.json'
    $shippedProfiles=Join-Path $root 'config/serving-profiles.json'
    function New-Card([int]$Free){
        $adapter=[pscustomobject]@{device='Vulkan0';name='Speculation test card';vendorId='1002';vramMiB=24576;freeVramMiB=$Free;isAmd=$true;isIntegrated=$false;backend='Vulkan';driverVersion='spec-test'}
        return [pscustomobject]@{schemaVersion=1;source='spec-test';backend='Vulkan';enginePath='C:\FastLLM\vulkan\llama-server.exe';adapters=@($adapter)}
    }
    $card=New-Card 23552
    $common=@{Hardware=$card;CatalogPath=$catalogPath;Profile='balanced';NoEngineExecution=$true;InstallRoot=$installRoot;KvProfilesPath=$specProfiles;ModelId='qwen3.8-27b-ud-q4-k-m'}
    function Get-SpecDocument(){ return (Get-Content -LiteralPath $specProfiles -Raw | ConvertFrom-Json) }
    function Save-SpecDocument($Document,[string]$Name){ $path=Join-Path $work $Name; Write-Utf8 $path ($Document | ConvertTo-Json -Depth 12); return $path }

    # ---- 1. the loader refuses what the checker refuses (tests/fixtures/speculation-addon-parity-cases.json is read by both) ------------------
    $parity=Get-Content -LiteralPath (Join-Path $root 'tests/fixtures/speculation-addon-parity-cases.json') -Raw | ConvertFrom-Json
    $document=Get-SpecDocument
    $profilesJson=ConvertTo-Json -InputObject @($document.profiles) -Depth 10
    $mismatch=0;$cases=0
    foreach($case in @($parity.cases)){
        $cases++
        $caseFile=Join-Path $work ('parity-'+$cases+'.json')
        Write-Utf8 $caseFile ('{"schema":"bitworks.fastllm-serving-profiles/v1","profiles":'+$profilesJson+',"addOns":'+(ConvertTo-Json -InputObject @($case.addOns) -Depth 10)+',"sidecars":[]}')
        $refused=$false
        try { & $module { param($P) Read-FastLlmAddOnRows -Path $P | Out-Null } $caseFile } catch { $refused=[bool]([string]$_.Exception.Data['FastLlmFailureCode'] -ceq 'serving-profiles-invalid') }
        if($refused -ne [bool]$case.refuse){$mismatch++;Write-Host "DIFF parity case $($case.name): checker refuses=$($case.refuse) loader refused=$refused"}
    }
    Check ($cases -ge 40 -and $mismatch -eq 0) "speculation loader parity: the PowerShell loader and the checker give the same verdict on all $cases shared cases"
    $rows=@(& $module { param($P) Read-FastLlmAddOnRows -Path $P } $specProfiles)
    Check ($rows.Count -eq 5 -and (@($rows | ForEach-Object { [string]$_.kind }) -join ',') -ceq 'vision,vision,ngram,ngram,mtp') 'speculation loader: the five test rows are read, in order, each with its kind'
    $mtpRow=@($rows | Where-Object { $_.kind -ceq 'mtp' })[0]
    Check ([string]$mtpRow.componentId -ceq 'test-mtp-draft' -and [string]$mtpRow.specType -ceq 'draft-mtp' -and (@($mtpRow.extraArguments) -join ' ') -ceq '--spec-draft-n-max 4' -and [int64]$mtpRow.extraFreeVramMiB['long'] -eq 900) 'speculation loader: an mtp row keeps its component id, spec type, extra arguments and per-profile memory'
    $ngramRow=@($rows | Where-Object { $_.kind -ceq 'ngram' })[0]
    Check (-not $ngramRow.PSObject.Properties['componentId'] -and [int64]$ngramRow.extraFreeVramMiB['default'] -eq 0) 'speculation loader: an ngram row has no component id and may add 0 MiB'
    Check (@(& $module { param($P) Read-FastLlmAddOnRows -Path $P } $shippedProfiles).Count -eq 0 -and @(& $module { param($P) Read-FastLlmAddOnRows -Path $P } (Join-Path $work 'absent.json')).Count -eq 0) 'speculation loader: the shipped file has no row, and no file is no rows'
    Check (@(& $module { param($P) Read-FastLlmVisionAddOns -Path $P } $specProfiles).Count -eq 2) 'speculation loader: the vision loader still returns the vision rows only'
    $zeroMtp=Get-SpecDocument;$zeroMtp.addOns[4].extraFreeVramMiB.long=0
    Check ((Get-RefusalCode { & $module { param($P) Read-FastLlmAddOnRows -Path $P | Out-Null } (Save-SpecDocument $zeroMtp 'zero-mtp.json') }).code -ceq 'serving-profiles-invalid') 'speculation loader: 0 MiB is refused for an mtp row (and allowed for an ngram row)'

    # ---- 2. the closed per-engine allowlist ---------------------------------------------------------------------------------------------------
    $allow=& $module { Get-FastLlmSpeculationAllowlist }
    $catalog=Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
    $components=Get-Content -LiteralPath (Join-Path $root 'config/components.json') -Raw | ConvertFrom-Json
    $builtIn='llama.cpp-'+[string]$catalog.engine.version+'-vulkan'
    $pinned=@($builtIn)+@($components.components | Where-Object { $_.kind -ceq 'engine' } | ForEach-Object { [string]$_.id })
    Check ((@($allow.Keys | Sort-Object) -join ',') -ceq (@($pinned | Sort-Object -Unique) -join ',')) 'allowlist: exactly the pinned engine ids have an entry (the built-in engine and every listed engine component)'
    $tagOf=@{};$tagOf[$builtIn]=[string]$catalog.engine.version
    foreach($c in @($components.components | Where-Object { $_.kind -ceq 'engine' })){ $tagOf[[string]$c.id]=[string]$c.version }
    $membershipBad=0
    foreach($engineId in @($allow.Keys)){
        $fixturePath=Join-Path $root ('tests/fixtures/engine-surface-'+$tagOf[$engineId]+'.json')
        $entry=$allow[$engineId]
        if(-not (Test-Path -LiteralPath $fixturePath)){ if(@($entry.flags).Count -ne 0 -or @($entry.specTypes.ngram).Count -ne 0 -or @($entry.specTypes.mtp).Count -ne 0){$membershipBad++}; continue }
        $options=@((Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json).options)
        foreach($flag in @($entry.flags)+@($entry.draftModelFlag | Where-Object { $_ })){ if($options -cnotcontains [string]$flag){$membershipBad++;Write-Host "DIFF $engineId allows $flag, which engine tag $($tagOf[$engineId]) does not list"} }
    }
    Check ($membershipBad -eq 0) 'allowlist: every allowlisted flag appears in the engine-surface fixture of that engine''s tag (an engine with no fixture has an empty allowlist)'
    $counterBad=0
    foreach($engineId in @($allow.Keys)){
        $entry=$allow[$engineId];$fixturePath=Join-Path $root ('tests/fixtures/engine-surface-'+$tagOf[$engineId]+'.json')
        if(-not (Test-Path -LiteralPath $fixturePath)){ if($null -ne $entry.counters){$counterBad++}; continue }
        $listed=@((Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json).metricsCounters)
        if($null -eq $entry.counters -or $listed -cnotcontains [string]$entry.counters.draft -or $listed -cnotcontains [string]$entry.counters.accepted){$counterBad++;Write-Host "DIFF $engineId counters"}
    }
    Check ($counterBad -eq 0) 'allowlist: the metrics counter names the summary reads are listed in the engine-surface fixture of that engine''s tag (no fixture, no counters)'
    $vulkanEntry=$allow[$builtIn];$hipEntry=$allow['llama.cpp-hip-b11658']
    Check (@($vulkanEntry.flags) -cnotcontains '--spec-draft-sampling' -and @($hipEntry.flags) -ccontains '--spec-draft-sampling') 'allowlist: the lists are per engine (--spec-draft-sampling exists on the HIP pin only)'
    Check (@($allow.Values | ForEach-Object { @($_.flags) } | Where-Object { $_ -clike '--draft*' }).Count -eq 0) 'allowlist: the removed --draft names are never allowed'
    Check ((@($vulkanEntry.specTypes.mtp) -join ',') -ceq 'draft-mtp' -and (@($vulkanEntry.specTypes.ngram) -join ',') -ceq 'ngram-simple,ngram-map-k,ngram-map-k4v,ngram-mod' -and [string]$vulkanEntry.draftModelFlag -ceq '--spec-draft-model') 'allowlist: the spec types and the draft model flag are the pinned literals'
    Check ((@($vulkanEntry.flags) -join ' ') -ceq '--spec-ngram-size-n --spec-ngram-size-m --spec-ngram-min-hits --spec-ngram-simple-size-n --spec-ngram-simple-size-m --spec-ngram-simple-min-hits --spec-ngram-map-k-size-n --spec-ngram-map-k-size-m --spec-ngram-map-k-min-hits --spec-ngram-map-k4v-size-n --spec-ngram-map-k4v-size-m --spec-ngram-map-k4v-min-hits --spec-ngram-mod-n-match --spec-ngram-mod-n-max --spec-ngram-mod-n-min --spec-draft-n-max --spec-draft-n-min --spec-draft-p-min') 'allowlist: the built-in engine''s flag list is the pinned literal';
    Check ((@($hipEntry.flags) -join ' ') -ceq ((@($vulkanEntry.flags) -join ' ')+' --spec-draft-n-ubatch --spec-draft-sampling')) 'allowlist: the HIP pin''s flag list is the pinned literal (two more flags)'
    $unknown=@(& $module { Get-FastLlmSpeculationAllowlistEntry -EngineId 'llama.cpp-b99999-vulkan' })
    Check ($unknown.Count -eq 1 -and @($unknown[0].flags).Count -eq 0 -and @($unknown[0].specTypes.ngram).Count -eq 0 -and @($unknown[0].specTypes.mtp).Count -eq 0 -and $null -eq $unknown[0].draftModelFlag) 'allowlist: an engine id that is not pinned has an empty allowlist'

    # ---- 3. the planner: lookup, effective profile id, fit; refusals 1, 2 and 3 in order ----------------------------------------------------------
    $off=Get-FastLlmPlan @common -KvContextProfile 'long'
    $offExplicit=Get-FastLlmPlan @common -KvContextProfile 'long' -Speculation 'off'
    Check ((($off | ConvertTo-Json -Depth 12) -ceq ($offExplicit | ConvertTo-Json -Depth 12)) -and -not $offExplicit.PSObject.Properties['speculation']) 'speculation off: -Speculation off is byte-identical to no -Speculation and adds no field'
    Check ((Test-SameArguments $off.serverArguments $offExplicit.serverArguments) -and (@($off.serverArguments) -join ' ').Contains('--spec-type none')) 'speculation off: the arguments keep --spec-type none'
    $badSet=Get-RefusalCode { Get-FastLlmPlan @common -Speculation 'maybe' }
    Check ($badSet.threw) 'speculation: the parameter is a closed set (off|ngram|mtp)'
    $ngram=Get-FastLlmPlan @common -KvContextProfile 'long' -Speculation 'ngram'
    $sb=$ngram.speculation
    Check ($null -ne $sb -and [string]$sb.mode -ceq 'ngram' -and [string]$sb.specType -ceq 'ngram-simple' -and (@($sb.extraArguments) -join ' ') -ceq '--spec-ngram-size-n 12 --spec-ngram-size-m 48' -and [string]$sb.profileId -ceq 'long' -and [int]$sb.extraFreeVramMiB -eq 64 -and [int64]$sb.requiredFreeVramMiB -eq 21564 -and [string]$sb.resultId -ceq 'test-ngram-0001') 'speculation plan: the block names the mode, spec type, extra arguments, profile id, the extra memory (64), the total (21500 + 64) and the evidence id'
    Check ([string]$sb.engineId -ceq 'llama.cpp-b10698-vulkan' -and [string]$sb.backend -ceq 'vulkan' -and [string]$sb.modelSha256 -ceq [string]$ngram.model.sha256 -and -not $sb.PSObject.Properties['startRefusal']) 'speculation plan: the block carries the model sha256, engine id and backend, and an ngram plan names no start refusal'
    $addedFields=@($ngram.PSObject.Properties.Name | Where-Object { -not $off.PSObject.Properties[$_] })
    Check ($addedFields.Count -eq 1 -and $addedFields[0] -ceq 'speculation') 'speculation plan: speculation is the only field added to the opt-in plan'
    Check ([int]$ngram.servingProfile.requiredFreeVramMiB -eq 21500 -and [int]$ngram.model.requiredFreeVramMiB -eq 21500) 'speculation plan: the profile row''s own requirement is unchanged; the extra memory is added in the speculation block only'
    $mtp=Get-FastLlmPlan @common -KvContextProfile 'long' -Speculation 'mtp'
    Check ([string]$mtp.speculation.mode -ceq 'mtp' -and [string]$mtp.speculation.componentId -ceq 'test-mtp-draft' -and [string]$mtp.speculation.specType -ceq 'draft-mtp' -and [int64]$mtp.speculation.requiredFreeVramMiB -eq 22400 -and [string]$mtp.speculation.startRefusal -ceq 'speculation-evidence-unavailable') 'speculation plan: an mtp block names the draft component and says the start is refused (speculation-evidence-unavailable)'
    # An explicit default profile with one request is the same default-context plan: it has no profile id, so a value for it is never used (the
    # default value of a row matters only with 2 requests at once, which speculation does not offer in this version).
    $zeroExtra=Get-SpecDocument;$zeroExtra.addOns[2].extraFreeVramMiB.long=0
    $zeroPlan=Get-FastLlmPlan @common -KvContextProfile 'long' -KvProfilesPath (Save-SpecDocument $zeroExtra 'zero-extra.json') -Speculation 'ngram'
    Check ([int]$zeroPlan.speculation.extraFreeVramMiB -eq 0 -and [int64]$zeroPlan.speculation.requiredFreeVramMiB -eq 21500) 'speculation plan: an ngram row may add 0 MiB (the total is the profile row''s requirement)'
    # Refusal 1: no row of that kind.
    $r1=Get-RefusalCode { Get-FastLlmPlan @common -ModelId 'qwen3.8-27b-q8-0' -KvContextProfile 'long' -Speculation 'ngram' }
    Check ($r1.threw -and $r1.code -ceq 'speculation-not-measured' -and $r1.message -like 'speculation-not-measured: *Nothing was started*' -and $r1.message -like '*-Speculation off*' -and [string]::IsNullOrEmpty($r1.reason)) 'speculation refusal 1: a model without an ngram row is refused (speculation-not-measured), nothing was started, and no reason is set for a retry or recovery'
    $r1b=Get-RefusalCode { Get-FastLlmPlan @common -ModelId 'qwen3.5-9b-q6-k' -KvContextProfile 'long' -Speculation 'mtp' }
    Check ($r1b.threw -and $r1b.code -ceq 'speculation-not-measured') 'speculation refusal 1: a model with an ngram row but no mtp row is refused for mtp (the kind must match)'
    foreach($file in @($shippedProfiles,(Join-Path $root 'tests/fixtures/serving-profiles-test.json'),(Join-Path $work 'absent.json'))){
        $rf=Get-RefusalCode { Get-FastLlmPlan @common -KvContextProfile 'long' -KvProfilesPath $file -Speculation 'ngram' }
        Check ($rf.threw -and $rf.code -ceq 'speculation-not-measured') ('speculation refusal 1: '+(Split-Path -Leaf $file)+' has no ngram row, so the option is refused')
    }
    foreach($mut in @(
            @{Name='s-other-sha';Label='another model sha256';Mutate={ param($d) $d.addOns[2].modelSha256=('0'*64) }},
            @{Name='s-other-engine';Label='another engine build';Mutate={ param($d) $d.addOns[2].engineId='llama.cpp-b99999-vulkan' }},
            @{Name='s-hip-engine';Label='the HIP engine and backend';Mutate={ param($d) $d.addOns[2].engineId='llama.cpp-hip-b11658'; $d.addOns[2].backend='hip' }},
            @{Name='s-other-backend';Label='another backend';Mutate={ param($d) $d.addOns[2].backend='hip' }})){
        $mutDocument=Get-SpecDocument
        & $mut.Mutate $mutDocument
        $rm=Get-RefusalCode { Get-FastLlmPlan @common -KvContextProfile 'long' -KvProfilesPath (Save-SpecDocument $mutDocument ($mut.Name+'.json')) -Speculation 'ngram' }
        Check ($rm.threw -and ($rm.code -ceq 'speculation-not-measured' -or $rm.code -ceq 'serving-profiles-invalid')) "speculation refusal 1: a row for $($mut.Label) does not apply to this plan"
    }
    $hipCard=Get-Content -LiteralPath (Join-Path $root 'tests/fixtures/dual-rx-7900-xtx-24gb.json') -Raw | ConvertFrom-Json
    $hipRefused=Get-RefusalCode { Get-FastLlmPlan -Hardware $hipCard -CatalogPath $catalogPath -Profile balanced -NoEngineExecution -InstallRoot $installRoot -KvContextProfile 'long' -KvProfilesPath $specProfiles -Speculation 'ngram' }
    Check ($hipRefused.threw -and $hipRefused.code -ceq 'speculation-not-measured') 'speculation HIP: a plan on another backend finds no row (the same engine and backend binding as every opt-in row); no HIP rule is written'
    $planSource=Get-Content -LiteralPath (Join-Path $root 'src/FastLlm.psm1') -Raw
    Check (-not [regex]::IsMatch($planSource,'(?i)\bspeculation\b[^\r\n]*\bhip\b|\bhip\b[^\r\n]*\bspeculation\b')) 'speculation HIP: no new HIP rule is written for speculation'
    $malformed=Join-Path $work 'malformed.json';Write-Utf8 $malformed '{not json'
    Check ((Get-RefusalCode { Get-FastLlmPlan @common -KvContextProfile 'long' -KvProfilesPath $malformed -Speculation 'ngram' }).code -ceq 'serving-profiles-invalid') 'speculation: a profile file that is not JSON fails typed (never honoured, never dropped)'
    $offUnread=Get-FastLlmPlan @common -KvContextProfile 'default' -KvProfilesPath $malformed -Speculation 'off'
    Check ($null -ne $offUnread) 'speculation off: the add-on rows are never read (a profile file that is not JSON changes nothing)'
    $badSpecRow=Get-SpecDocument;$badSpecRow.addOns[2].specType='ngram-bogus'
    Check ((Get-RefusalCode { Get-FastLlmPlan @common -KvContextProfile 'long' -KvProfilesPath (Save-SpecDocument $badSpecRow 'bad-spec-type.json') -Speculation 'ngram' }).code -ceq 'serving-profiles-invalid') 'speculation: a row with a spec type outside the engine''s allowlist fails typed in the planner too'
    $badFlagRow=Get-SpecDocument;$badFlagRow.addOns[2].extraArguments=@('--spec-draft-sampling','on')
    Check ((Get-RefusalCode { Get-FastLlmPlan @common -KvContextProfile 'long' -KvProfilesPath (Save-SpecDocument $badFlagRow 'bad-flag.json') -Speculation 'ngram' }).code -ceq 'serving-profiles-invalid') 'speculation: a row with a flag outside the engine''s allowlist fails typed in the planner too'
    # Refusal 2: a row, but no value for the effective profile.
    $r2=Get-RefusalCode { Get-FastLlmPlan @common -Speculation 'ngram' }
    Check ($r2.threw -and $r2.code -ceq 'speculation-profile-not-measured' -and $r2.message -like '*Nothing was started*' -and [string]::IsNullOrEmpty($r2.reason)) 'speculation refusal 2: a default-context plan has no profile id to key a value on, so it is refused (speculation-profile-not-measured)'
    foreach($specMode in @('ngram','mtp')){
        $r2b=Get-RefusalCode { Get-FastLlmPlan @common -KvContextProfile 'default' -KvSlots 1 -Speculation $specMode }
        Check ($r2b.threw -and $r2b.code -ceq 'speculation-profile-not-measured') "speculation refusal 2: explicit default values are the same default-context plan and are refused the same way ($specMode)"
    }
    $r2c=Get-RefusalCode { Get-FastLlmPlan @common -ModelId 'qwen3.5-9b-q6-k' -KvContextProfile 'default' -Speculation 'ngram' }
    Check ($r2c.threw -and $r2c.code -ceq 'speculation-profile-not-measured') 'speculation refusal 2: a row with a value only for long is refused for the default profile'
    $rOrder=Get-RefusalCode { Get-FastLlmPlan @common -ModelId 'qwen3.8-27b-q8-0' -Speculation 'ngram' }
    Check ($rOrder.threw -and $rOrder.code -ceq 'speculation-not-measured') 'speculation order: with no row AND no profile id, refusal 1 comes before refusal 2'
    # Refusal 3: a combination that is not offered in this version.
    $r3=Get-RefusalCode { Get-FastLlmPlan @common -KvContextProfile 'long' -KvSlots 2 -Speculation 'ngram' }
    Check ($r3.threw -and $r3.code -ceq 'speculation-combination-not-offered' -and $r3.message -like '*-KvSlots*' -and $r3.message -like '*Nothing was started*' -and [string]::IsNullOrEmpty($r3.reason)) 'speculation refusal 3: speculation with 2 requests at once is refused (speculation-combination-not-offered)'
    $r3b=Get-RefusalCode { Get-FastLlmPlan @common -KvContextProfile 'long' -Vision 'on' -Speculation 'ngram' }
    Check ($r3b.threw -and $r3b.code -ceq 'speculation-combination-not-offered' -and $r3b.message -like '*-Vision*') 'speculation refusal 3: speculation with -Vision on is refused'
    $r3c=Get-RefusalCode { Get-FastLlmPlan @common -KvContextProfile 'long' -KvSlots 2 -ModelId 'qwen3.8-27b-q8-0' -Speculation 'ngram' }
    Check ($r3c.threw -and $r3c.code -ceq 'speculation-not-measured') 'speculation order: with no row AND 2 slots, refusal 1 (no row) comes before refusal 3 (the combination)'
    $tightSlots=Get-RefusalCode { Get-FastLlmPlan -Hardware (New-Card 21530) -CatalogPath $catalogPath -Profile balanced -NoEngineExecution -InstallRoot $installRoot -KvProfilesPath $specProfiles -ModelId 'qwen3.8-27b-ud-q4-k-m' -KvContextProfile 'long' -KvSlots 2 -Speculation 'ngram' }
    Check ($tightSlots.threw -and $tightSlots.code -ceq 'speculation-combination-not-offered') 'speculation refusal 3: the combination is named even when the plan would not fit the card anyway (no fit refusal hides it)'
    $noServingRow=Get-RefusalCode { Get-FastLlmPlan @common -ModelId 'qwen3.5-9b-q6-k' -KvContextProfile 'long' -KvSlots 2 -Speculation 'ngram' }
    Check ($noServingRow.threw -and $noServingRow.code -ceq 'speculation-combination-not-offered') 'speculation refusal 3: the combination is named when the profile row does not allow 2 slots either (no serving-row refusal hides it)'
    $r3d=Get-RefusalCode { Get-FastLlmPlan @common -KvContextProfile 'default' -KvSlots 2 -ModelId 'qwen3.5-9b-q6-k' -Speculation 'ngram' }
    Check ($r3d.threw -and $r3d.code -ceq 'speculation-profile-not-measured') 'speculation order: with no value for the profile AND 2 slots, refusal 2 comes before refusal 3'
    # Fit: the extra memory is the row's, added to the profile's requirement. Nothing is derived.
    $tight=New-Card 21530
    $fitCommon=@{Hardware=$tight;CatalogPath=$catalogPath;Profile='balanced';NoEngineExecution=$true;InstallRoot=$installRoot;KvProfilesPath=$specProfiles;ModelId='qwen3.8-27b-ud-q4-k-m';KvContextProfile='long'}
    Check ([string](Get-FastLlmPlan @fitCommon).servingProfile.id -ceq 'long') 'speculation fit: with 21530 MiB free the long row alone (21500) fits'
    $rFit=Get-RefusalCode { Get-FastLlmPlan @fitCommon -Speculation 'ngram' }
    Check ($rFit.threw -and $rFit.code -ceq 'model-does-not-fit') 'speculation fit: the same card with ngram on needs 21500 + 64 and does not fit (the existing model-does-not-fit refusal)'
    $smallExtra=Get-SpecDocument;$smallExtra.addOns[2].extraFreeVramMiB.long=30
    Check ([int64](Get-FastLlmPlan @fitCommon -KvProfilesPath (Save-SpecDocument $smallExtra 'small-extra.json') -Speculation 'ngram').speculation.requiredFreeVramMiB -eq 21530) 'speculation fit: the number comes from the row (21500 + 30 = 21530 fits exactly); no constant or formula is used'
    $recipeCard=Get-Content -LiteralPath (Join-Path $root 'tests/fixtures/rx-7900-xt-20gb-identified.json') -Raw | ConvertFrom-Json
    $recipeCard.backend='Vulkan';$recipeCard.adapters[0].device='Vulkan0';$recipeCard.adapters[0].backend='Vulkan'
    $identified=@{Hardware=$recipeCard;CatalogPath=$catalogPath;RecipesPath=(Join-Path $root 'config/recipes.json');GpuVariantsPath=(Join-Path $root 'config/gpu-variants.json');Profile='balanced';NoEngineExecution=$true;InstallRoot=$installRoot;KvProfilesPath=$specProfiles}
    $recipeSpec=Get-RefusalCode { Get-FastLlmPlan @identified -Speculation 'ngram' }
    Check ($recipeSpec.threw -and $recipeSpec.code -ceq 'speculation-profile-not-measured') 'speculation: on a card with a measured recipe, no recipe is applied (no engine is probed); a default-context plan is refused for want of a profile id'
    $recipeSpecLong=Get-FastLlmPlan @identified -ModelId 'qwen3.5-9b-q6-k' -KvContextProfile 'long' -Speculation 'ngram'
    Check ([string]$recipeSpecLong.selectionMode -ne 'recipe' -and -not $recipeSpecLong.PSObject.Properties['engineComponentId'] -and [string]$recipeSpecLong.speculation.profileId -ceq 'long' -and [string]$recipeSpecLong.speculation.engineId -ceq 'llama.cpp-b10698-vulkan') 'speculation: the plan runs on the built-in engine and is no recipe plan'
    Check ((Get-RefusalCode { Get-FastLlmPlan @common -KvContextProfile 'long' -RecipeId 'some-recipe' -Speculation 'ngram' }).message -like '*cannot be combined*') 'speculation: -Recipe with -Speculation is refused (a recipe is measured without speculation)'
    Check ((Get-RefusalCode { Get-FastLlmPlan @common -KvContextProfile 'long' -ContextSize 8192 -Speculation 'ngram' }).message -like '*cannot be combined*') 'speculation: -ContextSize with a context profile is still refused'

    # ---- 4. the argv: the none value is replaced IN PLACE, the extra arguments are appended, the draft path goes through the one helper ------------------
    $baseArgs=@($off.serverArguments)
    $ngramArgs=@($ngram.serverArguments)
    $at=[Array]::IndexOf($baseArgs,'--spec-type')
    Check ($at -ge 0 -and $baseArgs[$at+1] -ceq 'none' -and $ngramArgs[$at] -ceq '--spec-type' -and $ngramArgs[$at+1] -ceq 'ngram-simple') 'speculation argv: the none value after --spec-type is replaced IN PLACE by the row''s spec type'
    $expected=@($baseArgs);$expected[$at+1]='ngram-simple';$expected+=@('--spec-ngram-size-n','12','--spec-ngram-size-m','48')
    Check (Test-SameArguments $expected $ngramArgs) 'speculation argv: nothing else moves or changes; the row''s extra arguments are appended at the end, in row order'
    $mtpArgs=@($mtp.serverArguments)
    $expectedMtp=@($baseArgs);$expectedMtp[$at+1]='draft-mtp';$expectedMtp+=@('--spec-draft-model','<verified-draft>','--spec-draft-n-max','4')
    Check (Test-SameArguments $expectedMtp $mtpArgs) 'speculation argv: an mtp plan shows --spec-draft-model <verified-draft> before the row''s extra arguments'
    $built=@(& $module { param($A,$S) Get-FastLlmSpeculationArguments -Arguments $A -Speculation $S -DraftPath 'C:\Users\Test User\FastLLM\components\draft\test-mtp-draft\test-mtp-draft.gguf' } $baseArgs $mtp.speculation)
    Check ($built[$at+1] -ceq 'draft-mtp' -and ($built -ccontains 'C:\Users\Test User\FastLLM\components\draft\test-mtp-draft\test-mtp-draft.gguf') -and $built.Count -eq $baseArgs.Count+4) 'speculation argv: the builder puts the real draft path after --spec-draft-model'
    $joined=& $module { param($A) Join-FastLlmProcessArguments -Arguments $A } @($built)
    Check ($joined.Contains('--spec-draft-model "C:\Users\Test User\FastLLM\components\draft\test-mtp-draft\test-mtp-draft.gguf" --spec-draft-n-max 4')) 'speculation argv: a draft path with a space is quoted as one argument by Join-FastLlmProcessArguments (the helper that passes --model)'
    Check (-not [regex]::IsMatch($planSource,'spec-draft-model[^\r\n]*(\\"|`"|Quote)')) 'speculation argv: no new quoting code is written for the draft path'
    $specSourcePath=Join-Path $root 'src/FastLlm.Speculation.ps1'
    $specSource=Get-Content -LiteralPath $specSourcePath -Raw
    Check (-not [regex]::IsMatch($specSource,'(\\"|`"|Quote)')) 'speculation argv: FastLlm.Speculation.ps1 has no quoting code'
    Check ((Get-RefusalCode { & $module { Get-FastLlmSpeculationArguments -Arguments @('--model','m') -Speculation ([pscustomobject]@{mode='ngram';specType='ngram-simple';extraArguments=@()}) } }).message -like '*exactly one*') 'speculation argv: arguments without --spec-type are refused (nothing is appended)'
    Check ((Get-RefusalCode { & $module { Get-FastLlmSpeculationArguments -Arguments @('--spec-type','ngram-mod') -Speculation ([pscustomobject]@{mode='ngram';specType='ngram-simple';extraArguments=@()}) } }).message -like '*none*') 'speculation argv: arguments whose --spec-type value is not none are refused'
    foreach($tool in @('BackendParityDiagnostic','CpuReferenceLab','HipModelTrial','OffloadLab','SamplerDiagnostic','VulkanFitTrial','VulkanVidmemTrial')){
        $toolText=Get-Content -LiteralPath (Join-Path $root ('src/FastLlm.'+$tool+'.ps1')) -Raw
        Check ($toolText.Contains("'--spec-type'") -and $toolText.Contains("'none'") -and -not [regex]::IsMatch($toolText,'(?i)speculation-|ngram|--spec-draft')) "diagnostic tool $tool keeps --spec-type none and knows nothing about speculation"
    }

    # ---- 5. default off everywhere: the bench path, the saved settings, the background and sign-in starts never carry it -----------------------------------
    . (Join-Path $root 'src/FastLlm.ServingSettings.ps1')
    $resolved=Resolve-FastLlmServingOptions -InstallRoot $installRoot -Bound @{} -IgnoreUserSettings
    Check (-not $resolved.PSObject.Properties['speculation'] -and @($resolved.PSObject.Properties.Name).Count -eq 12) 'default off: no saved setting exists; Resolve-FastLlmServingOptions is unchanged (no speculation property)'
    $allOn=[pscustomobject]@{contextProfile='long';slots=2;embeddings='on';embeddingPort=8090;thinking='off';chatPage='on';idleStopMinutes=15}
    $planOptions=Get-FastLlmServingPlanOptions -Options $allOn -ConfigRoot (Join-Path $root 'config')
    Check (-not $planOptions.ContainsKey('Speculation') -and -not (Get-FastLlmServingServerOptions -Options $allOn).ContainsKey('Speculation')) 'default off: the shared serving options (used by start, the window and the sign-in start) never carry a speculation option'
    foreach($file in @('src/FastLlm.BackgroundHost.ps1','src/FastLlm.SignInStart.ps1','src/FastLlm.UiBackground.ps1','src/FastLlm.UiFlow.ps1','src/FastLlm.ServingSettings.ps1','src/FastLlm.ServingProfileRun.ps1','fast-llm-ui.ps1')){
        $text=Get-Content -LiteralPath (Join-Path $root $file) -Raw
        Check (-not [regex]::IsMatch($text,'(?i)-Speculation|\bSpeculation\s*=|speculation-not-measured|FastLlmSpeculation')) "bench and background paths: $file never asks for speculation"
    }
    $defaultPlan=Get-FastLlmPlan -Hardware $card -CatalogPath $catalogPath -Profile balanced -NoEngineExecution -InstallRoot $installRoot
    Check (-not $defaultPlan.PSObject.Properties['speculation'] -and (@($defaultPlan.serverArguments) -join ' ').Contains('--spec-type none')) 'default off: a direct planner call (the bench path) has --spec-type none and no speculation field'
    $startFunction=& $module { (Get-Command Start-FastLlmServer).ScriptBlock.ToString() }
    Check (-not [regex]::IsMatch($startFunction,'\$Speculation\b')) 'default off: Start-FastLlmServer has no speculation parameter; only a plan with a speculation block can ask for it'

    # ---- 6. the start check: refusals 4 and 5, in order, before any process, download or request file -----------------------------------------------
    function New-SpecWorld([string]$Label,[string]$Component){
        $install=Join-Path $work ('spec-world-'+$Label)
        $config=Join-Path $install 'config'
        foreach($folder in @($install,$config,(Join-Path $install 'state'))){New-Item -ItemType Directory -Path $folder -Force | Out-Null}
        [IO.File]::Copy($catalogPath,(Join-Path $config 'catalog.json'),$true)
        [IO.File]::Copy($specComponents,(Join-Path $config 'components.json'),$true)
        $entry=@((Get-Content -LiteralPath $specComponents -Raw | ConvertFrom-Json).components | Where-Object { $_.id -ceq 'test-mtp-draft' })[0]
        $componentRoot=& $module { param($I,$E) Get-FastLlmComponentRoot -InstallRoot $I -Component $E } $install $entry
        if($Component -cne 'missing'){
            New-Item -ItemType Directory -Path $componentRoot -Force | Out-Null
            $bytes=[Text.Encoding]::ASCII.GetBytes((('FastLLM test speculation draft fixture. Not a draft file. ')*4).Substring(0,192))
            if($Component -ceq 'corrupt'){$bytes[0]=[byte]0x58}
            [IO.File]::WriteAllBytes((Join-Path $componentRoot ([string]$entry.entryPoint)),$bytes)
            if($Component -cne 'no-consent'){ & $module { param($I,$E) Write-FastLlmComponentConsentReceipt -Component $E -InstallRoot $I -AcceptanceMode 'explicit-switch' } $install $entry }
        }
        return [pscustomobject]@{install=$install;catalog=(Join-Path $config 'catalog.json');components=(Join-Path $config 'components.json');componentRoot=$componentRoot}
    }
    function Get-TreeListing([string]$Folder){ return @(Get-ChildItem -LiteralPath $Folder -Recurse -Force | ForEach-Object { $_.FullName.Substring($Folder.Length)+'|'+$(if($_.PSIsContainer){'d'}else{[string]$_.Length}) } | Sort-Object) }
    $saved=& $module {
        @{ supervised=(Get-Command Invoke-FastLlmSupervisedServer).ScriptBlock; hardware=(Get-Command Get-FastLlmHardware).ScriptBlock; writeState=(Get-Command Write-FastLlmState).ScriptBlock
           prerequisites=(Get-Command Assert-FastLlmWindowsPrerequisites).ScriptBlock; install=(Get-Command Install-FastLlmModel).ScriptBlock; save=(Get-Command Save-FastLlmVerifiedFile).ScriptBlock }
    }
    $script:specCalls=New-Object 'Collections.Generic.List[string]'
    & $module {
        function script:Invoke-FastLlmSupervisedServer { $script:specCalls.Add('PROCESS-SUPERVISED') ; throw 'PROCESS-SUPERVISED' }
        function script:Get-FastLlmHardware { $script:specCalls.Add('PROBE-HARDWARE'); throw 'PROBE-HARDWARE' }
        function script:Write-FastLlmState { param($InstallRoot,$State,$FileName) $script:specCalls.Add('WRITE-STATE') }
        function script:Assert-FastLlmWindowsPrerequisites { $script:specCalls.Add('PAST-THE-SPECULATION-CHECK'); throw 'PAST-THE-SPECULATION-CHECK' }
        function script:Install-FastLlmModel { $script:specCalls.Add('DOWNLOAD-MODEL') }
        function script:Save-FastLlmVerifiedFile { $script:specCalls.Add('DOWNLOAD-FILE') }
    }
    & $module { param($Calls) $script:specCalls=$Calls } $script:specCalls
    try {
        function Invoke-SpecStart($World,$Plan){
            $script:specCalls.Clear()
            $before=Get-TreeListing $World.install
            $result=Get-RefusalCode { Start-FastLlmServer -Plan $Plan -CatalogPath $World.catalog -InstallRoot $World.install }
            $after=Get-TreeListing $World.install
            $result | Add-Member -NotePropertyName calls -NotePropertyValue @($script:specCalls) -Force
            $result | Add-Member -NotePropertyName changed -NotePropertyValue (($before -join "`n") -cne ($after -join "`n")) -Force
            return $result
        }
        $w4=New-SpecWorld 'missing' 'missing'
        $s4=Invoke-SpecStart $w4 $mtp
        Check ($s4.threw -and $s4.code -ceq 'needs-setup-component-missing' -and $s4.message -like '*test-mtp-draft*is not installed*A start never installs*Nothing was started*' -and $s4.calls.Count -eq 0 -and -not $s4.changed) 'speculation refusal 4: a draft file that is not installed is needs-setup-component-missing; no process, no probe, no download, no request or status file'
        $w4b=New-SpecWorld 'noconsent' 'no-consent'
        $s4b=Invoke-SpecStart $w4b $mtp
        Check ($s4b.threw -and $s4b.code -ceq 'needs-setup-component-missing' -and $s4b.calls.Count -eq 0 -and -not $s4b.changed) 'speculation refusal 4: an installed draft file whose license was not accepted counts as not installed'
        $w4c=New-SpecWorld 'unlisted' 'installed'
        Write-Utf8 $w4c.components '{"schema":"bitworks.fastllm-components/v1","components":[]}'
        $s4c=Invoke-SpecStart $w4c $mtp
        Check ($s4c.threw -and $s4c.code -ceq 'needs-setup-component-missing' -and $s4c.message -like '*not listed*' -and $s4c.calls.Count -eq 0 -and -not $s4c.changed) 'speculation refusal 4: a draft component that is not in the components list is refused the same way'
        $w5=New-SpecWorld 'corrupt' 'corrupt'
        $s5=Invoke-SpecStart $w5 $mtp
        Check ($s5.threw -and $s5.code -ceq 'needs-setup-component-missing' -and $s5.message -like '*failed its file check*pinned*Nothing was started*' -and $s5.calls.Count -eq 0 -and -not $s5.changed) 'speculation refusal 4: a draft file whose hash differs from the pin is refused (failed its file check); nothing runs'
        $w6=New-SpecWorld 'good' 'installed'
        $s6=Invoke-SpecStart $w6 $mtp
        Check ($s6.threw -and $s6.code -ceq 'speculation-evidence-unavailable' -and $s6.message -like '*Nothing was started*' -and $s6.calls.Count -eq 0 -and -not $s6.changed) 'speculation refusal 5 (pin): with a valid row, a profile value, a non-HIP plan, the draft installed and its hash matching, an mtp start is STILL refused: speculation-evidence-unavailable; nothing starts and no file is written'
        Check ($s6.message -ceq 'speculation-evidence-unavailable: Speculation with a draft file cannot be verified yet: FastLLM has no way yet to prove where the draft model is loaded (on the GPU or on the CPU), so a start with -Speculation mtp is not offered in this release. Nothing was started. To start without speculation, leave -Speculation off.') 'speculation refusal 5: the message says plainly that it cannot be verified yet and that nothing started'
        Check ($s6.reason -cne 'RuntimeCheckFailed' -and $s6.reason -cne 'PlanChanged' -and $s6.reason -cne 'ModelNeedsProvisioning' -and [string]::IsNullOrEmpty($s6.reason)) 'speculation refusal 5: no reason that the CLI would recover, re-plan or repair on'
        Check ((Invoke-SpecStart $w6 $mtp).message -ceq $s6.message) 'speculation refusal 5: the same every time'
        # Mutation proof: refusal 5 fires whenever every earlier check passes. The function with its final throw removed would pass this very
        # world, so the check above is not satisfied by an earlier refusal.
        $assertText=& $module { (Get-Command Assert-FastLlmSpeculationStartable).ScriptBlock.ToString() }
        $mutantText=[regex]::Replace($assertText,"throw \(New-FastLlmTypedFailure -Code 'speculation-evidence-unavailable'[^\r\n]*\)",'return')
        Check ($mutantText -cne $assertText -and $assertText.Contains("'speculation-evidence-unavailable'") -and -not $mutantText.Contains("'speculation-evidence-unavailable'")) 'mutation proof: the final throw of the start check is found and removed in a copy'
        $mutantResult=& $module { param($Text,$Plan,$Catalog,$Install,$Components)
            Set-Item -Path Function:script:Assert-FastLlmSpeculationStartableMutant -Value ([scriptblock]::Create($Text))
            try { Assert-FastLlmSpeculationStartableMutant -Plan $Plan -CatalogPath $Catalog -InstallRoot $Install -ComponentsPath $Components; return 'passed' } catch { return [string]$_.Exception.Data['FastLlmFailureCode'] }
        } $mutantText $mtp $w6.catalog $w6.install $w6.components
        Check ($mutantResult -ceq 'passed') 'mutation proof: without that throw every earlier mtp check passes in the good world, so only refusal 5 stands between it and a start'
        $w6dir=Join-Path $work 'spec-world-good-switch'
        # An ngram plan is startable by the check: it has no component and no evidence refusal.
        $ngramCheck=Get-RefusalCode { Assert-FastLlmSpeculationStartable -Plan $ngram -CatalogPath $w6.catalog -InstallRoot $w6.install }
        Check (-not $ngramCheck.threw) 'speculation start check: an ngram plan passes the start check (no component, no evidence refusal)'
        $ngramStart=Invoke-SpecStart $w6 $ngram
        Check ($ngramStart.threw -and $ngramStart.code -cne 'speculation-evidence-unavailable' -and $ngramStart.code -cnotlike 'speculation-*' -and @($ngramStart.calls) -contains 'PAST-THE-SPECULATION-CHECK' -and -not $ngramStart.changed) 'speculation start: the real Start-FastLlmServer lets an ngram plan through both speculation gates (it reaches the next start step, which the test stops)'
        $noBlock=Get-RefusalCode { Assert-FastLlmSpeculationStartable -Plan $off -CatalogPath $w6.catalog -InstallRoot $w6.install }
        Check (-not $noBlock.threw) 'speculation start check: a plan without a speculation block is not touched'
        $badBlock=$ngram | ConvertTo-Json -Depth 12 | ConvertFrom-Json
        $badBlock.speculation.specType='ngram-bogus'
        Check ((Get-RefusalCode { Assert-FastLlmSpeculationStartable -Plan $badBlock -CatalogPath $w6.catalog -InstallRoot $w6.install }).code -ceq 'speculation-invalid') 'speculation start check: a plan block whose spec type is outside the engine''s allowlist is refused (speculation-invalid)'
        $mismatch=$ngram | ConvertTo-Json -Depth 12 | ConvertFrom-Json
        $mismatch.serverArguments=@($mismatch.serverArguments | ForEach-Object { if($_ -ceq 'ngram-simple'){'none'}else{$_} })
        Check ((Get-RefusalCode { Assert-FastLlmSpeculationStartable -Plan $mismatch -CatalogPath $w6.catalog -InstallRoot $w6.install }).code -ceq 'speculation-invalid') 'speculation start check: a plan whose arguments do not carry its own spec type is refused (speculation-invalid)'
        # Start-FastLlmServer refuses a bad mtp plan before anything, exactly as for vision.
        $startMtp=Invoke-SpecStart $w6 $mtp
        Check ($startMtp.calls.Count -eq 0 -and -not $startMtp.changed) 'speculation start: Start-FastLlmServer refuses an mtp plan before any call or write'
    }
    finally {
        & $module { param($Saved)
            Set-Item -Path Function:script:Invoke-FastLlmSupervisedServer -Value $Saved.supervised
            Set-Item -Path Function:script:Get-FastLlmHardware -Value $Saved.hardware
            Set-Item -Path Function:script:Write-FastLlmState -Value $Saved.writeState
            Set-Item -Path Function:script:Assert-FastLlmWindowsPrerequisites -Value $Saved.prerequisites
            Set-Item -Path Function:script:Install-FastLlmModel -Value $Saved.install
            Set-Item -Path Function:script:Save-FastLlmVerifiedFile -Value $Saved.save
        } $saved
    }

    # ---- 7. self-test: comparable only when the expected numbers record the same speculation mode --------------------------------------------------
    $samples=@(1..2 | ForEach-Object { [pscustomobject]@{outputTokens=128;generationTokensPerSecond=40.0;promptTokensPerSecond=900.0} })
    $expectedBase=[pscustomobject]@{generationTokS=40.0;engineBuild='b10698';contextTokens=4096}
    $expectedNgram=[pscustomobject]@{generationTokS=40.0;engineBuild='b10698';contextTokens=4096;speculation='ngram-simple'}
    $verdictOff=& $module { param($S,$E) Get-FastLlmSelfTestVerdict -Samples $S -Expected $E -EngineBuild 'b10698' -ContextSize 4096 -MitigationEffective 'off' } $samples $expectedBase
    Check ($verdictOff.comparable -eq $true) 'self-test: with speculation off and expected numbers that name none (absent), the result is comparable (unchanged)'
    $verdictOn=& $module { param($S,$E) Get-FastLlmSelfTestVerdict -Samples $S -Expected $E -EngineBuild 'b10698' -ContextSize 4096 -MitigationEffective 'off' -SpeculationEffective 'ngram-simple' } $samples $expectedBase
    Check ($verdictOn.comparable -eq $false -and $verdictOn.status -ceq 'pass') 'self-test: with speculation on and expected numbers that do not record it (absent means none), the result is not comparable and not judged'
    $verdictSame=& $module { param($S,$E) Get-FastLlmSelfTestVerdict -Samples $S -Expected $E -EngineBuild 'b10698' -ContextSize 4096 -MitigationEffective 'off' -SpeculationEffective 'ngram-simple' } $samples $expectedNgram
    Check ($verdictSame.comparable -eq $true) 'self-test: with speculation on and expected numbers that record the same spec type, the result is comparable'
    $verdictOther=& $module { param($S,$E) Get-FastLlmSelfTestVerdict -Samples $S -Expected $E -EngineBuild 'b10698' -ContextSize 4096 -MitigationEffective 'off' -SpeculationEffective 'ngram-mod' } $samples $expectedNgram
    Check ($verdictOther.comparable -eq $false) 'self-test: expected numbers that record another spec type are not comparable'
    $verdictBack=& $module { param($S,$E) Get-FastLlmSelfTestVerdict -Samples $S -Expected $E -EngineBuild 'b10698' -ContextSize 4096 -MitigationEffective 'off' } $samples $expectedNgram
    Check ($verdictBack.comparable -eq $false) 'self-test: expected numbers measured with speculation are not comparable with a run that has it off'
    $slow=@(1..2 | ForEach-Object { [pscustomobject]@{outputTokens=128;generationTokensPerSecond=10.0;promptTokensPerSecond=900.0} })
    $slowOn=& $module { param($S,$E) Get-FastLlmSelfTestVerdict -Samples $S -Expected $E -EngineBuild 'b10698' -ContextSize 4096 -MitigationEffective 'off' -SpeculationEffective 'ngram-simple' } $slow $expectedBase
    Check ($slowOn.status -ceq 'pass' -and $slowOn.comparable -eq $false) 'self-test: a slow run with speculation on is never reported below-expected against numbers measured without it'

    # ---- 8. the benchmark tool refuses a run started with speculation on --------------------------------------------------------------------------------
    $refuse={ param($State) $text='accepted'; try { & $module { param($S) Assert-FastLlmBenchmarkDefaultSetup -State $S } $State } catch { $text=[string]$_.Exception.Message }; $text }
    $okState=[pscustomobject]@{active=$true;phase='ready';thinking='auto';chatPage='off';idleStopMinutes=0;recipe=[pscustomobject]@{requestedArguments=@('--model','<verified-model>','--no-ui')}}
    Check ((& $refuse $okState) -ceq 'accepted') 'benchmark: a default status is accepted (unchanged)'
    $specState=[pscustomobject]@{active=$true;phase='ready';thinking='auto';chatPage='off';idleStopMinutes=0;speculation=[pscustomobject]@{mode='ngram';specType='ngram-simple'};recipe=[pscustomobject]@{requestedArguments=@('--model','<verified-model>','--no-ui')}}
    Check ((& $refuse $specState) -ceq 'Benchmarks measure the default setup. Turn speculation off (-Speculation off), start again, then benchmark.') 'benchmark: a status with a speculation field is refused, as with the sidecar and the idle stop'
    $specRecipe=[pscustomobject]@{active=$true;phase='ready';thinking='auto';chatPage='off';idleStopMinutes=0;recipe=[pscustomobject]@{speculation='ngram-simple';requestedArguments=@('--model','<verified-model>','--no-ui')}}
    Check ((& $refuse $specRecipe) -ceq 'Benchmarks measure the default setup. Turn speculation off (-Speculation off), start again, then benchmark.') 'benchmark: a recipe whose speculation is not none is refused too'
    $benchSource=Get-Content -LiteralPath (Join-Path $root 'src/FastLlm.Benchmark.ps1') -Raw
    Check ($benchSource.IndexOf('Assert-FastLlmBenchmarkDefaultSetup -State $state') -gt 0) 'benchmark: the default-setup check still runs before any measurement'
    foreach($tool in @('tools/benchmark.ps1','tools/hip-benchmark.ps1','tools/concurrency-benchmark.ps1')){
        if(Test-Path -LiteralPath (Join-Path $root $tool)){ Check (-not [regex]::IsMatch((Get-Content -LiteralPath (Join-Path $root $tool) -Raw),'(?i)-Speculation')) "$tool never passes -Speculation" }
    }

    # ---- 9. the switch carries -Speculation exactly as it carries the profile ----------------------------------------------------------------------------
    $previous=$ngram
    $servingOptions=& $module { param($P) Get-FastLlmSwitchServingOptions -PreviousPlan $P } $previous
    Check ([string]$servingOptions.Speculation -ceq 'ngram' -and [string]$servingOptions.KvContextProfile -ceq 'long') 'switch: the serving options of a plan with speculation carry Speculation (and the profile), as #84 carries the profile'
    $plainOptions=& $module { param($P) Get-FastLlmSwitchServingOptions -PreviousPlan $P } $off
    Check (-not $plainOptions.ContainsKey('Speculation')) 'switch: a plan without speculation carries no Speculation option'
    $planOptionsSwitch=& $module { param($S,$C,$I) Get-FastLlmSwitchPlanOptions -ServingOptions $S -Request ([pscustomobject]@{modelId='qwen3.5-9b-q6-k';recipeId=$null}) -CatalogPath $C -InstallRoot $I } $servingOptions $catalogPath $installRoot
    Check ([string]$planOptionsSwitch.Speculation -ceq 'ngram' -and [string]$planOptionsSwitch.KvProfilesPath -clike '*serving-profiles.json') 'switch: the planner options of the target carry Speculation and the profiles file the row is read from'
    $targetOptions=@{};foreach($key in @($planOptionsSwitch.Keys)){ $targetOptions[$key]=$planOptionsSwitch[$key] }
    $targetOptions.Hardware=$card;$targetOptions.NoEngineExecution=$true;$targetOptions.KvProfilesPath=$specProfiles
    $targetPlan=Get-FastLlmPlan @targetOptions
    Check ($null -ne $targetPlan.speculation -and [string]$targetPlan.speculation.resultId -ceq 'test-ngram-0002' -and [string]$targetPlan.speculation.specType -ceq 'ngram-mod' -and (@($targetPlan.serverArguments) -join ' ').Contains('--spec-type ngram-mod')) 'switch: a target with a row is planned with its own row''s speculation'
    $noRowOptions=@{};foreach($key in @($targetOptions.Keys)){ $noRowOptions[$key]=$targetOptions[$key] }
    $noRowOptions.ModelId='qwen3.8-27b-q8-0'
    $noRow=Get-RefusalCode { Get-FastLlmPlan @noRowOptions }
    Check ($noRow.threw -and $noRow.code -ceq 'speculation-not-measured') 'switch: a target with no row is refused typed (speculation-not-measured); it is never planned, so never silently started without speculation'
    $switchSource=Get-Content -LiteralPath (Join-Path $root 'src/FastLlm.psm1') -Raw
    $loopStart=$switchSource.IndexOf('function Invoke-FastLlmSwitchLoop')
    Check ($loopStart -gt 0 -and -not [regex]::IsMatch($switchSource.Substring($loopStart),'(?s)\.Remove\(\s*[''"]Speculation|Speculation\s*=\s*[''"]off')) 'switch: nothing in the switch sequence drops or rewrites Speculation'
    $basisOptions=& $module { param($O) ConvertTo-FastLlmSwitchBasisPlanOptions -Options $O } $servingOptions
    Check ($null -ne $basisOptions -and [string]$basisOptions['Speculation'] -ceq 'ngram') 'switch: the saved basis of a run keeps Speculation (a closed value), so the picker asks the planner the same question'
    $badBasis=@{Profile='balanced';Speculation='draft-simple'}
    Check ($null -eq (& $module { param($O) ConvertTo-FastLlmSwitchBasisPlanOptions -Options $O } $badBasis)) 'switch: a basis with a Speculation value outside off|ngram|mtp is refused'

    Write-Host "speculation-tests (planner, allowlist, start check, self-test, benchmark, switch): $script:count checks passed"
}
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
