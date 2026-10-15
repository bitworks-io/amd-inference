# Pure transition and exact-provenance helpers shared by the control window and
# its CLI child. No native process, UI, network, or filesystem work occurs here.
Set-StrictMode -Version 2

function Get-FastLlmUiModelProvenanceDigest {
    param([Parameter(Mandatory=$true)]$Model)
    $fields = @('id','upstreamModel','upstreamRevision','upstreamLicense',
        'upstreamLicenseSha256','upstreamLicenseUrl','repository','revision',
        'artifactLicense','artifactProvider','license','artifactLicenseMetadataUrl',
        'sha256','sizeBytes','url','file','servingMode')
    $body = New-Object System.Text.StringBuilder
    [void]$body.Append("fastllm-ui-model-provenance-v1`n")
    foreach ($field in $fields) {
        $property = $Model.PSObject.Properties[$field]
        if (-not $property -or $null -eq $property.Value) {
            throw "Model provenance is missing '$field'."
        }
        $value = if ($field -eq 'sizeBytes') {
            ([int64]$property.Value).ToString([Globalization.CultureInfo]::InvariantCulture)
        } else { [string]$property.Value }
        if ([string]::IsNullOrWhiteSpace($value)) { throw "Model provenance is empty at '$field'." }
        [void]$body.Append($field).Append(':').Append(([Text.Encoding]::UTF8.GetByteCount($value)).ToString([Globalization.CultureInfo]::InvariantCulture)).Append(':').Append($value).Append("`n")
    }
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($body.ToString())))).Replace('-','').ToLowerInvariant()
    } finally { $hash.Dispose() }
}

function Assert-FastLlmUiExpectedProvenance {
    param([Parameter(Mandatory=$true)]$Model,
          [Parameter(Mandatory=$true)][string]$ExpectedSha256)
    if ($ExpectedSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        (Get-FastLlmUiModelProvenanceDigest -Model $Model) -cne $ExpectedSha256) {
        throw 'The selected model provenance changed after license review. No new consent or model acquisition was attempted.'
    }
}

function Get-FastLlmUiPlanIdentity {
    param([Parameter(Mandatory=$true)]$Plan)
    $digest = Get-FastLlmUiModelProvenanceDigest -Model $Plan.model
    $devices = @($Plan.selectedAdapters | ForEach-Object { [string]$_.device }) -join ','
    return "$digest|$([string]$Plan.hardwareFingerprint)|$devices|$([int]$Plan.model.contextSize)"
}

function Format-FastLlmUiModelConsent {
    param([Parameter(Mandatory=$true)]$Plan)
    if (-not $Plan.PSObject.Properties['model'] -or $null -eq $Plan.model) {
        throw 'A selected model is required for license review.'
    }
    $m=$Plan.model
    $digest=Get-FastLlmUiModelProvenanceDigest -Model $m
    $displayFields=@('id','upstreamModel','upstreamRevision','upstreamLicense',
        'upstreamLicenseUrl','upstreamLicenseSha256','repository','revision',
        'artifactLicense','artifactProvider','license','artifactLicenseMetadataUrl',
        'url','sha256','file','servingMode')
    foreach($field in $displayFields){
        $value=[string]$m.$field
        if($value.Length -gt 4096 -or $value -match '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]') {
            throw "Model provenance '$field' cannot be displayed safely for consent."
        }
    }
    if(-not $m.PSObject.Properties['contextSize'] -or
        ($m.contextSize -isnot [int] -and $m.contextSize -isnot [long]) -or
        [long]$m.contextSize -lt 1 -or [long]$m.contextSize -gt 1048576) {
        throw 'The selected model has no valid context size for license review.'
    }
    $bytes=[long]$m.sizeBytes
    if($bytes -le 0){throw 'The selected artifact has no valid byte size for license review.'}
    $sizeGiB=([Math]::Round($bytes/1GB,2)).ToString('0.00',[Globalization.CultureInfo]::InvariantCulture)
    $body=@(
        'Review this exact model and conversion before downloading.'
        ''
        "Selected model ID: $($m.id)"
        "Context: $($m.contextSize) tokens"
        "Artifact size: $bytes bytes ($sizeGiB GiB)"
        ''
        "Upstream model: $($m.upstreamModel)"
        "Upstream revision: $($m.upstreamRevision)"
        "Upstream license: $($m.upstreamLicense)"
        "Upstream license URL: $($m.upstreamLicenseUrl)"
        "Upstream license SHA-256: $($m.upstreamLicenseSha256)"
        ''
        "Conversion repository: $($m.repository)"
        "Conversion revision: $($m.revision)"
        "Conversion provider: $($m.artifactProvider)"
        "Conversion license label: $($m.license)"
        "Artifact license: $($m.artifactLicense)"
        "Conversion license metadata URL: $($m.artifactLicenseMetadataUrl)"
        ''
        "Artifact file: $($m.file)"
        "Artifact URL: $($m.url)"
        "Artifact SHA-256: $($m.sha256)"
        "Serving mode: $($m.servingMode)"
        ''
        "Exact review binding SHA-256: $digest"
        ''
        'Accepting authorizes the download of this exact artifact only.'
    ) -join "`r`n"
    if($body.Length -gt 16384){throw 'Model provenance exceeds the license review display limit.'}
    return $body
}

