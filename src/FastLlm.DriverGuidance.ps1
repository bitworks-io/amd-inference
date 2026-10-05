#requires -Version 5.1
# Read-only, guidance-only AMD driver catalog. No download, install, or GPU/PnP join.
Set-StrictMode -Version 2

function ConvertTo-FastLlmDriverModelKey {
    param([AllowNull()][string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    $plain = [regex]::Replace($Name, '(?i)\(TM\)|[™®]', '')
    return ([regex]::Replace($plain.ToUpperInvariant(), '[^A-Z0-9]+', ' ')).Trim()
}

function Assert-FastLlmDriverGuidanceDate {
    param([string]$Value, [string]$Field)
    if ($Value -cnotmatch '^\d{4}-\d{2}-\d{2}$') { throw "Invalid driver guidance date: $Field." }
    try { [datetime]::ParseExact($Value, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) | Out-Null }
    catch { throw "Invalid driver guidance date: $Field." }
}

function Assert-FastLlmOfficialAmdUrl {
    param([string]$Value, [string]$Field)
    $uri = $null
    if (-not [uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -cne 'https' -or
        $uri.Host -notin @('www.amd.com', 'amd.com') -or
        -not [string]::IsNullOrEmpty($uri.UserInfo) -or
        -not $uri.IsDefaultPort -or
        -not [string]::IsNullOrEmpty($uri.Fragment) -or
        -not [string]::IsNullOrEmpty($uri.Query) -or
        $uri.AbsolutePath -notmatch '^/en/(support|resources/support-articles)/') {
        throw "Driver guidance has a non-official AMD URL: $Field."
    }
}

function Import-FastLlmDriverGuidanceCatalog {
    [CmdletBinding()]
    param([string]$Path = (Join-Path $PSScriptRoot '../config/driver-guidance.json'))
    $file = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($file.PSIsContainer -or -not ($file -is [IO.FileInfo]) -or
        ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        $file.Length -lt 1 -or $file.Length -gt 131072) {
        throw 'Driver guidance must be a nonempty regular file of at most 128 KiB, not a reparse point.'
    }
    $data = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($data.schemaVersion -ne 1 -or $data.status -cne 'guidance-only-unqualified' -or
        $data.automaticDriverInstall -ne $false -or $null -eq $data.models -or @($data.models).Count -eq 0) {
        throw 'Invalid driver guidance schema or policy.'
    }
    Assert-FastLlmDriverGuidanceDate -Value $data.asOf -Field 'asOf'
    $ids = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $keys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($model in @($data.models)) {
        if ([string]::IsNullOrWhiteSpace($model.id) -or -not $ids.Add($model.id) -or
            $model.installerFamily -notin @('adrenalin', 'pro') -or $null -eq $model.names -or @($model.names).Count -eq 0) {
            throw 'Invalid or duplicate driver guidance model.'
        }
        Assert-FastLlmOfficialAmdUrl -Value $model.productUrl -Field "$($model.id).productUrl"
        foreach ($name in @($model.names)) {
            $key = ConvertTo-FastLlmDriverModelKey $name
            if (-not $key -or -not $keys.Add($key)) { throw 'Ambiguous driver guidance model name.' }
        }
        foreach ($kind in @('recommended', 'optional')) {
            $package = $model.$kind
            if ($null -eq $package) {
                if ($kind -eq 'recommended') { throw 'Driver guidance recommended package is missing.' }
                continue
            }
            if ([string]::IsNullOrWhiteSpace($package.name) -or [string]::IsNullOrWhiteSpace($package.channel) -or
                $package.driverStoreVersion -notmatch '^\d+(\.\d+){3}$') {
                throw "Invalid driver guidance package: $($model.id).$kind."
            }
            Assert-FastLlmDriverGuidanceDate -Value $package.releaseDate -Field "$($model.id).$kind.releaseDate"
            Assert-FastLlmOfficialAmdUrl -Value $package.notesUrl -Field "$($model.id).$kind.notesUrl"
        }
    }
    return $data
}

function Get-FastLlmDriverGuidance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$GpuName,
        [AllowNull()][string]$PnpDriverVersion,
        [ValidateSet('desktop', 'dedicated-inference')][string]$DeploymentType = 'desktop',
        [ValidateSet('Auto', 'Minimal', 'DriverOnly')][string]$UserInstallModeChoice = 'Auto',
        [string]$GuidanceFile = (Join-Path $PSScriptRoot '../config/driver-guidance.json')
    )
    $data = Import-FastLlmDriverGuidanceCatalog -Path $GuidanceFile
    $key = ConvertTo-FastLlmDriverModelKey $GpuName
    $matching = @($data.models | Where-Object {
        $candidate = $_
        @($candidate.names | Where-Object { (ConvertTo-FastLlmDriverModelKey $_) -ceq $key }).Count -gt 0
    })
    if ($matching.Count -gt 1) { throw 'Ambiguous driver guidance model match.' }
    $model = if ($matching.Count -eq 1) { $matching[0] } else { $null }
    $mode = if ($UserInstallModeChoice -ne 'Auto') { $UserInstallModeChoice }
            elseif ($DeploymentType -eq 'dedicated-inference') { 'DriverOnly' }
            else { 'Minimal' }
    $modeReason = if ($UserInstallModeChoice -ne 'Auto') { 'Explicit operator choice; no TPS benefit is implied.' }
                  elseif ($DeploymentType -eq 'dedicated-inference') { 'Driver Only omits the Adrenalin feature UI on a dedicated inference host; no TPS benefit is implied.' }
                  else { 'Minimal retains basic Adrenalin controls on a desktop; no TPS benefit is implied.' }
    if ($null -ne $model -and $model.installerFamily -eq 'pro') {
        $mode = 'installer-dependent'
        $modeReason = 'The R9700 product page presents PRO Edition. Verify available install modes in that AMD installer; Adrenalin mode choices are not assumed for PRO.'
    } elseif ($null -eq $model) {
        $mode = 'unknown'
        $modeReason = 'No exact AMD focus-model catalog match; no product-specific installer mode can be recommended.'
    }
    $hasReportedPnpVersion = -not [string]::IsNullOrWhiteSpace($PnpDriverVersion)
    $validPnpVersion = $hasReportedPnpVersion -and $PnpDriverVersion -cmatch '^[0-9]{1,5}(\.[0-9]{1,5}){3}$'
    $modelNote = if ($null -eq $model) { 'No exact AMD focus-model guidance entry; use the AMD product selector.' }
                 elseif ($model.PSObject.Properties['note']) { $model.note }
                 else { $null }
    $modelId = $null
    $productUrl = $null
    $installerFamily = $null
    $recommended = $null
    $optional = $null
    if ($null -ne $model) {
        $modelId = $model.id
        $productUrl = $model.productUrl
        $installerFamily = $model.installerFamily
        $recommended = $model.recommended
        $optional = $model.optional
    }
    $reportedVersion = $null
    if ($validPnpVersion) { $reportedVersion = $PnpDriverVersion }
    $versionAssessment = 'unknown-no-pnp-version'
    if ($hasReportedPnpVersion) {
        $versionAssessment = 'unknown-invalid-pnp-version'
        if ($validPnpVersion) { $versionAssessment = 'unknown-unmatched-pnp-to-serving-adapter' }
    }
    $modelAssessment = 'unknown-unmatched-focus-model'
    if ($null -ne $model) { $modelAssessment = 'exact-catalog-name-only-not-hardware-verified' }
    return [pscustomobject]@{
        schemaVersion = 1
        asOf = $data.asOf
        qualification = $false
        automaticDriverInstall = $false
        inputGpuName = $GpuName
        knownFocusModel = ($null -ne $model)
        modelId = $modelId
        modelAssessment = $modelAssessment
        productUrl = $productUrl
        installerFamily = $installerFamily
        recommended = $recommended
        optional = $optional
        reportedPnpDriverVersion = $reportedVersion
        hasOwnTrustedMapping = $false
        driverVersionAssessment = $versionAssessment
        suggestedInstallMode = $mode
        installModeReason = $modeReason
        driverAction = 'guidance-only-no-download-or-install'
        note = $modelNote
    }
}

function Get-FastLlmInventoryDriverGuidance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][object]$WindowsInventory,
        [ValidateSet('desktop', 'dedicated-inference')][string]$DeploymentType = 'desktop',
        [ValidateSet('Auto', 'Minimal', 'DriverOnly')][string]$UserInstallModeChoice = 'Auto',
        [string]$GuidanceFile = (Join-Path $PSScriptRoot '../config/driver-guidance.json')
    )
    # PnP entries are intentionally not correlated to DXGI or serving-engine adapters.
    $entries = @()
    if ($WindowsInventory.PSObject.Properties['pnpDisplayDevices']) {
        $entries = @($WindowsInventory.pnpDisplayDevices)
    }
    foreach ($entry in $entries) {
        if ($null -eq $entry) { continue }
        $description = ''
        $instanceId = $null
        $version = $null
        if ($entry.PSObject.Properties['Description']) { $description = [string]$entry.Description }
        if ($entry.PSObject.Properties['InstanceId']) { $instanceId = [string]$entry.InstanceId }
        if ($entry.PSObject.Properties['DriverVersion']) { $version = [string]$entry.DriverVersion }
        $guidance = Get-FastLlmDriverGuidance -GpuName $description -PnpDriverVersion $version `
            -DeploymentType $DeploymentType -UserInstallModeChoice $UserInstallModeChoice -GuidanceFile $GuidanceFile
        $guidance | Add-Member -NotePropertyName source -NotePropertyValue 'pnp-display-name-only'
        $guidance | Add-Member -NotePropertyName sourceInstanceId -NotePropertyValue $instanceId
        Write-Output $guidance
    }
}
