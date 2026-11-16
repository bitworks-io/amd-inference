# Update check: versions, settings, ETag, a 24 h limit and channels.
# Dot-sourced by the entry scripts only; NEVER by FastLlm.psm1 (the producer stays vnext.4 with 31 inputs).
# Silent on failure: a failed check never writes state and never throws.
Set-StrictMode -Version 2.0

if (-not (Get-Command Move-FastLlmFileReplacing -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'FastLlm.FileReplace.ps1')
}

if (-not (Get-Command Test-FastLlmPinnedSignature -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'FastLlm.Trust.ps1')
}

$script:FastLlmReleasePageUrlPrefix = 'https://github.com/bitworks-io/amd-inference/releases/tag/'
$script:FastLlmUpdateSumsMaxBytes = 65536
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

# Strict reads for the reinstall decision. They never unroll an array, never accept a trailing newline or non-ASCII digits, and
# tell a missing property from a null one. The shared version parser and the update path are not used for these checks.
function Get-FastLlmStrictField {
    param($Object, [string]$Name)
    $absent = [pscustomobject]@{ present = $false; value = $null }
    if ($null -eq $Object) { return $absent }
    if ($Object -is [Collections.IDictionary]) {
        if (-not $Object.Contains($Name)) { return $absent }
        return [pscustomobject]@{ present = $true; value = $Object[$Name] }
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $absent }
    return [pscustomobject]@{ present = $true; value = $property.Value }
}

function Test-FastLlmStrictVersion {
    param($Value)
    if ($Value -isnot [string]) { return $false }
    if (-not ($Value -cmatch '^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+\z')) { return $false }
    return ($null -ne (ConvertTo-FastLlmVersionNumbers $Value))
}

# Decide whether "reinstall the previous version" may be offered. Pure: it reads only its arguments, installs nothing, and is not
# called by the update path (the refusal of non-newer releases in Invoke-FastLlmVerifiedUpdate is unchanged).
#   -InstalledPolicy  the installed release's policy (schema, dataFormat, rollbackFloor), or $null when it has none
#   -InstalledVersion the installed release version
#   -PreviousRecord   { version; policy; replacedBy } written by the installer for the release it replaced, or $null; policy is $null
#                     when that release had no policy file; replacedBy is the release that replaced it and must equal InstalledVersion
#   -FreshLatest      the newest published version from a fresh check; $null or empty means offline. It can only block, never pick the target
#   -StoreRelease     { version; draft } for the target's own release tag in the project's release store, or $null when absent
# Returns { decision = 'eligible'|'refused'; reason = <code>; target = <version or $null> }.
function Get-FastLlmReinstallDecision {
    param($InstalledPolicy, [string]$InstalledVersion, $PreviousRecord, [string]$FreshLatest, $StoreRelease)
    $result = {
        param([string]$Decision, [string]$Reason, $Target)
        [pscustomobject]@{ decision = $Decision; reason = $Reason; target = $Target }
    }
    $policySchema = 'bitworks.fastllm-release-policy/v1'
    if ($null -eq $PreviousRecord) { return (& $result 'refused' 'no-previous-record' $null) }
    $target = (Get-FastLlmStrictField $PreviousRecord 'version').value
    $replacedBy = (Get-FastLlmStrictField $PreviousRecord 'replacedBy').value
    if (-not (Test-FastLlmStrictVersion $target) -or -not (Test-FastLlmStrictVersion $InstalledVersion)) { return (& $result 'refused' 'not-immediate-previous' $null) }
    if ($replacedBy -isnot [string] -or $replacedBy -cne $InstalledVersion) { return (& $result 'refused' 'not-immediate-previous' $null) }
    if ((Compare-FastLlmVersion $target $InstalledVersion) -ne -1) { return (& $result 'refused' 'not-immediate-previous' $null) }

    # Both policies must be the v1 policy; one that is missing or foreign has no data format.
    $previousPolicy = (Get-FastLlmStrictField $PreviousRecord 'policy').value
    foreach ($policy in @($InstalledPolicy, $previousPolicy)) {
        if ($policy -is [Array] -or [string](Get-FastLlmStrictField $policy 'schema').value -cne $policySchema) { return (& $result 'refused' 'data-format-missing' $target) }
    }

    # The floor comes from the INSTALLED policy only. It must be present and be null or a strict version; anything else fails closed.
    $floorField = Get-FastLlmStrictField $InstalledPolicy 'rollbackFloor'
    if (-not $floorField.present) { return (& $result 'refused' 'below-security-floor' $target) }
    if ($null -ne $floorField.value) {
        if (-not (Test-FastLlmStrictVersion $floorField.value)) { return (& $result 'refused' 'below-security-floor' $target) }
        if ((Compare-FastLlmVersion $target $floorField.value) -eq -1) { return (& $result 'refused' 'below-security-floor' $target) }
    }

    $installedFormat = (Get-FastLlmStrictField $InstalledPolicy 'dataFormat').value
    $previousFormat = (Get-FastLlmStrictField $previousPolicy 'dataFormat').value
    foreach ($format in @($installedFormat, $previousFormat)) {
        if (($format -isnot [int] -and $format -isnot [long]) -or $format -lt 1) { return (& $result 'refused' 'data-format-missing' $target) }
    }
    if ([long]$installedFormat -ne [long]$previousFormat) { return (& $result 'refused' 'data-format-differs' $target) }

    # $null or empty means offline: the local rules decide. Anything else must be a strict version, or the check cannot be trusted.
    if (-not [string]::IsNullOrEmpty($FreshLatest)) {
        if (-not (Test-FastLlmStrictVersion $FreshLatest)) { return (& $result 'refused' 'fresh-check-unreadable' $target) }
        if ((Compare-FastLlmVersion $FreshLatest $InstalledVersion) -eq 1) { return (& $result 'refused' 'newer-release-available' $target) }
    }

    if ($null -eq $StoreRelease) { return (& $result 'refused' 'not-in-release-store' $target) }
    $storeVersion = (Get-FastLlmStrictField $StoreRelease 'version').value
    $storeDraft = (Get-FastLlmStrictField $StoreRelease 'draft').value
    if (-not (Test-FastLlmStrictVersion $storeVersion) -or $storeVersion -cne $target -or $storeDraft -isnot [bool]) { return (& $result 'refused' 'not-in-release-store' $target) }
    if ($storeDraft) { return (& $result 'refused' 'draft-release' $target) }
    return (& $result 'eligible' 'eligible' $target)
}

