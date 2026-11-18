# Serving-profile run detection for the measurement tools. Loaded by the module (the benchmark default-setup check) and by
# FastLlm.SemanticSmoke.ps1 (the semantic-smoke state check), so each rule has one definition and no second copy.
# Windows PowerShell 5.1 compatible.

# The closed sets of the serving profiles (FastLlm.psm1 validates measured rows against the same ones).
function Get-FastLlmServingProfileVocabulary {
    return [pscustomobject]@{ slots = @(1, 2); cacheTypes = @('f16', 'q8_0'); defaultCacheType = 'f16'; profileIds = @('default', 'long') }
}

# llama-server also accepts -np (--parallel), -ctk / -ctv (--cache-type-k / -v) and -c (--ctx-size). The product writes only the long forms
# (the default argument goldens pin them), so a short form, with a space or an equals sign, is never the default run.
function Test-FastLlmServingProfileShortForm {
    param([string[]] $Arguments)
    # A null list has no short form (Windows PowerShell 5.1 returns $null for @($x) on an array-typed $null, so it is not wrapped).
    if ($null -eq $Arguments) { return $false }
    foreach ($argument in $Arguments) {
        foreach ($short in @('-np', '-ctk', '-ctv', '-c')) {
            if ($argument -ceq $short -or ([string] $argument).StartsWith($short + '=', [StringComparison]::Ordinal)) { return $true }
        }
    }
    return $false
}

# What a measurement tool needs to know about a run, read from the status document of a start: is it a serving-profile run (an opt-in context
# profile, a second slot or a non-default KV cache type), and is that run's own record consistent. The default run has none of these: its
# arguments carry --parallel 1 and --cache-type-k/-v f16 (the default arguments are pinned), so only another value counts.
# Every read is tolerant (a status written before a field existed, or a recipe with only some of the fields, is a default run).
# This is the one definition: the semantic-smoke state check and the benchmark default-setup check both call it.
function Test-FastLlmServingProfileRun {
    param($State)
    if ($null -eq $State) { return $false }
    $recipeProperty = $State.PSObject.Properties['recipe']
    if ($null -eq $recipeProperty -or $null -eq $recipeProperty.Value) { return $false }
    $recipe = $recipeProperty.Value
    $whole = 0
    # A recipe written for a plan with a serving profile names it, even when the profile is the default id on a second slot.
    if ($null -ne $recipe.PSObject.Properties['profile']) { return $true }
    $slotsProperty = $recipe.PSObject.Properties['slots']
    if ($null -ne $slotsProperty -and (-not [int]::TryParse([string] $slotsProperty.Value, [ref] $whole) -or $whole -ne 1)) { return $true }
    $perSlotProperty = $recipe.PSObject.Properties['contextPerSlot']
    if ($null -ne $perSlotProperty) {
        $perSlot = 0
        $total = 0
        $totalProperty = $recipe.PSObject.Properties['contextSize']
        if ($null -eq $totalProperty -or -not [int]::TryParse([string] $perSlotProperty.Value, [ref] $perSlot) -or
            -not [int]::TryParse([string] $totalProperty.Value, [ref] $total) -or $perSlot -ne $total) { return $true }
    }
    $argumentsProperty = $recipe.PSObject.Properties['requestedArguments']
    if ($null -ne $argumentsProperty -and $null -ne $argumentsProperty.Value) {
        $arguments = @($argumentsProperty.Value | ForEach-Object { [string] $_ })
        if (Test-FastLlmServingProfileShortForm $arguments) { return $true }
        $seen = @{}
        for ($i = 0; $i -lt $arguments.Count; $i++) {
            $name = $arguments[$i]
            $value = $null
            $equals = $name.IndexOf('=')
            if ($equals -gt 0 -and $name.StartsWith('--', [StringComparison]::Ordinal)) { $value = $name.Substring($equals + 1); $name = $name.Substring(0, $equals) }
            elseif ($i + 1 -lt $arguments.Count) { $value = $arguments[$i + 1] }
            if ($name -cne '--parallel' -and $name -cne '--cache-type-k' -and $name -cne '--cache-type-v') { continue }
            # A repeated argument, or one with no value, cannot be read as the default.
            if ($seen.ContainsKey($name) -or $null -eq $value) { return $true }
            $seen[$name] = $true
            $default = if ($name -ceq '--parallel') { '1' } else { [string] (Get-FastLlmServingProfileVocabulary).defaultCacheType }
            if ($value -cne $default) { return $true }
        }
    }
    return $false
}

# The rules a serving-profile run must meet to be measured at all (checked only behind an explicit opt-in): the product's own closed sets
# (slots 1 or 2, KV cache f16 or q8_0, one cache type for K and V), a context total that divides by the slots, a per-slot context that the
# canary saw, a profile id from the closed list, and no short-form argument. The caller still checks --parallel and --ctx-size against these values.
function Test-FastLlmServingProfileState {
    param($State)
    $vocabulary = Get-FastLlmServingProfileVocabulary
    $isWhole = { param($Value) return [bool] ($Value -is [int] -or $Value -is [long]) }
    if ($null -eq $State -or $null -eq $State.PSObject.Properties['recipe'] -or $null -eq $State.recipe) { return $false }
    $recipe = $State.recipe
    $read = { param($Object, [string] $Name) if ($null -eq $Object) { return $null }; $property = $Object.PSObject.Properties[$Name]; if ($null -eq $property) { return $null }; return $property.Value }
    $slots = & $read $recipe 'slots'
    $total = & $read $recipe 'contextSize'
    $perSlot = & $read $recipe 'contextPerSlot'
    $effective = & $read (& $read $State 'canary') 'effectiveContext'
    if (-not (& $isWhole $slots) -or @($vocabulary.slots) -notcontains [int] $slots) { return $false }
    if (-not (& $isWhole $total) -or -not (& $isWhole $perSlot) -or [long] $perSlot -lt 1 -or ([long] $perSlot * [long] $slots) -ne [long] $total) { return $false }
    if (-not (& $isWhole $effective) -or [long] $effective -ne [long] $perSlot) { return $false }
    $profileId = & $read $recipe 'profile'
    if ($null -ne $recipe.PSObject.Properties['profile'] -and ($profileId -isnot [string] -or @($vocabulary.profileIds) -cnotcontains $profileId)) { return $false }
    $arguments = @()
    $argumentsValue = & $read $recipe 'requestedArguments'
    if ($null -ne $argumentsValue) { $arguments = @($argumentsValue | ForEach-Object { [string] $_ }) }
    if (Test-FastLlmServingProfileShortForm $arguments) { return $false }
    $cache = @{}
    foreach ($name in @('--cache-type-k', '--cache-type-v')) {
        $indices = @(for ($i = 0; $i -lt $arguments.Count; $i++) { if ($arguments[$i] -ceq $name) { $i } })
        if (@($arguments | Where-Object { $_.StartsWith($name + '=', [StringComparison]::Ordinal) }).Count -gt 0) { return $false }
        if ($indices.Count -gt 1) { return $false }
        if ($indices.Count -eq 1) {
            if ($indices[0] + 1 -ge $arguments.Count -or @($vocabulary.cacheTypes) -cnotcontains $arguments[$indices[0] + 1]) { return $false }
            $cache[$name] = $arguments[$indices[0] + 1]
        }
    }
    if ($cache.ContainsKey('--cache-type-k') -and $cache.ContainsKey('--cache-type-v') -and $cache['--cache-type-k'] -cne $cache['--cache-type-v']) { return $false }
    return $true
}
