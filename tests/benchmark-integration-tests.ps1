#requires -Version 5.1
param([switch]$Worker,[ValidateSet('success','change-run','invalid-token','fractional-prompt','fractional-predicted','duplicate-final','mixed-evaluated','string-stop','string-duration')][string]$CaseName='success',[string]$FixtureRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2

if ($env:OS -ne 'Windows_NT') {
    Write-Host 'SKIP: native-Windows-only benchmark HTTP integration; no physical benchmark executed.'
    exit 0
}
$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run benchmark integration tests as a standard Windows user; the production guard remains enabled.'
}
if (-not ('Bitworks.FastLlm.ProcessHost' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot '../src/ProcessHost.cs') }

function Assert-Test([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; Write-Host "PASS: $Message" }
function Invoke-TestChild([string]$Script,[string]$Arguments) {
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=(Get-Process -Id $PID).Path
    $source="& '$($Script.Replace("'","''"))' $Arguments"
    $info.Arguments='-NoLogo -NoProfile -NonInteractive -OutputFormat Text -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($source))
    $info.UseShellExecute=$false
    $child=New-Object Bitworks.FastLlm.ProcessHost
    $child.Start($info)
    return $child
}
function Get-TestHash([int[]]$Ids) {
    $canonical="fastllm-prompt-tokens-v1`n$($Ids.Count)`n"+(($Ids | ForEach-Object {"$_`n"}) -join '')
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($canonical)))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