function New-FastLlmUiTrayState {
    return [pscustomobject]@{ visibility='window'; iconReady=$false; closed=$false }
}

function Move-FastLlmUiTrayState {
    param([Parameter(Mandatory=$true)]$State,
          [Parameter(Mandatory=$true)][ValidateSet('icon-ready','minimize','restore','close')][string]$Event)
    if ($State.closed) { throw 'The control window has already closed.' }
    switch ($Event) {
        'icon-ready' {
            if ($State.visibility -ne 'window') { throw 'A hidden window cannot create its first tray icon.' }
            $State.iconReady=$true
        }
        'minimize' {
            if (-not $State.iconReady -or $State.visibility -ne 'window') {
                throw 'Minimize requires a visible window and a working tray icon.'
            }
            $State.visibility='tray'
        }
        'restore' {
            if ($State.visibility -ne 'tray') { throw 'The control window is not in the tray.' }
            $State.visibility='window'
        }
        'close' { $State.visibility='closed'; $State.closed=$true }
    }
    return $State
}

function Get-FastLlmUiSetupDecision {
    param([Parameter(Mandatory=$true)]$Diagnostic, [ValidateSet(0,2)][int]$ExitCode)
    if ($null -eq $Diagnostic -or $Diagnostic -is [array] -or
        $Diagnostic.PSObject.Properties['windows'] -eq $null -or $Diagnostic.windows -isnot [bool] -or -not $Diagnostic.windows -or
        $Diagnostic.PSObject.Properties['vulkanVerified'] -eq $null -or $Diagnostic.vulkanVerified -isnot [bool] -or
        $Diagnostic.PSObject.Properties['windowsPrerequisites'] -eq $null -or $null -eq $Diagnostic.windowsPrerequisites -or
        $Diagnostic.PSObject.Properties['error'] -eq $null) {
        throw 'The setup check returned an incomplete Windows diagnostic.'
    }
    $p=$Diagnostic.windowsPrerequisites
    foreach ($name in @('applicable','ready','is64BitProcess','vulkanLoaderPresent')) {
        $field=$p.PSObject.Properties[$name]
        if (-not $field -or $field.Value -isnot [bool]) { throw "The setup check is missing a valid '$name' value." }
    }
    if (-not $p.applicable -or -not $p.PSObject.Properties['missingVcRuntimeFiles'] -or
        $null -eq $p.missingVcRuntimeFiles -or $p.missingVcRuntimeFiles -isnot [array]) {
        throw 'The setup check returned incomplete prerequisite details.'
    }
    $missing=@($p.missingVcRuntimeFiles)
    $expected=@('MSVCP140.dll','VCRUNTIME140.dll','VCRUNTIME140_1.dll')
    if ($missing.Count -gt 3 -or @($missing | Where-Object { $_ -isnot [string] -or $_ -cnotin $expected }).Count -gt 0 -or
        @($missing | Select-Object -Unique).Count -ne $missing.Count) {
        throw 'The setup check returned invalid runtime file details.'
    }
    $computed=[bool]($p.is64BitProcess -and $p.vulkanLoaderPresent -and $missing.Count -eq 0)
    if ($p.ready -ne $computed) { throw 'The setup check returned inconsistent prerequisite results.' }
    if ($null -ne $Diagnostic.error -and $Diagnostic.error -isnot [string]) {
        throw 'The setup check returned an invalid diagnostic error.'
    }
    if (($ExitCode -eq 0) -ne [string]::IsNullOrEmpty([string]$Diagnostic.error)) {
        throw 'The setup check returned an inconsistent exit status.'
    }
    $warnings=@()
    $inventoryField=$Diagnostic.PSObject.Properties['prerequisiteInventory']
    $inventoryErrorField=$Diagnostic.PSObject.Properties['prerequisiteInventoryError']
    if (-not $inventoryField -or -not $inventoryErrorField) {
        throw 'The setup check omitted advisory inventory status.'
    }
    if ($null -ne $inventoryErrorField.Value -and $inventoryErrorField.Value -isnot [string]) {
        throw 'The setup check returned an invalid advisory inventory status.'
    }
    if ($null -eq $inventoryField.Value -or -not [string]::IsNullOrEmpty([string]$inventoryErrorField.Value)) {
        $warnings+= 'Detailed prerequisite inventory is unavailable. File presence alone does not qualify compatibility.'
    } else {
        $inventory=$inventoryField.Value
        if (-not $inventory.PSObject.Properties['schemaVersion'] -or ($inventory.schemaVersion -isnot [int] -and $inventory.schemaVersion -isnot [long]) -or $inventory.schemaVersion -ne 1 -or
            -not $inventory.PSObject.Properties['applicable'] -or $inventory.applicable -isnot [bool] -or -not $inventory.applicable -or
            -not $inventory.PSObject.Properties['qualified'] -or $inventory.qualified -isnot [bool] -or $inventory.qualified -or
            -not $inventory.PSObject.Properties['compatibilityVerified'] -or $inventory.compatibilityVerified -isnot [bool] -or $inventory.compatibilityVerified -or
            -not $inventory.PSObject.Properties['partial'] -or $inventory.partial -isnot [bool]) {
            throw 'The setup check returned malformed advisory inventory.'
        }
        $observationUncertain=[bool]$inventory.partial
        if (-not $inventory.PSObject.Properties['vcRuntimeRegistration'] -or $null -eq $inventory.vcRuntimeRegistration -or
            -not $inventory.vcRuntimeRegistration.PSObject.Properties['status'] -or
            $inventory.vcRuntimeRegistration.status -cne 'observed' -or
            -not $inventory.vcRuntimeRegistration.PSObject.Properties['installed'] -or
            $inventory.vcRuntimeRegistration.installed -isnot [bool] -or -not $inventory.vcRuntimeRegistration.installed -or
            -not $inventory.vcRuntimeRegistration.PSObject.Properties['versionState'] -or
            $inventory.vcRuntimeRegistration.versionState -cne 'observed') {
            $observationUncertain=$true
        }
        if (-not $inventory.PSObject.Properties['files'] -or $null -eq $inventory.files -or
            $inventory.files -isnot [array] -or @($inventory.files).Count -ne 4) {
            $observationUncertain=$true
        } else {
            $names=@('MSVCP140.dll','VCRUNTIME140.dll','VCRUNTIME140_1.dll','vulkan-1.dll')
            for($i=0;$i -lt 4;$i++) {
                $file=$inventory.files[$i]
                if($null -eq $file -or -not $file.PSObject.Properties['name'] -or $file.name -cne $names[$i] -or
                    -not $file.PSObject.Properties['status'] -or $file.status -cne 'observed' -or
                    -not $file.PSObject.Properties['signatureStatus'] -or $file.signatureStatus -cne 'Valid' -or
                    -not $file.PSObject.Properties['fileVersion'] -or [string]::IsNullOrEmpty([string]$file.fileVersion)) {
                    $observationUncertain=$true
                }
            }
        }
        if ($observationUncertain) {
            $warnings+= 'Some registration, version, or signature observations are missing or inconsistent. Compatibility remains unqualified.'
        }
    }
    return [pscustomobject]@{
        canProceed=$computed; engineVerified=[bool]$Diagnostic.vulkanVerified
        missingVcRuntimeFiles=$missing; missingVulkanLoader=(-not $p.vulkanLoaderPresent)
        missing64BitHost=(-not $p.is64BitProcess); advisoryWarnings=$warnings
        compatibilityQualified=$false
    }
}

