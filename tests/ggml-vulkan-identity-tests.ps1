#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/FastLlm.GgmlVulkanIdentity.ps1')
Add-Type -Path (Join-Path $root 'src/WindowsGgmlVulkanIdentity.cs')

$checks = 0
function Check([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Expect-Reject($Snapshot, [string]$Message) {
    $rejected = $false
    try { Assert-FastLlmGgmlVulkanIdentitySnapshot -Snapshot $Snapshot }
    catch { $rejected = $true }
    Check $rejected $Message
}

$pin = '31e2fe70d4864a4ae6a4e7d8e102ee9203ba18963077e7727c54f9bd6ae3bea5'
$snapshot = [pscustomobject]@{
    schemaVersion=1; applicable=$true; qualified=$false
    identityScope='independent-process-advisory'; sourceEngineArchiveSha256=$pin
    devices=@([pscustomobject]@{ Name='Vulkan0'; Backend='Vulkan'; Description='AMD Radeon RX 7900 XTX'
        MemoryFreeBytes=[int64]20GB; MemoryTotalBytes=[int64]24GB; DeviceId='0000:03:00.0' })
}
Assert-FastLlmGgmlVulkanIdentitySnapshot -Snapshot $snapshot
Check $true 'Valid GGML advisory snapshot should be accepted.'
$snapshot.devices[0].DeviceId = $null
Assert-FastLlmGgmlVulkanIdentitySnapshot -Snapshot $snapshot
Check $true 'Unavailable PCI ID must remain a valid null.'
$snapshot.devices[0].DeviceId = '0000:03:00.0'
$snapshot.qualified = $true
Expect-Reject $snapshot 'Worker may not claim qualification.'
$snapshot.qualified = $false
$snapshot.devices[0].DeviceId = 'PCI\\VEN_1002'
Expect-Reject $snapshot 'Free-form identity is not a validated BDF.'
$snapshot.devices[0].DeviceId = '0000:03:00.0'
$snapshot.devices[0].Name = 'Vulkan1'
Expect-Reject $snapshot 'Non-contiguous GGML device names must be rejected.'
$snapshot.devices[0].Name = 'Vulkan0'
$snapshot.devices[0].MemoryFreeBytes = [int64]25GB
Expect-Reject $snapshot 'Impossible memory values must be rejected.'
$snapshot.devices[0].MemoryFreeBytes = [int64]20GB
$snapshot.devices[0].MemoryFreeBytes = 1.5
Expect-Reject $snapshot 'Fractional memory values must be rejected without integer casting.'
$snapshot.devices[0].MemoryFreeBytes = '12345'
Expect-Reject $snapshot 'String memory values must be rejected without integer casting.'
$snapshot.devices[0].MemoryFreeBytes = [int64]20GB
$snapshot.sourceEngineArchiveSha256 = ('0' * 64)
Expect-Reject $snapshot 'An unpinned source engine must be rejected.'
$snapshot.sourceEngineArchiveSha256 = $pin
$snapshot.devices = @(0..8 | ForEach-Object {
    [pscustomobject]@{ Name="Vulkan$_"; Backend='Vulkan'; Description='AMD Radeon RX 7900 XTX'
        MemoryFreeBytes=[int64]20GB; MemoryTotalBytes=[int64]24GB; DeviceId=$null }
})
Expect-Reject $snapshot 'A ninth Vulkan device must be rejected.'

$workerText = Get-Content -LiteralPath (Join-Path $root 'tools/collect-ggml-vulkan-identity.ps1') -Raw
$csText = Get-Content -LiteralPath (Join-Path $root 'src/WindowsGgmlVulkanIdentity.cs') -Raw
$helperText = Get-Content -LiteralPath (Join-Path $root 'src/FastLlm.GgmlVulkanIdentity.ps1') -Raw
Check ($workerText.Contains('Test-FastLlmEngineInstallation') -and $workerText.Contains('Get-FastLlmEngineExecutable')) 'Worker must check the full installed manifest and derived path.'
Check ($csText.Contains('SetDefaultDllDirectories') -and $csText.Contains('AddDllDirectory') -and $csText.Contains('LoadLibraryExW')) 'Native loader must use a restricted explicit directory.'
Check ($csText.Contains('ggml_backend_load') -and $csText.Contains('ggml_backend_dev_get_props') -and -not $csText.Contains('DllImport("ggml.dll"')) 'Worker must use the pinned GGML C ABI, not ambient DllImport.'
Check ($csText.Contains('LoadLibraryExW(basePath') -and $csText.Contains('Symbol<DeviceProps>(baseDll, "ggml_backend_dev_get_props")') -and
       $csText.Contains('Symbol<BackendLoad>(core, "ggml_backend_load")') -and
       $csText.Contains('Symbol<DeviceByName>(core, "ggml_backend_dev_by_name")')) 'Each GGML C ABI symbol must be resolved from its audited b10698 DLL owner.'
Check ($csText.Contains('index <= 8') -and $csText.Contains('index == 8') -and $csText.Contains('type != 1 && type != 2')) 'Native worker must reject excess devices and non-GPU types.'
Check ($helperText.Contains('WaitForExit($remaining)') -and -not $helperText.Contains('WaitForExit()')) 'Worker wait must be bounded.'
Check ($helperText.Contains('Join-FastLlmProcessArguments') -and $helperText.Contains('$child.OutputCompleted') -and $helperText.Contains('$child.OutputTruncated')) 'Wrapper must reuse tested quoting and require complete, untruncated output.'
$module = Import-Module (Join-Path $root 'src/FastLlm.psm1') -PassThru -ErrorAction Stop
$quoted = & $module { param($items) Join-FastLlmProcessArguments -Arguments $items } @('C:\Path With Space\','value"quoted')
Check ($quoted -ceq '"C:\Path With Space\\" "value\"quoted"') 'Existing tested argument helper must preserve trailing slash and embedded quote.'

Add-Type -Path (Join-Path $root 'src/ProcessHost.cs')
function Start-Mock([string]$Mode) {
    $child = New-Object Bitworks.FastLlm.ProcessHost
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = (Get-Process -Id $PID).Path
    $info.Arguments = & $module { param($items) Join-FastLlmProcessArguments -Arguments $items } @(
        '-NoLogo','-NoProfile','-File',(Join-Path $root 'tests/helpers/mock-ggml-identity-output.ps1'),'-Mode',$Mode)
    $child.Start($info)
    return $child
}
foreach ($mode in @('single','duplicate','overflow')) {
    $child = Start-Mock $mode
    try {
        Check ($child.Process.WaitForExit(4000)) "Mock $mode must exit within deadline."
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while (-not $child.OutputCompleted -and $watch.ElapsedMilliseconds -lt 4000) { Start-Sleep -Milliseconds 10 }
        Check $child.OutputCompleted "Mock $mode must deliver both output EOF signals."
        if ($mode -eq 'single') {
            $parsed = ConvertFrom-FastLlmGgmlIdentityOutput -OutputText ($child.Snapshot()) -WasTruncated $child.OutputTruncated
            Check ($parsed.schemaVersion -eq 1) 'Complete single-marker output must parse.'
        } elseif ($mode -eq 'duplicate') {
            $rejected = $false
            try { ConvertFrom-FastLlmGgmlIdentityOutput -OutputText ($child.Snapshot()) -WasTruncated $child.OutputTruncated | Out-Null }
            catch { $rejected = $true }
            Check $rejected 'Delayed duplicate marker must be rejected after EOF.'
        } else {
            Check $child.OutputTruncated 'Overflow mock must set native capture truncation flag.'
            $rejected = $false
            try { ConvertFrom-FastLlmGgmlIdentityOutput -OutputText ($child.Snapshot()) -WasTruncated $child.OutputTruncated | Out-Null }
            catch { $rejected = $true }
            Check $rejected 'Truncated output must be rejected.'
        }
    } finally { $child.Dispose() }
}
$child = Start-Mock 'timeout'
try { Check (-not $child.Process.WaitForExit(50)) 'Hanging worker must exceed short deadline.' }
finally { $child.Dispose() }
if ($env:OS -ne 'Windows_NT') {
    $rejected = $false
    try { [Bitworks.FastLlm.WindowsGgmlVulkanIdentity]::Read('/not/a/windows/engine') | Out-Null }
    catch [System.Management.Automation.MethodInvocationException] {
        $rejected = $_.Exception.InnerException -is [PlatformNotSupportedException]
    }
    Check $rejected 'Native GGML diagnostic must reject non-Windows hosts.'
}
Write-Host "GGML Vulkan identity diagnostic tests passed: $checks"
