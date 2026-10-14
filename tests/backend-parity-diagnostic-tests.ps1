#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$repoRoot=Split-Path $PSScriptRoot -Parent
$semantic=Join-Path $repoRoot 'src/FastLlm.SemanticSmoke.ps1'
$workload=Join-Path $repoRoot 'src/FastLlm.TaskWorkload.ps1'
$taskQuality=Join-Path $repoRoot 'tools/task-quality-benchmark.ps1'
$cpuLab=Join-Path $repoRoot 'src/FastLlm.CpuReferenceLab.ps1'
$diagnostic=Join-Path $repoRoot 'src/FastLlm.BackendParityDiagnostic.ps1'
$tool=Join-Path $repoRoot 'tools/backend-parity-diagnostic.ps1'
foreach($path in @($cpuLab,$diagnostic,$tool)){
    $tokens=$null;$errors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    if(@($errors).Count){throw ('Parser errors in '+$path+': '+(@($errors | ForEach-Object Message) -join ' | '))}
}
. $semantic
. $workload
. $taskQuality -OutputPath (Join-Path ([IO.Path]::GetTempPath()) 'unused-backend-parity-task-quality.json')
. $cpuLab
. $diagnostic
$script:checks=0
function Check($Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
function Fails([scriptblock]$Operation,[string]$Message){$failed=$false;try{& $Operation|Out-Null}catch{$failed=$true};Check $failed $Message}
function New-TestRoot {
    $path=Join-Path ([IO.Path]::GetTempPath()) ('fastllm-backend-parity-'+[Guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory -Path $path
    return $path
}
$constants=Get-FastLlmBackendParityConstants
$cases=Get-FastLlmBackendParityCases
$g1Case=$cases['arithmetic-steps-v1'];$g3Case=$cases['arithmetic-invoice-v1']
$renderPath=Join-Path $repoRoot 'tests/fixtures/qwen38-arithmetic-steps-render.json'
$renderDocument=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($renderPath))
$realRender=[string]$renderDocument.text
$syntheticPrompt="<|im_start|>user`nSYNTHETIC-BITWORKS-RENDERED-PROMPT<|im_end|>`n<|im_start|>assistant`n<think>`n`n</think>`n`n"

function New-NormalState {
    $arguments=@('--model','<verified-model>','--offline','--no-mmproj','--spec-type','none','--alias',$constants.modelId,
        '--host','127.0.0.1','--port','8080','--cors-origins','localhost','--no-cors-credentials','--ctx-size','32768',
        '--parallel','1','--n-gpu-layers','all','--fit','on','--fit-target','768','--device','Vulkan0','--split-mode','none',
        '--flash-attn','auto','--cache-type-k','f16','--cache-type-v','f16','--jinja','--metrics','--log-verbosity','4','--no-agent','--no-ui')
    [pscustomobject]@{
        schemaVersion=1;active=$true;phase='ready';runId=('a'*32);endpoint='http://127.0.0.1:8080/v1'
        modelId=$constants.modelId;modelSha256=$constants.modelSha256;engineVersion='b10698'
        processIdentity=[pscustomobject]@{pid=42;startUtcTicks=638000000000000000}
        canary=[pscustomobject]@{modelIdentity=$true;repeatableToken=$true;synchronousChat=$true;streaming=$true;
            effectiveContext=32768;semanticCorrectnessQualified=$false}
        placement=[pscustomobject]@{reportedLayers=66;totalLayers=66;reportedAllLayers=$true;devices=@('Vulkan0')}
        startupDiagnostics=[pscustomobject]@{status='captured';reportedFlashAttentionMode='auto';reportedFlashAttentionResolved=$true}
        recipe=[pscustomobject]@{backend='Vulkan';contextSize=32768;slots=1;engineSha256=$constants.engineSha256;
            catalogSha256=$constants.catalogSha256;cacheTypeK='f16';cacheTypeV='f16';speculation='none';flashAttention='auto';
            splitMode='none';tensorSplit=$null
            adapters=@([pscustomobject]@{device='Vulkan0';name='AMD Radeon RX 7900 XTX';vendorId='1002';isAmd=$true;isIntegrated=$false;backend='Vulkan'})
            requestedArguments=$arguments}
    }
}
function New-CpuState {
    $fixed=Get-FastLlmCpuReferenceFixed
    $arguments=@('--model','<verified-model>','--offline','--no-mmproj','--spec-type','none','--alias',$fixed.modelId,
        '--host','127.0.0.1','--port','18089','--cors-origins','localhost','--no-cors-credentials','--ctx-size','32768',
        '--parallel','1','--n-gpu-layers','0','--fit','off','--fit-target','768','--device','none','--split-mode','none',
        '--no-op-offload','--no-kv-offload','--flash-attn','auto','--cache-type-k','f16','--cache-type-v','f16','--jinja',
        '--metrics','--log-verbosity','4','--no-agent','--no-ui')
    [pscustomobject]@{
        schemaVersion=1;kind=$fixed.stateKind;active=$true;phase='lab-ready';runId=('b'*32);endpoint='http://127.0.0.1:18089/v1'
        modelId=$fixed.modelId;modelSha256=$fixed.modelSha256;engineVersion='b10698'
        processIdentity=[pscustomobject]@{pid=43;startUtcTicks=638000000000000001}
        canary=[pscustomobject]@{modelIdentity=$true;repeatableToken=$true;synchronousChat=$true;streaming=$true;
            effectiveContext=32768;semanticCorrectnessQualified=$false}
        startupDiagnostics=[pscustomobject]@{status='captured';reportedFlashAttentionMode='auto';reportedFlashAttentionResolved=$true}
        placement=[pscustomobject]@{requestedGpuLayers=0;reportedGpuLayers=0;reportedTotalLayers=65;cpuModelBufferMiB=15700.5;
            cpuModelBufferKinds=@('CPU_Mapped');cpuModelBufferLineCount=1;gpuBufferLinesObserved=0}
        recipe=[pscustomobject]@{backend='Vulkan-engine-cpu-placement';contextSize=32768;slots=1;device='none';gpuLayers=0;
            engineSha256=$fixed.engineSha256;catalogSha256=$fixed.catalogSha256;requestedArguments=$arguments}
    }
}
$normalAssert={param($State,$Expected)
    $binding=Assert-FastLlmSemanticSmokeState -State $State -ExpectedBinding $Expected
    Assert-FastLlmBackendParityNormalRecipe -State $State
    $binding}
$cpuAssert={param($State,$Expected) Assert-FastLlmCpuReferenceState -State $State -ExpectedBinding $Expected}
function New-Alternatives([string[]]$Tokens,[double[]]$Logprobs){
    $items=@()
    for($i=0;$i -lt $Tokens.Count;$i++){$items+=[ordered]@{token=$Tokens[$i];logprob=$Logprobs[$i]}}
    return ,$items
}
function New-GenerationResponse([string]$Content,[string]$Finish='stop',[bool]$WithLogprobs=$false,$PositionCount=3,[bool]$Malformed=$false){
    $choice=[ordered]@{index=0;message=[ordered]@{role='assistant';content=$Content};finish_reason=$Finish}
    if($WithLogprobs){
        $lpItems=@()
        $tokens=@('6','3','<|im_end|>','X','Y','Z')
        for($i=0;$i -lt $PositionCount;$i++){
            $alts=New-Alternatives @('6','7','-','six','63',' 6','<|im_start|>','8','9','0','1','2') @(-0.123456,-1.23455,-2.5,-3.5,-4.5,-5.5,-6.5,-7.5,-8.5,-9.5,-10.5,-11.5)
            $entry=[ordered]@{token=$tokens[$i];logprob=-0.123456;bytes=@(54);top_logprobs=$alts}
            if($Malformed){$entry.Remove('top_logprobs')}
            $lpItems+=$entry
        }
        $choice.logprobs=[ordered]@{content=$lpItems}
    }
    [pscustomobject]@{Status=200;Body=(ConvertTo-Json -InputObject ([ordered]@{choices=@($choice);usage=[ordered]@{prompt_tokens=60;completion_tokens=3}}) -Depth 12 -Compress)}
}
function New-TemplateResponse([string]$Prompt){
    [pscustomobject]@{Status=200;Body=(ConvertTo-Json -InputObject @{prompt=$Prompt} -Compress)}
}
function New-TokenizeResponse([int[]]$Ids){
    $tokens=@(foreach($id in $Ids){[ordered]@{id=$id;piece=('p'+$id)}})
    [pscustomobject]@{Status=200;Body=(ConvertTo-Json -InputObject @{tokens=$tokens} -Depth 6 -Compress)}
}
function New-StandardRequest([string]$G1='64',[string]$G2='64',[string]$G3='869',[int[]]$Ids=$null,[string]$Prompt=$null){
    if($null -eq $Ids){$Ids=@($constants.promptTokenIds)}
    if([string]::IsNullOrEmpty($Prompt)){$Prompt=$syntheticPrompt}
    $script:requestConfig=@{g1=$G1;g2=$G2;g3=$G3;ids=$Ids;prompt=$Prompt}
    return {param($Path,$Body,$TimeoutMs)
        $script:requests++;$script:paths+=$Path;$script:bodies+=,$Body;$script:timeouts+=$TimeoutMs
        if($Path -ceq '/apply-template'){return New-TemplateResponse $script:requestConfig.prompt}
        if($Path -ceq '/tokenize'){return New-TokenizeResponse $script:requestConfig.ids}
        if($Path -cne '/v1/chat/completions'){throw 'wrong path'}
        $logprobs=($null -ne $Body.PSObject.Properties['logprobs'])
        if($Body.messages[0].content -ceq $g3Case.prompt){return New-GenerationResponse $script:requestConfig.g3 'stop' $true}
        if($logprobs){return New-GenerationResponse $script:requestConfig.g2 'stop' $true}
        return New-GenerationResponse $script:requestConfig.g1
    }
}
function Reset-Counters {$script:requests=0;$script:paths=@();$script:bodies=@();$script:timeouts=@();$script:reads=0}
function Invoke-Core($Target,$State,$Assert,$Request,[string]$Name,[int]$Deadline=30,[int]$Timeout=5,$Read=$null,$Process=$null,[string]$Edition=''){
    if($null -eq $Read){$Read={$script:state}}
    if($null -eq $Process){$Process={param($S)}}
    $script:state=$State
    Invoke-FastLlmBackendParityCore -OutputPath (Join-Path $root ($Name+'.json')) -Target $Target -ToolSourcePath $tool `
        -TaskQualityToolSourcePath $taskQuality -DeadlineSeconds $Deadline -RequestTimeoutSeconds $Timeout `
        -ReadState $Read -AssertState $Assert -CheckProcess $Process -Request $Request -Edition $Edition
}

# --- Pure retention and parser behaviour ---
Check ($constants.promptTokenIds.Count -eq 50 -and $constants.promptTokenIds[0] -eq 248045 -and $constants.promptTokenIds[49] -eq 271) 'embedded token IDs changed'
Check ($constants.renderedPromptSha256 -ceq '0de01e9758e7469fbbf649a3d529d756ccb8bcc0d937538633155ca18c20c41c') 'embedded render hash changed'
foreach($sample in @(
    @{text='63';kind='integer';value='63'},@{text='-5';kind='integer';value='-5'},@{text='0';kind='integer';value='0'},
    @{text='123456';kind='integer';value='123456'},@{text='-123456';kind='integer';value='-123456'},
    @{text='1234567';kind='integer-too-long';value=$null},@{text='-1234567';kind='integer-too-long';value=$null},
    @{text='63.';kind='non-integer';value=$null},@{text=' 63 ';kind='integer';value='63'},
    @{text="`n 63`t";kind='integer';value='63'},@{text='6 3';kind='non-integer';value=$null},
    @{text='--5';kind='non-integer';value=$null},@{text='+5';kind='non-integer';value=$null},
    @{text='-';kind='non-integer';value=$null},@{text='';kind='empty';value=$null},@{text='   ';kind='empty';value=$null},
    @{text='The answer is 63';kind='non-integer';value=$null},@{text='63 and more';kind='non-integer';value=$null},
    @{text=([string]::Join("`n",@('63','64')));kind='non-integer';value=$null},
    @{text=([string][char]0x0666+[char]0x0663);kind='non-integer';value=$null}
)){
    $answer=ConvertTo-FastLlmBackendParityAnswer -Content $sample.text
    Check ($answer.classification -ceq $sample.kind -and (($null -eq $sample.value -and $null -eq $answer.value) -or $answer.value -ceq $sample.value)) ('answer retention boundary '+$sample.kind+' for length '+$sample.text.Length)
    Check ($answer.length -eq $sample.text.Length) 'answer length not recorded'
}
Check ((ConvertTo-FastLlmBackendParityAnswer -Content $null).classification -ceq 'missing') 'null content not classified missing'
foreach($keep in @('0','7','9','-','<|im_end|>')){Check ((ConvertTo-FastLlmBackendParityPiece $keep) -ceq $keep) "piece $keep was redacted"}
foreach($drop in @('63','six',' 6','<|im_start|>','','--','6-','<|IM_END|>',"6`n",$null,42)){
    Check ((ConvertTo-FastLlmBackendParityPiece $drop) -ceq '<other>') 'piece was not redacted'
}
$lp=Get-FastLlmBackendParityLogprobs -Body ((New-GenerationResponse '64' 'stop' $true 6).Body)
Check ($lp.status -ceq 'captured' -and @($lp.positions).Count -eq 4) 'logprob retention was not limited to four positions'
$p1=@($lp.positions)[0]
Check ($p1.position -eq 1 -and $p1.sampledPiece -ceq '6' -and $p1.sampledLogprob -eq -0.1235 -and @($p1.top).Count -eq 10) 'logprob rounding or top-10 bound failed'
Check ($p1.top1Piece -ceq '6' -and $p1.top1Logprob -eq -0.1235) 'top-1 was not the maximum log probability'
Check (@($p1.top | Where-Object piece -ceq '<other>').Count -ge 3 -and @($p1.top | Where-Object piece -ceq '-').Count -eq 1) 'top piece redaction failed'
Check ((@($lp.positions)[2]).sampledPiece -ceq '<|im_end|>' -and (@($lp.positions)[3]).sampledPiece -ceq '<other>') 'sampled piece redaction failed'
$short=Get-FastLlmBackendParityLogprobs -Body ((New-GenerationResponse '64' 'stop' $true 3).Body)
Check ($short.status -ceq 'captured' -and @($short.positions).Count -eq 3) 'short generation lost positions'
Check ((Get-FastLlmBackendParityLogprobs -Body ((New-GenerationResponse '64' 'stop' $true 3 $true).Body)).status -ceq 'malformed') 'malformed logprobs accepted'
Check ((Get-FastLlmBackendParityLogprobs -Body ((New-GenerationResponse '64').Body)).status -ceq 'missing') 'absent logprobs not reported missing'
Check ((Get-FastLlmBackendParityLogprobs -Body 'not-json').status -ceq 'malformed') 'non-JSON logprobs accepted'
$tpl=ConvertFrom-FastLlmBackendParityTemplate -Response (New-TemplateResponse $syntheticPrompt) -ExpectedSha256 (Get-FastLlmTaskWorkloadSha256 -Text $syntheticPrompt)
Check ($tpl.status -ceq 'captured' -and $tpl.matchesLocalRender -and $tpl.renderedPromptRetained -and $tpl.renderedPrompt -ceq $syntheticPrompt) 'matching template was not recorded'
$tplBig=ConvertFrom-FastLlmBackendParityTemplate -Response (New-TemplateResponse ('x'*5000)) -ExpectedSha256 ('0'*64)
Check ($tplBig.status -ceq 'captured' -and -not $tplBig.renderedPromptRetained -and $null -eq $tplBig.renderedPrompt -and $tplBig.renderedPromptLength -eq 5000) 'oversized rendered prompt was retained'
Check ((ConvertFrom-FastLlmBackendParityTemplate -Response ([pscustomobject]@{Status=200;Body='{"x":1}'}) -ExpectedSha256 ('0'*64)).status -ceq 'invalid-response') 'template without prompt accepted'
Check ((ConvertFrom-FastLlmBackendParityTemplate -Response ([pscustomobject]@{Status=404;Body=''}) -ExpectedSha256 ('0'*64)).status -ceq 'http-status') 'template 404 accepted'
$tok=ConvertFrom-FastLlmBackendParityTokenize -Response (New-TokenizeResponse @($constants.promptTokenIds)) -ExpectedIds @($constants.promptTokenIds)
Check ($tok.status -ceq 'captured' -and $tok.matchesLocalTokenIds -and $tok.tokenCount -eq 50) 'matching token IDs were not recorded'
$off=@($constants.promptTokenIds);$off[7]=1
Check (-not (ConvertFrom-FastLlmBackendParityTokenize -Response (New-TokenizeResponse $off) -ExpectedIds @($constants.promptTokenIds)).matchesLocalTokenIds) 'differing token ID matched'
Check (-not (ConvertFrom-FastLlmBackendParityTokenize -Response (New-TokenizeResponse @($constants.promptTokenIds)[0..48]) -ExpectedIds @($constants.promptTokenIds)).matchesLocalTokenIds) 'shorter token list matched'
Check ((ConvertFrom-FastLlmBackendParityTokenize -Response ([pscustomobject]@{Status=200;Body='{"tokens":[1,2]}'}) -ExpectedIds @(1,2)).status -ceq 'invalid-response') 'bare-integer tokens accepted without pieces'
$bytesPiece=ConvertFrom-FastLlmBackendParityTokenize -Response ([pscustomobject]@{Status=200;Body='{"tokens":[{"id":5,"piece":[195,40]},{"id":6,"piece":"ab"}]}'}) -ExpectedIds @(5,6)
Check ($bytesPiece.status -ceq 'captured' -and $bytesPiece.pieces[0] -ceq '<bytes>' -and $bytesPiece.matchesLocalTokenIds) 'byte-array piece handling failed'
Check ($null -eq (ConvertTo-FastLlmBackendParityNumber $true) -and $null -eq (ConvertTo-FastLlmBackendParityNumber $false) -and (ConvertTo-FastLlmBackendParityNumber ([double]-0.123456)) -eq -0.1235) 'boolean accepted as a number'
$boolLogprob=Get-FastLlmBackendParityLogprobs -Body '{"choices":[{"logprobs":{"content":[{"token":"6","logprob":true,"top_logprobs":[{"token":"6","logprob":false}]}]}}]}'
Check ($boolLogprob.status -ceq 'captured' -and $null -eq @($boolLogprob.positions)[0].sampledLogprob -and $null -eq @($boolLogprob.positions)[0].top1Logprob) 'boolean log probabilities were retained'
Check ((Get-FastLlmBackendParityLogprobs -Body '{"choices":[{"logprobs":{"content":[5]}}]}').status -ceq 'malformed') 'non-object position accepted'
Check ((Get-FastLlmBackendParityLogprobs -Body '{"choices":[{"logprobs":{"content":[{"token":"6","logprob":-1}]}}]}').status -ceq 'malformed') 'position without top_logprobs accepted'
Check ((ConvertFrom-FastLlmBackendParityTokenize -Response ([pscustomobject]@{Status=200;Body='{"tokens":[{"id":true,"piece":"a"}]}'}) -ExpectedIds @(1)).status -ceq 'invalid-response') 'boolean token ID accepted'
$longPiece=ConvertFrom-FastLlmBackendParityTokenize -Response ([pscustomobject]@{Status=200;Body=('{"tokens":[{"id":5,"piece":"'+('a'*40)+'"},{"id":6,"piece":"'+('b'*32)+'"}]}')}) -ExpectedIds @(5,6)
Check ($longPiece.pieces[0] -ceq '<long>' -and $longPiece.pieces[1] -ceq ('b'*32)) 'T2 piece cap not applied'
$manyTokens='{"tokens":['+((1..1025 | ForEach-Object {'{"id":'+$_+',"piece":"a"}'}) -join ',')+']}'
Check ((ConvertFrom-FastLlmBackendParityTokenize -Response ([pscustomobject]@{Status=200;Body=$manyTokens}) -ExpectedIds @(1)).status -ceq 'invalid-response') 'oversized token list accepted'
Check ((Get-FastLlmBackendParityAbortRank 'historical-body-mismatch') -eq (Get-FastLlmBackendParityAbortRank 'hash-mismatch')) 'pin mismatch rank wrong'
$toolText=[IO.File]::ReadAllText($tool)
Check ($toolText.Contains("if(`$report.reportStatus -cne 'complete'){exit 1}")) 'tool does not exit nonzero for an aborted arm'
Check ((Get-FastLlmBackendParityAbortRank 'hash-mismatch') -gt (Get-FastLlmBackendParityAbortRank 'identity-changed') -and
    (Get-FastLlmBackendParityAbortRank 'identity-changed') -gt (Get-FastLlmBackendParityAbortRank 'source-changed') -and
    (Get-FastLlmBackendParityAbortRank 'source-changed') -gt (Get-FastLlmBackendParityAbortRank 'deadline') -and
    (Get-FastLlmBackendParityAbortRank 'deadline') -gt (Get-FastLlmBackendParityAbortRank 'http-status')) 'abort precedence order changed'

# --- Case identity and the historical G1 body ---
Check ($g1Case.id -ceq 'arithmetic-steps-v1' -and $g1Case.expected -ceq '63' -and $g3Case.id -ceq 'arithmetic-invoice-v1' -and $g3Case.expected -ceq '869') 'fixed cases changed'
$savedCases=(Get-Command Get-FastLlmTaskWorkloadCases).ScriptBlock
try{
    Set-Item Function:Get-FastLlmTaskWorkloadCases -Value {
        param([int]$DistractorCount=0)
        $changed=@()
        foreach($item in @(& $savedCases -DistractorCount $DistractorCount)){
            if($item.id -ceq 'arithmetic-invoice-v1'){$copy=$item.PSObject.Copy();$copy.prompt=([string]$item.prompt)+' changed';$changed+=$copy}else{$changed+=$item}
        }
        $changed
    }
    Fails {Get-FastLlmBackendParityCases} 'changed G3 prompt was accepted'
}finally{Set-Item Function:Get-FastLlmTaskWorkloadCases -Value $savedCases}
$hashes=Get-FastLlmBackendParitySourceHashes -ToolSourcePath $tool -TaskQualityToolSourcePath $taskQuality
foreach($key in @('diagnostic','tool','taskQualityParser','cpuReferenceLab','workload','semanticSmoke','module','benchmark','runtime','httpHost','listener')){
    Check ($hashes.Contains($key) -and [string]$hashes[$key] -cmatch '^[0-9a-f]{64}$') "missing source hash $key"
}
Check (Test-FastLlmBackendParitySourceHashes $hashes $tool $taskQuality) 'unchanged sources rejected'
$diagnosticSource=[IO.File]::ReadAllText($diagnostic)
foreach($required in @("`$env:OS -cne 'Windows_NT'",'[Environment]::Is64BitProcess','WindowsBuiltInRole]::Administrator',"'benchmark.lock'",'[IO.FileMode]::CreateNew','[IO.FileAttributes]::ReparsePoint')){
    Check ($diagnosticSource.Contains($required)) "wrapper safety contract missing $required"
}
Check (-not ($diagnosticSource -cmatch '\?\?|-AsHashtable|ForEach-Object -Parallel')) 'PowerShell 7-only syntax present'

$root=New-TestRoot
try{
    # --- Complete CPU-reference arm with the real CPU state assertion ---
    Reset-Counters
    $report=Invoke-Core 'CpuReference' (New-CpuState) $cpuAssert (New-StandardRequest) 'cpu-complete'
    Check ($script:requests -eq 5 -and (@($script:paths) -join ',') -ceq '/apply-template,/tokenize,/v1/chat/completions,/v1/chat/completions,/v1/chat/completions') 'request order or count changed'
    Check ($report.reportStatus -ceq 'complete' -and $null -eq $report.failureCode -and $report.target -ceq 'CpuReference' -and $report.valid -eq $true -and $report.g3Passed -eq $true) 'complete arm was not valid'
    Check ($report.t1.status -ceq 'captured' -and $report.t1.matchesLocalRender -eq $false -and $report.t1.renderedPrompt -ceq $syntheticPrompt) 'T1 mismatch was not recorded as a finding'
    Check ($report.t2.status -ceq 'captured' -and $report.t2.matchesLocalTokenIds -eq $true -and $report.t2.tokenCount -eq 50) 'T2 match was not recorded'
    Check ($report.g1.answer.value -ceq '64' -and $report.g1.grade -ceq 'incorrect' -and $report.g1.answerMatchesExpected -eq $false -and $report.g1.strictPass -eq $false) 'G1 wrong integer not recorded'
    Check ($report.g2.logprobsRequested -eq $true -and @($report.g2.positions).Count -eq 3 -and $report.g3.strictPass -eq $true -and $report.g3.answer.value -ceq '869') 'G2/G3 rows incomplete'
    Check ($null -eq $report.g1.PSObject.Properties['positions'] -and $report.g1.logprobsRequested -eq $false) 'G1 requested logprobs'
    Check ($report.catalogSha256 -ceq $constants.catalogSha256 -and $report.engineSha256 -ceq $constants.engineSha256 -and $report.modelSha256 -ceq $constants.modelSha256) 'hash binding missing'
    Check ((@($report.requestedArguments) -contains '--device') -and (@($report.requestedArguments) -contains '--no-kv-offload') -and $report.placementEvidence.reportedGpuLayers -eq 0) 'CPU recipe/placement evidence missing'
    Check ($report.methodology.issuedRequests -eq 5 -and $report.methodology.retryCount -eq 0 -and $report.methodology.deadlineSeconds -eq 30) 'methodology wrong'
    $q=$report.qualification
    Check ($q.approved -eq $false -and $q.qualityEvaluation -eq $false -and $q.semanticQualified -eq $false -and $q.performanceQualified -eq $false -and
        $q.physicalResidency -eq $false -and $q.throughputClaim -eq $false -and $q.gdnClaim -eq $false -and $q.generalCorrectnessClaim -eq $false) 'qualification flag was not false'

    # Request bodies: G1 is the historical-exact body; G2/G3 add exactly the logprob fields.
    $historical=New-TaskQualityRequestBody -State $script:state -Case $g1Case
    $historicalSha=Get-FastLlmTaskWorkloadSha256 -Text $historical
    Check ($report.methodology.g1RequestBodySha256 -ceq $historicalSha -and $report.g1.requestBodySha256 -ceq $historicalSha) 'G1 body hash differs from the task-quality constructor'
    Check ((Get-FastLlmTaskWorkloadSha256 -Text (ConvertTo-Json -InputObject $script:bodies[2] -Depth 12 -Compress)) -ceq $historicalSha) 'G1 wire body differs from the historical body'
    $g2=$script:bodies[3];$g3=$script:bodies[4]
    Check ($g2.logprobs -eq $true -and [int]$g2.top_logprobs -eq 10 -and $g2.messages[0].content -ceq $g1Case.prompt -and
        [int]$g2.max_tokens -eq 32 -and [int]$g2.seed -eq 42 -and $g2.chat_template_kwargs.enable_thinking -eq $false) 'G2 body wrong'
    Check ($g3.logprobs -eq $true -and [int]$g3.top_logprobs -eq 10 -and $g3.messages[0].content -ceq $g3Case.prompt -and $g3.model -ceq $constants.modelId) 'G3 body wrong'
    $t1Body=$script:bodies[0]
    Check ($t1Body.messages[0].content -ceq $g1Case.prompt -and $t1Body.chat_template_kwargs.enable_thinking -eq $false -and @($t1Body.messages).Count -eq 1) 'T1 body wrong'
    $t2Body=$script:bodies[1]
    Check ($t2Body.content -ceq $syntheticPrompt -and $t2Body.with_pieces -eq $true -and $t2Body.parse_special -eq $true) 'T2 body was not the rendered prompt with pieces'
    Check (@($script:timeouts | Where-Object {$_ -le 0 -or $_ -gt 5000}).Count -eq 0) 'per-request timeout was not bounded'

    # --- No completion text leakage (real T1 render, which legitimately contains the full G1 prompt) ---
    Check ($realRender.Length -eq 212 -and (Get-FastLlmTaskWorkloadSha256 -Text $realRender) -ceq $constants.renderedPromptSha256 -and $realRender.Contains($g1Case.prompt)) 'real render fixture is not the 212-character first-party render'
    Reset-Counters
    $leak=Invoke-Core 'CpuReference' (New-CpuState) $cpuAssert (New-StandardRequest 'The answer is sixty-four because of reasons' 'Sure! 1234567' 'Mixed 869 text' $null $realRender) 'leak'
    $serialized=[IO.File]::ReadAllText((Join-Path $root 'leak.json'))
    Check ($leak.t1.matchesLocalRender -eq $true -and $leak.t1.renderedPromptRetained -eq $true -and $leak.t1.renderedPrompt -ceq $realRender -and $leak.t1.renderedPromptLength -eq 212) 'real render was not retained and matched'
    Check ($leak.g1.answer.classification -ceq 'non-integer' -and $null -eq $leak.g1.answer.value -and $leak.g1.answer.length -eq 'The answer is sixty-four because of reasons'.Length) 'non-integer G1 answer not reduced to class and length'
    Check ($leak.g2.answer.classification -ceq 'non-integer' -and $leak.g3.answer.classification -ceq 'non-integer') 'non-integer G2/G3 answers not reduced'
    Check ($leak.completionTextRetained -eq $false -and $leak.rawPromptRetained -eq $true) 'retention flags are not truthful for a retained T1 render'
    $parsedReport=ConvertFrom-Json -InputObject $serialized
    Check ($parsedReport.rawPromptRetained -eq $true -and $parsedReport.t1.renderedPrompt -ceq $realRender) 'serialized T1 render lost'
    $parsedReport.t1.renderedPrompt=$null
    $stripped=ConvertTo-Json -InputObject $parsedReport -Depth 24
    foreach($secret in @('sixty-four','because of reasons','Sure!','1234567','Mixed 869',$g1Case.prompt,$g3Case.prompt,'Compute (84','im_start','<think>')){
        Check (-not $stripped.Contains($secret)) "report leaked text outside T1: $secret"
    }
    # With no retained T1 render the flag must say so.
    Reset-Counters
    $std=New-StandardRequest
    $noRender=Invoke-Core 'CpuReference' (New-CpuState) $cpuAssert {param($Path,$Body,$TimeoutMs)if($Path -ceq '/apply-template'){$script:requests++;return New-TemplateResponse ('x'*5000)};& $std $Path $Body $TimeoutMs} 'no-render'
    Check ($noRender.t1.renderedPromptRetained -eq $false -and $noRender.rawPromptRetained -eq $false) 'oversized render flag overstated'
    # A too-long numeric answer is not retained either.
    Check ($leak.g2.answer.classification -ceq 'non-integer') 'sanity'
    Reset-Counters
    $long=Invoke-Core 'CpuReference' (New-CpuState) $cpuAssert (New-StandardRequest '1234567' '1234567' '869') 'long'
    Check ($long.g1.answer.classification -ceq 'integer-too-long' -and $null -eq $long.g1.answer.value -and -not ([IO.File]::ReadAllText((Join-Path $root 'long.json'))).Contains('1234567')) 'too-long integer retained'

    # --- Normal arm and its recipe assertion ---
    Reset-Counters
    $normal=Invoke-Core 'Normal' (New-NormalState) $normalAssert (New-StandardRequest '63' '63' '869') 'normal-complete'
    Check ($normal.reportStatus -ceq 'complete' -and $normal.target -ceq 'Normal' -and $normal.g1.strictPass -eq $true -and $normal.g1.answerMatchesExpected -eq $true) 'Normal arm complete report wrong'
    Reset-Counters
    $cpuAsNormal=New-NormalState
    $cpuAsNormal.recipe.requestedArguments=@($cpuAsNormal.recipe.requestedArguments)+@('--no-kv-offload')
    Fails {Invoke-Core 'Normal' $cpuAsNormal $normalAssert (New-StandardRequest) 'normal-cpu-flag'} 'Normal arm accepted a CPU placement flag'
    Check ($script:requests -eq 0) 'requests were issued for a rejected Normal state'
    $wrongModel=New-NormalState;$wrongModel.modelSha256=('0'*64)
    $wrongModelReport=Invoke-Core 'Normal' $wrongModel $normalAssert (New-StandardRequest) 'normal-wrong-model'
    Check ($wrongModelReport.failureCode -ceq 'hash-mismatch' -and $script:requests -eq 0) 'Normal arm with a different model hash did not abort before any request'
    Fails {Invoke-Core 'Normal' (New-NormalState) $normalAssert (New-StandardRequest) 'normal-deadline-too-long' 181} 'Normal arm accepted a deadline above 180 s'
    $cpuLong=Invoke-Core 'CpuReference' (New-CpuState) $cpuAssert (New-StandardRequest) 'cpu-1200' 1200 300
    Check ($cpuLong.methodology.deadlineSeconds -eq 1200 -and $cpuLong.methodology.requestTimeoutSeconds -eq 300) 'CPU arm deadline not 1200 s'
    Fails {Invoke-Core 'CpuReference' (New-CpuState) $cpuAssert (New-StandardRequest) 'cpu-timeout-over-deadline' 10 11} 'request timeout above the deadline accepted'
    $badCpu=New-CpuState;$badCpu.placement.reportedGpuLayers=1
    Fails {Invoke-Core 'CpuReference' $badCpu $cpuAssert (New-StandardRequest) 'cpu-gpu-layers'} 'CPU state with GPU layers was accepted'
    $badCpu2=New-CpuState;$badCpu2.placement.gpuBufferLinesObserved=1
    Fails {Invoke-Core 'CpuReference' $badCpu2 $cpuAssert (New-StandardRequest) 'cpu-gpu-buffer'} 'CPU state with GPU buffers was accepted'

    # --- T1/T2 mismatch is recorded without abort ---
    Reset-Counters
    $offIds=@($constants.promptTokenIds);$offIds[0]=1
    $t2mismatch=Invoke-Core 'CpuReference' (New-CpuState) $cpuAssert (New-StandardRequest '64' '64' '869' $offIds) 't2-mismatch'
    Check ($script:requests -eq 5 -and $t2mismatch.reportStatus -ceq 'complete' -and $t2mismatch.t2.matchesLocalTokenIds -eq $false -and $t2mismatch.t1.matchesLocalRender -eq $false -and $t2mismatch.g3.strictPass -eq $true) 'template/token mismatch stopped generation'

    # --- Missing endpoint, transport error, http status ---
    Reset-Counters
    $missing=Invoke-Core 'CpuReference' (New-CpuState) $cpuAssert {param($Path,$Body,$TimeoutMs)$script:requests++;[pscustomobject]@{Status=404;Body='{}'}} 't1-404'
    Check ($script:requests -eq 1 -and $missing.reportStatus -ceq 'aborted' -and $missing.failureCode -ceq 'endpoint-missing' -and $missing.t1.status -ceq 'aborted' -and $null -eq $missing.t2 -and $null -eq $missing.g1 -and $missing.valid -eq $false) 'missing T1 endpoint did not abort'
    Reset-Counters
    $std=New-StandardRequest
    $t2missing=Invoke-Core 'CpuReference' (New-CpuState) $cpuAssert {param($Path,$Body,$TimeoutMs)if($Path -ceq '/tokenize'){$script:requests++;return [pscustomobject]@{Status=404;Body=''}};& $std $Path $Body $TimeoutMs} 't2-404'
    Check ($t2missing.failureCode -ceq 'endpoint-missing' -and $t2missing.t1.status -ceq 'captured' -and $t2missing.t2.status -ceq 'aborted' -and $null -eq $t2missing.g1) 'missing T2 endpoint did not retain T1 and abort'
    foreach($statusCase in @(@('/apply-template',503,'t1'),@('/tokenize',501,'t2'),@('/apply-template',500,'t1b'))){
        Reset-Counters
        $std=New-StandardRequest
        $script:statusPath=$statusCase[0];$script:statusCode=$statusCase[1]
        $statusReport=Invoke-Core 'CpuReference' (New-CpuState) $cpuAssert {param($Path,$Body,$TimeoutMs)if($Path -ceq $script:statusPath){$script:requests++;return [pscustomobject]@{Status=$script:statusCode;Body=''}};& $std $Path $Body $TimeoutMs} ('status-'+$statusCase[2]+'-'+$statusCase[1])
        Check ($statusReport.failureCode -ceq 'http-status') ('non-404 T1/T2 status '+$statusCase[1]+' was not http-status')
    }
    Reset-Counters
    $std=New-StandardRequest
    $transport=Invoke-Core 'CpuReference' (New-CpuState) $cpuAssert {param($Path,$Body,$TimeoutMs)if($script:requests -eq 3){$script:requests++;throw 'private transport text'};& $std $Path $Body $TimeoutMs} 'g2-transport'
    Check ($script:requests -eq 4 -and $transport.failureCode -ceq 'request-error' -and $transport.g1.answer.value -ceq '64' -and $transport.g2.status -ceq 'aborted' -and $null -eq $transport.g3) 'G2 transport error lost partial report or retried'
    Check (-not ([IO.File]::ReadAllText((Join-Path $root 'g2-transport.json'))).Contains('private transport text')) 'transport text leaked'
    Reset-Counters
    $timeout=Invoke-Core 'CpuReference' (New-CpuState) $cpuAssert {param($Path,$Body,$TimeoutMs)$script:requests++;throw (New-Object System.TimeoutException 'x')} 'timeout'
    Check ($timeout.failureCode -ceq 'timeout' -and $script:requests -eq 1) 'timeout exception type not classified'
    Reset-Counters
    $textOnly=Invoke-Core 'CpuReference' (New-CpuState) $cpuAssert {param($Path,$Body,$TimeoutMs)$script:requests++;throw 'The operation has timed out'} 'timeout-text'
    Check ($textOnly.failureCode -ceq 'request-error') 'a message mentioning time was classified as a timeout'
    Reset-Counters
    $webTimeout=Invoke-Core 'CpuReference' (New-CpuState) $cpuAssert {param($Path,$Body,$TimeoutMs)$script:requests++;throw (New-Object System.Net.WebException 'x',([System.Net.WebExceptionStatus]::Timeout))} 'timeout-web'
    Check ($webTimeout.failureCode -ceq 'timeout') 'WebException timeout not classified'
    Check (Test-FastLlmBackendParityTimeoutException (New-Object InvalidOperationException 'outer',(New-Object System.TimeoutException 'inner'))) 'inner timeout not found'
    Check (-not (Test-FastLlmBackendParityTimeoutException (New-Object InvalidOperationException 'timeout in text only'))) 'text-only timeout accepted'
    Reset-Counters
    $std=New-StandardRequest
    $http500=Invoke-Core 'CpuReference' (New-CpuState) $cpuAssert {param($Path,$Body,$TimeoutMs)if($Path -ceq '/v1/chat/completions'){$script:requests++;return [pscustomobject]@{Status=500;Body='{}'}};& $std $Path $Body $TimeoutMs} 'g1-500'
    Check ($http500.failureCode -ceq 'http-status' -and $http500.t2.status -ceq 'captured' -and $http500.g1.status -ceq 'aborted' -and $null -eq $http500.g2) 'non-200 generation did not abort'

    # --- T1 present but unusable: T2 skipped, generation continues ---
    Reset-Counters
    $std=New-StandardRequest
    $badT1=Invoke-Core 'CpuReference' (New-CpuState) $cpuAssert {param($Path,$Body,$TimeoutMs)if($Path -ceq '/apply-template'){$script:requests++;return [pscustomobject]@{Status=200;Body='{"x":1}'}};& $std $Path $Body $TimeoutMs} 't1-invalid'
    Check ($badT1.t1.status -ceq 'invalid-response' -and $badT1.t2.status -ceq 'skipped-no-rendered-prompt' -and $badT1.reportStatus -ceq 'complete' -and $script:requests -eq 4) 'invalid T1 handling wrong'

    # --- G3 failure: complete but invalid; wrong G3 grade, truncation and malformed response ---
    Reset-Counters
    $g3Fail=Invoke-Core 'CpuReference' (New-CpuState) $cpuAssert (New-StandardRequest '64' '64' '870') 'g3-wrong'
    Check ($g3Fail.reportStatus -ceq 'complete' -and $g3Fail.g3Passed -eq $false -and $g3Fail.valid -eq $false -and $g3Fail.g3.grade -ceq 'incorrect' -and $g3Fail.g3.answer.value -ceq '870') 'G3 failure not recorded as an invalid arm'
    Reset-Counters
    $std=New-StandardRequest
    $g3Trunc=Invoke-Core 'CpuReference' (New-CpuState) $cpuAssert {param($Path,$Body,$TimeoutMs)if($Path -ceq '/v1/chat/completions' -and $Body.messages[0].content -ceq $g3Case.prompt){$script:requests++;return (New-GenerationResponse '869' 'length' $true)};& $std $Path $Body $TimeoutMs} 'g3-truncated'
    Check ($g3Trunc.g3Passed -eq $false -and $g3Trunc.valid -eq $false -and $g3Trunc.g3.grade -ceq 'inconclusive') 'G3 truncation counted as pass'
    Reset-Counters
    $std=New-StandardRequest
    $noLogprobs=Invoke-Core 'CpuReference' (New-CpuState) $cpuAssert {param($Path,$Body,$TimeoutMs)if($Path -ceq '/v1/chat/completions' -and $Body.messages[0].content -ceq $g3Case.prompt){$script:requests++;return (New-GenerationResponse '869')};& $std $Path $Body $TimeoutMs} 'g3-no-logprobs'
    Check ($noLogprobs.g3.strictPass -eq $true -and $noLogprobs.g3.logprobStatus -ceq 'missing' -and @($noLogprobs.g3.positions).Count -eq 0 -and $noLogprobs.reportStatus -ceq 'complete') 'missing logprobs not recorded as such'
    Reset-Counters
    $g1Incon=Invoke-Core 'CpuReference' (New-CpuState) $cpuAssert {param($Path,$Body,$TimeoutMs)if($Path -ceq '/v1/chat/completions' -and $Body.messages[0].content -ceq $g1Case.prompt -and $null -eq $Body.PSObject.Properties['logprobs']){$script:requests++;return [pscustomobject]@{Status=200;Body='not-json'}};& $std $Path $Body $TimeoutMs} 'g1-malformed'
    Check ($script:requests -eq 5 -and $g1Incon.g1.grade -ceq 'inconclusive' -and $g1Incon.reportStatus -ceq 'complete' -and $g1Incon.g3Passed -eq $true) 'inconclusive G1 stopped later steps'

    # --- Process-identity change ---
    Reset-Counters
    $script:cpuBase=New-CpuState
    $identity=Invoke-Core 'CpuReference' $script:cpuBase $cpuAssert (New-StandardRequest) 'identity-run' 30 5 {
        $script:reads++
        if($script:reads -ge 7){$changed=New-CpuState;$changed.runId=('f'*32);return $changed}
        $script:state}
    Check ($script:requests -eq 2 -and $identity.reportStatus -ceq 'aborted' -and $identity.failureCode -ceq 'identity-changed' -and $identity.bindingStatus -ceq 'compromised' -and
        $identity.t1.status -ceq 'captured' -and $identity.t2.status -ceq 'captured' -and $identity.g1.status -ceq 'aborted' -and $null -eq $identity.g2) 'identity change before G1 did not abort with partial report'
    Reset-Counters
    $mid=Invoke-Core 'CpuReference' (New-CpuState) $cpuAssert (New-StandardRequest) 'identity-process' 30 5 {$script:reads++;$script:state} {
        param($S)$script:reads++;if($script:reads -ge 9){throw 'pid or start ticks changed'}}
    Check ($mid.failureCode -ceq 'identity-changed' -and $mid.reportStatus -ceq 'aborted' -and $script:requests -le 3 -and $mid.valid -eq $false) 'process-check failure did not abort'
    Reset-Counters
    $postChange=Invoke-Core 'CpuReference' (New-CpuState) $cpuAssert (New-StandardRequest) 'identity-post' 30 5 {
        $script:reads++
        if($script:reads -eq 4){$changed=New-CpuState;$changed.processIdentity.startUtcTicks=638000000000000099;return $changed}
        $script:state}
    Check ($script:requests -eq 1 -and $postChange.failureCode -ceq 'identity-changed' -and $postChange.t1.status -ceq 'aborted' -and -not (([IO.File]::ReadAllText((Join-Path $root 'identity-post.json'))).Contains('SYNTHETIC'))) 'result issued under a changed identity was kept'

    # --- Hash mismatch aborts before any request ---
    Reset-Counters
    $hashState=New-CpuState;$hashState.recipe.catalogSha256=('1'*64)
    $hash=Invoke-Core 'CpuReference' $hashState $cpuAssert (New-StandardRequest) 'hash-mismatch'
    Check ($script:requests -eq 0 -and $hash.reportStatus -ceq 'aborted' -and $hash.failureCode -ceq 'hash-mismatch' -and $hash.bindingStatus -ceq 'compromised' -and $null -eq $hash.t1) 'hash mismatch did not stop before any request'
    Reset-Counters
    $engineState=New-CpuState;$engineState.recipe.engineSha256=('2'*64)
    $engine=Invoke-Core 'CpuReference' $engineState $cpuAssert (New-StandardRequest) 'engine-mismatch'
    Check ($engine.failureCode -ceq 'hash-mismatch' -and $script:requests -eq 0) 'engine hash mismatch did not abort'
    Reset-Counters
    $modelState=New-CpuState;$modelState.modelSha256=('3'*64)
    $model=Invoke-Core 'CpuReference' $modelState $cpuAssert (New-StandardRequest) 'model-mismatch'
    Check ($model.failureCode -ceq 'hash-mismatch' -and $script:requests -eq 0) 'model hash mismatch did not abort'

    # --- Source change ---
    $savedHashes=(Get-Command Get-FastLlmBackendParitySourceHashes).ScriptBlock
    try{
        $script:sourceReads=0;Reset-Counters
        Set-Item Function:Get-FastLlmBackendParitySourceHashes -Value {
            param($ToolSourcePath,$TaskQualityToolSourcePath)
            $script:sourceReads++
            [ordered]@{diagnostic=$(if($script:sourceReads -ge 5){'f'*64}else{'e'*64})}
        }
        $sourceChanged=Invoke-Core 'CpuReference' (New-CpuState) $cpuAssert (New-StandardRequest) 'source-change'
        Check ($sourceChanged.failureCode -ceq 'source-changed' -and $sourceChanged.reportStatus -ceq 'aborted' -and $sourceChanged.sourceProvenance.endStatus -ceq 'changed' -and $script:requests -le 2) 'source change did not abort'
    }finally{Set-Item Function:Get-FastLlmBackendParitySourceHashes -Value $savedHashes}

    # --- Deadline ---
    Reset-Counters
    $deadline=Invoke-Core 'CpuReference' (New-CpuState) $cpuAssert {param($Path,$Body,$TimeoutMs)$script:requests++;Start-Sleep -Milliseconds 1100;New-TemplateResponse $syntheticPrompt} 'deadline' 1 1
    Check ($script:requests -eq 1 -and $deadline.failureCode -ceq 'deadline' -and $deadline.reportStatus -ceq 'aborted' -and $deadline.t1.status -ceq 'aborted' -and $null -eq $deadline.t2) 'elapsed deadline was not enforced'
    Reset-Counters
    $std=New-StandardRequest
    $partial=Invoke-Core 'CpuReference' (New-CpuState) $cpuAssert {param($Path,$Body,$TimeoutMs)if($script:requests -eq 2){Start-Sleep -Milliseconds 1300};& $std $Path $Body $TimeoutMs} 'deadline-partial' 1 1
    Check ($partial.failureCode -ceq 'deadline' -and $partial.t1.status -ceq 'captured' -and $partial.t2.status -ceq 'captured' -and $partial.g1.status -ceq 'aborted' -and $partial.valid -eq $false) 'deadline abort lost earlier rows'
    Check (Test-Path -LiteralPath (Join-Path $root 'deadline-partial.json') -PathType Leaf) 'partial report was not written'

    # --- Abort precedence ---
    Reset-Counters
    $script:precedenceRead=0
    $precedence=Invoke-Core 'CpuReference' (New-CpuState) $cpuAssert {param($Path,$Body,$TimeoutMs)$script:requests++;[pscustomobject]@{Status=503;Body=''}} 'precedence' 30 5 {
        $script:precedenceRead++
        if($script:precedenceRead -ge 4){$changed=New-CpuState;$changed.runId=('e'*32);return $changed}
        $script:state}
    Check ($precedence.failureCode -ceq 'identity-changed' -and $precedence.bindingStatus -ceq 'compromised') 'identity change did not take precedence over a transport status'
    Reset-Counters
    $deadlinePrecedence=Invoke-Core 'CpuReference' (New-CpuState) $cpuAssert {param($Path,$Body,$TimeoutMs)$script:requests++;Start-Sleep -Milliseconds 1100;[pscustomobject]@{Status=503;Body=''}} 'precedence-deadline' 1 1
    Check ($deadlinePrecedence.failureCode -ceq 'deadline') 'deadline did not take precedence over http status'

    # --- Report carries startup diagnostics and the pin state (S3, S5) ---
    Reset-Counters
    $cpuStartup=Invoke-Core 'CpuReference' (New-CpuState) $cpuAssert (New-StandardRequest) 'startup-cpu'
    Check ($cpuStartup.startupDiagnostics.reportedFlashAttentionMode -ceq 'auto' -and $cpuStartup.startupDiagnostics.reportedFlashAttentionResolved -eq $true) 'CPU startup diagnostics not copied into the report'
    Reset-Counters
    $normalStartup=Invoke-Core 'Normal' (New-NormalState) $normalAssert (New-StandardRequest '63' '63' '869') 'startup-normal'
    Check ($normalStartup.startupDiagnostics.reportedFlashAttentionMode -ceq 'auto' -and $normalStartup.startupDiagnostics.reportedFlashAttentionResolved -eq $true) 'Normal startup diagnostics not copied into the report'
    $noStartup=New-CpuState;$noStartup.PSObject.Properties.Remove('startupDiagnostics')
    Reset-Counters
    $noStartupReport=Invoke-Core 'CpuReference' $noStartup $cpuAssert (New-StandardRequest) 'startup-missing'
    Check ($null -eq $noStartupReport.startupDiagnostics -and $noStartupReport.reportStatus -ceq 'complete') 'a state without startup diagnostics broke the report'
    $isDesktop=($PSVersionTable.PSEdition -ceq 'Desktop')
    Check ($cpuStartup.historicalBodyPinEnforced -eq $isDesktop -and $cpuStartup.historicalBodyPinVerified -eq $isDesktop) 'pin was enforced or verified on the wrong PowerShell edition'

    # --- S5: pins enforced under Desktop only; a mismatch aborts before any request ---
    $savedConstants=(Get-Command Get-FastLlmBackendParityConstants).ScriptBlock
    try{
        Reset-Counters
        Set-Item Function:Get-FastLlmBackendParityConstants -Value {$c=& $savedConstants;$c['historicalG1BodySha256']=('0'*64);$c}
        $pinBad=Invoke-Core 'CpuReference' (New-CpuState) $cpuAssert (New-StandardRequest) 'pin-g1-bad' 30 5 $null $null 'Desktop'
        Check ($script:requests -eq 0 -and $pinBad.reportStatus -ceq 'aborted' -and $pinBad.failureCode -ceq 'historical-body-mismatch' -and $pinBad.historicalBodyPinVerified -eq $false -and $null -eq $pinBad.t1) 'G1 pin mismatch did not abort before any request'
        Set-Item Function:Get-FastLlmBackendParityConstants -Value {$c=& $savedConstants;$c['historicalG3BaseBodySha256']=('0'*64);$c}
        Reset-Counters
        $pinBad3=Invoke-Core 'CpuReference' (New-CpuState) $cpuAssert (New-StandardRequest) 'pin-g3-bad' 30 5 $null $null 'Desktop'
        Check ($script:requests -eq 0 -and $pinBad3.failureCode -ceq 'historical-body-mismatch') 'G3 pin mismatch did not abort before any request'
        # Not enforced under Core, even with a deliberately wrong pin.
        Reset-Counters
        $pinCore=Invoke-Core 'CpuReference' (New-CpuState) $cpuAssert (New-StandardRequest) 'pin-core' 30 5 $null $null 'Core'
        Check ($pinCore.reportStatus -ceq 'complete' -and $pinCore.historicalBodyPinEnforced -eq $false -and $pinCore.historicalBodyPinVerified -eq $false) 'pin was enforced on Core'
        # Correct pins computed from the real constructor pass under Desktop on either host.
        $pinState=New-CpuState
        $g1Pin=Get-FastLlmTaskWorkloadSha256 -Text (New-TaskQualityRequestBody -State $pinState -Case $g1Case)
        $g3Pin=Get-FastLlmTaskWorkloadSha256 -Text (ConvertTo-Json -InputObject (ConvertFrom-Json -InputObject (New-TaskQualityRequestBody -State $pinState -Case $g3Case)) -Depth 12 -Compress)
        $script:pinG1=$g1Pin;$script:pinG3=$g3Pin
        Set-Item Function:Get-FastLlmBackendParityConstants -Value {$c=& $savedConstants;$c['historicalG1BodySha256']=$script:pinG1;$c['historicalG3BaseBodySha256']=$script:pinG3;$c}
        Reset-Counters
        $pinGood=Invoke-Core 'CpuReference' (New-CpuState) $cpuAssert (New-StandardRequest) 'pin-good' 30 5 $null $null 'Desktop'
        Check ($pinGood.reportStatus -ceq 'complete' -and $pinGood.historicalBodyPinEnforced -eq $true -and $pinGood.historicalBodyPinVerified -eq $true) 'matching pins did not verify'
    }finally{Set-Item Function:Get-FastLlmBackendParityConstants -Value $savedConstants}
    $constantsNow=Get-FastLlmBackendParityConstants
    Check ($constantsNow.historicalG1BodySha256 -ceq 'df1fdf9d97e6dc7efbc084b0489a5fc0f9448c6eb2ba4f29fb5d2eac1a869ecd' -and
        $constantsNow.historicalG3BaseBodySha256 -ceq '0e9e11773ad8523adfff73f01a6c496c817c92594a9be6031e1592d11e59cdd4') 'historical body pins changed'

    # --- S7: hashes are checked before the state assertion ---
    Reset-Counters
    $hashFirst=New-CpuState;$hashFirst.recipe.catalogSha256=('1'*64)
    $hashFirstReport=Invoke-Core 'CpuReference' $hashFirst {param($S,$E)throw 'the state assertion must not run before the hash check'} (New-StandardRequest) 'hash-before-assert'
    Check ($script:requests -eq 0 -and $hashFirstReport.failureCode -ceq 'hash-mismatch' -and $hashFirstReport.reportStatus -ceq 'aborted' -and $null -eq $hashFirstReport.evidenceBindingSha256) 'hash mismatch did not precede the state assertion'
    # A hash that changes mid-run is a hash-mismatch, not an identity change.
    Reset-Counters
    $script:midRead=0
    $midHash=Invoke-Core 'CpuReference' (New-CpuState) $cpuAssert (New-StandardRequest) 'hash-mid' 30 5 {
        $script:midRead++
        if($script:midRead -ge 5){$changed=New-CpuState;$changed.modelSha256=('4'*64);return $changed}
        $script:state}
    Check ($midHash.failureCode -ceq 'hash-mismatch' -and $midHash.reportStatus -ceq 'aborted' -and $midHash.bindingStatus -ceq 'compromised') 'mid-run hash change not reported as hash-mismatch'

    # --- S6: Arm V recipe checks (sampler diagnostic parity) ---
    $normalMutations=[ordered]@{
        'device'={param($s)$s.recipe.requestedArguments=@($s.recipe.requestedArguments | ForEach-Object {if($_ -ceq 'Vulkan0'){'Vulkan1'}else{$_}})}
        'split mode arg'={param($s)$s.recipe.requestedArguments=@($s.recipe.requestedArguments | ForEach-Object {if($_ -ceq 'none'){'layer'}else{$_}})}
        'split mode state'={param($s)$s.recipe.splitMode='layer'}
        'tensor split arg'={param($s)$s.recipe.requestedArguments=@($s.recipe.requestedArguments)+@('--tensor-split','1,1')}
        'tensor split state'={param($s)$s.recipe.tensorSplit='1,1'}
        'fit target'={param($s)$s.recipe.requestedArguments=@($s.recipe.requestedArguments | ForEach-Object {if($_ -ceq '768'){'512'}else{$_}})}
        'two adapters'={param($s)$s.recipe.adapters=@($s.recipe.adapters)+@($s.recipe.adapters[0])}
        'adapter name'={param($s)$s.recipe.adapters[0].name='AMD Radeon RX 7900 XT'}
        'adapter vendor'={param($s)$s.recipe.adapters[0].vendorId='10de'}
        'adapter integrated'={param($s)$s.recipe.adapters[0].isIntegrated=$true}
        'adapter device'={param($s)$s.recipe.adapters[0].device='Vulkan1'}
        'placement devices extra'={param($s)$s.placement.devices=@('Vulkan0','Vulkan1')}
        'placement devices other'={param($s)$s.placement.devices=@('Vulkan1')}
        'missing metrics'={param($s)$s.recipe.requestedArguments=@($s.recipe.requestedArguments | Where-Object {$_ -cne '--metrics'})}
        'cpu offload flag'={param($s)$s.recipe.requestedArguments=@($s.recipe.requestedArguments)+@('--no-op-offload')}
    }
    Assert-FastLlmBackendParityNormalRecipe -State (New-NormalState)
    foreach($name in $normalMutations.Keys){
        $mutant=New-NormalState
        & $normalMutations[$name] $mutant
        Fails {Assert-FastLlmBackendParityNormalRecipe -State $mutant} "Arm V recipe accepted mutation: $name"
    }

    # --- Output protection ---
    Fails {Invoke-Core 'CpuReference' (New-CpuState) $cpuAssert (New-StandardRequest) 'cpu-complete'} 'existing output was overwritten'

    # --- Module-scope integration, as the tool loads it ---
    $module=Import-Module (Join-Path $repoRoot 'src/FastLlm.psm1') -Force -PassThru
    $moduleOut=Join-Path $root 'module.json'
    $moduleResult=& $module {
        param($Semantic,$Workload,$TaskQuality,$CpuLab,$Diagnostic,$Tool,$Output,$State,$Request)
        . $Semantic;. $Workload;. $TaskQuality -OutputPath $Output;. $CpuLab;. $Diagnostic
        Invoke-FastLlmBackendParityCore -OutputPath $Output -Target CpuReference -ToolSourcePath $Tool -TaskQualityToolSourcePath $TaskQuality `
            -DeadlineSeconds 30 -RequestTimeoutSeconds 5 -ReadState {$State} `
            -AssertState {param($S,$E) Assert-FastLlmCpuReferenceState -State $S -ExpectedBinding $E} `
            -CheckProcess {param($S)} -Request $Request
    } $semantic $workload $taskQuality $cpuLab $diagnostic $tool $moduleOut (New-CpuState) (New-StandardRequest '64' '64' '869')
    Check ($moduleResult.reportStatus -ceq 'complete' -and $moduleResult.valid -eq $true) 'imported-module integration failed'
    Write-Host "PASS: $script:checks backend parity diagnostic focused assertions. No engine or model invoked."
}finally{
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
}
