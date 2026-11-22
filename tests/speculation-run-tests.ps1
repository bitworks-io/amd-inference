#requires -Version 5.1
# The speculation option, a real supervised run against the mock server: an n-gram plan really starts, its status and run log record the real
# mode, and at stop a spec-summary event carries the two counters of /metrics (a counter the server does not list is null, never 0). A run without
# speculation keeps exactly its status and run log fields. Mock server only: no engine, GPU, network or bench.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force -ErrorAction Stop
$module=Get-Module FastLlm
$catalog=Join-Path $root 'config/catalog.json'
$script:count=0
function Check($Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:count++;Write-Host "PASS: $Message"}
function Get-RefusalMessage([scriptblock]$Action){ $m='no exception'; try { & $Action | Out-Null } catch { $m=[string]$_.Exception.Message }; return $m }

$temp=Join-Path ([IO.Path]::GetTempPath()) ('speculation-run-tests-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp -Force | Out-Null
try {
    function New-Block([string]$SpecType,[string[]]$Extra){
        return [pscustomobject][ordered]@{
            mode='ngram'; specType=$SpecType; extraArguments=@($Extra); engineId='llama.cpp-b10698-vulkan'; backend='vulkan'; profileId='long'
            modelSha256=('0'*64); extraFreeVramMiB=64; requiredFreeVramMiB=21564; resultId='test-ngram-0001' }
    }
    function Invoke-SpecRun([string]$Label,[string]$MockMode,$Block){
        $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
        $listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
        $runRoot=Join-Path $temp ('run-'+$Label)
        $lock=Enter-FastLlmOperation $runRoot
        $plan=[pscustomobject]@{
            enginePath=(Get-Process -Id $PID).Path
            serverArguments=@('-NoLogo','-NoProfile','-File',(Join-Path $PSScriptRoot 'helpers/mock-server.ps1'),'-Port',"$port",'-Mode',$MockMode,'-Model','test-model','-Context','1024')
            endpoint="http://127.0.0.1:$port/v1"; selectedAdapters=@([pscustomobject]@{device='Vulkan0'})
            hardwareFingerprint='synthetic';engineVersion='test';model=[pscustomobject]@{id='test-model';contextSize=1024;sha256=('0'*64);parallel=1;cacheTypeK='f16';cacheTypeV='f16'}
            catalogVersion='test';backend='Vulkan';splitMode='none';tensorSplit=$null;modelPath='test-model'
        }
        if($null -ne $Block){ $plan | Add-Member -NotePropertyName speculation -NotePropertyValue $Block }
        $stopper=New-Object Diagnostics.Process
        $stopper.StartInfo.FileName=(Get-Process -Id $PID).Path
        $code="Import-Module '$($root.Replace("'","''"))/src/FastLlm.psm1'; for (`$i=0; `$i -lt 150; `$i++) { try { `$s=Get-FastLlmStatus '$($runRoot.Replace("'","''"))'; if (`$s.phase -eq 'ready') { Request-FastLlmStop '$($runRoot.Replace("'","''"))'; exit 0 } } catch {}; Start-Sleep -Milliseconds 200 }; exit 1"
        $stopper.StartInfo.Arguments='-NoLogo -NoProfile -OutputFormat Text -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
        $stopper.StartInfo.UseShellExecute=$false
        $stopper.Start()|Out-Null
        $exit=$null;$failure=$null
        try {
            try { $exit=& $module { param($P,$R,$C) Invoke-FastLlmSupervisedServer -Plan $P -InstallRoot $R -LoadTimeoutSeconds 15 -CatalogPath $C } $plan $runRoot $catalog }
            catch { $failure=$_.Exception }
        } finally { if(-not $stopper.HasExited){ $stopper.Kill() }; $stopper.Dispose(); $lock.Dispose() }
        $events=@()
        $logs=@(Get-ChildItem -LiteralPath (Join-Path $runRoot 'state/logs') -Filter 'run-*.jsonl' -ErrorAction SilentlyContinue)
        if($logs.Count -eq 1){ $events=@([IO.File]::ReadAllLines($logs[0].FullName) | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }) }
        return [pscustomobject]@{exit=$exit;failure=$failure;status=(Get-FastLlmStatus $runRoot);events=$events}
    }
    $defaultRecipeFields='adapters,backend,cacheTypeK,cacheTypeV,catalogSha256,catalogVersion,configurationIsolation,contextSize,engineSha256,flashAttention,requestedArguments,slots,speculation,splitMode,tensorSplit'
    $defaultStartFields='backend,chatPage,contextSize,engineVersion,event,modelId,port,runId,selfTest,thinking,ts'

    # ---- a run without speculation keeps exactly its fields ----------------------------------------------------------------------------------------
    $plain=Invoke-SpecRun 'plain' 'spec-ok' $null
    Check ($null -eq $plain.failure -and $plain.exit -eq 0) "speculation run: a plan without a speculation block reaches ready and stops$(if($plain.failure){': '+$plain.failure.Message})"
    Check (-not $plain.status.PSObject.Properties['speculation'] -and [string]$plain.status.recipe.speculation -ceq 'none' -and (@($plain.status.recipe.PSObject.Properties.Name | Sort-Object) -join ',') -ceq $defaultRecipeFields) 'speculation run: a plain run has no status speculation field, recipe.speculation is none and the recipe has exactly its fields'
    $plainStart=@($plain.events | Where-Object { [string]$_.event -ceq 'start' })[0]
    Check ((@($plainStart.PSObject.Properties.Name | Sort-Object) -join ',') -ceq $defaultStartFields) 'speculation run: a plain run''s start event has exactly its existing fields'
    Check (@($plain.events | Where-Object { [string]$_.event -ceq 'spec-summary' }).Count -eq 0) 'speculation run: a plain run writes no spec-summary event, even when the server reports the counters'
    Check (-not ([IO.File]::ReadAllText((Join-Path $temp 'run-plain/state/status.json'))).Contains('speculation"')) 'speculation run: a plain run''s status.json text has no speculation key'

    # ---- an ngram plan really starts and records the real mode ----------------------------------------------------------------------------------------
    $block=New-Block 'ngram-simple' @('--spec-ngram-size-n','12','--spec-ngram-size-m','48')
    $run=Invoke-SpecRun 'ngram' 'spec-ok' $block
    Check ($null -eq $run.failure -and $run.exit -eq 0 -and [string]$run.status.phase -ceq 'stopped') "speculation run: an ngram plan reaches ready and is stopped by the user$(if($run.failure){': '+$run.failure.Message})"
    $recorded=$run.status.speculation
    Check ($null -ne $recorded -and [string]$recorded.mode -ceq 'ngram' -and [string]$recorded.specType -ceq 'ngram-simple' -and (@($recorded.extraArguments) -join ' ') -ceq '--spec-ngram-size-n 12 --spec-ngram-size-m 48' -and [string]$recorded.resultId -ceq 'test-ngram-0001') 'speculation run: status.json records the real mode in an additive speculation field (mode, spec type, extra arguments, evidence id)'
    Check ((@($recorded.PSObject.Properties.Name) -join ',') -ceq 'mode,specType,extraArguments,resultId') 'speculation run: the status speculation field has exactly those four members'
    Check ([string]$run.status.recipe.speculation -ceq 'ngram-simple') 'speculation run: recipe.speculation names the spec type that runs, so the measurement tools that require none refuse it'
    $start=@($run.events | Where-Object { [string]$_.event -ceq 'start' })[0]
    Check ([string]$start.speculation -ceq 'ngram-simple' -and (@($start.PSObject.Properties.Name | Sort-Object) -join ',') -ceq ($defaultStartFields+',speculation')) 'speculation run: the run log start event gains one field, speculation'
    $summary=@($run.events | Where-Object { [string]$_.event -ceq 'spec-summary' })
    Check ($summary.Count -eq 1 -and [long]$summary[0].draftTokens -eq 120 -and [long]$summary[0].acceptedTokens -eq 90 -and (@($summary[0].PSObject.Properties.Name | Sort-Object) -join ',') -ceq 'acceptedTokens,draftTokens,event,runId,ts') 'speculation run: at stop one spec-summary event carries draftTokens 120 and acceptedTokens 90 read from /metrics, and nothing else'
    $names=@($run.events | ForEach-Object { [string]$_.event })
    Check ($names.IndexOf('spec-summary') -gt $names.IndexOf('start') -and $names.IndexOf('spec-summary') -lt $names.IndexOf('end')) 'speculation run: the spec-summary comes after start and before end'

    $oneCounter=Invoke-SpecRun 'draft-only' 'specdraft-ok' $block
    $s1=@($oneCounter.events | Where-Object { [string]$_.event -ceq 'spec-summary' })
    Check ($s1.Count -eq 1 -and $s1[0].PSObject.Properties['acceptedTokens'] -and $null -eq $s1[0].acceptedTokens -and [long]$s1[0].draftTokens -eq 120) 'speculation run: a counter the server does not report is recorded as null (never 0), the other keeps its number'
    $acceptedOnly=Invoke-SpecRun 'accepted-only' 'specaccepted-ok' $block
    $s2=@($acceptedOnly.events | Where-Object { [string]$_.event -ceq 'spec-summary' })
    Check ($s2.Count -eq 1 -and $null -eq $s2[0].draftTokens -and [long]$s2[0].acceptedTokens -eq 90) 'speculation run: the same the other way round'
    $noCounters=Invoke-SpecRun 'no-counters' 'ok' $block
    $s3=@($noCounters.events | Where-Object { [string]$_.event -ceq 'spec-summary' })
    Check ($s3.Count -eq 1 -and $s3[0].PSObject.Properties['draftTokens'] -and $s3[0].PSObject.Properties['acceptedTokens'] -and $null -eq $s3[0].draftTokens -and $null -eq $s3[0].acceptedTokens) 'speculation run: with neither counter reported both are null'
    $noMetrics=Invoke-SpecRun 'no-metrics' 'spec-nometrics-ok' $block
    $s4=@($noMetrics.events | Where-Object { [string]$_.event -ceq 'spec-summary' })
    Check ($null -eq $noMetrics.failure -and $s4.Count -eq 1 -and $null -eq $s4[0].draftTokens -and $null -eq $s4[0].acceptedTokens) 'speculation run: a /metrics that cannot be read gives null counters and never fails the run'

    # ---- the counter reader and the run log allowlist: numbers only -------------------------------------------------------------------------------------
    $entry=& $module { Get-FastLlmSpeculationAllowlistEntry -EngineId 'llama.cpp-b10698-vulkan' }
    $read={ param($Text) & $module { param($T,$E) Get-FastLlmSpeculationCounters -MetricsText $T -Counters $E.counters } $Text $entry }
    $both=& $read ("# HELP x`nllamacpp:spec_decode_num_draft_tokens_total 7`nllamacpp:spec_decode_num_accepted_tokens_total 5`n")
    Check ($both.draftTokens -eq 7 -and $both.acceptedTokens -eq 5) 'counters: both counters are read by their pinned names'
    $float=& $read "llamacpp:spec_decode_num_draft_tokens_total 7.0`nllamacpp:spec_decode_num_accepted_tokens_total 5.0`n"
    Check ($float.draftTokens -eq 7 -and $float.acceptedTokens -eq 5) 'counters: a whole number printed with a decimal point is read'
    $odd=& $read "llamacpp:spec_decode_num_draft_tokens_total abc`nllamacpp:spec_decode_num_accepted_tokens_total -3`n"
    Check ($null -eq $odd.draftTokens -and $null -eq $odd.acceptedTokens) 'counters: a value that is not a non-negative whole number is null'
    $other=& $read "llamacpp:spec_decode_num_drafts_total 9`nllamacpp:tokens_predicted_total 4`n"
    Check ($null -eq $other.draftTokens -and $null -eq $other.acceptedTokens) 'counters: a counter with another name (the drafts count, tokens predicted) is never taken for either'
    $empty=& $read ''
    Check ($null -eq $empty.draftTokens -and $null -eq $empty.acceptedTokens) 'counters: no text gives null, never 0'
    $unpinned=& $module { Get-FastLlmSpeculationCounters -MetricsText 'llamacpp:spec_decode_num_draft_tokens_total 7' -Counters $null }
    Check ($null -eq $unpinned.draftTokens -and $null -eq $unpinned.acceptedTokens) 'counters: an engine with no pinned counter names records null'
    $folder=Join-Path $temp 'allowlist-log'
    $eventResult=& $module { param($F) Write-FastLlmRunLogEvent -InstallRoot $F -RunId 'abc-1' -Event 'spec-summary' -Fields @{ draftTokens = 3; acceptedTokens = $null } } $folder
    Check ($eventResult -eq $true) 'run log: a spec-summary event with a number and a null is written'
    foreach($bad in @(@{prompt='x'},@{draftTokens='12'},@{draftTokens=1.5},@{acceptedTokens=$true},@{draftTokens=-1})){
        $message=Get-RefusalMessage { & $module { param($F,$Fields) Write-FastLlmRunLogEvent -InstallRoot $F -RunId 'abc-2' -Event 'spec-summary' -Fields $Fields } $folder $bad }
        Check ($message -like 'run-log-*') ('run log: a spec-summary field that is not a counter number is refused ('+(($bad.Keys | ForEach-Object { $_+'='+$bad[$_] }) -join ',')+')')
    }

    # ---- a malformed block never starts ------------------------------------------------------------------------------------------------------------------
    $badBlock=New-Block 'ngram-simple' @('--spec-ngram-size-n','12')
    $badBlock.specType='ngram simple; rm'
    $bad=Invoke-SpecRun 'bad-block' 'ok' $badBlock
    Check ($null -ne $bad.failure -and [string]$bad.failure.Data['FastLlmFailureCode'] -ceq 'speculation-invalid' -and [string]::IsNullOrEmpty([string]$bad.failure.Data['FastLlmReason'])) 'speculation run: a plan block with a malformed spec type fails typed (speculation-invalid) with nothing to retry or recover'
    Write-Host "speculation-run-tests (mock-server start, status, run log, spec-summary): $script:count checks passed"
}
finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
