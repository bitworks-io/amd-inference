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
# The pin overrides and the untrusted-root switch exist only for release/ReleaseVerify.psm1's tests: no product file may pass them.
$productFiles = @(Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter *.ps1 | Where-Object { $_.Name -ne 'FastLlm.Trust.ps1' }) +
    @(Get-ChildItem -LiteralPath (Join-Path $root 'tools') -Filter *.ps1) + @(Get-Item -LiteralPath (Join-Path $root 'fast-llm.ps1'), (Join-Path $root 'fast-llm-ui.ps1'))
$overrideUsers = @($productFiles | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match '-(ExpectedOrganization|ExpectedRootThumbprint|RequiredEkus|AllowUntrustedRootForTests)\b' } | ForEach-Object { $_.Name })
Check ($overrideUsers.Count -eq 0) ("no product file passes a pin override or the untrusted-root switch (found: " + ($overrideUsers -join ', ') + ")")
# doctor as a child process, against a temp copy of the entry script, src, config and tools (Windows only: doctor reads Windows state).
# These cases assert what the install-integrity check owns; doctor's hardware, plan and inventory checks are not under test here.
# doctor refuses to run elevated (by design), so these cases run only as a standard user: in the bench native gate, never on
# the elevated hosted runner, where they print an explicit SKIP.
$elevated = $false
if ($env:OS -eq 'Windows_NT') { $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
if ($env:OS -eq 'Windows_NT' -and $elevated) { Write-Host 'SKIP: doctor integrity child cases (doctor refuses elevation; they run as a standard user in the bench native gate)' }
if ($env:OS -eq 'Windows_NT' -and -not $elevated) {
  function Invoke-DoctorChild([string]$AppDir, [string]$InstallRoot) {
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=(Get-Process -Id $PID).Path
    $info.Arguments='-NoLogo -NoProfile -NonInteractive -File "'+(Join-Path $AppDir 'fast-llm.ps1')+'" doctor -InstallRoot "'+$InstallRoot+'"'
    $info.UseShellExecute=$false;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $child=[Diagnostics.Process]::Start($info)
    $out=$child.StandardOutput.ReadToEndAsync();$err=$child.StandardError.ReadToEndAsync()
    if(-not $child.WaitForExit(120000)){$child.Kill(); throw 'doctor child timed out'}
    $stdout=[string]$out.Result; $stderr=[string]$err.Result
    $lines=@($stdout -split "`r?`n"); $first=-1
    for($n=0;$n -lt $lines.Count;$n++){ if($lines[$n] -match '^\{'){ $first=$n; break } }
    $json=$null
    if($first -ge 0){ try { $json=(($lines[$first..($lines.Count-1)]) -join "`n") | ConvertFrom-Json } catch { $json=$null } }
    return [pscustomobject]@{exit=$child.ExitCode;json=$json;stdout=$stdout;stderr=$stderr}
  }
  function Clip([string]$Text){ if($Text.Length -gt 1500){ $Text.Substring(0,1500) } else { $Text } }
  function DoctorCheck($Child,[bool]$Condition,[string]$Message){
    if(-not $Condition){ Write-Host ("doctor child exit code: "+$Child.exit); Write-Host ("doctor child stdout (first 1500): "+(Clip $Child.stdout)); Write-Host ("doctor child stderr (first 1500): "+(Clip $Child.stderr)) }
    Check $Condition $Message
  }
  function Test-DoctorConsistent($Child){
    # exit 2 iff doctor's error is set
    if($null -eq $Child.json){ return $false }
    $hasError = -not [string]::IsNullOrEmpty([string]$Child.json.error)
    return (($Child.exit -eq 2) -eq $hasError)
  }
  function Test-NoIntegrityError($Child){ $e=[string]$Child.json.error; return ($e -notmatch '(?i)install integrity') }
  $doctorTmp=Join-Path ([IO.Path]::GetTempPath()) ('trust-doctor-'+[guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $doctorTmp | Out-Null
  try {
    $appDir=Join-Path $doctorTmp 'app'; New-Item -ItemType Directory -Path $appDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'fast-llm.ps1') -Destination $appDir
    foreach($d in 'src','config','tools'){ Copy-Item -LiteralPath (Join-Path $root $d) -Destination (Join-Path $appDir $d) -Recurse }
    $instRoot=Join-Path $doctorTmp 'data'
    $env:FASTLLM_TEST_SKIP_CATALOG_SIGNATURE=$null
    $dc=Invoke-DoctorChild $appDir $instRoot
    DoctorCheck $dc ($null -ne $dc.json) 'doctor: the child printed a JSON report'
    DoctorCheck $dc ($dc.json.installIntegrity.status -eq 'not-installed' -and $dc.json.installIntegrity.appRoot -eq $appDir) 'doctor: no FastLLM.cat reports not-installed with the app root'
    DoctorCheck $dc ($dc.json.installIntegrity.summary -eq 'Install integrity: not an installed release (no FastLLM.cat)') 'doctor: the not-installed line'
    DoctorCheck $dc ((Test-DoctorConsistent $dc) -and (Test-NoIntegrityError $dc)) 'doctor: not-installed adds no integrity error and exit 2 matches error'
    New-FileCatalog -Path $appDir -CatalogFilePath (Join-Path $appDir 'FastLLM.cat') -CatalogVersion 2 | Out-Null
    Set-Content -LiteralPath (Join-Path $appDir 'added.txt') -Value 'x' -Encoding ascii
    $dc=Invoke-DoctorChild $appDir $instRoot
    DoctorCheck $dc ($dc.exit -eq 2 -and $dc.json.installIntegrity.status -eq 'failed' -and $dc.json.installIntegrity.reason -eq 'catalog-signature' -and ([string]$dc.json.error) -match '(?i)install integrity') 'doctor: an unsigned catalog fails on its signature without the test variable'
    $env:FASTLLM_TEST_SKIP_CATALOG_SIGNATURE='1'
    $dc=Invoke-DoctorChild $appDir $instRoot
    DoctorCheck $dc ($dc.exit -eq 2 -and $dc.json.installIntegrity.status -eq 'failed' -and $dc.json.installIntegrity.reason -eq 'tree' -and $dc.json.installIntegrity.catalogSignature.reason -eq 'skipped-for-test' -and (@($dc.json.installIntegrity.mismatches) -contains 'added.txt') -and ([string]$dc.json.error) -match '(?i)install integrity') 'doctor: with the test variable, the added file is named and the exit is 2'
    DoctorCheck $dc ($dc.json.installIntegrity.summary -like 'Install integrity: FAILED (tree): *added.txt*') 'doctor: the failed line names the path'
    Remove-Item -LiteralPath (Join-Path $appDir 'added.txt')
    $dc=Invoke-DoctorChild $appDir $instRoot
    DoctorCheck $dc ($dc.json.installIntegrity.status -eq 'ok' -and $dc.json.installIntegrity.summary -eq 'Install integrity: ok') 'doctor: a matching tree reports ok (signature skipped only by the test variable)'
    DoctorCheck $dc ((Test-DoctorConsistent $dc) -and (Test-NoIntegrityError $dc)) 'doctor: ok adds no integrity error and exit 2 matches error'
  } finally { $env:FASTLLM_TEST_SKIP_CATALOG_SIGNATURE=$null; Remove-Item -LiteralPath $doctorTmp -Recurse -Force }
}
Write-Host "$count trust checks passed."
