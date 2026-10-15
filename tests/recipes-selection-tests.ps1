#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src/FastLlm.CardIdentity.ps1')
. (Join-Path $root 'src/FastLlm.Recipes.ps1')
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; Write-Host "PASS: $Message" }
$variants = Get-FastLlmGpuVariants -Path (Join-Path $root 'config/gpu-variants.json')
$catalog = [pscustomobject]@{ engine = [pscustomobject]@{ version = 'b10698' }; models = @(
        [pscustomobject]@{ id = 'big'; requiredFreeVramMiB = 20500; scores = [pscustomobject]@{ balanced = 112 } },
        [pscustomobject]@{ id = 'small'; requiredFreeVramMiB = 7300; scores = [pscustomobject]@{ balanced = 70 } }) }
function Recipe($id, $origin, $model, $gen, [bool]$recommended = $false, [bool]$compelling = $false, $variant = 'rx-7900-xtx', $count = 1, $engine = 'b10698') {
    [pscustomobject]@{ id = $id; origin = $origin; gpu = [pscustomobject]@{ variant = $variant; count = $count }
        components = [pscustomobject]@{ engine = "llama.cpp-$engine-vulkan"; model = $model }; engineBuild = $engine; recommended = $recommended
        runtime = [pscustomobject]@{ contextSize = 32768; vulkanBarMitigation = 'auto' }
        expected = [pscustomobject]@{ generationTokS = $gen }; evidence = [pscustomobject]@{ url = 'https://bitworks.io/r' }
        compelling = $(if ($origin -like 'community-*') { [pscustomobject]@{ isCompelling = $compelling } } else { $null }) }
}
$xtxDxgi = @([pscustomobject]@{ vendorId = 4098; deviceId = 29772; revision = 200; dedicatedVideoMiB = 24534 })
function Placement($free, $count = 1, $vram = 24560) { [pscustomobject]@{ adapters = @(1..$count | ForEach-Object { [pscustomobject]@{ name = 'n'; vramMiB = $vram } }); selectionCapacity = $free } }
$xtDxgi = @([pscustomobject]@{ vendorId = 4098; deviceId = 29772; revision = 204; dedicatedVideoMiB = 20464 })

