# Private Vulkan experiment only. Never emits the normal benchmark result kind.
function Assert-FastLlmVulkanVidmemBenchmarkArgument {
    param([object[]]$Arguments,[string]$Name,[string]$Value)
    $hits=@(for($i=0;$i -lt $Arguments.Count;$i++){if([string]$Arguments[$i] -ceq $Name){$i}})
    return $hits.Count -eq 1 -and $hits[0]+1 -lt $Arguments.Count -and [string]$Arguments[$hits[0]+1] -ceq $Value
}

function Get-FastLlmVulkanVidmemBenchmarkBinding {
    param($State)
    $bound=[ordered]@{kind=$State.kind;runId=$State.runId;processIdentity=$State.processIdentity;
        modelId=$State.modelId;modelSha256=$State.modelSha256;engineVersion=$State.engineVersion;
        engineSha256=$State.engineSha256;catalogSha256=$State.catalogSha256;trialSourceSha256=$State.trialSourceSha256;endpoint=$State.endpoint;
        tuple=$State.tuple;variant=$State.variant;arm=$State.arm;environmentOverride=$State.environmentOverride;startInfoEnvironmentVerified=$State.startInfoEnvironmentVerified;
        observedEnvironment=$State.observedEnvironment;preStartIdle=$State.preStartIdle;hostModelBufferPolicy=$State.hostModelBufferPolicy;
        recipe=$State.recipe;selectedDevice=$State.selectedDevice;allowHostModelBuffer=$State.allowHostModelBuffer;
        placementClassification=$State.placementClassification;allWeightsOnGpuVerified=$State.allWeightsOnGpuVerified;
        allOperationsOnGpuVerified=$State.allOperationsOnGpuVerified;cpuInputEvidence=$State.cpuInputEvidence;
        placement=$State.placement;placementCounters=$State.placementCounters;
        placementEvidence=$State.placementEvidence;startupDiagnostics=$State.startupDiagnostics;canary=$State.canary}
    $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $bound -Depth 16 -Compress))
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}
    finally{$sha.Dispose()}
}

function Assert-FastLlmVulkanVidmemRecordedEnvironment {
    param($State)
    Assert-FastLlmVulkanVidmemVariant ([string]$State.variant)
    Assert-FastLlmVulkanVidmemArm -Arm ([string]$State.arm) -Variant ([string]$State.variant)
    if($State.startInfoEnvironmentVerified -ne $true){throw 'Vidmem start-info environment was not verified before launch.'}
    if($State.allowHostModelBuffer -ne $true -or $State.recipe.allowHostModelBuffer -ne $true -or
       [string]$State.hostModelBufferPolicy -cne 'implicit-lane-policy-normal-recipe-reports-CPU_Mapped'){
        throw 'Vidmem lane must record the implicit host-model-buffer policy.'
    }
    $overrideProps=@($State.environmentOverride.PSObject.Properties)
    $ggmlProps=@($State.observedEnvironment.ggmlEnvironment.PSObject.Properties)
    if($State.variant -ceq 'default'){
        if($overrideProps.Count -ne 0 -or $ggmlProps.Count -ne 0){throw 'Default vidmem variant must record an empty environmentOverride and no observed GGML_* variable.'}
    }elseif($overrideProps.Count -ne 1 -or $overrideProps[0].Name -cne 'GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM' -or
            [string]$overrideProps[0].Value -cne '1' -or $ggmlProps.Count -ne 1 -or
            $ggmlProps[0].Name -cne 'GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM' -or [string]$ggmlProps[0].Value -cne '1'){
        throw 'Override vidmem variant must record and observe exactly GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM=1.'
    }
    if(@($State.observedEnvironment.variables).Count -lt 1 -or @($State.observedEnvironment.excludedFromDigest).Count -lt 1){
        throw 'Observed per-variable environment entries or the exclusion list are missing.'
    }
    if([string]$State.observedEnvironment.launchEnvironmentSha256 -cnotmatch '^[0-9a-f]{64}$' -or
       [string]$State.observedEnvironment.launchEnvironmentWithOverrideSha256 -cnotmatch '^[0-9a-f]{64}$' -or
       [string]$State.observedEnvironment.launchArgumentsSha256 -cnotmatch '^[0-9a-f]{64}$'){
        throw 'Observed launch-environment digests are missing or malformed.'
    }
    if(($State.variant -ceq 'default') -ne ([string]$State.observedEnvironment.launchEnvironmentSha256 -ceq [string]$State.observedEnvironment.launchEnvironmentWithOverrideSha256)){
        throw 'Observed environment digests are inconsistent with the variant.'
    }
    if($State.preStartIdle.verified -ne $true -or [int]$State.preStartIdle.inferenceProcessCount -ne 0 -or
       $State.preStartIdle.port8080Free -ne $true -or $State.preStartIdle.port18090Free -ne $true -or
       [string]$State.preStartIdle.stage -cne 'immediately-before-start'){
        throw 'preStartIdle evidence is missing or not clean.'
    }
}