# A plain read is lenient: a file that cannot be read gives no stored values, and the defaults apply.
# -ForWrite is the read of a read-modify-write. A settings.json that exists but is not a readable JSON object (it does not parse, it is not
# an object, it is a folder or a link, it is over 16 KiB, it cannot be read right now) is then refused instead of being read as empty:
# written back, an empty read would erase every setting the file held, the API key flag among them, and the next start would run
# without the key that was asked for. The same verdict as Read-FastLlmServingSettingsObject (malformed). An absent file is empty.
function Read-FastLlmSettingsObject {
    param([string]$InstallRoot, [switch]$ForWrite)
    $result = [ordered]@{}
    if ($ForWrite) {
        $readable = $true
        try {
            $path = Join-Path $InstallRoot 'settings.json'
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
                        foreach ($property in $stored.PSObject.Properties) { $result[$property.Name] = $property.Value }
                        $readable = $true
                    }
                }
            }
        }
        catch { $readable = $false }
        if (-not $readable) { throw 'settings-malformed: settings.json is not valid JSON, so it was not changed. Fix or delete it, then try again.' }
        return $result
    }
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
    $merged = Read-FastLlmSettingsObject -InstallRoot $InstallRoot -ForWrite
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
    # Windows PowerShell 5.1 may default to protocols api.github.com refuses; enable TLS 1.2 (and 1.3 where defined). Never throws.
    try {
        $protocols = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        if ([Enum]::IsDefined([Net.SecurityProtocolType], 'Tls13')) { $protocols = $protocols -bor [Net.SecurityProtocolType]::Tls13 }
        [Net.ServicePointManager]::SecurityProtocol = $protocols
    }
    catch { $null = $_ }
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
    $candidate = ConvertTo-FastLlmUpdateLatest -Release $best -Parsed $bestParsed
    # A release page outside this repository's tag path is no eligible release at all.
    if (-not ([string]$candidate.htmlUrl).StartsWith($script:FastLlmReleasePageUrlPrefix, [StringComparison]::Ordinal)) { return $null }
    return $candidate
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
            elseif (-not ([string]$latest.htmlUrl).StartsWith($script:FastLlmReleasePageUrlPrefix, [StringComparison]::Ordinal)) { $latest = $null }
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
            $recentStamp = $state.lastCheckUtc.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
            # A newer release found by an earlier check stays available inside the window; still NO request.
            $cachedLatest = $state.latest
            if ($null -ne $cachedLatest -and -not [string]::IsNullOrEmpty([string]$cachedLatest.version) -and (Compare-FastLlmVersion ([string]$cachedLatest.version) $installedVersion) -gt 0) {
                return (& $make 'available' $cachedLatest $recentStamp)
            }
            return (& $make 'skipped-recent' $cachedLatest $recentStamp)
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


# The cached notice for start and status: reads ONLY <InstallRoot>\state\update-check.json and RELEASE.json. NO network.
# Returns one line when the cached latest is newer than the installed version, else $null. Never throws.
function Get-FastLlmCachedUpdateNotice {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$AppRoot
    )
    try {
        $installedRelease = Read-FastLlmInstalledRelease -AppRoot $AppRoot
        if ($null -eq $installedRelease) { return $null }
        $cached = Read-FastLlmUpdateState -Path (Join-Path (Join-Path $InstallRoot 'state') 'update-check.json')
        if ($null -eq $cached -or $null -eq $cached.latest) { return $null }
        if ((Compare-FastLlmVersion ([string]$cached.latest.version) $installedRelease.version) -le 0) { return $null }
        return ('Update available: FastLLM {0} ({1}).' -f $cached.latest.version, $cached.latest.htmlUrl)
    }
    catch { return $null }
}


# --- Verified update flow ---

function Get-FastLlmUpdateFileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $hasher.ComputeHash($stream)
        return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $hasher.Dispose(); $stream.Dispose() }
}

