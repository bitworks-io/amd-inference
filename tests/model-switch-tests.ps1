#requires -Version 5.1
# Supervised model switch (opt-in, -AllowSwitch): the request file, the in-supervisor restart and the status block, against the native mock server.
# The REAL start (Start-FastLlmServer), supervisor, request reader and writer, status writer and run log run here. Replaced, as in start-tests:
# the catalog (a small synthetic model list), the planner, the hardware inventory, the engine check and the SHA-256 and consent checks, each of
# which records that it was called. An independent client process plays the user (tests/helpers/switch-client.ps1).
# No Radeon adapter, inference engine or network is needed.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force
$module=Get-Module FastLlm
. (Join-Path $PSScriptRoot 'helpers/SwitchTestWorld.ps1')
$catalog=Join-Path $root 'config/catalog.json'
$enginePath=(Get-Process -Id $PID).Path
$count=0
function Check([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; $script:count++; Write-Host "PASS: $Message" }
function Get-Field($Object,[string]$Name) { if ($null -eq $Object) { return $null }; $p=$Object.PSObject.Properties[$Name]; if ($null -eq $p) { return $null }; return $p.Value }
function Get-FreePort { $l=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$l.Start();$p=$l.LocalEndpoint.Port;$l.Stop();return $p }
function Test-PortFree([int]$Number) { $l=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,$Number);try{$l.Server.ExclusiveAddressUse=$true;$l.Start();return $true}catch{return $false}finally{try{$l.Stop()}catch{}} }
$marker='FLLM-MARKER-SWITCH-7f3a'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('fast-llm-switch-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp -Force | Out-Null

# ---- the test world: models a and b are installed and consented; c is not downloaded; d has the wrong size; e has no consent ----
function New-SwitchWorld([string]$Label,[hashtable]$Modes=@{}) {
    $install=Join-Path $temp $Label
    $models=Join-Path $install 'models'
    New-Item -ItemType Directory -Path $models -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $install 'state') -Force | Out-Null
    $entries=@()
    foreach ($letter in @('a','b','c','d','e')) {
        $id='model-'+$letter
        $file=$id+'.gguf'
        $size=[int64](16+[int][char]$letter)
        if ($letter -cne 'c') { [IO.File]::WriteAllBytes((Join-Path $models $file),(New-Object byte[] $(if($letter -ceq 'd'){5}else{[int]$size}))) }
        $entries+=[ordered]@{ id=$id; file=$file; sizeBytes=$size; sha256=($letter*64); consent=($letter -cne 'e')
            url='https://example.invalid/'+$file; repository='switch-test/'+$id; revision='rev-'+$letter; upstreamModel='upstream/'+$id; upstreamRevision='up-'+$letter
            upstreamLicense='apache-2.0'; upstreamLicenseSha256=('f'*64); artifactLicense='apache-2.0'; contextSize=1024; parallel=1; cacheTypeK='f16'; cacheTypeV='f16' }
        $modeList=@('ok')
        if ($Modes.ContainsKey($id)) { $modeList=@($Modes[$id]) }
        [IO.File]::WriteAllLines((Join-Path $install ($id+'.modes')),[string[]]$modeList)
    }
    $recipes=@(
        [ordered]@{ id='recipe-b'; origin='bitworks'; components=[ordered]@{ engine='llama.cpp-test-vulkan'; model='model-b' } },
        [ordered]@{ id='recipe-x'; origin='community-experimental'; components=[ordered]@{ engine='llama.cpp-test-vulkan'; model='model-b' } }
    )
    $worldPath=Join-Path $install 'world.json'
    [IO.File]::WriteAllText($worldPath,(ConvertTo-Json -InputObject ([ordered]@{ installRoot=$install; models=$entries; recipes=$recipes }) -Depth 6),(New-Object Text.UTF8Encoding($false)))
    return [pscustomobject]@{ root=$install; path=$worldPath; port=(Get-FreePort); models=$models; state=(Join-Path $install 'state') }
}
function Get-ModeStarts($World,[string]$ModelId) {
    $path=Join-Path $World.root ($ModelId+'.modes.starts')
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    return @([IO.File]::ReadAllLines($path) | Where-Object { $_ })
}

# ---- the replaced boundaries (module scope), driven by one state table ----
$st=@{ events=(New-Object 'Collections.Generic.List[string]'); world=$null; enginePath=$enginePath; planCalls=(New-Object 'Collections.Generic.List[object]')
    planFailures=@{}; hashResults=@{}; hashHold=@{}; hashMarker=$null; inventoryHold=$false; stopAtSwitchWrite=$false; snapshots=(New-Object 'Collections.Generic.List[object]'); writes=(New-Object 'Collections.Generic.List[object]')
    lockFree=(New-Object 'Collections.Generic.List[string]'); runs=(New-Object 'Collections.Generic.List[object]'); thinking='auto'; chatPage='off'; serverExtra=@()
    hardwareCalls=0; fixedFree=$null; requiredFree=@{}; needsProbe=@(); planHardware=(New-Object 'Collections.Generic.List[object]'); basisWrites=(New-Object 'Collections.Generic.List[object]'); kv=@{}; requiredFreeLong=@{} }
function Read-StatusText($World) {
    $path=Join-Path $World.state 'status.json'
    for ($attempt=0; $attempt -lt 20; $attempt++) { try { if (Test-Path -LiteralPath $path) { return [IO.File]::ReadAllText($path) } } catch { $null=$_ }; Start-Sleep -Milliseconds 15 }
    return $null
}
function ConvertFrom-StatusText([string]$Text) { if ([string]::IsNullOrWhiteSpace($Text)) { return $null }; $parsed=$Text | ConvertFrom-Json; return $parsed }
# The synthetic plan of one model: the mock server on the scenario's port, its mode taken from the model's mode file at each start.
$st.newPlan={
    param([string]$ModelId,[string]$RecipeId,$Bound)
    $world=$st.world
    $document=Read-FastLlmJson -Path $world.path
    $targetId=$ModelId
    if ($RecipeId) { $targetId=[string](@($document.recipes | Where-Object { [string]$_.id -ceq $RecipeId })[0].components.model) }
    if (-not $targetId) { $targetId='model-a' }
    $model=@($document.models | Where-Object { [string]$_.id -ceq $targetId })[0]
    $thinking='auto'; if ($Bound -and $Bound.ContainsKey('Thinking')) { $thinking=[string]$Bound['Thinking'] }
    $chatPage='off'; if ($Bound -and $Bound.ContainsKey('ChatPage')) { $chatPage=[string]$Bound['ChatPage'] }
    $recipe=[pscustomobject]@{ id=$null; origin='manual'; label='Chosen by you'; evidenceUrl=$null; expected=$null }
    if ($RecipeId) { $recipe=[pscustomobject]@{ id=$RecipeId; origin='bitworks'; label='Measured by Bitworks on this card'; evidenceUrl=$null; expected=$null } }
    $servingProfile=$null
    $kvProfile='default'; if ($Bound -and $Bound.ContainsKey('KvContextProfile')) { $kvProfile=[string]$Bound['KvContextProfile'] }
    $kvSlots=1; if ($Bound -and $Bound.ContainsKey('KvSlots')) { $kvSlots=[int]$Bound['KvSlots'] }
    if ($kvProfile -cne 'default' -or $kvSlots -ne 1) { $servingProfile=[pscustomobject]@{ id=$kvProfile; slots=$kvSlots; contextPerSlot=[int](1024/$kvSlots) } }
    $plan=[pscustomobject]@{
        schemaVersion=1; catalogVersion='switch-test'; hardwareFingerprint='synthetic'; profile='balanced'
        requestedModelId=$ModelId; requestedRecipeId=$(if($RecipeId){$RecipeId}else{$null}); recovered=$false; requestedContextSize=0
        requestedServerPort=[int]$world.port; requestedThinking=$thinking; requestedChatPage=$chatPage; allowExperimentalModel=$false
        backend='Vulkan'; engineVersion='test'; enginePath=$st.enginePath
        selectedAdapters=@([pscustomobject]@{device='Vulkan0'}); model=$model; modelPath=(Join-Path $world.models ([string]$model.file))
        splitMode='none'; tensorSplit=$null; endpoint="http://127.0.0.1:$($world.port)/v1"
        serverArguments=@('-NoLogo','-NoProfile','-File',(Join-Path $PSScriptRoot 'helpers/mock-server.ps1'),'-Port',"$($world.port)",'-ModeFile',(Join-Path $world.root ([string]$model.id+'.modes')),'-Model',[string]$model.id,'-Context','1024')+@($st.serverExtra)
        recipe=$recipe; warnings=@()
    }
    if ($null -ne $servingProfile) { $plan | Add-Member -NotePropertyName servingProfile -NotePropertyValue $servingProfile }
    return $plan
}
$savedSupervisor=& $module { (Get-Command Invoke-FastLlmSupervisedServer).ScriptBlock }
$savedWriteState=& $module { (Get-Command Write-FastLlmState).ScriptBlock }
& $module {
    param($S,$OriginalSupervisor,$OriginalWriteState)
    $script:switchTest=$S
    $script:switchTestEvents=$S.events
    $script:switchTestOriginalSupervisor=$OriginalSupervisor
    $script:switchTestOriginalWriteState=$OriginalWriteState
    # Every status document this process writes, in order (a transient one can be gone before another process looks).
    function script:Write-FastLlmState {
        param([string]$InstallRoot,$State,[string]$FileName='status.json')
        & $script:switchTestOriginalWriteState -InstallRoot $InstallRoot -State $State -FileName $FileName
        if ($FileName -clike 'switch-basis-*') { $script:switchTest.basisWrites.Add(@{ FileName=$FileName; Text=(ConvertTo-Json -InputObject $State -Depth 12 -Compress) }) }
        if ($FileName -ceq 'status.json') {
            $script:switchTest.writes.Add((ConvertTo-Json -InputObject $State -Depth 12 -Compress))
            # A stop that arrives while the old server is shutting down for a switch: the stop request is on disk right after that run's
            # final document, before the run has finished cleaning up.
            if ($script:switchTest.stopAtSwitchWrite -and $State -is [System.Collections.IDictionary] -and $State.Contains('stopReason') -and [string]$State['stopReason'] -ceq 'switch') {
                [IO.File]::WriteAllText((Join-Path $script:switchTest.world.state ('stop-' + [string]$State['runId'])),'')
            }
        }
    }
    # Holds the caller until a stop request file is on disk (at most 10 minutes), so a scenario does not depend on how fast the machine is.
    function script:Wait-SwitchTestStopRequest {
        $world=$script:switchTest.world
        $hold=[Diagnostics.Stopwatch]::StartNew()
        while ($hold.Elapsed.TotalSeconds -lt 600 -and @(Get-ChildItem -LiteralPath $world.state -Filter 'stop-*' -Force -ErrorAction SilentlyContinue).Count -eq 0) { Start-Sleep -Milliseconds 50 }
    }
    function script:Assert-FastLlmWindowsPrerequisites { }
    function script:Test-FastLlmEngineInstallation { return $true }
    function script:Get-FastLlmEngineExecutable { return $script:switchTest.enginePath }
    # A switch never installs, repairs or downloads: these record a call that must not happen.
    function script:Install-FastLlmModel { $script:switchTest.events.Add('INSTALL-MODEL') }
    function script:Save-FastLlmVerifiedFile { $script:switchTest.events.Add('NETWORK-SAVE') }
    function script:Test-FastLlmFileHash {
        param([string]$Path,[string]$Sha256)
        $leaf=[IO.Path]::GetFileNameWithoutExtension($Path)
        $script:switchTest.events.Add('hash:'+$leaf)
        if ($script:switchTest.hashHold.ContainsKey($leaf)) {
            if ($script:switchTest.hashMarker) { [IO.File]::WriteAllText([string]$script:switchTest.hashMarker,'hashing') }
            Wait-SwitchTestStopRequest
        }
        if ($script:switchTest.hashResults.ContainsKey($leaf) -and $script:switchTest.hashResults[$leaf].Count -gt 0) { return [bool]$script:switchTest.hashResults[$leaf].Dequeue() }
        return $true
    }
    function script:Get-FastLlmHardware {
        $script:switchTest.events.Add('inventory')
        $world=$script:switchTest.world
        # What the status document says, and whether the operation lock is free, at the moment a (re)start takes its inventory.
        $text=$null
        try { $text=[IO.File]::ReadAllText((Join-Path $world.state 'status.json')) } catch { $text=$null }
        $script:switchTest.snapshots.Add($text)
        $probe=$null
        try { $probe=Enter-FastLlmOperation -InstallRoot $world.root; $script:switchTest.lockFree.Add('inventory') } catch { $null=$_ } finally { if ($probe) { $probe.Dispose() } }
        if ($script:switchTest.inventoryHold -and @($script:switchTest.events | Where-Object { $_ -ceq 'inventory' }).Count -gt 1) { Wait-SwitchTestStopRequest }
        # A valid reading (it passes Assert-FastLlmHardware). Each call reads a different free number unless a scenario fixes it, so a test can tell
        # which reading a plan (or a saved basis) was built from.
        $script:switchTest.hardwareCalls++
        $free=10000+[int]$script:switchTest.hardwareCalls
        if ($null -ne $script:switchTest.fixedFree) { $free=[int]$script:switchTest.fixedFree }
        return [pscustomobject]@{ schemaVersion=1; source='switch-test'; backend='Vulkan'; enginePath=(Join-Path (Join-Path $world.root 'engines') 'mock-engine')
            adapters=@([pscustomobject]@{ device='Vulkan0'; name='Switch Test Adapter'; vendorId='1002'; vramMiB=24000; freeVramMiB=$free; driverVersion='test'; backend='Vulkan'; isAmd=$true; isIntegrated=$false }) }
    }
    function script:Get-FastLlmPlan {
        param($Hardware,$CatalogPath,$Profile,$InstallRoot,$ModelId,$ContextSize,[switch]$AllowExperimentalModel,$RecipesPath,$GpuVariantsPath,$RecipeId,[switch]$Recovered,[switch]$ResolveFallback,$FallbackFromRecipe,$FallbackReason,[int]$ServerPort=0,[string]$Thinking='auto',[string]$ChatPage='off',[string]$KvContextProfile='default',[int]$KvSlots=1,$KvProfilesPath,[switch]$NoEngineExecution)
        $bound=@{}
        foreach ($key in $PSBoundParameters.Keys) { $bound[$key]=$PSBoundParameters[$key] }
        $script:switchTest.planCalls.Add($bound)
        $label='auto'
        if ($RecipeId) { $label='recipe:'+[string]$RecipeId } elseif ($ModelId) { $label=[string]$ModelId }
        $script:switchTest.events.Add('plan:'+$label)
        if ($script:switchTest.planFailures.ContainsKey($label)) { throw $script:switchTest.planFailures[$label] }
        # What the real planner does with the reading it is given (the same refusals, the same text and codes), so a verdict can be compared with a switch.
        $script:switchTest.planHardware.Add($Hardware)
        if ($ModelId) {
            $entry=@((Read-FastLlmJson -Path $script:switchTest.world.path).models | Where-Object { [string]$_.id -ceq [string]$ModelId })[0]
            if ($null -ne $entry -and $entry.PSObject.Properties['autoEligible'] -and -not [bool]$entry.autoEligible -and -not $AllowExperimentalModel) {
                throw "Model '$ModelId' is experimental and requires -AllowExperimentalModel with an explicit model selection."
            }
            if ($NoEngineExecution -and $script:switchTest.needsProbe -contains [string]$ModelId) {
                throw (New-FastLlmTypedFailure -Code 'fixture-plan-cannot-probe-engine' -Message "Recipe for '$ModelId' runs on the HIP engine, whose devices can only be listed by running it.")
            }
            $neededFree=$null
            if ($script:switchTest.requiredFree.ContainsKey([string]$ModelId)) { $neededFree=[int64]$script:switchTest.requiredFree[[string]$ModelId] }
            if ($KvContextProfile -ceq 'long' -and $script:switchTest.requiredFreeLong.ContainsKey([string]$ModelId)) { $neededFree=[int64]$script:switchTest.requiredFreeLong[[string]$ModelId] }
            if ($null -ne $neededFree -and $neededFree -gt [int64]@($Hardware.adapters)[0].freeVramMiB) {
                $doesNotFit=New-Object InvalidOperationException("Requested model '$ModelId' does not fit the estimated current free-memory budget. No other model was substituted.")
                $doesNotFit.Data['FastLlmFailureCode']='model-does-not-fit'
                throw $doesNotFit
            }
        }
        return (& $script:switchTest.newPlan ([string]$ModelId) ([string]$RecipeId) $bound)
    }
    function script:Invoke-FastLlmSupervisedServer {
        param($Plan,[string]$InstallRoot,[int]$LoadTimeoutSeconds=300,[string]$CatalogPath,[string]$VulkanBarMitigation='off',[switch]$ThroughputCanary,[switch]$SelfTest,[string]$DeviceBinding='off',[int]$IdleStopMinutes=0,[switch]$AllowSwitch,$SwitchContext,$ApiKeyHolder)
        $script:switchTest.events.Add('supervisor:'+[string]$Plan.model.id)
        $run=@{ modelId=[string]$Plan.model.id; bound=(@($PSBoundParameters.Keys | Sort-Object) -join ','); idleStopMinutes=[int]$IdleStopMinutes; selfTest=[bool]$SelfTest; runId=$null; finalText=$null; failed=$false; thinking=[string]$Plan.requestedThinking; plan=$Plan }
        $script:switchTest.runs.Add($run)
        try { return (& $script:switchTestOriginalSupervisor @PSBoundParameters) }
        catch { $run.failed=$true; throw }
        finally {
            # The run's own final document (the supervisor writes it on its way out), read before anything else can replace it.
            try { $run.finalText=[IO.File]::ReadAllText((Join-Path (Join-Path $InstallRoot 'state') 'status.json')) } catch { $null=$_ }
            try { if ($run.finalText) { $run.runId=[string]($run.finalText | ConvertFrom-Json).runId } } catch { $null=$_ }
        }
    }
} $st $savedSupervisor $savedWriteState
function Use-World($World) {
    $st.world=$World
    $st.events.Clear();$st.planCalls.Clear();$st.snapshots.Clear();$st.lockFree.Clear();$st.runs.Clear();$st.writes.Clear()
    $st.planFailures=@{};$st.hashResults=@{};$st.hashHold=@{};$st.hashMarker=$null;$st.inventoryHold=$false;$st.stopAtSwitchWrite=$false;$st.serverExtra=@()
    $st.hardwareCalls=0;$st.fixedFree=$null;$st.requiredFree=@{};$st.needsProbe=@();$st.planHardware.Clear();$st.basisWrites.Clear();$st.kv=@{};$st.requiredFreeLong=@{}
    Install-SwitchTestWorld -Module $module -WorldPath $World.path
}
function Set-BusyWait([double]$Seconds,[int]$PollMilliseconds) { & $module { param($S,$P) $script:FastLlmSwitchBusyWaitSeconds=$S; $script:FastLlmSwitchBusyPollMilliseconds=$P } $Seconds $PollMilliseconds }
function Get-RunLog($World,[string]$RunId) {
    $files=@(Get-ChildItem -LiteralPath (Join-Path $World.state 'logs') -Filter ("run-*-$RunId.jsonl") -ErrorAction SilentlyContinue)
    if ($files.Count -ne 1) { return @() }
    return @([IO.File]::ReadAllLines($files[0].FullName) | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
}
function Get-LogEvents($Lines,[string]$Name) { return @($Lines | Where-Object { [string]$_.event -ceq $Name }) }
# The status documents this process wrote for one run, in order (parsed).
function Get-Writes([string]$RunId) { return @($st.writes | ForEach-Object { $parsedWrite=$_ | ConvertFrom-Json; $parsedWrite } | Where-Object { [string]$_.runId -ceq $RunId }) }
function Get-LogTime($Line) { return ([datetime]$Line.ts).ToUniversalTime() }
function Find-MarkerFiles($World) {
    $hits=@()
    foreach ($file in @(Get-ChildItem -LiteralPath $World.root -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        if ($file.Name -ceq 'steps.json' -or $file.Name -ceq 'client-result.json') { continue }
        $text=[Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($file.FullName))
        if ($text.IndexOf($marker,[StringComparison]::OrdinalIgnoreCase) -ge 0) { $hits+=$file.FullName }
    }
    return @($hits)
}
function New-Step([hashtable]$Wait,[string]$Action,[hashtable]$More=@{}) {
    $step=[ordered]@{ action=$Action }
    if ($Wait) { $step.wait=$Wait }
    foreach ($key in $More.Keys) { $step[$key]=$More[$key] }
    return $step
}
# The stop request files of a world are gone, waited for with a bounded deadline (the supervisor removes its own after the document is final).
function Wait-StopFilesGone($World,[double]$Seconds) {
    $deadline=[Diagnostics.Stopwatch]::StartNew()
    while ($deadline.Elapsed.TotalSeconds -lt $Seconds) {
        if (@(Get-ChildItem -LiteralPath $World.state -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'stop-*' }).Count -eq 0) { return $true }
        Start-Sleep -Milliseconds 50
    }
    return (@(Get-ChildItem -LiteralPath $World.state -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'stop-*' }).Count -eq 0)
}
function Format-RawRequest([hashtable]$Fields) { return (ConvertTo-Json -InputObject $Fields -Compress) }

