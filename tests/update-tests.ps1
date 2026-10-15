#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src/FastLlm.Update.ps1')
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; Write-Host "PASS: $Message" }

$stableApi = 'https://api.github.com/repos/bitworks-io/amd-inference/releases/latest'
$canaryApi = 'https://api.github.com/repos/bitworks-io/amd-inference/releases?per_page=10'
$good = 'https://github.com/bitworks-io/amd-inference/releases/download/'
$t0 = New-Object DateTime -ArgumentList 2026, 10, 20, 12, 0, 0, ([DateTimeKind]::Utc)

# --- tag parsing ---
$p = ConvertFrom-FastLlmReleaseTag 'v2026.10.15.1'
Check ($p.version -eq '2026.10.15.1' -and $p.channel -eq 'stable' -and @($p.numbers).Count -eq 4 -and $p.numbers[3] -eq 1) 'a stable tag parses'
$p = ConvertFrom-FastLlmReleaseTag 'v2026.10.15.12-canary'
Check ($p.version -eq '2026.10.15.12' -and $p.channel -eq 'canary') 'a canary tag parses'
Check ($null -eq (ConvertFrom-FastLlmReleaseTag 'v2026.10.15.1-beta')) 'a bad suffix is rejected'
Check ($null -eq (ConvertFrom-FastLlmReleaseTag 'v2026.10.15.0')) 'N=0 is rejected'
Check ($null -eq (ConvertFrom-FastLlmReleaseTag 'v2026.10.15.10000')) 'N=10000 is rejected'
Check ($null -ne (ConvertFrom-FastLlmReleaseTag 'v2026.10.15.9999')) 'N=9999 is accepted'
Check ($null -eq (ConvertFrom-FastLlmReleaseTag '2026.10.15.1')) 'a tag without the v is rejected'

# --- compare ---
Check ((Compare-FastLlmVersion '2026.10.15.2' '2026.10.15.1') -eq 1) '2026.10.15.2 is newer than 2026.10.15.1'
Check ((Compare-FastLlmVersion '2026.10.16.1' '2026.10.15.9') -eq 1) '2026.10.16.1 is newer than 2026.10.15.9'
Check ((Compare-FastLlmVersion '2026.11.01.1' '2026.10.31.9') -eq 1) '2026.11.01.1 is newer than 2026.10.31.9'
Check ((Compare-FastLlmVersion '2026.10.15.1' '2026.10.15.2') -eq -1) 'the older compares as -1'
Check ((Compare-FastLlmVersion '2026.10.15.1' '2026.10.15.1') -eq 0) 'equal versions compare as 0'
Check ((Compare-FastLlmVersion '2026.10.15.10' '2026.10.15.9') -eq 1) 'versions compare numerically, not as text'

# --- fixtures ---
function New-Env([string]$Version = '2026.10.15.1', [string]$Channel = 'stable', [bool]$WithRelease = $true) {
    $base = Join-Path ([IO.Path]::GetTempPath()) ("fastllm-update-" + [guid]::NewGuid().ToString('N'))
    $e = [pscustomobject]@{ Install = (Join-Path $base 'install'); App = (Join-Path $base 'app') }
    New-Item -ItemType Directory -Path $e.Install, $e.App -Force | Out-Null
    if ($WithRelease) { Set-Content -LiteralPath (Join-Path $e.App 'RELEASE.json') -Value (@{ version = $Version; channel = $Channel } | ConvertTo-Json) }
    $e
}
function Rel([string]$Tag, [bool]$Prerelease = $false, [bool]$Draft = $false, $Assets = $null) {
    if ($null -eq $Assets) { $Assets = @(@{ name = 'a.zip'; browser_download_url = ($good + $Tag + '/a.zip'); size = 100 }) }
    @{ tag_name = $Tag; draft = $Draft; prerelease = $Prerelease; html_url = "https://github.com/bitworks-io/amd-inference/releases/tag/$Tag"; assets = @($Assets) }
}
function Json($o) { ConvertTo-Json -InputObject $o -Depth 8 -Compress }
$script:calls = New-Object 'System.Collections.Generic.List[object]'
function Mock([int]$Status, [string]$Body, [string]$Etag = 'W/"e1"') {
    $script:calls.Clear()
    $s = $Status; $b = $Body; $t = $Etag; $log = $script:calls
    { param($Url, $Etag) $log.Add([pscustomobject]@{ Url = $Url; Etag = $Etag }); @{ Status = $s; Body = $b; Etag = $t } }.GetNewClosure()
}
function StatePath($e) { Join-Path (Join-Path $e.Install 'state') 'update-check.json' }

