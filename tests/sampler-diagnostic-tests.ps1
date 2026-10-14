#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
$semantic=Join-Path $root 'src/FastLlm.SemanticSmoke.ps1'
$workload=Join-Path $root 'src/FastLlm.TaskWorkload.ps1'
$taskTool=Join-Path $root 'tools/task-quality-benchmark.ps1'
$diagnostic=Join-Path $root 'src/FastLlm.SamplerDiagnostic.ps1'
$tool=Join-Path $root 'tools/sampler-diagnostic.ps1'
. $semantic
. $workload
. $taskTool -OutputPath (Join-Path ([IO.Path]::GetTempPath()) 'unused-sampler-task.json')
. $diagnostic
$script:checks=0
function Check([bool]$Pass,[string]$Message){if(-not $Pass){throw $Message};$script:checks++}
function Fails([scriptblock]$Action){try{& $Action|Out-Null;return $false}catch{return $true}}
$parseTokens=$null;$parseErrors=$null
$sourceAst=[Management.Automation.Language.Parser]::ParseFile($diagnostic,[ref]$parseTokens,[ref]$parseErrors)
Check (@($parseErrors).Count -eq 0) 'Sampler diagnostic source did not parse.'
$propsFunction=@($sourceAst.FindAll({param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Get-FastLlmSamplerPropsMetadata'
},$true))
Check ($propsFunction.Count -eq 1) 'Sampler props metadata function missing.'
$integerAssignment=@($propsFunction[0].Body.FindAll({param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -ceq '$integerType'
},$true))
Check ($integerAssignment.Count -eq 1) 'Seed integer-type gate missing.'
$integerNames=@($integerAssignment[0].Right.FindAll({param($node)
    $node -is [Management.Automation.Language.TypeExpressionAst]
},$true)|ForEach-Object {$_.TypeName.FullName}|Sort-Object -Unique)
$expectedIntegerNames=@('System.Byte','System.SByte','System.Int16','System.UInt16',
    'System.Int32','System.UInt32','System.Int64','System.UInt64')
