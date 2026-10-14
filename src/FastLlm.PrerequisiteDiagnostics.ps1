#requires -Version 5.1
# Diagnostic-only VC++/Vulkan observations. No installer, download, or readiness decision.

function Read-FastLlmVcRuntimeRegistration {
    $key = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $runtime = $key.OpenSubKey('SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', $false)
        if ($null -eq $runtime) {
            return [pscustomobject]@{ status='missing'; installed=$null; version=$null; versionState='missing' }
        }
        try {
            $installedValue = $runtime.GetValue('Installed', $null)
            $installed = $null
            if ($installedValue -is [int] -and $installedValue -in @(0,1)) { $installed = ($installedValue -eq 1) }
            $versionValue = $runtime.GetValue('Version', $null)
            $version = $null
            $versionState = 'missing'
            if ($null -ne $versionValue) {
                $versionState = 'invalid'
                if ($versionValue -is [string] -and $versionValue -cmatch '^[vV]?[0-9]{1,5}(\.[0-9]{1,5}){3}$') {
                    $version = $versionValue
                    $versionState = 'observed'
                }
            }
            return [pscustomobject]@{ status='observed'; installed=$installed; version=$version; versionState=$versionState }
        } finally { $runtime.Dispose() }
    } finally { $key.Dispose() }
}

function Read-FastLlmPrerequisiteFile {
    param([Parameter(Mandatory=$true)][string]$Name, [Parameter(Mandatory=$true)][string]$System32)
    if ($Name -cnotin @('MSVCP140.dll','VCRUNTIME140.dll','VCRUNTIME140_1.dll','vulkan-1.dll')) {
        throw 'Unknown prerequisite file name.'
    }
    $path = Join-Path $System32 $Name
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{ name=$Name; status='missing'; fileVersion=$null; productVersion=$null; signatureStatus=$null; signer=$null; sha256=$null }
    }
    $file = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if ($file.PSIsContainer -or -not ($file -is [IO.FileInfo]) -or
        ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $file.Length -gt 67108864) {
        throw 'Expected regular prerequisite file is absent or unsafe.'
    }
    $fileVersion = $null
    $productVersion = $null
    if ($file.VersionInfo.FileVersion -match '^[0-9]{1,5}(\.[0-9]{1,5}){1,3}$') { $fileVersion = $file.VersionInfo.FileVersion }
    if ($file.VersionInfo.ProductVersion -match '^[0-9]{1,5}(\.[0-9]{1,5}){1,3}$') { $productVersion = $file.VersionInfo.ProductVersion }
    $signature = Get-AuthenticodeSignature -LiteralPath $path -ErrorAction Stop
    $signer = $null
    if ($null -ne $signature.SignerCertificate) {
        $subject = [string]$signature.SignerCertificate.Subject
        if ($subject.Length -le 256 -and $subject -notmatch '[\x00-\x1f\x7f]') { $signer = $subject }
    }
    return [pscustomobject]@{
        name=$Name; status='observed'; fileVersion=$fileVersion; productVersion=$productVersion
        signatureStatus=[string]$signature.Status; signer=$signer
        sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    }
}

function Get-FastLlmPrerequisiteSnapshot {
    param([string]$System32Path = [Environment]::SystemDirectory)
    $errors = New-Object 'System.Collections.Generic.List[object]'
    $registry = $null
    try { $registry = Read-FastLlmVcRuntimeRegistration }
    catch { $errors.Add([pscustomobject]@{ section='vcRuntimeRegistration'; code='read-failed' }) }
    $files = @()
    foreach ($name in @('MSVCP140.dll','VCRUNTIME140.dll','VCRUNTIME140_1.dll','vulkan-1.dll')) {
        try { $files += Read-FastLlmPrerequisiteFile -Name $name -System32 $System32Path }
        catch {
            $files += [pscustomobject]@{ name=$name; status='error'; fileVersion=$null; productVersion=$null; signatureStatus=$null; signer=$null; sha256=$null }
            $errors.Add([pscustomobject]@{ section=$name; code='read-failed' })
        }
    }
    return [pscustomobject]@{
        schemaVersion=1; applicable=$true; qualified=$false; compatibilityVerified=$false
        requiredVersion=$null; is64BitProcess=[Environment]::Is64BitProcess
        registrySource='HKLM-Registry64:SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'
        vcRuntimeRegistration=$registry; files=@($files); partial=($errors.Count -gt 0)
        errors=@($errors.ToArray())
        note='Observed registration, file metadata, signature, and hashes only. No minimum version, AMD driver identity, Vulkan compatibility, or native load is certified.'
    }
}

function Get-FastLlmPrerequisiteInventory {
    [CmdletBinding()]
    param()
    if ($env:OS -ne 'Windows_NT') {
        return [pscustomobject]@{ schemaVersion=1; applicable=$false; qualified=$false; compatibilityVerified=$false; requiredVersion=$null }
    }
    if (-not [Environment]::Is64BitProcess) { throw 'Prerequisite inventory requires a 64-bit process.' }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Prerequisite inventory requires a standard-user process.'
    }
    Initialize-FastLlmProcessHost
    $child = New-Object Bitworks.FastLlm.ProcessHost
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = (Get-Process -Id $PID).Path
        $worker = Join-Path (Split-Path $PSScriptRoot -Parent) 'tools/collect-prerequisite-inventory.ps1'
        $info.Arguments = Join-FastLlmProcessArguments @('-NoLogo','-NoProfile','-NonInteractive','-OutputFormat','Text','-File',$worker)
        $child.Start($info)
        $remaining = [Math]::Max(1, 20000 - [int]$watch.ElapsedMilliseconds)
        if (-not $child.Process.WaitForExit($remaining)) { throw 'Prerequisite inventory exceeded its 20-second deadline.' }
        if ($child.Process.ExitCode -ne 0) { throw 'Prerequisite inventory worker failed.' }
        while ($watch.ElapsedMilliseconds -lt 20000) {
            $json = $child.Snapshot()
            if ($json.Length -gt 32768) { throw 'Prerequisite inventory output exceeded its limit.' }
            $trimmed = $json.Trim()
            if ($trimmed.StartsWith('{') -and $trimmed.EndsWith('}')) {
                try { $snapshot = ConvertFrom-Json -InputObject $json -ErrorAction Stop }
                catch { throw 'Prerequisite inventory returned invalid JSON.' }
                Assert-FastLlmPrerequisiteSnapshot -Snapshot $snapshot
                return $snapshot
            }
            Start-Sleep -Milliseconds 20
        }
        throw 'Prerequisite inventory output exceeded its 20-second deadline.'
    } finally { $child.Dispose() }
}

function Assert-FastLlmPrerequisiteSnapshot {
    param([Parameter(Mandatory=$true)]$Snapshot)
    $names = @('MSVCP140.dll','VCRUNTIME140.dll','VCRUNTIME140_1.dll','vulkan-1.dll')
    if ($Snapshot.schemaVersion -ne 1 -or $Snapshot.applicable -ne $true -or
        $Snapshot.qualified -ne $false -or $Snapshot.compatibilityVerified -ne $false -or
        $null -ne $Snapshot.requiredVersion -or @($Snapshot.files).Count -ne $names.Count) {
        throw 'Prerequisite inventory returned an unexpected schema or qualification claim.'
    }
    for ($index = 0; $index -lt $names.Count; $index++) {
        if ($Snapshot.files[$index].name -cne $names[$index] -or
            $Snapshot.files[$index].status -notin @('observed','missing','error')) {
            throw 'Prerequisite inventory returned an unexpected file record.'
        }
    }
}
