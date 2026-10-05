# Private lab-only preparation of one reviewed Microsoft x64 VC++ package.
# No function in this file executes the installer or accepts its license.
function Get-FastLlmVcRedistCandidate {
    param([Parameter(Mandatory=$true)][string]$ManifestPath)
    $expectedUrl='https://download.visualstudio.microsoft.com/download/pr/ebdab8e5-1d7b-4d9f-a11b-cbb1720c3b12/843068991DAAA1F73AD9F6239BCE4D0F6A07A51F18C37EA2A867E9BECA71295C/VC_redist.x64.exe'
    Assert-FastLlmVcRedistPath -Path $ManifestPath
    $item=Get-Item -LiteralPath $ManifestPath -Force -ErrorAction Stop
    if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -gt 8192){
        throw 'Reviewed prerequisite manifest is unsafe.'
    }
    $manifest=Get-Content -LiteralPath $ManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if(($manifest.schemaVersion -isnot [int] -and $manifest.schemaVersion -isnot [long]) -or
       $manifest.schemaVersion -ne 1 -or $manifest.status -cne 'lab-preparation-only' -or
       $manifest.installerExecutionEnabled -isnot [bool] -or $manifest.installerExecutionEnabled -ne $false -or
       $null -eq $manifest.vcRedistX64){
        throw 'Reviewed prerequisite manifest policy changed.'
    }
    $candidate=$manifest.vcRedistX64
    if([string]$candidate.url -cne $expectedUrl -or
       [string]$candidate.fileName -cne 'VC_redist.x64.exe' -or
       [string]$candidate.version -cne '14.51.36247.0' -or
       ($candidate.sizeBytes -isnot [int] -and $candidate.sizeBytes -isnot [long]) -or
       [int64]$candidate.sizeBytes -ne 18731856 -or
       [string]$candidate.sha256 -cne '843068991daaa1f73ad9f6239bce4d0f6a07a51f18c37ea2a867e9beca71295c' -or
       [string]$candidate.signerSubject -cne 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' -or
       [string]$candidate.signerThumbprint -cne '1D77A9B9E8FE2075D9AD15123257FB90DB0DA4A1'){
        throw 'Reviewed Microsoft prerequisite pin changed.'
    }
    $uri=[Uri]$candidate.url
    if($uri.Scheme -cne 'https' -or $uri.Host -cne 'download.visualstudio.microsoft.com' -or
       -not $uri.IsDefaultPort -or $uri.UserInfo -or $uri.Query -or $uri.Fragment){
        throw 'Reviewed prerequisite URL is not an exact Microsoft CDN URL.'
    }
    return $candidate
}

function Assert-FastLlmVcRedistHostState {
    param([bool]$WindowsHost,[bool]$Host64Bit,[bool]$Elevated)
    if(-not $WindowsHost -or -not $Host64Bit){
        throw 'VC++ preparation requires 64-bit Windows.'
    }
    if($Elevated){throw 'VC++ preparation requires a standard-user process.'}
}

function Assert-FastLlmVcRedistStandardWindows {
    if($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess){
        Assert-FastLlmVcRedistHostState -WindowsHost ($env:OS -eq 'Windows_NT') -Host64Bit ([Environment]::Is64BitProcess) -Elevated $false
    }
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    Assert-FastLlmVcRedistHostState -WindowsHost $true -Host64Bit $true -Elevated ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
}

function Assert-FastLlmVcRedistPath {
    param([Parameter(Mandatory=$true)][string]$Path)
    if(-not [IO.Path]::IsPathRooted($Path)){throw 'VC++ preparation path must be absolute.'}
    $current=[IO.Path]::GetFullPath($Path)
    while($current){
        if(Test-Path -LiteralPath $current){
            $item=Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){
                throw 'VC++ preparation path contains a reparse point.'
            }
        }
        $parent=Split-Path -Parent $current
        if(-not $parent -or $parent -ceq $current){break}
        $current=$parent
    }
}