# The same line rules as release/ReleaseVerify.psm1 Read-FastLlmSha256Sums, on a size-capped file: two spaces, 64 lowercase hex, a bare file name.
function Read-FastLlmUpdateSums {
    param([Parameter(Mandatory = $true)][string]$Path)
    $info = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($info.Length -gt $script:FastLlmUpdateSumsMaxBytes) { throw 'SHA256SUMS is over the size cap.' }
    $bytes = [IO.File]::ReadAllBytes($Path)
    foreach ($byte in $bytes) { if ($byte -gt 126 -or ($byte -lt 32 -and $byte -ne 10 -and $byte -ne 13)) { throw 'SHA256SUMS is not plain ASCII text.' } }
    $text = [Text.Encoding]::ASCII.GetString($bytes)
    $sums = @{}
    foreach ($rawLine in $text.Split([char]10)) {
        $line = $rawLine
        if ($line.EndsWith("`r")) { $line = $line.Substring(0, $line.Length - 1) }
        if ($line -eq '') { continue }
        $m = [regex]::Match($line, '^([0-9a-f]{64})  ([A-Za-z0-9._-]+)$')
        if (-not $m.Success) { throw 'SHA256SUMS has a malformed line.' }
        if ($sums.ContainsKey($m.Groups[2].Value)) { throw 'SHA256SUMS has a duplicate entry.' }
        $sums[$m.Groups[2].Value] = $m.Groups[1].Value
    }
    return $sums
}

# Deletes only what this call created: the exact download names (and the sibling lock, partial and quarantine names Save-FastLlmVerifiedFile derives from them) inside the fresh directory, then the directory if it is empty.
function Remove-FastLlmUpdateWork {
    param([string]$Directory, [string[]]$BaseNames)
    if ([string]::IsNullOrEmpty($Directory)) { return }
    try {
        if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return }
        # A just-written installer can be held briefly by an anti-malware scan, so each removal retries (bounded) before giving up.
        foreach ($child in @(Get-ChildItem -LiteralPath $Directory -Force -File)) {
            foreach ($baseName in @($BaseNames)) {
                if ($child.Name.StartsWith($baseName, [StringComparison]::Ordinal)) {
                    for ($attempt = 0; $attempt -lt 20; $attempt++) {
                        try { [IO.File]::Delete($child.FullName); break } catch { Start-Sleep -Milliseconds 100 }
                    }
                    break
                }
            }
        }
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { break }
            if (@(Get-ChildItem -LiteralPath $Directory -Force).Count) { break }
            try { [IO.Directory]::Delete($Directory); break } catch { Start-Sleep -Milliseconds 100 }
        }
    }
    catch { }
}

function Save-FastLlmUpdateCappedFile {
    param([string]$Url, [string]$Destination, [int64]$MaxBytes)
    if (-not $Url.StartsWith($script:FastLlmAssetUrlPrefix, [StringComparison]::Ordinal)) { throw 'The asset URL is outside the release download path.' }
    $curlPath = $null
    if ($env:OS -eq 'Windows_NT' -and $env:SystemRoot) {
        $systemCurl = Join-Path (Join-Path $env:SystemRoot 'System32') 'curl.exe'
        if (Test-Path -LiteralPath $systemCurl -PathType Leaf) { $curlPath = $systemCurl }
    }
    elseif ($env:OS -ne 'Windows_NT') {
        $curlCommand = Get-Command 'curl' -CommandType Application -ErrorAction SilentlyContinue
        if ($curlCommand) { $curlPath = $curlCommand.Source }
    }
    if (-not $curlPath) { throw 'The trusted Windows System32 curl.exe is required for HTTPS-only downloads.' }
    $curlArguments = @('--disable', '--silent', '--show-error', '--location', '--fail', '--max-time', '60',
        '--max-filesize', [string]$MaxBytes, '--proto', '=https', '--proto-redir', '=https', '--output', $Destination, $Url)
    & $curlPath @curlArguments
    if ($LASTEXITCODE -ne 0) { throw "Download failed with curl exit code $LASTEXITCODE." }
    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) { throw 'The download produced no file.' }
    if ((Get-Item -LiteralPath $Destination).Length -gt $MaxBytes) { throw 'The download is over the size cap.' }
}

