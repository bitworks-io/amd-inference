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

Describe 'ConvertTo-FastLlmVersionInfoText' {
    BeforeAll { $script:ver = '2026.10.14.1' }
    It 'strips 40 trailing spaces' {
        ConvertTo-FastLlmVersionInfoText ($script:ver + (' ' * 40)) | Should -BeExactly $script:ver
    }
    It 'strips trailing NULs' {
        ConvertTo-FastLlmVersionInfoText ($script:ver + [string]::new([char]0, 5)) | Should -BeExactly $script:ver
    }
    It 'strips a mix of trailing spaces and NULs' {
        ConvertTo-FastLlmVersionInfoText ($script:ver + '  ' + [string]::new([char]0, 3) + ' ' + [char]0) | Should -BeExactly $script:ver
    }
    It 'keeps a leading space so the exact comparison still fails' {
        $text = ConvertTo-FastLlmVersionInfoText (' ' + $script:ver + '   ')
        $text | Should -BeExactly (' ' + $script:ver)
        ($text -cne $script:ver) | Should -BeTrue
    }
    It 'keeps a trailing tab' {
        ConvertTo-FastLlmVersionInfoText ($script:ver + "`t") | Should -BeExactly ($script:ver + "`t")
    }
    It 'returns an empty string for null' {
        ConvertTo-FastLlmVersionInfoText $null | Should -BeExactly ''
    }
}

