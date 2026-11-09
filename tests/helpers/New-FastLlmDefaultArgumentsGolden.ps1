#requires -Version 5.1
# Default llama-server argument matrix. Dot-source it for Get-FastLlmDefaultArgumentsMatrix; run it as a script to (re)write
# tests/fixtures/default-server-arguments.json. Pure planner work: no engine, GPU or network.
param([string] $OutputPath)

function Get-FastLlmDefaultArgumentsMatrix {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $InstallRoot,
        [hashtable] $PlanParameters = @{}
    )
    $module = Import-Module (Join-Path $Root 'src/FastLlm.psm1') -Force -PassThru -ErrorAction Stop
    $catalogPath = Join-Path $Root 'config/catalog.json'
    $common = @{
        CatalogPath       = $catalogPath
        RecipesPath       = Join-Path $Root 'config/recipes.json'
        GpuVariantsPath   = Join-Path $Root 'config/gpu-variants.json'
        Profile           = 'balanced'
        NoEngineExecution = $true
        InstallRoot       = $InstallRoot
    }
    foreach ($key in @($PlanParameters.Keys)) { $common[$key] = $PlanParameters[$key] }

    $normalise = {
        param([string] $Text)
        $value = $Text
        $variants = @($InstallRoot, $InstallRoot.Replace('\', '/'), $InstallRoot.Replace('/', '\'))
        foreach ($variant in $variants) {
            if ($variant) { $value = $value.Replace($variant, '<install-root>') }
        }
        return $value.Replace('\', '/')
    }
    $rowFor = {
        param([string] $Tier, [string] $Budget, $FreeVram, [string] $Request, $Hardware, [string] $ModelId)
        $parameters = @{}
        foreach ($key in @($common.Keys)) { $parameters[$key] = $common[$key] }
        $parameters['Hardware'] = $Hardware
        if ($ModelId) { $parameters['ModelId'] = $ModelId }
        $outcome = 'plan'; $refusal = ''; $arguments = @(); $recipeId = ''
        try {
            $plan = Get-FastLlmPlan @parameters
            $planArguments = @($plan.serverArguments)
            if ($plan.PSObject.Properties['recipe'] -and $plan.recipe) { $recipeId = [string] $plan.recipe.id }
            if ($planArguments.Count -eq 0) { $outcome = 'pending' }
            else { $arguments = @($planArguments | ForEach-Object { & $normalise ([string] $_) }) }
        }
        catch {
            # Every planner refusal (no fit, explicit model too large, context ceiling) is recorded with its message.
            $outcome = 'refused'; $refusal = (& $normalise ([string] $_.Exception.Message))
        }
        return [pscustomobject] [ordered] @{
            tier = $Tier; budget = $Budget; freeVramMiB = $FreeVram; request = $Request
            outcome = $outcome; refusal = $refusal; recipeId = $recipeId; arguments = [string[]] $arguments
        }
    }

    $catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
    $modelIds = @($catalog.models | ForEach-Object { [string] $_.id })
    $tiers = @((Get-Content -LiteralPath (Join-Path $Root 'config/preload-tiers.json') -Raw | ConvertFrom-Json).tiers | Sort-Object -Property vramMiB)
    $rows = New-Object System.Collections.ArrayList
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
            [void] $rows.Add((& $rowFor ([string] $tier.id) $budget ([int] $free) 'auto' $hardware ''))
            foreach ($modelId in $modelIds) {
                [void] $rows.Add((& $rowFor ([string] $tier.id) $budget ([int] $free) $modelId $hardware $modelId))
            }
        }
    }
    $fixtureNames = @('rx-7900-xt-20gb-identified', 'rx-7900-xt-20gb', 'rx-7900-xtx-24gb', 'rx-7900-xtx-24gb-with-igpu', 'dual-rx-7900-xt-20gb',
        'dual-rx-7900-xtx-24gb', 'dual-r9700-32gb', 'r9700-32gb', 'r9700-plus-dual-rx-7900-xt', 'amd-4gb', 'amd-8gb', 'amd-12gb', 'amd-16gb')
    foreach ($name in $fixtureNames) {
        $hardware = Get-Content -LiteralPath (Join-Path $Root "tests/fixtures/$name.json") -Raw | ConvertFrom-Json
        [void] $rows.Add((& $rowFor ('fixture:' + $name) '' 0 'auto' $hardware ''))
    }
    return $rows.ToArray()
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version 2.0
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    if (-not $OutputPath) { $OutputPath = Join-Path $root 'tests/fixtures/default-server-arguments.json' }
    $installRoot = Join-Path ([IO.Path]::GetTempPath()) ('fastllm-golden-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
    try {
        $rows = @(Get-FastLlmDefaultArgumentsMatrix -Root $root -InstallRoot $installRoot)
        $baseCommit = (& git -C $root rev-parse HEAD).Trim()
        $catalogSha = ((Get-Content -LiteralPath (Join-Path $root 'config/catalog.sha256') -Raw).Trim() -split '\s+')[0]
        $document = [ordered] @{
            schema              = 'fastllm.default-arguments-golden.v1'
            baseCommit          = $baseCommit
            catalogSha256       = $catalogSha
            hipRecipeCoverage   = 'fallback-vulkan-rows-pinned-to-components-tests: a HIP recipe plan under -NoEngineExecution fails typed (fixture-plan-cannot-probe-engine) and the planner returns the fallback recipe, and the HIP component check hashes at Full depth, so no fake tree is accepted without product changes; the suite pins the recipe rows to the arrays in tests/components-tests.ps1 and the HIP pin stays there.'
            rows                = $rows
        }
        $json = ($document | ConvertTo-Json -Depth 8) + "`n"
        [IO.File]::WriteAllText($OutputPath, $json, (New-Object Text.UTF8Encoding($false)))
        Write-Host "Wrote $($rows.Count) rows to $OutputPath"
    }
    finally { Remove-Item -LiteralPath $installRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