function Stop-FastLlmServerForUpdate {
    param([Parameter(Mandatory = $true)][string]$InstallRoot, [int]$TimeoutSeconds = 60)
    try {
        $state = Get-FastLlmStatus -InstallRoot $InstallRoot
        if (-not [bool](Get-FastLlmUpdateProp $state 'active')) { return [pscustomobject]@{ ok = $true; reason = 'already-stopped' } }
        $phase = [string](Get-FastLlmUpdateProp $state 'phase')
        if (@('loading', 'checking', 'ready') -cnotcontains $phase) { return [pscustomobject]@{ ok = $false; reason = "busy-${phase}" } }
        Request-FastLlmStop -InstallRoot $InstallRoot | Out-Null
        $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
        while ([datetime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 500
            $after = Get-FastLlmStatus -InstallRoot $InstallRoot
            if (-not [bool](Get-FastLlmUpdateProp $after 'active')) { return [pscustomobject]@{ ok = $true; reason = 'stopped' } }
        }
        return [pscustomobject]@{ ok = $false; reason = 'stop-timeout' }
    }
    catch { return [pscustomobject]@{ ok = $false; reason = [string]$_.Exception.Message } }
}

# Seams are scriptblocks whose defaults are the real implementations; tests pass mocks.
#   StopServer  { param($InstallRoot) }                       -> { ok; reason }
#   Download    { param($Url, $Destination, $Sha256, $SizeBytes) }  throws on failure; an empty Sha256 means the capped SHA256SUMS fetch, with SizeBytes as the cap
#   Verify      { param($Path) }                              -> { ok; reason; detail }
#   GetProductVersion { param($Path) }                        -> string
#   RunInstaller { param($Setup, $Silent) }                   -> exit code
#   Integrity   { param($AppRoot) }                           -> { status; reason }
function Invoke-FastLlmVerifiedUpdate {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$AppRoot,
        [Parameter(Mandatory = $true)]$Latest,
        [scriptblock]$StopServer = { param($Root) Stop-FastLlmServerForUpdate -InstallRoot $Root },
        [scriptblock]$Download = {
            param($Url, $Destination, $Sha256, $SizeBytes)
            if ([string]::IsNullOrEmpty($Sha256)) { Save-FastLlmUpdateCappedFile -Url $Url -Destination $Destination -MaxBytes $SizeBytes }
            else { Save-FastLlmVerifiedFile -Url $Url -Destination $Destination -Sha256 $Sha256 -SizeBytes $SizeBytes | Out-Null }
        },
        [scriptblock]$Verify = { param($Path) Test-FastLlmPinnedSignature -Path $Path },
        [scriptblock]$GetProductVersion = { param($Path) Get-FastLlmFileProductVersion -Path $Path },
        [scriptblock]$RunInstaller = {
            param($Setup, $QuietMode)
            $installerSwitch = '/SILENT'
            if ($QuietMode) { $installerSwitch = '/VERYSILENT' }
            $process = Start-Process -FilePath $Setup -ArgumentList @($installerSwitch, '/CURRENTUSER', '/NORESTART') -Wait -PassThru
            $process.ExitCode
        },
        [scriptblock]$Integrity = { param($Root) Test-FastLlmInstallIntegrity -AppRoot $Root },
        [switch]$Silent,
        # Reinstall-previous only (Invoke-FastLlmReinstallPrevious): the exact older version the reinstall decision allowed. Empty (every
        # update caller) keeps step 5 exactly as it is: the release must be newer. When set, the release must BE this version and be older.
        [string]$PreviousTarget
    )
    $freshDir = $null
    $workNames = @()
    $finish = {
        param([string]$Status, [string]$Step, [string]$Reason)
        if ($Status -cne 'installed') { Remove-FastLlmUpdateWork -Directory $freshDir -BaseNames $workNames }
        [pscustomobject]@{ status = $Status; step = $Step; reason = $Reason }
    }

    $newVersion = [string](Get-FastLlmUpdateProp $Latest 'version')
    if ($null -eq (ConvertTo-FastLlmVersionNumbers $newVersion)) { return (& $finish 'refused' 'version' 'invalid-latest-version') }
    $assets = Get-FastLlmUpdateProp $Latest 'assets'
    $installerName = "FastLLM-Setup-${newVersion}.exe"

    # 1. stop, verify stopped
    try { $stopped = & $StopServer $InstallRoot } catch { return (& $finish 'failed' 'stop' ([string]$_.Exception.Message)) }
    if (-not [bool](Get-FastLlmUpdateProp $stopped 'ok')) { return (& $finish 'failed' 'stop' ([string](Get-FastLlmUpdateProp $stopped 'reason'))) }

    # 2. SHA256SUMS (capped), parsed strictly
    $sumsAsset = $null
    $installerAsset = $null
    if ($null -ne $assets) {
        if ($assets.Contains('SHA256SUMS')) { $sumsAsset = $assets['SHA256SUMS'] }
        if ($assets.Contains($installerName)) { $installerAsset = $assets[$installerName] }
    }
    if ($null -eq $sumsAsset) { return (& $finish 'refused' 'sums' 'no-sums-asset') }
    $sumsUrl = [string](Get-FastLlmUpdateProp $sumsAsset 'url')
    if (-not $sumsUrl.StartsWith($script:FastLlmAssetUrlPrefix, [StringComparison]::Ordinal)) { return (& $finish 'refused' 'sums' 'bad-asset-url') }
    $sumsSize = [int64](Get-FastLlmUpdateProp $sumsAsset 'size')
    if ($sumsSize -gt $script:FastLlmUpdateSumsMaxBytes) { return (& $finish 'refused' 'sums' 'sums-too-large') }

    $freshDir = Join-Path (Join-Path $InstallRoot 'updates') ("${newVersion}-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $workNames = @('SHA256SUMS', $installerName)
    try { [IO.Directory]::CreateDirectory($freshDir) | Out-Null } catch { return (& $finish 'failed' 'sums' 'cannot-create-download-directory') }
    $sumsPath = Join-Path $freshDir 'SHA256SUMS'
    try { & $Download $sumsUrl $sumsPath '' ([int64]$script:FastLlmUpdateSumsMaxBytes) | Out-Null }
    catch { return (& $finish 'failed' 'sums' ([string]$_.Exception.Message)) }
    try {
        if (-not (Test-Path -LiteralPath $sumsPath -PathType Leaf)) { throw 'missing-sums-file' }
        $sums = Read-FastLlmUpdateSums -Path $sumsPath
    }
    catch { return (& $finish 'refused' 'sums' ([string]$_.Exception.Message)) }
    if (-not $sums.ContainsKey($installerName)) { return (& $finish 'refused' 'sums' 'no-installer-entry') }
    $installerSha = [string]$sums[$installerName]

    # 3. the installer: sha from SUMS, size from the release asset
    if ($null -eq $installerAsset) { return (& $finish 'refused' 'download' 'no-installer-asset') }
    $installerUrl = [string](Get-FastLlmUpdateProp $installerAsset 'url')
    $installerSize = [int64](Get-FastLlmUpdateProp $installerAsset 'size')
    if (-not $installerUrl.StartsWith($script:FastLlmAssetUrlPrefix, [StringComparison]::Ordinal) -or $installerSize -le 0) { return (& $finish 'refused' 'download' 'bad-installer-asset') }
    $setupPath = Join-Path $freshDir $installerName
    try { & $Download $installerUrl $setupPath $installerSha $installerSize | Out-Null }
    catch { return (& $finish 'failed' 'download' ([string]$_.Exception.Message)) }
    if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf)) { return (& $finish 'failed' 'download' 'missing-installer-file') }
    try { $actualSha = Get-FastLlmUpdateFileSha256 -Path $setupPath } catch { return (& $finish 'failed' 'hash' ([string]$_.Exception.Message)) }
    if ($actualSha -cne $installerSha) { return (& $finish 'failed' 'hash' 'sha256-mismatch') }

    # 4. pinned signature
    try { $signature = & $Verify $setupPath } catch { return (& $finish 'failed' 'signature' ([string]$_.Exception.Message)) }
    if (-not [bool](Get-FastLlmUpdateProp $signature 'ok')) { return (& $finish 'refused' 'signature' ([string](Get-FastLlmUpdateProp $signature 'reason'))) }

    # 5. ProductVersion equals the release version and is newer than the installed one (reinstall-previous: the exact target, and older)
    try { $productVersion = [string](& $GetProductVersion $setupPath) } catch { return (& $finish 'failed' 'version' ([string]$_.Exception.Message)) }
    if ($productVersion -cne $newVersion) { return (& $finish 'refused' 'version' 'product-version-mismatch') }
    $installedRelease = Read-FastLlmInstalledRelease -AppRoot $AppRoot
    if ($null -eq $installedRelease) { return (& $finish 'refused' 'version' 'not-a-release') }
    if ([string]::IsNullOrEmpty($PreviousTarget)) {
        if ((Compare-FastLlmVersion $newVersion $installedRelease.version) -ne 1) { return (& $finish 'refused' 'version' 'not-newer') }
    }
    else {
        if ($newVersion -cne $PreviousTarget) { return (& $finish 'refused' 'version' 'not-the-previous-target') }
        if ((Compare-FastLlmVersion $newVersion $installedRelease.version) -ne -1) { return (& $finish 'refused' 'version' 'not-older') }
    }

    # 6. run the per-user installer
    try { $exitCode = & $RunInstaller $setupPath ([bool]$Silent) } catch { return (& $finish 'failed' 'install' ([string]$_.Exception.Message)) }
    if ([int]$exitCode -ne 0) { return (& $finish 'failed' 'install' "installer-exit-${exitCode}") }

    # 7. integrity of the installed tree
    # Not $integrity: PowerShell names are case-insensitive, so that would assign into the [scriptblock] $Integrity parameter.
    try { $integrityResult = & $Integrity $AppRoot } catch { return (& $finish 'failed' 'integrity' ([string]$_.Exception.Message)) }
    if ([string](Get-FastLlmUpdateProp $integrityResult 'status') -cne 'ok') {
        $why = [string](Get-FastLlmUpdateProp $integrityResult 'reason')
        if ([string]::IsNullOrEmpty($why)) { $why = [string](Get-FastLlmUpdateProp $integrityResult 'status') }
        return (& $finish 'failed' 'integrity' $why)
    }
    return (& $finish 'installed' 'integrity' '')
}

