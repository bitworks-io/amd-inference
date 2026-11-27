#requires -Version 5.1
# Settings additions: the REAL availability probes of the Settings page run against a temporary config root and install root (no mock of the planner's own row
# source). Test-FastLlmUiFluentLongMeasured (the Long probe, and the same probe asked for the Default profile at 2 requests at once) is true only for a model with a
# measured row at the asked slots, and false for another model, another slots value and the shipped file with no rows. Test-FastLlmUiFluentEmbeddingsAvailable
# is false with no approved embedding model installed. The probe functions are taken from the page source by AST. No WPF, GPU, network or bench; runs everywhere.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force
$script:count=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:count++;Write-Host "PASS: $Message"}
$work=Join-Path ([IO.Path]::GetTempPath()) ('ui-fluent-settings-probe-'+[Guid]::NewGuid().ToString('N'))
$noBom=New-Object Text.UTF8Encoding($false)
try{
    $configRoot=Join-Path $work 'src-root/config'
    $installRoot=Join-Path $work 'install'
    New-Item -ItemType Directory -Path $configRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'config/catalog.json') -Destination (Join-Path $configRoot 'catalog.json')
    $ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'src/FastLlm.UiFluentSettings.ps1'),[ref]$null,[ref]$null)
    foreach($n in 'Test-FastLlmUiFluentLongMeasured','Test-FastLlmUiFluentEmbeddingsAvailable'){
        $fn=$ast.Find({param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -ceq $n},$true)
        if($null -eq $fn){throw "FAIL: $n is not in the page source"}
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    $script:FastLlmUiFluentSourceRoot=Join-Path $work 'src-root'
    $script:installPath=$installRoot
    # The module's internal helpers are reached through the module scope, as the probe itself does.
    $catalog=& (Get-Module FastLlm) { param($Path) Get-FastLlmCatalog -CatalogPath $Path } (Join-Path $configRoot 'catalog.json')
    $engineId=[string](& (Get-Module FastLlm) { param($Catalog) Get-FastLlmBuiltInEngineId -Catalog $Catalog } $catalog)
    $backend=@('rocm','vulkan')|Where-Object{[bool]$catalog.engine.assets.$_.enabled}|Select-Object -First 1
    $models=@($catalog.models|Where-Object{-not (& (Get-Module FastLlm) { param($M) Get-FastLlmModelSupersededBy -Model $M } $_)})
    $model=$models[0]
    $other=$models[1]
    $modelIndex=[Array]::IndexOf(@($catalog.models|ForEach-Object{[string]$_.id}),[string]$model.id)+1
    $otherIndex=[Array]::IndexOf(@($catalog.models|ForEach-Object{[string]$_.id}),[string]$other.id)+1
    function New-Row([string]$ModelId,[string]$Sha,[string]$Profile,[int[]]$Slots){
        return [ordered]@{ modelId=$ModelId; modelSha256=$Sha; engineId=$engineId; backend=[string]$backend; id=$Profile; contextTotal=65536; slotsAllowed=@($Slots); cacheTypeK='q8_0'; cacheTypeV='q8_0'; requiredFreeVramMiB=9000; fitTargetMiB=512; evidence=[ordered]@{resultId='probe-test-1'} }
    }
    function Write-Profiles($Rows){
        $doc=[ordered]@{ schema='bitworks.fastllm-serving-profiles/v1'; profiles=@($Rows) }
        [IO.File]::WriteAllText((Join-Path $configRoot 'serving-profiles.json'),($doc|ConvertTo-Json -Depth 8),$noBom)
    }
    function Set-Box([int]$Index,[string]$Item){ $script:modelBox=[pscustomobject]@{SelectedIndex=$Index;SelectedItem=$Item} }
    function One-Bool($Value){ $r=@($Value); return [bool]($r.Count -eq 1 -and $r[0] -is [bool]) }

    # The shipped file: no rows, so nothing is measured (Long and Default at 2 can only fail at a start).
    Copy-Item -LiteralPath (Join-Path $root 'config/serving-profiles.json') -Destination (Join-Path $configRoot 'serving-profiles.json') -Force
    Set-Box $modelIndex ([string]$model.id)
    Check (-not (Test-FastLlmUiFluentLongMeasured -ProfileId 'long' -Slots 1) -and -not (Test-FastLlmUiFluentLongMeasured -ProfileId 'default' -Slots 2)) 'the shipped serving-profiles.json (no rows): Long at 1 and Default at 2 are not measured'

    # One long row at slots 1, for the first model.
    Write-Profiles @((New-Row ([string]$model.id) ([string]$model.sha256) 'long' @(1)))
    Set-Box $modelIndex ([string]$model.id)
    Check ((Test-FastLlmUiFluentLongMeasured -ProfileId 'long' -Slots 1) -eq $true) 'a measured long row at slots 1: the Long probe is true for the matching model at 1'
    Check ((Test-FastLlmUiFluentLongMeasured) -eq $true) 'the Long probe defaults to profile long at slots 1'
    Check ((Test-FastLlmUiFluentLongMeasured -ProfileId 'long' -Slots 2) -eq $false) 'the same row does not allow 2 at once: the Long probe is false at 2'
    Check ((Test-FastLlmUiFluentLongMeasured -ProfileId 'default' -Slots 2) -eq $false) 'a long row is not a default row: Default at 2 is false'
    Set-Box $otherIndex ([string]$other.id)
    Check ((Test-FastLlmUiFluentLongMeasured -ProfileId 'long' -Slots 1) -eq $false) 'another chosen model has no row: the Long probe is false'
    Check ((One-Bool (Test-FastLlmUiFluentLongMeasured -ProfileId 'long' -Slots 1)) -and (One-Bool (Test-FastLlmUiFluentLongMeasured -ProfileId 'long' -Slots 2))) 'the probe returns exactly one bool'
    # A row with the wrong model hash (a different file revision) does not count.
    Write-Profiles @((New-Row ([string]$model.id) ('0'*64) 'long' @(1)))
    Set-Box $modelIndex ([string]$model.id)
    Check ((Test-FastLlmUiFluentLongMeasured -ProfileId 'long' -Slots 1) -eq $false) 'a row for another file revision of the model is not measured'

    # A long row allowing 1 and 2, and a default row allowing 1 and 2: both probes are true at 2 for the model.
    Write-Profiles @((New-Row ([string]$model.id) ([string]$model.sha256) 'long' @(1,2)),(New-Row ([string]$model.id) ([string]$model.sha256) 'default' @(1,2)))
    Set-Box $modelIndex ([string]$model.id)
    Check ((Test-FastLlmUiFluentLongMeasured -ProfileId 'long' -Slots 2) -eq $true -and (Test-FastLlmUiFluentLongMeasured -ProfileId 'default' -Slots 2) -eq $true) 'long and default rows that allow 2: both probes are true at 2'
    # A default row alone: Default at 2 is measured but Long is not.
    Write-Profiles @((New-Row ([string]$model.id) ([string]$model.sha256) 'default' @(1,2)))
    Set-Box $modelIndex ([string]$model.id)
    Check ((Test-FastLlmUiFluentLongMeasured -ProfileId 'default' -Slots 2) -eq $true -and (Test-FastLlmUiFluentLongMeasured -ProfileId 'long' -Slots 2) -eq $false) 'a default row alone: Default at 2 is measured, Long is not'
    Set-Box $otherIndex ([string]$other.id)
    Check ((Test-FastLlmUiFluentLongMeasured -ProfileId 'default' -Slots 2) -eq $false) 'a default row for another model: Default at 2 is false'
    # A broken file fails closed.
    [IO.File]::WriteAllText((Join-Path $configRoot 'serving-profiles.json'),'{ not json',$noBom)
    Check ((Test-FastLlmUiFluentLongMeasured -ProfileId 'long' -Slots 1) -eq $false) 'an unreadable serving-profiles.json is not measured (the probe fails closed, without throwing)'

    # The embeddings probe: no approved embedding model is installed under this install, so it is false (and it does not throw).
    Check ((Test-FastLlmUiFluentEmbeddingsAvailable) -eq $false -and (One-Bool (Test-FastLlmUiFluentEmbeddingsAvailable))) 'the embeddings probe is false with no embedding model installed (one bool, no throw)'
    Write-Host "Settings probe tests passed ($($script:count) checks)."
}
finally{
    if(Test-Path -LiteralPath $work){Remove-Item -LiteralPath $work -Recurse -Force}
}
