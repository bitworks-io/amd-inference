# Loaded into FastLlm.psm1. These are lifecycle utilities, not another inference engine.
. (Join-Path $PSScriptRoot 'FastLlm.FileReplace.ps1')
function Initialize-FastLlmProcessHost {
    if (-not ('Bitworks.FastLlm.ProcessHost' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'ProcessHost.cs') -ErrorAction Stop
    }
}

function Get-FastLlmWindowsInventory {
    [CmdletBinding()]
    param()
    if ($env:OS -ne 'Windows_NT') { return [pscustomobject]@{ applicable=$false; qualified=$false } }
    Initialize-FastLlmProcessHost
    $child = New-Object Bitworks.FastLlm.ProcessHost
    try {
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = (Get-Process -Id $PID).Path
        $info.Arguments = Join-FastLlmProcessArguments @('-NoLogo','-NoProfile','-NonInteractive','-OutputFormat','Text','-File',(Join-Path $PSScriptRoot 'WindowsInventory.ps1'))
        $deadline = [Diagnostics.Stopwatch]::StartNew()
        $child.Start($info)
        $remaining = [Math]::Max(1, 30000 - [int]$deadline.ElapsedMilliseconds)
        if (-not $child.Process.WaitForExit($remaining)) { throw 'Windows inventory exceeded its 30-second deadline.' }
        while (-not $child.OutputCompleted) {
            if ($deadline.ElapsedMilliseconds -ge 30000) { throw 'Windows inventory output exceeded its 30-second deadline.' }
            Start-Sleep -Milliseconds 20
        }
        if ($child.OutputTruncated) { throw 'Windows inventory output was truncated.' }
        if ($child.Process.ExitCode -ne 0) { throw 'Windows DXGI/PNP inventory probe failed.' }
        $output = $child.Snapshot()
        if (-not $output -or $output.Length -gt 65536) { throw 'Windows inventory output was missing or oversized.' }
        $inventory = ConvertFrom-Json -InputObject $output -ErrorAction Stop
        if (-not $inventory -or $inventory.applicable -ne $true -or $inventory.qualified -ne $false -or
            -not $inventory.PSObject.Properties['nativeHost'] -or -not $inventory.nativeHost -or
            $inventory.nativeHost.schemaVersion -ne 1 -or
            $inventory.nativeHost.kind -ne 'windows-native-host-inventory' -or
            $inventory.nativeHost.qualified -ne $false -or
            $inventory.nativeHost.status -notin @('captured','partial','unavailable')) {
            throw 'Windows inventory output did not match its diagnostic schema.'
        }
        $nativeHost = $inventory.nativeHost
        if (-not $nativeHost.physicalMemoryBytes -or
            $nativeHost.physicalMemoryBytes.source -ne 'GlobalMemoryStatusEx.ullTotalPhys' -or
            $nativeHost.physicalMemoryBytes.status -notin @('captured','unavailable') -or
            -not $nativeHost.activeLogicalProcessors -or
            $nativeHost.activeLogicalProcessors.source -ne 'GetActiveProcessorCount.ALL_PROCESSOR_GROUPS' -or
            $nativeHost.activeLogicalProcessors.status -notin @('captured','unavailable') -or
            -not $nativeHost.os -or $nativeHost.os.versionSource -ne 'RtlGetVersion' -or
            $nativeHost.os.ubrSource -ne 'HKLM.CurrentVersion.UBR' -or
            $nativeHost.os.architectureSource -ne 'GetNativeSystemInfo' -or
            $nativeHost.os.status -notin @('captured','partial','unavailable') -or
            -not $nativeHost.advisory -or -not $nativeHost.advisory.cpuNames -or
            $nativeHost.advisory.cpuNames.source -ne 'HKLM.HARDWARE.CentralProcessor.ProcessorNameString' -or
            $nativeHost.advisory.cpuNames.status -notin @('captured','partial','unavailable') -or
            $nativeHost.advisory.cpuNames.scanLimit -ne 256 -or
            -not $nativeHost.advisory.systemManufacturer -or -not $nativeHost.advisory.systemProductName) {
            throw 'Windows inventory native host fields did not match their diagnostic schema.'
        }
        if ($nativeHost.status -eq 'captured' -and
            ($nativeHost.physicalMemoryBytes.status -ne 'captured' -or
             $nativeHost.activeLogicalProcessors.status -ne 'captured' -or
             $nativeHost.os.status -ne 'captured')) {
            throw 'Windows inventory native host completeness was inconsistent.'
        }
        if ($deadline.ElapsedMilliseconds -ge 30000) { throw 'Windows inventory exceeded its 30-second deadline.' }
        return $inventory
    } finally { $child.Dispose() }
}

function Get-FastLlmStateRoot {
    param([string] $InstallRoot, [switch] $Create)
    $root = [IO.Path]::GetFullPath($InstallRoot)
    $state = Join-FastLlmContainedPath -Root $root -Child 'state'
    foreach ($path in @($root, $state)) {
        if (Test-Path -LiteralPath $path) {
            $item = Get-Item -LiteralPath $path -Force
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe runtime state directory.' }
        }
    }
    if ($Create) { New-Item -ItemType Directory -Path $state -Force | Out-Null }
    return $state
}

# Attributes of a state file as an int, or $null when it cannot be read (missing, access denied). A seam for tests.
function Get-FastLlmStateFileAttributes {
    param([string]$Path)
    try { return [int][IO.File]::GetAttributes($Path) } catch { return $null }
}

function Write-FastLlmState {
    param([string] $InstallRoot, $State, [string] $FileName='status.json')
    Assert-FastLlmLeafName -Value $FileName -Label 'State file name'
    $temporary = $null
    $written = $false
    try {
        # Inside the typed-flag try: a failure to resolve or create the state folder is a state-write failure too.
        $root = Get-FastLlmStateRoot -InstallRoot $InstallRoot -Create
        $path = Join-Path $root $FileName
        $temporary = Join-Path $root ([Guid]::NewGuid().ToString('N') + '.tmp')
        # The reparse check stays before the write. [IO.File]::GetAttributes (FindFirstFile fallback on .NET Framework) also sees a
        # delete-pending destination, so a hold shorter than the replace budget no longer aborts a healthy start here;
        # Move-FastLlmFileReplacing owns the wait (<= ~1.4 s) and fails typed. Attributes -1 or an unreadable destination are
        # transient and are not retried: the replace below waits. A REAL reparse point is unsafe at once.
        $existingAttributes = Get-FastLlmStateFileAttributes -Path $path
        if ($null -ne $existingAttributes -and [int]$existingAttributes -ne -1 -and ([int]$existingAttributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Unsafe status path.' }
        # Every state document passes the key scrub on its way to disk: a well-formed API key can never be stored in one, whatever put it into the state.
        # The serialized text goes to the scrub inside a [ref] and not through a pipeline: nothing unscrubbed is handed to a cmdlet as input.
        $stateJson = ConvertTo-Json -InputObject $State -Depth 12
        Set-Content -LiteralPath $temporary -Encoding UTF8 -Value (ConvertTo-FastLlmKeyFreeText -Text ([ref] $stateJson) -Structured)
        $written = $true
        Move-FastLlmFileReplacing -Source $temporary -Destination $path
        # Success consumed the temp. Garbage from earlier FAILED replaces (kept on purpose) is swept now, best-effort.
        Remove-FastLlmStaleTemporaries -Folder $root -NamePattern '^[0-9a-f]{32}\.tmp$'
    } catch {
        # Typed marker: the supervisor classifies a state-write failure by this flag, never by message text.
        try { $_.Exception.Data['FastLlmStateWrite'] = $true } catch { }
        throw
    } finally {
        # Best-effort and never replaces the original error. A fully written temp is ALWAYS kept after a failed replace
        # (it may be the only copy; File.Exists on the destination cannot be trusted); only a partial write is removed.
        if ($temporary -and -not $written) { try { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue } } catch { } }
    }
}

function Get-FastLlmRecoveryPlan {
    param($Hardware,[string]$CatalogPath,[string]$InstallRoot,[string]$Profile,[string]$FailedModelId,[string]$RequestedModelId,[int]$ContextSize=0)
    # An explicit artifact is never substituted. Recovery never downloads or grants consent.
    if ($RequestedModelId) { return $null }
    $key=Get-FastLlmFingerprint $Hardware
    $path=Join-Path (Get-FastLlmStateRoot $InstallRoot) ($key+'.last-ready.json')
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)){return $null}
    try{
        $item=Get-Item -LiteralPath $path -Force
        if($item.Length -gt 16384 -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){return $null}
        $record=Read-FastLlmJson -Path $path -MaxBytes 16384
        if($record.kind -ne 'api-smoke-only' -or $record.hardwareFingerprint -ne $key -or $record.modelId -eq $FailedModelId){return $null}
        $digest=(Get-FileHash -LiteralPath $CatalogPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if($record.catalogSha256 -ne $digest){return $null}
        $plan=Get-FastLlmPlan -Hardware $Hardware -CatalogPath $CatalogPath -InstallRoot $InstallRoot -Profile $Profile -ModelId $record.modelId -ContextSize $ContextSize -Recovered
        if($plan.model.sha256 -ne $record.modelSha256 -or -not (Test-Path -LiteralPath $plan.modelPath -PathType Leaf) -or -not (Test-FastLlmModelConsentReceipt $plan.model $InstallRoot)){return $null}
        return $plan
    }catch{return $null}
}

function Enter-FastLlmOperation {
    param([string] $InstallRoot)
    $root = Get-FastLlmStateRoot -InstallRoot $InstallRoot -Create
    $path = Join-Path $root 'operation.lock'
    if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe lock path.' }
    try { return [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { throw 'Another FastLLM install/start operation is active for this installation.' }
    # Keep the lock file: unlinking it after close introduces an acquisition race.
}

function Get-FastLlmStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string] $InstallRoot)
    $root = Get-FastLlmStateRoot -InstallRoot $InstallRoot
    $path = Join-Path $root 'status.json'
    # The existence, size, reparse and read steps sit inside one bounded retry (~150 ms): ReplaceFile can briefly hide
    # the name from openers, which must never be reported as a phantom stopped state or thrown.
    $state = $null
    for ($attempt = 0; $null -eq $state; $attempt++) {
        $last = ($attempt -ge 9)
        try {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                if ($last) { return [pscustomobject]@{ phase='stopped'; active=$false } }
                Start-Sleep -Milliseconds 15
                continue
            }
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            # Attributes -1 (every bit set, including ReparsePoint) is the mid-replace transient: treat it as a missing name.
            if ([int]$item.Attributes -eq -1) {
                if ($last) { return [pscustomobject]@{ phase='stopped'; active=$false } }
                Start-Sleep -Milliseconds 15
                continue
            }
            # A real reparse point is unsafe at once (no retry). An over-cap size is judged by the bounded read below.
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Unsafe status document.' }
            $state = Read-FastLlmJson -Path $path -MaxBytes 65536
            if ($null -eq $state) { throw 'Status document was empty.' }
        } catch {
            # Unsafe verdicts (real reparse point, size over the cap on the opened handle) are final; only transients retry.
            if ($_.Exception.Message -ceq 'Unsafe status document.' -or $_.Exception.Data['FastLlmJsonTooLarge'] -eq $true) { throw }
            if ($last) {
                if ($_.Exception.Message -like 'JSON file was not found:*') { return [pscustomobject]@{ phase='stopped'; active=$false } }
                throw
            }
            Start-Sleep -Milliseconds 15
        }
    }
    $active = $false
    $lockPath = Join-Path $root 'operation.lock'
    if (Test-Path -LiteralPath $lockPath) {
        if ((Get-Item -LiteralPath $lockPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Unsafe lock path.' }
        $lock = $null
        try { $lock = [IO.File]::Open($lockPath, 'Open', 'ReadWrite', 'None') }
        catch { $active = $true }
        finally { if ($lock) { $lock.Dispose() } }
    }
    $state | Add-Member -NotePropertyName active -NotePropertyValue $active -Force
    if (-not $active -and $state.phase -in @('preparing','loading','checking','ready')) { $state.phase = 'interrupted' }
    return $state
}

function Request-FastLlmStop {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string] $InstallRoot)
    $state = Get-FastLlmStatus -InstallRoot $InstallRoot
    # A model switch in progress: the previous run has ended and its final document says the switch is pending. The supervisor is alive between
    # the two runs, so a stop is accepted; it names that run, and the switch (or the run that follows it) honours it.
    $switchInProgress = [bool] ($state.active -and $state.phase -in @('stopped','failed') -and $state.PSObject.Properties['switch'] -and $null -ne $state.switch -and
        $state.switch -is [System.Management.Automation.PSCustomObject] -and $state.switch.PSObject.Properties['pending'] -and $state.switch.pending -eq $true)
    if (-not $state.active -or ($state.phase -notin @('loading','checking','ready') -and -not $switchInProgress) -or -not $state.PSObject.Properties['runId'] -or $state.runId -notmatch '^[0-9a-f]{32}$') { throw 'There is no supervised server to stop. Cancel an in-progress installation in its owning window.' }
    $root = Get-FastLlmStateRoot -InstallRoot $InstallRoot
    $path = Join-Path $root ('stop-' + $state.runId)
    # Existence and reparse checks sit in a bounded retry so a concurrent create/delete of the request file is not an error.
    # Attributes -1 (the name vanished mid-check) is transient and retried; a real reparse point is refused at once.
    for ($attempt = 0; ; $attempt++) {
        try {
            if (Test-Path -LiteralPath $path) {
                $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
                if ([int]$item.Attributes -eq -1) { throw 'Stop request path was transient.' }
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Unsafe stop request path.' }
            } else {
                # Share Delete: the supervisor polls for this name and removes it on its way out, and it may do so while
                # this handle is still open; with Delete shared the removal succeeds and the name goes when this closes.
                $stream = $null
                try { $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Delete) }
                finally { if ($stream) { $stream.Dispose() } }
            }
            break
        } catch {
            if ($_.Exception.Message -ceq 'Unsafe stop request path.' -or $attempt -ge 9) { throw }
            Start-Sleep -Milliseconds 15
        }
    }
    Write-Host 'Stop requested. The owning supervisor will terminate its own server.'
}

# ---- supervised model switch (opt-in) ----
# A switch is asked for with a small request file, state\switch-<runId>.json (at most 4 KiB): schemaVersion 1, exactly one of modelId or recipeId,
# and force. Only a supervisor started with -AllowSwitch looks for it; every other start, the bench path included, never reads it. The supervisor
# that serves stops its own server and then runs a full normal start of the other model in the same process, with the one operation lock held
# throughout (Start-FastLlmServer owns that sequence). Stop always wins over a switch.
$script:FastLlmSwitchRequestMaxBytes = 4096
# How long a switch waits for requests in progress (requests_processing and requests_deferred both 0) before it is refused, and how often it looks.
$script:FastLlmSwitchBusyWaitSeconds = 60
$script:FastLlmSwitchBusyPollMilliseconds = 1000
$script:FastLlmSwitchIdPattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z'
$script:FastLlmSwitchCodePattern = '^[A-Za-z0-9][A-Za-z0-9-]{0,63}\z'

# The switch block of a status document: { from, to, result, failureCode }, plus pending = true while the outcome is not known yet.
function New-FastLlmSwitchBlock {
    param([string] $From, [string] $To, [switch] $Pending, [string] $Result, [string] $FailureCode)
    $block = [ordered] @{ from = $null; to = $null }
    if ($From) { $block.from = $From }
    if ($To) { $block.to = $To }
    if ($Pending) { $block.pending = $true }
    $block.result = $null
    $block.failureCode = $null
    if ($Result) { $block.result = $Result }
    if ($FailureCode) { $block.failureCode = $FailureCode }
    return $block
}

# Reads a switch request under the same safe-path rules as the stop file: the name is the supervisor's own (run id), a reparse point or a
# directory is never opened, and at most 4 KiB are read (checked on the opened handle). Returns { state, code, modelId, recipeId, force }:
# state ok, transient (the name is missing or mid-replace: look again on the next pass) or refused (with a code; no id is passed on).
function Read-FastLlmSwitchRequest {
    param([Parameter(Mandatory = $true)][string] $Path)
    $result = [ordered] @{ state = 'refused'; code = 'switch-request-invalid'; modelId = $null; recipeId = $null; force = $false }
    $attributes = Get-FastLlmStateFileAttributes -Path $Path
    if ($null -eq $attributes -or [int] $attributes -eq -1) { $result.state = 'transient'; $result.code = $null; return [pscustomobject] $result }
    if (([int] $attributes -band [int] [IO.FileAttributes]::ReparsePoint) -ne 0 -or ([int] $attributes -band [int] [IO.FileAttributes]::Directory) -ne 0) {
        $result.code = 'switch-request-unsafe'
        return [pscustomobject] $result
    }
    # At most 4 KiB are ever read, and the limit is checked on the OPENED handle (a name swapped after the look above cannot defeat it). The
    # handle shares Delete, so the writer's atomic replace is never blocked by this read.
    $limit = [int] $script:FastLlmSwitchRequestMaxBytes
    $text = $null
    $tooLarge = $false
    $stream = $null
    try {
        $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        if ($stream.Length -gt $limit) { $tooLarge = $true }
        else {
            $buffer = New-Object byte[] ($limit + 1)
            $total = 0
            while ($total -le $limit) {
                $count = $stream.Read($buffer, $total, ($limit + 1 - $total))
                if ($count -le 0) { break }
                $total += $count
            }
            if ($total -gt $limit) { $tooLarge = $true }
            else { $text = (New-Object Text.UTF8Encoding($false)).GetString($buffer, 0, $total) }
        }
    }
    catch {
        # The name went away or is held for a moment by its writer: not a refusal.
        $result.state = 'transient'; $result.code = $null
        return [pscustomobject] $result
    }
    finally { if ($stream) { $stream.Dispose() } }
    if ($tooLarge) { $result.code = 'switch-request-too-large'; return [pscustomobject] $result }
    # One JSON object, nothing else (Windows PowerShell 5.1 writes a byte order mark; an array is not a request in any PowerShell version).
    $text = $text.TrimStart([char] 0xFEFF)
    if (-not $text.TrimStart().StartsWith('{', [StringComparison]::Ordinal)) { return [pscustomobject] $result }
    $document = $null
    try { $document = ConvertFrom-Json -InputObject $text -ErrorAction Stop } catch { return [pscustomobject] $result }
    if ($null -eq $document -or $document -isnot [System.Management.Automation.PSCustomObject]) { return [pscustomobject] $result }
    $values = @{}
    foreach ($property in @($document.PSObject.Properties)) {
        if (@('schemaVersion', 'modelId', 'recipeId', 'force') -cnotcontains [string] $property.Name) { return [pscustomobject] $result }
        $values[[string] $property.Name] = $property.Value
    }
    if (-not ($values['schemaVersion'] -is [int] -or $values['schemaVersion'] -is [long]) -or [long] $values['schemaVersion'] -ne 1) { return [pscustomobject] $result }
    $ids = @{}
    foreach ($name in @('modelId', 'recipeId')) {
        if (-not $values.ContainsKey($name)) { continue }
        if ($values[$name] -isnot [string] -or $values[$name] -cnotmatch $script:FastLlmSwitchIdPattern) { return [pscustomobject] $result }
        $ids[$name] = [string] $values[$name]
    }
    if ($ids.Count -ne 1) { return [pscustomobject] $result }
    if ($values.ContainsKey('force') -and $values['force'] -isnot [bool]) { return [pscustomobject] $result }
    $result.state = 'ok'
    $result.code = $null
    if ($ids.ContainsKey('modelId')) { $result.modelId = $ids['modelId'] } else { $result.recipeId = $ids['recipeId'] }
    if ($values.ContainsKey('force')) { $result.force = [bool] $values['force'] }
    return [pscustomobject] $result
}

