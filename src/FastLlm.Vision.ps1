# Loaded into FastLlm.psm1. The vision option (-Vision on): llama-server reads images when it is given a projector file (--mmproj). Off by default;
# with it off nothing in this file runs, no file is read and no field is added anywhere, and every start still passes --no-mmproj.
#
# THIS RELEASE OFFERS NO START WITH VISION. Every vision start ends in a typed refusal before anything is started. A real start needs three things
# that do not exist yet: a measured add-on row, an approved projector component, and a check that proves where the projector was loaded (on the
# GPU or on the CPU). This file pins what the option is made of and how it fails closed:
#   - the add-on rows of the serving profiles file ("addOns", kind "vision"), read by the loader below with the same rules as
#     the serving profiles checker (tests/fixtures/vision-addon-parity-cases.json is read by both);
#   - the planner, which needs a row for exactly the plan's model sha256, engine id and backend, and a value for the plan's effective context
#     profile id (the free memory the projector adds to that profile's requirement; a plan with no profile id has none);
#   - the argument shape: --no-mmproj is replaced IN PLACE by --mmproj <path>;
#   - the start check below, which refuses in this order: the projector component is not installed (a start never downloads), its files differ
#     from the pinned hashes, and, always, vision-evidence-unavailable.
# Nothing here derives a fit, a size or a placement from a formula or a constant.

$script:FastLlmVisionAddOnKind = 'vision'
$script:FastLlmVisionAddOnKeys = @('kind', 'modelId', 'modelSha256', 'engineId', 'backend', 'componentId', 'extraFreeVramMiB', 'evidence')
$script:FastLlmVisionEvidenceKeys = @('resultId', 'measuredAt', 'gpuClasses')
$script:FastLlmVisionBackends = @('vulkan', 'hip')
$script:FastLlmVisionProjectorPlaceholder = '<verified-projector>'
$script:FastLlmVisionNoMmproj = '--no-mmproj'

function New-FastLlmVisionAddOnsInvalid {
    param([Parameter(Mandatory = $true)][string] $Detail)
    return (New-FastLlmServingProfilesFailure -Detail ('The serving profiles file has a vision add-on row that is not valid (' + $Detail + '), so vision cannot be used. Nothing was started.'))
}

# True for a closed key set: every expected key is there (exact case) and nothing else is.
function Test-FastLlmVisionClosedKeys {
    param($Row, [Parameter(Mandatory = $true)][string[]] $Expected)
    if ($null -eq $Row -or $Row -isnot [pscustomobject]) { return $false }
    $names = @($Row.PSObject.Properties | ForEach-Object { [string] $_.Name })
    foreach ($key in $Expected) { if ($names -cnotcontains $key) { return $false } }
    foreach ($name in $names) { if ($Expected -cnotcontains $name) { return $false } }
    return $true
}

