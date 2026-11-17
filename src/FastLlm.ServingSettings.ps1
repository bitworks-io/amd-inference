# Serving preferences (loopback port, thinking, chat page, idle stop, context profile, slots, the API key flag) stored in <InstallRoot>\settings.json.
# Dot-sourced ONLY by fast-llm.ps1, fast-llm-ui.ps1 and the start-at-sign-in launcher tool, never by src/FastLlm.psm1 or the background host: the bench path
# (Get-FastLlmPlan) reads no user settings. Windows PowerShell 5.1-safe; ASCII only.
Set-StrictMode -Version 2

if (-not (Get-Command -Name Move-FastLlmFileReplacing -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'FastLlm.FileReplace.ps1')
}

$script:FastLlmServingDefaultPort = 8080
$script:FastLlmServingDefaultThinking = 'auto'
$script:FastLlmServingDefaultChatPage = 'off'
$script:FastLlmServingDefaultIdleStopMinutes = 0
$script:FastLlmServingIdleStopChoices = @(0, 15, 30, 60)
$script:FastLlmServingDefaultContextProfile = 'default'
$script:FastLlmServingDefaultSlots = 1
$script:FastLlmServingSlotsChoices = @(1, 2)
$script:FastLlmServingSettingsMaxBytes = 16384
# The API key flag. settings.json holds only apiKey: "on"; the key itself is never a setting (it lives in the per-user store next to the settings).
$script:FastLlmServingDefaultApiKey = 'off'
$script:FastLlmServingApiKeyStoreName = 'api-key.dat'

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

# Idle stop is a closed set of minutes: 0 (Never, the default), 15, 30 or 60. An integer or its plain digits as text; nothing else.
function ConvertTo-FastLlmIdleStopMinutes {
    param($Value)
    $invalid = 'serving-settings-invalid-idle-stop: the idle stop must be 0 (never), 15, 30 or 60 minutes.'
    if ($null -eq $Value -or $Value -is [bool]) { throw $invalid }
    $given = 0
    if ($Value -is [int] -or $Value -is [long]) { if ($Value -lt 0 -or $Value -gt 60) { throw $invalid }; $given = [int] $Value }
    elseif ($Value -is [string] -and $Value -cmatch '^(0|15|30|60)$') { $given = [int] $Value }
    else { throw $invalid }
    if ($script:FastLlmServingIdleStopChoices -notcontains $given) { throw $invalid }
    return $given
}

# Context profile is a closed set: default (today's arguments) or long (the measured long-context setup, refused when nothing is measured
# for the model and engine). The match is case-sensitive.
function ConvertTo-FastLlmContextProfile {
    param($Value)
    if ($Value -is [string] -and ($Value -ceq 'default' -or $Value -ceq 'long')) { return [string] $Value }
    throw 'serving-settings-invalid-context-profile: ContextProfile must be default or long.'
}

# Slots is a closed set: 1 (the default) or 2 requests at once. An integer or its plain digit as text; nothing else.
function ConvertTo-FastLlmSlots {
    param($Value)
    $invalid = 'serving-settings-invalid-slots: Slots must be 1 or 2.'
    if ($null -eq $Value -or $Value -is [bool]) { throw $invalid }
    $given = 0
    if ($Value -is [int] -or $Value -is [long]) { if ($Value -lt 1 -or $Value -gt 2) { throw $invalid }; $given = [int] $Value }
    elseif ($Value -is [string] -and $Value -cmatch '^(1|2)\z') { $given = [int] $Value }
    else { throw $invalid }
    if ($script:FastLlmServingSlotsChoices -notcontains $given) { throw $invalid }
    return $given
}

# The API key flag is a closed set: off (the default) or on. The match is case-sensitive.
function ConvertTo-FastLlmApiKeySetting {
    param($Value)
    if ($Value -is [string] -and ($Value -ceq 'off' -or $Value -ceq 'on')) { return [string] $Value }
    throw 'serving-settings-invalid-apikey: ApiKey must be off or on.'
}