# Runs one scenario: the operation lock is taken here (as the CLI and the background host do) and held until the start has returned and the
# client has finished. Returns the start's exit code or failure, the client's record, each supervised run and the final status.
# Every step of a scenario has a deadline (a few minutes; a step may carry its own timeoutSeconds). A scenario whose condition never
# comes true - a switch that is refused when it should be accepted, or the other way round - then fails with what was observed,
# and does not hold the suite for an hour.
$script:ScenarioLoadTimeoutSeconds=600
# What a step that asks for a switch may wait through: the supervisor's wait for requests in progress (the module's default), the other
# model's full start (the same load timeout) and a margin for a loaded machine. A scenario that never matches still fails, only later.
$script:SwitchStepTimeoutSeconds=[int]$script:ScenarioLoadTimeoutSeconds+[int](& $module { $script:FastLlmSwitchBusyWaitSeconds })+60
function Get-StepTimeoutSeconds([object[]]$Steps,$Index) {
    $step=@($Steps)[[int]$Index]
    if ($null -ne $step -and $step.Contains('timeoutSeconds')) { return [int]$step['timeoutSeconds'] }
    return [int]$script:SwitchStepTimeoutSeconds
}
function Invoke-SwitchScenario {
    param([string]$Label,$World,[object[]]$Steps,[hashtable]$StartOptions=@{},[switch]$NoAllowSwitch)
    $stepsPath=Join-Path $World.root 'steps.json'
    $resultPath=Join-Path $World.root 'client-result.json'
    [IO.File]::WriteAllText($stepsPath,(ConvertTo-Json -InputObject ([ordered]@{ steps=@($Steps) }) -Depth 8),(New-Object Text.UTF8Encoding($false)))
    $lock=Enter-FastLlmOperation $World.root
    $client=New-Object Diagnostics.Process
    $client.StartInfo.FileName=$enginePath
    $clientCode="& '$((Join-Path $PSScriptRoot 'helpers/switch-client.ps1').Replace("'","''"))' -Root '$($root.Replace("'","''"))' -InstallRoot '$($World.root.Replace("'","''"))' -WorldPath '$($World.path.Replace("'","''"))' -StepsPath '$($stepsPath.Replace("'","''"))' -ResultPath '$($resultPath.Replace("'","''"))' -StepTimeoutSeconds $([int]$script:SwitchStepTimeoutSeconds)"
    $client.StartInfo.Arguments='-NoLogo -NoProfile -OutputFormat Text -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($clientCode))
    $client.StartInfo.UseShellExecute=$false
    $exit=$null;$failure=$null;$clientExited=$false
    try {
        $client.Start() | Out-Null
        $plan=& $st.newPlan 'model-a' '' (@{ Thinking=$st.thinking; ChatPage=$st.chatPage }+$st.kv)
        $arguments=@{ Plan=$plan; CatalogPath=$catalog; InstallRoot=$World.root; LoadTimeoutSeconds=$script:ScenarioLoadTimeoutSeconds }
        if (-not $NoAllowSwitch) { $arguments.AllowSwitch=$true }
        foreach ($key in $StartOptions.Keys) { $arguments[$key]=$StartOptions[$key] }
        try { $exit=Start-FastLlmServer @arguments } catch { $failure=$_.Exception }
        # The client's own bound: every step's deadline, then its final release of whatever is still served (at most five minutes).
        $clientSeconds=360
        foreach ($scenarioStep in @($Steps)) { $stepSeconds=[int]$script:SwitchStepTimeoutSeconds; if ($scenarioStep.Contains('timeoutSeconds')) { $stepSeconds=[int]$scenarioStep['timeoutSeconds'] }; $clientSeconds+=$stepSeconds }
        $clientExited=$client.WaitForExit($clientSeconds*1000)
    } finally {
        if (-not $client.HasExited) { $client.Kill() }
        $client.Dispose()
        $lock.Dispose()
    }
    if ($null -ne $failure) { Write-Host ("Scenario ${Label}: the start raised: " + [regex]::Replace([string]$failure.Message,'[\x00-\x1f\x7f]',' ')) }
    $record=$null
    if (Test-Path -LiteralPath $resultPath) { $record=Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json }
    $outcomes=@();$observations=@()
    if ($null -ne $record) { $outcomes=@($record.steps);$observations=@($record.observations) }
    if ($null -eq $record -or -not $record.completed -or -not $clientExited) {
        Write-Host ("Scenario ${Label}: client steps: " + (@($outcomes | ForEach-Object { "$($_.index):$($_.action):matched=$($_.matched):ms=$($_.ms):timeout=$(Get-StepTimeoutSeconds $Steps $_.index)s:$($_.error)" }) -join ' | '))
        Write-Host ("Scenario ${Label}: observations: " + (@($observations | ForEach-Object { "$($_.ms)ms:$($_.phase)/$($_.modelId)/$($_.stopReason)/" + $(if($_.switch){ConvertTo-Json -InputObject $_.switch -Compress}else{'-'}) }) -join ' | '))
        Write-Host ("Scenario ${Label}: events: " + ($st.events -join ','))
    }
    $finalStatus=ConvertFrom-StatusText (Read-StatusText $World)
    return [pscustomobject]@{ exit=$exit; failure=$failure; completed=[bool]($null -ne $record -and $record.completed -and $clientExited); steps=$outcomes; observations=$observations
        runs=@($st.runs.ToArray()); final=$finalStatus; events=@($st.events.ToArray()); world=$World }
}
function Get-RunFinal($Run) { return (ConvertFrom-StatusText ([string]$Run.finalText)) }
function Get-ReadyObservations($Scenario,[string]$RunId) { return @($Scenario.observations | Where-Object { [string]$_.runId -ceq $RunId -and [string]$_.phase -ceq 'ready' }) }
function Get-Block($Document) { return (Get-Field $Document 'switch') }
function Test-Block($Block,[string]$From,$To,$Result,$FailureCode,[bool]$Pending) {
    if ($null -eq $Block) { return $false }
    $hasPending=[bool]($null -ne $Block.PSObject.Properties['pending'])
    if ($Pending -ne $hasPending) { return $false }
    if ($Pending -and $Block.pending -ne $true) { return $false }
    $expectedNames=@('failureCode','from','result','to'); if ($Pending) { $expectedNames=@('failureCode','from','pending','result','to') }
    if ((@($Block.PSObject.Properties.Name | Sort-Object) -join ',') -cne ($expectedNames -join ',')) { return $false }
    return ([string]$Block.from -ceq $From -and [string]$Block.to -ceq [string]$To -and ($null -eq $To) -eq ($null -eq $Block.to) -and
        [string]$Block.result -ceq [string]$Result -and ($null -eq $Result) -eq ($null -eq $Block.result) -and
        [string]$Block.failureCode -ceq [string]$FailureCode -and ($null -eq $FailureCode) -eq ($null -eq $Block.failureCode))
}
$defaultSupervisorBound='CatalogPath,InstallRoot,LoadTimeoutSeconds,Plan'
$switchSupervisorBound='AllowSwitch,CatalogPath,InstallRoot,LoadTimeoutSeconds,Plan,SwitchContext'
$suitePassed=$false
try {
    # ================= the client waits at least as long as the product may take =================
    # A step that asks for a switch waits through what the product may take for it: the supervisor's wait for requests in progress (the module's
    # default, read before any scenario changes it), then the full start of the other model, which has the same load timeout as the first. A
    # client that gives up sooner judges faster than the product does (a timing race under load).
    $busyWaitSeconds=[int](& $module { $script:FastLlmSwitchBusyWaitSeconds })
    $stepMarginSeconds=60
    $stepBudget=[int]$script:ScenarioLoadTimeoutSeconds+$busyWaitSeconds+$stepMarginSeconds
    Check ($busyWaitSeconds -gt 0 -and [int]$script:SwitchStepTimeoutSeconds -ge $stepBudget) "client step wait: $([int]$script:SwitchStepTimeoutSeconds) s covers the target's load timeout ($([int]$script:ScenarioLoadTimeoutSeconds) s) + the busy wait ($busyWaitSeconds s) + a margin ($stepMarginSeconds s) = $stepBudget s"

    # ================= the request file: reader =================
    $unitWorld=New-SwitchWorld 'unit'
    Use-World $unitWorld
    $requestFile=Join-Path $unitWorld.state ('switch-'+('a'*32)+'.json')
    function Read-Request([string]$Text) {
        [IO.File]::WriteAllText($requestFile,$Text,(New-Object Text.UTF8Encoding($false)))
        try { return (& $module { param($P) Read-FastLlmSwitchRequest -Path $P } $requestFile) } finally { [IO.File]::Delete($requestFile) }
    }
    $read=Read-Request '{"schemaVersion":1,"modelId":"model-b","force":false}'
    Check ($read.state -ceq 'ok' -and $read.modelId -ceq 'model-b' -and $null -eq $read.recipeId -and $read.force -eq $false) 'request: a model request is read (schemaVersion 1, modelId, force)'
    $read=Read-Request '{"schemaVersion":1,"recipeId":"recipe-b","force":true}'
    Check ($read.state -ceq 'ok' -and $read.recipeId -ceq 'recipe-b' -and $null -eq $read.modelId -and $read.force -eq $true) 'request: a recipe request with force is read'
    $read=Read-Request '{"schemaVersion":1,"modelId":"model-b"}'
    Check ($read.state -ceq 'ok' -and $read.force -eq $false) 'request: force is optional and off when absent'
    $read=Read-Request ([string][char]0xFEFF+'{"schemaVersion":1,"modelId":"model-b","force":false}')
    Check ($read.state -ceq 'ok' -and $read.modelId -ceq 'model-b') 'request: a UTF-8 byte order mark (Windows PowerShell 5.1 writes one) is accepted'
    $invalid=[ordered]@{
        'not JSON'='{"schemaVersion":1,"modelId":'
        'an array'='[{"schemaVersion":1,"modelId":"model-b"}]'
        'a string'='"model-b"'
        'empty'=''
        'schemaVersion 2'='{"schemaVersion":2,"modelId":"model-b"}'
        'schemaVersion as text'='{"schemaVersion":"1","modelId":"model-b"}'
        'no schemaVersion'='{"modelId":"model-b"}'
        'both ids'='{"schemaVersion":1,"modelId":"model-b","recipeId":"recipe-b"}'
        'no id'='{"schemaVersion":1,"force":true}'
        'an id with a path'='{"schemaVersion":1,"modelId":"..\\\\model-b"}'
        'an id with a space'='{"schemaVersion":1,"modelId":"model b"}'
        'an empty id'='{"schemaVersion":1,"modelId":""}'
        'a numeric id'='{"schemaVersion":1,"modelId":7}'
        'an over-long id'=('{"schemaVersion":1,"modelId":"'+('m'*129)+'"}')
        'force as text'='{"schemaVersion":1,"modelId":"model-b","force":"true"}'
        'an unknown field'='{"schemaVersion":1,"modelId":"model-b","force":false,"prompt":"hello"}'
    }
    foreach ($case in $invalid.Keys) {
        $read=Read-Request $invalid[$case]
        Check ($read.state -ceq 'refused' -and $read.code -ceq 'switch-request-invalid' -and $null -eq $read.modelId -and $null -eq $read.recipeId) "request: $case is refused as switch-request-invalid and carries no id"
    }
    $exact='{"schemaVersion":1,"modelId":"model-b","force":false}'
    $read=Read-Request ($exact+(' '*(4096-$exact.Length)))
    Check ($read.state -ceq 'ok') 'request: a request of exactly 4096 bytes is read'
    $read=Read-Request ($exact+(' '*(4097-$exact.Length)))
    Check ($read.state -ceq 'refused' -and $read.code -ceq 'switch-request-too-large') 'request: a request of 4097 bytes is refused as switch-request-too-large (4 KiB limit)'
    $read=& $module { param($P) Read-FastLlmSwitchRequest -Path $P } $requestFile
    Check ($read.state -ceq 'transient') 'request: a name that is not there is transient, never a refusal'
    New-Item -ItemType Directory -Path $requestFile | Out-Null
    $read=& $module { param($P) Read-FastLlmSwitchRequest -Path $P } $requestFile
    [IO.Directory]::Delete($requestFile)
    Check ($read.state -ceq 'refused' -and $read.code -ceq 'switch-request-unsafe') 'request: a directory at the request path is refused as switch-request-unsafe'
    $linkTarget=Join-Path $unitWorld.root 'link-target.json'
    [IO.File]::WriteAllText($linkTarget,'{"schemaVersion":1,"modelId":"model-b","force":false}')
    if ($env:OS -ceq 'Windows_NT') { New-Item -ItemType Junction -Path $requestFile -Target $unitWorld.models | Out-Null } else { New-Item -ItemType SymbolicLink -Path $requestFile -Target $linkTarget | Out-Null }
    $read=& $module { param($P) Read-FastLlmSwitchRequest -Path $P } $requestFile
    Check ($read.state -ceq 'refused' -and $read.code -ceq 'switch-request-unsafe' -and $null -eq $read.modelId) 'request: a reparse point at the request path is refused as switch-request-unsafe and is not followed'
    if ($env:OS -ceq 'Windows_NT') { [IO.Directory]::Delete($requestFile) } else { [IO.File]::Delete($requestFile) }
    Check ((Test-Path -LiteralPath $linkTarget) -and (Test-Path -LiteralPath (Join-Path $unitWorld.models 'model-a.gguf'))) 'request: refusing a reparse point leaves what it points at untouched'

    # ================= the target: installed, consented and the right size, before anything is stopped =================
    function Resolve-Target([hashtable]$Arguments) { return (& $module { param($A) Resolve-FastLlmSwitchTarget @A } (@{ CatalogPath=$catalog; InstallRoot=$unitWorld.root; CurrentModelId='model-a' } + $Arguments)) }
    $target=Resolve-Target @{ ModelId='model-b' }
    Check ($target.ok -and $target.modelId -ceq 'model-b' -and $null -eq $target.code -and $null -eq $target.recipeId) 'target: an installed, consented model of the catalog size is accepted'
    $target=Resolve-Target @{ ModelId='MODEL-B' }
    Check ($target.ok -and $target.modelId -ceq 'model-b') 'target: the id is matched as the planner matches it, and the catalog spelling is what is passed on'
    foreach ($case in @(@{id='no-such-model';code='switch-target-unknown';to=$null},@{id='model-c';code='switch-target-not-installed';to='model-c'},@{id='model-d';code='switch-target-size-mismatch';to='model-d'},@{id='model-e';code='switch-target-no-consent';to='model-e'},@{id='model-a';code='switch-target-already-serving';to='model-a'})) {
        $target=Resolve-Target @{ ModelId=$case.id }
        Check (-not $target.ok -and $target.code -ceq $case.code -and [string]$target.modelId -ceq [string]$case.to) "target: $($case.id) is refused as $($case.code)"
    }
    $target=Resolve-Target @{ RecipeId='recipe-b' }
    Check ($target.ok -and $target.recipeId -ceq 'recipe-b' -and $target.modelId -ceq 'model-b') 'target: a recipe request resolves to the recipe''s model, which must be installed too'
    $target=Resolve-Target @{ RecipeId='no-such-recipe' }
    Check (-not $target.ok -and $target.code -ceq 'switch-target-unknown' -and $null -eq $target.recipeId -and $null -eq $target.modelId) 'target: an unknown recipe is refused as switch-target-unknown'
    $target=Resolve-Target @{ RecipeId='recipe-x' }
    Check (-not $target.ok -and $target.code -ceq 'switch-recipe-experimental') 'target: an experimental recipe is refused (its acceptance gate lives in the CLI, which a request file does not pass through)'
    $target=Resolve-Target @{ RecipeId='recipe-b'; CurrentRecipeId='recipe-b' }
    Check (-not $target.ok -and $target.code -ceq 'switch-target-already-serving') 'target: the recipe that already runs is refused as switch-target-already-serving'
    $target=Resolve-Target @{ RecipeId='recipe-b'; ServingProfileActive=$true }
    Check (-not $target.ok -and $target.code -ceq 'switch-recipe-needs-default-options') 'target: a recipe is refused while a context profile or slots option is on (a recipe is measured for the default options)'

    # ================= the request writer (Request-FastLlmSwitch) =================
    function Request-Switch([hashtable]$Arguments) {
        $thrown=$null
        try { Request-FastLlmSwitch -InstallRoot $unitWorld.root -CatalogPath $catalog @Arguments 6>$null | Out-Null } catch { $thrown=$_.Exception }
        return $thrown
    }
    $runId='b'*32
    $writerPath=Join-Path $unitWorld.state ('switch-'+$runId+'.json')
    $thrown=Request-Switch @{ ModelId='model-b' }
    Check ($null -ne $thrown -and $thrown.Message -like '*no ready FastLLM server*' -and -not (Test-Path -LiteralPath $writerPath)) 'writer: with no supervised server nothing is written'
    $unitLock=Enter-FastLlmOperation $unitWorld.root
    try {
        Write-FastLlmState -InstallRoot $unitWorld.root -State ([ordered]@{ schemaVersion=1; runId=$runId; phase='loading'; modelId='model-a'; switchAllowed=$true })
        $thrown=Request-Switch @{ ModelId='model-b' }
        Check ($null -ne $thrown -and $thrown.Message -like '*no ready FastLLM server*') 'writer: a server that is still loading takes no switch request'
        Write-FastLlmState -InstallRoot $unitWorld.root -State ([ordered]@{ schemaVersion=1; runId=$runId; phase='ready'; modelId='model-a' })
        $thrown=Request-Switch @{ ModelId='model-b' }
        Check ($null -ne $thrown -and $thrown.Message -like '*not started with model switching allowed*' -and -not (Test-Path -LiteralPath $writerPath)) 'writer: a server started without -AllowSwitch takes no switch request, and no file is written'
        Write-FastLlmState -InstallRoot $unitWorld.root -State ([ordered]@{ schemaVersion=1; runId=$runId; phase='ready'; modelId='model-a'; switchAllowed=$true })
        $thrown=Request-Switch @{ }
        Check ($null -ne $thrown -and $thrown.Message -like '*exactly one*') 'writer: a request needs a model id or a recipe id'
        $thrown=Request-Switch @{ ModelId='model-b'; RecipeId='recipe-b' }
        Check ($null -ne $thrown -and $thrown.Message -like '*exactly one*') 'writer: a request cannot name both a model and a recipe'
        foreach ($case in @(@{id='no-such-model';code='switch-target-unknown'},@{id='model-c';code='switch-target-not-installed'},@{id='model-e';code='switch-target-no-consent'},@{id='model-a';code='switch-target-already-serving'})) {
            $thrown=Request-Switch @{ ModelId=$case.id }
            Check ($null -ne $thrown -and [string]$thrown.Data['FastLlmFailureCode'] -ceq $case.code -and -not (Test-Path -LiteralPath $writerPath)) "writer: $($case.id) is refused at once as $($case.code), and no file is written"
        }
        $thrown=Request-Switch @{ ModelId='model-b' }
        Check ($null -eq $thrown -and (Test-Path -LiteralPath $writerPath -PathType Leaf)) 'writer: a valid request is written to state\switch-<runId>.json'
        $written=Read-FastLlmJson -Path $writerPath
        Check ((@($written.PSObject.Properties.Name | Sort-Object) -join ',') -ceq 'force,modelId,schemaVersion' -and [int]$written.schemaVersion -eq 1 -and $written.modelId -ceq 'model-b' -and $written.force -eq $false) 'writer: the request holds exactly schemaVersion, modelId and force'
        Check ((Get-Item -LiteralPath $writerPath).Length -le 4096 -and @(Get-ChildItem -LiteralPath $unitWorld.state -Filter '*.tmp').Count -eq 0) 'writer: the request is at most 4 KiB and no temporary file is left'
        $read=& $module { param($P) Read-FastLlmSwitchRequest -Path $P } $writerPath
        Check ($read.state -ceq 'ok' -and $read.modelId -ceq 'model-b') 'writer: what the writer writes, the supervisor''s reader accepts'
        $thrown=Request-Switch @{ RecipeId='recipe-b'; Force=$true }
        $written=Read-FastLlmJson -Path $writerPath
        Check ($null -eq $thrown -and (@($written.PSObject.Properties.Name | Sort-Object) -join ',') -ceq 'force,recipeId,schemaVersion' -and $written.recipeId -ceq 'recipe-b' -and $written.force -eq $true) 'writer: a later request replaces the earlier one (recipe id, force)'
        [IO.File]::Delete($writerPath)
        if ($env:OS -ceq 'Windows_NT') { New-Item -ItemType Junction -Path $writerPath -Target $unitWorld.models | Out-Null } else { New-Item -ItemType SymbolicLink -Path $writerPath -Target $linkTarget | Out-Null }
        $thrown=Request-Switch @{ ModelId='model-b' }
        if ($env:OS -ceq 'Windows_NT') { [IO.Directory]::Delete($writerPath) } else { [IO.File]::Delete($writerPath) }
        Check ($null -ne $thrown -and $thrown.Message -ceq 'Unsafe switch request path.' -and ([IO.File]::ReadAllText($linkTarget)) -ceq '{"schemaVersion":1,"modelId":"model-b","force":false}') 'writer: a reparse point at the request path is refused (Unsafe switch request path.) and nothing is written through it'
        # Stop during a switch: while the previous run's final document says a switch is pending, a stop names that run and is accepted.
        Write-FastLlmState -InstallRoot $unitWorld.root -State ([ordered]@{ schemaVersion=1; runId=$runId; phase='stopped'; stopReason='switch'; modelId='model-a'; switchAllowed=$true; 'switch'=[ordered]@{ from='model-a'; to='model-b'; pending=$true; result=$null; failureCode=$null } })
        Request-FastLlmStop -InstallRoot $unitWorld.root 6>$null
        Check (Test-Path -LiteralPath (Join-Path $unitWorld.state ('stop-'+$runId))) 'stop during a switch: a stop is accepted while the final document of the previous run carries switch.pending'
        [IO.File]::Delete((Join-Path $unitWorld.state ('stop-'+$runId)))
        Write-FastLlmState -InstallRoot $unitWorld.root -State ([ordered]@{ schemaVersion=1; runId=$runId; phase='stopped'; stopReason='user'; modelId='model-a'; 'switch'=[ordered]@{ from='model-a'; to='model-b'; result='ok'; failureCode=$null } })
        $stopRefused=$false
        try { Request-FastLlmStop -InstallRoot $unitWorld.root 6>$null } catch { $stopRefused=($_.Exception.Message -like '*no supervised server to stop*') }
        Check $stopRefused 'stop during a switch: a stopped run whose switch block is final is still "no supervised server to stop"'
    } finally { $unitLock.Dispose() }

    # ================= failure codes, the target plan and the pure pieces =================
    function Get-Code($Exception) { return (& $module { param($E) Get-FastLlmSwitchFailureCode -Exception $E } $Exception) }
    $typed=New-FastLlmTypedFailure -Code 'serving-profile-not-measured' -Message 'x'
    Check ((Get-Code $typed) -ceq 'serving-profile-not-measured') 'failure code: a typed failure keeps its own code'
    $supervised=New-Object InvalidOperationException('boom'); $supervised.Data['FastLlmSwitchFailureCode']='port-in-use'; $supervised.Data['FastLlmFailureCode']='other-code'
    Check ((Get-Code $supervised) -ceq 'port-in-use') 'failure code: the code the supervised run itself put in its switch block wins, so both documents agree'
    foreach ($case in @(@{reason='PlanChanged';code='switch-plan-changed'},@{reason='ModelNeedsProvisioning';code='switch-model-invalid'},@{reason='RuntimeCheckFailed';code='startup-or-runtime-check-failed'},@{reason='StateWriteFailed';code='state-write-failed'},@{reason='';code='switch-start-failed'})) {
        $untyped=New-Object InvalidOperationException("free text with $marker"); if ($case.reason) { $untyped.Data['FastLlmReason']=$case.reason }
        Check ((Get-Code $untyped) -ceq $case.code) "failure code: an untyped failure with reason '$($case.reason)' is $($case.code), never its text"
    }
    $hostile=New-Object InvalidOperationException('x'); $hostile.Data['FastLlmFailureCode']="bad code $marker"
    Check ((Get-Code $hostile) -ceq 'switch-start-failed') 'failure code: a value that is not a code is never passed on'
    $untypedRun=New-Object InvalidOperationException("canary text $marker")
    Check ((& $module { param($E) Get-FastLlmSwitchFailureCode -Exception $E -StatusCode 'startup-or-runtime-check-failed' } $untypedRun) -ceq 'startup-or-runtime-check-failed' -and (& $module { param($E) Get-FastLlmSwitchFailureCode -Exception $E -StatusCode 'startup-or-runtime-check-failed' } $typed) -ceq 'serving-profile-not-measured') 'failure code: an untyped failure of a supervised run takes the run''s status code; a typed one keeps its own'

    $previous=& $st.newPlan 'model-a' '' @{}
    $st.planCalls.Clear();$st.events.Clear()
    $targetPlan=& $module { param($P,$C,$R) New-FastLlmSwitchTargetPlan -PreviousPlan $P -Request ([pscustomobject]@{ modelId='model-b'; recipeId=$null }) -CatalogPath $C -InstallRoot $R } $previous $catalog $unitWorld.root
    $bound=$st.planCalls[$st.planCalls.Count-1]
    Check ($targetPlan.model.id -ceq 'model-b' -and (@($bound.Keys | Sort-Object) -join ',') -ceq 'CatalogPath,GpuVariantsPath,Hardware,InstallRoot,ModelId,Profile,RecipesPath,ServerPort' -and $bound['ModelId'] -ceq 'model-b' -and [int]$bound['ServerPort'] -eq [int]$unitWorld.port) 'target plan: the planner is asked for the target model on the same port; default options add no parameter'
    Check (($st.events -join ',') -ceq 'inventory,plan:model-b') 'target plan: a fresh hardware inventory is taken before the target is planned'
    $optioned=& $st.newPlan 'model-a' '' @{ Thinking='off'; ChatPage='on' }
    $optioned.profile='quality';$optioned.allowExperimentalModel=$true
    $optioned | Add-Member -NotePropertyName servingProfile -NotePropertyValue ([pscustomobject]@{ id='long'; slots=2; contextPerSlot=512 })
    $optioned | Add-Member -NotePropertyName backgroundRequestId -NotePropertyValue ('c'*32)
    $targetPlan=& $module { param($P,$C,$R) New-FastLlmSwitchTargetPlan -PreviousPlan $P -Request ([pscustomobject]@{ modelId='model-b'; recipeId=$null }) -CatalogPath $C -InstallRoot $R } $optioned $catalog $unitWorld.root
    $bound=$st.planCalls[$st.planCalls.Count-1]
    Check ($bound['Thinking'] -ceq 'off' -and $bound['ChatPage'] -ceq 'on' -and $bound['KvContextProfile'] -ceq 'long' -and [int]$bound['KvSlots'] -eq 2 -and ([string]$bound['KvProfilesPath']).EndsWith('serving-profiles.json') -and $bound['Profile'] -ceq 'quality' -and [bool]$bound['AllowExperimentalModel']) 'target plan: thinking, chat page, context profile, slots, profile and the experimental-model switch are the SAME as the previous plan''s'
    Check (-not $bound.ContainsKey('ContextSize') -and -not $bound.ContainsKey('ResolveFallback') -and -not $bound.ContainsKey('Recovered')) 'target plan: an explicit context size, a fallback and a recovery label are not carried to another model'
    Check ($targetPlan.backgroundRequestId -ceq ('c'*32)) 'target plan: a background start''s request id follows the plan, so the new run stays the host''s run'
    $targetPlan=& $module { param($P,$C,$R) New-FastLlmSwitchTargetPlan -PreviousPlan $P -Request ([pscustomobject]@{ modelId='model-b'; recipeId='recipe-b' }) -CatalogPath $C -InstallRoot $R } $previous $catalog $unitWorld.root
    $bound=$st.planCalls[$st.planCalls.Count-1]
    Check ($bound['RecipeId'] -ceq 'recipe-b' -and -not $bound.ContainsKey('ModelId') -and $targetPlan.recipe.id -ceq 'recipe-b') 'target plan: a recipe request is planned by its recipe id, never together with a model id'

    $runtimeText=[IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.Runtime.ps1'))
    $loopAt=$runtimeText.IndexOf('while (-not $hostProcess.Process.WaitForExit(250)) {')
    $loopText=$runtimeText.Substring($loopAt,$runtimeText.IndexOf('$exitCode = $hostProcess.Process.ExitCode',$loopAt)-$loopAt)
    $stopAt=$loopText.IndexOf('Test-Path -LiteralPath $stopPath')
    $pollAt=$loopText.IndexOf('Step-FastLlmSwitchPoll')
    Check ($stopAt -ge 0 -and $pollAt -gt $stopAt) 'loop: the stop file is checked before the switch request in every pass (stop always wins)'
    Check ($loopText -match '(?s)if \(\$AllowSwitch\) \{.*Step-FastLlmSwitchPoll' -and $runtimeText.IndexOf('Step-FastLlmSwitchPoll -') -eq $runtimeText.LastIndexOf('Step-FastLlmSwitchPoll -')) 'loop: the switch request is looked for only inside if ($AllowSwitch), in one place'
    Check ($runtimeText -match '\[switch\]\s*\$AllowSwitch' -and $runtimeText -notmatch '\$AllowSwitch\s*=\s*\$true') 'supervisor: -AllowSwitch is a switch that is off unless passed'
    $startText=& $module { (Get-Command Start-FastLlmServer).ScriptBlock.ToString() }
    $loopFunctionText=& $module { (Get-Command Invoke-FastLlmSwitchLoop).ScriptBlock.ToString() }
    Check ($startText -match '\[switch\]\s*\$AllowSwitch' -and $startText.Contains('$supervisorOptions.AllowSwitch') -and $startText.Contains('$startAgain.AllowSwitch')) 'start: Start-FastLlmServer takes -AllowSwitch (off by default), passes it on only when set and keeps it for the stand-in start'
    Check (-not $startText.Contains('Enter-FastLlmOperation') -and -not $loopFunctionText.Contains('Enter-FastLlmOperation') -and -not $loopFunctionText.Contains('operation.lock')) 'lock: neither the start nor the switch loop takes or releases the operation lock (one lock, owned by the one caller)'
    Check (([regex]::Matches($loopFunctionText,'Start-FastLlmServer ')).Count -eq 2) 'loop: the switch loop has exactly two starts per request: the target and ONE restore (never a third attempt)'
    # Default and bench starts never ask for it: only the supervisor, the start and the background host know the parameter.
    # FastLlm.UiFlow.ps1 is the control window's own logic (its Settings opt-in and its picker); the window passes the opt-in only for a start the user made there.
    $allowed=@('FastLlm.Runtime.ps1','FastLlm.psm1','FastLlm.BackgroundHost.ps1','FastLlm.UiFlow.ps1')
    $others=@(Get-ChildItem -LiteralPath (Join-Path $root 'src') -File | Where-Object { $_.Extension -in @('.ps1','.psm1') -and $allowed -cnotcontains $_.Name -and ([IO.File]::ReadAllText($_.FullName)) -match 'AllowSwitch|SwitchAllowed' })
    $tools=@(Get-ChildItem -LiteralPath (Join-Path $root 'tools') -File -Filter '*.ps1' | Where-Object { ([IO.File]::ReadAllText($_.FullName)) -match 'AllowSwitch|SwitchAllowed' })
    Check ($others.Count -eq 0 -and $tools.Count -eq 0) ('bench path: no lab, benchmark, diagnostic or tool source passes -AllowSwitch: ['+((@($others)+@($tools) | ForEach-Object Name) -join ',')+']')

    # ================= scenario: switch ok (self-test on, idle stop on, thinking off, chat page on) =================
    Set-BusyWait 60 200
    $world=New-SwitchWorld 'ok' @{ 'model-a'=@('busy2-selftest-ok'); 'model-b'=@('selftest-ok') }
    Use-World $world
    $st.thinking='off';$st.chatPage='on'
    $observed=New-Object 'Collections.Generic.List[string]'
    $r=Invoke-SwitchScenario -Label 'ok' -World $world -StartOptions @{ SelfTest=$true; IdleStopMinutes=15; SwitchObserver={ param($ServedModelId) $observed.Add([string]$ServedModelId) } } -Steps @(
        (New-Step @{ phase='ready'; modelId='model-a' } 'switch' @{ modelId='model-b' }),
        (New-Step @{ phase='ready'; modelId='model-b'; switchResult='ok' } 'stop'))
    $st.thinking='auto';$st.chatPage='off'
    Check ($r.completed -and $null -eq $r.failure -and $r.exit -eq 0) 'switch ok: the start serves model-a, switches to model-b on request, and ends 0 on stop'
    Check ($r.runs.Count -eq 2 -and $r.runs[0].modelId -ceq 'model-a' -and $r.runs[1].modelId -ceq 'model-b' -and $r.runs[0].runId -cmatch '^[0-9a-f]{32}$' -and $r.runs[1].runId -cmatch '^[0-9a-f]{32}$' -and $r.runs[0].runId -cne $r.runs[1].runId) 'switch ok: two supervised runs, a new run id for the new model'
    $oldFinal=Get-RunFinal $r.runs[0]
    Check ($oldFinal.phase -ceq 'stopped' -and $oldFinal.stopReason -ceq 'switch' -and $oldFinal.modelId -ceq 'model-a') 'switch ok: the old run ends stopped with stopReason switch'
    Check (Test-Block (Get-Block $oldFinal) 'model-a' 'model-b' $null $null $true) 'switch ok: the old run''s final document carries switch.pending (from model-a, to model-b)'
    $gap=ConvertFrom-StatusText ([string]$st.snapshots[1])
    Check ($st.snapshots.Count -ge 2 -and $gap.runId -ceq $r.runs[0].runId -and $gap.stopReason -ceq 'switch' -and (Get-Block $gap).pending -eq $true) 'switch ok: while the target is prepared, the status document is the old run''s final one, so a window can show "Switching to model-b"'
    $ready=@(Get-ReadyObservations $r $r.runs[1].runId)
    Check ($ready.Count -ge 1 -and (Test-Block $ready[0].switch 'model-a' 'model-b' 'ok' $null $false)) 'switch ok: the new run is ready with switch = { from, to, result ok, failureCode null } and no pending field'
    Check ($ready[0].canary -and $ready[0].placement -and $ready[0].selfTest -ceq 'pass' -and $ready[0].pid -gt 0) 'switch ok: the new model passed the same gates (API check, reported layers, self-test) before it was ready'
    $firstReady=@(Get-ReadyObservations $r $r.runs[0].runId)
    Check ($firstReady[0].canary -and $firstReady[0].selfTest -ceq 'pass' -and $firstReady[0].pid -gt 0 -and $firstReady[0].pid -ne $ready[0].pid) 'switch ok: each model was served by its own server process'
    $writesA=@(Get-Writes $r.runs[0].runId)
    $waitingAt=-1;$stoppedAt=-1
    for ($w=0; $w -lt $writesA.Count; $w++) {
        if ($waitingAt -lt 0 -and [string]$writesA[$w].phase -ceq 'ready' -and (Get-Field (Get-Block $writesA[$w]) 'pending') -eq $true) { $waitingAt=$w }
        if ([string]$writesA[$w].phase -ceq 'stopped') { $stoppedAt=$w }
    }
    $requestLine=@(Get-LogEvents (Get-RunLog $world $r.runs[0].runId) 'switch-request')[0]
    $endLine=@(Get-LogEvents (Get-RunLog $world $r.runs[0].runId) 'end')[0]
    Check ($waitingAt -ge 0 -and $stoppedAt -gt $waitingAt -and ((Get-LogTime $endLine) - (Get-LogTime $requestLine)).TotalMilliseconds -ge 200) 'switch ok: while requests were still in progress the server kept serving (ready, switch pending) and was stopped only after they finished'
    $events=$r.events -join ','
    Check ($events -ceq 'hash:model-a,consent:model-a,inventory,plan:model-a,supervisor:model-a,consent:model-b,inventory,plan:model-b,hash:model-b,consent:model-b,inventory,plan:model-b,supervisor:model-b') "switch ok: the target is checked before anything stops, then gets a fresh inventory and a full normal start (hash, consent, inventory, plan) [$events]"
    Check ($r.runs[0].bound -ceq 'AllowSwitch,CatalogPath,IdleStopMinutes,InstallRoot,LoadTimeoutSeconds,Plan,SelfTest,SwitchContext' -and $r.runs[1].bound -ceq $r.runs[0].bound -and $r.runs[1].idleStopMinutes -eq 15 -and $r.runs[1].selfTest) 'switch ok: the new run gets the same start options (self-test, idle stop), so the idle detector starts again with the new run'
    Check ($r.runs[1].thinking -ceq 'off' -and (Get-RunFinal $r.runs[1]).thinking -ceq 'off' -and (Get-RunFinal $r.runs[1]).chatPage -ceq 'on' -and [int](Get-RunFinal $r.runs[1]).idleStopMinutes -eq 15 -and (Get-RunFinal $r.runs[1]).endpoint -ceq (Get-RunFinal $r.runs[0]).endpoint) 'switch ok: the switch carried the serving options (thinking off, chat page on, the same endpoint)'
    Check (@($r.observations | Where-Object { $_.runId -and -not $_.active }).Count -eq 0 -and $r.observations.Count -ge 4 -and $st.lockFree.Count -eq 0) 'switch ok: the operation lock was held at every moment another process looked, and was never free between the two runs'
    Check ((Get-RunFinal $r.runs[1]).stopReason -ceq 'user' -and (Test-Block (Get-Block $r.final) 'model-a' 'model-b' 'ok' $null $false) -and $r.final.switchAllowed -eq $true) 'switch ok: a later user stop ends the new run normally; its document keeps the switch block'
    $logA=@(Get-RunLog $world $r.runs[0].runId);$logB=@(Get-RunLog $world $r.runs[1].runId)
    $requested=@(Get-LogEvents $logA 'switch-request')
    Check ($requested.Count -eq 1 -and (@($requested[0].PSObject.Properties.Name | Sort-Object) -join ',') -ceq 'event,fromModelId,runId,toModelId,ts' -and $requested[0].fromModelId -ceq 'model-a' -and $requested[0].toModelId -ceq 'model-b') 'switch ok: the old run''s log has switch-request { fromModelId, toModelId } and nothing else'
    $results=@(Get-LogEvents $logB 'switch-result')
    Check ($results.Count -eq 1 -and (@($results[0].PSObject.Properties.Name | Sort-Object) -join ',') -ceq 'event,result,runId,ts' -and $results[0].result -ceq 'ok' -and @(Get-LogEvents $logA 'switch-result').Count -eq 0) 'switch ok: the new run''s log has switch-result { result ok }'
    Check (@(Get-LogEvents $logA 'end').Count -eq 1 -and (Get-LogEvents $logA 'end')[0].phase -ceq 'stopped' -and (Get-LogEvents $logB 'start')[0].modelId -ceq 'model-b' -and (Get-LogEvents $logB 'self-test')[0].status -ceq 'pass' -and @(Get-ChildItem -LiteralPath (Join-Path $world.state 'logs') -Filter 'run-*.jsonl').Count -eq 2) 'switch ok: both run logs are kept, each with its own start, checks and end'
    Check (@(Get-ChildItem -LiteralPath $world.state -Force | Where-Object { $_.Name -like 'switch-*' -or $_.Name -like 'stop-*' }).Count -eq 0) 'switch ok: no request file is left behind'
    Check (($observed -join ',') -ceq 'model-b') 'switch ok: the observer was told the model about to be served'
    Check ((@(Get-ModeStarts $world 'model-a')).Count -eq 1 -and (@(Get-ModeStarts $world 'model-b')).Count -eq 1 -and (Test-PortFree $world.port)) 'switch ok: each model''s server was started once and nothing is left listening'

    # ================= scenario: the target fails, the previous model is restored (once) =================
    $world=New-SwitchWorld 'restored' @{ 'model-a'=@('selftest-ok','selftest-ok'); 'model-b'=@('ok') }
    Use-World $world
    $observed=New-Object 'Collections.Generic.List[string]'
    # Every server of the sequence (the first start, the target and the restore) is launched through the one environment builder: with
    # hostile inherited values in this process, the mock server exits at once if any of them reaches it (an inherited API key included).
    $savedEnvironment=@{}
    foreach ($name in @('FASTLLM_TEST_EXPECT_ISOLATION','LLAMA_API_KEY','LLAMA_ARG_MODEL','GGML_TEST_OVERRIDE')) {
        $savedEnvironment[$name]=[Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name,$(if($name -ceq 'FASTLLM_TEST_EXPECT_ISOLATION'){'1'}else{'hostile-inherited-value'}))
    }
    try {
        $r=Invoke-SwitchScenario -Label 'restored' -World $world -StartOptions @{ SelfTest=$true; SwitchObserver={ param($ServedModelId) $observed.Add([string]$ServedModelId) } } -Steps @(
            (New-Step @{ phase='ready'; modelId='model-a' } 'switch' @{ modelId='model-b' }),
            (New-Step @{ phase='ready'; modelId='model-a'; switchResult='failed-restored' } 'stop'))
    } finally { foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name,$savedEnvironment[$name]) } }
    Check ($r.completed -and $null -eq $r.failure -and $r.exit -eq 0) 'failed-restored: a target that fails its self-test does not end the start; the previous model serves again'
    Check ($r.runs.Count -eq 3 -and (($r.runs | ForEach-Object { $_.modelId }) -join ',') -ceq 'model-a,model-b,model-a' -and $r.runs[1].failed -and -not $r.runs[2].failed -and @($r.runs | ForEach-Object { $_.runId } | Select-Object -Unique).Count -eq 3) 'failed-restored: exactly three runs (model-a, the failed model-b, model-a again), each with its own run id'
    $targetFinal=Get-RunFinal $r.runs[1]
    Check ($targetFinal.phase -ceq 'failed' -and $targetFinal.failureCode -ceq 'startup-or-runtime-check-failed' -and (Test-Block (Get-Block $targetFinal) 'model-a' 'model-b' $null 'self-test-failed' $true)) 'failed-restored: the failed target''s document says why (self-test-failed) and that the switch is still pending'
    $ready=@(Get-ReadyObservations $r $r.runs[2].runId)
    Check ($ready.Count -ge 1 -and (Test-Block $ready[0].switch 'model-a' 'model-b' 'failed-restored' 'self-test-failed' $false) -and $ready[0].selfTest -ceq 'pass' -and $ready[0].canary) 'failed-restored: the restored run is ready with switch = { from, to, result failed-restored, failureCode } after passing the gates again'
    $events=$r.events -join ','
    Check ($events.EndsWith('supervisor:model-b,hash:model-a,consent:model-a,inventory,plan:model-a,supervisor:model-a')) "failed-restored: the restore is a full normal start of the previous model (hash, consent, inventory, plan) [$events]"
    $logB=@(Get-RunLog $world $r.runs[1].runId);$logRestore=@(Get-RunLog $world $r.runs[2].runId)
    $results=@(Get-LogEvents $logRestore 'switch-result')
    Check ($results.Count -eq 1 -and $results[0].result -ceq 'failed-restored' -and $results[0].failureCode -ceq 'self-test-failed' -and (@($results[0].PSObject.Properties.Name | Sort-Object) -join ',') -ceq 'event,failureCode,result,runId,ts') 'failed-restored: the restored run''s log has switch-result { result failed-restored, failureCode }'
    Check ((Get-LogEvents $logB 'end')[0].phase -ceq 'failed' -and (Get-LogEvents $logB 'start')[0].modelId -ceq 'model-b' -and @(Get-LogEvents $logB 'switch-result').Count -eq 0 -and @(Get-ChildItem -LiteralPath (Join-Path $world.state 'logs') -Filter 'run-*.jsonl').Count -eq 3) 'failed-restored: the failed target''s run log is kept next to the other two'
    Check (($observed -join ',') -ceq 'model-b,model-a') 'failed-restored: the observer was told the target, then the restored model'
    Check (@(Get-LogEvents $logB 'api-check').Count -eq 1 -and @(Get-LogEvents $logRestore 'api-check').Count -eq 1 -and @(Get-LogEvents (Get-RunLog $world $r.runs[0].runId) 'api-check').Count -eq 1) 'failed-restored: the first start, the target and the restore each ran with the scrubbed environment (no inherited API key or engine override reached any of the three servers)'
    Check (@($r.observations | Where-Object { $_.runId -and -not $_.active }).Count -eq 0 -and $st.lockFree.Count -eq 0 -and (Test-PortFree $world.port)) 'failed-restored: the lock was held throughout and nothing is left listening'

    # ================= scenario: the restore fails too, then stopped (never a third attempt) =================
    $world=New-SwitchWorld 'stopped' @{ 'model-a'=@('ok','unstable','ok'); 'model-b'=@('unstable','ok') }
    Use-World $world
    $r=Invoke-SwitchScenario -Label 'stopped' -World $world -Steps @(
        (New-Step @{ phase='ready'; modelId='model-a' } 'switch' @{ modelId='model-b' }),
        (New-Step @{ switchResult='failed-stopped' } 'none'))
    Check ($r.completed -and $null -ne $r.failure -and [string]$r.failure.Data['FastLlmFailureCode'] -ceq 'switch-failed-stopped' -and $r.failure.Data['FastLlmSwitchAttempted'] -eq $true) 'failed-stopped: when the restore fails too the start ends with the typed failure switch-failed-stopped'
    Check (@('RuntimeCheckFailed','PlanChanged','ModelNeedsProvisioning') -cnotcontains [string]$r.failure.Data['FastLlmReason'] -and $r.failure.Message -like '*model-b*' -and $r.failure.Message -like '*model-a*' -and $r.failure.Message -like '*stopped*') 'failed-stopped: the failure names both models in plain words and carries no reason a caller would retry, re-plan or repair on'
    Check ($r.runs.Count -eq 3 -and (($r.runs | ForEach-Object { $_.modelId }) -join ',') -ceq 'model-a,model-b,model-a' -and (@(Get-ModeStarts $world 'model-a')).Count -eq 2 -and (@(Get-ModeStarts $world 'model-b')).Count -eq 1) 'failed-stopped: the target and ONE restore were tried; there was never a third attempt'
    Check ($r.final.phase -ceq 'failed' -and $r.final.runId -ceq $r.runs[2].runId -and $r.final.failureCode -ceq 'startup-or-runtime-check-failed' -and (Test-Block (Get-Block $r.final) 'model-a' 'model-b' 'failed-stopped' 'startup-or-runtime-check-failed' $false)) 'failed-stopped: the final document says switch = { from, to, result failed-stopped, failureCode } (why the target did not start)'
    $logRestore=@(Get-RunLog $world $r.runs[2].runId)
    $results=@(Get-LogEvents $logRestore 'switch-result')
    Check ($results.Count -eq 1 -and $results[0].result -ceq 'failed-stopped' -and $results[0].failureCode -ceq 'startup-or-runtime-check-failed' -and @(Get-ChildItem -LiteralPath (Join-Path $world.state 'logs') -Filter 'run-*.jsonl').Count -eq 3) 'failed-stopped: the last run''s log has switch-result { result failed-stopped, failureCode } and all three run logs are kept'
    Check ((Test-PortFree $world.port) -and @($r.observations | Where-Object { $_.runId -and -not $_.active }).Count -eq 0) 'failed-stopped: no server is left running, and the lock was held until the start returned'

    # ================= scenario: the target cannot even be planned (does not fit), the previous model is restored =================
    $world=New-SwitchWorld 'unplanned' @{ 'model-a'=@('ok','ok') }
    Use-World $world
    $st.planFailures['model-b']=(New-Object InvalidOperationException("No other model fits. $marker"))
    $r=Invoke-SwitchScenario -Label 'unplanned' -World $world -Steps @(
        (New-Step @{ phase='ready'; modelId='model-a' } 'switch' @{ modelId='model-b' }),
        (New-Step @{ phase='ready'; modelId='model-a'; switchResult='failed-restored' } 'stop'))
    Check ($r.completed -and $null -eq $r.failure -and $r.exit -eq 0 -and (($r.runs | ForEach-Object { $_.modelId }) -join ',') -ceq 'model-a,model-a' -and (@(Get-ModeStarts $world 'model-b')).Count -eq 0) 'target not plannable: the planner''s refusal is a failed switch; model-b is never started and model-a is restored'
    $ready=@(Get-ReadyObservations $r $r.runs[1].runId)
    Check ($ready.Count -ge 1 -and (Test-Block $ready[0].switch 'model-a' 'model-b' 'failed-restored' 'switch-start-failed' $false)) 'target not plannable: an untyped refusal is recorded as switch-start-failed'
    $between=ConvertFrom-StatusText ([string]$st.snapshots[$st.snapshots.Count-1])
    Check ($between.runId -ceq $r.runs[0].runId -and (Test-Block (Get-Block $between) 'model-a' 'model-b' $null 'switch-start-failed' $true)) 'target not plannable: with no target run to say so, the previous run''s document says why the restore follows'
    Check (@(Find-MarkerFiles $world).Count -eq 0) 'target not plannable: the refusal''s own text is in no status document and no log'

    # ================= scenario: the restore never reaches a run (its model fails the hash); the outcome is still recorded =================
    $world=New-SwitchWorld 'unrestorable'
    Use-World $world
    $st.planFailures['model-b']=(New-FastLlmTypedFailure -Code 'serving-profile-not-measured' -Message 'not measured for this model and engine')
    $hashQueue=New-Object 'Collections.Generic.Queue[object]';$hashQueue.Enqueue($true);$hashQueue.Enqueue($false)
    $st.hashResults['model-a']=$hashQueue
    $r=Invoke-SwitchScenario -Label 'unrestorable' -World $world -Steps @(
        (New-Step @{ phase='ready'; modelId='model-a' } 'switch' @{ modelId='model-b' }),
        (New-Step @{ switchResult='failed-stopped' } 'none'))
    Check ($r.completed -and $null -ne $r.failure -and [string]$r.failure.Data['FastLlmFailureCode'] -ceq 'switch-failed-stopped' -and $r.runs.Count -eq 1) 'restore not startable: the start ends with switch-failed-stopped after the one run that served'
    Check ($r.final.runId -ceq $r.runs[0].runId -and $r.final.phase -ceq 'stopped' -and (Test-Block (Get-Block $r.final) 'model-a' 'model-b' 'failed-stopped' 'serving-profile-not-measured' $false)) 'restore not startable: the status document carries failed-stopped with the target''s typed code although no new run wrote one'
    $logA=@(Get-RunLog $world $r.runs[0].runId)
    $results=@(Get-LogEvents $logA 'switch-result')
    Check ($results.Count -eq 1 -and $results[0].result -ceq 'failed-stopped' -and $results[0].failureCode -ceq 'serving-profile-not-measured') 'restore not startable: the last run''s log gets the switch-result'
    Check (($r.events -join ',') -notmatch 'INSTALL|NETWORK' -and ($r.events -join ',').EndsWith('plan:model-b,hash:model-a')) 'restore not startable: the restore stops at the failed hash; nothing is repaired, installed or downloaded for it'

    # ================= scenario: refused-busy, then a forced switch by recipe =================
    Set-BusyWait 2 200
    $world=New-SwitchWorld 'busy' @{ 'model-a'=@('busy-ok'); 'model-b'=@('ok') }
    Use-World $world
    $r=Invoke-SwitchScenario -Label 'busy' -World $world -Steps @(
        (New-Step @{ phase='ready'; modelId='model-a' } 'switch' @{ modelId='model-b' }),
        (New-Step @{ phase='ready'; modelId='model-a'; switchResult='refused-busy' } 'switch' @{ recipeId='recipe-b'; force=$true }),
        (New-Step @{ phase='ready'; modelId='model-b'; switchResult='ok' } 'stop'))
    Set-BusyWait 60 200
    Check ($r.completed -and $null -eq $r.failure -and $r.exit -eq 0 -and (($r.runs | ForEach-Object { $_.modelId }) -join ',') -ceq 'model-a,model-b') 'refused-busy: a server that is still answering after the wait is not switched; a forced request then is'
    $firstReady=@(Get-ReadyObservations $r $r.runs[0].runId)
    $refused=@($firstReady | Where-Object { $null -ne $_.switch -and (Get-Field $_.switch 'result') -ceq 'refused-busy' })
    Check ($refused.Count -ge 1 -and (Test-Block $refused[0].switch 'model-a' 'model-b' 'refused-busy' $null $false) -and $refused[0].pid -eq $firstReady[0].pid) 'refused-busy: the same server keeps running with switch = { from, to, result refused-busy, failureCode null }'
    $logA=@(Get-RunLog $world $r.runs[0].runId)
    $busyMs=[int]((Get-LogTime (Get-LogEvents $logA 'switch-result')[0]) - (Get-LogTime (Get-LogEvents $logA 'switch-request')[0])).TotalMilliseconds
    Check ($busyMs -ge 2000 -and @(Get-Writes $r.runs[0].runId | Where-Object { [string]$_.phase -ceq 'ready' -and (Get-Field (Get-Block $_) 'pending') -eq $true }).Count -ge 1) "refused-busy: the request waited the whole busy time, shown as pending, before it was refused ($busyMs ms)"
    $sequence=(@($logA | Where-Object { [string]$_.event -like 'switch-*' } | ForEach-Object { [string]$_.event + $(if ($_.PSObject.Properties['result']) { ':' + [string]$_.result } else { '' }) }) -join ',')
    Check ($sequence -ceq 'switch-request,switch-result:refused-busy,switch-request') "refused-busy: the run log has the request, its refusal, then the forced request [$sequence]"
    $forcedPlan=@($st.planCalls | Where-Object { $_.ContainsKey('RecipeId') -and $_['RecipeId'] -ceq 'recipe-b' })
    Check ($forcedPlan.Count -ge 1 -and -not $forcedPlan[0].ContainsKey('ModelId') -and (Get-RunFinal $r.runs[1]).planRecipe.id -ceq 'recipe-b' -and (Test-Block (Get-Block $r.final) 'model-a' 'model-b' 'ok' $null $false)) 'forced recipe switch: force skips the wait, the target is planned by recipe id and the block names the recipe''s model'
    Check ((@(Get-ModeStarts $world 'model-a')).Count -eq 1 -and (Test-PortFree $world.port)) 'refused-busy: the refused request did not restart the server'

    # ================= scenario: stop beats switch (both requests on disk) =================
    $world=New-SwitchWorld 'stop-first'
    Use-World $world
    $r=Invoke-SwitchScenario -Label 'stop-first' -World $world -Steps @(
        (New-Step @{ phase='ready'; modelId='model-a' } 'stop-then-raw' @{ text=(Format-RawRequest @{ schemaVersion=1; modelId='model-b'; force=$true }) }))
    Check ($r.completed -and $null -eq $r.failure -and $r.exit -eq 0 -and $r.runs.Count -eq 1 -and (@(Get-ModeStarts $world 'model-b')).Count -eq 0) 'stop beats switch: with a stop and a (forced) switch request both present, the server stops and the other model is never started'
    Check ($r.final.phase -ceq 'stopped' -and $r.final.stopReason -ceq 'user' -and $null -eq (Get-Block $r.final)) 'stop beats switch: the run ends as a user stop and the switch request was never read'
    Check (@(@(Get-RunLog $world $r.runs[0].runId) | Where-Object { [string]$_.event -like 'switch-*' }).Count -eq 0 -and @(Get-ChildItem -LiteralPath $world.state -Force | Where-Object { $_.Name -like 'stop-*' }).Count -eq 0 -and ($r.events -join ',') -ceq 'hash:model-a,consent:model-a,inventory,plan:model-a,supervisor:model-a') 'stop beats switch: nothing about the switch is logged, checked or planned, and the stop request is removed'

    # ================= scenario: a stop while the target is being prepared (inventory) =================
    $world=New-SwitchWorld 'stop-gap'
    Use-World $world
    $st.inventoryHold=$true
    $r=Invoke-SwitchScenario -Label 'stop-gap' -World $world -Steps @(
        (New-Step @{ phase='ready'; modelId='model-a' } 'switch' @{ modelId='model-b' }),
        (New-Step @{ phase='stopped'; stopReason='switch'; switchPending=$true } 'stop'))
    Check ($r.completed -and $null -eq $r.steps[1].error -and $null -eq $r.failure -and $r.exit -eq 0) 'stop during a switch: a stop asked for after the old server stopped is accepted and ends the start cleanly'
    Check ($r.runs.Count -eq 1 -and -not ($r.events -join ',').Contains('supervisor:model-b') -and (@(Get-ModeStarts $world 'model-b')).Count -eq 0) 'stop during a switch: the target is never started'
    Check ($r.final.runId -ceq $r.runs[0].runId -and $r.final.phase -ceq 'stopped' -and $r.final.stopReason -ceq 'user' -and (Test-Block (Get-Block $r.final) 'model-a' 'model-b' 'refused' 'switch-cancelled-by-stop' $false)) 'stop during a switch: the document ends as a user stop with switch = { result refused, failureCode switch-cancelled-by-stop }'
    $results=@(Get-LogEvents (Get-RunLog $world $r.runs[0].runId) 'switch-result')
    Check ($results.Count -eq 1 -and $results[0].result -ceq 'refused' -and $results[0].failureCode -ceq 'switch-cancelled-by-stop' -and (Wait-StopFilesGone $world 10)) 'stop during a switch: the outcome is in the run log and the stop request is removed'

    # ================= scenario: a stop that lands while the old server is shutting down for the switch =================
    $world=New-SwitchWorld 'stop-shutdown'
    Use-World $world
    $st.stopAtSwitchWrite=$true
    $r=Invoke-SwitchScenario -Label 'stop-shutdown' -World $world -Steps @(
        (New-Step @{ phase='ready'; modelId='model-a' } 'switch' @{ modelId='model-b' }),
        (New-Step @{ switchResult='refused'; switchFailureCode='switch-cancelled-by-stop' } 'none'))
    Check ($r.completed -and $null -eq $r.failure -and $r.exit -eq 0 -and $r.runs.Count -eq 1 -and ($r.events -join ',') -notmatch 'plan:model-b|supervisor:model-b') 'stop while the old server shuts down: the stop request survives that run''s clean-up and nothing is planned or started for the target'
    Check ($r.final.runId -ceq $r.runs[0].runId -and $r.final.stopReason -ceq 'user' -and (Test-Block (Get-Block $r.final) 'model-a' 'model-b' 'refused' 'switch-cancelled-by-stop' $false) -and @(Get-ChildItem -LiteralPath $world.state -Force | Where-Object { $_.Name -like 'stop-*' }).Count -eq 0) 'stop while the old server shuts down: the document ends as a user stop with the switch cancelled, and the stop request is removed'

    # ================= scenario: a stop while the target's file is being hashed (after the last check before the start) =================
    $world=New-SwitchWorld 'stop-hash'
    Use-World $world
    $st.hashHold['model-b']=$true
    $st.hashMarker=Join-Path $world.root 'hashing.marker'
    $r=Invoke-SwitchScenario -Label 'stop-hash' -World $world -Steps @(
        (New-Step @{ phase='ready'; modelId='model-a' } 'switch' @{ modelId='model-b' }),
        (New-Step @{ fileExists=$st.hashMarker; switchPending=$true } 'stop'))
    Check ($r.completed -and $null -eq $r.steps[1].error -and $null -eq $r.failure -and $r.exit -eq 0) 'stop during the target hash: the stop names the previous run and is still honoured by the next one'
    Check ($r.runs.Count -eq 2 -and $r.runs[1].modelId -ceq 'model-b' -and (@(Get-ModeStarts $world 'model-b')).Count -eq 0) 'stop during the target hash: the target''s supervised run ends before it spawns a server'
    $targetFinal=Get-RunFinal $r.runs[1]
    Check ($targetFinal.phase -ceq 'stopped' -and $targetFinal.stopReason -ceq 'user' -and $null -eq $targetFinal.processIdentity -and (Test-Block (Get-Block $targetFinal) 'model-a' 'model-b' 'refused' 'switch-cancelled-by-stop' $false)) 'stop during the target hash: that run ends stopped (user), with no server identity and the switch cancelled'
    Check (@(Get-ChildItem -LiteralPath $world.state -Force | Where-Object { $_.Name -like 'stop-*' }).Count -eq 0) 'stop during the target hash: the stop request of the previous run is removed'

    # ================= scenario: a stop while the switch waits for requests in progress =================
    Set-BusyWait 3600 200
    $world=New-SwitchWorld 'stop-wait' @{ 'model-a'=@('busy-ok') }
    Use-World $world
    $r=Invoke-SwitchScenario -Label 'stop-wait' -World $world -Steps @(
        (New-Step @{ phase='ready'; modelId='model-a' } 'switch' @{ modelId='model-b' }),
        (New-Step @{ phase='ready'; switchPending=$true } 'stop'))
    Check ($r.completed -and $null -eq $r.failure -and $r.exit -eq 0 -and $r.runs.Count -eq 1) 'stop during the busy wait: the stop wins over the waiting switch'
    Check ($r.final.stopReason -ceq 'user' -and (Test-Block (Get-Block $r.final) 'model-a' 'model-b' 'refused' 'switch-cancelled-by-stop' $false)) 'stop during the busy wait: the final document is a user stop with the switch cancelled, not pending'
    Set-BusyWait 60 200

    # ================= scenario: a stop while the target loads is a stop, not a failed switch =================
    $world=New-SwitchWorld 'stop-load' @{ 'model-b'=@('timeout') }
    Use-World $world
    $r=Invoke-SwitchScenario -Label 'stop-load' -World $world -Steps @(
        (New-Step @{ phase='ready'; modelId='model-a' } 'switch' @{ modelId='model-b' }),
        (New-Step @{ phase='loading'; modelId='model-b' } 'stop'))
    Check ($r.completed -and $null -eq $r.steps[1].error -and $null -eq $r.failure -and $r.exit -eq 0) 'stop while the target loads: the start ends 0'
    Check ($r.runs.Count -eq 2 -and (@(Get-ModeStarts $world 'model-a')).Count -eq 1) 'stop while the target loads: the previous model is NOT started again (a stop is not a failed start)'
    Check ($r.final.phase -ceq 'stopped' -and (Test-Block (Get-Block $r.final) 'model-a' 'model-b' 'refused' 'switch-cancelled-by-stop' $false) -and (Test-PortFree $world.port)) 'stop while the target loads: the document says the switch was cancelled, and nothing is left listening'

    # ================= scenario: no polling without the flag (the default start and the bench path) =================
    $world=New-SwitchWorld 'no-flag'
    Use-World $world
    $rawRequest=Format-RawRequest @{ schemaVersion=1; modelId='model-b'; force=$true }
    $r=Invoke-SwitchScenario -Label 'no-flag' -World $world -NoAllowSwitch -Steps @(
        (New-Step @{ phase='ready'; modelId='model-a' } 'switch' @{ modelId='model-b' }),
        (New-Step $null 'raw' @{ text=$rawRequest }),
        (New-Step $null 'sleep' @{ milliseconds=3000 }),
        (New-Step @{ phase='ready'; modelId='model-a' } 'stop'))
    Check ($r.completed -and $null -eq $r.failure -and $r.exit -eq 0 -and $r.runs.Count -eq 1 -and $r.runs[0].bound -ceq $defaultSupervisorBound) 'no flag: a default start calls the supervisor with exactly its existing parameters and serves one run'
    Check ([string]$r.steps[0].error -like '*not started with model switching allowed*') 'no flag: the request writer refuses a server that was not started with -AllowSwitch'
    Check ($st.basisWrites.Count -eq 0 -and @(Get-ChildItem -LiteralPath $world.state -Force | Where-Object { $_.Name -like 'switch-basis-*' }).Count -eq 0) 'no flag: no switch basis is written for a default start'
    $leftover=Join-Path $world.state ('switch-'+$r.runs[0].runId+'.json')
    Check ((Test-Path -LiteralPath $leftover -PathType Leaf) -and ([IO.File]::ReadAllText($leftover)) -ceq $rawRequest) 'no flag: a (forced) request file written anyway is never read, changed or removed'
    Check (@($r.observations | Where-Object { $null -ne $_.switch -or $null -ne $_.switchAllowed -or ([string]$_.keys) -match 'switch' }).Count -eq 0 -and $null -eq (Get-Block $r.final) -and -not $r.final.PSObject.Properties['switchAllowed'] -and $r.final.stopReason -ceq 'user') 'no flag: the status document of a default start has no switch field at any time'
    Check (@(@(Get-RunLog $world $r.runs[0].runId) | Where-Object { [string]$_.event -like 'switch-*' }).Count -eq 0 -and (@(Get-ModeStarts $world 'model-b')).Count -eq 0 -and ($r.events -join ',') -ceq 'hash:model-a,consent:model-a,inventory,plan:model-a,supervisor:model-a') 'no flag: nothing is logged, planned or started for the request'
    $defaultKeys=[string](@(Get-ReadyObservations $r $r.runs[0].runId)[0].keys)

    # ================= scenario: unsafe and refused requests never touch the running server =================
    $world=New-SwitchWorld 'refused'
    Use-World $world
    $followed=Join-Path $world.root 'followed.json'
    [IO.File]::WriteAllText($followed,(Format-RawRequest @{ schemaVersion=1; modelId='model-b'; force=$true }))
    $refusals=@(
        @{ action='link'; more=@{ target=$followed }; code='switch-request-unsafe'; to=$null; after='unlink' },
        @{ action='raw'; more=@{ text=(Format-RawRequest @{ schemaVersion=1; modelId='model-b'; force=$true }); padBytes=4096 }; code='switch-request-too-large'; to=$null },
        @{ action='directory'; more=@{}; code='switch-request-unsafe'; to=$null; after='remove-directory' },
        @{ action='raw'; more=@{ text=('{"schemaVersion":1,"modelId":"model-b","prompt":"'+$marker+'"}') }; code='switch-request-invalid'; to=$null },
        @{ action='raw'; more=@{ text=(Format-RawRequest @{ schemaVersion=1; modelId=$marker; force=$true }) }; code='switch-target-unknown'; to=$null },
        @{ action='raw'; more=@{ text=(Format-RawRequest @{ schemaVersion=1; modelId='model-c'; force=$true }) }; code='switch-target-not-installed'; to='model-c' },
        @{ action='raw'; more=@{ text=(Format-RawRequest @{ schemaVersion=1; modelId='model-d'; force=$true }) }; code='switch-target-size-mismatch'; to='model-d' },
        @{ action='raw'; more=@{ text=(Format-RawRequest @{ schemaVersion=1; modelId='model-e'; force=$true }) }; code='switch-target-no-consent'; to='model-e' },
        @{ action='raw'; more=@{ text=(Format-RawRequest @{ schemaVersion=1; modelId='model-a'; force=$true }) }; code='switch-target-already-serving'; to='model-a' },
        @{ action='raw'; more=@{ text=(Format-RawRequest @{ schemaVersion=1; recipeId='recipe-x'; force=$true }) }; code='switch-recipe-experimental'; to=$null },
        @{ action='raw'; more=@{ text=('{"schemaVersion":1,"modelId":"model-b" '+$marker) }; code='switch-request-invalid'; to=$null }
    )
    $steps=@();$wait=@{ phase='ready'; modelId='model-a' }
    foreach ($refusal in $refusals) {
        $steps+=(New-Step $wait $refusal.action $refusal.more)
        $wait=@{ phase='ready'; modelId='model-a'; switchResult='refused'; switchFailureCode=$refusal.code }
        if ($refusal.ContainsKey('after')) { $steps+=(New-Step $wait $refusal.after); $wait=$null }
    }
    $steps+=(New-Step $wait 'stop')
    $r=Invoke-SwitchScenario -Label 'refused' -World $world -Steps $steps
    Check ($r.completed -and $null -eq $r.failure -and $r.exit -eq 0 -and @($r.steps | Where-Object { $null -ne $_.error }).Count -eq 0) 'refused requests: every unsafe, oversized, malformed or unusable request was answered and the start ended 0 on stop'
    Check ($r.runs.Count -eq 1 -and (@(Get-ModeStarts $world 'model-a')).Count -eq 1 -and (@(Get-ModeStarts $world 'model-b')).Count -eq 0 -and @($r.observations | Where-Object { $_.runId } | ForEach-Object { $_.runId } | Select-Object -Unique).Count -eq 1 -and ($r.events -join ',') -notmatch 'plan:model-b|hash:model-b|supervisor:model-b') 'refused requests: the running server was never stopped, and nothing was planned, hashed or started for a refused target'
    $seen=@($r.observations | Where-Object { $null -ne $_.switch } | ForEach-Object { $_.switch })
    $mismatch=@()
    foreach ($refusal in $refusals) {
        if (@($seen | Where-Object { Test-Block $_ 'model-a' $refusal.to 'refused' $refusal.code $false }).Count -lt 1) { $mismatch+=$refusal.code }
    }
    Check ($mismatch.Count -eq 0) ('refused requests: each refusal is shown as switch = { from, to (a catalog id or null), result refused, failureCode } [' + ($mismatch -join ',') + ']')
    Check ((ConvertTo-Json -InputObject $seen -Depth 4 -Compress) -notmatch 'followed|model-b') 'refused requests: the reparse point was not followed (its valid request for model-b never appears)'
    $logA=@(Get-RunLog $world $r.runs[0].runId)
    $codes=(@(Get-LogEvents $logA 'switch-result') | ForEach-Object { [string]$_.result + ':' + [string]$_.failureCode }) -join ','
    Check ($codes -ceq ((@($refusals | ForEach-Object { 'refused:' + $_.code })) -join ',')) "refused requests: the run log has one switch-result per request, with the code only [$codes]"
    $logged=@(Get-LogEvents $logA 'switch-request')
    Check ($logged.Count -eq $refusals.Count -and @($logged | Where-Object { $_.fromModelId -cne 'model-a' }).Count -eq 0 -and ((@($logged | ForEach-Object { [string](Get-Field $_ 'toModelId') }) -join ',') -ceq ',,,,,model-c,model-d,model-e,model-a,,')) 'refused requests: switch-request names the target only when it is a catalog id'
    Check (@(Find-MarkerFiles $world).Count -eq 0) 'refused requests: text from a request (an unknown id, an extra field, broken JSON) is in no status document and no log'
    Check ((Test-Path -LiteralPath $followed) -and (Test-Path -LiteralPath (Join-Path $world.models 'model-a.gguf')) -and @(Get-ChildItem -LiteralPath $world.state -Force | Where-Object { $_.Name -like 'switch-*' }).Count -eq 0) 'refused requests: what the reparse point pointed at is untouched and no request file is left'
    $switchKeys=[string](@(Get-ReadyObservations $r $r.runs[0].runId)[0].keys)
    Check ($r.runs[0].bound -ceq $switchSupervisorBound -and ((@($switchKeys -split ',') | Where-Object { (@($defaultKeys -split ',')) -cnotcontains $_ }) -join ',') -ceq 'switchAllowed' -and (@(@($defaultKeys -split ',') | Where-Object { (@($switchKeys -split ',')) -cnotcontains $_ })).Count -eq 0) 'status: with -AllowSwitch and no switch, the only field added to the default document is switchAllowed'

    # ================= the API key (opt-in) with a model switch =================
    # With the key on, the server answers /metrics only with the key, so the busy read of a switch carries it (the run's keyed sender, as the
    # idle read does), and every start of a sequence - the first, the target, the restore - reads the key store itself and gives its own
    # server the key through the environment only. A fake protector and generated marker keys; the mock enforces the key as llama-server does
    # and records what each request carried in <diagnostic>.auth (never the key).
    $keyProtector=@{
        Protect={ param([byte[]]$Bytes) $out=New-Object 'System.Collections.Generic.List[byte]';$out.AddRange([byte[]](0x46,0x4B,0x31));foreach($b in $Bytes){$out.Add([byte]($b -bxor 0x5A))};return ,($out.ToArray()) }
        Unprotect={ param([byte[]]$Bytes) if($Bytes.Length -lt 4 -or $Bytes[0] -ne 0x46 -or $Bytes[1] -ne 0x4B -or $Bytes[2] -ne 0x31){throw 'fake protector: not protected data'};$out=New-Object 'System.Collections.Generic.List[byte]';for($i=3;$i -lt $Bytes.Length;$i++){$out.Add([byte]($Bytes[$i] -bxor 0x5A))};return ,($out.ToArray()) }
    }
    $keyMarker='fl-'+('LEAKMARKER'*3)+'switchKEY'+'Zq7_'
    if ($keyMarker.Length -ne 46) { throw 'the switch-test marker is not a well-formed key' }
    $keyWords=@('LEAKMARKER','Zq7_')
    $keyHolder=New-Object Security.SecureString;foreach($c in $keyMarker.ToCharArray()){$keyHolder.AppendChar($c)};$keyHolder.MakeReadOnly()
    function Get-KeyTestListenerOwners([int]$Port) {
        $found=New-Object 'System.Collections.Generic.List[int]'
        foreach ($line in @(& lsof -nP "-iTCP@127.0.0.1:$Port" -sTCP:LISTEN -Fp 2>$null)) { if ([string]$line -match '^p(\d+)$') { $value=[int]$Matches[1]; if (-not $found.Contains($value)) { $found.Add($value) } } }
        return $found.ToArray()
    }
    function New-KeyWorld([string]$Label,[hashtable]$Modes,[string]$KeyMode) {
        $keyWorld=New-SwitchWorld $Label $Modes
        Use-World $keyWorld
        & $module { param($R,$K) Write-FastLlmApiKeyStore -InstallRoot $R -ApiKeyHolder $K } $keyWorld.root $keyHolder
        $st.serverExtra=@('-DiagnosticPath',(Join-Path $keyWorld.root 'mock-diagnostic.txt'),'-KeyMode',$KeyMode)
        return $keyWorld
    }
    function Get-KeyAuth($World) { $path=Join-Path $World.root 'mock-diagnostic.txt.auth'; if (Test-Path -LiteralPath $path) { return @([IO.File]::ReadAllLines($path) | Where-Object { $_ }) }; return @() }
    # Every file of the world (status, run logs, state) and whatever the start raised: a key or its tail anywhere is a leak.
    function Find-KeyLeaks($Scenario) {
        $hits=@()
        foreach ($file in @(Get-ChildItem -LiteralPath $Scenario.world.root -Recurse -File -Force -ErrorAction SilentlyContinue)) {
            $text=[Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($file.FullName))
            foreach ($word in $keyWords) { if ($text.IndexOf($word,[StringComparison]::Ordinal) -ge 0) { $hits+=($file.Name+' :: '+$word) } }
        }
        $spoken=''
        if ($null -ne $Scenario.failure) { $spoken=$Scenario.failure.ToString()+'|'+[string]$Scenario.failure.Message }
        $spoken+='|'+($st.writes -join '|')
        foreach ($word in $keyWords) { if ($spoken.IndexOf($word,[StringComparison]::Ordinal) -ge 0) { $hits+=('failure text or a status document :: '+$word) } }
        return @($hits)
    }
    $keyId=[string](& $module { param($K) Get-FastLlmApiKeyId -ApiKeyHolder $K } $keyHolder)
    $keySupervisorBound='AllowSwitch,ApiKeyHolder,CatalogPath,InstallRoot,LoadTimeoutSeconds,Plan,SelfTest,SwitchContext'
    & $module { param($P) $script:FastLlmApiKeyProtector=$P } $keyProtector
    if ($env:OS -ne 'Windows_NT') { & $module { param($P) $script:FastLlmApiKeyListenerOwners=$P } ${function:Get-KeyTestListenerOwners} }
    # A key variable inherited by this process must never reach a server: each one gets the stored key, set by the one environment builder.
    $savedInheritedKey=[Environment]::GetEnvironmentVariable('LLAMA_API_KEY')
    [Environment]::SetEnvironmentVariable('LLAMA_API_KEY','hostile-inherited-value')
    try {
        # ---- key on: a non-forced switch on an idle server is accepted ----
        Set-BusyWait 60 200
        $world=New-KeyWorld 'key-switch' @{ 'model-a'=@('selftest-ok'); 'model-b'=@('selftest-ok') } 'enforce'
        $r=Invoke-SwitchScenario -Label 'key-switch' -World $world -StartOptions @{ SelfTest=$true; ApiKey='on' } -Steps @(
            (New-Step @{ phase='ready'; modelId='model-a' } 'switch' @{ modelId='model-b' }),
            (New-Step @{ phase='ready'; modelId='model-b'; switchResult='ok' } 'stop'))
        Check ($r.completed -and $null -eq $r.failure -and $r.exit -eq 0 -and (($r.runs | ForEach-Object { $_.modelId }) -join ',') -ceq 'model-a,model-b') 'api key + switch: with the key on, a non-forced switch on an idle server is accepted (the busy read of /metrics carried the key)'
        $auth=@(Get-KeyAuth $world)
        Check (@($auth | Where-Object { $_ -ceq 'env key-present' }).Count -eq 2 -and @($auth | Where-Object { $_ -cmatch ' wrong$' }).Count -eq 0 -and @($auth | Where-Object { $_ -ceq 'GET /metrics ok' }).Count -ge 1 -and @($auth | Where-Object { $_ -ceq 'GET /metrics none' }).Count -eq 0) "api key + switch: both servers got the stored key through their environment (not the inherited value), and every /metrics read carried it [$(@($auth | Where-Object { $_ -like '*metrics*' } | Select-Object -Unique) -join ',')]"
        Check ($r.runs[0].bound -ceq $keySupervisorBound -and $r.runs[1].bound -ceq $keySupervisorBound) 'api key + switch: the target model''s start was given the key exactly like the first start'
        $finalA=Get-RunFinal $r.runs[0];$finalB=Get-RunFinal $r.runs[1]
        Check ([string]$finalA.apiKey -ceq 'on' -and [string]$finalA.apiKeyId -ceq $keyId -and [string]$finalB.apiKey -ceq 'on' -and [string]$finalB.apiKeyId -ceq $keyId -and (Test-Block (Get-Block $finalB) 'model-a' 'model-b' 'ok' $null $false)) 'api key + switch: each run proved the key (401 without, 200 with) before its status said apiKey on; the switch block says ok'
        $unkeyed=@($auth | Where-Object { $_ -cmatch ' none$' -and $_ -cnotmatch '/health ' } | Select-Object -Unique)
        Check (($unkeyed -join ',') -ceq 'GET /props none' -and @($auth | Where-Object { $_ -ceq 'GET /props none' }).Count -eq 2) "api key + switch: the only requests without the key were the two proofs' own (one per server) [$($unkeyed -join ',')]"
        $leaks=@(Find-KeyLeaks $r)
        Check ($leaks.Count -eq 0 -and (@($r.events) -join ',') -cnotmatch 'LEAKMARKER') "api key + switch: no key text in any status document, run log, state file or failure [$($leaks -join '; ')]"

        # ---- key on: switch, the target fails, the previous model is restored ----
        $world=New-KeyWorld 'key-restore' @{ 'model-a'=@('selftest-ok','selftest-ok'); 'model-b'=@('ok') } 'enforce'
        $r=Invoke-SwitchScenario -Label 'key-restore' -World $world -StartOptions @{ SelfTest=$true; ApiKey='on' } -Steps @(
            (New-Step @{ phase='ready'; modelId='model-a' } 'switch' @{ modelId='model-b' }),
            (New-Step @{ phase='ready'; modelId='model-a'; switchResult='failed-restored' } 'stop'))
        Check ($r.completed -and $null -eq $r.failure -and $r.exit -eq 0 -and (($r.runs | ForEach-Object { $_.modelId }) -join ',') -ceq 'model-a,model-b,model-a' -and $r.runs[1].failed -and -not $r.runs[2].failed) 'api key + restore: with the key on, a failed target is followed by the one restore of the previous model'
        $auth=@(Get-KeyAuth $world)
        Check (@($auth | Where-Object { $_ -ceq 'env key-present' }).Count -eq 3 -and @($auth | Where-Object { $_ -ceq 'env key-absent' }).Count -eq 0 -and @($auth | Where-Object { $_ -cmatch ' wrong$' }).Count -eq 0) 'api key + restore: all three servers (the first, the target, the restore) got the stored key through their environment'
        Check ((@($r.runs | ForEach-Object { $_.bound } | Select-Object -Unique) -join ';') -ceq $keySupervisorBound -and @($auth | Where-Object { $_ -ceq 'GET /props none' }).Count -eq 3) 'api key + restore: every start of the sequence was given the key like the first, and each ran the 401/200 proof'
        $restored=Get-RunFinal $r.runs[2]
        Check ([string]$restored.apiKey -ceq 'on' -and [string]$restored.apiKeyId -ceq $keyId -and (Test-Block (Get-Block $restored) 'model-a' 'model-b' 'failed-restored' 'self-test-failed' $false) -and (Test-PortFree $world.port)) 'api key + restore: the restored model serves with the key on, and the switch block says failed-restored'
        $leaks=@(Find-KeyLeaks $r)
        Check ($leaks.Count -eq 0) "api key + restore: no key text in any status document, run log, state file or failure [$($leaks -join '; ')]"

        # ---- key on, but the read is refused (a wrong key at the server): the switch stays refused-busy ----
        Set-BusyWait 2 200
        $world=New-KeyWorld 'key-refused' @{ 'model-a'=@('ok'); 'model-b'=@('ok') } 'metrics-401'
        $r=Invoke-SwitchScenario -Label 'key-refused' -World $world -StartOptions @{ ApiKey='on' } -Steps @(
            (New-Step @{ phase='ready'; modelId='model-a' } 'switch' @{ modelId='model-b' }),
            (New-Step @{ phase='ready'; modelId='model-a'; switchResult='refused-busy' } 'stop'))
        Set-BusyWait 60 200
        Check ($r.completed -and $null -eq $r.failure -and $r.exit -eq 0 -and (($r.runs | ForEach-Object { $_.modelId }) -join ',') -ceq 'model-a') 'api key, read refused: when the server refuses the /metrics read (401), the switch is not forced through: the same model keeps serving'
        $auth=@(Get-KeyAuth $world)
        Check (@($auth | Where-Object { $_ -ceq 'GET /metrics ok' }).Count -ge 2 -and @($auth | Where-Object { $_ -ceq 'env key-present' }).Count -eq 1 -and (@(Get-ModeStarts $world 'model-b')).Count -eq 0) 'api key, read refused: the reads carried the key and were refused; the target was never started'
        $refusedReady=@(Get-ReadyObservations $r $r.runs[0].runId | Where-Object { $null -ne $_.switch -and (Get-Field $_.switch 'result') -ceq 'refused-busy' })
        Check ($refusedReady.Count -ge 1 -and (Test-Block $refusedReady[0].switch 'model-a' 'model-b' 'refused-busy' $null $false)) 'api key, read refused: the status shows switch = { result refused-busy }'
        $logA=@(Get-RunLog $world $r.runs[0].runId)
        Check ((@(Get-LogEvents $logA 'switch-result') | ForEach-Object { [string]$_.result }) -join ',' -ceq 'refused-busy') 'api key, read refused: the run log has the one refusal'
        $leaks=@(Find-KeyLeaks $r)
        Check ($leaks.Count -eq 0) "api key, read refused: no key text in the status, the run log or the failure text [$($leaks -join '; ')]"

        # ---- key on: 'switch' asked of an install whose server was stopped by the idle stop ----
        # No server is running, so the CLI makes the request a normal start with switching allowed. That start is a keyed start like any
        # other. The CLI's own statements run here, taken from fast-llm.ps1: the ones that decide the action, and the serving block that
        # reads the saved key flag for the action that will run. What they give is then started for real against the mock.
        . (Join-Path $root 'src/FastLlm.ServingSettings.ps1')
        $cliErrors=$null;$cliTokens=$null
        $cliTree=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'fast-llm.ps1'),[ref]$cliTokens,[ref]$cliErrors)
        $cliActionFunction=@($cliTree.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-FastLlmSwitchCliAction' },$true))
        $cliActionLines=@($cliTree.FindAll({ param($node) ($node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Extent.Text -cin @('$effectiveAction = [string] $Action','$effectiveSwitchAllowed = [bool] $SwitchAllowed')) -or ($node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -ceq "`$Action -eq 'switch'") },$true) | Sort-Object { $_.Extent.StartOffset })
        $cliServing=@($cliTree.FindAll({ param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -ceq "`$effectiveAction -in @('plan', 'install', 'start', 'doctor')" },$true))
        $cliSameBlock=($cliActionLines.Count -eq 3 -and $cliServing.Count -eq 1 -and @($cliActionLines | Where-Object { [object]::ReferenceEquals($_.Parent,$cliServing[0].Parent) }).Count -eq 3)
        Check (@($cliErrors).Count -eq 0 -and $cliActionFunction.Count -eq 1 -and $cliSameBlock -and $cliActionLines[2] -is [Management.Automation.Language.IfStatementAst] -and $cliActionLines[2].Extent.StartOffset -lt $cliServing[0].Extent.StartOffset -and $cliServing[0].Extent.Text.Contains("if ([string] `$servingOptions.apiKey -ceq 'on') { `$effectiveApiKey = 'on' }")) 'api key + idle-stopped switch: fast-llm.ps1 decides the action first, and reads the saved key flag after it, for the action that will run'
        $cliStartOptionLines="if (`$effectiveSwitchAllowed) { `$startPolicyOptions.AllowSwitch = `$true }","if (`$effectiveApiKey -ceq 'on') { `$startPolicyOptions.ApiKey = 'on' }"
        $cliText=[IO.File]::ReadAllText((Join-Path $root 'fast-llm.ps1'))
        Check (@($cliStartOptionLines | Where-Object { ([regex]::Matches($cliText,[regex]::Escape($_))).Count -eq 1 }).Count -eq 2 -and $cliText -cnotmatch 'startPolicyOptions\.ApiKeyHolder') 'api key + idle-stopped switch: the start is handed switching and the key flag from those two values, each on its own line (never the key)'
        . ([scriptblock]::Create($cliActionFunction[0].Extent.Text))
        $cliResolve=[scriptblock]::Create(((@($cliActionLines | ForEach-Object { $_.Extent.Text })+@($cliServing[0].Extent.Text)) -join "`n"))
        function Resolve-KeyCliStart([string]$Action,[string]$InstallRoot) {
            $SwitchAllowed=[switch]$false;$IgnoreUserSettings=[switch]$false;$DryRun=[switch]$false;$AsJson=[switch]$false;$selectionOptions=@{}
            $effectiveAction=$null;$effectiveSwitchAllowed=$null;$effectiveApiKey=$null
            $said=@(. $cliResolve 6>&1 | ForEach-Object { [string]$_ })
            return @{ action=$effectiveAction; switchAllowed=$effectiveSwitchAllowed; apiKey=$effectiveApiKey; selection=$selectionOptions; said=$said }
        }
        $world=New-KeyWorld 'key-idle-start' @{ 'model-a'=@('selftest-ok'); 'model-b'=@('selftest-ok') } 'enforce'
        $setting=Invoke-FastLlmApiKeySetting -InstallRoot $world.root -Action on
        Write-FastLlmState -InstallRoot $world.root -State ([ordered]@{ schemaVersion=1; runId=[Guid]::NewGuid().ToString('N'); phase='stopped'; stopReason='idle'; idleStopMinutes=30; modelId='model-a' })
        $idleStatus=Get-FastLlmStatus -InstallRoot $world.root
        Check ([string]$setting.apiKey -ceq 'on' -and -not [bool]$setting.created -and [string]$setting.apiKeyId -ceq $keyId -and [string]$idleStatus.phase -ceq 'stopped' -and [string]$idleStatus.stopReason -ceq 'idle' -and -not [bool]$idleStatus.active) 'api key + idle-stopped switch: the install has the key setting on, a stored key, and a server that the idle stop stopped'
        $cli=Resolve-KeyCliStart 'switch' $world.root
        Check ($cli.action -ceq 'start' -and $cli.switchAllowed -eq $true -and $cli.apiKey -ceq 'on' -and $cli.selection.Count -eq 0 -and (@($cli.said) -join '|') -ceq 'No FastLLM server is running, so this is a normal start of the requested model, with model switching allowed.') "api key + idle-stopped switch: switch with no server running is the start action with switching allowed AND the key on (the planner is told nothing about the key) [$($cli.action)/$($cli.switchAllowed)/$($cli.apiKey)]"
        $idleStart=@{ SelfTest=$true }
        if ($cli.apiKey -ceq 'on') { $idleStart.ApiKey='on' }
        $r=Invoke-SwitchScenario -Label 'key-idle-start' -World $world -StartOptions $idleStart -NoAllowSwitch:(-not $cli.switchAllowed) -Steps @(
            (New-Step @{ phase='ready'; modelId='model-a' } 'switch' @{ modelId='model-b' }),
            (New-Step @{ phase='ready'; modelId='model-b'; switchResult='ok' } 'stop'))
        Check ($r.completed -and $null -eq $r.failure -and $r.exit -eq 0 -and (($r.runs | ForEach-Object { $_.modelId }) -join ',') -ceq 'model-a,model-b' -and $r.runs[0].bound -ceq $keySupervisorBound) 'api key + idle-stopped switch: the start that follows is given the key and switching, exactly like a keyed start asked for directly (and a later switch works)'
        $auth=@(Get-KeyAuth $world)
        $proofWithout=[Array]::IndexOf([string[]]$auth,'GET /props none');$proofWith=[Array]::IndexOf([string[]]$auth,'GET /props ok')
        $firstKeyed=-1;for($i=0;$i -lt $auth.Count;$i++){ if ($auth[$i] -cmatch ' ok$') { $firstKeyed=$i;break } }
        Check ($auth[0] -ceq 'env key-present' -and $proofWithout -ge 0 -and $proofWith -eq ($proofWithout+1) -and $firstKeyed -eq $proofWith -and @($auth | Where-Object { $_ -cmatch ' wrong$' }).Count -eq 0) "api key + idle-stopped switch: the server got the stored key through its environment, and the 401/200 proof ran (without the key, then with it) before any other keyed request [$(@($auth | Select-Object -First 6) -join ',')]"
        $idleFinal=Get-RunFinal $r.runs[0]
        $unkeyed=@($auth | Where-Object { $_ -cmatch ' none$' -and $_ -cnotmatch '/health ' } | Select-Object -Unique)
        Check ([string]$idleFinal.apiKey -ceq 'on' -and [string]$idleFinal.apiKeyId -ceq $keyId -and ($unkeyed -join ',') -ceq 'GET /props none' -and @($auth | Where-Object { $_ -ceq 'GET /props none' }).Count -eq 2) "api key + idle-stopped switch: the status says apiKey on with the key id, and the only requests without the key were the proofs' own [$($unkeyed -join ',')]"
        $leaks=@(Find-KeyLeaks $r)
        Check ($leaks.Count -eq 0) "api key + idle-stopped switch: no key text in any status document, run log, state file or failure [$($leaks -join '; ')]"
        # With the key setting off, the same request is the same start without a key.
        $world=New-KeyWorld 'key-idle-off' @{ 'model-a'=@('ok') } 'enforce'
        Invoke-FastLlmApiKeySetting -InstallRoot $world.root -Action off | Out-Null
        $cli=Resolve-KeyCliStart 'switch' $world.root
        Check ($cli.action -ceq 'start' -and $cli.switchAllowed -eq $true -and $cli.apiKey -ceq 'off') 'api key + idle-stopped switch: with the key setting off the same request is a start with switching allowed and no key'

        # ---- the saved flag, as the command line reads it (M1) ----
        # An installation that never had a key store starts without a key whatever its settings.json holds (none, empty, other settings
        # only). A key store with no stored value is not "off": the flag cannot be known, and the start refuses it.
        $flagShapes=[ordered]@{ 'no settings.json'=$null; 'an empty object'='{}'; 'other settings only'='{ "serverPort": 18181, "thinking": "off" }' }
        foreach ($flagShape in $flagShapes.Keys) {
            $plainRoot=Join-Path $temp ('flag-plain-'+[Guid]::NewGuid().ToString('N').Substring(0,8));New-Item -ItemType Directory -Path $plainRoot | Out-Null
            if ($null -ne $flagShapes[$flagShape]) { [IO.File]::WriteAllText((Join-Path $plainRoot 'settings.json'),[string]$flagShapes[$flagShape]) }
            $plainCli=Resolve-KeyCliStart 'start' $plainRoot
            $keyedRoot=Join-Path $temp ('flag-keyed-'+[Guid]::NewGuid().ToString('N').Substring(0,8));New-Item -ItemType Directory -Path $keyedRoot | Out-Null
            & $module { param($R,$K) Write-FastLlmApiKeyStore -InstallRoot $R -ApiKeyHolder $K } $keyedRoot $keyHolder
            if ($null -ne $flagShapes[$flagShape]) { [IO.File]::WriteAllText((Join-Path $keyedRoot 'settings.json'),[string]$flagShapes[$flagShape]) }
            $keyedCli=Resolve-KeyCliStart 'start' $keyedRoot
            $keyedSwitch=Resolve-KeyCliStart 'switch' $keyedRoot
            Check ($plainCli.action -ceq 'start' -and $plainCli.apiKey -ceq 'off' -and $keyedCli.apiKey -ceq 'undetermined' -and $keyedSwitch.action -ceq 'start' -and $keyedSwitch.apiKey -ceq 'undetermined') "saved flag ($flagShape): with no key store the command line reads off (a keyless start, as always); with a key store it reads undetermined, for start and for switch-as-start [$($plainCli.apiKey)/$($keyedCli.apiKey)/$($keyedSwitch.apiKey)]"
        }
        Check ($cliText.Contains("if (`$effectiveApiKey -ceq 'undetermined') { throw (New-FastLlmApiKeySettingFailure) }") -and $cliText.IndexOf("if (`$effectiveApiKey -ceq 'undetermined') { throw (New-FastLlmApiKeySettingFailure) }") -lt $cliText.IndexOf('$startPolicyOptions.AllowSwitch = $true')) 'saved flag: the start refuses undetermined (api-key-setting-unreadable) before it builds its start options'

        # ---- L1 in a switch: the target's key may have gone to another program, so the previous model is NOT started again ----
        # The listener is the target's own server before the first keyed request of its start (the proof) and something else right after
        # it. That start fails with api-key-listener-changed, and the sequence ends there: a restore would serve with the same key.
        function Get-KeyRealListenerOwners([int]$Port) {
            if ($env:OS -ne 'Windows_NT') { return @(Get-KeyTestListenerOwners $Port) }
            if (-not ('Bitworks.FastLlm.WindowsGpuTelemetry' -as [type])) { Add-Type -Path (Join-Path $root 'src/WindowsGpuTelemetry.cs') }
            return @([Bitworks.FastLlm.WindowsGpuTelemetry]::GetLoopbackListenerOwners($Port))
        }
        $world=New-KeyWorld 'key-exposed' @{ 'model-a'=@('selftest-ok','selftest-ok'); 'model-b'=@('selftest-ok') } 'enforce'
        $script:keyExposure=@{ world=$world; reads=0; changed=$false }
        & $module { param($P) $script:FastLlmApiKeyListenerOwners=$P } {
            param($Port)
            if ($script:keyExposure.changed) { return @(4242) }
            if (@(Get-ModeStarts $script:keyExposure.world 'model-b').Count -gt 0) {
                $script:keyExposure.reads++
                if ($script:keyExposure.reads -eq 2) { $script:keyExposure.changed=$true; return @(4242) }
            }
            return @(Get-KeyRealListenerOwners $Port)
        }
        try {
            $r=Invoke-SwitchScenario -Label 'key-exposed' -World $world -StartOptions @{ SelfTest=$true; ApiKey='on' } -Steps @(
                (New-Step @{ phase='ready'; modelId='model-a' } 'switch' @{ modelId='model-b' }),
                (New-Step @{ switchResult='failed-stopped' } 'none'))
        }
        finally {
            if ($env:OS -ne 'Windows_NT') { & $module { param($P) $script:FastLlmApiKeyListenerOwners=$P } ${function:Get-KeyTestListenerOwners} } else { & $module { $script:FastLlmApiKeyListenerOwners=$null } }
        }
        $exposedCode='';$exposedText=''
        if ($null -ne $r.failure) { $exposedCode=[string]$r.failure.Data['FastLlmFailureCode'];$exposedText=[string]$r.failure.Message }
        Check ($r.completed -and $exposedCode -ceq 'api-key-listener-changed' -and (($r.runs | ForEach-Object { $_.modelId }) -join ',') -ceq 'model-a,model-b' -and $r.runs[1].failed -and $script:keyExposure.changed) "api key, listener changed in a switch: the target's start fails with api-key-listener-changed and the previous model is not started again (runs: $((($r.runs | ForEach-Object { $_.modelId }) -join ',')); code: $exposedCode)"
        Check ($exposedText -cmatch 'Another program may have received the key' -and $exposedText -cmatch 'Create a new key' -and [string]$r.failure.Data['FastLlmReason'] -ceq 'ApiKeyFailed' -and $r.failure.Data['FastLlmSwitchAttempted'] -eq $true) 'api key, listener changed in a switch: the failure says to create a new key, and is final (never retried, recovered or replaced)'
        Check ((Test-Block (Get-Block $r.final) 'model-a' 'model-b' 'failed-stopped' 'api-key-listener-changed' $false) -and [string]$r.final.phase -ceq 'failed' -and (Test-PortFree $world.port) -and (@(Get-ModeStarts $world 'model-a')).Count -eq 1) 'api key, listener changed in a switch: the status says failed-stopped with the code, nothing is served, and the first model was started once only'
        $auth=@(Get-KeyAuth $world)
        Check (@($auth | Where-Object { $_ -ceq 'env key-present' }).Count -eq 2 -and @($auth | Where-Object { $_ -cmatch ' wrong$' }).Count -eq 0) 'api key, listener changed in a switch: two servers were started (the first and the target), never a third'
        $leaks=@(Find-KeyLeaks $r)
        Check ($leaks.Count -eq 0) "api key, listener changed in a switch: no key text in any status document, run log, state file or failure [$($leaks -join '; ')]"

    } finally {
        [Environment]::SetEnvironmentVariable('LLAMA_API_KEY',$savedInheritedKey)
        & $module { $script:FastLlmApiKeyProtector=$null; $script:FastLlmApiKeyListenerOwners=$null }
        Set-BusyWait 60 200
        $st.serverExtra=@()
    }
    $pollText=& $module { (Get-Command Step-FastLlmSwitchPoll).ScriptBlock.ToString() }
    $startText=& $module { (Get-Command Start-FastLlmServer).ScriptBlock.ToString() }
    Check ($pollText.Contains('Get-FastLlmIdleMetricsText -BaseUrl $BaseUrl -Request $MetricsRequest') -and $startText.Contains("if (`$ApiKey -ceq 'on') { `$switchStartOptions.ApiKey = 'on' }") -and $startText -cnotmatch 'switchStartOptions\.ApiKeyHolder') 'api key + switch: the busy read takes the run''s sender, and a start inside a sequence is handed only the flag (it reads the store itself)'
    # ================= the switch basis (state\switch-basis-<runId>.json): writer and strict reader =================
    $basisUnit=New-SwitchWorld 'basis-unit'
    Use-World $basisUnit
    $basisRunId='d'*32
    $validHardware=[pscustomobject]@{ schemaVersion=1; source='switch-test'; backend='Vulkan'; enginePath=(Join-Path (Join-Path $basisUnit.root 'engines') 'mock-engine')
        adapters=@([pscustomobject]@{ device='Vulkan0'; name='Switch Test Adapter'; vendorId='1002'; vramMiB=24000; freeVramMiB=20000; driverVersion='test'; backend='Vulkan'; isAmd=$true; isIntegrated=$false }) }
    $basisPath=Join-Path $basisUnit.state ('switch-basis-'+$basisRunId+'.json')
    function Write-Basis($Hardware,[string]$RunId=$basisRunId,$PlanOptions=@{ Profile='balanced' }) { return (& $module { param($I,$R,$H,$O) Write-FastLlmSwitchBasis -InstallRoot $I -RunId $R -Hardware $H -PlanOptions $O } $basisUnit.root $RunId $Hardware $PlanOptions) }
    function Read-Basis([string]$RunId=$basisRunId) { return (& $module { param($I,$R) Read-FastLlmSwitchBasis -InstallRoot $I -RunId $R } $basisUnit.root $RunId) }
    function Write-RawBasis([string]$Text,[string]$RunId=$basisRunId) { [IO.File]::WriteAllText((Join-Path $basisUnit.state ('switch-basis-'+$RunId+'.json')),$Text,(New-Object Text.UTF8Encoding($false))) }
    function Remove-RawBasis([string]$RunId=$basisRunId) { $rawPath=Join-Path $basisUnit.state ('switch-basis-'+$RunId+'.json'); if (Test-Path -LiteralPath $rawPath) { [IO.File]::Delete($rawPath) } }
    function New-BasisText([hashtable]$Override=@{},[string[]]$Drop=@()) {
        $document=[ordered]@{ schemaVersion=1; runId=$basisRunId; capturedAt=(Get-Date).ToUniversalTime().ToString('o'); hardware=$validHardware; planOptions=[pscustomobject]@{ Profile='balanced'; ServerPort=18080; Thinking='off' } }
        foreach ($key in $Override.Keys) { $document[$key]=$Override[$key] }
        foreach ($key in $Drop) { $document.Remove($key) }
        return (ConvertTo-Json -InputObject $document -Depth 8)
    }
    $wrote=Write-Basis $validHardware
    $basisDocument=Read-FastLlmJson -Path $basisPath
    Check ($wrote -eq $true -and (Test-Path -LiteralPath $basisPath -PathType Leaf)) 'basis: a valid reading is written to state\switch-basis-<runId>.json'
    Check ((@($basisDocument.PSObject.Properties.Name | Sort-Object) -join ',') -ceq 'capturedAt,hardware,planOptions,runId,schemaVersion' -and [int]$basisDocument.schemaVersion -eq 1 -and $basisDocument.runId -ceq $basisRunId) 'basis: the file holds exactly schemaVersion 1, runId, capturedAt, hardware and planOptions'
    $capturedMatch=[regex]::Match([IO.File]::ReadAllText($basisPath),'"capturedAt":\s*"(\d{4}-\d{2}-\d{2}T[0-9:.]+Z)"')
    $capturedAt=[datetime]::MinValue
    Check ($capturedMatch.Success -and [datetime]::TryParse($capturedMatch.Groups[1].Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AdjustToUniversal,[ref]$capturedAt)) 'basis: capturedAt is a UTC ISO time'
    Check ((Get-Item -LiteralPath $basisPath).Length -le 65536 -and @(Get-ChildItem -LiteralPath $basisUnit.state -Filter '*.tmp').Count -eq 0) 'basis: the file is at most 64 KiB and no temporary file is left'
    $basisText=[IO.File]::ReadAllText($basisPath)
    Check ($basisText -notmatch 'LLAMA_API_KEY|apikey|prompt' -and $basisText.IndexOf($root,[StringComparison]::OrdinalIgnoreCase) -lt 0) 'basis: no key, no prompt and no path outside the install is in the file'
    $basis=Read-Basis
    Check ($null -ne $basis -and $basis.runId -ceq $basisRunId -and [int]$basis.schemaVersion -eq 1 -and [int]@($basis.hardware.adapters)[0].freeVramMiB -eq 20000) 'basis: the reader returns the reading that was written'
    & $module { param($H) Assert-FastLlmHardware -Hardware $H } $basis.hardware
    Check $true 'basis: what the reader returns passes Assert-FastLlmHardware'
    Check ($null -eq (Read-Basis ('e'*32))) 'basis: a run with no file reads as null'
    Check ($null -eq (Read-Basis 'not-a-run-id') -and $null -eq (Read-Basis '')) 'basis: a run id that is not 32 lowercase hex characters reads as null'
    Remove-RawBasis
    Write-RawBasis (New-BasisText @{ runId=('f'*32) })
    Check ($null -eq (Read-Basis)) 'basis: a file whose own runId is not the run it is read for reads as null'
    $padded=New-BasisText
    Remove-RawBasis; Write-RawBasis ($padded+(' '*(65536-[Text.Encoding]::UTF8.GetByteCount($padded))))
    Check ((Get-Item -LiteralPath $basisPath).Length -eq 65536 -and $null -ne (Read-Basis)) 'basis: a file of exactly 65536 bytes is read'
    Remove-RawBasis; Write-RawBasis ($padded+(' '*(65537-[Text.Encoding]::UTF8.GetByteCount($padded))))
    Check ((Get-Item -LiteralPath $basisPath).Length -eq 65537 -and $null -eq (Read-Basis)) 'basis: a file of 65537 bytes reads as null (64 KiB cap)'
    foreach ($case in @(
        @{ name='schemaVersion 2'; text=(New-BasisText @{ schemaVersion=2 }) },
        @{ name='schemaVersion as text'; text=(New-BasisText @{ schemaVersion='1' }) },
        @{ name='no schemaVersion'; text=(New-BasisText @{} @('schemaVersion')) },
        @{ name='no runId'; text=(New-BasisText @{} @('runId')) },
        @{ name='no capturedAt'; text=(New-BasisText @{} @('capturedAt')) },
        @{ name='a capturedAt that is not a time'; text=(New-BasisText @{ capturedAt='yesterday-ish' }) },
        @{ name='no hardware'; text=(New-BasisText @{} @('hardware')) },
        @{ name='hardware with no adapters'; text=(New-BasisText @{ hardware=[pscustomobject]@{ backend='Vulkan'; adapters=@() } }) },
        @{ name='hardware with an impossible free number'; text=(New-BasisText @{ hardware=[pscustomobject]@{ backend='Vulkan'; adapters=@([pscustomobject]@{ device='Vulkan0'; name='x'; vramMiB=100; freeVramMiB=200; backend='Vulkan'; isAmd=$true }) } }) },
        @{ name='hardware with an unknown backend'; text=(New-BasisText @{ hardware=[pscustomobject]@{ backend='Metal'; adapters=@([pscustomobject]@{ device='Vulkan0'; name='x'; vramMiB=100; freeVramMiB=50; backend='Metal'; isAmd=$true }) } }) },
        @{ name='an extra field'; text=(New-BasisText @{ prompt='hello' }) },
        @{ name='no planOptions'; text=(New-BasisText @{} @('planOptions')) },
        @{ name='planOptions that is not an object'; text=(New-BasisText @{ planOptions='balanced' }) },
        @{ name='planOptions with an extra name'; text=(New-BasisText @{ planOptions=[pscustomobject]@{ Profile='balanced'; ModelId='model-b' } }) },
        @{ name='planOptions carrying a path'; text=(New-BasisText @{ planOptions=[pscustomobject]@{ Profile='balanced'; RecipesPath='C:\\x' } }) },
        @{ name='planOptions with no Profile'; text=(New-BasisText @{ planOptions=[pscustomobject]@{ Thinking='off' } }) },
        @{ name='a Profile that is not a profile'; text=(New-BasisText @{ planOptions=[pscustomobject]@{ Profile='turbo' } }) },
        @{ name='a Profile of the wrong type'; text=(New-BasisText @{ planOptions=[pscustomobject]@{ Profile=7 } }) },
        @{ name='a ServerPort of the wrong type'; text=(New-BasisText @{ planOptions=[pscustomobject]@{ Profile='balanced'; ServerPort='8080' } }) },
        @{ name='a ServerPort out of range'; text=(New-BasisText @{ planOptions=[pscustomobject]@{ Profile='balanced'; ServerPort=80 } }) },
        @{ name='a Thinking that is not a thinking value'; text=(New-BasisText @{ planOptions=[pscustomobject]@{ Profile='balanced'; Thinking='maybe' } }) },
        @{ name='a ChatPage of the wrong type'; text=(New-BasisText @{ planOptions=[pscustomobject]@{ Profile='balanced'; ChatPage=$true } }) },
        @{ name='KvSlots out of range'; text=(New-BasisText @{ planOptions=[pscustomobject]@{ Profile='balanced'; KvSlots=3 } }) },
        @{ name='a KvContextProfile that is not a profile'; text=(New-BasisText @{ planOptions=[pscustomobject]@{ Profile='balanced'; KvContextProfile='huge' } }) },
        @{ name='AllowExperimentalModel as text'; text=(New-BasisText @{ planOptions=[pscustomobject]@{ Profile='balanced'; AllowExperimentalModel='yes' } }) },
        @{ name='an array'; text=('['+(New-BasisText)+']') },
        @{ name='not JSON'; text='{"schemaVersion":1,' },
        @{ name='empty'; text='' }
    )) {
        Remove-RawBasis; Write-RawBasis $case.text
        Check ($null -eq (Read-Basis)) "basis: $($case.name) reads as null, never a partial object"
    }
    Remove-RawBasis
    $linkTargetBasis=Join-Path $basisUnit.root 'basis-link-target.json'
    [IO.File]::WriteAllText($linkTargetBasis,(New-BasisText),(New-Object Text.UTF8Encoding($false)))
    if ($env:OS -ceq 'Windows_NT') { New-Item -ItemType Junction -Path $basisPath -Target $basisUnit.models | Out-Null } else { New-Item -ItemType SymbolicLink -Path $basisPath -Target $linkTargetBasis | Out-Null }
    $linked=Read-Basis
    if ($env:OS -ceq 'Windows_NT') { [IO.Directory]::Delete($basisPath) } else { [IO.File]::Delete($basisPath) }
    Check ($null -eq $linked -and (Test-Path -LiteralPath $linkTargetBasis)) 'basis: a reparse point at the basis path reads as null and is not followed'
    $oversizeHardware=[pscustomobject]@{ schemaVersion=1; source='switch-test'; backend='Vulkan'; filler=('x'*70000); adapters=$validHardware.adapters }
    Check ((Write-Basis $validHardware $basisRunId @{ Profile='balanced'; ModelId='model-b' }) -eq $false -and (Write-Basis $validHardware $basisRunId $null) -eq $false -and -not (Test-Path -LiteralPath $basisPath)) 'basis: options that are not on the allowlist (or none) are not written'
    Check ((Write-Basis $oversizeHardware) -eq $false -and -not (Test-Path -LiteralPath $basisPath)) 'basis: a reading that would not fit in 64 KiB is not written'
    Check ((Write-Basis ([pscustomobject]@{ synthetic=$true })) -eq $false -and -not (Test-Path -LiteralPath $basisPath)) 'basis: a reading that fails Assert-FastLlmHardware is not written'
    Check ((Write-Basis $validHardware 'not-a-run-id') -eq $false -and @(Get-ChildItem -LiteralPath $basisUnit.state -Filter 'switch-basis-*').Count -eq 0) 'basis: no file is written for a run id that is not a run id'

    # ================= the switch basis in a real run: the reading the run's plan was built from, written once, removed at the end =================
    $world=New-SwitchWorld 'basis-run' @{ 'model-a'=@('ok'); 'model-b'=@('ok') }
    Use-World $world
    $r=Invoke-SwitchScenario -Label 'basis-run' -World $world -Steps @(
        (New-Step @{ phase='ready'; modelId='model-a' } 'switch' @{ modelId='model-b' }),
        (New-Step @{ phase='ready'; modelId='model-b'; switchResult='ok' } 'stop'))
    Check ($r.completed -and $null -eq $r.failure -and $r.runs.Count -eq 2) 'basis run: the start serves model-a, switches to model-b and ends on stop'
    $basisFiles=@($st.basisWrites | ForEach-Object { $_.FileName })
    Check ($basisFiles.Count -eq 2 -and $basisFiles[0] -ceq ('switch-basis-'+$r.runs[0].runId+'.json') -and $basisFiles[1] -ceq ('switch-basis-'+$r.runs[1].runId+'.json')) 'basis run: a run that allows switching writes its basis once at its start, under its own run id (one per run of the sequence)'
    $firstBasis=$st.basisWrites[0].Text | ConvertFrom-Json
    $secondBasis=$st.basisWrites[1].Text | ConvertFrom-Json
    Check ($firstBasis.runId -ceq $r.runs[0].runId -and $secondBasis.runId -ceq $r.runs[1].runId -and [int]$firstBasis.schemaVersion -eq 1) 'basis run: each basis names the run it was written for'
    # The plan a run was started from is the LAST plan made before its supervisor. Its reading is the one saved: the pre-load reading of the
    # first start, and for the switch target the fresh reading taken after the old server stopped (not the one before it).
    $planFree=@($st.planHardware | ForEach-Object { [int](@($_.adapters)[0].freeVramMiB) })
    $events=@($r.events)
    $supervisorIndexes=@(); for ($e=0; $e -lt $events.Count; $e++) { if ($events[$e] -clike 'supervisor:*') { $supervisorIndexes+=$e } }
    $planIndexes=@(); for ($e=0; $e -lt $events.Count; $e++) { if ($events[$e] -clike 'plan:*') { $planIndexes+=$e } }
    $lastPlanBefore=@(); foreach ($supervisorAt in $supervisorIndexes) { $lastPlanBefore+=@($planIndexes | Where-Object { $_ -lt $supervisorAt })[-1] }
    $planNumberOf=@{}; for ($n=0; $n -lt $planIndexes.Count; $n++) { $planNumberOf[$planIndexes[$n]]=$n }
    $firstRunFree=$planFree[$planNumberOf[$lastPlanBefore[0]]]
    $secondRunFree=$planFree[$planNumberOf[$lastPlanBefore[1]]]
    Check ([int]@($firstBasis.hardware.adapters)[0].freeVramMiB -eq $firstRunFree -and [int]@($secondBasis.hardware.adapters)[0].freeVramMiB -eq $secondRunFree -and $firstRunFree -ne $secondRunFree) 'basis run: each basis holds exactly the hardware its run''s own plan was built from (the pre-load reading; for the switch target the fresh reading taken after the old server stopped)'
    Check ($planFree.Count -eq 3 -and $secondRunFree -eq $planFree[2] -and $planFree[1] -ne $planFree[2]) 'basis run: the target''s basis is the reading of its own start, not the one the switch planned with before it'
    Check (@(Get-ChildItem -LiteralPath $world.state -Force | Where-Object { $_.Name -like 'switch-basis-*' }).Count -eq 0) 'basis run: every basis file is removed when its run ends, with the request file'
    Check (@(Find-MarkerFiles $world).Count -eq 0 -and ($firstBasis.PSObject.Properties.Name -join ',') -ceq 'schemaVersion,runId,capturedAt,hardware,planOptions') 'basis run: nothing but schemaVersion, runId, capturedAt, hardware and planOptions is saved'

    $world=New-SwitchWorld 'basis-default'
    Use-World $world
    $r=Invoke-SwitchScenario -Label 'basis-default' -World $world -NoAllowSwitch -Steps @(
        (New-Step @{ phase='ready'; modelId='model-a' } 'stop'))
    Check ($r.completed -and $null -eq $r.failure -and $r.runs.Count -eq 1 -and $r.runs[0].bound -ceq $defaultSupervisorBound -and $st.basisWrites.Count -eq 0 -and @(Get-ChildItem -LiteralPath $world.state -Force | Where-Object { $_.Name -like 'switch-*' }).Count -eq 0) 'basis default: a run that does not allow switching writes no basis, and its supervisor call, state folder and status are what they were'
    Check (-not $r.final.PSObject.Properties['switchAllowed'] -and $null -eq (Get-Block $r.final)) 'basis default: the status of a default run has no switch field'

    $world=New-SwitchWorld 'basis-failed' @{ 'model-a'=@('selftest-ok','selftest-ok'); 'model-b'=@('ok') }
    Use-World $world
    $r=Invoke-SwitchScenario -Label 'basis-failed' -World $world -StartOptions @{ SelfTest=$true } -Steps @(
        (New-Step @{ phase='ready'; modelId='model-a' } 'switch' @{ modelId='model-b' }),
        (New-Step @{ phase='ready'; modelId='model-a'; switchResult='failed-restored' } 'stop'))
    Check ($r.completed -and $r.runs.Count -eq 3 -and $st.basisWrites.Count -eq 3 -and @(Get-ChildItem -LiteralPath $world.state -Force | Where-Object { $_.Name -like 'switch-basis-*' }).Count -eq 0) 'basis failed: the target that failed and the restore each wrote their own basis, and none is left behind'

    # ================= the picker rows =================
    # Models f (experimental: not auto-eligible), g (its plan needs an engine probe a fixture plan refuses) and h (does not fit the reading) join a..e.
    function Add-PickerModels($World) {
        $document=Read-FastLlmJson -Path $World.path
        $entries=@($document.models)
        foreach ($letter in @('f','g','h')) {
            $id='model-'+$letter;$file=$id+'.gguf';$size=[int64](16+[int][char]$letter)
            [IO.File]::WriteAllBytes((Join-Path $World.models $file),(New-Object byte[] ([int]$size)))
            [IO.File]::WriteAllLines((Join-Path $World.root ($id+'.modes')),[string[]]@('ok'))
            $entry=[ordered]@{ id=$id; file=$file; sizeBytes=$size; sha256=($letter*64); consent=$true; url='https://example.invalid/'+$file; repository='switch-test/'+$id; revision='rev-'+$letter
                upstreamModel='upstream/'+$id; upstreamRevision='up-'+$letter; upstreamLicense='apache-2.0'; upstreamLicenseSha256=('f'*64); artifactLicense='apache-2.0'; contextSize=1024; parallel=1; cacheTypeK='f16'; cacheTypeV='f16' }
            if ($letter -ceq 'f') { $entry.autoEligible=$false }
            $entries+=[pscustomobject]$entry
        }
        $document.models=$entries
        [IO.File]::WriteAllText($World.path,(ConvertTo-Json -InputObject $document -Depth 8),(New-Object Text.UTF8Encoding($false)))
    }
    function New-PickerStatus($World,[string]$RunId) {
        return [pscustomobject]@{ schemaVersion=1; runId=$RunId; phase='ready'; active=$true; modelId='model-a'; switchAllowed=$true; thinking='auto'; chatPage='off'
            endpoint="http://127.0.0.1:$($World.port)/v1"; recipe=[pscustomobject]@{ contextSize=1024; slots=1 } }
    }
    function Get-PickerRows($World,$Status) {
        $script:pickerOutput=@()
        $rows=@(& $module { param($I,$C,$S) Get-FastLlmSwitchPickerRows -InstallRoot $I -CatalogPath $C -Status $S } $World.root $catalog $Status 6>&1)
        $script:pickerOutput=@($rows | Where-Object { $_ -isnot [pscustomobject] })
        return @($rows | Where-Object { $_ -is [pscustomobject] })
    }
    function Get-Row($Rows,[string]$Id) { return @($Rows | Where-Object { [string]$_.id -ceq $Id })[0] }
    $pickerWorld=New-SwitchWorld 'picker' @{ 'model-a'=@('ok') }
    Add-PickerModels $pickerWorld
    Use-World $pickerWorld
    $st.fixedFree=20000;$st.requiredFree=@{ 'model-h'=99999 };$st.needsProbe=@('model-g')
    $pickerRunId=('a1'*16)
    function Write-BasisFor($World,$Hardware,[string]$RunId,$PlanOptions=@{ Profile='balanced' }) { return (& $module { param($I,$R,$H,$O) Write-FastLlmSwitchBasis -InstallRoot $I -RunId $R -Hardware $H -PlanOptions $O } $World.root $RunId $Hardware $PlanOptions) }
    Check ((Write-BasisFor $pickerWorld $validHardware $pickerRunId) -eq $true) 'picker: setup, the current run saved the reading its plan was built from (20000 MiB free)'
    $pickerStatus=New-PickerStatus $pickerWorld $pickerRunId
    $st.planCalls.Clear();$st.events.Clear()
    $rows=Get-PickerRows $pickerWorld $pickerStatus
    $catalogIds=@((Read-FastLlmJson -Path $pickerWorld.path).models | ForEach-Object { [string]$_.id })
    Check ($rows.Count -eq $catalogIds.Count -and ($rows | ForEach-Object { [string]$_.id }) -join ',' -ceq ($catalogIds -join ',')) 'picker rows: one row per catalog model, in catalog order'
    Check (@($rows | Where-Object { (@($_.PSObject.Properties.Name) -join ',') -cne 'id,displayName,state,reason' }).Count -eq 0 -and @($rows | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.displayName) -or [string]::IsNullOrWhiteSpace([string]$_.reason) }).Count -eq 0) 'picker rows: every row is { id, displayName, state, reason } with a name and a reason'
    $stateList=(@($rows | ForEach-Object { [string]$_.id + '=' + [string]$_.state }) -join ',')
    Check ($stateList -ceq 'model-a=current,model-b=fits,model-c=not-installed,model-d=refused,model-e=refused,model-f=refused,model-g=check-at-switch,model-h=does-not-fit') "picker rows: each model gets the verdict of its own check [$stateList]"
    Check ((Get-Row $rows 'model-b').reason -clike 'Fits (estimate from the free memory measured when the current model started;*FastLLM checks again when it switches*') 'picker rows: a fit is worded as an estimate that FastLLM checks again at the switch'
    Check ((Get-Row $rows 'model-c').reason -ceq 'Not installed') 'picker rows: a model that is not installed says so and nothing else'
    Check ((Get-Row $rows 'model-d').reason -ceq (& $module { Get-FastLlmSwitchRefusalText -Code 'switch-target-size-mismatch' -ModelId 'model-d' }) -and (Get-Row $rows 'model-e').reason -ceq (& $module { Get-FastLlmSwitchRefusalText -Code 'switch-target-no-consent' -ModelId 'model-e' })) 'picker rows: a refusal is worded with the same sentence the switch refuses with (size mismatch, no consent)'
    Check ((Get-Row $rows 'model-f').reason -ceq (& $module { Get-FastLlmSwitchRefusalText -Code 'switch-target-experimental-model' -ModelId 'model-f' }) -and (Get-Row $rows 'model-g').reason -clike '*can''t tell yet whether this fits; it checks when it switches*') 'picker rows: an experimental model is refused with the switch''s sentence; what is not known says FastLLM checks when it switches'
    Check ((Get-Row $rows 'model-h').reason -clike 'Does not fit*free memory measured when the current model started*' -and (Get-Row $rows 'model-a').reason -ceq 'Running now') 'picker rows: a does-not-fit and the running model are worded plainly'
    Check ($script:pickerOutput.Count -eq 0) 'picker rows: the function writes nothing to the console or the window (no Write-Host output)'
    Check (@($st.events | Where-Object { $_ -ceq 'inventory' -or $_ -clike 'supervisor:*' -or $_ -clike 'hash:*' -or $_ -ceq 'INSTALL-MODEL' -or $_ -ceq 'NETWORK-SAVE' }).Count -eq 0 -and @($st.events | Where-Object { $_ -clike 'plan:*' }).Count -eq 3) 'picker rows: no inventory, no hash, no download and no run: only the planner is asked, once for each model that passed the switch''s own checks'
    $helperCall=$st.planCalls[0]
    Check ($helperCall.ContainsKey('NoEngineExecution') -and $helperCall.ContainsKey('Hardware') -and [int]@($helperCall['Hardware'].adapters)[0].freeVramMiB -eq 20000 -and @($st.planHardware | Where-Object { [int]@($_.adapters)[0].freeVramMiB -ne 20000 }).Count -eq 0) 'picker rows: the planner is given the saved reading (never a fresh inventory) and may not run an engine'
    Check (@(Get-ChildItem -LiteralPath $pickerWorld.state -Force | Where-Object { $_.Name -notlike 'switch-basis-*' -and $_.Name -notlike 'operation.lock' }).Count -eq 0) 'picker rows: computing rows writes nothing'

    # No basis, or a basis of another run: what needs the planner is "checked at the switch"; what the switch's own checks refuse is still refused.
    $noBasisStatus=New-PickerStatus $pickerWorld ('b2'*16)
    $rows=Get-PickerRows $pickerWorld $noBasisStatus
    $stateList=(@($rows | ForEach-Object { [string]$_.id + '=' + [string]$_.state }) -join ',')
    Check ($stateList -ceq 'model-a=current,model-b=check-at-switch,model-c=not-installed,model-d=refused,model-e=refused,model-f=refused,model-g=check-at-switch,model-h=check-at-switch') "picker rows: with no basis for the run every model that needs the planner is check-at-switch [$stateList]"
    Check ((Get-Row $rows 'model-b').reason -clike '*can''t tell yet whether this fits; it checks when it switches*') 'picker rows: the missing-basis reason says FastLLM checks when it switches'
    Copy-Item -LiteralPath (Join-Path $pickerWorld.state ('switch-basis-'+$pickerRunId+'.json')) -Destination (Join-Path $pickerWorld.state ('switch-basis-'+('b2'*16)+'.json'))
    $rows=Get-PickerRows $pickerWorld $noBasisStatus
    Check ((Get-Row $rows 'model-b').state -ceq 'check-at-switch' -and (Get-Row $rows 'model-h').state -ceq 'check-at-switch') 'picker rows: a basis file that belongs to another run (its own runId differs from the status) is never used'
    [IO.File]::Delete((Join-Path $pickerWorld.state ('switch-basis-'+('b2'*16)+'.json')))
    $rows=Get-PickerRows $pickerWorld ([pscustomobject]@{ phase='ready'; modelId='model-a'; switchAllowed=$true })
    Check ((Get-Row $rows 'model-a').state -ceq 'current' -and (Get-Row $rows 'model-b').state -ceq 'check-at-switch' -and (Get-Row $rows 'model-c').state -ceq 'not-installed') 'picker rows: a status with no run id gives no basis and no error'
    $rows=Get-PickerRows $pickerWorld $pickerStatus
    Check ((Get-Row $rows 'model-b').state -ceq 'fits') 'picker rows: the same rows are computed again from the same inputs'

    # Failures are classified by the typed code only, never by the words of the message.
    $realText="Requested model 'model-b' does not fit the estimated current free-memory budget. No other model was substituted."
    $st.planFailures['model-b']=(New-Object InvalidOperationException($realText))
    Check ((Get-Row (Get-PickerRows $pickerWorld $pickerStatus) 'model-b').state -ceq 'check-at-switch') 'picker rows: the words of a does-not-fit without its typed code are NOT a does-not-fit'
    $typedOther=New-Object InvalidOperationException('plain words that say nothing about fit'); $typedOther.Data['FastLlmFailureCode']='model-does-not-fit'
    $st.planFailures['model-b']=$typedOther
    Check ((Get-Row (Get-PickerRows $pickerWorld $pickerStatus) 'model-b').state -ceq 'does-not-fit') 'picker rows: the typed code model-does-not-fit is a does-not-fit whatever the message says'
    $typedNone=New-Object InvalidOperationException('x'); $typedNone.Data['FastLlmFailureCode']='no-profile-fits'
    $st.planFailures['model-b']=$typedNone
    Check ((Get-Row (Get-PickerRows $pickerWorld $pickerStatus) 'model-b').state -ceq 'does-not-fit') 'picker rows: the typed code no-profile-fits is a does-not-fit'
    $st.planFailures['model-b']=(New-FastLlmTypedFailure -Code 'fixture-plan-cannot-probe-engine' -Message 'the engine would have to be run')
    Check ((Get-Row (Get-PickerRows $pickerWorld $pickerStatus) 'model-b').state -ceq 'check-at-switch') 'picker rows: another typed code (an engine probe a fixture plan refuses) is check-at-switch'
    $st.planFailures['model-b']=(New-Object InvalidOperationException('anything else'))
    Check ((Get-Row (Get-PickerRows $pickerWorld $pickerStatus) 'model-b').state -ceq 'check-at-switch') 'picker rows: any other failure is check-at-switch, never does-not-fit'
    $st.planFailures=@{}

    # The picker builds its options through Get-FastLlmSwitchPlanOptions only: a changed helper changes what the planner is asked.
    $savedOptionsBlock=& $module { (Get-Command Get-FastLlmSwitchPlanOptions).ScriptBlock }
    & $module { param($Original,$S)
        $script:switchTestOriginalOptions=$Original
        function script:Get-FastLlmSwitchPlanOptions {
            param($PreviousPlan,$ServingOptions,$Request,$CatalogPath,$InstallRoot)
            $built=& $script:switchTestOriginalOptions @PSBoundParameters
            if ($script:switchTest.ContainsKey('mutateOptions') -and $script:switchTest['mutateOptions']) { $built.ContextSize=777 }
            return $built
        }
    } $savedOptionsBlock $st
    $st.mutateOptions=$true
    $st.planCalls.Clear()
    $null=Get-PickerRows $pickerWorld $pickerStatus
    $mutated=@($st.planCalls | Where-Object { $_.ContainsKey('ContextSize') -and [int]$_['ContextSize'] -eq 777 })
    $st.mutateOptions=$false
    Check ($mutated.Count -eq 3) 'picker mutation check: when the option helper is changed, every plan the picker asks for changes with it (the picker has no options of its own)'
    $st.planCalls.Clear()
    $null=& $module { param($P,$C,$R) New-FastLlmSwitchTargetPlan -PreviousPlan $P -Request ([pscustomobject]@{ modelId='model-b'; recipeId=$null }) -CatalogPath $C -InstallRoot $R } (& $st.newPlan 'model-a' '' @{}) $catalog $pickerWorld.root
    Check (-not $st.planCalls[$st.planCalls.Count-1].ContainsKey('ContextSize')) 'picker mutation check: with the helper as it ships, the real switch asks the planner exactly what it did before'
    $pickerText=& $module { (Get-Command Get-FastLlmSwitchPickerRows).ScriptBlock.ToString() }
    Check ($pickerText.Contains('Get-FastLlmSwitchPlanOptions') -and $pickerText -notmatch 'RecipesPath|GpuVariantsPath|\bProfile\s*=|KvContextProfile|KvSlots') 'picker mutation check: the picker names the option helper and none of the planner options itself'
    Check ($pickerText -notmatch '\.Message|-like|-match|-clike|-cmatch|-contains' -and $pickerText.Contains("FastLlmFailureCode")) 'picker mutation check: a failure is classified by its typed code, with no test of message text'

    # ================= the basis carries the switch's serving options (what Get-FastLlmSwitchPlanOptions takes from the run's real plan) =================
    foreach ($optCase in @(@{ name='default'; kv=@{}; mode='ok' }, @{ name='slots'; kv=@{ KvSlots=2 }; mode='slots2' }, @{ name='long'; kv=@{ KvContextProfile='long' }; mode='ok' })) {
        $w=New-SwitchWorld ('basis-options-'+$optCase.name) @{ 'model-a'=@($optCase.mode) }
        Use-World $w
        $st.kv=$optCase.kv
        $r=Invoke-SwitchScenario -Label ('basis-options-'+$optCase.name) -World $w -Steps @((New-Step @{ phase='ready'; modelId='model-a' } 'stop' @{ timeoutSeconds=120 }))
        $savedBasis=$st.basisWrites[0].Text | ConvertFrom-Json
        $servingOf=& $module { param($P) Get-FastLlmSwitchServingOptions -PreviousPlan $P } $r.runs[0].plan
        $savedNames=(@($savedBasis.planOptions.PSObject.Properties.Name) | Sort-Object) -join ','
        $sameValues=$true
        foreach ($key in $servingOf.Keys) { if (([string]$savedBasis.planOptions.$key) -cne ([string]$servingOf[$key])) { $sameValues=$false } }
        Check ($r.completed -and $savedNames -ceq ((@($servingOf.Keys) | Sort-Object) -join ',') -and $sameValues) ("basis options ($($optCase.name) run): planOptions equal what Get-FastLlmSwitchServingOptions returns for the run's plan [$savedNames]")
        Check (-not ($savedNames -match 'Path|ModelId|RecipeId|Catalog|InstallRoot|Hardware')) ("basis options ($($optCase.name) run): no path, model or hardware is among the options")
        if ($optCase.name -ceq 'slots') { Check ([int]$savedBasis.planOptions.KvSlots -eq 2 -and -not $savedBasis.planOptions.PSObject.Properties['KvContextProfile']) 'basis options (slots run): the slot count is carried' }
        if ($optCase.name -ceq 'long') { Check ($savedBasis.planOptions.KvContextProfile -ceq 'long' -and -not $savedBasis.planOptions.PSObject.Properties['KvSlots']) 'basis options (long run): the context profile is carried' }
        if ($optCase.name -ceq 'default') { Check ((@($savedBasis.planOptions.PSObject.Properties.Name | Sort-Object) -join ',') -ceq 'Profile,ServerPort' -and $savedBasis.planOptions.Profile -ceq 'balanced') 'basis options (default run): only the profile and the port, as a default switch asks' }
    }
    # A run on the long-context profile: a target that fits the default options does not fit its long profile. The real switch fails with the typed
    # code, and the picker (which uses the options the run saved) says so, where default options would have said fits.
    $w=New-SwitchWorld 'basis-long-fit' @{ 'model-a'=@('ok','ok') }
    Add-PickerModels $w
    Use-World $w
    $st.fixedFree=20000;$st.requiredFree=@{ 'model-h'=15000 };$st.requiredFreeLong=@{ 'model-h'=25000 };$st.kv=@{ KvContextProfile='long' }
    $r=Invoke-SwitchScenario -Label 'basis-long-fit' -World $w -Steps @(
        (New-Step @{ phase='ready'; modelId='model-a' } 'switch' @{ modelId='model-h' }),
        (New-Step @{ phase='ready'; modelId='model-a'; switchResult='failed-restored' } 'stop'))
    $longBlock=Get-Block $r.final
    Check ($r.completed -and (Test-Block $longBlock 'model-a' 'model-h' 'failed-restored' 'model-does-not-fit' $false)) 'long profile: the real switch to a model that does not fit the long profile fails with model-does-not-fit and restores'
    $longBasis=$st.basisWrites[0]
    [IO.File]::WriteAllText((Join-Path $w.state $longBasis.FileName),$longBasis.Text,(New-Object Text.UTF8Encoding($false)))
    $longStatus=Get-RunFinal $r.runs[0]
    $longRows=Get-PickerRows $w $longStatus
    Check ((Get-Row $longRows 'model-h').state -ceq 'does-not-fit') 'long profile: the picker says does-not-fit, as the real switch found'
    $defaultText=$longBasis.Text | ConvertFrom-Json
    $defaultText.planOptions=[pscustomobject]@{ Profile='balanced'; ServerPort=[int]$w.port }
    [IO.File]::WriteAllText((Join-Path $w.state $longBasis.FileName),(ConvertTo-Json -InputObject $defaultText -Depth 12),(New-Object Text.UTF8Encoding($false)))
    Check ((Get-Row (Get-PickerRows $w $longStatus) 'model-h').state -ceq 'fits') 'long profile: with default options the same target would have read fits (the saved options are what decide it)'
    $tampered=$longBasis.Text | ConvertFrom-Json
    $tampered.planOptions | Add-Member -NotePropertyName ModelId -NotePropertyValue 'model-b'
    [IO.File]::WriteAllText((Join-Path $w.state $longBasis.FileName),(ConvertTo-Json -InputObject $tampered -Depth 12),(New-Object Text.UTF8Encoding($false)))
    Check ((Get-Row (Get-PickerRows $w $longStatus) 'model-h').state -ceq 'check-at-switch' -and (Get-Row (Get-PickerRows $w $longStatus) 'model-b').state -ceq 'check-at-switch') 'tampered options: an extra name in planOptions makes the whole basis unusable (check-at-switch)'
    $tampered2=$longBasis.Text | ConvertFrom-Json
    $tampered2.planOptions.KvContextProfile=7
    [IO.File]::WriteAllText((Join-Path $w.state $longBasis.FileName),(ConvertTo-Json -InputObject $tampered2 -Depth 12),(New-Object Text.UTF8Encoding($false)))
    Check ((Get-Row (Get-PickerRows $w $longStatus) 'model-h').state -ceq 'check-at-switch') 'tampered options: a value of the wrong type makes the whole basis unusable (check-at-switch)'

    # An experimental model is refused by the switch's own check, before anything is stopped.
    $expTarget=& $module { param($C,$R) Resolve-FastLlmSwitchTarget -CatalogPath $C -InstallRoot $R -ModelId 'model-f' -CurrentModelId 'model-a' } $catalog $pickerWorld.root
    Check (-not $expTarget.ok -and $expTarget.code -ceq 'switch-target-experimental-model' -and $expTarget.modelId -ceq 'model-f') 'experimental: Resolve-FastLlmSwitchTarget refuses an experimental model with switch-target-experimental-model'
    Check ((& $module { Get-FastLlmSwitchRefusalText -Code 'switch-target-experimental-model' -ModelId 'model-f' }) -clike '*experimental model*command line*not by a switch*') 'experimental: the refusal text says it is started from the command line, not by a switch'
    # The flag the refusal names is a real parameter of fast-llm.ps1 that start accepts together with -ModelId (read from the param block by AST).
    $launcherAst=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'fast-llm.ps1'),[ref]$null,[ref]$null)
    $launcherParams=@{}
    foreach ($launcherParam in @($launcherAst.ParamBlock.Parameters)) { $launcherParams[[string]$launcherParam.Name.VariablePath.UserPath]=$launcherParam }
    $refusalSentence=& $module { Get-FastLlmSwitchRefusalText -Code 'switch-target-experimental-model' -ModelId 'model-f' }
    $namedFlags=@([regex]::Matches($refusalSentence,'(?<![\w-])-([A-Za-z]+)') | ForEach-Object { $_.Groups[1].Value })
    $flagAst=$launcherParams['AllowExperimentalModel']
    $flagIsSwitch=$false; $flagSetNames=@()
    if ($null -ne $flagAst) { $flagIsSwitch=([string]$flagAst.StaticType.Name -ceq 'SwitchParameter'); $flagSetNames=@($flagAst.Attributes | Where-Object { $_.TypeName.Name -ceq 'Parameter' } | ForEach-Object { @($_.NamedArguments | Where-Object { $_.ArgumentName -ceq 'ParameterSetName' }) }) }
    Check (($namedFlags -join ',') -ceq 'ModelId,AllowExperimentalModel' -and $launcherParams.ContainsKey('ModelId') -and $flagIsSwitch -and $flagSetNames.Count -eq 0) 'experimental: the flags the refusal names (-ModelId, -AllowExperimentalModel) are parameters of fast-llm.ps1, the second a switch in no parameter set, so start accepts them together'
    Check ($refusalSentence -cnotmatch 'AcceptExperimental') 'experimental: the refusal does not name -AcceptExperimental (that flag belongs to experimental recipes)'
    $expWorld=New-SwitchWorld 'experimental-raw' @{ 'model-a'=@('ok') }
    Add-PickerModels $expWorld
    Use-World $expWorld
    $r=Invoke-SwitchScenario -Label 'experimental-raw' -World $expWorld -Steps @(
        (New-Step @{ phase='ready'; modelId='model-a' } 'raw' @{ text=(Format-RawRequest @{ schemaVersion=1; modelId='model-f'; force=$false }) }),
        (New-Step @{ phase='ready'; modelId='model-a'; switchResult='refused' } 'stop'))
    $expBlock=Get-Block (@($r.observations | Where-Object { $null -ne $_.switch })[-1])
    Check ($r.completed -and $r.runs.Count -eq 1 -and (@(Get-ModeStarts $expWorld 'model-f')).Count -eq 0 -and (Test-Block $expBlock 'model-a' 'model-f' 'refused' 'switch-target-experimental-model' $false)) 'experimental: a request for an experimental model that reaches the supervisor is refused (switch.result refused) and the server is not restarted'
    Check (@($r.observations | Where-Object { $_.runId -ceq $r.runs[0].runId -and $_.phase -cin @('stopped','failed') -and $_.stopReason -ceq 'switch' }).Count -eq 0 -and @(Get-ChildItem -LiteralPath $expWorld.state -Force | Where-Object { $_.Name -like 'switch-*' }).Count -eq 0) 'experimental: the current run was never stopped for a switch and no request file is left'

    # ================= parity: the picker's verdict against what the real switch does with the same hardware =================
    # Hardware is fixed (20000 MiB free). model-b fits, model-h needs more than that, model-g needs an engine probe a fixture plan cannot make
    # (a real plan makes it), model-f is experimental (the switch refuses it before anything stops), c is not downloaded, d has
    # the wrong size, e has no consent. The real switch is run (a supervised start with a client asking for it); the picker is asked about the
    # same hardware: the basis the real run saved, and the status the real run wrote.
    $parity=@()
    function Invoke-ParityScenario([string]$TargetId,[string]$ExpectResult,[string]$ExpectModel) {
        $w=New-SwitchWorld ('parity-'+$TargetId) @{ 'model-a'=@('ok','ok') }
        Add-PickerModels $w
        Use-World $w
        $st.fixedFree=20000;$st.requiredFree=@{ 'model-h'=99999 };$st.needsProbe=@('model-g')
        $run=Invoke-SwitchScenario -Label ('parity-'+$TargetId) -World $w -Steps @(
            (New-Step @{ phase='ready'; modelId='model-a' } 'switch' @{ modelId=$TargetId }),
            (New-Step @{ phase='ready'; modelId=$ExpectModel; switchResult=$ExpectResult } 'stop'))
        $realCalls=@($st.planCalls | Where-Object { $_.ContainsKey('ModelId') -and [string]$_['ModelId'] -ceq $TargetId })
        $captured=$st.basisWrites[0]
        [IO.File]::WriteAllText((Join-Path $w.state $captured.FileName),$captured.Text,(New-Object Text.UTF8Encoding($false)))
        $status=Get-RunFinal $run.runs[0]
        $pickerRows=Get-PickerRows $w $status
        $pickerCalls=@($st.planCalls | Where-Object { $_.ContainsKey('ModelId') -and [string]$_['ModelId'] -ceq $TargetId -and $_.ContainsKey('NoEngineExecution') })
        return [pscustomobject]@{ run=$run; world=$w; row=(Get-Row $pickerRows $TargetId); realCall=$realCalls[0]; pickerCall=$pickerCalls[0]; basisText=$captured.Text; status=$status }
    }
    $fitsCase=Invoke-ParityScenario 'model-b' 'ok' 'model-b'
    $notFitCase=Invoke-ParityScenario 'model-h' 'failed-restored' 'model-a'
    $probeCase=Invoke-ParityScenario 'model-g' 'ok' 'model-g'
    foreach ($case in @($fitsCase,$notFitCase,$probeCase)) { Check ($case.run.completed -and $null -eq $case.run.failure) ("parity: the real switch to "+$case.row.id+" ran to its end") }
    $realBlock={ param($Case) $b=Get-Block $Case.run.final; if ($b.result -ceq 'ok') { return 'ok' }; return ([string]$b.result+':'+[string]$b.failureCode) }
    Check ((& $realBlock $fitsCase) -ceq 'ok' -and $fitsCase.row.state -ceq 'fits') 'parity fits: the real switch succeeds and the picker says fits'
    Check ((& $realBlock $notFitCase) -ceq 'failed-restored:model-does-not-fit' -and $notFitCase.row.state -ceq 'does-not-fit') 'parity does not fit: the real switch fails with the typed code model-does-not-fit (and restores) and the picker says does-not-fit'
    Check ((& $realBlock $probeCase) -ceq 'ok' -and $probeCase.row.state -ceq 'check-at-switch') 'parity engine probe: the real switch succeeds (a real plan runs the probe); the picker, whose fixture plan refuses it, says check-at-switch and never does-not-fit'
    foreach ($case in @($fitsCase,$notFitCase,$probeCase)) {
        $basisSaved=$case.basisText | ConvertFrom-Json
        Check ($basisSaved.runId -ceq $case.status.runId -and [int]@($basisSaved.hardware.adapters)[0].freeVramMiB -eq 20000) ("parity: the basis the real run saved for "+$case.row.id+"'s scenario is the injected 20000 MiB reading, under that run")
        $realKeys=@($case.realCall.Keys | Sort-Object)
        $pickerKeys=@($case.pickerCall.Keys | Where-Object { $_ -cne 'NoEngineExecution' } | Sort-Object)
        $same=($realKeys -join ',') -ceq ($pickerKeys -join ',')
        foreach ($key in $realKeys) { if ($key -cne 'Hardware' -and ([string]$case.realCall[$key]) -cne ([string]$case.pickerCall[$key])) { $same=$false } }
        Check ($same -and [int]@($case.realCall['Hardware'].adapters)[0].freeVramMiB -eq [int]@($case.pickerCall['Hardware'].adapters)[0].freeVramMiB) ("parity: the planner is asked the same thing for "+$case.row.id+" by the picker and by the real switch (same options, same hardware), the picker adding only NoEngineExecution")
    }
    # Refusals: the real writer refuses before anything is stopped; the picker shows the same verdict with the same sentence.
    $refusalWorld=New-SwitchWorld 'parity-refusals' @{ 'model-a'=@('ok') }
    Add-PickerModels $refusalWorld
    Use-World $refusalWorld
    $st.fixedFree=20000
    $refusalRunId='c3'*16
    $null=Write-BasisFor $refusalWorld $validHardware $refusalRunId
    $refusalStatus=New-PickerStatus $refusalWorld $refusalRunId
    $refusalRows=Get-PickerRows $refusalWorld $refusalStatus
    $refusalLock=Enter-FastLlmOperation $refusalWorld.root
    try {
        Write-FastLlmState -InstallRoot $refusalWorld.root -State ([ordered]@{ schemaVersion=1; runId=$refusalRunId; phase='ready'; modelId='model-a'; switchAllowed=$true })
        foreach ($case in @(@{id='model-c';code='switch-target-not-installed';state='not-installed'},@{id='model-d';code='switch-target-size-mismatch';state='refused'},@{id='model-e';code='switch-target-no-consent';state='refused'},@{id='model-f';code='switch-target-experimental-model';state='refused'})) {
            $thrown=$null
            try { Request-FastLlmSwitch -InstallRoot $refusalWorld.root -CatalogPath $catalog -ModelId $case.id 6>$null | Out-Null } catch { $thrown=$_.Exception }
            $row=Get-Row $refusalRows $case.id
            $refusalSentence=& $module { param($C,$M) Get-FastLlmSwitchRefusalText -Code $C -ModelId $M } $case.code $case.id
            Check ($null -ne $thrown -and [string]$thrown.Data['FastLlmFailureCode'] -ceq $case.code -and $row.state -ceq $case.state) ("parity "+$case.id+": the real switch refuses with "+$case.code+" and the picker says "+$case.state)
            if ($case.state -ceq 'refused') { Check ($row.reason -ceq $refusalSentence -and $thrown.Message.Contains($row.reason)) ("parity "+$case.id+": the picker's reason is the sentence the real refusal carries") }
        }
        $thrown=$null
        try { Request-FastLlmSwitch -InstallRoot $refusalWorld.root -CatalogPath $catalog -ModelId 'model-b' 6>$null | Out-Null } catch { $thrown=$_.Exception }
        Check ($null -eq $thrown -and (Get-Row $refusalRows 'model-b').state -ceq 'fits') 'parity: a model the real writer accepts is one the picker lets the user pick (fits)'
        [IO.File]::Delete((Join-Path $refusalWorld.state ('switch-basis-'+$refusalRunId+'.json')))
        $refusalRows=Get-PickerRows $refusalWorld $refusalStatus
        Check ((Get-Row $refusalRows 'model-b').state -ceq 'check-at-switch' -and $null -eq $thrown) 'parity basis missing: the real writer still accepts the model; the picker says check-at-switch (and lets the user pick it)'
        $null=Write-BasisFor $refusalWorld $validHardware $refusalRunId
        $mismatchStatus=New-PickerStatus $refusalWorld ('d4'*16)
        $refusalRows=Get-PickerRows $refusalWorld $mismatchStatus
        Check ((Get-Row $refusalRows 'model-b').state -ceq 'check-at-switch') 'parity basis of another run: the picker says check-at-switch for a status whose run has no basis'
    } finally { $refusalLock.Dispose() }
    $suitePassed=$true
} finally {
    if ($suitePassed) { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue } }
    else { Write-Warning "Model switch test scratch retained for failure diagnostics: $temp" }
}
Write-Host "model-switch-tests: $count checks passed. Mock services are not Windows/AMD qualification."
