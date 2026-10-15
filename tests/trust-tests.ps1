$ErrorActionPreference='Stop'; Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/FastLlm.Trust.ps1')
$count=0; function Check([bool]$c,[string]$m){ if(-not $c){ throw "FAIL: $m" }; $script:count++; Write-Host "PASS: $m" }
$good=@{ Status='Valid'; SignerSubject='CN=Bitworks LLC, O=Bitworks LLC, L=Huntsville, S=Alabama, C=US'; RootThumbprint='F40042E2E5F7E8EF8189FED15519AECE42C3BFA2'
  Ekus=@('1.3.6.1.4.1.311.97.1.0','1.3.6.1.5.5.7.3.3','1.3.6.1.4.1.311.97.990689314.800187930.133508941.234438932'); ChainStatuses=@('NoError'); HasTimestamp=$true }
function T($o){ $p=$good.Clone(); foreach($k in $o.Keys){ $p[$k]=$o[$k] }; Test-FastLlmPinnedSignatureData @p }
Check ((T @{}).ok) 'a pinned Bitworks signature passes'
Check ((T @{Status='NotSigned'}).reason -eq 'not-valid') 'unsigned is refused'
Check ((T @{SignerSubject='CN=Someone, O=Other LLC'}).reason -eq 'wrong-publisher') 'another publisher is refused'
Check ((T @{RootThumbprint='0000000000000000000000000000000000000000'}).reason -eq 'wrong-root') 'another root is refused'
Check ((T @{Ekus=@('1.3.6.1.5.5.7.3.3')}).reason -eq 'missing-eku') 'a missing pinned EKU is refused'
Check ((T @{ChainStatuses=@('NotTimeValid');HasTimestamp=$true}).ok) 'an expired leaf with a timestamp passes'
Check ((T @{ChainStatuses=@('NotTimeValid');HasTimestamp=$false}).reason -eq 'bad-chain-status') 'an expired leaf without a timestamp is refused'
Check ((T @{ChainStatuses=@('Revoked')}).reason -eq 'bad-chain-status') 'any other chain status is refused'
Check ((ConvertTo-FastLlmVersionInfoText ('2026.10.15.1' + (' ' * 40))) -ceq '2026.10.15.1') 'Inno padding is trimmed'
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('trust-'+[guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  Check ((Test-FastLlmInstallIntegrity -AppRoot $tmp).status -eq 'not-installed') 'no FastLLM.cat means not-installed, not a failure'
  Set-Content -LiteralPath (Join-Path $tmp 'a.txt') -Value 'a' -Encoding ascii
  New-FileCatalog -Path $tmp -CatalogFilePath (Join-Path $tmp 'FastLLM.cat') -CatalogVersion 2 | Out-Null
  $r=Test-FastLlmInstallIntegrity -AppRoot $tmp
  Check ($r.status -eq 'failed' -and $r.reason -eq 'catalog-signature' -and $r.catalogSignature.reason -eq 'not-valid') 'an unsigned catalog fails integrity on its signature'
  $r=Test-FastLlmInstallIntegrity -AppRoot $tmp -SkipSignatureForTest
  Check ($r.status -eq 'ok') 'the tree matches its catalog (signature check skipped only by the test switch)'
  Set-Content -LiteralPath (Join-Path $tmp 'b.txt') -Value 'b' -Encoding ascii
  $r=Test-FastLlmInstallIntegrity -AppRoot $tmp -SkipSignatureForTest
  Check ($r.status -eq 'failed' -and (@($r.mismatches) -contains 'b.txt')) 'an added file fails and is named'
  New-Item -ItemType Directory -Path (Join-Path $tmp '_uninstall') | Out-Null; Set-Content -LiteralPath (Join-Path $tmp '_uninstall\unins000.dat') -Value 'u' -Encoding ascii
  Remove-Item -LiteralPath (Join-Path $tmp 'b.txt')
  Check ((Test-FastLlmInstallIntegrity -AppRoot $tmp -SkipSignatureForTest).status -eq 'ok') '_uninstall\ is excluded'
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force }
Write-Host "$count trust checks passed."
