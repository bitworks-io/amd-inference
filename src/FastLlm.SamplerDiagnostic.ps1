# Private, fixed 32-request sampler comparison on one already-Ready Windows run.
# This does not alter the canonical task suite, its grader, or serving configuration.
function Get-FastLlmSamplerDiagnosticSourceHashes {
    param([string]$ToolPath,[string]$TaskToolPath)
    $paths=[ordered]@{
        diagnostic=(Join-Path $PSScriptRoot 'FastLlm.SamplerDiagnostic.ps1');tool=$ToolPath;taskTool=$TaskToolPath
        workload=(Join-Path $PSScriptRoot 'FastLlm.TaskWorkload.ps1')
        semantic=(Join-Path $PSScriptRoot 'FastLlm.SemanticSmoke.ps1')
        module=(Join-Path $PSScriptRoot 'FastLlm.psm1')
        runtime=(Join-Path $PSScriptRoot 'FastLlm.Runtime.ps1')
        benchmark=(Join-Path $PSScriptRoot 'FastLlm.Benchmark.ps1')
        processHost=(Join-Path $PSScriptRoot 'ProcessHost.cs')
        listener=(Join-Path $PSScriptRoot 'WindowsGpuTelemetry.cs')
    }
    $result=[ordered]@{}
    foreach($key in $paths.Keys){
        $item=Get-Item -LiteralPath $paths[$key] -Force -ErrorAction Stop
        if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Unsafe sampler diagnostic source.'}
        $result[$key]=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    return $result
}

function Test-FastLlmSamplerDiagnosticSourceHashes {
    param($Expected,[string]$ToolPath,[string]$TaskToolPath)
    try{
        $now=Get-FastLlmSamplerDiagnosticSourceHashes -ToolPath $ToolPath -TaskToolPath $TaskToolPath
        if(@($now.Keys).Count -ne @($Expected.Keys).Count){return $false}
        foreach($key in $Expected.Keys){if(-not $now.Contains($key) -or [string]$now[$key] -cne [string]$Expected[$key]){return $false}}
        return $true
    }catch{return $false}
}

function Get-FastLlmSamplerDiagnosticCases {
    $cases=@(Get-FastLlmTaskWorkloadCases -DistractorCount 0)
    Assert-TaskQualityCases -Cases $cases -DistractorCount 0
    $expected='extract-order-v1,filter-candidates-v1,sort-integers-v1,arithmetic-invoice-v1,arithmetic-steps-v1,dependency-chain-v1,retrieve-head-v1,retrieve-tail-v1'
    if((@($cases|ForEach-Object id) -join ',') -cne $expected){throw 'Canonical task order changed.'}
    $identities=@(
        'f84f8f48d0cf792ebf7f28e946d40bf1e821d0419fae24e8ec44b799a6cad9f4:d6ab559500a2ba78398c4d91a68708b413e79aba0bccb2642476c3a639f943d1',
        '3589d1e0b2fef7494aa92d16b85f8a2f8b9ac3123a1e21254f111e582fe5e8d9:9fa069279ff09e03c73359e5653957cf4dbce21d2f4fed60231e6f3b40c32c35',
        '04763edaef5c31c3c141a991059c2bea6a456ab4f287e0128817c8ceebbc16ad:1fe2b9b59f80577bff5f7f8eb1271d3492e22c71017cbb3d82877b867ffa26d0',
        'a239eca38f916a456a7dd46e355142662a6a4f9c9921b89306e00d1f6de0d6de:2963f23b5d79371ea1a4b66617a977b69f127c8d3088c018128b41427304516d',
        '8075c10d5c487b7976efbbb22ef8d50fcef17697aa6b12559945459d1c04c028:3f6195f88d915f645e3a63eab36fed5bfc54e67f80152c1e178e359b7bb7eef9',
        '7743df5f85abd29719c7ba7082f26402ffae4ee2e87b5fa00d4b17ee486e278b:acfddb908c38f09615df361ce9f13e0d9e112cb7c867687cda533cede64082f8',
        'a5ef81a2ddeec0f8cdbdd571dad61128e1151f1842f0f713fb987b1149e050cd:6b10e55d4c1fa222fbeaedc21ea778a16f68404352f1b1bc91c035e1ee4622c5',
        'b8c468a2c4f15dd71c7c72e9ce98be36cdf8aa50ae597ce959dee1dbd0cbf73b:23c38e675edf1b1dff13c769185b66653bea9528520dfebf8986184464614953')
    for($i=0;$i -lt 8;$i++){
        $actual=(Get-FastLlmTaskWorkloadPromptSha256 $cases[$i])+':'+(Get-FastLlmTaskWorkloadReferenceSha256 $cases[$i])
        if($actual -cne $identities[$i]){throw 'Historical task identity changed.'}
    }
    return $cases
}

function New-FastLlmSamplerDiagnosticBody {
    param($State,$Case,[ValidateSet('greedy','qwen-explicit')][string]$Arm,[int]$Seed)
    $json=New-TaskQualityRequestBody -State $State -Case $Case
    $body=ConvertFrom-Json -InputObject $json -ErrorAction Stop
    $expectedNames=@('model','messages','max_tokens','temperature','seed','stream','cache_prompt','chat_template_kwargs')
    if($null -ne $Case.responseFormat){$expectedNames+= 'response_format'}
    if((@($body.PSObject.Properties.Name|Sort-Object) -join ',') -cne (@($expectedNames|Sort-Object) -join ',') -or
       $body.model -cne [string]$State.modelId -or @($body.messages).Count -ne 1 -or
       $body.messages[0].role -cne 'user' -or $body.messages[0].content -cne [string]$Case.prompt -or
       [int]$body.max_tokens -ne [int]$Case.maxOutputTokens -or
       [double]$body.temperature -ne 0 -or [int]$body.seed -ne 42 -or
       $body.stream -ne $false -or $body.cache_prompt -ne $false -or
       $body.chat_template_kwargs.enable_thinking -ne $false){throw 'Canonical request constructor changed.'}
    if($null -eq $Case.responseFormat){
        if($body.PSObject.Properties['response_format']){throw 'Unexpected response format.'}
    }elseif(-not $body.PSObject.Properties['response_format'] -or
        (ConvertTo-Json -InputObject $body.response_format -Depth 16 -Compress) -cne
        (ConvertTo-Json -InputObject $Case.responseFormat -Depth 16 -Compress)){throw 'Canonical response format changed.'}
    if($Arm -ceq 'greedy'){
        if($Seed -ne 42){throw 'Greedy arm seed changed.'}
    }else{
        if($Seed -notin @(42,1729,31415)){throw 'Sampled arm seed changed.'}
        $body.temperature=0.7
        $body.seed=$Seed
        $body | Add-Member -NotePropertyName top_p -NotePropertyValue 0.8
        $body | Add-Member -NotePropertyName top_k -NotePropertyValue 20
        $body | Add-Member -NotePropertyName min_p -NotePropertyValue 0
        $body | Add-Member -NotePropertyName presence_penalty -NotePropertyValue 1.5
        # Qwen's repetition_penalty is sent using llama.cpp's repeat_penalty API field.
        $body | Add-Member -NotePropertyName repeat_penalty -NotePropertyValue 1
    }
    return $body
}

function Get-FastLlmSamplerPropsMetadata {
    param($Response,[int]$ExpectedContext)
    $result=[ordered]@{available=$false;templateSha256=$null;templateField='chat_template';defaultSampling=@{};
        observedContext=$null;observedSlots=$null;reason='unavailable'}
    if($null -eq $Response -or $Response.Status -ne 200 -or $Response.Body -isnot [string] -or
       $Response.Body.Length -gt 1048576){return [pscustomobject]$result}
    try{$data=ConvertFrom-Json -InputObject $Response.Body -ErrorAction Stop}catch{return [pscustomobject]$result}
    if($null -eq $data -or -not $data.PSObject.Properties['total_slots'] -or
       -not $data.PSObject.Properties['default_generation_settings'] -or
       $data.total_slots -isnot [int] -and $data.total_slots -isnot [long] -or
       $null -eq $data.default_generation_settings -or
       -not $data.default_generation_settings.PSObject.Properties['n_ctx'] -or
       $data.default_generation_settings.n_ctx -isnot [int] -and
       $data.default_generation_settings.n_ctx -isnot [long]){return [pscustomobject]$result}
    $result.observedContext=[int]$data.default_generation_settings.n_ctx
    $result.observedSlots=[int]$data.total_slots
    if($result.observedContext -ne $ExpectedContext -or $result.observedSlots -ne 1){throw 'Live properties conflict with the bound S1 context.'}
    $result.available=$true;$result.reason='verified'
    if($data.PSObject.Properties['chat_template'] -and $data.chat_template -is [string] -and
       $data.chat_template.Length -gt 0 -and $data.chat_template.Length -le 262144){
        $result.templateSha256=Get-FastLlmTaskWorkloadSha256 -Text $data.chat_template
    }
    $params=if($data.default_generation_settings.PSObject.Properties['params']){$data.default_generation_settings.params}else{$null}
    foreach($name in @('temperature','top_p','top_k','min_p','presence_penalty','repeat_penalty','seed')){
        $property=if($null -ne $params){$params.PSObject.Properties[$name]}else{$null}
        if($property -and $property.Value -is [ValueType] -and
           $property.Value -isnot [bool]){
            $value=[double]$property.Value
            if([double]::IsNaN($value) -or [double]::IsInfinity($value)){continue}
            if($name -ceq 'seed'){
                # llama.cpp uses UINT32_MAX as its default random-seed sentinel.
                # Parsed floating JSON can round a fractional literal to an integer,
                # so accept only JSON integer values for seed provenance.
                $integerType=($property.Value -is [System.Byte] -or $property.Value -is [System.SByte] -or
                    $property.Value -is [System.Int16] -or $property.Value -is [System.UInt16] -or
                    $property.Value -is [System.Int32] -or $property.Value -is [System.UInt32] -or
                    $property.Value -is [System.Int64] -or $property.Value -is [System.UInt64])
                if($integerType -and $value -ge 0 -and $value -le 4294967295 -and
                   [Math]::Truncate($value) -eq $value){$result.defaultSampling[$name]=$value}
            }elseif([Math]::Abs($value) -le 1000000){
                $result.defaultSampling[$name]=$value
            }
        }
    }
    return [pscustomobject]$result
}

function Assert-FastLlmSamplerDiagnosticRecipe {
    param($State)
    if($State.modelId -cne 'qwen3.8-27b-ud-q4-k-m' -or
       $State.modelSha256 -cne '322e194ff79741c7baa497c240f677f54b201b0efab44ca8e50f122b39123482' -or
       [int]$State.recipe.contextSize -ne 32768 -or [int]$State.recipe.slots -ne 1 -or
       $State.recipe.engineSha256 -cne '9f4dd930c50cdd3f7946b679ff67eaa124343096abdb56f2978199cf035758c7' -or
       $State.recipe.catalogSha256 -cne '65b8f2f9ca340dab273274086aba9e8f01cb14a2b8cf4bb65c5ed5f6e779caa6' -or
       $State.recipe.cacheTypeK -cne 'f16' -or $State.recipe.cacheTypeV -cne 'f16' -or
       $State.recipe.speculation -cne 'none' -or $State.recipe.splitMode -cne 'none' -or
       $State.recipe.flashAttention -cne 'auto' -or $null -ne $State.recipe.tensorSplit -or
       @($State.recipe.adapters).Count -ne 1 -or [string]$State.recipe.adapters[0].device -cne 'Vulkan0' -or
       [string]$State.recipe.adapters[0].name -cne 'AMD Radeon RX 7900 XTX' -or
       [string]$State.recipe.adapters[0].vendorId -cne '1002' -or
       $State.recipe.adapters[0].isAmd -ne $true -or $State.recipe.adapters[0].isIntegrated -ne $false -or
       [string]$State.recipe.adapters[0].backend -cne 'Vulkan' -or
       @($State.placement.devices).Count -ne 1 -or [string]$State.placement.devices[0] -cne 'Vulkan0'){
        throw 'Sampler diagnostic requires exact normal b10698/Q4/32K/S1/Vulkan0 F16/no-spec recipe.'
    }
    $recipeArguments=@($State.recipe.requestedArguments)
    foreach($pair in @(@('--device','Vulkan0'),@('--split-mode','none'),@('--cache-type-k','f16'),
        @('--cache-type-v','f16'),@('--spec-type','none'),@('--n-gpu-layers','all'),@('--fit','on'),
        @('--flash-attn','auto'),@('--fit-target','768'),@('--cors-origins','localhost'),
        @('--log-verbosity','4'),@('--model','<verified-model>'))){
        if(-not (Test-FastLlmSemanticSmokeArgument $recipeArguments $pair[0] $pair[1])){throw 'Sampler recipe arguments differ from the fixed run.'}
    }
    foreach($flag in @('--offline','--no-mmproj','--jinja','--no-agent','--no-ui','--metrics','--no-cors-credentials')){
        if(@($recipeArguments|Where-Object {$_ -ceq $flag}).Count -ne 1){throw 'Sampler recipe is missing a fixed isolation flag.'}
    }
    if(@($recipeArguments|Where-Object {$_ -ceq '--tensor-split'}).Count -ne 0){throw 'Sampler diagnostic does not accept tensor splitting.'}
}

function Invoke-FastLlmSamplerDiagnosticCore {
    param([Parameter(Mandatory=$true)][string]$OutputPath,
          [Parameter(Mandatory=$true)][scriptblock]$ReadState,
          [Parameter(Mandatory=$true)][scriptblock]$Request,
          [Parameter(Mandatory=$true)][scriptblock]$CheckProcess,
          [Parameter(Mandatory=$true)][string]$ToolPath,
          [Parameter(Mandatory=$true)][string]$TaskToolPath,
          [ValidateRange(120,3600)][int]$DeadlineSeconds=1800,
          [ValidateRange(1,120)][int]$RequestTimeoutSeconds=45)
    if($RequestTimeoutSeconds -gt $DeadlineSeconds){throw 'Request timeout exceeds diagnostic budget.'}
    if(Test-Path -LiteralPath $OutputPath){throw 'Sampler diagnostic report already exists.'}
    $full=[IO.Path]::GetFullPath($OutputPath)
    if(-not (Test-Path -LiteralPath (Split-Path $full -Parent) -PathType Container)){throw 'Private report parent must exist.'}
    foreach($name in @('Get-FastLlmTaskWorkloadCases','Get-FastLlmTaskWorkloadSha256',
        'Get-FastLlmTaskWorkloadPromptSha256','Get-FastLlmTaskWorkloadReferenceSha256',
        'Assert-TaskQualityCases','New-TaskQualityRequestBody','ConvertFrom-TaskQualityResponse',
        'Assert-FastLlmSemanticSmokeState')){
        if(-not (Get-Command $name -CommandType Function -ErrorAction SilentlyContinue)){throw 'Sampler dependency unavailable.'}
    }
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $source=Get-FastLlmSamplerDiagnosticSourceHashes -ToolPath $ToolPath -TaskToolPath $TaskToolPath
    $cases=@(Get-FastLlmSamplerDiagnosticCases)
    $state=& $ReadState
    $binding=Assert-FastLlmSemanticSmokeState -State $state
    & $CheckProcess $state
    Assert-FastLlmSamplerDiagnosticRecipe $state
    $caseMetadata=@($cases|ForEach-Object {
        [pscustomobject]@{id=$_.id;promptSha256=(Get-FastLlmTaskWorkloadPromptSha256 $_);
            referenceSha256=(Get-FastLlmTaskWorkloadReferenceSha256 $_);maxOutputTokens=$_.maxOutputTokens;
            responseFormatSha256=$(if($null -eq $_.responseFormat){$null}else{
                Get-FastLlmTaskWorkloadSha256 -Text (ConvertTo-Json $_.responseFormat -Depth 16 -Compress)})}
    })
    $schedule=@([pscustomobject]@{arm='greedy';seed=42})+@(
        @(42,1729,31415)|ForEach-Object {[pscustomobject]@{arm='qwen-explicit';seed=$_}})
    $results=@();$issued=0;$abort=$null;$bindingStatus='verified';$sourceStatus='verified'
    $propsBefore=[pscustomobject]@{available=$false;reason='unavailable'}
    $propsAfter=[pscustomobject]@{available=$false;reason='unavailable'}
    try{
        $pre=& $Request '/props' $null 5000
        $propsBefore=Get-FastLlmSamplerPropsMetadata -Response $pre -ExpectedContext 32768
        if(-not $propsBefore.available){$abort='props-unavailable'}
    }catch{$abort='props-or-transport-error'}
    foreach($arm in $schedule){
        foreach($case in $cases){
            if($abort){break}
            try{
                $current=& $ReadState
                $null=Assert-FastLlmSemanticSmokeState -State $current -ExpectedBinding $binding
                & $CheckProcess $current
            }catch{$abort='binding-or-process-changed';$bindingStatus='compromised';break}
            if(-not (Test-FastLlmSamplerDiagnosticSourceHashes -Expected $source -ToolPath $ToolPath -TaskToolPath $TaskToolPath)){
                $abort='source-changed';$sourceStatus='changed';break
            }
            $remaining=[int][Math]::Floor(($DeadlineSeconds-$clock.Elapsed.TotalSeconds)*1000)
            if($remaining -le 0){$abort='deadline';break}
            try{$body=New-FastLlmSamplerDiagnosticBody -State $state -Case $case -Arm $arm.arm -Seed $arm.seed}
            catch{$abort='request-construction-changed';break}
            $issued++
            $requestBodySha256=Get-FastLlmTaskWorkloadSha256 -Text (ConvertTo-Json -InputObject $body -Depth 12 -Compress)
            $response=$null;$transportError=$false
            try{$response=& $Request '/v1/chat/completions' $body ([Math]::Min($RequestTimeoutSeconds*1000,$remaining))}
            catch{$transportError=$true}
            try{
                $current=& $ReadState
                $null=Assert-FastLlmSemanticSmokeState -State $current -ExpectedBinding $binding
                & $CheckProcess $current
            }catch{$abort='binding-or-process-changed';$bindingStatus='compromised'}
            if(-not (Test-FastLlmSamplerDiagnosticSourceHashes -Expected $source -ToolPath $ToolPath -TaskToolPath $TaskToolPath)){
                $abort='source-changed';$sourceStatus='changed'
            }
            if($clock.Elapsed.TotalSeconds -gt $DeadlineSeconds -and -not $abort){$abort='deadline'}
            $parsed=if($transportError -or $abort){[pscustomobject]@{grade='inconclusive';errorCode=$(if($abort){$abort}else{'request-error'});
                classification='inconclusive';httpStatus=$null;finishReason=$null;actualPromptTokens=$null;actualOutputTokens=$null}}else{
                ConvertFrom-TaskQualityResponse -Response $response -Case $case -EffectiveContext 32768
            }
            $results+= [pscustomobject]@{index=$issued;arm=$arm.arm;seed=[int]$arm.seed;taskId=$case.id;
                requestBodySha256=$requestBodySha256;
                requestedSampling=$(if($arm.arm -ceq 'greedy'){@{temperature=0;seed=42}}else{
                    @{temperature=0.7;top_p=0.8;top_k=20;min_p=0;presence_penalty=1.5;repeat_penalty=1;seed=[int]$arm.seed}});
                grade=$parsed.grade;classification=$parsed.classification;errorCode=$parsed.errorCode;
                httpStatus=$parsed.httpStatus;finishReason=$parsed.finishReason;
                actualPromptTokens=$parsed.actualPromptTokens;actualOutputTokens=$parsed.actualOutputTokens}
            if($transportError -and -not $abort){$abort='request-error'}
            if($parsed.grade -ceq 'inconclusive' -and -not $abort){$abort='inconclusive-response'}
        }
        if($abort){break}
    }
    try{
        $current=& $ReadState
        $null=Assert-FastLlmSemanticSmokeState -State $current -ExpectedBinding $binding
        & $CheckProcess $current
    }catch{$abort='binding-or-process-changed';$bindingStatus='compromised'}
    if(-not (Test-FastLlmSamplerDiagnosticSourceHashes -Expected $source -ToolPath $ToolPath -TaskToolPath $TaskToolPath)){
        $abort='source-changed';$sourceStatus='changed'
    }
    if(-not $abort){
        try{
            $post=& $Request '/props' $null 5000
            $propsAfter=Get-FastLlmSamplerPropsMetadata -Response $post -ExpectedContext 32768
            if(-not $propsAfter.available){$abort='props-unavailable'}
        }
        catch{$abort='props-or-transport-error'}
    }
    if(-not $abort -and $propsBefore.available -and $propsAfter.available -and
       (ConvertTo-Json -InputObject $propsBefore -Depth 8 -Compress) -cne
       (ConvertTo-Json -InputObject $propsAfter -Depth 8 -Compress)){
        $abort='props-metadata-changed'
    }
    try{
        $current=& $ReadState
        $null=Assert-FastLlmSemanticSmokeState -State $current -ExpectedBinding $binding
        & $CheckProcess $current
    }catch{$abort='binding-or-process-changed';$bindingStatus='compromised'}
    if(-not (Test-FastLlmSamplerDiagnosticSourceHashes -Expected $source -ToolPath $ToolPath -TaskToolPath $TaskToolPath)){
        $abort='source-changed';$sourceStatus='changed'
    }
    if($clock.Elapsed.TotalSeconds -gt $DeadlineSeconds -and -not $abort){$abort='deadline'}
    $armSummary=@(foreach($arm in $schedule){
        $items=@($results|Where-Object {$_.arm -ceq $arm.arm -and $_.seed -eq $arm.seed})
        [pscustomobject]@{arm=$arm.arm;seed=[int]$arm.seed;planned=8;issued=$items.Count;remaining=(8-$items.Count)
            correct=@($items|Where-Object grade -eq 'correct').Count
            incorrect=@($items|Where-Object grade -eq 'incorrect').Count
            inconclusive=@($items|Where-Object grade -eq 'inconclusive').Count}
    })
    $report=[ordered]@{
        schemaVersion=1;resultKind='private-windows-sampler-diagnostic';recordedAt=[DateTime]::UtcNow.ToString('o')
        reportStatus=$(if($abort){'aborted'}else{'complete'});abortReasonCode=$abort
        bindingStatus=$bindingStatus;runId=$state.runId;processIdentity=$state.processIdentity
        modelId=$state.modelId;modelSha256=$state.modelSha256;engineVersion=$state.engineVersion
        engineSha256=$state.recipe.engineSha256;catalogSha256=$state.recipe.catalogSha256;endpoint=$state.endpoint
        evidenceBindingSha256=$binding;sourceProvenance=@{sha256=$source;endStatus=$sourceStatus;
            scope='On-disk SHA-256 before/after; loaded code not attested'}
        methodology=@{protocolVersion='sampler-comparison-diagnostic-v1';suiteVersion=(Get-FastLlmTaskWorkloadSuiteVersion)
            cases=$caseMetadata;arms=@($schedule);distractorCount=0;plannedTaskRequests=32;issuedTaskRequests=$issued
            remainingTaskRequests=(32-$issued);retryCount=0;concurrency=1;requestTimeoutSeconds=$RequestTimeoutSeconds
            elapsedBudgetSeconds=$DeadlineSeconds;hardRequestTimeout=$true;hardWallClockDeadline=$false
            outerProcessDeadlineOwner=$false;samplerControlsRequestedNotProven=$true
            note='Explicit request controls are not proof the server honored the sampler; no causal, quality, speed, or fit claim.'}
        props=@{before=$propsBefore;after=$propsAfter;rawPropsRetained=$false}
        requests=$results;armSummary=$armSummary;promptTextRetained=$false;answerTextRetained=$false;answerSha256Retained=$false
        templateTextRetained=$false;rateMeasured=$false
        qualification=@{approved=$false;qualityEvaluation=$false;performanceQualified=$false;physicalResidency=$false}
    }
    $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes((ConvertTo-Json -InputObject $report -Depth 24)+"`n")
    if($bytes.Length -gt 131072){throw 'Sampler report exceeds private size bound.'}
    $file=[IO.File]::Open($full,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$file.Write($bytes,0,$bytes.Length);$file.Flush()}finally{$file.Dispose()}
    return [pscustomobject]$report
}

function Invoke-FastLlmSamplerDiagnostic {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$InstallRoot,
          [Parameter(Mandatory=$true)][string]$OutputPath,
          [Parameter(Mandatory=$true)][string]$ToolPath,
          [Parameter(Mandatory=$true)][string]$TaskToolPath,
          [ValidateRange(120,3600)][int]$DeadlineSeconds=1800,
          [ValidateRange(1,120)][int]$RequestTimeoutSeconds=45)
    if($env:OS -cne 'Windows_NT' -or -not [Environment]::Is64BitProcess){throw 'Sampler diagnostic requires native 64-bit Windows.'}
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run sampler diagnostic as a standard user.'}
    if($OutputPath -cnotmatch '^[A-Za-z]:\\' -or [IO.Path]::GetExtension($OutputPath) -ine '.json'){
        throw 'OutputPath must be an absolute local-drive .json file.'
    }
    $full=[IO.Path]::GetFullPath($OutputPath)
    $cursor=[IO.Path]::GetPathRoot($full)
    foreach($segment in ([IO.Path]::GetDirectoryName($full).Substring($cursor.Length).Split([IO.Path]::DirectorySeparatorChar))){
        if($segment.Length -eq 0){continue}
        $cursor=Join-Path $cursor $segment
        $item=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if(-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Unsafe output parent.'}
    }
    $stateRoot=Get-FastLlmStateRoot -InstallRoot $InstallRoot
    $lockPath=Join-FastLlmContainedPath -Root $stateRoot -Child 'benchmark.lock'
    if((Test-Path -LiteralPath $lockPath) -and ((Get-Item -LiteralPath $lockPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){
        throw 'Unsafe benchmark lock.'
    }
    try{$lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
    catch{throw 'A benchmark or semantic diagnostic is active.'}
    try{
        return Invoke-FastLlmSamplerDiagnosticCore -OutputPath $full -ToolPath $ToolPath -TaskToolPath $TaskToolPath `
            -DeadlineSeconds $DeadlineSeconds -RequestTimeoutSeconds $RequestTimeoutSeconds `
            -ReadState {Get-FastLlmStatus -InstallRoot $InstallRoot} `
            -Request {param($Path,$Body,$TimeoutMs) Invoke-FastLlmHttp -BaseUrl 'http://127.0.0.1:8080' -Path $Path -Body $Body -TimeoutMs $TimeoutMs} `
            -CheckProcess {param($State) Assert-FastLlmSemanticSmokeProcess -State $State}
    }finally{$lock.Dispose()}
}
