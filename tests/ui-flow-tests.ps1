#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/FastLlm.UiFlow.ps1')
$checks=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:checks++}
function Clone($Value){return ($Value|ConvertTo-Json -Depth 16|ConvertFrom-Json)}
function Plan($Model,$Inventory){return [pscustomobject]@{
    model=$Model;hardwareFingerprint=$Inventory
    selectedAdapters=@([pscustomobject]@{device='Vulkan0';name='AMD Radeon RX 7900 XTX'})
}}
$catalog=Get-Content -LiteralPath (Join-Path $root 'config/catalog.json') -Raw|ConvertFrom-Json
$large=Clone (@($catalog.models|Where-Object id -eq 'qwen3.8-27b-ud-q4-k-m')[0])
if(-not $large){$large=Clone $catalog.models[0]}
$small=Clone $catalog.models[0]
$largePlan=Plan $large 'large-card'
$smallPlan=Plan $small 'small-card'
function SetupDiagnostic([bool]$EngineVerified=$true,[string[]]$MissingVc=@(),[bool]$VulkanPresent=$true,[bool]$Host64=$true) {
    $ready=$Host64 -and $VulkanPresent -and $MissingVc.Count -eq 0
    return [pscustomobject]@{
        windows=$true;vulkanVerified=$EngineVerified;error=$(if($ready -and $EngineVerified){$null}else{'setup unavailable'})
        windowsPrerequisites=[pscustomobject]@{
            applicable=$true;ready=[bool]$ready;is64BitProcess=$Host64
            vulkanLoaderPresent=$VulkanPresent;missingVcRuntimeFiles=@($MissingVc)
        }
        prerequisiteInventory=$null;prerequisiteInventoryError='prerequisite-inventory-unavailable'
    }
}
function ReadySetup([bool]$EngineVerified=$true) {
    $code=if($EngineVerified){0}else{2}
    return Get-FastLlmUiSetupDecision -Diagnostic (SetupDiagnostic -EngineVerified:$EngineVerified) -ExitCode $code
}

$digest=Get-FastLlmUiModelProvenanceDigest -Model $large
Check ($digest -cmatch '^[0-9a-f]{64}$') 'Provenance digest is versioned canonical SHA-256.'
Assert-FastLlmUiExpectedProvenance -Model $large -ExpectedSha256 $digest
$fields=@('id','upstreamModel','upstreamRevision','upstreamLicense','upstreamLicenseSha256',
    'upstreamLicenseUrl','repository','revision','artifactLicense','artifactProvider',
    'license','artifactLicenseMetadataUrl','sha256','sizeBytes','url','file','servingMode')
foreach($field in $fields){
    $changed=Clone $large
    if($field -eq 'sizeBytes'){$changed.sizeBytes=[int64]$changed.sizeBytes+1}
    else{$changed.$field=[string]$changed.$field+'-changed'}
    $rejected=$false
    try{Assert-FastLlmUiExpectedProvenance -Model $changed -ExpectedSha256 $digest}catch{$rejected=$true}
    Check $rejected "Changed $field cannot reuse a previously approved digest."
}
$rejected=$false
try{Assert-FastLlmUiExpectedProvenance -Model $large -ExpectedSha256 ''}catch{$rejected=$true}
Check $rejected 'Empty expected digest cannot authorize consent.'
$consentText=Format-FastLlmUiModelConsent -Plan $largePlan
foreach($value in @([string]$large.id,[string]$large.upstreamModel,[string]$large.upstreamRevision,
    [string]$large.upstreamLicense,[string]$large.upstreamLicenseUrl,[string]$large.upstreamLicenseSha256,
    [string]$large.repository,[string]$large.revision,[string]$large.artifactProvider,
    [string]$large.artifactLicense,[string]$large.license,[string]$large.artifactLicenseMetadataUrl,
    [string]$large.url,[string]$large.sha256,[string]$large.file,[string]$large.servingMode)) {
    Check ($consentText.Contains($value)) "License review displays exact catalog value '$value'."
}
Check ($consentText.Contains("$($large.contextSize) tokens") -and
    $consentText.Contains(([long]$large.sizeBytes).ToString()) -and
    $consentText.Contains($digest)) 'License review includes context, byte size, and the exact provenance binding.'