function New-FastLlmUiFlow {
    param([ValidateSet('install','start')][string]$Mode)
    return [pscustomobject]@{
        mode=$Mode; phase='setup'
        planAttempts=0; maxPlanAttempts=3; pendingPlan=$null
        pendingProvenance=$null; setupDecision=$null; lastStartIdentity=$null; retryAfterFailure=$false
        lastStartError=$null; acceptNewConsent=$false
    }
}

function Move-FastLlmUiFlow {
    param([Parameter(Mandatory=$true)]$Flow,
          [Parameter(Mandatory=$true)][ValidateSet('setup-complete','setup-recheck','setup-defer','engine-complete','preview-complete',
              'consent-approved','consent-declined','model-complete','serving-failed',
              'serving-complete','stop','error')][string]$Event,
          $Plan, $SetupDecision, [bool]$HasConsent=$false, [bool]$HasArtifact=$false,
          [string]$ErrorMessage)
    switch ($Event) {
        'setup-complete' {
            if ($Flow.phase -ne 'setup' -or -not $SetupDecision -or
                $SetupDecision.canProceed -isnot [bool] -or $SetupDecision.engineVerified -isnot [bool]) {
                throw 'Unexpected or invalid setup check completion.'
            }
            $Flow.setupDecision=$SetupDecision
            if (-not $SetupDecision.canProceed) { $Flow.phase='setup-attention' }
            elseif ($Flow.mode -eq 'install' -or -not $SetupDecision.engineVerified) { $Flow.phase='engine' }
            else { $Flow.phase='preview' }
        }
        'setup-recheck' {
            if ($Flow.phase -ne 'setup-attention') { throw 'No setup action is awaiting recheck.' }
            $Flow.phase='setup'; $Flow.setupDecision=$null
            $Flow.pendingPlan=$null; $Flow.pendingProvenance=$null; $Flow.acceptNewConsent=$false
        }
        'setup-defer' {
            if ($Flow.phase -ne 'setup-attention') { throw 'No setup action is awaiting deferral.' }
            $Flow.phase='cancelled'; $Flow.setupDecision=$null
            $Flow.pendingPlan=$null; $Flow.pendingProvenance=$null; $Flow.acceptNewConsent=$false
        }
        'engine-complete' {
            if ($Flow.phase -ne 'engine') { throw 'Unexpected engine completion.' }
            $Flow.phase='preview'
        }
        'preview-complete' {
            if ($Flow.phase -ne 'preview' -or -not $Plan) { throw 'Unexpected or missing plan preview.' }
            $Flow.planAttempts++
            if ($Flow.planAttempts -gt $Flow.maxPlanAttempts) {
                $Flow.phase='failed'; $Flow.lastStartError='Hardware/model selection did not stabilize within the UI attempt limit.'
                break
            }
            $identity=Get-FastLlmUiPlanIdentity -Plan $Plan
            if ($Flow.retryAfterFailure -and $identity -ceq $Flow.lastStartIdentity) {
                $Flow.phase='failed'
                break
            }
            $Flow.retryAfterFailure=$false
            $Flow.pendingPlan=$Plan
            $Flow.pendingProvenance=Get-FastLlmUiModelProvenanceDigest -Model $Plan.model
            $Flow.acceptNewConsent=$false
            if (-not $HasConsent) { $Flow.phase='consent' }
            elseif (-not $HasArtifact) { $Flow.phase='model-download' }
            else { $Flow.phase='serving' }
        }
        'consent-approved' {
            if ($Flow.phase -ne 'consent' -or -not $Flow.pendingPlan) { throw 'No exact model is awaiting consent.' }
            $Flow.acceptNewConsent=$true; $Flow.phase='model-download'
        }
        'consent-declined' {
            if ($Flow.phase -ne 'consent') { throw 'No exact model is awaiting consent.' }
            $Flow.phase='cancelled'; $Flow.pendingPlan=$null; $Flow.pendingProvenance=$null
        }
        'model-complete' {
            if ($Flow.phase -ne 'model-download') { throw 'Unexpected model download completion.' }
            $Flow.phase='preview'; $Flow.acceptNewConsent=$false
        }
        'serving-failed' {
            if ($Flow.phase -ne 'serving') { throw 'Unexpected serving failure.' }
            $Flow.lastStartIdentity=Get-FastLlmUiPlanIdentity -Plan $Flow.pendingPlan
            $Flow.lastStartError=$ErrorMessage
            if ($Flow.planAttempts -ge $Flow.maxPlanAttempts) { $Flow.phase='failed' }
            else { $Flow.retryAfterFailure=$true; $Flow.phase='preview' }
        }
        'serving-complete' {
            if ($Flow.phase -ne 'serving') { throw 'Unexpected serving completion.' }
            $Flow.phase='complete'
        }
        'stop' { $Flow.phase='cancelled'; $Flow.pendingPlan=$null; $Flow.pendingProvenance=$null }
        'error' { $Flow.phase='failed'; $Flow.lastStartError=$ErrorMessage }
    }
    return $Flow
}

