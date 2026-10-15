#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; Write-Host "PASS: $Message" }
$module = Get-Module FastLlm
function S($gen, $pp, $out = 128) { [pscustomobject]@{ outputTokens = $out; generationTokensPerSecond = $gen; promptTokensPerSecond = $pp; timeToFirstTextMs = 900 } }
$exp = [pscustomobject]@{ generationTokS = 32.7; promptTokS = 654; contextTokens = 32768; engineBuild = 'b10698'; mitigation = 'on' }
$v = & $module { param($s, $e) Get-FastLlmSelfTestVerdict -Samples $s -GenerationTokens 128 -Expected $e -EngineBuild 'b10698' -ContextSize 32768 -MitigationEffective 'on' } @((S 32 650), (S 33 655)) $exp
Check ($v.status -eq 'pass' -and $v.generationTokS -eq 32.5 -and $v.comparable) 'two good samples pass, median of two is their mean'
$v = & $module { param($s, $e) Get-FastLlmSelfTestVerdict -Samples $s -GenerationTokens 128 -Expected $e -EngineBuild 'b10698' -ContextSize 32768 -MitigationEffective 'on' } @((S 20 400), (S 21 410)) $exp
Check ($v.status -eq 'below-expected' -and @($v.reasons) -contains 'resizable-bar') 'under 70 percent of expected warns with likely causes'
$v = & $module { param($s, $e) Get-FastLlmSelfTestVerdict -Samples $s -GenerationTokens 128 -Expected $e -EngineBuild 'b10698' -ContextSize 32768 -MitigationEffective 'off' } @((S 20 400), (S 21 410)) $exp
Check ($v.status -eq 'pass' -and -not $v.comparable) 'a different mitigation state is not compared'
$v = & $module { param($s, $e) Get-FastLlmSelfTestVerdict -Samples $s -GenerationTokens 128 -Expected $e -EngineBuild 'b9999' -ContextSize 32768 -MitigationEffective 'on' } @((S 20 400), (S 21 410)) $exp
Check ($v.status -eq 'pass' -and -not $v.comparable) 'a different engine build is not compared'
$v = & $module { param($s) Get-FastLlmSelfTestVerdict -Samples $s -GenerationTokens 128 -Expected $null -EngineBuild 'b10698' -ContextSize 8192 -MitigationEffective 'off' } @((S 30 500 64), (S 30 500))
Check ($v.status -eq 'fail' -and @($v.reasons) -contains 'incomplete-generation') 'fewer than 128 tokens is a hard fail'
$v = & $module { param($s) Get-FastLlmSelfTestVerdict -Samples $s -GenerationTokens 128 -Expected $null -EngineBuild 'b10698' -ContextSize 8192 -MitigationEffective 'off' } @((S 30 500))
Check ($v.status -eq 'fail') 'one sample is a hard fail'

# Runner with an injected transport: tokenize returns 600 tokens; completions return server timings.
$tokens = @(1..600)
function Stream($predicted) {
    $final = @{ content = ''; stop = $true; timings = @{ prompt_n = 512; prompt_ms = 800.0; predicted_n = $predicted; predicted_ms = 4000.0 } } | ConvertTo-Json -Compress
    [pscustomobject]@{ Status = 200; Events = @('{"content":"x","stop":false}', $final); EventTimesMs = @(900, 4900); ElapsedMs = 4900; Body = '' }
}
$ok = { param($Path, $Body, $TimeoutMs) if ($Path -eq '/tokenize') { [pscustomobject]@{ Status = 200; Body = (@{ tokens = $tokens } | ConvertTo-Json -Compress) } } else { Stream 128 } }
$r = & $module { param($req) Invoke-FastLlmSelfTest -BaseUrl 'http://127.0.0.1:1' -ContextSize 8192 -Expected $null -EngineBuild 'b10698' -MitigationEffective 'off' -Request $req } $ok
Check ($r.status -eq 'pass' -and $r.generationTokS -gt 0) 'the runner measures two runs after a warm-up'
Check (-not ($r | ConvertTo-Json -Depth 6).Contains('"x"')) 'no generated text is kept in the result'
$err = { param($Path, $Body, $TimeoutMs) if ($Path -eq '/tokenize') { [pscustomobject]@{ Status = 200; Body = (@{ tokens = $tokens } | ConvertTo-Json -Compress) } } else { [pscustomobject]@{ Status = 500; Events = @(); EventTimesMs = @(); Body = '' } } }
$r = & $module { param($req) Invoke-FastLlmSelfTest -BaseUrl 'http://127.0.0.1:1' -ContextSize 8192 -Expected $null -EngineBuild 'b10698' -MitigationEffective 'off' -Request $req } $err
Check ($r.status -eq 'fail' -and @($r.reasons) -contains 'request-failed') 'an HTTP 500 is a typed hard fail'
$r = & $module { param($req) Invoke-FastLlmSelfTest -BaseUrl 'http://127.0.0.1:1' -ContextSize 256 -Expected $null -EngineBuild 'b10698' -MitigationEffective 'off' -Request $req } $ok
Check ($r.status -eq 'skipped' -and @($r.reasons) -contains 'context-too-small') 'a context smaller than the workload is skipped, not failed'
$script:requests = 0
$counting = { param($Path, $Body, $TimeoutMs) $script:requests++; if ($Path -eq '/tokenize') { [pscustomobject]@{ Status = 200; Body = (@{ tokens = $tokens } | ConvertTo-Json -Compress) } } else { Stream 128 } }
$r = & $module { param($req) Invoke-FastLlmSelfTest -BaseUrl 'http://127.0.0.1:1' -ContextSize 647 -Expected $null -EngineBuild 'b10698' -MitigationEffective 'off' -Request $req } $counting
Check ($r.status -eq 'skipped' -and $script:requests -eq 0) 'a skipped self-test sends no request (647 is one token under the 648 needed)'
$r = & $module { param($req) Invoke-FastLlmSelfTest -BaseUrl 'http://127.0.0.1:1' -ContextSize 648 -Expected $null -EngineBuild 'b10698' -MitigationEffective 'off' -Request $req } $counting
Check ($r.status -eq 'pass' -and $script:requests -gt 0) 'a context of exactly 648 runs the self-test'
Write-Host 'selftest-tests: PASS'
