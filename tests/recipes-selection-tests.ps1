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
# Card count (final review I3): a recipe applies only when gpu.count equals the identified eligible cards of its variant, on the placement using all of them.
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
$block = New-FastLlmPlanRecipeBlock -Pick $null -ModelId '' -Skipped @('x')
Check ($block.origin -eq 'estimated' -and $block.label -eq 'Estimated for your card') 'no pick is labelled estimated'
$block = New-FastLlmPlanRecipeBlock -Pick $null -ModelId 'small' -Skipped @()
Check ($block.origin -eq 'manual' -and $block.label -eq 'Chosen by you') 'an explicit model is labelled as the user choice'
Check ((Get-FastLlmRecipeLabel 'bitworks') -eq 'Measured by Bitworks on this card') 'the Bitworks label text is exact'
Write-Host 'recipes-selection-tests: PASS'
