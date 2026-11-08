#requires -Version 5.1
# Default argument golden: today's DEFAULT llama-server launch arguments must never change. The live planner matrix (tier x budget x model,
# plus the hardware fixtures) is compared with tests/fixtures/default-server-arguments.json row by row.
# Pure planner work; no engine, GPU or network.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force -ErrorAction Stop
. (Join-Path $PSScriptRoot 'helpers/New-FastLlmDefaultArgumentsGolden.ps1')
$script:count=0
function Check($Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:count++;Write-Host "PASS: $Message"}

$work=Join-Path ([IO.Path]::GetTempPath()) ('default-arguments-tests-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
try {
    $golden=Get-Content -LiteralPath (Join-Path $root 'tests/fixtures/default-server-arguments.json') -Raw | ConvertFrom-Json
    $goldenRows=@($golden.rows)
    $live=@(Get-FastLlmDefaultArgumentsMatrix -Root $root -InstallRoot (Join-Path $work 'install'))

    Check ($golden.schema -ceq 'fastllm.default-arguments-golden.v1') 'golden schema'
    $catalogSha=((Get-Content -LiteralPath (Join-Path $root 'config/catalog.sha256') -Raw).Trim() -split '\s+')[0]
    Check ($golden.catalogSha256 -ceq $catalogSha) 'golden catalogSha256 equals config/catalog.sha256'

    # golden-matches-live
    Check ($live.Count -eq $goldenRows.Count) "golden-matches-live: row count ($($live.Count))"
    $differences=0
    for($i=0;$i -lt $goldenRows.Count;$i++){
        $g=$goldenRows[$i];$l=$live[$i]
        $same=($g.tier -ceq $l.tier) -and ($g.budget -ceq $l.budget) -and ([int]$g.freeVramMiB -eq [int]$l.freeVramMiB) -and ($g.request -ceq $l.request) -and
              ($g.outcome -ceq $l.outcome) -and ($g.refusal -ceq $l.refusal) -and ($g.recipeId -ceq $l.recipeId)
        $ga=@($g.arguments);$la=@($l.arguments)
        if($same -and $ga.Count -eq $la.Count){for($j=0;$j -lt $ga.Count;$j++){if(-not ($ga[$j] -ceq $la[$j])){$same=$false;break}}}else{$same=$false}
        if(-not $same){$differences++;Write-Host "DIFF row $i tier=$($g.tier) budget=$($g.budget) request=$($g.request)"}
    }
    Check ($differences -eq 0) 'golden-matches-live: every row equal, -ceq on every argument'

    # golden-covers-every-model
    $catalog=Get-Content -LiteralPath (Join-Path $root 'config/catalog.json') -Raw | ConvertFrom-Json
    $planRows=@($goldenRows | Where-Object { $_.outcome -ceq 'plan' })
    foreach($model in @($catalog.models)){
        $id=[string]$model.id
        $hit=@($goldenRows | Where-Object { $_.request -ceq $id })
        Check ($hit.Count -gt 0) "golden-covers-every-model: $id"
    }

    # golden-has-no-ui-and-no-agent
    $bad=@($planRows | Where-Object { @($_.arguments | Where-Object { $_ -ceq '--no-ui' }).Count -ne 1 -or @($_.arguments | Where-Object { $_ -ceq '--no-agent' }).Count -ne 1 })
    Check ($planRows.Count -gt 0 -and $bad.Count -eq 0) "golden-has-no-ui-and-no-agent: $($planRows.Count) plan rows"

    # golden-has-recipe-and-split-rows
    Check (@($goldenRows | Where-Object { $_.outcome -ceq 'plan' -and $_.recipeId }).Count -ge 1) 'golden-has-recipe-and-split-rows: a recipe plan row'
    Check (@($planRows | Where-Object { @($_.arguments) -ccontains '--tensor-split' }).Count -ge 1) 'golden-has-recipe-and-split-rows: a --tensor-split row'
    Check (@($planRows | Where-Object { @($_.arguments).Count -eq 0 }).Count -eq 0) 'golden-has-recipe-and-split-rows: no empty plan arguments'
    Check (@($goldenRows | Where-Object { $_.outcome -ceq 'pending' -and @($_.arguments).Count -ne 0 }).Count -eq 0) 'pending rows never carry an argument golden'

    # HIP recipe fallback coverage: the Vulkan recipe rows equal the arrays pinned in tests/components-tests.ps1.
    Check ($golden.hipRecipeCoverage -like 'fallback-vulkan-rows-pinned-to-components-tests*') 'hipRecipeCoverage path recorded'
    $commonTail=@('--host','127.0.0.1','--port','8080','--cors-origins','localhost','--no-cors-credentials')
    $expectedXtx=@('--model','MODEL','--offline','--no-mmproj','--spec-type','none','--alias','qwen3.8-27b-ud-q4-k-m')+$commonTail+@(
        '--ctx-size','32768','--parallel','1','--n-gpu-layers','all','--fit','on','--fit-target','768','--device','Vulkan0','--split-mode','none',
        '--flash-attn','auto','--cache-type-k','f16','--cache-type-v','f16','--jinja','--metrics','--log-verbosity','4','--no-agent','--no-ui')
    $expectedXt=@('--model','MODEL','--offline','--no-mmproj','--spec-type','none','--alias','qwen3.8-27b-ud-iq4-xs')+$commonTail+@(
        '--ctx-size','16384','--parallel','1','--n-gpu-layers','all','--fit','on','--fit-target','512','--device','ROCm0','--split-mode','none',
        '--flash-attn','auto','--cache-type-k','f16','--cache-type-v','f16','--jinja','--metrics','--log-verbosity','4','--no-agent','--no-ui')
    foreach($case in @(@{Name='rx-7900-xtx-24gb';Expected=$expectedXtx},@{Name='rx-7900-xt-20gb-identified';Expected=$expectedXt})){
        $row=@($goldenRows | Where-Object { $_.tier -ceq ('fixture:'+$case.Name) })[0]
        $got=@($row.arguments);$got[1]='MODEL'
        $equal=($got.Count -eq $case.Expected.Count)
        if($equal){for($j=0;$j -lt $got.Count;$j++){if(-not ($got[$j] -ceq $case.Expected[$j])){$equal=$false;break}}}
        Check $equal "recipe row $($case.Name) equals the array pinned in components-tests.ps1"
    }
    # plan-default-port-golden: the port parameter at 0 (catalog value) and at 8080 both reproduce the golden byte for byte.
    foreach($portCase in @(0,8080)){
        $portLive=@(Get-FastLlmDefaultArgumentsMatrix -Root $root -InstallRoot (Join-Path $work 'install') -PlanParameters @{ServerPort=$portCase})
        $portDiffs=0
        if($portLive.Count -ne $goldenRows.Count){$portDiffs=-1}
        else{
            for($i=0;$i -lt $goldenRows.Count;$i++){
                $g=$goldenRows[$i];$l=$portLive[$i]
                $same=($g.outcome -ceq $l.outcome) -and ($g.refusal -ceq $l.refusal) -and ($g.recipeId -ceq $l.recipeId)
                $ga=@($g.arguments);$la=@($l.arguments)
                if($same -and $ga.Count -eq $la.Count){for($j=0;$j -lt $ga.Count;$j++){if(-not ($ga[$j] -ceq $la[$j])){$same=$false;break}}}else{$same=$false}
                if(-not $same){$portDiffs++}
            }
        }
        Check ($portDiffs -eq 0) "plan-default-port-golden: -ServerPort $portCase equals the golden, every row, -ceq on every argument"
    }

    # thinking-auto-golden: -Thinking auto reproduces the golden byte for byte, every row.
    $autoLive=@(Get-FastLlmDefaultArgumentsMatrix -Root $root -InstallRoot (Join-Path $work 'install') -PlanParameters @{Thinking='auto'})
    $autoDiffs=0
    if($autoLive.Count -ne $goldenRows.Count){$autoDiffs=-1}
    else{
        for($i=0;$i -lt $goldenRows.Count;$i++){
            $g=$goldenRows[$i];$l=$autoLive[$i]
            $same=($g.outcome -ceq $l.outcome) -and ($g.refusal -ceq $l.refusal) -and ($g.recipeId -ceq $l.recipeId)
            $ga=@($g.arguments);$la=@($l.arguments)
            if($same -and $ga.Count -eq $la.Count){for($j=0;$j -lt $ga.Count;$j++){if(-not ($ga[$j] -ceq $la[$j])){$same=$false;break}}}else{$same=$false}
            if(-not $same){$autoDiffs++}
        }
    }
    Check ($autoDiffs -eq 0) 'thinking-auto-golden: -Thinking auto equals the golden, every row, -ceq on every argument'

    # thinking-off-appends-one-flag: every plan row is the golden plus --reasoning off at the very end; non-plan rows are unchanged.
    $offLive=@(Get-FastLlmDefaultArgumentsMatrix -Root $root -InstallRoot (Join-Path $work 'install') -PlanParameters @{Thinking='off'})
    $offBad=0;$offPlanRows=0;$offSplitRows=0
    Check ($offLive.Count -eq $goldenRows.Count) 'thinking-off-appends-one-flag: row count equals the golden'
    for($i=0;$i -lt $goldenRows.Count;$i++){
        $g=$goldenRows[$i];$l=$offLive[$i]
        $ga=@($g.arguments);$la=@($l.arguments)
        $same=($g.outcome -ceq $l.outcome) -and ($g.refusal -ceq $l.refusal) -and ($g.recipeId -ceq $l.recipeId)
        if($g.outcome -ceq 'plan'){
            $offPlanRows++;if($ga -ccontains '--tensor-split'){$offSplitRows++}
            if($la.Count -ne $ga.Count+2){$same=$false}
            else{
                for($j=0;$j -lt $ga.Count;$j++){if(-not ($ga[$j] -ceq $la[$j])){$same=$false;break}}
                if(-not (($la[$la.Count-2] -ceq '--reasoning') -and ($la[$la.Count-1] -ceq 'off'))){$same=$false}
            }
            if(@($la | Where-Object { $_ -ceq '--reasoning' }).Count -ne 1){$same=$false}
        }
        else{
            if($la.Count -ne $ga.Count){$same=$false}
            else{for($j=0;$j -lt $ga.Count;$j++){if(-not ($ga[$j] -ceq $la[$j])){$same=$false;break}}}
        }
        if(-not $same){$offBad++;Write-Host "DIFF off row $i tier=$($g.tier) request=$($g.request)"}
    }
    Check ($offBad -eq 0 -and $offPlanRows -gt 0) "thinking-off-appends-one-flag: $offPlanRows plan rows equal golden + --reasoning off at the end"
    Check ($offSplitRows -ge 1) "thinking-off-appends-one-flag: $offSplitRows --tensor-split rows end with --reasoning off after the split"

    # plan-custom-port: only the --port value and the endpoint change; --host stays loopback.
    $portHardware=Read-FastLlmJson (Join-Path $root 'tests/fixtures/rx-7900-xtx-24gb.json')
    $portCommon=@{Hardware=$portHardware;CatalogPath=(Join-Path $root 'config/catalog.json');RecipesPath=(Join-Path $root 'config/recipes.json');GpuVariantsPath=(Join-Path $root 'config/gpu-variants.json');Profile='balanced';NoEngineExecution=$true;InstallRoot=(Join-Path $work 'install')}
    $basePlan=Get-FastLlmPlan @portCommon
    $customPlan=Get-FastLlmPlan @portCommon -ServerPort 18181
    $baseArgs=@($basePlan.serverArguments);$customArgs=@($customPlan.serverArguments)
    $portIndex=[Array]::IndexOf($baseArgs,'--port')
    $changed=@();for($i=0;$i -lt $baseArgs.Count;$i++){if(-not ($baseArgs[$i] -ceq $customArgs[$i])){$changed+=$i}}
    Check ($baseArgs.Count -eq $customArgs.Count -and $portIndex -ge 0 -and $changed.Count -eq 1 -and $changed[0] -eq ($portIndex+1) -and $customArgs[$portIndex+1] -ceq '18181') 'plan-custom-port: only the --port value changed, at the same index'
    Check ($customPlan.endpoint -ceq 'http://127.0.0.1:18181/v1' -and $basePlan.endpoint -ceq 'http://127.0.0.1:8080/v1') 'plan-custom-port: endpoint follows the port'
    $hostIndex=[Array]::IndexOf($customArgs,'--host')
    Check ($hostIndex -ge 0 -and $customArgs[$hostIndex+1] -ceq '127.0.0.1') 'plan-custom-port: --host stays 127.0.0.1'
    Check ([int]$customPlan.requestedServerPort -eq 18181 -and [int]$basePlan.requestedServerPort -eq 0) 'plan-custom-port: requestedServerPort is recorded (0 = catalog)'
    $rangeRejected=0
    foreach($badPort in @(-1,65536)){try{Get-FastLlmPlan @portCommon -ServerPort $badPort | Out-Null}catch{$rangeRejected++}}
    Check ($rangeRejected -eq 2) 'plan-custom-port: the planner parameter is range checked'

    # plan-json-additive: every BASE property keeps its value; the only new property is requestedServerPort (this task's share of the three requested*).
    $baseJson=Get-Content -LiteralPath (Join-Path $root 'tests/fixtures/plan-json-base.json') -Raw | ConvertFrom-Json
    $nowJson=$basePlan | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $installRoot=Join-Path $work 'install'
    $normalize={param($Value) $t=($Value | ConvertTo-Json -Depth 12 -Compress); foreach($v in @($installRoot,$installRoot.Replace('\','\\'),$installRoot.Replace('\','/'))){if($v){$t=$t.Replace($v,'<install-root>')}}; $t.Replace('\\','/')}
    $missing=@();$valueDiffs=@()
    foreach($property in $baseJson.PSObject.Properties){
        if(-not $nowJson.PSObject.Properties[$property.Name]){$missing+=$property.Name;continue}
        $a=& $normalize $property.Value;$b=& $normalize $nowJson.PSObject.Properties[$property.Name].Value
        if($a -cne $b){$valueDiffs+=$property.Name}
    }
    $added=@($nowJson.PSObject.Properties.Name | Where-Object { -not $baseJson.PSObject.Properties[$_] })
    Check ($missing.Count -eq 0) 'plan-json-additive: every BASE property is still present'
    Check ($valueDiffs.Count -eq 0) ("plan-json-additive: every BASE property keeps its value ($($valueDiffs -join ','))")
    Check (@($added | Where-Object { $_ -cnotin @('requestedServerPort','requestedThinking','requestedChatPage') }).Count -eq 0 -and $added -ccontains 'requestedServerPort' -and $added -ccontains 'requestedThinking' -and $added -ccontains 'requestedChatPage' -and $added.Count -eq 3) 'plan-json-additive: the new properties are exactly requestedServerPort, requestedThinking and requestedChatPage'
    Check ([string]$basePlan.requestedThinking -ceq 'auto') 'plan-thinking: requestedThinking is auto by default'
    $offPlan=Get-FastLlmPlan @portCommon -Thinking 'off'
    Check ([string]$offPlan.requestedThinking -ceq 'off') 'plan-thinking: requestedThinking records off'
    $thinkRejected=0
    foreach($badThinking in @('on','x','banana')){try{Get-FastLlmPlan @portCommon -Thinking $badThinking | Out-Null}catch{$thinkRejected++}}
    Check ($thinkRejected -eq 3) 'plan-thinking: the planner parameter is a closed set'
    Check ([string](Get-FastLlmPlan @portCommon -Thinking 'OFF').requestedThinking -ceq 'off') 'plan-thinking: OFF is normalised to off'
    # chatpage-off-golden: -ChatPage off reproduces the golden byte for byte, every row.
    function Test-SameArguments($Expected,$Actual){$e=@($Expected);$a=@($Actual);if($e.Count -ne $a.Count){return $false};for($k=0;$k -lt $e.Count;$k++){if(-not ($e[$k] -ceq $a[$k])){return $false}};return $true}
    $chatOffLive=@(Get-FastLlmDefaultArgumentsMatrix -Root $root -InstallRoot (Join-Path $work 'install') -PlanParameters @{ChatPage='off'})
    $chatOffDiffs=0
    if($chatOffLive.Count -ne $goldenRows.Count){$chatOffDiffs=-1}
    else{
        for($i=0;$i -lt $goldenRows.Count;$i++){
            $g=$goldenRows[$i];$l=$chatOffLive[$i]
            $same=($g.outcome -ceq $l.outcome) -and ($g.refusal -ceq $l.refusal) -and ($g.recipeId -ceq $l.recipeId) -and (Test-SameArguments $g.arguments $l.arguments)
            if(-not $same){$chatOffDiffs++}
        }
    }
    Check ($chatOffDiffs -eq 0) 'chatpage-off-golden: -ChatPage off equals the golden, every row, -ceq on every argument'

    # chatpage-on-removes-only-no-ui: every plan row is the golden minus exactly the one --no-ui element, order otherwise identical.
    $chatOnLive=@(Get-FastLlmDefaultArgumentsMatrix -Root $root -InstallRoot (Join-Path $work 'install') -PlanParameters @{ChatPage='on'})
    Check ($chatOnLive.Count -eq $goldenRows.Count) 'chatpage-on-removes-only-no-ui: row count equals the golden'
    $chatBad=0;$chatPlanRows=0
    for($i=0;$i -lt $goldenRows.Count;$i++){
        $g=$goldenRows[$i];$l=$chatOnLive[$i]
        $same=($g.outcome -ceq $l.outcome) -and ($g.refusal -ceq $l.refusal) -and ($g.recipeId -ceq $l.recipeId)
        if($g.outcome -ceq 'plan'){
            $chatPlanRows++
            $expected=@(@($g.arguments) | Where-Object { $_ -cne '--no-ui' })
            if(@($g.arguments).Count -ne $expected.Count+1 -or -not (Test-SameArguments $expected $l.arguments)){$same=$false}
            if(@(@($l.arguments) | Where-Object { $_ -ceq '--no-ui' }).Count -ne 0){$same=$false}
            if(@(@($l.arguments) | Where-Object { $_ -ceq '--ui' }).Count -ne 0){$same=$false}
        }
        elseif(-not (Test-SameArguments $g.arguments $l.arguments)){$same=$false}
        if(-not $same){$chatBad++;Write-Host "DIFF chat-on row $i tier=$($g.tier) request=$($g.request)"}
    }
    Check ($chatBad -eq 0 -and $chatPlanRows -gt 0) "chatpage-on-removes-only-no-ui: $chatPlanRows plan rows equal golden minus the one --no-ui element"

    # chatpage-on-keeps-no-agent: every On plan row keeps --no-agent and --host 127.0.0.1.
    $keepBad=0
    foreach($l in $chatOnLive){
        if($l.outcome -cne 'plan'){continue}
        $la=@($l.arguments);$h=[Array]::IndexOf($la,'--host')
        if(-not ($la -ccontains '--no-agent') -or $h -lt 0 -or -not ($la[$h+1] -ceq '127.0.0.1')){$keepBad++}
    }
    Check ($keepBad -eq 0) 'chatpage-on-keeps-no-agent: every On plan keeps --no-agent and --host 127.0.0.1'

    # chatpage-toggle-restores-no-ui: Off after On gives the golden again (the plan keeps no state between calls).
    $chatOn=Get-FastLlmPlan @portCommon -ChatPage 'on'
    $chatOffAgain=Get-FastLlmPlan @portCommon -ChatPage 'off'
    Check (-not (@($chatOn.serverArguments) -ccontains '--no-ui') -and (Test-SameArguments $basePlan.serverArguments $chatOffAgain.serverArguments) -and (@($chatOffAgain.serverArguments) -ccontains '--no-ui')) 'chatpage-toggle-restores-no-ui: Off after On gives the default arguments'

    # chatpage plan field and combination with Thinking off.
    Check ([string]$basePlan.requestedChatPage -ceq 'off' -and [string]$chatOn.requestedChatPage -ceq 'on') 'plan-chatpage: requestedChatPage records off by default and on when asked'
    Check ([string](Get-FastLlmPlan @portCommon -ChatPage 'ON').requestedChatPage -ceq 'on') 'plan-chatpage: ON is normalised to on'
    $chatRejected=0
    foreach($badChat in @('auto','x','banana')){try{Get-FastLlmPlan @portCommon -ChatPage $badChat | Out-Null}catch{$chatRejected++}}
    Check ($chatRejected -eq 3) 'plan-chatpage: the planner parameter is a closed set'
    $both=Get-FastLlmPlan @portCommon -ChatPage 'on' -Thinking 'off'
    $bothExpected=@(@($basePlan.serverArguments) | Where-Object { $_ -cne '--no-ui' }) + @('--reasoning','off')
    Check (Test-SameArguments $bothExpected $both.serverArguments) 'plan-chatpage: with Thinking off the arguments are the golden minus --no-ui plus --reasoning off at the end'
    Write-Host "default-arguments-tests: $script:count checks passed"
}
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
