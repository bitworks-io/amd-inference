#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src/FastLlm.Update.ps1')
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; Write-Host "PASS: $Message" }
# Every temp folder this suite creates is recorded here and removed in the final finally, pass or fail.
$script:createdTemp = New-Object 'System.Collections.Generic.List[string]'
function Add-TempPath([string]$Path) { $script:createdTemp.Add($Path); $Path }

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
try {
function New-Env([string]$Version = '2026.10.15.1', [string]$Channel = 'stable', [bool]$WithRelease = $true) {
    $base = Add-TempPath (Join-Path ([IO.Path]::GetTempPath()) ("fastllm-update-" + [guid]::NewGuid().ToString('N')))
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
$nRoot = Add-TempPath (Join-Path ([IO.Path]::GetTempPath()) ('fast-llm-notice-' + [guid]::NewGuid().ToString('N')))
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

# --- reinstall previous: the explicit action (record reader, store lookup, install through the verified path) ---
$old = '2026.10.15.1'
$cur = '2026.10.16.1'
function New-ReinstallEnv([string]$Installed = $cur, $InstalledPolicy = $null, [bool]$WithRecord = $true, [string]$Previous = $old, $PreviousPolicy = $null,
                          [string]$ReplacedBy = $cur, [string]$PreviousChannel = 'stable', [bool]$WithPreviousPolicyFile = $true) {
    $e = New-Env -Version $Installed
    New-Item -ItemType Directory -Path (Join-Path $e.App 'config') -Force | Out-Null
    if ($null -eq $InstalledPolicy) { $InstalledPolicy = New-Policy }
    Set-Content -LiteralPath (Join-Path (Join-Path $e.App 'config') 'release-policy.json') -Value (ConvertTo-Json -InputObject $InstalledPolicy -Compress)
    if ($WithRecord) {
        $folder = Join-Path (Join-Path $e.Install 'state') 'previous-release'
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $folder 'RELEASE.json') -Value (@{ version = $Previous; channel = $PreviousChannel } | ConvertTo-Json)
        Set-Content -LiteralPath (Join-Path $folder 'record.json') -Value ('{"replacedBy":"' + $ReplacedBy + '"}')
        if ($WithPreviousPolicyFile) {
            if ($null -eq $PreviousPolicy) { $PreviousPolicy = New-Policy }
            Set-Content -LiteralPath (Join-Path $folder 'release-policy.json') -Value (ConvertTo-Json -InputObject $PreviousPolicy -Compress)
        }
    }
    $e
}
function RecordFolder($e) { Join-Path (Join-Path $e.Install 'state') 'previous-release' }
function Store-Body([string]$Version = $old, [string]$Channel = 'stable', [bool]$Draft = $false, [bool]$Prerelease = $false) {
    $tag = 'v' + $Version
    if ($Channel -ceq 'canary') { $tag += '-canary' }
    Json @{ tag_name = $tag; draft = $Draft; prerelease = $Prerelease; html_url = "https://github.com/bitworks-io/amd-inference/releases/tag/$tag"
            assets = @(@{ name = 'SHA256SUMS'; browser_download_url = ($good + "$tag/SHA256SUMS"); size = 200 }, @{ name = "FastLLM-Setup-$Version.exe"; browser_download_url = ($good + "$tag/FastLLM-Setup-$Version.exe"); size = $setupBytes.Length }) }
}
# Answers releases/latest (the fresh check) and releases/tags/<tag> (the store); every URL asked is recorded.
function New-ReinstallRequest([string]$LatestTag = 'v2026.10.16.1', $StoreStatus = 200, $StoreBody = $null, $LatestStatus = 200, $LatestBody = $null, [bool]$LatestThrows = $false) {
    $urls = New-Object 'System.Collections.Generic.List[string]'
    if ($null -eq $StoreBody) { $StoreBody = Store-Body }
    if ($null -eq $LatestBody) { $LatestBody = Json (Rel $LatestTag) }
    $latestBody = $LatestBody
    $latestCode = $LatestStatus
    $latestFails = $LatestThrows
    $storeCode = $StoreStatus
    $request = {
        param($Url, $Etag)
        $urls.Add([string]$Url)
        if ($Url.Contains('/releases/tags/')) { return @{ Status = $storeCode; Body = $StoreBody; Etag = 'W/"s"' } }
        if ($latestFails) { throw 'timeout' }
        @{ Status = $latestCode; Body = $latestBody; Etag = 'W/"l"' }
    }.GetNewClosure()
    [pscustomobject]@{ Request = $request; Urls = $urls }
}
function Install-Seams($Seams) {
    @{ StopServer = $Seams.StopServer; Download = $Seams.Download; Verify = $Seams.Verify; GetProductVersion = $Seams.GetProductVersion; RunInstaller = $Seams.RunInstaller; Integrity = $Seams.Integrity }
}
$prompts = New-Object 'System.Collections.Generic.List[string]'
function New-Prompt($Answer) { $log = $prompts; $reply = $Answer; { param($Text) $log.Add($Text); $reply }.GetNewClosure() }
$approveNever = { param($From, $To) throw 'the approval must not be asked' }
$approveYes = { param($From, $To) $true }
function Seams-For-Old([hashtable]$More = @{}) {
    $opts = @{ Sums = ($setupSha + '  FastLLM-Setup-' + $old + '.exe' + "`n"); ProductVersion = $old }
    foreach ($k in $More.Keys) { $opts[$k] = $More[$k] }
    New-Seams $opts
}

# Facts read from the PC.
$e = New-ReinstallEnv
$f = Read-FastLlmReinstallFacts -InstallRoot $e.Install -AppRoot $e.App
Check ($f.installedVersion -ceq $cur -and $f.record.version -ceq $old -and $f.record.replacedBy -ceq $cur -and $f.record.policy.dataFormat -eq 1 -and $f.installedPolicy.dataFormat -eq 1 -and $f.channel -ceq 'stable') 'reinstall facts: the installed version, both policies and the record are read'
$d = Get-FastLlmReinstallDecision -InstalledPolicy $f.installedPolicy -InstalledVersion $f.installedVersion -PreviousRecord $f.record -FreshLatest $null -StoreRelease (New-StoreRelease)
Check ($d.decision -ceq 'eligible') 'reinstall facts: what the reader returns is accepted by the decision'
$e = New-ReinstallEnv -WithRecord $false
Check ($null -eq (Read-FastLlmReinstallFacts -InstallRoot $e.Install -AppRoot $e.App).record) 'reinstall facts: no record folder gives no record'
$e = New-ReinstallEnv
Set-Content -LiteralPath (Join-Path (RecordFolder $e) 'record.json') -Value '{ not json'
Check ($null -eq (Read-FastLlmReinstallFacts -InstallRoot $e.Install -AppRoot $e.App).record) 'reinstall facts: a record.json that is not JSON gives no record'
$e = New-ReinstallEnv
Set-Content -LiteralPath (Join-Path (RecordFolder $e) 'RELEASE.json') -Value '[1,2]'
Check ($null -eq (Read-FastLlmReinstallFacts -InstallRoot $e.Install -AppRoot $e.App).record) 'reinstall facts: a RELEASE.json that is not an object gives no record'
$e = New-ReinstallEnv
Set-Content -LiteralPath (Join-Path (RecordFolder $e) 'record.json') -Value (' ' * 70000)
Check ($null -eq (Read-FastLlmReinstallFacts -InstallRoot $e.Install -AppRoot $e.App).record) 'reinstall facts: an oversized record file gives no record'
$e = New-ReinstallEnv -PreviousChannel 'beta'
Check ($null -eq (Read-FastLlmReinstallFacts -InstallRoot $e.Install -AppRoot $e.App).record) 'reinstall facts: a record whose channel is not stable or canary gives no record'
$e = New-ReinstallEnv -WithPreviousPolicyFile $false
Check ($null -eq (Read-FastLlmReinstallFacts -InstallRoot $e.Install -AppRoot $e.App).record.policy) 'reinstall facts: a previous release without a policy file has no policy'
$e = New-Env -WithRelease $false
Check ($null -eq (Read-FastLlmReinstallFacts -InstallRoot $e.Install -AppRoot $e.App)) 'reinstall facts: no installed release gives nothing'

# The store lookup is by exact tag.
$req = New-ReinstallRequest
$store = Get-FastLlmStoreRelease -Version $old -Channel 'stable' -Request $req.Request
Check ($req.Urls.Count -eq 1 -and $req.Urls[0] -ceq 'https://api.github.com/repos/bitworks-io/amd-inference/releases/tags/v2026.10.15.1') 'store: asks releases/tags/<exact tag>, never latest or a list'
Check ($store.version -ceq $old -and $store.draft -eq $false -and $store.latest.version -ceq $old -and $store.latest.assets.ContainsKey('SHA256SUMS') -and $store.latest.assets.ContainsKey("FastLLM-Setup-$old.exe")) 'store: the release comes back with its assets'
$req = New-ReinstallRequest -StoreBody (Store-Body $old 'canary')
$store = Get-FastLlmStoreRelease -Version $old -Channel 'canary' -Request $req.Request
Check ($req.Urls[0] -ceq 'https://api.github.com/repos/bitworks-io/amd-inference/releases/tags/v2026.10.15.1-canary' -and $store.version -ceq $old) 'store: a canary previous release is fetched by its canary tag'
$req = New-ReinstallRequest -StoreBody (Store-Body '2026.10.14.1')
Check ($null -eq (Get-FastLlmStoreRelease -Version $old -Channel 'stable' -Request $req.Request)) 'store: an answer for another tag is no store release'
$req = New-ReinstallRequest -StoreBody (Store-Body $old 'stable' $false $true)
Check ($null -eq (Get-FastLlmStoreRelease -Version $old -Channel 'stable' -Request $req.Request)) 'store: a stable tag that is a pre-release is no store release'
$offsite = Store-Body | ConvertFrom-Json
$offsite.html_url = 'https://evil.example/bitworks-io/amd-inference/releases/tag/v2026.10.15.1'
$req = New-ReinstallRequest -StoreBody (Json $offsite)
Check ($null -eq (Get-FastLlmStoreRelease -Version $old -Channel 'stable' -Request $req.Request)) 'store: an off-site release page is no store release'
$req = New-ReinstallRequest -StoreStatus 404 -StoreBody '{"message":"Not Found"}'
Check ($null -eq (Get-FastLlmStoreRelease -Version $old -Channel 'stable' -Request $req.Request)) 'store: a 404 is no store release'
$req = New-ReinstallRequest -StoreBody 'not json'
Check ($null -eq (Get-FastLlmStoreRelease -Version $old -Channel 'stable' -Request $req.Request)) 'store: an unreadable answer is no store release'
Check ($null -eq (Get-FastLlmStoreRelease -Version "$old`n" -Channel 'stable' -Request $req.Request) -and $req.Urls.Count -eq 1) 'store: a version that is not strict is never looked up'
$drafted = New-ReinstallRequest -StoreBody (Store-Body $old 'stable' $true)
Check ((Get-FastLlmStoreRelease -Version $old -Channel 'stable' -Request $drafted.Request).draft -eq $true) 'store: a draft is reported as a draft'

# The resolved decision. Local refusals never touch the network.
$localCases = @(
    @{ Name = 'no previous record'; Env = (New-ReinstallEnv -WithRecord $false); Reason = 'no-previous-record' },
    @{ Name = 'a record written for another install'; Env = (New-ReinstallEnv -ReplacedBy '2026.10.17.1'); Reason = 'not-immediate-previous' },
    @{ Name = 'a record naming a newer release'; Env = (New-ReinstallEnv -Previous '2026.10.17.1'); Reason = 'not-immediate-previous' },
    @{ Name = 'a target below the installed floor'; Env = (New-ReinstallEnv -InstalledPolicy (New-Policy 1 '2026.10.16.1')); Reason = 'below-security-floor' },
    @{ Name = 'a different data format'; Env = (New-ReinstallEnv -PreviousPolicy (New-Policy 2)); Reason = 'data-format-differs' },
    @{ Name = 'a previous release without a policy file'; Env = (New-ReinstallEnv -WithPreviousPolicyFile $false); Reason = 'data-format-missing' })
foreach ($case in $localCases) {
    $req = New-ReinstallRequest
    $r = Resolve-FastLlmReinstall -InstallRoot $case.Env.Install -AppRoot $case.Env.App -Request $req.Request
    Check ($r.decision -ceq 'refused' -and $r.reason -ceq $case.Reason -and $null -eq $r.latest -and $req.Urls.Count -eq 0) ('resolve: ' + $case.Name + ' is refused with no network request')
}
$e = New-Env -WithRelease $false
$r = Resolve-FastLlmReinstall -InstallRoot $e.Install -AppRoot $e.App -Request (New-ReinstallRequest).Request
Check ($r.decision -ceq 'refused' -and $r.reason -ceq 'not-a-release') 'resolve: no installed release is refused'
$e = New-ReinstallEnv
$req = New-ReinstallRequest
$r = Resolve-FastLlmReinstall -InstallRoot $e.Install -AppRoot $e.App -Request $req.Request
Check ($r.decision -ceq 'eligible' -and $r.target -ceq $old -and $r.installed -ceq $cur -and $r.latest.version -ceq $old -and $req.Urls.Count -eq 2) 'resolve: eligible after a fresh check and the store entry, with the release to install'
$req = New-ReinstallRequest -LatestTag 'v2026.10.17.1'
$r = Resolve-FastLlmReinstall -InstallRoot $e.Install -AppRoot $e.App -Request $req.Request
Check ($r.decision -ceq 'refused' -and $r.reason -ceq 'newer-release-available' -and $null -eq $r.latest -and $req.Urls.Count -eq 1 -and -not $req.Urls[0].Contains('/releases/tags/')) 'resolve: a newer release found by the fresh check refuses in favour of updating, without asking the store'
$req = New-ReinstallRequest -StoreStatus 404 -StoreBody '{}'
$r = Resolve-FastLlmReinstall -InstallRoot $e.Install -AppRoot $e.App -Request $req.Request
Check ($r.decision -ceq 'refused' -and $r.reason -ceq 'not-in-release-store' -and $null -eq $r.latest) 'resolve: a target missing from the store is refused'
$req = New-ReinstallRequest -StoreBody (Store-Body $old 'stable' $true)
$r = Resolve-FastLlmReinstall -InstallRoot $e.Install -AppRoot $e.App -Request $req.Request
Check ($r.decision -ceq 'refused' -and $r.reason -ceq 'draft-release' -and $null -eq $r.latest) 'resolve: a draft release is refused'
$offline = { param($Url, $Etag) throw 'offline' }
$r = Resolve-FastLlmReinstall -InstallRoot $e.Install -AppRoot $e.App -Request $offline
Check ($r.decision -ceq 'refused' -and $r.reason -ceq 'fresh-check-unreadable') 'resolve: offline, the fresh check cannot be read, so nothing is offered'
# The window's offer: no request beyond the normal update check, and never the store.
$e = New-ReinstallEnv
$req = New-ReinstallRequest
$r = Resolve-FastLlmReinstall -InstallRoot $e.Install -AppRoot $e.App -Request $req.Request -OfferOnly
Check ($r.decision -ceq 'eligible' -and $r.target -ceq $old -and $null -eq $r.latest -and $req.Urls.Count -eq 1 -and -not $req.Urls[0].Contains('/releases/tags/')) 'offer: eligible on the update check alone, with no store request and nothing to install from'
$req = New-ReinstallRequest
$r = Resolve-FastLlmReinstall -InstallRoot $e.Install -AppRoot $e.App -Request $req.Request -OfferOnly
Check ($r.decision -ceq 'eligible' -and $req.Urls.Count -eq 0) 'offer: a launch inside the 24 h window makes no request at all'
$e = New-ReinstallEnv
$req = New-ReinstallRequest -LatestTag 'v2026.10.17.1'
$r = Resolve-FastLlmReinstall -InstallRoot $e.Install -AppRoot $e.App -Request $req.Request -OfferOnly
Check ($r.decision -ceq 'refused' -and $r.reason -ceq 'newer-release-available' -and -not (@($req.Urls) -like '*/releases/tags/*')) 'offer: a newer release known from the check offers nothing and asks no store'
$e = New-ReinstallEnv -WithRecord $false
$req = New-ReinstallRequest
$r = Resolve-FastLlmReinstall -InstallRoot $e.Install -AppRoot $e.App -Request $req.Request -OfferOnly
Check ($r.decision -ceq 'refused' -and $req.Urls.Count -eq 0) 'offer: no record means no request at all'

# The API key and an older version: an older release has no key support, so with the key on (or its setting unreadable) nothing is offered
# or reinstalled, decided locally, before any request. Key off and a never-keyed install are unchanged.
. (Join-Path $root 'src/FastLlm.ServingSettings.ps1')
. (Join-Path $root 'src/FastLlm.UiFlow.ps1')
$keyText = "The API key is on, and the older version can't use it: it would serve without a key. To go back, turn the API key off in Settings, reinstall the older version, and turn the key on again after you update."
$script:keyNetworkCalls = 0
$throwingRequest = { param($Url, $Etag) $script:keyNetworkCalls++; throw 'the network must not be used' }
$keyStates = @(
    @{ Name = 'key on'; Json = '{"apiKey":"on"}' },
    @{ Name = 'key undetermined (unreadable value)'; Json = '{"apiKey":"maybe"}' },
    @{ Name = 'key undetermined (no setting saved, key store present)'; Json = $null; Store = $true })
foreach ($state in $keyStates) {
    $e = New-ReinstallEnv
    if ($null -ne $state.Json) { Set-Content -LiteralPath (Join-Path $e.Install 'settings.json') -Value $state.Json }
    if ($state.ContainsKey('Store')) { Set-Content -LiteralPath (Join-Path $e.Install $script:FastLlmServingApiKeyStoreName) -Value 'placeholder' }
    $script:keyNetworkCalls = 0
    $r = Resolve-FastLlmReinstall -InstallRoot $e.Install -AppRoot $e.App -Request $throwingRequest
    Check ($r.decision -ceq 'refused' -and $r.reason -ceq 'api-key-on' -and $null -eq $r.latest -and $r.target -ceq $old -and $r.installed -ceq $cur -and $script:keyNetworkCalls -eq 0) ("api-key: $($state.Name) refuses with api-key-on and the request seam is never called")
    $r = Resolve-FastLlmReinstall -InstallRoot $e.Install -AppRoot $e.App -Request $throwingRequest -OfferOnly
    Check ($r.reason -ceq 'api-key-on' -and $script:keyNetworkCalls -eq 0 -and $null -eq (Get-FastLlmUiReinstallOffer -Resolved $r)) ("api-key: $($state.Name) shows no window offer, with no request")
    $r = Resolve-FastLlmReinstall -InstallRoot $e.Install -AppRoot $e.App -Request $throwingRequest -OfferOnly -Check ([pscustomobject]@{ status = 'up-to-date'; installed = $cur; latest = @{ version = $cur } })
    Check ($r.reason -ceq 'api-key-on' -and $null -eq (Get-FastLlmUiReinstallOffer -Resolved $r)) ("api-key: $($state.Name) shows no window offer even with a check passed in")
    $s = Seams-For-Old
    $r = Invoke-FastLlmReinstallPrevious -InstallRoot $e.Install -AppRoot $e.App -Approve $approveYes -Request $throwingRequest -UpdateSeams (Install-Seams $s)
    $report = Get-FastLlmReinstallCliReport -Result $r
    Check ($r.status -ceq 'refused' -and $r.step -ceq 'decision' -and $r.reason -ceq 'api-key-on' -and $s.Order.Count -eq 0 -and $script:keyNetworkCalls -eq 0 -and (Test-Path -LiteralPath (RecordFolder $e))) ("api-key: $($state.Name) installs nothing and keeps the record")
    Check ($report.exitCode -eq 3 -and $report.text -ceq ('Reinstall refused: ' + $keyText) -and (Get-FastLlmReinstallReasonText 'api-key-on') -ceq $keyText) ("api-key: $($state.Name) update -Previous prints the approved text and exits 3")
    Check ((Format-FastLlmUiReinstallResult -Result $r -To $old) -ceq ('Reinstall not done: ' + $keyText)) ("api-key: $($state.Name) the window shows the same text on a refused click")
}
# Key off, and never keyed: identical to a decision made without this rule.
foreach ($unchanged in @(@{ Name = 'key off'; Json = '{"apiKey":"off"}' }, @{ Name = 'never keyed'; Json = $null })) {
    $e = New-ReinstallEnv
    if ($null -ne $unchanged.Json) { Set-Content -LiteralPath (Join-Path $e.Install 'settings.json') -Value $unchanged.Json }
    $req = New-ReinstallRequest
    $r = Resolve-FastLlmReinstall -InstallRoot $e.Install -AppRoot $e.App -Request $req.Request
    Check ($r.decision -ceq 'eligible' -and $r.reason -ceq 'eligible' -and $r.target -ceq $old -and $r.installed -ceq $cur -and $r.latest.version -ceq $old -and $req.Urls.Count -eq 2 -and @($r.PSObject.Properties.Name).Count -eq 5) ("api-key: $($unchanged.Name) decides exactly as before: eligible, same fields, two requests")
    $e = New-ReinstallEnv
    if ($null -ne $unchanged.Json) { Set-Content -LiteralPath (Join-Path $e.Install 'settings.json') -Value $unchanged.Json }
    $req = New-ReinstallRequest
    $r = Resolve-FastLlmReinstall -InstallRoot $e.Install -AppRoot $e.App -Request $req.Request -OfferOnly
    Check ($r.decision -ceq 'eligible' -and $null -eq $r.latest -and $req.Urls.Count -eq 1 -and $null -ne (Get-FastLlmUiReinstallOffer -Resolved $r)) ("api-key: $($unchanged.Name) still gets the window offer")
    $s = Seams-For-Old
    $r = Invoke-FastLlmReinstallPrevious -InstallRoot $e.Install -AppRoot $e.App -Approve $approveYes -Request (New-ReinstallRequest).Request -UpdateSeams (Install-Seams $s)
    $report = Get-FastLlmReinstallCliReport -Result $r
    Check ($r.status -ceq 'installed' -and $report.exitCode -eq 0 -and $report.text -ceq "FastLLM $old is reinstalled. Close and reopen FastLLM.") ("api-key: $($unchanged.Name) still reinstalls, with the same CLI text and exit code")
    $e = New-ReinstallEnv -WithRecord $false
    if ($null -ne $unchanged.Json) { Set-Content -LiteralPath (Join-Path $e.Install 'settings.json') -Value $unchanged.Json }
    $r = Resolve-FastLlmReinstall -InstallRoot $e.Install -AppRoot $e.App -Request $throwingRequest
    Check ($r.reason -ceq 'no-previous-record') ("api-key: $($unchanged.Name) keeps the other local refusals' own reasons")
}

# Update checks turned off: no store request, and the explicit action is refused (a newer release cannot be ruled out).
$e = New-ReinstallEnv
Set-FastLlmUpdateSettings -InstallRoot $e.Install -UpdateCheck 'off'
$req = New-ReinstallRequest
$r = Resolve-FastLlmReinstall -InstallRoot $e.Install -AppRoot $e.App -Request $req.Request -OfferOnly
Check ($r.decision -ceq 'refused' -and $r.reason -ceq 'update-checks-off' -and $req.Urls.Count -eq 0) 'resolve: offer-only with update checks off makes no request and offers nothing'
$r = Resolve-FastLlmReinstall -InstallRoot $e.Install -AppRoot $e.App -Request $req.Request
Check ($r.decision -ceq 'refused' -and $r.reason -ceq 'update-checks-off' -and $null -eq $r.latest -and $req.Urls.Count -eq 0) 'resolve: the explicit action with update checks off is refused (the newer-release rule cannot be applied), with no request'
$s = Seams-For-Old
$r = Invoke-FastLlmReinstallPrevious -InstallRoot $e.Install -AppRoot $e.App -Approve $approveNever -Request $req.Request -UpdateSeams (Install-Seams $s)
Check ($r.status -ceq 'refused' -and $r.reason -ceq 'update-checks-off' -and $s.Order.Count -eq 0) 'reinstall: with update checks off nothing is stopped, downloaded or run'

# F1: the "newer release first" rule fails closed. A fresh check that cannot be read refuses; it is never read as "allowed".
$e = New-ReinstallEnv
$unreadable = @(
    @{ Name = 'a timeout'; Req = (New-ReinstallRequest -LatestThrows $true) },
    @{ Name = 'a 403'; Req = (New-ReinstallRequest -LatestStatus 403 -LatestBody '{"message":"rate limit"}') },
    @{ Name = 'a 500'; Req = (New-ReinstallRequest -LatestStatus 500 -LatestBody 'oops') },
    @{ Name = 'a 200 with an unparseable tag'; Req = (New-ReinstallRequest -LatestBody (Json (Rel 'not-a-version-tag'))) },
    @{ Name = 'a 200 that is not JSON'; Req = (New-ReinstallRequest -LatestBody 'not json') })
foreach ($case in $unreadable) {
    $s = Seams-For-Old
    $r = Resolve-FastLlmReinstall -InstallRoot $e.Install -AppRoot $e.App -Request $case.Req.Request
    Check ($r.decision -ceq 'refused' -and $r.reason -ceq 'fresh-check-unreadable' -and $null -eq $r.latest -and -not (@($case.Req.Urls) -like '*/releases/tags/*')) ('fresh check: ' + $case.Name + ' refuses and the store is never asked')
    $r = Invoke-FastLlmReinstallPrevious -InstallRoot $e.Install -AppRoot $e.App -Approve $approveNever -Request $case.Req.Request -UpdateSeams (Install-Seams $s)
    Check ($r.status -ceq 'refused' -and $r.reason -ceq 'fresh-check-unreadable' -and $s.Order.Count -eq 0 -and @(UpdateDirs $e).Count -eq 0) ('fresh check: ' + $case.Name + ' installs nothing')
}
$s = Seams-For-Old
$control = New-ReinstallRequest -LatestTag 'v2026.10.17.1'
$r = Invoke-FastLlmReinstallPrevious -InstallRoot $e.Install -AppRoot $e.App -Approve $approveNever -Request $control.Request -UpdateSeams (Install-Seams $s)
Check ($r.status -ceq 'refused' -and $r.reason -ceq 'newer-release-available' -and $s.Order.Count -eq 0) 'fresh check: the control (latest is newer) still says newer-release-available'
$r = Resolve-FastLlmReinstall -InstallRoot $e.Install -AppRoot $e.App -Request (New-ReinstallRequest).Request
Check ($r.decision -ceq 'eligible') 'fresh check: a readable, not-newer answer is eligible'

# F5: the window passes the first check's result in, so no second request is made.
$e = New-ReinstallEnv
foreach ($case in @(@{ Name = 'failed'; Check = [pscustomobject]@{ status = 'failed'; installed = $cur; latest = $null }; Reason = 'fresh-check-unreadable' },
                    @{ Name = 'a newer release'; Check = [pscustomobject]@{ status = 'available'; installed = $cur; latest = @{ version = '2026.10.17.1' } }; Reason = 'newer-release-available' },
                    @{ Name = 'disabled'; Check = [pscustomobject]@{ status = 'disabled'; installed = $cur; latest = $null }; Reason = 'update-checks-off' },
                    @{ Name = 'up to date with no latest'; Check = [pscustomobject]@{ status = 'up-to-date'; installed = $cur; latest = $null }; Reason = 'fresh-check-unreadable' },
                    @{ Name = 'up to date'; Check = [pscustomobject]@{ status = 'up-to-date'; installed = $cur; latest = @{ version = $cur } }; Reason = 'eligible' },
                    @{ Name = 'no result at all'; Check = $null; Reason = 'fresh-check-unreadable' })) {
    $req = New-ReinstallRequest
    $r = Resolve-FastLlmReinstall -InstallRoot $e.Install -AppRoot $e.App -Request $req.Request -OfferOnly -Check $case.Check
    Check ($r.reason -ceq $case.Reason -and $req.Urls.Count -eq 0 -and $null -eq $r.latest) ('offer: with the first check passed in (' + $case.Name + ') no request is made, and the answer is ' + $case.Reason)
}
$req = New-ReinstallRequest -LatestThrows $true
$r = Resolve-FastLlmReinstall -InstallRoot (New-ReinstallEnv).Install -AppRoot $e.App -Request $req.Request -OfferOnly
Check ($r.decision -ceq 'refused' -and $r.reason -ceq 'fresh-check-unreadable' -and $r.decision -cne 'eligible') 'offer: an update check that failed offers nothing'

# F2/F4: what the person confirmed is what is replaced.
$e = New-ReinstallEnv
$s = Seams-For-Old
$changeInstalled = { param($From, $To) Set-Content -LiteralPath (Join-Path $e.App 'RELEASE.json') -Value (@{ version = '2026.10.17.1'; channel = 'stable' } | ConvertTo-Json); $true }.GetNewClosure()
$r = Invoke-FastLlmReinstallPrevious -InstallRoot $e.Install -AppRoot $e.App -Approve $changeInstalled -Request (New-ReinstallRequest).Request -UpdateSeams (Install-Seams $s)
Check ($r.status -ceq 'refused' -and $r.reason -ceq 'installed-changed' -and $s.Order.Count -eq 0 -and (Test-Path -LiteralPath (RecordFolder $e))) 'installed changed while the prompt waited: refused before anything is stopped or installed, and the record is kept'
$e = New-ReinstallEnv
$s = Seams-For-Old
$r = Invoke-FastLlmReinstallPrevious -InstallRoot $e.Install -AppRoot $e.App -Approve $approveNever -ExpectedFrom '2026.10.14.1' -ExpectedTarget $old -Request (New-ReinstallRequest).Request -UpdateSeams (Install-Seams $s)
Check ($r.status -ceq 'refused' -and $r.reason -ceq 'target-changed' -and $s.Order.Count -eq 0) 'a replaced version that differs from the one shown is refused as target-changed'
$s = Seams-For-Old
$r = Invoke-FastLlmReinstallPrevious -InstallRoot $e.Install -AppRoot $e.App -Approve $approveYes -ExpectedFrom $cur -ExpectedTarget $old -Request (New-ReinstallRequest).Request -UpdateSeams (Install-Seams $s)
Check ($r.status -ceq 'installed') 'the confirmed replaced and target versions install'

# Rule 8: history, the support bundle, and muting the banner for the version just left.
$h = @(Read-FastLlmReinstallHistory -InstallRoot $e.Install)
Check ($h.Count -eq 1 -and $h[0].from -ceq $cur -and $h[0].to -ceq $old -and $h[0].atUtc -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') 'history: a successful reinstall records from, to and the UTC time'
$e2 = New-ReinstallEnv
$when = New-Object DateTime -ArgumentList 2026, 11, 16, 12, 30, 5, ([DateTimeKind]::Utc)
$s = Seams-For-Old
$r = Invoke-FastLlmReinstallPrevious -InstallRoot $e2.Install -AppRoot $e2.App -Approve $approveYes -Request (New-ReinstallRequest).Request -UpdateSeams (Install-Seams $s) -NowUtc $when
$h = @(Read-FastLlmReinstallHistory -InstallRoot $e2.Install)
Check ($h.Count -eq 1 -and $h[0].atUtc -ceq '2026-11-16T12:30:05Z') 'history: the time comes from the clock seam, in UTC'
foreach ($notInstalled in @(@{ Name = 'declined'; Approve = { param($From, $To) $false }; O = @{} }, @{ Name = 'a failed install'; Approve = $approveYes; O = @{ Exit = 1 } })) {
    $e3 = New-ReinstallEnv
    $s = Seams-For-Old $notInstalled.O
    $r = Invoke-FastLlmReinstallPrevious -InstallRoot $e3.Install -AppRoot $e3.App -Approve $notInstalled.Approve -Request (New-ReinstallRequest).Request -UpdateSeams (Install-Seams $s)
    Check (@(Read-FastLlmReinstallHistory -InstallRoot $e3.Install).Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path (Join-Path $e3.Install 'state') 'update-muted.json'))) ('history: ' + $notInstalled.Name + ' writes no history and no mute')
}
$e4 = New-Env
for ($n = 1; $n -le 25; $n++) { Add-FastLlmReinstallHistory -InstallRoot $e4.Install -From '2026.10.16.1' -To '2026.10.15.1' -NowUtc $when.AddMinutes($n) }
$h = @(Read-FastLlmReinstallHistory -InstallRoot $e4.Install)
Check ($h.Count -eq 20 -and $h[19].atUtc -ceq '2026-11-16T12:55:05Z') 'history: only the newest 20 entries are kept'
$historyPath = Join-Path (Join-Path $e4.Install 'state') 'reinstall-history.json'
Set-Content -LiteralPath $historyPath -Value '{"entries":[{"from":"2026.10.16.1","to":"2026.10.15.1","atUtc":"2026-11-16T12:30:05Z"},{"from":"evil; calc","to":"2026.10.15.1","atUtc":"2026-11-16T12:30:05Z"},{"from":"2026.10.16.1","to":"2026.10.15.1","atUtc":"not a time"},{"from":"2026.10.16.1","to":"2026.10.15.1","atUtc":"2026-11-16T12:30:05Z","prompt":"secret"}]}'
$h = @(Read-FastLlmReinstallHistory -InstallRoot $e4.Install)
Check ($h.Count -eq 2 -and (@($h | Where-Object { $_.PSObject.Properties.Name.Count -ne 3 }).Count -eq 0)) 'history: entries that are not a strict version pair and a UTC time are dropped, and extra fields are never read'
Set-Content -LiteralPath $historyPath -Value '{ not json'
Check (@(Read-FastLlmReinstallHistory -InstallRoot $e4.Install).Count -eq 0) 'history: an unreadable file reads as empty'

