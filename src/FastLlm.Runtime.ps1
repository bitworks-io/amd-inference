# Loaded into FastLlm.psm1. These are lifecycle utilities, not another inference engine.
function Initialize-FastLlmProcessHost {
    if (-not ('Bitworks.FastLlm.ProcessHost' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'ProcessHost.cs') -ErrorAction Stop
    }
}

function Get-FastLlmWindowsInventory {
    [CmdletBinding()]
    param()
    if ($env:OS -ne 'Windows_NT') { return [pscustomobject]@{ applicable=$false; qualified=$false } }
    Initialize-FastLlmProcessHost
    $child = New-Object Bitworks.FastLlm.ProcessHost
    try {
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = (Get-Process -Id $PID).Path
        $info.Arguments = Join-FastLlmProcessArguments @('-NoLogo','-NoProfile','-NonInteractive','-OutputFormat','Text','-File',(Join-Path $PSScriptRoot 'WindowsInventory.ps1'))
        $deadline = [Diagnostics.Stopwatch]::StartNew()
        $child.Start($info)
        $remaining = [Math]::Max(1, 30000 - [int]$deadline.ElapsedMilliseconds)
        if (-not $child.Process.WaitForExit($remaining)) { throw 'Windows inventory exceeded its 30-second deadline.' }
        while (-not $child.OutputCompleted) {
            if ($deadline.ElapsedMilliseconds -ge 30000) { throw 'Windows inventory output exceeded its 30-second deadline.' }
            Start-Sleep -Milliseconds 20
        }
        if ($child.OutputTruncated) { throw 'Windows inventory output was truncated.' }
        if ($child.Process.ExitCode -ne 0) { throw 'Windows DXGI/PNP inventory probe failed.' }
        $output = $child.Snapshot()
        if (-not $output -or $output.Length -gt 65536) { throw 'Windows inventory output was missing or oversized.' }
        $inventory = ConvertFrom-Json -InputObject $output -ErrorAction Stop
        if (-not $inventory -or $inventory.applicable -ne $true -or $inventory.qualified -ne $false -or
            -not $inventory.PSObject.Properties['nativeHost'] -or -not $inventory.nativeHost -or
            $inventory.nativeHost.schemaVersion -ne 1 -or
            $inventory.nativeHost.kind -ne 'windows-native-host-inventory' -or
            $inventory.nativeHost.qualified -ne $false -or
            $inventory.nativeHost.status -notin @('captured','partial','unavailable')) {
            throw 'Windows inventory output did not match its diagnostic schema.'
        }
        $nativeHost = $inventory.nativeHost
        if (-not $nativeHost.physicalMemoryBytes -or
            $nativeHost.physicalMemoryBytes.source -ne 'GlobalMemoryStatusEx.ullTotalPhys' -or
            $nativeHost.physicalMemoryBytes.status -notin @('captured','unavailable') -or
            -not $nativeHost.activeLogicalProcessors -or
            $nativeHost.activeLogicalProcessors.source -ne 'GetActiveProcessorCount.ALL_PROCESSOR_GROUPS' -or
            $nativeHost.activeLogicalProcessors.status -notin @('captured','unavailable') -or
            -not $nativeHost.os -or $nativeHost.os.versionSource -ne 'RtlGetVersion' -or
            $nativeHost.os.ubrSource -ne 'HKLM.CurrentVersion.UBR' -or
            $nativeHost.os.architectureSource -ne 'GetNativeSystemInfo' -or
            $nativeHost.os.status -notin @('captured','partial','unavailable') -or
            -not $nativeHost.advisory -or -not $nativeHost.advisory.cpuNames -or
            $nativeHost.advisory.cpuNames.source -ne 'HKLM.HARDWARE.CentralProcessor.ProcessorNameString' -or
            $nativeHost.advisory.cpuNames.status -notin @('captured','partial','unavailable') -or
            $nativeHost.advisory.cpuNames.scanLimit -ne 256 -or
            -not $nativeHost.advisory.systemManufacturer -or -not $nativeHost.advisory.systemProductName) {
            throw 'Windows inventory native host fields did not match their diagnostic schema.'
        }
        if ($nativeHost.status -eq 'captured' -and
            ($nativeHost.physicalMemoryBytes.status -ne 'captured' -or
             $nativeHost.activeLogicalProcessors.status -ne 'captured' -or
             $nativeHost.os.status -ne 'captured')) {
            throw 'Windows inventory native host completeness was inconsistent.'
        }
        if ($deadline.ElapsedMilliseconds -ge 30000) { throw 'Windows inventory exceeded its 30-second deadline.' }
        return $inventory
    } finally { $child.Dispose() }
}

