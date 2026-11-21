#requires -Version 5.1
# The window's background start and the sign-in start apply the saved context profile, requests at once and embeddings exactly as `start` does,
# and refuse (typed, visibly) when that setup cannot run; they never fall back to the default setup.
# Everything runs against stand-ins: no engine, GPU, network or process is started, and nothing is launched by Start-FastLlmBackgroundHost
# (the request writer is replaced by a recorder that stops there). Windows-only checks and the private-state ACL gate are replaced.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force -ErrorAction Stop
. (Join-Path $root 'src/FastLlm.ServingProfileRun.ps1')
. (Join-Path $root 'src/FastLlm.ServingSettings.ps1')
. (Join-Path $root 'src/FastLlm.BackgroundHost.ps1')
. (Join-Path $root 'src/FastLlm.SignInStart.ps1')
. (Join-Path $root 'src/FastLlm.UiFlow.ps1')
. (Join-Path $root 'src/FastLlm.UiBackground.ps1')
$script:count = 0
function Check($Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; $script:count++; Write-Host "PASS: $Message" }
function Write-Utf8([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false))) }
$source = $root
$configRoot = Join-Path $root 'config'
$catalogPath = Join-Path $configRoot 'catalog.json'
$work = Join-Path ([IO.Path]::GetTempPath()) ('background-saved-serving-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
function New-Root([string]$SettingsJson) {
    $path = Join-Path $work ([Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path | Out-Null
    if ($SettingsJson) { Write-Utf8 (Join-Path $path 'settings.json') $SettingsJson }
    return $path
}

# ---- stand-ins (script scope, so they win over the module's commands for the code under test) ----
$script:mockOrder = New-Object 'System.Collections.Generic.List[string]'
$script:mockStateWrites = New-Object 'System.Collections.Generic.List[object]'
$script:captureMode = $false
$script:embeddingsStub = $false
$script:startRequests = New-Object 'System.Collections.Generic.List[object]'
$script:planMode = 'mock'
$script:planBound = @{}
$script:serverBound = @{}
$script:serverStarts = 0
$script:fixtureCard = [pscustomobject]@{ schemaVersion = 1; source = 'bg-test'; backend = 'Vulkan'; enginePath = 'C:\FastLLM\vulkan\llama-server.exe'
    adapters = @([pscustomobject]@{ device = 'Vulkan0'; name = 'Test card'; vendorId = '1002'; vramMiB = 24576; freeVramMiB = 23552; isAmd = $true; isIntegrated = $false; backend = 'Vulkan'; driverVersion = 'bg-test' }) }
$realWrite = (Get-Command Write-FastLlmBackgroundDocument).ScriptBlock
function Assert-FastLlmBackgroundNativeHost { }
function Assert-FastLlmBackgroundPrivateState { param($InstallRoot, $RequestId) }
function Get-FastLlmBackgroundHostStatus { param($InstallRoot, $SourceRoot) return [pscustomobject]@{ occupied = $false } }
function Import-Module { param($Name, [switch]$Force) }
function Get-FastLlmHardware { param($CatalogPath, $InstallRoot) $script:mockOrder.Add('hardware'); return [pscustomobject]@{ kind = 'mock' } }
function Write-FastLlmState { param($InstallRoot, $State, $FileName) $script:mockOrder.Add('status:' + [string]$State.phase); $script:mockStateWrites.Add($State) }
function Get-FastLlmStatus { param($InstallRoot) $last = $script:mockStateWrites[$script:mockStateWrites.Count - 1]; $copy = [pscustomobject]@{}; foreach ($key in $last.Keys) { $copy | Add-Member -NotePropertyName $key -NotePropertyValue $last[$key] }; return $copy }
function Enter-FastLlmOperation { param($InstallRoot) $script:mockOrder.Add('lock'); return (New-Object IO.MemoryStream) }
function Write-FastLlmBackgroundDocument {
    param($Path, $Value, [switch]$CreateNew)
    if ($script:captureMode) { $script:mockOrder.Add('write-request'); $script:startRequests.Add($Value); throw 'background-start-probe: the request was written; this test launches nothing' }
    & $realWrite @PSBoundParameters
}
function Assert-FastLlmEmbeddingsAvailable {
    param([string]$CatalogPath, [string]$InstallRoot, [int]$Port = 0)
    $script:mockOrder.Add('embeddings-check:' + $Port)
    if ($script:embeddingsStub) { return }
    & (Get-Module FastLlm) { param($c, $i, $p) Assert-FastLlmEmbeddingsAvailable -CatalogPath $c -InstallRoot $i -Port $p } $CatalogPath $InstallRoot $Port
}
function Get-FastLlmPlan {
    param($Hardware, $CatalogPath, $Profile, $InstallRoot, $ModelId, $ContextSize, $AllowExperimentalModel, [switch]$ResolveFallback, $RecipesPath, $GpuVariantsPath,
          [int]$ServerPort = 0, [string]$Thinking = 'auto', [string]$ChatPage = 'off', [string]$KvContextProfile, [int]$KvSlots, [string]$KvProfilesPath)
    $script:planBound = @{}
    foreach ($name in @('KvContextProfile', 'KvSlots', 'KvProfilesPath')) { if ($PSBoundParameters.ContainsKey($name)) { $script:planBound[$name] = $PSBoundParameters[$name] } }
    if ($script:planMode -ceq 'real') {
        # The real planner, asked the way the host asked the mock (same serving options), on a fixture card: the shipped profile file has no row.
        $splat = @{ Hardware = $script:fixtureCard; CatalogPath = $CatalogPath; Profile = $Profile; InstallRoot = $InstallRoot; NoEngineExecution = $true }
        foreach ($name in @($script:planBound.Keys)) { $splat[$name] = $script:planBound[$name] }
        return (& (Get-Module FastLlm) { param($s) Get-FastLlmPlan @s } $splat)
    }
    return [pscustomobject]@{ model = [pscustomobject]@{ id = 'test-model' } }
}
function Start-FastLlmServer {
    param($Plan, $CatalogPath, $InstallRoot, $LoadTimeoutSeconds, [string]$VulkanBarMitigation, [switch]$SelfTest, $IdleStopMinutes, [switch]$AllowSwitch, $SwitchObserver, $ApiKey, [string]$Embeddings, [int]$EmbeddingPort)
    $script:serverBound = @{}
    foreach ($name in @('Embeddings', 'EmbeddingPort')) { if ($PSBoundParameters.ContainsKey($name)) { $script:serverBound[$name] = $PSBoundParameters[$name] } }
    $script:serverStarts++
    return 0
}

# ---- the saved states every comparison runs over ----
$savedStates = [ordered]@{
    'default'            = '{}'
    'long'               = '{"contextProfile":"long"}'
    'slots-2'            = '{"slots":2}'
    'long-and-2'         = '{"contextProfile":"long","slots":2}'
    'embeddings-on-8091' = '{"embeddings":"on","embeddingPort":8091}'
}
function Invoke-StartProbe([string]$InstallRoot, [hashtable]$Arguments) {
    $script:mockOrder.Clear(); $script:startRequests.Clear(); $script:captureMode = $true
    $failure = $null
    try { Start-FastLlmBackgroundHost -SourceRoot $source -InstallRoot $InstallRoot -NoWait @Arguments | Out-Null } catch { $failure = $_ }
    finally { $script:captureMode = $false }
    return [pscustomobject]@{ failure = $failure; requests = @($script:startRequests.ToArray()); order = @($script:mockOrder.ToArray()) }
}
function Get-FailureCode($Failure) { if ($null -eq $Failure) { return $null }; return [string]$Failure.Exception.Data['FastLlmFailureCode'] }

try {
    # ================= 1. the planner refusal is typed (its message is unchanged) =================
    $installForPlanner = New-Root ''
    $refusal = $null
    try {
        & (Get-Module FastLlm) { param($c, $cat, $i, $p) Get-FastLlmPlan -Hardware $c -CatalogPath $cat -Profile balanced -NoEngineExecution -InstallRoot $i -KvContextProfile 'long' -KvProfilesPath $p } $script:fixtureCard $catalogPath $installForPlanner (Join-Path $configRoot 'serving-profiles.json') | Out-Null
    } catch { $refusal = $_ }
    Check ($null -ne $refusal -and [string]$refusal.Exception.Message -ceq 'Not measured for this model and engine.') 'planner refusal: with no measured row the message is exactly the plain reason (unchanged)'
    Check ((Get-FailureCode $refusal) -ceq 'serving-profile-not-measured') 'planner refusal: the refusal carries the typed code serving-profile-not-measured'

    # ================= 2. the shared option builders: one place for what start adds to the planner and the server =================
    $defaultOptions = [pscustomobject]@{ contextProfile = 'default'; slots = 1; embeddings = 'off'; embeddingPort = 8081 }
    Check ((Get-FastLlmServingPlanOptions -Options $defaultOptions -ConfigRoot $configRoot).Count -eq 0 -and (Get-FastLlmServingServerOptions -Options $defaultOptions).Count -eq 0) 'option builders: all defaults add nothing (the default plan call and start call are unchanged)'
    $longOptions = [pscustomobject]@{ contextProfile = 'long'; slots = 1; embeddings = 'off'; embeddingPort = 8081 }
    $longPlanOptions = Get-FastLlmServingPlanOptions -Options $longOptions -ConfigRoot $configRoot
    Check ((@($longPlanOptions.Keys | Sort-Object) -join ',') -ceq 'KvContextProfile,KvProfilesPath' -and $longPlanOptions.KvContextProfile -ceq 'long' -and $longPlanOptions.KvProfilesPath -ceq (Join-Path $configRoot 'serving-profiles.json')) 'option builders: long adds the profile and the profiles file (config\serving-profiles.json), and not the slots'
    $twoOptions = [pscustomobject]@{ contextProfile = 'default'; slots = 2; embeddings = 'off'; embeddingPort = 8081 }
    Check ((@((Get-FastLlmServingPlanOptions -Options $twoOptions -ConfigRoot $configRoot).Keys | Sort-Object) -join ',') -ceq 'KvProfilesPath,KvSlots') 'option builders: 2 slots adds the slots and the profiles file, and not the profile'
    $embeddingOptions = [pscustomobject]@{ contextProfile = 'default'; slots = 1; embeddings = 'on'; embeddingPort = 8091 }
    $embeddingServer = Get-FastLlmServingServerOptions -Options $embeddingOptions
    Check ((@($embeddingServer.Keys | Sort-Object) -join ',') -ceq 'EmbeddingPort,Embeddings' -and $embeddingServer.Embeddings -ceq 'on' -and $embeddingServer.EmbeddingPort -eq 8091 -and (Get-FastLlmServingPlanOptions -Options $embeddingOptions -ConfigRoot $configRoot).Count -eq 0) 'option builders: embeddings on adds the flag and the port to the server only, never to the planner'

    # ================= 3. the source pins =================
    $defaultPins = Get-FastLlmBackgroundSourcePins -SourceRoot $source
    $profilePins = Get-FastLlmBackgroundSourcePins -SourceRoot $source -IncludeServingProfiles
    Check (@($defaultPins.Keys) -cnotcontains 'config/serving-profiles.json' -and @($profilePins.Keys) -ccontains 'config/serving-profiles.json' -and $profilePins.Count -eq $defaultPins.Count + 1) 'pins: the profiles file is pinned only for a request that uses it (a default request keeps the pin set it always had)'
    $defaultPinsAsRead = $defaultPins | ConvertTo-Json | ConvertFrom-Json
    $profilePinsAsRead = $profilePins | ConvertTo-Json | ConvertFrom-Json
    Assert-FastLlmBackgroundPins -SourceRoot $source -Expected $defaultPinsAsRead
    Assert-FastLlmBackgroundPins -SourceRoot $source -Expected $profilePinsAsRead
    $pinRefusal = $null
    try { Assert-FastLlmBackgroundPins -SourceRoot $source -Expected $defaultPinsAsRead -RequireServingProfiles } catch { $pinRefusal = $_ }
    Check ($null -ne $pinRefusal -and [string]$pinRefusal.Exception.Message -ceq 'Background source pin set changed during handoff.') 'pins: a request that uses the profiles file but does not pin it is refused'

    # ================= 4. Start-FastLlmBackgroundHost: parameters, the request, the embeddings check =================
    foreach ($bad in @(@{ KvContextProfile = 'banana' }, @{ KvContextProfile = 'LONG' }, @{ KvSlots = 3 }, @{ KvSlots = 0 }, @{ Embeddings = 'maybe' }, @{ EmbeddingPort = 80 }, @{ EmbeddingPort = 70000 })) {
        $name = @($bad.Keys)[0]
        $probe = Invoke-StartProbe (New-Root '') $bad
        Check ($null -ne $probe.failure -and $probe.requests.Count -eq 0 -and [string]$probe.failure.Exception.Message -cnotlike 'background-start-probe*') "start parameters: -$name $($bad[$name]) is refused before anything is written"
    }
    $mainFields = 'schemaVersion,kind,requestId,sourceRoot,installRoot,profile,modelId,contextSize,allowExperimentalModel,loadTimeoutSeconds,vulkanBarMitigation,serverPort,thinking,chatPage,idleStopMinutes,sourcePins'
    $script:embeddingsStub = $true
    $defaultProbe = Invoke-StartProbe (New-Root '') @{}
    Check ($defaultProbe.requests.Count -eq 1 -and (@($defaultProbe.requests[0].Keys) -join ',') -ceq $mainFields) 'default request: exactly the fields (and order) the document has on main, with none of the four new ones'
    $dr = $defaultProbe.requests[0]
    Check ($dr.profile -ceq 'balanced' -and [string]$dr.modelId -ceq '' -and $dr.contextSize -eq 0 -and $dr.allowExperimentalModel -eq $false -and $dr.loadTimeoutSeconds -eq 300 -and $dr.vulkanBarMitigation -ceq 'auto' -and $dr.serverPort -eq 0 -and $dr.thinking -ceq 'auto' -and $dr.chatPage -ceq 'off' -and $dr.idleStopMinutes -eq 0 -and (@($dr.sourcePins.Keys) -join ',') -ceq (@($defaultPins.Keys) -join ',')) 'default request: every value is the one main writes, and the pin set is the default one'
    $explicitDefault = Invoke-StartProbe (New-Root '') @{ KvContextProfile = 'default'; KvSlots = 1; Embeddings = 'off' }
    Check ($explicitDefault.requests.Count -eq 1 -and (@($explicitDefault.requests[0].Keys) -join ',') -ceq $mainFields) 'default request: the defaults spelled out give the same document'
    $longProbe = Invoke-StartProbe (New-Root '') @{ KvContextProfile = 'long' }
    $lr = $longProbe.requests[0]
    Check ($longProbe.requests.Count -eq 1 -and (@($lr.Keys) -join ',') -ceq ($mainFields + ',contextProfile') -and $lr.contextProfile -ceq 'long') 'long request: only contextProfile is added (no slots, no embeddings)'
    Check (@($lr.sourcePins.Keys) -ccontains 'config/serving-profiles.json') 'long request: the profiles file is pinned'
    $twoProbe = Invoke-StartProbe (New-Root '') @{ KvSlots = 2 }
    Check ($twoProbe.requests.Count -eq 1 -and (@($twoProbe.requests[0].Keys) -join ',') -ceq ($mainFields + ',slots') -and $twoProbe.requests[0].slots -eq 2 -and $twoProbe.requests[0].slots -is [int]) 'slots request: only slots (a whole number) is added'
    $embeddingProbe = Invoke-StartProbe (New-Root '') @{ Embeddings = 'on'; EmbeddingPort = 8091 }
    $er = $embeddingProbe.requests[0]
    Check ($embeddingProbe.requests.Count -eq 1 -and (@($er.Keys) -join ',') -ceq ($mainFields + ',embeddings,embeddingPort') -and $er.embeddings -ceq 'on' -and $er.embeddingPort -eq 8091 -and -not (@($er.sourcePins.Keys) -ccontains 'config/serving-profiles.json')) 'embeddings request: embeddings and the port are added, and the profiles file is not pinned'
    Check ((@($embeddingProbe.order) -join ',') -ceq 'embeddings-check:8091,lock,write-request') 'embeddings request: the availability check runs once, with the port, before the lock and before the request is written'
    $script:embeddingsStub = $false
    $noModelRoot = New-Root ''
    $noModel = Invoke-StartProbe $noModelRoot @{ Embeddings = 'on' }
    Check ((Get-FailureCode $noModel.failure) -ceq 'embeddings-no-model' -and $noModel.requests.Count -eq 0 -and $noModel.order -cnotcontains 'write-request' -and $noModel.order -cnotcontains 'lock') 'no embedding model: the start is refused typed (embeddings-no-model) before the lock and before any request is written, so no host process is started'
    Check (@(Get-ChildItem -LiteralPath $noModelRoot -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'background-request-*' }).Count -eq 0) 'no embedding model: no request file exists'
    $startText = [IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.BackgroundHost.ps1'))
    Check ($startText.IndexOf('Assert-FastLlmEmbeddingsAvailable') -gt $startText.IndexOf('Assert-FastLlmApiKeyStore -InstallRoot $install') -and $startText.IndexOf('Assert-FastLlmEmbeddingsAvailable') -lt $startText.IndexOf('Get-FastLlmBackgroundHostStatus -InstallRoot $install -SourceRoot $source')) 'no embedding model: the check sits with the API key store check, before the occupancy check and the lock'

    # ================= 5. the whole path: saved settings -> host arguments -> request -> host -> planner and server =================
    $workerRoot = New-Root ''
    function New-HostRequestFile([System.Collections.IDictionary]$Fields, $Pins) {
        $id = [Guid]::NewGuid().ToString('N')
        $document = [ordered]@{ schemaVersion = 1; kind = 'fastllm-private-background-request'; requestId = $id; sourceRoot = $source; installRoot = [IO.Path]::GetFullPath($workerRoot)
            profile = 'balanced'; modelId = ''; contextSize = 0; allowExperimentalModel = $false; loadTimeoutSeconds = 30; vulkanBarMitigation = 'auto'; serverPort = 0; thinking = 'auto'; chatPage = 'off'; idleStopMinutes = 0 }
        foreach ($key in @($Fields.Keys)) { $document[$key] = $Fields[$key] }
        if ($null -eq $Pins) {
            if ($document.Contains('contextProfile') -or $document.Contains('slots')) { $Pins = Get-FastLlmBackgroundSourcePins -SourceRoot $source -IncludeServingProfiles } else { $Pins = Get-FastLlmBackgroundSourcePins -SourceRoot $source }
        }
        $document['sourcePins'] = $Pins
        & $realWrite -Path (Get-FastLlmBackgroundPath -InstallRoot $workerRoot -Leaf ('background-request-' + $id + '.json')) -Value $document -CreateNew
        return $id
    }
    function Invoke-Host([string]$Id) {
        $script:mockOrder.Clear(); $script:mockStateWrites.Clear(); $script:planBound = @{}; $script:serverBound = @{}; $script:serverStarts = 0
        $failure = $null; $exit = $null
        try { $exit = Invoke-FastLlmBackgroundServe -RequestId $Id -InstallRoot $workerRoot -SourceRoot $source } catch { $failure = $_ }
        $record = $null
        $recordPath = Get-FastLlmBackgroundPath -InstallRoot $workerRoot -Leaf 'background-host.json' -NoCreate
        if (Test-Path -LiteralPath $recordPath) { $record = Read-FastLlmBackgroundDocument -Path $recordPath }
        return [pscustomobject]@{ exit = $exit; failure = $failure; record = $record; order = @($script:mockOrder.ToArray()); plan = $script:planBound; server = $script:serverBound; starts = $script:serverStarts }
    }
    $script:embeddingsStub = $true
    foreach ($name in $savedStates.Keys) {
        $installRoot = New-Root $savedStates[$name]
        $resolved = Resolve-FastLlmServingOptions -InstallRoot $installRoot -Bound @{}
        $expectedPlan = Get-FastLlmServingPlanOptions -Options $resolved -ConfigRoot $configRoot
        $expectedServer = Get-FastLlmServingServerOptions -Options $resolved
        $hostArguments = Get-FastLlmServingHostArguments -InstallRoot $installRoot
        $probe = Invoke-StartProbe $installRoot $hostArguments
        Check ($probe.requests.Count -eq 1) "parity [$name]: the background start writes a request from the saved settings"
        $request = $probe.requests[0]
        $document = $request | ConvertTo-Json -Depth 6 | ConvertFrom-Json
        # The host reads the request from its own install root; the saved state decides what the request holds.
        $fields = [ordered]@{}
        foreach ($field in @('contextProfile', 'slots', 'embeddings', 'embeddingPort')) { if ($request.Contains($field)) { $fields[$field] = $request[$field] } }
        $id = New-HostRequestFile $fields $null
        $run = Invoke-Host $id
        Check ($null -eq $run.failure -and $run.exit -eq 0 -and $run.starts -eq 1) "parity [$name]: the host runs the request to the server start"
        Check ((@($run.plan.Keys | Sort-Object) -join ',') -ceq (@($expectedPlan.Keys | Sort-Object) -join ',')) "parity [$name]: the host's planner options are exactly the ones start gives the planner for the same settings (keys)"
        $planEqual = $true
        foreach ($key in @($expectedPlan.Keys)) { if ([string]$run.plan[$key] -cne [string]$expectedPlan[$key]) { $planEqual = $false } }
        Check $planEqual "parity [$name]: the host's planner option values equal start's (profile, slots, profiles file)"
        Check ((@($run.server.Keys | Sort-Object) -join ',') -ceq (@($expectedServer.Keys | Sort-Object) -join ',') -and (@($expectedServer.Keys | Where-Object { [string]$run.server[$_] -cne [string]$expectedServer[$_] }).Count -eq 0)) "parity [$name]: the host's server options are exactly the ones start gives the server (embeddings and port)"
    }
    $script:embeddingsStub = $false
    # Spot checks that do not use the builders, so the parity above cannot agree with itself by both being wrong.
    $spot = New-Root '{"contextProfile":"long","slots":2,"embeddings":"on","embeddingPort":8091}'
    $spotArguments = Get-FastLlmServingHostArguments -InstallRoot $spot
    Check ($spotArguments.KvContextProfile -ceq 'long' -and $spotArguments.KvSlots -eq 2 -and $spotArguments.Embeddings -ceq 'on' -and $spotArguments.EmbeddingPort -eq 8091) 'saved long + 2 slots + embeddings 8091: the host arguments carry all four values'
    $spotRun = Invoke-Host (New-HostRequestFile ([ordered]@{ contextProfile = 'long'; slots = 2; embeddings = 'on'; embeddingPort = 8091 }) $null)
    Check ($spotRun.plan.KvContextProfile -ceq 'long' -and $spotRun.plan.KvSlots -eq 2 -and $spotRun.plan.KvProfilesPath -ceq (Join-Path $configRoot 'serving-profiles.json') -and $spotRun.server.Embeddings -ceq 'on' -and $spotRun.server.EmbeddingPort -eq 8091) 'long + 2 slots + embeddings 8091: the host plans with the profile, the slots and the profiles file and starts the server with the sidecar'
    $plainRun = Invoke-Host (New-HostRequestFile ([ordered]@{}) $null)
    Check ($plainRun.plan.Count -eq 0 -and $plainRun.server.Count -eq 0 -and $plainRun.starts -eq 1) 'default request: the host adds no option to the planner or the server'

    # ================= 6. the host reads the four fields strictly =================
    $cases = @(
        @{ Field = 'contextProfile'; Value = 'LONG' }, @{ Field = 'contextProfile'; Value = 'short' }, @{ Field = 'contextProfile'; Value = 5 }, @{ Field = 'contextProfile'; Value = $true }, @{ Field = 'contextProfile'; Value = $null }, @{ Field = 'contextProfile'; Value = '' },
        @{ Field = 'slots'; Value = 3 }, @{ Field = 'slots'; Value = 0 }, @{ Field = 'slots'; Value = '2' }, @{ Field = 'slots'; Value = 2.5 }, @{ Field = 'slots'; Value = $true }, @{ Field = 'slots'; Value = $null },
        @{ Field = 'embeddings'; Value = 'ON' }, @{ Field = 'embeddings'; Value = 'yes' }, @{ Field = 'embeddings'; Value = $true }, @{ Field = 'embeddings'; Value = 1 }, @{ Field = 'embeddings'; Value = $null },
        @{ Field = 'embeddingPort'; Value = 80 }, @{ Field = 'embeddingPort'; Value = 70000 }, @{ Field = 'embeddingPort'; Value = '8091' }, @{ Field = 'embeddingPort'; Value = $true }, @{ Field = 'embeddingPort'; Value = 8091.5 }, @{ Field = 'embeddingPort'; Value = $null },
        @{ Field = 'embeddingPort'; Value = 8091; Alone = $true }, @{ Field = 'embeddingPort'; Value = 8091; Alone = $true; Off = $true }
    )
    foreach ($case in $cases) {
        $fields = [ordered]@{}
        if ($case.Field -ceq 'embeddingPort' -and -not $case.ContainsKey('Alone')) { $fields.embeddings = 'on' }
        if ($case.ContainsKey('Off')) { $fields.embeddings = 'off' }
        $fields[$case.Field] = $case.Value
        $run = Invoke-Host (New-HostRequestFile $fields $null)
        $shown = if ($null -eq $case.Value) { 'null' } else { [string]$case.Value + ' (' + $case.Value.GetType().Name + ')' }
        Check ($null -ne $run.failure -and [string]$run.failure.Exception.Message -ceq ('Background request ' + $case.Field + ' is invalid.') -and $run.starts -eq 0 -and $run.order -cnotcontains 'lock' -and $run.order -cnotcontains 'hardware') "strict: $($case.Field) = $shown is refused before the lock and the plan, and nothing is started"
    }
    $run = Invoke-Host (New-HostRequestFile ([ordered]@{ embeddings = 'on' }) $null)
    Check ($null -ne $run.failure -and [string]$run.failure.Exception.Message -ceq 'Background request embeddingPort is invalid.' -and $run.starts -eq 0 -and $run.order -cnotcontains 'lock') 'strict: embeddings on with no embeddingPort is refused before the lock (never port 0)'
    foreach ($ok in @(@{ contextProfile = 'default' }, @{ contextProfile = 'long' }, @{ slots = 1 }, @{ slots = 2 }, @{ embeddings = 'off' })) {
        $run = Invoke-Host (New-HostRequestFile ([ordered]@{} + $ok) $null)
        Check ($null -eq $run.failure -and $run.starts -eq 1) "strict: the exact value $((@($ok.Keys)[0]))=$($ok[@($ok.Keys)[0]]) is accepted"
    }
    $run = Invoke-Host (New-HostRequestFile ([ordered]@{ slots = 3 }) $null)
    Check ($null -ne $run.failure -and $run.starts -eq 0 -and $run.plan.Count -eq 0) 'strict: an invalid slots value never falls back to one slot (nothing is planned or started)'
    $run = Invoke-Host (New-HostRequestFile ([ordered]@{ contextProfile = 'long' }) (Get-FastLlmBackgroundSourcePins -SourceRoot $source))
    Check ($null -ne $run.failure -and [string]$run.failure.Exception.Message -ceq 'Background source pin set changed during handoff.' -and $run.starts -eq 0 -and $run.order -cnotcontains 'lock' -and $run.order -cnotcontains 'hardware' -and $run.plan.Count -eq 0) 'pins: a request for a profile whose pins do not name the profiles file is refused by the host before the lock, the module import and the plan'
    $hostSource = [IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.BackgroundHost.ps1'))
    $serveStart = $hostSource.IndexOf('function Invoke-FastLlmBackgroundServe')
    $serveText = $hostSource.Substring($serveStart)
    Check ($serveText.IndexOf('Get-FastLlmBackgroundRequestServing -Request $request') -gt 0 -and $serveText.IndexOf('Get-FastLlmBackgroundRequestServing -Request $request') -lt $serveText.IndexOf('Enter-FastLlmOperation') -and $serveText.IndexOf('Get-FastLlmBackgroundRequestServing -Request $request') -lt $serveText.IndexOf('Import-Module')) 'strict: the four fields are read before the module import, the lock and the plan'

    # ================= 7. no measured row: the host ends failed with the planner's own typed code =================
    $script:planMode = 'real'
    $script:embeddingsStub = $true
    $fail = Invoke-Host (New-HostRequestFile ([ordered]@{ contextProfile = 'long' }) $null)
    $script:planMode = 'mock'
    $lastStatus = $script:mockStateWrites[$script:mockStateWrites.Count - 1]
    Check ($null -ne $fail.failure -and $fail.starts -eq 0) 'no measured row: a background start with long serves nothing (the server is never started)'
    Check ($null -ne $fail.record -and [string]$fail.record.phase -ceq 'failed' -and [string]$fail.record.failureCode -ceq 'serving-profile-not-measured' -and [string]$fail.record.failureReason -ceq 'Not measured for this model and engine.') 'no measured row: the host record is phase failed with the planner''s typed code and its plain reason'
    Check ([string]$lastStatus.phase -ceq 'failed' -and [string]$lastStatus.failureCode -ceq 'serving-profile-not-measured' -and (@($script:mockStateWrites | ForEach-Object { [string]$_.phase }) -join ',') -ceq 'preparing,failed') 'no measured row: status.json goes from preparing to failed with the same code'
    $script:embeddingsStub = $false


    # ================= 8. a switch plans the target with the same profile and slots =================
    # The supervisor builds a switch target's planner options from the plan that served (Get-FastLlmSwitchServingOptions), for a start made by the
    # command line and for a background start alike; here the plan that served has the profile, and the target is asked the same question.
    $switchRoot = New-Root ''
    $testProfiles = Join-Path $root 'tests/fixtures/serving-profiles-test.json'
    $realPlanner = { param($s) Get-FastLlmPlan @s }
    $servedPlan = & (Get-Module FastLlm) $realPlanner @{ Hardware = $script:fixtureCard; CatalogPath = $catalogPath; Profile = 'balanced'; NoEngineExecution = $true; InstallRoot = $switchRoot; KvContextProfile = 'long'; KvProfilesPath = $testProfiles }
    Check ([string]$servedPlan.servingProfile.id -ceq 'long') 'switch: the plan that served carries the long profile'
    $servingOf = { param($p) Get-FastLlmSwitchServingOptions -PreviousPlan $p }
    $switchServing = & (Get-Module FastLlm) $servingOf $servedPlan
    Check ($switchServing.KvContextProfile -ceq 'long' -and -not $switchServing.ContainsKey('KvSlots')) 'switch: the serving options of the plan that served are the profile (no slots)'
    $targetOf = { param($p, $c, $i) Get-FastLlmSwitchPlanOptions -PreviousPlan $p -Request ([pscustomobject]@{ recipeId = $null; modelId = 'qwen3.5-9b-q8-0' }) -CatalogPath $c -InstallRoot $i }
    $targetOptions = & (Get-Module FastLlm) $targetOf $servedPlan $catalogPath $switchRoot
    $backgroundOptions = Get-FastLlmServingPlanOptions -Options $longOptions -ConfigRoot $configRoot
    Check ($targetOptions.KvContextProfile -ceq $backgroundOptions.KvContextProfile -and $targetOptions.KvProfilesPath -ceq $backgroundOptions.KvProfilesPath -and $targetOptions.ModelId -ceq 'qwen3.5-9b-q8-0') 'switch: the target is planned with the profile and the profiles file a background start plans with (one set of options)'
    $targetOptions.Hardware = $script:fixtureCard; $targetOptions.NoEngineExecution = $true
    $targetRefusal = $null
    try { & (Get-Module FastLlm) $realPlanner $targetOptions | Out-Null } catch { $targetRefusal = $_ }
    Check ($null -ne $targetRefusal -and [string]$targetRefusal.Exception.Message -ceq 'Not measured for this model and engine.' -and (Get-FailureCode $targetRefusal) -ceq 'serving-profile-not-measured') 'switch: a target with no measured row is refused typed (serving-profile-not-measured), never planned with the default setup'
    $defaultServed = & (Get-Module FastLlm) $realPlanner @{ Hardware = $script:fixtureCard; CatalogPath = $catalogPath; Profile = 'balanced'; NoEngineExecution = $true; InstallRoot = $switchRoot }
    $defaultSwitchOptions = & (Get-Module FastLlm) $servingOf $defaultServed
    Check (-not $defaultSwitchOptions.ContainsKey('KvContextProfile') -and -not $defaultSwitchOptions.ContainsKey('KvSlots')) 'switch: a default run switches with no profile option (as before)'

    # ================= 9. the window: the request and the call to the host =================
    $mainRequestNames = 'sourceRoot,installRoot,profile,modelId,contextSize,vulkanBarMitigation,serverPort,thinking,chatPage,idleStopMinutes,apiKey'
    $expectedRequestExtra = @{ 'default' = ''; 'long' = ',contextProfile'; 'slots-2' = ',slots'; 'long-and-2' = ',contextProfile,slots'; 'embeddings-on-8091' = ',embeddings,embeddingPort' }
    $uiText = [IO.File]::ReadAllText((Join-Path $root 'fast-llm-ui.ps1'))
    $startBlockMatch = [regex]::Match($uiText, '(?s)-Start \{\s*param\(\$Request\)(.*?)\r?\n    \}\r?\n    \$backgroundLabel')
    Check $startBlockMatch.Success 'window: the Start block of the background start is found in fast-llm-ui.ps1'
    function Capture-BgStart {
        [CmdletBinding()]
        param([string]$SourceRoot, [string]$InstallRoot, [string]$Profile, [string]$ModelId, [int]$ContextSize, [string]$VulkanBarMitigation, [int]$ServerPort, [string]$Thinking, [string]$ChatPage, [int]$IdleStopMinutes,
              [ValidateSet('off', 'on')][string]$UseApiKey = 'off', [switch]$SwitchAllowed, [string]$KvContextProfile, [int]$KvSlots, [string]$Embeddings, [int]$EmbeddingPort, [switch]$NoWait)
        $script:bgCaptured = @{}
        foreach ($key in $PSBoundParameters.Keys) { $script:bgCaptured[$key] = $PSBoundParameters[$key] }
    }
    foreach ($name in $savedStates.Keys) {
        $installRoot = New-Root $savedStates[$name]
        $hostArguments = Get-FastLlmServingHostArguments -InstallRoot $installRoot
        $request = New-FastLlmUiBackgroundRequest -SourceRoot $root -InstallRoot $installRoot -ModelId 'm' -ContextSize 1 -BarMitigation 'on' -Settings (Get-FastLlmServingSettings -InstallRoot $installRoot) -ServingArguments $hostArguments
        Check ((@($request.PSObject.Properties.Name) -join ',') -ceq ($mainRequestNames + $expectedRequestExtra[$name])) "window request [$name]: exactly the fields main has, plus only the non-default ones ($($expectedRequestExtra[$name].TrimStart(',')))"
        $windowArguments = Get-FastLlmUiBackgroundServingArguments -Request $request
        $expectedKeys = @($hostArguments.Keys | Where-Object { @('KvContextProfile', 'KvSlots', 'Embeddings', 'EmbeddingPort') -ccontains $_ } | Sort-Object)
        Check ((@($windowArguments.Keys | Sort-Object) -join ',') -ceq ($expectedKeys -join ',') -and (@($expectedKeys | Where-Object { [string]$windowArguments[$_] -cne [string]$hostArguments[$_] }).Count -eq 0)) "window arguments [$name]: the four values handed to the host are the ones the saved settings resolve to"
        $body = $startBlockMatch.Groups[1].Value.Replace('& (Get-Module FastLlm) {', '& {').Replace('. $Source', '').Replace('Start-FastLlmBackgroundHost', 'Capture-BgStart').Replace('$PSScriptRoot', '.')
        $script:bgCaptured = $null
        & ([scriptblock]::Create('param($Request)' + $body)) $request
        $capturedServing = @($script:bgCaptured.Keys | Where-Object { @('KvContextProfile', 'KvSlots', 'Embeddings', 'EmbeddingPort') -ccontains $_ } | Sort-Object)
        Check (($capturedServing -join ',') -ceq ($expectedKeys -join ',') -and (@($expectedKeys | Where-Object { [string]$script:bgCaptured[$_] -cne [string]$hostArguments[$_] }).Count -eq 0) -and $script:bgCaptured.NoWait -eq $true) "window start [$name]: the one Start-FastLlmBackgroundHost call receives the saved profile, slots and embeddings (and nothing when they are default)"
    }
    $withSwitch = New-FastLlmUiBackgroundRequest -SourceRoot $root -InstallRoot $root -ModelId 'm' -ContextSize 1 -BarMitigation 'on' -Settings ([pscustomobject]@{ serverPort = 8080 }) -ServingArguments @{ KvContextProfile = 'long' } -AllowSwitch $true
    Check ((@($withSwitch.PSObject.Properties.Name) -join ',') -ceq ($mainRequestNames + ',contextProfile,allowSwitch')) 'window request: the switch field stays last'
    $startFunction = [regex]::Match($uiText, '(?s)function StartUiBackground \{.*?\r?\n\}\r?\n').Value
    Check ($startFunction.Contains('Get-FastLlmServingHostArguments -InstallRoot $script:installPath') -and $startFunction.Contains('-ServingArguments $servingArguments') -and $startFunction.Contains('apiKeyUndetermined')) 'window: the background start takes the four values from Get-FastLlmServingHostArguments (the one resolution), and an unreadable key flag keeps its own refusal'

    # ================= 10. the refusals are visible =================
    $embeddingsLine = 'FastLLM did not start at sign-in (2026-11-21T08:00:00Z): embeddings are on, but no embedding model is installed. Install an approved embedding model, or turn embeddings off (Settings, or fast-llm.ps1 settings -Embeddings off).'
    $otherEmbeddingsLine = 'FastLLM did not start at sign-in (2026-11-21T08:00:00Z): embeddings are on, but they cannot start (embeddings-not-measured). Turn embeddings off (Settings, or fast-llm.ps1 settings -Embeddings off), or fix the embedding setup.'
    $profileLine = 'The last start did not run: the context profile or requests-at-once setting it used has no measured setup for this model and engine. Set the context profile to default and requests at once to 1 (Settings, or fast-llm.ps1 settings -KvContextProfile default -KvSlots 1), or wait for a measured setup.'
    $resultNoModel = [pscustomobject]@{ time = '2026-11-21T08:00:00Z'; result = 'host-failed'; failureCode = 'embeddings-no-model' }
    Check ((Get-FastLlmSignInResultText -Result $resultNoModel) -ceq $embeddingsLine) 'visible: the Settings line for a sign-in refused for the embeddings (no model) says it did not start, why, and the two fixes'
    Check ((Get-FastLlmSignInResultText -Result ([pscustomobject]@{ time = '2026-11-21T08:00:00Z'; result = 'host-failed'; failureCode = 'embeddings-not-measured' })) -ceq $otherEmbeddingsLine) 'visible: another embeddings refusal has its own fixed line, with its code'
    Check ((Get-FastLlmSignInResultText -Result ([pscustomobject]@{ time = '2026-11-21T08:00:00Z'; result = 'host-failed'; failureCode = 'host-start-failed' })) -ceq 'Start at sign-in failed: host-start-failed (2026-11-21T08:00:00Z).') 'visible: every other host failure keeps its line'
    $onRoot = New-Root '{"embeddings":"on"}'
    $offRoot = New-Root ''
    foreach ($r in @($onRoot, $offRoot)) { New-Item -ItemType Directory -Path (Join-Path $r 'state') -Force | Out-Null; Write-Utf8 (Join-Path $r 'state/signin-start.json') '{"time":"2026-11-21T08:00:00Z","result":"host-failed","failureCode":"embeddings-no-model"}' }
    Check ((Get-FastLlmSignInAttentionText -InstallRoot $onRoot) -ceq $embeddingsLine) 'visible: the line the window shows when it opens (and status prints) is that exact text while embeddings are still on'
    Check ($null -eq (Get-FastLlmSignInAttentionText -InstallRoot $offRoot)) 'visible: once embeddings are turned off the line is no longer shown'
    $startedRoot = New-Root '{"embeddings":"on"}'
    New-Item -ItemType Directory -Path (Join-Path $startedRoot 'state') -Force | Out-Null
    Write-Utf8 (Join-Path $startedRoot 'state/signin-start.json') '{"time":"2026-11-21T08:00:00Z","result":"started","failureCode":null}'
    Check ($null -eq (Get-FastLlmSignInAttentionText -InstallRoot $startedRoot) -and $null -eq (Get-FastLlmSignInAttentionText -InstallRoot (New-Root '{"embeddings":"on"}'))) 'visible: a started sign-in, or none recorded, shows no line'
    Check ((Get-FastLlmSavedServingFailureText -Code 'serving-profile-not-measured') -ceq $profileLine -and $null -eq (Get-FastLlmSavedServingFailureText -Code 'background-start-or-runtime-failed')) 'visible: the not-measured code has one fixed line naming the setting and the fix; other codes have none'
    $profileState = New-FastLlmUiBackgroundState
    $profileState.observation = [pscustomobject]@{ phase = 'stale'; active = $false; attachable = $false; occupied = $false; requestId = 'a' * 32; failureCode = 'serving-profile-not-measured'; failureReason = 'Not measured for this model and engine.' }
    Check ((Get-FastLlmUiBackgroundText -State $profileState) -ceq $profileLine) 'visible: the window shows the profile line when the last background run failed for a missing measured setup'
    $otherState = New-FastLlmUiBackgroundState
    $otherState.observation = [pscustomobject]@{ phase = 'stale'; active = $false; attachable = $false; occupied = $false; requestId = 'a' * 32; failureCode = 'hip-device-not-found'; failureReason = 'x' }
    Check ((Get-FastLlmUiBackgroundText -State $otherState) -ceq 'No active background host. Review the previous host status before starting again.') 'visible: any other host failure still shows the text it showed before'
    $cliText = [IO.File]::ReadAllText((Join-Path $root 'fast-llm.ps1'))
    $statusBlock = $cliText.Substring($cliText.IndexOf("        'status' {"))
    $statusBlock = $statusBlock.Substring(0, $statusBlock.IndexOf("        'update-check' {"))
    Check ($statusBlock.Contains('Get-FastLlmSignInAttentionText -InstallRoot $InstallRoot') -and $statusBlock.Contains('Get-FastLlmSavedServingFailureText')) 'visible: status prints the sign-in line and the profile line (source)'
    Check ($uiText.Contains('Get-FastLlmSignInAttentionText -InstallRoot (Get-FastLlmSignInDefaultInstallRoot)') -and $uiText.LastIndexOf('Get-FastLlmSignInAttentionText') -gt $uiText.LastIndexOf('RefreshUiSwitchState') -and $uiText.LastIndexOf('Get-FastLlmSignInAttentionText') -lt $uiText.LastIndexOf('StartUiBackgroundPoll')) 'visible: the window reads the sign-in line when it opens (source)'
    # The real status command, in its own process. fast-llm.ps1 refuses every live operation under an elevated Windows token (the CI runner is
    # elevated), so there the real run is asserted to REFUSE and the two lines are checked through the functions the status block calls.
    $shell = (Get-Process -Id $PID).Path
    $statusChildrenElevated = $false
    if ($env:OS -ceq 'Windows_NT') { $statusChildrenElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    function Invoke-StatusChild([string]$InstallRoot) {
        # Output and errors are captured through the process object, so an error line of the child can never end this suite (Windows PowerShell 5.1).
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $shell
        $info.Arguments = '-NoLogo -NoProfile -NonInteractive -File "' + (Join-Path $root 'fast-llm.ps1') + '" status -InstallRoot "' + $InstallRoot + '"'
        $info.UseShellExecute = $false; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true; $info.CreateNoWindow = $true
        $child = [Diagnostics.Process]::Start($info)
        try {
            $stdout = $child.StandardOutput.ReadToEnd(); $stderr = $child.StandardError.ReadToEnd(); $child.WaitForExit()
            return [pscustomobject]@{ exit = $child.ExitCode; lines = @($stdout -split "\r?\n"); errorText = $stderr }
        } finally { $child.Dispose() }
    }
    $statusProfileRoot = New-Root '{"embeddings":"on"}'
    New-Item -ItemType Directory -Path (Join-Path $statusProfileRoot 'state') -Force | Out-Null
    Write-Utf8 (Join-Path $statusProfileRoot 'state/signin-start.json') '{"time":"2026-11-21T08:00:00Z","result":"host-failed","failureCode":"embeddings-no-model"}'
    $statusFailedRoot = New-Root ''
    New-Item -ItemType Directory -Path (Join-Path $statusFailedRoot 'state') -Force | Out-Null
    Write-Utf8 (Join-Path $statusFailedRoot 'state/status.json') ('{"schemaVersion":1,"runId":"' + ('b' * 32) + '","phase":"failed","action":"start","failureCode":"serving-profile-not-measured"}')
    if (-not $statusChildrenElevated) {
        Write-Host 'INFO: status child cases: real process (standard user)'
        $statusOut = @((Invoke-StatusChild $statusProfileRoot).lines)
        Check ($statusOut -ccontains $embeddingsLine) 'visible: fast-llm.ps1 status prints the exact sign-in line'
        $statusFailedOut = @((Invoke-StatusChild $statusFailedRoot).lines)
        Check ($statusFailedOut -ccontains $profileLine) 'visible: fast-llm.ps1 status prints the exact profile line for a run that failed for a missing measured setup'
    } else {
        Write-Host 'INFO: status child cases: elevated runner: refusal asserted, lines checked in-process'
        $refused = Invoke-StatusChild $statusProfileRoot
        Check ($refused.exit -ne 0 -and (($refused.errorText + ($refused.lines -join "`n")) -clike '*must run as a standard user*') -and @($refused.lines | Where-Object { $_ -ceq $embeddingsLine }).Count -eq 0) 'visible: under an elevated token the real fast-llm.ps1 status refuses (the standard-user guard is unchanged) and the suite carries on'
        $statusOut = @(Get-FastLlmSignInAttentionText -InstallRoot $statusProfileRoot)
        Check ($statusOut -ccontains $embeddingsLine) 'visible: the sign-in line the status block prints (Get-FastLlmSignInAttentionText on the prepared root) is the exact text'
        $preparedStatus = Get-Content -LiteralPath (Join-Path $statusFailedRoot 'state/status.json') -Raw | ConvertFrom-Json
        $statusFailedOut = @(Get-FastLlmSavedServingFailureText -Code ([string]$preparedStatus.failureCode))
        Check ($statusFailedOut -ccontains $profileLine) 'visible: the profile line the status block prints (Get-FastLlmSavedServingFailureText on the prepared status document) is the exact text'
    }
    Check ($profileLine -cnotmatch 'background|saved' -and (Get-FastLlmUiBackgroundText -State $profileState) -ceq @($statusFailedOut | Where-Object { $_ -clike 'The last start did not run*' })[0]) 'visible: a failed command-line start (status.json only, no background host record) gets the same neutral line the window shows, which claims neither a background run nor a saved setting'
    Check (@($statusOut | Where-Object { $_ -clike 'FastLLM did not start at sign-in*' }).Count -eq 1 -and @($statusFailedOut | Where-Object { $_ -clike 'FastLLM did not start at sign-in*' }).Count -eq 0) 'visible: the sign-in line appears once, and only when the last sign-in was refused'
}
finally {
    $leftover = @()
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
Check (-not (Test-Path -LiteralPath $work)) 'background-saved-serving-tests: the temp folder it created is removed'
Write-Host "background-saved-serving-tests: $script:count checks passed"
