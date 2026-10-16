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

# Writes the whole settings object through a temporary file and a replace, so a reader never sees a half-written file.
function Write-FastLlmComponentSettingsObject {
    param([Parameter(Mandatory = $true)][string] $InstallRoot, [Parameter(Mandatory = $true)] $Merged)
    if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) { New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null }
    $path = Join-Path $InstallRoot 'settings.json'
    $temporary = "$path.tmp-$([guid]::NewGuid().ToString('N'))"
    [IO.File]::WriteAllText($temporary, (([pscustomobject] $Merged) | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    if (Get-Command -Name Move-FastLlmFileReplacing -ErrorAction SilentlyContinue) { Move-FastLlmFileReplacing -Source $temporary -Destination $path }
    else { Move-Item -LiteralPath $temporary -Destination $path -Force }
}

# Read-modify-write: every other key already in settings.json is kept.
function Set-FastLlmComponentSettings {
    param(
        [Parameter(Mandatory = $true)][string] $InstallRoot,
        [Parameter(Mandatory = $true)][ValidateSet('on', 'off')][string] $ExperimentalComponents
    )
    $merged = Read-FastLlmComponentSettingsObject -InstallRoot $InstallRoot
    $merged['experimentalComponents'] = $ExperimentalComponents
    Write-FastLlmComponentSettingsObject -InstallRoot $InstallRoot -Merged $merged
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
# (requires first, the engine last) with its state, license consent kind, source hosts and license links. Read-only and offline.
# State: the recipe's built-in engine is "built in" when its executable is under engines\ and "missing" otherwise (the window's start installs it);
# every other member is "installed" only when the inventory says installed AND verified (presence and size), else "missing".
# The caller passes the recipes it wants listed (Select-FastLlmVisibleRecipes has already hidden experimental ones).
function Get-FastLlmRecipeChooserRows {
    param([object[]] $Recipes, [object[]] $Components, [object[]] $Inventory, [Parameter(Mandatory = $true)] $Catalog, [Parameter(Mandatory = $true)][string] $InstallRoot)
    $installedIds = @{}
    foreach ($inventoryRow in @($Inventory | Where-Object { $_ })) { if ([bool] $inventoryRow.installed -and [bool] $inventoryRow.verified) { $installedIds[[string] $inventoryRow.id] = $true } }
    $builtInEngineId = 'llama.cpp-' + [string] $Catalog.engine.version + '-vulkan'
    $builtInEntryPoint = 'llama-server.exe'
    if ($Catalog.engine.PSObject.Properties['assets'] -and $Catalog.engine.assets -and $Catalog.engine.assets.PSObject.Properties['vulkan'] -and
        $Catalog.engine.assets.vulkan.PSObject.Properties['entryPoint'] -and $Catalog.engine.assets.vulkan.entryPoint) { $builtInEntryPoint = [string] $Catalog.engine.assets.vulkan.entryPoint }
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($recipe in @($Recipes | Where-Object { $_ })) {
        # Same rule as the recipe selection: the recipe's named engine component, else the built-in Vulkan engine of the catalog.
        $engineId = $builtInEngineId
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
        $installRequired = $false
        foreach ($member in $members) {
            $consent = ''
            if ($member.PSObject.Properties['license'] -and $member.license -and $member.license.PSObject.Properties['consent']) { $consent = [string] $member.license.consent }
            $isBuiltIn = ([string] $member.id -ceq $builtInEngineId)
            if ($isBuiltIn) { $isInstalled = [bool] (Get-FastLlmEngineExecutable -InstallRoot $InstallRoot -EngineVersion ([string] $Catalog.engine.version) -BackendKey 'vulkan' -EntryPoint $builtInEntryPoint) }
            else { $isInstalled = $installedIds.ContainsKey([string] $member.id) }
            $state = 'missing'
            if ($isInstalled -and $isBuiltIn) { $state = 'built in' } elseif ($isInstalled) { $state = 'installed' }
            if (-not $isInstalled -and $consent -ceq 'accept') { $consentRequired = $true }
            # The built-in engine is installed by the start itself; any other missing member needs the window's install first.
            if (-not $isInstalled -and -not $isBuiltIn) { $installRequired = $true }
            $displayName = [string] $member.id
            if ($member.PSObject.Properties['displayName'] -and $member.displayName) { $displayName = [string] $member.displayName }
            $chain.Add([pscustomobject] [ordered] @{
                    id = [string] $member.id; displayName = $displayName; kind = [string] $member.kind; version = [string] $member.version
                    builtIn = [bool] $isBuiltIn; installed = [bool] $isInstalled; state = $state; consent = $consent
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
                engineId = $engineId; chain = $chain.ToArray(); consentRequired = [bool] $consentRequired; installRequired = [bool] $installRequired; chainError = $chainError
            })
    }
    return $rows.ToArray()
}

# The experimental switch lives in the settings of the root the window was launched from, but every child is given the install folder shown in the
# window. Mirror the stored value into that folder's settings when it differs, so the CLI the child runs sees the switch the user set. Returns $true
# when it wrote. Never writes when the two already agree (so a default root is not touched).
function Sync-FastLlmExperimentalSwitch {
    param([Parameter(Mandatory = $true)][string] $SourceRoot, [Parameter(Mandatory = $true)][string] $TargetRoot)
    if ([IO.Path]::GetFullPath($SourceRoot).TrimEnd('\', '/') -ieq [IO.Path]::GetFullPath($TargetRoot).TrimEnd('\', '/')) { return $false }
    $wanted = [string] (Get-FastLlmComponentSettings -InstallRoot $SourceRoot).experimentalComponents
    $stored = [string] (Get-FastLlmComponentSettings -InstallRoot $TargetRoot).experimentalComponents
    if ($wanted -ceq $stored) { return $false }
    Set-FastLlmComponentSettings -InstallRoot $TargetRoot -ExperimentalComponents $wanted
    return $true
}

# Stores the switch under the launch root and mirrors it into the install folder. When the mirror fails the launch-root value goes back to what it
# was, so the stored switch, the checkbox the caller restores and the folder all agree; the error is rethrown for the caller to show.
function Set-FastLlmExperimentalSwitchMirrored {
    param(
        [Parameter(Mandatory = $true)][string] $SourceRoot,
        [Parameter(Mandatory = $true)][string] $TargetRoot,
        [Parameter(Mandatory = $true)][ValidateSet('on', 'off')][string] $Value
    )
    $previous = [string] (Get-FastLlmComponentSettings -InstallRoot $SourceRoot).experimentalComponents
    Set-FastLlmComponentSettings -InstallRoot $SourceRoot -ExperimentalComponents $Value
    try { [void](Sync-FastLlmExperimentalSwitch -SourceRoot $SourceRoot -TargetRoot $TargetRoot) }
    catch {
        $failure = $_.Exception.Message
        try { Set-FastLlmComponentSettings -InstallRoot $SourceRoot -ExperimentalComponents $previous } catch { }
        throw "The experimental components setting could not be applied to the install folder, so it was not changed: $failure"
    }
}

# ---- componentLicenses: accept the licenses of engine components automatically (a standing, explicit user setting) ----

# componentLicenses in <InstallRoot>\settings.json: { mode: 'ask' | 'accept-automatically', acceptedAt, accepted: [ { title, host } ] }.
# Reads fail closed: anything missing, malformed or incomplete reads as 'ask' with an empty list. Never throws.
function Get-FastLlmComponentLicenseSettings {
    param([Parameter(Mandatory = $true)][string] $InstallRoot)
    $ask = [pscustomobject] [ordered] @{ mode = 'ask'; acceptedAt = ''; accepted = @() }
    try {
        $stored = Read-FastLlmComponentSettingsObject -InstallRoot $InstallRoot
        if (-not $stored.Contains('componentLicenses')) { return $ask }
        $block = $stored['componentLicenses']
        if ($null -eq $block -or $block -isnot [pscustomobject]) { return $ask }
        $modeProperty = $block.PSObject.Properties['mode']
        if ($null -eq $modeProperty -or $modeProperty.Value -isnot [string] -or $modeProperty.Value -cne 'accept-automatically') { return $ask }
        $listProperty = $block.PSObject.Properties['accepted']
        if ($null -eq $listProperty -or $listProperty.Value -isnot [array]) { return $ask }
        $accepted = New-Object 'System.Collections.Generic.List[object]'
        foreach ($entry in $listProperty.Value) {
            if ($null -eq $entry -or $entry -isnot [pscustomobject]) { return $ask }
            $titleProperty = $entry.PSObject.Properties['title']
            $hostProperty = $entry.PSObject.Properties['host']
            if ($null -eq $titleProperty -or $null -eq $hostProperty -or $titleProperty.Value -isnot [string] -or $hostProperty.Value -isnot [string]) { return $ask }
            $title = ([string] $titleProperty.Value).Trim()
            $hostName = ([string] $hostProperty.Value).Trim()
            if ($title.Length -eq 0 -or $hostName.Length -eq 0) { return $ask }
            if ([regex]::IsMatch($title + $hostName, '[\x00-\x1F\x7F]')) { return $ask }
            $accepted.Add([pscustomobject] [ordered] @{ title = $title; host = $hostName })
        }
        if ($accepted.Count -eq 0) { return $ask }
        # A missing, blank or unparsable acceptedAt reads as ask: a receipt never carries a time that was made up.
        $acceptedAt = ''
        $atProperty = $block.PSObject.Properties['acceptedAt']
        if ($null -eq $atProperty) { return $ask }
        if ($atProperty.Value -is [string]) {
            $parsedAt = [datetime]::MinValue
            if ([string]::IsNullOrWhiteSpace([string] $atProperty.Value) -or -not [datetime]::TryParse([string] $atProperty.Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref] $parsedAt)) { return $ask }
            $acceptedAt = [string] $atProperty.Value
        }
        elseif ($atProperty.Value -is [datetime]) { $acceptedAt = ([datetime] $atProperty.Value).ToUniversalTime().ToString('o') }
        else { return $ask }
        return [pscustomobject] [ordered] @{ mode = 'accept-automatically'; acceptedAt = $acceptedAt; accepted = $accepted.ToArray() }
    }
    catch { return $ask }
}

# Read-modify-write: every other key already in settings.json is kept. 'ask' stores an empty list.
function Set-FastLlmComponentLicenseSettings {
    param(
        [Parameter(Mandatory = $true)][string] $InstallRoot,
        [Parameter(Mandatory = $true)][ValidateSet('ask', 'accept-automatically')][string] $Mode,
        [object[]] $Accepted = @(),
        [string] $AcceptedAt = ''
    )
    $entries = New-Object 'System.Collections.Generic.List[object]'
    if ($Mode -ceq 'accept-automatically') {
        foreach ($identity in @($Accepted)) {
            if ($null -eq $identity -or [string]::IsNullOrWhiteSpace([string] $identity.title) -or [string]::IsNullOrWhiteSpace([string] $identity.host)) {
                throw 'Every accepted license needs a title and a host.'
            }
            $entries.Add([pscustomobject] [ordered] @{ title = ([string] $identity.title).Trim(); host = ([string] $identity.host).Trim() })
        }
        if ($entries.Count -eq 0) { throw 'accept-automatically needs at least one accepted license.' }
    }
    $merged = Read-FastLlmComponentSettingsObject -InstallRoot $InstallRoot
    $merged['componentLicenses'] = [pscustomobject] [ordered] @{
        mode       = $Mode
        acceptedAt = $(if ($Mode -ceq 'accept-automatically') { $AcceptedAt } else { '' })
        accepted   = $entries.ToArray()
    }
    Write-FastLlmComponentSettingsObject -InstallRoot $InstallRoot -Merged $merged
}

# The host of an https license URL, or $null when the URL does not parse, is not https or contains a control character.
function Get-FastLlmLicenseUrlHost {
    param([string] $Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
    if ([regex]::IsMatch($Url, '[\x00-\x1F\x7F]')) { return $null }
    $parsed = $null
    if (-not [Uri]::TryCreate($Url.Trim(), [UriKind]::Absolute, [ref] $parsed)) { return $null }
    if ($parsed.Scheme -cne 'https' -or [string]::IsNullOrEmpty($parsed.Host)) { return $null }
    return [string] $parsed.Host
}

# Every license link (title, host, url) of every accept-type component in the list, once per title and host.
function Get-FastLlmAcceptableLicenseLinks {
    param([object[]] $Components)
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $result = New-Object 'System.Collections.Generic.List[object]'
    foreach ($component in @($Components | Where-Object { $_ })) {
        $licenseProperty = $component.PSObject.Properties['license']
        if ($null -eq $licenseProperty -or $null -eq $licenseProperty.Value) { continue }
        $consentProperty = $licenseProperty.Value.PSObject.Properties['consent']
        if ($null -eq $consentProperty -or [string] $consentProperty.Value -cne 'accept') { continue }
        foreach ($link in @(Get-FastLlmComponentLicenseLinks -Component $component)) {
            $hostName = Get-FastLlmLicenseUrlHost -Url ([string] $link.url)
            $title = ([string] $link.title).Trim()
            if ($null -eq $hostName -or $title.Length -eq 0) { continue }
            if ($seen.Add($title + "`n" + $hostName)) {
                $result.Add([pscustomobject] [ordered] @{ title = $title; host = $hostName; url = ([string] $link.url).Trim() })
            }
        }
    }
    return $result.ToArray()
}

# The license identities (title and host) a user accepts by turning the setting on.
function Get-FastLlmAcceptableLicenseIdentities {
    param([object[]] $Components)
    foreach ($link in @(Get-FastLlmAcceptableLicenseLinks -Components $Components)) {
        [pscustomobject] [ordered] @{ title = [string] $link.title; host = [string] $link.host }
    }
}

# True when the setting is accept-automatically and every license link of every pending component, whatever its consent type, matches a stored identity by title
# (case-insensitive) and URL host, never by the full URL. A link that does not parse, or has a control character, is never covered.
function Test-FastLlmLicensesCovered {
    param([Parameter(Mandatory = $true)] $Settings, [object[]] $Pending)
    try {
        if ($null -eq $Settings -or [string] $Settings.mode -cne 'accept-automatically') { return $false }
        $stored = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($identity in @($Settings.accepted)) { [void] $stored.Add(([string] $identity.title).Trim() + "`n" + ([string] $identity.host).Trim()) }
        foreach ($component in @($Pending | Where-Object { $_ })) {
            $linksProperty = $component.PSObject.Properties['licenseLinks']
            $links = @()
            if ($null -ne $linksProperty -and $null -ne $linksProperty.Value) { $links = @($linksProperty.Value) }
            if ($links.Count -eq 0) { return $false }
            foreach ($link in $links) {
                $hostName = Get-FastLlmLicenseUrlHost -Url ([string] $link.url)
                $title = ([string] $link.title).Trim()
                if ($null -eq $hostName -or $title.Length -eq 0) { return $false }
                if (-not $stored.Contains($title + "`n" + $hostName)) { return $false }
            }
        }
        return $true
    }
    catch { return $false }
}

# The lines shown before the setting is stored: every acceptable license with its current link.
function Format-FastLlmLicenseDisclosure {
    param([object[]] $Components)
    foreach ($link in @(Get-FastLlmAcceptableLicenseLinks -Components $Components)) { 'License: {0} {1}' -f $link.title, $link.url }
}

# The acceptance time to pass to Install-FastLlmComponent when the stored setting covers every accept-type license of the component's chain, else ''.
function Get-FastLlmStandingAcceptance {
    param([Parameter(Mandatory = $true)][string] $InstallRoot, [Parameter(Mandatory = $true)][string] $ComponentsPath, [Parameter(Mandatory = $true)][string] $ComponentId)
    try {
        $settings = Get-FastLlmComponentLicenseSettings -InstallRoot $InstallRoot
        if ([string] $settings.mode -cne 'accept-automatically') { return '' }
        $all = @(Get-FastLlmComponents -ComponentsPath $ComponentsPath)
        $chain = @(Get-FastLlmComponentChain -Components $all -Id $ComponentId)
        # Every member of the chain counts, whatever its consent type: a license the user did not see when turning the setting on is never covered.
        $needing = New-Object 'System.Collections.Generic.List[object]'
        foreach ($chainEntry in $chain) {
            $needing.Add([pscustomobject] @{ id = [string] $chainEntry.id; licenseLinks = @(Get-FastLlmComponentLicenseLinks -Component $chainEntry) })
        }
        if (-not (Test-FastLlmLicensesCovered -Settings $settings -Pending $needing.ToArray())) { return '' }
        return [string] $settings.acceptedAt
    }
    catch { return '' }
}

# Mirrors the stored setting from the launch root into the install folder when they differ (pattern of Sync-FastLlmExperimentalSwitch). Returns $true when it wrote.
function Sync-FastLlmComponentLicenseSetting {
    param([Parameter(Mandatory = $true)][string] $SourceRoot, [Parameter(Mandatory = $true)][string] $TargetRoot)
    if ([IO.Path]::GetFullPath($SourceRoot).TrimEnd('\', '/') -ieq [IO.Path]::GetFullPath($TargetRoot).TrimEnd('\', '/')) { return $false }
    $wanted = Get-FastLlmComponentLicenseSettings -InstallRoot $SourceRoot
    $stored = Get-FastLlmComponentLicenseSettings -InstallRoot $TargetRoot
    $same = ([string] $wanted.mode -ceq [string] $stored.mode) -and ([string] $wanted.acceptedAt -ceq [string] $stored.acceptedAt) -and
        ((@($wanted.accepted | ForEach-Object { $_.title + "`n" + $_.host }) -join "`r") -ceq (@($stored.accepted | ForEach-Object { $_.title + "`n" + $_.host }) -join "`r"))
    if ($same) { return $false }
    Set-FastLlmComponentLicenseSettings -InstallRoot $TargetRoot -Mode ([string] $wanted.mode) -Accepted @($wanted.accepted) -AcceptedAt ([string] $wanted.acceptedAt)
    return $true
}

# Stores the setting under the launch root and mirrors it into the install folder; when the mirror fails the launch-root value goes back to what it was.
function Set-FastLlmComponentLicenseSettingMirrored {
    param(
        [Parameter(Mandatory = $true)][string] $SourceRoot,
        [Parameter(Mandatory = $true)][string] $TargetRoot,
        [Parameter(Mandatory = $true)][ValidateSet('ask', 'accept-automatically')][string] $Mode,
        [object[]] $Accepted = @(),
        [string] $AcceptedAt = ''
    )
    $previous = Get-FastLlmComponentLicenseSettings -InstallRoot $SourceRoot
    Set-FastLlmComponentLicenseSettings -InstallRoot $SourceRoot -Mode $Mode -Accepted $Accepted -AcceptedAt $AcceptedAt
    try { [void](Sync-FastLlmComponentLicenseSetting -SourceRoot $SourceRoot -TargetRoot $TargetRoot) }
    catch {
        $failure = $_.Exception.Message
        try { Set-FastLlmComponentLicenseSettings -InstallRoot $SourceRoot -Mode ([string] $previous.mode) -Accepted @($previous.accepted) -AcceptedAt ([string] $previous.acceptedAt) } catch { }
        throw "The component license setting could not be applied to the install folder, so it was not changed: $failure"
    }
}

# ---- declinedSetups: setups whose component licenses the user declined in the window (window only; under the launch root, never mirrored) ----

# declinedSetups in <InstallRoot>\settings.json: an array of recipe ids. A missing or malformed value reads as empty; a malformed entry is skipped. Never throws.
function Get-FastLlmUiDeclinedSetups {
    param([Parameter(Mandatory = $true)][string] $InstallRoot)
    try {
        $stored = Read-FastLlmComponentSettingsObject -InstallRoot $InstallRoot
        if (-not $stored.Contains('declinedSetups')) { return @() }
        $value = $stored['declinedSetups']
        if ($value -isnot [array]) { return @() }
        $ids = New-Object 'System.Collections.Generic.List[string]'
        foreach ($entry in $value) {
            if ($entry -isnot [string] -or $entry -cnotmatch '^[a-z0-9][a-z0-9.\-]{1,120}$') { continue }
            if (-not $ids.Contains([string] $entry)) { $ids.Add([string] $entry) }
        }
        return $ids.ToArray()
    }
    catch { return @() }
}

function Add-FastLlmUiDeclinedSetup {
    param([Parameter(Mandatory = $true)][string] $InstallRoot, [Parameter(Mandatory = $true)][string] $RecipeId)
    if ($RecipeId -cnotmatch '^[a-z0-9][a-z0-9.\-]{1,120}$') { throw 'The setup id is not valid.' }
    $ids = New-Object 'System.Collections.Generic.List[string]'
    foreach ($id in @(Get-FastLlmUiDeclinedSetups -InstallRoot $InstallRoot)) { $ids.Add([string] $id) }
    if ($ids.Contains($RecipeId)) { return }
    $ids.Add($RecipeId)
    $merged = Read-FastLlmComponentSettingsObject -InstallRoot $InstallRoot
    $merged['declinedSetups'] = $ids.ToArray()
    Write-FastLlmComponentSettingsObject -InstallRoot $InstallRoot -Merged $merged
}

function Remove-FastLlmUiDeclinedSetup {
    param([Parameter(Mandatory = $true)][string] $InstallRoot, [Parameter(Mandatory = $true)][string] $RecipeId)
    $current = @(Get-FastLlmUiDeclinedSetups -InstallRoot $InstallRoot)
    if ($current -cnotcontains $RecipeId) { return }
    $merged = Read-FastLlmComponentSettingsObject -InstallRoot $InstallRoot
    $merged['declinedSetups'] = @($current | Where-Object { $_ -cne $RecipeId })
    Write-FastLlmComponentSettingsObject -InstallRoot $InstallRoot -Merged $merged
}

# The user turned the automatic install on: remembered declines no longer apply.
function Clear-FastLlmUiDeclinedSetups {
    param([Parameter(Mandatory = $true)][string] $InstallRoot)
    $merged = Read-FastLlmComponentSettingsObject -InstallRoot $InstallRoot
    if (-not $merged.Contains('declinedSetups')) { return }
    $merged['declinedSetups'] = @()
    Write-FastLlmComponentSettingsObject -InstallRoot $InstallRoot -Merged $merged
}
