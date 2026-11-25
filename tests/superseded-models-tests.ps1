#requires -Version 5.1
# Superseded model files: a catalog entry may name the entry that replaces its file revision (supersededBy). The catalog loader checks the field;
# the planner, recipe selection, preload, install, switch and the window's model picker never take a superseded model; an old file already on disk
# stays known, listed and removable, and nothing here downloads. Mock only: the download function is replaced by one that records its calls, and the
# install, store and rollback cases use a catalog copy with a tiny file for the old entry.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force -PassThru -ErrorAction Stop
. (Join-Path $root 'src/FastLlm.UiFlow.ps1')
$script:count=0
function Check($Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:count++;Write-Host "PASS: $Message"}
function Write-Utf8([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object Text.UTF8Encoding($false)))}
function Get-Thrown([scriptblock]$Action){try{& $Action | Out-Null}catch{return $_.Exception};return $null}
function Get-Code($Exception){if($null -eq $Exception -or -not $Exception.Data.Contains('FastLlmFailureCode')){return ''};return [string]$Exception.Data['FastLlmFailureCode']}

$realCatalogPath=Join-Path $root 'config/catalog.json'
$fixtures=Join-Path $root 'tests/fixtures'
$work=Join-Path ([IO.Path]::GetTempPath()) ('superseded-models-tests-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$oldIds=@('qwen3.8-27b-ud-iq4-xs','qwen3.8-27b-ud-q4-k-m','qwen3.8-27b-ud-q5-k-m','qwen3.8-27b-ud-q6-k-m')
try {
    $realCatalog=Get-FastLlmCatalog -CatalogPath $realCatalogPath
    $superseded=@($realCatalog.models | Where-Object { $_.PSObject.Properties['supersededBy'] })
    Check ($superseded.Count -eq 4 -and (($superseded | ForEach-Object { [string]$_.id } | Sort-Object) -join ',') -ceq (($oldIds | Sort-Object) -join ',')) 'the shipped catalog supersedes the four old Qwen3.8 27B entries'

    # A catalog written from the real one with a change applied to its parsed form.
    function New-CatalogCopy([string]$Name,[scriptblock]$Change){
        $dir=Join-Path $work $Name
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $doc=Get-Content -LiteralPath $realCatalogPath -Raw | ConvertFrom-Json
        & $Change $doc
        $path=Join-Path $dir 'catalog.json'
        Write-Utf8 $path ($doc | ConvertTo-Json -Depth 20)
        return $path
    }
    function Get-Model($Doc,[string]$Id){return @($Doc.models | Where-Object { [string]$_.id -ceq $Id })[0]}

    # ---- a. validation ------------------------------------------------------------------------------------------------------------------------
    # Each case changes one thing and must be refused for its OWN rule: the message is pinned, so a case cannot pass on another check's refusal.
    $loadRefusals=@{
        'a target that is not in the catalog' = @{ Message="Model 'qwen3.8-27b-ud-q4-k-m' is superseded by 'no-such-model', which is not in the catalog."
            Change={ param($d) (Get-Model $d 'qwen3.8-27b-ud-q4-k-m').supersededBy='no-such-model' } }
        'itself' = @{ Message="Model 'qwen3.8-27b-ud-q4-k-m' cannot be superseded by itself."
            Change={ param($d) (Get-Model $d 'qwen3.8-27b-ud-q4-k-m').supersededBy='qwen3.8-27b-ud-q4-k-m' } }
        # A pure chain: old -> new -> a third entry of the SAME family, parameters and quantization (a copy of the new one under another id and
        # file), so only the no-chains rule can refuse it.
        'a target that is itself superseded (a chain)' = @{ Message="Model 'qwen3.8-27b-ud-q4-k-m' is superseded by 'qwen3.8-27b-ud-q4-k-m-4af51b35', which is itself superseded. Chains are not allowed."
            Change={ param($d)
                $new=Get-Model $d 'qwen3.8-27b-ud-q4-k-m-4af51b35'
                $third=$new | ConvertTo-Json -Depth 20 | ConvertFrom-Json
                $third.id='qwen3.8-27b-ud-q4-k-m-chain-third'
                $third.file='Qwen3.8-27B-UD-Q4_K_M-chain-third.gguf'
                $d.models=@(@($d.models) + $third)
                $new | Add-Member -NotePropertyName supersededBy -NotePropertyValue 'qwen3.8-27b-ud-q4-k-m-chain-third' } }
        'a target with another quantization' = @{ Message="Model 'qwen3.8-27b-ud-q4-k-m' is superseded by 'qwen3.8-27b-ud-q5-k-m-4af51b35', which has a different quantization."
            Change={ param($d) (Get-Model $d 'qwen3.8-27b-ud-q4-k-m').supersededBy='qwen3.8-27b-ud-q5-k-m-4af51b35' } }
        'a target with another family' = @{ Message="Model 'qwen3.8-27b-ud-q4-k-m' is superseded by 'qwen3.8-27b-ud-q4-k-m-4af51b35', which has a different family."
            Change={ param($d) (Get-Model $d 'qwen3.8-27b-ud-q4-k-m-4af51b35').family='Other' } }
        'a target with other parameters' = @{ Message="Model 'qwen3.8-27b-ud-q4-k-m' is superseded by 'qwen3.8-27b-ud-q4-k-m-4af51b35', which has a different parameters."
            Change={ param($d) (Get-Model $d 'qwen3.8-27b-ud-q4-k-m-4af51b35').parameters='9B' } }
        'an empty value' = @{ Message="Model 'qwen3.8-27b-ud-q4-k-m' supersededBy must be a non-empty string naming a catalog model."
            Change={ param($d) (Get-Model $d 'qwen3.8-27b-ud-q4-k-m').supersededBy='' } }
        'a value that is not text' = @{ Message="Model 'qwen3.8-27b-ud-q4-k-m' supersededBy must be a non-empty string naming a catalog model."
            Change={ param($d) (Get-Model $d 'qwen3.8-27b-ud-q4-k-m').supersededBy=5 } }
        'notes that are empty' = @{ Message="Model 'qwen3.8-27b-ud-q5-k-m-4af51b35' notes must be a non-empty string."
            Change={ param($d) (Get-Model $d 'qwen3.8-27b-ud-q5-k-m-4af51b35').notes='  ' } }
        'notes that are not text' = @{ Message="Model 'qwen3.8-27b-ud-q5-k-m-4af51b35' notes must be a non-empty string."
            Change={ param($d) (Get-Model $d 'qwen3.8-27b-ud-q5-k-m-4af51b35').notes=7 } }
    }
    foreach($name in @($loadRefusals.Keys | Sort-Object)){
        $case=$loadRefusals[$name]
        $bad=New-CatalogCopy ('bad-'+[Guid]::NewGuid().ToString('N')) $case.Change
        $thrown=Get-Thrown { Get-FastLlmCatalog -CatalogPath $bad }
        Check ($null -ne $thrown -and [string]$thrown.Message -ceq [string]$case.Message) "validation: the catalog refuses supersededBy/notes with $name, for that rule (got: $(if($thrown){$thrown.Message}else{'no error'}))"
    }
    # The same chain with the third entry present but nothing superseded twice loads: the third entry alone breaks nothing.
    $thirdOnly=New-CatalogCopy 'third-only' { param($d)
        $third=(Get-Model $d 'qwen3.8-27b-ud-q4-k-m-4af51b35') | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $third.id='qwen3.8-27b-ud-q4-k-m-chain-third'
        $third.file='Qwen3.8-27B-UD-Q4_K_M-chain-third.gguf'
        $d.models=@(@($d.models) + $third) }
    Check ($null -eq (Get-Thrown { Get-FastLlmCatalog -CatalogPath $thirdOnly })) 'validation: the chain case fails only because of the chain (the extra entry alone loads)'
    $withoutField=New-CatalogCopy 'plain' { param($d) foreach($m in @($d.models)){ if($m.PSObject.Properties['supersededBy']){ $m.PSObject.Properties.Remove('supersededBy') } } }
    Check ($null -eq (Get-Thrown { Get-FastLlmCatalog -CatalogPath $withoutField })) 'validation: supersededBy is optional'

    # ---- b. planner ---------------------------------------------------------------------------------------------------------------------------
    function Get-FixturePlan([string]$Fixture,[string]$CatalogPath,[hashtable]$Extra=@{}){
        $hardware=Read-FastLlmJson -Path (Join-Path $fixtures $Fixture)
        $parameters=@{ Hardware=$hardware; CatalogPath=$CatalogPath; InstallRoot=(Join-Path $work 'plan-install'); NoEngineExecution=$true }
        foreach($key in @($Extra.Keys)){ $parameters[$key]=$Extra[$key] }
        return Get-FastLlmPlan @parameters
    }
    Check ((Get-FixturePlan 'rx-7900-xt-20gb.json' $realCatalogPath).model.id -ceq 'qwen3.8-27b-ud-iq4-xs-4af51b35') 'the planner never picks a superseded model: an XT-like card gets the new IQ4_XS'
    Check ((Get-FixturePlan 'rx-7900-xtx-24gb.json' $realCatalogPath).model.id -ceq 'qwen3.8-27b-ud-q4-k-m-4af51b35') 'the planner never picks a superseded model: an XTX-like card gets the new Q4_K_M'
    foreach($profile in @('fast','balanced','quality')){
        $pick=(Get-FixturePlan 'r9700-32gb.json' $realCatalogPath @{Profile=$profile}).model.id
        Check ($oldIds -cnotcontains [string]$pick) "the planner never picks a superseded model: no profile ($profile) picks an old id (picked $pick)"
    }
    foreach($oldId in $oldIds){
        $replacement=[string](Get-Model $realCatalog $oldId).supersededBy
        $plain=Get-Thrown { Get-FixturePlan 'r9700-32gb.json' $realCatalogPath @{ModelId=$oldId} }
        Check ((Get-Code $plain) -ceq 'model-superseded' -and $plain.Message -ceq "Model '$oldId' is superseded by '$replacement'. Use '$replacement'.") "explicit -ModelId $oldId refuses with model-superseded naming '$replacement'"
        $experimental=Get-Thrown { Get-FixturePlan 'r9700-32gb.json' $realCatalogPath @{ModelId=$oldId;AllowExperimentalModel=[switch]$true} }
        Check ((Get-Code $experimental) -ceq 'model-superseded') "-AllowExperimentalModel does not bypass model-superseded for $oldId"
    }
    Check ((Get-FixturePlan 'rx-7900-xtx-24gb.json' $realCatalogPath @{ModelId='qwen3.8-27b-ud-q4-k-m-4af51b35'}).model.id -ceq 'qwen3.8-27b-ud-q4-k-m-4af51b35') 'an explicit -ModelId for the replacement plans'

    # ---- c. recipe selection ------------------------------------------------------------------------------------------------------------------
    $shippedRecipes=@(Read-FastLlmRecipes -Path (Join-Path $root 'config/recipes.json'))
    $supersededIds=@($superseded | ForEach-Object { [string]$_.id })
    Check (@($shippedRecipes | Where-Object { $supersededIds -ccontains [string]$_.components.model }).Count -eq 0) 'recipe/tier-derived models: no shipped recipe names a superseded model'
    $variantsPath=Join-Path $root 'config/gpu-variants.json'
    $recipeDir=Join-Path $work 'recipes'
    New-Item -ItemType Directory -Path $recipeDir -Force | Out-Null
    $recipeFile=Join-Path $recipeDir 'recipes.json'
    $oldRecipeDocument=[pscustomobject][ordered]@{ schema='bitworks.fastllm-recipes/v2'; recipes=@([pscustomobject][ordered]@{
            id='test-xtx-old'; origin='bitworks'; recommended=$true
            gpu=[pscustomobject]@{ variant='rx-7900-xtx'; count=1 }
            components=[pscustomobject]@{ engine="llama.cpp-$($realCatalog.engine.version)-vulkan"; model='qwen3.8-27b-ud-q4-k-m' }
            engineBuild=[string]$realCatalog.engine.version
            runtime=[pscustomobject]@{ contextSize=32768; vulkanBarMitigation='auto' }
            expected=[pscustomobject]@{ generationTokS=30.5 }
            evidence=[pscustomobject]@{ url='https://bitworks.io/test-recipe'; publishedAt='2026-10-01' } }) }
    Write-Utf8 $recipeFile ($oldRecipeDocument | ConvertTo-Json -Depth 8)
    $xtx=Read-FastLlmJson -Path (Join-Path $fixtures 'rx-7900-xtx-24gb.json')
    $xtx | Add-Member -NotePropertyName dxgiAdapters -NotePropertyValue @([pscustomobject]@{ vendorId=4098; deviceId=29772; revision=200; dedicatedVideoMiB=24534 })
    $recipeOptions=@{ RecipesPath=$recipeFile; GpuVariantsPath=$variantsPath }
    $autoPlan=Get-FastLlmPlan -Hardware $xtx -CatalogPath $realCatalogPath -InstallRoot (Join-Path $work 'plan-install') -NoEngineExecution @recipeOptions
    Check ($autoPlan.recipe.origin -ceq 'estimated' -and $autoPlan.model.id -ceq 'qwen3.8-27b-ud-q4-k-m-4af51b35') 'recipe auto-pick skips a recipe on a superseded model and the estimated plan takes the replacement'
    Check (@($autoPlan.recipe.skipped | Where-Object { $_ -clike 'test-xtx-old: model is superseded by ''qwen3.8-27b-ud-q4-k-m-4af51b35''*' }).Count -eq 1) 'recipe auto-pick: the skipped reason names the replacement'
    $namedRecipe=Get-Thrown { Get-FastLlmPlan -Hardware $xtx -CatalogPath $realCatalogPath -InstallRoot (Join-Path $work 'plan-install') -NoEngineExecution -RecipeId 'test-xtx-old' @recipeOptions }
    Check ((Get-Code $namedRecipe) -ceq 'model-superseded') 'naming a recipe on a superseded model with -Recipe refuses with model-superseded'
    $shippedPick=Get-FastLlmPlan -Hardware $xtx -CatalogPath $realCatalogPath -InstallRoot (Join-Path $work 'plan-install') -NoEngineExecution -RecipesPath (Join-Path $root 'config/recipes.json') -GpuVariantsPath $variantsPath
    Check ($shippedPick.model.id -ceq 'qwen3.8-27b-ud-q4-k-m-4af51b35' -and $shippedPick.recipe.origin -ceq 'bitworks') 'the shipped XTX recipe plans the new file'
    Check ($shippedPick.recipe.PSObject.Properties['measuredOn'] -and $shippedPick.recipe.measuredOn.model -ceq 'qwen3.8-27b-ud-q4-k-m' -and $shippedPick.recipe.measuredOn.revision -ceq '4ca720788d1e01f1bff70c033e0d0028fd02e502') 'the plan names the file revision the expected numbers were measured on'
    Check ($shippedPick.recipe.measurementNote -ceq 'Expected numbers were measured on the previous file revision 4ca72078; this revision is being verified.') 'the plan carries the measurement note, with the first 8 characters of the old revision'
    $lineageLabel='Measured by Bitworks on this card on the previous file revision; this revision is being verified'
    Check ($shippedPick.recipe.label -ceq $lineageLabel) 'the plan label for a lineage recipe says the numbers are from the previous file revision'
    $summary=Format-FastLlmUiRecipeSummary -Plan $shippedPick
    Check ($summary -clike 'Best setup for your *: qwen3.8-27b-ud-q4-k-m-4af51b35 (UD-Q4_K_M), 32,768 context. Measured by Bitworks on this card on the previous file revision; this revision is being verified.') "the window recipe summary carries the honest label (observed: $summary)"
    $shippedRows=@(Read-FastLlmRecipes -Path (Join-Path $root 'config/recipes.json'))
    $lineageRows=@($shippedRows | Where-Object { $_.evidence -and $_.evidence.PSObject.Properties['measuredModel'] })
    Check ($lineageRows.Count -eq 4 -and @($lineageRows | Where-Object { [string]$_.label -cne $lineageLabel }).Count -eq 0) 'the recipe list labels every lineage recipe with the honest label'
    Check (@($shippedRows | Where-Object { -not ($_.evidence -and $_.evidence.PSObject.Properties['measuredModel']) -and [string]$_.origin -ceq 'bitworks' }).Count -eq 0) 'every shipped verified recipe is a lineage recipe'
    $estimatedPlan=Get-FixturePlan 'rx-7900-xtx-24gb.json' $realCatalogPath
    Check (-not $estimatedPlan.recipe.PSObject.Properties['measuredOn'] -and -not $estimatedPlan.recipe.PSObject.Properties['measurementNote']) 'a plan without such a recipe has no measuredOn or measurementNote'

    # Naming a current recipe is not refused because another usable recipe's model is superseded.
    $twoRecipes=[pscustomobject][ordered]@{ schema='bitworks.fastllm-recipes/v2'; recipes=@(
        $oldRecipeDocument.recipes[0],
        [pscustomobject][ordered]@{ id='test-xtx-current'; origin='bitworks'; recommended=$false
            gpu=[pscustomobject]@{ variant='rx-7900-xtx'; count=1 }
            components=[pscustomobject]@{ engine="llama.cpp-$($realCatalog.engine.version)-vulkan"; model='qwen3.8-27b-ud-q4-k-m-4af51b35' }
            engineBuild=[string]$realCatalog.engine.version
            runtime=[pscustomobject]@{ contextSize=32768; vulkanBarMitigation='auto' }
            expected=[pscustomobject]@{ generationTokS=30.5 }
            evidence=[pscustomobject]@{ url='https://bitworks.io/test-recipe'; publishedAt='2026-10-01' } }) }
    $twoFile=Join-Path $recipeDir 'two-recipes.json'
    Write-Utf8 $twoFile ($twoRecipes | ConvertTo-Json -Depth 8)
    $twoOptions=@{ RecipesPath=$twoFile; GpuVariantsPath=$variantsPath }
    $currentNamed=Get-FastLlmPlan -Hardware $xtx -CatalogPath $realCatalogPath -InstallRoot (Join-Path $work 'plan-install') -NoEngineExecution -RecipeId 'test-xtx-current' @twoOptions
    Check ($currentNamed.recipe.id -ceq 'test-xtx-current' -and $currentNamed.model.id -ceq 'qwen3.8-27b-ud-q4-k-m-4af51b35') 'naming a current recipe plans even when another usable recipe names a superseded model'
    $supersededNamed=Get-Thrown { Get-FastLlmPlan -Hardware $xtx -CatalogPath $realCatalogPath -InstallRoot (Join-Path $work 'plan-install') -NoEngineExecution -RecipeId 'test-xtx-old' @twoOptions }
    Check ((Get-Code $supersededNamed) -ceq 'model-superseded') 'naming the superseded recipe in the same list still refuses'
    $twoAuto=Get-FastLlmPlan -Hardware $xtx -CatalogPath $realCatalogPath -InstallRoot (Join-Path $work 'plan-install') -NoEngineExecution @twoOptions
    Check ($twoAuto.recipe.id -ceq 'test-xtx-current') 'auto-pick takes the current recipe and skips the superseded one'

    # The recipe block fields, from a recipe that carries the lineage and one that does not.
    $lineageBlock=& $module {
        param($Recipe) New-FastLlmPlanRecipeBlock -Pick ([pscustomobject]@{ recipe=$Recipe; variant='v'; skipped=@() }) -ModelId 'm'
    } ([pscustomobject]@{ id='r'; origin='bitworks'; evidence=[pscustomobject]@{ url='https://bitworks.io/x'; measuredModel='old-model'; measuredRevision='0123456789abcdef0123456789abcdef01234567' } })
    Check ($lineageBlock.label -ceq 'Measured by Bitworks on this card on the previous file revision; this revision is being verified') 'recipe block: the label of a lineage recipe is the honest label'
    Check ($lineageBlock.measuredOn.model -ceq 'old-model' -and $lineageBlock.measuredOn.revision -ceq '0123456789abcdef0123456789abcdef01234567' -and $lineageBlock.measurementNote -ceq 'Expected numbers were measured on the previous file revision 01234567; this revision is being verified.') 'recipe block: measuredOn and measurementNote'
    $plainBlock=& $module {
        param($Recipe) New-FastLlmPlanRecipeBlock -Pick ([pscustomobject]@{ recipe=$Recipe; variant='v'; skipped=@() }) -ModelId 'm'
    } ([pscustomobject]@{ id='r'; origin='bitworks'; evidence=[pscustomobject]@{ url='https://bitworks.io/x' } })
    Check ($plainBlock.label -ceq 'Measured by Bitworks on this card') 'recipe block: the label of any other recipe is unchanged'
    Check (-not $plainBlock.PSObject.Properties['measuredOn'] -and -not $plainBlock.PSObject.Properties['measurementNote']) 'recipe block: no lineage fields without measuredModel'
    $uiNote='Expected numbers were measured on the previous file revision 4ca72078; this revision is being verified.'
    $slow=Format-FastLlmUiSelfTest -SelfTest ([pscustomobject]@{ status='below-expected'; generationTokS=20; promptTokS=400; expectedGenerationTokS=32.7 }) -MeasurementNote $uiNote
    Check ($slow -clike 'Self-test: slower than expected*' -and $slow.EndsWith($uiNote)) 'the window self-test line repeats the measurement note for such a recipe'
    Check ((Format-FastLlmUiSelfTest -SelfTest ([pscustomobject]@{ status='below-expected'; generationTokS=20; promptTokS=400; expectedGenerationTokS=32.7 })) -cnotlike '*previous file revision*') 'the window self-test line has no note for any other recipe'

    # ---- d. preload ---------------------------------------------------------------------------------------------------------------------------
    $tiersPath=Join-Path $root 'config/preload-tiers.json'
    $recipesPath=Join-Path $root 'config/recipes.json'
    $approvedPath=Join-Path $fixtures 'preload-approved-models.json'
    $approvedList=@(& $module { param($p) Read-FastLlmApprovedModels -Path $p } $approvedPath)
    Check (@($approvedList | Where-Object { $oldIds -ccontains [string]$_.modelId }).Count -eq 3 -and @($approvedList | Where-Object { [string]$_.modelId -ceq 'qwen3.8-27b-ud-q4-k-m' }).Count -eq 1) 'preload: the approved list still carries the old (id, revision) pairs'
    $withList=& $module { param($c,$r,$g,$t,$a) Get-FastLlmPreloadSet -CatalogPath $c -RecipesPath $r -GpuVariantsPath $g -TiersPath $t -ApprovedModelsPath $a } $realCatalogPath $recipesPath $variantsPath $tiersPath $approvedPath
    $withoutList=& $module { param($c,$r,$g,$t) Get-FastLlmPreloadSet -CatalogPath $c -RecipesPath $r -GpuVariantsPath $g -TiersPath $t } $realCatalogPath $recipesPath $variantsPath $tiersPath
    Check (@($withList.models | Where-Object { $oldIds -ccontains [string]$_.modelId }).Count -eq 0) 'preload: an approved old pair is skipped, so the new release never downloads a superseded file'
    Check (@($withoutList.models | Where-Object { $oldIds -ccontains [string]$_.modelId }).Count -eq 0) 'preload: recipe and tier entries never contain a superseded model'
    $preloadIds=@($withList.models | ForEach-Object { [string]$_.modelId })
    Check ($preloadIds -ccontains 'qwen3.8-27b-ud-iq4-xs-4af51b35' -and $preloadIds -ccontains 'qwen3.8-27b-ud-q4-k-m-4af51b35' -and $preloadIds -ccontains 'qwen3.8-27b-ud-q6-k-m-4af51b35') 'preload: the replacements are in the set'
    Check ($preloadIds -cnotcontains 'qwen3.8-27b-ud-q5-k-m-4af51b35') 'preload: the Q5_K_M replacement is not approved, so it is not preloaded'

    # ---- a tiny catalog: the old entries describe small files so install, store and rollback cases run without a real model ---------------------
    $tinyBytes=New-Object byte[] 4096
    for($i=0;$i -lt $tinyBytes.Length;$i++){ $tinyBytes[$i]=[byte](($i*7+3) % 251) }
    $tinySha=[BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($tinyBytes)).Replace('-','').ToLowerInvariant()
    $tinyCatalog=New-CatalogCopy 'tiny' { param($d) foreach($id in @('qwen3.8-27b-ud-q4-k-m')){ $m=Get-Model $d $id; $m.sizeBytes=[int64]4096; $m.sha256=$tinySha } }
    $tinyDoc=Get-Content -LiteralPath $tinyCatalog -Raw | ConvertFrom-Json
    $tinyOld=Get-Model $tinyDoc 'qwen3.8-27b-ud-q4-k-m'
    function New-InstallRootWith([string[]]$Files){
        $dir=Join-Path $work ('install-'+[Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $dir 'models') -Force | Out-Null
        foreach($file in $Files){ [IO.File]::WriteAllBytes((Join-Path (Join-Path $dir 'models') $file),$tinyBytes) }
        return $dir
    }

    # The download function of the module is replaced by one that records every call; no case below may call it unless it says so.
    $downloads=New-Object System.Collections.ArrayList
    # Like the real function it returns without transferring when the file already has the pinned hash; any other call is a download and is recorded.
$downloadMock={ param($Url,$Destination,$Sha256,$SizeBytes,$AllowedRedirectHosts)
    if(& $module { param($p,$s) Test-FastLlmFileHash -Path $p -Sha256 $s } $Destination $Sha256){ return $Destination }
    [void]$downloads.Add($Destination); return $Destination }.GetNewClosure()
    & $module { param($mock) Set-Item -Path Function:\Save-FastLlmVerifiedFile -Value $mock } $downloadMock

    # ---- e. install ---------------------------------------------------------------------------------------------------------------------------
    $emptyRoot=New-InstallRootWith @()
    $absent=Get-Thrown { Install-FastLlmCatalogModel -ModelId 'qwen3.8-27b-ud-q4-k-m' -CatalogPath $tinyCatalog -InstallRoot $emptyRoot -AcceptModelLicense -Unattended }
    Check ((Get-Code $absent) -ceq 'model-superseded' -and $downloads.Count -eq 0) 'install: a superseded id whose file is absent refuses with model-superseded before any download'
    $wrongSizeRoot=New-InstallRootWith @()
    [IO.File]::WriteAllBytes((Join-Path (Join-Path $wrongSizeRoot 'models') ([string]$tinyOld.file)),(New-Object byte[] 100))
    $wrongSize=Get-Thrown { Install-FastLlmCatalogModel -ModelId 'qwen3.8-27b-ud-q4-k-m' -CatalogPath $tinyCatalog -InstallRoot $wrongSizeRoot -AcceptModelLicense -Unattended }
    Check ((Get-Code $wrongSize) -ceq 'model-superseded' -and $downloads.Count -eq 0) 'install: a superseded id whose file has the wrong size refuses before any download'
    $wrongHashRoot=New-InstallRootWith @()
    $otherBytes=New-Object byte[] 4096
    [IO.File]::WriteAllBytes((Join-Path (Join-Path $wrongHashRoot 'models') ([string]$tinyOld.file)),$otherBytes)
    $wrongHash=Get-Thrown { Install-FastLlmCatalogModel -ModelId 'qwen3.8-27b-ud-q4-k-m' -CatalogPath $tinyCatalog -InstallRoot $wrongHashRoot -AcceptModelLicense -Unattended }
    Check ((Get-Code $wrongHash) -ceq 'model-superseded' -and $downloads.Count -eq 0 -and (Test-Path -LiteralPath (Join-Path (Join-Path $wrongHashRoot 'models') ([string]$tinyOld.file)))) 'install: a superseded id whose file has the wrong hash refuses, and the file is left as it was'
    $presentRoot=New-InstallRootWith @([string]$tinyOld.file)
    $installed=Install-FastLlmCatalogModel -ModelId 'qwen3.8-27b-ud-q4-k-m' -CatalogPath $tinyCatalog -InstallRoot $presentRoot -AcceptModelLicense -Unattended
    Check ($installed -ceq (Join-Path (Join-Path $presentRoot 'models') ([string]$tinyOld.file)) -and $downloads.Count -eq 0) 'install: a present and verified superseded file installs as for any installed model, with no download'
    $replacement=Get-Model $tinyDoc 'qwen3.8-27b-ud-q4-k-m-4af51b35'
    $fresh=Install-FastLlmCatalogModel -ModelId 'qwen3.8-27b-ud-q4-k-m-4af51b35' -CatalogPath $tinyCatalog -InstallRoot $emptyRoot -AcceptModelLicense -Unattended
    Check ($downloads.Count -eq 1 -and $fresh -ceq (Join-Path (Join-Path $emptyRoot 'models') ([string]$replacement.file))) 'install: the replacement downloads to models/<its file name> (the recording download function is wired)'
    Check ([string]$replacement.file -cne [IO.Path]::GetFileName(([Uri][string]$replacement.url).AbsolutePath)) 'install: the local file name is not the URL basename'
    $downloads.Clear()

    # ---- f. model store -----------------------------------------------------------------------------------------------------------------------
    $storeRoot=New-InstallRootWith @([string]$tinyOld.file)
    & $module { param($m,$r) Write-FastLlmModelConsentReceipt -Model $m -InstallRoot $r -AcceptanceMode explicit-switch } $tinyOld $storeRoot
    Set-Content -LiteralPath (Join-Path (Join-Path $storeRoot 'models') 'stray.partial') -Value 'x'
    $rows=@(Get-FastLlmInstalledModels -InstallRoot $storeRoot -CatalogPath $tinyCatalog)
    Check ($rows.Count -eq 1 -and $rows[0].id -ceq 'qwen3.8-27b-ud-q4-k-m' -and $rows[0].sizeMatches -and $rows[0].consent) 'store: a present superseded file is still listed as installed'
    Check ($rows[0].supersededBy -ceq 'qwen3.8-27b-ud-q4-k-m-4af51b35') 'store: the row says which model replaces it'
    $leftovers=@(Get-FastLlmModelLeftovers -InstallRoot $storeRoot)
    Check ($leftovers.Count -eq 1 -and $leftovers[0].name -ceq 'stray.partial') 'store: leftovers flag the partial download and never the superseded file'
    $removal=Remove-FastLlmInstalledModel -InstallRoot $storeRoot -CatalogPath $tinyCatalog -ModelId 'qwen3.8-27b-ud-q4-k-m'
    Check ($removal.removed -and $removal.reason -ceq 'ok' -and -not (Test-Path -LiteralPath (Join-Path (Join-Path $storeRoot 'models') ([string]$tinyOld.file)))) 'store: Remove-FastLlmInstalledModel works for a superseded id'
    Check ($downloads.Count -eq 0) 'store: nothing was downloaded'

    # ---- rollback: the previous release's catalog (no replacement entries, no supersededBy) with the old file present -------------------------
    $previousCatalog=New-CatalogCopy 'previous-release' {
        param($d)
        $d.models=@($d.models | Where-Object { [string]$_.id -cnotlike '*-4af51b35' })
        foreach($m in @($d.models)){ if($m.PSObject.Properties['supersededBy']){ $m.PSObject.Properties.Remove('supersededBy') } }
        $q4=Get-Model $d 'qwen3.8-27b-ud-q4-k-m'; $q4.sizeBytes=[int64]4096; $q4.sha256=$tinySha
    }
    $previousDoc=Get-FastLlmCatalog -CatalogPath $previousCatalog
    Check (@($previousDoc.models | Where-Object { $_.PSObject.Properties['supersededBy'] }).Count -eq 0 -and @($previousDoc.models | Where-Object { [string]$_.id -clike '*-4af51b35' }).Count -eq 0) 'rollback: the previous-release catalog has no supersededBy and none of the new entries'
    $rollbackPlan=Get-FixturePlan 'rx-7900-xtx-24gb.json' $previousCatalog
    Check ($rollbackPlan.model.id -ceq 'qwen3.8-27b-ud-q4-k-m') 'rollback: under the previous catalog the plan picks the old model'
    $rollbackRoot=New-InstallRootWith @([string]$tinyOld.file)
    $rolledBack=Install-FastLlmCatalogModel -ModelId 'qwen3.8-27b-ud-q4-k-m' -CatalogPath $previousCatalog -InstallRoot $rollbackRoot -AcceptModelLicense -Unattended
    Check ($rolledBack -ceq (Join-Path (Join-Path $rollbackRoot 'models') ([string]$tinyOld.file)) -and $downloads.Count -eq 0) 'rollback: install of the old model with its file present is a no-op with no download'
    $rollbackRows=@(Get-FastLlmInstalledModels -InstallRoot $rollbackRoot -CatalogPath $previousCatalog)
    Check ($rollbackRows.Count -eq 1 -and -not $rollbackRows[0].supersededBy) 'rollback: the store lists the old model with no superseded marker'

    # ---- g. runtime switch --------------------------------------------------------------------------------------------------------------------
    $switchRoot=New-InstallRootWith @([string]$tinyOld.file)
    & $module { param($m,$r) Write-FastLlmModelConsentReceipt -Model $m -InstallRoot $r -AcceptanceMode explicit-switch } $tinyOld $switchRoot
    $switchRefused=& $module { param($c,$r) Resolve-FastLlmSwitchTarget -CatalogPath $c -InstallRoot $r -ModelId 'qwen3.8-27b-ud-q4-k-m' } $tinyCatalog $switchRoot
    Check (-not $switchRefused.ok -and $switchRefused.code -ceq 'switch-target-superseded-model' -and $switchRefused.modelId -ceq 'qwen3.8-27b-ud-q4-k-m') 'switch: a superseded model, even installed and consented, refuses with switch-target-superseded-model'
    $switchPrevious=& $module { param($c,$r) Resolve-FastLlmSwitchTarget -CatalogPath $c -InstallRoot $r -ModelId 'qwen3.8-27b-ud-q4-k-m' } $previousCatalog $switchRoot
    Check ($switchPrevious.ok) 'switch: under the previous-release catalog the same model is a valid switch target'
    $refusalText=& $module { Get-FastLlmSwitchRefusalText -Code 'switch-target-superseded-model' -ModelId 'qwen3.8-27b-ud-q4-k-m' }
    Check ($refusalText -clike "*'qwen3.8-27b-ud-q4-k-m'*older file revision*") 'switch: the refusal has its own plain sentence'

    # ---- h. window model picker ---------------------------------------------------------------------------------------------------------------
    . (Join-Path $root 'src/FastLlm.UiFluentAdapter.ps1')
    . (Join-Path $root 'src/FastLlm.Components.ps1')
    . (Join-Path $root 'src/FastLlm.UiFluentBindings.ps1')
    $pickerCatalog=[pscustomobject]@{ models=@([pscustomobject]@{ id='m-current' },[pscustomobject]@{ id='m-experimental'; autoEligible=$false },[pscustomobject]@{ id='m-old'; supersededBy='m-current' },[pscustomobject]@{ id='m-auto'; autoEligible=$true }) }
    $pickerSettings=[pscustomobject]@{ vulkanBarMitigation='on'; updateCheck='on'; experimentalComponents='off' }
    $made=Initialize-FastLlmUiFluentBindings -InstallRoot $work -Catalog $pickerCatalog -UiSettings $pickerSettings
    $pickerItems=@($made['modelBox'].Items | ForEach-Object { [string]$_ })
    Check (($pickerItems -join ',') -ceq 'Recommended for installed GPU,m-current,m-auto') 'picker: superseded and not-auto-eligible models are hidden, the rest are listed'
    $shippedItems=@((Initialize-FastLlmUiFluentBindings -InstallRoot $work -Catalog $realCatalog -UiSettings $pickerSettings)['modelBox'].Items | ForEach-Object { [string]$_ })
    Check (@($shippedItems | Where-Object { $oldIds -ccontains $_ }).Count -eq 0 -and $shippedItems -ccontains 'qwen3.8-27b-ud-q4-k-m-4af51b35') 'picker: the shipped catalog lists the new Qwen3.8 27B ids and none of the old ones'

    Write-Host "superseded-models-tests: $script:count checks passed"
}
finally {
    if(Test-Path -LiteralPath $work){ Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
