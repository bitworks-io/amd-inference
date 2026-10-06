#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
. (Join-Path $PSScriptRoot '../src/FastLlm.TaskWorkload.ps1')
$script:checks=0
function Check([bool]$condition,[string]$label){
    if(-not $condition){throw "FAIL: $label"}
    $script:checks++
}
function Check-Throws([scriptblock]$action,[string]$label){
    $threw=$false
    try { & $action | Out-Null } catch { $threw=$true }
    Check $threw $label
}
function Grade($case,[string]$answer){Test-FastLlmTaskWorkloadAnswer -Case $case -Content $answer}

$zero=@(Get-FastLlmTaskWorkloadCases -DistractorCount 0)
$medium=@(Get-FastLlmTaskWorkloadCases -DistractorCount 32)
$long=@(Get-FastLlmTaskWorkloadCases -DistractorCount 128)
$again=@(Get-FastLlmTaskWorkloadCases -DistractorCount 128)
Check ($zero.Count -eq 8 -and $medium.Count -eq 8 -and $long.Count -eq 8) 'eight tasks at all contexts'
Check (@($zero.id | Select-Object -Unique).Count -eq 8) 'independent stable IDs'
Check (([string]::Join('|',[string[]]$zero.id)) -ceq ([string]::Join('|',[string[]]$long.id))) 'same tasks at every context'
Check (([string]::Join('|',[string[]]$zero.expected)) -ceq ([string]::Join('|',[string[]]$long.expected))) 'same references at every context'
Check (([string]::Join('|',[string[]]$long.prompt)) -ceq ([string]::Join('|',[string[]]$again.prompt))) 'deterministic long prompts'
Check ((Get-FastLlmTaskWorkloadSuiteVersion) -ceq 'task-quality-v1') 'explicit suite version'
Check-Throws {Get-FastLlmTaskWorkloadCases -DistractorCount 31} 'count allowlist'

for($index=0;$index -lt 8;$index++){
    $case=$zero[$index]
    Check ($case.suiteVersion -ceq 'task-quality-v1' -and $case.distractorCount -eq 0) "case identity $index"
    Check ($case.gradingNormalization -ceq 'trim-leading-trailing-whitespace-only') "normalization declared $index"
    Check ($case.maxOutputTokens -gt 0 -and $case.maxOutputTokens -le 128) "bounded output $index"
    Check ((Get-FastLlmTaskWorkloadPromptSha256 -Case $case) -cmatch '^[0-9a-f]{64}$') "prompt hash format $index"
    Check ((Get-FastLlmTaskWorkloadReferenceSha256 -Case $case) -cmatch '^[0-9a-f]{64}$') "reference hash format $index"
    Check ((Get-FastLlmTaskWorkloadReferenceSha256 -Case $case) -ceq
           (Get-FastLlmTaskWorkloadReferenceSha256 -Case $long[$index])) "stable reference $index"
    Check ((Get-FastLlmTaskWorkloadPromptSha256 -Case $case) -cne
           (Get-FastLlmTaskWorkloadPromptSha256 -Case $long[$index])) "distinct context prompt $index"
    $good=Grade $case ("`n"+$case.expected+"`n")
    Check ($good.passed -is [bool] -and $good.passed -and $good.errorCode -ceq 'OK' -and
           $good.classification -ceq 'strict-pass') "strict reference pass $index"
    Check ((Grade $case ($case.expected+' extra')).passed -eq $false) "extra text rejected $index"
}
Check ($zero[0].responseFormat.type -ceq 'json_object' -and
       $zero[0].responseFormat.schema.type -ceq 'object' -and
       $zero[0].responseFormat.schema.additionalProperties -eq $false) 'explicit JSON schema'
Check (([string]::Join(',', [string[]]$zero[0].responseFormat.schema.required)) -ceq 'orderId,units,rush') 'schema exact required keys'
Check (@($zero | Where-Object {$null -ne $_.responseFormat}).Count -eq 1) 'only structured case requests JSON mode'
Check ($long[6].targetPosition -ceq 'head' -and $long[7].targetPosition -ceq 'tail') 'retrieval positions declared'
Check ($long[6].prompt.IndexOf('MARIGOLD-47',[StringComparison]::Ordinal) -lt
       $long[6].prompt.IndexOf('Irrelevant archive note 001',[StringComparison]::Ordinal)) 'head target precedes distractors'
Check ($long[7].prompt.IndexOf('CYAN-812',[StringComparison]::Ordinal) -gt
       $long[7].prompt.IndexOf('Irrelevant archive note 128',[StringComparison]::Ordinal)) 'tail target follows distractors'
