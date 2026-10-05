#requires -Version 5.1
# Exercise the actual start function with narrowly replaced native/acquisition boundaries.
# No fixture input is added to an executing production action; no engine is launched here.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force
$module=Get-Module FastLlm
$catalogPath=Join-Path $root 'config/catalog.json'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('fast-llm-start-test-'+[Guid]::NewGuid().ToString('N'))
$count=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:count++;Write-Host "PASS: $Message"}
$saved=@{}
try {
    $hardware=Read-FastLlmJson (Join-Path $PSScriptRoot 'fixtures/rx-7900-xtx-24gb.json')
    $engineFolder=Join-Path $temp 'engines/b10698/vulkan'
    New-Item -ItemType Directory -Path $engineFolder -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $engineFolder 'llama-server.exe') -Value 'not executable'
    $hardware.enginePath=Get-FastLlmEngineExecutable -InstallRoot $temp -EngineVersion b10698 -BackendKey vulkan -EntryPoint llama-server.exe
    $plan=Get-FastLlmPlan -Hardware $hardware -CatalogPath $catalogPath -InstallRoot $temp -ModelId qwen3.8-27b-ud-iq4-xs -ContextSize 8192
    New-Item -ItemType Directory -Path (Split-Path $plan.modelPath -Parent) -Force | Out-Null
    Set-Content -LiteralPath $plan.modelPath -Value 'synthetic-placeholder'
    $fresh=$plan | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $fresh.selectedAdapters[0].device='Vulkan1'
    $deviceArgument=[Array]::IndexOf($fresh.serverArguments,'--device')+1
    $fresh.serverArguments[$deviceArgument]='Vulkan1'
    $state=@{events=(New-Object 'Collections.Generic.List[string]');fresh=$fresh;hardware=$hardware;hash=$true;consent=$true;observed=$null;requestedModel=$null;requestedContext=0}
    $names=@('Assert-FastLlmWindowsPrerequisites','Test-FastLlmEngineInstallation','Test-FastLlmFileHash','Test-FastLlmModelConsentReceipt','Get-FastLlmHardware','Get-FastLlmPlan','Invoke-FastLlmSupervisedServer')
    foreach($name in $names){$saved[$name]=& $module {param($N) (Get-Command $N).ScriptBlock} $name}
    & $module {
        param($S)
        $script:startTestState=$S
        function script:Assert-FastLlmWindowsPrerequisites { }
        function script:Test-FastLlmEngineInstallation { return $true }
        function script:Test-FastLlmFileHash { $script:startTestState.events.Add('hash');return $script:startTestState.hash }
        function script:Test-FastLlmModelConsentReceipt { return $script:startTestState.consent }
        function script:Get-FastLlmHardware { $script:startTestState.events.Add('reprobe');return $script:startTestState.hardware }
        function script:Get-FastLlmPlan {
            param($Hardware,$CatalogPath,$Profile,$InstallRoot,$ModelId,$ContextSize,[switch]$AllowExperimentalModel)
            $script:startTestState.requestedModel=$ModelId;$script:startTestState.requestedContext=$ContextSize
            return $script:startTestState.fresh
        }
        function script:Invoke-FastLlmSupervisedServer {
            param($Plan,$InstallRoot,$LoadTimeoutSeconds,$CatalogPath)
            $script:startTestState.events.Add('supervisor');$script:startTestState.observed=$Plan;return 0
        }
    } $state
    $result=Start-FastLlmServer -Plan $plan -CatalogPath $catalogPath -InstallRoot $temp
    Check ($result -eq 0 -and ($state.events -join ',') -eq 'hash,reprobe,supervisor') 'startup hashes, re-probes, then delegates to the supervisor in order'
    Check ($state.requestedModel -eq $plan.model.id -and $state.requestedContext -eq 8192) 'post-hash replanning preserves the explicit artifact and context'
    Check ($state.observed.selectedAdapters[0].device -eq 'Vulkan1' -and $state.observed.serverArguments[$deviceArgument] -eq 'Vulkan1') 'same-artifact launch uses the latest device arguments'

    foreach($property in @('modelPath','backend','catalogVersion')){
        $original=$fresh.$property;$fresh.$property='changed';$state.events.Clear();$reason=$null
        try{Start-FastLlmServer -Plan $plan -CatalogPath $catalogPath -InstallRoot $temp | Out-Null}catch{$reason=$_.Exception.Data['FastLlmReason']}
        Check ($reason -eq 'PlanChanged' -and -not $state.events.Contains('supervisor')) "$property changes cannot reach native launch"
        $fresh.$property=$original
    }
    foreach($property in @('sha256','upstreamRevision','upstreamLicenseSha256','artifactLicense')){
        $original=$fresh.model.$property;$fresh.model.$property='changed';$state.events.Clear();$reason=$null
        try{Start-FastLlmServer -Plan $plan -CatalogPath $catalogPath -InstallRoot $temp | Out-Null}catch{$reason=$_.Exception.Data['FastLlmReason']}
        Check ($reason -eq 'PlanChanged' -and -not $state.events.Contains('supervisor')) "changed model $property cannot reach native launch"
        $fresh.model.$property=$original
    }
    $state.hash=$false;$state.events.Clear();$reason=$null
    try{Start-FastLlmServer -Plan $plan -CatalogPath $catalogPath -InstallRoot $temp | Out-Null}catch{$reason=$_.Exception.Data['FastLlmReason']}
    Check ($reason -eq 'ModelNeedsProvisioning' -and ($state.events -join ',') -eq 'hash') 'integrity failure stops before probe or launch'
    $state.hash=$true;$state.consent=$false;$state.events.Clear();$caught=$false
    try{Start-FastLlmServer -Plan $plan -CatalogPath $catalogPath -InstallRoot $temp | Out-Null}catch{$caught=$_.Exception.Message -match 'consent'}
    Check ($caught -and -not $state.events.Contains('supervisor')) 'missing consent cannot reach native launch'
} finally {
    foreach($name in $saved.Keys){& $module {param($N,$B) Set-Item -Path ('Function:script:'+$N) -Value $B} $name $saved[$name]}
    if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}
}
Write-Host "$count start-boundary checks passed. Native calls were replaced; this is not hardware qualification."
