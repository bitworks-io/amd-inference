#requires -Version 5.1
# Bench model preload (fastllm.preload-set.v1). The preload set is every model the real planner (Get-FastLlmPlan) would pick for a
# single card of each common VRAM tier, plus the models of the recommended recipes. Tier budgets come from config/preload-tiers.json.
Set-StrictMode -Version 2

function Read-FastLlmPreloadTiers {
    param([Parameter(Mandatory = $true)][string] $Path)
    $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if (-not $document.PSObject.Properties['schemaVersion'] -or [int] $document.schemaVersion -ne 1) {
        throw "Preload tiers '$Path' has an unsupported schemaVersion."
    }
    $seen = @{}
    $tiers = @()
    foreach ($tier in @($document.tiers)) {
        $id = [string] $tier.id
        if ([string]::IsNullOrWhiteSpace($id)) { throw 'A preload tier has no id.' }
        if ($seen.ContainsKey($id)) { throw "Duplicate preload tier id '$id'." }
        $seen[$id] = $true
        $vram = [int] $tier.vramMiB
        $idle = [int] $tier.idleFreeVramMiB
        $conservative = [int] $tier.conservativeFreeVramMiB
        if (-not ($conservative -lt $idle -and $idle -lt $vram -and $conservative -gt 0)) {
            throw "Preload tier '$id' must satisfy 0 < conservativeFreeVramMiB < idleFreeVramMiB < vramMiB."
        }
        $tiers += [pscustomobject]@{
            id                      = $id
            vramMiB                 = $vram
            idleFreeVramMiB         = $idle
            conservativeFreeVramMiB = $conservative
            source                  = [string] $tier.source
        }
    }
    return @($tiers)
}

function Read-FastLlmApprovedModels {
    param([Parameter(Mandatory = $true)][string] $Path)
    $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if (-not $document.PSObject.Properties['schemaVersion'] -or [int] $document.schemaVersion -ne 1) {
        throw "Approved models list '$Path' has an unsupported schemaVersion."
    }
    return @($document.models | ForEach-Object { [pscustomobject]@{ modelId = [string] $_.modelId; revision = [string] $_.revision } })
}

# The optional "components" list of the approved file: { id; version } per approved component. A component is installed only when both match.
function Read-FastLlmApprovedComponents {
    param([Parameter(Mandatory = $true)][string] $Path)
    $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if (-not $document.PSObject.Properties['schemaVersion'] -or [int] $document.schemaVersion -ne 1) {
        throw "Approved models list '$Path' has an unsupported schemaVersion."
    }
    if (-not $document.PSObject.Properties['components'] -or $null -eq $document.components) { return @() }
    return @($document.components | ForEach-Object { [pscustomobject]@{ id = [string] $_.id; version = [string] $_.version } })
}