# --- stable channel ---
$e = New-Env
$r = Invoke-FastLlmUpdateCheck -InstallRoot $e.Install -AppRoot $e.App -Request (Mock 200 (Json (Rel 'v2026.10.16.1'))) -NowUtc $t0
Check ($r.status -eq 'available' -and $r.installed -eq '2026.10.15.1' -and $r.latest.version -eq '2026.10.16.1' -and $r.latest.tag -eq 'v2026.10.16.1' -and $r.latest.channel -eq 'stable') 'stable: a newer stable is available'
Check ($script:calls.Count -eq 1 -and $script:calls[0].Url -eq $stableApi -and $null -eq $script:calls[0].Etag) 'stable asks releases/latest, with no ETag the first time and no query'
Check ($r.latest.assets['a.zip'].size -eq 100 -and $r.latest.assets['a.zip'].url.StartsWith($good) -and $r.latest.htmlUrl -like '*v2026.10.16.1') 'the latest carries assets with url and size, and the page URL'
Check (Test-Path -LiteralPath (StatePath $e)) 'a 200 writes the state file'

$e = New-Env
$r = Invoke-FastLlmUpdateCheck -InstallRoot $e.Install -AppRoot $e.App -Request (Mock 200 (Json (Rel 'v2026.10.15.1'))) -NowUtc $t0
Check ($r.status -eq 'up-to-date' -and $r.latest.version -eq '2026.10.15.1') 'an equal version is up to date'

$e = New-Env -Version '2026.10.16.1' -Channel 'canary'
Set-FastLlmUpdateSettings -InstallRoot $e.Install -UpdateChannel 'stable'
$r = Invoke-FastLlmUpdateCheck -InstallRoot $e.Install -AppRoot $e.App -Request (Mock 200 (Json (Rel 'v2026.10.15.1'))) -NowUtc $t0
Check ($r.status -eq 'up-to-date') 'an older stable while a canary is installed is up to date'

$e = New-Env
$r = Invoke-FastLlmUpdateCheck -InstallRoot $e.Install -AppRoot $e.App -Request (Mock 200 (Json (Rel 'v2026.10.17.1-canary' $true))) -NowUtc $t0
Check ($r.status -eq 'up-to-date' -and $null -eq $r.latest) 'the stable channel ignores a canary or pre-release'

# --- canary channel ---
$e = New-Env -Channel 'canary'
$list = @((Rel 'v2026.10.14.1'), (Rel 'v2026.10.16.1-canary' $true), (Rel 'v2026.10.15.1-canary' $true))
$m = Mock 200 (Json $list)
$r = Invoke-FastLlmUpdateCheck -InstallRoot $e.Install -AppRoot $e.App -Request $m -NowUtc $t0
Check ($r.status -eq 'available' -and $r.latest.version -eq '2026.10.16.1' -and $r.latest.channel -eq 'canary') 'canary: offers the newest canary over an older stable'
Check ($script:calls[0].Url -eq $canaryApi) 'canary asks the list with per_page=10 and nothing else'

$e = New-Env -Channel 'canary'
$list = @((Rel 'v2026.10.20.1-canary' $true $true), (Rel 'not-a-tag'), (Rel 'v2026.10.17.0'), (Rel 'v2026.10.16.1-canary' $true))
$r = Invoke-FastLlmUpdateCheck -InstallRoot $e.Install -AppRoot $e.App -Request (Mock 200 (Json $list)) -NowUtc $t0
Check ($r.status -eq 'available' -and $r.latest.version -eq '2026.10.16.1') 'a draft and bad tags are ignored'

$e = New-Env -Channel 'canary'
$list = @((Rel 'v2026.10.16.1'), (Rel 'v2026.10.15.1-canary' $true))
$r = Invoke-FastLlmUpdateCheck -InstallRoot $e.Install -AppRoot $e.App -Request (Mock 200 (Json $list)) -NowUtc $t0
Check ($r.status -eq 'available' -and $r.latest.channel -eq 'stable') 'canary: a newer stable still beats an older canary'

