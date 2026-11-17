# Loaded into FastLlm.psm1. The opt-in embedding sidecar: a SECOND supervised llama-server, with a dedicated embedding model, on its own
# loopback port, on the CPU only, under the same supervisor and the same operation lock as the text model. Off by default: without the
# option nothing in this file runs, no file is read and no field is added anywhere.
#
# What decides whether it may start (nothing is derived from a file size or a formula):
#   - an embedding-model component that is listed, installed and consented (config/components.json; every file is hashed when the sidecar starts);
#   - a measured sidecar row for exactly that model file on the built-in engine (config/serving-profiles.json, "sidecars");
#   - CPU placement. A row with any other placement is refused.
# Without these the option is refused at the start, typed, before anything is launched.
#
# Lifetime: the sidecar belongs to the serving SESSION (the caller's Start-FastLlmServer), not to one run of the text model. It starts only
# after the text model is Ready, keeps running across a supervised model switch and the switch's restore, and is stopped when the session
# ends (stop, idle stop, a failed switch that stopped, a failure of the text server). Its process host has the same kill-on-close job as
# the text server's, so both die with the supervisor.
#
# Failure isolation: whatever fails here (the port, the file check, the start, the load, the checks, a crash later, the API key on the
# sidecar) is recorded in the sidecar's own status block with a typed code and never fails, stops or changes the text model. It is never
# started a second time in a session.
#
# PRIVACY: embedding inputs are the user's documents. Nothing from a request, a document or a vector is kept: the engine's output is
# discarded after the start check, the check embeds a fixed built-in sentence and keeps only its verdict and the vector length, and the
# run-log lines hold ids, numbers, codes and closed words only.

$script:FastLlmSidecarDefaultPort = 8081
# How long the sidecar may take to load its model, counted from its start.
$script:FastLlmSidecarLoadTimeoutSeconds = 300
# The sentence the start check embeds twice. A fixed built-in constant: never a user's text.
$script:FastLlmSidecarCanaryText = 'FastLLM start check: the same sentence must give the same vector twice.'
$script:FastLlmSidecarPoolings = @('mean', 'cls', 'last')
$script:FastLlmSidecarMaxContext = 1048576
$script:FastLlmSidecarMaxDimension = 65536
$script:FastLlmSidecarIdPattern = '^[a-z0-9][a-z0-9.\-]{1,120}\z'
$script:FastLlmSidecarCodePattern = '^[a-z][a-z0-9-]{0,63}\z'
$script:FastLlmSidecarPhases = @('waiting', 'starting', 'checking', 'ready', 'failed', 'stopped')

# A refusal of the option itself, before anything is started. Typed, in plain words, and with a reason no caller retries, re-plans or
# recovers on: another model or setup cannot make embeddings available.
function New-FastLlmSidecarRefusal {
    param([Parameter(Mandatory = $true)][string] $Code, [Parameter(Mandatory = $true)][string] $Message)
    $failure = New-FastLlmTypedFailure -Code $Code -Message $Message
    $failure.Data['FastLlmReason'] = 'EmbeddingsRefused'
    return $failure
}

# A failure of the sidecar while it starts or runs: only a code travels (the text shown for it is fixed, per code).
function New-FastLlmSidecarStop {
    param([Parameter(Mandatory = $true)][string] $Code)
    $failure = New-Object -TypeName System.InvalidOperationException -ArgumentList $Code
    $failure.Data['FastLlmSidecarCode'] = $Code
    return $failure
}

