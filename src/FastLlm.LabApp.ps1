#requires -Version 5.1
# Local, unsigned lab-package installation only. This never executes archive content.

function Assert-FastLlmLabAppLeaf {
    param([string]$Name)
    if($Name -cnotmatch '^[0-9a-f]{64}-[0-9a-f]{32}$'){throw 'Invalid managed lab-app version ID.'}
}

function Assert-FastLlmLabAppPath {
    param([string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    $part=New-Object IO.DirectoryInfo($full)
    while($null -ne $part){
        if($part.Exists -and (($part.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)){
            throw 'Lab-app path includes a reparse-point ancestor.'
        }
        $part=$part.Parent
    }
    if(Test-Path -LiteralPath $full){
        $item=Get-Item -LiteralPath $full -Force
        if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Lab-app path is a reparse point.'}
    }
    return $full
}

function Assert-FastLlmLabLocalWindowsPath {
    param([string]$Path)
    if($env:OS -cne 'Windows_NT'){return}
    if($Path -cnotmatch '^[A-Za-z]:[\\/]'){throw 'Use an explicit absolute path on a local drive.'}
    if($Path.StartsWith('\\') -or $Path.StartsWith('//') -or $Path.StartsWith('\\?\') -or
       $Path.StartsWith('\\.\')){throw 'Lab packages and app roots must be on a local fixed drive.'}
    $full=[IO.Path]::GetFullPath($Path)
    $root=[IO.Path]::GetPathRoot($full)
    if($root -cnotmatch '^[A-Za-z]:\\$'){throw 'Lab package is not on a local drive-letter volume.'}
    $drive=New-Object IO.DriveInfo($root)
    if($drive.DriveType -ne [IO.DriveType]::Fixed){throw 'Network, removable, and virtual volumes are not supported for the lab app.'}
}

function Assert-FastLlmLabPackagePath {
    param([string]$Name)
    if([string]::IsNullOrEmpty($Name) -or $Name.Length -gt 240 -or $Name -cnotmatch '^[A-Za-z0-9_./-]+$' -or
       $Name.StartsWith('/') -or $Name.Contains('\') -or $Name.Contains(':') -or
       $Name -match '[\x00-\x1f\x7f]' -or $Name -match '[<>"|?*]' -or
       $Name.EndsWith('/')){throw 'Unsafe ZIP member path.'}
    $parts=$Name.Split('/')
    if($parts.Count -gt 12){throw 'ZIP member path is too deep.'}
    foreach($part in $parts){
        if($part.Length -eq 0 -or $part.Length -gt 100 -or $part -in @('.','..') -or
           $part.TrimEnd([char[]]@(' ','.')) -cne $part -or
           $part -match '^(?i:(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9]))(?:\.|$)'){
            throw 'Unsafe Win32 ZIP path component.'
        }
    }
    if($Name -cne 'PACKAGE-MANIFEST.json' -and
       [IO.Path]::GetExtension($Name).ToLowerInvariant() -notin @('.ps1','.psm1','.cs','.md','.json','.sha256','.cmd')){
        throw 'ZIP contains an unapproved source-file type.'
    }
}

function Assert-FastLlmLabManifest {
    param($Manifest,[string[]]$Names)
    $manifestKeys=@('schemaVersion','kind','physicalQualification','publicReleaseApproved','generatedAt','sourceLicenseDecision','files')
    if(@($Manifest.PSObject.Properties).Count -ne $manifestKeys.Count -or
       @($Manifest.PSObject.Properties.Name | Where-Object {$_ -cnotin $manifestKeys}).Count -ne 0 -or
       [int]$Manifest.schemaVersion -ne 1 -or $Manifest.kind -cne 'unsigned-private-windows-lab-package' -or
       $Manifest.physicalQualification -isnot [bool] -or $Manifest.physicalQualification -or
       $Manifest.publicReleaseApproved -isnot [bool] -or $Manifest.publicReleaseApproved -or
       $null -eq $Manifest.generatedAt -or ([string]$Manifest.generatedAt).Length -gt 64 -or
       $Manifest.sourceLicenseDecision -isnot [string] -or $Manifest.sourceLicenseDecision.Length -gt 128 -or
       $null -eq $Manifest.files){throw 'ZIP manifest is not the unqualified source-only lab contract.'}
    $declared=@($Manifest.files)
    if($declared.Count -lt 1 -or $declared.Count -gt 512 -or $Names.Count -ne $declared.Count+1){throw 'ZIP file count differs from manifest.'}
    $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    [void]$seen.Add('PACKAGE-MANIFEST.json')
    $map=@{}
    foreach($entry in $declared){
        if(@($entry.PSObject.Properties).Count -ne 3 -or
           @($entry.PSObject.Properties.Name | Where-Object {$_ -cnotin @('path','sizeBytes','sha256')}).Count -ne 0 -or
           $entry.path -isnot [string] -or $entry.sha256 -isnot [string] -or
           $entry.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
           ($entry.sizeBytes -isnot [long] -and $entry.sizeBytes -isnot [int]) -or
           [long]$entry.sizeBytes -lt 0 -or [long]$entry.sizeBytes -gt 2MB){
            throw 'ZIP manifest member is malformed or too large.'
        }
        Assert-FastLlmLabPackagePath $entry.path
        if($Names -cnotcontains $entry.path){throw 'ZIP member spelling differs from its exact manifest path.'}
        if(-not $seen.Add($entry.path)){throw 'Duplicate or case-colliding ZIP manifest path.'}
        $map[$entry.path]=$entry
    }
    foreach($name in $Names){if(-not $seen.Contains($name)){throw 'ZIP contains an undeclared member.'}}
    foreach($essential in @('FastLLM.cmd','fast-llm-ui.ps1','fast-llm.ps1','src/FastLlm.psm1','config/catalog.json')){
        if(-not $seen.Contains($essential)){throw 'Lab ZIP lacks a required application entry point.'}
    }
    return $map
}

function Get-FastLlmLabPackageDigest {
    param([IO.Stream]$Stream)
    $Stream.Position=0
    $sha=[Security.Cryptography.SHA256]::Create()
    try{
        $buffer=New-Object byte[] 65536;$count=[long]0
        while(($read=$Stream.Read($buffer,0,$buffer.Length)) -gt 0){
            $count+=$read
            if($count -gt 25MB){throw 'Lab ZIP exceeded held-handle byte limit.'}
            [void]$sha.TransformBlock($buffer,0,$read,$buffer,0)
        }
        [void]$sha.TransformFinalBlock([byte[]]@(),0,0)
        return ([BitConverter]::ToString($sha.Hash)).Replace('-','').ToLowerInvariant()
    }
    finally{$sha.Dispose()}
}

function Read-FastLlmLabEntryBytes {
    param($Entry,[long]$Limit)
    $source=$Entry.Open();$memory=New-Object IO.MemoryStream
    try{
        $buffer=New-Object byte[] 65536
        while(($read=$source.Read($buffer,0,$buffer.Length)) -gt 0){
            if($memory.Length+$read -gt $Limit){throw 'ZIP member exceeded its expanded-byte limit.'}
            $memory.Write($buffer,0,$read)
        }
        if($memory.Length -ne [long]$Entry.Length){throw 'ZIP member expanded length differs from central directory.'}
        return ,$memory.ToArray()
    }finally{$source.Dispose();$memory.Dispose()}
}

function Assert-FastLlmLabEntryDigest {
    param($Entry,[long]$ExpectedBytes,[string]$ExpectedSha256)
    $source=$Entry.Open();$sha=[Security.Cryptography.SHA256]::Create()
    try{
        $buffer=New-Object byte[] 65536;$count=[long]0
        while(($read=$source.Read($buffer,0,$buffer.Length)) -gt 0){
            $count+=$read
            if($count -gt $ExpectedBytes -or $count -gt 2MB){throw 'ZIP member expanded beyond its declared bound.'}
            [void]$sha.TransformBlock($buffer,0,$read,$buffer,0)
        }
        [void]$sha.TransformFinalBlock([byte[]]@(),0,0)
        $actual=([BitConverter]::ToString($sha.Hash)).Replace('-','').ToLowerInvariant()
        if($count -ne $ExpectedBytes -or $actual -cne $ExpectedSha256){throw 'ZIP member length or SHA-256 differs from manifest.'}
    }finally{$source.Dispose();$sha.Dispose()}
}

function Copy-FastLlmLabEntry {
    param($Entry,[string]$Destination,[long]$ExpectedBytes,[string]$ExpectedSha256)
    $source=$Entry.Open()
    $target=$null;$sha=[Security.Cryptography.SHA256]::Create()
    try{
        $target=[IO.File]::Open($Destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $buffer=New-Object byte[] 65536;$count=[long]0
        while(($read=$source.Read($buffer,0,$buffer.Length)) -gt 0){
            $count+=$read
            if($count -gt $ExpectedBytes -or $count -gt 2MB){throw 'ZIP member expanded beyond its declared bound.'}
            [void]$sha.TransformBlock($buffer,0,$read,$buffer,0)
            $target.Write($buffer,0,$read)
        }
        [void]$sha.TransformFinalBlock([byte[]]@(),0,0)
        $actual=([BitConverter]::ToString($sha.Hash)).Replace('-','').ToLowerInvariant()
        if($count -ne $ExpectedBytes -or $actual -cne $ExpectedSha256){throw 'ZIP member length or SHA-256 differs from manifest.'}
        $target.Flush($true)
    }finally{if($target){$target.Dispose()};$source.Dispose();$sha.Dispose()}
}

function Expand-FastLlmLabVerifiedPackage {
    param([string]$ArchivePath,[string]$ExpectedSha256,[string]$Stage)
    if($ExpectedSha256 -cnotmatch '^[0-9a-f]{64}$'){throw 'An independently reviewed exact ZIP SHA-256 is required.'}
    if($env:OS -ceq 'Windows_NT'){Assert-FastLlmLabLocalWindowsPath $ArchivePath}
    $zipPath=Assert-FastLlmLabAppPath $ArchivePath
    $item=Get-Item -LiteralPath $zipPath -Force -ErrorAction Stop
    if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
       $item.Length -lt 1 -or $item.Length -gt 25MB){throw 'Lab ZIP is not a bounded regular file.'}
    $file=[IO.File]::Open($zipPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    try{
        if($file.Length -lt 1 -or $file.Length -gt 25MB){throw 'Held lab ZIP length is outside bound.'}
        Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
        if((Get-FastLlmLabPackageDigest $file) -cne $ExpectedSha256){throw 'Lab ZIP differs from the independently supplied SHA-256.'}
        $file.Position=0
        $archive=New-Object IO.Compression.ZipArchive($file,[IO.Compression.ZipArchiveMode]::Read,$true)
        try{
            $entries=@($archive.Entries)
            if($entries.Count -lt 2 -or $entries.Count -gt 1001){throw 'Lab ZIP entry count is outside bounds.'}
            $names=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            $byName=@{};$expanded=[long]0
            foreach($entry in $entries){
                $name=[string]$entry.FullName
                Assert-FastLlmLabPackagePath $name
                if(-not $names.Add($name)){throw 'Lab ZIP contains duplicate or case-colliding paths.'}
                if(($entry.ExternalAttributes -band 0x400) -ne 0 -or ($entry.ExternalAttributes -band 0x10) -ne 0 -or
                   ((($entry.ExternalAttributes -shr 16) -band 0xF000) -in @(0xA000,0x4000,0x2000,0x6000,0x1000,0xC000))){
                    throw 'Lab ZIP contains a link, reparse point, directory, or special member.'
                }
                if($entry.Length -gt 2MB -or $entry.Length -lt 0){throw 'Lab ZIP entry exceeds source size bound.'}
                $expanded+=[long]$entry.Length
                if($expanded -gt 20MB){throw 'Lab ZIP expanded source budget exceeded.'}
                $byName[$name]=$entry
            }
            foreach($name in $names){
                $parts=$name.Split('/')
                for($i=1;$i -lt $parts.Count;$i++){
                    if($names.Contains(($parts[0..($i-1)] -join '/'))){throw 'Lab ZIP uses a file as a directory ancestor.'}
                }
            }
            if(-not $byName.ContainsKey('PACKAGE-MANIFEST.json')){throw 'Lab ZIP lacks its package manifest.'}
            $manifestEntry=$byName['PACKAGE-MANIFEST.json']
            if($manifestEntry.Length -gt 2MB){throw 'Package manifest exceeds its bound.'}
            $manifestBytes=Read-FastLlmLabEntryBytes -Entry $manifestEntry -Limit 2MB
            $utf8=New-Object Text.UTF8Encoding($false,$true)
            $manifestText=$utf8.GetString($manifestBytes)
            # PowerShell 5.1 can bind a char argument through culture-sensitive string
            # comparison, where U+FEFF may be treated as ignorable even without a BOM.
            if($manifestText.StartsWith([string][char]0xFEFF,[StringComparison]::Ordinal)){
                $manifestText=$manifestText.Substring(1)
            }
            $manifest=ConvertFrom-Json -InputObject $manifestText -ErrorAction Stop
            $map=Assert-FastLlmLabManifest -Manifest $manifest -Names @($names)
            foreach($name in @($names | Where-Object {$_ -cne 'PACKAGE-MANIFEST.json'})){
                $declared=$map[$name]
                if($null -eq $declared -or [long]$byName[$name].Length -ne [long]$declared.sizeBytes){
                    throw 'Lab ZIP metadata differs from its manifest.'
                }
                Assert-FastLlmLabEntryDigest -Entry $byName[$name] -ExpectedBytes ([long]$declared.sizeBytes) -ExpectedSha256 $declared.sha256
            }
            # No stage exists or is written before every expanded member is verified.
            $stage=Assert-FastLlmLabAppPath $Stage
            if(Test-Path -LiteralPath $stage){throw 'Fresh lab ZIP staging directory already exists.'}
            $null=Assert-FastLlmLabAppPath (Split-Path $stage -Parent)
            [void][IO.Directory]::CreateDirectory($stage)
            $null=Assert-FastLlmLabAppPath $stage
            foreach($name in $names){
                $relative=$name.Replace('/',[IO.Path]::DirectorySeparatorChar)
                $target=Join-Path $stage $relative
                $parent=Split-Path $target -Parent
                $null=Assert-FastLlmLabAppPath $parent
                [void][IO.Directory]::CreateDirectory($parent)
                $null=Assert-FastLlmLabAppPath $parent
                if(Test-Path -LiteralPath $target){throw 'Fresh lab ZIP target already exists.'}
                if($name -ceq 'PACKAGE-MANIFEST.json'){
                    $out=[IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                    try{$out.Write($manifestBytes,0,$manifestBytes.Length);$out.Flush($true)}finally{$out.Dispose()}
                }else{
                    $expected=$map[$name]
                    Copy-FastLlmLabEntry -Entry $byName[$name] -Destination $target -ExpectedBytes ([long]$expected.sizeBytes) -ExpectedSha256 $expected.sha256
                }
            }
        }finally{$archive.Dispose()}
        if((Get-FastLlmLabPackageDigest $file) -cne $ExpectedSha256){throw 'Lab ZIP changed during extraction.'}
        $manifestSha=[Security.Cryptography.SHA256]::Create()
        try{$manifestDigest=([BitConverter]::ToString($manifestSha.ComputeHash($manifestBytes))).Replace('-','').ToLowerInvariant()}
        finally{$manifestSha.Dispose()}
        return [pscustomobject]@{sha256=$ExpectedSha256;manifestSha256=$manifestDigest;files=$map.Count;stage=$stage}
    }finally{$file.Dispose()}
}

function Get-FastLlmLabAppState {
    param([string]$AppRoot)
    $path=Join-Path $AppRoot 'lab-app.json'
    if(-not (Test-Path -LiteralPath $path)){return $null}
    $item=Get-Item -LiteralPath $path -Force
    if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -gt 8192){throw 'Lab-app state is unsafe.'}
    $state=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if($state.schemaVersion -ne 1 -or $state.kind -cne 'fastllm-private-lab-app' -or
       $state.installId -cnotmatch '^[0-9a-f]{32}$' -or
       $state.currentManifestSha256 -cnotmatch '^[0-9a-f]{64}$') {throw 'Lab-app state is invalid.'}
    Assert-FastLlmLabAppLeaf $state.currentVersion
    if($null -ne $state.previousVersion){
        Assert-FastLlmLabAppLeaf $state.previousVersion
        if($state.previousManifestSha256 -cnotmatch '^[0-9a-f]{64}$'){throw 'Previous managed manifest digest is invalid.'}
    }elseif($null -ne $state.previousManifestSha256){throw 'Previous manifest digest lacks a version.'}
    return $state
}

function Get-FastLlmLabAppOwner {
    param([string]$AppRoot)
    $path=Join-Path $AppRoot 'lab-app-owner.json'
    if(-not (Test-Path -LiteralPath $path)){return $null}
    $item=Get-Item -LiteralPath $path -Force
    if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
       $item.Length -lt 1 -or $item.Length -gt 8192){throw 'Lab-app owner marker is unsafe.'}
    $owner=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if($owner.schemaVersion -ne 1 -or $owner.kind -cne 'fastllm-private-lab-app-owner' -or
       $owner.installId -cnotmatch '^[0-9a-f]{32}$'){throw 'Lab-app owner marker is invalid.'}
    return $owner
}

function Write-FastLlmLabAppJsonAtomic {
    param([string]$Path,$Value)
    $temp=$Path+'.tmp.'+[Guid]::NewGuid().ToString('N')
    $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Value -Depth 8 -Compress))
    if($bytes.Length -gt 8192){throw 'Lab-app metadata exceeds bound.'}
    $file=[IO.File]::Open($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$file.Write($bytes,0,$bytes.Length);$file.Flush($true)}finally{$file.Dispose()}
    if([IO.File]::Exists($Path)){
        $backup=$Path+'.replaced.'+[Guid]::NewGuid().ToString('N')
        [IO.File]::Replace($temp,$Path,$backup)
        [IO.File]::Delete($backup)
    }else{[IO.File]::Move($temp,$Path)}
}

function Test-FastLlmLabAppVersion {
    param([string]$AppRoot,[string]$Version,[string]$ExpectedManifestSha256)
    Assert-FastLlmLabAppLeaf $Version
    $root=Assert-FastLlmLabAppPath (Join-Path (Join-Path $AppRoot 'versions') $Version)
    if(-not [IO.Directory]::Exists($root)){throw 'Managed version directory is missing.'}
    $manifestPath=Join-Path $root 'PACKAGE-MANIFEST.json'
    $manifestItem=Get-Item -LiteralPath $manifestPath -Force -ErrorAction Stop
    if($manifestItem.Length -gt 2MB -or ($manifestItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Managed version manifest is unsafe.'}
    if($ExpectedManifestSha256){
        if($ExpectedManifestSha256 -cnotmatch '^[0-9a-f]{64}$' -or
           (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ExpectedManifestSha256){
            throw 'Managed version manifest differs from the recorded installation digest.'
        }
    }
    $manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $actual=@();$actualDirs=@();$visited=0;$pending=New-Object 'System.Collections.Generic.Stack[string]';$pending.Push($root)
    while($pending.Count -gt 0){
        $visited++;if($visited -gt 8192){throw 'Managed version directory tree exceeds bound.'}
        $directory=$pending.Pop()
        foreach($item in Get-ChildItem -LiteralPath $directory -Force){
            if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Managed version contains a reparse point.'}
            if($item.PSIsContainer){
                $actualDirs+= $item.FullName.Substring($root.Length+1).Replace('\','/')
                $pending.Push($item.FullName)
            }
            else{$actual+= $item.FullName.Substring($root.Length+1).Replace('\','/')}
            if($actual.Count+$pending.Count+$visited -gt 8192){throw 'Managed version contains too many entries.'}
        }
    }
    $map=Assert-FastLlmLabManifest -Manifest $manifest -Names $actual
    $expectedDirs=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($name in $actual){
        $parts=$name.Split('/')
        for($i=1;$i -lt $parts.Count;$i++){[void]$expectedDirs.Add(($parts[0..($i-1)] -join '/'))}
    }
    if($actualDirs.Count -ne $expectedDirs.Count -or @($actualDirs | Where-Object {-not $expectedDirs.Contains($_)}).Count){
        throw 'Managed version has undeclared or missing directories.'
    }
    foreach($entry in $map.Values){
        $path=Join-Path $root ([string]$entry.path).Replace('/',[IO.Path]::DirectorySeparatorChar)
        $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
           $item.Length -ne [long]$entry.sizeBytes -or
           (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.sha256){
            throw 'Managed lab-app version file differs from its manifest.'
        }
    }
    return $root
}

function Get-FastLlmLabShortcutPath {
    $programs=[Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)
    if([string]::IsNullOrWhiteSpace($programs)){throw 'Per-user Start Menu is unavailable.'}
    return Join-Path (Join-Path $programs 'Bitworks') 'FastLLM Lab.lnk'
}

function Assert-FastLlmLabShortcutOwnership {
    param([string]$TargetPath,[string]$Arguments,[string]$AppRoot,$State,$Journal)
    if([string]::IsNullOrWhiteSpace($TargetPath) -or $Arguments -cne ''){
        throw 'Refusing to overwrite a Start Menu shortcut with an unexpected target or arguments.'
    }
    $oldTarget=[IO.Path]::GetFullPath($TargetPath)
    $versionRoot=[IO.Path]::GetFullPath((Join-Path $AppRoot 'versions')).TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar))
    $oldLeaf=[IO.Path]::GetFileName([IO.Path]::GetDirectoryName($oldTarget))
    Assert-FastLlmLabAppLeaf $oldLeaf
    $expected=[IO.Path]::GetFullPath((Join-Path (Join-Path $versionRoot $oldLeaf) 'FastLLM.cmd'))
    if(-not $oldTarget.Equals($expected,[StringComparison]::OrdinalIgnoreCase)){
        throw 'Start Menu shortcut does not target an exact managed app entry point.'
    }
    $recorded=@()
    if($State){$recorded+= [string]$State.currentVersion;if($State.previousVersion){$recorded+= [string]$State.previousVersion}}
    if($Journal){$recorded+= [string]$Journal.targetVersion}
    if($oldLeaf -cnotin $recorded){throw 'Start Menu shortcut target is not in committed or interrupted managed state.'}
    return $oldLeaf
}

function Set-FastLlmLabShortcut {
    param([string]$ShortcutPath,[string]$AppRoot,[string]$Version,[string]$ManifestSha256)
    $target=Join-Path (Test-FastLlmLabAppVersion $AppRoot $Version $ManifestSha256) 'FastLLM.cmd'
    $parent=Assert-FastLlmLabAppPath (Split-Path $ShortcutPath -Parent)
    [void][IO.Directory]::CreateDirectory($parent)
    $shell=New-Object -ComObject WScript.Shell
    if(Test-Path -LiteralPath $ShortcutPath){
        $item=Get-Item -LiteralPath $ShortcutPath -Force
        if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Start Menu shortcut is a reparse point.'}
        $old=$shell.CreateShortcut($ShortcutPath)
        $state=Get-FastLlmLabAppState $AppRoot
        $journalPath=Join-Path $AppRoot 'lab-app-journal.json'
        $journal=$null
        if(Test-Path -LiteralPath $journalPath){
            $journalItem=Get-Item -LiteralPath $journalPath -Force
            if($journalItem.PSIsContainer -or ($journalItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
               $journalItem.Length -lt 1 -or $journalItem.Length -gt 8192){throw 'Start Menu ownership journal is unsafe.'}
            $journal=Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
            if($journal.targetVersion -cnotmatch '^[0-9a-f]{64}-[0-9a-f]{32}$' -or
               $journal.targetManifestSha256 -cnotmatch '^[0-9a-f]{64}$'){
                throw 'Start Menu ownership journal is invalid.'
            }
        }
        $null=Assert-FastLlmLabShortcutOwnership -TargetPath ([string]$old.TargetPath) -Arguments ([string]$old.Arguments) `
            -AppRoot $AppRoot -State $state -Journal $journal
    }
    $temporary=$ShortcutPath+'.tmp.'+[Guid]::NewGuid().ToString('N')+'.lnk'
    $link=$shell.CreateShortcut($temporary)
    $link.TargetPath=$target;$link.Arguments='';$link.WorkingDirectory=Split-Path $target -Parent
    $link.Description='Unsigned Bitworks FastLLM private lab application';$link.Save()
    if(Test-Path -LiteralPath $ShortcutPath){
        $backup=$ShortcutPath+'.replaced.'+[Guid]::NewGuid().ToString('N')
        [IO.File]::Replace($temporary,$ShortcutPath,$backup)
        [IO.File]::Delete($backup)
    }
    else{[IO.File]::Move($temporary,$ShortcutPath)}
    return $ShortcutPath
}

function Invoke-FastLlmLabAppCore {
    param([ValidateSet('Install','Repair','Rollback')][string]$Action,[string]$AppRoot,
          [string]$ArchivePath,[string]$ExpectedSha256,[string]$ShortcutPath)
    $app=Assert-FastLlmLabAppPath $AppRoot
    if($env:OS -ceq 'Windows_NT'){Assert-FastLlmLabLocalWindowsPath $app}
    $alreadyExists=[IO.Directory]::Exists($app)
    $cache=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'Bitworks/FastLLM'
    $separator=[string][IO.Path]::DirectorySeparatorChar
    $appCompare=([IO.Path]::GetFullPath($app)).TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar))
    $cacheCompare=([IO.Path]::GetFullPath($cache)).TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar))
    if($appCompare.Equals($cacheCompare,[StringComparison]::OrdinalIgnoreCase) -or
       $appCompare.StartsWith(($cacheCompare+$separator),[StringComparison]::OrdinalIgnoreCase) -or
       $cacheCompare.StartsWith(($appCompare+$separator),[StringComparison]::OrdinalIgnoreCase)){
        throw 'Lab-app source root and model/cache root must not overlap.'
    }
    [void][IO.Directory]::CreateDirectory($app)
    $lockPath=Join-Path $app 'lab-app.lock'
    $lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try{
        $owner=Get-FastLlmLabAppOwner $app
        if(-not $owner){
            if($alreadyExists){
                $unexpected=@(Get-ChildItem -LiteralPath $app -Force | Where-Object {$_.Name -cne 'lab-app.lock'})
                if($unexpected.Count){throw 'Existing unowned application root requires manual review.'}
            }
            $owner=[ordered]@{schemaVersion=1;kind='fastllm-private-lab-app-owner';installId=[Guid]::NewGuid().ToString('N')}
            Write-FastLlmLabAppJsonAtomic -Path (Join-Path $app 'lab-app-owner.json') -Value $owner
        }
        $state=Get-FastLlmLabAppState $app
        if($state -and $state.installId -cne $owner.installId){throw 'Lab-app state owner differs from the managed root.'}
        $journalPath=Join-Path $app 'lab-app-journal.json'
        if(Test-Path -LiteralPath $journalPath){
            $journalItem=Get-Item -LiteralPath $journalPath -Force
            if($journalItem.PSIsContainer -or ($journalItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
               $journalItem.Length -lt 1 -or $journalItem.Length -gt 8192){throw 'Interrupted lab-app journal is unsafe.'}
            $journal=Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
            if($journal.schemaVersion -ne 1 -or $journal.kind -cne 'fastllm-private-lab-app-transition' -or
               $journal.installId -cne $owner.installId -or
               $journal.targetManifestSha256 -cnotmatch '^[0-9a-f]{64}$'){
                throw 'Interrupted lab-app transition needs manual review.'
            }
            Assert-FastLlmLabAppLeaf $journal.targetVersion
            if($null -ne $journal.previousVersion){
                Assert-FastLlmLabAppLeaf $journal.previousVersion
                if($journal.previousManifestSha256 -cnotmatch '^[0-9a-f]{64}$'){throw 'Interrupted prior digest is invalid.'}
            }elseif($null -ne $journal.previousManifestSha256){throw 'Interrupted prior digest lacks a version.'}
            $priorState=$state -and $state.currentVersion -ceq $journal.previousVersion -and
                $state.currentManifestSha256 -ceq $journal.previousManifestSha256
            $committedState=$state -and $state.currentVersion -ceq $journal.targetVersion -and
                $state.currentManifestSha256 -ceq $journal.targetManifestSha256 -and
                $state.previousVersion -ceq $journal.previousVersion -and
                $state.previousManifestSha256 -ceq $journal.previousManifestSha256
            if(-not $committedState -and -not $priorState -and -not ($null -eq $state -and $null -eq $journal.previousVersion)){
                throw 'Interrupted lab-app journal does not match prior or committed state.'
            }
            $null=Test-FastLlmLabAppVersion $app $journal.targetVersion $journal.targetManifestSha256
            $null=Set-FastLlmLabShortcut -ShortcutPath $ShortcutPath -AppRoot $app -Version $journal.targetVersion -ManifestSha256 $journal.targetManifestSha256
            $state=[pscustomobject]@{schemaVersion=1;kind='fastllm-private-lab-app';installId=$journal.installId;
                currentVersion=$journal.targetVersion;currentManifestSha256=$journal.targetManifestSha256;
                previousVersion=$journal.previousVersion;previousManifestSha256=$journal.previousManifestSha256}
            Write-FastLlmLabAppJsonAtomic -Path (Join-Path $app 'lab-app.json') -Value $state
            [IO.File]::Delete($journalPath)
        }
        if($Action -ceq 'Rollback'){
            if($ArchivePath -or $ExpectedSha256){throw 'Rollback does not accept an archive or new hash.'}
            if(-not $state -or -not $state.previousVersion){throw 'No verified previous version is available for rollback.'}
            $target=$state.previousVersion;$targetManifestSha=$state.previousManifestSha256
        }else{
            if(-not $ArchivePath -or $ExpectedSha256 -cnotmatch '^[0-9a-f]{64}$'){
                throw 'Install/Repair requires a local ZIP and exact independently supplied SHA-256.'
            }
            if($Action -ceq 'Install' -and $state){throw 'A managed app already exists; use Repair.'}
            if($Action -ceq 'Repair' -and -not $state){throw 'No managed app exists; use Install.'}
            $versions=Assert-FastLlmLabAppPath (Join-Path $app 'versions')
            [void][IO.Directory]::CreateDirectory($versions)
            $target=$ExpectedSha256+'-'+[Guid]::NewGuid().ToString('N')
            $stage=Assert-FastLlmLabAppPath (Join-Path $app ('.stage-'+[Guid]::NewGuid().ToString('N')))
            $verified=Expand-FastLlmLabVerifiedPackage -ArchivePath $ArchivePath -ExpectedSha256 $ExpectedSha256 -Stage $stage
            if($verified.sha256 -cne $ExpectedSha256){throw 'Lab ZIP verification failed.'}
            $targetManifestSha=$verified.manifestSha256
            [IO.Directory]::Move($stage,(Join-Path $versions $target))
        }
        $null=Test-FastLlmLabAppVersion $app $target $targetManifestSha
        $previous=if($state){$state.currentVersion}else{$null}
        $previousManifestSha=if($state){$state.currentManifestSha256}else{$null}
        $id=$owner.installId
        $journal=[ordered]@{schemaVersion=1;kind='fastllm-private-lab-app-transition';installId=$id;
            targetVersion=$target;targetManifestSha256=$targetManifestSha;
            previousVersion=$previous;previousManifestSha256=$previousManifestSha}
        Write-FastLlmLabAppJsonAtomic -Path $journalPath -Value $journal
        $null=Set-FastLlmLabShortcut -ShortcutPath $ShortcutPath -AppRoot $app -Version $target -ManifestSha256 $targetManifestSha
        $next=[ordered]@{schemaVersion=1;kind='fastllm-private-lab-app';installId=$id;
            currentVersion=$target;currentManifestSha256=$targetManifestSha;
            previousVersion=$previous;previousManifestSha256=$previousManifestSha}
        Write-FastLlmLabAppJsonAtomic -Path (Join-Path $app 'lab-app.json') -Value $next
        [IO.File]::Delete($journalPath)
        return [pscustomobject]@{appRoot=$app;currentVersion=$target;previousVersion=$previous;
            shortcutPath=$ShortcutPath;publisherAuthenticated=$false;publicReleaseApproved=$false;
            retainedVersions=$true;modelCacheUntouched=$true}
    }finally{$lock.Dispose()}
}

function Invoke-FastLlmLabApp {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][ValidateSet('Install','Repair','Rollback')][string]$Action,
          [string]$ArchivePath,[string]$ExpectedSha256)
    if($env:OS -cne 'Windows_NT' -or -not [Environment]::Is64BitProcess){throw 'Lab-app installation requires 64-bit Windows PowerShell as a standard user.'}
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    if((New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
        throw 'Do not elevate the private lab-app installer.'
    }
    $local=[Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if([string]::IsNullOrWhiteSpace($local)){throw 'Per-user LocalAppData is unavailable.'}
    Assert-FastLlmLabLocalWindowsPath $local
    return Invoke-FastLlmLabAppCore -Action $Action -ArchivePath $ArchivePath -ExpectedSha256 $ExpectedSha256 `
        -AppRoot (Join-Path $local 'Bitworks/FastLLM-App') -ShortcutPath (Get-FastLlmLabShortcutPath)
}
