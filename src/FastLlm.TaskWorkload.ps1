#requires -Version 5.1
# Private, hand-authored task-quality screen. No model output is ever executed.

function Get-FastLlmTaskWorkloadSuiteVersion { 'task-quality-v1' }

function Get-FastLlmTaskWorkloadSha256 {
    param([Parameter(Mandatory=$true)][string]$Text)
    $hasher=[Security.Cryptography.SHA256]::Create()
    try {
        $bytes=[Text.Encoding]::UTF8.GetBytes($Text)
        $digest=$hasher.ComputeHash($bytes)
        return ([BitConverter]::ToString($digest)).Replace('-','').ToLowerInvariant()
    } finally { $hasher.Dispose() }
}

function Get-FastLlmTaskWorkloadPromptSha256 {
    param([Parameter(Mandatory=$true)]$Case)
    if(-not ($Case.prompt -is [string])){throw 'Task prompt is missing.'}
    Get-FastLlmTaskWorkloadSha256 -Text $Case.prompt
}

function Get-FastLlmTaskWorkloadReferenceSha256 {
    param([Parameter(Mandatory=$true)]$Case)
    if(-not ($Case.suiteVersion -is [string]) -or -not ($Case.id -is [string]) -or
       -not ($Case.expected -is [string])){throw 'Task reference identity is incomplete.'}
    $format=if($null -eq $Case.responseFormat){''}else{ConvertTo-Json -InputObject $Case.responseFormat -Depth 10 -Compress}
    Get-FastLlmTaskWorkloadSha256 -Text ($Case.suiteVersion+"`n"+$Case.id+"`n"+$Case.kind+"`n"+
        $Case.expected+"`n"+$Case.gradingNormalization+"`n"+$format)
}

