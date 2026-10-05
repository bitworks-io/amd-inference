#requires -Version 5.1
# Private, read-only b10698 Vulkan capability snapshot. Dot-source only for parser tests.
param([string]$InstallRoot, [string]$OutputPath)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function ConvertFrom-FastLlmVulkanCapabilityOutput {
    param([Parameter(Mandatory=$true)][string]$Text)
    if ($Text.Length -gt 65536) { throw 'Vulkan capability output exceeded its bound.' }
    $capabilities = @{}
    $listed = @{}
    $capLike = 0
    $listLike = 0
    $foundCount = $null
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line.Length -ge 8192) { throw 'A Vulkan capability output line may have been truncated.' }
        if ($line -match 'ggml_vulkan:\s*Found\s+\d+') {
            if ($null -ne $foundCount -or $line -cnotmatch '^.*ggml_vulkan: Found (?<count>[1-8]) Vulkan devices:\s*$') {
                throw 'Missing or duplicate Vulkan device-count evidence.'
            }
            $foundCount = [int]$Matches.count
        }
        if ($line -match 'ggml_vulkan:\s*\d+\s*=') {
            $capLike++
            if ($line -cnotmatch '^.*ggml_vulkan:\s*(?<index>[0-7]) = (?<name>[A-Za-z0-9 ._()+-]{1,96}) \((?<driver>[A-Za-z0-9 ._()+-]{1,96})\) \| uma: (?<uma>[01]) \| fp16: (?<fp16>0|1|dot2) \| bf16: (?<bf16>[01]) \| fp4: (?<fp4>[01]) \| warp size: (?<warp>\d{1,3}) \| shared memory: (?<shared>\d{1,8}) \| int dot: (?<dot>[01]) \| matrix cores: (?<matrix>none|KHR_coopmat|NV_coopmat2v|NV_coopmat2)\s*$') {
                throw 'Unrecognized Vulkan capability row.'
            }
            $index = [int]$Matches.index
            if ($capabilities.ContainsKey($index)) { throw 'Duplicate Vulkan capability row.' }
            $warp = [int]$Matches.warp
            $shared = [int]$Matches.shared
            if ($warp -lt 1 -or $warp -gt 128 -or $shared -lt 1 -or $shared -gt 1048576) { throw 'Impossible Vulkan capability value.' }
            $capabilities[$index] = [pscustomobject][ordered]@{
                device = "Vulkan$index"
                name = [string]$Matches.name
                driverName = [string]$Matches.driver
                uma = ($Matches.uma -ceq '1')
                fp16 = [string]$Matches.fp16
                bf16 = ($Matches.bf16 -ceq '1')
                fp4 = ($Matches.fp4 -ceq '1')
                warpSize = $warp
                sharedMemoryBytes = $shared
                integerDotProduct = ($Matches.dot -ceq '1')
                matrixCores = [string]$Matches.matrix
            }
        }
        if ($line -match '^\s*Vulkan\d+:') {
            $listLike++
            if ($line -cnotmatch '^\s*Vulkan(?<index>[0-7]): (?<name>[A-Za-z0-9 ._()+-]{1,96}) \((?<total>\d{1,8}) MiB, (?<free>\d{1,8}) MiB free\)\s*$') {
                throw 'Unrecognized Vulkan device-list row.'
            }
            $index = [int]$Matches.index
            if ($listed.ContainsKey($index)) { throw 'Duplicate Vulkan device-list row.' }
            $total = [int64]::Parse($Matches.total, [Globalization.CultureInfo]::InvariantCulture)
            $free = [int64]::Parse($Matches.free, [Globalization.CultureInfo]::InvariantCulture)
            if ($total -le 0 -or $total -gt 1048576 -or $free -gt $total) { throw 'Impossible Vulkan device memory report.' }
            $listed[$index] = [pscustomobject]@{ name=[string]$Matches.name; totalMiB=$total; freeMiB=$free }
        }
    }
    if ($capLike -lt 1 -or $capLike -gt 8 -or $foundCount -ne $capLike -or $listLike -ne $capLike -or
        $capabilities.Count -ne $capLike -or $listed.Count -ne $capLike) {
        $foundLabel = if ($null -eq $foundCount) { 'absent' } else { [string]$foundCount }
        throw "Missing or inconsistent Vulkan capability/device-list rows (capability=$capLike, listed=$listLike, found=$foundLabel)."
    }
    $result = @()
    for ($index = 0; $index -lt $capLike; $index++) {
        if (-not $capabilities.ContainsKey($index) -or -not $listed.ContainsKey($index) -or
            $capabilities[$index].name -cne $listed[$index].name) {
            throw 'Vulkan capability and device-list rows disagree.'
        }
        $row = $capabilities[$index]
        $row | Add-Member -NotePropertyName totalMiB -NotePropertyValue $listed[$index].totalMiB
        $row | Add-Member -NotePropertyName freeMiB -NotePropertyValue $listed[$index].freeMiB
        $result += $row
    }
    return @($result)
}

