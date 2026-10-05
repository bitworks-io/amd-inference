#requires -Version 5.1
# Private GGML log-callback diagnostic; never imported by the normal service.
param([string]$InstallRoot, [string]$OutputPath, [switch]$Worker, [string]$WorkerToken)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:ggmlCapabilityWorkerStage = 'entry'

function Assert-GgmlCapabilityStandardWindows {
    if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) {
        throw 'GGML capability diagnostic requires 64-bit Windows.'
    }
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'GGML capability diagnostic requires a standard-user process.'
    }
}
function Assert-GgmlCapabilityOutputPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) {
        throw 'OutputPath must be an absolute local file path.'
    }
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
        throw 'OutputPath already exists; choose a fresh report filename.'
    }
    return $full
}
function Assert-GgmlCapabilitySnapshot {
    param($Snapshot)
    if ($null -eq $Snapshot -or
        ($Snapshot.ReportedDeviceCount -isnot [int] -and $Snapshot.ReportedDeviceCount -isnot [long]) -or
        $Snapshot.ReportedDeviceCount -lt 1 -or $Snapshot.ReportedDeviceCount -gt 8 -or
        @($Snapshot.Devices).Count -ne $Snapshot.ReportedDeviceCount) {
        throw 'GGML capability worker returned an invalid device count.'
    }
    for ($index = 0; $index -lt $Snapshot.ReportedDeviceCount; $index++) {
        $d = $Snapshot.Devices[$index]
        if ($d.DeviceName -cne "Vulkan$index" -or
            $d.Description -cnotmatch '^[A-Za-z0-9 ._()+-]{1,96}$' -or
            $d.DriverName -cnotmatch '^[A-Za-z0-9 ._()+-]{1,96}$' -or
            $d.Description -cne $d.Description.Trim() -or
            ($null -ne $d.DeviceId -and $d.DeviceId -cnotmatch '^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$') -or
            $d.DeviceIdStatus -cnotin @('bdf-reported','unavailable','invalid-format') -or
            (($d.DeviceIdStatus -ceq 'bdf-reported') -ne ($null -ne $d.DeviceId)) -or
            $d.TotalMiB -isnot [long] -or $d.FreeMiB -isnot [long] -or
            $d.TotalMiB -lt 1 -or $d.TotalMiB -gt 1048576 -or
            $d.FreeMiB -lt 0 -or $d.FreeMiB -gt $d.TotalMiB -or
            $d.Uma -isnot [bool] -or $d.Fp16 -cnotin @('0','1','dot2') -or
            $d.Bf16 -isnot [bool] -or $d.Fp4 -isnot [bool] -or
            ($d.WarpSize -isnot [int] -and $d.WarpSize -isnot [long]) -or $d.WarpSize -lt 1 -or $d.WarpSize -gt 128 -or
            ($d.SharedMemoryBytes -isnot [int] -and $d.SharedMemoryBytes -isnot [long]) -or $d.SharedMemoryBytes -lt 1 -or $d.SharedMemoryBytes -gt 1048576 -or
            $d.IntegerDotProduct -isnot [bool] -or
            $d.MatrixCores -cnotin @('none','KHR_coopmat','NV_coopmat2v','NV_coopmat2')) {
            throw 'GGML capability worker returned an invalid device record.'
        }
    }
}
function ConvertFrom-GgmlCapabilityWorkerOutput {
    param([string]$Text,[bool]$Truncated)
    if ($Truncated -or $Text.Length -gt 32768) { throw 'GGML capability worker output exceeded its bound.' }
    $records = [regex]::Matches($Text, '(?m)^FASTLLM_GGML_CAPABILITY_JSON:([A-Za-z0-9+/=]{1,7468})\r?$')
    if ($records.Count -ne 1) { throw 'GGML capability worker returned missing or multiple records.' }
    $bytes = [Convert]::FromBase64String($records[0].Groups[1].Value)
    if ($bytes.Length -gt 5600) { throw 'GGML capability record exceeded its bound.' }
    $json = (New-Object Text.UTF8Encoding($false,$true)).GetString($bytes)
    $record = $json | ConvertFrom-Json -ErrorAction Stop
    if ($record.schemaVersion -ne 1 -or $record.kind -cne 'fastllm-private-ggml-vulkan-capability-worker' -or
        $record.qualified -ne $false -or $record.servingDeviceBinding -ne $false -or
        $record.modelLoaded -ne $false) { throw 'GGML capability worker record has invalid provenance.' }
    # JSON conversion yields Int64 for large values but Int32 for small ones.
    foreach ($device in @($record.snapshot.Devices)) {
        foreach ($field in @('TotalMiB','FreeMiB')) {
            if ($device.$field -is [int]) { $device.$field = [long]$device.$field }
        }
    }
    Assert-GgmlCapabilitySnapshot -Snapshot $record.snapshot
    return $record
}
function Get-GgmlCapabilityWorkerFailureCode {
    param([string]$Text)
    if ($Text.Length -gt 32768) { return 'output-excessive' }
    $matches = [regex]::Matches($Text, '(?m)^FASTLLM_GGML_CAPABILITY_ERROR:([^\r\n]{0,128})\r?$')
    if ($matches.Count -ne 1) { return 'no-unique-stage' }
    $code = [string]$matches[0].Groups[1].Value
    if ($code -cmatch '^(entry|identity|catalog|prerequisite|manifest|isolation|native-compile|native-read-(preloaded|search|directory|base-load|core-load|symbol|backend-register|callback-excess|count-duplicate|row-malformed|row-duplicate|set-incomplete|index-gap|registry-missing|props-mismatch|value-invalid|registry-extra|text-excess|memory-invalid|path-nonascii|other)|snapshot|integrity|record)$') { return $code }
    return 'no-unique-stage'
}
function Get-GgmlCapabilityNativeFailureCode {
    param([Exception]$Exception)
    # PowerShell wraps CLR method exceptions. Match only fixed literals from
    # our reviewed C# source; never return exception text or an OS error path.
    $fixed = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($pair in @(
        @('A GGML DLL was preloaded before the restricted diagnostic loader.','preloaded'),
        @('Could not restrict DLL search.','search'),
        @('Could not add verified engine directory.','directory'),
        @('Could not load verified GGML base.','base-load'),
        @('Could not load verified GGML core.','core-load'),
        @('Verified GGML Vulkan backend did not register.','backend-register'),
        @('GGML callback data was excessive or malformed.','callback-excess'),
        @('Duplicate GGML Vulkan device-count row.','count-duplicate'),
        @('Malformed GGML Vulkan capability row.','row-malformed'),
        @('Duplicate GGML Vulkan capability row.','row-duplicate'),
        @('GGML Vulkan callback did not provide a complete device set.','set-incomplete'),
        @('GGML Vulkan device indices are not contiguous.','index-gap'),
        @('GGML Vulkan capability device is absent from registry.','registry-missing'),
        @('GGML Vulkan device properties disagree with callback.','props-mismatch'),
        @('GGML Vulkan capability value is impossible.','value-invalid'),
        @('GGML Vulkan registry has more devices than callback.','registry-extra'),
        @('GGML diagnostic text exceeds its limit.','text-excess'),
        @('GGML device memory is invalid.','memory-invalid'),
        @('GGML diagnostic requires an ASCII-only engine path.','path-nonascii')
    )) { $fixed.Add([string]$pair[0],[string]$pair[1]) }
    $current = $Exception
    for ($depth = 0; $depth -lt 8 -and $null -ne $current; $depth++) {
        if ($fixed.ContainsKey($current.Message)) { return 'native-read-' + $fixed[$current.Message] }
        if ($current.Message -cmatch '^Required GGML ABI symbol is absent: (ggml_log_get|ggml_log_set|ggml_backend_load|ggml_backend_dev_by_name|ggml_backend_dev_get_props)$') {
            return 'native-read-symbol'
        }
        $current = $current.InnerException
    }
    return 'native-read-other'
}

