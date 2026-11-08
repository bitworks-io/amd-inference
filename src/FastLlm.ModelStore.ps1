# Downloaded-model manager: list the installed models and the leftover partial downloads, and remove them safely.
# Every path is built from the install root plus a catalog `file` field (or a leftover name this module listed itself), never from user input.
# Consent receipts under consents\ are never touched. Nothing here hashes a model file.

# A sharing violation (ERROR_SHARING_VIOLATION / ERROR_LOCK_VIOLATION as an IOException HResult): llama-server still has the file open.
$script:FastLlmSharingViolationHResults = @(-2147024864, -2147024863)

function Get-FastLlmModelStoreDirectory {
    param([Parameter(Mandatory = $true)][string] $InstallRoot)
    return (Join-FastLlmContainedPath -Root $InstallRoot -Child 'models' -Label 'Models root')
}

# Walks an exception chain (a seam or Remove-Item may wrap the real one) and classifies a failed delete.
function Get-FastLlmModelStoreDeleteFailureReason {
    param($Exception)
    $current = $Exception
    for ($depth = 0; $current -and $depth -lt 8; $depth++) {
        if ($current -is [UnauthorizedAccessException]) { return 'access-denied' }
        if ($current -is [IO.IOException] -and ($script:FastLlmSharingViolationHResults -contains [int] $current.HResult)) { return 'in-use' }
        $current = $current.InnerException
    }
    return 'delete-failed'
}

