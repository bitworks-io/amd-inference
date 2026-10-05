#requires -Version 5.1
[CmdletBinding()]
param([string]$ArchivePath,[string]$ExpectedSha256,[switch]$AllowNativeLabInstallTest)

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
if($env:OS -cne 'Windows_NT'){
    Write-Host 'SKIP: lab-app native integration requires Windows PowerShell 5.1 on Windows.'
    return
}
if(-not $AllowNativeLabInstallTest){
    Write-Host 'SKIP: pass -AllowNativeLabInstallTest with an independently reviewed local ZIP and SHA-256.'
    return
}
if($PSVersionTable.PSVersion.Major -ne 5 -or -not [Environment]::Is64BitProcess){
    throw 'Lab-app native integration requires 64-bit Windows PowerShell 5.1.'
}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if((New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    throw 'Run the lab-app native integration as a standard user.'
}
if([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA){
    throw 'Run the lab-app native integration with powershell.exe -STA.'
}
if($ExpectedSha256 -cnotmatch '^[0-9a-f]{64}$' -or [string]::IsNullOrWhiteSpace($ArchivePath)){
    throw 'Provide the exact independently reviewed lowercase ZIP SHA-256 and local archive path.'
}
if($ArchivePath -cnotmatch '^[A-Za-z]:[\\/]'){
    throw 'The reviewed ZIP must have an explicit drive-absolute local path.'
}

$repo=Split-Path $PSScriptRoot -Parent
$corePath=Join-Path $repo 'src/FastLlm.LabApp.ps1'
. $corePath
Assert-FastLlmLabLocalWindowsPath $ArchivePath
$archive=Assert-FastLlmLabAppPath $ArchivePath
if(-not (Test-Path -LiteralPath $archive -PathType Leaf) -or [IO.Path]::GetExtension($archive) -ine '.zip'){
    throw 'The reviewed local ZIP is unavailable.'
}
if((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ExpectedSha256){
    throw 'The reviewed local ZIP SHA-256 differs; no test root was created.'
}

$local=[Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
Assert-FastLlmLabLocalWindowsPath $local
$guid=[Guid]::NewGuid().ToString('N')
$evidence=Join-Path $local ('Bitworks\FastLLM-LabNativeEvidence-'+$guid)
$app=Join-Path $evidence 'app'
$shortcutDir=Join-Path $evidence 'shortcut'
$shortcut=Join-Path $shortcutDir 'FastLLM Lab.lnk'
$foreignApp=Join-Path $evidence 'foreign-app'
$foreignDir=Join-Path $evidence 'foreign-shortcut'
$foreignShortcut=Join-Path $foreignDir 'FastLLM Lab.lnk'
foreach($path in @($evidence,$app,$shortcutDir,$foreignApp,$foreignDir,$shortcut)){
    $null=Assert-FastLlmLabAppPath $path
    if(Test-Path -LiteralPath $path){throw 'Fresh native evidence path unexpectedly exists.'}
}
[void][IO.Directory]::CreateDirectory($evidence)
[void][IO.Directory]::CreateDirectory($shortcutDir)
[void][IO.Directory]::CreateDirectory($foreignDir)
$script:shell=New-Object -ComObject WScript.Shell
$checks=0
function Check([bool]$Condition,[string]$Message){
    if(-not $Condition){throw "FAIL: $Message"}
    $script:checks++
    Write-Host "PASS: $Message"
}
function Reject([scriptblock]$Action,[string]$ExpectedError,[string]$Message){
    $failure=$null
    try{& $Action | Out-Null}catch{$failure=$_}
    Check ($null -ne $failure -and ([string]$failure.Exception.Message).Contains($ExpectedError)) $Message
}
function Get-ShortcutTarget([string]$Path){
    if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){throw 'Expected shortcut is missing.'}
    $item=Get-Item -LiteralPath $Path -Force
    if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Test shortcut is a reparse point.'}
    return $script:shell.CreateShortcut($Path)
}
function Check-ManagedShortcut([string]$AppRoot,[string]$Path,$State){
    $link=Get-ShortcutTarget $Path
    $expected=[IO.Path]::GetFullPath((Join-Path (Join-Path (Join-Path $AppRoot 'versions') $State.currentVersion) 'FastLLM.cmd'))
    Check ([IO.Path]::GetFullPath([string]$link.TargetPath).Equals($expected,[StringComparison]::OrdinalIgnoreCase)) 'Shortcut targets the exact current managed launcher.'
    Check ([string]$link.Arguments -ceq '') 'Shortcut has no command arguments.'
    Check ([IO.Path]::GetFullPath([string]$link.WorkingDirectory).Equals((Split-Path $expected -Parent),[StringComparison]::OrdinalIgnoreCase)) 'Shortcut working directory is the exact current version.'
    $null=Test-FastLlmLabAppVersion $AppRoot $State.currentVersion $State.currentManifestSha256
}
function Get-NonEntrySourceFile([string]$AppRoot,$State){
    $version=Join-Path (Join-Path $AppRoot 'versions') $State.currentVersion
    $manifest=Get-Content -LiteralPath (Join-Path $version 'PACKAGE-MANIFEST.json') -Raw | ConvertFrom-Json
    $row=@($manifest.files | Where-Object {$_.path -cmatch '\.md$'} | Sort-Object path | Select-Object -First 1)
    if($row.Count -ne 1){throw 'Reviewed package lacks a non-entry Markdown source file for the test-only corruption case.'}
    $relative=([string]$row[0].path).Replace('/',[IO.Path]::DirectorySeparatorChar)
    return (Join-Path $version $relative)
}

try{
    $installed=Invoke-FastLlmLabAppCore -Action Install -AppRoot $app -ShortcutPath $shortcut -ArchivePath $archive -ExpectedSha256 $ExpectedSha256
    $first=Get-FastLlmLabAppState $app
    Check ($installed.currentVersion -ceq $first.currentVersion -and $null -eq $first.previousVersion) 'Fresh install committed one verified version.'
    $firstManifest=Get-Content -LiteralPath (Join-Path (Join-Path (Join-Path $app 'versions') $first.currentVersion) 'PACKAGE-MANIFEST.json') -Raw | ConvertFrom-Json
    Check (@($firstManifest.files).Count -ge 100) 'Installed package is a full lab application, not a tiny synthetic fixture.'
    Check-ManagedShortcut $app $shortcut $first

    $repaired=Invoke-FastLlmLabAppCore -Action Repair -AppRoot $app -ShortcutPath $shortcut -ArchivePath $archive -ExpectedSha256 $ExpectedSha256
    $second=Get-FastLlmLabAppState $app
    Check ($second.currentVersion -cne $first.currentVersion -and $second.previousVersion -ceq $first.currentVersion) 'Repair retained the prior verified version.'
    Check ((Test-Path -LiteralPath (Join-Path (Join-Path $app 'versions') $first.currentVersion) -PathType Container)) 'Repair did not delete the retained version.'
    Check-ManagedShortcut $app $shortcut $second

    $rolled=Invoke-FastLlmLabAppCore -Action Rollback -AppRoot $app -ShortcutPath $shortcut
    $afterRollback=Get-FastLlmLabAppState $app
    Check ($rolled.currentVersion -ceq $first.currentVersion -and $afterRollback.previousVersion -ceq $second.currentVersion) 'Healthy rollback selected the original retained version.'
    Check-ManagedShortcut $app $shortcut $afterRollback

    # Test-only interruption after shortcut update but before the state commit.
    # The core is re-dot-sourced in finally so the injected function cannot escape this test.
    $script:originalWrite=(Get-Command Write-FastLlmLabAppJsonAtomic -ErrorAction Stop).ScriptBlock
    $script:injectStateWrite=$true
    function Write-FastLlmLabAppJsonAtomic {
        param([string]$Path,$Value)
        if($script:injectStateWrite -and [IO.Path]::GetFileName($Path) -ceq 'lab-app.json'){
            $script:injectStateWrite=$false
            throw 'TEST-ONLY interrupted state commit after shortcut update.'
        }
        & $script:originalWrite -Path $Path -Value $Value
    }
    try{
        Reject {Invoke-FastLlmLabAppCore -Action Repair -AppRoot $app -ShortcutPath $shortcut -ArchivePath $archive -ExpectedSha256 $ExpectedSha256} 'TEST-ONLY interrupted state commit' 'Injected post-shortcut state-write interruption stopped Repair.'
    }finally{. $corePath}
    $journalPath=Join-Path $app 'lab-app-journal.json'
    $journal=Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
    $interrupted=Get-FastLlmLabAppState $app
    Check ($interrupted.currentVersion -ceq $afterRollback.currentVersion -and $journal.targetVersion -cne $interrupted.currentVersion) 'Interrupted transition retained prior state and a distinct journal target.'
    $interruptedLink=Get-ShortcutTarget $shortcut
    $interruptedTarget=[IO.Path]::GetFullPath((Join-Path (Join-Path (Join-Path $app 'versions') $journal.targetVersion) 'FastLLM.cmd'))
    Check ([IO.Path]::GetFullPath([string]$interruptedLink.TargetPath).Equals($interruptedTarget,[StringComparison]::OrdinalIgnoreCase)) 'Interrupted shortcut reached only the journal-recorded verified target.'
    $recovered=Invoke-FastLlmLabAppCore -Action Rollback -AppRoot $app -ShortcutPath $shortcut
    $afterRecovery=Get-FastLlmLabAppState $app
    Check ($recovered.currentVersion -ceq $afterRollback.currentVersion -and $afterRecovery.previousVersion -ceq $journal.targetVersion -and
           -not (Test-Path -LiteralPath $journalPath)) 'Next action recovered interrupted transition before safe rollback.'
    Check-ManagedShortcut $app $shortcut $afterRecovery

    $sourceFile=Get-NonEntrySourceFile $app $afterRecovery
    $originalCopy=Join-Path $evidence 'test-only-original-source-copy.bin'
    [IO.File]::Copy($sourceFile,$originalCopy,$false)
    $originalHash=(Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::AppendAllText($sourceFile,"`r`nTEST-ONLY-CORRUPTION-$guid",[Text.Encoding]::UTF8)
    Check ((Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash.ToLowerInvariant() -cne $originalHash) 'Only a recorded non-entry source file was deliberately modified.'
    $fixed=Invoke-FastLlmLabAppCore -Action Repair -AppRoot $app -ShortcutPath $shortcut -ArchivePath $archive -ExpectedSha256 $ExpectedSha256
    $afterFix=Get-FastLlmLabAppState $app
    Check ($fixed.currentVersion -ceq $afterFix.currentVersion -and $afterFix.previousVersion -ceq $afterRecovery.currentVersion) 'Repair replaced a damaged current version and retained it for review.'
    Check-ManagedShortcut $app $shortcut $afterFix
    Reject {Invoke-FastLlmLabAppCore -Action Rollback -AppRoot $app -ShortcutPath $shortcut} 'Managed lab-app version file differs from its manifest.' 'Rollback refused the deliberately damaged prior version.'
    Check-ManagedShortcut $app $shortcut (Get-FastLlmLabAppState $app)

    $foreign=[IO.Path]::GetFullPath((Join-Path $env:SystemRoot 'System32\notepad.exe'))
    $foreignLink=$script:shell.CreateShortcut($foreignShortcut)
    $foreignLink.TargetPath=$foreign;$foreignLink.Arguments='';$foreignLink.Save()
    $foreignHash=(Get-FileHash -LiteralPath $foreignShortcut -Algorithm SHA256).Hash.ToLowerInvariant()
    # A non-managed System32 target is rejected at the managed-version leaf check
    # before the later target/argument-specific shortcut refusal message.
    Reject {Invoke-FastLlmLabAppCore -Action Install -AppRoot $foreignApp -ShortcutPath $foreignShortcut -ArchivePath $archive -ExpectedSha256 $ExpectedSha256} 'Invalid managed lab-app version ID.' 'Installer refused an unrelated existing shortcut.'
    Check ((Get-FileHash -LiteralPath $foreignShortcut -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $foreignHash) 'Unrelated shortcut bytes were not replaced.'

    $record=[ordered]@{kind='lab-app-native-test-evidence';archiveSha256=$ExpectedSha256;
        appRoot=$app;shortcutPath=$shortcut;originalSourceCopy=$originalCopy;
        installedVersion=$first.currentVersion;repairedVersion=$second.currentVersion;
        interruptedVersion=$journal.targetVersion;finalVersion=$afterFix.currentVersion;
        damagedRetainedVersion=$afterFix.previousVersion;checks=$checks;
        publicReleaseApproved=$false;modelOrEngineExecuted=$false}
    $report=Join-Path $evidence 'native-test-result.json'
    $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $record -Depth 5))
    $stream=[IO.File]::Open($report,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
    Write-Host "Lab app native integration checks: $checks passed. Evidence retained at $evidence"
}catch{
    Write-Host "Lab app native integration stopped; isolated evidence retained at $evidence"
    throw
}
