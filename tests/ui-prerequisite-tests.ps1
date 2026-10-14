#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'src/FastLlm.UiPrerequisite.ps1')
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'src/FastLlm.UiFlow.ps1')
$passed=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:passed++}
function Reject([scriptblock]$Action,[string]$Message){
    $rejected=$false
    try{& $Action | Out-Null}catch{$rejected=$true}
    Check $rejected $Message
}
$decision=[pscustomobject]@{canProceed=$false;missing64BitHost=$false;missingVcRuntimeFiles=@('MSVCP140.dll');missingVulkanLoader=$false}
$offer=Get-FastLlmUiVcOffer -Decision $decision -InstallDecision 'offer-install'
Check ($offer.canPrepare -and $offer.installDecision -ceq 'offer-install') 'Missing VC++ on x64 did not offer preparation.'
$decision.missing64BitHost=$true
Check (-not (Get-FastLlmUiVcOffer -Decision $decision -InstallDecision 'offer-install').canPrepare) '32-bit host offered x64 preparation.'
$decision.missing64BitHost=$false
$decision.missingVcRuntimeFiles=@()
Check (-not (Get-FastLlmUiVcOffer -Decision $decision -InstallDecision 'offer-install').canPrepare) 'No missing VC++ files still offered preparation.'
$decision.missingVcRuntimeFiles=@('MSVCP140.dll')
foreach($state in @('already-installed-needs-probe','inventory-uncertain')){
    $notOffered=Get-FastLlmUiVcOffer -Decision $decision -InstallDecision $state
    Check (-not $notOffered.canPrepare -and $notOffered.message -match 'repair|registration') "Unsafe installation offer for $state."
}
Reject {Get-FastLlmUiVcOffer -Decision $decision -InstallDecision 'made-up'} 'Unknown registration state was accepted.'

$root=Split-Path $PSScriptRoot -Parent
$cache=Join-Path $root 'test-vc-cache'
$arguments=@(Get-FastLlmUiVcPrepareArguments -ProjectRoot $root -CacheRoot $cache)
Check ($arguments.Count -eq 11 -and $arguments[5] -ceq '-File' -and
    $arguments[6] -ceq (Join-Path $root 'tools/prepare-vc-runtime.ps1') -and
    $arguments[7] -ceq '-Action' -and $arguments[8] -ceq 'Prepare' -and
    $arguments[9] -ceq '-CacheRoot' -and $arguments[10] -ceq $cache) 'Preparation child arguments are not fixed to the reviewed helper.'
foreach($action in @('launch','stop','close','tray-exit','minimize')){
    Check (-not (Test-FastLlmUiVcActionAllowed -BrokerActive $true -Action $action)) "Live broker permitted $action."
}
Check (Test-FastLlmUiVcActionAllowed -BrokerActive $true -Action restore) 'Live broker blocked window restore.'
Check (Test-FastLlmUiVcActionAllowed -BrokerActive $false -Action close) 'Terminal broker blocked normal close.'
$live=[pscustomobject]@{HasExited=$false}
$terminal=[pscustomobject]@{HasExited=$true}
$unknown=New-Object psobject
$unknown | Add-Member -MemberType ScriptProperty -Name HasExited -Value {throw 'transient process access failure'}
Check ((Get-FastLlmUiVcBrokerObservation -Process $live) -ceq 'live') 'Live broker was misclassified as terminal.'
Check ((Get-FastLlmUiVcBrokerObservation -Process $terminal) -ceq 'terminal') 'Exited broker was not observed as terminal.'
Check ((Get-FastLlmUiVcBrokerObservation -Process $unknown) -ceq 'uncertain-live') 'Process status-read failure was treated as terminal.'
Check (-not (Test-FastLlmUiVcActionAllowed -BrokerActive $true -Action close)) 'Uncertain broker state allowed window close.'

$candidate=[pscustomobject]@{version='14.51.36247.0';fileName='VC_redist.x64.exe';sizeBytes=18731856;
    sha256='843068991daaa1f73ad9f6239bce4d0f6a07a51f18c37ea2a867e9beca71295c';
    url='https://download.visualstudio.microsoft.com/download/pr/ebdab8e5-1d7b-4d9f-a11b-cbb1720c3b12/843068991DAAA1F73AD9F6239BCE4D0F6A07A51F18C37EA2A867E9BECA71295C/VC_redist.x64.exe';
    signerSubject='CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'}
$run=Join-Path $cache ('vc-redist-'+('a'*32))
$receipt=[pscustomobject]@{status='prepared-not-installed';path=(Join-Path $run 'VC_redist.x64.exe');
    version=$candidate.version;sizeBytes=$candidate.sizeBytes;sha256=$candidate.sha256;
    signatureStatus='Valid';installerExecuted=$false;compatibilityQualified=$false}
