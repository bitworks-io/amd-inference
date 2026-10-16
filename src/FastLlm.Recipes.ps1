# Per-card recipes (config/recipes.json, bitworks.fastllm-recipes/v2). Matching uses card variants from
# FastLlm.CardIdentity.ps1, never names. community-experimental and bitworks-experimental recipes are never auto-selected.
# A recipe whose engine chain needs an AMD license accepted may be auto-selected only when its origin is 'bitworks' (measured by us); every other
# origin never is. A recipe whose engine chain cannot be resolved is never auto-selected, whatever its origin.
Set-StrictMode -Version 2

$script:FastLlmRecipeLabels = @{
    'bitworks'               = 'Measured by Bitworks on this card'
    'community-reproduced'   = 'Community recipe, reproduced by Bitworks'
    'community-experimental' = 'Experimental community recipe, not reproduced by Bitworks'
    'bitworks-experimental'  = 'Experimental Bitworks setup, not yet measured by Bitworks on this card'
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

# The origins that are gated behind the experimental switch and -AcceptExperimental, and never auto-selected. The one list: exported, so the
# entry-script component helpers use it too.
function Test-FastLlmExperimentalOrigin {
    param([string] $Origin)
    return [bool] (@('community-experimental', 'bitworks-experimental') -contains $Origin)
}

function Get-FastLlmRecipeRank {
    param($Recipe)
    if ($Recipe.origin -eq 'community-reproduced' -and $Recipe.PSObject.Properties['compelling'] -and $Recipe.compelling -and
        $Recipe.compelling.PSObject.Properties['isCompelling'] -and $Recipe.compelling.isCompelling) { return 0 }
    if (Test-FastLlmExperimentalOrigin -Origin ([string] $Recipe.origin)) { return 2 }
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
                $runtimeRoots.Add((Resolve-FastLlmRuntimePathDirectory -Root $requiredRoot -Directory ([string] $pathDirectory)))
            }
        }
    }
    return [pscustomobject] [ordered] @{ id = $engineId; version = [string] $component.version; backend = [string] $component.platform.backend
        executable = $componentExecutable; installed = $componentInstalled; builtIn = $false; runtimeRoots = $runtimeRoots.ToArray() }
}

# A runtimePathDirs entry is a nested tree path ('bin' or 'lib/bin'), validated by the same rule the components file is validated with, then joined one
# segment at a time. The strict rule runs first: a .NET Framework path API throws on a control character before any rule of ours would.
function Resolve-FastLlmRuntimePathDirectory {
    param([Parameter(Mandatory = $true)][string] $Root, [Parameter(Mandatory = $true)][string] $Directory)
    Assert-FastLlmComponentTreePath -Value $Directory -Label 'Runtime path directory'
    $resolved = $Root
    foreach ($segment in $Directory.Split('/')) {
        $resolved = Join-FastLlmContainedPath -Root $resolved -Child $segment -Label 'Runtime path directory'
    }
    return $resolved
}

# needs-setup-component-missing. FastLlmComponentId stays the engine (the chain root): the install action installs that one id and its whole requires
# chain. The member that actually failed is named in the message and in FastLlmUnavailableComponentId.
function New-FastLlmComponentUnavailableFailure {
    param([Parameter(Mandatory = $true)][string] $EngineId, [Parameter(Mandatory = $true)][string] $UnavailableId, [Parameter(Mandatory = $true)][string] $Message)
    $failure = New-FastLlmEngineFailure -Code 'needs-setup-component-missing' -ComponentId $EngineId -Message $Message
    $failure.Data['FastLlmUnavailableComponentId'] = $UnavailableId
    return $failure
}

