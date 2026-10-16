# Loaded into FastLlm.psm1. These are lifecycle utilities, not another inference engine.
. (Join-Path $PSScriptRoot 'FastLlm.FileReplace.ps1')
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

# Attributes of a state file as an int, or $null when it cannot be read (missing, access denied). A seam for tests.
function Get-FastLlmStateFileAttributes {
    param([string]$Path)
    try { return [int][IO.File]::GetAttributes($Path) } catch { return $null }
}

function Write-FastLlmState {
    param([string] $InstallRoot, $State, [string] $FileName='status.json')
    Assert-FastLlmLeafName -Value $FileName -Label 'State file name'
    $temporary = $null
    $written = $false
    try {
        # Inside the typed-flag try: a failure to resolve or create the state folder is a state-write failure too.
        $root = Get-FastLlmStateRoot -InstallRoot $InstallRoot -Create
        $path = Join-Path $root $FileName
        $temporary = Join-Path $root ([Guid]::NewGuid().ToString('N') + '.tmp')
        # The reparse check stays before the write. [IO.File]::GetAttributes (FindFirstFile fallback on .NET Framework) also sees a
        # delete-pending destination, so a hold shorter than the replace budget no longer aborts a healthy start here;
        # Move-FastLlmFileReplacing owns the wait (<= ~1.4 s) and fails typed. Attributes -1 or an unreadable destination are
        # transient and are not retried: the replace below waits. A REAL reparse point is unsafe at once.
        $existingAttributes = Get-FastLlmStateFileAttributes -Path $path
        if ($null -ne $existingAttributes -and [int]$existingAttributes -ne -1 -and ([int]$existingAttributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Unsafe status path.' }
        $State | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporary -Encoding UTF8
        $written = $true
        Move-FastLlmFileReplacing -Source $temporary -Destination $path
        # Success consumed the temp. Garbage from earlier FAILED replaces (kept on purpose) is swept now, best-effort.
        Remove-FastLlmStaleTemporaries -Folder $root -NamePattern '^[0-9a-f]{32}\.tmp$'
    } catch {
        # Typed marker: the supervisor classifies a state-write failure by this flag, never by message text.
        try { $_.Exception.Data['FastLlmStateWrite'] = $true } catch { }
        throw
    } finally {
        # Best-effort and never replaces the original error. A fully written temp is ALWAYS kept after a failed replace
        # (it may be the only copy; File.Exists on the destination cannot be trusted); only a partial write is removed.
        if ($temporary -and -not $written) { try { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue } } catch { } }
    }
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
        $record=Read-FastLlmJson -Path $path -MaxBytes 16384
        if($record.kind -ne 'api-smoke-only' -or $record.hardwareFingerprint -ne $key -or $record.modelId -eq $FailedModelId){return $null}
        $digest=(Get-FileHash -LiteralPath $CatalogPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if($record.catalogSha256 -ne $digest){return $null}
        $plan=Get-FastLlmPlan -Hardware $Hardware -CatalogPath $CatalogPath -InstallRoot $InstallRoot -Profile $Profile -ModelId $record.modelId -ContextSize $ContextSize -Recovered
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
    # The existence, size, reparse and read steps sit inside one bounded retry (~150 ms): ReplaceFile can briefly hide
    # the name from openers, which must never be reported as a phantom stopped state or thrown.
    $state = $null
    for ($attempt = 0; $null -eq $state; $attempt++) {
        $last = ($attempt -ge 9)
        try {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                if ($last) { return [pscustomobject]@{ phase='stopped'; active=$false } }
                Start-Sleep -Milliseconds 15
                continue
            }
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            # Attributes -1 (every bit set, including ReparsePoint) is the mid-replace transient: treat it as a missing name.
            if ([int]$item.Attributes -eq -1) {
                if ($last) { return [pscustomobject]@{ phase='stopped'; active=$false } }
                Start-Sleep -Milliseconds 15
                continue
            }
            # A real reparse point is unsafe at once (no retry). An over-cap size is judged by the bounded read below.
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Unsafe status document.' }
            $state = Read-FastLlmJson -Path $path -MaxBytes 65536
            if ($null -eq $state) { throw 'Status document was empty.' }
        } catch {
            # Unsafe verdicts (real reparse point, size over the cap on the opened handle) are final; only transients retry.
            if ($_.Exception.Message -ceq 'Unsafe status document.' -or $_.Exception.Data['FastLlmJsonTooLarge'] -eq $true) { throw }
            if ($last) {
                if ($_.Exception.Message -like 'JSON file was not found:*') { return [pscustomobject]@{ phase='stopped'; active=$false } }
                throw
            }
            Start-Sleep -Milliseconds 15
        }
    }
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
    # Existence and reparse checks sit in a bounded retry so a concurrent create/delete of the request file is not an error.
    # Attributes -1 (the name vanished mid-check) is transient and retried; a real reparse point is refused at once.
    for ($attempt = 0; ; $attempt++) {
        try {
            if (Test-Path -LiteralPath $path) {
                $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
                if ([int]$item.Attributes -eq -1) { throw 'Stop request path was transient.' }
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Unsafe stop request path.' }
            } else {
                # Share Delete: the supervisor polls for this name and removes it on its way out, and it may do so while
                # this handle is still open; with Delete shared the removal succeeds and the name goes when this closes.
                $stream = $null
                try { $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Delete) }
                finally { if ($stream) { $stream.Dispose() } }
            }
            break
        } catch {
            if ($_.Exception.Message -ceq 'Unsafe stop request path.' -or $attempt -ge 9) { throw }
            Start-Sleep -Milliseconds 15
        }
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

function ConvertFrom-FastLlmServerDeviceListEntries {
    # Parses the normalized, already-validated lines the ProcessHost retains ("device-info NAME TOTAL FREE DESC" and
    # "using-device NAME ID FREE DESC"). Fields only, never raw lines: at most 16 entries each, printable ASCII, descriptions capped at 128.
    param([string]$DeviceInfoText,[string]$UsingDeviceText)
    $clean={ param([string]$Value) $text=[regex]::Replace($Value,'[^\x20-\x7e]','?'); if($text.Length -gt 128){$text=$text.Substring(0,128)}; $text }
    $deviceInfo=New-Object System.Collections.Generic.List[object]
    foreach($line in @($DeviceInfoText -split "`r?`n")) {
        if($deviceInfo.Count -ge 16){break}
        $parts=$line.Split(' ',5)
        if($parts.Count -ne 5 -or $parts[0] -cne 'device-info' -or $parts[2] -notmatch '^[0-9]{1,12}$' -or $parts[3] -notmatch '^[0-9]{1,12}$'){continue}
        $deviceInfo.Add([ordered]@{name=(& $clean $parts[1]); description=(& $clean $parts[4]); totalMiB=[long]$parts[2]; freeMiB=[long]$parts[3]})
    }
    $usingDevice=New-Object System.Collections.Generic.List[object]
    foreach($line in @($UsingDeviceText -split "`r?`n")) {
        if($usingDevice.Count -ge 16){break}
        $parts=$line.Split(' ',5)
        if($parts.Count -ne 5 -or $parts[0] -cne 'using-device' -or $parts[3] -notmatch '^[0-9]{1,12}$'){continue}
        $usingDevice.Add([ordered]@{name=(& $clean $parts[1]); id=(& $clean $parts[2]); freeMiB=[long]$parts[3]; description=(& $clean $parts[4])})
    }
    [pscustomobject]@{deviceInfo=$deviceInfo.ToArray(); usingDevice=$usingDevice.ToArray()}
}

# A typed device-binding failure (enforce). FastLlmFailureCode is the failure code, FastLlmReason = DeviceBindingFailed is what keeps it
# out of model recovery (the supervisor's catch keeps both; fast-llm.ps1 retries only RuntimeCheckFailed, PlanChanged and
# ModelNeedsProvisioning, and rethrows this one).
# The one definition of a conforming device-binding failure code; anything else is device-binding-unavailable. Shared by the factory
# below and the supervisor's catch so the two cannot drift.
function ConvertTo-FastLlmDeviceBindingCode {
    param([string] $Code)
    if ($Code -cnotmatch '^device-binding-[a-z-]{1,40}$') { return 'device-binding-unavailable' }
    return $Code
}

function New-FastLlmDeviceBindingFailure {
    param([Parameter(Mandatory = $true)][string] $Code, [Parameter(Mandatory = $true)][string] $Message)
    # A code outside the pattern never becomes the exception's code or message prefix (the CLI prints the message).
    $Code = ConvertTo-FastLlmDeviceBindingCode -Code $Code
    $exception = New-FastLlmTypedFailure -Code $Code -Message $Message
    $exception.Data['FastLlmReason'] = 'DeviceBindingFailed'
    return $exception
}

# The ONE child-environment builder, used by the device probe and by the server launch. It returns what to remove from the inherited environment
# and what to set; Initialize-FastLlmEngineStartInfo applies it. -Plan needs backend, enginePath and (HIP only) runtimeRoots.
#   Vulkan: the shared scrub, APPDATA/PROGRAMDATA in the run sandbox, PATH = <engine dir>;System32;SystemRoot, and the BAR variable only on request.
# The PATH only decides among PATH entries: Windows searches the application directory (the engine directory, which holds amdhip64_7, amd_comgr and
# rocm_kpack), then System32, then the Windows directory, and PATH after those. A same-named library in System32 would therefore win over a runtime bin
# entry, whatever the PATH order is.
#   HIP:    the same scrub plus every ROC* name, then PATH = <engine dir>;<runtime roots...>;System32;SystemRoot. Never the BAR variable and never any HIP_*, ROC* or HSA_* value.
# Names scrubbed from a HIP child in addition to the shared scrub: the ROCm/HSA-adjacent ROC* family (ROCR_VISIBLE_DEVICES), the hipBLAS/hipBLASLt/rocBLAS
# library-path and logging overrides (HIPBLAS*, HIPBLASLT_TENSILE_LIBPATH, MIOPEN_*), the CLR/COMGR switches (AMD_*, GPU_*, HCC_*, HIPCC_*) and the device-lib path.
function Test-FastLlmHipEnvironmentName {
    param([Parameter(Mandatory = $true)][string] $Name)
    return [bool] ($Name -like 'ROC*' -or $Name -like 'HIPBLAS*' -or $Name -like 'MIOPEN_*' -or $Name -like 'AMD_*' -or $Name -like 'GPU_*' -or
        $Name -like 'HCC_*' -or $Name -like 'HIPCC_*' -or $Name -like 'HIPRTC_*' -or $Name -like 'ORIGAMI_*' -or $Name -ieq 'DEVICE_LIB_PATH')
}

function Get-FastLlmEngineEnvironment {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Plan, [Parameter(Mandatory = $true)] $Sandbox, [string[]] $InheritedNames = @(), [switch] $VulkanBarMitigation, [string] $SystemRoot)
    $enginePath = [string] $Plan.enginePath
    # Split-Path as both call sites always used it. Off Windows (a pre-filter run on a Windows-style path) it would rewrite the separators, so cut by hand.
    if ($env:OS -eq 'Windows_NT') { $engineDirectory = Split-Path -Parent $enginePath }
    else {
        $separator = $enginePath.LastIndexOfAny([char[]] @('\', '/'))
        $engineDirectory = if ($separator -gt 0) { $enginePath.Substring(0, $separator) } else { '' }
    }
    $isHip = $false
    if ($Plan.PSObject.Properties['backend'] -and ([string] $Plan.backend) -ieq 'hip') { $isHip = $true }
    $remove = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in @($InheritedNames)) {
        if ((Test-FastLlmEnvironmentNameRequiresClearing -Name ([string] $name)) -or ($isHip -and (Test-FastLlmHipEnvironmentName -Name ([string] $name)))) { $remove.Add([string] $name) }
    }
    $set = [ordered] @{}
    $set['APPDATA'] = [string] $Sandbox.appData
    $set['PROGRAMDATA'] = [string] $Sandbox.programData
    if (-not $PSBoundParameters.ContainsKey('SystemRoot')) { $SystemRoot = [string] $env:SystemRoot }
    if (($env:OS -eq 'Windows_NT' -or $PSBoundParameters.ContainsKey('SystemRoot')) -and [string]::IsNullOrWhiteSpace($SystemRoot)) {
        # Never leave PATH inherited: ask Windows, or fail closed.
        $SystemRoot = [Environment]::GetFolderPath('Windows')
        if ([string]::IsNullOrWhiteSpace($SystemRoot)) { throw 'The Windows directory is not known, so the engine search path cannot be built. Nothing was started.' }
    }
    if ($env:OS -eq 'Windows_NT' -or $PSBoundParameters.ContainsKey('SystemRoot')) {
        $searchPath = New-Object 'System.Collections.Generic.List[string]'
        $searchPath.Add($engineDirectory)
        if ($isHip) {
            $planRuntimeRoots = @()
            if ($Plan.PSObject.Properties['runtimeRoots'] -and $null -ne $Plan.runtimeRoots) { $planRuntimeRoots = @($Plan.runtimeRoots) }
            foreach ($runtimeRoot in $planRuntimeRoots) { if (-not [string]::IsNullOrWhiteSpace([string] $runtimeRoot)) { $searchPath.Add([string] $runtimeRoot) } }
        }
        $searchPath.Add("$SystemRoot\System32")
        $searchPath.Add($SystemRoot)
        $set['PATH'] = $searchPath.ToArray() -join ';'
    }
    # The BAR variable is a Vulkan-lane switch: a HIP plan never receives it, whatever the caller asked for.
    if ($VulkanBarMitigation -and -not $isHip) { $set[$script:FastLlmVulkanBarMitigationVariable] = '1' }
    return [pscustomobject] [ordered] @{ remove = $remove.ToArray(); set = $set }
}

function Initialize-FastLlmEngineStartInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Diagnostics.ProcessStartInfo] $StartInfo, [Parameter(Mandatory = $true)] $Plan, [Parameter(Mandatory = $true)] $Sandbox, [switch] $VulkanBarMitigation)
    $environment = Get-FastLlmEngineEnvironment -Plan $Plan -Sandbox $Sandbox -InheritedNames @($StartInfo.EnvironmentVariables.Keys | ForEach-Object { [string] $_ }) -VulkanBarMitigation:$VulkanBarMitigation
    foreach ($name in $environment.remove) { $StartInfo.EnvironmentVariables.Remove($name) }
    foreach ($name in $environment.set.Keys) { $StartInfo.EnvironmentVariables[[string] $name] = [string] $environment.set[$name] }
}

