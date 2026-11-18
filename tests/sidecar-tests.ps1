#requires -Version 5.1
# The embedding sidecar (opt-in, off by default): a second supervised llama-server with a dedicated embedding model on its own loopback port,
# CPU placement only. The REAL start (Start-FastLlmServer), supervisor, sidecar code, component checks, row reader, status writer and run log
# run here against two mock engines: the native mock text server and tests/helpers/mock-embedding-server.ps1, which takes the sidecar's real
# arguments. Replaced, as in the model switch tests: the catalog (a small synthetic model list), the planner, the hardware inventory, the engine
# check and the text model's hash. The embedding component and its measured row are FIXTURES (tests/fixtures/embedding-*-test.json): no
# embedding model ships. An independent client process plays the user and the apps (tests/helpers/sidecar-client.ps1).
# No Radeon adapter, inference engine, model or network is needed.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force
$module = Get-Module FastLlm
. (Join-Path $root 'src/FastLlm.ServingSettings.ps1')
. (Join-Path $root 'src/FastLlm.ConnectInfo.ps1')
. (Join-Path $PSScriptRoot 'helpers/SidecarTestWorld.ps1')
. (Join-Path $PSScriptRoot 'helpers/module-log-tap.ps1')
$helpersRoot = Join-Path $PSScriptRoot 'helpers'
$enginePath = (Get-Process -Id $PID).Path
$isWindowsHost = ($env:OS -eq 'Windows_NT')
$script:count = 0
$script:failed = 0
# A failed check ends the suite, as in the other suites. FASTLLM_TESTS_CONTINUE=1 (a developer aid) records it and goes on instead.
function Check([bool] $Condition, [string] $Message) {
    if (-not $Condition) {
        if ($env:FASTLLM_TESTS_CONTINUE -ceq '1') { $script:failed++; Write-Host "FAIL: $Message"; return }
        throw "FAIL: $Message"
    }
    $script:count++
    Write-Host "PASS: $Message"
}
function InModule([scriptblock] $Block, [object[]] $Arguments = @()) { & $module $Block @Arguments }
function Get-Field($Object, [string] $Name) { if ($null -eq $Object) { return $null }; $p = $Object.PSObject.Properties[$Name]; if ($null -eq $p) { return $null }; return $p.Value }
function Test-PortFree([int] $Number) { $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Number); try { $l.Server.ExclusiveAddressUse = $true; $l.Start(); return $true } catch { return $false } finally { try { $l.Stop() } catch { $null = $_ } } }
function Test-ProcessAlive([int] $ProcessId) {
    if ($ProcessId -le 0) { return $false }
    try { $p = [Diagnostics.Process]::GetProcessById($ProcessId); try { return (-not $p.HasExited) } finally { $p.Dispose() } } catch { return $false }
}
function Wait-ProcessGone([int] $ProcessId, [int] $Seconds = 20) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.Elapsed.TotalSeconds -lt $Seconds) { if (-not (Test-ProcessAlive $ProcessId)) { return $true }; Start-Sleep -Milliseconds 100 }
    return (-not (Test-ProcessAlive $ProcessId))
}
function Wait-PortFree([int] $Number, [int] $Seconds = 20) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.Elapsed.TotalSeconds -lt $Seconds) { if (Test-PortFree $Number) { return $true }; Start-Sleep -Milliseconds 100 }
    return (Test-PortFree $Number)
}
function Get-FailureCode($Exception) { if ($null -eq $Exception -or $null -eq $Exception.Data) { return '' }; return [string] $Exception.Data['FastLlmFailureCode'] }
function Read-Control($World, [string] $Name) {
    $path = Join-Path $World.control $Name
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    for ($attempt = 0; $attempt -lt 50; $attempt++) { try { return @([IO.File]::ReadAllLines($path) | Where-Object { $_ }) } catch { Start-Sleep -Milliseconds 20 } }
    return @()
}
function Get-RunLog($World, [string] $RunId) {
    $files = @(Get-ChildItem -LiteralPath (Join-Path $World.state 'logs') -Filter ("run-*-$RunId.jsonl") -ErrorAction SilentlyContinue)
    if ($files.Count -ne 1) { return @() }
    return @([IO.File]::ReadAllLines($files[0].FullName) | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
}
function Get-LogEvents($Lines, [string] $Name) { return @($Lines | Where-Object { [string] $_.event -ceq $Name }) }
function Get-AllRunLogs($World) {
    $lines = @()
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $World.state 'logs') -Filter 'run-*.jsonl' -ErrorAction SilentlyContinue | Sort-Object Name)) { $lines += @([IO.File]::ReadAllLines($file.FullName) | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }) }
    return @($lines)
}
# Every file under the folder, byte-wise, for every word. The scenario's own instructions and the client's record are not FastLLM's files.
function Find-WordsInFiles([string] $Folder, [string[]] $Words) {
    $hits = New-Object 'System.Collections.Generic.List[string]'
    foreach ($file in @(Get-ChildItem -LiteralPath $Folder -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        if ($file.Name -ceq 'steps.json' -or $file.Name -ceq 'client-result.json') { continue }
        $text = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($file.FullName))
        foreach ($word in $Words) { if ($text.IndexOf($word, [StringComparison]::Ordinal) -ge 0) { $hits.Add($file.Name + ' :: ' + $word) } }
    }
    return $hits.ToArray()
}
function Get-Sidecar($Document) { $list = Get-Field $Document 'sidecars'; if ($null -eq $list) { return $null }; $entries = @($list); if ($entries.Count -lt 1) { return $null }; return $entries[0] }
function New-Step([hashtable] $Wait, [string] $Action, [hashtable] $More = @{}) {
    $step = [ordered] @{ action = $Action }
    if ($Wait) { $step.wait = $Wait }
    foreach ($key in $More.Keys) { $step[$key] = $More[$key] }
    return $step
}
# The listener table, for the API key's listener check. On Windows the product's own read is used (the seam stays $null); elsewhere lsof
# answers the same question, so the check is real on every test host. Every port that is asked about is recorded.
$listenerAsks = New-Object 'System.Collections.Generic.List[int]'
$listenerLies = @{}
# A port -> a rule: once the mock engine's auth.log (in the world's control folder) holds a line like the pattern, another program owns the
# port. Every check before the send then sees the sidecar, and the first check after a keyed send sees something else.
$listenerLieWhenKeyed = @{}
# A port -> a rule: once the mock engine's auth.log (its control folder) holds a line like the pattern, another program owns the port. The checks
# before the send then see the sidecar, and the first check after a send sees something else.
$listenerLieWhenKeyed = @{}
function Get-TestListenerOwners([int] $Port) {
    $found = New-Object 'System.Collections.Generic.List[int]'
    if ($isWindowsHost) {
        if (-not ('Bitworks.FastLlm.WindowsGpuTelemetry' -as [type])) { Add-Type -Path (Join-Path $root 'src/WindowsGpuTelemetry.cs') -ErrorAction Stop }
        foreach ($owner in @([Bitworks.FastLlm.WindowsGpuTelemetry]::GetLoopbackListenerOwners($Port))) { $found.Add([int] $owner) }
    }
    else { foreach ($line in @(& lsof -nP "-iTCP@127.0.0.1:$Port" -sTCP:LISTEN -Fp 2>$null)) { if ([string] $line -match '^p(\d+)$') { $value = [int] $Matches[1]; if (-not $found.Contains($value)) { $found.Add($value) } } } }
    return $found.ToArray()
}
function Set-RecordingListenerOwners {
    $provider = {
        param([int] $Port)
        $listenerAsks.Add($Port)
        # A test may say that another program owns a port: the answer for that port is then the process id it names.
        if ($listenerLies.ContainsKey($Port)) { return @([int] $listenerLies[$Port]) }
        if ($listenerLieWhenKeyed.ContainsKey($Port)) {
            $rule = $listenerLieWhenKeyed[$Port]
            if (@(Read-Control $rule.world 'auth.log' | Where-Object { $_ -clike $rule.pattern }).Count -gt 0) { return @([int] $PID) }
        }
        return @(Get-TestListenerOwners $Port)
    }
    & $module { param($P) $script:FastLlmApiKeyListenerOwners = $P } $provider
}
# A reversible fake protector (xor plus a header), so the key store logic runs everywhere and the file is never plain text.
$fakeProtector = @{
    Protect = { param([byte[]] $Bytes) $out = New-Object 'System.Collections.Generic.List[byte]'; $out.AddRange([byte[]] (0x46, 0x4B, 0x31)); foreach ($b in $Bytes) { $out.Add([byte] ($b -bxor 0x5A)) }; return , ($out.ToArray()) }
    Unprotect = { param([byte[]] $Bytes)
        if ($Bytes.Length -lt 4 -or $Bytes[0] -ne 0x46 -or $Bytes[1] -ne 0x4B -or $Bytes[2] -ne 0x31) { throw 'fake protector: not protected data' }
        $out = New-Object 'System.Collections.Generic.List[byte]'; for ($i = 3; $i -lt $Bytes.Length; $i++) { $out.Add([byte] ($Bytes[$i] -bxor 0x5A)) }; return , ($out.ToArray()) }
}
# A marker key: well-formed, recognisable, and with a tail (the last four characters) that appears nowhere else. Never a real key.
$keyMarker = 'fl-' + 'SIDECARKEY' * 3 + 'embedMARK' + 'Qj5_'
if ($keyMarker.Length -ne 46) { throw 'the test marker is not a well-formed key' }
# A second marker key, for a key that is changed while the session runs.
$rotatedMarker = 'fl-' + 'ROTATESIDE' * 3 + 'embedMARK' + 'Vx8-'
if ($rotatedMarker.Length -ne 46) { throw 'the second test marker is not a well-formed key' }
$keyWords = @('SIDECARKEY', 'embedMARK', 'Qj5_', 'ROTATESIDE', 'Vx8-')
function New-Holder([string] $Text) { $h = New-Object Security.SecureString; foreach ($c in $Text.ToCharArray()) { $h.AppendChar($c) }; $h.MakeReadOnly(); return $h }
$documentMarker = 'FLLM-MARKER-EMBED-DOC-91c2'
$vectorMarker = '0.123457'

# A short folder name: the component installer refuses an install folder whose longest file path would pass the Windows limit.
$temp = Join-Path ([IO.Path]::GetTempPath()) ('fls-' + [Guid]::NewGuid().ToString('N').Substring(0, 12))
New-Item -ItemType Directory -Path $temp -Force | Out-Null
$st = New-SidecarTestState -EnginePath $enginePath -HelpersRoot $helpersRoot
$savedControl = [Environment]::GetEnvironmentVariable('FASTLLM_TEST_SIDECAR_CONTROL')
$suitePassed = $false

# The deadline of one scenario step: its own timeoutSeconds, else the suite's step wait.
function Get-StepTimeoutSeconds([object[]] $Steps, $Index) {
    $step = @($Steps)[[int] $Index]
    if ($null -ne $step -and $step.Contains('timeoutSeconds')) { return [int] $step['timeoutSeconds'] }
    return [int] $script:StepTimeoutSeconds
}
# Runs one scenario: the operation lock is taken here (as the CLI does) and held until the start has returned and the client has finished.
$script:ScenarioLoadTimeoutSeconds = 600
# The client's step wait is what the product may take for a step: the text model's load timeout, then the sidecar's load timeout (read from
# the module) and its canary request (30 s, the timeout in FastLlm.Sidecar.ps1), and a margin for a loaded machine. A scenario that never
# matches still fails, only later.
$script:StepTimeoutSeconds = [int] $script:ScenarioLoadTimeoutSeconds + [int] (InModule { $script:FastLlmSidecarLoadTimeoutSeconds }) + 30 + 60
function Invoke-SidecarScenario {
    param([string] $Label, $World, [object[]] $Steps, [hashtable] $StartOptions = @{}, [switch] $NoEmbeddings)
    $stepsPath = Join-Path $World.root 'steps.json'
    $resultPath = Join-Path $World.root 'client-result.json'
    [IO.File]::WriteAllText($stepsPath, (ConvertTo-Json -InputObject ([ordered] @{ steps = @($Steps) }) -Depth 8), (New-Object Text.UTF8Encoding($false)))
    [Environment]::SetEnvironmentVariable('FASTLLM_TEST_SIDECAR_CONTROL', [string] $World.control)
    $lock = Enter-FastLlmOperation $World.root
    $client = New-Object Diagnostics.Process
    $client.StartInfo.FileName = $enginePath
    $quote = { param([string] $Text) "'" + $Text.Replace("'", "''") + "'" }
    $clientCode = "& $(& $quote (Join-Path $helpersRoot 'sidecar-client.ps1')) -Root $(& $quote $root) -InstallRoot $(& $quote $World.root) -WorldPath $(& $quote $World.path) -StepsPath $(& $quote $stepsPath) -ResultPath $(& $quote $resultPath) -CatalogPath $(& $quote $World.catalog) -StepTimeoutSeconds $([int] $script:StepTimeoutSeconds)"
    $client.StartInfo.Arguments = '-NoLogo -NoProfile -OutputFormat Text -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($clientCode))
    $client.StartInfo.UseShellExecute = $false
    $exit = $null; $failure = $null; $clientExited = $false
    $console = New-Object 'System.Collections.Generic.List[string]'
    try {
        $client.Start() | Out-Null
        $plan = New-SidecarTextPlan -World $World -HelpersRoot $helpersRoot -EnginePath $enginePath -ModelId 'model-a'
        $arguments = @{ Plan = $plan; CatalogPath = $World.catalog; InstallRoot = $World.root; LoadTimeoutSeconds = $script:ScenarioLoadTimeoutSeconds }
        if (-not $NoEmbeddings) { $arguments.Embeddings = 'on'; $arguments.EmbeddingPort = [int] $World.embeddingPort }
        foreach ($key in $StartOptions.Keys) { $arguments[$key] = $StartOptions[$key] }
        try {
            foreach ($item in @(Start-FastLlmServer @arguments 6>&1)) {
                if ($item -is [System.Management.Automation.InformationRecord]) { $console.Add([string] $item.MessageData) } else { $exit = $item }
            }
        }
        catch { $failure = $_.Exception }
        $clientSeconds = 360
        foreach ($scenarioStep in @($Steps)) { $stepSeconds = [int] $script:StepTimeoutSeconds; if ($scenarioStep.Contains('timeoutSeconds')) { $stepSeconds = [int] $scenarioStep['timeoutSeconds'] }; $clientSeconds += $stepSeconds }
        $clientExited = $client.WaitForExit($clientSeconds * 1000)
    }
    finally {
        if (-not $client.HasExited) { $client.Kill() }
        $client.Dispose()
        $lock.Dispose()
        [Environment]::SetEnvironmentVariable('FASTLLM_TEST_SIDECAR_CONTROL', $savedControl)
    }
    if ($null -ne $failure) { Write-Host ("Scenario ${Label}: the start raised: " + [regex]::Replace([string] $failure.Message, '[\x00-\x1f\x7f]', ' ')) }
    $record = $null
    if (Test-Path -LiteralPath $resultPath) { $record = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json }
    $outcomes = @(); $observations = @()
    if ($null -ne $record) { $outcomes = @($record.steps); $observations = @($record.observations) }
    $completed = [bool] ($null -ne $record -and $record.completed -and $clientExited)
    if (-not $completed) {
        Write-Host ("Scenario ${Label}: client steps: " + (@($outcomes | ForEach-Object { "$($_.index):$($_.action):matched=$($_.matched):ms=$($_.ms):timeout=$(Get-StepTimeoutSeconds $Steps $_.index)s:$($_.error)" }) -join ' | '))
        Write-Host ("Scenario ${Label}: observations: " + (@($observations | ForEach-Object { "$($_.ms)ms:$($_.phase)/$($_.modelId)/$($_.sidecarPhase)/$($_.sidecarFailureCode)" }) -join ' | '))
        Write-Host ("Scenario ${Label}: events: " + ($st.events -join ','))
        Write-Host ("Scenario ${Label}: console: " + ($console -join ' || '))
    }
    $finalText = $null
    try { $finalText = [IO.File]::ReadAllText((Join-Path $World.state 'status.json')) } catch { $finalText = $null }
    $final = $null
    if ($finalText) { $final = $finalText | ConvertFrom-Json }
    return [pscustomobject] @{ exit = $exit; failure = $failure; completed = $completed; steps = $outcomes; observations = $observations; console = @($console.ToArray())
        runs = @($st.runs.ToArray()); final = $final; events = @($st.events.ToArray()); writes = @($st.writes.ToArray() | ForEach-Object { $parsed = $_ | ConvertFrom-Json; $parsed }); world = $World }
}
function Get-StepOutcome($Scenario, [string] $Action, [int] $Occurrence = 0) { return @($Scenario.steps | Where-Object { [string] $_.action -ceq $Action })[$Occurrence] }
# A status document with what makes two runs differ by design removed: the run id, the times, the process ids and the sidecar block.
function ConvertTo-ComparableStatus($Document) {
    $copy = (ConvertTo-Json -InputObject $Document -Depth 12 -Compress) | ConvertFrom-Json
    foreach ($name in @('runId', 'updatedAt', 'sidecars')) { if ($copy.PSObject.Properties[$name]) { $copy.PSObject.Properties.Remove($name) } }
    if ($copy.PSObject.Properties['processIdentity'] -and $null -ne $copy.processIdentity) { $copy.processIdentity = 'present' }
    # The GPU memory check stamps the time it ran.
    return [regex]::Replace((ConvertTo-Json -InputObject $copy -Depth 12 -Compress), '"checkedAtUtc":"[^"]*"', '"checkedAtUtc":"time"')
}

