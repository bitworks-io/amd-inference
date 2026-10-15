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

function Get-FastLlmBuiltInEngineId {
    param([Parameter(Mandatory = $true)] $Catalog)
    return 'llama.cpp-' + [string] $Catalog.engine.version + '-vulkan'
}

function Get-FastLlmRecipeEngineId {
    param([Parameter(Mandatory = $true)] $Recipe, [Parameter(Mandatory = $true)] $Catalog)
    if ($Recipe.PSObject.Properties['components'] -and $Recipe.components -and $Recipe.components.PSObject.Properties['engine'] -and $Recipe.components.engine) {
        return [string] $Recipe.components.engine
    }
    return (Get-FastLlmBuiltInEngineId -Catalog $Catalog)
}

# The listed engine component with this exact id: kind engine, Vulkan or HIP backend, llama.cpp adapter. $null when there is none.
function Find-FastLlmEngineComponent {
    param([object[]] $Components, [Parameter(Mandatory = $true)][string] $EngineId)
    foreach ($candidate in @($Components | Where-Object { $_ })) {
        if ([string] $candidate.id -cne $EngineId) { continue }
        if ([string] $candidate.kind -cne 'engine') { continue }
        if (-not $candidate.PSObject.Properties['adapter'] -or [string] $candidate.adapter -cne 'llama.cpp') { continue }
        if (-not $candidate.PSObject.Properties['platform'] -or -not $candidate.platform -or -not $candidate.platform.PSObject.Properties['backend'] -or [string] $candidate.platform.backend -cnotin @('vulkan', 'hip')) { continue }
        return $candidate
    }
    return $null
}

# The engine version a recipe runs on: the catalog version for the built-in id, the component version otherwise; $null for an unknown id.
function Get-FastLlmRecipeEngineVersion {
    param([Parameter(Mandatory = $true)] $Recipe, [Parameter(Mandatory = $true)] $Catalog, [object[]] $Components)
    $engineId = Get-FastLlmRecipeEngineId -Recipe $Recipe -Catalog $Catalog
    if ($engineId -ceq (Get-FastLlmBuiltInEngineId -Catalog $Catalog)) { return [string] $Catalog.engine.version }
    $found = Find-FastLlmEngineComponent -Components $Components -EngineId $engineId
    if ($null -eq $found) { return $null }
    return [string] $found.version
}

function New-FastLlmEngineFailure {
    param([Parameter(Mandatory = $true)][string] $Code, [Parameter(Mandatory = $true)][string] $Message, [string] $ComponentId)
    $failure = New-Object -TypeName System.InvalidOperationException -ArgumentList ($Code + ': ' + $Message)
    $failure.Data['FastLlmFailureCode'] = $Code
    if ($ComponentId) { $failure.Data['FastLlmComponentId'] = $ComponentId }
    return $failure
}

