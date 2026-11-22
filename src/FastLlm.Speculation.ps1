# Loaded into FastLlm.psm1. The speculation option (-Speculation ngram|mtp): llama-server drafts tokens ahead and keeps the ones the model agrees
# with, which makes generation faster on some workloads. Off by default; with it off nothing in this file runs, no file is read and no field is
# added anywhere, and every start still passes --spec-type none.
#
# THIS RELEASE SHIPS NO MEASURED ROW, so on a real install every start with speculation is refused before anything is started. What this file pins:
#   - the add-on rows ("addOns" of the serving profiles file, kinds "ngram" and "mtp"), read by the loader in FastLlm.Vision.ps1 beside the vision
#     rows with the same rules as the serving profiles checker (tests/fixtures/speculation-addon-parity-cases.json is read by both);
#   - the closed per-engine allowlist below: for each pinned engine id, the --spec-type values and the extra argument NAMES a row may use. A row
#     outside it is refused by the checker and by the loader. Flag names differ between engine pins, so one list is never shared across engines;
#   - the planner, which needs a row of the asked kind for exactly the plan's model sha256, engine id and backend, and a value for the plan's
#     effective context profile id (a plan with no profile id has none);
#   - the argument shape: the none after --spec-type is replaced IN PLACE by the row's spec type and the row's extra arguments are appended;
#   - the start check, which an n-gram plan passes and an mtp plan never does: the draft component is not installed or fails its hash (a start
#     never downloads), and, always, speculation-evidence-unavailable (nothing can yet prove where the draft model is loaded);
#   - the counters read at stop for the run log's spec-summary event.
# Nothing here derives a fit, a size, a speed or a placement from a formula or a constant.

$script:FastLlmSpeculationModes = @('ngram', 'mtp')
$script:FastLlmSpeculationNone = 'none'
$script:FastLlmSpeculationDraftPlaceholder = '<verified-draft>'
$script:FastLlmSpeculationValuePattern = '^[0-9A-Za-z][0-9A-Za-z._:,]{0,31}\z'
$script:FastLlmSpeculationSpecTypePattern = '^[a-z0-9][a-z0-9-]{0,39}\z'

$script:FastLlmSpeculationNgramFlags = @('--spec-ngram-size-n', '--spec-ngram-size-m', '--spec-ngram-min-hits',
    '--spec-ngram-simple-size-n', '--spec-ngram-simple-size-m', '--spec-ngram-simple-min-hits',
    '--spec-ngram-map-k-size-n', '--spec-ngram-map-k-size-m', '--spec-ngram-map-k-min-hits',
    '--spec-ngram-map-k4v-size-n', '--spec-ngram-map-k4v-size-m', '--spec-ngram-map-k4v-min-hits',
    '--spec-ngram-mod-n-match', '--spec-ngram-mod-n-max', '--spec-ngram-mod-n-min')
$script:FastLlmSpeculationDraftFlags = @('--spec-draft-n-max', '--spec-draft-n-min', '--spec-draft-p-min')
# The metrics counters the summary reads, as the engine-surface fixture of each tag lists them.
$script:FastLlmSpeculationCounters = [pscustomobject] @{ draft = 'llamacpp:spec_decode_num_draft_tokens_total'; accepted = 'llamacpp:spec_decode_num_accepted_tokens_total' }

function New-FastLlmSpeculationAllowlistEntry {
    param([string[]] $NgramTypes = @(), [string[]] $MtpTypes = @(), [string[]] $Flags = @(), [string] $DraftModelFlag, $Counters)
    return [pscustomobject] [ordered] @{
        specTypes = [pscustomobject] [ordered] @{ ngram = [string[]] @($NgramTypes); mtp = [string[]] @($MtpTypes) }
        flags = [string[]] @($Flags)
        draftModelFlag = $(if ($DraftModelFlag) { $DraftModelFlag } else { $null })
        counters = $Counters
    }
}