# The first component of an engine's chain (requires first, the engine last) that fails the installation check at the given depth, or $null when
# all pass. Used to name the right component in a needs-setup-component-missing failure.
function Get-FastLlmFirstUnavailableComponent {
    param([object[]] $Components, [Parameter(Mandatory = $true)][string] $EngineId, [Parameter(Mandatory = $true)][string] $InstallRoot,
          [ValidateSet('Presence', 'Full')][string] $Depth = 'Full')
    foreach ($chained in @(Get-FastLlmComponentChain -Components $Components -Id $EngineId)) {
        if ($Depth -ceq 'Full') { $chainPasses = Test-FastLlmComponentVerifiedFull -InstallRoot $InstallRoot -Component $chained }
        else { $chainPasses = Test-FastLlmComponentInstallation -InstallRoot $InstallRoot -Component $chained -Depth $Depth }
        if (-not $chainPasses) { return [string] $chained.id }
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
            throw (New-FastLlmEngineFailure -Code 'hip-device-not-found' -ComponentId $ComponentId -Message "The HIP engine '${ComponentId}' reports no device that matches the selected card '$adapterName' ($adapterVram MiB). It reports: $listed. Nothing was guessed. Choose the Vulkan setup instead; FastLLM does not switch to it on its own.")
        }
        if ($candidates.Count -gt 1 -or $claimed.Contains([string] $candidates[0].device)) {
            throw (New-FastLlmEngineFailure -Code 'hip-device-ambiguous' -ComponentId $ComponentId -Message "The selected card '$adapterName' ($adapterVram MiB) matches more than one HIP device ($listed), for example two identical cards. FastLLM cannot tell which one is the selected card, so nothing was guessed. Choose the Vulkan setup instead; FastLLM does not switch to it on its own.")
        }
        $claimed.Add([string] $candidates[0].device)
        $copy = $adapter.PSObject.Copy()
        $copy | Add-Member -NotePropertyName device -NotePropertyValue ([string] $candidates[0].device) -Force
        $resolved.Add($copy)
    }
    return $resolved.ToArray()
}

# True when the recipe's engine chain (requires first, the engine last) holds a component whose license consent is 'accept' (an AMD license cannot be
# accepted silently). The built-in engine is not a component, so it never needs this. A chain that cannot be resolved fails closed: it needs acceptance.
function Test-FastLlmRecipeNeedsLicenseAcceptance {
    param([Parameter(Mandatory = $true)] $Recipe, [Parameter(Mandatory = $true)] $Catalog, [object[]] $Components)
    $engineId = Get-FastLlmRecipeEngineId -Recipe $Recipe -Catalog $Catalog
    if ($engineId -ceq (Get-FastLlmBuiltInEngineId -Catalog $Catalog)) { return $false }
    $engine = Find-FastLlmEngineComponent -Components $Components -EngineId $engineId
    if ($null -eq $engine) { return $false }   # not listed: the version check skips the recipe, and nothing can install
    $chain = @($engine)
    $requiresProperty = $engine.PSObject.Properties['requires']
    if ($null -ne $requiresProperty -and @($requiresProperty.Value | Where-Object { $_ }).Count -gt 0) {
        try { $chain = @(Get-FastLlmComponentChain -Components $Components -Id $engineId) }
        catch { return $true }
    }
    foreach ($member in $chain) {
        if ($member.PSObject.Properties['license'] -and $member.license -and $member.license.PSObject.Properties['consent'] -and [string] $member.license.consent -ceq 'accept') { return $true }
    }
    return $false
}

# True when the recipe's engine chain (requires first, the engine last) can be resolved from the component list. The built-in engine and an engine that
# is not listed (skipped later by the version check) have nothing to resolve.
function Test-FastLlmRecipeChainResolves {
    param([Parameter(Mandatory = $true)] $Recipe, [Parameter(Mandatory = $true)] $Catalog, [object[]] $Components)
    $engineId = Get-FastLlmRecipeEngineId -Recipe $Recipe -Catalog $Catalog
    if ($engineId -ceq (Get-FastLlmBuiltInEngineId -Catalog $Catalog)) { return $true }
    $engine = Find-FastLlmEngineComponent -Components $Components -EngineId $engineId
    if ($null -eq $engine) { return $true }
    $requiresProperty = $engine.PSObject.Properties['requires']
    if ($null -ne $requiresProperty -and @($requiresProperty.Value | Where-Object { $_ }).Count -gt 0) {
        try { $null = @(Get-FastLlmComponentChain -Components $Components -Id $engineId) }
        catch { return $false }
    }
    return $true
}

