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
function Get-RuntimeTestProcessEvidence([int]$ProcessId,[long]$ExpectedStartUtcTicks=0) {
    $evidence=[ordered]@{pid=$ProcessId; identityState='not-found'; alive=$false; startUtcTicks=$null; matchesExpectedStart=$false; inspectionError=$null}
    if($ProcessId -le 0){return [pscustomobject]$evidence}
    $observed=$null
    try {
        $observed=[Diagnostics.Process]::GetProcessById($ProcessId)
        $evidence.startUtcTicks=[long]$observed.StartTime.ToUniversalTime().Ticks
        $evidence.alive=-not $observed.HasExited
        $evidence.matchesExpectedStart=($ExpectedStartUtcTicks -gt 0 -and $evidence.startUtcTicks -eq $ExpectedStartUtcTicks)
        $evidence.identityState=if(-not $evidence.alive){'exited'}elseif($ExpectedStartUtcTicks -le 0){'alive-unbound'}elseif($evidence.matchesExpectedStart){'alive-same'}else{'alive-different'}
    } catch [ArgumentException] {
        # The process is already gone; keep the recorded identity for comparison.
    } catch {
        $evidence.identityState='inspection-failed'
        $evidence.inspectionError=$_.Exception.GetType().Name
    } finally {
        if($observed){$observed.Dispose()}
    }
    return [pscustomobject]$evidence
}
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
$listText=(1..20 | ForEach-Object { "device-info Vulkan$_ $(1000+$_) $(500+$_) GPU number $_" }) -join "`n"
$useText=(1..20 | ForEach-Object { "using-device Vulkan$_ 0000:0$($_ % 8):00.0 $(400+$_) Adapter $_" }) -join "`n"
$entries=& $module {param($I,$U) ConvertFrom-FastLlmServerDeviceListEntries -DeviceInfoText $I -UsingDeviceText $U} $listText $useText
Check ($entries.deviceInfo.Count -eq 16 -and $entries.usingDevice.Count -eq 16) 'persisted server device-list entries are capped at 16 each'
Check ($entries.deviceInfo[0].name -ceq 'Vulkan1' -and $entries.deviceInfo[0].totalMiB -eq 1001 -and $entries.deviceInfo[0].freeMiB -eq 501 -and $entries.deviceInfo[0].description -ceq 'GPU number 1') 'device_info entries round-trip as fields'
Check ($entries.usingDevice[1].name -ceq 'Vulkan2' -and $entries.usingDevice[1].id -ceq '0000:02:00.0' -and $entries.usingDevice[1].freeMiB -eq 402 -and $entries.usingDevice[1].description -ceq 'Adapter 2') 'using-device entries round-trip as fields'
$unknownId=& $module {ConvertFrom-FastLlmServerDeviceListEntries -DeviceInfoText '' -UsingDeviceText "using-device Vulkan0 unknown 18000 AMD Radeon RX 7900 XT`n"}
Check ($unknownId.usingDevice.Count -eq 1 -and $unknownId.usingDevice[0].id -ceq 'unknown' -and $unknownId.deviceInfo.Count -eq 0) 'unknown device id and empty device_info text are kept as fields'
$odd=& $module {param($T) ConvertFrom-FastLlmServerDeviceListEntries -DeviceInfoText $T -UsingDeviceText ''} ("device-info Vulkan0 100 50 Odd " + [string][char]0x2122 + [string][char]7 + (' x' * 100))
Check ($odd.deviceInfo.Count -eq 1 -and $odd.deviceInfo[0].description -cmatch '^[\x20-\x7e]{1,128}$' -and $odd.deviceInfo[0].description.StartsWith('Odd ??')) 'persisted description stays printable ASCII and bounded'
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
$suitePassed=$false
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
    Check ($recovered.recipe.origin -ceq 'estimated' -and $recovered.recipe.label -ceq 'Estimated for your card' -and $recovered.recovered) 'a recovered plan is labelled estimated, never Chosen by you'
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
                Check ($status.serverDeviceListCapture.deviceInfoLikeLines -ge 0 -and $status.serverDeviceListCapture.deviceInfoMalformedLines -ge 0 -and $status.serverDeviceListCapture.deviceInfoOverflow -is [bool] -and $status.serverDeviceListCapture.usingDeviceLikeLines -ge 0 -and $status.serverDeviceListCapture.usingDeviceMalformedLines -ge 0 -and $status.serverDeviceListCapture.usingDeviceOverflow -is [bool] -and $status.serverDeviceListCapture.diagnostics -match '^deviceInfo\(like=\d+' -and $status.serverDeviceListCapture.diagnostics -notmatch 'Radeon|canary|private') 'the server device-list capture is frozen before the canary and records counts and reason-only diagnostics'
                Check (@($status.serverDeviceListCapture.deviceInfo).Count -eq 1 -and $status.serverDeviceListCapture.deviceInfo[0].name -ceq 'Vulkan0' -and $status.serverDeviceListCapture.deviceInfo[0].totalMiB -eq 24560 -and $status.serverDeviceListCapture.deviceInfo[0].freeMiB -eq 20304 -and $status.serverDeviceListCapture.deviceInfo[0].description -ceq 'AMD Radeon RX 7900 XTX' -and @($status.serverDeviceListCapture.usingDevice).Count -le 2 -and ($mode -ne 'ok' -or (@($status.serverDeviceListCapture.usingDevice).Count -eq 1 -and $status.serverDeviceListCapture.usingDevice[0].name -ceq 'Vulkan0' -and $status.serverDeviceListCapture.usingDevice[0].id -ceq '0000:03:00.0' -and $status.serverDeviceListCapture.usingDevice[0].freeMiB -eq 20000 -and $status.serverDeviceListCapture.usingDevice[0].description -ceq 'AMD Radeon RX 7900 XTX'))) 'the parsed server device-list entries persist in status.json as fields only'
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
        try {
            $probe.Connect('127.0.0.1',$port)
            # This is failure-only evidence, not a grace period or a replacement
            # for the immediate strict listener assertion above.
            $diagnosticPath=Join-Path $runRoot 'post-stop-listener-diagnostic.json'
            try {
                $finalStatus=Get-FastLlmStatus $runRoot
                $recordedPid=0
                $recordedTicks=0L
                if($finalStatus.processIdentity){
                    $recordedPid=[int]$finalStatus.processIdentity.pid
                    $recordedTicks=[long]$finalStatus.processIdentity.startUtcTicks
                }
                $listenerOwners=@()
                $listenerQueryError=$null
                if($env:OS -eq 'Windows_NT'){
                    try {
                        if(-not ('Bitworks.FastLlm.WindowsGpuTelemetry' -as [type])){
                            Add-Type -Path (Join-Path $root 'src/WindowsGpuTelemetry.cs') -ErrorAction Stop
                        }
                        $listenerOwners=@([Bitworks.FastLlm.WindowsGpuTelemetry]::GetLoopbackListenerOwners($port) |
                            Select-Object -First 8 |
                            ForEach-Object { Get-RuntimeTestProcessEvidence -ProcessId ([int]$_) })
                    } catch {$listenerQueryError=$_.Exception.GetType().Name}
                }else{$listenerQueryError='not-windows'}
                $diagnostic=[ordered]@{
                    kind='runtime-post-stop-listener-diagnostic';mode=$mode;port=[int]$port
                    observedAtUtc=(Get-Date).ToUniversalTime().ToString('o')
                    finalPhase=[string]$finalStatus.phase
                    supervisedProcess=(Get-RuntimeTestProcessEvidence -ProcessId $recordedPid -ExpectedStartUtcTicks $recordedTicks)
                    recordedStartUtcTicks=$recordedTicks
                    listenerOwners=@($listenerOwners);listenerQueryError=$listenerQueryError
                }
                $diagnosticJson=$diagnostic|ConvertTo-Json -Depth 5 -Compress
                Write-Warning "Unexpected listener evidence: $diagnosticJson"
                [IO.File]::WriteAllText($diagnosticPath,$diagnosticJson,[Text.Encoding]::UTF8)
                Write-Warning "Unexpected listener diagnostic retained: $diagnosticPath"
            } catch {
                Write-Warning ('Unexpected listener diagnostic could not be completed: '+$_.Exception.GetType().Name)
            }
            throw 'Leaked child server remains listening.'
        } catch [Net.Sockets.SocketException] { Check $true "$mode child was terminated" } finally { $probe.Dispose() }
        $lock.Dispose();$lock=$null
    }

    # Post-load self-test inside a mock supervised start (a failed self-test must not announce ready): the verdict is in before ANY ready announcement
    # (status phase, Ready console line) and before the last-ready recovery record is rewritten. A hard fail keeps the previous record.
    $savedWriteState=& $module {(Get-Command Write-FastLlmState).ScriptBlock}
    try {
        foreach ($selfTestCase in @(@{mode='selftest-ok';context=1024;label='selftest-ok'},@{mode='ok';context=1024;label='ok'},@{mode='selftest-ok';context=600;label='small-context'})) {
            $selfTestMode=$selfTestCase.mode
            $expectPass=($selfTestMode -ceq 'selftest-ok')
            $expectSkip=($selfTestCase.context -lt 648)
            $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
            $listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
            $runRoot=Join-Path $temp ('selftest-case-'+$selfTestCase.label)
            $lock=Enter-FastLlmOperation $runRoot
            $plan=[pscustomobject]@{
                enginePath=(Get-Process -Id $PID).Path
                serverArguments=@('-NoLogo','-NoProfile','-File',(Join-Path $PSScriptRoot 'helpers/mock-server.ps1'),'-Port',"$port",'-Mode',$selfTestMode,'-Model','test-model','-Context',"$($selfTestCase.context)")
                endpoint="http://127.0.0.1:$port/v1"; selectedAdapters=@([pscustomobject]@{device='Vulkan0'})
                hardwareFingerprint='synthetic';engineVersion='test';model=[pscustomobject]@{id='test-model';contextSize=$selfTestCase.context;sha256=('0'*64)}
                catalogVersion='test';backend='Vulkan';splitMode='none';tensorSplit=$null;modelPath='test-model'
                recipe=[pscustomobject]@{id='r1';origin='bitworks';label='Measured by Bitworks on this card';evidenceUrl='https://bitworks.io/amd/results/x';expected=$null}
            }
            $plan.model | Add-Member -NotePropertyMembers @{parallel=1;cacheTypeK='f16';cacheTypeV='f16'}
            $priorRecord=[ordered]@{kind='api-smoke-only';hardwareFingerprint='synthetic';modelId='prior-model';modelSha256=('1'*64);catalogSha256=('2'*64)}
            Write-FastLlmState $runRoot $priorRecord 'synthetic.last-ready.json'
            $recordPath=Join-Path $runRoot 'state/synthetic.last-ready.json'
            $priorText=[IO.File]::ReadAllText($recordPath)
            $writeLog=New-Object 'Collections.Generic.List[string]'
            & $module {
                param($Log,$Original)
                $script:selfTestWriteLog=$Log;$script:selfTestOriginalWrite=$Original
                function script:Write-FastLlmState {
                    param([string]$InstallRoot,$State,[string]$FileName='status.json')
                    if ($FileName -ceq 'status.json') { $script:selfTestWriteLog.Add('status:'+[string]$State.phase) } else { $script:selfTestWriteLog.Add($FileName) }
                    & $script:selfTestOriginalWrite -InstallRoot $InstallRoot -State $State -FileName $FileName
                }
                # Console lines go into the same ordered log (a start that throws would otherwise lose its captured output).
                # A plain (non-advanced) function so any Write-Host argument form is accepted.
                function script:Write-Host { $script:selfTestWriteLog.Add('host:' + [string] $args[0]) }
            } $writeLog $savedWriteState
            $stopper=$null
            if ($expectPass -or $expectSkip) {
                $stopper=New-Object Diagnostics.Process
                $stopper.StartInfo.FileName=(Get-Process -Id $PID).Path
                $stopCode="Import-Module '$($root.Replace("'","''"))/src/FastLlm.psm1'; for (`$i=0; `$i -lt 150; `$i++) { try { `$s=Get-FastLlmStatus '$($runRoot.Replace("'","''"))'; if (`$s.phase -eq 'ready') { Request-FastLlmStop '$($runRoot.Replace("'","''"))'; exit 0 } } catch {}; Start-Sleep -Milliseconds 200 }; exit 1"
                $stopper.StartInfo.Arguments='-NoLogo -NoProfile -OutputFormat Text -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($stopCode))
                $stopper.StartInfo.UseShellExecute=$false
                $stopper.Start()|Out-Null
            }
            $exit=$null;$failure=$null;$console=@()
            try {
                try {
                    $out=@(& $module { param($P,$R,$C) Invoke-FastLlmSupervisedServer -Plan $P -InstallRoot $R -LoadTimeoutSeconds 15 -CatalogPath $C -SelfTest } $plan $runRoot $catalog 6>&1)
                    foreach ($item in $out) { if ($item -is [Management.Automation.InformationRecord]) { $console += [string]$item } elseif ($item -is [int]) { $exit = $item } }
                } catch { $failure=$_.Exception }
            } finally {
                & $module { param($Original) Set-Item -Path 'Function:script:Write-FastLlmState' -Value $Original; Remove-Item -Path 'Function:script:Write-Host' -ErrorAction SilentlyContinue } $savedWriteState
                if ($stopper) { if (-not $stopper.HasExited) { $stopper.Kill() }; $stopper.Dispose() }
            }
            # Diagnostics only: name the start's own failure before any check reads its files, so an unexpected throw is not hidden behind a missing selftest.json.
            if ($null -ne $failure) { Write-Host ("Self-test case $($selfTestCase.label): the start raised: " + [regex]::Replace([string]$failure.Message,'[\x00-\x1f\x7f]',' ')) }
            $log=@($writeLog)
            $iSelfTest=$log.IndexOf('selftest.json');$iReady=$log.IndexOf('status:ready');$iRecord=$log.IndexOf('synthetic.last-ready.json')
            $iSelfTestLine=-1;$iReadyLine=-1
            for ($k=0;$k -lt $log.Count;$k++) {
                if ($iSelfTestLine -lt 0 -and $log[$k] -like 'host:Self-test*') { $iSelfTestLine=$k }
                if ($iReadyLine -lt 0 -and $log[$k] -like 'host:Ready:*') { $iReadyLine=$k }
            }
            $finalStatus=Get-FastLlmStatus $runRoot
            Check ($finalStatus.planRecipe.id -ceq 'r1' -and $finalStatus.planRecipe.origin -ceq 'bitworks' -and $finalStatus.planRecipe.evidenceUrl -ceq 'https://bitworks.io/amd/results/x') "self-test case $($selfTestCase.label): the status records the running plan's recipe"
            Check ($finalStatus.engineExecutable -ceq $plan.enginePath -and $finalStatus.engineComponentId -ceq 'llama.cpp-test-vulkan') "self-test case $($selfTestCase.label): the status records the engine executable that runs and its engine component id"
            $selfTestFile=Read-FastLlmJson (Join-Path $runRoot 'state/selftest.json')
            if ($expectSkip) {
                Check ($null -eq $failure -and $exit -eq 0) 'self-test skip: a context too small for the workload does not fail the start'
                Check ($selfTestFile.result.status -ceq 'skipped' -and @($selfTestFile.result.reasons) -contains 'context-too-small') 'self-test skip: selftest.json records skipped with the reason context-too-small'
                Check ($iSelfTest -ge 0 -and $iReady -gt $iSelfTest -and $iRecord -gt $iReady -and $iReadyLine -gt $iSelfTestLine -and $iSelfTestLine -ge 0) 'self-test skip: the skip is recorded before ready and the Ready line follows it'
                Check (@($log | Where-Object { $_ -like 'host:Self-test skipped*' }).Count -eq 1) 'self-test skip: the console says the self-test was skipped'
            } elseif ($expectPass) {
                Check ($null -eq $failure -and $exit -eq 0) 'self-test pass: the supervised start completes and obeys stop'
                Check ($iSelfTest -ge 0 -and $iReady -gt $iSelfTest -and $iRecord -gt $iReady) 'self-test pass: the verdict is written before the ready status and the last-ready record'
                Check ($iSelfTestLine -ge 0 -and $iReadyLine -gt $iSelfTestLine -and $iReadyLine -gt $iSelfTest -and $iReady -lt $iReadyLine) 'self-test pass: the Ready line is printed after the self-test line and after the ready status'
                Check ($selfTestFile.result.status -ceq 'pass' -and $selfTestFile.schemaVersion -eq 1) 'self-test pass: selftest.json records the verdict'
                $newRecord=Read-FastLlmJson $recordPath
                Check ($newRecord.modelId -ceq 'test-model') 'self-test pass: the last-ready record is rewritten for the model that passed'
            } else {
                Check ($null -ne $failure -and $failure.Data['FastLlmReason'] -ceq 'RuntimeCheckFailed' -and $failure.Message -match 'Self-test failed') 'self-test hard fail: the start raises RuntimeCheckFailed so recovery runs'
                Check ($iSelfTest -ge 0 -and $iReady -eq -1 -and $iRecord -eq -1) 'self-test hard fail: no ready status and no last-ready write ever happened'
                Check ($iReadyLine -eq -1 -and $iSelfTest -ge 0) 'self-test hard fail: the Ready line is never printed'
                Check ($finalStatus.phase -ceq 'failed' -and $selfTestFile.result.status -ceq 'fail') 'self-test hard fail: the run ends failed and the verdict is recorded'
                Check ([IO.File]::ReadAllText($recordPath) -ceq $priorText) 'self-test hard fail: the previous last-ready record survives byte for byte'
                Check ((Read-FastLlmJson $recordPath).modelId -cne $plan.model.id) 'self-test hard fail: recovery can still use the previous record (it does not name the failed model)'
            }
            $probe=New-Object Net.Sockets.TcpClient
            try {
                $probe.Connect('127.0.0.1',$port)
                throw 'Leaked self-test child server remains listening.'
            } catch [Net.Sockets.SocketException] { Check $true "self-test case $($selfTestCase.label) child was terminated" } finally { $probe.Dispose() }
            $lock.Dispose();$lock=$null
        }
    } finally {
        & $module { param($Original) Set-Item -Path 'Function:script:Write-FastLlmState' -Value $Original; Remove-Item -Path 'Function:script:Write-Host' -ErrorAction SilentlyContinue } $savedWriteState
    }


    # The start-time fallback launches a second server right after the first failed: the first one must be fully gone (child process, port, status file)
    # and the second run must carry the fallback and its own recipe into status.json and selftest.json. Same run root, same port, mock servers.
    $fallbackListener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
    $fallbackListener.Start();$fallbackPort=$fallbackListener.LocalEndpoint.Port;$fallbackListener.Stop()
    $fallbackRoot=Join-Path $temp 'fallback-sequence'
    $fallbackLock=Enter-FastLlmOperation $fallbackRoot
    try {
        function New-FallbackSequencePlan([string]$Mode,[string]$RecipeId) {
            $built=[pscustomobject]@{
                enginePath=(Get-Process -Id $PID).Path
                serverArguments=@('-NoLogo','-NoProfile','-File',(Join-Path $PSScriptRoot 'helpers/mock-server.ps1'),'-Port',"$fallbackPort",'-Mode',$Mode,'-Model','test-model','-Context','1024')
                endpoint="http://127.0.0.1:$fallbackPort/v1"; selectedAdapters=@([pscustomobject]@{device='Vulkan0'})
                hardwareFingerprint='synthetic';engineVersion='test';model=[pscustomobject]@{id='test-model';contextSize=1024;sha256=('0'*64)}
                catalogVersion='test';backend='Vulkan';splitMode='none';tensorSplit=$null;modelPath='test-model'
                recipe=[pscustomobject]@{id=$RecipeId;origin='bitworks';label='Measured by Bitworks on this card';evidenceUrl=$null;expected=$null}
            }
            $built.model | Add-Member -NotePropertyMembers @{parallel=1;cacheTypeK='f16';cacheTypeV='f16'}
            return $built
        }
        # A run that cannot even spawn (the port is occupied) is untyped and has no runtime reason: the start-time fallback never applies to it.
        $occupier=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,$fallbackPort)
        $occupier.Server.ExclusiveAddressUse=$true;$occupier.Start()
        $occupiedFailure=$null
        try { & $module { param($P,$R,$C) Invoke-FastLlmSupervisedServer -Plan $P -InstallRoot $R -LoadTimeoutSeconds 15 -CatalogPath $C | Out-Null } (New-FallbackSequencePlan 'ok' 'hip-recipe') $fallbackRoot $catalog } catch { $occupiedFailure=$_.Exception } finally { $occupier.Stop() }
        Check ($null -ne $occupiedFailure -and [string]::IsNullOrEmpty([string]$occupiedFailure.Data['FastLlmReason']) -and [string]::IsNullOrEmpty([string]$occupiedFailure.Data['FastLlmFailureCode'])) 'an occupied port fails the supervised run before the spawn with no typed code and no runtime reason (so it never falls back)'
        Check (([IO.File]::ReadAllText((Join-Path $PSScriptRoot '../src/FastLlm.Runtime.ps1'))).Contains("if (`$reachedReady) { `$_.Exception.Data['FastLlmAfterReady']=`$true }")) 'a failure after the supervisor reached ready is tagged FastLlmAfterReady'
        # First run: the server loads, then the run fails (the child is alive when the failure is raised).
        $firstFailure=$null
        try { & $module { param($P,$R,$C) Invoke-FastLlmSupervisedServer -Plan $P -InstallRoot $R -LoadTimeoutSeconds 15 -CatalogPath $C } (New-FallbackSequencePlan 'unstable' 'hip-recipe') $fallbackRoot $catalog | Out-Null } catch { $firstFailure=$_.Exception }
        $firstStatus=Get-FastLlmStatus $fallbackRoot
        Check ($null -ne $firstFailure -and $firstStatus.phase -ceq 'failed' -and $firstStatus.processIdentity.pid -gt 0) 'fallback sequence: the first run fails with a recorded child'
        $firstChildAlive=$true
        try { $firstChild=Get-Process -Id ([int]$firstStatus.processIdentity.pid) -ErrorAction Stop; $firstChildAlive=(-not $firstChild.HasExited) -and ($firstChild.StartTime.ToUniversalTime().Ticks -eq [long]$firstStatus.processIdentity.startUtcTicks) } catch { $firstChildAlive=$false }
        Check (-not $firstChildAlive) 'fallback sequence: the first run''s server process is gone before the supervised start returns'
        $freeProbe=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,$fallbackPort)
        $portFree=$true
        try { $freeProbe.Server.ExclusiveAddressUse=$true; $freeProbe.Start() } catch { $portFree=$false } finally { try { $freeProbe.Stop() } catch { } }
        Check $portFree 'fallback sequence: the first run''s port is free again, so the second launch cannot collide with it'
        # Second run: the stand-in, carrying the fallback, with the self-test on.
        $secondPlan=New-FallbackSequencePlan 'selftest-ok' 'vulkan-recipe'
        $secondPlan | Add-Member -NotePropertyName fallback -NotePropertyValue ([pscustomobject]@{fromRecipe='hip-recipe';toRecipe='vulkan-recipe';toModelId='test-model';reason='hip-dll-missing';applied=$true})
        $secondStopper=New-Object Diagnostics.Process
        $secondStopper.StartInfo.FileName=(Get-Process -Id $PID).Path
        $secondStopCode="Import-Module '$($root.Replace("'","''"))/src/FastLlm.psm1'; for (`$i=0; `$i -lt 150; `$i++) { try { `$s=Get-FastLlmStatus '$($fallbackRoot.Replace("'","''"))'; if (`$s.phase -eq 'ready') { Request-FastLlmStop '$($fallbackRoot.Replace("'","''"))'; exit 0 } } catch {}; Start-Sleep -Milliseconds 200 }; exit 1"
        $secondStopper.StartInfo.Arguments='-NoLogo -NoProfile -OutputFormat Text -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($secondStopCode))
        $secondStopper.StartInfo.UseShellExecute=$false
        $secondStopper.Start()|Out-Null
        $secondFailure=$null;$secondExit=$null
        try { $secondExit=& $module { param($P,$R,$C) Invoke-FastLlmSupervisedServer -Plan $P -InstallRoot $R -LoadTimeoutSeconds 15 -CatalogPath $C -SelfTest } $secondPlan $fallbackRoot $catalog } catch { $secondFailure=$_.Exception }
        finally { if (-not $secondStopper.HasExited) { $secondStopper.Kill() }; $secondStopper.Dispose() }
        if ($null -ne $secondFailure) { Write-Host ('Fallback sequence: the second run raised: ' + [regex]::Replace([string]$secondFailure.Message,'[\x00-\x1f\x7f]',' ')) }
        $secondStatus=Get-FastLlmStatus $fallbackRoot
        Check ($null -eq $secondFailure -and $secondExit -eq 0) 'fallback sequence: the second run starts on the same port and run root, and obeys stop'
        Check ($secondStatus.fallback.fromRecipe -ceq 'hip-recipe' -and $secondStatus.fallback.toRecipe -ceq 'vulkan-recipe' -and $secondStatus.fallback.reason -ceq 'hip-dll-missing' -and $secondStatus.planRecipe.id -ceq 'vulkan-recipe') 'status.json after a fallback start contains fallback {fromRecipe, toRecipe, reason} and the recipe that ran'
        Check ($secondStatus.engine.backend -ceq 'vulkan' -and $secondStatus.engine.version -ceq 'test' -and $secondStatus.engine.componentId -ceq 'llama.cpp-test-vulkan' -and $secondStatus.engineVersion -ceq 'test') 'status.json records engine {backend, version, componentId} next to the existing engine fields'
        $fallbackSelfTest=Read-FastLlmJson (Join-Path $fallbackRoot 'state/selftest.json')
        Check ($fallbackSelfTest.recipeId -ceq 'vulkan-recipe') 'selftest.json after a fallback start names the recipe that ran (the Vulkan one)'
        # A start without a fallback records none.
        Check ($null -eq $firstStatus.PSObject.Properties['fallback']) 'a start without a fallback has no fallback field in status.json'
    } finally { $fallbackLock.Dispose() }

    # The failure text depends on how the HIP setup was chosen: an automatic choice is followed by the Vulkan setup, an explicit recipe is not.
    $autoHipPlan=[pscustomobject]@{backend='hip';engineComponentId='x';recipe=[pscustomobject]@{id='hip-recipe'}}
    $explicitHipPlan=[pscustomobject]@{backend='hip';engineComponentId='x';recipe=[pscustomobject]@{id='hip-recipe'};requestedRecipeId='hip-recipe'}
    $fellBackPlan=[pscustomobject]@{backend='hip';engineComponentId='x';recipe=[pscustomobject]@{id='hip-recipe'};fallback=[pscustomobject]@{applied=$true}}
    $wordingFor={ param($P) & $module { param($X) Get-FastLlmSelfTestFailureText -Reasons @('slow') -Plan $X } $P }
    Check ((& $wordingFor $autoHipPlan) -ceq 'Self-test failed (slow). The server was stopped; FastLLM starts the Vulkan setup instead.') 'an automatically chosen HIP setup''s self-test failure says the Vulkan setup is started instead'
    Check ((& $wordingFor $explicitHipPlan) -ceq 'Self-test failed (slow). The server was stopped; FastLLM does not switch to another setup on its own.') 'an explicit -Recipe HIP self-test failure still says FastLLM does not switch on its own'
    Check ((& $wordingFor $fellBackPlan) -ceq 'Self-test failed (slow). The server was stopped; FastLLM does not switch to another setup on its own.') 'a plan that already fell back never promises another fallback'
    foreach($wordingCase in @(@{label='hip-dll-blocked';exit=-1073740760},@{label='hip-dll-missing';exit=-1073741515})){
        $autoText=& $module { param($E) (New-FastLlmHipLaunchFailure -ComponentId 'eng-hip' -ExitCode $E -AutoSelected).Message } $wordingCase.exit
        $explicitText=& $module { param($E) (New-FastLlmHipLaunchFailure -ComponentId 'eng-hip' -ExitCode $E).Message } $wordingCase.exit
        Check ($autoText -like '*FastLLM starts the Vulkan setup instead.' -and $autoText -notlike '*does not switch to Vulkan on its own*' -and $explicitText -like '*FastLLM does not switch to Vulkan on its own.*') "$($wordingCase.label): the message for an automatic choice no longer says it does not switch; for an explicit recipe it still does"
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
        Check ($soak.completed -and $soak.completedCycles -eq 2) ('API soak exercises real HTTP without storing generated text' + $(if (-not $soak.completed) { " [failure=$($soak.failureCode) type=$($soak.failureType) cycles=$($soak.completedCycles) elapsed=$([int]$soak.elapsedSeconds)s]" }))
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
    # ================= the one child-environment builder, the HIP device list, and the typed HIP failures =================
    $envSandbox=[pscustomobject]@{appData='C:\sandbox\appdata';programData='C:\sandbox\programdata'}
    $inherited=@('PATH','HOME','HIP_VISIBLE_DEVICES','HSA_OVERRIDE_GFX_VERSION','ROCR_VISIBLE_DEVICES','ROCM_PATH','ROCBLAS_LAYER','GGML_VK_VISIBLE_DEVICES','LLAMA_ARG_PORT','VK_ICD_FILENAMES','HF_TOKEN','CUDA_VISIBLE_DEVICES','GPU_DEVICE_ORDINAL','HIPBLASLT_TENSILE_LIBPATH','AMD_LOG_LEVEL','GPU_MAX_HW_QUEUES','Hip_Path_Lower','USERPROFILE')
    $vulkanEnvPlan=[pscustomobject]@{backend='Vulkan';enginePath='C:\fl\engines\b10698\vulkan\llama-server.exe'}
    $hipEnvPlan=[pscustomobject]@{backend='hip';enginePath='C:\fl\components\engine\llama.cpp-hip-b11658\b11658\llama-server.exe';runtimeRoots=@('C:\fl\components\runtime\amd-rocm-gfx1100-10.0.0\10.0.0\bin')}
    $vulkanEnv=& $module { param($P,$S,$I) Get-FastLlmEngineEnvironment -Plan $P -Sandbox $S -InheritedNames $I -SystemRoot 'C:\Windows' } $vulkanEnvPlan $envSandbox $inherited
    Check (($vulkanEnv.set.Keys -join ',') -ceq 'APPDATA,PROGRAMDATA,PATH' -and $vulkanEnv.set['PATH'] -ceq 'C:\fl\engines\b10698\vulkan;C:\Windows\System32;C:\Windows' -and $vulkanEnv.set['APPDATA'] -ceq 'C:\sandbox\appdata' -and $vulkanEnv.set['PROGRAMDATA'] -ceq 'C:\sandbox\programdata') 'Vulkan environment is unchanged: APPDATA, PROGRAMDATA and PATH = engine dir;System32;SystemRoot, and no BAR variable by default'
    Check (($vulkanEnv.remove -join ',') -ceq 'HIP_VISIBLE_DEVICES,HSA_OVERRIDE_GFX_VERSION,ROCM_PATH,ROCBLAS_LAYER,GGML_VK_VISIBLE_DEVICES,LLAMA_ARG_PORT,VK_ICD_FILENAMES,HF_TOKEN,CUDA_VISIBLE_DEVICES,GPU_DEVICE_ORDINAL,Hip_Path_Lower') 'Vulkan scrub removes the same names as before plus the device-ordinal variables (ROCR_ names are not in the shared scrub list)'
    $vulkanBarEnv=& $module { param($P,$S,$I) Get-FastLlmEngineEnvironment -Plan $P -Sandbox $S -InheritedNames $I -VulkanBarMitigation -SystemRoot 'C:\Windows' } $vulkanEnvPlan $envSandbox $inherited
    $barName=& $module { $script:FastLlmVulkanBarMitigationVariable }
    Check (($vulkanBarEnv.set.Keys -join ',') -ceq "APPDATA,PROGRAMDATA,PATH,$barName" -and $vulkanBarEnv.set[$barName] -ceq '1') 'Vulkan environment gets the BAR variable only when the mitigation is requested'
    $hipEnv=& $module { param($P,$S,$I) Get-FastLlmEngineEnvironment -Plan $P -Sandbox $S -InheritedNames $I -SystemRoot 'C:\Windows' } $hipEnvPlan $envSandbox $inherited
    Check ($hipEnv.set['PATH'] -ceq 'C:\fl\components\engine\llama.cpp-hip-b11658\b11658;C:\fl\components\runtime\amd-rocm-gfx1100-10.0.0\10.0.0\bin;C:\Windows\System32;C:\Windows') 'HIP PATH is exactly <engine dir>;<runtime roots>;System32;SystemRoot (the engine dir is the application directory, which Windows searches first, then System32 and the Windows directory, and PATH after those: PATH orders only its own entries)'
    Check (($hipEnv.set.Keys -join ',') -ceq 'APPDATA,PROGRAMDATA,PATH') 'HIP environment sets only APPDATA, PROGRAMDATA and PATH'
    $hipBarEnv=& $module { param($P,$S,$I) Get-FastLlmEngineEnvironment -Plan $P -Sandbox $S -InheritedNames $I -VulkanBarMitigation -SystemRoot 'C:\Windows' } $hipEnvPlan $envSandbox $inherited
    Check (-not $hipBarEnv.set.Contains($barName) -and ($hipBarEnv.set.Keys -join ',') -ceq 'APPDATA,PROGRAMDATA,PATH') 'a HIP plan never receives the BAR variable, even when the caller asks for it'
    Check (@($hipEnv.set.Keys | Where-Object { $_ -like 'HIP_*' -or $_ -like 'ROC*' -or $_ -like 'HSA_*' }).Count -eq 0) 'no HIP_, ROC or HSA_ variable is ever set for a HIP child'
    foreach($hipOnly in @('HIPBLASLT_TENSILE_LIBPATH','AMD_LOG_LEVEL','GPU_MAX_HW_QUEUES')) {
        Check (($hipEnv.remove -contains $hipOnly) -and -not ($vulkanEnv.remove -contains $hipOnly)) "the HIP child scrubs $hipOnly and the Vulkan child is left as it was"
    }
    $emptyRootThrew=$false;$emptyRootEnv=$null
    try { $emptyRootEnv=& $module { param($P,$S) Get-FastLlmEngineEnvironment -Plan $P -Sandbox $S -SystemRoot '' } $hipEnvPlan $envSandbox } catch { $emptyRootThrew=$true }
    Check ($emptyRootThrew -or ($null -ne $emptyRootEnv -and $emptyRootEnv.set.Contains('PATH') -and $emptyRootEnv.set['PATH'] -like '*System32*')) 'an empty SystemRoot never leaves the inherited PATH in place: PATH is rebuilt from the Windows directory or the build fails closed'
    $runtimeTextForRoot=[IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.Runtime.ps1'))
    Check ($runtimeTextForRoot.Contains("[Environment]::GetFolderPath('Windows')") -and $runtimeTextForRoot.Contains('the engine search path cannot be built')) 'the empty-SystemRoot fallback asks Windows for its directory and otherwise throws'
    foreach($mustGo in @('HIP_VISIBLE_DEVICES','HSA_OVERRIDE_GFX_VERSION','ROCR_VISIBLE_DEVICES','ROCM_PATH','ROCBLAS_LAYER','GGML_VK_VISIBLE_DEVICES','LLAMA_ARG_PORT','HF_TOKEN','CUDA_VISIBLE_DEVICES','GPU_DEVICE_ORDINAL')) {
        Check ($hipEnv.remove -contains $mustGo) "the HIP child scrubs the inherited $mustGo"
    }
    Check (-not ($hipEnv.remove -contains 'PATH') -and -not ($hipEnv.remove -contains 'USERPROFILE')) 'the scrub does not remove variables outside its list'
    $twoRootsPlan=[pscustomobject]@{backend='hip';enginePath='C:\e\llama-server.exe';runtimeRoots=@('C:\r1\bin','C:\r2\bin')}
    $twoRootsEnv=& $module { param($P,$S) Get-FastLlmEngineEnvironment -Plan $P -Sandbox $S -SystemRoot 'D:\Win' } $twoRootsPlan $envSandbox
    Check ($twoRootsEnv.set['PATH'] -ceq 'C:\e;C:\r1\bin;C:\r2\bin;D:\Win\System32;D:\Win') 'several runtime roots keep their chain order between the engine dir and System32'
    # The builder is applied to a real ProcessStartInfo by the one wrapper that both the probe and the launch call.
    $startInfo=New-Object Diagnostics.ProcessStartInfo
    $startInfo.EnvironmentVariables['HIP_VISIBLE_DEVICES']='1';$startInfo.EnvironmentVariables['ROCR_VISIBLE_DEVICES']='1';$startInfo.EnvironmentVariables['GGML_VK_X']='1'
    & $module { param($I,$P,$S) Initialize-FastLlmEngineStartInfo -StartInfo $I -Plan $P -Sandbox $S -VulkanBarMitigation } $startInfo $hipEnvPlan $envSandbox
    Check (-not $startInfo.EnvironmentVariables.ContainsKey('HIP_VISIBLE_DEVICES') -and -not $startInfo.EnvironmentVariables.ContainsKey('ROCR_VISIBLE_DEVICES') -and -not $startInfo.EnvironmentVariables.ContainsKey('GGML_VK_X') -and -not $startInfo.EnvironmentVariables.ContainsKey($barName) -and $startInfo.EnvironmentVariables['APPDATA'] -ceq 'C:\sandbox\appdata') 'Initialize-FastLlmEngineStartInfo applies the scrub and the sets to a ProcessStartInfo (HIP, BAR requested and ignored)'
    $moduleText=[IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.psm1'))
    $runtimeText=[IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.Runtime.ps1'))
    Check ($moduleText.Contains('Initialize-FastLlmEngineStartInfo -StartInfo $startInfo -Plan $probePlan') -and $runtimeText.Contains('Initialize-FastLlmEngineStartInfo -StartInfo $info -Plan $Plan') -and -not $moduleText.Contains("EnvironmentVariables['PATH']") -and -not $moduleText.Contains("EnvironmentVariables['APPDATA']") -and -not $runtimeText.Contains('$info.EnvironmentVariables[''PATH'']')) 'the device probe and the server launch both build their environment through the one function (no second copy of the PATH or scrub code)'

    # The real b11658 device list on an RX 7900 XTX PC, parsed by the existing parser and matched by name and VRAM.
    $realList="Available devices:`r`n  ROCm0: AMD Radeon RX 7900 XTX (24560 MiB, 24411 MiB free)`r`n"
    $realDevices=@(ConvertFrom-LlamaDeviceList -Text $realList -Backend ROCm)
    Check ($realDevices.Count -eq 1 -and $realDevices[0].device -ceq 'ROCm0' -and $realDevices[0].name -ceq 'AMD Radeon RX 7900 XTX' -and $realDevices[0].vramMiB -eq 24560 -and $realDevices[0].freeVramMiB -eq 24411 -and $realDevices[0].isAmd -and -not $realDevices[0].isIntegrated) 'the real b11658 --list-devices line parses to ROCm0 with name, total and free VRAM'
    $realSelected=@(& $module { param($A,$D) Resolve-FastLlmHipSelectedAdapters -Adapters $A -Devices $D -ComponentId 'llama.cpp-hip-b11658' } @([pscustomobject]@{device='Vulkan0';name='AMD Radeon RX 7900 XTX';vramMiB=24560;freeVramMiB=23737}) $realDevices)
    Check ($realSelected.Count -eq 1 -and $realSelected[0].device -ceq 'ROCm0') 'the real device line matches the Vulkan-probed RX 7900 XTX'
    $twoCards=@(ConvertFrom-LlamaDeviceList -Text "Available devices:`n  ROCm0: AMD Radeon RX 7900 XTX (24560 MiB, 24411 MiB free)`n  ROCm1: AMD Radeon RX 7900 XTX (24560 MiB, 24411 MiB free)" -Backend ROCm)
    $twinCode=$null
    try { & $module { param($A,$D) Resolve-FastLlmHipSelectedAdapters -Adapters $A -Devices $D -ComponentId 'c' } @([pscustomobject]@{device='Vulkan0';name='AMD Radeon RX 7900 XTX';vramMiB=24560}) $twoCards | Out-Null } catch { $twinCode=$_.Exception.Data['FastLlmFailureCode'] }
    Check ($twoCards.Count -eq 2 -and $twinCode -ceq 'hip-device-ambiguous') 'two identical cards in a real-format list: hip-device-ambiguous'
    $mixed=@(ConvertFrom-LlamaDeviceList -Text "Available devices:`n  ROCm0: AMD Radeon(TM) Graphics (512 MiB, 400 MiB free)`n  ROCm1: AMD Radeon RX 7900 XTX (24560 MiB, 24411 MiB free)" -Backend ROCm)
    $mixedSelected=@(& $module { param($A,$D) Resolve-FastLlmHipSelectedAdapters -Adapters $A -Devices $D -ComponentId 'c' } @([pscustomobject]@{device='Vulkan0';name='AMD Radeon RX 7900 XTX';vramMiB=24560}) $mixed)
    Check ($mixed.Count -eq 2 -and $mixed[0].isIntegrated -and $mixedSelected[0].device -ceq 'ROCm1') 'an iGPU plus a dGPU in a real-format list: the dGPU is picked by name and VRAM'

    # Typed HIP launch failures (the supervisor and the probe both use this factory). The reason is never RuntimeCheckFailed: recovery would re-plan onto Vulkan.
    function Get-HipFailure($ExitCode,$NativeError) { & $module { param($E,$N) if ($null -ne $N) { New-FastLlmHipLaunchFailure -ComponentId 'llama.cpp-hip-b11658' -NativeErrorCode $N } else { New-FastLlmHipLaunchFailure -ComponentId 'llama.cpp-hip-b11658' -ExitCode $E } } $ExitCode $NativeError }
    $blockedExit=Get-HipFailure -1073740760 $null
    Check ($null -ne $blockedExit -and $blockedExit.Data['FastLlmFailureCode'] -ceq 'hip-dll-blocked' -and $blockedExit.Data['FastLlmReason'] -ceq 'HipDllFailed' -and $blockedExit.Message -like 'hip-dll-blocked:*' -and $blockedExit.Message -like "*llama.cpp-hip-b11658*" -and $blockedExit.Message -like '*server was stopped*' -and $blockedExit.Message -like '*Vulkan*') 'exit status 0xC0000428 (STATUS_INVALID_IMAGE_HASH) is hip-dll-blocked, naming the component, saying the server was stopped and pointing at the Vulkan setup'
    Check ($runtimeText.Contains("`$state.selectedDeviceIdentity = [ordered]@{ status = 'not-applicable'; reason = 'hip-lane' }") -and $runtimeText.Contains('if (-not $isHipPlan) { $state.selectedDeviceIdentity=ConvertFrom-FastLlmSelectedDeviceIdentity')) 'a HIP status records the selected-device identity as not applicable instead of a misleading Vulkan-name failure'
    foreach($nativeError in @(4551,1260,577)) {
        $blockedStart=Get-HipFailure $null $nativeError
        Check ($null -ne $blockedStart -and $blockedStart.Data['FastLlmFailureCode'] -ceq 'hip-dll-blocked') "Win32 error $nativeError from the process start is hip-dll-blocked"
    }
    $missingDll=Get-HipFailure -1073741515 $null
    Check ($null -ne $missingDll -and $missingDll.Data['FastLlmFailureCode'] -ceq 'hip-dll-missing' -and $missingDll.Data['FastLlmReason'] -ceq 'HipDllFailed' -and $missingDll.Message -like '*llama.cpp-hip-b11658*' -and $missingDll.Message -like '*Vulkan*') 'exit status 0xC0000135 (STATUS_DLL_NOT_FOUND) is hip-dll-missing, naming the component'
    foreach($ordinary in @(0,1,-1073741819,3,5)) { Check ($null -eq (Get-HipFailure $ordinary $null)) "exit status $ordinary is not a DLL failure" }
    Check ($null -eq (Get-HipFailure $null 5)) 'an unrelated Win32 error from the process start is not a DLL failure'
    Check ($runtimeText.Contains("New-FastLlmHipLaunchFailure -ComponentId `$hipComponentId -ExitCode ([int] `$hostProcess.Process.ExitCode)") -and $runtimeText.Contains("New-FastLlmHipLaunchFailure -ComponentId `$hipComponentId -NativeErrorCode") -and $moduleText.Contains('New-FastLlmHipLaunchFailure -ComponentId $ComponentId -ExitCode') -and $moduleText.Contains('New-FastLlmHipLaunchFailure -ComponentId $ComponentId -NativeErrorCode')) 'the supervisor (early exit and process start) and the device probe (exit and start) all use the typed factory'
    Check ($runtimeText -match "elseif \(\`$_\.Exception\.Data\['FastLlmReason'\] -ceq 'HipDllFailed'\)") 'the supervisor keeps the typed code and its non-recoverable reason out of the RuntimeCheckFailed branch'

    Check ($moduleText.Contains("if (`$_.Exception.Data['FastLlmFailureCode']) { throw }")) 'the HIP device probe rethrows its own typed failure instead of turning it into an empty device list'
    # The real probe against a stand-in engine (a batch file that exits with a chosen status; Windows only).
    if ($env:OS -eq 'Windows_NT') {
        function Invoke-StandInProbe([string]$Name,[int]$ExitCode,[switch]$Hip) {
            $probeDir=Join-Path $temp $Name
            New-Item -ItemType Directory -Path $probeDir -Force | Out-Null
            $standIn=Join-Path $probeDir 'llama-server.cmd'
            [IO.File]::WriteAllText($standIn,"@exit /b $ExitCode`r`n",(New-Object Text.ASCIIEncoding))
            $probeArguments=@{EnginePath=$standIn;Backend='ROCm';InstallRoot=$probeDir;TimeoutSeconds=20}
            if($Hip){$probeArguments.Hip=$true;$probeArguments.RuntimeRoots=@();$probeArguments.ComponentId='llama.cpp-hip-b11658'}
            $probeFailure=$null;$probeDevices=$null
            try { $probeDevices=@(Invoke-FastLlmDeviceProbe @probeArguments) } catch { $probeFailure=$_.Exception }
            return [pscustomobject]@{failure=$probeFailure;devices=$probeDevices}
        }
        $probeBlocked=Invoke-StandInProbe 'probe-blocked' -1073740760 -Hip
        Check ($null -ne $probeBlocked.failure -and $probeBlocked.failure.Data['FastLlmFailureCode'] -ceq 'hip-dll-blocked') 'the real HIP device probe turns an engine exit of 0xC0000428 into hip-dll-blocked, not an empty list'
        $probeMissing=Invoke-StandInProbe 'probe-missing' -1073741515 -Hip
        Check ($null -ne $probeMissing.failure -and $probeMissing.failure.Data['FastLlmFailureCode'] -ceq 'hip-dll-missing') 'the real HIP device probe turns an engine exit of 0xC0000135 into hip-dll-missing'
        $probeOrdinary=Invoke-StandInProbe 'probe-ordinary' 3 -Hip
        Check ($null -ne $probeOrdinary.failure -and $probeOrdinary.failure.Data['FastLlmFailureCode'] -ceq 'hip-backend-unavailable' -and $probeOrdinary.failure.Message -like '*status 3*') 'any other failing exit of the HIP probe is hip-backend-unavailable, not an empty device list'
        & $module { function script:Get-FastLlmSmartAppControlState { 'off' } }
        try {
            $noneDir=Join-Path $temp 'probe-none'
            New-Item -ItemType Directory -Path $noneDir -Force | Out-Null
            $noneEngine=Join-Path $noneDir 'llama-server.cmd'
            [IO.File]::WriteAllText($noneEngine,"@echo Available devices:`r`n@echo   (none)`r`n@exit /b 0`r`n",(New-Object Text.ASCIIEncoding))
            $noneFailure=$null;try { Invoke-FastLlmDeviceProbe -EnginePath $noneEngine -Backend ROCm -InstallRoot $noneDir -TimeoutSeconds 20 -Hip -RuntimeRoots @() -ComponentId 'llama.cpp-hip-b11658' | Out-Null } catch { $noneFailure=$_.Exception }
            Check ($null -ne $noneFailure -and $noneFailure.Data['FastLlmFailureCode'] -ceq 'hip-backend-unavailable') 'the real b11658 output of a HIP engine that cannot load its backend (exit 0, "(none)") is hip-backend-unavailable'
            $slowStarted=Get-Date
            $slowDir=Join-Path $temp 'probe-slow'
            New-Item -ItemType Directory -Path $slowDir -Force | Out-Null
            $slowEngine=Join-Path $slowDir 'llama-server.cmd'
            [IO.File]::WriteAllText($slowEngine,"@ping -n 8 127.0.0.1 >nul`r`n@exit /b 0`r`n",(New-Object Text.ASCIIEncoding))
            $slowFailure=$null;try { Invoke-FastLlmDeviceProbe -EnginePath $slowEngine -Backend ROCm -InstallRoot $slowDir -TimeoutSeconds 1 -Hip -RuntimeRoots @() -ComponentId 'llama.cpp-hip-b11658' | Out-Null } catch { $slowFailure=$_.Exception }
            Check ($null -ne $slowFailure -and $slowFailure.Data['FastLlmFailureCode'] -ceq 'hip-backend-unavailable' -and $slowFailure.Message -like '*in time*') 'a HIP probe that times out is hip-backend-unavailable'
            # The stand-in is a .cmd whose ping child outlives the probe's kill of cmd.exe (the real engine is one process) and holds the
            # folder; wait for that child so the cleanup can delete it. Bounded: the stand-in pings for about 7 s.
            $slowDeadline=[DateTime]::UtcNow.AddSeconds(20)
            while ([DateTime]::UtcNow -lt $slowDeadline -and @(Get-Process -Name ping -ErrorAction SilentlyContinue | Where-Object { try { $_.StartTime -gt $slowStarted } catch { $false } }).Count -gt 0) { Start-Sleep -Milliseconds 250 }
        } finally { & $module { Remove-Item -Path Function:script:Get-FastLlmSmartAppControlState -ErrorAction SilentlyContinue } }
        # A healthy HIP engine through the real probe: exactly the two lines b11658 prints, no child process left holding the folder.
        $healthyDir=Join-Path $temp 'probe-healthy'
        New-Item -ItemType Directory -Path $healthyDir -Force | Out-Null
        $healthyEngine=Join-Path $healthyDir 'llama-server.cmd'
        [IO.File]::WriteAllText($healthyEngine,"@echo Available devices:`r`n@echo   ROCm0: AMD Radeon RX 7900 XTX (24560 MiB, 24411 MiB free)`r`n@exit /b 0`r`n",(New-Object Text.ASCIIEncoding))
        $healthyDevices=@(Invoke-FastLlmDeviceProbe -EnginePath $healthyEngine -Backend ROCm -InstallRoot $healthyDir -TimeoutSeconds 20 -Hip -RuntimeRoots @() -ComponentId 'llama.cpp-hip-b11658')
        Check ($healthyDevices.Count -eq 1 -and $healthyDevices[0].device -ceq 'ROCm0' -and $healthyDevices[0].name -ceq 'AMD Radeon RX 7900 XTX' -and $healthyDevices[0].vramMiB -eq 24560 -and $healthyDevices[0].freeVramMiB -eq 24411) 'a healthy HIP engine through the real probe yields exactly one parsed ROCm0 device with its name and totals'
        $probeVulkan=Invoke-StandInProbe 'probe-vulkan' -1073740760
        Check ($null -eq $probeVulkan.failure -and $probeVulkan.devices.Count -eq 0) 'the non-HIP probe is unchanged: the same exit is an empty list, never a typed failure'
    }
    else { Write-Host 'SKIP: the stand-in engine probe needs a Windows child process' }

    # Call-site pin: the self-test failure is built through the helper at the call site, and the old inline text exists only inside the helper.
    Check ($runtimeText.Contains("-Code 'self-test-failed' -Message (Get-FastLlmSelfTestFailureText -Reasons @(`$selfTestResult.reasons) -Plan `$Plan)") -and ([regex]::Matches($runtimeText, [regex]::Escape('FastLLM tries the next cached setup.'))).Count -eq 1) 'the self-test failure at its call site uses the plan-aware helper (the old inline text is gone)'
    # The HIP backend-unavailable / SAC-evidenced block factory (the Smart App Control read is seamed).
    function Get-HipBackendFailure([string]$Sac,[string]$Cause,$ExitCode=$null) {
        & $module { param($S) function script:Get-FastLlmSmartAppControlState { $script:sacForTest }; $script:sacForTest=$S } $Sac
        try { & $module { param($C,$X) New-FastLlmHipBackendFailure -ComponentId 'llama.cpp-hip-b11658' -Cause $C -ExitCode $X } $Cause $ExitCode }
        finally { & $module { Remove-Item -Path Function:script:Get-FastLlmSmartAppControlState -ErrorAction SilentlyContinue } }
    }
    $sacOn=Get-HipBackendFailure 'enforced' 'no-device'
    Check ($sacOn.Data['FastLlmFailureCode'] -ceq 'hip-dll-blocked' -and $sacOn.Data['FastLlmReason'] -ceq 'HipDllFailed' -and $sacOn.Message -like '*Smart App Control*unsigned*' -and $sacOn.Message -like '*Vulkan*' -and $sacOn.Message -like '*llama.cpp-hip-b11658*') 'no ROCm device with Smart App Control enforcement on is hip-dll-blocked, saying the AMD runtime DLLs are unsigned'
    foreach($sac in @('off','unknown')) {
        $unavailable=Get-HipBackendFailure $sac 'no-device'
        Check ($unavailable.Data['FastLlmFailureCode'] -ceq 'hip-backend-unavailable' -and $unavailable.Data['FastLlmReason'] -cne 'RuntimeCheckFailed' -and $unavailable.Message -like '*Smart App Control or WDAC*' -and $unavailable.Message -like '*driver*' -and $unavailable.Message -like '*Reinstall*' -and $unavailable.Message -like '*Vulkan setup*' -and $unavailable.Message -like '*Nothing was started*') "no ROCm device with Smart App Control $sac is hip-backend-unavailable, naming the causes and the way out"
    }
    foreach($other in @(@{cause='timeout';text='*in time*'},@{cause='exit';text='*status 7*'},@{cause='start';text='*could not be started*'})) {
        $notBlocked=Get-HipBackendFailure 'enforced' $other.cause 7
        Check ($notBlocked.Data['FastLlmFailureCode'] -ceq 'hip-backend-unavailable' -and $notBlocked.Message -like $other.text) "a probe $($other.cause) stays hip-backend-unavailable even with Smart App Control enforced (no evidence of a block)"
    }
    Check ($runtimeText.Contains("HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy") -and $runtimeText.Contains('VerifiedAndReputablePolicyState') -and $runtimeText.Contains('-eq 1) { return ''enforced'' }')) 'the Smart App Control read is the read-only CI policy value, 1 meaning enforcement'
    Check (($moduleText.Contains('-Cause timeout')) -and $moduleText.Contains('-Cause no-device') -and $moduleText.Contains('if ($Hip -and @($probedDevices | Where-Object') -and $moduleText.Contains('-Cause exit') -and $moduleText.Contains('-Cause start')) 'the HIP probe maps a timeout, an empty device list, a failing exit and a failed start to the typed backend failure'
    # Plan-keyed no-recovery and the self-test text.
    $planKey={ param($P) & $module { param($X) Test-FastLlmPlanOnEngineComponent -Plan $X } $P }
    Check ((& $planKey ([pscustomobject]@{engineComponentId='x'})) -and (& $planKey ([pscustomobject]@{backend='hip'})) -and -not (& $planKey ([pscustomobject]@{backend='Vulkan'})) -and -not (& $planKey ([pscustomobject]@{backend='Vulkan';engineComponentId=$null}))) 'a plan runs on an engine component when it names one or its backend is hip'
    $textFor={ param($P) & $module { param($X) Get-FastLlmSelfTestFailureText -Reasons @('slow','bad') -Plan $X } $P }
    Check ((& $textFor ([pscustomobject]@{backend='Vulkan'})) -ceq 'Self-test failed (slow, bad). The server was stopped; FastLLM tries the next cached setup.') 'the self-test failure text for a Vulkan plan is unchanged (recovery can run)'
    Check ((& $textFor ([pscustomobject]@{backend='hip';engineComponentId='x'})) -ceq 'Self-test failed (slow, bad). The server was stopped; FastLLM does not switch to another setup on its own.') 'the self-test failure text for an engine component plan does not promise a recovery that cannot run'

    # Supervised start of a HIP plan against a stand-in engine that exits at once (Windows only: a real child process with a chosen exit status).
    if ($env:OS -eq 'Windows_NT') {
        & $module { Initialize-FastLlmProcessHost }
        function Invoke-HipEarlyExit([string]$Name,[int]$ExitCode,[string]$Binding='off') {
            $hipRun=Join-Path $temp $Name
            New-Item -ItemType Directory -Path $hipRun -Force | Out-Null
            $hipListener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$hipListener.Start();$hipPort=$hipListener.LocalEndpoint.Port;$hipListener.Stop()
            $hipPlan=[pscustomobject]@{enginePath=$env:ComSpec;serverArguments=@('/c','exit',"$ExitCode");endpoint="http://127.0.0.1:$hipPort/v1";backend='hip';engineComponentId='llama.cpp-hip-b11658';runtimeRoots=@()
                selectedAdapters=@([pscustomobject]@{device='ROCm0';name='AMD Radeon RX 7900 XTX';vramMiB=24560});hardwareFingerprint='synthetic';engineVersion='b11658';model=[pscustomobject]@{id='test-model';contextSize=1024;sha256=('0'*64)}}
            $hipLock=Enter-FastLlmOperation $hipRun
            $hipFailure=$null
            try {
                $hipOptions=@{Plan=$hipPlan;InstallRoot=$hipRun;LoadTimeoutSeconds=30}
                if($Binding -cne 'off'){$hipOptions.DeviceBinding=$Binding}
                try { & $module { param($O) Invoke-FastLlmSupervisedServer @O } $hipOptions | Out-Null } catch { $hipFailure=$_.Exception }
            } finally { $hipLock.Dispose() }
            return [pscustomobject]@{failure=$hipFailure;state=(Get-FastLlmStatus $hipRun)}
        }
        $blockedRun=Invoke-HipEarlyExit 'hip-blocked' -1073740760
        Check ($null -ne $blockedRun.failure -and $blockedRun.failure.Data['FastLlmFailureCode'] -ceq 'hip-dll-blocked' -and $blockedRun.failure.Data['FastLlmReason'] -ceq 'HipDllFailed' -and $blockedRun.state.phase -ceq 'failed' -and $blockedRun.state.failureCode -ceq 'hip-dll-blocked') 'a HIP server that exits with 0xC0000428 before readiness fails the start hip-dll-blocked (status failed, code recorded, never RuntimeCheckFailed)'
        $missingRun=Invoke-HipEarlyExit 'hip-missing' -1073741515
        Check ($null -ne $missingRun.failure -and $missingRun.failure.Data['FastLlmFailureCode'] -ceq 'hip-dll-missing' -and $missingRun.state.failureCode -ceq 'hip-dll-missing') 'a HIP server that exits with 0xC0000135 before readiness fails the start hip-dll-missing'
        $genericRun=Invoke-HipEarlyExit 'hip-generic' 3
        Check ($null -ne $genericRun.failure -and $genericRun.failure.Message -like '*exited before readiness*' -and $null -eq $genericRun.failure.Data['FastLlmFailureCode'] -and $genericRun.state.failureCode -ceq 'startup-or-runtime-check-failed') 'any other early exit of a HIP server keeps the generic failure'
        Check ($genericRun.state.engineComponentId -ceq 'llama.cpp-hip-b11658' -and $genericRun.state.engineExecutable -ceq $env:ComSpec -and $genericRun.state.vulkanMemoryPolicy.effective -ceq 'not-applicable' -and $genericRun.state.barGuidance.shown -eq $false -and $genericRun.state.processIdentity.pid -gt 0 -and $genericRun.state.selectedDeviceIdentity.status -ceq 'not-applicable' -and $genericRun.state.selectedDeviceIdentity.reason -ceq 'hip-lane') 'status.json records the HIP component and executable, a not-applicable Vulkan memory policy and no BAR guidance'
        $recordRun=Invoke-HipEarlyExit 'hip-record' 3 'record'
        Check ($recordRun.state.deviceBinding.status -ceq 'not-applicable' -and $recordRun.state.identityRecord -ceq 'not-applicable' -and $recordRun.state.failureCode -ceq 'startup-or-runtime-check-failed') '-DeviceBinding record on a HIP plan records not-applicable and captures no Vulkan identity'
        $enforceRun=Invoke-HipEarlyExit 'hip-enforce' 3 'enforce'
        Check ($null -ne $enforceRun.failure -and $enforceRun.failure.Data['FastLlmFailureCode'] -ceq 'device-binding-unsupported-backend' -and $enforceRun.failure.Data['FastLlmReason'] -ceq 'DeviceBindingFailed' -and $enforceRun.state.failureCode -ceq 'device-binding-unsupported-backend' -and $null -eq $enforceRun.state.processIdentity) '-DeviceBinding enforce on a HIP plan fails device-binding-unsupported-backend before any server process is spawned (positive control: the generic run recorded a pid)'
    }
    else { Write-Host 'SKIP: supervised HIP early-exit starts need a Windows child process' }
    $suitePassed=$true
} finally {
    if($lock){$lock.Dispose()}
    if($suitePassed){
        if(Test-Path $temp){Remove-Item -LiteralPath $temp -Recurse -Force}
    }else{
        Write-Warning "Runtime test scratch retained for failure diagnostics: $temp"
    }
}
Write-Host "$count runtime checks passed. Mock services are not Windows/AMD qualification."
