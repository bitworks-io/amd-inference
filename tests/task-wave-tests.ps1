#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force -PassThru
& $module {Initialize-FastLlmProcessHost}
. (Join-Path $root 'src/FastLlm.Benchmark.ps1')
. (Join-Path $root 'tools/concurrency-benchmark.ps1') -OutputPath (Join-Path $PSScriptRoot 'unused-task-wave-report.json')
$count=0
function Check([bool]$Condition,[string]$Message){
    if(-not $Condition){throw $Message}
    $script:count++
    Write-Host "PASS: $Message"
}
function Assert-WaveTiming($Wave,[int]$Clients){
    Assert-ConcurrencyWaveShape $Wave $Clients
    $last=[double](@($Wave.requests)|Measure-Object finishedMs -Maximum).Maximum
    Check ([Math]::Abs(($last-[double]$Wave.releasedMs)-[double]$Wave.wallMs) -lt 0.1 -and
        [double]$Wave.collectorElapsedMs -ge [double]$Wave.wallMs) 'common wall is last HTTP completion minus barrier release'
    foreach($request in @($Wave.requests)){
        Check ([double]$request.startedMs -ge [double]$Wave.releasedMs -and
            [double]$request.finishedMs -ge [double]$request.startedMs) 'request interval begins after common release'
    }
}