if (-not $Worker) {
    $FixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('fastllm-benchmark-http-'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $FixtureRoot -Force|Out-Null
    try {
        foreach ($case in @('success','change-run','invalid-token','fractional-prompt','fractional-predicted','duplicate-final','mixed-evaluated','string-stop','string-duration')) {
            $childArguments="-Worker -CaseName '$case' -FixtureRoot '$($FixtureRoot.Replace("'","''"))'"
            $process=Invoke-TestChild $PSCommandPath $childArguments
            try {
                if (-not $process.Process.WaitForExit(60000)) { throw "FAIL: $case integration exceeded 60 seconds." }
                # Exit code is authoritative. Do not wait indefinitely for async
                # output callbacks after the bounded process-exit deadline.
                Write-Host $process.Snapshot()
                Assert-Test ($process.Process.ExitCode -eq 0) "$case integration worker completed"
            } finally { $process.Dispose() }
        }
        Write-Host 'Native Windows mock HTTP benchmark integration passed. Synthetic fixture only; no GPU benchmark executed.'
    } finally {
        Remove-Item -LiteralPath $FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    exit 0
}

$repo=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/FastLlm.psm1') -Force
& (Get-Module FastLlm) { Initialize-FastLlmProcessHost }
$caseRoot=Join-Path $FixtureRoot $CaseName
New-Item -ItemType Directory -Path $caseRoot -Force|Out-Null
$listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
$listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
$logPath=Join-Path $caseRoot 'requests.txt'
$reportPath=Join-Path $caseRoot 'report.json'
$installRoot=Join-Path $caseRoot 'install'
$runId='a'*32
$statePath=Join-Path $installRoot 'state/status.json'
$fixture=Join-Path $PSScriptRoot 'helpers/mock-benchmark-server.ps1'
$childArguments="-Port $port -Mode '$CaseName' -LogPath '$($logPath.Replace("'","''"))' -StatusPath '$($statePath.Replace("'","''"))' -OriginalRunId '$runId'"
$server=Invoke-TestChild $fixture $childArguments
$lock=$null
try {
    $ready=$false
    for ($i=0;$i -lt 100;$i++) {
        if ($server.Process.HasExited) { throw "Mock HTTP server exited before readiness: $($server.Snapshot())" }
        try { $health=[Bitworks.FastLlm.LoopbackHttp]::Request("http://127.0.0.1:$port/health",$null,200,1024); if ($health.Status -eq 200) { $ready=$true; break } } catch {}
        Start-Sleep -Milliseconds 100
    }
    Assert-Test $ready 'mock server ready within 10 seconds'
    $lock=Enter-FastLlmOperation $installRoot
    $state=@{
        schemaVersion=1;runId=$runId;phase='ready';endpoint="http://127.0.0.1:$port/v1"
        modelId='synthetic-mock-only';modelSha256=('0'*64);engineVersion='mock-only'
        recipe=@{contextSize=256;backend='mock';requestedArguments=@('mock-argument')}
        canary=@{mockOnly=$true};placement=@{mockOnly=$true}
    }
    Write-FastLlmState -InstallRoot $installRoot -State $state
    $errorText=$null
    try { Invoke-FastLlmBenchmark -InstallRoot $installRoot -OutputPath $reportPath -PromptTokens @(16,32) -GenerationTokens 8 -Repetitions 5 | Out-Null }
    catch { $errorText=$_.Exception.Message }
    if ($CaseName -eq 'success') {
        Assert-Test (-not $errorText) "report completed: $errorText"
        Assert-Test (Test-Path -LiteralPath $reportPath -PathType Leaf) 'report written exactly once'
        $report=Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
        $raw=Get-Content -LiteralPath $reportPath -Raw
        Assert-Test ($report.schemaVersion -eq 1 -and $report.resultKind -eq 'native-windows-api-benchmark-not-full-qualification' -and -not $report.qualification.approved) 'report remains unqualified native benchmark v1'
        Assert-Test ($report.samples.Count -eq 10 -and $report.summary.Count -eq 2) 'warmups discarded, five repetitions retained per prompt'
        Assert-Test ($raw -notmatch 'synthetic-completion-text-SECRET|A local inference system|"prompt"\s*:|"content"\s*:|"tokens"\s*:') 'report excludes prompt/completion text and token arrays'
        $requests=@(Get-Content -LiteralPath $logPath)
        Assert-Test ($requests.Count -eq 13 -and @($requests|Where-Object {$_ -eq 'TOKENIZE'}).Count -eq 1) 'one tokenize call plus all warmup and repetition completions reached HTTP fixture'
        foreach ($n in @(16,32)) {
            $expected=@(1..$n)
            $digest=Get-TestHash $expected
            $group=@($report.samples|Where-Object requestedPromptTokens -eq $n)
            $artifact=@($report.methodology.promptArtifacts|Where-Object requestedPromptTokens -eq $n)
            $hits=@($requests|Where-Object {$_ -eq ($n.ToString()+':'+($expected -join ','))})
            Assert-Test ($hits.Count -eq 6 -and $group.Count -eq 5 -and $artifact.Count -eq 1) "prompt $n uses identical numeric arrays in warmup and repetitions"
            Assert-Test ($artifact[0].sha256 -eq $digest -and $artifact[0].tokenCount -eq $n -and @($group|Where-Object { $_.promptArtifactSha256 -ne $digest -or $_.promptTokens -ne $n -or $_.outputTokens -ne 8 }).Count -eq 0) "prompt $n digest binds report samples and fixed response counts"
        }
    } else {
        $expected=switch($CaseName){
            'change-run' {'Server identity changed during benchmark'}
            'invalid-token' {'invalid token ID'}
            'fractional-prompt' {'positive exact integers'}
            'fractional-predicted' {'positive exact integers'}
            'duplicate-final' {'exactly one final stop'}
            'mixed-evaluated' {'Warmup and measured runs evaluated different prompt counts'}
            'string-stop' {'stop flags must be JSON booleans'}
            'string-duration' {'durations must be finite positive numbers'}
        }
        Assert-Test ($errorText -match $expected) "$CaseName rejected: $errorText"
        Assert-Test (-not (Test-Path -LiteralPath $reportPath)) "$CaseName cannot write a report"
        $requests=@(Get-Content -LiteralPath $logPath)
        if ($CaseName -eq 'invalid-token') { Assert-Test ($requests.Count -eq 1 -and $requests[0] -eq 'TOKENIZE') 'invalid token IDs stop before completion requests' }
        elseif ($CaseName -eq 'mixed-evaluated') { Assert-Test (@($requests|Where-Object {$_ -ne 'TOKENIZE'}).Count -ge 2) 'mixed evaluated count is rejected after warmup and a repeated prompt' }
        else { Assert-Test (@($requests|Where-Object {$_ -ne 'TOKENIZE'}).Count -eq 1) "$CaseName stops after the first completion" }
    }
} finally {
    if ($lock) { $lock.Dispose() }
    $server.Dispose()
}