# The support bundle carries the history: versions and times only, and only when there is one.
. (Join-Path $root 'src/FastLlm.SupportBundle.ps1')
$bundleDir = Add-TempPath (Join-Path ([IO.Path]::GetTempPath()) ('fastllm-bundle-' + [guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path $bundleDir -Force | Out-Null
$listing = New-FastLlmSupportBundle -InstallRoot $e4.Install -AppRoot $e4.App -OutputPath (Join-Path $bundleDir 'none.zip') -Doctor ([pscustomobject]@{ note = 'x' }) -ListOnly
Check (@($listing.entries | Where-Object { $_.name -ceq 'reinstall-history.json' }).Count -eq 0) 'bundle: no history entry when there is no history'
$listing = New-FastLlmSupportBundle -InstallRoot $e2.Install -AppRoot $e2.App -OutputPath (Join-Path $bundleDir 'with.zip') -Doctor ([pscustomobject]@{ note = 'x' })
Check (@($listing.entries | Where-Object { $_.name -ceq 'reinstall-history.json' }).Count -eq 1) 'bundle: the history is listed as reinstall-history.json'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead((Join-Path $bundleDir 'with.zip'))
try {
    $entry = $zip.GetEntry('reinstall-history.json')
    $reader = New-Object IO.StreamReader($entry.Open())
    $historyText = $reader.ReadToEnd()
    $reader.Dispose()
}
finally { $zip.Dispose() }
$historyDoc = $historyText | ConvertFrom-Json
Check (@($historyDoc.entries).Count -eq 1 -and $historyDoc.entries[0].from -ceq $cur -and $historyDoc.entries[0].to -ceq $old -and $historyText -match '"atUtc":\s*"2026-11-16T12:30:05Z"' -and @($historyDoc.entries[0].PSObject.Properties).Count -eq 3) 'bundle: the entry holds only from, to and the time'
Remove-Item -LiteralPath $bundleDir -Recurse -Force -ErrorAction SilentlyContinue

# Muting: the version just left is not offered again by the passive notices; a NEWER release is.
Check ((Test-FastLlmUpdateMuted -InstallRoot $e2.Install -LatestVersion $cur) -eq $true) 'mute: the version just left is muted after a reinstall'
Check ((Test-FastLlmUpdateMuted -InstallRoot $e2.Install -LatestVersion '2026.10.17.1') -eq $false) 'mute: a newer release than the one left is not muted'
Check ((Test-FastLlmUpdateMuted -InstallRoot $e2.Install -LatestVersion $old) -eq $false) 'mute: an older version is not muted, only the exact version left'
Check ((Test-FastLlmUpdateMuted -InstallRoot (New-Env).Install -LatestVersion $cur) -eq $false) 'mute: nothing is muted without a mute record'
$mutePath = Join-Path (Join-Path $e2.Install 'state') 'update-muted.json'
Set-Content -LiteralPath $mutePath -Value '{"version":"evil"}'
Check ((Test-FastLlmUpdateMuted -InstallRoot $e2.Install -LatestVersion $cur) -eq $false) 'mute: an unreadable record mutes nothing'
Set-Content -LiteralPath $mutePath -Value '{ not json'
Check ((Test-FastLlmUpdateMuted -InstallRoot $e2.Install -LatestVersion $cur) -eq $false) 'mute: a corrupt record mutes nothing'
$e5 = New-Env -Version $old
Write-FastLlmUpdateState -Path (Join-Path (Join-Path $e5.Install 'state') 'update-check.json') -CheckedUtc $t0 -Etag 'x' -Channel 'stable' -Latest (New-Latest $cur)
Check ($null -ne (Get-FastLlmCachedUpdateNotice -InstallRoot $e5.Install -AppRoot $e5.App)) 'mute: without a mute record the cached notice offers the newer release'
Set-FastLlmUpdateMute -InstallRoot $e5.Install -Version $cur
Check ($null -eq (Get-FastLlmCachedUpdateNotice -InstallRoot $e5.Install -AppRoot $e5.App)) 'mute: the cached notice is silent for the version just left'
Write-FastLlmUpdateState -Path (Join-Path (Join-Path $e5.Install 'state') 'update-check.json') -CheckedUtc $t0 -Etag 'x' -Channel 'stable' -Latest (New-Latest '2026.10.17.1')
Check ($null -ne (Get-FastLlmCachedUpdateNotice -InstallRoot $e5.Install -AppRoot $e5.App)) 'mute: the cached notice offers a release newer than the one left'
$r = Invoke-FastLlmUpdateCheck -InstallRoot $e5.Install -AppRoot $e5.App -Request (Mock 200 (Json (Rel 'v2026.10.16.1'))) -NowUtc $t0 -Force
Check ($r.status -ceq 'available') 'mute: the explicit update check itself is unchanged and still reports the release'

# Every reason code has plain words, and an unknown one still has some.
foreach ($code in @('no-previous-record', 'not-immediate-previous', 'below-security-floor', 'data-format-differs', 'data-format-missing', 'fresh-check-unreadable', 'newer-release-available', 'not-in-release-store', 'draft-release', 'update-checks-off', 'target-changed', 'not-a-release', 'approval-required', 'installed-changed', 'a-code-from-the-future', '')) {
    $words = Get-FastLlmReinstallReasonText $code
    Check ($words.Length -gt 20 -and $words -cnotmatch '^[a-z]+(-[a-z]+)+$' -and $words.EndsWith('.')) "reason text: '$code' reads as a sentence"
}
Check ((Get-FastLlmReinstallReasonText 'below-security-floor') -ceq 'The previous version has a known security problem that this version fixes.') 'reason text: the security floor sentence is the design text'

# Invoke-FastLlmReinstallPrevious: refusals reach the user as text and nothing is stopped, downloaded or run.
$refusalCases = @(
    @{ Name = 'no record'; Env = (New-ReinstallEnv -WithRecord $false); Req = (New-ReinstallRequest); Reason = 'no-previous-record' },
    @{ Name = 'a tampered record'; Env = (New-ReinstallEnv -ReplacedBy '2026.10.17.1'); Req = (New-ReinstallRequest); Reason = 'not-immediate-previous' },
    @{ Name = 'below the floor'; Env = (New-ReinstallEnv -InstalledPolicy (New-Policy 1 '2026.10.16.1')); Req = (New-ReinstallRequest); Reason = 'below-security-floor' },
    @{ Name = 'a data format mismatch'; Env = (New-ReinstallEnv -PreviousPolicy (New-Policy 2)); Req = (New-ReinstallRequest); Reason = 'data-format-differs' },
    @{ Name = 'a newer release'; Env = (New-ReinstallEnv); Req = (New-ReinstallRequest -LatestTag 'v2026.10.17.1'); Reason = 'newer-release-available' },
    @{ Name = 'a release missing from the store'; Env = (New-ReinstallEnv); Req = (New-ReinstallRequest -StoreStatus 404 -StoreBody '{}'); Reason = 'not-in-release-store' },
    @{ Name = 'a draft'; Env = (New-ReinstallEnv); Req = (New-ReinstallRequest -StoreBody (Store-Body $old 'stable' $true)); Reason = 'draft-release' })
foreach ($case in $refusalCases) {
    $s = Seams-For-Old
    $r = Invoke-FastLlmReinstallPrevious -InstallRoot $case.Env.Install -AppRoot $case.Env.App -Approve $approveNever -Request $case.Req.Request -UpdateSeams (Install-Seams $s)
    $report = Get-FastLlmReinstallCliReport -Result $r
    Check ($r.status -ceq 'refused' -and $r.step -ceq 'decision' -and $r.reason -ceq $case.Reason -and $r.message -ceq (Get-FastLlmReinstallReasonText $case.Reason) -and $s.Order.Count -eq 0 -and @(UpdateDirs $case.Env).Count -eq 0) ('reinstall: ' + $case.Name + ' is refused with its reason, and nothing is stopped or downloaded')
    Check ($report.exitCode -eq 3 -and $report.text -ceq ('Reinstall refused: ' + (Get-FastLlmReinstallReasonText $case.Reason))) ('reinstall: ' + $case.Name + ' prints the reason in plain words and exits 3')
}

# Allowed: the approval names both versions, then the SAME verified path installs the PREVIOUS release's artifact.
$e = New-ReinstallEnv
$req = New-ReinstallRequest
$s = Seams-For-Old
$downloadedUrls = New-Object 'System.Collections.Generic.List[string]'
$innerDownload = $s.Download
$recordingDownload = { param($Url, $Destination, $Sha256, $SizeBytes) $downloadedUrls.Add([string]$Url); & $innerDownload $Url $Destination $Sha256 $SizeBytes }.GetNewClosure()
$us = Install-Seams $s
$us['Download'] = $recordingDownload
$asked = New-Object 'System.Collections.Generic.List[string]'
$approveRecording = { param($From, $To) $asked.Add("$From>$To"); $true }.GetNewClosure()
$r = Invoke-FastLlmReinstallPrevious -InstallRoot $e.Install -AppRoot $e.App -Approve $approveRecording -Request $req.Request -UpdateSeams $us
Check ($r.status -ceq 'installed' -and $r.from -ceq $cur -and $r.to -ceq $old) 'reinstall: an allowed, approved reinstall installs'
Check ((($s.Order -join ',') -ceq 'stop,sums,download,verify,version,install,integrity')) 'reinstall: it runs the same verified steps as an update, in the same order'
Check ($asked.Count -eq 1 -and $asked[0] -ceq "$cur>$old") 'reinstall: the approval is asked once, with the installed version and the target'
Check ($downloadedUrls.Count -eq 2 -and $downloadedUrls[0] -ceq ($good + 'v2026.10.15.1/SHA256SUMS') -and $downloadedUrls[1] -ceq ($good + 'v2026.10.15.1/FastLLM-Setup-2026.10.15.1.exe')) 'reinstall: it downloads the PREVIOUS release SHA256SUMS and installer from the release store'
Check (-not (Test-Path -LiteralPath (RecordFolder $e))) 'reinstall: the previous-release record is cleared after an install, so going back never chains'

# The CLI's approver, all the way through: the prompt names both versions and only y or yes installs the previous release.
$e = New-ReinstallEnv
$s = Seams-For-Old
$prompts.Clear()
$r = Invoke-FastLlmReinstallPrevious -InstallRoot $e.Install -AppRoot $e.App -Approve (New-FastLlmReinstallApprover -Prompt (New-Prompt 'y')) -Request (New-ReinstallRequest).Request -UpdateSeams (Install-Seams $s)
Check ($r.status -ceq 'installed' -and $r.to -ceq $old -and $prompts.Count -eq 1 -and $prompts[0] -ceq "Reinstall FastLLM $old (replaces $cur)? [y/N]" -and (($s.Order -join ',') -ceq 'stop,sums,download,verify,version,install,integrity')) 'reinstall: the prompt names both versions, and a y installs the previous release through the verified path'
$e = New-ReinstallEnv
$s = Seams-For-Old
$r = Invoke-FastLlmReinstallPrevious -InstallRoot $e.Install -AppRoot $e.App -Approve (New-FastLlmReinstallApprover -Prompt (New-Prompt 'n')) -Request (New-ReinstallRequest).Request -UpdateSeams (Install-Seams $s)
Check ($r.status -ceq 'declined' -and $s.Order.Count -eq 0) 'reinstall: an answer of n installs nothing'
Check (-not (Get-Command New-FastLlmReinstallApprover).Parameters.ContainsKey('Yes')) 'reinstall: the approver has no way to skip the prompt'

# Not approved: nothing happens.
foreach ($notYes in @({ param($From, $To) $false }, { param($From, $To) 'yes' }, { param($From, $To) $null }, { param($From, $To) @($true, $true) }, { param($From, $To) throw 'boom' })) {
    $e = New-ReinstallEnv
    $s = Seams-For-Old
    $r = Invoke-FastLlmReinstallPrevious -InstallRoot $e.Install -AppRoot $e.App -Approve $notYes -Request (New-ReinstallRequest).Request -UpdateSeams (Install-Seams $s)
    Check ($r.status -ceq 'declined' -and $s.Order.Count -eq 0 -and (Test-Path -LiteralPath (RecordFolder $e)) -and (Get-FastLlmReinstallCliReport -Result $r).exitCode -eq 0) 'reinstall: anything but exactly true declines, stops nothing and keeps the record'
}
# The window's guard: the target it showed must still be the one decided.
$e = New-ReinstallEnv
$s = Seams-For-Old
$r = Invoke-FastLlmReinstallPrevious -InstallRoot $e.Install -AppRoot $e.App -Approve $approveNever -ExpectedTarget '2026.10.14.1' -Request (New-ReinstallRequest).Request -UpdateSeams (Install-Seams $s)
Check ($r.status -ceq 'refused' -and $r.reason -ceq 'target-changed' -and $s.Order.Count -eq 0) 'reinstall: a target that differs from the confirmed one is refused before anything runs'
$s = Seams-For-Old
$r = Invoke-FastLlmReinstallPrevious -InstallRoot $e.Install -AppRoot $e.App -Approve $approveYes -ExpectedTarget $old -Request (New-ReinstallRequest).Request -UpdateSeams (Install-Seams $s)
Check ($r.status -ceq 'installed') 'reinstall: the confirmed target installs'

# A failure on the verified path keeps the record and reports the step.
foreach ($failure in @(@{ O = @{ SigOk = $false; SigReason = 'wrong-publisher' }; Step = 'signature'; Status = 'refused' }, @{ O = @{ ProductVersion = '2026.10.14.1' }; Step = 'version'; Status = 'refused' }, @{ O = @{ Exit = 1 }; Step = 'install'; Status = 'failed' }, @{ O = @{ DownloadFail = $true }; Step = 'download'; Status = 'failed' })) {
    $e = New-ReinstallEnv
    $s = Seams-For-Old $failure.O
    $r = Invoke-FastLlmReinstallPrevious -InstallRoot $e.Install -AppRoot $e.App -Approve $approveYes -Request (New-ReinstallRequest).Request -UpdateSeams (Install-Seams $s)
    Check ($r.status -ceq $failure.Status -and $r.step -ceq $failure.Step -and (Test-Path -LiteralPath (RecordFolder $e))) ('reinstall: a ' + $failure.Step + ' failure is reported and the record is kept')
}

# The verified update path itself: -PreviousTarget is opt-in, exact and older; without it nothing changed.
$e = New-Env -Version $cur
$s = Seams-For-Old
$us = Install-Seams $s
$r = Invoke-FastLlmVerifiedUpdate -InstallRoot $e.Install -AppRoot $e.App -Latest (New-Latest $old) @us
Check ($r.status -ceq 'refused' -and $r.step -ceq 'version' -and $r.reason -ceq 'not-newer' -and -not ($s.Order -contains 'install')) 'previous target: without it an older release is still refused as not-newer'
$e = New-Env -Version $cur
$s = Seams-For-Old
$us = Install-Seams $s
$r = Invoke-FastLlmVerifiedUpdate -InstallRoot $e.Install -AppRoot $e.App -Latest (New-Latest $old) -PreviousTarget '2026.10.14.1' -PreviousFrom $cur @us
Check ($r.status -ceq 'refused' -and $r.reason -ceq 'not-the-previous-target' -and -not ($s.Order -contains 'install')) 'previous target: a release that is not the target is refused'
$e = New-Env -Version $old
$s = New-Seams
$us = Install-Seams $s
$r = Invoke-FastLlmVerifiedUpdate -InstallRoot $e.Install -AppRoot $e.App -Latest (New-Latest $cur) -PreviousTarget $cur -PreviousFrom $old @us
Check ($r.status -ceq 'refused' -and $r.reason -ceq 'not-older' -and -not ($s.Order -contains 'install')) 'previous target: a newer release is refused even when named as the target'
$e = New-Env -Version $cur
$s = New-Seams
$us = Install-Seams $s
$r = Invoke-FastLlmVerifiedUpdate -InstallRoot $e.Install -AppRoot $e.App -Latest (New-Latest $cur) -PreviousTarget $cur -PreviousFrom $cur @us
Check ($r.status -ceq 'refused' -and $r.reason -ceq 'not-older' -and -not ($s.Order -contains 'install')) 'previous target: the installed version itself is refused'
$e = New-Env -Version '2026.10.17.1'
$s = Seams-For-Old
$us = Install-Seams $s
$r = Invoke-FastLlmVerifiedUpdate -InstallRoot $e.Install -AppRoot $e.App -Latest (New-Latest $old) -PreviousTarget $old -PreviousFrom $cur @us
Check ($r.status -ceq 'refused' -and $r.step -ceq 'version' -and $r.reason -ceq 'installed-changed' -and -not ($s.Order -contains 'install')) 'previous target: an installed version other than the decided one is refused (installed-changed)'
$e = New-Env -Version $cur
$s = Seams-For-Old
$us = Install-Seams $s
$r = Invoke-FastLlmVerifiedUpdate -InstallRoot $e.Install -AppRoot $e.App -Latest (New-Latest $old) -PreviousTarget $old @us
Check ($r.status -ceq 'refused' -and $r.reason -ceq 'installed-changed' -and -not ($s.Order -contains 'install')) 'previous target: without the decided installed version nothing is installed'

# The confirmation and the CLI report.
$prompts.Clear()
foreach ($yes in @('y', 'Y', 'yes', ' YES ')) {
    $prompts.Clear()
    $approver = New-FastLlmReinstallApprover -Prompt (New-Prompt $yes)
    Check ((& $approver $cur $old) -eq $true -and $prompts.Count -eq 1 -and $prompts[0] -ceq "Reinstall FastLLM $old (replaces $cur)? [y/N]") "confirm: without -Yes it asks naming both versions, and '$yes' confirms"
}
foreach ($no in @('', 'n', 'no', 'yellow', 'yes please', '1', $null)) {
    $approver = New-FastLlmReinstallApprover -Prompt (New-Prompt $no)
    Check ((& $approver $cur $old) -eq $false) "confirm: '$no' does not confirm"
}
$report = Get-FastLlmReinstallCliReport -Result ([pscustomobject]@{ status = 'installed'; step = 'integrity'; reason = ''; to = $old })
Check ($report.exitCode -eq 0 -and $report.text -like "*$old*") 'report: installed exits 0'
$report = Get-FastLlmReinstallCliReport -Result ([pscustomobject]@{ status = 'declined'; step = 'confirm'; reason = 'not-confirmed' })
Check ($report.exitCode -eq 0 -and $report.text -ceq 'Not reinstalled. Nothing was changed.') 'report: declined exits 0 and says nothing changed'
$report = Get-FastLlmReinstallCliReport -Result ([pscustomobject]@{ status = 'failed'; step = 'install'; reason = 'installer-exit-1'; to = $old })
Check ($report.exitCode -eq 1 -and $report.text -ceq 'Reinstall failed at install: installer-exit-1') 'report: a failed install exits 1'
$report = Get-FastLlmReinstallCliReport -Result ([pscustomobject]@{ status = 'refused'; step = 'signature'; reason = 'wrong-publisher'; to = $old })
Check ($report.exitCode -eq 3) 'report: a refusal on the verified path exits 3'
$report = Get-FastLlmReinstallCliReport -Result ([pscustomobject]@{ status = 'failed'; step = 'integrity'; reason = 'tree'; to = $old })
Check ($report.exitCode -eq 1 -and $report.text -like "*don't match the signed catalog*") 'report: an integrity failure after the installer says so and exits 1'

# Where the reinstall is wired: only the explicit CLI action and the window click may call it, and only the update script passes -PreviousTarget.
$callers = @()
$previousTargetUsers = @()
$decisionCallers = @()
$sourceFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.psm1', '.cmd', '.iss') -and $_.FullName -notmatch '[\\/](tests|\.git)[\\/]' })
foreach ($sourceFile in $sourceFiles) {
    $text = [IO.File]::ReadAllText($sourceFile.FullName)
    if ($text.Contains('Invoke-FastLlmReinstallPrevious')) { $callers += $sourceFile.Name }
    if ($text.Contains('-PreviousTarget')) { $previousTargetUsers += $sourceFile.Name }
    if ($text.Contains('Get-FastLlmReinstallDecision')) { $decisionCallers += $sourceFile.Name }
}
Check (@($callers).Count -eq 3 -and ($callers -ccontains 'FastLlm.Update.ps1') -and ($callers -ccontains 'fast-llm-ui.ps1') -and ($callers -ccontains 'fast-llm.ps1')) ('wiring: only the update script, the CLI update action and the window mention the reinstall action (found: ' + ($callers -join ',') + ')')
Check ((@($previousTargetUsers) -join ',') -ceq 'FastLlm.Update.ps1') 'wiring: only the update script passes or reads -PreviousTarget'
Check ((@($decisionCallers) -join ',') -ceq 'FastLlm.Update.ps1') 'wiring: the decision is named only in the update script'
$updateSource = [IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.Update.ps1'))
Check ([regex]::Matches($updateSource, '-PreviousTarget \(\[string\]\$resolved\.target\)').Count -eq 1) 'wiring: the one call that passes -PreviousTarget uses the decision target'
$verifiedStart = $updateSource.IndexOf('function Invoke-FastLlmVerifiedUpdate')
$reinstallStart = $updateSource.IndexOf('# --- Reinstall the previous version')
Check ($verifiedStart -gt 0 -and $reinstallStart -gt $verifiedStart -and -not $updateSource.Substring($verifiedStart, $reinstallStart - $verifiedStart).Contains('Get-FastLlmReinstallDecision')) 'wiring: the verified update path never calls the decision'
$cliSource = [IO.File]::ReadAllText((Join-Path $root 'fast-llm.ps1'))
$updateActionStart = $cliSource.IndexOf("        'update' {")
$updateAction = $cliSource.Substring($updateActionStart, $cliSource.IndexOf("        'stop' {") - $updateActionStart)
$reinstallBranch = $updateAction.Substring(0, $updateAction.IndexOf('Invoke-FastLlmUpdateCheck'))
Check ($reinstallBranch.Contains('if ($Previous) {') -and $reinstallBranch.Contains('Invoke-FastLlmReinstallPrevious') -and $reinstallBranch.Contains('New-FastLlmReinstallApprover') -and -not $reinstallBranch.Contains('Yes')) 'wiring: update -Previous branches off before the normal update check'
Check ($updateAction.Contains('Invoke-FastLlmVerifiedUpdate -InstallRoot $InstallRoot -AppRoot $PSScriptRoot -Latest $updateLatest -Silent:$Unattended') -and -not $updateAction.Contains('PreviousTarget')) 'wiring: the normal update call is unchanged and never passes -PreviousTarget'

# The CLI: parameter, abbreviations, guards, and a real run that refuses without any network.
$cliAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'fast-llm.ps1'), [ref]$null, [ref]$null)
$cliParameters = @($cliAst.ParamBlock.Parameters)
$previousParameter = @($cliParameters | Where-Object { $_.Name.VariablePath.UserPath -ceq 'Previous' })
Check ($previousParameter.Count -eq 1 -and $previousParameter[0].StaticType -eq [System.Management.Automation.SwitchParameter]) 'cli: fast-llm.ps1 declares -Previous as a switch'
$names = @($cliParameters | ForEach-Object { $_.Name.VariablePath.UserPath })
$common = @('Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable')
function Resolve-Prefix([string]$Prefix, [string[]]$Pool) {
    $exact = @($Pool | Where-Object { $_ -ieq $Prefix })
    if ($exact.Count -eq 1) { return $exact[0] }
    $hits = @($Pool | Where-Object { $_.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase) })
    if ($hits.Count -eq 1) { return $hits[0] }
    return $null
}
$withoutPrevious = @(@($names) + $common | Where-Object { $_ -cne 'Previous' })
$withPrevious = @(@($names) + $common)
$changed = @()
foreach ($name in $withoutPrevious) {
    for ($length = 1; $length -le $name.Length; $length++) {
        $prefix = $name.Substring(0, $length)
        $before = Resolve-Prefix $prefix $withoutPrevious
        if ($null -ne $before -and (Resolve-Prefix $prefix $withPrevious) -cne $before) { $changed += $prefix }
    }
}
Check ($changed.Count -eq 0) ('cli: adding -Previous leaves every parameter abbreviation that resolved uniquely resolving to the same parameter (changed: ' + ($changed -join ',') + ')')
foreach ($name in @('Preload', 'PreloadStatus', 'Profile', 'Port', 'PlannedRecipe', 'ProbeVulkanMemory')) {
    Check ((Resolve-Prefix $name $withPrevious) -ceq $name) "cli: -$name still resolves to itself"
}
Check ((Resolve-Prefix 'Prev' $withPrevious) -ceq 'Previous' -and $null -eq (Resolve-Prefix 'Pre' $withPrevious)) 'cli: -Prev is -Previous, and -Pre stays ambiguous as before'
$shell = (Get-Process -Id $PID).Path
function Invoke-Cli([string[]]$Arguments) {
    # Windows PowerShell 5.1 turns a native command's stderr into a terminating error under 'Stop'; the refusals under test write to stderr.
    # Thrown text can be wrapped or prefixed by the host, so whitespace is collapsed before it is matched.
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = @(& $shell -NoLogo -NoProfile -NonInteractive -File (Join-Path $root 'fast-llm.ps1') @Arguments 2>&1 | ForEach-Object { [string]$_ })
        $code = $LASTEXITCODE
        [pscustomobject]@{ code = $code; text = ((($lines -join ' ') -replace '\s+', ' ').Trim()) }
    }
    finally { $ErrorActionPreference = $savedPreference }
}
$cliRoot = Add-TempPath (Join-Path ([IO.Path]::GetTempPath()) ('fastllm-cli-root-' + [guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path $cliRoot -Force | Out-Null
# These three children get past fast-llm.ps1's parameter checks, so they reach its standard-user guard, which refuses every live action under
# an Administrator token (the hosted Windows runner is elevated). Elevated, the test checks instead that the guard refuses update -Previous
# before any reinstall step. The plain-words refusal is checked in-process above for every reason. The cases after this block are refused
# by the parameter checks, before the guard, so they run everywhere.
$cliChildrenElevated = $false
if ($env:OS -eq 'Windows_NT') { $cliChildrenElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
if ($cliChildrenElevated) {
    Write-Host 'SKIP: update -Previous CLI child cases that reach the update step (fast-llm.ps1 refuses a live operation under an elevated token; they run under a standard user)'
    $run = Invoke-Cli @('update', '-Previous', '-InstallRoot', $cliRoot)
    # Windows PowerShell 5.1 wraps redirected error text at the buffer width, even inside a word, so this text is compared with all whitespace removed.
    $flat = $run.text -replace '\s', ''
    Check ($run.code -ne 0 -and $flat -like '*mustrunasastandarduser*' -and $flat -notlike '*Reinstallrefused:*') ('cli: under an elevated token, update -Previous is refused by the standard-user guard before any reinstall step (code ' + $run.code + ')')
}
else {
    $run = Invoke-Cli @('update', '-Previous', '-InstallRoot', $cliRoot)
    Check ($run.code -eq 3 -and $run.text -like '*Reinstall refused:*not an installed FastLLM release*') ('cli: update -Previous in an unreleased tree is refused in plain words with a non-zero exit (code ' + $run.code + ')')
    $run = Invoke-Cli @('update', '-Prev', '-InstallRoot', $cliRoot)
    Check ($run.code -eq 3 -and $run.text -like '*Reinstall refused:*') 'cli: the abbreviation -Prev reaches the same refusal'
    $run = Invoke-Cli @('update', '-Previous', '-AsJson', '-InstallRoot', $cliRoot)
    Check ($run.code -eq 3 -and $run.text -match '"reason":\s*"not-a-release"' -and $run.text -match '"status":\s*"refused"') 'cli: -AsJson prints the typed refusal'
}
$run = Invoke-Cli @('update', '-Previous', '-Yes', '-InstallRoot', $cliRoot)
Check ($run.code -ne 0 -and $run.text -like '*cannot be combined with -Yes*' -and $run.text -notlike '*Reinstall refused:*') 'cli: update -Previous -Yes is refused, so the confirmation naming both versions always shows'
$run = Invoke-Cli @('update', '-Previous', '-Unattended', '-Yes', '-InstallRoot', $cliRoot)
Check ($run.code -ne 0 -and $run.text -like '*cannot run with -Unattended*') 'cli: update -Previous is refused with -Unattended, even with -Yes'
$run = Invoke-Cli @('update', '-Previous', '-Unattended', '-InstallRoot', $cliRoot)
Check ($run.code -ne 0 -and $run.text -like '*cannot run with -Unattended*') 'cli: update -Previous -Unattended is refused'
$run = Invoke-Cli @('update', '-Previous', '-Channel', 'stable', '-InstallRoot', $cliRoot)
Check ($run.code -ne 0 -and $run.text -like '*cannot be combined with -Channel*') 'cli: update -Previous is refused with -Channel'
foreach ($otherAction in @('start', 'status', 'update-check', 'models')) {
    $run = Invoke-Cli @($otherAction, '-Previous', '-InstallRoot', $cliRoot)
    Check ($run.code -ne 0 -and $run.text -like '*-Previous is supported only by update*') "cli: -Previous is refused with $otherAction"
}
Remove-Item -LiteralPath $cliRoot -Recurse -Force -ErrorAction SilentlyContinue

# The reinstall code writes no log of its own, so nothing it prints or logs can carry prompts or completions.
$reinstallSource = $updateSource.Substring($reinstallStart)
Check (-not ($reinstallSource -match 'Write-Host|Write-Output|Add-Content|Out-File|Write-Verbose')) 'reinstall: the reinstall code writes no log or console text of its own'

}
finally {
    foreach ($p in @($script:createdTemp)) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
}
$leftTemp = @($script:createdTemp | Where-Object { Test-Path -LiteralPath $_ })
Check ($script:createdTemp.Count -ge 1 -and $leftTemp.Count -eq 0) "update-tests: every temp folder it created is removed ($($script:createdTemp.Count) created)"
Write-Host 'update-tests: PASS'
# The CLI refusal cases leave a child's non-zero exit code in $LASTEXITCODE. CI runs the suites in one session and fails the step
# when the final value is non-zero, so reset it once every check has passed.
$global:LASTEXITCODE = 0
