#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('install', 'plan', 'start', 'doctor', 'models', 'recipes', 'status', 'stop', 'update-check', 'update', 'components', 'settings')]
    [string] $Action = 'start',

    [ValidateSet('fast', 'balanced', 'quality')]
    [string] $Profile = 'balanced',

    [string] $InstallRoot,

    [string] $ModelId,

    # plan/start/install: use this recipe ID from config/recipes.json; refuses if it does not apply. Cannot be combined with -ModelId.
    [string] $Recipe,

    [ValidateRange(0, 1048576)]
    [int] $ContextSize = 0,

    [switch] $AllowExperimentalModel,

    [switch] $EngineOnly,

    [ValidateRange(10, 1800)]
    [int] $LoadTimeoutSeconds = 300,

    [string] $HardwareFile,

    [switch] $AcceptModelLicense,

    [string] $ExpectedModelProvenanceSha256,

    [switch] $Unattended,

    [switch] $DryRun,

    [switch] $AsJson,

    # Vulkan Resizable-BAR mitigation for a live start: off = none, on = set GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM=1 on the
    # Vulkan lane, auto = only when Resizable BAR is confidently detected as off. Absent means auto.
    [ValidateSet('off', 'on', 'auto')]
    [string] $VulkanBarMitigation = 'auto',

    # doctor only: opt in to the live Vulkan memory-layout probe (a bounded child process). Default doctor never probes.
    [switch] $ProbeVulkanMemory,

    # doctor only: print the report as compact single-line JSON with a summarized install-integrity block, for callers that bound the output size.
    [switch] $Compact,

    # Advisory post-Ready prompt-processing measurement (live start only; default off).
    [switch] $ThroughputCanary,

    # start only: skip the post-load self-test
    [switch] $SkipSelfTest,

    # Live start only: W03 Phase A per-start device binding. record = observe which GPU the plan resolves to and note GPU, slot or
    # driver changes since the last recorded start; it never changes the server arguments, the environment or the BAR policy.
    # enforce additionally fails the start when the GPU cannot be bound before launch, or when the server's device list after the model
    # loads does not match the bound GPU. That failure is typed (device-binding-<status> or device-binding-post-load-mismatch) and never
    # triggers model recovery or a model swap. off (default) is byte-identical to a start without the parameter.
    [ValidateSet('off', 'record', 'enforce')]
    [string] $DeviceBinding = 'off',

    # Live start only: NEVER download or install anything (model, engine or runtime). Every acquisition path is blocked and ends the
    # start with a typed failure code (needs-setup-model-missing, needs-setup-consent-missing, needs-setup-model-invalid,
    # needs-setup-engine-missing, needs-setup-prerequisite-missing), never RuntimeCheckFailed, and model recovery or substitution
    # is disabled. Absent means the default start, unchanged.
    [switch] $NoDownload,

    # update only: confirm the install without the interactive prompt (required with -Unattended).
    [switch] $Yes,

    # update-check and update only: the release channel to follow; persisted to settings.json before the check.
    [ValidateSet('stable', 'canary')]
    [string] $Channel,

    # components only: -List (the default) shows every listed component; -Install <id> installs one through its license rule; -Remove <id> removes one.
    [switch] $List,

    [string] $Install,

    [string] $Remove,

    # components -Install and install: accept an accept-type component license on the command line (a show-type license is displayed, not accepted).
    # settings: required to turn -ComponentLicenses accept-automatically on, after the licenses are shown.
    [switch] $AcceptLicense,

    # settings only: ask (default) or accept-automatically. With accept-automatically, the licenses of the engine components listed in components.json
    # (title and host) count as accepted by you, so components can be installed without -AcceptLicense. Needs -AcceptLicense to turn on; ask turns it off.
    [ValidateSet('ask', 'accept-automatically')]
    [string] $ComponentLicenses,

    # start only: the setup a preview showed (a recipe id). The start picks the setup automatically, like a start without -Recipe, and runs it
    # or the Vulkan setup that stands in for it; any other final setup is refused. Not with -Recipe or -ModelId.
    [string] $PlannedRecipe,

    # plan, install and start: use the Vulkan setup that stands in for the automatically chosen HIP setup (reason components-declined). Not with -Recipe.
    [switch] $UseFallback,

    # plan, start and install with -Recipe of a community-experimental or bitworks-experimental recipe: required in addition to the experimental switch being on.
    [switch] $AcceptExperimental,

    # recipes only, with -AsJson: each listed recipe with its engine's requires chain (install state, license consent kind, source hosts, license links). Read-only and offline.
    [switch] $Detail
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$catalogPath = Join-Path (Join-Path $projectRoot 'config') 'catalog.json'
$modulePath = Join-Path (Join-Path $projectRoot 'src') 'FastLlm.psm1'

if (-not $InstallRoot) {
    $localData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if (-not $localData) {
        $localData = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) '.fast-llm'
    }
    $InstallRoot = Join-Path (Join-Path $localData 'Bitworks') 'FastLLM'
}

