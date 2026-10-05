#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$repo=Split-Path $PSScriptRoot -Parent
$helper=Join-Path $repo 'src/FastLlm.VcRedistInstall.ps1'
$tool=Join-Path $repo 'tools/install-vc-runtime.ps1'
foreach($path in @($helper,$tool)){
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    if(@($errors).Count){throw "PowerShell parser errors in $path"}
}
. (Join-Path $repo 'src/FastLlm.VcRedist.ps1')
. $helper
$count=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:count++}
function Reject([scriptblock]$Action,[string]$Message){
    $failed=$false
    try{& $Action|Out-Null}catch{$failed=$true}
    Check $failed $Message
}
$candidate=Get-FastLlmVcRedistCandidate -ManifestPath (Join-Path $repo 'config/windows-prerequisites.json')
$temp=Join-Path $repo ('fastllm-vc-install-test-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp|Out-Null
try{
    $run=Join-Path $temp ('vc-redist-'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $run|Out-Null
    $prepared=Join-Path $run 'VC_redist.x64.exe'
    Check ((Assert-FastLlmVcRedistPreparedPath -Path $prepared -CacheRoot $temp) -ceq $prepared) 'Exact prepared path rejected.'
    Reject {Assert-FastLlmVcRedistPreparedPath -Path (Join-Path $run 'other.exe') -CacheRoot $temp} 'Other executable accepted.'
    Reject {Assert-FastLlmVcRedistPreparedPath -Path (Join-Path $temp 'VC_redist.x64.exe') -CacheRoot $temp} 'Artifact outside run accepted.'
    Reject {Assert-FastLlmVcRedistPreparedPath -Path (Join-Path (Join-Path $temp 'vc-redist-bad') 'VC_redist.x64.exe') -CacheRoot $temp} 'Non-GUID run accepted.'
    $broker=Get-FastLlmVcRedistBrokerText -PreparedPath $prepared -Candidate $candidate
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseInput($broker,[ref]$tokens,[ref]$errors)
    Check (@($errors).Count -eq 0) 'Elevated broker has PowerShell syntax errors.'
    Check ($broker.Contains("$([char]36)info.Arguments='/install /norestart'") -and
           -not $broker.Contains('/quiet') -and -not $broker.Contains('/passive')) 'Vendor installer must retain license UI and suppress automatic restart.'
    Check ($broker.Contains('[IO.Directory]::CreateDirectory($stage,$acl)') -and
           $broker.Contains('$acl.SetAccessRuleProtection($true,$false)') -and
           $broker.Contains('$acl.SetOwner($admins)') -and
           $broker.Contains('$actualAcl.GetAccessRules($true,$false,[Security.Principal.SecurityIdentifier])') -and
           $broker.Contains('if($seen.Count -ne 2)') -and
           $broker.Contains("'S-1-5-32-544'") -and $broker.Contains("'S-1-5-18'")) 'Stage ACL must be protected and admin/SYSTEM-only at creation.'
    Check ($broker.Contains('CheckArtifact $source') -and $broker.Contains('CheckArtifact $staged') -and
           $broker.IndexOf('CheckArtifact $source') -lt $broker.IndexOf('[IO.File]::Open($source') -and
           $broker.IndexOf('[IO.File]::Open($staged') -lt $broker.IndexOf('CheckArtifact $staged')) 'Source and protected copy must both be verified.'
    Check ($broker.Contains('[IO.FileMode]::CreateNew') -and $broker.Contains('if($copied -gt 18731856)') -and
           $broker.Contains('if($copied -ne 18731856)') -and -not $broker.Contains('[IO.File]::Copy')) 'Protected staging copy must be bounded to exact bytes.'
    Check ($broker.Contains("$([char]36)process.WaitForExit() # Never time out or kill a live Microsoft installer.") -and
           -not $broker.Contains('Kill(') -and -not $broker.Contains('Stop-Process')) 'Live Microsoft installer must not be killed on timeout.'
    Check ($broker.Contains('Get-AuthenticodeSignature -LiteralPath $path') -and
           $broker.Contains("'Valid'") -and $broker.Contains([string]$candidate.sha256) -and
           $broker.Contains([string]$candidate.signerThumbprint)) 'Protected copy must recheck exact signed package pins.'
    Check ($broker.Contains('[IO.File]::Delete($staged)') -and
           $broker.Contains('[IO.Directory]::Delete($stage,$false)') -and
           $broker.Contains('if(-not $vendorStarted -or $vendorExited)') -and
           $broker.Contains('if($exitCode -in @(3010,-2147021886)){$exitCode=51008}') -and
           -not $broker.Contains('Remove-Item -Recurse')) 'Cleanup must target only the known file and empty stage.'
    Check ($broker.Contains('RegistryView]::Registry64') -and
           $broker.Contains('if($missing){51007}else{51005}')) 'Elevated broker must skip an already registered equal or newer runtime.'
    foreach($case in @(
        @{code=0;state='installed-recheck-required'},@{code=3010;state='reboot-required'},
        @{code=-2147021886;state='reboot-required'},
        @{code=1602;state='installer-cancelled'},@{code=1638;state='other-version-recheck-required'},
        @{code=-2147023294;state='installer-cancelled'},@{code=-2147023258;state='other-version-recheck-required'},
        @{code=51002;state='broker-verification-or-launch-failed'},
        @{code=51003;state='stage-cleanup-failed-recheck-required'},
        @{code=51004;state='installer-state-uncertain'},
        @{code=51005;state='already-installed-needs-probe'},
        @{code=51006;state='prepared-artifact-unavailable-to-elevated-account'},
        @{code=51007;state='registered-runtime-incomplete-manual-repair'},
        @{code=51008;state='reboot-required-stage-cleanup-failed'},
        @{code=999;state='unclassified-exit-recheck-required'}
    )){
        Check ((Get-FastLlmVcRedistExitState -ExitCode $case.code) -ceq $case.state) "Wrong exit mapping $($case.code)."
    }
    Check ((Get-FastLlmVcRedistExitState -ExitCode 0 -UacCancelled $true) -ceq 'uac-cancelled') 'UAC cancellation must be distinct.'
    $cancel=[ComponentModel.Win32Exception]::new(1223)
    Check (Test-FastLlmVcRedistUacCancelled -Exception $cancel) 'Direct UAC cancellation was not recognized.'
    Check (Test-FastLlmVcRedistUacCancelled -Exception ([Exception]::new('wrapped',$cancel))) 'Wrapped UAC cancellation was not recognized.'
    Check (-not (Test-FastLlmVcRedistUacCancelled -Exception ([Exception]::new('wrapped',[ComponentModel.Win32Exception]::new(5))))) 'Other launch errors must not be labeled UAC cancellation.'
    $missing=[pscustomobject]@{applicable=$true;partial=$false;vcRuntimeRegistration=[pscustomobject]@{status='missing'}}
    Check ((Get-FastLlmVcRedistInstallDecision -Inventory $missing -CandidateVersion ([version]'14.51.36247.0')) -ceq 'offer-install') 'Missing runtime should offer installation.'
    foreach($v in @('14.51.36247.0','14.52.1.0')){
        $inventory=[pscustomobject]@{applicable=$true;partial=$false;vcRuntimeRegistration=[pscustomobject]@{
            status='observed';installed=$true;versionState='observed';version=$v}}
        Check ((Get-FastLlmVcRedistInstallDecision -Inventory $inventory -CandidateVersion ([version]'14.51.36247.0')) -ceq 'already-installed-needs-probe') 'Equal or newer runtime should not be installed.'
    }
    $uncertain=[pscustomobject]@{applicable=$true;partial=$true;vcRuntimeRegistration=$null}
    Check ((Get-FastLlmVcRedistInstallDecision -Inventory $uncertain -CandidateVersion ([version]'14.51.36247.0')) -ceq 'inventory-uncertain') 'Partial inventory should not authorize install.'
    $source=Get-Content -LiteralPath $helper -Raw
    Check ($source.Contains("$([char]36)info.Verb='runas'") -and $source.Contains('UseShellExecute=$true') -and
           $source.Contains('Start-FastLlmVcRedistInstall') -and $source.Contains('Complete-FastLlmVcRedistInstall') -and
           -not $source.Contains('ProcessHost')) 'UI handoff must expose live broker process without kill-on-close job.'
    Check ($source.Contains('if(-not $ConfirmInstall)') -and
           $source.Contains('Start-FastLlmVcRedistInstall -PreparedPath $PreparedPath') -and
           $source.Contains('-ConfirmInstall:$ConfirmInstall')) 'Direct UI helper must also require explicit confirmation.'
    $wrapper=Get-Content -LiteralPath $tool -Raw
    Check ($wrapper.Contains('[switch]$ConfirmInstall') -and $wrapper.Contains('if(-not $ConfirmInstall)') -and
           $wrapper.Contains('Invoke-FastLlmVcRedistInstall')) 'CLI must require explicit install confirmation.'
}finally{Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}
Write-Host "VC installer handoff tests passed: $count"
