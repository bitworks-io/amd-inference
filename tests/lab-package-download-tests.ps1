#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'tools/get-lab-package.ps1')
$script:checks=0
function Check([bool]$Condition,[string]$Name){
    if(-not $Condition){throw "FAILED: $Name"}
    $script:checks++
}
function Reject([scriptblock]$Action,[string]$Name){
    $failed=$false
    try{& $Action | Out-Null}catch{$failed=$true}
    Check $failed $Name
}
function RejectMessage([scriptblock]$Action,[string]$Pattern,[string]$Name){
    $message=$null
    try{& $Action | Out-Null}catch{$message=$_.Exception.Message}
    Check ($message -match $Pattern) $Name
}
$tag='v1.2.3-g'+('a'*40)
$url='https://github.com/bitworks-io/amd-inference/releases/download/'+$tag+'/FastLLM-lab-'+('b'*32)+'.zip'
$asset='https://release-assets.githubusercontent.com/github-production-release-asset-sample?token=x'
$sha=([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes('abc')))).Replace('-','').ToLowerInvariant()
Check ((Assert-FastLlmLabReleaseUrl $url).fileName -ceq ('FastLLM-lab-'+('b'*32)+'.zip')) 'exact release URL accepted'
foreach($bad in @(
    ($url -replace $tag,'latest'),($url -replace 'github.com','evil.example'),
    ($url -replace '/releases/download/','/archive/'),($url+'?download=1'),
    ($url -replace 'https:','http:'),($url -replace 'bitworks-io','bitworks%2dio'),
    ($url -replace '-g[a-f0-9]{40}','-gabc'),($url -replace '.zip','.zip/other')
)) {Reject {Assert-FastLlmLabReleaseUrl $bad} 'mutable or ambiguous release URL rejected'}
Check ((Assert-FastLlmLabRedirectUrl $asset) -eq $asset) 'official release asset redirect accepted'
foreach($bad in @(
    'http://release-assets.githubusercontent.com/github-production-release-asset-x',
    'https://evil.example/github-production-release-asset-x',
    'https://release-assets.githubusercontent.com.evil.example/github-production-release-asset-x',
    'https://release-assets.githubusercontent.com/other-path',
    'https://user:pass@release-assets.githubusercontent.com/github-production-release-asset-x',
    'https://release-assets.githubusercontent.com:444/github-production-release-asset-x',
    'https://release-assets.githubusercontent.com/github-production-release-asset-x#fragment'
)) {Reject {Assert-FastLlmLabRedirectUrl $bad} 'unsafe redirect rejected'}