# Decimal NTSTATUS values as Int32 (Process.ExitCode): STATUS_INVALID_IMAGE_HASH 0xC0000428 and STATUS_DLL_NOT_FOUND 0xC0000135.
# Win32 errors 4551 and 1260 (application-control policy blocks such as Smart App Control or WDAC) can surface from the process start itself.
# Returns a typed exception, or $null when neither a policy block nor a missing DLL explains the failure. The reason is deliberately not
# RuntimeCheckFailed: model recovery would re-plan onto the built-in Vulkan engine, which is the silent fallback this lane forbids.
# True when a HIP plan was picked automatically from a measured recipe and has not itself fallen back: a failed start of such a plan is
# followed by one visible start of the Vulkan setup. An explicit recipe, a plan that already fell back and a non-HIP plan never are.
function Test-FastLlmPlanFallsBackOnFailure {
    param($Plan)
    if ($null -eq $Plan) { return $false }
    if (-not ($Plan.PSObject.Properties['backend'] -and ([string] $Plan.backend) -ieq 'hip')) { return $false }
    if (-not ($Plan.PSObject.Properties['recipe'] -and $Plan.recipe -and $Plan.recipe.PSObject.Properties['id'] -and -not [string]::IsNullOrWhiteSpace([string] $Plan.recipe.id))) { return $false }
    if ($Plan.PSObject.Properties['requestedRecipeId'] -and -not [string]::IsNullOrWhiteSpace([string] $Plan.requestedRecipeId)) { return $false }
    if ($Plan.PSObject.Properties['fallback'] -and $Plan.fallback) { return $false }
    return $true
}

