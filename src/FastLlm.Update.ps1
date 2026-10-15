# Update check: versions, settings, ETag, a 24 h limit and channels.
# Dot-sourced by the entry scripts only; NEVER by FastLlm.psm1 (the producer stays vnext.3 with 31 inputs).
# Silent on failure: a failed check never writes state and never throws.
Set-StrictMode -Version 2.0

if (-not (Get-Command Move-FastLlmFileReplacing -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'FastLlm.FileReplace.ps1')
}

$script:FastLlmReleaseApiBase = 'https://api.github.com/repos/bitworks-io/amd-inference/releases'
$script:FastLlmAssetUrlPrefix = 'https://github.com/bitworks-io/amd-inference/releases/download/'

function Get-FastLlmUpdateProp {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] }; return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertFrom-FastLlmReleaseTag {
    param([string]$Tag)
    if ([string]::IsNullOrEmpty($Tag)) { return $null }
    $m = [regex]::Match($Tag, '^v(\d{4})\.(\d{2})\.(\d{2})\.([1-9]\d{0,3})(-canary)?$')
    if (-not $m.Success) { return $null }
    $numbers = [int[]]@([int]$m.Groups[1].Value, [int]$m.Groups[2].Value, [int]$m.Groups[3].Value, [int]$m.Groups[4].Value)
    $channel = 'stable'
    if ($m.Groups[5].Success) { $channel = 'canary' }
    return [pscustomobject]@{
        version = ('{0}.{1}.{2}.{3}' -f $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value, $m.Groups[4].Value)
        numbers = $numbers
        channel = $channel
    }
}

function ConvertTo-FastLlmVersionNumbers {
    param([string]$Version)
    $m = [regex]::Match([string]$Version, '^(\d{4})\.(\d{2})\.(\d{2})\.([1-9]\d{0,3})$')
    if (-not $m.Success) { return $null }
    return [int[]]@([int]$m.Groups[1].Value, [int]$m.Groups[2].Value, [int]$m.Groups[3].Value, [int]$m.Groups[4].Value)
}

function Compare-FastLlmVersion {
    param([string]$A, [string]$B)
    $left = ConvertTo-FastLlmVersionNumbers $A
    $right = ConvertTo-FastLlmVersionNumbers $B
    if ($null -eq $left -or $null -eq $right) { throw 'Compare-FastLlmVersion: a version is not YYYY.MM.DD.N.' }
    for ($i = 0; $i -lt 4; $i++) {
        if ($left[$i] -lt $right[$i]) { return -1 }
        if ($left[$i] -gt $right[$i]) { return 1 }
    }
    return 0
}

function Read-FastLlmInstalledRelease {
    param([string]$AppRoot)
    try {
        $path = Join-Path $AppRoot 'RELEASE.json'
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
        $stored = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $version = [string](Get-FastLlmUpdateProp $stored 'version')
        if ($null -eq (ConvertTo-FastLlmVersionNumbers $version)) { return $null }
        $installedChannel = [string](Get-FastLlmUpdateProp $stored 'channel')
        if (@('stable', 'canary') -cnotcontains $installedChannel) { $installedChannel = 'stable' }
        return [pscustomobject]@{ version = $version; channel = $installedChannel }
    }
    catch { return $null }
}

function Read-FastLlmSettingsObject {
    param([string]$InstallRoot)
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

function Get-FastLlmUpdateSettings {
    param([Parameter(Mandatory = $true)][string]$InstallRoot, [string]$AppRoot)
    $defaultChannel = 'stable'
    if (-not [string]::IsNullOrEmpty($AppRoot)) {
        $release = Read-FastLlmInstalledRelease -AppRoot $AppRoot
        if ($null -ne $release) { $defaultChannel = $release.channel }
    }
    $stored = Read-FastLlmSettingsObject -InstallRoot $InstallRoot
    $check = 'on'
    $channelValue = $defaultChannel
    if ($stored.Contains('updateCheck') -and (@('on', 'off') -ccontains [string]$stored['updateCheck'])) { $check = [string]$stored['updateCheck'] }
    if ($stored.Contains('updateChannel') -and (@('stable', 'canary') -ccontains [string]$stored['updateChannel'])) { $channelValue = [string]$stored['updateChannel'] }
    return @{ updateCheck = $check; updateChannel = $channelValue }
}

function Set-FastLlmUpdateSettings {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [ValidateSet('on', 'off')][string]$UpdateCheck,
        [ValidateSet('stable', 'canary')][string]$UpdateChannel
    )
    $merged = Read-FastLlmSettingsObject -InstallRoot $InstallRoot
    if ($PSBoundParameters.ContainsKey('UpdateCheck')) { $merged['updateCheck'] = $UpdateCheck }
    if ($PSBoundParameters.ContainsKey('UpdateChannel')) { $merged['updateChannel'] = $UpdateChannel }
    if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) { New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null }
    $path = Join-Path $InstallRoot 'settings.json'
    $temporary = "$path.tmp-$([guid]::NewGuid().ToString('N'))"
    [IO.File]::WriteAllText($temporary, (([pscustomobject]$merged) | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    Move-FastLlmFileReplacing -Source $temporary -Destination $path
}

function Invoke-FastLlmUpdateHttp {
    param([string]$Url, [string]$Etag)
    $headers = @{ 'User-Agent' = 'Bitworks-FastLLM'; 'Accept' = 'application/vnd.github+json' }
    if (-not [string]::IsNullOrEmpty($Etag)) { $headers['If-None-Match'] = $Etag }
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 10 -Headers $headers
    }
    catch {
        $failure = $_.Exception
        $failedResponse = $null
        if ($failure.PSObject.Properties['Response']) { $failedResponse = $failure.Response }
        if ($null -ne $failedResponse -and [string]$failedResponse.StatusCode -ceq 'NotModified') {
            return @{ Status = 304; Body = ''; Etag = $Etag }
        }
        throw
    }
    $responseEtag = $null
    if ($null -ne $response.Headers -and $response.Headers['ETag']) { $responseEtag = [string]@($response.Headers['ETag'])[0] }
    return @{ Status = [int]$response.StatusCode; Body = [string]$response.Content; Etag = $responseEtag }
}

