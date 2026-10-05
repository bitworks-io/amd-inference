# Private, fixed-case semantic smoke check for a supervised normal Windows run.
# This is deliberately separate from the benchmark and recipe qualification paths.
function Get-FastLlmSemanticSmokeSha256 {
    param([string]$Value)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)))).Replace('-','').ToLowerInvariant()}
    finally{$sha.Dispose()}
}

function Get-FastLlmSemanticSmokeCases {
    return @(
        [pscustomobject]@{id='arithmetic-v1';prompt='What is 7 + 5? Reply with only the decimal number.';expected='12';kind='exact'}
        [pscustomobject]@{id='json-extract-v1';prompt='From this sentence, return only a JSON object with exactly the keys name and age: Ada is 37 years old.';expectedName='Ada';expectedAge=37;kind='json'}
        [pscustomobject]@{id='single-word-v1';prompt='Reply with exactly this one uppercase word and nothing else: READY';expected='READY';kind='exact'}
    )
}

function Get-FastLlmSemanticSmokeBinding {
    param($State)
    $identity=[ordered]@{
        runId=$State.runId;pid=[int]$State.processIdentity.pid;startUtcTicks=[long]$State.processIdentity.startUtcTicks
        modelId=$State.modelId;modelSha256=$State.modelSha256;engineVersion=$State.engineVersion
        engineSha256=$State.recipe.engineSha256;catalogSha256=$State.recipe.catalogSha256
        endpoint=$State.endpoint;recipe=$State.recipe;placement=$State.placement;canary=$State.canary
    }
    return Get-FastLlmSemanticSmokeSha256 (ConvertTo-Json -InputObject $identity -Depth 16 -Compress)
}

function Assert-FastLlmSemanticSmokeState {
    param($State,[string]$ExpectedBinding)
    if(-not $State -or [int]$State.schemaVersion -ne 1 -or $State.active -isnot [bool] -or -not $State.active -or $State.phase -cne 'ready' -or
       $State.endpoint -cne 'http://127.0.0.1:8080/v1' -or $State.runId -cnotmatch '^[0-9a-f]{32}$' -or
       $State.modelId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._+-]{0,199}$' -or
       $State.modelSha256 -cnotmatch '^[0-9a-f]{64}$' -or $State.engineVersion -cne 'b10698' -or
       -not $State.recipe -or $State.recipe.backend -cne 'Vulkan' -or
       $State.recipe.engineSha256 -cnotmatch '^[0-9a-f]{64}$' -or $State.recipe.catalogSha256 -cnotmatch '^[0-9a-f]{64}$' -or
       [int]$State.recipe.contextSize -lt 256 -or [int]$State.recipe.slots -ne 1 -or
       [int]$State.processIdentity.pid -le 0 -or [long]$State.processIdentity.startUtcTicks -le 0 -or
       $State.canary.modelIdentity -isnot [bool] -or -not $State.canary.modelIdentity -or
       $State.canary.repeatableToken -isnot [bool] -or -not $State.canary.repeatableToken -or
       $State.canary.synchronousChat -isnot [bool] -or -not $State.canary.synchronousChat -or
       $State.canary.streaming -isnot [bool] -or -not $State.canary.streaming -or
       $State.canary.semanticCorrectnessQualified -isnot [bool] -or $State.canary.semanticCorrectnessQualified -or
       [int]$State.canary.effectiveContext -ne [int]$State.recipe.contextSize -or
       $State.placement.reportedAllLayers -isnot [bool] -or -not $State.placement.reportedAllLayers -or
       [int]$State.placement.reportedLayers -le 0 -or
       [int]$State.placement.reportedLayers -ne [int]$State.placement.totalLayers -or
       -not $State.placement.devices -or @($State.placement.devices).Count -lt 1 -or
       -not (Test-FastLlmSemanticSmokeArgument @($State.recipe.requestedArguments) '--host' '127.0.0.1') -or
       -not (Test-FastLlmSemanticSmokeArgument @($State.recipe.requestedArguments) '--port' '8080') -or
       -not (Test-FastLlmSemanticSmokeArgument @($State.recipe.requestedArguments) '--alias' ([string]$State.modelId)) -or
       -not (Test-FastLlmSemanticSmokeArgument @($State.recipe.requestedArguments) '--parallel' '1') -or
       -not (Test-FastLlmSemanticSmokeArgument @($State.recipe.requestedArguments) '--ctx-size' ([string]$State.recipe.contextSize))){
        throw 'The exact supervised normal inference run is not ready or its state is inconsistent.'
    }
    $binding=Get-FastLlmSemanticSmokeBinding $State
    if($ExpectedBinding -and $binding -cne $ExpectedBinding){throw 'Supervised run binding changed during semantic smoke.'}
    return $binding
}

