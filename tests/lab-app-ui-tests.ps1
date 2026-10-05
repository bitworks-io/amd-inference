#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$repo = Split-Path $PSScriptRoot -Parent
$tool = Join-Path $repo 'tools/install-lab-app.ps1'
$launcher = Join-Path $repo 'Install-FastLLM-Lab.cmd'
$source = Get-Content -LiteralPath $tool -Raw
$cmd = Get-Content -LiteralPath $launcher -Raw
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($tool,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Lab app window script does not parse.' }
foreach ($name in @('Test-FastLlmLabInstallerInput','Format-FastLlmLabInstallerResult')) {
    $node = $ast.Find({param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name},$true)
    if (-not $node) { throw "Missing testable UI helper: $name" }
    . ([scriptblock]::Create($node.Extent.Text))
}

$script:checks = 0
function Check([bool]$condition,[string]$message) {
    if (-not $condition) { throw "FAIL: $message" }
    $script:checks++
    Write-Host "PASS: $message"
}
function Check-Throws([scriptblock]$action,[string]$message) {
    $caught = $false
    try { & $action | Out-Null } catch { $caught = $true }
    Check $caught $message
}
function Assert-FastLlmLabLocalWindowsPath {
    param([string]$Path)
    $script:localGuardCalls++
    if ($script:mockNetworkDrive) { throw 'Simulated mapped network volume.' }
    if ($Path.StartsWith('\\') -or $Path.StartsWith('//')) { throw 'Simulated UNC or device path.' }
}
$script:localGuardCalls = 0
$script:mockNetworkDrive = $false

$folder = Join-Path ([IO.Path]::GetTempPath()) ('fastllm-lab-ui-test-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $folder
$archive = Join-Path $folder 'reviewed-source.zip'
try {
    [IO.File]::WriteAllBytes($archive,[byte[]]@(1,2,3))
    $digest = 'a' * 64
    $choice = Test-FastLlmLabInstallerInput -Action Install -ArchivePath $archive -ExpectedSha256 $digest
    Check ($choice.action -eq 'Install' -and $choice.archivePath -eq $archive -and $choice.expectedSha256 -eq $digest) 'reviewed local ZIP and independently entered hash are passed unchanged'
    Check ($script:localGuardCalls -eq 1) 'UI delegates local-drive authority to the core helper'
    $repair = Test-FastLlmLabInstallerInput -Action Repair -ArchivePath $archive -ExpectedSha256 ($digest.ToUpperInvariant())
    Check ($repair.action -eq 'Repair' -and $repair.expectedSha256 -eq $digest) 'repair has the same exact local ZIP/hash requirement'
    Check-Throws { Test-FastLlmLabInstallerInput -Action Install -ArchivePath $archive -ExpectedSha256 'bad' } 'malformed SHA-256 is rejected before invoking core'
    Check-Throws { Test-FastLlmLabInstallerInput -Action Install -ArchivePath 'relative.zip' -ExpectedSha256 $digest } 'relative ZIP path is rejected'
    Check-Throws { Test-FastLlmLabInstallerInput -Action Install -ArchivePath (Join-Path $folder 'missing.zip') -ExpectedSha256 $digest } 'missing ZIP is rejected'
    Check-Throws { Test-FastLlmLabInstallerInput -Action Install -ArchivePath $archive -ExpectedSha256 '' } 'no adjacent sidecar or implicit hash is accepted'
    $script:mockNetworkDrive = $true
    Check-Throws { Test-FastLlmLabInstallerInput -Action Install -ArchivePath $archive -ExpectedSha256 $digest } 'mapped-network-drive rejection from core helper blocks UI acceptance'
    $script:mockNetworkDrive = $false
    $rollback = Test-FastLlmLabInstallerInput -Action Rollback -ArchivePath $null -ExpectedSha256 $null
    Check ($rollback.action -eq 'Rollback' -and $null -eq $rollback.archivePath -and $null -eq $rollback.expectedSha256) 'rollback invokes core without ZIP or hash'
    Check-Throws { Test-FastLlmLabInstallerInput -Action Rollback -ArchivePath $archive -ExpectedSha256 $digest } 'rollback input cannot accidentally pass an archive to core'
    $result = [pscustomobject]@{ appRoot='C:\Users\test\AppData\Local\Bitworks\FastLLM-LabApp'; currentVersion='test-version'; previousVersion='old-version'; shortcutPath='C:\Users\test\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\FastLLM Lab.lnk'; publisherAuthenticated=$false; publicReleaseApproved=$false }
    $formatted = Format-FastLlmLabInstallerResult $result
    Check ($formatted.Contains('test-version') -and $formatted.Contains('old-version') -and $formatted.Contains('Publisher authenticated: No') -and $formatted.Contains('Public release approved: No')) 'result displays version/shortcut and nonqualification'
    $result.publisherAuthenticated = $true
    Check-Throws { Format-FastLlmLabInstallerResult $result } 'UI refuses a contradictory publisher-authentication result'
} finally {
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
    if (Test-Path -LiteralPath $folder) { Remove-Item -LiteralPath $folder -Force }
}

Check ($source.Contains('WindowsPrincipal') -and $source.Contains('Is64BitProcess') -and $source.Contains('BuiltInRole]::Administrator')) 'UI requires 64-bit standard-user Windows PowerShell'
Check ($source.Contains('OpenFileDialog') -and $source.Contains('CheckFileExists') -and $source.Contains('Expected SHA-256')) 'UI asks for a local ZIP and independently supplied digest'
Check ($source.IndexOf('Assert-FastLlmLabLocalWindowsPath -Path $ArchivePath') -gt 0 -and
    $source.IndexOf('Assert-FastLlmLabLocalWindowsPath -Path $ArchivePath') -lt $source.IndexOf('Test-Path -LiteralPath $ArchivePath -PathType Leaf')) 'core local-drive guard runs before ZIP filesystem probe'
Check ($source.Contains('$ArchivePath -cnotmatch') -and $source.Contains("^[A-Za-z]:")) 'Windows UI requires an explicit drive-rooted ZIP path, not current-drive resolution'
Check ($source.Contains('MessageBoxDefaultButton]::Button2') -and $source.Contains('MessageBoxButtons]::YesNo') -and $source.Contains('reviewed.Checked')) 'mutating actions require explicit review and default-no confirmation'
Check ($source.Contains('UseWaitCursor = $true') -and $source.Contains('UseWaitCursor = $false') -and $source.Contains('may briefly stop responding')) 'synchronous bounded verification has honest wait-cursor UX'
Check ($source.Contains('Invoke-FastLlmLabApp -Action Rollback') -and $source.Contains('Invoke-FastLlmLabApp -Action $Action -ArchivePath')) 'UI invokes only the fixed core install/repair/rollback API'
Check ($source -notmatch '(?i)\b(?:Unblock-File|Start-Process|Invoke-WebRequest|curl\.exe|AcceptModelLicense)\b|\-ExecutionPolicy\b') 'UI has no unblock, policy bypass, download, or model-consent path'
Check ($cmd.Contains('WindowsPowerShell\v1.0\powershell.exe') -and $cmd.Contains('-STA -File') -and $cmd.Contains('tools\install-lab-app.ps1')) 'double-click launcher uses adjacent setup script and Windows PowerShell STA'
Check ($cmd -notmatch '(?i)(?:-ExecutionPolicy|\-Verb\s+RunAs|Invoke-WebRequest|curl\.exe)') 'launcher has no policy bypass, elevation, or download switch'
Write-Host "$script:checks lab app UI checks passed. No installer or native Windows UI was executed."
