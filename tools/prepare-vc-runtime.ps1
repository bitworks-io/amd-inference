#requires -Version 5.1
# Private lab preparation only. Never executes Microsoft's installer.
[CmdletBinding()]
param([ValidateSet('Prepare','Validate')][string]$Action='Prepare',
      [string]$CacheRoot,[string]$ArtifactPath,[switch]$InternalWorker)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$repo=Split-Path $PSScriptRoot -Parent
$helper=Join-Path $repo 'src/FastLlm.VcRedist.ps1'
$manifest=Join-Path $repo 'config/windows-prerequisites.json'
if($InternalWorker){
    # Read-only child. Its output is deliberately a fixed success marker; never
    # print a certificate, path, exception, or downloaded content to the parent.
    try{
        if($Action -cne 'Validate' -or $CacheRoot -or -not $ArtifactPath){exit 1}
        . $helper
        Assert-FastLlmVcRedistStandardWindows
        $candidate=Get-FastLlmVcRedistCandidate -ManifestPath $manifest
        [void](Assert-FastLlmVcRedistArtifact -Path $ArtifactPath -Candidate $candidate)
        [Console]::Out.WriteLine('vc-redist-verified')
        exit 0
    }catch{exit 1}
}
$module=Import-Module (Join-Path $repo 'src/FastLlm.psm1') -PassThru -ErrorAction Stop
if($Action -ceq 'Prepare'){
    if($ArtifactPath){throw 'Prepare does not accept an existing artifact path.'}
    if(-not $CacheRoot){
        $CacheRoot=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'Bitworks\FastLLM\prerequisites'
    }
    $result=& $module {param($Source,$Config,$Root)
        . $Source
        Invoke-FastLlmVcRedistPrepare -ManifestPath $Config -CacheRoot $Root
    } $helper $manifest $CacheRoot
}else{
    if($CacheRoot -or -not $ArtifactPath){throw 'Validate requires only -ArtifactPath.'}
    $result=& $module {param($Source,$Config,$Path)
        . $Source
        Assert-FastLlmVcRedistStandardWindows
        $candidate=Get-FastLlmVcRedistCandidate -ManifestPath $Config
        Assert-FastLlmVcRedistArtifactBounded -Path $Path -ManifestPath $Config -Candidate $candidate
    } $helper $manifest $ArtifactPath
}
$result | ConvertTo-Json -Depth 4
