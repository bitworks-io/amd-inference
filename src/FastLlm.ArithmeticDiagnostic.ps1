# Private, fixed-case diagnostic for one already-Ready normal Windows run.
# It reuses the unchanged task-quality request constructor and strict response parser.

function Get-FastLlmArithmeticDiagnosticSourceHashes {
    param([Parameter(Mandatory=$true)][string]$ToolSourcePath,
          [Parameter(Mandatory=$true)][string]$TaskQualityToolSourcePath)
    $paths=[ordered]@{
        diagnostic=(Join-Path $PSScriptRoot 'FastLlm.ArithmeticDiagnostic.ps1')
        tool=$ToolSourcePath
        taskQualityParser=$TaskQualityToolSourcePath
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
            throw 'Arithmetic diagnostic source is unsafe.'
        }
        $hashes[$key]=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    return $hashes
}

function Test-FastLlmArithmeticDiagnosticSourceHashes {
    param($Expected,[string]$ToolSourcePath,[string]$TaskQualityToolSourcePath)
    try{
        $current=Get-FastLlmArithmeticDiagnosticSourceHashes -ToolSourcePath $ToolSourcePath `
            -TaskQualityToolSourcePath $TaskQualityToolSourcePath
        if(@($current.Keys).Count -ne @($Expected.Keys).Count){return $false}
        foreach($key in $Expected.Keys){
            if(-not $current.Contains($key) -or [string]$current[$key] -cne [string]$Expected[$key]){return $false}
        }
        return $true
    }catch{return $false}
}

function Test-FastLlmArithmeticDiagnosticExpectedValue {
    param([AllowEmptyString()][string]$Candidate)
    # Deliberately fixed to arithmetic-steps-v1's expected value. This is not an expression evaluator.
    if(-not ($Candidate -cmatch '\A(?<sign>[+-]?)(?<digits>[0-9]+)(?:\.)?\z')){return $false}
    if($Matches['sign'] -ceq '-'){return $false}
    $digits=$Matches['digits'].TrimStart('0')
    if($digits.Length -eq 0){$digits='0'}
    return $digits -ceq '63'
}

function New-FastLlmArithmeticDiagnosticResult {
    param([string]$ErrorCode='not-attempted')
    return [pscustomobject][ordered]@{
        httpStatus=$null;finishReason=$null;actualPromptTokens=$null;actualOutputTokens=$null
        originalGrade='inconclusive';originalErrorCode=$ErrorCode;originalClassification='inconclusive'
        diagnosticClassification='inconclusive'
    }
}

function Get-FastLlmArithmeticDiagnosticClassification {
    param($Response,$Case,[int]$EffectiveContext)
    $strict=ConvertFrom-TaskQualityResponse -Response $Response -Case $Case -EffectiveContext $EffectiveContext
    $classification='inconclusive'
    if($strict.grade -ceq 'correct'){$classification='strict-pass'}
    elseif($strict.grade -ceq 'incorrect'){
        $classification='wrong-or-unclassified'
        try{
            $body=ConvertFrom-Json -InputObject ([string]$Response.Body) -ErrorAction Stop
            $content=$body.choices[0].message.content
            if($content -is [string]){
                $answer=$content.Trim()
                if($answer -cmatch '\A[+-]?[0-9]+\z'){
                    $classification=$(if(Test-FastLlmArithmeticDiagnosticExpectedValue $answer){
                        'correct-value-noncanonical-format'
                    }else{'wrong-numeric-value'})
                }else{
                    $candidate=$null
                    if($answer -cmatch '\A[+-]?[0-9]+\.\z'){$candidate=$answer}
                    elseif($answer -cmatch '\A`(?<inner>[+-]?[0-9]+)`\z'){$candidate=$Matches['inner']}
                    elseif($answer -cmatch '\A```(?:text)?\r?\n(?<inner>[+-]?[0-9]+)\r?\n```\z'){$candidate=$Matches['inner']}
                    if($null -ne $candidate -and (Test-FastLlmArithmeticDiagnosticExpectedValue $candidate)){
                        $classification='correct-value-noncanonical-format'
                    }
                }
            }
        }catch{
            # Keep the strict failure and the bounded secondary classification. Never retain response text.
        }
    }
    return [pscustomobject][ordered]@{
        httpStatus=$strict.httpStatus;finishReason=$strict.finishReason
        actualPromptTokens=$strict.actualPromptTokens;actualOutputTokens=$strict.actualOutputTokens
        originalGrade=$strict.grade;originalErrorCode=$strict.errorCode
        originalClassification=$strict.classification;diagnosticClassification=$classification
    }
}

function Get-FastLlmArithmeticDiagnosticCase {
    $cases=@(Get-FastLlmTaskWorkloadCases -DistractorCount 0)
    Assert-TaskQualityCases -Cases $cases -DistractorCount 0
    $selected=@($cases|Where-Object {$_.id -ceq 'arithmetic-steps-v1'})
    $promptSha=if($selected.Count -eq 1){Get-FastLlmTaskWorkloadPromptSha256 -Case $selected[0]}else{$null}
    $referenceSha=if($selected.Count -eq 1){Get-FastLlmTaskWorkloadReferenceSha256 -Case $selected[0]}else{$null}
    if($selected.Count -ne 1 -or $selected[0].suiteVersion -cne (Get-FastLlmTaskWorkloadSuiteVersion) -or
       $selected[0].kind -cne 'arithmetic' -or $selected[0].expected -cne '63' -or
       [int]$selected[0].maxOutputTokens -ne 32 -or $null -ne $selected[0].responseFormat -or
       [int]$selected[0].distractorCount -ne 0 -or
       $selected[0].gradingNormalization -cne 'trim-leading-trailing-whitespace-only' -or
       $promptSha -cne '8075c10d5c487b7976efbbb22ef8d50fcef17697aa6b12559945459d1c04c028' -or
       $referenceSha -cne '3f6195f88d915f645e3a63eab36fed5bfc54e67f80152c1e178e359b7bb7eef9'){
        throw 'The fixed arithmetic task differs from the canonical workload.'
    }
    return $selected[0]
}

function Invoke-FastLlmArithmeticDiagnosticCore {
    param([Parameter(Mandatory=$true)][string]$OutputPath,
          [Parameter(Mandatory=$true)][scriptblock]$ReadState,
          [Parameter(Mandatory=$true)][scriptblock]$Request,
          [Parameter(Mandatory=$true)][scriptblock]$CheckProcess,
          [Parameter(Mandatory=$true)][string]$ToolSourcePath,
          [Parameter(Mandatory=$true)][string]$TaskQualityToolSourcePath,
          [ValidateRange(1,180)][int]$DeadlineSeconds=90,
          [ValidateRange(1,60)][int]$RequestTimeoutSeconds=60)
    if($RequestTimeoutSeconds -gt $DeadlineSeconds){throw 'Arithmetic request timeout exceeds the overall diagnostic budget.'}
    if(Test-Path -LiteralPath $OutputPath){throw 'Arithmetic diagnostic output already exists.'}
    $full=[IO.Path]::GetFullPath($OutputPath)
    $parent=Split-Path $full -Parent
    if(-not (Test-Path -LiteralPath $parent -PathType Container)){throw 'Arithmetic diagnostic output parent does not exist.'}
    foreach($name in @('Get-FastLlmTaskWorkloadCases','Get-FastLlmTaskWorkloadSuiteVersion',
                       'Get-FastLlmTaskWorkloadPromptSha256','Get-FastLlmTaskWorkloadReferenceSha256',
                       'Assert-TaskQualityCases','New-TaskQualityRequestBody','ConvertFrom-TaskQualityResponse',
                       'Assert-FastLlmSemanticSmokeState')){
        if(-not (Get-Command $name -CommandType Function -ErrorAction SilentlyContinue)){
            throw 'Arithmetic diagnostic dependency is unavailable.'
        }
    }
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $source=Get-FastLlmArithmeticDiagnosticSourceHashes -ToolSourcePath $ToolSourcePath `
        -TaskQualityToolSourcePath $TaskQualityToolSourcePath
    $case=Get-FastLlmArithmeticDiagnosticCase
    $first=& $ReadState
    $binding=Assert-FastLlmSemanticSmokeState -State $first
    & $CheckProcess $first
    $bodyJson=New-TaskQualityRequestBody -State $first -Case $case
    try{$body=ConvertFrom-Json -InputObject $bodyJson -ErrorAction Stop}catch{throw 'Canonical arithmetic request construction failed.'}
    $bodyNames=@($body.PSObject.Properties.Name)
    if($bodyNames.Count -ne 8 -or $null -ne $body.PSObject.Properties['response_format'] -or
       $body.model -cne [string]$first.modelId -or @($body.messages).Count -ne 1 -or
       $body.messages[0].role -cne 'user' -or $body.messages[0].content -cne [string]$case.prompt -or
       [int]$body.max_tokens -ne 32 -or [int]$body.temperature -ne 0 -or [int]$body.seed -ne 42 -or
       $body.stream -ne $false -or $body.cache_prompt -ne $false -or
       $body.chat_template_kwargs.enable_thinking -ne $false){
        throw 'Canonical arithmetic request differs from the task assessment.'
    }

    $reportStatus='complete';$failureCode=$null;$bindingStatus='verified';$sourceStatus='verified'
    $requestIssued=0;$result=New-FastLlmArithmeticDiagnosticResult;$response=$null
    try{
        $state=& $ReadState
        $null=Assert-FastLlmSemanticSmokeState -State $state -ExpectedBinding $binding
        & $CheckProcess $state
    }catch{$failureCode='identity-changed';$bindingStatus='compromised'}
    if(-not $failureCode -and -not (Test-FastLlmArithmeticDiagnosticSourceHashes -Expected $source `
        -ToolSourcePath $ToolSourcePath -TaskQualityToolSourcePath $TaskQualityToolSourcePath)){
        $failureCode='source-changed';$sourceStatus='changed'
    }
    $remaining=[int][Math]::Floor(($DeadlineSeconds-$clock.Elapsed.TotalSeconds)*1000)
    if(-not $failureCode -and $remaining -le 0){$failureCode='deadline'}
    if(-not $failureCode){
        $requestIssued=1
        try{$response=& $Request '/v1/chat/completions' $body ([Math]::Min($RequestTimeoutSeconds*1000,$remaining))}
        catch{$failureCode='request-error'}
    }
    try{
        $state=& $ReadState
        $null=Assert-FastLlmSemanticSmokeState -State $state -ExpectedBinding $binding
        & $CheckProcess $state
    }catch{$failureCode='identity-changed';$bindingStatus='compromised'}
    if(-not (Test-FastLlmArithmeticDiagnosticSourceHashes -Expected $source -ToolSourcePath $ToolSourcePath `
        -TaskQualityToolSourcePath $TaskQualityToolSourcePath)){
        $sourceStatus='changed'
        if($bindingStatus -ceq 'verified'){$failureCode='source-changed'}
    }
    if($clock.Elapsed.TotalSeconds -gt $DeadlineSeconds -and $bindingStatus -ceq 'verified' -and
       $sourceStatus -ceq 'verified'){$failureCode='deadline'}
    if(-not $failureCode -and $requestIssued -eq 1){
        $result=Get-FastLlmArithmeticDiagnosticClassification -Response $response -Case $case `
            -EffectiveContext ([int]$first.recipe.contextSize)
    }
    try{
        $state=& $ReadState
        $null=Assert-FastLlmSemanticSmokeState -State $state -ExpectedBinding $binding
        & $CheckProcess $state
    }catch{$failureCode='identity-changed';$bindingStatus='compromised'}
    if(-not (Test-FastLlmArithmeticDiagnosticSourceHashes -Expected $source -ToolSourcePath $ToolSourcePath `
        -TaskQualityToolSourcePath $TaskQualityToolSourcePath)){
        $sourceStatus='changed'
        if($bindingStatus -ceq 'verified'){$failureCode='source-changed'}
    }
    if($clock.Elapsed.TotalSeconds -gt $DeadlineSeconds -and $bindingStatus -ceq 'verified' -and
       $sourceStatus -ceq 'verified'){$failureCode='deadline'}
    if($failureCode){
        $reportStatus='aborted'
        $result=New-FastLlmArithmeticDiagnosticResult -ErrorCode $failureCode
    }
    $report=[ordered]@{
        schemaVersion=1;resultKind='private-windows-arithmetic-diagnostic';recordedAt=[DateTime]::UtcNow.ToString('o')
        reportStatus=$reportStatus;failureCode=$failureCode;bindingStatus=$bindingStatus
        runId=$first.runId;processIdentity=$first.processIdentity;modelId=$first.modelId;modelSha256=$first.modelSha256
        engineVersion=$first.engineVersion;recipe=$first.recipe;endpoint=$first.endpoint;evidenceBindingSha256=$binding
        sourceProvenance=@{sha256=$source;endStatus=$sourceStatus;scope='On-disk SHA-256 before/after; loaded code not attested'}
        methodology=@{protocolVersion='arithmetic-format-diagnostic-v1';suiteVersion=(Get-FastLlmTaskWorkloadSuiteVersion)
            fixedCaseId=$case.id;promptSha256=(Get-FastLlmTaskWorkloadPromptSha256 -Case $case)
            priorProtocolScope='exact arithmetic-steps-v1 identity from task-quality-assessment-v1'
            distractorCount=0;plannedRequests=1;issuedRequests=$requestIssued;retryCount=0;responseFormat='none'
            maxOutputTokens=32;stream=$false;sampling='temperature-0-seed-42-thinking-disabled';prefixCache=$false
            requestTimeoutSeconds=$RequestTimeoutSeconds;elapsedBudgetSeconds=$DeadlineSeconds
            hardRequestTimeout=$true;hardWallClockDeadline=$false;outerProcessDeadlineOwner=$false
            strictParser='unchanged task-quality assessment parser';secondaryParser='anchored fixed-value formatting classifier; no expression evaluation or prose search'}
        result=$result;diagnosticConclusive=($reportStatus -ceq 'complete' -and
            @('strict-pass','correct-value-noncanonical-format','wrong-numeric-value') -ccontains [string]$result.diagnosticClassification)
        rawPromptOrResponseRetained=$false;answerTextRetained=$false;answerSha256Retained=$false
        qualification=@{approved=$false;qualityEvaluation=$false;semanticQualified=$false;performanceQualified=$false;physicalResidency=$false}
    }
    $json=ConvertTo-Json -InputObject $report -Depth 20
    $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($json+"`n")
    if($bytes.Length -gt 65536){throw 'Arithmetic diagnostic report exceeds its private size bound.'}
    $file=[IO.File]::Open($full,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$file.Write($bytes,0,$bytes.Length);$file.Flush()}finally{$file.Dispose()}
    return [pscustomobject]$report
}

