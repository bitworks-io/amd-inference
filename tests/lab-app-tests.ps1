#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/FastLlm.LabApp.ps1')
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$checks=0
$script:failNextShortcut=$false
function Check([bool]$condition,[string]$message){if(-not $condition){throw $message};$script:checks++}
function Reject([scriptblock]$action,[string]$message){$bad=$false;try{& $action|Out-Null}catch{$bad=$true};Check $bad $message}

# A test-only shortcut adapter avoids COM and Windows shell mutation on macOS.
function Set-FastLlmLabShortcut {
    param([string]$ShortcutPath,[string]$AppRoot,[string]$Version,[string]$ManifestSha256)
    $null=Test-FastLlmLabAppVersion $AppRoot $Version $ManifestSha256
    $existing=if(Test-Path -LiteralPath $ShortcutPath){Get-Content -LiteralPath $ShortcutPath -Raw}else{$null}
    if($existing){
        $state=Get-FastLlmLabAppState $AppRoot
        $journalPath=Join-Path $AppRoot 'lab-app-journal.json'
        $journal=if(Test-Path -LiteralPath $journalPath){Get-Content -LiteralPath $journalPath -Raw|ConvertFrom-Json}else{$null}
        $oldTarget=Join-Path (Join-Path (Join-Path $AppRoot 'versions') $existing) 'FastLLM.cmd'
        $null=Assert-FastLlmLabShortcutOwnership -TargetPath $oldTarget -Arguments '' -AppRoot $AppRoot -State $state -Journal $journal
    }
    if($script:failNextShortcut){$script:failNextShortcut=$false;throw 'Injected interrupted shortcut write.'}
    [IO.File]::WriteAllText($ShortcutPath,$Version)
    return $ShortcutPath
}

