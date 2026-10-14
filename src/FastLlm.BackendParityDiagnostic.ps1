# Private Qwen3.8-27B Q4 backend-parity diagnostic (Vulkan vs CPU reference), declared protocol
# docs/research/QWEN38-BACKEND-PARITY-PROTOCOL-2026-10-06.md. One request sequence (T1, T2, G1, G2, G3) against one
# already-Ready server: the normal run on 127.0.0.1:8080 (-Target Normal) or the CPU-reference lab (-Target CpuReference).
# It reuses the unchanged task-quality request constructor and strict grader. It retains only the bounded fields the
# protocol declares and makes no throughput, quality, GDN or general-correctness claim.
function Get-FastLlmBackendParityConstants {
    return [ordered]@{
        protocolVersion='qwen38-backend-parity-v1'
        modelId='qwen3.8-27b-ud-q4-k-m';contextSize=32768
        catalogSha256='65b8f2f9ca340dab273274086aba9e8f01cb14a2b8cf4bb65c5ed5f6e779caa6'
        engineSha256='9f4dd930c50cdd3f7946b679ff67eaa124343096abdb56f2978199cf035758c7'
        modelSha256='322e194ff79741c7baa497c240f677f54b201b0efab44ca8e50f122b39123482'
        # Expected rendered-prompt hash and the 50 prompt token IDs come from an offline first-party render and tokenizer
        # check of the arithmetic-steps-v1 prompt (non-thinking template); they are protocol constants, not runtime values.
        renderedPromptSha256='0de01e9758e7469fbbf649a3d529d756ccb8bcc0d937538633155ca18c20c41c'
        promptTokenIds=@(248045,846,198,44712,318,23,19,17249,539,220,22,5346,220,24,8,2942,220,18,11,1608,279,71458,430,5158,13,
            8984,1132,279,12571,2255,12,16,15,7308,13,198,2665,7896,466,15673,13,248046,198,248045,74455,198,248068,271,248069,271)
        # Historical request-body pins, enforced only under Windows PowerShell 5.1 ('Desktop'): hashtable key order is
        # randomized per process in PowerShell 7, so those hashes are not reproducible there.
        historicalG1BodySha256='df1fdf9d97e6dc7efbc084b0489a5fc0f9448c6eb2ba4f29fb5d2eac1a869ecd'
        historicalG3BaseBodySha256='0e9e11773ad8523adfff73f01a6c496c817c92594a9be6031e1592d11e59cdd4'
        maxRetainedPromptChars=4096;maxTokenIds=1024;maxPieceChars=32;topLogprobs=10;retainedPositions=4
        normalDeadlineSeconds=180;cpuDeadlineSeconds=1200;normalRequestTimeoutSeconds=60;cpuRequestTimeoutSeconds=300
    }
}

function Get-FastLlmBackendParitySourceHashes {
    param([Parameter(Mandatory=$true)][string]$ToolSourcePath,
          [Parameter(Mandatory=$true)][string]$TaskQualityToolSourcePath)
    $paths=[ordered]@{
        diagnostic=(Join-Path $PSScriptRoot 'FastLlm.BackendParityDiagnostic.ps1')
        tool=$ToolSourcePath
        taskQualityParser=$TaskQualityToolSourcePath
        cpuReferenceLab=(Join-Path $PSScriptRoot 'FastLlm.CpuReferenceLab.ps1')
        workload=(Join-Path $PSScriptRoot 'FastLlm.TaskWorkload.ps1')
        semanticSmoke=(Join-Path $PSScriptRoot 'FastLlm.SemanticSmoke.ps1')
        module=(Join-Path $PSScriptRoot 'FastLlm.psm1')
        benchmark=(Join-Path $PSScriptRoot 'FastLlm.Benchmark.ps1')
        runtime=(Join-Path $PSScriptRoot 'FastLlm.Runtime.ps1')
        httpHost=(Join-Path $PSScriptRoot 'ProcessHost.cs')
        listener=(Join-Path $PSScriptRoot 'WindowsGpuTelemetry.cs')
    }
    $hashes=[ordered]@{}
    foreach($key in $paths.Keys){
        $item=Get-Item -LiteralPath $paths[$key] -Force -ErrorAction Stop
        if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){
            throw 'Backend parity diagnostic source is unsafe.'
        }
        $hashes[$key]=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    return $hashes
}

