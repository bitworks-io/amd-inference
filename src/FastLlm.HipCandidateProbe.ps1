#requires -Version 5.1
# Private, opt-in lab diagnostic. Never imported by the serving module.
$ErrorActionPreference = 'Stop'

$script:HipArchiveSha256 = 'cc9f6ce72a700507f0a1cb6b1e1a06481d7710a3bd433d0829e2f8762ee85a1d'
$script:HipFileSetSha256 = 'f8a5d8f4640c456fcee095d298a2a6aa1af0c8ba147c522766e74da08e9fdcf1'

function Assert-FastLlmHipLabIdentity {
    if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) { throw 'Private HIP probe requires 64-bit Windows.' }
    $principal = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Private HIP probe must run as a standard user.' }
}

function Assert-FastLlmHipNoReparseAncestors {
    param([Parameter(Mandatory=$true)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    while ($null -ne $item) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'HIP candidate path traverses a reparse point.'
        }
        $item = $item.Parent
    }
}

function Join-FastLlmHipProcessArguments {
    param([object[]]$Arguments)
    return (@($Arguments | ForEach-Object {
        $value = [string]$_
        if ($value.Length -gt 0 -and $value -notmatch '[\s"]') { $value }
        else {
            $escaped = [regex]::Replace($value, '(\\*)"', '$1$1\"')
            $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
            '"' + $escaped + '"'
        }
    }) -join ' ')
}

function ConvertTo-FastLlmHipWorkerLines {
    param([Parameter(Mandatory=$true)][string]$Json)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Json)
    if ($bytes.Length -gt 180000) { throw 'HIP worker report exceeds 180,000 bytes.' }
    $lines = New-Object System.Collections.Generic.List[string]
    $index = 0
    for ($offset = 0; $offset -lt $bytes.Length; $offset += 4096) {
        $length = [Math]::Min(4096,$bytes.Length - $offset)
        $lines.Add('FASTLLM_HIP_CHUNK:' + $index.ToString([Globalization.CultureInfo]::InvariantCulture) + ':' +
            [Convert]::ToBase64String($bytes,$offset,$length))
        $index++
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
    $lines.Add('FASTLLM_HIP_DONE:' + $index + ':' + $bytes.Length + ':' + $digest)
    return $lines.ToArray()
}

function ConvertFrom-FastLlmHipWorkerLines {
    param([Parameter(Mandatory=$true)][string]$OutputText,[bool]$WasTruncated)
    if ($WasTruncated -or $OutputText.Length -gt 250000) { throw 'HIP worker output was truncated or oversized.' }
    $lines = @($OutputText -split "`r?`n" | Where-Object { $_.Length -gt 0 })
    $chunks = New-Object System.Collections.Generic.List[byte[]]
    $done = $null
    [int64]$total = 0
    foreach ($line in $lines) {
        if ($line -cmatch '^FASTLLM_HIP_CHUNK:([0-9]{1,3}):([A-Za-z0-9+/=]{1,5500})$' -and $null -eq $done) {
            if ([int]$Matches[1] -ne $chunks.Count) { throw 'HIP worker report has an out-of-order chunk.' }
            $chunk = [Convert]::FromBase64String($Matches[2])
            if ($chunk.Length -gt 4096 -or $chunk.Length -eq 0) { throw 'HIP worker report chunk has invalid length.' }
            $chunks.Add($chunk)
            $total += $chunk.Length
            if ($total -gt 180000) { throw 'HIP worker report exceeds byte limit.' }
        } elseif ($line -cmatch '^FASTLLM_HIP_DONE:([0-9]{1,3}):([0-9]{1,6}):([0-9a-f]{64})$' -and $null -eq $done) {
            $done = [pscustomobject]@{ count=[int]$Matches[1]; length=[int]$Matches[2]; sha256=$Matches[3] }
        } else { throw 'HIP worker output contains an invalid or extra line.' }
    }
    if ($null -eq $done -or $done.count -ne $chunks.Count -or $done.length -ne $total -or $chunks.Count -eq 0) {
        throw 'HIP worker report is incomplete.'
    }
    for ($index = 0; $index -lt $chunks.Count - 1; $index++) {
        if ($chunks[$index].Length -ne 4096) { throw 'HIP worker report has a short non-final chunk.' }
    }
    $bytes = New-Object byte[] $total
    $offset = 0
    foreach ($chunk in $chunks) { [Array]::Copy($chunk,0,$bytes,$offset,$chunk.Length); $offset += $chunk.Length }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
    if ($digest -cne $done.sha256) { throw 'HIP worker report hash mismatch.' }
    $utf8 = [Text.UTF8Encoding]::new($false,$true)
    return $utf8.GetString($bytes)
}

