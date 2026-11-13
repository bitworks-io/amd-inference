#requires -Version 5.1
# GPU memory (spill) check: detector state machine, texts, self-test marking, benchmark refusal, the exported verdict helper, the
# post-Ready loop schedule and the no-Get-Counter tripwire. The reader is injected, so nothing here needs Windows or a GPU.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force
$module = Get-Module FastLlm
$script:count = 0
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; $script:count++ }
function InModule([scriptblock]$Block, [object[]]$Arguments = @()) { & $module $Block @Arguments }
$MiB = 1048576
$luid = '000000000000c780'
$t0 = New-Object DateTime 2026, 11, 13, 12, 0, 0, ([DateTimeKind]::Utc)
function Sample([double]$SharedMiB, [double]$DedicatedMiB = 9000) { [pscustomobject]@{ SharedBytes = [uint64]($SharedMiB * 1048576); DedicatedBytes = [uint64]($DedicatedMiB * 1048576); Error = $null } }
function FailedSample([string]$Code) { [pscustomobject]@{ SharedBytes = $null; DedicatedBytes = $null; Error = $Code } }

# ---- the floor and the sample-to-state rule ----
Check ((InModule { $script:FastLlmSpillFloorMiB }) -eq 256) 'the floor is the fixed constant 256 MiB'
Check ((InModule { $script:FastLlmSpillCheckIntervalSeconds }) -eq 60) 'the re-check interval is 60 seconds'
$r = InModule { param($s, $n) ConvertTo-FastLlmSpillCheck -Sample $s -Now $n } @((Sample 49.4), $t0)
Check ($r.state -ceq 'ok' -and $r.sharedMiB -eq 49.4 -and $r.dedicatedMiB -eq 9000 -and $r.floorMiB -eq 256 -and $null -eq $r.error -and $r.checkedAtUtc -ceq $t0.ToString('o')) 'a healthy sample is ok with the numbers and the check time'
$r = InModule { param($s, $n) ConvertTo-FastLlmSpillCheck -Sample $s -Now $n } @((Sample 256), $t0)
Check ($r.state -ceq 'ok') 'exactly 256 MiB shared is still ok (the floor is inclusive)'
$r = InModule { param($s, $n) ConvertTo-FastLlmSpillCheck -Sample $s -Now $n } @((Sample 257), $t0)
Check ($r.state -ceq 'spilled') '257 MiB shared is spilled'
$r = InModule { param($n) ConvertTo-FastLlmSpillCheck -Sample ([pscustomobject]@{ SharedBytes = [uint64](256 * 1048576 + 1); DedicatedBytes = [uint64]1; Error = $null }) -Now $n } @($t0)
Check ($r.state -ceq 'spilled') 'one byte over the floor is spilled'
$r = InModule { param($s, $n) ConvertTo-FastLlmSpillCheck -Sample $s -Now $n } @((Sample 1073.4 8285.9), $t0)
Check ($r.state -ceq 'spilled' -and $r.sharedMiB -eq 1073.4 -and $r.dedicatedMiB -eq 8285.9) 'a measured spill keeps both numbers'
$r = InModule { param($s, $n) ConvertTo-FastLlmSpillCheck -Sample $s -Now $n } @((FailedSample 'query-adapter-ntstatus-c0000022'), $t0)
Check ($r.state -ceq 'unknown' -and $r.error -ceq 'query-adapter-ntstatus-c0000022' -and $null -eq $r.sharedMiB -and $null -eq $r.dedicatedMiB) 'a failed read is unknown with its short code and no numbers'
$r = InModule { param($n) ConvertTo-FastLlmSpillCheck -Sample ([pscustomobject]@{ SharedBytes = $null; DedicatedBytes = $null; Error = 'Access is denied for some free text' }) -Now $n } @($t0)
Check ($r.state -ceq 'unknown' -and $r.error -ceq 'read-failed') 'an error that is not a short code is replaced by read-failed, never copied'
$r = InModule { param($n) ConvertTo-FastLlmSpillCheck -Sample ([pscustomobject]@{ SharedBytes = $null; DedicatedBytes = $null; Error = $null }) -Now $n } @($t0)
Check ($r.state -ceq 'unknown' -and $r.error -ceq 'no-data') 'a sample with neither numbers nor an error is unknown, not ok'
$r = InModule { param($n) ConvertTo-FastLlmSpillCheck -Sample $null -Now $n } @($t0)
Check ($r.state -ceq 'unknown') 'no sample at all is unknown'
$names = @($r.PSObject.Properties.Name)
Check (($names -join ',') -ceq 'state,sharedMiB,dedicatedMiB,floorMiB,checkedAtUtc,error') 'the status block has exactly the specified fields in order'