$malformedPlan=Plan (Clone $large) 'large-card'
$malformedPlan.model.upstreamLicense="Apache`nNot Apache"
$rejected=$false
try{Format-FastLlmUiModelConsent -Plan $malformedPlan | Out-Null}catch{$rejected=$true}
Check $rejected 'Control characters cannot spoof a license-review line.'
foreach($spoof in @([char]0x202e,[char]0x2066,[char]0x2028,[char]0x2029)){
    $malformedPlan=Plan (Clone $large) 'large-card'
    $malformedPlan.model.upstreamModel="Qwen${spoof}changed"
    $rejected=$false
    try{Format-FastLlmUiModelConsent -Plan $malformedPlan | Out-Null}catch{$rejected=$true}
    Check $rejected "Unicode display control U+$([int][char]$spoof) cannot spoof a consent field."
}
$malformedPlan=Plan (Clone $large) 'large-card'
$malformedPlan.model.artifactLicenseMetadataUrl='x' * 4097
$rejected=$false
try{Format-FastLlmUiModelConsent -Plan $malformedPlan | Out-Null}catch{$rejected=$true}
Check $rejected 'Oversized provenance cannot be truncated into consent.'

$tray=New-FastLlmUiTrayState
Check ($tray.visibility -eq 'window' -and -not $tray.iconReady -and -not $tray.closed) 'The window starts visible without a tray icon.'
$rejected=$false
try{Move-FastLlmUiTrayState -State $tray -Event minimize | Out-Null}catch{$rejected=$true}
Check ($rejected -and $tray.visibility -eq 'window') 'A failed tray creation cannot hide the control window.'
$tray=Move-FastLlmUiTrayState -State $tray -Event icon-ready
$tray=Move-FastLlmUiTrayState -State $tray -Event minimize
Check ($tray.visibility -eq 'tray' -and $tray.iconReady) 'Explicit minimize keeps a live tray owner.'
$rejected=$false
try{Move-FastLlmUiTrayState -State $tray -Event minimize | Out-Null}catch{$rejected=$true}
Check $rejected 'Repeated minimize cannot create a second hidden state.'
$tray=Move-FastLlmUiTrayState -State $tray -Event restore
Check ($tray.visibility -eq 'window') 'Restore returns the existing window.'
$tray=Move-FastLlmUiTrayState -State $tray -Event minimize
$tray=Move-FastLlmUiTrayState -State $tray -Event close
Check ($tray.closed -and $tray.visibility -eq 'closed') 'Exit closes rather than detaching a hidden process.'
$rejected=$false
try{Move-FastLlmUiTrayState -State $tray -Event restore | Out-Null}catch{$rejected=$true}
Check $rejected 'A closed tray owner cannot be restored.'

$flow=New-FastLlmUiFlow -Mode install
Check ($flow.phase -eq 'setup') 'First installation begins with a read-only setup check.'
$flow=Move-FastLlmUiFlow $flow setup-complete -SetupDecision (ReadySetup -EngineVerified:$false)
Check ($flow.phase -eq 'engine') 'Presence-ready first installation provisions the engine.'
$flow=Move-FastLlmUiFlow $flow engine-complete
Check ($flow.phase -eq 'preview') 'Engine success requires a live plan preview.'
$flow=Move-FastLlmUiFlow $flow preview-complete -Plan $largePlan -HasConsent:$false -HasArtifact:$false
Check ($flow.phase -eq 'consent' -and $flow.planAttempts -eq 1) 'First exact artifact requires consent.'
$flow=Move-FastLlmUiFlow $flow consent-approved
Check ($flow.phase -eq 'model-download' -and $flow.acceptNewConsent -and $flow.pendingProvenance -ceq $digest) 'Approval binds only the displayed digest.'
$flow=Move-FastLlmUiFlow $flow model-complete
Check ($flow.phase -eq 'preview' -and -not $flow.acceptNewConsent) 'Download success re-probes rather than starting a stale plan.'
$flow=Move-FastLlmUiFlow $flow preview-complete -Plan $largePlan -HasConsent:$true -HasArtifact:$true
Check ($flow.phase -eq 'serving' -and -not $flow.acceptNewConsent) 'Matching cached artifact serves without generic license acceptance.'
$flow=Move-FastLlmUiFlow $flow serving-complete
Check ($flow.phase -eq 'complete') 'A clean foreground end completes the workflow.'

