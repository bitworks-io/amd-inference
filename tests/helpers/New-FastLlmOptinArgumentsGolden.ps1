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
            'test-24gb-22000' { @((& $adapter 'Vulkan0' 24576 22000)) }
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
        @('long-explicit-model', 'test-24gb', 'qwen3.8-27b-ud-q4-k-m-4af51b35', 'long', 1, 'auto', 'off'),
        @('long-smaller-card', 'test-12gb', 'auto', 'long', 1, 'auto', 'off'),
        @('long-two-slots-smaller-card', 'test-12gb', 'auto', 'long', 2, 'auto', 'off'),
        @('long-no-row', 'test-24gb', 'qwen3.5-9b-q8-0', 'long', 1, 'auto', 'off'),
        @('two-slots-not-allowed', 'test-24gb', 'qwen3.5-9b-q6-k', 'long', 2, 'auto', 'off'),
        @('two-slots-no-row', 'test-24gb', 'qwen3.5-9b-q6-k', 'default', 2, 'auto', 'off'),
        @('long-row-memory-explicit', 'test-24gb-tight', 'qwen3.8-27b-ud-q4-k-m-4af51b35', 'long', 1, 'auto', 'off'),
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

# The vision option's rows (-Vision on), planned from the TEST rows in tests/fixtures/vision-profiles-test.json (the serving profile rows of the
# opt-in matrix plus two vision add-on rows). Each plan row also carries argumentsWithProjector: the arguments of the same plan WITHOUT vision, with
# the --no-mmproj element replaced in place by --mmproj and a projector path that contains a space (the one helper that builds it). Pure planner work.
function Get-FastLlmVisionArgumentsMatrix {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $InstallRoot
    )
    $module = Import-Module (Join-Path $Root 'src/FastLlm.psm1') -Force -PassThru -ErrorAction Stop
    $visionProfiles = Join-Path $Root 'tests/fixtures/vision-profiles-test.json'
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
            'test-24gb-22000' { @((& $adapter 'Vulkan0' 24576 22000)) }
            'test-12gb' { @((& $adapter 'Vulkan0' 12272 11474)) }
            default { throw "Unknown vision test hardware '$Name'." }
        }
        return [pscustomobject]@{
            schemaVersion = 1; source = 'optin-test'; backend = 'Vulkan'; enginePath = 'C:\FastLLM\vulkan\llama-server.exe'; adapters = @($adapters)
        }
    }
    $normalise = {
        param([string] $Text)
        $value = $Text
        foreach ($variant in @($InstallRoot, $InstallRoot.Replace('\', '/'), $InstallRoot.Replace('/', '\'))) {
            if ($variant) { $value = $value.Replace($variant, '<install-root>') }
        }
        return $value.Replace('\', '/')
    }
    $projectorPath = 'C:\Users\Test User\FastLLM\components\projector\test-vision-projector-q8\test-vision-projector-q8.gguf'
    # name, hardware, request (auto or a model id), contextProfile, slots
    $cases = @(
        @('vision-long', 'test-24gb', 'qwen3.8-27b-ud-q4-k-m-4af51b35', 'long', 1),
        @('vision-long-two-slots', 'test-24gb', 'qwen3.8-27b-ud-q4-k-m-4af51b35', 'long', 2),
        @('vision-default-two-slots', 'test-24gb', 'qwen3.8-27b-ud-q4-k-m-4af51b35', 'default', 2),
        @('vision-smaller-model-long', 'test-24gb', 'qwen3.5-9b-q6-k', 'long', 1),
        @('vision-extra-memory-tips-the-fit', 'test-12gb', 'qwen3.5-9b-q6-k', 'long', 1),
        @('vision-default-context-no-profile-id', 'test-24gb', 'qwen3.8-27b-ud-q4-k-m-4af51b35', 'default', 1),
        @('vision-row-has-no-value-for-the-profile', 'test-12gb', 'qwen3.5-9b-q6-k', 'default', 1),
        @('vision-no-row-for-the-model', 'test-24gb', 'qwen3.8-27b-q8-0', 'long', 1),
        @('vision-fit-adds-the-extra-memory', 'test-24gb-22000', 'qwen3.8-27b-ud-q4-k-m-4af51b35', 'long', 1)
    )
    $rows = New-Object System.Collections.ArrayList
    foreach ($case in $cases) {
        $parameters = @{
            CatalogPath = Join-Path $Root 'config/catalog.json'; Profile = 'balanced'; NoEngineExecution = $true; InstallRoot = $InstallRoot
            KvProfilesPath = $visionProfiles; Hardware = (& $hardwareFor ([string] $case[1])); ModelId = [string] $case[2]
            KvContextProfile = [string] $case[3]; KvSlots = [int] $case[4]
        }
        $outcome = 'plan'; $refusal = ''; $refusalCode = ''; $arguments = @(); $withProjector = @(); $requiredFree = 0; $extra = 0; $profileId = ''
        try {
            $plan = Get-FastLlmPlan @parameters -Vision 'on'
            $arguments = @($plan.serverArguments | ForEach-Object { & $normalise ([string] $_) })
            $requiredFree = [int64] $plan.vision.requiredFreeVramMiB; $extra = [int] $plan.vision.extraFreeVramMiB; $profileId = [string] $plan.vision.profileId
            # The same plan without vision (a default-context row has no vision plan to compare, so it is planned only when the plan above exists).
            $basePlan = Get-FastLlmPlan @parameters
            $baseArguments = @($basePlan.serverArguments | ForEach-Object { [string] $_ })
            $built = @(& $module { param($A, $P) Get-FastLlmVisionArguments -Arguments $A -ProjectorPath $P } $baseArguments $projectorPath)
            # The projector path is not an install-root path: keep it as it is (the normaliser would turn its backslashes into slashes).
            $withProjector = @($built | ForEach-Object { if ([string] $_ -ceq $projectorPath) { [string] $_ } else { & $normalise ([string] $_) } })
        }
        catch {
            $outcome = 'refused'; $refusal = (& $normalise ([string] $_.Exception.Message)); $refusalCode = [string] $_.Exception.Data['FastLlmFailureCode']
        }
        [void] $rows.Add([pscustomobject] [ordered] @{
                name = [string] $case[0]; hardware = [string] $case[1]; request = [string] $case[2]
                contextProfile = [string] $case[3]; slots = [int] $case[4]
                outcome = $outcome; refusalCode = $refusalCode; refusal = $refusal; visionProfileId = $profileId
                extraFreeVramMiB = $extra; requiredFreeVramMiB = $requiredFree
                arguments = [string[]] $arguments; argumentsWithProjector = [string[]] $withProjector
            })
    }
    return $rows.ToArray()
}

# The speculation option's rows (-Speculation ngram|mtp), planned from the TEST rows in tests/fixtures/speculation-profiles-test.json (the serving
# profile rows of the opt-in matrix plus vision, ngram and mtp add-on rows). A plan row records the whole argument list: the --spec-type value is the
# row's, the row's extra arguments are appended at the end, and an mtp plan shows --spec-draft-model <verified-draft>. Pure planner work.
function Get-FastLlmSpeculationArgumentsMatrix {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $InstallRoot
    )
    $module = Import-Module (Join-Path $Root 'src/FastLlm.psm1') -Force -PassThru -ErrorAction Stop
    $specProfiles = Join-Path $Root 'tests/fixtures/speculation-profiles-test.json'
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
            'test-12gb' { @((& $adapter 'Vulkan0' 12272 11474)) }
            default { throw "Unknown speculation test hardware '$Name'." }
        }
        return [pscustomobject]@{
            schemaVersion = 1; source = 'optin-test'; backend = 'Vulkan'; enginePath = 'C:\FastLLM\vulkan\llama-server.exe'; adapters = @($adapters)
        }
    }
    $normalise = {
        param([string] $Text)
        $value = $Text
        foreach ($variant in @($InstallRoot, $InstallRoot.Replace('\', '/'), $InstallRoot.Replace('/', '\'))) {
            if ($variant) { $value = $value.Replace($variant, '<install-root>') }
        }
        return $value.Replace('\', '/')
    }
    # name, hardware, request (a model id), mode, contextProfile, slots, vision
    $cases = @(
        @('ngram-long', 'test-24gb', 'qwen3.8-27b-ud-q4-k-m-4af51b35', 'ngram', 'long', 1, 'off'),
        @('ngram-mod-no-extra-arguments', 'test-12gb', 'qwen3.5-9b-q6-k', 'ngram', 'long', 1, 'off'),
        @('mtp-long', 'test-24gb', 'qwen3.8-27b-ud-q4-k-m-4af51b35', 'mtp', 'long', 1, 'off'),
        @('refused-no-row-for-the-model', 'test-24gb', 'qwen3.8-27b-q8-0', 'ngram', 'long', 1, 'off'),
        @('refused-no-mtp-row-for-the-model', 'test-12gb', 'qwen3.5-9b-q6-k', 'mtp', 'long', 1, 'off'),
        @('refused-row-has-no-value-for-the-profile', 'test-12gb', 'qwen3.5-9b-q6-k', 'ngram', 'default', 1, 'off'),
        @('refused-explicit-default-has-no-profile-id', 'test-24gb', 'qwen3.8-27b-ud-q4-k-m-4af51b35', 'ngram', 'default', 1, 'off'),
        @('refused-mtp-explicit-default-has-no-profile-id', 'test-24gb', 'qwen3.8-27b-ud-q4-k-m-4af51b35', 'mtp', 'default', 1, 'off'),
        @('refused-two-slots', 'test-24gb', 'qwen3.8-27b-ud-q4-k-m-4af51b35', 'ngram', 'long', 2, 'off'),
        @('refused-with-vision', 'test-24gb', 'qwen3.8-27b-ud-q4-k-m-4af51b35', 'ngram', 'long', 1, 'on')
    )
    $rows = New-Object System.Collections.ArrayList
    foreach ($case in $cases) {
        $parameters = @{
            CatalogPath = Join-Path $Root 'config/catalog.json'; Profile = 'balanced'; NoEngineExecution = $true; InstallRoot = $InstallRoot
            KvProfilesPath = $specProfiles; Hardware = (& $hardwareFor ([string] $case[1])); ModelId = [string] $case[2]
            KvContextProfile = [string] $case[4]; KvSlots = [int] $case[5]; Speculation = [string] $case[3]
        }
        if ([string] $case[6] -ceq 'on') { $parameters['Vision'] = 'on' }
        $outcome = 'plan'; $refusal = ''; $refusalCode = ''; $arguments = @(); $specType = ''; $extraArguments = @(); $requiredFree = 0; $extra = 0
        try {
            $plan = Get-FastLlmPlan @parameters
            $arguments = @($plan.serverArguments | ForEach-Object { & $normalise ([string] $_) })
            $specType = [string] $plan.speculation.specType; $extraArguments = @($plan.speculation.extraArguments | ForEach-Object { [string] $_ })
            $requiredFree = [int64] $plan.speculation.requiredFreeVramMiB; $extra = [int] $plan.speculation.extraFreeVramMiB
        }
        catch {
            $outcome = 'refused'; $refusal = (& $normalise ([string] $_.Exception.Message)); $refusalCode = [string] $_.Exception.Data['FastLlmFailureCode']
        }
        [void] $rows.Add([pscustomobject] [ordered] @{
                name = [string] $case[0]; hardware = [string] $case[1]; request = [string] $case[2]; mode = [string] $case[3]
                contextProfile = [string] $case[4]; slots = [int] $case[5]; vision = [string] $case[6]
                outcome = $outcome; refusalCode = $refusalCode; refusal = $refusal; specType = $specType; extraArguments = [string[]] $extraArguments
                extraFreeVramMiB = $extra; requiredFreeVramMiB = $requiredFree; arguments = [string[]] $arguments
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
        $visionRows = @(Get-FastLlmVisionArgumentsMatrix -Root $root -InstallRoot $installRoot)
        $speculationRows = @(Get-FastLlmSpeculationArgumentsMatrix -Root $root -InstallRoot $installRoot)
        $document = [ordered] @{
            schema                = 'fastllm.optin-arguments-golden.v1'
            catalogSha256         = ((Get-Content -LiteralPath (Join-Path $root 'config/catalog.sha256') -Raw).Trim() -split '\s+')[0]
            servingProfilesSha256 = (Get-FileHash -LiteralPath (Join-Path $root 'tests/fixtures/serving-profiles-test.json') -Algorithm SHA256).Hash.ToLowerInvariant()
            rows                  = $rows
            visionProfilesSha256  = (Get-FileHash -LiteralPath (Join-Path $root 'tests/fixtures/vision-profiles-test.json') -Algorithm SHA256).Hash.ToLowerInvariant()
            visionRows            = $visionRows
            speculationProfilesSha256 = (Get-FileHash -LiteralPath (Join-Path $root 'tests/fixtures/speculation-profiles-test.json') -Algorithm SHA256).Hash.ToLowerInvariant()
            speculationRows       = $speculationRows
        }
        $json = ($document | ConvertTo-Json -Depth 8) + "`n"
        [IO.File]::WriteAllText($OutputPath, $json, (New-Object Text.UTF8Encoding($false)))
        Write-Host "Wrote $($rows.Count) rows to $OutputPath"
    }
    finally { Remove-Item -LiteralPath $installRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