function Invoke-FastLlmArithmeticDiagnostic {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$InstallRoot,
          [Parameter(Mandatory=$true)][string]$OutputPath,
          [Parameter(Mandatory=$true)][string]$ToolSourcePath,
          [Parameter(Mandatory=$true)][string]$TaskQualityToolSourcePath,
          [ValidateRange(1,180)][int]$DeadlineSeconds=90,
          [ValidateRange(1,60)][int]$RequestTimeoutSeconds=60)
    if($env:OS -cne 'Windows_NT' -or -not [Environment]::Is64BitProcess){throw 'Arithmetic diagnostic requires native 64-bit Windows.'}
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run arithmetic diagnostic as a standard user.'}
    if($OutputPath -cnotmatch '^[A-Za-z]:\\' -or [IO.Path]::GetExtension($OutputPath) -ine '.json'){
        throw 'OutputPath must be an absolute local-drive .json file.'
    }
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
    $stateRoot=Get-FastLlmStateRoot -InstallRoot $InstallRoot
    $lockPath=Join-FastLlmContainedPath -Root $stateRoot -Child 'benchmark.lock'
    if((Test-Path -LiteralPath $lockPath) -and ((Get-Item -LiteralPath $lockPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){
        throw 'Unsafe benchmark lock.'
    }
    try{$lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
    catch{throw 'A benchmark or semantic diagnostic is active.'}
    try{
        return Invoke-FastLlmArithmeticDiagnosticCore -OutputPath $full -ToolSourcePath $ToolSourcePath `
            -TaskQualityToolSourcePath $TaskQualityToolSourcePath -DeadlineSeconds $DeadlineSeconds `
            -RequestTimeoutSeconds $RequestTimeoutSeconds -ReadState {Get-FastLlmStatus -InstallRoot $InstallRoot} `
            -Request {param($Path,$Body,$TimeoutMs) Invoke-FastLlmHttp -BaseUrl 'http://127.0.0.1:8080' -Path $Path -Body $Body -TimeoutMs $TimeoutMs} `
            -CheckProcess {param($State) Assert-FastLlmSemanticSmokeProcess -State $State}
    }finally{$lock.Dispose()}
}