$cached=New-FastLlmUiFlow -Mode start
$cached=Move-FastLlmUiFlow $cached setup-complete -SetupDecision (ReadySetup)
Check ($cached.phase -eq 'preview') 'Verified cached start proceeds to preview.'
$cached=Move-FastLlmUiFlow $cached preview-complete -Plan $largePlan -HasConsent:$true -HasArtifact:$true
Check ($cached.phase -eq 'serving' -and $cached.planAttempts -eq 1) 'Cached restart skips engine/download/consent.'
$cached=Move-FastLlmUiFlow $cached serving-failed -ErrorMessage 'card changed'
Check ($cached.phase -eq 'preview') 'Failed unattended start gets one fresh selection check.'
$cached=Move-FastLlmUiFlow $cached preview-complete -Plan $smallPlan -HasConsent:$false -HasArtifact:$false
Check ($cached.phase -eq 'consent' -and $cached.pendingProvenance -cne $digest) 'Large-to-small swap prompts for the new exact artifact.'
$cached=Move-FastLlmUiFlow $cached consent-approved
$cached=Move-FastLlmUiFlow $cached model-complete
$cached=Move-FastLlmUiFlow $cached preview-complete -Plan $smallPlan -HasConsent:$true -HasArtifact:$true
Check ($cached.phase -eq 'serving' -and $cached.planAttempts -eq 3) 'Small-card acquisition re-probes within the UI budget.'
$back=New-FastLlmUiFlow -Mode start
$back=Move-FastLlmUiFlow $back setup-complete -SetupDecision (ReadySetup)
$back=Move-FastLlmUiFlow $back preview-complete -Plan $largePlan -HasConsent:$true -HasArtifact:$true
Check ($back.phase -eq 'serving' -and -not $back.acceptNewConsent) 'Small-to-large swap reuses exact cached receipt.'

$decline=New-FastLlmUiFlow -Mode start
$decline=Move-FastLlmUiFlow $decline setup-complete -SetupDecision (ReadySetup)
$decline=Move-FastLlmUiFlow $decline preview-complete -Plan $largePlan -HasConsent:$false -HasArtifact:$false
$decline=Move-FastLlmUiFlow $decline consent-declined
Check ($decline.phase -eq 'cancelled' -and -not $decline.pendingPlan) 'Declined consent never reaches acquisition.'

$changed=New-FastLlmUiFlow -Mode start
$changed=Move-FastLlmUiFlow $changed setup-complete -SetupDecision (ReadySetup)
$changed=Move-FastLlmUiFlow $changed preview-complete -Plan $largePlan -HasConsent:$false -HasArtifact:$false
$changed=Move-FastLlmUiFlow $changed consent-approved
$changed=Move-FastLlmUiFlow $changed model-complete
$changed=Move-FastLlmUiFlow $changed preview-complete -Plan $smallPlan -HasConsent:$false -HasArtifact:$false
Check ($changed.phase -eq 'consent' -and -not $changed.acceptNewConsent -and $changed.pendingProvenance -cne $digest) 'Changed selection after download discards old approval.'