# ---- the reader: no LUID, no process, throwing reader, off Windows ----
$reader = { param($l, $p, $b) [pscustomobject]@{ SharedBytes = [uint64](49 * 1048576); DedicatedBytes = [uint64](9000 * 1048576); Error = $null } }
$self = [Diagnostics.Process]::GetCurrentProcess()
$s = InModule { param($p, $rd) Read-FastLlmSpillSample -Luid $null -Process $p -BudgetMs 200 -Reader $rd } @($self, $reader)
Check ($s.Error -ceq 'no-luid' -and $null -eq $s.SharedBytes) 'no adapter LUID is an unknown sample (no-luid)'
$s = InModule { param($p, $rd) Read-FastLlmSpillSample -Luid 'not-a-luid' -Process $p -BudgetMs 200 -Reader $rd } @($self, $reader)
Check ($s.Error -ceq 'no-luid') 'a malformed LUID is an unknown sample'
$s = InModule { param($l, $rd) Read-FastLlmSpillSample -Luid $l -Process $null -BudgetMs 200 -Reader $rd } @($luid, $reader)
Check ($s.Error -ceq 'no-process') 'no server process is an unknown sample'
$s = InModule { param($l, $p, $rd) Read-FastLlmSpillSample -Luid $l -Process $p -BudgetMs 200 -Reader $rd } @($luid, $self, $reader)
Check ($null -eq $s.Error -and $s.SharedBytes -eq [uint64](49 * 1048576)) 'the injected reader result is passed through'
$s = InModule { param($l, $p) Read-FastLlmSpillSample -Luid $l -Process $p -BudgetMs 200 -Reader { throw 'boom with private text' } } @($luid, $self)
Check ($s.Error -ceq 'read-failed' -and $null -eq $s.SharedBytes) 'a throwing reader never throws out of the check and never leaks its text'
$s = InModule { param($l, $p) Read-FastLlmSpillSample -Luid $l -Process $p -BudgetMs 200 -Reader { param($a, $b, $c) @{ SharedBytes = $null; DedicatedBytes = $null; Error = 'layout-unexpected' } } } @($luid, $self)
Check ($s.Error -ceq 'layout-unexpected') 'a layout failure reported by the reader is carried as its code (unknown)'
if ([Environment]::OSVersion.Platform -ne 'Win32NT') {
    $s = InModule { param($l, $p) Read-FastLlmSpillSample -Luid $l -Process $p -BudgetMs 200 } @($luid, $self)
    Check ($s.Error -ceq 'not-windows' -and $null -eq $s.SharedBytes) 'off Windows the default reader is unknown (not-windows)'
}

