# A whole supervised start with embeddings on, in its own process, for tests/sidecar-tests.ps1: the suite ends this process from outside to
# see what happens to the two servers it supervises. It loads the same test world and the same replaced boundaries as the suite, takes the
# operation lock as the CLI does, and serves until it is ended.
param(
    [Parameter(Mandatory = $true)][string] $Root,
    [Parameter(Mandatory = $true)][string] $WorldRoot,
    [Parameter(Mandatory = $true)][string] $WorldPath,
    [Parameter(Mandatory = $true)][string] $CatalogPath,
    [Parameter(Mandatory = $true)][string] $ControlPath,
    [Parameter(Mandatory = $true)][int] $TextPort,
    [Parameter(Mandatory = $true)][int] $EmbeddingPort
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $Root 'src/FastLlm.psm1') -Force
$module = Get-Module FastLlm
. (Join-Path $PSScriptRoot 'SidecarTestWorld.ps1')
$enginePath = (Get-Process -Id $PID).Path
$state = New-SidecarTestState -EnginePath $enginePath -HelpersRoot $PSScriptRoot
Install-SidecarTestBoundaries -Module $module -State $state
$world = [pscustomobject] @{ root = $WorldRoot; path = $WorldPath; port = $TextPort; embeddingPort = $EmbeddingPort; models = (Join-Path $WorldRoot 'models'); state = (Join-Path $WorldRoot 'state'); catalog = $CatalogPath; control = $ControlPath }
Use-SidecarWorld -Module $module -State $state -World $world
[Environment]::SetEnvironmentVariable('FASTLLM_TEST_SIDECAR_CONTROL', $ControlPath)
$lock = Enter-FastLlmOperation $WorldRoot
try {
    $plan = New-SidecarTextPlan -World $world -HelpersRoot $PSScriptRoot -EnginePath $enginePath -ModelId 'model-a'
    Start-FastLlmServer -Plan $plan -CatalogPath $CatalogPath -InstallRoot $WorldRoot -LoadTimeoutSeconds 600 -Embeddings on -EmbeddingPort $EmbeddingPort 6>$null | Out-Null
}
finally { $lock.Dispose() }
