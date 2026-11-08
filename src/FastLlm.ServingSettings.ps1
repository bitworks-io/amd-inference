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

# Strict port parse: integer text, or an integral int/long, then the 1024-65535 range. Anything else throws.
function ConvertTo-FastLlmServerPort {
    param($Value)
    $invalid = 'serving-settings-invalid-port: the port must be a whole number from 1024 to 65535.'
    if ($null -eq $Value) { throw $invalid }
    if ($Value -is [bool] -or $Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        # Only an integral floating value is a whole number; text form is checked below.
        if ($Value -is [bool]) { throw $invalid }
        if ([Math]::Floor([double] $Value) -ne [double] $Value) { throw $invalid }
        $Value = ([decimal] $Value).ToString([Globalization.CultureInfo]::InvariantCulture)
    }
    $given = 0
    $text = ([string] $Value).Trim()
    if (-not [int]::TryParse($text, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref] $given)) { throw $invalid }
    if (-not (Test-FastLlmServerPort -Port $given)) { throw $invalid }
    return $given
}

# Thinking is a closed set: auto (today's arguments) or off (appends --reasoning off). The match is case-sensitive.
function ConvertTo-FastLlmThinking {
    param($Value)
    if ($Value -is [string] -and ($Value -ceq 'auto' -or $Value -ceq 'off')) { return [string] $Value }
    throw 'serving-settings-invalid-thinking: Thinking must be auto or off.'
}

# Chat page is a closed set: off (default, --no-ui stays) or on (omits only --no-ui). The match is case-sensitive.
function ConvertTo-FastLlmChatPage {
    param($Value)
    if ($Value -is [string] -and ($Value -ceq 'off' -or $Value -ceq 'on')) { return [string] $Value }
    throw 'serving-settings-invalid-chatpage: ChatPage must be off or on.'
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
    $thinking = $script:FastLlmServingDefaultThinking
    if (-not $read.malformed -and $read.object.Contains('thinking')) {
        $storedThinking = $read.object['thinking']
        if ($storedThinking -is [string] -and $storedThinking -ceq 'off') { $thinking = 'off' }
    }
    $chatPage = $script:FastLlmServingDefaultChatPage
    if (-not $read.malformed -and $read.object.Contains('chatPage')) {
        $storedChatPage = $read.object['chatPage']
        if ($storedChatPage -is [string] -and $storedChatPage -ceq 'on') { $chatPage = 'on' }
    }
    return [pscustomobject]@{
        serverPort = $port
        thinking   = $thinking
        chatPage   = $chatPage
        malformed  = [bool] $read.malformed
    }
}

# Sets only the bound keys. The default value removes the key. Unknown keys are kept. A malformed file is never overwritten.
function Set-FastLlmServingSettings {
    param(
        [Parameter(Mandatory = $true)][string] $InstallRoot,
        $ServerPort,
        $Thinking,
        $ChatPage
    )
    if ($PSBoundParameters.ContainsKey('ServerPort')) { $ServerPort = ConvertTo-FastLlmServerPort -Value $ServerPort }
    if ($PSBoundParameters.ContainsKey('Thinking')) { $Thinking = ConvertTo-FastLlmThinking -Value $Thinking }
    if ($PSBoundParameters.ContainsKey('ChatPage')) { $ChatPage = ConvertTo-FastLlmChatPage -Value $ChatPage }
    $read = Read-FastLlmServingSettingsObject -InstallRoot $InstallRoot
    if ($read.malformed) { throw 'serving-settings-malformed: settings.json is not valid JSON. Fix or delete it, then try again.' }
    $merged = $read.object
    if ($PSBoundParameters.ContainsKey('ServerPort')) {
        if ($ServerPort -eq $script:FastLlmServingDefaultPort) { $merged.Remove('serverPort') }
        else { $merged['serverPort'] = $ServerPort }
    }
    if ($PSBoundParameters.ContainsKey('Thinking')) {
        if ($Thinking -ceq $script:FastLlmServingDefaultThinking) { $merged.Remove('thinking') }
        else { $merged['thinking'] = $Thinking }
    }
    if ($PSBoundParameters.ContainsKey('ChatPage')) {
        if ($ChatPage -ceq $script:FastLlmServingDefaultChatPage) { $merged.Remove('chatPage') }
        else { $merged['chatPage'] = $ChatPage }
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
        if (-not $stored.malformed -and $stored.thinking -cne $script:FastLlmServingDefaultThinking) {
            $thinking = $stored.thinking
            $source = 'settings'
        }
        if (-not $stored.malformed -and $stored.chatPage -cne $script:FastLlmServingDefaultChatPage) {
            $chatPage = $stored.chatPage
            $source = 'settings'
        }
    }
    if ($Bound.ContainsKey('ServerPort')) {
        $given = ConvertTo-FastLlmServerPort -Value $Bound['ServerPort']
        $port = $given
        $source = 'parameter'
    }
    if ($Bound.ContainsKey('Thinking')) {
        $thinking = ConvertTo-FastLlmThinking -Value $Bound['Thinking']
        $source = 'parameter'
    }
    if ($Bound.ContainsKey('ChatPage')) {
        $chatPage = ConvertTo-FastLlmChatPage -Value $Bound['ChatPage']
        $source = 'parameter'
    }
    return [pscustomobject]@{ serverPort = $port; thinking = $thinking; chatPage = $chatPage; source = $source }
}