function Get-FastLlmTaskWorkloadCases {
    [CmdletBinding()]
    param([ValidateSet(0,32,128)][int]$DistractorCount=0)
    $notes=@()
    for($i=1;$i -le $DistractorCount;$i++){
        $notes+=('Irrelevant archive note {0:D3}: marker N{0:D3} is not part of any requested answer.' -f $i)
    }
    $noteBlock=if($notes.Count){"`n"+([string]::Join("`n",[string[]]$notes))+"`n"}else{"`n"}
    $version=Get-FastLlmTaskWorkloadSuiteVersion
    $jsonSchema=[ordered]@{
        type='json_object'
        schema=[ordered]@{
            type='object'
            properties=[ordered]@{
                orderId=[ordered]@{type='string'}
                units=[ordered]@{type='integer'}
                rush=[ordered]@{type='boolean'}
            }
            required=@('orderId','units','rush')
            additionalProperties=$false
        }
    }
    $definitions=@(
        [pscustomobject]@{id='extract-order-v1';kind='structured-json';expected='{"orderId":"BX-204","units":7,"rush":true}';maxOutputTokens=96;responseFormat=$jsonSchema;targetPosition='source-record';
            prompt=('Extract exactly orderId (string), units (integer), and rush (boolean) from this record. Return one bare JSON object with exactly those keys and no Markdown or other text.'+"`n"+
                'Record: Order BX-204 requests 7 units. Expedited handling is YES.'+$noteBlock+'Only the Record line supplies the requested values.')},
        [pscustomobject]@{id='filter-candidates-v1';kind='filter';expected='K2,K4';maxOutputTokens=32;responseFormat=$null;targetPosition='table';
            prompt=('From the table, return IDs whose score is at least 80 AND whose status is active, in the table order. Output only comma-separated IDs with no spaces.'+"`n"+
                'K1 score=92 status=paused; K2 score=80 status=active; K3 score=79 status=active; K4 score=85 status=active.'+$noteBlock+'Answer using only the table.')},
        [pscustomobject]@{id='sort-integers-v1';kind='sort';expected='-3,0,9,12';maxOutputTokens=32;responseFormat=$null;targetPosition='values';
            prompt=('Sort these four integers ascending. Output only a comma-separated list with no spaces: 9, -3, 12, 0.'+$noteBlock+'Do not include an explanation.')},
        [pscustomobject]@{id='arithmetic-invoice-v1';kind='arithmetic';expected='869';maxOutputTokens=32;responseFormat=$null;targetPosition='expression';
            prompt=('Compute 37 times 24, then subtract 19. Output only the resulting base-10 integer.'+$noteBlock+'No units or explanation.')},
        [pscustomobject]@{id='arithmetic-steps-v1';kind='arithmetic';expected='63';maxOutputTokens=32;responseFormat=$null;targetPosition='expression';
            prompt=('Compute (84 divided by 7 plus 9) times 3, using the parentheses as written. Output only the resulting base-10 integer.'+$noteBlock+'No units or explanation.')},
        [pscustomobject]@{id='dependency-chain-v1';kind='dependency-order';expected='plan>fetch>verify>serve';maxOutputTokens=48;responseFormat=$null;targetPosition='constraints';
            prompt=('Four steps are plan, fetch, verify, serve. Plan must precede fetch; fetch must precede verify; verify must precede serve. Output the only valid full order in lowercase, joined by > with no spaces.'+$noteBlock+'Include each step exactly once.')},
        [pscustomobject]@{id='retrieve-head-v1';kind='context-retrieval';expected='MARIGOLD-47';maxOutputTokens=32;responseFormat=$null;targetPosition='head';
            prompt=('Find the code on the AUTHORITATIVE ledger line; ignore archive notes. Output only that exact code.'+"`n"+
                'AUTHORITATIVE ledger line: code MARIGOLD-47.'+$noteBlock+'What is the authoritative code?')},
        [pscustomobject]@{id='retrieve-tail-v1';kind='context-retrieval';expected='CYAN-812';maxOutputTokens=32;responseFormat=$null;targetPosition='tail';
            prompt=('Find the key on the AUTHORITATIVE depot line; ignore archive notes. Output only that exact key.'+$noteBlock+
                'AUTHORITATIVE depot line: key CYAN-812.'+"`n"+'What is the authoritative key?')}
    )
    foreach($definition in $definitions){
        [pscustomobject]@{
            suiteVersion=$version;id=$definition.id;kind=$definition.kind;prompt=$definition.prompt
            expected=$definition.expected;maxOutputTokens=$definition.maxOutputTokens
            responseFormat=$definition.responseFormat;distractorCount=$DistractorCount
            targetPosition=$definition.targetPosition
            gradingNormalization='trim-leading-trailing-whitespace-only'
        }
    }
}

function New-FastLlmTaskWorkloadResult {
    param([bool]$Passed,[string]$ErrorCode,[string]$Classification)
    [pscustomobject]@{passed=$Passed;errorCode=$ErrorCode;classification=$Classification}
}

function Skip-FastLlmTaskJsonWhitespace {
    param([string]$Text,[ref]$Position)
    while($Position.Value -lt $Text.Length -and " `t`r`n".Contains([string]$Text[$Position.Value])){
        $Position.Value++
    }
}

function Read-FastLlmTaskJsonString {
    param([string]$Text,[ref]$Position)
    if($Position.Value -ge $Text.Length -or [int][char]$Text[$Position.Value] -ne 34){throw [FormatException]'Expected JSON string.'}
    $start=$Position.Value
    $Position.Value++
    while($Position.Value -lt $Text.Length){
        $point=[int][char]$Text[$Position.Value]
        if($point -eq 34){
            $Position.Value++
            $raw=$Text.Substring($start,$Position.Value-$start)
            try { $decoded=ConvertFrom-Json -InputObject $raw -ErrorAction Stop }
            catch { throw [FormatException]'Invalid JSON string escape.' }
            if(-not ($decoded -is [string])){throw [FormatException]'Invalid JSON string.'}
            return [pscustomobject]@{value=$decoded;kind='string';raw=$raw}
        }
        if($point -lt 32){throw [FormatException]'Control character in JSON string.'}
        if($point -eq 92){
            $Position.Value++
            if($Position.Value -ge $Text.Length){throw [FormatException]'Incomplete JSON escape.'}
            $escape=[string]$Text[$Position.Value]
            if($escape -ceq 'u'){
                if($Position.Value+4 -ge $Text.Length -or
                   $Text.Substring($Position.Value+1,4) -cnotmatch '^[0-9a-fA-F]{4}$'){
                    throw [FormatException]'Invalid JSON Unicode escape.'
                }
                $Position.Value+=4
            } elseif(-not ('"\/bfnrt'.Contains($escape))){
                throw [FormatException]'Invalid JSON escape.'
            }
        }
        $Position.Value++
    }
    throw [FormatException]'Unterminated JSON string.'
}

