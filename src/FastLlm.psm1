Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FastLlm.SelectedDeviceIdentity.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.CardIdentity.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.Recipes.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.Runtime.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.OffloadLab.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.Benchmark.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.VulkanMemoryPolicy.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.SelfTest.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.DeviceBinding.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.OffloadBenchmark.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.Soak.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.DriverGuidance.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.DriverGuidanceView.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.PrerequisiteDiagnostics.ps1')

function Get-FastLlmRequiredProperty {
    param(
        [Parameter(Mandatory = $true)]
        $Object,

        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [string] $Label
    )

    $property = $Object.PSObject.Properties[$Name]
    if (-not $property -or $null -eq $property.Value) {
        throw "$Label is missing required property '$Name'."
    }
    return $property.Value
}

function Assert-FastLlmLeafName {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Value,

        [Parameter(Mandatory = $true)]
        [string] $Label
    )

    if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]{0,199}$' -or
        $Value -eq '.' -or $Value -eq '..' -or
        [System.IO.Path]::IsPathRooted($Value) -or
        [System.IO.Path]::GetFileName($Value) -ne $Value) {
        throw "$Label must be a simple leaf name using only letters, digits, dot, underscore, plus, or hyphen."
    }
}

function Assert-FastLlmHttpsUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Value,

        [Parameter(Mandatory = $true)]
        [string] $Label
    )

    try {
        $uri = New-Object System.Uri($Value)
    }
    catch {
        throw "$Label is not a valid absolute URL."
    }
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https') {
        throw "$Label must use HTTPS."
    }
}

function Join-FastLlmContainedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root,

        [Parameter(Mandatory = $true)]
        [string] $Child,

        [string] $Label = 'Derived path'
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root)
    $combinedFull = [System.IO.Path]::GetFullPath((Join-Path $rootFull $Child))
    $trimChars = [char[]] @([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $rootPrefix = $rootFull.TrimEnd($trimChars) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $combinedFull.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label escapes its expected root."
    }
    return $combinedFull
}

function Read-FastLlmJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        # Optional hard cap in bytes (0 = unbounded, the historical behaviour). Checked on the OPENED handle, so a name
        # swapped after any earlier check cannot defeat it; at most MaxBytes+1 bytes are ever read. A larger file throws a
        # typed System.IO.InvalidDataException (Data['FastLlmJsonTooLarge'] = $true) that callers must not retry.
        [ValidateRange(0, 1073741824)]
        [int] $MaxBytes = 0
    )

    # Open with FileShare.Delete so a concurrent atomic replace of this file is never blocked by the reader.
    # ReplaceFile can briefly hide the destination name from openers, so a missing name is re-checked for <= ~150 ms.
    $stream = $null
    for ($attempt = 0; -not $stream; $attempt++) {
        $last = ($attempt -ge 9)
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            if ($last) { throw "JSON file was not found: $Path" }
            Start-Sleep -Milliseconds 15
            continue
        }
        try {
            $stream = New-Object IO.FileStream($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        } catch {
            $failure = $_.Exception
            if ($failure -is [Management.Automation.MethodInvocationException] -and $failure.InnerException) { $failure = $failure.InnerException }
            if ($failure -is [IO.FileNotFoundException] -and $last) { throw "JSON file was not found: $Path" }
            if ($last -or -not ($failure -is [IO.IOException] -or $failure -is [UnauthorizedAccessException]) -or $failure -is [IO.DirectoryNotFoundException]) { throw }
            Start-Sleep -Milliseconds 15
        }
    }
    try {
        $source = $stream
        $buffered = $null
        if ($MaxBytes -gt 0) {
            $tooLarge = { $failure = New-Object IO.InvalidDataException(('JSON file exceeds its size limit of {0} bytes: {1}' -f $MaxBytes,[IO.Path]::GetFileName($Path))); $failure.Data['FastLlmJsonTooLarge'] = $true; throw $failure }
            if ($stream.Length -gt $MaxBytes) { & $tooLarge }
            $buffer = New-Object byte[] ($MaxBytes + 1)
            $total = 0
            while ($total -le $MaxBytes) {
                $read = $stream.Read($buffer,$total,($MaxBytes + 1 - $total))
                if ($read -le 0) { break }
                $total += $read
            }
            if ($total -gt $MaxBytes) { & $tooLarge }
            $buffered = New-Object IO.MemoryStream($buffer,0,$total)
            $source = $buffered
        }
        try {
            $reader = New-Object IO.StreamReader($source,(New-Object Text.UTF8Encoding($false)),$true)
            try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
        } finally { if ($buffered) { $buffered.Dispose() } }
    } finally { $stream.Dispose() }
    return ($text | ConvertFrom-Json)
}

function Get-FastLlmCatalog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $CatalogPath
    )

    $catalog = Read-FastLlmJson -Path $CatalogPath
    if ([int] (Get-FastLlmRequiredProperty -Object $catalog -Name 'schemaVersion' -Label 'Catalog') -ne 1) {
        throw "Unsupported catalog schema version '$($catalog.schemaVersion)'."
    }
    if (-not $catalog.models -or @($catalog.models).Count -eq 0) {
        throw 'The model catalog has no model entries.'
    }

    $engine = Get-FastLlmRequiredProperty -Object $catalog -Name 'engine' -Label 'Catalog'
    $engineVersion = [string] (Get-FastLlmRequiredProperty -Object $engine -Name 'version' -Label 'Engine')
    Assert-FastLlmLeafName -Value $engineVersion -Label 'Engine version'
    $assets = Get-FastLlmRequiredProperty -Object $engine -Name 'assets' -Label 'Engine'
    foreach ($backendKey in @('rocm', 'vulkan')) {
        $assetProperty = $assets.PSObject.Properties[$backendKey]
        if (-not $assetProperty) {
            throw "Engine assets are missing '$backendKey'."
        }
        $asset = $assetProperty.Value
        $assetFile = [string] (Get-FastLlmRequiredProperty -Object $asset -Name 'file' -Label "$backendKey asset")
        $entryPoint = [string] (Get-FastLlmRequiredProperty -Object $asset -Name 'entryPoint' -Label "$backendKey asset")
        $assetUrl = [string] (Get-FastLlmRequiredProperty -Object $asset -Name 'url' -Label "$backendKey asset")
        $assetSha = [string] (Get-FastLlmRequiredProperty -Object $asset -Name 'sha256' -Label "$backendKey asset")
        Assert-FastLlmLeafName -Value $assetFile -Label "$backendKey asset file"
        Assert-FastLlmLeafName -Value $entryPoint -Label "$backendKey entry point"
        Assert-FastLlmHttpsUrl -Value $assetUrl -Label "$backendKey asset URL"
        if ($assetSha -notmatch '^[0-9a-fA-F]{64}$') {
            throw "$backendKey asset SHA-256 is invalid."
        }
        if ([int64] (Get-FastLlmRequiredProperty -Object $asset -Name 'sizeBytes' -Label "$backendKey asset") -le 0) {
            throw "$backendKey asset size must be positive."
        }
        $enabledProperty = $asset.PSObject.Properties['enabled']
        if ($enabledProperty -and [bool] $enabledProperty.Value) {
            $manifest = @(Get-FastLlmRequiredProperty -Object $asset -Name 'manifest' -Label "$backendKey enabled asset")
            if ($manifest.Count -eq 0) {
                throw "$backendKey enabled asset must have an extracted-file manifest."
            }
            $manifestNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
            $manifestTotal = [int64] 0
            foreach ($entry in $manifest) {
                $entryPath = [string] (Get-FastLlmRequiredProperty -Object $entry -Name 'path' -Label "$backendKey manifest entry")
                $entrySha = [string] (Get-FastLlmRequiredProperty -Object $entry -Name 'sha256' -Label "$backendKey manifest entry '$entryPath'")
                $entrySize = [int64] (Get-FastLlmRequiredProperty -Object $entry -Name 'sizeBytes' -Label "$backendKey manifest entry '$entryPath'")
                Assert-FastLlmLeafName -Value $entryPath -Label "$backendKey manifest path"
                if (-not $manifestNames.Add($entryPath)) {
                    throw "$backendKey manifest contains duplicate path '$entryPath'."
                }
                if ($entrySha -notmatch '^[0-9a-fA-F]{64}$' -or $entrySize -lt 0) {
                    throw "$backendKey manifest entry '$entryPath' has invalid integrity metadata."
                }
                $manifestTotal += $entrySize
            }
            if (-not $manifestNames.Contains($entryPoint)) {
                throw "$backendKey manifest does not contain entry point '$entryPoint'."
            }
            $expandedSize = [int64] (Get-FastLlmRequiredProperty -Object $asset -Name 'expandedSizeBytes' -Label "$backendKey enabled asset")
            if ($manifestTotal -ne $expandedSize) {
                throw "$backendKey manifest sizes total $manifestTotal bytes, not declared expanded size $expandedSize."
            }
        }
        elseif (-not $asset.PSObject.Properties['disabledReason']) {
            throw "$backendKey disabled asset must explain why it is disabled."
        }
    }

    $policy = Get-FastLlmRequiredProperty -Object $catalog -Name 'hardwarePolicy' -Label 'Catalog'
    if ([string] (Get-FastLlmRequiredProperty -Object $policy -Name 'serverHost' -Label 'Hardware policy') -ne '127.0.0.1') {
        throw 'This alpha permits only the exact loopback host 127.0.0.1.'
    }
    $serverPort = [int] (Get-FastLlmRequiredProperty -Object $policy -Name 'serverPort' -Label 'Hardware policy')
    if ($serverPort -lt 1 -or $serverPort -gt 65535) {
        throw 'Hardware policy serverPort must be between 1 and 65535.'
    }

    $modelIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $modelFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($model in @($catalog.models)) {
        $modelId = [string] (Get-FastLlmRequiredProperty -Object $model -Name 'id' -Label 'Model')
        $modelFile = [string] (Get-FastLlmRequiredProperty -Object $model -Name 'file' -Label "Model '$modelId'")
        $modelUrl = [string] (Get-FastLlmRequiredProperty -Object $model -Name 'url' -Label "Model '$modelId'")
        $modelSha = [string] (Get-FastLlmRequiredProperty -Object $model -Name 'sha256' -Label "Model '$modelId'")
        Assert-FastLlmLeafName -Value $modelId -Label 'Model id'
        Assert-FastLlmLeafName -Value $modelFile -Label "Model '$modelId' file"
        Assert-FastLlmHttpsUrl -Value $modelUrl -Label "Model '$modelId' URL"
        if (-not $modelIds.Add($modelId) -or -not $modelFiles.Add($modelFile)) {
            throw "Model ids and files must be unique; duplicate found at '$modelId'."
        }
        if ($modelSha -notmatch '^[0-9a-fA-F]{64}$' -or
            [int64] (Get-FastLlmRequiredProperty -Object $model -Name 'sizeBytes' -Label "Model '$modelId'") -le 0 -or
            [int64] (Get-FastLlmRequiredProperty -Object $model -Name 'requiredFreeVramMiB' -Label "Model '$modelId'") -le 0 -or
            [int] (Get-FastLlmRequiredProperty -Object $model -Name 'contextSize' -Label "Model '$modelId'") -le 0) {
            throw "Model '$modelId' has invalid size, hash, memory, or context metadata."
        }
        foreach ($requiredField in @('upstreamRevision', 'upstreamLicense', 'upstreamLicenseUrl', 'upstreamLicenseSha256', 'artifactLicense', 'servingMode')) {
            Get-FastLlmRequiredProperty -Object $model -Name $requiredField -Label "Model '$modelId'" | Out-Null
        }
        if ([string] $model.upstreamRevision -notmatch '^[0-9a-fA-F]{40}$' -or
            [string] $model.revision -notmatch '^[0-9a-fA-F]{40}$' -or
            [string] $model.upstreamLicenseSha256 -notmatch '^[0-9a-fA-F]{64}$') {
            throw "Model '$modelId' has invalid immutable provenance metadata."
        }
        Assert-FastLlmHttpsUrl -Value ([string] $model.upstreamLicenseUrl) -Label "Model '$modelId' upstream license URL"
    }
    return $catalog
}

function ConvertFrom-LlamaDeviceList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Text,

        [Parameter(Mandatory = $true)]
        [ValidateSet('ROCm', 'Vulkan')]
        [string] $Backend
    )

    $adapters = @()
    $pattern = '^\s*(?<device>[A-Za-z]+\d+):\s+(?<name>.+)\s+\((?<total>\d+)\s+MiB,\s*(?<free>\d+)\s+MiB\s+free\)\s*$'
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -notmatch $pattern) {
            continue
        }

        $device = [string] $Matches.device
        $name = $Matches.name.Trim()
        $totalMiB = [int64] $Matches.total
        $freeMiB = [int64] $Matches.free
        $isAmd = [bool] ($name -match '(?i)\bAMD\b|Radeon')
        $isIntegrated = [bool] (Test-FastLlmIntegratedName -Name $name)
        $vendorId = $null
        if ($isAmd) {
            $vendorId = '1002'
        }
        $adapters += [pscustomobject] [ordered] @{
            device        = $device
            name          = $name
            vendorId      = $vendorId
            vramMiB       = $totalMiB
            freeVramMiB   = $freeMiB
            driverVersion = $null
            backend       = $Backend
            isAmd         = $isAmd
            isIntegrated  = $isIntegrated
        }
    }

    return @($adapters)
}

function Test-FastLlmHipSupportedName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        $Catalog
    )

    $normalizedName = $Name.Trim()
    if ($normalizedName.StartsWith('AMD ', [System.StringComparison]::OrdinalIgnoreCase)) {
        $normalizedName = $normalizedName.Substring(4).Trim()
    }
    foreach ($pattern in @($Catalog.hardwarePolicy.hipSupportedNamePatterns)) {
        $normalizedPattern = ([string] $pattern).Trim()
        if ($normalizedPattern.StartsWith('AMD ', [System.StringComparison]::OrdinalIgnoreCase)) {
            $normalizedPattern = $normalizedPattern.Substring(4).Trim()
        }
        if ($normalizedName.Equals($normalizedPattern, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Test-FastLlmIntegratedName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    return [bool] ($Name -match '(?i)\bRadeon(?:\(TM\))?\s+(?:(?:RX\s+)?Vega\s+\d{1,2}\s+|(?:\d{3,4}[A-Za-z]{0,2})\s+)?Graphics\b')
}

function Get-FastLlmWindowsPrerequisiteStatus {
    [CmdletBinding()]
    param()

    $vcRuntimeFiles = @('MSVCP140.dll', 'VCRUNTIME140.dll', 'VCRUNTIME140_1.dll')
    if ($env:OS -ne 'Windows_NT') {
        return [pscustomobject] [ordered] @{
            applicable            = $false
            ready                 = $true
            is64BitProcess        = [Environment]::Is64BitProcess
            system32              = $null
            vcRuntimeFiles        = $vcRuntimeFiles
            missingVcRuntimeFiles = @()
            vulkanLoader          = $null
            vulkanLoaderPresent   = $false
        }
    }

    $system32 = $null
    if ($env:SystemRoot) {
        $system32 = Join-Path $env:SystemRoot 'System32'
    }
    $missingVcRuntimeFiles = @()
    foreach ($file in $vcRuntimeFiles) {
        if (-not $system32 -or -not (Test-Path -LiteralPath (Join-Path $system32 $file) -PathType Leaf)) {
            $missingVcRuntimeFiles += $file
        }
    }
    $vulkanLoader = if ($system32) { Join-Path $system32 'vulkan-1.dll' } else { $null }
    $vulkanLoaderPresent = [bool] ($vulkanLoader -and (Test-Path -LiteralPath $vulkanLoader -PathType Leaf))
    $is64BitProcess = [Environment]::Is64BitProcess

    return [pscustomobject] [ordered] @{
        applicable            = $true
        ready                 = [bool] ($is64BitProcess -and $missingVcRuntimeFiles.Count -eq 0 -and $vulkanLoaderPresent)
        is64BitProcess        = $is64BitProcess
        system32              = $system32
        vcRuntimeFiles        = $vcRuntimeFiles
        missingVcRuntimeFiles = $missingVcRuntimeFiles
        vulkanLoader          = $vulkanLoader
        vulkanLoaderPresent   = $vulkanLoaderPresent
    }
}

function Assert-FastLlmWindowsPrerequisites {
    [CmdletBinding()]
    param()

    $status = Get-FastLlmWindowsPrerequisiteStatus
    if (-not $status.applicable -or $status.ready) {
        return
    }
    $problems = @()
    if (-not $status.is64BitProcess) {
        $problems += 'run the script from 64-bit Windows PowerShell or PowerShell 7'
    }
    if (@($status.missingVcRuntimeFiles).Count -gt 0) {
        $problems += "install the current Microsoft Visual C++ 2015-2022 Redistributable (x64); missing $(@($status.missingVcRuntimeFiles) -join ', ') (https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist)"
    }
    if (-not $status.vulkanLoaderPresent) {
        $problems += 'install a current AMD Windows graphics driver with Vulkan support; vulkan-1.dll is missing from System32'
    }
    throw "Windows prerequisites are incomplete: $($problems -join '; '). This alpha does not install these machine-wide prerequisites automatically."
}

function New-FastLlmRuntimeSandbox {
    param(
        [Parameter(Mandatory = $true)]
        [string] $InstallRoot
    )

    $sandboxesRoot = Join-FastLlmContainedPath -Root $InstallRoot -Child 'runtime-sandboxes' -Label 'Runtime sandbox root'
    New-Item -ItemType Directory -Path $sandboxesRoot -Force -ErrorAction Stop | Out-Null
    $sandboxesRootItem = Get-Item -LiteralPath $sandboxesRoot -Force -ErrorAction Stop
    if (($sandboxesRootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing reparse-point runtime sandbox root '$sandboxesRoot'."
    }

    $sandboxRoot = Join-FastLlmContainedPath -Root $sandboxesRoot -Child ([Guid]::NewGuid().ToString('N')) -Label 'Runtime sandbox path'
    $appData = Join-FastLlmContainedPath -Root $sandboxRoot -Child 'appdata' -Label 'Runtime APPDATA path'
    $programData = Join-FastLlmContainedPath -Root $sandboxRoot -Child 'programdata' -Label 'Runtime PROGRAMDATA path'
    try {
        New-Item -ItemType Directory -Path $appData -Force -ErrorAction Stop | Out-Null
        New-Item -ItemType Directory -Path $programData -Force -ErrorAction Stop | Out-Null
        return [pscustomobject] [ordered] @{
            root        = $sandboxRoot
            appData     = $appData
            programData = $programData
        }
    }
    catch {
        if (Test-Path -LiteralPath $sandboxRoot) {
            Remove-Item -LiteralPath $sandboxRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Remove-FastLlmRuntimeSandbox {
    param($Sandbox)

    if ($Sandbox -and $Sandbox.root -and (Test-Path -LiteralPath ([string] $Sandbox.root))) {
        Remove-Item -LiteralPath ([string] $Sandbox.root) -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-FastLlmEnvironmentNameRequiresClearing {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    return [bool] (
        $Name -like 'LLAMA_*' -or
        $Name -like 'GGML_*' -or
        $Name -like 'VK_*' -or
        $Name -like 'HIP_*' -or
        $Name -like 'ROCM_*' -or
        $Name -like 'HSA_*' -or
        $Name -like 'ROCBLAS_*' -or
        $Name -like 'SMITHY_*' -or
        $Name -like 'AIP_*' -or
        $Name -in @('MTMD_BACKEND_DEVICE', 'HF_TOKEN')
    )
}

function ConvertTo-FastLlmProcessArgument {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Value
    )

    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') {
        return $Value
    }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Join-FastLlmProcessArguments {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $Arguments
    )

    return (@($Arguments | ForEach-Object { ConvertTo-FastLlmProcessArgument -Value ([string] $_) }) -join ' ')
}

function Assert-FastLlmHardware {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Hardware
    )

    $backend = [string] (Get-FastLlmRequiredProperty -Object $Hardware -Name 'backend' -Label 'Hardware inventory')
    if ($backend -notin @('ROCm', 'Vulkan')) {
        throw "Hardware inventory backend '$backend' is not ROCm or Vulkan."
    }
    $adapters = @(Get-FastLlmRequiredProperty -Object $Hardware -Name 'adapters' -Label 'Hardware inventory')
    if ($adapters.Count -eq 0) {
        throw 'Hardware inventory has no adapters.'
    }

    $devices = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($adapter in $adapters) {
        $device = [string] (Get-FastLlmRequiredProperty -Object $adapter -Name 'device' -Label 'Hardware adapter')
        $name = [string] (Get-FastLlmRequiredProperty -Object $adapter -Name 'name' -Label "Hardware adapter '$device'")
        $total = [int64] (Get-FastLlmRequiredProperty -Object $adapter -Name 'vramMiB' -Label "Hardware adapter '$device'")
        $free = [int64] (Get-FastLlmRequiredProperty -Object $adapter -Name 'freeVramMiB' -Label "Hardware adapter '$device'")
        $adapterBackend = [string] (Get-FastLlmRequiredProperty -Object $adapter -Name 'backend' -Label "Hardware adapter '$device'")
        Get-FastLlmRequiredProperty -Object $adapter -Name 'isAmd' -Label "Hardware adapter '$device'" | Out-Null
        if ([string]::IsNullOrWhiteSpace($device) -or [string]::IsNullOrWhiteSpace($name)) {
            throw 'Hardware adapter device and name must not be empty.'
        }
        if (-not $devices.Add($device)) {
            throw "Hardware inventory contains duplicate device '$device'."
        }
        if ($total -le 0 -or $free -lt 0 -or $free -gt $total) {
            throw "Hardware adapter '$device' has impossible VRAM values (total $total MiB, free $free MiB)."
        }
        if ($adapterBackend -ne $backend) {
            throw "Hardware adapter '$device' backend '$adapterBackend' does not match inventory backend '$backend'."
        }
    }
}

function Get-FastLlmEngineExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $InstallRoot,

        [Parameter(Mandatory = $true)]
        [string] $EngineVersion,

        [Parameter(Mandatory = $true)]
        [ValidateSet('rocm', 'vulkan')]
        [string] $BackendKey,

        [string] $EntryPoint = 'llama-server.exe'
    )

    Assert-FastLlmLeafName -Value $EngineVersion -Label 'Engine version'
    Assert-FastLlmLeafName -Value $EntryPoint -Label 'Engine entry point'
    $enginesRoot = Join-FastLlmContainedPath -Root $InstallRoot -Child 'engines' -Label 'Engines root'
    $versionRoot = Join-FastLlmContainedPath -Root $enginesRoot -Child $EngineVersion -Label 'Engine version path'
    $backendRoot = Join-FastLlmContainedPath -Root $versionRoot -Child $BackendKey -Label 'Engine backend path'
    if (-not (Test-Path -LiteralPath $backendRoot -PathType Container)) {
        return $null
    }

    $serverPath = Join-FastLlmContainedPath -Root $backendRoot -Child $EntryPoint -Label 'Engine executable path'
    if (Test-Path -LiteralPath $serverPath -PathType Leaf) {
        return $serverPath
    }
    return $null
}

function Test-FastLlmEngineInstallation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $InstallRoot,

        [Parameter(Mandatory = $true)]
        [string] $EngineVersion,

        [Parameter(Mandatory = $true)]
        [ValidateSet('rocm', 'vulkan')]
        [string] $BackendKey,

        [Parameter(Mandatory = $true)]
        $Asset
    )

    if (-not [bool] $Asset.enabled) {
        return $false
    }
    $serverPath = Get-FastLlmEngineExecutable -InstallRoot $InstallRoot -EngineVersion $EngineVersion -BackendKey $BackendKey -EntryPoint ([string] $Asset.entryPoint)
    if (-not $serverPath) {
        return $false
    }

    $backendRoot = Split-Path -Parent $serverPath
    return Test-FastLlmManifestDirectory -Root $backendRoot -Asset $Asset
}

function Test-FastLlmManifestDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root,

        [Parameter(Mandatory = $true)]
        $Asset
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return $false
    }
    $rootItem = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        return $false
    }
    $actualFiles = @(Get-ChildItem -LiteralPath $Root -Force -Recurse -ErrorAction Stop)
    $manifest = @($Asset.manifest)
    if ($actualFiles.Count -ne $manifest.Count) {
        return $false
    }
    $manifestNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $manifest) {
        $manifestNames.Add([string] $entry.path) | Out-Null
    }
    foreach ($actualFile in $actualFiles) {
        if ($actualFile.PSIsContainer -or
            ($actualFile.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $actualFile.DirectoryName -ne $rootItem.FullName -or
            -not $manifestNames.Contains([string] $actualFile.Name)) {
            return $false
        }
    }
    foreach ($entry in $manifest) {
        $path = Join-FastLlmContainedPath -Root $Root -Child ([string] $entry.path) -Label 'Engine manifest path'
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            return $false
        }
        $item = Get-Item -LiteralPath $path -ErrorAction Stop
        if ($item.DirectoryName -ne $Root -or $item.Length -ne [int64] $entry.sizeBytes) {
            return $false
        }
        if (-not (Test-FastLlmFileHash -Path $path -Sha256 ([string] $entry.sha256))) {
            return $false
        }
    }
    return $true
}