# True when the downloader holds the lock file open (it opens it FileShare.None). A missing or openable lock is stale and does not count.
function Test-FastLlmModelStoreLockHeld {
    param([Parameter(Mandatory = $true)][string] $LockPath)
    if (-not (Test-Path -LiteralPath $LockPath -PathType Leaf)) { return $false }
    $handle = $null
    try {
        $handle = New-Object IO.FileStream($LockPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        return $false
    }
    catch [IO.FileNotFoundException] { return $false }
    catch [IO.DirectoryNotFoundException] { return $false }
    catch { return $true }
    finally { if ($handle) { $handle.Dispose() } }
}

# live | dead | unknown for a background host identity {pid, startUtcTicks}: live only when a process with that pid exists and started at that tick.
function Get-FastLlmModelStoreHostState {
    param($Identity)
    if ($null -eq $Identity) { return 'unknown' }
    $pidValue = 0
    $ticks = 0L
    try {
        if (-not $Identity.PSObject.Properties['pid'] -or -not $Identity.PSObject.Properties['startUtcTicks']) { return 'unknown' }
        if (-not [int]::TryParse([string] $Identity.pid, [ref] $pidValue) -or $pidValue -le 0 -or
            -not [long]::TryParse([string] $Identity.startUtcTicks, [ref] $ticks) -or $ticks -le 0) { return 'unknown' }
    }
    catch { return 'unknown' }
    $process = $null
    try { $process = [Diagnostics.Process]::GetProcessById($pidValue) }
    catch [ArgumentException] { return 'dead' }
    catch { return 'unknown' }
    try {
        if ($process.HasExited) { return 'dead' }
        if ($process.StartTime.ToUniversalTime().Ticks -eq $ticks) { return 'live' }
        return 'dead'
    }
    catch { return 'unknown' }
    finally { $process.Dispose() }
}

# What the model store must respect, read once: the supervised server's status and the background host record (both tolerant reads).
# The background record is read directly (capped at 64 KiB, a reparse point refused); in doubt, the model counts as busy.
function Get-FastLlmModelStoreBusyContext {
    param([Parameter(Mandatory = $true)][string] $InstallRoot, [switch] $SkipStatus)
    $context = [ordered]@{ statusUnknown = $false; statusActive = $false; statusModelId = ''; backgroundUnknown = $false; backgroundBusy = $false; backgroundModelId = '' }
    if (-not $SkipStatus) {
        try {
            $status = Get-FastLlmStatus -InstallRoot $InstallRoot
            $context.statusActive = [bool] $status.active
            if ($status.PSObject.Properties['modelId']) { $context.statusModelId = [string] $status.modelId }
        }
        catch { $context.statusUnknown = $true }
    }
    try {
        $recordPath = Join-Path (Join-Path ([IO.Path]::GetFullPath($InstallRoot)) 'state') 'background-host.json'
        if (Test-Path -LiteralPath $recordPath) {
            $item = Get-Item -LiteralPath $recordPath -Force -ErrorAction Stop
            if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe background host record.' }
            $record = Read-FastLlmJson -Path $recordPath -MaxBytes 65536
            if ($null -eq $record) { throw 'Empty background host record.' }
            $phase = if ($record.PSObject.Properties['phase']) { [string] $record.phase } else { '' }
            if ($phase -cnotin @('stopped', 'failed')) {
                # No existing action rewrites a crashed host's record, so a record whose host process is provably gone does not own the model.
                # Any doubt about the identity or the process counts as alive.
                $hostState = Get-FastLlmModelStoreHostState -Identity $(if ($record.PSObject.Properties['hostIdentity']) { $record.hostIdentity } else { $null })
                if ($hostState -ceq 'unknown') { throw 'Background host identity is unclear.' }
                if ($hostState -ceq 'live') {
                    $context.backgroundBusy = $true
                    if ($record.PSObject.Properties['modelId'] -and $null -ne $record.modelId) { $context.backgroundModelId = [string] $record.modelId }
                }
            }
        }
    }
    catch { $context.backgroundUnknown = $true }
    return [pscustomobject] $context
}

# '' when nothing holds the model, else serving | background-owned | download-in-progress.
function Get-FastLlmModelStoreBusyReason {
    param([Parameter(Mandatory = $true)] $Model, [Parameter(Mandatory = $true)][string] $InstallRoot, [Parameter(Mandatory = $true)] $Context)
    if ($Context.statusUnknown) { return 'serving' }
    if ($Context.statusActive -and $Context.statusModelId -ceq [string] $Model.id) { return 'serving' }
    if ($Context.backgroundUnknown) { return 'background-owned' }
    if ($Context.backgroundBusy -and $Context.backgroundModelId -ceq [string] $Model.id) { return 'background-owned' }
    $modelsRoot = Get-FastLlmModelStoreDirectory -InstallRoot $InstallRoot
    $lockName = [string] $Model.file + '.' + ([string] $Model.sha256).Substring(0, 16) + '.lock'
    if (Test-FastLlmModelStoreLockHeld -LockPath (Join-FastLlmContainedPath -Root $modelsRoot -Child $lockName -Label 'Download lock')) { return 'download-in-progress' }
    return ''
}

function Get-FastLlmInstalledModels {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $InstallRoot, [Parameter(Mandatory = $true)][string] $CatalogPath)
    $catalog = Get-FastLlmCatalog -CatalogPath $CatalogPath
    $modelsRoot = Get-FastLlmModelStoreDirectory -InstallRoot $InstallRoot
    $context = $null
    $rows = New-Object System.Collections.ArrayList
    foreach ($model in @($catalog.models)) {
        $path = $null
        try { $path = Join-FastLlmContainedPath -Root $modelsRoot -Child ([string] $model.file) -Label 'Model file' } catch { continue }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $length = [int64] (Get-Item -LiteralPath $path -Force).Length
        $consent = [bool] (Test-FastLlmModelConsentReceipt -Model $model -InstallRoot $InstallRoot)
        if ($null -eq $context) { $context = Get-FastLlmModelStoreBusyContext -InstallRoot $InstallRoot }
        $reason = Get-FastLlmModelStoreBusyReason -Model $model -InstallRoot $InstallRoot -Context $context
        [void] $rows.Add([pscustomobject]@{
            id           = [string] $model.id
            file         = [string] $model.file
            sizeBytes    = [int64] $length
            present      = $true
            sizeMatches  = [bool] ($length -eq [int64] $model.sizeBytes)
            consent      = $consent
            inUse        = [bool] ($reason -ne '')
            inUseReason  = $reason
        })
    }
    return @($rows)
}

