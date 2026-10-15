Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/FastLlm.BackgroundHost.ps1')

function Assert-BackgroundTest {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw $Message }
}

function Read-FastLlmJson {
    param([string]$Path)
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-FastLlmStatus {
    param([string]$InstallRoot)
    return $script:mockStatus
}

function Test-FastLlmBackgroundLoopbackHealth { return $true }

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('fastllm-bg-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    $source = Split-Path -Parent $PSScriptRoot
    $pinNames = @((Get-FastLlmBackgroundSourcePins -SourceRoot $source).Keys)
    foreach ($pinned in @('src/FastLlm.VulkanMemoryPolicy.ps1','src/FastLlm.SelfTest.ps1','src/FastLlm.DeviceBinding.ps1','tools/collect-vulkan-luid-join.ps1','src/WindowsVulkanLuidJoin.cs','src/WindowsPciAddress.cs','src/FastLlm.CardIdentity.ps1','src/FastLlm.Recipes.ps1','config/recipes.json','config/gpu-variants.json')) {
        Assert-BackgroundTest ($pinNames -contains $pinned) "Background source pins omit $pinned."
    }
    $self = [Diagnostics.Process]::GetCurrentProcess()
    try { $hostIdentity = [ordered]@{pid=[int]$self.Id;startUtcTicks=[long]$self.StartTime.ToUniversalTime().Ticks} }
    finally { $self.Dispose() }
    $requestA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $requestB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    $runA = '11111111111111111111111111111111'
    $runB = '22222222222222222222222222222222'
    $script:mockStatus = [pscustomobject]@{active=$false;phase='stopped'}
    $privateStateCheck = (Get-Command Assert-FastLlmBackgroundPrivateState).ScriptBlock
    $nativeHostCheck = (Get-Command Assert-FastLlmBackgroundNativeHost).ScriptBlock
    function Assert-FastLlmBackgroundPrivateState { throw 'background-only private-state refusal' }
    try {
        $ordinary = Get-FastLlmBackgroundHostStatus -InstallRoot $scratch -SourceRoot $source
        Assert-BackgroundTest ($ordinary.phase -ceq 'absent' -and -not $ordinary.occupied) 'Absent background host imposed background-only ACL policy.'
        function Assert-FastLlmBackgroundNativeHost {}
        $refused = $false
        try { Start-FastLlmBackgroundHost -InstallRoot $scratch -SourceRoot $source -NoWait | Out-Null }
        catch { $refused = $_.Exception.Message -match 'background-only private-state refusal' }
        Assert-BackgroundTest $refused 'Opt-in background Start skipped private-state ACL gate.'
    } finally {
        Set-Item -Path Function:Assert-FastLlmBackgroundPrivateState -Value $privateStateCheck
        Set-Item -Path Function:Assert-FastLlmBackgroundNativeHost -Value $nativeHostCheck
    }
    $lockPath = Join-Path (Split-Path -Parent (Get-FastLlmBackgroundPath -InstallRoot $scratch -Leaf 'background-host.json')) 'operation.lock'
    $held = [IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $unowned = Get-FastLlmBackgroundHostStatus -InstallRoot $scratch -SourceRoot $source
        Assert-BackgroundTest ($unowned.occupied -and -not $unowned.active -and $unowned.phase -ceq 'occupied-unverified') 'An ownerless active operation was reported absent.'
    } finally { $held.Dispose() }
    $owner = [ordered]@{schemaVersion=1;kind='fastllm-private-background-host';requestId=$requestA;
        hostIdentity=$hostIdentity;phase='loading';modelId='model-a';failureCode=$null;
        sourceRoot=$source;sourcePinSha256=(Get-FileHash -LiteralPath (Join-Path $source 'src/FastLlm.BackgroundHost.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()}
    $ownerPath = Get-FastLlmBackgroundPath -InstallRoot $scratch -Leaf 'background-host.json'
    Write-FastLlmBackgroundDocument -Path $ownerPath -Value $owner
    $ownerRequestPath = Get-FastLlmBackgroundPath -InstallRoot $scratch -Leaf ('background-request-' + $requestA + '.json')
    Write-FastLlmBackgroundDocument -Path $ownerRequestPath -CreateNew -Value ([ordered]@{
        requestId=$requestA;sourcePins=(Get-FastLlmBackgroundSourcePins -SourceRoot $source)})
    $script:mockStatus = [pscustomobject]@{active=$false;phase='stopped'}
    $liveOwnerBeforeStatus = Get-FastLlmBackgroundHostStatus -InstallRoot $scratch -SourceRoot $source -SkipHealth
    Assert-BackgroundTest ($liveOwnerBeforeStatus.occupied -and -not $liveOwnerBeforeStatus.active) 'A live owner without a Ready status appeared startable.'
    $script:mockStatus = [pscustomobject]@{active=$true;phase='ready';runId=$runA;
        backgroundRequestId=$requestA;modelId='model-a';endpoint='http://127.0.0.1:8080/v1';
        canary=[pscustomobject]@{passed=$true};processIdentity=$hostIdentity}
    $before = Get-FastLlmBackgroundHostStatus -InstallRoot $scratch -SourceRoot $source
    $attached = Attach-FastLlmBackgroundHost -InstallRoot $scratch -SourceRoot $source -ExpectedRequestId $requestA
    Assert-BackgroundTest ($attached.attachable -and $attached.runId -ceq $runA) 'Matching owner and run failed to attach.'
    $rejected = $false
    try { Attach-FastLlmBackgroundHost -InstallRoot $scratch -SourceRoot $source -ExpectedRequestId $requestB | Out-Null }
    catch { $rejected = $true }
    Assert-BackgroundTest $rejected 'Wrong request ID attached to background host.'
    $script:mockStatus = [pscustomobject]@{active=$true;phase='ready';runId=$runB;
        backgroundRequestId=$requestB;modelId='model-a';endpoint='http://127.0.0.1:8080/v1';
        canary=[pscustomobject]@{passed=$true};processIdentity=$hostIdentity}
    $foreign = Get-FastLlmBackgroundHostStatus -InstallRoot $scratch -SourceRoot $source
    Assert-BackgroundTest ($foreign.occupied -and -not $foreign.active -and -not $foreign.attachable -and
        $foreign.phase -ceq 'occupied-unverified') 'A replacement foreground run was misidentified as background owned.'
    $rejected = $false
    try { Stop-FastLlmBackgroundHost -InstallRoot $scratch -SourceRoot $source -ExpectedRequestId $requestA -ExpectedRunId $runA | Out-Null }
    catch { $rejected = $true }
    Assert-BackgroundTest $rejected 'A replacement run was stopped through stale background metadata.'
    Assert-BackgroundTest (-not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $ownerPath) ('stop-' + $runA)))) 'An old run stop marker was created.'
    Assert-BackgroundTest (-not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $ownerPath) ('stop-' + $runB)))) 'A replacement run stop marker was created.'
    $script:mockStatus = [pscustomobject]@{active=$true;phase='ready';runId=$runA;
        backgroundRequestId=$requestA;modelId='model-a';endpoint='http://127.0.0.1:8080/v1';
        canary=[pscustomobject]@{passed=$true};processIdentity=$hostIdentity}
    $stop = Stop-FastLlmBackgroundHost -InstallRoot $scratch -SourceRoot $source -ExpectedRequestId $requestA -ExpectedRunId $runA
    Assert-BackgroundTest ($stop.stopRequested -and (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $ownerPath) ('stop-' + $runA)))) 'Exact run-scoped stop was not sent.'
    $owner.phase = 'stopped'
    Write-FastLlmBackgroundDocument -Path $ownerPath -Value $owner
    $stopped = Get-FastLlmBackgroundHostStatus -InstallRoot $scratch -SourceRoot $source
    Assert-BackgroundTest (-not $stopped.attachable -and -not $stopped.active) 'Stopped owner remained attachable.'

    # A fresh process must read the request before any FastLlm module import.
    $bootstrapId = 'cccccccccccccccccccccccccccccccc'
    $requestPath = Get-FastLlmBackgroundPath -InstallRoot $scratch -Leaf ('background-request-' + $bootstrapId + '.json')
    Write-FastLlmBackgroundDocument -Path $requestPath -Value ([ordered]@{requestId=$bootstrapId}) -CreateNew
    $sourceLiteral = (Join-Path $source 'src/FastLlm.BackgroundHost.ps1').Replace("'","''")
    $requestLiteral = $requestPath.Replace("'","''")
    $childCommand = "`$ProgressPreference='SilentlyContinue'; . '$sourceLiteral'; `$doc=Read-FastLlmBackgroundDocument -Path '$requestLiteral'; if(`$doc.requestId -cne '$bootstrapId'){exit 2}; 'bootstrap-ok'"
    $info = New-Object Diagnostics.ProcessStartInfo
    $currentExecutable = [Diagnostics.Process]::GetCurrentProcess()
    try { $info.FileName = $currentExecutable.MainModule.FileName }
    finally { $currentExecutable.Dispose() }
    $info.Arguments = '-NoLogo -NoProfile -NonInteractive -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCommand))
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $child = [Diagnostics.Process]::Start($info)
    try {
        if (-not $child.WaitForExit(10000)) { $child.Kill(); throw 'Fresh-child bootstrap exceeded deadline.' }
        $output = $child.StandardOutput.ReadToEnd()
        $errors = $child.StandardError.ReadToEnd()
        Assert-BackgroundTest ($child.ExitCode -eq 0 -and $output -match 'bootstrap-ok' -and -not $errors) ('Fresh-child request bootstrap failed before module import. exit=' + $child.ExitCode + ' stdout=[' + $output + '] stderr=[' + $errors + ']')
    } finally { $child.Dispose() }

    # Exercise the worker with disposable stand-ins: no acquisition method is
    # available, and the worker must release its operation handle on success.
    function Assert-FastLlmBackgroundNativeHost {}
    function Import-Module { param($Name,[switch]$Force) }
    function Get-FastLlmHardware { param($CatalogPath,$InstallRoot) $script:mockOrder.Add('hardware'); [pscustomobject]@{kind='mock'} }
    # M2: the order of lock, first status write and first probe is recorded; the status writes themselves are kept for inspection.
    $script:mockOrder = New-Object 'System.Collections.Generic.List[string]'
    $script:mockStateWrites = New-Object 'System.Collections.Generic.List[object]'
    function Write-FastLlmState { param($InstallRoot,$State,$FileName) $script:mockOrder.Add('status:' + [string]$State.phase); $script:mockStateWrites.Add($State) }
    function Get-FastLlmPlan {
        param($Hardware,$CatalogPath,$Profile,$InstallRoot,$ModelId,$ContextSize,$AllowExperimentalModel)
        if ($script:throwPlan) { $planFailure = New-Object System.InvalidOperationException('hip-device-not-found: no matching device'); $planFailure.Data['FastLlmFailureCode'] = 'hip-device-not-found'; throw $planFailure }
        [pscustomobject]@{model=[pscustomobject]@{id='test-model'}}
    }
    # The status the host would read back: the last document written (as the CLI-visible object, with the run id and action it was given).
    function Get-FastLlmStatus { param($InstallRoot) $last = $script:mockStateWrites[$script:mockStateWrites.Count - 1]; $copy = [pscustomobject]@{}; foreach ($key in $last.Keys) { $copy | Add-Member -NotePropertyName $key -NotePropertyValue $last[$key] }; $copy }
    function Enter-FastLlmOperation { param($InstallRoot) $script:mockOrder.Add('lock'); $script:mockOperation = New-Object IO.MemoryStream; $script:mockOperation }
    function Start-FastLlmServer {
        param($Plan,$CatalogPath,$InstallRoot,$LoadTimeoutSeconds,[string]$VulkanBarMitigation,[switch]$SelfTest)
        Assert-BackgroundTest ([bool]$SelfTest) 'Background worker did not request the post-load self-test.'
        Assert-BackgroundTest ($Plan.backgroundRequestId -ceq $script:workerRequestId) 'Worker lost exact request correlation.'
        $script:mockBarPolicy = $VulkanBarMitigation
        $script:mockServerStarts++
        if ($script:serverMovesStatus) { $script:mockStateWrites.Add([ordered]@{ schemaVersion = 1; runId = 'supervisor'; phase = 'failed'; failureCode = 'startup-or-runtime-check-failed' }) }
        if ($script:throwServer) { throw 'disposable test server failure' }
        if ($script:throwPlanChanged) { $changed = New-Object System.InvalidOperationException("The measured recipe 'r1' no longer applies at start.`r`nSecond line."); $changed.Data['FastLlmReason'] = 'PlanChanged'; throw $changed }
        return 0
    }
    function Install-FastLlmModel { throw 'Worker attempted acquisition.' }
    function Install-FastLlmEngines { throw 'Worker attempted engine installation.' }
    $workerRoot = Join-Path $scratch 'worker'
    New-Item -ItemType Directory -Path $workerRoot | Out-Null
    $script:workerRequestId = 'dddddddddddddddddddddddddddddddd'
    $script:mockServerStarts = 0
    $script:throwServer = $false
    $script:throwPlanChanged = $false
    $script:throwPlan = $false
    $script:serverMovesStatus = $false
    $workerRequestPath = Get-FastLlmBackgroundPath -InstallRoot $workerRoot -Leaf ('background-request-' + $script:workerRequestId + '.json')
    Write-FastLlmBackgroundDocument -Path $workerRequestPath -CreateNew -Value ([ordered]@{
        schemaVersion=1;kind='fastllm-private-background-request';requestId=$script:workerRequestId;
        sourceRoot=$source;installRoot=[IO.Path]::GetFullPath($workerRoot);profile='balanced';
        modelId='';contextSize=0;allowExperimentalModel=$false;loadTimeoutSeconds=30;vulkanBarMitigation='on';
        sourcePins=(Get-FastLlmBackgroundSourcePins -SourceRoot $source)})
    $workerExit = Invoke-FastLlmBackgroundServe -RequestId $script:workerRequestId -InstallRoot $workerRoot -SourceRoot $source
    Assert-BackgroundTest ($workerExit -eq 0 -and $script:mockServerStarts -eq 1 -and -not $script:mockOperation.CanRead) 'Worker failed to call supervisor exactly once or release operation lock.'
    Assert-BackgroundTest ($script:mockBarPolicy -ceq 'on') 'Worker did not pass the request vulkanBarMitigation to the start.'
    # M2: status.json says 'preparing' (the shape fast-llm.ps1 writes) right after the operation lock and before the first hardware probe.
    Assert-BackgroundTest (($script:mockOrder -join ',') -ceq 'lock,status:preparing,hardware') ('The background worker must write a preparing status right after taking the lock, before probing (observed: ' + ($script:mockOrder -join ',') + ').')
    $preparingState = $script:mockStateWrites[0]
    Assert-BackgroundTest ($preparingState.schemaVersion -eq 1 -and $preparingState.phase -ceq 'preparing' -and $preparingState.action -ceq 'start' -and [string]$preparingState.runId -cmatch '^[0-9a-f]{32}$' -and @($preparingState.Keys).Count -eq 4) 'The preparing status has the shape the CLI writes (schemaVersion, runId, phase, action).'
    $script:workerRequestId = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
    $workerRequestPath = Get-FastLlmBackgroundPath -InstallRoot $workerRoot -Leaf ('background-request-' + $script:workerRequestId + '.json')
    Write-FastLlmBackgroundDocument -Path $workerRequestPath -CreateNew -Value ([ordered]@{
        schemaVersion=1;kind='fastllm-private-background-request';requestId=$script:workerRequestId;
        sourceRoot=$source;installRoot=[IO.Path]::GetFullPath($workerRoot);profile='balanced';
        modelId='';contextSize=0;allowExperimentalModel=$false;loadTimeoutSeconds=30;
        sourcePins=(Get-FastLlmBackgroundSourcePins -SourceRoot $source)})
    $script:throwServer = $true
    $failed = $false
    $script:mockBarPolicy = $null
    try { Invoke-FastLlmBackgroundServe -RequestId $script:workerRequestId -InstallRoot $workerRoot -SourceRoot $source | Out-Null }
    catch { $failed = $_.Exception.Message -match 'disposable test server failure' }
    Assert-BackgroundTest ($failed -and -not $script:mockOperation.CanRead) 'Worker did not release operation lock after server failure.'
    Assert-BackgroundTest ($script:mockBarPolicy -ceq 'auto') 'A request without vulkanBarMitigation must default to auto.'
    $script:workerRequestId = 'ffffffffffffffffffffffffffffffff'
    $badPath = Get-FastLlmBackgroundPath -InstallRoot $workerRoot -Leaf ('background-request-' + $script:workerRequestId + '.json')
    Write-FastLlmBackgroundDocument -Path $badPath -CreateNew -Value ([ordered]@{
        schemaVersion=1;kind='fastllm-private-background-request';requestId=$script:workerRequestId;
        sourceRoot=$source;installRoot=[IO.Path]::GetFullPath($workerRoot);profile='balanced';
        modelId='';contextSize=0;allowExperimentalModel=$false;loadTimeoutSeconds=30;vulkanBarMitigation='AUTO';
        sourcePins=(Get-FastLlmBackgroundSourcePins -SourceRoot $source)})
    $script:mockServerStarts = 0
    $badRejected = $false
    try { Invoke-FastLlmBackgroundServe -RequestId $script:workerRequestId -InstallRoot $workerRoot -SourceRoot $source | Out-Null }
    catch { $badRejected = $_.Exception.Message -match 'vulkanBarMitigation is invalid' }
    Assert-BackgroundTest ($badRejected -and $script:mockServerStarts -eq 0) 'An invalid vulkanBarMitigation request value must be refused before any start.'
    $failedOwner = Read-FastLlmBackgroundDocument -Path (Get-FastLlmBackgroundPath -InstallRoot $workerRoot -Leaf 'background-host.json')
    Assert-BackgroundTest ($failedOwner.phase -ceq 'failed' -and $failedOwner.failureCode -ceq 'background-start-or-runtime-failed') 'Worker did not retain bounded failure state.'
    Assert-BackgroundTest ($failedOwner.failureReason -eq $null -or [string]$failedOwner.failureReason -eq '') 'An ordinary failure must not persist its message.'
    # A PlanChanged failure keeps its reason (final review N2), single line and bounded.
    $script:workerRequestId = 'abababababababababababababababab'
    $changedPath = Get-FastLlmBackgroundPath -InstallRoot $workerRoot -Leaf ('background-request-' + $script:workerRequestId + '.json')
    Write-FastLlmBackgroundDocument -Path $changedPath -CreateNew -Value ([ordered]@{
        schemaVersion=1;kind='fastllm-private-background-request';requestId=$script:workerRequestId;
        sourceRoot=$source;installRoot=[IO.Path]::GetFullPath($workerRoot);profile='balanced';
        modelId='';contextSize=0;allowExperimentalModel=$false;loadTimeoutSeconds=30;
        sourcePins=(Get-FastLlmBackgroundSourcePins -SourceRoot $source)})
    $script:throwServer = $false
    $script:throwPlanChanged = $true
    try { Invoke-FastLlmBackgroundServe -RequestId $script:workerRequestId -InstallRoot $workerRoot -SourceRoot $source | Out-Null } catch { }
    $script:throwPlanChanged = $false
    $changedOwner = Read-FastLlmBackgroundDocument -Path (Get-FastLlmBackgroundPath -InstallRoot $workerRoot -Leaf 'background-host.json')
    Assert-BackgroundTest ($changedOwner.failureCode -ceq 'PlanChanged' -and [string]$changedOwner.failureReason -like "The measured recipe 'r1' no longer applies*" -and [string]$changedOwner.failureReason -notmatch "[\x00-\x1f]") 'A PlanChanged failure must persist its single-line reason.'
    # A failure before the supervisor runs: the 'preparing' status becomes failed with the typed code (the shape fast-llm.ps1 writes).
    $script:workerRequestId = 'bcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbc'
    Write-FastLlmBackgroundDocument -Path (Get-FastLlmBackgroundPath -InstallRoot $workerRoot -Leaf ('background-request-' + $script:workerRequestId + '.json')) -CreateNew -Value ([ordered]@{
        schemaVersion=1;kind='fastllm-private-background-request';requestId=$script:workerRequestId;
        sourceRoot=$source;installRoot=[IO.Path]::GetFullPath($workerRoot);profile='balanced';
        modelId='';contextSize=0;allowExperimentalModel=$false;loadTimeoutSeconds=30;
        sourcePins=(Get-FastLlmBackgroundSourcePins -SourceRoot $source)})
    $script:mockStateWrites.Clear(); $script:mockServerStarts = 0; $script:throwServer = $false; $script:throwPlan = $true
    try { Invoke-FastLlmBackgroundServe -RequestId $script:workerRequestId -InstallRoot $workerRoot -SourceRoot $source | Out-Null } catch { }
    $script:throwPlan = $false
    $failedStatus = $script:mockStateWrites[$script:mockStateWrites.Count - 1]
    Assert-BackgroundTest ($script:mockServerStarts -eq 0 -and $script:mockStateWrites.Count -eq 2 -and $failedStatus.phase -ceq 'failed' -and $failedStatus.failureCode -ceq 'hip-device-not-found' -and $failedStatus.runId -ceq $script:mockStateWrites[0].runId -and $failedStatus.action -ceq 'start') 'A background failure before the supervisor must rewrite the preparing status to failed with the typed failure code.'
    # A supervisor that already moved the status on is not overwritten.
    $script:workerRequestId = 'cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd'
    Write-FastLlmBackgroundDocument -Path (Get-FastLlmBackgroundPath -InstallRoot $workerRoot -Leaf ('background-request-' + $script:workerRequestId + '.json')) -CreateNew -Value ([ordered]@{
        schemaVersion=1;kind='fastllm-private-background-request';requestId=$script:workerRequestId;
        sourceRoot=$source;installRoot=[IO.Path]::GetFullPath($workerRoot);profile='balanced';
        modelId='';contextSize=0;allowExperimentalModel=$false;loadTimeoutSeconds=30;
        sourcePins=(Get-FastLlmBackgroundSourcePins -SourceRoot $source)})
    $script:mockStateWrites.Clear(); $script:throwServer = $true; $script:serverMovesStatus = $true
    try { Invoke-FastLlmBackgroundServe -RequestId $script:workerRequestId -InstallRoot $workerRoot -SourceRoot $source | Out-Null } catch { }
    $script:throwServer = $false; $script:serverMovesStatus = $false
    Assert-BackgroundTest ($script:mockStateWrites.Count -eq 2 -and $script:mockStateWrites[1].runId -ceq 'supervisor') 'A failure after the supervisor moved the status on must not rewrite it.'
    # Regression: Windows PowerShell 5.1 turns a plain $null into "" for File.Replace's backup argument ("path is not of a legal form").
    $replaceDoc = Join-Path $scratch 'replace-regression.json'
    Write-FastLlmBackgroundDocument -Path $replaceDoc -Value ([ordered]@{generation=1})
    Write-FastLlmBackgroundDocument -Path $replaceDoc -Value ([ordered]@{generation=2})
    Assert-BackgroundTest ((Read-FastLlmBackgroundDocument -Path $replaceDoc).generation -eq 2) 'Atomic background document replace did not publish the new content.'
    Assert-BackgroundTest (@(Get-ChildItem -LiteralPath $scratch -Filter '*.background.tmp' -Force).Count -eq 0 -and
        @(Get-ChildItem -LiteralPath $scratch -Filter 'replace-regression*' -Force).Count -eq 1) 'Atomic replace left a temp or backup file.'
    $hostSource = Get-Content -LiteralPath (Join-Path $source 'src/FastLlm.BackgroundHost.ps1') -Raw
    $replaceSource = Get-Content -LiteralPath (Join-Path $source 'src/FastLlm.FileReplace.ps1') -Raw
    Assert-BackgroundTest ($hostSource.Contains('vulkanBarMitigation=$VulkanBarMitigation.ToLowerInvariant()') -and $hostSource.Contains("[ValidateSet('off','on','auto')][string]`$VulkanBarMitigation='auto'")) 'The background request records vulkanBarMitigation with a default of auto.'
    Assert-BackgroundTest ($replaceSource.Contains('[IO.File]::Replace($Source,$Destination,[NullString]::Value)') -and
        -not ($replaceSource -match '\[IO\.File\]::Replace\([^)]*\$null') -and
        $hostSource.Contains('Move-FastLlmFileReplacing -Source $temp -Destination $Path') -and
        -not ($hostSource -match '\[IO\.File\]::Replace')) 'File.Replace backup argument must be [NullString]::Value, not $null (5.1 marshals $null to an empty path), and the background writer must use the shared helper.'
    if ($env:OS -ceq 'Windows_NT') {
        $a = Join-Path $scratch 'nullstring-a.txt'; $b = Join-Path $scratch 'nullstring-b.txt'
        Set-Content -LiteralPath $a -Value 'new'; Set-Content -LiteralPath $b -Value 'old'
        [IO.File]::Replace($a,$b,[NullString]::Value)
        Assert-BackgroundTest ((Get-Content -LiteralPath $b -Raw).Trim() -ceq 'new' -and -not (Test-Path -LiteralPath $a)) 'Native File.Replace with a true null backup did not replace atomically.'
    }
    # Reader/writer hardening: bounded reads, transient verdicts, concurrent replace, keep-temp and the stale sweep.
    $hardenDir = Join-Path $scratch 'harden'
    New-Item -ItemType Directory -Path $hardenDir | Out-Null
    $validDoc = Join-Path $hardenDir 'valid.json'
    [IO.File]::WriteAllBytes($validDoc,[Text.Encoding]::ASCII.GetBytes('{"p":"abc"}'))
    $script:giBox = $null
    function Get-Item {
        [CmdletBinding()]
        param([Parameter(Position=0)][string]$LiteralPath,[switch]$Force)
        $box = $script:giBox
        if ($null -ne $box -and $LiteralPath -like $box.pattern) {
            $box.calls++
            if ($box.calls -le $box.count) { return [pscustomobject]@{ Attributes=[int]$box.attributes; Length=1L; PSIsContainer=$false } }
        }
        Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath -Force:$Force -ErrorAction Stop
    }
    try {
        $script:giBox = @{pattern='*valid.json';attributes=-1;count=3;calls=0}
        $doc = Read-FastLlmBackgroundDocument -Path $validDoc
        Assert-BackgroundTest ($doc -and $doc.p -ceq 'abc' -and $script:giBox.calls -eq 4) 'Background reader did not retry Attributes -1 and then read the real document.'
        $script:giBox = @{pattern='*valid.json';attributes=-1;count=1000;calls=0}
        $doc = Read-FastLlmBackgroundDocument -Path $validDoc
        Assert-BackgroundTest ($null -eq $doc -and $script:giBox.calls -eq 10) 'A persistent Attributes -1 must read as a missing document after the bounded retry.'
        $script:giBox = @{pattern='*valid.json';attributes=1024;count=1000;calls=0}
        $unsafe = $null
        try { Read-FastLlmBackgroundDocument -Path $validDoc | Out-Null } catch { $unsafe = $_.Exception.Message }
        Assert-BackgroundTest ($unsafe -ceq 'Unsafe background state document.' -and $script:giBox.calls -eq 1) 'A real reparse point must be unsafe at once, without the retry.'
        # Size cap: exactly 16384 bytes reads; 16385 is unsafe at once.
        $atCap = Join-Path $hardenDir 'at-cap.json'; $overCap = Join-Path $hardenDir 'over-cap.json'
        [IO.File]::WriteAllBytes($atCap,[Text.Encoding]::ASCII.GetBytes('{"p":"' + ('a' * 16376) + '"}'))
        [IO.File]::WriteAllBytes($overCap,[Text.Encoding]::ASCII.GetBytes('{"p":"' + ('a' * 16377) + '"}'))
        Assert-BackgroundTest ((Get-Item -LiteralPath $atCap).Length -eq 16384 -and (Get-Item -LiteralPath $overCap).Length -eq 16385) 'Cap fixtures have the wrong sizes.'
        $script:giBox = @{pattern='*cap.json';attributes=0;count=0;calls=0}
        Assert-BackgroundTest ((Read-FastLlmBackgroundDocument -Path $atCap).p.Length -eq 16376) 'A document exactly at the cap was not read.'
        $script:giBox = @{pattern='*over-cap.json';attributes=0;count=0;calls=0}
        $unsafe = $null
        try { Read-FastLlmBackgroundDocument -Path $overCap | Out-Null } catch { $unsafe = $_.Exception.Message }
        Assert-BackgroundTest ($unsafe -ceq 'Unsafe background state document.' -and $script:giBox.calls -eq 1) 'A document one byte over the cap must be unsafe at once, without the retry.'
        if ($env:OS -ceq 'Windows_NT') {
            # Assert-FastLlmBackgroundPrivateState tolerates a transient Attributes -1 while status.json is replaced (bounded retry).
            $privRoot = Join-Path $scratch 'private-state-root'
            $privState = Split-Path -Parent (Get-FastLlmBackgroundPath -InstallRoot $privRoot -Leaf 'background-host.json')
            New-Item -ItemType Directory -Path $privState -Force | Out-Null
            [IO.File]::WriteAllBytes((Join-Path $privState 'status.json'),[Text.Encoding]::ASCII.GetBytes('{"p":"abc"}'))
            $script:giBox = $null
            $baseline = $true
            try { & $privateStateCheck -InstallRoot $privRoot } catch { $baseline = $false }
            Assert-BackgroundTest $baseline 'The private-state check must pass for a fresh owned state folder (baseline).'
            $script:giBox = @{pattern='*status.json';attributes=-1;count=3;calls=0}
            $transientOk = $true
            try { & $privateStateCheck -InstallRoot $privRoot } catch { $transientOk = $false }
            Assert-BackgroundTest ($transientOk -and $script:giBox.calls -eq 4) 'The private-state check must retry a transient Attributes -1 and then pass.'
            $script:giBox = @{pattern='*status.json';attributes=-1;count=1000;calls=0}
            $persistentOk = $true
            try { & $privateStateCheck -InstallRoot $privRoot } catch { $persistentOk = $false }
            Assert-BackgroundTest ($persistentOk -and $script:giBox.calls -eq 10) 'A persistent Attributes -1 must read as missing after the bounded retry, not throw.'
            $script:giBox = @{pattern='*status.json';attributes=1024;count=1000;calls=0}
            $unsafeState = $null
            try { & $privateStateCheck -InstallRoot $privRoot } catch { $unsafeState = $_.Exception.Message }
            Assert-BackgroundTest ($unsafeState -ceq 'Unsafe background state path.' -and $script:giBox.calls -eq 1) 'A real reparse point must be unsafe at once, without the retry.'
        }
    } finally {
        $script:giBox = $null
        Remove-Item -Path Function:\Get-Item -ErrorAction SilentlyContinue
    }
    if ($env:OS -ceq 'Windows_NT') {
        # Behavioural: the reader against another process replacing the same document 200 times.
        $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $racePath = Join-Path $hardenDir 'race.json'
        $raceDone = Join-Path $hardenDir 'race.done'
        $raceScript = Join-Path $hardenDir 'race-writer.ps1'
        Write-FastLlmBackgroundDocument -Path $racePath -Value ([ordered]@{generation=0})
        Set-Content -LiteralPath $raceScript -Encoding ASCII -Value @'
param([string]$Source,[string]$Doc,[string]$Done)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
try {
    . (Join-Path $Source 'src/FastLlm.BackgroundHost.ps1')
    for ($i = 1; $i -le 200; $i++) { Write-FastLlmBackgroundDocument -Path $Doc -Value ([ordered]@{generation=$i}) }
    Set-Content -LiteralPath $Done -Value 'ok'
} catch { Set-Content -LiteralPath $Done -Value ('error: ' + $_.Exception.Message) }
'@
        $raceWriter = Start-Process -FilePath $ps -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$raceScript,$source,$racePath,$raceDone) -PassThru -WindowStyle Hidden
        $raceClock = [Diagnostics.Stopwatch]::StartNew(); $raceReads = 0; $raceError = $null; $lastGeneration = 0
        while (-not (Test-Path -LiteralPath $raceDone) -and $raceClock.Elapsed.TotalSeconds -lt 40) {
            try {
                $raceDoc = Read-FastLlmBackgroundDocument -Path $racePath
                if ($null -eq $raceDoc) { throw 'document read as missing during a replace' }
                if ([int]$raceDoc.generation -lt $lastGeneration) { throw "generation went backwards $lastGeneration -> $($raceDoc.generation)" }
                $lastGeneration = [int]$raceDoc.generation; $raceReads++
            } catch { $raceError = $_.Exception.Message; break }
        }
        [void]$raceWriter.WaitForExit(10000)
        $raceResult = if (Test-Path -LiteralPath $raceDone) { (Get-Content -LiteralPath $raceDone -Raw).Trim() } else { 'timeout' }
        Assert-BackgroundTest ($null -eq $raceError -and $raceReads -gt 0) ("Background reader failed under concurrent replace after $raceReads reads: $raceError")
        Assert-BackgroundTest ($raceResult -ceq 'ok' -and (Read-FastLlmBackgroundDocument -Path $racePath).generation -eq 200) "Background writer process did not finish 200 replaces: $raceResult"
        Write-Host "PASS: background reader saw no exception over $raceReads reads while another process replaced the document 200 times"
        # Keep-temp on a failed replace and the stale-temp sweep after the next successful write.
        $keepPath = Join-Path $hardenDir 'keep.json'
        Write-FastLlmBackgroundDocument -Path $keepPath -Value ([ordered]@{generation=1})
        $script:FastLlmFileReplaceInvoker = { param($s,$d) throw (New-Object IO.IOException('simulated sharing violation',-2147024864)) }
        $failedReplace = $null
        try { Write-FastLlmBackgroundDocument -Path $keepPath -Value ([ordered]@{generation=2}) } catch { $failedReplace = $_.Exception.Message } finally { $script:FastLlmFileReplaceInvoker = $null }
        $keptTemps = @(Get-ChildItem -LiteralPath $hardenDir -Filter '*.background.tmp' -Force)
        Assert-BackgroundTest ($failedReplace -and $failedReplace.StartsWith('state-replace-failed: keep.json') -and $keptTemps.Count -eq 1 -and (Read-FastLlmBackgroundDocument -Path $keepPath).generation -eq 1) 'A failed background replace must keep its temp and leave the destination untouched.'
        [IO.File]::SetLastWriteTimeUtc($keptTemps[0].FullName,[DateTime]::UtcNow.AddMinutes(-11))
        $freshTemp = Join-Path $hardenDir ([Guid]::NewGuid().ToString('N') + '.background.tmp'); Set-Content -LiteralPath $freshTemp -Value 'x'
        $foreignTemp = Join-Path $hardenDir 'foreign.background.tmp'; Set-Content -LiteralPath $foreignTemp -Value 'x'; [IO.File]::SetLastWriteTimeUtc($foreignTemp,[DateTime]::UtcNow.AddMinutes(-30))
        Write-FastLlmBackgroundDocument -Path $keepPath -Value ([ordered]@{generation=3})
        Assert-BackgroundTest ((Read-FastLlmBackgroundDocument -Path $keepPath).generation -eq 3 -and -not (Test-Path -LiteralPath $keptTemps[0].FullName) -and
            (Test-Path -LiteralPath $freshTemp) -and (Test-Path -LiteralPath $foreignTemp)) 'The next successful background write must sweep only stale GUID temps (fresh and foreign names are kept).'
        Write-Host 'PASS: background keep-temp and stale sweep'
    }
    'Background host identity/stop tests passed.'
} finally {
    if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}