$pick = Select-FastLlmRecipeForPlacements -Recipes @((Recipe 'b1' 'bitworks' 'big' 32.7 $true)) -Variants $variants -Placements @((Placement 23000)) -DxgiAdapters $xtxDxgi -Catalog $catalog -Profile 'balanced'
Check ($pick -and $pick.recipe.id -eq 'b1' -and $pick.variant -eq 'rx-7900-xtx') 'a fitting Bitworks recipe is picked for the matched card'
$pick = Select-FastLlmRecipeForPlacements -Recipes @((Recipe 'b1' 'bitworks' 'big' 32.7 $true)) -Variants $variants -Placements @((Placement 18000)) -DxgiAdapters $xtxDxgi -Catalog $catalog -Profile 'balanced'
Check ($null -eq $pick) 'a recipe that does not fit free VRAM is skipped (estimated fallback)'
$pick = Select-FastLlmRecipeForPlacements -Recipes @((Recipe 'b1' 'bitworks' 'big' 32.7 $true)) -Variants $variants -Placements @((Placement 23000)) -DxgiAdapters @() -Catalog $catalog -Profile 'balanced'
Check ($null -eq $pick) 'no card identity means no recipe'
$pick = Select-FastLlmRecipeForPlacements -Recipes @((Recipe 'b1' 'bitworks' 'missing' 32.7 $true)) -Variants $variants -Placements @((Placement 23000)) -DxgiAdapters $xtxDxgi -Catalog $catalog -Profile 'balanced'
Check ($null -eq $pick) 'a recipe whose model left the catalog is skipped'
$pick = Select-FastLlmRecipeForPlacements -Recipes @((Recipe 'b1' 'bitworks' 'big' 32.7 $true $false 'rx-7900-xtx' 1 'b9999')) -Variants $variants -Placements @((Placement 23000)) -DxgiAdapters $xtxDxgi -Catalog $catalog -Profile 'balanced'
Check ($null -eq $pick) 'a recipe for another engine build is skipped'
$both = @((Recipe 'b1' 'bitworks' 'big' 32.7 $true), (Recipe 'c1' 'community-reproduced' 'big' 40 $false $true))
$pick = Select-FastLlmRecipeForPlacements -Recipes $both -Variants $variants -Placements @((Placement 23000)) -DxgiAdapters $xtxDxgi -Catalog $catalog -Profile 'balanced'
Check ($pick.recipe.id -eq 'c1') 'a compelling reproduced community recipe outranks the Bitworks recipe'
$both = @((Recipe 'b1' 'bitworks' 'big' 32.7 $true), (Recipe 'c1' 'community-reproduced' 'big' 34 $false $false))
$pick = Select-FastLlmRecipeForPlacements -Recipes $both -Variants $variants -Placements @((Placement 23000)) -DxgiAdapters $xtxDxgi -Catalog $catalog -Profile 'balanced'
Check ($pick.recipe.id -eq 'b1') 'a non-compelling community recipe does not outrank the recommended Bitworks recipe'
$exp = @((Recipe 'e1' 'community-experimental' 'big' 60 $false $true))
$pick = Select-FastLlmRecipeForPlacements -Recipes $exp -Variants $variants -Placements @((Placement 23000)) -DxgiAdapters $xtxDxgi -Catalog $catalog -Profile 'balanced' -IncludeExperimental
Check ($null -eq $pick) 'an experimental recipe is never auto-selected'
$pick = Select-FastLlmRecipeForPlacements -Recipes $exp -Variants $variants -Placements @((Placement 23000)) -DxgiAdapters $xtxDxgi -Catalog $catalog -Profile 'balanced' -RecipeId 'e1'
Check ($pick.recipe.id -eq 'e1') 'an experimental recipe can be chosen explicitly'
$threw = $null
try { Select-FastLlmRecipeForPlacements -Recipes @((Recipe 'b1' 'bitworks' 'big' 32.7 $true)) -Variants $variants -Placements @((Placement 18000)) -DxgiAdapters $xtxDxgi -Catalog $catalog -Profile 'balanced' -RecipeId 'b1' | Out-Null } catch { $threw = $_.Exception.Message }
Check ($threw -like "*does not apply to this PC*No other recipe was substituted*") '-Recipe that does not fit refuses without substituting'
$threw = $null
try { Select-FastLlmRecipeForPlacements -Recipes @() -Variants $variants -Placements @((Placement 23000)) -DxgiAdapters $xtxDxgi -Catalog $catalog -Profile 'balanced' -RecipeId 'nope' | Out-Null } catch { $threw = $_.Exception.Message }
Check ($threw -like "*not in this release*") '-Recipe for an unknown id refuses'
$pick = Select-FastLlmRecipeForPlacements -Recipes @((Recipe 'd1' 'bitworks' 'big' 31 $true $false 'rx-7900-xtx' 2)) -Variants $variants -Placements @((Placement 23000), (Placement 23000), (Placement 46000 2)) -EligibleAdapters @((Placement 1).adapters[0], (Placement 1).adapters[0]) -DxgiAdapters @($xtxDxgi[0], $xtxDxgi[0]) -Catalog $catalog -Profile 'balanced'
Check ($pick.recipe.id -eq 'd1' -and @($pick.placement.adapters).Count -eq 2) 'a dual-card recipe applies only to the two-card placement'
# Card count: a recipe applies only when gpu.count equals the identified eligible cards of its variant, on the placement using all of them.
$twoXtxPlacements = @((Placement 23000), (Placement 23000), (Placement 46000 2))
$twoXtxCards = @((Placement 1).adapters[0], (Placement 1).adapters[0])
$sink = New-Object 'System.Collections.Generic.List[string]'
$pick = Select-FastLlmRecipeForPlacements -Recipes @((Recipe 'b1' 'bitworks' 'big' 32.7 $true)) -Variants $variants -Placements $twoXtxPlacements -EligibleAdapters $twoXtxCards -DxgiAdapters @($xtxDxgi[0], $xtxDxgi[0]) -Catalog $catalog -Profile 'balanced' -SkippedSink $sink
Check ($null -eq $pick) 'a one-card recipe does not apply on a PC with two identified cards of that variant'
Check (@($sink | Where-Object { $_ -like 'b1: measured on 1 card(s); this PC has 2 identified card(s) of this type, and this placement uses 1' }).Count -eq 1) 'the skipped list names the card-count mismatch once per placement size'
$pick = Select-FastLlmRecipeForPlacements -Recipes @((Recipe 'b1' 'bitworks' 'big' 32.7 $true), (Recipe 'd1' 'bitworks' 'big' 31 $true $false 'rx-7900-xtx' 2)) -Variants $variants -Placements $twoXtxPlacements -EligibleAdapters $twoXtxCards -DxgiAdapters @($xtxDxgi[0], $xtxDxgi[0]) -Catalog $catalog -Profile 'balanced'
Check ($pick.recipe.id -eq 'd1' -and @($pick.placement.adapters).Count -eq 2) 'on two identified cards only the two-card recipe on the pair can apply'
$mixedCards = @((Placement 1).adapters[0], (Placement 1 1 20480).adapters[0])
$mixedDxgi = @($xtxDxgi[0], $xtDxgi[0])
$pick = Select-FastLlmRecipeForPlacements -Recipes @((Recipe 'x1' 'bitworks' 'small' 25 $true $false 'rx-7900-xt' 1)) -Variants $variants -Placements @((Placement 23000), (Placement 19000 1 20480)) -EligibleAdapters $mixedCards -DxgiAdapters $mixedDxgi -Catalog $catalog -Profile 'balanced'
Check ($pick.recipe.id -eq 'x1' -and $pick.variant -eq 'rx-7900-xt') 'a one-card recipe still applies when the PC has one card of its variant next to another variant'
# Not auto-eligible models: never auto-picked by a recipe; reachable only by naming the recipe.
$catalogWithExperimental = [pscustomobject]@{ engine = $catalog.engine; models = @($catalog.models) + @([pscustomobject]@{ id = 'exp'; requiredFreeVramMiB = 7300; autoEligible = $false; scores = [pscustomobject]@{ balanced = 90 } }) }
$sink = New-Object 'System.Collections.Generic.List[string]'
$pick = Select-FastLlmRecipeForPlacements -Recipes @((Recipe 'e2' 'bitworks' 'exp' 30 $true)) -Variants $variants -Placements @((Placement 23000)) -DxgiAdapters $xtxDxgi -Catalog $catalogWithExperimental -Profile 'balanced' -SkippedSink $sink
Check ($null -eq $pick -and @($sink | Where-Object { $_ -like 'e2: model is experimental*' }).Count -eq 1) 'a recipe for a model that is not auto-eligible is not auto-picked'
$pick = Select-FastLlmRecipeForPlacements -Recipes @((Recipe 'e2' 'bitworks' 'exp' 30 $true), (Recipe 'b1' 'bitworks' 'big' 32.7 $false)) -Variants $variants -Placements @((Placement 23000)) -DxgiAdapters $xtxDxgi -Catalog $catalogWithExperimental -Profile 'balanced'
Check ($pick.recipe.id -eq 'b1') 'an auto-eligible recipe is still picked next to a not auto-eligible one'
$pick = Select-FastLlmRecipeForPlacements -Recipes @((Recipe 'e2' 'bitworks' 'exp' 30 $true)) -Variants $variants -Placements @((Placement 23000)) -DxgiAdapters $xtxDxgi -Catalog $catalogWithExperimental -Profile 'balanced' -RecipeId 'e2'
Check ($pick.recipe.id -eq 'e2') 'a not auto-eligible model is reachable by naming its recipe'
# The identified card is reported even when no recipe is picked (estimated and manual plans), and only when every eligible card agrees.
$oneXtx = @((Placement 1).adapters[0])
Check ((Get-FastLlmIdentifiedCardVariant -EligibleAdapters $oneXtx -DxgiAdapters $xtxDxgi -Variants $variants) -eq 'rx-7900-xtx') 'a matched card is identified without any recipe'
Check ($null -eq (Get-FastLlmIdentifiedCardVariant -EligibleAdapters $oneXtx -DxgiAdapters @() -Variants $variants)) 'a card with no identity is not identified'
Check ($null -eq (Get-FastLlmIdentifiedCardVariant -EligibleAdapters $mixedCards -DxgiAdapters $mixedDxgi -Variants $variants)) 'two different identified cards give no single identified card'
Check ((Get-FastLlmIdentifiedCardVariant -EligibleAdapters $twoXtxCards -DxgiAdapters @($xtxDxgi[0], $xtxDxgi[0]) -Variants $variants) -eq 'rx-7900-xtx') 'two identical identified cards are the same variant'
$block = New-FastLlmPlanRecipeBlock -Pick $null -ModelId '' -Skipped @('x') -IdentifiedVariant 'rx-7900-xtx'
Check ($block.origin -eq 'estimated' -and $block.variant -eq 'rx-7900-xtx') 'an estimated block carries the identified card variant'
$block = New-FastLlmPlanRecipeBlock -Pick $null -ModelId 'small' -Skipped @() -IdentifiedVariant 'rx-7900-xt'
Check ($block.origin -eq 'manual' -and $block.variant -eq 'rx-7900-xt') 'a manual block carries the identified card variant'
$block = New-FastLlmPlanRecipeBlock -Pick $null -ModelId '' -Skipped @('x')
Check ($null -eq $block.variant) 'a block without an identified card has no variant'
$block = New-FastLlmPlanRecipeBlock -Pick $null -ModelId '' -Skipped @('x')
Check ($block.origin -eq 'estimated' -and $block.label -eq 'Estimated for your card') 'no pick is labelled estimated'
$block = New-FastLlmPlanRecipeBlock -Pick $null -ModelId 'small' -Skipped @()
Check ($block.origin -eq 'manual' -and $block.label -eq 'Chosen by you') 'an explicit model is labelled as the user choice'
$block = New-FastLlmPlanRecipeBlock -Pick $null -ModelId 'small' -Skipped @() -Recovered
Check ($block.origin -eq 'estimated' -and $block.label -eq 'Estimated for your card') 'a model chosen by recovery is labelled estimated, never Chosen by you'
Check ((Get-FastLlmRecipeLabel 'bitworks') -eq 'Measured by Bitworks on this card') 'the Bitworks label text is exact'
# The SHIPPED config files, planned together: a shape mismatch between tools/build-recipes.py output and the selector fails here.
$shippedRecipes = Read-FastLlmRecipes -Path (Join-Path $root 'config/recipes.json')
$shippedCatalog = Get-Content -LiteralPath (Join-Path $root 'config/catalog.json') -Raw | ConvertFrom-Json
function ShippedFree($modelId) { [int64] (@($shippedCatalog.models | Where-Object { $_.id -eq $modelId })[0].requiredFreeVramMiB) + 500 }
$xtDxgi = @([pscustomobject]@{ vendorId = 4098; deviceId = 29772; revision = 204; dedicatedVideoMiB = 20422 })
$pick = Select-FastLlmRecipeForPlacements -Recipes $shippedRecipes -Variants $variants -Placements @([pscustomobject]@{ adapters = @([pscustomobject]@{ name = 'n'; vramMiB = 20470 }); selectionCapacity = (ShippedFree 'qwen3.8-27b-ud-iq4-xs') }) -DxgiAdapters $xtDxgi -Catalog $shippedCatalog -Profile 'balanced'
Check ($null -ne $pick -and $pick.recipe.id -eq 'rx-7900-xt.qwen3.8-27b-ud-iq4-xs.16k') 'the shipped recipes select the RX 7900 XT recipe for 1002/744C/CC'
$block = New-FastLlmPlanRecipeBlock -Pick $pick -ModelId '' -Skipped @()
Check ($block.origin -eq 'bitworks' -and $block.label -eq 'Measured by Bitworks on this card') 'the shipped RX 7900 XT recipe is labelled as measured by Bitworks'
Check ($block.evidenceUrl -eq 'https://bitworks.io/amd-inference/recipes/rx-7900-xt-20gb-windows-qwen3-8-27b-iq4xs/#lab-observation') 'the shipped RX 7900 XT recipe carries its lab-observation URL'
$pick = Select-FastLlmRecipeForPlacements -Recipes $shippedRecipes -Variants $variants -Placements @([pscustomobject]@{ adapters = @([pscustomobject]@{ name = 'n'; vramMiB = 24560 }); selectionCapacity = (ShippedFree 'qwen3.8-27b-ud-q4-k-m') }) -DxgiAdapters $xtxDxgi -Catalog $shippedCatalog -Profile 'balanced'
Check ($null -ne $pick -and $pick.recipe.id -eq 'rx-7900-xtx.qwen3.8-27b-ud-q4-k-m.32k') 'the shipped recipes select the RX 7900 XTX recipe for 1002/744C/C8'
$block = New-FastLlmPlanRecipeBlock -Pick $pick -ModelId '' -Skipped @()
Check ($block.origin -eq 'bitworks' -and $block.label -eq 'Measured by Bitworks on this card') 'the shipped RX 7900 XTX recipe is labelled as measured by Bitworks'
Check ($block.evidenceUrl -eq 'https://bitworks.io/amd-inference/recipes/rx-7900-xtx-24gb-windows-qwen3-8-27b-q4km/#lab-observation') 'the shipped RX 7900 XTX recipe carries its lab-observation URL'
$unknownRevision = @([pscustomobject]@{ vendorId = 4098; deviceId = 29772; revision = 192; dedicatedVideoMiB = 24534 })
$pick = Select-FastLlmRecipeForPlacements -Recipes $shippedRecipes -Variants $variants -Placements @([pscustomobject]@{ adapters = @([pscustomobject]@{ name = 'n'; vramMiB = 24560 }); selectionCapacity = 30000 }) -DxgiAdapters $unknownRevision -Catalog $shippedCatalog -Profile 'balanced'
Check ($null -eq $pick) 'an unknown revision (C0) of the same device selects no shipped recipe'
$block = New-FastLlmPlanRecipeBlock -Pick $pick -ModelId '' -Skipped @()
Check ($block.origin -eq 'estimated') 'an unknown revision leaves the plan estimated'
Write-Host 'recipes-selection-tests: PASS'

