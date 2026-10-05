#requires -Version 5.1
# Pure control-window decisions for the separately reviewed Microsoft VC++ lane.
function Get-FastLlmUiVcPrepareArguments {
    param([Parameter(Mandatory=$true)][string]$ProjectRoot,
          [Parameter(Mandatory=$true)][string]$CacheRoot)
    return @('-NoLogo','-NoProfile','-NonInteractive','-OutputFormat','Text','-File',
        (Join-Path $ProjectRoot 'tools/prepare-vc-runtime.ps1'),'-Action','Prepare','-CacheRoot',$CacheRoot)
}

function Test-FastLlmUiVcActionAllowed {
    param([bool]$BrokerActive,
          [ValidateSet('launch','stop','close','tray-exit','minimize','restore')][string]$Action)
    if($BrokerActive -and $Action -cne 'restore'){return $false}
    return $true
}

function Get-FastLlmUiVcBrokerObservation {
    param([Parameter(Mandatory=$true)]$Process)
    try{
        $exited=$Process.HasExited
        if($exited -isnot [bool]){return 'uncertain-live'}
        if($exited){return 'terminal'}
        return 'live'
    }catch{return 'uncertain-live'}
}

function Get-FastLlmUiVcOffer {
    param($Decision,[string]$InstallDecision)
    if(-not $Decision -or $Decision.canProceed -isnot [bool] -or
       $Decision.missing64BitHost -isnot [bool] -or
       $null -eq $Decision.missingVcRuntimeFiles -or $Decision.missingVcRuntimeFiles -isnot [array]){
        throw 'The setup decision is incomplete for VC++ guidance.'
    }
    if($InstallDecision -cnotin @('offer-install','already-installed-needs-probe','inventory-uncertain')){
        throw 'The VC++ registration decision is invalid.'
    }
    $missing=@($Decision.missingVcRuntimeFiles).Count -gt 0
    $offer=[bool](-not $Decision.canProceed -and -not $Decision.missing64BitHost -and $missing -and
        $InstallDecision -ceq 'offer-install')
    $message=if(-not $missing){'No missing VC++ runtime file was reported.'}
        elseif($Decision.missing64BitHost){'Use 64-bit Windows PowerShell before preparing the x64 runtime.'}
        elseif($InstallDecision -ceq 'already-installed-needs-probe'){
            'The same or a newer Microsoft VC++ x64 runtime is registered, but required files are missing. Use Microsoft repair or reinstall guidance, then Recheck; FastLLM will not install an older package over it.'
        }elseif($InstallDecision -ceq 'inventory-uncertain'){
            'The installed VC++ runtime registration could not be verified. Use Microsoft setup or repair guidance, then Recheck.'
        }else{'The reviewed Microsoft VC++ x64 package can be prepared for your review.'}
    return [pscustomobject]@{canPrepare=$offer;message=$message;installDecision=$InstallDecision}
}

