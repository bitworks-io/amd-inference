#requires -Version 5.1
# The keep-list pin for the window script (fast-llm-ui.ps1), and three small flip-ready pins.
# Pure: every file is parsed, never run.
#
# 1. Keep-list (plan D2). The window script's top-level items are: the param block, the statements before the big try, every statement in the
#    big try's body (each function definition and each other statement), and that try's finally block. The suite pins, by SHA-256 of the
#    item's text (line endings as LF), every item the flip leaves byte for byte as it is (KEEP-IDENTICAL). Each such hash must appear exactly once.
#    Every other item must be one of: an item the flip changes but keeps (the MODIFY list, matched by function name or a stable substring), or an
#    item the flip deletes whole (the DELETE list, by hash, inside the 5b-delete markers). A new top-level statement fails; a one-character change in a kept item fails.
# 2. The $Window readers: every reader of $Window or $script:Window (the param declaration excluded) is one of the ALLOWED switch sites, each in
#    its own 5b-delete block. When the flip deletes them the list is empty and the check means "no reader of $Window".
# 3. The window title (plan D7): the shell takes it from $script:FastLlmUiFluentWindowTitle, not from the classic form.
#
# The blocks wrapped in the 5b marker comment lines (begin and end pairs) go in the flip PR.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
$checks=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:checks++}

function ConvertTo-Lf([string]$Text){
    if($Text.Length -gt 0 -and [int]$Text[0] -eq 0xFEFF){$Text=$Text.Substring(1)}
    return ($Text -replace "`r`n","`n")
}
function Get-Sha256Hex([string]$Text){
    $sha=[System.Security.Cryptography.SHA256]::Create()
    try{$bytes=$sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))}finally{$sha.Dispose()}
    return (($bytes|ForEach-Object{$_.ToString('x2')}) -join '')
}
function Read-SourceText([string]$Relative){return (ConvertTo-Lf ([System.IO.File]::ReadAllText((Join-Path $root $Relative))))}
function Get-Parsed([string]$Text){
    $tokens=$null;$errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
    return [pscustomobject]@{Ast=$ast;ErrorCount=@($errors).Count}
}

# The top-level items of the window script. Kind: param, pre (before the big try), body (in its body), outer-finally.
function Get-TopLevelItems($Ast){
    $items=New-Object System.Collections.ArrayList
    $add={
        param($node,[string]$kind)
        $fn=''
        if($node -is [System.Management.Automation.Language.FunctionDefinitionAst]){$fn=[string]$node.Name}
        $first=($node.Extent.Text -split "`n")[0]
        if($first.Length -gt 60){$first=$first.Substring(0,60)}
        [void]$items.Add([pscustomobject]@{Kind=$kind;FnName=$fn;Line=$node.Extent.StartLineNumber;Start=$node.Extent.StartOffset;End=$node.Extent.EndOffset;Text=$node.Extent.Text;Sha=(Get-Sha256Hex $node.Extent.Text);Head=$first;Ast=$node})
    }
    if($null -ne $Ast.ParamBlock){& $add $Ast.ParamBlock 'param'}
    foreach($statement in @($Ast.EndBlock.Statements)){
        if($statement -is [System.Management.Automation.Language.TryStatementAst]){
            foreach($inner in @($statement.Body.Statements)){& $add $inner 'body'}
            if($null -ne $statement.Finally){& $add $statement.Finally 'outer-finally'}
        }
        else{& $add $statement 'pre'}
    }
    return ,$items.ToArray()
}