function Get-FastLlmSidecarValue {
    param($Row, [Parameter(Mandatory = $true)][string] $Name)
    if ($null -eq $Row -or $Row -isnot [System.Management.Automation.PSCustomObject]) { return $null }
    $property = $Row.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

# The sidecar rows of the serving profiles file. No file is no rows (the option is then refused as not measured). A file that is not this
# schema is a typed failure: an option is never honoured from a file that cannot be read.
function Read-FastLlmSidecarRows {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $document = $null
    try { $document = Read-FastLlmJson -Path $Path -MaxBytes $script:FastLlmServingProfilesMaxBytes }
    catch { throw (New-FastLlmServingProfilesFailure -Detail 'The serving profiles file could not be read as JSON, so embeddings cannot be turned on.') }
    $schema = Get-FastLlmSidecarValue -Row $document -Name 'schema'
    $rowsProperty = $null
    if ($document -is [System.Management.Automation.PSCustomObject]) { $rowsProperty = $document.PSObject.Properties['sidecars'] }
    if (-not ($schema -is [string]) -or $schema -cne $script:FastLlmServingProfilesSchema -or $null -eq $rowsProperty -or -not ($rowsProperty.Value -is [array])) {
        throw (New-FastLlmServingProfilesFailure -Detail 'The serving profiles file has an unexpected schema, so embeddings cannot be turned on.')
    }
    return @($rowsProperty.Value | Where-Object { $null -ne $_ })
}

# The model file of an embedding-model component: its entryPoint, which must be a .gguf leaf name of its file manifest. { name, sha256 }, or
# $null for a component that names no such file (it is then not an embedding model FastLLM can use).
function Get-FastLlmSidecarModelFile {
    param([Parameter(Mandatory = $true)] $Component)
    try {
        $entryProperty = $Component.PSObject.Properties['entryPoint']
        if ($null -eq $entryProperty -or -not ($entryProperty.Value -is [string])) { return $null }
        $entry = [string] $entryProperty.Value
        if ($entry -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._+-]{0,199}\.gguf\z') { return $null }
        foreach ($manifestEntry in @((Get-FastLlmComponentManifestAsset -Component $Component).manifest)) {
            if ([string] $manifestEntry.path -ceq $entry -and ([string] $manifestEntry.sha256) -match '^[0-9a-fA-F]{64}$') {
                return [pscustomobject] [ordered] @{ name = $entry; sha256 = ([string] $manifestEntry.sha256).ToLowerInvariant() }
            }
        }
    }
    catch { $null = $_ }
    return $null
}

# The sidecar's arguments. The host is the literal loopback address: there is no parameter through which another could arrive. The API
# key is never an argument (it travels in the child's environment). --no-ui always: the sidecar never serves a chat page.
function Get-FastLlmSidecarArguments {
    param([Parameter(Mandatory = $true)][string] $ModelPath, [Parameter(Mandatory = $true)][string] $Alias, [Parameter(Mandatory = $true)][int] $Port,
        [Parameter(Mandatory = $true)][int] $ContextSize, [Parameter(Mandatory = $true)][string] $Pooling)
    return @(
        '--model', $ModelPath,
        '--offline',
        '--alias', $Alias,
        '--host', '127.0.0.1',
        '--port', [string] $Port,
        '--cors-origins', 'localhost',
        '--no-cors-credentials',
        # CPU placement: no device is given to the engine.
        '--device', 'none',
        '--embedding',
        '--pooling', $Pooling,
        '-c', [string] $ContextSize,
        '--metrics',
        '--log-verbosity', '4',
        '--no-agent',
        '--no-ui'
    )
}

# The plan of the sidecar, or a typed refusal. Cheap on purpose (it runs before the text model starts): the component list, the presence
# of the component's files (names and sizes, no hashing), its consent receipt and the measured row. The model file is hashed, and the
# engine is checked, when the sidecar starts.
function Get-FastLlmSidecarPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $CatalogPath, [Parameter(Mandatory = $true)][string] $InstallRoot, [int] $Port = 0, [string] $ComponentsPath, [string] $ProfilesPath)
    $configRoot = Split-Path -Parent $CatalogPath
    if (-not $ComponentsPath) { $ComponentsPath = Join-Path $configRoot 'components.json' }
    if (-not $ProfilesPath) { $ProfilesPath = Join-Path $configRoot 'serving-profiles.json' }
    if ($Port -eq 0) { $Port = $script:FastLlmSidecarDefaultPort }
    if ($Port -lt 1024 -or $Port -gt 65535) {
        throw (New-FastLlmSidecarRefusal -Code 'embeddings-port-invalid' -Message 'The embeddings port must be a whole number from 1024 to 65535. Nothing was started.')
    }
    $off = 'To start without embeddings, turn them off: fast-llm.ps1 settings -Embeddings off'
    $catalog = Get-FastLlmCatalog -CatalogPath $CatalogPath
    $engineVersion = [string] $catalog.engine.version
    # The built-in engine, whatever engine serves the text model.
    $engineId = 'llama.cpp-' + $engineVersion + '-vulkan'
    $installed = New-Object 'System.Collections.Generic.List[object]'
    if (Test-Path -LiteralPath $ComponentsPath -PathType Leaf) {
        foreach ($component in @(Get-FastLlmComponents -ComponentsPath $ComponentsPath)) {
            if ([string] $component.kind -cne 'embedding-model') { continue }
            if ([string] $component.id -cnotmatch $script:FastLlmSidecarIdPattern) { continue }
            $modelFile = Get-FastLlmSidecarModelFile -Component $component
            if ($null -eq $modelFile) { continue }
            if (-not (Test-FastLlmComponentInstallation -InstallRoot $InstallRoot -Component $component -Depth Presence)) { continue }
            if (-not (Test-FastLlmComponentConsentReceipt -Component $component -InstallRoot $InstallRoot)) { continue }
            $installed.Add([pscustomobject] @{ component = $component; file = $modelFile })
        }
    }
    if ($installed.Count -eq 0) {
        throw (New-FastLlmSidecarRefusal -Code 'embeddings-no-model' -Message "Embeddings are on, but no approved embedding model is installed on this PC (one that this release lists, with its license accepted). Nothing was started. $off")
    }
    $rows = @(Read-FastLlmSidecarRows -Path $ProfilesPath)
    $measured = New-Object 'System.Collections.Generic.List[object]'
    foreach ($candidate in $installed) {
        $matching = New-Object 'System.Collections.Generic.List[object]'
        foreach ($row in $rows) {
            $rowRole = Get-FastLlmSidecarValue -Row $row -Name 'role'
            $rowComponent = Get-FastLlmSidecarValue -Row $row -Name 'componentId'
            $rowSha = Get-FastLlmSidecarValue -Row $row -Name 'componentSha256'
            $rowEngine = Get-FastLlmSidecarValue -Row $row -Name 'engineId'
            $rowBackend = Get-FastLlmSidecarValue -Row $row -Name 'backend'
            if (-not ($rowRole -is [string]) -or $rowRole -cne 'embedding') { continue }
            if (-not ($rowComponent -is [string]) -or $rowComponent -cne [string] $candidate.component.id) { continue }
            if (-not ($rowSha -is [string]) -or $rowSha -cne [string] $candidate.file.sha256) { continue }
            if (-not ($rowEngine -is [string]) -or $rowEngine -cne $engineId) { continue }
            if (-not ($rowBackend -is [string]) -or $rowBackend -cne 'vulkan') { continue }
            $matching.Add($row)
        }
        if ($matching.Count -gt 1) {
            throw (New-FastLlmServingProfilesFailure -Detail "The serving profiles file has more than one embedding row for '$([string] $candidate.component.id)' on this engine, so none is used. Nothing was started.")
        }
        if ($matching.Count -eq 1) { $measured.Add([pscustomobject] @{ component = $candidate.component; file = $candidate.file; row = $matching[0] }) }
    }
    if ($measured.Count -eq 0) {
        throw (New-FastLlmSidecarRefusal -Code 'embeddings-not-measured' -Message "Embeddings are on, but the installed embedding model has not been measured for this engine ($engineId), so it is not offered. Nothing was started. $off")
    }
    if ($measured.Count -gt 1) {
        throw (New-FastLlmSidecarRefusal -Code 'embeddings-model-ambiguous' -Message "Embeddings are on, and more than one measured embedding model is installed; FastLLM runs one and does not choose between them. Remove all but one. Nothing was started. $off")
    }
    $pick = $measured[0]
    $componentId = [string] $pick.component.id
    $placement = Get-FastLlmSidecarValue -Row $pick.row -Name 'placement'
    if (-not ($placement -is [string]) -or $placement -cne 'cpu') {
        throw (New-FastLlmSidecarRefusal -Code 'embeddings-gpu-not-offered' -Message "Embeddings on the GPU are not offered: the measured setup of '$componentId' is not a CPU setup. Nothing was started. $off")
    }
    $invalid = { param([string] $What) throw (New-FastLlmServingProfilesFailure -Detail "The embedding row for '$componentId' has $What, so it is not used. Nothing was started.") }
    $isWhole = { param($Value) return [bool] ($Value -is [int] -or $Value -is [long]) }
    $contextSize = Get-FastLlmSidecarValue -Row $pick.row -Name 'contextSize'
    if (-not (& $isWhole $contextSize) -or [long] $contextSize -lt 1 -or [long] $contextSize -gt $script:FastLlmSidecarMaxContext) { & $invalid 'a context size that is not a whole number from 1 to 1048576' }
    $pooling = Get-FastLlmSidecarValue -Row $pick.row -Name 'pooling'
    if (-not ($pooling -is [string]) -or $script:FastLlmSidecarPoolings -cnotcontains $pooling) { & $invalid 'a pooling that is not mean, cls or last' }
    $dimension = Get-FastLlmSidecarValue -Row $pick.row -Name 'dimension'
    if (-not (& $isWhole $dimension) -or [long] $dimension -lt 1 -or [long] $dimension -gt $script:FastLlmSidecarMaxDimension) { & $invalid 'a dimension that is not a whole number from 1 to 65536' }
    $resultId = Get-FastLlmSidecarValue -Row (Get-FastLlmSidecarValue -Row $pick.row -Name 'evidence') -Name 'resultId'
    if (-not ($resultId -is [string]) -or $resultId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,119}\z') { & $invalid 'no evidence result id' }
    $componentRoot = Get-FastLlmComponentRoot -InstallRoot $InstallRoot -Component $pick.component
    $modelPath = Join-FastLlmContainedPath -Root $componentRoot -Child ([string] $pick.file.name) -Label 'Embedding model file'
    return [pscustomobject] [ordered] @{
        role            = 'embedding'
        componentId     = $componentId
        componentSha256 = [string] $pick.file.sha256
        component       = $pick.component
        engineId        = $engineId
        engineVersion   = $engineVersion
        backend         = 'vulkan'
        # Resolved when the sidecar starts, together with the engine's file check.
        enginePath      = $null
        placement       = 'cpu'
        contextSize     = [int] $contextSize
        pooling         = [string] $pooling
        dimension       = [int] $dimension
        evidenceResultId = [string] $resultId
        port            = [int] $Port
        endpoint        = "http://127.0.0.1:$([int] $Port)/v1"
        modelPath       = $modelPath
        catalogPath     = $CatalogPath
        serverArguments = @(Get-FastLlmSidecarArguments -ModelPath $modelPath -Alias $componentId -Port ([int] $Port) -ContextSize ([int] $contextSize) -Pooling ([string] $pooling))
    }
}