function ConvertTo-FastLlmUpdateLatest {
    param($Release, $Parsed)
    $assets = @{}
    foreach ($asset in @(Get-FastLlmUpdateProp $Release 'assets')) {
        $name = [string](Get-FastLlmUpdateProp $asset 'name')
        $url = [string](Get-FastLlmUpdateProp $asset 'browser_download_url')
        if ([string]::IsNullOrEmpty($name) -or -not $url.StartsWith($script:FastLlmAssetUrlPrefix, [StringComparison]::Ordinal)) { continue }
        $size = 0
        try { $size = [int64](Get-FastLlmUpdateProp $asset 'size') } catch { $size = 0 }
        $assets[$name] = @{ url = $url; size = $size }
    }
    return @{
        version = $Parsed.version
        tag     = [string](Get-FastLlmUpdateProp $Release 'tag_name')
        channel = $Parsed.channel
        htmlUrl = [string](Get-FastLlmUpdateProp $Release 'html_url')
        assets  = $assets
    }
}

# Highest eligible release in a parsed response. Stable accepts only non-draft, non-prerelease stable tags; canary accepts any valid non-draft tag.
function Select-FastLlmLatestRelease {
    param($Parsed, [string]$Channel)
    if ($Channel -ceq 'stable') {
        if ($null -eq (Get-FastLlmUpdateProp $Parsed 'tag_name')) { throw 'not-a-release-object' }
        $items = @($Parsed)
    }
    else {
        if ($Parsed -isnot [array] -and $null -eq (Get-FastLlmUpdateProp $Parsed 'tag_name')) { throw 'not-a-release-list' }
        $items = @($Parsed)
    }
    $best = $null
    $bestParsed = $null
    foreach ($item in $items) {
        if ($null -eq $item) { continue }
        if ((Get-FastLlmUpdateProp $item 'draft') -eq $true) { continue }
        $tagInfo = ConvertFrom-FastLlmReleaseTag ([string](Get-FastLlmUpdateProp $item 'tag_name'))
        if ($null -eq $tagInfo) { continue }
        if ($Channel -ceq 'stable' -and ($tagInfo.channel -cne 'stable' -or (Get-FastLlmUpdateProp $item 'prerelease') -eq $true)) { continue }
        if ($null -eq $best -or (Compare-FastLlmVersion $tagInfo.version $bestParsed.version) -gt 0) { $best = $item; $bestParsed = $tagInfo }
    }
    if ($null -eq $best) { return $null }
    return ConvertTo-FastLlmUpdateLatest -Release $best -Parsed $bestParsed
}

function ConvertTo-FastLlmUtcDate {
    param($Value)
    if ($null -eq $Value) { return $null }
    try {
        if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
        return [datetime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]'AdjustToUniversal,AssumeUniversal')
    }
    catch { return $null }
}