if ($HardwareFile -and $Action -ne 'plan') {
    throw '-HardwareFile is a development fixture input and is permitted only with the non-executing plan action.'
}
if ($EngineOnly -and $Action -ne 'install') { throw '-EngineOnly is supported only by install.' }
if (($PSBoundParameters.ContainsKey('VulkanBarMitigation') -or $ThroughputCanary) -and ($Action -ne 'start' -or $DryRun)) {
    throw '-VulkanBarMitigation and -ThroughputCanary are supported only by a live start.'
}
# ValidateSet ignores case and keeps the typed value; every later comparison is case-sensitive, so normalise once here.
$DeviceBinding = $DeviceBinding.ToLowerInvariant()
if ($PSBoundParameters.ContainsKey('DeviceBinding') -and ($Action -ne 'start' -or $DryRun)) {
    throw '-DeviceBinding is supported only by a live start.'
}
if ($NoDownload -and ($Action -ne 'start' -or $DryRun)) { throw '-NoDownload is supported only by a live start.' }
if ($Yes -and $Action -ne 'update') { throw '-Yes is supported only by update.' }
if ($PSBoundParameters.ContainsKey('Channel') -and $Action -notin @('update-check', 'update')) { throw '-Channel is supported only by update-check and update.' }
if ($List -and $Action -ne 'components') { throw '-List is supported only by components.' }
if ($PSBoundParameters.ContainsKey('Install') -and $Action -ne 'components') { throw '-Install is supported only by components.' }
if ($PSBoundParameters.ContainsKey('Remove') -and $Action -ne 'components') { throw '-Remove is supported only by components.' }
if ($AcceptLicense -and $Action -notin @('components', 'install', 'settings')) { throw '-AcceptLicense is supported only by components -Install, install and settings.' }
if ($PSBoundParameters.ContainsKey('ComponentLicenses') -and $Action -ne 'settings') { throw '-ComponentLicenses is supported only by settings.' }
if ($Action -eq 'settings' -and $AcceptLicense -and -not ($PSBoundParameters.ContainsKey('ComponentLicenses') -and $ComponentLicenses -ceq 'accept-automatically')) {
    throw '-AcceptLicense with settings only goes with -ComponentLicenses accept-automatically; nothing was changed.'
}
if ($Action -eq 'settings' -and $PSBoundParameters.ContainsKey('ComponentLicenses') -and $ComponentLicenses -ceq 'accept-automatically' -and -not $AcceptLicense) {
    throw 'settings -ComponentLicenses accept-automatically needs -AcceptLicense: it shows the licenses first, and nothing was changed.'
}
if ($PSBoundParameters.ContainsKey('PlannedRecipe') -and $Action -ne 'start') { throw '-PlannedRecipe is supported only by start.' }
if ($PSBoundParameters.ContainsKey('PlannedRecipe') -and [string]::IsNullOrWhiteSpace($PlannedRecipe)) { throw '-PlannedRecipe needs a recipe id.' }
if ($PSBoundParameters.ContainsKey('PlannedRecipe') -and ($Recipe -or $ModelId)) { throw '-PlannedRecipe cannot be combined with -Recipe or -ModelId.' }
if ($UseFallback -and $Action -notin @('plan', 'install', 'start')) { throw '-UseFallback is supported only by plan, install and start.' }
if ($UseFallback -and $Recipe) { throw '-UseFallback cannot be combined with -Recipe: an explicit recipe never falls back.' }
if ($AcceptExperimental -and $Action -notin @('plan', 'start', 'install')) { throw '-AcceptExperimental is supported only by plan, start and install.' }
if ($Detail -and ($Action -ne 'recipes' -or -not $AsJson)) { throw '-Detail is supported only by recipes with -AsJson.' }
if ($Action -eq 'components') {
    if (@(@([bool] $List, $PSBoundParameters.ContainsKey('Install'), $PSBoundParameters.ContainsKey('Remove')) | Where-Object { $_ }).Count -gt 1) {
        throw 'components takes one of -List, -Install <id> or -Remove <id>.'
    }
    if ($AcceptLicense -and -not $PSBoundParameters.ContainsKey('Install')) { throw '-AcceptLicense is supported only with components -Install.' }
    if (($PSBoundParameters.ContainsKey('Install') -and [string]::IsNullOrWhiteSpace($Install)) -or ($PSBoundParameters.ContainsKey('Remove') -and [string]::IsNullOrWhiteSpace($Remove))) {
        throw 'components -Install and -Remove need a component id.'
    }
}
if ($Action -eq 'update' -and $Unattended -and -not $Yes) { throw 'update -Unattended requires -Yes; nothing was changed.' }
if ($ProbeVulkanMemory -and $Action -ne 'doctor') { throw '-ProbeVulkanMemory is supported only by doctor.' }
if ($Compact -and $Action -ne 'doctor') { throw '-Compact is supported only by doctor.' }
if ($Action -eq 'start' -and $AsJson -and -not $DryRun) {
    throw '-AsJson is supported with start only when -DryRun is also specified; a foreground server owns its console output.'
}
if ($Action -eq 'install' -and $DryRun) {
    throw 'install -DryRun is not supported because install is an acquisition action. Use plan for a non-mutating decision preview.'
}
if ($PSBoundParameters.ContainsKey('ExpectedModelProvenanceSha256')) {
    if ($ExpectedModelProvenanceSha256 -cnotmatch '^[0-9a-f]{64}$' -or $Action -ne 'install' -or
        -not $AcceptModelLicense -or -not $ModelId -or $EngineOnly -or $DryRun -or $HardwareFile) {
        throw '-ExpectedModelProvenanceSha256 requires install, an exact -ModelId, and explicit -AcceptModelLicense; it cannot be used for engine-only, fixture, or dry-run actions.'
    }
}

if ($env:OS -eq 'Windows_NT') {
    $offlineFixturePlan = $Action -eq 'plan' -and -not [string]::IsNullOrWhiteSpace($HardwareFile)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $offlineFixturePlan -and $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Any live operation in this alpha, including hardware planning, must run as a standard user. Do not elevate it or register it as a service.'
    }
}