function Test-FastLlmBackendParitySourceHashes {
    param($Expected,[string]$ToolSourcePath,[string]$TaskQualityToolSourcePath)
    try{
        $current=Get-FastLlmBackendParitySourceHashes -ToolSourcePath $ToolSourcePath `
            -TaskQualityToolSourcePath $TaskQualityToolSourcePath
        if(@($current.Keys).Count -ne @($Expected.Keys).Count){return $false}
        foreach($key in $Expected.Keys){
            if(-not $current.Contains($key) -or [string]$current[$key] -cne [string]$Expected[$key]){return $false}
        }
        return $true
    }catch{return $false}
}

function Get-FastLlmBackendParityCases {
    $cases=@(Get-FastLlmTaskWorkloadCases -DistractorCount 0)
    Assert-TaskQualityCases -Cases $cases -DistractorCount 0
    $identities=@{
        'arithmetic-steps-v1'='8075c10d5c487b7976efbbb22ef8d50fcef17697aa6b12559945459d1c04c028:3f6195f88d915f645e3a63eab36fed5bfc54e67f80152c1e178e359b7bb7eef9:63'
        'arithmetic-invoice-v1'='a239eca38f916a456a7dd46e355142662a6a4f9c9921b89306e00d1f6de0d6de:2963f23b5d79371ea1a4b66617a977b69f127c8d3088c018128b41427304516d:869'
    }
    $selected=[ordered]@{}
    foreach($id in @('arithmetic-steps-v1','arithmetic-invoice-v1')){
        $match=@($cases | Where-Object {$_.id -ceq $id})
        if($match.Count -ne 1){throw 'The fixed parity task differs from the canonical workload.'}
        $case=$match[0]
        $actual=(Get-FastLlmTaskWorkloadPromptSha256 -Case $case)+':'+(Get-FastLlmTaskWorkloadReferenceSha256 -Case $case)+':'+[string]$case.expected
        if($case.suiteVersion -cne (Get-FastLlmTaskWorkloadSuiteVersion) -or $case.kind -cne 'arithmetic' -or
           [int]$case.maxOutputTokens -ne 32 -or $null -ne $case.responseFormat -or [int]$case.distractorCount -ne 0 -or
           $case.gradingNormalization -cne 'trim-leading-trailing-whitespace-only' -or $actual -cne $identities[$id]){
            throw 'The fixed parity task differs from the canonical workload.'
        }
        $selected[$id]=$case
    }
    return $selected
}

function ConvertTo-FastLlmBackendParityAnswer {
    # Bounded answer retention: the trimmed content is kept only if it is an optionally negative integer of 1 to 6
    # digits. Anything else keeps only a coarse classification and the character length.
    param($Content)
    if($Content -isnot [string]){
        return [pscustomobject][ordered]@{classification='missing';value=$null;length=0}
    }
    $trimmed=$Content.Trim()
    $kind='non-integer'
    if($trimmed.Length -eq 0){$kind='empty'}
    elseif($trimmed -cmatch '\A-?[0-9]{1,6}\z'){$kind='integer'}
    elseif($trimmed -cmatch '\A-?[0-9]+\z'){$kind='integer-too-long'}
    return [pscustomobject][ordered]@{
        classification=$kind;value=$(if($kind -ceq 'integer'){$trimmed}else{$null});length=[int]$Content.Length
    }
}

function Test-FastLlmBackendParityTimeoutException {
    # Classified by exception type along the inner-exception chain, never by message text.
    param($Exception)
    $current=$Exception
    for($depth=0;$depth -lt 6 -and $null -ne $current;$depth++){
        if($current -is [System.TimeoutException] -or $current -is [System.OperationCanceledException]){return $true}
        if($current -is [System.Net.WebException] -and
           ($current.Status -eq [System.Net.WebExceptionStatus]::Timeout -or $current.Status -eq [System.Net.WebExceptionStatus]::RequestCanceled)){return $true}
        $current=$current.InnerException
    }
    return $false
}

function ConvertTo-FastLlmBackendParityPiece {
    # The protocol keeps single digits, '-' and '<|im_end|>'. The server renders special tokens as empty strings, so
    # '<|im_end|>' is not expected to occur; the protocol-literal exception is kept, and anything else is '<other>'.
    param($Token)
    if($Token -is [string] -and ($Token -cmatch '\A[0-9]\z' -or $Token -ceq '-' -or $Token -ceq '<|im_end|>')){return $Token}
    return '<other>'
}

function ConvertTo-FastLlmBackendParityNumber {
    param($Value)
    if($Value -is [bool]){return $null}
    if($Value -isnot [double] -and $Value -isnot [int] -and $Value -isnot [long] -and $Value -isnot [decimal] -and $Value -isnot [single]){return $null}
    $number=[double]$Value
    if([double]::IsNaN($number) -or [double]::IsInfinity($number)){return $null}
    return [Math]::Round($number,4,[MidpointRounding]::AwayFromZero)
}

function Get-FastLlmBackendParityLogprobs {
    # First four generated positions: redacted sampled piece plus top-10 alternatives, four-decimal rounding.
    param([string]$Body)
    $constants=Get-FastLlmBackendParityConstants
    $result=[ordered]@{status='missing';positions=@()}
    try{$data=ConvertFrom-Json -InputObject $Body -ErrorAction Stop}catch{$result.status='malformed';return [pscustomobject]$result}
    $choices=if($null -ne $data){$data.PSObject.Properties['choices']}else{$null}
    if(-not $choices -or @($choices.Value).Count -ne 1){$result.status='malformed';return [pscustomobject]$result}
    $choice=@($choices.Value)[0]
    $logprobs=if($null -ne $choice){$choice.PSObject.Properties['logprobs']}else{$null}
    if(-not $logprobs -or $null -eq $logprobs.Value){return [pscustomobject]$result}
    $content=$logprobs.Value.PSObject.Properties['content']
    if(-not $content -or $null -eq $content.Value){return [pscustomobject]$result}
    $items=@($content.Value)
    if($items.Count -eq 0){$result.status='empty';return [pscustomobject]$result}
    $positions=@()
    $limit=[Math]::Min([int]$constants.retainedPositions,$items.Count)
    for($i=0;$i -lt $limit;$i++){
        $item=$items[$i]
        $tokenProperty=if($null -ne $item){$item.PSObject.Properties['token']}else{$null}
        $logprobProperty=if($null -ne $item){$item.PSObject.Properties['logprob']}else{$null}
        $topProperty=if($null -ne $item){$item.PSObject.Properties['top_logprobs']}else{$null}
        if(-not $tokenProperty -or -not $logprobProperty -or -not $topProperty){$result.status='malformed';return [pscustomobject]$result}
        $alternatives=@()
        $best=$null
        foreach($alternative in @($topProperty.Value | Select-Object -First ([int]$constants.topLogprobs))){
            $altToken=if($null -ne $alternative){$alternative.PSObject.Properties['token']}else{$null}
            $altLogprob=if($null -ne $alternative){$alternative.PSObject.Properties['logprob']}else{$null}
            if(-not $altToken -or -not $altLogprob){$result.status='malformed';return [pscustomobject]$result}
            $number=ConvertTo-FastLlmBackendParityNumber $altLogprob.Value
            $entry=[pscustomobject][ordered]@{piece=(ConvertTo-FastLlmBackendParityPiece $altToken.Value);logprob=$number}
            $alternatives+=$entry
            if($null -ne $number -and ($null -eq $best -or $number -gt $best.logprob)){$best=$entry}
        }
        $positions+=[pscustomobject][ordered]@{
            position=($i+1);sampledPiece=(ConvertTo-FastLlmBackendParityPiece $tokenProperty.Value)
            sampledLogprob=(ConvertTo-FastLlmBackendParityNumber $logprobProperty.Value)
            top1Piece=$(if($null -ne $best){$best.piece}else{$null});top1Logprob=$(if($null -ne $best){$best.logprob}else{$null})
            top=@($alternatives)
        }
    }
    $result.status='captured';$result.positions=@($positions)
    return [pscustomobject]$result
}

function ConvertFrom-FastLlmBackendParityTemplate {
    param($Response,[string]$ExpectedSha256)
    $row=[ordered]@{status='invalid-response';httpStatus=$null;renderedPrompt=$null;renderedPromptRetained=$false
        renderedPromptLength=$null;renderedPromptSha256=$null;matchesLocalRender=$false}
    if($null -eq $Response){return [pscustomobject]$row}
    if($Response.Status -isnot [int] -and $Response.Status -isnot [long]){return [pscustomobject]$row}
    $row.httpStatus=[int]$Response.Status
    if($row.httpStatus -ne 200){$row.status='http-status';return [pscustomobject]$row}
    if($Response.Body -isnot [string] -or $Response.Body.Length -gt 1048576){return [pscustomobject]$row}
    try{$data=ConvertFrom-Json -InputObject $Response.Body -ErrorAction Stop}catch{return [pscustomobject]$row}
    $prompt=if($null -ne $data){$data.PSObject.Properties['prompt']}else{$null}
    if(-not $prompt -or $prompt.Value -isnot [string] -or $prompt.Value.Length -eq 0){return [pscustomobject]$row}
    $constants=Get-FastLlmBackendParityConstants
    $row.status='captured'
    $row.renderedPromptLength=[int]$prompt.Value.Length
    $row.renderedPromptSha256=Get-FastLlmTaskWorkloadSha256 -Text $prompt.Value
    $row.matchesLocalRender=($row.renderedPromptSha256 -ceq $ExpectedSha256)
    if($prompt.Value.Length -le [int]$constants.maxRetainedPromptChars){
        $row.renderedPrompt=$prompt.Value;$row.renderedPromptRetained=$true
    }
    return [pscustomobject]$row
}

function ConvertFrom-FastLlmBackendParityTokenize {
    param($Response,[int[]]$ExpectedIds)
    $row=[ordered]@{status='invalid-response';httpStatus=$null;tokenCount=$null;tokenIds=@();pieces=@();matchesLocalTokenIds=$false}
    if($null -eq $Response){return [pscustomobject]$row}
    if($Response.Status -isnot [int] -and $Response.Status -isnot [long]){return [pscustomobject]$row}
    $row.httpStatus=[int]$Response.Status
    if($row.httpStatus -ne 200){$row.status='http-status';return [pscustomobject]$row}
    if($Response.Body -isnot [string] -or $Response.Body.Length -gt 1048576){return [pscustomobject]$row}
    try{$data=ConvertFrom-Json -InputObject $Response.Body -ErrorAction Stop}catch{return [pscustomobject]$row}
    $tokens=if($null -ne $data){$data.PSObject.Properties['tokens']}else{$null}
    if(-not $tokens -or $null -eq $tokens.Value){return [pscustomobject]$row}
    $constants=Get-FastLlmBackendParityConstants
    $items=@($tokens.Value)
    if($items.Count -eq 0 -or $items.Count -gt [int]$constants.maxTokenIds){return [pscustomobject]$row}
    $ids=@();$pieces=@()
    foreach($item in $items){
        $idProperty=if($null -ne $item){$item.PSObject.Properties['id']}else{$null}
        $pieceProperty=if($null -ne $item){$item.PSObject.Properties['piece']}else{$null}
        if(-not $idProperty -or $idProperty.Value -is [bool] -or ($idProperty.Value -isnot [int] -and $idProperty.Value -isnot [long]) -or
           [long]$idProperty.Value -lt 0 -or [long]$idProperty.Value -gt 100000000 -or -not $pieceProperty){return [pscustomobject]$row}
        $ids+=[int]$idProperty.Value
        if($pieceProperty.Value -is [string]){
            $pieces+=$(if($pieceProperty.Value.Length -le [int]$constants.maxPieceChars){[string]$pieceProperty.Value}else{'<long>'})
        }else{$pieces+='<bytes>'}
    }
    $row.status='captured';$row.tokenCount=$ids.Count;$row.tokenIds=@($ids);$row.pieces=@($pieces)
    $row.matchesLocalTokenIds=(@($ids).Count -eq @($ExpectedIds).Count -and (@($ids) -join ',') -ceq (@($ExpectedIds) -join ','))
    return [pscustomobject]$row
}

function Get-FastLlmBackendParityGenerationRow {
    param([string]$Step,$Case,$Response,[string]$RequestBodySha256,[bool]$LogprobsRequested,[int]$EffectiveContext)
    $strict=ConvertFrom-TaskQualityResponse -Response $Response -Case $Case -EffectiveContext $EffectiveContext
    $answer=ConvertTo-FastLlmBackendParityAnswer -Content $null
    $logprobs=$null
    $httpOk=($null -ne $Response -and $Response.Status -eq 200 -and $Response.Body -is [string])
    if($httpOk){
        try{
            $body=ConvertFrom-Json -InputObject ([string]$Response.Body) -ErrorAction Stop
            $choices=if($null -ne $body){$body.PSObject.Properties['choices']}else{$null}
            if($choices -and @($choices.Value).Count -eq 1){
                $message=@($choices.Value)[0].PSObject.Properties['message']
                if($message -and $null -ne $message.Value){
                    $contentProperty=$message.Value.PSObject.Properties['content']
                    if($contentProperty){$answer=ConvertTo-FastLlmBackendParityAnswer -Content $contentProperty.Value}
                }
            }
        }catch{
            # Keep the strict result. Never retain response text.
        }
        if($LogprobsRequested){$logprobs=Get-FastLlmBackendParityLogprobs -Body ([string]$Response.Body)}
    }
    $row=[ordered]@{
        step=$Step;caseId=[string]$Case.id;expected=[string]$Case.expected;requestBodySha256=$RequestBodySha256
        logprobsRequested=$LogprobsRequested
        httpStatus=$strict.httpStatus;finishReason=$strict.finishReason
        actualPromptTokens=$strict.actualPromptTokens;actualOutputTokens=$strict.actualOutputTokens
        grade=$strict.grade;errorCode=$strict.errorCode;strictClassification=$strict.classification
        strictPass=($strict.grade -ceq 'correct')
        answer=$answer;answerMatchesExpected=($answer.classification -ceq 'integer' -and $answer.value -ceq [string]$Case.expected)
    }
    if($LogprobsRequested){$row['logprobStatus']=$logprobs.status;$row['positions']=@($logprobs.positions)}
    return [pscustomobject]$row
}

function New-FastLlmBackendParityAbortedRow {
    param([string]$Step,[string]$Code)
    return [pscustomobject][ordered]@{step=$Step;status='aborted';errorCode=$Code;grade='inconclusive'}
}

function Assert-FastLlmBackendParityNormalRecipe {
    # Arm V: the normal supervised Q4 start at 32,768 context, exactly the recipe checks of the sampler diagnostic.
    param($State)
    $constants=Get-FastLlmBackendParityConstants
    if($State.modelId -cne $constants.modelId -or $State.modelSha256 -cne $constants.modelSha256 -or
       [int]$State.recipe.contextSize -ne $constants.contextSize -or [int]$State.recipe.slots -ne 1 -or
       $State.recipe.engineSha256 -cne $constants.engineSha256 -or $State.recipe.catalogSha256 -cne $constants.catalogSha256 -or
       $State.recipe.cacheTypeK -cne 'f16' -or $State.recipe.cacheTypeV -cne 'f16' -or
       $State.recipe.speculation -cne 'none' -or $State.recipe.splitMode -cne 'none' -or
       $State.recipe.flashAttention -cne 'auto' -or $null -ne $State.recipe.tensorSplit -or
       @($State.recipe.adapters).Count -ne 1 -or [string]$State.recipe.adapters[0].device -cne 'Vulkan0' -or
       [string]$State.recipe.adapters[0].name -cne 'AMD Radeon RX 7900 XTX' -or
       [string]$State.recipe.adapters[0].vendorId -cne '1002' -or
       $State.recipe.adapters[0].isAmd -ne $true -or $State.recipe.adapters[0].isIntegrated -ne $false -or
       [string]$State.recipe.adapters[0].backend -cne 'Vulkan' -or
       @($State.placement.devices).Count -ne 1 -or [string]$State.placement.devices[0] -cne 'Vulkan0'){
        throw 'Backend parity Arm V requires the exact normal b10698/Q4/32K/S1/Vulkan0 F16/no-spec recipe.'
    }
    $arguments=@($State.recipe.requestedArguments)
    foreach($pair in @(@('--device','Vulkan0'),@('--split-mode','none'),@('--cache-type-k','f16'),@('--cache-type-v','f16'),
        @('--spec-type','none'),@('--n-gpu-layers','all'),@('--fit','on'),@('--flash-attn','auto'),@('--fit-target','768'),
        @('--cors-origins','localhost'),@('--log-verbosity','4'),@('--model','<verified-model>'),@('--port','8080'))){
        if(-not (Test-FastLlmSemanticSmokeArgument $arguments $pair[0] $pair[1])){throw 'Arm V recipe arguments differ from the normal run.'}
    }
    foreach($flag in @('--offline','--no-mmproj','--jinja','--no-agent','--no-ui','--metrics','--no-cors-credentials')){
        if(@($arguments | Where-Object {$_ -ceq $flag}).Count -ne 1){throw 'Arm V recipe is missing a fixed flag.'}
    }
    if(@($arguments | Where-Object {$_ -ceq '--tensor-split'}).Count -ne 0){throw 'Arm V does not accept tensor splitting.'}
    if(@($arguments | Where-Object {$_ -ceq '--no-kv-offload' -or $_ -ceq '--no-op-offload'}).Count -ne 0){
        throw 'Arm V must not be a CPU-placement run.'
    }
}

function Test-FastLlmBackendParityStateHashes {
    param($State)
    $constants=Get-FastLlmBackendParityConstants
    try{
        return ($State.modelId -ceq $constants.modelId -and $State.modelSha256 -ceq $constants.modelSha256 -and
            $State.recipe.engineSha256 -ceq $constants.engineSha256 -and $State.recipe.catalogSha256 -ceq $constants.catalogSha256 -and
            [int]$State.recipe.contextSize -eq $constants.contextSize -and [int]$State.recipe.slots -eq 1)
    }catch{return $false}
}

function Get-FastLlmBackendParityAbortRank {
    param([string]$Code)
    switch($Code){
        'hash-mismatch'{return 5}
        'historical-body-mismatch'{return 5}
        'identity-changed'{return 4}
        'source-changed'{return 3}
        'deadline'{return 2}
        default{return 1}
    }
}

function Invoke-FastLlmBackendParityCore {
    param([Parameter(Mandatory=$true)][string]$OutputPath,
          [Parameter(Mandatory=$true)][ValidateSet('Normal','CpuReference')][string]$Target,
          [Parameter(Mandatory=$true)][scriptblock]$ReadState,
          [Parameter(Mandatory=$true)][scriptblock]$AssertState,
          [Parameter(Mandatory=$true)][scriptblock]$Request,
          [Parameter(Mandatory=$true)][scriptblock]$CheckProcess,
          [Parameter(Mandatory=$true)][string]$ToolSourcePath,
          [Parameter(Mandatory=$true)][string]$TaskQualityToolSourcePath,
          [ValidateRange(0,1200)][int]$DeadlineSeconds=0,
          [ValidateRange(0,600)][int]$RequestTimeoutSeconds=0,
          [string]$Edition='')
    $constants=Get-FastLlmBackendParityConstants
    if([string]::IsNullOrEmpty($Edition)){$Edition=[string]$PSVersionTable.PSEdition}
    $maxDeadline=$(if($Target -ceq 'Normal'){[int]$constants.normalDeadlineSeconds}else{[int]$constants.cpuDeadlineSeconds})
    if($DeadlineSeconds -eq 0){$DeadlineSeconds=$maxDeadline}
    if($RequestTimeoutSeconds -eq 0){
        $RequestTimeoutSeconds=$(if($Target -ceq 'Normal'){[int]$constants.normalRequestTimeoutSeconds}else{[int]$constants.cpuRequestTimeoutSeconds})
    }
    if($DeadlineSeconds -gt $maxDeadline){throw 'Backend parity deadline exceeds the declared arm deadline.'}
    if($RequestTimeoutSeconds -gt $DeadlineSeconds){throw 'Backend parity request timeout exceeds the arm deadline.'}
    if(Test-Path -LiteralPath $OutputPath){throw 'Backend parity diagnostic output already exists.'}
    $full=[IO.Path]::GetFullPath($OutputPath)
    $parent=Split-Path $full -Parent
    if(-not (Test-Path -LiteralPath $parent -PathType Container)){throw 'Backend parity diagnostic output parent does not exist.'}
    foreach($name in @('Get-FastLlmTaskWorkloadCases','Get-FastLlmTaskWorkloadSuiteVersion','Get-FastLlmTaskWorkloadSha256',
                       'Get-FastLlmTaskWorkloadPromptSha256','Get-FastLlmTaskWorkloadReferenceSha256',
                       'Assert-TaskQualityCases','New-TaskQualityRequestBody','ConvertFrom-TaskQualityResponse')){
        if(-not (Get-Command $name -CommandType Function -ErrorAction SilentlyContinue)){
            throw 'Backend parity diagnostic dependency is unavailable.'
        }
    }
    $source=Get-FastLlmBackendParitySourceHashes -ToolSourcePath $ToolSourcePath -TaskQualityToolSourcePath $TaskQualityToolSourcePath
    $cases=Get-FastLlmBackendParityCases
    $g1Case=$cases['arithmetic-steps-v1'];$g3Case=$cases['arithmetic-invoice-v1']
    $first=& $ReadState
    $abort=$null;$binding=$null
    $contextSize=[int]$constants.contextSize
    $g1Json=$null;$g1Body=$null;$g1BodySha=$null;$g2Body=$null;$g3Body=$null;$t1Body=$null
    $pinEnforced=($Edition -ceq 'Desktop');$pinVerified=$false
    # Hashes are checked before the state assertion, so a mismatch is a recorded abort with zero requests.
    if(-not (Test-FastLlmBackendParityStateHashes -State $first)){$abort='hash-mismatch'}
    else{$binding=& $AssertState $first $null}
    if(-not $abort){
        $contextSize=[int]$first.recipe.contextSize
        # G1 is the historical-exact body. The arithmetic diagnostic sends ConvertFrom-Json(New-TaskQualityRequestBody).
        $g1Json=New-TaskQualityRequestBody -State $first -Case $g1Case
        try{$g1Body=ConvertFrom-Json -InputObject $g1Json -ErrorAction Stop}catch{throw 'Canonical G1 request construction failed.'}
        $g1BodySha=Get-FastLlmTaskWorkloadSha256 -Text $g1Json
        $bodyNames=@($g1Body.PSObject.Properties.Name)
        if($bodyNames.Count -ne 8 -or $null -ne $g1Body.PSObject.Properties['response_format'] -or
           $g1Body.model -cne [string]$first.modelId -or @($g1Body.messages).Count -ne 1 -or
           $g1Body.messages[0].role -cne 'user' -or $g1Body.messages[0].content -cne [string]$g1Case.prompt -or
           [int]$g1Body.max_tokens -ne 32 -or [int]$g1Body.temperature -ne 0 -or [int]$g1Body.seed -ne 42 -or
           $g1Body.stream -ne $false -or $g1Body.cache_prompt -ne $false -or
           $g1Body.chat_template_kwargs.enable_thinking -ne $false -or
           (Get-FastLlmTaskWorkloadSha256 -Text (ConvertTo-Json -InputObject $g1Body -Depth 16 -Compress)) -cne $g1BodySha){
            throw 'G1 request differs from the historical arithmetic diagnostic body.'
        }
        $g2Body=ConvertFrom-Json -InputObject $g1Json
        $g2Body | Add-Member -NotePropertyName logprobs -NotePropertyValue $true
        $g2Body | Add-Member -NotePropertyName top_logprobs -NotePropertyValue ([int]$constants.topLogprobs)
        $g3Json=New-TaskQualityRequestBody -State $first -Case $g3Case
        $g3Body=ConvertFrom-Json -InputObject $g3Json
        if([string]$g3Body.messages[0].content -cne [string]$g3Case.prompt -or [int]$g3Body.max_tokens -ne 32){throw 'G3 request construction changed.'}
        $g3BaseSha=Get-FastLlmTaskWorkloadSha256 -Text (ConvertTo-Json -InputObject $g3Body -Depth 12 -Compress)
        $g3Body | Add-Member -NotePropertyName logprobs -NotePropertyValue $true
        $g3Body | Add-Member -NotePropertyName top_logprobs -NotePropertyValue ([int]$constants.topLogprobs)
        $t1Body=[ordered]@{messages=@([ordered]@{role='user';content=[string]$g1Case.prompt})
            chat_template_kwargs=[ordered]@{enable_thinking=$false}}
        if($pinEnforced){
            if($g1BodySha -ceq $constants.historicalG1BodySha256 -and $g3BaseSha -ceq $constants.historicalG3BaseBodySha256){$pinVerified=$true}
            else{$abort='historical-body-mismatch'}
        }
    }

    $integrity={
        $code=$null
        try{
            $current=& $ReadState
            if(-not (Test-FastLlmBackendParityStateHashes -State $current)){$code='hash-mismatch'}
            else{
                $null=& $AssertState $current $binding
                & $CheckProcess $current
            }
        }catch{$code='identity-changed'}
        if(-not $code -and -not (Test-FastLlmBackendParitySourceHashes -Expected $source -ToolSourcePath $ToolSourcePath `
            -TaskQualityToolSourcePath $TaskQualityToolSourcePath)){$code='source-changed'}
        return $code
    }
    $bindingStatus='verified';$sourceStatus='verified'
    $setAbort={
        param($Current,$Code)
        if($null -eq $Current -or (Get-FastLlmBackendParityAbortRank $Code) -gt (Get-FastLlmBackendParityAbortRank $Current)){return $Code}
        return $Current
    }
    $rows=[ordered]@{T1=$null;T2=$null;G1=$null;G2=$null;G3=$null}
    $issued=0
    $t1Prompt=$null
    $steps=@('T1','T2','G1','G2','G3')
    if(-not $abort){
        $startCode=& $integrity
        if($startCode){$abort=& $setAbort $abort $startCode}
    }
    $clock=[Diagnostics.Stopwatch]::StartNew()
    foreach($step in $steps){
        if($abort){break}
        if($step -ceq 'T2' -and $null -eq $t1Prompt){
            $rows[$step]=[pscustomobject][ordered]@{status='skipped-no-rendered-prompt';httpStatus=$null;tokenCount=$null
                tokenIds=@();pieces=@();matchesLocalTokenIds=$false}
            continue
        }
        $pre=& $integrity
        if($pre){$abort=& $setAbort $abort $pre;$rows[$step]=New-FastLlmBackendParityAbortedRow $step $abort;break}
        $remaining=[int][Math]::Floor(($DeadlineSeconds-$clock.Elapsed.TotalSeconds)*1000)
        if($remaining -le 0){$abort=& $setAbort $abort 'deadline';$rows[$step]=New-FastLlmBackendParityAbortedRow $step $abort;break}
        $path='/v1/chat/completions';$body=$null;$bodySha=$null
        switch($step){
            'T1'{$path='/apply-template';$body=$t1Body}
            'T2'{$path='/tokenize';$body=[ordered]@{content=$t1Prompt;with_pieces=$true;parse_special=$true}}
            'G1'{$body=$g1Body}
            'G2'{$body=$g2Body}
            'G3'{$body=$g3Body}
        }
        if($step -cmatch '\AG'){$bodySha=Get-FastLlmTaskWorkloadSha256 -Text (ConvertTo-Json -InputObject $body -Depth 12 -Compress)}
        $issued++
        $response=$null;$requestCode=$null
        try{$response=& $Request $path $body ([Math]::Min($RequestTimeoutSeconds*1000,$remaining))}
        catch{$requestCode=$(if(Test-FastLlmBackendParityTimeoutException $_.Exception){'timeout'}else{'request-error'})}
        $post=& $integrity
        if($post){$abort=& $setAbort $abort $post}
        if($clock.Elapsed.TotalSeconds -gt $DeadlineSeconds){$abort=& $setAbort $abort 'deadline'}
        if($requestCode){$abort=& $setAbort $abort $requestCode}
        elseif($null -eq $response -or (($response.Status -isnot [int] -and $response.Status -isnot [long]) -or [int]$response.Status -ne 200)){
            $notFound=($null -ne $response -and ($response.Status -is [int] -or $response.Status -is [long]) -and [int]$response.Status -eq 404)
            $abort=& $setAbort $abort $(if($step -cmatch '\AT' -and $notFound){'endpoint-missing'}else{'http-status'})
        }
        if($abort){$rows[$step]=New-FastLlmBackendParityAbortedRow $step $abort;break}
        switch($step){
            'T1'{
                $rows[$step]=ConvertFrom-FastLlmBackendParityTemplate -Response $response -ExpectedSha256 $constants.renderedPromptSha256
                if($rows[$step].status -ceq 'captured'){
                    # The T2 input is the engine's own rendered prompt, retained or not.
                    $t1Prompt=[string](ConvertFrom-Json -InputObject $response.Body).prompt
                }
            }
            'T2'{$rows[$step]=ConvertFrom-FastLlmBackendParityTokenize -Response $response -ExpectedIds @($constants.promptTokenIds)}
            'G1'{$rows[$step]=Get-FastLlmBackendParityGenerationRow -Step 'G1' -Case $g1Case -Response $response -RequestBodySha256 $bodySha -LogprobsRequested $false -EffectiveContext $contextSize}
            'G2'{$rows[$step]=Get-FastLlmBackendParityGenerationRow -Step 'G2' -Case $g1Case -Response $response -RequestBodySha256 $bodySha -LogprobsRequested $true -EffectiveContext $contextSize}
            'G3'{$rows[$step]=Get-FastLlmBackendParityGenerationRow -Step 'G3' -Case $g3Case -Response $response -RequestBodySha256 $bodySha -LogprobsRequested $true -EffectiveContext $contextSize}
        }
    }
    if($abort -ceq 'identity-changed' -or $abort -ceq 'hash-mismatch'){$bindingStatus='compromised'}
    if($abort -ceq 'source-changed'){$sourceStatus='changed'}
    elseif(-not (Test-FastLlmBackendParitySourceHashes -Expected $source -ToolSourcePath $ToolSourcePath -TaskQualityToolSourcePath $TaskQualityToolSourcePath)){
        $sourceStatus='changed'
        if(-not $abort){$abort='source-changed'}
    }
    $reportStatus=$(if($abort){'aborted'}else{'complete'})
    $g3Passed=($null -ne $rows['G3'] -and $rows['G3'].PSObject.Properties['strictPass'] -and $rows['G3'].strictPass -eq $true)
    $t1Retained=($null -ne $rows['T1'] -and $null -ne $rows['T1'].PSObject.Properties['renderedPromptRetained'] -and $rows['T1'].renderedPromptRetained -eq $true)
    $report=[ordered]@{
        schemaVersion=1;resultKind='private-backend-parity-diagnostic';protocolVersion=$constants.protocolVersion
        recordedAt=[DateTime]::UtcNow.ToString('o');target=$Target
        reportStatus=$reportStatus;failureCode=$abort;bindingStatus=$bindingStatus
        runId=$first.runId;processIdentity=$first.processIdentity;endpoint=$first.endpoint;evidenceBindingSha256=$binding
        modelId=$first.modelId;modelSha256=$first.modelSha256;engineVersion=$first.engineVersion
        engineSha256=$first.recipe.engineSha256;catalogSha256=$first.recipe.catalogSha256
        contextSize=$contextSize;requestedArguments=@($first.recipe.requestedArguments)
        placementEvidence=$first.placement
        startupDiagnostics=$(if($null -ne $first.PSObject.Properties['startupDiagnostics']){$first.startupDiagnostics}else{$null})
        historicalBodyPinEnforced=$pinEnforced;historicalBodyPinVerified=$pinVerified;powerShellEdition=$Edition
        sourceProvenance=@{sha256=$source;endStatus=$sourceStatus;scope='On-disk SHA-256 before/after; loaded code not attested'}
        methodology=@{suiteVersion=(Get-FastLlmTaskWorkloadSuiteVersion);plannedRequests=5;issuedRequests=$issued;retryCount=0
            steps=@($steps);g1CaseId=$g1Case.id;g1PromptSha256=(Get-FastLlmTaskWorkloadPromptSha256 -Case $g1Case)
            g3CaseId=$g3Case.id;g3PromptSha256=(Get-FastLlmTaskWorkloadPromptSha256 -Case $g3Case)
            g1RequestBodySha256=$g1BodySha;g1BodyIsHistoricalArithmeticDiagnosticBody=$true
            sampling='temperature-0-seed-42-thinking-disabled';stream=$false;prefixCache=$false;maxOutputTokens=32
            logprobsRequestedOnly=@('G2','G3');topLogprobs=[int]$constants.topLogprobs;retainedGeneratedPositions=[int]$constants.retainedPositions
            retention='integer answers matching ^-?[0-9]{1,6}$ after trim; pieces limited to single digit, -, <|im_end|> else <other>; 4-decimal logprobs'
            deadlineSeconds=$DeadlineSeconds;requestTimeoutSeconds=$RequestTimeoutSeconds
            hardRequestTimeout=$true;hardWallClockDeadline=$false;outerProcessDeadlineOwner=$false}
        t1=$rows['T1'];t2=$rows['T2'];g1=$rows['G1'];g2=$rows['G2'];g3=$rows['G3']
        g3Passed=$g3Passed;valid=($reportStatus -ceq 'complete' -and $g3Passed)
        rawPromptRetained=$t1Retained;completionTextRetained=$false;answerRetentionBounded=$true;reportTruncated=$false
        qualification=@{approved=$false;qualityEvaluation=$false;semanticQualified=$false;performanceQualified=$false;
            physicalResidency=$false;throughputClaim=$false;gdnClaim=$false;generalCorrectnessClaim=$false}
    }
    $json=ConvertTo-Json -InputObject $report -Depth 24
    $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($json+"`n")
    if($bytes.Length -gt 262144){
        # A partial report is never lost: shed the bulky optional retention first, and say so.
        if($null -ne $report['t2'] -and $null -ne $report['t2'].PSObject.Properties['pieces']){$report['t2'].pieces=@()}
        if($null -ne $report['t1'] -and $null -ne $report['t1'].PSObject.Properties['renderedPrompt']){
            $report['t1'].renderedPrompt=$null;$report['t1'].renderedPromptRetained=$false
        }
        $report['rawPromptRetained']=$false;$report['reportTruncated']=$true
        $json=ConvertTo-Json -InputObject $report -Depth 24
        $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($json+"`n")
        if($bytes.Length -gt 262144){throw 'Backend parity report exceeds its private size bound.'}
    }
    $file=[IO.File]::Open($full,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$file.Write($bytes,0,$bytes.Length);$file.Flush()}finally{$file.Dispose()}
    return [pscustomobject]$report
}