# KEEP-IDENTICAL: the SHA-256 of every top-level item of fast-llm-ui.ps1 that is the same text before and after the flip.
$keepSha=@(
    '80ac92bee4d55aa15fad976ea0e27400de58c5f74c02d3dc97d0f1993e18367f' # L3 $ErrorActionPreference='Stop'
    'deec25aa69215180abbda0fcc2be494b15f13fb7c98a8e95884286012cff919a' # L4 Set-StrictMode -Version 2
    '217ff0d84ba9a0174a401081e8f0831d01b61b1f156e3812f8e305ae62856abd' # L5 if ($env:OS -ne 'Windows_NT') { throw 'The control window re
    'de7c3eaeab11d09eb593b579d30b3bd7031cfe0050093b18020fceef2701cb5d' # L6 $principal=New-Object Security.Principal.WindowsPrincipal([S
    '7106c46006a2b9be7c633e1aeff49506a47ca0c12602539d17dbb9472b5a737f' # L7 if ($principal.IsInRole([Security.Principal.WindowsBuiltInRo
    '6f040a834e6c8b366f67abf6e71a5dc8958e30713ecd47a94c8b4842e64362bb' # L8 $labAppLifetime=$null
    '41a6d99c3fbe7fc72c44362d1e62e7db95a19743cbba29e7c63165ce89eca6bf' # L10 . (Join-Path $PSScriptRoot 'src/FastLlm.LabApp.ps1')
    'e538ed1f4e3fa9c0013d1027205854ca54060ea6f83658bc90a293dbd821b956' # L11 $labAppLifetime=Enter-FastLlmLabAppLifetime -SourceRoot $PSS
    'e8c1dc42032ae5e38cba774f8d8edc1b7297da958810cba14be63a6fcf206584' # L12 Add-Type -AssemblyName System.Windows.Forms
    '8ef592b3b6e0699f1c9fb316a89ed0ff6ded63078948c937dd9c3788fb5a61d2' # L13 Add-Type -AssemblyName System.Drawing
    '116df1e353981c7bf902aab00fc236ec29eb85f7b997d245fb5a74099cf50f38' # L14 Import-Module (Join-Path $PSScriptRoot 'src/FastLlm.psm1') -
    '237d38f67be5866323fa3d6cbf8700a6ac6440ad06a567e987a0e707a6fa257d' # L15 . (Join-Path $PSScriptRoot 'src/FastLlm.UiFlow.ps1')
    '2c4c33e12ac7f3adbe00216d2775319e6ac4cd72464c310741a7e26ccdc83a98' # L16 . (Join-Path $PSScriptRoot 'src/FastLlm.UiPrerequisite.ps1')
    '7cc0b1288b2a01c6b6ed976a9e8713ac47fa0ba784b7eb466baab8e49be68b2f' # L17 . (Join-Path $PSScriptRoot 'src/FastLlm.UiBackground.ps1')
    '3647ae61d9f648d0e5abacab203a1ca354df378fe94e25d571147db440f28f71' # L18 . (Join-Path $PSScriptRoot 'src/FastLlm.UiState.ps1')
    '66f7706db1fe521bbfd124eba01ef2685d241d4445d18217b84fd3fef19ba01f' # L20 . (Join-Path $PSScriptRoot 'src/FastLlm.Update.ps1')
    '465a8ac90382b2dbfb3c69ccfd98351475a84c561bb901a74d32aafeafdb87a2' # L22 . (Join-Path $PSScriptRoot 'src/FastLlm.Components.ps1')
    '3436dd132af1aac4a14ac578780db0c1625bd68e8dd939f2f5068d6f98d8cc5d' # L24 . (Join-Path $PSScriptRoot 'src/FastLlm.ServingSettings.ps1'
    '3706b3b25fbb5d7b3d99fb84670b577c45a55ff60da082b21053ad4d400dba53' # L26 . (Join-Path $PSScriptRoot 'src/FastLlm.SignInStart.ps1')
    '271356e43f3c8ccc7afc86583f7da665a604debe8952073347ae0cf6afdac20b' # L28 . (Join-Path $PSScriptRoot 'src/FastLlm.SupportBundle.ps1')
    '749ab85019750abc63cc6457f373c3bb1c898ff0387c910d937a39c1c0de4b12' # L30 . (Join-Path $PSScriptRoot 'src/FastLlm.ConnectInfo.ps1')
    '437a9021b2d684253fb8e396fbd10389552aa4722504a22764522e32d5d26d22' # L31 & (Get-Module FastLlm) { Initialize-FastLlmProcessHost }
    '86988cad26801261169c1d7606e8d24d59f6e64be68cd8ee7584eb9bac8da349' # L32 if (-not $InstallRoot) { $InstallRoot=Join-Path ([Environmen
    '3110f6e650a407be823a23fc0663973f258edaf17d210302b5f9f8239b3e49bc' # L35 $catalog=Get-FastLlmCatalog (Join-Path $PSScriptRoot 'config
    'a20ad175c598080efe3c668b64d8daffb469e637ae20130e5e7a451702111549' # L37 $script:settingsRoot=$InstallRoot
    'bc2e5ce05e3abc7f395c4315fa2f8bf66ad631b1a4af09a3b8a570e8b7f13fce' # L38 $script:child=$null
    '6144a5e7853102626cedbbe213296bc149e481cfb767ddbabe30648eb0f625ad' # L38 $script:step='idle'
    'bba0ad364e1b06c381fa403d85fabcfb1c72f94eeb086b9e3b7b03f503206c76' # L38 $script:selection=@()
    'e5e0219b0d086c0468ca57513f0c4b8ba98fbc39bd385841a1fe0168be321ee3' # L38 $script:installPath=$InstallRoot
    'f2a05639e758757b89ecb39a4fc7ea29b8411a3a89dc7297e67cc5ab2c1b9b30' # L38 $script:flow=$null
    '9a58d777fd73b7dff7883d5877e00ab5c07cc3f5a5aa8bb32c6753b3bd561899' # L39 $script:vcBroker=$null
    'bc9291de3b5083de64e0e025915b707cb12d58bf584238c6adb49c4797df3a7a' # L39 $script:vcPrepared=$null
    '05c8e382656c59cff024335d611da88766603bd6905fdc550aca8593d459752d' # L40 $script:vcCacheRoot=Join-Path ([Environment]::GetFolderPath(
    'a1771fc830e389e3bd53c2a0a094477f72f257917c70b118a224d170a8e12f1b' # L41 $script:vcManifestPath=Join-Path $PSScriptRoot 'config/windo
    '58cbfc8664d685a928f7372dd66f2cb2e5f66f59e11765be82f4edc181ac4cb8' # L42 $script:trayState=New-FastLlmUiTrayState
    'e0bc7eee4ab0f11e7639e30a3d2a1952ce93709080f5ad8702d513567c0caa4a' # L42 $script:trayIcon=$null
    '5a9c378bb582a393c6ec53e4f4951567326f32acb5d72204df85c8b74e3d3630' # L42 $script:trayMenu=$null
    '0d20eb870de3158dce20dd815d7419fe3eec5e7958409f71b090522107e840d5' # L43 $script:bgState=New-FastLlmUiBackgroundState
    'a16c9798fe8d49e2bd8e8b096fc344fba188bcf7a947f358915bd92a63286740' # L43 $script:bgNextPollUtc=[DateTime]::MinValue
    'bc36690f799b671d003942074de3f1909505e3816621454ab15e0da42c411c94' # L44 $script:bgStopRequested=$false
    '14b8a3d9732e63d3c15f0b7520ca597204e3720d25cc1ddd57ccc52bdc0dbe9d' # L45 $script:bgEndedByUserStop=$false
    '6b5068761950101a8fcb907a99e393b0ff9a7cb9645cad282568392677332e99' # L46 $script:bgPoll=$null
    'aa0b9e232d9c2c4a4b3fd13233d2ba78c2e5ff8b5400c0ee126510835bd55cc0' # L47 $script:startupRun=$null
    '2a419277e6eeac524b52447ae1763b28878c555479729668210d012b33fd953b' # L47 $script:updateRun=$null
    '82193b9875be2de97ac09ac5d4a285e975881498972ca374ccd044ffbc0154d4' # L47 $script:updateOffer=$null
    '1f24aa56b801eaa7753bad26903224c48b42f359ad173f67dc0653c9c25f7635' # L47 $script:reinstallOffer=$null
    '4adc796936b7839ccf088eb91b7efeb6fdf81c0e1ec52f01c15b75ca1ee4da4d' # L47 $script:updateOutcome=$false
    'cc70b71c8fa449fe0fcc36414e15b222c6928ee4058a05493acdf1d478ca41ac' # L47 $script:bannerUrl=$null
    '38a6b09d58c207ec1c50d7549def6ab96939e01c3c04bb358e369823f33f0ccf' # L80 $script:barValues=@('auto','on','off')
    '5e0efca311b437cffce3293e6d7069c9e40d7a2a4160eab5101db661e88f3d54' # L82 $script:uiSettings=Read-FastLlmUiSettings -InstallRoot $scri
    'a225daba53185eb809885c9d4493ed61875af6967c74e57b988095756cff48f4' # L83 $script:lastUserStoppedRequestId=[string]$script:uiSettings.
    '1c0e1a52038754c99cbc05c0ef8e0ac4470e7a864e63540ce68de54e4174db3a' # L85 function SaveUserStoppedBackgroundRequestId
    'fbff47824d4c89970288d8bf4f55fdc5d01446f39305a74435b1f8a8cb2f7da2' # L91 function GetBarValue
    '2ccf80c3773e7d835f6a87841bdb1744c2a9245900a2722d572fd3f5c7b8c6d5' # L115 $script:chatUrl=$null
    '03b89f19c6c58b399c52228103d0b2fa1564ed34d4b748c12e576789935e8139' # L117 $script:sideChild=$null
    '01c7cbbe82a530fc1ca70025eadc36ede54c6ee936b08ab2954dc40dde1018c7' # L117 $script:sideStep='idle'
    '784a42292c8df7f724b07328b9f00a678acfec7726a49db878e20017e214816e' # L117 $script:runReady=$false
    '0f6bd98e5e24fb9057f05ca01b2248d8b8a9334e9d0faf826c89f367e2908840' # L117 $script:servingSettingsNotice=''
    '44d4d1075308703cdf3070cd76d567ac6a7cbd4607732204fbb20ec1c32f077b' # L119 $script:previewReady=$false
    '9139b2a6ecda32931c659eea116b20302094ea03373d07601838acb30616e225' # L120 $script:chosenRecipe=$null
    '9dbd75b50fbc62471e43b1bfce302ccf1d951e68ebbaef0b65a7a114afb8ce2a' # L121 $script:pendingRecipeRow=$null
    'e1fe61c2fd488fbaeebeaab1032ffa30cec98ac67174d144cc61117a14d17b8d' # L122 $script:servingPreviousRunId=''
    'e42da8d2bf042606671388ec3527177e705c643c3ea7752c7862eec049186a3e' # L122 $script:bundlePath=''
    '7bd4f2ce48558ade85d80e4a9fbc5868d78f1341fdbc444717f62edd82064f3f' # L123 $script:identifiedVariant=''
    '0122028e12aaf97cf6346c7526a0bd33cec4bcb918500d398c6dde45a9a7f2d2' # L124 $script:chooserNotice=''
    'b2883a5a4fec6cec78c57b08e7f6e8e67e84ca01a955e6f7d308b5fb10862c4c' # L142 $script:switchGap=$false
    '8b5b877340208cf90ea949ef2246cd59896c08bc355e2cfec04600cb2383dad1' # L143 $script:evidenceUrl=$null
    'a986d5afacbee5e1525952dd7242cc53d50fb94924386c58aa0e931ef44deaa5' # L146 $script:failureCapture=$null
    '81499036a959eebaae081d97f93269729dbca0c8da3037367734ba15c9756296' # L147 $script:failureHeld=$false
    'e80c0a20a8e3e0fadb7467bf115189eaea067c2f3874ac190dadd27dc1cd793c' # L147 $script:failureViewText=''
    'e2a72096388554a3dd597d200af715d08d722cd9aa73e25f50a552cd4f1b22b7' # L151 function ClearFailureCapture
    '538e572eb4cf5eb337eb93c7e0083c914195f69e3ea689c7ffff0746caa2a83b' # L152 function SetFailureCapture
    'e481ca182c3a45b1aebdbbcac4535893ab1546beb3710df99ab65fdf0e456b44' # L156 $script:servingNotesDone=$false
    '09d82ffbc13e3c057dd481727da5be5f711f376ed3f4955119eb8b946f4d4866' # L158 function ClearPreviousRunNotes
    '30b4075f00d5a986d81859670c1a048d615afee20b4f345fec4324ce908dfad8' # L173 $script:licenseRevert=$false
    'd5bac4ca5c6b0a3217387cf473d78889ea7172e129335c4746466e10527b6b61' # L174 $script:fallbackRequest=''
    '78170256465653e44fcff5e388e47cd5eceeea20a5ec53be6e9e4f63d963cd43' # L174 $script:setupNotice=''
    'b5a3255d8cc80539b14de7e89f5c11ea61f40c4dcba7dc62692d7000e0414961' # L174 $script:planComponentInstall=$false
    '44003498ab5e1b91a6f7a50c6ad1df9c8a381a30797a359ba3373b03cad84bb2' # L187 $script:uiDialogView=$null
    '59b3599be46f4567ed1fd9bc73ce7cddb8f09aa6f2dc9aba517541678b10c5a3' # L193 function SetUiBanner
    '93b3b7915e60e0db35bb310a1dd565861e72f221a81bc9468f29a1a3b8a97ca2' # L208 $vc.Add_LinkClicked({try{Start-Process 'https://learn.micros
    '99cb5041be21a89f4a06d4ddb95862ee7d91936fe34223410370130fe06b92da' # L209 $amd.Add_LinkClicked({try{Start-Process 'https://www.amd.com
    'f472f5e9f18e514d9cd6146d0769a5fa38b4f591d301d4660338b3a4e4aa651a' # L210 $failureCopyLink.Add_LinkClicked({try{[Windows.Forms.Clipboa
    '1bf6ec0c6f0da4fb08f423a48cd479ec1de658f2cbf774aa32ca5fb53e8facdf' # L211 $resultsLink.Add_LinkClicked({
    'ab4e1d55141577b6e9fe01fdefbca40527b917a987a5fb22cec25acd4627b9cf' # L217 $barLink.Add_LinkClicked({try{Start-Process 'https://github.
    'a75a76eed33af42c540fc8a9cc9ed4b1f43aedf0070afddb8660aa1ec7c23959' # L218 $barBox.Add_SelectedIndexChanged({
    'b6f6c5519ad0746a18cbd79549f32bd7a37ef24c452f3e166b7fb4358187a8af' # L222 $bannerNotes.Add_LinkClicked({
    'd668ebf661ec6d3eeda0b64738d0eac63da510e945954fc320dccc2d2d28f376' # L228 $updateBox.Add_CheckedChanged({
    '5cf3a7fddde3250e5279ca7a9c76befac9213b6542c00ed5366bd77c8549fc78' # L233 $experimentalBox.Add_CheckedChanged({
    'ae525df401d83007ca896836adac6ba8c36053dedeb070c4460884153837ae84' # L296 $licenseBox.Add_CheckedChanged({
    'b5dc2da428075b30e427f89568465a3bad8d97cc47524a769b68bed098d82165' # L321 function GetUiStateSnapshot
    '9b2dff7fccc72dce58f46fd4138a02f924208f7edaa8235126a4dd4d115ec09c' # L329 function SetBusy
    '0c554572334bf82809cd8df9386b52001593818955197e2861bf910bf3db41e3' # L351 function GetUiActionAvailabilityNow
    '619e5183343565d86fc517d29c0cdf1160355238838b14d1afcc66bb36c1f6ec' # L355 function UpdateUiRunState
    '7baff54380add8323ecc5f92a6cd2b54aa90523e63a4b6b8f90e839355fc7d38' # L364 function UpdateUiSwitchState
    '1ee3b87fffa1e226383c84b67c4a41555868c1ade293a3b7e263a0540ed7e9b1' # L371 function RefreshUiSwitchState
    '84f6ffa3a77ed60aea4bcdc2e9c745b4e8c23c3e52f4906c73039c436062e10f' # L374 function GetUiBackgroundStatus
    '26544f51e71ead95ec71cc9858f605c52d28384cc39b47667658ecec714bcda3' # L380 function TestUiBackgroundProcess
    '0bb220d4b988e3d13944c4ee6732a048b2cba60b7cab03d586c09c0e5310028e' # L387 function GetUiBackgroundRunStatus
    '8fe355a1014c90cfb600758f84182289c762b2f40384bc537e358b01e3d3db09' # L390 function ApplyUiBackgroundStatus
    'ad76a3c74e1f199571cd00c1dc0f064243403d2f9127068cb4de720b2e902f74' # L424 function SetUiBackgroundUnknown
    'cc31ea613758f20e6cd596ff90039b77ab5dad9ba3f8454c749e81ee37e756af' # L431 function RefreshUiBackgroundStatus
    'dcad30170d771c03a49aa1085f6370e82e0781ae90948dae469bab0451085008' # L434 function StartUiBackgroundPoll
    'a9cf4a6e23d9cc3637b7028d7b060a51532a4e13cdc686c2237c75e54c0ee04d' # L453 function CompleteUiBackgroundPoll
    '8a976dba20a5262e181a6f36a83d500267a24f3a154cce155a42b09ff690fc91' # L466 function AssertUiBackgroundNotOccupied
    'c72f76ff523553ba14c49f060fe65774dd1c1c08379c745105cb7a10adfe2f05' # L473 function GetVcCandidate
    'af16889098fa320f1db943c3b26b785f8746502abde46431cab42c9750b6d69d' # L479 function GetVcInstallDecision
    'cfafaf970c4ea4710e61d22fd5f836fd9d3190318acd4cef145673b6b0003b00' # L485 function ReadSelection
    'e40336462e879204105f1eda4a11ed08c853a6cab9cb79afa5ab70ae015b56dc' # L492 function LaunchStep
    'd2a8d62cc58938b9aea086d4477e12e944b2b052ea9707734d3074317c2c33ae' # L533 function LaunchSideStep
    '5113c9a3bb2b2343e0b1460274244a00b28f3fcb5e4be1b18e9a6d7f4fc6bb5e' # L554 function CompleteUiSideStep
    '2b57909029e79f4fe19ddc79b46e1c9edb15a31c98a8195b37a00d8818d75cd9' # L581 function RevealUiForAction
    '8b61070b2c914db60e918b70ac2fa4021b98ef80f51a485e22d5302115ce9472' # L585 function SetTrayMenuAvailable
    '9a1576e1682f382a370cc5cd8167534eb493c5053a50fadaf1e472722cab546e' # L592 function ShowFailure
    'd015b970e71205963ddde2141542b15c22c738b158f2a97414ed8a0996f428d9' # L613 function DisposeTrayControls
    '98bee261a9b388ed0a75a302b6972a323eaf46336c49e9a78ce4229bc4981221' # L623 function EnsureTrayIcon
    'bdf2eef5e3448c8479ec0663772898a2d897eef8142d9357790b0e615b96abff' # L642 function MinimizeToTray
    '0863bb403bc3080a3c72232f095e4e466b18e397cc7e179d83aea02cd985ff2b' # L655 function RestoreFromTray
    'f3325ed37d785af49b1e1ee14ca7c536bd16fa22fda8fcc1e09c05e0f27a26c6' # L660 function ExitFromTray
    'fac53da00a4e7bf1bfd081b759971918ba8dcd25cb5f73a49d15b70ff3f0e908' # L664 function StopUiOperation
    '85a48b382b006d84770ae1def9f7521b57e82a520c84bdf44cd7413b99c488dd' # L781 function StartVcBroker
    'eb050c407ae593f0ff30bd72c6e0f09a9cab6530df7f24faa1763dbb60d278c0' # L802 function HandleVcBrokerResult
    '0aea36a49175d4bab13eb61902b0e690e51e19a7b097fee06f004c1f55496e75' # L842 function LaunchUiPhase
    '520824b02d51ab5f916826e77617c2ea377f2272b2b915345e36d867603a903c' # L869 function RepreviewForPendingSetup
    'de956249be3d17b9ca8c86fbcf0870016d55c8fac2cabfa5b1ca3b21cc545a57' # L876 function HandlePendingSetup
    '2761bad6a193dc155bea7957d7442c814db1f1f70fe6e65cf97e336597219b51' # L902 function ContinueUiAfterPreview
    '7d938cf80a43193b1f6d774c063dddbedfc91c48e4384bdbe6e60bb0cd7b4344' # L975 $script:apiKeyStore=$null
    'fa6d4dfb96fd6a4cf0e8abffd212ac8e2aa6c63c220121c0f2f56d5753537413' # L975 $script:apiKeyStoreStamp=''
    '1ff0244b19aebb272a54c2888fcaebf3d78ce68c2453ea779484317eabd130bb' # L976 function GetUiApiKeyStore
    '8c204eb15bb0ba8038fa61742d91ed032fcef1b9cc61431e6c19a04996c2436e' # L985 function ReadUiApiKey
    '4f141714aa313e3e4749f7b1aded7963b91327a16e4068342b54489a8525bf43' # L989 function SetUiClipboardPayload
    'e5ed887e0ae3a6e23bb89ae422b5a323b6a6341fc06f8110239ef4ace8fdb6d5' # L993 function NewUiApiKey
    'b7f8ac5d66641934f93d9beb47198215c813cb04625e908858d7e611072fb0be' # L1003 function ShowUiApiKeyFailure
    '05d22cae49acdcf892042b93f0cea120fe839982f405c474ca10a236d5e9ca41' # L1146 function StartUiBackground
    'e2cd598770bc8be6d3686d752b08fcc9a74997fa5ce320000d6a4dda1d41318e' # L1180 function AttachUiBackground
    '323adb0e4f8f29fc40214adfa69f0422299369617841eb002fa114130d9d1f57' # L1200 $installButton.Add_Click({try{ReadSelection;AssertUiBackgrou
    'ad46e7011770204de85d8ed2aa752371c4cbdb1f178ec3c33c9cc86208603631' # L1201 $startButton.Add_Click({try{ReadSelection;AssertUiBackground
    '479b611d6acaa388a59475285668f4bed73588f5e78f1ae7f618125b27c9c5e9' # L1202 $backgroundStartButton.Add_Click({
    'b2c3f6297ed66988eb03674ec25aeadf2e58cedf93b5fbb20024f6171039c533' # L1214 $backgroundAttachButton.Add_Click({try{AttachUiBackground}ca
    'c32e23f15070b75e785b6cea9687cc6a9a87c7c89bece06f685d56965340a711' # L1215 $backgroundCheckButton.Add_Click({
    '5bb80d5d463d781ef475aa10b6c1e33ea8cc84cf28343e949b3754b6e95acc22' # L1226 $doctorButton.Add_Click({try{ReadSelection;LaunchStep 'diagn
    '3fda58bd7d2b241f09b20871807c7b76c9c293c048becdb8a82764eea521e63a' # L1227 $driverButton.Add_Click({try{ReadSelection;LaunchStep 'drive
    '0232011ec9f6407ff2d2fd3ab51df65ebe2917c126da0d2a49ded254ebf4c6e9' # L1229 $script:componentsView=$null
    'ac536b2cd07350b14459f8bed40d01155c8a93aed99b1e5c0c83e42dfc9354ad' # L1254 function RemoveComponentFromWindow
    '0964f8e07f0a7c4b19ee576d212455f038c2acf35bcdd7082929189b2770a392' # L1290 $script:modelsView=$null
    'ed947c4d57b1e64d50c682e31eca61b82724fa9ef442d114fb3203fcd97bb374' # L1329 function RemoveModelFromWindow
    'a0462ea87ec33da56b8f02015ffe472fe6503524704de0c24e32553a53156863' # L1349 function RemoveLeftoversFromWindow
    'baee430569ca6042c92d2e0e05d906c52c4dd4c737246fde76b2b3c18026edc1' # L1431 function OpenLogsFolder
    'b2c5e2f5cd11d2fb88ee365429aca356cafd46b3d7ea91f3d8a205607e289356' # L1438 $logsButton.Add_Click({try{OpenLogsFolder}catch{$statusLabel
    '42f23680e0fff70035b13472f2ab05288c52f4c9284026457c3c7c779569fb41' # L1441 function ReadSideSelection
    'c485148710a15c7bd867f8905d228162c136ba996871ec6052bcd5ae9d6951f3' # L1445 function StartSupportBundle
    '31e4df45aa957c9021257ef709ff7ef6b2e2d8ed0b7acbe011dd1a61425794ae' # L1450 function ContinueSupportBundle
    '6ab7d1837f67f72c74e67903be3bd3009c3f6af89d677590862be55f174d3a51' # L1472 $bundleButton.Add_Click({try{StartSupportBundle}catch{ShowFa
    '1f9bfe2f18246afcd81442c35204750c9cb2911ba7147f28e43e1f52f5a3ba9d' # L1576 function StartRecipeList
    '421e4b41d1096f9a696318309460b31dc802ce158058109c5b04e7c422edcc22' # L1713 function BeginChosenRecipe
    '3d6e92e61380bfff19b4b29cbe73f3191e02c8d44503856ffb8a26c8f1d2d6c3' # L1721 function ContinueWithChosenRecipe
    'e908bd43b34174c92300eb4d77a2604f9a9a45623d84f230c31203051ae3c60b' # L1744 $chooseButton.Add_Click({try{StartRecipeList}catch{ShowFailu
    'd919d2fc434ada9cb3a326e6a6b940193cdd71c1de53ae1c64cb9df1c5cd3d4d' # L1746 function StartUiStartupChecks
    '6cfa7c9997fec14c480759de09cf3a1ce5a0940a6cd540d22779bdf3c086b7e7' # L1770 function CompleteUiStartupChecks
    '141af233fcc54ad77b3794c8479d3cc7d0fd26a2d06ab74df73ab249c36dfa7f' # L1790 function InvokeUiUpdate
    '345de0026fd90d5d0d2db03e6b83adfcd76b1e39b0192f9d6ea60bc9c70ead15' # L1813 function CompleteUiUpdate
    'a79d897543feba052ffbde1a11ba00cd3d79b1f23ed7c3efbcdec2d9b2dd89ac' # L1839 $bannerButton.Add_Click({try{InvokeUiUpdate}catch{$statusLab
    'a68b77e7690b2510e452e70f4645c55ffb143ea6398f97400058da994ab8328b' # L1840 function InvokeUiReinstall
    'a867926bd121ce9957077905c60bac25f89667c2acdcaa535c2d8390f32459b6' # L1864 $reinstallButton.Add_Click({try{InvokeUiReinstall}catch{$sta
    '60840bd4aab06e9c5ec11d844e37db7e6f1b1d3ecc274e1ad826f9f838ff93e0' # L1865 $form.Add_Shown({try{StartUiStartupChecks}catch{}})
    '0817173e39f8d54f5d36ca065ada904734fc7458346faffbe90eee7883e10f6a' # L1866 $copyButton.Add_Click({
    '4417023832a26128b5830ac8f41cba766ae9c74c511df2f885ca942797055457' # L1870 $openChatButton.Add_Click({
    '35540bcb72bf2533e2ffaca6b900c4e25ad2ce1f2eddde8464b5457c40f39c1f' # L1877 $stopButton.Add_Click({try{StopUiOperation}catch{ShowFailure
    '07afa0af8b5c92062a0c7539d9300d6928505463cb2abd9f2bbc0fa27003cf3e' # L1878 $trayButton.Add_Click({
    '6801da60cf8b75b107b5845f319d56efb6783a63951dab5a3d75dd966454267c' # L1884 $timer=New-Object Windows.Forms.Timer
    'd593931bee17051b33e12389d17ef551a6161097f2e9ab6490887704e43910a4' # L1884 $timer.Interval=250
    'a4c76b29857e42f865e7a3b7a9a51111a8f5f5ce11b84e9feaee837f062ba312' # L1885 $timer.Add_Tick({
    '676ba374d4c272579cc5c6217146be560788c99b4bb4b45384e5d645823c4790' # L2063 $script:bgNextPollUtc=[DateTime]::UtcNow.AddSeconds(2)
    '9a8c4e4a03c90d11ed2cbc08781067622679f6f673966177dfaf3ea73d11aac2' # L2064 RefreshUiSwitchState
    'e96b9aa6636ddaf4add48e9febab7b3448c9a4f6aee4e5a23f93f99ecdde19a9' # L2066 try{$signInAttention=Get-FastLlmSignInAttentionText -Install
    '87aa1d792165fb79bae1eea5471ed65239ab50a4d92a841d032e6d689285a40c' # L2067 StartUiBackgroundPoll
    'd7667c9fea170ba0c3a31df387fcc625a5c0f75f5b7cda7cc7c5f93f5c70a8d6' # L2068 $form.Add_FormClosing({param($sender,$event)
    '7aeff895a27e8731d34fdac2f78d3fb25e1709624b3473742b16d0213826e3a8' # L2099 $timer.Start()
    '7da17886fa03e1fc76c4d698443b24cede38cdf1d6b7a52d3e26b02699fda36c' # L2108 { if($labAppLifetime){$labAppLifetime.Dispose()} }
)