function Format-FastLlmUiRecipeSummary {
    param([Parameter(Mandatory = $true)] $Plan)
    $names = @(@($Plan.selectedAdapters) | ForEach-Object { if ($_ -and $_.PSObject.Properties['name']) { [string] $_.name } } | Where-Object { $_ } | Select-Object -Unique)
    $card = 'GPU'
    if ($names.Count) { $card = $names -join ' + ' }
    $label = 'Estimated for your card'
    if ($Plan.PSObject.Properties['recipe'] -and $Plan.recipe -and $Plan.recipe.label) { $label = [string] $Plan.recipe.label }
    $quant = ''
    if ($Plan.model.PSObject.Properties['quantization'] -and $Plan.model.quantization) { $quant = " ($($Plan.model.quantization))" }
    $context = ([int] $Plan.model.contextSize).ToString('N0', [Globalization.CultureInfo]::InvariantCulture)
    return "Best setup for your ${card}: $($Plan.model.id)$quant, $context context. $label."
}

function Get-FastLlmUiEvidenceUrl {
    param([Parameter(Mandatory = $true)] $Plan)
    if (-not ($Plan.PSObject.Properties['recipe'] -and $Plan.recipe -and $Plan.recipe.evidenceUrl)) { return $null }
    $url = [string] $Plan.recipe.evidenceUrl
    if ($url.StartsWith('https://bitworks.io/', [StringComparison]::Ordinal)) { return $url }
    return $null
}

# The preview's measured recipe is passed to the start as -Recipe, so a start that can no longer apply it fails closed
# ("does not apply to this PC") instead of silently running as estimated under the preview's measured label.
function Get-FastLlmUiStartRecipeArguments {
    param($Plan, $ChosenRecipe)
    if (-not $Plan -or -not $Plan.PSObject.Properties['recipe'] -or -not $Plan.recipe) { return @() }
    $origin = [string] $Plan.recipe.origin
    $id = $null
    if ($Plan.recipe.PSObject.Properties['id']) { $id = [string] $Plan.recipe.id }
    if (-not $id -or @('estimated', 'manual', '') -contains $origin) { return @() }
    if ($id -cnotmatch '^[a-z0-9][a-z0-9.\-]{1,120}$') { return @() }
    # The experimental acceptance is passed on only for the recipe the user explicitly picked in the chooser (its id equals the plan's), never because a
    # plan happens to report an experimental origin.
    if ((Test-FastLlmExperimentalOrigin -Origin $origin) -and $ChosenRecipe -and [string] $ChosenRecipe.id -ceq $id) { return @('-Recipe', $id, '-AcceptExperimental') }
    return @('-Recipe', $id)
}