function Invoke-GgmlVulkanCapabilities {
    param([Parameter(Mandatory=$true)][string]$InstallRoot,[string]$OutputPath,[bool]$AsWorker=$false,[string]$RunToken)
    if ($AsWorker) { $script:ggmlCapabilityWorkerStage = 'identity' }
    Assert-GgmlCapabilityStandardWindows
    if ($AsWorker) {
        # Accidental direct -Worker invocation is unsupported. This token is
        # not an authentication boundary against another process of this user.
        if ($RunToken -cnotmatch '^[0-9a-f]{32}$' -or
            $env:FASTLLM_GGML_CAPABILITY_RUN_TOKEN -cne $RunToken) {
            throw 'GGML capability worker requires its supervised parent invocation.'
        }
        $env:FASTLLM_GGML_CAPABILITY_RUN_TOKEN = $null
    }
    if (-not $AsWorker) { $reportPath = Assert-GgmlCapabilityOutputPath -Path $OutputPath }
    if ($AsWorker) { $script:ggmlCapabilityWorkerStage = 'catalog' }
    $repo = Split-Path $PSScriptRoot -Parent
    $catalogPath = Join-Path $repo 'config/catalog.json'
    $modulePath = Join-Path $repo 'src/FastLlm.psm1'
    $nativeSource = Join-Path $repo 'src/WindowsGgmlVulkanCapabilities.cs'
    $hostSource = Join-Path $repo 'src/ProcessHost.cs'
    $workerSource = $PSCommandPath
    $catalogHash = (Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($catalogHash -cne '65b8f2f9ca340dab273274086aba9e8f01cb14a2b8cf4bb65c5ed5f6e779caa6') {
        throw 'Private GGML capability worker requires its reviewed catalog digest.'
    }
    $moduleHash = (Get-FileHash -LiteralPath $modulePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $nativeSourceHash = (Get-FileHash -LiteralPath $nativeSource -Algorithm SHA256).Hash.ToLowerInvariant()
    $hostSourceHash = (Get-FileHash -LiteralPath $hostSource -Algorithm SHA256).Hash.ToLowerInvariant()
    $workerSourceHash = (Get-FileHash -LiteralPath $workerSource -Algorithm SHA256).Hash.ToLowerInvariant()
    $module = Import-Module $modulePath -PassThru -Force -DisableNameChecking -ErrorAction Stop
    if ($AsWorker) { $script:ggmlCapabilityWorkerStage = 'prerequisite' }
    & $module { Assert-FastLlmWindowsPrerequisites }
    if ($AsWorker) { $script:ggmlCapabilityWorkerStage = 'manifest' }
    $catalog = Get-FastLlmCatalog -CatalogPath $catalogPath
    $asset = $catalog.engine.assets.vulkan
    if ($catalog.engine.version -cne 'b10698' -or $asset.enabled -ne $true -or
        $asset.entryPoint -cne 'llama-server.exe' -or
        $asset.sha256 -cne '31e2fe70d4864a4ae6a4e7d8e102ee9203ba18963077e7727c54f9bd6ae3bea5' -or
        -not (Test-FastLlmEngineInstallation -InstallRoot $InstallRoot -EngineVersion 'b10698' -BackendKey 'vulkan' -Asset $asset)) {
        throw 'Pinned Vulkan engine failed its exact reviewed manifest.'
    }
    $server = Get-FastLlmEngineExecutable -InstallRoot $InstallRoot -EngineVersion 'b10698' -BackendKey 'vulkan'
    $engineRoot = Split-Path -Parent $server
    $serverHash = (Get-FileHash -LiteralPath $server -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($AsWorker) {
        $script:ggmlCapabilityWorkerStage = 'isolation'
        $windowsRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
        $system32 = [Environment]::GetFolderPath([Environment+SpecialFolder]::System)
        $sandbox = Join-Path ([IO.Path]::GetTempPath()) ('FastLlm-GgmlCapability-' + $RunToken)
        $sandboxItem = Get-Item -LiteralPath $sandbox -Force -ErrorAction Stop
        if (-not $sandboxItem.PSIsContainer -or ($sandboxItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            $env:APPDATA -cne $sandbox -or $env:PROGRAMDATA -cne $sandbox -or
            $env:PATH -cne "$engineRoot;$system32;$windowsRoot") {
            throw 'GGML capability worker did not receive its isolated environment.'
        }
        foreach ($name in @([Environment]::GetEnvironmentVariables().Keys)) {
            if ((& $module {param($value) Test-FastLlmEnvironmentNameRequiresClearing -Name $value} ([string]$name)) -or
                ([string]$name) -like 'VULKAN_*' -or ([string]$name) -like 'AMD_VULKAN_*') {
                throw 'GGML capability worker received a native override variable.'
            }
        }
        $script:ggmlCapabilityWorkerStage = 'native-compile'
        Add-Type -Path $nativeSource -ErrorAction Stop
        $script:ggmlCapabilityWorkerStage = 'native-read'
        $snapshot = [Bitworks.FastLlm.WindowsGgmlVulkanCapabilities]::Read($engineRoot)
        $script:ggmlCapabilityWorkerStage = 'snapshot'
        Assert-GgmlCapabilitySnapshot -Snapshot $snapshot
        $script:ggmlCapabilityWorkerStage = 'integrity'
        if (-not (Test-FastLlmEngineInstallation -InstallRoot $InstallRoot -EngineVersion 'b10698' -BackendKey 'vulkan' -Asset $asset) -or
            (Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $catalogHash -or
            (Get-FileHash -LiteralPath $nativeSource -Algorithm SHA256).Hash.ToLowerInvariant() -cne $nativeSourceHash -or
            (Get-FileHash -LiteralPath $workerSource -Algorithm SHA256).Hash.ToLowerInvariant() -cne $workerSourceHash) {
            throw 'GGML capability inputs changed within worker.'
        }
        $script:ggmlCapabilityWorkerStage = 'record'
        $record = [ordered]@{schemaVersion=1;kind='fastllm-private-ggml-vulkan-capability-worker';
            qualified=$false;servingDeviceBinding=$false;modelLoaded=$false;snapshot=$snapshot}
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($record | ConvertTo-Json -Compress -Depth 7))
        if ($bytes.Length -gt 5600) { throw 'GGML capability record exceeded its bound.' }
        [Console]::Out.WriteLine('FASTLLM_GGML_CAPABILITY_JSON:' + [Convert]::ToBase64String($bytes))
        return
    }
    if (-not ('Bitworks.FastLlm.ProcessHost' -as [type])) { Add-Type -Path $hostSource -ErrorAction Stop }
    $sandbox = Join-Path ([IO.Path]::GetTempPath()) ('FastLlm-GgmlCapability-' + [Guid]::NewGuid().ToString('N'))
    $runToken = [IO.Path]::GetFileName($sandbox).Substring('FastLlm-GgmlCapability-'.Length)
    New-Item -ItemType Directory -Path $sandbox -ErrorAction Stop | Out-Null
    $child = $null
    $startedUtc = [DateTime]::UtcNow.ToString('o')
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $child = New-Object Bitworks.FastLlm.ProcessHost
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = (Get-Process -Id $PID).Path
        $args = @('-NoLogo','-NoProfile','-NonInteractive','-OutputFormat','Text','-ExecutionPolicy','RemoteSigned',
            '-File',$workerSource,'-InstallRoot',$InstallRoot,'-Worker','-WorkerToken',$runToken)
        $info.Arguments = & $module {param($items) Join-FastLlmProcessArguments -Arguments $items} $args
        $info.WorkingDirectory = $repo
        foreach ($name in @($info.EnvironmentVariables.Keys)) {
            $key = [string]$name
            if ((& $module {param($value) Test-FastLlmEnvironmentNameRequiresClearing -Name $value} $key) -or
                $key -like 'VULKAN_*' -or $key -like 'AMD_VULKAN_*') {
                $info.EnvironmentVariables.Remove($key)
            }
        }
        $windowsRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
        $system32 = [Environment]::GetFolderPath([Environment+SpecialFolder]::System)
        if (-not $windowsRoot -or -not $system32) { throw 'Windows loader directories are unavailable.' }
        $info.EnvironmentVariables['APPDATA'] = $sandbox
        $info.EnvironmentVariables['PROGRAMDATA'] = $sandbox
        $info.EnvironmentVariables['PATH'] = "$engineRoot;$system32;$windowsRoot"
        $info.EnvironmentVariables['FASTLLM_GGML_CAPABILITY_RUN_TOKEN'] = $runToken
        $child.Start($info)
        while ($watch.ElapsedMilliseconds -lt 20000) {
            if ($child.Process.WaitForExit(100)) { break }
        }
        if (-not $child.Process.HasExited) { throw 'GGML capability worker exceeded 20 seconds.' }
        $exitCode = $child.Process.ExitCode
        while (-not $child.OutputCompleted -and $watch.ElapsedMilliseconds -lt 20000) { Start-Sleep -Milliseconds 20 }
        if (-not $child.OutputCompleted) { throw 'GGML capability worker failed: output-incomplete.' }
        if ($child.OutputTruncated) { throw 'GGML capability worker failed: output-truncated.' }
        if ($exitCode -ne 0) {
            $code = Get-GgmlCapabilityWorkerFailureCode -Text ($child.Snapshot())
            throw "GGML capability worker failed: $code."
        }
        $record = ConvertFrom-GgmlCapabilityWorkerOutput -Text ($child.Snapshot()) -Truncated $child.OutputTruncated
    } finally {
        if ($child) { $child.Dispose() }
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-FastLlmEngineInstallation -InstallRoot $InstallRoot -EngineVersion 'b10698' -BackendKey 'vulkan' -Asset $asset) -or
        (Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $catalogHash -or
        (Get-FileHash -LiteralPath $modulePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $moduleHash -or
        (Get-FileHash -LiteralPath $nativeSource -Algorithm SHA256).Hash.ToLowerInvariant() -cne $nativeSourceHash -or
        (Get-FileHash -LiteralPath $hostSource -Algorithm SHA256).Hash.ToLowerInvariant() -cne $hostSourceHash -or
        (Get-FileHash -LiteralPath $workerSource -Algorithm SHA256).Hash.ToLowerInvariant() -cne $workerSourceHash -or
        (Get-FileHash -LiteralPath $server -Algorithm SHA256).Hash.ToLowerInvariant() -cne $serverHash) {
        throw 'GGML capability inputs changed during diagnostic.'
    }
    $report = [ordered]@{
        schemaVersion=1;kind='fastllm-private-ggml-vulkan-capabilities'
        startedUtc=$startedUtc;completedUtc=[DateTime]::UtcNow.ToString('o')
        catalogSha256=$catalogHash;moduleSourceSha256=$moduleHash;engineArchiveSha256=[string]$asset.sha256
        engineExecutableSha256=$serverHash;nativeSourceSha256=$nativeSourceHash
        collectorSourceSha256=$workerSourceHash;processHostSourceSha256=$hostSourceHash
        source='pinned-b10698-ggml-log-callback-independent-worker'
        isolation='standard-user-targeted-clean-environment-and-restricted-dll-search'
        snapshot=$record.snapshot
        qualified=$false;servingDeviceBinding=$false;driverBinaryBinding=$false
        modelLoaded=$false;performanceQualification=$false
    }
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($report | ConvertTo-Json -Compress -Depth 8))
    if ($bytes.Length -gt 32768) { throw 'GGML capability report exceeded its bound.' }
    $stream = [IO.File]::Open($reportPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush() }
    finally { $stream.Dispose() }
    return $reportPath
}

if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($InstallRoot) -or (-not $Worker -and [string]::IsNullOrWhiteSpace($OutputPath))) {
        throw 'Specify -InstallRoot and, unless -Worker, a fresh absolute -OutputPath.'
    }
    try {
        Invoke-GgmlVulkanCapabilities -InstallRoot $InstallRoot -OutputPath $OutputPath -AsWorker:$Worker -RunToken $WorkerToken
    } catch {
        if ($Worker) {
            # Never relay exception messages, paths, loader errors, or native text.
            if ($script:ggmlCapabilityWorkerStage -ceq 'native-read') {
                $script:ggmlCapabilityWorkerStage = Get-GgmlCapabilityNativeFailureCode -Exception $_.Exception
            }
            [Console]::Error.WriteLine('FASTLLM_GGML_CAPABILITY_ERROR:' + $script:ggmlCapabilityWorkerStage)
            exit 1
        }
        throw
    }
}