Describe 'installed tree versus signed package' {
    BeforeEach {
        $script:pkgTree = Join-Path $script:work ('pkg-' + [guid]::NewGuid().ToString('N'))
        $script:appTree = Join-Path $script:work ('app-' + [guid]::NewGuid().ToString('N'))
        foreach ($t in $script:pkgTree, $script:appTree) {
            New-Item -ItemType Directory -Force -Path (Join-Path $t 'src'), (Join-Path $t 'config') | Out-Null
            Set-Content -LiteralPath (Join-Path $t 'fast-llm.ps1') -Value 'root' -Encoding ascii
            Set-Content -LiteralPath (Join-Path $t 'src\a.ps1') -Value 'a' -Encoding ascii
            Set-Content -LiteralPath (Join-Path $t 'config\c.json') -Value '{}' -Encoding ascii
            Set-Content -LiteralPath (Join-Path $t 'FastLLM.cat') -Value 'cat' -Encoding ascii
        }
        $script:skipNames = @('unins000.exe', 'unins000.dat', 'unins000.msg')
    }
    It 'accepts an identical tree and ignores _uninstall and unins000.*' {
        New-Item -ItemType Directory -Force -Path (Join-Path $script:appTree '_uninstall') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:appTree '_uninstall\unins000.exe') -Value 'u' -Encoding ascii
        Set-Content -LiteralPath (Join-Path $script:appTree 'unins000.dat') -Value 'u' -Encoding ascii
        Test-FastLlmTreeMatchesPackage -PackagePath $script:pkgTree -InstalledPath $script:appTree -SkipNames $script:skipNames -SkipPrefixes '_uninstall\' | Should -Be 4
    }
    It 'rejects an extra installed file' {
        Set-Content -LiteralPath (Join-Path $script:appTree 'src\extra.ps1') -Value 'x' -Encoding ascii
        { Test-FastLlmTreeMatchesPackage -PackagePath $script:pkgTree -InstalledPath $script:appTree -SkipNames $script:skipNames -SkipPrefixes '_uninstall\' } | Should -Throw '*installed only*extra.ps1*'
    }
    It 'rejects a file missing from the installed tree' {
        Remove-Item -LiteralPath (Join-Path $script:appTree 'config\c.json')
        { Test-FastLlmTreeMatchesPackage -PackagePath $script:pkgTree -InstalledPath $script:appTree -SkipNames $script:skipNames -SkipPrefixes '_uninstall\' } | Should -Throw '*package only*c.json*'
    }
    It 'rejects a changed file with the same name' {
        Set-Content -LiteralPath (Join-Path $script:appTree 'src\a.ps1') -Value 'changed' -Encoding ascii
        { Test-FastLlmTreeMatchesPackage -PackagePath $script:pkgTree -InstalledPath $script:appTree -SkipNames $script:skipNames -SkipPrefixes '_uninstall\' } | Should -Throw '*does not equal the signed package tree*'
    }
    It 'rejects a tree mismatch even when the installed tree carries its own matching catalog' {
        Set-Content -LiteralPath (Join-Path $script:appTree 'extra.txt') -Value 'x' -Encoding ascii
        Remove-Item -LiteralPath (Join-Path $script:appTree 'FastLLM.cat')
        New-FileCatalog -Path $script:appTree -CatalogFilePath (Join-Path $script:appTree 'FastLLM.cat') -CatalogVersion 2 | Out-Null
        { Test-FastLlmTreeMatchesPackage -PackagePath $script:pkgTree -InstalledPath $script:appTree -SkipNames $script:skipNames -SkipPrefixes '_uninstall\' } | Should -Throw '*differences*'
    }
    It 'rejects an installed catalog whose hash differs from the package catalog' {
        { Test-FastLlmFileHashEqual -Path (Join-Path $script:appTree 'FastLLM.cat') -ReferencePath (Join-Path $script:pkgTree 'FastLLM.cat') } | Should -Not -Throw
        Set-Content -LiteralPath (Join-Path $script:appTree 'FastLLM.cat') -Value 'other catalog' -Encoding ascii
        { Test-FastLlmFileHashEqual -Path (Join-Path $script:appTree 'FastLLM.cat') -ReferencePath (Join-Path $script:pkgTree 'FastLLM.cat') } | Should -Throw '*differs from the package copy*'
    }
}

Describe 'Test-FastLlmPackageScriptsSigned' {
    BeforeEach {
        $script:sigPkg = Join-Path $script:work ('sig-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $script:sigPkg 'config\schemas') | Out-Null
        $script:sigArgs = @{ ExpectedRootThumbprint = $script:cert.Thumbprint; RequiredEkus = $script:codeSigning; AllowUntrustedRootForTests = $true }
        foreach ($rel in 'fast-llm.ps1', 'config\schemas\ok.ps1') {
            $signed = New-SignedScript ('s-' + [guid]::NewGuid().ToString('N') + '.ps1') $script:cert
            Copy-Item -LiteralPath $signed -Destination (Join-Path $script:sigPkg $rel)
        }
    }
    It 'counts signed scripts at every depth' {
        Test-FastLlmPackageScriptsSigned -PackagePath $script:sigPkg -SignatureArgs $script:sigArgs | Should -Be 2
    }
    It 'rejects an unsigned script in a subfolder outside src and tools' {
        Set-Content -LiteralPath (Join-Path $script:sigPkg 'config\schemas\validate.ps1') -Value 'x' -Encoding ascii
        { Test-FastLlmPackageScriptsSigned -PackagePath $script:sigPkg -SignatureArgs $script:sigArgs } | Should -Throw '*signature not valid*validate.ps1*'
    }
    It 'rejects an unsigned module or manifest in a subfolder' {
        New-Item -ItemType Directory -Force -Path (Join-Path $script:sigPkg 'licenses') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:sigPkg 'licenses\m.psm1') -Value 'x' -Encoding ascii
        { Test-FastLlmPackageScriptsSigned -PackagePath $script:sigPkg -SignatureArgs $script:sigArgs } | Should -Throw '*m.psm1*'
        Remove-Item -LiteralPath (Join-Path $script:sigPkg 'licenses\m.psm1')
        Set-Content -LiteralPath (Join-Path $script:sigPkg 'licenses\m.psd1') -Value '@{}' -Encoding ascii
        { Test-FastLlmPackageScriptsSigned -PackagePath $script:sigPkg -SignatureArgs $script:sigArgs } | Should -Throw '*m.psd1*'
    }
}