# Throws the typed refusal unless embeddings can be turned on now (an approved embedding model is installed, it is measured for the built-in
# engine, and its placement is the CPU). For the entry points, so the refusal comes before any hardware probe, plan, download or launch.
# Read-only: nothing is hashed, started or written.
function Assert-FastLlmEmbeddingsAvailable {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $CatalogPath, [Parameter(Mandatory = $true)][string] $InstallRoot, [int] $Port = 0)
    $null = Get-FastLlmSidecarPlan -CatalogPath $CatalogPath -InstallRoot $InstallRoot -Port $Port
}

# The executable and the arguments the sidecar is launched with: the built-in engine and the plan's arguments, unchanged. (A seam: the
# tests launch a mock engine with the same arguments.)
function Get-FastLlmSidecarCommand {
    param([Parameter(Mandatory = $true)] $Plan)
    return @{ fileName = [string] $Plan.enginePath; arguments = @($Plan.serverArguments) }
}

# The sidecar of one serving session: its plan, its status block, its process and what belongs to them. The block is the ONE object every
# status document of the session carries (sidecars[0]), so a document always shows the block as it is at that moment.
function New-FastLlmSidecarSession {
    param([Parameter(Mandatory = $true)] $Plan)
    $block = [ordered] @{ role = 'embedding'; componentId = [string] $Plan.componentId; endpoint = [string] $Plan.endpoint; phase = 'waiting'; processIdentity = $null; placement = 'cpu'; canary = $null }
    return @{ plan = $Plan; block = $block; process = $null; sandbox = $null; attempted = $false; clock = $null; apiKeyHolder = $null; apiKeyId = $null
        baseUrl = (([string] $Plan.endpoint) -replace '/v1$', ''); idle = @{ promptTokens = $null; predictedTokens = $null; failedLogged = $false }; changed = $false }
}

# ---- run log: ids, whole numbers, codes and closed words only ----
# The fields of one sidecar line, built from the values that have their closed shape; anything else is dropped, so no text a request,
# a document or a vector held can reach the log through these events.
function Get-FastLlmSidecarRunLogFields {
    param([Parameter(Mandatory = $true)][string] $Event, [System.Collections.IDictionary] $Values = @{})
    $fields = [ordered] @{}
    $whole = { param($Value, [long] $Low, [long] $High) return [bool] (($Value -is [int] -or $Value -is [long]) -and [long] $Value -ge $Low -and [long] $Value -le $High) }
    if ($Values['role'] -is [string] -and $Values['role'] -ceq 'embedding') { $fields.role = 'embedding' }
    switch -CaseSensitive ($Event) {
        'sidecar-start' {
            if ($Values['componentId'] -is [string] -and $Values['componentId'] -cmatch $script:FastLlmSidecarIdPattern) { $fields.componentId = [string] $Values['componentId'] }
            if (& $whole $Values['port'] 1 65535) { $fields.port = [int] $Values['port'] }
            if ($Values['placement'] -is [string] -and $Values['placement'] -ceq 'cpu') { $fields.placement = 'cpu' }
        }
        'sidecar-placement' {
            foreach ($name in @('offloadLines', 'offloadedLayers', 'totalLayers', 'gpuBufferLines', 'cpuBufferLines')) { if (& $whole $Values[$name] 0 1000000) { $fields[$name] = [int] $Values[$name] } }
        }
        'sidecar-canary' {
            if ($Values['ok'] -is [bool]) { $fields.ok = [bool] $Values['ok'] }
            if (& $whole $Values['dimension'] 0 10000000) { $fields.dimension = [int] $Values['dimension'] }
        }
        'sidecar-phase' {
            if ($Values['phase'] -is [string] -and $script:FastLlmSidecarPhases -ccontains $Values['phase']) { $fields.phase = [string] $Values['phase'] }
            if ($Values['failureCode'] -is [string] -and $Values['failureCode'] -cmatch $script:FastLlmSidecarCodePattern) { $fields.failureCode = [string] $Values['failureCode'] }
        }
        default { }
    }
    return $fields
}