# ---- the detector: first event, then changes only; ok -> spilled -> ok; unknown is never ok ----
function Step($prev, $sample, $now) { InModule { param($p, $s, $n) Step-FastLlmSpillCheck -Previous $p -Sample $s -Now $n } @($prev, $sample, $now) }
$a = Step $null (Sample 49.4) $t0
Check ($a.event -ceq 'spill-check' -and $a.spillCheck.state -ceq 'ok' -and $null -eq $a.from) 'the first result is the spill-check event'
$b = Step $a.spillCheck (Sample 50) $t0.AddSeconds(60)
Check ($null -eq $b.event -and $b.spillCheck.state -ceq 'ok' -and $b.spillCheck.sharedMiB -eq 50 -and $b.spillCheck.checkedAtUtc -ceq $t0.AddSeconds(60).ToString('o')) 'an unchanged state logs nothing but refreshes the numbers and time'
$c = Step $b.spillCheck (Sample 1080.1 8279.2) $t0.AddSeconds(120)
Check ($c.event -ceq 'spill-check-changed' -and $c.from -ceq 'ok' -and $c.to -ceq 'spilled' -and $c.spillCheck.state -ceq 'spilled') 'a late spill flips ok to spilled with a spill-check-changed event'
$d = Step $c.spillCheck (Sample 1075 8280) $t0.AddSeconds(180)
Check ($null -eq $d.event -and $d.spillCheck.state -ceq 'spilled') 'staying spilled logs nothing'
$e = Step $d.spillCheck (Sample 49.4) $t0.AddSeconds(240)
Check ($e.event -ceq 'spill-check-changed' -and $e.from -ceq 'spilled' -and $e.to -ceq 'ok') 'a clear flips spilled back to ok'
$f = Step $e.spillCheck (FailedSample 'query-adapter-ntstatus-c0000001') $t0.AddSeconds(300)
Check ($f.event -ceq 'spill-check-changed' -and $f.to -ceq 'unknown' -and $f.spillCheck.state -cne 'ok') 'a failed read after ok is unknown, never ok'
$g = Step $f.spillCheck (FailedSample 'read-timeout') $t0.AddSeconds(360)
Check ($null -eq $g.event -and $g.spillCheck.state -ceq 'unknown') 'staying unknown logs nothing'
$h = Step $c.spillCheck (FailedSample 'read-failed') $t0.AddSeconds(420)
Check ($h.event -ceq 'spill-check-changed' -and $h.from -ceq 'spilled' -and $h.to -ceq 'unknown') 'a failed read while spilled is unknown (the spill is not assumed cleared)'
$u = Step $null (FailedSample 'no-luid') $t0
Check ($u.event -ceq 'spill-check' -and $u.spillCheck.state -ceq 'unknown') 'a first failed read is unknown'
$fields = InModule { param($x) Get-FastLlmSpillCheckEventFields -Step $x } @($a)
Check (($fields.Keys -join ',') -ceq 'state,sharedMiB,dedicatedMiB,floorMiB') 'the first event carries the state and the numbers'
$fields = InModule { param($x) Get-FastLlmSpillCheckEventFields -Step $x } @($c)
Check (($fields.Keys -join ',') -ceq 'from,to,sharedMiB,dedicatedMiB' -and $fields.from -ceq 'ok' -and $fields.to -ceq 'spilled' -and $fields.sharedMiB -eq 1080.1 -and $fields.dedicatedMiB -eq 8279.2) 'the changed event carries from, to and the numbers only'
$allowed = InModule { $script:FastLlmRunLogAllowedFields }
Check (($allowed['spill-check'] -join ',') -ceq 'state,sharedMiB,dedicatedMiB,floorMiB' -and ($allowed['spill-check-changed'] -join ',') -ceq 'from,to,sharedMiB,dedicatedMiB') 'the run-log allowlist has exactly the two spill events with numbers and states only'

# ---- the texts, exactly ----
function Text($state, $shared) { InModule { param($st, $sh) Get-FastLlmSpillCheckText -SpillCheck ([pscustomobject]@{ state = $st; sharedMiB = $sh; dedicatedMiB = $null; floorMiB = 256; checkedAtUtc = $null; error = $null }) } @($state, $shared) }
Check ((Text 'ok' 49.4) -ceq 'GPU memory check: no spill to system memory detected.') 'the ok text'
Check ((Text 'spilled' 1073.4) -ceq "Part of the model's memory spilled to system RAM (about 1.0 GB), probably because another app is using the GPU. Long chats will be slower. Close GPU apps and restart FastLLM.") 'the spilled text with one decimal of GB'
Check ((Text 'spilled' 3072) -ceq "Part of the model's memory spilled to system RAM (about 3.0 GB), probably because another app is using the GPU. Long chats will be slower. Close GPU apps and restart FastLLM.") 'the spilled text for 3 GB'
Check ((Text 'spilled' 1536) -clike '*(about 1.5 GB)*') 'the spilled size is sharedMiB over 1024 with one decimal'
Check ((Text 'unknown' $null) -ceq 'GPU memory check unavailable on this system.') 'the unknown text'
Check ($null -eq (InModule { Get-FastLlmSpillCheckText -SpillCheck $null })) 'no spill check, no text'
foreach ($stateName in 'ok', 'spilled', 'unknown') { Check ((Text $stateName 1100) -cnotmatch 'fully on (the )?GPU|layers') "the $stateName text never claims full residency or mentions layers" }
$readyText = (Get-Content -LiteralPath (Join-Path $root 'src/FastLlm.Runtime.ps1') -Raw)
Check ($readyText.Contains('reported GPU layers passed; physical residency/performance remain unqualified')) 'the existing Ready wording stays'

