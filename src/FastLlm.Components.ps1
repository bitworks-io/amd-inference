# Experimental switch, component list formatting and the experimental-recipe gate (community components, C1).
# Dot-sourced ONLY by fast-llm.ps1 and fast-llm-ui.ps1, never by src/FastLlm.psm1: the producer inputs stay as they are.
# Windows PowerShell 5.1-safe; ASCII only.
Set-StrictMode -Version 2

# Spec section 2.7: what experimental means, that Bitworks has not reproduced the recipe, and where each component comes from.
$script:FastLlmExperimentalParagraph = 'Experimental community recipes are setups that other people published and that Bitworks has not reproduced. ' +
    'Experimental means they may be slow, unstable or fail on your card, and the speed they claim has not been confirmed by Bitworks. ' +
    'Each component comes from its listed official source and is checked against its pinned hash before it is used. ' +
    'Nothing is chosen for you: an experimental recipe is only used when you pick it and accept each of its components. ' +
    'You can turn this off at any time. Components you installed stay on disk until you remove them.'

function Read-FastLlmComponentSettingsObject {
    param([Parameter(Mandatory = $true)][string] $InstallRoot)
    $result = [ordered]@{}
    try {
        $path = Join-Path $InstallRoot 'settings.json'
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $stored = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            if ($null -ne $stored -and $stored -is [pscustomobject]) {
                foreach ($property in $stored.PSObject.Properties) { $result[$property.Name] = $property.Value }
            }
        }
    }
    catch { $result = [ordered]@{} }
    return $result
}

# experimentalComponents in <InstallRoot>\settings.json: 'on' or 'off', default 'off'. Anything else reads as 'off'.
function Get-FastLlmComponentSettings {
    param([Parameter(Mandatory = $true)][string] $InstallRoot)
    $stored = Read-FastLlmComponentSettingsObject -InstallRoot $InstallRoot
    $value = 'off'
    if ($stored.Contains('experimentalComponents') -and (@('on', 'off') -ccontains [string] $stored['experimentalComponents'])) {
        $value = [string] $stored['experimentalComponents']
    }
    return @{ experimentalComponents = $value }
}

# Read-modify-write: every other key already in settings.json is kept.
function Set-FastLlmComponentSettings {
    param(
        [Parameter(Mandatory = $true)][string] $InstallRoot,
        [Parameter(Mandatory = $true)][ValidateSet('on', 'off')][string] $ExperimentalComponents
    )
    $merged = Read-FastLlmComponentSettingsObject -InstallRoot $InstallRoot
    $merged['experimentalComponents'] = $ExperimentalComponents
    if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) { New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null }
    $path = Join-Path $InstallRoot 'settings.json'
    $temporary = "$path.tmp-$([guid]::NewGuid().ToString('N'))"
    [IO.File]::WriteAllText($temporary, (([pscustomobject] $merged) | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    if (Get-Command -Name Move-FastLlmFileReplacing -ErrorAction SilentlyContinue) { Move-FastLlmFileReplacing -Source $temporary -Destination $path }
    else { Move-Item -LiteralPath $temporary -Destination $path -Force }
}

function Format-FastLlmComponentSize {
    param([int64] $Bytes)
    $megabytes = [double] $Bytes / 1048576.0
    return ($megabytes.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture) + ' MB')
}

# One line per inventory row (Get-FastLlmComponentInventory): id, kind, version, installed, size in MB, verified.
function Format-FastLlmComponentList {
    param([object[]] $Inventory)
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add(('{0,-34} {1,-8} {2,-10} {3,-10} {4,12} {5,-8}' -f 'id', 'kind', 'version', 'installed', 'size', 'verified'))
    foreach ($row in @($Inventory | Where-Object { $_ })) {
        $installedText = 'no'
        $sizeText = '-'
        $verifiedText = '-'
        if ([bool] $row.installed) {
            $installedText = 'yes'
            $sizeText = Format-FastLlmComponentSize -Bytes ([int64] $row.bytes)
            $verifiedText = 'no'
            if ([bool] $row.verified) { $verifiedText = 'yes' }
        }
        $lines.Add(('{0,-34} {1,-8} {2,-10} {3,-10} {4,12} {5,-8}' -f [string] $row.id, [string] $row.kind, [string] $row.version, $installedText, $sizeText, $verifiedText))
    }
    return $lines.ToArray()
}

