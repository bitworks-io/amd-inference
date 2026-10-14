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
Write-Host 'installer-tests: PASS'
