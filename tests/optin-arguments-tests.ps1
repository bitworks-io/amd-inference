#requires -Version 5.1
# Opt-in argument golden: the context profile and slots options. A plan with no option is today's plan, byte for byte; an option is honoured
# only from a measured profile row (model sha256 + engine id + backend) and is refused without one. The rows used here are TEST rows
# (tests/fixtures/serving-profiles-test.json); config/serving-profiles.json ships none. Pure planner work; no engine, GPU or network.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force -ErrorAction Stop
. (Join-Path $PSScriptRoot 'helpers/New-FastLlmDefaultArgumentsGolden.ps1')
. (Join-Path $PSScriptRoot 'helpers/New-FastLlmOptinArgumentsGolden.ps1')
$script:count=0
function Check($Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:count++;Write-Host "PASS: $Message"}
function Test-SameArguments($Expected,$Actual){$e=@($Expected);$a=@($Actual);if($e.Count -ne $a.Count){return $false};for($k=0;$k -lt $e.Count;$k++){if(-not ($e[$k] -ceq $a[$k])){return $false}};return $true}
# The refusal text must be exactly the expected one (ordinal), not merely contain it.
function RefusedExactly([scriptblock]$Action,[string]$Expected,[string]$Message) {
    $observed='no exception'
    try { & $Action | Out-Null } catch { $observed=[string]$_.Exception.Message }
    if(-not ($observed -ceq $Expected)){ $shown=[regex]::Replace($observed,'[\x00-\x1f\x7f]',' '); if($shown.Length -gt 240){$shown=$shown.Substring(0,240)}; throw "FAIL: $Message (observed: $shown)" }
    Check $true $Message
}
function RefusedLike([scriptblock]$Action,[string]$Pattern,[string]$Message) {
    $observed='no exception';$caught=$false
    try { & $Action | Out-Null } catch { $observed=[string]$_.Exception.Message; $caught=[bool]($observed -match $Pattern) }
    if(-not $caught){ $shown=[regex]::Replace($observed,'[\x00-\x1f\x7f]',' '); if($shown.Length -gt 240){$shown=$shown.Substring(0,240)}; throw "FAIL: $Message (observed: $shown)" }
    Check $true $Message
}
function Write-Utf8([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object Text.UTF8Encoding($false)))}
$notMeasured='Not measured for this model and engine.'