function Get-FastLlmStateRoot {
    param([string] $InstallRoot, [switch] $Create)
    $root = [IO.Path]::GetFullPath($InstallRoot)
    $state = Join-FastLlmContainedPath -Root $root -Child 'state'
    foreach ($path in @($root, $state)) {
        if (Test-Path -LiteralPath $path) {
            $item = Get-Item -LiteralPath $path -Force
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe runtime state directory.' }
        }
    }
    if ($Create) { New-Item -ItemType Directory -Path $state -Force | Out-Null }
    return $state
}

function Write-FastLlmState {
    param([string] $InstallRoot, $State, [string] $FileName='status.json')
    Assert-FastLlmLeafName -Value $FileName -Label 'State file name'
    $root = Get-FastLlmStateRoot -InstallRoot $InstallRoot -Create
    $path = Join-Path $root $FileName
    if (Test-Path -LiteralPath $path) {
        if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Unsafe status path.' }
    }
    $temporary = Join-Path $root ([Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $State | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporary -Encoding UTF8
        Move-Item -LiteralPath $temporary -Destination $path -Force
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Get-FastLlmRecoveryPlan {
    param($Hardware,[string]$CatalogPath,[string]$InstallRoot,[string]$Profile,[string]$FailedModelId,[string]$RequestedModelId,[int]$ContextSize=0)
    # An explicit artifact is never substituted. Recovery never downloads or grants consent.
    if ($RequestedModelId) { return $null }
    $key=Get-FastLlmFingerprint $Hardware
    $path=Join-Path (Get-FastLlmStateRoot $InstallRoot) ($key+'.last-ready.json')
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)){return $null}
    try{
        $item=Get-Item -LiteralPath $path -Force
        if($item.Length -gt 16384 -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){return $null}
        $record=Read-FastLlmJson $path
        if($record.kind -ne 'api-smoke-only' -or $record.hardwareFingerprint -ne $key -or $record.modelId -eq $FailedModelId){return $null}
        $digest=(Get-FileHash -LiteralPath $CatalogPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if($record.catalogSha256 -ne $digest){return $null}
        $plan=Get-FastLlmPlan -Hardware $Hardware -CatalogPath $CatalogPath -InstallRoot $InstallRoot -Profile $Profile -ModelId $record.modelId -ContextSize $ContextSize
        if($plan.model.sha256 -ne $record.modelSha256 -or -not (Test-Path -LiteralPath $plan.modelPath -PathType Leaf) -or -not (Test-FastLlmModelConsentReceipt $plan.model $InstallRoot)){return $null}
        return $plan
    }catch{return $null}
}

function Enter-FastLlmOperation {
    param([string] $InstallRoot)
    $root = Get-FastLlmStateRoot -InstallRoot $InstallRoot -Create
    $path = Join-Path $root 'operation.lock'
    if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe lock path.' }
    try { return [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { throw 'Another FastLLM install/start operation is active for this installation.' }
    # Keep the lock file: unlinking it after close introduces an acquisition race.
}

function Get-FastLlmStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string] $InstallRoot)
    $root = Get-FastLlmStateRoot -InstallRoot $InstallRoot
    $path = Join-Path $root 'status.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return [pscustomobject]@{ phase='stopped'; active=$false } }
    $item = Get-Item -LiteralPath $path -Force
    if ($item.Length -gt 65536 -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe status document.' }
    $state = Read-FastLlmJson -Path $path
    $active = $false
    $lockPath = Join-Path $root 'operation.lock'
    if (Test-Path -LiteralPath $lockPath) {
        if ((Get-Item -LiteralPath $lockPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Unsafe lock path.' }
        $lock = $null
        try { $lock = [IO.File]::Open($lockPath, 'Open', 'ReadWrite', 'None') }
        catch { $active = $true }
        finally { if ($lock) { $lock.Dispose() } }
    }
    $state | Add-Member -NotePropertyName active -NotePropertyValue $active -Force
    if (-not $active -and $state.phase -in @('preparing','loading','checking','ready')) { $state.phase = 'interrupted' }
    return $state
}

function Request-FastLlmStop {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string] $InstallRoot)
    $state = Get-FastLlmStatus -InstallRoot $InstallRoot
    if (-not $state.active -or $state.phase -notin @('loading','checking','ready') -or -not $state.PSObject.Properties['runId'] -or $state.runId -notmatch '^[0-9a-f]{32}$') { throw 'There is no supervised server to stop. Cancel an in-progress installation in its owning window.' }
    $root = Get-FastLlmStateRoot -InstallRoot $InstallRoot
    $path = Join-Path $root ('stop-' + $state.runId)
    if (Test-Path -LiteralPath $path) {
        if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Unsafe stop request path.' }
    } else {
        $stream = [IO.File]::Open($path, 'CreateNew', 'Write', 'None')
        $stream.Dispose()
    }
    Write-Host 'Stop requested. The owning supervisor will terminate its own server.'
}

function ConvertFrom-FastLlmPlacementLog {
    [CmdletBinding()]
    param([string] $Text, [string[]] $Devices)
    $offloads = [regex]::Matches($Text, '(?m)^.*load_tensors: offloaded (\d+)/(\d+) layers to GPU\s*$')
    if ($offloads.Count -ne 1) { throw 'Missing or ambiguous layer-offload evidence.' }
    $loaded = [int] $offloads[0].Groups[1].Value
    $total = [int] $offloads[0].Groups[2].Value
    if ($total -le 0 -or $loaded -ne $total) { throw 'The engine did not report all model layers on GPU.' }
    $buffers = [regex]::Matches($Text, '(?m)^.*load_tensors:\s+(Vulkan\d+|ROCm\d+)\s+model buffer size\s*=\s*([0-9.]+) MiB\s*$')
    $reportedBuffers=@()
    foreach ($buffer in $buffers) {
        $size = [double]::Parse($buffer.Groups[2].Value, [Globalization.CultureInfo]::InvariantCulture)
        if ($size -le 0 -or [double]::IsInfinity($size) -or [double]::IsNaN($size)) { throw 'GPU model-buffer evidence must be positive and finite.' }
        $reportedBuffers+= [pscustomobject]@{device=$buffer.Groups[1].Value;sizeMiB=$size}
    }
    $reported = @($reportedBuffers | ForEach-Object { $_.device } | Select-Object -Unique)
    if($reported.Count -ne $buffers.Count){throw 'Duplicate GPU model-buffer evidence is ambiguous.'}
    if (@($Devices | Where-Object { $_ -notin $reported }).Count -or @($reported | Where-Object { $_ -notin $Devices }).Count) { throw 'Reported model-buffer devices do not match the selected devices.' }
    return [pscustomobject]@{ reportedLayers=$loaded; totalLayers=$total; devices=$reported; modelBufferMiB=$reportedBuffers; reportedAllLayers=$true; physicalResidencyVerified=$false }
}

function ConvertFrom-FastLlmStartupDiagnostics {
    [CmdletBinding()]
    param([string]$Text,[bool]$Overflow=$false,[string]$RequestedFlashAttention)
    $result=[ordered]@{
        status='missing';kvBuffers=@();computeBuffers=@()
        requestedFlashAttention=$RequestedFlashAttention
        reportedFlashAttentionMode=$null;reportedFlashAttentionResolved=$null
        allocationCoverage='partial: model, KV and compute buffer lines only; recurrent/state and other allocations are not captured'
        physicalResidencyVerified=$false
    }
    if($Overflow){$result.status='overflow';return [pscustomobject]$result}
    if([string]::IsNullOrWhiteSpace($Text)){return [pscustomobject]$result}
    if($Text.Length -gt 4096){$result.status='invalid';return [pscustomobject]$result}
    $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $kv=@();$compute=@();$flashMode=$null;$flashResolved=$null
    $lines=@($Text -split "`r?`n" | Where-Object { $_ })
    if($lines.Count -gt 32){$result.status='overflow';return [pscustomobject]$result}
    foreach($line in $lines){
        $kind=$null;$device=$null;$value=$null
        if($line -cmatch '^(kv|compute) (Vulkan\d+|ROCm\d+|CPU(?:_[A-Za-z0-9]+)?) ([0-9]+(?:\.[0-9]+)?)$'){
            $kind=$Matches[1];$device=$Matches[2]
            if(-not $seen.Add("$kind|$device")){$result.status='duplicate';return [pscustomobject]$result}
            $numeric=$Matches[3]
            $value=[double]0
            if($numeric.Length -gt 32 -or
                -not [double]::TryParse($numeric,[Globalization.NumberStyles]::AllowDecimalPoint,[Globalization.CultureInfo]::InvariantCulture,[ref]$value) -or
                $value -le 0 -or [double]::IsNaN($value) -or [double]::IsInfinity($value)){$result.status='invalid';return [pscustomobject]$result}
            $entry=[pscustomobject]@{device=$device;sizeMiB=$value}
            if($kind -eq 'kv'){$kv+= $entry}else{$compute+= $entry}
        }elseif($line -cmatch '^flash-mode (auto|enabled|disabled)$'){
            if(-not $seen.Add('flash-mode')){$result.status='duplicate';return [pscustomobject]$result}
            $flashMode=$Matches[1]
        }elseif($line -cmatch '^flash-resolved (enabled|disabled)$'){
            if(-not $seen.Add('flash-resolved')){$result.status='duplicate';return [pscustomobject]$result}
            $flashResolved=($Matches[1] -eq 'enabled')
        }else{$result.status='invalid';return [pscustomobject]$result}
    }
    # b10698 resolves Flash Attention support only for auto mode. An explicit
    # enabled/disabled mode paired with a resolution line is inconsistent.
    if($null -ne $flashResolved -and $flashMode -ne 'auto'){$result.status='invalid';return [pscustomobject]$result}
    $result.kvBuffers=$kv
    $result.computeBuffers=$compute
    $result.reportedFlashAttentionMode=$flashMode
    $result.reportedFlashAttentionResolved=$flashResolved
    $result.status='partial'
    if($result.kvBuffers.Count -and $result.computeBuffers.Count -and $null -ne $result.reportedFlashAttentionMode -and $null -ne $result.reportedFlashAttentionResolved){$result.status='captured'}
    return [pscustomobject]$result
}

function Invoke-FastLlmHttp {
    param([string] $BaseUrl, [string] $Path, $Body, [int] $TimeoutMs=5000)
    Initialize-FastLlmProcessHost
    $json = if ($null -ne $Body) { ConvertTo-Json -InputObject $Body -Depth 12 -Compress } else { $null }
    return [Bitworks.FastLlm.LoopbackHttp]::Request($BaseUrl + $Path, $json, $TimeoutMs, 1048576)
}

function Test-FastLlmApiCanary {
    [CmdletBinding()]
    param([string] $BaseUrl, [string] $ModelId, [int] $ContextSize)
    $models = Invoke-FastLlmHttp -BaseUrl $BaseUrl -Path '/v1/models'
    if ($models.Status -ne 200 -or @((ConvertFrom-Json $models.Body).data | Where-Object { $_.id -eq $ModelId }).Count -ne 1) { throw 'Served model identity does not match the plan.' }
    $props = Invoke-FastLlmHttp -BaseUrl $BaseUrl -Path '/props'
    if ($props.Status -ne 200) { throw 'Server properties are unavailable.' }
    $properties = ConvertFrom-Json $props.Body
    if ([int]$properties.default_generation_settings.n_ctx -ne $ContextSize -or [int]$properties.total_slots -ne 1) { throw 'Effective context/slots differ from the requested configuration.' }
    $firstToken = $null
    for ($i=0; $i -lt 2; $i++) {
        $answer = Invoke-FastLlmHttp -BaseUrl $BaseUrl -Path '/completion' -TimeoutMs 30000 -Body @{
            prompt='The capital of France is'; n_predict=1; temperature=0; seed=42; cache_prompt=$false; return_tokens=$true; ignore_eos=$true; stream=$false
        }
        if ($answer.Status -ne 200) { throw 'One-token inference canary failed.' }
        $data = ConvertFrom-Json $answer.Body
        if (@($data.tokens).Count -ne 1 -or [long]$data.tokens[0] -lt 0) { throw 'One-token canary returned an invalid token.' }
        if ($i -eq 0) { $firstToken = [long]$data.tokens[0] }
        elseif ([long]$data.tokens[0] -ne $firstToken) { throw 'Greedy one-token canary was not repeatable.' }
    }
    $chat = Invoke-FastLlmHttp -BaseUrl $BaseUrl -Path '/v1/chat/completions' -TimeoutMs 30000 -Body @{
        model=$ModelId; messages=@(@{role='user';content='Say hello.'}); max_tokens=8; temperature=0; seed=42; stream=$false
    }
    if ($chat.Status -ne 200) { throw 'Synchronous OpenAI chat canary failed.' }
    $chatData = ConvertFrom-Json $chat.Body
    if (@($chatData.choices).Count -ne 1) { throw 'Synchronous chat returned an invalid choice count.' }
    $message = $chatData.choices[0].message
    if ($message.role -ne 'assistant') { throw 'Synchronous chat returned an invalid role.' }
    $chatText = $false
    foreach ($key in @('content','reasoning_content','reasoning')) {
        $property = $message.PSObject.Properties[$key]
        if ($property -and -not [string]::IsNullOrEmpty([string]$property.Value)) { $chatText=$true }
    }
    if (-not $chatText) { throw 'Synchronous chat returned no text.' }
    $stream = Invoke-FastLlmHttp -BaseUrl $BaseUrl -Path '/v1/chat/completions' -TimeoutMs 30000 -Body @{
        model=$ModelId; messages=@(@{role='user';content='Say hello.'}); max_tokens=8; temperature=0; seed=42; stream=$true
    }
    if ($stream.Status -ne 200) { throw 'OpenAI streaming canary failed.' }
    $hasText = $false; $done = $false
    foreach ($line in ($stream.Body -split "`r?`n")) {
        if ($line -eq 'data: [DONE]') { $done=$true; continue }
        if ($line.StartsWith('data: ')) {
            $event = $line.Substring(6) | ConvertFrom-Json
            foreach ($choice in @($event.choices)) {
                foreach ($key in @('content','reasoning_content','reasoning')) {
                    $property = $choice.delta.PSObject.Properties[$key]
                    if ($property -and -not [string]::IsNullOrEmpty([string]$property.Value)) { $hasText=$true }
                }
            }
        }
    }
    if (-not $done -or -not $hasText) { throw 'Streaming canary lacked text or its completion marker.' }
    return [pscustomobject]@{ modelIdentity=$true; effectiveContext=$ContextSize; repeatableToken=$true; synchronousChat=$true; streaming=$true; semanticCorrectnessQualified=$false }
}

function Invoke-FastLlmSupervisedServer {
    param($Plan, [string] $InstallRoot, [int] $LoadTimeoutSeconds=300, [string] $CatalogPath)
    Initialize-FastLlmProcessHost
    $state = [ordered]@{ schemaVersion=1; runId=[Guid]::NewGuid().ToString('N'); phase='loading'; updatedAt=(Get-Date).ToUniversalTime().ToString('o'); modelId=$Plan.model.id; endpoint=$Plan.endpoint; hardwareFingerprint=$Plan.hardwareFingerprint; engineVersion=$Plan.engineVersion; modelSha256=$Plan.model.sha256; canary=$null; placement=$null; startupDiagnostics=$null; selectedDeviceCapture=$null; selectedDeviceIdentity=$null; failureCode=$null; performanceQualified=$false; recipe=$null; processIdentity=$null }
    if ($Plan.PSObject.Properties['catalogVersion']) {
        if (-not $CatalogPath) { throw 'A real runtime recipe requires the verified catalog path.' }
        $state.recipe = [ordered]@{
            catalogVersion=$Plan.catalogVersion; catalogSha256=(Get-FileHash -LiteralPath $CatalogPath -Algorithm SHA256).Hash.ToLowerInvariant()
            engineSha256=(Get-FileHash -LiteralPath $Plan.enginePath -Algorithm SHA256).Hash.ToLowerInvariant()
            backend=$Plan.backend; contextSize=$Plan.model.contextSize; slots=$Plan.model.parallel
            cacheTypeK=$Plan.model.cacheTypeK; cacheTypeV=$Plan.model.cacheTypeV; speculation='none'; flashAttention='auto'
            splitMode=$Plan.splitMode; tensorSplit=$Plan.tensorSplit; adapters=$Plan.selectedAdapters
            requestedArguments=@($Plan.serverArguments | ForEach-Object { if ($_ -eq $Plan.modelPath) { '<verified-model>' } else { $_ } })
            configurationIsolation='empty-per-run-config-roots-and-targeted-environment-sanitization'
        }
    }
    $stateRoot = Get-FastLlmStateRoot -InstallRoot $InstallRoot -Create
    $stopPath = Join-Path $stateRoot ('stop-' + $state.runId)
    $sandbox = New-FastLlmRuntimeSandbox -InstallRoot $InstallRoot
    $hostProcess = New-Object Bitworks.FastLlm.ProcessHost
    $spawned = $false
    $baseUrl = $Plan.endpoint -replace '/v1$', ''
    try {
        # Refuse an already occupied port. A same-user bind race after this check remains possible.
        $uri = [Uri]$baseUrl
        $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $uri.Port)
        try { $listener.Server.ExclusiveAddressUse=$true; $listener.Start() }
        finally { $listener.Stop() }
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $Plan.enginePath
        $info.Arguments = Join-FastLlmProcessArguments -Arguments $Plan.serverArguments
        $info.WorkingDirectory = Split-Path -Parent $Plan.enginePath
        foreach ($name in @($info.EnvironmentVariables.Keys)) { if (Test-FastLlmEnvironmentNameRequiresClearing $name) { $info.EnvironmentVariables.Remove($name) } }
        $info.EnvironmentVariables['APPDATA'] = $sandbox.appData
        $info.EnvironmentVariables['PROGRAMDATA'] = $sandbox.programData
        if ($env:OS -eq 'Windows_NT') { $info.EnvironmentVariables['PATH'] = "$($info.WorkingDirectory);$env:SystemRoot\System32;$env:SystemRoot" }
        Write-FastLlmState -InstallRoot $InstallRoot -State $state
        $hostProcess.Start($info)
        $spawned = $true
        # Record only the actual supervised child identity, never a discovered
        # listener guess. This remains present through checking/ready/final state.
        $state.processIdentity = [ordered]@{
            pid=[int]$hostProcess.Process.Id
            startUtcTicks=[long]$hostProcess.Process.StartTime.ToUniversalTime().Ticks
        }
        $state.updatedAt=(Get-Date).ToUniversalTime().ToString('o')
        Write-FastLlmState -InstallRoot $InstallRoot -State $state
        $deadline = [Diagnostics.Stopwatch]::StartNew()
        $healthy = $false
        while ($deadline.Elapsed.TotalSeconds -lt $LoadTimeoutSeconds) {
            if (Test-Path -LiteralPath $stopPath) { $state.phase='stopped'; return 0 }
            if ($hostProcess.Process.HasExited) { throw 'Server exited before readiness.' }
            try { $health=Invoke-FastLlmHttp -BaseUrl $baseUrl -Path '/health' -TimeoutMs 1000; $healthy=$health.Status -eq 200 -and (ConvertFrom-Json $health.Body).status -eq 'ok' } catch { $healthy=$false }
            if ($healthy) { break }
            Start-Sleep -Milliseconds 200
        }
        if (-not $healthy) { throw 'Model-load readiness deadline exceeded.' }
        # Freeze before API canaries so no prompt/completion-related server lines
        # can enter the allowlisted startup-only diagnostic capture.
        $startupText=$hostProcess.FreezeStartupDiagnostics()
        $requestedFlashAttention=if($state.recipe){$state.recipe.flashAttention}else{$null}
        $state.startupDiagnostics=ConvertFrom-FastLlmStartupDiagnostics -Text $startupText -Overflow $hostProcess.StartupDiagnosticsOverflow -RequestedFlashAttention $requestedFlashAttention
        # Freeze same-child device selection before any API canary can cause
        # prompt-related output. This advisory never changes the Ready gate.
        $selectedDeviceText=$hostProcess.FreezeSelectedDeviceIdentity()
        $state.selectedDeviceCapture=[ordered]@{
            likeLines=[int]$hostProcess.SelectedDeviceLikeLines
            malformedLines=[int]$hostProcess.SelectedDeviceMalformedLines
            overflow=[bool]$hostProcess.SelectedDeviceIdentityOverflow
            diagnostics=[string]$hostProcess.SelectedDeviceIdentityDiagnostics()
        }
        $state.selectedDeviceIdentity=ConvertFrom-FastLlmSelectedDeviceIdentity -Text $selectedDeviceText -ExpectedDevices @($Plan.selectedAdapters.device) -LikeLines $state.selectedDeviceCapture.likeLines -MalformedLines $state.selectedDeviceCapture.malformedLines -Overflow $state.selectedDeviceCapture.overflow
        $state.phase='checking'; $state.updatedAt=(Get-Date).ToUniversalTime().ToString('o')
        Write-FastLlmState -InstallRoot $InstallRoot -State $state
        # Capture only normalized placement lines as they arrive. The general
        # process log is a bounded tail and may evict early model-load evidence.
        $placementText = $hostProcess.PlacementSnapshot()
        try {
            if ($hostProcess.PlacementOverflow) { throw 'GPU placement capture exceeded its bounded limit.' }
            $state.placement = ConvertFrom-FastLlmPlacementLog -Text $placementText -Devices @($Plan.selectedAdapters.device)
        }
        catch {
            Write-Host "GPU placement diagnostics: $($hostProcess.PlacementDiagnostics())"
            $safeLines = @($placementText -split "`r?`n" | Where-Object { $_ } | Select-Object -First 16)
            if ($safeLines.Count) { Write-Host ('GPU placement evidence: ' + ($safeLines -join ' | ')) }
            throw
        }
        $state.canary = Test-FastLlmApiCanary -BaseUrl $baseUrl -ModelId $Plan.model.id -ContextSize $Plan.model.contextSize
        if ($hostProcess.Process.HasExited) { throw 'Server exited during canary.' }
        $hostProcess.DiscardOutput()
        $state.phase='ready'; $state.updatedAt=(Get-Date).ToUniversalTime().ToString('o')
        Write-FastLlmState -InstallRoot $InstallRoot -State $state
        if ($state.recipe) {
            Write-FastLlmState -InstallRoot $InstallRoot -FileName ($Plan.hardwareFingerprint+'.last-ready.json') -State ([ordered]@{
                kind='api-smoke-only';hardwareFingerprint=$Plan.hardwareFingerprint;modelId=$Plan.model.id;modelSha256=$Plan.model.sha256;catalogSha256=$state.recipe.catalogSha256
            })
        }
        Write-Host "Ready: $($Plan.endpoint) - API smoke test and reported GPU layers passed; physical residency/performance remain unqualified."
        while (-not $hostProcess.Process.WaitForExit(250)) {
            if (Test-Path -LiteralPath $stopPath) { $state.phase='stopped'; return 0 }
        }
        $exitCode = $hostProcess.Process.ExitCode
        if ($exitCode -ne 0) { throw 'Server exited unexpectedly after readiness.' }
        $state.phase='stopped'
        return $exitCode
    } catch {
        $state.phase='failed'; $state.failureCode='startup-or-runtime-check-failed'
        if($spawned){$_.Exception.Data['FastLlmReason']='RuntimeCheckFailed'}
        throw
    } finally {
        try { $hostProcess.Dispose() }
        finally {
            try {
                $state.updatedAt=(Get-Date).ToUniversalTime().ToString('o')
                Write-FastLlmState -InstallRoot $InstallRoot -State $state
            } finally {
                try { Remove-FastLlmRuntimeSandbox $sandbox }
                finally { if (Test-Path -LiteralPath $stopPath) { Remove-Item -LiteralPath $stopPath -Force } }
            }
        }
    }
}