Check (($integerNames -join ',') -ceq ((@($expectedIntegerNames|Sort-Object)) -join ',')) 'Seed type gate uses a nonportable PowerShell type alias.'
function New-TestResponse([string]$Content,[string]$Finish='stop'){
    [pscustomobject]@{Status=200;Body=(@{choices=@(@{message=@{role='assistant';content=$Content};finish_reason=$Finish});
        usage=@{prompt_tokens=100;completion_tokens=1}}|ConvertTo-Json -Depth 8 -Compress)}
}
$cases=@(Get-FastLlmSamplerDiagnosticCases)
Check ($cases.Count -eq 8) 'Canonical case set changed.'
$savedWorkload=(Get-Command Get-FastLlmTaskWorkloadCases).ScriptBlock
try{
    Set-Item Function:Get-FastLlmTaskWorkloadCases -Value {
        param([int]$DistractorCount=0)
        $items=@(& $savedWorkload -DistractorCount $DistractorCount)
        $items[0].prompt=([string]$items[0].prompt)+' drift'
        $items
    }
    Check (Fails {Get-FastLlmSamplerDiagnosticCases}) 'Historical prompt drift accepted.'
}finally{Set-Item Function:Get-FastLlmTaskWorkloadCases -Value $savedWorkload}
$script:state=[pscustomobject]@{
    schemaVersion=1;active=$true;phase='ready';runId=('a'*32);endpoint='http://127.0.0.1:8080/v1'
    modelId='qwen3.8-27b-ud-q4-k-m';modelSha256='322e194ff79741c7baa497c240f677f54b201b0efab44ca8e50f122b39123482'
    engineVersion='b10698';processIdentity=[pscustomobject]@{pid=42;startUtcTicks=638000000000000000}
    canary=[pscustomobject]@{modelIdentity=$true;repeatableToken=$true;synchronousChat=$true;streaming=$true;
        effectiveContext=32768;semanticCorrectnessQualified=$false}
    placement=[pscustomobject]@{reportedLayers=66;totalLayers=66;reportedAllLayers=$true;devices=@('Vulkan0')}
    recipe=[pscustomobject]@{backend='Vulkan';contextSize=32768;slots=1;
        engineSha256='9f4dd930c50cdd3f7946b679ff67eaa124343096abdb56f2978199cf035758c7';
        catalogSha256='65b8f2f9ca340dab273274086aba9e8f01cb14a2b8cf4bb65c5ed5f6e779caa6';
        cacheTypeK='f16';cacheTypeV='f16';speculation='none';splitMode='none';flashAttention='auto';tensorSplit=$null;
        adapters=@([pscustomobject]@{device='Vulkan0';name='AMD Radeon RX 7900 XTX';vendorId='1002';
            isAmd=$true;isIntegrated=$false;backend='Vulkan'});
        requestedArguments=@('--host','127.0.0.1','--port','8080','--alias','qwen3.8-27b-ud-q4-k-m',
            '--ctx-size','32768','--parallel','1','--device','Vulkan0','--split-mode','none',
            '--cache-type-k','f16','--cache-type-v','f16','--spec-type','none','--n-gpu-layers','all',
            '--fit','on','--fit-target','768','--flash-attn','auto','--log-verbosity','4',
            '--cors-origins','localhost','--model','<verified-model>',
            '--offline','--no-mmproj','--jinja','--no-agent','--no-ui','--metrics','--no-cors-credentials')}
}
$hashes=Get-FastLlmSamplerDiagnosticSourceHashes -ToolPath $tool -TaskToolPath $taskTool
Check ($hashes.Count -eq 10 -and (Test-FastLlmSamplerDiagnosticSourceHashes $hashes $tool $taskTool)) 'Source manifest incomplete.'
$toolSource=[IO.File]::ReadAllText($tool)
$coreSource=[IO.File]::ReadAllText($diagnostic)
foreach($term in @('benchmark.lock','[IO.FileMode]::CreateNew','WindowsBuiltInRole]::Administrator',
    'Assert-FastLlmSemanticSmokeProcess','Test-FastLlmSamplerDiagnosticSourceHashes','ConvertFrom-TaskQualityResponse')){
    Check ($coreSource.Contains($term) -or $toolSource.Contains($term)) "Missing safety contract $term"
}
Check ($toolSource.Contains('. $TaskTool -OutputPath $Destination')) 'Tool does not dot-source the unchanged parser.'
$greedy=New-FastLlmSamplerDiagnosticBody $script:state $cases[0] greedy 42
$sampled=New-FastLlmSamplerDiagnosticBody $script:state $cases[0] qwen-explicit 1729
Check ($greedy.temperature -eq 0 -and $greedy.seed -eq 42 -and
    -not $greedy.PSObject.Properties['top_k'] -and $greedy.chat_template_kwargs.enable_thinking -eq $false) 'Greedy request mutated.'
Check ($sampled.temperature -eq 0.7 -and $sampled.top_p -eq 0.8 -and $sampled.top_k -eq 20 -and
    $sampled.min_p -eq 0 -and $sampled.presence_penalty -eq 1.5 -and $sampled.repeat_penalty -eq 1 -and
    $sampled.seed -eq 1729 -and $sampled.chat_template_kwargs.enable_thinking -eq $false) 'Qwen sampler mapping wrong.'
Check ($greedy.messages[0].content -ceq $sampled.messages[0].content -and
    $greedy.max_tokens -eq $sampled.max_tokens -and $greedy.cache_prompt -eq $sampled.cache_prompt -and
    $greedy.stream -eq $sampled.stream) 'Sampler changed canonical task payload.'