$same=New-FastLlmUiFlow -Mode start
$same=Move-FastLlmUiFlow $same setup-complete -SetupDecision (ReadySetup)
$same=Move-FastLlmUiFlow $same preview-complete -Plan $largePlan -HasConsent:$true -HasArtifact:$true
$same=Move-FastLlmUiFlow $same serving-failed -ErrorMessage 'server failed'
$same=Move-FastLlmUiFlow $same preview-complete -Plan $largePlan -HasConsent:$true -HasArtifact:$true
Check ($same.phase -eq 'failed' -and $same.lastStartError -eq 'server failed') 'Unchanged failed start is shown, not retried.'
$limit=New-FastLlmUiFlow -Mode start
$limit=Move-FastLlmUiFlow $limit setup-complete -SetupDecision (ReadySetup)
for($i=0;$i -lt 3;$i++){
    $limit=Move-FastLlmUiFlow $limit preview-complete -Plan $largePlan -HasConsent:$true -HasArtifact:$false
    $limit=Move-FastLlmUiFlow $limit model-complete
}
$limit=Move-FastLlmUiFlow $limit preview-complete -Plan $largePlan -HasConsent:$true -HasArtifact:$false
Check ($limit.phase -eq 'failed' -and $limit.planAttempts -eq 4) 'Plan/provision churn is bounded to three previews.'
$stopped=Move-FastLlmUiFlow (New-FastLlmUiFlow -Mode start) stop
Check ($stopped.phase -eq 'cancelled') 'Stop cancels pending transitions.'
$errorFlow=Move-FastLlmUiFlow (New-FastLlmUiFlow -Mode start) error -ErrorMessage 'probe failed'
Check ($errorFlow.phase -eq 'failed') 'Unexpected child failure does not continue.'

$cleanStart=Move-FastLlmUiFlow (New-FastLlmUiFlow -Mode start) setup-complete -SetupDecision (ReadySetup -EngineVerified:$false)
Check ($cleanStart.phase -eq 'engine' -and $cleanStart.planAttempts -eq 0) 'Start on a clean machine provisions the missing engine before preview.'
$cleanStart=Move-FastLlmUiFlow $cleanStart engine-complete
Check ($cleanStart.phase -eq 'preview') 'Clean-machine Start previews only after verified engine provisioning.'
$missingVc=Get-FastLlmUiSetupDecision -Diagnostic (SetupDiagnostic -MissingVc @('MSVCP140.dll')) -ExitCode 2
Check (-not $missingVc.canProceed -and @($missingVc.missingVcRuntimeFiles).Count -eq 1 -and -not $missingVc.compatibilityQualified) 'Missing VC file pauses without a compatibility claim.'
$missingVulkan=Get-FastLlmUiSetupDecision -Diagnostic (SetupDiagnostic -VulkanPresent:$false) -ExitCode 2
Check (-not $missingVulkan.canProceed -and $missingVulkan.missingVulkanLoader) 'Missing Vulkan loader pauses before engine or model work.'
$missing64=Get-FastLlmUiSetupDecision -Diagnostic (SetupDiagnostic -Host64:$false) -ExitCode 2
Check (-not $missing64.canProceed -and $missing64.missing64BitHost) 'A 32-bit UI host reaches actionable setup guidance without attempting a native engine.'
$attention=Move-FastLlmUiFlow (New-FastLlmUiFlow -Mode start) setup-complete -SetupDecision $missingVc
Check ($attention.phase -eq 'setup-attention' -and $attention.planAttempts -eq 0) 'Missing prerequisites enter user-action state without consuming a plan preview.'
$attention=Move-FastLlmUiFlow $attention setup-recheck
Check ($attention.phase -eq 'setup' -and -not $attention.pendingPlan -and -not $attention.acceptNewConsent) 'Recheck launches a fresh setup phase without stale approval.'
$attention=Move-FastLlmUiFlow $attention setup-complete -SetupDecision (ReadySetup)
Check ($attention.phase -eq 'preview' -and $attention.planAttempts -eq 0) 'Successful recheck proceeds once without an automatic loop.'
$deferred=Move-FastLlmUiFlow (New-FastLlmUiFlow -Mode install) setup-complete -SetupDecision $missingVulkan
$deferred=Move-FastLlmUiFlow $deferred setup-defer
Check ($deferred.phase -eq 'cancelled' -and -not $deferred.setupDecision) 'Do later clears pending setup flow.'
$invalid=SetupDiagnostic
$invalid.windowsPrerequisites.ready=$false
$rejected=$false
try{Get-FastLlmUiSetupDecision -Diagnostic $invalid -ExitCode 0 | Out-Null}catch{$rejected=$true}
Check $rejected 'Contradictory presence result fails closed.'
$invalid=SetupDiagnostic
$invalid.windowsPrerequisites.missingVcRuntimeFiles='MSVCP140.dll'
$rejected=$false
try{Get-FastLlmUiSetupDecision -Diagnostic $invalid -ExitCode 0 | Out-Null}catch{$rejected=$true}
Check $rejected 'Malformed runtime file shape fails closed.'
$invalid=SetupDiagnostic
$invalid.PSObject.Properties.Remove('windowsPrerequisites')
$rejected=$false
try{Get-FastLlmUiSetupDecision -Diagnostic $invalid -ExitCode 0 | Out-Null}catch{$rejected=$true}
Check $rejected 'Unavailable prerequisite report fails closed.'
$rejected=$false
try{Get-FastLlmUiSetupDecision -Diagnostic (SetupDiagnostic) -ExitCode 2 | Out-Null}catch{$rejected=$true}
Check $rejected 'Inconsistent doctor exit status fails closed.'
$inventory=SetupDiagnostic
$inventory.prerequisiteInventory=[pscustomobject]@{schemaVersion=1;applicable=$true;qualified=$false;compatibilityVerified=$false;partial=$true}
$inventory.prerequisiteInventoryError=$null
$decision=Get-FastLlmUiSetupDecision -Diagnostic $inventory -ExitCode 0
Check ($decision.canProceed -and @($decision.advisoryWarnings).Count -eq 1 -and -not $decision.compatibilityQualified) 'Incomplete registration/signature observations warn but do not replace the presence gate.'
$jsonDecision=Get-FastLlmUiSetupDecision -Diagnostic (Clone (SetupDiagnostic -EngineVerified:$false)) -ExitCode 2
Check ($jsonDecision.canProceed -and -not $jsonDecision.engineVerified) 'Doctor JSON roundtrip preserves clean-machine Start routing.'
$inventory.prerequisiteInventory.partial=$false
$decision=Get-FastLlmUiSetupDecision -Diagnostic $inventory -ExitCode 0
Check ($decision.canProceed -and @($decision.advisoryWarnings).Count -eq 1) 'Ambiguous inventory metadata warns even when partial is false.'

