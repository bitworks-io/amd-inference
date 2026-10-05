#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$repo = Split-Path $PSScriptRoot -Parent
$worker = Join-Path $repo 'src/WindowsInventory.ps1'
$nativeSource = Join-Path $repo 'src/WindowsHostInventory.cs'
$runtimeSource = Get-Content -LiteralPath (Join-Path $repo 'src/FastLlm.Runtime.ps1') -Raw
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($worker, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Windows inventory worker does not parse.' }
foreach ($name in @('Get-FastLlmBoundedHostString','Get-FastLlmNativeHostInventory')) {
    $node = $ast.Find({ param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name }, $true)
    if (-not $node) { throw "Missing host inventory function: $name" }
    . ([scriptblock]::Create($node.Extent.Text))
}
Add-Type -Path $nativeSource -ErrorAction Stop

$script:checks = 0
function Check([bool]$condition, [string]$message) {
    if (-not $condition) { throw "FAIL: $message" }
    $script:checks++
    Write-Host "PASS: $message"
}

$script:memoryFails = $false
$script:logicalFails = $false
$script:versionFails = $false
$script:architectureFails = $false
$script:registryFails = $false
$script:cpuOverflow = $false
$script:cpuValueMissing = $false
$script:boardProductMissing = $false
function Get-FastLlmNativePhysicalMemoryBytes { if ($script:memoryFails) { throw 'denied' }; return [long]34359738368 }
function Get-FastLlmNativeActiveLogicalProcessors { if ($script:logicalFails) { throw 'denied' }; return [int]16 }
function Get-FastLlmNativeOsVersion {
    if ($script:versionFails) { throw 'denied' }
    return [pscustomobject]@{ Major = [uint32]10; Minor = [uint32]0; Build = [uint32]26200 }
}
function Get-FastLlmNativeArchitecture { if ($script:architectureFails) { throw 'denied' }; return 'x64' }
function Get-ChildItem {
    [CmdletBinding()]
    param([string]$LiteralPath)
    if ($script:registryFails) { throw 'denied' }
    if ($script:cpuOverflow) {
        foreach ($i in 0..256) { [pscustomobject]@{ PSChildName = [string]$i; PSPath = "HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\$i" } }
        return
    }
    return [pscustomobject]@{ PSChildName = '0'; PSPath = 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' }
}
function Get-ItemProperty {
    [CmdletBinding()]
    param([string]$LiteralPath, [string]$Name)
    if ($script:registryFails) { throw 'denied' }
    if ($LiteralPath -like '*CurrentVersion') { return [pscustomobject]@{ UBR = [int]9168 } }
    if ($LiteralPath -like '*CentralProcessor*') {
        if ($script:cpuValueMissing) { return [pscustomobject]@{ ProcessorNameString = $null } }
        return [pscustomobject]@{ ProcessorNameString = 'Intel Core i5-13400F' }
    }
    if ($script:boardProductMissing) { return [pscustomobject]@{ SystemManufacturer = 'Test board' } }
    return [pscustomobject]@{ SystemManufacturer = 'Test board'; SystemProductName = 'Test product' }
}

$full = Get-FastLlmNativeHostInventory
Check ($full.schemaVersion -eq 1 -and $full.kind -eq 'windows-native-host-inventory' -and $full.qualified -eq $false) 'native host schema and nonqualification are explicit'
Check ($full.status -eq 'captured' -and $full.physicalMemoryBytes.value -eq [long]34359738368 -and $full.activeLogicalProcessors.value -eq 16) 'native RAM and logical CPU facts are captured independently'
Check ($full.os.status -eq 'captured' -and $full.os.build -eq 26200 -and $full.os.ubr -eq 9168 -and $full.os.architecture -eq 'x64') 'OS build, revision, and native architecture have separate provenance'
Check ($full.advisory.cpuNames.status -eq 'captured' -and $full.advisory.cpuNames.value.Count -eq 1) 'bounded CPU registry string is advisory only'
Check ($full.advisory.cpuNames.completeScan -and $full.advisory.cpuNames.enumeratedKeys -eq 1 -and $full.advisory.cpuNames.scanLimit -eq 256) 'CPU name provenance records a complete bounded key scan'

$script:cpuOverflow = $true
$overflow = Get-FastLlmNativeHostInventory
Check ($overflow.advisory.cpuNames.status -eq 'partial' -and -not $overflow.advisory.cpuNames.completeScan -and $overflow.advisory.cpuNames.enumeratedKeys -eq 257) 'processor-key overflow cannot look like complete CPU-name evidence'
$script:cpuOverflow = $false
$script:cpuValueMissing = $true
$missingCpuName = Get-FastLlmNativeHostInventory
Check ($missingCpuName.advisory.cpuNames.status -eq 'partial' -and -not $missingCpuName.advisory.cpuNames.completeScan) 'missing registry CPU name cannot look complete'
$script:cpuValueMissing = $false
$script:boardProductMissing = $true
$missingBoardProduct = Get-FastLlmNativeHostInventory
Check ($missingBoardProduct.advisory.systemManufacturer.status -eq 'captured' -and $missingBoardProduct.advisory.systemProductName.status -eq 'unavailable') 'board advisory fields fail independently'
$script:boardProductMissing = $false

$script:registryFails = $true
$registryDenied = Get-FastLlmNativeHostInventory
Check ($registryDenied.status -eq 'partial' -and $registryDenied.os.status -eq 'partial') 'missing UBR is not silently fabricated'
Check ($registryDenied.physicalMemoryBytes.status -eq 'captured' -and $registryDenied.advisory.cpuNames.status -eq 'unavailable') 'registry denial does not hide native API facts'

$script:memoryFails = $true
$script:logicalFails = $true
$script:versionFails = $true
$script:architectureFails = $true
$allDenied = Get-FastLlmNativeHostInventory
Check ($allDenied.status -eq 'unavailable' -and $null -eq $allDenied.physicalMemoryBytes.value -and $null -eq $allDenied.os.build) 'all unavailable remains explicit and null'
Check (-not ((ConvertTo-Json $allDenied -Depth 8) -match 'denied')) 'raw exception text is not serialized'

Check ($null -eq (Get-FastLlmBoundedHostString "bad`nname") -and $null -eq (Get-FastLlmBoundedHostString ('x' * 129))) 'control characters and oversize firmware strings are rejected'
Check ($runtimeSource -notmatch '\.Process\.WaitForExit\(\)' -and $runtimeSource.Contains('OutputCompleted') -and $runtimeSource.Contains('OutputTruncated')) 'inventory parent waits for bounded EOF and rejects truncation'
Check ($runtimeSource.Contains("output.Length -gt 65536") -and $runtimeSource.Contains('windows-native-host-inventory')) 'inventory parent bounds and validates worker JSON'
Check ($runtimeSource.IndexOf('$deadline = [Diagnostics.Stopwatch]::StartNew()') -lt $runtimeSource.IndexOf('$child.Start($info)') -and $runtimeSource.Contains('if ($deadline.ElapsedMilliseconds -ge 30000)')) 'inventory deadline spans child launch through final return'
Write-Host "$script:checks native host checks passed. No Windows native API was invoked."