function Compare-FastLlmVulkanVidmemArmReports {
    param([object[]]$Reports)
    $problems=New-Object Collections.Generic.List[string]
    $order=@('A1','B1','B2','A2')
    if($Reports.Count -ne 4){$problems.Add('Exactly four arm reports are required.')}
    else{
        for($i=0;$i -lt 4;$i++){
            $r=$Reports[$i]
            if([string]$r.arm -cne $order[$i]){$problems.Add("Report $i must be arm $($order[$i]).")}
            if([string]$r.status -cne 'complete'){$problems.Add("Arm $($r.arm) is not complete.")}
            $expectedVariant=if($order[$i].StartsWith('A')){'disable-host-visible-vidmem'}else{'default'}
            if([string]$r.variant -cne $expectedVariant){$problems.Add("Arm $($r.arm) variant differs from its label.")}
        }
        if(@($Reports|ForEach-Object {[string]$_.runId}|Select-Object -Unique).Count -ne 4){$problems.Add('Run IDs are not distinct.')}
        foreach($field in @('launchEnvironmentSha256','launchArgumentsSha256')){
            if(@($Reports|ForEach-Object {[string]$_.observedEnvironment.$field}|Select-Object -Unique).Count -ne 1){
                $detail=''
                if($field -ceq 'launchEnvironmentSha256'){
                    $names=@(foreach($r in @($Reports[1..3])){Get-FastLlmVulkanVidmemEnvironmentDifferences -Left $Reports[0].observedEnvironment -Right $r.observedEnvironment})|Select-Object -Unique
                    $detail=' (differing variable names: '+(@($names) -join ', ')+')'
                }
                $problems.Add("$field is not identical across arms.$detail")}
        }
        if(@($Reports|ForEach-Object {[string]$_.tuple}|Select-Object -Unique).Count -ne 1 -or [string]::IsNullOrEmpty([string]$Reports[0].tuple)){$problems.Add('Reports mix tuples or carry no tuple.')}
        foreach($field in @('modelSha256','engineSha256','catalogSha256')){
            if(@($Reports|ForEach-Object {[string]$_.$field}|Select-Object -Unique).Count -ne 1){$problems.Add("$field differs across arms.")}
        }
        $a=@($Reports[0],$Reports[3]|ForEach-Object {[string]$_.observedEnvironment.launchEnvironmentWithOverrideSha256}|Select-Object -Unique)
        $b=@($Reports[1],$Reports[2]|ForEach-Object {[string]$_.observedEnvironment.launchEnvironmentWithOverrideSha256}|Select-Object -Unique)
        if($a.Count -ne 1 -or $b.Count -ne 1 -or $a[0] -ceq $b[0]){$problems.Add('Arms differ by anything other than exactly the one override.')}
        foreach($r in @($Reports[0],$Reports[3])){
            $props=@($r.environmentOverride.PSObject.Properties)
            if($props.Count -ne 1 -or $props[0].Name -cne 'GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM' -or [string]$props[0].Value -cne '1'){$problems.Add("Arm $($r.arm) override record is wrong.")}
        }
        foreach($r in @($Reports[1],$Reports[2])){
            if(@($r.environmentOverride.PSObject.Properties).Count -ne 0){$problems.Add("Arm $($r.arm) must record an empty override.")}
        }
    }
    return [pscustomobject]@{ok=($problems.Count -eq 0);problems=@($problems)}
}

function Get-FastLlmVulkanVidmemEnvironmentDifferences {
    # Names only, never values. Excluded and override entries are not compared.
    param($Left,$Right)
    $map={param($observed) $h=@{};$list=if($observed.PSObject.Properties['variables']){@($observed.variables)}else{@()};foreach($e in $list){
        if($e.PSObject.Properties['excluded'] -or $e.PSObject.Properties['overrideVariable']){continue}
        $h[[string]$e.name]=[string]$e.valueSha256};$h}
    $l=& $map $Left;$r=& $map $Right
    return @(@($l.Keys)+@($r.Keys)|Select-Object -Unique|Sort-Object|Where-Object {-not $l.ContainsKey($_) -or -not $r.ContainsKey($_) -or $l[$_] -cne $r[$_]})
}