# The allowlist, keyed by pinned engine id (the built-in Vulkan engine and each listed engine component). Every name is one the engine-surface
# fixture of that engine's tag lists (tests/speculation-tests.ps1 and tests/test_serving_profiles.py prove it). The HIP pin is the only one that has
# --spec-draft-n-ubatch and --spec-draft-sampling. The three HIP engine components are the same pin and share one entry.
function Get-FastLlmSpeculationAllowlist {
    $ngramTypes = @('ngram-simple', 'ngram-map-k', 'ngram-map-k4v', 'ngram-mod')
    $mtpTypes = @('draft-mtp')
    $vulkan = New-FastLlmSpeculationAllowlistEntry -NgramTypes $ngramTypes -MtpTypes $mtpTypes -Flags @($script:FastLlmSpeculationNgramFlags + $script:FastLlmSpeculationDraftFlags) -DraftModelFlag '--spec-draft-model' -Counters $script:FastLlmSpeculationCounters
    $hipFlags = @($script:FastLlmSpeculationNgramFlags + $script:FastLlmSpeculationDraftFlags + @('--spec-draft-n-ubatch', '--spec-draft-sampling'))
    $hip = { New-FastLlmSpeculationAllowlistEntry -NgramTypes $ngramTypes -MtpTypes $mtpTypes -Flags $hipFlags -DraftModelFlag '--spec-draft-model' -Counters $script:FastLlmSpeculationCounters }
    return @{
        'llama.cpp-b10698-vulkan'      = $vulkan
        'llama.cpp-hip-b11658'         = (& $hip)
        'llama.cpp-hip-b11658-gfx1201' = (& $hip)
        'llama.cpp-hip-b11658-gfx1200' = (& $hip)
    }
}

# The entry of an engine id; an engine id that is not pinned has an EMPTY entry (nothing is allowed).
function Get-FastLlmSpeculationAllowlistEntry {
    param([AllowEmptyString()][string] $EngineId)
    $table = Get-FastLlmSpeculationAllowlist
    # Exact, like the checker: a PowerShell hashtable ignores case, so the key is compared on its own first.
    if ($EngineId -and @($table.Keys) -ccontains $EngineId) { return $table[$EngineId] }
    return (New-FastLlmSpeculationAllowlistEntry)
}

# The shape rules of a row's specType and extraArguments, the same as the checker's. Returns $null when valid, or the detail of the first problem.
# extraArguments is a list of strings: flags (--name) from the engine's allowlist, each followed by at most one plain value, no flag twice, the
# first element a flag. A value is 1-32 characters of letters, digits, dots, dashes, colons and commas and never starts with a dash or is a path.
function Test-FastLlmSpeculationRow {
    param([string] $Kind, [string] $EngineId, $SpecType, $ExtraArguments)
    $entry = Get-FastLlmSpeculationAllowlistEntry -EngineId $EngineId
    $allowedTypes = @()
    if ($Kind -ceq 'ngram') { $allowedTypes = @($entry.specTypes.ngram) } elseif ($Kind -ceq 'mtp') { $allowedTypes = @($entry.specTypes.mtp) }
    if (-not ($SpecType -is [string]) -or $allowedTypes -cnotcontains $SpecType) { return 'specType is not allowed for this kind and engine' }
    if ($null -eq $ExtraArguments -or $ExtraArguments -isnot [array]) { return 'extraArguments must be a list of strings' }
    foreach ($argument in @($ExtraArguments)) { if (-not ($argument -is [string])) { return 'extraArguments must be a list of strings' } }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $previousWasFlag = $false
    $index = 0
    foreach ($argument in @($ExtraArguments)) {
        $text = [string] $argument
        if ($text.StartsWith('--', [StringComparison]::Ordinal)) {
            if (@($entry.flags) -cnotcontains $text) { return 'an extraArguments flag is not allowed for this engine' }
            if (-not $seen.Add($text)) { return 'extraArguments names a flag twice' }
            $previousWasFlag = $true
        }
        else {
            if ($index -eq 0) { return 'extraArguments must start with a flag' }
            if (-not $previousWasFlag) { return 'extraArguments gives a flag more than one value' }
            if ($text -cnotmatch $script:FastLlmSpeculationValuePattern) { return 'an extraArguments value is not a short plain value' }
            $previousWasFlag = $false
        }
        $index++
    }
    return $null
}