# Before anything is stopped: the target must be a model of the catalog that is installed, of the catalog size and consented (no hashing here; the
# full start hashes it). A recipe request names a non-experimental recipe and is checked through its model. Returns { ok, code, modelId, recipeId };
# modelId and recipeId are the catalog's and the recipe list's own spelling, never the request's text.
function Resolve-FastLlmSwitchTarget {
    param([Parameter(Mandatory = $true)][string] $CatalogPath, [Parameter(Mandatory = $true)][string] $InstallRoot, [string] $ModelId, [string] $RecipeId,
        [string] $CurrentModelId, [string] $CurrentRecipeId, [switch] $ServingProfileActive)
    $result = [ordered] @{ ok = $false; code = 'switch-target-unknown'; modelId = $null; recipeId = $null }
    try {
        $catalog = Get-FastLlmCatalog -CatalogPath $CatalogPath
        $targetModelId = $ModelId
        if ($RecipeId) {
            $recipe = @(Read-FastLlmRecipes -Path (Join-Path (Split-Path -Parent $CatalogPath) 'recipes.json') | Where-Object { [string] $_.id -eq $RecipeId } | Select-Object -First 1)
            if ($recipe.Count -ne 1) { return [pscustomobject] $result }
            $result.recipeId = [string] $recipe[0].id
            # The experimental gate (the switch plus -AcceptExperimental) lives in the command line, which a request file does not pass through.
            if (Test-FastLlmExperimentalOrigin -Origin ([string] $recipe[0].origin)) { $result.code = 'switch-recipe-experimental'; return [pscustomobject] $result }
            # A recipe is measured for the default context profile and one slot; the planner refuses the combination, so it is refused before the stop.
            if ($ServingProfileActive) { $result.code = 'switch-recipe-needs-default-options'; return [pscustomobject] $result }
            $targetModelId = ''
            if ($recipe[0].PSObject.Properties['components'] -and $recipe[0].components -and $recipe[0].components.PSObject.Properties['model']) { $targetModelId = [string] $recipe[0].components.model }
        }
        if (-not $targetModelId) { return [pscustomobject] $result }
        $model = @($catalog.models | Where-Object { [string] $_.id -eq $targetModelId } | Select-Object -First 1)
        if ($model.Count -ne 1) { return [pscustomobject] $result }
        $result.modelId = [string] $model[0].id
        if (($RecipeId -and $CurrentRecipeId -and [string] $result.recipeId -ceq $CurrentRecipeId) -or (-not $RecipeId -and $CurrentModelId -and [string] $result.modelId -ceq $CurrentModelId)) {
            $result.code = 'switch-target-already-serving'
            return [pscustomobject] $result
        }
        # Switching never goes to an experimental model (not auto-eligible): that start is made directly, with its own acceptance. Refused here, before
        # anything is stopped, rather than failing at the plan after the working server was stopped.
        $autoEligible = $model[0].PSObject.Properties['autoEligible']
        if ($autoEligible -and -not [bool] $autoEligible.Value) { $result.code = 'switch-target-experimental-model'; return [pscustomobject] $result }
        $modelsRoot = Join-FastLlmContainedPath -Root $InstallRoot -Child 'models' -Label 'Models root'
        $modelPath = Join-FastLlmContainedPath -Root $modelsRoot -Child ([string] $model[0].file) -Label 'Model file'
        if (-not (Test-Path -LiteralPath $modelPath -PathType Leaf)) { $result.code = 'switch-target-not-installed'; return [pscustomobject] $result }
        if ([int64] (Get-Item -LiteralPath $modelPath -Force).Length -ne [int64] $model[0].sizeBytes) { $result.code = 'switch-target-size-mismatch'; return [pscustomobject] $result }
        if (-not (Test-FastLlmModelConsentReceipt -Model $model[0] -InstallRoot $InstallRoot)) { $result.code = 'switch-target-no-consent'; return [pscustomobject] $result }
        $result.ok = $true
        $result.code = $null
    }
    catch { $result.ok = $false; $result.code = 'switch-target-check-failed' }
    return [pscustomobject] $result
}

# The plain sentence behind a refusal code, for the request writer (the supervisor never prints a request's own text).
function Get-FastLlmSwitchRefusalText {
    param([string] $Code, [string] $ModelId)
    $name = 'the requested model'
    if ($ModelId -and $ModelId -cmatch $script:FastLlmSwitchIdPattern) { $name = "'$ModelId'" }
    switch -CaseSensitive ($Code) {
        'switch-target-unknown' { return 'The requested model or recipe is not in FastLLM''s list. See the exact ids with: .\fast-llm.ps1 models -Installed' }
        'switch-target-not-installed' { return "The model $name is not downloaded. Install it first; a switch never downloads." }
        'switch-target-size-mismatch' { return "The file of the model $name is incomplete or damaged. Install it again first; a switch never downloads." }
        'switch-target-no-consent' { return "The license of the model $name has not been accepted on this PC. Install it first." }
        'switch-target-already-serving' { return "The model $name is already running." }
        'switch-target-experimental-model' { return "The model $name is experimental. An experimental model is started from the command line (start -ModelId ... -AllowExperimentalModel), not by a switch." }
        'switch-recipe-experimental' { return 'An experimental recipe is started from the command line (start -Recipe ... -AcceptExperimental), not by a switch.' }
        'switch-recipe-needs-default-options' { return 'A recipe is measured for the default context profile and one request at a time; this server runs with another setting.' }
        default { return 'The switch target could not be checked. Nothing was changed.' }
    }
}

# Asks the running supervisor for a model switch: writes state\switch-<runId>.json for the run that is ready. Refused at once, in plain words,
# when there is no ready server, when it was not started with model switching allowed, or when the target is not installed, consented and of the
# right size (the supervisor checks all of it again and never trusts this side).
function Request-FastLlmSwitch {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $InstallRoot, [Parameter(Mandatory = $true)][string] $CatalogPath, [string] $ModelId, [string] $RecipeId, [switch] $Force)
    if ([bool] $ModelId -eq [bool] $RecipeId) { throw 'A switch request names exactly one of a model id or a recipe id.' }
    $state = Get-FastLlmStatus -InstallRoot $InstallRoot
    if (-not $state.active -or [string] $state.phase -cne 'ready' -or -not $state.PSObject.Properties['runId'] -or $state.runId -notmatch '^[0-9a-f]{32}$') {
        throw 'There is no ready FastLLM server to switch. Wait until it is ready, or start the model with the start action.'
    }
    if (-not ($state.PSObject.Properties['switchAllowed'] -and $state.switchAllowed -eq $true)) {
        throw 'This FastLLM server was not started with model switching allowed, so it takes no switch request. Stop it, then start it with -SwitchAllowed.'
    }
    $currentModelId = ''
    if ($state.PSObject.Properties['modelId']) { $currentModelId = [string] $state.modelId }
    $currentRecipeId = ''
    if ($state.PSObject.Properties['planRecipe'] -and $state.planRecipe -and $state.planRecipe.PSObject.Properties['id'] -and $state.planRecipe.id) { $currentRecipeId = [string] $state.planRecipe.id }
    $profileActive = [bool] ($state.PSObject.Properties['recipe'] -and $state.recipe -and $state.recipe.PSObject.Properties['profile'])
    $target = Resolve-FastLlmSwitchTarget -CatalogPath $CatalogPath -InstallRoot $InstallRoot -ModelId $ModelId -RecipeId $RecipeId -CurrentModelId $currentModelId -CurrentRecipeId $currentRecipeId -ServingProfileActive:$profileActive
    if (-not $target.ok) { throw (New-FastLlmTypedFailure -Code ([string] $target.code) -Message ((Get-FastLlmSwitchRefusalText -Code ([string] $target.code) -ModelId ([string] $target.modelId)) + ' FastLLM did not switch.')) }
    $request = [ordered] @{ schemaVersion = 1 }
    if ($target.recipeId) { $request.recipeId = [string] $target.recipeId } else { $request.modelId = [string] $target.modelId }
    $request.force = [bool] $Force
    $leaf = 'switch-' + [string] $state.runId + '.json'
    $path = Join-Path (Get-FastLlmStateRoot -InstallRoot $InstallRoot) $leaf
    # Same rule as the stop request: a real reparse point (or a directory) at the request path is refused at once. A transient name is left to
    # the atomic replace below, which waits within its own budget.
    $attributes = Get-FastLlmStateFileAttributes -Path $path
    if ($null -ne $attributes -and [int] $attributes -ne -1 -and
        ((([int] $attributes -band [int] [IO.FileAttributes]::ReparsePoint) -ne 0) -or (([int] $attributes -band [int] [IO.FileAttributes]::Directory) -ne 0))) { throw 'Unsafe switch request path.' }
    Write-FastLlmState -InstallRoot $InstallRoot -State $request -FileName $leaf
    $shown = [string] $target.modelId
    if ($target.recipeId) { $shown = [string] $target.recipeId }
    Write-Host "Switch to '$shown' requested. The owning supervisor finishes the requests in progress, stops its server and starts the other model; this takes about one model load. See: .\fast-llm.ps1 status"
}

# Removes a consumed request file: a plain file only, never a reparse point or a directory, and never recursively. $true when the name is gone.
function Remove-FastLlmSwitchRequestFile {
    param([Parameter(Mandatory = $true)][string] $Path)
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        $attributes = Get-FastLlmStateFileAttributes -Path $Path
        if ($null -eq $attributes) { return (-not (Test-Path -LiteralPath $Path)) }
        if ([int] $attributes -ne -1) {
            if (([int] $attributes -band [int] [IO.FileAttributes]::ReparsePoint) -ne 0 -or ([int] $attributes -band [int] [IO.FileAttributes]::Directory) -ne 0) { return $false }
            try { [IO.File]::Delete($Path); return $true } catch { $null = $_ }
        }
        Start-Sleep -Milliseconds 15
    }
    return $false
}

# ---- the switch basis: the hardware reading a run's plan was built from ----
# While a model is loaded, the free memory of the card excludes it, so a fresh reading cannot say whether another model would fit once this one
# is gone (and adding the running model's use back would invent a fit). The honest input is the reading this run's own plan was built from:
# taken before this run's server loaded (for the target of a switch, after the old server stopped). A run that allows switching saves it once,
# at its start, to state\switch-basis-<runId>.json: schemaVersion 1, runId, capturedAt, hardware and planOptions (the serving options). Nothing else: no key, no prompt, no path
# outside the install. It is removed where the run's request file is removed. The window's model picker reads it, strictly.
$script:FastLlmSwitchBasisMaxBytes = 65536
$script:FastLlmSwitchBasisRunIdPattern = '^[0-9a-f]{32}\z'

# The serving options a basis may carry, checked against an allowlist of names, types and values (no path, no model, nothing else). Returns an
# ordered table of the checked values, or $null for an unknown name, a wrong type, an out-of-range value or a missing Profile.
function ConvertTo-FastLlmSwitchBasisPlanOptions {
    param($Options)
    if ($null -eq $Options) { return $null }
    $pairs = @()
    if ($Options -is [System.Collections.IDictionary]) { foreach ($key in @($Options.Keys)) { $pairs += , @([string] $key, $Options[$key]) } }
    elseif ($Options -is [System.Management.Automation.PSCustomObject]) { foreach ($property in @($Options.PSObject.Properties)) { $pairs += , @([string] $property.Name, $property.Value) } }
    else { return $null }
    $whole = { param($Value) return [bool] ($Value -is [int] -or $Value -is [long]) }
    $checked = [ordered] @{}
    foreach ($pair in $pairs) {
        $name = $pair[0]
        $value = $pair[1]
        switch -CaseSensitive ($name) {
            'Profile' { if ($value -isnot [string] -or @('fast', 'balanced', 'quality') -cnotcontains $value) { return $null }; $checked[$name] = [string] $value }
            'AllowExperimentalModel' { if ($value -isnot [bool]) { return $null }; $checked[$name] = [bool] $value }
            'ServerPort' { if (-not (& $whole $value) -or [long] $value -lt 1024 -or [long] $value -gt 65535) { return $null }; $checked[$name] = [int] $value }
            'Thinking' { if ($value -isnot [string] -or @('auto', 'off') -cnotcontains $value) { return $null }; $checked[$name] = [string] $value }
            'ChatPage' { if ($value -isnot [string] -or @('off', 'on') -cnotcontains $value) { return $null }; $checked[$name] = [string] $value }
            'KvContextProfile' { if ($value -isnot [string] -or @('default', 'long') -cnotcontains $value) { return $null }; $checked[$name] = [string] $value }
            'KvSlots' { if (-not (& $whole $value) -or @(1, 2) -notcontains [int] $value) { return $null }; $checked[$name] = [int] $value }
            'Vision' { if ($value -isnot [string] -or @('off', 'on') -cnotcontains $value) { return $null }; $checked[$name] = [string] $value }
            'Speculation' { if ($value -isnot [string] -or @('ngram', 'mtp') -cnotcontains $value) { return $null }; $checked[$name] = [string] $value }
            default { return $null }
        }
    }
    if (-not $checked.Contains('Profile')) { return $null }
    return $checked
}

# Saves the basis for a run. $true when it was written; $false (and no file) for a reading that is not a valid hardware reading, that would
# not fit in 64 KiB, or for a run id that is not a run id. Never throws: a basis is an aid to the window, never a reason a start fails.
function Write-FastLlmSwitchBasis {
    param([Parameter(Mandatory = $true)][string] $InstallRoot, [string] $RunId, $Hardware, $PlanOptions)
    try {
        if ($RunId -cnotmatch $script:FastLlmSwitchBasisRunIdPattern -or $null -eq $Hardware) { return $false }
        Assert-FastLlmHardware -Hardware $Hardware
        $checkedOptions = ConvertTo-FastLlmSwitchBasisPlanOptions -Options $PlanOptions
        if ($null -eq $checkedOptions) { return $false }
        $document = [ordered] @{ schemaVersion = 1; runId = $RunId; capturedAt = (Get-Date).ToUniversalTime().ToString('o'); hardware = $Hardware; planOptions = $checkedOptions }
        $size = (New-Object Text.UTF8Encoding($false)).GetByteCount((ConvertTo-Json -InputObject $document -Depth 12))
        # Room for the byte order mark Windows PowerShell 5.1 writes.
        if ($size -gt ($script:FastLlmSwitchBasisMaxBytes - 16)) { return $false }
        Write-FastLlmState -InstallRoot $InstallRoot -State $document -FileName ('switch-basis-' + $RunId + '.json')
        return $true
    }
    catch { return $false }
}

# Reads the basis of a run, strictly. Returns { schemaVersion, runId, capturedAt, hardware } or $null: a missing file, a file over 64 KiB, a
# reparse point or a directory, anything that is not exactly the document above, a runId that is not the run asked for, or hardware that does
# not pass Assert-FastLlmHardware. Never a partial object, never an error.
function Read-FastLlmSwitchBasis {
    param([Parameter(Mandatory = $true)][string] $InstallRoot, [string] $RunId)
    try {
        if ($RunId -cnotmatch $script:FastLlmSwitchBasisRunIdPattern) { return $null }
        $path = Join-Path (Get-FastLlmStateRoot -InstallRoot $InstallRoot) ('switch-basis-' + $RunId + '.json')
        $attributes = Get-FastLlmStateFileAttributes -Path $path
        if ($null -eq $attributes -or [int] $attributes -eq -1) { return $null }
        if (([int] $attributes -band [int] [IO.FileAttributes]::ReparsePoint) -ne 0 -or ([int] $attributes -band [int] [IO.FileAttributes]::Directory) -ne 0) { return $null }
        # At most 64 KiB are read, checked on the opened handle; the text must be one JSON object (a one-element array is not a basis).
        $text = $null
        $stream = $null
        try {
            $stream = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            if ($stream.Length -gt $script:FastLlmSwitchBasisMaxBytes) { return $null }
            $buffer = New-Object byte[] ($script:FastLlmSwitchBasisMaxBytes + 1)
            $total = 0
            while ($total -le $script:FastLlmSwitchBasisMaxBytes) {
                $count = $stream.Read($buffer, $total, ($script:FastLlmSwitchBasisMaxBytes + 1 - $total))
                if ($count -le 0) { break }
                $total += $count
            }
            if ($total -gt $script:FastLlmSwitchBasisMaxBytes) { return $null }
            $text = (New-Object Text.UTF8Encoding($false)).GetString($buffer, 0, $total)
        }
        finally { if ($stream) { $stream.Dispose() } }
        $text = $text.TrimStart([char] 0xFEFF)
        if (-not $text.TrimStart().StartsWith('{', [StringComparison]::Ordinal)) { return $null }
        $document = ConvertFrom-Json -InputObject $text -ErrorAction Stop
        if ($null -eq $document -or $document -isnot [System.Management.Automation.PSCustomObject]) { return $null }
        if ((@($document.PSObject.Properties.Name | Sort-Object) -join ',') -cne 'capturedAt,hardware,planOptions,runId,schemaVersion') { return $null }
        if (-not ($document.schemaVersion -is [int] -or $document.schemaVersion -is [long]) -or [long] $document.schemaVersion -ne 1) { return $null }
        if ($document.runId -isnot [string] -or $document.runId -cne $RunId) { return $null }
        # PowerShell 7 turns an ISO time into a date while reading; Windows PowerShell 5.1 leaves the text. Both are accepted, and the time is returned as ISO text.
        $capturedAt = [datetime]::MinValue
        $capturedText = $null
        if ($document.capturedAt -is [datetime]) { $capturedText = ([datetime] $document.capturedAt).ToUniversalTime().ToString('o') }
        elseif ($document.capturedAt -is [string] -and [datetime]::TryParse([string] $document.capturedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref] $capturedAt)) { $capturedText = [string] $document.capturedAt }
        else { return $null }
        if ($document.hardware -isnot [System.Management.Automation.PSCustomObject]) { return $null }
        Assert-FastLlmHardware -Hardware $document.hardware
        if ($document.planOptions -isnot [System.Management.Automation.PSCustomObject]) { return $null }
        $checkedOptions = ConvertTo-FastLlmSwitchBasisPlanOptions -Options $document.planOptions
        if ($null -eq $checkedOptions) { return $null }
        return [pscustomobject] [ordered] @{ schemaVersion = 1; runId = [string] $document.runId; capturedAt = $capturedText; hardware = $document.hardware; planOptions = ([pscustomobject] $checkedOptions) }
    }
    catch { return $null }
}

# True when a stop was asked for against a previous run of this start (a stop during a model switch names the run whose document was current).
function Test-FastLlmSwitchPriorStop {
    param([string[]] $Paths)
    foreach ($path in @($Paths)) { if ($path -and (Test-Path -LiteralPath $path)) { return $true } }
    return $false
}

function Remove-FastLlmSwitchPriorStop {
    param([string[]] $Paths)
    foreach ($path in @($Paths)) {
        if (-not $path) { continue }
        for ($attempt = 0; (Test-Path -LiteralPath $path) -and $attempt -lt 10; $attempt++) {
            try { Remove-Item -LiteralPath $path -Force -ErrorAction Stop } catch { Start-Sleep -Milliseconds 15 }
        }
    }
}