Check (Fails {New-FastLlmSamplerDiagnosticBody $script:state $cases[0] qwen-explicit 7}) 'Arbitrary seed accepted.'
$badState=$script:state.PSObject.Copy();$badState.modelSha256=('e'*64)
foreach($mutation in @('engine','catalog','kv','spec','device','tensor','split','flash','topology')){
    $altered=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $script:state -Depth 16)
    switch($mutation){
        'engine' {$altered.recipe.engineSha256=('f'*64)}
        'catalog' {$altered.recipe.catalogSha256=('f'*64)}
        'kv' {$altered.recipe.cacheTypeK='q8_0'}
        'spec' {$altered.recipe.speculation='draft'}
        'device' {$altered.recipe.adapters[0].device='Vulkan1'}
        'tensor' {$altered.recipe.requestedArguments+=@('--tensor-split','0.5,0.5')}
        'split' {$altered.recipe.splitMode='layer'}
        'flash' {$altered.recipe.flashAttention='disabled'}
        'topology' {$altered.recipe.adapters[0].name='Unknown GPU'}
    }
    Check (Fails {Assert-FastLlmSamplerDiagnosticRecipe $altered}) "Unsafe recipe mutation accepted: $mutation"
}
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('fastllm-sampler-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $testRoot
try{
    $props=[pscustomobject]@{Status=200;Body='{"total_slots":1,"default_generation_settings":{"n_ctx":32768,"params":{"temperature":0.8}},"chat_template":"secret-template C:\\users\\bench\\model"}'}
    $sanitized=Get-FastLlmSamplerPropsMetadata -Response $props -ExpectedContext 32768
    Check ($sanitized.available -and $sanitized.observedSlots -eq 1 -and $sanitized.observedContext -eq 32768 -and
        $sanitized.templateSha256 -cmatch '^[0-9a-f]{64}$' -and $sanitized.defaultSampling.temperature -eq 0.8) 'Safe props metadata missing.'
    Check (Fails {Get-FastLlmSamplerPropsMetadata -Response ([pscustomobject]@{Status=200;Body='{"total_slots":2,"default_generation_settings":{"n_ctx":32768}}'}) -ExpectedContext 32768}) 'Contradictory slots accepted.'
    Check (-not (Get-FastLlmSamplerPropsMetadata -Response ([pscustomobject]@{Status=503;Body=''} ) -ExpectedContext 32768).available) 'Unavailable props invented.'
    $noParams=Get-FastLlmSamplerPropsMetadata -Response ([pscustomobject]@{Status=200;Body='{"total_slots":1,"default_generation_settings":{"n_ctx":32768,"temperature":0.9}}'}) -ExpectedContext 32768
    Check ($noParams.available -and $noParams.defaultSampling.Count -eq 0) 'Top-level guessed sampler default was exported.'
    $seedPropsTemplate='{"total_slots":1,"default_generation_settings":{"n_ctx":32768,"params":{"temperature":0.8,"top_k":1000001,"seed":__SEED__}}}'
    foreach($seedCase in @(
        [pscustomobject]@{token='0';accepted=$true;expected=[double]0},
        [pscustomobject]@{token='4294967295';accepted=$true;expected=[double]4294967295},
        [pscustomobject]@{token='42.0';accepted=$false;expected=$null},
        [pscustomobject]@{token='-1';accepted=$false;expected=$null},
        [pscustomobject]@{token='42.5';accepted=$false;expected=$null},
        [pscustomobject]@{token='42.000000000000001';accepted=$false;expected=$null},
        [pscustomobject]@{token='4294967295.0000001';accepted=$false;expected=$null},
        [pscustomobject]@{token='4294967296';accepted=$false;expected=$null},
        [pscustomobject]@{token='true';accepted=$false;expected=$null},
        [pscustomobject]@{token='"42"';accepted=$false;expected=$null},
        [pscustomobject]@{token='1e309';accepted=$false;expected=$null}
    )){
        $seedResponse=[pscustomobject]@{Status=200;Body=$seedPropsTemplate.Replace('__SEED__',$seedCase.token)}
        $seedMetadata=Get-FastLlmSamplerPropsMetadata -Response $seedResponse -ExpectedContext 32768
        $hasSeed=$seedMetadata.available -and $seedMetadata.defaultSampling.Contains('seed')
        Check ($hasSeed -eq $seedCase.accepted) "Seed metadata accept/reject mismatch: $($seedCase.token)"
        if($seedCase.accepted){
            Check ($seedMetadata.defaultSampling.seed -eq $seedCase.expected -and
                $seedMetadata.defaultSampling.temperature -eq 0.8 -and
                -not $seedMetadata.defaultSampling.Contains('top_k')) "Seed metadata or unchanged nonseed bound mismatch: $($seedCase.token)"
        }
    }
    $script:issuedBodies=@();$script:checksSeen=0;$script:propsSeen=0
    $report=Invoke-FastLlmSamplerDiagnosticCore -OutputPath (Join-Path $testRoot 'complete.json') -ToolPath $tool -TaskToolPath $taskTool `
        -DeadlineSeconds 120 -RequestTimeoutSeconds 5 -ReadState {$script:state} `
        -CheckProcess {param($State)$script:checksSeen++;if($State.processIdentity.pid -ne 42){throw 'Wrong owner.'}} `
        -Request {param($Path,$Body,$TimeoutMs)
            if($Path -ceq '/props'){$script:propsSeen++;return $props}
            if($Path -cne '/v1/chat/completions' -or $TimeoutMs -gt 5000){throw 'Wrong request transport.'}
            $script:issuedBodies+=,$Body
            $index=($script:issuedBodies.Count-1)%8
            New-TestResponse $cases[$index].expected
        }
    Check ($report.reportStatus -ceq 'complete' -and $report.methodology.issuedTaskRequests -eq 32 -and
        $report.methodology.remainingTaskRequests -eq 0 -and $report.methodology.retryCount -eq 0 -and
        $script:issuedBodies.Count -eq 32 -and $script:propsSeen -eq 2) 'Not exactly 32 no-retry requests plus two props reads.'
    Check (@($report.methodology.arms).Count -eq 4 -and @($report.armSummary).Count -eq 4 -and
        @($report.armSummary|Where-Object {$_.issued -ne 8 -or $_.remaining -ne 0}).Count -eq 0) 'Fixed arm schedule or summary missing.'
    Check ($script:checksSeen -ge 65 -and $report.bindingStatus -ceq 'verified' -and
        $report.sourceProvenance.endStatus -ceq 'verified') 'Per-request identity/source checks missing.'
    $expectedOrder=@()
    foreach($prefix in @('greedy:42','qwen-explicit:42','qwen-explicit:1729','qwen-explicit:31415')){
        foreach($case in $cases){$expectedOrder+="${prefix}:$($case.id)"}
    }
    Check ((@($report.requests|ForEach-Object {"$($_.arm):$($_.seed):$($_.taskId)"}) -join ',') -ceq
        ($expectedOrder -join ',')) 'Request arm/seed/case order changed.'
    Check (@($report.requests|Where-Object grade -ne 'correct').Count -eq 0 -and
        @($report.requests|Where-Object {$_.actualPromptTokens -ne 100 -or $_.actualOutputTokens -ne 1}).Count -eq 0) 'Strict grade or actual usage not retained.'
    $bodyDigest=Get-FastLlmTaskWorkloadSha256 -Text (ConvertTo-Json -InputObject $script:issuedBodies[0] -Depth 12 -Compress)
    Check ($report.requests[0].requestBodySha256 -ceq $bodyDigest -and
        @($report.requests|Where-Object { $_.requestBodySha256 -cnotmatch '^[0-9a-f]{64}$' }).Count -eq 0) 'Exact issued body digests missing.'
    $json=[IO.File]::ReadAllText((Join-Path $testRoot 'complete.json'))
    Check (-not $json.Contains('secret-template') -and -not $json.Contains('C:\\users') -and
        -not $json.Contains($cases[0].prompt) -and -not $json.Contains('"content"') -and
        $report.answerSha256Retained -eq $false -and $report.rateMeasured -eq $false -and
        $report.qualification.approved -eq $false -and $report.methodology.hardWallClockDeadline -eq $false) 'Private report leaked content or overstated claim.'
    Check (Fails {Invoke-FastLlmSamplerDiagnosticCore -OutputPath (Join-Path $testRoot 'complete.json') -ToolPath $tool -TaskToolPath $taskTool `
        -ReadState {$script:state} -CheckProcess {} -Request {}}) 'Existing report overwritten.'
    Check (Fails {Invoke-FastLlmSamplerDiagnosticCore -OutputPath (Join-Path $testRoot 'wrong-model.json') -ToolPath $tool -TaskToolPath $taskTool `
        -ReadState {$badState} -CheckProcess {} -Request {}}) 'Wrong exact model accepted.'
    $script:attempts=0
    $wrong=Invoke-FastLlmSamplerDiagnosticCore -OutputPath (Join-Path $testRoot 'wrong.json') -ToolPath $tool -TaskToolPath $taskTool `
        -DeadlineSeconds 120 -RequestTimeoutSeconds 5 -ReadState {$script:state} -CheckProcess {} `
        -Request {param($Path,$Body,$TimeoutMs) if($Path -ceq '/props'){return $props};$script:attempts++;New-TestResponse 'wrong-answer'}
    Check ($wrong.reportStatus -ceq 'complete' -and $wrong.methodology.issuedTaskRequests -eq 32 -and
        @($wrong.requests|Where-Object grade -eq 'incorrect').Count -eq 32) 'Strict incorrect should continue, not turn into an invented pass.'
    $script:attempts=0
    $short=Invoke-FastLlmSamplerDiagnosticCore -OutputPath (Join-Path $testRoot 'short.json') -ToolPath $tool -TaskToolPath $taskTool `
        -DeadlineSeconds 120 -RequestTimeoutSeconds 5 -ReadState {$script:state} -CheckProcess {} `
        -Request {param($Path,$Body,$TimeoutMs) if($Path -ceq '/props'){return $props};$script:attempts++;New-TestResponse 'answer' 'length'}
    Check ($short.reportStatus -ceq 'aborted' -and $short.abortReasonCode -ceq 'inconclusive-response' -and
        $short.methodology.issuedTaskRequests -eq 1 -and $short.methodology.remainingTaskRequests -eq 31 -and
        $short.requests[0].grade -ceq 'inconclusive' -and @($short.methodology.arms).Count -eq 4 -and
        @($short.armSummary|Measure-Object -Property remaining -Sum).Sum -eq 31) 'Truncation did not fail closed with exact attempted count.'
    $script:attempts=0
    $transport=Invoke-FastLlmSamplerDiagnosticCore -OutputPath (Join-Path $testRoot 'transport.json') -ToolPath $tool -TaskToolPath $taskTool `
        -DeadlineSeconds 120 -RequestTimeoutSeconds 5 -ReadState {$script:state} -CheckProcess {} `
        -Request {param($Path,$Body,$TimeoutMs) if($Path -ceq '/props'){return $props};$script:attempts++;throw 'secret response'}
    Check ($transport.reportStatus -ceq 'aborted' -and $transport.abortReasonCode -ceq 'request-error' -and
        $transport.methodology.issuedTaskRequests -eq 1 -and $transport.requests[0].grade -ceq 'inconclusive' -and
        -not ([IO.File]::ReadAllText((Join-Path $testRoot 'transport.json')).Contains('secret response'))) 'Transport abort leaked details or retried.'
    $script:liveState=$script:state.PSObject.Copy();$script:postProps=0;$script:postRequests=0
    $postChanged=Invoke-FastLlmSamplerDiagnosticCore -OutputPath (Join-Path $testRoot 'post-change.json') -ToolPath $tool -TaskToolPath $taskTool `
        -DeadlineSeconds 120 -RequestTimeoutSeconds 5 -ReadState {$script:liveState} -CheckProcess {} `
        -Request {param($Path,$Body,$TimeoutMs)
            if($Path -ceq '/props'){
                $script:postProps++
                if($script:postProps -eq 2){$script:liveState.runId=('b'*32)}
                return $props
            }
            $caseIndex=$script:postRequests%8;$script:postRequests++
            New-TestResponse $cases[$caseIndex].expected
        }
    Check ($postChanged.reportStatus -ceq 'aborted' -and $postChanged.bindingStatus -ceq 'compromised' -and
        $postChanged.methodology.issuedTaskRequests -eq 32) 'Identity mutation during final props escaped final recheck.'
    $changedProps=[pscustomobject]@{Status=200;Body='{"total_slots":1,"default_generation_settings":{"n_ctx":32768,"params":{"temperature":0.9}}}' }
    $script:changedPropsReads=0;$script:changedPropsRequests=0
    $metadataChanged=Invoke-FastLlmSamplerDiagnosticCore -OutputPath (Join-Path $testRoot 'props-change.json') -ToolPath $tool -TaskToolPath $taskTool `
        -DeadlineSeconds 120 -RequestTimeoutSeconds 5 -ReadState {$script:state} -CheckProcess {} `
        -Request {param($Path,$Body,$TimeoutMs)
            if($Path -ceq '/props'){$script:changedPropsReads++;if($script:changedPropsReads -eq 2){return $changedProps};return $props}
            $caseIndex=$script:changedPropsRequests%8;$script:changedPropsRequests++
            New-TestResponse $cases[$caseIndex].expected
        }
    Check ($metadataChanged.reportStatus -ceq 'aborted' -and $metadataChanged.abortReasonCode -ceq 'props-metadata-changed' -and
        $metadataChanged.methodology.issuedTaskRequests -eq 32) 'Changed available props metadata silently completed.'
    $unavailableProps=[pscustomobject]@{Status=503;Body='service unavailable'}
    $script:unavailableRequests=0
    $preUnavailable=Invoke-FastLlmSamplerDiagnosticCore -OutputPath (Join-Path $testRoot 'pre-props-503.json') -ToolPath $tool -TaskToolPath $taskTool `
        -DeadlineSeconds 120 -RequestTimeoutSeconds 5 -ReadState {$script:state} -CheckProcess {} `
        -Request {param($Path,$Body,$TimeoutMs) if($Path -ceq '/props'){return $unavailableProps};$script:unavailableRequests++;New-TestResponse 'unused'}
    Check ($preUnavailable.reportStatus -ceq 'aborted' -and $preUnavailable.abortReasonCode -ceq 'props-unavailable' -and
        $preUnavailable.methodology.issuedTaskRequests -eq 0 -and $script:unavailableRequests -eq 0) 'Pre-props 503 still issued model requests.'
    $script:postUnavailableProps=0;$script:postUnavailableRequests=0
    $postUnavailable=Invoke-FastLlmSamplerDiagnosticCore -OutputPath (Join-Path $testRoot 'post-props-503.json') -ToolPath $tool -TaskToolPath $taskTool `
        -DeadlineSeconds 120 -RequestTimeoutSeconds 5 -ReadState {$script:state} -CheckProcess {} `
        -Request {param($Path,$Body,$TimeoutMs)
            if($Path -ceq '/props'){$script:postUnavailableProps++;if($script:postUnavailableProps -eq 2){return $unavailableProps};return $props}
            $caseIndex=$script:postUnavailableRequests%8;$script:postUnavailableRequests++
            New-TestResponse $cases[$caseIndex].expected
        }
    Check ($postUnavailable.reportStatus -ceq 'aborted' -and $postUnavailable.abortReasonCode -ceq 'props-unavailable' -and
        $postUnavailable.methodology.issuedTaskRequests -eq 32) 'Post-props 503 falsely completed.'
    $malformedProps=[pscustomobject]@{Status=200;Body='{malformed'}
    $preMalformed=Invoke-FastLlmSamplerDiagnosticCore -OutputPath (Join-Path $testRoot 'pre-props-malformed.json') -ToolPath $tool -TaskToolPath $taskTool `
        -DeadlineSeconds 120 -RequestTimeoutSeconds 5 -ReadState {$script:state} -CheckProcess {} `
        -Request {param($Path,$Body,$TimeoutMs) if($Path -ceq '/props'){return $malformedProps};New-TestResponse 'unused'}
    Check ($preMalformed.reportStatus -ceq 'aborted' -and $preMalformed.abortReasonCode -ceq 'props-unavailable' -and
        $preMalformed.methodology.issuedTaskRequests -eq 0) 'Malformed props accepted.'
    $script:postMalformedProps=0;$script:postMalformedRequests=0
    $postMalformed=Invoke-FastLlmSamplerDiagnosticCore -OutputPath (Join-Path $testRoot 'post-props-malformed.json') -ToolPath $tool -TaskToolPath $taskTool `
        -DeadlineSeconds 120 -RequestTimeoutSeconds 5 -ReadState {$script:state} -CheckProcess {} `
        -Request {param($Path,$Body,$TimeoutMs)
            if($Path -ceq '/props'){$script:postMalformedProps++;if($script:postMalformedProps -eq 2){return $malformedProps};return $props}
            $caseIndex=$script:postMalformedRequests%8;$script:postMalformedRequests++
            New-TestResponse $cases[$caseIndex].expected
        }
    Check ($postMalformed.reportStatus -ceq 'aborted' -and $postMalformed.abortReasonCode -ceq 'props-unavailable' -and
        $postMalformed.methodology.issuedTaskRequests -eq 32) 'Post-props malformed body falsely completed.'
    $savedHashTest=(Get-Command Test-FastLlmSamplerDiagnosticSourceHashes).ScriptBlock
    try{
        Set-Item Function:Test-FastLlmSamplerDiagnosticSourceHashes -Value {return $false}
        $script:driftRequests=0
        $drift=Invoke-FastLlmSamplerDiagnosticCore -OutputPath (Join-Path $testRoot 'source-drift.json') -ToolPath $tool -TaskToolPath $taskTool `
            -DeadlineSeconds 120 -RequestTimeoutSeconds 5 -ReadState {$script:state} -CheckProcess {} `
            -Request {param($Path,$Body,$TimeoutMs) if($Path -ceq '/props'){return $props};$script:driftRequests++;New-TestResponse 'unused'}
        Check ($drift.reportStatus -ceq 'aborted' -and $drift.sourceProvenance.endStatus -ceq 'changed' -and
            $drift.methodology.issuedTaskRequests -eq 0 -and $script:driftRequests -eq 0) 'Source drift still issued a model request.'
    }finally{Set-Item Function:Test-FastLlmSamplerDiagnosticSourceHashes -Value $savedHashTest}
}finally{
    Get-ChildItem -LiteralPath $testRoot -File|Remove-Item -Force
    Remove-Item -LiteralPath $testRoot -Force
}
"Sampler diagnostic mock checks passed: $script:checks; no engine/model invoked."