function Get-FastLlmModelLeftovers {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $InstallRoot)
    $modelsRoot = Get-FastLlmModelStoreDirectory -InstallRoot $InstallRoot
    if (-not (Test-Path -LiteralPath $modelsRoot -PathType Container)) { return @() }
    $rows = New-Object System.Collections.ArrayList
    foreach ($item in @(Get-ChildItem -LiteralPath $modelsRoot -Force -File -ErrorAction Stop | Sort-Object -Property Name)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        $name = [string] $item.Name
        $kind = $null
        $locked = $false
        if ($name -cmatch '\.partial$') {
            $kind = 'partial'
            $locked = Test-FastLlmModelStoreLockHeld -LockPath (Join-Path $modelsRoot ($name.Substring(0, $name.Length - '.partial'.Length) + '.lock'))
        }
        elseif ($name -cmatch '\.corrupt\.' -or $name -cmatch '^[0-9a-f]{8}\.corrupt$') { $kind = 'corrupt' }
        if (-not $kind) { continue }
        [void] $rows.Add([pscustomobject]@{ name = $name; sizeBytes = [int64] $item.Length; kind = $kind; locked = [bool] $locked })
    }
    return @($rows)
}

# Takes the operation lock without waiting unless the caller already holds it. Returns the handle (or $null when the caller holds it); throws on busy.
function Enter-FastLlmModelStoreLock {
    param([string] $InstallRoot, [switch] $OperationLockHeld)
    if ($OperationLockHeld) { return $null }
    try { return (Enter-FastLlmOperation -InstallRoot $InstallRoot) }
    catch { throw 'operation-in-progress' }
}

function Remove-FastLlmInstalledModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $InstallRoot,
        [Parameter(Mandatory = $true)][string] $CatalogPath,
        [Parameter(Mandatory = $true)][string] $ModelId,
        [switch] $OperationLockHeld,
        # Test seam for the delete itself.
        [scriptblock] $DeleteFile = { param($Path) Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
    )
    $result = { param($removed, $reason, $bytes) [pscustomobject]@{ modelId = $ModelId; removed = [bool] $removed; reason = [string] $reason; bytes = [int64] $bytes } }
    $catalog = Get-FastLlmCatalog -CatalogPath $CatalogPath
    $model = @($catalog.models | Where-Object { [string] $_.id -ceq $ModelId })[0]
    if ($null -eq $model) { return (& $result $false 'not-in-catalog' 0) }
    $path = $null
    try { $path = Join-FastLlmContainedPath -Root (Get-FastLlmModelStoreDirectory -InstallRoot $InstallRoot) -Child ([string] $model.file) -Label 'Model file' }
    catch { return (& $result $false 'path-outside-install-root' 0) }
    # A models folder or a model file that is a link could lead outside the install root: refuse it rather than follow it.
    foreach ($linkCandidate in @((Get-FastLlmModelStoreDirectory -InstallRoot $InstallRoot), $path)) {
        if ((Test-Path -LiteralPath $linkCandidate) -and ((Get-Item -LiteralPath $linkCandidate -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { return (& $result $false 'path-outside-install-root' 0) }
    }
    # A present file is removable even when it is short or has no consent record (those are the files users most want gone); not-installed means absent.
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return (& $result $false 'not-installed' 0) }
    $bytes = [int64] (Get-Item -LiteralPath $path -Force).Length
    # A caller that does not hold the operation lock reads the server status first (the lock it takes next would make that status read "active" itself).
    if (-not $OperationLockHeld) {
        $earlyContext = Get-FastLlmModelStoreBusyContext -InstallRoot $InstallRoot
        if ($earlyContext.statusUnknown -or ($earlyContext.statusActive -and $earlyContext.statusModelId -ceq [string] $model.id)) { return (& $result $false 'serving' 0) }
    }
    $lock = $null
    try {
        try { $lock = Enter-FastLlmModelStoreLock -InstallRoot $InstallRoot -OperationLockHeld:$OperationLockHeld }
        catch { return (& $result $false 'operation-in-progress' 0) }
        # With the lock held by us nothing is serving, so the status "active" flag (our own handle) is not consulted again.
        $context = Get-FastLlmModelStoreBusyContext -InstallRoot $InstallRoot -SkipStatus
        $busy = Get-FastLlmModelStoreBusyReason -Model $model -InstallRoot $InstallRoot -Context $context
        if ($busy) { return (& $result $false $busy 0) }
        try { & $DeleteFile $path }
        catch {
            $reason = Get-FastLlmModelStoreDeleteFailureReason -Exception $_.Exception
            return (& $result $false $reason 0)
        }
        return (& $result $true 'ok' $bytes)
    }
    finally { if ($lock) { $lock.Dispose() } }
}

function Remove-FastLlmModelLeftovers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $InstallRoot,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Names,
        [switch] $OperationLockHeld,
        [scriptblock] $DeleteFile = { param($Path) Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
    )
    $results = New-Object System.Collections.ArrayList
    $row = { param($name, $removed, $reason, $bytes) [pscustomobject]@{ name = [string] $name; removed = [bool] $removed; reason = [string] $reason; bytes = [int64] $bytes } }
    $lock = $null
    try {
        try { $lock = Enter-FastLlmModelStoreLock -InstallRoot $InstallRoot -OperationLockHeld:$OperationLockHeld }
        catch {
            foreach ($name in @($Names)) { [void] $results.Add((& $row $name $false 'operation-in-progress' 0)) }
            return @($results)
        }
        $modelsRoot = Get-FastLlmModelStoreDirectory -InstallRoot $InstallRoot
        $listed = @(Get-FastLlmModelLeftovers -InstallRoot $InstallRoot)
        foreach ($name in @($Names)) {
            # Only a name the listing itself returned is ever deleted (exact, case-sensitive match).
            $entry = @($listed | Where-Object { [string] $_.name -ceq [string] $name })[0]
            if ($null -eq $entry) { [void] $results.Add((& $row $name $false 'not-a-leftover' 0)); continue }
            if ($entry.locked) { [void] $results.Add((& $row $name $false 'download-in-progress' 0)); continue }
            try { $path = Join-FastLlmContainedPath -Root $modelsRoot -Child ([string] $entry.name) -Label 'Leftover file' }
            catch { [void] $results.Add((& $row $name $false 'path-outside-install-root' 0)); continue }
            try { & $DeleteFile $path }
            catch {
                [void] $results.Add((& $row $name $false (Get-FastLlmModelStoreDeleteFailureReason -Exception $_.Exception) 0))
                continue
            }
            [void] $results.Add((& $row $name $true 'ok' $entry.sizeBytes))
        }
        return @($results)
    }
    finally { if ($lock) { $lock.Dispose() } }
}

