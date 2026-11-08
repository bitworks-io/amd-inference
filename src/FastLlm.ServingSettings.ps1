# Serving preferences (loopback port today) stored in <InstallRoot>\settings.json.
# Dot-sourced ONLY by fast-llm.ps1 and fast-llm-ui.ps1, never by src/FastLlm.psm1 or the background host: the bench path
# (Get-FastLlmPlan) reads no user settings. Windows PowerShell 5.1-safe; ASCII only.
Set-StrictMode -Version 2

if (-not (Get-Command -Name Move-FastLlmFileReplacing -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'FastLlm.FileReplace.ps1')
}

$script:FastLlmServingDefaultPort = 8080
$script:FastLlmServingDefaultThinking = 'auto'
$script:FastLlmServingDefaultChatPage = 'off'
$script:FastLlmServingSettingsMaxBytes = 16384

function Test-FastLlmServerPort {
    param([Parameter(Mandatory = $true)][int] $Port)
    return ($Port -ge 1024 -and $Port -le 65535)
}

# Returns @{ malformed = [bool]; object = [ordered] }. An absent file is empty and not malformed. A file over 16 KiB, a reparse
# point, text that is not a JSON object, or text that does not parse is malformed.
function Read-FastLlmServingSettingsObject {
    param([Parameter(Mandatory = $true)][string] $InstallRoot)
    $result = [ordered]@{}
    $path = Join-Path $InstallRoot 'settings.json'
    if (-not (Test-Path -LiteralPath $path)) { return @{ malformed = $false; object = $result } }
    try {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($item.PSIsContainer) { return @{ malformed = $true; object = $result } }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return @{ malformed = $true; object = $result } }
        if ($item.Length -gt $script:FastLlmServingSettingsMaxBytes) { return @{ malformed = $true; object = $result } }
        $text = [IO.File]::ReadAllText($path)
        $stored = $text | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $stored -or $stored -isnot [pscustomobject]) { return @{ malformed = $true; object = $result } }
        foreach ($property in $stored.PSObject.Properties) { $result[$property.Name] = $property.Value }
    }
    catch { return @{ malformed = $true; object = [ordered]@{} } }
    return @{ malformed = $false; object = $result }
}

function Get-FastLlmServingSettings {
    param([Parameter(Mandatory = $true)][string] $InstallRoot)
    $read = Read-FastLlmServingSettingsObject -InstallRoot $InstallRoot
    $port = $script:FastLlmServingDefaultPort
    if (-not $read.malformed -and $read.object.Contains('serverPort')) {
        $value = $read.object['serverPort']
        if (($value -is [int] -or $value -is [long]) -and (Test-FastLlmServerPort -Port ([int] [Math]::Min([long] $value, 2147483647L)))) { $port = [int] $value }
    }
    return [pscustomobject]@{
        serverPort = $port
        thinking   = $script:FastLlmServingDefaultThinking
        chatPage   = $script:FastLlmServingDefaultChatPage
        malformed  = [bool] $read.malformed
    }
}

# Sets only the bound keys. The default value removes the key. Unknown keys are kept. A malformed file is never overwritten.
function Set-FastLlmServingSettings {
    param(
        [Parameter(Mandatory = $true)][string] $InstallRoot,
        [int] $ServerPort
    )
    if ($PSBoundParameters.ContainsKey('ServerPort') -and -not (Test-FastLlmServerPort -Port $ServerPort)) {
        throw 'serving-settings-invalid-port: the port must be a whole number from 1024 to 65535.'
    }
    $read = Read-FastLlmServingSettingsObject -InstallRoot $InstallRoot
    if ($read.malformed) { throw 'serving-settings-malformed: settings.json is not valid JSON. Fix or delete it, then try again.' }
    $merged = $read.object
    if ($PSBoundParameters.ContainsKey('ServerPort')) {
        if ($ServerPort -eq $script:FastLlmServingDefaultPort) { $merged.Remove('serverPort') }
        else { $merged['serverPort'] = $ServerPort }
    }
    if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) { New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null }
    $path = Join-Path $InstallRoot 'settings.json'
    $temporary = "$path.tmp-$([guid]::NewGuid().ToString('N'))"
    [IO.File]::WriteAllText($temporary, (([pscustomobject] $merged) | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    Move-FastLlmFileReplacing -Source $temporary -Destination $path
}

# Precedence: explicit parameter in -Bound, then settings (unless -IgnoreUserSettings), then the default.
function Resolve-FastLlmServingOptions {
    param(
        [Parameter(Mandatory = $true)][string] $InstallRoot,
        [Parameter(Mandatory = $true)][hashtable] $Bound,
        [switch] $IgnoreUserSettings
    )
    $port = $script:FastLlmServingDefaultPort
    $thinking = $script:FastLlmServingDefaultThinking
    $chatPage = $script:FastLlmServingDefaultChatPage
    $source = 'default'
    if (-not $IgnoreUserSettings) {
        $stored = Get-FastLlmServingSettings -InstallRoot $InstallRoot
        if (-not $stored.malformed -and $stored.serverPort -ne $script:FastLlmServingDefaultPort) {
            $port = $stored.serverPort
            $source = 'settings'
        }
    }
    if ($Bound.ContainsKey('ServerPort')) {
        $given = 0
        if (-not [int]::TryParse([string] $Bound['ServerPort'], [ref] $given) -or -not (Test-FastLlmServerPort -Port $given)) {
            throw 'serving-settings-invalid-port: the port must be a whole number from 1024 to 65535.'
        }
        $port = $given
        $source = 'parameter'
    }
    return [pscustomobject]@{ serverPort = $port; thinking = $thinking; chatPage = $chatPage; source = $source }
}
