#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $testsRoot
$catalogPath = Join-Path (Join-Path $projectRoot 'config') 'catalog.json'
$modulePath = Join-Path (Join-Path $projectRoot 'src') 'FastLlm.psm1'
$fixtureRoot = Join-Path $testsRoot 'fixtures'
Import-Module $modulePath -Force

$script:passed = 0
$script:failed = 0

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)] $Expected,
        [Parameter(Mandatory = $true)] $Actual,
        [Parameter(Mandatory = $true)] [string] $Message
    )
    if ([string] $Expected -ne [string] $Actual) {
        $script:failed++
        Write-Host "FAIL: $Message (expected '$Expected', got '$Actual')" -ForegroundColor Red
        return
    }
    $script:passed++
    Write-Host "PASS: $Message" -ForegroundColor Green
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)] [bool] $Condition,
        [Parameter(Mandatory = $true)] [string] $Message
    )
    if (-not $Condition) {
        $script:failed++
        Write-Host "FAIL: $Message" -ForegroundColor Red
        return
    }
    $script:passed++
    Write-Host "PASS: $Message" -ForegroundColor Green
}

function Assert-ThrowsMatching {
    param(
        [Parameter(Mandatory = $true)] [scriptblock] $Action,
        [Parameter(Mandatory = $true)] [string] $Pattern,
        [Parameter(Mandatory = $true)] [string] $Message
    )
    $matched = $false
    try {
        & $Action | Out-Null
    }
    catch {
        $matched = [bool] ($_.Exception.Message -match $Pattern)
    }
    Assert-True -Condition $matched -Message $Message
}

function Get-ServerArgumentValue {
    param(
        [Parameter(Mandatory = $true)] [object[]] $Arguments,
        [Parameter(Mandatory = $true)] [string] $Name
    )
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        if ([string] $Arguments[$index] -eq $Name) {
            if (($index + 1) -ge $Arguments.Count) {
                throw "Server argument '$Name' has no value."
            }
            return [string] $Arguments[$index + 1]
        }
    }
    throw "Server argument '$Name' was not found."
}

function Get-FixturePlan {
    param(
        [Parameter(Mandatory = $true)] [string] $Fixture,
        [ValidateSet('fast', 'balanced', 'quality')] [string] $Profile = 'balanced'
    )
    $hardware = Read-FastLlmJson -Path (Join-Path $fixtureRoot $Fixture)
    return Get-FastLlmPlan -Hardware $hardware -CatalogPath $catalogPath -Profile $Profile -InstallRoot (Join-Path $projectRoot '.test-install')
}

$cases = @(
    @{ Fixture = 'amd-4gb.json'; Expected = 'qwen3.5-4b-iq4-xs' },
    @{ Fixture = 'amd-8gb.json'; Expected = 'qwen3.5-9b-q4-k-m' },
    @{ Fixture = 'amd-12gb.json'; Expected = 'qwen3.5-9b-q6-k' },
    @{ Fixture = 'amd-16gb.json'; Expected = 'qwen3.5-9b-q8-0' },
    @{ Fixture = 'rx-7900-xt-20gb.json'; Expected = 'qwen3.8-27b-ud-iq4-xs' },
    @{ Fixture = 'rx-7900-xtx-24gb.json'; Expected = 'qwen3.8-27b-ud-q4-k-m' },
    @{ Fixture = 'r9700-32gb.json'; Expected = 'qwen3.8-27b-ud-q6-k-m' }
)

foreach ($case in $cases) {
    $plan = Get-FixturePlan -Fixture $case.Fixture
    Assert-Equal -Expected $case.Expected -Actual $plan.model.id -Message "$($case.Fixture) selects its balanced model"
    Assert-Equal -Expected 'none' -Actual $plan.splitMode -Message "$($case.Fixture) remains single GPU"
    Assert-True -Condition ([bool] $plan.requestedAllGpuLayers) -Message "$($case.Fixture) requests full GPU offload"
    Assert-True -Condition (-not [bool] $plan.placementVerified) -Message "$($case.Fixture) does not claim placement before a runtime canary"
}

$dual20 = Get-FixturePlan -Fixture 'dual-rx-7900-xt-20gb.json'
Assert-Equal -Expected 'qwen3.8-27b-ud-q6-k-m' -Actual $dual20.model.id -Message 'dual 20GB balanced profile uses aggregate capacity'
Assert-Equal -Expected 'layer' -Actual $dual20.splitMode -Message 'dual 20GB defaults to layer split'
Assert-Equal -Expected 2 -Actual @($dual20.selectedAdapters).Count -Message 'dual 20GB selects both identical adapters'
Assert-True -Condition ([bool] ($dual20.tensorSplit -match '^\d+,\d+$')) -Message 'dual 20GB emits an explicit memory-weighted tensor split'