# Engine component: a recipe's engineBuild is compared with the engine the recipe RESOLVES to: the catalog build for the built-in id, the component version otherwise.
function EngineComponent($id, $version, $kind = 'engine', $backend = 'vulkan', $adapter = 'llama.cpp') {
    [pscustomobject]@{ id = $id; kind = $kind; version = $version; adapter = $adapter; platform = [pscustomobject]@{ os = 'windows'; arch = 'x64'; backend = $backend }; entryPoint = 'llama-server.exe' }
}
$componentRecipe = Recipe 'k1' 'bitworks' 'big' 32.7 $true $false 'rx-7900-xtx' 1 'b10800'
$listed = @((EngineComponent 'llama.cpp-b10800-vulkan' 'b10800'))
Check ((Get-FastLlmBuiltInEngineId -Catalog $catalog) -ceq 'llama.cpp-b10698-vulkan') 'the built-in engine id is llama.cpp-<catalog version>-vulkan'
Check ((Get-FastLlmRecipeEngineVersion -Recipe (Recipe 'b1' 'bitworks' 'big' 32.7) -Catalog $catalog -Components @()) -ceq 'b10698') 'the built-in id resolves to the catalog engine version without any component list'
Check ((Get-FastLlmRecipeEngineVersion -Recipe $componentRecipe -Catalog $catalog -Components $listed) -ceq 'b10800') 'a listed engine component resolves to its own version'
Check ($null -eq (Get-FastLlmRecipeEngineVersion -Recipe $componentRecipe -Catalog $catalog -Components @())) 'an engine id that is neither built-in nor listed has no version'
$pick = Select-FastLlmRecipeForPlacements -Recipes @($componentRecipe) -Variants $variants -Placements @((Placement 23000)) -DxgiAdapters $xtxDxgi -Catalog $catalog -Profile 'balanced' -Components $listed
Check ($pick -and $pick.recipe.id -eq 'k1') 'a recipe on a listed engine component of the same build is picked'
$sink = New-Object 'System.Collections.Generic.List[string]'
$pick = Select-FastLlmRecipeForPlacements -Recipes @($componentRecipe) -Variants $variants -Placements @((Placement 23000)) -DxgiAdapters $xtxDxgi -Catalog $catalog -Profile 'balanced' -SkippedSink $sink
Check ($null -eq $pick -and @($sink | Where-Object { $_ -like 'k1: engine build differs' }).Count -eq 1) 'a recipe whose engine component is not listed is skipped, not thrown'
$pick = Select-FastLlmRecipeForPlacements -Recipes @($componentRecipe) -Variants $variants -Placements @((Placement 23000)) -DxgiAdapters $xtxDxgi -Catalog $catalog -Profile 'balanced' -Components @((EngineComponent 'llama.cpp-b10800-vulkan' 'b10801'))
Check ($null -eq $pick) 'a recipe whose engineBuild differs from its component version is skipped'
foreach ($badComponent in @((EngineComponent 'llama.cpp-b10800-vulkan' 'b10800' 'runtime'), (EngineComponent 'llama.cpp-b10800-vulkan' 'b10800' 'engine' 'rocm'), (EngineComponent 'llama.cpp-b10800-vulkan' 'b10800' 'engine' 'vulkan' 'other'))) {
    $pick = Select-FastLlmRecipeForPlacements -Recipes @($componentRecipe) -Variants $variants -Placements @((Placement 23000)) -DxgiAdapters $xtxDxgi -Catalog $catalog -Profile 'balanced' -Components @($badComponent)
    Check ($null -eq $pick) "a component of kind $($badComponent.kind), backend $($badComponent.platform.backend), adapter $($badComponent.adapter) is not an engine for a llama.cpp Vulkan recipe"
}
$caughtFailure = $null
try { Resolve-FastLlmRecipeEngine -Recipe $componentRecipe -Catalog $catalog -Components @() -InstallRoot 'C:\unused' | Out-Null } catch { $caughtFailure = $_.Exception }
Check ($null -ne $caughtFailure -and $caughtFailure.Data['FastLlmFailureCode'] -ceq 'recipe-engine-component-unknown' -and $caughtFailure.Message -like "*llama.cpp-b10800-vulkan*") 'an unknown engine id is a typed error that names the id'