function Invoke-FastLlmDeviceProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $EnginePath,

        [Parameter(Mandatory = $true)]
        [ValidateSet('ROCm', 'Vulkan')]
        [string] $Backend,

        [Parameter(Mandatory = $true)]
        [string] $InstallRoot,

        [ValidateRange(1, 120)]
        [int] $TimeoutSeconds = 15,

        # The HIP engine component's lane: its runtime directories join the DLL search path (Get-FastLlmEngineEnvironment), and a blocked or
        # missing DLL is a typed failure instead of an empty device list (which would read as "no device").
        [switch] $Hip,

        [string[]] $RuntimeRoots = @(),

        [string] $ComponentId
    )

    if (-not (Test-Path -LiteralPath $EnginePath -PathType Leaf)) {
        return @()
    }

    $sandbox = New-FastLlmRuntimeSandbox -InstallRoot $InstallRoot
    $process = New-Object System.Diagnostics.Process

    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $EnginePath
        $startInfo.Arguments = '--list-devices'
        $startInfo.WorkingDirectory = Split-Path -Parent $EnginePath
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        # The same environment builder as the server launch: the probe cannot see a different PATH than the server will.
        $probeBackend = [string] $Backend
        if ($Hip) { $probeBackend = 'hip' }
        $probePlan = [pscustomobject] [ordered] @{ backend = $probeBackend; enginePath = $EnginePath; runtimeRoots = @($RuntimeRoots) }
        Initialize-FastLlmEngineStartInfo -StartInfo $startInfo -Plan $probePlan -Sandbox $sandbox
        $process.StartInfo = $startInfo

        if (-not $process.Start()) {
            return @()
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try {
                $process.Kill()
                $process.WaitForExit(5000) | Out-Null
            }
            catch {
                # A failed or wedged probe is simply unusable; the caller can try the next backend.
            }
            return @()
        }
        if ($process.ExitCode -ne 0) {
            if ($Hip) {
                $hipProbeFailure = New-FastLlmHipLaunchFailure -ComponentId $ComponentId -ExitCode ([int] $process.ExitCode)
                if ($hipProbeFailure) { throw $hipProbeFailure }
            }
            return @()
        }
        $output = [string] $stdoutTask.GetAwaiter().GetResult()
        $errorOutput = [string] $stderrTask.GetAwaiter().GetResult()
        if ($errorOutput) {
            $output = $output + [Environment]::NewLine + $errorOutput
        }
    }
    catch {
        if ($Hip) {
            if ($_.Exception.Data['FastLlmFailureCode']) { throw }
            $hipStartFailure = New-FastLlmHipLaunchFailure -ComponentId $ComponentId -NativeErrorCode (Get-FastLlmNativeErrorCode -Exception $_.Exception)
            if ($hipStartFailure) { throw $hipStartFailure }
        }
        return @()
    }
    finally {
        $process.Dispose()
        Remove-FastLlmRuntimeSandbox -Sandbox $sandbox
    }

    return @(ConvertFrom-LlamaDeviceList -Text $output -Backend $Backend)
}

function Add-FastLlmDriverVersions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Adapters
    )

    if ($env:OS -ne 'Windows_NT') {
        return @($Adapters)
    }

    try {
        $controllers = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop)
        foreach ($adapter in $Adapters) {
            $match = $controllers |
                Where-Object {
                    $_.Name -and (
                        $adapter.name.IndexOf([string] $_.Name, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                        ([string] $_.Name).IndexOf([string] $adapter.name, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                    )
                } |
                Select-Object -First 1
            if ($match) {
                $adapter.driverVersion = [string] $match.DriverVersion
            }
        }
    }
    catch {
        # The serving-engine probe remains authoritative for device memory.
    }
    return @($Adapters)
}

function Get-FastLlmHardware {
    [CmdletBinding()]
    param(
        [string] $HardwareFile,

        [Parameter(Mandatory = $true)]
        [string] $CatalogPath,

        [Parameter(Mandatory = $true)]
        [string] $InstallRoot
    )

    if ($HardwareFile) {
        $hardware = Read-FastLlmJson -Path $HardwareFile
        Assert-FastLlmHardware -Hardware $hardware
        return $hardware
    }

    if ($env:OS -ne 'Windows_NT') {
        throw 'Live hardware detection is Windows-only. Use -HardwareFile for a dry-run on another operating system.'
    }

    Assert-FastLlmWindowsPrerequisites

    $catalog = Get-FastLlmCatalog -CatalogPath $CatalogPath
    $version = [string] $catalog.engine.version
    $timeoutSeconds = [int] $catalog.hardwarePolicy.deviceProbeTimeoutSeconds
    $rocmAsset = $catalog.engine.assets.rocm
    $vulkanAsset = $catalog.engine.assets.vulkan
    $rocmPath = $null
    $vulkanPath = $null
    if ([bool] $rocmAsset.enabled -and
        (Test-FastLlmEngineInstallation -InstallRoot $InstallRoot -EngineVersion $version -BackendKey 'rocm' -Asset $rocmAsset)) {
        $rocmPath = Get-FastLlmEngineExecutable -InstallRoot $InstallRoot -EngineVersion $version -BackendKey 'rocm' -EntryPoint ([string] $rocmAsset.entryPoint)
    }
    if ([bool] $vulkanAsset.enabled -and
        (Test-FastLlmEngineInstallation -InstallRoot $InstallRoot -EngineVersion $version -BackendKey 'vulkan' -Asset $vulkanAsset)) {
        $vulkanPath = Get-FastLlmEngineExecutable -InstallRoot $InstallRoot -EngineVersion $version -BackendKey 'vulkan' -EntryPoint ([string] $vulkanAsset.entryPoint)
    }

    if (-not $rocmPath -and -not $vulkanPath) {
        throw "No installed llama.cpp engine was found below '$InstallRoot'. Run the install action first."
    }

    $rocmAdapters = @()
    if ($rocmPath) {
        $rocmAdapters = @(
            Invoke-FastLlmDeviceProbe -EnginePath $rocmPath -Backend 'ROCm' -InstallRoot $InstallRoot -TimeoutSeconds $timeoutSeconds |
                Where-Object { $_.isAmd -and -not $_.isIntegrated -and (Test-FastLlmHipSupportedName -Name $_.name -Catalog $catalog) }
        )
    }

    if ($rocmAdapters.Count -gt 0) {
        $selectedAdapters = @(Add-FastLlmDriverVersions -Adapters $rocmAdapters)
        $hardware = [pscustomobject] [ordered] @{
            schemaVersion = 1
            detectedAt    = (Get-Date).ToUniversalTime().ToString('o')
            source        = 'llama.cpp --list-devices'
            backend       = 'ROCm'
            enginePath    = $rocmPath
            adapters      = $selectedAdapters
        }
        Assert-FastLlmHardware -Hardware $hardware
        return $hardware
    }

    if (-not $vulkanPath) {
        throw 'The ROCm probe was not usable and the Vulkan fallback is not installed.'
    }
    $vulkanAdapters = @(
        Invoke-FastLlmDeviceProbe -EnginePath $vulkanPath -Backend 'Vulkan' -InstallRoot $InstallRoot -TimeoutSeconds $timeoutSeconds |
            Where-Object { $_.isAmd -and -not $_.isIntegrated }
    )
    if ($vulkanAdapters.Count -eq 0) {
        throw 'Neither the ROCm nor Vulkan engine found an AMD GPU.'
    }
    $vulkanAdapters = @(Add-FastLlmDriverVersions -Adapters $vulkanAdapters)
    $hardware = [pscustomobject] [ordered] @{
        schemaVersion = 1
        detectedAt    = (Get-Date).ToUniversalTime().ToString('o')
        source        = 'llama.cpp --list-devices'
        backend       = 'Vulkan'
        enginePath    = $vulkanPath
        adapters      = $vulkanAdapters
    }
    $hardware | Add-Member -NotePropertyName dxgiAdapters -NotePropertyValue @(Get-FastLlmDxgiCardIdentities)
    Assert-FastLlmHardware -Hardware $hardware
    return $hardware
}

function Get-FastLlmFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Hardware
    )

    $parts = @([string] $Hardware.backend)
    foreach ($adapter in @($Hardware.adapters | Sort-Object -Property device)) {
        $driverProperty = $adapter.PSObject.Properties['driverVersion']
        $driverVersion = if ($driverProperty) { $driverProperty.Value } else { $null }
        $identityProperty = $adapter.PSObject.Properties['stableId']
        $identity = if ($identityProperty -and $identityProperty.Value) { [string] $identityProperty.Value } else { [string] $adapter.device }
        $parts += ('{0}|{1}|{2}|{3}' -f $identity, $adapter.name, $adapter.vramMiB, $driverVersion)
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($parts -join ';'))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
        return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally {
        $sha.Dispose()
    }
}

function Get-FastLlmScore {
    param(
        [Parameter(Mandatory = $true)]
        $Model,

        [Parameter(Mandatory = $true)]
        [ValidateSet('fast', 'balanced', 'quality')]
        [string] $Profile
    )

    $property = $Model.scores.PSObject.Properties[$Profile]
    if (-not $property) {
        return -1
    }
    return [int] $property.Value
}