$dual20Quality = Get-FixturePlan -Fixture 'dual-rx-7900-xt-20gb.json' -Profile 'quality'
Assert-Equal -Expected 'qwen3.8-27b-q8-0' -Actual $dual20Quality.model.id -Message 'dual XT quality profile selects Qwen3.8 Q8'
Assert-Equal -Expected 2 -Actual @($dual20Quality.selectedAdapters).Count -Message 'dual XT quality profile needs both cards'

$dual24Balanced = Get-FixturePlan -Fixture 'dual-rx-7900-xtx-24gb.json'
Assert-Equal -Expected 'qwen3.8-27b-ud-q6-k-m' -Actual $dual24Balanced.model.id -Message 'dual XTX balanced profile selects Qwen3.8 Q6'
Assert-Equal -Expected 2 -Actual @($dual24Balanced.selectedAdapters).Count -Message 'dual XTX balanced profile uses two cards only for the higher-ranked model'

$dual24Quality = Get-FixturePlan -Fixture 'dual-rx-7900-xtx-24gb.json' -Profile 'quality'
Assert-Equal -Expected 'qwen3.8-27b-q8-0' -Actual $dual24Quality.model.id -Message 'dual XTX quality profile selects Qwen3.8 Q8'
Assert-Equal -Expected 'layer' -Actual $dual24Quality.splitMode -Message 'dual XTX quality profile avoids experimental tensor parallelism'

$dualR9700Balanced = Get-FixturePlan -Fixture 'dual-r9700-32gb.json'
Assert-Equal -Expected 'qwen3.8-27b-ud-q6-k-m' -Actual $dualR9700Balanced.model.id -Message 'dual R9700 balanced profile keeps its highest-ranked eligible Q6 model'
Assert-Equal -Expected 1 -Actual @($dualR9700Balanced.selectedAdapters).Count -Message 'dual R9700 balanced profile prefers one card when Q6 already fits'
Assert-Equal -Expected 'ROCm0' -Actual $dualR9700Balanced.selectedAdapters[0].device -Message 'dual R9700 balanced profile uses the higher-free card'
Assert-Equal -Expected 'none' -Actual $dualR9700Balanced.splitMode -Message 'dual R9700 balanced profile does not force a split'

$dualR9700Quality = Get-FixturePlan -Fixture 'dual-r9700-32gb.json' -Profile 'quality'
Assert-Equal -Expected 'qwen3.8-27b-q8-0' -Actual $dualR9700Quality.model.id -Message 'dual R9700 quality profile selects Qwen3.8 Q8'
Assert-Equal -Expected 1 -Actual @($dualR9700Quality.selectedAdapters).Count -Message 'dual R9700 quality profile prefers one card when Q8 already fits'
Assert-Equal -Expected 'none' -Actual $dualR9700Quality.splitMode -Message 'dual R9700 quality profile does not force a split'

foreach ($pair in @($dual20,$dual20Quality,$dual24Balanced,$dual24Quality,$dualR9700Balanced,$dualR9700Quality)) {
    Assert-True -Condition ([bool] $pair.requestedAllGpuLayers -and -not [bool] $pair.placementVerified) -Message 'pair fixture requests all layers without asserting runtime placement'
    Assert-Equal -Expected 'f16' -Actual (Get-ServerArgumentValue -Arguments @($pair.serverArguments) -Name '--cache-type-k') -Message 'pair fixture retains FP16 key cache'
    Assert-Equal -Expected 'f16' -Actual (Get-ServerArgumentValue -Arguments @($pair.serverArguments) -Name '--cache-type-v') -Message 'pair fixture retains FP16 value cache'
}

$heterogeneous = Get-FixturePlan -Fixture 'heterogeneous-20gb-24gb.json'
Assert-Equal -Expected 1 -Actual @($heterogeneous.selectedAdapters).Count -Message 'heterogeneous GPUs are not combined by default'
Assert-Equal -Expected 'none' -Actual $heterogeneous.splitMode -Message 'heterogeneous profile uses the largest single adapter'
Assert-True -Condition ([bool] ((@($heterogeneous.warnings) -join ' ') -match 'Heterogeneous')) -Message 'heterogeneous selection is explained'