$scratch=Join-Path ([IO.Path]::GetTempPath()) ('fastllm-task-wave-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($scratch)
$listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
$listener.Start()
$port=([Net.IPEndPoint]$listener.LocalEndpoint).Port
$listener.Stop()
$mock=Join-Path $PSScriptRoot 'helpers/mock-task-wave-server.ps1'
$log=Join-Path $scratch 'requests.txt'
$accepted=Join-Path $scratch 'accepted.txt'
$stdout=Join-Path $scratch 'mock.stdout.txt'
$stderr=Join-Path $scratch 'mock.stderr.txt'
$process=$null
try {
    $exe=(Get-Process -Id $PID).Path
    $process=Start-Process -FilePath $exe -ArgumentList @('-NoProfile','-NonInteractive','-File',('"'+$mock+'"'),'-Port',$port,
        '-LogPath',('"'+$log+'"'),'-AcceptPath',('"'+$accepted+'"')) `
        -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $url="http://127.0.0.1:$port/task-wave"
    $healthy=$false
    for($attempt=0;$attempt -lt 50;$attempt++){
        if($process.HasExited){break}
        try {if([Bitworks.FastLlm.LoopbackHttp]::Request($url,'health',1000,1048576).Status -eq 200){$healthy=$true;break}}catch{}
        Start-Sleep -Milliseconds 100
    }
    if(-not $healthy){throw "Task-wave mock failed startup: $(if(Test-Path -LiteralPath $stderr){Get-Content -LiteralPath $stderr -Raw})"}
    Check $true 'disposable loopback fixture is ready'

    $acceptBytes=if(Test-Path -LiteralPath $accepted){(Get-Item -LiteralPath $accepted).Length}else{0}
    $emptyPeer=New-Object Net.Sockets.TcpClient
    try {
        $emptyPeer.Connect([Net.IPAddress]::Loopback,$port)
        $acceptClock=[Diagnostics.Stopwatch]::StartNew()
        while($acceptClock.Elapsed.TotalSeconds -lt 3){
            if($process.HasExited){break}
            if((Test-Path -LiteralPath $accepted) -and (Get-Item -LiteralPath $accepted).Length -gt $acceptBytes){break}
            Start-Sleep -Milliseconds 25
        }
        if(-not (Test-Path -LiteralPath $accepted) -or (Get-Item -LiteralPath $accepted).Length -le $acceptBytes){
            throw 'Mock did not accept the empty-header peer.'
        }
        $emptyPeer.Client.LingerState=New-Object Net.Sockets.LingerOption($true,0)
    }finally{$emptyPeer.Dispose()}
    $recoveredAfterReset=$false
    for($attempt=0;$attempt -lt 40;$attempt++){
        if($process.HasExited){break}
        try {if([Bitworks.FastLlm.LoopbackHttp]::Request($url,'after-reset',500,1048576).Status -eq 200){$recoveredAfterReset=$true;break}}catch{}
        Start-Sleep -Milliseconds 50
    }
    Check $recoveredAfterReset 'accepted no-header peer reset does not kill fixture or next healthy request'

    $before=@(Get-Content -LiteralPath $log).Count
    foreach($invoke in @(
        {Invoke-ConcurrencyWave -Url $url -Clients 0 -TimeoutMs 1000 -Bodies @('x')},
        {Invoke-ConcurrencyWave -Url $url -Clients 9 -TimeoutMs 1000 -Bodies @('x')},
        {Invoke-ConcurrencyWave -Url $url -Clients 2 -TimeoutMs 1000 -Bodies @('x')},
        {Invoke-ConcurrencyWave -Url $url -Clients 1 -TimeoutMs 1000 -Bodies @('')},
        {Invoke-ConcurrencyWave -Url $url -Clients 1 -TimeoutMs 1000 -Bodies @($null)},
        {Invoke-ConcurrencyWave -Url $url -Clients 1 -TimeoutMs 1000 -Body 'x' -Bodies @('y')},
        {Invoke-ConcurrencyWave -Url $url -Clients 1 -TimeoutMs 1000}
    )){
        $rejected=$false
        try{$null=& $invoke}catch{$rejected=$true}
        Check $rejected 'invalid client/body selection rejects before transport'
    }
    Check (@(Get-Content -LiteralPath $log).Count -eq $before) 'invalid selection made no HTTP request'

    foreach($clients in @(1,2,4)){
        $bodies=@(for($i=1;$i -le $clients;$i++){"c$clients-$i"})
        $wave=Invoke-ConcurrencyWave -Url $url -Clients $clients -TimeoutMs 4000 -Bodies $bodies
        Assert-WaveTiming $wave $clients
        for($i=0;$i -lt $clients;$i++){
            $request=$wave.requests[$i]
            $echo=$request.response.Body|ConvertFrom-Json
            Check ($request.client -eq $i+1 -and $request.response.Status -eq 200 -and
                $request.errorCode -eq $null -and $echo.body -ceq $bodies[$i]) 'client index retains its distinct serialized body'
        }
        if($clients -gt 1){
            Check ((Get-ConcurrencyObservedOverlap $wave.requests) -ge 2) 'barrier produces overlapping HTTP intervals'
        }
    }

    $failed=Invoke-ConcurrencyWave -Url $url -Clients 2 -TimeoutMs 4000 -Bodies @('quick','slow-fail')
    Assert-WaveTiming $failed 2
    Check ($failed.requests[0].response.Status -eq 200 -and $failed.requests[1].response.Status -eq 503 -and
        $failed.requests[1].errorCode -eq $null -and $failed.wallMs -ge 300) 'slow failed HTTP client remains in common-wall sample'

    $timed=Invoke-ConcurrencyWave -Url $url -Clients 1 -TimeoutMs 150 -Bodies @('stall')
    Assert-WaveTiming $timed 1
    Check ($timed.requests[0].errorCode -eq 'request-error' -and $timed.requests[0].response -eq $null -and
        $timed.collectorElapsedMs -lt 5000) 'timed-out client yields bounded failed request and runspace cleanup'
    $recovered=$false
    for($attempt=0;$attempt -lt 40;$attempt++){
        if($process.HasExited){break}
        try {if([Bitworks.FastLlm.LoopbackHttp]::Request($url,'recover',500,1048576).Status -eq 200){$recovered=$true;break}}catch{}
        Start-Sleep -Milliseconds 100
    }
    Check $recovered 'fixture serves another request after timeout and peer disconnect'

    $uniform=Invoke-ConcurrencyWave $url 'uniform' 2 4000
    Assert-WaveTiming $uniform 2
    Check (@($uniform.requests|Where-Object {($_.response.Body|ConvertFrom-Json).body -cne 'uniform'}).Count -eq 0) 'legacy positional Body sends identical body to both clients'
    $emptyGet=Invoke-ConcurrencyWave -Url $url -Body '' -Clients 1 -TimeoutMs 4000
    Assert-WaveTiming $emptyGet 1
    Check ($emptyGet.requests[0].response.Status -eq 200) 'legacy empty Body remains accepted'
} finally {
    if($process -and -not $process.HasExited){$process.Kill();$process.WaitForExit(5000)|Out-Null}
    if(Test-Path -LiteralPath $scratch){[IO.Directory]::Delete($scratch,$true)}
}
Write-Host "Task-wave assertions passed: $count"
