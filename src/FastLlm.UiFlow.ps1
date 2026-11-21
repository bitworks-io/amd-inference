# Pure transition and exact-provenance helpers shared by the control window and
# its CLI child. No native process, UI, network, or filesystem work occurs here.
Set-StrictMode -Version 2

# The model-switching opt-in reader (Get-FastLlmUiAllowSwitch) is shared with the start at sign-in, which never loads this file.
. (Join-Path $PSScriptRoot 'FastLlm.UiSettings.ps1')

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

# The window's setup check asks doctor for its compact report; this is the most text the window will parse from it.
$script:FastLlmUiSetupCheckMaxCharacters = 262144

# The window's output capture (ProcessHost) cuts every output line to this many characters; a line this long may be cut.
$script:FastLlmUiOutputLineCutCharacters = 8192

# Steps that start or advance a run. Only these clear the "stopped by the user" background line; Diagnostics, a setup check and
# other read-only steps leave it alone.
function Test-FastLlmUiStepStartsRun {
    param([AllowNull()][string]$Step)
    return ($Step -cin @('engine', 'model download', 'serving', 'component install'))
}

# True when the window's capture may have dropped part of a child's output: the rolling total reached its limit, or a line
# reached the per-line cut length (a line that long may have been cut).
function Test-FastLlmUiOutputWasCut {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    if ($Text.Length -ge $script:FastLlmUiSetupCheckMaxCharacters) { return $true }
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line.Length -ge $script:FastLlmUiOutputLineCutCharacters) { return $true }
    }
    return $false
}

function ConvertFrom-FastLlmUiSetupCheckOutput {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text) -or $Text.Length -gt $script:FastLlmUiSetupCheckMaxCharacters) {
        throw 'The setup check returned no usable bounded diagnostic.'
    }
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line.Length -ge $script:FastLlmUiOutputLineCutCharacters) {
            throw 'The setup check returned a line longer than the window can read; open Diagnostics for details.'
        }
    }
    return (ConvertFrom-Json $Text)
}

# doctor -Compact: the install-integrity block keeps its status, reason, mismatch list and summary line, and the catalog signature
# result keeps only its ok/reason/detail verdict; the full signature object that Authenticode attaches is dropped.
function ConvertTo-FastLlmCompactDoctorReport {
    param([Parameter(Mandatory=$true)]$Diagnostic)
    $integrity = $Diagnostic['installIntegrity']
    if ($null -eq $integrity) { return $Diagnostic }
    $signature = $integrity.catalogSignature
    $compactSignature = $null
    if ($null -ne $signature) {
        $compactSignature = [ordered]@{}
        foreach ($name in @('ok', 'reason', 'detail')) {
            if ($signature.PSObject.Properties[$name]) { $compactSignature[$name] = $signature.PSObject.Properties[$name].Value }
        }
        $compactSignature = [pscustomobject]$compactSignature
    }
    $Diagnostic['installIntegrity'] = [pscustomobject][ordered]@{
        appRoot          = $integrity.appRoot
        status           = $integrity.status
        reason           = $integrity.reason
        catalogSignature = $compactSignature
        mismatches       = @($integrity.mismatches)
        summary          = $integrity.summary
    }
    return $Diagnostic
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
        planAttempts=0; maxPlanAttempts=3; componentAttempts=0; maxComponentAttempts=1; pendingPlan=$null
        pendingProvenance=$null; setupDecision=$null; lastStartIdentity=$null; retryAfterFailure=$false
        lastStartError=$null; acceptNewConsent=$false
    }
}