# One pass of the switch poll, called from the supervisor's post-Ready loop after the stop check. $Poll is the supervisor's own table
# ({ wait; unsafeReported; stuckStamp }). Returns $null (nothing to do) or { action; code; toModelId; recipeId; first }:
#   refused  the request is answered without touching the server (code: why; toModelId only when it is a catalog id)
#   waiting  a valid request waits for the requests in progress (first = $true on the pass that read it)
#   accept   the server is idle (or the request says force): the caller stops the server for the switch
# A request is consumed (removed) as soon as it is read: one request, one answer. An unsafe object is answered once and never opened.
function Step-FastLlmSwitchPoll {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary] $Poll, [Parameter(Mandatory = $true)][string] $RequestPath, [Parameter(Mandatory = $true)][string] $CatalogPath,
        [Parameter(Mandatory = $true)][string] $InstallRoot, [Parameter(Mandatory = $true)][string] $BaseUrl, [string] $CurrentModelId, [string] $CurrentRecipeId, [bool] $ServingProfileActive,
        # Replaces the sender of the /metrics read, as for the idle read: a start with the API key on passes the run's keyed sender (the server
        # then answers /metrics only with the key). Without it the read is the keyless one it always was. (Not named Request: this function
        # has a local of that name, and variable names are not case-sensitive.)
        [scriptblock] $MetricsRequest)
    $first = $false
    if ($null -eq $Poll['wait']) {
        if (-not (Test-Path -LiteralPath $RequestPath)) { $Poll['unsafeReported'] = $false; $Poll['stuckStamp'] = $null; return $null }
        $request = Read-FastLlmSwitchRequest -Path $RequestPath
        if ($request.state -ceq 'transient') { return $null }
        if ($request.code -ceq 'switch-request-unsafe') {
            if ($Poll['unsafeReported']) { return $null }
            $Poll['unsafeReported'] = $true
            return @{ action = 'refused'; code = 'switch-request-unsafe'; toModelId = $null; recipeId = $null; first = $true }
        }
        $Poll['unsafeReported'] = $false
        # A request that could not be removed after it was answered is not answered again while it is the same file.
        $stamp = $null
        try { $requestItem = Get-Item -LiteralPath $RequestPath -Force -ErrorAction Stop; $stamp = [string] $requestItem.LastWriteTimeUtc.Ticks + '|' + [string] $requestItem.Length } catch { $stamp = $null }
        if ($null -ne $Poll['stuckStamp'] -and $stamp -ceq [string] $Poll['stuckStamp']) { return $null }
        $Poll['stuckStamp'] = $null
        if (-not (Remove-FastLlmSwitchRequestFile -Path $RequestPath)) { $Poll['stuckStamp'] = $stamp }
        if ($request.state -cne 'ok') { return @{ action = 'refused'; code = [string] $request.code; toModelId = $null; recipeId = $null; first = $true } }
        $target = Resolve-FastLlmSwitchTarget -CatalogPath $CatalogPath -InstallRoot $InstallRoot -ModelId ([string] $request.modelId) -RecipeId ([string] $request.recipeId) `
            -CurrentModelId $CurrentModelId -CurrentRecipeId $CurrentRecipeId -ServingProfileActive:$ServingProfileActive
        if (-not $target.ok) { return @{ action = 'refused'; code = [string] $target.code; toModelId = $target.modelId; recipeId = $target.recipeId; first = $true } }
        $Poll['wait'] = @{ modelId = [string] $target.modelId; recipeId = $target.recipeId; force = [bool] $request.force; clock = [Diagnostics.Stopwatch]::StartNew(); nextPollMs = 0 }
        $first = $true
    }
    $wait = $Poll['wait']
    $step = @{ action = 'waiting'; code = $null; toModelId = [string] $wait.modelId; recipeId = $wait.recipeId; first = $first }
    if ($wait.force) { $Poll['wait'] = $null; $step.action = 'accept'; return $step }
    if ($wait.clock.ElapsedMilliseconds -ge [long] $wait.nextPollMs) {
        $wait.nextPollMs = [long] $wait.clock.ElapsedMilliseconds + [long] $script:FastLlmSwitchBusyPollMilliseconds
        # The idle detector's counters: a request that is processing or deferred is never cut off. A read that fails proves nothing, so it waits.
        $counters = $null
        # With the API key on the read carries the run's key (the same sender, and the same listener check, as the idle read); a read the
        # server refuses is a failed read like any other, so the request waits and is refused as busy, never forced through.
        try { $counters = ConvertFrom-FastLlmIdleMetrics -Text (Get-FastLlmIdleMetricsText -BaseUrl $BaseUrl -Request $MetricsRequest) } catch { $counters = $null }
        if ($null -ne $counters -and $counters.processing -eq 0 -and $counters.deferred -eq 0) { $Poll['wait'] = $null; $step.action = 'accept'; return $step }
        if ($wait.clock.Elapsed.TotalSeconds -ge [double] $script:FastLlmSwitchBusyWaitSeconds) { $Poll['wait'] = $null; $step.action = 'refused'; $step.code = 'refused-busy'; return $step }
    }
    if (-not $first) { return $null }
    return $step
}

# Sets the outcome of the switch block in a supervisor's state and writes the switch-result line of its run log.
function Set-FastLlmSwitchResult {
    param([Parameter(Mandatory = $true)] $State, [string] $InstallRoot, [Parameter(Mandatory = $true)][string] $Result, [string] $FailureCode)
    $block = $State['switch']
    $State['switch'] = New-FastLlmSwitchBlock -From ([string] $block.from) -To ([string] $block.to) -Result $Result -FailureCode $FailureCode
    Add-FastLlmRunLogEvent -InstallRoot $InstallRoot -State $State -Event 'switch-result' -Fields { Get-FastLlmRunLogSwitchResultFields -Result $Result -FailureCode $FailureCode }
}

# The failure code a failed switch start is recorded with: the code the failed run itself recorded (so both documents agree), else the typed code
# of the failure, else that run's status code, else a fixed code by reason. Never the failure's text.
function Get-FastLlmSwitchFailureCode {
    param($Exception, [string] $StatusCode)
    $reason = ''
    if ($null -ne $Exception -and $null -ne $Exception.Data) {
        foreach ($key in @('FastLlmSwitchFailureCode', 'FastLlmFailureCode')) {
            $value = $Exception.Data[$key]
            if ($value -is [string] -and $value -cmatch $script:FastLlmSwitchCodePattern) { return $value }
        }
        $reason = [string] $Exception.Data['FastLlmReason']
    }
    if ($StatusCode -and $StatusCode -cmatch $script:FastLlmSwitchCodePattern) { return $StatusCode }
    switch -CaseSensitive ($reason) {
        'PlanChanged' { return 'switch-plan-changed' }
        'ModelNeedsProvisioning' { return 'switch-model-invalid' }
        'RuntimeCheckFailed' { return 'startup-or-runtime-check-failed' }
        'StateWriteFailed' { return 'state-write-failed' }
        'PortInUse' { return 'port-in-use' }
    }
    return 'switch-start-failed'
}

# Between two runs of a switch no supervised run is alive to write the status document: this rewrites the switch block (and, for a stop, the stop
# reason) of the CURRENT document. Best-effort; the caller holds the operation lock.
function Set-FastLlmSwitchOutcome {
    param([Parameter(Mandatory = $true)][string] $InstallRoot, [Parameter(Mandatory = $true)] $Block, [string] $StopReason)
    try {
        $document = Get-FastLlmStatus -InstallRoot $InstallRoot
        if (-not $document.PSObject.Properties['runId']) { return }
        if ($document.PSObject.Properties['active']) { $document.PSObject.Properties.Remove('active') }
        $document | Add-Member -NotePropertyName 'switch' -NotePropertyValue $Block -Force
        if ($StopReason) { $document | Add-Member -NotePropertyName stopReason -NotePropertyValue $StopReason -Force }
        $document | Add-Member -NotePropertyName updatedAt -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
        Write-FastLlmState -InstallRoot $InstallRoot -State $document
    }
    catch { $null = $_ }
}

function ConvertFrom-FastLlmPlacementLog {
    [CmdletBinding()]
    param([string] $Text, [string[]] $Devices)
    $offloads = [regex]::Matches($Text, '(?m)^.*load_tensors: offloaded (\d+)/(\d+) layers to GPU\s*$')
    if ($offloads.Count -ne 1) { throw 'Missing or ambiguous layer-offload evidence.' }
    $loaded = [int] $offloads[0].Groups[1].Value
    $total = [int] $offloads[0].Groups[2].Value
    if ($total -le 0 -or $loaded -ne $total) { throw 'The engine did not report all model layers on GPU.' }
    $buffers = [regex]::Matches($Text, '(?m)^.*load_tensors:\s+(Vulkan\d+|ROCm\d+)\s+model buffer size\s*=\s*([0-9.]+) MiB\s*$')
    $reportedBuffers=@()
    foreach ($buffer in $buffers) {
        $size = [double]::Parse($buffer.Groups[2].Value, [Globalization.CultureInfo]::InvariantCulture)
        if ($size -le 0 -or [double]::IsInfinity($size) -or [double]::IsNaN($size)) { throw 'GPU model-buffer evidence must be positive and finite.' }
        $reportedBuffers+= [pscustomobject]@{device=$buffer.Groups[1].Value;sizeMiB=$size}
    }
    $reported = @($reportedBuffers | ForEach-Object { $_.device } | Select-Object -Unique)
    if($reported.Count -ne $buffers.Count){throw 'Duplicate GPU model-buffer evidence is ambiguous.'}
    if (@($Devices | Where-Object { $_ -notin $reported }).Count -or @($reported | Where-Object { $_ -notin $Devices }).Count) { throw 'Reported model-buffer devices do not match the selected devices.' }
    return [pscustomobject]@{ reportedLayers=$loaded; totalLayers=$total; devices=$reported; modelBufferMiB=$reportedBuffers; reportedAllLayers=$true; physicalResidencyVerified=$false }
}

function ConvertFrom-FastLlmStartupDiagnostics {
    [CmdletBinding()]
    param([string]$Text,[bool]$Overflow=$false,[string]$RequestedFlashAttention)
    $result=[ordered]@{
        status='missing';kvBuffers=@();computeBuffers=@()
        requestedFlashAttention=$RequestedFlashAttention
        reportedFlashAttentionMode=$null;reportedFlashAttentionResolved=$null
        allocationCoverage='partial: model, KV and compute buffer lines only; recurrent/state and other allocations are not captured'
        physicalResidencyVerified=$false
    }
    if($Overflow){$result.status='overflow';return [pscustomobject]$result}
    if([string]::IsNullOrWhiteSpace($Text)){return [pscustomobject]$result}
    if($Text.Length -gt 4096){$result.status='invalid';return [pscustomobject]$result}
    $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $kv=@();$compute=@();$flashMode=$null;$flashResolved=$null
    $lines=@($Text -split "`r?`n" | Where-Object { $_ })
    if($lines.Count -gt 32){$result.status='overflow';return [pscustomobject]$result}
    foreach($line in $lines){
        $kind=$null;$device=$null;$value=$null
        if($line -cmatch '^(kv|compute) (Vulkan\d+|ROCm\d+|CPU(?:_[A-Za-z0-9]+)?) ([0-9]+(?:\.[0-9]+)?)$'){
            $kind=$Matches[1];$device=$Matches[2]
            if(-not $seen.Add("$kind|$device")){$result.status='duplicate';return [pscustomobject]$result}
            $numeric=$Matches[3]
            $value=[double]0
            if($numeric.Length -gt 32 -or
                -not [double]::TryParse($numeric,[Globalization.NumberStyles]::AllowDecimalPoint,[Globalization.CultureInfo]::InvariantCulture,[ref]$value) -or
                $value -le 0 -or [double]::IsNaN($value) -or [double]::IsInfinity($value)){$result.status='invalid';return [pscustomobject]$result}
            $entry=[pscustomobject]@{device=$device;sizeMiB=$value}
            if($kind -eq 'kv'){$kv+= $entry}else{$compute+= $entry}
        }elseif($line -cmatch '^flash-mode (auto|enabled|disabled)$'){
            if(-not $seen.Add('flash-mode')){$result.status='duplicate';return [pscustomobject]$result}
            $flashMode=$Matches[1]
        }elseif($line -cmatch '^flash-resolved (enabled|disabled)$'){
            if(-not $seen.Add('flash-resolved')){$result.status='duplicate';return [pscustomobject]$result}
            $flashResolved=($Matches[1] -eq 'enabled')
        }else{$result.status='invalid';return [pscustomobject]$result}
    }
    # b10698 resolves Flash Attention support only for auto mode. An explicit
    # enabled/disabled mode paired with a resolution line is inconsistent.
    if($null -ne $flashResolved -and $flashMode -ne 'auto'){$result.status='invalid';return [pscustomobject]$result}
    $result.kvBuffers=$kv
    $result.computeBuffers=$compute
    $result.reportedFlashAttentionMode=$flashMode
    $result.reportedFlashAttentionResolved=$flashResolved
    $result.status='partial'
    if($result.kvBuffers.Count -and $result.computeBuffers.Count -and $null -ne $result.reportedFlashAttentionMode -and $null -ne $result.reportedFlashAttentionResolved){$result.status='captured'}
    return [pscustomobject]$result
}

function Invoke-FastLlmHttp {
    param([string] $BaseUrl, [string] $Path, $Body, [int] $TimeoutMs=5000, $ApiKeyHolder, $ApiKeyServer)
    Initialize-FastLlmProcessHost
    $json = if ($null -ne $Body) { ConvertTo-Json -InputObject $Body -Depth 12 -Compress } else { $null }
    # The key, when given in a holder, travels only as an Authorization header on this one loopback-only client; no other host is ever sent it.
    # It becomes text here, at the last hop. A plain string or a malformed key is refused (typed, no key text in the error).
    # -ApiKeyServer is the server process the key belongs to (process id and start time, as status.json records them). The key is sent only
    # after that process is confirmed to be the one listener on the port; without that confirmation nothing is sent.
    if ($null -ne $ApiKeyHolder) {
        $null = Get-FastLlmApiKeyId -ApiKeyHolder $ApiKeyHolder
        Assert-FastLlmApiKeyListener -BaseUrl $BaseUrl -ServerIdentity $ApiKeyServer
        # The check and the request are two steps, so the same check runs again when the request is over (answered or not). If the
        # listener is then not this run's server, the key may have gone to another program: api-key-listener-changed, which wins over
        # whatever the request itself returned or raised.
        $keyedResponse = $null
        $keyedFailure = $null
        try { $keyedResponse = [Bitworks.FastLlm.LoopbackHttp]::Request($BaseUrl + $Path, $json, $TimeoutMs, 1048576, (Get-FastLlmApiKeyText -ApiKeyHolder $ApiKeyHolder)) }
        catch { $keyedFailure = $_ }
        Assert-FastLlmApiKeyListenerAfterSend -BaseUrl $BaseUrl -ServerIdentity $ApiKeyServer -Answered:($null -eq $keyedFailure)
        if ($null -ne $keyedFailure) { throw $keyedFailure }
        return $keyedResponse
    }
    return [Bitworks.FastLlm.LoopbackHttp]::Request($BaseUrl + $Path, $json, $TimeoutMs, 1048576)
}

# ---- idle stop (opt-in) ----
# The server counts what it has processed on GET /metrics (enabled by the default arguments, so nothing about the arguments depends
# on this). The detector is pure: it takes the previous state, the new /metrics text (or $null when it could not be read), the time and
# the idle minutes, and returns the new state and whether to stop. It never stops on a failed read and the idle clock does not advance
# on one. A request that is processing or deferred is never cut off.
$script:FastLlmIdleCounterNames = @('llamacpp:prompt_tokens_total', 'llamacpp:tokens_predicted_total', 'llamacpp:requests_processing', 'llamacpp:requests_deferred')
$script:FastLlmIdlePollSeconds = 30
# One poll interval can add at most this much idle time, so a sleeping PC or a clock jump cannot count as hours of idleness.
$script:FastLlmIdleMaxStepSeconds = 120

# Returns $null unless all four counters are present and numeric. Tolerant of HELP/TYPE lines, blank lines, CRLF and labels.
function ConvertFrom-FastLlmIdleMetrics {
    param([AllowNull()][string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $found = @{}
    foreach ($line in ($Text -split "`n")) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) { continue }
        if ($trimmed -cmatch '^(llamacpp:[A-Za-z0-9_]+)(?:\{[^}]*\})?\s+([-+]?[0-9]+(?:\.[0-9]*)?(?:[eE][-+]?[0-9]+)?)(?:\s+-?[0-9]+)?$') {
            $name = $Matches[1]
            if ($script:FastLlmIdleCounterNames -contains $name -and -not $found.ContainsKey($name)) {
                $number = 0.0
                if ([double]::TryParse($Matches[2], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref] $number) -and -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number)) { $found[$name] = $number }
            }
        }
    }
    foreach ($required in $script:FastLlmIdleCounterNames) { if (-not $found.ContainsKey($required)) { return $null } }
    return [pscustomobject]@{
        promptTokens    = [double] $found['llamacpp:prompt_tokens_total']
        predictedTokens = [double] $found['llamacpp:tokens_predicted_total']
        processing      = [double] $found['llamacpp:requests_processing']
        deferred        = [double] $found['llamacpp:requests_deferred']
    }
}

function New-FastLlmIdleDetectorState {
    param([Parameter(Mandatory = $true)][datetime] $Now)
    return [pscustomobject]@{ lastPollUtc = $Now; lastActivityUtc = $Now; idleSeconds = 0.0; promptTokens = $null; predictedTokens = $null; failedReads = 0 }
}

function Step-FastLlmIdleDetector {
    param(
        [Parameter(Mandatory = $true)] $State,
        [AllowNull()][string] $MetricsText,
        [Parameter(Mandatory = $true)][datetime] $Now,
        [Parameter(Mandatory = $true)][int] $IdleMinutes
    )
    $metrics = ConvertFrom-FastLlmIdleMetrics -Text $MetricsText
    if ($null -eq $metrics) {
        # Unreadable: no activity is assumed and no idle time is added. The time since the last poll is not counted later either.
        $failed = [pscustomobject]@{ lastPollUtc = $Now; lastActivityUtc = $State.lastActivityUtc; idleSeconds = [double] $State.idleSeconds; promptTokens = $State.promptTokens; predictedTokens = $State.predictedTokens; failedReads = ([int] $State.failedReads + 1) }
        return [pscustomobject]@{ state = $failed; shouldStop = $false; readFailed = $true; activity = $false }
    }
    $elapsed = ($Now - [datetime] $State.lastPollUtc).TotalSeconds
    if ($elapsed -lt 0) { $elapsed = 0 }
    if ($elapsed -gt $script:FastLlmIdleMaxStepSeconds) { $elapsed = $script:FastLlmIdleMaxStepSeconds }
    $activity = ($metrics.processing -gt 0 -or $metrics.deferred -gt 0)
    if ($null -ne $State.promptTokens -and ($metrics.promptTokens -ne [double] $State.promptTokens -or $metrics.predictedTokens -ne [double] $State.predictedTokens)) { $activity = $true }
    $idleSeconds = [double] $State.idleSeconds
    $lastActivity = $State.lastActivityUtc
    if ($activity) { $idleSeconds = 0.0; $lastActivity = $Now }
    elseif ($null -ne $State.promptTokens) { $idleSeconds += $elapsed }
    $next = [pscustomobject]@{ lastPollUtc = $Now; lastActivityUtc = $lastActivity; idleSeconds = $idleSeconds; promptTokens = $metrics.promptTokens; predictedTokens = $metrics.predictedTokens; failedReads = 0 }
    $stop = ($IdleMinutes -gt 0 -and -not $activity -and $metrics.processing -eq 0 -and $metrics.deferred -eq 0 -and $idleSeconds -ge ($IdleMinutes * 60))
    return [pscustomobject]@{ state = $next; shouldStop = [bool] $stop; readFailed = $false; activity = [bool] $activity }
}

