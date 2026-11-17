# Connection info for the "Connect an app" dialog and `status`, the client setting cards, and the user-run API-format check.
# Dot-sourced ONLY by fast-llm.ps1 and fast-llm-ui.ps1, never by src/FastLlm.psm1 or the background host. Windows PowerShell 5.1-safe; ASCII only.
# HONESTY: every client card copies only settings its own documentation names (the doc URL sits beside each card) and makes no claim
# about how well a client behaves with a local model. The API check records numbers and pass/fail only, never prompt or completion text.
Set-StrictMode -Version 2

# Coding agents often send requests longer than this; below it the agent warning is shown.
$script:FastLlmConnectAgentMinContext = 32768
$script:FastLlmConnectResponsesLabel = '/v1/responses: partial at this engine version'
$script:FastLlmConnectClaudeCodeNote = "Claude Code is designed for Anthropic's Claude models; results with a local model may vary."
$script:FastLlmConnectUnknownContextNotice = 'FastLLM is not running, so the context limit is not known yet. Coding agents often send requests longer than 32,768 tokens; check the limit after FastLLM starts.'
$script:FastLlmApiCheckNotReadyMessage = 'Start FastLLM and wait for Ready before running the API check.'
$script:FastLlmApiCheckPrompt = 'Reply with one short word.'
# The API key in a card. Connection info never holds the key: with the key on, a card carries the token {KEY} where the key goes. The window
# shows the placeholder below in its place and puts the real key in only when the user presses a card's Copy button. So the status document,
# -AsJson output and the support bundle cannot contain the key.
$script:FastLlmConnectKeyToken = '{KEY}'
$script:FastLlmConnectKeyPlaceholder = '<your FastLLM key>'
$script:FastLlmApiCheckKeyExposedMessage = 'api-key-listener-changed: Right after the API check sent a request with the API key, the program listening on the FastLLM port could no longer be confirmed to be the running FastLLM server. Another program may have received the key. Stop FastLLM, create a new key (fast-llm.ps1 settings -ApiKey rotate), give the new key to your apps, then start again.'
$script:FastLlmApiCheckUnauthorizedNote = 'The server refused the API key (HTTP 401). If you created a new key after this server started, restart FastLLM to use it.'

# Endpoints exist at both pinned engine builds (upstream server README b10698 lines 1463 and 1572; b11658 lines 1488 and 1624).
# FastLLM passes no flag that disables them.
$script:FastLlmConnectEndpoints = @(
    @{ path = '/v1/chat/completions'; label = 'OpenAI-compatible chat' }
    @{ path = '/v1/completions'; label = 'OpenAI-compatible text completion' }
    @{ path = '/v1/models'; label = 'model list' }
    @{ path = '/v1/messages'; label = 'Anthropic-compatible' }
    @{ path = '/v1/responses'; label = $script:FastLlmConnectResponsesLabel }
)