# The recipe chosen in "Choose another setup" is pinned for the preview as well, so the plan describes the recipe the user picked.
function Get-FastLlmUiPreviewRecipeArguments {
    param($Recipe)
    if (-not $Recipe) { return @() }
    $id = [string] $Recipe.id
    if ($id -cnotmatch '^[a-z0-9][a-z0-9.\-]{1,120}$') { throw 'The chosen setup has an invalid id; nothing was started.' }
    if (Test-FastLlmExperimentalOrigin -Origin ([string] $Recipe.origin)) { return @('-Recipe', $id, '-AcceptExperimental') }
    return @('-Recipe', $id)
}

# -Recipe cannot be combined with -ModelId and takes its context from the recipe, so a chosen recipe drops the window's model and context pickers.
function Get-FastLlmUiRecipeSelection {
    param([object[]] $Selection, $Recipe)
    if (-not $Recipe) { return @($Selection) }
    $kept = New-Object 'System.Collections.Generic.List[object]'
    $items = @($Selection)
    for ($i = 0; $i -lt $items.Count; $i++) {
        if ([string] $items[$i] -ceq '-ModelId' -or [string] $items[$i] -ceq '-ContextSize') { $i++; continue }
        $kept.Add($items[$i])
    }
    return $kept.ToArray()
}

# ---- "Choose another setup" and the per-component consent dialog (pure helpers) ----

function Format-FastLlmUiHostList {
    param([object[]] $Hosts)
    $names = @($Hosts | Where-Object { $_ } | ForEach-Object { [string] $_ })
    if ($names.Count -eq 0) { return 'a source listed in this release' }
    return ($names -join ', ')
}

# "built in", "installed" or "missing", exactly as the CLI reported it.
function Get-FastLlmUiMemberState {
    param($Member)
    $state = ''
    if ($Member.PSObject.Properties['state']) { $state = [string] $Member.state }
    if (@('built in', 'installed', 'missing') -ccontains $state) { return $state }
    return 'missing'
}

# The recipes the chooser shows, from the detail rows of `recipes -Detail -AsJson`. Experimental rows (community-experimental and
# bitworks-experimental) are shown only when the switch is on, whatever the list contained.
function Get-FastLlmUiChooserRows {
    param([object[]] $Rows, [string] $ExperimentalComponents = 'off', [string] $Variant)
    # Only the identified card's recipes are ever offered; without an identified card nothing is (fail closed).
    if ([string]::IsNullOrWhiteSpace($Variant)) { return @() }
    $shown = New-Object 'System.Collections.Generic.List[object]'
    foreach ($row in @($Rows | Where-Object { $_ })) {
        $origin = [string] $row.origin
        $isExperimental = Test-FastLlmExperimentalOrigin -Origin $origin
        if ($isExperimental -and $ExperimentalComponents -cne 'on') { continue }
        if ([string] $row.variant -cne $Variant) { continue }
        $chain = @($row.chain | Where-Object { $_ })
        # The chain is requires first, the engine last; the text names the engine first, then what it requires, each with its source host.
        $engineText = [string] $row.engineId
        if ($chain.Count -gt 0) {
            $parts = @($chain | ForEach-Object {
                    $name = [string] $_.displayName
                    if ([string]::IsNullOrWhiteSpace($name)) { $name = [string] $_.id }
                    '{0} (from {1}; {2})' -f $name, (Format-FastLlmUiHostList -Hosts @($_.sourceHosts)), (Get-FastLlmUiMemberState -Member $_)
                })
            $engineText = $parts[$parts.Count - 1]
            if ($parts.Count -gt 1) { $engineText += '; requires ' + (@($parts[0..($parts.Count - 2)]) -join '; ') }
        }
        $shown.Add([pscustomobject] [ordered] @{
                id = [string] $row.id; origin = $origin; variant = [string] $row.variant; experimental = [bool] $isExperimental
                label = [string] $row.label; model = [string] $row.model
                contextSize = [int] $row.contextSize
                contextText = ([int] $row.contextSize).ToString('N0', [Globalization.CultureInfo]::InvariantCulture) + ' tokens'
                engineId = [string] $row.engineId; engineText = $engineText
                chain = $chain
                consentRequired = [bool] $row.consentRequired
                installRequired = [bool] $row.installRequired
                chainError = $(if ($row.PSObject.Properties['chainError']) { [string] $row.chainError } else { '' })
            })
    }
    return $shown.ToArray()
}

# Only an https link is ever handed to the browser.
function Get-FastLlmUiSafeLicenseUrl {
    param([string] $Url)
    if ([string]::IsNullOrWhiteSpace($Url) -or $Url.Length -gt 2048 -or $Url -match '[\p{Cc}\s]') { return $null }
    $parsed = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref] $parsed)) { return $null }
    if ($parsed.Scheme -cne 'https' -or [string]::IsNullOrEmpty($parsed.Host)) { return $null }
    return $Url
}