# Only what is installed, for the Components window: id, version, kind and size, one row each.
function Get-FastLlmInstalledComponentRows {
    param([object[]] $Inventory)
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($row in @($Inventory | Where-Object { $_ -and [bool] $_.installed })) {
        $rows.Add([pscustomobject] [ordered] @{
                id    = [string] $row.id
                kind  = [string] $row.kind
                label = ('{0} ({1}, {2}) - {3}' -f [string] $row.id, [string] $row.kind, [string] $row.version, (Format-FastLlmComponentSize -Bytes ([int64] $row.bytes)))
            })
    }
    return $rows.ToArray()
}

# Experimental recipes are hidden unless the switch is on. Other recipes are always listed. Installed components never change this.
function Select-FastLlmVisibleRecipes {
    param([object[]] $Recipes, [string] $ExperimentalComponents = 'off')
    $visible = New-Object 'System.Collections.Generic.List[object]'
    foreach ($candidate in @($Recipes | Where-Object { $_ })) {
        if ((Test-FastLlmExperimentalOrigin -Origin ([string] $candidate.origin)) -and $ExperimentalComponents -cne 'on') { continue }
        $visible.Add($candidate)
    }
    return $visible.ToArray()
}

# The display text of a component's sources: every URL, plus the redirect hosts a download may be served from.
function Get-FastLlmComponentSourceText {
    param([Parameter(Mandatory = $true)] $Listed)
    # Display only (the loader has already validated the list): every source URL of the component, single 'source' or multi-part 'sources',
    # and the redirect hosts the download may be served from.
    $entries = @()
    if ($Listed.PSObject.Properties['sources'] -and $Listed.sources) { $entries = @($Listed.sources) }
    elseif ($Listed.PSObject.Properties['source'] -and $Listed.source) { $entries = @($Listed.source) }
    $urls = @($entries | ForEach-Object { [string] $_.url } | Where-Object { $_ })
    if ($urls.Count -eq 0) { return $null }
    $text = ($urls -join ', ')
    $redirectHosts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in $entries) {
        if ($entry.PSObject.Properties['allowedRedirectHosts'] -and $entry.allowedRedirectHosts) {
            foreach ($redirectHost in @($entry.allowedRedirectHosts)) { if ($redirectHost -and -not $redirectHosts.Contains([string] $redirectHost)) { $redirectHosts.Add([string] $redirectHost) } }
        }
    }
    if ($redirectHosts.Count -gt 0) { $text += '; downloads may be redirected via ' + ($redirectHosts -join ', ') }
    return $text
}

# Every component a recipe names (engine, runtime, model, draft) with its source URL when it is a listed component. A listed engine is expanded to its
# whole requires chain (requires first, the engine last), so a component that only the engine pulls in (the AMD runtime) is listed too.
function Get-FastLlmRecipeComponentSources {
    param([Parameter(Mandatory = $true)] $Recipe, [object[]] $Components)
    $rows = New-Object 'System.Collections.Generic.List[object]'
    if (-not $Recipe.PSObject.Properties['components'] -or -not $Recipe.components) { return $rows.ToArray() }
    foreach ($role in @('engine', 'runtime', 'model', 'draft')) {
        $roleProperty = $Recipe.components.PSObject.Properties[$role]
        if (-not $roleProperty -or [string]::IsNullOrWhiteSpace([string] $roleProperty.Value)) { continue }
        $componentId = [string] $roleProperty.Value
        $members = @()
        if ($role -ceq 'engine' -or $role -ceq 'runtime') {
            $listedRoot = @($Components | Where-Object { $_ -and [string] $_.id -ceq $componentId })
            if ($listedRoot.Count -gt 0) {
                # An unresolvable chain falls back to the named component alone; the install and the plan refuse it with a typed failure of their own.
                try { $members = @(Get-FastLlmComponentChain -Components $Components -Id $componentId) } catch { $members = @() }
            }
        }
        if ($members.Count -eq 0) {
            $found = @($Components | Where-Object { $_ -and [string] $_.id -ceq $componentId })
            if ($found.Count -gt 0) { $members = @($found[0]) }
        }
        if ($members.Count -eq 0) {
            $rows.Add([pscustomobject] [ordered] @{ role = $role; id = $componentId; sourceUrl = $null; listed = $false })
            continue
        }
        foreach ($member in $members) {
            $memberRole = $role
            if ([string] $member.id -cne $componentId -and $member.PSObject.Properties['kind'] -and $member.kind) { $memberRole = [string] $member.kind }
            $sourceUrl = Get-FastLlmComponentSourceText -Listed $member
            $rows.Add([pscustomobject] [ordered] @{ role = $memberRole; id = [string] $member.id; sourceUrl = $sourceUrl; listed = [bool] $sourceUrl })
        }
    }
    return $rows.ToArray()
}