# Resolves the engine a recipe names. The built-in id (llama.cpp-<catalog version>-vulkan) is checked first and maps to the existing
# engines\<version>\vulkan path; it never consults components.json. Any other id must be a listed engine component. An unknown id is a typed error.
function Resolve-FastLlmRecipeEngine {
    param([Parameter(Mandatory = $true)] $Recipe, [Parameter(Mandatory = $true)] $Catalog, [object[]] $Components, [Parameter(Mandatory = $true)][string] $InstallRoot)
    $engineId = Get-FastLlmRecipeEngineId -Recipe $Recipe -Catalog $Catalog
    if ($engineId -ceq (Get-FastLlmBuiltInEngineId -Catalog $Catalog)) {
        $builtInEntryPoint = 'llama-server.exe'
        if ($Catalog.engine.PSObject.Properties['assets'] -and $Catalog.engine.assets -and $Catalog.engine.assets.PSObject.Properties['vulkan'] -and
            $Catalog.engine.assets.vulkan.PSObject.Properties['entryPoint'] -and $Catalog.engine.assets.vulkan.entryPoint) {
            $builtInEntryPoint = [string] $Catalog.engine.assets.vulkan.entryPoint
        }
        $builtInExecutable = Get-FastLlmEngineExecutable -InstallRoot $InstallRoot -EngineVersion ([string] $Catalog.engine.version) -BackendKey 'vulkan' -EntryPoint $builtInEntryPoint
        return [pscustomobject] [ordered] @{ id = $engineId; version = [string] $Catalog.engine.version; backend = 'vulkan'
            executable = $builtInExecutable; installed = [bool] $builtInExecutable; builtIn = $true; runtimeRoots = @() }
    }
    $component = Find-FastLlmEngineComponent -Components $Components -EngineId $engineId
    if ($null -eq $component) {
        throw (New-FastLlmEngineFailure -Code 'recipe-engine-component-unknown' -Message "The recipe names the engine '${engineId}', which is not a built-in engine or a listed Vulkan or HIP llama.cpp engine component." -ComponentId $engineId)
    }
    $componentEntryPoint = 'llama-server.exe'
    if ($component.PSObject.Properties['entryPoint'] -and $component.entryPoint) { $componentEntryPoint = [string] $component.entryPoint }
    $componentRoot = Get-FastLlmComponentRoot -InstallRoot $InstallRoot -Component $component
    Assert-FastLlmLeafName -Value $componentEntryPoint -Label 'Engine component entry point'
    $componentExecutable = Join-FastLlmContainedPath -Root $componentRoot -Child $componentEntryPoint -Label 'Engine component executable path'
    $componentInstalled = [bool] ((Test-FastLlmComponentInstallation -InstallRoot $InstallRoot -Component $component -Depth Presence) -and (Test-Path -LiteralPath $componentExecutable -PathType Leaf))
    # Every required component (requires-first chain, the engine itself last) must also be present; its runtime directories become the DLL search roots.
    $runtimeRoots = New-Object 'System.Collections.Generic.List[string]'
    foreach ($chained in @(Get-FastLlmComponentChain -Components $Components -Id $engineId)) {
        if ([string] $chained.id -ceq [string] $component.id) { continue }
        if (-not (Test-FastLlmComponentInstallation -InstallRoot $InstallRoot -Component $chained -Depth Presence)) { $componentInstalled = $false }
        if ([string] $chained.kind -ceq 'runtime' -and $chained.PSObject.Properties['runtimePathDirs'] -and $chained.runtimePathDirs) {
            $requiredRoot = Get-FastLlmComponentRoot -InstallRoot $InstallRoot -Component $chained
            foreach ($pathDirectory in @($chained.runtimePathDirs)) {
                # The strict leaf rule first: a .NET Framework path API throws on a control character before any rule of ours runs.
                Assert-FastLlmComponentLeafName -Value ([string] $pathDirectory) -Label 'Runtime path directory'
                $runtimeRoots.Add((Join-FastLlmContainedPath -Root $requiredRoot -Child ([string] $pathDirectory) -Label 'Runtime path directory'))
            }
        }
    }
    return [pscustomobject] [ordered] @{ id = $engineId; version = [string] $component.version; backend = [string] $component.platform.backend
        executable = $componentExecutable; installed = $componentInstalled; builtIn = $false; runtimeRoots = $runtimeRoots.ToArray() }
}

# The first component of an engine's chain (requires first, the engine last) that fails the installation check at the given depth, or $null when
# all pass. Used to name the right component in a needs-setup-component-missing failure.
function Get-FastLlmFirstUnavailableComponent {
    param([object[]] $Components, [Parameter(Mandatory = $true)][string] $EngineId, [Parameter(Mandatory = $true)][string] $InstallRoot,
          [ValidateSet('Presence', 'Full')][string] $Depth = 'Full')
    foreach ($chained in @(Get-FastLlmComponentChain -Components $Components -Id $EngineId)) {
        if (-not (Test-FastLlmComponentInstallation -InstallRoot $InstallRoot -Component $chained -Depth $Depth)) { return [string] $chained.id }
    }
    return $null
}

# Maps each selected (discrete AMD) adapter onto the HIP engine's own device name by EXACT name and total VRAM within +-5%. The result is a copy:
# the hardware object is never changed. Zero matches is hip-device-not-found, two or more (two identical cards) is hip-device-ambiguous; nothing is guessed.
function Resolve-FastLlmHipSelectedAdapters {
    param([object[]] $Adapters, [object[]] $Devices, [Parameter(Mandatory = $true)][string] $ComponentId)
    $hipDevices = @($Devices | Where-Object { $_ -and [string] $_.device -cmatch '^ROCm[0-9]{1,2}$' })
    $listed = (@($hipDevices | ForEach-Object { "$($_.device): $($_.name) ($($_.vramMiB) MiB)" }) -join '; ')
    if (-not $listed) { $listed = 'no device' }
    $resolved = New-Object 'System.Collections.Generic.List[object]'
    $claimed = New-Object 'System.Collections.Generic.List[string]'
    foreach ($adapter in @($Adapters)) {
        $adapterName = ([string] $adapter.name).Trim()
        $adapterVram = [int64] $adapter.vramMiB
        $candidates = @($hipDevices | Where-Object {
                ([string] $_.name).Trim().Equals($adapterName, [System.StringComparison]::OrdinalIgnoreCase) -and
                [Math]::Abs([int64] $_.vramMiB - $adapterVram) -le ([double] $adapterVram * 0.05)
            })
        if ($candidates.Count -eq 0) {
            throw (New-FastLlmEngineFailure -Code 'hip-device-not-found' -ComponentId $ComponentId -Message "The HIP engine '${ComponentId}' reports no device that matches the selected card '$adapterName' ($adapterVram MiB). It reports: $listed. Nothing was guessed.")
        }
        if ($candidates.Count -gt 1 -or $claimed.Contains([string] $candidates[0].device)) {
            throw (New-FastLlmEngineFailure -Code 'hip-device-ambiguous' -ComponentId $ComponentId -Message "The selected card '$adapterName' ($adapterVram MiB) matches more than one HIP device ($listed), for example two identical cards. FastLLM cannot tell which one is the selected card, so nothing was guessed.")
        }
        $claimed.Add([string] $candidates[0].device)
        $copy = $adapter.PSObject.Copy()
        $copy | Add-Member -NotePropertyName device -NotePropertyValue ([string] $candidates[0].device) -Force
        $resolved.Add($copy)
    }
    return $resolved.ToArray()
}

