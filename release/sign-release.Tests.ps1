BeforeAll {
    $script = Join-Path $PSScriptRoot 'sign-release.ps1'
    $cert = New-SelfSignedCertificate -Subject 'CN=Test Signer, O=Test Org' -Type CodeSigningCert -CertStoreLocation Cert:\CurrentUser\My
    $root = [IO.Path]::Combine($env:TEMP, 'fastllm-sign-tests-' + [guid]::NewGuid())
    function New-UnsignedZip([string]$dir) {
        $tree = Join-Path $dir 'src-tree'
        New-Item -ItemType Directory -Force -Path (Join-Path $tree 'src'),(Join-Path $tree 'tools'),(Join-Path $tree 'tests') | Out-Null
        'Write-Output 1' | Set-Content (Join-Path $tree 'fast-llm.ps1')
        'Write-Output 2' | Set-Content (Join-Path $tree 'src\a.ps1')
        'Write-Output 3' | Set-Content (Join-Path $tree 'tools\b.psm1')
        'Write-Output 4' | Set-Content (Join-Path $tree 'tests\t.ps1')
        '@echo off' | Set-Content (Join-Path $tree 'FastLLM.cmd')
        '{"version":"2026.10.13.90"}' | Set-Content (Join-Path $tree 'FASTLLM-VERSION.json')
        $release = '{"builtAtUtc":"2026-10-13T12:00:00Z","channel":"canary","component":"fastllm-lab","manifestSha256":"' + ('0'*64) + '","minAgentVersion":"0.10.0","schema":"bitworks.fastllm-release/v1","version":"2026.10.13.90"}'
        [IO.File]::WriteAllText((Join-Path $tree 'RELEASE.json'), $release + "`n")
        & python (Join-Path $PSScriptRoot 'release_json.py') regen-manifest $tree | Out-Null
        $zip = Join-Path $dir 'unsigned.zip'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory($tree, $zip)
        return $zip
    }
    function Sign-Timestamped([string]$file) {
        $r = Set-AuthenticodeSignature -FilePath $file -Certificate $cert -TimestampServer 'http://timestamp.digicert.com' -HashAlgorithm SHA256
        if ($r.Status -notin 'Valid','UnknownError','NotTrusted' -or -not $r.TimeStamperCertificate) { throw "test signing setup failed for ${file}: $($r.Status) $($r.StatusMessage) ts=$([bool]$r.TimeStamperCertificate)" }
        Write-Host "self-signed Status observed: $($r.Status)"
    }
    function Sign-List([string]$work) {
        Get-Content (Join-Path $work 'sign-list.txt') | ForEach-Object { Sign-Timestamped $_ }
    }
}
AfterAll { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue; Remove-Item $cert.PSPath -ErrorAction SilentlyContinue }

Describe 'sign-release' {
    It 'Prepare lists only root, src and tools scripts' {
        $w = Join-Path $root 'p1'; $zip = New-UnsignedZip $w
        & $script -Phase Prepare -Version 2026.10.13.90 -UnsignedZip $zip -ExpectedSha256 (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower() -WorkDir $w
        $list = Get-Content (Join-Path $w 'sign-list.txt') | ForEach-Object { $_.Substring((Join-Path $w 'tree').Length + 1) } | Sort-Object
        $list | Should -Be @('fast-llm.ps1','src\a.ps1','tools\b.psm1')
    }
    It 'Prepare refuses a sha mismatch' {
        $w = Join-Path $root 'p2'; $zip = New-UnsignedZip $w
        { & $script -Phase Prepare -Version 2026.10.13.90 -UnsignedZip $zip -ExpectedSha256 ('f'*64) -WorkDir $w } | Should -Throw '*sha256*'
    }
    It 'Prepare refuses a version mismatch in RELEASE.json' {
        $w = Join-Path $root 'p3'; $zip = New-UnsignedZip $w
        { & $script -Phase Prepare -Version 2026.10.13.91 -UnsignedZip $zip -ExpectedSha256 (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower() -WorkDir $w } | Should -Throw '*version*'
    }
    It 'Assert-Signed fails without timestamp' {
        $w = Join-Path $root 'p4'; $zip = New-UnsignedZip $w
        & $script -Phase Prepare -Version 2026.10.13.90 -UnsignedZip $zip -ExpectedSha256 (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower() -WorkDir $w
        Get-Content (Join-Path $w 'sign-list.txt') | ForEach-Object { Set-AuthenticodeSignature -FilePath $_ -Certificate $cert -HashAlgorithm SHA256 | Out-Null }
        { & $script -Phase AfterScripts -WorkDir $w -ExpectedOrganization 'Test Org' -AllowUntrustedRootForTests } | Should -Throw '*timestamp*'
    }
    It 'Full flow produces an exact catalog, a manifest, and an offer' {
        $w = Join-Path $root 'p5'; $zip = New-UnsignedZip $w
        & $script -Phase Prepare -Version 2026.10.13.90 -UnsignedZip $zip -ExpectedSha256 (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower() -WorkDir $w
        Sign-List $w
        & $script -Phase AfterScripts -WorkDir $w -ExpectedOrganization 'Test Org' -AllowUntrustedRootForTests
        Sign-Timestamped (Join-Path $w 'FastLLM.cat')
        & $script -Phase AfterCatalog -WorkDir $w -Version 2026.10.13.90 -ExpectedOrganization 'Test Org' -AllowUntrustedRootForTests
        $offer = Get-Content (Join-Path $w 'out\OFFER.json') -Raw | ConvertFrom-Json
        $offer.packageSha256 | Should -Be (Get-FileHash (Join-Path $w 'out\package.zip') -Algorithm SHA256).Hash.ToLower()
        $check = Test-FileCatalog -CatalogFilePath (Join-Path $w 'tree\FastLLM.cat') -Path (Join-Path $w 'tree') -FilesToSkip 'FastLLM.cat' -Detailed
        $check.Status | Should -Be 'Valid'
    }
    It 'AfterCatalog refuses an extra file added after cataloguing' {
        $w = Join-Path $root 'p6'; $zip = New-UnsignedZip $w
        & $script -Phase Prepare -Version 2026.10.13.90 -UnsignedZip $zip -ExpectedSha256 (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower() -WorkDir $w
        Sign-List $w
        & $script -Phase AfterScripts -WorkDir $w -ExpectedOrganization 'Test Org' -AllowUntrustedRootForTests
        Sign-Timestamped (Join-Path $w 'FastLLM.cat')
        'x' | Set-Content (Join-Path $w 'tree\src\extra.ps1')
        { & $script -Phase AfterCatalog -WorkDir $w -Version 2026.10.13.90 -ExpectedOrganization 'Test Org' -AllowUntrustedRootForTests } | Should -Throw '*catalog*'
    }
}