function Assert-FastLlmVulkanVidmemReferenceReport {
    # Pre-measurement: this arm's launch environment must match an earlier arm's report except for the override.
    param($State,$Reference)
    $o=$State.observedEnvironment
    if([string]$Reference.observedEnvironment.launchEnvironmentSha256 -cne [string]$o.launchEnvironmentSha256){
        $names=@(Get-FastLlmVulkanVidmemEnvironmentDifferences -Left $Reference.observedEnvironment -Right $o)
        throw ('Launch environment digest differs from the reference arm beyond the single override; differing variable names: '+$(if($names.Count){$names -join ', '}else{'(none listed; per-variable entries absent)'}))
    }
    if([string]$Reference.observedEnvironment.launchArgumentsSha256 -cne [string]$o.launchArgumentsSha256 -or
       [string]$Reference.tuple -cne [string]$State.tuple -or
       [string]$Reference.modelSha256 -cne [string]$State.modelSha256 -or
       [string]$Reference.engineSha256 -cne [string]$State.engineSha256 -or
       [string]$Reference.catalogSha256 -cne [string]$State.catalogSha256){
        throw 'Launch arguments, model, engine or catalog differ from the reference arm.'
    }
    $sameVariant=[string]$Reference.variant -ceq [string]$State.variant
    $sameFull=[string]$Reference.observedEnvironment.launchEnvironmentWithOverrideSha256 -ceq [string]$o.launchEnvironmentWithOverrideSha256
    if($sameVariant -ne $sameFull){throw 'Full launch-environment digest relationship to the reference arm contradicts the variants.'}
}

