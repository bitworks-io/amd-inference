#requires -Version 5.1
# Real standard-user Windows CLI boundary only. Deliberately wrong provenance
# cannot reach engine acquisition, model acquisition, a receipt, or GPU probing.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
if($env:OS -ne 'Windows_NT'){
    Write-Output 'SKIP: Windows-only native CLI consent boundary; no child or acquisition ran.'
    exit 0
}
if($PSVersionTable.PSVersion.Major -ne 5){
    Write-Output 'SKIP: this native CLI consent boundary targets Windows PowerShell 5.1.'
    exit 0
}
if(-not [Environment]::Is64BitProcess){throw 'Run native CLI boundary tests in 64-bit PowerShell.'}
$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    throw 'Run native CLI boundary tests as a standard Windows user.'
}
$root=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force -PassThru
& $module { Initialize-FastLlmProcessHost }
$cli=Join-Path $root 'fast-llm.ps1'
$modelId='qwen3.8-27b-ud-q4-k-m'
$wrongDigest=('0'*64)
$checks=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:checks++}

function Invoke-BoundedCli([string[]]$CliArguments){
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=(Get-Process -Id $PID).Path
    $argv=@('-NoLogo','-NoProfile','-NonInteractive','-OutputFormat','Text','-File',$cli)+$CliArguments
    $info.Arguments=& $module {param($A) Join-FastLlmProcessArguments $A} $argv
    $info.WorkingDirectory=$root
    $info.UseShellExecute=$false
    $info.CreateNoWindow=$true
    $child=New-Object Bitworks.FastLlm.ProcessHost
    $watch=[Diagnostics.Stopwatch]::StartNew()
    try{
        $child.Start($info)
        while(-not $child.Process.HasExited -and $watch.ElapsedMilliseconds -lt 30000){
            [void]$child.Process.WaitForExit(100)
        }
        if(-not $child.Process.HasExited){throw 'CLI negative child exceeded its 30-second deadline.'}
        while(-not $child.OutputCompleted -and $watch.ElapsedMilliseconds -lt 30000){Start-Sleep -Milliseconds 20}
        if(-not $child.OutputCompleted -or $child.OutputTruncated){throw 'CLI negative child output was incomplete.'}
        return [pscustomobject]@{exitCode=$child.Process.ExitCode;text=$child.Snapshot()}
    }finally{$child.Dispose()}
}

$testParent=Join-Path ([IO.Path]::GetTempPath()) ('fastllm-ui-cli-native-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testParent -ErrorAction Stop|Out-Null
try{
    $catalog=Get-FastLlmCatalog (Join-Path $root 'config/catalog.json')
    $model=@($catalog.models|Where-Object {[string]$_.id -ceq $modelId})
    Check ($model.Count -eq 1) 'The real catalog contains exactly one reviewed Q4 model.'
    . (Join-Path $root 'src/FastLlm.UiFlow.ps1')
    $actual=Get-FastLlmUiModelProvenanceDigest -Model $model[0]
    if($actual -ceq $wrongDigest){$wrongDigest=('f'*64)}
    Check ($actual -cne $wrongDigest) 'The negative digest differs from current catalog provenance.'

    $rejectedRoot=Join-Path $testParent 'wrong-digest'
    $result=Invoke-BoundedCli @('install','-ModelId',$modelId,'-InstallRoot',$rejectedRoot,
        '-AcceptModelLicense','-Unattended','-ExpectedModelProvenanceSha256',$wrongDigest)
    Check ($result.exitCode -ne 0 -and $result.text -match 'selected model provenance changed after license review') 'Real CLI rejected the wrong exact digest.'
    foreach($name in @('engines','downloads','models','consents')){
        Check (-not (Test-Path -LiteralPath (Join-Path $rejectedRoot $name))) "Rejected consent created no $name acquisition directory."
    }
    $lock=Enter-FastLlmOperation -InstallRoot $rejectedRoot
    try{Check ($null -ne $lock) 'Failed CLI released its operation lock.'}finally{$lock.Dispose()}

    $invalid=@(
        @{label='missing explicit acceptance';args=@('install','-ModelId',$modelId,'-ExpectedModelProvenanceSha256',$wrongDigest)},
        @{label='wrong action';args=@('start','-ModelId',$modelId,'-AcceptModelLicense','-ExpectedModelProvenanceSha256',$wrongDigest)},
        @{label='engine-only';args=@('install','-EngineOnly','-ModelId',$modelId,'-AcceptModelLicense','-ExpectedModelProvenanceSha256',$wrongDigest)},
        @{label='malformed digest';args=@('install','-ModelId',$modelId,'-AcceptModelLicense','-ExpectedModelProvenanceSha256','bad')}
    )
    for($index=0;$index -lt $invalid.Count;$index++){
        $entry=$invalid[$index]
        $path=Join-Path $testParent ('invalid-'+$index)
        $result=Invoke-BoundedCli (@($entry.args)+@('-InstallRoot',$path))
        Check ($result.exitCode -ne 0 -and $result.text -match 'ExpectedModelProvenanceSha256') "$($entry.label) combination was rejected."
        Check (-not (Test-Path -LiteralPath $path)) "$($entry.label) created no install root."
    }
    Write-Output "Native CLI consent boundary passed: $checks checks; no positive install or native model execution."
}finally{
    if(Test-Path -LiteralPath $testParent){Remove-Item -LiteralPath $testParent -Recurse -Force}
}
