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
    $state=@{events=(New-Object 'Collections.Generic.List[string]');fresh=$fresh;hardware=$hardware;hash=$true;consent=$true;observed=$null;requestedModel=$null;requestedContext=0;supervisorBound=$null;supervisorPolicy=$null;supervisorCanary=$false;supervisorBinding=$null;componentOk=$true;engineChecks=0;failComponent='';componentCalls=(New-Object 'Collections.Generic.List[string]')}
    $names=@('Assert-FastLlmWindowsPrerequisites','Test-FastLlmEngineInstallation','Test-FastLlmComponentInstallation','Install-FastLlmComponent','Test-FastLlmFileHash','Test-FastLlmModelConsentReceipt','Get-FastLlmHardware','Get-FastLlmPlan','Invoke-FastLlmSupervisedServer')
    foreach($name in $names){$saved[$name]=& $module {param($N) (Get-Command $N).ScriptBlock} $name}
    & $module {
        param($S)
        $script:startTestState=$S
        function script:Assert-FastLlmWindowsPrerequisites { }
        function script:Test-FastLlmEngineInstallation { $script:startTestState.engineChecks++;return $true }
        function script:Test-FastLlmComponentInstallation { param($InstallRoot,$Component,$Depth) $script:startTestState.events.Add('component-check');$script:startTestState.componentCalls.Add(([string]$Component.id)+':'+[string]$Depth);if([string]$Component.id -ceq $script:startTestState.failComponent){return $false};return $script:startTestState.componentOk }
        function script:Install-FastLlmComponent { param($ComponentsPath,$ComponentId,$InstallRoot) $script:startTestState.events.Add('INSTALL-COMPONENT');return $null }
        function script:Test-FastLlmFileHash { $script:startTestState.events.Add('hash');return $script:startTestState.hash }
        function script:Test-FastLlmModelConsentReceipt { return $script:startTestState.consent }
        function script:Get-FastLlmHardware { $script:startTestState.events.Add('reprobe');return $script:startTestState.hardware }
        function script:Get-FastLlmPlan {
            param($Hardware,$CatalogPath,$Profile,$InstallRoot,$ModelId,$ContextSize,[switch]$AllowExperimentalModel,$RecipesPath,$GpuVariantsPath,$RecipeId,[switch]$Recovered)
            $script:startTestState.requestedModel=$ModelId;$script:startTestState.requestedContext=$ContextSize
            return $script:startTestState.fresh
        }
        function script:Invoke-FastLlmSupervisedServer {
            param($Plan,$InstallRoot,$LoadTimeoutSeconds,$CatalogPath,[string]$VulkanBarMitigation,[switch]$ThroughputCanary,[string]$DeviceBinding,[switch]$SelfTest)
            $script:startTestState.supervisorBound=@($PSBoundParameters.Keys | Sort-Object);$script:startTestState.supervisorBinding=$DeviceBinding
            $script:startTestState.supervisorPolicy=$VulkanBarMitigation;$script:startTestState.supervisorCanary=[bool]$ThroughputCanary
            $script:startTestState.events.Add('supervisor');$script:startTestState.observed=$Plan;return 0
        }
    } $state
    $result=Start-FastLlmServer -Plan $plan -CatalogPath $catalogPath -InstallRoot $temp
    Check ($result -eq 0 -and ($state.events -join ',') -eq 'hash,reprobe,supervisor') 'startup hashes, re-probes, then delegates to the supervisor in order'
    Check ($state.requestedModel -eq $plan.model.id -and $state.requestedContext -eq 8192) 'post-hash replanning preserves the explicit artifact and context'
    Check ($state.observed.selectedAdapters[0].device -eq 'Vulkan1' -and $state.observed.serverArguments[$deviceArgument] -eq 'Vulkan1') 'same-artifact launch uses the latest device arguments'

    # Vulkan memory policy / canary wiring: defaults leave the supervisor call exactly as it was.
    Check (($state.supervisorBound -join ',') -eq 'CatalogPath,InstallRoot,LoadTimeoutSeconds,Plan') 'a default start passes the supervisor exactly the pre-existing parameters (mitigation and canary stay off)'
    Start-FastLlmServer -Plan $plan -CatalogPath $catalogPath -InstallRoot $temp -VulkanBarMitigation on | Out-Null
    Check ($state.supervisorBound -contains 'VulkanBarMitigation' -and $state.supervisorPolicy -eq 'on' -and -not $state.supervisorCanary) 'an explicit on reaches the supervisor and nothing else changes'
    Start-FastLlmServer -Plan $plan -CatalogPath $catalogPath -InstallRoot $temp -VulkanBarMitigation auto -ThroughputCanary | Out-Null
    Check ($state.supervisorPolicy -eq 'auto' -and $state.supervisorCanary) 'an explicit auto and the canary flag reach the supervisor'
    Start-FastLlmServer -Plan $plan -CatalogPath $catalogPath -InstallRoot $temp -VulkanBarMitigation off | Out-Null
    Check (($state.supervisorBound -join ',') -eq 'CatalogPath,InstallRoot,LoadTimeoutSeconds,Plan') 'an explicit off is the same call as the default'
    # W03 Phase A device binding: reaches the supervisor only when not off; off is the very same supervisor call as the default.
    Start-FastLlmServer -Plan $plan -CatalogPath $catalogPath -InstallRoot $temp -DeviceBinding off | Out-Null
    Check (($state.supervisorBound -join ',') -eq 'CatalogPath,InstallRoot,LoadTimeoutSeconds,Plan' -and [string]::IsNullOrEmpty([string]$state.supervisorBinding)) 'an explicit -DeviceBinding off is exactly the default supervisor call (no DeviceBinding parameter passed)'
    Start-FastLlmServer -Plan $plan -CatalogPath $catalogPath -InstallRoot $temp -DeviceBinding record | Out-Null
    Check (($state.supervisorBound -join ',') -eq 'CatalogPath,DeviceBinding,InstallRoot,LoadTimeoutSeconds,Plan' -and $state.supervisorBinding -ceq 'record' -and -not $state.supervisorCanary) '-DeviceBinding record reaches the supervisor and nothing else changes'
    Start-FastLlmServer -Plan $plan -CatalogPath $catalogPath -InstallRoot $temp -VulkanBarMitigation auto -DeviceBinding record | Out-Null
    Check ($state.supervisorPolicy -eq 'auto' -and $state.supervisorBinding -ceq 'record') 'the BAR policy and the device binding travel together'
    Start-FastLlmServer -Plan $plan -CatalogPath $catalogPath -InstallRoot $temp -DeviceBinding enforce | Out-Null
    Check (($state.supervisorBound -join ',') -eq 'CatalogPath,DeviceBinding,InstallRoot,LoadTimeoutSeconds,Plan' -and $state.supervisorBinding -ceq 'enforce' -and -not $state.supervisorCanary) '-DeviceBinding enforce reaches the supervisor and nothing else changes'
    $state.events.Clear();$bogusRejected=$false
    try { Start-FastLlmServer -Plan $plan -CatalogPath $catalogPath -InstallRoot $temp -DeviceBinding bogus | Out-Null } catch { $bogusRejected=$true }
    Check ($bogusRejected -and $state.events.Count -eq 0) 'an unknown -DeviceBinding value fails before any hashing or launch'
    & $module { $script:FastLlmVulkanBarMitigationPolicy = 'auto' }
    try {
        Start-FastLlmServer -Plan $plan -CatalogPath $catalogPath -InstallRoot $temp | Out-Null
        Check ($state.supervisorPolicy -eq 'auto') 'the module-level policy is honoured when no start parameter is given'
        Start-FastLlmServer -Plan $plan -CatalogPath $catalogPath -InstallRoot $temp -VulkanBarMitigation off | Out-Null
        Check ($null -eq $state.supervisorPolicy -or $state.supervisorPolicy -eq '') 'an explicit start parameter overrides the module-level policy'
        & $module { $script:FastLlmVulkanBarMitigationPolicy = 'bogus' }
        $caught=$false;$state.events.Clear()
        try{Start-FastLlmServer -Plan $plan -CatalogPath $catalogPath -InstallRoot $temp | Out-Null}catch{$caught=$_.Exception.Message -match 'Unknown Vulkan Resizable BAR mitigation'}
        Check ($caught -and $state.events.Count -eq 0) 'an invalid module-level policy fails before any hashing or launch'
    } finally { & $module { $script:FastLlmVulkanBarMitigationPolicy = 'off' } }
    $state.events.Clear()

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
    # Final review M9: a measured (recipe-origin) plan whose start re-plan lost the card identity or the recipe must re-plan, never run as estimated.
    $savedRecipe=$plan.recipe;$savedFreshRecipe=$fresh.recipe
    $plan.recipe=[pscustomobject]@{id='r1';origin='bitworks';label='Measured by Bitworks on this card'}
    $fresh.recipe=[pscustomobject]@{id=$null;origin='estimated';label='Estimated for your card'}
    $state.events.Clear();$reason=$null;$message=''
    try{Start-FastLlmServer -Plan $plan -CatalogPath $catalogPath -InstallRoot $temp | Out-Null}catch{$reason=$_.Exception.Data['FastLlmReason'];$message=$_.Exception.Message}
    Check ($reason -eq 'PlanChanged' -and -not $state.events.Contains('supervisor') -and $message -like "*measured recipe 'r1'*estimated*") 'a recipe plan that re-plans as estimated raises PlanChanged with the reason and never launches'
    $fresh.recipe=[pscustomobject]@{id='r2';origin='bitworks';label='Measured by Bitworks on this card'}
    $state.events.Clear();$reason=$null;$message=''
    try{Start-FastLlmServer -Plan $plan -CatalogPath $catalogPath -InstallRoot $temp | Out-Null}catch{$reason=$_.Exception.Data['FastLlmReason'];$message=$_.Exception.Message}
    Check ($reason -eq 'PlanChanged' -and -not $state.events.Contains('supervisor') -and $message -like "*'r1'*'r2'*") 'a recipe plan that re-plans to another recipe raises PlanChanged'
    $fresh.recipe=[pscustomobject]@{id='r1';origin='bitworks';label='Measured by Bitworks on this card'}
    $state.events.Clear();$reason=$null
    try{Start-FastLlmServer -Plan $plan -CatalogPath $catalogPath -InstallRoot $temp | Out-Null}catch{$reason=$_.Exception.Data['FastLlmReason']}
    Check ($null -eq $reason -and $state.events.Contains('supervisor')) 'a recipe plan that re-plans to the same recipe launches'
    $plan.recipe=[pscustomobject]@{id=$null;origin='estimated';label='Estimated for your card'}
    $fresh.recipe=[pscustomobject]@{id=$null;origin='estimated';label='Estimated for your card'}
    $state.events.Clear();$reason=$null
    try{Start-FastLlmServer -Plan $plan -CatalogPath $catalogPath -InstallRoot $temp | Out-Null}catch{$reason=$_.Exception.Data['FastLlmReason']}
    Check ($null -eq $reason -and $state.events.Contains('supervisor')) 'an estimated plan that re-plans as estimated is unaffected'
    $plan.recipe=$savedRecipe;$fresh.recipe=$savedFreshRecipe;$state.events.Clear()

    $state.hash=$false;$state.events.Clear();$reason=$null
    try{Start-FastLlmServer -Plan $plan -CatalogPath $catalogPath -InstallRoot $temp | Out-Null}catch{$reason=$_.Exception.Data['FastLlmReason']}
    Check ($reason -eq 'ModelNeedsProvisioning' -and ($state.events -join ',') -eq 'hash') 'integrity failure stops before probe or launch'
    $state.hash=$true;$state.consent=$false;$state.events.Clear();$caught=$false
    try{Start-FastLlmServer -Plan $plan -CatalogPath $catalogPath -InstallRoot $temp | Out-Null}catch{$caught=$_.Exception.Message -match 'consent'}
    Check ($caught -and -not $state.events.Contains('supervisor')) 'missing consent cannot reach native launch'
    $state.consent=$true

    # Engine component plans (Task 3): the verified component executable is what runs; a missing component is a typed failure, with no install and no fallback.
    $shippedComponents=@(Get-FastLlmComponents -ComponentsPath (Join-Path $root 'config/components.json'))
    $componentEntry=@($shippedComponents | Where-Object { [string]$_.id -ceq 'llama.cpp-b10698-vulkan' })[0]
    $componentExe=& $module { param($R,$L) Join-FastLlmContainedPath -Root $R -Child $L -Label 'Engine component executable path' } (Get-FastLlmComponentRoot -InstallRoot $temp -Component $componentEntry) ([string]$componentEntry.entryPoint)
    $componentPlan=$plan | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $componentPlan.enginePath=$componentExe
    $componentPlan | Add-Member -NotePropertyName engineComponentId -NotePropertyValue 'llama.cpp-b10698-vulkan'
    $freshComponent=$componentPlan | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $savedFresh=$state.fresh;$state.fresh=$freshComponent
    $state.componentOk=$false;$state.events.Clear();$code=$null;$message=''
    try{Start-FastLlmServer -Plan $componentPlan -CatalogPath $catalogPath -InstallRoot $temp | Out-Null}catch{$code=$_.Exception.Data['FastLlmFailureCode'];$message=$_.Exception.Message}
    Check ($code -ceq 'needs-setup-component-missing' -and $message -like '*llama.cpp-b10698-vulkan*' -and ($state.events -join ',') -ceq 'component-check') 'a component plan whose component is not installed fails typed, naming it, before any hashing, probe, install or launch'
    $state.componentOk=$true;$state.events.Clear();$state.observed=$null
    $result=Start-FastLlmServer -Plan $componentPlan -CatalogPath $catalogPath -InstallRoot $temp
    Check ($result -eq 0 -and $state.events.Contains('supervisor') -and -not $state.events.Contains('INSTALL-COMPONENT') -and $state.observed.enginePath -ceq $componentExe) 'a component plan with an installed component launches on the component executable, with no install call'
    $wrongExe=$componentPlan | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $wrongExe.enginePath=$plan.enginePath
    $state.events.Clear();$caught=$false
    try{Start-FastLlmServer -Plan $wrongExe -CatalogPath $catalogPath -InstallRoot $temp | Out-Null}catch{$caught=$_.Exception.Message -match 'does not match the verified installed engine'}
    Check ($caught -and -not $state.events.Contains('supervisor')) 'a component plan that points at the built-in engine instead is refused before launch'
    $state.fresh=$savedFresh;$state.componentOk=$true;$state.events.Clear()

    # ---- C3 Task 3: a HIP component plan. M7 start order: no built-in engine check and no catalog asset check; every component in the chain verified (Full), the first
    # failure named; the resolved backend must equal the plan backend; device binding enforce is refused before anything runs. ----
    $hipEngineEntry=@($shippedComponents | Where-Object { [string]$_.id -ceq 'llama.cpp-hip-b11658' })[0]
    $hipExe=& $module { param($R,$L) Join-FastLlmContainedPath -Root $R -Child $L -Label 'Engine component executable path' } (Get-FastLlmComponentRoot -InstallRoot $temp -Component $hipEngineEntry) ([string]$hipEngineEntry.entryPoint)
    $hipPlan=$plan | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $hipPlan.enginePath=$hipExe;$hipPlan.backend='hip'
    $hipPlan | Add-Member -NotePropertyName engineComponentId -NotePropertyValue 'llama.cpp-hip-b11658'
    $hipPlan | Add-Member -NotePropertyName runtimeRoots -NotePropertyValue @('C:\rt\bin')
    $freshHip=$hipPlan | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $state.fresh=$freshHip;$state.componentOk=$true;$state.failComponent='';$state.events.Clear();$state.componentCalls.Clear();$state.observed=$null;$engineChecksBefore=$state.engineChecks
    $result=Start-FastLlmServer -Plan $hipPlan -CatalogPath $catalogPath -InstallRoot $temp
    Check ($result -eq 0 -and $state.events.Contains('supervisor') -and $state.observed.backend -ceq 'hip' -and $state.observed.enginePath -ceq $hipExe) 'a HIP component plan launches on the component executable with backend hip, although the catalog rocm asset is disabled'
    Check ($state.engineChecks -eq $engineChecksBefore) 'a HIP component plan never runs the built-in engine installation check (M7)'
    Check (($state.componentCalls -join ',') -ceq 'amd-rocm-gfx1100-10.0.0:Full,llama.cpp-hip-b11658:Full') 'a HIP start verifies the runtime and then the engine, each at Depth Full'
    $state.fresh=$savedFresh;$state.events.Clear();$state.componentCalls.Clear();$engineChecksBefore=$state.engineChecks
    Start-FastLlmServer -Plan $plan -CatalogPath $catalogPath -InstallRoot $temp | Out-Null
    Check ($state.engineChecks -eq $engineChecksBefore + 1) 'positive control: a built-in (non-component) plan still runs the built-in engine installation check exactly once'
    foreach($missingCase in @(@{id='amd-rocm-gfx1100-10.0.0';expected='amd-rocm-gfx1100-10.0.0'},@{id='llama.cpp-hip-b11658';expected='llama.cpp-hip-b11658'})){
        $state.fresh=$freshHip;$state.failComponent=$missingCase.id;$state.events.Clear();$state.componentCalls.Clear();$engineChecksBefore=$state.engineChecks;$code=$null;$message='';$named=$null;$unavailableNamed=$null
        try{Start-FastLlmServer -Plan $hipPlan -CatalogPath $catalogPath -InstallRoot $temp | Out-Null}catch{$code=$_.Exception.Data['FastLlmFailureCode'];$message=$_.Exception.Message;$named=$_.Exception.Data['FastLlmComponentId'];$unavailableNamed=$_.Exception.Data['FastLlmUnavailableComponentId']}
        Check ($code -ceq 'needs-setup-component-missing' -and $named -ceq 'llama.cpp-hip-b11658' -and $unavailableNamed -ceq $missingCase.expected -and $message -like "*'$($missingCase.expected)'*" -and -not $state.events.Contains('supervisor') -and -not $state.events.Contains('hash') -and -not $state.events.Contains('INSTALL-COMPONENT') -and $state.engineChecks -eq $engineChecksBefore) "a HIP start whose $($missingCase.id) fails its check is needs-setup-component-missing naming it (the install target stays the engine), before any hash, install, probe or launch"
    }
    $state.failComponent='amd-rocm-gfx1100-10.0.0';$state.componentCalls.Clear()
    try{Start-FastLlmServer -Plan $hipPlan -CatalogPath $catalogPath -InstallRoot $temp | Out-Null}catch{}
    Check (($state.componentCalls -join ',') -ceq 'amd-rocm-gfx1100-10.0.0:Full') 'the chain stops at the first failing component (the runtime), so the engine is not reported as the cause'
    $state.failComponent=''
    # Backend mismatch: the plan backend must equal the resolved engine component's backend, in both directions.
    foreach($mismatch in @(@{label='a Vulkan plan on the HIP engine component';backend='Vulkan';component='llama.cpp-hip-b11658'},@{label='a hip plan on the Vulkan engine component';backend='hip';component='llama.cpp-b10698-vulkan'})){
        $mismatchPlan=$componentPlan | ConvertTo-Json -Depth 12 | ConvertFrom-Json
        $mismatchPlan.backend=$mismatch.backend;$mismatchPlan.engineComponentId=$mismatch.component
        $mismatchEntry=@($shippedComponents | Where-Object { [string]$_.id -ceq $mismatch.component })[0]
        $mismatchPlan.enginePath=& $module { param($R,$L) Join-FastLlmContainedPath -Root $R -Child $L -Label 'Engine component executable path' } (Get-FastLlmComponentRoot -InstallRoot $temp -Component $mismatchEntry) ([string]$mismatchEntry.entryPoint)
        $state.fresh=$mismatchPlan;$state.events.Clear();$code=$null
        try{Start-FastLlmServer -Plan $mismatchPlan -CatalogPath $catalogPath -InstallRoot $temp | Out-Null}catch{$code=$_.Exception.Data['FastLlmFailureCode']}
        Check ($code -ceq 'recipe-engine-backend-mismatch' -and -not $state.events.Contains('supervisor') -and -not $state.events.Contains('hash')) "$($mismatch.label) is refused as recipe-engine-backend-mismatch before any hash or launch"
    }
    # A hip plan with no engine component is not a thing: it stays refused (and never reaches the catalog rocm asset).
    $bareHip=$plan | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $bareHip.backend='hip';$state.fresh=$bareHip;$state.events.Clear();$caught=$false
    try{Start-FastLlmServer -Plan $bareHip -CatalogPath $catalogPath -InstallRoot $temp | Out-Null}catch{$caught=$_.Exception.Message -match "unknown backend 'hip'"}
    Check ($caught -and -not $state.events.Contains('supervisor')) 'a hip plan without an engine component is refused'
    # Device binding is Vulkan-only: enforce is refused before any check, record and off are not.
    $state.fresh=$freshHip;$state.events.Clear();$state.componentCalls.Clear();$engineChecksBefore=$state.engineChecks;$code=$null;$reason=$null;$message=''
    try{Start-FastLlmServer -Plan $hipPlan -CatalogPath $catalogPath -InstallRoot $temp -DeviceBinding enforce | Out-Null}catch{$code=$_.Exception.Data['FastLlmFailureCode'];$reason=$_.Exception.Data['FastLlmReason'];$message=$_.Exception.Message}
    Check ($code -ceq 'device-binding-unsupported-backend' -and $reason -ceq 'DeviceBindingFailed' -and $message -like 'device-binding-unsupported-backend:*' -and $state.events.Count -eq 0 -and $state.componentCalls.Count -eq 0 -and $state.engineChecks -eq $engineChecksBefore) '-DeviceBinding enforce on a HIP plan is device-binding-unsupported-backend (never recovered), before any verification or launch'
    foreach($allowed in @('record','off')){
        $state.events.Clear();$state.observed=$null;$state.supervisorBinding=$null
        $allowedResult=Start-FastLlmServer -Plan $hipPlan -CatalogPath $catalogPath -InstallRoot $temp -DeviceBinding $allowed
        Check ($allowedResult -eq 0 -and $state.events.Contains('supervisor')) "-DeviceBinding $allowed on a HIP plan still starts"
    }
    $state.fresh=$savedFresh;$state.componentOk=$true;$state.failComponent='';$state.events.Clear()

    # ================= fast-llm.ps1 start -NoDownload: every acquisition path is blocked with a typed failure code =================
    # The real 'start' branch of fast-llm.ps1 is extracted from its AST and run with every I/O boundary replaced by a recorder, so no
    # Install-*, download or network seam can be reached unnoticed (the same technique as ui-flow-tests for the install branch).
    $cliTokens=$null;$cliErrors=$null
    $cliTree=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'fast-llm.ps1'),[ref]$cliTokens,[ref]$cliErrors)
    Check (@($cliErrors).Count -eq 0) 'fast-llm.ps1 parses'
    $cliSwitch=@($cliTree.FindAll({param($node) $node -is [Management.Automation.Language.SwitchStatementAst]},$true))[0]
    $startClause=@($cliSwitch.Clauses | Where-Object { $_.Item1.Extent.Text -ceq "'start'" })[0]
    $startText=$startClause.Item2.Extent.Text
    $startBranch=[scriptblock]::Create($startText.Substring(1,$startText.Length-2))
    $cliSource=[IO.File]::ReadAllText((Join-Path $root 'fast-llm.ps1'))
    Check ($cliSource.Contains('[switch] $NoDownload') -and $cliSource.Contains("-NoDownload is supported only by a live start.")) 'fast-llm.ps1 declares -NoDownload and refuses it outside a live start'

    $ndRoot=Join-Path $temp 'nodownload'
    New-Item -ItemType Directory -Path $ndRoot -Force | Out-Null
    $ndModel=Join-Path $ndRoot 'model.gguf'
    $script:nd=@{log=(New-Object 'Collections.Generic.List[string]');prereq=$true;engine=$true;modelExists=$true;consent=$true;startQueue=(New-Object 'Collections.Generic.Queue[object]');recovery=$true;planCalls=0;requestedModelIds=(New-Object 'Collections.Generic.List[string]');planFailure=$null}
    function Reset-Nd { $script:nd.log.Clear();$script:nd.prereq=$true;$script:nd.engine=$true;$script:nd.consent=$true;$script:nd.startQueue.Clear();$script:nd.recovery=$true;$script:nd.planCalls=0;$script:nd.requestedModelIds.Clear();$script:nd.planFailure=$null
        if(Test-Path -LiteralPath $ndModel){Remove-Item -LiteralPath $ndModel -Force};Set-Content -LiteralPath $ndModel -Value 'x';$script:nd.modelExists=$true }
    function Get-FastLlmWindowsPrerequisiteStatus { $script:nd.log.Add('prerequisites');return [pscustomobject]@{applicable=$true;ready=$script:nd.prereq} }
    function Get-FastLlmCatalog { param($CatalogPath) $script:nd.log.Add('catalog');return [pscustomobject]@{engine=[pscustomobject]@{version='b-test';assets=[pscustomobject]@{vulkan=[pscustomobject]@{enabled=$true};rocm=[pscustomobject]@{enabled=$false}}}} }
    function Test-FastLlmEngineInstallation { param($InstallRoot,$EngineVersion,$BackendKey,$Asset) $script:nd.log.Add('engine-check');return $script:nd.engine }
    function Get-FastLlmHardware { param($CatalogPath,$InstallRoot) $script:nd.log.Add('hardware');return [pscustomobject]@{} }
    function Get-FastLlmPlan { param($Hardware,$CatalogPath,$Profile,$InstallRoot,$ModelId,$ContextSize,[switch]$AllowExperimentalModel,$RecipesPath,$GpuVariantsPath,$RecipeId)
        $script:nd.log.Add('plan');$script:nd.planCalls++;$script:nd.requestedModelIds.Add([string]$ModelId)
        if($script:nd.planFailure){throw $script:nd.planFailure}
        return [pscustomobject]@{modelPath=$ndModel;model=[pscustomobject]@{id='nd-model'}} }
    function Write-FastLlmPlan { param($Plan) }
    function Test-FastLlmModelConsentReceipt { param($Model,$InstallRoot) $script:nd.log.Add('consent-check');return $script:nd.consent }
    function Install-FastLlmModel { param($Plan,$InstallRoot,$AcceptModelLicense,$Unattended) $script:nd.log.Add('INSTALL-MODEL');Set-Content -LiteralPath $ndModel -Value 'x';$script:nd.modelExists=$true;return $ndModel }
    function Install-FastLlmEngines { param($CatalogPath,$InstallRoot) $script:nd.log.Add('INSTALL-ENGINE') }
    function Install-FastLlmComponent { param($ComponentsPath,$ComponentId,$InstallRoot,$AcceptLicense,$Unattended) $script:nd.log.Add('INSTALL-COMPONENT');return $null }
    function Save-FastLlmVerifiedFile { param($Url,$Destination,$Sha256,$SizeBytes) $script:nd.log.Add('NETWORK-SAVE') }
    function Invoke-WebRequest { $script:nd.log.Add('NETWORK-WEB') }
    function Invoke-RestMethod { $script:nd.log.Add('NETWORK-REST') }
    function Get-FastLlmRecoveryPlan { param($Hardware,$CatalogPath,$InstallRoot,$Profile,$FailedModelId,$RequestedModelId,$ContextSize)
        $script:nd.log.Add('recovery-plan');if($script:nd.recovery){return [pscustomobject]@{model=[pscustomobject]@{id='other-model'}}};return $null }
    function Start-FastLlmServer { param($Plan,$CatalogPath,$InstallRoot,$LoadTimeoutSeconds,$VulkanBarMitigation,[switch]$ThroughputCanary,$DeviceBinding,[switch]$SelfTest)
        $script:nd.log.Add('start');$script:nd.startBound=@($PSBoundParameters.Keys | Sort-Object);$script:nd.startBar=$VulkanBarMitigation
        if($script:nd.startQueue.Count -gt 0){
            $next=$script:nd.startQueue.Dequeue()
            if($next -is [string]){$e=New-Object InvalidOperationException('simulated '+$next);$e.Data['FastLlmReason']=$next;throw $e}
            if($next -is [hashtable]){$e=New-Object InvalidOperationException('simulated '+$next.reason);$e.Data['FastLlmReason']=$next.reason;$e.Data['FastLlmFailureCode']=$next.code;throw $e}
            return [int]$next
        }
        return 0 }
    $script:ndDeviceBinding='off'
    $script:ndUnattended=$true
    $script:ndSkipSelfTest=$true   # these start tests are not about serving quality: the self-test is skipped unless a check opts in
    function Invoke-NdStart([bool]$NoDownloadSwitch) {
        $DryRun=$false;$InstallRoot=$ndRoot;$Profile='balanced';$ModelId='nd-model';$ContextSize=0;$AllowExperimentalModel=$false;$LoadTimeoutSeconds=30
        $AcceptModelLicense=$false;$Unattended=$script:ndUnattended;$ThroughputCanary=$false;$SkipSelfTest=[switch]$script:ndSkipSelfTest;$VulkanBarMitigation='auto';$DeviceBinding=$script:ndDeviceBinding;$NoDownload=[switch]$NoDownloadSwitch
        $selectionOptions=@{ModelId=$ModelId;ContextSize=0;AllowExperimentalModel=$false}
        $failure=$null
        try { & $startBranch | Out-Null } catch { $failure=$_.Exception }
        return $failure
    }
    function Get-NdCode($Failure) { if($null -eq $Failure){return $null};return $Failure.Data['FastLlmFailureCode'] }
    function Test-NdNoAcquisition { return (@($script:nd.log | Where-Object { $_ -cmatch '^(INSTALL|NETWORK)' }).Count -eq 0) }

    # The install action (not start) is the only place a missing engine component is installed, and never on a dry run or unattended.
    $installClause=@($cliSwitch.Clauses | Where-Object { $_.Item1.Extent.Text -ceq "'install'" })[0]
    $installText=$installClause.Item2.Extent.Text
    Check ($installText.Contains("'needs-setup-component-missing'") -and $installText.Contains('Install-FastLlmComponent') -and $installText.Contains('$DryRun -or $Unattended') -and -not $startText.Contains('Install-FastLlmComponent')) 'only the install action can install a missing engine component (not on a dry run, not unattended); start never does'

    # -- blocked paths: a typed code, never RuntimeCheckFailed, and no Install-*/network seam is reached
    Reset-Nd; $script:nd.prereq=$false
    $f=Invoke-NdStart $true
    Check ((Get-NdCode $f) -ceq 'needs-setup-prerequisite-missing' -and $f.Data['FastLlmReason'] -cne 'RuntimeCheckFailed' -and (Test-NdNoAcquisition) -and -not $script:nd.log.Contains('hardware') -and -not $script:nd.log.Contains('start')) '-NoDownload: a missing runtime prerequisite is needs-setup-prerequisite-missing before any probe or start'
    Reset-Nd; $script:nd.engine=$false
    $f=Invoke-NdStart $true
    Check ((Get-NdCode $f) -ceq 'needs-setup-engine-missing' -and (Test-NdNoAcquisition) -and -not $script:nd.log.Contains('hardware') -and -not $script:nd.log.Contains('start')) '-NoDownload: a missing engine is needs-setup-engine-missing and Install-FastLlmEngines is never reached'
    Reset-Nd; Remove-Item -LiteralPath $ndModel -Force; $script:nd.modelExists=$false
    $f=Invoke-NdStart $true
    Check ((Get-NdCode $f) -ceq 'needs-setup-model-missing' -and (Test-NdNoAcquisition) -and -not $script:nd.log.Contains('start') -and -not $script:nd.log.Contains('recovery-plan')) '-NoDownload: a missing model file is needs-setup-model-missing, with no Install-FastLlmModel and no start'
    Reset-Nd; $script:nd.consent=$false
    $f=Invoke-NdStart $true
    Check ((Get-NdCode $f) -ceq 'needs-setup-consent-missing' -and (Test-NdNoAcquisition) -and -not $script:nd.log.Contains('start')) '-NoDownload: a present model without a consent receipt is needs-setup-consent-missing (no provisioning)'
    Reset-Nd; $script:nd.startQueue.Enqueue('ModelNeedsProvisioning')
    $f=Invoke-NdStart $true
    Check ((Get-NdCode $f) -ceq 'needs-setup-model-invalid' -and (Test-NdNoAcquisition) -and @($script:nd.log | Where-Object { $_ -ceq 'start' }).Count -eq 1 -and $script:nd.planCalls -eq 1) '-NoDownload: a model that fails verification inside start is needs-setup-model-invalid; the repair download path (Install-FastLlmModel) is not reached and there is no re-plan'
    Reset-Nd; $script:nd.startQueue.Enqueue('RuntimeCheckFailed')
    $f=Invoke-NdStart $true
    Check ($f -and $f.Data['FastLlmReason'] -ceq 'RuntimeCheckFailed' -and -not $script:nd.log.Contains('recovery-plan') -and (Test-NdNoAcquisition) -and @($script:nd.log | Where-Object { $_ -ceq 'start' }).Count -eq 1 -and $script:nd.requestedModelIds.Count -eq 1) '-NoDownload: a genuine runtime failure never triggers model recovery or substitution (one start, no recovery plan)'
    Reset-Nd; $script:nd.startQueue.Enqueue('PlanChanged')
    $f=Invoke-NdStart $true
    Check ($null -eq $f -and @($script:nd.log | Where-Object { $_ -ceq 'start' }).Count -eq 2 -and (Test-NdNoAcquisition) -and @($script:nd.requestedModelIds | Where-Object { $_ -cne 'nd-model' }).Count -eq 0) '-NoDownload: a PlanChanged re-plan is not an acquisition and keeps the pinned -ModelId'
    Reset-Nd
    $f=Invoke-NdStart $true
    Check ($null -eq $f -and (Test-NdNoAcquisition) -and @($script:nd.log | Where-Object { $_ -ceq 'start' }).Count -eq 1) '-NoDownload: a healthy start still starts exactly once'
    # A recipe whose engine component is not installed: the plan raises needs-setup-component-missing; a start never installs it and never falls back.
    foreach($componentCase in @(@{label='-NoDownload';noDownload=$true;unattended=$true},@{label='default';noDownload=$false;unattended=$false},@{label='-Unattended';noDownload=$false;unattended=$true})){
        Reset-Nd
        $componentFailure=New-Object InvalidOperationException('needs-setup-component-missing: The engine component test-engine-1 is not installed.')
        $componentFailure.Data['FastLlmFailureCode']='needs-setup-component-missing';$componentFailure.Data['FastLlmComponentId']='test-engine-1'
        $script:nd.planFailure=$componentFailure
        $savedUnattended=$script:ndUnattended;$script:ndUnattended=$componentCase.unattended
        $f=Invoke-NdStart $componentCase.noDownload
        $script:ndUnattended=$savedUnattended
        Check ((Get-NdCode $f) -ceq 'needs-setup-component-missing' -and $f.Message -like '*test-engine-1*' -and (Test-NdNoAcquisition) -and -not $script:nd.log.Contains('start') -and -not $script:nd.log.Contains('recovery-plan') -and $script:nd.planCalls -eq 1) "start ($($componentCase.label)): a missing engine component is needs-setup-component-missing with no install call, no start, no recovery and no built-in fallback"
    }

    # -- W03 Phase A: the CLI passes -DeviceBinding only when it is not off (an off start calls Start-FastLlmServer exactly as before)
    Reset-Nd
    $f=Invoke-NdStart $false
    Check ($null -eq $f -and ($script:nd.startBound -join ',') -ceq 'CatalogPath,InstallRoot,LoadTimeoutSeconds,Plan,VulkanBarMitigation' -and $script:nd.startBar -ceq 'auto') 'default start: Start-FastLlmServer is called without -DeviceBinding and always forwards -VulkanBarMitigation auto'
    Reset-Nd; $script:ndSkipSelfTest=$false
    $f=Invoke-NdStart $false
    Check ($null -eq $f -and ($script:nd.startBound -join ',') -ceq 'CatalogPath,InstallRoot,LoadTimeoutSeconds,Plan,SelfTest,VulkanBarMitigation') 'start without -SkipSelfTest: Start-FastLlmServer receives -SelfTest'
    $script:ndSkipSelfTest=$true
    Reset-Nd; $script:ndDeviceBinding='record'
    $f=Invoke-NdStart $false
    Check ($null -eq $f -and ($script:nd.startBound -join ',') -ceq 'CatalogPath,DeviceBinding,InstallRoot,LoadTimeoutSeconds,Plan,VulkanBarMitigation') '-DeviceBinding record: Start-FastLlmServer receives it'
    # -- W03 Phase A enforce: the CLI passes it on, and a DeviceBindingFailed failure is NEVER retried, re-planned, recovered or model-swapped
    foreach($recoveryAllowed in @($false,$true)){
        Reset-Nd; $script:ndDeviceBinding='enforce'; $script:nd.recovery=$recoveryAllowed; $script:nd.startQueue.Enqueue('DeviceBindingFailed')
        $f=Invoke-NdStart $false
        Check ($null -ne $f -and $f.Data['FastLlmReason'] -ceq 'DeviceBindingFailed' -and ($script:nd.startBound -join ',') -ceq 'CatalogPath,DeviceBinding,InstallRoot,LoadTimeoutSeconds,Plan,VulkanBarMitigation' -and @($script:nd.log | Where-Object { $_ -ceq 'start' }).Count -eq 1 -and -not $script:nd.log.Contains('recovery-plan') -and $script:nd.planCalls -eq 1 -and $script:nd.requestedModelIds.Count -eq 1 -and (Test-NdNoAcquisition)) "-DeviceBinding enforce: a DeviceBindingFailed start is rethrown after exactly one start (no retry, no re-plan, no recovery plan, no model swap; recovery available: $recoveryAllowed)"
    }
    Reset-Nd; $script:ndDeviceBinding='enforce'; $script:nd.startQueue.Enqueue('DeviceBindingFailed')
    $f=Invoke-NdStart $true
    Check ($null -ne $f -and $f.Data['FastLlmReason'] -ceq 'DeviceBindingFailed' -and @($script:nd.log | Where-Object { $_ -ceq 'start' }).Count -eq 1 -and -not $script:nd.log.Contains('recovery-plan') -and (Test-NdNoAcquisition)) '-DeviceBinding enforce with -NoDownload: the DeviceBindingFailed failure is rethrown unchanged'
    # N-1: a failure that carries a device-binding-* code is never recovered, even if its reason is the recoverable RuntimeCheckFailed
    # (this is the only thing that stops the CLI guard being dead code: delete the code half of the guard and these fail).
    foreach($recoveryAllowed in @($false,$true)){
        Reset-Nd; $script:ndDeviceBinding='enforce'; $script:nd.recovery=$recoveryAllowed; $script:nd.startQueue.Enqueue(@{reason='RuntimeCheckFailed';code='device-binding-post-load-mismatch'})
        $f=Invoke-NdStart $false
        Check ($null -ne $f -and $f.Data['FastLlmReason'] -ceq 'RuntimeCheckFailed' -and $f.Data['FastLlmFailureCode'] -ceq 'device-binding-post-load-mismatch' -and @($script:nd.log | Where-Object { $_ -ceq 'start' }).Count -eq 1 -and -not $script:nd.log.Contains('recovery-plan') -and $script:nd.planCalls -eq 1 -and $script:nd.requestedModelIds.Count -eq 1 -and (Test-NdNoAcquisition)) "a RuntimeCheckFailed carrying a device-binding-* code is rethrown after one start with no recovery (recovery available: $recoveryAllowed)"
    }
    Reset-Nd; $script:ndDeviceBinding='enforce'; $script:nd.startQueue.Enqueue(@{reason='RuntimeCheckFailed';code='startup-or-runtime-check-failed'})
    $f=Invoke-NdStart $false
    Check ($null -eq $f -and $script:nd.log.Contains('recovery-plan')) 'a RuntimeCheckFailed with an ordinary failure code is still recovered'
    Check ($cliSource.Contains("-clike 'device-binding-*'") -and $cliSource.Contains('$DeviceBinding = $DeviceBinding.ToLowerInvariant()')) 'fast-llm.ps1 rethrows on a device-binding-* failure code and normalises -DeviceBinding to lowercase'
    Reset-Nd; $script:ndDeviceBinding='enforce'; $script:nd.startQueue.Enqueue('RuntimeCheckFailed')
    $f=Invoke-NdStart $false
    Check ($null -eq $f -and $script:nd.log.Contains('recovery-plan')) '-DeviceBinding enforce: an ordinary RuntimeCheckFailed is still recovered exactly as before'
    $script:ndDeviceBinding='off'
    Check ($cliSource.Contains("[ValidateSet('off', 'record', 'enforce')]") -and $cliSource.Contains("[string] `$DeviceBinding = 'off'") -and $cliSource.Contains('-DeviceBinding is supported only by a live start.') -and $cliSource.Contains("`$PSBoundParameters.ContainsKey('DeviceBinding')")) 'fast-llm.ps1 declares -DeviceBinding off|record|enforce and refuses it outside a live start'

    # -- the default start (no switch) is unchanged: it still provisions and recovers exactly as before
    Reset-Nd; Remove-Item -LiteralPath $ndModel -Force; $script:nd.modelExists=$false
    $f=Invoke-NdStart $false
    Check ($null -eq $f -and ($script:nd.log -join ',') -ceq 'hardware,plan,INSTALL-MODEL,hardware,plan,consent-check,start') 'default start, model missing: provisions through Install-FastLlmModel, re-plans, then starts (no prerequisite or engine pre-check added)'
    Reset-Nd; $script:nd.startQueue.Enqueue('ModelNeedsProvisioning')
    $f=Invoke-NdStart $false
    Check ($null -eq $f -and ($script:nd.log -join ',') -ceq 'hardware,plan,consent-check,start,INSTALL-MODEL,hardware,plan,consent-check,start') 'default start, corrupt model: still repaired through Install-FastLlmModel and re-planned'
    Reset-Nd; $script:nd.startQueue.Enqueue('RuntimeCheckFailed')
    $f=Invoke-NdStart $false
    Check ($null -eq $f -and ($script:nd.log -join ',') -ceq 'hardware,plan,consent-check,start,hardware,recovery-plan,hardware,plan,consent-check,start' -and $script:nd.requestedModelIds[$script:nd.requestedModelIds.Count-1] -ceq 'other-model') 'default start, runtime failure: model recovery and substitution still happen'
    Reset-Nd; $script:nd.consent=$false
    $f=Invoke-NdStart $false
    Check ($null -ne $f -and $null -eq (Get-NdCode $f) -and $script:nd.log.Contains('INSTALL-MODEL')) 'default start, no consent receipt: still provisions (and the failure carries no typed -NoDownload code)'

    # -- update-check / update: argument validation and the cached notice wiring (static; no PowerShell can run a real start here)
    $statusClause=@($cliSwitch.Clauses | Where-Object { $_.Item1.Extent.Text -ceq "'status'" })[0]
    $updateCheckClause=@($cliSwitch.Clauses | Where-Object { $_.Item1.Extent.Text -ceq "'update-check'" })[0]
    $updateClause=@($cliSwitch.Clauses | Where-Object { $_.Item1.Extent.Text -ceq "'update'" })[0]
    Check ($cliSource.Contains("'stop', 'update-check', 'update', 'components')]") -and $cliSource.Contains('[switch] $Yes') -and $cliSource.Contains("[ValidateSet('stable', 'canary')]") -and $cliSource.Contains('[string] $Channel')) 'fast-llm.ps1 declares update-check, update, -Yes and -Channel stable|canary'
    Check ($cliSource.Contains("-Yes is supported only by update.") -and $cliSource.Contains("-Channel is supported only by update-check and update.") -and $cliSource.Contains("`$PSBoundParameters.ContainsKey('Channel')")) 'fast-llm.ps1 refuses -Yes and -Channel for any other action'
    Check ($cliSource.Contains('$Action -eq ''update'' -and $Unattended -and -not $Yes') -and $cliSource.Contains('update -Unattended requires -Yes')) 'update refuses -Unattended without -Yes before doing anything'
    Check ($cliSource.Contains("FastLlm.Update.ps1") -and -not ([IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.psm1'))).Contains('FastLlm.Update.ps1')) 'FastLlm.Update.ps1 is dot-sourced by fast-llm.ps1 and never by FastLlm.psm1'
    Check ($null -ne $statusClause -and $null -ne $updateCheckClause -and $null -ne $updateClause) 'the status, update-check and update clauses exist'
    Check ($statusClause.Item2.Extent.Text.Contains('Get-FastLlmCachedUpdateNotice') -and $startText.Contains('Get-FastLlmCachedUpdateNotice')) 'start and status print the cached update notice'
    Check (-not $statusClause.Item2.Extent.Text.Contains('Invoke-FastLlmUpdateCheck') -and -not $startText.Contains('Invoke-FastLlmUpdateCheck') -and -not $statusClause.Item2.Extent.Text.Contains('Invoke-FastLlmVerifiedUpdate') -and -not $startText.Contains('Invoke-FastLlmVerifiedUpdate')) 'start and status make no update request'
    Check ($updateCheckClause.Item2.Extent.Text.Contains('Invoke-FastLlmUpdateCheck') -and $updateCheckClause.Item2.Extent.Text.Contains('-Force') -and $updateClause.Item2.Extent.Text.Contains('Invoke-FastLlmVerifiedUpdate') -and $updateClause.Item2.Extent.Text.Contains('exit $updateExit')) 'update-check forces a check and update runs the verified flow with its exit code'
} finally {
    foreach($name in $saved.Keys){& $module {param($N,$B) Set-Item -Path ('Function:script:'+$N) -Value $B} $name $saved[$name]}
    if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}
}
Write-Host "$count start-boundary checks passed. Native calls were replaced; this is not hardware qualification."