# MODIFY: items the flip changes but keeps. A function entry matches the function definition of that name; a text entry matches one item
# (not a function, not the param block) whose text contains the substring and is at most Max characters. The substring is in the item both before and after.
$modify=@(
    @{Kind='param';Why='the param block (drops $Window)'}
    @{Kind='text';Needle='src/FastLlm.UiFluentShell.ps1';Max=800;Why='line 34, the shell dot-source'}
    @{Kind='text';Needle='Test-FastLlmUiFluentHost';Max=800;Why='line 34, the support check'}
    @{Kind='text';Needle='Show-FastLlmUiUnsupported';Max=800;Why='line 34, the unsupported-PC exit'}
    @{Kind='text';Needle='Initialize-FastLlmUiFluentShell';Max=400;Why='line 188, the shell rebinding'}
    @{Kind='text';Needle='Start-FastLlmUiFluentLoop';Max=1200;Why='the main try'}
    @{Kind='function';Needle='ShowUiMessageBox';Why='dispatch function'}
    @{Kind='function';Needle='ShowLicenseSettingConfirm';Why='dispatch function'}
    @{Kind='function';Needle='ShowUiSideResult';Why='dispatch function'}
    @{Kind='function';Needle='ShowSetupAttention';Why='dispatch function'}
    @{Kind='function';Needle='ShowVcInstallReview';Why='dispatch function'}
    @{Kind='function';Needle='ShowExactModelConsent';Why='dispatch function'}
    @{Kind='function';Needle='ShowDriverGuidance';Why='dispatch function'}
    @{Kind='function';Needle='ShowRecipeChooser';Why='dispatch function'}
    @{Kind='function';Needle='ShowComponentConsent';Why='dispatch function'}
    @{Kind='function';Needle='GetUiTrayIcon';Why='the tray icon wrapper (reads $script:Window today)'}
    @{Kind='function';Needle='FillComponentsPanel';Why='loses its classic tail below the fluent early return'}
    @{Kind='function';Needle='FillModelsPanel';Why='loses its classic tail below the fluent early return'}
)