# One consent row per component in the chain. A component that is already installed (or built in) is a read-only row; one that is missing needs
# its "I accept" box. Each row has the component's name, version, source host and license links as listed (no license text); a link is shown with
# its host so the destination is visible. A row with a link that cannot be opened from here is blocked: its box cannot be ticked.
function Get-FastLlmUiConsentRows {
    param([object[]] $Chain)
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($member in @($Chain | Where-Object { $_ })) {
        $state = Get-FastLlmUiMemberState -Member $member
        $links = New-Object 'System.Collections.Generic.List[object]'
        $blocked = $false
        foreach ($link in @($member.licenseLinks | Where-Object { $_ })) {
            $safe = Get-FastLlmUiSafeLicenseUrl -Url ([string] $link.url)
            $linkText = [string] $link.title
            if ($safe) { $linkText = '{0} ({1})' -f [string] $link.title, ([Uri] $safe).Host } else { $blocked = $true }
            $links.Add([pscustomobject] [ordered] @{ title = [string] $link.title; url = $safe; linkText = $linkText })
        }
        $name = [string] $member.displayName
        if ([string]::IsNullOrWhiteSpace($name)) { $name = [string] $member.id }
        $needsAccept = ($state -ceq 'missing')
        $statusText = 'built in'
        if ($state -ceq 'installed') { $statusText = 'installed; license accepted earlier' }
        elseif ($needsAccept) { $statusText = 'will be downloaded' }
        $rows.Add([pscustomobject] [ordered] @{
                id = [string] $member.id; name = $name; version = [string] $member.version
                state = $state; needsAccept = [bool] $needsAccept; blocked = [bool]($needsAccept -and $blocked); statusText = $statusText
                sourceHosts = @($member.sourceHosts); sourceText = (Format-FastLlmUiHostList -Hosts @($member.sourceHosts))
                redirectHosts = @($member.redirectHosts)
                links = $links.ToArray()
                acceptText = ('I accept the license terms for {0}' -f $name)
            })
    }
    return $rows.ToArray()
}

# What the chooser tells the user when it has fewer rows than they expect (or none).
function Get-FastLlmUiChooserNotice {
    param([object[]] $Shown, [string] $ExperimentalComponents = 'off', [string] $Variant)
    if ([string]::IsNullOrWhiteSpace($Variant)) { return 'This card was not identified, so no setup can be offered for it. Nothing was changed.' }
    $parts = New-Object 'System.Collections.Generic.List[string]'
    $rows = @($Shown | Where-Object { $_ })
    if ($ExperimentalComponents -ceq 'on' -and @($rows | Where-Object { $_.experimental }).Count -eq 0) {
        $parts.Add('Experimental community components is on, but no experimental setup is listed for this card.')
    }
    if ($rows.Count -eq 0) { $parts.Add('No other setup is available for this card.') }
    return ($parts -join ' ')
}

# The failure code to trust after a failed start: the one the CLI recorded for THIS run. An unchanged run id means the start failed before it
# wrote its own status, so a code left by an earlier run is ignored.
function Get-FastLlmUiFailureCode {
    param($Status, [string] $PreviousRunId)
    if (-not $Status -or -not $Status.PSObject.Properties['failureCode'] -or -not $Status.PSObject.Properties['runId']) { return '' }
    if ([string] $Status.runId -ceq $PreviousRunId) { return '' }
    return [string] $Status.failureCode
}

# Install is enabled only when there is at least one row and EVERY row's box is ticked.
function Test-FastLlmUiConsentComplete {
    param([int] $RowCount, [object[]] $Ticked)
    $states = @($Ticked)
    if ($RowCount -lt 1 -or $states.Count -ne $RowCount) { return $false }
    foreach ($state in $states) { if ($state -isnot [bool] -or -not $state) { return $false } }
    return $true
}

# The install command the dialog's Install runs, or nothing: Cancel (or an incomplete dialog) never produces one, so nothing is downloaded.
function Get-FastLlmUiComponentInstallArguments {
    param([string] $EngineId, [string] $InstallRoot, [bool] $Confirmed, [int] $RowCount, [object[]] $Ticked)
    if (-not $Confirmed -or -not (Test-FastLlmUiConsentComplete -RowCount $RowCount -Ticked $Ticked)) { return @() }
    if ($EngineId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._\-]{0,127}$' -or [string]::IsNullOrWhiteSpace($InstallRoot)) { return @() }
    return @('components', '-Install', $EngineId, '-InstallRoot', $InstallRoot, '-AcceptLicense', '-Unattended')
}

# Typed failures of a start (the failure code the CLI records in status.json) are shown as their own message; the window does not retry them,
# and nothing falls back to Vulkan.
function Test-FastLlmUiTypedHipFailure {
    param([string] $Code)
    if ([string]::IsNullOrWhiteSpace($Code)) { return $false }
    return [bool] ($Code -cmatch '^(hip-backend-unavailable|hip-dll-blocked|hip-device-[a-z\-]{1,40}|needs-setup-component-missing)$')
}

function Format-FastLlmUiTypedFailure {
    param([string] $Code, [string] $Text)
    return ([string] $Text).TrimEnd() + "`r`n(failure code: $Code)"
}

# What the RUNNING server's plan said about its recipe (status.json planRecipe), never the preview's.
function Get-FastLlmUiRunEvidenceUrl {
    param($State)
    if (-not $State -or -not $State.PSObject.Properties['planRecipe'] -or -not $State.planRecipe) { return $null }
    return (Get-FastLlmUiEvidenceUrl -Plan ([pscustomobject] @{ recipe = $State.planRecipe }))
}