function Add-FastLlmSidecarRunLogEvent {
    param([string] $InstallRoot, $State, [Parameter(Mandatory = $true)][string] $Event, [System.Collections.IDictionary] $Values = @{})
    if ($null -eq $State) { return }
    $Values['role'] = 'embedding'
    Add-FastLlmRunLogEvent -InstallRoot $InstallRoot -State $State -Event $Event -Fields { Get-FastLlmSidecarRunLogFields -Event $Event -Values $Values }
}

# The one console line of a failure: the code and a fixed sentence for it. The text model is never affected, and the line says so.
function Get-FastLlmSidecarFailureText {
    param([Parameter(Mandatory = $true)][string] $Code, $Plan)
    $port = 0
    if ($null -ne $Plan) { $port = [int] $Plan.port }
    $why = switch -CaseSensitive ($Code) {
        'embeddings-port-in-use' { "Port $port is already in use, or it is the model's own port. Choose another port: fast-llm.ps1 settings -EmbeddingPort <n>" }
        'embeddings-engine-unavailable' { 'The built-in engine failed its file check. Run the install action to repair it.' }
        'embeddings-model-invalid' { 'The embedding model failed its file check. Install it again.' }
        'embeddings-no-model' { 'The license receipt of the embedding model is missing. Install it again.' }
        'embeddings-start-failed' { 'The embeddings server could not be started.' }
        'embeddings-server-exited' { 'The embeddings server stopped unexpectedly.' }
        'embeddings-load-timeout' { 'The embedding model did not finish loading in time.' }
        'embeddings-placement-not-cpu' { 'The engine reported the embedding model on a GPU, and only the CPU is offered.' }
        'embeddings-canary-failed' { 'The embeddings server did not pass its start check.' }
        'embeddings-api-key-changed' { 'The API key was changed, and the embeddings server still had the earlier key. Start FastLLM again to use embeddings.' }
        'api-key-not-enforced' { 'The API key is on, but the embeddings server did not enforce it.' }
        'api-key-listener-not-verified' { 'The program listening on the embeddings port could not be confirmed to be the embeddings server FastLLM started, so the API key was not sent to it.' }
        'api-key-listener-changed' { 'Right after a request with the API key, the program listening on the embeddings port could no longer be confirmed to be the embeddings server. Another program may have received the key: create a new key (fast-llm.ps1 settings -ApiKey rotate), give it to your apps, then start again.' }
        default { 'The embeddings server could not be used.' }
    }
    return "Embeddings: not available ($Code). $why The model keeps running; embeddings stay off until the next start."
}

function Close-FastLlmSidecarProcess {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary] $Session)
    $process = $Session['process']
    $Session['process'] = $null
    if ($null -ne $process) { try { $process.Dispose() } catch { $null = $_ } }
    $sandbox = $Session['sandbox']
    $Session['sandbox'] = $null
    if ($null -ne $sandbox) { try { Remove-FastLlmRuntimeSandbox $sandbox } catch { $null = $_ } }
}

# Turns the block to failed with a typed code, and ends the sidecar's process. Never throws: a failure of the sidecar must not become a
# failure of the run that supervises it.
function Set-FastLlmSidecarFailed {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary] $Session, [Parameter(Mandatory = $true)][string] $Code, [string] $InstallRoot, $State)
    try {
        if ($Code -cnotmatch $script:FastLlmSidecarCodePattern) { $Code = 'embeddings-internal-error' }
        Close-FastLlmSidecarProcess -Session $Session
        $Session.block['phase'] = 'failed'
        $Session.block['failureCode'] = $Code
        $Session['changed'] = $true
        Add-FastLlmSidecarRunLogEvent -InstallRoot $InstallRoot -State $State -Event 'sidecar-phase' -Values @{ phase = 'failed'; failureCode = $Code }
        Write-Host (Get-FastLlmSidecarFailureText -Code $Code -Plan $Session['plan'])
    }
    catch { $null = $_ }
}

# The code a caught failure is recorded with: the sidecar's own typed code, a typed API key code, or the fallback.
function Get-FastLlmSidecarFailureCode {
    param($Exception, [string] $Fallback = 'embeddings-internal-error')
    if ($null -ne $Exception -and $null -ne $Exception.Data) {
        $own = $Exception.Data['FastLlmSidecarCode']
        if ($own -is [string] -and $own -cmatch $script:FastLlmSidecarCodePattern) { return $own }
        $keyCode = $Exception.Data['FastLlmFailureCode']
        if ([string] $Exception.Data['FastLlmReason'] -ceq 'ApiKeyFailed' -and $keyCode -is [string] -and $keyCode -cmatch '^api-key-[a-z-]{1,40}\z') { return $keyCode }
    }
    return $Fallback
}

