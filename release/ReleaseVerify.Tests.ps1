BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ReleaseVerify.psm1') -Force
    $script:work = Join-Path ([IO.Path]::GetTempPath()) ('rv-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:work | Out-Null
    $script:cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=FastLLM Test Signer, O=Bitworks LLC' `
        -CertStoreLocation Cert:\CurrentUser\My -HashAlgorithm SHA256 -NotAfter (Get-Date).AddDays(2)
    $script:other = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=Someone Else, O=Other Org' `
        -CertStoreLocation Cert:\CurrentUser\My -HashAlgorithm SHA256 -NotAfter (Get-Date).AddDays(2)
    $script:codeSigning = @('1.3.6.1.5.5.7.3.3')
    function New-SignedScript([string]$Name, $Cert, [switch]$NoTimestamp) {
        $path = Join-Path $script:work $Name
        Set-Content -LiteralPath $path -Value "Write-Output 'hello'" -Encoding ascii
        $params = @{ FilePath = $path; Certificate = $Cert; HashAlgorithm = 'SHA256' }
        if (-not $NoTimestamp) { $params.TimestampServer = 'http://timestamp.digicert.com' }
        $null = Set-AuthenticodeSignature @params
        return $path
    }
    function Test-Ok([string]$Path, $Thumb = $script:cert.Thumbprint, $Ekus = $script:codeSigning) {
        Test-FastLlmReleaseSignature -Path $Path -ExpectedRootThumbprint $Thumb -RequiredEkus $Ekus -AllowUntrustedRootForTests
    }
}
AfterAll {
    foreach ($c in @($script:cert, $script:other)) { if ($c) { Remove-Item -LiteralPath ("Cert:\CurrentUser\My\" + $c.Thumbprint) -Force } }
    if ($script:work -and (Test-Path -LiteralPath $script:work)) { Remove-Item -LiteralPath $script:work -Recurse -Force }
}

Describe 'Test-FastLlmReleaseSignature' {
    It 'accepts a timestamped signature that matches every pin' {
        { Test-Ok (New-SignedScript 'ok.ps1' $script:cert) } | Should -Not -Throw
    }
    It 'rejects an unsigned file' {
        $path = Join-Path $script:work 'unsigned.ps1'; Set-Content -LiteralPath $path -Value 'x' -Encoding ascii
        { Test-Ok $path } | Should -Throw '*signature not valid*'
    }
    It 'rejects the wrong publisher' {
        { Test-Ok (New-SignedScript 'other.ps1' $script:other) $script:other.Thumbprint } | Should -Throw '*unexpected signer*'
    }
    It 'rejects a missing timestamp' {
        { Test-Ok (New-SignedScript 'nots.ps1' $script:cert -NoTimestamp) } | Should -Throw '*no timestamp*'
    }
    It 'rejects a missing EKU' {
        { Test-Ok (New-SignedScript 'eku.ps1' $script:cert) $script:cert.Thumbprint @('1.3.6.1.4.1.311.97.1.0') } | Should -Throw '*missing EKU*'
    }
    It 'rejects the wrong root' {
        { Test-Ok (New-SignedScript 'root.ps1' $script:cert) ('0' * 40) } | Should -Throw '*unexpected root*'
    }
    It 'rejects a file changed after signing' {
        $path = New-SignedScript 'tampered.ps1' $script:cert
        Add-Content -LiteralPath $path -Value '# changed' -Encoding ascii
        { Test-Ok $path } | Should -Throw '*signature not valid*'
    }
}

Describe 'Read-FastLlmSha256Sums' {
    It 'parses two-space lines' {
        $path = Join-Path $script:work 'S1'; [IO.File]::WriteAllText($path, ('a' * 64) + "  x.zip`n" + ('b' * 64) + "  y.exe`n")
        $sums = Read-FastLlmSha256Sums -Path $path
        $sums['x.zip'] | Should -Be ('a' * 64); $sums.Count | Should -Be 2
    }
    It 'rejects a malformed line' {
        $path = Join-Path $script:work 'S2'; [IO.File]::WriteAllText($path, "nothex  x.zip`n")
        { Read-FastLlmSha256Sums -Path $path } | Should -Throw '*malformed*'
    }
    It 'rejects a duplicate name' {
        $path = Join-Path $script:work 'S3'; [IO.File]::WriteAllText($path, ('a' * 64) + "  x.zip`n" + ('b' * 64) + "  x.zip`n")
        { Read-FastLlmSha256Sums -Path $path } | Should -Throw '*duplicate*'
    }
}

Describe 'Resolve-FastLlmReleaseTag' {
    It 'maps tags to channels' {
        Resolve-FastLlmReleaseTag -Tag 'v2026.10.16.1' -Version '2026.10.16.1' | Should -Be 'stable'
        Resolve-FastLlmReleaseTag -Tag 'v2026.10.16.2-canary' -Version '2026.10.16.2' | Should -Be 'canary'
    }
    It 'rejects a mismatch or a malformed tag' {
        { Resolve-FastLlmReleaseTag -Tag 'v2026.10.16.1' -Version '2026.10.16.2' } | Should -Throw
        { Resolve-FastLlmReleaseTag -Tag 'v2026.10.16.01' -Version '2026.10.16.01' } | Should -Throw
        { Resolve-FastLlmReleaseTag -Tag '2026.10.16.1' -Version '2026.10.16.1' } | Should -Throw
    }
}

Describe 'Test-FastLlmCatalogTree' {
    BeforeAll {
        $script:tree = Join-Path $script:work 'tree'
        New-Item -ItemType Directory -Force -Path (Join-Path $script:tree 'src') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:tree 'a.ps1') -Value 'a' -Encoding ascii
        Set-Content -LiteralPath (Join-Path $script:tree 'src\b.ps1') -Value 'b' -Encoding ascii
        $script:cat = Join-Path $script:work 'FastLLM.cat'
        New-FileCatalog -Path $script:tree -CatalogFilePath $script:cat -CatalogVersion 2 | Out-Null
    }
    It 'accepts an exact tree' { { Test-FastLlmCatalogTree -CatalogPath $script:cat -TreePath $script:tree } | Should -Not -Throw }
    It 'accepts extra files only under a skipped prefix' {
        New-Item -ItemType Directory -Force -Path (Join-Path $script:tree '_uninstall') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:tree '_uninstall\unins000.dat') -Value 'u' -Encoding ascii
        { Test-FastLlmCatalogTree -CatalogPath $script:cat -TreePath $script:tree -SkipNames 'unins000.dat' -SkipPrefixes '_uninstall\' } | Should -Not -Throw
        Remove-Item -LiteralPath (Join-Path $script:tree '_uninstall') -Recurse -Force
    }
    It 'rejects an extra file' {
        Set-Content -LiteralPath (Join-Path $script:tree 'extra.txt') -Value 'x' -Encoding ascii
        { Test-FastLlmCatalogTree -CatalogPath $script:cat -TreePath $script:tree } | Should -Throw '*does not match*'
        Remove-Item -LiteralPath (Join-Path $script:tree 'extra.txt') -Force
    }
    It 'rejects a changed file' {
        Set-Content -LiteralPath (Join-Path $script:tree 'a.ps1') -Value 'changed' -Encoding ascii
        { Test-FastLlmCatalogTree -CatalogPath $script:cat -TreePath $script:tree } | Should -Throw '*does not match*'
    }
}