# --- Reinstall the previous version: the explicit action built on Get-FastLlmReinstallDecision ---------------------------------
# Only Invoke-FastLlmReinstallPrevious (the CLI "update -Previous" and the window's button) calls these. Nothing here runs from start,
# the update check, the self-test or any automated path, and the normal update path never passes -PreviousTarget.

$script:FastLlmReinstallReasonText = @{
    'no-previous-record'        = 'There is no usable record of a previous version on this PC, so there is nothing to go back to.'
    'not-immediate-previous'    = 'The recorded version is not the one installed just before this one.'
    'below-security-floor'      = 'The previous version has a known security problem that this version fixes.'
    'data-format-differs'       = 'The previous version cannot read the data this version writes.'
    'data-format-missing'       = 'FastLLM cannot tell whether the previous version can read this version''s data.'
    'fresh-check-unreadable'    = 'The check for newer releases could not be read, so going back is not offered.'
    'newer-release-available'   = 'A newer release is available. Update instead of going back.'
    'not-in-release-store'      = 'The previous version is not available from the FastLLM release page (or the page could not be reached).'
    'draft-release'             = 'The previous version is not published.'
    'update-checks-off'         = 'Update checks are turned off, so FastLLM cannot tell whether a newer release exists. Turn update checks on and try again.'
    'target-changed'            = 'The previous version changed since you were asked. Nothing was changed.'
    'not-a-release'             = 'This is not an installed FastLLM release (no RELEASE.json), so there is nothing to go back from.'
    'approval-required'         = 'The reinstall was not confirmed. Nothing was changed.'
}
function Get-FastLlmReinstallReasonText {
    param([string]$Reason)
    if (-not [string]::IsNullOrEmpty($Reason) -and $script:FastLlmReinstallReasonText.ContainsKey($Reason)) { return [string]$script:FastLlmReinstallReasonText[$Reason] }
    return 'Going back to the previous version is not possible right now. Nothing was changed.'
}