Check (@([regex]::Matches($long[6].prompt,'Irrelevant archive note [0-9]{3}')).Count -eq 128) 'exact 128 distractors'
Check (@([regex]::Matches($medium[7].prompt,'Irrelevant archive note [0-9]{3}')).Count -eq 32) 'exact 32 distractors'

$json=$zero[0]
Check ((Grade $json '{ "rush": true, "units": 7, "orderId": "BX-204" }').passed) 'JSON key order irrelevant'
$jsonFailures=@(
    @('{"orderId":"BX-204","units":7,"rush":true,"rush":false}','DUPLICATE_JSON_KEY'),
    @('{"orderId":"BX-204","units":7,"rush":true,"order\u0049d":"BX-204"}','DUPLICATE_JSON_KEY'),
    @('{"orderId":"BX-204","units":7,"rush":true,"extra":0}','EXTRA_JSON_KEY'),
    @('{"orderId":"BX-204","units":7}','MISSING_JSON_KEY'),
    @('{"orderId":"BX-204","units":"7","rush":true}','WRONG_JSON_TYPE'),
    @('{"orderId":"BX-204","units":7,"rush":"true"}','WRONG_JSON_TYPE'),
    @('{"orderId":"BX-204","units":8,"rush":true}','WRONG_VALUE'),
    @('{"orderId":"BX-204","units":7,"rush":false}','WRONG_VALUE'),
    @('{"orderId":"BX-204","units":7,"rush":true,}','MALFORMED_JSON'),
    @('{"orderId":"BX-204","units":7,"rush":true} trailing','MALFORMED_JSON'),
    @('{"orderId":"BX-204","units":7,"rush":tru}','MALFORMED_JSON'),
    @('{"orderId":"BX-204","units":7,"rush":true,"nested":{}}','MALFORMED_JSON'),
    @('[{"orderId":"BX-204","units":7,"rush":true}]','MALFORMED_JSON')
)
foreach($failure in $jsonFailures){
    $actual=Grade $json $failure[0]
    Check (-not $actual.passed -and $actual.errorCode -ceq $failure[1]) "JSON rejection $($failure[1])"
}
$fenced=('```json'+"`n"+$json.expected+"`n"+'```')
$fencedResult=Grade $json $fenced
Check (-not $fencedResult.passed -and $fencedResult.errorCode -ceq 'FENCED_JSON' -and
       $fencedResult.classification -ceq 'fenced-valid-json') 'valid fenced JSON distinct but failed'
Check ((Grade $json ('```json'+"`n"+'{bad}'+"`n"+'```')).errorCode -ceq 'FENCED_OUTPUT') 'invalid fenced JSON failed'
Check ((Grade $zero[1] ('```text'+"`n"+'K2,K4'+"`n"+'```')).errorCode -ceq 'FENCED_OUTPUT') 'text fence rejected'
Check ((Grade $zero[3] '63').errorCode -ceq 'WRONG_ANSWER') 'wrong arithmetic rejected'
Check ((Grade $zero[4] '869').errorCode -ceq 'WRONG_ANSWER') 'cross-task arithmetic rejected'
Check ((Grade $zero[6] 'CYAN-812').errorCode -ceq 'WRONG_ANSWER') 'cross-task retrieval rejected'
Check ((Grade $zero[5] 'serve>verify>fetch>plan').errorCode -ceq 'WRONG_ANSWER') 'dependency order enforced'
Check ((Grade $zero[1] ' K2,K4 ').passed) 'outer whitespace only'
Check ((Grade $zero[1] 'K2, K4').errorCode -ceq 'WRONG_ANSWER') 'interior whitespace not repaired'
Check ((Grade $zero[1] '').errorCode -ceq 'EMPTY') 'empty classified'

$tampered=$zero[1].PSObject.Copy()
$tampered.expected='K1'
Check-Throws {Grade $tampered 'K1'} 'reference tamper rejected'
$tampered=$zero[0].PSObject.Copy()
$tampered.kind='filter'
Check-Throws {Grade $tampered $tampered.expected} 'grader-kind tamper rejected'
$tampered=$zero[0].PSObject.Copy()
$tampered.prompt='changed'
Check-Throws {Grade $tampered $tampered.expected} 'prompt tamper rejected'
$tampered=$zero[0].PSObject.Copy()
$tampered.responseFormat=$null
Check-Throws {Grade $tampered $tampered.expected} 'schema tamper rejected'
$tampered=$zero[0].PSObject.Copy()
$tampered.gradingNormalization='none'
Check-Throws {Grade $tampered $tampered.expected} 'normalization tamper rejected'
$tampered=$zero[0].PSObject.Copy()
$tampered.id='unknown'
Check-Throws {Grade $tampered $tampered.expected} 'unknown case rejected'

Write-Output "$script:checks passed"