function New-FastLlmHipLaunchFailure {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $ComponentId, [object] $ExitCode, [object] $NativeErrorCode, [switch] $ServerWasRunning, [switch] $AutoSelected)
    $blocked = $false
    $missing = $false
    $detail = $null
    if ($null -ne $NativeErrorCode -and [int] $NativeErrorCode -in @(4551, 1260, 577)) { $blocked = $true; $detail = "Windows error $([int] $NativeErrorCode)" }
    elseif ($null -ne $ExitCode -and [int] $ExitCode -eq -1073740760) { $blocked = $true; $detail = 'exit status 0xC0000428, STATUS_INVALID_IMAGE_HASH' }
    elseif ($null -ne $ExitCode -and [int] $ExitCode -eq -1073741515) { $missing = $true; $detail = 'exit status 0xC0000135, STATUS_DLL_NOT_FOUND' }
    if (-not $blocked -and -not $missing) { return $null }
    $stopped = 'The server was stopped.'
    $vulkan = 'FastLLM does not switch to Vulkan on its own. To use the Vulkan setup instead, start FastLLM without the HIP recipe (choose a Vulkan setup).'
    if ($AutoSelected) { $vulkan = 'FastLLM starts the Vulkan setup instead.' }
    if ($blocked) {
        $code = 'hip-dll-blocked'
        $text = "Windows blocked a DLL of the HIP engine component '${ComponentId}' from loading ($detail). Smart App Control or an application-control policy (WDAC) rejects unsigned files. $stopped $vulkan"
    }
    else {
        $code = 'hip-dll-missing'
        $text = "The HIP engine component '${ComponentId}' could not find a DLL it needs ($detail). Reinstall the engine and its runtime component. $stopped $vulkan"
    }
    $failure = New-FastLlmTypedFailure -Code $code -Message $text
    $failure.Data['FastLlmComponentId'] = $ComponentId
    $failure.Data['FastLlmReason'] = 'HipDllFailed'
    return $failure
}

# Smart App Control state, read-only: HKLM\SYSTEM\CurrentControlSet\Control\CI\Policy VerifiedAndReputablePolicyState (1 = enforcement on).
# 'enforced', 'off' (0 or evaluation) or 'unknown' (not Windows, or the value is unreadable). A module-level function so tests can replace the read.
function Get-FastLlmSmartAppControlState {
    if ($env:OS -ne 'Windows_NT') { return 'unknown' }
    try {
        $policy = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name 'VerifiedAndReputablePolicyState' -ErrorAction Stop
        $value = $policy.VerifiedAndReputablePolicyState
        if ($value -isnot [int] -and $value -isnot [long]) { return 'unknown' }
        if ([int64] $value -eq 1) { return 'enforced' }
        return 'off'
    }
    catch { return 'unknown' }
}