$mixedSingleAndPair = Get-FixturePlan -Fixture 'r9700-plus-dual-rx-7900-xt.json'
Assert-Equal -Expected 'qwen3.8-27b-ud-q6-k-m' -Actual $mixedSingleAndPair.model.id -Message 'mixed single-plus-pair hardware selects the best balanced model'
Assert-Equal -Expected 1 -Actual @($mixedSingleAndPair.selectedAdapters).Count -Message 'a fitting R9700 is preferred over an unnecessary identical XT pair'
Assert-Equal -Expected 'ROCm0' -Actual $mixedSingleAndPair.selectedAdapters[0].device -Message 'the strongest fitting single adapter is selected'
Assert-Equal -Expected 'none' -Actual $mixedSingleAndPair.splitMode -Message 'an unnecessary pair does not activate layer splitting'

$unsupportedThrew = $false
try {
    Get-FixturePlan -Fixture 'unsupported-2gb.json' | Out-Null
}
catch {
    $unsupportedThrew = $_.Exception.Message -match '(?i)(No AMD adapter|VRAM|CPU fallback)'
}
Assert-True -Condition $unsupportedThrew -Message 'hardware below the nominal-4GB reporting tolerance is rejected without CPU fallback'

Assert-True -Condition (Test-FastLlmIntegratedName -Name 'AMD Radeon Vega 8 Graphics') -Message 'legacy Radeon Vega APU naming is classified as integrated graphics'
Assert-True -Condition (Test-FastLlmIntegratedName -Name 'AMD Radeon RX Vega 11 Graphics') -Message 'legacy Radeon RX Vega APU naming is classified as integrated graphics'
Assert-ThrowsMatching -Action { Get-FixturePlan -Fixture 'legacy-vega-8-igpu.json' } -Pattern '(?i)No discrete AMD adapter|CPU plan' -Message 'shared-memory legacy Vega graphics cannot satisfy the 4GB discrete-GPU floor'

$reported4Gb = Get-FixturePlan -Fixture 'nominal-4gb-reported-3584mb.json'
Assert-Equal -Expected 'qwen3.5-4b-iq4-xs' -Actual $reported4Gb.model.id -Message 'a nominal 4GB card reported as 3584 MiB remains eligible'
Assert-Equal -Expected 1 -Actual @($reported4Gb.selectedAdapters).Count -Message 'the reported-size tolerance does not create aggregate capacity'

Assert-ThrowsMatching -Action { Get-FixturePlan -Fixture 'invalid-free-exceeds-total.json' } -Pattern '(?i)free.*(total|VRAM)|(total|VRAM).*free' -Message 'an adapter cannot report more free VRAM than total VRAM'

Assert-ThrowsMatching -Action { Get-FixturePlan -Fixture 'duplicate-device-identifiers.json' } -Pattern '(?i)duplicate.*device|device.*duplicate' -Message 'duplicate engine device identifiers are rejected'

$reserveBoundary = Get-FixturePlan -Fixture 'dual-reserve-boundary.json'
Assert-Equal -Expected 14400 -Actual $reserveBoundary.capacity.aggregateFreeVramMiB -Message 'dual reserve boundary reports raw aggregate capacity separately'
Assert-Equal -Expected 12864 -Actual $reserveBoundary.capacity.selectionFreeVramMiB -Message 'dual capacity deducts the reserve from every participating GPU'
Assert-Equal -Expected 'qwen3.5-9b-q6-k' -Actual $reserveBoundary.model.id -Message 'raw aggregate capacity cannot admit the 27B profile across the reserve boundary'
Assert-Equal -Expected '6432,6432' -Actual $reserveBoundary.tensorSplit -Message 'tensor split weights also deduct each device reserve'

$xtxWithIgpu = Get-FixturePlan -Fixture 'rx-7900-xtx-24gb-with-igpu.json'
Assert-Equal -Expected 1 -Actual @($xtxWithIgpu.selectedAdapters).Count -Message 'an XTX is not combined with integrated Radeon graphics'
Assert-Equal -Expected 'ROCm0' -Actual $xtxWithIgpu.selectedAdapters[0].device -Message 'the discrete XTX is selected instead of the iGPU'
Assert-Equal -Expected 23800 -Actual $xtxWithIgpu.capacity.aggregateFreeVramMiB -Message 'iGPU shared memory is excluded from aggregate capacity'

