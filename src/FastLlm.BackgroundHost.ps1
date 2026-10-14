# Private opt-in lab host. Source alongside the FastLlm module; this file does
# not change the foreground CLI or grant a model license.
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'FastLlm.FileReplace.ps1')

function Assert-FastLlmBackgroundNativeHost {
    if ($env:OS -cne 'Windows_NT' -or -not [Environment]::Is64BitProcess) {
        throw 'Background serving requires native 64-bit Windows.'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ((New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Background serving requires a standard-user session.'
    }
    if (-not ('Bitworks.FastLlm.BackgroundJobCheck' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
namespace Bitworks.FastLlm {
  public static class BackgroundJobCheck {
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);
    public static bool CurrentProcessIsInJob() {
      bool inJob;
      using (var process = Process.GetCurrentProcess()) {
        if (!IsProcessInJob(process.Handle, IntPtr.Zero, out inJob))
          throw new InvalidOperationException("Cannot determine process job containment.");
      }
      return inJob;
    }
  }
}
'@ -ErrorAction Stop
    }
    if ([Bitworks.FastLlm.BackgroundJobCheck]::CurrentProcessIsInJob()) {
        throw 'The current process is contained in a Windows job; a persistent host cannot be launched from it.'
    }
}

function Get-FastLlmBackgroundSourcePins {
    param([Parameter(Mandatory=$true)][string]$SourceRoot)
    $root = [IO.Path]::GetFullPath($SourceRoot)
    foreach ($folder in @($root,(Join-Path $root 'src'),(Join-Path $root 'tools'),(Join-Path $root 'config'))) {
        $item = Get-Item -LiteralPath $folder -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'A background source directory is unsafe.'
        }
    }
    $names = @(
        'src/FastLlm.BackgroundHost.ps1','tools/background-host.ps1',
        'src/FastLlm.psm1','src/FastLlm.Runtime.ps1','src/FastLlm.FileReplace.ps1','src/FastLlm.LabApp.ps1',
        'src/FastLlm.SelectedDeviceIdentity.ps1','src/FastLlm.OffloadLab.ps1',
        'src/FastLlm.Benchmark.ps1','src/FastLlm.OffloadBenchmark.ps1',
        'src/FastLlm.Soak.ps1','src/FastLlm.VulkanMemoryPolicy.ps1','src/FastLlm.SelfTest.ps1','src/FastLlm.DeviceBinding.ps1','src/WindowsBootTime.cs',
        'tools/collect-vulkan-luid-join.ps1','src/WindowsVulkanLuidJoin.cs','src/WindowsPciAddress.cs',
        'src/FastLlm.DriverGuidance.ps1',
        'src/FastLlm.DriverGuidanceView.ps1','src/FastLlm.PrerequisiteDiagnostics.ps1',
        'src/ProcessHost.cs','src/WindowsInventory.ps1',
        'src/WindowsInventory.cs','src/WindowsGpuIdentity.cs',
        'src/WindowsHostInventory.cs','src/WindowsGpuTelemetry.cs',
        'src/FastLlm.CardIdentity.ps1','src/FastLlm.Recipes.ps1',
        'config/catalog.json','config/recipes.json','config/gpu-variants.json'
    )
    $pins = [ordered]@{}
    foreach ($name in $names) {
        $path = [IO.Path]::GetFullPath((Join-Path $root $name))
        if (-not $path.StartsWith(($root.TrimEnd([char[]]@('\','/')) + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) {
            throw 'A background source path escaped its source root.'
        }
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'A background source file is not a regular file.'
        }
        $pins[$name] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    return $pins
}

function Assert-FastLlmBackgroundPrivateState {
    param([Parameter(Mandatory=$true)][string]$InstallRoot,[string]$RequestId)
    if ($env:OS -cne 'Windows_NT') { return }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $ownSid = $identity.User.Value
    $allowed = @($ownSid,'S-1-5-18','S-1-5-32-544','S-1-3-0') # owner, SYSTEM, Administrators, CREATOR OWNER
    $state = Split-Path -Parent (Get-FastLlmBackgroundPath -InstallRoot $InstallRoot -Leaf 'background-host.json')
    $writeMask = [int][Security.AccessControl.FileSystemRights]::WriteData -bor
        [int][Security.AccessControl.FileSystemRights]::AppendData -bor
        [int][Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
        [int][Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [int][Security.AccessControl.FileSystemRights]::Delete -bor
        [int][Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [int][Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [int][Security.AccessControl.FileSystemRights]::TakeOwnership
    $targets = @([IO.Path]::GetFullPath($InstallRoot),$state,
        (Join-Path $state 'operation.lock'),(Join-Path $state 'status.json'),
        (Join-Path $state 'background-host.json'))
    if ($RequestId) {
        if ($RequestId -cnotmatch '^[0-9a-f]{32}$') { throw 'Invalid background request ID.' }
        $targets += Join-Path $state ('background-request-' + $RequestId + '.json')
    }
    foreach ($target in $targets) {
        if (-not (Test-Path -LiteralPath $target)) { continue }
        # status.json and background-host.json are replaced while this runs (every poll): a file being replaced can read as
        # Attributes -1, vanish for a moment, or fail Get-Acl. Retry that transient state a bounded number of times (about 0.5 s);
        # a REAL reparse point is unsafe at once and is never retried.
        $attributes = $null
        $acl = $null
        for ($check = 0; ; $check++) {
            try {
                if (-not (Test-Path -LiteralPath $target)) { $attributes = $null; break }
                $attributes = [int](Get-Item -LiteralPath $target -Force -ErrorAction Stop).Attributes
                if ($attributes -eq -1) {
                    if ($check -ge 9) { $attributes = $null; break }
                    Start-Sleep -Milliseconds 50
                    continue
                }
                if ($attributes -band [int][IO.FileAttributes]::ReparsePoint) { break }
                $acl = Get-Acl -LiteralPath $target -ErrorAction Stop
                break
            } catch {
                if ($check -ge 9) { throw }
                Start-Sleep -Milliseconds 50
            }
        }
        if ($null -eq $attributes) { continue }
        if ($attributes -band [int][IO.FileAttributes]::ReparsePoint) { throw 'Unsafe background state path.' }
        $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        if ($owner -cne $ownSid) { throw 'Background state path is not owned by the current user.' }
        $rules = $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])
        foreach ($rule in @($rules)) {
            if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
            if ($rule.IdentityReference.Value -notin $allowed -and
                (([int]$rule.FileSystemRights -band $writeMask) -ne 0)) {
                throw 'Background state path grants write access to another principal.'
            }
        }
    }
}

function Assert-FastLlmBackgroundPins {
    param([string]$SourceRoot,$Expected)
    $actual = Get-FastLlmBackgroundSourcePins -SourceRoot $SourceRoot
    if (-not $Expected -or @($Expected.PSObject.Properties).Count -ne $actual.Count) {
        throw 'Background source pin set changed during handoff.'
    }
    foreach ($name in $actual.Keys) {
        $property = $Expected.PSObject.Properties[$name]
        if (-not $property -or [string]$property.Value -cne [string]$actual[$name]) {
            throw 'Background source changed during handoff.'
        }
    }
}

function Get-FastLlmBackgroundPath {
    param([string]$InstallRoot,[string]$Leaf,[switch]$NoCreate)
    if ($Leaf -notmatch '^(background-host\.json|background-request-[0-9a-f]{32}\.json)$') {
        throw 'Invalid background state file name.'
    }
    $root = [IO.Path]::GetFullPath($InstallRoot)
    $state = Join-Path $root 'state'
    foreach ($folder in @($root,$state)) {
        if (Test-Path -LiteralPath $folder) {
            $item = Get-Item -LiteralPath $folder -Force
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'Unsafe background state directory.'
            }
        }
    }
    if (-not $NoCreate) { New-Item -ItemType Directory -Path $state -Force | Out-Null }
    Join-Path $state $Leaf
}

function Read-FastLlmBackgroundDocument {
    param([string]$Path)
    # Share-delete open with a bounded retry (~150 ms): an atomic replace of this document must not read as missing or fail.
    # Attributes -1 (the name vanished mid-replace) is transient and counts as missing. A REAL reparse point, a folder, or a
    # size over the cap (judged on the opened handle, then by a read of at most cap+1 bytes) is unsafe at once: no retry.
    $cap = 16384
    $text = $null
    for ($attempt = 0; $null -eq $text; $attempt++) {
        $last = ($attempt -ge 9)
        $stream = $null
        try {
            $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
            if ([int]$item.Attributes -eq -1) {
                if ($last) { return $null }
                Start-Sleep -Milliseconds 15
                continue
            }
            if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'Unsafe background state document.'
            }
            $stream = New-Object IO.FileStream($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            if ($stream.Length -gt $cap) { throw 'Unsafe background state document.' }
            $buffer = New-Object byte[] ($cap + 1)
            $total = 0
            while ($total -le $cap) {
                $read = $stream.Read($buffer,$total,($cap + 1 - $total))
                if ($read -le 0) { break }
                $total += $read
            }
            if ($total -gt $cap) { throw 'Unsafe background state document.' }
            $memory = New-Object IO.MemoryStream($buffer,0,$total)
            try {
                $reader = New-Object IO.StreamReader($memory,(New-Object Text.UTF8Encoding($false)),$true)
                try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
            } finally { $memory.Dispose() }
        } catch {
            $failure = Get-FastLlmUnwrappedException $_.Exception
            if ($failure.Message -ceq 'Unsafe background state document.') { throw }
            $missing = ($failure -is [Management.Automation.ItemNotFoundException] -or $failure -is [IO.FileNotFoundException] -or $failure -is [IO.DirectoryNotFoundException])
            if ($last) { if ($missing) { return $null }; throw }
            Start-Sleep -Milliseconds 15
        } finally { if ($stream) { $stream.Dispose() } }
    }
    ConvertFrom-Json -InputObject $text -ErrorAction Stop
}

function Write-FastLlmBackgroundDocument {
    param([string]$Path,$Value,[switch]$CreateNew)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container) -or
        ((Get-Item -LiteralPath $parent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Unsafe background state directory.'
    }
    if (Test-Path -LiteralPath $Path) {
        # Attributes -1 (or a name that vanished between the checks) means missing, not a reparse point.
        $existing = -1
        try { $existing = [int](Get-Item -LiteralPath $Path -Force -ErrorAction Stop).Attributes }
        catch {
            $gone = Get-FastLlmUnwrappedException $_.Exception
            if (-not ($gone -is [Management.Automation.ItemNotFoundException] -or $gone -is [IO.FileNotFoundException] -or $gone -is [IO.DirectoryNotFoundException])) { throw }
        }
        if ($existing -ne -1 -and ($CreateNew -or ($existing -band [int][IO.FileAttributes]::ReparsePoint))) {
            throw 'Background state target already exists or is unsafe.'
        }
    }
    $json = ConvertTo-Json -InputObject $Value -Depth 12 -Compress
    if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 16384) { throw 'Background state document exceeds its size limit.' }
    $temp = Join-Path $parent ([Guid]::NewGuid().ToString('N') + '.background.tmp')
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json)
    $stream = [IO.File]::Open($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    $moved = $false
    try {
        if ($CreateNew) { [IO.File]::Move($temp,$Path) }
        else { Move-FastLlmFileReplacing -Source $temp -Destination $Path }
        $moved = $true
        # Success consumed the temp. Stale temps kept by earlier FAILED replaces are swept, best-effort.
        Remove-FastLlmStaleTemporaries -Folder $parent -NamePattern '^[0-9a-f]{32}\.background\.tmp$'
    } finally {
        # Best-effort. After a failed REPLACE the fully written temp is kept (it may be the only copy; File.Exists on the
        # destination is unreliable for a delete-pending file). The create-new path never replaced anything: remove its temp.
        if (-not $moved -and $CreateNew) { try { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } } catch { } }
    }
}

function Test-FastLlmBackgroundProcessIdentity {
    param($Identity)
    if (-not $Identity) { return $false }
    $pidValue = 0
    $ticks = 0L
    try {
        if (-not [int]::TryParse([string]$Identity.pid,[ref]$pidValue) -or $pidValue -le 0 -or
            -not [long]::TryParse([string]$Identity.startUtcTicks,[ref]$ticks) -or $ticks -le 0) { return $false }
    } catch { return $false }
    try {
        $process = [Diagnostics.Process]::GetProcessById($pidValue)
        try { return $process.StartTime.ToUniversalTime().Ticks -eq $ticks -and -not $process.HasExited }
        finally { $process.Dispose() }
    } catch { return $false }
}

function Test-FastLlmBackgroundLoopbackHealth {
    try {
        if (-not ('Bitworks.FastLlm.LoopbackHttp' -as [type])) {
            Add-Type -Path (Join-Path $PSScriptRoot 'ProcessHost.cs') -ErrorAction Stop
        }
        $response = [Bitworks.FastLlm.LoopbackHttp]::Request('http://127.0.0.1:8080/health',$null,1500,4096)
        if ($response.Status -ne 200) { return $false }
        $health = ConvertFrom-Json -InputObject $response.Body -ErrorAction Stop
        return [string]$health.status -ceq 'ok'
    } catch { return $false }
}

function Test-FastLlmBackgroundOperationOccupied {
    param([string]$InstallRoot)
    $root = Split-Path -Parent (Get-FastLlmBackgroundPath -InstallRoot $InstallRoot -Leaf 'background-host.json' -NoCreate)
    $path = Join-Path $root 'operation.lock'
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $item = Get-Item -LiteralPath $path -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Unsafe operation lock path.'
    }
    $handle = $null
    try { $handle = [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None); return $false }
    catch [IO.IOException] { return $true }
    finally { if ($handle) { $handle.Dispose() } }
}

function Get-FastLlmBackgroundHostStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$InstallRoot,
          [Parameter(Mandatory=$true)][string]$SourceRoot,
          [switch]$SkipHealth)
    $path = Get-FastLlmBackgroundPath -InstallRoot $InstallRoot -Leaf 'background-host.json' -NoCreate
    $owner = Read-FastLlmBackgroundDocument -Path $path
    if (-not $owner) {
        $unowned = Get-FastLlmStatus -InstallRoot $InstallRoot
        $unownedOccupied = [bool]($unowned.active -or (Test-FastLlmBackgroundOperationOccupied -InstallRoot $InstallRoot))
        return [pscustomobject]@{phase=if ($unownedOccupied) {'occupied-unverified'} else {'absent'};
            active=$false;attachable=$false;occupied=$unownedOccupied;requestId=$null;runId=$null}
    }
    if ($owner.schemaVersion -ne 1 -or $owner.kind -cne 'fastllm-private-background-host' -or
        [string]$owner.requestId -cnotmatch '^[0-9a-f]{32}$') { throw 'Invalid background host record.' }
    Assert-FastLlmBackgroundPrivateState -InstallRoot $InstallRoot -RequestId ([string]$owner.requestId)
    $alive = Test-FastLlmBackgroundProcessIdentity -Identity $owner.hostIdentity
    $sourceMatches = $false
    if ($SourceRoot) {
        $currentSource = [IO.Path]::GetFullPath($SourceRoot)
        $sourceMatches = [string]$owner.sourceRoot -ceq $currentSource
        if ($sourceMatches) {
            try {
                $backgroundPath = Join-Path $currentSource 'src\FastLlm.BackgroundHost.ps1'
                $sourceMatches = [string]$owner.sourcePinSha256 -ceq
                    (Get-FileHash -LiteralPath $backgroundPath -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($sourceMatches) {
                    $requestPath = Get-FastLlmBackgroundPath -InstallRoot $InstallRoot -Leaf ('background-request-' + [string]$owner.requestId + '.json')
                    $request = Read-FastLlmBackgroundDocument -Path $requestPath
                    if (-not $request -or $request.requestId -cne $owner.requestId) { $sourceMatches = $false }
                    else { Assert-FastLlmBackgroundPins -SourceRoot $currentSource -Expected $request.sourcePins }
                }
            } catch { $sourceMatches = $false }
        }
    }
    $status = Get-FastLlmStatus -InstallRoot $InstallRoot
    $occupied = [bool]($alive -or $status.active -or (Test-FastLlmBackgroundOperationOccupied -InstallRoot $InstallRoot))
    $active = [bool]($alive -and $sourceMatches -and $occupied -and $owner.phase -eq 'loading' -and
        $status.phase -in @('loading','checking','ready') -and
        $status.PSObject.Properties['runId'] -and [string]$status.runId -match '^[0-9a-f]{32}$' -and
        $status.PSObject.Properties['backgroundRequestId'] -and [string]$status.backgroundRequestId -ceq [string]$owner.requestId)
    $readyIdentity = [bool]($active -and $status.phase -eq 'ready' -and
        $status.PSObject.Properties['processIdentity'] -and
        (Test-FastLlmBackgroundProcessIdentity -Identity $status.processIdentity) -and
        [string]$status.endpoint -ceq 'http://127.0.0.1:8080/v1' -and
        [string]$status.modelId -ceq [string]$owner.modelId -and
        $status.PSObject.Properties['canary'] -and $null -ne $status.canary)
    $healthy = [bool]($readyIdentity -and -not $SkipHealth -and (Test-FastLlmBackgroundLoopbackHealth))
    return [pscustomobject]@{
        phase = if ($active) { [string]$status.phase } elseif ($occupied) { 'occupied-unverified' } elseif ($alive) { [string]$owner.phase } else { 'stale' }
        active = $active
        occupied = $occupied
        attachable = $healthy
        servingHealthy = $healthy
        readyIdentityVerified = $readyIdentity
        requestId = [string]$owner.requestId
        hostIdentity = $owner.hostIdentity
        runId = if ($active) { [string]$status.runId } else { $null }
        serverIdentity = if ($active) { $status.processIdentity } else { $null }
        endpoint = if ($active) { [string]$status.endpoint } else { $null }
        modelId = if ($active) { [string]$status.modelId } else { [string]$owner.modelId }
        failureCode = if (-not $alive) { [string]$owner.failureCode } else { $null }
        performanceQualified = $false
    }
}

function Attach-FastLlmBackgroundHost {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$InstallRoot,
          [Parameter(Mandatory=$true)][string]$SourceRoot,
          [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{32}$')][string]$ExpectedRequestId)
    $status = Get-FastLlmBackgroundHostStatus -InstallRoot $InstallRoot -SourceRoot $SourceRoot
    if (-not $status.attachable -or $status.requestId -cne $ExpectedRequestId) {
        throw 'There is no matching verified Ready background host to attach.'
    }
    return $status
}

function Stop-FastLlmBackgroundHost {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$InstallRoot,
          [Parameter(Mandatory=$true)][string]$SourceRoot,
          [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{32}$')][string]$ExpectedRequestId,
          [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{32}$')][string]$ExpectedRunId)
    $status = Get-FastLlmBackgroundHostStatus -InstallRoot $InstallRoot -SourceRoot $SourceRoot
    if (-not $status.active -or $status.requestId -cne $ExpectedRequestId -or
        [string]$status.runId -cne $ExpectedRunId) {
        throw 'Background run changed or is no longer active; stop was not sent.'
    }
    $root = Split-Path -Parent (Get-FastLlmBackgroundPath -InstallRoot $InstallRoot -Leaf 'background-host.json')
    $path = Join-Path $root ('stop-' + $ExpectedRunId)
    if (Test-Path -LiteralPath $path) {
        if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Unsafe stop marker.'
        }
    } else {
        try {
            $stream = [IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            $stream.Dispose()
        } catch [IO.IOException] {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
                ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw }
        }
    }
    return [pscustomobject]@{stopRequested=$true;runId=$ExpectedRunId;hostIdentity=$status.hostIdentity}
}

function Start-FastLlmBackgroundHost {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$SourceRoot,
          [Parameter(Mandatory=$true)][string]$InstallRoot,
          [ValidateSet('fast','balanced','quality')][string]$Profile='balanced',
          [string]$ModelId,[ValidateRange(0,1048576)][int]$ContextSize=0,
          [switch]$AllowExperimentalModel,
          [ValidateRange(10,1800)][int]$LoadTimeoutSeconds=300,
          [ValidateRange(15,1800)][int]$ReadyTimeoutSeconds=420,
          [ValidateSet('off','on','auto')][string]$VulkanBarMitigation='auto',
          [switch]$NoWait)
    Assert-FastLlmBackgroundNativeHost
    $source = [IO.Path]::GetFullPath($SourceRoot)
    $install = [IO.Path]::GetFullPath($InstallRoot)
    Assert-FastLlmBackgroundPrivateState -InstallRoot $install
    $existing = Get-FastLlmBackgroundHostStatus -InstallRoot $install -SourceRoot $source
    if ($existing.occupied) { throw 'This installation already has an active serving operation.' }
    $lock = Enter-FastLlmOperation -InstallRoot $install
    $lock.Dispose()
    $requestId = [Guid]::NewGuid().ToString('N')
    $request = [ordered]@{
        schemaVersion=1;kind='fastllm-private-background-request';requestId=$requestId
        sourceRoot=$source;installRoot=$install;profile=$Profile;modelId=$ModelId
        contextSize=$ContextSize;allowExperimentalModel=[bool]$AllowExperimentalModel
        loadTimeoutSeconds=$LoadTimeoutSeconds;vulkanBarMitigation=$VulkanBarMitigation.ToLowerInvariant();sourcePins=(Get-FastLlmBackgroundSourcePins -SourceRoot $source)
    }
    $requestPath = Get-FastLlmBackgroundPath -InstallRoot $install -Leaf ('background-request-' + $requestId + '.json')
    Write-FastLlmBackgroundDocument -Path $requestPath -Value $request -CreateNew
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $item = Get-Item -LiteralPath $powershell -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe Windows PowerShell executable.' }
    $tool = Join-Path $source 'tools\background-host.ps1'
    $safeTool = $tool.Replace("'","''")
    $safeInstall = $install.Replace("'","''")
    $command = "& '$safeTool' -RequestId '$requestId' -InstallRoot '$safeInstall'"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $powershell
    $info.Arguments = '-NoLogo -NoProfile -NonInteractive -EncodedCommand ' + $encoded
    $info.WorkingDirectory = $source
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $false
    $info.RedirectStandardError = $false
    $info.RedirectStandardInput = $false
    $process = [Diagnostics.Process]::Start($info)
    if (-not $process) { throw 'Background host process did not start.' }
    try {
        $hostId = [pscustomobject]@{pid=[int]$process.Id;startUtcTicks=[long]$process.StartTime.ToUniversalTime().Ticks}
        if ($NoWait) {
            return [pscustomobject]@{phase='starting';active=$false;attachable=$false;occupied=$true;
                requestId=$requestId;hostIdentity=$hostId;runId=$null;performanceQualified=$false}
        }
        $deadline = [Diagnostics.Stopwatch]::StartNew()
        while ($deadline.Elapsed.TotalSeconds -lt $ReadyTimeoutSeconds) {
            $status = Get-FastLlmBackgroundHostStatus -InstallRoot $install -SourceRoot $source
            if ($status.requestId -ceq $requestId -and
                $status.hostIdentity.pid -eq $hostId.pid -and
                $status.hostIdentity.startUtcTicks -eq $hostId.startUtcTicks) {
                if ($status.attachable) { return $status }
                if (-not $status.active -and -not (Test-FastLlmBackgroundProcessIdentity $hostId)) {
                    throw 'Background host exited before Ready; inspect its bounded host failure code.'
                }
            }
            if ($process.HasExited) { throw 'Background host exited before Ready.' }
            Start-Sleep -Milliseconds 250
        }
        throw 'Background readiness deadline elapsed; use status or exact run-scoped Stop to inspect the owner.'
    } finally { $process.Dispose() }
}

function Invoke-FastLlmBackgroundServe {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{32}$')][string]$RequestId,
          [Parameter(Mandatory=$true)][string]$InstallRoot,
          [Parameter(Mandatory=$true)][string]$SourceRoot)
    Assert-FastLlmBackgroundNativeHost
    $install = [IO.Path]::GetFullPath($InstallRoot)
    $source = [IO.Path]::GetFullPath($SourceRoot)
    Assert-FastLlmBackgroundPrivateState -InstallRoot $install -RequestId $RequestId
    $requestPath = Get-FastLlmBackgroundPath -InstallRoot $install -Leaf ('background-request-' + $RequestId + '.json')
    $request = Read-FastLlmBackgroundDocument -Path $requestPath
    if (-not $request -or $request.schemaVersion -ne 1 -or $request.kind -cne 'fastllm-private-background-request' -or
        $request.requestId -cne $RequestId -or $request.installRoot -cne $install -or $request.sourceRoot -cne $source) {
        throw 'Background request identity is invalid.'
    }
    # vulkanBarMitigation is validated (case-sensitive); a request written before the field existed means auto.
    $barMitigation = 'auto'
    if ($request.PSObject.Properties['vulkanBarMitigation']) { $barMitigation = [string]$request.vulkanBarMitigation }
    if ($barMitigation -cnotin @('off','on','auto')) { throw 'Background request vulkanBarMitigation is invalid.' }
    Assert-FastLlmBackgroundPins -SourceRoot $source -Expected $request.sourcePins
    $lease = $null
    $operation = $null
    $record = $null
    $recordPath = Get-FastLlmBackgroundPath -InstallRoot $install -Leaf 'background-host.json'
    try {
        . (Join-Path $source 'src\FastLlm.LabApp.ps1')
        $lease = Enter-FastLlmLabAppLifetime -SourceRoot $source
        Import-Module (Join-Path $source 'src\FastLlm.psm1') -Force
        $operation = Enter-FastLlmOperation -InstallRoot $install
        $self = [Diagnostics.Process]::GetCurrentProcess()
        try { $hostIdentity = [ordered]@{pid=[int]$self.Id;startUtcTicks=[long]$self.StartTime.ToUniversalTime().Ticks} }
        finally { $self.Dispose() }
        $record = [ordered]@{schemaVersion=1;kind='fastllm-private-background-host';requestId=$RequestId;
            hostIdentity=$hostIdentity;phase='preparing';modelId=$null;failureCode=$null;
            sourceRoot=$source;
            sourcePinSha256=(Get-FileHash -LiteralPath (Join-Path $source 'src\FastLlm.BackgroundHost.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()}
        Write-FastLlmBackgroundDocument -Path $recordPath -Value $record
        $catalog = Join-Path $source 'config\catalog.json'
        $hardware = Get-FastLlmHardware -CatalogPath $catalog -InstallRoot $install
        $plan = Get-FastLlmPlan -Hardware $hardware -CatalogPath $catalog -Profile ([string]$request.profile) `
            -InstallRoot $install -ModelId ([string]$request.modelId) -ContextSize ([int]$request.contextSize) `
            -AllowExperimentalModel:([bool]$request.allowExperimentalModel) `
            -RecipesPath (Join-Path $source 'config\recipes.json') -GpuVariantsPath (Join-Path $source 'config\gpu-variants.json')
        $plan | Add-Member -NotePropertyName backgroundRequestId -NotePropertyValue $RequestId -Force
        $record.modelId = [string]$plan.model.id
        $record.phase = 'loading'
        Write-FastLlmBackgroundDocument -Path $recordPath -Value $record
        Assert-FastLlmBackgroundPins -SourceRoot $source -Expected $request.sourcePins
        # This validates the installed engine, full model hash, exact consent,
        # then re-probes before using the normal supervised server. No install,
        # download, quarantine, or consent path is reachable here.
        $exit = Start-FastLlmServer -Plan $plan -CatalogPath $catalog -InstallRoot $install `
            -LoadTimeoutSeconds ([int]$request.loadTimeoutSeconds) -VulkanBarMitigation $barMitigation -SelfTest
        $record.phase = 'stopped'
        Write-FastLlmBackgroundDocument -Path $recordPath -Value $record
        return $exit
    } catch {
        if ($record) {
            $record.phase='failed'
            $record.failureCode = if ($_.Exception.Data['FastLlmReason']) { [string]$_.Exception.Data['FastLlmReason'] } else { 'background-start-or-runtime-failed' }
            try { Write-FastLlmBackgroundDocument -Path $recordPath -Value $record } catch {}
        }
        throw
    } finally {
        if ($operation) { $operation.Dispose() }
        if ($lease) { $lease.Dispose() }
    }
}