function Move-FastLlmUiFlow {
    param([Parameter(Mandatory=$true)]$Flow,
          [Parameter(Mandatory=$true)][ValidateSet('setup-complete','setup-recheck','setup-defer','engine-complete','preview-complete',
              'consent-approved','consent-declined','model-complete','serving-failed','components-handled',
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
        'components-handled' {
            # The preview named components that were installed or declined; the preview runs again. The component step has its own one-time
            # budget, so the previews and the serving retry keep theirs; a second round of pending components does not stabilize.
            if ($Flow.phase -ne 'preview') { throw 'Unexpected component handling.' }
            $Flow.componentAttempts++
            if ($Flow.componentAttempts -gt $Flow.maxComponentAttempts) {
                $Flow.phase='failed'; $Flow.lastStartError='Hardware/model selection did not stabilize within the UI attempt limit.'
            }
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

# An automatic preview is started with -PlannedRecipe, so the start resolves the fallback again and keeps its true reason; the recipe the user picked in
# "Choose another setup" is started with -Recipe, which never falls back. -UseFallback is added only for a real decline ('declined') or the window's own
# failed component install ('install-failed', which also says why); 'resolve' (the preview took the fallback for a reason of its own) adds nothing.
function Get-FastLlmUiFallbackSwitches {
    param([string] $Request, [bool] $Preview = $false)
    if ($Request -ceq 'declined') { return @('-UseFallback') }
    if ($Request -ceq 'install-failed') { return @('-UseFallback', '-FallbackReason', 'components-install-failed') }
    if ($Preview -and $Request -ceq 'resolve') { return @('-UseFallback') }
    return @()
}

function Get-FastLlmUiStartRecipeArguments {
    param($Plan, $ChosenRecipe, [string] $FallbackRequest = '')
    if (-not $Plan) { return @() }
    $recipeId = $null
    $origin = ''
    if ($Plan.PSObject.Properties['recipe'] -and $Plan.recipe) {
        $origin = [string] $Plan.recipe.origin
        if ($Plan.recipe.PSObject.Properties['id']) { $recipeId = [string] $Plan.recipe.id }
    }
    $chosenIsPlan = [bool]($ChosenRecipe -and $recipeId -and [string] $ChosenRecipe.id -ceq $recipeId)
    # A plan that carries a fallback (a stand-in that may be an estimated plan with no recipe of its own) is started from the setup it replaced.
    if (-not $chosenIsPlan -and $Plan.PSObject.Properties['fallback'] -and $Plan.fallback -and $Plan.fallback.PSObject.Properties['fromRecipe']) {
        $from = [string] $Plan.fallback.fromRecipe
        if ($from -cmatch '^[a-z0-9][a-z0-9.\-]{1,120}$') { return (@('-PlannedRecipe', $from) + @(Get-FastLlmUiFallbackSwitches -Request $FallbackRequest)) }
        return @()
    }
    if (-not $recipeId -or @('estimated', 'manual', '') -contains $origin) { return @() }
    if ($recipeId -cnotmatch '^[a-z0-9][a-z0-9.\-]{1,120}$') { return @() }
    # The experimental acceptance is passed on only for the recipe the user explicitly picked in the chooser (its id equals the plan's), never because a
    # plan happens to report an experimental origin.
    if ((Test-FastLlmExperimentalOrigin -Origin $origin) -and $chosenIsPlan) { return @('-Recipe', $recipeId, '-AcceptExperimental') }
    if (-not $chosenIsPlan -and $origin -ceq 'bitworks') {
        $hasSetup = [bool]($Plan.PSObject.Properties['setup'] -and $Plan.setup)
        $hasEngine = [bool]($Plan.PSObject.Properties['engineComponentId'] -and $Plan.engineComponentId)
        if ($hasSetup -or $hasEngine) { return (@('-PlannedRecipe', $recipeId) + @(Get-FastLlmUiFallbackSwitches -Request $FallbackRequest)) }
    }
    return @('-Recipe', $recipeId)
}

# The recipe chosen in "Choose another setup" is pinned for the preview as well, so the plan describes the recipe the user picked.
function Get-FastLlmUiPreviewRecipeArguments {
    param($Recipe, [string] $FallbackRequest = '')
    # An automatic preview can be asked for the fallback setup; a chosen recipe never falls back, so it takes no such switch.
    if (-not $Recipe) { return @(Get-FastLlmUiFallbackSwitches -Request $FallbackRequest -Preview $true) }
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
        # A pending component of a plan names itself `name` and has no state; it is shown as missing.
        if (-not $member.PSObject.Properties['displayName'] -and $member.PSObject.Properties['name']) {
            $member = [pscustomobject] [ordered] @{
                id = $member.id; displayName = $member.name; version = $member.version; state = 'missing'
                sourceHosts = $member.sourceHosts; redirectHosts = $member.redirectHosts; licenseLinks = $member.licenseLinks
            }
        }
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

# True only when the status was written by the run started after PreviousRunId. A status with no run id, or the same run id as before the
# start, belongs to an earlier run and must not drive Ready or the self-test notes.
function Test-FastLlmUiStatusIsCurrentRun {
    param($Status, [string] $PreviousRunId)
    if (-not $Status -or -not $Status.PSObject.Properties['runId']) { return $false }
    $runId = [string] $Status.runId
    if ([string]::IsNullOrEmpty($runId)) { return $false }
    return -not ($runId -ceq $PreviousRunId)
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

# Typed failures of a start (the failure code the CLI records in status.json) are shown as their own message; the window does not retry them.
# This is the path of a setup the user picked in the chooser (an explicit -Recipe never falls back); an automatic start falls back inside the CLI.
function Test-FastLlmUiTypedHipFailure {
    param([string] $Code)
    if ([string]::IsNullOrWhiteSpace($Code)) { return $false }
    return [bool] ($Code -cmatch '^(hip-backend-unavailable|hip-dll-blocked|hip-dll-missing|hip-device-[a-z\-]{1,40}|needs-setup-component-missing)$')
}

# The start information for one of the window's fast-llm.ps1 children (LaunchStep and LaunchSideStep; not the VC++ preparation child).
# Contract with fast-llm.ps1's failure catch: the child is given FASTLLM_STDERR_ENCODING=utf-8 in its own environment, so it writes a failure
# message to a redirected stderr as UTF-8 (no byte order mark), and the window decodes that stderr as UTF-8. Only the exact value 'utf-8' enables
# it; any other caller of fast-llm.ps1 keeps its console encoding. The variable is set on this child's start information only, never in the
# window's own environment (that would reach every child, the engines included), and stdout is not changed.
function New-FastLlmUiCliStartInfo {
    param([Parameter(Mandatory = $true)][string] $AppRoot, [object[]] $Arguments = @())
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = (Get-Process -Id $PID).Path
    $argsList = @('-NoLogo', '-NoProfile', '-NonInteractive', '-OutputFormat', 'Text', '-File', (Join-Path $AppRoot 'fast-llm.ps1')) + @($Arguments)
    $info.Arguments = & (Get-Module FastLlm) { param($A) Join-FastLlmProcessArguments $A } $argsList
    $info.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $info.EnvironmentVariables['FASTLLM_STDERR_ENCODING'] = 'utf-8'
    return $info
}

function Format-FastLlmUiTypedFailure {
    param([string] $Code, [string] $Text)
    return ([string] $Text).TrimEnd() + "`r`n(failure code: $Code)"
}

# The visible text of a failed child's capture, without Windows PowerShell 5.1's error-record decoration. The capture itself is kept elsewhere
# and copied unchanged ("Copy full output"); this only chooses what the output box shows. It removes ONLY what it can prove belongs to an error
# record, which is a complete tail: an "At <path>:<n> char:<n>" line, one or more "+ ..." code lines (the last is the "+ ~~~" underline), a
# "    + CategoryInfo   : ..." line and a "    + FullyQualifiedErrorId : ..." line (each with its wrapped continuation), and the single-space line
# 5.1 prints after a record. A continuation is a line after a line of exactly 120 characters (the 5.1 hard wrap width) or one indented to the
# value column; a "(failure code: ...)" line is never one. The record's message is the text before the tail:
#  a) a line starting with "<path>.ps1 : ", "<path>.psm1 : " or "powershell.exe : " (any case, the path holds no " : ") and the lines
#     after it; only that prefix is removed from the line;
#  b) with no such prefix (a throw), the line right before the tail and the lines before it that are exactly 120 wide.
# The message lines are joined into one line only when every one of them except the last is exactly 120 characters long (measured as printed,
# prefix included); otherwise they stay as they are. Every other line, every message text and the line ends are kept, and a text with no
# complete record is returned unchanged, byte for byte.
function Format-FastLlmUiFailureDisplay {
    param([string] $Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $parts = [regex]::Split($Text, '(\r\n|\n)')
    $lines = New-Object System.Collections.Generic.List[string]
    $seps = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $parts.Count; $i += 2) {
        $lines.Add([string] $parts[$i])
        $seps.Add($(if ($i + 1 -lt $parts.Count) { [string] $parts[$i + 1] } else { '' }))
    }
    $count = $lines.Count
    $wrapWidth = 120
    $categoryRx = '^    \+ CategoryInfo +: '
    $errorIdRx = '^    \+ FullyQualifiedErrorId +: '
    $atRx = '^At .+:\d+ char:\d+\s*$'
    $codeRx = '^\+ '
    $prefixRx = '(?i)^(?<path>(?:(?! : ).)*?(?:\.ps1|\.psm1|powershell\.exe)) : (?<message>.*)$'
    $isContinuation = {
        param([int] $Index)
        if ($Index -ge $count) { return $false }
        $line = $lines[$Index]
        if ($line.Length -eq 0 -or $line -cmatch '^\(failure code: ' -or $line -match $categoryRx -or $line -match $errorIdRx -or $line -cmatch $atRx -or $line -cmatch $codeRx) { return $false }
        return ($lines[$Index - 1].Length -eq $wrapWidth -or $line -cmatch '^ {30}\S')
    }
    $outLines = New-Object System.Collections.Generic.List[string]
    $outSeps = New-Object System.Collections.Generic.List[string]
    $position = 0
    $changed = $false
    $index = 0
    while ($index -lt $count) {
        if ($lines[$index] -notmatch $categoryRx) { $index++; continue }
        # Forward: the CategoryInfo line, its continuations, the FullyQualifiedErrorId line, its continuations, the single-space line.
        $next = $index + 1
        while (& $isContinuation $next) { $next++ }
        if ($next -ge $count -or $lines[$next] -notmatch $errorIdRx) { $index++; continue }
        $next++
        while (& $isContinuation $next) { $next++ }
        $tailEnd = $next - 1
        if ($next -lt $count -and $lines[$next] -ceq ' ') { $tailEnd = $next }
        # Backward from the CategoryInfo line. A terminating error (a throw, a cmdlet error) has a position block first: an "At <path>:<n> char:<n>"
        # line and its "+ " code lines. A Write-Error record from a script run with -File has none: its message lines come right before the tail.
        $tailStart = $index
        $back = $index - 1
        $codeLines = 0
        while ($back -ge $position -and $lines[$back] -cmatch $codeRx) { $back--; $codeLines++ }
        $hasPosition = $false
        if ($codeLines -ge 1) {
            if ($back -lt $position -or $lines[$back] -cnotmatch $atRx) { $index++; continue }
            $tailStart = $back
            $hasPosition = $true
        }
        # The message: the lines between its first line and the tail. Its first line is proven only by a script or host prefix (the nearest one
        # after the previous record); only that prefix is removed, and the message lines are joined into one (a 120-wide line with no space, any
        # other line with one space). Without a prefix, a record is proven only by its position block, and its message lines stay exactly as they are,
        # never joined: where such a message starts cannot be proven. A record with neither a prefix nor a position block is not touched.
        $messageStart = -1
        $strippedFirst = $null
        for ($k = $tailStart - 1; $k -ge $position; $k--) {
            $found = [regex]::Match($lines[$k], $prefixRx)
            if ($found.Success) { $messageStart = $k; $strippedFirst = $found.Groups['message'].Value; break }
        }
        if ($messageStart -lt 0) {
            if (-not $hasPosition) { $index++; continue }
            $messageStart = $tailStart
        }
        # Every line before the message (and, without a prefix, the message lines themselves) is kept exactly as it is.
        for ($k = $position; $k -lt $messageStart; $k++) { $outLines.Add($lines[$k]); $outSeps.Add($seps[$k]) }
        $messageCount = $tailStart - $messageStart
        if ($messageCount -gt 0) {
            # A proven record (a prefix line and its tail): every line from the prefix line to the tail is the message, wrapped by the host. A line of
            # exactly the host width ends at a hard wrap and is joined with no space; any other line ends at a word wrap and is joined with one space.
            $messageText = $null
            for ($k = $messageStart; $k -lt $tailStart; $k++) {
                $piece = $(if ($k -eq $messageStart) { $strippedFirst } else { $lines[$k] })
                if ($null -eq $messageText) { $messageText = $piece }
                elseif ($lines[$k - 1].Length -eq $wrapWidth) { $messageText = $messageText + $piece }
                else { $messageText = $messageText.TrimEnd() + ' ' + $piece }
            }
            $outLines.Add($messageText); $outSeps.Add($seps[$tailEnd])
        }
        $changed = $true
        $position = $tailEnd + 1
        $index = $position
    }
    if (-not $changed) { return $Text }
    for ($k = $position; $k -lt $count; $k++) { $outLines.Add($lines[$k]); $outSeps.Add($seps[$k]) }
    $builder = New-Object System.Text.StringBuilder
    for ($k = 0; $k -lt $outLines.Count; $k++) { [void] $builder.Append($outLines[$k]).Append($outSeps[$k]) }
    return $builder.ToString()
}

# What the window shows and keeps for a failure. A failure shown from a child's capture passes the capture: the box shows its cleaned text
# and the capture is kept exactly as captured for "Copy full output". Fixed window text passes none: the text is shown as is and nothing is kept.
function Get-FastLlmUiFailureView {
    param([string] $Message, [string] $Capture)
    if ($PSBoundParameters.ContainsKey('Capture') -and -not [string]::IsNullOrEmpty($Capture)) {
        return [pscustomobject] @{ text = (Format-FastLlmUiFailureDisplay -Text $Message); capture = $Capture }
    }
    return [pscustomobject] @{ text = [string] $Message; capture = $null }
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

# A short user text for a fallback reason; a code that is not listed is shown as it is.
function Get-FastLlmUiFallbackReasonText {
    param([string] $Reason)
    switch -CaseSensitive ($Reason) {
        'components-declined' { return 'AMD license not accepted' }
        'components-pending' { return 'HIP components not installed' }
        'components-unverified' { return 'HIP component failed its file check' }
        'components-install-failed' { return 'HIP components could not be installed' }
        'hip-dll-blocked' { return 'Windows blocked the HIP runtime' }
        'hip-dll-missing' { return 'HIP runtime could not be loaded' }
        'hip-backend-unavailable' { return 'HIP runtime could not be loaded' }
        'hip-device-not-found' { return 'HIP could not use this card' }
        'hip-device-ambiguous' { return 'HIP could not use this card' }
        'start-failed' { return 'HIP server did not start' }
        default { return $Reason }
    }
}

# "Running on HIP (AMD ROCm 10.0)", "Running on Vulkan" or "Running on Vulkan (fallback: <reason>)", from the engine and fallback blocks of status.json.
function Format-FastLlmUiRunEngineLine {
    param($State)
    if (-not $State -or -not $State.PSObject.Properties['engine'] -or -not $State.engine) { return $null }
    $backend = ''
    if ($State.engine.PSObject.Properties['backend'] -and $State.engine.backend) { $backend = ([string] $State.engine.backend).ToLowerInvariant() }
    if ($backend -ceq 'hip') { return 'Running on HIP (AMD ROCm 10.0)' }
    if ($backend -cne 'vulkan') { return $null }
    if ($State.PSObject.Properties['fallback'] -and $State.fallback -and $State.fallback.PSObject.Properties['reason'] -and -not [string]::IsNullOrWhiteSpace([string] $State.fallback.reason)) {
        return ('Running on Vulkan (fallback: {0})' -f (Get-FastLlmUiFallbackReasonText -Reason ([string] $State.fallback.reason)))
    }
    return 'Running on Vulkan'
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
    $settings = [pscustomobject] [ordered]@{ vulkanBarMitigation = 'auto'; updateCheck = [string] $update.updateCheck; updateChannel = [string] $update.updateChannel; experimentalComponents = 'off'; lastUserStoppedBackgroundRequestId = ''; allowSwitch = $false }
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
            if ($stored.PSObject.Properties['lastUserStoppedBackgroundRequestId'] -and [string] $stored.lastUserStoppedBackgroundRequestId -cmatch '^[0-9a-f]{32}$') {
                $settings.lastUserStoppedBackgroundRequestId = [string] $stored.lastUserStoppedBackgroundRequestId
            }
            # Opt-in model switching: the one shared reader (Get-FastLlmUiAllowSwitch, src/FastLlm.UiSettings.ps1) decides.
            if (Get-FastLlmUiAllowSwitch -InstallRoot $InstallRoot) { $settings.allowSwitch = $true }
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
    # A settings.json that exists but is not a readable JSON object (it does not parse, it is not an object, it is a folder or a link, it
    # is over 16 KiB, it cannot be read right now) is refused instead of being read as empty: written back, an empty read would erase
    # every setting the file held, the API key flag among them, and the next start would run without the key that was asked for. The
    # same verdict as Read-FastLlmServingSettingsObject (malformed). An absent file is empty.
    $merged = [ordered]@{}
    $readable = $true
    try {
        if (Test-Path -LiteralPath $path) {
            $readable = $false
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if (-not $item.PSIsContainer -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and $item.Length -le 16384) {
                $storedText = [IO.File]::ReadAllText($path)
                $stored = $null
                # A JSON object and nothing else. The text must begin with "{" (PowerShell 7 would hand back the one element of a
                # one-element array as the document), and the parsed value must be the class PSCustomObject - not [pscustomobject]
                # (PSObject), which an array, a string or a number returned by a cmdlet would pass too.
                if ($storedText.TrimStart().StartsWith('{', [StringComparison]::Ordinal)) { $stored = $storedText | ConvertFrom-Json -ErrorAction Stop }
                if ($null -ne $stored -and $stored -is [System.Management.Automation.PSCustomObject]) {
                    foreach ($property in $stored.PSObject.Properties) { $merged[$property.Name] = $property.Value }
                    $readable = $true
                }
            }
        }
    }
    catch { $readable = $false }
    if (-not $readable) { throw 'settings-malformed: settings.json is not valid JSON, so it was not changed. Fix or delete it, then try again.' }
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
    # The request id of the background run the user last stopped: a 32-hex value sets it, an empty string removes it.
    $stoppedProperty = $Settings.PSObject.Properties['lastUserStoppedBackgroundRequestId']
    if ($stoppedProperty -and $null -ne $stoppedProperty.Value) {
        $stoppedValue = [string] $stoppedProperty.Value
        if ($stoppedValue -eq '') { $merged.Remove('lastUserStoppedBackgroundRequestId') }
        elseif ($stoppedValue -cmatch '^[0-9a-f]{32}$') { $merged['lastUserStoppedBackgroundRequestId'] = $stoppedValue }
        else { throw 'lastUserStoppedBackgroundRequestId must be 32 lowercase hex characters or empty.' }
    }
    # Opt-in model switching: true is stored; false removes the key (so a file that never had it is what it was).
    $switchProperty = $Settings.PSObject.Properties['allowSwitch']
    if ($switchProperty -and $null -ne $switchProperty.Value) {
        if ($switchProperty.Value -isnot [bool]) { throw 'allowSwitch must be true or false.' }
        if ($switchProperty.Value) { $merged['allowSwitch'] = $true } else { $merged.Remove('allowSwitch') }
    }
    if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) { New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null }
    $temporary = "$path.tmp-$([guid]::NewGuid().ToString('N'))"
    [IO.File]::WriteAllText($temporary, (([pscustomobject] $merged) | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $path -Force
}

# Saves only that setting; every other key (the BAR value included) is kept as it is.
function Set-FastLlmUiAllowSwitch {
    param([Parameter(Mandatory = $true)][string] $InstallRoot, [Parameter(Mandatory = $true)][bool] $Value)
    $current = Read-FastLlmUiSettings -InstallRoot $InstallRoot
    Write-FastLlmUiSettings -InstallRoot $InstallRoot -Settings ([pscustomobject] @{ vulkanBarMitigation = [string] $current.vulkanBarMitigation; allowSwitch = $Value })
}

# The arguments a foreground start adds for the opt-in model switch: none at all unless the setting is on.
function Get-FastLlmUiSwitchArguments {
    param([bool] $AllowSwitch)
    if ($AllowSwitch) { return @('-SwitchAllowed') }
    return @()
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

# The "Reinstall previous version" button: offered only when the reinstall decision (Resolve-FastLlmReinstall) is eligible and names two
# real versions. Anything else, including no answer, gives no button.
function Get-FastLlmUiReinstallOffer {
    param($Resolved)
    if ([string] (Get-FastLlmUiValue $Resolved 'decision') -cne 'eligible') { return $null }
    $from = [string] (Get-FastLlmUiValue $Resolved 'installed')
    $target = [string] (Get-FastLlmUiValue $Resolved 'target')
    $versionPattern = '^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[1-9][0-9]{0,3}\z'
    if ($from -cnotmatch $versionPattern -or $target -cnotmatch $versionPattern -or $from -ceq $target) { return $null }
    return @{ text = 'Reinstall previous version'; from = $from; to = $target }
}

function Format-FastLlmUiReinstallConfirm {
    param([Parameter(Mandatory = $true)][string] $From, [Parameter(Mandatory = $true)][string] $To)
    return "Reinstall $To (replaces $From)? FastLLM will stop the server, download $To from the signed release page, check its Bitworks signature, and run the installer. Continue?"
}

# The outcome of the explicit reinstall in plain words; a refusal by the decision says why.
function Format-FastLlmUiReinstallResult {
    param($Result, [string] $To)
    if (-not (Get-Command Get-FastLlmReinstallReasonText -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'FastLlm.Update.ps1') }
    $status = [string] (Get-FastLlmUiValue $Result 'status')
    $step = [string] (Get-FastLlmUiValue $Result 'step')
    $reason = [string] (Get-FastLlmUiValue $Result 'reason')
    if ($status -ceq 'installed') { return "FastLLM $To was reinstalled. Close and reopen FastLLM." }
    if ((Test-FastLlmUiUpdateIntegrityFailure -Result $Result)) { return "FastLLM $To was installed, but its files don't match the signed catalog. Reinstall FastLLM from the release page." }
    if ($status -ceq 'refused' -and $step -ceq 'decision') { return ('Reinstall not done: ' + (Get-FastLlmReinstallReasonText $reason)) }
    if ([string]::IsNullOrEmpty($reason)) { $reason = 'the reinstall did not complete' }
    return "Reinstall not done: $reason. Nothing was changed."
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

# The card variant a preview identified ('' when it did not). The window keeps it from the moment the preview completes, so it outlives the plan
# the flow clears when the model license is declined or the workflow is stopped.
function Get-FastLlmUiIdentifiedVariant {
    param($Plan)
    if (-not $Plan -or -not $Plan.PSObject.Properties['recipe'] -or -not $Plan.recipe -or -not $Plan.recipe.PSObject.Properties['variant']) { return '' }
    return [string] $Plan.recipe.variant
}

# How many consent rows still need an accept box (the components that are missing).
function Get-FastLlmUiPendingConsentCount {
    param([object[]] $ConsentRows)
    return @($ConsentRows | Where-Object { $_ -and $_.needsAccept }).Count
}

# Only a step whose CLI reads the experimental switch is blocked when the switch could not be applied to the install folder: the recipe list, and a
# plan or start that names an experimental recipe. Diagnostics, downloads and the rest never read it.
function Test-FastLlmUiStepReadsExperimentalSwitch {
    param([object[]] $Arguments)
    $items = @($Arguments | ForEach-Object { [string] $_ })
    if ($items.Count -eq 0) { return $false }
    if ($items[0] -ceq 'recipes') { return [bool] ($items -ccontains '-Detail') }
    if ($items[0] -ceq 'plan' -or $items[0] -ceq 'start') { return [bool] (@($items | Where-Object { $_ -ceq ('-Accept' + 'Experimental') }).Count -gt 0) }
    return $false
}

# ---- engine components named by the preview (pending setup) ----

# What the window does when the preview names components that are not installed: nothing, install them now (the standing setting covers every license),
# ask first, or take the Vulkan setup (a remembered decline, or a component that failed its file check).
function Get-FastLlmUiPendingDecision {
    param($Plan, $LicenseSettings, [object[]] $DeclinedSetups = @())
    $none = [pscustomobject] [ordered] @{ action = 'none'; recipeId = ''; engineId = ''; rows = @(); notice = ''; fallbackRequest = '' }
    if (-not $Plan -or -not $Plan.PSObject.Properties['setup'] -or -not $Plan.setup -or -not $Plan.setup.PSObject.Properties['pendingComponents']) { return $none }
    $pending = @($Plan.setup.pendingComponents | Where-Object { $_ })
    if ($pending.Count -eq 0) { return $none }
    $recipeId = ''
    if ($Plan.PSObject.Properties['fallback'] -and $Plan.fallback -and $Plan.fallback.PSObject.Properties['fromRecipe'] -and $Plan.fallback.fromRecipe) { $recipeId = [string] $Plan.fallback.fromRecipe }
    elseif ($Plan.PSObject.Properties['recipe'] -and $Plan.recipe -and $Plan.recipe.PSObject.Properties['id']) { $recipeId = [string] $Plan.recipe.id }
    $engineId = ''
    if ($Plan.PSObject.Properties['engineComponentId'] -and $Plan.engineComponentId) { $engineId = [string] $Plan.engineComponentId }
    $rows = @(Get-FastLlmUiConsentRows -Chain $pending)
    $result = [pscustomobject] [ordered] @{ action = 'ask'; recipeId = $recipeId; engineId = $engineId; rows = $rows; notice = ''; fallbackRequest = '' }
    $unverified = @($pending | Where-Object { $_.PSObject.Properties['unverified'] -and [bool] $_.unverified })
    if ($unverified.Count -gt 0) {
        $first = $unverified[0]
        $result.action = 'fallback'
        $result.fallbackRequest = 'resolve'
        $result.notice = ('Using the Vulkan setup: {0} is installed but failed its file check. To install it again, remove it with components -Remove {1}, then start again.' -f [string] $first.name, [string] $first.id)
        return $result
    }
    if (@($DeclinedSetups | ForEach-Object { [string] $_ }) -ccontains $recipeId) {
        $result.action = 'fallback'
        $result.fallbackRequest = 'declined'
        $result.notice = Get-FastLlmUiDeclineLine
        return $result
    }
    if ($LicenseSettings -and (Test-FastLlmLicensesCovered -Settings $LicenseSettings -Pending $pending)) { $result.action = 'install-now' }
    return $result
}

function Get-FastLlmUiDeclineLine {
    return "Using the Vulkan setup: the AMD license wasn't accepted. You can install the HIP setup any time from Choose another setup."
}

# The command that installs the plan's engine components on the strength of the stored setting alone: no -AcceptLicense, the child reads the setting.
function Get-FastLlmUiInstallFailedLine {
    return 'Using the Vulkan setup: the engine components could not be installed. Start again to retry.'
}

function Get-FastLlmUiAutomaticInstallArguments {
    param([string] $EngineId, [string] $InstallRoot)
    if ($EngineId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._\-]{0,127}$' -or [string]::IsNullOrWhiteSpace($InstallRoot)) { return @() }
    return @('components', '-Install', $EngineId, '-InstallRoot', $InstallRoot, '-Unattended')
}

# A readable model name for the consent window, built from the catalog entry's upstream repository and quantization ("Qwen3.8-27B UD-Q4_K_M").
# Falls back to the catalog id when either field is missing, and to an empty string for no model.
function Get-FastLlmModelDisplayName {
    param($Model)
    if ($null -eq $Model) { return '' }
    $id = if ($Model.PSObject.Properties['id']) { [string]$Model.id } else { '' }
    $upstream = if ($Model.PSObject.Properties['upstreamModel']) { [string]$Model.upstreamModel } else { '' }
    $quant = if ($Model.PSObject.Properties['quantization']) { [string]$Model.quantization } else { '' }
    $name = $upstream.Substring($upstream.LastIndexOf('/') + 1).Trim()
    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($quant)) { return $id }
    return "$name $($quant.Trim())"
}

# The dialog's opening text: the setup the user picked, or the best setup FastLLM chose for the card.
function Get-FastLlmUiComponentIntro {
    param([string] $Model, [string] $ContextText, [bool] $Chosen)
    $opening = "You chose the $Model setup ($ContextText)."
    if (-not $Chosen) { $opening = "FastLLM's best setup for your card ($Model, $ContextText) needs engine components." }
    return "$opening It needs the components below. Missing ones are downloaded from the sources shown, not from Bitworks. Open each license link, read it, and tick I accept for every missing component to enable Install."
}

# Steps whose CLI reads the automatic-install setting from the install folder: a component install.
function Test-FastLlmUiStepReadsLicenseSetting {
    param([object[]] $Arguments)
    $items = @($Arguments | ForEach-Object { [string] $_ })
    if ($items.Count -eq 0) { return $false }
    if ($items[0] -ceq 'components') { return [bool] ($items -ccontains '-Install') }
    return $false
}

# The status line once the server is ready, with the engine that runs in front. -ApiKeyStore is what is known about the stored key
# (Get-FastLlmApiKeyStoreState), or nothing; the key sentence appears only when the running server proved the key.
function Format-FastLlmUiReadyStatus {
    param($State, $ApiKeyStore)
    $text = 'Ready - API smoke tests passed; GPU residency/performance unqualified.'
    $text = Add-FastLlmUiSpillCheckText -Text $text -State $State
    $text = Add-FastLlmUiApiKeyText -Text $text -State $State -ApiKeyStore $ApiKeyStore
    $engine = Format-FastLlmUiRunEngineLine -State $State
    if ($engine) { return "$engine. $text" }
    return $text
}

# ---- the optional API key: the pure parts of the window ----

# What the window says about the key next to Ready. Nothing unless the status of the running server says apiKey "on" (written only after
# the 401/200 check). When the stored key is a different one than the server was started with (the ids differ), the user is told to restart.
function Get-FastLlmUiApiKeyStatusText {
    param($State, $ApiKeyStore)
    if (-not $State -or -not $State.PSObject.Properties['apiKey'] -or [string] $State.apiKey -cne 'on') { return '' }
    $runningId = ''
    if ($State.PSObject.Properties['apiKeyId']) { $runningId = [string] $State.apiKeyId }
    if ($ApiKeyStore -and $ApiKeyStore.PSObject.Properties['available']) {
        if (-not [bool] $ApiKeyStore.available) { return 'API key on. The stored key cannot be read, so it cannot be shown or copied: create a new key in Settings, then restart.' }
        if ($runningId -and $ApiKeyStore.PSObject.Properties['apiKeyId'] -and [string] $ApiKeyStore.apiKeyId -cne $runningId) { return 'API key on. A new key was created after this start: restart to use the new key.' }
    }
    return 'API key on.'
}

function Add-FastLlmUiApiKeyText {
    param([string] $Text, $State, $ApiKeyStore)
    $keyText = Get-FastLlmUiApiKeyStatusText -State $State -ApiKeyStore $ApiKeyStore
    if ($keyText) { return "$Text $keyText" }
    return $Text
}

# A typed API key failure of a start (the failure code in status.json). Like a typed HIP failure it is shown as its own message, and the
# window does not retry the start.
function Test-FastLlmUiApiKeyFailure {
    param([string] $Code)
    if ([string]::IsNullOrWhiteSpace($Code)) { return $false }
    return [bool] ($Code -cmatch '^api-key-[a-z-]{1,40}$')
}

# The plain text for an API key failure, and whether the window offers the one action that helps: "Create a new key" (when the stored key
# cannot be read, or may have been seen by another program). Nothing is created without that click.
# What the window says when it cannot tell whether the API key is required (api-key-setting-unreadable). The way out is to choose in
# Settings - but Settings cannot save while the settings file is not valid JSON, so the text names that file by its full path and says
# to fix or delete it first. (Deleting it is safe: with a key stored, a missing setting is still "not chosen", never "off".)
function Get-FastLlmUiApiKeySettingText {
    param([string] $SettingsPath)
    $file = 'settings.json in the FastLLM data folder'
    if (-not [string]::IsNullOrWhiteSpace($SettingsPath)) { $file = $SettingsPath }
    return 'FastLLM cannot tell whether the API key is required: a key is stored, and the settings file does not say whether to use it. Nothing was started. If the settings file is not valid JSON, fix or delete it first (' + $file + '). Then open Settings, tick or clear "Require an API key", and save.'
}

function Get-FastLlmUiApiKeyFailure {
    param([string] $Code, [string] $SettingsPath)
    $text = 'The API key could not be used, so FastLLM did not start.'
    $offerNewKey = $false
    switch -CaseSensitive ($Code) {
        'api-key-unavailable' {
            $text = 'The API key is on, but the stored key cannot be read by this Windows user (for example after a moved profile or a restored backup). FastLLM did not start, and it does not start without the key. Create a new key, give it to your apps, then start again.'
            $offerNewKey = $true
        }
        'api-key-not-enforced' { $text = 'The API key is on, but the server did not enforce it, so FastLLM stopped the server. Nothing is running. To run without a key, turn the API key off in Settings.' }
        'api-key-listener-not-verified' { $text = 'FastLLM could not confirm that its own server is the program listening on its port, so it did not send the API key and stopped the server. Close the other program that uses the port, or choose another port in Settings.' }
        'api-key-setting-unreadable' { $text = Get-FastLlmUiApiKeySettingText -SettingsPath $SettingsPath }
        'api-key-listener-changed' {
            $text = 'Right after FastLLM sent a request with the API key, it could no longer confirm that its own server was the program listening on its port. Another program may have received the key, so FastLLM stopped. Create a new key, give it to your apps, then start again.'
            $offerNewKey = $true
        }
        'api-key-invalid' { $text = 'The stored API key is not a valid key. FastLLM did not start. Create a new key, give it to your apps, then start again.'; $offerNewKey = $true }
    }
    return [pscustomobject] [ordered] @{ code = [string] $Code; text = $text; offerNewKey = [bool] $offerNewKey }
}

# The "Require an API key" box in Settings, from the saved setting. When the setting cannot be known (see Get-FastLlmServingSettings) the
# box is neither ticked nor clear: showing it clear would be a claim, and saving it clear would write "off" in place of a lost "on".
function Get-FastLlmUiApiKeyBoxState {
    param($Settings)
    if ($Settings -and $Settings.PSObject.Properties['apiKeyUndetermined'] -and [bool] $Settings.apiKeyUndetermined) { return 'indeterminate' }
    if ($Settings -and $Settings.PSObject.Properties['apiKey'] -and [string] $Settings.apiKey -ceq 'on') { return 'checked' }
    return 'unchecked'
}

# What Save does about the API key, from the saved setting, the box (checked, unchecked, indeterminate) and whether the user touched it:
#   none  nothing is written (the setting is known and the box agrees with it)
#   on    turn the key on        off   turn the key off
#   ask   Save is refused: the setting is not known and the user has not chosen. Nothing is written until they tick or clear the box.
function Get-FastLlmUiApiKeySaveAction {
    param([string] $Current, [bool] $Undetermined, [string] $BoxState, [bool] $Touched)
    if ($BoxState -cne 'checked' -and $BoxState -cne 'unchecked') { return 'ask' }
    if ($Undetermined -and -not $Touched) { return 'ask' }
    if ($BoxState -ceq 'checked') {
        if (-not $Undetermined -and $Current -ceq 'on') { return 'none' }
        return 'on'
    }
    if (-not $Undetermined -and $Current -cne 'on') { return 'none' }
    return 'off'
}

function Get-FastLlmUiApiKeyChoiceText {
    return 'FastLLM cannot tell whether the API key is required: a key is stored, but the saved settings do not say whether to use it. Tick "Require an API key" to use the key, or clear it to run without one, then save. Nothing was saved. (If saving then fails because the settings file is not valid JSON, fix or delete that file first.)'
}

# The question asked before a new key replaces the stored one (the Settings button, and the offer after a failed start).
function Get-FastLlmUiNewKeyConfirmText {
    param([bool] $HasReadableKey)
    if ($HasReadableKey) { return 'Create a new API key? The new key applies at the next start. From then on the current key stops working, and every app that uses it needs the new key.' }
    return 'Create a new API key? The stored key cannot be read, so a new one is the only way to use the key again. Every app needs the new key.'
}

# The API key row of Connect an app, from the connection info, the saved setting and what is known about the stored key. The value shown is
# always the mask: the key itself appears only after Show, and is read from the store at that moment.
function Get-FastLlmUiApiKeyRow {
    param($Info, $Settings, $ApiKeyStore)
    $state = 'off'
    if ($Info -and $Info.PSObject.Properties['apiKey']) { $state = [string] $Info.apiKey }
    $settingOn = [bool] ($Settings -and $Settings.PSObject.Properties['apiKey'] -and [string] $Settings.apiKey -ceq 'on')
    $storeReadable = [bool] ($ApiKeyStore -and $ApiKeyStore.PSObject.Properties['available'] -and [bool] $ApiKeyStore.available)
    $row = [ordered] @{ visible = $false; mask = '********'; canShow = $false; note = '' }
    if ($state -ceq 'on') {
        $row.visible = $true; $row.canShow = $storeReadable
        $row.note = 'This server requires the API key.'
        $runningId = ''
        if ($Info.PSObject.Properties['apiKeyId'] -and $null -ne $Info.apiKeyId) { $runningId = [string] $Info.apiKeyId }
        if (-not $storeReadable) { $row.note = 'This server requires the API key, but the stored key cannot be read, so it cannot be shown or copied. Create a new key in Settings, then restart.' }
        elseif ($runningId -and [string] $ApiKeyStore.apiKeyId -cne $runningId) { $row.note = 'A new key was created after this server started. The key shown and copied here is the new one: restart to use the new key.' }
    }
    elseif ($state -ceq 'on-at-next-start' -or $state -ceq 'starting') {
        $row.visible = $true; $row.canShow = $storeReadable
        $row.note = 'The API key is required from the next start.'
        if ($state -ceq 'starting') { $row.note = 'FastLLM is starting with the API key; it is in use once FastLLM is ready.' }
        if (-not $storeReadable) { $row.note = 'The API key is on, but the stored key cannot be read. FastLLM does not start until you create a new key in Settings.' }
    }
    elseif ($settingOn) {
        $row.note = 'The API key setting is on, but this server was started without it. Restart to use the key.'
    }
    return [pscustomobject] $row
}

# The GPU memory check sentence (from the status block) after the given text. Same plain info text for every state: no colour or style.
# A status without the block (an older run) adds nothing.
function Add-FastLlmUiSpillCheckText {
    param([string] $Text, $State)
    $block = $null
    if ($State -and $State.PSObject.Properties['spillCheck']) { $block = $State.spillCheck }
    $spill = Get-FastLlmSpillCheckText -SpillCheck $block
    if ($spill) { return "$Text $spill" }
    return $Text
}

# The status line for an attached background run: the engine that runs (from status.json) in front of the given text.
function Format-FastLlmUiBackgroundReadyStatus {
    param([string] $Text, $State, $ApiKeyStore)
    $Text = Add-FastLlmUiSpillCheckText -Text $Text -State $State
    $Text = Add-FastLlmUiApiKeyText -Text $Text -State $State -ApiKeyStore $ApiKeyStore
    $engine = Format-FastLlmUiRunEngineLine -State $State
    if ($engine) { return "$engine. $Text" }
    return $Text
}

# What turning on "Install engine components automatically" shows before it is stored: every acceptable license with a link that can be opened from
# here. A license whose link cannot be opened (or no license at all) means the setting cannot be turned on from the window.
function Get-FastLlmUiLicenseDisclosure {
    param([object[]] $Components)
    $links = New-Object 'System.Collections.Generic.List[object]'
    $canAccept = $true
    foreach ($link in @(Get-FastLlmAcceptableLicenseLinks -Components $Components)) {
        $safe = Get-FastLlmUiSafeLicenseUrl -Url ([string] $link.url)
        if (-not $safe) { $canAccept = $false }
        $links.Add([pscustomobject] [ordered] @{ title = [string] $link.title; host = [string] $link.host; url = $safe; linkText = ('{0} ({1})' -f [string] $link.title, [string] $link.host) })
    }
    if ($links.Count -eq 0) { $canAccept = $false }
    return [pscustomobject] [ordered] @{
        links = $links.ToArray()
        identities = @($links.ToArray() | ForEach-Object { [pscustomobject] [ordered] @{ title = $_.title; host = $_.host } })
        canAccept = [bool] $canAccept
    }
}

# The API URL the window shows and copies. A run that is active reports its own port, which may differ from the saved
# setting (the port applies at the next start); otherwise the saved port is what the next start will use. The address is always
# rebuilt on 127.0.0.1 from the parsed port, never copied from the status.
function Get-FastLlmUiApiUrl {
    param($Status,$Settings)
    $runningPort = Get-FastLlmUiRunningPort -Status $Status
    if ($runningPort -ge 1024 -and $runningPort -le 65535) { return 'http://127.0.0.1:' + $runningPort + '/v1' }
    $port = 8080
    if ($Settings -and $Settings.PSObject.Properties['serverPort']) {
        $parsed = 0
        if ([int]::TryParse([string]$Settings.serverPort,[ref]$parsed) -and $parsed -ge 1024 -and $parsed -le 65535) { $port = $parsed }
    }
    return 'http://127.0.0.1:' + $port + '/v1'
}

# The port of a running run's endpoint, or 0 when there is no active run with a usable endpoint.
function Get-FastLlmUiRunningPort {
    param($Status)
    if (-not $Status -or -not $Status.PSObject.Properties['active'] -or -not [bool]$Status.active -or
        -not $Status.PSObject.Properties['endpoint']) { return 0 }
    $uri = $null
    if ([Uri]::TryCreate([string]$Status.endpoint,[UriKind]::Absolute,[ref]$uri)) { return [int]$uri.Port }
    return 0
}

# The built-in chat page of the running server, or $null. Only an active run whose state records chatPage='on' has one; a status written
# before the field existed has none. The page is on the same loopback port as the API, without /v1.
function Get-FastLlmUiChatUrl {
    param($Status)
    if (-not $Status -or -not $Status.PSObject.Properties['chatPage'] -or [string]$Status.chatPage -cne 'on') { return $null }
    $port = Get-FastLlmUiRunningPort -Status $Status
    if ($port -lt 1024 -or $port -gt 65535) { return $null }
    return 'http://127.0.0.1:' + $port + '/'
}

# True while a server this window can see is ready: a window-started (foreground) run whose status says ready, or a background run
# that is active and whose status says ready. Anything else (nothing running, still loading, a stopped run) is false.
function Test-FastLlmUiServingReady {
    param($Status,[bool]$ForegroundChildActive,$BackgroundObservation)
    if (-not $Status -or -not $Status.PSObject.Properties['active'] -or -not [bool]$Status.active) { return $false }
    if (-not $Status.PSObject.Properties['phase'] -or [string]$Status.phase -cne 'ready') { return $false }
    $backgroundActive = [bool]($BackgroundObservation -and $BackgroundObservation.PSObject.Properties['active'] -and [bool]$BackgroundObservation.active)
    return [bool]($ForegroundChildActive -or $backgroundActive)
}

# The Open chat button: enabled, with its address, only while a run (foreground or background) is ready and was started with the chat page on.
function Get-FastLlmUiChatButtonState {
    param($Status,[bool]$ForegroundChildActive,$BackgroundObservation)
    $url = $null
    if (Test-FastLlmUiServingReady -Status $Status -ForegroundChildActive $ForegroundChildActive -BackgroundObservation $BackgroundObservation) {
        $url = Get-FastLlmUiChatUrl -Status $Status
    }
    return @{ url = $url; enabled = [bool]$url }
}

# The hint under a refused Start in background. A refusal from the background state ownership guard is about the folder, not a missing model.
function Get-FastLlmUiBackgroundFailureHint {
    param([string]$Message)
    foreach ($prefix in @('Background state path is not owned by','Background state path grants write access','Unsafe background state path')) {
        if ($Message.StartsWith($prefix, [StringComparison]::Ordinal)) {
            return 'Background mode needs an install and model folder that only your Windows user owns, such as the default folder in your profile. Choose such a folder, then try Start in background again.'
        }
    }
    return 'Background mode needs an already prepared, consented model. Use Install & start first, then Stop and try Start in background.'
}

# Which window actions are usable. A launch or install in progress locks the setup actions, but a ready server (foreground or background)
# does not lock Settings, the API check or the support bundle: those only read, and the check runs as a separate side step.
function Get-FastLlmUiActionAvailability {
    param([bool]$LaunchInProgress,[bool]$Serving,[bool]$SideStepActive,[bool]$BackgroundOccupied)
    return @{
        settings = [bool](-not $LaunchInProgress)
        apiCheck = [bool]($Serving -and -not $SideStepActive)
        saveBundle = [bool](-not $LaunchInProgress -and -not $SideStepActive)
        openLogs = $true
        downloadedModels = $true
        connectApp = $true
    }
}

# The status line when a run ended because it was idle for the set time (the opt-in idle stop). Minutes is the saved setting of that run.
function Get-FastLlmUiIdleStopText {
    param($Minutes)
    $count = 0
    if (-not [int]::TryParse([string]$Minutes,[ref]$count) -or $count -le 0) {
        return 'Stopped after being idle to free GPU memory. Apps get no answer until you start FastLLM again.'
    }
    return 'Stopped after ' + $count + ' min idle to free GPU memory. Apps get no answer until you start FastLLM again.'
}

# The status line when the foreground service ended. An idle stop says why; any other end keeps the plain wording.
function Get-FastLlmUiServiceStoppedText {
    param($Status)
    if ($Status -and $Status.PSObject.Properties['stopReason'] -and [string]$Status.stopReason -ceq 'idle') {
        $minutes = 0
        if ($Status.PSObject.Properties['idleStopMinutes']) { $minutes = $Status.idleStopMinutes }
        return (Get-FastLlmUiIdleStopText -Minutes $minutes)
    }
    return 'Service stopped.'
}

# The status line for a model change, read from the status document's change block ({ from, to, pending, result, failureCode }). '' when the
# document has none (every start that was not asked to change its model) or when the result is one this version does not know. A model id is
# shown only when it has the shape of an id and a failure code only when it has the shape of a code; nothing else from the document is shown.
function Get-FastLlmUiSwitchStatusText {
    param($Status)
    if ($null -eq $Status -or -not $Status.PSObject.Properties['switch']) { return '' }
    $block = $Status.PSObject.Properties['switch'].Value
    if ($null -eq $block -or $block -isnot [System.Management.Automation.PSCustomObject]) { return '' }
    $read = { param([string] $Name) if ($block.PSObject.Properties[$Name]) { return $block.PSObject.Properties[$Name].Value }; return $null }
    $isId = { param($Value) return [bool] ($Value -is [string] -and $Value -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z') }
    $toValue = & $read 'to'
    $fromValue = & $read 'from'
    $toKnown = [bool] (& $isId $toValue)
    $to = 'the other model'
    if ($toKnown) { $to = [string] $toValue }
    $from = 'the previous model'
    $fromStart = 'The previous model'
    if (& $isId $fromValue) { $from = [string] $fromValue; $fromStart = [string] $fromValue }
    $code = 'an unnamed reason'
    $codeValue = & $read 'failureCode'
    if ($codeValue -is [string] -and $codeValue -cmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,63}\z') { $code = [string] $codeValue }
    $result = [string] (& $read 'result')
    if ((& $read 'pending') -eq $true -and -not $result) {
        if ($codeValue) { return "Could not start $to ($code). Starting $from again." }
        if ($Status.PSObject.Properties['phase'] -and [string] $Status.phase -ceq 'ready') { return "Switching to $to when the requests in progress have finished." }
        return "Switching to $to."
    }
    $keeps = "$fromStart keeps running."
    switch -CaseSensitive ($result) {
        'ok' { return "Switched to $to." }
        'refused-busy' { return "Did not switch to ${to}: FastLLM was still answering requests. $keeps" }
        'failed-restored' { return "Could not start $to ($code). $fromStart was started again and is running." }
        'failed-stopped' { return "Could not start $to ($code), and $from could not be started again. FastLLM is stopped." }
        'refused' {
            switch -CaseSensitive ($code) {
                'switch-target-not-installed' { return "Did not switch: $to is not downloaded. $keeps" }
                'switch-target-size-mismatch' { return "Did not switch: the file of $to is incomplete or damaged. $keeps" }
                'switch-target-no-consent' { return "Did not switch: the license of $to has not been accepted on this PC. $keeps" }
                'switch-target-already-serving' { return "$to is already running." }
                'switch-target-unknown' { return "Did not switch: the requested model is not in FastLLM's list. $keeps" }
                'switch-target-experimental-model' { return "Did not switch: an experimental model is started from the command line, not by a switch. $keeps" }
                'switch-recipe-experimental' { return "Did not switch: an experimental setup is started from the command line, not by a switch. $keeps" }
                'switch-recipe-needs-default-options' { return "Did not switch: a measured setup needs the default context profile and one request at a time. $keeps" }
                'switch-cancelled-by-stop' { return "The switch to $to was cancelled by Stop." }
                'switch-request-invalid' { return "Did not switch: the request could not be read. $keeps" }
                'switch-request-unsafe' { return "Did not switch: the request could not be read. $keeps" }
                'switch-request-too-large' { return "Did not switch: the request could not be read. $keeps" }
                default { return "Did not switch to $to ($code). $keeps" }
            }
        }
    }
    return ''
}

# The status line after Settings is saved. While a run is going, a changed value applies at the next start.
# The idle stop is read tolerantly: a caller that has no such value means no change.
function Get-FastLlmUiSettingsSavedNote {
    param([bool]$RunActive,$Before,$After)
    if ($RunActive) {
        if ([int]$After.serverPort -ne [int]$Before.serverPort) { return 'The new port applies at the next start.' }
        if ([string]$After.thinking -cne [string]$Before.thinking) { return 'The new thinking setting applies at the next start.' }
        if ([string]$After.chatPage -cne [string]$Before.chatPage) { return 'The new chat page setting applies at the next start.' }
        $beforeIdle = if ($Before.PSObject.Properties['idleStopMinutes']) { [string]$Before.idleStopMinutes } else { '0' }
        $afterIdle = if ($After.PSObject.Properties['idleStopMinutes']) { [string]$After.idleStopMinutes } else { '0' }
        if ($afterIdle -cne $beforeIdle) { return 'The new idle stop setting applies at the next start.' }
        # The API key is read tolerantly too: a caller that has no such value means no change.
        $beforeKey = if ($Before.PSObject.Properties['apiKey']) { [string]$Before.apiKey } else { 'off' }
        $afterKey = if ($After.PSObject.Properties['apiKey']) { [string]$After.apiKey } else { $beforeKey }
        if ($afterKey -cne $beforeKey) { return 'The new API key setting applies at the next start.' }
        $beforeSwitch = [bool] ($Before.PSObject.Properties['allowSwitch'] -and $Before.allowSwitch -eq $true)
        $afterSwitch = [bool] ($After.PSObject.Properties['allowSwitch'] -and $After.allowSwitch -eq $true)
        if ($afterSwitch -ne $beforeSwitch) { return 'The new switching setting applies at the next start.' }
    }
    return 'Settings saved.'
}

# Shown when the user turns the chat page off. The browser may keep the page's cached files for the address, so the fix is on the browser side.
function Get-FastLlmUiChatPageOffNote {
    param([int]$Port)
    return "If the chat page still appears after you turn it off, clear the browser's site data for 127.0.0.1:" + $Port + '.'
}

# The background start request. A malformed settings file reads as defaults (the caller shows the notice); start still works.
function New-FastLlmUiBackgroundRequest {
    param([Parameter(Mandatory=$true)][string]$SourceRoot,[Parameter(Mandatory=$true)][string]$InstallRoot,
          $ModelId,[int]$ContextSize,[string]$BarMitigation,[Parameter(Mandatory=$true)]$Settings,[bool]$AllowSwitch=$false,
          # The saved context profile, requests at once and embeddings, as Get-FastLlmServingHostArguments resolves them (the one resolution,
          # shared with the sign-in start). Only a non-default value is in it, and only a non-default value reaches the request.
          [System.Collections.IDictionary]$ServingArguments=$null)
    $port = 8080
    if ($Settings -and $Settings.PSObject.Properties['serverPort']) {
        $parsed = 0
        if ([int]::TryParse([string]$Settings.serverPort,[ref]$parsed) -and $parsed -ge 1024 -and $parsed -le 65535) { $port = $parsed }
    }
    # Thinking is read tolerantly: only a stored 'off' is carried; absent or anything else is auto.
    $thinking = 'auto'
    if ($Settings -and $Settings.PSObject.Properties['thinking'] -and [string]$Settings.thinking -ceq 'off') { $thinking = 'off' }
    $chatPage = 'off'
    if ($Settings -and $Settings.PSObject.Properties['chatPage'] -and [string]$Settings.chatPage -ceq 'on') { $chatPage = 'on' }
    # The idle stop is read tolerantly too: only 15, 30 or 60 (a whole number) is carried; anything else is 0 (never).
    $idleStop = 0
    if ($Settings -and $Settings.PSObject.Properties['idleStopMinutes'] -and ($Settings.idleStopMinutes -is [int] -or $Settings.idleStopMinutes -is [long]) -and @(15,30,60) -contains [int]$Settings.idleStopMinutes) { $idleStop = [int]$Settings.idleStopMinutes }
    # The API key is NOT read tolerantly: when the flag cannot be known the request is refused (nothing is started), and only the exact
    # saved "on" asks for the key. The request carries the flag only, never a key.
    if ($Settings -and $Settings.PSObject.Properties['apiKeyUndetermined'] -and [bool]$Settings.apiKeyUndetermined) {
        $undetermined = New-Object -TypeName System.InvalidOperationException -ArgumentList ('api-key-setting-unreadable: ' + (Get-FastLlmUiApiKeySettingText -SettingsPath (Join-Path $InstallRoot 'settings.json')))
        $undetermined.Data['FastLlmFailureCode'] = 'api-key-setting-unreadable'
        throw $undetermined
    }
    $apiKey = 'off'
    if ($Settings -and $Settings.PSObject.Properties['apiKey'] -and [string]$Settings.apiKey -ceq 'on') { $apiKey = 'on' }
    $request = [pscustomobject]@{sourceRoot=$SourceRoot;installRoot=$InstallRoot;profile='balanced';
        modelId=$ModelId;contextSize=$ContextSize;vulkanBarMitigation=$BarMitigation;serverPort=$port;thinking=$thinking;chatPage=$chatPage;idleStopMinutes=$idleStop;apiKey=$apiKey}
    # Present only when not the default, so a default request is the object it always was.
    if ($null -ne $ServingArguments) {
        if ($ServingArguments.Contains('KvContextProfile')) { $request | Add-Member -NotePropertyName contextProfile -NotePropertyValue ([string]$ServingArguments['KvContextProfile']) }
        if ($ServingArguments.Contains('KvSlots')) { $request | Add-Member -NotePropertyName slots -NotePropertyValue ([int]$ServingArguments['KvSlots']) }
        if ($ServingArguments.Contains('Embeddings')) {
            $request | Add-Member -NotePropertyName embeddings -NotePropertyValue ([string]$ServingArguments['Embeddings'])
            $request | Add-Member -NotePropertyName embeddingPort -NotePropertyValue ([int]$ServingArguments['EmbeddingPort'])
        }
    }
    # Opt-in model switching: the field exists only when the setting is on, so a default request is the object it always was.
    if ($AllowSwitch) { $request | Add-Member -NotePropertyName allowSwitch -NotePropertyValue $true }
    return $request
}

# The parameters of Start-FastLlmBackgroundHost that the saved context profile, slots and embeddings in a window request stand for (none for a default request).
function Get-FastLlmUiBackgroundServingArguments {
    param([Parameter(Mandatory=$true)]$Request)
    $arguments=@{}
    if ($Request.PSObject.Properties['contextProfile']) { $arguments.KvContextProfile=[string]$Request.contextProfile }
    if ($Request.PSObject.Properties['slots']) { $arguments.KvSlots=[int]$Request.slots }
    if ($Request.PSObject.Properties['embeddings']) {
        $arguments.Embeddings=[string]$Request.embeddings
        if ($Request.PSObject.Properties['embeddingPort']) { $arguments.EmbeddingPort=[int]$Request.embeddingPort }
    }
    return $arguments
}

function Get-FastLlmUiMalformedSettingsNotice {
    param($Settings)
    if ($Settings -and $Settings.PSObject.Properties['malformed'] -and [bool]$Settings.malformed) {
        return 'settings.json is not valid JSON, so FastLLM is using the default settings. Fix or delete the file to change settings.'
    }
    return ''
}

# ---- Save support bundle: the pure parts (the default file name and the text of the list-before-save dialog) ----

function Get-FastLlmUiSupportBundleFileName {
    param([Parameter(Mandatory = $true)][DateTime] $Now)
    return ('FastLLM-support-{0}.zip' -f $Now.ToString('yyyyMMdd-HHmm', [Globalization.CultureInfo]::InvariantCulture))
}

# The text of the dialog shown before anything is saved: every entry with its size, the redaction count, and the plain statement that the
# bundle stays on this PC. $Listing is the parsed `doctor -SupportBundle <path> -ListOnly` output ({ entries: [{name,sizeBytes}], redactions }).
function Format-FastLlmUiSupportBundleList {
    param([Parameter(Mandatory = $true)] $Listing)
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('The support bundle will contain these files:')
    $lines.Add('')
    foreach ($entry in @($Listing.entries)) {
        $kib = [Math]::Max(1, [int][Math]::Ceiling([double] $entry.sizeBytes / 1024))
        $lines.Add(('  {0}  ({1} KiB)' -f [string] $entry.name, $kib))
    }
    $lines.Add('')
    $lines.Add(('{0} item(s) that identify this PC or you (your user name, computer name, profile folder, hardware serial-style ids) were replaced with placeholders.' -f [int] $Listing.redactions))
    $lines.Add('The bundle is saved only where you choose. FastLLM does not upload it or send it anywhere; share it only with people you trust. It never contains prompts, answers or chat text.')
    return ($lines -join [Environment]::NewLine)
}

# ---- the window's model switch: the gap between two runs, the switch line, the Switch model button and the picker dialog ----

$script:FastLlmUiSwitchSettingText = 'Turn on ''Allow switching models'' in Settings; it applies from the next start.'

# How the window reads a run's status for a model switch. Pure. Returns
#   gap                  $true between the old server stopping and the next run's first write: the document is stopped or failed and says the
#                        switch is pending (and a supervisor is alive). The window then shows statusText (the existing switch text) instead of
#                        an unverifiable occupied installation.
#   stopEnabled          $true in the gap: Stop stays enabled there, because stop always wins
#   startEnabled         $false in the gap (Start stays disabled); otherwise this classification does not restrict it
#   statusText           the switch text in the gap, else ''
#   line                 the switch text to show under a serving status: only for a run that allows switching, whenever its document has a
#                        switch block (the gap excluded)
#   switchButtonEnabled  the Switch model button: only for a live run that is ready, allows switching and has no switch pending
#   switchButtonReason   why it is disabled ('' when enabled)
function Get-FastLlmUiSwitchWindowState {
    param($Status, [bool] $SettingOn = $false)
    $result = [ordered] @{ gap = $false; stopEnabled = $false; startEnabled = $true; statusText = ''; line = ''; switchButtonEnabled = $false; switchButtonReason = '' }
    $read = { param($Object, [string] $Name) if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.PSObject.Properties[$Name].Value }; return $null }
    $alive = [bool] ($null -ne $Status -and -not ($Status.PSObject.Properties['active'] -and $Status.active -eq $false))
    $phase = [string] (& $read $Status 'phase')
    $switchAllowed = [bool] ((& $read $Status 'switchAllowed') -eq $true)
    $block = & $read $Status 'switch'
    $hasBlock = [bool] ($block -is [System.Management.Automation.PSCustomObject])
    $pending = [bool] ($hasBlock -and (& $read $block 'pending') -eq $true -and -not (& $read $block 'result'))
    if ($alive -and $pending -and ($phase -ceq 'stopped' -or $phase -ceq 'failed')) {
        $result.gap = $true
        $result.stopEnabled = $true
        $result.startEnabled = $false
        $result.statusText = Get-FastLlmUiSwitchStatusText -Status $Status
        $result.switchButtonReason = 'A model switch is under way.'
        return [pscustomobject] $result
    }
    if ($alive -and $switchAllowed -and $hasBlock) { $result.line = Get-FastLlmUiSwitchStatusText -Status $Status }
    $ready = [bool] ($alive -and $phase -ceq 'ready')
    if ($ready -and $switchAllowed -and $pending) { $result.switchButtonReason = 'A model switch is already under way.' }
    elseif ($ready -and $switchAllowed) { $result.switchButtonEnabled = $true }
    elseif ($ready) {
        if ($SettingOn) { $result.switchButtonReason = 'This run was started before switching was turned on. Stop FastLLM and start it again to switch models.' }
        else { $result.switchButtonReason = $script:FastLlmUiSwitchSettingText }
    }
    elseif ($alive -and $switchAllowed -and @('preparing', 'loading', 'checking') -ccontains $phase) { $result.switchButtonReason = 'You can switch models once FastLLM is ready.' }
    elseif ($SettingOn) { $result.switchButtonReason = 'Start FastLLM to switch models.' }
    else { $result.switchButtonReason = $script:FastLlmUiSwitchSettingText }
    return [pscustomobject] $result
}

# The picker's list items from the module's rows: { id, text, canSwitch }. Only a model that fits, or whose fit is checked at the switch, can be picked.
function Get-FastLlmUiSwitchPickerItems {
    param($Rows)
    $items = New-Object System.Collections.ArrayList
    foreach ($row in @($Rows)) {
        if ($null -eq $row) { continue }
        $id = [string] $row.id
        $name = [string] $row.displayName
        if ([string]::IsNullOrWhiteSpace($name)) { $name = $id }
        [void] $items.Add([pscustomobject] [ordered] @{ id = $id; text = ($name + '  -  ' + [string] $row.reason); canSwitch = [bool] (@('fits', 'check-at-switch') -ccontains [string] $row.state) })
    }
    return @($items)
}

# Whether the Switch button of the picker is enabled for the selected item.
function Get-FastLlmUiSwitchPickerButtonState {
    param($Items, $SelectedId)
    $enabled = $false
    if ($SelectedId -is [string] -and $SelectedId) {
        $match = @(@($Items) | Where-Object { [string] $_.id -ceq $SelectedId } | Select-Object -First 1)
        if ($match.Count -eq 1 -and $match[0].canSwitch -eq $true) { $enabled = $true }
    }
    return [pscustomobject] @{ enabled = $enabled }
}

# One line of plain text from an exception message (no control characters, at most 400 characters).
function ConvertTo-FastLlmUiOneLine {
    param([string] $Text)
    $line = [regex]::Replace([string] $Text, '[\x00-\x1f\x7f]', ' ')
    if ($line.Length -gt 400) { $line = $line.Substring(0, 400) }
    return $line
}

# The picker's rows as dialog items, computed once when the dialog opens. A failure is a message, never a throw. -RowsProvider is a test seam.
function Get-FastLlmUiSwitchPickerModel {
    param([Parameter(Mandatory = $true)][string] $InstallRoot, [Parameter(Mandatory = $true)][string] $CatalogPath, $Status, [scriptblock] $RowsProvider)
    try {
        if ($null -eq $RowsProvider) { $RowsProvider = { param($InstallRoot, $CatalogPath, $Status) return (Get-FastLlmSwitchPickerRows -InstallRoot $InstallRoot -CatalogPath $CatalogPath -Status $Status) } }
        $rows = @(& $RowsProvider $InstallRoot $CatalogPath $Status)
        return [pscustomobject] @{ items = @(Get-FastLlmUiSwitchPickerItems -Rows $rows); message = '' }
    }
    catch { return [pscustomobject] @{ items = @(); message = 'The model list could not be read: ' + (ConvertTo-FastLlmUiOneLine -Text $_.Exception.Message) } }
}

# What the picker's Switch button does: asks the running supervisor for the switch (Request-FastLlmSwitch, with no Force: a busy refusal shows its
# text and the user tries again). Everything the request function prints is dropped, every throw becomes the message of the result, and only a
# row that can be switched to makes a request. Returns { ok, text }. -Request is a test seam.
function Invoke-FastLlmUiSwitchPick {
    param([Parameter(Mandatory = $true)][string] $InstallRoot, [Parameter(Mandatory = $true)][string] $CatalogPath, $Items, [string] $ModelId, [scriptblock] $Request)
    $item = $null
    if ($ModelId) { $item = @(@($Items) | Where-Object { [string] $_.id -ceq $ModelId -and $_.canSwitch -eq $true } | Select-Object -First 1) }
    if ($null -eq $item -or $item.Count -ne 1) { return [pscustomobject] @{ ok = $false; text = 'That model cannot be switched to from here.' } }
    if ($null -eq $Request) { $Request = { param($InstallRoot, $CatalogPath, $ModelId) Request-FastLlmSwitch -InstallRoot $InstallRoot -CatalogPath $CatalogPath -ModelId $ModelId } }
    $name = [string] $ModelId
    $itemText = [string] $item[0].text
    $separator = $itemText.IndexOf('  -  ', [StringComparison]::Ordinal)
    if ($separator -gt 0) { $name = $itemText.Substring(0, $separator) }
    try {
        & $Request $InstallRoot $CatalogPath $ModelId 6>$null 5>$null 4>$null 3>$null | Out-Null
        return [pscustomobject] @{ ok = $true; text = "Switch to $name requested. FastLLM finishes the requests in progress, stops the current model and starts the other one; this takes about one model load." }
    }
    catch { return [pscustomobject] @{ ok = $false; text = (ConvertTo-FastLlmUiOneLine -Text $_.Exception.Message) } }
}