function Get-FastLlmPreloadSet {
    param(
        [Parameter(Mandatory = $true)][string] $CatalogPath,
        [Parameter(Mandatory = $true)][string] $RecipesPath,
        [Parameter(Mandatory = $true)][string] $GpuVariantsPath,
        [Parameter(Mandatory = $true)][string] $TiersPath,
        [string] $ApprovedModelsPath
    )

    $catalog = Get-FastLlmCatalog -CatalogPath $CatalogPath
    $tiers = @(Read-FastLlmPreloadTiers -Path $TiersPath | Sort-Object -Property vramMiB)
    $approvedList = $null
    if ($ApprovedModelsPath) { $approvedList = @(Read-FastLlmApprovedModels -Path $ApprovedModelsPath) }

    $entries = New-Object System.Collections.ArrayList
    $index = @{}
    $add = {
        param([string] $ModelId, [string] $Tier, [string] $Reason)
        if (-not $index.ContainsKey($ModelId)) {
            $catalogModel = @($catalog.models | Where-Object { [string] $_.id -eq $ModelId } | Select-Object -First 1)
            if ($catalogModel.Count -eq 0) { throw "Preload model '$ModelId' is not in the catalog." }
            $entry = [pscustomobject]@{
                modelId   = $ModelId
                file      = [string] $catalogModel[0].file
                sizeBytes = [int64] $catalogModel[0].sizeBytes
                sha256    = [string] $catalogModel[0].sha256
                revision  = [string] $catalogModel[0].revision
                license   = [string] $catalogModel[0].license
                tiers     = @()
                reasons   = @()
                approved  = $null
            }
            $index[$ModelId] = $entry
            [void] $entries.Add($entry)
        }
        $entry = $index[$ModelId]
        if ($Tier -and @($entry.tiers) -notcontains $Tier) { $entry.tiers = @($entry.tiers) + $Tier }
        if (@($entry.reasons) -notcontains $Reason) { $entry.reasons = @($entry.reasons) + $Reason }
    }

    $recipeDocument = Get-Content -LiteralPath $RecipesPath -Raw | ConvertFrom-Json
    foreach ($recipe in @($recipeDocument.recipes)) {
        if ($recipe.PSObject.Properties['recommended'] -and $recipe.recommended -eq $true) {
            & $add ([string] $recipe.components.model) '' 'recipe'
        }
    }

    $emptyTiers = @()
    foreach ($tier in $tiers) {
        foreach ($budget in @('idle', 'conservative')) {
            $free = if ($budget -eq 'idle') { $tier.idleFreeVramMiB } else { $tier.conservativeFreeVramMiB }
            $hardware = [pscustomobject]@{
                schemaVersion = 1
                source        = 'preload-tier'
                backend       = 'Vulkan'
                enginePath    = 'C:\FastLLM\vulkan\llama-server.exe'
                adapters      = @([pscustomobject]@{
                        device        = 'Vulkan0'
                        name          = "Preload tier $($tier.id)"
                        vendorId      = '1002'
                        vramMiB       = $tier.vramMiB
                        freeVramMiB   = $free
                        isAmd         = $true
                        isIntegrated  = $false
                        backend       = 'Vulkan'
                        driverVersion = 'preload-tier'
                    })
            }
            try {
                $plan = Get-FastLlmPlan -Hardware $hardware -CatalogPath $CatalogPath -Profile balanced -RecipesPath $RecipesPath -GpuVariantsPath $GpuVariantsPath -NoEngineExecution
            } catch {
                if ([string] $_.Exception.Message -like 'No catalog profile fits*') {
                    $emptyTiers += [pscustomobject]@{ tier = $tier.id; budget = $budget }
                    continue
                }
                throw
            }
            & $add ([string] $plan.model.id) $tier.id 'tier'
        }
    }

    if ($null -ne $approvedList) {
        foreach ($entry in $entries) {
            $entry.approved = [bool] (@($approvedList | Where-Object { $_.modelId -ceq $entry.modelId -and $_.revision -ceq $entry.revision }).Count -gt 0)
        }
    }

    return [pscustomobject]@{
        schema     = 'fastllm.preload-set.v1'
        models     = @($entries)
        emptyTiers = @($emptyTiers)
    }
}

function Test-FastLlmModelInstalled {
    param(
        [Parameter(Mandatory = $true)] $Model,
        [Parameter(Mandatory = $true)][string] $InstallRoot
    )
    # Fast check, no hashing: the file has the catalog size and the consent receipt matches the model.
    try {
        $modelsRoot = Join-FastLlmContainedPath -Root $InstallRoot -Child 'models' -Label 'Models root'
        $path = Join-FastLlmContainedPath -Root $modelsRoot -Child ([string] $Model.file) -Label 'Model file'
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        if ((Get-Item -LiteralPath $path).Length -ne [int64] $Model.sizeBytes) { return $false }
        return [bool] (Test-FastLlmModelConsentReceipt -Model $Model -InstallRoot $InstallRoot)
    }
    catch { return $false }
}


# ---- install loop, status contract, output helpers

# The engine-component chain (requires first, engine last) of every recommended recipe, de-duplicated, from config/components.json.
function Get-FastLlmPreloadComponents {
    param(
        [Parameter(Mandatory = $true)][string] $CatalogPath,
        [Parameter(Mandatory = $true)][string] $RecipesPath,
        [Parameter(Mandatory = $true)][string] $ComponentsPath
    )
    $catalog = Get-FastLlmCatalog -CatalogPath $CatalogPath
    $components = @(Get-FastLlmComponents -ComponentsPath $ComponentsPath)
    $recipeDocument = Get-Content -LiteralPath $RecipesPath -Raw | ConvertFrom-Json
    $seen = @{}
    $ordered = New-Object System.Collections.ArrayList
    foreach ($recipe in @($recipeDocument.recipes)) {
        if (-not ($recipe.PSObject.Properties['recommended'] -and $recipe.recommended -eq $true)) { continue }
        $engineId = Get-FastLlmRecipeEngineId -Recipe $recipe -Catalog $catalog
        foreach ($member in @(Get-FastLlmComponentChain -Components $components -Id $engineId)) {
            if ($seen.ContainsKey([string] $member.id)) { continue }
            $seen[[string] $member.id] = $true
            [void] $ordered.Add($member)
        }
    }
    return @($ordered)
}

