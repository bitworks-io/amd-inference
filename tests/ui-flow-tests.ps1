#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/FastLlm.UiFlow.ps1')
. (Join-Path $root 'src/FastLlm.Update.ps1')
. (Join-Path $root 'src/FastLlm.Components.ps1')
Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force
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
# Windows PowerShell 5.1 ConvertFrom-Json emits a JSON array as one object: the recipe list from the CLI must be unrolled into one row per recipe.
Check ($ui.Contains('ShowRecipeChooser @((ConvertFrom-Json $text) | ForEach-Object { $_ })') -and -not $ui.Contains('ShowRecipeChooser @(ConvertFrom-Json $text)')) 'the recipe list JSON is unrolled into one row per recipe (Windows PowerShell 5.1 ConvertFrom-Json)'
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
$plan = [pscustomobject]@{ selectedAdapters = @([pscustomobject]@{ name = 'AMD Radeon RX 7900 XTX' })
    model = [pscustomobject]@{ id = 'qwen3.8-27b-ud-q4-k-m'; quantization = 'UD-Q4_K_M'; contextSize = 32768 }
    recipe = [pscustomobject]@{ label = 'Measured by Bitworks on this card'; evidenceUrl = 'https://bitworks.io/amd/results/x' } }
$text = Format-FastLlmUiRecipeSummary -Plan $plan
Check ($text -eq 'Best setup for your AMD Radeon RX 7900 XTX: qwen3.8-27b-ud-q4-k-m (UD-Q4_K_M), 32,768 context. Measured by Bitworks on this card.') 'recipe summary text is exact'
Check ((Get-FastLlmUiEvidenceUrl -Plan $plan) -eq 'https://bitworks.io/amd/results/x') 'evidence link is the recipe page'
$plan.recipe.evidenceUrl = 'https://evil.example/x'
Check ($null -eq (Get-FastLlmUiEvidenceUrl -Plan $plan)) 'only https bitworks.io links are offered'
$plan.recipe = $null
Check ((Format-FastLlmUiRecipeSummary -Plan $plan).EndsWith('Estimated for your card.')) 'a plan without a recipe is labelled estimated'
Check ((Format-FastLlmUiSelfTest -SelfTest ([pscustomobject]@{ status = 'pass'; generationTokS = 32.5; promptTokS = 650 })) -eq 'Self-test passed: 32.5 tok/s generation, 650 tok/s prompt.') 'self-test pass text'
Check ((Format-FastLlmUiSelfTest -SelfTest ([pscustomobject]@{ status = 'below-expected'; generationTokS = 20; promptTokS = 400; expectedGenerationTokS = 32.7 })) -like 'Self-test: slower than expected*20*32.7*doctor*') 'below-expected text names the gap and doctor'
Check ((Format-FastLlmUiSelfTest -SelfTest ([pscustomobject]@{ status = 'skipped'; reasons = @('context-too-small') })) -eq 'Self-test skipped: the context size is too small for the performance check.') 'a skipped self-test is not reported as a failure'
Check ($null -eq (Get-FastLlmUiBarNote -State ([pscustomobject]@{ barGuidance = [pscustomobject]@{ shown = $false; text = $null } }))) 'no BAR note when not shown'
Check ((Get-FastLlmUiBarNote -State ([pscustomobject]@{ barGuidance = [pscustomobject]@{ shown = $true; text = 'Resizable BAR (AMD Smart Access Memory) appears to be off on this PC. x' } })) -like 'Resizable BAR*') 'BAR note passes through the runtime text'
$uiRoot = Join-Path ([IO.Path]::GetTempPath()) ('ui-set-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $uiRoot | Out-Null
Check ((Read-FastLlmUiSettings -InstallRoot $uiRoot).vulkanBarMitigation -eq 'auto') 'BAR setting defaults to auto'
Write-FastLlmUiSettings -InstallRoot $uiRoot -Settings ([pscustomobject]@{ vulkanBarMitigation = 'off' })
Check ((Read-FastLlmUiSettings -InstallRoot $uiRoot).vulkanBarMitigation -eq 'off') 'BAR setting persists'
Set-Content -LiteralPath (Join-Path $uiRoot 'settings.json') -Value '{"vulkanBarMitigation":"sideways"}' -Encoding ascii
Check ((Read-FastLlmUiSettings -InstallRoot $uiRoot).vulkanBarMitigation -eq 'auto') 'an invalid stored value falls back to auto'
# The preview's measured recipe is passed to the start , and the running plan's recipe drives the label and link.
$measuredPlan = [pscustomobject]@{ recipe = [pscustomobject]@{ id = 'rx-7900-xtx.qwen3.8-27b-ud-q4-k-m.32k'; origin = 'bitworks'; label = 'Measured by Bitworks on this card'; evidenceUrl = 'https://bitworks.io/amd/results/x' } }
Check ((@(Get-FastLlmUiStartRecipeArguments -Plan $measuredPlan) -join ' ') -ceq '-Recipe rx-7900-xtx.qwen3.8-27b-ud-q4-k-m.32k') 'a measured preview passes its recipe id to the start'
foreach ($quiet in @('estimated', 'manual')) { Check (@(Get-FastLlmUiStartRecipeArguments -Plan ([pscustomobject]@{ recipe = [pscustomobject]@{ id = $null; origin = $quiet } })).Count -eq 0) "a $quiet preview passes no recipe" }
Check (@(Get-FastLlmUiStartRecipeArguments -Plan ([pscustomobject]@{ recipe = [pscustomobject]@{ id = 'x y; evil'; origin = 'bitworks' } })).Count -eq 0) 'an unsafe recipe id is never passed to the child'
Check (@(Get-FastLlmUiStartRecipeArguments -Plan $null).Count -eq 0) 'no preview plan passes no recipe'
$runState = [pscustomobject]@{ planRecipe = [pscustomobject]@{ id = 'r1'; origin = 'bitworks'; label = 'Measured by Bitworks on this card'; evidenceUrl = 'https://bitworks.io/amd/results/x' } }
Check ((Get-FastLlmUiRunEvidenceUrl -State $runState) -eq 'https://bitworks.io/amd/results/x' -and (Get-FastLlmUiRunSetupLine -State $runState) -ceq 'Setup: Measured by Bitworks on this card') 'the results link and setup line come from the running plan'
$estimatedRun = [pscustomobject]@{ planRecipe = [pscustomobject]@{ id = $null; origin = 'estimated'; label = 'Estimated for your card'; evidenceUrl = $null } }
Check ($null -eq (Get-FastLlmUiRunEvidenceUrl -State $estimatedRun) -and (Get-FastLlmUiRunSetupLine -State $estimatedRun) -ceq 'Setup: Estimated for your card') 'a run that is estimated shows no results link, whatever the preview said'
Check ($null -eq (Get-FastLlmUiRunEvidenceUrl -State ([pscustomobject]@{ planRecipe = [pscustomobject]@{ evidenceUrl = 'https://evil.example/x' } })) -and $null -eq (Get-FastLlmUiRunEvidenceUrl -State ([pscustomobject]@{ phase = 'ready' }))) 'a run without a safe recorded link shows none'
Check ($ui.Contains('Get-FastLlmUiStartRecipeArguments -Plan $script:flow.pendingPlan') -and $ui.Contains('$resultsLink.Visible=$false;$script:evidenceUrl=$null') -and $ui.Contains('Get-FastLlmUiRunEvidenceUrl -State $s')) 'the UI passes the recipe, clears the preview link at start and re-shows it from the running plan'
# The BAR setting is read and written under the same launch root, never the editable folder box .
$readRoots = @([regex]::Matches($ui, '(?m)Read-FastLlmUiSettings -InstallRoot (\$[A-Za-z_]+(?::[A-Za-z_]+)?)') | ForEach-Object { $_.Groups[1].Value })
$writeRoots = @([regex]::Matches($ui, '(?m)Write-FastLlmUiSettings -InstallRoot (\$[A-Za-z_]+(?::[A-Za-z_]+)?)') | ForEach-Object { $_.Groups[1].Value })
Check ($readRoots.Count -eq 1 -and $writeRoots.Count -eq 1 -and $readRoots[0] -ceq $writeRoots[0] -and $readRoots[0] -ceq '$script:settingsRoot') 'the BAR setting is read and written under one root'
Check ($ui.Contains('$script:settingsRoot=$InstallRoot') -and -not [regex]::IsMatch($ui, '(?:Read|Write)-FastLlmUiSettings[^\r\n]*pathBox')) 'the settings root is the launch root, not the folder box'
Remove-Item -LiteralPath $uiRoot -Recurse -Force

# Update banner, first-launch integrity, settings round trip and the Preview title .
$releaseUrl = 'https://github.com/bitworks-io/amd-inference/releases/tag/v2026.10.16.1'
$availableCheck = [pscustomobject]@{ status = 'available'; installed = '2026.10.15.1'; latest = @{ version = '2026.10.16.1'; htmlUrl = $releaseUrl; assets = @{} } }
$banner = Format-FastLlmUiUpdateBanner -Check $availableCheck
Check ($banner.text -ceq 'FastLLM 2026.10.16.1 is available.' -and $banner.url -ceq $releaseUrl) 'an available update gives the banner text and release url'
foreach ($quietStatus in @('up-to-date', 'failed', 'disabled', 'skipped-recent', 'not-a-release')) {
    Check ($null -eq (Format-FastLlmUiUpdateBanner -Check ([pscustomobject]@{ status = $quietStatus; installed = '2026.10.15.1'; latest = $availableCheck.latest }))) "no banner for $quietStatus"
}
Check ($null -eq (Format-FastLlmUiUpdateBanner -Check $null)) 'no banner without a check result'
$foreignCheck = [pscustomobject]@{ status = 'available'; latest = [pscustomobject]@{ version = '2026.10.16.1'; htmlUrl = 'https://evil.example/x' } }
Check ($null -eq (Format-FastLlmUiUpdateBanner -Check $foreignCheck).url) 'a release page outside this repository is never offered as a link'
Check ($null -eq (Format-FastLlmUiUpdateBanner -Check ([pscustomobject]@{ status = 'available'; latest = @{ version = 'evil; calc'; htmlUrl = $releaseUrl } }))) 'an invalid version gives no banner'
$integrityBanner = Format-FastLlmUiIntegrityBanner -Result ([pscustomobject]@{ status = 'failed'; reason = 'tree' })
Check ($integrityBanner.text -ceq "FastLLM's files don't match its signed catalog. Reinstall FastLLM from the release page." -and $integrityBanner.url -ceq 'https://github.com/bitworks-io/amd-inference/releases') 'a failed integrity check gives the red banner text and the releases link'
foreach ($quietIntegrity in @('ok', 'not-installed')) { Check ($null -eq (Format-FastLlmUiIntegrityBanner -Result ([pscustomobject]@{ status = $quietIntegrity }))) "no integrity banner for $quietIntegrity" }
Check ($null -eq (Format-FastLlmUiIntegrityBanner -Result $null)) 'no integrity banner without a result'
Check ((Format-FastLlmUiUpdateConfirm -Version '2026.10.16.1') -ceq 'FastLLM will stop the server, download 2026.10.16.1, check its Bitworks signature, and run the installer. Continue?') 'the update confirmation text is exact'
Check ((Format-FastLlmUiUpdateResult -Result ([pscustomobject]@{ status = 'installed'; step = 'integrity'; reason = '' }) -Version '2026.10.16.1') -ceq 'FastLLM was updated to 2026.10.16.1. Close and reopen FastLLM.') 'the installed result text is exact'
Check ((Format-FastLlmUiUpdateResult -Result ([pscustomobject]@{ status = 'refused'; step = 'signature'; reason = 'not-valid' }) -Version '2026.10.16.1') -ceq 'Update not installed: not-valid. Nothing was changed.') 'a refused update says nothing was changed'
Check ((Format-FastLlmUiUpdateResult -Result ([pscustomobject]@{ status = 'failed'; step = 'stop'; reason = 'busy-loading' }) -Version '2026.10.16.1') -ceq 'Update not installed: busy-loading. Nothing was changed.') 'a failed update says nothing was changed'
$integrityOutcome = [pscustomobject]@{ status = 'failed'; step = 'integrity'; reason = 'tree' }
Check ((Format-FastLlmUiUpdateResult -Result $integrityOutcome -Version '2026.10.16.1') -ceq "FastLLM 2026.10.16.1 was installed, but its files don't match the signed catalog. Reinstall FastLLM from the release page.") 'an integrity failure after the installer says it was installed and to reinstall'
Check ((Test-FastLlmUiUpdateIntegrityFailure -Result $integrityOutcome) -and -not (Test-FastLlmUiUpdateIntegrityFailure -Result ([pscustomobject]@{ status = 'failed'; step = 'install'; reason = 'exit-1' })) -and -not (Test-FastLlmUiUpdateIntegrityFailure -Result ([pscustomobject]@{ status = 'refused'; step = 'integrity'; reason = 'x' }))) 'only a failed integrity step selects the reinstall text'
Check ((Format-FastLlmUiUpdateResult -Result ([pscustomobject]@{ status = 'failed'; step = 'install'; reason = 'installer-exit-1' }) -Version '2026.10.16.1') -ceq 'Update not installed: installer-exit-1. Nothing was changed.') 'every other failure keeps the nothing-changed text'

$integrityRoot = Join-Path ([IO.Path]::GetTempPath()) ('ui-int-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $integrityRoot | Out-Null
Check (Test-FastLlmUiIntegrityDue -InstallRoot $integrityRoot -InstalledVersion '2026.10.15.1') 'integrity is due on the first launch of a version'
Check (Test-FastLlmUiIntegrityDue -InstallRoot $integrityRoot -InstalledVersion '2026.10.15.1') 'asking does not record anything'
Check (-not (Set-FastLlmUiIntegrityChecked -InstallRoot $integrityRoot -InstalledVersion '2026.10.15.1' -Result ([pscustomobject]@{ status = 'failed' }))) 'a failed result is not recorded'
Check (Test-FastLlmUiIntegrityDue -InstallRoot $integrityRoot -InstalledVersion '2026.10.15.1') 'integrity is due again after a failed result'
Check (Set-FastLlmUiIntegrityChecked -InstallRoot $integrityRoot -InstalledVersion '2026.10.15.1' -Result ([pscustomobject]@{ status = 'ok' })) 'an ok result is recorded'
Check (-not (Test-FastLlmUiIntegrityDue -InstallRoot $integrityRoot -InstalledVersion '2026.10.15.1')) 'integrity is not due again after ok for the same version'
Check (Test-FastLlmUiIntegrityDue -InstallRoot $integrityRoot -InstalledVersion '2026.10.16.1') 'integrity is due for a new version'
Check (Set-FastLlmUiIntegrityChecked -InstallRoot $integrityRoot -InstalledVersion '2026.10.16.1' -Result ([pscustomobject]@{ status = 'not-installed' })) 'not-installed is recorded'
Check (-not (Test-FastLlmUiIntegrityDue -InstallRoot $integrityRoot -InstalledVersion '2026.10.16.1') -and -not (Test-FastLlmUiIntegrityDue -InstallRoot $integrityRoot -InstalledVersion '2026.10.15.1')) 'both versions stay recorded'
Check (-not (Set-FastLlmUiIntegrityChecked -InstallRoot $integrityRoot -InstalledVersion '2026.10.17.1' -Result $null)) 'an unknown result is not recorded'
Check (Test-Path -LiteralPath (Join-Path (Join-Path $integrityRoot 'state') 'integrity-checked.json') -PathType Leaf) 'the record is state\integrity-checked.json'
Check (-not (Test-FastLlmUiIntegrityDue -InstallRoot $integrityRoot -InstalledVersion '')) 'no installed version means no check'
Check (-not (Test-FastLlmUiIntegrityDue -InstallRoot $integrityRoot -InstalledVersion 'not-a-version')) 'a malformed version means no check'
Remove-Item -LiteralPath $integrityRoot -Recurse -Force

$roundRoot = Join-Path ([IO.Path]::GetTempPath()) ('ui-round-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $roundRoot | Out-Null
$defaults = Read-FastLlmUiSettings -InstallRoot $roundRoot
Check ($defaults.vulkanBarMitigation -ceq 'auto' -and $defaults.updateCheck -ceq 'on' -and $defaults.updateChannel -ceq 'stable') 'settings default to auto, on and stable'
Set-FastLlmUpdateSettings -InstallRoot $roundRoot -UpdateCheck off -UpdateChannel canary
Write-FastLlmUiSettings -InstallRoot $roundRoot -Settings ([pscustomobject]@{ vulkanBarMitigation = 'on' })
$roundTrip = Read-FastLlmUiSettings -InstallRoot $roundRoot
Check ($roundTrip.vulkanBarMitigation -ceq 'on' -and $roundTrip.updateCheck -ceq 'off' -and $roundTrip.updateChannel -ceq 'canary') 'the BAR write keeps both update keys'
Set-FastLlmUpdateSettings -InstallRoot $roundRoot -UpdateCheck on
$roundTrip = Read-FastLlmUiSettings -InstallRoot $roundRoot
Check ($roundTrip.vulkanBarMitigation -ceq 'on' -and $roundTrip.updateCheck -ceq 'on' -and $roundTrip.updateChannel -ceq 'canary') 'the update write keeps the BAR key and the channel'
Set-Content -LiteralPath (Join-Path $roundRoot 'settings.json') -Value '{"vulkanBarMitigation":"off","updateCheck":"off","updateChannel":"canary","futureKey":"keep"}' -Encoding ascii
Write-FastLlmUiSettings -InstallRoot $roundRoot -Settings ([pscustomobject]@{ vulkanBarMitigation = 'auto' })
$rawSettings = Get-Content -LiteralPath (Join-Path $roundRoot 'settings.json') -Raw | ConvertFrom-Json
Check ($rawSettings.vulkanBarMitigation -ceq 'auto' -and $rawSettings.updateCheck -ceq 'off' -and $rawSettings.updateChannel -ceq 'canary' -and $rawSettings.futureKey -ceq 'keep') 'a UI write preserves update keys and unknown keys'
Remove-Item -LiteralPath $roundRoot -Recurse -Force

Check ($ui.Contains("`$form.Text='Bitworks FastLLM (Preview)'") -and -not $ui.Contains('lab alpha')) 'the window title is Bitworks FastLLM (Preview)'
Check ($ui.Contains("src/FastLlm.Update.ps1") -and -not [regex]::IsMatch($ui, 'Import-Module[^\r\n]*FastLlm\.Update')) 'the UI dot-sources the update script'
Check ($ui.Contains('Invoke-FastLlmVerifiedUpdate -InstallRoot') -and -not [regex]::IsMatch($ui, '(?i)-Silent(?!ly)')) 'the UI runs the verified update without -Silent'
Check ($ui.Contains('Test-FastLlmUiIntegrityDue') -and $ui.Contains('Set-FastLlmUpdateSettings') -and $ui.Contains("'Check for updates'")) 'the UI has the first-launch integrity check and the update setting'

# Experimental components: the UI settings carry the switch (default off) and keep the other keys.
$expRoot = Join-Path ([IO.Path]::GetTempPath()) ('fastllm-ui-exp-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $expRoot -Force | Out-Null
$expDefaults = Read-FastLlmUiSettings -InstallRoot $expRoot
Check ($expDefaults.experimentalComponents -ceq 'off') 'the UI settings default experimentalComponents to off'
Set-FastLlmUpdateSettings -InstallRoot $expRoot -UpdateCheck off -UpdateChannel canary
Write-FastLlmUiSettings -InstallRoot $expRoot -Settings ([pscustomobject]@{ vulkanBarMitigation = 'on'; experimentalComponents = 'on' })
$expRound = Read-FastLlmUiSettings -InstallRoot $expRoot
Check ($expRound.experimentalComponents -ceq 'on' -and $expRound.vulkanBarMitigation -ceq 'on' -and $expRound.updateCheck -ceq 'off' -and $expRound.updateChannel -ceq 'canary') 'the UI write carries experimentalComponents and keeps vulkanBarMitigation, updateCheck and updateChannel'
Write-FastLlmUiSettings -InstallRoot $expRoot -Settings ([pscustomobject]@{ vulkanBarMitigation = 'off' })
$expKept = Read-FastLlmUiSettings -InstallRoot $expRoot
Check ($expKept.experimentalComponents -ceq 'on' -and $expKept.vulkanBarMitigation -ceq 'off') 'a BAR-only write (the BAR box of the window) leaves the experimental switch as it was'
Set-FastLlmComponentSettings -InstallRoot $expRoot -ExperimentalComponents 'off'
$expAfterSet = Read-FastLlmUiSettings -InstallRoot $expRoot
Check ($expAfterSet.experimentalComponents -ceq 'off' -and $expAfterSet.vulkanBarMitigation -ceq 'off' -and $expAfterSet.updateCheck -ceq 'off' -and $expAfterSet.updateChannel -ceq 'canary') 'Set-FastLlmComponentSettings is read by the UI settings and keeps the other keys'
$expRejected = $false
try { Write-FastLlmUiSettings -InstallRoot $expRoot -Settings ([pscustomobject]@{ vulkanBarMitigation = 'auto'; experimentalComponents = 'yes' }) } catch { $expRejected = $true }
Check $expRejected 'an experimentalComponents value other than on or off is rejected'
Remove-Item -LiteralPath $expRoot -Recurse -Force

# The Components window helpers are pure.
$uiRows = @(
    [pscustomobject]@{ id = 'a'; kind = 'engine'; version = 'v1'; installed = $true; bytes = [int64]1048576; verified = $true },
    [pscustomobject]@{ id = 'b'; kind = 'model'; version = 'v2'; installed = $false; bytes = [int64]0; verified = $false })
$shownRows = @(Get-FastLlmInstalledComponentRows -Inventory $uiRows)
Check ($shownRows.Count -eq 1 -and $shownRows[0].id -ceq 'a' -and $shownRows[0].label -ceq 'a (engine, v1) - 1.0 MB') 'the Components window lists only installed components, with their sizes'
Check (@(Get-FastLlmInstalledComponentRows -Inventory @()).Count -eq 0) 'no installed components gives an empty list'
Check ($script:FastLlmExperimentalParagraph -like '*Bitworks has not reproduced*' -and $script:FastLlmExperimentalParagraph -like '*pinned hash*') 'the paragraph the checkbox confirms is the spec 2.7 text'

# The window: the checkbox, its confirmation (Yes/No, default No), the Components list with Remove, and no recipe chooser.
Check ($ui.Contains("Text='Experimental community components'") -and $ui.Contains('$experimentalBox.Add_CheckedChanged')) 'the settings area has an Experimental community components checkbox'
Check ($ui.Contains("`$script:FastLlmExperimentalParagraph,'Experimental community components','YesNo','Warning','Button2'")) 'turning the switch on shows the paragraph in a Yes/No confirmation whose default is No'
Check ($ui.Contains("Set-FastLlmComponentSettings -InstallRoot `$script:settingsRoot -ExperimentalComponents 'on'") -and $ui.Contains("-ExperimentalComponents 'off'")) 'the checkbox writes the switch through Set-FastLlmComponentSettings'
Check ($ui.Contains('$removeLock=Enter-FastLlmOperation -InstallRoot $view.root') -and $ui.Contains('-InstallRoot $view.root -OperationLockHeld)') -and $ui.Contains('finally{if($removeLock){$removeLock.Dispose()}}') -and $ui.IndexOf('Enter-FastLlmOperation -InstallRoot $view.root') -lt $ui.IndexOf('-InstallRoot $view.root -OperationLockHeld)')) 'removing a component from the window takes the operation lock first, passes it to the removal and releases it'
Check ($ui.Contains("ButtonAt 'Components'") -and $ui.Contains('Remove-FastLlmComponent -ComponentsPath') -and $ui.Contains("Text='Remove'") -and $ui.Contains('Get-FastLlmInstalledComponentRows')) 'a Components button lists installed components with a Remove action per row'
Check ($ui.Contains('src/FastLlm.Components.ps1') -and -not [regex]::IsMatch($ui, 'Import-Module[^\r\n]*FastLlm\.Components')) 'the UI dot-sources the components script'
$removeHandler = [regex]::Match($ui, '(?s)function RemoveComponentFromWindow.*?\r?\n\}').Value
Check ($removeHandler.Contains('$view.dialog.BeginInvoke([Action]{FillComponentsPanel})') -and -not [regex]::IsMatch($removeHandler, '(?m)^\s*FillComponentsPanel\s*$')) 'the Components window rebuilds its panel after the Remove click returns, never disposing the clicked button inside its own Click handler'
$flowSourceText = Get-Content -LiteralPath (Join-Path $root 'src/FastLlm.UiFlow.ps1') -Raw
Check (-not $ui.Contains("'-AcceptExperimental'") -and [regex]::Matches($flowSourceText, "'-AcceptExperimental'").Count -eq 2 -and $ui.Contains('Get-FastLlmUiPreviewRecipeArguments -Recipe $script:chosenRecipe') -and $ui.Contains('Get-FastLlmUiStartRecipeArguments -Plan $script:flow.pendingPlan -ChosenRecipe $script:chosenRecipe')) 'the experimental acceptance reaches the CLI only through the two argument helpers (preview and start), each fed the recipe the user picked in the chooser'

# ---- "Choose another setup": the chooser rows ----
$chooserCatalog = Get-Content -LiteralPath (Join-Path $root 'config/catalog.json') -Raw | ConvertFrom-Json
$chooserComponents = @(Get-FastLlmComponents -ComponentsPath (Join-Path $root 'config/components.json'))
$chooserRecipes = @(Read-FastLlmRecipes -Path (Join-Path $root 'config/recipes.json'))
$chooserRoot = Join-Path ([IO.Path]::GetTempPath()) ('ui-chooser-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $chooserRoot | Out-Null
function New-ChooserDetailRows([object[]]$Inventory = @(), [string]$Root = $chooserRoot) {
    # What `recipes -Detail -AsJson` prints, through the same JSON round trip the window reads.
    $built = @(Get-FastLlmRecipeChooserRows -Recipes $chooserRecipes -Components $chooserComponents -Inventory $Inventory -Catalog $chooserCatalog -InstallRoot $Root)
    return @(((ConvertTo-Json -InputObject $built -Depth 8) | ConvertFrom-Json) | ForEach-Object { $_ })
}
$detailRows = @(New-ChooserDetailRows)
$experimentalLabel = 'Experimental Bitworks setup, not yet measured by Bitworks on this card'
$xtxVariant = 'rx-7900-xtx'
$offRows = @(Get-FastLlmUiChooserRows -Rows $detailRows -ExperimentalComponents 'off' -Variant $xtxVariant)
$onRows = @(Get-FastLlmUiChooserRows -Rows $detailRows -ExperimentalComponents 'on' -Variant $xtxVariant)
$expectedHidden = @($chooserRecipes | Where-Object { (Test-FastLlmExperimentalOrigin -Origin ([string]$_.origin)) -and [string]$_.gpu.variant -ceq $xtxVariant }).Count
Check ($expectedHidden -eq 1 -and @($chooserRecipes | Where-Object { Test-FastLlmExperimentalOrigin -Origin ([string]$_.origin) }).Count -ge 2 -and $detailRows.Count -eq $chooserRecipes.Count) 'the shipped recipes include the experimental HIP recipes, and each recipe has a detail row'
Check ($offRows.Count -ge 1 -and @($offRows | Where-Object { $_.experimental }).Count -eq 0 -and $onRows.Count -eq $offRows.Count + $expectedHidden) 'with the switch off the chooser hides every experimental row, even when the list holds them; with it on it shows them'
Check (@(Get-FastLlmUiChooserRows -Rows $detailRows -Variant $xtxVariant).Count -eq $offRows.Count -and @(Get-FastLlmUiChooserRows -Rows $detailRows -ExperimentalComponents 'ON' -Variant $xtxVariant).Count -eq $offRows.Count) 'the switch defaults to off and only the exact value on shows experimental rows'
$hipRow = @($onRows | Where-Object { $_.id -ceq 'rx-7900-xtx.qwen3.8-27b-ud-q4-k-m.32k.hip' })[0]
Check ($null -ne $hipRow -and $hipRow.label -ceq $experimentalLabel -and $hipRow.origin -ceq 'bitworks-experimental' -and $hipRow.model -ceq 'qwen3.8-27b-ud-q4-k-m' -and $hipRow.contextText -ceq '32,768 tokens') 'a HIP row shows the experimental Bitworks label, the model and the context'
Check ($hipRow.engineText -ceq 'llama.cpp b11658 (HIP, ROCm 10.0) (from github.com; missing); requires AMD ROCm 10.0 runtime (gfx1100) (from stable.repo.amd.com; missing)') 'a HIP row names the engine, its required runtime, their source hosts and the exact state "missing"'
Check ($hipRow.installRequired -eq $true -and $hipRow.consentRequired -eq $true) 'a HIP row with its chain missing needs the install'
$vulkanRow = @($offRows | Where-Object { $_.origin -ceq 'bitworks' })[0]
Check ($null -ne $vulkanRow -and $vulkanRow.label -ceq 'Measured by Bitworks on this card' -and -not $vulkanRow.consentRequired -and -not $vulkanRow.installRequired -and $vulkanRow.engineText -ceq 'llama.cpp b10698 (Vulkan) (from github.com; missing)') 'a Bitworks row with no engine installed says the built-in engine is missing, and needs no component install'
# The built-in engine lives under engines\<version>\vulkan, not under components\.
$vulkanDir = Join-Path $chooserRoot 'engines/b10698/vulkan'
New-Item -ItemType Directory -Path $vulkanDir -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $vulkanDir 'llama-server.exe'), 'x')
$builtInRows = @(Get-FastLlmUiChooserRows -Rows @(New-ChooserDetailRows) -ExperimentalComponents 'off' -Variant $xtxVariant)
Check ($builtInRows[0].engineText -ceq 'llama.cpp b10698 (Vulkan) (from github.com; built in)' -and $builtInRows[0].chain[0].builtIn -eq $true -and $builtInRows[0].chain[0].state -ceq 'built in') 'with the engine present the built-in engine row says "built in"'
# Another component counts as installed only when the inventory says installed AND verified.
$unverifiedInventory = @([pscustomobject]@{ id = 'amd-rocm-gfx1100-10.0.0'; kind = 'runtime'; version = '10.0.0'; installed = $true; bytes = 1; verified = $false })
$unverifiedHip = @(New-ChooserDetailRows $unverifiedInventory | Where-Object { $_.id -like '*.hip' })[0]
Check ($unverifiedHip.chain[0].state -ceq 'missing' -and $unverifiedHip.chain[0].installed -eq $false) 'a component that is present but not verified is missing'
$verifiedInventory = @([pscustomobject]@{ id = 'amd-rocm-gfx1100-10.0.0'; kind = 'runtime'; version = '10.0.0'; installed = $true; bytes = 1; verified = $true })
$verifiedHip = @(Get-FastLlmUiChooserRows -Rows @(New-ChooserDetailRows $verifiedInventory) -ExperimentalComponents 'on' -Variant $xtxVariant | Where-Object { $_.id -like '*.hip' })[0]
Check ($verifiedHip.engineText -ceq 'llama.cpp b11658 (HIP, ROCm 10.0) (from github.com; missing); requires AMD ROCm 10.0 runtime (gfx1100) (from stable.repo.amd.com; installed)' -and $verifiedHip.installRequired -eq $true) 'an installed and verified runtime is "installed" while the engine is still "missing"'
$communityDetail = @((ConvertTo-Json -InputObject @($detailRows | Where-Object { $_.variant -ceq $xtxVariant })[0] -Depth 8 | ConvertFrom-Json) | ForEach-Object { $_ })[0]
$communityDetail.origin = 'community-experimental'
Check (@(Get-FastLlmUiChooserRows -Rows @($communityDetail) -ExperimentalComponents 'off' -Variant $xtxVariant).Count -eq 0 -and @(Get-FastLlmUiChooserRows -Rows @($communityDetail) -ExperimentalComponents 'on' -Variant $xtxVariant).Count -eq 1) 'a community-experimental row is hidden with the switch off and shown with it on'
$xtRows = @(Get-FastLlmUiChooserRows -Rows $detailRows -ExperimentalComponents 'on' -Variant 'rx-7900-xt')
Check ($xtRows.Count -ge 1 -and @($xtRows | Where-Object { $_.variant -cne 'rx-7900-xt' }).Count -eq 0 -and @($onRows | Where-Object { $_.variant -cne $xtxVariant }).Count -eq 0) 'the chooser lists only the identified card''s recipes'
Check (@(Get-FastLlmUiChooserRows -Rows $detailRows -ExperimentalComponents 'on' -Variant '').Count -eq 0 -and @(Get-FastLlmUiChooserRows -Rows $detailRows -ExperimentalComponents 'on').Count -eq 0 -and @(Get-FastLlmUiChooserRows -Rows $detailRows -ExperimentalComponents 'on' -Variant 'rx-9999').Count -eq 0) 'a card that is not identified (or has no recipes) gets no rows, never every card''s'
Check ((Get-FastLlmUiChooserNotice -Shown @() -ExperimentalComponents 'on' -Variant '') -ceq 'This card was not identified, so no setup can be offered for it. Nothing was changed.') 'an unidentified card is explained'
Check ((Get-FastLlmUiChooserNotice -Shown @() -ExperimentalComponents 'off' -Variant 'rx-9999') -ceq 'No other setup is available for this card.') 'no setup for the card is explained'
Check ((Get-FastLlmUiChooserNotice -Shown $offRows -ExperimentalComponents 'on' -Variant $xtxVariant) -ceq 'Experimental community components is on, but no experimental setup is listed for this card.' -and (Get-FastLlmUiChooserNotice -Shown $onRows -ExperimentalComponents 'on' -Variant $xtxVariant) -ceq '' -and (Get-FastLlmUiChooserNotice -Shown $offRows -ExperimentalComponents 'off' -Variant $xtxVariant) -ceq '') 'the switch on without any experimental row is said so; otherwise there is no notice'

# ---- the experimental switch is mirrored to the install folder the children are given ----
$mirrorSource = Join-Path $chooserRoot 'launch'
$mirrorTarget = Join-Path $chooserRoot 'other-folder'
Set-FastLlmComponentSettings -InstallRoot $mirrorSource -ExperimentalComponents 'on'
Check ((Sync-FastLlmExperimentalSwitch -SourceRoot $mirrorSource -TargetRoot $mirrorTarget) -eq $true -and (Get-FastLlmComponentSettings -InstallRoot $mirrorTarget).experimentalComponents -ceq 'on') 'the switch stored under the launch root is mirrored into a different install folder'
Check ((Sync-FastLlmExperimentalSwitch -SourceRoot $mirrorSource -TargetRoot $mirrorTarget) -eq $false) 'an install folder that already agrees is not written again'
Set-FastLlmComponentSettings -InstallRoot $mirrorSource -ExperimentalComponents 'off'
Check ((Sync-FastLlmExperimentalSwitch -SourceRoot $mirrorSource -TargetRoot $mirrorTarget) -eq $true -and (Get-FastLlmComponentSettings -InstallRoot $mirrorTarget).experimentalComponents -ceq 'off') 'turning the switch off is mirrored too'
Check ((Sync-FastLlmExperimentalSwitch -SourceRoot $mirrorSource -TargetRoot $mirrorSource) -eq $false -and -not (Test-Path -LiteralPath (Join-Path $chooserRoot 'never-created'))) 'the same root is left alone'
$freshTarget = Join-Path $chooserRoot 'fresh-folder'
Check ((Sync-FastLlmExperimentalSwitch -SourceRoot $mirrorSource -TargetRoot $freshTarget) -eq $false -and -not (Test-Path -LiteralPath $freshTarget)) 'a switch that is off writes nothing into a folder that has no settings'

# ---- the per-component consent rows and the enable rule ----
$hipChain = @($hipRow.chain)
$consentRows = @(Get-FastLlmUiConsentRows -Chain $hipChain)
Check ($consentRows.Count -eq 2 -and $hipChain.Count -eq 2) 'the consent dialog has one row per component in the HIP chain'
Check ($consentRows[0].id -ceq 'amd-rocm-gfx1100-10.0.0' -and $consentRows[1].id -ceq 'llama.cpp-hip-b11658') 'the consent rows list the required runtime first and the engine last'
Check (($consentRows[0].sourceHosts -join ',') -ceq 'stable.repo.amd.com' -and ($consentRows[1].sourceHosts -join ',') -ceq 'github.com' -and $consentRows[0].sourceText -ceq 'stable.repo.amd.com') 'each consent row shows its source host'
foreach ($consentRow in $consentRows) {
    $listed = @($chooserComponents | Where-Object { [string]$_.id -ceq $consentRow.id })[0]
    $expectedLinks = @(Get-FastLlmComponentLicenseLinks -Component $listed)
    Check ($expectedLinks.Count -ge 2 -and @($consentRow.links).Count -eq $expectedLinks.Count) "the consent row for $($consentRow.id) has every license link of the component"
    for ($i = 0; $i -lt $expectedLinks.Count; $i++) {
        Check ($consentRow.links[$i].url -ceq [string]$expectedLinks[$i].url -and $consentRow.links[$i].title -ceq [string]$expectedLinks[$i].title) "link $i of $($consentRow.id) is the component's license link"
    }
    Check ($consentRow.acceptText -like 'I accept*' -and @($consentRow.PSObject.Properties.Name | Where-Object { $_ -like '*text*' -and $_ -notin @('sourceText', 'acceptText', 'statusText') }).Count -eq 0) "the consent row for $($consentRow.id) carries links and an accept box, never license text"
}
Check (@($consentRows | Where-Object { $_.needsAccept }).Count -eq 2 -and $consentRows[0].statusText -ceq 'will be downloaded' -and @($consentRows | Where-Object { $_.blocked }).Count -eq 0) 'every missing component needs its own accept box'
$installedRuntimeChain = @((ConvertTo-Json -InputObject $hipChain -Depth 6 | ConvertFrom-Json) | ForEach-Object { $_ })
$installedRuntimeChain[0].installed = $true
$installedRuntimeChain[0].state = 'installed'
$partRows = @(Get-FastLlmUiConsentRows -Chain $installedRuntimeChain)
Check ($partRows.Count -eq 2 -and -not $partRows[0].needsAccept -and $partRows[0].statusText -ceq 'installed; license accepted earlier' -and $partRows[1].needsAccept -and $partRows[1].id -ceq 'llama.cpp-hip-b11658') 'an installed component stays in the dialog as a read-only row; only the missing one needs a box'
$builtInChain = @((ConvertTo-Json -InputObject $hipChain -Depth 6 | ConvertFrom-Json) | ForEach-Object { $_ })
$builtInChain[0].state = 'built in'
Check (@(Get-FastLlmUiConsentRows -Chain $builtInChain)[0].statusText -ceq 'built in' -and -not @(Get-FastLlmUiConsentRows -Chain $builtInChain)[0].needsAccept) 'a built-in component is a read-only row saying built in'
$showChain = @((ConvertTo-Json -InputObject $hipChain -Depth 6 | ConvertFrom-Json) | ForEach-Object { $_ })
$showChain[0].consent = 'show'; $showChain[1].consent = 'show'
Check (@(Get-FastLlmUiConsentRows -Chain $showChain | Where-Object { $_.needsAccept }).Count -eq 2) 'a chain whose licenses are all show-type still has rows to accept, so it has an install path'
foreach ($consentRow in $consentRows) {
    Check ($consentRow.links[0].linkText -ceq ('{0} ({1})' -f $consentRow.links[0].title, ([Uri]$consentRow.links[0].url).Host)) "the license link of $($consentRow.id) shows its destination host"
}
$unsafeChain = @((ConvertTo-Json -InputObject $hipChain -Depth 6 | ConvertFrom-Json) | ForEach-Object { $_ })
$unsafeChain[1].licenseLinks[0].url = 'javascript:alert(1)'
$unsafeChain[1].licenseLinks[1].url = 'http://example.com/license'
$unsafeRows = @(Get-FastLlmUiConsentRows -Chain $unsafeChain)
Check ($null -eq $unsafeRows[1].links[0].url -and $null -eq $unsafeRows[1].links[1].url) 'a license link that is not https is never offered to the browser'
Check ($unsafeRows[1].blocked -eq $true -and $unsafeRows[0].blocked -eq $false) 'a component with a link that cannot be opened cannot be accepted'
Check ((Get-FastLlmUiSafeLicenseUrl -Url 'https://www.amd.com/en/developer/resources/rocm-hub/eula/licenses.html') -ceq 'https://www.amd.com/en/developer/resources/rocm-hub/eula/licenses.html' -and $null -eq (Get-FastLlmUiSafeLicenseUrl -Url 'file:///C:/x') -and $null -eq (Get-FastLlmUiSafeLicenseUrl -Url 'https://a b') -and $null -eq (Get-FastLlmUiSafeLicenseUrl -Url '') -and $null -eq (Get-FastLlmUiSafeLicenseUrl -Url 'not a url')) 'only a plain https URL passes the link check'
Check ((Test-FastLlmUiConsentComplete -RowCount 2 -Ticked @($true, $true))) 'Install is enabled when every row is ticked'
Check (-not (Test-FastLlmUiConsentComplete -RowCount 2 -Ticked @($true, $false)) -and -not (Test-FastLlmUiConsentComplete -RowCount 2 -Ticked @($false, $true)) -and -not (Test-FastLlmUiConsentComplete -RowCount 2 -Ticked @($false, $false))) 'Install stays disabled while any row is unticked'
Check (-not (Test-FastLlmUiConsentComplete -RowCount 2 -Ticked @($true)) -and -not (Test-FastLlmUiConsentComplete -RowCount 2 -Ticked @()) -and -not (Test-FastLlmUiConsentComplete -RowCount 0 -Ticked @()) -and -not (Test-FastLlmUiConsentComplete -RowCount 1 -Ticked @('yes'))) 'a missing box, no rows or a non-boolean tick never enables Install'

# ---- the install and start argument builders ----
$installRootArg = 'C:\Users\x\FastLLM'
$installArgs = @(Get-FastLlmUiComponentInstallArguments -EngineId 'llama.cpp-hip-b11658' -InstallRoot $installRootArg -Confirmed $true -RowCount 2 -Ticked @($true, $true))
Check (($installArgs -join '|') -ceq 'components|-Install|llama.cpp-hip-b11658|-InstallRoot|C:\Users\x\FastLLM|-AcceptLicense|-Unattended') 'Install runs components -Install <engine id> -AcceptLicense'
Check (@(Get-FastLlmUiComponentInstallArguments -EngineId 'llama.cpp-hip-b11658' -InstallRoot $installRootArg -Confirmed $false -RowCount 2 -Ticked @($true, $true)).Count -eq 0) 'Cancel produces no install command, even with every box ticked'
Check (@(Get-FastLlmUiComponentInstallArguments -EngineId 'llama.cpp-hip-b11658' -InstallRoot $installRootArg -Confirmed $true -RowCount 2 -Ticked @($true, $false)).Count -eq 0) 'Install without every box ticked produces no install command'
Check (@(Get-FastLlmUiComponentInstallArguments -EngineId 'x y; evil' -InstallRoot $installRootArg -Confirmed $true -RowCount 1 -Ticked @($true)).Count -eq 0) 'an unsafe engine id never reaches the child'
$expPlan = [pscustomobject]@{ recipe = [pscustomobject]@{ id = 'rx-7900-xtx.qwen3.8-27b-ud-q4-k-m.32k.hip'; origin = 'bitworks-experimental' } }
$expChosen = [pscustomobject]@{ id = 'rx-7900-xtx.qwen3.8-27b-ud-q4-k-m.32k.hip'; origin = 'bitworks-experimental' }
Check ((@(Get-FastLlmUiStartRecipeArguments -Plan $expPlan -ChosenRecipe $expChosen) -join ' ') -ceq '-Recipe rx-7900-xtx.qwen3.8-27b-ud-q4-k-m.32k.hip -AcceptExperimental') 'the start of the experimental recipe the user picked passes -Recipe and -AcceptExperimental'
Check ((@(Get-FastLlmUiStartRecipeArguments -Plan $expPlan) -join ' ') -ceq '-Recipe rx-7900-xtx.qwen3.8-27b-ud-q4-k-m.32k.hip' -and (@(Get-FastLlmUiStartRecipeArguments -Plan $expPlan -ChosenRecipe $null) -join ' ') -ceq '-Recipe rx-7900-xtx.qwen3.8-27b-ud-q4-k-m.32k.hip') 'an experimental origin in a plan alone never adds -AcceptExperimental'
Check ((@(Get-FastLlmUiStartRecipeArguments -Plan $expPlan -ChosenRecipe ([pscustomobject]@{ id = 'another-recipe'; origin = 'bitworks-experimental' })) -join ' ') -ceq '-Recipe rx-7900-xtx.qwen3.8-27b-ud-q4-k-m.32k.hip') 'a chosen recipe with a different id than the plan''s does not carry the acceptance'
$communityPlan = [pscustomobject]@{ recipe = [pscustomobject]@{ id = 'c1'; origin = 'community-experimental' } }
Check ((@(Get-FastLlmUiStartRecipeArguments -Plan $communityPlan -ChosenRecipe ([pscustomobject]@{ id = 'c1'; origin = 'community-experimental' })) -join ' ') -ceq '-Recipe c1 -AcceptExperimental') 'the start of a chosen community-experimental recipe passes -AcceptExperimental'
foreach ($plainOrigin in @('bitworks', 'community-reproduced')) {
    Check ((@(Get-FastLlmUiStartRecipeArguments -Plan ([pscustomobject]@{ recipe = [pscustomobject]@{ id = 'r1'; origin = $plainOrigin } })) -join ' ') -ceq '-Recipe r1') "the start of a $plainOrigin recipe passes -Recipe only"
}
Check ((@(Get-FastLlmUiPreviewRecipeArguments -Recipe ([pscustomobject]@{ id = 'c1'; origin = 'community-experimental' })) -join ' ') -ceq '-Recipe c1 -AcceptExperimental' -and (@(Get-FastLlmUiPreviewRecipeArguments -Recipe ([pscustomobject]@{ id = 'r1'; origin = 'bitworks' })) -join ' ') -ceq '-Recipe r1' -and @(Get-FastLlmUiPreviewRecipeArguments -Recipe $null).Count -eq 0) 'the preview of a chosen recipe passes -Recipe, plus -AcceptExperimental only for an experimental origin'
$malformedThrew = $false
try { [void](Get-FastLlmUiPreviewRecipeArguments -Recipe ([pscustomobject]@{ id = 'bad id'; origin = 'bitworks' })) } catch { $malformedThrew = $true }
Check $malformedThrew 'a malformed chosen recipe id stops the preview instead of silently running the default plan'
$pickerSelection = @('-InstallRoot', 'C:\r', '-ContextSize', '16384', '-ModelId', 'm1')
Check ((@(Get-FastLlmUiRecipeSelection -Selection $pickerSelection -Recipe ([pscustomobject]@{ id = 'r1'; origin = 'bitworks' })) -join '|') -ceq '-InstallRoot|C:\r' -and (@(Get-FastLlmUiRecipeSelection -Selection $pickerSelection -Recipe $null) -join '|') -ceq ($pickerSelection -join '|')) 'a chosen recipe drops the model and context pickers (they cannot be combined with -Recipe); no chosen recipe keeps the selection'
foreach ($typedCode in @('hip-backend-unavailable', 'hip-dll-blocked', 'hip-device-not-found', 'hip-device-ambiguous', 'needs-setup-component-missing')) {
    Check (Test-FastLlmUiTypedHipFailure -Code $typedCode) "$typedCode is a typed failure the window shows without retrying"
}
Check (-not (Test-FastLlmUiTypedHipFailure -Code '') -and -not (Test-FastLlmUiTypedHipFailure -Code 'plan-changed') -and -not (Test-FastLlmUiTypedHipFailure -Code 'xhip-dll-blocked')) 'other or empty failure codes are not treated as typed HIP failures'
Check ((Get-FastLlmUiFailureCode -Status ([pscustomobject]@{ runId = 'b'; failureCode = 'hip-dll-blocked' }) -PreviousRunId 'a') -ceq 'hip-dll-blocked') 'a failure code written by this run is trusted'
Check ((Get-FastLlmUiFailureCode -Status ([pscustomobject]@{ runId = 'a'; failureCode = 'hip-dll-blocked' }) -PreviousRunId 'a') -ceq '' -and (Get-FastLlmUiFailureCode -Status ([pscustomobject]@{ runId = 'b' }) -PreviousRunId 'a') -ceq '' -and (Get-FastLlmUiFailureCode -Status $null -PreviousRunId 'a') -ceq '') 'a failure code left by an earlier run, or none, is not trusted'
Check ((Format-FastLlmUiTypedFailure -Code 'hip-dll-blocked' -Text "Blocked.`r`n") -ceq "Blocked.`r`n(failure code: hip-dll-blocked)") 'a typed failure shows its own message and its code'

# ---- source assertions on the window ----
$uiTokens = $null; $uiErrors = $null
$uiAst = [System.Management.Automation.Language.Parser]::ParseInput($ui, [ref]$uiTokens, [ref]$uiErrors)
Check ($uiErrors.Count -eq 0) 'the window script parses'
function Get-UiFunctionText([string]$Name) {
    $found = $uiAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name }, $true)
    if (-not $found) { throw "FAIL: the window has no function $Name" }
    return $found
}
function Test-NoDisposeInHandlers($FunctionAst) {
    $handlers = @($FunctionAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and ([string]$n.Member.Value) -like 'Add_*' }, $true))
    $bad = 0
    foreach ($handler in $handlers) {
        $bad += @($handler.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and ([string]$n.Member.Value) -ceq 'Dispose' }, $true)).Count
    }
    return [pscustomobject]@{ handlers = $handlers.Count; disposes = $bad }
}
$consentFn = Get-UiFunctionText 'ShowComponentConsent'
$chooserFn = Get-UiFunctionText 'ShowRecipeChooser'
$consentText = $consentFn.Extent.Text
Check ($consentText -notmatch 'License Agreement' -and $consentText -notmatch 'Get-Content|ReadAllText|ReadAllLines|Invoke-WebRequest|Invoke-RestMethod|\.Multiline' -and $consentText -notmatch 'New-Object Windows\.Forms\.TextBox') 'the consent dialog embeds no license text: no agreement text, no license file read, no text box'
Check ($consentText.Contains('New-Object Windows.Forms.LinkLabel') -and $consentText.Contains('Get-FastLlmUiSafeLicenseUrl') -and $consentText.Contains('Start-Process $target') -and $consentText.Contains('$consentRow.links')) 'the consent dialog shows each license as a clickable link opened in the browser'
Check ($consentText.Contains('New-Object Windows.Forms.CheckBox') -and $consentText.Contains('$install.Enabled=$false') -and $consentText.Contains('$box.Add_CheckedChanged({UpdateConsentInstallState})') -and (Get-UiFunctionText 'UpdateConsentInstallState').Extent.Text.Contains('Test-FastLlmUiConsentComplete')) 'the consent dialog starts with Install disabled and enables it through the all-ticked rule'
Check ($consentText.Contains('$dialog.AcceptButton=$cancel') -and $consentText.Contains('$dialog.CancelButton=$cancel')) 'Enter and Escape in the consent dialog cancel'
$consentDisposal = Test-NoDisposeInHandlers $consentFn
$chooserDisposal = Test-NoDisposeInHandlers $chooserFn
Check ($consentDisposal.handlers -ge 2 -and $consentDisposal.disposes -eq 0) 'the consent dialog disposes nothing inside its own Click, LinkClicked or CheckedChanged handlers'
Check ($chooserDisposal.handlers -ge 2 -and $chooserDisposal.disposes -eq 0) 'the chooser disposes nothing inside its own handlers'
function Get-DisposeCounts($FunctionAst) {
    $all = @($FunctionAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and ([string]$n.Member.Value) -ceq 'Dispose' }, $true)).Count
    $inFinally = 0
    foreach ($tryAst in @($FunctionAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] -and $null -ne $n.Finally }, $true))) {
        $inFinally += @($tryAst.Finally.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and ([string]$n.Member.Value) -ceq 'Dispose' }, $true)).Count
    }
    return [pscustomobject]@{ all = $all; inFinally = $inFinally }
}
$consentCounts = Get-DisposeCounts $consentFn
$chooserCounts = Get-DisposeCounts $chooserFn
Check ($consentCounts.all -ge 1 -and $consentCounts.all -eq $consentCounts.inFinally -and $chooserCounts.all -ge 1 -and $chooserCounts.all -eq $chooserCounts.inFinally) 'each dialog (and the font it made) is disposed only in a finally after ShowDialog returns'
Check ($chooserFn.Extent.Text.Contains('$dialog.AcceptButton=$choose') -and $chooserFn.Extent.Text.Contains('$dialog.CancelButton=$cancel') -and $chooserFn.Extent.Text.Contains('-Variant $variant') -and $chooserFn.Extent.Text.Contains('Get-FastLlmUiChooserNotice')) 'the chooser is filtered to the plan''s identified card, says what is missing, and Enter chooses the selected row'
Check ($ui.Contains('$previewed.recipe.variant')) 'the chooser reads the identified card from the previewed plan'
$continueAst = Get-UiFunctionText 'ContinueWithChosenRecipe'
Check ($continueAst.Extent.Text.Contains('if($Row.installRequired){') -and $continueAst.Extent.Text.Contains('-not $script:chooserNotice') -and -not $continueAst.Extent.Text.Contains('consentRequired')) 'the install dialog opens whenever any chain member is missing, and keeps the chooser''s notice in the status line'
Check ($consentText.Contains('$box.Enabled=(-not $consentRow.blocked)') -and $consentText.Contains('if($consentRow.needsAccept)') -and $consentText.Contains('$consentRow.statusText') -and $consentText.Contains('$linkText') -eq $false -and $consentText.Contains('$licenseLink.linkText')) 'the consent dialog lists every component, with only the missing ones tickable, and shows each link with its host'
$launchStepText = (Get-UiFunctionText 'LaunchStep').Extent.Text
Check ($launchStepText.Contains('if($script:installPath){try{[void](Sync-FastLlmExperimentalSwitch -SourceRoot $script:settingsRoot -TargetRoot $script:installPath)}') -and $launchStepText.IndexOf('Sync-FastLlmExperimentalSwitch') -lt $launchStepText.IndexOf('$script:child.Start($info)')) 'every child is given an install folder that carries the experimental switch the user set'
Check ($ui.Contains('Sync-FastLlmExperimentalSwitch -SourceRoot $script:settingsRoot -TargetRoot ([IO.Path]::GetFullPath($pathBox.Text))')) 'toggling the switch mirrors it into the install folder shown in the window'
Check ($launchStepText.Contains('$script:servingPreviousRunId') -and $ui.Contains('Get-FastLlmUiFailureCode -Status (Get-FastLlmStatus $script:installPath) -PreviousRunId ([string]$script:servingPreviousRunId)')) 'a typed failure code is trusted only when this start wrote it'
foreach ($planButton in @(@('installButton', 'install'), @('startButton', 'start'))) {
    Check ([regex]::IsMatch($ui, ('\$' + $planButton[0] + '\.Add_Click\(\{try\{ReadSelection;AssertUiBackgroundNotOccupied;\$script:chosenRecipe=\$null;\$script:flow=New-FastLlmUiFlow -Mode ' + $planButton[1]))) "the $($planButton[1]) button clears a chosen recipe before it starts"
}
$continueText = (Get-UiFunctionText 'ContinueWithChosenRecipe').Extent.Text
Check ($continueText.Contains('Get-FastLlmUiComponentInstallArguments') -and $continueText.Contains("LaunchStep 'component install' `$installArgs") -and $continueText.Contains('$Row.experimental -and -not $experimentalBox.Checked')) 'choosing a recipe installs through the argument builder and refuses an experimental row while the switch is off'
Check (-not $ui.Contains("'-Install'") -and -not $ui.Contains("'-AcceptLicense'")) 'the window builds no install or license-acceptance argument itself'
Check ($ui.Contains("'recipes','-Detail','-AsJson'") -and $ui.Contains('$chooseButton.Add_Click') -and $ui.Contains("ButtonAt 'Choose another setup'") -and $ui.Contains('$script:previewReady')) 'a Choose another setup button asks the CLI for the recipe list and is tied to a preview'
Check ($ui.Contains('$chooseButton.Enabled=[bool](-not $Busy -and -not $occupied -and -not $script:vcBroker -and $script:previewReady)')) 'the button is enabled only when a preview exists and nothing else is running'
Check ($ui.Contains("'component install'{") -and $ui.Contains('Test-FastLlmUiTypedHipFailure -Code $failureCode') -and $ui.Contains('Format-FastLlmUiTypedFailure')) 'a finished component install starts the chosen recipe, and a typed start failure is shown as its message'
Check ($ui.Contains('Get-FastLlmUiPreviewRecipeArguments -Recipe $script:chosenRecipe')) 'the chosen recipe is pinned for the preview'

Write-Output "UI flow tests passed: $checks"