# The one add-on row of the asked kind whose model sha256, engine id AND backend equal the plan's, or $null. (The rows are already unique by that key.)
function Find-FastLlmSpeculationAddOn {
    param([object[]] $Rows, [Parameter(Mandatory = $true)][string] $Kind, [Parameter(Mandatory = $true)] $Model, [string] $EngineId, [string] $Backend)
    $modelSha = ([string] $Model.sha256).ToLowerInvariant()
    foreach ($row in @($Rows)) {
        if ($null -eq $row) { continue }
        if ([string] $row.kind -cne $Kind) { continue }
        if ([string] $row.modelSha256 -cne $modelSha) { continue }
        if ([string] $row.engineId -cne $EngineId) { continue }
        if ([string] $row.backend -cne $Backend) { continue }
        return $row
    }
    return $null
}

# The server arguments with the none after --spec-type replaced IN PLACE by the row's spec type, then (an mtp plan) --spec-draft-model and the draft
# path, then the row's extra arguments, all appended at the end in row order. Exactly one --spec-type must be there, followed by none: with another
# shape the arguments are not the ones this function knows how to change, and nothing is appended. The draft path is one element: it reaches the
# process through Join-FastLlmProcessArguments, the one helper that also passes --model, which quotes a path with a space as one argument.
function Get-FastLlmSpeculationArguments {
    param([Parameter(Mandatory = $true)][string[]] $Arguments, [Parameter(Mandatory = $true)] $Speculation, [string] $DraftPath)
    $found = 0
    $at = -1
    $list = @($Arguments)
    for ($i = 0; $i -lt $list.Count; $i++) { if ([string] $list[$i] -ceq '--spec-type') { $found++; $at = $i } }
    if ($found -ne 1) { throw "The server arguments must have exactly one --spec-type to change; they have $found." }
    if ($at + 1 -ge $list.Count -or [string] $list[$at + 1] -cne $script:FastLlmSpeculationNone) { throw "The server arguments must have $($script:FastLlmSpeculationNone) after --spec-type to replace it." }
    $mode = [string] $Speculation.mode
    $result = New-Object 'System.Collections.Generic.List[string]'
    for ($i = 0; $i -lt $list.Count; $i++) {
        if ($i -eq $at + 1) { $result.Add([string] $Speculation.specType) } else { $result.Add([string] $list[$i]) }
    }
    if ($mode -ceq 'mtp') {
        $entry = Get-FastLlmSpeculationAllowlistEntry -EngineId ([string] $Speculation.engineId)
        if (-not $entry.draftModelFlag) { throw 'No draft model flag is allowed for this engine, so the arguments were not changed.' }
        if ([string]::IsNullOrWhiteSpace($DraftPath)) { throw 'The draft file path is empty, so the arguments were not changed.' }
        $result.Add([string] $entry.draftModelFlag)
        $result.Add($DraftPath)
    }
    foreach ($argument in @($Speculation.extraArguments)) { $result.Add([string] $argument) }
    return $result.ToArray()
}