# Free bytes on the drive that holds the path. [IO.DriveInfo] (not Get-PSDrive, which reads 0 for a standard user over SSH).
function Get-FastLlmPreloadFreeBytes {
    param([Parameter(Mandatory = $true)][string] $Path)
    $driveRoot = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path))
    return [int64] (New-Object System.IO.DriveInfo($driveRoot)).AvailableFreeSpace
}

function Get-FastLlmPreloadExitCode {
    param([object[]] $Rows)
    $actions = @($Rows | Where-Object { $_ } | ForEach-Object { [string] $_.action })
    if ($actions -contains 'failed') { return 4 }
    foreach ($waiting in @('awaiting-approval', 'awaiting-component-licence', 'disk-floor')) {
        if ($actions -contains $waiting) { return 2 }
    }
    return 0
}

# The fastllm.preload-run.v1 envelope printed by -Preload. -ErrorType (an exception type name only) marks an unexpected failure: exitCode 1 plus an additive error field.
function New-FastLlmPreloadRun {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Rows, [string] $ErrorType)
    $rowList = @($Rows | Where-Object { $_ })
    $run = [ordered]@{
        schema   = 'fastllm.preload-run.v1'
        exitCode = [int] (Get-FastLlmPreloadExitCode -Rows $rowList)
        rows     = $rowList
    }
    if ($ErrorType) {
        $run.exitCode = 1
        $run.error = $ErrorType
    }
    return [pscustomobject] $run
}

# -InputObject (not the pipeline) so a one-element or empty array property stays a JSON array.
function ConvertTo-FastLlmPreloadJson {
    param([Parameter(Mandatory = $true)] $InputObject)
    return (ConvertTo-Json -Depth 6 -InputObject $InputObject)
}

# Atomic write: same-folder temp, UTF-8 without a BOM, then the module's file-replace helper.
function Write-FastLlmPreloadOutputFile {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Json)
    $full = [IO.Path]::GetFullPath($Path)
    $directory = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null }
    $temporary = Join-Path $directory ('.' + [IO.Path]::GetFileName($full) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $moved = $false
    try {
        [IO.File]::WriteAllText($temporary, $Json, (New-Object System.Text.UTF8Encoding($false)))
        Move-FastLlmFileReplacing -Source $temporary -Destination $full
        $moved = $true
    }
    finally {
        if (-not $moved) { try { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue } } catch { } }
    }
}