# GET /metrics on the loopback address with a short timeout (250 ms, so a poll never delays the loop's stop check by more than that;
# a read that times out is a failed read, which never stops the server). Only a 200 body counts; anything else is $null (a failed read).
# -Request replaces the sender (a start with the API key on passes the one that attaches the run's key; /metrics needs the key then).
# -Result, when given, receives the HTTP status of the read (0 when there was no answer), so a refused read (401) can be told apart.
function Get-FastLlmIdleMetricsText {
    param([Parameter(Mandatory = $true)][string] $BaseUrl, [scriptblock] $Request, [System.Collections.IDictionary] $Result)
    if ($null -ne $Result) { $Result['status'] = 0 }
    if ($Request) { $response = & $Request '/metrics' $null 250 }
    else { $response = Invoke-FastLlmHttp -BaseUrl $BaseUrl -Path '/metrics' -TimeoutMs 250 }
    if ($null -ne $Result -and $null -ne $response) { $Result['status'] = [int] $response.Status }
    if ($null -ne $response -and $response.Status -eq 200) { return [string] $response.Body }
    return $null
}

# One poll: a fetch that throws or returns nothing is a failed read.
function Invoke-FastLlmIdleStopPoll {
    param(
        [Parameter(Mandatory = $true)] $State,
        [Parameter(Mandatory = $true)][scriptblock] $Fetch,
        [Parameter(Mandatory = $true)][datetime] $Now,
        [Parameter(Mandatory = $true)][int] $IdleMinutes
    )
    $text = $null
    try { $text = & $Fetch } catch { $text = $null }
    return (Step-FastLlmIdleDetector -State $State -MetricsText ([string] $text) -Now $Now -IdleMinutes $IdleMinutes)
}

# -ContextSize is the context ONE request gets and -Slots the slot count the server must report. A default plan passes the plan context and
# one slot (the check it always was); a plan with a serving profile passes total / slots and its slot count.
function Test-FastLlmApiCanary {
    [CmdletBinding()]
    param([string] $BaseUrl, [string] $ModelId, [int] $ContextSize, [ValidateSet(1, 2)][int] $Slots = 1,
          # Replaces the sender (path, body, timeout in ms), as in the self-test. A start with the API key on passes the one that attaches the run's key.
          [scriptblock] $Request)
    $send = { param($CanaryPath, $CanaryBody, $CanaryTimeoutMs)
        if ($Request) { return (& $Request $CanaryPath $CanaryBody $CanaryTimeoutMs) }
        return (Invoke-FastLlmHttp -BaseUrl $BaseUrl -Path $CanaryPath -Body $CanaryBody -TimeoutMs $CanaryTimeoutMs) }
    $models = & $send '/v1/models' $null 5000
    if ($models.Status -ne 200 -or @((ConvertFrom-Json $models.Body).data | Where-Object { $_.id -eq $ModelId }).Count -ne 1) { throw 'Served model identity does not match the plan.' }
    $props = & $send '/props' $null 5000
    if ($props.Status -ne 200) { throw 'Server properties are unavailable.' }
    $properties = ConvertFrom-Json $props.Body
    if ([int]$properties.default_generation_settings.n_ctx -ne $ContextSize -or [int]$properties.total_slots -ne $Slots) { throw 'Effective context/slots differ from the requested configuration.' }
    $firstToken = $null
    for ($i=0; $i -lt 2; $i++) {
        $answer = & $send '/completion' @{
            prompt='The capital of France is'; n_predict=1; temperature=0; seed=42; cache_prompt=$false; return_tokens=$true; ignore_eos=$true; stream=$false
        } 30000
        if ($answer.Status -ne 200) { throw 'One-token inference canary failed.' }
        $data = ConvertFrom-Json $answer.Body
        if (@($data.tokens).Count -ne 1 -or [long]$data.tokens[0] -lt 0) { throw 'One-token canary returned an invalid token.' }
        if ($i -eq 0) { $firstToken = [long]$data.tokens[0] }
        elseif ([long]$data.tokens[0] -ne $firstToken) { throw 'Greedy one-token canary was not repeatable.' }
    }
    $chat = & $send '/v1/chat/completions' @{
        model=$ModelId; messages=@(@{role='user';content='Say hello.'}); max_tokens=8; temperature=0; seed=42; stream=$false
    } 30000
    if ($chat.Status -ne 200) { throw 'Synchronous OpenAI chat canary failed.' }
    $chatData = ConvertFrom-Json $chat.Body
    if (@($chatData.choices).Count -ne 1) { throw 'Synchronous chat returned an invalid choice count.' }
    $message = $chatData.choices[0].message
    if ($message.role -ne 'assistant') { throw 'Synchronous chat returned an invalid role.' }
    $chatText = $false
    foreach ($key in @('content','reasoning_content','reasoning')) {
        $property = $message.PSObject.Properties[$key]
        if ($property -and -not [string]::IsNullOrEmpty([string]$property.Value)) { $chatText=$true }
    }
    if (-not $chatText) { throw 'Synchronous chat returned no text.' }
    $stream = & $send '/v1/chat/completions' @{
        model=$ModelId; messages=@(@{role='user';content='Say hello.'}); max_tokens=8; temperature=0; seed=42; stream=$true
    } 30000
    if ($stream.Status -ne 200) { throw 'OpenAI streaming canary failed.' }
    $hasText = $false; $done = $false
    foreach ($line in ($stream.Body -split "`r?`n")) {
        if ($line -eq 'data: [DONE]') { $done=$true; continue }
        if ($line.StartsWith('data: ')) {
            $event = $line.Substring(6) | ConvertFrom-Json
            foreach ($choice in @($event.choices)) {
                foreach ($key in @('content','reasoning_content','reasoning')) {
                    $property = $choice.delta.PSObject.Properties[$key]
                    if ($property -and -not [string]::IsNullOrEmpty([string]$property.Value)) { $hasText=$true }
                }
            }
        }
    }
    if (-not $done -or -not $hasText) { throw 'Streaming canary lacked text or its completion marker.' }
    return [pscustomobject]@{ modelIdentity=$true; effectiveContext=$ContextSize; repeatableToken=$true; synchronousChat=$true; streaming=$true; semanticCorrectnessQualified=$false }
}

function ConvertFrom-FastLlmServerDeviceListEntries {
    # Parses the normalized, already-validated lines the ProcessHost retains ("device-info NAME TOTAL FREE DESC" and
    # "using-device NAME ID FREE DESC"). Fields only, never raw lines: at most 16 entries each, printable ASCII, descriptions capped at 128.
    param([string]$DeviceInfoText,[string]$UsingDeviceText)
    $clean={ param([string]$Value) $text=[regex]::Replace($Value,'[^\x20-\x7e]','?'); if($text.Length -gt 128){$text=$text.Substring(0,128)}; $text }
    $deviceInfo=New-Object System.Collections.Generic.List[object]
    foreach($line in @($DeviceInfoText -split "`r?`n")) {
        if($deviceInfo.Count -ge 16){break}
        $parts=$line.Split(' ',5)
        if($parts.Count -ne 5 -or $parts[0] -cne 'device-info' -or $parts[2] -notmatch '^[0-9]{1,12}$' -or $parts[3] -notmatch '^[0-9]{1,12}$'){continue}
        $deviceInfo.Add([ordered]@{name=(& $clean $parts[1]); description=(& $clean $parts[4]); totalMiB=[long]$parts[2]; freeMiB=[long]$parts[3]})
    }
    $usingDevice=New-Object System.Collections.Generic.List[object]
    foreach($line in @($UsingDeviceText -split "`r?`n")) {
        if($usingDevice.Count -ge 16){break}
        $parts=$line.Split(' ',5)
        if($parts.Count -ne 5 -or $parts[0] -cne 'using-device' -or $parts[3] -notmatch '^[0-9]{1,12}$'){continue}
        $usingDevice.Add([ordered]@{name=(& $clean $parts[1]); id=(& $clean $parts[2]); freeMiB=[long]$parts[3]; description=(& $clean $parts[4])})
    }
    [pscustomobject]@{deviceInfo=$deviceInfo.ToArray(); usingDevice=$usingDevice.ToArray()}
}

# The plain refusal for an occupied loopback port. FastLlmFailureCode lets the CLI and the status file name it; FastLlmReason = PortInUse
# keeps it out of model recovery and out of the start-time fallback (a stand-in server would need the same port).
function New-FastLlmPortInUseFailure {
    param([Parameter(Mandatory = $true)][int] $Port)
    $failure = New-Object -TypeName System.InvalidOperationException -ArgumentList ("Port $Port is already in use, so FastLLM did not start. If FastLLM is already running in the background, use Attach running. Otherwise close the program that uses port $Port, or choose another port in FastLLM's settings.")
    $failure.Data['FastLlmFailureCode'] = 'port-in-use'
    $failure.Data['FastLlmReason'] = 'PortInUse'
    return $failure
}

# Throws the port-in-use failure when anything listens on the port. Two checks: the listener table (any address: 127.0.0.1, 0.0.0.0,
# ::1 or ::, which an exclusive loopback bind alone can miss), then today's exclusive trial bind of 127.0.0.1. A listener-table read
# error fails closed. -ListenerProvider replaces the table read in tests: a scriptblock returning IPEndPoint-like objects (Port).
function Assert-FastLlmLoopbackPortFree {
    param([Parameter(Mandatory = $true)][int] $Port, [scriptblock] $ListenerProvider)
    $occupied = $false
    try {
        if ($ListenerProvider) { $listeners = @(& $ListenerProvider) }
        else { $listeners = @([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()) }
        foreach ($endpoint in $listeners) { if ($null -ne $endpoint -and [int] $endpoint.Port -eq $Port) { $occupied = $true; break } }
    }
    catch { $occupied = $true }
    if (-not $occupied) {
        $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
        try { $listener.Server.ExclusiveAddressUse = $true; $listener.Start() }
        catch { $occupied = $true }
        finally { try { $listener.Stop() } catch { } }
    }
    if ($occupied) { throw (New-FastLlmPortInUseFailure -Port $Port) }
}

# llama-server's own bind error: "couldn't bind HTTP server socket, hostname: 127.0.0.1, port: <n>" (the same text at both engine pins).
# It takes the process host, not its output: what an engine prints can echo what an app sent it, and PowerShell module logging can record
# every parameter value of a command. The output is matched in place and handed to no command.
function Test-FastLlmServerBindFailure {
    param([Parameter(Mandatory = $true)] $HostProcess, [Parameter(Mandatory = $true)][int] $Port)
    return [regex]::IsMatch([string] $HostProcess.Snapshot(), ("couldn't bind HTTP server socket, hostname: 127\.0\.0\.1, port: $Port(?![0-9])"))
}

# A typed device-binding failure (enforce). FastLlmFailureCode is the failure code, FastLlmReason = DeviceBindingFailed is what keeps it
# out of model recovery (the supervisor's catch keeps both; fast-llm.ps1 retries only RuntimeCheckFailed, PlanChanged and
# ModelNeedsProvisioning, and rethrows this one).
# The one definition of a conforming device-binding failure code; anything else is device-binding-unavailable. Shared by the factory
# below and the supervisor's catch so the two cannot drift.
function ConvertTo-FastLlmDeviceBindingCode {
    param([string] $Code)
    if ($Code -cnotmatch '^device-binding-[a-z-]{1,40}$') { return 'device-binding-unavailable' }
    return $Code
}

function New-FastLlmDeviceBindingFailure {
    param([Parameter(Mandatory = $true)][string] $Code, [Parameter(Mandatory = $true)][string] $Message)
    # A code outside the pattern never becomes the exception's code or message prefix (the CLI prints the message).
    $Code = ConvertTo-FastLlmDeviceBindingCode -Code $Code
    $exception = New-FastLlmTypedFailure -Code $Code -Message $Message
    $exception.Data['FastLlmReason'] = 'DeviceBindingFailed'
    return $exception
}

# The ONE child-environment builder, used by the device probe and by the server launch. It returns what to remove from the inherited environment
# and what to set; Initialize-FastLlmEngineStartInfo applies it. -Plan needs backend, enginePath and (HIP only) runtimeRoots.
#   Vulkan: the shared scrub, APPDATA/PROGRAMDATA in the run sandbox, PATH = <engine dir>;System32;SystemRoot, and the BAR variable only on request.
# The PATH only decides among PATH entries: Windows searches the application directory (the engine directory, which holds amdhip64_7, amd_comgr and
# rocm_kpack), then System32, then the Windows directory, and PATH after those. A same-named library in System32 would therefore win over a runtime bin
# entry, whatever the PATH order is.
#   HIP:    the same scrub plus every ROC* name, then PATH = <engine dir>;<runtime roots...>;System32;SystemRoot. Never the BAR variable and never any HIP_*, ROC* or HSA_* value.
# Names scrubbed from a HIP child in addition to the shared scrub: the ROCm/HSA-adjacent ROC* family (ROCR_VISIBLE_DEVICES), the hipBLAS/hipBLASLt/rocBLAS
# library-path and logging overrides (HIPBLAS*, HIPBLASLT_TENSILE_LIBPATH, MIOPEN_*), the CLR/COMGR switches (AMD_*, GPU_*, HCC_*, HIPCC_*) and the device-lib path.
function Test-FastLlmHipEnvironmentName {
    param([Parameter(Mandatory = $true)][string] $Name)
    return [bool] ($Name -like 'ROC*' -or $Name -like 'HIPBLAS*' -or $Name -like 'MIOPEN_*' -or $Name -like 'AMD_*' -or $Name -like 'GPU_*' -or
        $Name -like 'HCC_*' -or $Name -like 'HIPCC_*' -or $Name -like 'HIPRTC_*' -or $Name -like 'ORIGAMI_*' -or $Name -ieq 'DEVICE_LIB_PATH')
}

function Get-FastLlmEngineEnvironment {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Plan, [Parameter(Mandatory = $true)] $Sandbox, [string[]] $InheritedNames = @(), [switch] $VulkanBarMitigation, [string] $SystemRoot, $ApiKeyHolder)
    $enginePath = [string] $Plan.enginePath
    # Split-Path as both call sites always used it. Off Windows (a pre-filter run on a Windows-style path) it would rewrite the separators, so cut by hand.
    if ($env:OS -eq 'Windows_NT') { $engineDirectory = Split-Path -Parent $enginePath }
    else {
        $separator = $enginePath.LastIndexOfAny([char[]] @('\', '/'))
        $engineDirectory = if ($separator -gt 0) { $enginePath.Substring(0, $separator) } else { '' }
    }
    $isHip = $false
    if ($Plan.PSObject.Properties['backend'] -and ([string] $Plan.backend) -ieq 'hip') { $isHip = $true }
    $remove = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in @($InheritedNames)) {
        if ((Test-FastLlmEnvironmentNameRequiresClearing -Name ([string] $name)) -or ($isHip -and (Test-FastLlmHipEnvironmentName -Name ([string] $name)))) { $remove.Add([string] $name) }
    }
    $set = [ordered] @{}
    $set['APPDATA'] = [string] $Sandbox.appData
    $set['PROGRAMDATA'] = [string] $Sandbox.programData
    if (-not $PSBoundParameters.ContainsKey('SystemRoot')) { $SystemRoot = [string] $env:SystemRoot }
    if (($env:OS -eq 'Windows_NT' -or $PSBoundParameters.ContainsKey('SystemRoot')) -and [string]::IsNullOrWhiteSpace($SystemRoot)) {
        # Never leave PATH inherited: ask Windows, or fail closed.
        $SystemRoot = [Environment]::GetFolderPath('Windows')
        if ([string]::IsNullOrWhiteSpace($SystemRoot)) { throw 'The Windows directory is not known, so the engine search path cannot be built. Nothing was started.' }
    }
    if ($env:OS -eq 'Windows_NT' -or $PSBoundParameters.ContainsKey('SystemRoot')) {
        $searchPath = New-Object 'System.Collections.Generic.List[string]'
        $searchPath.Add($engineDirectory)
        if ($isHip) {
            $planRuntimeRoots = @()
            if ($Plan.PSObject.Properties['runtimeRoots'] -and $null -ne $Plan.runtimeRoots) { $planRuntimeRoots = @($Plan.runtimeRoots) }
            foreach ($runtimeRoot in $planRuntimeRoots) { if (-not [string]::IsNullOrWhiteSpace([string] $runtimeRoot)) { $searchPath.Add([string] $runtimeRoot) } }
        }
        $searchPath.Add("$SystemRoot\System32")
        $searchPath.Add($SystemRoot)
        $set['PATH'] = $searchPath.ToArray() -join ';'
    }
    # The BAR variable is a Vulkan-lane switch: a HIP plan never receives it, whatever the caller asked for.
    if ($VulkanBarMitigation -and -not $isHip) { $set[$script:FastLlmVulkanBarMitigationVariable] = '1' }
    # The optional run key reaches the server child through its environment only (never its arguments), after an inherited LLAMA_API_KEY was
    # scrubbed above. The device probe never passes -ApiKeyHolder, so it never receives one.
    # The text is taken from the holder here (the use point) and is validated: a value llama-server would split or mangle is refused.
    if ($null -ne $ApiKeyHolder) { $set['LLAMA_API_KEY'] = Get-FastLlmApiKeyText -ApiKeyHolder $ApiKeyHolder }
    return [pscustomobject] [ordered] @{ remove = $remove.ToArray(); set = $set }
}

function Initialize-FastLlmEngineStartInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Diagnostics.ProcessStartInfo] $StartInfo, [Parameter(Mandatory = $true)] $Plan, [Parameter(Mandatory = $true)] $Sandbox, [switch] $VulkanBarMitigation, $ApiKeyHolder)
    $environment = Get-FastLlmEngineEnvironment -Plan $Plan -Sandbox $Sandbox -InheritedNames @($StartInfo.EnvironmentVariables.Keys | ForEach-Object { [string] $_ }) -VulkanBarMitigation:$VulkanBarMitigation -ApiKeyHolder $ApiKeyHolder
    foreach ($name in $environment.remove) { $StartInfo.EnvironmentVariables.Remove($name) }
    foreach ($name in $environment.set.Keys) { $StartInfo.EnvironmentVariables[[string] $name] = [string] $environment.set[$name] }
}

# Decimal NTSTATUS values as Int32 (Process.ExitCode): STATUS_INVALID_IMAGE_HASH 0xC0000428 and STATUS_DLL_NOT_FOUND 0xC0000135.
# Win32 errors 4551 and 1260 (application-control policy blocks such as Smart App Control or WDAC) can surface from the process start itself.
# Returns a typed exception, or $null when neither a policy block nor a missing DLL explains the failure. The reason is deliberately not
# RuntimeCheckFailed: model recovery would re-plan onto the built-in Vulkan engine, which is the silent fallback this lane forbids.
# True when a HIP plan was picked automatically from a measured recipe and has not itself fallen back: a failed start of such a plan is
# followed by one visible start of the Vulkan setup. An explicit recipe, a plan that already fell back and a non-HIP plan never are.
function Test-FastLlmPlanFallsBackOnFailure {
    param($Plan)
    if ($null -eq $Plan) { return $false }
    if (-not ($Plan.PSObject.Properties['backend'] -and ([string] $Plan.backend) -ieq 'hip')) { return $false }
    if (-not ($Plan.PSObject.Properties['recipe'] -and $Plan.recipe -and $Plan.recipe.PSObject.Properties['id'] -and -not [string]::IsNullOrWhiteSpace([string] $Plan.recipe.id))) { return $false }
    if ($Plan.PSObject.Properties['requestedRecipeId'] -and -not [string]::IsNullOrWhiteSpace([string] $Plan.requestedRecipeId)) { return $false }
    if ($Plan.PSObject.Properties['fallback'] -and $Plan.fallback) { return $false }
    return $true
}