# plan, start and install with -Recipe of a community-experimental or bitworks-experimental recipe: refused unless the switch is on AND -AcceptExperimental is given.
# Other origins and a missing recipe pass through here (an unknown id is refused later by the recipe selection itself).
function Assert-FastLlmExperimentalRecipeAllowed {
    param(
        [Parameter(Mandatory = $true)][string] $InstallRoot,
        [string] $RecipeId,
        [object[]] $Recipes,
        [object[]] $Components,
        [switch] $AcceptExperimental
    )
    if ([string]::IsNullOrWhiteSpace($RecipeId)) { return }
    # Same case-insensitive id match as the recipe selection: any match that is community-experimental or bitworks-experimental is gated.
    $found = $null
    foreach ($candidate in @($Recipes | Where-Object { $_ })) {
        if ([string] $candidate.id -ieq $RecipeId -and (Test-FastLlmExperimentalOrigin -Origin ([string] $candidate.origin))) { $found = $candidate }
    }
    if ($null -eq $found) { return }
    $switchValue = [string] (Get-FastLlmComponentSettings -InstallRoot $InstallRoot).experimentalComponents
    if ($switchValue -ceq 'on' -and $AcceptExperimental) { return }
    $reasons = New-Object 'System.Collections.Generic.List[string]'
    if ($switchValue -cne 'on') { $reasons.Add("the experimental components switch is off (turn on 'Experimental community components' in the FastLLM window, or set experimentalComponents to on in settings.json)") }
    if (-not $AcceptExperimental) { $reasons.Add('-AcceptExperimental was not given') }
    $named = @(Get-FastLlmRecipeComponentSources -Recipe $found -Components $Components | ForEach-Object {
            if ($_.listed) { '{0} {1} ({2})' -f $_.role, $_.id, $_.sourceUrl } else { '{0} {1} (comes with this release)' -f $_.role, $_.id }
        })
    $refusedKind = 'an experimental community recipe, not reproduced by Bitworks'
    if ([string] $found.origin -ieq 'bitworks-experimental') { $refusedKind = 'an experimental Bitworks setup, not yet measured by Bitworks on this card' }
    throw ("Recipe '$RecipeId' is $refusedKind, and was refused: " + ($reasons -join '; and ') +
        ". It would use: " + ($named -join '; ') + '. Nothing was changed.')
}

# The hosts a listed component downloads from (the host of each source URL), and separately the hosts a download may be redirected to.
function Get-FastLlmComponentSourceHosts {
    param([Parameter(Mandatory = $true)] $Listed, [switch] $Redirect)
    $entries = @()
    if ($Listed.PSObject.Properties['sources'] -and $Listed.sources) { $entries = @($Listed.sources) }
    elseif ($Listed.PSObject.Properties['source'] -and $Listed.source) { $entries = @($Listed.source) }
    $hosts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in $entries) {
        $candidates = @()
        if ($Redirect) {
            if ($entry.PSObject.Properties['allowedRedirectHosts'] -and $entry.allowedRedirectHosts) { $candidates = @($entry.allowedRedirectHosts | ForEach-Object { [string] $_ }) }
        }
        else {
            $parsed = $null
            if ([Uri]::TryCreate([string] $entry.url, [UriKind]::Absolute, [ref] $parsed)) { $candidates = @($parsed.Host) }
        }
        foreach ($candidate in $candidates) { if ($candidate -and -not $hosts.Contains($candidate)) { $hosts.Add($candidate) } }
    }
    return $hosts.ToArray()
}

