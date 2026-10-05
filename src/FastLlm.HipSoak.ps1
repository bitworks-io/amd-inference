# Private HIP reliability exercise. This is not a qualification or a server manager.
function Get-FastLlmHipSoakSources {
    $names=[ordered]@{
        hipSoak='FastLlm.HipSoak.ps1'
        hipBenchmark='FastLlm.HipBenchmark.ps1'
        hipTrial='FastLlm.HipModelTrial.ps1'
        runtime='FastLlm.Runtime.ps1'
        processHost='ProcessHost.cs'
        listenerProbe='WindowsGpuTelemetry.cs'
    }
    $hashes=[ordered]@{}
    foreach($key in $names.Keys){
        $hashes[$key+'Sha256']=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $names[$key]) -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    return $hashes
}

function Assert-FastLlmHipSoakSources {
    param($Expected)
    $current=Get-FastLlmHipSoakSources
    foreach($key in $Expected.Keys){if($current[$key] -cne $Expected[$key]){throw 'Private HIP soak source changed.'}}
}

function Assert-FastLlmHipSoakReady {
    param($State,[string]$RunId,[string]$Binding,[scriptblock]$CheckProcess,$Sources)
    if($null -eq $State -or $State.runId -cne $RunId){throw 'Private HIP run changed.'}
    $currentBinding=Assert-FastLlmHipBenchmarkState -State $State -ExpectedBinding $Binding
    if($State.trialSourceSha256 -cne $Sources.hipTrialSha256){throw 'Private HIP trial source differs from launch source.'}
    & $CheckProcess $State
    Assert-FastLlmHipSoakSources $Sources
    return $currentBinding
}

