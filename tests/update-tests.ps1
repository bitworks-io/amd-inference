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
Check ($r.status -eq 'available' -and $script:calls.Count -eq 1) 'a second call within 24 h makes no request and still offers the cached newer release'
Check ($null -ne $r.latest -and $r.latest.version -eq '2026.10.16.1' -and $r.latest.assets['a.zip'].size -eq 100) 'a skipped call still returns the stored latest'
$r = Invoke-FastLlmUpdateCheck -InstallRoot $e.Install -AppRoot $e.App -Request $m -NowUtc $t0.AddHours(25)
Check ($r.status -eq 'available' -and $script:calls.Count -eq 2) 'after 24 h the check runs again'
$r = Invoke-FastLlmUpdateCheck -InstallRoot $e.Install -AppRoot $e.App -Request $m -NowUtc $t0.AddHours(25).AddMinutes(1) -Force
Check ($r.status -eq 'available' -and $script:calls.Count -eq 3) '-Force bypasses the 24 h limit'

# a cached latest that is not newer than the installed version stays skipped-recent
$e = New-Env
$mSame = Mock 200 (Json (Rel 'v2026.10.15.1'))
$null = Invoke-FastLlmUpdateCheck -InstallRoot $e.Install -AppRoot $e.App -Request $mSame -NowUtc $t0
$r = Invoke-FastLlmUpdateCheck -InstallRoot $e.Install -AppRoot $e.App -Request $mSame -NowUtc $t0.AddHours(1)
Check ($r.status -eq 'skipped-recent' -and $script:calls.Count -eq 1) 'inside 24 h an equal cached latest is skipped-recent with no request'

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
Check ($r.status -eq 'available' -and $script:calls.Count -eq 1) 'the 304 stamp starts a new 24 h window'
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

# --- htmlUrl must be this repository's release page ---
$e = New-Env
$rel = Rel 'v2026.10.16.1'
$rel.html_url = 'https://evil.example/bitworks-io/amd-inference/releases/tag/v2026.10.16.1'
$r = Invoke-FastLlmUpdateCheck -InstallRoot $e.Install -AppRoot $e.App -Request (Mock 200 (Json $rel)) -NowUtc $t0
Check ($r.status -eq 'up-to-date' -and $null -eq $r.latest) 'a release whose page URL is off-site is no eligible release'
$e = New-Env
$rel = Rel 'v2026.10.16.1'
$rel.html_url = 'https://github.com/bitworks-io/amd-inference-evil/releases/tag/v2026.10.16.1'
$r = Invoke-FastLlmUpdateCheck -InstallRoot $e.Install -AppRoot $e.App -Request (Mock 200 (Json $rel)) -NowUtc $t0
Check ($r.status -eq 'up-to-date' -and $null -eq $r.latest) 'a lookalike repository page URL is no eligible release'