# One row per recipe for the window's "Choose another setup" list: the recipe, its label, model and context, and the engine's whole requires chain
# (requires first, the engine last) with install state, license consent kind, source hosts and license links. Read-only and offline: the
# inventory is presence-only. The caller passes the recipes it wants listed (Select-FastLlmVisibleRecipes has already hidden experimental ones).
function Get-FastLlmRecipeChooserRows {
    param([object[]] $Recipes, [object[]] $Components, [object[]] $Inventory, [Parameter(Mandatory = $true)] $Catalog)
    $installedIds = @{}
    foreach ($inventoryRow in @($Inventory | Where-Object { $_ })) { if ([bool] $inventoryRow.installed) { $installedIds[[string] $inventoryRow.id] = $true } }
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($recipe in @($Recipes | Where-Object { $_ })) {
        # Same rule as the recipe selection: the recipe's named engine component, else the built-in Vulkan engine of the catalog.
        $engineId = 'llama.cpp-' + [string] $Catalog.engine.version + '-vulkan'
        if ($recipe.PSObject.Properties['components'] -and $recipe.components -and $recipe.components.PSObject.Properties['engine'] -and $recipe.components.engine) { $engineId = [string] $recipe.components.engine }
        $chainError = ''
        $members = @()
        if (@($Components | Where-Object { $_ -and [string] $_.id -ceq $engineId }).Count -gt 0) {
            try { $members = @(Get-FastLlmComponentChain -Components $Components -Id $engineId) }
            catch { $chainError = [string] $_.Exception.Message }
        }
        else { $chainError = "The engine '$engineId' is not in this release's component list." }
        $chain = New-Object 'System.Collections.Generic.List[object]'
        $consentRequired = $false
        foreach ($member in $members) {
            $consent = ''
            if ($member.PSObject.Properties['license'] -and $member.license -and $member.license.PSObject.Properties['consent']) { $consent = [string] $member.license.consent }
            $isInstalled = $installedIds.ContainsKey([string] $member.id)
            if (-not $isInstalled -and $consent -ceq 'accept') { $consentRequired = $true }
            $displayName = [string] $member.id
            if ($member.PSObject.Properties['displayName'] -and $member.displayName) { $displayName = [string] $member.displayName }
            $chain.Add([pscustomobject] [ordered] @{
                    id = [string] $member.id; displayName = $displayName; kind = [string] $member.kind; version = [string] $member.version
                    installed = [bool] $isInstalled; consent = $consent
                    sourceHosts = @(Get-FastLlmComponentSourceHosts -Listed $member); redirectHosts = @(Get-FastLlmComponentSourceHosts -Listed $member -Redirect)
                    licenseLinks = @(Get-FastLlmComponentLicenseLinks -Component $member)
                })
        }
        $contextSize = 0
        if ($recipe.PSObject.Properties['runtime'] -and $recipe.runtime -and $recipe.runtime.PSObject.Properties['contextSize']) { $contextSize = [int] $recipe.runtime.contextSize }
        $rows.Add([pscustomobject] [ordered] @{
                id = [string] $recipe.id; origin = [string] $recipe.origin; label = (Get-FastLlmRecipeLabel ([string] $recipe.origin))
                variant = [string] $recipe.gpu.variant; gpuCount = [int] $recipe.gpu.count
                model = [string] $recipe.components.model; contextSize = $contextSize
                engineId = $engineId; chain = $chain.ToArray(); consentRequired = [bool] $consentRequired; chainError = $chainError
            })
    }
    return $rows.ToArray()
}