# One request to the sidecar. With the API key on, every request but -WithoutKey carries the key, and so goes through the listener check
# against THE SIDECAR's process and port, before and after (Invoke-FastLlmHttp): the key is sent to nothing else.
function Invoke-FastLlmSidecarRequest {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary] $Session, [Parameter(Mandatory = $true)][string] $Path, $Body, [int] $TimeoutMs = 5000, [switch] $WithoutKey)
    $holder = $Session['apiKeyHolder']
    if ($null -ne $holder -and -not $WithoutKey) {
        return (Invoke-FastLlmHttp -BaseUrl ([string] $Session['baseUrl']) -Path $Path -Body $Body -TimeoutMs $TimeoutMs -ApiKeyHolder $holder -ApiKeyServer $Session.block['processIdentity'])
    }
    return (Invoke-FastLlmHttp -BaseUrl ([string] $Session['baseUrl']) -Path $Path -Body $Body -TimeoutMs $TimeoutMs)
}

# What the engine printed about where the model went, as numbers only. CPU placement expects no GPU line at all; what is seen is recorded.
function ConvertFrom-FastLlmSidecarPlacement {
    param([string] $Text)
    $seen = [ordered] @{ offloadLines = 0; offloadedLayers = 0; totalLayers = 0; gpuBufferLines = 0; cpuBufferLines = 0 }
    foreach ($line in @(([string] $Text) -split "`r?`n")) {
        if ($line -cmatch '^load_tensors: offloaded (\d{1,6})/(\d{1,6}) layers to GPU$') {
            $seen.offloadLines = [int] $seen.offloadLines + 1
            $seen.offloadedLayers = [int] $seen.offloadedLayers + [int] $Matches[1]
            $seen.totalLayers = [int] $Matches[2]
        }
        elseif ($line -cmatch '^load_tensors: (Vulkan\d+|ROCm\d+) model buffer size = ') { $seen.gpuBufferLines = [int] $seen.gpuBufferLines + 1 }
        elseif ($line -cmatch '^load_tensors: (CPU|CPU_Mapped) model buffer size = ') { $seen.cpuBufferLines = [int] $seen.cpuBufferLines + 1 }
    }
    return $seen
}

# The vector of an /v1/embeddings answer as numbers, or $null when the answer is not exactly one vector of finite numbers.
function ConvertFrom-FastLlmSidecarEmbedding {
    param([string] $Body)
    try {
        $document = ConvertFrom-Json -InputObject $Body -ErrorAction Stop
        $dataProperty = $document.PSObject.Properties['data']
        if ($null -eq $dataProperty -or -not ($dataProperty.Value -is [array]) -or @($dataProperty.Value).Count -ne 1) { return $null }
        $entry = @($dataProperty.Value)[0]
        $vectorProperty = $entry.PSObject.Properties['embedding']
        if ($null -eq $vectorProperty -or -not ($vectorProperty.Value -is [array])) { return $null }
        $values = @($vectorProperty.Value)
        if ($values.Count -lt 1 -or $values.Count -gt 10000000) { return $null }
        $vector = New-Object double[] $values.Count
        for ($index = 0; $index -lt $values.Count; $index++) {
            $value = $values[$index]
            if (-not ($value -is [int] -or $value -is [long] -or $value -is [double] -or $value -is [decimal] -or $value -is [single])) { return $null }
            $number = [double] $value
            if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { return $null }
            $vector[$index] = $number
        }
        return , $vector
    }
    catch { return $null }
}

# The start check. The served name must be the component, and the fixed built-in sentence, embedded twice, must give the same vector of
# the row's dimension (finite numbers, not all zero). Returns only the verdict and the vector length that was seen: the vectors and the
# answers are dropped here. A failure of the API key path is not a failed check and is passed on.
function Test-FastLlmSidecarCanary {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary] $Session)
    $result = @{ ok = $false; dimension = $null }
    $alias = [string] $Session.plan.componentId
    $expected = [int] $Session.plan.dimension
    try {
        $models = Invoke-FastLlmSidecarRequest -Session $Session -Path '/v1/models' -TimeoutMs 5000
        if ($null -eq $models -or $models.Status -ne 200) { return $result }
        $listed = @((ConvertFrom-Json -InputObject ([string] $models.Body) -ErrorAction Stop).data)
        if ($listed.Count -ne 1 -or [string] $listed[0].id -cne $alias) { return $result }
        $first = $null
        for ($attempt = 0; $attempt -lt 2; $attempt++) {
            $answer = Invoke-FastLlmSidecarRequest -Session $Session -Path '/v1/embeddings' -Body @{ model = $alias; input = $script:FastLlmSidecarCanaryText } -TimeoutMs 30000
            if ($null -eq $answer -or $answer.Status -ne 200) { return $result }
            $vector = ConvertFrom-FastLlmSidecarEmbedding -Body ([string] $answer.Body)
            if ($null -eq $vector) { return $result }
            $result.dimension = [int] $vector.Length
            if ($vector.Length -ne $expected) { return $result }
            if ($attempt -eq 0) {
                $nonZero = $false
                foreach ($number in $vector) { if ($number -ne 0.0) { $nonZero = $true; break } }
                if (-not $nonZero) { return $result }
                $first = $vector
            }
            else { for ($index = 0; $index -lt $vector.Length; $index++) { if ($vector[$index] -ne $first[$index]) { return $result } } }
        }
        $result.ok = $true
    }
    catch {
        if ([string] $_.Exception.Data['FastLlmReason'] -ceq 'ApiKeyFailed') { throw }
        $result.ok = $false
    }
    return $result
}

