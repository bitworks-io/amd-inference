Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FastLlm.SelectedDeviceIdentity.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.Runtime.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.OffloadLab.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.Benchmark.ps1')
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
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "JSON file was not found: $Path"
    }

    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
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
        [int] $TimeoutSeconds = 15
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
        foreach ($name in @($startInfo.EnvironmentVariables.Keys)) {
            if (Test-FastLlmEnvironmentNameRequiresClearing -Name ([string] $name)) {
                $startInfo.EnvironmentVariables.Remove([string] $name)
            }
        }
        $startInfo.EnvironmentVariables['APPDATA'] = [string] $sandbox.appData
        $startInfo.EnvironmentVariables['PROGRAMDATA'] = [string] $sandbox.programData
        if ($env:OS -eq 'Windows_NT' -and $env:SystemRoot) {
            $system32 = Join-Path $env:SystemRoot 'System32'
            $startInfo.EnvironmentVariables['PATH'] = "$(Split-Path -Parent $EnginePath);$system32;$env:SystemRoot"
        }
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
            return @()
        }
        $output = [string] $stdoutTask.GetAwaiter().GetResult()
        $errorOutput = [string] $stderrTask.GetAwaiter().GetResult()
        if ($errorOutput) {
            $output = $output + [Environment]::NewLine + $errorOutput
        }
    }
    catch {
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

        [switch] $AllowExperimentalModel
    )

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

    if (-not $selected) {
        if ($ModelId) { throw "Requested model '$ModelId' does not fit the estimated current free-memory budget. No other model was substituted." }
        $maximumAvailableCapacity = [int64] (($placements | Measure-Object -Property selectionCapacity -Maximum).Maximum)
        throw "No catalog profile fits the currently free AMD VRAM ($maximumAvailableCapacity MiB across a supported placement). Close GPU-heavy applications or select different hardware."
    }

    # Copy before narrowing context: the immutable artifact/provenance remains unchanged.
    $model = $selected.model | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $catalogContext = [int] $model.contextSize
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

    return [pscustomobject] [ordered] @{
        schemaVersion       = 1
        catalogVersion      = [string] $catalog.catalogVersion
        hardwareFingerprint = Get-FastLlmFingerprint -Hardware $Hardware
        fingerprintKind     = 'inventory-key-not-authoritative-pci-identity'
        selectionMode       = if ($ModelId) { 'explicit' } else { 'auto' }
        requestedModelId    = $ModelId
        requestedContextSize = $ContextSize
        allowExperimentalModel = [bool] $AllowExperimentalModel
        catalogContextSize  = $catalogContext
        performanceQualified = $false
        candidatePlacementCount = $placements.Count
        profile             = $Profile
        backend             = [string] $Hardware.backend
        engineVersion       = [string] $catalog.engine.version
        enginePath          = $Hardware.enginePath
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
        warnings            = $warnings
    }
}

function Test-FastLlmFileHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $Sha256
    )

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
        [int64] $SizeBytes
    )

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
                $curlArguments = @(
                    '--disable',
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
                    '--output', $partial,
                    $Url
                )
                $curlProcess = New-Object System.Diagnostics.Process
                $curlStarted = $false
                $curlExceededSize = $false
                try {
                    $curlStartInfo = New-Object System.Diagnostics.ProcessStartInfo
                    $curlStartInfo.FileName = $curlPath
                    $curlStartInfo.Arguments = Join-FastLlmProcessArguments -Arguments $curlArguments
                    $curlStartInfo.WorkingDirectory = $parent
                    $curlStartInfo.UseShellExecute = $false
                    $curlStartInfo.CreateNoWindow = $true
                    $curlProcess.StartInfo = $curlStartInfo
                    if (-not $curlProcess.Start()) {
                        throw 'curl did not start.'
                    }
                    $curlStarted = $true
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
                if ($curlExceededSize) {
                    $oversizedPartial = "$partial.corrupt.oversize.$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')).$([Guid]::NewGuid().ToString('N'))"
                    if (Test-Path -LiteralPath $partial) {
                        Move-Item -LiteralPath $partial -Destination $oversizedPartial -ErrorAction Stop
                    }
                    throw "Download exceeded the catalog size ceiling of $SizeBytes bytes. The oversized partial was quarantined."
                }
                if ($curlExitCode -ne 0) {
                    throw "Download failed with curl exit code $curlExitCode. The SHA-bound partial file was retained for resume."
                }
            }
            else {
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
                throw "Downloaded artifact failed exact size/SHA-256 verification for '$Destination'. The bad partial was quarantined."
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
    try {
        $receipt | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temporary -Encoding UTF8 -NoNewline -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $receiptPath -Force -ErrorAction Stop
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
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
        $receipt = Read-FastLlmJson -Path $receiptPath
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
        [int] $LoadTimeoutSeconds = 300
    )

    Assert-FastLlmWindowsPrerequisites

    $catalog = Get-FastLlmCatalog -CatalogPath $CatalogPath
    $backendKey = ([string] $Plan.backend).ToLowerInvariant()
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
    $freshPlan = Get-FastLlmPlan -Hardware $freshHardware -CatalogPath $CatalogPath -Profile ([string] $Plan.profile) -InstallRoot $InstallRoot -ModelId $Plan.requestedModelId -ContextSize $Plan.requestedContextSize -AllowExperimentalModel:$Plan.allowExperimentalModel
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
    if ($planRequiresProvisioning) {
        $planChangedMessage = "Hardware, catalog, or model provenance changed while preparing startup; selection must be replanned (previous '$($Plan.model.id)', current '$($freshPlan.model.id)')."
        $planChangedException = New-Object -TypeName System.InvalidOperationException -ArgumentList $planChangedMessage
        $planChangedException.Data['FastLlmReason'] = 'PlanChanged'
        throw $planChangedException
    }
    # The model is unchanged, so use the newest device set, free-memory split, and launch arguments.
    $Plan = $freshPlan

    return Invoke-FastLlmSupervisedServer -Plan $Plan -InstallRoot $InstallRoot -LoadTimeoutSeconds $LoadTimeoutSeconds -CatalogPath $CatalogPath
}

Export-ModuleMember -Function @(
    'Add-FastLlmDriverVersions',
    'Assert-FastLlmHardware',
    'ConvertFrom-LlamaDeviceList',
    'Get-FastLlmCatalog',
    'Get-FastLlmEngineExecutable',
    'Get-FastLlmHardware',
    'Get-FastLlmPlan',
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
    'Install-FastLlmModel',
    'Invoke-FastLlmDeviceProbe',
    'Read-FastLlmJson',
    'Save-FastLlmVerifiedFile',
    'Start-FastLlmServer',
    'Test-FastLlmEngineInstallation',
    'Test-FastLlmFileHash',
    'Test-FastLlmHipSupportedName',
    'Test-FastLlmIntegratedName',
    'Test-FastLlmModelConsentReceipt'
)
