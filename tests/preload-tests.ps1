#requires -Version 5.1
# Preload set tests: tier config parsing, the planner-derived model set against the repo config, and the approved-artifact CI guard.
# Pure config and fixture work; no engine, GPU or network.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force -PassThru -ErrorAction Stop
$script:count=0
function Check($Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:count++;Write-Host "PASS: $Message"}
function Throws([scriptblock]$Action,[string]$Pattern) {
    $caught=$false;$observed='no exception'
    try { & $Action | Out-Null } catch {
        $caught=[bool]([string]$_.Exception.Message -match $Pattern)
        $observed=[regex]::Replace([string]$_.Exception.Message,'[\x00-\x1f\x7f]',' ')
        if($observed.Length -gt 240){$observed=$observed.Substring(0,240)}
    }
    if(-not $caught){throw "FAIL: rejects $Pattern (observed: $observed)"}
    Check $true "rejects $Pattern"
}
function Write-Utf8([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object Text.UTF8Encoding($false)))}

$tiersPath=Join-Path $root 'config/preload-tiers.json'
$catalog=Join-Path $root 'config/catalog.json'
$recipes=Join-Path $root 'config/recipes.json'
$variants=Join-Path $root 'config/gpu-variants.json'
$approved=Join-Path $root 'tests/fixtures/preload-approved-models.json'
$work=Join-Path ([IO.Path]::GetTempPath()) ('preload-tests-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
try {
    # ---- tiers parse
    $tiers=@(& $module { param($p) Read-FastLlmPreloadTiers -Path $p } $tiersPath)
    Check ($tiers.Count -eq 7) 'tiers parse: 7 tiers'
    Check ((($tiers | ForEach-Object { $_.id }) -join ',') -eq '4gb,8gb,12gb,16gb,20gb,24gb,32gb') 'tiers parse: ids in order'
    Check (@($tiers | Where-Object { $_.id -eq '12gb' })[0].idleFreeVramMiB -eq 11474) 'tiers parse: 12gb idle free VRAM'

    # ---- tiers reject bad
    $doc=Get-Content -LiteralPath $tiersPath -Raw | ConvertFrom-Json
    $dup=Join-Path $work 'dup.json'
    $copy=$doc | ConvertTo-Json -Depth 6 | ConvertFrom-Json
    $copy.tiers[1].id='4gb'
    Write-Utf8 $dup ($copy | ConvertTo-Json -Depth 6)
    Throws { & $module { param($p) Read-FastLlmPreloadTiers -Path $p } $dup } 'Duplicate preload tier'
    $inverted=Join-Path $work 'inverted.json'
    $copy=$doc | ConvertTo-Json -Depth 6 | ConvertFrom-Json
    $copy.tiers[0].conservativeFreeVramMiB=$copy.tiers[0].idleFreeVramMiB+1
    Write-Utf8 $inverted ($copy | ConvertTo-Json -Depth 6)
    Throws { & $module { param($p) Read-FastLlmPreloadTiers -Path $p } $inverted } 'conservative'
    $badSchema=Join-Path $work 'schema.json'
    $copy=$doc | ConvertTo-Json -Depth 6 | ConvertFrom-Json
    $copy.schemaVersion=2
    Write-Utf8 $badSchema ($copy | ConvertTo-Json -Depth 6)
    Throws { & $module { param($p) Read-FastLlmPreloadTiers -Path $p } $badSchema } 'schemaVersion'

    # ---- approved models parse
    $list=@(& $module { param($p) Read-FastLlmApprovedModels -Path $p } $approved)
    Check ($list.Count -eq 7 -and $list[0].modelId -eq 'qwen3.5-4b-iq4-xs' -and $list[0].revision -eq 'e87f176479d0855a907a41277aca2f8ee7a09523') 'approved models parse'
    $badApproved=Join-Path $work 'approved-bad.json'
    Write-Utf8 $badApproved '{"schemaVersion":2,"models":[]}'
    Throws { & $module { param($p) Read-FastLlmApprovedModels -Path $p } $badApproved } 'schemaVersion'

    # ---- preload set golden
    $set=& $module { param($c,$r,$g,$t) Get-FastLlmPreloadSet -CatalogPath $c -RecipesPath $r -GpuVariantsPath $g -TiersPath $t } $catalog $recipes $variants $tiersPath
    Check ($set.schema -eq 'fastllm.preload-set.v1') 'preload set golden: schema'
    $ids=@($set.models | ForEach-Object { $_.modelId })
    $expected='qwen3.8-27b-ud-iq4-xs,qwen3.8-27b-ud-q4-k-m,qwen3.5-4b-iq4-xs,qwen3.5-9b-q6-k,qwen3.5-9b-q8-0,qwen3.8-27b-ud-q6-k-m'
    Check (($ids -join ',') -eq $expected) "preload set golden: model order (observed: $($ids -join ','))"
    $empty=@($set.emptyTiers | ForEach-Object { $_.tier+'/'+$_.budget })
    Check (($empty -join ',') -eq '4gb/idle,4gb/conservative') "preload set golden: emptyTiers (observed: $($empty -join ','))"
    $iq4=@($set.models | Where-Object { $_.modelId -eq 'qwen3.8-27b-ud-iq4-xs' })[0]
    Check ((@($iq4.reasons) -join ',') -eq 'recipe,tier') 'preload set golden: iq4-xs reasons'
    Check ((@($iq4.tiers) -join ',') -eq '20gb') "preload set golden: iq4-xs tiers (observed: $(@($iq4.tiers) -join ','))"
    $q6=@($set.models | Where-Object { $_.modelId -eq 'qwen3.8-27b-ud-q6-k-m' })[0]
    Check ((@($q6.tiers) -join ',') -eq '32gb') 'preload set golden: q6-k-m tiers'
    Check ($null -eq $iq4.approved) 'preload set golden: approved is null without a list'

    # ---- subset of approved (CI guard)
    $checked=& $module { param($c,$r,$g,$t,$a) Get-FastLlmPreloadSet -CatalogPath $c -RecipesPath $r -GpuVariantsPath $g -TiersPath $t -ApprovedModelsPath $a } $catalog $recipes $variants $tiersPath $approved
    foreach ($model in @($checked.models)) {
        Check ($model.approved -eq $true) "preload set subset of approved: $($model.modelId) (a model and its revision must be on the approved list before it joins the preload set)"
    }

    # an approved entry whose modelId differs only in case does not approve the model (exact, case-sensitive match like components)
    $caseList=Join-Path $work 'approved-case.json'
    $caseDoc=Get-Content -LiteralPath $approved -Raw | ConvertFrom-Json
    $caseDoc.models[0].modelId=$caseDoc.models[0].modelId.ToUpperInvariant()
    Write-Utf8 $caseList ($caseDoc | ConvertTo-Json -Depth 20)
    $caseSet=& $module { param($c,$r,$g,$t,$a) Get-FastLlmPreloadSet -CatalogPath $c -RecipesPath $r -GpuVariantsPath $g -TiersPath $t -ApprovedModelsPath $a } $catalog $recipes $variants $tiersPath $caseList
    $caseHit=@($caseSet.models | Where-Object { $_.modelId -ceq 'qwen3.5-4b-iq4-xs' })
    Check ($caseHit.Count -eq 1 -and $caseHit[0].approved -eq $false) 'approved match is case-sensitive: an approved modelId differing only in case leaves the model unapproved'

    # ---- planner: -PreferInstalledModels (bench-only)
    # Placeholder model files are tiny files, not sparse (NTFS has no sparse default), so the planner tests use a copy of the catalog whose model sizes are tiny (picks depend on requiredFreeVramMiB, not sizeBytes).
    $smallDir=Join-Path $work 'small-catalog'
    New-Item -ItemType Directory -Path $smallDir -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'config/components.json') -Destination $smallDir
    $catalogDoc=Get-Content -LiteralPath $catalog -Raw | ConvertFrom-Json
    foreach($m in @($catalogDoc.models)){ $m.sizeBytes=[int64]4096 }
    $smallCatalog=Join-Path $smallDir 'catalog.json'
    Write-Utf8 $smallCatalog ($catalogDoc | ConvertTo-Json -Depth 20)
    $catalogDoc=Get-Content -LiteralPath $smallCatalog -Raw | ConvertFrom-Json
    $tierList=@(& $module { param($p) Read-FastLlmPreloadTiers -Path $p } $tiersPath)
    function New-TierHardware([string]$TierId,[string]$Budget) {
        $t=@($tierList | Where-Object { $_.id -eq $TierId })[0]
        $free=if($Budget -eq 'idle'){$t.idleFreeVramMiB}else{$t.conservativeFreeVramMiB}
        [pscustomobject]@{schemaVersion=1;source='preload-tier';backend='Vulkan';enginePath='C:\FastLLM\vulkan\llama-server.exe';adapters=@([pscustomobject]@{device='Vulkan0';name="Preload tier $TierId";vendorId='1002';vramMiB=$t.vramMiB;freeVramMiB=$free;isAmd=$true;isIntegrated=$false;backend='Vulkan';driverVersion='preload-tier'})}
    }
    function New-InstallRoot([string[]]$ModelIds,[switch]$NoReceipt,[int64]$SizeDelta=0) {
        $dir=Join-Path $work ('install-'+[Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $dir 'models') -Force | Out-Null
        foreach($id in $ModelIds){
            $m=@($catalogDoc.models | Where-Object { $_.id -eq $id })[0]
            $fs=[IO.File]::Create((Join-Path (Join-Path $dir 'models') ([string]$m.file)))
            try { $fs.SetLength([int64]$m.sizeBytes + $SizeDelta) } finally { $fs.Dispose() }
            if(-not $NoReceipt){ & $module { param($m,$r) Write-FastLlmModelConsentReceipt -Model $m -InstallRoot $r -AcceptanceMode explicit-switch } $m $dir }
        }
        return $dir
    }
    function Get-TierPlan($Hardware,[string]$Root,[switch]$Prefer,[string]$ModelId) {
        $a=@{Hardware=$Hardware;CatalogPath=$smallCatalog;Profile='balanced';RecipesPath=$recipes;GpuVariantsPath=$variants;NoEngineExecution=$true}
        if($Root){$a.InstallRoot=$Root}
        if($Prefer){$a.PreferInstalledModels=$true}
        if($ModelId){$a.ModelId=$ModelId}
        & $module { param($a) Get-FastLlmPlan @a } $a
    }
    $hw16=New-TierHardware '16gb' 'idle'
    $rootQ6=New-InstallRoot @('qwen3.5-9b-q6-k')
    $p=Get-TierPlan $hw16 $rootQ6 -Prefer
    Check ($p.model.id -eq 'qwen3.5-9b-q6-k' -and $p.preferInstalled.from -eq 'qwen3.5-9b-q8-0' -and $p.preferInstalled.to -eq 'qwen3.5-9b-q6-k' -and $p.preferInstalled.reason -eq 'not-installed') "prefer installed substitutes (observed: $($p.model.id))"
    $rootNone=New-InstallRoot @()
    $p=Get-TierPlan $hw16 $rootNone -Prefer
    Check ($p.model.id -eq 'qwen3.5-9b-q8-0' -and $null -eq $p.preferInstalled) 'prefer installed keeps top pick when nothing installed fits'
    Remove-Item -LiteralPath $rootNone -Recurse -Force -ErrorAction SilentlyContinue
    $rootNoReceipt=New-InstallRoot @('qwen3.5-9b-q6-k') -NoReceipt
    $p=Get-TierPlan $hw16 $rootNoReceipt -Prefer
    Check ($p.model.id -eq 'qwen3.5-9b-q8-0' -and $null -eq $p.preferInstalled) 'prefer installed ignores a receipt-less file'
    Remove-Item -LiteralPath $rootNoReceipt -Recurse -Force -ErrorAction SilentlyContinue
    $rootShort=New-InstallRoot @('qwen3.5-9b-q6-k') -SizeDelta -1
    $p=Get-TierPlan $hw16 $rootShort -Prefer
    Check ($p.model.id -eq 'qwen3.5-9b-q8-0' -and $null -eq $p.preferInstalled) 'prefer installed ignores a wrong-size file'
    Remove-Item -LiteralPath $rootShort -Recurse -Force -ErrorAction SilentlyContinue
    $p=Get-TierPlan $hw16 $rootQ6 -Prefer -ModelId 'qwen3.5-9b-q8-0'
    Check ($p.model.id -eq 'qwen3.5-9b-q8-0' -and $null -eq $p.preferInstalled) 'explicit ModelId never substitutes'
    Throws { Get-TierPlan $hw16 '' -Prefer } '-PreferInstalledModels requires -InstallRoot'
    foreach($tid in @('12gb','16gb')){
        $h=New-TierHardware $tid 'idle'
        $plain=Get-TierPlan $h $rootQ6
        $plainNoRoot=Get-TierPlan $h ''
        Check ($null -eq $plain.PSObject.Properties['preferInstalled'] -and $plain.model.id -eq $plainNoRoot.model.id -and $plain.recipe.origin -eq $plainNoRoot.recipe.origin) "public default unchanged: $tid"
    }
    Remove-Item -LiteralPath $rootQ6 -Recurse -Force -ErrorAction SilentlyContinue
    # recipe model missing: the Vulkan recipe pick at the 24gb tier is replaced by the best installed fitting model
    $hw24=New-TierHardware '24gb' 'idle'
    $hw24 | Add-Member -NotePropertyName dxgiAdapters -NotePropertyValue @([pscustomobject]@{vendorId=4098;deviceId=29772;revision=200;dedicatedVideoMiB=24534})
    $rootNoneForRecipe=New-InstallRoot @()
    $recipeBase=Get-TierPlan $hw24 $rootNoneForRecipe
    Check ($null -ne $recipeBase.recipe.id -and $recipeBase.model.id -eq 'qwen3.8-27b-ud-q4-k-m') "recipe pick without the switch (observed: $($recipeBase.model.id))"
    Remove-Item -LiteralPath $rootNoneForRecipe -Recurse -Force -ErrorAction SilentlyContinue
    $root9=New-InstallRoot @('qwen3.5-9b-q8-0')
    $p=Get-TierPlan $hw24 $root9 -Prefer
    Check ($p.model.id -eq 'qwen3.5-9b-q8-0' -and $null -eq $p.recipe.id -and $p.recipe.origin -eq 'estimated' -and $p.preferInstalled.from -eq 'qwen3.8-27b-ud-q4-k-m') "recipe model missing substitutes estimated installed pick (observed: $($p.model.id))"
    Remove-Item -LiteralPath $root9 -Recurse -Force -ErrorAction SilentlyContinue
    $rootRecipe=New-InstallRoot @('qwen3.8-27b-ud-q4-k-m')
    $p=Get-TierPlan $hw24 $rootRecipe -Prefer
    Check ($p.model.id -eq 'qwen3.8-27b-ud-q4-k-m' -and $null -ne $p.recipe.id -and $null -eq $p.preferInstalled) 'recipe model installed keeps the recipe'
    Remove-Item -LiteralPath $rootRecipe -Recurse -Force -ErrorAction SilentlyContinue
    Throws { Get-TierPlan (New-TierHardware '4gb' 'idle') (New-InstallRoot @('qwen3.5-4b-iq4-xs')) -Prefer } 'No catalog profile fits'

    # ---- no-download sweep: with exactly the golden set installed, every non-empty tier plans an installed model
    $sweepRoot=New-InstallRoot @($ids)
    $emptyKeys=@($set.emptyTiers | ForEach-Object { $_.tier+'/'+$_.budget })
    foreach($t in $tierList){
        foreach($budget in @('idle','conservative')){
            if($emptyKeys -contains ($t.id+'/'+$budget)){ continue }
            $p=Get-TierPlan (New-TierHardware $t.id $budget) $sweepRoot -Prefer
            $installed=& $module { param($m,$r) Test-FastLlmModelInstalled -Model $m -InstallRoot $r } $p.model $sweepRoot
            Check ($installed -eq $true) "no-download sweep: $($t.id)/$budget plans installed $($p.model.id)"
        }
    }

    Remove-Item -LiteralPath $sweepRoot -Recurse -Force -ErrorAction SilentlyContinue

    # ---- approved components reader
    $approvedComponents=@(& $module { param($p) Read-FastLlmApprovedComponents -Path $p } $approved)
    Check ($approvedComponents.Count -eq 2 -and $approvedComponents[0].id -eq 'llama.cpp-hip-b11658' -and $approvedComponents[0].version -eq 'b11658') 'approved components parse'
    $noComponentsList=Join-Path $work 'approved-nocomponents.json'
    Write-Utf8 $noComponentsList '{"schemaVersion":1,"models":[]}'
    Check (@(& $module { param($p) Read-FastLlmApprovedComponents -Path $p } $noComponentsList).Count -eq 0) 'approved components: absent list is empty'

    # ---- install loop: installer seams record calls and write tiny placeholders; free space is injected
    $GiB=[int64]1073741824
    function New-InstallerSeam([string]$Root,$Calls,[string[]]$FailIds=@()) {
        $m=$module; $doc=$catalogDoc
        { param($id)
            [void]$Calls.Add($id)
            if($FailIds -contains $id){ throw 'seam failure' }
            $model=@($doc.models | Where-Object { $_.id -eq $id })[0]
            $fs=[IO.File]::Create((Join-Path (Join-Path $Root 'models') ([string]$model.file)))
            try { $fs.SetLength([int64]$model.sizeBytes) } finally { $fs.Dispose() }
            & $m { param($mo,$r) Write-FastLlmModelConsentReceipt -Model $mo -InstallRoot $r -AcceptanceMode explicit-switch } $model $Root
        }.GetNewClosure()
    }
    function New-ComponentSeam($Calls) { { param($component) [void]$Calls.Add([string]$component.id) }.GetNewClosure() }
    function Invoke-PreloadSet([string]$Root,[hashtable]$Extra) {
        $a=@{CatalogPath=$smallCatalog;RecipesPath=$recipes;GpuVariantsPath=$variants;TiersPath=$tiersPath;InstallRoot=$Root;ApprovedModelsPath=$approved;MinFreeGB=1;FreeBytesProvider={param($p) [int64]1099511627776}}
        foreach($k in $Extra.Keys){ $a[$k]=$Extra[$k] }
        @(& $module { param($a) Install-FastLlmPreloadSet @a } $a)
    }
    function Rows($Rows,[string]$Kind) { @($Rows | Where-Object { $_.kind -eq $Kind }) }
    function Row($Rows,[string]$Id) { @($Rows | Where-Object { $_.id -eq $Id })[0] }
    $rowProps='action,bytes,error,id,kind,seconds'

    # only approved models install; an unapproved one never reaches the seam
    $partialApproved=Join-Path $work 'approved-partial.json'
    $partialDoc=Get-Content -LiteralPath $approved -Raw | ConvertFrom-Json
    $partialDoc.models=@($partialDoc.models | Where-Object { $_.modelId -ne 'qwen3.8-27b-ud-q6-k-m' })
    Write-Utf8 $partialApproved ($partialDoc | ConvertTo-Json -Depth 6)
    $r1=New-InstallRoot @(); $c1=New-Object System.Collections.ArrayList; $cc1=New-Object System.Collections.ArrayList
    $rows=Invoke-PreloadSet $r1 @{ApprovedModelsPath=$partialApproved;Installer=(New-InstallerSeam $r1 $c1);ComponentInstaller=(New-ComponentSeam $cc1)}
    $m=Rows $rows 'model'
    Check ((Row $rows 'qwen3.8-27b-ud-q6-k-m').action -eq 'awaiting-approval') 'preload installs only approved: unlisted model awaits approval'
    Check (-not ($c1 -contains 'qwen3.8-27b-ud-q6-k-m')) 'preload installs only approved: seam never called for it'
    Check (@($m | Where-Object { $_.id -ne 'qwen3.8-27b-ud-q6-k-m' -and $_.action -ne 'installed' }).Count -eq 0 -and $c1.Count -eq 5) 'preload installs only approved: the others are installed'
    Check ((@($rows[0].PSObject.Properties.Name | Sort-Object) -join ',') -eq $rowProps) 'row property names match the contract'
    Remove-Item -LiteralPath $r1 -Recurse -Force -ErrorAction SilentlyContinue

    # a wrong revision is unapproved
    $wrongRev=Join-Path $work 'approved-wrongrev.json'
    $wrongDoc=Get-Content -LiteralPath $approved -Raw | ConvertFrom-Json
    @($wrongDoc.models | Where-Object { $_.modelId -eq 'qwen3.5-9b-q6-k' })[0].revision='0000000000000000000000000000000000000000'
    Write-Utf8 $wrongRev ($wrongDoc | ConvertTo-Json -Depth 6)
    $r2=New-InstallRoot @(); $c2=New-Object System.Collections.ArrayList
    $rows=Invoke-PreloadSet $r2 @{ApprovedModelsPath=$wrongRev;Installer=(New-InstallerSeam $r2 $c2);ComponentInstaller=(New-ComponentSeam (New-Object System.Collections.ArrayList))}
    Check ((Row $rows 'qwen3.5-9b-q6-k').action -eq 'awaiting-approval' -and -not ($c2 -contains 'qwen3.5-9b-q6-k')) 'revision mismatch is unapproved'
    Remove-Item -LiteralPath $r2 -Recurse -Force -ErrorAction SilentlyContinue

    # present is skipped
    $r3=New-InstallRoot @('qwen3.5-4b-iq4-xs'); $c3=New-Object System.Collections.ArrayList
    $rows=Invoke-PreloadSet $r3 @{Installer=(New-InstallerSeam $r3 $c3);ComponentInstaller=(New-ComponentSeam (New-Object System.Collections.ArrayList))}
    Check ((Row $rows 'qwen3.5-4b-iq4-xs').action -eq 'present' -and -not ($c3 -contains 'qwen3.5-4b-iq4-xs') -and $c3.Count -eq 5) "present is skipped (observed: $((Row $rows 'qwen3.5-4b-iq4-xs').action); calls: $($c3 -join ','))"
    Remove-Item -LiteralPath $r3 -Recurse -Force -ErrorAction SilentlyContinue

    # -Next installs exactly one
    $r4=New-InstallRoot @(); $c4=New-Object System.Collections.ArrayList
    $rows=Invoke-PreloadSet $r4 @{Next=$true;Installer=(New-InstallerSeam $r4 $c4);ComponentInstaller=(New-ComponentSeam (New-Object System.Collections.ArrayList))}
    Check ($c4.Count -eq 1 -and @($rows | Where-Object { $_.action -eq 'installed' }).Count -eq 1) 'next installs exactly one'
    Check ($rows[-1].action -eq 'installed') 'next stops after the first install'
    Remove-Item -LiteralPath $r4 -Recurse -Force -ErrorAction SilentlyContinue

    # components need -AcceptLicense AND a listed id+version
    $r5=New-InstallRoot @(); $c5=New-Object System.Collections.ArrayList; $cc5=New-Object System.Collections.ArrayList
    $rows=Invoke-PreloadSet $r5 @{Installer=(New-InstallerSeam $r5 $c5);ComponentInstaller=(New-ComponentSeam $cc5)}
    $comp=Rows $rows 'component'
    Check ($comp.Count -eq 2 -and @($comp | Where-Object { $_.action -ne 'awaiting-component-licence' }).Count -eq 0 -and $cc5.Count -eq 0) 'components need AcceptLicense: awaiting-component-licence, seam not called'
    Check (@(Rows $rows 'model' | Where-Object { $_.action -eq 'installed' }).Count -eq 6) 'components need AcceptLicense: the models still install'
    Remove-Item -LiteralPath $r5 -Recurse -Force -ErrorAction SilentlyContinue
    $r6=New-InstallRoot @(); $c6=New-Object System.Collections.ArrayList; $cc6=New-Object System.Collections.ArrayList
    $rows=Invoke-PreloadSet $r6 @{AcceptLicense=$true;Installer=(New-InstallerSeam $r6 $c6);ComponentInstaller=(New-ComponentSeam $cc6)}
    Check ((((@($rows[0],$rows[1]) | ForEach-Object { $_.kind + ':' + $_.id + '=' + $_.action }) -join ',') -eq 'component:amd-rocm-gfx1100-10.0.0=installed,component:llama.cpp-hip-b11658=installed')) 'components first, requires before engine, installed with AcceptLicense'
    Check (($cc6 -join ',') -eq 'amd-rocm-gfx1100-10.0.0,llama.cpp-hip-b11658') 'component seam called in chain order'
    Remove-Item -LiteralPath $r6 -Recurse -Force -ErrorAction SilentlyContinue
    # an unlisted requires never gets installed implicitly through the engine that needs it
    $onlyEngine=Join-Path $work 'approved-onlyengine.json'
    $engineDoc=Get-Content -LiteralPath $approved -Raw | ConvertFrom-Json
    $engineDoc.components=@($engineDoc.components | Where-Object { $_.id -eq 'llama.cpp-hip-b11658' })
    Write-Utf8 $onlyEngine ($engineDoc | ConvertTo-Json -Depth 6)
    $r6b=New-InstallRoot @(); $cc6b=New-Object System.Collections.ArrayList
    $rows=Invoke-PreloadSet $r6b @{AcceptLicense=$true;ApprovedModelsPath=$onlyEngine;DryRun=$true;ComponentInstaller=(New-ComponentSeam $cc6b)}
    Check ((((Rows $rows 'component') | ForEach-Object { $_.action }) -join ',') -eq 'awaiting-component-licence,awaiting-component-licence' -and $cc6b.Count -eq 0) 'a component whose requires are not approved is not installed'
    Remove-Item -LiteralPath $r6b -Recurse -Force -ErrorAction SilentlyContinue
    # a listed component with the wrong version is not approved
    $wrongVersion=Join-Path $work 'approved-wrongversion.json'
    $versionDoc=Get-Content -LiteralPath $approved -Raw | ConvertFrom-Json
    @($versionDoc.components | Where-Object { $_.id -eq 'amd-rocm-gfx1100-10.0.0' })[0].version='9.9.9'
    Write-Utf8 $wrongVersion ($versionDoc | ConvertTo-Json -Depth 6)
    $r6c=New-InstallRoot @(); $cc6c=New-Object System.Collections.ArrayList
    $rows=Invoke-PreloadSet $r6c @{AcceptLicense=$true;ApprovedModelsPath=$wrongVersion;DryRun=$true;ComponentInstaller=(New-ComponentSeam $cc6c)}
    Check ((Row $rows 'amd-rocm-gfx1100-10.0.0').action -eq 'awaiting-component-licence') 'a listed component with the wrong version is awaiting-component-licence'
    Remove-Item -LiteralPath $r6c -Recurse -Force -ErrorAction SilentlyContinue

    # disk floor: free space is injected; an existing .partial counts toward what is still needed
    $r7=New-InstallRoot @(); $c7=New-Object System.Collections.ArrayList
    $rows=Invoke-PreloadSet $r7 @{MinFreeGB=2;FreeBytesProvider={param($p) [int64]1073741824};Installer=(New-InstallerSeam $r7 $c7);ComponentInstaller=(New-ComponentSeam (New-Object System.Collections.ArrayList))}
    Check (@(Rows $rows 'model' | Where-Object { $_.action -ne 'disk-floor' }).Count -eq 0 -and $c7.Count -eq 0) 'disk floor: MinFreeGB above free space gives disk-floor, no seam call'
    Remove-Item -LiteralPath $r7 -Recurse -Force -ErrorAction SilentlyContinue
    $r8=New-InstallRoot @(); $c8=New-Object System.Collections.ArrayList
    $q6=@($catalogDoc.models | Where-Object { $_.id -eq 'qwen3.5-9b-q6-k' })[0]
    $partialPath=Join-Path (Join-Path $r8 'models') ($q6.file+'.'+([string]$q6.sha256).Substring(0,16)+'.partial')
    [IO.File]::WriteAllBytes($partialPath,(New-Object byte[] 4000))
    # floor 1 GiB, free 1 GiB + 100: a full 4096 would leave 1 GiB - 3996 (below), the 96 still needed leaves 1 GiB + 4 (ok)
    $rows=Invoke-PreloadSet $r8 @{MinFreeGB=1;FreeBytesProvider={param($p) [int64]1073741924};Installer=(New-InstallerSeam $r8 $c8);ComponentInstaller=(New-ComponentSeam (New-Object System.Collections.ArrayList))}
    Check ((Row $rows 'qwen3.5-9b-q6-k').action -eq 'installed' -and (Row $rows 'qwen3.5-4b-iq4-xs').action -eq 'disk-floor') 'disk floor subtracts an existing .partial from the bytes needed'
    Remove-Item -LiteralPath $r8 -Recurse -Force -ErrorAction SilentlyContinue

    # -Next: a disk-floor row does not count as the one install
    $bigDir=Join-Path $work 'big-catalog'
    New-Item -ItemType Directory -Path $bigDir -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'config/components.json') -Destination $bigDir
    $bigDoc=Get-Content -LiteralPath $smallCatalog -Raw | ConvertFrom-Json
    @($bigDoc.models | Where-Object { $_.id -eq 'qwen3.8-27b-ud-iq4-xs' })[0].sizeBytes=[int64](3*$GiB)
    $bigCatalog=Join-Path $bigDir 'catalog.json'
    Write-Utf8 $bigCatalog ($bigDoc | ConvertTo-Json -Depth 20)
    $r9=New-InstallRoot @(); $c9=New-Object System.Collections.ArrayList
    $rows=Invoke-PreloadSet $r9 @{CatalogPath=$bigCatalog;Next=$true;MinFreeGB=1;FreeBytesProvider={param($p) [int64]2147483648};Installer=(New-InstallerSeam $r9 $c9);ComponentInstaller=(New-ComponentSeam (New-Object System.Collections.ArrayList))}
    $modelRows=Rows $rows 'model'
    Check ((($modelRows | ForEach-Object { $_.action }) -join ',') -eq 'disk-floor,installed' -and $c9.Count -eq 1) "next skips a disk-floor row and installs the next that fits (observed: $((($modelRows | ForEach-Object { $_.action }) -join ',')))"
    Remove-Item -LiteralPath $r9 -Recurse -Force -ErrorAction SilentlyContinue

    # a failing installer gives a failed row; -Next stops there
    $r10=New-InstallRoot @(); $c10=New-Object System.Collections.ArrayList
    $rows=Invoke-PreloadSet $r10 @{Next=$true;Installer=(New-InstallerSeam $r10 $c10 @('qwen3.8-27b-ud-iq4-xs'));ComponentInstaller=(New-ComponentSeam (New-Object System.Collections.ArrayList))}
    Check ($rows[-1].action -eq 'failed' -and $rows[-1].error -match 'seam failure' -and $c10.Count -eq 1) 'a failing installer gives a failed row and -Next stops'
    Remove-Item -LiteralPath $r10 -Recurse -Force -ErrorAction SilentlyContinue

    # dry run: would-install, no seam call, nothing written
    $r11=New-InstallRoot @(); $c11=New-Object System.Collections.ArrayList; $cc11=New-Object System.Collections.ArrayList
    $rows=Invoke-PreloadSet $r11 @{DryRun=$true;AcceptLicense=$true;Installer=(New-InstallerSeam $r11 $c11);ComponentInstaller=(New-ComponentSeam $cc11)}
    Check (@($rows | Where-Object { $_.action -ne 'would-install' }).Count -eq 0 -and $c11.Count -eq 0 -and $cc11.Count -eq 0 -and @(Get-ChildItem -LiteralPath (Join-Path $r11 'models') -Force).Count -eq 0) 'dry run: would-install rows, no seam call, nothing written'
    Remove-Item -LiteralPath $r11 -Recurse -Force -ErrorAction SilentlyContinue

    # the function refuses without an approved list too
    Throws { Invoke-PreloadSet (Join-Path $work 'nowhere') @{ApprovedModelsPath=''} } 'requires -ApprovedModelsPath'

    # ---- envelope and exit codes
    $env1=& $module { param($rows) New-FastLlmPreloadRun -Rows $rows } @([pscustomobject]@{kind='model';id='x';action='present';bytes=[int64]0;seconds=0;error=$null})
    $json1=& $module { param($e) ConvertTo-FastLlmPreloadJson -InputObject $e } $env1
    Check ($env1.schema -eq 'fastllm.preload-run.v1' -and $env1.exitCode -eq 0 -and $json1 -match '"rows":\s*\[') 'envelope: a one-row result serializes rows as an array'
    $env0=& $module { New-FastLlmPreloadRun -Rows @() }
    Check ((& $module { param($e) ConvertTo-FastLlmPreloadJson -InputObject $e } $env0) -match '"rows":\s*\[\s*\]') 'envelope: zero rows serializes rows as an empty array'
    foreach($case in @(@('present,installed,would-install',0),@('present,awaiting-approval',2),@('awaiting-component-licence',2),@('disk-floor,installed',2),@('awaiting-approval,failed',4))){
        $fake=@($case[0].Split(',') | ForEach-Object { [pscustomobject]@{kind='model';id='x';action=$_;bytes=[int64]0;seconds=0;error=$null} })
        $e=& $module { param($rows) New-FastLlmPreloadRun -Rows $rows } $fake
        Check ($e.exitCode -eq $case[1]) "exit code for $($case[0]) is $($case[1])"
    }

    # ---- status contract
    function Get-Status([string]$Root,[hashtable]$Extra) {
        $a=@{CatalogPath=$smallCatalog;RecipesPath=$recipes;GpuVariantsPath=$variants;TiersPath=$tiersPath;InstallRoot=$Root;MinFreeGB=1;FreeBytesProvider={param($p) [int64]5368709120}}
        foreach($k in $Extra.Keys){ $a[$k]=$Extra[$k] }
        & $module { param($a) Get-FastLlmPreloadStatus @a } $a
    }
    $sr=New-InstallRoot @('qwen3.5-4b-iq4-xs') -NoReceipt
    $status=Get-Status $sr @{ApprovedModelsPath=$approved}
    Check ((@($status.PSObject.Properties.Name | Sort-Object) -join ',') -eq 'components,emptyTiers,freeBytes,installRoot,minFreeBytes,models,release,schema') 'status contract: top-level property names'
    Check ((@($status.models[0].PSObject.Properties.Name | Sort-Object) -join ',') -eq 'approved,consent,file,modelId,present,reason,revision,sizeBytes,sizeOk,tiers') 'status contract: models[0] property names'
    Check ((@($status.emptyTiers[0].PSObject.Properties.Name | Sort-Object) -join ',') -eq 'budget,tier') 'status contract: emptyTiers[0] property names'
    Check ((@($status.components[0].PSObject.Properties.Name | Sort-Object) -join ',') -eq 'id,present,verified,version') 'status contract: components[0] property names'
    Check ($status.schema -eq 'fastllm.preload-status.v1' -and $status.freeBytes -eq 5368709120 -and $status.minFreeBytes -eq $GiB -and $status.installRoot -eq $sr -and $null -eq $status.release) 'status contract: schema, freeBytes, minFreeBytes (GiB), installRoot, release null without RELEASE.json'
    $s4=@($status.models | Where-Object { $_.modelId -eq 'qwen3.5-4b-iq4-xs' })[0]
    Check ($s4.present -eq $true -and $s4.sizeOk -eq $true -and $s4.consent -eq $false -and $s4.reason -eq 'consent-missing') 'status: a receipt-less file is consent-missing'
    $s9=@($status.models | Where-Object { $_.modelId -eq 'qwen3.5-9b-q6-k' })[0]
    Check ($s9.present -eq $false -and $s9.reason -eq 'missing' -and $s9.approved -eq $true) 'status: an absent approved model is missing'
    Check ((@($status.components | ForEach-Object { $_.id }) -join ',') -eq 'amd-rocm-gfx1100-10.0.0,llama.cpp-hip-b11658' -and @($status.components | Where-Object { $_.present -or $_.verified }).Count -eq 0) 'status: components cover the recommended engine chains, none present'
    Remove-Item -LiteralPath $sr -Recurse -Force -ErrorAction SilentlyContinue
    $sr2=New-InstallRoot @('qwen3.5-4b-iq4-xs','qwen3.5-9b-q6-k')
    $short=Join-Path (Join-Path $sr2 'models') ([string]@($catalogDoc.models | Where-Object { $_.id -eq 'qwen3.5-9b-q6-k' })[0].file)
    $fs=[IO.File]::Open($short,'Open','ReadWrite'); try { $fs.SetLength(10) } finally { $fs.Dispose() }
    $status2=Get-Status $sr2 @{ApprovedModelsPath=$partialApproved}
    Check (@($status2.models | Where-Object { $_.modelId -eq 'qwen3.5-4b-iq4-xs' })[0].reason -eq 'ok' -and @($status2.models | Where-Object { $_.modelId -eq 'qwen3.5-9b-q6-k' })[0].reason -eq 'size-mismatch') 'status: ok and size-mismatch reasons'
    Check (@($status2.models | Where-Object { $_.modelId -eq 'qwen3.8-27b-ud-q6-k-m' })[0].reason -eq 'awaiting-approval') 'status: an unapproved absent model is awaiting-approval'
    $status3=Get-Status $sr2 @{}
    Check ($null -eq $status3.models[0].approved) 'status: approved is null without a list'
    Remove-Item -LiteralPath $sr2 -Recurse -Force -ErrorAction SilentlyContinue

    # ---- atomic output file
    $outFile=Join-Path $work 'out.json'
    & $module { param($p) Write-FastLlmPreloadOutputFile -Path $p -Json '{"a":1}' } $outFile
    $bytes=[IO.File]::ReadAllBytes($outFile)
    Check ($bytes.Length -eq 7 -and $bytes[0] -eq 123) 'output file: UTF-8 without a BOM'
    & $module { param($p) Write-FastLlmPreloadOutputFile -Path $p -Json '{"a":2}' } $outFile
    Check ((Get-Content -LiteralPath $outFile -Raw) -eq '{"a":2}' -and @(Get-ChildItem -LiteralPath $work -Filter 'out.json*').Count -eq 1) 'output file: replaced atomically, no temp left behind'

    # ---- CLI
    $pwshPath=(Get-Process -Id $PID).Path
    $cli=Join-Path $root 'fast-llm.ps1'
    # Every child-process call goes through here: on Windows PowerShell 5.1 a child's stderr line redirected with 2>&1 under
    # $ErrorActionPreference='Stop' is a terminating NativeCommandError, so the preference is relaxed locally. Returns the output text and exit code.
    function Invoke-PwshChild([object[]]$ChildArgs) {
        $previous=$ErrorActionPreference
        $ErrorActionPreference='Continue'
        try {
            $text=(& $pwshPath @ChildArgs 2>&1 | ForEach-Object { if($_ -is [Management.Automation.ErrorRecord]){ $_.ToString() } else { [string]$_ } } | Out-String)
            $code=$LASTEXITCODE
        } finally { $ErrorActionPreference=$previous }
        [pscustomobject]@{Text=$text;Code=$code}
    }
    # The guards throw; a child that prints the exception message keeps the text free of console line wrapping.
    function Get-CliGuard([string]$CliArguments) {
        $command='try { & '''+$cli+''' '+$CliArguments+'; exit $LASTEXITCODE } catch { [Console]::Out.WriteLine($_.Exception.Message); exit 1 }'
        Invoke-PwshChild @('-NoProfile','-Command',$command)
    }
    $g=Get-CliGuard 'models -Preload'
    $out=$g.Text; $LASTEXITCODE=$g.Code
    Check ($LASTEXITCODE -ne 0 -and $out -match [regex]::Escape('-Preload requires -ApprovedModelsPath; no licence is accepted without an approved list.')) 'cli guard: -Preload without -ApprovedModelsPath refuses'
    $g=Get-CliGuard 'plan -Preload'; $out=$g.Text; $LASTEXITCODE=$g.Code
    Check ($LASTEXITCODE -ne 0 -and $out -match 'only valid with the models action') 'cli guard: -Preload only with models'
    $g=Get-CliGuard 'doctor -Next'; $out=$g.Text; $LASTEXITCODE=$g.Code
    Check ($LASTEXITCODE -ne 0 -and $out -match 'only valid with the models action') 'cli guard: -Next only with models'
    # The -File children below run fast-llm.ps1 past its parameter checks, so they reach the standard-user guard, which refuses every live action
    # under an Administrator token (the hosted Windows runner is elevated) before the output path is touched. They run as a standard user in the
    # bench native gate; the in-process guard checks above and the module-level checks below stay on every runner.
    $cliChildrenElevated=$false
    if($env:OS -eq 'Windows_NT'){ $cliChildrenElevated=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    if($cliChildrenElevated){ Write-Host 'SKIP: preload CLI child cases (fast-llm.ps1 refuses elevation; they run as a standard user in the bench native gate)' }
    else {
        $cliRoot=Join-Path $work 'cli-root'
        $cliOut=Join-Path $work 'cli-run.json'
        $g=Invoke-PwshChild @('-NoProfile', '-File', $cli, 'models', '-Preload', '-DryRun', '-ApprovedModelsPath', $partialApproved, '-InstallRoot', $cliRoot, '-OutputPath', $cliOut, '-AsJson')
        $out=$g.Text; $LASTEXITCODE=$g.Code
        $cliCode=$LASTEXITCODE
        $envelope=Get-Content -LiteralPath $cliOut -Raw | ConvertFrom-Json
        Check ($cliCode -eq 2 -and $envelope.schema -eq 'fastllm.preload-run.v1' -and $envelope.exitCode -eq 2 -and @($envelope.rows).Count -ge 6) "cli: -Preload -DryRun with an unlisted model exits 2 and writes the envelope (exit $cliCode)"
        Check (-not (Test-Path -LiteralPath $cliRoot)) 'cli: dry run creates no install root'
        $statusOut=Join-Path $work 'cli-status.json'
        $g=Invoke-PwshChild @('-NoProfile', '-File', $cli, 'models', '-PreloadStatus', '-AsJson', '-InstallRoot', $cliRoot, '-OutputPath', $statusOut)
        $out=$g.Text; $LASTEXITCODE=$g.Code
        $cliStatus=Get-Content -LiteralPath $statusOut -Raw | ConvertFrom-Json
        Check ($LASTEXITCODE -eq 0 -and $cliStatus.schema -eq 'fastllm.preload-status.v1' -and @($cliStatus.models).Count -eq 6) 'cli: -PreloadStatus -AsJson -OutputPath writes the status contract'

        # ---- error path: no stale report, fail fast on a bad output path, envelope on an unexpected exception
        $staleOut=Join-Path $work 'stale.json'
        Write-Utf8 $staleOut '{"schema":"fastllm.preload-run.v1","exitCode":0,"rows":[]}'
        $badApprovedPath=Join-Path $work 'does-not-exist.json'
        $g=Invoke-PwshChild @('-NoProfile', '-File', $cli, 'models', '-Preload', '-DryRun', '-ApprovedModelsPath', $badApprovedPath, '-InstallRoot', (Join-Path $work 'stale-root'), '-OutputPath', $staleOut, '-AsJson')
        $out=$g.Text; $LASTEXITCODE=$g.Code
        $staleCode=$LASTEXITCODE
        $afterStale=$null
        if(Test-Path -LiteralPath $staleOut){ $afterStale=Get-Content -LiteralPath $staleOut -Raw | ConvertFrom-Json }
        Check ($staleCode -eq 1 -and $null -ne $afterStale -and $afterStale.exitCode -eq 1 -and $afterStale.error -ne $null) 'a failing early run replaces the stale report with an exitCode 1 envelope'
        Write-Utf8 $staleOut 'old'
        $g=Invoke-PwshChild @('-NoProfile', '-File', $cli, 'models', '-PreloadStatus', '-AsJson', '-ApprovedModelsPath', $badApprovedPath, '-InstallRoot', (Join-Path $work 'stale-root'), '-OutputPath', $staleOut)
        $out=$g.Text; $LASTEXITCODE=$g.Code
        Check ($LASTEXITCODE -eq 1 -and -not (Test-Path -LiteralPath $staleOut)) '-PreloadStatus failure: exit 1 and no file'
        $missingDirOut=Join-Path (Join-Path $work 'no-such-dir') 'out.json'
        $failRoot=Join-Path $work 'failfast-root'
        $g=Invoke-PwshChild @('-NoProfile', '-File', $cli, 'models', '-Preload', '-DryRun', '-ApprovedModelsPath', $approved, '-InstallRoot', $failRoot, '-OutputPath', $missingDirOut)
        $out=$g.Text; $LASTEXITCODE=$g.Code
        Check ($LASTEXITCODE -ne 0 -and -not (Test-Path -LiteralPath $failRoot)) 'a missing -OutputPath directory fails fast, nothing installed'
        $dirAsOut=Join-Path $work 'out-is-a-dir'
        New-Item -ItemType Directory -Path $dirAsOut -Force | Out-Null
        $g=Invoke-PwshChild @('-NoProfile', '-File', $cli, 'models', '-Preload', '-DryRun', '-ApprovedModelsPath', $approved, '-InstallRoot', $failRoot, '-OutputPath', $dirAsOut)
        $out=$g.Text; $LASTEXITCODE=$g.Code
        Check ($LASTEXITCODE -ne 0 -and -not (Test-Path -LiteralPath $failRoot)) 'an -OutputPath that is a directory fails fast'
        if($env:OS -ne 'Windows_NT' -and (id -u) -ne '0'){
            $roDir=Join-Path $work 'readonly'
            New-Item -ItemType Directory -Path $roDir -Force | Out-Null
            chmod 555 $roDir
            $g=Invoke-PwshChild @('-NoProfile', '-File', $cli, 'models', '-Preload', '-DryRun', '-ApprovedModelsPath', $approved, '-InstallRoot', $failRoot, '-OutputPath', (Join-Path $roDir 'out.json'))
            $out=$g.Text; $LASTEXITCODE=$g.Code
            Check ($LASTEXITCODE -ne 0 -and -not (Test-Path -LiteralPath $failRoot)) 'an unwritable -OutputPath directory fails fast'
            chmod 755 $roDir
        }
    }

    # an exception outside the per-item try, after the first row: envelope with the rows so far, the type name only
    $calls=New-Object System.Collections.ArrayList
    $throwOnSecond={ param($p) [void]$calls.Add(1); if($calls.Count -ge 2){ throw (New-Object System.InvalidOperationException('secret detail C:\private\path')) }; [int64]1099511627776 }.GetNewClosure()
    $midOut=Join-Path $work 'mid.json'
    $midRoot=New-InstallRoot @('qwen3.5-4b-iq4-xs')
    $midArgs=@{CatalogPath=$smallCatalog;RecipesPath=$recipes;GpuVariantsPath=$variants;TiersPath=$tiersPath;InstallRoot=$midRoot;ApprovedModelsPath=$approved;MinFreeGB=1;DryRun=$true;FreeBytesProvider=$throwOnSecond}
    $envMid=& $module { param($a,$o) Invoke-FastLlmPreloadRun -InstallArguments $a -OutputPath $o } $midArgs $midOut
    $fileText=Get-Content -LiteralPath $midOut -Raw
    $fileMid=$fileText | ConvertFrom-Json
    Check ($envMid.exitCode -eq 1 -and $envMid.error -eq 'InvalidOperationException' -and @($envMid.rows).Count -ge 1 -and $fileMid.exitCode -eq 1 -and $fileMid.error -eq 'InvalidOperationException' -and $fileText -notmatch 'secret|private') 'mid-run exception: envelope exitCode 1, rows so far, error is the type name only'
    Check ((@($fileMid.PSObject.Properties.Name | Sort-Object) -join ',') -eq 'error,exitCode,rows,schema') 'mid-run envelope has the additive error field'
    $envOk=& $module { param($a) Invoke-FastLlmPreloadRun -InstallArguments $a } @{CatalogPath=$smallCatalog;RecipesPath=$recipes;GpuVariantsPath=$variants;TiersPath=$tiersPath;InstallRoot=$midRoot;ApprovedModelsPath=$approved;MinFreeGB=1;DryRun=$true;FreeBytesProvider={param($p) [int64]1099511627776}}
    Check ($null -eq $envOk.PSObject.Properties['error']) 'a normal envelope has no error field'
    # process exit code through a child pwsh running the same function
    $childOut=Join-Path $work 'child.json'
    $childLines=@(
        "Import-Module '$(Join-Path $root 'src/FastLlm.psm1')' -Force",
        '$global:n=0',
        "`$a=@{CatalogPath='$smallCatalog';RecipesPath='$recipes';GpuVariantsPath='$variants';TiersPath='$tiersPath';InstallRoot='$midRoot';ApprovedModelsPath='$approved';MinFreeGB=1;DryRun=`$true;FreeBytesProvider={param(`$p) `$global:n++; if(`$global:n -ge 2){ throw 'boom' }; [int64]1099511627776}}",
        "`$e=Invoke-FastLlmPreloadRun -InstallArguments `$a -OutputPath '$childOut'",
        'exit $e.exitCode')
    $childCode=(Invoke-PwshChild @('-NoProfile','-Command',($childLines -join '; '))).Code
    $childEnv=Get-Content -LiteralPath $childOut -Raw | ConvertFrom-Json
    Check ($childCode -eq 1 -and $childEnv.exitCode -eq 1 -and $childEnv.error -eq 'RuntimeException' -and @($childEnv.rows).Count -ge 1) 'mid-run exception in a child process: exit code 1 equals envelope exitCode'
    Remove-Item -LiteralPath $midRoot -Recurse -Force -ErrorAction SilentlyContinue

    # ---- deterministic
    $again=& $module { param($c,$r,$g,$t) Get-FastLlmPreloadSet -CatalogPath $c -RecipesPath $r -GpuVariantsPath $g -TiersPath $t } $catalog $recipes $variants $tiersPath
    Check (($set | ConvertTo-Json -Depth 6) -eq ($again | ConvertTo-Json -Depth 6)) 'preload set deterministic'
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "preload-tests: $script:count checks passed"
# The child-process checks above end on a deliberate non-zero exit; do not leak it into a caller that runs several suites in one session.
$global:LASTEXITCODE = 0
