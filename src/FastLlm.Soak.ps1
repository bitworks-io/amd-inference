# API reliability exercise only. Memory residency and model quality need separate evidence.
function Invoke-FastLlmApiSoakCore {
    param($State, [scriptblock]$ReadState, [int]$MinimumCycles, [int]$DurationSeconds)
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $completed=0
    $failure=$null
    try {
        do {
            $current=& $ReadState
            if (-not $current.active -or $current.phase -ne 'ready' -or $current.runId -ne $State.runId) { throw 'Server identity changed during soak.' }
            Test-FastLlmApiCanary -BaseUrl ($State.endpoint -replace '/v1$','') -ModelId $State.modelId -ContextSize $State.recipe.contextSize | Out-Null
            $completed++
            if ($completed % 10 -eq 0) { Write-Host "Soak: $completed cycles, $([int]$clock.Elapsed.TotalSeconds) seconds elapsed." }
            if ($completed -ge $MinimumCycles -and $clock.Elapsed.TotalSeconds -ge $DurationSeconds) { break }
            Start-Sleep -Milliseconds 250
        } while ($true)
        $current=& $ReadState
        if (-not $current.active -or $current.phase -ne 'ready' -or $current.runId -ne $State.runId) { throw 'Server identity changed before soak completion.' }
    } catch { $failure='api-canary-or-server-identity-failed' }
    return [pscustomobject]@{
        completedCycles=$completed;minimumCycles=$MinimumCycles;requestedDurationSeconds=$DurationSeconds
        elapsedSeconds=$clock.Elapsed.TotalSeconds;completed=($null -eq $failure);failureCode=$failure
        inferenceRequestsPerCycle=4;tokensPerCompletionCanary=1;maximumTokensPerChatCanary=8
    }
}

function Invoke-FastLlmSoak {
    [CmdletBinding()]
    param([string]$InstallRoot,[string]$OutputPath,[ValidateRange(1,100000)][int]$MinimumCycles=100,[ValidateRange(0,172800)][int]$DurationSeconds=7200)
    if ($env:OS -ne 'Windows_NT') { throw 'Physical reliability runs require native Windows.' }
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run soak tests as a standard user.' }
    $state=Get-FastLlmStatus $InstallRoot
    if (-not $state.active -or $state.phase -ne 'ready' -or -not $state.recipe) { throw 'Start a supervised server and wait for ready before testing.' }
    if (Test-Path -LiteralPath $OutputPath) { throw 'Soak output already exists; choose a new result file.' }
    $lockPath=Join-Path (Get-FastLlmStateRoot $InstallRoot) 'benchmark.lock'
    if ((Test-Path -LiteralPath $lockPath) -and ((Get-Item -LiteralPath $lockPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe benchmark lock.' }
    $lock=[IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None')
    try {
        $outcome=Invoke-FastLlmApiSoakCore -State $state -ReadState { Get-FastLlmStatus $InstallRoot } -MinimumCycles $MinimumCycles -DurationSeconds $DurationSeconds
        $result=[ordered]@{
            schemaVersion=1;resultKind='native-windows-api-soak-not-full-qualification';recordedAt=(Get-Date).ToUniversalTime().ToString('o')
            modelId=$state.modelId;modelSha256=$state.modelSha256;engineVersion=$state.engineVersion;recipe=$state.recipe
            outcome=$outcome
            qualification=@{approved=$false;qualityEvaluation=$false;physicalResidency=$false;longContext=$false;driverReset=$false;sleepResume=$false}
        }
        $fullPath=[IO.Path]::GetFullPath($OutputPath)
        New-Item -ItemType Directory -Path (Split-Path $fullPath -Parent) -Force | Out-Null
        $file=[IO.File]::Open($fullPath,'CreateNew','Write','None')
        try { $bytes=[Text.Encoding]::UTF8.GetBytes(($result | ConvertTo-Json -Depth 16));$file.Write($bytes,0,$bytes.Length) }
        finally { $file.Dispose() }
        if (-not $outcome.completed) { throw "Soak failed; a failure-only report was saved to '$OutputPath'." }
        return $result
    } finally { $lock.Dispose() }
}
