#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$root = Split-Path $PSScriptRoot -Parent
$helper = Join-Path $root 'src/FastLlm.PrerequisiteDiagnostics.ps1'
$worker = Join-Path $root 'tools/collect-prerequisite-inventory.ps1'
$tokens = $null
$parseErrors = $null
[Management.Automation.Language.Parser]::ParseFile($helper, [ref]$tokens, [ref]$parseErrors) | Out-Null
if ($parseErrors.Count) { throw 'Prerequisite diagnostic helper does not parse.' }
[Management.Automation.Language.Parser]::ParseFile($worker, [ref]$tokens, [ref]$parseErrors) | Out-Null
if ($parseErrors.Count) { throw 'Prerequisite diagnostic worker does not parse.' }
. $helper

$script:checks = 0
function Check([bool]$condition, [string]$message) {
    if (-not $condition) { throw "FAIL: $message" }
    $script:checks++
    Write-Host "PASS: $message"
}

$script:registryFails = $false
$script:fileFails = ''
function Read-FastLlmVcRuntimeRegistration {
    if ($script:registryFails) { throw 'mock access denied' }
    return [pscustomobject]@{ status='observed'; installed=$true; version='v14.51.36247.0'; versionState='observed' }
}
function Read-FastLlmPrerequisiteFile {
    param([string]$Name, [string]$System32)
    if ($Name -eq $script:fileFails) { throw 'mock file failure' }
    return [pscustomobject]@{ name=$Name; status='observed'; fileVersion='14.51.36247.0'; productVersion='14.51.36247.0'; signatureStatus='Valid'; signer='CN=Mock'; sha256=('a' * 64) }
}

$full = Get-FastLlmPrerequisiteSnapshot -System32Path 'fixture-system32'
Check (-not $full.partial -and $full.errors.Count -eq 0 -and $full.files.Count -eq 4) 'independent registry and four fixed file observations are retained'
Check ($full.vcRuntimeRegistration.version -eq 'v14.51.36247.0' -and
    -not $full.qualified -and -not $full.compatibilityVerified -and $null -eq $full.requiredVersion) 'version observation never claims compatibility or a required minimum'
Check ((@($full.files | ForEach-Object name) -join ',') -eq 'MSVCP140.dll,VCRUNTIME140.dll,VCRUNTIME140_1.dll,vulkan-1.dll') 'file list is fixed and bounded'
Assert-FastLlmPrerequisiteSnapshot -Snapshot $full
Check $true 'valid small snapshot passes the parent schema guard'
$badClaim = $full | ConvertTo-Json -Depth 6 | ConvertFrom-Json
$badClaim.qualified = $true
$rejected = $false
try { Assert-FastLlmPrerequisiteSnapshot -Snapshot $badClaim }
catch { $rejected = $true }
Check $rejected 'parent rejects an unexpected qualification claim'
$badNames = $full | ConvertTo-Json -Depth 6 | ConvertFrom-Json
$badNames.files[0].name = 'other.dll'
$rejected = $false
try { Assert-FastLlmPrerequisiteSnapshot -Snapshot $badNames }
catch { $rejected = $true }
Check $rejected 'parent rejects altered prerequisite file names'

$script:registryFails = $true
$script:fileFails = 'vulkan-1.dll'
$partial = Get-FastLlmPrerequisiteSnapshot -System32Path 'fixture-system32'
Check ($partial.partial -and $partial.errors.Count -eq 2 -and $null -eq $partial.vcRuntimeRegistration) 'registry failure does not hide independent file observations'
Check ($partial.files.Count -eq 4 -and $partial.files[3].status -eq 'error' -and
    $partial.files[0].status -eq 'observed' -and $partial.errors[1].section -eq 'vulkan-1.dll') 'one file failure does not hide other file observations'

# Restore the actual file reader for filesystem fixtures, without invoking signature inspection.
. $helper
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('fastllm-prereq-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -ErrorAction Stop | Out-Null
try {
    $missing = Read-FastLlmPrerequisiteFile -Name 'MSVCP140.dll' -System32 $fixture
    Check ($missing.status -eq 'missing' -and $null -eq $missing.sha256) 'missing expected file is an observation, not a readiness assertion'
    $rejected = $false
    try { Read-FastLlmPrerequisiteFile -Name 'arbitrary.dll' -System32 $fixture | Out-Null }
    catch { $rejected = $true }
    Check $rejected 'arbitrary file names cannot enter the diagnostic reader'
    $large = Join-Path $fixture 'vulkan-1.dll'
    $stream = [IO.File]::Open($large, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.SetLength(67108865) }
    finally { $stream.Dispose() }
    $rejected = $false
    try { Read-FastLlmPrerequisiteFile -Name 'vulkan-1.dll' -System32 $fixture | Out-Null }
    catch { $rejected = $true }
    Check $rejected 'oversize file is rejected before signature/hash work'
}
finally { Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue }

$module = Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force -PassThru
Check ($module.ExportedCommands.ContainsKey('Get-FastLlmPrerequisiteInventory')) 'diagnostic wrapper is exported'
if ($env:OS -ne 'Windows_NT') {
    $na = Get-FastLlmPrerequisiteInventory
    Check (-not $na.applicable -and -not $na.qualified) 'non-Windows wrapper is non-applicable without spawning a worker'
}
$source = Get-Content -LiteralPath (Join-Path $root 'fast-llm.ps1') -Raw
Check ($source.Contains('prerequisiteInventory = $null') -and $source.Contains('prerequisiteInventoryError = $null')) 'doctor carries isolated prerequisite result/error fields'
Check ($source.Contains('Get-FastLlmPrerequisiteInventory') -and $source.Contains('Get-FastLlmWindowsInventory')) 'doctor runs prerequisite and GPU inventories independently'
$package = Get-Content -LiteralPath (Join-Path $root 'tools/build-lab-package.ps1') -Raw
Check ($package.Contains("'tools/collect-prerequisite-inventory.ps1'")) 'lab package includes the dedicated diagnostic worker'
$ui = Get-Content -LiteralPath (Join-Path $root 'fast-llm-ui.ps1') -Raw
Check ($ui.Contains("LaunchStep 'diagnostics' (@('doctor')")) 'GUI Diagnostics uses doctor output that includes prerequisite inventory'
$helperSource = Get-Content -LiteralPath $helper -Raw
Check ($helperSource -notmatch 'WaitForExit\s*\(\s*\)' -and $helperSource.Contains('ElapsedMilliseconds -lt 20000')) 'worker exit and output delivery have no parameterless wait'
$workerSource = Get-Content -LiteralPath $worker -Raw
Check ($workerSource.Contains("`$ProgressPreference = 'SilentlyContinue'")) 'worker disables progress output before JSON emission'

Write-Host "Prerequisite diagnostic checks passed: $script:checks"