# waiting -> starting. Runs only after the text model is Ready. In order: the port, the built-in engine's file check, the model's full
# file check (every file hashed) and its consent receipt, then the launch, in its own process host and its own empty configuration roots,
# with the text server's environment builder (the same scrub of inherited LLAMA_*, GGML_* and the rest; the key, when on, in the
# environment only).
function Start-FastLlmSidecarProcess {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary] $Session, [Parameter(Mandatory = $true)][string] $InstallRoot, $State, [int] $TextPort = 0)
    $plan = $Session['plan']
    $Session['attempted'] = $true
    $port = [int] $plan.port
    # The port: not the model's own, and free. A clash refuses the sidecar only.
    if ($TextPort -gt 0 -and $port -eq $TextPort) { throw (New-FastLlmSidecarStop -Code 'embeddings-port-in-use') }
    try { Assert-FastLlmLoopbackPortFree -Port $port } catch { throw (New-FastLlmSidecarStop -Code 'embeddings-port-in-use') }
    # The built-in engine, verified now (a text model on an engine component never verified it).
    $enginePath = $null
    try {
        $catalog = Get-FastLlmCatalog -CatalogPath ([string] $plan.catalogPath)
        $asset = $catalog.engine.assets.PSObject.Properties['vulkan'].Value
        if ([string] $catalog.engine.version -ceq [string] $plan.engineVersion -and [bool] $asset.enabled -and
            (Test-FastLlmEngineInstallation -InstallRoot $InstallRoot -EngineVersion ([string] $plan.engineVersion) -BackendKey 'vulkan' -Asset $asset)) {
            $enginePath = Get-FastLlmEngineExecutable -InstallRoot $InstallRoot -EngineVersion ([string] $plan.engineVersion) -BackendKey 'vulkan' -EntryPoint ([string] $asset.entryPoint)
        }
    }
    catch { $enginePath = $null }
    if (-not $enginePath) { throw (New-FastLlmSidecarStop -Code 'embeddings-engine-unavailable') }
    $plan.enginePath = [string] $enginePath
    # The model: every file of the component, by size and SHA-256, and its consent receipt.
    $verified = $false
    try { $verified = [bool] (Test-FastLlmComponentVerifiedFull -InstallRoot $InstallRoot -Component $plan.component) } catch { $verified = $false }
    if (-not $verified -or -not (Test-Path -LiteralPath ([string] $plan.modelPath) -PathType Leaf)) { throw (New-FastLlmSidecarStop -Code 'embeddings-model-invalid') }
    if (-not (Test-FastLlmComponentConsentReceipt -Component $plan.component -InstallRoot $InstallRoot)) { throw (New-FastLlmSidecarStop -Code 'embeddings-no-model') }
    Initialize-FastLlmProcessHost
    $command = Get-FastLlmSidecarCommand -Plan $plan
    try {
        $sandbox = New-FastLlmRuntimeSandbox -InstallRoot $InstallRoot
        $Session['sandbox'] = $sandbox
        $process = New-Object Bitworks.FastLlm.ProcessHost
        $Session['process'] = $process
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = [string] $command.fileName
        $info.Arguments = Join-FastLlmProcessArguments -Arguments @($command.arguments)
        $info.WorkingDirectory = Split-Path -Parent ([string] $command.fileName)
        # The built-in engine's environment: never the text plan's (a HIP text plan has its own runtime paths; the sidecar has none).
        $environmentPlan = [pscustomobject] @{ backend = 'vulkan'; enginePath = [string] $command.fileName }
        $holder = $Session['apiKeyHolder']
        if ($null -ne $holder) {
            Initialize-FastLlmEngineStartInfo -StartInfo $info -Plan $environmentPlan -Sandbox $sandbox -ApiKeyHolder $holder
            # Besides every line with an api_key label, the process host drops any output line that holds the key itself.
            $process.DropLinesContaining((Get-FastLlmApiKeyText -ApiKeyHolder $holder))
        }
        else { Initialize-FastLlmEngineStartInfo -StartInfo $info -Plan $environmentPlan -Sandbox $sandbox }
        $process.Start($info)
    }
    catch { throw (New-FastLlmSidecarStop -Code 'embeddings-start-failed') }
    # Only the actual supervised child, as for the text server; the key is only ever sent to this process.
    $Session.block['processIdentity'] = [ordered] @{ pid = [int] $process.Process.Id; startUtcTicks = [long] $process.Process.StartTime.ToUniversalTime().Ticks }
    $Session['clock'] = [Diagnostics.Stopwatch]::StartNew()
    $Session.block['phase'] = 'starting'
    Add-FastLlmSidecarRunLogEvent -InstallRoot $InstallRoot -State $State -Event 'sidecar-start' -Values @{ componentId = [string] $plan.componentId; port = $port; placement = 'cpu' }
    Write-Host "Embeddings: starting '$([string] $plan.componentId)' on the CPU at $([string] $plan.endpoint)."
}

# starting -> checking: the model is loaded when /health says ok. An exit is the port (the engine's own bind error) or a failed start.
function Wait-FastLlmSidecarHealth {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary] $Session)
    $process = $Session['process']
    $port = [int] $Session.plan.port
    if ($null -eq $process -or $process.Process.HasExited) {
        if ($null -ne $process) {
            # The engine's last lines arrive just after the exit. They are startup output only (nothing was asked of this server yet).
            $outputWait = [Diagnostics.Stopwatch]::StartNew()
            while (-not $process.OutputCompleted -and $outputWait.ElapsedMilliseconds -lt 1000) { Start-Sleep -Milliseconds 50 }
            if (Test-FastLlmServerBindFailure -Text ([string] $process.Snapshot()) -Port $port) { throw (New-FastLlmSidecarStop -Code 'embeddings-port-in-use') }
        }
        throw (New-FastLlmSidecarStop -Code 'embeddings-server-exited')
    }
    $healthy = $false
    try { $health = Invoke-FastLlmSidecarRequest -Session $Session -Path '/health' -TimeoutMs 250 -WithoutKey; $healthy = [bool] ($health.Status -eq 200 -and (ConvertFrom-Json -InputObject ([string] $health.Body)).status -eq 'ok') } catch { $healthy = $false }
    if ($healthy) { $Session.block['phase'] = 'checking'; return }
    # Health first, the deadline second: a sidecar that was left loading while the text model was switched may have been ready for a while.
    if ($Session['clock'].Elapsed.TotalSeconds -ge [double] $script:FastLlmSidecarLoadTimeoutSeconds) { throw (New-FastLlmSidecarStop -Code 'embeddings-load-timeout') }
}

