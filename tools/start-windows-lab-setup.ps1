#requires -Version 5.1
# Interactive companion for setup-windows-lab.cmd. No deployment keys embedded.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

function Select-LabLauncherPublicKey([string]$Title, [string]$InitialDirectory) {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = [System.Windows.Forms.OpenFileDialog]::new()
    try {
        $dialog.Title = $Title
        $dialog.InitialDirectory = $InitialDirectory
        $dialog.Filter = 'SSH public keys (*.pub)|*.pub'
        $dialog.CheckFileExists = $true
        $dialog.Multiselect = $false
        $dialog.RestoreDirectory = $true
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.FileName }
        return $null
    } finally { $dialog.Dispose() }
}

function Resolve-LabLauncherPublicKey([string]$Directory, [ValidateSet('test','admin')][string]$Role) {
    $defaultPath = Join-Path $Directory ($Role + '-client.pub')
    if (Test-Path -LiteralPath $defaultPath -PathType Leaf) { return $defaultPath }
    $description = if ($Role -eq 'admin') { 'ADMINISTRATOR access (fastllm-admin)' } else { 'standard-user access (fastllm-test)' }
    $selected = Select-LabLauncherPublicKey -Title "Select PUBLIC key for $description" -InitialDirectory $Directory
    if ([string]::IsNullOrWhiteSpace($selected)) { throw 'Public-key selection canceled. No setup actions were performed.' }
    if (-not (Test-Path -LiteralPath $selected -PathType Leaf)) { throw 'The selected public-key file does not exist.' }
    [IO.Path]::GetFullPath($selected)
}

try {
    if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) {
        throw 'Use this launcher on 64-bit Windows.'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Right-click setup-windows-lab.cmd and choose Run as administrator.'
    }
    if ($env:SSH_CONNECTION) { throw 'Run locally or through RDP; setup restarts SSH.' }
    $setup = Join-Path $PSScriptRoot 'setup-windows-lab.ps1'
    if (-not (Test-Path -LiteralPath $setup -PathType Leaf)) { throw 'Keep the launcher and both PowerShell scripts together in the tools folder.' }
    # Resolve both inputs before invoking any machine-changing setup.
    $testKey = Resolve-LabLauncherPublicKey -Directory $PSScriptRoot -Role test
    $adminKey = Resolve-LabLauncherPublicKey -Directory $PSScriptRoot -Role admin
    Write-Host "Standard-user public key: $testKey"
    Write-Host "Administrator public key: $adminKey"
    & $setup -TestPublicKeyPath $testKey -AdminPublicKeyPath $adminKey
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