$labAppLifetime = $null
try {
# Managed installations share a lifetime lease before importing application code.
# Ordinary reviewed source checkouts do not create installation state or a lease.
. (Join-Path (Join-Path $projectRoot 'src') 'FastLlm.LabApp.ps1')
$labAppLifetime = Enter-FastLlmLabAppLifetime -SourceRoot $projectRoot
Import-Module $modulePath -Force
. (Join-Path (Join-Path $projectRoot 'src') 'FastLlm.UiFlow.ps1')
. (Join-Path (Join-Path $projectRoot 'src') 'FastLlm.Trust.ps1')
. (Join-Path (Join-Path $projectRoot 'src') 'FastLlm.Update.ps1')
# Components is dot-sourced here and in the control window, never imported through FastLlm.psm1.
. (Join-Path (Join-Path $projectRoot 'src') 'FastLlm.Components.ps1')
$recipesPath = Join-Path (Join-Path $PSScriptRoot 'config') 'recipes.json'
$componentsFilePath = Join-Path (Join-Path $PSScriptRoot 'config') 'components.json'
$selectionOptions = @{
    ModelId = $ModelId; ContextSize = $ContextSize; AllowExperimentalModel = $AllowExperimentalModel
    RecipesPath = $recipesPath; GpuVariantsPath = (Join-Path (Join-Path $PSScriptRoot 'config') 'gpu-variants.json'); RecipeId = $Recipe
}

# A fixture plan (-HardwareFile) never runs an engine: the planner refuses a recipe whose engine would have to be probed (the HIP engine).
if ($HardwareFile) { $selectionOptions.NoEngineExecution = $true }

function Write-FastLlmPlan {
    param($Plan)

    if ($AsJson) {
        $Plan | ConvertTo-Json -Depth 12
        return
    }

    Write-Host "Hardware:  $((@($Plan.selectedAdapters | ForEach-Object { $_.name })) -join ' + ')"
    Write-Host "Backend:   $($Plan.backend) / llama.cpp $($Plan.engineVersion)"
    Write-Host "Profile:   $($Plan.profile)"
    Write-Host "Setup:     $($Plan.recipe.label)"
    if ($Plan.recipe.evidenceUrl) { Write-Host "Results:   $($Plan.recipe.evidenceUrl)" }
    Write-Host "Model:     $($Plan.model.id) ($($Plan.model.quantization))"
    Write-Host "Serving:   $($Plan.model.servingMode)"
    Write-Host "Context:   $($Plan.model.contextSize) tokens"
    Write-Host "GPU plan:  $(@($Plan.selectedAdapters).Count) device(s); split mode $($Plan.splitMode)"
    Write-Host 'Placement: requested all GPU layers; startup must pass API and reported-layer checks (physical residency remains unqualified)'
    Write-Host "Endpoint:  $($Plan.endpoint)"
    if ($Plan.PSObject.Properties['setup'] -and $Plan.setup -and $Plan.setup.PSObject.Properties['pendingComponents'] -and @($Plan.setup.pendingComponents).Count -gt 0) {
        Write-Host 'Needs:     engine components that are not installed:'
        foreach ($needed in @($Plan.setup.pendingComponents)) {
            $neededState = ''
            if ([bool] $needed.unverified) { $neededState = ' (installed, but failed its file check)' }
            Write-Host ("  - {0} {1}, {2:N1} MB, from {3}{4}" -f $needed.name, $needed.version, ([double] $needed.downloadBytes / 1MB), (@($needed.sourceHosts) -join ', '), $neededState)
            foreach ($neededLink in @($needed.licenseLinks)) { Write-Host ("      license: {0} <{1}>" -f $neededLink.title, $neededLink.url) }
        }
    }
    if ($Plan.PSObject.Properties['fallback'] -and $Plan.fallback) {
        $fallbackTarget = 'a Vulkan setup'
        if ($Plan.fallback.toRecipe) { $fallbackTarget = [string] $Plan.fallback.toRecipe }
        if ([bool] $Plan.fallback.applied) {
            Write-Host "Fallback:  using $fallbackTarget instead of $($Plan.fallback.fromRecipe) ($($Plan.fallback.reason))"
            if ([string] $Plan.fallback.reason -ceq 'components-pending') { Write-Host "FastLLM's best setup for your card uses the AMD HIP runtime, which isn't installed. Started the Vulkan setup instead." }
            elseif ([string] $Plan.fallback.reason -ceq 'components-unverified') { Write-Host "FastLLM's best setup for your card uses the AMD HIP runtime, which is installed but failed its file check. Started the Vulkan setup instead." }
            elseif ([string] $Plan.fallback.reason -ceq 'components-declined') { Write-Host "Using the Vulkan setup: the AMD license wasn't accepted." }
            else { Write-Host "FastLLM's best setup for your card could not run here ($($Plan.fallback.reason)). Started the Vulkan setup instead." }
        }
        else { Write-Host "Fallback:  if the components are not installed, $fallbackTarget is used ($($Plan.fallback.reason))" }
    }
    if (@($Plan.warnings).Count -gt 0) {
        Write-Host 'Warnings:'
        foreach ($warning in @($Plan.warnings)) {
            Write-Host "  - $warning"
        }
    }
}

# -UseFallback: the Vulkan setup that stands in for the automatically chosen HIP setup, stamped components-declined. A plan that is not a HIP
# setup (and has no fallback to apply) stays as it is.
function Get-FastLlmDeclinedFallbackPlan {
    param($Plan, $Hardware)
    $fromRecipeId = ''
    if ($Plan.PSObject.Properties['fallback'] -and $Plan.fallback) { $fromRecipeId = [string] $Plan.fallback.fromRecipe }
    elseif ($Plan.PSObject.Properties['backend'] -and ([string] $Plan.backend) -ieq 'hip' -and $Plan.PSObject.Properties['recipe'] -and $Plan.recipe -and $Plan.recipe.PSObject.Properties['id']) { $fromRecipeId = [string] $Plan.recipe.id }
    if (-not $fromRecipeId) { return $Plan }
    return Get-FastLlmPlan -Hardware $Hardware -CatalogPath $catalogPath -Profile $Profile -InstallRoot $InstallRoot @selectionOptions -FallbackFromRecipe $fromRecipeId -FallbackReason 'components-declined'
}

$operationLock = $null
# components -Install/-Remove take the same lock for mutual exclusion only: it is a separate variable so the failure writer below never records a component
# command in status.json.
$componentsLock = $null
try {
    # An experimental recipe is refused before anything is planned, locked or downloaded.
    if ($Recipe -and $Action -in @('plan', 'start', 'install', 'doctor')) {
        $gateComponents = @()
        if (Test-Path -LiteralPath $componentsFilePath -PathType Leaf) { $gateComponents = @(Get-FastLlmComponents -ComponentsPath $componentsFilePath) }
        Assert-FastLlmExperimentalRecipeAllowed -InstallRoot $InstallRoot -RecipeId $Recipe -Recipes @(Read-FastLlmRecipes -Path $recipesPath) -Components $gateComponents -AcceptExperimental:$AcceptExperimental
    }
    if ($Action -in @('install', 'start') -and -not $DryRun) {
        if ($env:OS -ne 'Windows_NT') { throw 'Live execution is Windows-only. Use plan -HardwareFile for offline testing.' }
        $operationLock = Enter-FastLlmOperation -InstallRoot $InstallRoot
        Write-FastLlmState -InstallRoot $InstallRoot -State ([ordered]@{ schemaVersion=1; runId=[Guid]::NewGuid().ToString('N'); phase='preparing'; action=$Action })
    }
    # components -Install and -Remove change what a start or an install relies on, so they take the same operation lock (and write no status).
    if ($Action -eq 'components' -and ($PSBoundParameters.ContainsKey('Install') -or $PSBoundParameters.ContainsKey('Remove'))) {
        $componentsLock = Enter-FastLlmOperation -InstallRoot $InstallRoot
    }
    switch ($Action) {
        'models' {
            $catalog = Get-FastLlmCatalog -CatalogPath $catalogPath
            if ($AsJson) { ConvertTo-Json -InputObject @($catalog.models) -Depth 12 }
            else { $catalog.models | Select-Object id, quantization, contextSize, requiredFreeVramMiB, servingMode | Format-Table -AutoSize }
        }
        'recipes' {
            # Experimental recipes are listed only when the experimental switch is on; each is marked with its label.
            $recipeList = @(Select-FastLlmVisibleRecipes -Recipes @(Read-FastLlmRecipes -Path $recipesPath) -ExperimentalComponents ([string] (Get-FastLlmComponentSettings -InstallRoot $InstallRoot).experimentalComponents))
            if ($AsJson -and $Detail) {
                $detailCatalog = Get-FastLlmCatalog -CatalogPath $catalogPath
                $detailComponents = @(Get-FastLlmComponents -ComponentsPath $componentsFilePath)
                $detailInventory = @(Get-FastLlmComponentInventory -ComponentsPath $componentsFilePath -InstallRoot $InstallRoot)
                ConvertTo-Json -InputObject @(Get-FastLlmRecipeChooserRows -Recipes $recipeList -Components $detailComponents -Inventory $detailInventory -Catalog $detailCatalog -InstallRoot $InstallRoot) -Depth 8
            }
            elseif ($AsJson) { ConvertTo-Json -InputObject $recipeList -Depth 12 }
            elseif ($recipeList.Count -eq 0) { Write-Host 'This release has no published recipes.' }
            else {
                foreach ($listed in $recipeList) {
                    Write-Host ("{0} - {1} - {2} x{3} - {4}, {5} tokens" -f $listed.id, (Get-FastLlmRecipeLabel ([string] $listed.origin)), $listed.gpu.variant, $listed.gpu.count, $listed.components.model, $listed.runtime.contextSize)
                }
            }
        }
        'components' {
            if ($PSBoundParameters.ContainsKey('Install')) {
                # The standing componentLicenses setting counts as the license acceptance when it covers every license of the chain; -AcceptLicense still wins.
                $settingAcceptedAt = ''
                $settingAcceptedLicenses = @()
                if (-not $AcceptLicense) { $settingAcceptedLicenses = @((Get-FastLlmComponentLicenseSettings -InstallRoot $InstallRoot).accepted) }
                if (-not $AcceptLicense) { $settingAcceptedAt = [string] (Get-FastLlmStandingAcceptance -InstallRoot $InstallRoot -ComponentsPath $componentsFilePath -ComponentId $Install) }
                $installResult = Install-FastLlmComponent -ComponentsPath $componentsFilePath -ComponentId $Install -InstallRoot $InstallRoot -AcceptLicense:$AcceptLicense -SettingAcceptedAt $settingAcceptedAt -SettingAcceptedLicenses @($settingAcceptedLicenses) -Unattended:$Unattended -PassThru
                $installedRoot = [string] $installResult.root
                if ($AsJson) { [pscustomobject]@{ id = $Install; installed = $true; path = $installedRoot; installedComponents = @($installResult.installed) } | ConvertTo-Json -Depth 5 }
                elseif (@($installResult.installed).Count -eq 0) { Write-Host "Component '$Install' is already installed and verified: $installedRoot" }
                else { foreach ($newlyInstalled in @($installResult.installed)) { Write-Host "Installed and verified component '$($newlyInstalled.id)': $($newlyInstalled.path)" } }
            }
            elseif ($PSBoundParameters.ContainsKey('Remove')) {
                Remove-FastLlmComponent -ComponentsPath $componentsFilePath -ComponentId $Remove -InstallRoot $InstallRoot -OperationLockHeld:([bool] (Get-Variable -Name componentsLock -ValueOnly -ErrorAction SilentlyContinue)) | Out-Null
                if ($AsJson) { [pscustomobject]@{ id = $Remove; removed = $true } | ConvertTo-Json -Depth 4 }
                else { Write-Host "Removed component '$Remove'." }
            }
            else {
                $componentInventory = @(Get-FastLlmComponentInventory -ComponentsPath $componentsFilePath -InstallRoot $InstallRoot)
                if ($AsJson) { ConvertTo-Json -InputObject @($componentInventory) -Depth 6 }
                elseif ($componentInventory.Count -eq 0) { Write-Host 'This release lists no components.' }
                else { foreach ($componentLine in @(Format-FastLlmComponentList -Inventory $componentInventory)) { Write-Host $componentLine } }
            }
        }
        'settings' {
            # No operation lock: this only reads and writes settings.json.
            if ($PSBoundParameters.ContainsKey('ComponentLicenses')) {
                if ($ComponentLicenses -ceq 'accept-automatically') {
                    $licenseComponents = @(Get-FastLlmComponents -ComponentsPath $componentsFilePath)
                    foreach ($disclosureLine in @(Format-FastLlmLicenseDisclosure -Components $licenseComponents)) { Write-Host $disclosureLine }
                    Set-FastLlmComponentLicenseSettings -InstallRoot $InstallRoot -Mode 'accept-automatically' -Accepted @(Get-FastLlmAcceptableLicenseIdentities -Components $licenseComponents) -AcceptedAt ((Get-Date).ToUniversalTime().ToString('o'))
                }
                else { Set-FastLlmComponentLicenseSettings -InstallRoot $InstallRoot -Mode 'ask' }
            }
            $licenseState = Get-FastLlmComponentLicenseSettings -InstallRoot $InstallRoot
            if ($AsJson) { $licenseState | ConvertTo-Json -Depth 6 }
            elseif ([string] $licenseState.mode -ceq 'accept-automatically') {
                Write-Host "componentLicenses: accept-automatically (turned on $($licenseState.acceptedAt); $(@($licenseState.accepted).Count) license(s) accepted)"
            }
            else { Write-Host 'componentLicenses: ask' }
        }
        'status' {
            Remove-FastLlmDeviceBindingPrivateFields -Status (Get-FastLlmStatus -InstallRoot $InstallRoot) | ConvertTo-Json -Depth 12
            # Cached notice only (no network). Not in -AsJson mode: status already prints one JSON document.
            if (-not $AsJson) {
                try {
                    if (Get-Command -Name Get-FastLlmCachedUpdateNotice -ErrorAction SilentlyContinue) {
                        $cachedNotice = Get-FastLlmCachedUpdateNotice -InstallRoot $InstallRoot -AppRoot $PSScriptRoot
                        if ($cachedNotice) { Write-Host $cachedNotice }
                    }
                } catch { }
            }
        }
        'update-check' {
            if ($PSBoundParameters.ContainsKey('Channel')) { Set-FastLlmUpdateSettings -InstallRoot $InstallRoot -UpdateChannel $Channel }
            $checkResult = Invoke-FastLlmUpdateCheck -InstallRoot $InstallRoot -AppRoot $PSScriptRoot -Force
            if ($AsJson) { $checkResult | ConvertTo-Json -Depth 8; break }
            switch ([string]$checkResult.status) {
                'disabled' { Write-Host 'Update checks are turned off (updateCheck is off in settings.json).' }
                'not-a-release' { Write-Host 'This is not an installed FastLLM release (no RELEASE.json), so there is nothing to check.' }
                'failed' { Write-Host 'The update check could not be completed. Try again later.' }
                'available' { Write-Host ('FastLLM {0} is available: {1}. Run "fast-llm.ps1 update" to install it.' -f $checkResult.latest.version, $checkResult.latest.htmlUrl) }
                default { Write-Host ('FastLLM {0} is up to date.' -f $checkResult.installed) }
            }
        }
        'update' {
            if ($PSBoundParameters.ContainsKey('Channel')) { Set-FastLlmUpdateSettings -InstallRoot $InstallRoot -UpdateChannel $Channel }
            $checkResult = Invoke-FastLlmUpdateCheck -InstallRoot $InstallRoot -AppRoot $PSScriptRoot -Force
            if ([string]$checkResult.status -cne 'available') {
                if ($AsJson) { $checkResult | ConvertTo-Json -Depth 8; break }
                switch ([string]$checkResult.status) {
                    'disabled' { Write-Host 'Update checks are turned off (updateCheck is off in settings.json).' }
                    'not-a-release' { Write-Host 'This is not an installed FastLLM release (no RELEASE.json), so there is nothing to update.' }
                    'failed' { Write-Host 'The update check could not be completed. Try again later.' }
                    default { Write-Host ('FastLLM {0} is up to date.' -f $checkResult.installed) }
                }
                break
            }
            $updateLatest = $checkResult.latest
            if (-not $AsJson) {
                Write-Host ('FastLLM {0} is available: {1}' -f $updateLatest.version, $updateLatest.htmlUrl)
                Write-Host 'The update will:'
                Write-Host '  1. stop a running FastLLM server and confirm it stopped'
                Write-Host '  2. download SHA256SUMS (size-capped) and read the installer hash from it'
                Write-Host '  3. download the installer and check its size and SHA-256'
                Write-Host '  4. check the installer signature against the pinned publisher'
                Write-Host '  5. check the installer version equals the release and is newer than this install'
                Write-Host '  6. run the per-user installer, then check the installed files against FastLLM.cat'
            }
            if (-not $Yes) {
                $answer = Read-Host ('Install FastLLM {0} now? [y/N]' -f $updateLatest.version)
                if ($answer -notmatch '^\s*[yY]') {
                    if ($AsJson) { [pscustomobject]@{ status = 'declined'; step = 'confirm'; reason = 'not-confirmed' } | ConvertTo-Json -Depth 4 }
                    else { Write-Host 'Not installed.' }
                    break
                }
            }
            $updateResult = Invoke-FastLlmVerifiedUpdate -InstallRoot $InstallRoot -AppRoot $PSScriptRoot -Latest $updateLatest -Silent:$Unattended
            if ($AsJson) { $updateResult | ConvertTo-Json -Depth 4 }
            elseif ([string]$updateResult.status -ceq 'installed') { Write-Host ('FastLLM {0} is installed.' -f $updateLatest.version) }
            elseif ([string]$updateResult.status -ceq 'failed' -and [string]$updateResult.step -ceq 'integrity') { Write-Host ("FastLLM {0} was installed, but its files don't match the signed catalog ({1}). Reinstall FastLLM from https://github.com/bitworks-io/amd-inference/releases" -f $updateLatest.version, $updateResult.reason) }
            else { Write-Host ('Update {0} at {1}: {2}' -f $updateResult.status, $updateResult.step, $updateResult.reason) }
            if ([string]$updateResult.status -ceq 'refused') { $updateExit = 3 }
            elseif ([string]$updateResult.status -cne 'installed') { $updateExit = 1 }
            else { $updateExit = 0 }
            if ($updateExit -ne 0) { exit $updateExit }
        }
        'stop' { Request-FastLlmStop -InstallRoot $InstallRoot }
        'install' {
            if ($env:OS -ne 'Windows_NT') {
                throw 'Installation is supported only on Windows. Use the plan action with -HardwareFile for fixture testing.'
            }
            if ($ExpectedModelProvenanceSha256) {
                $reviewCatalog = Get-FastLlmCatalog -CatalogPath $catalogPath
                $reviewModel = @($reviewCatalog.models | Where-Object { [string]$_.id -ceq $ModelId })
                if ($reviewModel.Count -ne 1) { throw 'The exact model selected during license review is unavailable.' }
                Assert-FastLlmUiExpectedProvenance -Model $reviewModel[0] -ExpectedSha256 $ExpectedModelProvenanceSha256
            }
            Install-FastLlmEngines -CatalogPath $catalogPath -InstallRoot $InstallRoot
            if ($EngineOnly) {
                Write-Host 'Verified engine installed. No model license was accepted and no weights were downloaded.'
                Write-FastLlmState -InstallRoot $InstallRoot -State ([ordered]@{schemaVersion=1;phase='engine-installed'})
                break
            }
            $hardware = Get-FastLlmHardware -HardwareFile $HardwareFile -CatalogPath $catalogPath -InstallRoot $InstallRoot
            $installNote = @()
            try {
                $plan = Get-FastLlmPlan -Hardware $hardware -CatalogPath $catalogPath -Profile $Profile -InstallRoot $InstallRoot @selectionOptions -ResolveFallback:$UseFallback
            }
            catch {
                # An explicit recipe on an engine component that is not installed: the component is installed when -AcceptLicense or the standing
                # setting covers its licenses (a plain interactive install still shows a show-type license and asks); unattended with neither,
                # and a dry run, refuse. Nothing falls back.
                $missingComponentId = [string] $_.Exception.Data['FastLlmComponentId']
                if ([string] $_.Exception.Data['FastLlmFailureCode'] -cne 'needs-setup-component-missing' -or -not $missingComponentId -or $DryRun) { throw }
                $missingAcceptedAt = ''
                $missingAcceptedLicenses = @()
                if (-not $AcceptLicense) {
                    $missingAcceptedLicenses = @((Get-FastLlmComponentLicenseSettings -InstallRoot $InstallRoot).accepted)
                    $missingAcceptedAt = [string] (Get-FastLlmStandingAcceptance -InstallRoot $InstallRoot -ComponentsPath $componentsFilePath -ComponentId $missingComponentId)
                }
                if ($Unattended -and -not $AcceptLicense -and -not $missingAcceptedAt) { throw }
                Install-FastLlmComponent -ComponentsPath $componentsFilePath -ComponentId $missingComponentId -InstallRoot $InstallRoot -AcceptLicense:$AcceptLicense -SettingAcceptedAt $missingAcceptedAt -SettingAcceptedLicenses @($missingAcceptedLicenses) -Unattended:$Unattended | Out-Null
                $plan = Get-FastLlmPlan -Hardware $hardware -CatalogPath $catalogPath -Profile $Profile -InstallRoot $InstallRoot @selectionOptions
            }
            if ($UseFallback) { $plan = Get-FastLlmDeclinedFallbackPlan -Plan $plan -Hardware $hardware }
            elseif ($plan.PSObject.Properties['setup'] -and $plan.setup -and $plan.setup.PSObject.Properties['pendingComponents'] -and @($plan.setup.pendingComponents).Count -gt 0) {
                # The automatically chosen setup needs engine components that are not installed. They are installed here only with the accepted
                # licenses (-AcceptLicense, or the standing setting when it covers every license of the chain); otherwise the fallback setup is
                # installed and this is said out loud. A component that is installed but failed its file check is never reinstalled in place.
                $pendingEngineId = [string] $plan.engineComponentId
                $unverifiedPending = @(@($plan.setup.pendingComponents) | Where-Object { [bool] $_.unverified })
                $pendingAcceptedAt = ''
                $pendingAcceptedLicenses = @()
                if ($unverifiedPending.Count -eq 0 -and -not $AcceptLicense) {
                    $pendingAcceptedLicenses = @((Get-FastLlmComponentLicenseSettings -InstallRoot $InstallRoot).accepted)
                    $pendingAcceptedAt = [string] (Get-FastLlmStandingAcceptance -InstallRoot $InstallRoot -ComponentsPath $componentsFilePath -ComponentId $pendingEngineId)
                }
                if ($unverifiedPending.Count -eq 0 -and ($AcceptLicense -or $pendingAcceptedAt)) {
                    Install-FastLlmComponent -ComponentsPath $componentsFilePath -ComponentId $pendingEngineId -InstallRoot $InstallRoot -AcceptLicense:$AcceptLicense -SettingAcceptedAt $pendingAcceptedAt -SettingAcceptedLicenses @($pendingAcceptedLicenses) -Unattended:$Unattended | Out-Null
                    $plan = Get-FastLlmPlan -Hardware $hardware -CatalogPath $catalogPath -Profile $Profile -InstallRoot $InstallRoot @selectionOptions
                }
                else {
                    foreach ($unverifiedItem in $unverifiedPending) {
                        $installNote += "The component '$($unverifiedItem.id)' is installed but failed its file check, and FastLLM does not reinstall it in place. To reinstall it: run '.\fast-llm.ps1 components -Remove $($unverifiedItem.id)', then run install again."
                    }
                    if ($unverifiedPending.Count -eq 0) {
                        $installNote += 'To install the HIP setup, accept these licenses by running install again with -AcceptLicense, or turn on the setting: .\fast-llm.ps1 settings -ComponentLicenses accept-automatically -AcceptLicense'
                        foreach ($noteItem in @($plan.setup.pendingComponents)) {
                            foreach ($noteLink in @($noteItem.licenseLinks)) { $installNote += ("  license for {0}: {1} <{2}>" -f $noteItem.name, $noteLink.title, $noteLink.url) }
                        }
                    }
                    $plan = Get-FastLlmPlan -Hardware $hardware -CatalogPath $catalogPath -Profile $Profile -InstallRoot $InstallRoot @selectionOptions -FallbackFromRecipe ([string] $plan.fallback.fromRecipe) -FallbackReason ([string] $plan.fallback.reason)
                }
            }
            if ($ExpectedModelProvenanceSha256) {
                Assert-FastLlmUiExpectedProvenance -Model $plan.model -ExpectedSha256 $ExpectedModelProvenanceSha256
            }
            Write-FastLlmPlan -Plan $plan
            if (-not $AsJson) { foreach ($noteLine in $installNote) { Write-Host $noteLine } }
            if ($DryRun) {
                break
            }
            $modelPath = Install-FastLlmModel -Plan $plan -InstallRoot $InstallRoot -AcceptModelLicense:$AcceptModelLicense -Unattended:$Unattended
            if (-not $AsJson) {
                Write-Host "Installed verified model: $modelPath"
                Write-Host "Run: .\fast-llm.ps1 start -Profile $Profile"
            }
            Write-FastLlmState -InstallRoot $InstallRoot -State ([ordered]@{ schemaVersion=1; phase='installed'; modelId=$plan.model.id; performanceQualified=$false })
        }
        'plan' {
            $hardware = Get-FastLlmHardware -HardwareFile $HardwareFile -CatalogPath $catalogPath -InstallRoot $InstallRoot
            $plan = Get-FastLlmPlan -Hardware $hardware -CatalogPath $catalogPath -Profile $Profile -InstallRoot $InstallRoot @selectionOptions -ResolveFallback:$UseFallback
            if ($UseFallback) { $plan = Get-FastLlmDeclinedFallbackPlan -Plan $plan -Hardware $hardware }
            Write-FastLlmPlan -Plan $plan
        }
        'start' {
            if ($DryRun) {
                $hardware = Get-FastLlmHardware -CatalogPath $catalogPath -InstallRoot $InstallRoot
                $plan = Get-FastLlmPlan -Hardware $hardware -CatalogPath $catalogPath -Profile $Profile -InstallRoot $InstallRoot @selectionOptions -ResolveFallback
                if ($UseFallback) { $plan = Get-FastLlmDeclinedFallbackPlan -Plan $plan -Hardware $hardware }
                if ($PlannedRecipe -and -not (Test-FastLlmPlanMatchesPlannedRecipe -Plan $plan -PlannedRecipe $PlannedRecipe)) {
                    throw (New-FastLlmTypedFailure -Code 'planned-recipe-not-applicable' -Message "The setup '$PlannedRecipe' does not apply to this PC any more. Nothing was started; choose a setup again.")
                }
                Write-FastLlmPlan -Plan $plan
                break
            }

            if ($NoDownload) {
                # Blocked acquisition: a missing runtime prerequisite or engine is a typed needs-setup failure, never an install.
                $noDownloadPrerequisites = Get-FastLlmWindowsPrerequisiteStatus
                if ($noDownloadPrerequisites.applicable -and -not $noDownloadPrerequisites.ready) {
                    throw (New-FastLlmTypedFailure -Code 'needs-setup-prerequisite-missing' -Message 'A Windows prerequisite is missing and -NoDownload forbids installing anything.')
                }
                $noDownloadCatalog = Get-FastLlmCatalog -CatalogPath $catalogPath
                $noDownloadEngineReady = $false
                foreach ($noDownloadBackend in @('vulkan', 'rocm')) {
                    $noDownloadAsset = $noDownloadCatalog.engine.assets.PSObject.Properties[$noDownloadBackend]
                    if ($noDownloadAsset -and [bool] $noDownloadAsset.Value.enabled -and
                        (Test-FastLlmEngineInstallation -InstallRoot $InstallRoot -EngineVersion ([string] $noDownloadCatalog.engine.version) -BackendKey $noDownloadBackend -Asset $noDownloadAsset.Value)) {
                        $noDownloadEngineReady = $true
                    }
                }
                if (-not $noDownloadEngineReady) {
                    throw (New-FastLlmTypedFailure -Code 'needs-setup-engine-missing' -Message 'The verified engine is not installed and -NoDownload forbids installing it.')
                }
            }
            $maximumPlanAttempts = 3
            $serverCompleted = $false
            $recoveryAttempted = $false
            for ($planAttempt = 1; $planAttempt -le $maximumPlanAttempts; $planAttempt++) {
                $hardware = Get-FastLlmHardware -CatalogPath $catalogPath -InstallRoot $InstallRoot
                # A start never installs anything: an automatically chosen setup whose engine components are missing, unverified or unable to run
                # resolves to the Vulkan setup that stands in for it (-ResolveFallback), and the plan says so.
                $plan = Get-FastLlmPlan -Hardware $hardware -CatalogPath $catalogPath -Profile $Profile -InstallRoot $InstallRoot @selectionOptions -ResolveFallback
                if ($UseFallback) { $plan = Get-FastLlmDeclinedFallbackPlan -Plan $plan -Hardware $hardware }
                # A window start names the setup its preview showed: the final plan is that setup or the one that stands in for it, or nothing starts.
                # After a model recovery the plan is no longer the previewed setup by design (the documented recovery to a smaller cached model, as
                # it works today for the Vulkan setup), so the check applies to the first plans only.
                if ($PlannedRecipe -and -not $recoveryAttempted -and -not (Test-FastLlmPlanMatchesPlannedRecipe -Plan $plan -PlannedRecipe $PlannedRecipe)) {
                    throw (New-FastLlmTypedFailure -Code 'planned-recipe-not-applicable' -Message "The setup '$PlannedRecipe' does not apply to this PC any more. Nothing was started; choose a setup again.")
                }
                Write-FastLlmPlan -Plan $plan
                if ($VulkanBarMitigation -in @('on', 'off') -and $plan.PSObject.Properties['backend'] -and [string] $plan.backend -ieq 'hip') {
                    Write-Host 'Resizable BAR mitigation is a Vulkan setting and does not apply to the HIP engine.'
                }
                $modelReady = (Test-Path -LiteralPath ([string] $plan.modelPath) -PathType Leaf) -and
                    (Test-FastLlmModelConsentReceipt -Model $plan.model -InstallRoot $InstallRoot)
                if (-not $modelReady) {
                    if ($NoDownload) {
                        if (-not (Test-Path -LiteralPath ([string] $plan.modelPath) -PathType Leaf)) {
                            throw (New-FastLlmTypedFailure -Code 'needs-setup-model-missing' -Message 'The selected model is not installed and -NoDownload forbids downloading it.')
                        }
                        throw (New-FastLlmTypedFailure -Code 'needs-setup-consent-missing' -Message 'The selected model has no exact consent receipt and -NoDownload forbids provisioning it.')
                    }
                    if ($recoveryAttempted) { throw 'The cached recovery artifact or consent changed. Recovery cannot download or accept a replacement.' }
                    Write-Host 'The selected model is missing or lacks an exact consent receipt; provisioning it before startup.'
                    Install-FastLlmModel -Plan $plan -InstallRoot $InstallRoot -AcceptModelLicense:$AcceptModelLicense -Unattended:$Unattended | Out-Null
                    Write-Host 'Provisioning finished; re-detecting hardware and free VRAM before startup.'
                    continue
                }

                # Cached notice only (no network, state\update-check.json): once, after the plan and before the foreground server launches.
                # It is cosmetic and must never affect the start: strict-mode-safe once guard, only when loaded, any error ignored.
                if (-not (Get-Variable -Name FastLlmUpdateNoticeShown -Scope Script -ErrorAction SilentlyContinue)) {
                    $script:FastLlmUpdateNoticeShown = $true
                    try {
                        if (Get-Command -Name Get-FastLlmCachedUpdateNotice -ErrorAction SilentlyContinue) {
                            $cachedNotice = Get-FastLlmCachedUpdateNotice -InstallRoot $InstallRoot -AppRoot $PSScriptRoot
                            if ($cachedNotice) { Write-Host $cachedNotice }
                        }
                    } catch { }
                }
                # The BAR policy is always passed so the auto default reaches the start; the other options only when asked.
                $startPolicyOptions = @{}
                $startPolicyOptions.VulkanBarMitigation = $VulkanBarMitigation
                if ($ThroughputCanary) { $startPolicyOptions.ThroughputCanary = $true }
                if (-not $SkipSelfTest) { $startPolicyOptions.SelfTest = $true }
                if ($DeviceBinding -ne 'off') { $startPolicyOptions.DeviceBinding = $DeviceBinding }
                try {
                    $exitCode = Start-FastLlmServer -Plan $plan -CatalogPath $catalogPath -InstallRoot $InstallRoot -LoadTimeoutSeconds $LoadTimeoutSeconds @startPolicyOptions
                }
                catch {
                    # W03 enforce: a device-binding failure is never retried, re-planned or recovered with another model.
                    if ($NoDownload -and $_.Exception.Data['FastLlmReason'] -eq 'ModelNeedsProvisioning') {
                        $invalidModelFailure = New-FastLlmTypedFailure -Code 'needs-setup-model-invalid' -Message 'The selected model failed verification and -NoDownload forbids repairing or re-downloading it.'
                        if ($_.Exception.Data['FastLlmFallbackAttempted']) {
                            $invalidModelFailure.Data['FastLlmFallbackAttempted'] = $true
                            $invalidModelFailure.Data['FastLlmFallbackFirstCode'] = $_.Exception.Data['FastLlmFallbackFirstCode']
                        }
                        throw $invalidModelFailure
                    }
                    # A failure of the fallback attempt (the stand-in's own start) ends the start: no re-plan onto the HIP setup, no repair, no recovery.
                    if ($_.Exception.Data['FastLlmFallbackAttempted']) { throw }
                    if ($_.Exception.Data['FastLlmReason'] -ceq 'DeviceBindingFailed' -or [string]$_.Exception.Data['FastLlmFailureCode'] -clike 'device-binding-*') { throw }
                    # A plan on an engine component (HIP) never recovers onto another recipe or engine: the failure is rethrown with its own code.
                    # Keyed on the PLAN, so a built-in Vulkan recipe start (including a UI-forwarded -Recipe) keeps its recovery.
                    $planOnEngineComponent = [bool](($plan.PSObject.Properties['engineComponentId'] -and $plan.engineComponentId) -or ($plan.PSObject.Properties['backend'] -and [string]$plan.backend -ieq 'hip'))
                    if ($_.Exception.Data['FastLlmReason'] -eq 'RuntimeCheckFailed' -and -not $planOnEngineComponent -and -not $NoDownload -and -not $recoveryAttempted -and $planAttempt -lt $maximumPlanAttempts) {
                        $recoveryAttempted = $true
                        $recoveryHardware = Get-FastLlmHardware -CatalogPath $catalogPath -InstallRoot $InstallRoot
                        $recovery = Get-FastLlmRecoveryPlan -Hardware $recoveryHardware -CatalogPath $catalogPath -InstallRoot $InstallRoot -Profile $Profile -FailedModelId $plan.model.id -RequestedModelId $ModelId -ContextSize $ContextSize
                        if ($recovery) {
                            $selectionOptions.ModelId = $recovery.model.id
                            # -Recipe and -ModelId cannot be combined; recovery is an explicit cached model.
                            $selectionOptions.RecipeId = $null
                            # The cached model is a recovery, not the user's choice: the plan is labelled estimated.
                            $selectionOptions.Recovered = $true
                            Write-Host "The automatic choice failed runtime checks. Trying previously smoke-tested, cached model '$($recovery.model.id)' once; it will be rehashed and checked again."
                            continue
                        }
                    }
                    if ($_.Exception.Data['FastLlmReason'] -eq 'PlanChanged' -and $planAttempt -lt $maximumPlanAttempts) {
                        Write-Host "$($_.Exception.Message) Re-planning before launch."
                        continue
                    }
                    if ($_.Exception.Data['FastLlmReason'] -eq 'ModelNeedsProvisioning' -and -not $recoveryAttempted -and $planAttempt -lt $maximumPlanAttempts) {
                        Write-Host "$($_.Exception.Message) Repairing the exact consented artifact before re-planning."
                        Install-FastLlmModel -Plan $plan -InstallRoot $InstallRoot -AcceptModelLicense:$AcceptModelLicense -Unattended:$Unattended | Out-Null
                        continue
                    }
                    throw
                }
                if ($exitCode -ne 0) {
                    throw "llama-server exited with code $exitCode."
                }
                $serverCompleted = $true
                break
            }
            if (-not $serverCompleted) {
                throw "Hardware/model selection did not stabilize within $maximumPlanAttempts attempts. Close GPU-heavy applications and run start again."
            }

        }
        'doctor' {
            $catalog = Get-FastLlmCatalog -CatalogPath $catalogPath
            $windowsPrerequisites = Get-FastLlmWindowsPrerequisiteStatus
            $vulkanVerified = Test-FastLlmEngineInstallation -InstallRoot $InstallRoot -EngineVersion ([string] $catalog.engine.version) -BackendKey 'vulkan' -Asset $catalog.engine.assets.vulkan
            # Install integrity: the installed files against the signed FastLLM.cat. The signature skip is a hidden test seam that
            # applies ONLY to an unsigned catalog (reason not-valid, Authenticode status exactly NotSigned) AND FASTLLM_TEST_SKIP_CATALOG_SIGNATURE=1; any other signature
            # failure is never skipped. Nothing in the product sets the variable.
            $installIntegrityResult = Test-FastLlmInstallIntegrity -AppRoot $PSScriptRoot
            if ($installIntegrityResult.status -ceq 'failed' -and $installIntegrityResult.reason -ceq 'catalog-signature' -and
                $installIntegrityResult.catalogSignature -and $installIntegrityResult.catalogSignature.reason -ceq 'not-valid' -and
                $installIntegrityResult.catalogSignature.detail -ceq 'NotSigned' -and
                $env:FASTLLM_TEST_SKIP_CATALOG_SIGNATURE -ceq '1') {
                $installIntegrityResult = Test-FastLlmInstallIntegrity -AppRoot $PSScriptRoot -SkipSignatureForTest
            }
            $installIntegritySummary = switch ([string]$installIntegrityResult.status) {
                'ok' { 'Install integrity: ok' }
                'not-installed' { 'Install integrity: not an installed release (no FastLLM.cat)' }
                default {
                    $integrityDetail = @(@($installIntegrityResult.mismatches) | Select-Object -First 5)
                    if (-not $integrityDetail.Count -and $installIntegrityResult.catalogSignature) { $integrityDetail = @([string]$installIntegrityResult.catalogSignature.reason) }
                    'Install integrity: FAILED (' + [string]$installIntegrityResult.reason + '): ' + ($integrityDetail -join ', ')
                }
            }
            $diagnostic = [ordered] @{
                timestamp      = (Get-Date).ToUniversalTime().ToString('o')
                windows        = $env:OS -eq 'Windows_NT'
                installRoot    = $InstallRoot
                catalogVersion = [string] $catalog.catalogVersion
                engineVersion  = [string] $catalog.engine.version
                rocmEnabled    = [bool] $catalog.engine.assets.rocm.enabled
                rocmDisabledReason = [string] $catalog.engine.assets.rocm.disabledReason
                rocmVerified   = Test-FastLlmEngineInstallation -InstallRoot $InstallRoot -EngineVersion ([string] $catalog.engine.version) -BackendKey 'rocm' -Asset $catalog.engine.assets.rocm
                rocmEngine     = Get-FastLlmEngineExecutable -InstallRoot $InstallRoot -EngineVersion ([string] $catalog.engine.version) -BackendKey 'rocm' -EntryPoint ([string] $catalog.engine.assets.rocm.entryPoint)
                vulkanEnabled  = [bool] $catalog.engine.assets.vulkan.enabled
                vulkanVerified = $vulkanVerified
                windowsPrerequisites = $windowsPrerequisites
                prerequisiteInventory = $null
                prerequisiteInventoryError = $null
                windowsInventory = $null
                inventoryError = $null
                driverGuidance = @()
                driverGuidanceError = $null
                vulkanRuntimeReady = [bool] ($vulkanVerified -and $windowsPrerequisites.applicable -and $windowsPrerequisites.ready)
                vulkanEngine   = Get-FastLlmEngineExecutable -InstallRoot $InstallRoot -EngineVersion ([string] $catalog.engine.version) -BackendKey 'vulkan' -EntryPoint ([string] $catalog.engine.assets.vulkan.entryPoint)
                hardware       = $null
                plan           = $null
                vulkanMemory   = $null
                vulkanMemoryError = $null
                # doctor prints one JSON document, so the human line travels inside it as summary.
                installIntegrity = [pscustomobject] @{
                    appRoot          = [string] $PSScriptRoot
                    status           = [string] $installIntegrityResult.status
                    reason           = $installIntegrityResult.reason
                    catalogSignature = $installIntegrityResult.catalogSignature
                    mismatches       = @($installIntegrityResult.mismatches)
                    summary          = $installIntegritySummary
                }
                error          = $null
            }
            if ($installIntegrityResult.status -ceq 'failed') { $diagnostic.error = 'Install integrity failed: ' + $installIntegritySummary.Substring('Install integrity: FAILED '.Length) }
            try { $diagnostic.prerequisiteInventory = Get-FastLlmPrerequisiteInventory }
            catch { $diagnostic.prerequisiteInventoryError = 'prerequisite-inventory-unavailable' }
            try { $diagnostic.windowsInventory = Get-FastLlmWindowsInventory } catch { $diagnostic.inventoryError = $_.Exception.Message }
            # Advisory only: keep exact PnP records separate from the serving-engine adapters.
            try { $diagnostic.driverGuidance = @(Get-FastLlmInventoryDriverGuidance -WindowsInventory $diagnostic.windowsInventory) }
            catch { $diagnostic.driverGuidanceError = 'driver-guidance-unavailable' }
            try {
                $diagnostic.hardware = Get-FastLlmHardware -HardwareFile $HardwareFile -CatalogPath $catalogPath -InstallRoot $InstallRoot
                $diagnostic.plan = Get-FastLlmPlan -Hardware $diagnostic.hardware -CatalogPath $catalogPath -Profile $Profile -InstallRoot $InstallRoot @selectionOptions
            }
            catch {
                # Appended, never replacing an earlier install-integrity failure.
                if ($diagnostic.error) { $diagnostic.error = [string]$diagnostic.error + '; ' + $_.Exception.Message }
                else { $diagnostic.error = $_.Exception.Message }
            }
            # Configured mitigation policy; the live Resizable-BAR probe runs only with -ProbeVulkanMemory and a Vulkan plan.
            # Advisory: never changes the exit status, never creates the install root.
            try {
                $diagnosticAdapters = @()
                $diagnosticAdapterObjects = @()
                $diagnosticBackend = ''
                if ($diagnostic.plan) {
                    $diagnosticAdapterObjects = @($diagnostic.plan.selectedAdapters)
                    $diagnosticAdapters = @(@($diagnostic.plan.selectedAdapters) | ForEach-Object { [string]$_.name })
                    $diagnosticBackend = [string]$diagnostic.plan.backend
                }
                $diagnostic.vulkanMemory = Get-FastLlmVulkanMemoryDiagnostic -AdapterNames $diagnosticAdapters -Backend $diagnosticBackend -Probe:$ProbeVulkanMemory -Adapters $diagnosticAdapterObjects
            }
            catch { $diagnostic.vulkanMemoryError = 'vulkan-memory-diagnostic-unavailable' }
            if ($Compact) { ConvertTo-FastLlmCompactDoctorReport -Diagnostic $diagnostic | ConvertTo-Json -Depth 12 -Compress }
            else { $diagnostic | ConvertTo-Json -Depth 12 }
            if ($diagnostic.error) {
                exit 2
            }
        }
    }
}
catch {
    $failure = $_
    # A device-binding failure never trusts its code to be clean already: the same pattern as ConvertTo-FastLlmDeviceBindingCode in
    # src/FastLlm.Runtime.ps1 (private to the module, so inlined here; a test asserts the two patterns are the same string).
    # Non-conforming or empty becomes device-binding-unavailable. The result is used for status.json and for the console.
    $isBindingFailure = $failure.Exception.Data['FastLlmReason'] -ceq 'DeviceBindingFailed'
    $bindingCode = $null
    if ($isBindingFailure) {
        $bindingCode = [string] $failure.Exception.Data['FastLlmFailureCode']
        if ($bindingCode -cnotmatch '^device-binding-[a-z-]{1,40}$') { $bindingCode = 'device-binding-unavailable' }
    }
    if ($operationLock) {
        try {
            $state = Get-FastLlmStatus -InstallRoot $InstallRoot
            $state.phase = 'failed'
            # A typed failure (for example a blocked -NoDownload acquisition) is recorded so a supervising caller can classify it.
            if ($isBindingFailure) {
                $state | Add-Member -NotePropertyName failureCode -NotePropertyValue $bindingCode -Force
            } elseif ($failure.Exception.Data['FastLlmFailureCode']) {
                $state | Add-Member -NotePropertyName failureCode -NotePropertyValue ([string] $failure.Exception.Data['FastLlmFailureCode']) -Force
            }
            Write-FastLlmState -InstallRoot $InstallRoot -State $state
        } catch { Write-Warning 'Failure status could not be saved; the operation lock will still be released.' }
    }
    $failureMessage = [string] $failure.Exception.Message
    # A device-binding failure prints its message only when it already carries the conforming '<code>: ' prefix; otherwise a fixed text (no part of the message).
    if ($isBindingFailure -and -not $failureMessage.StartsWith($bindingCode + ': ', [StringComparison]::Ordinal)) {
        $failureMessage = $bindingCode + ': device binding failed (details withheld; see status)'
    }
    Write-Error $failureMessage -ErrorAction Continue
    exit 1
}
finally { if ($operationLock) { $operationLock.Dispose() }; if ($componentsLock) { $componentsLock.Dispose() } }
}
finally { if ($labAppLifetime) { $labAppLifetime.Dispose() } }
