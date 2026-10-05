# Private Windows lab handoff. The elevated broker is an in-command script,
# never a mutable repository file. This is not a signed public bootstrapper.
function Assert-FastLlmVcRedistPreparedPath {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string]$CacheRoot)
    Assert-FastLlmVcRedistPath -Path $Path
    $full=[IO.Path]::GetFullPath($Path)
    $root=[IO.Path]::GetFullPath($CacheRoot).TrimEnd('\','/')
    $parent=[IO.Path]::GetDirectoryName($full)
    $run=[IO.Path]::GetFileName($parent)
    if([IO.Path]::GetFileName($full) -cne 'VC_redist.x64.exe' -or
       $run -cnotmatch '^vc-redist-[0-9a-f]{32}$' -or
       -not [string]::Equals([IO.Path]::GetDirectoryName($parent),$root,[StringComparison]::OrdinalIgnoreCase)){
        throw 'Only an exact prepared VC++ artifact in the dedicated cache may be installed.'
    }
    return $full
}

function Get-FastLlmVcRedistInstallDecision {
    param($Inventory,[version]$CandidateVersion)
    if($null -eq $Inventory -or $Inventory.applicable -ne $true -or $Inventory.partial -eq $true -or
       $null -eq $Inventory.vcRuntimeRegistration){return 'inventory-uncertain'}
    $registration=$Inventory.vcRuntimeRegistration
    if($registration.status -ceq 'missing'){return 'offer-install'}
    if($registration.status -cne 'observed' -or $registration.installed -isnot [bool] -or
       $registration.versionState -cne 'observed' -or -not $registration.version){return 'inventory-uncertain'}
    if(-not $registration.installed){return 'offer-install'}
    $observed=$null
    if(-not [version]::TryParse(([string]$registration.version).TrimStart('v','V'),[ref]$observed)){
        return 'inventory-uncertain'
    }
    if($observed -ge $CandidateVersion){return 'already-installed-needs-probe'}
    return 'offer-install'
}