# checking -> ready. The gates, in order: CPU placement (what the engine printed, taken before any request), the sidecar's OWN 401/200
# proof when the API key is on, then the start check. Only then may the block say ready. The engine's output is discarded from here on.
function Complete-FastLlmSidecarChecks {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary] $Session, [Parameter(Mandatory = $true)][string] $InstallRoot, $State)
    $process = $Session['process']
    if ($null -eq $process -or $process.Process.HasExited) { throw (New-FastLlmSidecarStop -Code 'embeddings-server-exited') }
    $seen = ConvertFrom-FastLlmSidecarPlacement -Text ([string] $process.PlacementSnapshot())
    Add-FastLlmSidecarRunLogEvent -InstallRoot $InstallRoot -State $State -Event 'sidecar-placement' -Values $seen
    if ([bool] $process.PlacementOverflow -or [int] $seen.gpuBufferLines -gt 0 -or [int] $seen.offloadedLayers -gt 0) { throw (New-FastLlmSidecarStop -Code 'embeddings-placement-not-cpu') }
    if ($null -ne $Session['apiKeyHolder']) {
        # One request without the key must be refused (401) and one with it must be answered (200); no answer counts as 0.
        $proofWithout = 0
        $proofWith = 0
        try { $proofWithout = [int] (Invoke-FastLlmSidecarRequest -Session $Session -Path '/v1/models' -TimeoutMs 5000 -WithoutKey).Status } catch { $proofWithout = 0 }
        try { $proofWith = [int] (Invoke-FastLlmSidecarRequest -Session $Session -Path '/v1/models' -TimeoutMs 5000).Status }
        catch {
            if ([string] $_.Exception.Data['FastLlmReason'] -ceq 'ApiKeyFailed') { throw }
            $proofWith = 0
        }
        if ((Get-FastLlmApiKeyEnforcement -WithoutKeyStatus $proofWithout -WithKeyStatus $proofWith) -cne 'enforced') { throw (New-FastLlmSidecarStop -Code 'api-key-not-enforced') }
    }
    $canary = Test-FastLlmSidecarCanary -Session $Session
    $dimension = $null
    if ($canary.dimension -is [int]) { $dimension = [int] $canary.dimension }
    $Session.block['canary'] = [ordered] @{ ok = [bool] $canary.ok; dimension = $dimension }
    Add-FastLlmSidecarRunLogEvent -InstallRoot $InstallRoot -State $State -Event 'sidecar-canary' -Values @{ ok = [bool] $canary.ok; dimension = $dimension }
    if (-not [bool] $canary.ok) { throw (New-FastLlmSidecarStop -Code 'embeddings-canary-failed') }
    if ($process.Process.HasExited) { throw (New-FastLlmSidecarStop -Code 'embeddings-server-exited') }
    # From here on apps send their documents: nothing the engine prints is kept.
    $process.DiscardOutput()
    $Session.block['phase'] = 'ready'
    Add-FastLlmSidecarRunLogEvent -InstallRoot $InstallRoot -State $State -Event 'sidecar-phase' -Values @{ phase = 'ready' }
    Write-Host "Embeddings: ready at $([string] $Session.plan.endpoint) (model '$([string] $Session.plan.componentId)', $([int] $canary.dimension) dimensions, on the CPU)."
}

# One step of the sidecar, called from the supervisor's post-Ready loop on every pass (so a stop or a switch is never kept waiting by a
# model that is loading). Returns $true when the block changed, so the caller writes the status document. Never throws.
function Step-FastLlmSidecar {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary] $Session, [Parameter(Mandatory = $true)][string] $InstallRoot, $State, [int] $TextPort = 0)
    $before = [string] $Session.block['phase']
    try {
        if ($before -ceq 'waiting') { Start-FastLlmSidecarProcess -Session $Session -InstallRoot $InstallRoot -State $State -TextPort $TextPort }
        elseif ($before -ceq 'starting') { Wait-FastLlmSidecarHealth -Session $Session }
        elseif ($before -ceq 'checking') { Complete-FastLlmSidecarChecks -Session $Session -InstallRoot $InstallRoot -State $State }
        elseif ($before -ceq 'ready') {
            # A sidecar that ends later: its block turns failed. It is not started again.
            $process = $Session['process']
            if ($null -eq $process -or $process.Process.HasExited) { throw (New-FastLlmSidecarStop -Code 'embeddings-server-exited') }
        }
    }
    catch { Set-FastLlmSidecarFailed -Session $Session -Code (Get-FastLlmSidecarFailureCode -Exception $_.Exception) -InstallRoot $InstallRoot -State $State }
    $changed = [bool] ([string] $Session.block['phase'] -cne $before -or [bool] $Session['changed'])
    $Session['changed'] = $false
    return $changed
}

