#requires -Version 5.1
# Downloads an exact, independently pinned source-only lab package. It never runs or installs it.
[CmdletBinding()]
param(
    [string]$SourceUrl,
    [string]$ExpectedSha256,
    [long]$ExpectedSizeBytes
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2

function Assert-FastLlmLabReleaseUrl {
    param([string]$Url)
    if($Url -cnotmatch '^https://github\.com/bitworks-io/amd-inference/releases/download/v[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.]+)?-g[0-9a-f]{40}/(FastLLM-lab-[0-9a-f]{32}\.zip)$'){
        throw 'Use an exact Bitworks GitHub lab-package release URL with a version, full source commit and package GUID; moving or ambiguous URLs are refused.'
    }
    return [pscustomobject]@{url=$Url;fileName=[string]$Matches[1]}
}

function Assert-FastLlmLabRedirectUrl {
    param([string]$Url)
    if([string]::IsNullOrWhiteSpace($Url) -or $Url.Length -gt 4096){throw 'Release redirect URL is missing or too long.'}
    if($Url -cnotmatch '^https://release-assets\.githubusercontent\.com/'){
        throw 'Release redirect must use the exact GitHub asset host without a custom port or credentials.'
    }
    $uri=$null
    if(-not [Uri]::TryCreate($Url,[UriKind]::Absolute,[ref]$uri) -or
       $uri.Scheme -cne 'https' -or $uri.Host -cne 'release-assets.githubusercontent.com' -or
       -not $uri.IsDefaultPort -or $uri.UserInfo -or $uri.Fragment -or
       -not $uri.AbsolutePath.StartsWith('/github-production-release-asset-',[StringComparison]::Ordinal)){
        throw 'Release redirect left the expected GitHub HTTPS asset service.'
    }
    return $uri.AbsoluteUri
}

function Assert-FastLlmLabDownloadDirectory {
    param([string]$Directory)
    $full=[IO.Path]::GetFullPath($Directory)
    if($env:OS -eq 'Windows_NT'){
        if($full -cnotmatch '^[A-Za-z]:\\'){
            throw 'The download cache must be on a local Windows drive.'
        }
        $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($full))
        if(-not $drive.IsReady -or $drive.DriveType -ne [IO.DriveType]::Fixed){
            throw 'The download cache requires an available fixed local drive.'
        }
    }
    $cursor=$full
    while($cursor){
        $attributes=$null
        try{$attributes=[IO.File]::GetAttributes($cursor)}
        catch [IO.FileNotFoundException]{}
        catch [IO.DirectoryNotFoundException]{}
        if($null -ne $attributes){
            if(($attributes -band [IO.FileAttributes]::Directory) -eq 0 -or
               ($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){
                throw 'The download cache path contains a file or reparse point.'
            }
        }
        $parent=[IO.Path]::GetDirectoryName($cursor)
        if(-not $parent -or $parent -ceq $cursor){break}
        $cursor=$parent
    }
    return $full
}

function Invoke-FastLlmLabHttpGet {
    param([string]$Url,[string]$Destination,[long]$MaxBytes,[Threading.CancellationToken]$Token)
    Add-Type -AssemblyName System.Net.Http
    # .NET Framework response streams may not honor a token on a blocked ReadAsync.
    # The callback is pure CLR code: it must not invoke PowerShell on a thread-pool thread.
    if(-not ('FastLlmLabReadCancellation' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
public static class FastLlmLabReadCancellation {
    public static CancellationTokenRegistration Register(CancellationToken token, Stream stream) {
        return token.Register(state => {
            try { ((Stream)state).Dispose(); } catch (Exception) { }
        }, stream);
    }
}
'@
    }
    $handler=New-Object Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect=$false
    $handler.UseCookies=$false
    $client=[Net.Http.HttpClient]::new($handler)
    $response=$null;$stream=$null;$output=$null;$abort=$null
    try{
        $client.Timeout=[TimeSpan]::FromSeconds(125)
        $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,$Url)
        try{
            $response=$client.SendAsync($request,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$Token).GetAwaiter().GetResult()
        }finally{$request.Dispose()}
        $status=[int]$response.StatusCode
        if($status -in @(301,302,303,307,308)){
            if(-not $response.Headers.Location){throw 'Release redirect lacks a Location.'}
            return [pscustomobject]@{status=$status;location=$response.Headers.Location.OriginalString;bytes=0L}
        }
        if($status -ne 200){throw "Release download returned HTTP $status."}
        if($response.Content.Headers.ContentLength -and [long]$response.Content.Headers.ContentLength -gt $MaxBytes){
            throw 'Release Content-Length exceeds the exact expected package size.'
        }
        $stream=$response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $abort=[FastLlmLabReadCancellation]::Register($Token,$stream)
        $output=[IO.File]::Open($Destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $buffer=New-Object byte[] 65536
        $total=0L
        while($true){
            $Token.ThrowIfCancellationRequested()
            $count=$stream.ReadAsync($buffer,0,$buffer.Length,$Token).GetAwaiter().GetResult()
            if($count -eq 0){break}
            $total+=$count
            if($total -gt $MaxBytes){throw 'Release response exceeds the exact expected package size.'}
            $output.Write($buffer,0,$count)
        }
        $output.Flush($true)
        return [pscustomobject]@{status=200;location=$null;bytes=$total}
    }finally{
        if($abort){$abort.Dispose()}
        if($output){$output.Dispose()}
        if($stream){$stream.Dispose()}
        if($response){$response.Dispose()}
        $client.Dispose();$handler.Dispose()
    }
}

function Get-FastLlmLabPackageCore {
    param([string]$Url,[string]$Sha256,[long]$SizeBytes,[string]$CacheDirectory)
    $release=Assert-FastLlmLabReleaseUrl $Url
    if($Sha256 -cnotmatch '^[0-9a-fA-F]{64}$'){throw 'Expected SHA-256 must contain exactly 64 hexadecimal characters.'}
    if($SizeBytes -lt 1 -or $SizeBytes -gt 64MB){throw 'Expected source package size must be 1 to 64 MiB.'}
    $cache=Assert-FastLlmLabDownloadDirectory $CacheDirectory
    if(-not (Test-Path -LiteralPath $cache)){
        [void][IO.Directory]::CreateDirectory($cache)
        $cache=Assert-FastLlmLabDownloadDirectory $cache
    }
    $final=Join-Path $cache $release.fileName
    if(Test-Path -LiteralPath $final){throw 'The exact package filename already exists; review it before another download.'}
    $partial=Join-Path $cache ('.'+$release.fileName+'.partial.'+[Guid]::NewGuid().ToString('N'))
    $cancel=New-Object Threading.CancellationTokenSource
    try{
        $cancel.CancelAfter([TimeSpan]::FromSeconds(120))
        $current=$release.url
        $redirects=0
        while($true){
            $reply=Invoke-FastLlmLabHttpGet -Url $current -Destination $partial -MaxBytes $SizeBytes -Token $cancel.Token
            if($reply.status -eq 200){break}
            $redirects++
            if($redirects -gt 3){throw 'Release exceeded the redirect limit.'}
            $current=Assert-FastLlmLabRedirectUrl ([string]$reply.location)
        }
        $item=Get-Item -LiteralPath $partial -Force
        if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
           [long]$item.Length -ne $SizeBytes -or [long]$reply.bytes -ne $SizeBytes){
            throw 'Downloaded package byte count differs from the independently supplied size.'
        }
        $actual=(Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant()
        if($actual -cne $Sha256.ToLowerInvariant()){throw 'Downloaded package SHA-256 differs from the independently supplied digest.'}
        if(Test-Path -LiteralPath $final){throw 'The exact package filename appeared during download; refusing to overwrite it.'}
        [IO.File]::Move($partial,$final)
        return [pscustomobject]@{path=$final;sizeBytes=$SizeBytes;sha256=$actual;sourceUrl=$release.url;
            installed=$false;executed=$false;publisherAuthenticated=$false;publicReleaseApproved=$false}
    }finally{
        $cancel.Dispose()
        if(Test-Path -LiteralPath $partial){[IO.File]::Delete($partial)}
    }
}

if($MyInvocation.InvocationName -ne '.'){
    if($env:OS -cne 'Windows_NT' -or -not [Environment]::Is64BitProcess){throw 'Use 64-bit Windows PowerShell as a standard user.'}
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Do not elevate the lab package downloader.'}
    $local=[Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if(-not $local){throw 'Per-user LocalAppData is unavailable.'}
    $result=Get-FastLlmLabPackageCore -Url $SourceUrl -Sha256 $ExpectedSha256 -SizeBytes $ExpectedSizeBytes `
        -CacheDirectory (Join-Path $local 'Bitworks/FastLLM/source-packages')
    Write-Host "Verified source-only ZIP: $($result.path)"
    Write-Host "SHA-256: $($result.sha256)"
    Write-Host 'Open the separately reviewed lab setup companion to install this ZIP. No code was executed.'
}
