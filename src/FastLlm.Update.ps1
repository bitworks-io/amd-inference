# Update check: versions, settings, ETag, a 24 h limit and channels.
# Dot-sourced by the entry scripts only; NEVER by FastLlm.psm1 (the producer stays vnext.3 with 31 inputs).
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
        [switch]$Silent
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

    # 5. ProductVersion equals the release version and is newer than the installed one
    try { $productVersion = [string](& $GetProductVersion $setupPath) } catch { return (& $finish 'failed' 'version' ([string]$_.Exception.Message)) }
    if ($productVersion -cne $newVersion) { return (& $finish 'refused' 'version' 'product-version-mismatch') }
    $installedRelease = Read-FastLlmInstalledRelease -AppRoot $AppRoot
    if ($null -eq $installedRelease) { return (& $finish 'refused' 'version' 'not-a-release') }
    if ((Compare-FastLlmVersion $newVersion $installedRelease.version) -ne 1) { return (& $finish 'refused' 'version' 'not-newer') }

    # 6. run the per-user installer
    try { $exitCode = & $RunInstaller $setupPath ([bool]$Silent) } catch { return (& $finish 'failed' 'install' ([string]$_.Exception.Message)) }
    if ([int]$exitCode -ne 0) { return (& $finish 'failed' 'install' "installer-exit-${exitCode}") }

    # 7. integrity of the installed tree
    try { $integrity = & $Integrity $AppRoot } catch { return (& $finish 'failed' 'integrity' ([string]$_.Exception.Message)) }
    if ([string](Get-FastLlmUpdateProp $integrity 'status') -cne 'ok') {
        $why = [string](Get-FastLlmUpdateProp $integrity 'reason')
        if ([string]::IsNullOrEmpty($why)) { $why = [string](Get-FastLlmUpdateProp $integrity 'status') }
        return (& $finish 'failed' 'integrity' $why)
    }
    return (& $finish 'installed' 'integrity' '')
}