function New-FastLlmHipLaunchFailure {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $ComponentId, [object] $ExitCode, [object] $NativeErrorCode, [switch] $ServerWasRunning, [switch] $AutoSelected)
    $blocked = $false
    $missing = $false
    $detail = $null
    if ($null -ne $NativeErrorCode -and [int] $NativeErrorCode -in @(4551, 1260, 577)) { $blocked = $true; $detail = "Windows error $([int] $NativeErrorCode)" }
    elseif ($null -ne $ExitCode -and [int] $ExitCode -eq -1073740760) { $blocked = $true; $detail = 'exit status 0xC0000428, STATUS_INVALID_IMAGE_HASH' }
    elseif ($null -ne $ExitCode -and [int] $ExitCode -eq -1073741515) { $missing = $true; $detail = 'exit status 0xC0000135, STATUS_DLL_NOT_FOUND' }
    if (-not $blocked -and -not $missing) { return $null }
    $stopped = 'The server was stopped.'
    $vulkan = 'FastLLM does not switch to Vulkan on its own. To use the Vulkan setup instead, start FastLLM without the HIP recipe (choose a Vulkan setup).'
    if ($AutoSelected) { $vulkan = 'FastLLM tries the Vulkan setup instead.' }
    if ($blocked) {
        $code = 'hip-dll-blocked'
        $text = "Windows blocked a DLL of the HIP engine component '${ComponentId}' from loading ($detail). Smart App Control or an application-control policy (WDAC) rejects unsigned files. $stopped $vulkan"
    }
    else {
        $code = 'hip-dll-missing'
        $text = "The HIP engine component '${ComponentId}' could not find a DLL it needs ($detail). Reinstall the engine and its runtime component. $stopped $vulkan"
    }
    $failure = New-FastLlmTypedFailure -Code $code -Message $text
    $failure.Data['FastLlmComponentId'] = $ComponentId
    $failure.Data['FastLlmReason'] = 'HipDllFailed'
    return $failure
}

# Smart App Control state, read-only: HKLM\SYSTEM\CurrentControlSet\Control\CI\Policy VerifiedAndReputablePolicyState (1 = enforcement on).
# 'enforced', 'off' (0 or evaluation) or 'unknown' (not Windows, or the value is unreadable). A module-level function so tests can replace the read.
function Get-FastLlmSmartAppControlState {
    if ($env:OS -ne 'Windows_NT') { return 'unknown' }
    try {
        $policy = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name 'VerifiedAndReputablePolicyState' -ErrorAction Stop
        $value = $policy.VerifiedAndReputablePolicyState
        if ($value -isnot [int] -and $value -isnot [long]) { return 'unknown' }
        if ([int64] $value -eq 1) { return 'enforced' }
        return 'off'
    }
    catch { return 'unknown' }
}

# The HIP device probe found no usable backend: it did not list a single ROCm<N> device, timed out, exited non-zero or could not start.
# Upstream b11658 prints "Available devices:" and "(none)" with exit 0 and empty stderr when ggml-hip.dll (or an AMD DLL it loads) cannot load,
# so this is not an exit code. Only independent evidence upgrades it to hip-dll-blocked: Smart App Control enforcement is on AND the engine
# started cleanly but listed no ROCm device. The reason is never RuntimeCheckFailed (model recovery would re-plan onto Vulkan).
function New-FastLlmHipBackendFailure {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $ComponentId, [Parameter(Mandatory = $true)][ValidateSet('no-device', 'timeout', 'exit', 'start')][string] $Cause, [object] $ExitCode)
    $vulkan = 'FastLLM did not switch to Vulkan: use the Vulkan setup instead (start FastLLM without the HIP recipe).'
    if ($Cause -ceq 'no-device' -and (Get-FastLlmSmartAppControlState) -ceq 'enforced') {
        $failure = New-FastLlmTypedFailure -Code 'hip-dll-blocked' -Message "The HIP engine component '${ComponentId}' listed no ROCm device, and Smart App Control is on. Smart App Control blocks unsigned DLLs, and the AMD runtime DLLs are unsigned, so Windows most likely refused to load them. Nothing was started. $vulkan"
        $failure.Data['FastLlmReason'] = 'HipDllFailed'
    }
    else {
        $what = switch ($Cause) {
            'no-device' { 'listed no ROCm device' }
            'timeout' { 'did not finish listing its devices in time' }
            'exit' { "exited with status $ExitCode while listing its devices" }
            default { 'could not be started' }
        }
        $failure = New-FastLlmTypedFailure -Code 'hip-backend-unavailable' -Message "The HIP engine component '${ComponentId}' $what, so the HIP backend is not usable. Likely causes: an AMD runtime DLL could not load (blocked by Smart App Control or WDAC, or damaged), or the AMD driver does not expose HIP for this card. Reinstall the HIP components, update the AMD driver, or choose the Vulkan setup. Nothing was started. $vulkan"
        $failure.Data['FastLlmReason'] = 'HipBackendUnavailable'
    }
    $failure.Data['FastLlmComponentId'] = $ComponentId
    return $failure
}

# The Win32 error carried by a process-start failure, if any (PowerShell wraps the .NET exception, so the chain is walked).
function Get-FastLlmNativeErrorCode {
    param($Exception)
    $current = $Exception
    for ($depth = 0; $null -ne $current -and $depth -lt 8; $depth++) {
        if ($current -is [System.ComponentModel.Win32Exception]) { return [int] $current.NativeErrorCode }
        $current = $current.InnerException
    }
    return $null
}

# The serving profile of a plan (opt-in context profile or slots) as checked values, or $null for a plan without one. A block outside the
# closed values, or whose per-slot context is not the plan context divided by its slots, is a typed failure: such a plan is never started.
function Get-FastLlmPlanServingProfile {
    param($Plan)
    if ($null -eq $Plan -or -not $Plan.PSObject.Properties['servingProfile'] -or $null -eq $Plan.servingProfile) { return $null }
    $block = $Plan.servingProfile
    $values = @{}
    foreach ($name in @('id', 'slots', 'contextPerSlot')) {
        $values[$name] = $null
        if ($block -is [pscustomobject] -and $block.PSObject.Properties[$name]) { $values[$name] = $block.PSObject.Properties[$name].Value }
    }
    $total = $null
    if ($Plan.PSObject.Properties['model'] -and $Plan.model -and $Plan.model.PSObject.Properties['contextSize']) { $total = $Plan.model.contextSize }
    $whole = { param($Value) return [bool] ($Value -is [int] -or $Value -is [long]) }
    $valid = ($values['id'] -is [string]) -and (@('default', 'long') -ccontains $values['id']) -and (& $whole $values['slots']) -and (@(1, 2) -contains [int] $values['slots']) -and
        (& $whole $values['contextPerSlot']) -and ([long] $values['contextPerSlot'] -gt 0) -and (& $whole $total) -and
        ([long] $values['contextPerSlot'] * [int] $values['slots'] -eq [long] $total)
    if (-not $valid) {
        $failure = New-Object -TypeName System.InvalidOperationException -ArgumentList 'serving-profile-invalid: The plan carries a serving profile that does not match its context and slots. Nothing was started; plan again.'
        $failure.Data['FastLlmFailureCode'] = 'serving-profile-invalid'
        throw $failure
    }
    return [pscustomobject] [ordered] @{ id = [string] $values['id']; slots = [int] $values['slots']; contextPerSlot = [int] $values['contextPerSlot'] }
}

# True when the plan runs on an engine component (HIP, or any listed engine component). Such a plan is never recovered onto another setup.
function Test-FastLlmPlanOnEngineComponent {
    param($Plan)
    if ($Plan.PSObject.Properties['engineComponentId'] -and $Plan.engineComponentId) { return $true }
    return [bool] ($Plan.PSObject.Properties['backend'] -and ([string] $Plan.backend) -ieq 'hip')
}

# The closing sentence of a failed self-test depends on whether the CLI may actually recover onto the next cached setup.
function Get-FastLlmSelfTestFailureText {
    param([string[]] $Reasons, $Plan)
    $next = 'FastLLM tries the next cached setup.'
    if (Test-FastLlmPlanOnEngineComponent -Plan $Plan) { $next = 'FastLLM does not switch to another setup on its own.' }
    if (Test-FastLlmPlanFallsBackOnFailure -Plan $Plan) { $next = 'FastLLM tries the Vulkan setup instead.' }
    return "Self-test failed ($(@($Reasons) -join ', ')). The server was stopped; $next"
}

