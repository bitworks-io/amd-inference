# Per-card recipes (config/recipes.json, bitworks.fastllm-recipes/v2). Matching uses card variants from
# FastLlm.CardIdentity.ps1, never names. community-experimental recipes are never auto-selected.
Set-StrictMode -Version 2

$script:FastLlmRecipeLabels = @{
    'bitworks'               = 'Measured by Bitworks on this card'
    'community-reproduced'   = 'Community recipe, reproduced by Bitworks'
    'community-experimental' = 'Experimental community recipe, not reproduced by Bitworks'
    'estimated'              = 'Estimated for your card'
    'manual'                 = 'Chosen by you'
}

function Get-FastLlmRecipeLabel {
    param([Parameter(Mandatory = $true)][string] $Origin)
    if (-not $script:FastLlmRecipeLabels.ContainsKey($Origin)) { throw "Unknown recipe origin '$Origin'." }
    return [string] $script:FastLlmRecipeLabels[$Origin]
}

function Read-FastLlmRecipes {
    param([Parameter(Mandatory = $true)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($document.schema -ne 'bitworks.fastllm-recipes/v2') { throw 'config/recipes.json has an unexpected schema.' }
    return @($document.recipes)
}

function Get-FastLlmRecipeRank {
    param($Recipe)
    if ($Recipe.origin -eq 'community-reproduced' -and $Recipe.PSObject.Properties['compelling'] -and $Recipe.compelling -and
        $Recipe.compelling.PSObject.Properties['isCompelling'] -and $Recipe.compelling.isCompelling) { return 0 }
    if ($Recipe.origin -eq 'community-experimental') { return 2 }
    return 1
}

function Select-FastLlmRecipeForPlacements {
    param([object[]] $Recipes, [object[]] $Variants, [object[]] $Placements, [object[]] $DxgiAdapters,
          [Parameter(Mandatory = $true)] $Catalog, [Parameter(Mandatory = $true)][string] $Profile,
          [string] $RecipeId, [switch] $IncludeExperimental,
          [object[]] $EligibleAdapters,
          [System.Collections.Generic.List[string]] $SkippedSink)
    $usable = @($Recipes | Where-Object { $_ -and ($_.origin -ne 'community-experimental' -or $IncludeExperimental -or ($RecipeId -and $_.id -eq $RecipeId)) })
    if ($RecipeId) {
        $usable = @($usable | Where-Object { $_.id -eq $RecipeId })
        if ($usable.Count -eq 0) { throw "Recipe '$RecipeId' is not in this release's recipe list. No other recipe was substituted." }
    }
    $models = @{}
    foreach ($model in @($Catalog.models)) { $models[[string] $model.id] = $model }
    $options = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[string]
    # A recipe is for a card count: it applies only when gpu.count equals the number of IDENTIFIED eligible cards of that variant in this PC,
    # on the placement that uses all of them. Without the explicit list, the eligible cards are the single-card placements (as the planner builds them).
    $eligible = @($EligibleAdapters | Where-Object { $_ })
    if ($eligible.Count -eq 0) { $eligible = @($Placements | Where-Object { @($_.adapters).Count -eq 1 } | ForEach-Object { @($_.adapters)[0] }) }
    $cardsPerVariant = @{}
    foreach ($card in $eligible) {
        $cardMatch = Resolve-FastLlmAdapterVariant -PlannerAdapter $card -DxgiAdapters $DxgiAdapters -Variants $Variants
        if ($cardMatch.status -eq 'matched') {
            $cardKey = [string] $cardMatch.variant
            if ($cardsPerVariant.ContainsKey($cardKey)) { $cardsPerVariant[$cardKey] = [int] $cardsPerVariant[$cardKey] + 1 } else { $cardsPerVariant[$cardKey] = 1 }
        }
    }
    foreach ($placement in @($Placements)) {
        $adapters = @($placement.adapters)
        $keys = @($adapters | ForEach-Object {
                $match = Resolve-FastLlmAdapterVariant -PlannerAdapter $_ -DxgiAdapters $DxgiAdapters -Variants $Variants
                if ($match.status -eq 'matched') { [string] $match.variant } else { '<' + [string] $match.status + '>' } } | Sort-Object -Unique)
        if ($keys.Count -ne 1 -or ([string] $keys[0]).StartsWith('<')) { $skipped.Add("card not identified ($($keys -join ','))"); continue }
        $variant = [string] $keys[0]
        $cardsOfVariant = 0
        if ($cardsPerVariant.ContainsKey($variant)) { $cardsOfVariant = [int] $cardsPerVariant[$variant] }
        foreach ($recipe in $usable) {
            if ([string] $recipe.gpu.variant -ne $variant) { continue }
            if ([int] $recipe.gpu.count -ne $adapters.Count -or $adapters.Count -ne $cardsOfVariant) {
                $countReason = "$($recipe.id): measured on $($recipe.gpu.count) card(s); this PC has $cardsOfVariant identified card(s) of this type, and this placement uses $($adapters.Count)"
                if (-not $skipped.Contains($countReason)) { $skipped.Add($countReason) }
                continue
            }
            $model = $models[[string] $recipe.components.model]
            if (-not $model) { $skipped.Add("$($recipe.id): model not in the catalog"); continue }
            if ([string] $recipe.engineBuild -ne [string] $Catalog.engine.version) { $skipped.Add("$($recipe.id): engine build differs"); continue }
            # The estimated planner never auto-picks a model flagged autoEligible false; a recipe may use one only when named with -Recipe.
            if (-not $RecipeId -and $model.PSObject.Properties['autoEligible'] -and -not [bool] $model.autoEligible) { $skipped.Add("$($recipe.id): model is experimental and not auto-eligible"); continue }
            if ([int64] $model.requiredFreeVramMiB -gt [int64] $placement.selectionCapacity) {
                $skipped.Add("$($recipe.id): needs $($model.requiredFreeVramMiB) MiB free, $($placement.selectionCapacity) MiB available"); continue
            }
            $score = -1
            if ($model.PSObject.Properties['scores'] -and $model.scores -and $model.scores.PSObject.Properties[$Profile]) { $score = [double] $model.scores.$Profile }
            $recommended = $false
            if ($recipe.PSObject.Properties['recommended']) { $recommended = [bool] $recipe.recommended }
            $generation = 0.0
            if ($recipe.PSObject.Properties['expected'] -and $recipe.expected -and $recipe.expected.PSObject.Properties['generationTokS'] -and $null -ne $recipe.expected.generationTokS) {
                $generation = [double] $recipe.expected.generationTokS
            }
            $options.Add([pscustomobject]@{ recipe = $recipe; model = $model; placement = $placement; variant = $variant
                    rank = (Get-FastLlmRecipeRank $recipe); recommended = $recommended; score = $score
                    generation = $generation; id = [string] $recipe.id })
        }
    }
    if ($SkippedSink) { foreach ($reason in $skipped) { $SkippedSink.Add($reason) } }
    $sorted = @($options | Sort-Object -Property rank, @{ Expression = { $_.recommended }; Descending = $true },
        @{ Expression = { $_.score }; Descending = $true }, @{ Expression = { $_.generation }; Descending = $true }, id)
    if ($RecipeId -and $sorted.Count -eq 0) { throw "Recipe '$RecipeId' does not apply to this PC: $(@($skipped) -join '; '). No other recipe was substituted." }
    if ($sorted.Count -eq 0) { return $null }
    $pick = $sorted[0]
    if ($pick.recipe.origin -eq 'community-experimental' -and -not $RecipeId) { return $null }
    return [pscustomobject]@{ recipe = $pick.recipe; model = $pick.model; placement = $pick.placement; variant = $pick.variant; skipped = @($skipped) }
}

function New-FastLlmPlanRecipeBlock {
    param($Pick, [string] $ModelId, [string[]] $Skipped)
    if ($Pick) {
        $recipe = $Pick.recipe
        $url = $null
        if ($recipe.PSObject.Properties['evidence'] -and $recipe.evidence -and $recipe.evidence.PSObject.Properties['url'] -and $recipe.evidence.url) { $url = [string] $recipe.evidence.url }
        $expected = $null
        if ($recipe.PSObject.Properties['expected']) { $expected = $recipe.expected }
        $mitigation = $null
        if ($recipe.PSObject.Properties['runtime'] -and $recipe.runtime -and $recipe.runtime.PSObject.Properties['vulkanBarMitigation']) { $mitigation = [string] $recipe.runtime.vulkanBarMitigation }
        return [pscustomobject] [ordered] @{ id = [string] $recipe.id; origin = [string] $recipe.origin; label = (Get-FastLlmRecipeLabel ([string] $recipe.origin))
            variant = $Pick.variant; evidenceUrl = $url; expected = $expected; vulkanBarMitigation = $mitigation; skipped = @($Pick.skipped) }
    }
    $origin = 'estimated'
    if ($ModelId) { $origin = 'manual' }
    return [pscustomobject] [ordered] @{ id = $null; origin = $origin; label = (Get-FastLlmRecipeLabel $origin); variant = $null
        evidenceUrl = $null; expected = $null; vulkanBarMitigation = $null; skipped = @($Skipped) }
}
