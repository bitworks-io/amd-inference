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
