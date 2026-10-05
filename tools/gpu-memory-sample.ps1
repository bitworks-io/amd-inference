#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$InstallRoot,
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{32}$')][string]$RunId,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [ValidateRange(1,600)][int]$Samples=12,
    [ValidateRange(1,60)][int]$IntervalSeconds=5
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
if($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess){throw 'GPU telemetry requires 64-bit Windows PowerShell.'}
if($Samples * $IntervalSeconds -gt 3600){throw 'GPU telemetry is limited to one hour.'}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$principal=New-Object Security.Principal.WindowsPrincipal($identity)
if($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    throw 'GPU telemetry must run as the same standard user as the supervised server.'
}

$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force
Add-Type -Path (Join-Path $root 'src/WindowsGpuTelemetry.cs') -ErrorAction Stop

function Assert-FastLlmTelemetryTarget {
    param([string]$ExpectedRunId,[int]$ExpectedPid,[long]$ExpectedStartTicks)
    $status=Get-FastLlmStatus -InstallRoot $InstallRoot
    if(-not $status.active -or $status.phase -ne 'ready' -or $status.runId -cne $ExpectedRunId -or -not $status.recipe){
        throw 'The supervised ready run changed or stopped.'
    }
    if(-not $status.PSObject.Properties['processIdentity'] -or -not $status.processIdentity -or
        -not $status.processIdentity.PSObject.Properties['pid'] -or
        -not $status.processIdentity.PSObject.Properties['startUtcTicks'] -or
        -not [Bitworks.FastLlm.WindowsGpuTelemetry]::MatchesSupervisedProcessIdentity(
            $ExpectedPid,$ExpectedStartTicks,[int]$status.processIdentity.pid,[long]$status.processIdentity.startUtcTicks)){
        throw 'The run does not attest this exact supervised child process.'
    }
    $endpoint=[uri]$status.endpoint
    if($endpoint.Scheme -ne 'http' -or $endpoint.Host -ne '127.0.0.1' -or $endpoint.AbsolutePath -ne '/v1'){
        throw 'Telemetry requires the supervised loopback endpoint.'
    }
    $owners=@([Bitworks.FastLlm.WindowsGpuTelemetry]::GetLoopbackListenerOwners($endpoint.Port))
    if($owners.Count -ne 1 -or [int]$owners[0] -ne $ExpectedPid){throw 'The loopback listener owner changed.'}
    $process=[Diagnostics.Process]::GetProcessById($ExpectedPid)
    try{
        if($process.HasExited -or $process.ProcessName -ne 'llama-server' -or
            $process.StartTime.ToUniversalTime().Ticks -ne $ExpectedStartTicks){
            throw 'The listener process identity changed.'
        }
    }finally{$process.Dispose()}
    return $status
}