# The refusal when the API key flag cannot be known (see Get-FastLlmServingSettings). Typed, and never retried or replaced by another setup.
function New-FastLlmApiKeySettingFailure {
    $failure = New-Object -TypeName System.InvalidOperationException -ArgumentList 'api-key-setting-unreadable: FastLLM cannot tell whether the API key is required: settings.json cannot be read or its apiKey value is not on or off. Nothing was started. Run "fast-llm.ps1 settings -ApiKey on" or "-ApiKey off" to set it; if settings.json is not valid JSON, fix or delete the file first.'
    $failure.Data['FastLlmFailureCode'] = 'api-key-setting-unreadable'
    $failure.Data['FastLlmReason'] = 'ApiKeyFailed'
    return $failure
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
    $idleStop = $script:FastLlmServingDefaultIdleStopMinutes
    if (-not $read.malformed -and $read.object.Contains('idleStopMinutes')) {
        $storedIdle = $read.object['idleStopMinutes']
        if (($storedIdle -is [int] -or $storedIdle -is [long]) -and $script:FastLlmServingIdleStopChoices -contains [int] ([Math]::Min([long] $storedIdle, 2147483647L))) { $idleStop = [int] $storedIdle }
    }
    $contextProfile = $script:FastLlmServingDefaultContextProfile
    if (-not $read.malformed -and $read.object.Contains('contextProfile')) {
        $storedProfile = $read.object['contextProfile']
        if ($storedProfile -is [string] -and $storedProfile -ceq 'long') { $contextProfile = 'long' }
    }
    $slots = $script:FastLlmServingDefaultSlots
    if (-not $read.malformed -and $read.object.Contains('slots')) {
        $storedSlots = $read.object['slots']
        if (($storedSlots -is [int] -or $storedSlots -is [long]) -and [long] $storedSlots -eq 2) { $slots = 2 }
    }
    # The API key flag fails closed. It is on only for the exact stored text "on", and off only for no value or the exact text "off".
    # Any other stored value means the flag cannot be known. So does a settings file that cannot be read when this installation has a key
    # store (the key was turned on here at some time): unlike the other settings, the default (off) must not stand in then, because a start
    # would run without the key that was asked for. apiKeyUndetermined says so; a start refuses it.
    $apiKey = $script:FastLlmServingDefaultApiKey
    $apiKeyUndetermined = $false
    if ($read.malformed) {
        try { $apiKeyUndetermined = [bool] (Test-Path -LiteralPath (Join-Path $InstallRoot $script:FastLlmServingApiKeyStoreName)) } catch { $apiKeyUndetermined = $true }
    }
    elseif ($read.object.Contains('apiKey')) {
        $storedApiKey = $read.object['apiKey']
        if ($storedApiKey -is [string] -and $storedApiKey -ceq 'on') { $apiKey = 'on' }
        elseif (-not ($storedApiKey -is [string] -and $storedApiKey -ceq 'off')) { $apiKeyUndetermined = $true }
    }
    return [pscustomobject]@{
        serverPort       = $port
        thinking         = $thinking
        chatPage         = $chatPage
        idleStopMinutes  = $idleStop
        contextProfile   = $contextProfile
        slots            = $slots
        apiKey           = $apiKey
        apiKeyUndetermined = [bool] $apiKeyUndetermined
        malformed        = [bool] $read.malformed
    }
}

