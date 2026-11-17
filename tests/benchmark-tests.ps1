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
# benchmark-refuses-api-key: a run started with the API key on is a user choice, and the benchmark sends no key, so it is never benchmarked.
$keyMessage='Benchmarks measure the default setup. Turn the API key off, start again, then benchmark.'
foreach($keyValue in @('on','ON','yes')){
    $readyKey=[pscustomobject]@{active=$true;phase='ready';thinking='auto';chatPage='off';apiKey=$keyValue;apiKeyId='0123abcd';recipe=[pscustomobject]@{contextSize=32768;requestedArguments=$readyArgs}}
    Check ((Get-ThinkingRefusal $readyKey) -ceq $keyMessage) "benchmark-refuses-api-key: state.apiKey $keyValue throws the exact message"
}
$readyKeyOff=[pscustomobject]@{active=$true;phase='ready';thinking='auto';chatPage='off';apiKey='off';recipe=[pscustomobject]@{contextSize=32768;requestedArguments=$readyArgs}}
Check ($null -eq (Get-ThinkingRefusal $readyKeyOff)) 'benchmark-refuses-api-key: state.apiKey off is accepted (a status without the field is covered above)'
# benchmark-refuses-embeddings: a run with the embedding sidecar on (its status has a sidecars field, whatever the block says) is a user choice that
# adds a second process on the PC, so it is never benchmarked. A status without the field is the default setup and passes (covered above).
$embeddingsMessage='Benchmarks measure the default setup. Turn embeddings off, start again, then benchmark.'
foreach($sidecarBlocks in @(@([pscustomobject]@{role='embedding';phase='ready'}),@([pscustomobject]@{role='embedding';phase='failed';failureCode='embeddings-server-exited'}),@([pscustomobject]@{role='embedding';phase='waiting'}),@())){
    $readyEmbeddings=[pscustomobject]@{active=$true;phase='ready';thinking='auto';chatPage='off';apiKey='off';sidecars=$sidecarBlocks;recipe=[pscustomobject]@{contextSize=32768;requestedArguments=$readyArgs}}
    Check ((Get-ThinkingRefusal $readyEmbeddings) -ceq $embeddingsMessage) "benchmark-refuses-embeddings: a status with a sidecars field ($(@($sidecarBlocks | ForEach-Object { $_.phase }) -join ',')) throws the exact message"
}
$readyNoSidecars=[pscustomobject]@{active=$true;phase='ready';thinking='auto';chatPage='off';apiKey='off';recipe=[pscustomobject]@{contextSize=32768;requestedArguments=$readyArgs}}
Check ($null -eq (Get-ThinkingRefusal $readyNoSidecars)) 'benchmark-refuses-embeddings: a status without a sidecars field is unchanged'
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
# benchmark-refuses-serving-profile: a serving-profile run (opt-in context profile, slots or non-default KV cache) is a user choice, never the default setup.
$profileMessage='Benchmarks measure the default setup. Set the context profile to default and requests at once to 1 (-KvContextProfile default -KvSlots 1), start again, then benchmark.'
$realArgs=@('--model','<verified-model>','--offline','--no-mmproj','--spec-type','none','--alias','qwen-test','--host','127.0.0.1','--port','8080',
    '--cors-origins','localhost','--no-cors-credentials','--ctx-size','32768','--parallel','1','--n-gpu-layers','all','--fit','on','--fit-target','768',
    '--device','Vulkan0','--split-mode','none','--flash-attn','auto','--cache-type-k','f16','--cache-type-v','f16','--jinja','--metrics',
    '--log-verbosity','4','--no-agent','--no-ui')
function New-ProfileStatus([hashtable]$Recipe,[string[]]$ArgumentList=$realArgs){
    $fields=[ordered]@{contextSize=32768;slots=1;requestedArguments=$ArgumentList}
    foreach($key in $Recipe.Keys){$fields[$key]=$Recipe[$key]}
    return [pscustomobject]@{active=$true;phase='ready';thinking='auto';chatPage='off';apiKey='off';idleStopMinutes=0;recipe=[pscustomobject]$fields}
}
function Set-ProfileArgument([string[]]$ArgumentList,[string]$Name,[string]$Value){
    $copy=@($ArgumentList);for($i=0;$i -lt $copy.Count;$i++){if($copy[$i] -ceq $Name){$copy[$i+1]=$Value}};return $copy
}
Check ($null -eq (Get-ThinkingRefusal (New-ProfileStatus @{}))) 'benchmark-refuses-serving-profile: the real default argv (f16 cache types, --parallel 1) is accepted'
Check ($null -eq (Get-ThinkingRefusal $readyOldBoth)) 'benchmark-refuses-serving-profile: a status with none of the fields is unchanged'
$profileCases=[ordered]@{
    'recipe.profile long with one slot'=(New-ProfileStatus @{profile='long'})
    'recipe.profile default with two slots'=(New-ProfileStatus @{profile='default';slots=2;contextPerSlot=16384})
    'recipe.slots 2'=(New-ProfileStatus @{slots=2})
    'contextPerSlot below contextSize'=(New-ProfileStatus @{contextPerSlot=16384})
    '--parallel 2'=(New-ProfileStatus @{} (Set-ProfileArgument $realArgs '--parallel' '2'))
    '--cache-type-k q8_0'=(New-ProfileStatus @{} (Set-ProfileArgument $realArgs '--cache-type-k' 'q8_0'))
    '--cache-type-v q8_0'=(New-ProfileStatus @{} (Set-ProfileArgument $realArgs '--cache-type-v' 'q8_0'))
}
foreach($name in $profileCases.Keys){
    Check ((Get-ThinkingRefusal $profileCases[$name]) -ceq $profileMessage) "benchmark-refuses-serving-profile: $name throws the exact message"
}
$profileThinking=New-ProfileStatus @{slots=2};$profileThinking.thinking='off'
Check ((Get-ThinkingRefusal $profileThinking) -ceq $thinkingMessage) 'benchmark-refuses-serving-profile: the existing Thinking refusal still comes first'
$profileKey=New-ProfileStatus @{slots=2};$profileKey.apiKey='on'
Check ((Get-ThinkingRefusal $profileKey) -ceq $keyMessage) 'benchmark-refuses-serving-profile: the API key refusal still comes first'
$profileAt=$benchSource.IndexOf('$profileRefusal')
$keyAt=$benchSource.IndexOf('$keyRefusal')
$argsAt=$benchSource.IndexOf('$hasNoUi = $false')
Check ($keyAt -gt 0 -and $profileAt -gt $keyAt -and $profileAt -lt $argsAt) 'benchmark-refuses-serving-profile: the check sits as its own line right after the API key refusal'
Check ([regex]::Matches($benchSource,'Test-FastLlmServingProfileRun').Count -eq 1) 'benchmark-refuses-serving-profile: the benchmark calls the one shared predicate'
Write-Host "$count benchmark/build checks passed. No GPU benchmark executed."