# DELETE: items the flip deletes whole, by hash. Empty once the flip has landed.
$deleteSha=@()

function Test-ModifyMatch($Entry,$Item){
    switch([string]$Entry.Kind){
        'param'{return ($Item.Kind -ceq 'param')}
        'function'{return ($Item.FnName -ceq [string]$Entry.Needle)}
        default{return ($Item.Kind -cne 'param' -and $Item.FnName -ceq '' -and $Item.Text.Contains([string]$Entry.Needle) -and $Item.Text.Length -le [int]$Entry.Max)}
    }
}

# Everything the keep-list pin finds wrong with one version of the window script's text; an empty list is a pass.
function Get-KeepProblems([string]$Text){
    $problems=New-Object System.Collections.ArrayList
    $parsed=Get-Parsed $Text
    if($parsed.ErrorCount -gt 0){[void]$problems.Add("The window script has $($parsed.ErrorCount) parse errors.");return $problems.ToArray()}
    $items=Get-TopLevelItems $parsed.Ast
    $count=@{}
    foreach($item in $items){$count[$item.Sha]=1+[int]$(if($count.ContainsKey($item.Sha)){$count[$item.Sha]}else{0})}
    $keepSet=@{};foreach($h in $keepSha){$keepSet[[string]$h]=$true}
    $deleteSet=@{};foreach($h in $deleteSha){$deleteSet[[string]$h]=$true}
    foreach($h in $keepSha){
        $n=0;if($count.ContainsKey([string]$h)){$n=[int]$count[[string]$h]}
        if($n -ne 1){[void]$problems.Add("A kept item (hash $([string]$h)) appears $n times instead of once.")}
    }
    $matched=@{}
    foreach($item in $items){
        if($keepSet.ContainsKey($item.Sha) -or $deleteSet.ContainsKey($item.Sha)){continue}
        $hits=0
        for($i=0;$i -lt $modify.Count;$i++){
            if(Test-ModifyMatch $modify[$i] $item){$hits++;$matched[$i]=1+[int]$(if($matched.ContainsKey($i)){$matched[$i]}else{0})}
        }
        if($hits -eq 0){[void]$problems.Add("The top-level item at line $($item.Line) ($($item.Head)) is not on the keep list, the modify list or the delete list.")}
    }
    for($i=0;$i -lt $modify.Count;$i++){
        $n=0;if($matched.ContainsKey($i)){$n=[int]$matched[$i]}
        if($n -ne 1){[void]$problems.Add("The modify entry '$($modify[$i].Needle)' ($($modify[$i].Why)) matches $n items instead of one.")}
    }
    return $problems.ToArray()
}

