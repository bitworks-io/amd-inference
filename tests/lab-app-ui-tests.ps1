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
foreach ($name in @('Test-FastLlmLabInstallerInput','Format-FastLlmLabInstallerResult',
    'Format-FastLlmLabRemovalPreview','Test-FastLlmLabRestoreInput','Format-FastLlmLabRemovalResult',
    'Assert-FastLlmLabCompanionLocation')) {
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

    $preview = [pscustomobject]@{ready=$true;reason=$null;digest=$digest;items=@('owned-version','owned-shortcut')}
    $previewText = Format-FastLlmLabRemovalPreview $preview
    Check ($previewText.Contains('owned-version') -and $previewText.Contains('owned-shortcut') -and
        $previewText.Contains('recoverable quarantine') -and $previewText.Contains('benchmark reports stay in place')) 'removal preview lists the exact items and retained-data boundary'
    Check ($previewText.Contains($digest) -and $previewText.Contains('quarantine: 2')) 'preview exposes its exact digest and item count, including a ready result with null reason'
    $refusal = [pscustomobject]@{ready=$false;reason='The app is active.';digest=$null;items=@()}
    Check ((Format-FastLlmLabRemovalPreview $refusal).Contains('No files were moved.')) 'refused preview cannot imply removal'
    $refusal.reason = $null
    Check-Throws { Format-FastLlmLabRemovalPreview $refusal } 'a refused preview requires an explanation'
    $preview.ready = 'true'
    Check-Throws { Format-FastLlmLabRemovalPreview $preview } 'preview readiness must be a boolean'
    $preview.ready = $true
    $preview.digest = 'bad'
    Check-Throws { Format-FastLlmLabRemovalPreview $preview } 'ready preview requires the exact digest'
    $preview.digest = $digest
    $preview.items = @()
    Check-Throws { Format-FastLlmLabRemovalPreview $preview } 'empty removal set is not accepted'
    $preview.items = @("safe`nmisleading")
    Check-Throws { Format-FastLlmLabRemovalPreview $preview } 'control characters cannot inject a preview line'
    $preview.items = @('item' + [char]0x202e + 'changed')
    Check-Throws { Format-FastLlmLabRemovalPreview $preview } 'bidirectional display controls cannot alter a preview item'
    $preview.items = @('x' * 1025)
    Check-Throws { Format-FastLlmLabRemovalPreview $preview } 'oversized preview item is refused'
    Check ((Test-FastLlmLabRestoreInput -QuarantinePath $folder) -eq $folder) 'restore passes the explicit local quarantine path without probing or guessing it'
    Check-Throws { Test-FastLlmLabRestoreInput -QuarantinePath 'relative-quarantine' } 'relative restore path is rejected'
    $script:mockNetworkDrive = $true
    Check-Throws { Test-FastLlmLabRestoreInput -QuarantinePath $folder } 'core fixed-drive guard rejects restore on a mapped network drive'
    $script:mockNetworkDrive = $false
    $removed = [pscustomobject]@{quarantinePath=$folder;modelCacheUntouched=$true;publicReleaseApproved=$false}
    Check ((Format-FastLlmLabRemovalResult $removed Uninstall).Contains($folder)) 'uninstall result exposes the exact recoverable location'
    $removed.publicReleaseApproved = $true
    Check-Throws { Format-FastLlmLabRemovalResult $removed Uninstall } 'uninstall cannot claim public release approval'
    $removed.publicReleaseApproved = $false
    $removed.modelCacheUntouched = 'true'
    Check-Throws { Format-FastLlmLabRemovalResult $removed Uninstall } 'cache-preservation evidence cannot be a truthy string'
    $restored = [pscustomobject]@{appRoot=$folder;modelCacheUntouched=$true;publicReleaseApproved=$false}
    Check ((Format-FastLlmLabRemovalResult $restored Restore).Contains('The app was not started.')) 'restore result does not imply automatic execution'
    Assert-FastLlmLabCompanionLocation -SourceRoot $folder
    $managedSource = Join-Path (Join-Path $folder 'versions') ('a' * 64 + '-' + 'b' * 32)
    Check-Throws { Assert-FastLlmLabCompanionLocation -SourceRoot $managedSource } 'companion refuses to operate from a managed version it could move'
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
Check ($source.Contains('Get-FastLlmLabAppRemovalPreviewForUser') -and
    $source.Contains('Invoke-FastLlmLabAppRemoval -ExpectedPreviewDigest $preview.digest') -and
    $source.Contains('Invoke-FastLlmLabAppRestore -QuarantinePath $quarantine')) 'lifecycle UI uses fixed-user APIs and binds uninstall to the displayed preview digest'
Check ($source.Contains("if (`$Action -eq 'Preview')") -and $source.Contains('Preview only. No files were moved.')) 'preview path returns before mutation confirmation'
Check ($source.Contains('ShowNewFolderButton = $false') -and $source.Contains('Existing destination files will not be overwritten')) 'restore chooser does not create folders or promise to overwrite conflicts'
Check ($source.Contains('SetInstallerBusy $true') -and $source.Contains('SetInstallerBusy $false')) 'lifecycle actions serialize all companion controls'
Check ($source.Contains('Get-FastLlmLabAppPendingRecoveryForUser') -and $source.Contains('$quarantineBox.Text = [string]$pending.quarantinePath')) 'verified interrupted-removal path is discoverable without guessing'
Check ($source.Contains('Preview SHA-256:') -and $source.Contains('$(@($preview.items).Count) verified app items')) 'uninstall confirmation visibly binds item count and preview digest'
Check ($source.Contains('Automatic busy detection covers the managed control window and main CLI only.') -and $source.Contains('those tools are not detected automatically')) 'preview and confirmation disclose the unguarded developer-tool limitation'
foreach ($entry in @('fast-llm.ps1','fast-llm-ui.ps1')) {
    $entryPath = Join-Path $repo $entry
    $entryErrors = $null; $entryTokens = $null
    $entryAst = [Management.Automation.Language.Parser]::ParseFile($entryPath,[ref]$entryTokens,[ref]$entryErrors)
    Check (@($entryErrors).Count -eq 0) "$entry lifetime wrapper parses"
    $leaseNode = $entryAst.Find({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Enter-FastLlmLabAppLifetime'},$true)
    $importNode = $entryAst.Find({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Import-Module'},$true)
    Check ($leaseNode -and $importNode -and $leaseNode.Extent.StartOffset -lt $importNode.Extent.StartOffset) "$entry acquires the managed lease before application import"
    $leaseTry = $entryAst.Find({param($n) $n -is [Management.Automation.Language.TryStatementAst] -and
        $n.Finally -and $n.Finally.Extent.Text -match '\$labAppLifetime\.Dispose\(\)'},$true)
    Check ($leaseTry -and $leaseTry.Body.Extent.StartOffset -lt $leaseNode.Extent.StartOffset -and
        $leaseTry.Body.Extent.EndOffset -gt $importNode.Extent.EndOffset) "$entry releases its lifetime lease from an enclosing finally"
}
Check ($source -notmatch '(?i)\b(?:Unblock-File|Start-Process|Invoke-WebRequest|curl\.exe|AcceptModelLicense)\b|\-ExecutionPolicy\b') 'UI has no unblock, policy bypass, download, or model-consent path'
Check ($cmd.Contains('WindowsPowerShell\v1.0\powershell.exe') -and $cmd.Contains('-STA -File') -and $cmd.Contains('tools\install-lab-app.ps1')) 'double-click launcher uses adjacent setup script and Windows PowerShell STA'
Check ($cmd -notmatch '(?i)(?:-ExecutionPolicy|\-Verb\s+RunAs|Invoke-WebRequest|curl\.exe)') 'launcher has no policy bypass, elevation, or download switch'
Write-Host "$script:checks lab app UI checks passed. No installer or native Windows UI was executed."
