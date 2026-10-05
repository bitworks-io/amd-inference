#requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$source=Join-Path $root 'src/FastLlm.OffloadBenchmark.ps1'
$tokens=$null;$errors=$null
$null=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw ('Offload benchmark parser errors: '+(@($errors | ForEach-Object Message) -join ' | '))}
Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force
$module=Get-Module FastLlm
$count=0
function Check($condition,$message){if(-not $condition){throw $message};$script:count++}
function Reject($action,$message){$threw=$false;try{& $action | Out-Null}catch{$threw=$true};Check $threw $message}
function RejectMatch($action,$pattern,$message){$matched=$false;try{& $action | Out-Null}catch{$matched=$_.Exception.Message -match $pattern};Check $matched $message}
$state=[pscustomobject]@{
    active=$true;schemaVersion=1;kind='fastllm-offload-lab-run';phase='lab-ready';endpoint='http://127.0.0.1:18080/v1';experimental=$true
    runId=('a'*32);processIdentity=[pscustomobject]@{pid=12345;startUtcTicks=10000000}
    modelId='mock-qwen';modelSha256=('b'*64);engineVersion='b10698';engineSha256=('c'*64);catalogSha256=('d'*64)
    requestedContextSize=1024
    recipe=[pscustomobject]@{backend='Vulkan';fitMode='off';device='Vulkan0';gpuLayers=20;contextSize=1024;slots=1;splitMode='none';speculation='none';
        engineSha256=('c'*64);catalogSha256=('d'*64);cacheTypeK='f16';cacheTypeV='f16';
        selectedAdapters=@([pscustomobject]@{device='Vulkan0';name='AMD mock';reportedTotalVramMiB=20480});
        requestedArguments=@('--model','<verified-model>','--alias','mock-qwen','--host','127.0.0.1','--port','18080','--ctx-size','1024','--parallel','1',
            '--device','Vulkan0','--n-gpu-layers','20','--fit','off','--split-mode','none','--cache-type-k','f16','--cache-type-v','f16')}
    placement=[pscustomobject]@{requestedGpuLayers=20;reportedGpuLayers=20;reportedTotalLayers=66;selectedDevice='Vulkan0';
        gpuModelBufferMiB=1024;cpuModelBufferMiB=$null;physicalResidencyVerified=$false;performanceQualified=$false}
    canary=[pscustomobject]@{modelIdentity=$true;repeatableToken=$true;synchronousChat=$true;streaming=$true;effectiveContext=1024;semanticCorrectnessQualified=$false}
    performanceQualified=$false;physicalResidencyVerified=$false
}
$script:fakeState=$state
$script:requests=0
$readState={return $script:fakeState}
$checkProcess={param($s) if($s.processIdentity.pid -ne 12345){throw 'PID changed'}}
$request={
    param($path,$body,$timeoutMs)
    $script:requests++
    if($timeoutMs -le 0 -or $timeoutMs -gt 300000){throw 'Invalid bounded request timeout.'}
    if($path -eq '/tokenize'){
        return [pscustomobject]@{Status=200;Body=(@{tokens=@(0..512)}|ConvertTo-Json -Compress -Depth 4)}
    }
    if($path -ne '/completion' -or $body.prompt.Count -ne 16 -or $body.n_predict -ne 4 -or $body.cache_prompt){throw 'Unexpected workload.'}
    return [pscustomobject]@{
        Status=200;Events=@('{"content":"first"}','{"stop":true,"timings":{"prompt_n":16,"prompt_ms":100,"predicted_n":4,"predicted_ms":200}}','[DONE]')
        EventTimesMs=@(10,250,250);ElapsedMs=250
    }
}
$tempParent=if($env:OS -eq 'Windows_NT'){[IO.Path]::GetTempPath()}elseif(Test-Path -LiteralPath '/private/tmp' -PathType Container){'/private/tmp'}else{[IO.Path]::GetTempPath()}
$temp=Join-Path $tempParent ('fast-llm-offload-benchmark-'+[Guid]::NewGuid().ToString('N'))
try{
    $output=Join-Path $temp 'result.json'
    $result=& $module {param($S,$O,$R,$Q,$P) . $S; Invoke-FastLlmOffloadBenchmarkCore -OutputPath $O -PromptTokens @(16) -GenerationTokens 4 -Repetitions 5 -ReadState $R -Request $Q -CheckProcess $P} $source $output $readState $request $checkProcess
    Check ($result.resultKind -eq 'native-windows-api-offload-lab-experiment' -and $result.qualification.approved -eq $false) 'Distinct unqualified report kind missing.'
    Check ($result.samples.Count -eq 5 -and $script:requests -eq 7) 'Warmup/repetition count is wrong.'
    Check (@($result.samples | Select-Object -ExpandProperty promptArtifactSha256 -Unique).Count -eq 1 -and $result.samples[0].promptArtifactSha256 -eq $result.methodology.promptArtifacts[0].sha256) 'Prompt identity digest not bound to all samples.'
    Check ($result.summary[0].generation.median -eq 20 -and $result.summary[0].prefill.median -eq 160 -and $result.summary[0].requestedPromptTokens -eq 16) 'Canonical response/statistics helpers not applied.'
    Check ($result.sourceProvenance.canonicalHelperSha256 -eq (Get-FileHash (Join-Path $root 'src/FastLlm.Benchmark.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()) 'Canonical helper source hash absent.'
    $saved=Get-Content -LiteralPath $output -Raw
    Check ($saved -notmatch 'accurate useful answers|"first"|private/untrusted' -and $saved -match 'native-windows-api-offload-lab-experiment') 'Report leaked request/response text or lost experiment label.'
    Reject {& $module {param($S,$O,$R,$Q,$P) . $S; Invoke-FastLlmOffloadBenchmarkCore -OutputPath $O -PromptTokens @(16) -GenerationTokens 4 -Repetitions 5 -ReadState $R -Request $Q -CheckProcess $P} $source $output $readState $request $checkProcess} 'Output overwrite was accepted.'
    $script:fakeState.phase='ready'
    Reject {& $module {param($S,$O,$R,$Q,$P) . $S; Invoke-FastLlmOffloadBenchmarkCore -OutputPath $O -PromptTokens @(16) -GenerationTokens 4 -Repetitions 5 -ReadState $R -Request $Q -CheckProcess $P} $source (Join-Path $temp 'normal.json') $readState $request $checkProcess} 'Normal ready state entered lab report.'
    $script:fakeState.phase='lab-ready'
    $script:fakeState.placement.reportedGpuLayers=19
    Reject {& $module {param($S,$O,$R,$Q,$P) . $S; Invoke-FastLlmOffloadBenchmarkCore -OutputPath $O -PromptTokens @(16) -GenerationTokens 4 -Repetitions 5 -ReadState $R -Request $Q -CheckProcess $P} $source (Join-Path $temp 'partial.json') $readState $request $checkProcess} 'Mismatched requested/reported layers entered report.'
    $script:fakeState.placement.reportedGpuLayers=20
    $script:mutatingCalls=0
    $mutatingRequest={
        param($path,$body,$timeoutMs)
        $script:mutatingCalls++
        if($script:mutatingCalls -eq 2){$script:fakeState.processIdentity.pid=99999}
        & $request $path $body $timeoutMs
    }
    Reject {& $module {param($S,$O,$R,$Q,$P) . $S; Invoke-FastLlmOffloadBenchmarkCore -OutputPath $O -PromptTokens @(16) -GenerationTokens 4 -Repetitions 5 -ReadState $R -Request $Q -CheckProcess $P} $source (Join-Path $temp 'changed-process.json') $readState $mutatingRequest $checkProcess} 'Changed process identity was accepted mid-request.'
    Check (-not (Test-Path -LiteralPath (Join-Path $temp 'changed-process.json'))) 'Changed-run failure wrote a report.'
    $script:fakeState.processIdentity.pid=12345
    $script:alternatingCalls=0
    $alternatingRequest={
        param($path,$body,$timeoutMs)
        $answer=& $request $path $body $timeoutMs
        if($path -eq '/completion'){
            $script:alternatingCalls++
            if($script:alternatingCalls % 2 -eq 0){$answer.Events[1]=$answer.Events[1].Replace('"prompt_n":16','"prompt_n":17')}
        }
        return $answer
    }
    Reject {& $module {param($S,$O,$R,$Q,$P) . $S; Invoke-FastLlmOffloadBenchmarkCore -OutputPath $O -PromptTokens @(16) -GenerationTokens 4 -Repetitions 5 -ReadState $R -Request $Q -CheckProcess $P} $source (Join-Path $temp 'mixed-count.json') $readState $alternatingRequest $checkProcess} 'Mixed N/N+1 evaluated prompt counts in one group passed.'
    Check (-not (Test-Path -LiteralPath (Join-Path $temp 'mixed-count.json'))) 'Mixed-count failure wrote a report.'
    $fractional=& $request '/completion' @{prompt=@(0..15);n_predict=4;cache_prompt=$false} 1000
    $fractional.Events[1]=$fractional.Events[1].Replace('"prompt_n":16','"prompt_n":16.5')
    Reject {& $module {param($S,$R) . $S; ConvertFrom-FastLlmOffloadBenchmarkResponse -Response $R -ExpectedTokens 4} $source $fractional} 'Fractional evaluated token count passed.'
    $fractional.Events[1]=$fractional.Events[1].Replace('"prompt_n":16.5','"prompt_n":16').Replace('"predicted_n":4','"predicted_n":4.5')
    Reject {& $module {param($S,$R) . $S; ConvertFrom-FastLlmOffloadBenchmarkResponse -Response $R -ExpectedTokens 4} $source $fractional} 'Fractional generated token count passed.'
    $fractional.Events[1]=$fractional.Events[1].Replace('"predicted_n":4.5','"predicted_n":4').Replace('"stop":true','"stop":"false"')
    Reject {& $module {param($S,$R) . $S; ConvertFrom-FastLlmOffloadBenchmarkResponse -Response $R -ExpectedTokens 4} $source $fractional} 'String stop flag passed offload parser.'
    $script:fakeState.canary.effectiveContext=512
    Reject {& $module {param($S,$O,$R,$Q,$P) . $S; Invoke-FastLlmOffloadBenchmarkCore -OutputPath $O -PromptTokens @(16) -GenerationTokens 4 -Repetitions 5 -ReadState $R -Request $Q -CheckProcess $P} $source (Join-Path $temp 'bad-context.json') $readState $request $checkProcess} 'Inconsistent canary context passed.'
    $script:fakeState.canary.effectiveContext=1024
    Reject {& $module {param($S,$O,$R,$Q,$P) . $S; Invoke-FastLlmOffloadBenchmarkCore -OutputPath $O -PromptTokens @(16,16) -GenerationTokens 4 -Repetitions 5 -ReadState $R -Request $Q -CheckProcess $P} $source (Join-Path $temp 'duplicate.json') $readState $request $checkProcess} 'Duplicate prompt groups passed.'
    $before=Get-Content -LiteralPath $source -Raw
    Check ($before.Contains("'http://127.0.0.1:18080'") -and $before.Contains('Assert-FastLlmOffloadLabHost') -and -not $before.Contains('Invoke-FastLlmBenchmark -')) 'Live entry boundary is missing or calls normal producer.'
    Check ($before.Contains('GetLoopbackListenerOwners(18080)') -and $before.Contains('MainModule.FileName') -and $before.Contains('WindowsGpuTelemetry.cs')) 'Native listener/executable binding is absent.'
    Check ($result.sourceProvenance.canonicalHelperSha256 -eq (Get-FileHash (Join-Path $root 'src/FastLlm.Benchmark.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()) 'Offload report binds the current canonical helper source without pinning an old producer revision.'
    if($env:OS -eq 'Windows_NT'){
        # Real owner-PID check only; this disposable PowerShell listener is never a
        # successful benchmark target and is never sent inference requests.
        $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,18080)
        $listener.Server.ExclusiveAddressUse=$true
        $bound=$false
        try{
            try{$listener.Start();$bound=$true}
            catch {
                $cause=$_.Exception
                while($cause.InnerException){$cause=$cause.InnerException}
                if($cause -isnot [Net.Sockets.SocketException] -or
                   $cause.SocketErrorCode -ne [Net.Sockets.SocketError]::AddressAlreadyInUse){throw}
                Write-Host 'SKIP native loopback owner check: port 18080 is already in use.'
            }
            if($bound){
                & $module {param($S) . $S; Initialize-FastLlmOffloadBenchmarkTcp} $source
                $owners=@()
                for($i=0;$i -lt 20;$i++){
                    $owners=@([Bitworks.FastLlm.WindowsGpuTelemetry]::GetLoopbackListenerOwners(18080))
                    if($owners.Count -eq 1 -and $owners[0] -eq $PID){break}
                    Start-Sleep -Milliseconds 100
                }
                Check ($owners.Count -eq 1 -and $owners[0] -eq $PID) 'Native TCP owner table did not bind the disposable listener to this process.'
                $self=[Diagnostics.Process]::GetCurrentProcess()
                try{
                    $script:fakeState.processIdentity.pid=$PID+1
                    $script:fakeState.processIdentity.startUtcTicks=$self.StartTime.ToUniversalTime().Ticks
                    RejectMatch {& $module {param($S,$T) . $S; Assert-FastLlmOffloadBenchmarkProcess -State $T} $source $script:fakeState} 'Loopback listener owner differs' 'Wrong recorded PID was accepted for the native listener.'
                    $script:fakeState.processIdentity.pid=$PID
                    Check ($self.ProcessName -cne 'llama-server') 'Disposable listener unexpectedly uses the serving engine name.'
                    RejectMatch {& $module {param($S,$T) . $S; Assert-FastLlmOffloadBenchmarkProcess -State $T} $source $script:fakeState} 'child process identity is unavailable or changed' 'Non-llama PowerShell listener was accepted as a serving child.'
                }finally{$self.Dispose();$script:fakeState.processIdentity.pid=12345;$script:fakeState.processIdentity.startUtcTicks=10000000}
            }
        }finally{if($bound){$listener.Stop()}}
    }else{Write-Host 'SKIP native loopback owner check: Windows-only.'}
}finally{
    if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}
}
Write-Host "$count offload benchmark focused assertions passed. Native Windows measurements remain unqualified."