# One small JSON file from the previous-release record folder; $null when it is absent, too large, unreadable or not an object.
function Read-FastLlmReinstallJsonFile {
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        if ((Get-Item -LiteralPath $Path).Length -gt 65536) { return $null }
        $text = [IO.File]::ReadAllText($Path, (New-Object Text.UTF8Encoding($false)))
        $parsed = ConvertFrom-Json -InputObject $text
        if ($parsed -is [Array] -or $parsed -isnot [pscustomobject]) { return $null }
        return $parsed
    }
    catch { return $null }
}

# The facts the reinstall decision needs from this PC: the installed version and policy, and the installer's previous-release record
# (<InstallRoot>\state\previous-release\ record.json + RELEASE.json + release-policy.json). Returns $null when this is not an installed
# release. record is $null when it is missing or unreadable; a record that reads but lies is left for the decision to refuse.
function Read-FastLlmReinstallFacts {
    param([Parameter(Mandatory = $true)][string]$InstallRoot, [Parameter(Mandatory = $true)][string]$AppRoot)
    $installedRelease = Read-FastLlmInstalledRelease -AppRoot $AppRoot
    if ($null -eq $installedRelease) { return $null }
    $installedPolicy = Read-FastLlmReinstallJsonFile -Path (Join-Path (Join-Path $AppRoot 'config') 'release-policy.json')
    $folder = Join-Path (Join-Path $InstallRoot 'state') 'previous-release'
    $marker = Read-FastLlmReinstallJsonFile -Path (Join-Path $folder 'record.json')
    $oldRelease = Read-FastLlmReinstallJsonFile -Path (Join-Path $folder 'RELEASE.json')
    $record = $null
    $channel = 'stable'
    if ($null -ne $marker -and $null -ne $oldRelease) {
        $oldChannelField = Get-FastLlmStrictField $oldRelease 'channel'
        if ($oldChannelField.present) { $channel = [string]$oldChannelField.value }
        $record = [pscustomobject]@{
            version    = (Get-FastLlmStrictField $oldRelease 'version').value
            policy     = Read-FastLlmReinstallJsonFile -Path (Join-Path $folder 'release-policy.json')
            replacedBy = (Get-FastLlmStrictField $marker 'replacedBy').value
        }
        # A channel other than stable or canary means the record was not written by the installer.
        if ($oldChannelField.present -and (($oldChannelField.value -isnot [string]) -or (@('stable', 'canary') -cnotcontains $oldChannelField.value))) { $record = $null }
    }
    return [pscustomobject]@{ installedVersion = $installedRelease.version; installedPolicy = $installedPolicy; record = $record; channel = $channel }
}

# The target's own release in the project's release store, by exact tag. $null when absent, off-site, or not a release of that version
# and channel. Never a latest/list answer, so no remote answer chooses the target. Latest is the same shape the update path installs from.
#   -Request { param($Url, $Etag) } -> { Status; Body; Etag }  (the same seam as Invoke-FastLlmUpdateCheck)
function Get-FastLlmStoreRelease {
    param([Parameter(Mandatory = $true)][string]$Version, [string]$Channel = 'stable', [scriptblock]$Request)
    try {
        if (-not (Test-FastLlmStrictVersion $Version)) { return $null }
        if (@('stable', 'canary') -cnotcontains $Channel) { return $null }
        $tag = 'v' + $Version
        if ($Channel -ceq 'canary') { $tag = $tag + '-canary' }
        $url = "$script:FastLlmReleaseApiBase/tags/$tag"
        if ($null -ne $Request) { $response = & $Request $url $null } else { $response = Invoke-FastLlmUpdateHttp -Url $url -Etag $null }
        if ([int](Get-FastLlmUpdateProp $response 'Status') -ne 200) { return $null }
        $release = ConvertFrom-Json -InputObject ([string](Get-FastLlmUpdateProp $response 'Body'))
        if ([string](Get-FastLlmUpdateProp $release 'tag_name') -cne $tag) { return $null }
        $parsedTag = ConvertFrom-FastLlmReleaseTag $tag
        if ($null -eq $parsedTag -or $parsedTag.version -cne $Version -or $parsedTag.channel -cne $Channel) { return $null }
        $draft = Get-FastLlmUpdateProp $release 'draft'
        if ($draft -isnot [bool]) { return $null }
        # A stable release is never a pre-release; a canary one is whatever the project published.
        if ($Channel -ceq 'stable' -and (Get-FastLlmUpdateProp $release 'prerelease') -ne $false) { return $null }
        $latest = ConvertTo-FastLlmUpdateLatest -Release $release -Parsed $parsedTag
        if (-not ([string]$latest.htmlUrl).StartsWith($script:FastLlmReleasePageUrlPrefix, [StringComparison]::Ordinal)) { return $null }
        return [pscustomobject]@{ version = $Version; draft = $draft; latest = $latest }
    }
    catch { return $null }
}