function Assert-FastLlmHipArchive {
    param([Parameter(Mandatory=$true)][string]$ArchivePath, [Parameter(Mandatory=$true)]$Manifest)
    if ($Manifest.id -cne 'lemonade-hip-b1339-windows-gfx110x' -or $Manifest.executionEnabled -ne $false -or
        $Manifest.archive.sha256 -cne $script:HipArchiveSha256 -or
        [int64]$Manifest.archive.sizeBytes -ne 172433329 -or
        $Manifest.fileSetDigest.sha256 -cne $script:HipFileSetSha256 -or
        [int]$Manifest.extractedFileCount -ne 1081 -or [int64]$Manifest.extractedSizeBytes -ne 595119585) {
        throw 'The candidate manifest is not the reviewed disabled b1339 gfx110X experiment.'
    }
    $item = Get-Item -LiteralPath $ArchivePath -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -ne 172433329 -or
        (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -cne $script:HipArchiveSha256) {
        throw 'Candidate ZIP is not the reviewed exact artifact.'
    }
}

function Assert-FastLlmHipExtraction {
    param([Parameter(Mandatory=$true)][string]$CandidateRoot, [Parameter(Mandatory=$true)]$Manifest)
    Assert-FastLlmHipNoReparseAncestors -Path $CandidateRoot
    $root = (Get-Item -LiteralPath $CandidateRoot -Force -ErrorAction Stop).FullName
    $items = @(Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction Stop)
    $files = New-Object System.Collections.Generic.List[object]
    [int64]$bytes = 0
    foreach ($item in $items) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Candidate extraction contains a reparse point.' }
        if ($item.PSIsContainer) { continue }
        $relative = $item.FullName.Substring($root.Length).TrimStart([char]'\',[char]'/').Replace('\','/')
        if ($relative -notmatch '^[A-Za-z0-9_./+-]+$' -or $relative.Contains('..') -or $relative.Contains(':')) {
            throw 'Candidate extraction contains an invalid path.'
        }
        $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $files.Add([pscustomobject]@{ path=$relative; size=[int64]$item.Length; hash=$hash })
        $bytes += [int64]$item.Length
    }
    if ($files.Count -ne 1081 -or $bytes -ne 595119585) { throw 'Candidate extraction has the wrong full file count or byte count.' }
    $paths = [string[]]@($files | ForEach-Object { $_.path })
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    $byPath = @{}
    foreach ($file in $files) { $byPath[$file.path] = $file }
    $builder = New-Object Text.StringBuilder
    foreach ($path in $paths) {
        $file = $byPath[$path]
        [void]$builder.Append($file.path).Append([char]0).Append($file.size.ToString([Globalization.CultureInfo]::InvariantCulture)).Append([char]0).Append($file.hash).Append("`n")
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($builder.ToString())))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
    if ($digest -cne $script:HipFileSetSha256 -or $digest -cne $Manifest.fileSetDigest.sha256) {
        throw 'Candidate extraction fails the complete file-set digest.'
    }
    $server = Join-Path $root 'llama-server.exe'
    $entry = @($Manifest.verifiedFiles | Where-Object { $_.path -ceq 'llama-server.exe' })
    if ($entry.Count -ne 1 -or (Get-FileHash -LiteralPath $server -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry[0].sha256) {
        throw 'Candidate server entry point fails its explicit pin.'
    }
    return $server
}