# A copy of the text with one more statement as the first line of the big try's body.
function Add-AfterBigTry([string]$Text,[string]$Line){
    $marker="`ntry {`n"
    $at=$Text.IndexOf($marker,[System.StringComparison]::Ordinal)
    if($at -lt 0){throw 'The big try was not found.'}
    return $Text.Substring(0,$at+$marker.Length)+$Line+"`n"+$Text.Substring($at+$marker.Length)
}

# A copy of the text with one letter inside the item changed (a one-character regression that still parses).
function Get-ItemMutant([string]$Text,$Item){
    $mid=$Item.Start+[int](($Item.End-$Item.Start)/2)
    for($p=$mid;$p -lt $Item.End;$p++){
        $c=$Text[$p]
        if($c -cmatch '[a-z]'){
            $swap='q';if($c -ceq 'q'){$swap='z'}
            $candidate=$Text.Substring(0,$p)+$swap+$Text.Substring($p+1)
            if((Get-Parsed $candidate).ErrorCount -eq 0){return $candidate}
        }
    }
    throw "No parsing one-letter mutant for the item at line $($Item.Line)."
}

$uiText=Read-SourceText 'fast-llm-ui.ps1'
$parsedUi=Get-Parsed $uiText
Check ($parsedUi.ErrorCount -eq 0) 'fast-llm-ui.ps1 parses.'
$uiItems=Get-TopLevelItems $parsedUi.Ast