function Select-FastLlmRecipeForPlacements {
    param([object[]] $Recipes, [object[]] $Variants, [object[]] $Placements, [object[]] $DxgiAdapters,
          [Parameter(Mandatory = $true)] $Catalog, [Parameter(Mandatory = $true)][string] $Profile,
          [string] $RecipeId, [switch] $IncludeExperimental,
          [object[]] $EligibleAdapters,
          [object[]] $Components,
          [switch] $ExcludeLicenseRecipes,
          [System.Collections.Generic.List[string]] $SkippedSink)
    $usable = @($Recipes | Where-Object { $_ -and (-not (Test-FastLlmExperimentalOrigin -Origin ([string] $_.origin)) -or $IncludeExperimental -or ($RecipeId -and $_.id -eq $RecipeId)) })
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
            # A recipe whose engine chain needs an accepted license is auto-selected only when its origin is 'bitworks' (measured by us) and the caller
            # did not ask to exclude license recipes (the fallback pass does). A chain that cannot be resolved is never auto-selected, whatever its origin.
            # Every other origin is never auto-selected for a license chain; -Recipe is the way to it.
            if (-not $RecipeId -and (Test-FastLlmRecipeNeedsLicenseAcceptance -Recipe $recipe -Catalog $Catalog -Components $Components) -and
                ($ExcludeLicenseRecipes -or [string] $recipe.origin -cne 'bitworks' -or -not (Test-FastLlmRecipeChainResolves -Recipe $recipe -Catalog $Catalog -Components $Components))) {
                $licenseReason = "$($recipe.id): needs-license-acceptance (its engine components need an AMD license accepted; name the recipe with -Recipe)"
                if (-not $skipped.Contains($licenseReason)) { $skipped.Add($licenseReason) }
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
    if ((Test-FastLlmExperimentalOrigin -Origin ([string] $pick.recipe.origin)) -and -not $RecipeId) { return $null }
    return [pscustomobject]@{ recipe = $pick.recipe; model = $pick.model; placement = $pick.placement; variant = $pick.variant; skipped = @($skipped) }
}

# The card variant of this PC when every eligible card resolves to the same one, whatever the plan picked (an estimated or manual plan too);
# $null when a card is not identified or the cards differ. Nothing is guessed.
function Get-FastLlmIdentifiedCardVariant {
    param([object[]] $EligibleAdapters, [object[]] $DxgiAdapters, [object[]] $Variants)
    $cards = @($EligibleAdapters | Where-Object { $_ })
    if ($cards.Count -eq 0 -or @($Variants | Where-Object { $_ }).Count -eq 0) { return $null }
    $keys = @($cards | ForEach-Object {
            $match = Resolve-FastLlmAdapterVariant -PlannerAdapter $_ -DxgiAdapters $DxgiAdapters -Variants $Variants
            if ($match.status -eq 'matched') { [string] $match.variant } else { '<unidentified>' } } | Sort-Object -Unique)
    if ($keys.Count -eq 1 -and $keys[0] -ne '<unidentified>') { return [string] $keys[0] }
    return $null
}

function New-FastLlmPlanRecipeBlock {
    param($Pick, [string] $ModelId, [string[]] $Skipped, [switch] $Recovered, [switch] $HipBackend, [string] $IdentifiedVariant)
    if ($Pick) {
        $recipe = $Pick.recipe
        $url = $null
        if ($recipe.PSObject.Properties['evidence'] -and $recipe.evidence -and $recipe.evidence.PSObject.Properties['url'] -and $recipe.evidence.url) { $url = [string] $recipe.evidence.url }
        $expected = $null
        if ($recipe.PSObject.Properties['expected']) { $expected = $recipe.expected }
        $mitigation = $null
        if ($recipe.PSObject.Properties['runtime'] -and $recipe.runtime -and $recipe.runtime.PSObject.Properties['vulkanBarMitigation']) { $mitigation = [string] $recipe.runtime.vulkanBarMitigation }
        # The Vulkan BAR mitigation does not apply to the HIP engine; a HIP plan records that instead of a blank.
        if ($HipBackend -and $null -eq $mitigation) { $mitigation = 'not-applicable' }
        return [pscustomobject] [ordered] @{ id = [string] $recipe.id; origin = [string] $recipe.origin; label = (Get-FastLlmRecipeLabel ([string] $recipe.origin))
            variant = $Pick.variant; evidenceUrl = $url; expected = $expected; vulkanBarMitigation = $mitigation; skipped = @($Pick.skipped) }
    }
    $origin = 'estimated'
    if ($ModelId -and -not $Recovered) { $origin = 'manual' }   # a model picked by recovery is not the user's choice
    # variant is the identified card variant even without a recipe (the window offers only that card's setups); $null when the card is not identified.
    $planVariant = $null
    if (-not [string]::IsNullOrWhiteSpace($IdentifiedVariant)) { $planVariant = $IdentifiedVariant }
    return [pscustomobject] [ordered] @{ id = $null; origin = $origin; label = (Get-FastLlmRecipeLabel $origin); variant = $planVariant
        evidenceUrl = $null; expected = $null; vulkanBarMitigation = $null; skipped = @($Skipped) }
}