# The HIP device probe found no usable backend: it did not list a single ROCm<N> device, timed out, exited non-zero or could not start.
# Upstream b11658 prints "Available devices:" and "(none)" with exit 0 and empty stderr when ggml-hip.dll (or an AMD DLL it loads) cannot load,
# so this is not an exit code. Only independent evidence upgrades it to hip-dll-blocked: Smart App Control enforcement is on AND the engine
# started cleanly but listed no ROCm device. The reason is never RuntimeCheckFailed (model recovery would re-plan onto Vulkan).
function New-FastLlmHipBackendFailure {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $ComponentId, [Parameter(Mandatory = $true)][ValidateSet('no-device', 'timeout', 'exit', 'start')][string] $Cause, [object] $ExitCode, [switch] $AutoSelected)
    $vulkan = 'FastLLM did not switch to Vulkan: use the Vulkan setup instead (start FastLLM without the HIP recipe).'
    if ($AutoSelected) { $vulkan = 'FastLLM starts the Vulkan setup instead.' }
    if ($Cause -ceq 'no-device' -and (Get-FastLlmSmartAppControlState) -ceq 'enforced') {
        $failure = New-FastLlmTypedFailure -Code 'hip-dll-blocked' -Message "The HIP engine component '${ComponentId}' listed no ROCm device, and Smart App Control is on. Smart App Control blocks unsigned DLLs, and the AMD runtime DLLs are unsigned, so Windows most likely refused to load them. Nothing was started. $vulkan"
        $failure.Data['FastLlmReason'] = 'HipDllFailed'
    }
    else {
        $what = switch ($Cause) {
            'no-device' { 'listed no ROCm device' }
            'timeout' { 'did not finish listing its devices in time' }
            'exit' { "exited with status $ExitCode while listing its devices" }
            default { 'could not be started' }
        }
        $failure = New-FastLlmTypedFailure -Code 'hip-backend-unavailable' -Message "The HIP engine component '${ComponentId}' $what, so the HIP backend is not usable. Likely causes: an AMD runtime DLL could not load (blocked by Smart App Control or WDAC, or damaged), or the AMD driver does not expose HIP for this card. Reinstall the HIP components, update the AMD driver, or choose the Vulkan setup. Nothing was started. $vulkan"
        $failure.Data['FastLlmReason'] = 'HipBackendUnavailable'
    }
    $failure.Data['FastLlmComponentId'] = $ComponentId
    return $failure
}

# The Win32 error carried by a process-start failure, if any (PowerShell wraps the .NET exception, so the chain is walked).
function Get-FastLlmNativeErrorCode {
    param($Exception)
    $current = $Exception
    for ($depth = 0; $null -ne $current -and $depth -lt 8; $depth++) {
        if ($current -is [System.ComponentModel.Win32Exception]) { return [int] $current.NativeErrorCode }
        $current = $current.InnerException
    }
    return $null
}

# True when the plan runs on an engine component (HIP, or any listed engine component). Such a plan is never recovered onto another setup.
function Test-FastLlmPlanOnEngineComponent {
    param($Plan)
    if ($Plan.PSObject.Properties['engineComponentId'] -and $Plan.engineComponentId) { return $true }
    return [bool] ($Plan.PSObject.Properties['backend'] -and ([string] $Plan.backend) -ieq 'hip')
}

# The closing sentence of a failed self-test depends on whether the CLI may actually recover onto the next cached setup.
function Get-FastLlmSelfTestFailureText {
    param([string[]] $Reasons, $Plan)
    $next = 'FastLLM tries the next cached setup.'
    if (Test-FastLlmPlanOnEngineComponent -Plan $Plan) { $next = 'FastLLM does not switch to another setup on its own.' }
    if (Test-FastLlmPlanFallsBackOnFailure -Plan $Plan) { $next = 'FastLLM starts the Vulkan setup instead.' }
    return "Self-test failed ($(@($Reasons) -join ', ')). The server was stopped; $next"
}

