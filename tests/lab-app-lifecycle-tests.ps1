#requires -Version 5.1
# Synthetic, private lab-app lifecycle contract. It never touches the default app.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$repo=Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'src/FastLlm.LabApp.ps1')
$script:checks=0
function Check([bool]$Condition,[string]$Message){
    if(-not $Condition){throw "FAIL: $Message"}
    $script:checks++
    Write-Host "PASS: $Message"
}
function Reject([scriptblock]$Action,[string]$Message){
    $failed=$false
    try{& $Action | Out-Null}catch{$failed=$true}
    Check $failed $Message
}
function WriteText([string]$Path,[string]$Value){
    [void][IO.Directory]::CreateDirectory((Split-Path $Path -Parent))
    [IO.File]::WriteAllText($Path,$Value,(New-Object Text.UTF8Encoding($false)))
}
function Sha([string]$Path){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}

$testBase=if($env:OS -ceq 'Windows_NT'){[IO.Path]::GetTempPath()}else{$repo}
$base=Join-Path $testBase ('fastllm-lifecycle-'+[Guid]::NewGuid().ToString('N'))
$app=Join-Path $base 'Bitworks/FastLLM-App'
$link=Join-Path $base 'Programs/Bitworks/FastLLM Lab.lnk'
$cache=Join-Path $base 'Bitworks/FastLLM/models/keep.gguf'
$version=('a'*64)+'-'+('b'*32)
$versionRoot=Join-Path (Join-Path $app 'versions') $version
$installId='c'*32
try{
    [void][IO.Directory]::CreateDirectory($versionRoot)
    $dangling=Join-Path $base 'dangling-link'
    $linkCreated=$false
    try{New-Item -ItemType SymbolicLink -Path $dangling -Target (Join-Path $base 'missing-target') -ErrorAction Stop|Out-Null;$linkCreated=$true}catch{}
    if($linkCreated){
        Reject {Assert-FastLlmLabAppPath (Join-Path $dangling 'child')} 'dangling reparse-point ancestor is refused'
    }else{
        Write-Host 'SKIP: dangling symbolic-link fixture could not be created; native dangling-reparse behavior remains untested.'
    }
    WriteText $cache 'private model cache must remain'
    $source=[ordered]@{
        'FastLLM.cmd'='@echo off'
        'fast-llm-ui.ps1'='Enter-FastLlmLabAppLifetime -SourceRoot $PSScriptRoot'
        'fast-llm.ps1'='Enter-FastLlmLabAppLifetime -SourceRoot $projectRoot'
        'src/FastLlm.psm1'='# test-only'
        'src/FastLlm.LabApp.ps1'='function Enter-FastLlmLabAppLifetime { }'
        'config/catalog.json'='{}'
    }
    $rows=@()
    foreach($name in $source.Keys){
        $path=Join-Path $versionRoot $name
        WriteText $path $source[$name]
        $rows+= [ordered]@{path=$name;sizeBytes=[long](Get-Item -LiteralPath $path).Length;sha256=(Sha $path)}
    }
    $manifest=[ordered]@{schemaVersion=1;kind='unsigned-private-windows-lab-package';physicalQualification=$false;
        publicReleaseApproved=$false;generatedAt='test-only';sourceLicenseDecision='test-only';files=$rows}
    Write-FastLlmLabAppJsonAtomic -Path (Join-Path $versionRoot 'PACKAGE-MANIFEST.json') -Value $manifest
    $manifestSha=Sha (Join-Path $versionRoot 'PACKAGE-MANIFEST.json')
    WriteText (Join-Path $app 'lab-app.lock') ''
    WriteText (Join-Path $app 'lab-app-lifetime.lock') ''
    $owner=[ordered]@{schemaVersion=1;kind='fastllm-private-lab-app-owner';installId=$installId}
    $state=[ordered]@{schemaVersion=1;kind='fastllm-private-lab-app';installId=$installId;
        currentVersion=$version;currentManifestSha256=$manifestSha;previousVersion=$null;previousManifestSha256=$null}
    Write-FastLlmLabAppJsonAtomic -Path (Join-Path $app 'lab-app-owner.json') -Value $owner
    Write-FastLlmLabAppJsonAtomic -Path (Join-Path $app 'lab-app.json') -Value $state
    [void][IO.Directory]::CreateDirectory((Split-Path $link -Parent))
    if($env:OS -ceq 'Windows_NT'){
        $shell=New-Object -ComObject WScript.Shell
        $shortcut=$shell.CreateShortcut($link)
        $shortcut.TargetPath=Join-Path $versionRoot 'FastLLM.cmd'
        $shortcut.Arguments=''
        $shortcut.WorkingDirectory=$versionRoot
        $shortcut.Save()
    }else{WriteText $link $version}
    $ledger=[ordered]@{schemaVersion=1;kind='fastllm-private-lab-app-ledger';installId=$installId;
        versions=@([ordered]@{version=$version;manifestSha256=$manifestSha});shortcut=(Get-FastLlmLabShortcutRecord $link)}
    Write-FastLlmLabAppJsonAtomic -Path (Join-Path $app 'lab-app-ledger.json') -Value $ledger

    $preview=Get-FastLlmLabAppRemovalPreview -AppRoot $app -ShortcutPath $link
    Check ($preview.ready -and $preview.digest -cmatch '^[0-9a-f]{64}$' -and $preview.items.Count -eq 5) 'owned app previews exact shortcut, version, and metadata'
    $trailingLease=Enter-FastLlmLabAppLifetime -SourceRoot ($versionRoot+[IO.Path]::DirectorySeparatorChar)
    try{
        Check ($null -ne $trailingLease -and -not (Get-FastLlmLabAppRemovalPreview -AppRoot $app -ShortcutPath $link).ready) 'trailing-separator managed path acquires the lifetime lease'
    }finally{if($trailingLease){$trailingLease.Dispose()}}
    Reject {Enter-FastLlmLabAppLifetime -SourceRoot (Join-Path (Join-Path $app 'versions') 'not-a-version')} 'managed-looking invalid version path cannot bypass the lifetime lease'
    if($env:OS -ceq 'Windows_NT'){
        $caseAlias=Join-Path (Join-Path $app 'Versions') ($version.ToUpperInvariant())
        $caseLease=Enter-FastLlmLabAppLifetime -SourceRoot $caseAlias
        try{Check ($null -ne $caseLease) 'Windows case alias acquires the same managed lifetime lease'}finally{$caseLease.Dispose()}
    }
    $lease=Enter-FastLlmLabAppLifetime -SourceRoot $versionRoot
    try{
        $busy=Get-FastLlmLabAppRemovalPreview -AppRoot $app -ShortcutPath $link
        Check (-not $busy.ready) 'active app lifetime lease prevents removal preview'
        Reject {Invoke-FastLlmLabAppRemovalCore -AppRoot $app -ShortcutPath $link -ExpectedPreviewDigest $preview.digest} 'active app lease prevents removal'
    }finally{$lease.Dispose()}

    WriteText (Join-Path $app 'unknown.txt') 'unowned'
    Check (-not (Get-FastLlmLabAppRemovalPreview -AppRoot $app -ShortcutPath $link).ready) 'unknown app-root item blocks removal'
    [IO.File]::Delete((Join-Path $app 'unknown.txt'))
    $original=[IO.File]::ReadAllBytes($link)
    [IO.File]::AppendAllText($link,'changed')
    Check (-not (Get-FastLlmLabAppRemovalPreview -AppRoot $app -ShortcutPath $link).ready) 'modified shortcut blocks removal'
    [IO.File]::WriteAllBytes($link,$original)
    $ledgerPath=Join-Path $app 'lab-app-ledger.json'
    $legacyPath=Join-Path $base 'test-only-ledger-hold.json'
    [IO.File]::Move($ledgerPath,$legacyPath)
    Check (-not (Get-FastLlmLabAppRemovalPreview -AppRoot $app -ShortcutPath $link).ready) 'pre-ledger legacy root is not inferred as owned'
    [IO.File]::Move($legacyPath,$ledgerPath)

    $fresh=Get-FastLlmLabAppRemovalPreview -AppRoot $app -ShortcutPath $link
    Check ($fresh.ready -and $fresh.digest -ceq $preview.digest) 'read-only preview remains stable after test mutations are undone'
    Reject {Invoke-FastLlmLabAppRemovalCore -AppRoot $app -ShortcutPath $link -ExpectedPreviewDigest ('0'*64)} 'unreviewed preview digest cannot remove app'
    $removed=Invoke-FastLlmLabAppRemovalCore -AppRoot $app -ShortcutPath $link -ExpectedPreviewDigest $fresh.digest
    Check ((Test-Path -LiteralPath $removed.quarantinePath) -and -not (Test-Path -LiteralPath $link) -and
        -not (Test-Path -LiteralPath $versionRoot) -and -not (Test-Path -LiteralPath (Join-Path $app 'lab-app.json'))) 'removal quarantines exact owned app entries'
    Check ((Test-Path -LiteralPath $cache) -and -not (Test-Path -LiteralPath (Join-Path $app 'lab-app-uninstall.json'))) 'model cache is untouched and completed removal journal is cleared'
    $tx=Get-FastLlmLabRemovalTransaction -AppRoot $app -ShortcutPath $link -QuarantinePath $removed.quarantinePath
    $pendingJournal=[ordered]@{schemaVersion=1;kind='fastllm-private-lab-app-removal';
        quarantinePath=$removed.quarantinePath;previewDigest=$tx.previewDigest}
    Write-FastLlmLabAppJsonAtomic -Path (Join-Path $app 'lab-app-uninstall.json') -Value $pendingJournal
    [IO.File]::Move((Join-Path $removed.quarantinePath 'content/lab-app-owner.json'),(Join-Path $app 'lab-app-owner.json'))
    $pending=Get-FastLlmLabAppPendingRecovery -AppRoot $app -ShortcutPath $link
    Check ($pending.status -ceq 'interrupted-removal' -and $pending.movedItems -eq 4 -and $pending.totalItems -eq 5 -and
        $pending.quarantinePath -ceq $removed.quarantinePath) 'read-only pending recovery identifies a partially moved transaction'
    $pendingJournal.operation='unexpected'
    Write-FastLlmLabAppJsonAtomic -Path (Join-Path $app 'lab-app-uninstall.json') -Value $pendingJournal
    Reject {Invoke-FastLlmLabAppRemovalCore -AppRoot $app -ShortcutPath $link -ExpectedPreviewDigest $fresh.digest} 'removal continuation refuses an unknown journal operation'
    Reject {Get-FastLlmLabAppPendingRecovery -AppRoot $app -ShortcutPath $link} 'pending recovery refuses an unknown journal operation'
    $pendingJournal.operation='restore'
    Write-FastLlmLabAppJsonAtomic -Path (Join-Path $app 'lab-app-uninstall.json') -Value $pendingJournal
    Check ((Get-FastLlmLabAppPendingRecovery -AppRoot $app -ShortcutPath $link).status -ceq 'interrupted-restore') 'pending recovery distinguishes an interrupted restore'
    $restored=Invoke-FastLlmLabAppRestoreCore -AppRoot $app -ShortcutPath $link -QuarantinePath $removed.quarantinePath
    Check ((Test-Path -LiteralPath $versionRoot) -and (Test-Path -LiteralPath $link) -and
        (Get-FastLlmLabAppRemovalPreview -AppRoot $app -ShortcutPath $link).ready -and $restored.restoredItems -eq 5) 'restore puts exact app entries back and reopens preview'
    Check ((Get-Content -LiteralPath $cache -Raw) -ceq 'private model cache must remain') 'cache bytes remain unchanged through removal and restore'
    Write-Host "$script:checks lab-app lifecycle checks passed. No default app or model was touched."
}finally{
    if(Test-Path -LiteralPath $base){Remove-Item -LiteralPath $base -Recurse -Force}
}
