#requires -Version 5.1
# The update download inside a hosted runspace, the way the window runs it.
# fast-llm-ui.ps1's InvokeUiUpdate runs Invoke-FastLlmVerifiedUpdate in [PowerShell]::Create() with $ErrorActionPreference='Stop'
# (it imports src/FastLlm.psm1 and dot-sources src/FastLlm.Update.ps1). Its download step, Save-FastLlmUpdateCappedFile, calls
# curl.exe directly. When the download fails, curl writes "curl: (N) ..." on stderr and exits N; the function's designed answer is
# "Download failed with curl exit code N.". Windows PowerShell 5.1 can turn a native command's stderr into a terminating
# RemoteException under Stop, which would replace that message. This suite drives the REAL function against a closed local port
# (no network, nothing listens there): once in a hosted runspace exactly as the window does, and once in this script's own scope.
# It needs curl: System32 curl.exe on Windows (CI's powershell job runs it under 5.1 and PS 7), or curl on the PATH elsewhere.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src/FastLlm.Update.ps1')
$script:count = 0
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; $script:count++; Write-Host "PASS: $Message" }

$curlPresent = $false
if ($env:OS -eq 'Windows_NT') { $curlPresent = [bool]($env:SystemRoot -and (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\curl.exe') -PathType Leaf)) }
else { $curlPresent = [bool](Get-Command 'curl' -CommandType Application -ErrorAction SilentlyContinue) }
if (-not $curlPresent) {
    Write-Host 'SKIP: update-download-runspace-tests: no curl for the download function on this host (System32 curl.exe on Windows); 5 checks not run.'
    exit 0
}

# A closed local port: bind an ephemeral port, note it, release it. Nothing listens there, so curl fails at connect (exit 7).
$listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, 0)
$listener.Start(); $port = $listener.LocalEndpoint.Port; $listener.Stop()
$prefix = "https://127.0.0.1:$port/"
$url = $prefix + 'FastLLM-Setup.exe'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('fast-llm-update-runspace-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
$designed = '^Download failed with curl exit code [1-9][0-9]*\.$'
try {
    # 1. In a hosted runspace, set up as InvokeUiUpdate's runspace script is (fast-llm-ui.ps1). Only the release URL prefix is
    #    pointed at the closed local port, so the function's own prefix check passes and curl really runs.
    $source = @'
param($Project, $Prefix, $Url, $Destination)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $Project 'src/FastLlm.psm1') -Force
. (Join-Path $Project 'src/FastLlm.Update.ps1')
$script:FastLlmAssetUrlPrefix = $Prefix
try { Save-FastLlmUpdateCappedFile -Url $Url -Destination $Destination -MaxBytes 1048576; 'RESULT=no-throw' }
catch { 'RESULT=threw'; 'TYPE=' + $_.Exception.GetType().FullName; 'MESSAGE=' + $_.Exception.Message }
'@
    $runspaceFile = Join-Path $temp 'runspace.bin'
    $pipeline = [Management.Automation.PowerShell]::Create()
    try {
        $null = $pipeline.AddScript($source).AddArgument($root).AddArgument($prefix).AddArgument($url).AddArgument($runspaceFile)
        $handle = $pipeline.BeginInvoke()
        $done = $handle.AsyncWaitHandle.WaitOne(120000)
        Check $done 'the hosted runspace finishes within 120 s'
        $lines = @($pipeline.EndInvoke($handle) | ForEach-Object { [string]$_ })
    } finally { $pipeline.Dispose() }
    $message = @($lines | Where-Object { $_.StartsWith('MESSAGE=') } | ForEach-Object { $_.Substring(8) })
    $type = @($lines | Where-Object { $_.StartsWith('TYPE=') } | ForEach-Object { $_.Substring(5) })
    Write-Host ('hosted runspace: ' + ($lines -join ' | '))
    Check ($lines -contains 'RESULT=threw' -and $message.Count -eq 1 -and $message[0] -match $designed -and @($type) -notcontains 'System.Management.Automation.RemoteException') "in a hosted runspace under Stop, a failed download gives the designed message (got: $($message -join ' / '); type: $($type -join ' / '))"
    Check (-not (Test-Path -LiteralPath $runspaceFile)) 'in a hosted runspace, a failed download leaves no file'

    # 2. The same call in this script's own scope (Stop), as the console path runs it.
    $script:FastLlmAssetUrlPrefix = $prefix
    $directFile = Join-Path $temp 'direct.bin'
    $directMessage = $null
    try { Save-FastLlmUpdateCappedFile -Url $url -Destination $directFile -MaxBytes 1048576 } catch { $directMessage = $_.Exception.Message }
    Write-Host "script scope: $directMessage"
    Check ($null -ne $directMessage -and $directMessage -match $designed) "in the script's own scope under Stop, a failed download gives the designed message (got: $directMessage)"
    Check (-not (Test-Path -LiteralPath $directFile)) "in the script's own scope, a failed download leaves no file"
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host "update-download-runspace-tests: $script:count checks passed"
# The failed curl leaves its exit code in $LASTEXITCODE; CI fails the step on a non-zero final value, so reset it once every check passed.
$global:LASTEXITCODE = 0