# --- 24 h limit ---
$e = New-Env
$m = Mock 200 (Json (Rel 'v2026.10.16.1'))
$null = Invoke-FastLlmUpdateCheck -InstallRoot $e.Install -AppRoot $e.App -Request $m -NowUtc $t0
$r = Invoke-FastLlmUpdateCheck -InstallRoot $e.Install -AppRoot $e.App -Request $m -NowUtc $t0.AddHours(23)
Check ($r.status -eq 'skipped-recent' -and $script:calls.Count -eq 1) 'a second call within 24 h is skipped with no request'
Check ($null -ne $r.latest -and $r.latest.version -eq '2026.10.16.1' -and $r.latest.assets['a.zip'].size -eq 100) 'a skipped call still returns the stored latest'
$r = Invoke-FastLlmUpdateCheck -InstallRoot $e.Install -AppRoot $e.App -Request $m -NowUtc $t0.AddHours(25)
Check ($r.status -eq 'available' -and $script:calls.Count -eq 2) 'after 24 h the check runs again'
$r = Invoke-FastLlmUpdateCheck -InstallRoot $e.Install -AppRoot $e.App -Request $m -NowUtc $t0.AddHours(25).AddMinutes(1) -Force
Check ($r.status -eq 'available' -and $script:calls.Count -eq 3) '-Force bypasses the 24 h limit'

# --- ETag and 304 ---
$e = New-Env
$null = Invoke-FastLlmUpdateCheck -InstallRoot $e.Install -AppRoot $e.App -Request (Mock 200 (Json (Rel 'v2026.10.16.1')) 'W/"abc"') -NowUtc $t0
$m = Mock 304 '' ''
$r = Invoke-FastLlmUpdateCheck -InstallRoot $e.Install -AppRoot $e.App -Request $m -NowUtc $t0.AddHours(30)
Check ($script:calls.Count -eq 1 -and $script:calls[0].Etag -eq 'W/"abc"') 'the stored ETag is sent'
Check ($r.status -eq 'available' -and $r.latest.version -eq '2026.10.16.1') 'a 304 uses the stored latest'
$saved = Get-Content -LiteralPath (StatePath $e) -Raw | ConvertFrom-Json
Check ($saved.etag -eq 'W/"abc"' -and ([datetime]$saved.lastCheckUtc).ToUniversalTime().Hour -eq 18) 'a 304 keeps the ETag and stamps the time'
$r = Invoke-FastLlmUpdateCheck -InstallRoot $e.Install -AppRoot $e.App -Request $m -NowUtc $t0.AddHours(31)
Check ($r.status -eq 'skipped-recent' -and $script:calls.Count -eq 1) 'the 304 stamp starts a new 24 h window'
$e2 = New-Env
$r = Invoke-FastLlmUpdateCheck -InstallRoot $e2.Install -AppRoot $e2.App -Request (Mock 304 '' '') -NowUtc $t0
Check ($r.status -eq 'failed' -and -not (Test-Path -LiteralPath (StatePath $e2))) 'a 304 with no stored state is a failure'

# --- failure is silent and not stamped ---
$e = New-Env
$throws = { param($Url, $Etag) $script:calls.Add([pscustomobject]@{ Url = $Url; Etag = $Etag }); throw 'network down' }
$script:calls.Clear()
$r = Invoke-FastLlmUpdateCheck -InstallRoot $e.Install -AppRoot $e.App -Request $throws -NowUtc $t0
Check ($r.status -eq 'failed' -and $null -eq $r.latest -and -not (Test-Path -LiteralPath (StatePath $e))) 'a throwing request is failed, silently, with no state'
$r = Invoke-FastLlmUpdateCheck -InstallRoot $e.Install -AppRoot $e.App -Request (Mock 403 '{"message":"rate limit"}') -NowUtc $t0
Check ($r.status -eq 'failed' -and -not (Test-Path -LiteralPath (StatePath $e))) 'a 403 is failed with no state'
$r = Invoke-FastLlmUpdateCheck -InstallRoot $e.Install -AppRoot $e.App -Request (Mock 200 '<html>not json') -NowUtc $t0
Check ($r.status -eq 'failed' -and -not (Test-Path -LiteralPath (StatePath $e))) 'a non-JSON body is failed with no state'
$r = Invoke-FastLlmUpdateCheck -InstallRoot $e.Install -AppRoot $e.App -Request (Mock 200 '{"message":"Not Found"}') -NowUtc $t0
Check ($r.status -eq 'failed' -and -not (Test-Path -LiteralPath (StatePath $e))) 'a JSON body that is not a release is failed with no state'
$m = Mock 200 (Json (Rel 'v2026.10.16.1'))
$r = Invoke-FastLlmUpdateCheck -InstallRoot $e.Install -AppRoot $e.App -Request $m -NowUtc $t0.AddMinutes(1)
Check ($r.status -eq 'available' -and $script:calls.Count -eq 1) 'after failures the next call requests again'
$before = Get-Content -LiteralPath (StatePath $e) -Raw
$r = Invoke-FastLlmUpdateCheck -InstallRoot $e.Install -AppRoot $e.App -Request $throws -NowUtc $t0.AddHours(48)
$after = Get-Content -LiteralPath (StatePath $e) -Raw
Check ($r.status -eq 'failed' -and $before -ceq $after) 'a failure leaves an existing state file unchanged'