function Assert-FastLlmVulkanVidmemPinnedInputs {
    param([string]$ProducerPath,[string]$ParserPath,[string]$CatalogPath)
    $pins=Get-FastLlmVulkanVidmemPins
    $hash={param($path)
        $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Pinned input is unsafe.'}
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
    $producer=& $hash $ProducerPath;$parser=& $hash $ParserPath;$catalog=& $hash $CatalogPath
    if($producer -cne $pins.producerSha256){throw 'FastLlm.Benchmark.ps1 is not the reviewed producer c8b64fe0; refusing.'}
    if($parser -cne $pins.parserSha256){throw 'Response parser file differs from the pinned reviewed hash; refusing.'}
    if($catalog -cne $pins.catalogSha256){throw 'Catalog differs from the pinned reviewed hash; refusing.'}
    return [ordered]@{producerSha256=$producer;parserSha256=$parser;catalogSha256=$catalog}
}

function New-FastLlmVulkanVidmemBenchmarkMarker {
    # Exactly one benchmark per run ID: CreateNew fails if one was ever started.
    param([string]$RunRoot,[string]$RunId)
    if($RunId -cnotmatch '^[0-9a-f]{32}$'){throw 'Invalid run ID for benchmark marker.'}
    $root=Get-FastLlmStateRoot -InstallRoot $RunRoot
    $path=Join-FastLlmContainedPath -Root $root -Child ('benchmark-'+$RunId+'.started')
    try{$stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)}
    catch{throw 'A benchmark was already started for this run ID; exactly one benchmark is allowed per run.'}
    try{$bytes=[Text.Encoding]::UTF8.GetBytes((Get-Date).ToUniversalTime().ToString('o'));$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
}

function Assert-FastLlmVulkanVidmemBenchmarkState {
    param($State,[string]$ExpectedBinding)
    $spec=Get-FastLlmVulkanVidmemTupleSpec -Tuple ([string]$State.tuple)
    if($State.active -isnot [bool] -or -not $State.active -or [int]$State.schemaVersion -ne 1 -or
       $State.kind -cne 'fastllm-vulkan-vidmem-b10698-private-trial' -or $State.phase -cne 'vulkan-vidmem-ready' -or
       $State.endpoint -cne 'http://127.0.0.1:18090/v1' -or $State.experimental -isnot [bool] -or -not $State.experimental -or
       $State.performanceQualified -ne $false -or $State.physicalResidencyVerified -ne $false -or
       $State.dynamicClosureVerified -ne $false -or $State.semanticCorrectnessQualified -ne $false -or
       $State.allWeightsOnGpuVerified -ne $false -or $State.allOperationsOnGpuVerified -ne $false -or
       $State.cpuInputEvidence -cne 'not-attested' -or $State.allowHostModelBuffer -isnot [bool] -or

       $State.recipe.allowHostModelBuffer -ne $State.allowHostModelBuffer -or
       $State.runId -cnotmatch '^[0-9a-f]{32}$' -or [int]$State.processIdentity.pid -le 0 -or
       [long]$State.processIdentity.startUtcTicks -le 0 -or
       $State.modelId -cne $spec.modelId -or $State.modelSha256 -cne $spec.modelSha256 -or
       [string]$State.selectedDevice.name -cne $spec.adapterName -or
       $State.engineVersion -cne 'b10698' -or $State.engineSha256 -cne (Get-FastLlmVulkanVidmemPins).engineSha256 -or
       $State.catalogSha256 -cne (Get-FastLlmVulkanVidmemPins).catalogSha256 -or $State.trialSourceSha256 -cnotmatch '^[0-9a-f]{64}$' -or
       $State.recipe.backend -cne 'Vulkan' -or $State.recipe.device -cne 'Vulkan0' -or
       $State.selectedDevice.device -cne 'Vulkan0' -or [string]::IsNullOrWhiteSpace([string]$State.selectedDevice.name) -or
       [int]$State.recipe.contextSize -ne $spec.contextSize -or [int]$State.recipe.slots -ne 1 -or
       $State.recipe.gpuLayers -cne 'all' -or $State.recipe.fitMode -cne 'on' -or
       [int]$State.recipe.fitTargetMiB -ne $spec.fitTargetMiB -or $State.recipe.splitMode -cne 'none' -or
       $State.recipe.speculation -cne 'none' -or $State.recipe.flashAttention -cne 'auto' -or
       $State.recipe.cacheTypeK -cne 'f16' -or $State.recipe.cacheTypeV -cne 'f16'){
        throw 'Exact private Vulkan vidmem trial is not Ready or its fixed recipe/identity differs.'
    }
    Assert-FastLlmVulkanVidmemRecordedEnvironment -State $State
    $expected=@(New-FastLlmVulkanVidmemArguments -ModelPath '<verified-model>' -Tuple $State.tuple)
    $actual=@($State.recipe.requestedArguments)
    if($actual.Count -ne $expected.Count){throw 'Vulkan vidmem launch argument count differs from the fixed recipe.'}
    for($i=0;$i -lt $expected.Count;$i++){
        if([string]$actual[$i] -cne [string]$expected[$i]){throw 'Vulkan vidmem launch arguments differ from the fixed recipe.'}
    }
    if([int]$State.placement.reportedLayers -ne 66 -or [int]$State.placement.totalLayers -ne 66 -or
       $State.placement.reportedAllLayers -ne $true -or @($State.placement.devices).Count -ne 1 -or
       $State.placement.devices[0] -cne 'Vulkan0' -or @($State.placement.modelBufferMiB).Count -ne 1 -or
       $State.placement.modelBufferMiB[0].device -cne 'Vulkan0' -or
       [double]$State.placement.modelBufferMiB[0].sizeMiB -le 0 -or
       [double]::IsNaN([double]$State.placement.modelBufferMiB[0].sizeMiB) -or
       [double]::IsInfinity([double]$State.placement.modelBufferMiB[0].sizeMiB) -or
       $State.placement.physicalResidencyVerified -ne $false -or
       $State.placementEvidence.status -cne 'captured' -or
       [int]$State.placementEvidence.reportedGpuLayers -ne 66 -or
       [int]$State.placementEvidence.reportedTotalLayers -ne 66 -or
       $State.placementEvidence.gpuModelBuffer.device -cne 'Vulkan0' -or
       [double]$State.placementEvidence.gpuModelBuffer.sizeMiB -le 0 -or
       [double]::IsNaN([double]$State.placementEvidence.gpuModelBuffer.sizeMiB) -or
       [double]::IsInfinity([double]$State.placementEvidence.gpuModelBuffer.sizeMiB) -or
       [double]$State.placementEvidence.gpuModelBuffer.sizeMiB -ne [double]$State.placement.modelBufferMiB[0].sizeMiB -or
       $State.placementEvidence.physicalResidencyVerified -ne $false -or
       $State.placementEvidence.allWeightsOnGpuVerified -ne $false -or
       $State.placementEvidence.allOperationsOnGpuVerified -ne $false -or
       [int]$State.placementCounters.offloadLike -ne 1 -or
       [int]$State.placementCounters.bufferLike -ne $(if($null -eq $State.placementEvidence.hostModelBuffer){1}else{2}) -or
       [int]$State.placementCounters.captured -ne $(if($null -eq $State.placementEvidence.hostModelBuffer){2}else{3}) -or
       [int]$State.placementCounters.dropped -ne 0 -or
       $State.startupDiagnostics.physicalResidencyVerified -ne $false -or
       $State.canary.modelIdentity -ne $true -or $State.canary.repeatableToken -ne $true -or
       $State.canary.synchronousChat -ne $true -or $State.canary.streaming -ne $true -or
       [int]$State.canary.effectiveContext -ne $spec.contextSize -or
       $State.canary.semanticCorrectnessQualified -ne $false){
        throw 'Vulkan vidmem placement or API evidence is incomplete or inconsistent.'
    }
    $hostBuffer=$State.placementEvidence.hostModelBuffer
    if($null -eq $hostBuffer){
        if($State.placementClassification -cne 'all-reported-layers-no-host-model-buffer' -or
           $State.placementEvidence.classification -cne $State.placementClassification){
            throw 'Vulkan vidmem host-buffer classification differs from captured evidence.'
        }
    }else{
        if(-not $State.allowHostModelBuffer -or $hostBuffer.device -cne 'CPU_Mapped' -or
           [double]$hostBuffer.sizeMiB -le 0 -or [double]::IsNaN([double]$hostBuffer.sizeMiB) -or
           [double]::IsInfinity([double]$hostBuffer.sizeMiB) -or
           [double]$hostBuffer.sizeMiB -gt 1024.0 -or
           $State.placementClassification -cne 'all-reported-layers-with-host-model-buffer' -or
           $State.placementEvidence.classification -cne $State.placementClassification){
            throw 'Vulkan vidmem host-buffer classification or opt-in is invalid.'
        }
    }
    $binding=Get-FastLlmVulkanVidmemBenchmarkBinding $State
    if($ExpectedBinding -and $binding -cne $ExpectedBinding){
        throw 'Vulkan vidmem run, process, recipe or placement changed during measurement.'
    }
    return $binding
}

function Assert-FastLlmVulkanVidmemBenchmarkProcess {
    param($State,[switch]$HashExecutable)
    $owners=@(Get-FastLlmVulkanVidmemListenerOwners -Port 18090)
    if($owners.Count -ne 1 -or [int]$owners[0] -ne [int]$State.processIdentity.pid){throw 'Vulkan vidmem listener owner differs from the supervised child.'}
    $process=$null
    try{
        $process=[Diagnostics.Process]::GetProcessById([int]$State.processIdentity.pid)
        if($process.HasExited -or $process.ProcessName -cne 'llama-server' -or
           [long]$process.StartTime.ToUniversalTime().Ticks -ne [long]$State.processIdentity.startUtcTicks){throw 'Vulkan vidmem child process identity changed.'}
        if($HashExecutable){
            if((Get-FileHash -LiteralPath $process.MainModule.FileName -Algorithm SHA256).Hash.ToLowerInvariant() -cne $State.engineSha256){
                throw 'Vulkan vidmem executable file hash differs from the recorded engine.'
            }
        }
    }finally{if($process){$process.Dispose()}}
}

function Invoke-FastLlmVulkanVidmemBenchmarkCore {
    param([string]$OutputPath,[scriptblock]$ReadState,[scriptblock]$Request,[scriptblock]$CheckProcess,
          [scriptblock]$CheckExecutable,[Parameter(Mandatory=$true)][string]$Arm,[string]$ReferenceReport,
          [string]$ProducerPath,[string]$ParserPath,[string]$CatalogPath,[int]$DeadlineSeconds=3600)
    if($DeadlineSeconds -lt 1 -or $DeadlineSeconds -gt 3600){throw 'Vulkan vidmem benchmark deadline outside bound.'}
    if($Arm -cnotin @('A1','B1','B2','A2')){throw 'Vulkan vidmem arm must be exactly A1, B1, B2 or A2.'}
    $promptLengths=@(512,4096);$generationTokens=128;$repetitions=5
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $startedAt=(Get-Date).ToUniversalTime().ToString('o')
    $sourcePath=Join-Path $PSScriptRoot 'FastLlm.VulkanVidmemBenchmark.ps1'
    $helperPath=if($ProducerPath){$ProducerPath}else{Join-Path $PSScriptRoot 'FastLlm.Benchmark.ps1'}
    $responseParserPath=if($ParserPath){$ParserPath}else{Join-Path $PSScriptRoot 'FastLlm.OffloadBenchmark.ps1'}
    $catalogFilePath=if($CatalogPath){$CatalogPath}else{Join-Path (Split-Path $PSScriptRoot -Parent) 'config/catalog.json'}
    $trialPath=Join-Path $PSScriptRoot 'FastLlm.VulkanVidmemTrial.ps1'
    if(Test-Path -LiteralPath $OutputPath){throw 'Vulkan vidmem benchmark output already exists.'}
    $pinnedInputs=Assert-FastLlmVulkanVidmemPinnedInputs -ProducerPath $helperPath -ParserPath $responseParserPath -CatalogPath $catalogFilePath
    $sourceHash=(Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $helperHash=$pinnedInputs.producerSha256
    $responseParserHash=$pinnedInputs.parserSha256
    $trialHash=(Get-FileHash -LiteralPath $trialPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $first=$null;$binding=$null;$referenceCheck='none'
    $samples=@();$warmups=@();$evaluated=@{};$promptOrderByRound=@();$artifacts=@();$summary=@()
    $status='aborted';$abortReason='benchmark did not start'
    $buildReport={
        $f=$first
        $pick={param($name) if($null -ne $f){$f.$name}else{$null}}
        $hostRows=if($null -ne $f -and $null -ne $f.placementEvidence.hostModelBuffer){1}else{0}
        $hostMiB=if($null -ne $f -and $null -ne $f.placementEvidence.hostModelBuffer){[double]$f.placementEvidence.hostModelBuffer.sizeMiB}else{$null}
        [ordered]@{schemaVersion=2;resultKind='native-windows-api-vulkan-vidmem-lab-experiment';status=$status;abortReason=$(if($status -ceq 'complete'){$null}else{$abortReason});
        recordedAt=(Get-Date).ToUniversalTime().ToString('o');benchmarkStartedAtUtc=$startedAt;
        arm=$Arm;tuple=(& $pick 'tuple');variant=(& $pick 'variant');environmentOverride=(& $pick 'environmentOverride');startInfoEnvironmentVerified=(& $pick 'startInfoEnvironmentVerified');
        observedEnvironment=(& $pick 'observedEnvironment');preLockIdle=(& $pick 'preLockIdle');preStartIdle=(& $pick 'preStartIdle');
        hostModelBufferPolicy=(& $pick 'hostModelBufferPolicy');referenceReportCheck=$referenceCheck;
        timing=[ordered]@{launchedAtUtc=(& $pick 'launchedAtUtc');healthyAtUtc=(& $pick 'healthyAtUtc');modelLoadSeconds=(& $pick 'modelLoadSeconds');readyAtUtc=(& $pick 'readyAtUtc')};
        runId=(& $pick 'runId');processIdentity=(& $pick 'processIdentity');modelId=(& $pick 'modelId');modelSha256=(& $pick 'modelSha256');
        engineVersion=(& $pick 'engineVersion');engineSha256=(& $pick 'engineSha256');catalogSha256=(& $pick 'catalogSha256');
        trialSourceSha256=(& $pick 'trialSourceSha256');
        endpoint=(& $pick 'endpoint');recipe=(& $pick 'recipe');selectedDevice=(& $pick 'selectedDevice');
        allowHostModelBuffer=(& $pick 'allowHostModelBuffer');placementClassification=(& $pick 'placementClassification');
        reportedHostModelBufferRows=$hostRows;reportedHostModelBufferMiB=$hostMiB;
        allWeightsOnGpuVerified=$false;allOperationsOnGpuVerified=$false;cpuInputEvidence='not-attested';
        placement=(& $pick 'placement');placementCounters=(& $pick 'placementCounters');
        placementEvidence=(& $pick 'placementEvidence');startupDiagnostics=(& $pick 'startupDiagnostics');canary=(& $pick 'canary');
        evidenceBindingSha256=$binding;
        sourceProvenance=@{vulkanVidmemBenchmarkSha256=$sourceHash;vulkanVidmemTrialSha256=$trialHash;canonicalHelperSha256=$helperHash;
            strictResponseParserSha256=$responseParserHash;catalogFileSha256=$pinnedInputs.catalogSha256;pinsVerified=$true;
            scope='pinned producer/parser/catalog/engine hashes verified at measurement start; trial launch-source SHA matches on-disk source at start/end; loaded-code identity is not attested'};
        methodology=@{corpus='fastllm-repeated-prose-v1';sampling='greedy-seed42';prefixCache=$false;warmupPerPrompt=1;
            generationTokens=$generationTokens;repetitions=$repetitions;concurrency=1;randomizedPromptOrder=$false;
            promptOrderByRound=$promptOrderByRound;
            completionRequestTimeoutMs=180000;overallDeadlineSeconds=$DeadlineSeconds;promptArtifacts=$artifacts;
            samplePromptIdentity='exact token-array digest; reported prompt_n must be N or N+1 uniformly across warmup and samples'};
        warmups=$warmups;samples=$samples;summary=$summary;
        qualification=@{approved=$false;qualityEvaluation=$false;physicalResidency=$false;peakVramMeasured=$false;
            soak=$false;exclusiveWorkloadConfirmed=$false;privateVulkanVidmemExperiment=$true;
            allWeightsOnGpuVerified=$false;allOperationsOnGpuVerified=$false}}
    }
    $writeReport={
        $report=& $buildReport
        $report.completedAtUtc=(Get-Date).ToUniversalTime().ToString('o')
        $full=[IO.Path]::GetFullPath($OutputPath)
        New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force -ErrorAction Stop|Out-Null
        $file=[IO.File]::Open($full,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$bytes=[Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 18));$file.Write($bytes,0,$bytes.Length)}finally{$file.Dispose()}
        [pscustomobject]$report
    }
    try{
        $first=& $ReadState
        $binding=Assert-FastLlmVulkanVidmemBenchmarkState $first
        Assert-FastLlmVulkanVidmemArm -Arm $Arm -Variant ([string]$first.variant)
        if([string]$first.arm -cne $Arm){throw 'Benchmark arm label differs from the arm recorded at start.'}
        if($first.trialSourceSha256 -cne $trialHash){throw 'Vulkan vidmem trial launch-source hash differs from the measured source.'}
        if($ReferenceReport){
            $reference=ConvertFrom-Json -InputObject (Get-Content -LiteralPath $ReferenceReport -Raw)
            Assert-FastLlmVulkanVidmemReferenceReport -State $first -Reference $reference
            $referenceCheck='matched-reference-arm-'+[string]$reference.arm
        }
        & $CheckProcess $first;& $CheckExecutable $first
        $corpus=('A local inference system should produce accurate useful answers. Measure speed consistently while preserving model quality. '+[Environment]::NewLine)*([int][Math]::Ceiling(4096/16)+2)
        $remaining=[int][Math]::Floor(($DeadlineSeconds-$timer.Elapsed.TotalSeconds)*1000)
        if($remaining -le 0){throw 'Vulkan vidmem benchmark deadline exceeded.'}
        $tokenized=& $Request '/tokenize' @{content=$corpus;add_special=$false} ([Math]::Min(30000,$remaining))
        $current=& $ReadState;$null=Assert-FastLlmVulkanVidmemBenchmarkState $current $binding;& $CheckProcess $current
        if($tokenized.Status -ne 200){throw 'Vulkan vidmem benchmark tokenization failed.'}
        $tokens=@((ConvertFrom-Json $tokenized.Body).tokens)
        if($tokens.Count -lt 4096 -or $tokens.Count -gt 100000){throw 'Vulkan vidmem fixed corpus tokenization outside bounds.'}
        $prompts=@{};$digests=@{}
        $artifacts=@(foreach($length in $promptLengths){
            $array=@($tokens[0..($length-1)]);$digest=Get-FastLlmPromptArtifactSha256 -TokenIds $array
            $prompts[$length]=$array;$digests[$length]=$digest
            [pscustomobject]@{requestedPromptTokens=$length;tokenCount=$length;sha256=$digest;format='fastllm-prompt-tokens-v1'}
        })
        for($round=0;$round -le $repetitions;$round++){
            $roundOrder=if(($round % 2) -eq 0){@(512,4096)}else{@(4096,512)}
            $promptOrderByRound+= ,$roundOrder
            foreach($length in $roundOrder){
                $current=& $ReadState;$null=Assert-FastLlmVulkanVidmemBenchmarkState $current $binding;& $CheckProcess $current
                if((Get-FastLlmPromptArtifactSha256 -TokenIds $prompts[$length]) -cne $digests[$length]){throw 'Vulkan vidmem numeric prompt changed before submission.'}
                $remaining=[int][Math]::Floor(($DeadlineSeconds-$timer.Elapsed.TotalSeconds)*1000)
                if($remaining -le 0){throw 'Vulkan vidmem benchmark deadline exceeded.'}
                $requestStart=(Get-Date).ToUniversalTime().ToString('o')
                $response=& $Request '/completion' @{prompt=$prompts[$length];n_predict=$generationTokens;temperature=0;seed=42;cache_prompt=$false;ignore_eos=$true;stream=$true} ([Math]::Min(180000,$remaining))
                $requestEnd=(Get-Date).ToUniversalTime().ToString('o')
                if((Get-FastLlmPromptArtifactSha256 -TokenIds $prompts[$length]) -cne $digests[$length]){throw 'Vulkan vidmem numeric prompt changed during submission.'}
                $current=& $ReadState;$null=Assert-FastLlmVulkanVidmemBenchmarkState $current $binding;& $CheckProcess $current
                if($timer.Elapsed.TotalSeconds -gt $DeadlineSeconds){throw 'Vulkan vidmem benchmark deadline exceeded.'}
                $sample=ConvertFrom-FastLlmOffloadBenchmarkResponse -Response $response -ExpectedTokens $generationTokens
                if($sample.promptTokens -notin @($length,($length+1))){throw 'Vulkan vidmem server evaluated an unexpected prompt length.'}
                if($evaluated.ContainsKey($length)){
                    if($evaluated[$length] -ne $sample.promptTokens){throw 'Vulkan vidmem warmup and measured evaluations differ.'}
                }else{$evaluated[$length]=$sample.promptTokens}
                $phase=if($round -gt 0){'measured'}else{'warmup'}
                $sample|Add-Member -NotePropertyMembers @{phase=$phase;requestedPromptTokens=$length;repetition=$round;promptArtifactSha256=$digests[$length];startUtc=$requestStart;endUtc=$requestEnd}
                if($round -gt 0){$samples+=$sample}else{$warmups+=$sample}
                Write-Host "Private Vulkan vidmem $Arm prompt $length $phase $round/${repetitions}: prefill $([Math]::Round($sample.promptTokensPerSecond,2)) tok/s, first text $([Math]::Round($sample.timeToFirstTextMs,1)) ms, generation $([Math]::Round($sample.generationTokensPerSecond,2)) tok/s"
            }
        }
        $current=& $ReadState;$null=Assert-FastLlmVulkanVidmemBenchmarkState $current $binding;& $CheckProcess $current;& $CheckExecutable $current
        $summary=@(foreach($length in $promptLengths){
            $group=@($samples|Where-Object requestedPromptTokens -eq $length)
            if($group.Count -ne $repetitions -or @($group|Where-Object promptArtifactSha256 -ne $digests[$length]).Count -or
               @($group|Select-Object -ExpandProperty promptTokens -Unique).Count -ne 1){throw 'Vulkan vidmem sample group evidence is inconsistent.'}
            [pscustomobject]@{requestedPromptTokens=$length;evaluatedPromptTokens=$evaluated[$length];
                generation=Get-FastLlmStatistics $group.generationTokensPerSecond;prefill=Get-FastLlmStatistics $group.promptTokensPerSecond;
                firstText=Get-FastLlmStatistics $group.timeToFirstTextMs;completion=Get-FastLlmStatistics $group.completionMs}
        })
        if($timer.Elapsed.TotalSeconds -gt $DeadlineSeconds -or
           (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $sourceHash -or
           (Get-FileHash -LiteralPath $helperPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $helperHash -or
           (Get-FileHash -LiteralPath $responseParserPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $responseParserHash -or
           (Get-FileHash -LiteralPath $trialPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $trialHash){throw 'Vulkan vidmem benchmark deadline or source provenance changed.'}
        $status='complete';$abortReason=$null
        return (& $writeReport)
    }catch{
        $message=$_.Exception.Message
        if($status -cne 'complete'){
            $status='aborted';$abortReason=$message
            try{$null=& $writeReport}catch{Write-Warning 'Could not write the partial Vulkan vidmem report.'}
        }
        throw
    }
}

function Invoke-FastLlmVulkanVidmemBenchmark {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$RunRoot,[Parameter(Mandatory=$true)][string]$OutputPath,
          [Parameter(Mandatory=$true)][string]$Arm,[string]$ReferenceReport)
    Assert-FastLlmOffloadLabHost
    Assert-FastLlmOffloadRootPath $RunRoot
    if(-not [Environment]::Is64BitProcess){throw 'Vulkan vidmem benchmark requires 64-bit PowerShell.'}
    if(Test-Path -LiteralPath $OutputPath){throw 'Vulkan vidmem benchmark output already exists.'}
    $stateRoot=Get-FastLlmStateRoot -InstallRoot $RunRoot
    $lockPath=Join-FastLlmContainedPath -Root $stateRoot -Child 'vulkan-vidmem-benchmark.lock'
    if((Test-Path -LiteralPath $lockPath) -and ((Get-Item -LiteralPath $lockPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Unsafe Vulkan vidmem benchmark lock.'}
    try{$lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
    catch{throw 'Another Vulkan vidmem benchmark is active.'}
    try{
        $state=Get-FastLlmVulkanVidmemStatus -RunRoot $RunRoot
        Assert-FastLlmVulkanVidmemArm -Arm $Arm -Variant ([string]$state.variant)
        New-FastLlmVulkanVidmemBenchmarkMarker -RunRoot $RunRoot -RunId ([string]$state.runId)
        return Invoke-FastLlmVulkanVidmemBenchmarkCore -OutputPath $OutputPath -Arm $Arm -ReferenceReport $ReferenceReport -ReadState {Get-FastLlmVulkanVidmemStatus -RunRoot $RunRoot} `
            -Request {param($Path,$Body,$TimeoutMs) Invoke-FastLlmHttp -BaseUrl 'http://127.0.0.1:18090' -Path $Path -Body $Body -TimeoutMs $TimeoutMs} `
            -CheckProcess {param($State) Assert-FastLlmVulkanVidmemBenchmarkProcess $State} `
            -CheckExecutable {param($State) Assert-FastLlmVulkanVidmemBenchmarkProcess $State -HashExecutable}
    }finally{$lock.Dispose()}
}