function Select-FastLlmRecipeForPlacements {
    param([object[]] $Recipes, [object[]] $Variants, [object[]] $Placements, [object[]] $DxgiAdapters,
          [Parameter(Mandatory = $true)] $Catalog, [Parameter(Mandatory = $true)][string] $Profile,
          [string] $RecipeId, [switch] $IncludeExperimental,
          [object[]] $EligibleAdapters,
          [object[]] $Components,
          [System.Collections.Generic.List[string]] $SkippedSink)
    $usable = @($Recipes | Where-Object { $_ -and ($_.origin -ne 'community-experimental' -or $IncludeExperimental -or ($RecipeId -and $_.id -eq $RecipeId)) })
    if ($RecipeId) {
        $usable = @($usable | Where-Object { $_.id -eq $RecipeId })
        if ($usable.Count -eq 0) { throw "Recipe '$RecipeId' is not in this release's recipe list. No other recipe was substituted." }
    }
    $models = @{}
    foreach ($model in @($Catalog.models)) { $models[[string] $model.id] = $model }
    $options = New-Object System.Collections.Generic.List[object]
    # Reasons go straight into the caller's sink when there is one, so a plan keeps them even if a later step throws or no recipe is picked.
    $skipped = $SkippedSink
    if ($null -eq $skipped) { $skipped = New-Object System.Collections.Generic.List[string] }
    # Fail closed until runtime and draft components can run: a recipe naming one would otherwise be planned without it. Skipped with a reason,
    # or a typed failure when it was named with -Recipe.
    $runnable = New-Object System.Collections.Generic.List[object]
    foreach ($candidate in $usable) {
        $unsupportedRole = $null
        if ($candidate.PSObject.Properties['components'] -and $candidate.components) {
            foreach ($role in @('runtime', 'draft')) {
                $roleProperty = $candidate.components.PSObject.Properties[$role]
                if ($roleProperty -and -not [string]::IsNullOrWhiteSpace([string] $roleProperty.Value)) { $unsupportedRole = $role; break }
            }
        }
        if ($null -eq $unsupportedRole) { $runnable.Add($candidate); continue }
        if ($RecipeId) {
            throw (New-FastLlmEngineFailure -Code 'recipe-component-role-unsupported' -Message "Recipe '$($candidate.id)' names a $unsupportedRole component, which this release cannot run. No other recipe was substituted.")
        }
        $roleReason = "$($candidate.id): needs a runtime or draft component this release cannot run"
        if (-not $skipped.Contains($roleReason)) { $skipped.Add($roleReason) }
    }
    $usable = $runnable.ToArray()
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
            # The build is compared with the engine the recipe actually resolves to: the catalog's for the built-in id, the component's otherwise.
            $recipeEngineVersion = Get-FastLlmRecipeEngineVersion -Recipe $recipe -Catalog $Catalog -Components $Components
            if ($null -eq $recipeEngineVersion -or [string] $recipe.engineBuild -ne $recipeEngineVersion) { $skipped.Add("$($recipe.id): engine build differs"); continue }
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
    $sorted = @($options | Sort-Object -Property rank, @{ Expression = { $_.recommended }; Descending = $true },
        @{ Expression = { $_.score }; Descending = $true }, @{ Expression = { $_.generation }; Descending = $true }, id)
    if ($RecipeId -and $sorted.Count -eq 0) { throw "Recipe '$RecipeId' does not apply to this PC: $(@($skipped) -join '; '). No other recipe was substituted." }
    if ($sorted.Count -eq 0) { return $null }
    $pick = $sorted[0]
    if ($pick.recipe.origin -eq 'community-experimental' -and -not $RecipeId) { return $null }
    return [pscustomobject]@{ recipe = $pick.recipe; model = $pick.model; placement = $pick.placement; variant = $pick.variant; skipped = @($skipped) }
}

function New-FastLlmPlanRecipeBlock {
    param($Pick, [string] $ModelId, [string[]] $Skipped, [switch] $Recovered)
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
    if ($ModelId -and -not $Recovered) { $origin = 'manual' }   # a model picked by recovery is not the user's choice
    return [pscustomobject] [ordered] @{ id = $null; origin = $origin; label = (Get-FastLlmRecipeLabel $origin); variant = $null
        evidenceUrl = $null; expected = $null; vulkanBarMitigation = $null; skipped = @($Skipped) }
}