$work=Join-Path ([IO.Path]::GetTempPath()) ('optin-arguments-tests-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
try {
    $installRoot=Join-Path $work 'install'
    $catalogPath=Join-Path $root 'config/catalog.json'
    $testProfiles=Join-Path $root 'tests/fixtures/serving-profiles-test.json'
    $shippedProfiles=Join-Path $root 'config/serving-profiles.json'
    $golden=Get-Content -LiteralPath (Join-Path $root 'tests/fixtures/optin-server-arguments.json') -Raw | ConvertFrom-Json
    $goldenRows=@($golden.rows)

    # ---- the fixture is bound to the catalog and to the TEST profile rows it was planned from -------------------------------
    Check ($golden.schema -ceq 'fastllm.optin-arguments-golden.v1') 'optin golden schema'
    $catalogSha=((Get-Content -LiteralPath (Join-Path $root 'config/catalog.sha256') -Raw).Trim() -split '\s+')[0]
    Check ($golden.catalogSha256 -ceq $catalogSha) 'optin golden catalogSha256 equals config/catalog.sha256'
    Check ($golden.servingProfilesSha256 -ceq (Get-FileHash -LiteralPath $testProfiles -Algorithm SHA256).Hash.ToLowerInvariant()) 'optin golden is bound to the test profile rows by sha256'
    Check ($goldenRows.Count -ge 10 -and @($goldenRows | Where-Object { $_.outcome -ceq 'plan' }).Count -ge 5 -and @($goldenRows | Where-Object { $_.outcome -ceq 'refused' }).Count -ge 4) "optin golden has plan rows and refused rows ($($goldenRows.Count))"

    # ---- optin-golden-matches-live ----------------------------------------------------------------------------------------------
    $live=@(Get-FastLlmOptinArgumentsMatrix -Root $root -InstallRoot $installRoot)
    Check ($live.Count -eq $goldenRows.Count) "optin-golden-matches-live: row count ($($live.Count))"
    $differences=0
    for($i=0;$i -lt $goldenRows.Count -and $i -lt $live.Count;$i++){
        $g=$goldenRows[$i];$l=$live[$i]
        $same=($g.name -ceq $l.name) -and ($g.hardware -ceq $l.hardware) -and ($g.request -ceq $l.request) -and ($g.contextProfile -ceq $l.contextProfile) -and
              ([int]$g.slots -eq [int]$l.slots) -and ($g.thinking -ceq $l.thinking) -and ($g.chatPage -ceq $l.chatPage) -and ($g.outcome -ceq $l.outcome) -and
              ($g.refusal -ceq $l.refusal) -and ($g.modelId -ceq $l.modelId) -and ([int]$g.contextPerSlot -eq [int]$l.contextPerSlot) -and (Test-SameArguments $g.arguments $l.arguments)
        if(-not $same){$differences++;Write-Host "DIFF row $i name=$($g.name) live outcome=$($l.outcome) refusal=$($l.refusal)"}
    }
    Check ($differences -eq 0) 'optin-golden-matches-live: every row equal, -ceq on every argument and on every refusal text'

    # ---- substituted in place: an opt-in plan is the default plan of the same model with five values replaced, nothing moved ----
    function New-OptinAdapter([string]$Device,[int]$Vram,[int]$Free){
        return [pscustomobject]@{device=$Device;name='Opt-in test card';vendorId='1002';vramMiB=$Vram;freeVramMiB=$Free;isAmd=$true;isIntegrated=$false;backend='Vulkan';driverVersion='optin-test'}
    }
    function New-OptinHardware([string]$Name){
        $adapters=@()
        if($Name -ceq 'test-24gb'){$adapters=@((New-OptinAdapter 'Vulkan0' 24576 23552))}
        elseif($Name -ceq 'test-24gb-tight'){$adapters=@((New-OptinAdapter 'Vulkan0' 24576 21000))}
        elseif($Name -ceq 'test-12gb'){$adapters=@((New-OptinAdapter 'Vulkan0' 12272 11474))}
        elseif($Name -ceq 'test-dual-24gb'){$adapters=@((New-OptinAdapter 'Vulkan0' 24576 23552),(New-OptinAdapter 'Vulkan1' 24576 23552))}
        else{throw "Unknown opt-in test hardware '$Name'."}
        return [pscustomobject]@{schemaVersion=1;source='optin-test';backend='Vulkan';enginePath='C:\FastLLM\vulkan\llama-server.exe';adapters=$adapters}
    }
    $normalise={param([string]$Text) $t=$Text;foreach($v in @($installRoot,$installRoot.Replace('\','/'),$installRoot.Replace('/','\'))){if($v){$t=$t.Replace($v,'<install-root>')}};$t.Replace('\','/')}
    $valueFlags=@('--ctx-size','--parallel','--fit-target','--cache-type-k','--cache-type-v')
    $inPlaceBad=0;$inPlaceRows=0
    foreach($g in @($goldenRows | Where-Object { $_.outcome -ceq 'plan' })){
        $inPlaceRows++
        $base=Get-FastLlmPlan -Hardware (New-OptinHardware $g.hardware) -CatalogPath $catalogPath -Profile balanced -NoEngineExecution -InstallRoot $installRoot -ModelId $g.modelId -Thinking $g.thinking -ChatPage $g.chatPage
        $baseArgs=@($base.serverArguments | ForEach-Object { & $normalise ([string]$_) });$optArgs=@($g.arguments)
        $ok=($baseArgs.Count -eq $optArgs.Count)
        if($ok){
            $allowed=@($valueFlags | ForEach-Object { [Array]::IndexOf($baseArgs,$_)+1 })
            if(@($allowed | Where-Object { $_ -le 0 }).Count -ne 0){$ok=$false}
            for($j=0;$j -lt $baseArgs.Count;$j++){ if(-not ($baseArgs[$j] -ceq $optArgs[$j]) -and $allowed -notcontains $j){$ok=$false} }
        }
        if(-not $ok){$inPlaceBad++;Write-Host "DIFF in-place row $($g.name)"}
    }
    Check ($inPlaceBad -eq 0 -and $inPlaceRows -ge 5) "substituted-in-place: $inPlaceRows opt-in rows differ from the default plan of the same model only in the values of --ctx-size, --parallel, --fit-target, --cache-type-k and --cache-type-v"
    $longRow=@($goldenRows | Where-Object { $_.name -ceq 'long' })[0];$la=@($longRow.arguments)
    Check ($la[[Array]::IndexOf($la,'--ctx-size')+1] -ceq '65536' -and $la[[Array]::IndexOf($la,'--parallel')+1] -ceq '1' -and $la[[Array]::IndexOf($la,'--fit-target')+1] -ceq '896' -and $la[[Array]::IndexOf($la,'--cache-type-k')+1] -ceq 'q8_0' -and $la[[Array]::IndexOf($la,'--cache-type-v')+1] -ceq 'q8_0') 'long row: the values come from the profile row (65536, 1 slot, fit target 896, q8_0 K and V)'
    $twoRow=@($goldenRows | Where-Object { $_.name -ceq 'long-two-slots' })[0];$ta=@($twoRow.arguments)
    Check ($ta[[Array]::IndexOf($ta,'--ctx-size')+1] -ceq '65536' -and $ta[[Array]::IndexOf($ta,'--parallel')+1] -ceq '2' -and [int]$twoRow.contextPerSlot -eq 32768) 'long with 2 slots: --ctx-size stays the row total, --parallel is 2, and each slot gets total / slots'
    $splitRow=@($goldenRows | Where-Object { $_.name -ceq 'default-two-slots' })[0];$sa=@($splitRow.arguments)
    Check ($sa[[Array]::IndexOf($sa,'--ctx-size')+1] -ceq '32768' -and $sa[[Array]::IndexOf($sa,'--parallel')+1] -ceq '2' -and $sa[[Array]::IndexOf($sa,'--cache-type-k')+1] -ceq 'f16' -and [int]$splitRow.contextPerSlot -eq 16384) 'default profile with 2 slots: the measured total is split, 16384 per slot'
    $dualRow=@($goldenRows | Where-Object { $_.name -ceq 'long-two-slots-two-cards' })[0];$da=@($dualRow.arguments)
    Check ($da[$da.Count-2] -ceq '--tensor-split' -and $da[[Array]::IndexOf($da,'--split-mode')+1] -ceq 'layer') 'two cards: --tensor-split stays the last pair after the substitutions'
    $comboRow=@($goldenRows | Where-Object { $_.name -ceq 'long-thinking-off-chat-page-on' })[0];$ca=@($comboRow.arguments)
    Check ($ca[$ca.Count-2] -ceq '--reasoning' -and $ca[$ca.Count-1] -ceq 'off' -and -not ($ca -ccontains '--no-ui') -and ($ca -ccontains '--no-agent')) 'with Thinking off and the chat page on: one removal, one append, as on a default plan'
    foreach($g in @($goldenRows | Where-Object { $_.outcome -ceq 'plan' })){
        $ga=@($g.arguments)
        Check (($ga -ccontains '--no-mmproj') -and $ga[[Array]::IndexOf($ga,'--spec-type')+1] -ceq 'none' -and $ga[[Array]::IndexOf($ga,'--fit')+1] -ceq 'on' -and $ga[[Array]::IndexOf($ga,'--host')+1] -ceq '127.0.0.1' -and $ga[[Array]::IndexOf($ga,'--flash-attn')+1] -ceq 'auto') "opt-in row $($g.name) keeps --no-mmproj, --spec-type none, --fit on, --flash-attn auto and the loopback host"
    }

    # ---- fit uses the row's memory, not the catalog's -----------------------------------------------------------------------------
    Check (@($goldenRows | Where-Object { $_.name -ceq 'long-row-memory-explicit' })[0].refusal -ceq "Requested model 'qwen3.8-27b-ud-q4-k-m' does not fit the estimated current free-memory budget. No other model was substituted.") 'fit-uses-row-memory: 21000 MiB free fits the catalog number (20500) but not the long row (21500), so the explicit model is refused'
    Check (@($goldenRows | Where-Object { $_.name -ceq 'long-row-memory-auto' })[0].modelId -ceq 'qwen3.5-9b-q6-k') 'fit-uses-row-memory: the automatic pick moves to the best model whose long row fits'
    $tightDefault=Get-FastLlmPlan -Hardware (New-OptinHardware 'test-24gb-tight') -CatalogPath $catalogPath -Profile balanced -NoEngineExecution -InstallRoot $installRoot
    Check ([string]$tightDefault.model.id -ceq 'qwen3.8-27b-ud-q4-k-m') 'fit-uses-row-memory: the same card without the option still plans the larger model (today''s fit)'

    # ---- no-option plans are today's plans -------------------------------------------------------------------------------------
    $defaultGolden=Get-Content -LiteralPath (Join-Path $root 'tests/fixtures/default-server-arguments.json') -Raw | ConvertFrom-Json
    $defaultRows=@($defaultGolden.rows)
    $malformedProfiles=Join-Path $work 'malformed-profiles.json'
    Write-Utf8 $malformedProfiles '{ not json'
    $defaultCases=@(
        @{Label='-ContextProfile default -Slots 1';Parameters=@{ContextProfile='default';Slots=1}},
        @{Label='the test profile rows present and no option';Parameters=@{ServingProfilesPath=$testProfiles}},
        @{Label='the shipped profile file and explicit defaults';Parameters=@{ServingProfilesPath=$shippedProfiles;ContextProfile='default';Slots=1}},
        @{Label='a profile file that is not JSON and no option (the file is never read)';Parameters=@{ServingProfilesPath=$malformedProfiles}},
        @{Label='a profile path that does not exist and no option';Parameters=@{ServingProfilesPath=(Join-Path $work 'absent.json')}}
    )
    foreach($defaultCase in $defaultCases){
        $caseLive=@(Get-FastLlmDefaultArgumentsMatrix -Root $root -InstallRoot $installRoot -PlanParameters $defaultCase.Parameters)
        $caseDiffs=0
        if($caseLive.Count -ne $defaultRows.Count){$caseDiffs=-1}
        else{
            for($i=0;$i -lt $defaultRows.Count;$i++){
                $g=$defaultRows[$i];$l=$caseLive[$i]
                $same=($g.outcome -ceq $l.outcome) -and ($g.refusal -ceq $l.refusal) -and ($g.recipeId -ceq $l.recipeId) -and (Test-SameArguments $g.arguments $l.arguments)
                if(-not $same){$caseDiffs++}
            }
        }
        Check ($caseDiffs -eq 0) "default-golden: with $($defaultCase.Label) every one of the $($defaultRows.Count) default rows is equal, -ceq on every argument"
    }
    $fixtureHardware=Read-FastLlmJson (Join-Path $root 'tests/fixtures/rx-7900-xtx-24gb.json')
    $recipeCommon=@{Hardware=$fixtureHardware;CatalogPath=$catalogPath;RecipesPath=(Join-Path $root 'config/recipes.json');GpuVariantsPath=(Join-Path $root 'config/gpu-variants.json');Profile='balanced';NoEngineExecution=$true;InstallRoot=$installRoot}
    $plainPlan=Get-FastLlmPlan @recipeCommon
    $explicitDefaultPlan=Get-FastLlmPlan @recipeCommon -ContextProfile 'default' -Slots 1 -ServingProfilesPath $testProfiles
    Check (($plainPlan | ConvertTo-Json -Depth 12) -ceq ($explicitDefaultPlan | ConvertTo-Json -Depth 12)) 'no-option plan: the whole plan document is identical with the default option values spelled out'
    Check (-not $plainPlan.PSObject.Properties['servingProfile'] -and -not $explicitDefaultPlan.PSObject.Properties['servingProfile']) 'no-option plan: no servingProfile field'
    $baseJson=Get-Content -LiteralPath (Join-Path $root 'tests/fixtures/plan-json-base.json') -Raw | ConvertFrom-Json
    $addedNow=@(($explicitDefaultPlan | ConvertTo-Json -Depth 12 | ConvertFrom-Json).PSObject.Properties.Name | Where-Object { -not $baseJson.PSObject.Properties[$_] } | Sort-Object)
    Check (($addedNow -join ',') -ceq 'requestedChatPage,requestedServerPort,requestedThinking') 'no-option plan: the plan has exactly the fields it had before these options existed'
    # A card that is identified and has a measured recipe (the fixture card, planned on the Vulkan backend).
    $identifiedHardware=Read-FastLlmJson (Join-Path $root 'tests/fixtures/rx-7900-xt-20gb-identified.json')
    $identifiedHardware.backend='Vulkan';$identifiedHardware.adapters[0].device='Vulkan0';$identifiedHardware.adapters[0].backend='Vulkan'
    $identifiedCommon=@{Hardware=$identifiedHardware;CatalogPath=$catalogPath;RecipesPath=(Join-Path $root 'config/recipes.json');GpuVariantsPath=(Join-Path $root 'config/gpu-variants.json');Profile='balanced';NoEngineExecution=$true;InstallRoot=$installRoot}
    $measuredPlan=Get-FastLlmPlan @identifiedCommon
    $measuredDefaults=Get-FastLlmPlan @identifiedCommon -ContextProfile 'default' -Slots 1 -ServingProfilesPath $testProfiles
    Check ([string]$measuredPlan.selectionMode -ceq 'recipe' -and -not [string]::IsNullOrEmpty([string]$measuredPlan.recipe.id) -and [string]$measuredPlan.recipe.origin -ceq 'bitworks') 'no-option plan: the identified card plans a measured recipe'
    Check (($measuredPlan | ConvertTo-Json -Depth 12) -ceq ($measuredDefaults | ConvertTo-Json -Depth 12)) 'no-option plan: the recipe plan document is identical with the default option values spelled out'
    Check ([string](Get-FastLlmPlan @identifiedCommon -ContextProfile 'DEFAULT').recipe.id -ceq [string]$measuredPlan.recipe.id) 'no-option plan: DEFAULT is normalised to default and changes nothing'

    # ---- the plan document with an option ------------------------------------------------------------------------------------------
    $card=New-OptinHardware 'test-24gb'
    $optCommon=@{Hardware=$card;CatalogPath=$catalogPath;Profile='balanced';NoEngineExecution=$true;InstallRoot=$installRoot;ServingProfilesPath=$testProfiles}
    $defaultCardPlan=Get-FastLlmPlan -Hardware $card -CatalogPath $catalogPath -Profile balanced -NoEngineExecution -InstallRoot $installRoot
    $longTwo=Get-FastLlmPlan @optCommon -ContextProfile 'long' -Slots 2
    $block=$longTwo.servingProfile
    Check ($null -ne $block -and [string]$block.id -ceq 'long' -and [int]$block.slots -eq 2 -and [int]$block.contextTotal -eq 65536 -and [int]$block.contextPerSlot -eq 32768) 'opt-in plan: servingProfile carries the profile id, the slots, the total and the per-slot context'
    Check ([int]$block.requiredFreeVramMiB -eq 21500 -and [string]$block.engineId -ceq 'llama.cpp-b10698-vulkan' -and [string]$block.resultId -ceq 'test-serving-profile-0001') 'opt-in plan: servingProfile names the row memory, the engine id and the evidence result id'
    Check ([int]$longTwo.model.contextSize -eq 65536 -and [int]$longTwo.model.parallel -eq 2 -and [string]$longTwo.model.cacheTypeK -ceq 'q8_0' -and [string]$longTwo.model.cacheTypeV -ceq 'q8_0' -and [int]$longTwo.model.fitTargetMiB -eq 896 -and [int]$longTwo.model.requiredFreeVramMiB -eq 21500) 'opt-in plan: the plan model copy carries the row values (the total context, never the per-slot one)'
    Check ([int]$longTwo.catalogContextSize -eq 32768 -and [string]$longTwo.model.sha256 -ceq [string]$defaultCardPlan.model.sha256) 'opt-in plan: the catalog context and the model identity are unchanged'
    $extraNames=@($longTwo.PSObject.Properties.Name | Where-Object { -not $defaultCardPlan.PSObject.Properties[$_] })
    Check ($extraNames.Count -eq 1 -and $extraNames[0] -ceq 'servingProfile') 'opt-in plan: servingProfile is the only field added'
    Check ([string](Get-FastLlmPlan @optCommon -ContextProfile 'LONG').servingProfile.id -ceq 'long') 'opt-in plan: LONG is normalised to long'
    $slotsOnly=Get-FastLlmPlan @optCommon -Slots 2
    Check ([string]$slotsOnly.servingProfile.id -ceq 'default' -and [int]$slotsOnly.servingProfile.contextPerSlot -eq 16384 -and [int]$slotsOnly.model.contextSize -eq 32768) 'opt-in plan: slots alone uses the default profile row and reports the per-slot context'
    $again=Get-FastLlmPlan -Hardware $card -CatalogPath $catalogPath -Profile balanced -NoEngineExecution -InstallRoot $installRoot
    Check (Test-SameArguments $defaultCardPlan.serverArguments $again.serverArguments) 'opt-in plan: a default plan after an opt-in plan is the default again (no state is kept)'

    # ---- no row: refused with the exact reason -------------------------------------------------------------------------------------
    RefusedExactly { Get-FastLlmPlan -Hardware $card -CatalogPath $catalogPath -Profile balanced -NoEngineExecution -InstallRoot $installRoot -ContextProfile 'long' -ServingProfilesPath $shippedProfiles } $notMeasured 'no-row: long with the shipped (empty) profile file is refused with the exact reason'
    RefusedExactly { Get-FastLlmPlan -Hardware $card -CatalogPath $catalogPath -Profile balanced -NoEngineExecution -InstallRoot $installRoot -Slots 2 -ServingProfilesPath $shippedProfiles } $notMeasured 'no-row: 2 slots with the shipped (empty) profile file is refused with the exact reason'
    RefusedExactly { Get-FastLlmPlan -Hardware $card -CatalogPath $catalogPath -Profile balanced -NoEngineExecution -InstallRoot $installRoot -ContextProfile 'long' } $notMeasured 'no-row: long with no profile file given is refused with the exact reason'
    RefusedExactly { Get-FastLlmPlan -Hardware $card -CatalogPath $catalogPath -Profile balanced -NoEngineExecution -InstallRoot $installRoot -ContextProfile 'long' -ServingProfilesPath (Join-Path $work 'absent.json') } $notMeasured 'no-row: long with a profile file that does not exist is refused with the exact reason'
    RefusedExactly { Get-FastLlmPlan -Hardware $card -CatalogPath $catalogPath -Profile balanced -NoEngineExecution -InstallRoot $installRoot -ModelId 'qwen3.8-27b-ud-q4-k-m' -ContextProfile 'long' -ServingProfilesPath $shippedProfiles } $notMeasured 'no-row: an explicit model with the shipped profile file is refused with the exact reason'
    RefusedExactly { Get-FastLlmPlan @identifiedCommon -ContextProfile 'long' -ServingProfilesPath $shippedProfiles } $notMeasured 'no-row: a card with a measured recipe is refused too; the recipe is not run under the option'
    $shipped=Get-Content -LiteralPath $shippedProfiles -Raw | ConvertFrom-Json
    Check ($shipped.schema -ceq 'bitworks.fastllm-serving-profiles/v1' -and @($shipped.profiles).Count -eq 0 -and @($shipped.addOns).Count -eq 0 -and @($shipped.sidecars).Count -eq 0) 'the shipped profile file has the schema and no rows'

    # ---- engine binding: a row applies only when model sha256, engine id and backend all equal the plan's -----------------------
    function New-MutatedProfiles([string]$Name,[scriptblock]$Mutate){
        $document=Get-Content -LiteralPath $testProfiles -Raw | ConvertFrom-Json
        & $Mutate $document
        $path=Join-Path $work ($Name+'.json')
        Write-Utf8 $path ($document | ConvertTo-Json -Depth 8)
        return $path
    }
    $longFor={param($Document) @($Document.profiles | Where-Object { $_.modelId -ceq 'qwen3.8-27b-ud-q4-k-m' -and $_.id -ceq 'long' })[0]}
    $explicitLong=@{Hardware=$card;CatalogPath=$catalogPath;Profile='balanced';NoEngineExecution=$true;InstallRoot=$installRoot;ModelId='qwen3.8-27b-ud-q4-k-m';ContextProfile='long'}
    Check ([string](Get-FastLlmPlan @explicitLong -ServingProfilesPath $testProfiles).servingProfile.id -ceq 'long') 'engine-binding: the unchanged test row applies'
    $oneRow=New-MutatedProfiles 'one-row' { param($d) $d.profiles=@((& $longFor $d)) }
    Check ([string](Get-FastLlmPlan @explicitLong -ServingProfilesPath $oneRow).servingProfile.id -ceq 'long' -and [int](Get-FastLlmPlan @explicitLong -Slots 2 -ServingProfilesPath $oneRow).servingProfile.contextPerSlot -eq 32768) 'engine-binding: a file with exactly one row applies (a one-element list is still a list)'
    $oneSlot=New-MutatedProfiles 'one-slot' { param($d) $d.profiles=@((& $longFor $d)); $d.profiles[0].slotsAllowed=@(2) }
    Check ([int](Get-FastLlmPlan @explicitLong -Slots 2 -ServingProfilesPath $oneSlot).servingProfile.slots -eq 2) 'engine-binding: a row that allows exactly one slot count applies for that count'
    RefusedExactly { Get-FastLlmPlan @explicitLong -ServingProfilesPath $oneSlot } $notMeasured 'engine-binding: a row that allows only 2 slots does not apply to a 1-slot request'
    $noRows=New-MutatedProfiles 'no-rows' { param($d) $d.profiles=@() }
    RefusedExactly { Get-FastLlmPlan @explicitLong -ServingProfilesPath $noRows } $notMeasured 'engine-binding: a file with an empty row list is not measured'
    $profilesObject=Join-Path $work 'profiles-object.json'
    Write-Utf8 $profilesObject '{"schema":"bitworks.fastllm-serving-profiles/v1","profiles":{},"addOns":[],"sidecars":[]}'
    RefusedLike { Get-FastLlmPlan @explicitLong -ServingProfilesPath $profilesObject } 'serving-profiles-invalid' 'engine-binding: a row list that is not a list fails typed'
    $otherEngine=New-MutatedProfiles 'other-engine' { param($d) $r=& $longFor $d; $r.engineId='llama.cpp-hip-b11658'; $r.backend='hip' }
    RefusedExactly { Get-FastLlmPlan @explicitLong -ServingProfilesPath $otherEngine } $notMeasured 'engine-binding: a row for another engine (HIP) does not apply to the Vulkan plan'
    $newerEngine=New-MutatedProfiles 'newer-engine' { param($d) (& $longFor $d).engineId='llama.cpp-b99999-vulkan' }
    RefusedExactly { Get-FastLlmPlan @explicitLong -ServingProfilesPath $newerEngine } $notMeasured 'engine-binding: a row for another engine build does not apply (an engine change un-offers the option)'
    $otherBackend=New-MutatedProfiles 'other-backend' { param($d) (& $longFor $d).backend='hip' }
    RefusedExactly { Get-FastLlmPlan @explicitLong -ServingProfilesPath $otherBackend } $notMeasured 'engine-binding: a row for another backend does not apply'
    $otherSha=New-MutatedProfiles 'other-sha' { param($d) (& $longFor $d).modelSha256=('0'*64) }
    RefusedExactly { Get-FastLlmPlan @explicitLong -ServingProfilesPath $otherSha } $notMeasured 'engine-binding: a row for another model sha256 does not apply'
    $otherModelId=New-MutatedProfiles 'other-model-id' { param($d) (& $longFor $d).modelId='qwen3.8-27b-ud-q5-k-m' }
    RefusedExactly { Get-FastLlmPlan @explicitLong -ServingProfilesPath $otherModelId } $notMeasured 'engine-binding: a row whose model id is not the plan''s does not apply'
    $otherProfile=New-MutatedProfiles 'other-profile' { param($d) $d.profiles=@($d.profiles | Where-Object { -not ($_.modelId -ceq 'qwen3.8-27b-ud-q4-k-m' -and $_.id -ceq 'long') }) }
    RefusedExactly { Get-FastLlmPlan @explicitLong -ServingProfilesPath $otherProfile } $notMeasured 'engine-binding: the default profile row of the same model does not stand in for a missing long row'
    $rocmHardware=Read-FastLlmJson (Join-Path $root 'tests/fixtures/dual-rx-7900-xtx-24gb.json')
    RefusedExactly { Get-FastLlmPlan -Hardware $rocmHardware -CatalogPath $catalogPath -Profile balanced -NoEngineExecution -InstallRoot $installRoot -ContextProfile 'long' -ServingProfilesPath $testProfiles } $notMeasured 'engine-binding: a plan on another backend finds no row'

    # ---- a profile file that cannot be trusted is a failure, never a silent default --------------------------------------------
    $optLong=@{Hardware=$card;CatalogPath=$catalogPath;Profile='balanced';NoEngineExecution=$true;InstallRoot=$installRoot;ContextProfile='long'}
    RefusedLike { Get-FastLlmPlan @optLong -ServingProfilesPath $malformedProfiles } 'serving-profiles-invalid' 'invalid-file: a profile file that is not JSON fails typed when an option is on'
    $wrongSchema=New-MutatedProfiles 'wrong-schema' { param($d) $d.schema='bitworks.fastllm-serving-profiles/v2' }
    RefusedLike { Get-FastLlmPlan @optLong -ServingProfilesPath $wrongSchema } 'serving-profiles-invalid' 'invalid-file: an unexpected schema fails typed'
    $duplicateRow=New-MutatedProfiles 'duplicate-row' { param($d) $d.profiles=@($d.profiles)+@((& $longFor $d)) }
    RefusedLike { Get-FastLlmPlan @explicitLong -ServingProfilesPath $duplicateRow } 'serving-profiles-invalid' 'invalid-file: two rows for the same model, engine and profile fail typed (nothing is picked)'
    foreach($badRow in @(
            @{Name='bad-kv';Label='an unknown KV type';Mutate={ param($d) (& $longFor $d).cacheTypeK='q8_0 --host 0.0.0.0' }},
            @{Name='bad-context';Label='a context that is not a positive whole number';Mutate={ param($d) (& $longFor $d).contextTotal=-1 }},
            @{Name='odd-context';Label='a total that does not divide by the slots';Mutate={ param($d) (& $longFor $d).contextTotal=65537 }},
            @{Name='bad-slots';Label='a slot count outside 1 and 2';Mutate={ param($d) (& $longFor $d).slotsAllowed=@(1,2,4) }},
            @{Name='bad-memory';Label='a required memory that is not positive';Mutate={ param($d) (& $longFor $d).requiredFreeVramMiB=0 }},
            @{Name='bad-fit-target';Label='a fit target that is not a number';Mutate={ param($d) (& $longFor $d).fitTargetMiB='768 --no-fit' }})){
        $badPath=New-MutatedProfiles $badRow.Name $badRow.Mutate
        RefusedLike { Get-FastLlmPlan @explicitLong -Slots 2 -ServingProfilesPath $badPath } 'serving-profiles-invalid' "invalid-row: a matching row with $($badRow.Label) fails typed"
    }

    # ---- options that do not combine, and the closed parameter sets -------------------------------------------------------------
    RefusedLike { Get-FastLlmPlan @optCommon -ContextProfile 'long' -ContextSize 8192 } 'cannot be combined' 'combination: -ContextSize with a context profile is refused (the measured row sets the context)'
    RefusedLike { Get-FastLlmPlan @optCommon -Slots 2 -ContextSize 8192 } 'cannot be combined' 'combination: -ContextSize with 2 slots is refused'
    RefusedLike { Get-FastLlmPlan @identifiedCommon -RecipeId ([string]$measuredPlan.recipe.id) -ContextProfile 'long' -ServingProfilesPath $testProfiles } 'cannot be combined' 'combination: -Recipe with a context profile is refused'
    RefusedLike { Get-FastLlmPlan @identifiedCommon -RecipeId ([string]$measuredPlan.recipe.id) -Slots 2 -ServingProfilesPath $testProfiles } 'cannot be combined' 'combination: -Recipe with 2 slots is refused'
    $closed=0
    foreach($badProfile in @('short','x','banana','')){try{Get-FastLlmPlan @optCommon -ContextProfile $badProfile | Out-Null}catch{$closed++}}
    foreach($badSlots in @(0,3,4,-1)){try{Get-FastLlmPlan @optCommon -Slots $badSlots | Out-Null}catch{$closed++}}
    Check ($closed -eq 8) 'the planner parameters are closed sets: default|long and 1|2'

    # ---- recipes are measured for the default profile: an option uses profile rows on the estimated planner --------------------
    $recipeLong=Get-FastLlmPlan @identifiedCommon -ContextProfile 'long' -ServingProfilesPath $testProfiles
    Check ([string]$recipeLong.selectionMode -ceq 'auto' -and $null -eq $recipeLong.recipe.id -and [string]$recipeLong.recipe.origin -ceq 'estimated' -and $null -eq $recipeLong.recipe.expected) 'recipes: with an option the plan is not a recipe plan and carries no recipe speed expectation'
    Check (-not $recipeLong.PSObject.Properties['fallback'] -and [string]$recipeLong.model.id -ceq 'qwen3.5-9b-q6-k') 'recipes: the opt-in plan is no fallback plan; its model is the best one with a measured long row that fits this card'
    Check (@($recipeLong.recipe.skipped | Where-Object { $_ -like 'recipes not applied:*' }).Count -eq 1) 'recipes: the plan says why recipes were not applied'
    Check ([string]$recipeLong.servingProfile.id -ceq 'long' -and [string]$recipeLong.backend -ceq 'Vulkan' -and -not $recipeLong.PSObject.Properties['engineComponentId']) 'recipes: the opt-in plan runs on the built-in engine'

    # ---- the bench path: -PreferInstalledModels and direct calls without the parameters get today's plan -----------------------
    $benchPlan=Get-FastLlmPlan -Hardware $card -CatalogPath $catalogPath -Profile balanced -NoEngineExecution -InstallRoot $installRoot -PreferInstalledModels
    Check (-not $benchPlan.PSObject.Properties['servingProfile'] -and [int]$benchPlan.model.parallel -eq 1) 'bench path: a direct planner call without the options has no serving profile and one slot'

    Write-Host "optin-arguments-tests: $script:count checks passed"
}
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