# ---- the verdict helper (exported) ----
Check ((Get-Command Get-FastLlmSpillCheckVerdict -ErrorAction SilentlyContinue) -and (Get-Module FastLlm).ExportedFunctions.ContainsKey('Get-FastLlmSpillCheckVerdict')) 'Get-FastLlmSpillCheckVerdict is exported'
Check ((Get-FastLlmSpillCheckVerdict -Status ([pscustomobject]@{ spillCheck = [pscustomobject]@{ state = 'ok' } })) -ceq 'ok') 'verdict ok'
Check ((Get-FastLlmSpillCheckVerdict -Status ([pscustomobject]@{ spillCheck = [pscustomobject]@{ state = 'spilled' } })) -ceq 'spilled') 'verdict spilled'
Check ((Get-FastLlmSpillCheckVerdict -Status ([pscustomobject]@{ spillCheck = [pscustomobject]@{ state = 'unknown' } })) -ceq 'unknown') 'verdict unknown'
Check ((Get-FastLlmSpillCheckVerdict -Status ([pscustomobject]@{ phase = 'ready' })) -ceq 'unknown') 'a status without the block (an older server) is unknown, never ok'
Check ((Get-FastLlmSpillCheckVerdict -Status $null) -ceq 'unknown') 'no status is unknown'
Check ((Get-FastLlmSpillCheckVerdict -Status ([pscustomobject]@{ spillCheck = [pscustomobject]@{ state = 'OK' } })) -ceq 'unknown') 'a state that is not exactly ok is unknown'
Check ((Get-FastLlmSpillCheckVerdict -Status ([pscustomobject]@{ spillCheck = [pscustomobject]@{ state = 'fine' } })) -ceq 'unknown') 'an unrecognised state is unknown'
Check ((Get-FastLlmSpillCheckVerdict -Status ([pscustomobject]@{ spillCheck = $null })) -ceq 'unknown') 'a null block is unknown'
Check ((Get-FastLlmSpillCheckVerdict -Status ([ordered]@{ spillCheck = [ordered]@{ state = 'spilled' } })) -ceq 'spilled') 'a dictionary status works as well'
$helperSource = (Get-Content -LiteralPath (Join-Path $root 'src/FastLlm.SpillCheck.ps1') -Raw)
Check ($helperSource -match '(?s)function Get-FastLlmSpillCheckVerdict.{0,1500}' -and $helperSource -match 'ANY point during a (bench )?test run' -and $helperSource -match 'test-validity stop') 'the verdict helper documents that spilled at any point in a test run is a test-validity stop for the caller'

# ---- self-test marking ----
$st = [pscustomobject]@{ status = 'pass'; reasons = @(); generationTokS = 32; promptTokS = 650; firstTextMs = 900; expectedGenerationTokS = 32.7; comparable = $true }
function Mark($selfTest, $state) { InModule { param($x, $sc) Set-FastLlmSelfTestSpillMark -SelfTest $x -SpillCheck $sc } @($selfTest, [pscustomobject]@{ state = $state }) }
Check ((Mark ([pscustomobject]@{ status = 'pass'; comparable = $true }) 'ok').comparable -eq $true) 'an ok state leaves a comparable self-test comparable'
Check ((Mark ([pscustomobject]@{ status = 'pass'; comparable = $true }) 'spilled').comparable -eq $false) 'spilled at Ready marks the self-test comparable=false'
Check ((Mark ([pscustomobject]@{ status = 'pass'; comparable = $true }) 'unknown').comparable -eq $false) 'unknown at Ready marks the self-test comparable=false'
Check ((Mark ([pscustomobject]@{ status = 'pass'; comparable = $false }) 'ok').comparable -eq $false) 'an ok state never turns a not-comparable self-test comparable'
Check ($null -eq (InModule { Set-FastLlmSelfTestSpillMark -SelfTest $null -SpillCheck ([pscustomobject]@{ state = 'spilled' }) })) 'no self-test, nothing to mark'

