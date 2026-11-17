#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force -PassThru
$source=Join-Path $root 'src/FastLlm.SemanticSmoke.ps1'
. $source
$count=0
function Check($Condition,$Message){if(-not $Condition){throw $Message};$script:count++}
function TempPath {Join-Path ([IO.Path]::GetTempPath()) ('fastllm-semantic-'+[Guid]::NewGuid().ToString('N')+'.json')}
$privateResolution=& $module {param($S) . $S; @('Get-FastLlmStateRoot','Join-FastLlmContainedPath','Invoke-FastLlmHttp','Invoke-FastLlmSemanticSmoke') | ForEach-Object { [bool](Get-Command $_ -ErrorAction SilentlyContinue) }} $source
Check (@($privateResolution|Where-Object { -not $_ }).Count -eq 0) 'Standalone evaluator cannot resolve private module helpers in tool scope.'
$script:state=[pscustomobject]@{
    schemaVersion=1;active=$true;phase='ready';runId='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';endpoint='http://127.0.0.1:8080/v1'
    modelId='qwen-test';modelSha256=('a'*64);engineVersion='b10698';engineSha256=('b'*64);catalogSha256=('c'*64)
    processIdentity=[pscustomobject]@{pid=42;startUtcTicks=638000000000000000}
    canary=[pscustomobject]@{modelIdentity=$true;repeatableToken=$true;synchronousChat=$true;streaming=$true;effectiveContext=8192;semanticCorrectnessQualified=$false}
    placement=[pscustomobject]@{reportedLayers=66;totalLayers=66;reportedAllLayers=$true;devices=@('Vulkan0')}
    recipe=[pscustomobject]@{backend='Vulkan';contextSize=8192;slots=1;engineSha256=('b'*64);catalogSha256=('c'*64);
        requestedArguments=@('--host','127.0.0.1','--port','8080','--alias','qwen-test','--ctx-size','8192','--parallel','1')}
}
function New-HipState([string]$Engine='b11658',[string]$Backend='hip',[string[]]$Devices=@('ROCm0')){
    $copy=$script:state|ConvertTo-Json -Depth 8|ConvertFrom-Json
    $copy.engineVersion=$Engine;$copy.recipe.backend=$Backend;$copy.placement.devices=@($Devices)
    return $copy
}
$bothLanes=@('vulkan-b10698','hip-b11658')
Check ([bool](Assert-FastLlmSemanticSmokeState $script:state)) 'Vulkan state rejected with default lanes.'
Check ([bool](Assert-FastLlmSemanticSmokeState $script:state -AcceptedLanes $bothLanes)) 'Vulkan state rejected with both lanes.'
Check ([bool](Assert-FastLlmSemanticSmokeState (New-HipState) -AcceptedLanes $bothLanes)) 'Synthetic HIP state rejected with HIP lane enabled.'
Check ([bool](Assert-FastLlmSemanticSmokeState (New-HipState) -AcceptedLanes @('hip-b11658'))) 'Synthetic HIP state rejected with HIP lane only.'
$negatives=[ordered]@{
    'HIP state, default lanes'=@{state=(New-HipState);lanes=@('vulkan-b10698')}
    'b11658 with Vulkan backend'=@{state=(New-HipState 'b11658' 'Vulkan' @('Vulkan0'));lanes=$bothLanes}
    'b10698 with hip backend'=@{state=(New-HipState 'b10698' 'hip');lanes=$bothLanes}
    'backend upper-case HIP'=@{state=(New-HipState 'b11658' 'HIP');lanes=$bothLanes}
    'backend title-case Hip'=@{state=(New-HipState 'b11658' 'Hip');lanes=$bothLanes}
    'b9999 with hip backend'=@{state=(New-HipState 'b9999' 'hip');lanes=$bothLanes}
    'HIP state with Vulkan device'=@{state=(New-HipState 'b11658' 'hip' @('Vulkan0'));lanes=$bothLanes}
    'HIP state with mixed devices'=@{state=(New-HipState 'b11658' 'hip' @('ROCm0','Vulkan0'));lanes=$bothLanes}
    'Vulkan state with ROCm device'=@{state=(New-HipState 'b10698' 'Vulkan' @('ROCm0'));lanes=$bothLanes}
    'Vulkan state, HIP lane only'=@{state=$script:state;lanes=@('hip-b11658')}
}
foreach($name in $negatives.Keys){
    $threw=$false
    try{$null=Assert-FastLlmSemanticSmokeState $negatives[$name].state -AcceptedLanes $negatives[$name].lanes}catch{$threw=$true}
    Check $threw "State check accepted: $name."
}
$threw=$false
try{$null=Assert-FastLlmSemanticSmokeState $script:state -AcceptedLanes @('unknown-lane')}catch{$threw=$true}
Check $threw 'Unknown lane name was accepted.'
$hipState=New-HipState
$script:answers=@('12','{"name":"Ada","age":37}','READY');$script:requests=0
$out=TempPath
try{
    $report=Invoke-FastLlmSemanticSmokeCore -OutputPath $out -ReadState {$hipState} -CheckProcess {param($State)} -AcceptedLanes $bothLanes `
      -Request {param($Path,$Body,$TimeoutMs) $script:requests++;[pscustomobject]@{Status=200;Body=(@{choices=@(@{finish_reason='stop';message=@{role='assistant';content=$script:answers[$script:requests-1]}});usage=@{completion_tokens=4}}|ConvertTo-Json -Depth 8)}}
    Check ($report.passed -eq 3 -and $report.failed -eq 0 -and -not $report.aborted -and $report.engineVersion -ceq 'b11658' -and $report.backend -ceq 'hip') 'HIP state did not pass the three fixed cases with the HIP lane enabled.'
}finally{if(Test-Path $out){Remove-Item -LiteralPath $out -Force}}
$script:requests=0
$out=TempPath
$threw=$false
try{
    $null=Invoke-FastLlmSemanticSmokeCore -OutputPath $out -ReadState {$hipState} -CheckProcess {param($State)} `
      -Request {param($Path,$Body,$TimeoutMs) $script:requests++;throw 'must not be reached'}
}catch{$threw=$true}finally{if(Test-Path $out){Remove-Item -LiteralPath $out -Force}}
Check ($threw -and $script:requests -eq 0) 'HIP state ran the smoke without opting in.'
$script:answers=@('12','{"name":"Ada","age":37}','READY')
$script:requests=0;$script:checks=0
$out=TempPath
try{
    $report=Invoke-FastLlmSemanticSmokeCore -OutputPath $out -ReadState { $script:state } -CheckProcess {param($State)$script:checks++} `
        -Request {param($Path,$Body,$TimeoutMs) $script:requests++; if($Path -cne '/v1/chat/completions' -or $Body.model -cne 'qwen-test' -or $Body.temperature -ne 0 -or $Body.seed -ne 42 -or $Body.stream -ne $false -or $Body.cache_prompt -ne $false -or $Body.chat_template_kwargs.enable_thinking -ne $false -or $TimeoutMs -gt 60000){throw 'Unexpected semantic request.'};
            [pscustomobject]@{Status=200;Body=(@{choices=@(@{finish_reason='stop';message=@{role='assistant';content=$script:answers[$script:requests-1]}});usage=@{completion_tokens=4}}|ConvertTo-Json -Depth 8)}}
    Check ($report.cases.Count -eq 3 -and $report.passed -eq 3 -and $report.failed -eq 0) 'Three fixed semantic cases did not pass.'
    Check ($report.backend -ceq 'Vulkan') 'Smoke report did not carry the serving backend.'
    Check ($report.sourceProvenance.servingProfileSha256 -ceq (Get-FileHash -LiteralPath (Join-Path $root 'src/FastLlm.ServingProfileRun.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()) 'Smoke report did not state the serving-profile source hash.'
    Check ($script:requests -eq 3 -and $script:checks -ge 7) 'Each request lacked a process check before and after.'
    Check ($report.qualification.semanticQualified -eq $false -and $report.qualification.performanceQualified -eq $false) 'Smoke report claimed qualification.'
    $bytes=[IO.File]::ReadAllText($out)
    Check (-not $bytes.Contains('7 + 5') -and -not $bytes.Contains('"Ada"') -and -not $bytes.Contains('"READY"')) 'Smoke report disclosed prompt or completion content.'
    Check (@($report.cases|Where-Object {$_.promptSha256 -notmatch '^[0-9a-f]{64}$'}).Count -eq 0) 'Prompt digest absent.'
}finally{if(Test-Path $out){Remove-Item -LiteralPath $out -Force}}
$script:answers=@('13','{"name":"Ada","age":38}','ready');$script:requests=0
$out=TempPath
try{
    $report=Invoke-FastLlmSemanticSmokeCore -OutputPath $out -ReadState {$script:state} -CheckProcess {param($State)} `
      -Request {param($Path,$Body,$TimeoutMs) $script:requests++;[pscustomobject]@{Status=200;Body=(@{choices=@(@{finish_reason='stop';message=@{role='assistant';content=$script:answers[$script:requests-1]}});usage=@{completion_tokens=4}}|ConvertTo-Json -Depth 8)}}
    Check ($report.passed -eq 0 -and $report.failed -eq 3) 'Wrong semantic answers were accepted.'
}finally{if(Test-Path $out){Remove-Item -LiteralPath $out -Force}}
$script:answers=@('12','{"name":"Ada","age":37}','READY');$script:requests=0
$out=TempPath
try{
    $report=Invoke-FastLlmSemanticSmokeCore -OutputPath $out -ReadState {$script:state} -CheckProcess {param($State)} `
      -Request {param($Path,$Body,$TimeoutMs) $script:requests++;if($script:requests -eq 2){return [pscustomobject]@{Status=500;Body='private response should not leak'}};[pscustomobject]@{Status=200;Body=(@{choices=@(@{finish_reason='stop';message=@{role='assistant';content=$script:answers[$script:requests-1]}});usage=@{completion_tokens=4}}|ConvertTo-Json -Depth 8)}}
    Check ($report.passed -eq 2 -and $report.failed -eq 0 -and $report.inconclusive -eq 1 -and $report.cases[1].errorCode -eq 'http-status') 'HTTP error handling failed.'
    Check (-not ([IO.File]::ReadAllText($out)).Contains('private response')) 'HTTP body leaked.'
}finally{if(Test-Path $out){Remove-Item -LiteralPath $out -Force}}
$script:requests=0
$out=TempPath
try{
    $report=Invoke-FastLlmSemanticSmokeCore -OutputPath $out -ReadState {$script:state} `
      -CheckProcess {param($State) if($script:requests -ge 1){throw 'identity-changed'}} `
      -Request {param($Path,$Body,$TimeoutMs) $script:requests++;[pscustomobject]@{Status=200;Body='{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"12"}}]}'} }
    Check ($script:requests -eq 1 -and $report.aborted -eq $true -and $report.cases.Count -eq 1) 'Process change did not abort after first request.'
    Check ($report.cases[0].errorCode -eq 'identity-changed') 'Identity error code missing.'
}finally{if(Test-Path $out){Remove-Item -LiteralPath $out -Force}}
$fixed=(Get-FastLlmSemanticSmokeCases)[0]
$truncated=ConvertFrom-FastLlmSemanticSmokeResponse -Case $fixed -Response ([pscustomobject]@{Status=200;Body='{"choices":[{"finish_reason":"length","message":{"role":"assistant","content":"13"}}]}'})
Check ($truncated.outcome -eq 'inconclusive' -and $truncated.errorCode -eq 'truncated') 'Truncated reasoning or answer was scored as wrong.'
$reasoningOnly=ConvertFrom-FastLlmSemanticSmokeResponse -Case $fixed -Response ([pscustomobject]@{Status=200;Body='{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"","reasoning_content":"7+5=12"}}]}'})
Check ($reasoningOnly.outcome -eq 'inconclusive' -and $reasoningOnly.errorCode -eq 'reasoning-observed') 'Reasoning-only response was scored as a semantic failure.'
$missingFinish=ConvertFrom-FastLlmSemanticSmokeResponse -Case $fixed -Response ([pscustomobject]@{Status=200;Body='{"choices":[{"message":{"role":"assistant","content":"13"}}]}'})
Check ($missingFinish.outcome -eq 'inconclusive' -and $missingFinish.errorCode -eq 'invalid-response') 'Malformed response was scored as a semantic failure.'
$missingChoices=ConvertFrom-FastLlmSemanticSmokeResponse -Case $fixed -Response ([pscustomobject]@{Status=200;Body='{"usage":{"completion_tokens":2}}'})
Check ($missingChoices.outcome -eq 'inconclusive' -and $missingChoices.errorCode -eq 'invalid-response') 'Missing choices escaped strict response validation.'
$visibleThought=ConvertFrom-FastLlmSemanticSmokeResponse -Case $fixed -Response ([pscustomobject]@{Status=200;Body='{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"<think>7+5</think>12"}}]}'})
Check ($visibleThought.outcome -eq 'inconclusive' -and $visibleThought.errorCode -eq 'visible-reasoning') 'Visible thinking was scored as a semantic failure.'
$jsonCase=(Get-FastLlmSemanticSmokeCases)[1]
$duplicateJson=ConvertFrom-FastLlmSemanticSmokeResponse -Case $jsonCase -Response ([pscustomobject]@{Status=200;Body='{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"{\"name\":\"Ada\",\"age\":38,\"age\":37}"}}]}'})
Check ($duplicateJson.outcome -eq 'fail') 'Duplicate JSON keys were accepted as valid extraction.'
# --- Serving-profile runs: one predicate, refused by default, accepted only behind -AllowServingProfile ---
$defaultArgv=@('--model','<verified-model>','--offline','--no-mmproj','--spec-type','none','--alias','qwen-test','--host','127.0.0.1','--port','8080',
    '--cors-origins','localhost','--no-cors-credentials','--ctx-size','8192','--parallel','1','--n-gpu-layers','all','--fit','on','--fit-target','768',
    '--device','Vulkan0','--split-mode','none','--flash-attn','auto','--cache-type-k','f16','--cache-type-v','f16','--jinja','--metrics',
    '--log-verbosity','4','--no-agent','--no-ui')
function New-DefaultRealState{
    $copy=$script:state|ConvertTo-Json -Depth 8|ConvertFrom-Json
    $copy.recipe.requestedArguments=@($defaultArgv)
    return $copy
}
function New-ProfileState([int]$Slots=2,[int]$Total=8192,[string]$Profile='long',[string]$Cache='q8_0'){
    $copy=New-DefaultRealState
    $copy.recipe.slots=$Slots;$copy.recipe.contextSize=$Total
    $copy.recipe|Add-Member -NotePropertyName profile -NotePropertyValue $Profile
    $copy.recipe|Add-Member -NotePropertyName contextPerSlot -NotePropertyValue ([int]($Total/$Slots))
    $copy.canary.effectiveContext=[int]($Total/$Slots)
    $argv=@($defaultArgv)
    for($i=0;$i -lt $argv.Count;$i++){
        if($argv[$i] -ceq '--ctx-size'){$argv[$i+1]=[string]$Total}
        if($argv[$i] -ceq '--parallel'){$argv[$i+1]=[string]$Slots}
        if($argv[$i] -ceq '--cache-type-k' -or $argv[$i] -ceq '--cache-type-v'){$argv[$i+1]=$Cache}
    }
    $copy.recipe.requestedArguments=$argv
    return $copy
}
function Test-Refuses($State,[switch]$Allow){
    try{if($Allow){$null=Assert-FastLlmSemanticSmokeState $State -AllowServingProfile}else{$null=Assert-FastLlmSemanticSmokeState $State}}
    catch{return ($_.Exception.Message -ceq 'The exact supervised normal inference run is not ready or its state is inconsistent.')}
    return $false
}
function Set-Argument($State,[string]$Name,[string]$Value){
    $argv=@($State.recipe.requestedArguments)
    for($i=0;$i -lt $argv.Count;$i++){if($argv[$i] -ceq $Name){$argv[$i+1]=$Value}}
    $State.recipe.requestedArguments=$argv
}
$realDefault=New-DefaultRealState
Check (-not (Test-FastLlmServingProfileRun $realDefault)) 'The real default argv (with f16 cache types) is not a serving-profile run.'
Check ([bool](Assert-FastLlmSemanticSmokeState $realDefault)) 'The real default argv is refused without the switch.'
Check ([bool](Assert-FastLlmSemanticSmokeState $realDefault -AllowServingProfile)) 'The real default argv is refused with the switch.'
Check ([bool](Assert-FastLlmSemanticSmokeState $script:state -AllowServingProfile)) 'A default state is refused with the switch.'
Check (-not (Test-FastLlmServingProfileRun $script:state)) 'A default state without cache arguments is a serving-profile run.'
$bareStatus=[pscustomobject]@{active=$true;phase='ready'}
Check (-not (Test-FastLlmServingProfileRun $bareStatus)) 'A status with no recipe is a serving-profile run.'
$oldRecipe=[pscustomobject]@{recipe=[pscustomobject]@{contextSize=32768}}
Check (-not (Test-FastLlmServingProfileRun $oldRecipe)) 'A recipe with only contextSize is a serving-profile run (strict mode read).'
Check (-not (Test-FastLlmServingProfileRun $null)) 'A null state is a serving-profile run.'
# Each trigger on its own makes a profile run, and the default refuses it.
$long1=New-DefaultRealState;$long1.recipe|Add-Member -NotePropertyName profile -NotePropertyValue 'long'
$two=New-DefaultRealState;$two.recipe.slots=2
$perSlot=New-DefaultRealState;$perSlot.recipe|Add-Member -NotePropertyName contextPerSlot -NotePropertyValue 4096
$par2=New-DefaultRealState;Set-Argument $par2 '--parallel' '2'
$q8k=New-DefaultRealState;Set-Argument $q8k '--cache-type-k' 'q8_0'
$q8v=New-DefaultRealState;Set-Argument $q8v '--cache-type-v' 'q8_0'
$dupCache=New-DefaultRealState;$dupCache.recipe.requestedArguments=@($defaultArgv)+@('--cache-type-k','f16')
$noValue=New-DefaultRealState;$noValue.recipe.requestedArguments=@($defaultArgv|Where-Object {$true})+@('--cache-type-v')
$eqForm=New-DefaultRealState;$eqForm.recipe.requestedArguments=@($defaultArgv)+@('--cache-type-k=q8_0')
$parEq=New-DefaultRealState;$parEq.recipe.requestedArguments=@($defaultArgv)+@('--parallel=2')
$profiles=[ordered]@{'recipe.profile present, slots 1'=$long1;'recipe.slots 2'=$two;'contextPerSlot differs from contextSize'=$perSlot;
    '--parallel 2'=$par2;'--cache-type-k q8_0'=$q8k;'--cache-type-v q8_0'=$q8v;'a repeated cache argument'=$dupCache;'a cache argument without a value'=$noValue;
    '--cache-type-k=q8_0'=$eqForm;'--parallel=2'=$parEq}
foreach($name in $profiles.Keys){
    Check (Test-FastLlmServingProfileRun $profiles[$name]) "Predicate misses a serving-profile run: $name."
    Check (Test-Refuses $profiles[$name]) "Default state check accepted a serving-profile run: $name."
}
# contextPerSlot equal to contextSize alone is not a profile run.
$samePerSlot=New-DefaultRealState;$samePerSlot.recipe|Add-Member -NotePropertyName contextPerSlot -NotePropertyValue 8192
Check (-not (Test-FastLlmServingProfileRun $samePerSlot)) 'contextPerSlot equal to contextSize was taken for a profile run.'
# Opt-in: the planned point is accepted only behind the switch.
$p2=New-ProfileState
Check (Test-FastLlmServingProfileRun $p2) 'A planned two-slot state is not a profile run.'
Check (Test-Refuses $p2) 'A planned two-slot profile state was accepted without the switch.'
Check ([bool](Assert-FastLlmSemanticSmokeState $p2 -AllowServingProfile)) 'A planned two-slot profile state was refused with the switch.'
Check ([bool](Assert-FastLlmSemanticSmokeState (New-ProfileState 1 8192 'long' 'q8_0') -AllowServingProfile)) 'A planned one-slot long profile was refused with the switch.'
Check (Test-Refuses (New-ProfileState 1 8192 'long' 'q8_0')) 'A slots-1 long profile with q8_0 cache passed the default check.'
Check ([bool](Assert-FastLlmSemanticSmokeState (New-ProfileState 2 8192 'default' 'f16') -AllowServingProfile)) 'A planned default-profile two-slot state was refused with the switch.'
Check ([bool](Assert-FastLlmSemanticSmokeState (New-ProfileState 2 16384 'long' 'f16') -AllowServingProfile -AcceptedLanes @('vulkan-b10698'))) 'The switch does not combine with the lane list.'
$hipProfile=New-ProfileState;$hipProfile.engineVersion='b11658';$hipProfile.recipe.backend='hip';$hipProfile.placement.devices=@('ROCm0')
Check ([bool](Assert-FastLlmSemanticSmokeState $hipProfile -AllowServingProfile -AcceptedLanes @('hip-b11658'))) 'A HIP profile run was refused with its lane and the switch.'
Check (Test-Refuses $hipProfile -Allow) 'A HIP profile run was accepted with the switch but the default lane list.'
$bindingA=Assert-FastLlmSemanticSmokeState $p2 -AllowServingProfile
Check ($bindingA -cmatch '^[0-9a-f]{64}$' -and (Assert-FastLlmSemanticSmokeState $p2 -AllowServingProfile -ExpectedBinding $bindingA) -ceq $bindingA) 'The profile run binding is not stable.'
# Opt-in rejections: every one stays refused even with the switch.
$rej=[ordered]@{}
$s=New-ProfileState;$s.recipe.slots=3;$rej['recipe.slots 3']=$s
$s=New-ProfileState;$s.recipe.slots=0;$rej['recipe.slots 0']=$s
$s=New-ProfileState;Set-Argument $s '--parallel' '1';$rej['--parallel differs from recipe.slots']=$s
$s=New-ProfileState;$s.recipe.requestedArguments=@($s.recipe.requestedArguments)+@('--parallel','2');$rej['--parallel twice']=$s
$s=New-ProfileState;$s.recipe.requestedArguments=@($s.recipe.requestedArguments|Where-Object {$true});$s.recipe.requestedArguments=@($s.recipe.requestedArguments)+@('--ctx-size','8192');$rej['--ctx-size twice']=$s
$s=New-ProfileState;Set-Argument $s '--ctx-size' '4096';$rej['--ctx-size differs from contextSize']=$s
$s=New-ProfileState;$s.recipe.contextPerSlot=2048;$rej['contextPerSlot x slots differs from contextSize']=$s
$s=New-ProfileState;$s.canary.effectiveContext=8192;$rej['effectiveContext is the total, not per slot']=$s
$s=New-ProfileState;Set-Argument $s '--cache-type-k' 'f16';$rej['cache K differs from V']=$s
$s=New-ProfileState 2 8192 'long' 'q4_0';$rej['cache type outside f16/q8_0']=$s
$s=New-ProfileState;$s.recipe.requestedArguments=@($s.recipe.requestedArguments)+@('--cache-type-k','q8_0');$rej['cache argument repeated']=$s
$s=New-ProfileState;$s.recipe.profile='Long';$rej['profile id upper-case']=$s
$s=New-ProfileState;$s.recipe.profile=('a'*33);$rej['profile id too long']=$s
$s=New-ProfileState;$s.recipe.profile='';$rej['profile id empty']=$s
$s=New-ProfileState;$s.recipe.profile='long id';$rej['profile id with a space']=$s
$s=New-ProfileState;$s.recipe.contextSize=100;$rej['context below the floor']=$s
$s=New-ProfileState;$s.recipe.requestedArguments=@($s.recipe.requestedArguments|ForEach-Object{if($_ -ceq '8080'){'9090'}else{$_}});$rej['port is not 8080']=$s
$s=New-ProfileState;$s.endpoint='http://127.0.0.1:9090/v1';$rej['endpoint is not 8080']=$s
$s=New-ProfileState;$s.canary.semanticCorrectnessQualified=$true;$rej['canary claims qualification']=$s
$s=New-ProfileState;$s.phase='starting';$rej['not ready']=$s
$s=New-ProfileState;$s.placement.reportedLayers=1;$rej['partial placement']=$s
foreach($name in $rej.Keys){Check (Test-Refuses $rej[$name] -Allow) "A profile state with $name was accepted with the switch."}
# A bound-but-default state keeps every old check with the switch on.
$s=New-DefaultRealState;$s.recipe.slots=1;$s.canary.effectiveContext=4096
Check (Test-Refuses $s -Allow) 'With the switch, a default state with a wrong effectiveContext was accepted.'
$s=New-DefaultRealState;Set-Argument $s '--port' '9090'
Check (Test-Refuses $s -Allow) 'With the switch, a default state on another port was accepted.'
# One definition: no second copy of the predicate, and the product's closed sets are the ones the serving-profile rows are validated against.
$definitions=@(Get-ChildItem -LiteralPath (Join-Path $root 'src'),(Join-Path $root 'tools') -Recurse -File|Where-Object {$_.Extension -ceq '.ps1' -or $_.Extension -ceq '.psm1'}|Select-String -Pattern '^\s*function\s+Test-FastLlmServingProfileRun\b')
Check ($definitions.Count -eq 1 -and $definitions[0].Path -like '*FastLlm.ServingProfileRun.ps1') 'The serving-profile predicate has exactly one definition.'
$vocabulary=Get-FastLlmServingProfileVocabulary
$moduleSets=& $module {[pscustomobject]@{slots=@($script:FastLlmServingProfileSlots);cacheTypes=@($script:FastLlmServingProfileCacheTypes)}}
Check ((@($vocabulary.slots) -join ',') -ceq (@($moduleSets.slots) -join ',') -and (@($vocabulary.cacheTypes) -join ',') -ceq (@($moduleSets.cacheTypes) -join ',')) 'The serving-profile closed sets are the module row-validation sets.'
Check ((@($vocabulary.slots) -join ',') -ceq '1,2' -and (@($vocabulary.cacheTypes) -join ',') -ceq 'f16,q8_0') 'The serving-profile closed sets changed.'
# Closed profile ids: the product's own list, in the shared vocabulary, with no pattern of its own.
Check ((@((Get-FastLlmServingProfileVocabulary).profileIds) -join ',') -ceq 'default,long') 'The serving-profile ids are not default and long.'
$moduleIds=@(& $module {@($script:FastLlmServingProfileIds)})
Check (($moduleIds -join ',') -ceq 'default,long') 'The module profile ids changed.'
$runText=Get-Content -LiteralPath (Join-Path $root 'src/FastLlm.ServingProfileRun.ps1') -Raw
Check ($runText -cnotmatch '\$profile\b(?!Id)' -and -not $runText.Contains('[a-z][a-z0-9-]')) 'The serving-profile file shadows $PROFILE or keeps a profile id pattern.'
foreach($id in @('bogus','xlong','short','a')){
    $s=New-ProfileState;$s.recipe.profile=$id
    Check (Test-Refuses $s -Allow) "A lowercase profile id outside the product list was accepted: $id."
}
foreach($id in @('default','long')){
    Check ([bool](Assert-FastLlmSemanticSmokeState (New-ProfileState 2 8192 $id 'q8_0') -AllowServingProfile)) "A product profile id was refused: $id."
}
# llama-server short aliases are never the default run.
$aliases=[ordered]@{'-np 1'=@('-np','1');'-np=1'=@('-np=1');'-np 2'=@('-np','2');'-ctk f16'=@('-ctk','f16');'-ctk q8_0'=@('-ctk','q8_0');'-ctk=f16'=@('-ctk=f16')
    '-ctv f16'=@('-ctv','f16');'-ctv=q8_0'=@('-ctv=q8_0');'-c 8192'=@('-c','8192');'-c=8192'=@('-c=8192')}
foreach($name in $aliases.Keys){
    $d=New-DefaultRealState;$d.recipe.requestedArguments=@($d.recipe.requestedArguments)+@($aliases[$name])
    Check (Test-FastLlmServingProfileRun $d) "The predicate missed the short form $name."
    Check (Test-Refuses $d) "The default check accepted the short form $name."
    Check (Test-Refuses $d -Allow) "The opt-in check accepted the short form $name on a default run."
    $q=New-ProfileState;$q.recipe.requestedArguments=@($q.recipe.requestedArguments)+@($aliases[$name])
    Check (Test-Refuses $q) "The default check accepted a profile state with the short form $name."
    Check (Test-Refuses $q -Allow) "The opt-in check accepted a profile state with the short form $name."
}
# The product never writes a short form: its argument builder and goldens carry the long forms only.
$builderText=Get-Content -LiteralPath (Join-Path $root 'src/FastLlm.psm1') -Raw
Check ($builderText -cnotmatch "'-(np|ctk|ctv|c)'" -and (Get-Content -LiteralPath (Join-Path $root 'tests/fixtures/default-server-arguments.json') -Raw) -cnotmatch '"-(np|ctk|ctv|c)"' -and (Get-Content -LiteralPath (Join-Path $root 'tests/fixtures/optin-server-arguments.json') -Raw) -cnotmatch '"-(np|ctk|ctv|c)"') 'The product argument builder or a golden carries a short form.'
# Lane names are case-sensitive at binding, like the lane check.
foreach($call in @({Assert-FastLlmSemanticSmokeState $script:state -AcceptedLanes @('VULKAN-B10698')},{Invoke-FastLlmSemanticSmokeCore -OutputPath (TempPath) -ReadState {$script:state} -CheckProcess {param($S)} -Request {throw 'x'} -AcceptedLanes @('Vulkan-b10698')})){
    $caught=$null;try{& $call}catch{$caught=$_}
    Check ($null -ne $caught -and $caught.FullyQualifiedErrorId -like 'ParameterArgumentValidationError*') 'A lane name in the wrong case was not refused at binding.'
}
# Lanes have one source of truth.
$laneNames=@(Get-FastLlmSemanticSmokeLanes|ForEach-Object name)
Check ($laneNames.Count -eq 2 -and $laneNames -ccontains 'vulkan-b10698' -and $laneNames -ccontains 'hip-b11658') 'The lane table changed.'
$sourceText=Get-Content -LiteralPath $source -Raw
Check (-not $sourceText.Contains("ValidateSet('vulkan-b10698','hip-b11658')")) 'A copy of the lane list remains in the parameter validation.'
$threw=$false;$bindError=$null
try{$null=Assert-FastLlmSemanticSmokeState $script:state -AcceptedLanes @('hip-b11658','nonsense')}catch{$threw=$true}
Check $threw 'An unknown lane next to a known one was accepted.'
$threw=$false
try{$null=Invoke-FastLlmSemanticSmokeCore -OutputPath (TempPath) -ReadState {$script:state} -CheckProcess {param($S)} -Request {throw 'must not be reached'} -AcceptedLanes @('nonsense')}catch{$threw=$true}
Check $threw 'The smoke core accepted an unknown lane name.'
# Drift: an engine refresh that forgets the lane table fails here. Experimental components are labelled in their display name.
$components=(Get-Content -LiteralPath (Join-Path $root 'config/components.json') -Raw|ConvertFrom-Json).components
$engines=@($components|Where-Object {$_.kind -ceq 'engine'})
Check ($engines.Count -ge 2) 'The components file lists no engines.'
$mapped=@()
foreach($engine in $engines){
    if([string]$engine.displayName -match '(?i)experimental'){continue}
    $lane=@(Get-FastLlmSemanticSmokeLanes|Where-Object {$_.engine -ceq [string]$engine.version -and $_.backend -ieq [string]$engine.platform.backend})
    Check ($lane.Count -ge 1) "Engine component $($engine.id) ($($engine.version), $($engine.platform.backend)) has no semantic-smoke lane."
    $mapped+="$($engine.id)=$($lane[0].name)"
}
Check ($mapped.Count -ge 2) 'No non-experimental engine was mapped to a lane.'
Write-Host ("Lane drift check: "+($mapped -join '; '))
Write-Host "$count semantic smoke focused assertions passed."