$cli=Get-Content -LiteralPath (Join-Path $root 'fast-llm.ps1') -Raw
$ui=Get-Content -LiteralPath (Join-Path $root 'fast-llm-ui.ps1') -Raw
Check ($cli.Contains('Assert-FastLlmUiExpectedProvenance -Model $plan.model') -and
    $cli.IndexOf('Assert-FastLlmUiExpectedProvenance -Model $plan.model') -lt $cli.IndexOf('Install-FastLlmModel -Plan $plan')) 'CLI checks freshly resolved exact provenance before acquisition.'
Check ($cli.IndexOf('Assert-FastLlmUiExpectedProvenance -Model $reviewModel[0]') -lt
    $cli.IndexOf('Install-FastLlmEngines -CatalogPath $catalogPath')) 'Stale reviewed provenance is rejected before even repairing the engine.'
Check ($ui.Contains("'-ExpectedModelProvenanceSha256'") -and $ui.Contains('if($script:flow.acceptNewConsent)')) 'Only new GUI consent supplies the guarded acceptance switch.'
Check (-not $ui.Contains('Read-Host')) 'The GUI never launches a hidden interactive license prompt.'
Check ($ui.Contains("LaunchStep 'setup check' (@('doctor')+") -and
    $ui.Contains('Get-FastLlmUiSetupDecision -Diagnostic $diagnostic -ExitCode $code')) 'Both buttons reuse a validated read-only doctor child before acquisition.'
Check ($ui.Contains('ShowSetupAttention') -and $ui.Contains("'setup-recheck'") -and $ui.Contains("'setup-defer'")) 'The setup dialog offers explicit recheck and deferral.'
Check ($ui.Contains('https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist') -and
    $ui.Contains('https://www.amd.com/en/support/download/drivers.html') -and
    $ui.Contains(".ScrollBars='Vertical'")) 'Setup action uses fixed official links and a scrollable explanation.'