function Test-FastLlmSemanticSmokeArgument {
    param([object[]]$Arguments,[string]$Name,[string]$Expected)
    $indices=@(for($i=0;$i -lt $Arguments.Count;$i++){if([string]$Arguments[$i] -ceq $Name){$i}})
    return $indices.Count -eq 1 -and $indices[0]+1 -lt $Arguments.Count -and [string]$Arguments[$indices[0]+1] -ceq $Expected
}

function Assert-FastLlmSemanticSmokeProcess {
    param($State)
    if(-not ('Bitworks.FastLlm.WindowsGpuTelemetry' -as [type])){
        Add-Type -Path (Join-Path $PSScriptRoot 'WindowsGpuTelemetry.cs') -ErrorAction Stop
    }
    $owners=@([Bitworks.FastLlm.WindowsGpuTelemetry]::GetLoopbackListenerOwners(8080))
    if($owners.Count -ne 1 -or [int]$owners[0] -ne [int]$State.processIdentity.pid){throw 'Loopback listener owner changed.'}
    $process=$null
    try{
        $process=[Diagnostics.Process]::GetProcessById([int]$State.processIdentity.pid)
        if($process.HasExited -or $process.ProcessName -cne 'llama-server' -or
           [long]$process.StartTime.ToUniversalTime().Ticks -ne [long]$State.processIdentity.startUtcTicks){throw 'Serving process identity changed.'}
        if((Get-FileHash -LiteralPath $process.MainModule.FileName -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$State.recipe.engineSha256){
            throw 'Serving executable digest changed.'
        }
    }finally{if($process){$process.Dispose()}}
}

function ConvertFrom-FastLlmSemanticSmokeResponse {
    param($Response,$Case)
    if($null -eq $Response -or $Response.Status -ne 200){return [pscustomobject]@{outcome='inconclusive';errorCode='http-status';outputTokens=$null}}
    if(-not $Response.Body -or $Response.Body.Length -gt 131072){return [pscustomobject]@{outcome='inconclusive';errorCode='invalid-response';outputTokens=$null}}
    try{$body=ConvertFrom-Json $Response.Body}catch{return [pscustomobject]@{outcome='inconclusive';errorCode='invalid-response';outputTokens=$null}}
    $choicesProperty=if($null -ne $body){$body.PSObject.Properties['choices']}else{$null}
    if(-not $choicesProperty -or @($choicesProperty.Value).Count -ne 1){
        return [pscustomobject]@{outcome='inconclusive';errorCode='invalid-response';outputTokens=$null}
    }
    $choice=@($choicesProperty.Value)[0]
    $messageProperty=if($null -ne $choice){$choice.PSObject.Properties['message']}else{$null}
    if(-not $messageProperty -or $null -eq $messageProperty.Value){
        return [pscustomobject]@{outcome='inconclusive';errorCode='invalid-response';outputTokens=$null}
    }
    $message=$messageProperty.Value
    $roleProperty=$message.PSObject.Properties['role']
    if(-not $roleProperty -or $roleProperty.Value -cne 'assistant'){
        return [pscustomobject]@{outcome='inconclusive';errorCode='invalid-response';outputTokens=$null}
    }
    if(-not $choice.PSObject.Properties['finish_reason'] -or $choice.finish_reason -isnot [string]){
        return [pscustomobject]@{outcome='inconclusive';errorCode='invalid-response';outputTokens=$null}
    }
    if($choice.finish_reason -ceq 'length'){return [pscustomobject]@{outcome='inconclusive';errorCode='truncated';outputTokens=$null}}
    if($choice.finish_reason -cne 'stop'){
        return [pscustomobject]@{outcome='inconclusive';errorCode='unexpected-finish';outputTokens=$null}
    }
    foreach($field in @('reasoning_content','reasoning')){
        $reasoning=$message.PSObject.Properties[$field]
        if($reasoning -and -not [string]::IsNullOrWhiteSpace([string]$reasoning.Value)){
            return [pscustomobject]@{outcome='inconclusive';errorCode='reasoning-observed';outputTokens=$null}
        }
    }
    $contentProperty=$message.PSObject.Properties['content']
    $content=if($contentProperty){$contentProperty.Value}else{$null}
    if($content -isnot [string] -or [string]::IsNullOrWhiteSpace($content) -or $content.Length -gt 16384){
        return [pscustomobject]@{outcome='inconclusive';errorCode='missing-visible-answer';outputTokens=$null}
    }
    if($content -cmatch '(?i)</?think\b|</?analysis\b'){
        return [pscustomobject]@{outcome='inconclusive';errorCode='visible-reasoning';outputTokens=$null}
    }
    $tokenCount=$null
    $usageProperty=$body.PSObject.Properties['usage']
    if($usageProperty -and $null -ne $usageProperty.Value -and $usageProperty.Value.PSObject.Properties['completion_tokens']){
        $raw=$usageProperty.Value.completion_tokens
        if(($raw -isnot [int] -and $raw -isnot [long]) -or [long]$raw -lt 0 -or [long]$raw -gt 96){
            return [pscustomobject]@{outcome='inconclusive';errorCode='invalid-usage';outputTokens=$null}
        }
        $tokenCount=[int]$raw
    }
    $trimmed=$content.Trim()
    $matched=$false
    if($Case.kind -ceq 'exact'){$matched=$trimmed -ceq $Case.expected}
    elseif($Case.kind -ceq 'json'){
        try{
            # A deliberately narrow contract: exact keys and canonical values,
            # in either order. Anchoring the raw JSON also rejects duplicate keys,
            # which ConvertFrom-Json would otherwise collapse.
            $shape=$trimmed -cmatch '^\{\s*"name"\s*:\s*"Ada"\s*,\s*"age"\s*:\s*37\s*\}$' -or
                   $trimmed -cmatch '^\{\s*"age"\s*:\s*37\s*,\s*"name"\s*:\s*"Ada"\s*\}$'
            if(-not $shape){throw 'Unexpected JSON shape.'}
            $json=ConvertFrom-Json $trimmed
            $names=@($json.PSObject.Properties.Name)
            $matched=$names.Count -eq 2 -and $names -ccontains 'name' -and $names -ccontains 'age' -and
                     $json.name -is [string] -and $json.name -ceq $Case.expectedName -and
                     ($json.age -is [int] -or $json.age -is [long]) -and [int]$json.age -eq $Case.expectedAge
        }catch{$matched=$false}
    }
    return [pscustomobject]@{outcome=$(if($matched){'pass'}else{'fail'});errorCode=$(if($matched){$null}else{'unexpected-answer'});outputTokens=$tokenCount}
}

function Invoke-FastLlmSemanticSmokeCore {
    param([string]$OutputPath,[scriptblock]$ReadState,[scriptblock]$Request,[scriptblock]$CheckProcess,[int]$DeadlineSeconds=240)
    if($DeadlineSeconds -lt 1 -or $DeadlineSeconds -gt 240){throw 'Semantic smoke deadline is outside fixed bounds.'}
    if(Test-Path -LiteralPath $OutputPath){throw 'Semantic smoke output already exists.'}
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $sourcePath=Join-Path $PSScriptRoot 'FastLlm.SemanticSmoke.ps1'
    $sourceSha=(Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $first=& $ReadState
    $binding=Assert-FastLlmSemanticSmokeState -State $first
    & $CheckProcess $first
    $cases=@();$aborted=$false
    foreach($case in @(Get-FastLlmSemanticSmokeCases)){
        $outcome='inconclusive';$errorCode=$null;$outputTokens=$null;$fatal=$false
        try{
            $current=& $ReadState;$null=Assert-FastLlmSemanticSmokeState -State $current -ExpectedBinding $binding;& $CheckProcess $current
            $remaining=[int][Math]::Floor(($DeadlineSeconds-$timer.Elapsed.TotalSeconds)*1000)
            if($remaining -le 0){$errorCode='deadline';$fatal=$true}
            else{
                $body=@{model=$first.modelId;messages=@(@{role='user';content=$case.prompt});max_tokens=96;temperature=0;seed=42;
                    stream=$false;cache_prompt=$false;chat_template_kwargs=@{enable_thinking=$false}}
                try{$response=& $Request '/v1/chat/completions' $body ([Math]::Min(60000,$remaining))}
                catch{$errorCode='request-error'}
                $current=& $ReadState;$null=Assert-FastLlmSemanticSmokeState -State $current -ExpectedBinding $binding;& $CheckProcess $current
                if(-not $errorCode){
                    $parsed=ConvertFrom-FastLlmSemanticSmokeResponse -Response $response -Case $case
                    $outcome=$parsed.outcome;$errorCode=$parsed.errorCode;$outputTokens=$parsed.outputTokens
                }
                if($timer.Elapsed.TotalSeconds -gt $DeadlineSeconds){$outcome='inconclusive';$errorCode='deadline';$fatal=$true}
            }
        }catch{$outcome='inconclusive';$errorCode='identity-changed';$fatal=$true}
        $cases+= [pscustomobject]@{caseId=$case.id;promptSha256=(Get-FastLlmSemanticSmokeSha256 $case.prompt);
            outcome=$outcome;errorCode=$errorCode;outputTokens=$outputTokens}
        if($fatal){$aborted=$true;break}
    }
    try{$current=& $ReadState;$null=Assert-FastLlmSemanticSmokeState -State $current -ExpectedBinding $binding;& $CheckProcess $current}
    catch{$aborted=$true}
    if((Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $sourceSha){throw 'Semantic smoke source changed during evaluation.'}
    $passed=@($cases|Where-Object outcome -eq 'pass').Count
    $failed=@($cases|Where-Object outcome -eq 'fail').Count
    $inconclusive=@($cases|Where-Object outcome -eq 'inconclusive').Count
    $report=[ordered]@{
        schemaVersion=1;resultKind='native-windows-semantic-smoke-experiment';recordedAt=(Get-Date).ToUniversalTime().ToString('o')
        runId=$first.runId;processIdentity=$first.processIdentity;modelId=$first.modelId;modelSha256=$first.modelSha256
        engineVersion=$first.engineVersion;engineSha256=$first.recipe.engineSha256;catalogSha256=$first.recipe.catalogSha256
        endpoint=$first.endpoint;contextSize=[int]$first.recipe.contextSize;evidenceBindingSha256=$binding
        sourceProvenance=@{semanticSmokeSha256=$sourceSha;scope='on-disk SHA-256 checked at start/end; loaded-code identity is not attested'}
        methodology=@{caseSet='fastllm-fixed-semantic-smoke-v1';sampling='temperature-0-seed-42';thinkingRequested=$false;prefixCache=$false;
            maxOutputTokens=96;concurrency=1;elapsedBudgetSeconds=$DeadlineSeconds;requestTimeoutMaximumSeconds=60;
            hardWallClockDeadline=$false;interpretation='tiny hand-authored canary; elapsed request budget does not preempt OS process or file calls'}
        cases=$cases;passed=$passed;failed=$failed;inconclusive=$inconclusive;aborted=$aborted
        status=$(if($aborted){'aborted'}elseif($inconclusive -gt 0){'inconclusive'}elseif($failed -gt 0){'semantic-failures'}else{'smoke-passed'})
        qualification=@{approved=$false;semanticQualified=$false;qualityEvaluation=$false;performanceQualified=$false;physicalResidency=$false}
    }
    $full=[IO.Path]::GetFullPath($OutputPath)
    New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force -ErrorAction Stop|Out-Null
    $file=[IO.File]::Open($full,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$bytes=[Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 16));$file.Write($bytes,0,$bytes.Length)}finally{$file.Dispose()}
    return [pscustomobject]$report
}

function Invoke-FastLlmSemanticSmoke {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$InstallRoot,[Parameter(Mandatory=$true)][string]$OutputPath)
    if($env:OS -cne 'Windows_NT' -or -not [Environment]::Is64BitProcess){throw 'Semantic smoke requires native 64-bit Windows.'}
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run semantic smoke as a standard user.'}
    $stateRoot=Get-FastLlmStateRoot -InstallRoot $InstallRoot
    $path=Join-FastLlmContainedPath -Root $stateRoot -Child 'benchmark.lock'
    if((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Unsafe benchmark lock.'}
    try{$lock=[IO.File]::Open($path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
    catch{throw 'A benchmark or semantic smoke run is active.'}
    try{
        return Invoke-FastLlmSemanticSmokeCore -OutputPath $OutputPath -ReadState {Get-FastLlmStatus -InstallRoot $InstallRoot} `
            -Request {param($Path,$Body,$TimeoutMs) Invoke-FastLlmHttp -BaseUrl 'http://127.0.0.1:8080' -Path $Path -Body $Body -TimeoutMs $TimeoutMs} `
            -CheckProcess {param($State) Assert-FastLlmSemanticSmokeProcess -State $State}
    }finally{$lock.Dispose()}
}