function Get-FastLlmUiRunSetupLine {
    param($State)
    if (-not $State -or -not $State.PSObject.Properties['planRecipe'] -or -not $State.planRecipe -or -not $State.planRecipe.label) { return $null }
    return "Setup: $([string] $State.planRecipe.label)"
}

function Format-FastLlmUiSelfTest {
    param($SelfTest)
    if (-not $SelfTest) { return $null }
    switch ([string] $SelfTest.status) {
        'pass' { return "Self-test passed: $($SelfTest.generationTokS) tok/s generation, $($SelfTest.promptTokS) tok/s prompt." }
        'skipped' { return 'Self-test skipped: the context size is too small for the performance check.' }
        'below-expected' { return "Self-test: slower than expected ($($SelfTest.generationTokS) vs $($SelfTest.expectedGenerationTokS) tok/s generation). Likely causes: driver version, Resizable BAR, other apps using GPU memory, power or thermal limits. Run Doctor for details." }
        default {
            $reasons = @()
            if ($SelfTest.PSObject.Properties['reasons']) { $reasons = @($SelfTest.reasons) }
            return "Self-test failed ($($reasons -join ', ')). FastLLM tries the next cached setup."
        }
    }
}

function Get-FastLlmUiBarNote {
    param($State)
    if ($State -and $State.PSObject.Properties['barGuidance'] -and $State.barGuidance -and $State.barGuidance.shown) { return [string] $State.barGuidance.text }
    return $null
}

# The update keys come from Get-FastLlmUpdateSettings (src/FastLlm.Update.ps1), the one source of their defaults.
function Read-FastLlmUiSettings {
    param([Parameter(Mandatory = $true)][string] $InstallRoot, [string] $AppRoot)
    if (-not (Get-Command Get-FastLlmUpdateSettings -ErrorAction SilentlyContinue)) {
        . (Join-Path $PSScriptRoot 'FastLlm.Update.ps1')
    }
    $update = Get-FastLlmUpdateSettings -InstallRoot $InstallRoot -AppRoot $AppRoot
    $settings = [pscustomobject] [ordered]@{ vulkanBarMitigation = 'auto'; updateCheck = [string] $update.updateCheck; updateChannel = [string] $update.updateChannel; experimentalComponents = 'off' }
    $path = Join-Path $InstallRoot 'settings.json'
    try {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $stored = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            if ($stored.PSObject.Properties['vulkanBarMitigation'] -and @('auto', 'on', 'off') -contains [string] $stored.vulkanBarMitigation) {
                $settings.vulkanBarMitigation = [string] $stored.vulkanBarMitigation
            }
            if ($stored.PSObject.Properties['experimentalComponents'] -and @('on', 'off') -ccontains [string] $stored.experimentalComponents) {
                $settings.experimentalComponents = [string] $stored.experimentalComponents
            }
        }
    }
    catch { }
    return $settings
}

# Read-modify-write: every key already in settings.json (including ones this window does not know) is kept.
# updateCheck, updateChannel and experimentalComponents are written only when the caller supplies them; the window itself writes them with Set-FastLlmUpdateSettings.
function Write-FastLlmUiSettings {
    param([Parameter(Mandatory = $true)][string] $InstallRoot, [Parameter(Mandatory = $true)] $Settings)
    $value = [string] $Settings.vulkanBarMitigation
    if (@('auto', 'on', 'off') -notcontains $value) { throw 'vulkanBarMitigation must be auto, on or off.' }
    $path = Join-Path $InstallRoot 'settings.json'
    $merged = [ordered]@{}
    try {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $stored = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            if ($null -ne $stored -and $stored -is [pscustomobject]) {
                foreach ($property in $stored.PSObject.Properties) { $merged[$property.Name] = $property.Value }
            }
        }
    }
    catch { $merged = [ordered]@{} }
    $merged['vulkanBarMitigation'] = $value
    $checkProperty = $Settings.PSObject.Properties['updateCheck']
    if ($checkProperty -and $null -ne $checkProperty.Value) {
        if (@('on', 'off') -cnotcontains [string] $checkProperty.Value) { throw 'updateCheck must be on or off.' }
        $merged['updateCheck'] = [string] $checkProperty.Value
    }
    $channelProperty = $Settings.PSObject.Properties['updateChannel']
    if ($channelProperty -and $null -ne $channelProperty.Value) {
        if (@('stable', 'canary') -cnotcontains [string] $channelProperty.Value) { throw 'updateChannel must be stable or canary.' }
        $merged['updateChannel'] = [string] $channelProperty.Value
    }
    $experimentalProperty = $Settings.PSObject.Properties['experimentalComponents']
    if ($experimentalProperty -and $null -ne $experimentalProperty.Value) {
        if (@('on', 'off') -cnotcontains [string] $experimentalProperty.Value) { throw 'experimentalComponents must be on or off.' }
        $merged['experimentalComponents'] = [string] $experimentalProperty.Value
    }
    if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) { New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null }
    $temporary = "$path.tmp-$([guid]::NewGuid().ToString('N'))"
    [IO.File]::WriteAllText($temporary, (([pscustomobject] $merged) | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $path -Force
}

$script:FastLlmUiReleasesUrlPrefix = 'https://github.com/bitworks-io/amd-inference/releases'

function Get-FastLlmUiValue {
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] }; return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