Check ($ui.Contains("'-ModelId'") -and $ui.Contains("selection=@('-InstallRoot'")) 'Setup recheck preserves the exact model and context selection.'
Check ($ui.Contains('Format-FastLlmUiModelConsent -Plan $Plan') -and
    $ui.Contains('.AcceptButton=$cancel') -and $ui.Contains('.CancelButton=$cancel') -and
    $ui.Contains(".ScrollBars='Vertical'") -and -not $ui.Contains('$accept.TabStop=$false')) 'Consent defaults Enter and Escape to Cancel, while focused Accept remains keyboard-accessible.'
Check ($ui.Contains("ButtonAt 'Minimize to tray'") -and
    $ui.Contains('EnsureTrayIcon') -and $ui.Contains('$form.Hide()') -and
    $ui.IndexOf('EnsureTrayIcon', $ui.IndexOf('function MinimizeToTray')) -lt $ui.IndexOf('$form.Hide()', $ui.IndexOf('function MinimizeToTray'))) 'The explicit tray button creates the icon before hiding the window.'
Check ($ui.Contains("Items.Add('Restore FastLLM')") -and
    $ui.Contains("Items.Add('Stop inference / download')") -and
    $ui.Contains("Items.Add('Exit FastLLM')") -and
    $ui.Contains('function ExitFromTray') -and $ui.Contains('$form.Close()')) 'Tray controls restore, stop, and explicitly close the supervised window.'
Check ($ui.Contains('function StopUiOperation') -and $ui.Contains('$stopButton.Add_Click({try{StopUiOperation}') -and
    $ui.Contains('$stopItem.Add_Click({try{StopUiOperation}')) 'Window and tray Stop use the same run-scoped cleanup action.'
Check ($ui.Contains('DisposeTrayControls;$timer.Dispose();$form.Dispose()') -and
    $ui.Contains('DisposeTrayControls') -and
    @([regex]::Matches($ui,'New-Object Bitworks\.FastLlm\.ProcessHost')).Count -eq 1) 'One ProcessHost owns the child and tray controls are disposed even on an exceptional close.'
Check ($ui.Contains('[Windows.Forms.Application]::Run($form)') -and
    -not $ui.Contains('$form.ShowDialog()')) 'The main window uses a message loop that survives an explicit Hide-to-tray transition.'
$trayHandlerStart=$ui.IndexOf('$trayButton.Add_Click')
$trayHandlerEnd=$ui.IndexOf('$timer=New-Object', $trayHandlerStart)
Check ($trayHandlerStart -ge 0 -and $trayHandlerEnd -gt $trayHandlerStart) 'The explicit tray click handler is present.'
$trayHandler=$ui.Substring($trayHandlerStart,$trayHandlerEnd-$trayHandlerStart)
Check (-not $trayHandler.Contains('ShowFailure') -and -not $trayHandler.Contains('SetBusy') -and
    -not $trayHandler.Contains('child.Dispose') -and $trayHandler.Contains('$form.Show()')) 'A tray creation failure leaves the existing child, busy controls, and window intact.'
Check ($ui.Contains('if($script:child){') -and
    $ui.Contains('The active operation remains supervised; use Stop if needed.') -and
    $ui.Contains('SetBusy $true')) 'An unrelated actionable failure cannot re-enable Start while a supervised child remains active.'
Check ($ui.Contains('function RevealUiForAction') -and
    $ui.Contains('function ShowSetupAttention($Decision,$Diagnostic) {') -and
    $ui.Contains('function ShowExactModelConsent($Plan) {') -and
    $ui.Contains('function ShowFailure($Message){') -and
    @([regex]::Matches($ui,'RevealUiForAction')).Count -ge 4) 'Actionable setup, consent, and failure paths can restore a hidden window.'
Check (@([regex]::Matches($ui,'SetTrayMenuAvailable \$false')).Count -ge 3 -and
    @([regex]::Matches($ui,'SetTrayMenuAvailable \$true')).Count -ge 3) 'Tray menu actions are disabled during modal user decisions and restored afterward.'