function Invoke-FastLlmSupervisedServer {
    param($Plan, [string] $InstallRoot, [int] $LoadTimeoutSeconds=300, [string] $CatalogPath,
          # Policy defaults and the canary default to off here (and in the module policy) so direct callers (lab trials) are unaffected;
          # the CLI and the background host default to auto and always pass it.
          [string] $VulkanBarMitigation='off', [switch] $ThroughputCanary,
          # Post-load self-test (default off for direct callers; the CLI start enables it).
          [switch] $SelfTest,
          # W03 Phase A device binding. Absent or off: nothing below runs and no field is added. record observes only.
          # enforce additionally fails a start whose binding is not bound (before launch) or whose post-load device check fails;
          # both failures are typed (FastLlmReason DeviceBindingFailed) and never trigger model recovery.
          [ValidateSet('off','record','enforce')][string] $DeviceBinding='off')
    # ValidateSet ignores case and keeps the typed value, but the enforce checks below are case-sensitive: normalise once, first.
    $DeviceBinding = $DeviceBinding.ToLowerInvariant()
    Initialize-FastLlmProcessHost
    $state = [ordered]@{ schemaVersion=1; runId=[Guid]::NewGuid().ToString('N'); phase='loading'; updatedAt=(Get-Date).ToUniversalTime().ToString('o'); modelId=$Plan.model.id; endpoint=$Plan.endpoint; hardwareFingerprint=$Plan.hardwareFingerprint; engineVersion=$Plan.engineVersion; modelSha256=$Plan.model.sha256; canary=$null; placement=$null; startupDiagnostics=$null; selectedDeviceCapture=$null; selectedDeviceIdentity=$null; failureCode=$null; performanceQualified=$false; recipe=$null; processIdentity=$null; vulkanMemoryPolicy=$null; barGuidance=[ordered]@{ shown = $false; text = $null } }
    # A HIP plan (the engine component's lane) has no Vulkan memory policy, BAR mitigation, device binding or Vulkan identity capture.
    $isHipPlan = [bool] ($Plan.PSObject.Properties['backend'] -and ([string] $Plan.backend) -ieq 'hip')
    $hipAutoSelected = Test-FastLlmPlanFallsBackOnFailure -Plan $Plan
    $hipComponentId = ''
    if ($isHipPlan -and $Plan.PSObject.Properties['engineComponentId'] -and $Plan.engineComponentId) { $hipComponentId = [string] $Plan.engineComponentId }
    # Resolve the policy before any state is written; a non-off policy may run the bounded advisory heap probe.
    if ($isHipPlan) {
        $state.vulkanMemoryPolicy = [pscustomobject][ordered]@{ requested = 'not-applicable'; effective = 'not-applicable'; reason = 'hip-lane' }
        $state.selectedDeviceIdentity = [ordered]@{ status = 'not-applicable'; reason = 'hip-lane' }
    }
    else { $state.vulkanMemoryPolicy = Resolve-FastLlmVulkanBarMitigation -Plan $Plan -Requested $VulkanBarMitigation -InstallRoot $InstallRoot }
    if ($ThroughputCanary) { $state.throughputCanary = $null }
    if ($state.vulkanMemoryPolicy.requested -ne 'off' -and $state.vulkanMemoryPolicy.reason -eq 'engine-not-verified') {
        Write-Host "Vulkan memory: -VulkanBarMitigation $($state.vulkanMemoryPolicy.requested) was skipped because engine build '$($Plan.engineVersion)' has not been verified for it; no mitigation was applied."
    }
    elseif ($state.vulkanMemoryPolicy.requested -eq 'auto' -and $state.vulkanMemoryPolicy.reason -eq 'rebar-unknown-no-mitigation') {
        Write-Host 'Vulkan memory: the Resizable BAR check did not run or was inconclusive; no mitigation was applied. Details: fast-llm doctor -ProbeVulkanMemory.'
    }
    elseif ($state.vulkanMemoryPolicy.reason -eq 'policy-error') {
        Write-Host 'Vulkan memory: the Resizable BAR policy could not be evaluated; no mitigation was applied.'
    }
    if ($state.vulkanMemoryPolicy.effective -eq 'on') {
        $barCard = (@(@($Plan.selectedAdapters) | ForEach-Object { if ($_.PSObject.Properties['name']) { [string]$_.name } } | Where-Object { $_ }) -join ', ')
        if (-not $barCard) { $barCard = 'the selected GPU' }
        if ($state.vulkanMemoryPolicy.reason -eq 'rebar-off-detected') {
            Write-Host "Vulkan memory: Resizable BAR (Smart Access Memory) appears to be off for $barCard; keeping model buffers in device-only VRAM ($($script:FastLlmVulkanBarMitigationVariable)=1). Model load time may differ. Details: fast-llm doctor -ProbeVulkanMemory."
            $guidance = "Resizable BAR (AMD Smart Access Memory) appears to be off on this PC. FastLLM applied a workaround so models run at full speed. Turning on Resizable BAR / Smart Access Memory in your BIOS is AMD's recommended setup and may help further. See docs/RESIZABLE-BAR.md."
            Write-Host $guidance
            $state.barGuidance = [ordered]@{ shown = $true; text = $guidance }
        }
        else {
            Write-Host "Vulkan memory: keeping model buffers in device-only VRAM for $barCard ($($script:FastLlmVulkanBarMitigationVariable)=1, -VulkanBarMitigation on). Model load time may differ. Details: fast-llm doctor."
        }
    }
    # W03 Phase A: observe which device the plan resolves to, before any state is written and before the spawn. The observation never
    # alters the plan, the argv, the child environment or the BAR decision, and the collection itself never throws. record never fails
    # the start. enforce does: a binding that is not 'bound' becomes a typed gate (below) that is thrown before the port probe and the spawn.
    $deviceIdentity = $null
    $deviceBindingGate = $null
    if ($isHipPlan -and $DeviceBinding -ne 'off') {
        # Device binding and the Vulkan identity capture are Vulkan-only: record observes nothing here, and enforce refuses before any launch.
        $state.deviceBinding = [pscustomobject][ordered]@{ mode = $DeviceBinding; status = 'not-applicable'; reason = 'unsupported-backend' }
        $state.identityRecord = 'not-applicable'
        if ($DeviceBinding -ceq 'enforce') {
            $deviceBindingGate = New-FastLlmDeviceBindingFailure -Code 'device-binding-unsupported-backend' -Message "Device binding (enforce) is available only for the Vulkan lane; this setup runs on the HIP engine component '${hipComponentId}'. The server was not started. Use -DeviceBinding record or -DeviceBinding off to start without this requirement."
        }
    }
    elseif ($DeviceBinding -ne 'off') {
        # The glue is contained as well: nothing here may reach the start's catch (binding-internal-error, identity unavailable).
        try {
            $binding = Invoke-FastLlmDeviceBinding -Plan $Plan -InstallRoot $InstallRoot -BarDecision $state.vulkanMemoryPolicy -Mode $DeviceBinding
            $state.deviceBinding = $binding.record
            if ($null -ne $binding.identity) {
                $deviceIdentity = $binding.identity
                $state.identityFingerprint = [string]$binding.identity.fingerprint
                $state.identityFingerprintKind = $script:FastLlmDeviceIdentityKind
                $state.identityRecord = 'pending'
                if ($null -ne $binding.change -and ($binding.change.card -or $binding.change.slot -or $binding.change.driver)) {
                    $state.identityChange = [ordered]@{ card = [bool]$binding.change.card; slot = [bool]$binding.change.slot; driver = [bool]$binding.change.driver }
                }
                foreach ($line in @($binding.lines)) { Write-Host ([string]$line) }
            }
            else { $state.identityRecord = 'unavailable' }
        }
        catch {
            $glueErrorType = 'Exception'
            try { $glueErrorType = [string]$_.Exception.GetType().Name } catch { }
            $deviceIdentity = $null
            foreach ($staleField in @('identityFingerprint', 'identityFingerprintKind', 'identityChange')) { if ($state.Contains($staleField)) { $state.Remove($staleField) } }
            $state.deviceBinding = [pscustomobject][ordered]@{
                mode = $DeviceBinding; status = 'unavailable'; reason = 'binding-internal-error'; rawDeviceCount = 0; distinctAdapterCount = 0; duplicateLuidEntries = 0
                device = $null; planMatch = $null; barSnapshot = 'not-applicable'
                collector = [pscustomobject][ordered]@{ scriptSha256 = $null; joinSourceSha256 = $null; durationMs = 0; loaderVersion = $null; segmentKnown = $false }
                errorType = $glueErrorType
            }
            $state.identityRecord = 'unavailable'
        }
        # enforce only: a binding that is not 'bound' fails the start before launch. The failure is built here and thrown as the first
        # statement of the start's try block, so the catch records the typed code and the finally writes the failed state and cleans up.
        if ($DeviceBinding -ceq 'enforce' -and [string](Get-FastLlmDeviceBindingValue $state.deviceBinding 'status') -cne 'bound') {
            $gateStatus = [string](Get-FastLlmDeviceBindingValue $state.deviceBinding 'status')
            if ($gateStatus -cnotin @('unavailable', 'ambiguous', 'not-supported-topology')) { $gateStatus = 'unavailable' }
            $gateReason = [string](Get-FastLlmDeviceBindingValue $state.deviceBinding 'reason')
            if ($gateReason -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,95}$') { $gateReason = 'unspecified' }
            $deviceBindingGate = New-FastLlmDeviceBindingFailure -Code ('device-binding-' + $gateStatus) -Message "Device binding (enforce) could not bind the GPU: status '$gateStatus', reason '$gateReason'. The server was not started. Use -DeviceBinding record or -DeviceBinding off to start without this requirement."
        }
    }
    if ($Plan.PSObject.Properties['backgroundRequestId']) {
        $backgroundRequestId = [string]$Plan.backgroundRequestId
        if ($backgroundRequestId -cnotmatch '^[0-9a-f]{32}$') { throw 'Invalid background request correlation.' }
        $state.backgroundRequestId = $backgroundRequestId
    }
    # What the plan said about its recipe, recorded so a UI shows the label and results link of the plan that actually runs.
    if ($Plan.PSObject.Properties['recipe'] -and $Plan.recipe) {
        $planRecipeFields = [ordered]@{ id = $null; origin = $null; label = $null; evidenceUrl = $null }
        foreach ($planRecipeField in @($planRecipeFields.Keys)) {
            if ($Plan.recipe.PSObject.Properties[$planRecipeField] -and $null -ne $Plan.recipe.$planRecipeField) { $planRecipeFields[$planRecipeField] = [string] $Plan.recipe.$planRecipeField }
        }
        $state.planRecipe = $planRecipeFields
    }
    # The engine that actually runs, recorded so removing an engine component can tell whether this server uses it.
    if ($Plan.PSObject.Properties['enginePath'] -and -not [string]::IsNullOrWhiteSpace([string] $Plan.enginePath)) {
        $state.engineExecutable = [string] $Plan.enginePath
        $statusEngineComponentId = $null
        if ($Plan.PSObject.Properties['engineComponentId'] -and $Plan.engineComponentId) { $statusEngineComponentId = [string] $Plan.engineComponentId }
        elseif ($Plan.PSObject.Properties['engineVersion'] -and $Plan.engineVersion -and $Plan.PSObject.Properties['backend'] -and ([string] $Plan.backend).ToLowerInvariant() -ceq 'vulkan') {
            $statusEngineComponentId = 'llama.cpp-' + [string] $Plan.engineVersion + '-vulkan'
        }
        $state.engineComponentId = $statusEngineComponentId
        # The engine that runs, in one block (backend, version, component id), next to the older flat fields.
        $state.engine = [ordered]@{ backend = $(if ($Plan.PSObject.Properties['backend']) { ([string] $Plan.backend).ToLowerInvariant() } else { $null }); version = $(if ($Plan.PSObject.Properties['engineVersion']) { [string] $Plan.engineVersion } else { $null }); componentId = $statusEngineComponentId }
    }
    # A plan that stands in for the one that could not run says so: the recipe it replaced, the one that runs, and why.
    if ($Plan.PSObject.Properties['fallback'] -and $Plan.fallback -and $Plan.fallback.PSObject.Properties['applied'] -and [bool] $Plan.fallback.applied) {
        $fallbackToRecipe = $null
        if ($Plan.PSObject.Properties['recipe'] -and $Plan.recipe -and $Plan.recipe.PSObject.Properties['id']) { $fallbackToRecipe = [string] $Plan.recipe.id }
        $state.fallback = [ordered]@{ fromRecipe = [string] $Plan.fallback.fromRecipe; toRecipe = $fallbackToRecipe; reason = [string] $Plan.fallback.reason }
    }
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
        # Recorded only when the mitigation is in effect, so the default recipe stays byte-identical.
        if ($state.vulkanMemoryPolicy.effective -eq 'on') {
            $state.recipe.environmentOverride = [ordered]@{ $script:FastLlmVulkanBarMitigationVariable = '1' }
        }
    }
    $stateRoot = Get-FastLlmStateRoot -InstallRoot $InstallRoot -Create
    $stopPath = Join-Path $stateRoot ('stop-' + $state.runId)
    $sandbox = New-FastLlmRuntimeSandbox -InstallRoot $InstallRoot
    $hostProcess = New-Object Bitworks.FastLlm.ProcessHost
    $spawned = $false
    $baseUrl = $Plan.endpoint -replace '/v1$', ''
    try {
        if ($null -ne $deviceBindingGate) { throw $deviceBindingGate }
        # Refuse an already occupied port. A same-user bind race after this check remains possible.
        $uri = [Uri]$baseUrl
        $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $uri.Port)
        try { $listener.Server.ExclusiveAddressUse=$true; $listener.Start() }
        finally { $listener.Stop() }
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $Plan.enginePath
        $info.Arguments = Join-FastLlmProcessArguments -Arguments $Plan.serverArguments
        $info.WorkingDirectory = Split-Path -Parent $Plan.enginePath
        # The scrub, sandbox paths, PATH and (Vulkan lane, opt-in) the BAR variable all come from the one environment builder the device probe also uses.
        Initialize-FastLlmEngineStartInfo -StartInfo $info -Plan $Plan -Sandbox $sandbox -VulkanBarMitigation:($state.vulkanMemoryPolicy.effective -eq 'on')
        Write-FastLlmState -InstallRoot $InstallRoot -State $state
        try { $hostProcess.Start($info) }
        catch {
            # A policy block can refuse the process start itself (Win32 error 4551 or 1260): typed, and never a Vulkan fallback.
            if ($isHipPlan) {
                $hipStartFailure = New-FastLlmHipLaunchFailure -ComponentId $hipComponentId -NativeErrorCode (Get-FastLlmNativeErrorCode -Exception $_.Exception) -AutoSelected:$hipAutoSelected
                if ($hipStartFailure) { throw $hipStartFailure }
            }
            throw
        }
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
            if ($hostProcess.Process.HasExited) {
                # A HIP server that dies on a blocked or missing DLL is a typed failure; any other early exit stays the generic one.
                if ($isHipPlan) {
                    $hipEarlyFailure = New-FastLlmHipLaunchFailure -ComponentId $hipComponentId -ExitCode ([int] $hostProcess.Process.ExitCode) -AutoSelected:$hipAutoSelected
                    if ($hipEarlyFailure) { throw $hipEarlyFailure }
                }
                throw 'Server exited before readiness.'
            }
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
        if (-not $isHipPlan) { $state.selectedDeviceIdentity=ConvertFrom-FastLlmSelectedDeviceIdentity -Text $selectedDeviceText -ExpectedDevices @($Plan.selectedAdapters.device) -LikeLines $state.selectedDeviceCapture.likeLines -MalformedLines $state.selectedDeviceCapture.malformedLines -Overflow $state.selectedDeviceCapture.overflow }
        # Freeze the server device-list capture (the level-4 device_info entries and the "using device" lines) at the same point, before any
        # API canary. The capture itself never gates: any throw is recorded as { error = <exception type name> } (never its text) and is
        # swallowed here. Under -DeviceBinding enforce the post-load check below READS these entries (an error capture fails that check
        # closed) and can fail the start; under record and off nothing reads them to decide anything and the Ready gate is untouched.
        # Counts, overflow flags and reason-only diagnostics are recorded, plus the parsed entries as fields only (never raw lines), in private status.json only.
        try {
            $deviceInfoText=$hostProcess.FreezeDeviceInfoEntries()
            $usingDeviceText=$hostProcess.FreezeUsingDeviceEntries()
            $deviceListEntries=ConvertFrom-FastLlmServerDeviceListEntries -DeviceInfoText $deviceInfoText -UsingDeviceText $usingDeviceText
            $state.serverDeviceListCapture=[ordered]@{
                deviceInfoLikeLines=[int]$hostProcess.DeviceInfoLikeLines
                deviceInfoMalformedLines=[int]$hostProcess.DeviceInfoMalformedLines
                deviceInfoOverflow=[bool]$hostProcess.DeviceInfoOverflow
                usingDeviceLikeLines=[int]$hostProcess.UsingDeviceLikeLines
                usingDeviceMalformedLines=[int]$hostProcess.UsingDeviceMalformedLines
                usingDeviceOverflow=[bool]$hostProcess.UsingDeviceOverflow
                diagnostics=[string]$hostProcess.DeviceListCaptureDiagnostics()
                deviceInfo=@($deviceListEntries.deviceInfo)
                usingDevice=@($deviceListEntries.usingDevice)
            }
        } catch { $state.serverDeviceListCapture=[ordered]@{error=[string]$_.Exception.GetType().Name} }
        # W03 Phase A post-load device check, still before the canary, the ready write and the last-ready record. record: informational
        # (recorded only when the binding is bound, any error swallowed, never gates). enforce: a failed check stops the server through the
        # start's catch/finally (Dispose) and fails the start with a typed, never-recovered failure.
        if ($DeviceBinding -ne 'off' -and [string](Get-FastLlmDeviceBindingValue $state.deviceBinding 'status') -ceq 'bound') {
            $postLoad = $null
            try { $postLoad = Test-FastLlmDeviceBindingPostLoad -Plan $Plan -Binding $state.deviceBinding -Capture $state.serverDeviceListCapture }
            catch { $postLoad = [pscustomobject][ordered]@{ result = 'failed'; item = 'internal-error' } }
            try { $state.deviceBinding | Add-Member -NotePropertyName postLoadCheck -NotePropertyValue $postLoad -Force }
            catch {
                # record swallows; enforce must not let an untyped error reach the start's recovery, so it becomes the typed failure.
                if ($DeviceBinding -ceq 'enforce') {
                    $postLoad = [pscustomobject][ordered]@{ result = 'failed'; item = 'internal-error' }
                    throw (New-FastLlmDeviceBindingFailure -Code 'device-binding-post-load-mismatch' -Message "Device binding (enforce): the post-load device check could not be recorded (check internal-error). The server was stopped. Use -DeviceBinding record or -DeviceBinding off to start without this requirement.")
                }
            }
            if ($DeviceBinding -ceq 'enforce' -and $postLoad.result -cne 'passed') {
                throw (New-FastLlmDeviceBindingFailure -Code 'device-binding-post-load-mismatch' -Message ("Device binding (enforce): the server's device list does not match the bound GPU (check $($postLoad.item)). The server was stopped. Use -DeviceBinding record or -DeviceBinding off to start without this requirement."))
            }
        }
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
        # The self-test (spec 4.2 step 5, 4.3) completes BEFORE any ready announcement: the status phase stays 'checking', no Ready line is printed
        # and the last-ready recovery record is not rewritten until the verdict is in. A hard fail therefore leaves the previous record intact for recovery.
        if ($SelfTest) {
            $expected = $null
            if ($Plan.PSObject.Properties['recipe'] -and $Plan.recipe -and $Plan.recipe.expected) { $expected = $Plan.recipe.expected }
            $contextForTest = 0
            if ($Plan.model.PSObject.Properties['contextSize']) { $contextForTest = [int] $Plan.model.contextSize }
            $mitigation = 'off'
            if ($state.vulkanMemoryPolicy -and $state.vulkanMemoryPolicy.effective -eq 'on') { $mitigation = 'on' }
            $selfTestResult = Invoke-FastLlmSelfTest -BaseUrl $baseUrl -ContextSize $contextForTest -Expected $expected -EngineBuild ([string] $Plan.engineVersion) -MitigationEffective $mitigation
            $recipeId = $null
            if ($Plan.PSObject.Properties['recipe'] -and $Plan.recipe) { $recipeId = $Plan.recipe.id }
            $state.selfTest = $selfTestResult
            try { Write-FastLlmState -InstallRoot $InstallRoot -FileName 'selftest.json' -State ([ordered]@{ schemaVersion = 1; recipeId = $recipeId; modelId = [string] $Plan.model.id
                        engineBuild = [string] $Plan.engineVersion; result = $selfTestResult }) } catch { }
            try { $state.updatedAt = (Get-Date).ToUniversalTime().ToString('o'); Write-FastLlmState -InstallRoot $InstallRoot -State $state } catch { }
            if ($selfTestResult.status -eq 'pass') { Write-Host "Self-test passed: $($selfTestResult.generationTokS) tok/s generation, $($selfTestResult.promptTokS) tok/s prompt." }
            elseif ($selfTestResult.status -eq 'skipped') {
                Write-Host "Self-test skipped: the context size is too small for the performance check ($(@($selfTestResult.reasons) -join ', ')). The server keeps running."
            }
            elseif ($selfTestResult.status -eq 'below-expected') {
                Write-Host "Self-test: generation $($selfTestResult.generationTokS) tok/s is below 70% of the $($selfTestResult.expectedGenerationTokS) tok/s measured for this setup. Likely causes: driver version, Resizable BAR, other apps using GPU memory, power or thermal limits. Run: fast-llm doctor"
            }
            else {
                $failure = New-FastLlmTypedFailure -Code 'self-test-failed' -Message (Get-FastLlmSelfTestFailureText -Reasons @($selfTestResult.reasons) -Plan $Plan)
                $failure.Data['FastLlmReason'] = 'RuntimeCheckFailed'
                throw $failure
            }
        }
        $state.phase='ready'; $state.updatedAt=(Get-Date).ToUniversalTime().ToString('o')
        Write-FastLlmState -InstallRoot $InstallRoot -State $state
        if ($state.recipe) {
            Write-FastLlmState -InstallRoot $InstallRoot -FileName ($Plan.hardwareFingerprint+'.last-ready.json') -State ([ordered]@{
                kind='api-smoke-only';hardwareFingerprint=$Plan.hardwareFingerprint;modelId=$Plan.model.id;modelSha256=$Plan.model.sha256;catalogSha256=$state.recipe.catalogSha256
            })
        }
        if ($null -ne $deviceIdentity) {
            # Advisory: the identity record is written only now (a failed start leaves the file untouched). Any failure is caught here,
            # so it can never reach the start's catch block, change the phase or trigger model recovery.
            try { $identityWritten = Write-FastLlmDeviceIdentityRecord -InstallRoot $InstallRoot -Identity $deviceIdentity; $state.identityRecord = $(if ($identityWritten -is [bool] -and -not $identityWritten) { 'unavailable' } else { 'recorded' }) }
            catch { $state.identityRecord = 'write-failed' }
            try {
                $state.updatedAt=(Get-Date).ToUniversalTime().ToString('o')
                Write-FastLlmState -InstallRoot $InstallRoot -State $state
            } catch { }
        }
        Write-Host "Ready: $($Plan.endpoint) - API smoke test and reported GPU layers passed; physical residency/performance remain unqualified."
        if ($ThroughputCanary) {
            # Advisory only: every failure is recorded and swallowed; it can never fail the start or trigger recovery.
            try {
                $canaryNames = @(@($Plan.selectedAdapters) | ForEach-Object { if ($_.PSObject.Properties['name']) { [string]$_.name } })
                $contextForCanary = if ($Plan.model.PSObject.Properties['contextSize']) { [int]$Plan.model.contextSize } else { 0 }
                $state.throughputCanary = Invoke-FastLlmThroughputCanary -BaseUrl $baseUrl -ContextSize $contextForCanary -AdapterNames $canaryNames -ModelId ([string]$Plan.model.id)
            } catch { $state.throughputCanary = [pscustomobject][ordered]@{ ppTokPerS=$null; floor=$null; floorSource=$null; warmupPpTokPerS=$null; status='failed'; promptTokens=$null; promptArtifactSha256=$null; reason='canary-error' } }
            try {
                $state.updatedAt=(Get-Date).ToUniversalTime().ToString('o')
                Write-FastLlmState -InstallRoot $InstallRoot -State $state
            } catch { }
            $canaryNote = ''
            if ($state.throughputCanary.status -eq 'degraded') {
                if ($state.throughputCanary.reason -eq 'timeout') { $canaryNote = ' The canary request timed out.' }
                else { $canaryNote = ' Prompt processing is below the per-card floor.' }
                if ($Plan.PSObject.Properties['backend'] -and [string]$Plan.backend -ieq 'vulkan') { $canaryNote += ' See doctor -ProbeVulkanMemory for Resizable BAR guidance.' }
            }
            $canaryFloor = if ($null -ne $state.throughputCanary.floor) { "floor $($state.throughputCanary.floor)" } else { 'no reviewed floor for this model and card' }
            Write-Host "Throughput canary (advisory): PP512 $($state.throughputCanary.ppTokPerS) tok/s, $canaryFloor, status $($state.throughputCanary.status).$canaryNote"
        }
        while (-not $hostProcess.Process.WaitForExit(250)) {
            if (Test-Path -LiteralPath $stopPath) { $state.phase='stopped'; return 0 }
        }
        $exitCode = $hostProcess.Process.ExitCode
        if ($exitCode -ne 0) { throw 'Server exited unexpectedly after readiness.' }
        $state.phase='stopped'
        return $exitCode
    } catch {
        $state.phase='failed'
        if ($_.Exception.Data['FastLlmStateWrite'] -eq $true) {
            # A status-file write failure is not a model/runtime failure: it must never trigger model-switch recovery.
            $state.failureCode='state-write-failed'
            $_.Exception.Data['FastLlmReason']='StateWriteFailed'
        } elseif ($_.Exception.Data['FastLlmReason'] -ceq 'DeviceBindingFailed') {
            # A device-binding failure (enforce) is not a model/runtime failure: keep its reason so it is never overwritten by
            # RuntimeCheckFailed and never triggers model recovery or a model swap. The code is sanitised; anything outside the
            # pattern is recorded as device-binding-unavailable.
            $bindingFailureCode=ConvertTo-FastLlmDeviceBindingCode -Code ([string]$_.Exception.Data['FastLlmFailureCode'])
            $state.failureCode=$bindingFailureCode
            # Write the sanitised value back so the supervisor state and the CLI's outer catch (which records Data into status.json) carry the same code.
            $_.Exception.Data['FastLlmFailureCode']=$bindingFailureCode
        } elseif ($_.Exception.Data['FastLlmReason'] -ceq 'HipDllFailed') {
            # A blocked or missing HIP DLL keeps its typed code and a reason that model recovery does not retry (recovery would re-plan onto Vulkan).
            $state.failureCode=[string]$_.Exception.Data['FastLlmFailureCode']
        } else {
            $state.failureCode='startup-or-runtime-check-failed'
            if($spawned){$_.Exception.Data['FastLlmReason']='RuntimeCheckFailed'}
        }
        throw
    } finally {
        try { $hostProcess.Dispose() }
        finally {
            try {
                $state.updatedAt=(Get-Date).ToUniversalTime().ToString('o')
                # The write already retries within a bounded budget; a transient failure must not turn a clean stop into exit 1.
                try { Write-FastLlmState -InstallRoot $InstallRoot -State $state }
                catch { if ($_.Exception.Data['FastLlmStateWrite'] -eq $true) { Write-Warning 'The final status write failed after retries; the previous status document is unchanged.' } else { throw } }
            } finally {
                try { Remove-FastLlmRuntimeSandbox $sandbox }
                finally {
                    # The request file is run-scoped, so a leftover is harmless; a sharing violation here is transient (the
                    # requesting client or a scanner still holds it) and must not turn a clean stop into exit 1.
                    for ($attempt = 0; (Test-Path -LiteralPath $stopPath); $attempt++) {
                        try { Remove-Item -LiteralPath $stopPath -Force -ErrorAction Stop; break }
                        catch {
                            if ($attempt -ge 9) { Write-Warning "The stop request file could not be removed after retries: $stopPath"; break }
                            Start-Sleep -Milliseconds 15
                        }
                    }
                }
            }
        }
    }
}