function New-TestPackage([string]$Directory,[string]$ZipName,[bool]$BomManifest=$false){
    $payload=Join-Path $Directory ('payload-'+[Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory((Join-Path $payload 'src'))
    [void][IO.Directory]::CreateDirectory((Join-Path $payload 'config'))
    $files=@('FastLLM.cmd','fast-llm-ui.ps1','fast-llm.ps1','src/FastLlm.psm1','config/catalog.json')
    $rows=@()
    foreach($name in $files){
        $path=Join-Path $payload $name
        [IO.File]::WriteAllText($path,"source $name")
        $rows+=@{path=$name;sizeBytes=[long](Get-Item -LiteralPath $path).Length;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
    }
    $manifest=@{schemaVersion=1;kind='unsigned-private-windows-lab-package';physicalQualification=$false;publicReleaseApproved=$false;
        generatedAt='2026-10-05T00:00:00Z';sourceLicenseDecision='pending-bitworks';files=$rows}
    $manifestText=ConvertTo-Json -InputObject $manifest -Depth 8 -Compress
    if($BomManifest){
        $utf8=New-Object Text.UTF8Encoding($true)
        [IO.File]::WriteAllBytes((Join-Path $payload 'PACKAGE-MANIFEST.json'),($utf8.GetPreamble()+$utf8.GetBytes($manifestText)))
    }else{[IO.File]::WriteAllText((Join-Path $payload 'PACKAGE-MANIFEST.json'),$manifestText)}
    $zip=Join-Path $Directory $ZipName
    # .NET Framework ZipFile.CreateFromDirectory uses Windows separators for entry names.
    # The production verifier deliberately requires canonical forward-slash ZIP paths.
    $zipStream=New-Object IO.FileStream($zip,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{
        $archive=New-Object IO.Compression.ZipArchive($zipStream,[IO.Compression.ZipArchiveMode]::Create,$true)
        try{
            foreach($name in @($files + 'PACKAGE-MANIFEST.json')){
                $entry=$archive.CreateEntry($name)
                $inputStream=[IO.File]::OpenRead((Join-Path $payload $name))
                try{
                    $outputStream=$entry.Open()
                    try{$inputStream.CopyTo($outputStream)}finally{$outputStream.Dispose()}
                }finally{$inputStream.Dispose()}
            }
        }finally{$archive.Dispose()}
    }finally{$zipStream.Dispose()}
    return [pscustomobject]@{path=$zip;sha256=(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()}
}
function Add-TestZipEntry([string]$Zip,[string]$Name){
    $archive=[IO.Compression.ZipFile]::Open($Zip,[IO.Compression.ZipArchiveMode]::Update)
    try{
        $entry=$archive.CreateEntry($Name)
        $stream=$entry.Open()
        try{$bytes=[Text.Encoding]::UTF8.GetBytes('extra');$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
    }finally{$archive.Dispose()}
}

$tempBase=if([IO.Directory]::Exists('/private/tmp')){'/private/tmp'}else{[IO.Path]::GetTempPath()}
$temp=Join-Path $tempBase ('fastllm-lab-app-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
try{
    $app=Join-Path $temp 'app';$shortcut=Join-Path $temp 'shortcut.lnk'
    $first=New-TestPackage $temp 'first.zip'
    $second=New-TestPackage $temp 'second.zip'
    $bom=New-TestPackage $temp 'bom.zip' $true
    Reject {Assert-FastLlmLabPackagePath '../x.ps1'} 'Parent traversal accepted.'
    Reject {Assert-FastLlmLabPackagePath 'src//x.ps1'} 'Empty path component accepted.'
    Reject {Assert-FastLlmLabPackagePath 'src/CON.txt'} 'Reserved Win32 device accepted.'
    Reject {Assert-FastLlmLabPackagePath 'src/x. '} 'Win32 trailing dot/space accepted.'
    Reject {Assert-FastLlmLabPackagePath 'src\x.ps1'} 'Backslash accepted.'
    Reject {Assert-FastLlmLabPackagePath 'C:/x.ps1'} 'Drive path accepted.'
    Reject {Assert-FastLlmLabPackagePath 'src/x.ps1:stream'} 'Alternate data stream accepted.'
    Reject {Expand-FastLlmLabVerifiedPackage -ArchivePath $first.path -ExpectedSha256 ('0'*64) -Stage (Join-Path $temp 'badstage')} 'Wrong operator ZIP digest accepted.'
    Check (-not (Test-Path -LiteralPath (Join-Path $temp 'badstage'))) 'Stage created before ZIP digest review.'
    foreach($name in @('../escape.ps1','SRC/FastLlm.psm1','src/CON.txt','docs/a.md')){
        $bad=Join-Path $temp ('bad-'+[Guid]::NewGuid().ToString('N')+'.zip')
        Copy-Item -LiteralPath $first.path -Destination $bad
        Add-TestZipEntry $bad $name
        $badSha=(Get-FileHash -LiteralPath $bad -Algorithm SHA256).Hash.ToLowerInvariant()
        $badStage=Join-Path $temp ('badstage-'+[Guid]::NewGuid().ToString('N'))
        Reject {Expand-FastLlmLabVerifiedPackage -ArchivePath $bad -ExpectedSha256 $badSha -Stage $badStage} "Unsafe/extra ZIP member $name accepted."
        Check (-not (Test-Path -LiteralPath $badStage)) 'Unsafe ZIP reached staging.'
    }
    $ancestor=Join-Path $temp 'ancestor.zip'
    Copy-Item -LiteralPath $first.path -Destination $ancestor
    Add-TestZipEntry $ancestor 'docs/a.md'
    Add-TestZipEntry $ancestor 'docs/a.md/nested.json'
    $ancestorSha=(Get-FileHash -LiteralPath $ancestor -Algorithm SHA256).Hash.ToLowerInvariant()
    $ancestorStage=Join-Path $temp 'ancestor-stage'
    Reject {Expand-FastLlmLabVerifiedPackage -ArchivePath $ancestor -ExpectedSha256 $ancestorSha -Stage $ancestorStage} 'File-as-directory ZIP ancestor accepted.'
    Check (-not (Test-Path -LiteralPath $ancestorStage)) 'File-as-directory ZIP reached stage.'
    $stage=Join-Path $temp 'verifiedstage'
    $verified=Expand-FastLlmLabVerifiedPackage -ArchivePath $first.path -ExpectedSha256 $first.sha256 -Stage $stage
    Check ($verified.files -eq 5 -and (Test-Path -LiteralPath (Join-Path $stage 'FastLLM.cmd'))) 'Verified extraction missing exact files.'
    $plainManifest=[IO.File]::ReadAllBytes((Join-Path $stage 'PACKAGE-MANIFEST.json'))
    Check ($plainManifest.Length -gt 0 -and $plainManifest[0] -eq [byte][char]'{') 'No-BOM manifest lost its opening JSON brace.'
    $bomStage=Join-Path $temp 'bom-stage'
    $bomVerified=Expand-FastLlmLabVerifiedPackage -ArchivePath $bom.path -ExpectedSha256 $bom.sha256 -Stage $bomStage
    Check ($bomVerified.files -eq 5 -and (Get-FileHash -LiteralPath (Join-Path $bomStage 'PACKAGE-MANIFEST.json') -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $bomVerified.manifestSha256) 'PS5.1 UTF-8-BOM manifest bytes were not preserved.'
    $bomBytes=[IO.File]::ReadAllBytes((Join-Path $bomStage 'PACKAGE-MANIFEST.json'))
    Check ($bomBytes.Length -ge 4 -and $bomBytes[0] -eq 0xEF -and $bomBytes[1] -eq 0xBB -and $bomBytes[2] -eq 0xBF -and $bomBytes[3] -eq [byte][char]'{') 'UTF-8-BOM manifest was not decoded and retained correctly.'
    $linkStage=Join-Path $temp 'linked-stage';$linkTarget=Join-Path $temp 'outside-stage'
    [void][IO.Directory]::CreateDirectory($linkTarget)
    $linkCreated=$false
    try{New-Item -ItemType SymbolicLink -Path $linkStage -Target $linkTarget -ErrorAction Stop|Out-Null;$linkCreated=$true}catch{}
    if($linkCreated){
        Reject {Expand-FastLlmLabVerifiedPackage -ArchivePath $first.path -ExpectedSha256 $first.sha256 -Stage $linkStage} 'Reparse-point stage accepted.'
        Check (-not (Test-Path -LiteralPath (Join-Path $linkTarget 'FastLLM.cmd'))) 'Reparse-point stage redirected extraction.'
    }
    $installed=Invoke-FastLlmLabAppCore -Action Install -ArchivePath $first.path -ExpectedSha256 $first.sha256 -AppRoot $app -ShortcutPath $shortcut
    Check ($installed.currentVersion -cmatch '^[0-9a-f]{64}-[0-9a-f]{32}$' -and $null -eq $installed.previousVersion -and -not $installed.publicReleaseApproved) 'First install state is invalid.'
    Check ((Get-Content -LiteralPath $shortcut -Raw) -ceq $installed.currentVersion) 'Owned shortcut did not target installed version.'
    $ownedState=Get-FastLlmLabAppState $app
    $ownedTarget=Join-Path (Join-Path (Join-Path $app 'versions') $installed.currentVersion) 'FastLLM.cmd'
    Check ((Assert-FastLlmLabShortcutOwnership -TargetPath $ownedTarget -Arguments '' -AppRoot $app -State $ownedState -Journal $null) -ceq $installed.currentVersion) 'Recorded shortcut ownership was not accepted.'
    Reject {Assert-FastLlmLabShortcutOwnership -TargetPath $ownedTarget -Arguments '/c evil' -AppRoot $app -State $ownedState -Journal $null} 'Shortcut arguments were accepted as owned.'
    Reject {Assert-FastLlmLabShortcutOwnership -TargetPath (Join-Path (Split-Path $ownedTarget -Parent) 'other.cmd') -Arguments '' -AppRoot $app -State $ownedState -Journal $null} 'Other command target was accepted as owned.'
    Reject {Assert-FastLlmLabShortcutOwnership -TargetPath (Join-Path (Join-Path $app 'versions') (('f'*64)+'-'+('a'*32))) -Arguments '' -AppRoot $app -State $ownedState -Journal $null} 'Unrecorded version target was accepted as owned.'
    $repaired=Invoke-FastLlmLabAppCore -Action Repair -ArchivePath $second.path -ExpectedSha256 $second.sha256 -AppRoot $app -ShortcutPath $shortcut
    Check ($repaired.previousVersion -ceq $installed.currentVersion -and $repaired.currentVersion -cne $installed.currentVersion) 'Repair did not retain previous version.'
    Check ((Test-Path -LiteralPath (Join-Path (Join-Path $app 'versions') $installed.currentVersion))) 'Repair removed retained version.'
    $committed=Get-FastLlmLabAppState $app
    $journal=@{schemaVersion=1;kind='fastllm-private-lab-app-transition';installId=$committed.installId;
        targetVersion=$committed.currentVersion;targetManifestSha256=$committed.currentManifestSha256;
        previousVersion=$committed.previousVersion;previousManifestSha256=$committed.previousManifestSha256}
    Write-FastLlmLabAppJsonAtomic -Path (Join-Path $app 'lab-app-journal.json') -Value $journal
    $rolled=Invoke-FastLlmLabAppCore -Action Rollback -AppRoot $app -ShortcutPath $shortcut
    Check ($rolled.currentVersion -ceq $installed.currentVersion -and $rolled.previousVersion -ceq $repaired.currentVersion) 'Rollback did not select exact prior version.'
    Check (-not (Test-Path -LiteralPath (Join-Path $app 'lab-app-journal.json'))) 'Committed transaction recovery left a journal.'
    Reject {Invoke-FastLlmLabAppCore -Action Install -ArchivePath $first.path -ExpectedSha256 $first.sha256 -AppRoot $app -ShortcutPath $shortcut} 'Install overwrote an existing managed app.'
    Reject {Invoke-FastLlmLabAppCore -Action Repair -ArchivePath $first.path -ExpectedSha256 ('0'*64) -AppRoot $app -ShortcutPath $shortcut} 'Repair accepted a wrong exact hash.'
    $oldPath=Join-Path (Join-Path (Join-Path $app 'versions') $rolled.previousVersion) 'FastLLM.cmd'
    $priorManifest=Join-Path (Split-Path $oldPath -Parent) 'PACKAGE-MANIFEST.json'
    $priorManifestBytes=[IO.File]::ReadAllBytes($priorManifest)
    [IO.File]::WriteAllText($priorManifest,([Text.Encoding]::UTF8.GetString($priorManifestBytes)).Replace('pending-bitworks','other-license'))
    Reject {Invoke-FastLlmLabAppCore -Action Rollback -AppRoot $app -ShortcutPath $shortcut} 'Changed retained manifest was accepted for rollback.'
    [IO.File]::WriteAllBytes($priorManifest,$priorManifestBytes)
    [IO.File]::WriteAllText($oldPath,'changed')
    Reject {Invoke-FastLlmLabAppCore -Action Rollback -AppRoot $app -ShortcutPath $shortcut} 'Changed prior version was accepted for rollback.'
    Check (-not (Test-Path -LiteralPath (Join-Path $app 'lab-app-journal.json'))) 'Completed transaction left a journal.'
    $currentPath=Join-Path (Join-Path (Join-Path $app 'versions') $rolled.currentVersion) 'FastLLM.cmd'
    [IO.File]::WriteAllText($currentPath,'damaged-current-app')
    $script:failNextShortcut=$true
    Reject {Invoke-FastLlmLabAppCore -Action Repair -ArchivePath $second.path -ExpectedSha256 $second.sha256 -AppRoot $app -ShortcutPath $shortcut} 'Injected shortcut interruption did not stop repair.'
    Check (Test-Path -LiteralPath (Join-Path $app 'lab-app-journal.json')) 'Interrupted repair lost its recovery journal.'
    Reject {Invoke-FastLlmLabAppCore -Action Rollback -AppRoot $app -ShortcutPath $shortcut} 'Rollback accepted damaged prior app after recovering repair.'
    $recoveredRepair=Get-FastLlmLabAppState $app
    Check ($recoveredRepair.currentVersion -cne $rolled.currentVersion -and $recoveredRepair.previousVersion -ceq $rolled.currentVersion -and
           (Get-Content -LiteralPath $shortcut -Raw) -ceq $recoveredRepair.currentVersion -and
           -not (Test-Path -LiteralPath (Join-Path $app 'lab-app-journal.json'))) 'Repair recovery did not repoint the owned shortcut away from damaged source.'
    $retryApp=Join-Path $temp 'retry-app';$retryShortcut=Join-Path $temp 'retry-shortcut.lnk'
    Reject {Invoke-FastLlmLabAppCore -Action Install -ArchivePath $first.path -ExpectedSha256 ('0'*64) -AppRoot $retryApp -ShortcutPath $retryShortcut} 'Wrong initial hash accepted.'
    Check ($null -ne (Get-FastLlmLabAppOwner $retryApp) -and $null -eq (Get-FastLlmLabAppState $retryApp)) 'Failed initial attempt lost owner/retry marker.'
    $retry=Invoke-FastLlmLabAppCore -Action Install -ArchivePath $first.path -ExpectedSha256 $first.sha256 -AppRoot $retryApp -ShortcutPath $retryShortcut
    Check ($retry.currentVersion -cmatch '^[0-9a-f]{64}-[0-9a-f]{32}$') 'Retry after failed initial hash did not install.'
    $retryPrior=Get-FastLlmLabAppState $retryApp
    $retryRepair=Invoke-FastLlmLabAppCore -Action Repair -ArchivePath $second.path -ExpectedSha256 $second.sha256 -AppRoot $retryApp -ShortcutPath $retryShortcut
    $retryNew=Get-FastLlmLabAppState $retryApp
    $priorState=@{schemaVersion=1;kind='fastllm-private-lab-app';installId=$retryPrior.installId;
        currentVersion=$retryPrior.currentVersion;currentManifestSha256=$retryPrior.currentManifestSha256;
        previousVersion=$null;previousManifestSha256=$null}
    Write-FastLlmLabAppJsonAtomic -Path (Join-Path $retryApp 'lab-app.json') -Value $priorState
    $priorJournal=@{schemaVersion=1;kind='fastllm-private-lab-app-transition';installId=$retryPrior.installId;
        targetVersion=$retryNew.currentVersion;targetManifestSha256=$retryNew.currentManifestSha256;
        previousVersion=$retryPrior.currentVersion;previousManifestSha256=$retryPrior.currentManifestSha256}
    Write-FastLlmLabAppJsonAtomic -Path (Join-Path $retryApp 'lab-app-journal.json') -Value $priorJournal
    $recovered=Invoke-FastLlmLabAppCore -Action Rollback -AppRoot $retryApp -ShortcutPath $retryShortcut
    Check ($recovered.currentVersion -ceq $retryPrior.currentVersion -and $recovered.previousVersion -ceq $retryRepair.currentVersion -and
           -not (Test-Path -LiteralPath (Join-Path $retryApp 'lab-app-journal.json'))) 'Prior-state interrupted repair was not recovered before rollback.'
}finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}}
"Lab app checks: $checks passed"