# The speculation block of a plan as checked values, or $null for a plan without one. A block outside the closed values (mode, a spec type and extra
# arguments the engine's allowlist allows) is the typed failure speculation-invalid: such a plan is never started. No reason is set, so nothing
# retries, re-plans or recovers on it.
function Get-FastLlmPlanSpeculation {
    param($Plan)
    if ($null -eq $Plan -or -not $Plan.PSObject.Properties['speculation'] -or $null -eq $Plan.speculation) { return $null }
    $block = $Plan.speculation
    $read = { param($Name) if ($block -is [pscustomobject] -and $block.PSObject.Properties[$Name]) { return $block.PSObject.Properties[$Name].Value }; return $null }
    $mode = & $read 'mode'
    $specType = & $read 'specType'
    $engineId = & $read 'engineId'
    $extra = & $read 'extraArguments'
    $resultId = & $read 'resultId'
    $blockBackend = & $read 'backend'
    $blockSha = & $read 'modelSha256'
    $valid = ($mode -is [string]) -and ($script:FastLlmSpeculationModes -ccontains $mode) -and ($engineId -is [string]) -and ($specType -is [string]) -and
        ($specType -cmatch $script:FastLlmSpeculationSpecTypePattern)
    if ($valid) {
        $extraList = @(); if ($null -ne $extra) { $extraList = @($extra) }
        $valid = ($null -eq (Test-FastLlmSpeculationRow -Kind $mode -EngineId $engineId -SpecType $specType -ExtraArguments $extraList)) -and
            ($null -eq $resultId -or ($resultId -is [string] -and $resultId -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,119}\z'))
    }
    # The block is the plan's own: its model sha256, backend and engine id are the plan's (so a block cannot be moved onto another plan).
    if ($valid) {
        $valid = ($blockBackend -is [string]) -and ($blockSha -is [string]) -and ($blockSha -cmatch '^[0-9a-f]{64}\z')
    }
    if ($valid) {
        $planSha = $null
        if ($Plan.PSObject.Properties['model'] -and $Plan.model -and $Plan.model.PSObject.Properties['sha256']) { $planSha = ([string] $Plan.model.sha256).ToLowerInvariant() }
        if ($null -ne $planSha -and $planSha -cne $blockSha) { $valid = $false }
        $planBackend = $null
        if ($Plan.PSObject.Properties['backend'] -and $null -ne $Plan.backend) { $planBackend = ([string] $Plan.backend).ToLowerInvariant() }
        if ($null -ne $planBackend -and $planBackend -cne $blockBackend) { $valid = $false }
        $expectedEngineId = $null
        if ($Plan.PSObject.Properties['engineComponentId'] -and $Plan.engineComponentId) { $expectedEngineId = [string] $Plan.engineComponentId }
        elseif ($Plan.PSObject.Properties['engineVersion'] -and $Plan.engineVersion -and $null -ne $planBackend) { $expectedEngineId = 'llama.cpp-' + [string] $Plan.engineVersion + '-' + $planBackend }
        if ($null -ne $expectedEngineId -and $expectedEngineId -cne [string] $engineId) { $valid = $false }
    }
    if (-not $valid) {
        throw (New-FastLlmTypedFailure -Code 'speculation-invalid' -Message 'The plan carries a speculation setting that FastLLM does not allow for this engine. Nothing was started; plan again.')
    }
    $extraChecked = @(); if ($null -ne $extra) { $extraChecked = @($extra | ForEach-Object { [string] $_ }) }
    $componentId = & $read 'componentId'
    return [pscustomobject] [ordered] @{
        mode = [string] $mode; specType = [string] $specType; engineId = [string] $engineId; extraArguments = [string[]] $extraChecked
        resultId = $(if ($resultId -is [string]) { [string] $resultId } else { $null }); componentId = $(if ($componentId -is [string]) { [string] $componentId } else { $null })
    }
}

# A start with speculation. Called by the CLI start right after the plan (before any model download) and again at the top of Start-FastLlmServer, so
# no caller can start a speculation plan that has not passed it. A plan without a speculation block is not touched: this returns at once. The checks,
# in this order, none of which starts a process, probes hardware, downloads or writes a file:
#   0. the block is a checked one and the planned arguments carry exactly its spec type (speculation-invalid);
#   an n-gram plan is startable: it has no file and nothing else to check here;
#   4. an mtp plan: the draft component is listed, installed and its license accepted (needs-setup-component-missing: a start never downloads);
#   4. its files equal their pinned sizes and SHA-256 (the same code: the component failed its file check);
#   5. speculation-evidence-unavailable, ALWAYS: nothing can yet prove where the draft model is loaded (on the GPU or on the CPU), so a start with a
#      draft file cannot be verified.
# (1, 2 and 3, no row, no value for the profile and a refused combination, are the planner's: the plan is never made.)
function Assert-FastLlmSpeculationStartable {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Plan, [Parameter(Mandatory = $true)][string] $CatalogPath, [Parameter(Mandatory = $true)][string] $InstallRoot, [string] $ComponentsPath)
    $block = Get-FastLlmPlanSpeculation -Plan $Plan
    if ($null -eq $block) { return }
    $specTypeCount = 0
    $arguments = @(); if ($Plan.PSObject.Properties['serverArguments'] -and $null -ne $Plan.serverArguments) { $arguments = @($Plan.serverArguments | ForEach-Object { [string] $_ }) }
    for ($i = 0; $i -lt $arguments.Count; $i++) {
        if ($arguments[$i] -ceq '--spec-type') { $specTypeCount++; if ($i + 1 -ge $arguments.Count -or $arguments[$i + 1] -cne [string] $block.specType) { $specTypeCount = 99 } }
    }
    if ($specTypeCount -ne 1) {
        throw (New-FastLlmTypedFailure -Code 'speculation-invalid' -Message 'The plan''s arguments do not carry the speculation setting it names. Nothing was started; plan again.')
    }
    if ([string] $block.mode -cne 'mtp') { return }
    $componentId = ''
    if ($block.componentId) { $componentId = [string] $block.componentId }
    if (-not $ComponentsPath) { $ComponentsPath = Join-Path (Split-Path -Parent $CatalogPath) 'components.json' }
    $component = $null
    if ($componentId -and (Test-Path -LiteralPath $ComponentsPath -PathType Leaf)) {
        $component = @(Get-FastLlmComponents -ComponentsPath $ComponentsPath | Where-Object { [string] $_.id -ceq $componentId -and [string] $_.kind -ceq 'draft' }) | Select-Object -First 1
    }
    if ($null -eq $component) {
        throw (New-FastLlmComponentUnavailableFailure -EngineId $componentId -UnavailableId $componentId -Message "The speculation draft component '$componentId' is not listed in the signed components list, so -Speculation mtp cannot be used. A start never installs components. Nothing was started. To start without speculation, leave -Speculation off.")
    }
    if (-not (Test-FastLlmComponentInstallation -InstallRoot $InstallRoot -Component $component -Depth Presence) -or -not (Test-FastLlmComponentConsentReceipt -Component $component -InstallRoot $InstallRoot)) {
        throw (New-FastLlmComponentUnavailableFailure -EngineId $componentId -UnavailableId $componentId -Message "The speculation draft file '$componentId' is not installed (or its license was not accepted). A start never installs components; run the install action first: fast-llm.ps1 components -Install $componentId. Nothing was started.")
    }
    if (-not (Test-FastLlmComponentVerifiedFull -InstallRoot $InstallRoot -Component $component)) {
        throw (New-FastLlmComponentUnavailableFailure -EngineId $componentId -UnavailableId $componentId -Message "The speculation draft file '$componentId' failed its file check: a file differs from its pinned size or SHA-256. Nothing was started. Remove it and install it again: fast-llm.ps1 components -Remove $componentId")
    }
    throw (New-FastLlmTypedFailure -Code 'speculation-evidence-unavailable' -Message 'Speculation with a draft file cannot be verified yet: FastLLM has no way yet to prove where the draft model is loaded (on the GPU or on the CPU), so a start with -Speculation mtp is not offered in this release. Nothing was started. To start without speculation, leave -Speculation off.')
}

