#requires -Version 5.1
param([string] $SourceRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Add-Type -Path (Join-Path $SourceRoot 'src/ProcessHost.cs')

$listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = $listener.LocalEndpoint.Port
$listener.Stop()
$server = New-Object Diagnostics.Process
try {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = (Get-Process -Id $PID).Path
    $mockScript = Join-Path $SourceRoot 'tests/helpers/mock-server.ps1'
    $info.Arguments = '-NoLogo -NoProfile -NonInteractive -File "' + $mockScript + '" -Port ' + $port + ' -Mode ok'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $server.StartInfo = $info
    if (-not $server.Start()) { throw 'Mock server did not start.' }
    $url = "http://127.0.0.1:$port/health"
    $curl = Join-Path (Join-Path $env:SystemRoot 'System32') 'curl.exe'
    $curlOk = $false
    for ($i = 0; $i -lt 50; $i++) {
        if ($server.HasExited) { throw "Mock server exited $($server.ExitCode) before health check." }
        $body = & $curl --silent --max-time 2 $url
        if ($LASTEXITCODE -eq 0 -and $body -match '"status":"ok"') { $curlOk = $true; break }
        Start-Sleep -Milliseconds 100
    }
    if (-not $curlOk) { throw 'System32 curl did not observe a ready mock health response.' }
    Write-Host 'System32 curl: 200 OK health response.'
    try {
        $result = [Bitworks.FastLlm.LoopbackHttp]::Request($url, $null, 1000, 1048576)
        Write-Host "LoopbackHttp: HTTP $($result.Status), body $($result.Body)"
        if ($result.Status -ne 200 -or ($result.Body | ConvertFrom-Json).status -ne 'ok') {
            throw 'LoopbackHttp returned an unexpected health response.'
        }
        $empty = [Bitworks.FastLlm.LoopbackHttp]::Request($url, '', 1000, 1048576)
        if ($empty.Status -ne 200) { throw 'Empty-body health call did not use GET.' }
        Write-Host 'LoopbackHttp: null and empty body both used GET /health.'
        $post = [Bitworks.FastLlm.LoopbackHttp]::Request("http://127.0.0.1:$port/completion", '{}', 1000, 1048576)
        if ($post.Status -ne 200) { throw 'Nonempty JSON body did not use POST.' }
        Write-Host 'LoopbackHttp: nonempty JSON body used POST /completion.'
        $redirect = [Bitworks.FastLlm.LoopbackHttp]::Request("http://127.0.0.1:$port/redirect", $null, 1000, 1048576)
        if ($redirect.Status -ne 302) { throw 'Redirect was followed instead of returned.' }
        Write-Host 'LoopbackHttp: remote redirect was not followed.'
        $oversizeRejected = $false
        try { [Bitworks.FastLlm.LoopbackHttp]::Request("http://127.0.0.1:$port/oversize", $null, 5000, 1048576) | Out-Null }
        catch { $oversizeRejected = $_.Exception.ToString().Contains('exceeds limit') }
        if (-not $oversizeRejected) { throw 'Oversized response was not rejected.' }
        Write-Host 'LoopbackHttp: oversized response was rejected.'
        $timeoutRejected = $false
        try { [Bitworks.FastLlm.LoopbackHttp]::Request("http://127.0.0.1:$port/stall", $null, 200, 1048576) | Out-Null }
        catch { $timeoutRejected = $true }
        if (-not $timeoutRejected) { throw 'Stalled response exceeded its deadline.' }
        Write-Host 'LoopbackHttp: stalled response was bounded by deadline.'
    }
    catch {
        Write-Host "LoopbackHttp exception type: $($_.Exception.GetType().FullName)"
        Write-Host "LoopbackHttp exception message: $($_.Exception.Message)"
        if ($_.Exception.InnerException) {
            Write-Host "Inner type: $($_.Exception.InnerException.GetType().FullName)"
            Write-Host "Inner message: $($_.Exception.InnerException.Message)"
        }
        throw
    }
}
finally {
    if (-not $server.HasExited) {
        $server.Kill()
        $server.WaitForExit(5000) | Out-Null
    }
    $server.Dispose()
}