# ---- HIP engine components are engines; the selected card is matched to the HIP device by exact name and VRAM, never guessed ----
$hipComponent = EngineComponent 'llama.cpp-hip-b11658' 'b11658' 'engine' 'hip'
Check ($null -ne (Find-FastLlmEngineComponent -Components @($hipComponent) -EngineId 'llama.cpp-hip-b11658')) 'a listed hip engine component is an engine'
Check ($null -eq (Find-FastLlmEngineComponent -Components @((EngineComponent 'llama.cpp-hip-b11658' 'b11658' 'runtime' 'hip')) -EngineId 'llama.cpp-hip-b11658')) 'a hip runtime component is not an engine'
function HipDevice($device, $name, $total, $free = 1000) { [pscustomobject]@{ device = $device; name = $name; vramMiB = [int64]$total; freeVramMiB = [int64]$free; backend = 'ROCm' } }
function SelectedCard($name = 'AMD Radeon RX 7900 XTX', $vram = 24560, $device = 'Vulkan0') { [pscustomobject]@{ device = $device; name = $name; vramMiB = [int64]$vram; freeVramMiB = 23737; isAmd = $true } }
function HipFailure([scriptblock]$Block) { try { & $Block | Out-Null } catch { return $_.Exception }; return $null }
$one = @(Resolve-FastLlmHipSelectedAdapters -Adapters @((SelectedCard)) -Devices @((HipDevice 'ROCm0' 'AMD Radeon RX 7900 XTX' 24560 24411)) -ComponentId 'llama.cpp-hip-b11658')
Check ($one.Count -eq 1 -and $one[0].device -ceq 'ROCm0' -and $one[0].name -ceq 'AMD Radeon RX 7900 XTX' -and $one[0].freeVramMiB -eq 23737) 'one card: the selected adapter keeps its fields and gets the HIP device name'
$selectedOriginal = SelectedCard
$null = Resolve-FastLlmHipSelectedAdapters -Adapters @($selectedOriginal) -Devices @((HipDevice 'ROCm0' 'AMD Radeon RX 7900 XTX' 24560)) -ComponentId 'x'
Check ($selectedOriginal.device -ceq 'Vulkan0') 'the hardware adapter object is not modified (the result is a copy)'
$igpuFirst = @(Resolve-FastLlmHipSelectedAdapters -Adapters @((SelectedCard)) -Devices @((HipDevice 'ROCm0' 'AMD Radeon(TM) Graphics' 512 400), (HipDevice 'ROCm1' 'AMD Radeon RX 7900 XTX' 24560 24411)) -ComponentId 'x')
Check ($igpuFirst[0].device -ceq 'ROCm1') 'an iGPU listed first and the dGPU second: the dGPU is matched by name and VRAM, not by index'
$igpuLast = @(Resolve-FastLlmHipSelectedAdapters -Adapters @((SelectedCard)) -Devices @((HipDevice 'ROCm0' 'AMD Radeon RX 7900 XTX' 24560), (HipDevice 'ROCm1' 'AMD Radeon(TM) Graphics' 24576 400)) -ComponentId 'x')
Check ($igpuLast[0].device -ceq 'ROCm0') 'an iGPU with a similar VRAM total but another name is never matched'
$twin = HipFailure { Resolve-FastLlmHipSelectedAdapters -Adapters @((SelectedCard)) -Devices @((HipDevice 'ROCm0' 'AMD Radeon RX 7900 XTX' 24560), (HipDevice 'ROCm1' 'AMD Radeon RX 7900 XTX' 24560)) -ComponentId 'llama.cpp-hip-b11658' }
Check ($null -ne $twin -and $twin.Data['FastLlmFailureCode'] -ceq 'hip-device-ambiguous' -and $twin.Data['FastLlmComponentId'] -ceq 'llama.cpp-hip-b11658') 'two identical cards: hip-device-ambiguous, nothing is guessed'
$twinPair = HipFailure { Resolve-FastLlmHipSelectedAdapters -Adapters @((SelectedCard 'AMD Radeon RX 7900 XTX' 24560 'Vulkan0'), (SelectedCard 'AMD Radeon RX 7900 XTX' 24560 'Vulkan1')) -Devices @((HipDevice 'ROCm0' 'AMD Radeon RX 7900 XTX' 24560), (HipDevice 'ROCm1' 'AMD Radeon RX 7900 XTX' 24560)) -ComponentId 'x' }
Check ($null -ne $twinPair -and $twinPair.Data['FastLlmFailureCode'] -ceq 'hip-device-ambiguous') 'a selected pair of identical cards is ambiguous too (HIP names cannot be assigned to them)'
$none = HipFailure { Resolve-FastLlmHipSelectedAdapters -Adapters @((SelectedCard)) -Devices @() -ComponentId 'x' }
Check ($null -ne $none -and $none.Data['FastLlmFailureCode'] -ceq 'hip-device-not-found') 'an empty HIP device list: hip-device-not-found'
$otherName = HipFailure { Resolve-FastLlmHipSelectedAdapters -Adapters @((SelectedCard)) -Devices @((HipDevice 'ROCm0' 'AMD Radeon RX 7900 XT' 24560)) -ComponentId 'x' }
Check ($null -ne $otherName -and $otherName.Data['FastLlmFailureCode'] -ceq 'hip-device-not-found') 'a different card name with the same VRAM is not a match'
$edgeIn = @(Resolve-FastLlmHipSelectedAdapters -Adapters @((SelectedCard 'AMD Radeon RX 7900 XTX' 24000)) -Devices @((HipDevice 'ROCm0' 'AMD Radeon RX 7900 XTX' 25200)) -ComponentId 'x')
Check ($edgeIn[0].device -ceq 'ROCm0') 'a total exactly 5% above the selected card still matches'
$edgeOut = HipFailure { Resolve-FastLlmHipSelectedAdapters -Adapters @((SelectedCard 'AMD Radeon RX 7900 XTX' 24000)) -Devices @((HipDevice 'ROCm0' 'AMD Radeon RX 7900 XTX' 25201)) -ComponentId 'x' }
Check ($null -ne $edgeOut -and $edgeOut.Data['FastLlmFailureCode'] -ceq 'hip-device-not-found') 'a total just over 5% away does not match'
$caseName = @(Resolve-FastLlmHipSelectedAdapters -Adapters @((SelectedCard 'amd radeon rx 7900 xtx')) -Devices @((HipDevice 'ROCm0' 'AMD Radeon RX 7900 XTX' 24560)) -ComponentId 'x')
Check ($caseName[0].device -ceq 'ROCm0') 'the name comparison ignores case but nothing else'
$wrongFamily = HipFailure { Resolve-FastLlmHipSelectedAdapters -Adapters @((SelectedCard)) -Devices @((HipDevice 'Vulkan0' 'AMD Radeon RX 7900 XTX' 24560)) -ComponentId 'x' }
Check ($null -ne $wrongFamily -and $wrongFamily.Data['FastLlmFailureCode'] -ceq 'hip-device-not-found') 'only ROCm<N> devices count as HIP devices'