# The banner for an update check result: $null unless a newer release is available. The link is shown only for this repository's release pages.
function Format-FastLlmUiUpdateBanner {
    param($Check)
    if ([string] (Get-FastLlmUiValue $Check 'status') -cne 'available') { return $null }
    $latest = Get-FastLlmUiValue $Check 'latest'
    $version = [string] (Get-FastLlmUiValue $latest 'version')
    if ($version -cnotmatch '^\d{4}\.\d{2}\.\d{2}\.[1-9]\d{0,3}$') { return $null }
    $url = [string] (Get-FastLlmUiValue $latest 'htmlUrl')
    if (-not $url.StartsWith($script:FastLlmUiReleasesUrlPrefix, [StringComparison]::Ordinal)) { $url = $null }
    return @{ text = "FastLLM $version is available."; url = $url }
}

# The red banner for a failed first-launch integrity check; ok, not-installed and an unusable result show nothing.
function Format-FastLlmUiIntegrityBanner {
    param($Result)
    if ([string] (Get-FastLlmUiValue $Result 'status') -cne 'failed') { return $null }
    return @{ text = "FastLLM's files don't match its signed catalog. Reinstall FastLLM from the release page."; url = $script:FastLlmUiReleasesUrlPrefix }
}

function Format-FastLlmUiUpdateConfirm {
    param([Parameter(Mandatory = $true)][string] $Version)
    return "FastLLM will stop the server, download $Version, check its Bitworks signature, and run the installer. Continue?"
}

# True only for the outcome where the installer ran and the installed files then failed the catalog check.
function Test-FastLlmUiUpdateIntegrityFailure {
    param($Result)
    return ([string] (Get-FastLlmUiValue $Result 'status') -ceq 'failed' -and [string] (Get-FastLlmUiValue $Result 'step') -ceq 'integrity')
}

function Format-FastLlmUiUpdateResult {
    param($Result, [string] $Version)
    if ([string] (Get-FastLlmUiValue $Result 'status') -ceq 'installed') { return "FastLLM was updated to $Version. Close and reopen FastLLM." }
    if ((Test-FastLlmUiUpdateIntegrityFailure -Result $Result)) { return "FastLLM $Version was installed, but its files don't match the signed catalog. Reinstall FastLLM from the release page." }
    $reason = [string] (Get-FastLlmUiValue $Result 'reason')
    if ([string]::IsNullOrEmpty($reason)) { $reason = [string] (Get-FastLlmUiValue $Result 'status') }
    if ([string]::IsNullOrEmpty($reason)) { $reason = 'the update did not complete' }
    return "Update not installed: $reason. Nothing was changed."
}

function Read-FastLlmUiIntegrityRecord {
    param([Parameter(Mandatory = $true)][string] $InstallRoot)
    $recorded = [ordered]@{}
    try {
        $path = Join-Path (Join-Path $InstallRoot 'state') 'integrity-checked.json'
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $stored = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            if ($null -ne $stored -and $stored -is [pscustomobject]) {
                foreach ($property in $stored.PSObject.Properties) { $recorded[$property.Name] = $property.Value }
            }
        }
    }
    catch { $recorded = [ordered]@{} }
    return $recorded
}

# Due until a version has been recorded as checked (read-only). Only an ok or not-installed result is recorded, so a failed install is re-checked every launch.
function Test-FastLlmUiIntegrityDue {
    param([Parameter(Mandatory = $true)][string] $InstallRoot, [string] $InstalledVersion)
    if ($InstalledVersion -cnotmatch '^\d{4}\.\d{2}\.\d{2}\.[1-9]\d{0,3}$') { return $false }
    return (-not (Read-FastLlmUiIntegrityRecord -InstallRoot $InstallRoot).Contains($InstalledVersion))
}

# Records the result in <InstallRoot>\state\integrity-checked.json; a failed (or unknown) result is never recorded.
function Set-FastLlmUiIntegrityChecked {
    param([Parameter(Mandatory = $true)][string] $InstallRoot, [string] $InstalledVersion, $Result)
    if ($InstalledVersion -cnotmatch '^\d{4}\.\d{2}\.\d{2}\.[1-9]\d{0,3}$') { return $false }
    if (@('ok', 'not-installed') -cnotcontains [string] (Get-FastLlmUiValue $Result 'status')) { return $false }
    $recorded = Read-FastLlmUiIntegrityRecord -InstallRoot $InstallRoot
    $recorded[$InstalledVersion] = [datetime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    try {
        $path = Join-Path (Join-Path $InstallRoot 'state') 'integrity-checked.json'
        [IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
        $temporary = "$path.tmp-$([guid]::NewGuid().ToString('N'))"
        [IO.File]::WriteAllText($temporary, (([pscustomobject] $recorded) | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporary -Destination $path -Force
        return $true
    }
    catch { return $false }
}