# The add-on rows of the serving profiles file, validated with the rules of the checker (closed keys, kind vision only, whole positive MiB per
# known profile id, evidence, no duplicate key). No path, or a path with no file, is no rows (every vision plan is then refused as not measured).
# A file that cannot be read, has another schema, or has a row the checker would refuse is a typed failure: vision is never honoured, and never
# silently dropped, from a file that cannot be trusted. The list is returned as a list (a one-row file is still a list).
function Read-FastLlmVisionAddOns {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $document = $null
    try { $document = Read-FastLlmJson -Path $Path -MaxBytes $script:FastLlmServingProfilesMaxBytes }
    catch { throw (New-FastLlmServingProfilesFailure -Detail 'The serving profiles file could not be read as JSON, so vision cannot be used.') }
    $schema = Get-FastLlmServingProfileValue -Row $document -Name 'schema'
    $rowsProperty = $null
    if ($document -is [pscustomobject]) { $rowsProperty = $document.PSObject.Properties['addOns'] }
    if (-not ($schema -is [string]) -or $schema -cne $script:FastLlmServingProfilesSchema -or $null -eq $rowsProperty -or -not ($rowsProperty.Value -is [array])) {
        throw (New-FastLlmServingProfilesFailure -Detail 'The serving profiles file has an unexpected schema, so vision cannot be used.')
    }
    $rawText = ''
    try { $rawText = [System.IO.File]::ReadAllText($Path) } catch { throw (New-FastLlmServingProfilesFailure -Detail 'The serving profiles file could not be read as JSON, so vision cannot be used.') }
    $isWhole = { param($Value) return [bool] ($Value -is [int] -or $Value -is [long]) }
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($row in @($rowsProperty.Value)) {
        if (-not (Test-FastLlmVisionClosedKeys -Row $row -Expected $script:FastLlmVisionAddOnKeys)) { throw (New-FastLlmVisionAddOnsInvalid -Detail 'a row is not an object with exactly the add-on keys') }
        $kind = $row.kind
        if (-not ($kind -is [string]) -or $kind -cne $script:FastLlmVisionAddOnKind) { throw (New-FastLlmVisionAddOnsInvalid -Detail "kind must be 'vision'; other kinds are not accepted yet") }
        $sha = $row.modelSha256
        if (-not ($sha -is [string]) -or $sha -cnotmatch '^[0-9a-f]{64}\z') { throw (New-FastLlmVisionAddOnsInvalid -Detail 'modelSha256 must be 64 lowercase hex characters') }
        foreach ($textKey in @('modelId', 'engineId', 'componentId')) {
            $textValue = $row.PSObject.Properties[$textKey].Value
            if (-not ($textValue -is [string]) -or $textValue -ceq '') { throw (New-FastLlmVisionAddOnsInvalid -Detail "$textKey must be a non-empty string") }
        }
        $backend = $row.backend
        if (-not ($backend -is [string]) -or $script:FastLlmVisionBackends -cnotcontains $backend) { throw (New-FastLlmVisionAddOnsInvalid -Detail 'backend must be vulkan or hip') }
        $extra = $row.extraFreeVramMiB
        if ($extra -isnot [pscustomobject] -or @($extra.PSObject.Properties).Count -eq 0) { throw (New-FastLlmVisionAddOnsInvalid -Detail 'extraFreeVramMiB must be a non-empty object of profile id to MiB') }
        $extraById = @{}
        foreach ($extraProperty in @($extra.PSObject.Properties)) {
            $profileId = [string] $extraProperty.Name
            if ($script:FastLlmServingProfileIds -cnotcontains $profileId) { throw (New-FastLlmVisionAddOnsInvalid -Detail 'extraFreeVramMiB has a profile id that is not default or long') }
            if (-not (& $isWhole $extraProperty.Value) -or [long] $extraProperty.Value -le 0) { throw (New-FastLlmVisionAddOnsInvalid -Detail 'extraFreeVramMiB must be a positive whole number of MiB per profile id') }
            $extraById[$profileId] = [int64] $extraProperty.Value
        }
        $evidence = $row.evidence
        if (-not (Test-FastLlmVisionClosedKeys -Row $evidence -Expected $script:FastLlmVisionEvidenceKeys)) { throw (New-FastLlmVisionAddOnsInvalid -Detail 'evidence must be an object with exactly resultId, measuredAt and gpuClasses') }
        if (-not ($evidence.resultId -is [string]) -or $evidence.resultId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,119}\z') { throw (New-FastLlmVisionAddOnsInvalid -Detail 'evidence.resultId is not a result id') }
        $measuredAt = $evidence.measuredAt
        $measuredOk = $false
        # PowerShell 7 turns a date-like string into a DateTime when it reads JSON; the checker saw the text. A DateTime is accepted only when it is
        # UTC, whole seconds, and its exact text is in the file, which is what the text rule says.
        if ($measuredAt -is [datetime] -and $measuredAt.Kind -eq [System.DateTimeKind]::Utc -and ($measuredAt.Ticks % [int64] 10000000) -eq 0) {
            $measuredText = $measuredAt.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
            if ($rawText.Contains('"' + $measuredText + '"')) { $measuredAt = $measuredText }
        }
        if ($measuredAt -is [string] -and $measuredAt -cmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z') {
            $parsed = [datetime]::MinValue
            $measuredOk = [datetime]::TryParseExact($measuredAt, "yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref] $parsed)
        }
        if (-not $measuredOk) { throw (New-FastLlmVisionAddOnsInvalid -Detail 'evidence.measuredAt is not a UTC time like 2026-01-31T12:00:00Z') }
        $classes = $evidence.gpuClasses
        if (-not ($classes -is [array]) -or @($classes).Count -eq 0) { throw (New-FastLlmVisionAddOnsInvalid -Detail 'evidence.gpuClasses must be a non-empty list of short names') }
        foreach ($class in @($classes)) {
            if (-not ($class -is [string]) -or $class -cnotmatch '^[A-Za-z0-9][A-Za-z0-9 ._-]{0,79}\z') { throw (New-FastLlmVisionAddOnsInvalid -Detail 'evidence.gpuClasses must be a non-empty list of short names') }
        }
        $key = $kind + '|' + $sha + '|' + [string] $row.engineId + '|' + $backend
        if (-not $seen.Add($key)) { throw (New-FastLlmVisionAddOnsInvalid -Detail 'two rows have the same kind, model, engine and backend') }
        $rows.Add([pscustomobject] [ordered] @{
                modelId = [string] $row.modelId; modelSha256 = [string] $sha; engineId = [string] $row.engineId; backend = [string] $backend
                componentId = [string] $row.componentId; extraFreeVramMiB = $extraById; resultId = [string] $evidence.resultId })
    }
    return $rows.ToArray()
}

# The one add-on row whose model sha256, engine id AND backend equal the plan's, or $null. (The rows are already unique by that key.)
function Find-FastLlmVisionAddOn {
    param([object[]] $Rows, [Parameter(Mandatory = $true)] $Model, [string] $EngineId, [string] $Backend)
    $modelSha = ([string] $Model.sha256).ToLowerInvariant()
    foreach ($row in @($Rows)) {
        if ($null -eq $row) { continue }
        if ([string] $row.modelSha256 -cne $modelSha) { continue }
        if ([string] $row.engineId -cne $EngineId) { continue }
        if ([string] $row.backend -cne $Backend) { continue }
        return $row
    }
    return $null
}

# The server arguments with the --no-mmproj element replaced IN PLACE by --mmproj and the projector path. No other element moves or changes.
# Exactly one --no-mmproj must be there: with none (or two) the arguments are not the ones this function knows how to change, and nothing is appended.
# The path is one element: it reaches the process through Join-FastLlmProcessArguments, the one helper that also passes --model, which quotes a
# path with a space as one argument.
function Get-FastLlmVisionArguments {
    param([Parameter(Mandatory = $true)][string[]] $Arguments, [Parameter(Mandatory = $true)][AllowEmptyString()][string] $ProjectorPath)
    if ([string]::IsNullOrWhiteSpace($ProjectorPath)) { throw 'The vision projector path is empty, so the arguments were not changed.' }
    $found = 0
    foreach ($argument in @($Arguments)) { if ([string] $argument -ceq $script:FastLlmVisionNoMmproj) { $found++ } }
    if ($found -ne 1) { throw "The server arguments must have exactly one $($script:FastLlmVisionNoMmproj) to replace; they have $found." }
    $result = New-Object 'System.Collections.Generic.List[string]'
    foreach ($argument in @($Arguments)) {
        if ([string] $argument -ceq $script:FastLlmVisionNoMmproj) { $result.Add('--mmproj'); $result.Add($ProjectorPath) }
        else { $result.Add([string] $argument) }
    }
    return $result.ToArray()
}

# A start with vision, whatever the plan says, ends here. Called by the CLI start right after the plan (before any model download) and again at
# the top of Start-FastLlmServer, so no caller can start a vision plan. A plan without a vision block is not touched: this returns at once.
# The checks, in this order, none of which starts a process, probes hardware, downloads or writes a file:
#   4. the projector component is listed, installed and its license accepted (needs-setup-component-missing: a start never downloads);
#   5. every projector file equals its pinned size and SHA-256 (the same code: the component failed its file check);
#   6. vision-evidence-unavailable, ALWAYS: nothing can yet prove where the projector is loaded, so a start with vision cannot be verified.
# (1 and 2, no matching row and no value for the profile, are the planner's: the plan is never made.) The pinned hash is the component's own
# fileManifest; the model it belongs to is the add-on row's modelSha256 + componentId, which the planner matched.
# #60 (context profile, slots) has no HIP rule of its own, so none is invented here: a vision row is bound to an engine and backend like every
# opt-in row, and a plan on another backend finds no row.
function Assert-FastLlmVisionStartable {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Plan, [Parameter(Mandatory = $true)][string] $CatalogPath, [Parameter(Mandatory = $true)][string] $InstallRoot, [string] $ComponentsPath)
    if ($null -eq $Plan -or -not $Plan.PSObject.Properties['vision'] -or $null -eq $Plan.vision) { return }
    $componentId = ''
    if ($Plan.vision.PSObject.Properties['componentId'] -and $Plan.vision.componentId -is [string]) { $componentId = [string] $Plan.vision.componentId }
    if (-not $ComponentsPath) { $ComponentsPath = Join-Path (Split-Path -Parent $CatalogPath) 'components.json' }
    $component = $null
    if ($componentId -and (Test-Path -LiteralPath $ComponentsPath -PathType Leaf)) {
        $component = @(Get-FastLlmComponents -ComponentsPath $ComponentsPath | Where-Object { [string] $_.id -ceq $componentId -and [string] $_.kind -ceq 'projector' }) | Select-Object -First 1
    }
    if ($null -eq $component) {
        throw (New-FastLlmComponentUnavailableFailure -EngineId $componentId -UnavailableId $componentId -Message "The vision projector component '$componentId' is not listed in the signed components list, so vision cannot be used. A start never installs components. Nothing was started. To start without vision, leave -Vision off.")
    }
    if (-not (Test-FastLlmComponentInstallation -InstallRoot $InstallRoot -Component $component -Depth Presence) -or -not (Test-FastLlmComponentConsentReceipt -Component $component -InstallRoot $InstallRoot)) {
        throw (New-FastLlmComponentUnavailableFailure -EngineId $componentId -UnavailableId $componentId -Message "The vision projector '$componentId' is not installed (or its license was not accepted). A start never installs components; run the install action first: fast-llm.ps1 components -Install $componentId. Nothing was started.")
    }
    if (-not (Test-FastLlmComponentVerifiedFull -InstallRoot $InstallRoot -Component $component)) {
        throw (New-FastLlmComponentUnavailableFailure -EngineId $componentId -UnavailableId $componentId -Message "The vision projector '$componentId' failed its file check: a file differs from its pinned size or SHA-256. Nothing was started. Remove it and install it again: fast-llm.ps1 components -Remove $componentId")
    }
    throw (New-FastLlmTypedFailure -Code 'vision-evidence-unavailable' -Message 'Vision cannot be verified yet: FastLLM has no way yet to prove where the vision projector is loaded (on the GPU or on the CPU), so a start with vision is not offered in this release. Nothing was started. To start without vision, leave -Vision off.')
}
