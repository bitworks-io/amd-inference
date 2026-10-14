#requires -Version 5.1
param(
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$')][string] $Bdf,
    [switch] $LabOnly,
    [switch] $Worker
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
function Assert-PrivateWindowsLab {
    if (-not $IsWindows -and $PSVersionTable.PSVersion.Major -ge 6) { throw 'Windows x64 is required.' }
    if (-not [Environment]::Is64BitProcess -or [Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Windows x64 is required.' }
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run as a standard Windows user, not elevated.' }
    if (-not $LabOnly) { throw 'This unqualified private diagnostic requires -LabOnly.' }
}
Assert-PrivateWindowsLab
if ($Worker) {
    try {
        Add-Type -Path (Join-Path $repo 'src/WindowsVulkanPnPBridge.cs') -ErrorAction Stop
        $native = [Bitworks.FastLlm.WindowsVulkanPnPBridge]::Probe($Bdf)
        $report = [ordered]@{
            schemaVersion=1;kind='fastllm-private-vulkan-pnp-bridge';expectedBdf=$Bdf
            bdf=$native.Bdf;luid=$native.Luid;nodeMask=$native.NodeMask
            pnpInstanceId=$native.InstanceId;installedDriverVersion=$native.DriverVersion
            installedDriverProvider=$native.DriverProvider;installedDriverInf=$native.DriverInfPath
            unavailableReason=$native.Failure;bridgeAvailable=($null -eq $native.Failure)
            snapshotFrozen=$true
            sameProcess=$false;driverIdentityQualified=$false;compatibilityQualified=$false
            vulkanIcdBinaryVerified=$false;physicalResidencyVerified=$false
        }
    } catch {
        $report = [ordered]@{
            schemaVersion=1;kind='fastllm-private-vulkan-pnp-bridge';expectedBdf=$Bdf
            bdf=$null;luid=$null;nodeMask=$null;pnpInstanceId=$null
            installedDriverVersion=$null;installedDriverProvider=$null;installedDriverInf=$null
            unavailableReason='bridge-worker-failed';bridgeAvailable=$false
            snapshotFrozen=$true
            sameProcess=$false;driverIdentityQualified=$false;compatibilityQualified=$false
            vulkanIcdBinaryVerified=$false;physicalResidencyVerified=$false
        }
    }
    $json = $report | ConvertTo-Json -Compress -Depth 6
    $encoded = [Text.Encoding]::UTF8.GetBytes($json)
    # ProcessHost caps each native line at 8192 chars. Keep the entire marker
    # and base64 payload well below that bound, including non-ASCII metadata.
    if ($encoded.Length -gt 5600) { throw 'Bounded bridge output exceeded its limit.' }
    [Console]::Out.WriteLine('FASTLLM_BRIDGE_JSON:'+[Convert]::ToBase64String($encoded))
    return
}
if (-not ('Bitworks.FastLlm.ProcessHost' -as [type])) {
    Add-Type -Path (Join-Path $repo 'src/ProcessHost.cs') -ErrorAction Stop
}
Import-Module (Join-Path $repo 'src/FastLlm.psm1') -Force
$module = Get-Module FastLlm
$currentExe = (Get-Process -Id $PID).Path
if (-not [IO.Path]::IsPathRooted($currentExe)) { throw 'Cannot identify the current PowerShell executable.' }
$args = @('-NoLogo','-NoProfile','-NonInteractive','-File',$PSCommandPath,'-Bdf',$Bdf,'-LabOnly','-Worker')
$quoted = & $module {param($A) Join-FastLlmProcessArguments $A} $args
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = $currentExe
$info.Arguments = $quoted
$system = [Environment]::GetFolderPath([Environment+SpecialFolder]::System)
$windows = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
foreach ($key in @($info.EnvironmentVariables.Keys)) {
    if ($key -match '^(?i:VK_|VULKAN_|GGML_|LLAMA_|HIP_|HSA_|ROCR_|AMD_VULKAN_|DISABLE_LAYER_|LD_|DYLD_|PSMODULEPATH$)') {
        $info.EnvironmentVariables.Remove($key)
    }
}
$info.EnvironmentVariables['PATH'] = ($system+';'+$windows)
$hostProcess = New-Object Bitworks.FastLlm.ProcessHost
try {
    $hostProcess.Start($info)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    if (-not $hostProcess.Process.WaitForExit(60000)) { throw 'Bridge worker exceeded 60 seconds.' }
    while (-not $hostProcess.OutputCompleted -and $watch.ElapsedMilliseconds -lt 60000) { Start-Sleep -Milliseconds 20 }
    if (-not $hostProcess.OutputCompleted -or $hostProcess.OutputTruncated -or $hostProcess.Process.ExitCode -ne 0) {
        throw 'Bridge worker output was incomplete or failed.'
    }
    $lines = @($hostProcess.Snapshot() -split "`r?`n" | Where-Object { $_ -ne '' })
    if ($lines.Count -ne 1 -or $lines[0] -cnotmatch '^FASTLLM_BRIDGE_JSON:([A-Za-z0-9+/=]{1,7468})$') {
        throw 'Bridge worker returned unexpected output.'
    }
    $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1]))
    $report = $json | ConvertFrom-Json -ErrorAction Stop
    if ($report.kind -cne 'fastllm-private-vulkan-pnp-bridge' -or $report.expectedBdf -cne $Bdf -or
        $report.snapshotFrozen -ne $true -or $report.sameProcess -ne $false -or $report.driverIdentityQualified -ne $false -or
        $report.compatibilityQualified -ne $false) { throw 'Bridge worker report contract failed.' }
    $report | ConvertTo-Json -Depth 6
} finally { $hostProcess.Dispose() }
