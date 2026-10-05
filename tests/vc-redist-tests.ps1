#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$repo=Split-Path $PSScriptRoot -Parent
$helper=Join-Path $repo 'src/FastLlm.VcRedist.ps1'
$tool=Join-Path $repo 'tools/prepare-vc-runtime.ps1'
foreach($path in @($helper,$tool)){
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    if(@($errors).Count){throw "Parser errors in $path"}
}
. $helper
$count=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:count++}
function Reject([scriptblock]$Action,[string]$Message){
    $failed=$false
    try{& $Action|Out-Null}catch{$failed=$true}
    Check $failed $Message
}
$manifestPath=Join-Path $repo 'config/windows-prerequisites.json'
$candidate=Get-FastLlmVcRedistCandidate -ManifestPath $manifestPath
Check ([string]$candidate.url -ceq 'https://download.visualstudio.microsoft.com/download/pr/ebdab8e5-1d7b-4d9f-a11b-cbb1720c3b12/843068991DAAA1F73AD9F6239BCE4D0F6A07A51F18C37EA2A867E9BECA71295C/VC_redist.x64.exe') 'Exact Microsoft CDN URL pin changed.'
Check ([int64]$candidate.sizeBytes -eq 18731856 -and [string]$candidate.sha256 -ceq '843068991daaa1f73ad9f6239bce4d0f6a07a51f18c37ea2a867e9beca71295c') 'Exact size/hash pin changed.'
Check ([string]$candidate.version -ceq '14.51.36247.0' -and
       [string]$candidate.signerThumbprint -ceq '1D77A9B9E8FE2075D9AD15123257FB90DB0DA4A1') 'Version/certificate pin changed.'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('fastllm-vc-test-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -ErrorAction Stop|Out-Null
try{
    $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
    foreach($case in @(
        @{field='url';value='https://evil.example/vc_redist.x64.exe'},
        @{field='url';value='http://download.visualstudio.microsoft.com/x'},
        @{field='url';value=[string]$candidate.url+'?changed=1'},
        @{field='sizeBytes';value=1},
        @{field='sizeBytes';value='18731856'},
        @{field='sha256';value='0'*64},
        @{field='version';value='14.50.35719.0'},
        @{field='signerSubject';value='CN=Other'},
        @{field='signerThumbprint';value='0'*40}
    )){
        $copy=($manifest|ConvertTo-Json -Depth 8|ConvertFrom-Json)
        $copy.vcRedistX64.($case.field)=$case.value
        $path=Join-Path $fixture ('manifest-'+$case.field+'-'+[Guid]::NewGuid().ToString('N')+'.json')
        $copy|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $path -Encoding UTF8
        Reject {Get-FastLlmVcRedistCandidate -ManifestPath $path} "Changed candidate $($case.field) was accepted."
    }
    $copy=($manifest|ConvertTo-Json -Depth 8|ConvertFrom-Json)
    $copy.installerExecutionEnabled=$true
    $path=Join-Path $fixture 'enabled.json'
    $copy|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $path -Encoding UTF8
    Reject {Get-FastLlmVcRedistCandidate -ManifestPath $path} 'Installer execution was enabled in candidate policy.'
    $copy=($manifest|ConvertTo-Json -Depth 8|ConvertFrom-Json)
    $copy.schemaVersion='1'
    $path=Join-Path $fixture 'string-schema.json'
    $copy|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $path -Encoding UTF8
    Reject {Get-FastLlmVcRedistCandidate -ManifestPath $path} 'String schema version was accepted.'
    $copy=($manifest|ConvertTo-Json -Depth 8|ConvertFrom-Json)
    $copy.installerExecutionEnabled='false'
    $path=Join-Path $fixture 'string-enabled.json'
    $copy|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $path -Encoding UTF8
    Reject {Get-FastLlmVcRedistCandidate -ManifestPath $path} 'String execution policy was accepted.'
    $missing=Join-Path $fixture 'missing.json'
    Reject {Get-FastLlmVcRedistCandidate -ManifestPath $missing} 'Missing candidate manifest was accepted.'
    $bad=Join-Path $fixture 'bad.exe'
    [IO.File]::WriteAllBytes($bad,[byte[]]@(1,2,3))
    Reject {Assert-FastLlmVcRedistArtifact -Path $bad -Candidate $candidate} 'Bad local artifact was accepted.'
    $alias=Join-Path $fixture 'alias'
    try{
        New-Item -ItemType SymbolicLink -Path $alias -Target $fixture -ErrorAction Stop|Out-Null
        Reject {Assert-FastLlmVcRedistPath -Path (Join-Path $alias 'bad.exe')} 'Reparse ancestor was accepted.'
    }catch{
        # Symlink creation may require a Windows developer setting; all other
        # path tests still run. A successful creation must not mask assertion failure.
        if(Test-Path -LiteralPath $alias){throw}
    }
    Reject {Assert-FastLlmVcRedistPath -Path 'relative\file.exe'} 'Relative preparation path was accepted.'
    Reject {Assert-FastLlmVcRedistHostState -WindowsHost $false -Host64Bit $true -Elevated $false} 'Non-Windows host was accepted.'
    Reject {Assert-FastLlmVcRedistHostState -WindowsHost $true -Host64Bit $false -Elevated $false} '32-bit host was accepted.'
    Reject {Assert-FastLlmVcRedistHostState -WindowsHost $true -Host64Bit $true -Elevated $true} 'Elevated host was accepted.'
    Assert-FastLlmVcRedistHostState -WindowsHost $true -Host64Bit $true -Elevated $false
    $metadata=@{ActualLength=[int64]$candidate.sizeBytes;ActualHash=[string]$candidate.sha256;
        FileVersion=[string]$candidate.version;ProductVersion=[string]$candidate.version;
        SignatureStatus='Valid';SignerSubject=[string]$candidate.signerSubject;
        SignerThumbprint=[string]$candidate.signerThumbprint;Candidate=$candidate}
    Assert-FastLlmVcRedistMetadata @metadata
    $count++
    foreach($case in @(
        @{field='ActualLength';value=1},@{field='ActualHash';value='0'*64},
        @{field='FileVersion';value='14.50.35719.0'},@{field='ProductVersion';value='14.50.35719.0'},
        @{field='SignatureStatus';value='NotTrusted'},@{field='SignerSubject';value='CN=Other'},
        @{field='SignerThumbprint';value='0'*40}
    )){
        $changed=@{}+$metadata
        $changed[$case.field]=$case.value
        Reject {Assert-FastLlmVcRedistMetadata @changed} "Bad $($case.field) metadata was accepted."
    }
    $source=Get-Content -LiteralPath $helper -Raw
    Check ($source.Contains("'--max-redirs','0'") -and $source.Contains("'--max-filesize'") -and
           $source.Contains("'--max-time','120'") -and $source.Contains("-cne '200'") -and
           -not $source.Contains("'--location'")) 'No-redirect, transfer bounds, and HTTP 200 gate are required.'
    Check ($source.Contains("Join-Path ([Environment]::SystemDirectory) 'curl.exe'") -and
           -not $source.Contains('$env:SystemRoot') -and
           $source.Contains('Assert-FastLlmVcRedistPath -Path $curl') -and
           $source.Contains('$curlItem.PSIsContainer') -and
           $source.Contains('[IO.FileAttributes]::ReparsePoint')) 'Downloader must be the regular OS SystemDirectory executable.'
    $verifyPartial=$source.IndexOf('Assert-FastLlmVcRedistArtifactBounded -Path $partial')
    $move=$source.IndexOf('Move-Item -LiteralPath $partial -Destination $final')
    $verifyFinal=$source.IndexOf('Assert-FastLlmVcRedistArtifactBounded -Path $final')
    Check ($verifyPartial -ge 0 -and $verifyPartial -lt $move -and $move -lt $verifyFinal) 'Verify the partial before the move and the final after it.'
    Check ($source.Contains("$([char]36)watch.Elapsed.TotalSeconds -ge 30") -and
           $source.Contains("$([char]36)child.Dispose()") -and
           $source.Contains("-cne 'vc-redist-verified'")) 'Metadata and Authenticode validation must use a bounded worker.'
    Check (-not $source.Contains('Start-Process') -and -not $source.Contains('Verb RunAs') -and
           -not $source.Contains('Process.Start(')) 'Preparation helper must not execute the installer.'
    $wrapper=Get-Content -LiteralPath $tool -Raw
    Check ($wrapper.Contains('[switch]$InternalWorker') -and
           $wrapper.Contains('Assert-FastLlmVcRedistArtifact -Path $ArtifactPath') -and
           $wrapper.Contains('Assert-FastLlmVcRedistArtifactBounded -Path $Path') -and
           $wrapper.Contains("[Console]::Out.WriteLine('vc-redist-verified')")) 'Worker must validate exact bytes and return only a fixed marker.'
    Check ($wrapper.Contains("status='prepared-not-installed'") -eq $false -and
           $source.Contains("status='prepared-not-installed'")) 'Prepared status must be returned by verified artifact helper only.'
}finally{
    # This test created the exact random folder; only it is removed.
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "VC redist preparation tests passed: $count"
