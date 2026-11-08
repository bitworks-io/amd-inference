# Connection info for the "Connect an app" dialog and `status`, the client setting cards, and the user-run API-format check.
# Dot-sourced ONLY by fast-llm.ps1 and fast-llm-ui.ps1, never by src/FastLlm.psm1 or the background host. Windows PowerShell 5.1-safe; ASCII only.
# HONESTY: every client card copies only settings its own documentation names (the doc URL sits beside each card) and makes no claim
# about how well a client behaves with a local model. The API check records numbers and pass/fail only, never prompt or completion text.
Set-StrictMode -Version 2

# Coding agents often send requests longer than this; below it the agent warning is shown.
$script:FastLlmConnectAgentMinContext = 32768
$script:FastLlmConnectResponsesLabel = '/v1/responses: partial at this engine version'
$script:FastLlmConnectClaudeCodeNote = "Claude Code is designed for Anthropic's Claude models; results with a local model may vary."
$script:FastLlmApiCheckNotReadyMessage = 'Start FastLLM and wait for Ready before running the API check.'
$script:FastLlmApiCheckPrompt = 'Reply with one short word.'

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
$script:FastLlmConnectClients = @(
    @{
        id = 'openai-compatible'; title = 'Any OpenAI-compatible app'
        # https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md (the server's own OpenAI-compatible endpoints)
        docUrl = 'https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md'
        template = @'
Base URL: {BASE}
Model: {MODEL}
API key: any text (FastLLM sets no key)
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
API Key: any text (FastLLM sets no key)
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
Model name FastLLM serves: {MODEL}. The Claude Code documentation describes how to select a model.
{LIMIT}
'@
    }
    @{
        id = 'codex'; title = 'Codex'
        # https://developers.openai.com/codex/config-advanced (custom model providers; wire_api = "responses" appears in its Azure example)
        docUrl = 'https://developers.openai.com/codex/config-advanced'
        template = @'
# config.toml
model = "{MODEL}"
model_provider = "fastllm"

[model_providers.fastllm]
name = "FastLLM"
base_url = "{BASE}"
env_key = "OPENAI_API_KEY"
wire_api = "responses"

Set OPENAI_API_KEY to any text (FastLLM sets no key).
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
        if ($property) { return $property.Value }
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
    }
    $baseUrl = 'http://127.0.0.1:' + $port + '/v1'
    $anthropicBaseUrl = 'http://127.0.0.1:' + $port
    $warning = Get-FastLlmConnectAgentWarning -ContextTokens $contextTokens

    $limitLine = if ($null -ne $contextTokens) { 'Requests longer than ' + (Format-FastLlmConnectNumber -Value $contextTokens) + ' tokens are refused.' }
                 else { 'Requests longer than this setup''s context limit are refused. The limit is shown once FastLLM is running.' }
    $modelText = if ($null -ne $modelName) { $modelName } else { '<model name shown once FastLLM is running>' }
    $contextText = if ($null -ne $contextTokens) { [string] $contextTokens } else { '<context limit shown once FastLLM is running>' }
    $clients = @()
    foreach ($client in $script:FastLlmConnectClients) {
        $snippet = [string] $client.template
        $snippet = $snippet.Replace('{BASE}', $baseUrl).Replace('{ANTHROPIC}', $anthropicBaseUrl).Replace('{HOSTPORT}', '127.0.0.1:' + $port)
        $snippet = $snippet.Replace('{MODEL}', $modelText).Replace('{CONTEXT}', $contextText).Replace('{LIMIT}', $limitLine)
        $docUrls = @($client.docUrl)
        if ($client.ContainsKey('docUrls')) { $docUrls = @($client.docUrls) }
        $clients += [pscustomobject]@{ id = [string] $client.id; title = [string] $client.title; snippet = ($snippet.TrimEnd() -replace "`r`n", "`n"); docUrl = [string] $client.docUrl; docUrls = $docUrls }
    }
    $endpoints = @($script:FastLlmConnectEndpoints | ForEach-Object { [pscustomobject]@{ path = [string] $_.path; label = [string] $_.label } })
    return [pscustomobject]@{
        state            = $(if ($running) { 'running' } else { 'not running' })
        baseUrl          = $baseUrl
        anthropicBaseUrl = $anthropicBaseUrl
        modelName        = $modelName
        contextTokens    = $contextTokens
        agentWarning     = $warning
        endpoints        = $endpoints
        clients          = $clients
    }
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
        @{ path = '/v1/chat/completions'; shape = 'choices'; usage = @('prompt_tokens', 'completion_tokens')
           body = @{ model = $ModelName; messages = $message; max_tokens = 16; stream = $false } }
        @{ path = '/v1/messages'; shape = 'content'; usage = @('input_tokens', 'output_tokens')
           body = @{ model = $ModelName; messages = $message; max_tokens = 16; stream = $false } }
        @{ path = '/v1/responses'; shape = 'output'; usage = @('input_tokens', 'output_tokens')
           body = @{ model = $ModelName; input = $script:FastLlmApiCheckPrompt; max_output_tokens = 16; max_tokens = 16; stream = $false } }
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
                # Structure only: an array of at least one element must be present. Its text is never read.
                if ($null -ne $shapeValue -and $shapeValue -isnot [string] -and @($shapeValue).Count -ge 1) {
                    $passed = $true
                    $usage = Get-FastLlmApiCheckUsage -Parsed $parsed -PromptName $spec.usage[0] -CompletionName $spec.usage[1]
                    $promptTokens = $usage.prompt; $completionTokens = $usage.completion
                }
            }
        }
        catch { $passed = $false }
        $clock.Stop()
        if ($null -eq $elapsed) { $elapsed = [Math]::Round($clock.Elapsed.TotalMilliseconds, 1) }
        $checks += [pscustomobject][ordered]@{
            endpoint = [string] $spec.path; status = $(if ($passed) { 'pass' } else { 'fail' }); httpStatus = $httpStatus
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
    if ($null -ne $Request) { $arguments.Request = $Request }
    $result = Invoke-FastLlmApiCheck @arguments
    Write-FastLlmApiCheckRunLog -InstallRoot $InstallRoot -RunId ([string] (Get-FastLlmConnectProp $Status 'runId')) -Result $result
    $failed = @($result.checks | Where-Object { $_.status -cne 'pass' }).Count
    return [pscustomobject]@{ exitCode = $(if ($failed -gt 0) { 1 } else { 0 }); message = $null; result = $result }
}

# Plain-text table for the window.
function Format-FastLlmApiCheckTable {
    param($Result)
    $lines = @('API format check (one short fixed prompt per format; nothing is kept):')
    foreach ($check in @(Get-FastLlmConnectProp $Result 'checks')) {
        $http = if ($null -ne $check.httpStatus) { 'HTTP ' + $check.httpStatus } else { 'no reply' }
        $tokens = if ($null -ne $check.promptTokens -or $null -ne $check.completionTokens) { ' | tokens in/out: ' + $check.promptTokens + '/' + $check.completionTokens } else { '' }
        $lines += ('{0,-22} {1,-5} {2}{3} | {4} ms' -f $check.endpoint, ([string] $check.status).ToUpperInvariant(), $http, $tokens, $check.elapsedMs)
    }
    return ($lines -join [Environment]::NewLine)
}