# ---- the benchmark refuses, and invalidates on a change ----
function BenchAssert($state, [string]$phase = 'start') { try { InModule { param($sc, $p) Assert-FastLlmBenchmarkSpillOk -Status ([pscustomobject]@{ spillCheck = $sc }) -Phase $p } @($state, $phase); return $null } catch { return $_ } }
Check ($null -eq (BenchAssert ([pscustomobject]@{ state = 'ok' }))) 'the benchmark accepts an ok state'
$x = BenchAssert ([pscustomobject]@{ state = 'spilled' })
Check ($x -and [string]$x.Exception.Data['FastLlmBenchmarkFailureCode'] -ceq 'gpu-memory-spill' -or ($x -and $x.Exception.Message -match 'spill')) 'the benchmark refuses a spilled state'
$x2 = BenchAssert ([pscustomobject]@{ state = 'unknown' })
Check ($null -ne $x2) 'the benchmark refuses an unknown state'
$x3 = BenchAssert $null
Check ($null -ne $x3) 'the benchmark refuses a status without the block'
$x4 = BenchAssert ([pscustomobject]@{ state = 'spilled' }) 'run'
Check ($null -ne $x4 -and $x4.Exception.Message -match 'during') 'a change away from ok during the run invalidates the benchmark and says so'
$benchText = Get-Content -LiteralPath (Join-Path $root 'src/FastLlm.Benchmark.ps1') -Raw
$startAt = $benchText.IndexOf('function Invoke-FastLlmBenchmark {')
$benchBody = $benchText.Substring($startAt)
$readyGate = $benchBody.IndexOf("Start a supervised FastLLM server and wait for ready")
$firstAssert = $benchBody.IndexOf("Assert-FastLlmBenchmarkSpillOk -Status `$state -Phase 'start'")
Check ($readyGate -gt 0 -and $firstAssert -gt $readyGate) 'the benchmark checks the spill state at the start, right after the ready gate and before any work'
Check ($benchBody.IndexOf('benchLockPath') -gt $firstAssert) 'the start refusal comes before the benchmark lock is taken'
$timedAt = $benchBody.IndexOf("`$stage='timed'")
$runAsserts = ([regex]::Matches($benchBody.Substring($timedAt), [regex]::Escape("Assert-FastLlmBenchmarkSpillOk -Status `$current -Phase 'run'"))).Count
Check ($runAsserts -ge 2) 'every status read inside and right after the timed region re-checks the spill state'

# ---- the post-Ready loop schedule ----
# A simulated 250 ms loop over a fake clock: the check runs on schedule, not on every pass.
$calls = New-Object 'System.Collections.Generic.List[double]'
$clock = [pscustomobject]@{ now = $t0 }
$countingReader = { param($l, $p, $b) $script:spillReads++; [pscustomobject]@{ SharedBytes = [uint64](49 * 1048576); DedicatedBytes = [uint64](9000 * 1048576); Error = $null } }
$script:spillReads = 0
$prev = $null; $next = $t0.AddSeconds(60)
for ($i = 1; $i -le 520; $i++) {   # 130 simulated seconds
    $now = $t0.AddMilliseconds(250 * $i)
    $tick = InModule { param($pv, $n, $nd, $l, $p, $rd) Invoke-FastLlmSpillCheckTick -Previous $pv -Now $n -NextDueUtc $nd -Luid $l -Process $p -Reader $rd } @($prev, $now, $next, $luid, $self, $countingReader)
    if ($null -ne $tick) { $prev = $tick.spillCheck; $next = $tick.nextDueUtc; $calls.Add(($now - $t0).TotalSeconds) }
}
Check ($calls.Count -eq 2 -and [math]::Abs($calls[0] - 60) -le 0.25 -and [math]::Abs($calls[1] - 120) -le 0.25) 'over 130 s of loop passes the check ran twice, at 60 s and 120 s'
Check ($script:spillReads -eq 2) 'the reader was called only when the check was due'
$notDue = InModule { param($n, $l, $p, $rd) Invoke-FastLlmSpillCheckTick -Previous $null -Now $n -NextDueUtc $n.AddSeconds(1) -Luid $l -Process $p -Reader $rd } @($t0, $luid, $self, $countingReader)
Check ($null -eq $notDue -and $script:spillReads -eq 2) 'a check that is not due does nothing'
$tickOk = InModule { param($n, $l, $p, $rd) Invoke-FastLlmSpillCheckTick -Previous $null -Now $n -NextDueUtc $n -Luid $l -Process $p -Reader $rd } @($t0, $luid, $self, $countingReader)
Check ($tickOk.nextDueUtc -eq $t0.AddSeconds(60)) 'the next check is 60 seconds after this one'
$slowTick = InModule { param($n, $l, $p) Invoke-FastLlmSpillCheckTick -Previous $null -Now $n -NextDueUtc $n -Luid $l -Process $p -Reader { throw 'x' } } @($t0, $luid, $self)
Check ($slowTick.spillCheck.state -ceq 'unknown' -and $slowTick.nextDueUtc -eq $t0.AddSeconds(60)) 'a failing read is unknown and still schedules the next check'

