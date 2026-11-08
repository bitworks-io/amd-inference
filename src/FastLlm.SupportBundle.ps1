# Support bundle: a local, user-initiated zip the user can attach to a support request. Nothing is uploaded or sent anywhere; the bundle is
# written only to the path the user chose. Entry-layer file: dot-sourced by fast-llm.ps1 and fast-llm-ui.ps1, never by FastLlm.psm1,
# because it reads settings.json (the plan and run-log code must not).
# Contents: doctor.json (the doctor report), the newest 5 run logs, settings.json (allowlisted keys only), components.json (installed rows),
# version.json. Every entry passes through ConvertTo-FastLlmRedactedText. Prompts, completions and chat text are never in any source.
Set-StrictMode -Version 2.0

$script:FastLlmSupportBundleMaxBytes = 8388608
$script:FastLlmSupportBundleLogCount = 5
$script:FastLlmRedactionOptions = [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant
# Test seam: a scriptblock param($Target) run just before the final move (to prove the move never overwrites). Default $null.
$script:FastLlmSupportBundleBeforeMove = $null
$script:FastLlmSupportBundleSettingsKeys = @('vulkanBarMitigation', 'updateCheck', 'updateChannel', 'experimentalComponents', 'serverPort', 'thinking', 'chatPage')

# Replaces what identifies the PC or the user: the profile path (as \, JSON-escaped \\ and /, any case), the computer name, the user name,
# Windows SIDs, MAC addresses and PnP instance suffixes (the last three use the patterns of tools/leak-scan.py). Returns the redacted text;
# -RedactionCount ([ref]$n) adds the number of replacements to $n. -ProfilePath, -ComputerName and -UserName are test seams.
function Get-FastLlmRedactionRules {
    [CmdletBinding()]
    param(
        [string] $ProfilePath,
        [string] $ComputerName,
        [string] $UserName,
        [string] $ShortProfilePath
    )
    if (-not $PSBoundParameters.ContainsKey('ProfilePath')) {
        $ProfilePath = [string] $env:USERPROFILE
        if ([string]::IsNullOrWhiteSpace($ProfilePath)) { $ProfilePath = [string] $HOME }
    }
    if (-not $PSBoundParameters.ContainsKey('ComputerName')) {
        $ComputerName = [string] $env:COMPUTERNAME
        if ([string]::IsNullOrWhiteSpace($ComputerName)) { $ComputerName = [Environment]::MachineName }
    }
    if (-not $PSBoundParameters.ContainsKey('UserName')) {
        $UserName = [string] $env:USERNAME
        if ([string]::IsNullOrWhiteSpace($UserName)) { $UserName = [string] $env:USER }
    }
    if (-not $PSBoundParameters.ContainsKey('ShortProfilePath') -and $env:OS -ceq 'Windows_NT' -and -not [string]::IsNullOrWhiteSpace($ProfilePath)) {
        # The 8.3 short form of the profile folder (for example JRGSMI~1) can appear in paths the system reports.
        try { $ShortProfilePath = [string] (New-Object -ComObject Scripting.FileSystemObject).GetFolder($ProfilePath).ShortPath } catch { $ShortProfilePath = '' }
    }
    $options = [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant
    $rules = New-Object 'System.Collections.Generic.List[object]'
    $edge = '(?![\p{L}\p{N}_])'
    if (-not [string]::IsNullOrWhiteSpace($ProfilePath)) {
        $back = $ProfilePath.Trim().Replace('/', '\').TrimEnd('\')
        if ($back.Length -ge 3) {
            foreach ($variant in @($back.Replace('\', '\\'), $back, $back.Replace('\', '/'))) {
                $rules.Add(@{ pattern = ([regex]::Escape($variant) + $edge); replacement = '%USERPROFILE%' })
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($ShortProfilePath)) {
        $shortBack = $ShortProfilePath.Trim().Replace('/', '\').TrimEnd('\')
        if ($shortBack.Length -ge 3 -and $shortBack -cne $ProfilePath) {
            foreach ($variant in @($shortBack.Replace('\', '\\'), $shortBack, $shortBack.Replace('\', '/'))) {
                $rules.Add(@{ pattern = ([regex]::Escape($variant) + $edge); replacement = '%USERPROFILE%' })
            }
        }
    }
    # Any other X:\Users\<name> (another account, an 8.3 short name): the windows-user-path rule of tools/leak-scan.py, same exclusions.
    $rules.Add(@{ pattern = '[A-Za-z]:(?:\\\\|\\|/)Users(?:\\\\|\\|/)(?!(?:Public|Default|test|user|username|runneradmin|example)(?![\p{L}\p{N}_.~-]))[\p{L}\p{N}._~''-]{2,}'; replacement = '%USERPROFILE%' })
    if (-not [string]::IsNullOrWhiteSpace($ComputerName) -and $ComputerName.Trim().Length -ge 2) {
        $rules.Add(@{ pattern = ('(?<![\p{L}\p{N}_])' + [regex]::Escape($ComputerName.Trim()) + $edge); replacement = '<computer>' })
    }
    $rules.Add(@{ pattern = '\bDESKTOP-[A-Z0-9]{7}\b'; replacement = '<computer>' })
    if (-not [string]::IsNullOrWhiteSpace($UserName) -and $UserName.Trim().Length -ge 2) {
        $rules.Add(@{ pattern = ('(?<![\p{L}\p{N}_])' + [regex]::Escape($UserName.Trim()) + $edge); replacement = '<user>' })
    }
    $rules.Add(@{ pattern = '\bS-1-5-21-\d{6,10}-\d{6,10}-\d{6,10}\b'; replacement = '<sid>' })
    $rules.Add(@{ pattern = '\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b'; replacement = '<mac>' })
    $rules.Add(@{ pattern = '(VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4}[^\s"'']*?\\{1,2})[0-9A-F]&[0-9A-F]{6,8}&[0-9A-F]&[0-9A-F]{8}'; replacement = '${1}<instance>' })
    return $rules.ToArray()
}

# Applies compiled rules to one string. -RedactionCount ([ref]$n) adds the number of replacements to $n.
function Invoke-FastLlmRedactionRules {
    param([AllowEmptyString()][string] $Text, $Rules, $RedactionCount)
    $result = $Text
    $total = 0
    foreach ($rule in $Rules) {
        $found = [regex]::Matches($result, [string] $rule.pattern, $script:FastLlmRedactionOptions)
        if ($found.Count -gt 0) {
            $total += $found.Count
            $result = [regex]::Replace($result, [string] $rule.pattern, [string] $rule.replacement, $script:FastLlmRedactionOptions)
        }
    }
    if ($null -ne $RedactionCount) { $RedactionCount.Value = [int] $RedactionCount.Value + $total }
    return $result
}

# Replaces what identifies the PC or the user in one string (see the rules above). -ProfilePath, -ComputerName, -UserName and
# -ShortProfilePath are test seams; -RedactionCount ([ref]$n) adds the replacement count to $n.
function ConvertTo-FastLlmRedactedText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text,
        [string] $ProfilePath,
        [string] $ComputerName,
        [string] $UserName,
        [string] $ShortProfilePath,
        [ref] $RedactionCount
    )
    $seams = @{}
    foreach ($seam in @('ProfilePath', 'ComputerName', 'UserName', 'ShortProfilePath')) { if ($PSBoundParameters.ContainsKey($seam)) { $seams[$seam] = $PSBoundParameters[$seam] } }
    $rules = Get-FastLlmRedactionRules @seams
    $count = $null
    if ($PSBoundParameters.ContainsKey('RedactionCount')) { $count = $RedactionCount }
    return (Invoke-FastLlmRedactionRules -Text $Text -Rules $rules -RedactionCount $count)
}

# Redacts a parsed document: every decoded string value and every property name; numbers, bools and nulls are never touched, so the
# result serializes to valid JSON whatever the user name is. Returns ordered dictionaries and object[] arrays.
function ConvertTo-FastLlmRedactedObject {
    param($Value, $Rules, [ref] $Count, [int] $Depth = 0)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return (Invoke-FastLlmRedactionRules -Text $Value -Rules $Rules -RedactionCount $Count) }
    if ($Value -is [uri] -or $Value -is [version]) { return (Invoke-FastLlmRedactionRules -Text ([string] $Value) -Rules $Rules -RedactionCount $Count) }
    $type = $Value.GetType()
    if ($type.IsPrimitive -or $type.IsEnum -or $Value -is [decimal] -or $Value -is [datetime] -or $Value -is [datetimeoffset] -or $Value -is [guid] -or $Value -is [timespan]) { return $Value }
    if ($Depth -ge 14) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $out = [ordered] @{}
        foreach ($key in @($Value.Keys)) {
            $name = Invoke-FastLlmRedactionRules -Text ([string] $key) -Rules $Rules -RedactionCount $Count
            $out[$name] = ConvertTo-FastLlmRedactedObject -Value $Value[$key] -Rules $Rules -Count $Count -Depth ($Depth + 1)
        }
        return $out
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = New-Object 'System.Collections.Generic.List[object]'
        foreach ($item in $Value) { $items.Add((ConvertTo-FastLlmRedactedObject -Value $item -Rules $Rules -Count $Count -Depth ($Depth + 1))) }
        return , ([object[]] $items.ToArray())
    }
    $bag = [ordered] @{}
    foreach ($property in @($Value.PSObject.Properties)) {
        $propertyValue = $null
        try { $propertyValue = $property.Value } catch { continue }
        $name = Invoke-FastLlmRedactionRules -Text ([string] $property.Name) -Rules $Rules -RedactionCount $Count
        $bag[$name] = ConvertTo-FastLlmRedactedObject -Value $propertyValue -Rules $Rules -Count $Count -Depth ($Depth + 1)
    }
    return $bag
}

function Get-FastLlmSupportBundleSafeValue {
    param($Value)
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) { return $Value }
    if ($Value -is [string] -and $Value -cmatch '^[A-Za-z0-9._-]{1,40}$') { return $Value }
    return $null
}

# The allowlisted settings: the keys above and componentLicenses.mode only. Accepted licence titles and hosts, unknown keys and any value
# that is not a short plain token are dropped. A missing or malformed file reads as {}.
function Get-FastLlmSupportBundleSettings {
    param([string] $InstallRoot)
    $out = [ordered] @{}
    try {
        $path = Join-Path $InstallRoot 'settings.json'
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $out }
        $stored = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($null -eq $stored -or $stored -isnot [pscustomobject]) { return $out }
        foreach ($key in $script:FastLlmSupportBundleSettingsKeys) {
            $property = $stored.PSObject.Properties[$key]
            if ($null -eq $property) { continue }
            $safe = Get-FastLlmSupportBundleSafeValue $property.Value
            if ($null -ne $safe) { $out[$key] = $safe }
        }
        $licenses = $stored.PSObject.Properties['componentLicenses']
        if ($null -ne $licenses -and $licenses.Value -is [pscustomobject]) {
            $mode = $licenses.Value.PSObject.Properties['mode']
            if ($null -ne $mode -and $mode.Value -is [string]) {
                $safeMode = Get-FastLlmSupportBundleSafeValue $mode.Value
                if ($null -ne $safeMode) { $out['componentLicenses'] = [ordered] @{ mode = $safeMode } }
            }
        }
    }
    catch { $null = $_ }
    return $out
}

function Read-FastLlmSupportBundleLog {
    param([string] $Path)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $reader = New-Object IO.StreamReader($stream, (New-Object Text.UTF8Encoding($false)))
        return $reader.ReadToEnd()
    }
    finally { $stream.Dispose() }
}

function ConvertTo-FastLlmSupportBundleJson {
    param($Value, [int] $Depth = 12)
    return [string] (ConvertTo-Json -InputObject $Value -Depth $Depth)
}

function New-FastLlmSupportBundle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $InstallRoot,
        [Parameter(Mandatory = $true)][string] $AppRoot,
        [Parameter(Mandatory = $true)][string] $OutputPath,
        [Parameter(Mandatory = $true)] $Doctor,
        [switch] $ListOnly,
        # Test seams for the redaction (defaults: the environment).
        [string] $ProfilePath,
        [string] $ComputerName,
        [string] $UserName,
        [string] $ShortProfilePath
    )
    $seams = @{}
    foreach ($seam in @('ProfilePath', 'ComputerName', 'UserName', 'ShortProfilePath')) { if ($PSBoundParameters.ContainsKey($seam)) { $seams[$seam] = $PSBoundParameters[$seam] } }
    $rules = Get-FastLlmRedactionRules @seams
    # A relative path means relative to the PowerShell location, not to the process directory.
    $target = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    if (Test-Path -LiteralPath $target) { throw "support-bundle-output-exists: '$target' already exists. Choose a new file name; nothing was written." }
    $folder = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { throw "support-bundle-output-folder-missing: the folder '$folder' does not exist. Nothing was written." }

    $raw = New-Object 'System.Collections.Generic.List[object]'
    # Entries are structured documents; redaction walks the decoded values and never edits serialized JSON text.
    $raw.Add(@{ name = 'doctor.json'; value = $Doctor; depth = 12 })
    $logFolder = Join-Path (Join-Path $InstallRoot 'state') 'logs'
    try {
        if (Test-Path -LiteralPath $logFolder -PathType Container) {
            $logs = @(Get-ChildItem -LiteralPath $logFolder -Filter 'run-*.jsonl' -File -ErrorAction Stop |
                    Where-Object { $_.Name -cmatch '^run-\d{8}T\d{6}Z-[A-Za-z0-9-]{1,64}\.jsonl$' } |
                    Sort-Object -Property @{ Expression = { $_.LastWriteTimeUtc }; Descending = $true }, @{ Expression = { $_.Name }; Descending = $true } |
                    Select-Object -First $script:FastLlmSupportBundleLogCount)
            foreach ($log in $logs) {
                try { $raw.Add(@{ name = 'logs/' + $log.Name; jsonl = (Read-FastLlmSupportBundleLog -Path $log.FullName) }) } catch { $null = $_ }
            }
        }
    }
    catch { $null = $_ }
    $raw.Add(@{ name = 'settings.json'; value = (Get-FastLlmSupportBundleSettings -InstallRoot $InstallRoot); depth = 4 })

    $installed = @()
    $componentsUnavailable = $false
    try {
        if ((Get-Command Get-FastLlmInstalledComponentRows -ErrorAction SilentlyContinue) -and (Get-Command Get-FastLlmComponentInventory -ErrorAction SilentlyContinue)) {
            $componentsPath = Join-Path (Join-Path $AppRoot 'config') 'components.json'
            if (Test-Path -LiteralPath $componentsPath -PathType Leaf) {
                $installed = @(Get-FastLlmInstalledComponentRows -Inventory @(Get-FastLlmComponentInventory -ComponentsPath $componentsPath -InstallRoot $InstallRoot))
            }
        }
    }
    catch { $installed = @(); $componentsUnavailable = $true }
    $components = [ordered] @{ installed = @($installed) }
    if ($componentsUnavailable) { $components.unavailable = $true }
    $raw.Add(@{ name = 'components.json'; value = $components; depth = 5 })

    $release = $null
    if (Get-Command Read-FastLlmInstalledRelease -ErrorAction SilentlyContinue) { try { $release = Read-FastLlmInstalledRelease -AppRoot $AppRoot } catch { $release = $null } }
    $version = [ordered] @{
        release    = $(if ($null -ne $release) { [ordered] @{ version = [string] $release.version; channel = [string] $release.channel } } else { $null })
        powershell = [string] $PSVersionTable.PSVersion
        os         = [string] [Environment]::OSVersion.VersionString
    }
    $raw.Add(@{ name = 'version.json'; value = $version; depth = 4 })

    $redactions = 0
    $encoding = New-Object Text.UTF8Encoding($false)
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $total = 0L
    foreach ($item in $raw) {
        if ($item.ContainsKey('jsonl')) {
            # One JSON object per line; a line that does not parse is dropped, never copied as text.
            $lines = New-Object 'System.Collections.Generic.List[string]'
            foreach ($rawLine in @(([string] $item.jsonl) -split "`r?`n")) {
                if ([string]::IsNullOrWhiteSpace($rawLine)) { continue }
                $parsed = $null
                try { $parsed = ConvertFrom-Json -InputObject $rawLine -ErrorAction Stop } catch { continue }
                $clean = ConvertTo-FastLlmRedactedObject -Value $parsed -Rules $rules -Count ([ref] $redactions)
                $lines.Add([string] (ConvertTo-Json -InputObject $clean -Compress -Depth 8))
            }
            $text = $(if ($lines.Count -gt 0) { ($lines -join "`n") + "`n" } else { '' })
        }
        else {
            $clean = ConvertTo-FastLlmRedactedObject -Value $item.value -Rules $rules -Count ([ref] $redactions)
            $text = ConvertTo-FastLlmSupportBundleJson -Value $clean -Depth ([int] $item.depth)
        }
        $bytes = $encoding.GetBytes($text)
        $total += $bytes.LongLength
        $entries.Add(@{ name = [string] $item.name; bytes = $bytes })
    }
    if ($total -gt $script:FastLlmSupportBundleMaxBytes) {
        throw "support-bundle-too-large: the bundle would hold $total bytes, over the 8 MiB limit. Nothing was written."
    }
    $listing = [pscustomobject] [ordered] @{
        entries    = @($entries | ForEach-Object { [pscustomobject] [ordered] @{ name = [string] $_.name; sizeBytes = [long] $_.bytes.LongLength } })
        redactions = [int] $redactions
        totalBytes = [long] $total
        path       = $target
        saved      = $false
    }
    if ($ListOnly) { return $listing }

    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $temporary = Join-Path $folder ('.fastllm-support-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $moved = $false
    try {
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
            try {
                foreach ($entry in $entries) {
                    $zipEntry = $zip.CreateEntry([string] $entry.name, [IO.Compression.CompressionLevel]::Optimal)
                    $entryStream = $zipEntry.Open()
                    try { $entryStream.Write($entry.bytes, 0, $entry.bytes.Length) } finally { $entryStream.Dispose() }
                }
            }
            finally { $zip.Dispose() }
        }
        finally { $stream.Dispose() }
        if ((New-Object IO.FileInfo $temporary).Length -gt $script:FastLlmSupportBundleMaxBytes) { throw 'support-bundle-too-large: the zip is over the 8 MiB limit. Nothing was written.' }
        if (Test-Path -LiteralPath $target) { throw "support-bundle-output-exists: '$target' already exists. Choose a new file name; nothing was written." }
        if ($null -ne $script:FastLlmSupportBundleBeforeMove) { & $script:FastLlmSupportBundleBeforeMove $target }
        # Never overwrites: File.Move without the overwrite flag fails when the target exists (also when it appeared after the check above).
        try { [IO.File]::Move($temporary, $target) }
        catch {
            if (Test-Path -LiteralPath $target) { throw "support-bundle-output-exists: '$target' already exists. Choose a new file name; nothing was written." }
            throw
        }
        $moved = $true
    }
    finally {
        if (-not $moved) { try { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue } catch { $null = $_ } }
    }
    $listing.saved = $true
    return $listing
}
