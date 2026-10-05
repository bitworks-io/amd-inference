#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$LauncherScript = (Join-Path (Split-Path $PSScriptRoot -Parent) 'tools/start-windows-lab-setup.ps1'),
    [string]$CommandScript = (Join-Path (Split-Path $PSScriptRoot -Parent) 'tools/setup-windows-lab.cmd')
)
$ErrorActionPreference='Stop'
$tokens=$null; $parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($LauncherScript,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'Launcher does not parse.'}
$function=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Resolve-LabLauncherPublicKey'},$true)
. ([scriptblock]::Create($function.Extent.Text))
$script:checks=0
function Assert-True($Value,[string]$Message){if(-not $Value){throw $Message};$script:checks++}
function Assert-Throws([scriptblock]$Action,[string]$Message){$caught=$false;try{& $Action|Out-Null}catch{$caught=$true};Assert-True $caught $Message}
function Test-Path {param($LiteralPath,$PathType) Assert-True ($PathType -eq 'Leaf') 'Must select files, not directories.'; $script:files -contains $LiteralPath}
function Select-LabLauncherPublicKey {param($Title,$InitialDirectory) $script:pickerCalls++;$script:pickerTitle=$Title;$script:selection}
$script:pickerCalls=0
$testPath=Join-Path $PSScriptRoot 'test-client.pub';$adminPath=Join-Path $PSScriptRoot 'admin-client.pub'
$script:files=@($testPath,$adminPath)
Assert-True ((Resolve-LabLauncherPublicKey $PSScriptRoot test) -ceq $testPath) 'Default test key not used.'
Assert-True ((Resolve-LabLauncherPublicKey $PSScriptRoot admin) -ceq $adminPath) 'Default admin key not used.'
Assert-True ($script:pickerCalls -eq 0) 'Unnecessary picker for adjacent files.'
$custom=Join-Path $PSScriptRoot 'key with spaces.pub';$script:files=@($custom);$script:selection=$custom
Assert-True ((Resolve-LabLauncherPublicKey $PSScriptRoot admin) -ceq $custom) 'Selected file path changed.'
Assert-True ($script:pickerTitle -like '*ADMINISTRATOR*') 'Admin picker must identify privilege scope.'
$script:selection=$null
Assert-Throws {Resolve-LabLauncherPublicKey $PSScriptRoot test} 'Cancel must stop setup.'
$script:selection=$testPath
Assert-Throws {Resolve-LabLauncherPublicKey $PSScriptRoot test} 'Missing selected file accepted.'
$source=[IO.File]::ReadAllText($LauncherScript);$cmd=[IO.File]::ReadAllText($CommandScript)
Assert-True ($source.IndexOf('$adminKey = Resolve-LabLauncherPublicKey') -lt $source.IndexOf('& $setup -TestPublicKeyPath')) 'Setup starts before both keys resolve.'
Assert-True ($source.Contains('IsInRole') -and $source.Contains('$env:SSH_CONNECTION')) 'Missing admin/RDP preflight.'
Assert-True (-not $source.Contains('AAAAC3N')) 'Deployment key embedded.'
Assert-True ($cmd.Contains('Sysnative') -and $cmd.Contains(' -STA ')) 'Missing 64-bit/STA launcher handling.'
Assert-True ($cmd.Contains('-File "%~dp0start-windows-lab-setup.ps1"')) 'Helper path must be rooted at launcher and quoted.'
Assert-True ($cmd.Contains('set "FASTLLM_SETUP_RESULT=%ERRORLEVEL%"') -and $cmd.Contains('exit /b %FASTLLM_SETUP_RESULT%')) 'Exit status not preserved.'
Assert-True (-not $cmd.Contains('%*')) 'Unexpected shell argument forwarding.'
Write-Host "PASS: $script:checks lab-launcher checks on PowerShell $($PSVersionTable.PSVersion). No dialog or setup executed."