Check ($null -ne (Assert-FastLlmUiVcPreparedReceipt -Receipt $receipt -Candidate $candidate -CacheRoot $cache)) 'Exact prepared receipt was rejected.'
$review=Format-FastLlmUiVcReview -Receipt $receipt -Candidate $candidate -CacheRoot $cache
Check ($review.Contains($candidate.version) -and $review.Contains($candidate.url) -and
    $review.Contains($candidate.sha256) -and $review.Contains('license terms') -and
    $review.Contains('Windows PowerShell broker') -and $review.Contains('may open before') -and
    $review.Contains('UAC') -and $review.Contains('Cancel')) 'Review omitted exact package or explicit Microsoft approval disclosures.'
$receipt.sha256='0'*64
Reject {Assert-FastLlmUiVcPreparedReceipt -Receipt $receipt -Candidate $candidate -CacheRoot $cache} 'Mismatched prepared receipt digest was accepted.'
$receipt.sha256=$candidate.sha256
$receipt.installerExecuted=$true
Reject {Assert-FastLlmUiVcPreparedReceipt -Receipt $receipt -Candidate $candidate -CacheRoot $cache} 'Already executed receipt was accepted as preparation.'
$receipt.installerExecuted=$false
$receipt.path=Join-Path $root 'VC_redist.x64.exe'
Reject {Assert-FastLlmUiVcPreparedReceipt -Receipt $receipt -Candidate $candidate -CacheRoot $cache} 'Out-of-cache prepared receipt was accepted.'
$receipt.path=Join-Path $run 'VC_redist.x64.exe'

function Result([string]$Status,[bool]$Probe,[bool]$Reboot){
    return [pscustomobject]@{status=$Status;needsFreshProbe=$Probe;rebootRequired=$Reboot;compatibilityQualified=$false}
}
Check ((Get-FastLlmUiVcCompletion (Result 'installed-recheck-required' $true $false)).action -ceq 'recheck') 'Exit-zero success did not require a fresh setup check.'
Reject {Get-FastLlmUiVcCompletion (Result 'installed-recheck-required' $false $false)} 'Exit-zero success without fresh probe was accepted.'
Check ((Get-FastLlmUiVcCompletion (Result 'reboot-required' $false $true)).action -ceq 'defer') 'Reboot result did not defer serving.'
Check ((Get-FastLlmUiVcCompletion (Result 'reboot-required-stage-cleanup-failed' $false $true)).action -ceq 'defer') 'Reboot with cleanup failure did not defer serving.'
foreach($state in @('uac-cancelled','installer-cancelled','other-version-recheck-required',
       'registered-runtime-incomplete-manual-repair','prepared-artifact-unavailable-to-elevated-account',
       'unclassified-exit-recheck-required')){
    Check ((Get-FastLlmUiVcCompletion (Result $state $false $false)).action -ceq 'defer') "Failure state $state did not defer serving."
}
Reject {Get-FastLlmUiVcCompletion (Result 'unknown-success' $true $false)} 'Unknown broker outcome was accepted.'
$missingSetup=[pscustomobject]@{canProceed=$false;engineVerified=$false;missing64BitHost=$false;
    missingVcRuntimeFiles=@('MSVCP140.dll');missingVulkanLoader=$false;advisoryWarnings=@();compatibilityQualified=$false}
$successFlow=Move-FastLlmUiFlow -Flow (New-FastLlmUiFlow -Mode start) -Event 'setup-complete' -SetupDecision $missingSetup
Check ($successFlow.phase -ceq 'setup-attention') 'Missing runtime did not pause the normal start flow.'
$successOutcome=Get-FastLlmUiVcCompletion (Result 'installed-recheck-required' $true $false)
if($successOutcome.action -ceq 'recheck'){$successFlow=Move-FastLlmUiFlow -Flow $successFlow -Event 'setup-recheck'}
Check ($successFlow.phase -ceq 'setup' -and $successFlow.planAttempts -eq 0) 'Install success bypassed fresh setup/engine check.'
$rebootFlow=Move-FastLlmUiFlow -Flow (New-FastLlmUiFlow -Mode start) -Event 'setup-complete' -SetupDecision $missingSetup
$rebootOutcome=Get-FastLlmUiVcCompletion (Result 'reboot-required' $false $true)
if($rebootOutcome.action -ceq 'defer'){$rebootFlow=Move-FastLlmUiFlow -Flow $rebootFlow -Event 'setup-defer'}
Check ($rebootFlow.phase -ceq 'cancelled') 'Reboot result continued the start flow.'
Write-Host "UI prerequisite tests passed: $passed"
