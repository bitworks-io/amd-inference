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
        elseif($Name -ceq 'test-24gb-22000'){$adapters=@((New-OptinAdapter 'Vulkan0' 24576 22000))}
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
        @{Label='-KvContextProfile default -KvSlots 1';Parameters=@{KvContextProfile='default';KvSlots=1}},
        @{Label='the test profile rows present and no option';Parameters=@{KvProfilesPath=$testProfiles}},
        @{Label='the shipped profile file and explicit defaults';Parameters=@{KvProfilesPath=$shippedProfiles;KvContextProfile='default';KvSlots=1}},
        @{Label='a profile file that is not JSON and no option (the file is never read)';Parameters=@{KvProfilesPath=$malformedProfiles}},
        @{Label='a profile path that does not exist and no option';Parameters=@{KvProfilesPath=(Join-Path $work 'absent.json')}}
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
    $explicitDefaultPlan=Get-FastLlmPlan @recipeCommon -KvContextProfile 'default' -KvSlots 1 -KvProfilesPath $testProfiles
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
    $measuredDefaults=Get-FastLlmPlan @identifiedCommon -KvContextProfile 'default' -KvSlots 1 -KvProfilesPath $testProfiles
    Check ([string]$measuredPlan.selectionMode -ceq 'recipe' -and -not [string]::IsNullOrEmpty([string]$measuredPlan.recipe.id) -and [string]$measuredPlan.recipe.origin -ceq 'bitworks') 'no-option plan: the identified card plans a measured recipe'
    Check (($measuredPlan | ConvertTo-Json -Depth 12) -ceq ($measuredDefaults | ConvertTo-Json -Depth 12)) 'no-option plan: the recipe plan document is identical with the default option values spelled out'
    Check ([string](Get-FastLlmPlan @identifiedCommon -KvContextProfile 'DEFAULT').recipe.id -ceq [string]$measuredPlan.recipe.id) 'no-option plan: DEFAULT is normalised to default and changes nothing'

    # ---- the plan document with an option ------------------------------------------------------------------------------------------
    $card=New-OptinHardware 'test-24gb'
    # A base parameter set with some keys replaced. Windows PowerShell 5.1 refuses a parameter given both in a splat and by name
    # (ParameterAlreadyBound) while PowerShell 7 lets the named one win, so no call here passes a splatted key by name again.
    function Join-TestSplat([hashtable]$Base,[hashtable]$Override){ $merged=$Base.Clone(); foreach($key in @($Override.Keys)){ $merged[$key]=$Override[$key] }; return $merged }
    $optCommon=@{Hardware=$card;CatalogPath=$catalogPath;Profile='balanced';NoEngineExecution=$true;InstallRoot=$installRoot;KvProfilesPath=$testProfiles}
    $defaultCardPlan=Get-FastLlmPlan -Hardware $card -CatalogPath $catalogPath -Profile balanced -NoEngineExecution -InstallRoot $installRoot
    $longTwo=Get-FastLlmPlan @optCommon -KvContextProfile 'long' -KvSlots 2
    $block=$longTwo.servingProfile
    Check ($null -ne $block -and [string]$block.id -ceq 'long' -and [int]$block.slots -eq 2 -and [int]$block.contextTotal -eq 65536 -and [int]$block.contextPerSlot -eq 32768) 'opt-in plan: servingProfile carries the profile id, the slots, the total and the per-slot context'
    Check ([int]$block.requiredFreeVramMiB -eq 21500 -and [string]$block.engineId -ceq 'llama.cpp-b10698-vulkan' -and [string]$block.resultId -ceq 'test-serving-profile-0001') 'opt-in plan: servingProfile names the row memory, the engine id and the evidence result id'
    Check ([int]$longTwo.model.contextSize -eq 65536 -and [int]$longTwo.model.parallel -eq 2 -and [string]$longTwo.model.cacheTypeK -ceq 'q8_0' -and [string]$longTwo.model.cacheTypeV -ceq 'q8_0' -and [int]$longTwo.model.fitTargetMiB -eq 896 -and [int]$longTwo.model.requiredFreeVramMiB -eq 21500) 'opt-in plan: the plan model copy carries the row values (the total context, never the per-slot one)'
    Check ([int]$longTwo.catalogContextSize -eq 32768 -and [string]$longTwo.model.sha256 -ceq [string]$defaultCardPlan.model.sha256) 'opt-in plan: the catalog context and the model identity are unchanged'
    $extraNames=@($longTwo.PSObject.Properties.Name | Where-Object { -not $defaultCardPlan.PSObject.Properties[$_] })
    Check ($extraNames.Count -eq 1 -and $extraNames[0] -ceq 'servingProfile') 'opt-in plan: servingProfile is the only field added'
    Check ([string](Get-FastLlmPlan @optCommon -KvContextProfile 'LONG').servingProfile.id -ceq 'long') 'opt-in plan: LONG is normalised to long'
    $slotsOnly=Get-FastLlmPlan @optCommon -KvSlots 2
    Check ([string]$slotsOnly.servingProfile.id -ceq 'default' -and [int]$slotsOnly.servingProfile.contextPerSlot -eq 16384 -and [int]$slotsOnly.model.contextSize -eq 32768) 'opt-in plan: slots alone uses the default profile row and reports the per-slot context'
    $again=Get-FastLlmPlan -Hardware $card -CatalogPath $catalogPath -Profile balanced -NoEngineExecution -InstallRoot $installRoot
    Check (Test-SameArguments $defaultCardPlan.serverArguments $again.serverArguments) 'opt-in plan: a default plan after an opt-in plan is the default again (no state is kept)'

    # ---- no row: refused with the exact reason -------------------------------------------------------------------------------------
    RefusedExactly { Get-FastLlmPlan -Hardware $card -CatalogPath $catalogPath -Profile balanced -NoEngineExecution -InstallRoot $installRoot -KvContextProfile 'long' -KvProfilesPath $shippedProfiles } $notMeasured 'no-row: long with the shipped (empty) profile file is refused with the exact reason'
    RefusedExactly { Get-FastLlmPlan -Hardware $card -CatalogPath $catalogPath -Profile balanced -NoEngineExecution -InstallRoot $installRoot -KvSlots 2 -KvProfilesPath $shippedProfiles } $notMeasured 'no-row: 2 slots with the shipped (empty) profile file is refused with the exact reason'
    RefusedExactly { Get-FastLlmPlan -Hardware $card -CatalogPath $catalogPath -Profile balanced -NoEngineExecution -InstallRoot $installRoot -KvContextProfile 'long' } $notMeasured 'no-row: long with no profile file given is refused with the exact reason'
    RefusedExactly { Get-FastLlmPlan -Hardware $card -CatalogPath $catalogPath -Profile balanced -NoEngineExecution -InstallRoot $installRoot -KvContextProfile 'long' -KvProfilesPath (Join-Path $work 'absent.json') } $notMeasured 'no-row: long with a profile file that does not exist is refused with the exact reason'
    RefusedExactly { Get-FastLlmPlan -Hardware $card -CatalogPath $catalogPath -Profile balanced -NoEngineExecution -InstallRoot $installRoot -ModelId 'qwen3.8-27b-ud-q4-k-m' -KvContextProfile 'long' -KvProfilesPath $shippedProfiles } $notMeasured 'no-row: an explicit model with the shipped profile file is refused with the exact reason'
    RefusedExactly { Get-FastLlmPlan @identifiedCommon -KvContextProfile 'long' -KvProfilesPath $shippedProfiles } $notMeasured 'no-row: a card with a measured recipe is refused too; the recipe is not run under the option'
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
    $explicitLong=@{Hardware=$card;CatalogPath=$catalogPath;Profile='balanced';NoEngineExecution=$true;InstallRoot=$installRoot;ModelId='qwen3.8-27b-ud-q4-k-m';KvContextProfile='long'}
    Check ([string](Get-FastLlmPlan @explicitLong -KvProfilesPath $testProfiles).servingProfile.id -ceq 'long') 'engine-binding: the unchanged test row applies'
    $oneRow=New-MutatedProfiles 'one-row' { param($d) $d.profiles=@((& $longFor $d)) }
    Check ([string](Get-FastLlmPlan @explicitLong -KvProfilesPath $oneRow).servingProfile.id -ceq 'long' -and [int](Get-FastLlmPlan @explicitLong -KvSlots 2 -KvProfilesPath $oneRow).servingProfile.contextPerSlot -eq 32768) 'engine-binding: a file with exactly one row applies (a one-element list is still a list)'
    $oneSlot=New-MutatedProfiles 'one-slot' { param($d) $d.profiles=@((& $longFor $d)); $d.profiles[0].slotsAllowed=@(2) }
    Check ([int](Get-FastLlmPlan @explicitLong -KvSlots 2 -KvProfilesPath $oneSlot).servingProfile.slots -eq 2) 'engine-binding: a row that allows exactly one slot count applies for that count'
    RefusedExactly { Get-FastLlmPlan @explicitLong -KvProfilesPath $oneSlot } $notMeasured 'engine-binding: a row that allows only 2 slots does not apply to a 1-slot request'
    $noRows=New-MutatedProfiles 'no-rows' { param($d) $d.profiles=@() }
    RefusedExactly { Get-FastLlmPlan @explicitLong -KvProfilesPath $noRows } $notMeasured 'engine-binding: a file with an empty row list is not measured'
    $profilesObject=Join-Path $work 'profiles-object.json'
    Write-Utf8 $profilesObject '{"schema":"bitworks.fastllm-serving-profiles/v1","profiles":{},"addOns":[],"sidecars":[]}'
    RefusedLike { Get-FastLlmPlan @explicitLong -KvProfilesPath $profilesObject } 'serving-profiles-invalid' 'engine-binding: a row list that is not a list fails typed'
    $otherEngine=New-MutatedProfiles 'other-engine' { param($d) $r=& $longFor $d; $r.engineId='llama.cpp-hip-b11658'; $r.backend='hip' }
    RefusedExactly { Get-FastLlmPlan @explicitLong -KvProfilesPath $otherEngine } $notMeasured 'engine-binding: a row for another engine (HIP) does not apply to the Vulkan plan'
    $newerEngine=New-MutatedProfiles 'newer-engine' { param($d) (& $longFor $d).engineId='llama.cpp-b99999-vulkan' }
    RefusedExactly { Get-FastLlmPlan @explicitLong -KvProfilesPath $newerEngine } $notMeasured 'engine-binding: a row for another engine build does not apply (an engine change un-offers the option)'
    $otherBackend=New-MutatedProfiles 'other-backend' { param($d) (& $longFor $d).backend='hip' }
    RefusedExactly { Get-FastLlmPlan @explicitLong -KvProfilesPath $otherBackend } $notMeasured 'engine-binding: a row for another backend does not apply'
    $otherSha=New-MutatedProfiles 'other-sha' { param($d) (& $longFor $d).modelSha256=('0'*64) }
    RefusedExactly { Get-FastLlmPlan @explicitLong -KvProfilesPath $otherSha } $notMeasured 'engine-binding: a row for another model sha256 does not apply'
    $otherModelId=New-MutatedProfiles 'other-model-id' { param($d) (& $longFor $d).modelId='qwen3.8-27b-ud-q5-k-m' }
    RefusedExactly { Get-FastLlmPlan @explicitLong -KvProfilesPath $otherModelId } $notMeasured 'engine-binding: a row whose model id is not the plan''s does not apply'
    $otherProfile=New-MutatedProfiles 'other-profile' { param($d) $d.profiles=@($d.profiles | Where-Object { -not ($_.modelId -ceq 'qwen3.8-27b-ud-q4-k-m' -and $_.id -ceq 'long') }) }
    RefusedExactly { Get-FastLlmPlan @explicitLong -KvProfilesPath $otherProfile } $notMeasured 'engine-binding: the default profile row of the same model does not stand in for a missing long row'
    $rocmHardware=Read-FastLlmJson (Join-Path $root 'tests/fixtures/dual-rx-7900-xtx-24gb.json')
    RefusedExactly { Get-FastLlmPlan -Hardware $rocmHardware -CatalogPath $catalogPath -Profile balanced -NoEngineExecution -InstallRoot $installRoot -KvContextProfile 'long' -KvProfilesPath $testProfiles } $notMeasured 'engine-binding: a plan on another backend finds no row'

    # ---- a profile file that cannot be trusted is a failure, never a silent default --------------------------------------------
    $optLong=@{Hardware=$card;CatalogPath=$catalogPath;Profile='balanced';NoEngineExecution=$true;InstallRoot=$installRoot;KvContextProfile='long'}
    RefusedLike { Get-FastLlmPlan @optLong -KvProfilesPath $malformedProfiles } 'serving-profiles-invalid' 'invalid-file: a profile file that is not JSON fails typed when an option is on'
    $wrongSchema=New-MutatedProfiles 'wrong-schema' { param($d) $d.schema='bitworks.fastllm-serving-profiles/v2' }
    RefusedLike { Get-FastLlmPlan @optLong -KvProfilesPath $wrongSchema } 'serving-profiles-invalid' 'invalid-file: an unexpected schema fails typed'
    $duplicateRow=New-MutatedProfiles 'duplicate-row' { param($d) $d.profiles=@($d.profiles)+@((& $longFor $d)) }
    RefusedLike { Get-FastLlmPlan @explicitLong -KvProfilesPath $duplicateRow } 'serving-profiles-invalid' 'invalid-file: two rows for the same model, engine and profile fail typed (nothing is picked)'
    foreach($badRow in @(
            @{Name='bad-kv';Label='an unknown KV type';Mutate={ param($d) (& $longFor $d).cacheTypeK='q8_0 --host 0.0.0.0' }},
            @{Name='bad-context';Label='a context that is not a positive whole number';Mutate={ param($d) (& $longFor $d).contextTotal=-1 }},
            @{Name='odd-context';Label='a total that does not divide by the slots';Mutate={ param($d) (& $longFor $d).contextTotal=65537 }},
            @{Name='bad-slots';Label='a slot count outside 1 and 2';Mutate={ param($d) (& $longFor $d).slotsAllowed=@(1,2,4) }},
            @{Name='bad-memory';Label='a required memory that is not positive';Mutate={ param($d) (& $longFor $d).requiredFreeVramMiB=0 }},
            @{Name='bad-fit-target';Label='a fit target that is not a number';Mutate={ param($d) (& $longFor $d).fitTargetMiB='768 --no-fit' }})){
        $badPath=New-MutatedProfiles $badRow.Name $badRow.Mutate
        RefusedLike { Get-FastLlmPlan @explicitLong -KvSlots 2 -KvProfilesPath $badPath } 'serving-profiles-invalid' "invalid-row: a matching row with $($badRow.Label) fails typed"
    }

    # ---- options that do not combine, and the closed parameter sets -------------------------------------------------------------
    RefusedLike { Get-FastLlmPlan @optCommon -KvContextProfile 'long' -ContextSize 8192 } 'cannot be combined' 'combination: -ContextSize with a context profile is refused (the measured row sets the context)'
    RefusedLike { Get-FastLlmPlan @optCommon -KvSlots 2 -ContextSize 8192 } 'cannot be combined' 'combination: -ContextSize with 2 slots is refused'
    RefusedLike { Get-FastLlmPlan @identifiedCommon -RecipeId ([string]$measuredPlan.recipe.id) -KvContextProfile 'long' -KvProfilesPath $testProfiles } 'cannot be combined' 'combination: -Recipe with a context profile is refused'
    RefusedLike { Get-FastLlmPlan @identifiedCommon -RecipeId ([string]$measuredPlan.recipe.id) -KvSlots 2 -KvProfilesPath $testProfiles } 'cannot be combined' 'combination: -Recipe with 2 slots is refused'
    $closed=0
    foreach($badProfile in @('short','x','banana','')){try{Get-FastLlmPlan @optCommon -KvContextProfile $badProfile | Out-Null}catch{$closed++}}
    foreach($badSlots in @(0,3,4,-1)){try{Get-FastLlmPlan @optCommon -KvSlots $badSlots | Out-Null}catch{$closed++}}
    Check ($closed -eq 8) 'the planner parameters are closed sets: default|long and 1|2'

    # ---- recipes are measured for the default profile: an option uses profile rows on the estimated planner --------------------
    $recipeLong=Get-FastLlmPlan @identifiedCommon -KvContextProfile 'long' -KvProfilesPath $testProfiles
    Check ([string]$recipeLong.selectionMode -ceq 'auto' -and $null -eq $recipeLong.recipe.id -and [string]$recipeLong.recipe.origin -ceq 'estimated' -and $null -eq $recipeLong.recipe.expected) 'recipes: with an option the plan is not a recipe plan and carries no recipe speed expectation'
    Check (-not $recipeLong.PSObject.Properties['fallback'] -and [string]$recipeLong.model.id -ceq 'qwen3.5-9b-q6-k') 'recipes: the opt-in plan is no fallback plan; its model is the best one with a measured long row that fits this card'
    Check (@($recipeLong.recipe.skipped | Where-Object { $_ -like 'recipes not applied:*' }).Count -eq 1) 'recipes: the plan says why recipes were not applied'
    Check ([string]$recipeLong.servingProfile.id -ceq 'long' -and [string]$recipeLong.backend -ceq 'Vulkan' -and -not $recipeLong.PSObject.Properties['engineComponentId']) 'recipes: the opt-in plan runs on the built-in engine'

    # ---- the bench path: -PreferInstalledModels and direct calls without the parameters get today's plan -----------------------
    $benchPlan=Get-FastLlmPlan -Hardware $card -CatalogPath $catalogPath -Profile balanced -NoEngineExecution -InstallRoot $installRoot -PreferInstalledModels
    Check (-not $benchPlan.PSObject.Properties['servingProfile'] -and [int]$benchPlan.model.parallel -eq 1) 'bench path: a direct planner call without the options has no serving profile and one slot'

    # =====================================================================================================================================
    # The vision option (-Vision on): the argv shape and every refusal. Every vision start ends in a typed refusal before any process starts
    # (nothing can verify where the projector is loaded yet), so these tests pin the shape and the fail-closed behaviour. TEST rows only
    # (tests/fixtures/vision-profiles-test.json, tests/fixtures/vision-components-test.json); config/ ships neither a row nor a projector.
    # =====================================================================================================================================
    $visionProfiles=Join-Path $root 'tests/fixtures/vision-profiles-test.json'
    $visionComponents=Join-Path $root 'tests/fixtures/vision-components-test.json'
    $module=Get-Module FastLlm
    function Get-RefusalCode([scriptblock]$Action){
        $observed=[ordered]@{threw=$false;code='';message='';reason=''}
        try { & $Action | Out-Null } catch { $observed.threw=$true;$observed.message=[string]$_.Exception.Message;$observed.code=[string]$_.Exception.Data['FastLlmFailureCode'];$observed.reason=[string]$_.Exception.Data['FastLlmReason'] }
        return [pscustomobject]$observed
    }
    $visionCard=New-OptinHardware 'test-24gb'
    $visionCommon=@{Hardware=$visionCard;CatalogPath=$catalogPath;Profile='balanced';NoEngineExecution=$true;InstallRoot=$installRoot;KvProfilesPath=$visionProfiles;ModelId='qwen3.8-27b-ud-q4-k-m'}

    # ---- the loader refuses what the checker refuses (tests/fixtures/vision-addon-parity-cases.json is read by both) ---------------
    $parity=Get-Content -LiteralPath (Join-Path $root 'tests/fixtures/vision-addon-parity-cases.json') -Raw | ConvertFrom-Json
    $visionDocument=Get-Content -LiteralPath $visionProfiles -Raw | ConvertFrom-Json
    $profilesJson=ConvertTo-Json -InputObject @($visionDocument.profiles) -Depth 10
    $parityMismatch=0;$parityCases=0
    foreach($case in @($parity.cases)){
        $parityCases++
        $caseFile=Join-Path $work ('parity-'+$parityCases+'.json')
        Write-Utf8 $caseFile ('{"schema":"bitworks.fastllm-serving-profiles/v1","profiles":'+$profilesJson+',"addOns":'+(ConvertTo-Json -InputObject $case.addOns -Depth 10)+',"sidecars":[]}')
        $loaderRefused=$false
        try { & $module { param($P) Read-FastLlmVisionAddOns -Path $P | Out-Null } $caseFile } catch { $loaderRefused=[bool]([string]$_.Exception.Data['FastLlmFailureCode'] -ceq 'serving-profiles-invalid') }
        if($loaderRefused -ne [bool]$case.refuse){$parityMismatch++;Write-Host "DIFF parity case $($case.name): checker refuses=$($case.refuse) loader refused=$loaderRefused"}
    }
    Check ($parityCases -ge 20 -and $parityMismatch -eq 0) "vision loader parity: the PowerShell loader and the checker give the same verdict on all $parityCases shared cases"
    $goodRows=@(& $module { param($P) Read-FastLlmVisionAddOns -Path $P } $visionProfiles)
    Check ($goodRows.Count -eq 2 -and [string]$goodRows[0].componentId -ceq 'test-vision-projector-q8') 'vision loader: the two test rows are read (a one-row file is a list too)'
    Check (@(& $module { param($P) Read-FastLlmVisionAddOns -Path $P } $shippedProfiles).Count -eq 0) 'vision loader: the shipped file has no add-on row'
    Check (@(& $module { param($P) Read-FastLlmVisionAddOns -Path $P } (Join-Path $work 'absent.json')).Count -eq 0) 'vision loader: no file is no rows'

    # ---- the speculation rows of the golden (the live matrix is planned from the TEST rows and compared with the checked-in file) ------------------------
    $speculationProfiles=Join-Path $root 'tests/fixtures/speculation-profiles-test.json'
    $specGolden=@($golden.speculationRows)
    Check ($specGolden.Count -ge 10 -and $golden.speculationProfilesSha256 -ceq (Get-FileHash -LiteralPath $speculationProfiles -Algorithm SHA256).Hash.ToLowerInvariant()) 'speculation golden: the rows are bound to the test speculation rows by sha256'
    $liveSpec=@(Get-FastLlmSpeculationArgumentsMatrix -Root $root -InstallRoot $installRoot)
    Check ($liveSpec.Count -eq $specGolden.Count) "speculation-golden-matches-live: row count ($($liveSpec.Count))"
    $specDiffs=0
    for($i=0;$i -lt $specGolden.Count -and $i -lt $liveSpec.Count;$i++){
        $g=$specGolden[$i];$l=$liveSpec[$i]
        $same=($g.name -ceq $l.name) -and ($g.hardware -ceq $l.hardware) -and ($g.request -ceq $l.request) -and ($g.mode -ceq $l.mode) -and ($g.contextProfile -ceq $l.contextProfile) -and ([int]$g.slots -eq [int]$l.slots) -and
              ($g.vision -ceq $l.vision) -and ($g.outcome -ceq $l.outcome) -and ($g.refusalCode -ceq $l.refusalCode) -and ($g.refusal -ceq $l.refusal) -and ($g.specType -ceq $l.specType) -and
              (Test-SameArguments $g.extraArguments $l.extraArguments) -and ([int]$g.extraFreeVramMiB -eq [int]$l.extraFreeVramMiB) -and ([int64]$g.requiredFreeVramMiB -eq [int64]$l.requiredFreeVramMiB) -and (Test-SameArguments $g.arguments $l.arguments)
        if(-not $same){$specDiffs++;Write-Host "DIFF speculation row $i name=$($g.name) live outcome=$($l.outcome) code=$($l.refusalCode)"}
    }
    Check ($specDiffs -eq 0) 'speculation-golden-matches-live: every row equal, -ceq on every argument and on every refusal text'
    $specPlanRows=@($specGolden | Where-Object { $_.outcome -ceq 'plan' })
    Check ($specPlanRows.Count -eq 5 -and @($specGolden | Where-Object { $_.outcome -ceq 'refused' }).Count -eq 5) 'speculation golden: five plan rows (ngram and mtp) and five refused rows'
    $ngramRowG=@($specGolden | Where-Object { $_.name -ceq 'ngram-long' })[0]
    $mtpRowG=@($specGolden | Where-Object { $_.name -ceq 'mtp-long' })[0]
    $nA=@($ngramRowG.arguments);$mA=@($mtpRowG.arguments)
    Check ($nA[[Array]::IndexOf($nA,'--spec-type')+1] -ceq 'ngram-simple' -and (($nA[($nA.Count-4)..($nA.Count-1)]) -join ' ') -ceq '--spec-ngram-size-n 12 --spec-ngram-size-m 48' -and -not ($nA -ccontains '--spec-draft-model')) 'speculation golden: an ngram row replaces none in place and appends the row''s extra arguments last'
    Check ($mA[[Array]::IndexOf($mA,'--spec-type')+1] -ceq 'draft-mtp' -and $mA[[Array]::IndexOf($mA,'--spec-draft-model')+1] -ceq '<verified-draft>' -and (($mA[($mA.Count-2)..($mA.Count-1)]) -join ' ') -ceq '--spec-draft-n-max 4') 'speculation golden: an mtp row names --spec-draft-model <verified-draft> and appends the row''s extra arguments last'
    Check ((@($specGolden | Where-Object { $_.outcome -ceq 'refused' } | ForEach-Object { $_.refusalCode }) -join ',') -ceq 'speculation-not-measured,speculation-not-measured,speculation-profile-not-measured,speculation-combination-not-offered,speculation-combination-not-offered') 'speculation golden: the refused rows carry the typed codes in order'

    # ---- off is today's plan: no field, no argument -----------------------------------------------------------------------------------
    $plainLong=Get-FastLlmPlan @optCommon -ModelId 'qwen3.8-27b-ud-q4-k-m'
    $offLong=Get-FastLlmPlan @optCommon -ModelId 'qwen3.8-27b-ud-q4-k-m' -Vision 'off'
    Check (($plainLong | ConvertTo-Json -Depth 12) -ceq ($offLong | ConvertTo-Json -Depth 12) -and -not $offLong.PSObject.Properties['vision']) 'vision off: -Vision off is byte-identical to no -Vision and adds no field'
    Check (($plainLong.serverArguments -ccontains '--no-mmproj') -and -not ($plainLong.serverArguments -ccontains '--mmproj')) 'vision off: the arguments keep --no-mmproj'
    Check (($defaultCardPlan.serverArguments -ccontains '--no-mmproj') -and -not ($defaultCardPlan.serverArguments -ccontains '--mmproj') -and -not $defaultCardPlan.PSObject.Properties['vision']) 'vision off: a direct planner call (the bench path) keeps --no-mmproj and has no vision field'
    $offVisionFile=& { $s=Join-TestSplat $optCommon @{KvProfilesPath=$malformedProfiles}; Get-FastLlmPlan @s -ModelId 'qwen3.8-27b-ud-q4-k-m' -KvContextProfile 'default' -Vision 'off' }
    Check ($null -ne $offVisionFile) 'vision off: the add-on rows are never read (a profile file that is not JSON changes nothing)'
    RefusedLike { Get-FastLlmPlan @visionCommon -Vision 'maybe' } 'Vision|validate|Valid' 'vision: the parameter is a closed set (off|on)'

    # ---- the argv: --no-mmproj is replaced IN PLACE by --mmproj and the path; nothing else moves -------------------------------------------
    $visionGolden=@($golden.visionRows)
    Check ($visionGolden.Count -ge 8 -and $golden.visionProfilesSha256 -ceq (Get-FileHash -LiteralPath $visionProfiles -Algorithm SHA256).Hash.ToLowerInvariant()) 'vision golden: the rows are bound to the test vision rows by sha256'
    $liveVision=@(Get-FastLlmVisionArgumentsMatrix -Root $root -InstallRoot $installRoot)
    Check ($liveVision.Count -eq $visionGolden.Count) "vision-golden-matches-live: row count ($($liveVision.Count))"
    $visionDiffs=0
    for($i=0;$i -lt $visionGolden.Count -and $i -lt $liveVision.Count;$i++){
        $g=$visionGolden[$i];$l=$liveVision[$i]
        $same=($g.name -ceq $l.name) -and ($g.hardware -ceq $l.hardware) -and ($g.request -ceq $l.request) -and ($g.contextProfile -ceq $l.contextProfile) -and ([int]$g.slots -eq [int]$l.slots) -and
              ($g.outcome -ceq $l.outcome) -and ($g.refusalCode -ceq $l.refusalCode) -and ($g.refusal -ceq $l.refusal) -and ($g.visionProfileId -ceq $l.visionProfileId) -and
              ([int]$g.extraFreeVramMiB -eq [int]$l.extraFreeVramMiB) -and ([int64]$g.requiredFreeVramMiB -eq [int64]$l.requiredFreeVramMiB) -and
              (Test-SameArguments $g.arguments $l.arguments) -and (Test-SameArguments $g.argumentsWithProjector $l.argumentsWithProjector)
        if(-not $same){$visionDiffs++;Write-Host "DIFF vision row $i name=$($g.name) live outcome=$($l.outcome) code=$($l.refusalCode)"}
    }
    Check ($visionDiffs -eq 0) 'vision-golden-matches-live: every row equal, -ceq on every argument and on every refusal text'
    $visionPlanRows=@($visionGolden | Where-Object { $_.outcome -ceq 'plan' })
    Check ($visionPlanRows.Count -ge 4) "vision golden: $($visionPlanRows.Count) plan rows"
    $replacedBad=0
    foreach($g in $visionPlanRows){
        $hardwareName=[string]$g.hardware
        $baseParameters=@{Hardware=(New-OptinHardware $hardwareName);CatalogPath=$catalogPath;Profile='balanced';NoEngineExecution=$true;InstallRoot=$installRoot;KvProfilesPath=$visionProfiles;ModelId=[string]$g.request;KvContextProfile=[string]$g.contextProfile;KvSlots=[int]$g.slots}
        $baseArgs=@((Get-FastLlmPlan @baseParameters).serverArguments | ForEach-Object { & $normalise ([string]$_) })
        $withProjector=@($g.argumentsWithProjector);$planArgs=@($g.arguments)
        $at=[Array]::IndexOf($baseArgs,'--no-mmproj')
        $expected=@();for($k=0;$k -lt $baseArgs.Count;$k++){ if($k -eq $at){$expected+=@('--mmproj','C:\Users\Test User\FastLLM\components\projector\test-vision-projector-q8\test-vision-projector-q8.gguf')}else{$expected+=$baseArgs[$k]} }
        $expectedPlan=@();for($k=0;$k -lt $baseArgs.Count;$k++){ if($k -eq $at){$expectedPlan+=@('--mmproj','<verified-projector>')}else{$expectedPlan+=$baseArgs[$k]} }
        $ok=($at -ge 0) -and (Test-SameArguments $expected $withProjector) -and (Test-SameArguments $expectedPlan $planArgs) -and ($withProjector.Count -eq $baseArgs.Count+1) -and -not ($withProjector -ccontains '--no-mmproj')
        if(-not $ok){$replacedBad++;Write-Host "DIFF in-place vision row $($g.name)"}
    }
    Check ($replacedBad -eq 0) 'vision argv: in every plan row the --no-mmproj element is replaced in place by --mmproj and the path; every other element keeps its place and value'
    $firstVision=$visionPlanRows[0];$fa=@($firstVision.argumentsWithProjector)
    Check ($fa[[Array]::IndexOf($fa,'--mmproj')+1] -ceq 'C:\Users\Test User\FastLLM\components\projector\test-vision-projector-q8\test-vision-projector-q8.gguf' -and [Array]::IndexOf($fa,'--mmproj') -eq [Array]::IndexOf($fa,'--offline')+1) 'vision argv: --mmproj sits where --no-mmproj was (right after --offline) and its path has a space'
    # The path with a space stays ONE argument through the same helper that passes --model today (no new quoting code).
    $joined=& $module { param($A) Join-FastLlmProcessArguments -Arguments $A } @($fa)
    Check ($joined.Contains('--mmproj "C:\Users\Test User\FastLLM\components\projector\test-vision-projector-q8\test-vision-projector-q8.gguf" --spec-type none')) 'vision argv: the projector path with a space is quoted as one argument by Join-FastLlmProcessArguments'
    $modelJoined=& $module { param($A) Join-FastLlmProcessArguments -Arguments $A } @('--model','C:\Users\Test User\m.gguf')
    Check ($modelJoined -ceq '--model "C:\Users\Test User\m.gguf"') 'vision argv: --model with a space is quoted the same way (the same helper)'
    $quoteSource=Get-Content -LiteralPath (Join-Path $root 'src/FastLlm.psm1') -Raw
    Check (-not [regex]::IsMatch($quoteSource,'mmproj[^\r\n]*(\\"|`"|Quote)')) 'vision argv: no new quoting code is written for the projector path'
    $builtTwice=@(& $module { param($A,$P) Get-FastLlmVisionArguments -Arguments $A -ProjectorPath $P } @($plainLong.serverArguments) 'C:\p q\a.gguf')
    Check ($builtTwice.Count -eq @($plainLong.serverArguments).Count+1 -and ($builtTwice -ccontains 'C:\p q\a.gguf') -and -not ($builtTwice -ccontains '--no-mmproj')) 'vision argv: the builder replaces the one element and adds the path'
    RefusedLike { & $module { Get-FastLlmVisionArguments -Arguments @('--model','m') -ProjectorPath 'p.gguf' } } 'exactly one' 'vision argv: arguments without --no-mmproj are refused (nothing is appended)'
    RefusedLike { & $module { Get-FastLlmVisionArguments -Arguments @('--no-mmproj','--no-mmproj') -ProjectorPath 'p.gguf' } } 'exactly one' 'vision argv: two --no-mmproj elements are refused'
    RefusedLike { & $module { Get-FastLlmVisionArguments -Arguments @('--no-mmproj') -ProjectorPath '' } } 'projector path' 'vision argv: an empty projector path is refused'

    # ---- the planner: lookup, effective profile id and fit; refusals 1 and 2, in that order ------------------------------------------------
    $visionLong=Get-FastLlmPlan @visionCommon -KvContextProfile 'long' -Vision 'on'
    $vb=$visionLong.vision
    Check ($null -ne $vb -and [string]$vb.componentId -ceq 'test-vision-projector-q8' -and [string]$vb.profileId -ceq 'long' -and [int]$vb.extraFreeVramMiB -eq 1200 -and [int64]$vb.requiredFreeVramMiB -eq 22700 -and [string]$vb.resultId -ceq 'test-vision-addon-0001') 'vision plan: the vision block names the projector component, the profile id, the extra memory (1200), the total (21500 + 1200) and the evidence id'
    Check ([string]$vb.engineId -ceq 'llama.cpp-b10698-vulkan' -and [string]$vb.backend -ceq 'vulkan' -and [string]$vb.modelSha256 -ceq [string]$visionLong.model.sha256 -and [string]$vb.startRefusal -ceq 'vision-evidence-unavailable') 'vision plan: the block carries the model sha256, the engine id and backend, and says the start is refused (vision-evidence-unavailable)'
    $longNoVision=Get-FastLlmPlan @visionCommon -KvContextProfile 'long'
    $visionExtra=@($visionLong.PSObject.Properties.Name | Where-Object { -not $longNoVision.PSObject.Properties[$_] })
    Check ($visionExtra.Count -eq 1 -and $visionExtra[0] -ceq 'vision') 'vision plan: vision is the only field added to the opt-in plan'
    Check ([int]$visionLong.servingProfile.requiredFreeVramMiB -eq 21500 -and [int]$visionLong.model.requiredFreeVramMiB -eq 21500) 'vision plan: the profile row''s own requirement is unchanged; the extra memory is added in the vision block only'
    $visionArgs=@($visionLong.serverArguments)
    Check (($visionArgs -ccontains '--mmproj') -and $visionArgs[[Array]::IndexOf($visionArgs,'--mmproj')+1] -ceq '<verified-projector>' -and -not ($visionArgs -ccontains '--no-mmproj')) 'vision plan: the planned arguments show --mmproj <verified-projector> in place of --no-mmproj'
    $visionDefaultTwo=Get-FastLlmPlan @visionCommon -KvSlots 2 -Vision 'on'
    Check ([string]$visionDefaultTwo.vision.profileId -ceq 'default' -and [int]$visionDefaultTwo.vision.extraFreeVramMiB -eq 900 -and [int64]$visionDefaultTwo.vision.requiredFreeVramMiB -eq 21400) 'vision plan: 2 slots with the default context profile is keyed on profile id default (900 extra)'
    # Step 1: no matching add-on row.
    $r1=Get-RefusalCode { $s=Join-TestSplat $visionCommon @{ModelId='qwen3.8-27b-q8-0'}; Get-FastLlmPlan @s -KvContextProfile 'long' -Vision 'on' }
    Check ($r1.threw -and $r1.code -ceq 'vision-not-measured' -and $r1.message -like 'vision-not-measured: *Nothing was started*') 'vision refusal 1: a model without a vision add-on row is refused (vision-not-measured)'
    $r1b=Get-RefusalCode { $s=Join-TestSplat $visionCommon @{KvProfilesPath=$testProfiles}; Get-FastLlmPlan @s -KvContextProfile 'long' -Vision 'on' }
    Check ($r1b.threw -and $r1b.code -ceq 'vision-not-measured') 'vision refusal 1: the profile file of the opt-in rows has no add-on row, so the option is refused'
    $r1c=Get-RefusalCode { $s=Join-TestSplat $visionCommon @{KvProfilesPath=$shippedProfiles}; Get-FastLlmPlan @s -KvContextProfile 'long' -Vision 'on' }
    Check ($r1c.threw -and $r1c.code -ceq 'vision-not-measured') 'vision refusal 1: the shipped file (addOns is empty) refuses every vision plan'
    $r1d=Get-RefusalCode { $s=Join-TestSplat $visionCommon @{KvProfilesPath=(Join-Path $work 'absent.json')}; Get-FastLlmPlan @s -KvContextProfile 'long' -Vision 'on' }
    Check ($r1d.threw -and $r1d.code -ceq 'vision-not-measured') 'vision refusal 1: no profile file is no row'
    foreach($mut in @(
            @{Name='v-other-sha';Label='another model sha256';Mutate={ param($d) $d.addOns[0].modelSha256=('0'*64) }},
            @{Name='v-other-engine';Label='another engine build';Mutate={ param($d) $d.addOns[0].engineId='llama.cpp-b99999-vulkan' }},
            @{Name='v-hip-engine';Label='the HIP engine and backend';Mutate={ param($d) $d.addOns[0].engineId='llama.cpp-hip-b11658'; $d.addOns[0].backend='hip' }},
            @{Name='v-other-backend';Label='another backend';Mutate={ param($d) $d.addOns[0].backend='hip' }})){
        $mutDocument=Get-Content -LiteralPath $visionProfiles -Raw | ConvertFrom-Json
        & $mut.Mutate $mutDocument
        $mutPath=Join-Path $work ($mut.Name+'-vision.json')
        Write-Utf8 $mutPath ($mutDocument | ConvertTo-Json -Depth 10)
        $rm=Get-RefusalCode { $s=Join-TestSplat $visionCommon @{KvProfilesPath=$mutPath}; Get-FastLlmPlan @s -KvContextProfile 'long' -Vision 'on' }
        Check ($rm.threw -and $rm.code -ceq 'vision-not-measured') "vision refusal 1: a row for $($mut.Label) does not apply to this plan"
    }
    RefusedLike { $s=Join-TestSplat $visionCommon @{KvProfilesPath=$malformedProfiles}; Get-FastLlmPlan @s -KvContextProfile 'long' -Vision 'on' } 'serving-profiles-invalid' 'vision: a profile file that is not JSON fails typed (never honoured, never dropped)'
    $mtpDocument=Get-Content -LiteralPath $visionProfiles -Raw | ConvertFrom-Json
    $mtpDocument.addOns[0].kind='mtp'
    $mtpPath=Join-Path $work 'vision-mtp.json'
    Write-Utf8 $mtpPath ($mtpDocument | ConvertTo-Json -Depth 10)
    RefusedLike { $s=Join-TestSplat $visionCommon @{KvProfilesPath=$mtpPath}; Get-FastLlmPlan @s -KvContextProfile 'long' -Vision 'on' } 'serving-profiles-invalid' 'vision: an mtp row in the file fails typed (the loader refuses what the checker refuses)'
    # Step 2: a row, but no value for the effective profile.
    $r2=Get-RefusalCode { Get-FastLlmPlan @visionCommon -Vision 'on' }
    Check ($r2.threw -and $r2.code -ceq 'vision-profile-not-measured' -and $r2.message -like '*Nothing was started*') 'vision refusal 2: a default-context plan has no profile id to key a value on, so it is refused (vision-profile-not-measured)'
    $r2b=Get-RefusalCode { Get-FastLlmPlan @visionCommon -KvContextProfile 'default' -KvSlots 1 -Vision 'on' }
    Check ($r2b.threw -and $r2b.code -ceq 'vision-profile-not-measured') 'vision refusal 2: explicit default values are the same default-context plan and are refused the same way'
    $r2c=Get-RefusalCode { Get-FastLlmPlan -Hardware (New-OptinHardware 'test-12gb') -CatalogPath $catalogPath -Profile balanced -NoEngineExecution -InstallRoot $installRoot -KvProfilesPath $visionProfiles -ModelId 'qwen3.5-9b-q6-k' -KvContextProfile 'default' -Vision 'on' }
    Check ($r2c.threw -and $r2c.code -ceq 'vision-profile-not-measured') 'vision refusal 2: a row with a value only for long is refused for the default profile'
    $r2d=Get-RefusalCode { Get-FastLlmPlan -Hardware (New-OptinHardware 'test-24gb') -CatalogPath $catalogPath -Profile balanced -NoEngineExecution -InstallRoot $installRoot -KvProfilesPath $visionProfiles -ModelId 'qwen3.5-9b-q6-k' -KvContextProfile 'long' -Vision 'on' }
    Check (-not $r2d.threw) 'vision plan: the same row with a value for long plans'
    $rOrder=Get-RefusalCode { $s=Join-TestSplat $visionCommon @{ModelId='qwen3.8-27b-q8-0'}; Get-FastLlmPlan @s -Vision 'on' }
    Check ($rOrder.threw -and $rOrder.code -ceq 'vision-not-measured') 'vision order: with no row AND no profile id, refusal 1 (no row) comes before refusal 2'
    # Fit: the extra memory is the row's, added to the profile's requirement. Nothing is derived.
    $fitCard=New-OptinHardware 'test-24gb-22000'
    $fitCommon=@{Hardware=$fitCard;CatalogPath=$catalogPath;Profile='balanced';NoEngineExecution=$true;InstallRoot=$installRoot;KvProfilesPath=$visionProfiles;ModelId='qwen3.8-27b-ud-q4-k-m';KvContextProfile='long'}
    Check ([string](Get-FastLlmPlan @fitCommon).servingProfile.id -ceq 'long') 'vision fit: with 22000 MiB free the long row alone (21500) fits'
    $rFit=Get-RefusalCode { Get-FastLlmPlan @fitCommon -Vision 'on' }
    Check ($rFit.threw -and $rFit.code -ceq 'model-does-not-fit') 'vision fit: the same card with vision on needs 21500 + 1200 and does not fit (the existing model-does-not-fit refusal)'
    $extraChanged=Get-Content -LiteralPath $visionProfiles -Raw | ConvertFrom-Json
    $extraChanged.addOns[0].extraFreeVramMiB.long=400
    $extraPath=Join-Path $work 'vision-small-extra.json'
    Write-Utf8 $extraPath ($extraChanged | ConvertTo-Json -Depth 10)
    $fitSmall=& { $s=Join-TestSplat $fitCommon @{KvProfilesPath=$extraPath}; Get-FastLlmPlan @s -Vision 'on' }
    Check ([int64]$fitSmall.vision.requiredFreeVramMiB -eq 21900) 'vision fit: the number comes from the row (21500 + 400 = 21900 fits 22000); no constant, file size or formula is used'
    RefusedLike { Get-FastLlmPlan @visionCommon -KvContextProfile 'long' -RecipeId 'some-recipe' -Vision 'on' } 'cannot be combined' 'vision: -Recipe with -Vision on is refused (a recipe is measured without a projector)'
    RefusedLike { Get-FastLlmPlan @visionCommon -KvContextProfile 'long' -ContextSize 8192 -Vision 'on' } 'cannot be combined' 'vision: -ContextSize with a context profile is still refused'
    $recipeVision=Get-RefusalCode { Get-FastLlmPlan @identifiedCommon -KvProfilesPath $visionProfiles -Vision 'on' }
    Check ($recipeVision.threw -and $recipeVision.code -ceq 'vision-profile-not-measured' -and -not ($recipeVision.message -like '*engine*probe*')) 'vision: on a card with a measured recipe, vision does not apply the recipe (no engine is probed); a default-context plan is refused for want of a profile id'
    $recipeVisionLong=Get-FastLlmPlan @identifiedCommon -KvContextProfile 'long' -KvProfilesPath $visionProfiles -Vision 'on'
    Check ([string]$recipeVisionLong.selectionMode -ceq 'auto' -and -not $recipeVisionLong.PSObject.Properties['engineComponentId'] -and [string]$recipeVisionLong.vision.profileId -ceq 'long') 'vision: the vision plan runs on the built-in engine and is no recipe plan'

    # ---- HIP: #60 has no HIP rule of its own for long or 2 slots; its engine binding is what keeps a HIP plan out, and vision reuses it -------------
    $hipRefused=Get-RefusalCode { Get-FastLlmPlan -Hardware $rocmHardware -CatalogPath $catalogPath -Profile balanced -NoEngineExecution -InstallRoot $installRoot -KvContextProfile 'long' -KvProfilesPath $visionProfiles -Vision 'on' }
    Check ($hipRefused.threw -and $hipRefused.code -ceq 'vision-not-measured') 'vision HIP: a plan on another backend finds no vision row (the same engine and backend binding as the opt-in rows)'
    $planSource=Get-Content -LiteralPath (Join-Path $root 'src/FastLlm.psm1') -Raw
    Check (-not [regex]::IsMatch($planSource,'(?i)\bvision\b[^\r\n]*\bhip\b|\bhip\b[^\r\n]*\bvision\b')) 'vision HIP: no new HIP rule is written for vision'

    # ---- the diagnostic tools keep --no-mmproj, nothing else is touched ---------------------------------------------------------------
    foreach($tool in @('BackendParityDiagnostic','CpuReferenceLab','HipModelTrial','OffloadLab','SamplerDiagnostic','VulkanFitTrial','VulkanVidmemTrial')){
        $toolText=Get-Content -LiteralPath (Join-Path $root ('src/FastLlm.'+$tool+'.ps1')) -Raw
        Check ($toolText.Contains('--no-mmproj') -and -not [regex]::IsMatch($toolText,'--mmproj')) "diagnostic tool $tool keeps --no-mmproj and has no --mmproj"
    }
    . (Join-Path $root 'src/FastLlm.ServingSettings.ps1')
    $resolvedNow=Resolve-FastLlmServingOptions -InstallRoot $installRoot -Bound @{} -IgnoreUserSettings
    Check (-not $resolvedNow.PSObject.Properties['vision'] -and @($resolvedNow.PSObject.Properties.Name).Count -eq 12) 'vision: no saved setting exists: Resolve-FastLlmServingOptions is unchanged (no vision property)'

    # ---- Start: refusals 4, 5 and 6, in order, before any process, download or request file ---------------------------------------------------
    # The golden helper re-imports the module (-Force): take the instance that is loaded now.
    $module=Get-Module FastLlm
    function New-VisionWorld([string]$Label,[string]$Component){
        $install=Join-Path $work ('vision-world-'+$Label)
        $config=Join-Path $install 'config'
        foreach($folder in @($install,$config,(Join-Path $install 'state'))){New-Item -ItemType Directory -Path $folder -Force | Out-Null}
        [IO.File]::Copy($catalogPath,(Join-Path $config 'catalog.json'),$true)
        [IO.File]::Copy($visionComponents,(Join-Path $config 'components.json'),$true)
        $entry=@((Get-Content -LiteralPath $visionComponents -Raw | ConvertFrom-Json).components)[0]
        $componentRoot=& $module { param($I,$E) Get-FastLlmComponentRoot -InstallRoot $I -Component $E } $install $entry
        if($Component -cne 'missing'){
            New-Item -ItemType Directory -Path $componentRoot -Force | Out-Null
            $bytes=[Text.Encoding]::ASCII.GetBytes((('FastLLM test vision projector fixture. Not a projector. ')*4).Substring(0,192))
            if($Component -ceq 'corrupt'){$bytes[0]=[byte]0x58}
            [IO.File]::WriteAllBytes((Join-Path $componentRoot ([string]$entry.entryPoint)),$bytes)
            if($Component -cne 'no-consent'){ & $module { param($I,$E) Write-FastLlmComponentConsentReceipt -Component $E -InstallRoot $I -AcceptanceMode 'explicit-switch' } $install $entry }
        }
        return [pscustomobject]@{install=$install;catalog=(Join-Path $config 'catalog.json');components=(Join-Path $config 'components.json');componentRoot=$componentRoot}
    }
    function Get-TreeListing([string]$Folder){ return @(Get-ChildItem -LiteralPath $Folder -Recurse -Force | ForEach-Object { $_.FullName.Substring($Folder.Length)+'|'+$(if($_.PSIsContainer){'d'}else{[string]$_.Length}) } | Sort-Object) }
    # The module's process, download and state boundaries are replaced by recorders for these checks, and put back after.
    $savedBoundaries=& $module {
        @{ supervised=(Get-Command Invoke-FastLlmSupervisedServer).ScriptBlock; hardware=(Get-Command Get-FastLlmHardware).ScriptBlock; writeState=(Get-Command Write-FastLlmState).ScriptBlock
           prerequisites=(Get-Command Assert-FastLlmWindowsPrerequisites).ScriptBlock; install=(Get-Command Install-FastLlmModel).ScriptBlock; save=(Get-Command Save-FastLlmVerifiedFile).ScriptBlock }
    }
    $script:visionCalls=New-Object 'Collections.Generic.List[string]'
    & $module {
        function script:Invoke-FastLlmSupervisedServer { $script:visionCalls.Add('PROCESS-SUPERVISED') ; throw 'PROCESS-SUPERVISED' }
        function script:Get-FastLlmHardware { $script:visionCalls.Add('PROBE-HARDWARE'); throw 'PROBE-HARDWARE' }
        function script:Write-FastLlmState { param($InstallRoot,$State,$FileName) $script:visionCalls.Add('WRITE-STATE') }
        function script:Assert-FastLlmWindowsPrerequisites { $script:visionCalls.Add('PAST-THE-VISION-CHECK'); throw 'PAST-THE-VISION-CHECK' }
        function script:Install-FastLlmModel { $script:visionCalls.Add('DOWNLOAD-MODEL') }
        function script:Save-FastLlmVerifiedFile { $script:visionCalls.Add('DOWNLOAD-FILE') }
    }
    & $module { param($Calls) $script:visionCalls=$Calls } $script:visionCalls
    try {
        $visionPlanForStart=Get-FastLlmPlan @visionCommon -KvContextProfile 'long' -Vision 'on'
        function Invoke-VisionStart($World,$Plan,[hashtable]$Extra=@{}){
            $script:visionCalls.Clear()
            $before=Get-TreeListing $World.install
            $result=Get-RefusalCode { Start-FastLlmServer -Plan $Plan -CatalogPath $World.catalog -InstallRoot $World.install @Extra }
            $after=Get-TreeListing $World.install
            $result | Add-Member -NotePropertyName calls -NotePropertyValue @($script:visionCalls) -Force
            $result | Add-Member -NotePropertyName changed -NotePropertyValue (($before -join "`n") -cne ($after -join "`n")) -Force
            return $result
        }
        $w4=New-VisionWorld 'missing' 'missing'
        $s4=Invoke-VisionStart $w4 $visionPlanForStart
        Check ($s4.threw -and $s4.code -ceq 'needs-setup-component-missing' -and $s4.message -like "*test-vision-projector-q8*is not installed*A start never installs*Nothing was started*" -and $s4.calls.Count -eq 0 -and -not $s4.changed) 'vision refusal 4: a projector that is not installed is needs-setup-component-missing; no process, no probe, no download, no request or status file'
        $w4b=New-VisionWorld 'noconsent' 'no-consent'
        $s4b=Invoke-VisionStart $w4b $visionPlanForStart
        Check ($s4b.threw -and $s4b.code -ceq 'needs-setup-component-missing' -and $s4b.calls.Count -eq 0 -and -not $s4b.changed) 'vision refusal 4: an installed projector whose license was not accepted counts as not installed'
        $w4c=New-VisionWorld 'unlisted' 'installed'
        [IO.File]::WriteAllText($w4c.components,'{"schema":"bitworks.fastllm-components/v1","components":[]}',(New-Object Text.UTF8Encoding($false)))
        $s4c=Invoke-VisionStart $w4c $visionPlanForStart
        Check ($s4c.threw -and $s4c.code -ceq 'needs-setup-component-missing' -and $s4c.message -like '*not listed*' -and $s4c.calls.Count -eq 0 -and -not $s4c.changed) 'vision refusal 4: a projector component that is not in the components list is refused the same way'
        $w5=New-VisionWorld 'corrupt' 'corrupt'
        $s5=Invoke-VisionStart $w5 $visionPlanForStart
        Check ($s5.threw -and $s5.code -ceq 'needs-setup-component-missing' -and $s5.message -like "*failed its file check*pinned*Nothing was started*" -and $s5.calls.Count -eq 0 -and -not $s5.changed) 'vision refusal 5: a projector whose hash differs from the pin is refused (needs-setup-component-missing, "failed its file check"); nothing runs'
        $w6=New-VisionWorld 'good' 'installed'
        $s6=Invoke-VisionStart $w6 $visionPlanForStart
        Check ($s6.threw -and $s6.code -ceq 'vision-evidence-unavailable' -and $s6.message -like '*cannot be verified yet*' -and $s6.message -like '*Nothing was started*' -and $s6.calls.Count -eq 0 -and -not $s6.changed) 'vision refusal 6 (pin): with a valid row, a profile value, a non-HIP plan, the projector installed and its hash matching, the start is STILL refused: vision-evidence-unavailable; nothing starts and no file is written'
        Check ($s6.message -ceq 'vision-evidence-unavailable: Vision cannot be verified yet: FastLLM has no way yet to prove where the vision projector is loaded (on the GPU or on the CPU), so a start with vision is not offered in this release. Nothing was started. To start without vision, leave -Vision off.') 'vision refusal 6: the message says plainly that vision cannot be verified yet and that nothing started'
        Check ($s6.reason -cne 'RuntimeCheckFailed' -and $s6.reason -cne 'PlanChanged' -and $s6.reason -cne 'ModelNeedsProvisioning') 'vision refusal 6: no reason that the CLI would recover, re-plan or repair on'
        $s6again=Invoke-VisionStart $w6 $visionPlanForStart
        Check ($s6again.code -ceq 'vision-evidence-unavailable' -and $s6again.message -ceq $s6.message) 'vision refusal 6: the same every time'
        $w6b=New-VisionWorld 'good-switch' 'installed'
        $s7=Invoke-VisionStart $w6b $visionPlanForStart @{AllowSwitch=$true}
        Check ($s7.threw -and $s7.code -ceq 'vision-evidence-unavailable' -and $s7.calls.Count -eq 0 -and -not $s7.changed) 'vision with -AllowSwitch: refused at the same point (vision-evidence-unavailable) and nothing starts, so a switch can never carry vision'
        $s7missing=Invoke-VisionStart $w4 $visionPlanForStart @{AllowSwitch=$true}
        Check ($s7missing.code -ceq 'needs-setup-component-missing' -and $s7missing.calls.Count -eq 0) 'vision with -AllowSwitch: an earlier refusal (4) still comes first'
        $s6emb=Invoke-VisionStart $w6 $visionPlanForStart @{Embeddings='on'}
        Check ($s6emb.threw -and $s6emb.code -ceq 'vision-evidence-unavailable' -and $s6emb.calls.Count -eq 0 -and -not $s6emb.changed) 'vision with embeddings on: refused first, no sidecar session is started'
        # The same assertion the CLI start branch calls right after the plan, before any model download.
        $direct=Get-RefusalCode { Assert-FastLlmVisionStartable -Plan $visionPlanForStart -CatalogPath $w6.catalog -InstallRoot $w6.install }
        Check ($direct.threw -and $direct.code -ceq 'vision-evidence-unavailable') 'vision: Assert-FastLlmVisionStartable (the check the CLI runs before any download) refuses with the same code'
        $directMissing=Get-RefusalCode { Assert-FastLlmVisionStartable -Plan $visionPlanForStart -CatalogPath $w4.catalog -InstallRoot $w4.install }
        Check ($directMissing.code -ceq 'needs-setup-component-missing') 'vision: Assert-FastLlmVisionStartable refuses a missing projector first'
        # A plan without vision is not touched: -IgnoreUserSettings, the bench path and a direct supervisor call all have such a plan.
        $defaultPlanForStart=Get-FastLlmPlan -Hardware $visionCard -CatalogPath $catalogPath -Profile balanced -NoEngineExecution -InstallRoot $installRoot -ModelId 'qwen3.8-27b-ud-q4-k-m'
        $sDefault=Invoke-VisionStart $w6 $defaultPlanForStart
        Check ($sDefault.threw -and $sDefault.message -ceq 'PAST-THE-VISION-CHECK' -and $sDefault.code -cne 'vision-evidence-unavailable') 'vision off: a plan without vision goes straight past the vision check (the start continues as it always did)'
        Check (($defaultPlanForStart.serverArguments -ccontains '--no-mmproj') -and -not ($defaultPlanForStart.serverArguments -ccontains '--mmproj')) 'vision off: the arguments a direct start would pass keep --no-mmproj'
        $forgedPlan=$defaultPlanForStart | ConvertTo-Json -Depth 12 | ConvertFrom-Json
        $forgedPlan | Add-Member -NotePropertyName vision -NotePropertyValue ([pscustomobject]@{componentId='test-vision-projector-q8'}) -Force
        $sForged=Invoke-VisionStart $w6 $forgedPlan
        Check ($sForged.threw -and $sForged.code -ceq 'vision-evidence-unavailable' -and $sForged.calls.Count -eq 0) 'vision: a plan that carries any vision block can never start (a vision block with fields missing is refused too)'
        # A HIP plan with a vision block is refused the same way: vision never starts on any plan.
        $hipForged=$visionPlanForStart | ConvertTo-Json -Depth 12 | ConvertFrom-Json
        $hipForged.backend='hip'
        $sHip=Invoke-VisionStart $w6 $hipForged
        Check ($sHip.threw -and $sHip.code -ceq 'vision-evidence-unavailable' -and $sHip.calls.Count -eq 0) 'vision: a HIP plan with a vision block is refused too (it never starts)'
    }
    finally {
        & $module {
            param($Saved)
            Set-Item -Path Function:script:Invoke-FastLlmSupervisedServer -Value $Saved.supervised
            Set-Item -Path Function:script:Get-FastLlmHardware -Value $Saved.hardware
            Set-Item -Path Function:script:Write-FastLlmState -Value $Saved.writeState
            Set-Item -Path Function:script:Assert-FastLlmWindowsPrerequisites -Value $Saved.prerequisites
            Set-Item -Path Function:script:Install-FastLlmModel -Value $Saved.install
            Set-Item -Path Function:script:Save-FastLlmVerifiedFile -Value $Saved.save
        } $savedBoundaries
    }

    # ---- the start-time re-plan keeps -Vision (real Start-FastLlmServer) --------------------------------------------------------------------
    # Today every vision plan is refused at the top of Start-FastLlmServer, before the re-plan, so this is latent. The refusal is replaced here by a
    # function that returns (standing for a future release that can verify the projector), so the re-plan is what is under test: it must forward the
    # MODE, re-derive the block from the rows, and refuse typed when the block changed. The old block is never copied onto the fresh plan.
    $rpWorld=Join-Path $work 'replan-world'
    $rpConfig=Join-Path $rpWorld 'config'
    foreach($folder in @($rpWorld,$rpConfig)){New-Item -ItemType Directory -Path $folder -Force | Out-Null}
    $rpCatalog=Join-Path $rpConfig 'catalog.json'
    $rpProfiles=Join-Path $rpConfig 'serving-profiles.json'
    [IO.File]::Copy($catalogPath,$rpCatalog,$true)
    [IO.File]::Copy($visionProfiles,$rpProfiles,$true)
    $rpBoundaries=& $module {
        @{ vision=(Get-Command Assert-FastLlmVisionStartable).ScriptBlock; prerequisites=(Get-Command Assert-FastLlmWindowsPrerequisites).ScriptBlock
           engineInstall=(Get-Command Test-FastLlmEngineInstallation).ScriptBlock; engineExe=(Get-Command Get-FastLlmEngineExecutable).ScriptBlock
           hash=(Get-Command Test-FastLlmFileHash).ScriptBlock; consent=(Get-Command Test-FastLlmModelConsentReceipt).ScriptBlock
           hardware=(Get-Command Get-FastLlmHardware).ScriptBlock; supervised=(Get-Command Invoke-FastLlmSupervisedServer).ScriptBlock }
    }
    & $module {
        param($Card)
        $script:rpCard=$Card
        $script:rpCaptured=$null
        $script:rpHardwareCalls=0
        function script:Assert-FastLlmVisionStartable { param($Plan,$CatalogPath,$InstallRoot) }
        function script:Assert-FastLlmWindowsPrerequisites { }
        function script:Test-FastLlmEngineInstallation { return $true }
        function script:Get-FastLlmEngineExecutable { return 'C:\FastLLM\vulkan\llama-server.exe' }
        function script:Test-FastLlmFileHash { return $true }
        function script:Test-FastLlmModelConsentReceipt { return $true }
        function script:Get-FastLlmHardware { $script:rpHardwareCalls++; return $script:rpCard }
        function script:Invoke-FastLlmSupervisedServer { param($Plan) $script:rpCaptured=$Plan; return 0 }
    } $visionCard
    try {
        function Get-RpArgument($Arguments,[string]$Flag){ $list=@($Arguments);$at=[Array]::IndexOf($list,$Flag); if($at -lt 0){return '<absent>'}; return [string]$list[$at+1] }
        function Invoke-RpStart($Plan){
            & $module { $script:rpCaptured=$null;$script:rpHardwareCalls=0 }
            $result=Get-RefusalCode { Start-FastLlmServer -Plan $Plan -CatalogPath $rpCatalog -InstallRoot $rpWorld }
            $result | Add-Member -NotePropertyName captured -NotePropertyValue (& $module { $script:rpCaptured }) -Force
            $result | Add-Member -NotePropertyName hardwareCalls -NotePropertyValue ([int](& $module { $script:rpHardwareCalls })) -Force
            return $result
        }
        $rpCommon=@{Hardware=$visionCard;CatalogPath=$rpCatalog;Profile='balanced';NoEngineExecution=$true;InstallRoot=$rpWorld;KvProfilesPath=$rpProfiles;ModelId='qwen3.8-27b-ud-q4-k-m';KvContextProfile='long'}
        $rpPlan=Get-FastLlmPlan @rpCommon -Vision 'on'
        New-Item -ItemType Directory -Path (Split-Path -Parent $rpPlan.modelPath) -Force | Out-Null
        [IO.File]::WriteAllText($rpPlan.modelPath,'x')
        $rpRun=Invoke-RpStart $rpPlan
        $rpBlock=$null
        if($null -ne $rpRun.captured -and $rpRun.captured.PSObject.Properties['vision']){$rpBlock=$rpRun.captured.vision}
        Check (-not $rpRun.threw -and $rpRun.hardwareCalls -eq 1 -and $null -ne $rpRun.captured) 'vision re-plan: with the start refusal stood down, the real start re-plans once and reaches the supervisor'
        Check ($null -ne $rpBlock -and [string]$rpBlock.componentId -ceq [string]$rpPlan.vision.componentId -and [string]$rpBlock.profileId -ceq [string]$rpPlan.vision.profileId -and [int]$rpBlock.extraFreeVramMiB -eq [int]$rpPlan.vision.extraFreeVramMiB -and [string]$rpBlock.resultId -ceq [string]$rpPlan.vision.resultId) 'vision re-plan: the plan the supervisor gets has the vision block (same projector component, profile id, extra memory and evidence id)'
        $rpArgs=@(); if($null -ne $rpRun.captured){$rpArgs=@($rpRun.captured.serverArguments)}
        Check (($rpArgs -ccontains '--mmproj') -and -not ($rpArgs -ccontains '--no-mmproj')) 'vision re-plan: the arguments the supervisor gets have --mmproj and no --no-mmproj'
        Check ($null -ne $rpRun.captured -and [string]$rpRun.captured.servingProfile.id -ceq 'long' -and (Get-RpArgument $rpArgs '--ctx-size') -ceq '65536') 'vision re-plan: the serving profile is still forwarded (long, --ctx-size 65536)'
        # The block is re-derived from the rows at start, never copied: a changed row at start is a changed plan.
        $rpChanged=Get-Content -LiteralPath $visionProfiles -Raw | ConvertFrom-Json
        $rpChanged.addOns[0].extraFreeVramMiB.long=400
        Write-Utf8 $rpProfiles (ConvertTo-Json -InputObject $rpChanged -Depth 10)
        $rpSwapped=Invoke-RpStart $rpPlan
        Check ($rpSwapped.threw -and $rpSwapped.code -ceq 'vision-plan-changed' -and $rpSwapped.message -like '*changed while preparing startup. Nothing was started; plan again.' -and $null -eq $rpSwapped.captured) 'vision re-plan: a vision row whose extra memory changed between plan and start is refused vision-plan-changed; nothing reaches the supervisor'
        Check ($rpSwapped.reason -cne 'PlanChanged' -and $rpSwapped.reason -cne 'RuntimeCheckFailed' -and $rpSwapped.reason -cne 'ModelNeedsProvisioning') 'vision re-plan: vision-plan-changed carries no reason that the CLI would recover or re-plan on'
        # A row that is gone at start: the planner itself refuses the forwarded mode (never a plan without the projector).
        [IO.File]::Copy($shippedProfiles,$rpProfiles,$true)
        $rpLost=Invoke-RpStart $rpPlan
        Check ($rpLost.threw -and $null -eq $rpLost.captured) 'vision re-plan: a row that is gone at start is refused and nothing reaches the supervisor (never a start without the projector)'
        [IO.File]::Copy($visionProfiles,$rpProfiles,$true)
        # One case per compared field, each changing ONLY that field, so each comparison is pinned on its own.
        $rpEvidence=Get-Content -LiteralPath $visionProfiles -Raw | ConvertFrom-Json
        $rpEvidence.addOns[0].evidence.resultId=([string]$rpEvidence.addOns[0].evidence.resultId)+'-new'
        Write-Utf8 $rpProfiles (ConvertTo-Json -InputObject $rpEvidence -Depth 10)
        $rpNewEvidence=Invoke-RpStart $rpPlan
        Check ($rpNewEvidence.threw -and $rpNewEvidence.code -ceq 'vision-plan-changed' -and $null -eq $rpNewEvidence.captured) 'vision re-plan: the same vision row with new evidence (only resultId differs) is refused vision-plan-changed'
        [IO.File]::Copy($visionProfiles,$rpProfiles,$true)
        $rpComponent=Get-Content -LiteralPath $visionProfiles -Raw | ConvertFrom-Json
        $rpComponent.addOns[0].componentId=([string]$rpComponent.addOns[0].componentId)+'-other'
        Write-Utf8 $rpProfiles (ConvertTo-Json -InputObject $rpComponent -Depth 10)
        $rpOtherComponent=Invoke-RpStart $rpPlan
        Check ($rpOtherComponent.threw -and $rpOtherComponent.code -ceq 'vision-plan-changed' -and $null -eq $rpOtherComponent.captured) 'vision re-plan: the same vision row naming another projector component (only componentId differs) is refused vision-plan-changed'
        [IO.File]::Copy($visionProfiles,$rpProfiles,$true)
        # The profile id comes from the forwarded context profile, not the row, so only the incoming plan's block can differ in it.
        $rpOtherProfile=$rpPlan | ConvertTo-Json -Depth 12 | ConvertFrom-Json
        $rpOtherProfile.vision.profileId='default'
        $rpProfileRun=Invoke-RpStart $rpOtherProfile
        Check ($rpProfileRun.threw -and $rpProfileRun.code -ceq 'vision-plan-changed' -and $null -eq $rpProfileRun.captured) 'vision re-plan: a vision block whose profile id differs from the re-derived one (only profileId differs) is refused vision-plan-changed'
        # A plan without vision makes the call it always made: no vision block, --no-mmproj kept.
        $rpDefault=Get-FastLlmPlan @rpCommon
        $rpDefaultRun=Invoke-RpStart $rpDefault
        Check (-not $rpDefaultRun.threw -and $null -ne $rpDefaultRun.captured -and -not $rpDefaultRun.captured.PSObject.Properties['vision'] -and (@($rpDefaultRun.captured.serverArguments) -ccontains '--no-mmproj') -and -not (@($rpDefaultRun.captured.serverArguments) -ccontains '--mmproj')) 'vision re-plan: a plan without vision re-plans without it (no block, --no-mmproj kept)'
        # The switch basis: the serving options of a plan that carries vision keep the mode, so a switch asks the planner the same question.
        $rpOptions=& $module { param($P) Get-FastLlmSwitchServingOptions -PreviousPlan $P } $rpPlan
        Check ($rpOptions.ContainsKey('Vision') -and [string]$rpOptions.Vision -ceq 'on' -and [string]$rpOptions.KvContextProfile -ceq 'long') 'vision switch basis: the serving options of a vision plan carry -Vision on with the context profile'
        $rpPlanOptions=& $module { param($P,$C,$I) Get-FastLlmSwitchPlanOptions -PreviousPlan $P -Request ([pscustomobject]@{recipeId=$null;modelId='qwen3.8-27b-ud-q4-k-m'}) -CatalogPath $C -InstallRoot $I } $rpPlan $rpCatalog $rpWorld
        Check ([string]$rpPlanOptions.Vision -ceq 'on' -and [string]$rpPlanOptions.KvProfilesPath -ceq $rpProfiles) 'vision switch basis: the switch target options carry -Vision on and read the rows next to the catalog'
        $rpDefaultOptions=& $module { param($P) Get-FastLlmSwitchServingOptions -PreviousPlan $P } $rpDefault
        Check (-not $rpDefaultOptions.ContainsKey('Vision')) 'vision switch basis: a plan without vision adds no Vision option'
        # The saved switch basis (state/switch-basis-<runId>.json) keeps the mode too: its closed key check accepts Vision off|on and nothing else.
        $rpChecked=& $module { param($O) ConvertTo-FastLlmSwitchBasisPlanOptions -Options $O } $rpOptions
        Check ($null -ne $rpChecked -and [string]$rpChecked['Vision'] -ceq 'on' -and [string]$rpChecked['KvContextProfile'] -ceq 'long') 'vision switch basis: the saved basis keeps -Vision on (the closed key check accepts it)'
        $rpBadVision=& $module { ConvertTo-FastLlmSwitchBasisPlanOptions -Options @{ Profile='balanced'; Vision='ON' } }
        Check ($null -eq $rpBadVision) 'vision switch basis: a saved basis with a Vision value other than off|on (exact case) is not used'
    }
    finally {
        & $module {
            param($Saved)
            Set-Item -Path Function:script:Assert-FastLlmVisionStartable -Value $Saved.vision
            Set-Item -Path Function:script:Assert-FastLlmWindowsPrerequisites -Value $Saved.prerequisites
            Set-Item -Path Function:script:Test-FastLlmEngineInstallation -Value $Saved.engineInstall
            Set-Item -Path Function:script:Get-FastLlmEngineExecutable -Value $Saved.engineExe
            Set-Item -Path Function:script:Test-FastLlmFileHash -Value $Saved.hash
            Set-Item -Path Function:script:Test-FastLlmModelConsentReceipt -Value $Saved.consent
            Set-Item -Path Function:script:Get-FastLlmHardware -Value $Saved.hardware
            Set-Item -Path Function:script:Invoke-FastLlmSupervisedServer -Value $Saved.supervised
        } $rpBoundaries
    }

    Write-Host "optin-arguments-tests: $script:count checks passed"
}
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