function Install-FastLlmPreloadSet {
    param(
        [Parameter(Mandatory = $true)][string] $CatalogPath,
        [Parameter(Mandatory = $true)][string] $RecipesPath,
        [Parameter(Mandatory = $true)][string] $GpuVariantsPath,
        [Parameter(Mandatory = $true)][string] $TiersPath,
        [Parameter(Mandatory = $true)][string] $InstallRoot,
        [string] $ApprovedModelsPath,
        [string] $ComponentsPath,
        [switch] $AcceptModelLicense,
        [switch] $AcceptLicense,
        [switch] $Unattended,
        [switch] $Next,
        [switch] $DryRun,
        # GiB (1024^3) that must stay free after the download.
        [double] $MinFreeGB = 50,
        # Test seams. Installer: & $Installer $ModelId. ComponentInstaller: & $ComponentInstaller $ComponentEntry. FreeBytesProvider: & $FreeBytesProvider $InstallRoot.
        [scriptblock] $Installer,
        [scriptblock] $ComponentInstaller,
        [scriptblock] $FreeBytesProvider,
        # Optional collector: rows are added here as they are produced, so a caller still has them if this function throws.
        [System.Collections.ArrayList] $RowSink
    )

    if ([string]::IsNullOrWhiteSpace($ApprovedModelsPath)) {
        throw '-Preload requires -ApprovedModelsPath; no licence is accepted without an approved list.'
    }
    if (-not $ComponentsPath) { $ComponentsPath = Join-Path (Split-Path -Parent $CatalogPath) 'components.json' }
    $minFreeBytes = [int64] ($MinFreeGB * 1073741824)
    $approvedComponents = @(Read-FastLlmApprovedComponents -Path $ApprovedModelsPath)
    $set = Get-FastLlmPreloadSet -CatalogPath $CatalogPath -RecipesPath $RecipesPath -GpuVariantsPath $GpuVariantsPath -TiersPath $TiersPath -ApprovedModelsPath $ApprovedModelsPath
    $componentChain = @(Get-FastLlmPreloadComponents -CatalogPath $CatalogPath -RecipesPath $RecipesPath -ComponentsPath $ComponentsPath)
    $catalogModels = @((Get-FastLlmCatalog -CatalogPath $CatalogPath).models)

    if ($null -ne $RowSink) { $rows = $RowSink } else { $rows = New-Object System.Collections.ArrayList }
    $addRow = {
        param([string] $Kind, [string] $Id, [string] $Action, [int64] $Bytes, [double] $Seconds, $ErrorText)
        [void] $rows.Add([pscustomobject][ordered]@{ kind = $Kind; id = $Id; action = $Action; bytes = $Bytes; seconds = [Math]::Round($Seconds, 1); error = $ErrorText })
    }
    $hasRoomFor = {
        param([int64] $NeededBytes)
        if ($FreeBytesProvider) { $free = [int64] (& $FreeBytesProvider $InstallRoot) } else { $free = Get-FastLlmPreloadFreeBytes -Path $InstallRoot }
        return (($free - $NeededBytes) -ge $minFreeBytes)
    }
    # Component and model rows by state; the first item installed or failed ends a -Next run. A disk-floor row does not count.
    $stop = $false
    $ready = @{}     # component ids that are present, installed or (dry run) would be installed
    $blocked = @{}   # component id -> the action that kept it from being ready

    foreach ($component in $componentChain) {
        if ($stop) { break }
        $id = [string] $component.id
        $bytes = [int64] (Get-FastLlmPendingComponentRecord -Component $component).downloadBytes
        if (Test-FastLlmComponentInstallation -InstallRoot $InstallRoot -Component $component -Depth Presence) {
            $ready[$id] = $true
            & $addRow 'component' $id 'present' 0 0 $null
            continue
        }
        $listed = @($approvedComponents | Where-Object { $_.id -ceq $id -and $_.version -ceq [string] $component.version }).Count -gt 0
        if (-not ($AcceptLicense -and $listed)) {
            $blocked[$id] = 'awaiting-component-licence'
            & $addRow 'component' $id 'awaiting-component-licence' $bytes 0 $null
            continue
        }
        # Install-FastLlmComponent installs a missing requires too, so every requires must already be ready (approved) here.
        $blocker = $null
        if ($component.PSObject.Properties['requires'] -and $null -ne $component.requires) {
            foreach ($requiredId in @($component.requires)) {
                if (-not $ready.ContainsKey([string] $requiredId)) { $blocker = [string] $requiredId; break }
            }
        }
        if ($blocker) {
            $blockedAction = 'awaiting-component-licence'
            if ($blocked.ContainsKey($blocker) -and $blocked[$blocker] -ne 'failed') { $blockedAction = $blocked[$blocker] }
            if ($blocked.ContainsKey($blocker) -and $blocked[$blocker] -eq 'failed') { $blockedAction = 'failed' }
            $blocked[$id] = $blockedAction
            & $addRow 'component' $id $blockedAction $bytes 0 "required component '$blocker' is not available"
            continue
        }
        if (-not (& $hasRoomFor $bytes)) {
            $blocked[$id] = 'disk-floor'
            & $addRow 'component' $id 'disk-floor' $bytes 0 $null
            continue
        }
        if ($DryRun) {
            $ready[$id] = $true
            & $addRow 'component' $id 'would-install' $bytes 0 $null
            continue
        }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        try {
            if ($ComponentInstaller) { & $ComponentInstaller $component | Out-Null }
            else { Install-FastLlmComponent -ComponentsPath $ComponentsPath -ComponentId $id -InstallRoot $InstallRoot -AcceptLicense -Unattended:$Unattended -PassThru | Out-Null }
            $ready[$id] = $true
            & $addRow 'component' $id 'installed' $bytes $clock.Elapsed.TotalSeconds $null
        }
        catch {
            $blocked[$id] = 'failed'
            & $addRow 'component' $id 'failed' $bytes $clock.Elapsed.TotalSeconds ([string] $_.Exception.Message)
        }
        if ($Next) { $stop = $true }
    }

    foreach ($model in @($set.models)) {
        if ($stop) { break }
        $id = [string] $model.modelId
        $bytes = [int64] $model.sizeBytes
        # The receipt check needs the catalog entry itself (id, revision, license fields), not the preload-set entry.
        $catalogModel = @($catalogModels | Where-Object { [string] $_.id -ceq $id })[0]
        if (Test-FastLlmModelInstalled -Model $catalogModel -InstallRoot $InstallRoot) {
            & $addRow 'model' $id 'present' $bytes 0 $null
            continue
        }
        if ($model.approved -ne $true) {
            & $addRow 'model' $id 'awaiting-approval' $bytes 0 $null
            continue
        }
        $needed = $bytes
        try {
            $modelsRoot = Join-FastLlmContainedPath -Root $InstallRoot -Child 'models' -Label 'Models root'
            $partialPath = Join-FastLlmContainedPath -Root $modelsRoot -Child ([string] $model.file + '.' + ([string] $model.sha256).Substring(0, 16) + '.partial') -Label 'Model partial'
            if (Test-Path -LiteralPath $partialPath -PathType Leaf) { $needed = [Math]::Max([int64] 0, $bytes - [int64] (Get-Item -LiteralPath $partialPath).Length) }
        }
        catch { $needed = $bytes }
        if (-not (& $hasRoomFor $needed)) {
            & $addRow 'model' $id 'disk-floor' $bytes 0 $null
            continue
        }
        if ($DryRun) {
            & $addRow 'model' $id 'would-install' $bytes 0 $null
            continue
        }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        try {
            if ($Installer) { & $Installer $id | Out-Null }
            else { Install-FastLlmCatalogModel -ModelId $id -CatalogPath $CatalogPath -InstallRoot $InstallRoot -AcceptModelLicense:$AcceptModelLicense -Unattended:$Unattended | Out-Null }
            & $addRow 'model' $id 'installed' $bytes $clock.Elapsed.TotalSeconds $null
        }
        catch {
            & $addRow 'model' $id 'failed' $bytes $clock.Elapsed.TotalSeconds ([string] $_.Exception.Message)
        }
        if ($Next) { $stop = $true }
    }
    return @($rows)
}

