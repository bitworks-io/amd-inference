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
    Write-Host "default-arguments-tests: $script:count checks passed"
}
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