# The production CLI has no transport-injection parameter. Only this offline test
# replaces its script-scope HTTP function; hash and size checks remain in the core.
$original=${function:Invoke-FastLlmLabHttpGet}
function Invoke-FastLlmLabHttpGet {
    param([string]$Url,[string]$Destination,[long]$MaxBytes,[Threading.CancellationToken]$Token)
    if($script:replies.Count -eq 0){throw 'Offline transport plan exhausted.'}
    $next=$script:replies[0]
    $script:replies=@($script:replies | Select-Object -Skip 1)
    if($next.PSObject.Properties['error'] -and $next.error){throw $next.error}
    if($next.status -eq 200){
        [IO.File]::WriteAllBytes($Destination,[byte[]]$next.content)
        return [pscustomobject]@{status=200;location=$null;bytes=[long]$next.content.Count}
    }
    return [pscustomobject]@{status=[int]$next.status;location=[string]$next.location;bytes=0L}
}
$root=Join-Path $PSScriptRoot ('tmp-lab-download-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try{
    $plainFile=Join-Path $root 'plain-file'
    [IO.File]::WriteAllText($plainFile,'x')
    RejectMessage {Assert-FastLlmLabDownloadDirectory (Join-Path $plainFile 'child')} 'file or reparse' 'file ancestor rejected'
    $link=Join-Path $root 'dangling-link'
    $created=$false
    try{$null=New-Item -ItemType SymbolicLink -Path $link -Target (Join-Path $root 'no-target') -ErrorAction Stop;$created=$true}
    catch{Write-Host 'SKIP: creating a symbolic link requires a privilege unavailable to this test account.'}
    if($created){
        RejectMessage {Assert-FastLlmLabDownloadDirectory (Join-Path $link 'child')} 'file or reparse' 'dangling link ancestor rejected'
    }
    $good=@([byte]97,[byte]98,[byte]99)
    $script:replies=@(
        [pscustomobject]@{status=302;location=$asset;content=$null;error=$null},
        [pscustomobject]@{status=200;location=$null;content=$good;error=$null}
    )
    $success=Get-FastLlmLabPackageCore -Url $url -Sha256 $sha -SizeBytes 3 -CacheDirectory (Join-Path $root 'good')
    Check ([IO.File]::Exists($success.path)) 'verified package retained'
    Check ($success.sha256 -ceq $sha -and -not $success.installed -and -not $success.executed) 'acquisition-only result'
    Check (@($script:replies).Count -eq 0) 'both planned responses consumed'

    $cases=@(
        [pscustomobject]@{name='wrong digest';size=3;hash=('0'*64);replies=@([pscustomobject]@{status=200;content=$good})},
        [pscustomobject]@{name='short body';size=4;hash=$sha;replies=@([pscustomobject]@{status=200;content=$good})},
        [pscustomobject]@{name='oversize body';size=2;hash=$sha;replies=@([pscustomobject]@{status=200;content=$good})},
        [pscustomobject]@{name='broken transport';size=3;hash=$sha;replies=@([pscustomobject]@{error='interrupted'})},
        [pscustomobject]@{name='cross origin';size=3;hash=$sha;replies=@([pscustomobject]@{status=302;location='https://evil.example/data'})},
        [pscustomobject]@{name='redirect loop';size=3;hash=$sha;replies=@(
            [pscustomobject]@{status=302;location=$asset},[pscustomobject]@{status=302;location=$asset},
            [pscustomobject]@{status=302;location=$asset},[pscustomobject]@{status=302;location=$asset})}
    )
    foreach($case in $cases){
        $dest=Join-Path $root ($case.name -replace ' ','-')
        $script:replies=@($case.replies)
        $reason=switch($case.name){
            'wrong digest' {'SHA-256 differs'}
            'short body' {'byte count differs'}
            'oversize body' {'byte count differs'}
            'broken transport' {'interrupted'}
            'cross origin' {'redirect'}
            'redirect loop' {'redirect limit'}
        }
        RejectMessage {Get-FastLlmLabPackageCore -Url $url -Sha256 $case.hash -SizeBytes $case.size -CacheDirectory $dest} $reason $case.name
        Check (@(Get-ChildItem -LiteralPath $dest -File -Force).Count -eq 0) ($case.name+' leaves no package or partial file')
    }
    Reject {Get-FastLlmLabPackageCore -Url $url -Sha256 ('0'*63) -SizeBytes 3 -CacheDirectory (Join-Path $root 'bad-hash')} 'malformed digest rejected before fetch'
    Reject {Get-FastLlmLabPackageCore -Url $url -Sha256 $sha -SizeBytes (64MB+1) -CacheDirectory (Join-Path $root 'bad-size')} 'excessive expected size rejected before fetch'
}finally{
    ${function:Invoke-FastLlmLabHttpGet}=$original
    [IO.Directory]::Delete($root,$true)
}