function Get-FastLlmHipModuleSnapshot {
    param([Parameter(Mandatory=$true)][Diagnostics.Process]$Process, [Parameter(Mandatory=$true)][string]$CandidateRoot,
          [Parameter(Mandatory=$true)][Diagnostics.Stopwatch]$Watch, [int]$DeadlineMilliseconds)
    if ($Watch.ElapsedMilliseconds -ge $DeadlineMilliseconds) { return [pscustomobject]@{ complete=$false; reason='deadline'; modules=@() } }
    $rows = New-Object System.Collections.Generic.List[object]
    try {
        $Process.Refresh()
        $modules = @($Process.Modules)
        if ($modules.Count -gt 256) { return [pscustomobject]@{ complete=$false; reason='module-count-limit'; modules=@() } }
        foreach ($module in $modules) {
            if ($Watch.ElapsedMilliseconds -ge $DeadlineMilliseconds) { return [pscustomobject]@{ complete=$false; reason='deadline'; modules=@() } }
            $path = [string]$module.FileName
            if ([string]::IsNullOrWhiteSpace($path)) { return [pscustomobject]@{ complete=$false; reason='missing-path'; modules=@() } }
            $category = if ($path.StartsWith($CandidateRoot + '\',[StringComparison]::OrdinalIgnoreCase)) { 'candidate' }
                elseif ($path.StartsWith([Environment]::SystemDirectory + '\',[StringComparison]::OrdinalIgnoreCase)) { 'system32' }
                elseif ($path.StartsWith($env:SystemRoot + '\',[StringComparison]::OrdinalIgnoreCase)) { 'windows-or-driver' }
                else { 'external' }
            $rows.Add([pscustomobject]@{ name=[IO.Path]::GetFileName($path); path=$path; category=$category })
        }
        return [pscustomobject]@{ complete=($rows.Count -gt 0); reason=$(if($rows.Count -gt 0){$null}else{'no-modules-observed'}); modules=$rows.ToArray() }
    } catch { return [pscustomobject]@{ complete=$false; reason='module-enumeration-failed'; modules=@() } }
}

function Test-FastLlmHipDeviceRow {
    param([Parameter(Mandatory=$true)][string]$OutputText)
    $pattern = '^\s*(?<device>[A-Za-z]+\d+):\s+(?<name>.+)\s+\((?<total>\d+)\s+MiB,\s*(?<free>\d+)\s+MiB\s+free\)\s*$'
    $deviceRows = New-Object System.Collections.Generic.List[object]
    foreach ($line in ($OutputText -split "`r?`n")) {
        $match = [regex]::Match($line,$pattern)
        if (-not $match.Success -or $match.Groups['device'].Value -cne 'ROCm0') { continue }
        $name = $match.Groups['name'].Value.Trim()
        [int64]$total = 0
        [int64]$free = 0
        if (-not [int64]::TryParse($match.Groups['total'].Value,[ref]$total) -or
            -not [int64]::TryParse($match.Groups['free'].Value,[ref]$free)) { continue }
        if ($total -le 0 -or $free -lt 0 -or $free -gt $total -or
            $name -notmatch '(?i)\b(?:AMD\s+)?Radeon\b' -or
            $name -match '(?i)\b(?:integrated|graphics|apu)\b') { continue }
        $deviceRows.Add([pscustomobject]@{ device='ROCm0'; name=$name; totalMiB=$total; freeMiB=$free })
    }
    return ($deviceRows.Count -eq 1)
}

function Invoke-FastLlmHipCandidateProbe {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$ArchivePath,
          [Parameter(Mandatory=$true)][string]$OutputParent,
          [ValidateRange(5,60)][int]$TimeoutSeconds=20)
    Assert-FastLlmHipLabIdentity
    $projectRoot = Split-Path $PSScriptRoot -Parent
    $manifest = Get-Content -LiteralPath (Join-Path $projectRoot 'config/experiments/lemonade-hip-b1339-gfx110x.json') -Raw | ConvertFrom-Json
    Assert-FastLlmHipArchive -ArchivePath $ArchivePath -Manifest $manifest
    Assert-FastLlmHipNoReparseAncestors -Path $OutputParent
    $parent = Get-Item -LiteralPath $OutputParent -Force -ErrorAction Stop
    if (-not $parent.PSIsContainer -or ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Output parent must be a real directory.' }
    $profile = (Get-Item -LiteralPath $env:USERPROFILE -Force -ErrorAction Stop).FullName.TrimEnd('\')
    if (-not $parent.FullName.StartsWith($profile + '\',[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Output parent must be a directory within the current standard-user profile.'
    }
    $candidate = Join-Path $parent.FullName ('hip-b1339-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $candidate -ErrorAction Stop | Out-Null
    # The exact archive is hashed before expansion; never reuse or overwrite an existing extraction.
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $candidate -ErrorAction Stop
    $server = Assert-FastLlmHipExtraction -CandidateRoot $candidate -Manifest $manifest
    if (-not ('Bitworks.FastLlm.ProcessHost' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'ProcessHost.cs') -ErrorAction Stop }
    $worker = Join-Path $projectRoot 'tools/hip-candidate-native-worker.ps1'
    $controller = New-Object Bitworks.FastLlm.ProcessHost
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = (Get-Process -Id $PID).Path
        $info.Arguments = Join-FastLlmHipProcessArguments -Arguments @('-NoLogo','-NoProfile','-NonInteractive',
            '-ExecutionPolicy','RemoteSigned','-File',$worker,'-CandidateRoot',$candidate,'-TimeoutSeconds',$TimeoutSeconds)
        $info.WorkingDirectory = $projectRoot
        $controller.Start($info)
        # Includes every potentially blocking Process.Modules/hash/Authenticode call in the native worker.
        $deadline = 120000
        if (-not $controller.Process.WaitForExit($deadline)) { throw 'HIP native worker exceeded its 120-second deadline.' }
        while (-not $controller.OutputCompleted -and $watch.ElapsedMilliseconds -lt $deadline) { Start-Sleep -Milliseconds 10 }
        if (-not $controller.OutputCompleted -or $controller.OutputTruncated) { throw 'HIP native worker output is incomplete or truncated.' }
        $output = $controller.Snapshot()
        if ($controller.Process.ExitCode -ne 0) { throw ('HIP native worker failed: ' + $output.Substring(0,[Math]::Min(2000,$output.Length))) }
        $json = ConvertFrom-FastLlmHipWorkerLines -OutputText $output -WasTruncated $controller.OutputTruncated
        $result = ConvertFrom-Json -InputObject $json -ErrorAction Stop
        if ($result.schemaVersion -ne 1 -or $result.advisoryOnly -ne $true -or $result.qualification -ne $false -or
            $result.preLaunchFileSetVerified -ne $true -or $result.dynamicClosureVerified -ne $false -or
            $result.archiveSha256 -cne $script:HipArchiveSha256 -or
            $result.candidateRoot -cne $candidate) { throw 'HIP native worker returned invalid result metadata.' }
        return $result
    } finally { $controller.Dispose() }
}

function Invoke-FastLlmHipNativePhase {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$CandidateRoot, [ValidateRange(5,60)][int]$TimeoutSeconds=20)
    Assert-FastLlmHipLabIdentity
    $projectRoot = Split-Path $PSScriptRoot -Parent
    $manifest = Get-Content -LiteralPath (Join-Path $projectRoot 'config/experiments/lemonade-hip-b1339-gfx110x.json') -Raw | ConvertFrom-Json
    $candidate = (Get-Item -LiteralPath $CandidateRoot -Force -ErrorAction Stop).FullName
    Assert-FastLlmHipNoReparseAncestors -Path $candidate
    if (-not ('Bitworks.FastLlm.ProcessHost' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'ProcessHost.cs') -ErrorAction Stop }
    $parent = Get-Item -LiteralPath (Split-Path $candidate -Parent) -Force -ErrorAction Stop
    $sandbox = Join-Path $parent.FullName ('hip-probe-sandbox-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $sandbox -ErrorAction Stop | Out-Null
    $results = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($argument in @('--help','--list-devices')) {
            # The previous native process may have changed the folder. Recheck all files just before each launch.
            $server = Assert-FastLlmHipExtraction -CandidateRoot $candidate -Manifest $manifest
            $hostProcess = New-Object Bitworks.FastLlm.ProcessHost
            $watch = [Diagnostics.Stopwatch]::StartNew()
            try {
                $info = New-Object Diagnostics.ProcessStartInfo
                $info.FileName = $server
                $info.Arguments = $argument
                $info.WorkingDirectory = $candidate
                foreach ($name in @($info.EnvironmentVariables.Keys)) {
                    if ($name -match '^(?i:LLAMA_|GGML_|VK_|VULKAN_|HIP_|ROCM_|ROCR_|HSA_|ROCBLAS_|CUDA_|AMD_|SMITHY_|AIP_)' -or
                        $name -in @('MTMD_BACKEND_DEVICE','HF_TOKEN','GPU_DEVICE_ORDINAL')) {
                        $info.EnvironmentVariables.Remove([string]$name)
                    }
                }
                $info.EnvironmentVariables['APPDATA'] = $sandbox
                $info.EnvironmentVariables['PROGRAMDATA'] = $sandbox
                $info.EnvironmentVariables['PATH'] = "$candidate;$([Environment]::SystemDirectory);$env:SystemRoot"
                $hostProcess.Start($info)
                $deadline = $TimeoutSeconds * 1000
                $snapshots = New-Object System.Collections.Generic.List[object]
                while (-not $hostProcess.Process.WaitForExit(25)) {
                    if ($watch.ElapsedMilliseconds -ge $deadline) { throw "Candidate $argument exceeded deadline." }
                    if ($snapshots.Count -lt 8) { $snapshots.Add((Get-FastLlmHipModuleSnapshot -Process $hostProcess.Process -CandidateRoot $candidate -Watch $watch -DeadlineMilliseconds $deadline)) }
                }
                while (-not $hostProcess.OutputCompleted -and $watch.ElapsedMilliseconds -lt $deadline) { Start-Sleep -Milliseconds 10 }
                if (-not $hostProcess.OutputCompleted -or $hostProcess.OutputTruncated) { throw "Candidate $argument output incomplete or truncated." }
                $output = $hostProcess.Snapshot()
                if ($output.Length -gt 65536) { throw "Candidate $argument output exceeds report limit." }
                $observed = @($snapshots | Where-Object { $_.complete })
                $unique = @($observed | ForEach-Object { $_.modules } | Sort-Object -Property path -Unique)
                $moduleRows = New-Object System.Collections.Generic.List[object]
                foreach ($module in $unique) {
                    if ($watch.ElapsedMilliseconds -ge $deadline) { break }
                    try {
                        $item = Get-Item -LiteralPath $module.path -Force -ErrorAction Stop
                        $hash = (Get-FileHash -LiteralPath $module.path -Algorithm SHA256).Hash.ToLowerInvariant()
                        $signature = (Get-AuthenticodeSignature -LiteralPath $module.path).Status.ToString()
                        $moduleRows.Add([pscustomobject]@{ name=$module.name; path=$module.path; category=$module.category; sizeBytes=[int64]$item.Length; sha256=$hash; signatureStatus=$signature })
                    } catch { $moduleRows.Add([pscustomobject]@{ name=$module.name; path=$module.path; category=$module.category; sizeBytes=$null; sha256=$null; signatureStatus='unavailable' }) }
                }
                $captureComplete = $observed.Count -gt 0 -and $moduleRows.Count -eq $unique.Count -and
                    @($moduleRows | Where-Object { $null -eq $_.sha256 }).Count -eq 0
                $externalRuntime = @($moduleRows | Where-Object {
                    ($_.category -ne 'candidate' -and $_.name -match '^(?i:ggml|llama|hipblas|rocblas|rocsolver|amdhip|amd_comgr|libhipblas|libtensile|rocm_kpack)') -or
                    ($_.category -notin @('candidate','system32') -and $_.name -match '^(?i:vcruntime|msvcp|concrt)')
                })
                $hasRocmDevice = Test-FastLlmHipDeviceRow -OutputText $output
                $diagnosticLines = @($output -split "`r?`n" | Where-Object { $_ -match '(?i)error|fail|missing|could not|hip|roc|hsa|\.dll|device' } |
                    Select-Object -First 20 | ForEach-Object { if ($_.Length -gt 512) { $_.Substring(0,512) } else { $_ } })
                $captureReasons = @($snapshots | Where-Object { -not $_.complete } | ForEach-Object { $_.reason } | Select-Object -Unique)
                if ($observed.Count -eq 0) { $captureReasons += 'no-live-snapshot' }
                if ($moduleRows.Count -ne $unique.Count) { $captureReasons += 'hash-or-signature-deadline' }
                if (@($moduleRows | Where-Object { $null -eq $_.sha256 }).Count -gt 0) { $captureReasons += 'hash-or-signature-unavailable' }
                $ambientStatus = if ($externalRuntime.Count -gt 0) { 'observed' }
                    elseif ($captureComplete) { 'none-observed-in-snapshots' }
                    else { 'unknown' }
                $results.Add([pscustomobject]@{ argument=$argument; exitCode=$hostProcess.Process.ExitCode;
                    moduleCapture=$(if($captureComplete){'observed-snapshot-only'}else{'inconclusive'});
                    moduleCaptureReasons=@($captureReasons | Select-Object -Unique);
                    noncandidateRuntimeStatus=$ambientStatus; noncandidateRuntimeObserved=$(if($ambientStatus -eq 'unknown'){$null}else{$externalRuntime.Count -gt 0});
                    rocmDeviceObserved=$(if($argument -eq '--list-devices'){$hasRocmDevice}else{$null}); modules=$moduleRows.ToArray();
                    deviceLines=@($output -split "`r?`n" | Where-Object { $_ -match '(?i)ROCm[0-9]+|AMD Radeon|gfx1100' } | Select-Object -First 16);
                    diagnosticLines=$diagnosticLines;
                    outputSha256=$(Get-FastLlmHipTextHash -Text $output) })
                if ($hostProcess.Process.ExitCode -ne 0 -or $externalRuntime.Count -gt 0 -or
                    ($argument -eq '--list-devices' -and -not $hasRocmDevice)) { break }
            } finally { $hostProcess.Dispose() }
        }
    } finally { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
    $nativePassed = $results.Count -eq 2 -and @($results | Where-Object { $_.exitCode -ne 0 -or $_.noncandidateRuntimeStatus -eq 'observed' }).Count -eq 0 -and
        $results[1].rocmDeviceObserved -eq $true
    return [pscustomobject]@{ schemaVersion=1; advisoryOnly=$true; archiveSha256=$script:HipArchiveSha256;
        candidateRoot=$candidate; preLaunchFileSetVerified=$true; nativeProbePassed=[bool]$nativePassed;
        dynamicClosureVerified=$false; qualification=$false; probes=$results.ToArray() }
}

function Get-FastLlmHipTextHash { param([string]$Text)
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
