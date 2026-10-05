#requires -Version 5.1
# Optional diagnostic. Intentionally not imported/exported by FastLlm.psm1.

function Assert-FastLlmGgmlVulkanIdentitySnapshot {
    param([Parameter(Mandatory=$true)]$Snapshot)
    if ($Snapshot.schemaVersion -ne 1 -or $Snapshot.applicable -ne $true -or
        $Snapshot.qualified -ne $false -or
        $Snapshot.identityScope -cne 'independent-process-advisory' -or
        $Snapshot.sourceEngineArchiveSha256 -cne '31e2fe70d4864a4ae6a4e7d8e102ee9203ba18963077e7727c54f9bd6ae3bea5' -or
        @($Snapshot.devices).Count -gt 8) {
        throw 'GGML identity worker returned an unexpected schema or qualification claim.'
    }
    $index = 0
    foreach ($device in @($Snapshot.devices)) {
        if ($device.Name -cne "Vulkan$index" -or $device.Backend -cne 'Vulkan' -or
            [string]::IsNullOrWhiteSpace([string]$device.Description) -or
            $device.Description.Length -gt 256 -or
            ($device.MemoryTotalBytes -isnot [int] -and $device.MemoryTotalBytes -isnot [long]) -or
            ($device.MemoryFreeBytes -isnot [int] -and $device.MemoryFreeBytes -isnot [long]) -or
            [int64]$device.MemoryTotalBytes -le 0 -or [int64]$device.MemoryFreeBytes -lt 0 -or
            [int64]$device.MemoryFreeBytes -gt [int64]$device.MemoryTotalBytes -or
            ($null -ne $device.DeviceId -and $device.DeviceId -cnotmatch '^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$')) {
            throw 'GGML identity worker returned an invalid device record.'
        }
        $index++
    }
}

function ConvertFrom-FastLlmGgmlIdentityOutput {
    param([Parameter(Mandatory=$true)][string]$OutputText, [bool]$WasTruncated)
    if ($WasTruncated) { throw 'GGML identity worker output was truncated.' }
    if ($OutputText.Length -gt 32768) { throw 'GGML identity worker output exceeded its limit.' }
    $records = [regex]::Matches($OutputText, '(?m)^FASTLLM_GGML_IDENTITY_JSON:(\{[^\r\n]*\})\r?$')
    if ($records.Count -gt 1) { throw 'GGML identity worker returned multiple records.' }
    if ($records.Count -eq 0) { return $null }
    $snapshot = ConvertFrom-Json -InputObject $records[0].Groups[1].Value -ErrorAction Stop
    Assert-FastLlmGgmlVulkanIdentitySnapshot -Snapshot $snapshot
    return $snapshot
}

function Get-FastLlmGgmlVulkanIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$InstallRoot,
        [ValidateRange(1,30)][int]$TimeoutSeconds = 20
    )
    if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) {
        throw 'GGML Vulkan identity diagnostic requires 64-bit Windows.'
    }
    $principal = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'GGML Vulkan identity diagnostic requires a standard-user process.'
    }
    if (-not ('Bitworks.FastLlm.ProcessHost' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'ProcessHost.cs') -ErrorAction Stop
    }

    $projectRoot = Split-Path $PSScriptRoot -Parent
    $fastLlmModule = Import-Module (Join-Path $PSScriptRoot 'FastLlm.psm1') -PassThru -DisableNameChecking -ErrorAction Stop
    $worker = Join-Path $projectRoot 'tools/collect-ggml-vulkan-identity.ps1'
    $sandbox = Join-Path ([IO.Path]::GetTempPath()) ('FastLlm-GgmlIdentity-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $sandbox -ErrorAction Stop | Out-Null
    $child = New-Object Bitworks.FastLlm.ProcessHost
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = (Get-Process -Id $PID).Path
        $arguments = @('-NoLogo','-NoProfile','-NonInteractive','-OutputFormat','Text',
            '-ExecutionPolicy','RemoteSigned','-File',$worker,'-InstallRoot',$InstallRoot)
        $info.Arguments = & $fastLlmModule { param($items) Join-FastLlmProcessArguments -Arguments $items } $arguments
        $info.WorkingDirectory = $projectRoot
        foreach ($name in @($info.EnvironmentVariables.Keys)) {
            if ($name -like 'LLAMA_*' -or $name -like 'GGML_*' -or $name -like 'VK_*' -or
                $name -like 'VULKAN_*' -or $name -like 'HIP_*' -or $name -like 'ROCM_*' -or
                $name -like 'HSA_*' -or $name -like 'ROCBLAS_*' -or $name -like 'SMITHY_*' -or
                $name -like 'AIP_*' -or $name -in @('MTMD_BACKEND_DEVICE','HF_TOKEN')) {
                $info.EnvironmentVariables.Remove([string]$name)
            }
        }
        $info.EnvironmentVariables['APPDATA'] = $sandbox
        $info.EnvironmentVariables['PROGRAMDATA'] = $sandbox
        $info.EnvironmentVariables['PATH'] = ([Environment]::SystemDirectory + ';' + $env:SystemRoot)
        $child.Start($info)
        $remaining = [Math]::Max(1, $TimeoutSeconds * 1000 - [int]$watch.ElapsedMilliseconds)
        if (-not $child.Process.WaitForExit($remaining)) { throw 'GGML identity worker exceeded its deadline.' }
        if ($child.Process.ExitCode -ne 0) { throw 'GGML identity worker failed.' }
        while (-not $child.OutputCompleted -and $watch.ElapsedMilliseconds -lt $TimeoutSeconds * 1000) {
            Start-Sleep -Milliseconds 20
        }
        if (-not $child.OutputCompleted) { throw 'GGML identity worker output did not reach EOF within its deadline.' }
        $record = ConvertFrom-FastLlmGgmlIdentityOutput -OutputText ($child.Snapshot()) -WasTruncated $child.OutputTruncated
        if ($null -eq $record) { throw 'GGML identity worker returned no result record.' }
        return $record
    } finally {
        $child.Dispose()
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}