function Read-FastLlmUpdateState {
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        $stored = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        if ($null -eq $stored -or $stored -isnot [pscustomobject]) { return $null }
        $latest = $null
        $storedLatest = Get-FastLlmUpdateProp $stored 'latest'
        if ($null -ne $storedLatest) {
            $assets = @{}
            $storedAssets = Get-FastLlmUpdateProp $storedLatest 'assets'
            if ($null -ne $storedAssets) {
                foreach ($property in $storedAssets.PSObject.Properties) {
                    $assets[$property.Name] = @{ url = [string](Get-FastLlmUpdateProp $property.Value 'url'); size = [int64](Get-FastLlmUpdateProp $property.Value 'size') }
                }
            }
            $latest = @{
                version = [string](Get-FastLlmUpdateProp $storedLatest 'version')
                tag     = [string](Get-FastLlmUpdateProp $storedLatest 'tag')
                channel = [string](Get-FastLlmUpdateProp $storedLatest 'channel')
                htmlUrl = [string](Get-FastLlmUpdateProp $storedLatest 'htmlUrl')
                assets  = $assets
            }
            if ($null -eq (ConvertTo-FastLlmVersionNumbers $latest.version)) { $latest = $null }
        }
        return [pscustomobject]@{
            lastCheckUtc = (ConvertTo-FastLlmUtcDate (Get-FastLlmUpdateProp $stored 'lastCheckUtc'))
            etag         = [string](Get-FastLlmUpdateProp $stored 'etag')
            channel      = [string](Get-FastLlmUpdateProp $stored 'channel')
            latest       = $latest
        }
    }
    catch { return $null }
}

function Write-FastLlmUpdateState {
    param([string]$Path, [datetime]$CheckedUtc, [string]$Etag, [string]$Channel, $Latest)
    try {
        $folder = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
        $document = [ordered]@{
            lastCheckUtc = $CheckedUtc.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
            etag         = $Etag
            channel      = $Channel
            latest       = $Latest
        }
        $temporary = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
        [IO.File]::WriteAllText($temporary, ([pscustomobject]$document | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        Move-FastLlmFileReplacing -Source $temporary -Destination $Path
    }
    catch { }
}

function Invoke-FastLlmUpdateCheck {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$AppRoot,
        [switch]$Force,
        [scriptblock]$Request,
        [datetime]$NowUtc = [datetime]::UtcNow
    )
    $now = $NowUtc.ToUniversalTime()
    $installedRelease = Read-FastLlmInstalledRelease -AppRoot $AppRoot
    $installedVersion = $null
    if ($null -ne $installedRelease) { $installedVersion = $installedRelease.version }
    $make = {
        param($Status, $Latest, $Checked)
        [pscustomobject]@{ status = $Status; installed = $installedVersion; latest = $Latest; checkedUtc = $Checked }
    }

    $settings = Get-FastLlmUpdateSettings -InstallRoot $InstallRoot -AppRoot $AppRoot
    if ($settings.updateCheck -ceq 'off') { return (& $make 'disabled' $null $null) }
    if ($null -eq $installedRelease) { return (& $make 'not-a-release' $null $null) }

    $channelName = $settings.updateChannel
    $statePath = Join-Path (Join-Path $InstallRoot 'state') 'update-check.json'
    $state = Read-FastLlmUpdateState -Path $statePath
    $sameChannel = ($null -ne $state -and $state.channel -ceq $channelName)

    if (-not $Force -and $sameChannel -and $null -ne $state.lastCheckUtc) {
        $age = $now - $state.lastCheckUtc
        if ($age.TotalHours -ge 0 -and $age.TotalHours -lt 24) {
            return (& $make 'skipped-recent' $state.latest $state.lastCheckUtc.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture))
        }
    }

    $url = "$script:FastLlmReleaseApiBase/latest"
    if ($channelName -ceq 'canary') { $url = ($script:FastLlmReleaseApiBase + '?per_page=10') }
    $knownEtag = $null
    if ($sameChannel -and -not [string]::IsNullOrEmpty($state.etag)) { $knownEtag = $state.etag }

    $latestRelease = $null
    $responseEtag = $null
    try {
        if ($null -ne $Request) { $response = & $Request $url $knownEtag } else { $response = Invoke-FastLlmUpdateHttp -Url $url -Etag $knownEtag }
        $status = [int](Get-FastLlmUpdateProp $response 'Status')
        $responseEtag = [string](Get-FastLlmUpdateProp $response 'Etag')
        if ($status -eq 304) {
            if (-not $sameChannel -or [string]::IsNullOrEmpty($state.etag)) { throw 'unexpected-304' }
            $latestRelease = $state.latest
            if ([string]::IsNullOrEmpty($responseEtag)) { $responseEtag = $state.etag }
        }
        elseif ($status -eq 200) {
            $parsed = ConvertFrom-Json -InputObject ([string](Get-FastLlmUpdateProp $response 'Body'))
            $latestRelease = Select-FastLlmLatestRelease -Parsed $parsed -Channel $channelName
        }
        else { throw "http-$status" }
    }
    catch { return (& $make 'failed' $null $null) }

    $stamp = $now.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    Write-FastLlmUpdateState -Path $statePath -CheckedUtc $now -Etag $responseEtag -Channel $channelName -Latest $latestRelease
    if ($null -ne $latestRelease -and (Compare-FastLlmVersion $latestRelease.version $installedVersion) -gt 0) { return (& $make 'available' $latestRelease $stamp) }
    return (& $make 'up-to-date' $latestRelease $stamp)
}