function New-FastLlmHipSoakReportReservation {
    param([string]$OutputPath)
    if([string]::IsNullOrWhiteSpace($OutputPath) -or -not [IO.Path]::IsPathRooted($OutputPath)){
        throw 'Private HIP soak output must be an absolute path.'
    }
    $full=[IO.Path]::GetFullPath($OutputPath)
    if([IO.Path]::GetExtension($full) -ine '.json'){throw 'Private HIP soak output must be a .json file.'}
    if($env:OS -eq 'Windows_NT' -and [IO.Path]::GetPathRoot($full) -notmatch '^[A-Za-z]:\\$'){
        throw 'Private HIP soak output must be on a local drive.'
    }
    $parent=[IO.Path]::GetDirectoryName($full)
    if(-not (Test-Path -LiteralPath $parent -PathType Container)){throw 'Private HIP soak output directory must already exist.'}
    if($env:OS -eq 'Windows_NT'){
        $cursor=$parent
        while($cursor){
            $item=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Private HIP soak output traverses a reparse point.'}
            $next=[IO.Path]::GetDirectoryName($cursor)
            if(-not $next -or $next -ceq $cursor){break}
            $cursor=$next
        }
    }
    if(Test-Path -LiteralPath $full){throw 'Private HIP soak output already exists.'}
    $stream=[IO.File]::Open($full,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    return [pscustomobject]@{path=$full;stream=$stream}
}

function Enter-FastLlmHipSoakLock {
    param([string]$StateRoot)
    $lockPath=Join-FastLlmContainedPath -Root $StateRoot -Child 'hip-benchmark.lock'
    if((Test-Path -LiteralPath $lockPath) -and ((Get-Item -LiteralPath $lockPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){
        throw 'Unsafe HIP benchmark lock.'
    }
    try{return [IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
    catch{throw 'Another HIP benchmark, semantic check, or soak is active.'}
}

function Invoke-FastLlmHipSoakCore {
    param([string]$OutputPath,[string]$RunId,[scriptblock]$ReadState,[scriptblock]$CheckProcess,
          [scriptblock]$Canary,[int]$MinimumCycles=100,[int]$DurationSeconds=7200,
          [int]$MaximumSeconds=10800,[scriptblock]$GetElapsed,[scriptblock]$Pause)
    if($RunId -cnotmatch '^[0-9a-f]{32}$' -or $MinimumCycles -lt 1 -or $MinimumCycles -gt 100000 -or
       $DurationSeconds -lt 0 -or $DurationSeconds -gt 172800 -or $MaximumSeconds -lt $DurationSeconds -or
       $MaximumSeconds -gt 172800 -or -not $ReadState -or -not $CheckProcess -or -not $Canary){
        throw 'Private HIP soak arguments are invalid.'
    }
    if(Test-Path -LiteralPath $OutputPath){throw 'Private HIP soak output already exists.'}
    $clock=[Diagnostics.Stopwatch]::StartNew()
    if(-not $GetElapsed){$GetElapsed={ $clock.Elapsed.TotalSeconds }.GetNewClosure()}
    if(-not $Pause){$Pause={Start-Sleep -Milliseconds 250}}
    $sources=Get-FastLlmHipSoakSources
    # Reserve the final name and write capability before a potentially multi-hour run.
    $reservation=New-FastLlmHipSoakReportReservation -OutputPath $OutputPath
    $reportWritten=$false
    try{
    $first=$null;$trustedFirst=$null;$binding=$null;$completed=0;$failureCode=$null;$elapsed=0.0
    $startedUtc=[DateTime]::UtcNow.ToString('o')
    try{
        $first=& $ReadState
        $binding=Assert-FastLlmHipSoakReady -State $first -RunId $RunId -CheckProcess $CheckProcess -Sources $sources
        # Never serialize an unvalidated or subsequently mutable status object into a failure report.
        $trustedFirst=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $first -Depth 18)
        do{
            $elapsed=[double](& $GetElapsed)
            if([double]::IsNaN($elapsed) -or [double]::IsInfinity($elapsed) -or $elapsed -lt 0 -or $elapsed -ge $MaximumSeconds){
                $failureCode='elapsed-deadline';break
            }
            $current=& $ReadState
            $null=Assert-FastLlmHipSoakReady -State $current -RunId $RunId -Binding $binding -CheckProcess $CheckProcess -Sources $sources
            # Existing canary: four inference requests plus two metadata requests.
            # Production bounds each HTTP request; injected tests never run natively.
            $result=& $Canary $current
            $current=& $ReadState
            $null=Assert-FastLlmHipSoakReady -State $current -RunId $RunId -Binding $binding -CheckProcess $CheckProcess -Sources $sources
            if($null -eq $result -or $result.modelIdentity -ne $true -or $result.repeatableToken -ne $true -or
               $result.synchronousChat -ne $true -or $result.streaming -ne $true -or
               [int]$result.effectiveContext -ne [int]$first.recipe.contextSize -or
               $result.semanticCorrectnessQualified -ne $false){throw 'Private HIP canary failed.'}
            $completed++
            $elapsed=[double](& $GetElapsed)
            if([double]::IsNaN($elapsed) -or [double]::IsInfinity($elapsed) -or $elapsed -lt 0 -or $elapsed -gt $MaximumSeconds){
                $failureCode='elapsed-deadline';break
            }
            if($completed % 10 -eq 0){Write-Host "Private HIP soak: $completed cycles, $([int]$elapsed) seconds elapsed."}
            if($completed -ge $MinimumCycles -and $elapsed -ge $DurationSeconds){break}
            & $Pause
        }while($true)
        if(-not $failureCode){
            $current=& $ReadState
            $null=Assert-FastLlmHipSoakReady -State $current -RunId $RunId -Binding $binding -CheckProcess $CheckProcess -Sources $sources
            $elapsed=[double](& $GetElapsed)
            if($completed -lt $MinimumCycles -or $elapsed -lt $DurationSeconds -or $elapsed -gt $MaximumSeconds){$failureCode='incomplete'}
        }
    }catch{if(-not $failureCode){$failureCode='identity-source-process-or-canary-failed'}}
    $endedUtc=[DateTime]::UtcNow.ToString('o')
    $productionGate=($MinimumCycles -ge 100 -and $DurationSeconds -ge 7200)
    $completedGate=($null -eq $failureCode -and $completed -ge $MinimumCycles -and $elapsed -ge $DurationSeconds -and $elapsed -le $MaximumSeconds)
    $report=[ordered]@{
        schemaVersion=1;resultKind='native-windows-hip-private-soak-experiment';recordedAt=$endedUtc
        runId=$RunId;startedUtc=$startedUtc;endedUtc=$endedUtc
        processIdentity=$(if($trustedFirst){$trustedFirst.processIdentity}else{$null})
        modelId=$(if($trustedFirst){$trustedFirst.modelId}else{$null});modelSha256=$(if($trustedFirst){$trustedFirst.modelSha256}else{$null})
        engineVersion=$(if($trustedFirst){$trustedFirst.engineVersion}else{$null});engineSha256=$(if($trustedFirst){$trustedFirst.engineSha256}else{$null})
        catalogSha256=$(if($trustedFirst){$trustedFirst.catalogSha256}else{$null});trialSourceSha256=$(if($trustedFirst){$trustedFirst.trialSourceSha256}else{$null})
        evidenceBindingSha256=$binding;endpoint='http://127.0.0.1:18081/v1'
        allowHostModelBuffer=$(if($trustedFirst){$trustedFirst.allowHostModelBuffer}else{$null})
        placementClassification=$(if($trustedFirst){$trustedFirst.placementClassification}else{$null})
        placementEvidence=$(if($trustedFirst){$trustedFirst.placementEvidence}else{$null})
        allWeightsOnGpuVerified=$false;allOperationsOnGpuVerified=$false;cpuInputEvidence='not-attested'
        sourceProvenance=@{hashes=$sources;scope='on-disk sources checked at each cycle boundary; loaded-code identity is not attested'}
        methodology=@{canary='existing-fastllm-api-canary';inferenceRequestsPerCycle=4;httpRequestsPerCycle=6;minimumCycles=$MinimumCycles
            durationSeconds=$DurationSeconds;maximumElapsedSeconds=$MaximumSeconds
            completionGateRequires100CyclesAnd2Hours=$productionGate
            requestTimeouts='model/props default 5s; completion/chat 30s each; no hard process deadline'
            exclusiveWorkloadConfirmed=$false}
        outcome=@{completedCycles=$completed;elapsedSeconds=$elapsed;completed=($completedGate -and $productionGate)
            diagnosticFinished=$completedGate
            status=$(if($completedGate -and $productionGate){'private-soak-completed'}elseif($completedGate){'short-diagnostic-only'}else{'failed'})
            failureCode=$failureCode}
        qualification=@{approved=$false;soakQualified=$false;performanceQualified=$false;qualityEvaluation=$false
            physicalResidency=$false;driverReset=$false;sleepResume=$false;exclusiveWorkloadConfirmed=$false}
    }
    $bytes=[Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 18))
    if($bytes.Length -gt 65536){throw 'Private HIP soak report exceeds its 64 KiB bound.'}
    $reservation.stream.Write($bytes,0,$bytes.Length)
    $reservation.stream.Flush($true)
    $reportWritten=$true
    return [pscustomobject]$report
    }finally{
        $reservation.stream.Dispose()
        if(-not $reportWritten){[IO.File]::Delete($reservation.path)}
    }
}

function Invoke-FastLlmHipSoak {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$RunRoot,[Parameter(Mandatory=$true)][string]$RunId,
          [Parameter(Mandatory=$true)][string]$OutputPath)
    Assert-FastLlmHipLabIdentity
    Assert-FastLlmOffloadRootPath $RunRoot
    if(-not [Environment]::Is64BitProcess){throw 'HIP soak requires 64-bit PowerShell.'}
    if($RunId -cnotmatch '^[0-9a-f]{32}$'){throw 'Exact HIP run ID required.'}
    if(Test-Path -LiteralPath $OutputPath){throw 'Private HIP soak output already exists.'}
    $stateRoot=Get-FastLlmStateRoot -InstallRoot $RunRoot
    $lock=Enter-FastLlmHipSoakLock -StateRoot $stateRoot
    try{
        return Invoke-FastLlmHipSoakCore -OutputPath $OutputPath -RunId $RunId `
            -ReadState {Get-FastLlmHipTrialStatus -RunRoot $RunRoot} `
            -CheckProcess {param($State) Assert-FastLlmHipBenchmarkProcess -State $State -HashExecutable} `
            -Canary {param($State) Test-FastLlmApiCanary -BaseUrl 'http://127.0.0.1:18081' -ModelId $State.modelId -ContextSize $State.recipe.contextSize} `
            -MinimumCycles 100 -DurationSeconds 7200 -MaximumSeconds 10800
    }finally{$lock.Dispose()}
}