function Get-FastLlmVcRedistBrokerText {
    param([Parameter(Mandatory=$true)][string]$PreparedPath,[Parameter(Mandatory=$true)]$Candidate)
    $sourceB64=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($PreparedPath))
    if($sourceB64 -cnotmatch '^[A-Za-z0-9+/=]{1,4096}$'){throw 'Prepared artifact path is too long.'}
    # Only the base64 path is substituted; all package identity literals are
    # reviewed pins, independently checked against the prerequisite manifest.
    $script=@'
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$exitCode=51001
$stage=$null
$staged=$null
$vendorStarted=$false
$vendorExited=$false
function CheckPath([string]$path){
    $current=[IO.Path]::GetFullPath($path)
    while($current){
        if(Test-Path -LiteralPath $current){
            $item=Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'unsafe path'}
        }
        $parent=[IO.Path]::GetDirectoryName($current)
        if(-not $parent -or $parent -ceq $current){break}
        $current=$parent
    }
}
function CheckArtifact([string]$path){
    CheckPath $path
    $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
       [int64]$item.Length -ne 18731856){throw 'artifact size'}
    $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    if($hash -cne '843068991daaa1f73ad9f6239bce4d0f6a07a51f18c37ea2a867e9beca71295c'){
        throw 'artifact hash'
    }
    $version=$item.VersionInfo
    if([string]$version.FileVersion -cne '14.51.36247.0' -or
       [string]$version.ProductVersion -cne '14.51.36247.0'){throw 'artifact version'}
    $sig=Get-AuthenticodeSignature -LiteralPath $path -ErrorAction Stop
    if([string]$sig.Status -cne 'Valid' -or -not $sig.SignerCertificate -or
       [string]$sig.SignerCertificate.Subject -cne 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' -or
       [string]$sig.SignerCertificate.Thumbprint -cne '1D77A9B9E8FE2075D9AD15123257FB90DB0DA4A1'){
        throw 'artifact signer'
    }
    CheckPath $path
    $after=Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if($after.PSIsContainer -or [int64]$after.Length -ne 18731856 -or
       (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() -cne $hash){
        throw 'artifact changed'
    }
}
try{
    if(-not [Environment]::Is64BitProcess -or $env:OS -cne 'Windows_NT'){throw 'host'}
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'elevation'}
    $source=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('__SOURCE_B64__'))
    try{CheckArtifact $source}
    catch{$exitCode=51006;throw}
    $baseKey=[Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
    try{
        $runtime=$baseKey.OpenSubKey('SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64',$false)
        if($runtime){
            try{
                $installed=$runtime.GetValue('Installed',$null)
                $versionText=$runtime.GetValue('Version',$null)
                if($installed -isnot [int] -or $installed -notin @(0,1)){throw 'runtime registration uncertain'}
                if($installed -eq 1){
                    if($versionText -isnot [string]){throw 'runtime version uncertain'}
                    $version=$null
                    if(-not [version]::TryParse($versionText.TrimStart('v','V'),[ref]$version)){
                        throw 'runtime version uncertain'
                    }
                    if($version -ge [version]'14.51.36247.0'){
                        $system32=[Environment]::SystemDirectory
                        $missing=$false
                        foreach($name in @('MSVCP140.dll','VCRUNTIME140.dll','VCRUNTIME140_1.dll')){
                            if(-not [IO.File]::Exists((Join-Path $system32 $name))){$missing=$true}
                        }
                        $exitCode=if($missing){51007}else{51005}
                        throw 'equal or newer runtime already registered'
                    }
                }
            }finally{$runtime.Dispose()}
        }
    }finally{$baseKey.Dispose()}
    $base=[Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    CheckPath $base
    $admins=[Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $system=[Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $acl=New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    $acl.SetOwner($admins)
    $inherit=[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
    $propagate=[Security.AccessControl.PropagationFlags]::None
    foreach($sid in @($admins,$system)){
        $rule=[Security.AccessControl.FileSystemAccessRule]::new($sid,
            [Security.AccessControl.FileSystemRights]::FullControl,$inherit,$propagate,
            [Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    $stage=Join-Path $base ('BitworksFastLLM-VC-'+[Guid]::NewGuid().ToString('N'))
    if([IO.Directory]::Exists($stage) -or [IO.File]::Exists($stage)){throw 'stage collision'}
    [void][IO.Directory]::CreateDirectory($stage,$acl)
    CheckPath $stage
    $actualAcl=[IO.Directory]::GetAccessControl($stage)
    if(-not $actualAcl.AreAccessRulesProtected -or
       $actualAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $admins.Value){throw 'stage ACL'}
    $rules=@($actualAcl.GetAccessRules($true,$false,[Security.Principal.SecurityIdentifier]))
    if($rules.Count -ne 2){throw 'stage ACL'}
    $seen=@{}
    foreach($rule in $rules){
        if($rule.IsInherited -or $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
           $rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl -or
           $rule.InheritanceFlags -ne $inherit -or $rule.PropagationFlags -ne $propagate -or
           $rule.IdentityReference.Value -cnotin @($admins.Value,$system.Value)){throw 'stage ACL'}
        $seen[$rule.IdentityReference.Value]=$true
    }
    if($seen.Count -ne 2){throw 'stage ACL'}
    $staged=Join-Path $stage 'VC_redist.x64.exe'
    $reader=$null;$writer=$null
    try{
        $reader=[IO.File]::Open($source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $writer=[IO.File]::Open($staged,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $buffer=New-Object 'byte[]' 65536
        $copied=[int64]0
        while(($read=$reader.Read($buffer,0,$buffer.Length)) -gt 0){
            $copied+=$read
            if($copied -gt 18731856){throw 'source grew during copy'}
            $writer.Write($buffer,0,$read)
        }
        if($copied -ne 18731856){throw 'source shortened during copy'}
    }finally{
        if($writer){$writer.Dispose()}
        if($reader){$reader.Dispose()}
    }
    CheckArtifact $staged
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$staged
    $info.Arguments='/install /norestart'
    $info.WorkingDirectory=$stage
    $info.UseShellExecute=$false
    $process=New-Object Diagnostics.Process
    try{
        $process.StartInfo=$info
        if(-not $process.Start()){throw 'vendor start'}
        $vendorStarted=$true
        $process.WaitForExit() # Never time out or kill a live Microsoft installer.
        $vendorExited=$true
        $exitCode=[int]$process.ExitCode
    }finally{$process.Dispose()}
}catch{
    if($vendorStarted){$exitCode=51004}
    elseif($exitCode -eq 51001){$exitCode=51002}
}
finally{
    # Delete only the exact protected file and then its empty fresh directory.
    # If a lock prevents cleanup, leave protected staging for administrator review.
    if(-not $vendorStarted -or $vendorExited){
        try{
            if($stage -and $staged -and [IO.File]::Exists($staged)){CheckPath $staged;[IO.File]::Delete($staged)}
            if($stage -and [IO.Directory]::Exists($stage)){CheckPath $stage;[IO.Directory]::Delete($stage,$false)}
        }catch{
            if($exitCode -in @(3010,-2147021886)){$exitCode=51008}
            else{$exitCode=51003}
        }
    }
}
exit $exitCode
'@
    return $script.Replace('__SOURCE_B64__',$sourceB64)
}

function Get-FastLlmVcRedistExitState {
    param([int]$ExitCode,[bool]$UacCancelled=$false)
    if($UacCancelled){return 'uac-cancelled'}
    switch($ExitCode){
        0 {return 'installed-recheck-required'}
        3010 {return 'reboot-required'}
        -2147021886 {return 'reboot-required'}
        1602 {return 'installer-cancelled'}
        -2147023294 {return 'installer-cancelled'}
        1638 {return 'other-version-recheck-required'}
        -2147023258 {return 'other-version-recheck-required'}
        51002 {return 'broker-verification-or-launch-failed'}
        51003 {return 'stage-cleanup-failed-recheck-required'}
        51004 {return 'installer-state-uncertain'}
        51005 {return 'already-installed-needs-probe'}
        51006 {return 'prepared-artifact-unavailable-to-elevated-account'}
        51007 {return 'registered-runtime-incomplete-manual-repair'}
        51008 {return 'reboot-required-stage-cleanup-failed'}
        default {return 'unclassified-exit-recheck-required'}
    }
}

function Test-FastLlmVcRedistUacCancelled {
    param([Parameter(Mandatory=$true)][Exception]$Exception)
    $current=$Exception
    for($depth=0;$depth -lt 6 -and $null -ne $current;$depth++){
        if($current -is [ComponentModel.Win32Exception] -and $current.NativeErrorCode -eq 1223){return $true}
        $current=$current.InnerException
    }
    return $false
}

function Start-FastLlmVcRedistInstall {
    param([Parameter(Mandatory=$true)][string]$PreparedPath,
          [Parameter(Mandatory=$true)][string]$ManifestPath,
          [Parameter(Mandatory=$true)][string]$CacheRoot,[switch]$ConfirmInstall)
    if(-not $ConfirmInstall){throw 'An explicit Microsoft prerequisite install action is required.'}
    Assert-FastLlmVcRedistStandardWindows
    $candidate=Get-FastLlmVcRedistCandidate -ManifestPath $ManifestPath
    $expectedCache=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'Bitworks\FastLLM\prerequisites'
    if(-not [string]::Equals([IO.Path]::GetFullPath($CacheRoot),[IO.Path]::GetFullPath($expectedCache),
        [StringComparison]::OrdinalIgnoreCase)){throw 'The dedicated VC++ cache is required.'}
    $artifact=Assert-FastLlmVcRedistPreparedPath -Path $PreparedPath -CacheRoot $CacheRoot
    # The elevated broker rechecks the source and protected copy. No redundant
    # signature worker delays the control window before the UAC prompt.
    $powershell=Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    Assert-FastLlmVcRedistPath -Path $powershell
    $psItem=Get-Item -LiteralPath $powershell -Force -ErrorAction Stop
    if($psItem.PSIsContainer -or ($psItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){
        throw 'Trusted Windows PowerShell is unavailable.'
    }
    $broker=Get-FastLlmVcRedistBrokerText -PreparedPath $artifact -Candidate $candidate
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($broker))
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$powershell
    $info.Arguments="-NoLogo -NoProfile -NonInteractive -EncodedCommand $encoded"
    $info.Verb='runas'
    $info.UseShellExecute=$true
    $process=New-Object Diagnostics.Process
    $process.StartInfo=$info
    try{if(-not $process.Start()){throw 'Microsoft prerequisite UAC launch failed.'}}
    catch{
        $process.Dispose()
        if(Test-FastLlmVcRedistUacCancelled -Exception $_.Exception){
            return [pscustomobject]@{status='uac-cancelled';installerExecuted=$false;rebootRequired=$false;
                compatibilityQualified=$false;needsFreshProbe=$false;process=$null}
        }
        throw
    }
    return [pscustomobject]@{status='in-progress';process=$process;installerExecuted=$null;
        rebootRequired=$false;compatibilityQualified=$false;needsFreshProbe=$false}
}

function Complete-FastLlmVcRedistInstall {
    param([Parameter(Mandatory=$true)][Diagnostics.Process]$Process)
    if(-not $Process.HasExited){throw 'The Microsoft prerequisite broker is still running.'}
    try{$code=[int]$Process.ExitCode}finally{$Process.Dispose()}
    $state=Get-FastLlmVcRedistExitState -ExitCode $code
    $executed=if($code -in @(51002,51005,51006,51007)){$false}
        elseif($code -in @(0,3010,-2147021886,1602,-2147023294,1638,-2147023258,51008)){$true}
        else{$null}
    return [pscustomobject]@{status=$state;installerExecuted=$executed;
        rebootRequired=($code -in @(3010,-2147021886,51008));compatibilityQualified=$false;
        needsFreshProbe=($code -in @(0,1638,-2147023258,51003,51005));installerExitCode=$code}
}

function Invoke-FastLlmVcRedistInstall {
    param([Parameter(Mandatory=$true)][string]$PreparedPath,
          [Parameter(Mandatory=$true)][string]$ManifestPath,
          [Parameter(Mandatory=$true)][string]$CacheRoot,[switch]$ConfirmInstall)
    $start=Start-FastLlmVcRedistInstall -PreparedPath $PreparedPath -ManifestPath $ManifestPath -CacheRoot $CacheRoot -ConfirmInstall:$ConfirmInstall
    if($start.status -cne 'in-progress'){return $start}
    $start.process.WaitForExit() # CLI only; UI uses Start + timer + Complete.
    return Complete-FastLlmVcRedistInstall -Process $start.process
}
