# Private, fixed-case diagnostic for one already-Ready normal Windows run.
# The fixed prompt and strict grader come from FastLlm.SemanticSmoke.ps1.
function Get-FastLlmJsonFormatClassification {
    param($Response,$Case)
    $strict=ConvertFrom-FastLlmSemanticSmokeResponse -Response $Response -Case $Case
    $classification='wrong-or-invalid'
    if($strict.outcome -ceq 'pass'){$classification='strict-pass'}
    elseif($strict.outcome -ceq 'inconclusive'){$classification='inconclusive'}
    elseif($strict.outcome -ceq 'fail'){
        try{
            $body=ConvertFrom-Json -InputObject $Response.Body -ErrorAction Stop
            $content=[string]$body.choices[0].message.content
            # One complete fenced block, with no surrounding prose or second block.
            $match=[regex]::Match($content,'\A```(?:json)?\r?\n(?<inner>[\s\S]{1,4096}?)\r?\n```\z')
            if($match.Success){
                $body.choices[0].message.content=$match.Groups['inner'].Value
                $unwrapped=[pscustomobject]@{Status=$Response.Status;Body=(ConvertTo-Json -InputObject $body -Depth 16 -Compress)}
                $inner=ConvertFrom-FastLlmSemanticSmokeResponse -Response $unwrapped -Case $Case
                if($inner.outcome -ceq 'pass'){$classification='fenced-valid-json'}
            }
        }catch{
            # Classification remains wrong-or-invalid. Never retain response text.
        }
    }
    return [pscustomobject]@{strictOutcome=$strict.outcome;strictErrorCode=$strict.errorCode;
        classification=$classification;outputTokens=$strict.outputTokens}
}