$loopAt = $readyText.IndexOf('while (-not $hostProcess.Process.WaitForExit(250)) {')
$loopEnd = $readyText.IndexOf('$exitCode = $hostProcess.Process.ExitCode', $loopAt)
$loopText = $readyText.Substring($loopAt, $loopEnd - $loopAt)
$stopAt = $loopText.IndexOf('Test-Path -LiteralPath $stopPath')
$tickAt = $loopText.IndexOf('Invoke-FastLlmSpillCheckTick')
Check ($loopAt -gt 0 -and $readyText.IndexOf('WaitForExit(250)') -eq $readyText.LastIndexOf('WaitForExit(250)')) 'the loop keeps its single 250 ms WaitForExit'
Check ($stopAt -ge 0 -and $tickAt -gt $stopAt) 'the stop file is checked before the spill check in every pass'
Check ($loopText.Contains("-Event 'spill-check-changed'") -and $loopText.Contains('Get-FastLlmSpillCheckEventFields')) 'the loop logs spill-check-changed only for a transition'
Check ($loopText -match 'if \(\$null -ne \$spillTick\)') 'the loop does nothing between checks'
Check ((InModule { $script:FastLlmSpillLoopReadBudgetMs }) -le 200 -and (InModule { $script:FastLlmSpillFirstReadBudgetMs }) -le 2000) 'the reads are time-boxed: 200 ms in the loop, at most 2 s for the first'
$nativeSource = Get-Content -LiteralPath (Join-Path $root 'src/WindowsGpuProcessMemory.cs') -Raw
Check ($nativeSource.Contains('ReadWithin(') -and $nativeSource.Contains('Join(timeoutMs)') -and $nativeSource.Contains('IsBackground = true') -and $nativeSource.Contains('"read-timeout"')) 'the helper enforces the time box on a background thread and reports read-timeout'

# ---- the initial check at Ready, wiring ----
Check ($readyText.Contains("-Event 'spill-check'") -and $readyText.Contains('Set-FastLlmSelfTestSpillMark') -and $readyText.Contains('$state.spillCheck')) 'the supervisor records the first check, marks the self-test and puts spillCheck in the state'
$selfTestAt = $readyText.IndexOf('Invoke-FastLlmSelfTest -BaseUrl')
$readyWriteAt = $readyText.IndexOf("`$state.phase='ready'")
$initialAt = $readyText.IndexOf('Invoke-FastLlmSpillCheckAtReady')
Check ($selfTestAt -gt 0 -and $initialAt -gt $selfTestAt -and $initialAt -lt $readyWriteAt) 'the first check runs after the self-test and before the Ready state is written'
Check ($readyText.Contains('Get-FastLlmSpillCheckText')) 'the CLI prints the spill check text after Ready'