# --- 1. The keep-list ----------------------------------------------------------------------------------------------------------------------------
Check ($keepSha.Count -eq 179) "The keep list holds 179 hashes (it holds $($keepSha.Count))."
Check ((@($keepSha|Select-Object -Unique)).Count -eq $keepSha.Count) 'The keep list has no repeated hash.'
$keepProblems=@(Get-KeepProblems $uiText)
Check ($keepProblems.Count -eq 0) ("The window script's top-level items match the keep, modify and delete lists: "+($keepProblems -join ' | '))

# Mutants: a one-letter change in any kept item fails. Sampled across the file: first, a quarter, half, three quarters, last, the finally block,
# the first function, and the first Add_Tick or Add_FormClosing statement.
$keepItems=@($uiItems|Where-Object{$keepSha -contains $_.Sha})
Check ($keepItems.Count -eq $keepSha.Count) 'Every kept hash has an item to mutate.'
$picks=New-Object System.Collections.ArrayList
[void]$picks.Add($keepItems[0])
foreach($q in 1,2,3){[void]$picks.Add($keepItems[[int]($keepItems.Count*$q/4)])}
[void]$picks.Add($keepItems[$keepItems.Count-1])
$finallyItems=@($keepItems|Where-Object{$_.Kind -ceq 'outer-finally'})
Check ($finallyItems.Count -eq 1) 'The big try keeps its finally block unchanged.'
[void]$picks.Add($finallyItems[0])
$fnItems=@($keepItems|Where-Object{$_.FnName -cne ''})
Check ($fnItems.Count -gt 50) 'Many kept items are functions.'
[void]$picks.Add($fnItems[0])
$handlerItems=@($keepItems|Where-Object{$_.Text.Contains('Add_FormClosing') -or $_.Text.Contains('Add_Tick')})
Check ($handlerItems.Count -ge 1) 'The Tick or FormClosing handler is on the keep list.'
[void]$picks.Add($handlerItems[0])
foreach($pick in $picks){
    $mutant=Get-ItemMutant $uiText $pick
    $found=@(Get-KeepProblems $mutant)
    Check ($found.Count -gt 0) "mutation check: a one-letter change in the kept item at line $($pick.Line) ($($pick.Head)) fails the keep-list pin."
    Check (@($found|Where-Object{$_ -like 'A kept item*'}).Count -ge 1) "mutation check: the change at line $($pick.Line) is reported as a kept item that is gone."
}
$sneak=Add-AfterBigTry $uiText '$sneakyNewStatement=1' 
Check ($sneak -cne $uiText) 'The new-statement mutant changes the text.'
Check ((Get-Parsed $sneak).ErrorCount -eq 0) 'The new-statement mutant parses.'
$found=@(Get-KeepProblems $sneak)
Check (@($found|Where-Object{$_ -like '*is not on the keep list*'}).Count -eq 1) 'mutation check: a new top-level statement in the big try fails the keep-list pin.'
$sneakFn=Add-AfterBigTry $uiText 'function SneakyNewFunction { 1 }' 
$found=@(Get-KeepProblems $sneakFn)
Check (@($found|Where-Object{$_ -like '*is not on the keep list*'}).Count -eq 1) 'mutation check: a new top-level function fails the keep-list pin.'
$renamed=$uiText.Replace('function GetUiTrayIcon','function GetUiTrayIconRenamed')
Check ($renamed -cne $uiText) 'The renamed-function mutant changes the text.'
$found=@(Get-KeepProblems $renamed)
Check ($found.Count -gt 0) 'mutation check: a modify-list function that is renamed fails the keep-list pin.'
$gone=$uiText.Replace('$labAppLifetime=$null','')
$found=@(Get-KeepProblems $gone)
Check ($found.Count -gt 0) 'mutation check: a deleted kept statement fails the keep-list pin.'
# Control: the unmodified text passes (it is the same call as above, on the same text).
Check (@(Get-KeepProblems $uiText).Count -eq 0) 'control: the unmodified window script passes the keep-list pin.'