try {
    InModule { Initialize-FastLlmProcessHost }
    InModule { param($P) $script:FastLlmApiKeyProtector = $P } @($fakeProtector)
    Set-RecordingListenerOwners

    # ================= the arguments: the golden, the engine's own option names, loopback =================
    # Planned with the REAL catalog (the test world that replaces it is installed further down) from the fixture component and its fixture row.
    $realCatalog = Join-Path $root 'config/catalog.json'
    $fixtureComponents = Join-Path $root 'tests/fixtures/embedding-components-test.json'
    $fixtureProfiles = Join-Path $root 'tests/fixtures/embedding-profiles-test.json'
    $golden = Get-Content -LiteralPath (Join-Path $root 'tests/fixtures/embedding-server-arguments.json') -Raw | ConvertFrom-Json
    Check ($golden.schema -ceq 'fastllm.embedding-arguments-golden.v1') 'golden: the embedding argument fixture has its own schema'
    Check ($golden.embeddingProfilesSha256 -ceq (Get-FileHash -LiteralPath $fixtureProfiles -Algorithm SHA256).Hash.ToLowerInvariant() -and $golden.embeddingComponentsSha256 -ceq (Get-FileHash -LiteralPath $fixtureComponents -Algorithm SHA256).Hash.ToLowerInvariant()) 'golden: it is bound by sha256 to the TEST row and the TEST component it was built from'
    $goldenInstall = Join-Path $temp 'golden-install'
    $goldenEntry = @((Get-Content -LiteralPath $fixtureComponents -Raw | ConvertFrom-Json).components)[0]
    $goldenComponentRoot = InModule { param($InstallRoot, $Entry) Get-FastLlmComponentRoot -InstallRoot $InstallRoot -Component $Entry } @($goldenInstall, $goldenEntry)
    New-Item -ItemType Directory -Path $goldenComponentRoot -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $goldenComponentRoot ([string] $goldenEntry.entryPoint)), (Get-SidecarFixtureBytes))
    InModule { param($InstallRoot, $Entry) Write-FastLlmComponentConsentReceipt -Component $Entry -InstallRoot $InstallRoot -AcceptanceMode 'explicit-switch' } @($goldenInstall, $goldenEntry)
    $normalise = { param([string] $Text) $value = $Text; foreach ($variant in @($goldenInstall, $goldenInstall.Replace('\', '/'), $goldenInstall.Replace('/', '\'))) { if ($variant) { $value = $value.Replace($variant, '<install-root>') } }; return $value.Replace('\', '/') }
    $goldenDifferences = 0
    $livePlans = @()
    foreach ($goldenRow in @($golden.rows)) {
        $live = InModule { param($Catalog, $InstallRoot, $Port, $Components, $Profiles) Get-FastLlmSidecarPlan -CatalogPath $Catalog -InstallRoot $InstallRoot -Port $Port -ComponentsPath $Components -ProfilesPath $Profiles } @($realCatalog, $goldenInstall, [int] $goldenRow.port, $fixtureComponents, $fixtureProfiles)
        $livePlans += $live
        $liveArguments = @($live.serverArguments | ForEach-Object { & $normalise ([string] $_) })
        $same = ($liveArguments.Count -eq @($goldenRow.arguments).Count)
        for ($k = 0; $same -and $k -lt $liveArguments.Count; $k++) { if (-not ($liveArguments[$k] -ceq [string] $goldenRow.arguments[$k])) { $same = $false } }
        foreach ($field in @('componentId', 'engineId', 'backend', 'placement', 'pooling', 'endpoint')) { if (-not ([string] $live.$field -ceq [string] $goldenRow.$field)) { $same = $false } }
        foreach ($field in @('port', 'contextSize', 'dimension')) { if ([int] $live.$field -ne [int] $goldenRow.$field) { $same = $false } }
        if (-not $same) { $goldenDifferences++; Write-Host "DIFF golden row $($goldenRow.name): $($liveArguments -join ' ')" }
    }
    Check (@($golden.rows).Count -eq 2 -and $goldenDifferences -eq 0) 'golden: the planned sidecar arguments equal tests/fixtures/embedding-server-arguments.json, -ceq on every argument'
    $firstArguments = @($livePlans[0].serverArguments | ForEach-Object { [string] $_ })
    $valueOf = { param([string[]] $Arguments, [string] $Name) for ($i = 0; $i -lt $Arguments.Count - 1; $i++) { if ($Arguments[$i] -ceq $Name) { return $Arguments[$i + 1] } }; return $null }
    Check ((& $valueOf $firstArguments '--n-gpu-layers') -ceq '0' -and [Array]::IndexOf($firstArguments, '--n-gpu-layers') -eq ([Array]::IndexOf($firstArguments, '--device') + 2)) 'arguments: no layer is offloaded (--n-gpu-layers 0, next to --device none)'
    Check ((& $valueOf $firstArguments '--device') -ceq 'none' -and $firstArguments -ccontains '--embedding' -and (& $valueOf $firstArguments '--pooling') -ceq 'last' -and (& $valueOf $firstArguments '-c') -ceq '8192') 'arguments: CPU placement (--device none), --embedding, the row''s pooling and the row''s context'
    Check ((& $valueOf $firstArguments '--host') -ceq '127.0.0.1' -and (& $valueOf $firstArguments '--port') -ceq '8081' -and (& $valueOf $firstArguments '--alias') -ceq 'test-embedding-model-q8' -and $firstArguments -ccontains '--no-ui' -and $firstArguments -ccontains '--offline') 'arguments: loopback host, the embedding port, the component id as the served name, no chat page and no download'
    Check ((& $valueOf $firstArguments '--model') -ceq (Join-Path $goldenComponentRoot ([string] $goldenEntry.entryPoint))) 'arguments: the model is the component''s model file'
    Check (@($firstArguments | Where-Object { $_ -cmatch '(?i)api[-_]?key' }).Count -eq 0) 'arguments: no argument names an API key'
    $surface = Get-Content -LiteralPath (Join-Path $root 'tests/fixtures/engine-surface-b10698.json') -Raw | ConvertFrom-Json
    $surfaceOptions = @($surface.options | ForEach-Object { [string] $_ })
    $unknownOptions = @($firstArguments | Where-Object { $_ -cmatch '^-' -and $surfaceOptions -cnotcontains $_ })
    Check ($surfaceOptions.Count -gt 50 -and $unknownOptions.Count -eq 0) "arguments: every option is one the pinned built-in engine lists (unknown: $($unknownOptions -join ' '))"
    # Whatever is asked for, the host argument is the literal loopback address: there is no parameter through which another could arrive.
    $builderParameters = InModule { @((Get-Command Get-FastLlmSidecarArguments).Parameters.Keys | Where-Object { $_ -cin @('ModelPath', 'Alias', 'Port', 'ContextSize', 'Pooling') }) }
    $allBuilderParameters = InModule { @((Get-Command Get-FastLlmSidecarArguments).Parameters.Keys | Where-Object { [System.Management.Automation.Cmdlet]::CommonParameters -notcontains $_ }) }
    Check ($builderParameters.Count -eq 5 -and $allBuilderParameters.Count -eq 5) 'arguments: the builder takes the model path, the name, the port, the context and the pooling, and no host'
    $hostsSeen = @()
    foreach ($tryPort in @(1024, 8081, 65535)) { $built = @(InModule { param($Port) Get-FastLlmSidecarArguments -ModelPath 'm.gguf' -Alias 'a' -Port $Port -ContextSize 512 -Pooling 'mean' } @($tryPort)); $hostsSeen += (& $valueOf ([string[]] $built) '--host') }
    Check (@($hostsSeen | Where-Object { $_ -cne '127.0.0.1' }).Count -eq 0) 'arguments: the host is 127.0.0.1 for every port'

    # ================= what ships: no embedding model, so the option is refused =================
    # The REAL configuration of this repository (config/catalog.json, config/components.json, config/serving-profiles.json).
    $shippedRoot = Join-Path $temp 'shipped-install'
    New-Item -ItemType Directory -Path $shippedRoot -Force | Out-Null
    $shippedFailure = $null
    try { Assert-FastLlmEmbeddingsAvailable -CatalogPath $realCatalog -InstallRoot $shippedRoot } catch { $shippedFailure = $_.Exception }
    Check ((Get-FailureCode $shippedFailure) -ceq 'embeddings-no-model' -and [string] $shippedFailure.Data['FastLlmReason'] -ceq 'EmbeddingsRefused') 'shipped: with the configuration this release ships, -Embeddings on is refused as embeddings-no-model (no embedding model is listed)'
    Check (@(@(Get-FastLlmComponents -ComponentsPath (Join-Path $root 'config/components.json')) | Where-Object { [string] $_.kind -ceq 'embedding-model' }).Count -eq 0 -and @((Get-Content -LiteralPath (Join-Path $root 'config/serving-profiles.json') -Raw | ConvertFrom-Json).sidecars).Count -eq 0) 'shipped: config/components.json lists no embedding-model component and config/serving-profiles.json has no sidecar row'
    # Even the fixture component, installed and consented, is refused against the shipped rows: nothing is measured.
    $shippedWithFixture = $null
    try { $null = InModule { param($Catalog, $InstallRoot, $Components) Get-FastLlmSidecarPlan -CatalogPath $Catalog -InstallRoot $InstallRoot -ComponentsPath $Components } @($realCatalog, $goldenInstall, $fixtureComponents) } catch { $shippedWithFixture = $_.Exception }
    Check ((Get-FailureCode $shippedWithFixture) -ceq 'embeddings-not-measured') 'shipped: an installed embedding model with no measured row is refused as embeddings-not-measured'
    $cliSource = [IO.File]::ReadAllText((Join-Path $root 'fast-llm.ps1'))
    $startBlock = $cliSource.Substring($cliSource.IndexOf("        'start' {"))
    Check ($startBlock.IndexOf("if (`$effectiveEmbeddings -ceq 'on') { Assert-FastLlmEmbeddingsAvailable ") -gt 0 -and $startBlock.IndexOf('Assert-FastLlmEmbeddingsAvailable') -lt $startBlock.IndexOf('$hardware = Get-FastLlmHardware', $startBlock.IndexOf('$maximumPlanAttempts = 3')) -and $cliSource.Contains("if (`$effectiveEmbeddings -ceq 'on') { `$startPolicyOptions.Embeddings = 'on'; `$startPolicyOptions.EmbeddingPort = `$effectiveEmbeddingPort }")) 'command line: a live start asks whether embeddings are available before its first hardware probe and plan, and hands the option to the start only when it is on'

    # ================= the embedding model is a component: installed, consented and hash-verified like the others =================
    # A component built now (short names, so its paths fit the installer's Windows path limit under any temp folder): the fixture's bytes in
    # an archive, pinned by the archive's real size and SHA-256, and a row for it.
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $archiveSource = Join-Path $temp 'zs'
    New-Item -ItemType Directory -Path $archiveSource -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $archiveSource 'emb-q8.gguf'), (Get-SidecarFixtureBytes))
    $archivePath = Join-Path $temp 'emb-q8.zip'
    [System.IO.Compression.ZipFile]::CreateFromDirectory($archiveSource, $archivePath)
    $installDocument = Get-Content -LiteralPath $fixtureComponents -Raw | ConvertFrom-Json
    $installComponent = $installDocument.components[0]
    $installComponent.id = 'emb-q8'; $installComponent.version = 't1'; $installComponent.entryPoint = 'emb-q8.gguf'
    $installComponent.source.fileManifest[0].path = 'emb-q8.gguf'
    $installComponent.source.sha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $installComponent.source.sizeBytes = [int64] (Get-Item -LiteralPath $archivePath).Length
    $installComponents = Join-Path $temp 'ic.json'
    [IO.File]::WriteAllText($installComponents, (ConvertTo-Json -InputObject $installDocument -Depth 8), (New-Object Text.UTF8Encoding($false)))
    $installRows = Get-Content -LiteralPath $fixtureProfiles -Raw | ConvertFrom-Json
    $installRows.sidecars[0].componentId = 'emb-q8'
    $installProfiles = Join-Path $temp 'ip.json'
    [IO.File]::WriteAllText($installProfiles, (ConvertTo-Json -InputObject $installRows -Depth 8), (New-Object Text.UTF8Encoding($false)))
    $installRoot = Join-Path $temp 'ci'
    $downloads = @{ count = 0 }
    $copySeam = { param($Url, $Destination, $Sha256, $SizeBytes, $AllowedRedirectHosts) $downloads.count++; New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null; [IO.File]::Copy($archivePath, $Destination, $true) }.GetNewClosure()
    $installPlan = { InModule { param($Catalog, $InstallRoot, $Components, $Profiles) Get-FastLlmSidecarPlan -CatalogPath $Catalog -InstallRoot $InstallRoot -ComponentsPath $Components -ProfilesPath $Profiles } @($realCatalog, $installRoot, $installComponents, $installProfiles) }
    $planBeforeInstall = $null
    try { $null = & $installPlan } catch { $planBeforeInstall = $_.Exception }
    $refusedInstall = $null
    try { $null = Install-FastLlmComponent -ComponentsPath $installComponents -ComponentId 'emb-q8' -InstallRoot $installRoot -Unattended -Download $copySeam 6>$null } catch { $refusedInstall = $_.Exception }
    if ((Get-FailureCode $refusedInstall) -ceq 'component-path-too-long') { Write-Host 'SKIP: the temp folder is too long for the component installer''s Windows path limit; the install checks run where it fits.' }
    else {
        Check ((Get-FailureCode $planBeforeInstall) -ceq 'embeddings-no-model' -and $null -ne $refusedInstall -and $downloads.count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $installRoot 'components/embedding-model'))) 'component: an embedding-model component is not installed without its license being accepted (nothing downloaded), and without it the option is refused'
        $null = Install-FastLlmComponent -ComponentsPath $installComponents -ComponentId 'emb-q8' -InstallRoot $installRoot -AcceptLicense -Unattended -Download $copySeam 6>$null
        $installedEntry = @(Get-FastLlmComponents -ComponentsPath $installComponents)[0]
        $installedRoot = [string] (Get-FastLlmComponentRoot -InstallRoot $installRoot -Component $installedEntry)
        $installedFile = Join-Path $installedRoot 'emb-q8.gguf'
        Check ($downloads.count -eq 1 -and (Test-Path -LiteralPath $installedFile -PathType Leaf) -and $installedRoot.Replace('\', '/').EndsWith('/components/embedding-model/emb-q8/t1') -and (Test-FastLlmComponentInstallation -InstallRoot $installRoot -Component $installedEntry) -and (InModule { param($Entry, $InstallRoot) Test-FastLlmComponentConsentReceipt -Component $Entry -InstallRoot $InstallRoot } @($installedEntry, $installRoot))) 'component: the shipped component installer installs the embedding-model kind side by side (verified archive, exact file list, consent receipt)'
        $planAfterInstall = & $installPlan
        Check ([string] $planAfterInstall.modelPath -ceq $installedFile -and [string] $planAfterInstall.componentSha256 -ceq [string] $goldenEntry.source.fileManifest[0].sha256 -and [string] $planAfterInstall.componentId -ceq 'emb-q8') 'component: once it is installed and consented, the plan names its model file and its pinned SHA-256'
        # A changed file is no longer the installed component, and a removed receipt is no longer consent.
        $installedBytes = [IO.File]::ReadAllBytes($installedFile)
        [IO.File]::WriteAllBytes($installedFile, (New-Object byte[] 7))
        $planChangedSize = $null; try { $null = & $installPlan } catch { $planChangedSize = $_.Exception }
        [IO.File]::WriteAllBytes($installedFile, $installedBytes)
        $receiptFile = InModule { param($Entry, $InstallRoot) Get-FastLlmComponentConsentPath -Component $Entry -InstallRoot $InstallRoot } @($installedEntry, $installRoot)
        [IO.File]::Delete($receiptFile)
        $planNoReceipt = $null; try { $null = & $installPlan } catch { $planNoReceipt = $_.Exception }
        Check ((Get-FailureCode $planChangedSize) -ceq 'embeddings-no-model' -and (Get-FailureCode $planNoReceipt) -ceq 'embeddings-no-model') 'component: a model file of another size, or a missing consent receipt, makes it not installed and approved (embeddings-no-model)'
    }
    $unknownKind = Join-Path $temp 'uk.json'
    [IO.File]::WriteAllText($unknownKind, ([IO.File]::ReadAllText($fixtureComponents)).Replace('"kind": "embedding-model"', '"kind": "embedding"'), (New-Object Text.UTF8Encoding($false)))
    $unknownKindFailure = $null
    try { $null = @(Get-FastLlmComponents -ComponentsPath $unknownKind) } catch { $unknownKindFailure = [string] $_.Exception.Message }
    Check ([string] $unknownKindFailure -clike "*unsupported kind 'embedding'*") 'component: the kind list stays closed (embedding-model is accepted, any other new word is refused)'

    # ================= the session's sidecar between runs (no process is started here) =================
    $sessionPlan = $livePlans[0]
    $session = InModule { param($Plan) New-FastLlmSidecarSession -Plan $Plan } @($sessionPlan)
    $sessionState = @{ runId = ('0' * 32) }
    $enteredBlock = InModule { param($Session, $InstallRoot, $State) Enter-FastLlmSidecarRun -Session $Session -InstallRoot $InstallRoot -State $State -ApiKeyHolder $null } @($session, $goldenInstall, $sessionState)
    Check ([object]::ReferenceEquals($enteredBlock, $session.block) -and [string] $enteredBlock['phase'] -ceq 'waiting' -and (@($enteredBlock.Keys) -join ',') -ceq 'role,componentId,endpoint,phase,processIdentity,placement,canary') 'session: a run is given the session''s one block, waiting, with exactly its seven fields'
    # A run that ends before it was Ready (a start that failed, with a stand-in start to follow) never started the sidecar: the next run
    # of the same session waits for its own Ready and starts it.
    InModule { param($Session, $InstallRoot, $State) Exit-FastLlmSidecarRun -Session $Session -InstallRoot $InstallRoot -State $State } @($session, $goldenInstall, $sessionState)
    $afterFailedRun = [string] $session.block['phase']
    $null = InModule { param($Session, $InstallRoot, $State) Enter-FastLlmSidecarRun -Session $Session -InstallRoot $InstallRoot -State $State -ApiKeyHolder $null } @($session, $goldenInstall, $sessionState)
    Check ($afterFailedRun -ceq 'stopped' -and [string] $session.block['phase'] -ceq 'waiting' -and -not [bool] $session['attempted']) 'session: a run that ended before Ready leaves the sidecar unstarted (its document says stopped), and the next run of the session waits again'
    InModule { param($Session, $InstallRoot, $State) Exit-FastLlmSidecarRun -Session $Session -InstallRoot $InstallRoot -State $State -Keep } @($session, $goldenInstall, $sessionState)
    Check ([string] $session.block['phase'] -ceq 'waiting') 'session: a run that hands over to another run of the session (-Keep) changes nothing'
    # A step can never raise: with nothing installed for it to start, the block turns failed with a typed code and the caller goes on.
    $stepChanged = InModule { param($Session, $InstallRoot, $State) Step-FastLlmSidecar -Session $Session -InstallRoot $InstallRoot -State $State -TextPort 8080 6>$null } @($session, $goldenInstall, $sessionState)
    Check ($stepChanged -eq $true -and [string] $session.block['phase'] -ceq 'failed' -and [string] $session.block['failureCode'] -ceq 'embeddings-engine-unavailable' -and [bool] $session['attempted']) 'session: a step never raises; with no engine installed the block turns failed (embeddings-engine-unavailable)'
    $stepAgain = InModule { param($Session, $InstallRoot, $State) Step-FastLlmSidecar -Session $Session -InstallRoot $InstallRoot -State $State -TextPort 8080 6>$null } @($session, $goldenInstall, $sessionState)
    $null = InModule { param($Session, $InstallRoot, $State) Enter-FastLlmSidecarRun -Session $Session -InstallRoot $InstallRoot -State $State -ApiKeyHolder $null } @($session, $goldenInstall, $sessionState)
    Check ($stepAgain -eq $false -and [string] $session.block['phase'] -ceq 'failed' -and [string] $session.block['failureCode'] -ceq 'embeddings-engine-unavailable') 'session: a failed sidecar stays failed for the session: no later step and no later run starts it again'
    InModule { param($Session, $InstallRoot) Stop-FastLlmSidecarSession -Session $Session -InstallRoot $InstallRoot } @($session, $goldenInstall)
    Check ([string] $session.block['phase'] -ceq 'failed') 'session: ending the session keeps a failed block failed'

    # ================= removal: a live sidecar keeps its embedding component in use =================
    # The in-use check lets a component be removed only when no running FastLLM can reach into it. A live sidecar block (waiting, starting,
    # checking or ready) names the embedding component it serves; the status records no path for it, so the component's own folder decides.
    $inUseInstall = Join-Path $temp 'in-use-install'
    $inUseState = Join-Path $inUseInstall 'state'
    New-Item -ItemType Directory -Path $inUseState -Force | Out-Null
    $inUseRoot = Join-Path $inUseInstall 'components/embedding-model/emb-q8/t1'
    $inUseOther = Join-Path $inUseInstall 'components/embedding-model/emb-other/t1'
    New-Item -ItemType Directory -Path $inUseRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $inUseOther -Force | Out-Null
    $inUseEngineRoot = Join-Path $inUseInstall 'engines/llama.cpp/test/vulkan'
    $writeInUseStatus = {
        param([string] $Phase)
        $block = [ordered] @{ role = 'embedding'; componentId = 'emb-q8'; endpoint = 'http://127.0.0.1:8081/v1'; phase = $Phase; processIdentity = $null; placement = 'cpu'; canary = $null }
        $document = [ordered] @{ schemaVersion = 1; runId = 'r'; phase = 'ready'; engineExecutable = (Join-Path $inUseEngineRoot 'llama-server.exe'); sidecars = @($block) }
        [IO.File]::WriteAllText((Join-Path $inUseState 'status.json'), (ConvertTo-Json -InputObject $document -Depth 8))
    }
    $inUseLock = [IO.File]::Open((Join-Path $inUseState 'operation.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        $inUseAnswers = [ordered] @{}
        foreach ($inUsePhase in @('waiting', 'starting', 'checking', 'ready', 'failed', 'stopped')) {
            & $writeInUseStatus $inUsePhase
            $inUseAnswers[$inUsePhase] = [bool] (InModule { param($I, $C) Test-FastLlmComponentInUse -InstallRoot $I -ComponentRoot $C } @($inUseInstall, $inUseRoot))
        }
        & $writeInUseStatus 'ready'
        $inUseOtherAnswer = [bool] (InModule { param($I, $C) Test-FastLlmComponentInUse -InstallRoot $I -ComponentRoot $C } @($inUseInstall, $inUseOther))
        $inUseEngineAnswer = [bool] (InModule { param($I, $C) Test-FastLlmComponentInUse -InstallRoot $I -ComponentRoot $C } @($inUseInstall, $inUseEngineRoot))
        $inUseParentAnswer = [bool] (InModule { param($I, $C) Test-FastLlmComponentInUse -InstallRoot $I -ComponentRoot $C } @($inUseInstall, (Join-Path $inUseInstall 'components/embedding-model/emb-q8')))
    }
    finally { $inUseLock.Dispose() }
    Check (@(@('waiting', 'starting', 'checking', 'ready') | Where-Object { -not $inUseAnswers[$_] }).Count -eq 0 -and -not $inUseAnswers['failed'] -and -not $inUseAnswers['stopped']) 'in use: while a sidecar block is waiting, starting, checking or ready, its embedding component is in use; once failed or stopped it is not'
    Check ($inUseEngineAnswer -and -not $inUseOtherAnswer -and $inUseParentAnswer) 'in use: the engine root is still in use as before, another embedding component is not, and the folder of the component itself is'
    $inUseNotActive = [bool] (InModule { param($I, $C) Test-FastLlmComponentInUse -InstallRoot $I -ComponentRoot $C } @($inUseInstall, $inUseRoot))
    Check (-not $inUseNotActive) 'in use: when FastLLM is not running (no operation lock), the component is not in use whatever the last status says'

    # ================= the measured row and the component: the refusals, each typed =================
    $planCode = { param($World, [int] $Port = 0) try { $null = InModule { param($Catalog, $InstallRoot, $Port) Get-FastLlmSidecarPlan -CatalogPath $Catalog -InstallRoot $InstallRoot -Port $Port } @($World.catalog, $World.root, $Port); return 'none' } catch { return ((Get-FailureCode $_.Exception) + '|' + [string] $_.Exception.Data['FastLlmReason'] + '|' + [string] $_.Exception.Message) } }
    # The plan resolver reads the catalog through the module: from here on the catalog is the test world's (engine version "test").
    Install-SidecarTestBoundaries -Module $module -State $st
    $refusals = [ordered] @{
        'no component installed' = @{ Component = 'missing'; Rows = 'good'; Code = 'embeddings-no-model' }
        'a component without a consent receipt' = @{ Component = 'no-consent'; Rows = 'good'; Code = 'embeddings-no-model' }
        'no row at all' = @{ Component = 'installed'; Rows = 'none'; Code = 'embeddings-not-measured' }
        'a row for another engine' = @{ Component = 'installed'; Rows = 'other-engine'; Code = 'embeddings-not-measured' }
        'a row for another model file' = @{ Component = 'installed'; Rows = 'other-sha'; Code = 'embeddings-not-measured' }
        'a row with GPU placement' = @{ Component = 'installed'; Rows = 'gpu'; Code = 'embeddings-gpu-not-offered' }
        'two rows for one model and engine' = @{ Component = 'installed'; Rows = 'duplicate'; Code = 'serving-profiles-invalid' }
    }
    $refusalIndex = 0
    $refusalWorlds = @{}
    foreach ($case in $refusals.Keys) {
        $refusalIndex++
        $world = New-SidecarWorld -Module $module -Root $root -Temp $temp -Label ("refuse-$refusalIndex") -Rows $refusals[$case].Rows -Component $refusals[$case].Component
        $refusalWorlds[$case] = $world
        Use-SidecarWorld -Module $module -State $st -World $world
        $observed = & $planCode $world
        Check ($observed.StartsWith($refusals[$case].Code + '|')) "refusal: $case is $($refusals[$case].Code) ($($observed.Split('|')[0]))"
    }
    $noModelText = (& $planCode $refusalWorlds['no component installed']).Split('|')
    Check ($noModelText[1] -ceq 'EmbeddingsRefused' -and $noModelText[2] -cmatch '^embeddings-no-model: ' -and $noModelText[2].Contains('Nothing was started') -and $noModelText[2].Contains('-Embeddings off')) 'refusal: the text is plain, says nothing was started and how to turn embeddings off; the reason is never one a caller retries'
    Check (((& $planCode $refusalWorlds['no row at all']).Split('|')[2]).Contains('has not been measured') -and ((& $planCode $refusalWorlds['a row with GPU placement']).Split('|')[2]).Contains('GPU')) 'refusal: not measured and GPU placement each say so in plain words'
    $goodWorld = New-SidecarWorld -Module $module -Root $root -Temp $temp -Label 'plan-good'
    Use-SidecarWorld -Module $module -State $st -World $goodWorld
    Check ((& $planCode $goodWorld 8081) -ceq 'none' -and (& $planCode $goodWorld 0) -ceq 'none') 'plan: an installed, consented component with a row for this engine is planned (port 0 is the default port)'
    foreach ($badPort in @(80, 1023, 65536, -1)) { Check ((& $planCode $goodWorld $badPort).StartsWith('embeddings-port-invalid|')) "plan: port $badPort is refused as embeddings-port-invalid" }
    $defaultPlan = InModule { param($Catalog, $InstallRoot) Get-FastLlmSidecarPlan -CatalogPath $Catalog -InstallRoot $InstallRoot } @($goodWorld.catalog, $goodWorld.root)
    Check ([int] $defaultPlan.port -eq 8081 -and [string] $defaultPlan.endpoint -ceq 'http://127.0.0.1:8081/v1' -and [string] $defaultPlan.engineId -ceq 'llama.cpp-test-vulkan' -and [string] $defaultPlan.backend -ceq 'vulkan' -and [string] $defaultPlan.placement -ceq 'cpu') 'plan: the default port is 8081, and the engine is the built-in Vulkan engine with CPU placement'
    Check (@($st.events | Where-Object { $_ -clike 'hash:*' }).Count -eq 0) 'plan: nothing is hashed while the option is checked (the model file is hashed when the sidecar starts, once for each process)'
    # Nothing is derived from a file size: a model file of another size is simply not the installed component.
    [IO.File]::WriteAllBytes($goodWorld.modelFile, (New-Object byte[] 4096))
    Check ((& $planCode $goodWorld).StartsWith('embeddings-no-model|')) 'plan: a model file of another size is not the installed component (embeddings-no-model); no fit is derived from a size'

    # ================= the client waits at least as long as the product may take =================
    # A client step waits for a status condition. The product is allowed the text model's load timeout, then the sidecar's own load timeout
    # (read from the module) and the sidecar's canary request (30 s, the timeout in FastLlm.Sidecar.ps1); a client that gives up sooner judges
    # faster than the product does, which fails a scenario the product was still inside its budgets for (a timing race under load).
    $sidecarLoadSeconds = [int] (InModule { $script:FastLlmSidecarLoadTimeoutSeconds })
    $canarySeconds = 30
    $stepMarginSeconds = 60
    $stepBudget = [int] $script:ScenarioLoadTimeoutSeconds + $sidecarLoadSeconds + $canarySeconds + $stepMarginSeconds
    Check ($sidecarLoadSeconds -gt 0 -and [int] $script:StepTimeoutSeconds -ge $stepBudget) "client step wait: $([int] $script:StepTimeoutSeconds) s covers the text load timeout ($([int] $script:ScenarioLoadTimeoutSeconds) s) + the sidecar load timeout ($sidecarLoadSeconds s) + the canary ($canarySeconds s) + a margin ($stepMarginSeconds s) = $stepBudget s"

    # ================= off by default: a start without the option is the start it always was =================
    $offWorld = New-SidecarWorld -Module $module -Root $root -Temp $temp -Label 'default-off'
    Use-SidecarWorld -Module $module -State $st -World $offWorld
    $off = Invoke-SidecarScenario -Label 'default-off' -World $offWorld -NoEmbeddings -Steps @((New-Step @{ phase = 'ready' } 'request'), (New-Step @{ phase = 'ready' } 'stop'))
    Check ($off.completed -and $null -eq $off.failure -and $off.exit -eq 0) 'off: a start without -Embeddings reaches Ready and stops'
    Check ($off.runs.Count -eq 1 -and $off.runs[0].bound -ceq 'CatalogPath,InstallRoot,LoadTimeoutSeconds,Plan') 'off: the supervisor is given exactly the parameters it always was'
    Check (@($off.writes | Where-Object { $_.PSObject.Properties['sidecars'] }).Count -eq 0 -and @($off.observations | Where-Object { $_.hasSidecars }).Count -eq 0) 'off: no status document has a sidecars field'
    Check (@($off.events | Where-Object { $_ -ceq 'sidecar-command' -or $_ -clike 'hash:test-embedding*' }).Count -eq 0 -and @(Read-Control $offWorld 'starts.log').Count -eq 0) 'off: the embedding component is never touched and no second process is started'
    Check (@($off.console | Where-Object { $_ -clike 'Embeddings*' }).Count -eq 0 -and @(Get-AllRunLogs $offWorld | Where-Object { [string] $_.event -clike 'sidecar*' }).Count -eq 0) 'off: the console and the run log say nothing about embeddings'
    Check (Test-PortFree $offWorld.embeddingPort) 'off: nothing listens on the embedding port'

    # ================= on: the sidecar starts only after the text model is Ready, and Ready is what it always was =================
    $markerEnvironment = @{ LLAMA_ARG_HOST = '0.0.0.0'; LLAMA_ARG_PORT = '9'; LLAMA_ARG_EMBEDDINGS = '0'; LLAMA_API_KEY = 'inherited-not-a-key'; GGML_TEST_OVERRIDE = '1'; HF_TOKEN = 'inherited' }
    $savedEnvironment = @{}
    foreach ($name in $markerEnvironment.Keys) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, $markerEnvironment[$name]) }
    [IO.File]::WriteAllText((Join-Path $offWorld.control 'mode'), 'marker-ok')
    Use-SidecarWorld -Module $module -State $st -World $offWorld
    $embedBody = '{"model":"test-embedding-model-q8","input":"' + $documentMarker + ' a private document"}'
    try { $on = Invoke-SidecarScenario -Label 'on' -World $offWorld -Steps @((New-Step @{ phase = 'ready'; sidecarPhase = 'ready' } 'request' @{ embedBody = $embedBody }), (New-Step @{ phase = 'ready' } 'stop')) }
    finally { foreach ($name in $markerEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name]) } }
    Check ($on.completed -and $null -eq $on.failure -and $on.exit -eq 0) 'on: a start with embeddings on reaches Ready, the sidecar becomes ready, and a stop ends it cleanly'
    Check ($on.runs.Count -eq 1 -and $on.runs[0].bound -ceq 'CatalogPath,InstallRoot,LoadTimeoutSeconds,Plan,SidecarSession') 'on: the supervisor is given one more parameter, the session''s sidecar'
    $firstReady = [Array]::IndexOf($on.events, 'write:ready:waiting')
    $modelHash = [Array]::IndexOf($on.events, 'hash:test-embedding-model-q8')
    $spawn = [Array]::IndexOf($on.events, 'sidecar-command')
    Check ($firstReady -ge 0 -and $modelHash -gt $firstReady -and $spawn -gt $modelHash) 'order: the text model is written Ready first; only then is the embedding model hashed, and only then is the sidecar process started'
    $beforeReady = @($on.events | Select-Object -First $firstReady)
    Check (@($beforeReady | Where-Object { $_ -ceq 'sidecar-command' -or $_ -clike 'hash:test-embedding*' }).Count -eq 0 -and @($beforeReady | Where-Object { $_ -clike 'write:*' -and $_ -cnotlike 'write:*:waiting' }).Count -eq 0) 'order: until Ready the sidecar block says waiting and nothing of the sidecar has run'
    $offUntilReady = @(); foreach ($document in $off.writes) { $offUntilReady += (ConvertTo-ComparableStatus $document); if ([string] $document.phase -ceq 'ready') { break } }
    $onUntilReady = @(); foreach ($document in $on.writes) { $onUntilReady += (ConvertTo-ComparableStatus $document); if ([string] $document.phase -ceq 'ready') { break } }
    $sameUntilReady = ($offUntilReady.Count -eq $onUntilReady.Count -and $offUntilReady.Count -ge 3)
    for ($k = 0; $sameUntilReady -and $k -lt $offUntilReady.Count; $k++) { if (-not ($offUntilReady[$k] -ceq $onUntilReady[$k])) {
            $sameUntilReady = $false
            $at = 0; while ($at -lt $offUntilReady[$k].Length -and $at -lt $onUntilReady[$k].Length -and $offUntilReady[$k][$at] -ceq $onUntilReady[$k][$at]) { $at++ }
            $from = [Math]::Max(0, $at - 60)
            Write-Host "DIFF status write $k at character $at`n off: $($offUntilReady[$k].Substring($from, [Math]::Min(200, $offUntilReady[$k].Length - $from)))`n on:  $($onUntilReady[$k].Substring($from, [Math]::Min(200, $onUntilReady[$k].Length - $from)))"
        }
    }
    Check $sameUntilReady "text status: with embeddings on, every status document up to and including Ready equals the one without it, sidecars block aside ($($offUntilReady.Count) documents)"
    Check (@($on.writes | Where-Object { @('loading', 'checking', 'ready', 'stopped') -cnotcontains [string] $_.phase }).Count -eq 0 -and @($on.writes | Where-Object { $null -ne $_.failureCode }).Count -eq 0) 'text status: the top-level phase stays the text model''s, and it never carries a failure'
    Check (@($on.writes | Where-Object { @(Get-Field $_ 'sidecars').Count -ne 1 }).Count -eq 0) 'status: every document of a start with embeddings on has exactly one sidecar block'
    $phasesSeen = @(); foreach ($document in $on.writes) { $phase = [string] (Get-Sidecar $document).phase; if ($phasesSeen.Count -eq 0 -or $phasesSeen[$phasesSeen.Count - 1] -cne $phase) { $phasesSeen += $phase } }
    Check (($phasesSeen -join '>') -ceq 'waiting>starting>checking>ready>stopped') "status: the sidecar block goes waiting, starting, checking, ready, stopped ($($phasesSeen -join '>'))"
    $readyDocument = @($on.writes | Where-Object { [string] (Get-Sidecar $_).phase -ceq 'ready' })[0]
    $readyBlock = Get-Sidecar $readyDocument
    Check ((@($readyBlock.PSObject.Properties.Name) -join ',') -ceq 'role,componentId,endpoint,phase,processIdentity,placement,canary') 'status: a ready block has exactly role, componentId, endpoint, phase, processIdentity, placement and canary'
    Check ($readyBlock.role -ceq 'embedding' -and $readyBlock.componentId -ceq 'test-embedding-model-q8' -and $readyBlock.endpoint -ceq "http://127.0.0.1:$($offWorld.embeddingPort)/v1" -and $readyBlock.placement -ceq 'cpu') 'status: role embedding, the component id, the loopback endpoint on the embedding port and CPU placement'
    Check ((@($readyBlock.canary.PSObject.Properties.Name) -join ',') -ceq 'ok,dimension' -and $readyBlock.canary.ok -eq $true -and [int] $readyBlock.canary.dimension -eq 1024) 'status: the canary block holds only its verdict and the dimension (1024)'
    $sidecarPid = [int] $readyBlock.processIdentity.pid
    $textPid = [int] $readyDocument.processIdentity.pid
    Check ($sidecarPid -gt 0 -and [long] $readyBlock.processIdentity.startUtcTicks -gt 0 -and $sidecarPid -ne $textPid -and [string] @(Read-Control $offWorld 'pid')[0] -ceq [string] $sidecarPid) 'status: the block names the sidecar''s own process (not the text server''s), the one the mock engine ran as'
    Check (@(Read-Control $offWorld 'starts.log').Count -eq 1) 'lifecycle: the sidecar was started exactly once'
    $recordedArguments = @(Read-Control $offWorld 'argv.txt')
    $expectedArguments = @(InModule { param($Model, $Port) Get-FastLlmSidecarArguments -ModelPath $Model -Alias 'test-embedding-model-q8' -Port $Port -ContextSize 8192 -Pooling 'last' } @($offWorld.modelFile, [int] $offWorld.embeddingPort))
    Check (($recordedArguments -join "`n") -ceq ($expectedArguments -join "`n")) 'arguments: the engine process received exactly the built arguments'
    $environmentSeen = @(Read-Control $offWorld 'env.txt')
    Check ($environmentSeen -ccontains 'key-absent' -and @($environmentSeen | Where-Object { $_ -clike 'name *' }).Count -eq 0) "environment: an inherited LLAMA_ARG_HOST, LLAMA_ARG_PORT, LLAMA_ARG_EMBEDDINGS, LLAMA_API_KEY, GGML_* or HF_TOKEN never reaches the sidecar ($(@($environmentSeen | Where-Object { $_ -clike 'name *' }) -join ','))"
    Check ($environmentSeen -ccontains 'sandbox APPDATA empty' -and $environmentSeen -ccontains 'sandbox PROGRAMDATA empty') 'environment: the sidecar gets its own empty configuration roots'
    $request = Get-StepOutcome $on 'request'
    Check (@(Read-Control $offWorld 'listening')[0] -ceq "127.0.0.1:$($offWorld.embeddingPort)" -and [string] $request.sidecarListeners -ceq '127.0.0.1') "loopback: the sidecar listens on 127.0.0.1 and on no other address, although the inherited environment asked for 0.0.0.0 ($($request.sidecarListeners))"
    Check ([int] $request.textHealth -eq 200 -and [int] $request.textModels -eq 200 -and [int] $request.sidecarHealth -eq 200 -and [int] $request.sidecarEmbed -eq 200) 'serving: the text server answers on its port and the sidecar answers an embedding request on its own'
    Check ((Wait-ProcessGone $textPid) -and (Wait-ProcessGone $sidecarPid) -and (Wait-PortFree $offWorld.port) -and (Wait-PortFree $offWorld.embeddingPort)) 'stop: a stop ends both processes and frees both ports'
    $finalBlock = Get-Sidecar $on.final
    Check ($on.final.phase -ceq 'stopped' -and $on.final.stopReason -ceq 'user' -and $finalBlock.phase -ceq 'stopped' -and [int] $finalBlock.processIdentity.pid -eq $sidecarPid -and -not $finalBlock.PSObject.Properties['failureCode']) 'stop: the final document says stopped for the text model and for the sidecar, with no failure code'
    $onLog = @(Get-RunLog $offWorld ([string] $on.final.runId))
    $logNames = @($onLog | ForEach-Object { [string] $_.event })
    $readyLine = -1; for ($k = 0; $k -lt $onLog.Count; $k++) { if ($logNames[$k] -ceq 'phase' -and [string] $onLog[$k].phase -ceq 'ready') { $readyLine = $k; break } }
    Check ($readyLine -ge 0 -and [Array]::IndexOf($logNames, 'sidecar-start') -gt $readyLine -and @($logNames | Select-Object -First $readyLine | Where-Object { $_ -clike 'sidecar*' }).Count -eq 0) 'run log: the first sidecar line comes after the Ready line'
    $startLine = @(Get-LogEvents $onLog 'sidecar-start')
    Check ($startLine.Count -eq 1 -and $startLine[0].role -ceq 'embedding' -and $startLine[0].componentId -ceq 'test-embedding-model-q8' -and [int] $startLine[0].port -eq [int] $offWorld.embeddingPort -and $startLine[0].placement -ceq 'cpu') 'run log: sidecar-start names the role, the component id, the port and the placement'
    $placementLine = @(Get-LogEvents $onLog 'sidecar-placement')
    Check ($placementLine.Count -eq 1 -and [int] $placementLine[0].offloadLines -eq 1 -and [int] $placementLine[0].offloadedLayers -eq 0 -and [int] $placementLine[0].gpuBufferLines -eq 0 -and [int] $placementLine[0].cpuBufferLines -eq 1) 'run log: sidecar-placement records what the engine printed (one offload line with 0 layers, no GPU buffer, one CPU buffer)'
    $canaryLine = @(Get-LogEvents $onLog 'sidecar-canary')
    Check ($canaryLine.Count -eq 1 -and $canaryLine[0].ok -eq $true -and [int] $canaryLine[0].dimension -eq 1024) 'run log: sidecar-canary holds the verdict and the dimension'
    Check ((@(Get-LogEvents $onLog 'sidecar-phase' | ForEach-Object { [string] $_.phase }) -join '>') -ceq 'ready>stopped') 'run log: sidecar-phase says ready, then stopped'
    $allowedLogFields = @{ 'sidecar-start' = @('role', 'componentId', 'port', 'placement'); 'sidecar-placement' = @('role', 'offloadLines', 'offloadedLayers', 'totalLayers', 'gpuBufferLines', 'cpuBufferLines'); 'sidecar-canary' = @('role', 'ok', 'dimension'); 'sidecar-phase' = @('role', 'phase', 'failureCode'); 'sidecar-idle-check-failed' = @('role') }
    $strayFields = @()
    foreach ($line in @($onLog | Where-Object { [string] $_.event -clike 'sidecar*' })) { foreach ($name in @($line.PSObject.Properties.Name)) { if (@('ts', 'runId', 'event') -cnotcontains $name -and $allowedLogFields[[string] $line.event] -cnotcontains $name) { $strayFields += "$($line.event).$name" } } }
    Check ($strayFields.Count -eq 0) "run log: a sidecar line holds only ids, numbers, codes and closed words ($($strayFields -join ','))"
    # Privacy: the mock engine printed every request and response (the canary's and the app's) as a verbose server would.
    $canaryText = InModule { $script:FastLlmSidecarCanaryText }
    Check ($canaryText.Length -gt 20 -and (InModule { (Get-Variable -Name FastLlmSidecarCanaryText -Scope Script).Value }) -ceq $canaryText) 'privacy: the canary text is a fixed built-in constant'
    $privacyHits = @(Find-WordsInFiles $offWorld.root @($documentMarker, $canaryText, $vectorMarker, 'private document'))
    Check ($privacyHits.Count -eq 0) "privacy: no request text, document or vector is in any file FastLLM wrote: status, run logs, state ($($privacyHits -join '; '))"
    $consoleText = ($on.console -join "`n")
    Check ($consoleText.IndexOf($documentMarker, [StringComparison]::Ordinal) -lt 0 -and $consoleText.IndexOf($canaryText, [StringComparison]::Ordinal) -lt 0 -and $consoleText.IndexOf($vectorMarker, [StringComparison]::Ordinal) -lt 0) 'privacy: the console shows no request text, document or vector'
    $readyConsole = -1; $embeddingsConsole = -1
    for ($k = 0; $k -lt $on.console.Count; $k++) { if ($readyConsole -lt 0 -and $on.console[$k] -clike 'Ready: *') { $readyConsole = $k }; if ($embeddingsConsole -lt 0 -and $on.console[$k] -clike 'Embeddings*') { $embeddingsConsole = $k } }
    $offReadyLines = @($off.console | Where-Object { $_ -clike 'Ready: *' })
    Check ($readyConsole -ge 0 -and $embeddingsConsole -gt $readyConsole -and $offReadyLines.Count -eq 1 -and $on.console[$readyConsole] -ceq $offReadyLines[0]) 'console: the Ready line is the one it always was, and the first Embeddings line comes after it'
    Check (@($on.console | Where-Object { $_ -ceq "Embeddings: ready at http://127.0.0.1:$($offWorld.embeddingPort)/v1 (model 'test-embedding-model-q8', 1024 dimensions, on the CPU)." }).Count -eq 1) 'console: one line says the embeddings endpoint is ready, with its address, model name and dimension'
    # Connect an app reads the same status document.
    $readyDocument | Add-Member -NotePropertyName active -NotePropertyValue $true -Force
    $connection = Get-FastLlmConnectionInfo -Status $readyDocument
    Check ($connection.PSObject.Properties['embeddings'] -and $connection.embeddings.baseUrl -ceq "http://127.0.0.1:$($offWorld.embeddingPort)/v1" -and $connection.embeddings.path -ceq '/v1/embeddings' -and $connection.embeddings.modelName -ceq 'test-embedding-model-q8') 'connect an app: the ready status gives a /v1/embeddings row with the sidecar''s own base URL'
    $on.final | Add-Member -NotePropertyName active -NotePropertyValue $false -Force
    Check (-not (Get-FastLlmConnectionInfo -Status $on.final).PSObject.Properties['embeddings']) 'connect an app: after the stop there is no embeddings row'

    # ================= a sidecar failure never fails, stops or degrades the text model; it is recorded with a typed code; no retry =================
    InModule { $script:FastLlmSidecarLoadTimeoutSeconds = 4 }
    $failureCases = [ordered] @{
        'exit' = @{ Code = 'embeddings-server-exited'; What = 'a sidecar that exits at once (a start failure)' }
        'nohealth' = @{ Code = 'embeddings-load-timeout'; What = 'a sidecar that never becomes healthy' }
        'gpu-layers' = @{ Code = 'embeddings-placement-not-cpu'; What = 'a sidecar whose model went to a GPU' }
        'silent' = @{ Code = 'embeddings-placement-not-cpu'; What = 'a sidecar that prints no placement line at all (nothing shows the CPU)' }
        'gpu-odd' = @{ Code = 'embeddings-placement-not-cpu'; What = 'a CPU placement together with GPU lines in a shape the parse does not know' }
        'dimension-wrong' = @{ Code = 'embeddings-canary-failed'; What = 'a vector of another dimension than the row''s' }
        'unstable' = @{ Code = 'embeddings-canary-failed'; What = 'the same text giving two different vectors' }
        'models-wrong' = @{ Code = 'embeddings-canary-failed'; What = 'a served model name that is not the component' }
        'embed-500' = @{ Code = 'embeddings-canary-failed'; What = 'an embedding request that fails' }
        'zero-vector' = @{ Code = 'embeddings-canary-failed'; What = 'a vector of zeros' }
    }
    foreach ($mode in $failureCases.Keys) {
        $case = $failureCases[$mode]
        $world = New-SidecarWorld -Module $module -Root $root -Temp $temp -Label ("fail-$mode") -SidecarMode $mode
        Use-SidecarWorld -Module $module -State $st -World $world
        $failedRun = Invoke-SidecarScenario -Label "fail-$mode" -World $world -Steps @((New-Step @{ phase = 'ready'; sidecarPhase = 'failed' } 'sleep' @{ milliseconds = 1500 }), (New-Step @{ phase = 'ready'; sidecarPhase = 'failed' } 'request'), (New-Step @{ phase = 'ready' } 'stop'))
        $failedDocument = @($failedRun.writes | Where-Object { [string] (Get-Sidecar $_).phase -ceq 'failed' })[0]
        # A sidecar that never failed leaves nothing to examine: that is the failure of this case, not a reason to end the suite.
        if ($null -eq $failedDocument) { Check $false "failure ($mode): the sidecar block turned failed with $($case.Code) (no status document ever said failed)"; continue }
        $failedBlock = Get-Sidecar $failedDocument
        Check ($failedRun.completed -and $null -eq $failedRun.failure -and $failedRun.exit -eq 0 -and $failedBlock.failureCode -ceq $case.Code) "failure ($mode): $($case.What) is recorded in the sidecar block as $($case.Code), and the start itself ends cleanly at the stop"
        $failedRequest = Get-StepOutcome $failedRun 'request'
        Check ($failedDocument.phase -ceq 'ready' -and $null -eq $failedDocument.failureCode -and [int] $failedRequest.textHealth -eq 200 -and [int] $failedRequest.textModels -eq 200 -and @($failedRun.writes | Where-Object { [string] $_.phase -ceq 'failed' }).Count -eq 0) "failure ($mode): the text model stays Ready and keeps answering"
        $failedPid = 0; if ($null -ne $failedBlock.processIdentity) { $failedPid = [int] $failedBlock.processIdentity.pid }
        Check (@(Read-Control $world 'starts.log').Count -eq 1 -and -not (Test-ProcessAlive $failedPid) -and [int] $failedRequest.sidecarHealth -eq 0 -and (Test-PortFree $world.embeddingPort)) "failure ($mode): the sidecar is not started again (one start), its process is gone and its port is free"
        $failedCanary = $failedBlock.canary
        if ($case.Code -ceq 'embeddings-canary-failed') { Check ($null -ne $failedCanary -and $failedCanary.ok -eq $false -and (@($failedCanary.PSObject.Properties.Name) -join ',') -ceq 'ok,dimension') "failure ($mode): the canary block says not ok and holds nothing but the verdict and a dimension" }
        else { Check ($null -eq $failedCanary) "failure ($mode): no canary ran, so the block has none" }
        Check (@($failedRun.console | Where-Object { $_ -clike "Embeddings: not available ($($case.Code)).*" -and $_.Contains('The model keeps running') }).Count -eq 1) "failure ($mode): one console line names the code and says the model keeps running"
        $failedLog = @(Get-LogEvents (Get-RunLog $world ([string] $failedRun.final.runId)) 'sidecar-phase')
        Check ($failedLog.Count -eq 1 -and $failedLog[0].phase -ceq 'failed' -and $failedLog[0].failureCode -ceq $case.Code) "failure ($mode): the run log has one sidecar-phase line, failed, with the code"
        Check ((Get-Sidecar $failedRun.final).phase -ceq 'failed' -and (Get-Sidecar $failedRun.final).failureCode -ceq $case.Code -and $failedRun.final.phase -ceq 'stopped') "failure ($mode): the final document keeps the sidecar's failure next to the text model's clean stop"
        $failedDocument | Add-Member -NotePropertyName active -NotePropertyValue $true -Force
        Check (-not (Get-FastLlmConnectionInfo -Status $failedDocument).PSObject.Properties['embeddings']) "failure ($mode): Connect an app shows no embeddings row"
    }
    $dimensionDocument = @((Get-Content -LiteralPath (Join-Path (Join-Path $temp 'fail-dimension-wrong') 'state/status.json') -Raw | ConvertFrom-Json))[0]
    Check ([int] (Get-Sidecar $dimensionDocument).canary.dimension -eq 1025) 'failure (dimension-wrong): the dimension that was seen (1025) is recorded'
    InModule { $script:FastLlmSidecarLoadTimeoutSeconds = 300 }

    # A CPU load that also prints the CPU backend's repack buffer line is still a CPU placement.
    $repackWorld = New-SidecarWorld -Module $module -Root $root -Temp $temp -Label 'cpu-repack' -SidecarMode 'cpu-repack'
    Use-SidecarWorld -Module $module -State $st -World $repackWorld
    $repack = Invoke-SidecarScenario -Label 'cpu-repack' -World $repackWorld -Steps @((New-Step @{ phase = 'ready'; sidecarPhase = 'ready' } 'request' @{ embedBody = '{"input":"x"}' }), (New-Step @{ phase = 'ready' } 'stop'))
    Check ($repack.completed -and $repack.exit -eq 0 -and [int] (Get-StepOutcome $repack 'request').sidecarEmbed -eq 200 -and (Get-Sidecar $repack.final).phase -ceq 'stopped' -and @($repack.writes | Where-Object { [string] (Get-Sidecar $_).phase -ceq 'ready' }).Count -ge 1) 'placement: a CPU load that also prints a CPU_REPACK buffer line reaches ready (it is the one buffer line of a CPU load that the placement capture does not keep)'

    # A model file that fails its hash, and an engine that fails its file check: found when the sidecar starts, after Ready; never started.
    foreach ($broken in @(@{ Label = 'corrupt-model'; Component = 'corrupt'; EngineFailFrom = 0; Code = 'embeddings-model-invalid' }, @{ Label = 'engine-check'; Component = 'installed'; EngineFailFrom = 2; Code = 'embeddings-engine-unavailable' })) {
        $world = New-SidecarWorld -Module $module -Root $root -Temp $temp -Label $broken.Label -Component $broken.Component
        Use-SidecarWorld -Module $module -State $st -World $world
        $st.engineFailFrom = [int] $broken.EngineFailFrom
        $brokenRun = Invoke-SidecarScenario -Label $broken.Label -World $world -Steps @((New-Step @{ phase = 'ready'; sidecarPhase = 'failed' } 'request'), (New-Step @{ phase = 'ready' } 'stop'))
        $st.engineFailFrom = 0
        Check ($brokenRun.completed -and $brokenRun.exit -eq 0 -and (Get-Sidecar $brokenRun.final).failureCode -ceq $broken.Code -and [int] (Get-StepOutcome $brokenRun 'request').textModels -eq 200) "verification ($($broken.Label)): $($broken.Code) fails the sidecar only; the text model serves"
        Check (@(Read-Control $world 'starts.log').Count -eq 0 -and $brokenRun.events -cnotcontains 'sidecar-command') "verification ($($broken.Label)): no sidecar process was started"
    }

    # ================= a sidecar that crashes later: its block turns failed, the text model serves, Connect an app drops the row =================
    $crashWorld = New-SidecarWorld -Module $module -Root $root -Temp $temp -Label 'crash'
    Use-SidecarWorld -Module $module -State $st -World $crashWorld
    $crash = Invoke-SidecarScenario -Label 'crash' -World $crashWorld -Steps @((New-Step @{ phase = 'ready'; sidecarPhase = 'ready' } 'kill-sidecar'), (New-Step @{ phase = 'ready'; sidecarPhase = 'failed' } 'sleep' @{ milliseconds = 1500 }), (New-Step @{ phase = 'ready'; sidecarPhase = 'failed' } 'request'), (New-Step @{ phase = 'ready' } 'stop'))
    $crashBlock = Get-Sidecar $crash.final
    $crashRequest = Get-StepOutcome $crash 'request'
    Check ($crash.completed -and $null -eq $crash.failure -and $crash.exit -eq 0 -and $crashBlock.phase -ceq 'failed' -and $crashBlock.failureCode -ceq 'embeddings-server-exited') 'crash: a sidecar that ends while serving turns its block to failed (embeddings-server-exited)'
    Check ([int] $crashRequest.textHealth -eq 200 -and [int] $crashRequest.textModels -eq 200 -and @($crash.writes | Where-Object { [string] $_.phase -ceq 'failed' }).Count -eq 0) 'crash: the text model stays Ready and keeps answering'
    Check (@(Read-Control $crashWorld 'starts.log').Count -eq 1 -and (Test-PortFree $crashWorld.embeddingPort)) 'crash: the sidecar is not started again'
    $crashReady = @($crash.writes | Where-Object { [string] (Get-Sidecar $_).phase -ceq 'ready' })[0]
    $crashFailed = @($crash.writes | Where-Object { [string] (Get-Sidecar $_).phase -ceq 'failed' })[0]
    $crashReady | Add-Member -NotePropertyName active -NotePropertyValue $true -Force
    $crashFailed | Add-Member -NotePropertyName active -NotePropertyValue $true -Force
    Check ((Get-FastLlmConnectionInfo -Status $crashReady).PSObject.Properties['embeddings'] -and -not (Get-FastLlmConnectionInfo -Status $crashFailed).PSObject.Properties['embeddings']) 'crash: Connect an app had the embeddings row while the sidecar was ready and drops it once the block is failed'
    Check ((Get-Sidecar $crashFailed).canary.ok -eq $true -and [int] (Get-Sidecar $crashFailed).processIdentity.pid -eq [int] (Get-StepOutcome $crash 'kill-sidecar').killedPid) 'crash: the failed block still names the process that ended'

    # The text server ends while both serve: the run fails as it always did, and the sidecar is stopped with it.
    $textCrashWorld = New-SidecarWorld -Module $module -Root $root -Temp $temp -Label 'text-crash'
    Use-SidecarWorld -Module $module -State $st -World $textCrashWorld
    $textCrash = Invoke-SidecarScenario -Label 'text-crash' -World $textCrashWorld -Steps @((New-Step @{ phase = 'ready'; sidecarPhase = 'ready' } 'kill-text'))
    $textCrashPid = [int] (@($textCrash.observations | Where-Object { [int] $_.sidecarPid -gt 0 })[0].sidecarPid)
    Check ($null -ne $textCrash.failure -and $textCrash.final.phase -ceq 'failed' -and (Get-Sidecar $textCrash.final).phase -ceq 'stopped' -and (Wait-ProcessGone $textCrashPid) -and (Wait-PortFree $textCrashWorld.embeddingPort)) 'supervisor exit: when the text server ends, the run fails as it always did and the sidecar is stopped too'

    # ================= the port: a clash refuses the sidecar only =================
    $clashWorld = New-SidecarWorld -Module $module -Root $root -Temp $temp -Label 'port-clash'
    Use-SidecarWorld -Module $module -State $st -World $clashWorld
    $occupier = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, [int] $clashWorld.embeddingPort)
    $occupier.Start()
    try { $clash = Invoke-SidecarScenario -Label 'port-clash' -World $clashWorld -Steps @((New-Step @{ phase = 'ready'; sidecarPhase = 'failed' } 'request'), (New-Step @{ phase = 'ready' } 'stop')) }
    finally { $occupier.Stop() }
    Check ($clash.completed -and $null -eq $clash.failure -and $clash.exit -eq 0 -and (Get-Sidecar $clash.final).failureCode -ceq 'embeddings-port-in-use') 'port: an occupied embedding port refuses the sidecar with embeddings-port-in-use'
    Check ([int] (Get-StepOutcome $clash 'request').textModels -eq 200 -and @(Read-Control $clashWorld 'starts.log').Count -eq 0 -and $clash.events -cnotcontains 'sidecar-command' -and $null -eq (Get-Sidecar $clash.final).processIdentity) 'port: the text model serves, and no sidecar process was started'
    Check (@($clash.console | Where-Object { $_ -clike 'Embeddings: not available (embeddings-port-in-use).*' -and $_.Contains([string] $clashWorld.embeddingPort) -and $_.Contains('-EmbeddingPort') }).Count -eq 1) 'port: the console line names the port and how to choose another'
    $sameWorld = New-SidecarWorld -Module $module -Root $root -Temp $temp -Label 'port-same'
    Use-SidecarWorld -Module $module -State $st -World $sameWorld
    $same = Invoke-SidecarScenario -Label 'port-same' -World $sameWorld -StartOptions @{ EmbeddingPort = [int] $sameWorld.port } -Steps @((New-Step @{ phase = 'ready'; sidecarPhase = 'failed' } 'request'), (New-Step @{ phase = 'ready' } 'stop'))
    Check ($same.completed -and $same.exit -eq 0 -and (Get-Sidecar $same.final).failureCode -ceq 'embeddings-port-in-use' -and [int] (Get-StepOutcome $same 'request').textModels -eq 200 -and @(Read-Control $sameWorld 'starts.log').Count -eq 0) 'port: an embedding port equal to the model''s own port refuses the sidecar only, with the same code'

    # ================= the refusals at the start: nothing is started =================
    foreach ($case in @('no component installed', 'no row at all', 'a row with GPU placement')) {
        $world = $refusalWorlds[$case]
        Use-SidecarWorld -Module $module -State $st -World $world
        $refused = Invoke-SidecarScenario -Label ("start-refused-" + $refusals[$case].Code) -World $world -Steps @()
        Check ((Get-FailureCode $refused.failure) -ceq $refusals[$case].Code -and [string] $refused.failure.Data['FastLlmReason'] -ceq 'EmbeddingsRefused') "start refusal: with $case, -Embeddings on is refused as $($refusals[$case].Code)"
        Check (@($refused.events | Where-Object { $_ -clike 'supervisor:*' -or $_ -ceq 'inventory' -or $_ -clike 'write:*' }).Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $world.state 'status.json')) -and (Test-PortFree $world.port) -and (Test-PortFree $world.embeddingPort)) "start refusal ($($refusals[$case].Code)): nothing was probed, written or started"
    }
    # The same PC without the option starts as it always did.
    $world = $refusalWorlds['no component installed']
    Use-SidecarWorld -Module $module -State $st -World $world
    $withoutOption = Invoke-SidecarScenario -Label 'no-component-off' -World $world -NoEmbeddings -Steps @((New-Step @{ phase = 'ready' } 'stop'))
    Check ($withoutOption.completed -and $withoutOption.exit -eq 0 -and $null -eq $withoutOption.failure) 'start refusal: with no embedding component installed, a start WITHOUT the option is unaffected'

    # ================= a switch and a restore keep the sidecar running, with the same process identity =================
    # model-a: its first start serves, every later start fails. model-b always serves. So: a serves; switch to b (ok); switch back to a
    # (the target fails), and b is restored.
    $switchWorld = New-SidecarWorld -Module $module -Root $root -Temp $temp -Label 'switch' -Modes @{ 'model-a' = @('ok', 'exit') }
    Use-SidecarWorld -Module $module -State $st -World $switchWorld
    $switchRun = Invoke-SidecarScenario -Label 'switch' -World $switchWorld -StartOptions @{ AllowSwitch = $true } -Steps @(
        (New-Step @{ phase = 'ready'; modelId = 'model-a'; sidecarPhase = 'ready' } 'switch' @{ modelId = 'model-b' }),
        (New-Step @{ phase = 'ready'; modelId = 'model-b'; switchResult = 'ok' } 'request' @{ embedBody = '{"input":"after the switch"}' }),
        (New-Step @{ phase = 'ready'; modelId = 'model-b'; switchResult = 'ok' } 'switch' @{ modelId = 'model-a' }),
        (New-Step @{ phase = 'ready'; modelId = 'model-b'; switchResult = 'failed-restored' } 'request' @{ embedBody = '{"input":"after the restore"}' }),
        (New-Step @{ phase = 'ready'; modelId = 'model-b' } 'stop'))
    Check ($switchRun.completed -and $null -eq $switchRun.failure -and $switchRun.exit -eq 0 -and $switchRun.runs.Count -eq 4) "switch: a switch (ok) and a failed switch with its restore ran as four supervised runs ($($switchRun.runs.Count))"
    Check ((@($switchRun.runs | ForEach-Object { $_.modelId }) -join ',') -ceq 'model-a,model-b,model-a,model-b' -and @($switchRun.runs | Where-Object { $_.bound -cnotmatch '(^|,)SidecarSession(,|$)' }).Count -eq 0) 'switch: every run of the sequence was given the same session''s sidecar'
    $identities = @($switchRun.observations | Where-Object { [int] $_.sidecarPid -gt 0 } | ForEach-Object { "$($_.sidecarPid)/$($_.sidecarTicks)" } | Select-Object -Unique)
    Check ($identities.Count -eq 1 -and @(Read-Control $switchWorld 'starts.log').Count -eq 1) "switch: across the switch and the restore the sidecar is one process with one identity, started once ($($identities -join ' '))"
    $firstSidecarReady = -1; for ($k = 0; $k -lt $switchRun.observations.Count; $k++) { if ([string] $switchRun.observations[$k].sidecarPhase -ceq 'ready') { $firstSidecarReady = $k; break } }
    $lastServing = -1; for ($k = 0; $k -lt $switchRun.observations.Count; $k++) { if ([string] $switchRun.observations[$k].phase -ceq 'ready' -and [string] $switchRun.observations[$k].modelId -ceq 'model-b') { $lastServing = $k } }
    $between = @($switchRun.observations[$firstSidecarReady..$lastServing])
    Check ($firstSidecarReady -ge 0 -and $lastServing -gt $firstSidecarReady -and @($between | Where-Object { [string] $_.sidecarPhase -cne 'ready' }).Count -eq 0 -and @($between | Where-Object { [string] $_.phase -ceq 'loading' }).Count -ge 2) 'switch: from the moment it is ready until the stop, through both model loads, every status document says the sidecar is ready'
    Check ([int] (Get-StepOutcome $switchRun 'request' 0).sidecarEmbed -eq 200 -and [int] (Get-StepOutcome $switchRun 'request' 1).sidecarEmbed -eq 200 -and [int] (Get-StepOutcome $switchRun 'request' 1).textModels -eq 200) 'switch: the sidecar answers embedding requests after the switch and after the restore'
    $runFinals = @($switchRun.runs | ForEach-Object { $_.finalText | ConvertFrom-Json })
    Check ($runFinals[0].stopReason -ceq 'switch' -and (Get-Sidecar $runFinals[0]).phase -ceq 'ready' -and $runFinals[2].phase -ceq 'failed' -and (Get-Sidecar $runFinals[2]).phase -ceq 'ready') 'switch: the run that ends for a switch, and the target that fails before the restore, leave the sidecar ready'
    Check ((Get-Sidecar $switchRun.final).phase -ceq 'stopped' -and (Wait-ProcessGone ([int] $identities[0].Split('/')[0])) -and (Wait-PortFree $switchWorld.embeddingPort) -and (Wait-PortFree $switchWorld.port)) 'switch: the stop at the end stops both'
    $switchLogs = @(Get-AllRunLogs $switchWorld)
    Check (@(Get-LogEvents $switchLogs 'sidecar-start').Count -eq 1 -and @(Get-LogEvents $switchLogs 'sidecar-canary').Count -eq 1) 'switch: the sidecar was started and checked once in the whole session'

    # A switch whose target fails and whose restore fails too (failed-stopped) stops both.
    $stoppedWorld = New-SidecarWorld -Module $module -Root $root -Temp $temp -Label 'failed-stopped' -Modes @{ 'model-a' = @('ok', 'exit'); 'model-b' = @('exit') }
    Use-SidecarWorld -Module $module -State $st -World $stoppedWorld
    $stopped = Invoke-SidecarScenario -Label 'failed-stopped' -World $stoppedWorld -StartOptions @{ AllowSwitch = $true } -Steps @((New-Step @{ phase = 'ready'; modelId = 'model-a'; sidecarPhase = 'ready' } 'switch' @{ modelId = 'model-b' }), (New-Step @{ switchResult = 'failed-stopped' } 'none'))
    $stoppedPid = [int] (@($stopped.observations | Where-Object { [int] $_.sidecarPid -gt 0 })[0].sidecarPid)
    Check ((Get-FailureCode $stopped.failure) -ceq 'switch-failed-stopped' -and $stopped.runs.Count -eq 3) 'failed-stopped: the target and the one restore both failed, and the start ends with switch-failed-stopped'
    Check ((Wait-ProcessGone $stoppedPid) -and (Wait-PortFree $stoppedWorld.embeddingPort) -and (Wait-PortFree $stoppedWorld.port) -and (Get-Sidecar $stopped.final).phase -ceq 'stopped' -and (Get-Field $stopped.final.switch 'result') -ceq 'failed-stopped') 'failed-stopped: both processes are stopped, and the final document says so for the sidecar too'

    # The previous model cannot even be started again (its file fails the check before any run): no run is alive to stop the sidecar or to
    # write the document, so the session's owner does both.
    $ownerWorld = New-SidecarWorld -Module $module -Root $root -Temp $temp -Label 'owner-stops' -Modes @{ 'model-b' = @('exit') }
    Use-SidecarWorld -Module $module -State $st -World $ownerWorld
    $st.hashFail = @{ 'model-a' = 2 }
    $owner = Invoke-SidecarScenario -Label 'owner-stops' -World $ownerWorld -StartOptions @{ AllowSwitch = $true } -Steps @((New-Step @{ phase = 'ready'; modelId = 'model-a'; sidecarPhase = 'ready' } 'switch' @{ modelId = 'model-b' }), (New-Step @{ switchResult = 'failed-stopped' } 'none'))
    $st.hashFail = @{}
    $ownerPid = [int] (@($owner.observations | Where-Object { [int] $_.sidecarPid -gt 0 })[0].sidecarPid)
    $ownerLastRun = $owner.runs[$owner.runs.Count - 1].finalText | ConvertFrom-Json
    Check ((Get-FailureCode $owner.failure) -ceq 'switch-failed-stopped' -and $owner.runs.Count -eq 2 -and (Get-Sidecar $ownerLastRun).phase -ceq 'ready') 'owner: the target failed, and the previous model could not be started again before any run (two runs); the last run had left the sidecar ready for the restore'
    Check ((Wait-ProcessGone $ownerPid) -and (Wait-PortFree $ownerWorld.embeddingPort) -and (Get-Sidecar $owner.final).phase -ceq 'stopped' -and (Get-Field $owner.final.switch 'result') -ceq 'failed-stopped' -and [string] $owner.final.runId -ceq [string] $ownerLastRun.runId) 'owner: the session''s owner stops the sidecar and brings the last document up to date (sidecar stopped, switch failed-stopped)'

    # ================= idle stop: activity on either server counts; an unreadable sidecar /metrics counts as busy; a stop ends both =================
    InModule { $script:FastLlmIdlePollSeconds = 1 }
    $idleWorld = New-SidecarWorld -Module $module -Root $root -Temp $temp -Label 'idle'
    Use-SidecarWorld -Module $module -State $st -World $idleWorld
    $metricsFile = Join-Path $idleWorld.control 'metrics'
    [IO.File]::WriteAllText($metricsFile, 'busy')
    $poll = { param([int] $Number) Join-Path $idleWorld.root ('polls-' + $Number) }
    # 15 minutes of idleness are nine polls of the accelerated clock (a first read, then eight times 120 seconds). Each stage below waits
    # for 14 more polls while the sidecar reports activity of one kind; the text server is idle the whole time.
    $idle = Invoke-SidecarScenario -Label 'idle' -World $idleWorld -StartOptions @{ IdleStopMinutes = 15 } -Steps @(
        (New-Step @{ phase = 'ready'; sidecarPhase = 'ready' } 'write' @{ path = (Join-Path $idleWorld.root 'accelerate'); text = 'on' }),
        (New-Step @{ phase = 'ready'; fileExists = (& $poll 14) } 'write' @{ path = $metricsFile; text = 'activity' }),
        (New-Step @{ phase = 'ready'; fileExists = (& $poll 28) } 'write' @{ path = $metricsFile; text = '404' }),
        (New-Step @{ phase = 'ready'; fileExists = (& $poll 42) } 'write' @{ path = $metricsFile; text = 'garbage' }),
        (New-Step @{ phase = 'ready'; fileExists = (& $poll 56) } 'request'),
        (New-Step @{ phase = 'ready'; sidecarPhase = 'ready' } 'write' @{ path = $metricsFile; text = 'idle' }),
        (New-Step @{ phase = 'stopped'; stopReason = 'idle' } 'none'))
    $idlePid = [int] (@($idle.observations | Where-Object { [int] $_.sidecarPid -gt 0 })[0].sidecarPid)
    $idleTextPid = [int] (@($idle.observations | Where-Object { [int] $_.pid -gt 0 })[0].pid)
    Check ($idle.completed -and $null -eq $idle.failure -and $idle.exit -eq 0 -and [int] (Get-StepOutcome $idle 'request').textModels -eq 200 -and [int] (Get-StepOutcome $idle 'request').sidecarHealth -eq 200) 'idle: while the sidecar has a request in progress, then moving counters, then an unreadable /metrics (404, then not a metrics document), the idle text model is NOT stopped (56 polls; 9 would stop it)'
    Check ($idle.final.stopReason -ceq 'idle' -and $idle.final.phase -ceq 'stopped' -and (Get-Sidecar $idle.final).phase -ceq 'stopped' -and (Wait-ProcessGone $idleTextPid) -and (Wait-ProcessGone $idlePid) -and (Wait-PortFree $idleWorld.embeddingPort)) 'idle: once both servers are idle the idle stop fires, and it stops both'
    $idleLog = @(Get-RunLog $idleWorld ([string] $idle.final.runId))
    $sidecarMetricsReads = @(Read-Control $idleWorld 'metrics.log')
    Check (@(Get-LogEvents $idleLog 'idle-stop').Count -eq 1 -and @(Get-LogEvents $idleLog 'sidecar-idle-check-failed').Count -eq 1 -and @(Get-LogEvents $idleLog 'sidecar-idle-check-failed')[0].role -ceq 'embedding') 'idle: the unreadable sidecar /metrics is logged once for the whole run of failed reads, and the stop is logged'
    Check (@($sidecarMetricsReads | Where-Object { $_ -ceq 'busy' }).Count -ge 10 -and @($sidecarMetricsReads | Where-Object { $_ -ceq '404' }).Count -ge 10 -and @($sidecarMetricsReads | Where-Object { $_ -ceq 'idle' }).Count -ge 8) "idle: the supervisor read the sidecar's /metrics at every poll ($($sidecarMetricsReads.Count) reads)"
    # The other direction: the text server has a request in progress and the sidecar is idle.
    $busyWorld = New-SidecarWorld -Module $module -Root $root -Temp $temp -Label 'idle-text-busy' -Modes @{ 'model-a' = @('busy-ok') }
    Use-SidecarWorld -Module $module -State $st -World $busyWorld
    $busy = Invoke-SidecarScenario -Label 'idle-text-busy' -World $busyWorld -StartOptions @{ IdleStopMinutes = 15 } -Steps @(
        (New-Step @{ phase = 'ready'; sidecarPhase = 'ready' } 'write' @{ path = (Join-Path $busyWorld.root 'accelerate'); text = 'on' }),
        (New-Step @{ phase = 'ready'; fileExists = (Join-Path $busyWorld.root 'polls-16') } 'request'),
        (New-Step @{ phase = 'ready' } 'stop'))
    Check ($busy.completed -and $busy.exit -eq 0 -and $busy.final.stopReason -ceq 'user' -and [int] (Get-StepOutcome $busy 'request').sidecarHealth -eq 200 -and @(Get-LogEvents (Get-RunLog $busyWorld ([string] $busy.final.runId)) 'idle-stop').Count -eq 0) 'idle: while the TEXT server has a request in progress and the sidecar is idle, nothing is stopped (16 polls)'
    InModule { $script:FastLlmIdlePollSeconds = 30 }

    # ================= the API key: environment only, the sidecar's own 401/200 proof, the listener check on the sidecar's port =================
    $keyWorld = New-SidecarWorld -Module $module -Root $root -Temp $temp -Label 'key' -SidecarMode 'marker-ok'
    Use-SidecarWorld -Module $module -State $st -World $keyWorld
    InModule { param($InstallRoot, $Holder) Write-FastLlmApiKeyStore -InstallRoot $InstallRoot -ApiKeyHolder $Holder } @($keyWorld.root, (New-Holder $keyMarker))
    InModule { $script:FastLlmIdlePollSeconds = 1 }
    $listenerAsks.Clear()
    $key = Invoke-SidecarScenario -Label 'key' -World $keyWorld -StartOptions @{ ApiKey = 'on'; IdleStopMinutes = 15 } -Steps @(
        (New-Step @{ phase = 'ready'; sidecarPhase = 'ready' } 'sleep' @{ milliseconds = 3500 }),
        (New-Step @{ phase = 'ready'; sidecarPhase = 'ready' } 'request' @{ embedBody = '{"input":"a request without the key"}' }),
        (New-Step @{ phase = 'ready' } 'stop'))
    InModule { $script:FastLlmIdlePollSeconds = 30 }
    $keyAsks = @($listenerAsks.ToArray())
    $keyReady = @($key.writes | Where-Object { [string] (Get-Sidecar $_).phase -ceq 'ready' })[0]
    Check ($key.completed -and $null -eq $key.failure -and $key.exit -eq 0 -and $keyReady.apiKey -ceq 'on' -and (Get-Sidecar $keyReady).canary.ok -eq $true) 'key: with the API key on, the text model and the sidecar both become ready'
    $keyEnvironment = @(Read-Control $keyWorld 'env.txt')
    Check ($keyEnvironment -ccontains 'key-present' -and (@($keyEnvironment | Where-Object { $_ -clike 'name *' }) -join ',') -ceq 'name LLAMA_API_KEY') 'key: the sidecar gets the key through its environment (LLAMA_API_KEY and no other engine variable)'
    $keyArguments = @(Read-Control $keyWorld 'argv.txt') -join "`n"
    Check (@($keyWords | Where-Object { $keyArguments.IndexOf($_, [StringComparison]::Ordinal) -ge 0 }).Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $keyWorld.control 'fault')) -and $keyArguments -cnotmatch '(?i)api[-_]?key') 'key: no argument of the sidecar holds the key or names one'
    $keyAuth = @(Read-Control $keyWorld 'auth.log')
    $keyApi = @($keyAuth | Where-Object { $_ -cnotlike '* /health *' })
    $keyArgsProofPaths = (@($keyApi | Select-Object -First 2) -join '|')
    Check ($keyApi.Count -ge 5 -and $keyApi[0] -ceq 'GET /props none' -and $keyApi[1] -ceq 'GET /props ok') "key: the sidecar's own proof comes first, on /props as the text server's does: one request without the key, then one with it ($($keyApi[0]) | $($keyApi[1]))"
    Check ((@($keyApi | Select-Object -Skip 2 -First 3) -join ' | ') -ceq 'GET /v1/models ok | POST /v1/embeddings ok | POST /v1/embeddings ok') 'key: the canary follows, every request with the key'
    Check (@($keyAuth | Where-Object { $_ -clike '* wrong' }).Count -eq 0 -and @($keyAuth | Where-Object { $_ -clike '* /health *' -and $_ -cnotlike '* none' }).Count -eq 0 -and @($keyAuth | Where-Object { $_ -ceq 'GET /metrics ok' }).Count -ge 2 -and @($keyAuth | Where-Object { $_ -ceq 'GET /metrics none' }).Count -eq 0) 'key: the health polls never carry the key, and the idle read of the sidecar''s /metrics always does'
    $keyRequest = Get-StepOutcome $key 'request'
    Check ([int] $keyRequest.sidecarEmbed -eq 401 -and [int] $keyRequest.textModels -eq 401 -and [int] $keyRequest.sidecarHealth -eq 200) 'key: an app without the key is refused by the sidecar (401), as by the text server; /health stays open'
    Check ([int] $keyRequest.sidecarModelsOpen -eq 200 -and $keyArgsProofPaths -ceq 'GET /props none|GET /props ok') 'key: the engine answers /v1/models without the key (as upstream llama-server does), so it is no proof; the sidecar still reached ready, because its proof is /props'
    $keyedSidecarRequests = @($keyAuth | Where-Object { $_ -clike '* ok' }).Count
    $sidecarAsks = @($keyAsks | Where-Object { $_ -eq [int] $keyWorld.embeddingPort }).Count
    Check ($keyedSidecarRequests -ge 6 -and $sidecarAsks -ge (2 * $keyedSidecarRequests) -and @($keyAsks | Where-Object { $_ -eq [int] $keyWorld.port }).Count -ge 2) "key: every request that carried the key to the sidecar was preceded and followed by the listener check on the SIDECAR's port ($keyedSidecarRequests keyed requests, $sidecarAsks checks)"
    $keyLeaks = @(Find-WordsInFiles $keyWorld.root $keyWords)
    $keyConsole = ($key.console -join "`n")
    Check ($keyLeaks.Count -eq 0 -and @($keyWords | Where-Object { $keyConsole.IndexOf($_, [StringComparison]::Ordinal) -ge 0 }).Count -eq 0) "key: no key text is in any file (status, run logs, the mock's own argument and request records) or on the console, although the engine printed its key line and every Authorization header ($($keyLeaks -join '; '))"
    Check ((Get-Sidecar $key.final).phase -ceq 'stopped' -and (Wait-PortFree $keyWorld.embeddingPort)) 'key: the stop ends the keyed sidecar too'
    # The mock printed the key on lines with no api_key label (each request's Authorization header): only the process host's drop of any line
    # that holds the key can remove them. Besides the one labelled startup line, at least one line per keyed request of the proof and the
    # start check was dropped (the count only is read, just before the sidecar's process host is closed).
    $keyedChecks = @($keyApi | Where-Object { $_ -clike '* ok' -and $_ -cnotlike 'GET /metrics*' }).Count
    $droppedCounts = @($st.dropped.ToArray())
    Check ($keyedChecks -ge 4 -and $droppedCounts.Count -ge 1 -and [int] $droppedCounts[0] -ge (1 + $keyedChecks)) "key: the sidecar's output capture drops every line that holds the key, not only the labelled one ($($droppedCounts -join ',') lines dropped; $keyedChecks keyed requests echoed the key, and one labelled line)"

    # ---- module logging: nothing on the sidecar's key path is handed to PowerShell as a loggable value ----
    # PowerShell module logging records every bound parameter value of a module's functions and of cmdlets. With it on for FastLLM and for
    # PowerShell's own utility and management cmdlets, a whole keyed start with the sidecar runs, and what PowerShell logged is read: on
    # macOS the unified log of this process, on Windows a live capture of the PowerShell operational event log (event 4103 of this process,
    # tests/helpers/module-log-tap.ps1): a subscription that keeps each event as it is written, so the size of that circular log cannot
    # take anything out of the window. Two canary values, logged the same way before and after, mark the window; on Windows every record
    # between them must also have been delivered (a check of its own). Without the canaries the check is skipped and says so.
    # The key of this check is random text made here (never a real key): PowerShell may also log script text, and a marker written out in a
    # test file would be found in that text and not because a value was logged.
    $logMarker = 'fl-' + ([Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')).Substring(0, 43)
    $logWorld = New-SidecarWorld -Module $module -Root $root -Temp $temp -Label 'key-logged'
    Use-SidecarWorld -Module $module -State $st -World $logWorld
    InModule { param($InstallRoot, $Holder) Write-FastLlmApiKeyStore -InstallRoot $InstallRoot -ApiKeyHolder $Holder } @($logWorld.root, (New-Holder $logMarker))
    $logCanaryOne = 'MODLOGCANARY1' + [Guid]::NewGuid().ToString('N')
    $logCanaryTwo = 'MODLOGCANARY2' + [Guid]::NewGuid().ToString('N')
    $logKind = 'none'
    $onMac = [bool] (Test-Path Variable:IsMacOS) -and [bool] (Get-Variable -Name IsMacOS -ValueOnly)
    if ($onMac -and (Test-Path -LiteralPath '/usr/bin/log')) { $logKind = 'mac' } elseif ($isWindowsHost) { $logKind = 'windows' }
    $logCapturePath = Join-Path $temp 'module-log-capture.txt'
    $logBegin = [DateTime]::UtcNow.AddSeconds(-1)
    $logBeginLocal = [DateTime]::Now.AddSeconds(-1).ToString('yyyy-MM-dd HH:mm:ss')
    $logEventLog = 'Microsoft-Windows-PowerShell/Operational'
    if ($PSVersionTable.PSVersion.Major -ge 6) { $logEventLog = 'PowerShellCore/Operational' }
    $logTap = $null
    $logTapReport = $null
    $logEvidence = @{ oneId = [long] -1; oneSnapshot = ''; lastWait = '' }
    function Read-ModuleLog {
        if ($logKind -ceq 'mac') {
            try { & '/usr/bin/log' show --style compact --start $logBeginLocal --predicate "processID == $PID" > $logCapturePath 2> ($logCapturePath + '.err'); return [IO.File]::ReadAllText($logCapturePath) } catch { return '' }
        }
        if ($logKind -ceq 'windows') {
            # The live capture: the 4103 events of this process, kept as they were written.
            if ($null -eq $logTap) { return '' }
            return $logTap.Text()
        }
        return ''
    }
    function Wait-ModuleLogCanary([string] $Canary, [int] $Seconds) {
        $canaryClock = [Diagnostics.Stopwatch]::StartNew()
        while ($canaryClock.Elapsed.TotalSeconds -lt $Seconds) {
            # A module function with the canary as a plain [string] parameter: logged exactly the way a key parameter would be.
            $null = InModule { param($R) Get-FastLlmApiKeyStoreState -InstallRoot $R } @((Join-Path $temp $Canary))
            Start-Sleep -Milliseconds 400
            $waitText = Read-ModuleLog
            $logEvidence.lastWait = Get-ModuleLogFlags $waitText $logCanaryOne $logCanaryTwo
            if ($waitText.IndexOf($Canary, [StringComparison]::Ordinal) -ge 0) { return $true }
        }
        return $false
    }
    $loggedModules = @($module)
    foreach ($builtIn in @('Microsoft.PowerShell.Utility', 'Microsoft.PowerShell.Management')) { $loggedModules += @(Import-Module $builtIn -PassThru) }
    $logSawOne = $false; $logSawTwo = $false; $logRun = $null; $logText = ''
    # A document an app sends to the engine while it is still loading, and the sidecar then ends (its output is read for a bind error): made
    # here at run time, so a marker written in this file cannot be found through logged script text.
    $logDocMarker = 'B9DOC' + [Guid]::NewGuid().ToString('N')
    $logDocRun = $null
    try {
        if ($logKind -cne 'none') {
            # The capture starts before logging is turned on, so compiling it and creating it log nothing.
            if ($logKind -ceq 'windows') { $logTap = Start-ModuleLogTap $logEventLog $PID }
            foreach ($loggedModule in $loggedModules) { $loggedModule.LogPipelineExecutionDetails = $true }
            $logSawOne = Wait-ModuleLogCanary $logCanaryOne 30
            if ($logSawOne -and $logKind -ceq 'windows') { $logEvidence.oneId = [long] $logTap.FindRecord($logCanaryOne); $logEvidence.oneSnapshot = Get-ModuleLogSnapshot $logEventLog }
        }
        if ($logSawOne) {
            InModule { $script:FastLlmIdlePollSeconds = 1 }
            $logRun = Invoke-SidecarScenario -Label 'key-logged' -World $logWorld -StartOptions @{ ApiKey = 'on'; IdleStopMinutes = 15 } -Steps @((New-Step @{ phase = 'ready'; sidecarPhase = 'ready' } 'sleep' @{ milliseconds = 2500 }), (New-Step @{ phase = 'ready' } 'stop'))
            InModule { $script:FastLlmIdlePollSeconds = 30 }
            $logDocWorld = New-SidecarWorld -Module $module -Root $root -Temp $temp -Label 'doc-logged' -SidecarMode 'marker-nohealth'
            Use-SidecarWorld -Module $module -State $st -World $logDocWorld
            $logDocRun = Invoke-SidecarScenario -Label 'doc-logged' -World $logDocWorld -Steps @(
                (New-Step @{ phase = 'ready'; sidecarPhase = 'starting'; fileExists = (Join-Path $logDocWorld.control 'listening') } 'request' @{ embedBody = ('{"input":"' + $logDocMarker + ' a private document"}') }),
                (New-Step @{ phase = 'ready'; sidecarPhase = 'starting' } 'kill-sidecar'),
                (New-Step @{ phase = 'ready'; sidecarPhase = 'failed' } 'stop'))
            $logSawTwo = Wait-ModuleLogCanary $logCanaryTwo 60
        }
    }
    finally {
        InModule { $script:FastLlmIdlePollSeconds = 30 }
        foreach ($loggedModule in $loggedModules) { $loggedModule.LogPipelineExecutionDetails = $false }
        if ($logKind -cne 'none') { Start-Sleep -Milliseconds 500; $logText = Read-ModuleLog }
        # Canary two is in the capture when the wait saw it; delivery is in record order, so everything before it is in the text too.
        if ($null -ne $logTap) { $logTapReport = Get-ModuleLogTapReport $logTap $logCanaryOne $logCanaryTwo; Stop-ModuleLogTap $logTap }
    }
    foreach ($logInfoLine in @(Get-ModuleLogEvidenceLines $logKind $logEventLog $PID $logBegin $logEvidence $logText $logCanaryOne $logCanaryTwo $logTapReport)) { Write-Host $logInfoLine }
    if ($null -eq $logRun -or -not $logSawTwo) {
        $logSkipText = "the module-logging check of the sidecar's key path did not run to the end on this host: log source '$logKind', first canary seen: $logSawOne, second canary seen: $logSawTwo, live capture start error: '$($script:moduleLogTapStartError)'."
        # On Windows PowerShell 5.1 - the PowerShell the product runs in - this check is not optional.
        Check (-not ($isWindowsHost -and $PSVersionTable.PSVersion.Major -lt 6)) "module logging: on Windows PowerShell 5.1 the check must run to the end, and $logSkipText (The log is $logEventLog, event 4103.)"
        Write-Host "SKIP: $logSkipText The static rules of the API key suite cover src/FastLlm.Sidecar.ps1."
    }
    else {
        $logAuth = @(Read-Control $logWorld 'auth.log')
        Check ($logRun.completed -and $null -eq $logRun.failure -and $logRun.exit -eq 0 -and @($logRun.writes | Where-Object { [string] (Get-Sidecar $_).phase -ceq 'ready' -and [string] $_.apiKey -ceq 'on' }).Count -ge 1 -and @($logAuth | Where-Object { $_ -ceq 'POST /v1/embeddings ok' }).Count -eq 2 -and @($logAuth | Where-Object { $_ -ceq 'GET /metrics ok' }).Count -ge 1) 'module logging: with logging on, a keyed start with the sidecar ran to ready (its proof, its start check and its keyed /metrics reads) and stopped'
        $logFunctions = @('Start-FastLlmServer', 'Invoke-FastLlmSupervisedServer', 'Enter-FastLlmSidecarRun', 'Step-FastLlmSidecar', 'Start-FastLlmSidecarProcess', 'Complete-FastLlmSidecarChecks', 'Test-FastLlmSidecarCanary', 'Invoke-FastLlmSidecarRequest', 'Join-FastLlmSidecarIdle', 'Invoke-FastLlmHttp', 'Initialize-FastLlmEngineStartInfo', 'Get-FastLlmApiKeyText')
        $logMissing = @($logFunctions | Where-Object { $logText.IndexOf('ParameterBinding(' + $_ + ')', [StringComparison]::Ordinal) -lt 0 -and $logText.IndexOf('CommandInvocation(' + $_ + ')', [StringComparison]::Ordinal) -lt 0 })
        if ($logKind -ceq 'windows') { Check (Test-ModuleLogTapComplete $logTapReport) "module logging: the live capture lost nothing - no subscription error, and every record from canary one's to canary two's was delivered (records missing between them: $($logTapReport.missing), subscription errors: $($logTapReport.errors) $($logTapReport.errorType))" }
        Check ($logText.IndexOf($logCanaryOne, [StringComparison]::Ordinal) -ge 0 -and $logText.IndexOf($logCanaryTwo, [StringComparison]::Ordinal) -ge 0 -and $logMissing.Count -eq 0 -and $logText.IndexOf('System.Security.SecureString', [StringComparison]::Ordinal) -ge 0) "module logging: the log really recorded these calls - both canaries, the sidecar's functions and the key holder parameter (as a type name) are in it ($(Get-ModuleLogFlags $logText $logCanaryOne $logCanaryTwo), not logged: $($logMissing -join ','))"
        $logCharacters = @($logMarker.ToCharArray() | ForEach-Object { [string] $_ })
        $logByteValues = @([Text.Encoding]::UTF8.GetBytes($logMarker) | ForEach-Object { [string] [int] $_ })
        $logForbidden = [ordered] @{
            'the key' = $logMarker
            'the first twelve characters after the prefix' = $logMarker.Substring(3, 12)
            'twelve characters from the middle' = $logMarker.Substring(17, 12)
            'the last eight characters (the tail the engine prints is inside them)' = $logMarker.Substring(38, 8)
            'the key as comma-joined characters' = ($logCharacters -join ', ')
            'a run of eight comma-joined key characters' = (@($logCharacters[3..10]) -join ', ')
            'the key as comma-joined bytes' = ($logByteValues -join ', ')
            'a run of eight comma-joined key bytes' = (@($logByteValues[3..10]) -join ', ')
        }
        $logFindings = @($logForbidden.Keys | Where-Object { $logText.IndexOf([string] $logForbidden[$_], [StringComparison]::Ordinal) -ge 0 })
        Check ($logFindings.Count -eq 0) "module logging: what PowerShell logged ($($logText.Length) characters, source '$logKind') holds no key, no part of it, and no comma-joined characters or bytes of it ($($logFindings -join '; '))"
        $logFileHits = @(Find-WordsInFiles $logWorld.root @($logMarker, $logMarker.Substring(3, 12), $logMarker.Substring(34, 12)))
        Check ($logFileHits.Count -eq 0) "module logging: and no file of that start holds the key ($($logFileHits -join '; '))"
        # What the engine printed is never handed to a PowerShell parameter either: the document an app sent while the sidecar loaded was echoed
        # by the mock engine (as a verbose server would), and the sidecar's start check read that output when the sidecar ended.
        $logDocAuth = @(Read-Control $logDocWorld 'auth.log')
        Check ($null -ne $logDocRun -and $logDocRun.completed -and (Get-Field (Get-Sidecar $logDocRun.final) 'failureCode') -ceq 'embeddings-server-exited' -and @($logDocAuth | Where-Object { $_ -ceq 'POST /v1/embeddings none' }).Count -eq 1) 'module logging: the scenario ran: an app''s document reached the engine while it loaded, the sidecar ended, and its block says embeddings-server-exited'
        Check ($logText.IndexOf($logDocMarker, [StringComparison]::Ordinal) -lt 0 -and $logText.IndexOf('a private document', [StringComparison]::Ordinal) -lt 0) 'module logging: no text an app sent to the engine, echoed in the engine''s output, is in what PowerShell logged'
        Check (@(Find-WordsInFiles $logDocWorld.root @($logDocMarker) | Where-Object { $_ -notmatch 'steps\.json|client-result' }).Count -eq 0) 'module logging: and the document is in no file FastLLM wrote for that start'
    }

    # The listener on the sidecar's port is not the sidecar this run started: nothing with the key is sent to it, and only the sidecar fails.
    $lieWorld = New-SidecarWorld -Module $module -Root $root -Temp $temp -Label 'key-listener'
    Use-SidecarWorld -Module $module -State $st -World $lieWorld
    InModule { param($InstallRoot, $Holder) Write-FastLlmApiKeyStore -InstallRoot $InstallRoot -ApiKeyHolder $Holder } @($lieWorld.root, (New-Holder $keyMarker))
    $listenerLies[[int] $lieWorld.embeddingPort] = $PID
    try { $lie = Invoke-SidecarScenario -Label 'key-listener' -World $lieWorld -StartOptions @{ ApiKey = 'on' } -Steps @((New-Step @{ phase = 'ready'; sidecarPhase = 'failed' } 'request'), (New-Step @{ phase = 'ready' } 'stop')) }
    finally { $listenerLies.Clear() }
    $lieAuth = @(Read-Control $lieWorld 'auth.log')
    Check ($lie.completed -and $null -eq $lie.failure -and $lie.exit -eq 0 -and (Get-Sidecar $lie.final).failureCode -ceq 'api-key-listener-not-verified') 'key listener: when the listener on the sidecar''s port cannot be confirmed to be the sidecar, the sidecar fails with api-key-listener-not-verified'
    Check (@($lieAuth | Where-Object { $_ -cnotlike '* none' }).Count -eq 0 -and @($lieAuth | Where-Object { $_ -ceq 'GET /props none' }).Count -eq 1) "key listener: no request with the key was sent to it (only the keyless half of the proof) ($(@($lieAuth | Where-Object { $_ -cnotlike '* /health *' }) -join ' | '))"
    $lieReady = @($lie.writes | Where-Object { [string] (Get-Sidecar $_).phase -ceq 'failed' })[0]
    Check ($lieReady.phase -ceq 'ready' -and $lieReady.apiKey -ceq 'on' -and $null -eq $lieReady.failureCode -and [int] (Get-StepOutcome $lie 'request').textModels -eq 401 -and [int] (Get-StepOutcome $lie 'request').textHealth -eq 200) 'key listener: the key failure on the sidecar fails only the sidecar; the text model keeps serving with its key'

    # A sidecar that does not enforce the key never becomes ready.
    $ignoreWorld = New-SidecarWorld -Module $module -Root $root -Temp $temp -Label 'key-not-enforced'
    Use-SidecarWorld -Module $module -State $st -World $ignoreWorld
    [IO.File]::WriteAllText((Join-Path $ignoreWorld.control 'keymode'), 'ignore')
    InModule { param($InstallRoot, $Holder) Write-FastLlmApiKeyStore -InstallRoot $InstallRoot -ApiKeyHolder $Holder } @($ignoreWorld.root, (New-Holder $keyMarker))
    $ignore = Invoke-SidecarScenario -Label 'key-not-enforced' -World $ignoreWorld -StartOptions @{ ApiKey = 'on' } -Steps @((New-Step @{ phase = 'ready'; sidecarPhase = 'failed' } 'request'), (New-Step @{ phase = 'ready' } 'stop'))
    Check ($ignore.completed -and $ignore.exit -eq 0 -and (Get-Sidecar $ignore.final).failureCode -ceq 'api-key-not-enforced' -and @($ignore.writes | Where-Object { [string] (Get-Sidecar $_).phase -ceq 'ready' }).Count -eq 0) 'key proof: a sidecar that answers without the key (200 where 401 is required) never says ready: api-key-not-enforced'
    Check ([int] (Get-StepOutcome $ignore 'request').textModels -eq 401 -and @(Read-Control $ignoreWorld 'auth.log' | Where-Object { $_ -clike 'POST /v1/embeddings*' }).Count -eq 0) 'key proof: the text model keeps serving with its key, and no canary request followed the failed proof'

    # The key may have been sent to another program: after a request WITH the key, the listener on the sidecar's port is no longer the sidecar.
    # The key is one secret and the text server still accepts it, so this is not a failure of the sidecar alone: the whole run ends as the text
    # server's own listener change does (api-key-listener-changed, both processes stopped, no restore, no retry, "create a new key").
    # The check before each send sees the sidecar; the first check after a keyed request sees another program. Once while the sidecar is
    # checked (the proof's keyed request), once on the keyed /metrics idle read of a ready sidecar.
    foreach ($exposure in @(
            @{ Label = 'key-exposed-checking'; Pattern = '* ok'; Options = @{ ApiKey = 'on' }; ReadyFirst = $false },
            @{ Label = 'key-exposed-idle'; Pattern = 'GET /metrics ok'; Options = @{ ApiKey = 'on'; IdleStopMinutes = 15 }; ReadyFirst = $true })) {
        $exposedWorld = New-SidecarWorld -Module $module -Root $root -Temp $temp -Label $exposure.Label
        Use-SidecarWorld -Module $module -State $st -World $exposedWorld
        InModule { param($InstallRoot, $Holder) Write-FastLlmApiKeyStore -InstallRoot $InstallRoot -ApiKeyHolder $Holder } @($exposedWorld.root, (New-Holder $keyMarker))
        $listenerLieWhenKeyed[[int] $exposedWorld.embeddingPort] = @{ world = $exposedWorld; pattern = $exposure.Pattern }
        InModule { $script:FastLlmIdlePollSeconds = 1 }
        try { $exposed = Invoke-SidecarScenario -Label $exposure.Label -World $exposedWorld -StartOptions $exposure.Options -Steps @((New-Step @{ phase = 'failed' } 'none')) }
        finally { $listenerLieWhenKeyed.Clear(); InModule { $script:FastLlmIdlePollSeconds = 30 } }
        $exposedAuth = @(Read-Control $exposedWorld 'auth.log')
        $exposedCode = Get-FailureCode $exposed.failure
        $exposedWhere = if ($exposure.ReadyFirst) { 'on the keyed /metrics read of a ready sidecar' } else { 'right after the sidecar''s first request with the key' }
        Check ($exposed.completed -and $exposedCode -ceq 'api-key-listener-changed' -and [string] $exposed.failure.Data['FastLlmReason'] -ceq 'ApiKeyFailed' -and [string] $exposed.failure.Message -cmatch 'Create a new key') "key exposed ($($exposure.Label)): a listener that changed $exposedWhere ends the whole start with api-key-listener-changed, reason ApiKeyFailed, and the create-a-new-key text (saw: $exposedCode)"
        Check ($null -ne $exposed.failure -and $null -eq $exposed.exit -and [string] $exposed.final.phase -ceq 'failed' -and [string] $exposed.final.failureCode -ceq 'api-key-listener-changed') "key exposed ($($exposure.Label)): the start raised (a non-zero exit), and the final document says failed with the same code, on the text model's own fields"
        $exposedSidecarPid = 0; $exposedTextPid = 0
        $exposedWithSidecar = @($exposed.observations | Where-Object { [int] $_.sidecarPid -gt 0 }); if ($exposedWithSidecar.Count -gt 0) { $exposedSidecarPid = [int] $exposedWithSidecar[0].sidecarPid }
        $exposedWithText = @($exposed.observations | Where-Object { [int] $_.pid -gt 0 }); if ($exposedWithText.Count -gt 0) { $exposedTextPid = [int] $exposedWithText[0].pid }
        Check ($exposedSidecarPid -gt 0 -and $exposedTextPid -gt 0 -and (Wait-ProcessGone $exposedSidecarPid) -and (Wait-ProcessGone $exposedTextPid) -and (Wait-PortFree $exposedWorld.port) -and (Wait-PortFree $exposedWorld.embeddingPort)) "key exposed ($($exposure.Label)): both processes are stopped and both ports are free"
        $exposedEnd = @(Get-LogEvents (Get-RunLog $exposedWorld ([string] $exposed.final.runId)) 'end')
        Check ($exposedEnd.Count -eq 1 -and $exposedEnd[0].phase -ceq 'failed' -and [int] $exposedEnd[0].exitCode -eq 1 -and $exposedEnd[0].failureCode -ceq 'api-key-listener-changed') "key exposed ($($exposure.Label)): the run log ends with a failed run (exit code 1) and the code, not a clean stop"
        Check ($exposed.runs.Count -eq 1 -and @($exposed.events | Where-Object { $_ -clike 'supervisor:*' }).Count -eq 1 -and @($exposed.events | Where-Object { $_ -clike 'plan:*' }).Count -eq 1 -and @(Read-Control $exposedWorld 'starts.log').Count -eq 1) "key exposed ($($exposure.Label)): no restore and no retry: one supervised run, one plan, one sidecar start"
        $exposedKeyed = @($exposedAuth | Where-Object { $_ -clike '* ok' })
        if ($exposure.ReadyFirst) { Check ($exposedKeyed.Count -ge 5 -and $exposedKeyed[$exposedKeyed.Count - 1] -ceq 'GET /metrics ok' -and @($exposedKeyed | Where-Object { $_ -ceq 'GET /metrics ok' }).Count -eq 1 -and @($exposed.writes | Where-Object { [string] (Get-Sidecar $_).phase -ceq 'ready' }).Count -ge 1) "key exposed ($($exposure.Label)): the sidecar had been ready, and no request with the key followed the one that raised the alarm" }
        else { Check ($exposedKeyed.Count -eq 1 -and @($exposed.writes | Where-Object { [string] (Get-Sidecar $_).phase -ceq 'ready' }).Count -eq 0) "key exposed ($($exposure.Label)): exactly one request carried the key, no later check followed it, and no document ever said ready" }
        $exposedBlock = Get-Sidecar $exposed.final
        # (A start that raises returns no console lines to this suite, so the sentence itself is checked below, from the function that makes it.)
        Check ($exposedBlock.phase -ceq 'failed' -and (Get-Field $exposedBlock 'failureCode') -ceq 'api-key-listener-changed' -and @($exposed.console | Where-Object { $_.Contains('The model keeps running') }).Count -eq 0) "key exposed ($($exposure.Label)): the sidecar block in the final document records the code, and nothing printed says that the model keeps running"
        Check (@(Find-WordsInFiles $exposedWorld.root $keyWords).Count -eq 0) "key exposed ($($exposure.Label)): no key text is in any file"
    }
    $exposedText = InModule { Get-FastLlmSidecarFailureText -Code 'api-key-listener-changed' -Plan $null }
    $exposedStatusText = Get-FastLlmEmbeddingsStatusText -Status (([ordered] @{ sidecars = @([ordered] @{ role = 'embedding'; phase = 'failed'; failureCode = 'api-key-listener-changed' }) } | ConvertTo-Json -Depth 5) | ConvertFrom-Json)
    Check ($exposedText -cmatch 'create a new key' -and $exposedText -cnotmatch 'model keeps running|not affected' -and $exposedStatusText -cmatch '(?i)create a new key' -and $exposedStatusText -cnotmatch 'not affected') 'key exposed: neither the console line nor the status line of the exposure code says the model is not affected'
    $sidecarOnlyText = InModule { Get-FastLlmSidecarFailureText -Code 'api-key-listener-not-verified' -Plan $null }
    Check ($sidecarOnlyText.Contains('The model keeps running') -and (Get-FastLlmEmbeddingsStatusText -Status (([ordered] @{ sidecars = @([ordered] @{ role = 'embedding'; phase = 'failed'; failureCode = 'api-key-listener-not-verified' }) } | ConvertTo-Json -Depth 5) | ConvertFrom-Json)).Contains('The model is not affected')) 'key exposed: the not-verified and not-enforced codes (nothing was sent) stay sidecar-only, with their texts as they were'

    # A supervisor pass never waits on more than ONE request to the sidecar. The engine reads every request but /health and never answers it
    # (the key is on, so the old chain of requests was: the proof without the key, the proof with it, the model list, the two start-check
    # requests). The stop is written when the first delayed request has arrived, while the sidecar is being checked; the run must be stopped
    # within one request's timeout (5 s for the proof) plus a pass and a margin, not after the whole chain of timeouts.
    $hangWorld = New-SidecarWorld -Module $module -Root $root -Temp $temp -Label 'pass-bound' -SidecarMode 'hang'
    Use-SidecarWorld -Module $module -State $st -World $hangWorld
    InModule { param($InstallRoot, $Holder) Write-FastLlmApiKeyStore -InstallRoot $InstallRoot -ApiKeyHolder $Holder } @($hangWorld.root, (New-Holder $keyMarker))
    $hang = Invoke-SidecarScenario -Label 'pass-bound' -World $hangWorld -StartOptions @{ ApiKey = 'on' } -Steps @(
        (New-Step @{ phase = 'ready'; sidecarPhase = 'checking'; fileExists = (Join-Path $hangWorld.control 'delaying') } 'stop'),
        (New-Step @{ phase = 'stopped' } 'none' @{ timeoutSeconds = 8 }))
    Check ($hang.completed -and $null -eq $hang.failure -and $hang.exit -eq 0 -and $hang.final.stopReason -ceq 'user') 'pass bound: a stop written while a sidecar request is unanswered ends the run within 8 seconds (one request timeout of 5 s, one pass, and a margin), not after every request of the checks has timed out'
    Check (@(Read-Control $hangWorld 'delaying.log').Count -le 1 -and (Wait-PortFree $hangWorld.embeddingPort) -and (Wait-PortFree $hangWorld.port)) 'pass bound: after the stop no further request was sent to the sidecar, and both ports are free'

    # The key is changed while the session runs, then the model is switched: the new run serves with the new key, and the sidecar still has
    # the earlier one. It is stopped and its block says why; it is never sent the new key and never started again.
    $rotateWorld = New-SidecarWorld -Module $module -Root $root -Temp $temp -Label 'key-changed'
    Use-SidecarWorld -Module $module -State $st -World $rotateWorld
    $rotatedStoreRoot = Join-Path $temp 'key-changed-store'
    New-Item -ItemType Directory -Path $rotatedStoreRoot -Force | Out-Null
    InModule { param($InstallRoot, $Holder) Write-FastLlmApiKeyStore -InstallRoot $InstallRoot -ApiKeyHolder $Holder } @($rotatedStoreRoot, (New-Holder $rotatedMarker))
    InModule { param($InstallRoot, $Holder) Write-FastLlmApiKeyStore -InstallRoot $InstallRoot -ApiKeyHolder $Holder } @($rotateWorld.root, (New-Holder $keyMarker))
    $rotate = Invoke-SidecarScenario -Label 'key-changed' -World $rotateWorld -StartOptions @{ ApiKey = 'on'; AllowSwitch = $true } -Steps @(
        (New-Step @{ phase = 'ready'; modelId = 'model-a'; sidecarPhase = 'ready' } 'copy' @{ from = (Join-Path $rotatedStoreRoot 'api-key.dat'); to = (Join-Path $rotateWorld.root 'api-key.dat') }),
        (New-Step @{ phase = 'ready'; modelId = 'model-a'; sidecarPhase = 'ready' } 'switch' @{ modelId = 'model-b' }),
        (New-Step @{ phase = 'ready'; modelId = 'model-b'; sidecarPhase = 'failed' } 'request'),
        (New-Step @{ phase = 'ready'; modelId = 'model-b' } 'stop'))
    $rotatePid = [int] (@($rotate.observations | Where-Object { [int] $_.sidecarPid -gt 0 })[0].sidecarPid)
    $rotateFirst = $rotate.runs[0].finalText | ConvertFrom-Json
    Check ($rotate.completed -and $null -eq $rotate.failure -and $rotate.exit -eq 0 -and (Get-Sidecar $rotate.final).failureCode -ceq 'embeddings-api-key-changed' -and (Wait-ProcessGone $rotatePid) -and (Wait-PortFree $rotateWorld.embeddingPort)) 'key changed: after a new key and a model switch, the sidecar (which still had the earlier key) is stopped: embeddings-api-key-changed'
    Check ($rotate.final.apiKey -ceq 'on' -and [string] $rotate.final.apiKeyId -cne [string] $rotateFirst.apiKeyId -and [int] (Get-StepOutcome $rotate 'request').textModels -eq 401 -and [int] (Get-StepOutcome $rotate 'request').textHealth -eq 200) 'key changed: the switched model serves with the new key; only the sidecar is affected'
    Check (@(Read-Control $rotateWorld 'auth.log' | Where-Object { $_ -clike '* wrong' }).Count -eq 0 -and @(Read-Control $rotateWorld 'starts.log').Count -eq 1 -and @(Find-WordsInFiles $rotateWorld.root $keyWords).Count -eq 0) 'key changed: the new key was never sent to the sidecar, the sidecar was not started again, and neither key is in any file'

    # ================= the command line: the two settings =================
    $cliRoot = Join-Path $temp 'cli-install'
    New-Item -ItemType Directory -Path $cliRoot -Force | Out-Null
    function Invoke-Cli([string[]] $Arguments) {
        $saved = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $text = (& $enginePath -NoLogo -NoProfile -NonInteractive -File (Join-Path $root 'fast-llm.ps1') @Arguments -InstallRoot $cliRoot 2>&1 | Out-String) } finally { $ErrorActionPreference = $saved }
        return [pscustomobject] @{ exit = $LASTEXITCODE; text = $text; flat = ([regex]::Replace([regex]::Replace($text, '\x1b\[[0-9;]*m', ''), '[\s|]+', ' ')) }
    }
    # The names saved in settings.json (member enumeration over an object with no properties is an error in strict mode).
    function Get-SavedSettingNames { return @((Get-Content -LiteralPath (Join-Path $cliRoot 'settings.json') -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { [string] $_.Name }) }
    # On every host: the command line saves the two settings through the settings writer, and takes the two parameters for start and settings only.
    Check ($cliSource.Contains("if (`$PSBoundParameters.ContainsKey('Embeddings')) { Set-FastLlmServingSettings -InstallRoot `$InstallRoot -Embeddings `$requestedEmbeddings }") -and $cliSource.Contains("if (`$PSBoundParameters.ContainsKey('EmbeddingPort')) { Set-FastLlmServingSettings -InstallRoot `$InstallRoot -EmbeddingPort `$EmbeddingPort }") -and $cliSource.Contains("-and `$effectiveAction -notin @('start', 'settings')) { throw '-Embeddings and -EmbeddingPort are supported only by start and settings.' }") -and $cliSource.Contains("[ValidateSet('off', 'on')]`n    [string] `$Embeddings,")) 'command line: -Embeddings (off or on) and -EmbeddingPort are saved by settings and refused by every action but start and settings'
    # fast-llm.ps1 refuses every action but an offline plan under an elevated Windows token, so the child cases run as a standard user only.
    $cliChildrenElevated = $false
    if ($isWindowsHost) { $cliChildrenElevated = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    if ($cliChildrenElevated) { Write-Host 'SKIP: the command-line child cases (fast-llm.ps1 refuses a live operation under an elevated token; they run as a standard user).' }
    else {
        $cliShown = Invoke-Cli @('settings')
        Check ($cliShown.exit -eq 0 -and $cliShown.flat.Contains('embeddings: off') -and $cliShown.flat.Contains('embeddingPort: 8081') -and -not (Test-Path -LiteralPath (Join-Path $cliRoot 'settings.json'))) 'command line: settings shows embeddings off and port 8081 by default, and writes nothing'
        $cliOn = Invoke-Cli @('settings', '-Embeddings', 'ON', '-EmbeddingPort', '18282', '-AsJson')
        $cliOnDocument = $cliOn.text | ConvertFrom-Json
        $cliSaved = Get-Content -LiteralPath (Join-Path $cliRoot 'settings.json') -Raw | ConvertFrom-Json
        Check ($cliOn.exit -eq 0 -and $cliOnDocument.embeddings -ceq 'on' -and [int] $cliOnDocument.embeddingPort -eq 18282 -and $cliSaved.embeddings -ceq 'on' -and [int] $cliSaved.embeddingPort -eq 18282) 'command line: settings -Embeddings on -EmbeddingPort 18282 saves both (the value is stored in lower case) and shows them'
        $cliOff = Invoke-Cli @('settings', '-Embeddings', 'off', '-EmbeddingPort', '8081')
        Check ($cliOff.exit -eq 0 -and $cliOff.flat.Contains('embeddings: off') -and @(Get-SavedSettingNames | Where-Object { $_ -clike 'embedding*' }).Count -eq 0) 'command line: off and 8081 remove the two saved values'
        foreach ($refusedCli in @(
                @{ args = @('plan', '-Embeddings', 'on'); text = '-Embeddings and -EmbeddingPort are supported only by start and settings.' },
                @{ args = @('doctor', '-EmbeddingPort', '9000'); text = '-Embeddings and -EmbeddingPort are supported only by start and settings.' },
                @{ args = @('install', '-Embeddings', 'on'); text = '-Embeddings and -EmbeddingPort are supported only by start and settings.' },
                @{ args = @('settings', '-EmbeddingPort', '80'); text = 'serving-settings-invalid-embedding-port' },
                @{ args = @('start', '-EmbeddingPort', '8081.5'); text = 'serving-settings-invalid-embedding-port' },
                @{ args = @('settings', '-Embeddings', 'maybe'); text = 'does not belong to the set' },
                @{ args = @('settings', '-ApiKey', 'show', '-Embeddings', 'on'); text = 'prints the key and nothing else' })) {
            $cliRefused = Invoke-Cli $refusedCli.args
            Check ($cliRefused.exit -ne 0 -and $cliRefused.flat.Contains($refusedCli.text) -and -not (Test-Path -LiteralPath (Join-Path $cliRoot 'state'))) "command line: '$($refusedCli.args -join ' ')' is refused and starts nothing"
        }
        Check (@(Get-SavedSettingNames | Where-Object { $_ -clike 'embedding*' }).Count -eq 0) 'command line: a refused value saved nothing'
    }

    # ================= both die when the supervisor dies (the kill-on-close job of the process host) =================
    if ($isWindowsHost) {
        $jobWorld = New-SidecarWorld -Module $module -Root $root -Temp $temp -Label 'job'
        $worker = New-Object Diagnostics.Process
        $worker.StartInfo.FileName = $enginePath
        $workerCode = "& '$((Join-Path $helpersRoot 'sidecar-supervisor-worker.ps1').Replace("'", "''"))' -Root '$($root.Replace("'", "''"))' -WorldRoot '$($jobWorld.root.Replace("'", "''"))' -WorldPath '$($jobWorld.path.Replace("'", "''"))' -CatalogPath '$($jobWorld.catalog.Replace("'", "''"))' -ControlPath '$($jobWorld.control.Replace("'", "''"))' -TextPort $([int] $jobWorld.port) -EmbeddingPort $([int] $jobWorld.embeddingPort)"
        $worker.StartInfo.Arguments = '-NoLogo -NoProfile -OutputFormat Text -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($workerCode))
        $worker.StartInfo.UseShellExecute = $false
        $worker.Start() | Out-Null
        try {
            $jobStatus = $null
            $jobClock = [Diagnostics.Stopwatch]::StartNew()
            while ($jobClock.Elapsed.TotalSeconds -lt 240) {
                try { $jobStatus = Get-Content -LiteralPath (Join-Path $jobWorld.state 'status.json') -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $jobStatus = $null }
                if ($null -ne $jobStatus -and [string] $jobStatus.phase -ceq 'ready' -and [string] (Get-Sidecar $jobStatus).phase -ceq 'ready') { break }
                Start-Sleep -Milliseconds 200
            }
            $jobTextPid = [int] $jobStatus.processIdentity.pid
            $jobSidecarPid = [int] (Get-Sidecar $jobStatus).processIdentity.pid
            Check ((Test-ProcessAlive $jobTextPid) -and (Test-ProcessAlive $jobSidecarPid) -and -not $worker.HasExited) 'supervisor exit: a supervisor in its own process serves the text model and the sidecar'
            $worker.Kill()
            Check ((Wait-ProcessGone $jobTextPid 30) -and (Wait-ProcessGone $jobSidecarPid 30) -and (Wait-PortFree $jobWorld.port 30) -and (Wait-PortFree $jobWorld.embeddingPort 30)) 'supervisor exit: when the supervisor process is killed, both children die with it'
        }
        finally { if (-not $worker.HasExited) { try { $worker.Kill() } catch { $null = $_ } }; $worker.Dispose() }
    }
    else { Write-Host 'SKIP: supervisor exit by a killed supervisor process needs the Windows kill-on-close job; it runs on Windows.' }
    # On every host: the sidecar runs in the same process host class as the text server, which is what carries that job.
    $sidecarSource = [IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.Sidecar.ps1'))
    Check ($sidecarSource.Contains('New-Object Bitworks.FastLlm.ProcessHost') -and $sidecarSource -cnotmatch 'Start-Process|\[Diagnostics\.Process\]::Start|System\.Diagnostics\.Process\]::Start') 'supervisor exit: the sidecar is started through the process host (the kill-on-close job) and through nothing else'

    $suitePassed = ($script:failed -eq 0)
    Write-Host "PASS: $script:count sidecar checks"
    if ($script:failed -gt 0) { Write-Host "FAILED: $script:failed sidecar checks"; exit 1 }
}
finally {
    [Environment]::SetEnvironmentVariable('FASTLLM_TEST_SIDECAR_CONTROL', $savedControl)
    & $module { $script:FastLlmApiKeyProtector = $null; $script:FastLlmApiKeyListenerOwners = $null }
    # Only this suite's own folder, by its literal path. A failed run keeps it for inspection.
    if ($suitePassed -and (Test-Path -LiteralPath $temp)) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
    elseif (-not $suitePassed) { Write-Host "The suite's working folder was kept: $temp" }
}