# --- disabled and not-a-release ---
$e = New-Env
Set-FastLlmUpdateSettings -InstallRoot $e.Install -UpdateCheck 'off'
$m = Mock 200 (Json (Rel 'v2026.10.16.1'))
$r = Invoke-FastLlmUpdateCheck -InstallRoot $e.Install -AppRoot $e.App -Request $m -NowUtc $t0 -Force
Check ($r.status -eq 'disabled' -and $script:calls.Count -eq 0) 'updateCheck off is disabled with no request, even with -Force'
$e = New-Env -WithRelease $false
$m = Mock 200 (Json (Rel 'v2026.10.16.1'))
$r = Invoke-FastLlmUpdateCheck -InstallRoot $e.Install -AppRoot $e.App -Request $m -NowUtc $t0
Check ($r.status -eq 'not-a-release' -and $script:calls.Count -eq 0 -and $null -eq $r.installed) 'no RELEASE.json is not-a-release with no request'

# --- asset filtering ---
$e = New-Env
$assets = @(
    @{ name = 'ok.zip'; browser_download_url = ($good + 'v2026.10.16.1/ok.zip'); size = 7 },
    @{ name = 'evil.zip'; browser_download_url = 'https://evil.example/releases/download/evil.zip'; size = 8 },
    @{ name = 'near.zip'; browser_download_url = 'https://github.com/bitworks-io/amd-inference-evil/releases/download/near.zip'; size = 9 },
    @{ name = 'http.zip'; browser_download_url = 'http://github.com/bitworks-io/amd-inference/releases/download/http.zip'; size = 10 })
$r = Invoke-FastLlmUpdateCheck -InstallRoot $e.Install -AppRoot $e.App -Request (Mock 200 (Json (Rel 'v2026.10.16.1' $false $false $assets))) -NowUtc $t0
$names = @($r.latest.assets.Keys)
Check ($names.Count -eq 1 -and $names[0] -eq 'ok.zip' -and $r.latest.assets['ok.zip'].size -eq 7) 'assets whose URL is outside the repo download path are dropped'

# --- settings ---
$e = New-Env -Channel 'canary'
$s = Get-FastLlmUpdateSettings -InstallRoot $e.Install -AppRoot $e.App
Check ($s.updateCheck -eq 'on' -and $s.updateChannel -eq 'canary') 'defaults: on, and the installed channel'
$s = Get-FastLlmUpdateSettings -InstallRoot $e.Install
Check ($s.updateCheck -eq 'on' -and $s.updateChannel -eq 'stable') 'defaults: stable without a RELEASE.json'
Set-Content -LiteralPath (Join-Path $e.Install 'settings.json') -Value '{ not json'
$s = Get-FastLlmUpdateSettings -InstallRoot $e.Install -AppRoot $e.App
Check ($s.updateCheck -eq 'on' -and $s.updateChannel -eq 'canary') 'an invalid settings file gives the defaults'
Set-Content -LiteralPath (Join-Path $e.Install 'settings.json') -Value '{"updateCheck":"maybe","updateChannel":"nightly"}'
$s = Get-FastLlmUpdateSettings -InstallRoot $e.Install -AppRoot $e.App
Check ($s.updateCheck -eq 'on' -and $s.updateChannel -eq 'canary') 'unknown values fall back to the defaults'
Set-Content -LiteralPath (Join-Path $e.Install 'settings.json') -Value '{"vulkanBarMitigation":"on","other":{"x":1}}'
Set-FastLlmUpdateSettings -InstallRoot $e.Install -UpdateCheck 'off'
Set-FastLlmUpdateSettings -InstallRoot $e.Install -UpdateChannel 'stable'
$raw = Get-Content -LiteralPath (Join-Path $e.Install 'settings.json') -Raw | ConvertFrom-Json
Check ($raw.vulkanBarMitigation -eq 'on' -and $raw.other.x -eq 1 -and $raw.updateCheck -eq 'off' -and $raw.updateChannel -eq 'stable') 'Set-FastLlmUpdateSettings keeps every other key'
Check (@(Get-ChildItem -LiteralPath $e.Install -Filter 'settings.json.tmp-*').Count -eq 0) 'no temp file is left behind'
$s = Get-FastLlmUpdateSettings -InstallRoot $e.Install -AppRoot $e.App
Check ($s.updateCheck -eq 'off' -and $s.updateChannel -eq 'stable') 'the stored values are read back'

Write-Host 'update-tests: PASS'
