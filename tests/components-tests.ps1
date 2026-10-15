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

try {
    # ---- Exports and the shipped components.json ----
    foreach ($name in @('Get-FastLlmComponents', 'Get-FastLlmComponentRoot', 'Test-FastLlmComponentInstallation', 'Install-FastLlmComponent', 'Get-FastLlmComponentInventory', 'Remove-FastLlmComponent')) {
        Check ($null -ne (Get-Command -Name $name -Module FastLlm -ErrorAction SilentlyContinue)) "$name is exported"
    }
    $shipped = @(Get-FastLlmComponents -ComponentsPath (Join-Path $PSScriptRoot '../config/components.json'))
    Check ($shipped.Count -ge 1 -and [string] $shipped[0].id -ceq 'llama.cpp-b10698-vulkan') 'the shipped components.json loads and lists the b10698 Vulkan engine'
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

    # ---- Happy install (consent: show) ----
    $fx = New-Fixture -Dir (Join-Path $work 'fx-happy')
    $installRoot = New-TestRoot
    $counter = @{ count = 0 }
    $root = Install-Fixture -Fixture $fx -InstallRoot $installRoot -Counter $counter -AcceptLicense -Unattended
    $component = @(Get-FastLlmComponents -ComponentsPath $fx.ComponentsPath)[0]
    Check ((Test-Path -LiteralPath (Join-Path $root 'server.exe')) -and (Test-Path -LiteralPath (Join-Path $root 'engine.dll'))) 'happy install: the files land in the component root'
    Check (Test-FastLlmComponentInstallation -InstallRoot $installRoot -Component $component) 'happy install: the installed root verifies against the manifest'
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
    $accEntry = @(Get-FastLlmComponents -ComponentsPath $fxAcc.ComponentsPath)[0]
    $accRootPath = Install-Fixture -Fixture $fxAcc -InstallRoot $accRoot -Counter $counterAcc -AcceptLicense
    $receiptPath = Join-Path (Join-Path $accRoot 'consents') 'component-test-engine-1-v1.json'
    Check (Test-Path -LiteralPath $receiptPath -PathType Leaf) 'consent accept writes consents\component-<id>-<version>.json'
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    Check ([int] $receipt.schemaVersion -eq 1 -and $receipt.id -ceq 'test-engine-1' -and $receipt.version -ceq 'v1' -and $receipt.licenseUrl -ceq 'https://example.com/LICENSE' -and $receipt.mode -ceq 'explicit-switch' -and $receipt.acceptedAt -match '^\d{4}-\d\d-\d\dT') 'the receipt carries schemaVersion, id, version, license url, acceptedAt and mode'
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
    $downloadsDir = Join-Path $badRoot 'downloads'
    Check (@(Get-ChildItem -LiteralPath $downloadsDir -Force | Where-Object { $_.Name -like '*.corrupt.*' }).Count -eq 1 -and @(Get-ChildItem -LiteralPath $downloadsDir -Force | Where-Object { $_.Name -eq 'test-engine-1-v1.zip' }).Count -eq 0) 'hash mismatch: the bad download is quarantined, not left in place'

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

    # ---- Save-FastLlmVerifiedFile: curl arguments are unchanged without -AllowedRedirectHosts ----
    $moduleSource = Get-Content -LiteralPath $modulePath -Raw
    $argumentBlock = [regex]::Match($moduleSource, '\$curlArguments = @\((?<body>.*?)\r?\n\s*\)', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    Check $argumentBlock.Success 'the curl argument list is found in the module source'
    $normalized = $argumentBlock.Groups['body'].Value -replace '\s+', ''
    $expectedArguments = '''--disable'',''--silent'',''--show-error'',''--location'',''--fail'',''--retry'',''3'',''--connect-timeout'',''30'',''--speed-limit'',''1024'',''--speed-time'',''60'',''--max-filesize'',[string]$SizeBytes,''--proto'',''=https'',''--proto-redir'',''=https'',''--continue-at'',''-'',''--output'',$partial,$Url'
    Check ($normalized -ceq $expectedArguments) 'the curl argument literal is byte-for-byte what it was before -AllowedRedirectHosts'
    Check ([regex]::Matches($moduleSource, '--write-out').Count -eq 1) '--write-out appears exactly once in the module'
    Check ($moduleSource -cmatch '(?s)if \(\$checkRedirectHosts\) \{\s*\$curlArguments = @\(''--write-out'', ''%\{url_effective\}''\) \+ \$curlArguments\s*\}') '--write-out is added only inside the -AllowedRedirectHosts branch'
    Check ($moduleSource -cmatch '\$checkRedirectHosts = \$PSBoundParameters\.ContainsKey\(''AllowedRedirectHosts''\)') 'the redirect check is keyed on the parameter being bound'

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
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "components-tests: $script:checks checks passed"