# Client cards. Tokens: {BASE} OpenAI base URL, {ANTHROPIC} Anthropic base URL, {HOSTPORT} host and port, {MODEL}, {LIMIT} the limit line.
# Each doc URL is repeated in a comment; the card copies only what that page documents.
# keyTemplate is the card when the API key is on. It uses only the key setting the card's own documentation page names; where that page
# names none, the card says so and gives the key as FastLLM's own fact. {KEY} is left as it is by Get-FastLlmConnectionInfo.
$script:FastLlmConnectClients = @(
    @{
        id = 'openai-compatible'; title = 'Any OpenAI-compatible app'
        # https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md (the server's own OpenAI-compatible endpoints)
        docUrl = 'https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md'
        template = @'
Base URL: {BASE}
Model: {MODEL}
API key: any text (FastLLM's own fact: it sets no key, so any text works)
{LIMIT}
'@
        # The server README above documents the API key (--api-key) and that clients send it as "Authorization: Bearer <key>".
        keyTemplate = @'
Base URL: {BASE}
Model: {MODEL}
API key: {KEY}
(FastLLM's own fact: the API key is on, so every request needs this key, sent as "Authorization: Bearer <key>".)
{LIMIT}
'@
    }
    @{
        id = 'open-webui'; title = 'Open WebUI'
        # https://docs.openwebui.com/getting-started/quick-start/connect-a-provider/starting-with-llama-cpp
        # Menu path, the URL ending in /v1, and Auth "None" for a keyless server are what that page documents.
        docUrl = 'https://docs.openwebui.com/getting-started/quick-start/connect-a-provider/starting-with-llama-cpp'
        template = @'
Settings > Admin > Connections > OpenAI > Add Connection
URL: {BASE}
Auth: None
Model: {MODEL}
{LIMIT}
'@
        # That page shows a keyless server (Auth "None") and names no key setting for llama.cpp, so the card says so.
        keyTemplate = @'
Settings > Admin > Connections > OpenAI > Add Connection
URL: {BASE}
Model: {MODEL}
The page linked below shows a server without a key and names no key setting.
FastLLM's own fact: the API key is on, so this connection must send this key as a Bearer token: {KEY}
{LIMIT}
'@
    }
    @{
        id = 'continue'; title = 'Continue'
        # https://docs.continue.dev/customize/model-providers/more/llamacpp (config.yaml, provider llama.cpp, apiBase without /v1)
        docUrl = 'https://docs.continue.dev/customize/model-providers/more/llamacpp'
        template = @'
models:
  - name: FastLLM
    provider: llama.cpp
    model: {MODEL}
    apiBase: http://{HOSTPORT}
{LIMIT}
'@
        # That page's llama.cpp example has no key setting, so the card says so.
        keyTemplate = @'
models:
  - name: FastLLM
    provider: llama.cpp
    model: {MODEL}
    apiBase: http://{HOSTPORT}
The page linked below names no key setting for this provider.
FastLLM's own fact: the API key is on, so requests must send this key as a Bearer token: {KEY}
{LIMIT}
'@
    }
    @{
        id = 'cline-roo'; title = 'Cline and Roo Code'
        # Cline: https://docs.cline.bot/provider-config/openai-compatible
        # Roo Code: https://roocodeinc.github.io/Roo-Code/providers/openai-compatible
        docUrl = 'https://docs.cline.bot/provider-config/openai-compatible'
        docUrls = @('https://docs.cline.bot/provider-config/openai-compatible', 'https://roocodeinc.github.io/Roo-Code/providers/openai-compatible')
        template = @'
API Provider: OpenAI Compatible
Base URL: {BASE}
API Key: any text (FastLLM's own fact: it sets no key, so any text works)
Model: {MODEL}
Model Configuration > Context Window (Cline: "Context Window size"): {CONTEXT}
Roo Code's documentation says the model it uses must offer native tool calling.
{LIMIT}
'@
        # Both pages document the "API Key" field of the OpenAI Compatible provider.
        keyTemplate = @'
API Provider: OpenAI Compatible
Base URL: {BASE}
API Key: {KEY}
Model: {MODEL}
Model Configuration > Context Window (Cline: "Context Window size"): {CONTEXT}
Roo Code's documentation says the model it uses must offer native tool calling.
{LIMIT}
'@
    }
    @{
        id = 'claude-code'; title = 'Claude Code'
        # https://code.claude.com/docs/en/llm-gateway-connect.md (ANTHROPIC_BASE_URL and ANTHROPIC_AUTH_TOKEN; the page's own
        # check posts to $ANTHROPIC_BASE_URL/v1/messages, so the base URL has no /v1)
        # https://code.claude.com/docs/en/llm-gateway-protocol.md (what Claude Code sends to a gateway)
        docUrl = 'https://code.claude.com/docs/en/llm-gateway-connect.md'
        docUrls = @('https://code.claude.com/docs/en/llm-gateway-connect.md', 'https://code.claude.com/docs/en/llm-gateway-protocol.md')
        template = @'
Claude Code is designed for Anthropic's Claude models; results with a local model may vary.
PowerShell:
  $env:ANTHROPIC_BASE_URL = "{ANTHROPIC}"
  $env:ANTHROPIC_AUTH_TOKEN = "any-text"
(FastLLM's own fact: it sets no key, so any text works.)
FastLLM serves the model as {MODEL}.
{LIMIT}
'@
        # ANTHROPIC_AUTH_TOKEN is the documented variable (sent as "Authorization: Bearer").
        keyTemplate = @'
Claude Code is designed for Anthropic's Claude models; results with a local model may vary.
PowerShell:
  $env:ANTHROPIC_BASE_URL = "{ANTHROPIC}"
  $env:ANTHROPIC_AUTH_TOKEN = "{KEY}"
(FastLLM's own fact: the API key is on, so this must be the FastLLM key.)
FastLLM serves the model as {MODEL}.
{LIMIT}
'@
    }
    @{
        id = 'codex'; title = 'Codex'
        # https://learn.chatgpt.com/docs/config-file/config-advanced (custom model providers: a local Ollama provider with base_url ending in /v1 and no env_key;
        # wire_api = "responses" appears in the documentation's proxy and Azure examples)
        docUrl = 'https://learn.chatgpt.com/docs/config-file/config-advanced'
        template = @'
# config.toml
model = "{MODEL}"
model_provider = "fastllm"

[model_providers.fastllm]
name = "FastLLM"
base_url = "{BASE}"
wire_api = "responses"

The provider block follows the Codex documentation's local example (base_url ends in /v1 there too, with no key setting). wire_api = "responses" is the setting the documentation's proxy and Azure examples use; FastLLM's own fact: it serves the Responses API at /v1/responses.
FastLLM's own fact: it needs no key, so this card sets none.
/v1/responses: partial at this engine version
{LIMIT}
'@
        # env_key is the documented provider setting: the name of the environment variable that holds the key.
        keyTemplate = @'
# config.toml
model = "{MODEL}"
model_provider = "fastllm"

[model_providers.fastllm]
name = "FastLLM"
base_url = "{BASE}"
wire_api = "responses"
env_key = "FASTLLM_API_KEY"

PowerShell, before starting Codex:
  $env:FASTLLM_API_KEY = "{KEY}"

The provider block follows the Codex documentation's custom provider examples (base_url ends in /v1 there too). env_key is the documentation's setting for the environment variable that holds the key; the variable name FASTLLM_API_KEY is this card's choice. wire_api = "responses" is the setting the documentation's proxy and Azure examples use; FastLLM's own fact: it serves the Responses API at /v1/responses.
FastLLM's own fact: the API key is on, so the variable must hold the FastLLM key.
/v1/responses: partial at this engine version
{LIMIT}
'@
    }
)

function Get-FastLlmConnectProp {
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    try {
        if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] } else { return $null } }
        $property = $Object.PSObject.Properties[$Name]
        # A one-element array must stay an array (the comma stops the pipeline from unrolling it).
        if ($property) { $value = $property.Value; if ($value -is [array]) { return ,$value } else { return $value } }
    }
    catch { $null = $_ }
    return $null
}

function Format-FastLlmConnectNumber {
    param([long] $Value)
    return $Value.ToString('N0', [Globalization.CultureInfo]::InvariantCulture)
}

# The agent warning for a known context below the threshold; otherwise $null.
function Get-FastLlmConnectAgentWarning {
    param($ContextTokens)
    if ($null -eq $ContextTokens) { return $null }
    if ([long] $ContextTokens -ge $script:FastLlmConnectAgentMinContext) { return $null }
    return ("This setup's context is {0} tokens. Coding agents such as Claude Code, Codex, Cline and Roo Code often send longer requests; those requests are refused with an error." -f (Format-FastLlmConnectNumber -Value ([long] $ContextTokens)))
}

# The embedding sidecar's block of a status document (sidecars[] with exactly one block whose role is embedding), or $null. Tolerant:
# anything else - no field, not a list, more than one block, another role - is $null.
function Get-FastLlmConnectSidecarBlock {
    param($Status)
    $listed = Get-FastLlmConnectProp $Status 'sidecars'
    if ($null -eq $listed -or $listed -is [string] -or -not ($listed -is [array])) { return $null }
    $blocks = @($listed)
    if ($blocks.Count -ne 1 -or $null -eq $blocks[0]) { return $null }
    $role = Get-FastLlmConnectProp $blocks[0] 'role'
    if (-not ($role -is [string]) -or $role -cne 'embedding') { return $null }
    return $blocks[0]
}

# The /v1/embeddings row of Connect an app, or $null. It exists only for what the supervisor itself checked: FastLLM is running, the
# sidecar's block says ready, its start check passed, and its endpoint is a loopback address on a port of its own. The embeddings server is a
# SEPARATE server: the row carries its own base URL and is never listed among the endpoints of the text server's base URL.
function Get-FastLlmConnectEmbeddings {
    param($Status, [bool] $ApiKeyRequired = $false)
    $active = Get-FastLlmConnectProp $Status 'active'
    if (-not ($active -is [bool] -and $active)) { return $null }
    $block = Get-FastLlmConnectSidecarBlock -Status $Status
    if ($null -eq $block) { return $null }
    $phase = Get-FastLlmConnectProp $block 'phase'
    if (-not ($phase -is [string]) -or $phase -cne 'ready') { return $null }
    $canary = Get-FastLlmConnectProp $block 'canary'
    $canaryOk = Get-FastLlmConnectProp $canary 'ok'
    if (-not ($canaryOk -is [bool] -and $canaryOk)) { return $null }
    $dimension = Get-FastLlmConnectProp $canary 'dimension'
    if (-not ($dimension -is [int] -or $dimension -is [long]) -or [long] $dimension -lt 1 -or [long] $dimension -gt 65536) { return $null }
    $endpoint = Get-FastLlmConnectProp $block 'endpoint'
    if (-not ($endpoint -is [string])) { return $null }
    $match = [regex]::Match($endpoint, '\Ahttp://127\.0\.0\.1:([0-9]{1,5})/v1\z')
    if (-not $match.Success) { return $null }
    $port = [int] $match.Groups[1].Value
    if ($port -lt 1024 -or $port -gt 65535) { return $null }
    $componentId = Get-FastLlmConnectProp $block 'componentId'
    if (-not ($componentId -is [string]) -or $componentId -cnotmatch '\A[a-z0-9][a-z0-9.\-]{1,120}\z') { return $null }
    return [pscustomobject] [ordered] @{
        path           = '/v1/embeddings'
        label          = 'OpenAI-compatible embeddings (a separate server with its own base URL)'
        baseUrl        = 'http://127.0.0.1:' + $port + '/v1'
        modelName      = $componentId
        dimension      = [int] $dimension
        apiKeyRequired = [bool] $ApiKeyRequired
    }
}

# One plain line about the embedding sidecar for `status`, or $null when the status has no sidecar block. It states what was checked.
function Get-FastLlmEmbeddingsStatusText {
    param($Status)
    $block = Get-FastLlmConnectSidecarBlock -Status $Status
    if ($null -eq $block) { return $null }
    $phase = [string] (Get-FastLlmConnectProp $block 'phase')
    if ($phase -ceq 'ready') {
        $row = Get-FastLlmConnectEmbeddings -Status $Status
        if ($null -ne $row) { return "Embeddings: ready at $($row.baseUrl) (model '$($row.modelName)', $($row.dimension) dimensions)." }
        return 'Embeddings: not available.'
    }
    if ($phase -ceq 'failed') {
        $code = Get-FastLlmConnectProp $block 'failureCode'
        # A key that may have been seen stops the whole run: that code never says the model is not affected.
        if ($code -is [string] -and $code -ceq 'api-key-listener-changed') { return "Embeddings: not available ($code). The API key may have been seen by another program: create a new key (fast-llm.ps1 settings -ApiKey rotate), give it to your apps, then start again." }
        if ($code -is [string] -and $code -cmatch '\A[a-z][a-z0-9-]{0,63}\z') { return "Embeddings: not available ($code). The model is not affected." }
        return 'Embeddings: not available. The model is not affected.'
    }
    if ($phase -ceq 'stopped') { return 'Embeddings: stopped.' }
    if (@('waiting', 'starting', 'checking') -ccontains $phase) { return 'Embeddings: starting.' }
    return 'Embeddings: not available.'
}

# Status in, connection facts out. Every read is tolerant: the status may be from an older version, partial, or not running.
function Get-FastLlmConnectionInfo {
    [CmdletBinding()]
    param($Status, [string] $InstallRoot, $Settings)
    $port = 8080
    if ($null -eq $Settings -and $InstallRoot -and (Get-Command -Name Get-FastLlmServingSettings -ErrorAction SilentlyContinue)) {
        try { $Settings = Get-FastLlmServingSettings -InstallRoot $InstallRoot } catch { $Settings = $null }
    }
    $configured = Get-FastLlmConnectProp $Settings 'serverPort'
    $parsed = 0
    if ($null -ne $configured -and [int]::TryParse([string] $configured, [ref] $parsed) -and $parsed -ge 1024 -and $parsed -le 65535) { $port = $parsed }

    $running = $false
    $activeValue = Get-FastLlmConnectProp $Status 'active'
    if ($activeValue -is [bool] -and $activeValue) { $running = $true }
    $modelName = $null
    $contextTokens = $null
    if ($running) {
        $endpoint = [string] (Get-FastLlmConnectProp $Status 'endpoint')
        $match = [regex]::Match($endpoint, '^http://127\.0\.0\.1:(\d{1,5})(?:/v1)?/?$')
        if ($match.Success) {
            $endpointPort = [int] $match.Groups[1].Value
            if ($endpointPort -ge 1024 -and $endpointPort -le 65535) { $port = $endpointPort }
        }
        $id = Get-FastLlmConnectProp $Status 'modelId'
        if ($id -is [string] -and -not [string]::IsNullOrWhiteSpace($id)) { $modelName = $id }
        $size = Get-FastLlmConnectProp (Get-FastLlmConnectProp $Status 'recipe') 'contextSize'
        $sizeParsed = 0L
        if ($null -ne $size -and [long]::TryParse([string] $size, [ref] $sizeParsed) -and $sizeParsed -gt 0) { $contextTokens = $sizeParsed }
        # With a serving profile (two slots, or a long context) one request gets the per-slot context, never the total: the limit line, the agent
        # warning and the client context all use it. A value that is not a positive whole number no larger than the total is ignored.
        $perSlot = Get-FastLlmConnectProp (Get-FastLlmConnectProp $Status 'recipe') 'contextPerSlot'
        if ($null -ne $contextTokens -and ($perSlot -is [int] -or $perSlot -is [long]) -and [long] $perSlot -gt 0 -and [long] $perSlot -le $contextTokens) { $contextTokens = [long] $perSlot }
    }
    # The API key. Running: only what the run proved (the status says apiKey "on" after the 401/200 check, with the key's public id).
    # Not running: the saved setting, which is what the next start will use. No key ever enters this function: there is no parameter,
    # setting or status field through which one could.
    # A run that is still starting has proved nothing yet; like "not running" it shows what the saved setting asks for, so a card never
    # says "no key" about a server that is about to require one. A run that is Ready without the key says so, whatever the setting is now.
    $apiKeyRequired = $false
    $apiKeyId = $null
    $apiKeyState = 'off'
    $statusApiKey = Get-FastLlmConnectProp $Status 'apiKey'
    $statusPhase = Get-FastLlmConnectProp $Status 'phase'
    $settingApiKey = Get-FastLlmConnectProp $Settings 'apiKey'
    $settingOn = [bool] ($settingApiKey -is [string] -and $settingApiKey -ceq 'on')
    if ($running -and $statusApiKey -is [string] -and $statusApiKey -ceq 'on') {
        $apiKeyRequired = $true
        $apiKeyState = 'on'
        $statusApiKeyId = Get-FastLlmConnectProp $Status 'apiKeyId'
        if ($statusApiKeyId -is [string] -and $statusApiKeyId -cmatch '\A[0-9a-f]{8}\z') { $apiKeyId = $statusApiKeyId }
    }
    elseif ($settingOn -and -not $running) { $apiKeyRequired = $true; $apiKeyState = 'on-at-next-start' }
    elseif ($settingOn -and -not ($statusPhase -is [string] -and $statusPhase -ceq 'ready')) { $apiKeyRequired = $true; $apiKeyState = 'starting' }
    $baseUrl = 'http://127.0.0.1:' + $port + '/v1'
    $anthropicBaseUrl = 'http://127.0.0.1:' + $port
    $warning = Get-FastLlmConnectAgentWarning -ContextTokens $contextTokens
    # Unknown context (not running, or an older status): a fixed notice stands in for the warning.
    if ($null -eq $contextTokens) { $warning = $script:FastLlmConnectUnknownContextNotice }

    $limitLine = if ($null -ne $contextTokens) { 'Requests longer than ' + (Format-FastLlmConnectNumber -Value $contextTokens) + ' tokens are refused.' }
                 else { 'Requests longer than this setup''s context limit are refused. The limit is shown once FastLLM is running.' }
    $modelText = if ($null -ne $modelName) { $modelName } else { '<model name shown once FastLLM is running>' }
    $contextText = if ($null -ne $contextTokens) { [string] $contextTokens } else { '<context limit shown once FastLLM is running>' }
    $clients = @()
    foreach ($client in $script:FastLlmConnectClients) {
        $snippet = [string] $client.template
        # With the key on, the card that names the key setting; {KEY} stays unresolved.
        if ($apiKeyRequired) { $snippet = [string] $client.keyTemplate }
        $snippet = $snippet.Replace('{BASE}', $baseUrl).Replace('{ANTHROPIC}', $anthropicBaseUrl).Replace('{HOSTPORT}', '127.0.0.1:' + $port)
        $snippet = $snippet.Replace('{MODEL}', $modelText).Replace('{CONTEXT}', $contextText).Replace('{LIMIT}', $limitLine)
        $docUrls = @($client.docUrl)
        if ($client.ContainsKey('docUrls')) { $docUrls = @($client.docUrls) }
        $clients += [pscustomobject]@{ id = [string] $client.id; title = [string] $client.title; snippet = ($snippet.TrimEnd() -replace "`r`n", "`n"); docUrl = [string] $client.docUrl; docUrls = $docUrls }
    }
    $endpoints = @($script:FastLlmConnectEndpoints | ForEach-Object { [pscustomobject]@{ path = [string] $_.path; label = [string] $_.label } })
    $connection = [pscustomobject]@{
        state            = $(if ($running) { 'running' } else { 'not running' })
        baseUrl          = $baseUrl
        anthropicBaseUrl = $anthropicBaseUrl
        modelName        = $modelName
        contextTokens    = $contextTokens
        agentWarning     = $warning
        endpoints        = $endpoints
        clients          = $clients
        # Additive. apiKeyRequired: the cards carry the unresolved token {KEY}. apiKey: on (proved by the running server), starting (a run
        # is starting and the saved setting is on), on-at-next-start (nothing is running and the saved setting is on) or off.
        # apiKeyId: the running key's public id, or $null.
        apiKeyRequired   = [bool] $apiKeyRequired
        apiKey           = $apiKeyState
        apiKeyId         = $apiKeyId
    }
    # Additive, and present ONLY while the embedding sidecar is ready (its own start check passed): the /v1/embeddings row with the sidecar's
    # own base URL. Without it the object has exactly the fields it always had. There is no client card for embeddings.
    $embeddingsRow = Get-FastLlmConnectEmbeddings -Status $Status -ApiKeyRequired ([bool] $apiKeyRequired)
    if ($null -ne $embeddingsRow) { $connection | Add-Member -NotePropertyName embeddings -NotePropertyValue $embeddingsRow }
    return $connection
}

# A card as the window shows it: the token {KEY} becomes the placeholder. Never the key.
function Get-FastLlmConnectDisplayText {
    param([AllowNull()][string] $Snippet)
    if ($null -eq $Snippet) { return '' }
    return $Snippet.Replace($script:FastLlmConnectKeyToken, $script:FastLlmConnectKeyPlaceholder)
}

# A card as its Copy button puts it on the clipboard: the token {KEY} becomes the key. -Key is a [ref] to the text the window just read
# from the key store for this one copy (the key never crosses a function boundary as a plain value); with no key (the store could not be
# read) the placeholder is copied instead, so nothing misleading is pasted.
function Get-FastLlmConnectCopyText {
    param([AllowNull()][string] $Snippet, [ref] $Key)
    if ($null -eq $Snippet) { return '' }
    $keyText = $null
    if ($null -ne $Key) { $keyText = $Key.Value }
    if ($keyText -is [string] -and $keyText -cmatch '\Afl-[A-Za-z0-9_-]{43}\z') { return $Snippet.Replace($script:FastLlmConnectKeyToken, $keyText) }
    return (Get-FastLlmConnectDisplayText -Snippet $Snippet)
}

# What goes on the clipboard next to a text that holds the key: the three clipboard formats Windows documents for keeping a copy out of
# the clipboard history and the cloud clipboard. Each value is four bytes (a DWORD); zero means "no", and the first format only has to
# be present. The key stays on the clipboard until the user copies something else: there is no timer, so a later paste still works.
function Get-FastLlmUiKeyClipboardFormats {
    return [ordered] @{
        'ExcludeClipboardContentFromMonitorProcessing' = [byte[]] (1, 0, 0, 0)
        'CanIncludeInClipboardHistory'                 = [byte[]] (0, 0, 0, 0)
        'CanUploadToCloudClipboard'                    = [byte[]] (0, 0, 0, 0)
    }
}

# Fills one clipboard data object from a copy payload and publishes it. The window passes the two Windows calls: -NewDataObject makes a
# Windows.Forms.DataObject, -Publish hands it to the clipboard. Everything else is here, so it is tested without a window:
#   the text is set first, as UnicodeText with conversion to the other text formats;
#   then every format of the payload, under its exact name, without conversion, as a stream of its raw bytes (a byte array given to a
#   data object directly would be serialized, not written as the four bytes Windows expects);
#   then the object is published, once.
function Set-FastLlmUiClipboard {
    param([Parameter(Mandatory = $true)] $Payload, [Parameter(Mandatory = $true)][scriptblock] $NewDataObject, [Parameter(Mandatory = $true)][scriptblock] $Publish)
    $clipboardData = & $NewDataObject
    $clipboardData.SetData('UnicodeText', $true, [string] $Payload.text)
    foreach ($formatName in @($Payload.formats.Keys)) {
        $clipboardData.SetData([string] $formatName, $false, [IO.MemoryStream]::new([byte[]] $Payload.formats[$formatName]))
    }
    $null = & $Publish $clipboardData
}

# The one copy routine for both places that copy the key: the API key row (-KeyOnly: the key alone) and a client card (the card text, with
# its {KEY} token replaced). The window passes three script blocks and holds no key itself:
#   -ReadKey       returns the key text read from the store for this one copy, or $null
#   -SetClipboard  is given one payload, @{ text; formats }: the text, and the formats above when (and only when) the text holds the key
#   -SetStatus     is given a fixed text to show; it is never given the key or the copied text
# Returns $true when something was put on the clipboard.
function Invoke-FastLlmUiKeyCopy {
    param(
        [AllowNull()][string] $Snippet,
        [switch] $KeyOnly,
        [Parameter(Mandatory = $true)][scriptblock] $ReadKey,
        [Parameter(Mandatory = $true)][scriptblock] $SetClipboard,
        [Parameter(Mandatory = $true)][scriptblock] $SetStatus
    )
    $keyText = $null
    $copyText = $null
    $holdsKey = $false
    try {
        if ($KeyOnly -or ([string] $Snippet).Contains($script:FastLlmConnectKeyToken)) {
            try { $keyText = & $ReadKey } catch { $keyText = $null }
            $holdsKey = [bool] ($keyText -is [string] -and $keyText -cmatch '\Afl-[A-Za-z0-9_-]{43}\z')
        }
        if ($KeyOnly) {
            if (-not $holdsKey) { $null = & $SetStatus 'The stored API key cannot be read.'; return $false }
            $copyText = $keyText
        }
        else {
            if (-not $holdsKey) { $keyText = $null }
            if (([string] $Snippet).Contains($script:FastLlmConnectKeyToken) -and -not $holdsKey) { $null = & $SetStatus 'The stored API key cannot be read, so the card was copied without it.' }
            $copyText = Get-FastLlmConnectCopyText -Snippet $Snippet -Key ([ref] $keyText)
        }
        $formats = [ordered] @{}
        if ($holdsKey) { $formats = Get-FastLlmUiKeyClipboardFormats }
        try { $null = & $SetClipboard @{ text = $copyText; formats = $formats } }
        catch {
            if ($KeyOnly) { $null = & $SetStatus 'Could not copy the API key.' } else { $null = & $SetStatus 'Could not copy the card.' }
            return $false
        }
        return $true
    }
    finally { $keyText = $null; $copyText = $null }
}

function Test-FastLlmApiCheckReady {
    param($Status)
    $active = Get-FastLlmConnectProp $Status 'active'
    $phase = Get-FastLlmConnectProp $Status 'phase'
    if ($active -is [bool] -and $active -and $phase -is [string] -and $phase -ceq 'ready') { return $true }
    return $false
}

function Get-FastLlmApiCheckUsage {
    param($Parsed, [string] $PromptName, [string] $CompletionName)
    $usage = Get-FastLlmConnectProp $Parsed 'usage'
    $result = @{ prompt = $null; completion = $null }
    foreach ($pair in @(@('prompt', $PromptName), @('completion', $CompletionName))) {
        $value = Get-FastLlmConnectProp $usage $pair[1]
        $number = 0L
        if ($null -ne $value -and -not ($value -is [bool]) -and [long]::TryParse([string] $value, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref] $number)) { $result[$pair[0]] = $number }
    }
    return $result
}

# Sends one fixed non-streaming prompt (max_tokens 16) to each of the three API formats and records only the verdict, the HTTP status,
# the usage counts and the elapsed time. No request or response text is kept.
function Invoke-FastLlmApiCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $BaseUrl,
        [Parameter(Mandatory = $true)][string] $ModelName,
        [scriptblock] $Request
    )
    $root = $BaseUrl.TrimEnd('/')
    if ($root.EndsWith('/v1')) { $root = $root.Substring(0, $root.Length - 3) }
    if ($null -eq $Request) {
        $Request = {
            param($Root, $Path, $Body, $TimeoutMs)
            & (Get-Module FastLlm) { param($R, $P, $B, $T) Invoke-FastLlmHttp -BaseUrl $R -Path $P -Body $B -TimeoutMs $T } $Root $Path $Body $TimeoutMs
        }
    }
    $message = @(@{ role = 'user'; content = $script:FastLlmApiCheckPrompt })
    $specs = @(
        @{ path = '/v1/chat/completions'; shape = 'choices'; key = 'message'; usage = @('prompt_tokens', 'completion_tokens')
           body = @{ model = $ModelName; messages = $message; max_tokens = 16; stream = $false } }
        @{ path = '/v1/messages'; shape = 'content'; key = 'type'; usage = @('input_tokens', 'output_tokens')
           body = @{ model = $ModelName; messages = $message; max_tokens = 16; stream = $false } }
        @{ path = '/v1/responses'; shape = 'output'; key = 'type'; usage = @('input_tokens', 'output_tokens')
           body = @{ model = $ModelName; input = $script:FastLlmApiCheckPrompt; max_output_tokens = 16; stream = $false } }
    )
    $checks = @()
    foreach ($spec in $specs) {
        $httpStatus = $null; $elapsed = $null; $passed = $false; $promptTokens = $null; $completionTokens = $null
        $clock = [Diagnostics.Stopwatch]::StartNew()
        try {
            $response = & $Request $root $spec.path $spec.body 60000
            $code = Get-FastLlmConnectProp $response 'Status'
            $codeNumber = 0
            if ($null -ne $code -and [int]::TryParse([string] $code, [ref] $codeNumber)) { $httpStatus = $codeNumber }
            $reported = Get-FastLlmConnectProp $response 'ElapsedMs'
            $reportedNumber = 0.0
            if ($null -ne $reported -and [double]::TryParse([string] $reported, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref] $reportedNumber)) { $elapsed = [Math]::Round($reportedNumber, 1) }
            if ($httpStatus -eq 200) {
                $parsed = $null
                try { $parsed = ConvertFrom-Json ([string] (Get-FastLlmConnectProp $response 'Body')) } catch { $parsed = $null }
                $shapeValue = Get-FastLlmConnectProp $parsed $spec.shape
                # Structure only (presence and type, never text): a non-empty array whose first element is an object holding the format's key.
                $first = $null
                if ($shapeValue -is [System.Collections.IList] -and $shapeValue.Count -ge 1) { $first = $shapeValue[0] }
                $keyValue = $null
                if ($first -is [pscustomobject]) { $keyValue = Get-FastLlmConnectProp $first $spec.key }
                $keyOk = $false
                if ($spec.key -ceq 'message') { $keyOk = ($keyValue -is [pscustomobject]) } else { $keyOk = ($keyValue -is [string] -and $keyValue.Length -ge 1) }
                if ($keyOk) {
                    $passed = $true
                    $usage = Get-FastLlmApiCheckUsage -Parsed $parsed -PromptName $spec.usage[0] -CompletionName $spec.usage[1]
                    $promptTokens = $usage.prompt; $completionTokens = $usage.completion
                }
            }
        }
        catch { $passed = $false }
        $clock.Stop()
        if ($null -eq $elapsed) { $elapsed = [Math]::Round($clock.Elapsed.TotalMilliseconds, 1) }
        # A request the server refused for the API key (HTTP 401) is its own result: the format was not tested at all.
        $verdict = 'fail'
        if ($passed) { $verdict = 'pass' } elseif ($httpStatus -eq 401) { $verdict = 'unauthorized' }
        $checks += [pscustomobject][ordered]@{
            endpoint = [string] $spec.path; status = $verdict; httpStatus = $httpStatus
            promptTokens = $promptTokens; completionTokens = $completionTokens; elapsedMs = $elapsed
        }
    }
    return [pscustomobject]@{ checks = @($checks) }
}

