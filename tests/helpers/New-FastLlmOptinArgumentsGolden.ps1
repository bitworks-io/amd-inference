#requires -Version 5.1
# Opt-in llama-server argument matrix (context profile and slots). Dot-source it for Get-FastLlmOptinArgumentsMatrix; run it as a script to
# (re)write tests/fixtures/optin-server-arguments.json. The rows are planned from the TEST profile rows in
# tests/fixtures/serving-profiles-test.json, never from config/serving-profiles.json. Pure planner work: no engine, GPU or network.
param([string] $OutputPath)

function Get-FastLlmOptinArgumentsMatrix {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $InstallRoot,
        [string] $KvProfilesPath
    )
    $module = Import-Module (Join-Path $Root 'src/FastLlm.psm1') -Force -PassThru -ErrorAction Stop
    if (-not $KvProfilesPath) { $KvProfilesPath = Join-Path $Root 'tests/fixtures/serving-profiles-test.json' }
    $common = @{
        CatalogPath         = Join-Path $Root 'config/catalog.json'
        Profile             = 'balanced'
        NoEngineExecution   = $true
        InstallRoot         = $InstallRoot
        KvProfilesPath = $KvProfilesPath
    }
    $normalise = {
        param([string] $Text)
        $value = $Text
        $variants = @($InstallRoot, $InstallRoot.Replace('\', '/'), $InstallRoot.Replace('/', '\'))
        foreach ($variant in $variants) {
            if ($variant) { $value = $value.Replace($variant, '<install-root>') }
        }
        return $value.Replace('\', '/')
    }
    $adapter = {
        param([string] $Device, [int] $Vram, [int] $Free)
        return [pscustomobject]@{
            device = $Device; name = 'Opt-in test card'; vendorId = '1002'; vramMiB = $Vram; freeVramMiB = $Free
            isAmd = $true; isIntegrated = $false; backend = 'Vulkan'; driverVersion = 'optin-test'
        }
    }
    $hardwareFor = {
        param([string] $Name)
        $adapters = switch ($Name) {
            'test-24gb' { @((& $adapter 'Vulkan0' 24576 23552)) }
            'test-24gb-tight' { @((& $adapter 'Vulkan0' 24576 21000)) }
            'test-12gb' { @((& $adapter 'Vulkan0' 12272 11474)) }
            'test-dual-24gb' { @((& $adapter 'Vulkan0' 24576 23552), (& $adapter 'Vulkan1' 24576 23552)) }
            default { throw "Unknown opt-in test hardware '$Name'." }
        }
        return [pscustomobject]@{
            schemaVersion = 1; source = 'optin-test'; backend = 'Vulkan'; enginePath = 'C:\FastLLM\vulkan\llama-server.exe'; adapters = @($adapters)
        }
    }
    # name, hardware, request (auto or a model id), contextProfile, slots, thinking, chatPage
    $cases = @(
        @('long', 'test-24gb', 'auto', 'long', 1, 'auto', 'off'),
        @('long-two-slots', 'test-24gb', 'auto', 'long', 2, 'auto', 'off'),
        @('default-two-slots', 'test-24gb', 'auto', 'default', 2, 'auto', 'off'),
        @('long-explicit-model', 'test-24gb', 'qwen3.8-27b-ud-q4-k-m', 'long', 1, 'auto', 'off'),
        @('long-smaller-card', 'test-12gb', 'auto', 'long', 1, 'auto', 'off'),
        @('long-two-slots-smaller-card', 'test-12gb', 'auto', 'long', 2, 'auto', 'off'),
        @('long-no-row', 'test-24gb', 'qwen3.5-9b-q8-0', 'long', 1, 'auto', 'off'),
        @('two-slots-not-allowed', 'test-24gb', 'qwen3.5-9b-q6-k', 'long', 2, 'auto', 'off'),
        @('two-slots-no-row', 'test-24gb', 'qwen3.5-9b-q6-k', 'default', 2, 'auto', 'off'),
        @('long-row-memory-explicit', 'test-24gb-tight', 'qwen3.8-27b-ud-q4-k-m', 'long', 1, 'auto', 'off'),
        @('long-row-memory-auto', 'test-24gb-tight', 'auto', 'long', 1, 'auto', 'off'),
        @('long-two-slots-two-cards', 'test-dual-24gb', 'qwen3.8-27b-q8-0', 'long', 2, 'auto', 'off'),
        @('long-thinking-off-chat-page-on', 'test-24gb', 'auto', 'long', 1, 'off', 'on')
    )
    $rows = New-Object System.Collections.ArrayList
    foreach ($case in $cases) {
        $parameters = @{}
        foreach ($key in @($common.Keys)) { $parameters[$key] = $common[$key] }
        $parameters['Hardware'] = & $hardwareFor ([string] $case[1])
        if ([string] $case[2] -cne 'auto') { $parameters['ModelId'] = [string] $case[2] }
        $parameters['KvContextProfile'] = [string] $case[3]
        $parameters['KvSlots'] = [int] $case[4]
        $parameters['Thinking'] = [string] $case[5]
        $parameters['ChatPage'] = [string] $case[6]
        $outcome = 'plan'; $refusal = ''; $arguments = @(); $modelId = ''; $contextPerSlot = 0
        try {
            $plan = Get-FastLlmPlan @parameters
            $arguments = @($plan.serverArguments | ForEach-Object { & $normalise ([string] $_) })
            $modelId = [string] $plan.model.id
            if ($plan.PSObject.Properties['servingProfile'] -and $plan.servingProfile) { $contextPerSlot = [int] $plan.servingProfile.contextPerSlot }
        }
        catch {
            $outcome = 'refused'; $refusal = (& $normalise ([string] $_.Exception.Message))
        }
        [void] $rows.Add([pscustomobject] [ordered] @{
                name = [string] $case[0]; hardware = [string] $case[1]; request = [string] $case[2]
                contextProfile = [string] $case[3]; slots = [int] $case[4]; thinking = [string] $case[5]; chatPage = [string] $case[6]
                outcome = $outcome; refusal = $refusal; modelId = $modelId; contextPerSlot = $contextPerSlot; arguments = [string[]] $arguments
            })
    }
    return $rows.ToArray()
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version 2.0
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    if (-not $OutputPath) { $OutputPath = Join-Path $root 'tests/fixtures/optin-server-arguments.json' }
    $installRoot = Join-Path ([IO.Path]::GetTempPath()) ('fastllm-optin-golden-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
    try {
        $rows = @(Get-FastLlmOptinArgumentsMatrix -Root $root -InstallRoot $installRoot)
        $document = [ordered] @{
            schema                = 'fastllm.optin-arguments-golden.v1'
            catalogSha256         = ((Get-Content -LiteralPath (Join-Path $root 'config/catalog.sha256') -Raw).Trim() -split '\s+')[0]
            servingProfilesSha256 = (Get-FileHash -LiteralPath (Join-Path $root 'tests/fixtures/serving-profiles-test.json') -Algorithm SHA256).Hash.ToLowerInvariant()
            rows                  = $rows
        }
        $json = ($document | ConvertTo-Json -Depth 8) + "`n"
        [IO.File]::WriteAllText($OutputPath, $json, (New-Object Text.UTF8Encoding($false)))
        Write-Host "Wrote $($rows.Count) rows to $OutputPath"
    }
    finally { Remove-Item -LiteralPath $installRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