function Get-FastLlmPreloadStatus {
    param(
        [Parameter(Mandatory = $true)][string] $CatalogPath,
        [Parameter(Mandatory = $true)][string] $RecipesPath,
        [Parameter(Mandatory = $true)][string] $GpuVariantsPath,
        [Parameter(Mandatory = $true)][string] $TiersPath,
        [Parameter(Mandatory = $true)][string] $InstallRoot,
        [string] $ApprovedModelsPath,
        [string] $ComponentsPath,
        # The release folder that holds RELEASE.json; default is the parent of the catalog's config folder.
        [string] $AppRoot,
        # GiB (1024^3).
        [double] $MinFreeGB = 50,
        [scriptblock] $FreeBytesProvider
    )

    if (-not $ComponentsPath) { $ComponentsPath = Join-Path (Split-Path -Parent $CatalogPath) 'components.json' }
    if (-not $AppRoot) { $AppRoot = Split-Path -Parent (Split-Path -Parent ([IO.Path]::GetFullPath($CatalogPath))) }
    $set = Get-FastLlmPreloadSet -CatalogPath $CatalogPath -RecipesPath $RecipesPath -GpuVariantsPath $GpuVariantsPath -TiersPath $TiersPath -ApprovedModelsPath $ApprovedModelsPath

    $release = $null
    try {
        $releasePath = Join-Path $AppRoot 'RELEASE.json'
        if (Test-Path -LiteralPath $releasePath -PathType Leaf) {
            $stored = Get-Content -LiteralPath $releasePath -Raw | ConvertFrom-Json
            if ($stored.PSObject.Properties['version'] -and -not [string]::IsNullOrWhiteSpace([string] $stored.version)) { $release = [string] $stored.version }
        }
    }
    catch { $release = $null }

    if ($FreeBytesProvider) { $free = [int64] (& $FreeBytesProvider $InstallRoot) } else { $free = Get-FastLlmPreloadFreeBytes -Path $InstallRoot }

    $catalogModels = @((Get-FastLlmCatalog -CatalogPath $CatalogPath).models)
    $modelRows = @()
    foreach ($model in @($set.models)) {
        $catalogModel = @($catalogModels | Where-Object { [string] $_.id -ceq [string] $model.modelId })[0]
        $present = $false
        $sizeOk = $false
        $consent = $false
        try {
            $modelsRoot = Join-FastLlmContainedPath -Root $InstallRoot -Child 'models' -Label 'Models root'
            $path = Join-FastLlmContainedPath -Root $modelsRoot -Child ([string] $model.file) -Label 'Model file'
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $present = $true
                $sizeOk = ((Get-Item -LiteralPath $path).Length -eq [int64] $model.sizeBytes)
            }
            $consent = [bool] (Test-FastLlmModelConsentReceipt -Model $catalogModel -InstallRoot $InstallRoot)
        }
        catch { }
        if ($present) {
            if (-not $sizeOk) { $reason = 'size-mismatch' }
            elseif (-not $consent) { $reason = 'consent-missing' }
            else { $reason = 'ok' }
        }
        elseif ($model.approved -eq $false) { $reason = 'awaiting-approval' }
        else { $reason = 'missing' }
        $modelRows += [pscustomobject][ordered]@{
            modelId   = [string] $model.modelId
            revision  = [string] $model.revision
            file      = [string] $model.file
            sizeBytes = [int64] $model.sizeBytes
            present   = [bool] $present
            sizeOk    = [bool] $sizeOk
            consent   = [bool] $consent
            approved  = $model.approved
            tiers     = @($model.tiers)
            reason    = $reason
        }
    }

    $componentRows = @()
    foreach ($component in @(Get-FastLlmPreloadComponents -CatalogPath $CatalogPath -RecipesPath $RecipesPath -ComponentsPath $ComponentsPath)) {
        $root = Get-FastLlmComponentRoot -InstallRoot $InstallRoot -Component $component
        $present = Test-Path -LiteralPath $root -PathType Container
        $verified = $false
        # Same cheap check the component inventory reports as verified: the exact file set and sizes, no hashing.
        if ($present) { $verified = [bool] (Test-FastLlmComponentInstallation -InstallRoot $InstallRoot -Component $component -Depth Presence) }
        $componentRows += [pscustomobject][ordered]@{ id = [string] $component.id; version = [string] $component.version; present = [bool] $present; verified = $verified }
    }

    return [pscustomobject][ordered]@{
        schema       = 'fastllm.preload-status.v1'
        release      = $release
        installRoot  = $InstallRoot
        freeBytes    = $free
        minFreeBytes = [int64] ($MinFreeGB * 1073741824)
        models       = @($modelRows)
        emptyTiers   = @($set.emptyTiers)
        components   = @($componentRows)
    }
}