# One api-check run-log event per endpoint: fixed endpoint path, verdict and numbers only.
function Write-FastLlmApiCheckRunLog {
    param([string] $InstallRoot, [string] $RunId, $Result)
    if ([string]::IsNullOrWhiteSpace($RunId) -or $RunId -cnotmatch '^[A-Za-z0-9-]{1,64}$') { return }
    foreach ($check in @($Result.checks)) {
        $fields = [ordered]@{ endpoint = [string] $check.endpoint; status = [string] $check.status }
        foreach ($name in @('httpStatus', 'promptTokens', 'completionTokens', 'elapsedMs')) {
            $value = $check.$name
            if ($null -ne $value) { $fields[$name] = $value }
        }
        try { [void] (Write-FastLlmRunLogEvent -InstallRoot $InstallRoot -RunId $RunId -Event 'api-check' -Fields $fields) } catch { $null = $_ }
    }
}

# The doctor -ApiCheck flow: refuse unless Ready, run the check, log it. Returns { exitCode, message, result }.
function Invoke-FastLlmDoctorApiCheck {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $InstallRoot, $Status, [scriptblock] $Request)
    if (-not (Test-FastLlmApiCheckReady -Status $Status)) {
        return [pscustomobject]@{ exitCode = 2; message = $script:FastLlmApiCheckNotReadyMessage; result = $null }
    }
    $info = Get-FastLlmConnectionInfo -Status $Status -InstallRoot $InstallRoot
    if ($null -eq $info.modelName) {
        return [pscustomobject]@{ exitCode = 2; message = $script:FastLlmApiCheckNotReadyMessage; result = $null }
    }
    $arguments = @{ BaseUrl = $info.baseUrl; ModelName = $info.modelName }
    $apiCheckExposure = $null
    if ($null -ne $Request) { $arguments.Request = $Request }
    elseif ($info.apiKeyRequired) {
        # The running server requires the key. Each request reads the key store inside the FastLlm module and sends the key through the
        # module's loopback client, which first confirms that the listener is the server process this status records (process id and start
        # time). The key never leaves the module. A store that cannot be read is api-key-unavailable: the check is not run without the key.
        try { Assert-FastLlmApiKeyStore -InstallRoot $InstallRoot }
        catch { return [pscustomobject]@{ exitCode = 2; message = 'api-key-unavailable: The running server requires the API key, but the stored key cannot be read, so the API check was not run. Create a new key (settings -ApiKey rotate) and restart FastLLM.'; result = $null } }
        $apiCheckInstallRoot = $InstallRoot
        $apiCheckServer = Get-FastLlmConnectProp $Status 'processIdentity'
        # The loopback client checks the listener again after each request. If it is then not the recorded server, the key may have been
        # sent to another program (api-key-listener-changed): that is kept here, no further request is sent, and the check reports it.
        $apiCheckExposure = @{ seen = $false }
        $arguments.Request = {
            param($Root, $Path, $Body, $TimeoutMs)
            if ($apiCheckExposure.seen) { throw 'The API check was stopped.' }
            try { & (Get-Module FastLlm) { param($R, $P, $B, $T, $I, $S) Invoke-FastLlmHttp -BaseUrl $R -Path $P -Body $B -TimeoutMs $T -ApiKeyHolder (Read-FastLlmApiKeyStore -InstallRoot $I) -ApiKeyServer $S } $Root $Path $Body $TimeoutMs $apiCheckInstallRoot $apiCheckServer }
            catch {
                if ([string] $_.Exception.Data['FastLlmFailureCode'] -ceq 'api-key-listener-changed') { $apiCheckExposure.seen = $true }
                throw
            }
        }
    }
    $result = Invoke-FastLlmApiCheck @arguments
    if ($null -ne $apiCheckExposure -and $apiCheckExposure.seen) {
        Write-FastLlmApiCheckRunLog -InstallRoot $InstallRoot -RunId ([string] (Get-FastLlmConnectProp $Status 'runId')) -Result $result
        return [pscustomobject]@{ exitCode = 1; message = $script:FastLlmApiCheckKeyExposedMessage; result = $result }
    }
    $unauthorized = @($result.checks | Where-Object { $_.status -ceq 'unauthorized' }).Count
    if ($unauthorized -gt 0) { $result | Add-Member -NotePropertyName note -NotePropertyValue $script:FastLlmApiCheckUnauthorizedNote -Force }
    Write-FastLlmApiCheckRunLog -InstallRoot $InstallRoot -RunId ([string] (Get-FastLlmConnectProp $Status 'runId')) -Result $result
    $failed = @($result.checks | Where-Object { $_.status -cne 'pass' }).Count
    return [pscustomobject]@{ exitCode = $(if ($failed -gt 0) { 1 } else { 0 }); message = $null; result = $result }
}

# Plain-text table for the window.
function Format-FastLlmApiCheckTable {
    param($Result)
    $lines = @('API format check (one short fixed prompt per format; nothing is kept):')
    $rows = Get-FastLlmConnectProp $Result 'checks'
    if ($null -eq $rows) { $rows = @() }
    foreach ($check in $rows) {
        $http = if ($null -ne $check.httpStatus) { 'HTTP ' + $check.httpStatus } else { 'no reply' }
        $tokens = if ($null -ne $check.promptTokens -or $null -ne $check.completionTokens) { ' | tokens in/out: ' + $check.promptTokens + '/' + $check.completionTokens } else { '' }
        $lines += ('{0,-22} {1,-5} {2}{3} | {4} ms' -f $check.endpoint, ([string] $check.status).ToUpperInvariant(), $http, $tokens, $check.elapsedMs)
    }
    $note = Get-FastLlmConnectProp $Result 'note'
    if ($note -is [string] -and $note.Length -gt 0) { $lines += $note }
    return ($lines -join [Environment]::NewLine)
}
