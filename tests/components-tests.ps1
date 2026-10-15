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
    $expectedCache = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($installRoot, 'downloads', 'c', ((Get-HexSha $fx.Zip).Substring(0, 16) + '.zip')))
    Check ([string] $counter.destination -ceq $expectedCache) 'the component download is cached at downloads\c\<first 16 hex of the pinned SHA-256>.<ext>, never under the URL file name or the shared downloads\<file>'
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
    Check (@($accShown | Where-Object { $_ -ceq 'Component: Test engine v1 (test-engine-1 v1)' }).Count -eq 1 -and @($accShown | Where-Object { $_ -ceq 'License: MIT https://example.com/LICENSE' }).Count -eq 1) 'an accept-type install with -AcceptLicense prints the Component: and License: lines'
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
    $downloadsDir = [System.IO.Path]::Combine($badRoot, 'downloads', 'c')
    $badCacheName = (Get-HexSha $fxPin.Zip).Substring(0, 16) + '.zip'
    Check (@(Get-ChildItem -LiteralPath $downloadsDir -Force | Where-Object { $_.Name -like '*.corrupt.*' }).Count -eq 1 -and @(Get-ChildItem -LiteralPath $downloadsDir -Force | Where-Object { $_.Name -eq $badCacheName }).Count -eq 0) 'hash mismatch: the bad download is quarantined, not left in place'
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

    # ---- streaming zip-tree install, requires chains with per-component consent, removal guard, presence checks ----
    . (Join-Path $PSScriptRoot '../src/FastLlm.Components.ps1')

    # Builds <Path> from an ordered name -> text table with explicit entry names (forward slashes), so a nested archive is the same on every platform.
    function New-NamedZip([string] $Path, $Entries) {
        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
        New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
        $zipArchive = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($name in $Entries.Keys) {
                $zipEntry = $zipArchive.CreateEntry([string] $name)
                $zipStream = $zipEntry.Open()
                try { $bytes = [System.Text.Encoding]::ASCII.GetBytes([string] $Entries[$name]); $zipStream.Write($bytes, 0, $bytes.Length) } finally { $zipStream.Dispose() }
            }
        }
        finally { $zipArchive.Dispose() }
    }
    function Get-TextSha([string] $Text) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
    }
    # One archive part: Files (path -> text) are the manifest, Extra (archive-side name -> text) are members the manifest does not list.
    # BadHashPath pins a wrong SHA-256 for that path; MissingPath pins a path the archive does not hold.
    function New-ArchivePart([string] $Dir, [string] $Name, $Files, [string] $Prefix, $Extra = @{}, [string] $Format = 'zip-tree', [string] $BadHashPath = '', [string] $MissingPath = '', [string] $WrongSizePath = '') {
        $entries = [ordered] @{}
        $manifest = @()
        foreach ($filePath in $Files.Keys) {
            $entries[$Prefix + $filePath] = $Files[$filePath]
            $sha = Get-TextSha ([string] $Files[$filePath])
            if ($filePath -ceq $BadHashPath) { $sha = '1' * 64 }
            $pinnedLength = ([System.Text.Encoding]::ASCII.GetBytes([string] $Files[$filePath])).Length
            if ($filePath -ceq $WrongSizePath) { $pinnedLength = $pinnedLength + 1 }
            $manifest += [ordered] @{ path = $filePath; sizeBytes = $pinnedLength; sha256 = $sha }
        }
        foreach ($extraName in $Extra.Keys) { $entries[$extraName] = $Extra[$extraName] }
        if ($MissingPath) { $manifest += [ordered] @{ path = $MissingPath; sizeBytes = 3; sha256 = (Get-TextSha 'abc') } }
        $zipPath = Join-Path $Dir $Name
        New-NamedZip -Path $zipPath -Entries $entries
        $part = [ordered] @{ url = "https://downloads.example.com/$Name"; allowedRedirectHosts = @('downloads.example.com'); sha256 = (Get-HexSha $zipPath); sizeBytes = (Get-Item -LiteralPath $zipPath).Length; format = $Format }
        if ($Format -ceq 'zip-tree') { $part.extractPrefix = $Prefix }
        $part.fileManifest = @($manifest)
        return [pscustomobject] @{ part = $part; zip = $zipPath; url = [string] $part.url }
    }
    # A runtime (two nested zip-tree parts, a links-only license) and an engine (flat zip, url + links license) that requires it.
    function New-ChainFixture([string] $Name, [string] $Consent = 'accept', [string] $BadHashPath = '', [string] $MissingPath = '', [string] $WrongSizePath = '', [string] $BadEngineHashPath = '') {
        $dir = Join-Path $work $Name
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $part1 = New-ArchivePart -Dir $dir -Name 'rt-libs.whl' -Prefix '_sdk/' -Files ([ordered] @{ 'bin/a.dll' = 'runtime-a'; 'bin/lib/x.dat' = 'runtime-x' }) -Extra @{ '_sdk/unrelated.txt' = 'not listed'; 'other/readme.md' = 'also not listed' } -BadHashPath $BadHashPath -MissingPath $MissingPath -WrongSizePath $WrongSizePath
        $part2 = New-ArchivePart -Dir $dir -Name 'rt-device.whl' -Prefix '_sdk/' -Files ([ordered] @{ 'bin/b.dll' = 'runtime-b'; '.kpack/k.kpack' = 'runtime-k' })
        $engineFiles = [ordered] @{ 'server.exe' = 'engine-server'; 'engine.dll' = 'engine-dll' }
        $enginePart = New-ArchivePart -Dir $dir -Name 'engine.zip' -Prefix '' -Files $engineFiles -Format 'zip' -BadHashPath $BadEngineHashPath
        $runtimeLicense = [ordered] @{ spdx = 'proprietary'; consent = $Consent; links = @([ordered] @{ title = 'AMD EULA'; url = 'https://rocm.example.com/eula' }, [ordered] @{ title = 'Third party notices'; url = 'https://rocm.example.com/notices' }) }
        $engineLicense = [ordered] @{ spdx = 'MIT'; url = 'https://engine.example.com/LICENSE'; consent = $Consent; links = @([ordered] @{ title = 'AMD HIP terms'; url = 'https://rocm.example.com/hip' }) }
        $runtime = New-TreeComponent -Id 'rt-hip' -Parts @($part1.part, $part2.part) -PathDirs @('bin') -License $runtimeLicense
        $engine = New-TreeComponent -Id 'eng-hip' -Parts @($enginePart.part) -Kind 'engine' -Requires @('rt-hip') -License $engineLicense -LegacySource
        $engine.entryPoint = 'server.exe'
        $engine.adapter = 'llama.cpp'
        $docPath = Write-ComponentsDoc @($engine, $runtime)
        $zipByUrl = @{}
        foreach ($archive in @($part1, $part2, $enginePart)) { $zipByUrl[$archive.url] = $archive.zip }
        return [pscustomobject] @{ ComponentsPath = $docPath; ZipByUrl = $zipByUrl; Dir = $dir; Part1Url = $part1.url; Part2Url = $part2.url; EngineUrl = $enginePart.url }
    }
    # A download seam that serves the fixture archives and records the order (and a DOWNLOAD line in the output stream, to compare with the consent lines).
    function New-ChainSeam($Fixture, $State, $Override = @{}) {
        $zipByUrl = @{}
        foreach ($zipKey in $Fixture.ZipByUrl.Keys) { $zipByUrl[$zipKey] = $Fixture.ZipByUrl[$zipKey] }
        foreach ($overrideKey in $Override.Keys) { $zipByUrl[$overrideKey] = $Override[$overrideKey] }
        $stateLocal = $State
        return {
            param($Url, $Destination, $Sha256, $SizeBytes, $AllowedRedirectHosts)
            Write-Host "DOWNLOAD $Url"
            $stateLocal.log.Add([string] $Url)
            if ($stateLocal.ContainsKey('probe')) { $stateLocal.probes.Add((& $stateLocal.probe ([string] $Url))) }
            [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Destination)) | Out-Null
            Copy-Item -LiteralPath $zipByUrl[[string] $Url] -Destination $Destination -Force
        }.GetNewClosure()
    }
    function New-ChainState { return @{ log = (New-Object 'System.Collections.Generic.List[string]'); probes = (New-Object 'System.Collections.Generic.List[object]') } }
    # The module-scope console-answer hook (not a parameter): $null clears it.
    function Set-ConsentHook($Hook) { & $module { param($h) $script:FastLlmConsentPromptHook = $h } $Hook }
    function Get-ThrownFailure([scriptblock] $Block) {
        try { & $Block | Out-Null } catch { return [pscustomobject] @{ code = [string] $_.Exception.Data['FastLlmFailureCode']; message = [string] $_.Exception.Message } }
        return $null
    }
    function Get-ComponentEntry([string] $ComponentsPath, [string] $Id) { return @(Get-FastLlmComponents -ComponentsPath $ComponentsPath | Where-Object { $_.id -ceq $Id })[0] }

    # ---- License links helper ----
    $linksFx = New-ChainFixture -Name 'fx-chain'
    $linksRuntime = Get-ComponentEntry $linksFx.ComponentsPath 'rt-hip'
    $linksEngine = Get-ComponentEntry $linksFx.ComponentsPath 'eng-hip'
    $runtimeLinks = @(Get-FastLlmComponentLicenseLinks -Component $linksRuntime)
    $engineLinks = @(Get-FastLlmComponentLicenseLinks -Component $linksEngine)
    Check ($runtimeLinks.Count -eq 2 -and $runtimeLinks[0].title -ceq 'AMD EULA' -and $runtimeLinks[1].url -ceq 'https://rocm.example.com/notices') 'Get-FastLlmComponentLicenseLinks lists a links-only license (no license.url) as its links'
    Check ($engineLinks.Count -eq 2 -and $engineLinks[0].title -ceq 'MIT' -and $engineLinks[0].url -ceq 'https://engine.example.com/LICENSE' -and $engineLinks[1].title -ceq 'AMD HIP terms') 'Get-FastLlmComponentLicenseLinks lists license.url first (titled with its SPDX id), then the links'
    Check ($moduleSourceEarly -notmatch '\.license\.url') 'no code reads .license.url directly: every license read goes through the links helper'

    # ---- Chain install: order, consent lines before the first download, receipts, nested trees ----
    $chainRoot = New-TestRoot
    $chainState = New-ChainState
    $runtimeRootExpected = Get-FastLlmComponentRoot -InstallRoot $chainRoot -Component $linksRuntime
    # The seam can only see its own locals, so the probe closes over the runtime root to prove the runtime verified before the engine download started.
    $probeRuntimeRoot = $runtimeRootExpected
    $probeModule = $module
    $chainState.probe = { param($u) [pscustomobject] @{ url = $u; runtimeServer = (Test-Path -LiteralPath (Join-Path $probeRuntimeRoot 'bin/b.dll')) } }.GetNewClosure()
    $chainSeam = New-ChainSeam -Fixture $linksFx -State $chainState
    $chainOut = Install-FastLlmComponent -ComponentsPath $linksFx.ComponentsPath -ComponentId 'eng-hip' -InstallRoot $chainRoot -AcceptLicense -Download $chainSeam 6>&1
    $chainReturn = @($chainOut | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })
    $chainLines = @($chainOut | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string] $_ })
    $engineRootActual = Get-FastLlmComponentRoot -InstallRoot $chainRoot -Component $linksEngine
    Check ($chainReturn.Count -eq 1 -and $chainReturn[0] -is [string] -and $chainReturn[0] -ceq $engineRootActual) 'a chain install returns exactly the requested component root'
    Check (($chainState.log -join ',') -ceq ($linksFx.Part1Url + ',' + $linksFx.Part2Url + ',' + $linksFx.EngineUrl)) 'the chain installs the required runtime (both parts) before the engine'
    $firstDownload = [array]::IndexOf($chainLines, ($chainLines | Where-Object { $_ -like 'DOWNLOAD *' } | Select-Object -First 1))
    $runtimeLine = [array]::IndexOf($chainLines, 'Component: rt-hip (rt-hip 1.0)')
    $engineLine = [array]::IndexOf($chainLines, 'Component: eng-hip (eng-hip 1.0)')
    Check ($runtimeLine -ge 0 -and $engineLine -ge 0 -and $runtimeLine -lt $firstDownload -and $engineLine -lt $firstDownload -and $firstDownload -ge 0) 'the Component: lines of BOTH components print before the first download'
    foreach ($expectedLine in @('Source: downloads.example.com', 'License: AMD EULA https://rocm.example.com/eula', 'License: Third party notices https://rocm.example.com/notices', 'License: MIT https://engine.example.com/LICENSE', 'License: AMD HIP terms https://rocm.example.com/hip')) {
        $position = [array]::IndexOf($chainLines, $expectedLine)
        Check ($position -ge 0 -and $position -lt $firstDownload) "the consent line '$expectedLine' prints before the first download"
    }
    Check (@($chainLines | Where-Object { $_ -ceq 'Source: downloads.example.com' }).Count -eq 2) 'one Source: line per component (a repeated host inside one component is shown once)'
    Check ($chainState.probes[2].runtimeServer -eq $true) 'the runtime was installed before the engine download started'
    foreach ($receiptName in @('component-rt-hip-1.0.json', 'component-eng-hip-1.0.json')) {
        Check (Test-Path -LiteralPath (Join-Path (Join-Path $chainRoot 'consents') $receiptName) -PathType Leaf) "an accept-consent component gets its own receipt ($receiptName)"
    }
    $runtimeReceipt = Get-Content -LiteralPath (Join-Path (Join-Path $chainRoot 'consents') 'component-rt-hip-1.0.json') -Raw | ConvertFrom-Json
    Check ($null -eq $runtimeReceipt.licenseUrl -and @($runtimeReceipt.links).Count -eq 2 -and $runtimeReceipt.links[0].url -ceq 'https://rocm.example.com/eula' -and $runtimeReceipt.schemaVersion -eq 1) 'a links-only receipt keeps schemaVersion 1, a null licenseUrl and records links[]'
    Check (Test-Path -LiteralPath (Join-Path $runtimeRootExpected 'bin/lib/x.dat')) 'the nested two-part zip-tree lands under the component root (part one)'
    Check ((Test-Path -LiteralPath (Join-Path $runtimeRootExpected '.kpack/k.kpack')) -and (Test-Path -LiteralPath (Join-Path $runtimeRootExpected 'bin/b.dll'))) 'the nested two-part zip-tree lands under the component root (part two, a leading-dot folder)'
    Check ((Test-FastLlmComponentInstallation -InstallRoot $chainRoot -Component $linksRuntime) -and (Test-FastLlmComponentInstallation -InstallRoot $chainRoot -Component $linksRuntime -Depth Presence)) 'the installed nested runtime verifies at both Full and Presence'
    Check ((Test-FastLlmComponentInstallation -InstallRoot $chainRoot -Component $linksEngine) -and (Test-FastLlmComponentInstallation -InstallRoot $chainRoot -Component $linksEngine -Depth Presence)) 'the installed engine verifies at both Full and Presence'
    $runtimeFiles = @(Get-ChildItem -LiteralPath $runtimeRootExpected -Force -Recurse -File)
    Check ($runtimeFiles.Count -eq 4 -and @($runtimeFiles | Where-Object { $_.Name -like 'unrelated*' -or $_.Name -like 'readme*' }).Count -eq 0) 'archive members outside the manifest are ignored (only the 4 manifest files are installed)'
    Check (-not (Test-Path -LiteralPath (Join-Path (Join-Path $chainRoot 'components') '.s'))) 'the short staging folder is gone after the install'
    $againState = New-ChainState
    $againRoot = Install-FastLlmComponent -ComponentsPath $linksFx.ComponentsPath -ComponentId 'eng-hip' -InstallRoot $chainRoot -AcceptLicense -Download (New-ChainSeam -Fixture $linksFx -State $againState)
    Check ($againRoot -ceq $engineRootActual -and $againState.log.Count -eq 0) 'installing an installed chain again is a no-op without a download'

    # An old receipt (before links[]) matches a component without license links and no other.
    $plainReceiptFx = New-Fixture -Dir (Join-Path $work 'fx-old-receipt') -Consent 'accept'
    $plainEntry = @(Get-FastLlmComponents -ComponentsPath $plainReceiptFx.ComponentsPath)[0]
    $oldRoot = New-TestRoot
    New-Item -ItemType Directory -Path (Join-Path $oldRoot 'consents') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path (Join-Path $oldRoot 'consents') 'component-test-engine-1-v1.json'), '{"schemaVersion":1,"id":"test-engine-1","version":"v1","licenseUrl":"https://example.com/LICENSE","acceptedAt":"2026-01-01T00:00:00.0000000Z","mode":"explicit-switch"}')
    Check ((& $module { param($C, $R) Test-FastLlmComponentConsentReceipt -Component $C -InstallRoot $R } $plainEntry $oldRoot)) 'a receipt written before links[] still matches a component without license links'
    New-Item -ItemType Directory -Path (Join-Path $oldRoot 'consents') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path (Join-Path $oldRoot 'consents') 'component-eng-hip-1.0.json'), '{"schemaVersion":1,"id":"eng-hip","version":"1.0","licenseUrl":"https://engine.example.com/LICENSE","acceptedAt":"2026-01-01T00:00:00.0000000Z","mode":"explicit-switch"}')
    Check (-not (& $module { param($C, $R) Test-FastLlmComponentConsentReceipt -Component $C -InstallRoot $R } $linksEngine $oldRoot)) 'a receipt without links[] does not cover a component that now carries license links'

    # ---- Full vs Presence: extra, missing and same-size tampered files ----
    $extraFile = Join-Path $runtimeRootExpected 'bin/extra.txt'
    [System.IO.File]::WriteAllText($extraFile, 'extra')
    Check ((-not (Test-FastLlmComponentInstallation -InstallRoot $chainRoot -Component $linksRuntime)) -and (-not (Test-FastLlmComponentInstallation -InstallRoot $chainRoot -Component $linksRuntime -Depth Presence))) 'an extra installed file fails both Full and Presence'
    Remove-Item -LiteralPath $extraFile -Force
    $emptyExtraDir = Join-Path $runtimeRootExpected 'bin/empty-extra'
    New-Item -ItemType Directory -Path $emptyExtraDir -Force | Out-Null
    Check ((-not (Test-FastLlmComponentInstallation -InstallRoot $chainRoot -Component $linksRuntime)) -and (-not (Test-FastLlmComponentInstallation -InstallRoot $chainRoot -Component $linksRuntime -Depth Presence))) 'an extra installed folder fails both Full and Presence'
    Remove-Item -LiteralPath $emptyExtraDir -Force
    $sameSizeFile = Join-Path $runtimeRootExpected 'bin/a.dll'
    $originalBytes = [System.IO.File]::ReadAllBytes($sameSizeFile)
    [System.IO.File]::WriteAllBytes($sameSizeFile, [System.Text.Encoding]::ASCII.GetBytes('runtime-Z'))
    Check ((Test-FastLlmComponentInstallation -InstallRoot $chainRoot -Component $linksRuntime -Depth Presence) -and (-not (Test-FastLlmComponentInstallation -InstallRoot $chainRoot -Component $linksRuntime))) 'a same-size content change passes Presence (it never hashes) and fails Full'
    [System.IO.File]::WriteAllBytes($sameSizeFile, $originalBytes)
    Remove-Item -LiteralPath (Join-Path $runtimeRootExpected '.kpack/k.kpack') -Force
    Check ((-not (Test-FastLlmComponentInstallation -InstallRoot $chainRoot -Component $linksRuntime)) -and (-not (Test-FastLlmComponentInstallation -InstallRoot $chainRoot -Component $linksRuntime -Depth Presence))) 'a missing installed file fails both Full and Presence'
    [System.IO.File]::WriteAllBytes((Join-Path $runtimeRootExpected '.kpack/k.kpack'), [System.Text.Encoding]::ASCII.GetBytes('runtime-k'))
    Check (Test-FastLlmComponentInstallation -InstallRoot $chainRoot -Component $linksRuntime) 'the runtime verifies again once the file is restored (positive control)'

    # ---- Removal guard ----
    $guardFailure = Get-ThrownFailure { Remove-FastLlmComponent -ComponentsPath $linksFx.ComponentsPath -ComponentId 'rt-hip' -InstallRoot $chainRoot }
    Check ($null -ne $guardFailure -and $guardFailure.code -ceq 'component-required-by' -and $guardFailure.message -like "*'eng-hip'*") 'removing a required runtime while the engine is installed is the typed component-required-by, naming the engine'
    Check ((Test-Path -LiteralPath (Join-Path $runtimeRootExpected 'bin/a.dll')) -and (Test-Path -LiteralPath (Join-Path $chainRoot 'consents/component-rt-hip-1.0.json'))) 'the refused removal deleted nothing (files and receipt stay)'
    Check ((Remove-FastLlmComponent -ComponentsPath $linksFx.ComponentsPath -ComponentId 'eng-hip' -InstallRoot $chainRoot) -and -not (Test-Path -LiteralPath $engineRootActual)) 'the engine can be removed while its runtime stays'
    Check ((Remove-FastLlmComponent -ComponentsPath $linksFx.ComponentsPath -ComponentId 'rt-hip' -InstallRoot $chainRoot) -and -not (Test-Path -LiteralPath $runtimeRootExpected)) 'after the engine is removed the runtime can be removed'

    # ---- Failures: member hash mismatch, missing manifest member, required install fails first ----
    $badFx = New-ChainFixture -Name 'fx-chain-badhash' -BadHashPath 'bin/lib/x.dat'
    $badRoot = New-TestRoot
    $badState = New-ChainState
    $badFailure = Get-ThrownFailure { Install-FastLlmComponent -ComponentsPath $badFx.ComponentsPath -ComponentId 'eng-hip' -InstallRoot $badRoot -AcceptLicense -Download (New-ChainSeam -Fixture $badFx -State $badState) }
    Check ($null -ne $badFailure -and $badFailure.code -ceq 'component-archive-member-mismatch') 'a member whose SHA-256 differs from the pin is refused with a typed failure'
    $quarantineDir = [System.IO.Path]::Combine($badRoot, 'downloads', 'c')
    Check (@(Get-ChildItem -LiteralPath $quarantineDir -Force -File | Where-Object { $_.Name -like 'x.dat.corrupt.*' }).Count -eq 1) 'the bad member is quarantined next to the download cache (it survives the refusal)'
    Check ((-not (Test-Path -LiteralPath (Join-Path $badRoot 'components/runtime'))) -and -not (Test-Path -LiteralPath (Join-Path $badRoot 'components/.s'))) 'a mismatched member leaves no component folder and no staging'
    Check (-not ($badState.log -contains $badFx.EngineUrl)) 'the engine is never downloaded when its required runtime fails'
    $missingFx = New-ChainFixture -Name 'fx-chain-missing' -MissingPath 'bin/not-in-archive.dll'
    $missingRoot = New-TestRoot
    $missingFailure = Get-ThrownFailure { Install-FastLlmComponent -ComponentsPath $missingFx.ComponentsPath -ComponentId 'rt-hip' -InstallRoot $missingRoot -AcceptLicense -Download (New-ChainSeam -Fixture $missingFx -State (New-ChainState)) }
    Check ($null -ne $missingFailure -and $missingFailure.code -ceq 'component-archive-member-missing' -and -not (Test-Path -LiteralPath (Join-Path $missingRoot 'components/runtime'))) 'a manifest member missing from the archive is a typed failure and installs nothing'

    # ---- Consent: declined and unattended chains download nothing ----
    $showFx = New-ChainFixture -Name 'fx-chain-show' -Consent 'show'
    $declineRoot = New-TestRoot
    $declineState = New-ChainState
    $declineQuestions = New-Object 'System.Collections.Generic.List[string]'
    $declineAnswer = { param($q) $declineQuestions.Add($q); 'n' }.GetNewClosure()
    Set-ConsentHook $declineAnswer
    try { $declined = Get-ThrownFailure { Install-FastLlmComponent -ComponentsPath $showFx.ComponentsPath -ComponentId 'eng-hip' -InstallRoot $declineRoot -Download (New-ChainSeam -Fixture $showFx -State $declineState) } }
    finally { Set-ConsentHook $null }
    Check ($null -ne $declined -and $declined.code -ceq 'component-consent-declined' -and $declined.message -like "*'rt-hip'*" -and $declined.message -like "*'eng-hip'*") 'a declined chain is a typed failure naming both components'
    Check ($declineState.log.Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $declineRoot 'components')) -and -not (Test-Path -LiteralPath (Join-Path $declineRoot 'downloads'))) 'a declined chain downloads nothing and creates nothing'
    Check ($declineQuestions.Count -eq 1 -and $declineQuestions[0] -like "*'rt-hip'*" -and $declineQuestions[0] -like "*'eng-hip'*") 'the chain is asked once, naming every component'
    $yesRoot = New-TestRoot
    $yesState = New-ChainState
    Set-ConsentHook { param($q) 'y' }
    try { $null = Install-FastLlmComponent -ComponentsPath $showFx.ComponentsPath -ComponentId 'eng-hip' -InstallRoot $yesRoot -Download (New-ChainSeam -Fixture $showFx -State $yesState) }
    finally { Set-ConsentHook $null }
    Check ($yesState.log.Count -eq 3 -and (Test-FastLlmComponentInstallation -InstallRoot $yesRoot -Component (Get-ComponentEntry $showFx.ComponentsPath 'eng-hip')) -and -not (Test-Path -LiteralPath (Join-Path $yesRoot 'consents'))) 'an approved show-type chain installs both and writes no receipts (positive control)'
    $unRoot = New-TestRoot
    $unState = New-ChainState
    $unFailure = Get-ThrownFailure { Install-FastLlmComponent -ComponentsPath $showFx.ComponentsPath -ComponentId 'eng-hip' -InstallRoot $unRoot -Unattended -Download (New-ChainSeam -Fixture $showFx -State $unState) }
    Check ($null -ne $unFailure -and $unFailure.code -ceq 'component-consent-required' -and $unFailure.message -like "*'rt-hip'*" -and $unFailure.message -like "*'eng-hip'*" -and $unFailure.message -like '*-AcceptLicense*') 'an unattended chain without -AcceptLicense is component-consent-required, naming both components'
    Check ($unState.log.Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $unRoot 'components')) -and -not (Test-Path -LiteralPath (Join-Path $unRoot 'consents'))) 'an unattended refusal downloads nothing and writes nothing'
    $acceptFx = New-ChainFixture -Name 'fx-chain-accept-nosw'
    $acceptRoot = New-TestRoot
    $acceptState = New-ChainState
    Set-ConsentHook { param($q) 'y' }
    try { $acceptFailure = Get-ThrownFailure { Install-FastLlmComponent -ComponentsPath $acceptFx.ComponentsPath -ComponentId 'eng-hip' -InstallRoot $acceptRoot -Download (New-ChainSeam -Fixture $acceptFx -State $acceptState) } }
    finally { Set-ConsentHook $null }
    Check ($null -ne $acceptFailure -and $acceptFailure.code -ceq 'component-consent-required' -and $acceptFailure.message -like "*'rt-hip'*" -and $acceptFailure.message -like "*'eng-hip'*" -and $acceptFailure.message -like '*fast-llm.ps1 components -Install eng-hip -AcceptLicense*' -and $acceptState.log.Count -eq 0) 'accept-type components never install on a console answer: component-consent-required names both and points at -AcceptLicense, with no download'
    Check (-not (Test-Path -LiteralPath (Join-Path $acceptRoot 'consents'))) 'a refused accept chain writes no receipt'

    # A real child process (redirected stdin) never prompts: it gets the typed refusal instead of Read-Host.
    $childScript = Join-Path $work 'child-consent.ps1'
    [System.IO.File]::WriteAllText($childScript, @'
param([string] $ModulePath, [string] $ComponentsPath, [string] $InstallRoot)
$ErrorActionPreference = 'Stop'
Import-Module $ModulePath -Force
$m = Get-Module FastLlm
Write-Output ('INTERACTIVE=' + (& $m { Test-FastLlmConsoleInteractive }))
try { Install-FastLlmComponent -ComponentsPath $ComponentsPath -ComponentId 'eng-hip' -InstallRoot $InstallRoot | Out-Null; Write-Output 'RESULT=installed' }
catch { Write-Output ('RESULT=' + $_.Exception.Data['FastLlmFailureCode']) }
'@)
    # A short install root: the real downloader's derived names (no seam in a child) need room under the 259-character limit.
    $childRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('c3c' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
    $childInfo = New-Object System.Diagnostics.ProcessStartInfo
    $childInfo.FileName = (Get-Process -Id $PID).Path
    $childInfo.Arguments = '-NoProfile -File "' + $childScript + '" -ModulePath "' + $modulePath + '" -ComponentsPath "' + $showFx.ComponentsPath + '" -InstallRoot "' + $childRoot + '"'
    $childInfo.UseShellExecute = $false
    $childInfo.RedirectStandardInput = $true
    $childInfo.RedirectStandardOutput = $true
    $childInfo.RedirectStandardError = $true
    $childProcess = [System.Diagnostics.Process]::Start($childInfo)
    $childProcess.StandardInput.Close()
    $childOutputTask = $childProcess.StandardOutput.ReadToEndAsync()
    if (-not $childProcess.WaitForExit(120000)) { try { $childProcess.Kill() } catch { } }
    $childOutput = $childOutputTask.Result
    Check ($childOutput -match 'INTERACTIVE=False' -and $childOutput -match 'RESULT=component-consent-required') 'a child process with redirected input is not interactive and gets component-consent-required (no Read-Host)'
    Check (-not (Test-Path -LiteralPath (Join-Path $childRoot 'components')) -and -not (Test-Path -LiteralPath (Join-Path $childRoot 'downloads'))) 'the child refusal downloaded nothing'
    Remove-Item -LiteralPath $childRoot -Recurse -Force -ErrorAction SilentlyContinue

    # ---- MAX_PATH: refused before any download ----
    $deepSegments = @(1..5 | ForEach-Object { 'segment-number-' + $_ + '-xxxxxxxxxxxx' })
    $deepPath = ($deepSegments -join '/') + '/lib.dll'
    $deepDir = Join-Path $work 'fx-deep'
    $deepPart = New-ArchivePart -Dir $deepDir -Name 'deep.whl' -Prefix 'p/' -Files ([ordered] @{ $deepPath = 'deep' })
    $deepComponent = New-TreeComponent -Id 'rt-deep' -Parts @($deepPart.part)
    $deepDoc = Write-ComponentsDoc @($deepComponent)
    $deepEntry = Get-ComponentEntry $deepDoc 'rt-deep'
    $deepState = New-ChainState
    $deepFx = [pscustomobject] @{ ZipByUrl = @{ $deepPart.url = $deepPart.zip } }
    $longRoot = Join-Path $work (('long-install-folder-' * 4))
    $tooLong = Get-ThrownFailure { Install-FastLlmComponent -ComponentsPath $deepDoc -ComponentId 'rt-deep' -InstallRoot $longRoot -AcceptLicense -Download (New-ChainSeam -Fixture $deepFx -State $deepState) }
    Check ($deepPath.Length -ge 140 -and $null -ne $tooLong -and $tooLong.code -ceq 'component-path-too-long') 'a long manifest path under a long install root is refused as component-path-too-long'
    Check ($deepState.log.Count -eq 0 -and -not (Test-Path -LiteralPath $longRoot)) 'the path-too-long refusal happens before any download and creates nothing'
    $shallowDir = Join-Path $work 'fx-shallow'
    $shallowPart = New-ArchivePart -Dir $shallowDir -Name 'shallow.whl' -Prefix 'p/' -Files ([ordered] @{ 'a/b.dll' = 'shallow' })
    $shallowDoc = Write-ComponentsDoc @((New-TreeComponent -Id 'rt-shallow' -Parts @($shallowPart.part)))
    $shallowFx = [pscustomobject] @{ ZipByUrl = @{ $shallowPart.url = $shallowPart.zip } }
    $shallowState = New-ChainState
    $shortRoot = Join-Path $work 's'
    $shallowOk = Get-ThrownFailure { Install-FastLlmComponent -ComponentsPath $shallowDoc -ComponentId 'rt-shallow' -InstallRoot $shortRoot -AcceptLicense -Download (New-ChainSeam -Fixture $shallowFx -State $shallowState) }
    Check ($null -eq $shallowOk -and $shallowState.log.Count -eq 1) 'a component with short paths installs under a short install root (positive control)'

    # ---- inventory and resolution never hash; Full still does ----
    $presenceFx = New-Fixture -Dir (Join-Path $work 'fx-presence') -Id 'presence-engine'
    $presenceRoot = New-TestRoot
    $null = Install-Fixture -Fixture $presenceFx -InstallRoot $presenceRoot -Counter @{ count = 0 } -AcceptLicense -Unattended
    $presenceList = @(Get-FastLlmComponents -ComponentsPath $presenceFx.ComponentsPath)
    $presenceRecipe = [pscustomobject] @{ id = 'rm'; components = [pscustomobject] @{ engine = 'presence-engine'; model = 'm' } }
    & $module { $script:FastLlmFileHashCalls = 0 }
    $presenceInventory = @(Get-FastLlmComponentInventory -ComponentsPath $presenceFx.ComponentsPath -InstallRoot $presenceRoot)
    $presenceResolved = & $module { param($R, $C, $L, $I) Resolve-FastLlmRecipeEngine -Recipe $R -Catalog $C -Components $L -InstallRoot $I } $presenceRecipe $resolveCatalog $presenceList $presenceRoot
    $hashCallsAfterPresence = & $module { $script:FastLlmFileHashCalls }
    Check ($presenceInventory[0].installed -and $presenceInventory[0].verified -and $presenceResolved.installed) 'inventory and recipe resolution report an installed component as verified'
    Check ($hashCallsAfterPresence -eq 0) 'inventory and recipe resolution perform no hashing (the hash counter stays at 0)'
    Check (Test-FastLlmComponentInstallation -InstallRoot $presenceRoot -Component $presenceList[0]) 'the Full check passes on the same root (positive control)'
    $hashCallsAfterFull = & $module { $script:FastLlmFileHashCalls }
    Check ($hashCallsAfterFull -eq 2) 'the Full check hashes every file (2 of 2): the counter proves it is the thing being counted'
    $recipesSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../src/FastLlm.Recipes.ps1') -Raw
    Check ($recipesSource -match 'Test-FastLlmComponentInstallation -InstallRoot \$InstallRoot -Component \$component -Depth Presence') 'Resolve-FastLlmRecipeEngine checks components at Depth Presence'
    Check ($moduleSourceEarly -match 'Test-FastLlmComponentInstallation -InstallRoot \$InstallRoot -Component \$entry -Depth Presence') 'Get-FastLlmComponentInventory checks components at Depth Presence'
    Check ($moduleSourceEarly -match 'Get-FastLlmFirstUnavailableComponent -Components \$startComponents -EngineId \$planComponentId -InstallRoot \$InstallRoot -Depth Full' -and $recipesSource -match 'Test-FastLlmComponentInstallation -InstallRoot \$InstallRoot -Component \$chained -Depth \$Depth') 'Start-FastLlmServer keeps the Full check (it passes -Depth Full through the chain helper)'

    # ---- Streaming: no whole-archive or whole-entry API on the extraction path ----
    $extractSource = [regex]::Match($moduleSourceEarly, '(?s)function Expand-FastLlmComponentArchivePart \{.*?\r?\n\}\r?\n').Value
    $filesSource = [regex]::Match($moduleSourceEarly, '(?s)function Install-FastLlmComponentFiles \{.*?\r?\n\}\r?\n').Value
    Check ($extractSource.Length -gt 500 -and $filesSource.Length -gt 500 -and $extractSource.Contains('[System.IO.Compression.ZipFile]::OpenRead') -and $extractSource.Contains('.Open()') -and $extractSource.Contains('Copy-FastLlmBoundedStream') -and $moduleSourceEarly.Contains('$Source.Read($buffer, 0, $want)')) 'zip-tree extraction streams: ZipFile.OpenRead, entry.Open() and a bounded buffered copy to the FileStream'
    Check (($extractSource + $filesSource + $installSource) -notmatch 'Expand-Archive|ExtractToDirectory|ExtractToFile|ReadAllBytes|ReadAllText|ReadToEnd|\.ToArray\(\)\s*\|') 'the install path calls no whole-archive or whole-entry API'
    Check (([regex]::Matches($installSource, 'Read-Host')).Count -eq 1 -and $installSource.Contains('Test-FastLlmConsoleInteractive') -and $installSource.IndexOf('Test-FastLlmConsoleInteractive') -lt $installSource.IndexOf('Read-Host')) 'Read-Host is reached only after the interactive check'

    # ---- Fix round 1 ----
    # A reparse point for the link tests: a symbolic link, or (a standard Windows user cannot create those) a directory junction.
    function New-TestLink([string] $Path, [string] $Target) {
        try { New-Item -ItemType SymbolicLink -Path $Path -Target $Target -ErrorAction Stop | Out-Null; return $true } catch { }
        try { New-Item -ItemType Junction -Path $Path -Target $Target -ErrorAction Stop | Out-Null; return $true } catch { }
        return $false
    }
    $linkProbeDir = New-TestRoot
    $canLink = New-TestLink -Path (Join-Path $linkProbeDir 'l') -Target $linkProbeDir
    # Links are removed with Directory.Delete (non-recursive, never follows the link); Remove-Item can prompt or follow on Windows PowerShell 5.1.
    if ($canLink) { [System.IO.Directory]::Delete((Join-Path $linkProbeDir 'l')) }
    if (-not $canLink) { Write-Host 'SKIP: the reparse-point tests (links in the staging folder, the component tree, requirers and removal) - neither a symbolic link nor a junction could be created here' }
    $isUnix = [System.IO.Path]::DirectorySeparatorChar -eq '/'

    function New-Override($Url, $Path) { $table = @{}; $table[[string] $Url] = [string] $Path; return $table }
    # -- a replaced upstream part is a typed component-source-mismatch, quarantined, and nothing further is downloaded --
    $rf5Fx = New-ChainFixture -Name 'fx-rf5'
    $rf5Root = New-TestRoot
    $rf5State = New-ChainState
    $rf5Failure = Get-ThrownFailure { Install-FastLlmComponent -ComponentsPath $rf5Fx.ComponentsPath -ComponentId 'eng-hip' -InstallRoot $rf5Root -AcceptLicense -Download (New-ChainSeam -Fixture $rf5Fx -State $rf5State -Override (New-Override $rf5Fx.Part1Url $rf5Fx.ZipByUrl[$rf5Fx.EngineUrl])) }
    Check ($null -ne $rf5Failure -and $rf5Failure.code -ceq 'component-source-mismatch') 'a replaced first runtime part is the typed component-source-mismatch'
    Check ($rf5Failure.message -like "*'rt-hip'*" -and $rf5Failure.message -like "*$($rf5Fx.Part1Url)*" -and $rf5Failure.message -like '*expected*bytes*SHA-256*got*bytes*SHA-256*') 'the mismatch names the component, the part URL, and expected vs actual size and SHA-256'
    Check (($rf5State.log -join ',') -ceq $rf5Fx.Part1Url) 'nothing further is requested after the mismatched part (no second part, no engine)'
    $rf5Cache = [System.IO.Path]::Combine($rf5Root, 'downloads', 'c')
    $rf5Name = (Get-HexSha $rf5Fx.ZipByUrl[$rf5Fx.Part1Url]).Substring(0, 16) + '.whl'
    Check (@(Get-ChildItem -LiteralPath $rf5Cache -Force -File | Where-Object { $_.Name -like ($rf5Name + '.corrupt.*') }).Count -eq 1 -and @(Get-ChildItem -LiteralPath $rf5Cache -Force -File | Where-Object { $_.Name -ceq $rf5Name }).Count -eq 0) 'the replaced part is quarantined, not left in the cache'
    Check ((-not (Test-Path -LiteralPath (Join-Path $rf5Root 'components/runtime'))) -and (-not (Test-Path -LiteralPath (Join-Path $rf5Root 'components/engine'))) -and (-not (Test-Path -LiteralPath (Join-Path $rf5Root 'components/.s')))) 'a replaced part leaves no component folder and no staging'
    $rf5bState = New-ChainState
    $rf5bFailure = Get-ThrownFailure { Install-FastLlmComponent -ComponentsPath $rf5Fx.ComponentsPath -ComponentId 'eng-hip' -InstallRoot (New-TestRoot) -AcceptLicense -Download (New-ChainSeam -Fixture $rf5Fx -State $rf5bState -Override (New-Override $rf5Fx.Part2Url $rf5Fx.ZipByUrl[$rf5Fx.EngineUrl])) }
    Check ($null -ne $rf5bFailure -and $rf5bFailure.code -ceq 'component-source-mismatch' -and ($rf5bState.log -join ',') -ceq ($rf5Fx.Part1Url + ',' + $rf5Fx.Part2Url) -and $rf5bFailure.message -like '*part 2 of 2*') 'a replaced SECOND part is also typed, and the engine is never downloaded'
    $rf5cState = New-ChainState
    $taggedMismatch = & $module { New-FastLlmDownloadMismatchException -Message 'Downloaded artifact failed exact size/SHA-256 verification for x. The bad partial was quarantined.' }
    $taggedSeam = { param($Url, $Destination, $Sha256, $SizeBytes, $AllowedRedirectHosts) throw $taggedMismatch }.GetNewClosure()
    $rf5cFailure = Get-ThrownFailure { Install-FastLlmComponent -ComponentsPath $rf5Fx.ComponentsPath -ComponentId 'eng-hip' -InstallRoot (New-TestRoot) -AcceptLicense -Download $taggedSeam }
    Check ($null -ne $rf5cFailure -and $rf5cFailure.code -ceq 'component-source-mismatch' -and $rf5cFailure.message -like '*Downloaded artifact failed exact size/SHA-256 verification*') 'the downloader''s own tagged size/SHA-256 failure (Save-FastLlmVerifiedFile) becomes the typed failure with its message kept'
    $networkSeam = { param($Url, $Destination, $Sha256, $SizeBytes, $AllowedRedirectHosts) throw 'Download failed with curl exit code 6.' }
    $networkFailure = Get-ThrownFailure { Install-FastLlmComponent -ComponentsPath $rf5Fx.ComponentsPath -ComponentId 'eng-hip' -InstallRoot (New-TestRoot) -AcceptLicense -Download $networkSeam }
    Check ($null -ne $networkFailure -and $networkFailure.code -ne 'component-source-mismatch' -and $networkFailure.message -like '*curl exit code 6*') 'a network failure is not reported as a source mismatch'
    $saveSource = [regex]::Match($moduleSourceEarly, '(?s)function Save-FastLlmVerifiedFile \{.*?\r?\n\}\r?\n').Value
    Check ($saveSource.Contains('New-FastLlmDownloadMismatchException -Message "Downloaded artifact failed exact size/SHA-256') -and $saveSource.Contains('New-FastLlmDownloadMismatchException -Message "Download exceeded')) 'Save-FastLlmVerifiedFile tags its size and SHA-256 failures'

    # -- Partial-chain resume, and an existing receipt writes no new receipt --
    $resumeBad = New-ChainFixture -Name 'fx-resume-bad' -BadEngineHashPath 'server.exe'
    $resumeGood = New-ChainFixture -Name 'fx-resume-good'
    $resumeRoot = New-TestRoot
    $resumeState1 = New-ChainState
    $resumeFailure = Get-ThrownFailure { Install-FastLlmComponent -ComponentsPath $resumeBad.ComponentsPath -ComponentId 'eng-hip' -InstallRoot $resumeRoot -AcceptLicense -Download (New-ChainSeam -Fixture $resumeBad -State $resumeState1) }
    $resumeRuntimeEntry = Get-ComponentEntry $resumeGood.ComponentsPath 'rt-hip'
    Check ($null -ne $resumeFailure -and $resumeFailure.code -ceq 'component-archive-member-mismatch' -and (Test-FastLlmComponentInstallation -InstallRoot $resumeRoot -Component $resumeRuntimeEntry) -and -not (Test-Path -LiteralPath (Join-Path $resumeRoot 'components/engine'))) 'a failing engine leaves the already verified runtime installed and no engine folder'
    $receiptDir = Join-Path $resumeRoot 'consents'
    $receiptsBefore = @(Get-ChildItem -LiteralPath $receiptDir -File | Sort-Object Name | ForEach-Object { $_.Name + '=' + (Get-Content -LiteralPath $_.FullName -Raw) }) -join "`n"
    Start-Sleep -Milliseconds 1100
    $resumeState2 = New-ChainState
    $null = Install-FastLlmComponent -ComponentsPath $resumeGood.ComponentsPath -ComponentId 'eng-hip' -InstallRoot $resumeRoot -AcceptLicense -Download (New-ChainSeam -Fixture $resumeGood -State $resumeState2)
    Check (($resumeState2.log -join ',') -ceq $resumeGood.EngineUrl) 'rerunning the chain downloads only the missing engine (the verified runtime is not fetched again)'
    $receiptsAfter = @(Get-ChildItem -LiteralPath $receiptDir -File | Sort-Object Name | ForEach-Object { $_.Name + '=' + (Get-Content -LiteralPath $_.FullName -Raw) }) -join "`n"
    Check ($receiptsBefore -ceq $receiptsAfter -and @(Get-ChildItem -LiteralPath $receiptDir -File).Count -eq 2) 'with valid receipts in place, -AcceptLicense writes no new receipt (acceptedAt is unchanged)'

    # -- Pre-extraction member size mismatch --
    $sizeFx = New-ChainFixture -Name 'fx-wrongsize' -WrongSizePath 'bin/a.dll'
    $sizeRoot = New-TestRoot
    $sizeFailure = Get-ThrownFailure { Install-FastLlmComponent -ComponentsPath $sizeFx.ComponentsPath -ComponentId 'rt-hip' -InstallRoot $sizeRoot -AcceptLicense -Download (New-ChainSeam -Fixture $sizeFx -State (New-ChainState)) }
    Check ($null -ne $sizeFailure -and $sizeFailure.code -ceq 'component-archive-member-mismatch' -and $sizeFailure.message -like '*bytes, not the pinned*' -and -not (Test-Path -LiteralPath (Join-Path $sizeRoot 'components/runtime'))) 'a member whose archive size differs from the pin is refused before it is extracted'
    Check (@(Get-ChildItem -LiteralPath ([System.IO.Path]::Combine($sizeRoot, 'downloads', 'c')) -Force -File | Where-Object { $_.Name -like '*.corrupt.*' }).Count -eq 0) 'the pre-extraction size mismatch wrote nothing to quarantine (nothing was extracted)'

    # -- Bounded copy --
    $boundedSource = New-Object System.IO.MemoryStream(, ([byte[]] (1..100 | ForEach-Object { [byte] 7 })))
    $boundedDestination = New-Object System.IO.MemoryStream
    $boundedCopied = & $module { param($a, $b) Copy-FastLlmBoundedStream -Source $a -Destination $b -MaxBytes 50 } $boundedSource $boundedDestination
    Check ($boundedCopied -eq 51 -and $boundedDestination.Length -eq 51) 'the bounded copy stops at MaxBytes + 1 bytes (51 of 100), so an oversized member is detectable and never fills the disk'
    $boundedSource2 = New-Object System.IO.MemoryStream(, ([byte[]] (1..40 | ForEach-Object { [byte] 7 })))
    $boundedDestination2 = New-Object System.IO.MemoryStream
    $boundedCopied2 = & $module { param($a, $b) Copy-FastLlmBoundedStream -Source $a -Destination $b -MaxBytes 50 } $boundedSource2 $boundedDestination2
    Check ($boundedCopied2 -eq 40 -and $boundedDestination2.Length -eq 40) 'the bounded copy copies a member within its pin completely'

    # -- -NonInteractive --
    $niCheck = { param($a) & $module { param($x) Test-FastLlmNonInteractiveCommandLine -CommandLineArgs $x } $a }
    Check ((& $niCheck @('pwsh', '-NoProfile', '-NonInteractive', '-File', 'x.ps1')) -and (& $niCheck @('powershell.exe', '-noni')) -and (& $niCheck @('powershell.exe', '-NONINTERACTIVE')) -and (& $niCheck @('powershell.exe', '/NonInteractive'))) 'the command-line check sees -NonInteractive and its prefixes, in any case'
    Check ((-not (& $niCheck @('pwsh', '-NoProfile', '-File', 'x.ps1'))) -and (-not (& $niCheck @('pwsh', '-NoExit', '-NoLogo', '-NoProfile')))) 'the command-line check does not fire on -NoProfile, -NoExit or -NoLogo'
    $interactiveWith = { param($a) & $module { param($x) Test-FastLlmConsoleInteractive -CommandLineArgs $x -UserInteractive $true -InputRedirected $false } $a }
    Check ((& $interactiveWith @('pwsh', '-NoProfile', '-File', 'x.ps1')) -eq $true) 'with an interactive session and a console input, the console counts as interactive (control)'
    Check (((& $interactiveWith @('pwsh', '-NonInteractive', '-File', 'x.ps1')) -eq $false) -and ((& $interactiveWith @('powershell.exe', '-NoProfile', '-noni')) -eq $false) -and ((& $interactiveWith @('powershell.exe', '-NONI')) -eq $false)) 'Test-FastLlmConsoleInteractive is false whenever the command line has -NonInteractive or -noni, even with an interactive session and a console input'
    $productChildRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('c3p' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
    $productInfo = New-Object System.Diagnostics.ProcessStartInfo
    $productInfo.FileName = (Get-Process -Id $PID).Path
    $productInfo.Arguments = '-NoProfile -NonInteractive -File "' + $childScript + '" -ModulePath "' + $modulePath + '" -ComponentsPath "' + $showFx.ComponentsPath + '" -InstallRoot "' + $productChildRoot + '"'
    $productInfo.UseShellExecute = $false
    $productInfo.CreateNoWindow = $true
    $productInfo.RedirectStandardOutput = $true
    $productInfo.RedirectStandardError = $true
    $productProcess = [System.Diagnostics.Process]::Start($productInfo)
    $productOutputTask = $productProcess.StandardOutput.ReadToEndAsync()
    if (-not $productProcess.WaitForExit(120000)) { try { $productProcess.Kill() } catch { } }
    $productOutput = $productOutputTask.Result
    Check ($productOutput -match 'INTERACTIVE=False' -and $productOutput -match 'RESULT=component-consent-required') 'a child started the way the product starts them (-NonInteractive, stdin NOT redirected, no window) gets component-consent-required'
    Check (-not (Test-Path -LiteralPath (Join-Path $productChildRoot 'components')) -and -not (Test-Path -LiteralPath (Join-Path $productChildRoot 'downloads'))) 'the product-shaped child refusal downloaded nothing'
    Check ($moduleSourceEarly -match "catch \[System\.Management\.Automation\.PSInvalidOperationException\]" -and $installSource.Contains('PSInvalidOperationException')) 'Read-Host has a typed backstop for a session that cannot prompt'

    # -- The console-answer hook never overrides -Unattended --
    $hookCalls = New-Object 'System.Collections.Generic.List[string]'
    Set-ConsentHook ({ param($q) $hookCalls.Add($q); 'y' }.GetNewClosure())
    $hookState = New-ChainState
    try { $hookFailure = Get-ThrownFailure { Install-FastLlmComponent -ComponentsPath $showFx.ComponentsPath -ComponentId 'eng-hip' -InstallRoot (New-TestRoot) -Unattended -Download (New-ChainSeam -Fixture $showFx -State $hookState) } }
    finally { Set-ConsentHook $null }
    Check ($null -ne $hookFailure -and $hookFailure.code -ceq 'component-consent-required' -and $hookCalls.Count -eq 0 -and $hookState.log.Count -eq 0) '-Unattended wins over the console-answer hook: refused, the hook is never asked, nothing is downloaded'
    Check (-not $installSource.Contains('[scriptblock] $ConsentPrompt') -and (Get-Command Install-FastLlmComponent).Parameters.ContainsKey('ConsentPrompt') -eq $false) 'the console-answer seam is not a public parameter'

    # -- Refusal wording: who must accept, separately from the whole chain --
    $wordFx = New-ChainFixture -Name 'fx-wording'
    $wordRoot = New-TestRoot
    $null = Install-FastLlmComponent -ComponentsPath $wordFx.ComponentsPath -ComponentId 'rt-hip' -InstallRoot $wordRoot -AcceptLicense -Download (New-ChainSeam -Fixture $wordFx -State (New-ChainState))
    Remove-Item -LiteralPath (Join-Path $wordRoot 'consents/component-eng-hip-1.0.json') -Force -ErrorAction SilentlyContinue
    $wordFailure = Get-ThrownFailure { Install-FastLlmComponent -ComponentsPath $wordFx.ComponentsPath -ComponentId 'eng-hip' -InstallRoot $wordRoot -Download (New-ChainSeam -Fixture $wordFx -State (New-ChainState)) }
    Check ($null -ne $wordFailure -and $wordFailure.code -ceq 'component-consent-required' -and $wordFailure.message -like "*accept the license of: 'eng-hip'*" -and $wordFailure.message -notlike "*accept the license of: *'rt-hip'*(links above)*" -and $wordFailure.message -like "*whole chain is: 'rt-hip' (already installed), 'eng-hip'*") 'the refusal names who must accept separately from the whole chain, which lists an installed member as such'

    # -- Repair guidance when a required root is tampered and something installed requires it --
    $repairRoot = New-TestRoot
    $repairFx = New-ChainFixture -Name 'fx-repair'
    $null = Install-FastLlmComponent -ComponentsPath $repairFx.ComponentsPath -ComponentId 'eng-hip' -InstallRoot $repairRoot -AcceptLicense -Download (New-ChainSeam -Fixture $repairFx -State (New-ChainState))
    $repairRuntimeRoot = Get-FastLlmComponentRoot -InstallRoot $repairRoot -Component (Get-ComponentEntry $repairFx.ComponentsPath 'rt-hip')
    Remove-Item -LiteralPath (Join-Path $repairRuntimeRoot 'bin/b.dll') -Force
    $repairFailure = Get-ThrownFailure { Install-FastLlmComponent -ComponentsPath $repairFx.ComponentsPath -ComponentId 'eng-hip' -InstallRoot $repairRoot -AcceptLicense -Download (New-ChainSeam -Fixture $repairFx -State (New-ChainState)) }
    $removeEngineAt = if ($null -ne $repairFailure) { $repairFailure.message.IndexOf('components -Remove eng-hip') } else { -1 }
    $removeRuntimeAt = if ($null -ne $repairFailure) { $repairFailure.message.IndexOf('components -Remove rt-hip') } else { -1 }
    $installAt = if ($null -ne $repairFailure) { $repairFailure.message.IndexOf('components -Install eng-hip') } else { -1 }
    Check ($null -ne $repairFailure -and $repairFailure.code -ceq 'component-root-unverified' -and $removeEngineAt -ge 0 -and $removeEngineAt -lt $removeRuntimeAt -and $removeRuntimeAt -lt $installAt) 'a tampered required runtime with the engine installed gets the whole repair sequence in one message: remove the engine, remove the runtime, install again'
    $plainRepair = Get-ThrownFailure { Install-FastLlmComponent -ComponentsPath $repairFx.ComponentsPath -ComponentId 'rt-hip' -InstallRoot $repairRoot -AcceptLicense -Download (New-ChainSeam -Fixture $repairFx -State (New-ChainState)) }
    Check ($null -ne $plainRepair -and $plainRepair.code -ceq 'component-root-unverified' -and $plainRepair.message -like '*components -Remove eng-hip*') 'the typed component-root-unverified also covers installing the runtime itself'

    # -- Installed chain exposure (-PassThru) and the CLI --
    $ptFx = New-ChainFixture -Name 'fx-passthru'
    $ptRoot = New-TestRoot
    $ptResult = Install-FastLlmComponent -ComponentsPath $ptFx.ComponentsPath -ComponentId 'eng-hip' -InstallRoot $ptRoot -AcceptLicense -PassThru -Download (New-ChainSeam -Fixture $ptFx -State (New-ChainState)) 6>$null
    Check ((@($ptResult.installed | ForEach-Object { $_.id }) -join ',') -ceq 'rt-hip,eng-hip' -and $ptResult.root -ceq (Get-FastLlmComponentRoot -InstallRoot $ptRoot -Component (Get-ComponentEntry $ptFx.ComponentsPath 'eng-hip')) -and $ptResult.installed[0].path -like '*rt-hip*') '-PassThru lists each newly installed component (required first) with its path, and the requested root'
    $ptAgain = Install-FastLlmComponent -ComponentsPath $ptFx.ComponentsPath -ComponentId 'eng-hip' -InstallRoot $ptRoot -AcceptLicense -PassThru -Download (New-ChainSeam -Fixture $ptFx -State (New-ChainState))
    Check (@($ptAgain.installed).Count -eq 0 -and $ptAgain.root -ceq $ptResult.root) '-PassThru on an installed chain lists nothing as newly installed'
    $cliText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../fast-llm.ps1') -Raw
    Check ($cliText.Contains('-PassThru') -and $cliText.Contains('installedComponents = @($installResult.installed)') -and $cliText.Contains('foreach ($newlyInstalled in @($installResult.installed))')) 'components -Install prints one line per newly installed component and adds installedComponents to -AsJson'
    Check ($cliText -match "\`$Action -eq 'components' -and \(\`$PSBoundParameters\.ContainsKey\('Install'\) -or \`$PSBoundParameters\.ContainsKey\('Remove'\)\)\)\s*\{\s*\`$componentsLock = Enter-FastLlmOperation") 'components -Install and -Remove take the operation lock'

    # -- License display: one line per distinct URL --
    $shippedEngineLines = @(Get-FastLlmComponentLicenseLinks -Component $hipEngine)
    $shippedRuntimeLines = @(Get-FastLlmComponentLicenseLinks -Component $hipRuntime)
    Check ($shippedEngineLines.Count -eq 3 -and @($shippedEngineLines.url | Select-Object -Unique).Count -eq 3) 'the shipped HIP engine shows 3 distinct license lines (the duplicate URL is gone)'
    Check ($shippedRuntimeLines.Count -eq 2 -and $shippedRuntimeLines[0].title -ceq 'AMD Software End User License Agreement' -and $shippedRuntimeLines[0].title -cne 'proprietary') 'the shipped runtime shows 2 license lines, the first titled with the link title and not "proprietary"'
    Check (@($shippedEngineLines | Where-Object { $_.title -ceq 'MIT' }).Count -eq 0 -and $shippedEngineLines[0].title -ceq 'llama.cpp license (MIT)') 'the link title wins over the SPDX id when both carry the same URL'
    $dupLicense = [ordered] @{ spdx = 'MIT'; url = 'https://example.com/L'; consent = 'show'; links = @([ordered] @{ title = 'Mixed'; url = 'https://example.com/L' }, [ordered] @{ title = 'Other'; url = 'https://example.com/l' }, [ordered] @{ title = 'Again'; url = 'https://example.com/L' }) }
    $dupDoc = Write-ComponentsDoc @((New-TreeComponent -Id 'rt-dup' -Parts @($okPart) -License $dupLicense))
    $dupEntry = Get-ComponentEntry $dupDoc 'rt-dup'
    $dupLines = @(Get-FastLlmComponentLicenseLinks -Component $dupEntry)
    Check ($dupLines.Count -eq 2 -and $dupLines[0].title -ceq 'Mixed' -and $dupLines[1].url -ceq 'https://example.com/l') 'duplicates are removed by exact (case-sensitive) URL: the first title is kept and a URL that differs only in case stays'
    $dupReceiptLinks = @(& $module { param($c) Get-FastLlmComponentLicenseLinkEntries -Component $c } $dupEntry)
    Check ($dupReceiptLinks.Count -eq 3 -and (& $module { param($c) Get-FastLlmComponentLicenseUrlOrNull -Component $c } $dupEntry) -ceq 'https://example.com/L') 'the receipt helpers keep the raw license.url and every link (display-only dedupe)'

    # -- MAX_PATH boundaries --
    $boundaryBase = Join-Path ([System.IO.Path]::GetTempPath()) ('c3b' + [Guid]::NewGuid().ToString('N').Substring(0, 4))
    function New-BoundaryRoot([int] $ComponentRootLength, [string] $Id) {
        $probeRoot = Join-Path $boundaryBase 'p'
        $probeComponent = [pscustomobject] @{ kind = 'runtime'; id = $Id; version = '1.0' }
        $suffix = (Get-FastLlmComponentRoot -InstallRoot $probeRoot -Component $probeComponent).Length - [System.IO.Path]::GetFullPath($probeRoot).Length
        $installRootLength = $ComponentRootLength - $suffix
        $fixed = [System.IO.Path]::GetFullPath($boundaryBase).Length + 1
        $pad = $installRootLength - $fixed
        return (Join-Path $boundaryBase ('d' * $pad))
    }
    $segmentList = New-Object 'System.Collections.Generic.List[string]'
    foreach ($segmentIndex in 1..5) { $segmentList.Add('seg' + $segmentIndex + ('x' * 21)) }
    $fileDirectory = $segmentList -join '/'
    $filePath = $fileDirectory + '/leafleafleaf.dll'
    $fileComponentPart = New-ArchivePart -Dir (Join-Path $work 'fx-b-file') -Name 'b.whl' -Prefix 'p/' -Files ([ordered] @{ $filePath = 'b' })
    $fileDoc = Write-ComponentsDoc @((New-TreeComponent -Id 'rt-bound-file' -Parts @($fileComponentPart.part)))
    $fileFx = [pscustomobject] @{ ZipByUrl = @{ $fileComponentPart.url = $fileComponentPart.zip } }
    foreach ($case in @(@{ length = 259; allowed = $true }, @{ length = 260; allowed = $false })) {
        $boundaryInstall = New-BoundaryRoot -ComponentRootLength ($case.length - 1 - $filePath.Length) -Id 'rt-bound-file'
        $boundaryEntry = Get-ComponentEntry $fileDoc 'rt-bound-file'
        $actual = (Get-FastLlmComponentRoot -InstallRoot $boundaryInstall -Component $boundaryEntry).Length + 1 + $filePath.Length
        $boundaryState = New-ChainState
        $boundaryResult = Get-ThrownFailure { Install-FastLlmComponent -ComponentsPath $fileDoc -ComponentId 'rt-bound-file' -InstallRoot $boundaryInstall -AcceptLicense -Download (New-ChainSeam -Fixture $fileFx -State $boundaryState) }
        if ($case.allowed) { Check ($actual -eq 259 -and $null -eq $boundaryResult -and $boundaryState.log.Count -eq 1) 'a longest file path of exactly 259 characters is accepted' }
        else { Check ($actual -eq 260 -and $null -ne $boundaryResult -and $boundaryResult.code -ceq 'component-path-too-long' -and $boundaryResult.message -like '*file path of 260 characters*limit of 259*' -and $boundaryState.log.Count -eq 0) 'a longest file path of 260 characters is refused before any download, naming the file limit' }
        Remove-Item -LiteralPath $boundaryInstall -Recurse -Force -ErrorAction SilentlyContinue
    }
    $dirSegments = New-Object 'System.Collections.Generic.List[string]'
    foreach ($segmentIndex in 1..6) { $dirSegments.Add('dir' + $segmentIndex + ('y' * 20)) }
    $dirOnly = $dirSegments -join '/'
    $dirFilePath = $dirOnly + '/x'
    $dirPart = New-ArchivePart -Dir (Join-Path $work 'fx-b-dir') -Name 'd.whl' -Prefix 'p/' -Files ([ordered] @{ $dirFilePath = 'd' })
    $dirDoc = Write-ComponentsDoc @((New-TreeComponent -Id 'rt-bound-dir' -Parts @($dirPart.part)))
    $dirFx = [pscustomobject] @{ ZipByUrl = @{ $dirPart.url = $dirPart.zip } }
    foreach ($case in @(@{ length = 247; allowed = $true }, @{ length = 248; allowed = $false })) {
        $boundaryInstall = New-BoundaryRoot -ComponentRootLength ($case.length - 1 - $dirOnly.Length) -Id 'rt-bound-dir'
        $boundaryEntry = Get-ComponentEntry $dirDoc 'rt-bound-dir'
        $actual = (Get-FastLlmComponentRoot -InstallRoot $boundaryInstall -Component $boundaryEntry).Length + 1 + $dirOnly.Length
        $boundaryState = New-ChainState
        $boundaryResult = Get-ThrownFailure { Install-FastLlmComponent -ComponentsPath $dirDoc -ComponentId 'rt-bound-dir' -InstallRoot $boundaryInstall -AcceptLicense -Download (New-ChainSeam -Fixture $dirFx -State $boundaryState) }
        if ($case.allowed) { Check ($actual -eq 247 -and $null -eq $boundaryResult -and $boundaryState.log.Count -eq 1) 'a deepest folder path of exactly 247 characters is accepted' }
        else { Check ($actual -eq 248 -and $null -ne $boundaryResult -and $boundaryResult.code -ceq 'component-path-too-long' -and $boundaryResult.message -like '*folder path of 248 characters*limit of 247*' -and $boundaryState.log.Count -eq 0) 'a deepest folder path of 248 characters is refused before any download, naming the folder limit' }
        Remove-Item -LiteralPath $boundaryInstall -Recurse -Force -ErrorAction SilentlyContinue
    }
    # Derived names: with the real downloader (no -Download seam) its partial/quarantine names add up to 90 characters to the cache path.
    $derivedPart = New-ArchivePart -Dir (Join-Path $work 'fx-b-derived') -Name 'q.whl' -Prefix 'p/' -Files ([ordered] @{ 'a.dll' = 'q' })
    $derivedDoc = Write-ComponentsDoc @((New-TreeComponent -Id 'rt-bound-derived' -Parts @($derivedPart.part)))
    $derivedEntry = Get-ComponentEntry $derivedDoc 'rt-bound-derived'
    $probeCache = & $module { param($r, $c) @((Get-FastLlmComponentCachePaths -Component $c -InstallRoot $r).paths)[0] } (Join-Path $boundaryBase 'p') $derivedEntry
    # The cache file name keeps only the URL's extension, and that extension must still make a simple leaf name.
    $hostilePart = New-TreePart -Paths @('bin/a.dll')
    $hostilePart.url = 'https://example.com/dl/x.z%3Aip'
    $hostileEntry = Get-ComponentEntry (Write-ComponentsDoc @((New-TreeComponent -Id 'rt-hostile-ext' -Parts @($hostilePart)))) 'rt-hostile-ext'
    $hostileMessage = Get-ThrownMessage { & $module { param($r, $c) Get-FastLlmComponentCachePaths -Component $c -InstallRoot $r } (Join-Path $boundaryBase 'h') $hostileEntry }
    Check ($null -ne $hostileMessage -and $hostileMessage -like '*Component download file name*') 'a source URL whose extension is not a simple leaf name is refused for the cache path'
    $cacheSuffix = $probeCache.Length - [System.IO.Path]::GetFullPath((Join-Path $boundaryBase 'p')).Length
    foreach ($case in @(@{ total = 259; allowed = $true }, @{ total = 260; allowed = $false })) {
        $wantRoot = $case.total - 90 - $cacheSuffix
        $derivedInstall = Join-Path $boundaryBase ('e' * ($wantRoot - ([System.IO.Path]::GetFullPath($boundaryBase).Length + 1)))
        $derivedResult = Get-ThrownFailure { & $module { param($c, $r) Assert-FastLlmComponentPathLength -Component $c -InstallRoot $r -DownloaderNames } $derivedEntry $derivedInstall }
        if ($case.allowed) { Check ($null -eq $derivedResult) 'with the real downloader, a download path whose quarantine name just fits (259) is accepted' }
        else { Check ($null -ne $derivedResult -and $derivedResult.code -ceq 'component-path-too-long' -and $derivedResult.message -like '*download quarantine path*260 characters*') 'with the real downloader, a download path whose quarantine name would be 260 is refused, naming that limit' }
        $withoutDownloaderNames = Get-ThrownFailure { & $module { param($c, $r) Assert-FastLlmComponentPathLength -Component $c -InstallRoot $r } $derivedEntry $derivedInstall }
        Check ($null -eq $withoutDownloaderNames) 'without the real downloader (a test seam) the downloader-name limit is not applied'
    }
    # The real install without a seam is refused up front (and downloads nothing) when the downloader's names would not fit.
    $realRoot = Join-Path $boundaryBase ('e' * (260 - 90 - $cacheSuffix - ([System.IO.Path]::GetFullPath($boundaryBase).Length + 1)))
    $realRefusal = Get-ThrownFailure { Install-FastLlmComponent -ComponentsPath $derivedDoc -ComponentId 'rt-bound-derived' -InstallRoot $realRoot -AcceptLicense }
    Check ($null -ne $realRefusal -and $realRefusal.code -ceq 'component-path-too-long' -and -not (Test-Path -LiteralPath (Join-Path $realRoot 'downloads'))) 'Install-FastLlmComponent with the real downloader enforces the derived-name limit before any download'
    # The member quarantine name is shortened instead of failing: cache root + leaf + 56 over 259 still quarantines (and keeps the typed failure).
    $leafName = ('m' * 60) + '.dll'
    $memberPart = New-ArchivePart -Dir (Join-Path $work 'fx-b-member') -Name 'm.whl' -Prefix 'p/' -Files ([ordered] @{ $leafName = 'm' }) -BadHashPath $leafName
    $memberDoc = Write-ComponentsDoc @((New-TreeComponent -Id 'rt-bound-member' -Parts @($memberPart.part)))
    $memberFx = [pscustomobject] @{ ZipByUrl = @{ $memberPart.url = $memberPart.zip } }
    $memberEntry = Get-ComponentEntry $memberDoc 'rt-bound-member'
    $memberCacheRootProbe = Split-Path -Parent (& $module { param($r, $c) @((Get-FastLlmComponentCachePaths -Component $c -InstallRoot $r).paths)[0] } (Join-Path $boundaryBase 'p') $memberEntry)
    $memberSuffix = $memberCacheRootProbe.Length - [System.IO.Path]::GetFullPath((Join-Path $boundaryBase 'p')).Length
    $memberWantRoot = 260 - 56 - 1 - $leafName.Length - $memberSuffix
    $memberInstall = Join-Path $boundaryBase ('f' * ($memberWantRoot - ([System.IO.Path]::GetFullPath($boundaryBase).Length + 1)))
    $memberResult = Get-ThrownFailure { Install-FastLlmComponent -ComponentsPath $memberDoc -ComponentId 'rt-bound-member' -InstallRoot $memberInstall -AcceptLicense -Download (New-ChainSeam -Fixture $memberFx -State (New-ChainState)) }
    $memberCache = [System.IO.Path]::Combine($memberInstall, 'downloads', 'c')
    $memberQuarantined = @(Get-ChildItem -LiteralPath $memberCache -Force -File | Where-Object { $_.Name -like '*.corrupt*' })
    Check ($null -ne $memberResult -and $memberResult.code -ceq 'component-archive-member-mismatch' -and $memberQuarantined.Count -eq 1 -and $memberQuarantined[0].Name -match '^[0-9a-f]{8}\.corrupt$') 'a member quarantine name that would pass 259 characters is shortened, so the typed mismatch is still raised and the partial is kept'
    Remove-Item -LiteralPath $boundaryBase -Recurse -Force -ErrorAction SilentlyContinue

    # The shipped AMD runtime with the real downloader: the longest manifest file path binds at an install root of 76 characters.
    $tempFull = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([char[]] @('\', '/'))
    foreach ($case in @(@{ length = 76; allowed = $true }, @{ length = 77; allowed = $false })) {
        $shippedRootAt = Join-Path $tempFull ('r' * ($case.length - $tempFull.Length - 1))
        $shippedLimit = Get-ThrownFailure { & $module { param($c, $r) Assert-FastLlmComponentPathLength -Component $c -InstallRoot $r -DownloaderNames } $hipRuntime $shippedRootAt }
        if ($case.allowed) { Check ([System.IO.Path]::GetFullPath($shippedRootAt).Length -eq 76 -and $null -eq $shippedLimit) 'the shipped AMD runtime installs under an install root of 76 characters' }
        else { Check ([System.IO.Path]::GetFullPath($shippedRootAt).Length -eq 77 -and $null -ne $shippedLimit -and $shippedLimit.code -ceq 'component-path-too-long') 'the shipped AMD runtime is refused at 77 characters (the longest file path would pass 259)' }
    }

    # -- Hashing passes: each file once (the member check), each archive once --
    $hashFx = New-ChainFixture -Name 'fx-hashing'
    $hashRoot = New-TestRoot
    & $module { $script:FastLlmFileHashCalls = 0 }
    $null = Install-FastLlmComponent -ComponentsPath $hashFx.ComponentsPath -ComponentId 'eng-hip' -InstallRoot $hashRoot -AcceptLicense -Download (New-ChainSeam -Fixture $hashFx -State (New-ChainState)) 6>$null
    $installHashCalls = & $module { $script:FastLlmFileHashCalls }
    Check ($installHashCalls -eq 9) "a chain install hashes each of its 6 members once and each of its 3 archives once ($installHashCalls hash calls)"

    # -- Staging: stale cleanup, a link is never followed --
    $staleRoot = New-TestRoot
    $stagingBase = Join-Path (Join-Path $staleRoot 'components') '.s'
    New-Item -ItemType Directory -Path (Join-Path $stagingBase 'oldoldol/inner') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $stagingBase 'oldoldol/inner/f.bin'), 'x')
    [System.IO.Directory]::SetLastWriteTimeUtc((Join-Path $stagingBase 'oldoldol'), (Get-Date).ToUniversalTime().AddHours(-3))
    New-Item -ItemType Directory -Path (Join-Path $stagingBase 'freshfre') -Force | Out-Null
    $linkTarget = New-TestRoot
    [System.IO.File]::WriteAllText((Join-Path $linkTarget 'precious.txt'), 'keep')
    $staleLinkMade = $false
    if ($canLink) {
        $null = New-TestLink -Path (Join-Path $stagingBase 'linklink') -Target $linkTarget
        $staleLinkMade = $true
    }
    $staleFx = New-ChainFixture -Name 'fx-stale'
    $null = Install-FastLlmComponent -ComponentsPath $staleFx.ComponentsPath -ComponentId 'rt-hip' -InstallRoot $staleRoot -AcceptLicense -Download (New-ChainSeam -Fixture $staleFx -State (New-ChainState)) 6>$null 3>$null
    Check ((-not (Test-Path -LiteralPath (Join-Path $stagingBase 'oldoldol'))) -and (Test-Path -LiteralPath (Join-Path $stagingBase 'freshfre'))) 'an install removes staging leftovers older than an hour and keeps a fresh one'
    if ($staleLinkMade) { Check ((Test-Path -LiteralPath (Join-Path $linkTarget 'precious.txt')) -and (Test-Path -LiteralPath (Join-Path $stagingBase 'linklink'))) 'a link inside the staging folder is neither followed nor removed' }
    if ($staleLinkMade) { [System.IO.Directory]::Delete((Join-Path $stagingBase 'linklink')) }
    $filesSourceNow = [regex]::Match($moduleSourceEarly, '(?s)function Install-FastLlmComponentFiles \{.*?\r?\n\}\r?\n').Value
    Check ($filesSourceNow.Contains('New-Item -ItemType Directory -Path $candidate -ErrorAction Stop') -and $filesSourceNow -notmatch 'New-Item -ItemType Directory -Path \$candidate[^\r\n]*-Force') 'the per-install staging folder is created without -Force, so an existing name fails and is redrawn'

    # -- Directory move: bounded retry, appeared destination --
    $moveFx = New-ChainFixture -Name 'fx-move'
    $moveCalls = @{ n = 0 }
    & $module { $script:FastLlmDirectoryMoveDelaysMs = @(1, 1, 1, 1, 1) }
    try {
        $flaky = { param($s, $d) $moveCalls.n = [int] $moveCalls.n + 1; if ($moveCalls.n -le 2) { throw (New-Object System.IO.IOException('sharing violation')) }; [System.IO.Directory]::Move($s, $d) }.GetNewClosure()
        & $module { param($h) $script:FastLlmDirectoryMoveHook = $h } $flaky
        $moveRoot = New-TestRoot
        $null = Install-FastLlmComponent -ComponentsPath $moveFx.ComponentsPath -ComponentId 'rt-hip' -InstallRoot $moveRoot -AcceptLicense -Download (New-ChainSeam -Fixture $moveFx -State (New-ChainState)) 6>$null
        Check ($moveCalls.n -eq 3 -and (Test-FastLlmComponentInstallation -InstallRoot $moveRoot -Component (Get-ComponentEntry $moveFx.ComponentsPath 'rt-hip'))) 'a directory move that fails twice with IOException succeeds on the third try'
        $denied = { param($s, $d) $moveCalls.n = [int] $moveCalls.n + 1; throw (New-Object System.UnauthorizedAccessException('denied')) }.GetNewClosure()
        $moveCalls.n = 0
        & $module { param($h) $script:FastLlmDirectoryMoveHook = $h } $denied
        $deniedRoot = New-TestRoot
        $deniedFailure = Get-ThrownFailure { Install-FastLlmComponent -ComponentsPath $moveFx.ComponentsPath -ComponentId 'rt-hip' -InstallRoot $deniedRoot -AcceptLicense -Download (New-ChainSeam -Fixture $moveFx -State (New-ChainState)) }
        Check ($null -ne $deniedFailure -and $deniedFailure.code -ceq 'component-move-failed' -and $moveCalls.n -eq 6 -and -not (Test-Path -LiteralPath (Join-Path $deniedRoot 'components/runtime/rt-hip/1.0')) -and -not (Test-Path -LiteralPath (Join-Path $deniedRoot 'components/.s'))) 'an always-failing move is retried 5 times (6 tries), then a typed component-move-failed with staging cleaned up'
        $raceHook = { param($s, $d) New-Item -ItemType Directory -Path $d -Force | Out-Null; throw (New-Object System.IO.IOException('exists')) }
        & $module { param($h) $script:FastLlmDirectoryMoveHook = $h } $raceHook
        $raceFailure = Get-ThrownFailure { Install-FastLlmComponent -ComponentsPath $moveFx.ComponentsPath -ComponentId 'rt-hip' -InstallRoot (New-TestRoot) -AcceptLicense -Download (New-ChainSeam -Fixture $moveFx -State (New-ChainState)) }
        Check ($null -ne $raceFailure -and $raceFailure.code -ceq 'component-root-appeared') 'a destination that appears during the install is the typed component-root-appeared, not retried'
    }
    finally {
        & $module { $script:FastLlmDirectoryMoveHook = $null; $script:FastLlmDirectoryMoveDelaysMs = @(200, 400, 800, 1600, 2000) }
    }

    # -- Tree walk: links, unreadable folders --
    $treeFx = New-ChainFixture -Name 'fx-tree'
    $treeRoot = New-TestRoot
    $null = Install-FastLlmComponent -ComponentsPath $treeFx.ComponentsPath -ComponentId 'rt-hip' -InstallRoot $treeRoot -AcceptLicense -Download (New-ChainSeam -Fixture $treeFx -State (New-ChainState)) 6>$null
    $treeEntry = Get-ComponentEntry $treeFx.ComponentsPath 'rt-hip'
    $treeComponentRoot = Get-FastLlmComponentRoot -InstallRoot $treeRoot -Component $treeEntry
    if ($canLink) {
        $linkOutside = New-TestRoot
        [System.IO.File]::WriteAllText((Join-Path $linkOutside 'k.kpack'), 'runtime-k')
        Remove-Item -LiteralPath (Join-Path $treeComponentRoot '.kpack') -Recurse -Force
        $null = New-TestLink -Path (Join-Path $treeComponentRoot '.kpack') -Target $linkOutside
        Check ((-not (Test-FastLlmComponentInstallation -InstallRoot $treeRoot -Component $treeEntry -Depth Presence)) -and (-not (Test-FastLlmComponentInstallation -InstallRoot $treeRoot -Component $treeEntry))) 'a link inside the component root fails both depths'
        [System.IO.Directory]::Delete((Join-Path $treeComponentRoot '.kpack'))
        New-Item -ItemType Directory -Path (Join-Path $treeComponentRoot '.kpack') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $treeComponentRoot '.kpack/k.kpack'), 'runtime-k')
        Check (Test-FastLlmComponentInstallation -InstallRoot $treeRoot -Component $treeEntry) 'the tree verifies again once the link is replaced by the real folder (positive control)'
    }
    if ($isUnix -and $canLink) {
        & chmod 000 (Join-Path $treeComponentRoot 'bin/lib')
        try {
            $treeThrew = $false
            try { $treeVerified = Test-FastLlmComponentInstallation -InstallRoot $treeRoot -Component $treeEntry -Depth Presence } catch { $treeThrew = $true }
            $treeInventory = @(Get-FastLlmComponentInventory -ComponentsPath $treeFx.ComponentsPath -InstallRoot $treeRoot)
            Check ((-not $treeThrew) -and (-not $treeVerified) -and @($treeInventory | Where-Object { $_.id -ceq 'rt-hip' -and $_.installed -and -not $_.verified }).Count -eq 1) 'an unreadable folder makes the tree unverified instead of throwing, so -List still shows the row'
        }
        finally { & chmod 755 (Join-Path $treeComponentRoot 'bin/lib') }
    }

    # -- Removal guard edges: a link in a requirer's place --
    if ($canLink) {
        $edgeFx = New-ChainFixture -Name 'fx-edge'
        $edgeRoot = New-TestRoot
        $null = Install-FastLlmComponent -ComponentsPath $edgeFx.ComponentsPath -ComponentId 'eng-hip' -InstallRoot $edgeRoot -AcceptLicense -Download (New-ChainSeam -Fixture $edgeFx -State (New-ChainState)) 6>$null
        $edgeEngineRoot = Get-FastLlmComponentRoot -InstallRoot $edgeRoot -Component (Get-ComponentEntry $edgeFx.ComponentsPath 'eng-hip')
        $edgeOutside = New-TestRoot
        [System.IO.File]::WriteAllText((Join-Path $edgeOutside 'precious.txt'), 'keep')
        Remove-Item -LiteralPath $edgeEngineRoot -Recurse -Force
        $null = New-TestLink -Path $edgeEngineRoot -Target $edgeOutside
        $edgeWarnings = @()
        $edgeRemoved = Remove-FastLlmComponent -ComponentsPath $edgeFx.ComponentsPath -ComponentId 'rt-hip' -InstallRoot $edgeRoot -WarningVariable edgeWarnings 3>$null
        Check ($edgeRemoved -and @($edgeWarnings).Count -ge 1 -and "$($edgeWarnings[0])" -like '*reparse point*') 'a link standing where the requiring component should be is ignored by the guard, with a warning'
        $edgeRemovedLink = Remove-FastLlmComponent -ComponentsPath $edgeFx.ComponentsPath -ComponentId 'eng-hip' -InstallRoot $edgeRoot
        Check ($edgeRemovedLink -and (-not (Test-Path -LiteralPath $edgeEngineRoot)) -and (Test-Path -LiteralPath (Join-Path $edgeOutside 'precious.txt'))) 'removing a component whose root is a link unlinks it and never touches what it points at'
        $innerFx = New-ChainFixture -Name 'fx-inner'
        $innerRoot = New-TestRoot
        $null = Install-FastLlmComponent -ComponentsPath $innerFx.ComponentsPath -ComponentId 'rt-hip' -InstallRoot $innerRoot -AcceptLicense -Download (New-ChainSeam -Fixture $innerFx -State (New-ChainState)) 6>$null
        $innerComponentRoot = Get-FastLlmComponentRoot -InstallRoot $innerRoot -Component (Get-ComponentEntry $innerFx.ComponentsPath 'rt-hip')
        $null = New-TestLink -Path (Join-Path $innerComponentRoot 'bin/sneaky') -Target $edgeOutside
        $innerMessage = Get-ThrownMessage { Remove-FastLlmComponent -ComponentsPath $innerFx.ComponentsPath -ComponentId 'rt-hip' -InstallRoot $innerRoot }
        Check ($null -ne $innerMessage -and $innerMessage -like '*reparse point*' -and (Test-Path -LiteralPath (Join-Path $edgeOutside 'precious.txt')) -and (Test-Path -LiteralPath (Join-Path $innerComponentRoot 'bin/a.dll'))) 'a link inside a component refuses the removal and deletes nothing'
        [System.IO.Directory]::Delete((Join-Path $innerComponentRoot 'bin/sneaky'))
    }

    # ---- components -List shows runtime kinds ----
    $listRoot = New-TestRoot
    $listInventory = @(Get-FastLlmComponentInventory -ComponentsPath $linksFx.ComponentsPath -InstallRoot $listRoot)
    $listText = (@(Format-FastLlmComponentList -Inventory $listInventory) -join "`n")
    Check ($listInventory.Count -eq 2 -and $listText -match 'rt-hip\s+runtime\s' -and $listText -match 'eng-hip\s+engine\s') 'components -List lists each component, runtime kinds included'

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

    # ---- a HIP engine that requires a runtime. Resolution, the plan (device probe, ROCm<N>), and the shipped HIP engine's manifest ----
    $hipShippedEngine = @($shipped | Where-Object { [string] $_.id -ceq 'llama.cpp-hip-b11658' })[0]
    $hipShippedManifest = @((Get-FastLlmComponentSources -Component $hipShippedEngine)[0].fileManifest)
    Check (@($hipShippedManifest | Where-Object { $_.path -ceq 'amdhip64_7.dll' }).Count -eq 1 -and @($hipShippedManifest | Where-Object { $_.path -ceq 'llama-server.exe' }).Count -eq 1) 'the shipped HIP engine carries its own amdhip64_7.dll next to llama-server.exe (the engine-dir copy that wins the PATH order over the driver copy)'
    $hipFx = New-ChainFixture -Name 'fx-hip-plan'
    $hipList = @(Get-FastLlmComponents -ComponentsPath $hipFx.ComponentsPath)
    $hipResolveRecipe = [pscustomobject] @{ id = 'rh'; components = [pscustomobject] @{ engine = 'eng-hip'; model = 'm' } }
    $hipInstallRoot = New-TestRoot
    $hipRuntimeEntry = Get-ComponentEntry $hipFx.ComponentsPath 'rt-hip'
    $hipEngineEntry = Get-ComponentEntry $hipFx.ComponentsPath 'eng-hip'
    $hipRuntimeRootPath = Get-FastLlmComponentRoot -InstallRoot $hipInstallRoot -Component $hipRuntimeEntry
    $hipExpectedRoots = @(& $module { param($R, $C) Join-FastLlmContainedPath -Root $R -Child $C -Label 'x' } $hipRuntimeRootPath 'bin')
    $hipBefore = & $module { param($R, $C, $L, $I) Resolve-FastLlmRecipeEngine -Recipe $R -Catalog $C -Components $L -InstallRoot $I } $hipResolveRecipe $resolveCatalog $hipList $hipInstallRoot
    Check (-not $hipBefore.builtIn -and $hipBefore.backend -ceq 'hip' -and -not $hipBefore.installed -and @($hipBefore.runtimeRoots).Count -eq 1 -and $hipBefore.runtimeRoots[0] -ceq $hipExpectedRoots[0]) 'a HIP engine resolves with backend hip and the runtime root joined with runtimePathDirs, whether or not it is installed'
    $hipChainState = New-ChainState
    $null = Install-FastLlmComponent -ComponentsPath $hipFx.ComponentsPath -ComponentId 'eng-hip' -InstallRoot $hipInstallRoot -AcceptLicense -Download (New-ChainSeam -Fixture $hipFx -State $hipChainState)
    $hipAfter = & $module { param($R, $C, $L, $I) Resolve-FastLlmRecipeEngine -Recipe $R -Catalog $C -Components $L -InstallRoot $I } $hipResolveRecipe $resolveCatalog $hipList $hipInstallRoot
    Check ($hipAfter.installed -and $hipAfter.backend -ceq 'hip' -and $hipAfter.id -ceq 'eng-hip' -and $hipAfter.runtimeRoots[0] -ceq $hipExpectedRoots[0]) 'an installed HIP chain resolves as installed, with the runtime bin directory as its DLL root'
    Check (@($resolvedBuiltIn.runtimeRoots).Count -eq 0 -and $resolvedBuiltIn.backend -ceq 'vulkan' -and $installed.backend -ceq 'vulkan' -and @($installed.runtimeRoots).Count -eq 0) 'built-in and Vulkan component engines resolve with backend vulkan and no runtime roots'
    $hipShippedResolve = & $module { param($L, $I) Resolve-FastLlmRecipeEngine -Recipe ([pscustomobject] @{ id = 'rs'; components = [pscustomobject] @{ engine = 'llama.cpp-hip-b11658'; model = 'm' } }) -Catalog ([pscustomobject] @{ engine = [pscustomobject] @{ version = 'b10698'; assets = [pscustomobject] @{ vulkan = [pscustomobject] @{ entryPoint = 'llama-server.exe' } } } }) -Components $L -InstallRoot $I } $shipped (New-TestRoot)
    Check ($hipShippedResolve.backend -ceq 'hip' -and @($hipShippedResolve.runtimeRoots).Count -eq 1 -and $hipShippedResolve.runtimeRoots[0] -like '*components*runtime*amd-rocm-gfx1100-10.0.0*10.0.0*bin') 'the shipped HIP engine resolves its runtime root under components\runtime\amd-rocm-gfx1100-10.0.0\10.0.0\bin'

    $hipPlanDir = Join-Path $work 'hip-plan-config'
    New-Item -ItemType Directory -Path $hipPlanDir -Force | Out-Null
    Copy-Item -LiteralPath $shippedCatalogPath -Destination (Join-Path $hipPlanDir 'catalog.json') -Force
    Copy-Item -LiteralPath $hipFx.ComponentsPath -Destination (Join-Path $hipPlanDir 'components.json') -Force
    $hipRecipeDocument = Get-Content -LiteralPath $shippedRecipesPath -Raw | ConvertFrom-Json
    $hipRecipeEntry = @($hipRecipeDocument.recipes | Where-Object { $_.id -ceq 'rx-7900-xtx.qwen3.8-27b-ud-q4-k-m.32k' })[0]
    $hipRecipeEntry.id = 'fixture.hip-engine'
    $hipRecipeEntry.components.engine = 'eng-hip'
    $hipRecipeEntry.engineBuild = '1.0'
    $hipRecipeDocument.recipes = @($hipRecipeEntry)
    $hipRecipesPath = Join-Path $hipPlanDir 'recipes.json'
    [System.IO.File]::WriteAllText($hipRecipesPath, (ConvertTo-Json -InputObject $hipRecipeDocument -Depth 12), (New-Object System.Text.UTF8Encoding($false)))
    $hipPlanParams = @{ Hardware = $xtxHardware; CatalogPath = (Join-Path $hipPlanDir 'catalog.json'); InstallRoot = $hipInstallRoot; RecipesPath = $hipRecipesPath; GpuVariantsPath = $shippedVariantsPath
        # The HIP fixture chain needs accept consent, so it is reached only by naming the recipe, never by automatic selection.
        RecipeId = 'fixture.hip-engine' }
    $hipProbe = @{ calls = (New-Object 'System.Collections.Generic.List[object]'); devices = @(); failure = $null }
    $savedHipProbe = & $module { (Get-Command Invoke-FastLlmDeviceProbe).ScriptBlock }
    & $module {
        param($P)
        $script:hipProbeState = $P
        function script:Invoke-FastLlmDeviceProbe {
            param($EnginePath, $Backend, $InstallRoot, $TimeoutSeconds, [switch] $Hip, $RuntimeRoots, $ComponentId)
            $script:hipProbeState.calls.Add([pscustomobject] @{ EnginePath = $EnginePath; Backend = $Backend; Hip = [bool] $Hip; RuntimeRoots = @($RuntimeRoots); ComponentId = $ComponentId })
            if ($script:hipProbeState.failure) { throw $script:hipProbeState.failure }
            return $script:hipProbeState.devices
        }
    } $hipProbe
    try {
        $hipProbe.devices = @(ConvertFrom-LlamaDeviceList -Text "Available devices:`n  ROCm0: AMD Radeon RX 7900 XTX (24560 MiB, 24411 MiB free)" -Backend ROCm)
        $hipPlanned = Get-FastLlmPlan @hipPlanParams
        Check ($hipPlanned.recipe.id -ceq 'fixture.hip-engine' -and $hipPlanned.backend -ceq 'hip' -and $hipPlanned.engineComponentId -ceq 'eng-hip' -and $hipPlanned.engineVersion -ceq '1.0') 'a HIP recipe plans with backend hip, the engine component id and its version'
        Check (@($hipPlanned.runtimeRoots).Count -eq 1 -and $hipPlanned.runtimeRoots[0] -ceq $hipExpectedRoots[0]) 'the HIP plan carries the absolute runtime DLL roots'
        Check ($hipPlanned.selectedAdapters[0].device -ceq 'ROCm0' -and $xtxHardware.adapters[0].device -ceq 'Vulkan0') 'the HIP plan names the selected adapter ROCm0 and leaves the probed hardware untouched'
        $hipArguments = @($hipPlanned.serverArguments)
        Check ($hipArguments[[Array]::IndexOf($hipArguments, '--device') + 1] -ceq 'ROCm0' -and $hipArguments[[Array]::IndexOf($hipArguments, '--host') + 1] -ceq '127.0.0.1') 'the HIP plan passes --device ROCm0 and still binds 127.0.0.1'
        Check ($hipProbe.calls.Count -eq 1 -and $hipProbe.calls[0].Hip -and $hipProbe.calls[0].Backend -ceq 'ROCm' -and $hipProbe.calls[0].EnginePath -ceq $hipPlanned.enginePath -and $hipProbe.calls[0].ComponentId -ceq 'eng-hip' -and $hipProbe.calls[0].RuntimeRoots[0] -ceq $hipExpectedRoots[0]) 'the HIP device probe runs the component engine with the runtime roots (the same environment as the launch)'
        Check ((@($hipPlanned.PSObject.Properties.Name) -join ',') -ceq ((@($builtInNoRoot.PSObject.Properties.Name) + @('engineComponentId', 'runtimeRoots')) -join ',')) 'a HIP plan is the Vulkan plan shape plus exactly engineComponentId and runtimeRoots'
        # Vulkan plans never probe HIP and keep their shape.
        $hipProbe.calls.Clear()
        $vulkanAgain = Get-FastLlmPlan -Hardware $xtxHardware -CatalogPath $shippedCatalogPath -InstallRoot $planRoot -RecipesPath $shippedRecipesPath -GpuVariantsPath $shippedVariantsPath
        Check ($hipProbe.calls.Count -eq 0 -and $vulkanAgain.backend -ceq 'Vulkan' -and -not $vulkanAgain.PSObject.Properties['runtimeRoots'] -and -not $vulkanAgain.PSObject.Properties['engineComponentId']) 'a shipped Vulkan recipe plans without any HIP probe, with backend Vulkan and no HIP fields'
        # A named shipped-shape HIP recipe plans on the HIP engine with no Vulkan-only argument.
        $hipRecipeDoc2 = Get-Content -LiteralPath $shippedRecipesPath -Raw | ConvertFrom-Json
        $hipNamedEntry = @($hipRecipeDoc2.recipes | Where-Object { $_.id -ceq 'rx-7900-xtx.qwen3.8-27b-ud-q4-k-m.32k.hip' })[0]
        $hipNamedEntry.components.engine = 'eng-hip'
        $hipNamedEntry.engineBuild = '1.0'
        $hipRecipeDoc2.recipes = @($hipNamedEntry)
        $hipRecipesPath2 = Join-Path $hipPlanDir 'recipes-hip-shipped.json'
        [System.IO.File]::WriteAllText($hipRecipesPath2, (ConvertTo-Json -InputObject $hipRecipeDoc2 -Depth 12), (New-Object System.Text.UTF8Encoding($false)))
        $hipProbe.devices = @(ConvertFrom-LlamaDeviceList -Text "Available devices:`n  ROCm0: AMD Radeon RX 7900 XTX (24560 MiB, 24411 MiB free)" -Backend ROCm)
        $hipNamedParams = @{ Hardware = $xtxHardware; CatalogPath = (Join-Path $hipPlanDir 'catalog.json'); InstallRoot = $hipInstallRoot; RecipesPath = $hipRecipesPath2; GpuVariantsPath = $shippedVariantsPath }
        $hipAutoPlan = Get-FastLlmPlan @hipNamedParams
        Check ($hipAutoPlan.recipe.origin -ceq 'estimated') 'without -Recipe the HIP recipe is not picked: the plan stays estimated (no silent HIP promotion)'
        $hipNamedPlan = Get-FastLlmPlan @hipNamedParams -RecipeId 'rx-7900-xtx.qwen3.8-27b-ud-q4-k-m.32k.hip'
        Check ($hipNamedPlan.recipe.origin -ceq 'bitworks-experimental' -and $hipNamedPlan.backend -ceq 'hip' -and $hipNamedPlan.engineComponentId -ceq 'eng-hip' -and $hipNamedPlan.selectionMode -ceq 'recipe') 'naming the HIP recipe yields a HIP plan on the engine component'
        $vulkanFlagText = (@($hipNamedPlan.serverArguments) -join ' ')
        Check ($vulkanFlagText -cnotmatch '(?i)vulkan|GGML_VK|--vk' -and @($hipNamedPlan.serverArguments) -cnotcontains 'Vulkan0') 'the HIP plan arguments contain nothing Vulkan-specific'
        $hipNamedArguments = @($hipNamedPlan.serverArguments | ForEach-Object { if ($_ -ceq $hipNamedPlan.modelPath) { 'MODEL' } else { $_ } })
        Check (($hipNamedArguments -join [char]31) -ceq (($expectedXtx | ForEach-Object { if ($_ -ceq 'Vulkan0') { 'ROCm0' } else { $_ } }) -join [char]31)) 'the HIP plan arguments equal the shipped Vulkan recipe arguments with only the device changed to ROCm0'
        Check ($hipNamedPlan.recipe.vulkanBarMitigation -ceq 'not-applicable' -and $null -eq $hipNamedPlan.recipe.expected -and $null -eq $hipNamedPlan.recipe.evidenceUrl -and $hipNamedPlan.recipe.label -ceq 'Experimental Bitworks setup, not yet measured by Bitworks on this card') 'the HIP plan records the BAR mitigation as not-applicable and carries no expected or evidence'
        # iGPU first, dGPU second: matched by name and VRAM.
        $hipProbe.devices = @(ConvertFrom-LlamaDeviceList -Text "Available devices:`n  ROCm0: AMD Radeon(TM) Graphics (512 MiB, 400 MiB free)`n  ROCm1: AMD Radeon RX 7900 XTX (24560 MiB, 24411 MiB free)" -Backend ROCm)
        $hipSecond = Get-FastLlmPlan @hipPlanParams
        Check ($hipSecond.selectedAdapters[0].device -ceq 'ROCm1' -and $hipSecond.serverArguments[[Array]::IndexOf(@($hipSecond.serverArguments), '--device') + 1] -ceq 'ROCm1') 'with an iGPU listed first the plan still selects the dGPU as ROCm1'
        # Fail closed: nothing matches, or two identical cards.
        foreach ($closed in @(
                @{ code = 'hip-device-not-found'; text = "Available devices:`n  ROCm0: AMD Radeon RX 7900 XT (20464 MiB, 20000 MiB free)" },
                @{ code = 'hip-device-not-found'; text = 'Available devices:' },
                @{ code = 'hip-device-ambiguous'; text = "Available devices:`n  ROCm0: AMD Radeon RX 7900 XTX (24560 MiB, 24411 MiB free)`n  ROCm1: AMD Radeon RX 7900 XTX (24560 MiB, 24411 MiB free)" })) {
            $hipProbe.devices = @(ConvertFrom-LlamaDeviceList -Text $closed.text -Backend ROCm)
            $closedFailure = $null
            try { Get-FastLlmPlan @hipPlanParams | Out-Null } catch { $closedFailure = $_.Exception }
            Check ($null -ne $closedFailure -and $closedFailure.Data['FastLlmFailureCode'] -ceq $closed.code) "the HIP plan fails closed with $($closed.code) and no estimated plan"
        }
        # A blocked DLL at the probe is the typed failure, not "no device" and not an estimated Vulkan plan.
        $hipProbe.failure = & $module { New-FastLlmHipLaunchFailure -ComponentId 'eng-hip' -ExitCode -1073740760 }
        $blockedPlan = $null
        try { Get-FastLlmPlan @hipPlanParams | Out-Null } catch { $blockedPlan = $_.Exception }
        Check ($null -ne $blockedPlan -and $blockedPlan.Data['FastLlmFailureCode'] -ceq 'hip-dll-blocked' -and $blockedPlan.Data['FastLlmReason'] -ceq 'HipDllFailed') 'a blocked DLL during the device probe fails the plan hip-dll-blocked (never a silent fallback to Vulkan)'
        $hipProbe.failure = $null
        # Verify before execute: a SAME-SIZE content tamper of a runtime DLL (Presence cannot see it) stops the plan before the probe runs anything,
        # naming the runtime. The CLI order is plan, then Start's check: both refuse. The unchanged tree is hashed once per process.
        $hipProbe.devices = @(ConvertFrom-LlamaDeviceList -Text "Available devices:`n  ROCm0: AMD Radeon RX 7900 XTX (24560 MiB, 24411 MiB free)" -Backend ROCm)
        $hipProbe.calls.Clear()
        $tamperTarget = Join-Path (Join-Path $hipRuntimeRootPath 'bin') 'a.dll'
        $tamperOriginal = [System.IO.File]::ReadAllBytes($tamperTarget)
        $tamperStamp = (Get-Item -LiteralPath $tamperTarget).LastWriteTimeUtc
        $hashCallsBefore = & $module { $script:FastLlmFileHashCalls }
        $null = Get-FastLlmPlan @hipPlanParams
        $hashCallsAfterPlan = & $module { $script:FastLlmFileHashCalls }
        $null = Get-FastLlmPlan @hipPlanParams
        Check ((& $module { $script:FastLlmFileHashCalls }) -eq $hashCallsAfterPlan) 'an unchanged HIP chain is hashed once per process: the second plan hashes nothing (memoised Full verdict)'
        $touchStamp = $tamperStamp.AddSeconds(30)
        [System.IO.File]::SetLastWriteTimeUtc($tamperTarget, $touchStamp)
        $hashCallsBeforeTouch = & $module { $script:FastLlmFileHashCalls }
        $null = Get-FastLlmPlan @hipPlanParams
        Check ((& $module { $script:FastLlmFileHashCalls }) -gt $hashCallsBeforeTouch) 'a changed newest write time changes the memo key, so the chain is hashed again'
        $tampered = [byte[]] $tamperOriginal.Clone()
        $tampered[$tampered.Length - 1] = [byte] ($tampered[$tampered.Length - 1] -bxor 1)
        [System.IO.File]::WriteAllBytes($tamperTarget, $tampered)
        [System.IO.File]::SetLastWriteTimeUtc($tamperTarget, $touchStamp.AddSeconds(30))
        Check ((Get-Item -LiteralPath $tamperTarget).Length -eq $tamperOriginal.Length) 'the tamper keeps the file size (a presence/size check cannot see it)'
        $hipProbe.calls.Clear()
        $tamperPlan = $null
        try { Get-FastLlmPlan @hipPlanParams | Out-Null } catch { $tamperPlan = $_.Exception }
        Check ($null -ne $tamperPlan -and $tamperPlan.Data['FastLlmFailureCode'] -ceq 'needs-setup-component-missing' -and $tamperPlan.Data['FastLlmComponentId'] -ceq 'eng-hip' -and $tamperPlan.Data['FastLlmUnavailableComponentId'] -ceq 'rt-hip' -and $tamperPlan.Message -like "*'rt-hip'*" -and $hipProbe.calls.Count -eq 0) 'a same-size tamper of the runtime stops the CLI plan with needs-setup-component-missing naming the runtime, before the probe runs any component code'
        Check ((& $module { param($L, $I) Get-FastLlmFirstUnavailableComponent -Components $L -EngineId 'eng-hip' -InstallRoot $I -Depth Full } $hipList $hipInstallRoot) -ceq 'rt-hip') 'and Start-FastLlmServer verification (Full, the next step of the CLI order) refuses the same tamper, naming the runtime'
        [System.IO.File]::WriteAllBytes($tamperTarget, $tamperOriginal)
        [System.IO.File]::SetLastWriteTimeUtc($tamperTarget, $touchStamp.AddSeconds(60))
        $null = Get-FastLlmPlan @hipPlanParams
        Check ($hipProbe.calls.Count -eq 1) 'restoring the content makes the plan pass again (and probe once)'
        # The runtime is removed while the engine is installed: the plan names the RUNTIME.
        $hipProbe.devices = @(ConvertFrom-LlamaDeviceList -Text "Available devices:`n  ROCm0: AMD Radeon RX 7900 XTX (24560 MiB, 24411 MiB free)" -Backend ROCm)
        $hipProbe.calls.Clear()
        Remove-Item -LiteralPath (Join-Path (Join-Path $hipRuntimeRootPath 'bin') 'a.dll') -Force
        $missingRuntimePlan = $null
        try { Get-FastLlmPlan @hipPlanParams | Out-Null } catch { $missingRuntimePlan = $_.Exception }
        Check ($null -ne $missingRuntimePlan -and $missingRuntimePlan.Data['FastLlmFailureCode'] -ceq 'needs-setup-component-missing' -and $missingRuntimePlan.Data['FastLlmComponentId'] -ceq 'eng-hip' -and $missingRuntimePlan.Data['FastLlmUnavailableComponentId'] -ceq 'rt-hip' -and $missingRuntimePlan.Message -like "*'rt-hip'*" -and $hipProbe.calls.Count -eq 0) 'an engine installed but its runtime tampered with: the plan fails needs-setup-component-missing naming the runtime (the install target stays the engine, so the install action repairs the whole chain), and runs nothing'
        $hipStillResolved = & $module { param($R, $C, $L, $I) Resolve-FastLlmRecipeEngine -Recipe $R -Catalog $C -Components $L -InstallRoot $I } $hipResolveRecipe $resolveCatalog $hipList $hipInstallRoot
        Check (-not $hipStillResolved.installed) 'the HIP engine no longer resolves as installed once its runtime is damaged'
        Check ((& $module { param($L, $I) Get-FastLlmFirstUnavailableComponent -Components $L -EngineId 'eng-hip' -InstallRoot $I -Depth Presence } $hipList $hipInstallRoot) -ceq 'rt-hip') 'the first unavailable component of the chain is the runtime (requires first)'
    }
    finally {
        & $module { param($B) Set-Item -Path Function:script:Invoke-FastLlmDeviceProbe -Value $B } $savedHipProbe
    }

    # ---- Memo hardening: a tree holding ANY reparse point has no memo key, so a junction or symlink swapped in can never reuse a remembered pass ----
    $memoFx = New-Fixture -Dir (Join-Path $work 'fx-memo') -Id 'memo-engine-1' -Version 'v1'
    $memoRoot = New-TestRoot
    $memoCounter = @{ count = 0 }
    $memoComponentRoot = Install-Fixture -Fixture $memoFx -InstallRoot $memoRoot -Counter $memoCounter -AcceptLicense -Unattended
    $memoComponent = Get-ComponentEntry $memoFx.ComponentsPath 'memo-engine-1'
    $plainKey = & $module { param($R, $C) Get-FastLlmComponentMemoKey -Root $R -Component $C } $memoComponentRoot $memoComponent
    Check (-not [string]::IsNullOrEmpty($plainKey) -and $plainKey -like 'memo-engine-1|*') 'a plain installed tree has a memo key'
    $memoEntriesBefore = & $module { @($script:FastLlmFullVerdictMemo.Keys).Count }
    Check ((& $module { param($I, $C) Test-FastLlmComponentVerifiedFull -InstallRoot $I -Component $C } $memoRoot $memoComponent) -and (& $module { @($script:FastLlmFullVerdictMemo.Keys).Count }) -eq $memoEntriesBefore + 1) 'a passing Full verdict of a plain tree is remembered'
    $reparseTarget = Join-Path (New-TestRoot) 'outside'
    New-Item -ItemType Directory -Path $reparseTarget -Force | Out-Null
    $reparseLink = Join-Path $memoComponentRoot 'swapped'
    $reparseMade = $false
    try {
        if ($env:OS -eq 'Windows_NT') { & cmd.exe /c mklink /J "$reparseLink" "$reparseTarget" | Out-Null; $reparseMade = Test-Path -LiteralPath $reparseLink }
        else { New-Item -ItemType SymbolicLink -Path $reparseLink -Target $reparseTarget | Out-Null; $reparseMade = Test-Path -LiteralPath $reparseLink }
    }
    catch { $reparseMade = $false }
    if ($reparseMade) {
        $reparseKey = & $module { param($R, $C) Get-FastLlmComponentMemoKey -Root $R -Component $C } $memoComponentRoot $memoComponent
        Check ($null -eq $reparseKey) 'a tree holding a reparse point (junction or symlink) has no memo key'
        $memoCountWithLink = & $module { @($script:FastLlmFullVerdictMemo.Keys).Count }
        $null = & $module { param($I, $C) Test-FastLlmComponentVerifiedFull -InstallRoot $I -Component $C } $memoRoot $memoComponent
        Check ((& $module { @($script:FastLlmFullVerdictMemo.Keys).Count }) -eq $memoCountWithLink) 'a verdict on a tree with a reparse point is never stored in the memo'
        $reusedVerdict = & $module { param($I, $C) Test-FastLlmComponentVerifiedFull -InstallRoot $I -Component $C } $memoRoot $memoComponent
        Check (-not $reusedVerdict -and -not (Test-FastLlmComponentInstallation -InstallRoot $memoRoot -Component $memoComponent)) 'a remembered pass for the same tree is not reused once a reparse point is in it: the real check runs and refuses it'
        if ($env:OS -eq 'Windows_NT') { & cmd.exe /c rmdir "$reparseLink" | Out-Null } else { Remove-Item -LiteralPath $reparseLink -Force }
    }
    else { Write-Host 'SKIP: the reparse-point memo checks need a junction or symlink, which could not be created here' }
    $memoSource = [System.IO.File]::ReadAllText($modulePath)
    Check ($memoSource.Contains('[IO.FileAttributes]::ReparsePoint) { return $null }') -and $memoSource.Contains('Get-FastLlmComponentMemoKey -Root $root -Component $Component')) 'the memo key function returns $null on any reparse point and the verdict function uses it'

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
    $multiPartComponents = @([pscustomobject] @{ id = 'test-engine-1'; kind = 'engine'; version = 'v1'; sources = @([pscustomobject] @{ url = 'https://example.com/p1.zip' }, [pscustomobject] @{ url = 'https://example.com/p2.zip' }) })
    $multiPartMsg = Get-ThrownMessage { Assert-FastLlmExperimentalRecipeAllowed -InstallRoot $gateRoot -RecipeId 'e1' -Recipes $gateRecipes -Components $multiPartComponents }
    Check ($null -ne $multiPartMsg -and $multiPartMsg -like '*engine test-engine-1 (https://example.com/p1.zip, https://example.com/p2.zip)*') 'the refusal lists every source URL of a multi-part component'
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

    # ---- bitworks-experimental origin, the accept-license rule and the shipped HIP recipes ----
    Check ((Get-FastLlmRecipeLabel 'bitworks-experimental') -ceq 'Experimental Bitworks setup, not yet measured by Bitworks on this card') 'the bitworks-experimental label is the exact experimental Bitworks wording'
    $chainRecipe = $autoBitworks | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $chainRecipe.id = 'chain1'
    $chainRecipe.components.engine = 'eng-hip'
    $chainRecipe.engineBuild = '1.0'
    $acceptList = $hipList
    $showFx = New-ChainFixture -Name 'fx-show-chain' -Consent 'show'
    $showList = @(Get-FastLlmComponents -ComponentsPath $showFx.ComponentsPath)
    Check (@($acceptList | Where-Object { $_.license.consent -ceq 'accept' }).Count -eq 2 -and @($showList | Where-Object { $_.license.consent -ceq 'accept' }).Count -eq 0) 'the two chain fixtures differ only in license consent (accept versus show)'
    $chainSelect = { param($Recipe, $List, $Sink, [string] $Named, [bool] $Experimental)
        $selectParams = @{ Recipes = @($Recipe); Variants = $autoVariants; Placements = @($autoPlacement); DxgiAdapters = $autoDxgi; Catalog = $autoCatalog; Profile = 'balanced'; Components = $List }
        if ($null -ne $Sink) { $selectParams.SkippedSink = $Sink }
        if ($Named) { $selectParams.RecipeId = $Named }
        if ($Experimental) { $selectParams.IncludeExperimental = $true }
        return (Select-FastLlmRecipeForPlacements @selectParams) }
    # Positive control: the same recipe on an engine chain WITHOUT accept consent is picked under the same inputs.
    $showPick = & $chainSelect $chainRecipe $showList $null '' $false
    Check ($null -ne $showPick -and $showPick.recipe.id -ceq 'chain1') 'a bitworks recipe whose engine chain has no accept consent is auto-picked (the control for the rule below)'
    $acceptSink = New-Object 'System.Collections.Generic.List[string]'
    $acceptPick = & $chainSelect $chainRecipe $acceptList $acceptSink '' $false
    Check ($null -eq $acceptPick -and @($acceptSink | Where-Object { $_ -like 'chain1: needs-license-acceptance*' }).Count -eq 1) 'a bitworks recipe whose engine chain needs accept (engine and runtime) is not auto-selected, with the reason needs-license-acceptance'
    $namedPick = & $chainSelect $chainRecipe $acceptList $null 'chain1' $false
    Check ($null -ne $namedPick -and $namedPick.recipe.id -ceq 'chain1') 'the same accept-chain recipe is selected when named with -Recipe'
    $runtimeOnlyAccept = @($showList | ForEach-Object { $copy = $_ | ConvertTo-Json -Depth 20 | ConvertFrom-Json; if ($copy.id -ceq 'rt-hip') { $copy.license.consent = 'accept' }; $copy })
    Check ($null -eq (& $chainSelect $chainRecipe $runtimeOnlyAccept $null '' $false)) 'an accept consent on a REQUIRED component alone also blocks auto-selection (the whole chain is checked, not just the engine)'
    $reproRecipe = $chainRecipe | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $reproRecipe.origin = 'community-reproduced'
    Check ($null -eq (& $chainSelect $reproRecipe $acceptList $null '' $false) -and $null -ne (& $chainSelect $reproRecipe $showList $null '' $false)) 'the accept rule applies to a community-reproduced recipe too (control: picked without accept)'
    # bitworks-experimental: never auto-selected, with the switch on or off, even on a chain without accept.
    $bwExpRecipe = $chainRecipe | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $bwExpRecipe.origin = 'bitworks-experimental'
    Check ($null -eq (& $chainSelect $bwExpRecipe $showList $null '' $false) -and $null -eq (& $chainSelect $bwExpRecipe $showList $null '' $true) -and $null -eq (& $chainSelect $bwExpRecipe $acceptList $null '' $true)) 'a bitworks-experimental recipe is never auto-selected, with or without the experimental inclusion, with or without accept'
    $bwExpNamed = & $chainSelect $bwExpRecipe $acceptList $null 'chain1' $false
    Check ($null -ne $bwExpNamed -and $bwExpNamed.recipe.origin -ceq 'bitworks-experimental') 'a bitworks-experimental recipe named with -Recipe is selected'
    # The ENGINE's own accept is the only accept in the chain (runtime show), with requires and without any requires.
    $engineOnlyAccept = @($showList | ForEach-Object { $copy = $_ | ConvertTo-Json -Depth 20 | ConvertFrom-Json; if ($copy.id -ceq 'eng-hip') { $copy.license.consent = 'accept' }; $copy })
    Check (@($engineOnlyAccept | Where-Object { $_.license.consent -ceq 'accept' }).Count -eq 1 -and $null -eq (& $chainSelect $chainRecipe $engineOnlyAccept $null '' $false) -and $null -ne (& $chainSelect $chainRecipe $engineOnlyAccept $null 'chain1' $false)) 'an accept consent on the ENGINE alone (its required runtime is show) blocks auto-selection, and naming the recipe selects it'
    $soloEngine = $showList | Where-Object { $_.id -ceq 'eng-hip' } | ForEach-Object { $_ | ConvertTo-Json -Depth 20 | ConvertFrom-Json }
    $soloEngine.requires = @()
    $soloEngine.license.consent = 'accept'
    $soloShow = $soloEngine | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $soloShow.license.consent = 'show'
    Check ($null -eq (& $chainSelect $chainRecipe @($soloEngine) $null '' $false) -and $null -ne (& $chainSelect $chainRecipe @($soloShow) $null '' $false)) 'a single engine with accept consent and no requires is blocked (control: the same engine with show consent is picked)'
    # An unresolvable chain fails closed: the recipe is not auto-selected (control: the same list with a listed requires and show consent is picked).
    $unknownRequires = $soloShow | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $unknownRequires.requires = @('no-such-runtime')
    $unknownSink = New-Object 'System.Collections.Generic.List[string]'
    Check ($null -eq (& $chainSelect $chainRecipe @($unknownRequires) $unknownSink '' $false) -and @($unknownSink | Where-Object { $_ -like 'chain1: needs-license-acceptance*' }).Count -eq 1) 'an engine whose requires cannot be resolved fails closed: not auto-selected, with the license-acceptance reason'

    # Visibility and the gate, for both experimental origins.
    $bwGateRecipes = @((New-GateRecipe 'b1' 'bitworks'), (New-GateRecipe 'x1' 'bitworks-experimental'))
    Check (@(Select-FastLlmVisibleRecipes -Recipes $bwGateRecipes -ExperimentalComponents 'off').Count -eq 1 -and @(Select-FastLlmVisibleRecipes -Recipes $bwGateRecipes).Count -eq 1 -and @(Select-FastLlmVisibleRecipes -Recipes $bwGateRecipes -ExperimentalComponents 'on').Count -eq 2) 'a bitworks-experimental recipe is hidden unless the switch is on'
    $hipGateRecipe = New-GateRecipe 'x2' 'bitworks-experimental'
    $hipGateRecipe.components.engine = 'eng-hip'
    $hipGateRoot = New-TestRoot
    $hipGateOff = Get-ThrownMessage { Assert-FastLlmExperimentalRecipeAllowed -InstallRoot $hipGateRoot -RecipeId 'x2' -Recipes @($hipGateRecipe) -Components $acceptList -AcceptExperimental }
    Check ($null -ne $hipGateOff -and $hipGateOff -like '*switch is off*' -and $hipGateOff -like '*experimental Bitworks setup*') 'a bitworks-experimental recipe with the switch off is refused even with -AcceptExperimental'
    Check ($hipGateOff -like "*runtime rt-hip ($($hipFx.Part1Url), $($hipFx.Part2Url)*" -and $hipGateOff -like "*engine eng-hip ($($hipFx.EngineUrl)*" -and $hipGateOff.IndexOf('runtime rt-hip') -lt $hipGateOff.IndexOf('engine eng-hip') -and $hipGateOff -like '*model big-model (comes with this release)*') 'the refusal lists EVERY component of the engine chain (the required runtime and the engine) with all their source URLs, then the model'
    $hipGateUpper = Get-ThrownMessage { Assert-FastLlmExperimentalRecipeAllowed -InstallRoot $hipGateRoot -RecipeId 'X2' -Recipes @($hipGateRecipe) -Components $acceptList -AcceptExperimental }
    Check ($null -ne $hipGateUpper -and $hipGateUpper -like "*engine eng-hip*") 'a bitworks-experimental recipe named in another case (X2 for x2) is refused too'
    Check (Test-FastLlmExperimentalOrigin -Origin 'Bitworks-Experimental') 'the experimental-origin test ignores case, so a mixed-case origin is still gated'
    Set-FastLlmComponentSettings -InstallRoot $hipGateRoot -ExperimentalComponents 'on'
    $hipGateNoAccept = Get-ThrownMessage { Assert-FastLlmExperimentalRecipeAllowed -InstallRoot $hipGateRoot -RecipeId 'x2' -Recipes @($hipGateRecipe) -Components $acceptList }
    Check ($null -ne $hipGateNoAccept -and $hipGateNoAccept -like '*-AcceptExperimental was not given*' -and $hipGateNoAccept -like "*runtime rt-hip ($($hipFx.Part1Url)*" -and $hipGateNoAccept -like "*engine eng-hip ($($hipFx.EngineUrl)*") 'switch on without -AcceptExperimental is refused and still lists the whole chain'
    Check ($null -eq (Get-ThrownMessage { Assert-FastLlmExperimentalRecipeAllowed -InstallRoot $hipGateRoot -RecipeId 'x2' -Recipes @($hipGateRecipe) -Components $acceptList -AcceptExperimental })) 'switch on plus -AcceptExperimental passes the gate for a bitworks-experimental recipe'
    $shippedRecipeDocument = Get-Content -LiteralPath (Join-Path $repoRoot 'config/recipes.json') -Raw | ConvertFrom-Json
    $shippedHipGate = @($shippedRecipeDocument.recipes | Where-Object { $_.id -ceq 'rx-7900-xtx.qwen3.8-27b-ud-q4-k-m.32k.hip' })
    $shippedHipRefusal = Get-ThrownMessage { Assert-FastLlmExperimentalRecipeAllowed -InstallRoot (New-TestRoot) -RecipeId 'rx-7900-xtx.qwen3.8-27b-ud-q4-k-m.32k.hip' -Recipes $shippedHipGate -Components $shipped }
    Check ($null -ne $shippedHipRefusal -and $shippedHipRefusal -like '*runtime amd-rocm-gfx1100-10.0.0 (https://stable.repo.amd.com/rocm/core/whl-next/rocm-sdk-libraries/*, https://stable.repo.amd.com/rocm/core/whl-next/rocm-sdk-device-gfx1100/*' -and $shippedHipRefusal -like '*engine llama.cpp-hip-b11658 (https://github.com/ggml-org/llama.cpp/releases/download/b11658/*release-assets.githubusercontent.com*') 'the shipped HIP recipe refusal lists the AMD runtime (both wheels) and the engine, with the redirect hosts'

    # The shipped HIP recipes: the Vulkan recipe of each card with the HIP engine, experimental, unmeasured.
    foreach ($hipPair in @(@('rx-7900-xt.qwen3.8-27b-ud-iq4-xs.16k', 'rx-7900-xt'), @('rx-7900-xtx.qwen3.8-27b-ud-q4-k-m.32k', 'rx-7900-xtx'))) {
        $vulkanTwin = @($shippedRecipeDocument.recipes | Where-Object { $_.id -ceq $hipPair[0] })[0]
        $hipTwin = @($shippedRecipeDocument.recipes | Where-Object { $_.id -ceq ($hipPair[0] + '.hip') })
        Check ($hipTwin.Count -eq 1) "the shipped list has $($hipPair[0]).hip"
        $hipTwin = $hipTwin[0]
        Check ($hipTwin.origin -ceq 'bitworks-experimental' -and $hipTwin.label -ceq 'Experimental Bitworks setup, not yet measured by Bitworks on this card' -and $hipTwin.components.engine -ceq 'llama.cpp-hip-b11658' -and $hipTwin.engineBuild -ceq 'b11658') "$($hipPair[0]).hip is bitworks-experimental on the HIP engine"
        Check ($hipTwin.components.model -ceq $vulkanTwin.components.model -and $hipTwin.runtime.contextSize -eq $vulkanTwin.runtime.contextSize -and $hipTwin.runtime.cacheTypeK -ceq $vulkanTwin.runtime.cacheTypeK -and $hipTwin.runtime.cacheTypeV -ceq $vulkanTwin.runtime.cacheTypeV -and $hipTwin.gpu.variant -ceq $vulkanTwin.gpu.variant -and $hipTwin.gpu.count -eq $vulkanTwin.gpu.count) "$($hipPair[0]).hip has the same model, context size, KV cache types and card as its Vulkan recipe"
        Check (-not $hipTwin.runtime.PSObject.Properties['vulkanBarMitigation'] -and $null -eq $hipTwin.expected -and $null -eq $hipTwin.evidence -and $hipTwin.recommended -eq $false) "$($hipPair[0]).hip has no BAR mitigation, no expected or evidence block, and is not recommended"
    }
    # Shipped data, end to end through the recipe list a PC sees.
    $shippedVisibleOff = @(Select-FastLlmVisibleRecipes -Recipes @($shippedRecipeDocument.recipes) -ExperimentalComponents 'off')
    $shippedVisibleOn = @(Select-FastLlmVisibleRecipes -Recipes @($shippedRecipeDocument.recipes) -ExperimentalComponents 'on')
    Check (@($shippedVisibleOff | Where-Object { $_.id -like '*.hip' }).Count -eq 0 -and @($shippedVisibleOn | Where-Object { $_.id -like '*.hip' }).Count -eq 2) 'the shipped HIP recipes are hidden with the switch off and listed with it on'
    foreach ($hipHardware in @($xtxHardware, $xtHardware)) {
        $hipAutoDxgi = @($hipHardware.dxgiAdapters)
        $hipAutoPlacement = [pscustomobject] @{ adapters = @([pscustomobject] @{ name = 'n'; vramMiB = [int] $hipHardware.adapters[0].vramMiB }); selectionCapacity = 23000 }
        $shippedCatalogObject = Get-Content -LiteralPath $shippedCatalogPath -Raw | ConvertFrom-Json
        $shippedAuto = Select-FastLlmRecipeForPlacements -Recipes @($shippedRecipeDocument.recipes) -Variants $autoVariants -Placements @($hipAutoPlacement) -DxgiAdapters $hipAutoDxgi -Catalog $shippedCatalogObject -Profile 'balanced' -Components $shipped -IncludeExperimental
        Check ($null -ne $shippedAuto -and $shippedAuto.recipe.origin -ceq 'bitworks' -and $shippedAuto.recipe.id -notlike '*.hip') "automatic selection on $($hipHardware.adapters[0].name) keeps the shipped Vulkan recipe, even with the experimental inclusion on and the HIP components listed"
    }

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
    $branchDeclaration = 'function Invoke-CliBranchUnderTest { [CmdletBinding()] param([string] $Install, [string] $Remove, [switch] $AcceptLicense, [switch] $Unattended, [switch] $AsJson, [switch] $Detail, [string] $InstallRoot, [string] $componentsFilePath, [string] $recipesPath, [string] $catalogPath) '
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
    $null = Install-Fixture -Fixture $cliFixture -InstallRoot $cliRoot -Counter $cliCounter -AcceptLicense -Unattended
    $installedJson = (@(& $componentsFunction -InstallRoot $cliRoot -componentsFilePath $cliFixture.ComponentsPath -Install 'cli-engine-1' -AcceptLicense -AsJson 6>&1 | ForEach-Object { [string] $_ }) -join "`n") | ConvertFrom-Json
    Check ($installedJson.id -ceq 'cli-engine-1' -and $installedJson.installed -eq $true -and @($installedJson.installedComponents).Count -eq 0 -and $installedJson.path -like '*cli-engine-1*') 'components -Install -AsJson reports installedComponents (empty when the chain was already installed)'
    $installedText = @(& $componentsFunction -InstallRoot $cliRoot -componentsFilePath $cliFixture.ComponentsPath -Install 'cli-engine-1' -AcceptLicense 6>&1 | ForEach-Object { [string] $_ })
    Check (@($installedText | Where-Object { $_ -like "*'cli-engine-1' is already installed and verified*" }).Count -eq 1) 'components -Install on an installed chain says so instead of claiming an install'

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

    # recipes -Detail -AsJson: each recipe with its engine's requires chain, read-only and offline.
    $shippedCatalogPath = Join-Path $PSScriptRoot '../config/catalog.json'
    $shippedComponentsPath = Join-Path $PSScriptRoot '../config/components.json'
    $shippedRecipesPath = Join-Path $PSScriptRoot '../config/recipes.json'
    $detailRoot = New-TestRoot
    function Get-DetailRows([string] $Root) {
        $text = (@(& $recipesFunction -InstallRoot $Root -recipesPath $shippedRecipesPath -componentsFilePath $shippedComponentsPath -catalogPath $shippedCatalogPath -AsJson -Detail 6>&1 | ForEach-Object { [string] $_ }) -join "`n")
        return @($text | ConvertFrom-Json)
    }
    $detailOff = Get-DetailRows $detailRoot
    Check ($detailOff.Count -ge 1 -and @($detailOff | Where-Object { $_.origin -like '*experimental' }).Count -eq 0) 'recipes -Detail -AsJson hides experimental recipes when the switch is off'
    Set-FastLlmComponentSettings -InstallRoot $detailRoot -ExperimentalComponents 'on'
    $detailOn = Get-DetailRows $detailRoot
    $detailHip = @($detailOn | Where-Object { $_.id -like '*.hip' })
    Check ($detailHip.Count -eq 2 -and $detailOn.Count -eq $detailOff.Count + 2) 'recipes -Detail -AsJson lists the two HIP recipes when the switch is on'
    $hipDetail = $detailHip[0]
    Check ($hipDetail.origin -ceq 'bitworks-experimental' -and $hipDetail.label -ceq 'Experimental Bitworks setup, not yet measured by Bitworks on this card' -and $hipDetail.engineId -ceq 'llama.cpp-hip-b11658' -and $hipDetail.contextSize -gt 0 -and $hipDetail.model) 'a Detail row carries the recipe id, origin, label, engine, model and context'
    Check (@($hipDetail.chain).Count -eq 2 -and $hipDetail.chain[0].id -ceq 'amd-rocm-gfx1100-10.0.0' -and $hipDetail.chain[1].id -ceq 'llama.cpp-hip-b11658') 'the Detail chain lists the required runtime first and the engine last'
    Check ($hipDetail.chain[0].consent -ceq 'accept' -and $hipDetail.chain[1].consent -ceq 'accept' -and -not $hipDetail.chain[0].installed -and -not $hipDetail.chain[1].installed -and $hipDetail.consentRequired -eq $true) 'a HIP chain that is not installed needs consent'
    Check ((@($hipDetail.chain[0].sourceHosts) -join ',') -ceq 'stable.repo.amd.com' -and (@($hipDetail.chain[1].sourceHosts) -join ',') -ceq 'github.com' -and @($hipDetail.chain[1].redirectHosts) -contains 'objects.githubusercontent.com') 'the Detail chain names the source host of each component and the redirect hosts'
    $listedHip = @(Get-FastLlmComponents -ComponentsPath $shippedComponentsPath | Where-Object { $_.id -ceq 'llama.cpp-hip-b11658' })[0]
    $listedLinks = @(Get-FastLlmComponentLicenseLinks -Component $listedHip)
    Check ($listedLinks.Count -ge 2 -and @($hipDetail.chain[1].licenseLinks).Count -eq $listedLinks.Count -and $hipDetail.chain[1].licenseLinks[1].url -ceq [string] $listedLinks[1].url) 'the Detail chain carries the component''s license links'
    $listedRuntime = @(Get-FastLlmComponents -ComponentsPath $shippedComponentsPath | Where-Object { $_.id -ceq 'amd-rocm-gfx1100-10.0.0' })[0]
    New-Item -ItemType Directory -Path (Get-FastLlmComponentRoot -InstallRoot $detailRoot -Component $listedRuntime) -Force | Out-Null
    $detailPartial = @(Get-DetailRows $detailRoot | Where-Object { $_.id -like '*.hip' })[0]
    Check ($detailPartial.chain[0].installed -eq $true -and $detailPartial.chain[1].installed -eq $false -and $detailPartial.consentRequired -eq $true) 'Detail reads the installed state per component from the inventory'
    New-Item -ItemType Directory -Path (Get-FastLlmComponentRoot -InstallRoot $detailRoot -Component $listedHip) -Force | Out-Null
    $detailFull = @(Get-DetailRows $detailRoot | Where-Object { $_.id -like '*.hip' })[0]
    Check ($detailFull.consentRequired -eq $false) 'a fully installed chain needs no consent'
    $detailVulkan = @($detailOff | Where-Object { $_.engineId -ceq 'llama.cpp-b10698-vulkan' })[0]
    Check ($null -ne $detailVulkan -and $detailVulkan.consentRequired -eq $false -and $detailVulkan.chain[0].consent -ceq 'show') 'a built-in Vulkan recipe lists its engine and needs no consent'
    $hostsSample = @(Get-FastLlmComponentSourceHosts -Listed $listedRuntime)
    Check ($hostsSample.Count -eq 1 -and $hostsSample[0] -ceq 'stable.repo.amd.com') 'the source host of a multi-part component is read from its source URLs'

    # fast-llm.ps1 argument rules and wiring.
    Check ($cliText.Contains("'update-check', 'update', 'components')]") -and $cliText.Contains('[switch] $List') -and $cliText.Contains('[string] $Install') -and $cliText.Contains('[string] $Remove') -and $cliText.Contains('[switch] $AcceptLicense') -and $cliText.Contains('[switch] $AcceptExperimental') -and $cliText.Contains('[switch] $Detail')) 'fast-llm.ps1 declares the components action, -List, -Install, -Remove, -AcceptLicense, -AcceptExperimental and -Detail'
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
            @{ args = @('recipes', '-Detail', '-InstallRoot', $refusalRoot); text = '-Detail is supported only by recipes with -AsJson.' },
            @{ args = @('plan', '-Detail', '-AsJson', '-InstallRoot', $refusalRoot); text = '-Detail is supported only by recipes with -AsJson.' },
            @{ args = @('start', '-AcceptLicense', '-InstallRoot', $refusalRoot); text = '-AcceptLicense is supported only by components.' },
            @{ args = @('components', '-AcceptExperimental', '-InstallRoot', $refusalRoot); text = '-AcceptExperimental is supported only by plan, start and install.' },
            @{ args = @('components', '-Install', 'a', '-Remove', 'b', '-InstallRoot', $refusalRoot); text = 'components takes one of -List, -Install <id> or -Remove <id>.' },
            @{ args = @('components', '-List', '-AcceptLicense', '-InstallRoot', $refusalRoot); text = '-AcceptLicense is supported only with components -Install.' })) {
        $result = Invoke-CliRefusal $case.args
        Check ($result.exit -ne 0 -and $result.text.Contains($case.text)) ("fast-llm.ps1 " + ($case.args[0..1] -join ' ') + ' is refused: ' + $case.text)
    }
    # components commands hold the lock for mutual exclusion only: status.json is never written, and -Remove is not blocked by the CLI's own lock.
    $statusRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('c3s' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $statusRoot -Force | Out-Null
    $statusFile = Join-Path (& $module { param($r) Get-FastLlmStateRoot -InstallRoot $r -Create } $statusRoot) 'status.json'
    $shippedVulkan = @(Get-FastLlmComponents -ComponentsPath (Join-Path $PSScriptRoot '../config/components.json') | Where-Object { $_.id -ceq 'llama.cpp-b10698-vulkan' })[0]
    $vulkanRoot = Get-FastLlmComponentRoot -InstallRoot $statusRoot -Component $shippedVulkan
    New-Item -ItemType Directory -Path $vulkanRoot -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $vulkanRoot 'llama-server.exe'), 'x')
    Write-FastLlmState -InstallRoot $statusRoot -State ([ordered] @{ schemaVersion = 1; runId = ('c' * 32); phase = 'installed' })
    $statusBefore = [System.IO.File]::ReadAllBytes($statusFile)
    $failedInstall = Invoke-CliRefusal @('components', '-Install', 'llama.cpp-hip-b11658', '-Unattended', '-InstallRoot', $statusRoot)
    Check ($failedInstall.exit -ne 0 -and $failedInstall.text.Contains('component-consent-required')) 'a components -Install that needs consent fails with the typed refusal'
    Check ((@([System.IO.File]::ReadAllBytes($statusFile)) -join ',') -ceq ($statusBefore -join ',')) 'a failed components command leaves status.json byte-identical'
    $removeAfter = Invoke-CliRefusal @('components', '-Remove', 'llama.cpp-b10698-vulkan', '-InstallRoot', $statusRoot)
    Check ($removeAfter.exit -eq 0 -and -not (Test-Path -LiteralPath $vulkanRoot)) 'components -Remove of an installed component succeeds under the CLI''s own lock after an install (status phase installed, nothing running) and after a failed components command'
    Check ((@([System.IO.File]::ReadAllBytes($statusFile)) -join ',') -ceq ($statusBefore -join ',')) 'a successful components -Remove leaves status.json byte-identical too'
    New-Item -ItemType Directory -Path $vulkanRoot -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $vulkanRoot 'llama-server.exe'), 'x')
    Write-FastLlmState -InstallRoot $statusRoot -State ([ordered] @{ schemaVersion = 1; runId = ('d' * 32); phase = 'stopped'; engineExecutable = (Join-Path $vulkanRoot 'llama-server.exe'); engineComponentId = 'llama.cpp-b10698-vulkan' })
    $removeStopped = Invoke-CliRefusal @('components', '-Remove', 'llama.cpp-b10698-vulkan', '-InstallRoot', $statusRoot)
    Check ($removeStopped.exit -eq 0 -and -not (Test-Path -LiteralPath $vulkanRoot)) 'components -Remove succeeds for the engine recorded in a stopped status (nothing is running)'
    Remove-Item -LiteralPath $statusRoot -Recurse -Force -ErrorAction SilentlyContinue
    $cliSource = Get-Content -LiteralPath $cliPath -Raw
    Check ($cliSource.Contains('$componentsLock = Enter-FastLlmOperation') -and $cliSource.Contains('-OperationLockHeld:') -and $cliSource -match 'if \(\$componentsLock\) \{ \$componentsLock\.Dispose\(\) \}') 'the components lock is its own variable (the failure writer only knows $operationLock), is passed to Remove, and is disposed'
    # components -Install and -Remove take the operation lock.
    $lockRoot = New-TestRoot
    $heldLock = Enter-FastLlmOperation -InstallRoot $lockRoot
    try { $lockResult = Invoke-CliRefusal @('components', '-Remove', 'llama.cpp-b10698-vulkan', '-InstallRoot', $lockRoot) }
    finally { $heldLock.Dispose() }
    Check ($lockResult.exit -ne 0 -and $lockResult.text.Contains('Another FastLLM install/start operation is active')) 'components -Remove is refused while another operation holds the lock'
    $unlockedResult = Invoke-CliRefusal @('components', '-Remove', 'llama.cpp-b10698-vulkan', '-InstallRoot', $lockRoot)
    Check ($unlockedResult.exit -eq 0) 'the same command runs once the lock is free (positive control)'
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "components-tests: $script:checks checks passed"
# The CLI refusal cases leave a child's non-zero exit code in $LASTEXITCODE. CI runs the suites in one session and fails the step
# when the final value is non-zero, so reset it once every check has passed.
$global:LASTEXITCODE = 0