# The idle stop counts BOTH servers. $Step is the idle detector's step for the text server; with a sidecar that is ready, its /metrics is
# read too (the same four counters). Activity there (a request processing or deferred, or a counter that moved) resets the idle clock and
# withholds the stop. A read that fails or cannot be parsed counts as busy: the sidecar is never taken for idle on a read that proves nothing.
function Join-FastLlmSidecarIdle {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary] $Session, [Parameter(Mandatory = $true)] $Step, [Parameter(Mandatory = $true)][datetime] $Now, [string] $InstallRoot, $State)
    try {
        if ([string] $Session.block['phase'] -cne 'ready') { return $Step }
        $text = $null
        try {
            $response = Invoke-FastLlmSidecarRequest -Session $Session -Path '/metrics' -TimeoutMs 250
            if ($null -ne $response -and $response.Status -eq 200) { $text = [string] $response.Body }
        }
        catch {
            # A failure of the key path on the sidecar fails the sidecar (and only it); any other failed read is just a failed read.
            if ([string] $_.Exception.Data['FastLlmReason'] -ceq 'ApiKeyFailed') {
                Set-FastLlmSidecarFailed -Session $Session -Code (Get-FastLlmSidecarFailureCode -Exception $_.Exception) -InstallRoot $InstallRoot -State $State
                return $Step
            }
            $text = $null
        }
        $idle = $Session['idle']
        $metrics = ConvertFrom-FastLlmIdleMetrics -Text $text
        $busy = $false
        if ($null -eq $metrics) {
            $busy = $true
            # Logged once for each run of failed reads in a row.
            if (-not [bool] $idle['failedLogged']) { $idle['failedLogged'] = $true; Add-FastLlmSidecarRunLogEvent -InstallRoot $InstallRoot -State $State -Event 'sidecar-idle-check-failed' }
        }
        else {
            $idle['failedLogged'] = $false
            if ($metrics.processing -gt 0 -or $metrics.deferred -gt 0) { $busy = $true }
            # The first read only sets what later reads are compared with: no idle time is credited before that.
            if ($null -eq $idle['promptTokens']) { $busy = $true }
            elseif ($metrics.promptTokens -ne [double] $idle['promptTokens'] -or $metrics.predictedTokens -ne [double] $idle['predictedTokens']) { $busy = $true }
            $idle['promptTokens'] = [double] $metrics.promptTokens
            $idle['predictedTokens'] = [double] $metrics.predictedTokens
        }
        if (-not $busy) { return $Step }
        $detector = $Step.state
        $reset = [pscustomobject] @{ lastPollUtc = $detector.lastPollUtc; lastActivityUtc = $Now; idleSeconds = 0.0; promptTokens = $detector.promptTokens; predictedTokens = $detector.predictedTokens; failedReads = $detector.failedReads }
        return [pscustomobject] @{ state = $reset; shouldStop = $false; readFailed = [bool] $Step.readFailed; activity = $true }
    }
    catch {
        # Whatever went wrong here, the answer is the safe one: nothing is stopped on this poll.
        return [pscustomobject] @{ state = $Step.state; shouldStop = $false; readFailed = [bool] $Step.readFailed; activity = [bool] $Step.activity }
    }
}

# Called by every supervised run of the session before its first status write; returns the block for the run's document.
#   The first run (nothing was started yet): the block waits for this run's Ready, and the sidecar will get THIS run's key.
#   A later run (after a model switch): the sidecar keeps running. Two things end it here: it is no longer running, or the run's API key is
#   not the key the sidecar was started with (the key was changed in between) - it would refuse the key the apps are now given.
function Enter-FastLlmSidecarRun {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary] $Session, [string] $InstallRoot, $State, $ApiKeyHolder)
    try {
        $runKeyId = $null
        if ($null -ne $ApiKeyHolder) { $runKeyId = [string] (Get-FastLlmApiKeyId -ApiKeyHolder $ApiKeyHolder) }
        if (-not [bool] $Session['attempted']) {
            $Session.block['phase'] = 'waiting'
            $Session['apiKeyHolder'] = $ApiKeyHolder
            $Session['apiKeyId'] = $runKeyId
        }
        elseif (@('starting', 'checking', 'ready') -ccontains [string] $Session.block['phase']) {
            $process = $Session['process']
            if ($null -eq $process -or $process.Process.HasExited) { Set-FastLlmSidecarFailed -Session $Session -Code 'embeddings-server-exited' -InstallRoot $InstallRoot -State $State }
            elseif ([string] $runKeyId -cne [string] $Session['apiKeyId']) { Set-FastLlmSidecarFailed -Session $Session -Code 'embeddings-api-key-changed' -InstallRoot $InstallRoot -State $State }
        }
        $Session['changed'] = $false
    }
    catch { Set-FastLlmSidecarFailed -Session $Session -Code 'embeddings-internal-error' -InstallRoot $InstallRoot -State $State }
    return $Session['block']
}

# Stops the sidecar: its process is ended and a block that was alive says stopped (a failed block keeps its failure). Never throws.
function Stop-FastLlmSidecar {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary] $Session, [string] $InstallRoot, $State)
    try {
        $phase = [string] $Session.block['phase']
        Close-FastLlmSidecarProcess -Session $Session
        if (@('waiting', 'starting', 'checking', 'ready') -ccontains $phase) {
            $Session.block['phase'] = 'stopped'
            if ($phase -cne 'waiting') { Add-FastLlmSidecarRunLogEvent -InstallRoot $InstallRoot -State $State -Event 'sidecar-phase' -Values @{ phase = 'stopped' } }
        }
    }
    catch { $null = $_ }
}

# Called by every supervised run on its way out, before its final status write. -Keep: the session goes on with another run of the text
# model (a model switch was accepted, or a switch target failed and the previous model is restored), so the sidecar keeps running.
# Otherwise the run ends the session's serving (stop, idle stop, a failure after Ready, a restore that failed): both processes stop.
function Exit-FastLlmSidecarRun {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary] $Session, [string] $InstallRoot, $State, [switch] $Keep)
    if ($Keep) { return }
    Stop-FastLlmSidecar -Session $Session -InstallRoot $InstallRoot -State $State
}

# The end of the session (the caller's Start-FastLlmServer, in its finally): whatever is still running is stopped, and the CURRENT status
# document's block is brought up to date when no run was alive to write it (a switch that was cancelled or failed between two runs).
# Best-effort; the caller holds the operation lock.
function Stop-FastLlmSidecarSession {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary] $Session, [Parameter(Mandatory = $true)][string] $InstallRoot)
    try {
        Stop-FastLlmSidecar -Session $Session -InstallRoot $InstallRoot -State $null
        $document = Get-FastLlmStatus -InstallRoot $InstallRoot
        if (-not [bool] $document.active -or -not $document.PSObject.Properties['runId'] -or -not $document.PSObject.Properties['sidecars']) { return }
        $recorded = @($document.sidecars)
        if ($recorded.Count -eq 1 -and $null -ne $recorded[0] -and [string] $recorded[0].phase -ceq [string] $Session.block['phase']) { return }
        $document.PSObject.Properties.Remove('active')
        $document.sidecars = @($Session['block'])
        $document | Add-Member -NotePropertyName updatedAt -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
        Write-FastLlmState -InstallRoot $InstallRoot -State $document
    }
    catch { $null = $_ }
}
