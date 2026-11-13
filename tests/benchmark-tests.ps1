#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
Import-Module (Join-Path $PSScriptRoot '../src/FastLlm.psm1') -Force
$module=Get-Module FastLlm
$count=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:count++;Write-Host "PASS: $Message"}
$odd=& $module { Get-FastLlmStatistics @(30,10,20) }
Check ($odd.median -eq 20 -and $odd.p95 -eq 30 -and $odd.p95Caution) 'statistics sort samples and flag small-sample p95'
$even=& $module { Get-FastLlmStatistics @(40,10,30,20) }
Check ($even.median -eq 25) 'even sample median uses both middle values'
$bad=$false;try{& $module {Get-FastLlmStatistics @([double]::NaN)}}catch{$bad=$true}
Check $bad 'non-finite benchmark data is rejected'
$promptHash=& $module { Get-FastLlmPromptArtifactSha256 @(1,42,123456) }
Check ($promptHash -eq '9e5a96a15b8792d68233beccd3de9d0d07aaac8e5725f29058ea4d64ca270436') 'prompt token IDs hash to the canonical ASCII vector'
Check ((& $module { Get-FastLlmPromptArtifactSha256 @(1,42) }) -ne $promptHash) 'prompt length changes prompt artifact identity'
$bad=$false;try{& $module {Get-FastLlmPromptArtifactSha256 @(-1,42)}}catch{$bad=$true}
Check $bad 'negative token IDs cannot become prompt evidence'
$bad=$false;try{& $module {Get-FastLlmPromptArtifactSha256 @('1.5',42)}}catch{$bad=$true}
Check $bad 'fractional token IDs cannot become prompt evidence'
$bad=$false;try{& $module {Get-FastLlmPromptArtifactSha256 @([double]1,42)}}catch{$bad=$true}
Check $bad 'floating token IDs cannot be silently coerced into integers'
$response=[pscustomobject]@{Status=200;Events=@('{"content":"","stop":false}','{"content":"Hello","stop":false}','{"content":"","stop":true,"timings":{"prompt_n":512,"prompt_ms":1000,"predicted_n":128,"predicted_ms":4000}}');EventTimesMs=@(10,50,5000);ElapsedMs=5010}
$result=& $module {param($R) ConvertFrom-FastLlmBenchmarkResponse $R 128} $response
Check ($result.generationTokensPerSecond -eq 32 -and $result.promptTokensPerSecond -eq 512) 'rates derive from actual token counts and measured durations'
Check ($result.timeToFirstTextMs -eq 50) 'empty stream events do not count as first text'
Check (-not ($result|ConvertTo-Json).Contains('Hello')) 'result contains no generated text'
$bad=$false;try{& $module {param($R) ConvertFrom-FastLlmBenchmarkResponse $R 127} $response}catch{$bad=$true}
Check $bad 'early or extra generation is not a comparable sample'
$response.Events=@('{"content":"Hello","stop":false}','{"stop":true,"timings":{"prompt_n":512.5,"prompt_ms":1000,"predicted_n":128,"predicted_ms":4000}}')
$response.EventTimesMs=@(50,5000)
$bad=$false;try{& $module {param($R) ConvertFrom-FastLlmBenchmarkResponse $R 128} $response}catch{$bad=$true}
Check $bad 'fractional evaluated prompt count cannot be truncated into evidence'
$response.Events=@('{"content":"Hello","stop":false}','{"stop":true,"timings":{"prompt_n":512,"prompt_ms":1000,"predicted_n":128.5,"predicted_ms":4000}}')
$bad=$false;try{& $module {param($R) ConvertFrom-FastLlmBenchmarkResponse $R 128} $response}catch{$bad=$true}
Check $bad 'fractional generated token count cannot be truncated into evidence'
$response.Events=@('{"content":"Hello","stop":false}','{"stop":true,"timings":{"prompt_n":512,"prompt_ms":1000,"predicted_n":128,"predicted_ms":4000}}','{"stop":true,"timings":{"prompt_n":512,"prompt_ms":1000,"predicted_n":128,"predicted_ms":4000}}')
$response.EventTimesMs=@(50,5000,5001)
$bad=$false;try{& $module {param($R) ConvertFrom-FastLlmBenchmarkResponse $R 128} $response}catch{$bad=$true}
Check $bad 'duplicate final timing events cannot become a last-wins sample'
$response.Events=@('{"content":"Hello","stop":false}','{"stop":"false","timings":{"prompt_n":512,"prompt_ms":1000,"predicted_n":128,"predicted_ms":4000}}')
$response.EventTimesMs=@(50,5000)
$bad=$false;try{& $module {param($R) ConvertFrom-FastLlmBenchmarkResponse $R 128} $response}catch{$bad=$true}
Check $bad 'string stop=false cannot be treated as a truthy final stop'
$response.Events=@('{"content":"Hello","stop":false}','{"stop":true,"timings":{"prompt_n":512,"prompt_ms":"1000","predicted_n":128,"predicted_ms":4000}}')
$bad=$false;try{& $module {param($R) ConvertFrom-FastLlmBenchmarkResponse $R 128} $response}catch{$bad=$true}
Check $bad 'string-valued duration cannot be coerced into a rate'
$response.Events=@('{"content":"Hello","stop":false}','{"stop":true,"timings":{"prompt_n":512,"prompt_ms":1000,"predicted_n":128,"predicted_ms":1e999}}')
$bad=$false;try{& $module {param($R) ConvertFrom-FastLlmBenchmarkResponse $R 128} $response}catch{$bad=$true}
Check $bad 'non-finite or unparseable raw duration cannot become zero finite TPS'
$response.Events=@('{"content":"Hello","stop":false}','{"stop":true,"timings":{"prompt_n":512,"prompt_ms":1000,"predicted_n":128,"predicted_ms":4000}}')
$response.EventTimesMs=@(50)
$bad=$false;try{& $module {param($R) ConvertFrom-FastLlmBenchmarkResponse $R 128} $response}catch{$bad=$true}
Check $bad 'missing event timestamp cannot enter benchmark evidence'
$response.EventTimesMs=@(50,5000);$response.ElapsedMs=100
$bad=$false;try{& $module {param($R) ConvertFrom-FastLlmBenchmarkResponse $R 128} $response}catch{$bad=$true}
Check $bad 'first/final event times cannot exceed completion elapsed time'
$response.ElapsedMs=5010
$response.Events=@('{"content":"Hello","stop":false}')
$bad=$false;try{& $module {param($R) ConvertFrom-FastLlmBenchmarkResponse $R 128} $response}catch{$bad=$true}
Check $bad 'truncated streaming responses cannot become results'
foreach($file in Get-ChildItem (Split-Path $PSScriptRoot -Parent) -Recurse -Include *.ps1,*.psm1){
    $tokens=$null;$errors=$null
    [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)|Out-Null
    Check ($errors.Count -eq 0) "PowerShell syntax: $($file.Name)"
}
Add-Type -Path (Join-Path $PSScriptRoot '../src/WindowsInventory.cs')
Check $true 'Windows DXGI inventory helper compiles (native calls require Windows)'
Add-Type -Path (Join-Path $PSScriptRoot '../src/WindowsGpuIdentity.cs')
Check $true 'Windows SetupAPI identity helper compiles (native calls require Windows)'
Add-Type -Path (Join-Path $PSScriptRoot '../src/WindowsHostInventory.cs')
Check $true 'Windows standard-user host inventory helper compiles (native calls require Windows)'
# benchmark-refuses-thinking-off: a Thinking setting is a user choice and is never scored as the recipe configuration.
$thinkingMessage='Benchmarks measure the default setup. Set Thinking to Auto, start again, then benchmark.'
function Get-ThinkingRefusal($State){
    $text=$null
    try{& $module {param($S) Assert-FastLlmBenchmarkDefaultSetup -State $S} $State}catch{$text=[string]$_.Exception.Message}
    return $text
}
$readyArgs=@('--model','<verified-model>','--port','8080','--no-ui')
$readyAuto=[pscustomobject]@{active=$true;phase='ready';thinking='auto';recipe=[pscustomobject]@{contextSize=32768;requestedArguments=$readyArgs}}
$readyOff=[pscustomobject]@{active=$true;phase='ready';thinking='off';recipe=[pscustomobject]@{contextSize=32768;requestedArguments=$readyArgs}}
$readyFlag=[pscustomobject]@{active=$true;phase='ready';thinking='auto';recipe=[pscustomobject]@{contextSize=32768;requestedArguments=($readyArgs+@('--reasoning','off'))}}
Check ($null -eq (Get-ThinkingRefusal $readyAuto)) 'benchmark-refuses-thinking-off: an auto ready state is accepted'
Check ((Get-ThinkingRefusal $readyOff) -ceq $thinkingMessage) 'benchmark-refuses-thinking-off: state.thinking off throws the exact message'
Check ((Get-ThinkingRefusal $readyFlag) -ceq $thinkingMessage) 'benchmark-refuses-thinking-off: a --reasoning argument throws the exact message'
$readyFlagEq=[pscustomobject]@{active=$true;phase='ready';thinking='auto';recipe=[pscustomobject]@{contextSize=32768;requestedArguments=($readyArgs+@('--reasoning=off'))}}
Check ((Get-ThinkingRefusal $readyFlagEq) -ceq $thinkingMessage) 'benchmark-refuses-thinking-off: --reasoning=off is refused as well'
# old-status-without-thinking (R1): a state written before the field existed passes under StrictMode 2 with no exception.
$readyOld=[pscustomobject]@{active=$true;phase='ready';recipe=[pscustomobject]@{contextSize=32768;requestedArguments=$readyArgs}}
Check ($null -eq (Get-ThinkingRefusal $readyOld)) 'old-status-without-thinking: a ready state with no thinking field passes the check with no exception'
$readyOldNoArgs=[pscustomobject]@{active=$true;phase='ready';recipe=[pscustomobject]@{contextSize=32768}}
Check ($null -eq (Get-ThinkingRefusal $readyOldNoArgs)) 'old-status-without-thinking: a recipe with no requestedArguments passes too'
# benchmark-refuses-chat-page: a run started with the local chat page on is never benchmarked.
$chatMessage='Benchmarks measure the default setup. Turn the local chat page off, start again, then benchmark.'
$readyChatOff=[pscustomobject]@{active=$true;phase='ready';thinking='auto';chatPage='off';recipe=[pscustomobject]@{contextSize=32768;requestedArguments=$readyArgs}}
$readyChatOn=[pscustomobject]@{active=$true;phase='ready';thinking='auto';chatPage='on';recipe=[pscustomobject]@{contextSize=32768;requestedArguments=$readyArgs}}
$readyNoUiGone=[pscustomobject]@{active=$true;phase='ready';thinking='auto';chatPage='off';recipe=[pscustomobject]@{contextSize=32768;requestedArguments=@('--model','<verified-model>','--port','8080','--no-agent')}}
Check ($null -eq (Get-ThinkingRefusal $readyChatOff)) 'benchmark-refuses-chat-page: an off ready state is accepted'
Check ((Get-ThinkingRefusal $readyChatOn) -ceq $chatMessage) 'benchmark-refuses-chat-page: state.chatPage on throws the exact message'
Check ((Get-ThinkingRefusal $readyNoUiGone) -ceq $chatMessage) 'benchmark-refuses-chat-page: requestedArguments without --no-ui throws the exact message'
# old-status-without-new-fields (R1): a status from the 4 GB release has no thinking and no chatPage field; the check passes with no StrictMode exception.
$readyOldBoth=[pscustomobject]@{active=$true;phase='ready';recipe=[pscustomobject]@{contextSize=32768;requestedArguments=$readyArgs}}
Check ($null -eq (Get-ThinkingRefusal $readyOldBoth)) 'old-status-without-new-fields: a ready state with no thinking or chatPage field passes the check'
# benchmark-refuses-idle-stop: a run started with the idle stop on may stop itself mid-measurement, so it is never benchmarked.
$idleMessage='Benchmarks measure the default setup. Set Stop the model when idle to Never, start again, then benchmark.'
foreach($idleMinutes in 15,30,60){
    $readyIdle=[pscustomobject]@{active=$true;phase='ready';thinking='auto';chatPage='off';idleStopMinutes=$idleMinutes;recipe=[pscustomobject]@{contextSize=32768;requestedArguments=$readyArgs}}
    Check ((Get-ThinkingRefusal $readyIdle) -ceq $idleMessage) "benchmark-refuses-idle-stop: state.idleStopMinutes $idleMinutes throws the exact message"
}
$readyIdleNever=[pscustomobject]@{active=$true;phase='ready';thinking='auto';chatPage='off';idleStopMinutes=0;recipe=[pscustomobject]@{contextSize=32768;requestedArguments=$readyArgs}}
Check ($null -eq (Get-ThinkingRefusal $readyIdleNever)) 'benchmark-refuses-idle-stop: an idle stop of 0 is accepted'
Check ($null -eq (Get-ThinkingRefusal $readyChatOff)) 'old-status-without-new-fields: a ready state with no idleStopMinutes field passes the idle check'
$readyIdleThinking=[pscustomobject]@{active=$true;phase='ready';thinking='off';chatPage='off';idleStopMinutes=30;recipe=[pscustomobject]@{contextSize=32768;requestedArguments=$readyArgs}}
Check ((Get-ThinkingRefusal $readyIdleThinking) -ceq $thinkingMessage) 'benchmark-refuses-idle-stop: the existing Thinking refusal still comes first'
# The refusal runs inside Invoke-FastLlmBenchmark right after the ready check and before the context budget, the lock and every request.
$benchSource=Get-Content -LiteralPath (Join-Path $PSScriptRoot '../src/FastLlm.Benchmark.ps1') -Raw
$readyAt=$benchSource.IndexOf("throw 'Start a supervised FastLLM server and wait for ready before benchmarking.'")
$assertAt=$benchSource.IndexOf('Assert-FastLlmBenchmarkDefaultSetup -State $state',$readyAt)
$lockAt=$benchSource.IndexOf("'benchmark.lock'",$readyAt)
Check ($readyAt -gt 0 -and $assertAt -gt $readyAt -and $assertAt -lt $lockAt) 'benchmark-refuses-thinking-off: the check sits between the ready check and the benchmark lock, before any request'
Write-Host "$count benchmark/build checks passed. No GPU benchmark executed."