# The two counters of a /metrics text, by the names pinned for the engine ($Counters is the allowlist entry's counters; $null for an engine with
# none). A counter that is missing, not a number, negative, or not a whole number is $null, never 0. Only these two names are ever taken.
function Get-FastLlmSpeculationCounters {
    param([AllowEmptyString()][string] $MetricsText, $Counters)
    $result = [pscustomobject] [ordered] @{ draftTokens = $null; acceptedTokens = $null }
    if ($null -eq $Counters -or [string]::IsNullOrEmpty($MetricsText)) { return $result }
    $take = {
        param([string] $Name)
        $pattern = '(?m)^' + [regex]::Escape($Name) + '(?:\{[^}\r\n]*\})?[ \t]+([0-9]+(?:\.[0-9]+)?(?:[eE]\+?[0-9]+)?)[ \t]*\r?$'
        $found = [regex]::Matches($MetricsText, $pattern)
        if ($found.Count -ne 1) { return $null }
        $number = 0.0
        if (-not [double]::TryParse($found[0].Groups[1].Value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref] $number)) { return $null }
        if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt 0 -or $number -ne [Math]::Floor($number) -or $number -gt 9007199254740991) { return $null }
        return [long] $number
    }
    $result.draftTokens = & $take ([string] $Counters.draft)
    $result.acceptedTokens = & $take ([string] $Counters.accepted)
    return $result
}