# Sets only the bound keys. The default value removes the key. Unknown keys are kept. A malformed file is never overwritten.
function Set-FastLlmServingSettings {
    param(
        [Parameter(Mandatory = $true)][string] $InstallRoot,
        $ServerPort,
        $Thinking,
        $ChatPage,
        $IdleStopMinutes,
        $KvContextProfile,
        $KvSlots,
        $ApiKey
    )
    if ($PSBoundParameters.ContainsKey('ApiKey')) { $ApiKey = ConvertTo-FastLlmApiKeySetting -Value $ApiKey }
    if ($PSBoundParameters.ContainsKey('ServerPort')) { $ServerPort = ConvertTo-FastLlmServerPort -Value $ServerPort }
    if ($PSBoundParameters.ContainsKey('Thinking')) { $Thinking = ConvertTo-FastLlmThinking -Value $Thinking }
    if ($PSBoundParameters.ContainsKey('ChatPage')) { $ChatPage = ConvertTo-FastLlmChatPage -Value $ChatPage }
    if ($PSBoundParameters.ContainsKey('IdleStopMinutes')) { $IdleStopMinutes = ConvertTo-FastLlmIdleStopMinutes -Value $IdleStopMinutes }
    if ($PSBoundParameters.ContainsKey('KvContextProfile')) { $KvContextProfile = ConvertTo-FastLlmContextProfile -Value $KvContextProfile }
    if ($PSBoundParameters.ContainsKey('KvSlots')) { $KvSlots = ConvertTo-FastLlmSlots -Value $KvSlots }
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
    if ($PSBoundParameters.ContainsKey('IdleStopMinutes')) {
        if ($IdleStopMinutes -eq $script:FastLlmServingDefaultIdleStopMinutes) { $merged.Remove('idleStopMinutes') }
        else { $merged['idleStopMinutes'] = $IdleStopMinutes }
    }
    if ($PSBoundParameters.ContainsKey('KvContextProfile')) {
        if ($KvContextProfile -ceq $script:FastLlmServingDefaultContextProfile) { $merged.Remove('contextProfile') }
        else { $merged['contextProfile'] = $KvContextProfile }
    }
    if ($PSBoundParameters.ContainsKey('KvSlots')) {
        if ($KvSlots -eq $script:FastLlmServingDefaultSlots) { $merged.Remove('slots') }
        else { $merged['slots'] = $KvSlots }
    }
    # Only the flag: on is stored as apiKey "on", off removes it. This also replaces a stored value that was neither.
    if ($PSBoundParameters.ContainsKey('ApiKey')) {
        if ($ApiKey -ceq $script:FastLlmServingDefaultApiKey) { $merged.Remove('apiKey') }
        else { $merged['apiKey'] = $ApiKey }
    }
    if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) { New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null }
    $path = Join-Path $InstallRoot 'settings.json'
    $temporary = "$path.tmp-$([guid]::NewGuid().ToString('N'))"
    [IO.File]::WriteAllText($temporary, (([pscustomobject] $merged) | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    Move-FastLlmFileReplacing -Source $temporary -Destination $path
}

# The one line shown when settings.json cannot be read and the defaults are used instead.
function Get-FastLlmServingMalformedWarning {
    return 'settings.json is not valid JSON, so FastLLM is using the default settings. Fix or delete the file to change settings.'
}

# The warning a live start prints when settings.json cannot be read; $null when the file is absent, valid or not in use.
function Get-FastLlmServingSettingsWarning {
    param([Parameter(Mandatory = $true)][string] $InstallRoot)
    if ((Get-FastLlmServingSettings -InstallRoot $InstallRoot).malformed) { return (Get-FastLlmServingMalformedWarning) }
    return $null
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
    $idleStop = $script:FastLlmServingDefaultIdleStopMinutes
    $contextProfile = $script:FastLlmServingDefaultContextProfile
    $slots = $script:FastLlmServingDefaultSlots
    # The API key has no start parameter: it comes from the saved setting only, so -IgnoreUserSettings (the bench path) never uses one.
    $apiKey = $script:FastLlmServingDefaultApiKey
    $apiKeyUndetermined = $false
    $source = 'default'
    $settingsMalformed = $false
    if (-not $IgnoreUserSettings) {
        $stored = Get-FastLlmServingSettings -InstallRoot $InstallRoot
        $settingsMalformed = [bool]$stored.malformed
        $apiKeyUndetermined = [bool] $stored.apiKeyUndetermined
        if ([string] $stored.apiKey -ceq 'on') {
            $apiKey = 'on'
            $source = 'settings'
        }
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
        if (-not $stored.malformed -and $stored.idleStopMinutes -ne $script:FastLlmServingDefaultIdleStopMinutes) {
            $idleStop = $stored.idleStopMinutes
            $source = 'settings'
        }
        if (-not $stored.malformed -and $stored.contextProfile -cne $script:FastLlmServingDefaultContextProfile) {
            $contextProfile = $stored.contextProfile
            $source = 'settings'
        }
        if (-not $stored.malformed -and $stored.slots -ne $script:FastLlmServingDefaultSlots) {
            $slots = $stored.slots
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
    if ($Bound.ContainsKey('IdleStopMinutes')) {
        $idleStop = ConvertTo-FastLlmIdleStopMinutes -Value $Bound['IdleStopMinutes']
        $source = 'parameter'
    }
    if ($Bound.ContainsKey('KvContextProfile')) {
        $contextProfile = ConvertTo-FastLlmContextProfile -Value $Bound['KvContextProfile']
        $source = 'parameter'
    }
    if ($Bound.ContainsKey('KvSlots')) {
        $slots = ConvertTo-FastLlmSlots -Value $Bound['KvSlots']
        $source = 'parameter'
    }
    return [pscustomobject]@{ serverPort = $port; thinking = $thinking; chatPage = $chatPage; idleStopMinutes = $idleStop; contextProfile = $contextProfile; slots = $slots; apiKey = $apiKey; apiKeyUndetermined = $apiKeyUndetermined; source = $source; settingsMalformed = $settingsMalformed }
}

# The serving parameters a user's own background-host start takes from the saved settings, as a hashtable to splat into
# Start-FastLlmBackgroundHost. Built from Resolve-FastLlmServingOptions (one precedence and validation path); malformed or
# invalid settings give the defaults. As the CLI does, the default port maps to 0, the catalog port.
# The API key is the exception to "defaults": when its flag cannot be known this throws api-key-setting-unreadable (nothing is started), and
# UseApiKey = 'on' is added only when the key is on, so the arguments of a start without a key are the ones they always were.
function Get-FastLlmServingHostArguments {
    param([Parameter(Mandatory = $true)][string] $InstallRoot)
    $resolved = Resolve-FastLlmServingOptions -InstallRoot $InstallRoot -Bound @{}
    if ([bool] $resolved.apiKeyUndetermined) { throw (New-FastLlmApiKeySettingFailure) }
    $port = 0
    if ([int] $resolved.serverPort -ne $script:FastLlmServingDefaultPort) { $port = [int] $resolved.serverPort }
    $arguments = @{
        ServerPort = $port
        Thinking = [string] $resolved.thinking
        ChatPage = [string] $resolved.chatPage
        IdleStopMinutes = [int] $resolved.idleStopMinutes
    }
    if ([string] $resolved.apiKey -ceq 'on') { $arguments.UseApiKey = 'on' }
    return $arguments
}

# settings -ApiKey on|off|rotate|show, and the same four actions for the window. The store functions come from the FastLlm module (the caller
# has imported it). Returns what happened as an object: the flag, the key's public id, and lines to show. Only show returns the key, in
# .key, for the caller to print or copy; nothing here writes it anywhere.
#   on      keeps a readable key, creates one when there is no store, refuses (changing nothing) when the store cannot be read.
#           The flag is saved only after a readable key exists.
#   off     removes the flag. The stored key is kept, so turning the key on again does not change it.
#   rotate  creates a new key in place of the stored one (one atomic replace). The flag is not changed.
#   show    returns the stored key.
# Every change applies at the next start: a running server keeps the key (or no key) it was started with.
function Invoke-FastLlmApiKeySetting {
    param(
        [Parameter(Mandatory = $true)][string] $InstallRoot,
        [Parameter(Mandatory = $true)][ValidateSet('on', 'off', 'rotate', 'show')][string] $Action
    )
    $Action = $Action.ToLowerInvariant()
    $result = [ordered]@{ action = $Action; apiKey = $null; apiKeyId = $null; created = $false; lines = @() }
    if ($Action -cne 'show') {
        # A settings file that cannot be read is refused before a key is created or replaced.
        if ((Read-FastLlmServingSettingsObject -InstallRoot $InstallRoot).malformed) { throw 'serving-settings-malformed: settings.json is not valid JSON. Fix or delete it, then try again.' }
    }
    if ($Action -ceq 'on') {
        $store = Initialize-FastLlmApiKeyStore -InstallRoot $InstallRoot
        Set-FastLlmServingSettings -InstallRoot $InstallRoot -ApiKey 'on'
        $result.apiKeyId = [string] $store.apiKeyId
        $result.created = [bool] $store.created
        if ($store.created) { $result.lines = @('The API key is on from the next start. A new key was created (key id ' + $store.apiKeyId + ').', 'Show it with: fast-llm.ps1 settings -ApiKey show') }
        else { $result.lines = @('The API key is on from the next start. The existing key is used (key id ' + $store.apiKeyId + ').', 'Show it with: fast-llm.ps1 settings -ApiKey show') }
    }
    elseif ($Action -ceq 'off') {
        Set-FastLlmServingSettings -InstallRoot $InstallRoot -ApiKey 'off'
        $result.apiKeyId = (Get-FastLlmApiKeyStoreState -InstallRoot $InstallRoot).apiKeyId
        $result.lines = @('The API key is off from the next start. A server that is running now keeps the key it was started with until it stops.')
    }
    elseif ($Action -ceq 'rotate') {
        $store = Reset-FastLlmApiKeyStore -InstallRoot $InstallRoot
        $result.apiKeyId = [string] $store.apiKeyId
        $result.created = $true
        $result.lines = @('A new API key was created (key id ' + $store.apiKeyId + '). It applies at the next start; from then on apps need the new key and the old key stops working.', 'Show it with: fast-llm.ps1 settings -ApiKey show')
    }
    else {
        $result.key = Get-FastLlmApiKeyForDisplay -InstallRoot $InstallRoot
        $result.apiKeyId = (Get-FastLlmApiKeyStoreState -InstallRoot $InstallRoot).apiKeyId
    }
    $flag = Get-FastLlmServingSettings -InstallRoot $InstallRoot
    $result.apiKey = [string] $flag.apiKey
    if ($Action -ceq 'rotate' -and [string] $flag.apiKey -cne 'on') { $result.lines = @($result.lines) + @('The API key setting is off: turn it on with: fast-llm.ps1 settings -ApiKey on') }
    return [pscustomobject] $result
}
