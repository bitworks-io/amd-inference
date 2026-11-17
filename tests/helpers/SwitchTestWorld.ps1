# Test world for tests/model-switch-tests.ps1: a small synthetic model list read from a JSON file (ids, files, sizes, consent, recipes),
# installed over the module's catalog reader, consent check and recipe reader. The suite and its independent client process both load it,
# so both sides see the same models. Nothing here runs outside the tests.
function Install-SwitchTestWorld {
    param([Parameter(Mandatory = $true)] $Module, [Parameter(Mandatory = $true)][string] $WorldPath)
    & $Module {
        param($Path)
        $script:switchTestWorldPath = $Path
        if (-not (Get-Variable -Name switchTestEvents -Scope Script -ErrorAction SilentlyContinue)) { $script:switchTestEvents = $null }
        function script:Get-SwitchTestWorld { return (Read-FastLlmJson -Path $script:switchTestWorldPath -MaxBytes 262144) }
        function script:Get-FastLlmCatalog {
            param([string] $CatalogPath)
            $world = Get-SwitchTestWorld
            $assets = [pscustomobject] @{
                vulkan = [pscustomobject] @{ enabled = $true; entryPoint = 'mock-engine'; disabledReason = '' }
                rocm   = [pscustomobject] @{ enabled = $false; entryPoint = 'mock-engine'; disabledReason = 'switch-test' }
            }
            return [pscustomobject] @{ schemaVersion = 1; catalogVersion = 'switch-test'; engine = [pscustomobject] @{ version = 'test'; assets = $assets }; models = @($world.models) }
        }
        function script:Test-FastLlmModelConsentReceipt {
            param($Model, [string] $InstallRoot)
            if ($null -ne $script:switchTestEvents) { $script:switchTestEvents.Add('consent:' + [string] $Model.id) }
            $world = Get-SwitchTestWorld
            foreach ($entry in @($world.models)) { if ([string] $entry.id -ceq [string] $Model.id) { return [bool] $entry.consent } }
            return $false
        }
        function script:Read-FastLlmRecipes {
            param([string] $Path)
            $world = Get-SwitchTestWorld
            return @($world.recipes)
        }
    } $WorldPath
}