# Exercise the actual streaming helper with a single-request loopback fixture.
# The public CLI never accepts a test transport or a loopback source URL.
Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
public sealed class FastLlmOneResponseServer : IDisposable {
    private readonly TcpListener listener;
    private readonly Thread worker;
    private readonly string headers;
    private readonly byte[] body;
    private readonly int bodyDelayMs;
    public readonly int Port;
    public FastLlmOneResponseServer(string headers, byte[] body, int bodyDelayMs) {
        this.headers=headers; this.body=body; this.bodyDelayMs=bodyDelayMs;
        listener=new TcpListener(IPAddress.Loopback,0); listener.Start(1);
        Port=((IPEndPoint)listener.LocalEndpoint).Port;
        worker=new Thread(Run); worker.IsBackground=true; worker.Start();
    }
    private void Run() {
        try {
            using(var client=listener.AcceptTcpClient()) {
                client.ReceiveTimeout=2000; client.SendTimeout=2000;
                using(var stream=client.GetStream()) {
                    int matched=0, read=0;
                    while(read++<8192 && matched<4) {
                        int next=stream.ReadByte(); if(next<0) return;
                        int expected="\r\n\r\n"[matched];
                        matched= next==expected ? matched+1 : (next=='\r' ? 1 : 0);
                    }
                    var head=Encoding.ASCII.GetBytes(headers);
                    stream.Write(head,0,head.Length); stream.Flush();
                    if(bodyDelayMs>0) Thread.Sleep(bodyDelayMs);
                    if(body!=null && body.Length>0) {stream.Write(body,0,body.Length); stream.Flush();}
                }
            }
        } catch(SocketException) {} catch(System.IO.IOException) {} catch(ObjectDisposedException) {}
    }
    public void Dispose() {listener.Stop(); if(!worker.Join(3000)) throw new Exception("Loopback fixture did not stop");}
}
'@
$transportRoot=Join-Path $PSScriptRoot ('tmp-lab-http-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($transportRoot)
function ProbeRealHttp([string]$Headers,[byte[]]$Body,[int]$Delay,[long]$Limit,[int]$CancelMs,[string]$Leaf){
    $server=[FastLlmOneResponseServer]::new($Headers,$Body,$Delay)
    $source=[Threading.CancellationTokenSource]::new()
    $path=Join-Path $transportRoot $Leaf
    try{
        $source.CancelAfter($CancelMs)
        return Invoke-FastLlmLabHttpGet -Url ('http://127.0.0.1:'+$server.Port+'/fixture') `
            -Destination $path -MaxBytes $Limit -Token $source.Token
    }finally{$source.Dispose();$server.Dispose()}
}
try{
    $body=@([byte]97,[byte]98,[byte]99)
    $ok=ProbeRealHttp -Headers "HTTP/1.1 200 OK`r`nContent-Length: 3`r`nConnection: close`r`n`r`n" -Body $body `
        -Delay 0 -Limit 3 -CancelMs 2000 -Leaf 'ok.bin'
    Check ($ok.status -eq 200 -and $ok.bytes -eq 3 -and [IO.File]::ReadAllText((Join-Path $transportRoot 'ok.bin')) -ceq 'abc') 'real HTTP streamed exact body'
    $moved='https://release-assets.githubusercontent.com/github-production-release-asset-test?token=x'
    $redirect=ProbeRealHttp -Headers "HTTP/1.1 302 Found`r`nLocation: $moved`r`nContent-Length: 0`r`nConnection: close`r`n`r`n" `
        -Body @() -Delay 0 -Limit 3 -CancelMs 2000 -Leaf 'redirect.bin'
    Check ($redirect.status -eq 302 -and $redirect.location -ceq $moved -and -not (Test-Path -LiteralPath (Join-Path $transportRoot 'redirect.bin'))) 'real HTTP redirect returns location without file'
    RejectMessage {ProbeRealHttp -Headers "HTTP/1.1 404 Not Found`r`nContent-Length: 0`r`nConnection: close`r`n`r`n" `
        -Body @() -Delay 0 -Limit 3 -CancelMs 2000 -Leaf 'notfound.bin'} 'HTTP 404' 'real HTTP rejects non-200'
    RejectMessage {ProbeRealHttp -Headers "HTTP/1.1 200 OK`r`nContent-Length: 4`r`nConnection: close`r`n`r`n" `
        -Body @() -Delay 0 -Limit 3 -CancelMs 2000 -Leaf 'large-header.bin'} 'Content-Length exceeds' 'real HTTP rejects oversized length header'
    Check (-not (Test-Path -LiteralPath (Join-Path $transportRoot 'large-header.bin'))) 'oversized header creates no file'
    RejectMessage {ProbeRealHttp -Headers "HTTP/1.1 200 OK`r`nConnection: close`r`n`r`n" `
        -Body @([byte]97,[byte]98,[byte]99,[byte]100) -Delay 0 -Limit 3 -CancelMs 2000 -Leaf 'large-body.bin'} 'response exceeds' 'real HTTP rejects oversized streamed body'
    $slow=[FastLlmOneResponseServer]::new("HTTP/1.1 200 OK`r`nContent-Length: 3`r`nConnection: close`r`n`r`n",$body,2000)
    $cancel=[Threading.CancellationTokenSource]::new()
    $cancel.CancelAfter(50)
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $cancelled=$false
    $tokenWasCancelled=$false
    $elapsed=$null
    try{
        try{
            Invoke-FastLlmLabHttpGet -Url ('http://127.0.0.1:'+$slow.Port+'/fixture') `
                -Destination (Join-Path $transportRoot 'cancel.bin') -MaxBytes 3 -Token $cancel.Token | Out-Null
        }catch{$cancelled=$true;$tokenWasCancelled=$cancel.IsCancellationRequested}
    }finally{
        $elapsed=$watch.ElapsedMilliseconds
        $watch.Stop()
        $cancel.Dispose()
        # Fixture cleanup deliberately occurs after the elapsed measurement.
        $slow.Dispose()
    }
    Check ($cancelled -and $tokenWasCancelled -and $elapsed -lt 1000 -and
        (Test-Path -LiteralPath (Join-Path $transportRoot 'cancel.bin'))) `
        ("real stalled-body read ends before server releases body (helper $elapsed ms)")
    Write-Host "Stalled-body helper returned after $elapsed ms; fixture cleanup followed separately."
}finally{[IO.Directory]::Delete($transportRoot,$true)}
Write-Host "Lab package URL acquisition: $script:checks checks passed."