function Assert-FastLlmVulkanCapabilityOutputPath {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not [IO.Path]::IsPathRooted($Path)) { throw 'OutputPath must be an absolute local file path.' }
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ($root -notmatch '^[A-Za-z]:\\$' -or [IO.Path]::GetExtension($full) -ine '.json') {
        throw 'OutputPath must be a local-drive .json file.'
    }
    $parent = [IO.Path]::GetDirectoryName($full)
    $cursor = $root
    foreach ($segment in @('') + $parent.Substring($root.Length).Split([IO.Path]::DirectorySeparatorChar)) {
        if ($segment.Length -gt 0) { $cursor = Join-Path $cursor $segment }
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'OutputPath traverses an unsafe directory.'
        }
    }
    if ([IO.File]::Exists($full) -or [IO.Directory]::Exists($full)) {
        throw 'OutputPath already exists; use a new report filename.'
    }
    return $full
}

function Invoke-FastLlmVulkanCapabilities {
    param([Parameter(Mandatory=$true)][string]$InstallRoot,
          [Parameter(Mandatory=$true)][string]$OutputPath)
    if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) {
        throw 'This private diagnostic requires 64-bit Windows.'
    }
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run as a standard user, not elevated.'
    }
    $reportPath = Assert-FastLlmVulkanCapabilityOutputPath -Path $OutputPath
    $repo = Split-Path $PSScriptRoot -Parent
    $catalogPath = Join-Path $repo 'config/catalog.json'
    $modulePath = Join-Path $repo 'src/FastLlm.psm1'
    $hostSource = Join-Path $repo 'src/ProcessHost.cs'
    $sourceHash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $catalogHash = (Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash.ToLowerInvariant()
    # This private diagnostic trusts one reviewed catalog, including its entire
    # extracted engine manifest. The archive digest alone cannot pin that list.
    if ($catalogHash -cne '65b8f2f9ca340dab273274086aba9e8f01cb14a2b8cf4bb65c5ed5f6e779caa6') {
        throw 'Private Vulkan capability collector requires its reviewed catalog digest.'
    }
    $moduleHash = (Get-FileHash -LiteralPath $modulePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $hostHash = (Get-FileHash -LiteralPath $hostSource -Algorithm SHA256).Hash.ToLowerInvariant()
    $module = Import-Module $modulePath -PassThru -Force -DisableNameChecking -ErrorAction Stop
    & $module { Assert-FastLlmWindowsPrerequisites }
    $catalog = Get-FastLlmCatalog -CatalogPath $catalogPath
    $asset = $catalog.engine.assets.vulkan
    if ($catalog.engine.version -cne 'b10698' -or $asset.enabled -ne $true -or
        $asset.entryPoint -cne 'llama-server.exe' -or
        $asset.sha256 -cne '31e2fe70d4864a4ae6a4e7d8e102ee9203ba18963077e7727c54f9bd6ae3bea5') {
        throw 'Only the catalog-pinned b10698 Vulkan engine is permitted.'
    }
    if (-not (Test-FastLlmEngineInstallation -InstallRoot $InstallRoot -EngineVersion 'b10698' -BackendKey 'vulkan' -Asset $asset)) {
        throw 'Pinned Vulkan engine failed its complete extracted-file manifest.'
    }
    $enginePath = Get-FastLlmEngineExecutable -InstallRoot $InstallRoot -EngineVersion 'b10698' -BackendKey 'vulkan'
    if (-not $enginePath) { throw 'Pinned Vulkan executable is unavailable.' }
    $engineHash = (Get-FileHash -LiteralPath $enginePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if (-not ('Bitworks.FastLlm.ProcessHost' -as [type])) { Add-Type -Path $hostSource -ErrorAction Stop }
    $sandbox = & $module {param($root) New-FastLlmRuntimeSandbox -InstallRoot $root} $InstallRoot
    $child = $null
    # In b10698, --list-devices calls exit(0) inside argument parsing. Force
    # backend enumeration first, then synchronously drain its async debug log
    # before that early exit. No model, API listener, or environment override.
    $arguments = @('--log-verbosity','5','--device','Vulkan0','--log-disable','--list-devices')
    $startedUtc = [DateTime]::UtcNow.ToString('o')
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $child = New-Object Bitworks.FastLlm.ProcessHost
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $enginePath
        $info.Arguments = '--log-verbosity 5 --device Vulkan0 --log-disable --list-devices'
        $info.WorkingDirectory = Split-Path -Parent $enginePath
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        foreach ($name in @($info.EnvironmentVariables.Keys)) {
            if ((& $module {param($key) Test-FastLlmEnvironmentNameRequiresClearing -Name $key} ([string]$name)) -or
                ([string]$name) -like 'VULKAN_*' -or ([string]$name) -like 'AMD_VULKAN_*') {
                $info.EnvironmentVariables.Remove([string]$name)
            }
        }
        $info.EnvironmentVariables['APPDATA'] = [string]$sandbox.appData
        $info.EnvironmentVariables['PROGRAMDATA'] = [string]$sandbox.programData
        $windowsRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
        $system32 = [Environment]::GetFolderPath([Environment+SpecialFolder]::System)
        if (-not $windowsRoot -or -not $system32) { throw 'Windows loader directories are unavailable.' }
        $info.EnvironmentVariables['PATH'] = "$(Split-Path -Parent $enginePath);$system32;$windowsRoot"
        $child.Start($info)
        while ($watch.ElapsedMilliseconds -lt 20000) {
            if ($child.Process.WaitForExit(100)) { break }
        }
        if (-not $child.Process.HasExited) { throw 'Vulkan capability probe exceeded 20 seconds.' }
        $exitCode = $child.Process.ExitCode
        while (-not $child.OutputCompleted -and $watch.ElapsedMilliseconds -lt 20000) {
            Start-Sleep -Milliseconds 20
        }
        if (-not $child.OutputCompleted -or $child.OutputTruncated -or $exitCode -ne 0) {
            throw 'Vulkan capability probe failed or returned incomplete output.'
        }
        $devices = @(ConvertFrom-FastLlmVulkanCapabilityOutput -Text ($child.Snapshot()))
    } finally {
        if ($child) { $child.Dispose() }
        & $module {param($box) Remove-FastLlmRuntimeSandbox -Sandbox $box} $sandbox
    }
    if (-not (Test-FastLlmEngineInstallation -InstallRoot $InstallRoot -EngineVersion 'b10698' -BackendKey 'vulkan' -Asset $asset) -or
        (Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $catalogHash -or
        (Get-FileHash -LiteralPath $modulePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $moduleHash -or
        (Get-FileHash -LiteralPath $hostSource -Algorithm SHA256).Hash.ToLowerInvariant() -cne $hostHash -or
        (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $sourceHash -or
        (Get-FileHash -LiteralPath $enginePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $engineHash) {
        throw 'Diagnostic inputs changed during the Vulkan capability probe.'
    }
    $report = [ordered]@{
        schemaVersion = 1
        kind = 'fastllm-private-vulkan-capabilities'
        source = 'b10698-llama-server-flushed-debug-and-device-list'
        startedUtc = $startedUtc
        completedUtc = [DateTime]::UtcNow.ToString('o')
        engineArchiveSha256 = [string]$asset.sha256
        engineExecutableSha256 = $engineHash
        catalogSha256 = $catalogHash
        moduleSourceSha256 = $moduleHash
        processHostSourceSha256 = $hostHash
        collectorSourceSha256 = $sourceHash
        arguments = $arguments
        fullFileSetVerifiedBeforeAndAfter = $true
        isolation = 'normal-targeted-environment-plus-vulkan-vendor-overrides-and-empty-config-roots'
        devices = $devices
        qualification = $false
        servingDeviceBinding = $false
        performanceQualification = $false
    }
    $json = $report | ConvertTo-Json -Depth 7 -Compress
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json)
    if ($bytes.Length -gt 32768) { throw 'Vulkan capability report exceeded its bound.' }
    $stream = [IO.File]::Open($reportPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() }
    finally { $stream.Dispose() }
    return $reportPath
}

if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($InstallRoot) -or [string]::IsNullOrWhiteSpace($OutputPath)) {
        throw 'Specify -InstallRoot and a fresh absolute -OutputPath.'
    }
    Invoke-FastLlmVulkanCapabilities -InstallRoot $InstallRoot -OutputPath $OutputPath
}