# ---- the LUID comes from the product join; unknown when it is not available ----
$luidFromReport = InModule {
    $report = [pscustomobject]@{ devices = @([pscustomobject]@{ index = 0; deviceLuid = '000000000000c780'; deviceLuidValid = $true }, [pscustomobject]@{ index = 1; deviceLuid = '0000000000001111'; deviceLuidValid = $true }) }
    [pscustomobject]@{
        bound = (Get-FastLlmDeviceBindingLuid -Report $report -Resolved ([pscustomobject]@{ status = 'bound'; device = [pscustomobject]@{ rawVulkanIndex = 1 } }))
        notBound = (Get-FastLlmDeviceBindingLuid -Report $report -Resolved ([pscustomobject]@{ status = 'unavailable'; device = $null }))
        badIndex = (Get-FastLlmDeviceBindingLuid -Report $report -Resolved ([pscustomobject]@{ status = 'bound'; device = [pscustomobject]@{ rawVulkanIndex = 7 } }))
    }
}
Check ($luidFromReport.bound -ceq '0000000000001111' -and $null -eq $luidFromReport.notBound -and $null -eq $luidFromReport.badIndex) 'the LUID is the bound device row of the Vulkan to DXGI join report, and absent when the binding is not bound'
$known = InModule { Get-FastLlmSpillCheckLuid -Plan ([pscustomobject]@{ backend = 'vulkan' }) -InstallRoot 'x' -KnownLuid '000000000000AB12' }
Check ($known -ceq '000000000000ab12') 'a LUID the device binding already produced is used as is (lowercase)'
$hip = InModule { Get-FastLlmSpillCheckLuid -Plan ([pscustomobject]@{ backend = 'hip' }) -InstallRoot 'x' -KnownLuid $null }
Check ($null -eq $hip) 'a HIP run has no Vulkan LUID, so the state is unknown'


# ---- the window: status line text (foreground Ready and an attached background run) ----
. (Join-Path $root 'src/FastLlm.UiFlow.ps1')
$okState = [pscustomobject]@{ spillCheck = [pscustomobject]@{ state = 'ok'; sharedMiB = 49.4 } }
$spilledState = [pscustomobject]@{ spillCheck = [pscustomobject]@{ state = 'spilled'; sharedMiB = 1073.4 } }
$unknownState = [pscustomobject]@{ spillCheck = [pscustomobject]@{ state = 'unknown'; sharedMiB = $null } }
Check ((Format-FastLlmUiReadyStatus -State $okState) -ceq 'Ready - API smoke tests passed; GPU residency/performance unqualified. GPU memory check: no spill to system memory detected.') 'the window Ready line adds the ok text and keeps the unqualified wording'
Check ((Format-FastLlmUiReadyStatus -State $spilledState).EndsWith("Part of the model's memory spilled to system RAM (about 1.0 GB), probably because another app is using the GPU. Long chats will be slower. Close GPU apps and restart FastLLM.")) 'the window Ready line adds the spilled text'
Check ((Format-FastLlmUiReadyStatus -State $unknownState) -ceq 'Ready - API smoke tests passed; GPU residency/performance unqualified. GPU memory check unavailable on this system.') 'the window Ready line adds the calm unknown text, in the same plain line'
Check ((Format-FastLlmUiReadyStatus -State ([pscustomobject]@{ phase = 'ready' })) -ceq 'Ready - API smoke tests passed; GPU residency/performance unqualified.') 'a status from an older run adds no spill text'
Check ((Format-FastLlmUiBackgroundReadyStatus -Text 'Ready background inference attached.' -State $spilledState) -clike "Ready background inference attached. Part of the model's memory spilled*") 'an attached background run shows the spill text from its status'
Check ((Format-FastLlmUiBackgroundReadyStatus -Text 'Ready background inference attached.' -State $null) -ceq 'Ready background inference attached.') 'a background run without a status adds nothing'

# ---- no Get-Counter, no admin, no permission changes anywhere in the product ----
$offenders = @()
foreach ($dir in 'src', 'tools') {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root $dir) -File -Recurse | Where-Object { $_.Extension -in '.ps1', '.psm1', '.cs' }) {
        $text = Get-Content -LiteralPath $file.FullName -Raw
        if ($text -match '(?i)Get-Counter') { $offenders += $file.Name }
    }
}
Check ($offenders.Count -eq 0) ('no Get-Counter in src/ or tools/: ' + ($offenders -join ', '))
$ownFiles = @($helperSource, $nativeSource)
foreach ($own in $ownFiles) { Check ($own -cnotmatch '(?i)Start-Process[^\r\n]*-Verb\s+RunAs|icacls|Set-Acl|net\s+localgroup|Performance Monitor Users') 'the spill check files change no permission and ask for no elevation' }

Write-Host "$script:count spill-check checks passed."
