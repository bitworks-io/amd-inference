#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
if ($env:CI -ne 'true') { Write-Host 'installer-tests: skipped (CI only: it installs into the real per-user FastLLM paths)'; exit 0 }
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path $env:RUNNER_TEMP ('installer-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$app = Join-Path $env:LOCALAPPDATA 'Programs\Bitworks FastLLM'
$data = Join-Path $env:LOCALAPPDATA 'Bitworks\FastLLM'
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "ASSERT: $Message" } }
function Build-Tree([string]$Version, [string[]]$ExtraFiles = @()) {
    $out = Join-Path $work "pkg-$Version"
    $null = & python (Join-Path $repo 'tools/build-release.py') --version $Version --channel canary --min-agent-version 0.10.0 --built-at '2026-01-01T00:00:00Z' --out $out
    if ($LASTEXITCODE) { throw "build-release failed for $Version" }
    $tree = Join-Path $work "tree-$Version"
    Expand-Archive -LiteralPath (Join-Path $out 'package-unsigned.zip') -DestinationPath $tree
    foreach ($f in $ExtraFiles) { Set-Content -LiteralPath (Join-Path $tree $f) -Value 'extra' -Encoding ascii }
    return $tree
}
function Build-Installer([string]$Version, [string]$Tree) {
    $outDir = Join-Path $work "setup-$Version"
    $null = & (Join-Path $repo 'installer/build-installer.ps1') -Version $Version -SourceDir $Tree -OutputDir $outDir
    return (Join-Path $outDir "FastLLM-Setup-$Version.exe")
}
function Invoke-Silent([string]$Exe, [string[]]$Arguments) {
    $p = Start-Process -FilePath $Exe -ArgumentList $Arguments -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "$Exe exited $($p.ExitCode)" }
}
function Get-TreeList([string]$Root, [string[]]$SkipPrefixes = @()) {
    @(Get-ChildItem -LiteralPath $Root -Recurse -File | ForEach-Object { $_.FullName.Substring($Root.Length + 1) } |
        Where-Object { $rel = $_; -not @($SkipPrefixes | Where-Object { $rel.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count } |
        Sort-Object)
}
function Wait-Gone([string]$Path) {
    $deadline = (Get-Date).AddSeconds(60)
    while ((Test-Path -LiteralPath $Path) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    return -not (Test-Path -LiteralPath $Path)
}

# 1. Static: per-user, no elevation override, uninstaller outside the catalog folder; the launcher policy
$iss = Get-Content -LiteralPath (Join-Path $repo 'installer/FastLLM.iss') -Raw
Assert-True ($iss -match '(?m)^PrivilegesRequired=lowest\s*$') 'PrivilegesRequired=lowest missing'
Assert-True ($iss -notmatch '(?m)^PrivilegesRequiredOverridesAllowed') 'an elevation override directive is present'
Assert-True ($iss -match '(?m)^UninstallFilesDir=\{app\}\\_uninstall\s*$') 'UninstallFilesDir must be {app}\_uninstall'
Assert-True ($iss -match '(?m)^DefaultDirName=\{localappdata\}\\Programs\\Bitworks FastLLM\s*$') 'DefaultDirName changed'
$cmd = Get-Content -LiteralPath (Join-Path $repo 'FastLLM.cmd') -Raw
Assert-True ($cmd -match '(?im)^\s*if /i "%FASTLLM_POLICY%"=="Restricted" set "FASTLLM_EP=-ExecutionPolicy RemoteSigned"\s*$') 'FastLLM.cmd must lift a Restricted policy to RemoteSigned'
Assert-True ($cmd -match '(?im)^\s*if /i "%FASTLLM_POLICY%"=="Undefined" set "FASTLLM_EP=-ExecutionPolicy RemoteSigned"\s*$') 'FastLLM.cmd must lift an Undefined policy to RemoteSigned'
Assert-True ($cmd -notmatch '(?i)bypass') 'FastLLM.cmd must never use Bypass'
$ui = Get-Content -LiteralPath (Join-Path $repo 'fast-llm-ui.ps1') -Raw
Assert-True ($ui -notmatch '(?i)-ExecutionPolicy') 'child processes inherit the entry policy; they never override it'
# No product script, module or tool may set a script policy: children inherit the entry policy, so AllSigned and Group Policy
# are never weakened. FastLLM.cmd is the only product launcher that sets one. The allowlist holds lab-only admin scripts that
# are never packaged (tools/build-release.py keeps them out), each with its justification.
$policyAllowlist = @{ 'tools/setup-windows-lab.cmd' = 'private bench administration launcher (admin SSH setup); excluded from the release package' }
$policyExt = @('.ps1', '.psm1', '.psd1', '.cmd', '.bat', '.py', '.sh')
$policyFiles = @(Get-Item -LiteralPath (Join-Path $repo 'fast-llm.ps1'), (Join-Path $repo 'fast-llm-ui.ps1'))
foreach ($dir in 'src', 'tools') { $policyFiles += @(Get-ChildItem -LiteralPath (Join-Path $repo $dir) -Recurse -File | Where-Object { $policyExt -contains $_.Extension.ToLowerInvariant() }) }
foreach ($f in $policyFiles) {
    $rel = $f.FullName.Substring($repo.Length + 1).Replace('\', '/')
    $hit = [bool](Select-String -LiteralPath $f.FullName -Pattern 'ExecutionPolicy' -Quiet)
    if ($policyAllowlist.ContainsKey($rel)) { continue }
    Assert-True (-not $hit) "$rel sets or names an execution policy; only FastLLM.cmd may, and lab-only scripts must be allowlisted with a justification"
}
foreach ($rel in $policyAllowlist.Keys) {
    Assert-True (Test-Path -LiteralPath (Join-Path $repo $rel)) "allowlisted $rel no longer exists; remove it from the allowlist"
    Assert-True ([bool](Select-String -LiteralPath (Join-Path $repo $rel) -Pattern 'ExecutionPolicy' -Quiet)) "allowlisted $rel no longer sets a policy; remove it from the allowlist"
}
foreach ($f in Get-ChildItem -LiteralPath $repo -File | Where-Object { $_.Name -ne 'FastLLM.cmd' -and @('.cmd', '.bat', '.ps1') -contains $_.Extension.ToLowerInvariant() }) {
    Assert-True (-not (Select-String -LiteralPath $f.FullName -Pattern 'ExecutionPolicy' -Quiet)) "$($f.Name) sets a policy; FastLLM.cmd must stay the only product launcher that does"
}
Assert-True ($iss -match '(?m)^function PrepareToInstall\(' -and $iss -match "FileExists\(AddBackslash\(Dir\) \+ 'FastLLM\.cat'\)" -and $iss -match "_uninstall\\unins000\.dat") 'the installer must refuse a non-empty folder that is not a FastLLM install before [InstallDelete] runs'
Assert-True ($iss -notmatch '(?i)ExecutionPolicy') 'the installer script must not set an execution policy'

# 2. Fresh install
$v1 = '2026.01.01.1'; $tree1 = Build-Tree $v1 @('only-in-v1.txt')
$setup1 = Build-Installer $v1 $tree1
# Real Inno output: the version-resource padding must not defeat verify-release's exact ProductVersion check
Import-Module (Join-Path $repo 'release/ReleaseVerify.psm1') -Force
$productVersion = Get-FastLlmInstallerProductVersion -Path $setup1
Assert-True ($productVersion -ceq $v1) "installer ProductVersion is '$productVersion', expected '$v1'"
Invoke-Silent $setup1 @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/CURRENTUSER', '/NORESTART', "/LOG=$work\install-v1.log")
Assert-True (Test-Path -LiteralPath (Join-Path $app 'fast-llm.ps1')) 'app not installed'
Assert-True (Test-Path -LiteralPath (Join-Path $app '_uninstall\unins000.exe')) 'uninstaller not in _uninstall'
Assert-True (Test-Path -LiteralPath (Join-Path ([Environment]::GetFolderPath('Programs')) 'FastLLM.lnk')) 'Start Menu shortcut missing'
$diff = Compare-Object (Get-TreeList $tree1) (Get-TreeList $app @('_uninstall\'))
Assert-True (-not $diff) "installed tree differs from the package: $($diff | Out-String)"

# 3. Upgrade keeps user data and removes files the new version no longer ships
New-Item -ItemType Directory -Force -Path (Join-Path $data 'models') | Out-Null
$marker = Join-Path $data 'models\installer-test-marker.txt'
Set-Content -LiteralPath $marker -Value 'keep me' -Encoding ascii
$v2 = '2026.01.01.2'; $tree2 = Build-Tree $v2
Invoke-Silent (Build-Installer $v2 $tree2) @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/CURRENTUSER', '/NORESTART', "/LOG=$work\install-v2.log")
Assert-True (Test-Path -LiteralPath $marker) 'upgrade touched user data'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $app 'only-in-v1.txt'))) 'stale v1 file survived the upgrade'
$installed = (Get-Content -LiteralPath (Join-Path $app 'FASTLLM-VERSION.json') -Raw | ConvertFrom-Json).version
Assert-True ($installed -eq $v2) "installed version is $installed"
$diff = Compare-Object (Get-TreeList $tree2) (Get-TreeList $app @('_uninstall\'))
Assert-True (-not $diff) "upgraded tree differs from the package: $($diff | Out-String)"

# 4. Silent uninstall keeps user data
Invoke-Silent (Join-Path $app '_uninstall\unins000.exe') @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')
Assert-True (Wait-Gone (Join-Path $app 'fast-llm.ps1')) 'app files remain 60 s after uninstall'
Assert-True (Test-Path -LiteralPath $marker) 'uninstall removed user data'
Remove-Item -LiteralPath $marker -Force
# 5. /DIR= at a non-empty folder that is not a FastLLM install: Setup refuses and nothing in the folder is deleted
$foreign = Join-Path $work 'foreign-folder'
foreach ($sub in 'src', 'tools', 'config', 'licenses', 'other') { New-Item -ItemType Directory -Force -Path (Join-Path $foreign $sub) | Out-Null }
$foreignFiles = @('notes.txt', 'FastLLM.cmd', 'LICENSE', 'src\mine.ps1', 'tools\mine.ps1', 'config\mine.json', 'licenses\mine.txt', 'other\keep.bin')
foreach ($f in $foreignFiles) { Set-Content -LiteralPath (Join-Path $foreign $f) -Value "user file $f" -Encoding ascii }
$p = Start-Process -FilePath $setup1 -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/CURRENTUSER', '/NORESTART', "/DIR=`"$foreign`"", "/LOG=$work\install-foreign.log") -Wait -PassThru
Assert-True ($p.ExitCode -ne 0) 'Setup must refuse a non-empty folder that is not a FastLLM install'
foreach ($f in $foreignFiles) {
    $path = Join-Path $foreign $f
    Assert-True (Test-Path -LiteralPath $path) "Setup deleted the unrelated file $f"
    Assert-True ((Get-Content -LiteralPath $path -Raw).Trim() -eq "user file $f") "Setup changed the unrelated file $f"
}
Assert-True (-not (Test-Path -LiteralPath (Join-Path $foreign 'fast-llm.ps1'))) 'Setup installed into a foreign folder'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $foreign '_uninstall'))) 'Setup left an uninstaller in a foreign folder'
Remove-Item -LiteralPath $foreign -Recurse -Force
Write-Host 'installer-tests: PASS'