$dualXtxWithIgpu = Get-FixturePlan -Fixture 'dual-rx-7900-xtx-24gb-with-igpu.json' -Profile 'quality'
Assert-Equal -Expected 2 -Actual @($dualXtxWithIgpu.selectedAdapters).Count -Message 'two matching XTX cards remain usable when an iGPU is present'
Assert-Equal -Expected 'qwen3.8-27b-q8-0' -Actual $dualXtxWithIgpu.model.id -Message 'dual XTX plus iGPU bases quality selection on the discrete pair'
Assert-Equal -Expected 47400 -Actual $dualXtxWithIgpu.capacity.aggregateFreeVramMiB -Message 'dual XTX aggregate capacity excludes the iGPU'
Assert-Equal -Expected 45864 -Actual $dualXtxWithIgpu.capacity.selectionFreeVramMiB -Message 'dual XTX selection capacity reserves memory on both cards'
Assert-True -Condition (@($dualXtxWithIgpu.selectedAdapters.device) -notcontains 'ROCm2') -Message 'the iGPU device is absent from the selected device set'

$tripleXtx = Get-FixturePlan -Fixture 'triple-rx-7900-xtx-24gb.json' -Profile 'quality'
Assert-Equal -Expected 2 -Actual @($tripleXtx.selectedAdapters).Count -Message 'the preview multi-GPU policy caps a homogeneous group at two cards'
Assert-Equal -Expected 47400 -Actual $tripleXtx.capacity.aggregateFreeVramMiB -Message 'a third card does not inflate the supported dual-GPU capacity'
Assert-True -Condition (@($tripleXtx.selectedAdapters.device) -notcontains 'ROCm2') -Message 'the third card is not passed to the server'

$deviceText = Get-Content -LiteralPath (Join-Path $fixtureRoot 'llama-list-devices.txt') -Raw
$parsed = @(ConvertFrom-LlamaDeviceList -Text $deviceText -Backend 'ROCm')
Assert-Equal -Expected 2 -Actual $parsed.Count -Message 'llama.cpp device list parser finds both adapters'
Assert-Equal -Expected 24560 -Actual $parsed[0].vramMiB -Message 'device list parser preserves VRAM above the WMI uint32 limit'
Assert-Equal -Expected 24001 -Actual $parsed[1].freeVramMiB -Message 'device list parser records currently free VRAM'
$vulkanParsed = @(ConvertFrom-LlamaDeviceList -Text 'Vulkan0: AMD Radeon RX 7900 XTX (24576 MiB, 23800 MiB free)' -Backend 'Vulkan')
Assert-Equal -Expected 'Vulkan0' -Actual $vulkanParsed[0].device -Message 'device list parser accepts the enabled Vulkan lane device identifier'
Assert-Equal -Expected 'Vulkan' -Actual $vulkanParsed[0].backend -Message 'device list parser labels the enabled Vulkan lane correctly'

$catalog = Get-FastLlmCatalog -CatalogPath $catalogPath
Assert-True -Condition (Test-FastLlmHipSupportedName -Name 'AMD Radeon RX 7900 XTX' -Catalog $catalog) -Message '7900 XTX is in the ROCm qualification candidate allowlist'
Assert-True -Condition (-not (Test-FastLlmHipSupportedName -Name 'AMD Radeon Legacy Fixture' -Catalog $catalog)) -Message 'unknown AMD hardware does not enter ROCm by marketing name alone'
Assert-True -Condition (-not (Test-FastLlmHipSupportedName -Name 'AMD Radeon RX 7900 XTX Experimental' -Catalog $catalog)) -Message 'ROCm qualification does not accept a supported name as a longer-name substring'
Assert-True -Condition (-not (Test-FastLlmHipSupportedName -Name 'AMD Radeon RX 7900 XTWhatever' -Catalog $catalog)) -Message 'ROCm qualification requires a name boundary after a supported model'

$prerequisiteStatus = Get-FastLlmWindowsPrerequisiteStatus
Assert-Equal -Expected 'MSVCP140.dll,VCRUNTIME140.dll,VCRUNTIME140_1.dll' -Actual (@($prerequisiteStatus.vcRuntimeFiles) -join ',') -Message 'the Windows prerequisite check covers every imported VC14 runtime DLL'
if ($env:OS -ne 'Windows_NT') {
    Assert-True -Condition (-not [bool] $prerequisiteStatus.applicable) -Message 'Windows runtime prerequisites are not applied to offline cross-platform tests'
}

$manifestInstallRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('fast-llm-manifest-test-' + [Guid]::NewGuid().ToString('N'))
try {
    $manifestBackendRoot = Join-Path (Join-Path (Join-Path $manifestInstallRoot 'engines') 'manifest-test') 'vulkan'
    New-Item -ItemType Directory -Path $manifestBackendRoot -Force | Out-Null
    $manifestEnginePath = Join-Path $manifestBackendRoot 'llama-server.exe'
    [System.IO.File]::WriteAllBytes($manifestEnginePath, [System.Text.Encoding]::ASCII.GetBytes('verified-engine'))
    $manifestEngineItem = Get-Item -LiteralPath $manifestEnginePath
    $manifestAsset = [pscustomobject] @{
        enabled    = $true
        entryPoint = 'llama-server.exe'
        manifest   = @(
            [pscustomobject] @{
                path      = 'llama-server.exe'
                sizeBytes = [int64] $manifestEngineItem.Length
                sha256    = (Get-FileHash -LiteralPath $manifestEnginePath -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        )
    }
    Assert-True -Condition (Test-FastLlmEngineInstallation -InstallRoot $manifestInstallRoot -EngineVersion 'manifest-test' -BackendKey 'vulkan' -Asset $manifestAsset) -Message 'an exact one-file engine manifest verifies'

    $hiddenEnginePath = Join-Path $manifestBackendRoot '.ambient-backend.dll'
    [System.IO.File]::WriteAllBytes($hiddenEnginePath, [byte[]] @(1, 2, 3))
    if ($env:OS -eq 'Windows_NT') {
        $hiddenItem = Get-Item -LiteralPath $hiddenEnginePath -Force
        $hiddenItem.Attributes = $hiddenItem.Attributes -bor [System.IO.FileAttributes]::Hidden
    }
    Assert-True -Condition (-not (Test-FastLlmEngineInstallation -InstallRoot $manifestInstallRoot -EngineVersion 'manifest-test' -BackendKey 'vulkan' -Asset $manifestAsset)) -Message 'a hidden extra DLL invalidates the exact engine manifest'
}
finally {
    if (Test-Path -LiteralPath $manifestInstallRoot) {
        Remove-Item -LiteralPath $manifestInstallRoot -Recurse -Force
    }
}

$consentReuseRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('fast-llm-consent-test-' + [Guid]::NewGuid().ToString('N'))
try {
    $consentModelBytes = [System.Text.Encoding]::ASCII.GetBytes('already-verified-model')
    $consentModelHashAlgorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $consentModelHash = (($consentModelHashAlgorithm.ComputeHash($consentModelBytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally {
        $consentModelHashAlgorithm.Dispose()
    }
    $consentModel = [pscustomobject] @{
        id                    = 'consent-reuse-model'
        file                  = 'consent-reuse-model.gguf'
        url                   = 'https://example.invalid/consent-reuse-model.gguf'
        sizeBytes             = [int64] $consentModelBytes.Length
        sha256                = $consentModelHash
        upstreamModel         = 'fixture/upstream'
        upstreamRevision      = '1111111111111111111111111111111111111111'
        upstreamLicense       = 'fixture-license'
        upstreamLicenseUrl    = 'https://example.invalid/license'
        upstreamLicenseSha256 = '2222222222222222222222222222222222222222222222222222222222222222'
        repository            = 'fixture/artifact'
        revision              = '3333333333333333333333333333333333333333'
        artifactLicense       = 'fixture-license'
        artifactProvider      = 'fixture'
        servingMode           = 'test-only'
    }
    $consentPlan = [pscustomobject] @{ model = $consentModel }
    $consentModelsRoot = Join-Path $consentReuseRoot 'models'
    New-Item -ItemType Directory -Path $consentModelsRoot -Force | Out-Null
    $consentModelPath = Join-Path $consentModelsRoot $consentModel.file
    [System.IO.File]::WriteAllBytes($consentModelPath, $consentModelBytes)
    & (Get-Module FastLlm) { param($Model, $Root) Write-FastLlmModelConsentReceipt -Model $Model -InstallRoot $Root -AcceptanceMode 'explicit-switch' } $consentModel $consentReuseRoot
    $reusedModelPath = Install-FastLlmModel -Plan $consentPlan -InstallRoot $consentReuseRoot -Unattended
    Assert-Equal -Expected $consentModelPath -Actual $reusedModelPath -Message 'an exact consent receipt authorizes unattended reuse or repair of the same artifact'
    foreach ($field in @('upstreamModel','upstreamLicense','repository','artifactLicense')) {
        $changedModel = $consentModel | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $changedModel.$field = ([string] $changedModel.$field).ToUpperInvariant()
        $accepted = Test-FastLlmModelConsentReceipt -Model $changedModel -InstallRoot $consentReuseRoot
        Assert-Equal -Expected $false -Actual $accepted -Message "a changed consent-bound $field name cannot reuse the v1 receipt"
    }
}
finally {
    if (Test-Path -LiteralPath $consentReuseRoot) {
        Remove-Item -LiteralPath $consentReuseRoot -Recurse -Force
    }
}

$smallPlan = Get-FixturePlan -Fixture 'amd-4gb.json'
$largePlan = Get-FixturePlan -Fixture 'r9700-32gb.json'
$enabledLanePlan = Get-FixturePlan -Fixture 'rx-7900-xtx-24gb.json'
$singleArguments = @($enabledLanePlan.serverArguments)
Assert-Equal -Expected 'Vulkan' -Actual $enabledLanePlan.backend -Message 'launch contract coverage uses the enabled Vulkan lane'
Assert-True -Condition (-not (@($singleArguments | Where-Object { [string]::IsNullOrWhiteSpace([string] $_) }).Count)) -Message 'the server argument vector contains no null or blank entries'
Assert-Equal -Expected $enabledLanePlan.modelPath -Actual (Get-ServerArgumentValue -Arguments $singleArguments -Name '--model') -Message 'server arguments use the resolved model path'
Assert-True -Condition ($singleArguments -contains '--offline') -Message 'the server cannot fetch remote model or media resources at runtime'
Assert-True -Condition ($singleArguments -contains '--no-mmproj') -Message 'the text-only profile explicitly disables multimodal projector loading'
Assert-Equal -Expected 'none' -Actual (Get-ServerArgumentValue -Arguments $singleArguments -Name '--spec-type') -Message 'the text-only profile explicitly disables speculative MTP or draft decoding'
Assert-Equal -Expected $enabledLanePlan.model.id -Actual (Get-ServerArgumentValue -Arguments $singleArguments -Name '--alias') -Message 'server arguments expose the catalog model id as the alias'
Assert-Equal -Expected '127.0.0.1' -Actual (Get-ServerArgumentValue -Arguments $singleArguments -Name '--host') -Message 'the server remains loopback-only'
Assert-Equal -Expected '8080' -Actual (Get-ServerArgumentValue -Arguments $singleArguments -Name '--port') -Message 'the server uses the catalog port'
Assert-Equal -Expected 'localhost' -Actual (Get-ServerArgumentValue -Arguments $singleArguments -Name '--cors-origins') -Message 'browser CORS is restricted to localhost origins'
Assert-True -Condition ($singleArguments -contains '--no-cors-credentials') -Message 'browser CORS credentials are explicitly disabled'
Assert-Equal -Expected ([string] $enabledLanePlan.model.contextSize) -Actual (Get-ServerArgumentValue -Arguments $singleArguments -Name '--ctx-size') -Message 'the selected context size reaches llama-server'
Assert-Equal -Expected 'all' -Actual (Get-ServerArgumentValue -Arguments $singleArguments -Name '--n-gpu-layers') -Message 'the launch contract requests full GPU offload'
Assert-Equal -Expected 'on' -Actual (Get-ServerArgumentValue -Arguments $singleArguments -Name '--fit') -Message 'the launch contract keeps llama.cpp fit enabled'
Assert-Equal -Expected 'Vulkan0' -Actual (Get-ServerArgumentValue -Arguments $singleArguments -Name '--device') -Message 'single-GPU launch names only the selected enabled-lane device'
Assert-Equal -Expected 'none' -Actual (Get-ServerArgumentValue -Arguments $singleArguments -Name '--split-mode') -Message 'single-GPU launch disables splitting'
Assert-Equal -Expected 'auto' -Actual (Get-ServerArgumentValue -Arguments $singleArguments -Name '--flash-attn') -Message 'Flash Attention remains capability-gated by llama.cpp'
Assert-True -Condition ($singleArguments -contains '--jinja') -Message 'the launch contract enables model chat templates'
Assert-True -Condition ($singleArguments -contains '--metrics') -Message 'the launch contract enables local metrics'
Assert-Equal -Expected '4' -Actual (Get-ServerArgumentValue -Arguments $singleArguments -Name '--log-verbosity') -Message 'pinned loader INFO evidence is visible without verbose fit-probe duplicates'
Assert-True -Condition ($singleArguments -contains '--no-agent') -Message 'the API-only launch disables llama.cpp agent tools and MCP proxy behavior'
Assert-True -Condition ($singleArguments -contains '--no-ui') -Message 'the API-only launch disables the bundled web UI'
Assert-True -Condition ($singleArguments -notcontains '--tensor-split') -Message 'single-GPU launch omits tensor split weights'

$dualArguments = @($dualXtxWithIgpu.serverArguments)
Assert-Equal -Expected 'ROCm0,ROCm1' -Actual (Get-ServerArgumentValue -Arguments $dualArguments -Name '--device') -Message 'dual-GPU launch names exactly the selected discrete cards'
Assert-Equal -Expected 'layer' -Actual (Get-ServerArgumentValue -Arguments $dualArguments -Name '--split-mode') -Message 'dual-GPU launch uses the conservative layer split'
Assert-Equal -Expected '23032,22832' -Actual (Get-ServerArgumentValue -Arguments $dualArguments -Name '--tensor-split') -Message 'dual-GPU launch passes reserve-adjusted split weights'

Assert-True -Condition ($smallPlan.hardwareFingerprint -ne $largePlan.hardwareFingerprint) -Message 'a card swap changes the hardware fingerprint'
Assert-True -Condition ($smallPlan.model.id -ne $largePlan.model.id) -Message 'a card swap forces model reselection'

$launcherPath = Join-Path $projectRoot 'fast-llm.ps1'
$launcherSource = Get-Content -LiteralPath $launcherPath -Raw
$moduleSource = Get-Content -LiteralPath $modulePath -Raw
$offlinePlanGuardIndex = $launcherSource.IndexOf('$offlineFixturePlan = $Action -eq ''plan'' -and -not [string]::IsNullOrWhiteSpace($HardwareFile)')
$moduleImportIndex = $launcherSource.IndexOf('Import-Module $modulePath -Force')
Assert-True -Condition ($offlinePlanGuardIndex -ge 0) -Message 'the elevation exception is limited to an offline fixture plan'
Assert-True -Condition ($launcherSource.Contains('if (-not $offlineFixturePlan -and $principal.IsInRole')) -Message 'live plans remain inside the standard-user guard'
Assert-True -Condition ($offlinePlanGuardIndex -lt $moduleImportIndex) -Message 'the elevation guard runs before the local module is imported'
Assert-True -Condition ($launcherSource.Contains('$maximumPlanAttempts = 3')) -Message 'start bounds hardware/model re-planning attempts'
Assert-True -Condition ($moduleSource.Contains('$freshHardware = Get-FastLlmHardware')) -Message 'server startup re-probes hardware after hashing the selected model'
Assert-True -Condition ($moduleSource.Contains('[string] $freshPlan.modelPath -ne [string] $Plan.modelPath')) -Message 'the post-hash refresh cannot silently replace the verified model path'
Assert-True -Condition ($moduleSource.Contains('[string] $freshPlan.model.upstreamLicenseSha256 -ne [string] $Plan.model.upstreamLicenseSha256')) -Message 'the post-hash refresh cannot silently replace consent-bound model provenance'
Assert-True -Condition ($moduleSource.Contains("'ModelNeedsProvisioning'")) -Message 'a corrupt model is routed into the bounded provisioning repair loop'
Assert-True -Condition ($moduleSource.Contains("'--max-filesize', [string] `$SizeBytes")) -Message 'curl receives the catalog artifact size as a live transfer ceiling'
Assert-True -Condition ($moduleSource.Contains('$livePartial.Length -gt $SizeBytes')) -Message 'the downloader independently watches partial-file growth beyond the catalog size'
Assert-True -Condition ($moduleSource.Contains('$curlStarted -and -not $curlProcess.HasExited')) -Message 'interrupted curl children are terminated before the destination lock is released'
foreach ($environmentPattern in @("'LLAMA_*'", "'GGML_*'", "'VK_*'", "'HIP_*'", "'AIP_*'", "'MTMD_BACKEND_DEVICE'", "'HF_TOKEN'")) {
    Assert-True -Condition ($moduleSource.Contains($environmentPattern)) -Message "native launch sanitization covers $environmentPattern"
}

$fastLlmModule = Get-Module FastLlm
$quotedArgument = & $fastLlmModule { param($Value) ConvertTo-FastLlmProcessArgument -Value $Value } 'C:\Program Files\FastLLM\model.gguf'
Assert-Equal -Expected '"C:\Program Files\FastLLM\model.gguf"' -Actual $quotedArgument -Message 'native process arguments quote paths containing spaces'
$quotedTrailingSlash = & $fastLlmModule { param($Value) ConvertTo-FastLlmProcessArgument -Value $Value } 'C:\Path With Space\'
Assert-Equal -Expected '"C:\Path With Space\\"' -Actual $quotedTrailingSlash -Message 'native process arguments preserve a trailing slash inside quotes'
$quotedEmbeddedQuote = & $fastLlmModule { param($Value) ConvertTo-FastLlmProcessArgument -Value $Value } 'value"quoted'
Assert-Equal -Expected '"value\"quoted"' -Actual $quotedEmbeddedQuote -Message 'native process arguments escape embedded quotes'

# Exercise the production arithmetic expression under this host's overload
# binder, including Windows PowerShell 5.1, without allocating a large file.
$downloadAst = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref] $null, [ref] $null)
$remainingAssignment = $downloadAst.Find({ param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -eq '$remainingBytes'
}, $true)
$remainingExpression = [scriptblock]::Create($remainingAssignment.Right.Extent.Text)
foreach ($case in @(
    @{ total = [int64] 16464440224; existing = [int64] 0; expected = [int64] 16464440224 },
    @{ total = [int64] 16464440224; existing = [int64] 9000000000; expected = [int64] 7464440224 },
    @{ total = [int64] 16464440224; existing = [int64] 16464440224; expected = [int64] 0 },
    @{ total = [int64] 16464440224; existing = [int64] 16464440225; expected = [int64] 0 }
)) {
    $SizeBytes = $case.total; $existingBytes = $case.existing
    Assert-Equal -Expected $case.expected -Actual (& $remainingExpression) -Message "download remaining bytes use 64-bit arithmetic ($existingBytes of $SizeBytes)"
}

$currentPowerShell = (Get-Process -Id $PID).Path
$cliOutput = & $currentPowerShell -NoLogo -NoProfile -File $launcherPath plan -HardwareFile (Join-Path $fixtureRoot 'rx-7900-xtx-24gb.json') -InstallRoot (Join-Path $projectRoot '.test-install') -AsJson 2>&1
$cliExitCode = $LASTEXITCODE
$cliJson = $null
try {
    $cliJson = (($cliOutput | Out-String) | ConvertFrom-Json)
}
catch {
    # The assertions below report both the process and JSON contract failures.
}
Assert-Equal -Expected 0 -Actual $cliExitCode -Message 'the plan CLI JSON path exits successfully'
Assert-True -Condition ($null -ne $cliJson) -Message 'the plan CLI emits parseable JSON without presentation text'
if ($cliJson) {
    Assert-Equal -Expected 'qwen3.8-27b-ud-q4-k-m' -Actual $cliJson.model.id -Message 'CLI JSON preserves deterministic model selection'
    Assert-Equal -Expected 'http://127.0.0.1:8080/v1' -Actual $cliJson.endpoint -Message 'CLI JSON reports the loopback OpenAI-compatible endpoint'
}

$dryRunInstallRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('fast-llm-install-dry-run-' + [Guid]::NewGuid().ToString('N'))
$previousErrorActionPreference = $ErrorActionPreference
try {
    # Windows PowerShell 5.1 promotes redirected native stderr to a terminating
    # NativeCommandError under Stop; this child is expected to reject -DryRun.
    $ErrorActionPreference = 'Continue'
    $dryRunInstallOutput = & $currentPowerShell -NoLogo -NoProfile -File $launcherPath install -DryRun -InstallRoot $dryRunInstallRoot 2>&1
    $dryRunInstallExitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $previousErrorActionPreference
}
Assert-True -Condition ($dryRunInstallExitCode -ne 0) -Message 'install rejects the misleading mutating -DryRun combination'
Assert-True -Condition ((($dryRunInstallOutput | Out-String) -match '(?i)Use plan|non-mutating')) -Message 'install -DryRun directs users to the non-mutating plan action'
Assert-True -Condition (-not (Test-Path -LiteralPath $dryRunInstallRoot)) -Message 'rejected install -DryRun creates no install state'

Write-Host "`n$script:passed passed; $script:failed failed"
if ($script:failed -gt 0) {
    exit 1
}
