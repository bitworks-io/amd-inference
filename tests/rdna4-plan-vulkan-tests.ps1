#requires -Version 5.1
# RDNA4 HIP runtime components are experimental: nothing selects them. An RDNA4 card's plan stays on Vulkan, and no shipped recipe,
# GPU variant or catalog entry names them. Pure config and fixture work; no engine, GPU or network.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$root = Split-Path $PSScriptRoot -Parent
$module = Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force -PassThru -ErrorAction Stop
$script:count = 0
function Check($Condition, [string] $Message) { if (-not $Condition) { throw "FAIL: $Message" }; $script:count++; Write-Host "PASS: $Message" }

$catalogPath = Join-Path $root 'config/catalog.json'
$recipesPath = Join-Path $root 'config/recipes.json'
$variantsPath = Join-Path $root 'config/gpu-variants.json'
$work = Join-Path ([IO.Path]::GetTempPath()) ('rdna4-plan-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
try {
    # Nothing in the shipped selection config names the new ids.
    foreach ($configPath in @($catalogPath, $recipesPath, $variantsPath)) {
        $configText = Get-Content -LiteralPath $configPath -Raw
        Check ($configText -notmatch 'gfx120[01]' -and $configText -notmatch 'hip-b11658-gfx') ("no RDNA4 HIP component id or gfx target in " + (Split-Path $configPath -Leaf))
    }
    $recipeDoc = Get-Content -LiteralPath $recipesPath -Raw | ConvertFrom-Json
    $recipeEngines = @($recipeDoc.recipes | ForEach-Object { [string] $_.components.engine } | Sort-Object -Unique)
    Check (@($recipeEngines | Where-Object { $_ -like '*gfx*' }).Count -eq 0) 'no shipped recipe runs on an RDNA4 engine id'

    function New-Rdna4Hardware([string] $Name, [int] $VramMiB) {
        [pscustomobject] @{ schemaVersion = 1; source = 'rdna4-fixture'; backend = 'Vulkan'; enginePath = 'C:\FastLLM\vulkan\llama-server.exe'
            adapters = @([pscustomobject] @{ device = 'Vulkan0'; name = $Name; vendorId = '1002'; vramMiB = $VramMiB; freeVramMiB = ($VramMiB - 1024); isAmd = $true; isIntegrated = $false; backend = 'Vulkan'; driverVersion = 'fixture' }) }
    }
    $installRoot = Join-Path $work 'install'
    New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
    foreach ($card in @(@('AMD Radeon RX 9070 XT', 16304), @('AMD Radeon RX 9070', 16304), @('AMD Radeon AI PRO R9700', 32624), @('AMD Radeon RX 9060 XT', 16304), @('AMD Radeon RX 9060', 8176))) {
        $hardware = New-Rdna4Hardware $card[0] $card[1]
        $planArgs = @{ Hardware = $hardware; CatalogPath = $catalogPath; Profile = 'balanced'; InstallRoot = $installRoot; RecipesPath = $recipesPath; GpuVariantsPath = $variantsPath; NoEngineExecution = $true }
        $plan = & $module { param($a) Get-FastLlmPlan @a } $planArgs
        $planText = $plan | ConvertTo-Json -Depth 20
        Check ([string] $plan.backend -ieq 'vulkan') ("the " + $card[0] + " plan is Vulkan")
        Check ($null -eq $plan.PSObject.Properties['runtimeRoots'] -and $null -eq $plan.PSObject.Properties['engineComponentId']) ("the " + $card[0] + " plan names no engine component and no runtime roots")
        Check ($planText -notmatch '(?i)gfx120|hip-b11658|amd-rocm') ("the " + $card[0] + " plan mentions no HIP engine or ROCm runtime")
    }
    Write-Host "rdna4-plan-vulkan-tests: $($script:count) checks passed"
}
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
