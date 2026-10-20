#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

# The ADLX probe as a standalone verified tool component: kind 'tool' is accepted, Get-FastLlmInstalledToolComponent returns a component only when it is
# listed, installed and passes the Full check, and tools/benchmark.ps1 uses it only when no ADLX argument is given. Fixtures are built at test time under a
# temp folder; nothing is downloaded and no benchmark runs (the script is exercised against a stub producer).
$repo = Split-Path $PSScriptRoot -Parent
$modulePath = Join-Path $repo 'src/FastLlm.psm1'
Import-Module $modulePath -Force
. (Join-Path $repo 'src/FastLlm.UiFlow.ps1')
$script:checks = 0
function Check([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
    Write-Host "PASS: $Message"
}
function Get-HexSha([string] $Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('fastllm-adlx-probe-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$exeName = 'adlx-identity-vram.exe'

# A components file listing the tool (and its pinned file list), plus the install tree for it. Install: none | complete.
function New-ToolFixture {
    param([string] $Kind = 'tool', [ValidateSet('none', 'complete')][string] $Install = 'complete')
    $dir = Join-Path $work ([Guid]::NewGuid().ToString('N'))
    $installRoot = Join-Path $dir 'install'
    $source = Join-Path $dir 'source'
    New-Item -ItemType Directory -Path $installRoot, $source -Force | Out-Null
    $manifest = @()
    foreach ($name in @($exeName, 'EULA.txt', 'NOTICE.txt')) {
        $path = Join-Path $source $name
        [System.IO.File]::WriteAllBytes($path, [System.Text.Encoding]::ASCII.GetBytes("fixture-$name"))
        $manifest += [ordered] @{ path = $name; sizeBytes = (Get-Item -LiteralPath $path).Length; sha256 = (Get-HexSha $path) }
    }
    $entry = [ordered] @{
        id          = 'bitworks-adlx-probe'
        kind        = $Kind
        displayName = 'Test ADLX probe'
        version     = '1'
        source      = [ordered] @{
            url                  = 'https://example.com/adlx-probe-1.zip'
            allowedRedirectHosts = @('example.com')
            sha256               = ('0' * 64)
            sizeBytes            = 100
            format               = 'zip'
            fileManifest         = @($manifest)
        }
        license     = [ordered] @{ spdx = 'LicenseRef-Test'; consent = 'accept'; links = @([ordered] @{ title = 'Test license'; url = 'https://example.com/EULA.md' }) }
        platform    = [ordered] @{ os = 'windows'; arch = 'x64'; backend = 'adlx' }
        entryPoint  = $exeName
        requires    = @()
        signer      = $null
    }
    $configDir = Join-Path $dir 'config'
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    $componentsPath = Join-Path $configDir 'components.json'
    $document = [ordered] @{ schema = 'bitworks.fastllm-components/v1'; components = @($entry) }
    [System.IO.File]::WriteAllText($componentsPath, (ConvertTo-Json -InputObject $document -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
    $root = $null
    if ($Kind -ceq 'tool' -or $Kind -ceq 'engine') {
        $root = Get-FastLlmComponentRoot -InstallRoot $installRoot -Component (@(Get-FastLlmComponents -ComponentsPath $componentsPath)[0])
    }
    else {
        $root = Join-Path $installRoot 'components/x/bitworks-adlx-probe/1'
    }
    if ($Install -ceq 'complete') {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        foreach ($name in @($exeName, 'EULA.txt', 'NOTICE.txt')) { Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $root $name) }
    }
    return [pscustomobject] @{ Dir = $dir; InstallRoot = $installRoot; ComponentsPath = $componentsPath; Root = $root; ExeSha = ($manifest | Where-Object { $_.path -ceq $exeName } | Select-Object -First 1).sha256 }
}
function Get-Tool($Fixture, [string] $ExecutableName) {
    $params = @{ Id = 'bitworks-adlx-probe'; InstallRoot = $Fixture.InstallRoot; ComponentsPath = $Fixture.ComponentsPath }
    if ($ExecutableName) { $params.ExecutableName = $ExecutableName }
    return Get-FastLlmInstalledToolComponent @params
}

# tools/benchmark.ps1 runs in a child host against a copy of the module (so no benchmark runs): the real
# discovery helper stays, and only Invoke-FastLlmBenchmark is replaced by a recorder (a copy of src/ with a recorder appended in place of Invoke-FastLlmBenchmark).
function Invoke-BenchmarkScript($Fixture, [string[]] $ExtraArguments) {
    $tree = Join-Path $Fixture.Dir 'tree'
    New-Item -ItemType Directory -Path (Join-Path $tree 'tools'), (Join-Path $tree 'src'), (Join-Path $tree 'config') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'tools/benchmark.ps1') -Destination (Join-Path $tree 'tools/benchmark.ps1') -Force
    Copy-Item -LiteralPath $Fixture.ComponentsPath -Destination (Join-Path $tree 'config/components.json') -Force
    $recordPath = Join-Path $Fixture.Dir 'record.json'
    if (Test-Path -LiteralPath $recordPath) { Remove-Item -LiteralPath $recordPath -Force }
    Copy-Item -Path (Join-Path $repo 'src/*') -Destination (Join-Path $tree 'src') -Recurse -Force
    $stub = @"

function Invoke-FastLlmBenchmark {
    param([string]`$InstallRoot, [string]`$OutputPath, [int[]]`$PromptTokens, [int]`$GenerationTokens, [int]`$Repetitions, [string]`$AdlxExecutablePath, [string]`$AdlxExecutableSha256)
    [System.IO.File]::WriteAllText('$($recordPath.Replace("'", "''"))', (ConvertTo-Json -InputObject ([ordered] @{ path = `$AdlxExecutablePath; sha256 = `$AdlxExecutableSha256; pathBound = `$PSBoundParameters.ContainsKey('AdlxExecutablePath'); shaBound = `$PSBoundParameters.ContainsKey('AdlxExecutableSha256') })))
}
Export-ModuleMember -Function Invoke-FastLlmBenchmark
"@
    [System.IO.File]::AppendAllText((Join-Path $tree 'src/FastLlm.psm1'), $stub, (New-Object System.Text.UTF8Encoding($false)))
    $hostPath = (Get-Process -Id $PID).Path
    $arguments = @('-NoProfile', '-File', (Join-Path $tree 'tools/benchmark.ps1'), '-InstallRoot', $Fixture.InstallRoot, '-OutputPath', (Join-Path $Fixture.Dir 'out.json')) + $ExtraArguments
    $output = & $hostPath @arguments 2>&1 | Out-String
    $record = $null
    if (Test-Path -LiteralPath $recordPath) { $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json }
    return [pscustomobject] @{ Output = $output; Record = $record }
}

try {
    Check ($null -ne (Get-Command -Name Get-FastLlmInstalledToolComponent -Module FastLlm -ErrorAction SilentlyContinue)) 'Get-FastLlmInstalledToolComponent is exported'

    # ---- kind tool is accepted where kinds are validated ----
    $good = New-ToolFixture
    $listed = @(Get-FastLlmComponents -ComponentsPath $good.ComponentsPath)
    Check ($listed.Count -eq 1 -and [string] $listed[0].kind -ceq 'tool') 'a components file listing a tool component loads'
    $badKind = New-ToolFixture -Kind 'plugin' -Install none
    $kindFailure = $null
    try { Get-FastLlmComponents -ComponentsPath $badKind.ComponentsPath | Out-Null } catch { $kindFailure = [string] $_.Exception.Message }
    Check ($null -ne $kindFailure -and $kindFailure -match "unsupported kind 'plugin'") 'an unknown kind is still refused'
    Check ($good.Root -match '[\\/]components[\\/]tool[\\/]bitworks-adlx-probe[\\/]1$') 'a tool component root is components\tool\<id>\<version>'

    # ---- Get-FastLlmInstalledToolComponent ----
    $found = Get-Tool $good
    Check ($null -ne $found -and [string] $found.id -ceq 'bitworks-adlx-probe' -and [string] $found.version -ceq '1') 'installed and verified: returned with id and version'
    Check ([string] $found.sha256 -ceq $good.ExeSha) 'the sha256 is the executable''s fileManifest entry'
    Check ([System.IO.Path]::IsPathRooted([string] $found.path) -and [string] $found.path -ceq (Join-Path $good.Root $exeName)) 'the path is the absolute executable path inside the component root'
    Check ($null -ne (Get-Tool $good $exeName)) 'an explicit executable name is accepted'
    Check ([string] (Get-Tool $good 'EULA.txt').path -ceq (Join-Path $good.Root 'EULA.txt')) 'another listed file can be named'
    Check ($null -eq (Get-Tool $good 'missing.exe')) 'a file the manifest does not list returns $null'

    $notInstalled = New-ToolFixture -Install none
    Check ($null -eq (Get-Tool $notInstalled)) 'listed but not installed: $null'

    $changed = New-ToolFixture
    [System.IO.File]::WriteAllBytes((Join-Path $changed.Root $exeName), [System.Text.Encoding]::ASCII.GetBytes('fixture-adlx-identity-vram.exe'.Replace('fixture', 'tampered')))
    $changedResult = 'unset'
    $changedThrown = $null
    try { $changedResult = Get-Tool $changed } catch { $changedThrown = [string] $_.Exception.Message }
    Check ($null -eq $changedThrown -and $null -eq $changedResult) 'installed but the executable hash does not match: $null and no throw'

    $sameSizeChanged = New-ToolFixture
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $sameSizeChanged.Root $exeName))
    $bytes[0] = [byte] ($bytes[0] -bxor 1)
    [System.IO.File]::WriteAllBytes((Join-Path $sameSizeChanged.Root $exeName), $bytes)
    Check ($null -eq (Get-Tool $sameSizeChanged)) 'a same-size change is caught by the Full check'

    $extra = New-ToolFixture
    [System.IO.File]::WriteAllText((Join-Path $extra.Root 'extra.txt'), 'x')
    Check ($null -eq (Get-Tool $extra)) 'a file the manifest does not list fails verification: $null'

    $missingFile = New-ToolFixture
    Remove-Item -LiteralPath (Join-Path $missingFile.Root 'NOTICE.txt') -Force
    Check ($null -eq (Get-Tool $missingFile)) 'a missing manifest file fails verification: $null'

    $wrongKind = New-ToolFixture -Kind 'engine'
    Check ($null -eq (Get-Tool $wrongKind)) 'a listed component that is not a tool: $null'
    $otherId = Get-FastLlmInstalledToolComponent -Id 'some-other-tool' -InstallRoot $good.InstallRoot -ComponentsPath $good.ComponentsPath
    Check ($null -eq $otherId) 'an id the list does not contain: $null'
    $noFile = Get-FastLlmInstalledToolComponent -Id 'bitworks-adlx-probe' -InstallRoot $good.InstallRoot -ComponentsPath (Join-Path $work 'no-such-components.json')
    Check ($null -eq $noFile) 'a missing components file: $null and no throw'
    Check ($null -eq (Get-Tool $good 'sub/x.exe')) 'a path-like executable name that is not listed: $null'

    # ---- tools/benchmark.ps1 ----
    $viaScript = New-ToolFixture
    $run = Invoke-BenchmarkScript $viaScript @()
    Check ($null -ne $run.Record -and [string] $run.Record.path -ceq (Join-Path $viaScript.Root $exeName) -and [string] $run.Record.sha256 -ceq $viaScript.ExeSha) 'discovery: the installed, verified probe path and sha are passed to the producer'
    Check ($run.Output -match 'Using the installed ADLX probe component bitworks-adlx-probe 1\.') 'discovery: one line says which probe component is used'

    $runNone = Invoke-BenchmarkScript $notInstalled @()
    Check ($null -ne $runNone.Record -and -not [bool] $runNone.Record.pathBound -and -not [bool] $runNone.Record.shaBound) 'not installed: no ADLX argument is passed'
    Check ($runNone.Output -notmatch 'Using the installed ADLX probe') 'not installed: no discovery line'

    $runChanged = Invoke-BenchmarkScript $changed @()
    Check ($null -ne $runChanged.Record -and -not [bool] $runChanged.Record.pathBound -and -not [bool] $runChanged.Record.shaBound -and $runChanged.Output -notmatch 'Using the installed ADLX probe') 'hash mismatch: not used, and the run still proceeds'

    $explicitSha = ('ab' * 32)
    $runExplicit = Invoke-BenchmarkScript $viaScript @('-AdlxExecutablePath', (Join-Path $work 'explicit.exe'), '-AdlxExecutableSha256', $explicitSha)
    Check ($null -ne $runExplicit.Record -and [string] $runExplicit.Record.path -ceq (Join-Path $work 'explicit.exe') -and [string] $runExplicit.Record.sha256 -ceq $explicitSha) 'explicit arguments win over the installed component'
    Check ($runExplicit.Output -notmatch 'Using the installed ADLX probe') 'explicit arguments: no discovery line'

    $runPathOnly = Invoke-BenchmarkScript $viaScript @('-AdlxExecutablePath', (Join-Path $work 'explicit.exe'))
    Check ($null -ne $runPathOnly.Record -and [bool] $runPathOnly.Record.pathBound -and -not [bool] $runPathOnly.Record.shaBound) 'one explicit argument is never completed from discovery'

    $runShaOnly = Invoke-BenchmarkScript $viaScript @('-AdlxExecutableSha256', $explicitSha)
    Check ($null -ne $runShaOnly.Record -and -not [bool] $runShaOnly.Record.pathBound -and [bool] $runShaOnly.Record.shaBound -and [string] $runShaOnly.Record.sha256 -ceq $explicitSha) 'the other explicit argument alone is passed as given'

    $runOff = Invoke-BenchmarkScript $viaScript @('-NoAdlxProbe')
    Check ($null -ne $runOff.Record -and -not [bool] $runOff.Record.pathBound -and -not [bool] $runOff.Record.shaBound -and $runOff.Output -notmatch 'Using the installed ADLX probe') '-NoAdlxProbe disables discovery'

    # The shipped entry (the real config/components.json): it loads, is a tool with its executable in the pinned file list, and its license links pass the UI gate.
    $shippedProbe = @(Get-FastLlmComponents -ComponentsPath (Join-Path $repo 'config/components.json') | Where-Object { [string] $_.id -ceq 'bitworks-adlx-probe' })
    Check ($shippedProbe.Count -eq 1 -and [string] $shippedProbe[0].kind -ceq 'tool') 'shipped: bitworks-adlx-probe loads as a tool'
    $shippedManifest = @($shippedProbe[0].source.fileManifest)
    Check ([string] $shippedProbe[0].entryPoint -ceq $exeName -and @($shippedManifest | Where-Object { [string] $_.path -ceq $exeName }).Count -eq 1) 'shipped: the entry point is in the pinned file list'
    Check ([string] (@($shippedManifest | Where-Object { [string] $_.path -ceq $exeName })[0].sha256) -ceq 'f53e3eebbf97de5bc8de97fbcbb357df83b71c16579be761d7567c0935cc2766') 'shipped: the executable is pinned to the released hash'
    Check ([string] $shippedProbe[0].license.consent -ceq 'accept' -and @($shippedProbe[0].license.links).Count -eq 2) 'shipped: the license needs acceptance and lists two links'
    foreach ($link in @($shippedProbe[0].license.links)) {
        Check ($null -ne (Get-FastLlmUiSafeLicenseUrl -Url ([string] $link.url))) "shipped: the license link '$($link.title)' passes the UI safety gate"
    }

    Write-Host "All $script:checks checks passed."
}
finally {
    try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}