Check ($ui.Contains('$form.Add_FormClosing({param($sender,$event)') -and
    $ui.Contains('$event.Cancel=$true;SetTrayMenuAvailable $true;return')) 'Close confirmation blocks tray reentrancy and restores its controls if cancelled.'
$uiTokens=$null;$uiParseErrors=$null
$null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'fast-llm-ui.ps1'),[ref]$uiTokens,[ref]$uiParseErrors)
Check (@($uiParseErrors).Count -eq 0) 'The Windows control-window script parses.'

# Execute the actual CLI install branch with all I/O boundaries replaced. This
# exercises ordering, not a fixture-powered production install or native child.
$tokens=$null;$parseErrors=$null
$tree=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'fast-llm.ps1'),[ref]$tokens,[ref]$parseErrors)
Check (@($parseErrors).Count -eq 0) 'The CLI install branch parses.'
$switch=@($tree.FindAll({param($node) $node -is [Management.Automation.Language.SwitchStatementAst]},$true))[0]
$installClause=@($switch.Clauses | Where-Object { $_.Item1.Extent.Text -ceq "'install'" })[0]
$branchText=$installClause.Item2.Extent.Text
$installBranch=[scriptblock]::Create($branchText.Substring(1,$branchText.Length-2))
$oldOs=$env:OS
try {
    $env:OS='Windows_NT'
    $InstallRoot='synthetic-no-files';$catalogPath='synthetic-catalog';$ModelId=[string]$large.id;$HardwareFile=$null
    $ExpectedModelProvenanceSha256=$digest;$EngineOnly=$false;$DryRun=$false
    $AsJson=$true;$Unattended=$true;$AcceptModelLicense=$true;$Profile='balanced'
    $selectionOptions=@{ModelId=$ModelId;ContextSize=0;AllowExperimentalModel=$false}
    $script:mockCatalogModel=Clone $large
    $script:mockPlanModel=Clone $large
    $script:engineCalls=0;$script:modelCalls=0
    function Get-FastLlmCatalog {param($CatalogPath) return [pscustomobject]@{models=@($script:mockCatalogModel)}}
    function Install-FastLlmEngines {param($CatalogPath,$InstallRoot) $script:engineCalls++}
    function Get-FastLlmHardware {param($HardwareFile,$CatalogPath,$InstallRoot) return [pscustomobject]@{backend='Vulkan'}}
    function Get-FastLlmPlan {param($Hardware,$CatalogPath,$Profile,$InstallRoot,$ModelId,$ContextSize,$AllowExperimentalModel) return [pscustomobject]@{model=$script:mockPlanModel}}
    function Write-FastLlmPlan {param($Plan)}
    function Install-FastLlmModel {param($Plan,$InstallRoot,$AcceptModelLicense,$Unattended) $script:modelCalls++;return 'synthetic-model'}
    function Write-FastLlmState {param($InstallRoot,$State)}

    $script:mockCatalogModel.repository='changed/conversion'
    $rejected=$false
    try{& $installBranch}catch{$rejected=$true}
    Check ($rejected -and $script:engineCalls -eq 0 -and $script:modelCalls -eq 0) 'Changed catalog conversion is rejected before engine or model acquisition.'
    $script:mockCatalogModel=Clone $large
    foreach($field in @('upstreamRevision','upstreamLicense','repository','revision','sha256')){
        $script:mockPlanModel=Clone $large
        $script:mockPlanModel.$field=[string]$script:mockPlanModel.$field+'-changed'
        $before=$script:engineCalls
        $rejected=$false
        try{& $installBranch}catch{$rejected=$true}
        Check ($rejected -and $script:engineCalls -eq ($before+1) -and $script:modelCalls -eq 0) "Changed resolved $field is rejected before model acquisition or receipt."
    }
    $script:mockPlanModel=Clone $large
    & $installBranch | Out-Null
    Check ($script:engineCalls -eq 6 -and $script:modelCalls -eq 1) 'Unchanged exact provenance reaches the existing mocked install path.'
} finally {
    $env:OS=$oldOs
}
Write-Output "UI flow tests passed: $checks"