function Assert-FastLlmVcRedistMetadata {
    param([int64]$ActualLength,[string]$ActualHash,[string]$FileVersion,[string]$ProductVersion,
          [string]$SignatureStatus,[string]$SignerSubject,[string]$SignerThumbprint,
          [Parameter(Mandatory=$true)]$Candidate)
    if($ActualLength -ne [int64]$Candidate.sizeBytes){throw 'Microsoft prerequisite artifact size differs.'}
    if($ActualHash -cne [string]$Candidate.sha256){throw 'Microsoft prerequisite artifact SHA-256 differs.'}
    if($FileVersion -cne [string]$Candidate.version -or $ProductVersion -cne [string]$Candidate.version){
        throw 'Microsoft prerequisite artifact version differs.'
    }
    if($SignatureStatus -cne 'Valid' -or $SignerSubject -cne [string]$Candidate.signerSubject -or
       $SignerThumbprint -cne [string]$Candidate.signerThumbprint){
        throw 'Microsoft prerequisite artifact signature or publisher differs.'
    }
}

function Assert-FastLlmVcRedistArtifact {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)]$Candidate)
    Assert-FastLlmVcRedistPath -Path $Path
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
       [int64]$item.Length -ne [int64]$Candidate.sizeBytes){
        throw 'Microsoft prerequisite artifact has the wrong type or size.'
    }
    $sha=(Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    $version=$item.VersionInfo
    $signature=Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    $subject=if($signature.SignerCertificate){[string]$signature.SignerCertificate.Subject}else{''}
    $thumbprint=if($signature.SignerCertificate){[string]$signature.SignerCertificate.Thumbprint}else{''}
    Assert-FastLlmVcRedistMetadata -ActualLength ([int64]$item.Length) -ActualHash $sha `
        -FileVersion ([string]$version.FileVersion) -ProductVersion ([string]$version.ProductVersion) `
        -SignatureStatus ([string]$signature.Status) -SignerSubject $subject -SignerThumbprint $thumbprint -Candidate $Candidate
    # Metadata/signature and flat hash use separate Windows file opens. Narrow
    # that read-side race before reporting preparation; this is still NOT a
    # protected handoff for executing a user-writable installer as admin.
    Assert-FastLlmVcRedistPath -Path $Path
    $after=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if($after.PSIsContainer -or ($after.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
       [int64]$after.Length -ne [int64]$Candidate.sizeBytes -or
       (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() -cne $sha){
        throw 'Microsoft prerequisite artifact changed during verification.'
    }
    return [pscustomobject]@{status='prepared-not-installed';path=$item.FullName;version=$Candidate.version;
        sizeBytes=[int64]$item.Length;sha256=$sha;signatureStatus='Valid';installerExecuted=$false;
        compatibilityQualified=$false}
}

function Assert-FastLlmVcRedistArtifactBounded {
    param([Parameter(Mandatory=$true)][string]$Path,
          [Parameter(Mandatory=$true)][string]$ManifestPath,
          [Parameter(Mandatory=$true)]$Candidate)
    Assert-FastLlmVcRedistPath -Path $Path
    Assert-FastLlmVcRedistPath -Path $ManifestPath
    Initialize-FastLlmProcessHost
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=(Get-Process -Id $PID -ErrorAction Stop).Path
    $worker=Join-Path (Split-Path $PSScriptRoot -Parent) 'tools/prepare-vc-runtime.ps1'
    $info.Arguments=Join-FastLlmProcessArguments -Arguments @('-NoLogo','-NoProfile','-NonInteractive',
        '-File',$worker,'-Action','Validate','-ArtifactPath',$Path,'-InternalWorker')
    $child=New-Object Bitworks.FastLlm.ProcessHost
    $watch=[Diagnostics.Stopwatch]::StartNew()
    try{
        $child.Start($info)
        while(-not $child.Process.HasExited -or -not $child.OutputCompleted){
            if($watch.Elapsed.TotalSeconds -ge 30){throw 'Microsoft prerequisite verification exceeded its deadline.'}
            Start-Sleep -Milliseconds 50
        }
        if($child.OutputTruncated -or $child.Process.ExitCode -ne 0 -or
           $child.Snapshot().Trim() -cne 'vc-redist-verified'){
            throw 'Microsoft prerequisite verification worker failed.'
        }
    }finally{$child.Dispose()}
    # The worker checked this exact manifest and artifact. This receipt is only a
    # preparation record; it is not a secure handoff to an elevated installer.
    return [pscustomobject]@{status='prepared-not-installed';path=[IO.Path]::GetFullPath($Path);
        version=$Candidate.version;sizeBytes=[int64]$Candidate.sizeBytes;sha256=$Candidate.sha256;
        signatureStatus='Valid';installerExecuted=$false;compatibilityQualified=$false}
}

function Invoke-FastLlmVcRedistPrepare {
    param([Parameter(Mandatory=$true)][string]$ManifestPath,
          [Parameter(Mandatory=$true)][string]$CacheRoot)
    Assert-FastLlmVcRedistStandardWindows
    $candidate=Get-FastLlmVcRedistCandidate -ManifestPath $ManifestPath
    $privateRoot=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'Bitworks\FastLLM\prerequisites'
    if([IO.Path]::GetFullPath($CacheRoot) -cne [IO.Path]::GetFullPath($privateRoot)){
        throw 'VC++ preparation uses only its dedicated per-user cache.'
    }
    Assert-FastLlmVcRedistPath -Path $CacheRoot
    $root=[IO.Path]::GetFullPath($CacheRoot)
    if(-not (Test-Path -LiteralPath $root -PathType Container)){
        New-Item -ItemType Directory -Path $root -Force -ErrorAction Stop | Out-Null
    }
    Assert-FastLlmVcRedistPath -Path $root
    $run=Join-Path $root ('vc-redist-'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $run -ErrorAction Stop | Out-Null
    $partial=Join-Path $run 'VC_redist.x64.exe.partial'
    $final=Join-Path $run 'VC_redist.x64.exe'
    $succeeded=$false
    try{
        Assert-FastLlmVcRedistPath -Path $partial
        $curl=Join-Path ([Environment]::SystemDirectory) 'curl.exe'
        Assert-FastLlmVcRedistPath -Path $curl
        $curlItem=Get-Item -LiteralPath $curl -Force -ErrorAction Stop
        if($curlItem.PSIsContainer -or ($curlItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
           $curlItem.Name -cne 'curl.exe'){throw 'Trusted System32 curl.exe is unavailable.'}
        Initialize-FastLlmProcessHost
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=$curl
        $args=@('--disable','--silent','--show-error','--fail','--proto','=https','--max-redirs','0',
            '--connect-timeout','20','--max-time','120','--max-filesize',[string]$candidate.sizeBytes,
            '--output',$partial,'--write-out','%{http_code}',[string]$candidate.url)
        $info.Arguments=Join-FastLlmProcessArguments -Arguments $args
        $info.WorkingDirectory=$run
        foreach($name in @('CURL_HOME','CURL_CA_BUNDLE','SSL_CERT_FILE','SSL_CERT_DIR')){
            $info.EnvironmentVariables.Remove($name)
        }
        $child=New-Object Bitworks.FastLlm.ProcessHost
        $watch=[Diagnostics.Stopwatch]::StartNew()
        try{
            $child.Start($info)
            while(-not $child.Process.HasExited -or -not $child.OutputCompleted){
                if($watch.Elapsed.TotalSeconds -ge 150){throw 'Microsoft prerequisite transfer exceeded its deadline.'}
                if(Test-Path -LiteralPath $partial){
                    $current=Get-Item -LiteralPath $partial -Force -ErrorAction Stop
                    if($current.Length -gt [int64]$candidate.sizeBytes){throw 'Microsoft prerequisite transfer exceeded its byte limit.'}
                }
                Start-Sleep -Milliseconds 100
            }
            if($child.OutputTruncated -or $child.Process.ExitCode -ne 0 -or $child.Snapshot().Trim() -cne '200'){
                throw 'Microsoft prerequisite transfer failed or redirected.'
            }
        }finally{$child.Dispose()}
        Assert-FastLlmVcRedistPath -Path $partial
        $item=Get-Item -LiteralPath $partial -Force -ErrorAction Stop
        if($item.Length -ne [int64]$candidate.sizeBytes){throw 'Microsoft prerequisite transfer size differs.'}
        [void](Assert-FastLlmVcRedistArtifactBounded -Path $partial -ManifestPath $ManifestPath -Candidate $candidate)
        Assert-FastLlmVcRedistPath -Path $final
        if(Test-Path -LiteralPath $final){throw 'Microsoft prerequisite final artifact already exists.'}
        Move-Item -LiteralPath $partial -Destination $final -ErrorAction Stop
        $result=Assert-FastLlmVcRedistArtifactBounded -Path $final -ManifestPath $ManifestPath -Candidate $candidate
        $succeeded=$true
        return $result
    }finally{
        # A failed fresh run is deliberately left for local inspection. Never
        # recursively delete through a potentially replaced user-writable path.
        if(-not $succeeded){Write-Verbose 'VC++ preparation failed; the private run directory was preserved.'}
    }
}