# --- 2. Readers of $Window ------------------------------------------------------------------------------------------------------------------------
# A reader is any variable AST named Window or script:Window (or global:/local:), except the param declaration itself. Each ALLOWED entry names the
# top-level item the reader sits in (a function name, or a substring of the item's text).
$allowedReaders=@()

function Get-WindowReaderProblems([string]$Text){
    $problems=New-Object System.Collections.ArrayList
    $parsed=Get-Parsed $Text
    if($parsed.ErrorCount -gt 0){[void]$problems.Add('The window script does not parse.');return $problems.ToArray()}
    $items=Get-TopLevelItems $parsed.Ast
    $hits=@{}
    $readerCount=0
    foreach($item in $items){
        $vars=@($item.Ast.FindAll({param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and ([string]$n.VariablePath.UserPath) -imatch '^(script:|global:|local:)?Window$'},$true))
        foreach($v in $vars){
            if($v.Parent -is [System.Management.Automation.Language.ParameterAst]){continue}
            $readerCount++
            $owners=@()
            for($i=0;$i -lt $allowedReaders.Count;$i++){
                $e=$allowedReaders[$i]
                $hit=$false
                if([string]$e.Fn -cne ''){$hit=($item.FnName -ceq [string]$e.Fn)}
                else{$hit=($item.FnName -ceq '' -and $item.Text.Contains([string]$e.Needle))}
                if($hit){$owners+=$i}
            }
            if($owners.Count -eq 0){[void]$problems.Add("A reader of `$Window at line $($v.Extent.StartLineNumber) is not an allowed switch site.");continue}
            foreach($o in $owners){$hits[$o]=1+[int]$(if($hits.ContainsKey($o)){$hits[$o]}else{0})}
        }
    }
    for($i=0;$i -lt $allowedReaders.Count;$i++){
        $n=0;if($hits.ContainsKey($i)){$n=[int]$hits[$i]}
        if($n -ne 1){[void]$problems.Add("The allowed reader '$($allowedReaders[$i].Name)' matches $n readers instead of one.")}
    }
    return $problems.ToArray()
}
$readerProblems=@(Get-WindowReaderProblems $uiText)
Check ($readerProblems.Count -eq 0) ('Every reader of $Window is an allowed switch site: '+($readerProblems -join ' | '))
$extraReader=Add-AfterBigTry $uiText '$sneakWindow=$Window' 
Check ($extraReader -cne $uiText) 'The extra-reader mutant changes the text.'
$found=@(Get-WindowReaderProblems $extraReader)
Check (@($found|Where-Object{$_ -like 'A reader of*'}).Count -eq 1) 'mutation check: a new reader of $Window outside the allowed sites fails.'
$scriptReader=$uiText.Replace('function GetUiTrayIcon {','function GetUiTrayIcon { $null=$script:Window;')
Check ($scriptReader -cne $uiText) 'The tray-icon mutant changes the text.'
$found=@(Get-WindowReaderProblems $scriptReader)
Check ($found.Count -gt 0) 'mutation check: a second reader of $script:Window inside GetUiTrayIcon fails.'
$found=@(Get-WindowReaderProblems $uiText)
Check ($found.Count -eq 0) 'control: the unmodified window script passes the $Window reader check.'