function Get-FastLlmPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Hardware,

        [Parameter(Mandatory = $true)]
        [string] $CatalogPath,

        [ValidateSet('fast', 'balanced', 'quality')]
        [string] $Profile = 'balanced',

        [string] $InstallRoot,

        [string] $ModelId,

        [ValidateRange(0, 1048576)]
        [int] $ContextSize = 0,

        [switch] $AllowExperimentalModel,

        [string] $RecipesPath,

        [string] $GpuVariantsPath,

        [string] $RecipeId,

        # Set by model recovery: the cached model was not chosen by the user, so the plan is labelled estimated, not "Chosen by you".
        [switch] $Recovered
    )

    if ($ModelId -and $RecipeId) { throw '-Recipe and -ModelId cannot be combined.' }
    $catalog = Get-FastLlmCatalog -CatalogPath $CatalogPath
    Assert-FastLlmHardware -Hardware $Hardware
    if ($ContextSize -gt 0 -and $ContextSize -lt 512) { throw 'Explicit context must be at least 512 tokens, or 0 for the catalog default.' }
    if ($ModelId) {
        $requested = @($catalog.models | Where-Object { $_.id -eq $ModelId })
        if ($requested.Count -ne 1) { throw "Unknown model '$ModelId'. Use the models action to list exact catalog IDs." }
        $autoProperty = $requested[0].PSObject.Properties['autoEligible']
        if ($autoProperty -and -not [bool] $autoProperty.Value -and -not $AllowExperimentalModel) {
            throw "Model '$ModelId' is experimental and requires -AllowExperimentalModel with an explicit model selection."
        }
        if ($ContextSize -gt [int] $requested[0].contextSize) { throw 'Requested context exceeds the catalog ceiling for this model.' }
    }
    elseif ($AllowExperimentalModel) { throw '-AllowExperimentalModel requires an exact -ModelId.' }
    $minimumVram = [int64] $catalog.hardwarePolicy.minimumDedicatedVramMiB
    $allEligible = @(
        $Hardware.adapters |
            Where-Object {
                $integratedProperty = $_.PSObject.Properties['isIntegrated']
                $isIntegrated = ($integratedProperty -and [bool] $integratedProperty.Value) -or (Test-FastLlmIntegratedName -Name ([string] $_.name))
                $_.isAmd -eq $true -and
                    -not $isIntegrated -and
                    [int64] $_.vramMiB -ge $minimumVram
            } |
            Sort-Object -Property @{ Expression = { [int64] $_.freeVramMiB }; Descending = $true }, device
    )

    if ($allEligible.Count -eq 0) {
        throw "No discrete AMD adapter reporting at least $minimumVram MiB of VRAM was detected. This alpha does not deliberately select a CPU plan."
    }

    $maximumCombinedGpus = [int] $catalog.hardwarePolicy.maximumCombinedGpus
    $reserve = [int64] $catalog.hardwarePolicy.perGpuFitReserveMiB
    $placements = @(
      foreach ($single in $allEligible) {
        [pscustomobject] @{
            adapters          = @($single)
            largestCapacity   = [int64] $single.freeVramMiB
            rawCapacity       = [int64] $single.freeVramMiB
            selectionCapacity = [int64] $single.freeVramMiB
        }
      }
    )
    $groups = @(
        $allEligible | Group-Object -Property {
            '{0}|{1}' -f ([string] $_.name).Trim().ToLowerInvariant(), [int64] $_.vramMiB
        }
    )
    foreach ($group in $groups) {
        $members = @(
            $group.Group |
                Sort-Object -Property @{ Expression = { [int64] $_.freeVramMiB }; Descending = $true }, device |
                Select-Object -First $maximumCombinedGpus
        )
        if ($members.Count -lt 2) {
            continue
        }
        $usable = [int64] 0
        foreach ($member in $members) {
            $usable += [Math]::Max(0, ([int64] $member.freeVramMiB - $reserve))
        }
        if ($usable -gt 0) {
            $placements += [pscustomobject] @{
                adapters          = $members
                largestCapacity   = [int64] $members[0].freeVramMiB
                rawCapacity       = [int64] (($members | Measure-Object -Property freeVramMiB -Sum).Sum)
                selectionCapacity = $usable
            }
        }
    }

    $recipePick = $null
    $engineComponents = @()
    $recipeSkippedSink = New-Object System.Collections.Generic.List[string]
    # Recipes auto-apply only under the default balanced profile (the UI's fixed profile) or when -Recipe names one; an explicit fast or quality
    # profile keeps the estimated planner exactly as before recipes existed (spec 4.2: the profiles keep working as today).
    if (-not $ModelId -and $Profile -ne 'balanced' -and -not $RecipeId -and $RecipesPath -and $GpuVariantsPath) {
        $recipeSkippedSink.Add("recipes not applied: the $Profile profile uses the estimated planner; the balanced profile or -Recipe uses measured recipes")
    }
    if (-not $ModelId -and ($Profile -eq 'balanced' -or $RecipeId) -and $RecipesPath -and $GpuVariantsPath -and (Test-Path -LiteralPath $GpuVariantsPath)) {
        # Recipe data never fails an automatic plan; only an explicit -Recipe refuses.
        try {
            $dxgi = @()
            if ($Hardware.PSObject.Properties['dxgiAdapters']) { $dxgi = @($Hardware.dxgiAdapters) }
            # The signed component list sits next to the catalog. Without it only the built-in engine id can match a recipe.
            try {
                $componentsFile = Join-Path (Split-Path -Parent $CatalogPath) 'components.json'
                if (Test-Path -LiteralPath $componentsFile -PathType Leaf) { $engineComponents = @(Get-FastLlmComponents -ComponentsPath $componentsFile) }
            }
            catch { $engineComponents = @() }
            $recipePick = Select-FastLlmRecipeForPlacements -Recipes (Read-FastLlmRecipes -Path $RecipesPath) `
                -Variants (Get-FastLlmGpuVariants -Path $GpuVariantsPath) -Placements $placements -DxgiAdapters $dxgi `
                -Catalog $catalog -Profile $Profile -RecipeId $RecipeId -EligibleAdapters $allEligible -Components $engineComponents -SkippedSink $recipeSkippedSink
        }
        catch {
            if ($RecipeId) { throw }
            $recipePick = $null
            $recipeSkippedSink.Add("recipes not applied: recipe selection failed ($($_.Exception.GetType().Name)); the estimated plan is used")
        }
        if ($recipePick -and $ContextSize -gt [int] $recipePick.model.contextSize) {
            if ($RecipeId) { throw 'Requested context exceeds the catalog ceiling for this model.' }
            $recipePick = $null
        }
    }
    if ($RecipeId -and -not $recipePick) { throw "Recipe '$RecipeId' does not apply to this PC. No other recipe was substituted." }
    $recipeSkipped = @($recipeSkippedSink)

    if ($recipePick) {
        $selected = [pscustomobject] @{ model = $recipePick.model; placement = $recipePick.placement; score = 0; gpuCount = @($recipePick.placement.adapters).Count }
    }
    else {
        $fitting = @()
        foreach ($placement in $placements) {
            foreach ($model in @($catalog.models)) {
                if ($ModelId -and [string] $model.id -ne $ModelId) { continue }
                if ($ContextSize -gt [int] $model.contextSize) { continue }
                $autoEligibleProperty = $model.PSObject.Properties['autoEligible']
                if ($autoEligibleProperty -and -not [bool] $autoEligibleProperty.Value -and -not ($ModelId -and $AllowExperimentalModel)) {
                    continue
                }
                $score = if ($ModelId) { 0 } else { Get-FastLlmScore -Model $model -Profile $Profile }
                if ($score -lt 0) {
                    continue
                }
                if ([int64] $model.requiredFreeVramMiB -le [int64] $placement.selectionCapacity) {
                    $fitting += [pscustomobject] @{
                        model     = $model
                        score     = $score
                        gpuCount  = @($placement.adapters).Count
                        placement = $placement
                    }
                }
            }
        }
        $selected = $fitting |
            Sort-Object -Property @{ Expression = { $_.score }; Descending = $true }, @{ Expression = { [int64] $_.model.requiredFreeVramMiB }; Descending = $true }, gpuCount, @{ Expression = { [int64] $_.placement.selectionCapacity }; Descending = $true } |
            Select-Object -First 1
    }

    if (-not $selected) {
        if ($ModelId) { throw "Requested model '$ModelId' does not fit the estimated current free-memory budget. No other model was substituted." }
        $maximumAvailableCapacity = [int64] (($placements | Measure-Object -Property selectionCapacity -Maximum).Maximum)
        throw "No catalog profile fits the currently free AMD VRAM ($maximumAvailableCapacity MiB across a supported placement). Close GPU-heavy applications or select different hardware."
    }

    # Copy before narrowing context: the immutable artifact/provenance remains unchanged.
    $model = $selected.model | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $catalogContext = [int] $model.contextSize
    if ($recipePick) {
        $recipeRuntime = $recipePick.recipe.runtime
        $model.contextSize = [int] $recipeRuntime.contextSize
        foreach ($field in 'parallel', 'cacheTypeK', 'cacheTypeV', 'fitTargetMiB') {
            if ($recipeRuntime.PSObject.Properties[$field] -and $null -ne $recipeRuntime.$field) { $model.$field = $recipeRuntime.$field }
        }
    }
    if ($ContextSize -gt 0) { $model.contextSize = $ContextSize }
    $selectedPlacement = $selected.placement
    $selectedAdapters = @($selectedPlacement.adapters)
    $homogeneous = $selectedAdapters.Count -gt 1
    $largestCapacity = [int64] $selectedPlacement.largestCapacity
    $rawAggregateCapacity = [int64] $selectedPlacement.rawCapacity
    $aggregateCapacity = [int64] $selectedPlacement.selectionCapacity
    $splitMode = 'none'
    $tensorSplit = $null
    if ($homogeneous) {
        $splitMode = 'layer'
        $splitValues = @()
        foreach ($adapter in $selectedAdapters) {
            $value = [Math]::Max(1, ([int64] $adapter.freeVramMiB - $reserve))
            $splitValues += [string] $value
        }
        $tensorSplit = $splitValues -join ','
    }

    $warnings = @(
        'This is an alpha plan: fit, correctness, and actual GPU placement require validation on physical Windows/AMD hardware.',
        'The selected GGUF is a hash-pinned community quantization of an Apache-2.0 Qwen model; it is not a first-party Qwen GGUF.'
    )
    if ($Profile -eq 'fast' -and -not $ModelId) { $warnings += 'Fast is an estimated model preference, not a measured tokens-per-second optimization. Select -ModelId to keep a specific artifact.' }
    if ($ContextSize -gt 0) { $warnings += 'A smaller context keeps the original conservative memory threshold; it is not a newly measured fit claim.' }
    if ($allEligible.Count -gt $selectedAdapters.Count) {
        if ($selectedAdapters.Count -eq 1) {
            $warnings += 'The selected model fits the strongest single adapter, so other adapters remain unused; heterogeneous combining stays disabled.'
        }
        else {
            $warnings += "Only the strongest identical pair is considered; additional eligible adapters are ignored by the dual-GPU alpha policy."
        }
    }
    if ($selectedAdapters.Count -gt 1) {
        $warnings += 'Multi-GPU is experimental on native Windows. Layer split is used for capacity; it does not promise faster token generation.'
        $warnings += 'PCIe lane width, CPU/chipset attachment, atomics, cooling, and PSU capacity must be qualified before publishing performance claims.'
    }
    if ([string] $model.support -match 'experimental') {
        $warnings += "The selected '$($model.quantization)' profile uses an aggressive quantization and is experimental pending quality evaluation."
    }
    if ([string] $Hardware.backend -eq 'Vulkan') {
        $warnings += 'Vulkan is the only enabled alpha engine lane and requires a current AMD Vulkan driver plus the Microsoft VC++ 2015-2022 x64 runtime. Flash Attention remains on auto so unsupported kernels are not forced.'
    }
    if ([string] $Hardware.backend -eq 'ROCm' -and -not [bool] $catalog.engine.assets.rocm.enabled) {
        $warnings += 'This fixture describes a hypothetical ROCm plan, but automatic ROCm execution is disabled until a complete matched runtime is pinned.'
    }

    $modelPath = $null
    if ($InstallRoot) {
        $modelsRoot = Join-FastLlmContainedPath -Root $InstallRoot -Child 'models' -Label 'Models root'
        $modelPath = Join-FastLlmContainedPath -Root $modelsRoot -Child ([string] $model.file) -Label 'Model path'
    }

    # The engine the plan runs. A recipe naming the built-in engine keeps the probed engine path, so its plan is unchanged. A recipe naming a
    # listed engine component runs that component's executable; when it is not installed the plan fails typed, with no fallback to the
    # built-in engine. This sits outside the recipe-selection try, so a missing component can never turn into an estimated plan.
    $planEnginePath = $Hardware.enginePath
    $planEngineVersion = [string] $catalog.engine.version
    $planEngineComponentId = $null
    $planBackend = [string] $Hardware.backend
    $planRuntimeRoots = $null
    # The built-in id is recognised by name alone, so a plan on the built-in engine does no engine resolution at all.
    if ($recipePick -and -not $InstallRoot -and (Get-FastLlmRecipeEngineId -Recipe $recipePick.recipe -Catalog $catalog) -cne (Get-FastLlmBuiltInEngineId -Catalog $catalog)) {
        throw (New-FastLlmEngineFailure -Code 'recipe-engine-needs-install-root' -Message "Recipe '$($recipePick.recipe.id)' runs on an engine component, which cannot be resolved without an install root. The built-in engine is not used instead.")
    }
    if ($recipePick -and $InstallRoot -and (Get-FastLlmRecipeEngineId -Recipe $recipePick.recipe -Catalog $catalog) -cne (Get-FastLlmBuiltInEngineId -Catalog $catalog)) {
        $resolvedEngine = Resolve-FastLlmRecipeEngine -Recipe $recipePick.recipe -Catalog $catalog -Components $engineComponents -InstallRoot $InstallRoot
        if (-not $resolvedEngine.builtIn) {
            if (-not $resolvedEngine.installed) {
                # The first component of the chain that fails, so a missing runtime is named as the runtime.
                $unavailableId = Get-FastLlmFirstUnavailableComponent -Components $engineComponents -EngineId ([string] $resolvedEngine.id) -InstallRoot $InstallRoot -Depth Presence
                if (-not $unavailableId) { $unavailableId = [string] $resolvedEngine.id }
                if ($unavailableId -ceq [string] $resolvedEngine.id) {
                    $unavailableMessage = "The engine component '$($resolvedEngine.id)' is not installed, so recipe '$($recipePick.recipe.id)' cannot start. The built-in engine is not used instead. Install the component first."
                }
                else {
                    $unavailableMessage = "The component '${unavailableId}', which the engine component '$($resolvedEngine.id)' requires, is not installed, so recipe '$($recipePick.recipe.id)' cannot start. The built-in engine is not used instead. Install the component first."
                }
                # FastLlmComponentId stays the engine (the chain root): the install action installs that one id and its whole requires chain.
                # The member that actually failed is named in the message and in FastLlmUnavailableComponentId.
                $unavailableFailure = New-FastLlmEngineFailure -Code 'needs-setup-component-missing' -ComponentId ([string] $resolvedEngine.id) -Message $unavailableMessage
                $unavailableFailure.Data['FastLlmUnavailableComponentId'] = $unavailableId
                throw $unavailableFailure
            }
            $planEnginePath = [string] $resolvedEngine.executable
            $planEngineVersion = [string] $resolvedEngine.version
            $planEngineComponentId = [string] $resolvedEngine.id
            if ([string] $resolvedEngine.backend -ceq 'hip') {
                # The HIP engine names its own devices (ROCm<N>): the selected card is matched by exact name and VRAM, or the plan fails closed.
                $planBackend = 'hip'
                $planRuntimeRoots = @($resolvedEngine.runtimeRoots)
                $hipDevices = @(Invoke-FastLlmDeviceProbe -EnginePath $planEnginePath -Backend 'ROCm' -InstallRoot $InstallRoot `
                        -TimeoutSeconds ([int] $catalog.hardwarePolicy.deviceProbeTimeoutSeconds) -Hip -RuntimeRoots $planRuntimeRoots -ComponentId $planEngineComponentId)
                $selectedAdapters = @(Resolve-FastLlmHipSelectedAdapters -Adapters $selectedAdapters -Devices $hipDevices -ComponentId $planEngineComponentId)
                $warnings = @($warnings | Where-Object { $_ -notlike 'Vulkan is the only enabled alpha engine lane*' })
                $warnings += 'This setup runs on the experimental HIP (ROCm) engine from AMD and llama.cpp components. It is not a Vulkan setup, and FastLLM will not fall back to Vulkan on its own.'
            }
        }
    }

    $deviceNames = @($selectedAdapters | ForEach-Object { [string] $_.device })
    $arguments = @(
        '--model', $modelPath,
        '--offline',
        '--no-mmproj',
        '--spec-type', 'none',
        '--alias', [string] $model.id,
        '--host', [string] $catalog.hardwarePolicy.serverHost,
        '--port', [string] $catalog.hardwarePolicy.serverPort,
        '--cors-origins', 'localhost',
        '--no-cors-credentials',
        '--ctx-size', [string] $model.contextSize,
        '--parallel', [string] $model.parallel,
        '--n-gpu-layers', 'all',
        '--fit', 'on',
        '--fit-target', [string] $model.fitTargetMiB,
        '--device', ($deviceNames -join ','),
        '--split-mode', $splitMode,
        '--flash-attn', 'auto',
        '--cache-type-k', [string] $model.cacheTypeK,
        '--cache-type-v', [string] $model.cacheTypeV,
        '--jinja',
        '--metrics',
        # b10698 maps llama model INFO logs (including offload/buffer evidence)
        # to CLI verbosity 4. Level 5 would also expose repeated --fit probes.
        '--log-verbosity', '4',
        '--no-agent',
        '--no-ui'
    )
    if ($tensorSplit) {
        $arguments += @('--tensor-split', $tensorSplit)
    }

    $planDocument = [pscustomobject] [ordered] @{
        schemaVersion       = 1
        catalogVersion      = [string] $catalog.catalogVersion
        hardwareFingerprint = Get-FastLlmFingerprint -Hardware $Hardware
        fingerprintKind     = 'inventory-key-not-authoritative-pci-identity'
        selectionMode       = if ($ModelId) { 'explicit' } elseif ($recipePick) { 'recipe' } else { 'auto' }
        requestedModelId    = $ModelId
        requestedRecipeId   = $RecipeId
        recovered           = [bool] ($Recovered -and $ModelId)
        requestedContextSize = $ContextSize
        allowExperimentalModel = [bool] $AllowExperimentalModel
        catalogContextSize  = $catalogContext
        performanceQualified = $false
        candidatePlacementCount = $placements.Count
        profile             = $Profile
        backend             = $planBackend
        engineVersion       = $planEngineVersion
        enginePath          = $planEnginePath
        capacity            = [pscustomobject] [ordered] @{
            largestFreeVramMiB   = $largestCapacity
            aggregateFreeVramMiB = $rawAggregateCapacity
            selectionFreeVramMiB = $aggregateCapacity
            homogeneousGpuSet    = $homogeneous
        }
        selectedAdapters    = $selectedAdapters
        model               = $model
        modelPath           = $modelPath
        requestedAllGpuLayers = $true
        placementVerified   = $false
        splitMode           = $splitMode
        tensorSplit         = $tensorSplit
        endpoint            = "http://$($catalog.hardwarePolicy.serverHost):$($catalog.hardwarePolicy.serverPort)/v1"
        serverArguments     = $arguments
        recipe              = (New-FastLlmPlanRecipeBlock -Pick $recipePick -ModelId $ModelId -Skipped $recipeSkipped -Recovered:([bool] ($Recovered -and $ModelId)))
        warnings            = $warnings
    }
    # Present only for an engine component, so a plan on the built-in engine has exactly the fields it always had.
    if ($planEngineComponentId) {
        $planDocument | Add-Member -NotePropertyName engineComponentId -NotePropertyValue $planEngineComponentId
    }
    # Present only on a HIP plan: the absolute DLL directories of the required runtime components, in chain order.
    if ($planBackend -ceq 'hip') {
        $planDocument | Add-Member -NotePropertyName runtimeRoots -NotePropertyValue @($planRuntimeRoots)
    }
    return $planDocument
}

# Counts every SHA-256 computed through Test-FastLlmFileHash (read by tests: the M8 presence checks must never hash).
$script:FastLlmFileHashCalls = 0

function Test-FastLlmFileHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $Sha256
    )

    $script:FastLlmFileHashCalls++
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    return $actual -eq $Sha256.ToLowerInvariant()
}

function Get-FastLlmDownloadProgress {
    param(
        [Parameter(Mandatory = $true)] [int64] $SizeBytes,
        [Parameter(Mandatory = $true)] [int64] $ResumeBytes,
        [Parameter(Mandatory = $true)] [int64] $CurrentBytes,
        [Parameter(Mandatory = $true)] [int64] $PreviousBytes,
        [Parameter(Mandatory = $true)] [double] $ElapsedSeconds
    )

    if ($SizeBytes -le 0 -or $ResumeBytes -lt 0 -or $ResumeBytes -gt $SizeBytes -or
        $CurrentBytes -lt 0 -or $PreviousBytes -lt 0 -or $ElapsedSeconds -lt 0) {
        throw 'Invalid download progress counters.'
    }
    $observed = [Math]::Min([int64] $SizeBytes, [int64] $CurrentBytes)
    $newBytes = [Math]::Max([int64] 0, ([int64] $observed - [int64] $ResumeBytes))
    $rate = if ($ElapsedSeconds -ge 1) { [double] $newBytes / $ElapsedSeconds } else { [double] 0 }
    $stalled = $observed -lt $SizeBytes -and $observed -le $PreviousBytes
    $eta = $null
    # A short sample or a stalled interval is not a useful ETA. Rate covers
    # only bytes transferred by this attempt, never the already-resumed portion.
    if ($ElapsedSeconds -ge 30 -and -not $stalled -and $rate -ge 1024 -and $observed -lt $SizeBytes) {
        $eta = [Math]::Ceiling(([double] ($SizeBytes - $observed)) / $rate)
    }
    return [pscustomobject]@{
        bytes = $observed
        percent = [Math]::Round(([double] $observed * 100.0 / [double] $SizeBytes), 1)
        newBytes = $newBytes
        averageBytesPerSecond = $rate
        etaSeconds = $eta
        stalled = $stalled
        complete = $observed -ge $SizeBytes
    }
}

function Format-FastLlmDownloadProgress {
    param(
        [Parameter(Mandatory = $true)] $Progress,
        [Parameter(Mandatory = $true)] [int64] $SizeBytes
    )

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $message = [string]::Format($culture, 'Download {0:F1}% ({1:F2}/{2:F2} GiB)',
        [double] $Progress.percent, ([double] $Progress.bytes / 1GB), ([double] $SizeBytes / 1GB))
    if ($Progress.complete) { return "$message; transfer complete." }
    if ($Progress.stalled) { return "$message; waiting for data." }
    $message += [string]::Format($culture, '; average {0:F2} MiB/s',
        ([double] $Progress.averageBytesPerSecond / 1MB))
    if ($null -ne $Progress.etaSeconds) {
        $minutes = [Math]::Ceiling(([double] $Progress.etaSeconds) / 60.0)
        if ($minutes -ge 60) {
            $message += [string]::Format($culture, '; estimated {0:F1} h remaining', ($minutes / 60.0))
        }
        else {
            $message += [string]::Format($culture, '; estimated {0:F0} min remaining', $minutes)
        }
    }
    return "$message."
}

# The curl arguments for a verified download. --disable stays the first argument (curl reads a curlrc unless -q/--disable comes first);
# -WriteEffectiveUrl adds --write-out %{url_effective} right after it so the final host can be checked.
function Get-FastLlmCurlArguments {
    param([Parameter(Mandatory = $true)][string] $Url, [Parameter(Mandatory = $true)][string] $Partial, [Parameter(Mandatory = $true)][int64] $SizeBytes, [switch] $WriteEffectiveUrl)
    $arguments = New-Object 'System.Collections.Generic.List[string]'
    $arguments.Add('--disable')
    if ($WriteEffectiveUrl) {
        $arguments.Add('--write-out')
        $arguments.Add('%{url_effective}')
    }
    foreach ($argument in @(
            '--silent',
            '--show-error',
            '--location',
            '--fail',
            '--retry', '3',
            '--connect-timeout', '30',
            '--speed-limit', '1024',
            '--speed-time', '60',
            '--max-filesize', [string] $SizeBytes,
            '--proto', '=https',
            '--proto-redir', '=https',
            '--continue-at', '-',
            '--output', $Partial,
            $Url)) {
        $arguments.Add([string] $argument)
    }
    return $arguments.ToArray()
}

# Checks the final URL curl reported (--write-out %{url_effective}) against the allowed hosts. A mismatch quarantines the
# partial and throws. An empty URL with a clean curl exit is also refused; with a failed exit curl's own error follows.
function Assert-FastLlmDownloadHost {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $EffectiveUrl,

        [Parameter(Mandatory = $true)]
        [string[]] $AllowedHosts,

        [Parameter(Mandatory = $true)]
        [string] $Partial,

        [int] $CurlExitCode = 0
    )

    if ([string]::IsNullOrWhiteSpace($EffectiveUrl) -and $CurlExitCode -ne 0) {
        return
    }
    $finalHost = $null
    $finalIsHttps = $false
    if (-not [string]::IsNullOrWhiteSpace($EffectiveUrl)) {
        try {
            $finalUri = New-Object System.Uri($EffectiveUrl.Trim())
            $finalHost = [string] $finalUri.Host
            $finalIsHttps = $finalUri.Scheme -eq 'https'
        }
        catch {
            $finalHost = $null
        }
    }
    if ($finalHost -and $finalIsHttps) {
        foreach ($allowedHost in $AllowedHosts) {
            if ([string]::Equals($allowedHost, $finalHost, [System.StringComparison]::OrdinalIgnoreCase)) {
                return
            }
        }
    }
    if (Test-Path -LiteralPath $Partial) {
        $badRedirect = "$Partial.corrupt.redirect.$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')).$([Guid]::NewGuid().ToString('N'))"
        Move-Item -LiteralPath $Partial -Destination $badRedirect -ErrorAction Stop
    }
    $reported = if ($finalHost) { $finalHost } else { '(none reported)' }
    throw "Download redirected to an unlisted host: $reported"
}

# The same message as a plain string throw, tagged so a caller can tell a size/SHA-256 mismatch (a replaced upstream file) from a network failure.
function New-FastLlmDownloadMismatchException {
    param([Parameter(Mandatory = $true)][string] $Message)
    $exception = New-Object -TypeName System.InvalidOperationException -ArgumentList $Message
    $exception.Data['FastLlmDownloadMismatch'] = $true
    return $exception
}

function Save-FastLlmVerifiedFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Url,

        [Parameter(Mandatory = $true)]
        [string] $Destination,

        [Parameter(Mandatory = $true)]
        [string] $Sha256,

        [Parameter(Mandatory = $true)]
        [int64] $SizeBytes,

        # Optional. When given, the final (post-redirect) URL host must be in this list or the partial is quarantined.
        [string[]] $AllowedRedirectHosts
    )

    $checkRedirectHosts = $PSBoundParameters.ContainsKey('AllowedRedirectHosts')
    if ($checkRedirectHosts -and @($AllowedRedirectHosts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -eq 0) {
        throw 'Allowed redirect hosts must not be empty.'
    }
    Assert-FastLlmHttpsUrl -Value $Url -Label 'Artifact URL'
    if ($Sha256 -notmatch '^[0-9a-fA-F]{64}$' -or $SizeBytes -le 0) {
        throw 'Artifact integrity metadata is invalid.'
    }
    $parent = Split-Path -Parent $Destination
    if (-not $parent) {
        throw 'Artifact destination must include a parent directory.'
    }
    New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null

    if (Test-FastLlmFileHash -Path $Destination -Sha256 $Sha256) {
        return $Destination
    }

    $lockPath = "$Destination.$($Sha256.Substring(0, 16)).lock"
    try {
        $lockStream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    }
    catch {
        throw "Another acquisition is already using '$Destination'."
    }

    try {
        if (Test-FastLlmFileHash -Path $Destination -Sha256 $Sha256) {
            return $Destination
        }
        if (Test-Path -LiteralPath $Destination) {
            $destinationItem = Get-Item -LiteralPath $Destination -Force -ErrorAction Stop
            if (($destinationItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing reparse-point destination '$Destination'."
            }
            if ($destinationItem.PSIsContainer) {
                throw "Artifact destination '$Destination' is a directory."
            }
            $quarantine = "$Destination.corrupt.$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')).$([Guid]::NewGuid().ToString('N'))"
            Move-Item -LiteralPath $Destination -Destination $quarantine -ErrorAction Stop
        }

        $partial = "$Destination.$($Sha256.Substring(0, 16)).partial"
        $attempt = 0
        while ($attempt -lt 2) {
            $attempt++
            $resuming = $false
            if (Test-Path -LiteralPath $partial) {
                $partialItem = Get-Item -LiteralPath $partial -Force -ErrorAction Stop
                if (($partialItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or $partialItem.PSIsContainer) {
                    throw "Refusing unsafe partial path '$partial'."
                }
                if ($partialItem.Length -eq $SizeBytes) {
                    Write-Host 'Completed partial found. Verifying artifact SHA-256.'
                }
                if ($partialItem.Length -eq $SizeBytes -and (Test-FastLlmFileHash -Path $partial -Sha256 $Sha256)) {
                    Move-Item -LiteralPath $partial -Destination $Destination -ErrorAction Stop
                    if (-not (Test-FastLlmFileHash -Path $Destination -Sha256 $Sha256)) {
                        throw "Artifact changed while it was promoted to '$Destination'."
                    }
                    Write-Host 'Verified artifact ready.'
                    return $Destination
                }
                if ($partialItem.Length -ge $SizeBytes) {
                    $badPartial = "$partial.corrupt.$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')).$([Guid]::NewGuid().ToString('N'))"
                    Move-Item -LiteralPath $partial -Destination $badPartial -ErrorAction Stop
                }
                else {
                    $resuming = $true
                }
            }

            $existingBytes = [int64] 0
            if ($resuming) {
                $existingBytes = (Get-Item -LiteralPath $partial -ErrorAction Stop).Length
            }
            # Windows PowerShell 5.1 chooses the Int32 overload from an untyped
            # zero, which rejects ordinary multi-GB GGUF sizes before download.
            $remainingBytes = [Math]::Max([int64] 0, ([int64] $SizeBytes - [int64] $existingBytes))
            $driveRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($parent))
            if ($driveRoot) {
                $drive = New-Object System.IO.DriveInfo($driveRoot)
                $needed = [int64] ($remainingBytes + [Math]::Ceiling($SizeBytes * 0.05))
                if ($drive.AvailableFreeSpace -lt $needed) {
                    throw "Insufficient free disk space. Need at least $needed additional bytes on '$driveRoot'."
                }
            }

            $curlPath = $null
            if ($env:OS -eq 'Windows_NT' -and $env:SystemRoot) {
                $systemCurl = Join-Path (Join-Path $env:SystemRoot 'System32') 'curl.exe'
                if (Test-Path -LiteralPath $systemCurl -PathType Leaf) {
                    $curlPath = $systemCurl
                }
            }
            elseif ($env:OS -ne 'Windows_NT') {
                $curlCommand = Get-Command 'curl' -CommandType Application -ErrorAction SilentlyContinue
                if ($curlCommand) {
                    $curlPath = $curlCommand.Source
                }
            }
            if ($env:OS -eq 'Windows_NT' -and -not $curlPath) {
                throw 'The trusted Windows System32 curl.exe is required for HTTPS-only verified downloads.'
            }

            if ($curlPath) {
                $verb = if ($resuming) { 'Resuming' } else { 'Starting' }
                Write-Host ([string]::Format([System.Globalization.CultureInfo]::InvariantCulture,
                    '{0} download ({1:F2}/{2:F2} GiB present); verification required. Progress updates every 10 seconds.',
                    $verb, ([double] $existingBytes / 1GB), ([double] $SizeBytes / 1GB)))
                $curlArguments = Get-FastLlmCurlArguments -Url $Url -Partial $partial -SizeBytes $SizeBytes -WriteEffectiveUrl:$checkRedirectHosts
                $curlProcess = New-Object System.Diagnostics.Process
                $curlStarted = $false
                $curlExceededSize = $false
                $effectiveUrl = $null
                $effectiveUrlTask = $null
                try {
                    $curlStartInfo = New-Object System.Diagnostics.ProcessStartInfo
                    $curlStartInfo.FileName = $curlPath
                    $curlStartInfo.Arguments = Join-FastLlmProcessArguments -Arguments $curlArguments
                    $curlStartInfo.WorkingDirectory = $parent
                    $curlStartInfo.UseShellExecute = $false
                    $curlStartInfo.CreateNoWindow = $true
                    if ($checkRedirectHosts) {
                        $curlStartInfo.RedirectStandardOutput = $true
                    }
                    $curlProcess.StartInfo = $curlStartInfo
                    if (-not $curlProcess.Start()) {
                        throw 'curl did not start.'
                    }
                    $curlStarted = $true
                    if ($checkRedirectHosts) {
                        $effectiveUrlTask = $curlProcess.StandardOutput.ReadToEndAsync()
                    }
                    $transferClock = [System.Diagnostics.Stopwatch]::StartNew()
                    $lastProgressSeconds = [double] 0
                    $lastProgressBytes = [int64] $existingBytes
                    while (-not $curlProcess.WaitForExit(250)) {
                        # The response may take time to create its first partial file.
                        # Continue reporting the cadence while waiting for data.
                        $currentProgressBytes = [int64] $existingBytes
                        if (Test-Path -LiteralPath $partial -PathType Leaf) {
                            $livePartial = Get-Item -LiteralPath $partial -Force -ErrorAction Stop
                            $currentProgressBytes = [int64] $livePartial.Length
                            if ($livePartial.Length -gt $SizeBytes) {
                                $curlExceededSize = $true
                                $curlProcess.Kill()
                                $curlProcess.WaitForExit(5000) | Out-Null
                                break
                            }
                        }
                        if ($transferClock.Elapsed.TotalSeconds -ge ($lastProgressSeconds + 10)) {
                            $progress = Get-FastLlmDownloadProgress -SizeBytes $SizeBytes -ResumeBytes $existingBytes -CurrentBytes $currentProgressBytes -PreviousBytes $lastProgressBytes -ElapsedSeconds $transferClock.Elapsed.TotalSeconds
                            Write-Host (Format-FastLlmDownloadProgress -Progress $progress -SizeBytes $SizeBytes)
                            $lastProgressBytes = $currentProgressBytes
                            $lastProgressSeconds = $transferClock.Elapsed.TotalSeconds
                        }
                    }
                    $curlExitCode = $curlProcess.ExitCode
                    if ($checkRedirectHosts -and $effectiveUrlTask.Wait(5000)) {
                        $effectiveUrl = $effectiveUrlTask.Result
                    }
                }
                finally {
                    if ($curlStarted -and -not $curlProcess.HasExited) {
                        try {
                            $curlProcess.Kill()
                            $curlProcess.WaitForExit(5000) | Out-Null
                        }
                        catch {
                            # Best effort on cancellation; the SHA-bound partial is never promoted without verification.
                        }
                    }
                    $curlProcess.Dispose()
                }
                if ($checkRedirectHosts -and -not $curlExceededSize) {
                    Assert-FastLlmDownloadHost -EffectiveUrl $effectiveUrl -AllowedHosts $AllowedRedirectHosts -Partial $partial -CurlExitCode $curlExitCode
                }
                if ($curlExceededSize) {
                    $oversizedPartial = "$partial.corrupt.oversize.$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')).$([Guid]::NewGuid().ToString('N'))"
                    if (Test-Path -LiteralPath $partial) {
                        Move-Item -LiteralPath $partial -Destination $oversizedPartial -ErrorAction Stop
                    }
                    throw (New-FastLlmDownloadMismatchException -Message "Download exceeded the catalog size ceiling of $SizeBytes bytes. The oversized partial was quarantined.")
                }
                if ($curlExitCode -ne 0) {
                    throw "Download failed with curl exit code $curlExitCode. The SHA-bound partial file was retained for resume."
                }
            }
            else {
                if ($checkRedirectHosts) {
                    throw 'Redirect-host checking requires curl, which is not available.'
                }
                if ($resuming) {
                    $oldPartial = "$partial.noresume.$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')).$([Guid]::NewGuid().ToString('N'))"
                    Move-Item -LiteralPath $partial -Destination $oldPartial -ErrorAction Stop
                }
                Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing -ErrorAction Stop
            }

            if (-not (Test-Path -LiteralPath $partial -PathType Leaf)) {
                throw "Download did not produce the expected partial file '$partial'."
            }

            $downloadedSize = (Get-Item -LiteralPath $partial -ErrorAction Stop).Length
            Write-Host 'Transfer complete. Verifying artifact size and SHA-256.'
            $valid = $downloadedSize -eq $SizeBytes -and (Test-FastLlmFileHash -Path $partial -Sha256 $Sha256)
            if ($valid) {
                Move-Item -LiteralPath $partial -Destination $Destination -ErrorAction Stop
                if (-not (Test-FastLlmFileHash -Path $Destination -Sha256 $Sha256)) {
                    throw "Artifact changed while it was promoted to '$Destination'."
                }
                Write-Host 'Verified artifact ready.'
                return $Destination
            }

            $badPartial = "$partial.corrupt.$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')).$([Guid]::NewGuid().ToString('N'))"
            Move-Item -LiteralPath $partial -Destination $badPartial -ErrorAction Stop
            if (-not $resuming -or $attempt -ge 2) {
                throw (New-FastLlmDownloadMismatchException -Message "Downloaded artifact failed exact size/SHA-256 verification for '$Destination'. The bad partial was quarantined.")
            }
        }
    }
    finally {
        $lockStream.Dispose()
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }
}

function Assert-FastLlmFreeSpace {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [int64] $RequiredBytes
    )

    $driveRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Path))
    if (-not $driveRoot) {
        return
    }
    $drive = New-Object System.IO.DriveInfo($driveRoot)
    if ($drive.AvailableFreeSpace -lt $RequiredBytes) {
        throw "Insufficient free disk space. Need at least $RequiredBytes bytes on '$driveRoot'."
    }
}

function Test-FastLlmEngineArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ArchivePath,

        [Parameter(Mandatory = $true)]
        $Asset
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $manifest = @($Asset.manifest)
        if ($archive.Entries.Count -ne $manifest.Count -or $archive.Entries.Count -gt 1000) {
            return $false
        }
        $expected = @{}
        foreach ($entry in $manifest) {
            $expected[[string] $entry.path] = $entry
        }
        $expanded = [int64] 0
        foreach ($zipEntry in $archive.Entries) {
            $name = [string] $zipEntry.FullName
            if ($name -ne $zipEntry.Name -or $name.Contains(':') -or -not $expected.ContainsKey($name)) {
                return $false
            }
            if ([int64] $zipEntry.Length -ne [int64] $expected[$name].sizeBytes) {
                return $false
            }
            $expanded += [int64] $zipEntry.Length
        }
        return $expanded -eq [int64] $Asset.expandedSizeBytes
    }
    finally {
        $archive.Dispose()
    }
}

function Install-FastLlmEngines {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $CatalogPath,

        [Parameter(Mandatory = $true)]
        [string] $InstallRoot
    )

    Assert-FastLlmWindowsPrerequisites

    $catalog = Get-FastLlmCatalog -CatalogPath $CatalogPath
    $version = [string] $catalog.engine.version
    foreach ($backendKey in @('rocm', 'vulkan')) {
        $asset = $catalog.engine.assets.$backendKey
        if (-not [bool] $asset.enabled) {
            continue
        }
        if (Test-FastLlmEngineInstallation -InstallRoot $InstallRoot -EngineVersion $version -BackendKey $backendKey -Asset $asset) {
            continue
        }

        $downloadsRoot = Join-FastLlmContainedPath -Root $InstallRoot -Child 'downloads' -Label 'Downloads root'
        $cachePath = Join-FastLlmContainedPath -Root $downloadsRoot -Child ([string] $asset.file) -Label 'Engine download path'
        Save-FastLlmVerifiedFile -Url ([string] $asset.url) -Destination $cachePath -Sha256 ([string] $asset.sha256) -SizeBytes ([int64] $asset.sizeBytes) | Out-Null
        if (-not (Test-FastLlmEngineArchive -ArchivePath $cachePath -Asset $asset)) {
            throw "The verified $backendKey archive does not match its extracted-file manifest."
        }

        $enginesRoot = Join-FastLlmContainedPath -Root $InstallRoot -Child 'engines' -Label 'Engines root'
        $versionRoot = Join-FastLlmContainedPath -Root $enginesRoot -Child $version -Label 'Engine version root'
        $targetRoot = Join-FastLlmContainedPath -Root $versionRoot -Child $backendKey -Label 'Engine backend root'
        $stagingRoot = "$targetRoot.staging.$([Guid]::NewGuid().ToString('N'))"
        $stagingParent = Split-Path -Parent $stagingRoot
        New-Item -ItemType Directory -Path $stagingParent -Force -ErrorAction Stop | Out-Null
        $extractionReserve = [int64] [Math]::Ceiling(([int64] $asset.expandedSizeBytes * 1.10))
        Assert-FastLlmFreeSpace -Path $stagingParent -RequiredBytes $extractionReserve
        try {
            New-Item -ItemType Directory -Path $stagingRoot -Force -ErrorAction Stop | Out-Null
            Expand-Archive -LiteralPath $cachePath -DestinationPath $stagingRoot -Force -ErrorAction Stop
            if (-not (Test-FastLlmManifestDirectory -Root $stagingRoot -Asset $asset)) {
                throw "The extracted $backendKey engine failed its exact file manifest."
            }
            if (Test-Path -LiteralPath $targetRoot) {
                $backup = "$targetRoot.incomplete.$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')).$([Guid]::NewGuid().ToString('N'))"
                Move-Item -LiteralPath $targetRoot -Destination $backup -ErrorAction Stop
            }
            Move-Item -LiteralPath $stagingRoot -Destination $targetRoot -ErrorAction Stop
            if (-not (Test-FastLlmEngineInstallation -InstallRoot $InstallRoot -EngineVersion $version -BackendKey $backendKey -Asset $asset)) {
                throw "The promoted $backendKey engine failed its exact file manifest."
            }
        }
        finally {
            if (Test-Path -LiteralPath $stagingRoot) {
                Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# ---- Community components (C1): verified side-by-side install, inventory and removal ----

# Component ids and versions become folder names. On top of the simple leaf rule: no trailing dot or space (Windows strips them, so 'abc.' and
# 'abc' would be one folder) and no reserved device name (CON, PRN, AUX, NUL, COM1-9, LPT1-9), with or without an extension.
function Assert-FastLlmComponentLeafName {
    param([Parameter(Mandatory = $true)][string] $Value, [Parameter(Mandatory = $true)][string] $Label)
    # Component code only (the global Assert-FastLlmLeafName is unchanged): ASCII-only, case-sensitive, and nothing after the last character
    # (no trailing line feed, no U+212A Kelvin sign standing in for K).
    if ($Value -cnotmatch '^[A-Za-z0-9._+-]+\z') {
        throw "$Label must use only ASCII letters, digits, dot, underscore, plus, or hyphen."
    }
    if ($Value.EndsWith('.') -or $Value.EndsWith(' ')) {
        throw "$Label must not end with a dot or a space."
    }
    if ($Value -imatch '^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?\z') {
        throw "$Label must not be a reserved Windows device name."
    }
}

# Paths inside a zip-tree component (manifest paths and the archive-side extractPrefix) are relative, forward-slash and nested. Every segment passes the
# component leaf rules above. The one extension of the simple leaf rule, scoped to these path segments only: a segment may begin with a single dot or
# underscore (".kpack", "_rocm_sdk_libraries"); "." and ".." never match.
function Assert-FastLlmComponentTreePath {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Value, [Parameter(Mandatory = $true)][string] $Label)
    if ([string]::IsNullOrEmpty($Value)) {
        throw "$Label must not be empty."
    }
    foreach ($segment in $Value.Split('/')) {
        if ($segment -cnotmatch '^[._]?[A-Za-z0-9][A-Za-z0-9._+-]{0,199}\z') {
            throw "$Label '$Value' has a segment that is not a simple name (no empty segment, '..', ':', backslash or other special character)."
        }
        Assert-FastLlmComponentLeafName -Value $segment -Label "$Label segment '$segment'"
    }
}

# The component's download parts as one list, whatever the schema shape: a single legacy 'source' is a one-element list. Each entry is
# { url, allowedRedirectHosts, sha256, sizeBytes, format, extractPrefix (zip-tree only, else $null), fileManifest[] }.
function Get-FastLlmComponentSources {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Component)

    $raw = New-Object 'System.Collections.Generic.List[object]'
    $label = "Component '$([string] $Component.id)'"
    $sourceProperty = $Component.PSObject.Properties['source']
    $sourcesProperty = $Component.PSObject.Properties['sources']
    $hasSource = $null -ne $sourceProperty -and $null -ne $sourceProperty.Value
    $hasSources = $null -ne $sourcesProperty -and $null -ne $sourcesProperty.Value
    if ($hasSource -eq $hasSources) {
        throw "$label needs exactly one of 'source' or 'sources'."
    }
    if ($hasSource) { $raw.Add($sourceProperty.Value) }
    else { foreach ($part in @($sourcesProperty.Value)) { $raw.Add($part) } }
    if ($raw.Count -eq 0) {
        throw "$label lists no sources."
    }
    $list = New-Object 'System.Collections.Generic.List[object]'
    foreach ($part in $raw) {
        $prefix = $null
        $prefixProperty = $part.PSObject.Properties['extractPrefix']
        if ($null -ne $prefixProperty -and $null -ne $prefixProperty.Value) { $prefix = [string] $prefixProperty.Value }
        $partLabel = "$label source"
        $list.Add([pscustomobject] [ordered] @{
                url                  = [string] (Get-FastLlmRequiredProperty -Object $part -Name 'url' -Label $partLabel)
                allowedRedirectHosts = @(Get-FastLlmRequiredProperty -Object $part -Name 'allowedRedirectHosts' -Label $partLabel)
                sha256               = [string] (Get-FastLlmRequiredProperty -Object $part -Name 'sha256' -Label $partLabel)
                sizeBytes            = [int64] (Get-FastLlmRequiredProperty -Object $part -Name 'sizeBytes' -Label $partLabel)
                format               = [string] (Get-FastLlmRequiredProperty -Object $part -Name 'format' -Label $partLabel)
                extractPrefix        = $prefix
                fileManifest         = @(Get-FastLlmRequiredProperty -Object $part -Name 'fileManifest' -Label $partLabel)
            })
    }
    return $list.ToArray()
}

# The components to install for -Id, in install order: required components first, the named one last. Duplicates appear once. An unknown id,
# a cycle or a chain deeper than 4 is a typed failure.
function Get-FastLlmComponentChain {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Components, [Parameter(Mandatory = $true)][string] $Id)

    $byId = @{}
    foreach ($candidate in @($Components | Where-Object { $_ })) { $byId[([string] $candidate.id).ToLowerInvariant()] = $candidate }
    $ordered = New-Object 'System.Collections.Generic.List[object]'
    $done = New-Object 'System.Collections.Generic.HashSet[string]'
    $visit = $null
    $visit = {
        param([string] $CurrentId, [string[]] $Stack)
        $key = $CurrentId.ToLowerInvariant()
        if ($Stack -contains $key) {
            throw (New-FastLlmEngineFailure -Code 'component-requires-cycle' -ComponentId $CurrentId -Message ("Component requirements form a cycle: " + ((@($Stack) + $key) -join ' -> ') + '.'))
        }
        if (@($Stack).Count + 1 -gt 4) {
            throw (New-FastLlmEngineFailure -Code 'component-requires-too-deep' -ComponentId $CurrentId -Message "Component requirements are nested deeper than 4 levels at '$CurrentId'.")
        }
        if (-not $byId.ContainsKey($key)) {
            throw (New-FastLlmEngineFailure -Code 'component-requires-unknown' -ComponentId $CurrentId -Message "Component '$CurrentId' is not in the signed components list.")
        }
        # No early return for a finished node: its requires are walked again so the depth limit applies to the longest path, not the first one found.
        $node = $byId[$key]
        $requiresProperty = $node.PSObject.Properties['requires']
        if ($null -ne $requiresProperty -and $null -ne $requiresProperty.Value) {
            foreach ($requiredId in @($requiresProperty.Value)) {
                & $visit ([string] $requiredId) (@($Stack) + $key)
            }
        }
        if ($done.Add($key)) { $ordered.Add($node) }
    }
    & $visit $Id @()
    return $ordered.ToArray()
}

function Get-FastLlmComponents {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ComponentsPath
    )

    $document = Read-FastLlmJson -Path $ComponentsPath -MaxBytes 4194304
    $schema = [string] (Get-FastLlmRequiredProperty -Object $document -Name 'schema' -Label 'Components file')
    if ($schema -cne 'bitworks.fastllm-components/v1') {
        throw "Components file schema '$schema' is not supported."
    }
    $seenIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $entries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in @($document.components)) {
        $itemId = [string] (Get-FastLlmRequiredProperty -Object $item -Name 'id' -Label 'Component')
        Assert-FastLlmComponentLeafName -Value $itemId -Label 'Component id'
        Assert-FastLlmLeafName -Value $itemId -Label 'Component id'
        if (-not $seenIds.Add($itemId)) {
            throw "Components file lists '$itemId' more than once."
        }
        $label = "Component '$itemId'"
        $itemKind = [string] (Get-FastLlmRequiredProperty -Object $item -Name 'kind' -Label $label)
        if ($itemKind -cnotin @('engine', 'runtime', 'model', 'draft')) {
            throw "$label has an unsupported kind '$itemKind'."
        }
        $itemVersion = [string] (Get-FastLlmRequiredProperty -Object $item -Name 'version' -Label $label)
        Assert-FastLlmComponentLeafName -Value $itemVersion -Label "$label version"
        Assert-FastLlmLeafName -Value $itemVersion -Label "$label version"
        $sources = @(Get-FastLlmComponentSources -Component $item)
        $installedPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $installedPathList = New-Object 'System.Collections.Generic.List[string]'
        foreach ($source in $sources) {
            Assert-FastLlmHttpsUrl -Value ([string] (Get-FastLlmRequiredProperty -Object $source -Name 'url' -Label "$label source")) -Label "$label source URL"
            if ([string] (Get-FastLlmRequiredProperty -Object $source -Name 'sha256' -Label "$label source") -notmatch '^[0-9a-fA-F]{64}$') {
                throw "$label source sha256 is invalid."
            }
            if ([int64] (Get-FastLlmRequiredProperty -Object $source -Name 'sizeBytes' -Label "$label source") -le 0) {
                throw "$label source sizeBytes is invalid."
            }
            $sourceFormat = [string] (Get-FastLlmRequiredProperty -Object $source -Name 'format' -Label "$label source")
            $hosts = @(Get-FastLlmRequiredProperty -Object $source -Name 'allowedRedirectHosts' -Label "$label source")
            if ($hosts.Count -eq 0) {
                throw "$label lists no allowed redirect hosts."
            }
            $isTree = $sourceFormat -ceq 'zip-tree'
            if ($isTree) {
                if ($null -eq $source.extractPrefix -or -not ([string] $source.extractPrefix).EndsWith('/')) {
                    throw "$label zip-tree source needs an extractPrefix ending in '/'."
                }
                Assert-FastLlmComponentTreePath -Value ([string] $source.extractPrefix).Substring(0, ([string] $source.extractPrefix).Length - 1) -Label "$label extractPrefix"
            }
            elseif ($null -ne $source.extractPrefix) {
                throw "$label extractPrefix is only for zip-tree sources."
            }
            $manifest = @(Get-FastLlmRequiredProperty -Object $source -Name 'fileManifest' -Label "$label source")
            if ($manifest.Count -eq 0) {
                throw "$label has an empty file manifest."
            }
            foreach ($manifestEntry in $manifest) {
                $manifestPath = [string] (Get-FastLlmRequiredProperty -Object $manifestEntry -Name 'path' -Label "$label manifest entry")
                if ($isTree) {
                    Assert-FastLlmComponentTreePath -Value $manifestPath -Label "$label manifest path"
                }
                else {
                    # The component rule first: it refuses control characters with its own message, before the generic check reaches a .NET Framework
                    # path API that throws "Illegal characters in path" on them (Windows PowerShell 5.1).
                    Assert-FastLlmComponentLeafName -Value $manifestPath -Label "$label manifest path"
                    Assert-FastLlmLeafName -Value $manifestPath -Label "$label manifest path"
                }
                if (-not $installedPaths.Add($manifestPath)) {
                    throw "$label manifest path '$manifestPath' appears more than once (paths are compared case-insensitively, across all sources)."
                }
                $installedPathList.Add($manifestPath)
                if ([int64] (Get-FastLlmRequiredProperty -Object $manifestEntry -Name 'sizeBytes' -Label "$label manifest entry") -lt 0 -or
                    [string] (Get-FastLlmRequiredProperty -Object $manifestEntry -Name 'sha256' -Label "$label manifest entry") -notmatch '^[0-9a-fA-F]{64}$') {
                    throw "$label manifest entry is invalid."
                }
            }
        }
        # A path that is a file in one place and a directory in another (a, a/b) cannot both be installed.
        foreach ($installedPath in $installedPathList) {
            $parentPath = $installedPath
            while ($parentPath.Contains('/')) {
                $parentPath = $parentPath.Substring(0, $parentPath.LastIndexOf('/'))
                if ($installedPaths.Contains($parentPath)) {
                    throw "$label path '$parentPath' is both a file and a directory."
                }
            }
        }
        $pathDirsProperty = $item.PSObject.Properties['runtimePathDirs']
        if ($null -ne $pathDirsProperty -and $null -ne $pathDirsProperty.Value) {
            if ($itemKind -cne 'runtime') {
                throw "$label runtimePathDirs is only for runtime components."
            }
            $pathDirs = @($pathDirsProperty.Value)
            if ($pathDirs.Count -eq 0) {
                throw "$label runtimePathDirs must not be empty."
            }
            foreach ($pathDir in $pathDirs) {
                Assert-FastLlmComponentTreePath -Value ([string] $pathDir) -Label "$label runtimePathDirs entry"
                $dirPrefix = ([string] $pathDir) + '/'
                $hasFiles = $false
                foreach ($installedPath in $installedPathList) {
                    if ($installedPath.StartsWith($dirPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { $hasFiles = $true; break }
                }
                if (-not $hasFiles) {
                    throw "$label runtimePathDirs entry '$pathDir' has no manifest files under it."
                }
            }
        }
        $requiresProperty = $item.PSObject.Properties['requires']
        if ($null -ne $requiresProperty -and $null -ne $requiresProperty.Value) {
            foreach ($requiredId in @($requiresProperty.Value)) {
                if (([string] $requiredId) -ieq $itemId) {
                    throw "$label requires itself."
                }
            }
        }
        $licenseInfo = Get-FastLlmRequiredProperty -Object $item -Name 'license' -Label $label
        $licenseConsent = [string] (Get-FastLlmRequiredProperty -Object $licenseInfo -Name 'consent' -Label "$label license")
        if ($licenseConsent -cnotin @('show', 'accept')) {
            throw "$label license consent must be 'show' or 'accept'."
        }
        $licenseUrlProperty = $licenseInfo.PSObject.Properties['url']
        $hasLicenseUrl = $null -ne $licenseUrlProperty -and $null -ne $licenseUrlProperty.Value
        if ($hasLicenseUrl) {
            if ([string]::IsNullOrWhiteSpace([string] $licenseUrlProperty.Value)) {
                throw "$label license URL must be an https URL."
            }
            Assert-FastLlmHttpsUrl -Value ([string] $licenseUrlProperty.Value) -Label "$label license URL"
        }
        $licenseLinks = @()
        $linksProperty = $licenseInfo.PSObject.Properties['links']
        if ($null -ne $linksProperty -and $null -ne $linksProperty.Value) {
            $licenseLinks = @($linksProperty.Value)
            if ($licenseLinks.Count -eq 0) {
                throw "$label license links must not be empty."
            }
            foreach ($licenseLink in $licenseLinks) {
                if ([string]::IsNullOrWhiteSpace([string] (Get-FastLlmRequiredProperty -Object $licenseLink -Name 'title' -Label "$label license link"))) {
                    throw "$label license link title is empty."
                }
                Assert-FastLlmHttpsUrl -Value ([string] (Get-FastLlmRequiredProperty -Object $licenseLink -Name 'url' -Label "$label license link")) -Label "$label license link URL"
            }
        }
        if (-not $hasLicenseUrl -and $licenseLinks.Count -eq 0) {
            throw "$label license needs a url or links."
        }
        $entries.Add($item)
    }
    # requires: every id is listed, none is cyclic or deeper than 4 (Get-FastLlmComponentChain throws a typed failure).
    $listedComponents = $entries.ToArray()
    foreach ($listedComponent in $listedComponents) {
        Get-FastLlmComponentChain -Components $listedComponents -Id ([string] $listedComponent.id) | Out-Null
    }
    # Emitted one entry at a time: callers collect with @(...). A comma-wrapped return would hand @() a single nested array.
    return $entries.ToArray()
}

function Get-FastLlmComponentRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $InstallRoot,

        [Parameter(Mandatory = $true)]
        $Component
    )

    $componentsRoot = Join-FastLlmContainedPath -Root $InstallRoot -Child 'components' -Label 'Components root'
    $kindName = [string] $Component.kind
    $idName = [string] $Component.id
    $versionName = [string] $Component.version
    Assert-FastLlmLeafName -Value $kindName -Label 'Component kind'
    Assert-FastLlmLeafName -Value $idName -Label 'Component id'
    Assert-FastLlmLeafName -Value $versionName -Label 'Component version'
    $kindRoot = Join-FastLlmContainedPath -Root $componentsRoot -Child $kindName -Label 'Component kind root'
    $idRoot = Join-FastLlmContainedPath -Root $kindRoot -Child $idName -Label 'Component id root'
    return Join-FastLlmContainedPath -Root $idRoot -Child $versionName -Label 'Component version root'
}

function Get-FastLlmComponentManifestAsset {
    param([Parameter(Mandatory = $true)] $Component)

    $manifest = New-Object 'System.Collections.Generic.List[object]'
    foreach ($part in @(Get-FastLlmComponentSources -Component $Component)) {
        foreach ($partEntry in @($part.fileManifest)) { $manifest.Add($partEntry) }
    }
    $manifest = $manifest.ToArray()
    $expanded = [int64] 0
    foreach ($manifestEntry in $manifest) {
        $expanded += [int64] $manifestEntry.sizeBytes
    }
    return [pscustomobject] @{ manifest = $manifest; expandedSizeBytes = $expanded }
}

# The license.url of a component, or $null when its license has only links[].
function Get-FastLlmComponentLicenseUrlOrNull {
    param([Parameter(Mandatory = $true)] $Component)
    $license = $Component.PSObject.Properties['license']
    if ($null -eq $license -or $null -eq $license.Value) { return $null }
    $urlProperty = $license.Value.PSObject.Properties['url']
    if ($null -ne $urlProperty -and -not [string]::IsNullOrWhiteSpace([string] $urlProperty.Value)) { return [string] $urlProperty.Value }
    return $null
}

# The license.links[] entries only, as written (what a receipt records in links[]; never deduplicated).
function Get-FastLlmComponentLicenseLinkEntries {
    param([Parameter(Mandatory = $true)] $Component)
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $license = $Component.PSObject.Properties['license']
    if ($null -eq $license -or $null -eq $license.Value) { return $entries.ToArray() }
    $linksProperty = $license.Value.PSObject.Properties['links']
    if ($null -ne $linksProperty -and $null -ne $linksProperty.Value) {
        foreach ($link in @($linksProperty.Value)) { $entries.Add([pscustomobject] [ordered] @{ title = [string] $link.title; url = [string] $link.url }) }
    }
    return $entries.ToArray()
}

# The license lines to DISPLAY for a component, one per distinct URL (ordinal, trimmed; the first title wins). A links[] entry carries the real title,
# so license.url (titled with the SPDX id) is listed first only when no link has the same URL. A links-only license is valid, so no caller reads the
# license URL property directly. Receipts use the raw helpers above, not this one.
function Get-FastLlmComponentLicenseLinks {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Component)

    $result = New-Object 'System.Collections.Generic.List[object]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $links = @(Get-FastLlmComponentLicenseLinkEntries -Component $Component)
    $licenseUrl = Get-FastLlmComponentLicenseUrlOrNull -Component $Component
    if ($null -ne $licenseUrl) {
        $coveredByLink = $false
        foreach ($link in $links) { if (([string] $link.url).Trim() -ceq $licenseUrl.Trim()) { $coveredByLink = $true } }
        if (-not $coveredByLink) {
            $title = 'License'
            $license = $Component.PSObject.Properties['license'].Value
            $spdxProperty = $license.PSObject.Properties['spdx']
            if ($null -ne $spdxProperty -and -not [string]::IsNullOrWhiteSpace([string] $spdxProperty.Value)) { $title = [string] $spdxProperty.Value }
            $null = $seen.Add($licenseUrl.Trim())
            $result.Add([pscustomobject] [ordered] @{ title = $title; url = $licenseUrl })
        }
    }
    foreach ($link in $links) {
        if ($seen.Add(([string] $link.url).Trim())) { $result.Add($link) }
    }
    return $result.ToArray()
}





# Exact tree equality of an installed component root against its (nested) manifest: no reparse point anywhere (rejected BEFORE it is descended
# into), the same set of relative files (compared case-insensitively, '/' separated, each manifest path found exactly once), no directory that is not
# an ancestor of a manifest file, and every size. Depth 'Full' also checks every SHA-256 (through Test-FastLlmFileHash); 'Presence' never hashes.
# Any enumeration error (an unreadable folder) is a $false, never an exception.
function Test-FastLlmComponentTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Root,
        [Parameter(Mandatory = $true)] $Asset,
        [ValidateSet('Presence', 'Full')] [string] $Depth = 'Full'
    )

    try {
        if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $false }
        $rootItem = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
        if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        $separator = [System.IO.Path]::DirectorySeparatorChar
        $rootFull = $rootItem.FullName.TrimEnd([char[]] @('\', '/'))
        $expected = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::OrdinalIgnoreCase)
        $expectedDirs = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($manifestEntry in @($Asset.manifest)) {
            $manifestPath = [string] $manifestEntry.path
            $expected[$manifestPath] = $manifestEntry
            $parentPath = $manifestPath
            while ($parentPath.Contains('/')) {
                $parentPath = $parentPath.Substring(0, $parentPath.LastIndexOf('/'))
                $null = $expectedDirs.Add($parentPath)
            }
        }
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $toHash = New-Object 'System.Collections.Generic.List[object]'
        $pendingDirectories = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
        $pendingDirectories.Push((New-Object System.IO.DirectoryInfo($rootFull)))
        while ($pendingDirectories.Count -gt 0) {
            $directory = $pendingDirectories.Pop()
            foreach ($item in $directory.EnumerateFileSystemInfos()) {
                if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
                $relative = $item.FullName.Substring($rootFull.Length + 1).Replace($separator, [char] '/')
                if (($item.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                    if (-not $expectedDirs.Contains($relative)) { return $false }
                    $pendingDirectories.Push((New-Object System.IO.DirectoryInfo($item.FullName)))
                    continue
                }
                if (-not $expected.ContainsKey($relative)) { return $false }
                if (-not $seen.Add($relative)) { return $false }
                if ([int64] $item.Length -ne [int64] $expected[$relative].sizeBytes) { return $false }
                $toHash.Add([pscustomobject] @{ path = $item.FullName; sha256 = [string] $expected[$relative].sha256 })
            }
        }
        if ($seen.Count -ne $expected.Count) { return $false }
        if ($Depth -ceq 'Full') {
            foreach ($hashJob in $toHash) {
                if (-not (Test-FastLlmFileHash -Path $hashJob.path -Sha256 $hashJob.sha256)) { return $false }
            }
        }
        return $true
    }
    catch {
        return $false
    }
}

# Presence: the exact set of relative files and their sizes, no hashing. Full (the default): size and SHA-256 per file as well.
function Test-FastLlmComponentInstallation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $InstallRoot,

        [Parameter(Mandatory = $true)]
        $Component,

        [ValidateSet('Presence', 'Full')]
        [string] $Depth = 'Full'
    )

    $root = Get-FastLlmComponentRoot -InstallRoot $InstallRoot -Component $Component
    return [bool] (Test-FastLlmComponentTree -Root $root -Asset (Get-FastLlmComponentManifestAsset -Component $Component) -Depth $Depth)
}

function Get-FastLlmComponentConsentPath {
    param(
        [Parameter(Mandatory = $true)]
        $Component,

        [Parameter(Mandatory = $true)]
        [string] $InstallRoot
    )

    $consentsRoot = Join-FastLlmContainedPath -Root $InstallRoot -Child 'consents' -Label 'Consent root'
    $receiptName = 'component-{0}-{1}.json' -f [string] $Component.id, [string] $Component.version
    Assert-FastLlmLeafName -Value $receiptName -Label 'Component consent receipt name'
    return Join-FastLlmContainedPath -Root $consentsRoot -Child $receiptName -Label 'Component consent receipt path'
}

function Write-FastLlmComponentConsentReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Component,

        [Parameter(Mandatory = $true)]
        [string] $InstallRoot,

        [Parameter(Mandatory = $true)]
        [ValidateSet('interactive', 'explicit-switch')]
        [string] $AcceptanceMode
    )

    $receiptPath = Get-FastLlmComponentConsentPath -Component $Component -InstallRoot $InstallRoot
    $receiptRoot = Split-Path -Parent $receiptPath
    New-Item -ItemType Directory -Path $receiptRoot -Force -ErrorAction Stop | Out-Null
    $receipt = [ordered] @{
        schemaVersion = 1
        id            = [string] $Component.id
        version       = [string] $Component.version
        licenseUrl    = (Get-FastLlmComponentLicenseUrlOrNull -Component $Component)
        links         = @(Get-FastLlmComponentLicenseLinkEntries -Component $Component)
        acceptedAt    = (Get-Date).ToUniversalTime().ToString('o')
        mode          = $AcceptanceMode
    }
    $temporary = "$receiptPath.tmp.$([Guid]::NewGuid().ToString('N'))"
    $written = $false
    try {
        $receipt | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temporary -Encoding UTF8 -NoNewline -ErrorAction Stop
        $written = $true
        Move-FastLlmFileReplacing -Source $temporary -Destination $receiptPath
    }
    finally {
        if (-not $written) { try { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue } } catch { } }
    }
}

function Test-FastLlmComponentConsentReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Component,

        [Parameter(Mandatory = $true)]
        [string] $InstallRoot
    )

    $receiptPath = Get-FastLlmComponentConsentPath -Component $Component -InstallRoot $InstallRoot
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
        return $false
    }
    try {
        $receipt = Read-FastLlmJson -Path $receiptPath -MaxBytes 16384
        # links[] was added in C3: a receipt without it (written before) still matches a component without license links, and no other.
        $receiptLinkUrls = @()
        $receiptLinksProperty = $receipt.PSObject.Properties['links']
        if ($null -ne $receiptLinksProperty -and $null -ne $receiptLinksProperty.Value) { $receiptLinkUrls = @(@($receiptLinksProperty.Value) | ForEach-Object { [string] $_.url }) }
        $componentLinkUrls = @(@(Get-FastLlmComponentLicenseLinkEntries -Component $Component) | ForEach-Object { [string] $_.url })
        return [int] $receipt.schemaVersion -eq 1 -and
            [string] $receipt.id -ceq [string] $Component.id -and
            [string] $receipt.version -ceq [string] $Component.version -and
            [string] $receipt.licenseUrl -ceq [string] (Get-FastLlmComponentLicenseUrlOrNull -Component $Component) -and
            ($receiptLinkUrls -join "`n") -ceq ($componentLinkUrls -join "`n")
    }
    catch {
        return $false
    }
}

function Test-FastLlmSignerSubject {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Subject,

        [Parameter(Mandatory = $true)]
        [string] $Signer
    )

    if ([string]::IsNullOrWhiteSpace($Subject)) {
        return $false
    }
    foreach ($part in ($Subject -split ',\s*(?=[A-Za-z]+=)')) {
        if ($part.Trim().StartsWith('CN=', [System.StringComparison]::OrdinalIgnoreCase)) {
            $commonName = $part.Trim().Substring(3).Trim('"')
            return [string]::Equals($commonName, $Signer, [System.StringComparison]::OrdinalIgnoreCase)
        }
    }
    return $false
}

# True when the process was started with -NonInteractive (or any prefix PowerShell accepts, such as -noni). Every FastLLM child is started this way.
function Test-FastLlmNonInteractiveCommandLine {
    [CmdletBinding()]
    param([string[]] $CommandLineArgs = @([Environment]::GetCommandLineArgs()))
    foreach ($argument in @($CommandLineArgs)) {
        if (([string] $argument) -match '^(?i)[-/]noni') { return $true }
    }
    return $false
}

# True when a person can answer a prompt: not started with -NonInteractive, an interactive session, and input that is not redirected. A child process
# (-NonInteractive, redirected stdin, a service, a scheduled task) is not, and never reaches Read-Host. The parameters are test seams; by default
# they read the real process.
function Test-FastLlmConsoleInteractive {
    [CmdletBinding()]
    param(
        [string[]] $CommandLineArgs = @([Environment]::GetCommandLineArgs()),
        [object] $UserInteractive = $null,
        [object] $InputRedirected = $null
    )
    if (Test-FastLlmNonInteractiveCommandLine -CommandLineArgs $CommandLineArgs) { return $false }
    if ($null -eq $UserInteractive) { $UserInteractive = [Environment]::UserInteractive }
    if (-not [bool] $UserInteractive) { return $false }
    if ($null -eq $InputRedirected) {
        try { $InputRedirected = [Console]::IsInputRedirected } catch { return $false }
    }
    if ([bool] $InputRedirected) { return $false }
    return $true
}

# Test hooks (module scope, not parameters, so a caller of the exported functions cannot reach them):
#   FastLlmConsentPromptHook: answers the one chain question instead of Read-Host (counts as an interactive console, but never overrides -Unattended).
#   FastLlmDirectoryMoveHook / FastLlmDirectoryMoveDelaysMs: the directory move and its retry backoff.
$script:FastLlmConsentPromptHook = $null
$script:FastLlmDirectoryMoveHook = $null
$script:FastLlmDirectoryMoveDelaysMs = @(200, 400, 800, 1600, 2000)

# Windows MAX_PATH: a file path of 259 characters (260 with the terminating NUL) and a directory path of 247 characters (a directory must leave room
# for an 8.3 file name) are the limits without a long-path opt-in, which Windows PowerShell 5.1 and .NET Framework do not have. Checked with plain
# string arithmetic (GetFullPath itself throws on a long path in .NET Framework) for everything the install can create or rename: the final and staging
# roots with the longest file and folder, the download cache path, the downloader's partial and quarantine names (+90) and the member quarantine (+56).
function Assert-FastLlmComponentPathLength {
    param(
        [Parameter(Mandatory = $true)] $Component,
        [Parameter(Mandatory = $true)] [string] $InstallRoot,
        # The real downloader (Save-FastLlmVerifiedFile) adds up to 90 characters to the cache path for its partial and quarantine names; a test seam does not.
        [switch] $DownloaderNames
    )

    $componentId = [string] $Component.id
    try { $base = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd([char[]] @('\', '/')) }
    catch [System.IO.PathTooLongException] {
        throw (New-FastLlmEngineFailure -Code 'component-path-too-long' -ComponentId $componentId -Message "The install folder path is itself too long for Windows (limit 259). Nothing was downloaded. Use a shorter install folder.")
    }
    $kind = [string] $Component.kind
    $version = [string] $Component.version
    $finalRoot = $base.Length + 1 + 'components'.Length + 1 + $kind.Length + 1 + $componentId.Length + 1 + $version.Length
    $stagingRoot = $base.Length + 1 + 'components'.Length + 1 + '.s'.Length + 1 + 8
    $cacheRoot = $base.Length + 1 + 'downloads'.Length + 1 + 'c'.Length
    $longestFile = 0
    $longestDirectory = 0
    foreach ($manifestEntry in @((Get-FastLlmComponentManifestAsset -Component $Component).manifest)) {
        $manifestPath = [string] $manifestEntry.path
        if ($manifestPath.Length -gt $longestFile) { $longestFile = $manifestPath.Length }
        if ($manifestPath.Contains('/')) {
            $directoryLength = $manifestPath.LastIndexOf('/')
            if ($directoryLength -gt $longestDirectory) { $longestDirectory = $directoryLength }
        }
    }
    $fail = {
        param([string] $What, [int] $Length, [int] $Limit)
        throw (New-FastLlmEngineFailure -Code 'component-path-too-long' -ComponentId $componentId -Message "Installing '${componentId}' under '$InstallRoot' would create a $What of $Length characters, over the Windows limit of $Limit. Nothing was downloaded. Use a shorter install folder.")
    }
    foreach ($rootLength in @($finalRoot, $stagingRoot)) {
        if ($rootLength + 1 + $longestFile -gt 259) { & $fail 'file path' ($rootLength + 1 + $longestFile) 259 }
        $directoryTotal = $rootLength
        if ($longestDirectory -gt 0) { $directoryTotal = $rootLength + 1 + $longestDirectory }
        if ($directoryTotal -gt 247) { & $fail 'folder path' $directoryTotal 247 }
    }
    $sources = @(Get-FastLlmComponentSources -Component $Component)
    for ($index = 0; $index -lt $sources.Count; $index++) {
        $leafLength = 16 + [System.IO.Path]::GetExtension([System.IO.Path]::GetFileName(([System.Uri] ([string] $sources[$index].url)).AbsolutePath)).Length
        $cachePath = $cacheRoot + 1 + $leafLength
        if ($cachePath -gt 259) { & $fail 'download path' $cachePath 259 }
        if ($DownloaderNames -and $cachePath + 90 -gt 259) { & $fail 'download quarantine path (the downloader adds up to 90 characters)' ($cachePath + 90) 259 }
    }
    # The member quarantine name is shortened by Get-FastLlmQuarantinePath when the long form would not fit, so it needs no limit of its own.
}

# <Directory>\<Name>.corrupt.<time>.<guid>, or a short <Directory>\<8 hex>.corrupt when that would pass the 259-character Windows path limit, so
# a quarantine move can never fail on path length.
function Get-FastLlmQuarantinePath {
    param([Parameter(Mandatory = $true)] [string] $Directory, [Parameter(Mandatory = $true)] [string] $Name)
    $long = Join-Path $Directory ("$Name.corrupt.$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')).$([Guid]::NewGuid().ToString('N'))")
    if ($long.Length -le 259) { return $long }
    return (Join-Path $Directory ("$([Guid]::NewGuid().ToString('N').Substring(0, 8)).corrupt"))
}

# Copies at most MaxBytes + 1 bytes (through an 80 KB buffer) and returns how many it copied: a result above MaxBytes means the source is larger than
# its pin, and a bad pin can never fill the disk.
function Copy-FastLlmBoundedStream {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [System.IO.Stream] $Source,
        [Parameter(Mandatory = $true)] [System.IO.Stream] $Destination,
        [Parameter(Mandatory = $true)] [int64] $MaxBytes
    )

    $buffer = New-Object byte[] 81920
    [int64] $total = 0
    while ($total -le $MaxBytes) {
        $want = [int] [Math]::Min([int64] $buffer.Length, $MaxBytes + 1 - $total)
        $read = $Source.Read($buffer, 0, $want)
        if ($read -le 0) { break }
        $Destination.Write($buffer, 0, $read)
        $total += $read
    }
    return $total
}

# Streams the manifest members of one verified archive into the staging tree. Only manifest members (extractPrefix + path) are read; every other
# archive member is ignored. Each member goes entry -> Open() -> a bounded buffered copy to a FileStream straight at its final relative path, so no
# entry or archive is ever held in memory. A member that is missing, the wrong size or the wrong SHA-256 is quarantined (the partial is moved out of
# staging) and refused.
function Expand-FastLlmComponentArchivePart {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $ArchivePath,
        [Parameter(Mandatory = $true)] $Source,
        [Parameter(Mandatory = $true)] [string] $StagingRoot,
        [Parameter(Mandatory = $true)] [string] $QuarantineRoot,
        [Parameter(Mandatory = $true)] [string] $ComponentId
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $prefix = ''
    if ($null -ne $Source.extractPrefix) { $prefix = [string] $Source.extractPrefix }
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        foreach ($manifestEntry in @($Source.fileManifest)) {
            $relativePath = [string] $manifestEntry.path
            $pinnedSize = [int64] $manifestEntry.sizeBytes
            $zipEntry = $archive.GetEntry($prefix + $relativePath)
            if ($null -eq $zipEntry) {
                throw (New-FastLlmEngineFailure -Code 'component-archive-member-missing' -ComponentId $ComponentId -Message "The verified archive for '${ComponentId}' has no member '$($prefix + $relativePath)'. Nothing was installed.")
            }
            if ([int64] $zipEntry.Length -ne $pinnedSize) {
                throw (New-FastLlmEngineFailure -Code 'component-archive-member-mismatch' -ComponentId $ComponentId -Message "The archive member '$($prefix + $relativePath)' of '${ComponentId}' is $($zipEntry.Length) bytes, not the pinned $pinnedSize. Nothing was installed.")
            }
            $destination = Join-FastLlmContainedPath -Root $StagingRoot -Child $relativePath -Label 'Component member path'
            $null = [System.IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
            $entryStream = $null
            $fileStream = $null
            [int64] $copied = 0
            try {
                $entryStream = $zipEntry.Open()
                $fileStream = New-Object System.IO.FileStream($destination, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                $copied = Copy-FastLlmBoundedStream -Source $entryStream -Destination $fileStream -MaxBytes $pinnedSize
            }
            finally {
                if ($null -ne $fileStream) { $fileStream.Dispose() }
                if ($null -ne $entryStream) { $entryStream.Dispose() }
            }
            $written = Get-Item -LiteralPath $destination -Force -ErrorAction Stop
            if ($copied -gt $pinnedSize -or $written.Length -ne $pinnedSize -or -not (Test-FastLlmFileHash -Path $destination -Sha256 ([string] $manifestEntry.sha256))) {
                $null = [System.IO.Directory]::CreateDirectory($QuarantineRoot)
                $quarantined = Get-FastLlmQuarantinePath -Directory $QuarantineRoot -Name $written.Name
                Move-Item -LiteralPath $destination -Destination $quarantined -ErrorAction Stop
                throw (New-FastLlmEngineFailure -Code 'component-archive-member-mismatch' -ComponentId $ComponentId -Message "The archive member '$($prefix + $relativePath)' of '${ComponentId}' failed its pinned size and SHA-256. The partial file was quarantined and nothing was installed.")
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

# The cache path of each source part: downloads\c\<first 16 hex of the part's pinned SHA-256><extension of the URL file>. Short on purpose (every character
# counts against the 259-character path limit) and never built from the URL file name; two different parts never share (or quarantine) a file.
function Get-FastLlmComponentCachePaths {
    param([Parameter(Mandatory = $true)] $Component, [Parameter(Mandatory = $true)] [string] $InstallRoot)

    $downloadsRoot = Join-FastLlmContainedPath -Root $InstallRoot -Child 'downloads' -Label 'Downloads root'
    $cacheRoot = Join-FastLlmContainedPath -Root $downloadsRoot -Child 'c' -Label 'Component downloads root'
    $sources = @(Get-FastLlmComponentSources -Component $Component)
    $paths = New-Object 'System.Collections.Generic.List[string]'
    for ($index = 0; $index -lt $sources.Count; $index++) {
        $extension = [System.IO.Path]::GetExtension([System.IO.Path]::GetFileName(([System.Uri] ([string] $sources[$index].url)).AbsolutePath)).ToLowerInvariant()
        $fileName = ([string] $sources[$index].sha256).ToLowerInvariant().Substring(0, 16) + $extension
        Assert-FastLlmLeafName -Value $fileName -Label 'Component download file name'
        $paths.Add((Join-FastLlmContainedPath -Root $cacheRoot -Child $fileName -Label 'Component download path'))
    }
    return [pscustomobject] @{ root = $cacheRoot; paths = $paths.ToArray() }
}

# Walks a folder without following reparse points: false as soon as one is found (checked before it would be descended into) or when anything cannot
# be read.
function Test-FastLlmPlainTree {
    param([Parameter(Mandatory = $true)] [string] $Path)
    try {
        $pending = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
        $top = New-Object System.IO.DirectoryInfo($Path)
        if (($top.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        $pending.Push($top)
        while ($pending.Count -gt 0) {
            foreach ($item in $pending.Pop().EnumerateFileSystemInfos()) {
                if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
                if (($item.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0) { $pending.Push((New-Object System.IO.DirectoryInfo($item.FullName))) }
            }
        }
        return $true
    }
    catch { return $false }
}

# Removes leftovers of an install that was killed (components\.s\<8 hex> older than MaxAgeHours). Reparse points are never followed or removed.
# The caller holds the operation lock.
function Remove-FastLlmStaleComponentStaging {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string] $InstallRoot, [double] $MaxAgeHours = 1)

    $componentsRoot = Join-FastLlmContainedPath -Root $InstallRoot -Child 'components' -Label 'Components root'
    $stagingParent = Join-Path $componentsRoot '.s'
    if (-not (Test-Path -LiteralPath $stagingParent -PathType Container)) { return }
    $parentItem = Get-Item -LiteralPath $stagingParent -Force -ErrorAction Stop
    if (($parentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Write-Warning "Skipping stale-staging cleanup: '$stagingParent' is a reparse point."
        return
    }
    $cutoff = (Get-Date).ToUniversalTime().AddHours(-$MaxAgeHours)
    foreach ($child in @(Get-ChildItem -LiteralPath $stagingParent -Force -ErrorAction SilentlyContinue)) {
        if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Write-Warning "Left '$($child.FullName)' alone: it is a reparse point."
            continue
        }
        if (-not $child.PSIsContainer -or $child.LastWriteTimeUtc -gt $cutoff) { continue }
        if (-not (Test-FastLlmPlainTree -Path $child.FullName)) {
            Write-Warning "Left '$($child.FullName)' alone: it contains a reparse point or cannot be read."
            continue
        }
        Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# One directory move with a bounded retry (a virus scanner can hold a just-written file for a moment): IOException and UnauthorizedAccessException
# are retried after 200, 400, 800, 1600 and 2000 ms; a destination that appeared meanwhile is refused at once.
function Move-FastLlmComponentDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Source,
        [Parameter(Mandatory = $true)] [string] $Destination,
        [Parameter(Mandatory = $true)] [string] $ComponentId
    )

    $delays = @($script:FastLlmDirectoryMoveDelaysMs)
    for ($attempt = 0; ; $attempt++) {
        if (Test-Path -LiteralPath $Destination) {
            throw (New-FastLlmEngineFailure -Code 'component-root-appeared' -ComponentId $ComponentId -Message "Component folder '$Destination' appeared during installation. It was not changed; remove it first.")
        }
        try {
            if ($null -ne $script:FastLlmDirectoryMoveHook) { & $script:FastLlmDirectoryMoveHook $Source $Destination }
            else { [System.IO.Directory]::Move($Source, $Destination) }
            return
        }
        catch [System.IO.IOException], [System.UnauthorizedAccessException] {
            if ($attempt -ge $delays.Count) {
                throw (New-FastLlmEngineFailure -Code 'component-move-failed' -ComponentId $ComponentId -Message "Could not move the verified '$ComponentId' into place after $($attempt + 1) tries: $($_.Exception.Message)")
            }
            Start-Sleep -Milliseconds ([int] $delays[$attempt])
        }
    }
}

# Downloads, verifies and installs ONE component (consent was settled by the caller): every part is downloaded and checked against its pinned size and
# SHA-256, the manifest members are streamed into a short staging folder under components\.s (each member size- and hash-checked), the tree must equal
# the manifest exactly, and one directory move puts it in place. A part that does not match its pin (a replaced upstream file) is a typed
# component-source-mismatch: the partial is quarantined and nothing further is downloaded.
function Install-FastLlmComponentFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Entry,
        [Parameter(Mandatory = $true)] [string] $InstallRoot,
        [Parameter(Mandatory = $true)] [scriptblock] $Downloader
    )

    $componentId = [string] $Entry.id
    $root = Get-FastLlmComponentRoot -InstallRoot $InstallRoot -Component $Entry
    $sources = @(Get-FastLlmComponentSources -Component $Entry)
    $cache = Get-FastLlmComponentCachePaths -Component $Entry -InstallRoot $InstallRoot
    for ($index = 0; $index -lt $sources.Count; $index++) {
        $source = $sources[$index]
        $cachePath = [string] $cache.paths[$index]
        $pinnedSha = ([string] $source.sha256).ToLowerInvariant()
        $pinnedSize = [int64] $source.sizeBytes
        $partText = "part $($index + 1) of $($sources.Count) of '$componentId' ($([string] $source.url))"
        try {
            & $Downloader -Url ([string] $source.url) -Destination $cachePath -Sha256 $pinnedSha -SizeBytes $pinnedSize -AllowedRedirectHosts ([string[]] @($source.allowedRedirectHosts))
        }
        catch {
            if ($_.Exception.Data.Contains('FastLlmDownloadMismatch')) {
                throw (New-FastLlmEngineFailure -Code 'component-source-mismatch' -ComponentId $componentId -Message "The downloaded $partText does not match its pin (expected $pinnedSize bytes, SHA-256 $pinnedSha): $($_.Exception.Message) Nothing further in the chain was downloaded or installed.")
            }
            throw
        }
        $cacheItem = $null
        if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
            $cacheItem = Get-Item -LiteralPath $cachePath -Force -ErrorAction Stop
        }
        if ($null -eq $cacheItem) {
            throw (New-FastLlmEngineFailure -Code 'component-source-mismatch' -ComponentId $componentId -Message "The download of $partText produced no file (expected $pinnedSize bytes, SHA-256 $pinnedSha). Nothing further in the chain was downloaded or installed.")
        }
        if ($cacheItem.Length -ne $pinnedSize -or -not (Test-FastLlmFileHash -Path $cachePath -Sha256 $pinnedSha)) {
            $actualSha = (Get-FileHash -LiteralPath $cachePath -Algorithm SHA256).Hash.ToLowerInvariant()
            $actualSize = [int64] $cacheItem.Length
            $badDownload = Get-FastLlmQuarantinePath -Directory (Split-Path -Parent $cachePath) -Name (Split-Path -Leaf $cachePath)
            Move-Item -LiteralPath $cachePath -Destination $badDownload -ErrorAction Stop
            throw (New-FastLlmEngineFailure -Code 'component-source-mismatch' -ComponentId $componentId -Message "The downloaded $partText failed its pinned size and SHA-256 (expected $pinnedSize bytes, SHA-256 $pinnedSha; got $actualSize bytes, SHA-256 $actualSha). The file was quarantined. Nothing further in the chain was downloaded or installed.")
        }
        if ([string] $source.format -ceq 'zip') {
            # A flat zip holds exactly its manifest and nothing else.
            $partSize = [int64] 0
            foreach ($partEntry in @($source.fileManifest)) { $partSize += [int64] $partEntry.sizeBytes }
            $partAsset = [pscustomobject] @{ manifest = @($source.fileManifest); expandedSizeBytes = $partSize }
            if (-not (Test-FastLlmEngineArchive -ArchivePath $cachePath -Asset $partAsset)) {
                throw "The verified archive for '$componentId' does not match its pinned file list."
            }
        }
    }

    $asset = Get-FastLlmComponentManifestAsset -Component $Entry
    $componentsRoot = Join-FastLlmContainedPath -Root $InstallRoot -Child 'components' -Label 'Components root'
    $stagingParent = Join-Path $componentsRoot '.s'
    $null = New-Item -ItemType Directory -Path $stagingParent -Force -ErrorAction Stop
    # A fresh folder or nothing: New-Item without -Force fails when the name exists, and the name is drawn again.
    $stagingRoot = $null
    for ($stagingTry = 0; $null -eq $stagingRoot; $stagingTry++) {
        $candidate = Join-Path $stagingParent ([Guid]::NewGuid().ToString('N').Substring(0, 8))
        try { $null = New-Item -ItemType Directory -Path $candidate -ErrorAction Stop; $stagingRoot = $candidate }
        catch { if ($stagingTry -ge 4 -or -not (Test-Path -LiteralPath $candidate)) { throw } }
    }
    try {
        Assert-FastLlmFreeSpace -Path $stagingParent -RequiredBytes ([int64] [Math]::Ceiling(([int64] $asset.expandedSizeBytes * 1.10)))
        for ($index = 0; $index -lt $sources.Count; $index++) {
            Expand-FastLlmComponentArchivePart -ArchivePath ([string] $cache.paths[$index]) -Source $sources[$index] -StagingRoot $stagingRoot -QuarantineRoot ([string] $cache.root) -ComponentId $componentId
        }
        # Every member was size- and hash-checked as it was written: the tree checks are exact-set and size checks, so no file is hashed again.
        if (-not (Test-FastLlmComponentTree -Root $stagingRoot -Asset $asset -Depth Presence)) {
            throw "The extracted component '$componentId' failed its exact file manifest."
        }
        if ($Entry.PSObject.Properties['signer'] -and -not [string]::IsNullOrWhiteSpace([string] $Entry.signer)) {
            $entryPointPath = Join-FastLlmContainedPath -Root $stagingRoot -Child ([string] $Entry.entryPoint) -Label 'Component entry point'
            $signature = Get-AuthenticodeSignature -LiteralPath $entryPointPath
            $signerSubject = $null
            if ($signature.SignerCertificate) { $signerSubject = [string] $signature.SignerCertificate.Subject }
            if ([string] $signature.Status -ne 'Valid' -or -not (Test-FastLlmSignerSubject -Subject $signerSubject -Signer ([string] $Entry.signer))) {
                throw "The entry point of '$componentId' does not carry a valid signature from '$($Entry.signer)'."
            }
        }
        $null = [System.IO.Directory]::CreateDirectory((Split-Path -Parent $root))
        Move-FastLlmComponentDirectory -Source $stagingRoot -Destination $root -ComponentId $componentId
        # A same-volume rename of files that were just hashed: the exact-set and size check is enough here; Start hashes again.
        if (-not (Test-FastLlmComponentInstallation -InstallRoot $InstallRoot -Component $Entry -Depth Presence)) {
            throw "The promoted component '$componentId' failed its exact file manifest; remove it first."
        }
    }
    finally {
        if (Test-Path -LiteralPath $stagingRoot) {
            Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ((Test-Path -LiteralPath $stagingParent -PathType Container) -and @(Get-ChildItem -LiteralPath $stagingParent -Force).Count -eq 0) {
            Remove-Item -LiteralPath $stagingParent -Force -ErrorAction SilentlyContinue
        }
    }
}

# The installed components that require ComponentId (a requirer whose root is a reparse point is ignored, with a warning: it cannot be a FastLLM install).
function Get-FastLlmInstalledRequirers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $AllEntries,
        [Parameter(Mandatory = $true)] [string] $InstallRoot,
        [Parameter(Mandatory = $true)] [string] $ComponentId
    )

    $found = New-Object 'System.Collections.Generic.List[string]'
    foreach ($other in $AllEntries) {
        if (([string] $other.id) -ceq $ComponentId) { continue }
        $otherRequires = $other.PSObject.Properties['requires']
        if ($null -eq $otherRequires -or $null -eq $otherRequires.Value) { continue }
        $names = @(@($otherRequires.Value) | ForEach-Object { ([string] $_).ToLowerInvariant() })
        if ($names -notcontains $ComponentId.ToLowerInvariant()) { continue }
        $otherRoot = Get-FastLlmComponentRoot -InstallRoot $InstallRoot -Component $other
        if (-not (Test-Path -LiteralPath $otherRoot)) { continue }
        $otherItem = Get-Item -LiteralPath $otherRoot -Force -ErrorAction SilentlyContinue
        if ($null -eq $otherItem) { continue }
        if (($otherItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Write-Warning "Ignoring '$otherRoot' when checking what requires '$ComponentId': it is a reparse point, not an installed component."
            continue
        }
        if ($otherItem.PSIsContainer) { $found.Add([string] $other.id) }
    }
    return $found.ToArray()
}

function Install-FastLlmComponent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ComponentsPath,

        [Parameter(Mandatory = $true)]
        [string] $ComponentId,

        [Parameter(Mandatory = $true)]
        [string] $InstallRoot,

        [switch] $AcceptLicense,

        [switch] $Unattended,

        # Returns { root; installed = @({ id; version; path }) } (the components this call newly installed, required ones first) instead of the root.
        [switch] $PassThru,

        # Test seam. Called as & $Download -Url -Destination -Sha256 -SizeBytes -AllowedRedirectHosts. Default: Save-FastLlmVerifiedFile.
        [scriptblock] $Download
    )

    $allEntries = @(Get-FastLlmComponents -ComponentsPath $ComponentsPath)
    $entry = $null
    foreach ($candidate in $allEntries) {
        if ([string] $candidate.id -ceq $ComponentId) {
            $entry = $candidate
        }
    }
    if ($null -eq $entry) {
        throw "Component '$ComponentId' is not in the signed components list."
    }
    $chain = @(Get-FastLlmComponentChain -Components $allEntries -Id $ComponentId)

    # Side by side, never in place: an installed root that verifies is skipped; one that does not verify is refused untouched. Checked for the whole
    # chain before anything is shown, written or downloaded.
    $pending = New-Object 'System.Collections.Generic.List[object]'
    foreach ($chainEntry in $chain) {
        $chainFormats = @(@(Get-FastLlmComponentSources -Component $chainEntry) | ForEach-Object { [string] $_.format } | Select-Object -Unique)
        foreach ($chainFormat in $chainFormats) {
            if (@('zip', 'zip-tree') -cnotcontains $chainFormat) {
                throw "Component '$([string] $chainEntry.id)' has format '$($chainFormats -join ', ')', which this release cannot install."
            }
        }
        try { $chainRoot = Get-FastLlmComponentRoot -InstallRoot $InstallRoot -Component $chainEntry }
        catch [System.IO.PathTooLongException] {
            throw (New-FastLlmEngineFailure -Code 'component-path-too-long' -ComponentId ([string] $chainEntry.id) -Message "The install folder path is too long for Windows. Nothing was downloaded. Use a shorter install folder.")
        }
        if (Test-Path -LiteralPath $chainRoot) {
            if (Test-FastLlmComponentInstallation -InstallRoot $InstallRoot -Component $chainEntry) { continue }
            $requirers = @(Get-FastLlmInstalledRequirers -AllEntries $allEntries -InstallRoot $InstallRoot -ComponentId ([string] $chainEntry.id))
            $unverifiedId = [string] $chainEntry.id
            if ($requirers.Count -gt 0) {
                $removeSteps = (@($requirers | ForEach-Object { "fast-llm.ps1 components -Remove $_" }) + @("fast-llm.ps1 components -Remove $unverifiedId")) -join ', then '
                throw (New-FastLlmEngineFailure -Code 'component-root-unverified' -ComponentId $unverifiedId -Message "Component folder '$chainRoot' exists but does not match its pinned file list, and the installed component(s) '$($requirers -join "', '")' require it. It was not changed. To repair it run, in this order: $removeSteps, then fast-llm.ps1 components -Install $ComponentId -AcceptLicense. Remove what requires it first.")
            }
            throw (New-FastLlmEngineFailure -Code 'component-root-unverified' -ComponentId $unverifiedId -Message "Component folder '$chainRoot' exists but does not match its pinned file list. It was not changed; remove it first (fast-llm.ps1 components -Remove $unverifiedId), then install again.")
        }
        $pending.Add($chainEntry)
    }
    $root = Get-FastLlmComponentRoot -InstallRoot $InstallRoot -Component $entry
    if ($pending.Count -eq 0) {
        if ($PassThru) { return [pscustomobject] @{ root = $root; installed = @() } }
        return $root
    }
    foreach ($pendingEntry in $pending) {
        Assert-FastLlmComponentPathLength -Component $pendingEntry -InstallRoot $InstallRoot -DownloaderNames:($null -eq $Download)
    }

    # Consent for the whole chain, settled before the first download.
    $pendingIds = @($pending | ForEach-Object { [string] $_.id })
    $chainDescription = (@($chain | ForEach-Object {
                if ($pendingIds -ccontains [string] $_.id) { "'$([string] $_.id)'" } else { "'$([string] $_.id)' (already installed)" }
            }) -join ', ')
    $needsSwitch = New-Object 'System.Collections.Generic.List[object]'
    $needsAnswer = $false
    foreach ($pendingEntry in $pending) {
        if ([string] $pendingEntry.license.consent -ceq 'accept') {
            if (-not (Test-FastLlmComponentConsentReceipt -Component $pendingEntry -InstallRoot $InstallRoot)) { $needsSwitch.Add($pendingEntry) }
        }
        else { $needsAnswer = $true }
    }
    foreach ($chainEntry in $chain) {
        Write-Host "Component: $([string] $chainEntry.displayName) ($([string] $chainEntry.id) $([string] $chainEntry.version))"
        $shownHosts = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($chainSource in @(Get-FastLlmComponentSources -Component $chainEntry)) {
            $sourceHost = ([System.Uri] ([string] $chainSource.url)).Host
            if ($shownHosts.Add($sourceHost)) { Write-Host "Source: $sourceHost" }
        }
        foreach ($licenseLink in @(Get-FastLlmComponentLicenseLinks -Component $chainEntry)) {
            Write-Host "License: $([string] $licenseLink.title) $([string] $licenseLink.url)"
        }
    }
    if (-not $AcceptLicense) {
        $switchHint = "To install it, run: fast-llm.ps1 components -Install $ComponentId -AcceptLicense"
        if ($needsSwitch.Count -gt 0) {
            $acceptNames = (@($needsSwitch | ForEach-Object { "'$([string] $_.id)'" }) -join ', ')
            throw (New-FastLlmEngineFailure -Code 'component-consent-required' -ComponentId $ComponentId -Message "Installing '$ComponentId' needs you to accept the license of: $acceptNames (links above). The whole chain is: $chainDescription. Nothing was downloaded. $switchHint")
        }
        $canAsk = -not $Unattended -and (($null -ne $script:FastLlmConsentPromptHook) -or (Test-FastLlmConsoleInteractive))
        if ($needsAnswer -and -not $canAsk) {
            throw (New-FastLlmEngineFailure -Code 'component-consent-required' -ComponentId $ComponentId -Message "Installing '$ComponentId' requires -AcceptLicense after showing the licenses of the whole chain: $chainDescription (links above); nothing here can ask you. Nothing was downloaded. $switchHint")
        }
        if ($needsAnswer) {
            $question = "Download $chainDescription under the licenses listed above? [y/N]"
            if ($null -ne $script:FastLlmConsentPromptHook) { $answer = [string] (& $script:FastLlmConsentPromptHook $question) }
            else {
                try { $answer = Read-Host $question }
                catch [System.Management.Automation.PSInvalidOperationException] {
                    throw (New-FastLlmEngineFailure -Code 'component-consent-required' -ComponentId $ComponentId -Message "Installing '$ComponentId' requires -AcceptLicense after showing the licenses of the whole chain: $chainDescription (links above); this session cannot ask you. Nothing was downloaded. $switchHint")
                }
            }
            if ($answer -notmatch '^(?i)y(es)?$') {
                throw (New-FastLlmEngineFailure -Code 'component-consent-declined' -ComponentId $ComponentId -Message "Component download was not approved for the chain: $chainDescription. Nothing was downloaded.")
            }
        }
    }
    else {
        foreach ($pendingEntry in $needsSwitch) {
            Write-FastLlmComponentConsentReceipt -Component $pendingEntry -InstallRoot $InstallRoot -AcceptanceMode 'explicit-switch'
        }
    }

    $downloader = $Download
    if ($null -eq $downloader) {
        $downloader = {
            param($Url, $Destination, $Sha256, $SizeBytes, $AllowedRedirectHosts)
            Save-FastLlmVerifiedFile -Url $Url -Destination $Destination -Sha256 $Sha256 -SizeBytes $SizeBytes -AllowedRedirectHosts $AllowedRedirectHosts | Out-Null
        }
    }
    # Leftovers of an install that was killed (the caller holds the operation lock), then required components first: each must verify
    # (Install-FastLlmComponentFiles) before the next one is even downloaded.
    Remove-FastLlmStaleComponentStaging -InstallRoot $InstallRoot
    $installed = New-Object 'System.Collections.Generic.List[object]'
    foreach ($pendingEntry in $pending) {
        Install-FastLlmComponentFiles -Entry $pendingEntry -InstallRoot $InstallRoot -Downloader $downloader
        $installed.Add([pscustomobject] [ordered] @{ id = [string] $pendingEntry.id; version = [string] $pendingEntry.version; path = (Get-FastLlmComponentRoot -InstallRoot $InstallRoot -Component $pendingEntry) })
    }
    if ($PassThru) { return [pscustomobject] @{ root = $root; installed = $installed.ToArray() } }
    return $root
}

function Get-FastLlmComponentInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ComponentsPath,

        [Parameter(Mandatory = $true)]
        [string] $InstallRoot
    )

    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in @(Get-FastLlmComponents -ComponentsPath $ComponentsPath)) {
        $root = Get-FastLlmComponentRoot -InstallRoot $InstallRoot -Component $entry
        $installed = Test-Path -LiteralPath $root -PathType Container
        $totalBytes = [int64] 0
        $verified = $false
        if ($installed) {
            foreach ($file in @(Get-ChildItem -LiteralPath $root -Force -Recurse -File -ErrorAction SilentlyContinue)) {
                $totalBytes += [int64] $file.Length
            }
            $verified = Test-FastLlmComponentInstallation -InstallRoot $InstallRoot -Component $entry -Depth Presence
        }
        $rows.Add([pscustomobject] [ordered] @{
                id        = [string] $entry.id
                kind      = [string] $entry.kind
                version   = [string] $entry.version
                installed = [bool] $installed
                bytes     = [int64] $totalBytes
                verified  = [bool] $verified
            })
    }
    return $rows.ToArray()
}

# True when a running FastLLM can reach into the component root. A running server whose status records no engine path
# cannot be proven to be elsewhere, so it also counts as in use.
function Test-FastLlmComponentInUse {
    param(
        [Parameter(Mandatory = $true)]
        [string] $InstallRoot,

        [Parameter(Mandatory = $true)]
        [string] $ComponentRoot
    )

    $status = Get-FastLlmStatus -InstallRoot $InstallRoot
    if (-not [bool] $status.active) {
        return $false
    }
    $rootPrefix = [System.IO.Path]::GetFullPath($ComponentRoot).TrimEnd([char[]] @('\', '/')) + [System.IO.Path]::DirectorySeparatorChar
    $recorded = $false
    foreach ($fieldName in @('enginePath', 'executable', 'engineExecutable', 'componentRoot')) {
        $property = $status.PSObject.Properties[$fieldName]
        if ($property -and -not [string]::IsNullOrWhiteSpace([string] $property.Value)) {
            $recorded = $true
            $recordedPath = [System.IO.Path]::GetFullPath([string] $property.Value).TrimEnd([char[]] @('\', '/')) + [System.IO.Path]::DirectorySeparatorChar
            if ($recordedPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
    }
    return -not $recorded
}

function Remove-FastLlmComponent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ComponentsPath,

        [Parameter(Mandatory = $true)]
        [string] $ComponentId,

        [Parameter(Mandatory = $true)]
        [string] $InstallRoot,

        # The caller (the CLI) already holds the operation lock. A supervised server holds that lock for its whole lifetime, so a lock the caller
        # holds proves none is serving: the status-based in-use check (which would see the caller's own lock as "running") is skipped.
        [switch] $OperationLockHeld
    )

    $entry = $null
    foreach ($candidate in @(Get-FastLlmComponents -ComponentsPath $ComponentsPath)) {
        if ([string] $candidate.id -ceq $ComponentId) {
            $entry = $candidate
        }
    }
    if ($null -eq $entry) {
        throw "Component '$ComponentId' is not in the signed components list."
    }

    # An installed component that requires this one keeps it: remove the requiring component first.
    $requiredBy = @(Get-FastLlmInstalledRequirers -AllEntries @(Get-FastLlmComponents -ComponentsPath $ComponentsPath) -InstallRoot $InstallRoot -ComponentId ([string] $entry.id))
    if ($requiredBy.Count -gt 0) {
        throw (New-FastLlmEngineFailure -Code 'component-required-by' -ComponentId ([string] $entry.id) -Message ("Component '$ComponentId' is required by the installed component(s) '" + ($requiredBy -join "', '") + "'. Remove them first; nothing was deleted."))
    }

    $componentsRoot = Join-FastLlmContainedPath -Root $InstallRoot -Child 'components' -Label 'Components root'
    $root = Get-FastLlmComponentRoot -InstallRoot $InstallRoot -Component $entry
    # Join-FastLlmContainedPath proved containment; this also rules out the components folder itself.
    $componentsPrefix = $componentsRoot.TrimEnd([char[]] @('\', '/')) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $root.StartsWith($componentsPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Component folder is not under the components folder; nothing was deleted.'
    }
    if (-not $OperationLockHeld -and (Test-FastLlmComponentInUse -InstallRoot $InstallRoot -ComponentRoot $root)) {
        throw "FastLLM is running and may be using '$ComponentId'. Stop FastLLM first; nothing was deleted."
    }

    $removed = $false
    if (Test-Path -LiteralPath $root) {
        $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop
        if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            # A link standing where the component folder should be: only the link is removed, never what it points at.
            if (-not $rootItem.PSIsContainer) { throw "Refusing to delete '$root': it is not a plain folder." }
            [System.IO.Directory]::Delete($root)
            $removed = $true
        }
        else {
            if (-not $rootItem.PSIsContainer) {
                throw "Refusing to delete '$root': it is not a plain folder."
            }
            if (-not (Test-FastLlmPlainTree -Path $root)) {
                throw "Refusing to delete '$root': it contains a reparse point or cannot be read."
            }
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
            $removed = $true
        }
    }
    # Empty parents only, never the components folder itself.
    $parent = Split-Path -Parent $root
    while ($parent -and $parent.StartsWith($componentsPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        if (-not (Test-Path -LiteralPath $parent -PathType Container) -or @(Get-ChildItem -LiteralPath $parent -Force).Count -gt 0) {
            break
        }
        Remove-Item -LiteralPath $parent -Force -ErrorAction Stop
        $parent = Split-Path -Parent $parent
    }
    $receiptPath = Get-FastLlmComponentConsentPath -Component $entry -InstallRoot $InstallRoot
    if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
        Remove-Item -LiteralPath $receiptPath -Force -ErrorAction Stop
    }
    return $removed
}

function Install-FastLlmModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Plan,

        [Parameter(Mandatory = $true)]
        [string] $InstallRoot,

        [switch] $AcceptModelLicense,

        [switch] $Unattended
    )

    $hasExistingConsent = Test-FastLlmModelConsentReceipt -Model $Plan.model -InstallRoot $InstallRoot
    $newAcceptanceMode = $null
    if (-not $hasExistingConsent) {
        if ($AcceptModelLicense) {
            $newAcceptanceMode = 'explicit-switch'
        }
        else {
            if ($Unattended) {
                throw 'Unattended model installation requires -AcceptModelLicense or an existing exact consent receipt.'
            }
            $sizeGiB = [Math]::Round(([double] $Plan.model.sizeBytes / 1GB), 2)
            Write-Host "Model:              $($Plan.model.upstreamModel) @ $($Plan.model.upstreamRevision)"
            Write-Host "Community artifact: $($Plan.model.repository) @ $($Plan.model.revision)"
            Write-Host "Artifact SHA-256:    $($Plan.model.sha256)"
            Write-Host "Serving mode:        $($Plan.model.servingMode)"
            Write-Host "Upstream license:    $($Plan.model.upstreamLicense) ($($Plan.model.upstreamLicenseUrl))"
            Write-Host "Artifact license:    $($Plan.model.artifactLicense) (declared by $($Plan.model.artifactProvider))"
            $answer = Read-Host "Download this $sizeGiB GiB community conversion? [y/N]"
            if ($answer -notmatch '^(?i)y(es)?$') {
                throw 'Model download was not approved.'
            }
            $newAcceptanceMode = 'interactive'
        }
    }

    $modelsRoot = Join-FastLlmContainedPath -Root $InstallRoot -Child 'models' -Label 'Models root'
    $destination = Join-FastLlmContainedPath -Root $modelsRoot -Child ([string] $Plan.model.file) -Label 'Model destination'
    Save-FastLlmVerifiedFile -Url ([string] $Plan.model.url) -Destination $destination -Sha256 ([string] $Plan.model.sha256) -SizeBytes ([int64] $Plan.model.sizeBytes) | Out-Null
    if ($newAcceptanceMode) {
        Write-FastLlmModelConsentReceipt -Model $Plan.model -InstallRoot $InstallRoot -AcceptanceMode $newAcceptanceMode
    }
    return $destination
}

function Get-FastLlmModelConsentPath {
    param(
        [Parameter(Mandatory = $true)]
        $Model,

        [Parameter(Mandatory = $true)]
        [string] $InstallRoot
    )

    $consentsRoot = Join-FastLlmContainedPath -Root $InstallRoot -Child 'consents' -Label 'Consent root'
    $receiptName = '{0}-{1}.json' -f [string] $Model.id, [string] $Model.revision
    Assert-FastLlmLeafName -Value $receiptName -Label 'Consent receipt name'
    return Join-FastLlmContainedPath -Root $consentsRoot -Child $receiptName -Label 'Consent receipt path'
}

function Write-FastLlmModelConsentReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Model,

        [Parameter(Mandatory = $true)]
        [string] $InstallRoot,

        [Parameter(Mandatory = $true)]
        [ValidateSet('interactive', 'explicit-switch')]
        [string] $AcceptanceMode
    )

    $receiptPath = Get-FastLlmModelConsentPath -Model $Model -InstallRoot $InstallRoot
    $receiptRoot = Split-Path -Parent $receiptPath
    New-Item -ItemType Directory -Path $receiptRoot -Force -ErrorAction Stop | Out-Null
    $receipt = [ordered] @{
        schemaVersion         = 1
        acceptedAt            = (Get-Date).ToUniversalTime().ToString('o')
        acceptanceMode        = $AcceptanceMode
        modelId               = [string] $Model.id
        upstreamModel         = [string] $Model.upstreamModel
        upstreamRevision      = [string] $Model.upstreamRevision
        upstreamLicense       = [string] $Model.upstreamLicense
        upstreamLicenseSha256 = [string] $Model.upstreamLicenseSha256
        artifactRepository    = [string] $Model.repository
        artifactRevision      = [string] $Model.revision
        artifactLicense       = [string] $Model.artifactLicense
        artifactSha256        = [string] $Model.sha256
    }
    $temporary = "$receiptPath.tmp.$([Guid]::NewGuid().ToString('N'))"
    $written = $false
    try {
        $receipt | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temporary -Encoding UTF8 -NoNewline -ErrorAction Stop
        $written = $true
        Move-FastLlmFileReplacing -Source $temporary -Destination $receiptPath
        # Success consumed the temp. Stale temps kept by earlier FAILED replaces of this receipt are swept, best-effort.
        Remove-FastLlmStaleTemporaries -Folder $receiptRoot -NamePattern ('^' + [regex]::Escape([IO.Path]::GetFileName($receiptPath)) + '\.tmp\.[0-9a-f]{32}$')
    }
    finally {
        # Best-effort. A fully written temp is ALWAYS kept after a failed replace (it may be the only copy); only a partial write is removed.
        if (-not $written) { try { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue } } catch { } }
    }
}

function Test-FastLlmModelConsentReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Model,

        [Parameter(Mandatory = $true)]
        [string] $InstallRoot
    )

    $receiptPath = Get-FastLlmModelConsentPath -Model $Model -InstallRoot $InstallRoot
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
        return $false
    }
    try {
        # A real receipt is well under 4 KiB; a larger file is rejected unparsed and counts as no receipt.
        $receipt = Read-FastLlmJson -Path $receiptPath -MaxBytes 16384
        return [int] $receipt.schemaVersion -eq 1 -and
            [string] $receipt.modelId -eq [string] $Model.id -and
            [string] $receipt.upstreamModel -ceq [string] $Model.upstreamModel -and
            [string] $receipt.upstreamRevision -eq [string] $Model.upstreamRevision -and
            [string] $receipt.upstreamLicense -ceq [string] $Model.upstreamLicense -and
            [string] $receipt.upstreamLicenseSha256 -eq [string] $Model.upstreamLicenseSha256 -and
            [string] $receipt.artifactRepository -ceq [string] $Model.repository -and
            [string] $receipt.artifactRevision -eq [string] $Model.revision -and
            [string] $receipt.artifactLicense -ceq [string] $Model.artifactLicense -and
            [string] $receipt.artifactSha256 -eq [string] $Model.sha256
    }
    catch {
        return $false
    }
}

# A failure carrying a typed, closed-vocabulary code (Data['FastLlmFailureCode']) next to its human message.
function New-FastLlmTypedFailure {
    param([Parameter(Mandatory = $true)][string] $Code, [Parameter(Mandatory = $true)][string] $Message)
    $exception = New-Object -TypeName System.InvalidOperationException -ArgumentList ($Code + ': ' + $Message)
    $exception.Data['FastLlmFailureCode'] = $Code
    return $exception
}

function Start-FastLlmServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Plan,

        [Parameter(Mandatory = $true)]
        [string] $CatalogPath,

        [Parameter(Mandatory = $true)]
        [string] $InstallRoot,

        [ValidateRange(10, 1800)]
        [int] $LoadTimeoutSeconds = 300,

        # Lab override of the module-level policy; absent means "use $script:FastLlmVulkanBarMitigationPolicy" (default off).
        [ValidateSet('off', 'on', 'auto')]
        [string] $VulkanBarMitigation,

        # Advisory post-Ready prompt-processing canary; default off.
        [switch] $ThroughputCanary,

        # Post-load self-test (default off for direct callers; the CLI start enables it).
        [switch] $SelfTest,

        # W03 Phase A per-start device binding. off is byte-identical to a start without the parameter; record observes only;
        # enforce fails the start (typed, never recovered) when the binding is not bound or the post-load device check fails.
        [ValidateSet('off', 'record', 'enforce')]
        [string] $DeviceBinding = 'off'
    )

    # ValidateSet ignores case and keeps the typed value; normalise once, before any comparison or forwarding.
    $DeviceBinding = $DeviceBinding.ToLowerInvariant()

    Assert-FastLlmWindowsPrerequisites

    if ($PSBoundParameters.ContainsKey('VulkanBarMitigation')) { $vulkanMemoryPolicy = ConvertTo-FastLlmVulkanBarMitigationName $VulkanBarMitigation }
    else { $vulkanMemoryPolicy = ConvertTo-FastLlmVulkanBarMitigationName $script:FastLlmVulkanBarMitigationPolicy }

    # Device binding is Vulkan-only: enforce on a HIP plan is refused before anything is verified or launched.
    if (([string] $Plan.backend) -ieq 'hip' -and $DeviceBinding -ceq 'enforce') {
        throw (New-FastLlmDeviceBindingFailure -Code 'device-binding-unsupported-backend' -Message 'Device binding (enforce) is available only for the Vulkan lane; this setup runs on the HIP engine. The server was not started. Use -DeviceBinding record or -DeviceBinding off to start without this requirement.')
    }

    $catalog = Get-FastLlmCatalog -CatalogPath $CatalogPath
    $backendKey = ([string] $Plan.backend).ToLowerInvariant()
    if ($Plan.PSObject.Properties['engineComponentId'] -and $Plan.engineComponentId) {
        # A plan on an engine component (M7) never consults the catalog backend asset or the built-in engine installation: it runs the component's
        # verified executable. Every required component is verified in full first, naming the first one that fails; nothing falls back or installs.
        $planComponentId = [string] $Plan.engineComponentId
        $startComponentsFile = Join-Path (Split-Path -Parent $CatalogPath) 'components.json'
        $startComponents = @()
        $startComponent = $null
        if (Test-Path -LiteralPath $startComponentsFile -PathType Leaf) {
            $startComponents = @(Get-FastLlmComponents -ComponentsPath $startComponentsFile)
            $startComponent = Find-FastLlmEngineComponent -Components $startComponents -EngineId $planComponentId
        }
        if ($null -eq $startComponent) {
            throw (New-FastLlmEngineFailure -Code 'recipe-engine-component-unknown' -ComponentId $planComponentId -Message "The plan names the engine component '${planComponentId}', which is not in the signed components list.")
        }
        $unavailableComponentId = Get-FastLlmFirstUnavailableComponent -Components $startComponents -EngineId $planComponentId -InstallRoot $InstallRoot -Depth Full
        if ($unavailableComponentId) {
            $startUnavailableFailure = New-FastLlmEngineFailure -Code 'needs-setup-component-missing' -ComponentId $planComponentId -Message "The component '${unavailableComponentId}' (for the engine component '${planComponentId}') is not installed or failed its file check. The built-in engine is not used instead."
            $startUnavailableFailure.Data['FastLlmUnavailableComponentId'] = $unavailableComponentId
            throw $startUnavailableFailure
        }
        if (([string] $startComponent.platform.backend) -ine ([string] $Plan.backend)) {
            throw (New-FastLlmEngineFailure -Code 'recipe-engine-backend-mismatch' -ComponentId $planComponentId -Message "The plan backend '$($Plan.backend)' does not match the engine component '${planComponentId}', which is a $($startComponent.platform.backend) engine. Nothing was started.")
        }
        $expectedEngine = Join-FastLlmContainedPath -Root (Get-FastLlmComponentRoot -InstallRoot $InstallRoot -Component $startComponent) -Child ([string] $startComponent.entryPoint) -Label 'Engine component executable path'
    }
    else {
        if ($backendKey -notin @('rocm', 'vulkan')) {
            throw "The plan selected unknown backend '$($Plan.backend)'."
        }
        $asset = $catalog.engine.assets.PSObject.Properties[$backendKey].Value
        if (-not [bool] $asset.enabled) {
            throw "The $($Plan.backend) execution lane is disabled: $($asset.disabledReason)"
        }
        if (-not (Test-FastLlmEngineInstallation -InstallRoot $InstallRoot -EngineVersion ([string] $catalog.engine.version) -BackendKey $backendKey -Asset $asset)) {
            throw 'The selected engine installation failed its exact file manifest. Run the install action to repair it.'
        }
        $expectedEngine = Get-FastLlmEngineExecutable -InstallRoot $InstallRoot -EngineVersion ([string] $catalog.engine.version) -BackendKey $backendKey -EntryPoint ([string] $asset.entryPoint)
    }
    if (-not $Plan.enginePath -or -not ([string] $Plan.enginePath).Equals($expectedEngine, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The plan engine path does not match the verified installed engine.'
    }

    $catalogModel = @($catalog.models | Where-Object { [string] $_.id -eq [string] $Plan.model.id } | Select-Object -First 1)
    if ($catalogModel.Count -ne 1 -or [string] $catalogModel[0].sha256 -ne [string] $Plan.model.sha256) {
        throw 'The selected model is not the exact current catalog entry.'
    }
    if (-not $Plan.modelPath -or -not (Test-Path -LiteralPath $Plan.modelPath -PathType Leaf)) {
        throw "The selected model is not installed at '$($Plan.modelPath)'. Run the install action after this hardware change."
    }
    if (-not (Test-FastLlmFileHash -Path ([string] $Plan.modelPath) -Sha256 ([string] $Plan.model.sha256))) {
        $modelRepairMessage = "The selected model failed SHA-256 verification at '$($Plan.modelPath)' and must be quarantined and reacquired."
        $modelRepairException = New-Object -TypeName System.InvalidOperationException -ArgumentList $modelRepairMessage
        $modelRepairException.Data['FastLlmReason'] = 'ModelNeedsProvisioning'
        throw $modelRepairException
    }
    if (-not (Test-FastLlmModelConsentReceipt -Model $Plan.model -InstallRoot $InstallRoot)) {
        throw 'The exact model revision has no matching license-consent receipt. Run the install action.'
    }

    $freshHardware = Get-FastLlmHardware -CatalogPath $CatalogPath -InstallRoot $InstallRoot
    # A recipe-chosen plan is re-planned with the same recipe data, or it would always look "changed" against the estimated choice.
    $freshRecipeOptions = @{}
    $configRoot = Split-Path -Parent $CatalogPath
    # Added only when set, so the default call keeps the exact parameter set it always had.
    if ($Plan.PSObject.Properties['recovered'] -and $Plan.recovered) { $freshRecipeOptions.Recovered = $true }
    $planRecipeId = $null
    if ($Plan.PSObject.Properties['requestedRecipeId'] -and $Plan.requestedRecipeId) { $planRecipeId = [string] $Plan.requestedRecipeId }
    if ($Plan.PSObject.Properties['recipe'] -and $Plan.recipe -and $Plan.recipe.origin -notin @('estimated', 'manual')) {
        $freshRecipeOptions.RecipesPath = Join-Path $configRoot 'recipes.json'
        $freshRecipeOptions.GpuVariantsPath = Join-Path $configRoot 'gpu-variants.json'
        if ($planRecipeId) { $freshRecipeOptions.RecipeId = $planRecipeId }
    }
    $freshPlan = Get-FastLlmPlan -Hardware $freshHardware -CatalogPath $CatalogPath -Profile ([string] $Plan.profile) -InstallRoot $InstallRoot -ModelId $Plan.requestedModelId -ContextSize $Plan.requestedContextSize -AllowExperimentalModel:$Plan.allowExperimentalModel @freshRecipeOptions
    $planRequiresProvisioning = [string] $freshPlan.catalogVersion -ne [string] $Plan.catalogVersion -or
        [string] $freshPlan.backend -ne [string] $Plan.backend -or
        [string] $freshPlan.enginePath -ne [string] $Plan.enginePath -or
        [string] $freshPlan.model.id -ne [string] $Plan.model.id -or
        [string] $freshPlan.modelPath -ne [string] $Plan.modelPath -or
        [string] $freshPlan.model.sha256 -ne [string] $Plan.model.sha256 -or
        [int64] $freshPlan.model.sizeBytes -ne [int64] $Plan.model.sizeBytes -or
        [string] $freshPlan.model.url -ne [string] $Plan.model.url -or
        [string] $freshPlan.model.repository -ne [string] $Plan.model.repository -or
        [string] $freshPlan.model.revision -ne [string] $Plan.model.revision -or
        [string] $freshPlan.model.upstreamModel -ne [string] $Plan.model.upstreamModel -or
        [string] $freshPlan.model.upstreamRevision -ne [string] $Plan.model.upstreamRevision -or
        [string] $freshPlan.model.upstreamLicense -ne [string] $Plan.model.upstreamLicense -or
        [string] $freshPlan.model.upstreamLicenseSha256 -ne [string] $Plan.model.upstreamLicenseSha256 -or
        [string] $freshPlan.model.artifactLicense -ne [string] $Plan.model.artifactLicense
    # A measured plan must not start silently as estimated: if the start re-plan lost the card identity or the recipe (for example a failed
    # or slow inventory probe), the preview label and the recipe id would no longer describe what runs. Re-plan instead, and say why.
    $planRecipeLostReason = $null
    if ($Plan.PSObject.Properties['recipe'] -and $Plan.recipe -and [string] $Plan.recipe.origin -notin @('estimated', 'manual')) {
        $freshOrigin = ''
        $freshRecipeId = ''
        if ($freshPlan.PSObject.Properties['recipe'] -and $freshPlan.recipe) { $freshOrigin = [string] $freshPlan.recipe.origin; $freshRecipeId = [string] $freshPlan.recipe.id }
        if ($freshOrigin -in @('', 'estimated', 'manual')) {
            $planRecipeLostReason = "The measured recipe '$($Plan.recipe.id)' no longer applies at start (the card could not be identified again or the recipe no longer fits); it will not run as an estimated setup under a measured label."
        }
        elseif ($freshRecipeId -ne [string] $Plan.recipe.id) {
            $planRecipeLostReason = "The measured recipe '$($Plan.recipe.id)' was replaced by '$freshRecipeId' at start."
        }
    }
    if ($planRecipeLostReason) {
        $recipeLostException = New-Object -TypeName System.InvalidOperationException -ArgumentList $planRecipeLostReason
        $recipeLostException.Data['FastLlmReason'] = 'PlanChanged'
        throw $recipeLostException
    }
    if ($planRequiresProvisioning) {
        $planChangedMessage = "Hardware, catalog, or model provenance changed while preparing startup; selection must be replanned (previous '$($Plan.model.id)', current '$($freshPlan.model.id)')."
        $planChangedException = New-Object -TypeName System.InvalidOperationException -ArgumentList $planChangedMessage
        $planChangedException.Data['FastLlmReason'] = 'PlanChanged'
        throw $planChangedException
    }
    # The model is unchanged, so use the newest device set, free-memory split, and launch arguments.
    if ($Plan.PSObject.Properties['backgroundRequestId']) {
        $backgroundRequestId = [string]$Plan.backgroundRequestId
        if ($backgroundRequestId -cnotmatch '^[0-9a-f]{32}$') { throw 'Invalid background request correlation.' }
        $freshPlan | Add-Member -NotePropertyName backgroundRequestId -NotePropertyValue $backgroundRequestId -Force
    }
    $Plan = $freshPlan

    # Extra supervisor options are passed only when requested, so the default call is unchanged.
    $supervisorOptions = @{}
    if ($vulkanMemoryPolicy -ne 'off') { $supervisorOptions.VulkanBarMitigation = $vulkanMemoryPolicy }
    if ($ThroughputCanary) { $supervisorOptions.ThroughputCanary = $true }
    if ($SelfTest) { $supervisorOptions.SelfTest = $true }
    if ($DeviceBinding -ne 'off') { $supervisorOptions.DeviceBinding = $DeviceBinding }
    return Invoke-FastLlmSupervisedServer -Plan $Plan -InstallRoot $InstallRoot -LoadTimeoutSeconds $LoadTimeoutSeconds -CatalogPath $CatalogPath @supervisorOptions
}

Export-ModuleMember -Function @(
    'Add-FastLlmDriverVersions',
    'Assert-FastLlmHardware',
    'ConvertFrom-LlamaDeviceList',
    'Get-FastLlmCatalog',
    'Get-FastLlmEngineExecutable',
    'Get-FastLlmHardware',
    'Get-FastLlmPlan',
    'Get-FastLlmVulkanMemoryDiagnostic',
    'Get-FastLlmWindowsPrerequisiteStatus',
    'Get-FastLlmPrerequisiteInventory',
    'Get-FastLlmStatus',
    'Initialize-FastLlmOffloadLab',
    'Start-FastLlmOffloadLab',
    'Get-FastLlmOffloadLabStatus',
    'Request-FastLlmOffloadLabStop',
    'Invoke-FastLlmSoak',
    'Request-FastLlmStop',
    'Enter-FastLlmOperation',
    'Write-FastLlmState',
    'ConvertFrom-FastLlmPlacementLog',
    'Test-FastLlmApiCanary',
    'Invoke-FastLlmBenchmark',
    'Invoke-FastLlmOffloadBenchmark',
    'Get-FastLlmWindowsInventory',
    'Get-FastLlmDriverGuidance',
    'Get-FastLlmInventoryDriverGuidance',
    'Format-FastLlmDriverGuidance',
    'Get-FastLlmRecoveryPlan',
    'Install-FastLlmEngines',
    'Get-FastLlmComponents',
    'Get-FastLlmComponentRoot',
    'Get-FastLlmComponentSources',
    'Get-FastLlmComponentChain',
    'Test-FastLlmComponentInstallation',
    'Get-FastLlmComponentLicenseLinks',
    'Install-FastLlmComponent',
    'Get-FastLlmComponentInventory',
    'Remove-FastLlmComponent',
    'New-FastLlmTypedFailure',
    'Install-FastLlmModel',
    'Invoke-FastLlmDeviceProbe',
    'Read-FastLlmJson',
    'Read-FastLlmRecipes',
    'Get-FastLlmRecipeLabel',
    'Remove-FastLlmDeviceBindingPrivateFields',
    'Save-FastLlmVerifiedFile',
    'Start-FastLlmServer',
    'Test-FastLlmEngineInstallation',
    'Test-FastLlmFileHash',
    'Test-FastLlmHipSupportedName',
    'Test-FastLlmIntegratedName',
    'Test-FastLlmModelConsentReceipt'
)
