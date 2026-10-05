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
Write-Host "$count benchmark/build checks passed. No GPU benchmark executed."