function Invoke-FastLlmJsonFormatDiagnosticCore {
    param([string]$OutputPath,[scriptblock]$ReadState,[scriptblock]$Request,[scriptblock]$CheckProcess,
          [string]$ToolSourcePath,[int]$DeadlineSeconds=180,
          [ValidateSet('compare','unconstrained-only','json-object-only','explicit-object-schema')][string]$Mode='compare')
    if($DeadlineSeconds -lt 1 -or $DeadlineSeconds -gt 180){throw 'JSON-format deadline is outside fixed bounds.'}
    if(Test-Path -LiteralPath $OutputPath){throw 'JSON-format output already exists.'}
    $case=@(Get-FastLlmSemanticSmokeCases | Where-Object id -CEQ 'json-extract-v1')
    if($case.Count -ne 1 -or $case[0].kind -cne 'json'){throw 'Fixed JSON semantic case is unavailable.'}
    $case=$case[0]
    $sourcePath=Join-Path $PSScriptRoot 'FastLlm.JsonFormatDiagnostic.ps1'
    $semanticPath=Join-Path $PSScriptRoot 'FastLlm.SemanticSmoke.ps1'
    $sourceSha=(Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $semanticSha=(Get-FileHash -LiteralPath $semanticPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $toolSha=if($ToolSourcePath){(Get-FileHash -LiteralPath $ToolSourcePath -Algorithm SHA256).Hash.ToLowerInvariant()}else{$null}
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $first=& $ReadState
    $binding=Assert-FastLlmSemanticSmokeState -State $first
    & $CheckProcess $first
    $variants=@('unconstrained','json_object')
    if($Mode -ceq 'unconstrained-only'){$variants=@('unconstrained')}
    elseif($Mode -ceq 'json-object-only'){$variants=@('json_object')}
    elseif($Mode -ceq 'explicit-object-schema'){$variants=@('explicit-object-schema')}
    $results=@();$aborted=$false;$failureCode=$null
    foreach($variant in $variants){
        $classification='inconclusive';$strictOutcome='inconclusive';$strictErrorCode=$null;$outputTokens=$null;$httpStatus=$null
        try{
            $current=& $ReadState
            $null=Assert-FastLlmSemanticSmokeState -State $current -ExpectedBinding $binding
            & $CheckProcess $current
            $remaining=[int][Math]::Floor(($DeadlineSeconds-$timer.Elapsed.TotalSeconds)*1000)
            if($remaining -le 0){$failureCode='deadline';$aborted=$true;break}
            # Exactly the fixed semantic-smoke JSON case and sampling controls.
            $body=@{model=$first.modelId;messages=@(@{role='user';content=$case.prompt});max_tokens=96;temperature=0;seed=42;
                stream=$false;cache_prompt=$false;chat_template_kwargs=@{enable_thinking=$false}}
            if($variant -ceq 'json_object'){$body.response_format=@{type='json_object'}}
            if($variant -ceq 'explicit-object-schema'){$body.response_format=@{type='json_object';schema=@{type='object'}}}
            try{$response=& $Request '/v1/chat/completions' $body ([Math]::Min(60000,$remaining))}
            catch{$strictErrorCode='request-error';$response=$null}
            $current=& $ReadState
            $null=Assert-FastLlmSemanticSmokeState -State $current -ExpectedBinding $binding
            & $CheckProcess $current
            if($timer.Elapsed.TotalSeconds -gt $DeadlineSeconds){$failureCode='deadline';$aborted=$true;$strictErrorCode='deadline'}
            elseif($null -ne $response){
                $httpStatus=[int]$response.Status
                $parsed=Get-FastLlmJsonFormatClassification -Response $response -Case $case
                $classification=$parsed.classification;$strictOutcome=$parsed.strictOutcome
                $strictErrorCode=$parsed.strictErrorCode;$outputTokens=$parsed.outputTokens
            }
        }catch{$failureCode='identity-changed';$aborted=$true;$strictErrorCode='identity-changed'}
        $result=[ordered]@{variant=$variant;responseFormat=$(if($variant -ceq 'unconstrained'){'none'}else{'json_object'});
            httpStatus=$httpStatus;strictOutcome=$strictOutcome;strictErrorCode=$strictErrorCode;
            classification=$classification;outputTokens=$outputTokens}
        if($variant -ceq 'explicit-object-schema'){$result.schema=@{type='object'}}
        $results+= [pscustomobject]$result
        if($aborted){break}
    }
    try{$current=& $ReadState;$null=Assert-FastLlmSemanticSmokeState -State $current -ExpectedBinding $binding;& $CheckProcess $current}
    catch{$failureCode='identity-changed';$aborted=$true}
    if($timer.Elapsed.TotalSeconds -gt $DeadlineSeconds){$failureCode='deadline';$aborted=$true}
    if((Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $sourceSha -or
       (Get-FileHash -LiteralPath $semanticPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $semanticSha -or
       ($ToolSourcePath -and (Get-FileHash -LiteralPath $ToolSourcePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $toolSha)){
        throw 'JSON-format diagnostic source changed during the run.'
    }
    $report=[ordered]@{
        schemaVersion=1;resultKind='private-windows-json-format-diagnostic';recordedAt=[DateTime]::UtcNow.ToString('o')
        runId=$first.runId;processIdentity=$first.processIdentity;modelId=$first.modelId;modelSha256=$first.modelSha256
        engineVersion=$first.engineVersion;engineSha256=$first.recipe.engineSha256;catalogSha256=$first.recipe.catalogSha256
        contextSize=[int]$first.recipe.contextSize;endpoint=$first.endpoint;evidenceBindingSha256=$binding
        fixedCaseId=$case.id;fixedPromptSha256=(Get-FastLlmSemanticSmokeSha256 $case.prompt)
        sourceProvenance=@{diagnosticSha256=$sourceSha;semanticSmokeSha256=$semanticSha;toolSha256=$toolSha;
            scope='on-disk SHA-256 checked before/after; loaded-code identity is not attested'}
        methodology=@{requestVariants=$variants;singleDifference=$(if($Mode -ceq 'compare'){'response_format:{type:json_object}'}else{'not applicable: one fixed-case request'});
            sampling='temperature-0-seed-42';thinkingRequested=$false;prefixCache=$false;maxOutputTokens=96;
            concurrency=1;requestTimeoutMaximumSeconds=60;elapsedBudgetSeconds=$DeadlineSeconds;hardWallClockDeadline=$false;
            interpretation=$(if($Mode -ceq 'compare'){'Two fixed-case observations only; OS process and file calls are not preempted'}else{'One fixed-case observation only; OS process and file calls are not preempted'})}
        results=$results;aborted=$aborted;failureCode=$failureCode;rawPromptOrResponseRetained=$false
        qualification=@{approved=$false;semanticQualified=$false;qualityEvaluation=$false;performanceQualified=$false;physicalResidency=$false}
    }
    if($Mode -cne 'compare'){$report['diagnosticMode']=$Mode}
    if($Mode -ceq 'explicit-object-schema'){
        $report['methodology']['responseFormatSchema']=@{type='object'}
    }
    $full=[IO.Path]::GetFullPath($OutputPath)
    $parent=Split-Path $full -Parent
    if(-not (Test-Path -LiteralPath $parent -PathType Container)){throw 'JSON-format output parent does not exist.'}
    $json=ConvertTo-Json -InputObject $report -Depth 16
    $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($json+"`n")
    if($bytes.Length -gt 32768){throw 'JSON-format report exceeds its bound.'}
    $file=[IO.File]::Open($full,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$file.Write($bytes,0,$bytes.Length);$file.Flush()}finally{$file.Dispose()}
    return [pscustomobject]$report
}

function Invoke-FastLlmJsonFormatDiagnostic {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$InstallRoot,[Parameter(Mandatory=$true)][string]$OutputPath,
          [Parameter(Mandatory=$true)][string]$ToolSourcePath,
          [ValidateSet('compare','unconstrained-only','json-object-only','explicit-object-schema')][string]$Mode='compare')
    if($env:OS -cne 'Windows_NT' -or -not [Environment]::Is64BitProcess){throw 'JSON-format diagnostic requires native 64-bit Windows.'}
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run JSON-format diagnostic as a standard user.'}
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
    $path=Join-FastLlmContainedPath -Root $stateRoot -Child 'benchmark.lock'
    if((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){
        throw 'Unsafe benchmark lock.'
    }
    try{$lock=[IO.File]::Open($path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
    catch{throw 'A benchmark or semantic diagnostic is active.'}
    try{
        return Invoke-FastLlmJsonFormatDiagnosticCore -OutputPath $full -ToolSourcePath $ToolSourcePath -Mode $Mode `
            -ReadState {Get-FastLlmStatus -InstallRoot $InstallRoot} `
            -Request {param($Path,$Body,$TimeoutMs) Invoke-FastLlmHttp -BaseUrl 'http://127.0.0.1:8080' -Path $Path -Body $Body -TimeoutMs $TimeoutMs} `
            -CheckProcess {param($State) Assert-FastLlmSemanticSmokeProcess -State $State}
    }finally{$lock.Dispose()}
}