$initial=Get-FastLlmStatus -InstallRoot $InstallRoot
if(-not $initial.active -or $initial.phase -ne 'ready' -or $initial.runId -cne $RunId -or -not $initial.recipe){
    throw 'An exact active ready run ID is required.'
}
if(-not $initial.PSObject.Properties['processIdentity'] -or -not $initial.processIdentity -or
    -not $initial.processIdentity.PSObject.Properties['pid'] -or
    -not $initial.processIdentity.PSObject.Properties['startUtcTicks']){
    throw 'This run predates supervisor child identity recording; restart with the updated supervisor.'
}
$endpoint=[uri]$initial.endpoint
if($endpoint.Scheme -ne 'http' -or $endpoint.Host -ne '127.0.0.1' -or $endpoint.AbsolutePath -ne '/v1'){
    throw 'Telemetry requires the supervised loopback endpoint.'
}
$owners=@([Bitworks.FastLlm.WindowsGpuTelemetry]::GetLoopbackListenerOwners($endpoint.Port))
if($owners.Count -ne 1){throw 'Cannot identify one exact loopback listener owner.'}
$serverPid=[int]$owners[0]
$recordedPid=[int]$initial.processIdentity.pid
$recordedStartTicks=[long]$initial.processIdentity.startUtcTicks
if($recordedPid -le 0 -or $recordedStartTicks -le 0 -or $serverPid -ne $recordedPid){
    throw 'The loopback listener is not the supervisor-recorded child process.'
}
$server=[Diagnostics.Process]::GetProcessById($serverPid)
try{
    if($server.HasExited -or $server.ProcessName -ne 'llama-server'){throw 'The listener is not llama-server.'}
    $startTicks=$server.StartTime.ToUniversalTime().Ticks
    $executable=$server.MainModule.FileName
}finally{$server.Dispose()}
if($startTicks -ne $recordedStartTicks){throw 'The supervisor-recorded child start time does not match the listener.'}
if((Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$initial.recipe.engineSha256){
    throw 'The loopback listener binary differs from the supervised recipe.'
}
Assert-FastLlmTelemetryTarget -ExpectedRunId $RunId -ExpectedPid $serverPid -ExpectedStartTicks $startTicks | Out-Null

$readings=New-Object 'System.Collections.Generic.List[object]'
$clock=[Diagnostics.Stopwatch]::StartNew()
for($index=0;$index -lt $Samples;$index++){
    if($index -gt 0){Start-Sleep -Seconds $IntervalSeconds}
    if($clock.Elapsed.TotalSeconds -gt 3600){throw 'GPU telemetry exceeded its one-hour deadline.'}
    Assert-FastLlmTelemetryTarget -ExpectedRunId $RunId -ExpectedPid $serverPid -ExpectedStartTicks $startTicks | Out-Null
    $rows=@([Bitworks.FastLlm.WindowsGpuTelemetry]::ReadProcessMemory($serverPid))
    if($clock.Elapsed.TotalSeconds -gt 3600){throw 'GPU telemetry exceeded its one-hour deadline.'}
    Assert-FastLlmTelemetryTarget -ExpectedRunId $RunId -ExpectedPid $serverPid -ExpectedStartTicks $startTicks | Out-Null
    if($rows.Count -eq 0 -or $rows.Count -gt 16 -or @($rows | Where-Object { $null -eq $_.DedicatedBytes }).Count){
        throw 'No bounded per-process dedicated GPU counter sample is available.'
    }
    $readings.Add([pscustomobject]@{
        elapsedMs=[Math]::Round($clock.Elapsed.TotalMilliseconds,0)
        observedAt=(Get-Date).ToUniversalTime().ToString('o')
        adapters=@($rows | ForEach-Object { [pscustomobject]@{
            luid=$_.Luid;physicalAdapterIndex=$_.PhysicalAdapterIndex
            dedicatedBytes=$_.DedicatedBytes;sharedBytes=$_.SharedBytes;committedBytes=$_.CommittedBytes
        } })
    })
}

$report=[ordered]@{
    schemaVersion=1;kind='windows-pdh-gpu-process-memory-diagnostic'
    runId=$RunId;serverPid=$serverPid;serverStartUtcTicks=$startTicks
    samples=$readings.ToArray();requestedSampleCount=$Samples;intervalSeconds=$IntervalSeconds
    source='PdhAddEnglishCounterW:GPU Process Memory'
    processBinding='exact supervisor-recorded child PID and UTC start ticks, active-run loopback listener, executable SHA-256'
    adapterJoin='WDDM LUID only; not joined to llama.cpp Vulkan device or stable PCI identity'
    physicalResidencyVerified=$false;qualificationApproved=$false
    limitations=@('Microsoft documents incorrect GPU Process Memory dedicated values on affected Windows systems.',
                  'Per-process counters can double-count cross-process shared resources and cannot prove tensor or operation residency.',
                  'Committed bytes are reservations, not dedicated-memory residency; missing optional counters remain null.',
                  'The listener PID and start time are checked against the supervisor-recorded child identity and active run on each sample.')
}
$full=[IO.Path]::GetFullPath($OutputPath)
$parent=Split-Path $full -Parent
New-Item -ItemType Directory -Path $parent -Force | Out-Null
$stream=[IO.File]::Open($full,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try{
    $bytes=[Text.Encoding]::UTF8.GetBytes(($report | ConvertTo-Json -Depth 8))
    $stream.Write($bytes,0,$bytes.Length)
}finally{$stream.Dispose()}
Write-Host "GPU diagnostic samples saved: $Samples. These counters do not verify physical residency."