$suffixed = HipFailure { Resolve-FastLlmHipSelectedAdapters -Adapters @((SelectedCard)) -Devices @((HipDevice 'ROCm0' 'AMD Radeon RX 7900 XTX (gfx1100)' 24560)) -ComponentId 'x' }
Check ($null -ne $suffixed -and $suffixed.Data['FastLlmFailureCode'] -ceq 'hip-device-not-found' -and $suffixed.Message -like '*AMD Radeon RX 7900 XTX (gfx1100)*' -and $suffixed.Message -like '*Vulkan setup*') 'a HIP device name that differs by a suffix fails closed, reports the name it saw and points at the Vulkan setup'
Check ($twin.Message -like '*Vulkan setup*') 'the ambiguous message also points at the Vulkan setup'

# ---- bitworks-experimental is gated and never auto-selected like community-experimental ----
Check ((Get-FastLlmRecipeLabel 'bitworks-experimental') -ceq 'Experimental Bitworks setup, not yet measured by Bitworks on this card') 'the bitworks-experimental label'
$bwExp = Recipe 'bx1' 'bitworks-experimental' 'big' 30 $false
$pick = Select-FastLlmRecipeForPlacements -Recipes @($bwExp) -Variants $variants -Placements @((Placement 23000)) -DxgiAdapters $xtxDxgi -Catalog $catalog -Profile 'balanced'
Check ($null -eq $pick) 'a bitworks-experimental recipe is not considered without the experimental inclusion'
$pick = Select-FastLlmRecipeForPlacements -Recipes @($bwExp) -Variants $variants -Placements @((Placement 23000)) -DxgiAdapters $xtxDxgi -Catalog $catalog -Profile 'balanced' -IncludeExperimental
Check ($null -eq $pick) 'a bitworks-experimental recipe is never auto-selected, even with the experimental inclusion'
$bwControl = Recipe 'bx1' 'bitworks' 'big' 30 $false
$pick = Select-FastLlmRecipeForPlacements -Recipes @($bwControl) -Variants $variants -Placements @((Placement 23000)) -DxgiAdapters $xtxDxgi -Catalog $catalog -Profile 'balanced'
Check ($pick -and $pick.recipe.id -eq 'bx1') 'control: the same recipe from Bitworks is picked under the same inputs'
$pick = Select-FastLlmRecipeForPlacements -Recipes @($bwExp) -Variants $variants -Placements @((Placement 23000)) -DxgiAdapters $xtxDxgi -Catalog $catalog -Profile 'balanced' -RecipeId 'bx1'
Check ($pick -and $pick.recipe.origin -eq 'bitworks-experimental') 'a bitworks-experimental recipe named with -Recipe is selected'
Write-Host 'recipes-selection-tests (bitworks-experimental): PASS'
