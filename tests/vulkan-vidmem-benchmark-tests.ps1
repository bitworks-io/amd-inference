#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $root 'src/FastLlm.psm1') -PassThru -ErrorAction Stop
$trial=Join-Path $root 'src/FastLlm.VulkanVidmemTrial.ps1'
$benchmark=Join-Path $root 'src/FastLlm.VulkanVidmemBenchmark.ps1'
$count=0
function Check([bool]$ok,[string]$message){if(-not $ok){throw $message};$script:count++}
function Reject([scriptblock]$action,[string]$message){$failed=$false;try{& $action | Out-Null}catch{$failed=$true};Check $failed $message}
$pins=& $module {param($t) . $t;Get-FastLlmVulkanVidmemPins} $trial
$trialSha=(Get-FileHash -LiteralPath $trial -Algorithm SHA256).Hash.ToLowerInvariant()
$idleOk=[pscustomobject]@{stage='immediately-before-start';checkedAtUtc='2026-10-06T00:00:00.0000000Z';inferenceProcessCount=0;port8080Free=$true;port18090Free=$true;verified=$true}
function New-State([string]$variant,[string]$arm,[string]$tuple='xtx-q4-32k'){
    $spec=& $module {param($t,$x) . $t;Get-FastLlmVulkanVidmemTupleSpec -Tuple $x} $trial $tuple
    $argv=& $module {param($t,$x) . $t;New-FastLlmVulkanVidmemArguments -ModelPath '<verified-model>' -Tuple $x} $trial $tuple
    $withHost=($tuple -ceq 'xtx-q4-32k')
    $override=if($variant -ceq 'default'){[pscustomobject]@{}}else{[pscustomobject]@{GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM='1'}}
    $obs=[pscustomobject]@{variableCount=12;ggmlEnvironment=$override;launchEnvironmentSha256=('e'*64);
        variables=@([pscustomobject]@{name='PATH';valueSha256=('1'*64)},[pscustomobject]@{name='SSH_CLIENT';excluded='session-volatile-or-per-run'});excludedFromDigest=@('SSH_CLIENT','APPDATA');
        launchEnvironmentWithOverrideSha256=$(if($variant -ceq 'default'){'e'*64}else{'f'*64});launchArgumentsSha256=('9'*64);digestScope='unit'}
    [pscustomobject]@{
    active=$true;schemaVersion=1;kind='fastllm-vulkan-vidmem-b10698-private-trial';tuple=$tuple;phase='vulkan-vidmem-ready';endpoint='http://127.0.0.1:18090/v1'
    experimental=$true;performanceQualified=$false;physicalResidencyVerified=$false;dynamicClosureVerified=$false;semanticCorrectnessQualified=$false
    variant=$variant;arm=$arm;environmentOverride=$override;startInfoEnvironmentVerified=$true;observedEnvironment=$obs;
    preLockIdle=$idleOk;preStartIdle=$idleOk;hostModelBufferPolicy='implicit-lane-policy-normal-recipe-reports-CPU_Mapped'
    launchedAtUtc='2026-10-06T00:00:00.0000000Z';healthyAtUtc='2026-10-06T00:01:00.0000000Z';modelLoadSeconds=60.0;readyAtUtc='2026-10-06T00:01:05.0000000Z'
    allowHostModelBuffer=$true;placementClassification=$(if($withHost){'all-reported-layers-with-host-model-buffer'}else{'all-reported-layers-no-host-model-buffer'})
    allWeightsOnGpuVerified=$false;allOperationsOnGpuVerified=$false;cpuInputEvidence='not-attested'
    runId=('a'*32);processIdentity=[pscustomobject]@{pid=23456;startUtcTicks=10000000}
    modelId=$spec.modelId;modelSha256=$spec.modelSha256
    engineVersion='b10698';engineSha256=$pins.engineSha256;catalogSha256=$pins.catalogSha256
    trialSourceSha256=$trialSha
    selectedDevice=[pscustomobject]@{device='Vulkan0';name=$spec.adapterName;reportedFreeMiB=20000}
    recipe=[pscustomobject]@{backend='Vulkan';device='Vulkan0';contextSize=$spec.contextSize;slots=1;gpuLayers='all';fitMode='on';fitTargetMiB=$spec.fitTargetMiB;
        splitMode='none';allowHostModelBuffer=$true;cacheTypeK='f16';cacheTypeV='f16';speculation='none';flashAttention='auto';requestedArguments=@($argv)}
    placement=[pscustomobject]@{reportedLayers=66;totalLayers=66;devices=@('Vulkan0');reportedAllLayers=$true;
        modelBufferMiB=@([pscustomobject]@{device='Vulkan0';sizeMiB=15000.0});physicalResidencyVerified=$false}
    placementEvidence=[pscustomobject]@{status='captured';reportedGpuLayers=66;reportedTotalLayers=66;
        gpuModelBuffer=[pscustomobject]@{device='Vulkan0';sizeMiB=15000.0};hostModelBuffer=$(if($withHost){[pscustomobject]@{device='CPU_Mapped';sizeMiB=682.03}}else{$null});
        classification=$(if($withHost){'all-reported-layers-with-host-model-buffer'}else{'all-reported-layers-no-host-model-buffer'});
        physicalResidencyVerified=$false;allWeightsOnGpuVerified=$false;allOperationsOnGpuVerified=$false}
    placementCounters=[pscustomobject]@{offloadLike=1;bufferLike=$(if($withHost){2}else{1});captured=$(if($withHost){3}else{2});dropped=0}
    startupDiagnostics=[pscustomobject]@{status='partial';physicalResidencyVerified=$false}
    canary=[pscustomobject]@{modelIdentity=$true;repeatableToken=$true;synchronousChat=$true;streaming=$true;
        effectiveContext=$spec.contextSize;semanticCorrectnessQualified=$false}
    }
}
$script:fakeState=New-State 'disable-host-visible-vidmem' 'A1';$script:requestCount=0;$script:checkCount=0;$script:failAt=0
$readState={return $script:fakeState}
$check={param($s) $script:checkCount++;if($s.processIdentity.pid -ne 23456){throw 'PID changed'}}
$request={param($path,$body,$timeoutMs)
    $script:requestCount++
    if($script:failAt -gt 0 -and $script:requestCount -ge $script:failAt){throw 'Injected request failure.'}
    if($timeoutMs -le 0 -or $timeoutMs -gt $(if($path -eq '/completion'){180000}else{30000})){throw 'Unbounded request deadline.'}
    if($path -eq '/tokenize'){
        $phrase='A local inference system should produce accurate useful answers. Measure speed consistently while preserving model quality. '+[Environment]::NewLine
        if($body.content -cne ($phrase*258)){throw 'Fixed benchmark corpus changed.'}
        return [pscustomobject]@{Status=200;Body=(@{tokens=@(0..4999)}|ConvertTo-Json -Compress -Depth 4)}
    }
    if($path -ne '/completion' -or $body.prompt.Count -notin @(512,4096) -or $body.n_predict -ne 128 -or
       $body.cache_prompt -ne $false -or $body.temperature -ne 0 -or -not $body.stream){throw 'Wrong fixed benchmark workload.'}
    $n=$body.prompt.Count
    return [pscustomobject]@{Status=200;Events=@('{"content":"first"}',
        ('{"stop":true,"timings":{"prompt_n":'+$n+',"prompt_ms":100,"predicted_n":128,"predicted_ms":200}}'),'[DONE]');
        EventTimesMs=@(10,250,250);ElapsedMs=250}
}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('fastllm-vulkan-vidmem-benchmark-'+[guid]::NewGuid().ToString('N'))
try{
    New-Item -ItemType Directory -Path $temp -Force|Out-Null
    # Producer fixture: the reviewed bytes (c8b64fe0), independent of whatever is live at src/FastLlm.Benchmark.ps1.
    $v1=Join-Path $root 'src/FastLlm.Benchmark.v1.ps1'
    $producer=Join-Path $temp 'FastLlm.Benchmark.ps1'
    Copy-Item -LiteralPath $v1 -Destination $producer
    $parser=Join-Path $root 'src/FastLlm.OffloadBenchmark.ps1'
    $catalogFile=Join-Path $root 'config/catalog.json'
    Check ((Get-FileHash -LiteralPath $producer -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $pins.producerSha256) 'Producer fixture does not satisfy the pin.'
    $runCore={param($Out,$Arm,$Ref,$Producer,$Parser,$Catalog,$Req)
        & $module {param($T,$B,$O,$R,$Q,$C,$A,$F,$P,$S,$K) . $T;. $B
            Invoke-FastLlmVulkanVidmemBenchmarkCore -OutputPath $O -ReadState $R -Request $Q -CheckProcess $C -CheckExecutable $C -Arm $A -ReferenceReport $F -ProducerPath $P -ParserPath $S -CatalogPath $K -DeadlineSeconds 60
        } $trial $benchmark $Out $readState $Req $check $Arm $Ref $Producer $Parser $Catalog}
    $assertState={param($S) & $module {param($T,$B,$X) . $T;. $B;Assert-FastLlmVulkanVidmemBenchmarkState $X} $trial $benchmark $S}

    $out=Join-Path $temp 'a1.json'
    $report=& $runCore $out 'A1' $null $producer $parser $catalogFile $request
    Check ($report.resultKind -ceq 'native-windows-api-vulkan-vidmem-lab-experiment' -and -not $report.qualification.approved -and $report.qualification.privateVulkanVidmemExperiment -and $report.status -ceq 'complete') 'Distinct unqualified complete result missing.'
    Check ($report.variant -ceq 'disable-host-visible-vidmem' -and $report.arm -ceq 'A1' -and $report.environmentOverride.GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM -ceq '1' -and $report.startInfoEnvironmentVerified) 'Variant/arm/environmentOverride not reported.'
    Check ($report.observedEnvironment.launchEnvironmentSha256 -ceq ('e'*64) -and $report.preStartIdle.verified -and $report.hostModelBufferPolicy -match '^implicit') 'Observed environment, preStartIdle or host-buffer policy not in the report.'
    Check ($report.samples.Count -eq 10 -and $report.warmups.Count -eq 2 -and $script:requestCount -eq 13 -and $script:checkCount -gt 12) 'Fixed warmup/repetition or identity checks missing.'
    Check (@($report.warmups|Where-Object {$_.phase -ceq 'warmup' -and $_.repetition -eq 0}).Count -eq 2 -and @($report.samples|Where-Object {$_.phase -ceq 'measured'}).Count -eq 10) 'Warmups are not labelled and separated.'
    Check (@($report.samples+$report.warmups|Where-Object {-not $_.startUtc -or -not $_.endUtc}).Count -eq 0) 'Per-request start/end UTC missing.'
    Check ($report.timing.modelLoadSeconds -eq 60.0 -and $report.timing.readyAtUtc -and $report.timing.launchedAtUtc) 'Ready time and model-load duration missing.'
    Check (($report.summary.requestedPromptTokens -join ',') -ceq '512,4096' -and $report.recipe.fitMode -ceq 'on') 'Prompt groups or fit mode changed.'
    Check (-not $report.methodology.randomizedPromptOrder -and @($report.methodology.promptOrderByRound).Count -eq 6 -and
           ($report.methodology.promptOrderByRound[0] -join ',') -ceq '512,4096' -and
           ($report.methodology.promptOrderByRound[1] -join ',') -ceq '4096,512') 'Fixed balanced A/B prompt order missing.'
    Check (@($report.samples|Where-Object {$_.promptArtifactSha256 -notin @($report.methodology.promptArtifacts.sha256)}).Count -eq 0) 'Prompt digests not bound.'
    Check ($report.sourceProvenance.vulkanVidmemTrialSha256 -ceq $trialSha -and $report.sourceProvenance.canonicalHelperSha256 -ceq $pins.producerSha256 -and $report.sourceProvenance.strictResponseParserSha256 -ceq $pins.parserSha256 -and $report.sourceProvenance.pinsVerified) 'Pinned provenance absent.'
    $saved=Get-Content -LiteralPath $out -Raw
    Check ($saved -notmatch 'accurate useful answers|"first"' -and $saved -match 'native-windows-api-vulkan-vidmem-lab-experiment') 'Raw text leaked into benchmark.'

    # Pin refusals (producer, parser, catalog), each before any request or output.
    $script:requestCount=0
    $badProducer=Join-Path $temp 'bad/FastLlm.Benchmark.ps1';New-Item -ItemType Directory -Path (Split-Path $badProducer) -Force|Out-Null
    Copy-Item -LiteralPath $v1 -Destination $badProducer;Add-Content -LiteralPath $badProducer -Value '# tamper'
    $badParser=Join-Path $temp 'bad/parser.ps1';Copy-Item -LiteralPath $parser -Destination $badParser;Add-Content -LiteralPath $badParser -Value '# tamper'
    $badCatalog=Join-Path $temp 'bad/catalog.json';Copy-Item -LiteralPath $catalogFile -Destination $badCatalog;Add-Content -LiteralPath $badCatalog -Value ' '
    $liveBenchmark=Join-Path $root 'src/FastLlm.Benchmark.ps1'
    Reject {& $runCore (Join-Path $temp 'p1.json') 'A1' $null $badProducer $parser $catalogFile $request} 'Tampered producer accepted.'
    Reject {& $runCore (Join-Path $temp 'p2.json') 'A1' $null $producer $badParser $catalogFile $request} 'Tampered parser accepted.'
    Reject {& $runCore (Join-Path $temp 'p3.json') 'A1' $null $producer $parser $badCatalog $request} 'Tampered catalog accepted.'
    if((Get-FileHash -LiteralPath $liveBenchmark -Algorithm SHA256).Hash.ToLowerInvariant() -cne $pins.producerSha256){
        Reject {& $runCore (Join-Path $temp 'p4.json') 'A1' $null $liveBenchmark $parser $catalogFile $request} 'Non-reviewed live producer composition accepted.'
    }
    Check ($script:requestCount -eq 0 -and -not (Test-Path (Join-Path $temp 'p1.json'))) 'A pin failure sent requests or wrote output.'
    $s=New-State 'disable-host-visible-vidmem' 'A1';$s.engineSha256=('c'*64);$script:fakeState=$s
    Reject {& $assertState $s} 'Non-pinned engine hash accepted.'
    $s.engineSha256=$pins.engineSha256;$s.catalogSha256=('d'*64)
    Reject {& $assertState $s} 'Non-pinned catalog hash in state accepted.'

    # Arm checks.
    $script:fakeState=New-State 'disable-host-visible-vidmem' 'A1'
    Reject {& $runCore (Join-Path $temp 'arm1.json') 'B1' $null $producer $parser $catalogFile $request} 'Arm B1 accepted for the override variant.'
    Reject {& $runCore (Join-Path $temp 'arm2.json') 'Z9' $null $producer $parser $catalogFile $request} 'Unknown arm accepted.'
    Reject {& $runCore (Join-Path $temp 'arm3.json') 'A2' $null $producer $parser $catalogFile $request} 'Arm differing from the recorded start arm accepted.'

    # Aborted run writes a partial report and keeps warmups and samples.
    $script:requestCount=0;$script:failAt=8
    Reject {& $runCore (Join-Path $temp 'abort.json') 'A1' $null $producer $parser $catalogFile $request} 'Injected failure did not abort.'
    $script:failAt=0
    $partial=ConvertFrom-Json (Get-Content -LiteralPath (Join-Path $temp 'abort.json') -Raw)
    Check ($partial.status -ceq 'aborted' -and $partial.abortReason -match 'Injected' -and @($partial.warmups).Count -eq 2 -and @($partial.samples).Count -gt 0 -and @($partial.samples).Count -lt 10 -and $partial.variant -ceq 'disable-host-visible-vidmem') 'Partial/aborted report missing or lost samples.'

    # Reference-arm environment comparison (B1 vs A1 report).
    $script:fakeState=New-State 'default' 'B1'
    $b1=& $runCore (Join-Path $temp 'b1.json') 'B1' $out $producer $parser $catalogFile $request
    Check ($b1.referenceReportCheck -ceq 'matched-reference-arm-A1' -and $b1.status -ceq 'complete') 'Reference-arm match not recorded.'
    $script:fakeState=New-State 'default' 'B1';$script:fakeState.observedEnvironment.launchEnvironmentSha256=('1'*64);$script:fakeState.observedEnvironment.launchEnvironmentWithOverrideSha256=('1'*64)
    Reject {& $runCore (Join-Path $temp 'b1x.json') 'B1' $out $producer $parser $catalogFile $request} 'Environment drift versus the reference arm accepted.'
    $script:fakeState=New-State 'disable-host-visible-vidmem' 'A1'

    # Comparator over four arm reports.
    $mk={param($arm,$variant) $st=New-State $variant $arm
        [pscustomobject]@{arm=$arm;status='complete';tuple=$st.tuple;variant=$variant;runId=([guid]::NewGuid().ToString('N'));environmentOverride=$st.environmentOverride;
            observedEnvironment=$st.observedEnvironment;modelSha256=$st.modelSha256;engineSha256=$st.engineSha256;catalogSha256=$st.catalogSha256}}
    $four=@((& $mk 'A1' 'disable-host-visible-vidmem'),(& $mk 'B1' 'default'),(& $mk 'B2' 'default'),(& $mk 'A2' 'disable-host-visible-vidmem'))
    $cmp={param($r) & $module {param($T,$B,$R) . $T;. $B;Compare-FastLlmVulkanVidmemArmReports -Reports $R} $trial $benchmark $r}
    Check ((& $cmp $four).ok) 'Comparator rejected a consistent A-B-B-A set.'
    $drift=@($four[0],$four[1],$four[2],(& $mk 'A2' 'disable-host-visible-vidmem'));$drift[3].observedEnvironment=[pscustomobject]@{variableCount=12;ggmlEnvironment=$drift[3].environmentOverride;launchEnvironmentSha256=('2'*64);launchEnvironmentWithOverrideSha256=('3'*64);launchArgumentsSha256=('9'*64)}
    Check (-not (& $cmp $drift).ok) 'Comparator accepted a drifted launch environment.'
    Check (-not (& $cmp @($four[1],$four[0],$four[2],$four[3])).ok) 'Comparator accepted a wrong arm order.'
    $same=@($four[0],(& $mk 'B1' 'disable-host-visible-vidmem'),$four[2],$four[3])
    Check (-not (& $cmp $same).ok) 'Comparator accepted an arm whose variant contradicts its label.'

    # Session-volatile variables and per-run paths must not change the base digest; any other variable must.
    $savedEnv=@{};foreach($n in @('SSH_CLIENT','SSH_CONNECTION')){$savedEnv[$n]=[Environment]::GetEnvironmentVariable($n)}
    try{
        $e1=Join-Path $temp 'engine1';$e2=Join-Path $temp 'engine2';$r1=Join-Path $temp 'runA';$r2=Join-Path $temp 'runB'
        $obs=& $module {param($T,$B,$e1,$e2,$r1,$r2) . $T;. $B
            $mk={param($variant,$ssh,$runRoot,$engineDir,$mutate)
                [Environment]::SetEnvironmentVariable('SSH_CLIENT',$ssh[0]);[Environment]::SetEnvironmentVariable('SSH_CONNECTION',$ssh[1])
                $sb=[pscustomobject]@{appData=(Join-Path $runRoot 'sandbox/a');programData=(Join-Path $runRoot 'sandbox/p')}
                $argv=@(New-FastLlmVulkanVidmemArguments -ModelPath 'm' -Tuple 'xtx-q4-32k')
                $info=New-FastLlmVulkanVidmemStartInfo -EnginePath (Join-Path $engineDir 'llama-server.exe') -Arguments $argv -Sandbox $sb -Variant $variant
                $info.EnvironmentVariables['FASTLLM_RUNPATH']=(Join-Path $runRoot 'work')
                if($mutate){& $mutate $info}
                $o=Get-FastLlmVulkanVidmemObservedEnvironment -Info $info -RunRoot $runRoot -WorkingDirectory $info.WorkingDirectory
                ConvertFrom-Json (ConvertTo-Json $o -Depth 8)}
            $out=@{}
            $out.a=& $mk 'disable-host-visible-vidmem' @('10.0.0.1 56000 22','10.0.0.1 56000 10.0.0.2 22') $r1 $e1 $null
            $out.b=& $mk 'default' @('10.0.0.1 56003 22','10.0.0.1 56003 10.0.0.2 22') $r2 $e2 $null
            $out.c=& $mk 'default' @('10.0.0.1 56003 22','10.0.0.1 56003 10.0.0.2 22') $r2 $e2 {param($i) $i.EnvironmentVariables['VK_LOADER_DEBUG']='secret-value-xyz'}
            $out.d=& $mk 'default' @('10.0.0.1 56003 22','10.0.0.1 56003 10.0.0.2 22') $r2 $e2 {param($i) $i.EnvironmentVariables['PATH']=$i.EnvironmentVariables['PATH']+';C:\extra-secret'}
            $out.e=& $mk 'disable-host-visible-vidmem' @('10.0.0.1 56000 22','10.0.0.1 56000 10.0.0.2 22') $r1 $e1 {param($i) $i.EnvironmentVariables['C28FC6F98A2C44ABBBD89D6A3037D0D9_POSIX_FD_STATE']='fdstate-one'}
            $out.f=& $mk 'default' @('10.0.0.1 56003 22','10.0.0.1 56003 10.0.0.2 22') $r2 $e2 {param($i) $i.EnvironmentVariables['C28FC6F98A2C44ABBBD89D6A3037D0D9_POSIX_FD_STATE']='fdstate-two'}
            $out.namesEF=@(Get-FastLlmVulkanVidmemEnvironmentDifferences -Left $out.e -Right $out.f)
            $out.namesAB=@(Get-FastLlmVulkanVidmemEnvironmentDifferences -Left $out.a -Right $out.b)
            $out.namesBC=@(Get-FastLlmVulkanVidmemEnvironmentDifferences -Left $out.b -Right $out.c)
            $out.namesBD=@(Get-FastLlmVulkanVidmemEnvironmentDifferences -Left $out.b -Right $out.d)
            $ref=[pscustomobject]@{observedEnvironment=$out.b;variant='default';modelSha256='m';engineSha256='e';catalogSha256='c'}
            $st=[pscustomobject]@{observedEnvironment=$out.c;variant='default';modelSha256='m';engineSha256='e';catalogSha256='c'}
            $out.message=try{Assert-FastLlmVulkanVidmemReferenceReport -State $st -Reference $ref;''}catch{$_.Exception.Message}
            $out
        } $trial $benchmark $e1 $e2 $r1 $r2
    }finally{foreach($n in $savedEnv.Keys){[Environment]::SetEnvironmentVariable($n,$savedEnv[$n])}}
    Check ($obs.a.launchEnvironmentSha256 -ceq $obs.b.launchEnvironmentSha256) 'Arms differing only in SSH_CLIENT/SSH_CONNECTION, RunRoot and WorkingDirectory have different base digests.'
    Check ($obs.a.launchEnvironmentWithOverrideSha256 -cne $obs.b.launchEnvironmentWithOverrideSha256) 'Override is no longer isolated in the override-inclusive digest.'
    Check ($obs.namesAB.Count -eq 0) 'Equivalent arms report differing variable names.'
    Check ($obs.e.launchEnvironmentSha256 -ceq $obs.f.launchEnvironmentSha256 -and $obs.namesEF.Count -eq 0) 'Arms differing only in the Win32-OpenSSH POSIX_FD_STATE session variable have different base digests.'
    Check (@($obs.e.excludedFromDigest) -contains 'C28FC6F98A2C44ABBBD89D6A3037D0D9_POSIX_FD_STATE' -and @($obs.e.variables|Where-Object {$_.name -ceq 'C28FC6F98A2C44ABBBD89D6A3037D0D9_POSIX_FD_STATE' -and $_.excluded}).Count -eq 1) 'POSIX_FD_STATE is not excluded from the digest and marked.'
    Check (@($obs.a.excludedFromDigest) -contains 'SSH_CLIENT' -and @($obs.a.excludedFromDigest) -contains 'SESSIONNAME' -and @($obs.a.excludedFromDigest) -contains 'SSH_AUTH_SOCK' -and $obs.a.digestScope -match 'closed exclusion list') 'Exclusion list or scope not recorded.'
    Check (@($obs.a.variables|Where-Object {$_.name -ceq 'SSH_CLIENT'}).Count -eq 0 -or @($obs.a.variables|Where-Object {$_.name -ceq 'SSH_CLIENT' -and $_.excluded}).Count -eq 1) 'Excluded variable not marked.'
    Check ($obs.c.launchEnvironmentSha256 -cne $obs.b.launchEnvironmentSha256 -and $obs.namesBC.Count -eq 1 -and $obs.namesBC[0] -ceq 'VK_LOADER_DEBUG') 'Extra variable not detected by name.'
    Check ($obs.d.launchEnvironmentSha256 -cne $obs.b.launchEnvironmentSha256 -and $obs.namesBD.Count -eq 1 -and $obs.namesBD[0] -ceq 'PATH') 'Different PATH directory not detected.'
    Check ($obs.message -match 'VK_LOADER_DEBUG' -and $obs.message -notmatch 'secret-value-xyz' -and $obs.message -notmatch '[0-9a-f]{64}') 'Reference refusal must list variable names only.'
    Check (@($obs.a.variables|Where-Object {$_.name -ceq 'GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM'}|Where-Object {$_.PSObject.Properties['valueSha256'] -and $_.PSObject.Properties['overrideVariable']}).Count -eq 1) 'Override variable entry missing from per-variable list.'

    # Status of an initial default state is well-formed and not ready.
    $st=& $module {param($T) . $T
        $r=@{}
        $r.init=ConvertTo-FastLlmVulkanVidmemStatus -State ([pscustomobject]@{phase='stopped';active=$false})
        $r.wrong=try{ConvertTo-FastLlmVulkanVidmemStatus -State ([pscustomobject]@{schemaVersion=1;kind='other';active=$false;phase='x'});$false}catch{$true}
        $r.stale=ConvertTo-FastLlmVulkanVidmemStatus -State ([pscustomobject]@{schemaVersion=1;kind='fastllm-vulkan-vidmem-b10698-private-trial';active=$false;phase='vulkan-vidmem-ready'})
        $r} $trial
    Check ($st.init.schemaVersion -eq 1 -and $st.init.phase -ceq 'vulkan-vidmem-not-ready' -and -not $st.init.ready -and -not $st.init.active) 'Initial default state did not yield a well-formed not-ready status.'
    Check ($st.wrong -and $st.stale.phase -ceq 'vulkan-vidmem-interrupted') 'Status conversion lost the foreign-kind refusal or stale-phase handling.'

    # XT IQ4 tuple: a state of that tuple is accepted (no host buffer), and tuple/data mismatches are refused.
    $xtState=New-State 'default' 'B1' 'xt-iq4-16k'
    $null=& $assertState $xtState;$script:count++
    $null=& $assertState (New-State 'disable-host-visible-vidmem' 'A1' 'xt-iq4-16k');$script:count++
    $script:fakeState=New-State 'disable-host-visible-vidmem' 'A1' 'xt-iq4-16k'
    $xtReport=& $runCore (Join-Path $temp 'xt-a1.json') 'A1' $null $producer $parser $catalogFile $request
    Check ($xtReport.tuple -ceq 'xt-iq4-16k' -and $xtReport.recipe.contextSize -eq 16384 -and $xtReport.recipe.fitTargetMiB -eq 512 -and $xtReport.reportedHostModelBufferRows -eq 0 -and $xtReport.modelId -ceq 'qwen3.8-27b-ud-iq4-xs') 'XT IQ4 report fields wrong.'
    $mixed=New-State 'default' 'B1' 'xt-iq4-16k';$mixed.tuple='xtx-q4-32k'
    Reject {& $assertState $mixed} 'XT data under the XTX tuple label accepted.'
    $mixed2=New-State 'default' 'B1';$mixed2.tuple='xt-iq4-16k'
    Reject {& $assertState $mixed2} 'XTX data under the XT tuple label accepted.'
    $wrongAdapter=New-State 'default' 'B1' 'xt-iq4-16k';$wrongAdapter.selectedDevice.name='AMD Radeon RX 7900 XTX'
    Reject {& $assertState $wrongAdapter} 'Wrong adapter name for the tuple accepted.'
    $noTuple=New-State 'default' 'B1';$noTuple.tuple='bogus'
    Reject {& $assertState $noTuple} 'Unknown tuple accepted.'
    $script:fakeState=New-State 'default' 'B1' 'xt-iq4-16k'
    Reject {& $runCore (Join-Path $temp 'xt-b1x.json') 'B1' $out $producer $parser $catalogFile $request} 'Cross-tuple reference report accepted.'
    $mixedFour=@((& $mk 'A1' 'disable-host-visible-vidmem'),(& $mk 'B1' 'default'),(& $mk 'B2' 'default'),(& $mk 'A2' 'disable-host-visible-vidmem'))
    $mixedFour[3].tuple='xt-iq4-16k'
    Check (-not (& $cmp $mixedFour).ok) 'Comparator accepted mixed tuples.'
    $script:fakeState=New-State 'disable-host-visible-vidmem' 'A1'

    # One benchmark per run ID.
    $runRoot=Join-Path $temp 'run'
    & $module {param($r) $null=Get-FastLlmStateRoot -InstallRoot $r -Create} $runRoot
    & $module {param($T,$B,$r) . $T;. $B;New-FastLlmVulkanVidmemBenchmarkMarker -RunRoot $r -RunId ('b'*32)} $trial $benchmark $runRoot
    $script:count++
    Reject {& $module {param($T,$B,$r) . $T;. $B;New-FastLlmVulkanVidmemBenchmarkMarker -RunRoot $r -RunId ('b'*32)} $trial $benchmark $runRoot} 'Second benchmark for the same run ID accepted.'
    Reject {& $module {param($T,$B,$r) . $T;. $B;New-FastLlmVulkanVidmemBenchmarkMarker -RunRoot $r -RunId 'nothex'} $trial $benchmark $runRoot} 'Invalid run ID accepted for the marker.'

    # State save/reload round trip with the real shapes (ordered maps -> JSON -> objects).
    foreach($variant in @('default','disable-host-visible-vidmem')){
        $arm=if($variant -ceq 'default'){'B2'}else{'A2'}
        $rt=Join-Path $temp ('rt-'+$arm)
        $result=& $module {param($T,$B,$r,$variant,$arm) . $T;. $B
            $ov=Get-FastLlmVulkanVidmemEnvironmentOverride -Variant $variant
            $ggml=[ordered]@{};foreach($k in $ov.Keys){$ggml[$k]=$ov[$k]}
            $base=('e'*64)
            $state=[ordered]@{schemaVersion=1;kind='fastllm-vulkan-vidmem-b10698-private-trial';runId=('c'*32);phase='vulkan-vidmem-ready';
                variant=$variant;arm=$arm;environmentOverride=$ov;startInfoEnvironmentVerified=$true;
                allowHostModelBuffer=$true;hostModelBufferPolicy='implicit-lane-policy-normal-recipe-reports-CPU_Mapped';
                recipe=[ordered]@{allowHostModelBuffer=$true};
                observedEnvironment=[ordered]@{variableCount=10;ggmlEnvironment=$ggml;launchEnvironmentSha256=$base;
                    variables=@([ordered]@{name='PATH';valueSha256=('1'*64)},[ordered]@{name='SSH_CLIENT';excluded='session-volatile-or-per-run'});excludedFromDigest=@('SSH_CLIENT','APPDATA');
                    launchEnvironmentWithOverrideSha256=$(if($variant -ceq 'default'){$base}else{'f'*64});launchArgumentsSha256=('9'*64)};
                preStartIdle=[ordered]@{stage='immediately-before-start';checkedAtUtc='x';inferenceProcessCount=0;port8080Free=$true;port18090Free=$true;verified=$true}}
            Write-FastLlmState -InstallRoot $r -State $state
            $loaded=Get-FastLlmStatus -InstallRoot $r
            Assert-FastLlmVulkanVidmemRecordedEnvironment -State $loaded
            $loaded
        } $trial $benchmark $rt $variant $arm
        Check ($result.variant -ceq $variant -and $result.arm -ceq $arm -and @($result.environmentOverride.PSObject.Properties).Count -eq $(if($variant -ceq 'default'){0}else{1})) "Round-trip lost variant/override for $variant."
    }

    # Mutation checks on the shared state shape (host-buffer evidence, recipe and argv integrity).
    $mut={param($scriptblock,$message) $script:fakeState=New-State 'disable-host-visible-vidmem' 'A1';& $scriptblock $script:fakeState;Reject {& $assertState $script:fakeState} $message}
    $null=& $assertState (New-State 'disable-host-visible-vidmem' 'A1');$script:count++
    $null=& $assertState (New-State 'default' 'B1');$script:count++
    & $mut {param($s) $s.recipe.allowHostModelBuffer=$false} 'Host opt-in mismatch accepted.'
    & $mut {param($s) $s.allowHostModelBuffer=$false;$s.recipe.allowHostModelBuffer=$false} 'Non-implicit host-buffer policy accepted.'
    & $mut {param($s) $s.placementEvidence.hostModelBuffer.device='CPU'} 'Nonmapped CPU buffer accepted.'
    & $mut {param($s) $s.placementEvidence.hostModelBuffer.sizeMiB='NaN'} 'Malformed host size accepted.'
    & $mut {param($s) $s.placementEvidence.hostModelBuffer.sizeMiB=1024.01} 'Above-cap host buffer accepted.'
    & $mut {param($s) $s.placementCounters.bufferLike=3} 'Unrecognized model buffer counter accepted.'
    & $mut {param($s) $s.placementEvidence.classification='all-reported-layers-no-host-model-buffer'} 'Contradictory placement classification accepted.'
    & $mut {param($s) $s.placement.modelBufferMiB[0].sizeMiB='NaN';$s.placementEvidence.gpuModelBuffer.sizeMiB='NaN'} 'Nonfinite GPU buffer accepted.'
    & $mut {param($s) $s.phase='ready'} 'Normal Ready state accepted.'
    & $mut {param($s) $s.recipe.requestedArguments[($s.recipe.requestedArguments.IndexOf('--fit')+1)]='off'} 'Altered fit argument accepted.'
    & $mut {param($s) $s.recipe.requestedArguments[($s.recipe.requestedArguments.IndexOf('--port')+1)]='18083'} 'Altered port argument accepted.'
    & $mut {param($s) $s.environmentOverride=[pscustomobject]@{}} 'Override variant with empty override accepted.'
    & $mut {param($s) $s.observedEnvironment.ggmlEnvironment=[pscustomobject]@{}} 'Override variant without an observed GGML_* variable accepted.'
    & $mut {param($s) $s.variant='default'} 'Default variant carrying an override accepted.'
    & $mut {param($s) $s.variant='bogus'} 'Unknown variant accepted.'
    & $mut {param($s) $s.startInfoEnvironmentVerified=$false} 'Unverified start-info environment accepted.'
    & $mut {param($s) $s.preStartIdle.verified=$false} 'Unverified preStartIdle accepted.'
    & $mut {param($s) $s.preStartIdle.port8080Free=$false} 'Busy-port preStartIdle accepted.'
    & $mut {param($s) $s.arm='B1'} 'Arm contradicting the variant accepted.'
    & $mut {param($s) $s.observedEnvironment.launchEnvironmentWithOverrideSha256=('e'*64)} 'Override variant with identical digests accepted.'
    # XT IQ4 post-load path -> supervisor-shaped state -> Write-FastLlmState -> Get-FastLlmVulkanVidmemStatus -> benchmark-state assertion (both host-buffer shapes).
    foreach($shape in @('host','nohost')){
        $withHostXt=($shape -ceq 'host')
        foreach($variant in @('default','disable-host-visible-vidmem')){
            $armXt=if($variant -ceq 'default'){'B1'}else{'A1'}
            $parsed=& $module {param($T,$wh) . $T
                $text="load_tensors: offloaded 66/66 layers to GPU`nload_tensors: Vulkan0 model buffer size = 12726.34 MiB`n"
                if($wh){$text+="load_tensors: CPU_Mapped model buffer size = 521.00 MiB`n"}
                $diag=if($wh){'tensorLines=3, offloadLike=1, bufferLike=2, captured=3, dropped=0, generalOutputTruncated=False'}else{'tensorLines=2, offloadLike=1, bufferLike=1, captured=2, dropped=0, generalOutputTruncated=False'}
                $placement=ConvertFrom-FastLlmPlacementLog -Text $text -Devices @('Vulkan0')
                $ev=ConvertFrom-FastLlmVulkanVidmemBufferEvidence -Text $text -CpuBufferLikeLines $(if($wh){1}else{0}) -Overflow $false -ModelBytes 14252845984 -AllowHostModelBuffer $true
                $c=Assert-FastLlmVulkanVidmemPlacementCounters -Diagnostics $diag -Evidence $ev
                @{placement=$placement;evidence=$ev;counters=$c}} $trial $withHostXt
            $st=New-State $variant $armXt 'xt-iq4-16k'
            $st.placement=$parsed.placement;$st.placementEvidence=$parsed.evidence;$st.placementCounters=$parsed.counters
            $st.placementClassification=$parsed.evidence.classification
            # $idleOk is shared by every New-State and was mutated by the mutation checks above; use fresh clean idle records.
            $st.preLockIdle=[pscustomobject]@{stage='before-locks';checkedAtUtc='2026-10-06T00:00:00.0000000Z';inferenceProcessCount=0;port8080Free=$true;port18090Free=$true;verified=$true}
            $st.preStartIdle=[pscustomobject]@{stage='immediately-before-start';checkedAtUtc='2026-10-06T00:00:00.0000000Z';inferenceProcessCount=0;port8080Free=$true;port18090Free=$true;verified=$true}
            $rtRoot=Join-Path $temp ("xt-rt-$shape-$armXt")
            # The supervisor holds the run-root operation lock while Ready, which is what makes Get-FastLlmStatus report active=$true.
            $rt=& $module {param($T,$B,$r,$s) . $T;. $B
                $lock=Enter-FastLlmOperation $r
                try{
                    Write-FastLlmState -InstallRoot $r -State $s
                    @{loaded=(Get-FastLlmVulkanVidmemStatus -RunRoot $r);m1=(Get-FastLlmStatus -InstallRoot $r);m2=(Get-FastLlmStatus -InstallRoot $r)}
                }finally{$lock.Dispose()}} $trial $benchmark $rtRoot $st
            $loaded=$rt.loaded
            Check ($loaded.tuple -ceq 'xt-iq4-16k' -and $loaded.placementClassification -ceq $(if($withHostXt){'all-reported-layers-with-host-model-buffer'}else{'all-reported-layers-no-host-model-buffer'}) -and $loaded.placementCounters.bufferLike -eq $(if($withHostXt){2}else{1}) -and $loaded.placementCounters.captured -eq $(if($withHostXt){3}else{2})) "XT $shape/$variant state changed in the JSON round trip."
            $b1=& $assertState $loaded;Check ([bool]$b1) "XT $shape/$variant round-tripped state refused by the benchmark assertion."
            $mutated=$rt.m1
            $mutated.placementCounters.bufferLike=$(if($withHostXt){1}else{2})
            Reject {& $assertState $mutated} "XT $shape/$variant with counters inconsistent with evidence accepted."
            if($withHostXt){
                $over=$rt.m2
                $over.placementEvidence.hostModelBuffer.sizeMiB=1024.01
                Reject {& $assertState $over} "XT $variant with CPU_Mapped above the 1024 MiB cap accepted by the benchmark assertion."
            }else{
                $noRow=$rt.m2
                $noRow.placementCounters.bufferLike=2;$noRow.placementCounters.captured=3
                Reject {& $assertState $noRow} "XT $variant with host counters but no host buffer row accepted."
            }
        }
    }
}finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}}
"Vulkan vidmem benchmark checks: $count passed"