# The decision for this PC, local rules first. Only when every local rule passes does it look at the network, and never more than needed:
#   - the explicit action (default) asks the project for a fresh update check, stops there if a newer release exists, and only then asks
#     for the store entry of the exact target. Update checks turned off refuse it: with no way to tell whether a newer release exists, the
#     "update first" rule cannot be applied.
#   - -OfferOnly (the window's button, every launch) makes no request beyond the normal, once-a-day update check. It decides on what that
#     check knows and leaves the store entry out; the click decides again with the full path above before anything is installed.
# Returns { decision; reason; target; installed; latest } ; latest is the store release to install when eligible, else $null.
function Resolve-FastLlmReinstall {
    param([Parameter(Mandatory = $true)][string]$InstallRoot, [Parameter(Mandatory = $true)][string]$AppRoot, [scriptblock]$Request, [switch]$OfferOnly)
    $make = {
        param($Decision, $Installed, $Latest)
        [pscustomobject]@{ decision = $Decision.decision; reason = $Decision.reason; target = $Decision.target; installed = $Installed; latest = $Latest }
    }
    $facts = Read-FastLlmReinstallFacts -InstallRoot $InstallRoot -AppRoot $AppRoot
    if ($null -eq $facts) { return (& $make ([pscustomobject]@{ decision = 'refused'; reason = 'not-a-release'; target = $null }) $null $null) }
    # Pass 1, no network: the store entry is the one thing not known yet, so a refusal for any other reason is final.
    $local = Get-FastLlmReinstallDecision -InstalledPolicy $facts.installedPolicy -InstalledVersion $facts.installedVersion -PreviousRecord $facts.record -FreshLatest $null -StoreRelease $null
    if ([string]$local.reason -cne 'not-in-release-store') { return (& $make $local $facts.installedVersion $null) }

    $checkArguments = @{ InstallRoot = $InstallRoot; AppRoot = $AppRoot }
    if ($null -ne $Request) { $checkArguments['Request'] = $Request }
    if (-not $OfferOnly) { $checkArguments['Force'] = $true }
    $check = Invoke-FastLlmUpdateCheck @checkArguments
    if ([string]$check.status -ceq 'disabled') {
        return (& $make ([pscustomobject]@{ decision = 'refused'; reason = 'update-checks-off'; target = $local.target }) $facts.installedVersion $null)
    }
    $fresh = $null
    if (@('available', 'up-to-date', 'skipped-recent') -ccontains [string]$check.status -and $null -ne $check.latest) { $fresh = [string]$check.latest.version }
    $storeRelease = $null
    $store = $null
    if ($OfferOnly) {
        # No store request here. The target itself stands in for the store entry so the other rules are judged; nothing is installed from this answer.
        $storeRelease = [pscustomobject]@{ version = [string]$local.target; draft = $false }
    }
    else {
        $beforeStore = Get-FastLlmReinstallDecision -InstalledPolicy $facts.installedPolicy -InstalledVersion $facts.installedVersion -PreviousRecord $facts.record -FreshLatest $fresh -StoreRelease $null
        if ([string]$beforeStore.reason -cne 'not-in-release-store') { return (& $make $beforeStore $facts.installedVersion $null) }
        $store = Get-FastLlmStoreRelease -Version ([string]$local.target) -Channel $facts.channel -Request $Request
        if ($null -ne $store) { $storeRelease = [pscustomobject]@{ version = $store.version; draft = $store.draft } }
    }
    $final = Get-FastLlmReinstallDecision -InstalledPolicy $facts.installedPolicy -InstalledVersion $facts.installedVersion -PreviousRecord $facts.record -FreshLatest $fresh -StoreRelease $storeRelease
    $latestToInstall = $null
    if ([string]$final.decision -ceq 'eligible' -and $null -ne $store) { $latestToInstall = $store.latest }
    return (& $make $final $facts.installedVersion $latestToInstall)
}

# Removes the previous-release record after a reinstall, so going back never chains. Best effort.
function Clear-FastLlmPreviousReleaseRecord {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)
    try {
        $folder = Join-Path (Join-Path $InstallRoot 'state') 'previous-release'
        if (Test-Path -LiteralPath $folder) { Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction Stop }
    }
    catch { $null = $_ }
}

