#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force
$module=Get-Module FastLlm
$catalog=Join-Path $root 'config/catalog.json'
$hardware=Read-FastLlmJson (Join-Path $PSScriptRoot 'fixtures/rx-7900-xtx-24gb.json')
$count=0
function Check([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; $script:count++; Write-Host "PASS: $Message" }
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
$explicit=Get-FastLlmPlan -Hardware $hardware -CatalogPath $catalog -ModelId 'qwen3.8-27b-ud-iq4-xs' -ContextSize 8192
Check ($explicit.model.id -eq 'qwen3.8-27b-ud-iq4-xs' -and $explicit.model.contextSize -eq 8192) 'explicit artifact/context survive resolution'
Check ($explicit.model.requiredFreeVramMiB -eq 17800) 'reduced context does not invent a lower fit threshold'
Throws { Get-FastLlmPlan -Hardware $hardware -CatalogPath $catalog -ModelId 'does-not-exist' } 'Unknown model'
Throws { Get-FastLlmPlan -Hardware $hardware -CatalogPath $catalog -ContextSize 256 } 'at least 512'
Throws { Get-FastLlmPlan -Hardware $hardware -CatalogPath $catalog -ModelId 'qwen3.8-27b-q8-0' } 'No other model'
Throws { Get-FastLlmPlan -Hardware $hardware -CatalogPath $catalog -ModelId 'qwen3.8-27b-ud-iq4-xs' -ContextSize 32768 } 'context exceeds'
Throws { Get-FastLlmPlan -Hardware $hardware -CatalogPath $catalog -ModelId 'qwen3.8-27b-ud-iq3-xxs' } 'experimental'
$before=Get-FastLlmPlan -Hardware $hardware -CatalogPath $catalog
$hardware.adapters[0].freeVramMiB-=100
$after=Get-FastLlmPlan -Hardware $hardware -CatalogPath $catalog
Check ($before.hardwareFingerprint -eq $after.hardwareFingerprint) 'free-memory fluctuation does not invalidate inventory identity'
Check ($before.capacity.largestFreeVramMiB -ne $after.capacity.largestFreeVramMiB) 'live budget is still refreshed'
$hardware.adapters[0].driverVersion='changed'
Check ((Get-FastLlmPlan -Hardware $hardware -CatalogPath $catalog).hardwareFingerprint -ne $after.hardwareFingerprint) 'driver changes invalidate the inventory key'
Throws { ConvertFrom-FastLlmPlacementLog -Text 'load_tensors: offloaded 40/41 layers to GPU' -Devices Vulkan0 } 'not report all'
Throws { ConvertFrom-FastLlmPlacementLog -Text "load_tensors: offloaded 41/41 layers to GPU`nload_tensors: Vulkan1 model buffer size = 100.00 MiB" -Devices Vulkan0 } 'do not match'
Throws { ConvertFrom-FastLlmPlacementLog -Text 'server ready' -Devices Vulkan0 } 'Missing'
Throws { ConvertFrom-FastLlmPlacementLog -Text "load_tensors: offloaded 41/41 layers to GPU`nload_tensors: Vulkan0 model buffer size = 0.00 MiB" -Devices Vulkan0 } 'positive'
Throws { ConvertFrom-FastLlmPlacementLog -Text "load_tensors: offloaded 41/41 layers to GPU`nload_tensors: offloaded 41/41 layers to GPU`nload_tensors: Vulkan0 model buffer size = 1200.00 MiB" -Devices Vulkan0 } 'ambiguous'
Throws { ConvertFrom-FastLlmPlacementLog -Text "load_tensors: offloaded 41/41 layers to GPU`nload_tensors: Vulkan0 model buffer size = 1200.00 MiB`nload_tensors: Vulkan0 model buffer size = 1300.00 MiB" -Devices Vulkan0 } 'Duplicate GPU model-buffer'
$modelPlacement=ConvertFrom-FastLlmPlacementLog -Text "load_tensors: offloaded 41/41 layers to GPU`nload_tensors: Vulkan0 model buffer size = 1200.00 MiB" -Devices Vulkan0
Check ($modelPlacement.modelBufferMiB.Count -eq 1 -and $modelPlacement.modelBufferMiB[0].device -eq 'Vulkan0' -and $modelPlacement.modelBufferMiB[0].sizeMiB -eq 1200) 'unique selected model-buffer size is retained as reported MiB'
$diag=& $module {param($T) ConvertFrom-FastLlmStartupDiagnostics -Text $T} "kv Vulkan0 256.00`ncompute Vulkan0 64.00`nflash-mode auto`nflash-resolved enabled"
Check ($diag.status -eq 'captured' -and $diag.kvBuffers[0].sizeMiB -eq 256 -and $diag.computeBuffers[0].sizeMiB -eq 64 -and $diag.reportedFlashAttentionMode -eq 'auto' -and $diag.reportedFlashAttentionResolved -eq $true -and -not $diag.physicalResidencyVerified) 'startup diagnostics retain only numeric buffers and explicit flash resolution'
Check ((& $module {ConvertFrom-FastLlmStartupDiagnostics -Text ''}).status -eq 'missing' -and (& $module {ConvertFrom-FastLlmStartupDiagnostics -Text 'kv Vulkan0 256.00' -Overflow $true}).status -eq 'overflow') 'missing and overflow diagnostics never become positive evidence'
Check ((& $module {ConvertFrom-FastLlmStartupDiagnostics -Text "kv Vulkan0 256.00`nkv Vulkan0 257.00"}).status -eq 'duplicate' -and (& $module {ConvertFrom-FastLlmStartupDiagnostics -Text 'kv Vulkan0 -4.00'}).status -eq 'invalid') 'duplicate and malformed startup diagnostics are rejected'
$invalidAfterGood=& $module {ConvertFrom-FastLlmStartupDiagnostics -Text "kv Vulkan0 256.00`ncompute Vulkan0 -4.00"}
Check ($invalidAfterGood.status -eq 'invalid' -and $invalidAfterGood.kvBuffers.Count -eq 0) 'invalid diagnostics do not leak earlier seemingly valid values'
$duplicateAfterGood=& $module {ConvertFrom-FastLlmStartupDiagnostics -Text "kv Vulkan0 256.00`nkv Vulkan0 257.00"}
Check ($duplicateAfterGood.status -eq 'duplicate' -and $duplicateAfterGood.kvBuffers.Count -eq 0) 'duplicate diagnostics do not publish a first-wins value'
$hugeNumeric='9'*512
$oversizedDiagnostic=& $module {param($N) ConvertFrom-FastLlmStartupDiagnostics -Text "kv Vulkan0 $N"} $hugeNumeric
Check ($oversizedDiagnostic.status -eq 'invalid' -and $oversizedDiagnostic.kvBuffers.Count -eq 0) 'oversized numeric diagnostics cannot throw or fail serving'
$contradictoryDiagnostic=& $module {ConvertFrom-FastLlmStartupDiagnostics -Text "kv Vulkan0 256.00`ncompute Vulkan0 64.00`nflash-mode disabled`nflash-resolved enabled"}
Check ($contradictoryDiagnostic.status -eq 'invalid' -and $contradictoryDiagnostic.kvBuffers.Count -eq 0 -and $null -eq $contradictoryDiagnostic.reportedFlashAttentionMode) 'contradictory explicit flash mode and resolution publish no evidence'
Check ($diag.allocationCoverage -match 'recurrent/state' -and -not $diag.physicalResidencyVerified) 'startup buffer observations cannot claim complete hybrid-model allocation coverage'
$runtimeSource=Get-Content -LiteralPath (Join-Path $root 'src/FastLlm.Runtime.ps1') -Raw
Check ($runtimeSource -match "(?s)\`$state\.phase='checking';\s*\`$state\.updatedAt=.*?Write-FastLlmState" -and $runtimeSource -match "(?s)\`$state\.phase='ready';\s*\`$state\.updatedAt=.*?Write-FastLlmState") 'checking and ready publishes refresh status timestamps'
Check ($runtimeSource -match "(?s)\`$hostProcess\.Start\(\`$info\).*?\`$state\.processIdentity\s*=.*?pid=\[int\]\`$hostProcess\.Process\.Id.*?startUtcTicks=\[long\]\`$hostProcess\.Process\.StartTime\.ToUniversalTime\(\)\.Ticks.*?Write-FastLlmState") 'supervisor publishes actual child PID and UTC start ticks immediately after spawn'
& $module { Initialize-FastLlmProcessHost }
Add-Type -Path (Join-Path $PSScriptRoot 'helpers/MockServer.cs')
Check ([FastLlmTests.MockServer]::IsSynchronousChatRequest('{"stream":false,"model":"test"}') -and
    [FastLlmTests.MockServer]::IsSynchronousChatRequest('{"model":"test", "stream" :  false }') -and
    [FastLlmTests.MockServer]::IsSynchronousChatRequest((@{model='test';stream=$false}|ConvertTo-Json -Compress)) -and
    -not [FastLlmTests.MockServer]::IsSynchronousChatRequest('{"stream":true}') -and
    -not [FastLlmTests.MockServer]::IsSynchronousChatRequest('{"stream":"false"}')) 'mock detects the synchronous JSON boolean across PowerShell whitespace'
Throws { [Bitworks.FastLlm.LoopbackHttp]::Request('http://localhost:1234', $null, 100, 100) } 'loopback'
Throws { [Bitworks.FastLlm.LoopbackHttp]::Request('https://example.com', $null, 100, 100) } 'loopback'

$temp=Join-Path ([IO.Path]::GetTempPath()) ('fast-llm-runtime-'+[Guid]::NewGuid().ToString('N'))
$lock=$null
try {
    $lock=Enter-FastLlmOperation $temp
    Throws { Enter-FastLlmOperation $temp } 'Another FastLLM'
    Write-FastLlmState -InstallRoot $temp -State @{runId=('a'*32);phase='ready'}
    Check ((Get-FastLlmStatus $temp).active) 'status observes the live lock'
    Request-FastLlmStop $temp
    Request-FastLlmStop $temp
    Check (Test-Path (Join-Path $temp ('state/stop-'+('a'*32)))) 'stop uses a run-scoped request, not PID termination'
    $lock.Dispose();$lock=$null
    Check ((Get-FastLlmStatus $temp).phase -eq 'interrupted') 'stale ready state is not reported as running'
    Throws { Request-FastLlmStop $temp } 'no supervised'
    $lock=Enter-FastLlmOperation $temp
    Write-FastLlmState -InstallRoot $temp -State @{runId=('b'*32);phase='preparing'}
    Throws { Request-FastLlmStop $temp } 'no supervised'
    $lock.Dispose();$lock=$null
    Check ((Get-FastLlmStatus $temp).phase -eq 'interrupted') 'interrupted preparation cannot look active'

    # Synthetic recovery records only test policy. The placeholder is not a runnable model.
    $recoveryRoot=Join-Path $temp 'recovery'
    $cached=Get-FastLlmPlan -Hardware $hardware -CatalogPath $catalog -InstallRoot $recoveryRoot -ModelId 'qwen3.5-9b-q4-k-m'
    New-Item -ItemType Directory -Path (Split-Path $cached.modelPath -Parent) -Force | Out-Null
    Set-Content -LiteralPath $cached.modelPath -Value 'not a model'
    & $module {param($M,$R) Write-FastLlmModelConsentReceipt -Model $M -InstallRoot $R -AcceptanceMode explicit-switch} $cached.model $recoveryRoot
    $record=@{kind='api-smoke-only';hardwareFingerprint=$cached.hardwareFingerprint;modelId=$cached.model.id;modelSha256=$cached.model.sha256;catalogSha256=(Get-FileHash $catalog -Algorithm SHA256).Hash.ToLowerInvariant()}
    $recordName=$cached.hardwareFingerprint+'.last-ready.json'
    Write-FastLlmState $recoveryRoot $record $recordName
    $options=@{Hardware=$hardware;CatalogPath=$catalog;InstallRoot=$recoveryRoot;Profile='balanced';FailedModelId='qwen3.8-27b-ud-q4-k-m'}
    $recovered=Get-FastLlmRecoveryPlan @options
    Check ($recovered.model.id -eq $cached.model.id) 'recovery chooses only the previous cached consented artifact'
    Check (-not (Test-FastLlmFileHash -Path $recovered.modelPath -Sha256 $recovered.model.sha256)) 'recovery eligibility is not an integrity bypass; startup must still hash'
    Check ($null -eq (Get-FastLlmRecoveryPlan @options -RequestedModelId 'qwen3.8-27b-ud-q4-k-m')) 'explicit selection never falls back'
    $options.FailedModelId=$cached.model.id
    Check ($null -eq (Get-FastLlmRecoveryPlan @options)) 'recovery never loops onto the failing artifact'
    $options.FailedModelId='qwen3.8-27b-ud-q4-k-m'
    $record.catalogSha256='0'*64;Write-FastLlmState $recoveryRoot $record $recordName
    Check ($null -eq (Get-FastLlmRecoveryPlan @options)) 'catalog changes invalidate recovery history'
    $record.catalogSha256=(Get-FileHash $catalog -Algorithm SHA256).Hash.ToLowerInvariant()
    $record.modelSha256='0'*64;Write-FastLlmState $recoveryRoot $record $recordName
    Check ($null -eq (Get-FastLlmRecoveryPlan @options)) 'artifact digest changes invalidate recovery history'
    $record.modelSha256=$cached.model.sha256;Write-FastLlmState $recoveryRoot $record $recordName
    $hardware.adapters[0].driverVersion='newer'
    Check ($null -eq (Get-FastLlmRecoveryPlan @options)) 'changed driver/inventory cannot reuse recovery history'
    $hardware.adapters[0].driverVersion='changed'
    $consentPath=& $module {param($M,$R) Get-FastLlmModelConsentPath $M $R} $cached.model $recoveryRoot
    Remove-Item -LiteralPath $consentPath
    Check ($null -eq (Get-FastLlmRecoveryPlan @options)) 'missing consent cannot be inferred from recovery history'
    & $module {param($M,$R) Write-FastLlmModelConsentReceipt -Model $M -InstallRoot $R -AcceptanceMode explicit-switch} $cached.model $recoveryRoot
    Remove-Item -LiteralPath $cached.modelPath
    Check ($null -eq (Get-FastLlmRecoveryPlan @options)) 'recovery never downloads a missing artifact'

    foreach ($mode in @('partial','context','unstable','chat','sse','exit','timeout','duplicate','flood','diagduplicate','diagflood','ok')) {
        $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
        $listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
        $runRoot=Join-Path $temp $mode
        $lock=Enter-FastLlmOperation $runRoot
        $diagnosticPath=Join-Path $runRoot 'mock-startup-diagnostic.txt'
        $plan=[pscustomobject]@{
            enginePath=(Get-Process -Id $PID).Path
            serverArguments=@('-NoLogo','-NoProfile','-File',(Join-Path $PSScriptRoot 'helpers/mock-server.ps1'),'-Port',"$port",'-Mode',$mode,'-DiagnosticPath',$diagnosticPath)
            endpoint="http://127.0.0.1:$port/v1"; selectedAdapters=@([pscustomobject]@{device='Vulkan0'})
            hardwareFingerprint='synthetic';engineVersion='test';model=[pscustomobject]@{id='test-model';contextSize=1024;sha256=('0'*64)}
        }
        if ($mode -in @('ok','flood','diagduplicate','diagflood')) {
            $plan | Add-Member -NotePropertyMembers @{catalogVersion='test';backend='Vulkan';splitMode='none';tensorSplit=$null;modelPath='test-model'}
            $plan.model | Add-Member -NotePropertyMembers @{parallel=1;cacheTypeK='f16';cacheTypeV='f16'}
            $plan.serverArguments+=@('-Model','test-model')
            $savedEnvironment=@{}
            foreach($name in @('LLAMA_ARG_MODEL','GGML_TEST_OVERRIDE','VK_TEST_OVERRIDE','HIP_TEST_OVERRIDE','SMITHY_TEST_OVERRIDE','AIP_TEST_OVERRIDE','FASTLLM_TEST_EXPECT_ISOLATION')){
                $savedEnvironment[$name]=[Environment]::GetEnvironmentVariable($name)
                [Environment]::SetEnvironmentVariable($name,$(if($name -eq 'FASTLLM_TEST_EXPECT_ISOLATION'){'1'}else{'hostile-test-override'}))
            }
            # Stop from an independent client once the supervisor declares readiness.
            $stopper=New-Object Diagnostics.Process
            $stopper.StartInfo.FileName=(Get-Process -Id $PID).Path
            $stopCode="Import-Module '$($root.Replace("'","''"))/src/FastLlm.psm1'; for (`$i=0; `$i -lt 150; `$i++) { try { `$s=Get-FastLlmStatus '$($runRoot.Replace("'","''"))'; if (`$s.phase -eq 'ready') { if (-not `$s.processIdentity -or `$s.processIdentity.pid -le 0 -or `$s.processIdentity.startUtcTicks -le 0) { exit 2 }; `$child=[Diagnostics.Process]::GetProcessById([int]`$s.processIdentity.pid); try { if (`$child.StartTime.ToUniversalTime().Ticks -ne [long]`$s.processIdentity.startUtcTicks) { exit 3 } } finally { `$child.Dispose() }; Request-FastLlmStop '$($runRoot.Replace("'","''"))'; exit 0 } } catch {}; Start-Sleep -Milliseconds 200 }; exit 1"
            $stopper.StartInfo.Arguments='-NoLogo -NoProfile -OutputFormat Text -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($stopCode))
            $stopper.StartInfo.UseShellExecute=$false
            $stopper.Start()|Out-Null
            try {
                $result=& $module { param($P,$R,$C) Invoke-FastLlmSupervisedServer -Plan $P -InstallRoot $R -LoadTimeoutSeconds 15 -CatalogPath $C } $plan $runRoot $catalog
                Check ($result -eq 0) 'healthy supervised API reaches readiness then obeys stop'
                Check ($result -eq 0) 'native mock child observes empty config roots and stripped inherited overrides'
                Check ($stopper.WaitForExit(5000) -and $stopper.ExitCode -eq 0) 'independent stop client observed readiness'
                $status=Get-FastLlmStatus $runRoot
                Check ($status.canary.streaming -and $status.placement.reportedAllLayers) 'readiness evidence is retained without generated text'
                Check (-not $status.canary.semanticCorrectnessQualified -and -not $status.performanceQualified) 'synthetic smoke tests cannot certify physical correctness or speed'
                Check ($status.recipe.requestedArguments -contains '<verified-model>') 'runtime recipe redacts the verified model path'
                Check ($status.recipe.catalogSha256 -eq (Get-FileHash $catalog -Algorithm SHA256).Hash.ToLowerInvariant()) 'runtime recipe identifies the actual supplied catalog'
                Check ($status.processIdentity.pid -gt 0 -and $status.processIdentity.startUtcTicks -gt 0 -and $status.processIdentity.pid -ne $PID) 'run status retains the actual child identity without using it as a stop target'
                $expectedDiagnosticStatus=switch($mode){diagduplicate{'duplicate'};diagflood{'overflow'};default{'captured'}}
                Check ($status.startupDiagnostics.status -eq $expectedDiagnosticStatus -and -not $status.startupDiagnostics.physicalResidencyVerified) 'bounded startup-only diagnostic state persists without claiming residency'
                Check ($status.selectedDeviceCapture.likeLines -ge 0 -and $status.selectedDeviceCapture.malformedLines -ge 0 -and $status.selectedDeviceCapture.overflow -is [bool] -and $status.selectedDeviceCapture.diagnostics -notmatch 'Radeon|canary|private') 'bounded same-child selection counts persist without device descriptions or canary text'
                if($mode -eq 'diagflood'){
                    Check (-not $status.selectedDeviceIdentity.identityVerified -and $status.selectedDeviceIdentity.failureReason -eq 'missing-or-extra-selected-device') 'missing selected-device log remains explicitly unverified without blocking Ready'
                }elseif($mode -eq 'diagduplicate'){
                    Check (-not $status.selectedDeviceIdentity.identityVerified -and $status.selectedDeviceIdentity.failureReason -eq 'malformed-selected-device-line') 'malformed selected-device log remains explicitly unverified without blocking Ready'
                }else{
                    Check ($status.selectedDeviceIdentity.identityVerified -and $status.selectedDeviceIdentity.selectedDevices.Count -eq 1 -and $status.selectedDeviceIdentity.selectedDevices[0].pciBdf -eq '0000:03:00.0') 'same-child selected-device evidence persists for expected adapter'
                }
                Check (-not $status.selectedDeviceIdentity.physicalIdentityVerified -and -not $status.selectedDeviceIdentity.physicalResidencyVerified -and -not $status.selectedDeviceIdentity.operationPlacementVerified) 'same-child selection is not promoted to physical identity, residency, or operation evidence'
                if($mode -eq 'ok'){
                    Check ($status.startupDiagnostics.computeBuffers[0].sizeMiB -eq 64 -and $status.startupDiagnostics.requestedFlashAttention -eq 'auto') 'canary-time log lookalike is excluded and requested versus reported flash mode is explicit'
                    Check ((Get-Content -LiteralPath (Join-Path $runRoot 'state/status.json') -Raw) -notmatch 'private/untrusted-text|999\.00|canary-time text|0000:04:00\.0') 'untrusted startup text and canary-time lookalikes never enter persisted state'
                }
                Check ($status.placement.modelBufferMiB[0].sizeMiB -eq 1200) 'lifecycle retains the selected GPU model-buffer MiB'
                $history=Read-FastLlmJson (Join-Path $runRoot 'state/synthetic.last-ready.json')
                Check ($history.kind -eq 'api-smoke-only' -and $history.modelSha256 -eq $plan.model.sha256) 'recovery history is recorded only as exact-artifact API smoke evidence'
            } catch {
                $marker='not-written'
                if (Test-Path -LiteralPath $diagnosticPath) {
                    try { $marker=[string](Get-Content -LiteralPath $diagnosticPath -Raw -ErrorAction Stop) } catch { $marker='unreadable' }
                }
                Write-Host ('Unexpected mock child state for ' + $mode + ': ' + $marker.Substring(0,[Math]::Min(500,$marker.Length)))
                throw
            } finally {
                foreach($name in $savedEnvironment.Keys){[Environment]::SetEnvironmentVariable($name,$savedEnvironment[$name])}
                if (-not $stopper.HasExited) { $stopper.Kill() };$stopper.Dispose()
            }
        } else {
            $pattern=switch($mode){partial{'not report all'};context{'Effective context'};unstable{'not repeatable'};chat{'no text'};sse{'completion marker'};exit{'before readiness'};timeout{'deadline'};duplicate{'ambiguous'}}
            Throws { & $module { param($P,$R,$T) Invoke-FastLlmSupervisedServer -Plan $P -InstallRoot $R -LoadTimeoutSeconds $T } $plan $runRoot $(if($mode -eq 'timeout'){2}else{15}) } $pattern
            Check ((Get-FastLlmStatus $runRoot).phase -eq 'failed') "$mode failure recorded"
        }
        $probe=New-Object Net.Sockets.TcpClient
        try { $probe.Connect('127.0.0.1',$port);throw 'Leaked child server remains listening.' } catch [Net.Sockets.SocketException] { Check $true "$mode child was terminated" } finally { $probe.Dispose() }
        $lock.Dispose();$lock=$null
    }

    $httpHost=New-Object Bitworks.FastLlm.ProcessHost
    try {
        $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
        $listener.Start();$port=$listener.LocalEndpoint.Port
        $conflictPlan=[pscustomobject]@{
            enginePath='must-not-execute';serverArguments=@();endpoint="http://127.0.0.1:$port/v1"
            hardwareFingerprint='synthetic';engineVersion='test';model=[pscustomobject]@{id='test';sha256=('0'*64)}
        }
        $caught=$false
        try { & $module { param($P,$R) Invoke-FastLlmSupervisedServer $P $R } $conflictPlan (Join-Path $temp 'conflict') }
        catch { $caught=$true }
        finally { $listener.Stop() }
        Check ($caught -and (Get-FastLlmStatus (Join-Path $temp 'conflict')).phase -eq 'failed') 'occupied port fails before spawning an engine'
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=(Get-Process -Id $PID).Path
        $info.Arguments=& $module {param($A) Join-FastLlmProcessArguments $A} @('-NoLogo','-NoProfile','-File',(Join-Path $PSScriptRoot 'helpers/mock-server.ps1'),'-Port',"$port",'-Mode','ok')
        $httpHost.Start($info)
        $healthy=$false
        for($attempt=0;$attempt -lt 150;$attempt++){
            try{$healthy=[Bitworks.FastLlm.LoopbackHttp]::Request("http://127.0.0.1:$port/health",$null,200,1000).Status -eq 200}catch{}
            if($healthy){break};Start-Sleep -Milliseconds 100
        }
        Check $healthy 'HTTP transport mock is ready'
        $abandoned=New-Object Net.Sockets.TcpClient
        $abandoned.Connect('127.0.0.1',$port)
        $abandoned.Client.LingerState=New-Object Net.Sockets.LingerOption($true,0)
        try {
            $request=[Text.Encoding]::ASCII.GetBytes("GET /health HTTP/1.1`r`nHost: 127.0.0.1`r`nConnection: close`r`n`r`n")
            $stream=$abandoned.GetStream()
            $stream.Write($request,0,$request.Length)
        } finally { $abandoned.Close() }
        $healthyAfterReset=$false
        for($attempt=0;$attempt -lt 20;$attempt++){
            try{$healthyAfterReset=[Bitworks.FastLlm.LoopbackHttp]::Request("http://127.0.0.1:$port/health",$null,200,1000).Status -eq 200}catch{}
            if($healthyAfterReset){break};Start-Sleep -Milliseconds 100
        }
        Check ($healthyAfterReset -and -not $httpHost.Process.HasExited) 'mock survives an abruptly reset health client'
        $soakState=[pscustomobject]@{runId='synthetic';active=$true;phase='ready';endpoint="http://127.0.0.1:$port/v1";modelId='test-model';recipe=[pscustomobject]@{contextSize=1024}}
        $soak=& $module {param($S) Invoke-FastLlmApiSoakCore -State $S -ReadState { $S } -MinimumCycles 2 -DurationSeconds 0} $soakState
        Check ($soak.completed -and $soak.completedCycles -eq 2) 'API soak exercises real HTTP without storing generated text'
        $soak=& $module {param($S) Invoke-FastLlmApiSoakCore -State $S -ReadState { [pscustomobject]@{runId='other';phase='ready';active=$true} } -MinimumCycles 2 -DurationSeconds 0} $soakState
        Check (-not $soak.completed -and $soak.completedCycles -eq 0) 'API soak stops on a changed supervisor run'
        Check ([Bitworks.FastLlm.LoopbackHttp]::Request("http://127.0.0.1:$port/redirect",$null,1000,1000).Status -eq 302) 'HTTP client never follows a remote redirect'
        Throws { [Bitworks.FastLlm.LoopbackHttp]::Request("http://127.0.0.1:$port/oversize",$null,1000,1048576) } 'exceeds limit'
    } finally { $httpHost.Dispose() }

    # A separate child avoids a prior aborted oversized response changing this test.
    $stallHost=New-Object Bitworks.FastLlm.ProcessHost
    try {
        $stallHost.Start($info)
        $healthy=$false
        for($attempt=0;$attempt -lt 150;$attempt++){
            try{$healthy=[Bitworks.FastLlm.LoopbackHttp]::Request("http://127.0.0.1:$port/health",$null,200,1000).Status -eq 200}catch{}
            if($healthy){break};Start-Sleep -Milliseconds 100
        }
        Check $healthy 'deadline transport mock is ready'
        $elapsed=[Diagnostics.Stopwatch]::StartNew();$caught=$false
        try { [Bitworks.FastLlm.LoopbackHttp]::Request("http://127.0.0.1:$port/stall",$null,200,1000) } catch { $caught=$true }
        Check ($caught -and $elapsed.Elapsed.TotalSeconds -lt 5) 'a stalled HTTP request is bounded by its whole-request deadline'
    } finally { $stallHost.Dispose() }
} finally { if($lock){$lock.Dispose()}; if(Test-Path $temp){Remove-Item -LiteralPath $temp -Recurse -Force} }
Write-Host "$count runtime checks passed. Mock services are not Windows/AMD qualification."