function Invoke-FastLlmBackendParityDiagnostic {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][ValidateSet('Normal','CpuReference')][string]$Target,
          [Parameter(Mandatory=$true)][string]$InstallRoot,
          [string]$LabRunRoot,
          [Parameter(Mandatory=$true)][string]$OutputPath,
          [Parameter(Mandatory=$true)][string]$ToolSourcePath,
          [Parameter(Mandatory=$true)][string]$TaskQualityToolSourcePath,
          [ValidateRange(0,1200)][int]$DeadlineSeconds=0,
          [ValidateRange(0,600)][int]$RequestTimeoutSeconds=0)
    if($env:OS -cne 'Windows_NT' -or -not [Environment]::Is64BitProcess){throw 'Backend parity diagnostic requires native 64-bit Windows.'}
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run backend parity diagnostic as a standard user.'}
    if($OutputPath -cnotmatch '^[A-Za-z]:\\' -or [IO.Path]::GetExtension($OutputPath) -ine '.json'){
        throw 'OutputPath must be an absolute local-drive .json file.'
    }
    if($Target -ceq 'CpuReference' -and [string]::IsNullOrWhiteSpace($LabRunRoot)){throw 'CpuReference requires LabRunRoot.'}
    $full=[IO.Path]::GetFullPath($OutputPath)
    $cursor=[IO.Path]::GetPathRoot($full)
    foreach($segment in ([IO.Path]::GetDirectoryName($full).Substring($cursor.Length).Split([IO.Path]::DirectorySeparatorChar))){
        if($segment.Length -eq 0){continue}
        $cursor=Join-Path $cursor $segment
        $item=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if(-not $item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)){
            throw 'Unsafe output parent.'
        }
    }
    $stateBase=$(if($Target -ceq 'Normal'){$InstallRoot}else{$LabRunRoot})
    $stateRoot=Get-FastLlmStateRoot -InstallRoot $stateBase
    $lockPath=Join-FastLlmContainedPath -Root $stateRoot -Child 'benchmark.lock'
    if((Test-Path -LiteralPath $lockPath) -and ((Get-Item -LiteralPath $lockPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){
        throw 'Unsafe benchmark lock.'
    }
    try{$lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
    catch{throw 'A benchmark or semantic diagnostic is active.'}
    try{
        if($Target -ceq 'Normal'){
            return Invoke-FastLlmBackendParityCore -OutputPath $full -Target Normal -ToolSourcePath $ToolSourcePath `
                -TaskQualityToolSourcePath $TaskQualityToolSourcePath -DeadlineSeconds $DeadlineSeconds `
                -RequestTimeoutSeconds $RequestTimeoutSeconds -ReadState {Get-FastLlmStatus -InstallRoot $InstallRoot} `
                -AssertState {param($State,$Expected)
                    $binding=Assert-FastLlmSemanticSmokeState -State $State -ExpectedBinding $Expected
                    Assert-FastLlmBackendParityNormalRecipe -State $State
                    $binding} `
                -Request {param($Path,$Body,$TimeoutMs) Invoke-FastLlmHttp -BaseUrl 'http://127.0.0.1:8080' -Path $Path -Body $Body -TimeoutMs $TimeoutMs} `
                -CheckProcess {param($State) Assert-FastLlmSemanticSmokeProcess -State $State}
        }
        $cpuPort=[int](Get-FastLlmCpuReferenceFixed).port
        return Invoke-FastLlmBackendParityCore -OutputPath $full -Target CpuReference -ToolSourcePath $ToolSourcePath `
            -TaskQualityToolSourcePath $TaskQualityToolSourcePath -DeadlineSeconds $DeadlineSeconds `
            -RequestTimeoutSeconds $RequestTimeoutSeconds -ReadState {Get-FastLlmCpuReferenceLabStatus -LabRunRoot $LabRunRoot} `
            -AssertState {param($State,$Expected) Assert-FastLlmCpuReferenceState -State $State -ExpectedBinding $Expected} `
            -Request {param($Path,$Body,$TimeoutMs) Invoke-FastLlmHttp -BaseUrl ('http://127.0.0.1:'+$cpuPort) -Path $Path -Body $Body -TimeoutMs $TimeoutMs} `
            -CheckProcess {param($State) Assert-FastLlmCpuReferenceProcess -State $State}
    }finally{$lock.Dispose()}
}