# The explicit reinstall. -Approve is called with (installedVersion, targetVersion) after the decision allows it and before anything is
# stopped or downloaded; it must return exactly $true. There is no default approval. -ExpectedTarget (the window) refuses when a fresh
# decision names another version than the one the person confirmed. -UpdateSeams are the same seams Invoke-FastLlmVerifiedUpdate takes.
# Returns { status = refused|declined|installed|failed; step; reason; message; from; to }.
function Invoke-FastLlmReinstallPrevious {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$AppRoot,
        [Parameter(Mandatory = $true)][scriptblock]$Approve,
        [string]$ExpectedTarget,
        [scriptblock]$Request,
        [hashtable]$UpdateSeams = @{}
    )
    $make = {
        param([string]$Status, [string]$Step, [string]$Reason, [string]$Message, $From, $To)
        [pscustomobject]@{ status = $Status; step = $Step; reason = $Reason; message = $Message; from = $From; to = $To }
    }
    $resolveArguments = @{ InstallRoot = $InstallRoot; AppRoot = $AppRoot }
    if ($null -ne $Request) { $resolveArguments['Request'] = $Request }
    $resolved = Resolve-FastLlmReinstall @resolveArguments
    $from = $resolved.installed
    $to = $resolved.target
    if ([string]$resolved.decision -cne 'eligible' -or $null -eq $resolved.latest) {
        return (& $make 'refused' 'decision' ([string]$resolved.reason) (Get-FastLlmReinstallReasonText ([string]$resolved.reason)) $from $to)
    }
    if (-not [string]::IsNullOrEmpty($ExpectedTarget) -and [string]$resolved.target -cne $ExpectedTarget) {
        return (& $make 'refused' 'decision' 'target-changed' (Get-FastLlmReinstallReasonText 'target-changed') $from $to)
    }
    $approved = $false
    try { $answer = & $Approve $from $to; $approved = (@($answer).Count -eq 1) -and ($answer -is [bool]) -and ($answer -eq $true) } catch { $approved = $false }
    if (-not $approved) { return (& $make 'declined' 'confirm' 'not-confirmed' (Get-FastLlmReinstallReasonText 'approval-required') $from $to) }
    $outcome = Invoke-FastLlmVerifiedUpdate -InstallRoot $InstallRoot -AppRoot $AppRoot -Latest $resolved.latest -PreviousTarget ([string]$resolved.target) @UpdateSeams
    if ([string]$outcome.status -ceq 'installed') { Clear-FastLlmPreviousReleaseRecord -InstallRoot $InstallRoot }
    return (& $make ([string]$outcome.status) ([string]$outcome.step) ([string]$outcome.reason) '' $from $to)
}

# The confirmation for the CLI: -Yes confirms without asking; otherwise the prompt names both versions and only y or yes confirms.
#   -Prompt { param($Text) } -> the answer (defaults to Read-Host)
function New-FastLlmReinstallApprover {
    param([switch]$Yes, [scriptblock]$Prompt = { param($Text) Read-Host $Text })
    $confirmed = [bool]$Yes
    $ask = $Prompt
    return {
        param($From, $To)
        if ($confirmed) { return $true }
        $answer = & $ask ('Reinstall FastLLM {0} (replaces {1})? [y/N]' -f $To, $From)
        return ([string]$answer -cmatch '^\s*[yY]([eE][sS])?\s*$')
    }.GetNewClosure()
}

# What the CLI prints and exits with for an Invoke-FastLlmReinstallPrevious result: refused 3, declined 0, anything else that is not
# installed 1, installed 0 (the same codes as "update").
function Get-FastLlmReinstallCliReport {
    param($Result)
    $status = [string](Get-FastLlmUpdateProp $Result 'status')
    $step = [string](Get-FastLlmUpdateProp $Result 'step')
    $reason = [string](Get-FastLlmUpdateProp $Result 'reason')
    $to = [string](Get-FastLlmUpdateProp $Result 'to')
    if ($status -ceq 'installed') { return [pscustomobject]@{ text = ('FastLLM {0} is reinstalled. Close and reopen FastLLM.' -f $to); exitCode = 0 } }
    if ($status -ceq 'declined') { return [pscustomobject]@{ text = 'Not reinstalled. Nothing was changed.'; exitCode = 0 } }
    if ($status -ceq 'refused' -and $step -ceq 'decision') {
        return [pscustomobject]@{ text = ('Reinstall refused: ' + (Get-FastLlmReinstallReasonText $reason)); exitCode = 3 }
    }
    if ($status -ceq 'failed' -and $step -ceq 'integrity') {
        return [pscustomobject]@{ text = ("FastLLM {0} was installed, but its files don't match the signed catalog ({1}). Reinstall FastLLM from https://github.com/bitworks-io/amd-inference/releases" -f $to, $reason); exitCode = 1 }
    }
    $code = 1
    if ($status -ceq 'refused') { $code = 3 }
    return [pscustomobject]@{ text = ('Reinstall {0} at {1}: {2}' -f $status, $step, $reason); exitCode = $code }
}
