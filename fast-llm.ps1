#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('install', 'plan', 'start', 'doctor', 'models', 'status', 'stop')]
    [string] $Action = 'start',

    [ValidateSet('fast', 'balanced', 'quality')]
    [string] $Profile = 'balanced',

    [string] $InstallRoot,

    [string] $ModelId,

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

    [switch] $AsJson
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

Import-Module $modulePath -Force
. (Join-Path (Join-Path $projectRoot 'src') 'FastLlm.UiFlow.ps1')
$selectionOptions = @{ ModelId = $ModelId; ContextSize = $ContextSize; AllowExperimentalModel = $AllowExperimentalModel }

function Write-FastLlmPlan {
    param($Plan)

    if ($AsJson) {
        $Plan | ConvertTo-Json -Depth 12
        return
    }

    Write-Host "Hardware:  $((@($Plan.selectedAdapters | ForEach-Object { $_.name })) -join ' + ')"
    Write-Host "Backend:   $($Plan.backend) / llama.cpp $($Plan.engineVersion)"
    Write-Host "Profile:   $($Plan.profile)"
    Write-Host "Model:     $($Plan.model.id) ($($Plan.model.quantization))"
    Write-Host "Serving:   $($Plan.model.servingMode)"
    Write-Host "Context:   $($Plan.model.contextSize) tokens"
    Write-Host "GPU plan:  $(@($Plan.selectedAdapters).Count) device(s); split mode $($Plan.splitMode)"
    Write-Host 'Placement: requested all GPU layers; startup must pass API and reported-layer checks (physical residency remains unqualified)'
    Write-Host "Endpoint:  $($Plan.endpoint)"
    if (@($Plan.warnings).Count -gt 0) {
        Write-Host 'Warnings:'
        foreach ($warning in @($Plan.warnings)) {
            Write-Host "  - $warning"
        }
    }
}

$operationLock = $null
try {
    if ($Action -in @('install', 'start') -and -not $DryRun) {
        if ($env:OS -ne 'Windows_NT') { throw 'Live execution is Windows-only. Use plan -HardwareFile for offline testing.' }
        $operationLock = Enter-FastLlmOperation -InstallRoot $InstallRoot
        Write-FastLlmState -InstallRoot $InstallRoot -State ([ordered]@{ schemaVersion=1; runId=[Guid]::NewGuid().ToString('N'); phase='preparing'; action=$Action })
    }
    switch ($Action) {
        'models' {
            $catalog = Get-FastLlmCatalog -CatalogPath $catalogPath
            if ($AsJson) { ConvertTo-Json -InputObject @($catalog.models) -Depth 12 }
            else { $catalog.models | Select-Object id, quantization, contextSize, requiredFreeVramMiB, servingMode | Format-Table -AutoSize }
        }
        'status' { Get-FastLlmStatus -InstallRoot $InstallRoot | ConvertTo-Json -Depth 12 }
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
            $plan = Get-FastLlmPlan -Hardware $hardware -CatalogPath $catalogPath -Profile $Profile -InstallRoot $InstallRoot @selectionOptions
            if ($ExpectedModelProvenanceSha256) {
                Assert-FastLlmUiExpectedProvenance -Model $plan.model -ExpectedSha256 $ExpectedModelProvenanceSha256
            }
            Write-FastLlmPlan -Plan $plan
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
            $plan = Get-FastLlmPlan -Hardware $hardware -CatalogPath $catalogPath -Profile $Profile -InstallRoot $InstallRoot @selectionOptions
            Write-FastLlmPlan -Plan $plan
        }
        'start' {
            if ($DryRun) {
                $hardware = Get-FastLlmHardware -CatalogPath $catalogPath -InstallRoot $InstallRoot
                $plan = Get-FastLlmPlan -Hardware $hardware -CatalogPath $catalogPath -Profile $Profile -InstallRoot $InstallRoot @selectionOptions
                Write-FastLlmPlan -Plan $plan
                break
            }

            $maximumPlanAttempts = 3
            $serverCompleted = $false
            $recoveryAttempted = $false
            for ($planAttempt = 1; $planAttempt -le $maximumPlanAttempts; $planAttempt++) {
                $hardware = Get-FastLlmHardware -CatalogPath $catalogPath -InstallRoot $InstallRoot
                $plan = Get-FastLlmPlan -Hardware $hardware -CatalogPath $catalogPath -Profile $Profile -InstallRoot $InstallRoot @selectionOptions
                Write-FastLlmPlan -Plan $plan
                $modelReady = (Test-Path -LiteralPath ([string] $plan.modelPath) -PathType Leaf) -and
                    (Test-FastLlmModelConsentReceipt -Model $plan.model -InstallRoot $InstallRoot)
                if (-not $modelReady) {
                    if ($recoveryAttempted) { throw 'The cached recovery artifact or consent changed. Recovery cannot download or accept a replacement.' }
                    Write-Host 'The selected model is missing or lacks an exact consent receipt; provisioning it before startup.'
                    Install-FastLlmModel -Plan $plan -InstallRoot $InstallRoot -AcceptModelLicense:$AcceptModelLicense -Unattended:$Unattended | Out-Null
                    Write-Host 'Provisioning finished; re-detecting hardware and free VRAM before startup.'
                    continue
                }

                try {
                    $exitCode = Start-FastLlmServer -Plan $plan -CatalogPath $catalogPath -InstallRoot $InstallRoot -LoadTimeoutSeconds $LoadTimeoutSeconds
                }
                catch {
                    if ($_.Exception.Data['FastLlmReason'] -eq 'RuntimeCheckFailed' -and -not $recoveryAttempted -and $planAttempt -lt $maximumPlanAttempts) {
                        $recoveryAttempted = $true
                        $recoveryHardware = Get-FastLlmHardware -CatalogPath $catalogPath -InstallRoot $InstallRoot
                        $recovery = Get-FastLlmRecoveryPlan -Hardware $recoveryHardware -CatalogPath $catalogPath -InstallRoot $InstallRoot -Profile $Profile -FailedModelId $plan.model.id -RequestedModelId $ModelId -ContextSize $ContextSize
                        if ($recovery) {
                            $selectionOptions.ModelId = $recovery.model.id
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
                error          = $null
            }
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
                $diagnostic.error = $_.Exception.Message
            }
            $diagnostic | ConvertTo-Json -Depth 12
            if ($diagnostic.error) {
                exit 2
            }
        }
    }
}
catch {
    $failure = $_
    if ($operationLock) {
        try {
            $state = Get-FastLlmStatus -InstallRoot $InstallRoot
            $state.phase = 'failed'
            Write-FastLlmState -InstallRoot $InstallRoot -State $state
        } catch { Write-Warning 'Failure status could not be saved; the operation lock will still be released.' }
    }
    Write-Error $failure.Exception.Message -ErrorAction Continue
    exit 1
}
finally { if ($operationLock) { $operationLock.Dispose() } }