function Invoke-FastLlmSupervisedServer {
    param($Plan, [string] $InstallRoot, [int] $LoadTimeoutSeconds=300, [string] $CatalogPath,
          # Policy defaults and the canary default to off here (and in the module policy) so direct callers (lab trials) are unaffected;
          # the CLI and the background host default to auto and always pass it.
          [string] $VulkanBarMitigation='off', [switch] $ThroughputCanary,
          # Post-load self-test (default off for direct callers; the CLI start enables it).
          [switch] $SelfTest,
          # W03 Phase A device binding. Absent or off: nothing below runs and no field is added. record observes only.
          # enforce additionally fails a start whose binding is not bound (before launch) or whose post-load device check fails;
          # both failures are typed (FastLlmReason DeviceBindingFailed) and never trigger model recovery.
          [ValidateSet('off','record','enforce')][string] $DeviceBinding='off',
          # Opt-in: stop the server after this many minutes without requests (0 = never). Only the CLI and the background host pass it; every other caller, the bench path included, gets 0.
          [ValidateSet(0,15,30,60)][int] $IdleStopMinutes=0,
          # Opt-in model switch: only with this switch does the post-Ready loop look for state\switch-<runId>.json. Absent (every default start, direct
          # callers and the bench path): no request file is ever read and no field is added. -SwitchContext is Start-FastLlmServer's table for the
          # sequence (what this run is the outcome of, the accepted request, the plan that became ready); Start-FastLlmServer starts the other model.
          [switch] $AllowSwitch, [System.Collections.IDictionary] $SwitchContext,
          # Opt-in embedding sidecar: the serving session's sidecar (FastLlm.Sidecar.ps1), passed only by Start-FastLlmServer inside a session
          # that has one. Absent (every default start, direct callers and the bench path): nothing below runs and no field is added.
          [System.Collections.IDictionary] $SidecarSession,
          # Opt-in: the run's API key, in its holder. Only a start with the key setting on passes it (Start-FastLlmServer reads the store);
          # every other caller, the bench path included, passes nothing and gets today's keyless start. Untyped on purpose (see FastLlm.ApiKey.ps1).
          $ApiKeyHolder)
    # ValidateSet ignores case and keeps the typed value, but the enforce checks below are case-sensitive: normalise once, first.
    $DeviceBinding = $DeviceBinding.ToLowerInvariant()
    # $null for every plan without a serving profile (all of today's plans): nothing below then differs from before. Checked before anything is written or launched.
    $servingProfile = Get-FastLlmPlanServingProfile -Plan $Plan
    # The same for the speculation block (typed speculation-invalid, no retry reason): $null for every plan without one.
    $speculation = Get-FastLlmPlanSpeculation -Plan $Plan
    # A key was asked for exactly when the parameter was passed. Then the holder must be a well-formed key (typed api-key-invalid otherwise,
    # before anything is written or launched): a start that was asked for a key never runs without one.
    $apiKeyRequested = $PSBoundParameters.ContainsKey('ApiKeyHolder')
    $apiKeyId = $null
    # The one sender of this run's key: it is handed to the API check, the self-test, the throughput canary and the idle read, which call it
    # with (path, body, timeout). It runs inside those functions, so the names it reads are ones none of them uses. Each request goes through
    # the listener check in Invoke-FastLlmHttp first. $null without a key: every call below is then the one it always was.
    $apiKeyRequest = $null
    $apiKeyRunServer = $null
    # api-key-listener-changed (the key may have been sent to another program) is kept here the moment the sender sees it. The checks,
    # the idle read and the switch read each treat a failed request in their own way (a failed check, a failed read); this failure is not
    # theirs to absorb, so the run looks here after each of them and stops.
    $apiKeyRunExposure = @{ failure = $null }
    if ($apiKeyRequested) {
        $apiKeyId = [string] (Get-FastLlmApiKeyId -ApiKeyHolder $ApiKeyHolder)
        $apiKeyRunHolder = $ApiKeyHolder
        $apiKeyRunBaseUrl = $Plan.endpoint -replace '/v1$', ''
        $apiKeyRequest = { param($KeyedPath, $KeyedBody, $KeyedTimeoutMs)
            try { Invoke-FastLlmHttp -BaseUrl $apiKeyRunBaseUrl -Path $KeyedPath -Body $KeyedBody -TimeoutMs $KeyedTimeoutMs -ApiKeyHolder $apiKeyRunHolder -ApiKeyServer $apiKeyRunServer }
            catch {
                if ([string] $_.Exception.Data['FastLlmFailureCode'] -ceq 'api-key-listener-changed' -and $null -eq $apiKeyRunExposure.failure) { $apiKeyRunExposure.failure = $_.Exception }
                throw
            } }
    }
    Initialize-FastLlmProcessHost
    $state = [ordered]@{ schemaVersion=1; runId=[Guid]::NewGuid().ToString('N'); phase='loading'; updatedAt=(Get-Date).ToUniversalTime().ToString('o'); modelId=$Plan.model.id; endpoint=$Plan.endpoint; hardwareFingerprint=$Plan.hardwareFingerprint; engineVersion=$Plan.engineVersion; modelSha256=$Plan.model.sha256; canary=$null; placement=$null; startupDiagnostics=$null; selectedDeviceCapture=$null; selectedDeviceIdentity=$null; failureCode=$null; performanceQualified=$false; recipe=$null; thinking=$(if ($Plan.PSObject.Properties['requestedThinking'] -and [string]$Plan.requestedThinking -ceq 'off') { 'off' } else { 'auto' }); chatPage=$(if ($Plan.PSObject.Properties['requestedChatPage'] -and [string]$Plan.requestedChatPage -ceq 'on') { 'on' } else { 'off' }); processIdentity=$null; vulkanMemoryPolicy=$null; barGuidance=[ordered]@{ shown = $false; text = $null } }
    # Recorded from the start (only when on) so the Ready status already says so; the status of a default run is unchanged.
    if ($IdleStopMinutes -gt 0) { $state.idleStopMinutes = $IdleStopMinutes }
    # Opt-in model switch. Without -AllowSwitch nothing here or below runs: no field is added and no request file is ever looked for.
    $switchOrigin = $null
    $switchPriorStopPaths = @()
    $switchAccepted = $false
    $switchRunFailureCode = $null
    $switchBasisHardware = $null
    $switchBasisPlanOptions = $null
    if ($AllowSwitch) {
        if ($null -eq $SwitchContext) { throw 'A start that allows a model switch goes through Start-FastLlmServer: the supervisor cannot start the other model by itself.' }
        if (-not $CatalogPath) { throw 'A start that allows a model switch requires the verified catalog path.' }
        $state.switchAllowed = $true
        $SwitchContext['accepted'] = $null
        $SwitchContext['readyPlan'] = $null
        $SwitchContext['runId'] = [string] $state.runId
        $SwitchContext['runs'] = [int] $SwitchContext['runs'] + 1
        # This run is the outcome of a switch (the target, or the one restore of the previous model): its document says so from its first write.
        if ($null -ne $SwitchContext['origin']) {
            $switchOrigin = $SwitchContext['origin']
            $state['switch'] = New-FastLlmSwitchBlock -From ([string] $switchOrigin.from) -To ([string] $switchOrigin.to) -Pending -FailureCode ([string] $switchOrigin.failureCode)
        }
        if ($null -ne $SwitchContext['priorStopPaths']) { $switchPriorStopPaths = @($SwitchContext['priorStopPaths']) }
        # The reading this run's plan was built from, taken from the table once (a later run is given its own).
        if ($SwitchContext.Contains('basisHardware')) { $switchBasisHardware = $SwitchContext['basisHardware']; $SwitchContext['basisHardware'] = $null }
        if ($SwitchContext.Contains('basisPlanOptions')) { $switchBasisPlanOptions = $SwitchContext['basisPlanOptions']; $SwitchContext['basisPlanOptions'] = $null }
    }
    # A HIP plan (the engine component's lane) has no Vulkan memory policy, BAR mitigation, device binding or Vulkan identity capture.
    $isHipPlan = [bool] ($Plan.PSObject.Properties['backend'] -and ([string] $Plan.backend) -ieq 'hip')
    $hipAutoSelected = Test-FastLlmPlanFallsBackOnFailure -Plan $Plan
    $hipComponentId = ''
    if ($isHipPlan -and $Plan.PSObject.Properties['engineComponentId'] -and $Plan.engineComponentId) { $hipComponentId = [string] $Plan.engineComponentId }
    # Resolve the policy before any state is written; a non-off policy may run the bounded advisory heap probe.
    if ($isHipPlan) {
        $state.vulkanMemoryPolicy = [pscustomobject][ordered]@{ requested = 'not-applicable'; effective = 'not-applicable'; reason = 'hip-lane' }
        $state.selectedDeviceIdentity = [ordered]@{ status = 'not-applicable'; reason = 'hip-lane' }
    }
    else { $state.vulkanMemoryPolicy = Resolve-FastLlmVulkanBarMitigation -Plan $Plan -Requested $VulkanBarMitigation -InstallRoot $InstallRoot }
    if ($ThroughputCanary) { $state.throughputCanary = $null }
    if ($state.vulkanMemoryPolicy.requested -ne 'off' -and $state.vulkanMemoryPolicy.reason -eq 'engine-not-verified') {
        Write-Host "Vulkan memory: -VulkanBarMitigation $($state.vulkanMemoryPolicy.requested) was skipped because engine build '$($Plan.engineVersion)' has not been verified for it; no mitigation was applied."
    }
    elseif ($state.vulkanMemoryPolicy.requested -eq 'auto' -and $state.vulkanMemoryPolicy.reason -eq 'rebar-unknown-no-mitigation') {
        Write-Host 'Vulkan memory: the Resizable BAR check did not run or was inconclusive; no mitigation was applied. Details: fast-llm doctor -ProbeVulkanMemory.'
    }
    elseif ($state.vulkanMemoryPolicy.reason -eq 'policy-error') {
        Write-Host 'Vulkan memory: the Resizable BAR policy could not be evaluated; no mitigation was applied.'
    }
    if ($state.vulkanMemoryPolicy.effective -eq 'on') {
        $barCard = (@(@($Plan.selectedAdapters) | ForEach-Object { if ($_.PSObject.Properties['name']) { [string]$_.name } } | Where-Object { $_ }) -join ', ')
        if (-not $barCard) { $barCard = 'the selected GPU' }
        if ($state.vulkanMemoryPolicy.reason -eq 'rebar-off-detected') {
            Write-Host "Vulkan memory: Resizable BAR (Smart Access Memory) appears to be off for $barCard; keeping model buffers in device-only VRAM ($($script:FastLlmVulkanBarMitigationVariable)=1). Model load time may differ. Details: fast-llm doctor -ProbeVulkanMemory."
            $guidance = "Resizable BAR (AMD Smart Access Memory) appears to be off on this PC. FastLLM applied a workaround so models run at full speed. Turning on Resizable BAR / Smart Access Memory in your BIOS is AMD's recommended setup and may help further. See docs/RESIZABLE-BAR.md."
            Write-Host $guidance
            $state.barGuidance = [ordered]@{ shown = $true; text = $guidance }
        }
        else {
            Write-Host "Vulkan memory: keeping model buffers in device-only VRAM for $barCard ($($script:FastLlmVulkanBarMitigationVariable)=1, -VulkanBarMitigation on). Model load time may differ. Details: fast-llm doctor."
        }
    }
    # W03 Phase A: observe which device the plan resolves to, before any state is written and before the spawn. The observation never
    # alters the plan, the argv, the child environment or the BAR decision, and the collection itself never throws. record never fails
    # the start. enforce does: a binding that is not 'bound' becomes a typed gate (below) that is thrown before the port probe and the spawn.
    $deviceIdentity = $null
    $deviceBindingGate = $null
    # The adapter LUID the device binding resolved, for the GPU memory check (in memory only; absent when the binding is off).
    $spillBindingLuid = $null
    if ($isHipPlan -and $DeviceBinding -ne 'off') {
        # Device binding and the Vulkan identity capture are Vulkan-only: record observes nothing here, and enforce refuses before any launch.
        $state.deviceBinding = [pscustomobject][ordered]@{ mode = $DeviceBinding; status = 'not-applicable'; reason = 'unsupported-backend' }
        $state.identityRecord = 'not-applicable'
        if ($DeviceBinding -ceq 'enforce') {
            $deviceBindingGate = New-FastLlmDeviceBindingFailure -Code 'device-binding-unsupported-backend' -Message "Device binding (enforce) is available only for the Vulkan lane; this setup runs on the HIP engine component '${hipComponentId}'. The server was not started. Use -DeviceBinding record or -DeviceBinding off to start without this requirement."
        }
    }
    elseif ($DeviceBinding -ne 'off') {
        # The glue is contained as well: nothing here may reach the start's catch (binding-internal-error, identity unavailable).
        try {
            $binding = Invoke-FastLlmDeviceBinding -Plan $Plan -InstallRoot $InstallRoot -BarDecision $state.vulkanMemoryPolicy -Mode $DeviceBinding
            $state.deviceBinding = $binding.record
            $spillBindingLuid = $binding.luid
            if ($null -ne $binding.identity) {
                $deviceIdentity = $binding.identity
                $state.identityFingerprint = [string]$binding.identity.fingerprint
                $state.identityFingerprintKind = $script:FastLlmDeviceIdentityKind
                $state.identityRecord = 'pending'
                if ($null -ne $binding.change -and ($binding.change.card -or $binding.change.slot -or $binding.change.driver)) {
                    $state.identityChange = [ordered]@{ card = [bool]$binding.change.card; slot = [bool]$binding.change.slot; driver = [bool]$binding.change.driver }
                }
                foreach ($line in @($binding.lines)) { Write-Host ([string]$line) }
            }
            else { $state.identityRecord = 'unavailable' }
        }
        catch {
            $glueErrorType = 'Exception'
            try { $glueErrorType = [string]$_.Exception.GetType().Name } catch { }
            $deviceIdentity = $null
            foreach ($staleField in @('identityFingerprint', 'identityFingerprintKind', 'identityChange')) { if ($state.Contains($staleField)) { $state.Remove($staleField) } }
            $state.deviceBinding = [pscustomobject][ordered]@{
                mode = $DeviceBinding; status = 'unavailable'; reason = 'binding-internal-error'; rawDeviceCount = 0; distinctAdapterCount = 0; duplicateLuidEntries = 0
                device = $null; planMatch = $null; barSnapshot = 'not-applicable'
                collector = [pscustomobject][ordered]@{ scriptSha256 = $null; joinSourceSha256 = $null; durationMs = 0; loaderVersion = $null; segmentKnown = $false }
                errorType = $glueErrorType
            }
            $state.identityRecord = 'unavailable'
        }
        # enforce only: a binding that is not 'bound' fails the start before launch. The failure is built here and thrown as the first
        # statement of the start's try block, so the catch records the typed code and the finally writes the failed state and cleans up.
        if ($DeviceBinding -ceq 'enforce' -and [string](Get-FastLlmDeviceBindingValue $state.deviceBinding 'status') -cne 'bound') {
            $gateStatus = [string](Get-FastLlmDeviceBindingValue $state.deviceBinding 'status')
            if ($gateStatus -cnotin @('unavailable', 'ambiguous', 'not-supported-topology')) { $gateStatus = 'unavailable' }
            $gateReason = [string](Get-FastLlmDeviceBindingValue $state.deviceBinding 'reason')
            if ($gateReason -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,95}$') { $gateReason = 'unspecified' }
            $deviceBindingGate = New-FastLlmDeviceBindingFailure -Code ('device-binding-' + $gateStatus) -Message "Device binding (enforce) could not bind the GPU: status '$gateStatus', reason '$gateReason'. The server was not started. Use -DeviceBinding record or -DeviceBinding off to start without this requirement."
        }
    }
    if ($Plan.PSObject.Properties['backgroundRequestId']) {
        $backgroundRequestId = [string]$Plan.backgroundRequestId
        if ($backgroundRequestId -cnotmatch '^[0-9a-f]{32}$') { throw 'Invalid background request correlation.' }
        $state.backgroundRequestId = $backgroundRequestId
    }
    # What the plan said about its recipe, recorded so a UI shows the label and results link of the plan that actually runs.
    if ($Plan.PSObject.Properties['recipe'] -and $Plan.recipe) {
        $planRecipeFields = [ordered]@{ id = $null; origin = $null; label = $null; evidenceUrl = $null }
        foreach ($planRecipeField in @($planRecipeFields.Keys)) {
            if ($Plan.recipe.PSObject.Properties[$planRecipeField] -and $null -ne $Plan.recipe.$planRecipeField) { $planRecipeFields[$planRecipeField] = [string] $Plan.recipe.$planRecipeField }
        }
        $state.planRecipe = $planRecipeFields
    }
    # The engine that actually runs, recorded so removing an engine component can tell whether this server uses it.
    if ($Plan.PSObject.Properties['enginePath'] -and -not [string]::IsNullOrWhiteSpace([string] $Plan.enginePath)) {
        $state.engineExecutable = [string] $Plan.enginePath
        $statusEngineComponentId = $null
        if ($Plan.PSObject.Properties['engineComponentId'] -and $Plan.engineComponentId) { $statusEngineComponentId = [string] $Plan.engineComponentId }
        elseif ($Plan.PSObject.Properties['engineVersion'] -and $Plan.engineVersion -and $Plan.PSObject.Properties['backend'] -and ([string] $Plan.backend).ToLowerInvariant() -ceq 'vulkan') {
            $statusEngineComponentId = 'llama.cpp-' + [string] $Plan.engineVersion + '-vulkan'
        }
        $state.engineComponentId = $statusEngineComponentId
        # The engine that runs, in one block (backend, version, component id), next to the older flat fields.
        $state.engine = [ordered]@{ backend = $(if ($Plan.PSObject.Properties['backend']) { ([string] $Plan.backend).ToLowerInvariant() } else { $null }); version = $(if ($Plan.PSObject.Properties['engineVersion']) { [string] $Plan.engineVersion } else { $null }); componentId = $statusEngineComponentId }
    }
    # A plan that stands in for the one that could not run says so: the recipe it replaced, the one that runs, and why.
    if ($Plan.PSObject.Properties['fallback'] -and $Plan.fallback -and $Plan.fallback.PSObject.Properties['applied'] -and [bool] $Plan.fallback.applied) {
        $fallbackToRecipe = $null
        if ($Plan.PSObject.Properties['recipe'] -and $Plan.recipe -and $Plan.recipe.PSObject.Properties['id']) { $fallbackToRecipe = [string] $Plan.recipe.id }
        $state.fallback = [ordered]@{ fromRecipe = [string] $Plan.fallback.fromRecipe; toRecipe = $fallbackToRecipe; reason = [string] $Plan.fallback.reason }
    }
    if ($Plan.PSObject.Properties['catalogVersion']) {
        if (-not $CatalogPath) { throw 'A real runtime recipe requires the verified catalog path.' }
        $state.recipe = [ordered]@{
            catalogVersion=$Plan.catalogVersion; catalogSha256=(Get-FileHash -LiteralPath $CatalogPath -Algorithm SHA256).Hash.ToLowerInvariant()
            engineSha256=(Get-FileHash -LiteralPath $Plan.enginePath -Algorithm SHA256).Hash.ToLowerInvariant()
            backend=$Plan.backend; contextSize=$Plan.model.contextSize; slots=$Plan.model.parallel
            cacheTypeK=$Plan.model.cacheTypeK; cacheTypeV=$Plan.model.cacheTypeV; speculation='none'; flashAttention='auto'
            splitMode=$Plan.splitMode; tensorSplit=$Plan.tensorSplit; adapters=$Plan.selectedAdapters
            requestedArguments=@($Plan.serverArguments | ForEach-Object { if ($_ -eq $Plan.modelPath) { '<verified-model>' } else { $_ } })
            configurationIsolation='empty-per-run-config-roots-and-targeted-environment-sanitization'
        }
        # Recorded only when the mitigation is in effect, so the default recipe stays byte-identical.
        if ($state.vulkanMemoryPolicy.effective -eq 'on') {
            $state.recipe.environmentOverride = [ordered]@{ $script:FastLlmVulkanBarMitigationVariable = '1' }
        }
        # Recorded only for a plan with a serving profile, so the default recipe stays byte-identical. contextSize above stays the TOTAL context;
        # contextPerSlot is what one request gets.
        if ($servingProfile) {
            $state.recipe.profile = [string] $servingProfile.id
            $state.recipe.contextPerSlot = [int] $servingProfile.contextPerSlot
        }
    }
    # Recorded only for a plan with speculation, so the default status stays byte-identical: the real mode in an additive field, and the spec
    # type in the recipe (so the measurement tools that require none refuse the run).
    if ($speculation) {
        $state.speculation = [ordered]@{ mode = [string] $speculation.mode; specType = [string] $speculation.specType; extraArguments = @($speculation.extraArguments); resultId = $speculation.resultId }
        if ($state.recipe) { $state.recipe.speculation = [string] $speculation.specType }
    }
    $stateRoot = Get-FastLlmStateRoot -InstallRoot $InstallRoot -Create
    # Run log (best-effort, prompt-free): the plan's own fields and phase names only. Nothing a server prints or a client sends.
    $runPhase = 'preparing'
    $runFailureMessage = $null
    Add-FastLlmRunLogEvent -InstallRoot $InstallRoot -State $state -Event 'start' -Fields { Get-FastLlmRunLogStartFields -Plan $Plan -State $state -SelfTest ([bool] $SelfTest) }
    Add-FastLlmRunLogEvent -InstallRoot $InstallRoot -State $state -Event 'phase' -Fields @{ phase = 'preparing' }
    # Opt-in embedding sidecar: the session's one block is this document's sidecars[0] from its first write (waiting until this run is Ready,
    # or as it stands after a model switch). The top-level phase stays the text model's.
    if ($null -ne $SidecarSession) { $state.sidecars = @(Enter-FastLlmSidecarRun -Session $SidecarSession -InstallRoot $InstallRoot -State $state -ApiKeyHolder $ApiKeyHolder) }
    $stopPath = Join-Path $stateRoot ('stop-' + $state.runId)
    $switchRequestPath = Join-Path $stateRoot ('switch-' + $state.runId + '.json')
    $switchBasisPath = Join-Path $stateRoot ('switch-basis-' + $state.runId + '.json')
    $sandbox = New-FastLlmRuntimeSandbox -InstallRoot $InstallRoot
    $hostProcess = New-Object Bitworks.FastLlm.ProcessHost
    $spawned = $false
    $reachedReady = $false
    $baseUrl = $Plan.endpoint -replace '/v1$', ''
    try {
        # A stop asked for while the previous run was being replaced by this one names that run. Stop always wins: nothing is launched.
        # A run that allows switching saves, once, the hardware reading its own plan was built from (Start-FastLlmServer hands it over in the table of the
        # sequence); it is removed with the request file below. Best-effort, and nothing at all for a default run.
        if ($AllowSwitch -and $switchBasisHardware) { [void] (Write-FastLlmSwitchBasis -InstallRoot $InstallRoot -RunId ([string] $state.runId) -Hardware $switchBasisHardware -PlanOptions $switchBasisPlanOptions) }
        if ($AllowSwitch -and (Test-FastLlmSwitchPriorStop -Paths $switchPriorStopPaths)) { $state.stopReason='user'; $state.phase='stopped'; return 0 }
        if ($null -ne $deviceBindingGate) { throw $deviceBindingGate }
        # Refuse an already occupied port with a plain message. A same-user bind race after this check remains possible.
        $uri = [Uri]$baseUrl
        Assert-FastLlmLoopbackPortFree -Port $uri.Port
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $Plan.enginePath
        $info.Arguments = Join-FastLlmProcessArguments -Arguments $Plan.serverArguments
        $info.WorkingDirectory = Split-Path -Parent $Plan.enginePath
        # The scrub, sandbox paths, PATH and (Vulkan lane, opt-in) the BAR variable all come from the one environment builder the device probe also uses.
        # With a key, the same builder also sets LLAMA_API_KEY for this server child only: the arguments above are the same with or without it.
        if ($apiKeyRequested) { Initialize-FastLlmEngineStartInfo -StartInfo $info -Plan $Plan -Sandbox $sandbox -VulkanBarMitigation:($state.vulkanMemoryPolicy.effective -eq 'on') -ApiKeyHolder $ApiKeyHolder }
        else { Initialize-FastLlmEngineStartInfo -StartInfo $info -Plan $Plan -Sandbox $sandbox -VulkanBarMitigation:($state.vulkanMemoryPolicy.effective -eq 'on') }
        # W1: besides every line with an api_key label, the process host drops any output line that holds this run's key itself.
        if ($apiKeyRequested) { $hostProcess.DropLinesContaining((Get-FastLlmApiKeyText -ApiKeyHolder $ApiKeyHolder)) }
        Write-FastLlmState -InstallRoot $InstallRoot -State $state
        try { $hostProcess.Start($info) }
        catch {
            # A policy block can refuse the process start itself (Win32 error 4551 or 1260): typed, and never a Vulkan fallback.
            if ($isHipPlan) {
                $hipStartFailure = New-FastLlmHipLaunchFailure -ComponentId $hipComponentId -NativeErrorCode (Get-FastLlmNativeErrorCode -Exception $_.Exception) -AutoSelected:$hipAutoSelected
                if ($hipStartFailure) { throw $hipStartFailure }
            }
            throw
        }
        $spawned = $true
        # Record only the actual supervised child identity, never a discovered
        # listener guess. This remains present through checking/ready/final state.
        $state.processIdentity = [ordered]@{
            pid=[int]$hostProcess.Process.Id
            startUtcTicks=[long]$hostProcess.Process.StartTime.ToUniversalTime().Ticks
        }
        # The key is only ever sent to this process (the listener check compares the port's owner with this identity).
        $apiKeyRunServer = $state.processIdentity
        $state.updatedAt=(Get-Date).ToUniversalTime().ToString('o')
        Write-FastLlmState -InstallRoot $InstallRoot -State $state
        $runPhase = 'loading'
        Add-FastLlmRunLogEvent -InstallRoot $InstallRoot -State $state -Event 'phase' -Fields @{ phase = 'loading' }
        $deadline = [Diagnostics.Stopwatch]::StartNew()
        $healthy = $false
        while ($deadline.Elapsed.TotalSeconds -lt $LoadTimeoutSeconds) {
            if (Test-Path -LiteralPath $stopPath) { $state.phase='stopped'; return 0 }
            if ($AllowSwitch -and (Test-FastLlmSwitchPriorStop -Paths $switchPriorStopPaths)) { $state.stopReason='user'; $state.phase='stopped'; return 0 }
            if ($hostProcess.Process.HasExited) {
                # llama-server's own bind error is the same plain refusal as the pre-start check (a bind race after the check).
                # The output is read inside the check and handed to no command (an app may already have sent the loading server a request, and an
                # engine can echo one; module logging records command parameters).
                $earlyOutputWait = [Diagnostics.Stopwatch]::StartNew()
                while (-not $hostProcess.OutputCompleted -and $earlyOutputWait.ElapsedMilliseconds -lt 2000) { Start-Sleep -Milliseconds 50 }
                if (Test-FastLlmServerBindFailure -HostProcess $hostProcess -Port ([int] $uri.Port)) {
                    throw (New-FastLlmPortInUseFailure -Port ([int] $uri.Port))
                }
                # A HIP server that dies on a blocked or missing DLL is a typed failure; any other early exit stays the generic one.
                if ($isHipPlan) {
                    $hipEarlyFailure = New-FastLlmHipLaunchFailure -ComponentId $hipComponentId -ExitCode ([int] $hostProcess.Process.ExitCode) -AutoSelected:$hipAutoSelected
                    if ($hipEarlyFailure) { throw $hipEarlyFailure }
                }
                throw 'Server exited before readiness.'
            }
            try { $health=Invoke-FastLlmHttp -BaseUrl $baseUrl -Path '/health' -TimeoutMs 1000; $healthy=$health.Status -eq 200 -and (ConvertFrom-Json $health.Body).status -eq 'ok' } catch { $healthy=$false }
            if ($healthy) { break }
            Start-Sleep -Milliseconds 200
        }
        if (-not $healthy) { throw 'Model-load readiness deadline exceeded.' }
        # Freeze before API canaries so no prompt/completion-related server lines
        # can enter the allowlisted startup-only diagnostic capture.
        $startupText=$hostProcess.FreezeStartupDiagnostics()
        $requestedFlashAttention=if($state.recipe){$state.recipe.flashAttention}else{$null}
        $state.startupDiagnostics=ConvertFrom-FastLlmStartupDiagnostics -Text $startupText -Overflow $hostProcess.StartupDiagnosticsOverflow -RequestedFlashAttention $requestedFlashAttention
        Add-FastLlmRunLogEvent -InstallRoot $InstallRoot -State $state -Event 'startup-diagnostics' -Fields { Get-FastLlmRunLogDiagnosticsFields -Diagnostics $state.startupDiagnostics }
        # Freeze same-child device selection before any API canary can cause
        # prompt-related output. This advisory never changes the Ready gate.
        $selectedDeviceText=$hostProcess.FreezeSelectedDeviceIdentity()
        $state.selectedDeviceCapture=[ordered]@{
            likeLines=[int]$hostProcess.SelectedDeviceLikeLines
            malformedLines=[int]$hostProcess.SelectedDeviceMalformedLines
            overflow=[bool]$hostProcess.SelectedDeviceIdentityOverflow
            diagnostics=[string]$hostProcess.SelectedDeviceIdentityDiagnostics()
        }
        if (-not $isHipPlan) { $state.selectedDeviceIdentity=ConvertFrom-FastLlmSelectedDeviceIdentity -Text $selectedDeviceText -ExpectedDevices @($Plan.selectedAdapters.device) -LikeLines $state.selectedDeviceCapture.likeLines -MalformedLines $state.selectedDeviceCapture.malformedLines -UnknownIdLines ([int]$hostProcess.SelectedDeviceUnknownIdLines) -Overflow $state.selectedDeviceCapture.overflow }
        # Freeze the server device-list capture (the level-4 device_info entries and the "using device" lines) at the same point, before any
        # API canary. The capture itself never gates: any throw is recorded as { error = <exception type name> } (never its text) and is
        # swallowed here. Under -DeviceBinding enforce the post-load check below READS these entries (an error capture fails that check
        # closed) and can fail the start; under record and off nothing reads them to decide anything and the Ready gate is untouched.
        # Counts, overflow flags and reason-only diagnostics are recorded, plus the parsed entries as fields only (never raw lines), in private status.json only.
        try {
            $deviceInfoText=$hostProcess.FreezeDeviceInfoEntries()
            $usingDeviceText=$hostProcess.FreezeUsingDeviceEntries()
            $deviceListEntries=ConvertFrom-FastLlmServerDeviceListEntries -DeviceInfoText $deviceInfoText -UsingDeviceText $usingDeviceText
            $state.serverDeviceListCapture=[ordered]@{
                deviceInfoLikeLines=[int]$hostProcess.DeviceInfoLikeLines
                deviceInfoMalformedLines=[int]$hostProcess.DeviceInfoMalformedLines
                deviceInfoOverflow=[bool]$hostProcess.DeviceInfoOverflow
                usingDeviceLikeLines=[int]$hostProcess.UsingDeviceLikeLines
                usingDeviceMalformedLines=[int]$hostProcess.UsingDeviceMalformedLines
                usingDeviceOverflow=[bool]$hostProcess.UsingDeviceOverflow
                diagnostics=[string]$hostProcess.DeviceListCaptureDiagnostics()
                deviceInfo=@($deviceListEntries.deviceInfo)
                usingDevice=@($deviceListEntries.usingDevice)
            }
        } catch { $state.serverDeviceListCapture=[ordered]@{error=[string]$_.Exception.GetType().Name} }
        # W03 Phase A post-load device check, still before the canary, the ready write and the last-ready record. record: informational
        # (recorded only when the binding is bound, any error swallowed, never gates). enforce: a failed check stops the server through the
        # start's catch/finally (Dispose) and fails the start with a typed, never-recovered failure.
        if ($DeviceBinding -ne 'off' -and [string](Get-FastLlmDeviceBindingValue $state.deviceBinding 'status') -ceq 'bound') {
            $postLoad = $null
            try { $postLoad = Test-FastLlmDeviceBindingPostLoad -Plan $Plan -Binding $state.deviceBinding -Capture $state.serverDeviceListCapture }
            catch { $postLoad = [pscustomobject][ordered]@{ result = 'failed'; item = 'internal-error' } }
            try { $state.deviceBinding | Add-Member -NotePropertyName postLoadCheck -NotePropertyValue $postLoad -Force }
            catch {
                # record swallows; enforce must not let an untyped error reach the start's recovery, so it becomes the typed failure.
                if ($DeviceBinding -ceq 'enforce') {
                    $postLoad = [pscustomobject][ordered]@{ result = 'failed'; item = 'internal-error' }
                    throw (New-FastLlmDeviceBindingFailure -Code 'device-binding-post-load-mismatch' -Message "Device binding (enforce): the post-load device check could not be recorded (check internal-error). The server was stopped. Use -DeviceBinding record or -DeviceBinding off to start without this requirement.")
                }
            }
            if ($DeviceBinding -ceq 'enforce' -and $postLoad.result -cne 'passed') {
                throw (New-FastLlmDeviceBindingFailure -Code 'device-binding-post-load-mismatch' -Message ("Device binding (enforce): the server's device list does not match the bound GPU (check $($postLoad.item)). The server was stopped. Use -DeviceBinding record or -DeviceBinding off to start without this requirement."))
            }
        }
        if ($apiKeyRequested) {
            # The proof, before anything says the key is on: one request without the key must be refused (401) and one with it must be
            # answered (200). A request that gets no answer counts as status 0. Anything but 401 and 200 stops the server (the start's
            # finally) with api-key-not-enforced. The captures above are frozen, so these requests add nothing to them.
            $proofWithout = 0
            $proofWith = 0
            try { $proofWithout = [int] (Invoke-FastLlmHttp -BaseUrl $baseUrl -Path '/props' -TimeoutMs 5000).Status } catch { $proofWithout = 0 }
            try { $proofWith = [int] (& $apiKeyRequest '/props' $null 5000).Status }
            catch {
                # A refusal of the key path itself (the listener is not this run's server) keeps its own code; a request that failed is status 0.
                if ($_.Exception.Data['FastLlmReason'] -ceq 'ApiKeyFailed') { throw }
                $proofWith = 0
            }
            if ((Get-FastLlmApiKeyEnforcement -WithoutKeyStatus $proofWithout -WithKeyStatus $proofWith) -cne 'enforced') {
                throw (New-FastLlmApiKeyFailure -Code 'api-key-not-enforced' -Message "The API key is on, but the server did not enforce it: a request without the key got HTTP status $proofWithout (401 expected) and a request with the key got $proofWith (200 expected). The server was stopped.")
            }
            # Only now may the status, the window and Connect an app say the key is on. The id is public: it tells two keys apart, nothing more.
            $state.apiKey = 'on'
            $state.apiKeyId = $apiKeyId
            # How many lines of server output the process host dropped so far because they carried an api_key label or the key itself
            # (W1). A count only; it is refreshed when the server is ready.
            $state.apiKeyOutputLinesDropped = [int] $hostProcess.SecretLinesDropped
        }
        $state.phase='checking'; $state.updatedAt=(Get-Date).ToUniversalTime().ToString('o')
        Write-FastLlmState -InstallRoot $InstallRoot -State $state
        # Capture only normalized placement lines as they arrive. The general
        # process log is a bounded tail and may evict early model-load evidence.
        $placementText = $hostProcess.PlacementSnapshot()
        try {
            if ($hostProcess.PlacementOverflow) { throw 'GPU placement capture exceeded its bounded limit.' }
            $state.placement = ConvertFrom-FastLlmPlacementLog -Text $placementText -Devices @($Plan.selectedAdapters.device)
            Add-FastLlmRunLogEvent -InstallRoot $InstallRoot -State $state -Event 'placement' -Fields { Get-FastLlmRunLogPlacementFields -Placement $state.placement }
        }
        catch {
            Write-Host "GPU placement diagnostics: $($hostProcess.PlacementDiagnostics())"
            $safeLines = @($placementText -split "`r?`n" | Where-Object { $_ } | Select-Object -First 16)
            if ($safeLines.Count) { Write-Host ('GPU placement evidence: ' + ($safeLines -join ' | ')) }
            throw
        }
        # From here the API is in use: a failure's own text is never logged (it could echo request text), only its code.
        $runPhase = 'checking'
        Add-FastLlmRunLogEvent -InstallRoot $InstallRoot -State $state -Event 'phase' -Fields @{ phase = 'checking' }
        # The slot count and the per-slot context come from the plan's serving profile; without one the call is exactly the one it always was.
        # With a key the check, the self-test, the throughput canary and the idle read all send through the run's keyed sender; without one nothing is added to any call.
        $apiKeyRequestOption = @{}
        if ($apiKeyRequested) { $apiKeyRequestOption.Request = $apiKeyRequest }
        if ($servingProfile) { $state.canary = Test-FastLlmApiCanary -BaseUrl $baseUrl -ModelId $Plan.model.id -ContextSize $servingProfile.contextPerSlot -Slots $servingProfile.slots @apiKeyRequestOption }
        else { $state.canary = Test-FastLlmApiCanary -BaseUrl $baseUrl -ModelId $Plan.model.id -ContextSize $Plan.model.contextSize @apiKeyRequestOption }
        if ($null -ne $apiKeyRunExposure.failure) { throw $apiKeyRunExposure.failure }
        Add-FastLlmRunLogEvent -InstallRoot $InstallRoot -State $state -Event 'api-check' -Fields { Get-FastLlmRunLogApiCheckFields -Canary $state.canary }
        if ($hostProcess.Process.HasExited) { throw 'Server exited during canary.' }
        $hostProcess.DiscardOutput()
        # The self-test (spec 4.2 step 5, 4.3) completes BEFORE any ready announcement: the status phase stays 'checking', no Ready line is printed
        # and the last-ready recovery record is not rewritten until the verdict is in. A hard fail therefore leaves the previous record intact for recovery.
        $spillStep = $null
        if ($SelfTest) {
            $expected = $null
            if ($Plan.PSObject.Properties['recipe'] -and $Plan.recipe -and $Plan.recipe.expected) { $expected = $Plan.recipe.expected }
            $contextForTest = 0
            if ($Plan.model.PSObject.Properties['contextSize']) { $contextForTest = [int] $Plan.model.contextSize }
            # One request has the per-slot context, so that is what the self-test workload must fit.
            if ($servingProfile) { $contextForTest = [int] $servingProfile.contextPerSlot }
            $mitigation = 'off'
            if ($state.vulkanMemoryPolicy -and $state.vulkanMemoryPolicy.effective -eq 'on') { $mitigation = 'on' }
            $speculationEffective = 'none'
            if ($speculation) { $speculationEffective = [string] $speculation.specType }
            $selfTestResult = Invoke-FastLlmSelfTest -BaseUrl $baseUrl -ContextSize $contextForTest -Expected $expected -EngineBuild ([string] $Plan.engineVersion) -MitigationEffective $mitigation -SpeculationEffective $speculationEffective @apiKeyRequestOption
            if ($null -ne $apiKeyRunExposure.failure) { throw $apiKeyRunExposure.failure }
            # The GPU memory check right after the self-test (the KV buffer exists by now). A state that is not ok makes the numbers not comparable.
            $spillStep = Invoke-FastLlmSpillCheckAtReady -Plan $Plan -InstallRoot $InstallRoot -KnownLuid $spillBindingLuid -BarDecision $state.vulkanMemoryPolicy -Process $hostProcess.Process
            $selfTestResult = Set-FastLlmSelfTestSpillMark -SelfTest $selfTestResult -SpillCheck $spillStep.spillCheck
            $recipeId = $null
            if ($Plan.PSObject.Properties['recipe'] -and $Plan.recipe) { $recipeId = $Plan.recipe.id }
            $state.selfTest = $selfTestResult
            Add-FastLlmRunLogEvent -InstallRoot $InstallRoot -State $state -Event 'self-test' -Fields { Get-FastLlmRunLogSelfTestFields -Result $selfTestResult }
            try { Write-FastLlmState -InstallRoot $InstallRoot -FileName 'selftest.json' -State ([ordered]@{ schemaVersion = 1; recipeId = $recipeId; modelId = [string] $Plan.model.id
                        engineBuild = [string] $Plan.engineVersion; result = $selfTestResult }) } catch { }
            try { $state.updatedAt = (Get-Date).ToUniversalTime().ToString('o'); Write-FastLlmState -InstallRoot $InstallRoot -State $state } catch { }
            if ($selfTestResult.status -eq 'pass') { Write-Host "Self-test passed: $($selfTestResult.generationTokS) tok/s generation, $($selfTestResult.promptTokS) tok/s prompt." }
            elseif ($selfTestResult.status -eq 'skipped') {
                Write-Host "Self-test skipped: the context size is too small for the performance check ($(@($selfTestResult.reasons) -join ', ')). The server keeps running."
            }
            elseif ($selfTestResult.status -eq 'below-expected') {
                Write-Host "Self-test: generation $($selfTestResult.generationTokS) tok/s is below 70% of the $($selfTestResult.expectedGenerationTokS) tok/s measured for this setup. Likely causes: driver version, Resizable BAR, other apps using GPU memory, power or thermal limits. Run: fast-llm doctor"
            }
            else {
                $failure = New-FastLlmTypedFailure -Code 'self-test-failed' -Message (Get-FastLlmSelfTestFailureText -Reasons @($selfTestResult.reasons) -Plan $Plan)
                $failure.Data['FastLlmReason'] = 'RuntimeCheckFailed'
                throw $failure
            }
        }
        if ($null -eq $spillStep) { $spillStep = Invoke-FastLlmSpillCheckAtReady -Plan $Plan -InstallRoot $InstallRoot -KnownLuid $spillBindingLuid -BarDecision $state.vulkanMemoryPolicy -Process $hostProcess.Process }
        $state.spillCheck = $spillStep.spillCheck
        $spillLuid = [string] $spillStep.luid
        Add-FastLlmRunLogEvent -InstallRoot $InstallRoot -State $state -Event 'spill-check' -Fields { Get-FastLlmSpillCheckEventFields -Step $spillStep }
        # A run that is the outcome of a switch says so in the same write that says ready: ok for the target, failed-restored for the one restore.
        # Every gate above was passed first, exactly as for any other start.
        $switchReadyResult = $null
        if ($null -ne $switchOrigin) {
            $switchReadyResult = 'ok'
            $switchReadyCode = ''
            if ([string] $switchOrigin.role -ceq 'restore') { $switchReadyResult = 'failed-restored'; $switchReadyCode = [string] $switchOrigin.failureCode }
            $state['switch'] = New-FastLlmSwitchBlock -From ([string] $switchOrigin.from) -To ([string] $switchOrigin.to) -Result $switchReadyResult -FailureCode $switchReadyCode
        }
        if ($apiKeyRequested) { $state.apiKeyOutputLinesDropped = [int] $hostProcess.SecretLinesDropped }
        $state.phase='ready'; $state.updatedAt=(Get-Date).ToUniversalTime().ToString('o')
        Write-FastLlmState -InstallRoot $InstallRoot -State $state
        $reachedReady = $true
        $runPhase = 'ready'
        Add-FastLlmRunLogEvent -InstallRoot $InstallRoot -State $state -Event 'phase' -Fields @{ phase = 'ready' }
        if ($AllowSwitch) {
            # The plan that serves now: what a later switch is planned from, and what one restore would start again.
            $SwitchContext['readyPlan'] = $Plan
            if ($null -ne $switchReadyResult) { Add-FastLlmRunLogEvent -InstallRoot $InstallRoot -State $state -Event 'switch-result' -Fields { Get-FastLlmRunLogSwitchResultFields -Result $switchReadyResult -FailureCode $switchReadyCode } }
        }
        if ($state.recipe) {
            # profile and requestedContextSize are additive: ids and numbers only. Start at sign-in reads them to build its saved request
            # (the recovery reader ignores them). They are omitted when the plan does not carry them.
            $lastReady = [ordered]@{
                kind='api-smoke-only';hardwareFingerprint=$Plan.hardwareFingerprint;modelId=$Plan.model.id;modelSha256=$Plan.model.sha256;catalogSha256=$state.recipe.catalogSha256
            }
            if ($Plan.PSObject.Properties['profile'] -and $Plan.profile) { $lastReady.profile = [string]$Plan.profile }
            if ($Plan.PSObject.Properties['requestedContextSize'] -and $null -ne $Plan.requestedContextSize) { $lastReady.requestedContextSize = [int]$Plan.requestedContextSize }
            Write-FastLlmState -InstallRoot $InstallRoot -FileName ($Plan.hardwareFingerprint+'.last-ready.json') -State $lastReady
        }
        if ($null -ne $deviceIdentity) {
            # Advisory: the identity record is written only now (a failed start leaves the file untouched). Any failure is caught here,
            # so it can never reach the start's catch block, change the phase or trigger model recovery.
            try { $identityWritten = Write-FastLlmDeviceIdentityRecord -InstallRoot $InstallRoot -Identity $deviceIdentity; $state.identityRecord = $(if ($identityWritten -is [bool] -and -not $identityWritten) { 'unavailable' } else { 'recorded' }) }
            catch { $state.identityRecord = 'write-failed' }
            try {
                $state.updatedAt=(Get-Date).ToUniversalTime().ToString('o')
                Write-FastLlmState -InstallRoot $InstallRoot -State $state
            } catch { }
        }
        Write-Host "Ready: $($Plan.endpoint) - API smoke test and reported GPU layers passed; physical residency/performance remain unqualified."
        if ($apiKeyRequested) { Write-Host "API key: on (key id $apiKeyId). Checked: a request without the key is refused. Apps need the key; show it with: fast-llm.ps1 settings -ApiKey show" }
        # The GPU memory check line (never a layer-based claim). The unavailable text is shown once per run, here or at its first change.
        $spillUnknownShown = $false
        $spillReadyText = Get-FastLlmSpillCheckText -SpillCheck $state.spillCheck
        if ($spillReadyText) { Write-Host $spillReadyText; if ([string] $state.spillCheck.state -ceq 'unknown') { $spillUnknownShown = $true } }
        if ($ThroughputCanary) {
            # Advisory only: every failure is recorded and swallowed; it can never fail the start or trigger recovery.
            try {
                $canaryNames = @(@($Plan.selectedAdapters) | ForEach-Object { if ($_.PSObject.Properties['name']) { [string]$_.name } })
                $contextForCanary = if ($Plan.model.PSObject.Properties['contextSize']) { [int]$Plan.model.contextSize } else { 0 }
                if ($servingProfile) { $contextForCanary = [int] $servingProfile.contextPerSlot }
                $state.throughputCanary = Invoke-FastLlmThroughputCanary -BaseUrl $baseUrl -ContextSize $contextForCanary -AdapterNames $canaryNames -ModelId ([string]$Plan.model.id) @apiKeyRequestOption
            } catch { $state.throughputCanary = [pscustomobject][ordered]@{ ppTokPerS=$null; floor=$null; floorSource=$null; warmupPpTokPerS=$null; status='failed'; promptTokens=$null; promptArtifactSha256=$null; reason='canary-error' } }
            # The throughput canary swallows its own failures; a key that may have been sent to another program is not one of them.
            if ($null -ne $apiKeyRunExposure.failure) { throw $apiKeyRunExposure.failure }
            try {
                $state.updatedAt=(Get-Date).ToUniversalTime().ToString('o')
                Write-FastLlmState -InstallRoot $InstallRoot -State $state
            } catch { }
            $canaryNote = ''
            if ($state.throughputCanary.status -eq 'degraded') {
                if ($state.throughputCanary.reason -eq 'timeout') { $canaryNote = ' The canary request timed out.' }
                else { $canaryNote = ' Prompt processing is below the per-card floor.' }
                if ($Plan.PSObject.Properties['backend'] -and [string]$Plan.backend -ieq 'vulkan') { $canaryNote += ' See doctor -ProbeVulkanMemory for Resizable BAR guidance.' }
            }
            $canaryFloor = if ($null -ne $state.throughputCanary.floor) { "floor $($state.throughputCanary.floor)" } else { 'no reviewed floor for this model and card' }
            Write-Host "Throughput canary (advisory): PP512 $($state.throughputCanary.ppTokPerS) tok/s, $canaryFloor, status $($state.throughputCanary.status).$canaryNote"
        }
        $idleDetector = $null
        $idleNextPoll = [DateTime]::MaxValue
        # The HTTP status of the latest idle read, and whether a refused read (401) was already logged for the current run of them.
        $idleRead = @{ status = 0 }
        $idleUnauthorizedLogged = $false
        if ($IdleStopMinutes -gt 0) {
            $idleNow = (Get-Date).ToUniversalTime()
            $idleDetector = New-FastLlmIdleDetectorState -Now $idleNow
            $idleNextPoll = $idleNow.AddSeconds($script:FastLlmIdlePollSeconds)
        }
        $spillNextCheck = (Get-Date).ToUniversalTime().AddSeconds([int] $script:FastLlmSpillCheckIntervalSeconds)
        # A non-Vulkan plan found its adapter by the server process's memory; a failed read on it re-identifies once (inside the loop read budget).
        $spillReidentify = $null
        if (([string] (Get-FastLlmSpillValue $Plan 'backend')) -ine 'vulkan' -and -not $spillBindingLuid) {
            $spillProcess = $hostProcess.Process
            $spillReidentify = { Find-FastLlmProcessAdapter -Process $spillProcess -BudgetMs ([int] $script:FastLlmSpillLoopReadBudgetMs) }.GetNewClosure()
        }
        # Opt-in model switch: the request that waits for requests in progress, if any, and what was already answered.
        $switchPoll = @{ wait = $null; unsafeReported = $false; stuckStamp = $null }
        # With the API key on, the busy read of a switch goes through the run's keyed sender; without a key nothing is added to the call.
        $switchMetricsOption = @{}
        if ($apiKeyRequested) { $switchMetricsOption.MetricsRequest = $apiKeyRequest }
        $switchCurrentRecipeId = ''
        if ($AllowSwitch -and $Plan.PSObject.Properties['recipe'] -and $Plan.recipe -and $Plan.recipe.PSObject.Properties['id'] -and $Plan.recipe.id) { $switchCurrentRecipeId = [string] $Plan.recipe.id }
        while (-not $hostProcess.Process.WaitForExit(250)) {
            if (Test-Path -LiteralPath $stopPath) { $state.stopReason='user'; $state.phase='stopped'; return 0 }
            # Only a start with -AllowSwitch looks for a switch request, and only after the stop check above: stop always wins.
            if ($AllowSwitch) {
                if (Test-FastLlmSwitchPriorStop -Paths $switchPriorStopPaths) { $state.stopReason='user'; $state.phase='stopped'; return 0 }
                $switchStep = Step-FastLlmSwitchPoll -Poll $switchPoll -RequestPath $switchRequestPath -CatalogPath $CatalogPath -InstallRoot $InstallRoot -BaseUrl $baseUrl `
                    -CurrentModelId ([string] $Plan.model.id) -CurrentRecipeId $switchCurrentRecipeId -ServingProfileActive ([bool] ($null -ne $servingProfile)) @switchMetricsOption
                if ($null -ne $apiKeyRunExposure.failure) { throw $apiKeyRunExposure.failure }
                if ($null -ne $switchStep) {
                    $switchFrom = [string] $Plan.model.id
                    $switchTo = [string] $switchStep.toModelId
                    # Ids only, and the target only when it is a catalog id: nothing a request carried is logged.
                    if ($switchStep.first) { Add-FastLlmRunLogEvent -InstallRoot $InstallRoot -State $state -Event 'switch-request' -Fields { Get-FastLlmRunLogSwitchRequestFields -FromModelId $switchFrom -ToModelId $switchTo } }
                    $state['switch'] = New-FastLlmSwitchBlock -From $switchFrom -To $switchTo -Pending
                    if ([string] $switchStep.action -ceq 'accept') {
                        # A stop that arrived while the request was read or waited on is honoured instead of the switch.
                        if (Test-Path -LiteralPath $stopPath) { $state.stopReason='user'; $state.phase='stopped'; return 0 }
                        # The server is idle (or the request says force): this run ends stopped, and Start-FastLlmServer starts the other model.
                        $switchAccepted = $true
                        $SwitchContext['accepted'] = @{ modelId = $switchTo; recipeId = $switchStep.recipeId; fromModelId = $switchFrom }
                        $state.stopReason='switch'
                        $state.phase='stopped'
                        return 0
                    }
                    if ([string] $switchStep.action -ceq 'refused') {
                        # The server keeps running. Busy for the whole wait is its own result; every other refusal carries its code.
                        if ([string] $switchStep.code -ceq 'refused-busy') { Set-FastLlmSwitchResult -State $state -InstallRoot $InstallRoot -Result 'refused-busy' }
                        else { Set-FastLlmSwitchResult -State $state -InstallRoot $InstallRoot -Result 'refused' -FailureCode ([string] $switchStep.code) }
                    }
                    try { $state.updatedAt = (Get-Date).ToUniversalTime().ToString('o'); Write-FastLlmState -InstallRoot $InstallRoot -State $state } catch { $null = $_ }
                }
            }
            # Opt-in embedding sidecar, only now that the text model is Ready and after the stop and switch checks above: one step per pass
            # (start, wait for its model, its own checks, then watch it); a pass sends it at most one request. Whatever happens to it changes
            # only its own block, with ONE exception: api-key-listener-changed (a listener that changed right after a request with the key was
            # sent). The key is the text server's too, so that ends this run exactly as the text server's own listener change does, before any
            # status document is written for it.
            $sidecarChanged = $false
            if ($null -ne $SidecarSession) { $sidecarChanged = [bool] (Step-FastLlmSidecar -Session $SidecarSession -InstallRoot $InstallRoot -State $state -TextPort ([int] $uri.Port)) }
            if ($null -ne $SidecarSession -and $null -ne $SidecarSession['exposure']) {
                if ($null -eq $apiKeyRunExposure.failure) { $apiKeyRunExposure.failure = $SidecarSession['exposure'] }
                throw $apiKeyRunExposure.failure
            }
            if ($sidecarChanged) {
                try { $state.updatedAt = (Get-Date).ToUniversalTime().ToString('o'); Write-FastLlmState -InstallRoot $InstallRoot -State $state } catch { $null = $_ }
            }
            # The GPU memory re-check, every 60 s. The read is time-boxed (200 ms), so the stop file above is still seen within one pass.
            # Only a change of state is logged and printed; the status always carries the latest numbers.
            $spillTick = Invoke-FastLlmSpillCheckTick -Previous $state.spillCheck -Now (Get-Date).ToUniversalTime() -NextDueUtc $spillNextCheck -Luid $spillLuid -Process $hostProcess.Process -Reidentify $spillReidentify
            if ($null -ne $spillTick) {
                $spillNextCheck = $spillTick.nextDueUtc
                if ($null -ne $spillTick.PSObject.Properties['luid']) { $spillLuid = [string] $spillTick.luid }
                $state.spillCheck = $spillTick.spillCheck
                if ($spillTick.event -ceq 'spill-check-changed') {
                    Add-FastLlmRunLogEvent -InstallRoot $InstallRoot -State $state -Event 'spill-check-changed' -Fields { Get-FastLlmSpillCheckEventFields -Step $spillTick }
                    $spillChangeText = Get-FastLlmSpillCheckText -SpillCheck $state.spillCheck
                    if ($spillChangeText -and ([string] $state.spillCheck.state -cne 'unknown' -or -not $spillUnknownShown)) {
                        Write-Host $spillChangeText
                        if ([string] $state.spillCheck.state -ceq 'unknown') { $spillUnknownShown = $true }
                    }
                }
                try { $state.updatedAt = (Get-Date).ToUniversalTime().ToString('o'); Write-FastLlmState -InstallRoot $InstallRoot -State $state } catch { }
            }
            if ($IdleStopMinutes -gt 0) {
                $idleNow = (Get-Date).ToUniversalTime()
                if ($idleNow -ge $idleNextPoll) {
                    $idleNextPoll = $idleNow.AddSeconds($script:FastLlmIdlePollSeconds)
                    $idleStep = Invoke-FastLlmIdleStopPoll -State $idleDetector -Fetch { Get-FastLlmIdleMetricsText -BaseUrl $baseUrl -Request $apiKeyRequest -Result $idleRead } -Now $idleNow -IdleMinutes $IdleStopMinutes
                    $idleDetector = $idleStep.state
                    if ($null -ne $apiKeyRunExposure.failure) { throw $apiKeyRunExposure.failure }
                    # With an embedding sidecar the idle stop counts both servers: activity on the sidecar, or a read of its /metrics that
                    # proves nothing, resets the idle clock and withholds the stop.
                    if ($null -ne $SidecarSession) {
                        $idleStep = Join-FastLlmSidecarIdle -Session $SidecarSession -Step $idleStep -Now $idleNow -InstallRoot $InstallRoot -State $state; $idleDetector = $idleStep.state
                        # The sidecar's keyed read saw its listener change right after the send: not a failed read, the run ends (see above).
                        if ($null -ne $SidecarSession['exposure']) {
                            if ($null -eq $apiKeyRunExposure.failure) { $apiKeyRunExposure.failure = $SidecarSession['exposure'] }
                            throw $apiKeyRunExposure.failure
                        }
                    }
                    # A read refused with 401 (the key the server enforces is not the one this run holds) is a failed read like any other:
                    # it never stops the server. It is logged once for each run of refused reads, so the mismatch is not silent.
                    if ($idleStep.readFailed -and [int] $idleRead.status -eq 401) {
                        if (-not $idleUnauthorizedLogged) {
                            $idleUnauthorizedLogged = $true
                            Add-FastLlmRunLogEvent -InstallRoot $InstallRoot -State $state -Event 'idle-metrics-unauthorized' -Fields @{}
                        }
                    }
                    elseif (-not $idleStep.readFailed) { $idleUnauthorizedLogged = $false }
                    if ($idleStep.readFailed -and [int] $idleDetector.failedReads -eq 1) {
                        # Logged once for each run of failed reads in a row, however long it lasts. Nothing is stopped for it.
                        Add-FastLlmRunLogEvent -InstallRoot $InstallRoot -State $state -Event 'idle-check-failed' -Fields @{}
                    }
                    # A user Stop that arrived during the poll wins: the next pass sees the stop file and records a user stop.
                    if ($idleStep.shouldStop -and -not (Test-Path -LiteralPath $stopPath)) {
                        $state.stopReason='idle'
                        $state.stoppedAtUtc=$idleNow.ToString('o')
                        $idleLastActivity = ([datetime] $idleDetector.lastActivityUtc).ToUniversalTime().ToString('o')
                        Add-FastLlmRunLogEvent -InstallRoot $InstallRoot -State $state -Event 'idle-stop' -Fields {
                            [ordered] @{ idleStopMinutes = [int] $IdleStopMinutes; lastActivityUtc = $idleLastActivity; stoppedAtUtc = [string] $state.stoppedAtUtc } }
                        $state.phase='stopped'
                        return 0
                    }
                }
            }
        }
        $exitCode = $hostProcess.Process.ExitCode
        if ($exitCode -ne 0) { throw 'Server exited unexpectedly after readiness.' }
        $state.phase='stopped'
        return $exitCode
    } catch {
        $state.phase='failed'
        # What is recorded about a failure passes the key scrub first (with this run's key, when there is one).
        $runFailureText = [string] $_.Exception.Message
        $runFailureMessage = ConvertTo-FastLlmKeyFreeText -Text ([ref] $runFailureText) -ApiKeyHolder $ApiKeyHolder
        # A key that may have been sent to another program decides the outcome, whatever the failing step raised in its place: the code,
        # the never-retried reason and the fixed text that says to create a new key.
        if ($null -ne $apiKeyRunExposure.failure) {
            $runFailureMessage = [string] $apiKeyRunExposure.failure.Message
            $_.Exception.Data['FastLlmReason'] = 'ApiKeyFailed'
            $_.Exception.Data['FastLlmFailureCode'] = 'api-key-listener-changed'
            $_.Exception.Data.Remove('FastLlmStateWrite')
        }
        # A failure after the server was ready (a crash while serving) is not a start failure: the start-time fallback never applies to it.
        if ($reachedReady) { $_.Exception.Data['FastLlmAfterReady']=$true }
        if ($_.Exception.Data['FastLlmStateWrite'] -eq $true) {
            # A status-file write failure is not a model/runtime failure: it must never trigger model-switch recovery.
            $state.failureCode='state-write-failed'
            $_.Exception.Data['FastLlmReason']='StateWriteFailed'
        } elseif ($_.Exception.Data['FastLlmReason'] -ceq 'DeviceBindingFailed') {
            # A device-binding failure (enforce) is not a model/runtime failure: keep its reason so it is never overwritten by
            # RuntimeCheckFailed and never triggers model recovery or a model swap. The code is sanitised; anything outside the
            # pattern is recorded as device-binding-unavailable.
            $bindingFailureCode=ConvertTo-FastLlmDeviceBindingCode -Code ([string]$_.Exception.Data['FastLlmFailureCode'])
            $state.failureCode=$bindingFailureCode
            # Write the sanitised value back so the supervisor state and the CLI's outer catch (which records Data into status.json) carry the same code.
            $_.Exception.Data['FastLlmFailureCode']=$bindingFailureCode
        } elseif ($_.Exception.Data['FastLlmReason'] -ceq 'PortInUse') {
            # An occupied port (found before the spawn, or reported by the engine's own bind error) keeps its typed code and reason: model
            # recovery and the start-time fallback would only meet the same port.
            $state.failureCode='port-in-use'
        } elseif ($_.Exception.Data['FastLlmReason'] -ceq 'ApiKeyFailed') {
            # A key failure (not enforced, the listener is not this run's server, a malformed key) keeps its typed code and a reason that is
            # never retried, recovered with another model or replaced by the stand-in setup.
            $apiKeyFailureCode = [string] $_.Exception.Data['FastLlmFailureCode']
            if ($apiKeyFailureCode -cnotmatch '^api-key-[a-z-]{1,40}$') { $apiKeyFailureCode = 'api-key-unavailable' }
            $state.failureCode = $apiKeyFailureCode
        } elseif ($_.Exception.Data['FastLlmReason'] -ceq 'HipDllFailed') {
            # A blocked or missing HIP DLL keeps its typed code and a reason that model recovery does not retry (recovery would re-plan onto Vulkan).
            $state.failureCode=[string]$_.Exception.Data['FastLlmFailureCode']
        } else {
            $state.failureCode='startup-or-runtime-check-failed'
            if($spawned){$_.Exception.Data['FastLlmReason']='RuntimeCheckFailed'}
        }
        # A start that did not become ready during a switch: the code its switch block is recorded with travels with the failure, so the
        # document of the restore names the same code as this one.
        if ($AllowSwitch -and -not $reachedReady) {
            $switchRunFailureCode = Get-FastLlmSwitchFailureCode -Exception $_.Exception -StatusCode ([string] $state.failureCode)
            $_.Exception.Data['FastLlmSwitchFailureCode'] = $switchRunFailureCode
        }
        # A failure whose own text holds the key (or what the server prints of it) is not passed on as it is: every later reader - the
        # command line, the window, the background record, the stand-in start's console line - gets a copy with the scrubbed text and the same data.
        if ($runFailureMessage -cne [string] $_.Exception.Message) {
            $scrubbedFailure = New-Object -TypeName System.InvalidOperationException -ArgumentList $runFailureMessage
            foreach ($failureDataKey in @($_.Exception.Data.Keys)) { $scrubbedFailure.Data[$failureDataKey] = $_.Exception.Data[$failureDataKey] }
            throw $scrubbedFailure
        }
        throw
    } finally {
        # The switch block is settled before the final document and the end event are written. A run that was the outcome of a switch and did
        # not become ready: the one restore that did not serve is failed-stopped (there is no third attempt); a failed target stays pending, with
        # its code, because the restore follows; a stop is a cancelled switch. A request that was still waiting when the run ended is answered.
        if ($AllowSwitch) {
            try {
                if ($null -ne $switchOrigin -and -not $reachedReady) {
                    $state['switch'] = New-FastLlmSwitchBlock -From ([string] $switchOrigin.from) -To ([string] $switchOrigin.to) -Pending -FailureCode ([string] $switchOrigin.failureCode)
                    if ([string] $switchOrigin.role -ceq 'restore') { Set-FastLlmSwitchResult -State $state -InstallRoot $InstallRoot -Result 'failed-stopped' -FailureCode ([string] $switchOrigin.failureCode) }
                    elseif ([string] $state.phase -ceq 'failed') { $state['switch'] = New-FastLlmSwitchBlock -From ([string] $switchOrigin.from) -To ([string] $switchOrigin.to) -Pending -FailureCode ([string] $switchRunFailureCode) }
                    else { Set-FastLlmSwitchResult -State $state -InstallRoot $InstallRoot -Result 'refused' -FailureCode 'switch-cancelled-by-stop' }
                }
                elseif ($state.Contains('switch') -and $state['switch'].Contains('pending') -and -not $switchAccepted) {
                    $switchEndCode = 'switch-cancelled-by-stop'
                    if ([string] $state.phase -ceq 'failed') { $switchEndCode = 'switch-server-exited' }
                    Set-FastLlmSwitchResult -State $state -InstallRoot $InstallRoot -Result 'refused' -FailureCode $switchEndCode
                }
            } catch { $null = $_ }
        }
        # Opt-in embedding sidecar: this run ends the session's serving (a stop, an idle stop, a failure after Ready, a restore that did not
        # serve), so the sidecar is stopped with it, before the final document is written. It is kept only when another run of the text model
        # follows in the same session: a model switch was accepted, or this run was a switch target that failed and the previous model is
        # restored next (not after a key that may have been sent to another program: that ends the sequence).
        if ($null -ne $SidecarSession) {
            $sidecarKeep = [bool] ($switchAccepted -or ($null -ne $switchOrigin -and [string] $switchOrigin.role -ceq 'target' -and -not $reachedReady -and
                    [string] $state.phase -ceq 'failed' -and [string] $state.failureCode -cne 'api-key-listener-changed'))
            try { Exit-FastLlmSidecarRun -Session $SidecarSession -InstallRoot $InstallRoot -State $state -Keep:$sidecarKeep } catch { $null = $_ }
        }
        # Run log: a run with speculation that reached Ready writes one spec-summary at its end, read from /metrics while the server is still up.
        # A counter the server does not list, or a metrics read that fails, is recorded as null (never 0). Best-effort: it can never change a stop.
        if ($speculation -and $reachedReady -and $spawned) {
            try {
                $summaryText = $null
                try { $summaryText = Get-FastLlmIdleMetricsText -BaseUrl $baseUrl -Request $apiKeyRequest } catch { $summaryText = $null }
                $summaryEntry = Get-FastLlmSpeculationAllowlistEntry -EngineId ([string] $speculation.engineId)
                $summaryCounters = Get-FastLlmSpeculationCounters -MetricsText ([string] $summaryText) -Counters $summaryEntry.counters
                Add-FastLlmRunLogEvent -InstallRoot $InstallRoot -State $state -Event 'spec-summary' -Fields { Get-FastLlmRunLogSpecSummaryFields -Counters $summaryCounters }
            } catch { $null = $_ }
        }
        # Run log: the final phase and the end event (before the child is disposed, so its exit code is read if it already exited).
        $serverExitCode = $null
        try { if ($spawned -and $hostProcess.Process.HasExited) { $serverExitCode = [int] $hostProcess.Process.ExitCode } } catch { $null = $_ }
        Add-FastLlmRunLogEvent -InstallRoot $InstallRoot -State $state -Event 'phase' -Fields {
            $f = [ordered] @{ phase = [string] $state.phase }
            if ($state.failureCode) { $f.failureCode = [string] $state.failureCode }
            $f }
        Add-FastLlmRunLogEvent -InstallRoot $InstallRoot -State $state -Event 'end' -Fields {
            $f = [ordered] @{ phase = [string] $state.phase; exitCode = $(if ($state.phase -ceq 'failed') { 1 } else { 0 }) }
            if ($state.failureCode) { $f.failureCode = [string] $state.failureCode }
            if ($state.phase -ceq 'failed' -and $null -ne $runFailureMessage) { $f.failedAtPhase = $runPhase; $f.failureMessage = $runFailureMessage }
            if ($null -ne $serverExitCode) { $f.serverExitCode = $serverExitCode }
            $f }
        try { $hostProcess.Dispose() }
        finally {
            try {
                $state.updatedAt=(Get-Date).ToUniversalTime().ToString('o')
                # The write already retries within a bounded budget; a transient failure must not turn a clean stop into exit 1.
                try { Write-FastLlmState -InstallRoot $InstallRoot -State $state }
                catch { if ($_.Exception.Data['FastLlmStateWrite'] -eq $true) { Write-Warning 'The final status write failed after retries; the previous status document is unchanged.' } else { throw } }
            } finally {
                try { Remove-FastLlmRuntimeSandbox $sandbox }
                finally {
                    # The request file is run-scoped, so a leftover is harmless; a sharing violation here is transient (the
                    # requesting client or a scanner still holds it) and must not turn a clean stop into exit 1.
                    # A run that ended for a model switch leaves a stop request in place: a stop that arrived while this server was shutting down
                    # names this run, and the switch that follows must still see it (stop always wins). The switch removes it.
                    for ($attempt = 0; (-not $switchAccepted) -and (Test-Path -LiteralPath $stopPath); $attempt++) {
                        try { Remove-Item -LiteralPath $stopPath -Force -ErrorAction Stop; break }
                        catch {
                            if ($attempt -ge 9) { Write-Warning "The stop request file could not be removed after retries: $stopPath"; break }
                            Start-Sleep -Milliseconds 15
                        }
                    }
                    if ($AllowSwitch) {
                        # The switch request is run-scoped too: a plain leftover is removed, an unsafe object is never touched. A stop that named a
                        # previous run was honoured by now.
                        try { [void] (Remove-FastLlmSwitchRequestFile -Path $switchRequestPath) } catch { $null = $_ }
                        try { [void] (Remove-FastLlmSwitchRequestFile -Path $switchBasisPath) } catch { $null = $_ }
                        try { Remove-FastLlmSwitchPriorStop -Paths $switchPriorStopPaths } catch { $null = $_ }
                    }
                }
            }
        }
    }
}