function Read-FastLlmTaskJsonScalar {
    param([string]$Text,[ref]$Position)
    if($Position.Value -lt $Text.Length -and [int][char]$Text[$Position.Value] -eq 34){
        return Read-FastLlmTaskJsonString -Text $Text -Position $Position
    }
    $start=$Position.Value
    while($Position.Value -lt $Text.Length -and
          -not " ,}`t`r`n".Contains([string]$Text[$Position.Value])){$Position.Value++}
    if($Position.Value -eq $start){throw [FormatException]'Missing JSON value.'}
    $raw=$Text.Substring($start,$Position.Value-$start)
    if($raw -ceq 'true' -or $raw -ceq 'false'){
        return [pscustomobject]@{kind='boolean';value=($raw -ceq 'true');raw=$raw}
    }
    if($raw -ceq 'null'){return [pscustomobject]@{kind='null';value=$null;raw=$raw}}
    if($raw -cmatch '^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$'){
        $kind=if($raw -cmatch '^-?(?:0|[1-9][0-9]*)$'){'integer'}else{'number'}
        return [pscustomobject]@{kind=$kind;value=$raw;raw=$raw}
    }
    throw [FormatException]'Invalid JSON scalar.'
}

function Test-FastLlmTaskJsonObject {
    param([string]$Text)
    try {
        $at=0
        Skip-FastLlmTaskJsonWhitespace -Text $Text -Position ([ref]$at)
        if($at -ge $Text.Length -or [int][char]$Text[$at] -ne 123){throw [FormatException]'Expected JSON object.'}
        $at++
        $members=New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
        Skip-FastLlmTaskJsonWhitespace -Text $Text -Position ([ref]$at)
        if($at -lt $Text.Length -and [int][char]$Text[$at] -ne 125){
            while($true){
                $key=Read-FastLlmTaskJsonString -Text $Text -Position ([ref]$at)
                Skip-FastLlmTaskJsonWhitespace -Text $Text -Position ([ref]$at)
                if($at -ge $Text.Length -or [int][char]$Text[$at] -ne 58){throw [FormatException]'Expected JSON colon.'}
                $at++
                Skip-FastLlmTaskJsonWhitespace -Text $Text -Position ([ref]$at)
                $value=Read-FastLlmTaskJsonScalar -Text $Text -Position ([ref]$at)
                if($members.ContainsKey($key.value)){
                    return New-FastLlmTaskWorkloadResult $false 'DUPLICATE_JSON_KEY' 'duplicate-json-key'
                }
                $members.Add($key.value,$value)
                Skip-FastLlmTaskJsonWhitespace -Text $Text -Position ([ref]$at)
                if($at -ge $Text.Length){throw [FormatException]'Unterminated JSON object.'}
                if([int][char]$Text[$at] -eq 125){break}
                if([int][char]$Text[$at] -ne 44){throw [FormatException]'Expected JSON comma.'}
                $at++
                Skip-FastLlmTaskJsonWhitespace -Text $Text -Position ([ref]$at)
                if($at -ge $Text.Length -or [int][char]$Text[$at] -eq 125){throw [FormatException]'Trailing JSON comma.'}
            }
        }
        if($at -ge $Text.Length -or [int][char]$Text[$at] -ne 125){throw [FormatException]'Unterminated JSON object.'}
        $at++
        Skip-FastLlmTaskJsonWhitespace -Text $Text -Position ([ref]$at)
        if($at -ne $Text.Length){throw [FormatException]'Trailing JSON text.'}
    } catch [FormatException] {
        return New-FastLlmTaskWorkloadResult $false 'MALFORMED_JSON' 'malformed-json'
    }
    foreach($key in @('orderId','units','rush')){
        if(-not $members.ContainsKey($key)){return New-FastLlmTaskWorkloadResult $false 'MISSING_JSON_KEY' 'missing-json-key'}
    }
    if($members.Count -ne 3){return New-FastLlmTaskWorkloadResult $false 'EXTRA_JSON_KEY' 'extra-json-key'}
    if($members['orderId'].kind -cne 'string' -or $members['units'].kind -cne 'integer' -or
       $members['rush'].kind -cne 'boolean'){
        return New-FastLlmTaskWorkloadResult $false 'WRONG_JSON_TYPE' 'wrong-json-type'
    }
    if($members['orderId'].value -cne 'BX-204' -or $members['units'].raw -cne '7' -or
       $members['rush'].value -ne $true){
        return New-FastLlmTaskWorkloadResult $false 'WRONG_VALUE' 'wrong-value'
    }
    return New-FastLlmTaskWorkloadResult $true 'OK' 'strict-pass'
}

