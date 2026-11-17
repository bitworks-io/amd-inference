# Test world for tests/sidecar-tests.ps1, shared by the suite and by its supervisor worker process (which runs a whole start so the suite can
# end it from outside). On top of the model-switch world (a synthetic model list): a config folder that holds the FIXTURE embedding component
# list and FIXTURE sidecar rows, the fixture component installed and consented under the install root, a control folder for the mock
# embedding engine, and the replaced boundaries of the module (planner, inventory, engine check, the text model's hash), each of which
# records that it was called. The embedding component's own files are hashed for real. Nothing here runs outside the tests.
. (Join-Path $PSScriptRoot 'SwitchTestWorld.ps1')

function Get-SidecarFixtureBytes {
    $text = 'FastLLM test embedding model fixture. Not a model. ' * 4
    return , ([Text.Encoding]::ASCII.GetBytes($text.Substring(0, 192)))
}

function Get-SidecarFreePort { $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop(); return $p }

# -Rows: good (one row for the fixture component on the test engine), none, gpu (placement gpu), other-engine, other-sha, duplicate.
# -Component: installed (the default), missing (not installed), no-consent, corrupt (same size, other bytes).
function New-SidecarWorld {
    param([Parameter(Mandatory = $true)] $Module, [Parameter(Mandatory = $true)][string] $Root, [Parameter(Mandatory = $true)][string] $Temp, [Parameter(Mandatory = $true)][string] $Label,
        [hashtable] $Modes = @{}, [string] $Rows = 'good', [string] $Component = 'installed', [string] $SidecarMode = 'ok')
    $install = Join-Path $Temp $Label
    $models = Join-Path $install 'models'
    $config = Join-Path $install 'config'
    $control = Join-Path $install 'control'
    foreach ($folder in @($models, (Join-Path $install 'state'), $config, $control)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $utf8 = New-Object Text.UTF8Encoding($false)
    $entries = @()
    foreach ($letter in @('a', 'b')) {
        $id = 'model-' + $letter
        $file = $id + '.gguf'
        $size = [int64] (16 + [int] [char] $letter)
        [IO.File]::WriteAllBytes((Join-Path $models $file), (New-Object byte[] ([int] $size)))
        $entries += [ordered] @{ id = $id; file = $file; sizeBytes = $size; sha256 = ($letter * 64); consent = $true
            url = 'https://example.invalid/' + $file; repository = 'sidecar-test/' + $id; revision = 'rev-' + $letter; upstreamModel = 'upstream/' + $id; upstreamRevision = 'up-' + $letter
            upstreamLicense = 'apache-2.0'; upstreamLicenseSha256 = ('f' * 64); artifactLicense = 'apache-2.0'; contextSize = 1024; parallel = 1; cacheTypeK = 'f16'; cacheTypeV = 'f16' }
        $modeList = @('ok')
        if ($Modes.ContainsKey($id)) { $modeList = @($Modes[$id]) }
        [IO.File]::WriteAllLines((Join-Path $install ($id + '.modes')), [string[]] $modeList)
    }
    $worldPath = Join-Path $install 'world.json'
    [IO.File]::WriteAllText($worldPath, (ConvertTo-Json -InputObject ([ordered] @{ installRoot = $install; models = $entries; recipes = @() }) -Depth 6), $utf8)
    # The catalog READER is replaced (the switch test world); the file only has to exist, because a start hashes it.
    $catalogPath = Join-Path $config 'catalog.json'
    [IO.File]::WriteAllText($catalogPath, '{"note":"sidecar test world: the catalog reader is replaced"}', $utf8)
    $componentsFixture = Join-Path $Root 'tests/fixtures/embedding-components-test.json'
    [IO.File]::Copy($componentsFixture, (Join-Path $config 'components.json'), $true)
    $componentEntry = @((Get-Content -LiteralPath $componentsFixture -Raw | ConvertFrom-Json).components)[0]
    $rowsDocument = Get-Content -LiteralPath (Join-Path $Root 'tests/fixtures/embedding-profiles-test.json') -Raw | ConvertFrom-Json
    $row = @($rowsDocument.sidecars)[0]
    # The switch test world serves engine version "test": the row is for that built-in engine.
    $row.engineId = 'llama.cpp-test-vulkan'
    $sidecarRows = @($row)
    switch -CaseSensitive ($Rows) {
        'good' { }
        'none' { $sidecarRows = @() }
        'gpu' { $row.placement = 'gpu' }
        'other-engine' { $row.engineId = 'llama.cpp-other-vulkan' }
        'other-sha' { $row.componentSha256 = ('0' * 64) }
        'duplicate' { $sidecarRows = @($row, $row) }
        default { throw "Unknown rows variant '$Rows'." }
    }
    $profilesPath = Join-Path $config 'serving-profiles.json'
    [IO.File]::WriteAllText($profilesPath, (ConvertTo-Json -InputObject ([ordered] @{ schema = 'bitworks.fastllm-serving-profiles/v1'; profiles = @(); addOns = @(); sidecars = @($sidecarRows) }) -Depth 6), $utf8)
    $componentRoot = & $Module { param($InstallRoot, $Entry) Get-FastLlmComponentRoot -InstallRoot $InstallRoot -Component $Entry } $install $componentEntry
    $modelFile = Join-Path $componentRoot ([string] $componentEntry.entryPoint)
    if ($Component -cne 'missing') {
        New-Item -ItemType Directory -Path $componentRoot -Force | Out-Null
        $bytes = Get-SidecarFixtureBytes
        if ($Component -ceq 'corrupt') { $bytes[0] = [byte] 0x58 }
        [IO.File]::WriteAllBytes($modelFile, $bytes)
        if ($Component -cne 'no-consent') { & $Module { param($InstallRoot, $Entry) Write-FastLlmComponentConsentReceipt -Component $Entry -InstallRoot $InstallRoot -AcceptanceMode 'explicit-switch' } $install $componentEntry }
    }
    [IO.File]::WriteAllText((Join-Path $control 'mode'), $SidecarMode)
    return [pscustomobject] @{ root = $install; path = $worldPath; port = (Get-SidecarFreePort); embeddingPort = (Get-SidecarFreePort); models = $models; state = (Join-Path $install 'state')
        config = $config; catalog = $catalogPath; control = $control; componentRoot = $componentRoot; modelFile = $modelFile; componentId = [string] $componentEntry.id }
}

# The synthetic plan of one text model: the native mock server on the world's port, its mode taken from the model's mode file at each start.
function New-SidecarTextPlan {
    param([Parameter(Mandatory = $true)] $World, [Parameter(Mandatory = $true)][string] $HelpersRoot, [Parameter(Mandatory = $true)][string] $EnginePath, [string] $ModelId = 'model-a')
    $document = Get-Content -LiteralPath $World.path -Raw | ConvertFrom-Json
    $model = @($document.models | Where-Object { [string] $_.id -ceq $ModelId })[0]
    return [pscustomobject] @{
        schemaVersion = 1; catalogVersion = 'switch-test'; hardwareFingerprint = 'synthetic'; profile = 'balanced'
        requestedModelId = $ModelId; requestedRecipeId = $null; recovered = $false; requestedContextSize = 0
        requestedServerPort = [int] $World.port; requestedThinking = 'auto'; requestedChatPage = 'off'; allowExperimentalModel = $false
        backend = 'Vulkan'; engineVersion = 'test'; enginePath = $EnginePath
        selectedAdapters = @([pscustomobject] @{ device = 'Vulkan0' }); model = $model; modelPath = (Join-Path $World.models ([string] $model.file))
        splitMode = 'none'; tensorSplit = $null; endpoint = "http://127.0.0.1:$($World.port)/v1"
        serverArguments = @('-NoLogo', '-NoProfile', '-File', (Join-Path $HelpersRoot 'mock-server.ps1'), '-Port', "$($World.port)", '-ModeFile', (Join-Path $World.root ([string] $model.id + '.modes')), '-Model', [string] $model.id, '-Context', '1024')
        recipe = [pscustomobject] @{ id = $null; origin = 'manual'; label = 'Chosen by you'; evidenceUrl = $null; expected = $null }; warnings = @()
    }
}

# The suite's table: events (every boundary call, in order), world, enginePath, helpersRoot, writes (every status document, in order), runs,
# the engine check's verdicts, idle (the clock acceleration of the idle poll) and newPlan (the text plan builder, bound to the caller's scope).
function New-SidecarTestState {
    param([Parameter(Mandatory = $true)][string] $EnginePath, [Parameter(Mandatory = $true)][string] $HelpersRoot)
    return @{ events = (New-Object 'Collections.Generic.List[string]'); world = $null; enginePath = $EnginePath; helpersRoot = $HelpersRoot
        writes = (New-Object 'Collections.Generic.List[string]'); runs = (New-Object 'Collections.Generic.List[object]'); dropped = (New-Object 'Collections.Generic.List[int]')
        # engineFailFrom: 0 = the engine check always passes; N = the Nth check of a scenario, and every later one, fails.
        engineFailFrom = 0; engineChecks = 0
        # hashFail: text model id -> N: the Nth file check of that model in a scenario, and every later one, fails.
        hashFail = @{}; hashCalls = @{}
        idle = @{ base = $null; polls = 0 }; newPlan = ${function:New-SidecarTextPlan} }
}

# Replaces the module's boundaries, driven by the table above.
function Install-SidecarTestBoundaries {
    param([Parameter(Mandatory = $true)] $Module, [Parameter(Mandatory = $true)] $State)
    $saved = & $Module {
        @{ supervisor = (Get-Command Invoke-FastLlmSupervisedServer).ScriptBlock; writeState = (Get-Command Write-FastLlmState).ScriptBlock
            hash = (Get-Command Test-FastLlmFileHash).ScriptBlock; idlePoll = (Get-Command Invoke-FastLlmIdleStopPoll).ScriptBlock
            closeProcess = (Get-Command Close-FastLlmSidecarProcess).ScriptBlock }
    }
    & $Module {
        param($S, $Original)
        $script:sidecarTest = $S
        $script:sidecarTestOriginal = $Original
        function script:Write-FastLlmState {
            param([string] $InstallRoot, $State, [string] $FileName = 'status.json')
            & $script:sidecarTestOriginal.writeState -InstallRoot $InstallRoot -State $State -FileName $FileName
            if ($FileName -ceq 'status.json') {
                $text = ConvertTo-Json -InputObject $State -Depth 12 -Compress
                $script:sidecarTest.writes.Add($text)
                $sidecarPhase = '-'
                if ($State -is [System.Collections.IDictionary] -and $State.Contains('sidecars')) { $sidecarPhase = [string] @($State['sidecars'])[0]['phase'] }
                $phase = ''
                if ($State -is [System.Collections.IDictionary]) { $phase = [string] $State['phase'] } elseif ($State.PSObject.Properties['phase']) { $phase = [string] $State.phase }
                $script:sidecarTest.events.Add('write:' + $phase + ':' + $sidecarPhase)
            }
        }
        # The count of output lines the process host dropped because they carried the key (or an api_key label), read just before the sidecar's
        # process host is closed. A number only: nothing the engine printed is read.
        function script:Close-FastLlmSidecarProcess {
            param([Parameter(Mandatory = $true)][System.Collections.IDictionary] $Session)
            try { $closing = $Session['process']; if ($null -ne $closing) { $script:sidecarTest.dropped.Add([int] $closing.SecretLinesDropped) } } catch { $null = $_ }
            & $script:sidecarTestOriginal.closeProcess -Session $Session
        }
        function script:Assert-FastLlmWindowsPrerequisites { }
        function script:Test-FastLlmEngineInstallation {
            $script:sidecarTest.events.Add('engine-check')
            $script:sidecarTest.engineChecks = [int] $script:sidecarTest.engineChecks + 1
            if ([int] $script:sidecarTest.engineFailFrom -gt 0 -and [int] $script:sidecarTest.engineChecks -ge [int] $script:sidecarTest.engineFailFrom) { return $false }
            return $true
        }
        function script:Get-FastLlmEngineExecutable { return $script:sidecarTest.enginePath }
        function script:Install-FastLlmModel { $script:sidecarTest.events.Add('INSTALL-MODEL') }
        function script:Save-FastLlmVerifiedFile { $script:sidecarTest.events.Add('NETWORK-SAVE') }
        # The text model's file is a placeholder (its hash is recorded and accepted); the embedding component's files are hashed for real.
        function script:Test-FastLlmFileHash {
            param([string] $Path, [string] $Sha256)
            $leaf = [IO.Path]::GetFileNameWithoutExtension($Path)
            $script:sidecarTest.events.Add('hash:' + $leaf)
            $full = [IO.Path]::GetFullPath($Path)
            $componentsRoot = [IO.Path]::GetFullPath((Join-Path $script:sidecarTest.world.root 'components'))
            if ($full.StartsWith($componentsRoot, [StringComparison]::OrdinalIgnoreCase)) { return (& $script:sidecarTestOriginal.hash -Path $Path -Sha256 $Sha256) }
            $script:sidecarTest.hashCalls[$leaf] = [int] $script:sidecarTest.hashCalls[$leaf] + 1
            if ($script:sidecarTest.hashFail.ContainsKey($leaf) -and [int] $script:sidecarTest.hashCalls[$leaf] -ge [int] $script:sidecarTest.hashFail[$leaf]) { return $false }
            return $true
        }
        function script:Get-FastLlmHardware { $script:sidecarTest.events.Add('inventory'); return [pscustomobject] @{ synthetic = $true } }
        function script:Get-FastLlmPlan {
            param($Hardware, $CatalogPath, $Profile, $InstallRoot, $ModelId, $ContextSize, [switch] $AllowExperimentalModel, $RecipesPath, $GpuVariantsPath, $RecipeId, [switch] $Recovered, [switch] $ResolveFallback, $FallbackFromRecipe, $FallbackReason, [int] $ServerPort = 0, [string] $Thinking = 'auto', [string] $ChatPage = 'off', [string] $KvContextProfile = 'default', [int] $KvSlots = 1, $KvProfilesPath)
            $target = [string] $ModelId
            if (-not $target) { $target = 'model-a' }
            $script:sidecarTest.events.Add('plan:' + $target)
            # The plan builder lives in the test's own scope: it is called through the table, as a script block bound to that scope.
            return (& $script:sidecarTest.newPlan -World $script:sidecarTest.world -HelpersRoot $script:sidecarTest.helpersRoot -EnginePath $script:sidecarTest.enginePath -ModelId $target)
        }
        # The sidecar is launched with the engine's REAL arguments; only the executable is the mock (the host PowerShell running the mock script).
        function script:Get-FastLlmSidecarCommand {
            param($Plan)
            $script:sidecarTest.events.Add('sidecar-command')
            return @{ fileName = [string] $script:sidecarTest.enginePath; arguments = @('-NoLogo', '-NoProfile', '-File', (Join-Path $script:sidecarTest.helpersRoot 'mock-embedding-server.ps1')) + @($Plan.serverArguments) }
        }
        # The supervisor, wrapped: which parameters it was given, and its own final document.
        function script:Invoke-FastLlmSupervisedServer {
            param($Plan, [string] $InstallRoot, [int] $LoadTimeoutSeconds = 300, [string] $CatalogPath, [string] $VulkanBarMitigation = 'off', [switch] $ThroughputCanary, [switch] $SelfTest, [string] $DeviceBinding = 'off', [int] $IdleStopMinutes = 0, [switch] $AllowSwitch, $SwitchContext, $SidecarSession, $ApiKeyHolder)
            $script:sidecarTest.events.Add('supervisor:' + [string] $Plan.model.id)
            $run = @{ modelId = [string] $Plan.model.id; bound = (@($PSBoundParameters.Keys | Sort-Object) -join ','); runId = $null; finalText = $null; failed = $false }
            $script:sidecarTest.runs.Add($run)
            try { return (& $script:sidecarTestOriginal.supervisor @PSBoundParameters) }
            catch { $run.failed = $true; throw }
            finally {
                try { $run.finalText = [IO.File]::ReadAllText((Join-Path (Join-Path $InstallRoot 'state') 'status.json')) } catch { $null = $_ }
                try { if ($run.finalText) { $run.runId = [string] ($run.finalText | ConvertFrom-Json).runId } } catch { $null = $_ }
            }
        }
        # The idle clock, accelerated on request: once the file "accelerate" exists in the world, every poll is 120 seconds after the one
        # before it (the most one poll may count), and the poll's number is left as a file so the client can wait for it.
        function script:Invoke-FastLlmIdleStopPoll {
            param($State, [scriptblock] $Fetch, [datetime] $Now, [int] $IdleMinutes)
            $t = $script:sidecarTest
            if (-not (Test-Path -LiteralPath (Join-Path $t.world.root 'accelerate'))) { return (& $script:sidecarTestOriginal.idlePoll -State $State -Fetch $Fetch -Now $Now -IdleMinutes $IdleMinutes) }
            if ($null -eq $t.idle.base) { $t.idle.base = $Now; $t.idle.polls = 0 }
            $t.idle.polls = [int] $t.idle.polls + 1
            $result = & $script:sidecarTestOriginal.idlePoll -State $State -Fetch $Fetch -Now ([datetime] $t.idle.base).AddSeconds(120 * [int] $t.idle.polls) -IdleMinutes $IdleMinutes
            [IO.File]::WriteAllText((Join-Path $t.world.root ('polls-' + [int] $t.idle.polls)), '')
            return $result
        }
    } $State $saved
}

function Use-SidecarWorld {
    param([Parameter(Mandatory = $true)] $Module, [Parameter(Mandatory = $true)] $State, [Parameter(Mandatory = $true)] $World)
    $State.world = $World
    $State.events.Clear(); $State.writes.Clear(); $State.runs.Clear(); $State.dropped.Clear()
    $State.engineFailFrom = 0
    $State.engineChecks = 0
    $State.hashFail = @{}
    $State.hashCalls = @{}
    $State.idle = @{ base = $null; polls = 0 }
    Install-SwitchTestWorld -Module $Module -WorldPath $World.path
}
