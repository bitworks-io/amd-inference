#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# Verified side-by-side component install, inventory and removal (module functions in src/FastLlm.psm1).
# Fixtures (a zip, its pins and a components.json) are built at test time under a temp folder and passed in with
# -ComponentsPath and the -Download seam. Nothing is written into the repo's config/.
$modulePath = Join-Path $PSScriptRoot '../src/FastLlm.psm1'
Import-Module $modulePath -Force
$module = Get-Module FastLlm
Add-Type -AssemblyName System.IO.Compression.FileSystem
$script:checks = 0
function Check([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
    Write-Host "PASS: $Message"
}
function Get-ThrownMessage([scriptblock] $Block) {
    try { & $Block | Out-Null } catch { return [string] $_.Exception.Message }
    return $null
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('fastllm-components-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null

function New-TestRoot {
    $path = Join-Path $work ([Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Get-HexSha([string] $Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

# Builds <Dir>\fixture.zip (flat files), its pins and a components.json. ExtraFile adds a file to the zip that the manifest omits.
function New-Fixture {
    param(
        [string] $Dir,
        [string] $Id = 'test-engine-1',
        [string] $Version = 'v1',
        [string] $Consent = 'show',
        [string] $Salt = 'a',
        [switch] $ExtraFile
    )
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    $src = Join-Path $Dir 'src'
    New-Item -ItemType Directory -Path $src -Force | Out-Null
    $manifest = @()
    foreach ($name in @('server.exe', 'engine.dll')) {
        $filePath = Join-Path $src $name
        [System.IO.File]::WriteAllBytes($filePath, [System.Text.Encoding]::ASCII.GetBytes("content-$name-$Id-$Version-$Salt"))
        $manifest += [ordered] @{ path = $name; sizeBytes = (Get-Item -LiteralPath $filePath).Length; sha256 = (Get-HexSha $filePath) }
    }
    if ($ExtraFile) {
        [System.IO.File]::WriteAllBytes((Join-Path $src 'extra.txt'), [System.Text.Encoding]::ASCII.GetBytes('not in the manifest'))
    }
    $zip = Join-Path $Dir 'fixture.zip'
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($src, $zip)
    $entry = [ordered] @{
        id          = $Id
        kind        = 'engine'
        displayName = "Test engine $Version"
        version     = $Version
        source      = [ordered] @{
            url                  = "https://example.com/downloads/$Id-$Version.zip"
            allowedRedirectHosts = @('example.com', 'cdn.example.com')
            sha256               = (Get-HexSha $zip)
            sizeBytes            = (Get-Item -LiteralPath $zip).Length
            format               = 'zip'
            fileManifest         = @($manifest)
        }
        license     = [ordered] @{ spdx = 'MIT'; url = 'https://example.com/LICENSE'; consent = $Consent }
        platform    = [ordered] @{ os = 'windows'; arch = 'x64'; backend = 'vulkan' }
        adapter     = 'llama.cpp'
        entryPoint  = 'server.exe'
        requires    = @()
        signer      = $null
    }
    $document = [ordered] @{ schema = 'bitworks.fastllm-components/v1'; components = @($entry) }
    $componentsPath = Join-Path $Dir 'components.json'
    [System.IO.File]::WriteAllText($componentsPath, (ConvertTo-Json -InputObject $document -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
    return [pscustomobject] @{ ComponentsPath = $componentsPath; Zip = $zip; Id = $Id; Version = $Version; Dir = $Dir }
}

# A -Download seam that copies a prebuilt zip. State goes into locals first: closures must not read script-level variables.
function New-CopySeam([string] $Zip, [hashtable] $Counter) {
    $zipLocal = $Zip
    $counterLocal = $Counter
    return {
        param($Url, $Destination, $Sha256, $SizeBytes, $AllowedRedirectHosts)
        $counterLocal.count = [int] $counterLocal.count + 1
        $counterLocal.hosts = @($AllowedRedirectHosts)
        $counterLocal.url = [string] $Url
        $counterLocal.destination = [string] $Destination
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Destination)) | Out-Null
        Copy-Item -LiteralPath $zipLocal -Destination $Destination -Force
    }.GetNewClosure()
}

function Install-Fixture($Fixture, [string] $InstallRoot, [hashtable] $Counter, [switch] $AcceptLicense, [switch] $Unattended) {
    $seam = New-CopySeam -Zip $Fixture.Zip -Counter $Counter
    $params = @{ ComponentsPath = $Fixture.ComponentsPath; ComponentId = $Fixture.Id; InstallRoot = $InstallRoot; Download = $seam }
    if ($AcceptLicense) { $params.AcceptLicense = $true }
    if ($Unattended) { $params.Unattended = $true }
    return Install-FastLlmComponent @params
}

$moduleSourceEarly = Get-Content -LiteralPath $modulePath -Raw

try {
    # ---- Exports and the shipped components.json ----
    foreach ($name in @('Get-FastLlmComponents', 'Get-FastLlmComponentRoot', 'Get-FastLlmComponentSources', 'Get-FastLlmComponentChain', 'Test-FastLlmComponentInstallation', 'Install-FastLlmComponent', 'Get-FastLlmComponentInventory', 'Remove-FastLlmComponent')) {
        Check ($null -ne (Get-Command -Name $name -Module FastLlm -ErrorAction SilentlyContinue)) "$name is exported"
    }
    $shipped = @(Get-FastLlmComponents -ComponentsPath (Join-Path $PSScriptRoot '../config/components.json'))
    Check ($shipped.Count -ge 1 -and [string] $shipped[0].id -ceq 'llama.cpp-b10698-vulkan') 'the shipped components.json loads and lists the b10698 Vulkan engine'
    Check ($shipped[0] -isnot [System.Array] -and $null -ne $shipped[0].PSObject.Properties['adapter']) '@(Get-FastLlmComponents) yields the component entries themselves, not one nested array'
    $shippedRoot = Get-FastLlmComponentRoot -InstallRoot (Join-Path $work 'shipped') -Component $shipped[0]
    $expectedTail = [System.IO.Path]::Combine('components', 'engine', 'llama.cpp-b10698-vulkan', 'b10698')
    Check ($shippedRoot.EndsWith($expectedTail, [System.StringComparison]::OrdinalIgnoreCase)) 'the component root is components\<kind>\<id>\<version>'

    # Rejects a traversing id.
    $badDir = Join-Path $work 'bad-id'
    $badFixture = New-Fixture -Dir $badDir
    $badText = (Get-Content -LiteralPath $badFixture.ComponentsPath -Raw).Replace('"id":  "test-engine-1"', '"id":  "..\\evil"')
    if ($badText -eq (Get-Content -LiteralPath $badFixture.ComponentsPath -Raw)) { $badText = (Get-Content -LiteralPath $badFixture.ComponentsPath -Raw).Replace('"id": "test-engine-1"', '"id": "..\\evil"') }
    [System.IO.File]::WriteAllText($badFixture.ComponentsPath, $badText, (New-Object System.Text.UTF8Encoding($false)))
    $msg = Get-ThrownMessage { Get-FastLlmComponents -ComponentsPath $badFixture.ComponentsPath }
    Check ($null -ne $msg -and $msg -like '*Component id*') 'a components file with a traversing id is refused'

    # Ids and versions are folder names: case-duplicates, trailing dot or space and reserved device names are refused.
    function New-IdVariantFile([string] $SourceFile, [string[]] $EntryIds, [string] $EntryVersion) {
        $variantDocument = Get-Content -LiteralPath $SourceFile -Raw | ConvertFrom-Json
        $variantFirst = @($variantDocument.components)[0]
        $variantList = New-Object 'System.Collections.Generic.List[object]'
        foreach ($variantId in $EntryIds) {
            $variantCopy = $variantFirst | ConvertTo-Json -Depth 10 | ConvertFrom-Json
            $variantCopy.id = $variantId
            if ($EntryVersion) { $variantCopy.version = $EntryVersion }
            $variantList.Add($variantCopy)
        }
        $variantDocument.components = $variantList.ToArray()
        $variantPath = Join-Path (New-TestRoot) 'components.json'
        [System.IO.File]::WriteAllText($variantPath, (ConvertTo-Json -InputObject $variantDocument -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
        return $variantPath
    }
    $variantSource = (New-Fixture -Dir (Join-Path $work 'fx-variant')).ComponentsPath
    $msg = Get-ThrownMessage { Get-FastLlmComponents -ComponentsPath (New-IdVariantFile -SourceFile $variantSource -EntryIds @('dup-a', 'DUP-A')) }
    Check ($null -ne $msg -and $msg -like '*more than once*') 'two ids that differ only in case are refused as duplicates'
    foreach ($reservedId in @('con', 'NUL', 'com1', 'LPT9', 'aux.txt', 'prn')) {
        $msg = Get-ThrownMessage { Get-FastLlmComponents -ComponentsPath (New-IdVariantFile -SourceFile $variantSource -EntryIds @($reservedId)) }
        Check ($null -ne $msg -and $msg -like '*reserved Windows device name*') "the reserved device name '$reservedId' is refused as a component id"
    }
    $msg = Get-ThrownMessage { Get-FastLlmComponents -ComponentsPath (New-IdVariantFile -SourceFile $variantSource -EntryIds @('abc.')) }
    Check ($null -ne $msg -and $msg -like '*Component id*end with a dot or a space*') 'an id with a trailing dot is refused'
    $msg = Get-ThrownMessage { Get-FastLlmComponents -ComponentsPath (New-IdVariantFile -SourceFile $variantSource -EntryIds @('abc') -EntryVersion 'v1.') }
    Check ($null -ne $msg -and $msg -like '*version*end with a dot or a space*') 'a version with a trailing dot is refused'
    $msg = Get-ThrownMessage { Get-FastLlmComponents -ComponentsPath (New-IdVariantFile -SourceFile $variantSource -EntryIds @('abc') -EntryVersion 'nul') }
    Check ($null -ne $msg -and $msg -like '*version*reserved Windows device name*') 'a reserved device name is refused as a version'
    Check ($null -eq (Get-ThrownMessage { Get-FastLlmComponents -ComponentsPath (New-IdVariantFile -SourceFile $variantSource -EntryIds @('console', 'com10', 'abc-1.2')) })) 'ids that merely start like a device name (console, com10) are accepted'

    # ---- C3: multi-source zip-tree, requires chains, license links, runtimePathDirs ----
    function Get-ThrownCode([scriptblock] $Block) {
        try { & $Block | Out-Null } catch { return [string] $_.Exception.Data['FastLlmFailureCode'] }
        return $null
    }
    $zeroSha = '0' * 64
    function New-TreePart([string[]] $Paths, [string] $Format = 'zip-tree', $Prefix = 'pre/', [string] $HostName = 'example.com') {
        $files = @()
        foreach ($treePath in $Paths) { $files += [ordered] @{ path = $treePath; sizeBytes = 3; sha256 = $zeroSha } }
        $part = [ordered] @{ url = "https://$HostName/$([guid]::NewGuid().ToString('N')).zip"; allowedRedirectHosts = @($HostName); sha256 = $zeroSha; sizeBytes = 10; format = $Format }
        if ($null -ne $Prefix) { $part.extractPrefix = $Prefix }
        $part.fileManifest = @($files)
        return $part
    }
    function New-TreeComponent([string] $Id, $Parts, [string[]] $Requires = @(), [string] $Kind = 'runtime', $PathDirs = $null, $License = $null, [switch] $LegacySource) {
        if ($null -eq $License) { $License = [ordered] @{ spdx = 'proprietary'; url = 'https://example.com/license'; consent = 'accept' } }
        $component = [ordered] @{ id = $Id; kind = $Kind; displayName = $Id; version = '1.0' }
        if ($LegacySource) { $component.source = @($Parts)[0] } else { $component.sources = @($Parts) }
        $component.license = $License
        $component.platform = [ordered] @{ os = 'windows'; arch = 'x64'; backend = 'hip' }
        if ($null -ne $PathDirs) { $component.runtimePathDirs = @($PathDirs) }
        $component.requires = @($Requires)
        $component.signer = $null
        return $component
    }
    function Write-ComponentsDoc($Components) {
        $docPath = Join-Path (New-TestRoot) 'components.json'
        $docObject = [ordered] @{ schema = 'bitworks.fastllm-components/v1'; components = @($Components) }
        [System.IO.File]::WriteAllText($docPath, (ConvertTo-Json -InputObject $docObject -Depth 12), (New-Object System.Text.UTF8Encoding($false)))
        return $docPath
    }
    function Load-TreeDoc($Components) { return Get-ThrownMessage { Get-FastLlmComponents -ComponentsPath (Write-ComponentsDoc $Components) } }

    $okPart = New-TreePart -Paths @('bin/a.dll', 'bin/rocblas/library/x.dat', '.kpack/blas.kpack') -Prefix '_rocm_sdk_libraries/'
    $okRuntime = New-TreeComponent -Id 'rt-ok' -Parts @($okPart) -PathDirs @('bin')
    $okLoaded = @(Get-FastLlmComponents -ComponentsPath (Write-ComponentsDoc @($okRuntime)))
    Check ($okLoaded.Count -eq 1 -and @(Get-FastLlmComponentSources -Component $okLoaded[0])[0].extractPrefix -ceq '_rocm_sdk_libraries/') 'a zip-tree runtime with nested paths, a leading-dot segment (.kpack) and a leading-underscore prefix loads'

    # Nested paths: every segment passes the leaf rules.
    foreach ($case in @(
            @{ path = 'bin/../x.dll'; text = '*not a simple name*' }, @{ path = '../x.dll'; text = '*not a simple name*' },
            @{ path = 'bin/x:y.dll'; text = '*not a simple name*' }, @{ path = 'C:/x.dll'; text = '*not a simple name*' },
            @{ path = '/abs/x.dll'; text = '*not a simple name*' }, @{ path = 'bin\x.dll'; text = '*not a simple name*' },
            @{ path = 'bin//x.dll'; text = '*not a simple name*' }, @{ path = 'bin/./x.dll'; text = '*not a simple name*' },
            @{ path = 'bin/x.'; text = '*end with a dot or a space*' }, @{ path = 'bin/x '; text = '*not a simple name*' },
            @{ path = 'bin/con'; text = '*reserved Windows device name*' }, @{ path = 'NUL/x.dll'; text = '*reserved Windows device name*' },
            @{ path = 'bin/com1.txt'; text = '*reserved Windows device name*' },
            @{ path = 'bin/..a'; text = '*not a simple name*' }, @{ path = 'bin/._a'; text = '*not a simple name*' },
            @{ path = 'bin/__a'; text = '*not a simple name*' }, @{ path = 'bin/...'; text = '*not a simple name*' },
            @{ path = ('bin/' + ('a' * 201)); text = '*not a simple name*' },
            @{ path = "bin/x.dll`n"; text = '*not a simple name*' }, @{ path = "bin/x.`n"; text = '*not a simple name*' },
            @{ path = "bin/con`n"; text = '*not a simple name*' },
            @{ path = ('bin/' + [char] 0x212A + '.dll'); text = '*not a simple name*' })) {
        $badComponent = New-TreeComponent -Id 'rt-bad' -Parts @((New-TreePart -Paths @('bin/ok.dll', $case.path)))
        $msg = Load-TreeDoc @($badComponent)
        Check ($null -ne $msg -and $msg -like $case.text) ("the zip-tree path '" + ($case.path -replace "`n", '\n') + "' is refused")
    }
    Check ($null -eq (Load-TreeDoc @((New-TreeComponent -Id 'rt-near' -Parts @((New-TreePart -Paths @('bin/console.dll', 'bin/com10.dll', '.kpack/a.b', ('bin/' + ('a' * 200)), '_a/.b/c.d')))))) ) 'zip-tree paths that merely look like device names (console, com10) are accepted'
    $flat = New-TreeComponent -Id 'rt-flat' -Parts @((New-TreePart -Paths @('sub/x.dll') -Format 'zip' -Prefix $null))
    $msg = Load-TreeDoc @($flat)
    Check ($null -ne $msg -and $msg -like '*manifest path*') 'a flat zip manifest still refuses a nested path'

    # Flat zip names and versions keep the simple leaf rule: no leading dot or underscore, ASCII only, nothing after the last character.
    foreach ($flatName in @('.hidden', '_x.dll', 'a b.dll', "x.dll`n", ([string] [char] 0x212A + '.dll'), 'con', 'x.')) {
        $msg = Load-TreeDoc @((New-TreeComponent -Id 'rt-flatname' -Parts @((New-TreePart -Paths @($flatName) -Format 'zip' -Prefix $null))))
        Check ($null -ne $msg -and $msg -like '*manifest path*') ("the flat zip name '" + ($flatName -replace "`n", '\n') + "' is refused")
    }
    foreach ($badVersion in @('.x', '_x', "v1`n", ([string] [char] 0x212A + '1'))) {
        $msg = Get-ThrownMessage { Get-FastLlmComponents -ComponentsPath (New-IdVariantFile -SourceFile $variantSource -EntryIds @('abc') -EntryVersion $badVersion) }
        Check ($null -ne $msg -and $msg -like '*version*') ("the version '" + ($badVersion -replace "`n", '\n') + "' is refused")
    }
    $msg = Get-ThrownMessage { Get-FastLlmComponents -ComponentsPath (New-IdVariantFile -SourceFile $variantSource -EntryIds @("abc`n")) }
    Check ($null -ne $msg -and $msg -like '*Component id*') 'an id with a trailing line feed is refused'
    $msg = Get-ThrownMessage { Get-FastLlmComponents -ComponentsPath (New-IdVariantFile -SourceFile $variantSource -EntryIds @(([string] [char] 0x212A + 'abc'))) }
    Check ($null -ne $msg -and $msg -like '*Component id*') 'an id with a Kelvin sign is refused'

    # extractPrefix.
    foreach ($case in @(@{ prefix = $null; text = '*extractPrefix ending in*' }, @{ prefix = 'pre'; text = '*extractPrefix ending in*' }, @{ prefix = 'pre//'; text = '*extractPrefix*not a simple name*' },
            @{ prefix = '../pre/'; text = '*extractPrefix*not a simple name*' }, @{ prefix = '/pre/'; text = '*extractPrefix*not a simple name*' },
            @{ prefix = 'c:/pre/'; text = '*extractPrefix*not a simple name*' }, @{ prefix = 'con/'; text = '*extractPrefix*reserved*' })) {
        $msg = Load-TreeDoc @((New-TreeComponent -Id 'rt-pre' -Parts @((New-TreePart -Paths @('bin/a.dll') -Prefix $case.prefix))))
        Check ($null -ne $msg -and $msg -like $case.text) "the extractPrefix '$($case.prefix)' is refused"
    }
    $msg = Load-TreeDoc @((New-TreeComponent -Id 'rt-pre2' -Parts @((New-TreePart -Paths @('a.dll') -Format 'zip' -Prefix 'pre/'))))
    Check ($null -ne $msg -and $msg -like '*extractPrefix is only for zip-tree*') 'an extractPrefix on a flat zip source is refused'

    # source / sources shape.
    $both = New-TreeComponent -Id 'rt-both' -Parts @($okPart)
    $both.source = $okPart
    $msg = Load-TreeDoc @($both)
    Check ($null -ne $msg -and $msg -like "*exactly one of 'source' or 'sources'*") 'a component with both source and sources is refused'
    $neither = New-TreeComponent -Id 'rt-neither' -Parts @($okPart)
    $neither.Remove('sources')
    $msg = Load-TreeDoc @($neither)
    Check ($null -ne $msg -and $msg -like "*exactly one of 'source' or 'sources'*") 'a component with neither source nor sources is refused'
    $msg = Load-TreeDoc @((New-TreeComponent -Id 'rt-empty' -Parts @()))
    Check ($null -ne $msg -and $msg -like '*lists no sources*') 'an empty sources list is refused'

    # Disjoint paths, case-insensitively, within and across parts.
    $msg = Load-TreeDoc @((New-TreeComponent -Id 'rt-ov1' -Parts @((New-TreePart -Paths @('bin/a.dll')), (New-TreePart -Paths @('bin/a.dll', 'bin/b.dll')))))
    Check ($null -ne $msg -and $msg -like '*appears more than once*') 'overlapping part paths are refused'
    $msg = Load-TreeDoc @((New-TreeComponent -Id 'rt-ov2' -Parts @((New-TreePart -Paths @('bin/a.dll')), (New-TreePart -Paths @('BIN/A.DLL')))))
    Check ($null -ne $msg -and $msg -like '*appears more than once*') 'part paths that differ only in case are refused'
    $msg = Load-TreeDoc @((New-TreeComponent -Id 'rt-ov3' -Parts @((New-TreePart -Paths @('bin/a.dll', 'bin/A.dll')))))
    Check ($null -ne $msg -and $msg -like '*appears more than once*') 'case-only duplicates inside one part are refused'
    $msg = Load-TreeDoc @((New-TreeComponent -Id 'rt-ov4' -Parts @((New-TreePart -Paths @('bin')), (New-TreePart -Paths @('bin/a.dll')))))
    Check ($null -ne $msg -and $msg -like '*both a file and a directory*') 'a path that is a file in one part and a directory in another is refused'
    Check ($null -eq (Load-TreeDoc @((New-TreeComponent -Id 'rt-dj' -Parts @((New-TreePart -Paths @('bin/a.dll')), (New-TreePart -Paths @('bin/b.dll'))))))) 'disjoint parts load'

    # requires.
    $mk = { param($id, $reqs) New-TreeComponent -Id $id -Parts @((New-TreePart -Paths @("bin/$id.dll"))) -Requires $reqs }
    # The chain functions take loaded components (objects), not the hashtables the document builder makes.
    $mkObj = { param($id, $reqs) [pscustomobject] (& $mk $id $reqs) }
    $msg = Get-ThrownMessage { Get-FastLlmComponents -ComponentsPath (Write-ComponentsDoc @((& $mk 'ra' @('nope')))) }
    Check ($null -ne $msg -and $msg -like "*'nope'*not in the signed components list*") 'a requires naming an unlisted id is refused'
    Check ((Get-ThrownCode { Get-FastLlmComponents -ComponentsPath (Write-ComponentsDoc @((& $mk 'ra' @('nope')))) }) -ceq 'component-requires-unknown') 'an unknown requires is the typed failure component-requires-unknown'
    $msg = Get-ThrownMessage { Get-FastLlmComponents -ComponentsPath (Write-ComponentsDoc @((& $mk 'ra' @('RA')))) }
    Check ($null -ne $msg -and $msg -like '*requires itself*') 'a self-referential requires is refused'
    $cycleDoc = Write-ComponentsDoc @((& $mk 'ca' @('cb')), (& $mk 'cb' @('cc')), (& $mk 'cc' @('ca')))
    Check ((Get-ThrownCode { Get-FastLlmComponents -ComponentsPath $cycleDoc }) -ceq 'component-requires-cycle') 'a requires cycle is the typed failure component-requires-cycle at load time'
    $deepOk = Write-ComponentsDoc @((& $mk 'd1' @('d2')), (& $mk 'd2' @('d3')), (& $mk 'd3' @('d4')), (& $mk 'd4' @()))
    Check ($null -eq (Get-ThrownMessage { Get-FastLlmComponents -ComponentsPath $deepOk })) 'a requires chain of 4 loads'
    $deepBad = Write-ComponentsDoc @((& $mk 'd1' @('d2')), (& $mk 'd2' @('d3')), (& $mk 'd3' @('d4')), (& $mk 'd4' @('d5')), (& $mk 'd5' @()))
    Check ((Get-ThrownCode { Get-FastLlmComponents -ComponentsPath $deepBad }) -ceq 'component-requires-too-deep') 'a requires chain of 5 is the typed failure component-requires-too-deep'

    # Get-FastLlmComponentChain.
    $diamond = @((& $mkObj 'top' @('left', 'right')), (& $mkObj 'left' @('base')), (& $mkObj 'right' @('base')), (& $mkObj 'base' @()), (& $mkObj 'other' @()))
    $diamondChain = @(Get-FastLlmComponentChain -Components $diamond -Id 'top')
    Check ((($diamondChain | ForEach-Object { $_.id }) -join ',') -ceq 'base,left,right,top') 'the chain lists required components first, the named one last, each once'
    Check ((Get-ThrownCode { Get-FastLlmComponentChain -Components $diamond -Id 'missing' }) -ceq 'component-requires-unknown') 'Get-FastLlmComponentChain on an unknown id is component-requires-unknown'
    Check ((Get-ThrownCode { Get-FastLlmComponentChain -Components @((& $mkObj 'x1' @('x2')), (& $mkObj 'x2' @('x1'))) -Id 'x1' }) -ceq 'component-requires-cycle') 'Get-FastLlmComponentChain on a cycle is component-requires-cycle'
    Check ((Get-ThrownCode { Get-FastLlmComponentChain -Components @((& $mkObj 'y1' @('y2')), (& $mkObj 'y2' @('y3')), (& $mkObj 'y3' @('y4')), (& $mkObj 'y4' @('y5')), (& $mkObj 'y5' @())) -Id 'y1' }) -ceq 'component-requires-too-deep') 'Get-FastLlmComponentChain on a chain of 5 is component-requires-too-deep'
    $sharedDeep = @((& $mkObj 'top' @('xx', 'aa')), (& $mkObj 'aa' @('bb')), (& $mkObj 'bb' @('xx')), (& $mkObj 'xx' @('yy')), (& $mkObj 'yy' @()))
    Check ((Get-ThrownCode { Get-FastLlmComponentChain -Components $sharedDeep -Id 'top' }) -ceq 'component-requires-too-deep') 'a shared dependency reached by a 5-node path (top, aa, bb, xx, yy) is component-requires-too-deep even when a shallower path finished it first'
    $sharedDeepDoc = Write-ComponentsDoc @((& $mk 'top' @('xx', 'aa')), (& $mk 'aa' @('bb')), (& $mk 'bb' @('xx')), (& $mk 'xx' @('yy')), (& $mk 'yy' @()))
    Check ((Get-ThrownCode { Get-FastLlmComponents -ComponentsPath $sharedDeepDoc }) -ceq 'component-requires-too-deep') 'the same shared-dependency fixture is refused when the file loads'
    $diamond3 = @((& $mkObj 'top' @('aa', 'bb')), (& $mkObj 'aa' @('cc')), (& $mkObj 'bb' @('cc')), (& $mkObj 'cc' @()))
    Check ((@(Get-FastLlmComponentChain -Components $diamond3 -Id 'top') | ForEach-Object { $_.id }) -join ',' -ceq 'cc,aa,bb,top') 'a diamond within the limit lists the shared dependency once, first'
    Check (@(Get-FastLlmComponentChain -Components @((& $mkObj 'solo' @())) -Id 'solo').Count -eq 1) 'a component without requires is a chain of one'

    # Get-FastLlmComponentSources.
    $legacyList = @(Get-FastLlmComponentSources -Component $shipped[0])
    Check ($legacyList.Count -eq 1 -and $legacyList[0].format -ceq 'zip' -and $null -eq $legacyList[0].extractPrefix -and $legacyList[0].url -ceq [string] $shipped[0].source.url -and @($legacyList[0].fileManifest).Count -eq @($shipped[0].source.fileManifest).Count) 'Get-FastLlmComponentSources turns a legacy source into a one-element list'
    $multiList = @(Get-FastLlmComponentSources -Component $okLoaded[0])
    Check ($multiList.Count -eq 1 -and $multiList[0].format -ceq 'zip-tree') 'Get-FastLlmComponentSources returns a sources list as it is'

    # license.links and the accept rule.
    $linksLicense = [ordered] @{ spdx = 'proprietary'; consent = 'accept'; links = @([ordered] @{ title = 'EULA'; url = 'https://example.com/eula' }) }
    Check ($null -eq (Load-TreeDoc @((New-TreeComponent -Id 'lic-links' -Parts @($okPart) -License $linksLicense)))) 'an accept component with license.links and no license.url loads'
    $msg = Load-TreeDoc @((New-TreeComponent -Id 'lic-none' -Parts @($okPart) -License ([ordered] @{ spdx = 'proprietary'; consent = 'accept' })))
    Check ($null -ne $msg -and $msg -like '*license needs a url or links*') 'an accept component with neither license.url nor license.links is refused'
    $msg = Load-TreeDoc @((New-TreeComponent -Id 'lic-none-show' -Parts @($okPart) -License ([ordered] @{ spdx = 'MIT'; consent = 'show' })))
    Check ($null -ne $msg -and $msg -like '*license needs a url or links*') 'a show component with neither license.url nor license.links is refused too'
    foreach ($emptyUrlConsent in @('accept', 'show')) {
        $msg = Load-TreeDoc @((New-TreeComponent -Id 'lic-empty-url' -Parts @($okPart) -License ([ordered] @{ spdx = 'x'; url = ''; consent = $emptyUrlConsent; links = @([ordered] @{ title = 'EULA'; url = 'https://example.com/eula' }) })))
        Check ($null -ne $msg -and $msg -like '*license URL must be an https URL*') "an empty license.url is refused ($emptyUrlConsent), even with links"
    }
    $msg = Load-TreeDoc @((New-TreeComponent -Id 'lic-http' -Parts @($okPart) -License ([ordered] @{ spdx = 'x'; url = 'https://example.com/l'; consent = 'accept'; links = @([ordered] @{ title = 'EULA'; url = 'http://example.com/eula' }) })))
    Check ($null -ne $msg -and $msg -like '*license link URL*') 'a license link that is not https is refused'
    $msg = Load-TreeDoc @((New-TreeComponent -Id 'lic-title' -Parts @($okPart) -License ([ordered] @{ spdx = 'x'; url = 'https://example.com/l'; consent = 'accept'; links = @([ordered] @{ title = ''; url = 'https://example.com/eula' }) })))
    Check ($null -ne $msg -and $msg -like '*license link title*') 'a license link without a title is refused'
    $msg = Load-TreeDoc @((New-TreeComponent -Id 'lic-notitle' -Parts @($okPart) -License ([ordered] @{ spdx = 'x'; url = 'https://example.com/l'; consent = 'accept'; links = @([ordered] @{ url = 'https://example.com/eula' }) })))
    Check ($null -ne $msg -and $msg -like '*missing required property*title*') 'a license link with no title property is refused'

    # runtimePathDirs.
    $msg = Load-TreeDoc @((New-TreeComponent -Id 'pd-engine' -Kind 'engine' -Parts @($okPart) -PathDirs @('bin')))
    Check ($null -ne $msg -and $msg -like '*runtimePathDirs is only for runtime*') 'runtimePathDirs on a non-runtime component is refused'
    $msg = Load-TreeDoc @((New-TreeComponent -Id 'pd-empty' -Parts @($okPart) -PathDirs @('lib')))
    Check ($null -ne $msg -and $msg -like "*runtimePathDirs entry 'lib' has no manifest files*") 'a runtimePathDirs entry with no manifest files under it is refused'
    $msg = Load-TreeDoc @((New-TreeComponent -Id 'pd-dotdot' -Parts @($okPart) -PathDirs @('bin/..')))
    Check ($null -ne $msg -and $msg -like '*runtimePathDirs entry*not a simple name*') 'a runtimePathDirs entry with .. is refused'
    $msg = Load-TreeDoc @((New-TreeComponent -Id 'pd-abs' -Parts @($okPart) -PathDirs @('/bin')))
    Check ($null -ne $msg -and $msg -like '*runtimePathDirs entry*') 'a rooted runtimePathDirs entry is refused'
    $msg = Load-TreeDoc @((New-TreeComponent -Id 'pd-case' -Parts @($okPart) -PathDirs @('BIN')))
    Check ($null -eq $msg) 'runtimePathDirs matches manifest directories case-insensitively'

    # The shipped file.
    $shippedById = @{}
    foreach ($shippedEntry in $shipped) { $shippedById[[string] $shippedEntry.id] = $shippedEntry }
    $hipEngine = $shippedById['llama.cpp-hip-b11658']
    $hipRuntime = $shippedById['amd-rocm-gfx1100-10.0.0']
    Check ($null -ne $hipEngine -and $null -ne $hipRuntime) 'the shipped file lists the HIP engine and the AMD ROCm 10.0 runtime'
    $hipChain = @(Get-FastLlmComponentChain -Components $shipped -Id 'llama.cpp-hip-b11658')
    Check ((($hipChain | ForEach-Object { $_.id }) -join ',') -ceq 'amd-rocm-gfx1100-10.0.0,llama.cpp-hip-b11658') 'the shipped HIP engine chain is runtime then engine'
    Check (@(Get-FastLlmComponentChain -Components $shipped -Id 'llama.cpp-b10698-vulkan').Count -eq 1) 'the shipped Vulkan engine has a chain of one'
    $hipEngineSources = @(Get-FastLlmComponentSources -Component $hipEngine)
    $hipRuntimeSources = @(Get-FastLlmComponentSources -Component $hipRuntime)
    Check ($hipEngineSources.Count -eq 1 -and $hipEngineSources[0].format -ceq 'zip' -and @($hipEngineSources[0].fileManifest).Count -eq 55) 'the shipped HIP engine is one flat zip of 55 files'
    Check ($hipRuntimeSources.Count -eq 2 -and @($hipRuntimeSources[0].fileManifest).Count -eq 16 -and @($hipRuntimeSources[1].fileManifest).Count -eq 252 -and $hipRuntimeSources[0].extractPrefix -ceq '_rocm_sdk_libraries/' -and $hipRuntimeSources[1].extractPrefix -ceq '_rocm_sdk_libraries/') 'the shipped runtime is two zip-tree parts of 16 and 252 files'
    Check ((@($hipRuntime.runtimePathDirs) -join ',') -ceq 'bin' -and $hipRuntime.kind -ceq 'runtime') 'the shipped runtime declares runtimePathDirs bin'
    Check ($hipEngine.license.consent -ceq 'accept' -and $hipRuntime.license.consent -ceq 'accept' -and @($hipEngine.license.links).Count -eq 3 -and @($hipRuntime.license.links).Count -eq 2) 'both shipped HIP components need an accept and carry their license links'
    $runtimeAsset = & $module { param($c) Get-FastLlmComponentManifestAsset -Component $c } $hipRuntime
    $runtimePartSum = [int64] 0
    foreach ($runtimePart in $hipRuntimeSources) { foreach ($runtimeFile in @($runtimePart.fileManifest)) { $runtimePartSum += [int64] $runtimeFile.sizeBytes } }
    Check (@($runtimeAsset.manifest).Count -eq 268 -and @($runtimeAsset.manifest).Count -eq (@($hipRuntimeSources[0].fileManifest).Count + @($hipRuntimeSources[1].fileManifest).Count) -and $runtimeAsset.expandedSizeBytes -eq $runtimePartSum) 'Get-FastLlmComponentManifestAsset unions the manifests of all parts (268 files, summed size)'
    Check ($hipEngine.entryPoint -ceq 'llama-server.exe' -and @($hipEngineSources[0].fileManifest | Where-Object { $_.path -ceq 'llama-server.exe' }).Count -eq 1 -and [string] $hipEngine.platform.backend -ceq 'hip' -and @($hipEngine.requires) -ccontains 'amd-rocm-gfx1100-10.0.0') 'the shipped HIP engine names llama-server.exe in its manifest, backend hip and requires the runtime'

    # ---- Happy install (consent: show) ----
    $fx = New-Fixture -Dir (Join-Path $work 'fx-happy')
    $installRoot = New-TestRoot
    $counter = @{ count = 0 }
    $root = Install-Fixture -Fixture $fx -InstallRoot $installRoot -Counter $counter -AcceptLicense -Unattended
    $component = @(Get-FastLlmComponents -ComponentsPath $fx.ComponentsPath)[0]
    Check ((Test-Path -LiteralPath (Join-Path $root 'server.exe')) -and (Test-Path -LiteralPath (Join-Path $root 'engine.dll'))) 'happy install: the files land in the component root'
    Check (Test-FastLlmComponentInstallation -InstallRoot $installRoot -Component $component) 'happy install: the installed root verifies against the manifest'
    $expectedCache = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($installRoot, 'downloads', 'components', 'test-engine-1', 'v1', 'test-engine-1-v1.zip'))
    Check ([string] $counter.destination -ceq $expectedCache) 'the component download is cached at downloads\components\<id>\<version>\<file>, never the shared downloads\<file>'
    Check ($counter.count -eq 1 -and $counter.url -eq 'https://example.com/downloads/test-engine-1-v1.zip') 'happy install: one download of the pinned URL'
    Check ((@($counter.hosts) -join ',') -eq 'example.com,cdn.example.com') 'happy install: the download receives the component allowedRedirectHosts'
    Check (-not (Test-Path -LiteralPath (Join-Path $installRoot 'consents'))) 'consent show: no receipt is written'
    Check (@(Get-ChildItem -LiteralPath (Split-Path -Parent $root) -Force | Where-Object { $_.Name -like '*.staging.*' }).Count -eq 0) 'happy install: no staging folder is left behind'

    # ---- Inventory ----
    $inventory = @(Get-FastLlmComponentInventory -ComponentsPath $fx.ComponentsPath -InstallRoot $installRoot)
    $expectedBytes = [int64] 0
    foreach ($name in @('server.exe', 'engine.dll')) { $expectedBytes += (Get-Item -LiteralPath (Join-Path $root $name)).Length }
    Check ($inventory.Count -eq 1 -and $inventory[0].id -eq 'test-engine-1' -and $inventory[0].kind -eq 'engine' -and $inventory[0].version -eq 'v1') 'inventory: id, kind and version are reported'
    Check ($inventory[0].installed -and $inventory[0].verified -and $inventory[0].bytes -eq $expectedBytes -and $expectedBytes -gt 0) 'inventory: bytes total the files under the root and the row is verified'
    $emptyRoot = New-TestRoot
    $emptyInventory = @(Get-FastLlmComponentInventory -ComponentsPath $fx.ComponentsPath -InstallRoot $emptyRoot)
    Check (-not $emptyInventory[0].installed -and -not $emptyInventory[0].verified -and $emptyInventory[0].bytes -eq 0) 'inventory: a component that is not installed reports 0 bytes and not verified'

    # ---- Good existing root: no-op ----
    $before = Get-HexSha (Join-Path $root 'server.exe')
    $counter2 = @{ count = 0 }
    $again = Install-Fixture -Fixture $fx -InstallRoot $installRoot -Counter $counter2 -AcceptLicense -Unattended
    Check ($again -eq $root -and $counter2.count -eq 0 -and (Get-HexSha (Join-Path $root 'server.exe')) -eq $before) 'an existing good root is a no-op: no download, nothing changed'

    # ---- Tampered or partial existing root: refused, unchanged (Review Focus 2) ----
    [System.IO.File]::WriteAllBytes((Join-Path $root 'server.exe'), [System.Text.Encoding]::ASCII.GetBytes('tampered'))
    $tamperedHash = Get-HexSha (Join-Path $root 'server.exe')
    $counter3 = @{ count = 0 }
    $msg = Get-ThrownMessage { Install-Fixture -Fixture $fx -InstallRoot $installRoot -Counter $counter3 -AcceptLicense -Unattended }
    Check ($null -ne $msg -and $msg -like '*remove it first*') 'a tampered root is refused with a remove-it-first message'
    Check ($counter3.count -eq 0 -and (Get-HexSha (Join-Path $root 'server.exe')) -eq $tamperedHash -and (Test-Path -LiteralPath (Join-Path $root 'engine.dll'))) 'a tampered root is left exactly as it was and nothing was downloaded'
    Check (-not (Test-FastLlmComponentInstallation -InstallRoot $installRoot -Component $component)) 'a tampered root does not verify'
    $inventoryTampered = @(Get-FastLlmComponentInventory -ComponentsPath $fx.ComponentsPath -InstallRoot $installRoot)
    Check ($inventoryTampered[0].installed -and -not $inventoryTampered[0].verified) 'inventory: a tampered root is installed but not verified'
    Remove-Item -LiteralPath (Join-Path $root 'engine.dll') -Force
    $msg = Get-ThrownMessage { Install-Fixture -Fixture $fx -InstallRoot $installRoot -Counter $counter3 -AcceptLicense -Unattended }
    Check ($null -ne $msg -and $msg -like '*remove it first*' -and -not (Test-Path -LiteralPath (Join-Path $root 'engine.dll'))) 'a partly written root is refused and not completed in place'

    # ---- Unattended without -AcceptLicense ----
    $fxUn = New-Fixture -Dir (Join-Path $work 'fx-unattended')
    $unRoot = New-TestRoot
    $counterUn = @{ count = 0 }
    $msg = Get-ThrownMessage { Install-Fixture -Fixture $fxUn -InstallRoot $unRoot -Counter $counterUn -Unattended }
    Check ($null -ne $msg -and $msg -like '*-AcceptLicense*') 'unattended without -AcceptLicense is refused'
    Check ($counterUn.count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $unRoot 'components')) -and -not (Test-Path -LiteralPath (Join-Path $unRoot 'downloads'))) 'unattended refusal downloads nothing and creates nothing'

    # ---- consent: accept writes a receipt ----
    $fxAcc = New-Fixture -Dir (Join-Path $work 'fx-accept') -Consent 'accept'
    $accRoot = New-TestRoot
    $counterAcc = @{ count = 0 }
    $msg = Get-ThrownMessage { Install-Fixture -Fixture $fxAcc -InstallRoot $accRoot -Counter $counterAcc }
    Check ($null -ne $msg -and $msg -like '*-AcceptLicense*' -and $counterAcc.count -eq 0) 'consent accept without -AcceptLicense is refused before any download'
    Check ($msg -like '*fast-llm.ps1 components -Install test-engine-1 -AcceptLicense*') 'the accept refusal points at fast-llm.ps1 components -Install <id> -AcceptLicense'
    $accEntry = @(Get-FastLlmComponents -ComponentsPath $fxAcc.ComponentsPath)[0]
    $accRootPath = Install-Fixture -Fixture $fxAcc -InstallRoot $accRoot -Counter $counterAcc -AcceptLicense
    $receiptPath = Join-Path (Join-Path $accRoot 'consents') 'component-test-engine-1-v1.json'
    Check (Test-Path -LiteralPath $receiptPath -PathType Leaf) 'consent accept writes consents\component-<id>-<version>.json'
    $accShownRoot = New-TestRoot
    $accShown = @(Install-Fixture -Fixture $fxAcc -InstallRoot $accShownRoot -Counter @{ count = 0 } -AcceptLicense 6>&1 | ForEach-Object { [string] $_ })
    Check (@($accShown | Where-Object { $_ -ceq 'Component:  Test engine v1 v1' }).Count -eq 1 -and @($accShown | Where-Object { $_ -ceq 'License:    MIT (https://example.com/LICENSE)' }).Count -eq 1) 'an accept-type install with -AcceptLicense prints the Component: and License: lines'
    $installSource = [regex]::Match($moduleSourceEarly, '(?s)function Install-FastLlmComponent \{.*?\r?\n\}\r?\n').Value
    Check ($installSource.IndexOf('Write-Host "Component:') -ge 0 -and $installSource.IndexOf('Write-Host "Component:') -lt $installSource.IndexOf('Write-FastLlmComponentConsentReceipt -Component')) 'the license lines are printed before the consent receipt is written'
    $receiptText = Get-Content -LiteralPath $receiptPath -Raw
    $receipt = $receiptText | ConvertFrom-Json
    Check ([int] $receipt.schemaVersion -eq 1 -and $receipt.id -ceq 'test-engine-1' -and $receipt.version -ceq 'v1' -and $receipt.licenseUrl -ceq 'https://example.com/LICENSE' -and $receipt.mode -ceq 'explicit-switch' -and $receiptText -match '"acceptedAt"\s*:\s*"\d{4}-\d\d-\d\dT') 'the receipt carries schemaVersion, id, version, license url, acceptedAt and mode'
    Check (Test-Path -LiteralPath (Join-Path $accRootPath 'server.exe')) 'consent accept with -AcceptLicense installs the component'

    # ---- Hash mismatch: refused, nothing created (Review Focus 1) ----
    $fxPin = New-Fixture -Dir (Join-Path $work 'fx-pin') -Salt 'pinned'
    $fxOther = New-Fixture -Dir (Join-Path $work 'fx-other') -Salt 'different-bytes-here'
    $badRoot = New-TestRoot
    $counterBad = @{ count = 0 }
    $wrongSeam = New-CopySeam -Zip $fxOther.Zip -Counter $counterBad
    $msg = Get-ThrownMessage { Install-FastLlmComponent -ComponentsPath $fxPin.ComponentsPath -ComponentId $fxPin.Id -InstallRoot $badRoot -AcceptLicense -Unattended -Download $wrongSeam }
    Check ($null -ne $msg -and $msg -like '*failed its pinned size and SHA-256*') 'a download whose bytes differ from the pins is refused'
    Check (-not (Test-Path -LiteralPath (Join-Path $badRoot 'components'))) 'hash mismatch: no component directory is created'
    $downloadsDir = [System.IO.Path]::Combine($badRoot, 'downloads', 'components', 'test-engine-1', 'v1')
    Check (@(Get-ChildItem -LiteralPath $downloadsDir -Force | Where-Object { $_.Name -like '*.corrupt.*' }).Count -eq 1 -and @(Get-ChildItem -LiteralPath $downloadsDir -Force | Where-Object { $_.Name -eq 'test-engine-1-v1.zip' }).Count -eq 0) 'hash mismatch: the bad download is quarantined, not left in place'
    Check (@(Get-ChildItem -LiteralPath (Join-Path $badRoot 'downloads') -Force -File).Count -eq 0) 'hash mismatch: nothing is written to the shared downloads folder'

    # ---- Extra file in the archive: refused ----
    $fxExtra = New-Fixture -Dir (Join-Path $work 'fx-extra') -ExtraFile
    $extraRoot = New-TestRoot
    $counterExtra = @{ count = 0 }
    $msg = Get-ThrownMessage { Install-Fixture -Fixture $fxExtra -InstallRoot $extraRoot -Counter $counterExtra -AcceptLicense -Unattended }
    Check ($null -ne $msg -and $msg -like '*does not match its pinned file list*') 'an archive with an extra file is refused'
    Check (-not (Test-Path -LiteralPath (Join-Path $extraRoot 'components'))) 'extra file: no component directory is created'

    # ---- Redirect to an unlisted host: refused and quarantined (Review Focus 1) ----
    $partialDir = New-TestRoot
    $partial = Join-Path $partialDir 'file.zip.0123456789abcdef.partial'
    [System.IO.File]::WriteAllBytes($partial, [byte[]] @(1, 2, 3))
    $hostsAllowed = [string[]] @('github.com', 'objects.githubusercontent.com')
    & $module { param($P, $H) Assert-FastLlmDownloadHost -EffectiveUrl 'https://objects.githubusercontent.com/a/b.zip?x=1' -AllowedHosts $H -Partial $P -CurlExitCode 0 } $partial $hostsAllowed
    Check (Test-Path -LiteralPath $partial) 'a final URL on a listed host leaves the partial alone'
    & $module { param($P, $H) Assert-FastLlmDownloadHost -EffectiveUrl 'https://GitHub.com/a.zip' -AllowedHosts $H -Partial $P -CurlExitCode 0 } $partial $hostsAllowed
    Check (Test-Path -LiteralPath $partial) 'the host match ignores case'
    $msg = Get-ThrownMessage { & $module { param($P, $H) Assert-FastLlmDownloadHost -EffectiveUrl 'https://evil.example.net/payload.zip' -AllowedHosts $H -Partial $P -CurlExitCode 0 } $partial $hostsAllowed }
    Check ($msg -ceq 'Download redirected to an unlisted host: evil.example.net') 'a final URL on an unlisted host throws the exact message'
    Check (-not (Test-Path -LiteralPath $partial) -and @(Get-ChildItem -LiteralPath $partialDir -Force | Where-Object { $_.Name -like 'file.zip.0123456789abcdef.partial.corrupt.*' }).Count -eq 1) 'an unlisted redirect quarantines the partial'
    [System.IO.File]::WriteAllBytes($partial, [byte[]] @(1, 2, 3))
    $msg = Get-ThrownMessage { & $module { param($P, $H) Assert-FastLlmDownloadHost -EffectiveUrl 'http://github.com/a.zip' -AllowedHosts $H -Partial $P -CurlExitCode 0 } $partial $hostsAllowed }
    Check ($null -ne $msg -and $msg -like 'Download redirected to an unlisted host:*') 'a non-HTTPS final URL is refused even on a listed host'
    [System.IO.File]::WriteAllBytes($partial, [byte[]] @(1, 2, 3))
    $msg = Get-ThrownMessage { & $module { param($P, $H) Assert-FastLlmDownloadHost -EffectiveUrl '' -AllowedHosts $H -Partial $P -CurlExitCode 0 } $partial $hostsAllowed }
    Check ($null -ne $msg -and $msg -like 'Download redirected to an unlisted host:*') 'no reported final URL after a clean curl exit is refused'
    $msg = Get-ThrownMessage { Save-FastLlmVerifiedFile -Url 'https://example.com/a.zip' -Destination (Join-Path $partialDir 'a.zip') -Sha256 ('0' * 64) -SizeBytes 10 -AllowedRedirectHosts @() }
    Check ($null -ne $msg -and $msg -like '*Allowed redirect hosts must not be empty*') 'Save-FastLlmVerifiedFile refuses an empty -AllowedRedirectHosts list'

    # End to end through the seam: a download that fails on a redirect creates nothing.
    $redirectRoot = New-TestRoot
    $redirectSeam = { param($Url, $Destination, $Sha256, $SizeBytes, $AllowedRedirectHosts) throw 'Download redirected to an unlisted host: evil.example.net' }
    $msg = Get-ThrownMessage { Install-FastLlmComponent -ComponentsPath $fxPin.ComponentsPath -ComponentId $fxPin.Id -InstallRoot $redirectRoot -AcceptLicense -Unattended -Download $redirectSeam }
    Check ($msg -like '*unlisted host*' -and -not (Test-Path -LiteralPath (Join-Path $redirectRoot 'components'))) 'install through a redirecting download is refused and creates no component directory'

    # ---- Save-FastLlmVerifiedFile: curl arguments are unchanged without -AllowedRedirectHosts, and --disable is always first ----
    $moduleSource = Get-Content -LiteralPath $modulePath -Raw
    $curlPlain = @(& $module { Get-FastLlmCurlArguments -Url 'https://example.test/f.zip' -Partial 'C:\d\f.zip.partial' -SizeBytes 1234 })
    $curlChecked = @(& $module { Get-FastLlmCurlArguments -Url 'https://example.test/f.zip' -Partial 'C:\d\f.zip.partial' -SizeBytes 1234 -WriteEffectiveUrl })
    $curlExpected = @('--disable', '--silent', '--show-error', '--location', '--fail', '--retry', '3', '--connect-timeout', '30', '--speed-limit', '1024',
        '--speed-time', '60', '--max-filesize', '1234', '--proto', '=https', '--proto-redir', '=https', '--continue-at', '-',
        '--output', 'C:\d\f.zip.partial', 'https://example.test/f.zip')
    Check (($curlPlain -join "`n") -ceq ($curlExpected -join "`n")) 'the curl arguments without -WriteEffectiveUrl are exactly what they were before -AllowedRedirectHosts'
    Check ($curlPlain[0] -ceq '--disable' -and $curlChecked[0] -ceq '--disable') 'curl --disable is the first argument with and without -WriteEffectiveUrl'
    Check ($curlChecked.Count -eq $curlPlain.Count + 2 -and $curlChecked[1] -ceq '--write-out' -and $curlChecked[2] -ceq '%{url_effective}') '-WriteEffectiveUrl adds exactly --write-out %{url_effective}'
    $curlWithoutWriteOut = @($curlChecked[0]) + @($curlChecked[3..($curlChecked.Count - 1)])
    Check (($curlWithoutWriteOut -join "`n") -ceq ($curlPlain -join "`n")) 'the only difference with -WriteEffectiveUrl is the two --write-out elements'
    Check ($moduleSource -cmatch '\$checkRedirectHosts = \$PSBoundParameters\.ContainsKey\(''AllowedRedirectHosts''\)') 'the redirect check is keyed on the parameter being bound'
    Check ($moduleSource -cmatch 'Get-FastLlmCurlArguments -Url \$Url -Partial \$partial -SizeBytes \$SizeBytes -WriteEffectiveUrl:\$checkRedirectHosts') 'the curl arguments are built by the helper, with the write-out switch keyed on the redirect check'
    Check ($moduleSource -cmatch 'Assert-FastLlmDownloadHost -EffectiveUrl \$effectiveUrl') 'Save-FastLlmVerifiedFile still checks the effective URL host after curl'

    # ---- Signer subject matching ----
    Check (& $module { Test-FastLlmSignerSubject -Subject 'CN=Vendor Inc, O=Vendor Inc, C=US' -Signer 'Vendor Inc' }) 'signer: the subject CN matches'
    Check (-not (& $module { Test-FastLlmSignerSubject -Subject 'CN=Other Inc, O=Vendor Inc, C=US' -Signer 'Vendor Inc' })) 'signer: an organization match without the CN is not enough'
    Check (-not (& $module { Test-FastLlmSignerSubject -Subject $null -Signer 'Vendor Inc' })) 'signer: no subject does not match'

    # ---- Remove: refused while a server may be using it (Review Focus 5) ----
    $fxRun = New-Fixture -Dir (Join-Path $work 'fx-run')
    $runRoot = New-TestRoot
    $counterRun = @{ count = 0 }
    $runComponentRoot = Install-Fixture -Fixture $fxRun -InstallRoot $runRoot -Counter $counterRun -AcceptLicense -Unattended
    $lock = Enter-FastLlmOperation -InstallRoot $runRoot
    try {
        Write-FastLlmState -InstallRoot $runRoot -State ([ordered] @{ schemaVersion = 1; runId = ('a' * 32); phase = 'ready'; enginePath = (Join-Path $runComponentRoot 'server.exe') })
        $msg = Get-ThrownMessage { Remove-FastLlmComponent -ComponentsPath $fxRun.ComponentsPath -ComponentId $fxRun.Id -InstallRoot $runRoot }
        Check ($null -ne $msg -and $msg -like '*Stop FastLLM first*') 'remove while the active server runs this component is refused with "stop FastLLM first"'
        Check ((Test-Path -LiteralPath (Join-Path $runComponentRoot 'server.exe')) -and (Test-Path -LiteralPath (Join-Path $runComponentRoot 'engine.dll'))) 'remove while active: nothing was deleted'

        Write-FastLlmState -InstallRoot $runRoot -State ([ordered] @{ schemaVersion = 1; runId = ('a' * 32); phase = 'ready'; processIdentity = $null })
        $msg = Get-ThrownMessage { Remove-FastLlmComponent -ComponentsPath $fxRun.ComponentsPath -ComponentId $fxRun.Id -InstallRoot $runRoot }
        Check ($null -ne $msg -and $msg -like '*Stop FastLLM first*' -and (Test-Path -LiteralPath (Join-Path $runComponentRoot 'server.exe'))) 'remove while a server runs and records no engine path is refused (cannot prove it is elsewhere)'

        $otherEngine = Join-Path (Join-Path $runRoot 'engines') 'b1\vulkan\llama-server.exe'
        Write-FastLlmState -InstallRoot $runRoot -State ([ordered] @{ schemaVersion = 1; runId = ('a' * 32); phase = 'ready'; enginePath = $otherEngine })
        $lookalike = $runComponentRoot + '-other\server.exe'
        $removedLookalike = & $module { param($R, $C) Test-FastLlmComponentInUse -InstallRoot $R -ComponentRoot $C } $runRoot $runComponentRoot
        Check (-not $removedLookalike) 'an active server on a different engine path does not block removal'
        Write-FastLlmState -InstallRoot $runRoot -State ([ordered] @{ schemaVersion = 1; runId = ('a' * 32); phase = 'ready'; enginePath = $lookalike })
        $inUseLookalike = & $module { param($R, $C) Test-FastLlmComponentInUse -InstallRoot $R -ComponentRoot $C } $runRoot $runComponentRoot
        Check (-not $inUseLookalike) 'a sibling folder that merely shares the root name prefix is not treated as the component root'
    }
    finally {
        $lock.Dispose()
    }
    Write-FastLlmState -InstallRoot $runRoot -State ([ordered] @{ schemaVersion = 1; runId = ('a' * 32); phase = 'stopped' })
    $removedWhileStopped = Remove-FastLlmComponent -ComponentsPath $fxRun.ComponentsPath -ComponentId $fxRun.Id -InstallRoot $runRoot
    Check ($removedWhileStopped -and -not (Test-Path -LiteralPath $runComponentRoot)) 'remove succeeds once the server is stopped'

    # ---- Remove: only that exact root is deleted ----
    $fxV1 = New-Fixture -Dir (Join-Path $work 'fx-v1') -Id 'multi-engine' -Version 'v1' -Consent 'accept'
    $fxV2 = New-Fixture -Dir (Join-Path $work 'fx-v2') -Id 'multi-engine' -Version 'v2'
    $fxSib = New-Fixture -Dir (Join-Path $work 'fx-sib') -Id 'sibling-engine' -Version 'v1'
    $multiRoot = New-TestRoot
    $multiCounter = @{ count = 0 }
    $rootV1 = Install-Fixture -Fixture $fxV1 -InstallRoot $multiRoot -Counter $multiCounter -AcceptLicense
    $rootV2 = Install-Fixture -Fixture $fxV2 -InstallRoot $multiRoot -Counter $multiCounter -AcceptLicense -Unattended
    $rootSib = Install-Fixture -Fixture $fxSib -InstallRoot $multiRoot -Counter $multiCounter -AcceptLicense -Unattended
    Check (($rootV1 -ne $rootV2) -and ((Split-Path -Parent $rootV1) -eq (Split-Path -Parent $rootV2))) 'two versions of one component install side by side'
    $strayFile = Join-Path (Join-Path $multiRoot 'components') 'keep.txt'
    [System.IO.File]::WriteAllText($strayFile, 'keep')
    $modelFile = Join-Path (Join-Path $multiRoot 'models') 'keep.gguf'
    New-Item -ItemType Directory -Path (Split-Path -Parent $modelFile) -Force | Out-Null
    [System.IO.File]::WriteAllText($modelFile, 'keep')
    $receiptV1 = Join-Path (Join-Path $multiRoot 'consents') 'component-multi-engine-v1.json'
    Check (Test-Path -LiteralPath $receiptV1) 'the v1 consent receipt exists before removal'
    $null = Remove-FastLlmComponent -ComponentsPath $fxV1.ComponentsPath -ComponentId $fxV1.Id -InstallRoot $multiRoot
    Check (-not (Test-Path -LiteralPath $rootV1)) 'remove deletes the exact version root'
    Check ((Test-Path -LiteralPath (Join-Path $rootV2 'server.exe')) -and (Test-Path -LiteralPath (Join-Path $rootSib 'server.exe'))) 'remove leaves the other version and the sibling component alone'
    Check ((Test-Path -LiteralPath $strayFile) -and (Test-Path -LiteralPath $modelFile) -and (Test-Path -LiteralPath (Join-Path $multiRoot 'downloads'))) 'remove leaves unrelated files and folders alone'
    Check (-not (Test-Path -LiteralPath $receiptV1)) 'remove deletes the consent receipt'
    Check (Test-FastLlmComponentInstallation -InstallRoot $multiRoot -Component (@(Get-FastLlmComponents -ComponentsPath $fxV2.ComponentsPath)[0])) 'the remaining version still verifies after the other was removed'
    $null = Remove-FastLlmComponent -ComponentsPath $fxV2.ComponentsPath -ComponentId $fxV2.Id -InstallRoot $multiRoot
    Check (-not (Test-Path -LiteralPath (Split-Path -Parent $rootV2))) 'empty parent folders are removed up the tree'
    Check ((Test-Path -LiteralPath (Join-Path $multiRoot 'components') -PathType Container) -and (Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $multiRoot 'components') 'engine') 'sibling-engine') -PathType Container)) 'the components folder and non-empty parents stay'
    $absent = Remove-FastLlmComponent -ComponentsPath $fxV2.ComponentsPath -ComponentId $fxV2.Id -InstallRoot $multiRoot
    Check (-not $absent) 'removing a component that is not installed deletes nothing and reports false'
    $msg = Get-ThrownMessage { Remove-FastLlmComponent -ComponentsPath $fxV2.ComponentsPath -ComponentId 'not-listed' -InstallRoot $multiRoot }
    Check ($null -ne $msg -and $msg -like '*not in the signed components list*') 'removing an id that is not in components.json is refused'

    # ---- Remove: a status.json that records engineExecutable (Task 3) ----
    $fxExeA = New-Fixture -Dir (Join-Path $work 'fx-exe-a') -Id 'exe-engine-a'
    $fxExeB = New-Fixture -Dir (Join-Path $work 'fx-exe-b') -Id 'exe-engine-b'
    $exeRoot = New-TestRoot
    $exeCounter = @{ count = 0 }
    $exeRootA = Install-Fixture -Fixture $fxExeA -InstallRoot $exeRoot -Counter $exeCounter -AcceptLicense -Unattended
    $exeRootB = Install-Fixture -Fixture $fxExeB -InstallRoot $exeRoot -Counter $exeCounter -AcceptLicense -Unattended
    $exeLock = Enter-FastLlmOperation -InstallRoot $exeRoot
    try {
        $builtInRunning = Join-Path (Join-Path $exeRoot 'engines') 'b10698\vulkan\llama-server.exe'
        Write-FastLlmState -InstallRoot $exeRoot -State ([ordered] @{ schemaVersion = 1; runId = ('b' * 32); phase = 'ready'; engineExecutable = $builtInRunning; engineComponentId = 'llama.cpp-b10698-vulkan' })
        $removedWhileOther = Remove-FastLlmComponent -ComponentsPath $fxExeA.ComponentsPath -ComponentId $fxExeA.Id -InstallRoot $exeRoot
        Check ($removedWhileOther -and -not (Test-Path -LiteralPath $exeRootA)) 'a component NOT in use is removed while the built-in engine runs'
        Write-FastLlmState -InstallRoot $exeRoot -State ([ordered] @{ schemaVersion = 1; runId = ('b' * 32); phase = 'ready'; engineExecutable = (Join-Path $exeRootB 'server.exe'); engineComponentId = $fxExeB.Id })
        $removedOther = Remove-FastLlmComponent -ComponentsPath $fxExeA.ComponentsPath -ComponentId $fxExeA.Id -InstallRoot $exeRoot
        Check (-not $removedOther -and (Test-Path -LiteralPath (Join-Path $exeRootB 'server.exe'))) 'removal of a component NOT in use succeeds (nothing to delete here) while a different component engine runs'
        $msg = Get-ThrownMessage { Remove-FastLlmComponent -ComponentsPath $fxExeB.ComponentsPath -ComponentId $fxExeB.Id -InstallRoot $exeRoot }
        Check ($null -ne $msg -and $msg -like '*Stop FastLLM first*' -and (Test-Path -LiteralPath (Join-Path $exeRootB 'server.exe'))) 'a component recorded as the running engineExecutable cannot be removed'
    }
    finally {
        $exeLock.Dispose()
    }

    # ---- Resolve-FastLlmRecipeEngine (module-internal) ----
    $resolveCatalog = [pscustomobject] @{ engine = [pscustomobject] @{ version = 'b10698'; assets = [pscustomobject] @{ vulkan = [pscustomobject] @{ entryPoint = 'llama-server.exe' } } } }
    $resolveRecipe = [pscustomobject] @{ id = 'rr'; components = [pscustomobject] @{ engine = 'llama.cpp-b10698-vulkan'; model = 'm' } }
    $resolveRoot = New-TestRoot
    $builtInFolder = Join-Path $resolveRoot 'engines\b10698\vulkan'
    New-Item -ItemType Directory -Path $builtInFolder -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $builtInFolder 'llama-server.exe'), 'x')
    # A component list that ALSO lists the built-in id (the shipped components.json does): the built-in path must still win and components.json is not consulted.
    $fxShadow = New-Fixture -Dir (Join-Path $work 'fx-shadow') -Id 'llama.cpp-b10698-vulkan' -Version 'bX'
    $shadowList = @(Get-FastLlmComponents -ComponentsPath $fxShadow.ComponentsPath)
    $resolvedBuiltIn = & $module { param($R, $C, $L, $I) Resolve-FastLlmRecipeEngine -Recipe $R -Catalog $C -Components $L -InstallRoot $I } $resolveRecipe $resolveCatalog $shadowList $resolveRoot
    $expectedBuiltIn = Get-FastLlmEngineExecutable -InstallRoot $resolveRoot -EngineVersion 'b10698' -BackendKey 'vulkan' -EntryPoint 'llama-server.exe'
    Check ($resolvedBuiltIn.builtIn -and $resolvedBuiltIn.installed -and $resolvedBuiltIn.executable -ceq $expectedBuiltIn -and $resolvedBuiltIn.version -ceq 'b10698' -and $resolvedBuiltIn.id -ceq 'llama.cpp-b10698-vulkan') 'the built-in id resolves to the existing engines\<version>\vulkan executable, builtIn true, even when components.json also lists that id'
    Check (-not $resolvedBuiltIn.executable.StartsWith((Join-Path $resolveRoot 'components'), [System.StringComparison]::OrdinalIgnoreCase)) 'the built-in id never resolves into the components folder'
    $resolvedBuiltInEmpty = & $module { param($R, $C, $I) Resolve-FastLlmRecipeEngine -Recipe $R -Catalog $C -Components @() -InstallRoot $I } $resolveRecipe $resolveCatalog (New-TestRoot)
    Check ($resolvedBuiltInEmpty.builtIn -and -not $resolvedBuiltInEmpty.installed -and $null -eq $resolvedBuiltInEmpty.executable) 'the built-in id on a root without the engine resolves as not installed, without consulting any component'

    $fxEngine = New-Fixture -Dir (Join-Path $work 'fx-engine') -Id 'test-engine-1' -Version 'v1'
    $engineList = @(Get-FastLlmComponents -ComponentsPath $fxEngine.ComponentsPath)
    $engineRecipe = [pscustomobject] @{ id = 'rc'; components = [pscustomobject] @{ engine = 'test-engine-1'; model = 'm' } }
    $engineRoot = New-TestRoot
    $notInstalled = & $module { param($R, $C, $L, $I) Resolve-FastLlmRecipeEngine -Recipe $R -Catalog $C -Components $L -InstallRoot $I } $engineRecipe $resolveCatalog $engineList $engineRoot
    $expectedRoot = Join-Path (Join-Path (Join-Path (Join-Path $engineRoot 'components') 'engine') 'test-engine-1') 'v1'
    Check (-not $notInstalled.builtIn -and -not $notInstalled.installed -and $notInstalled.executable -ceq (Join-Path $expectedRoot 'server.exe') -and $notInstalled.version -ceq 'v1' -and $notInstalled.backend -ceq 'vulkan') 'a component engine resolves to components\engine\<id>\<version>\<entryPoint> and is reported not installed before the install'
    $engineCounter = @{ count = 0 }
    $installedRoot = Install-Fixture -Fixture $fxEngine -InstallRoot $engineRoot -Counter $engineCounter -AcceptLicense -Unattended
    $installed = & $module { param($R, $C, $L, $I) Resolve-FastLlmRecipeEngine -Recipe $R -Catalog $C -Components $L -InstallRoot $I } $engineRecipe $resolveCatalog $engineList $engineRoot
    Check ($installed.installed -and -not $installed.builtIn -and $installed.executable -ceq (Join-Path $installedRoot 'server.exe')) 'an installed component engine resolves as installed, at its component root'
    [System.IO.File]::WriteAllText((Join-Path $installedRoot 'extra.txt'), 'not in the pinned file list')
    $tampered = & $module { param($R, $C, $L, $I) Resolve-FastLlmRecipeEngine -Recipe $R -Catalog $C -Components $L -InstallRoot $I } $engineRecipe $resolveCatalog $engineList $engineRoot
    Check (-not $tampered.installed) 'a component engine whose folder no longer matches its pinned file list resolves as not installed'
    $unknownRecipe = [pscustomobject] @{ id = 'ru'; components = [pscustomobject] @{ engine = 'no-such-engine'; model = 'm' } }
    $unknownFailure = $null
    try { & $module { param($R, $C, $L, $I) Resolve-FastLlmRecipeEngine -Recipe $R -Catalog $C -Components $L -InstallRoot $I } $unknownRecipe $resolveCatalog $engineList $engineRoot | Out-Null } catch { $unknownFailure = $_.Exception }
    Check ($null -ne $unknownFailure -and $unknownFailure.Data['FastLlmFailureCode'] -ceq 'recipe-engine-component-unknown') 'an unknown engine id is a typed error'

    # ---- Get-FastLlmPlan: shipped recipes keep exactly the plan they always had; a component recipe plans on its component ----
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $shippedCatalogPath = Join-Path (Join-Path $repoRoot 'config') 'catalog.json'
    $shippedRecipesPath = Join-Path (Join-Path $repoRoot 'config') 'recipes.json'
    $shippedVariantsPath = Join-Path (Join-Path $repoRoot 'config') 'gpu-variants.json'
    $fixtureDir = Join-Path $PSScriptRoot 'fixtures'
    $planRoot = New-TestRoot
    $xtxHardware = Read-FastLlmJson -Path (Join-Path $fixtureDir 'rx-7900-xtx-24gb.json')
    $xtxHardware | Add-Member -NotePropertyName dxgiAdapters -NotePropertyValue @([pscustomobject] @{ vendorId = 4098; deviceId = 29772; revision = 200; dedicatedVideoMiB = 24534 })
    $xtHardware = Read-FastLlmJson -Path (Join-Path $fixtureDir 'rx-7900-xt-20gb.json')
    $xtHardware | Add-Member -NotePropertyName dxgiAdapters -NotePropertyValue @([pscustomobject] @{ vendorId = 4098; deviceId = 29772; revision = 204; dedicatedVideoMiB = 20464 })
    # Recorded expectation: the engine path and the full argument list the plan produced before engine components existed (MODEL is the verified model path).
    $commonTail = @('--host', '127.0.0.1', '--port', '8080', '--cors-origins', 'localhost', '--no-cors-credentials')
    $expectedXtx = @('--model', 'MODEL', '--offline', '--no-mmproj', '--spec-type', 'none', '--alias', 'qwen3.8-27b-ud-q4-k-m') + $commonTail + @(
        '--ctx-size', '32768', '--parallel', '1', '--n-gpu-layers', 'all', '--fit', 'on', '--fit-target', '768', '--device', 'Vulkan0', '--split-mode', 'none',
        '--flash-attn', 'auto', '--cache-type-k', 'f16', '--cache-type-v', 'f16', '--jinja', '--metrics', '--log-verbosity', '4', '--no-agent', '--no-ui')
    $expectedXt = @('--model', 'MODEL', '--offline', '--no-mmproj', '--spec-type', 'none', '--alias', 'qwen3.8-27b-ud-iq4-xs') + $commonTail + @(
        '--ctx-size', '16384', '--parallel', '1', '--n-gpu-layers', 'all', '--fit', 'on', '--fit-target', '512', '--device', 'ROCm0', '--split-mode', 'none',
        '--flash-attn', 'auto', '--cache-type-k', 'f16', '--cache-type-v', 'f16', '--jinja', '--metrics', '--log-verbosity', '4', '--no-agent', '--no-ui')
    $expectedFields = 'schemaVersion,catalogVersion,hardwareFingerprint,fingerprintKind,selectionMode,requestedModelId,requestedRecipeId,recovered,requestedContextSize,allowExperimentalModel,catalogContextSize,performanceQualified,candidatePlacementCount,profile,backend,engineVersion,enginePath,capacity,selectedAdapters,model,modelPath,requestedAllGpuLayers,placementVerified,splitMode,tensorSplit,endpoint,serverArguments,recipe,warnings'
    $shippedCases = @(
        @{ Hardware = $xtxHardware; RecipeId = 'rx-7900-xtx.qwen3.8-27b-ud-q4-k-m.32k'; Args = $expectedXtx; EnginePath = 'C:\FastLLM\vulkan\llama-server.exe' },
        @{ Hardware = $xtHardware; RecipeId = 'rx-7900-xt.qwen3.8-27b-ud-iq4-xs.16k'; Args = $expectedXt; EnginePath = 'C:\FastLLM\rocm\llama-server.exe' })
    foreach ($case in $shippedCases) {
        foreach ($recipeMode in @('auto', 'named')) {
            $planParams = @{ Hardware = $case.Hardware; CatalogPath = $shippedCatalogPath; InstallRoot = $planRoot; RecipesPath = $shippedRecipesPath; GpuVariantsPath = $shippedVariantsPath }
            if ($recipeMode -ceq 'named') { $planParams.RecipeId = $case.RecipeId }
            $shippedPlan = Get-FastLlmPlan @planParams
            $expectedModelPath = $shippedPlan.modelPath
            $expectedArguments = @($case.Args | ForEach-Object { if ($_ -ceq 'MODEL') { $expectedModelPath } else { $_ } })
            Check ($shippedPlan.recipe.id -ceq $case.RecipeId -and $shippedPlan.selectionMode -ceq 'recipe') "shipped recipe $($case.RecipeId) is picked ($recipeMode), so the plan check exercises the recipe path"
            Check ($shippedPlan.enginePath -ceq $case.EnginePath -and $shippedPlan.engineVersion -ceq 'b10698') "shipped recipe $($case.RecipeId) ($recipeMode): the plan's executable path is the probed built-in engine path, unchanged"
            Check (($shippedPlan.serverArguments -join [char]31) -ceq ($expectedArguments -join [char]31)) "shipped recipe $($case.RecipeId) ($recipeMode): the full argument list is unchanged"
            Check ($shippedPlan.modelPath -like '*\models\*.gguf' -and $shippedPlan.serverArguments[1] -ceq $shippedPlan.modelPath) "shipped recipe $($case.RecipeId) ($recipeMode): --model is the verified model path"
            Check ((@($shippedPlan.PSObject.Properties.Name) -join ',') -ceq $expectedFields) "shipped recipe $($case.RecipeId) ($recipeMode): the plan has exactly its pre-component fields (no engineComponentId)"
        }
    }

    # A recipe on a listed engine component: planned on that component's executable, never on the built-in engine.
    $fxPlan = New-Fixture -Dir (Join-Path $work 'fx-plan') -Id 'test-engine-1' -Version 'v1'
    Copy-Item -LiteralPath $shippedCatalogPath -Destination (Join-Path $fxPlan.Dir 'catalog.json') -Force
    $planCatalogPath = Join-Path $fxPlan.Dir 'catalog.json'
    $componentRecipeDocument = Get-Content -LiteralPath $shippedRecipesPath -Raw | ConvertFrom-Json
    $componentRecipeEntry = @($componentRecipeDocument.recipes | Where-Object { $_.id -ceq 'rx-7900-xtx.qwen3.8-27b-ud-q4-k-m.32k' })[0]
    $componentRecipeEntry.id = 'fixture.component-engine'
    $componentRecipeEntry.components.engine = 'test-engine-1'
    $componentRecipeEntry.engineBuild = 'v1'
    $componentRecipeDocument.recipes = @($componentRecipeEntry)
    $componentRecipesPath = Join-Path $fxPlan.Dir 'recipes.json'
    [System.IO.File]::WriteAllText($componentRecipesPath, (ConvertTo-Json -InputObject $componentRecipeDocument -Depth 12), (New-Object System.Text.UTF8Encoding($false)))
    $componentPlanRoot = New-TestRoot
    $componentPlanParams = @{ Hardware = $xtxHardware; CatalogPath = $planCatalogPath; InstallRoot = $componentPlanRoot; RecipesPath = $componentRecipesPath; GpuVariantsPath = $shippedVariantsPath }
    $missingFailure = $null
    try { Get-FastLlmPlan @componentPlanParams | Out-Null } catch { $missingFailure = $_.Exception }
    Check ($null -ne $missingFailure -and $missingFailure.Data['FastLlmFailureCode'] -ceq 'needs-setup-component-missing' -and $missingFailure.Message -like '*test-engine-1*') 'a recipe whose engine component is not installed fails the plan with needs-setup-component-missing naming the component'
    Check (-not (Test-Path -LiteralPath (Join-Path $componentPlanRoot 'components'))) 'the missing-component plan failure installs nothing and falls back to nothing'
    $missingNamed = $null
    try { Get-FastLlmPlan @componentPlanParams -RecipeId 'fixture.component-engine' | Out-Null } catch { $missingNamed = $_.Exception }
    Check ($null -ne $missingNamed -and $missingNamed.Data['FastLlmFailureCode'] -ceq 'needs-setup-component-missing') 'naming the recipe with -Recipe gives the same typed failure'
    $componentCounter = @{ count = 0 }
    $componentRootPlanned = Install-Fixture -Fixture $fxPlan -InstallRoot $componentPlanRoot -Counter $componentCounter -AcceptLicense -Unattended
    $componentPlan = Get-FastLlmPlan @componentPlanParams
    Check ($componentPlan.recipe.id -ceq 'fixture.component-engine' -and $componentPlan.selectionMode -ceq 'recipe') 'once installed, the component recipe is picked'
    Check ($componentPlan.enginePath -ceq (Join-Path $componentRootPlanned 'server.exe') -and $componentPlan.enginePath -like '*components\engine\test-engine-1\v1\server.exe') 'the plan runs the component executable at components\engine\<id>\<version>\<entryPoint>'
    Check ($componentPlan.engineComponentId -ceq 'test-engine-1' -and $componentPlan.engineVersion -ceq 'v1') 'the plan records the engine component id and its version'
    $componentArguments = @($componentPlan.serverArguments)
    $hostIndex = [Array]::IndexOf($componentArguments, '--host')
    Check ($hostIndex -ge 0 -and $componentArguments[$hostIndex + 1] -ceq '127.0.0.1') '--host 127.0.0.1 is still in the argument list of a component plan'
    $componentExpected = @($expectedXtx | ForEach-Object { if ($_ -ceq 'MODEL') { $componentPlan.modelPath } else { $_ } })
    Check (($componentArguments -join [char]31) -ceq ($componentExpected -join [char]31)) 'a component plan has the same argument list as the built-in plan of the same recipe'
    $mismatchDocument = Get-Content -LiteralPath $componentRecipesPath -Raw | ConvertFrom-Json
    $mismatchDocument.recipes[0].engineBuild = 'v2'
    $mismatchPath = Join-Path $fxPlan.Dir 'recipes-mismatch.json'
    [System.IO.File]::WriteAllText($mismatchPath, (ConvertTo-Json -InputObject $mismatchDocument -Depth 12), (New-Object System.Text.UTF8Encoding($false)))
    $mismatchParams = @{ Hardware = $xtxHardware; CatalogPath = $planCatalogPath; InstallRoot = $componentPlanRoot; RecipesPath = $mismatchPath; GpuVariantsPath = $shippedVariantsPath }
    $mismatchPlan = Get-FastLlmPlan @mismatchParams
    Check ($mismatchPlan.recipe.origin -ceq 'estimated' -and -not $mismatchPlan.PSObject.Properties['engineComponentId']) 'a recipe whose engineBuild is not its component version is skipped (estimated plan)'
    Check (@($mismatchPlan.recipe.skipped | Where-Object { $_ -like 'fixture.component-engine: engine build differs' }).Count -eq 1) 'the skipped list says the engine build differs'

    # A component recipe cannot be planned without an install root: typed failure, no silent plan on the built-in engine path.
    $noRootParams = @{} + $componentPlanParams
    $noRootParams.Remove('InstallRoot')
    $noRootFailure = $null
    try { Get-FastLlmPlan @noRootParams | Out-Null } catch { $noRootFailure = $_.Exception }
    Check ($null -ne $noRootFailure -and $noRootFailure.Data['FastLlmFailureCode'] -ceq 'recipe-engine-needs-install-root') 'a component-engine recipe planned without -InstallRoot fails typed with recipe-engine-needs-install-root'
    $builtInNoRootParams = @{ Hardware = $xtxHardware; CatalogPath = $shippedCatalogPath; RecipesPath = $shippedRecipesPath; GpuVariantsPath = $shippedVariantsPath }
    $builtInNoRoot = Get-FastLlmPlan @builtInNoRootParams
    Check ($builtInNoRoot.recipe.id -ceq 'rx-7900-xtx.qwen3.8-27b-ud-q4-k-m.32k' -and -not $builtInNoRoot.PSObject.Properties['engineComponentId']) 'a built-in-engine recipe still plans without -InstallRoot'

    # ---- Experimental switch, CLI components action and the experimental gate (src/FastLlm.Components.ps1; entry scripts only) ----
    . (Join-Path $PSScriptRoot '../src/FastLlm.Components.ps1')
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $cliPath = (Resolve-Path -LiteralPath (Join-Path $repoRoot 'fast-llm.ps1')).Path
    $cliText = [System.IO.File]::ReadAllText($cliPath)
    $cliTokens = $null
    $cliErrors = $null
    $cliTree = [System.Management.Automation.Language.Parser]::ParseFile($cliPath, [ref] $cliTokens, [ref] $cliErrors)
    Check (@($cliErrors).Count -eq 0) 'fast-llm.ps1 parses'

    # Never imported by the producer: only the two entry scripts dot-source the new file.
    $moduleText = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'src/FastLlm.psm1'))
    $benchmarkText = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'src/FastLlm.Benchmark.ps1'))
    $uiText = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'fast-llm-ui.ps1'))
    Check (-not $moduleText.Contains('FastLlm.Components') -and -not $benchmarkText.Contains('FastLlm.Components')) 'neither FastLlm.psm1 nor FastLlm.Benchmark.ps1 mentions FastLlm.Components.ps1'
    Check ($cliText.Contains("'src') 'FastLlm.Components.ps1'") -and $uiText.Contains("src/FastLlm.Components.ps1")) 'fast-llm.ps1 and fast-llm-ui.ps1 dot-source FastLlm.Components.ps1'

    # Settings: default off, read-modify-write keeps every other key.
    $settingsRoot = New-TestRoot
    Check ((Get-FastLlmComponentSettings -InstallRoot $settingsRoot).experimentalComponents -ceq 'off') 'experimentalComponents defaults to off with no settings.json'
    [System.IO.File]::WriteAllText((Join-Path $settingsRoot 'settings.json'), '{"vulkanBarMitigation":"on","updateCheck":"off","updateChannel":"canary","futureKey":"keep","experimentalComponents":"maybe"}', (New-Object System.Text.UTF8Encoding($false)))
    Check ((Get-FastLlmComponentSettings -InstallRoot $settingsRoot).experimentalComponents -ceq 'off') 'an unrecognised experimentalComponents value reads as off'
    Set-FastLlmComponentSettings -InstallRoot $settingsRoot -ExperimentalComponents 'on'
    $storedSettings = Get-Content -LiteralPath (Join-Path $settingsRoot 'settings.json') -Raw | ConvertFrom-Json
    Check ($storedSettings.experimentalComponents -ceq 'on' -and $storedSettings.vulkanBarMitigation -ceq 'on' -and $storedSettings.updateCheck -ceq 'off' -and $storedSettings.updateChannel -ceq 'canary' -and $storedSettings.futureKey -ceq 'keep') 'turning the switch on preserves vulkanBarMitigation, updateCheck, updateChannel and unknown keys'
    Check ((Get-FastLlmComponentSettings -InstallRoot $settingsRoot).experimentalComponents -ceq 'on') 'the switch reads back on'
    Set-FastLlmComponentSettings -InstallRoot $settingsRoot -ExperimentalComponents 'off'
    $storedSettings = Get-Content -LiteralPath (Join-Path $settingsRoot 'settings.json') -Raw | ConvertFrom-Json
    Check ($storedSettings.experimentalComponents -ceq 'off' -and $storedSettings.vulkanBarMitigation -ceq 'on' -and $storedSettings.updateChannel -ceq 'canary') 'turning the switch off keeps the other keys'
    $freshRoot = Join-Path (New-TestRoot) 'not-yet-created'
    Set-FastLlmComponentSettings -InstallRoot $freshRoot -ExperimentalComponents 'on'
    Check ((Get-FastLlmComponentSettings -InstallRoot $freshRoot).experimentalComponents -ceq 'on') 'setting the switch creates the install root and settings.json when they do not exist'
    Check ((Get-ThrownMessage { Set-FastLlmComponentSettings -InstallRoot $settingsRoot -ExperimentalComponents 'sometimes' }) -ne $null) 'a value other than on or off is rejected'

    # The paragraph (spec 2.7).
    Check ($script:FastLlmExperimentalParagraph -like '*Experimental means*' -and $script:FastLlmExperimentalParagraph -like '*Bitworks has not reproduced*' -and $script:FastLlmExperimentalParagraph -like '*listed official source*' -and $script:FastLlmExperimentalParagraph -like '*pinned hash*') 'the experimental paragraph says what experimental means, that Bitworks has not reproduced it, and that each component comes from its listed official source and is checked against its pinned hash'
    Check ($script:FastLlmExperimentalParagraph -cnotmatch '[^\x20-\x7E]') 'the experimental paragraph is ASCII'

    # Recipe visibility and the gate.
    function New-GateRecipe([string] $Id, [string] $Origin) {
        return [pscustomobject] @{
            id = $Id; origin = $Origin
            gpu = [pscustomobject] @{ variant = 'rx-7900-xtx'; count = 1 }
            components = [pscustomobject] @{ engine = 'test-engine-1'; model = 'big-model' }
            runtime = [pscustomobject] @{ contextSize = 32768 }
        }
    }
    $gateRecipes = @((New-GateRecipe 'b1' 'bitworks'), (New-GateRecipe 'e1' 'community-experimental'))
    $gateComponents = @([pscustomobject] @{ id = 'test-engine-1'; kind = 'engine'; version = 'v1'; source = [pscustomobject] @{ url = 'https://example.com/downloads/test-engine-1-v1.zip' } })
    Check (@(Select-FastLlmVisibleRecipes -Recipes $gateRecipes -ExperimentalComponents 'off').Count -eq 1 -and @(Select-FastLlmVisibleRecipes -Recipes $gateRecipes -ExperimentalComponents 'off')[0].id -ceq 'b1') 'with the switch off an experimental recipe is hidden'
    Check (@(Select-FastLlmVisibleRecipes -Recipes $gateRecipes -ExperimentalComponents 'on').Count -eq 2) 'with the switch on an experimental recipe is listed'
    Check (@(Select-FastLlmVisibleRecipes -Recipes $gateRecipes).Count -eq 1) 'the visibility default is off'

    $gateRoot = New-TestRoot
    $gateOffAccept = Get-ThrownMessage { Assert-FastLlmExperimentalRecipeAllowed -InstallRoot $gateRoot -RecipeId 'e1' -Recipes $gateRecipes -Components $gateComponents -AcceptExperimental }
    Check ($null -ne $gateOffAccept -and $gateOffAccept -like '*switch is off*' -and $gateOffAccept -like '*test-engine-1*' -and $gateOffAccept -like '*https://example.com/downloads/test-engine-1-v1.zip*' -and $gateOffAccept -like '*big-model*') 'switch off plus -AcceptExperimental is refused, naming each component and its source URL'
    Check ($gateOffAccept -like '*It would use: engine test-engine-1 (https://example.com/downloads/test-engine-1-v1.zip); model big-model (comes with this release).*') 'the refusal names each component in its own entry, with its own source'
    Set-FastLlmComponentSettings -InstallRoot $gateRoot -ExperimentalComponents 'on'
    $gateOnNoAccept = Get-ThrownMessage { Assert-FastLlmExperimentalRecipeAllowed -InstallRoot $gateRoot -RecipeId 'e1' -Recipes $gateRecipes -Components $gateComponents }
    Check ($null -ne $gateOnNoAccept -and $gateOnNoAccept -like '*-AcceptExperimental was not given*' -and $gateOnNoAccept -like '*https://example.com/downloads/test-engine-1-v1.zip*') 'switch on without -AcceptExperimental is refused'
    Check ($null -eq (Get-ThrownMessage { Assert-FastLlmExperimentalRecipeAllowed -InstallRoot $gateRoot -RecipeId 'e1' -Recipes $gateRecipes -Components $gateComponents -AcceptExperimental })) 'switch on plus -AcceptExperimental passes'
    Check ($null -eq (Get-ThrownMessage { Assert-FastLlmExperimentalRecipeAllowed -InstallRoot $gateRoot -RecipeId 'b1' -Recipes $gateRecipes -Components $gateComponents })) 'a Bitworks recipe needs neither the switch nor the acceptance'
    $gateOffRoot = New-TestRoot
    Check ($null -eq (Get-ThrownMessage { Assert-FastLlmExperimentalRecipeAllowed -InstallRoot $gateOffRoot -RecipeId 'b1' -Recipes $gateRecipes -Components $gateComponents })) 'a Bitworks recipe passes with the switch off'
    Check ($null -ne (Get-ThrownMessage { Assert-FastLlmExperimentalRecipeAllowed -InstallRoot $gateOffRoot -RecipeId 'e1' -Recipes $gateRecipes -Components $gateComponents })) 'an experimental recipe with the switch off and no acceptance is refused'
    Check ($null -eq (Get-ThrownMessage { Assert-FastLlmExperimentalRecipeAllowed -InstallRoot $gateOffRoot -Recipes $gateRecipes -Components $gateComponents })) 'no -Recipe means no gate'
    Check ($null -ne (Get-ThrownMessage { Assert-FastLlmExperimentalRecipeAllowed -InstallRoot $gateOffRoot -RecipeId 'E1' -Recipes $gateRecipes -Components $gateComponents })) "an experimental recipe named in another case ('E1' for 'e1') is refused, as the recipe selection matches case-insensitively"
    Check ($null -eq (Get-ThrownMessage { Assert-FastLlmExperimentalRecipeAllowed -InstallRoot $gateOffRoot -RecipeId 'B1' -Recipes $gateRecipes -Components $gateComponents })) "a Bitworks recipe named in another case still passes"

    # An installed experimental component with the switch off: its recipes stay hidden and nothing auto-selects it.
    . (Join-Path $repoRoot 'src/FastLlm.CardIdentity.ps1')
    . (Join-Path $repoRoot 'src/FastLlm.Recipes.ps1')
    $autoVariants = Get-FastLlmGpuVariants -Path (Join-Path $repoRoot 'config/gpu-variants.json')
    $autoCatalog = [pscustomobject] @{ engine = [pscustomobject] @{ version = 'b10698' }; models = @([pscustomobject] @{ id = 'big'; requiredFreeVramMiB = 20500; scores = [pscustomobject] @{ balanced = 112 } }) }
    $autoRecipe = [pscustomobject] @{ id = 'e1'; origin = 'community-experimental'; gpu = [pscustomobject] @{ variant = 'rx-7900-xtx'; count = 1 }
        components = [pscustomobject] @{ engine = 'llama.cpp-b10698-vulkan'; model = 'big' }; engineBuild = 'b10698'; recommended = $false
        runtime = [pscustomobject] @{ contextSize = 32768; vulkanBarMitigation = 'auto' }; expected = [pscustomobject] @{ generationTokS = 60 }
        evidence = [pscustomobject] @{ url = 'https://bitworks.io/r' }; compelling = [pscustomobject] @{ isCompelling = $true } }
    $autoDxgi = @([pscustomobject] @{ vendorId = 4098; deviceId = 29772; revision = 200; dedicatedVideoMiB = 24534 })
    $autoPlacement = [pscustomobject] @{ adapters = @([pscustomobject] @{ name = 'n'; vramMiB = 24560 }); selectionCapacity = 23000 }
    $autoOff = Select-FastLlmRecipeForPlacements -Recipes @($autoRecipe) -Variants $autoVariants -Placements @($autoPlacement) -DxgiAdapters $autoDxgi -Catalog $autoCatalog -Profile 'balanced'
    $autoOn = Select-FastLlmRecipeForPlacements -Recipes @($autoRecipe) -Variants $autoVariants -Placements @($autoPlacement) -DxgiAdapters $autoDxgi -Catalog $autoCatalog -Profile 'balanced' -IncludeExperimental
    Check ($null -eq $autoOff -and $null -eq $autoOn) 'an experimental recipe is never auto-selected, with the switch off or on'
    # Positive control: the same recipe from Bitworks IS picked under the same inputs, so the null above is about the origin and not the inputs.
    $autoBitworks = $autoRecipe | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $autoBitworks.origin = 'bitworks'
    $autoControl = Select-FastLlmRecipeForPlacements -Recipes @($autoBitworks) -Variants $autoVariants -Placements @($autoPlacement) -DxgiAdapters $autoDxgi -Catalog $autoCatalog -Profile 'balanced'
    Check ($null -ne $autoControl -and $autoControl.recipe.id -ceq 'e1') 'the same recipe with origin bitworks is picked under the same inputs'

    # Runtime and draft components cannot run in this release: skipped with a reason, and a typed failure when named.
    foreach ($unsupportedRole in @('runtime', 'draft')) {
        $roleRecipe = $autoBitworks | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $roleRecipe.components | Add-Member -NotePropertyName $unsupportedRole -NotePropertyValue "$unsupportedRole-1"
        $roleSink = New-Object 'System.Collections.Generic.List[string]'
        $roleAuto = Select-FastLlmRecipeForPlacements -Recipes @($roleRecipe) -Variants $autoVariants -Placements @($autoPlacement) -DxgiAdapters $autoDxgi -Catalog $autoCatalog -Profile 'balanced' -SkippedSink $roleSink
        Check ($null -eq $roleAuto -and @($roleSink | Where-Object { $_ -like '*needs a runtime or draft component this release cannot run' }).Count -eq 1) "a recipe naming a $unsupportedRole component is skipped with the reason"
        $roleFailure = $null
        try { Select-FastLlmRecipeForPlacements -Recipes @($roleRecipe) -Variants $autoVariants -Placements @($autoPlacement) -DxgiAdapters $autoDxgi -Catalog $autoCatalog -Profile 'balanced' -RecipeId 'e1' | Out-Null } catch { $roleFailure = $_.Exception }
        Check ($null -ne $roleFailure -and $roleFailure.Data['FastLlmFailureCode'] -ceq 'recipe-component-role-unsupported' -and $roleFailure.Message -like "*$unsupportedRole*") "naming a recipe with a $unsupportedRole component throws recipe-component-role-unsupported naming the role"
    }
    $emptyRoleRecipe = $autoBitworks | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $emptyRoleRecipe.components | Add-Member -NotePropertyName 'draft' -NotePropertyValue ''
    Check ($null -ne (Select-FastLlmRecipeForPlacements -Recipes @($emptyRoleRecipe) -Variants $autoVariants -Placements @($autoPlacement) -DxgiAdapters $autoDxgi -Catalog $autoCatalog -Profile 'balanced')) 'an empty draft role does not block a recipe'

    # Listing format.
    $listRows = @(
        [pscustomobject] @{ id = 'comp-a'; kind = 'engine'; version = 'v1'; installed = $true; bytes = [int64] 12582912; verified = $true },
        [pscustomobject] @{ id = 'comp-b'; kind = 'model'; version = 'q4'; installed = $false; bytes = [int64] 0; verified = $false })
    $listLines = @(Format-FastLlmComponentList -Inventory $listRows)
    Check ($listLines.Count -eq 3 -and $listLines[0] -like '*id*kind*version*installed*size*verified*') 'the component list has a header and one line per component'
    Check ($listLines[1] -like '*comp-a*engine*v1*yes*12.0 MB*yes*') 'an installed component line lists id, kind, version, installed, size in MB and verified'
    Check ($listLines[2] -like '*comp-b*model*q4*no*') 'a component that is not installed is listed as not installed'
    Check ((Format-FastLlmComponentSize -Bytes 1572864) -ceq '1.5 MB') 'the size is shown in MB with one decimal'
    $installedOnly = @(Get-FastLlmInstalledComponentRows -Inventory $listRows)
    Check ($installedOnly.Count -eq 1 -and $installedOnly[0].id -ceq 'comp-a' -and $installedOnly[0].label -like '*comp-a*engine*v1*12.0 MB*') 'the Components window rows list only installed components, with their sizes'

    # The real CLI branches, taken from the AST of fast-llm.ps1 and run against fixtures.
    function Get-CliBranchBody([string] $Name) {
        $switches = $cliTree.FindAll({ param($node) $node -is [System.Management.Automation.Language.SwitchStatementAst] }, $true)
        foreach ($switchAst in $switches) {
            foreach ($clause in $switchAst.Clauses) {
                if ($clause.Item1.Extent.Text -ceq "'$Name'") {
                    $branchText = $clause.Item2.Extent.Text
                    return $branchText.Substring(1, $branchText.Length - 2)
                }
            }
        }
        return $null
    }
    $componentsBody = Get-CliBranchBody 'components'
    $recipesBody = Get-CliBranchBody 'recipes'
    Check ($null -ne $componentsBody -and $null -ne $recipesBody) 'fast-llm.ps1 has a components branch and a recipes branch'
    $branchDeclaration = 'function Invoke-CliBranchUnderTest { [CmdletBinding()] param([string] $Install, [string] $Remove, [switch] $AcceptLicense, [switch] $Unattended, [switch] $AsJson, [string] $InstallRoot, [string] $componentsFilePath, [string] $recipesPath) '
    . ([scriptblock]::Create($branchDeclaration + $componentsBody + ' }'))
    $componentsFunction = ${function:Invoke-CliBranchUnderTest}
    . ([scriptblock]::Create($branchDeclaration + $recipesBody + ' }'))
    $recipesFunction = ${function:Invoke-CliBranchUnderTest}

    $cliFixture = New-Fixture -Dir (New-TestRoot) -Id 'cli-engine-1'
    $cliRoot = New-TestRoot
    $cliCounter = @{ count = 0 }
    $null = Install-Fixture -Fixture $cliFixture -InstallRoot $cliRoot -Counter $cliCounter -AcceptLicense -Unattended
    $listText = @(& $componentsFunction -InstallRoot $cliRoot -componentsFilePath $cliFixture.ComponentsPath 6>&1 | ForEach-Object { [string] $_ })
    Check ($listText.Count -ge 2 -and $listText[0] -like '*id*kind*version*installed*size*verified*') 'components -List (the default) prints a header'
    Check (@($listText | Where-Object { $_ -like '*cli-engine-1*engine*v1*yes*MB*yes*' }).Count -eq 1) 'components -List prints id, kind, version, installed, size in MB and verified'
    $listJson = @(& $componentsFunction -InstallRoot $cliRoot -componentsFilePath $cliFixture.ComponentsPath -AsJson 6>&1 | ForEach-Object { [string] $_ }) -join "`n" | ConvertFrom-Json
    $jsonRow = @($listJson)[0]
    Check ($jsonRow.id -ceq 'cli-engine-1' -and $jsonRow.kind -ceq 'engine' -and $jsonRow.version -ceq 'v1' -and $jsonRow.installed -eq $true -and $jsonRow.bytes -gt 0 -and $jsonRow.verified -eq $true) 'components -List -AsJson emits id, kind, version, installed, bytes and verified'
    $emptyCliRoot = New-TestRoot
    $emptyListText = @(& $componentsFunction -InstallRoot $emptyCliRoot -componentsFilePath $cliFixture.ComponentsPath 6>&1 | ForEach-Object { [string] $_ })
    Check (@($emptyListText | Where-Object { $_ -like '*cli-engine-1*engine*v1*no*' }).Count -eq 1) 'a component that is not installed is listed as not installed'
    $removeMessage = Get-ThrownMessage { & $componentsFunction -InstallRoot $cliRoot -componentsFilePath $cliFixture.ComponentsPath -Remove 'not-a-listed-component' }
    Check ($null -ne $removeMessage -and $removeMessage -like '*not in the signed components list*') 'components -Remove of an unlisted id is refused'
    $null = & $componentsFunction -InstallRoot $cliRoot -componentsFilePath $cliFixture.ComponentsPath -Remove 'cli-engine-1' 6>&1
    Check (-not (Test-Path -LiteralPath (Join-Path $cliRoot 'components/engine/cli-engine-1/v1'))) 'components -Remove removes the component'

    # recipes: experimental recipes only when the switch is on, marked with their label.
    $recipeDocument = [ordered] @{ schema = 'bitworks.fastllm-recipes/v2'; recipes = @((New-GateRecipe 'b1' 'bitworks'), (New-GateRecipe 'e1' 'community-experimental')) }
    $recipesFile = Join-Path (New-TestRoot) 'recipes.json'
    [System.IO.File]::WriteAllText($recipesFile, (ConvertTo-Json -InputObject $recipeDocument -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
    $recipesOffRoot = New-TestRoot
    $recipesOffText = @(& $recipesFunction -InstallRoot $recipesOffRoot -recipesPath $recipesFile 6>&1 | ForEach-Object { [string] $_ })
    Check ($recipesOffText.Count -eq 1 -and $recipesOffText[0] -like 'b1 - *' -and -not ($recipesOffText -join "`n").Contains('e1')) 'recipes hides an experimental recipe when the switch is off'
    $recipesOffJson = (@(& $recipesFunction -InstallRoot $recipesOffRoot -recipesPath $recipesFile -AsJson 6>&1 | ForEach-Object { [string] $_ }) -join "`n") | ConvertFrom-Json
    Check (@($recipesOffJson).Count -eq 1 -and @($recipesOffJson)[0].id -ceq 'b1') 'recipes -AsJson hides an experimental recipe when the switch is off'
    $recipesOnRoot = New-TestRoot
    Set-FastLlmComponentSettings -InstallRoot $recipesOnRoot -ExperimentalComponents 'on'
    $recipesOnText = @(& $recipesFunction -InstallRoot $recipesOnRoot -recipesPath $recipesFile 6>&1 | ForEach-Object { [string] $_ })
    Check ($recipesOnText.Count -eq 2 -and @($recipesOnText | Where-Object { $_ -like 'e1 - Experimental community recipe, not reproduced by Bitworks - *' }).Count -eq 1) 'recipes lists an experimental recipe with its label when the switch is on'

    # fast-llm.ps1 argument rules and wiring.
    Check ($cliText.Contains("'update-check', 'update', 'components')]") -and $cliText.Contains('[switch] $List') -and $cliText.Contains('[string] $Install') -and $cliText.Contains('[string] $Remove') -and $cliText.Contains('[switch] $AcceptLicense') -and $cliText.Contains('[switch] $AcceptExperimental')) 'fast-llm.ps1 declares the components action, -List, -Install, -Remove, -AcceptLicense and -AcceptExperimental'
    Check ($cliText.Contains('-List is supported only by components.') -and $cliText.Contains('-Install is supported only by components.') -and $cliText.Contains('-Remove is supported only by components.') -and $cliText.Contains('-AcceptLicense is supported only by components.') -and $cliText.Contains('-AcceptExperimental is supported only by plan, start and install.')) 'fast-llm.ps1 refuses the components parameters on other actions with the supported-only-by pattern'
    $gateIndex = $cliText.IndexOf('Assert-FastLlmExperimentalRecipeAllowed -InstallRoot')
    Check ($gateIndex -ge 0 -and $gateIndex -lt $cliText.IndexOf('Enter-FastLlmOperation -InstallRoot') -and $cliText.Contains("`$Action -in @('plan', 'start', 'install', 'doctor')")) 'the experimental gate runs for plan, start, install and doctor before the operation lock'
    $cliParameterNames = @($cliTree.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    $assignedNames = @($cliTree.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) | ForEach-Object { $_.Left.VariablePath.UserPath })
    # InstallRoot (default resolution) and DeviceBinding (lower-casing) are the two pre-existing, deliberate assignments to a parameter.
    $shadowed = @($assignedNames | Where-Object { $cliParameterNames -contains $_ -and @('InstallRoot', 'DeviceBinding') -cnotcontains $_ })
    Check ($shadowed.Count -eq 0) 'fast-llm.ps1 assigns to no variable named like one of its parameters, case-insensitively'

    $psExecutable = (Get-Process -Id $PID).Path
    function Invoke-CliRefusal([string[]] $Arguments) {
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $output = & $psExecutable -NoProfile -NonInteractive -File $cliPath @Arguments 2>&1 | ForEach-Object { [string] $_ } }
        finally { $ErrorActionPreference = $previousPreference }
        return [pscustomobject] @{ exit = $LASTEXITCODE; text = (($output -join ' ') -replace '\s+', ' ') }
    }
    $refusalRoot = New-TestRoot
    foreach ($case in @(
            @{ args = @('plan', '-List', '-InstallRoot', $refusalRoot); text = '-List is supported only by components.' },
            @{ args = @('plan', '-Install', 'x', '-InstallRoot', $refusalRoot); text = '-Install is supported only by components.' },
            @{ args = @('recipes', '-Remove', 'x', '-InstallRoot', $refusalRoot); text = '-Remove is supported only by components.' },
            @{ args = @('start', '-AcceptLicense', '-InstallRoot', $refusalRoot); text = '-AcceptLicense is supported only by components.' },
            @{ args = @('components', '-AcceptExperimental', '-InstallRoot', $refusalRoot); text = '-AcceptExperimental is supported only by plan, start and install.' },
            @{ args = @('components', '-Install', 'a', '-Remove', 'b', '-InstallRoot', $refusalRoot); text = 'components takes one of -List, -Install <id> or -Remove <id>.' },
            @{ args = @('components', '-List', '-AcceptLicense', '-InstallRoot', $refusalRoot); text = '-AcceptLicense is supported only with components -Install.' })) {
        $result = Invoke-CliRefusal $case.args
        Check ($result.exit -ne 0 -and $result.text.Contains($case.text)) ("fast-llm.ps1 " + ($case.args[0..1] -join ' ') + ' is refused: ' + $case.text)
    }
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "components-tests: $script:checks checks passed"
# The CLI refusal cases leave a child's non-zero exit code in $LASTEXITCODE. CI runs the suites in one session and fails the step
# when the final value is non-zero, so reset it once every check has passed.
$global:LASTEXITCODE = 0