function Assert-FastLlmUiVcPreparedReceipt {
    param($Receipt,$Candidate,[Parameter(Mandatory=$true)][string]$CacheRoot)
    if(-not $Receipt -or -not $Candidate -or $Receipt.status -cne 'prepared-not-installed' -or
        $Receipt.installerExecuted -isnot [bool] -or $Receipt.installerExecuted -or
        $Receipt.compatibilityQualified -isnot [bool] -or $Receipt.compatibilityQualified -or
        [string]$Receipt.version -cne [string]$Candidate.version -or
        [long]$Receipt.sizeBytes -ne [long]$Candidate.sizeBytes -or
        [string]$Receipt.sha256 -cne [string]$Candidate.sha256 -or
        [string]$Receipt.signatureStatus -cne 'Valid' -or
        [string]::IsNullOrWhiteSpace([string]$Receipt.path) -or
        -not [IO.Path]::IsPathRooted([string]$Receipt.path) -or
        [IO.Path]::GetFileName([string]$Receipt.path) -cne 'VC_redist.x64.exe'){
        throw 'The prepared Microsoft package receipt did not match the reviewed candidate.'
    }
    $full=[IO.Path]::GetFullPath([string]$Receipt.path)
    $run=[IO.Path]::GetDirectoryName($full)
    if([IO.Path]::GetFileName($run) -cnotmatch '^vc-redist-[0-9a-f]{32}$' -or
        -not [string]::Equals([IO.Path]::GetDirectoryName($run),[IO.Path]::GetFullPath($CacheRoot).TrimEnd('\','/'),
            [StringComparison]::OrdinalIgnoreCase)){
        throw 'The prepared Microsoft package was not in its dedicated cache.'
    }
    return $Receipt
}

function Format-FastLlmUiVcReview {
    param($Receipt,$Candidate,[Parameter(Mandatory=$true)][string]$CacheRoot)
    $null=Assert-FastLlmUiVcPreparedReceipt -Receipt $Receipt -Candidate $Candidate -CacheRoot $CacheRoot
    if([string]$Candidate.url -cnotmatch '^https://download\.visualstudio\.microsoft\.com/[A-Za-z0-9/._-]+/VC_redist\.x64\.exe$' -or
        [string]$Candidate.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        [string]$Candidate.version -cnotmatch '^[0-9]+(\.[0-9]+){3}$'){
        throw 'The Microsoft candidate is not suitable for display.'
    }
    return @(
        'Install Microsoft Visual C++ 2015–2022 Redistributable (x64)?',
        '',
        "Exact version: $($Candidate.version)",
        "Package: $($Candidate.fileName)",
        "Publisher: $($Candidate.signerSubject)",
        "Download URL: $($Candidate.url)",
        "Package size: $($Candidate.sizeBytes) bytes",
        "SHA-256: $($Candidate.sha256)",
        "Verified cache file: $($Receipt.path)",
        '',
        'Choosing Install requests Windows administrator approval (UAC) for a narrow Windows PowerShell broker. That broker verifies a protected copy of this exact package and launches the native Microsoft installer interactively. Review its prompts and license terms; FastLLM does not silently accept a license.',
        'The installer may require a restart. FastLLM does not restart Windows automatically. FastLLM will run a fresh setup check after a successful installation; GPU compatibility remains unqualified.',
        '',
        'Cancel keeps this as a prepared download only. FastLLM starts no elevated broker or Microsoft installer until you explicitly choose Install. The Microsoft installer process may open before you decide whether to accept its terms.'
    ) -join "`r`n"
}

function Get-FastLlmUiVcCompletion {
    param($Result)
    if(-not $Result -or $Result.status -cnotin @('installed-recheck-required','reboot-required',
         'uac-cancelled','installer-cancelled','other-version-recheck-required',
         'broker-verification-or-launch-failed','stage-cleanup-failed-recheck-required',
         'installer-state-uncertain','already-installed-needs-probe',
         'prepared-artifact-unavailable-to-elevated-account',
         'registered-runtime-incomplete-manual-repair','reboot-required-stage-cleanup-failed',
         'unclassified-exit-recheck-required') -or
       $Result.compatibilityQualified -isnot [bool] -or $Result.compatibilityQualified -or
       $Result.needsFreshProbe -isnot [bool] -or $Result.rebootRequired -isnot [bool]){
        throw 'Microsoft installer returned an invalid result.'
    }
    switch($Result.status){
        'installed-recheck-required' {
            if(-not $Result.needsFreshProbe -or $Result.rebootRequired){throw 'Successful VC++ result is inconsistent.'}
            return [pscustomobject]@{action='recheck';message='Microsoft reported installation success. FastLLM will run a fresh setup check and Vulkan engine probe before continuing.'}
        }
        'reboot-required' {
            if(-not $Result.rebootRequired){throw 'VC++ restart result is inconsistent.'}
            return [pscustomobject]@{action='defer';message='Microsoft requested a Windows restart. Restart when convenient, then open FastLLM and Recheck. FastLLM did not restart this PC.'}
        }
        'already-installed-needs-probe' {
            return [pscustomobject]@{action='defer';message='The same or a newer VC++ runtime is registered. Required files still need a fresh check; if missing, use Microsoft repair or reinstall guidance, then Recheck.'}
        }
        'registered-runtime-incomplete-manual-repair' {
            return [pscustomobject]@{action='defer';message='Microsoft VC++ registration is present but incomplete. Use Microsoft repair or reinstall guidance, then Recheck. FastLLM did not automatically replace it.'}
        }
        'other-version-recheck-required' {
            return [pscustomobject]@{action='defer';message='Microsoft reported another VC++ runtime version. Use Microsoft repair or reinstall guidance if required files remain missing, then Recheck.'}
        }
        'stage-cleanup-failed-recheck-required' {
            return [pscustomobject]@{action='defer';message='The Microsoft setup result needs a fresh check, and protected staging cleanup needs administrator review. Open Diagnostics, then Recheck after review.'}
        }
        'prepared-artifact-unavailable-to-elevated-account' {
            return [pscustomobject]@{action='defer';message='The administrator account could not access the prepared Microsoft package. Use the official Microsoft download and setup guidance, then Recheck.'}
        }
        'reboot-required-stage-cleanup-failed' {
            if(-not $Result.rebootRequired){throw 'VC++ restart result is inconsistent.'}
            return [pscustomobject]@{action='defer';message='Microsoft requested a restart, and protected staging cleanup needs administrator review. Restart Windows when convenient, review Diagnostics, then Recheck.'}
        }
        'uac-cancelled' {return [pscustomobject]@{action='defer';message='Administrator approval was cancelled. No Microsoft installer was started. Reopen FastLLM when ready to try again.'}}
        'installer-cancelled' {return [pscustomobject]@{action='defer';message='The Microsoft installer was cancelled. Review its license and setup prompts when ready, then Recheck.'}}
        default {return [pscustomobject]@{action='defer';message='Microsoft prerequisite setup did not complete cleanly. Open Diagnostics and Microsoft repair/download guidance, then Recheck. No compatibility claim was made.'}}
    }
}