function Test-FastLlmTaskWorkloadAnswer {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Case,[AllowEmptyString()][string]$Content)
    $known=@('extract-order-v1','filter-candidates-v1','sort-integers-v1','arithmetic-invoice-v1',
             'arithmetic-steps-v1','dependency-chain-v1','retrieve-head-v1','retrieve-tail-v1')
    if($Case.suiteVersion -cne (Get-FastLlmTaskWorkloadSuiteVersion) -or
       -not ($known -ccontains [string]$Case.id)){
        throw 'Unknown task workload case or suite version.'
    }
    if($Case.distractorCount -notin @(0,32,128)){throw 'Unknown task workload distractor count.'}
    $canonical=@(Get-FastLlmTaskWorkloadCases -DistractorCount ([int]$Case.distractorCount) |
        Where-Object { $_.id -ceq $Case.id })
    if($canonical.Count -ne 1){throw 'Unknown task workload case.'}
    $reference=$canonical[0]
    $actualFormat=if($null -eq $Case.responseFormat){''}else{ConvertTo-Json -InputObject $Case.responseFormat -Depth 10 -Compress}
    $referenceFormat=if($null -eq $reference.responseFormat){''}else{ConvertTo-Json -InputObject $reference.responseFormat -Depth 10 -Compress}
    if($Case.kind -cne $reference.kind -or $Case.prompt -cne $reference.prompt -or
       $Case.expected -cne $reference.expected -or
       [int]$Case.maxOutputTokens -ne $reference.maxOutputTokens -or
       $Case.gradingNormalization -cne $reference.gradingNormalization -or
       $actualFormat -cne $referenceFormat){throw 'Task workload case metadata differs from the suite.'}
    $answer=if($null -eq $Content){''}else{$Content.Trim()}
    if($answer.Length -eq 0){return New-FastLlmTaskWorkloadResult $false 'EMPTY' 'empty'}
    if($Case.kind -ceq 'structured-json'){
        if($answer.StartsWith('```',[StringComparison]::Ordinal)){
            $fence=[regex]::Match($answer,'\A```(?:json)?\r?\n(?<inner>[\s\S]*?)\r?\n```\z',
                [Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if($fence.Success){
                $inside=Test-FastLlmTaskJsonObject -Text $fence.Groups['inner'].Value
                if($inside.passed){return New-FastLlmTaskWorkloadResult $false 'FENCED_JSON' 'fenced-valid-json'}
            }
            return New-FastLlmTaskWorkloadResult $false 'FENCED_OUTPUT' 'fenced-invalid-json'
        }
        return Test-FastLlmTaskJsonObject -Text $answer
    }
    if($answer.StartsWith('```',[StringComparison]::Ordinal)){
        return New-FastLlmTaskWorkloadResult $false 'FENCED_OUTPUT' 'fenced-output'
    }
    if($answer -cne [string]$Case.expected){
        return New-FastLlmTaskWorkloadResult $false 'WRONG_ANSWER' 'wrong-answer'
    }
    return New-FastLlmTaskWorkloadResult $true 'OK' 'strict-pass'
}