# --- 3. The window title (plan D7) ---------------------------------------------------------------------------------------------------------------
# The literal below comes from the classic form's Text (fast-llm-ui.ps1), written here once; the shell must carry the same text in its constant.
$expectedTitle='Bitworks FastLLM (Preview)'
function Get-TitleProblems([string]$ShellText){
    $problems=New-Object System.Collections.ArrayList
    $parsed=Get-Parsed $ShellText
    if($parsed.ErrorCount -gt 0){[void]$problems.Add('The shell script does not parse.');return $problems.ToArray()}
    $ast=$parsed.Ast
    $consts=@($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and ([string]$n.Left.VariablePath.UserPath) -ieq 'script:FastLlmUiFluentWindowTitle'},$true))
    if($consts.Count -ne 1){[void]$problems.Add("The shell sets the title constant $($consts.Count) times instead of once.")}
    else{
        $value=$consts[0].Right
        $inner=$null
        if($value -is [System.Management.Automation.Language.CommandExpressionAst]){$inner=$value.Expression}
        if($inner -is [System.Management.Automation.Language.StringConstantExpressionAst]){
            if([string]$inner.Value -cne $expectedTitle){[void]$problems.Add("The title constant is '$([string]$inner.Value)', not the expected text.")}
        }
        else{[void]$problems.Add('The title constant is not a plain string.')}
    }
    $init=@($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Initialize-FastLlmUiFluentShell'},$true))
    if($init.Count -ne 1){[void]$problems.Add('Initialize-FastLlmUiFluentShell is not defined exactly once.');return $problems.ToArray()}
    $titles=@($init[0].FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and ([string]$n.Left.VariablePath.UserPath) -ceq 'windowTitle'},$true))
    if($titles.Count -ne 1){[void]$problems.Add("The shell sets windowTitle $($titles.Count) times instead of once.")}
    else{
        $rhs=($titles[0].Right.Extent.Text -replace '\s','') -replace '^\[string\]',''
        if($rhs -cne '$script:FastLlmUiFluentWindowTitle'){[void]$problems.Add("The shell takes windowTitle from '$($titles[0].Right.Extent.Text)', not from the constant.")}
    }
    $classicReads=@($init[0].FindAll({param($n) $n -is [System.Management.Automation.Language.MemberExpressionAst] -and $n.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and ([string]$n.Expression.VariablePath.UserPath) -ceq 'classicForm' -and [string]$n.Member.Extent.Text -ceq 'Text'},$true))
    if($classicReads.Count -ne 0){[void]$problems.Add('The shell still reads the classic form Text.')}
    return $problems.ToArray()
}
$shellText=Read-SourceText 'src/FastLlm.UiFluentShell.ps1'
$titleProblems=@(Get-TitleProblems $shellText)
Check ($titleProblems.Count -eq 0) ('The shell takes the window title from its constant, which holds the expected text: '+($titleProblems -join ' | '))
$oldShell=$shellText.Replace('$windowTitle = [string] $script:FastLlmUiFluentWindowTitle','$windowTitle = [string] $classicForm.Text')
Check ($oldShell -cne $shellText) 'The classic-title mutant changes the shell text.'
$found=@(Get-TitleProblems $oldShell)
Check ($found.Count -ge 1) 'mutation check: a shell that reads the title from the classic form again fails.'
$driftShell=$shellText.Replace("= 'Bitworks FastLLM (Preview)'","= 'Bitworks FastLLM (Beta)'")
Check ($driftShell -cne $shellText) 'The drifted-constant mutant changes the shell text.'
$found=@(Get-TitleProblems $driftShell)
Check ($found.Count -eq 1) 'mutation check: a constant that drifts from the expected text fails.'
$twiceShell=$shellText.Replace("`$script:FastLlmUiFluentWindowTitle = 'Bitworks FastLLM (Preview)'","`$script:FastLlmUiFluentWindowTitle = 'Bitworks FastLLM (Preview)'`n`$script:FastLlmUiFluentWindowTitle = 'Other'")
$found=@(Get-TitleProblems $twiceShell)
Check ($found.Count -ge 1) 'mutation check: a second assignment of the constant fails.'
Check (@(Get-TitleProblems $shellText).Count -eq 0) 'control: the unmodified shell passes the title check.'


Write-Host "ui-fluent-keeplist-tests: $checks checks passed."