# Before any work: the -OutputPath directory must exist and be writable, and a file left by an earlier run is deleted so a failed run can never leave a stale report.
function Initialize-FastLlmPreloadOutputPath {
    param([Parameter(Mandatory = $true)][string] $Path)
    $full = [IO.Path]::GetFullPath($Path)
    $directory = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw "-OutputPath directory '$directory' does not exist." }
    if (Test-Path -LiteralPath $full -PathType Container) { throw "-OutputPath '$full' is a directory." }
    $probe = Join-Path $directory ('.' + [Guid]::NewGuid().ToString('N') + '.probe')
    try { [IO.File]::WriteAllText($probe, 'x') }
    catch { throw "-OutputPath directory '$directory' is not writable." }
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $full -PathType Leaf) { Remove-Item -LiteralPath $full -Force -ErrorAction Stop }
}

# Runs the preload and returns the envelope (also written to -OutputPath). An unexpected exception becomes exitCode 1 with the rows collected so far
# and the exception TYPE NAME only (no message, no paths); the envelope exitCode always equals the process exit code the caller uses.
function Invoke-FastLlmPreloadRun {
    param([Parameter(Mandatory = $true)][hashtable] $InstallArguments, [string] $OutputPath)
    $sink = New-Object System.Collections.ArrayList
    try {
        [void] (Install-FastLlmPreloadSet @InstallArguments -RowSink $sink)
        $run = New-FastLlmPreloadRun -Rows @($sink)
    }
    catch {
        $run = New-FastLlmPreloadRun -Rows @($sink) -ErrorType ($_.Exception.GetType().Name)
    }
    if ($OutputPath) {
        try { Write-FastLlmPreloadOutputFile -Path $OutputPath -Json (ConvertTo-FastLlmPreloadJson -InputObject $run) }
        catch { if ($run.exitCode -ne 1) { $run = New-FastLlmPreloadRun -Rows @($sink) -ErrorType ($_.Exception.GetType().Name) } }
    }
    return $run
}