# Decimal gigabytes, one decimal place, invariant culture.
function Format-FastLlmModelStoreGigabytes {
    param([int64] $Bytes)
    return ([double] $Bytes / 1e9).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-FastLlmModelRemovalConfirmationText {
    param([Parameter(Mandatory = $true)][string] $DisplayName, [Parameter(Mandatory = $true)][int64] $SizeBytes)
    return ('Removes {0} ({1} GB) from this PC. You can download it again later.' -f $DisplayName, (Format-FastLlmModelStoreGigabytes -Bytes $SizeBytes))
}

# Free bytes on the install root's drive, or $null when it cannot be read.
function Get-FastLlmModelStoreFreeBytes {
    param([Parameter(Mandatory = $true)][string] $InstallRoot)
    try { return [int64] (Get-FastLlmPreloadFreeBytes -Path $InstallRoot) } catch { return $null }
}

# A plain sentence for a refusal reason (the window shows it as a message, never as an error box with a stack trace).
function Get-FastLlmModelRemovalRefusalText {
    param([Parameter(Mandatory = $true)][string] $Reason)
    switch ($Reason) {
        'ok'                        { return '' }
        'not-in-catalog'            { return 'FastLLM does not list that model. Nothing was removed.' }
        'not-installed'             { return 'That model file is not on this PC. Nothing was removed.' }
        'path-outside-install-root' { return 'That model file is a link, so FastLLM left it alone. Nothing was removed.' }
        'serving'                   { return 'FastLLM is serving this model. Stop it first. Nothing was removed.' }
        'background-owned'          { return 'A background run uses this model. Stop it first. Nothing was removed.' }
        'operation-in-progress'     { return 'FastLLM is busy with another install, start or download. Try again when it has finished. Nothing was removed.' }
        'download-in-progress'      { return 'This model is being downloaded right now. Nothing was removed.' }
        'in-use'                    { return 'The server still has this model file open. Stop it and try again. Nothing was removed.' }
        'access-denied'             { return 'Windows did not allow the file to be deleted. Close anything that uses it and try again. Nothing was removed.' }
        default                     { return 'The file could not be deleted. Nothing was removed.' }
    }
}