# --- verified update flow ---
$ver = '2026.10.16.1'
$setupName = "FastLLM-Setup-$ver.exe"
$setupBytes = [Text.Encoding]::ASCII.GetBytes('pretend installer bytes')
$sha = New-Object Security.Cryptography.SHA256Managed
$setupSha = (($sha.ComputeHash($setupBytes) | ForEach-Object { $_.ToString('x2') }) -join '')
$sha.Dispose()
function New-Latest([string]$Version = $ver) {
    @{ version = $Version; tag = "v$Version"; channel = 'stable'; htmlUrl = "https://github.com/bitworks-io/amd-inference/releases/tag/v$Version"
       assets = @{
           'SHA256SUMS' = @{ url = ($good + "v$Version/SHA256SUMS"); size = 200 }
           "FastLLM-Setup-$Version.exe" = @{ url = ($good + "v$Version/FastLLM-Setup-$Version.exe"); size = $setupBytes.Length } } }
}
# Builds the seam mocks; each records its name in $order.
function New-Seams($Opts) {
    $order = New-Object 'System.Collections.Generic.List[string]'
    $o = @{ Sums = ($setupSha + '  ' + $setupName + "`n"); StopOk = $true; DownloadFail = $false; PartialOnFail = $true; SigOk = $true; SigReason = $null
            ProductVersion = $ver; Exit = 0; IntegrityStatus = 'ok'; IntegrityReason = $null }
    if ($Opts) { foreach ($k in $Opts.Keys) { $o[$k] = $Opts[$k] } }
    # GetNewClosure copies only this function's locals: a script-level variable read inside a closure is $null when the
    # suite is invoked from another script (CI) rather than with -File (the bench gate), so copy it here.
    $bytes = $setupBytes
    $seams = @{ Order = $order }
    $seams.StopServer = { param($Root) $order.Add('stop'); [pscustomobject]@{ ok = $o.StopOk; reason = 'mock-stop' } }.GetNewClosure()
    $seams.Download = {
        param($Url, $Destination, $Sha256, $SizeBytes)
        if ($Sha256) { $order.Add('download') } else { $order.Add('sums') }
        if (-not $Sha256) { [IO.File]::WriteAllText($Destination, $o.Sums); return }
        if ($o.DownloadFail) {
            [IO.File]::WriteAllText("$Destination.$($Sha256.Substring(0, 16)).partial", 'partial')
            [IO.File]::WriteAllText("$Destination.$($Sha256.Substring(0, 16)).lock", '')
            throw 'Downloaded artifact failed exact size/SHA-256 verification'
        }
        [IO.File]::WriteAllBytes($Destination, $bytes)
    }.GetNewClosure()
    $seams.Verify = { param($Path) $order.Add('verify'); [pscustomobject]@{ ok = $o.SigOk; reason = $o.SigReason; detail = $null } }.GetNewClosure()
    $seams.GetProductVersion = { param($Path) $order.Add('version'); $o.ProductVersion }.GetNewClosure()
    $seams.RunInstaller = { param($Setup, $QuietMode) $order.Add('install'); $o.Exit }.GetNewClosure()
    $seams.Integrity = { param($Root) $order.Add('integrity'); [pscustomobject]@{ status = $o.IntegrityStatus; reason = $o.IntegrityReason } }.GetNewClosure()
    $seams
}
function Run-Update($Env, $Seams, $Latest = $null) {
    if ($null -eq $Latest) { $Latest = New-Latest }
    $result = Invoke-FastLlmVerifiedUpdate -InstallRoot $Env.Install -AppRoot $Env.App -Latest $Latest -StopServer $Seams.StopServer -Download $Seams.Download `
        -Verify $Seams.Verify -GetProductVersion $Seams.GetProductVersion -RunInstaller $Seams.RunInstaller -Integrity $Seams.Integrity
    # Diagnostics for CI and the bench gate: the exact result, the seam order and any leftover update files.
    $left = @(UpdateDirs $Env | ForEach-Object { $_.Name + '(' + @(Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue).Count + ')' })
    Write-Host ('  update result: ' + (@($result) | ConvertTo-Json -Compress -Depth 4) + ' order=' + (@($Seams.Order) -join ',') + ' leftover=' + ($left -join ','))
    $result
}
function UpdateDirs($Env) {
    $u = Join-Path $Env.Install 'updates'
    if (-not (Test-Path -LiteralPath $u)) { return @() }
    @(Get-ChildItem -LiteralPath $u -Force)
}

$e = New-Env
$s = New-Seams @{ StopOk = $false }
$r = Run-Update $e $s
Check ($r.status -eq 'failed' -and $r.step -eq 'stop' -and (($s.Order -join ',') -eq 'stop') -and @(UpdateDirs $e).Count -eq 0) 'stop fails: failed/stop, and no download'

$e = New-Env
$s = New-Seams @{ Sums = ('a' * 64 + '  other.zip' + "`n") }
$r = Run-Update $e $s
Check ($r.status -eq 'refused' -and $r.step -eq 'sums' -and $r.reason -eq 'no-installer-entry' -and (($s.Order -join ',') -eq 'stop,sums') -and @(UpdateDirs $e).Count -eq 0) 'SUMS without the installer line: refused/sums, and the work directory is removed'

foreach ($bad in @(($setupSha.ToUpper() + '  ' + $setupName), ($setupSha + ' ' + $setupName), ($setupSha + '  ..\' + $setupName), ('not a line'))) {
    $e = New-Env
    $s = New-Seams @{ Sums = ($bad + "`n") }
    $r = Run-Update $e $s
    Check ($r.status -eq 'refused' -and $r.step -eq 'sums' -and -not ($s.Order -contains 'download')) "a malformed SUMS line is refused: $bad"
}
$e = New-Env
$s = New-Seams @{ Sums = ($setupSha + '  ' + $setupName + "`n" + $setupSha + '  ' + $setupName + "`n") }
$r = Run-Update $e $s
Check ($r.status -eq 'refused' -and $r.step -eq 'sums') 'a duplicate SUMS entry is refused'

$e = New-Env
$s = New-Seams @{ DownloadFail = $true }
$r = Run-Update $e $s
Check ($r.status -eq 'failed' -and $r.step -eq 'download' -and -not ($s.Order -contains 'verify') -and @(UpdateDirs $e).Count -eq 0) 'download hash mismatch: failed/download, partial and lock removed, directory removed'

$e = New-Env
$s = New-Seams @{ SigOk = $false; SigReason = 'wrong-publisher' }
$r = Run-Update $e $s
Check ($r.status -eq 'refused' -and $r.step -eq 'signature' -and $r.reason -eq 'wrong-publisher' -and -not ($s.Order -contains 'install') -and @(UpdateDirs $e).Count -eq 0) 'wrong-publisher: refused/signature, installer never run, files removed'

$e = New-Env
$s = New-Seams @{ ProductVersion = '2026.10.15.1'; Sums = ($setupSha + '  FastLLM-Setup-2026.10.15.2.exe' + "`n") }
$r = Run-Update $e $s (New-Latest '2026.10.15.2')
Check ($r.status -eq 'refused' -and $r.step -eq 'version' -and -not ($s.Order -contains 'install')) 'ProductVersion 2026.10.15.1 against latest 2026.10.15.2: refused/version'

$e = New-Env -Version $ver
$s = New-Seams
$r = Run-Update $e $s
Check ($r.status -eq 'refused' -and $r.step -eq 'version' -and -not ($s.Order -contains 'install')) 'ProductVersion equal to installed: refused/version (no reinstall)'
$e = New-Env -Version '2026.10.17.1'
$s = New-Seams
$r = Run-Update $e $s
Check ($r.status -eq 'refused' -and $r.step -eq 'version' -and -not ($s.Order -contains 'install')) 'an older release than installed: refused/version (no downgrade)'

$e = New-Env
$s = New-Seams @{ Exit = 1 }
$r = Run-Update $e $s
Check ($r.status -eq 'failed' -and $r.step -eq 'install' -and -not ($s.Order -contains 'integrity') -and @(UpdateDirs $e).Count -eq 0) 'the installer exits 1: failed/install'

$e = New-Env
$s = New-Seams @{ IntegrityStatus = 'failed'; IntegrityReason = 'tree' }
$r = Run-Update $e $s
Check ($r.status -eq 'failed' -and $r.step -eq 'integrity' -and $r.reason -eq 'tree') 'integrity failed: failed/integrity with the reason'

$e = New-Env
$s = New-Seams
$r = Run-Update $e $s
Check ($r.status -eq 'installed') 'all good: installed'
Check (($s.Order -join ',') -eq 'stop,sums,download,verify,version,install,integrity') 'the call order is stop, sums, download, verify, version, install, integrity'
$dirs = @(UpdateDirs $e)
Check ($dirs.Count -eq 1 -and $dirs[0].Name -match '^2026\.10\.16\.1-[0-9a-f]{8}$' -and (Test-Path -LiteralPath (Join-Path $dirs[0].FullName $setupName))) 'success keeps the installer in a fresh <version>-<8 hex> directory'
Check (@(Get-ChildItem -LiteralPath $e.App -Force).Count -eq 1) 'the app folder is untouched'

# --- the cached notice (start and status): cache only, no network ---
$nRoot = Join-Path ([IO.Path]::GetTempPath()) ('fast-llm-notice-' + [guid]::NewGuid().ToString('N'))
try {
    $nInstall = Join-Path $nRoot 'install'; $nApp = Join-Path $nRoot 'app'
    New-Item -ItemType Directory -Path (Join-Path $nInstall 'state') -Force | Out-Null
    New-Item -ItemType Directory -Path $nApp -Force | Out-Null
    $nPage = 'https://github.com/bitworks-io/amd-inference/releases/tag/v2026.10.16.1'
    function Write-NoticeCache([string]$Version) {
        $doc = [ordered]@{ lastCheckUtc = '2026-10-20T12:00:00Z'; etag = 'x'; channel = 'stable'
            latest = [ordered]@{ version = $Version; tag = "v$Version"; channel = 'stable'; htmlUrl = "https://github.com/bitworks-io/amd-inference/releases/tag/v$Version"; assets = [ordered]@{} } }
        [IO.File]::WriteAllText((Join-Path (Join-Path $nInstall 'state') 'update-check.json'), ([pscustomobject]$doc | ConvertTo-Json -Depth 8))
    }
    Check ($null -eq (Get-FastLlmCachedUpdateNotice -InstallRoot $nInstall -AppRoot $nApp)) 'notice: no RELEASE.json and no cache gives null'
    [IO.File]::WriteAllText((Join-Path $nApp 'RELEASE.json'), '{"version":"2026.10.15.1","channel":"stable"}')
    Check ($null -eq (Get-FastLlmCachedUpdateNotice -InstallRoot $nInstall -AppRoot $nApp)) 'notice: no cache gives null'
    Write-NoticeCache '2026.10.16.1'
    Check ((Get-FastLlmCachedUpdateNotice -InstallRoot $nInstall -AppRoot $nApp) -ceq "Update available: FastLLM 2026.10.16.1 ($nPage).") 'notice: a newer cached version gives the one-line notice'
    Write-NoticeCache '2026.10.15.1'
    Check ($null -eq (Get-FastLlmCachedUpdateNotice -InstallRoot $nInstall -AppRoot $nApp)) 'notice: the same cached version gives null'
    Write-NoticeCache '2026.10.14.3'
    Check ($null -eq (Get-FastLlmCachedUpdateNotice -InstallRoot $nInstall -AppRoot $nApp)) 'notice: an older cached version gives null'
    [IO.File]::WriteAllText((Join-Path (Join-Path $nInstall 'state') 'update-check.json'), 'not json')
    Check ($null -eq (Get-FastLlmCachedUpdateNotice -InstallRoot $nInstall -AppRoot $nApp)) 'notice: a corrupt cache gives null and does not throw'
    Write-NoticeCache '2026.10.16.1'
    Remove-Item -LiteralPath (Join-Path $nApp 'RELEASE.json') -Force
    Check ($null -eq (Get-FastLlmCachedUpdateNotice -InstallRoot $nInstall -AppRoot $nApp)) 'notice: a source checkout (no RELEASE.json) gives null'
    $noticeSource = (Get-Command Get-FastLlmCachedUpdateNotice).ScriptBlock.ToString()
    Check (-not $noticeSource.Contains('Invoke-FastLlmUpdateCheck') -and -not $noticeSource.Contains('Invoke-FastLlmUpdateHttp')) 'notice: the helper makes no request'
}
finally { if (Test-Path -LiteralPath $nRoot) { Remove-Item -LiteralPath $nRoot -Recurse -Force } }

# The default request seam enables TLS 1.2 before it calls Invoke-WebRequest (Windows PowerShell 5.1 may not by default).
$httpSource = (Get-Command Invoke-FastLlmUpdateHttp).ScriptBlock.ToString()
$tlsAt = $httpSource.IndexOf('[Net.SecurityProtocolType]::Tls12', [StringComparison]::Ordinal)
$webAt = $httpSource.IndexOf('Invoke-WebRequest', [StringComparison]::Ordinal)
Check ($tlsAt -ge 0 -and $webAt -gt $tlsAt -and $httpSource.Contains('[Net.ServicePointManager]::SecurityProtocol = ') -and $httpSource.Contains("IsDefined([Net.SecurityProtocolType], 'Tls13')")) 'the default request seam enables TLS 1.2 (and 1.3 when defined) before Invoke-WebRequest'

# --- reinstall-previous decision (pure: no network, no files) ---
function New-Policy($DataFormat = 1, $Floor = $null) {
    [pscustomobject]@{ schema = 'bitworks.fastllm-release-policy/v1'; dataFormat = $DataFormat; rollbackFloor = $Floor; rollbackFloorReason = $null }
}
function New-PrevRecord([string]$Version = '2026.10.15.1', $Policy = $null, [bool]$WithPolicy = $true, $ReplacedBy = '2026.10.16.1') {
    if ($WithPolicy -and $null -eq $Policy) { $Policy = New-Policy }
    [pscustomobject]@{ version = $Version; policy = $Policy; replacedBy = $ReplacedBy }
}
function New-StoreRelease([string]$Version = '2026.10.15.1', [bool]$Draft = $false) { [pscustomobject]@{ version = $Version; draft = $Draft } }
function Decide($InstalledPolicy, [string]$InstalledVersion, $PreviousRecord, $FreshLatest, $StoreRelease) {
    Get-FastLlmReinstallDecision -InstalledPolicy $InstalledPolicy -InstalledVersion $InstalledVersion -PreviousRecord $PreviousRecord -FreshLatest $FreshLatest -StoreRelease $StoreRelease
}
$inst = '2026.10.16.1'

$d = Decide (New-Policy) $inst (New-PrevRecord) $null (New-StoreRelease)
Check ($d.decision -ceq 'eligible' -and $d.reason -ceq 'eligible' -and $d.target -ceq '2026.10.15.1') 'reinstall: the immediate previous release in the store, same data format, no floor: eligible'

$d = Decide (New-Policy) $inst $null $null (New-StoreRelease)
Check ($d.decision -ceq 'refused' -and $d.reason -ceq 'no-previous-record' -and $null -eq $d.target) 'reinstall: no previous record is refused'

foreach ($case in @(@('the same version as installed', '2026.10.16.1'), @('a newer version than installed', '2026.10.17.1'), @('a malformed version', 'previous'))) {
    $d = Decide (New-Policy) $inst (New-PrevRecord $case[1]) $null (New-StoreRelease $case[1])
    Check ($d.decision -ceq 'refused' -and $d.reason -ceq 'not-immediate-previous') ("reinstall: a record holding " + $case[0] + ' is not the immediate previous')
}
$d = Decide (New-Policy) 'not-a-version' (New-PrevRecord) $null (New-StoreRelease)
Check ($d.decision -ceq 'refused' -and $d.reason -ceq 'not-immediate-previous') 'reinstall: an unreadable installed version is refused'

$d = Decide (New-Policy 1 '2026.10.16.1') $inst (New-PrevRecord '2026.10.15.1') $null (New-StoreRelease)
Check ($d.decision -ceq 'refused' -and $d.reason -ceq 'below-security-floor' -and $d.target -ceq '2026.10.15.1') 'reinstall: a target below the installed floor is refused'
$d = Decide (New-Policy 1 '2026.10.15.1') $inst (New-PrevRecord '2026.10.15.1') $null (New-StoreRelease)
Check ($d.decision -ceq 'eligible') 'reinstall: a target equal to the floor is allowed'
$d = Decide (New-Policy 1 'garbage') $inst (New-PrevRecord) $null (New-StoreRelease)
Check ($d.decision -ceq 'refused' -and $d.reason -ceq 'below-security-floor') 'reinstall: an unreadable floor fails closed'
# The floor comes from the INSTALLED policy; the previous release's own floor is not consulted.
$d = Decide (New-Policy 1) $inst (New-PrevRecord '2026.10.15.1' (New-Policy 1 '2026.10.16.1')) $null (New-StoreRelease)
Check ($d.decision -ceq 'eligible') 'reinstall: only the installed policy supplies the floor'

$d = Decide (New-Policy 2) $inst (New-PrevRecord '2026.10.15.1' (New-Policy 1)) $null (New-StoreRelease)
Check ($d.decision -ceq 'refused' -and $d.reason -ceq 'data-format-differs') 'reinstall: a different data format is refused'
$d = Decide (New-Policy 1) $inst (New-PrevRecord '2026.10.15.1' $null $false) $null (New-StoreRelease)
Check ($d.decision -ceq 'refused' -and $d.reason -ceq 'data-format-missing') 'reinstall: a previous release with no policy file is refused'
$d = Decide (New-Policy 1) $inst (New-PrevRecord '2026.10.15.1' ([pscustomobject]@{ schema = 'x' })) $null (New-StoreRelease)
Check ($d.decision -ceq 'refused' -and $d.reason -ceq 'data-format-missing') 'reinstall: a previous policy with no data format is refused'
$d = Decide (New-Policy 1) $inst (New-PrevRecord '2026.10.15.1' (New-Policy '1')) $null (New-StoreRelease)
Check ($d.decision -ceq 'refused' -and $d.reason -ceq 'data-format-missing') 'reinstall: a data format that is not a whole number is refused'
$d = Decide $null $inst (New-PrevRecord) $null (New-StoreRelease)
Check ($d.decision -ceq 'refused' -and $d.reason -ceq 'data-format-missing') 'reinstall: an installed release with no policy file is refused'
$d = Decide (New-Policy $true) $inst (New-PrevRecord '2026.10.15.1' (New-Policy $true)) $null (New-StoreRelease)
Check ($d.decision -ceq 'refused' -and $d.reason -ceq 'data-format-missing') 'reinstall: a boolean is not a data format'

$d = Decide (New-Policy) $inst (New-PrevRecord) '2026.10.17.1' (New-StoreRelease)
Check ($d.decision -ceq 'refused' -and $d.reason -ceq 'newer-release-available') 'reinstall: a newer fresh release is refused in favour of updating'
$d = Decide (New-Policy) $inst (New-PrevRecord) $inst (New-StoreRelease)
Check ($d.decision -ceq 'eligible') 'reinstall: a fresh check equal to the installed version does not block'
$d = Decide (New-Policy) $inst (New-PrevRecord) '2026.10.01.1' (New-StoreRelease)
Check ($d.decision -ceq 'eligible') 'reinstall: an older fresh answer does not block'
foreach ($bad in @('not-a-version', "2026.10.17.1`n", '2026.10.17', '2026.10.17.1 ')) {
    $d = Decide (New-Policy) $inst (New-PrevRecord) $bad (New-StoreRelease)
    Check ($d.decision -ceq 'refused' -and $d.reason -ceq 'fresh-check-unreadable') 'reinstall: a fresh answer that is not a strict version is refused, not ignored'
}
$d = Decide (New-Policy) $inst (New-PrevRecord) '' (New-StoreRelease)
Check ($d.decision -ceq 'eligible') 'reinstall: an empty fresh answer means offline and allows the local rules'

$d = Decide (New-Policy) $inst (New-PrevRecord) $null $null
Check ($d.decision -ceq 'refused' -and $d.reason -ceq 'not-in-release-store') 'reinstall: a release missing from the store is refused'
$d = Decide (New-Policy) $inst (New-PrevRecord) $null (New-StoreRelease '2026.10.14.1')
Check ($d.decision -ceq 'refused' -and $d.reason -ceq 'not-in-release-store') 'reinstall: a store entry for a different version is refused'
$d = Decide (New-Policy) $inst (New-PrevRecord) $null ([pscustomobject]@{ version = '2026.10.15.1' })
Check ($d.decision -ceq 'refused' -and $d.reason -ceq 'not-in-release-store') 'reinstall: a store entry with no draft flag is refused'
$d = Decide (New-Policy) $inst (New-PrevRecord) $null (New-StoreRelease '2026.10.15.1' $true)
Check ($d.decision -ceq 'refused' -and $d.reason -ceq 'draft-release') 'reinstall: a draft release is refused'

# Order: a floor refusal wins over a missing store entry; a data refusal wins over a newer release.
$d = Decide (New-Policy 1 '2026.10.16.1') $inst (New-PrevRecord) '2026.10.17.1' $null
Check ($d.reason -ceq 'below-security-floor') 'reinstall: the security floor is checked before the store'
$d = Decide (New-Policy 2) $inst (New-PrevRecord) '2026.10.17.1' (New-StoreRelease)
Check ($d.reason -ceq 'data-format-differs') 'reinstall: the data format is checked before newer-release'

# --- strict reads: the record is bound to the install, policy fields are read as scalars ---
$d = Decide (New-Policy) $inst (New-PrevRecord '2026.10.15.1' $null $true '2026.10.14.1') $null (New-StoreRelease)
Check ($d.decision -ceq 'refused' -and $d.reason -ceq 'not-immediate-previous') 'reinstall: a record written for another install (replacedBy differs) is refused'
$d = Decide (New-Policy) $inst ([pscustomobject]@{ version = '2026.10.15.1'; policy = (New-Policy) }) $null (New-StoreRelease)
Check ($d.decision -ceq 'refused' -and $d.reason -ceq 'not-immediate-previous') 'reinstall: a record with no replacedBy is refused'
$d = Decide (New-Policy) $inst (New-PrevRecord '2026.10.15.1' $null $true @('2026.10.16.1')) $null (New-StoreRelease)
Check ($d.decision -ceq 'refused' -and $d.reason -ceq 'not-immediate-previous') 'reinstall: a replacedBy that is not a string is refused'

$noFloor = [pscustomobject]@{ schema = 'bitworks.fastllm-release-policy/v1'; dataFormat = 1; rollbackFloorReason = $null }
$d = Decide $noFloor $inst (New-PrevRecord) $null (New-StoreRelease)
Check ($d.decision -ceq 'refused' -and $d.reason -ceq 'below-security-floor') 'reinstall: an installed policy with no rollbackFloor property is refused'
foreach ($badFloor in @(@(), @('2026.10.01.1'), 5, $true, "2026.10.01.1`n", '2026.10.01.0', '')) {
    $d = Decide (New-Policy 1 $badFloor) $inst (New-PrevRecord) $null (New-StoreRelease)
    Check ($d.decision -ceq 'refused' -and $d.reason -ceq 'below-security-floor') 'reinstall: a floor that is not null or a strict version string is refused'
}
$d = Decide ([pscustomobject]@{ schema = 'other'; dataFormat = 1; rollbackFloor = $null }) $inst (New-PrevRecord) $null (New-StoreRelease)
Check ($d.decision -ceq 'refused' -and $d.reason -ceq 'data-format-missing') 'reinstall: an installed policy with a foreign schema is refused'
$d = Decide ([pscustomobject]@{ dataFormat = 1; rollbackFloor = $null }) $inst (New-PrevRecord) $null (New-StoreRelease)
Check ($d.decision -ceq 'refused' -and $d.reason -ceq 'data-format-missing') 'reinstall: an installed policy with no schema is refused'
$d = Decide (New-Policy @(1)) $inst (New-PrevRecord) $null (New-StoreRelease)
Check ($d.decision -ceq 'refused' -and $d.reason -ceq 'data-format-missing') 'reinstall: an installed dataFormat array is refused'
$d = Decide (New-Policy) $inst (New-PrevRecord '2026.10.15.1' (New-Policy @(1))) $null (New-StoreRelease)
Check ($d.decision -ceq 'refused' -and $d.reason -ceq 'data-format-missing') 'reinstall: a previous dataFormat array is refused'
$d = Decide (New-Policy) $inst (New-PrevRecord) $null ([pscustomobject]@{ version = '2026.10.15.1'; draft = @($false) })
Check ($d.decision -ceq 'refused' -and $d.reason -ceq 'not-in-release-store') 'reinstall: a draft flag that is an array is refused'

foreach ($lax in @("2026.10.15.1`n", '2026.10.15.1 ', '٢٠٢٦.10.15.1')) {
    $d = Decide (New-Policy) $inst (New-PrevRecord $lax) $null (New-StoreRelease $lax)
    Check ($d.decision -ceq 'refused' -and $d.reason -ceq 'not-immediate-previous') 'reinstall: a target that is not a strict version is refused'
}
$d = Decide (New-Policy) "2026.10.16.1`n" (New-PrevRecord '2026.10.15.1' $null $true "2026.10.16.1`n") $null (New-StoreRelease)
Check ($d.decision -ceq 'refused' -and $d.reason -ceq 'not-immediate-previous') 'reinstall: an installed version that is not a strict version is refused'
$d = Decide (New-Policy) $inst (New-PrevRecord) $null (New-StoreRelease "2026.10.15.1`n")
Check ($d.decision -ceq 'refused' -and $d.reason -ceq 'not-in-release-store') 'reinstall: a store version that is not strict is refused'

# Real JSON, as the future reader will produce it.
$jsonOk = '{"schema":"bitworks.fastllm-release-policy/v1","dataFormat":1,"rollbackFloor":null,"rollbackFloorReason":null}' | ConvertFrom-Json
$d = Decide $jsonOk $inst (New-PrevRecord '2026.10.15.1' $jsonOk) $null (New-StoreRelease)
Check ($d.decision -ceq 'eligible') 'reinstall: policies parsed from JSON are eligible'
$jsonArr = '{"schema":"bitworks.fastllm-release-policy/v1","dataFormat":1,"rollbackFloor":[],"rollbackFloorReason":null}' | ConvertFrom-Json
$d = Decide $jsonArr $inst (New-PrevRecord '2026.10.15.1' $jsonOk) $null (New-StoreRelease)
Check ($d.decision -ceq 'refused' -and $d.reason -ceq 'below-security-floor') 'reinstall: an empty-array floor parsed from JSON is refused, not read as no floor'
$jsonMissing = '{"schema":"bitworks.fastllm-release-policy/v1","dataFormat":1}' | ConvertFrom-Json
$d = Decide $jsonMissing $inst (New-PrevRecord '2026.10.15.1' $jsonOk) $null (New-StoreRelease)
Check ($d.decision -ceq 'refused' -and $d.reason -ceq 'below-security-floor') 'reinstall: a missing floor parsed from JSON is refused'

$decisionSource = (Get-Command Get-FastLlmReinstallDecision).ScriptBlock.ToString()
Check (-not ($decisionSource -match 'Invoke-|Get-Content|Test-Path|Set-Content|\[IO\.|Start-Process|Invoke-WebRequest')) 'reinstall: the decision function does no I/O'
Check ($null -ne (Get-Command Invoke-FastLlmVerifiedUpdate) -and -not ((Get-Command Invoke-FastLlmVerifiedUpdate).ScriptBlock.ToString().Contains('Get-FastLlmReinstallDecision'))) 'reinstall: the update path does not call the decision (no install path yet)'

Write-Host 'update-tests: PASS'
