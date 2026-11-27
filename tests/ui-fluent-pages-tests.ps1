#requires -Version 5.1
# Windows-only checks of the Fluent window pages (Tools, Connect and the page host) in the real shell.
# Like ui-fluent-shell-tests, one dispatcher loop is driven by a step timer: step P0 starts the real shell and enters its Dispatcher.Run,
# and every later step runs from the 50 ms step timer INSIDE that nested frame. The shared helpers are in helpers/UiFluentShellHarness.ps1.
# Each check prints PASS or FAIL with a stable name; the suite ends with "N checks passed" and exits non-zero on any FAIL.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$root = Split-Path $PSScriptRoot -Parent

# ======================================================================================================================
# PR 4a Task 7 (T5): the dialog call-site table, pinned on every platform (this part runs before the Windows-only skip below).
# The table is the hand-copied box key table of the plan's Global Constraints (never derived from the product's key plan), one row per classic ShowUiMessageBox
# call site. It is checked against the classic AST (the arguments of every call), against Get-FastLlmUiDialogKeyPlan, and against the two forms' key targets.
# ======================================================================================================================
$script:boxPinPass = 0
$script:boxPinFail = 0
function Check-BoxPin([bool]$Condition, [string]$Name, [string]$Detail = '') {
    if ($Condition) { $script:boxPinPass++; Write-Host "PASS: $Name" }
    else { $script:boxPinFail++; Write-Host "FAIL: $Name -- $Detail" }
}

# One row per routed call site: Id (the step's name for it), Site (the enclosing function, then the event handler it is wired in, as 'function|handler'),
# the box arguments as the classic call passes them (no default argument means MessageBox's own Button1; no icon means None; no buttons means OK).
function Get-PagesBoxTable {
    return @(
        @{ Id = 'link-vc';        Site = '|$vc.Add_LinkClicked';                        Caption = 'Open prerequisite page';              Buttons = 'OK';       Icon = 'Warning';     Default = 'Button1' },
        @{ Id = 'link-amd';       Site = '|$amd.Add_LinkClicked';                       Caption = 'Open AMD page';                       Buttons = 'OK';       Icon = 'Warning';     Default = 'Button1' },
        @{ Id = 'link-results';   Site = '|$resultsLink.Add_LinkClicked';               Caption = 'Open results page';                   Buttons = 'OK';       Icon = 'Warning';     Default = 'Button1' },
        @{ Id = 'link-bar';       Site = '|$barLink.Add_LinkClicked';                   Caption = 'Open Resizable BAR page';             Buttons = 'OK';       Icon = 'Warning';     Default = 'Button1' },
        @{ Id = 'link-release';   Site = '|$bannerNotes.Add_LinkClicked';               Caption = 'Open release page';                   Buttons = 'OK';       Icon = 'Warning';     Default = 'Button1' },
        @{ Id = 'experimental';   Site = '|$experimentalBox.Add_CheckedChanged';        Caption = 'Experimental community components';  Buttons = 'YesNo';     Icon = 'Warning';     Default = 'Button2' },
        @{ Id = 'license-setting'; Site = 'ShowLicenseSettingConfirm|$link.Add_LinkClicked'; Caption = 'Open license page';            Buttons = 'OK';       Icon = 'Warning';     Default = 'Button1'
           Link = $true; FluentFn = 'Show-FastLlmUiFluentLicenseSettingConfirm'; ErrorKey = 'LicenseLinkError'; ErrorText = 'Unable to open the license page. Check your default browser. Nothing was changed.' },
        @{ Id = 'newkey-ask';     Site = 'NewUiApiKey|';                                Caption = 'Create a new key';                    Buttons = 'YesNo';     Icon = 'Question';    Default = 'Button1'; D2 = $true },
        @{ Id = 'newkey-done';    Site = 'NewUiApiKey|';                                Caption = 'Create a new key';                    Buttons = 'OK';       Icon = 'Information'; Default = 'Button1' },
        @{ Id = 'remove-component'; Site = 'RemoveComponentFromWindow|';                Caption = 'Remove component';                    Buttons = 'YesNo';     Icon = 'Question';    Default = 'Button2' },
        @{ Id = 'remove-model';   Site = 'RemoveModelFromWindow|';                      Caption = 'Remove model';                        Buttons = 'YesNo';     Icon = 'Question';    Default = 'Button2' },
        @{ Id = 'remove-leftovers'; Site = 'RemoveLeftoversFromWindow|';                Caption = 'Remove leftover partial downloads';   Buttons = 'YesNo';     Icon = 'Question';    Default = 'Button2' },
        @{ Id = 'bundle-list';    Site = 'ContinueSupportBundle|';                      Caption = 'Save support bundle';                 Buttons = 'OKCancel'; Icon = 'Information'; Default = 'Button1' },
        @{ Id = 'bundle-exists';  Site = 'ContinueSupportBundle|';                      Caption = 'Save support bundle';                 Buttons = 'OK';       Icon = 'None';        Default = 'Button1' },
        @{ Id = 'license-consent'; Site = 'ShowComponentConsent|$link.Add_LinkClicked'; Caption = 'Open license page';                   Buttons = 'OK';       Icon = 'Warning';     Default = 'Button1'
           Link = $true; FluentFn = 'Show-FastLlmUiFluentComponentConsent'; ErrorKey = 'ComponentLinkError'; ErrorText = 'Unable to open the license page. Check your default browser. Nothing was downloaded.' },
        @{ Id = 'update';         Site = 'InvokeUiUpdate|';                             Caption = 'Update FastLLM';                      Buttons = 'YesNo';     Icon = 'Question';    Default = 'Button2' },
        @{ Id = 'reinstall';      Site = 'InvokeUiReinstall|';                          Caption = 'Reinstall previous version';          Buttons = 'YesNo';     Icon = 'Question';    Default = 'Button2' },
        @{ Id = 'close';          Site = '|$form.Add_FormClosing';                      Caption = 'Close FastLLM';                       Buttons = 'YesNo';     Icon = 'Question';    Default = 'Button1'; D2 = $true }
    )
}

# What Enter, Escape and the close box do for a box kind and default (the plan's box key table, copied by hand). Escape '' means the box stays open; XEnabled false means
# the close box is refused. Focus is the id of the button that holds the first focus (the Enter target).
function Get-PagesBoxExpect([string]$Buttons, [string]$Default) {
    if ($Buttons -ceq 'OK') { return @{ Enter = 'OK'; Escape = 'OK'; XEnabled = $true; X = 'OK'; Focus = 'OK' } }
    if ($Buttons -ceq 'OKCancel') {
        $enter = 'OK'; if ($Default -ceq 'Button2') { $enter = 'Cancel' }
        return @{ Enter = $enter; Escape = 'Cancel'; XEnabled = $true; X = 'Cancel'; Focus = $enter }
    }
    $yn = 'Yes'; if ($Default -ceq 'Button2') { $yn = 'No' }
    return @{ Enter = $yn; Escape = ''; XEnabled = $false; X = ''; Focus = $yn }
}

# Every classic ShowUiMessageBox call of a file: the site, the caption, the buttons, the icon and the default button, as the call writes them.
function Get-PagesClassicBoxCalls([string]$Path) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    $calls = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'ShowUiMessageBox' }, $true))
    $out = New-Object System.Collections.ArrayList
    foreach ($c in $calls) {
        $fn = ''; $handler = ''
        $up = $c.Parent
        while ($null -ne $up) {
            if ($fn -eq '' -and $up -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $fn = [string]$up.Name }
            if ($handler -eq '' -and $up -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and ([string]$up.Member.Extent.Text) -like 'Add_*') { $handler = [string]$up.Expression.Extent.Text + '.' + [string]$up.Member.Extent.Text }
            $up = $up.Parent
        }
        $args2 = @($c.CommandElements | Select-Object -Skip 1)
        $vals = New-Object System.Collections.ArrayList
        foreach ($a in $args2) {
            if ($a -is [System.Management.Automation.Language.StringConstantExpressionAst]) { [void]$vals.Add([string]$a.Value) }
            elseif ([string]$a.Extent.Text -match '::(\w+)\)*$') { [void]$vals.Add([string]$Matches[1]) }
            else { [void]$vals.Add('<expression>') }
        }
        $get = { param($i, $default) if ($vals.Count -gt $i) { return [string]$vals[$i] } else { return $default } }
        [void]$out.Add(@{ Site = ($fn + '|' + $handler); Text = (& $get 1 ''); Caption = (& $get 2 ''); Buttons = (& $get 3 'OK'); Icon = (& $get 4 'None'); Default = (& $get 5 'Button1'); Line = $c.Extent.StartLineNumber; Count = $args2.Count })
    }
    return $out.ToArray()
}

# The named arguments of one command, as the source text of each argument (a switch parameter has no argument).
function Get-PagesCommandNamedArgs($Command) {
    $p = @{}
    $els = @($Command.CommandElements | Select-Object -Skip 1)
    for ($i = 0; $i -lt $els.Count; $i++) {
        $e = $els[$i]
        if ($e -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
        if ($null -ne $e.Argument) { $p[[string]$e.ParameterName] = [string]$e.Argument.Extent.Text }
        elseif ($i + 1 -lt $els.Count) { $p[[string]$e.ParameterName] = [string]$els[$i + 1].Extent.Text; $i++ }
    }
    return $p
}

# The licence link-error box of the two licence dialogs, on the fluent side (the twin of the two classic ShowUiMessageBox calls in the link handlers).
# The link of both dialogs is built by New-FastLlmUiFluentConsentLink, which holds the one box call: through the invocation operator on the captured
# Show-FastLlmUiFluentMessageBox, with the caption the string table's LinkErrorCaption gives, the text each dialog passes, and named Buttons and Icon only
# (no DefaultButton, so the box's own default applies). Returns the list of problems (empty when the fluent source says what the row says).
# ConsentSource and DialogsSource are source texts so a mutant can be a changed copy; Text is the merged string table (key to literal).
function Get-PagesFluentLinkBoxProblems([string]$ConsentSource, [string]$DialogsSource, $Text, $Row) {
    $problems = New-Object System.Collections.ArrayList
    $consentAst = [System.Management.Automation.Language.Parser]::ParseInput($ConsentSource, [ref]$null, [ref]$null)
    $dialogsAst = [System.Management.Automation.Language.Parser]::ParseInput($DialogsSource, [ref]$null, [ref]$null)
    $helper = @($consentAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'New-FastLlmUiFluentConsentLink' }, $true))
    if ($helper.Count -ne 1) { [void]$problems.Add("New-FastLlmUiFluentConsentLink found $($helper.Count) times"); return $problems.ToArray() }
    $boxCalls = @($helper[0].FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand -and [string]$n.CommandElements[0].Extent.Text -ceq '$messageBox' }, $true))
    if ($boxCalls.Count -ne 1) { [void]$problems.Add("the link helper has $($boxCalls.Count) box calls, expected 1"); return $problems.ToArray() }
    $named = Get-PagesCommandNamedArgs $boxCalls[0]
    if (-not ($named.ContainsKey('Buttons') -and (ConvertTo-PagesPlainText ([string]$named['Buttons'])) -ceq [string]$Row.Buttons)) { [void]$problems.Add("the box buttons are '$($named['Buttons'])', expected '$($Row.Buttons)'") }
    if (-not ($named.ContainsKey('Icon') -and (ConvertTo-PagesPlainText ([string]$named['Icon'])) -ceq [string]$Row.Icon)) { [void]$problems.Add("the box icon is '$($named['Icon'])', expected '$($Row.Icon)'") }
    if ($named.ContainsKey('DefaultButton')) { [void]$problems.Add("the box call names a DefaultButton ($($named['DefaultButton'])), expected the box's own default $($Row.Default)") }
    if (-not ($named.ContainsKey('Caption') -and [string]$named['Caption'] -ceq '$errorCaption')) { [void]$problems.Add("the box caption argument is '$($named['Caption'])', expected `$errorCaption") }
    if (-not ($named.ContainsKey('Text') -and [string]$named['Text'] -ceq '$ErrorText')) { [void]$problems.Add("the box text argument is '$($named['Text'])', expected `$ErrorText") }
    if ((Get-PagesAssignedText $helper[0] '$errorCaption') -cne '[string] $t.LinkErrorCaption') { [void]$problems.Add("`$errorCaption is '$(Get-PagesAssignedText $helper[0] '$errorCaption')', expected the LinkErrorCaption string") }
    if ((Get-PagesAssignedText $helper[0] '$messageBox') -cne '${function:Show-FastLlmUiFluentMessageBox}') { [void]$problems.Add("`$messageBox is '$(Get-PagesAssignedText $helper[0] '$messageBox')', expected the fluent message box function") }
    if (-not ($Text.ContainsKey('LinkErrorCaption') -and [string]$Text['LinkErrorCaption'] -ceq [string]$Row.Caption)) { [void]$problems.Add("the LinkErrorCaption string is '$($Text['LinkErrorCaption'])', expected '$($Row.Caption)'") }
    if (-not ($Text.ContainsKey([string]$Row.ErrorKey) -and [string]$Text[[string]$Row.ErrorKey] -ceq [string]$Row.ErrorText)) { [void]$problems.Add("the $($Row.ErrorKey) string is '$($Text[[string]$Row.ErrorKey])', expected '$($Row.ErrorText)'") }
    # the dialog builds each link through the helper with its own error text
    $dialogFn = @($consentAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq [string]$Row.FluentFn }, $true))
    if ($dialogFn.Count -ne 1) { [void]$problems.Add("$($Row.FluentFn) found $($dialogFn.Count) times"); return $problems.ToArray() }
    $linkCalls = @($dialogFn[0].FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'New-FastLlmUiFluentConsentLink' }, $true))
    if ($linkCalls.Count -ne 1) { [void]$problems.Add("$($Row.FluentFn) builds its links with $($linkCalls.Count) helper calls, expected 1") }
    else {
        $linkNamed = Get-PagesCommandNamedArgs $linkCalls[0]
        $wantErr = '([string] $t.' + [string]$Row.ErrorKey + ')'
        if (-not ($linkNamed.ContainsKey('ErrorText') -and [string]$linkNamed['ErrorText'] -ceq $wantErr)) { [void]$problems.Add("$($Row.FluentFn) passes ErrorText '$($linkNamed['ErrorText'])', expected '$wantErr'") }
    }
    # the box's own default button
    $boxFn = @($dialogsAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Show-FastLlmUiFluentMessageBox' }, $true))
    if ($boxFn.Count -ne 1) { [void]$problems.Add("Show-FastLlmUiFluentMessageBox found $($boxFn.Count) times") }
    else {
        $defaultParam = @($boxFn[0].Body.ParamBlock.Parameters | Where-Object { [string]$_.Name.VariablePath.UserPath -ceq 'DefaultButton' })
        $defaultText = ''; if ($defaultParam.Count -eq 1 -and $null -ne $defaultParam[0].DefaultValue) { $defaultText = [string]$defaultParam[0].DefaultValue.Extent.Text }
        if ($defaultText -cne "'$($Row.Default)'") { [void]$problems.Add("the box's DefaultButton parameter defaults to $defaultText, expected '$($Row.Default)'") }
    }
    return $problems.ToArray()
}

function Invoke-PagesBoxTablePins([string]$UiPath) {
    $table = @(Get-PagesBoxTable)
    $calls = @(Get-PagesClassicBoxCalls $UiPath)
    # The call sites that are shared code and stay once the classic dialogs are gone: every call outside the two licence dialogs' link handlers (16 rows).
    $keptTable = @($table | Where-Object { -not $_.ContainsKey('Link') })
    $keptCalls = @($calls | Where-Object { -not ([string]$_['Site']).StartsWith('ShowLicenseSettingConfirm|') -and -not ([string]$_['Site']).StartsWith('ShowComponentConsent|') })
    Check-BoxPin ($keptCalls.Count -eq 16) 'P41 pin: fast-llm-ui.ps1 has exactly 16 ShowUiMessageBox call sites outside the two licence dialogs' "found=$($keptCalls.Count) expected=16"
    Check-BoxPin ($keptTable.Count -eq 16) 'P41 pin: the T5 table has 16 rows for them' "rows=$($keptTable.Count) expected=16"
    Check-BoxPin (@($table | Where-Object { $_.ContainsKey('Link') }).Count -eq 2) 'P41 pin: the T5 table has the two licence link rows (license-setting, license-consent)' ''
    # 5b-delete-begin
    Check-BoxPin ($calls.Count -eq 18) 'P41 pin: the classic file has exactly 18 ShowUiMessageBox call sites' "found=$($calls.Count) expected=18"
    Check-BoxPin ($table.Count -eq 18) 'P41 pin: the T5 table has one row per call site (18)' "rows=$($table.Count) expected=18"
    foreach ($row in @($table | Where-Object { $_.ContainsKey('Link') })) {
        $match = @($calls | Where-Object { [string]$_['Site'] -ceq [string]$row.Site -and [string]$_['Caption'] -ceq [string]$row.Caption -and [string]$_['Buttons'] -ceq [string]$row.Buttons })
        Check-BoxPin ($match.Count -eq 1) "P41 pin: row $($row.Id) matches exactly one classic call (site, caption, buttons)" "site='$($row.Site)' caption='$($row.Caption)' buttons=$($row.Buttons) matches=$($match.Count)"
        if ($match.Count -ne 1) { continue }
        Check-BoxPin ([string]$match[0]['Icon'] -ceq [string]$row.Icon -and [string]$match[0]['Default'] -ceq [string]$row.Default) "P41 pin: row $($row.Id) icon and default button are the classic call's" "classic icon=$($match[0]['Icon']) default=$($match[0]['Default']) table icon=$($row.Icon) default=$($row.Default) (line $($match[0]['Line']))"
        $classicText = [string]$match[0]['Text']
        Check-BoxPin ($classicText -ceq [string]$row.ErrorText) "P41 pin: row $($row.Id) the classic call's text is the literal the fluent twin pins" "classic text='$classicText' literal='$($row.ErrorText)'"
    }
    # 5b-delete-end
    foreach ($row in $keptTable) {
        $match = @($keptCalls | Where-Object { [string]$_['Site'] -ceq [string]$row.Site -and [string]$_['Caption'] -ceq [string]$row.Caption -and [string]$_['Buttons'] -ceq [string]$row.Buttons })
        Check-BoxPin ($match.Count -eq 1) "P41 pin: row $($row.Id) matches exactly one classic call (site, caption, buttons)" "site='$($row.Site)' caption='$($row.Caption)' buttons=$($row.Buttons) matches=$($match.Count)"
        if ($match.Count -ne 1) { continue }
        Check-BoxPin ([string]$match[0]['Icon'] -ceq [string]$row.Icon -and [string]$match[0]['Default'] -ceq [string]$row.Default) "P41 pin: row $($row.Id) icon and default button are the classic call's" "classic icon=$($match[0]['Icon']) default=$($match[0]['Default']) table icon=$($row.Icon) default=$($row.Default) (line $($match[0]['Line']))"
    }
    # every kept call is in the table (a new call site fails here)
    foreach ($c in $keptCalls) {
        $hit = @($table | Where-Object { [string]$_.Site -ceq [string]$c['Site'] -and [string]$_.Caption -ceq [string]$c['Caption'] -and [string]$_.Buttons -ceq [string]$c['Buttons'] })
        Check-BoxPin ($hit.Count -eq 1) "P41 pin: the classic call at line $($c['Line']) ('$($c['Caption'])') is in the T5 table" "site='$($c['Site'])' buttons=$($c['Buttons']) rows=$($hit.Count)"
    }
    # 5b-delete-begin
    foreach ($c in @($calls | Where-Object { ([string]$_['Site']).StartsWith('ShowLicenseSettingConfirm|') -or ([string]$_['Site']).StartsWith('ShowComponentConsent|') })) {
        $hit = @($table | Where-Object { [string]$_.Site -ceq [string]$c['Site'] -and [string]$_.Caption -ceq [string]$c['Caption'] -and [string]$_.Buttons -ceq [string]$c['Buttons'] })
        Check-BoxPin ($hit.Count -eq 1) "P41 pin: the classic call at line $($c['Line']) ('$($c['Caption'])') is in the T5 table" "site='$($c['Site'])' buttons=$($c['Buttons']) rows=$($hit.Count)"
    }
    # 5b-delete-end
    # the two licence link-error boxes, on the fluent side: one box call in the shared link helper, the caption, the text of each dialog, the box's own default
    $consentSource = [System.IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.UiFluentConsent.ps1'))
    $dialogsSource = [System.IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.UiFluentDialogs.ps1'))
    $linkText = Get-PagesFluentTextTable $root
    foreach ($row in @($table | Where-Object { $_.ContainsKey('Link') })) {
        $problems = @(Get-PagesFluentLinkBoxProblems $consentSource $dialogsSource $linkText $row)
        Check-BoxPin ($problems.Count -eq 0) "P41 pin: row $($row.Id) the fluent link-error box is one box call: caption '$($row.Caption)', $($row.Buttons), icon $($row.Icon), the box's default $($row.Default), the text literal" ($problems -join '; ')
    }
    # mutants: each regression of the fluent link box is found, and the unchanged copy is clean
    $linkRow = @($table | Where-Object { $_.Id -ceq 'license-setting' })[0]
    $consentRow = @($table | Where-Object { $_.Id -ceq 'license-consent' })[0]
    $badText = @{}; foreach ($k in @($linkText.Keys)) { $badText[$k] = $linkText[$k] }; $badText['LinkErrorCaption'] = 'Open the license page'
    $badText2 = @{}; foreach ($k in @($linkText.Keys)) { $badText2[$k] = $linkText[$k] }; $badText2['ComponentLinkError'] = 'Unable to open the license page.'
    Check-BoxPin (@(Get-PagesFluentLinkBoxProblems $consentSource $dialogsSource $linkText $linkRow).Count -eq 0 -and @(Get-PagesFluentLinkBoxProblems $consentSource $dialogsSource $linkText $consentRow).Count -eq 0) 'P41 mutation control: the unchanged fluent source passes the link-error box pin for both rows' ''
    Check-BoxPin (@(Get-PagesFluentLinkBoxProblems $consentSource.Replace("-Icon 'Warning'", "-Icon 'Information'") $dialogsSource $linkText $linkRow).Count -ge 1) 'P41 mutation check: a link-error box with another icon is flagged' ''
    Check-BoxPin (@(Get-PagesFluentLinkBoxProblems $consentSource.Replace("-Buttons 'OK' -Icon 'Warning'", "-Buttons 'YesNo' -Icon 'Warning'") $dialogsSource $linkText $linkRow).Count -ge 1) 'P41 mutation check: a link-error box with other buttons is flagged' ''
    Check-BoxPin (@(Get-PagesFluentLinkBoxProblems $consentSource.Replace("-Buttons 'OK' -Icon 'Warning'", "-Buttons 'OK' -Icon 'Warning' -DefaultButton 'Button2'") $dialogsSource $linkText $linkRow).Count -ge 1) 'P41 mutation check: a link-error box that names another default button is flagged' ''
    Check-BoxPin (@(Get-PagesFluentLinkBoxProblems $consentSource $dialogsSource.Replace("[string] `$DefaultButton = 'Button1'", "[string] `$DefaultButton = 'Button2'") $linkText $linkRow).Count -ge 1) 'P41 mutation check: a message box whose own default is Button2 is flagged' ''
    Check-BoxPin (@(Get-PagesFluentLinkBoxProblems $consentSource $dialogsSource $badText $linkRow).Count -ge 1) 'P41 mutation check: a changed link-error caption is flagged' ''
    Check-BoxPin (@(Get-PagesFluentLinkBoxProblems $consentSource $dialogsSource $badText2 $consentRow).Count -ge 1) 'P41 mutation check: a changed component link-error text is flagged' ''
    Check-BoxPin (@(Get-PagesFluentLinkBoxProblems $consentSource.Replace('-ErrorText ([string] $t.LicenseLinkError)', '-ErrorText ([string] $t.ComponentLinkError)') $dialogsSource $linkText $linkRow).Count -ge 1) 'P41 mutation check: the licence setting dialog passing the component error text is flagged' ''
    Check-BoxPin (@(Get-PagesFluentLinkBoxProblems ($consentSource + "`nfunction New-FastLlmUiFluentConsentLink { }`n") $dialogsSource $linkText $linkRow).Count -ge 1) 'P41 mutation check: a second link helper is flagged' ''
    Check-BoxPin (@(Get-PagesFluentLinkBoxProblems $consentSource.Replace('catch { $null = & $messageBox -Owner $Context[''Dialog'']', 'catch { $null = & $messageBox -Owner $Context[''Dialog''] -Text $ErrorText -Caption $errorCaption -Buttons ''OK'' -Icon ''Warning''; $null = & $messageBox -Owner $Context[''Dialog'']') $dialogsSource $linkText $linkRow).Count -ge 1) 'P41 mutation check: a second box call in the link helper is flagged' ''
    # the hand table against the product's key plan (read from the state file by the parser, nothing else is run)
    $statePath = Join-Path $root 'src/FastLlm.UiState.ps1'
    $stateAst = [System.Management.Automation.Language.Parser]::ParseFile($statePath, [ref]$null, [ref]$null)
    $planDef = $stateAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-FastLlmUiDialogKeyPlan' }, $true)
    Check-BoxPin ($null -ne $planDef) 'P41 pin: Get-FastLlmUiDialogKeyPlan was found in UiState' ''
    if ($null -ne $planDef) {
        . ([scriptblock]::Create([string]$planDef.Extent.Text))
        foreach ($row in $table) {
            $exp = Get-PagesBoxExpect $row.Buttons $row.Default
            $plan = Get-FastLlmUiDialogKeyPlan -Buttons $row.Buttons -DefaultButton $row.Default
            $ok = ([string]$plan['enter'] -ceq [string]$exp.Enter -and [string]$plan['escape'] -ceq [string]$exp.Escape -and [bool]$plan['closeEnabled'] -eq [bool]$exp.XEnabled -and [string]$plan['close'] -ceq [string]$exp.X)
            Check-BoxPin $ok "P41 pin: row $($row.Id) the key plan gives the table's Enter, Escape and close box" "plan enter='$($plan['enter'])' escape='$($plan['escape'])' close='$($plan['close'])' closeEnabled=$($plan['closeEnabled']) / table enter='$($exp.Enter)' escape='$($exp.Escape)' close='$($exp.X)' closeEnabled=$($exp.XEnabled)"
        }
    }
    # D2 parity (the lead's ruling): Enter answers Yes for Create a new key and Close FastLLM until the wording PR changes it in both windows
    foreach ($id in 'newkey-ask', 'close') {
        $row = @($table | Where-Object { $_.Id -ceq $id })[0]
        $exp = Get-PagesBoxExpect $row.Buttons $row.Default
        Check-BoxPin ([string]$exp.Enter -ceq 'Yes' -and [string]$row.Default -ceq 'Button1') "P41 pin: D2 parity, Enter is Yes for $id (the classic call has no default argument)" "enter='$($exp.Enter)' default=$($row.Default)"
    }
    # the two forms' key targets, from the fluent dialog file: side result Enter and Escape are Close; driver guidance has no Enter target and Escape is Close
    $dlgPath = Join-Path $root 'src/FastLlm.UiFluentDialogs.ps1'
    $dlgAst = [System.Management.Automation.Language.Parser]::ParseFile($dlgPath, [ref]$null, [ref]$null)
    $sideDef = $dlgAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Show-FastLlmUiFluentSideResult' }, $true)
    $guideDef = $dlgAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Show-FastLlmUiFluentDriverGuidance' }, $true)
    Check-BoxPin ($null -ne $sideDef -and $sideDef.Extent.Text.Contains("-Enter 'Close' -Escape 'Close'") -and -not $sideDef.Extent.Text.Contains('-CloseEnabled $false')) 'P41 pin: the side result answers Enter and Escape with Close and keeps its close box' ''
    Check-BoxPin ($null -ne $guideDef -and $guideDef.Extent.Text.Contains("-Enter '' -Escape 'Close'") -and -not $guideDef.Extent.Text.Contains('-CloseEnabled $false')) 'P41 pin: the driver guidance has no Enter target, answers Escape with Close and keeps its close box' ''
    # the step list of this file runs P40 and P41
    $selfText = [System.IO.File]::ReadAllText($PSCommandPath)
    $stepsBlock = [regex]::Match($selfText, '(?s)\$script:steps = @\((.*?)\r?\n\)')
    Check-BoxPin ($stepsBlock.Success -and $stepsBlock.Groups[1].Value.Contains("'Invoke-P40-SignInNotice'") -and $stepsBlock.Groups[1].Value.Contains("'Invoke-P41-DialogKeys'")) 'P41 pin: the step list names Invoke-P40-SignInNotice and Invoke-P41-DialogKeys' "stepsBlockFound=$($stepsBlock.Success)"
    # CI round 1: the suite loads the prerequisite file, which defines the helper the P41 loaded-check names (the Close FastLLM handler's guard)
    Check-BoxPin ($selfText.Contains(". (Join-Path `$root 'src/FastLlm.UiPrerequisite.ps1')") -and ([System.IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.UiPrerequisite.ps1'))).Contains('function Test-FastLlmUiVcActionAllowed')) 'P41 pin: the suite dot-sources the file that defines Test-FastLlmUiVcActionAllowed'
}

# ======================================================================================================================
# PR 4b Task B3 (P42): the seven fluent dialogs of 4b (licence setting, component consent, exact model consent, VC++ review, setup check, recipe chooser, the save prompt),
# pinned on every platform. The hand table below is checked against the classic AST (the form's AcceptButton, CancelButton and every button's DialogResult and caption),
# against the fluent function (its New-FastLlmUiFluentDialog -Enter and -Escape ids, its button table and the string table the captions come from), and against the
# reveal and tray rules. The save prompt has no classic form in this file (the 3c WinForms prompt it replaces is gone), so its row is pinned to the ruled targets only.
# ======================================================================================================================
function Get-PagesDialogTable {
    return @(
        @{ Id = 'license-setting'; Classic = 'ShowLicenseSettingConfirm'; Fluent = 'Show-FastLlmUiFluentLicenseSettingConfirm'; File = 'src/FastLlm.UiFluentConsent.ps1'; Title = 'Install engine components automatically'; Reveal = $false
           EnterId = 'Cancel'; EscapeId = 'Cancel'; ResultKind = 'bool'
           Buttons = @(@{ Id = 'Accept'; Text = 'I accept these licenses'; DR = 'OK'; Result = 'true' }, @{ Id = 'Cancel'; Text = 'Cancel'; DR = 'Cancel'; Result = 'false' }) },
        @{ Id = 'component-consent'; Classic = 'ShowComponentConsent'; Fluent = 'Show-FastLlmUiFluentComponentConsent'; File = 'src/FastLlm.UiFluentConsent.ps1'; Title = 'Install engine components'; Reveal = $true
           EnterId = 'Cancel'; EscapeId = 'Cancel'; ResultKind = 'bool'
           Buttons = @(@{ Id = 'Install'; Text = 'Install'; DR = 'OK'; Result = 'true' }, @{ Id = 'Cancel'; Text = 'Cancel'; DR = 'Cancel'; Result = 'false' }) },
        @{ Id = 'model-consent'; Classic = 'ShowExactModelConsent'; Fluent = 'Show-FastLlmUiFluentExactModelConsent'; File = 'src/FastLlm.UiFluentConsent.ps1'; Title = 'Review exact model license and artifact'; Reveal = $true
           EnterId = 'Cancel'; EscapeId = 'Cancel'; ResultKind = 'bool'
           Buttons = @(@{ Id = 'Accept'; Text = 'Accept license && download'; DR = 'OK'; Result = 'true' }, @{ Id = 'Cancel'; Text = 'Cancel'; DR = 'Cancel'; Result = 'false' }) },
        @{ Id = 'vc-review'; Classic = 'ShowVcInstallReview'; Fluent = 'Show-FastLlmUiFluentVcInstallReview'; File = 'src/FastLlm.UiFluentConsent.ps1'; Title = 'Review Microsoft VC++ package and installation'; Reveal = $true
           EnterId = 'Later'; EscapeId = 'Later'; ResultKind = 'bool'
           Buttons = @(@{ Id = 'Install'; Text = 'Install Microsoft runtime'; DR = 'OK'; Result = 'true' }, @{ Id = 'Later'; Text = 'Do later'; DR = 'Cancel'; Result = 'false' }) },
        @{ Id = 'setup-check'; Classic = 'ShowSetupAttention'; Fluent = 'Show-FastLlmUiFluentSetupAttention'; File = 'src/FastLlm.UiFluentDialogs.ps1'; Title = 'FastLLM setup check'; Reveal = $true
           EnterId = 'Recheck'; EscapeId = 'Later'; ResultKind = 'map'
           Buttons = @(@{ Id = 'Recheck'; Text = 'Recheck'; DR = 'Retry'; Result = 'recheck' }, @{ Id = 'Prepare'; Text = 'Prepare && review VC++'; DR = 'Yes'; Result = 'prepare' }, @{ Id = 'Later'; Text = 'Do later'; DR = 'Cancel'; Result = 'defer' }) },
        # the chooser's Enter target is Choose, but only while Choose is enabled: the fluent call starts with no Enter target ('') and the selection handler sets 'Choose'
        @{ Id = 'recipe-chooser'; Classic = 'ShowRecipeChooser'; Fluent = 'Show-FastLlmUiFluentRecipeChooser'; File = 'src/FastLlm.UiFluentDialogs.ps1'; Title = 'Choose another setup'; Reveal = $true; EnterDynamic = $true
           EnterId = 'Choose'; EscapeId = 'Cancel'; ResultKind = 'picked'
           Buttons = @(@{ Id = 'Choose'; Text = 'Choose'; DR = 'OK'; Result = 'picked' }, @{ Id = 'Cancel'; Text = 'Cancel'; DR = 'Cancel'; Result = 'null' }) },
        @{ Id = 'save-prompt'; Classic = ''; Fluent = 'Show-FastLlmUiFluentSavePrompt'; File = 'src/FastLlm.UiFluentSettings.ps1'; Title = 'FastLLM settings'; Reveal = $false
           EnterId = 'Cancel'; EscapeId = 'Cancel'; ResultKind = 'map'
           Buttons = @(@{ Id = 'Save'; Text = 'Save'; DR = ''; Result = 'save' }, @{ Id = 'DontSave'; Text = "Don't save"; DR = ''; Result = 'discard' }, @{ Id = 'Cancel'; Text = 'Cancel'; DR = ''; Result = 'cancel' }) }
    )
}

function Get-PagesFunctionAst([string]$Path, [string]$Name) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    $script:p42Want = $Name
    $found = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $script:p42Want }, $true))
    if ($found.Count -eq 1) { return $found[0] }
    return $null
}
function ConvertTo-PagesPlainText([string]$Text) {
    if ($Text -match "^'(.*)'$") { return $Matches[1].Replace("''", "'") }
    if ($Text -match '^"([^"$`]*)"$') { return $Matches[1] }
    return $Text
}
# The right side of the first assignment to $LeftText inside a function, as the text the source wrote ('' when there is none).
function Get-PagesAssignedText($FnAst, [string]$LeftText) {
    $script:p42Left = $LeftText
    $hit = @($FnAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq $script:p42Left }, $true))
    if ($hit.Count -eq 0) { return '' }
    return [string]$hit[0].Right.Extent.Text
}
function Get-PagesDialogResultName([string]$Text) {
    if ($Text -match '::(\w+)\s*$') { return [string]$Matches[1] }
    return ''
}
# The facts of a classic form: its title, the AcceptButton and CancelButton variables, and for every button caption its DialogResult.
function Get-PagesClassicFormFacts($FnAst) {
    $facts = @{ Title = (ConvertTo-PagesPlainText (Get-PagesAssignedText $FnAst '$dialog.Text')); AcceptVar = (Get-PagesAssignedText $FnAst '$dialog.AcceptButton'); CancelVar = (Get-PagesAssignedText $FnAst '$dialog.CancelButton'); Texts = @{}; Results = @{} }
    $assigns = @($FnAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))
    foreach ($a in $assigns) {
        $left = [string]$a.Left.Extent.Text
        if ($left -match '^\$(\w+)\.Text$') { $facts.Texts['$' + $Matches[1]] = (ConvertTo-PagesPlainText ([string]$a.Right.Extent.Text)) }
        elseif ($left -match '^\$(\w+)\.DialogResult$') { $facts.Results['$' + $Matches[1]] = (Get-PagesDialogResultName ([string]$a.Right.Extent.Text)) }
    }
    return $facts
}
# The named parameters of the one New-FastLlmUiFluentDialog call of a fluent function, as the source text of each argument.
function Get-PagesFluentDialogParams($FnAst) {
    $cmds = @($FnAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'New-FastLlmUiFluentDialog' }, $true))
    $p = @{ Count = $cmds.Count }
    if ($cmds.Count -ne 1) { return $p }
    $els = @($cmds[0].CommandElements | Select-Object -Skip 1)
    for ($i = 0; $i -lt $els.Count; $i++) {
        $e = $els[$i]
        if ($e -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
        if ($null -ne $e.Argument) { $p[[string]$e.ParameterName] = [string]$e.Argument.Extent.Text }
        elseif ($i + 1 -lt $els.Count) { $p[[string]$e.ParameterName] = [string]$els[$i + 1].Extent.Text; $i++ }
    }
    return $p
}
# The fluent button table of a function ($buttons = [ordered] @{ Id = [string] $t.Key; ... }) as id -> the string table key (or the member of the other table).
function Get-PagesFluentButtonKeys($FnAst) {
    $script:p42Left = '$buttons'
    $hit = @($FnAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq $script:p42Left }, $true))
    $out = [ordered]@{}
    if ($hit.Count -ne 1) { return $out }
    $hash = $hit[0].Right.Find({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)
    if ($null -eq $hash) { return $out }
    foreach ($kv in $hash.KeyValuePairs) {
        $id = [string]$kv.Item1.Value
        $valueText = [string]$kv.Item2.Extent.Text
        if ($valueText -match '\$[ts]\.(\w+)') { $out[$id] = [string]$Matches[1] } else { $out[$id] = '' }
    }
    return $out
}
# Every key of the two fluent string tables the dialog captions come from, with the literal (the plain string constants only).
function Get-PagesFluentTextTable([string]$Root) {
    $map = @{}
    foreach ($spec in @(@('src/FastLlm.UiFluentDialogs.ps1', '$script:FastLlmUiFluentDialogText'), @('src/FastLlm.UiFluentConsent.ps1', '$script:FastLlmUiFluentConsentText'))) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Root ([string]$spec[0])), [ref]$null, [ref]$null)
        $script:p42Left = [string]$spec[1]
        $assign = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq $script:p42Left }, $true))
        if ($assign.Count -ne 1) { continue }
        $hash = $assign[0].Right.Find({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)
        if ($null -eq $hash) { continue }
        foreach ($kv in $hash.KeyValuePairs) {
            $expr = $kv.Item2.PipelineElements[0].Expression
            if ($expr -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $map[[string]$kv.Item1.Value] = [string]$expr.Value }
        }
    }
    return $map
}

# 5b-delete-begin
# The classic half of one dialog row: the classic function's title, AcceptButton, CancelButton, every button's DialogResult and caption, reveal and close box, read from fast-llm-ui.ps1.
# Every statement is unconditional: a missing classic function fails the row.
function Invoke-PagesClassicDialogRowPins($row, [string]$UiPath) {
    $id = [string]$row.Id
    # the classic form
    $classicAst = Get-PagesFunctionAst $UiPath ([string]$row.Classic)
    Check-BoxPin ($null -ne $classicAst) "P42 pin: row $id the classic function $($row.Classic) is in fast-llm-ui.ps1 exactly once" ''
    if ($null -eq $classicAst) { return }
    $facts = Get-PagesClassicFormFacts $classicAst
    Check-BoxPin ([string]$facts.Title -ceq [string]$row.Title) "P42 pin: row $id the classic form's title is '$($row.Title)'" "classic title='$($facts.Title)'"
    $enterText = ''; $escapeText = ''
    if ($facts.Texts.ContainsKey([string]$facts.AcceptVar)) { $enterText = [string]$facts.Texts[[string]$facts.AcceptVar] }
    if ($facts.Texts.ContainsKey([string]$facts.CancelVar)) { $escapeText = [string]$facts.Texts[[string]$facts.CancelVar] }
    $wantEnterText = ''; $wantEscapeText = ''
    foreach ($b in @($row.Buttons)) { if ([string]$b.Id -ceq [string]$row.EnterId) { $wantEnterText = [string]$b.Text }; if ([string]$b.Id -ceq [string]$row.EscapeId) { $wantEscapeText = [string]$b.Text } }
    Check-BoxPin ($enterText -ceq $wantEnterText -and $enterText -cne '') "P42 pin: row $id the classic AcceptButton (Enter) is '$wantEnterText'" "AcceptButton=$($facts.AcceptVar) text='$enterText' expected='$wantEnterText'"
    Check-BoxPin ($escapeText -ceq $wantEscapeText -and $escapeText -cne '') "P42 pin: row $id the classic CancelButton (Escape and the close box) is '$wantEscapeText'" "CancelButton=$($facts.CancelVar) text='$escapeText' expected='$wantEscapeText'"
    foreach ($b in @($row.Buttons)) {
        $var = ''
        foreach ($k in @($facts.Texts.Keys)) { if ([string]$facts.Texts[$k] -ceq [string]$b.Text) { $var = [string]$k } }
        $dr = ''; if ($var -ne '' -and $facts.Results.ContainsKey($var)) { $dr = [string]$facts.Results[$var] }
        Check-BoxPin ($var -ne '' -and $dr -ceq [string]$b.DR) "P42 pin: row $id the classic button '$($b.Text)' has DialogResult $($b.DR)" "variable='$var' DialogResult='$dr' expected='$($b.DR)'"
    }
    Check-BoxPin (([bool]([string]$classicAst.Extent.Text).Contains('RevealUiForAction')) -eq [bool]$row.Reveal) "P42 pin: row $id the classic function reveals the window exactly when the table says ($($row.Reveal))" "classic reveal=$(([string]$classicAst.Extent.Text).Contains('RevealUiForAction')) expected=$($row.Reveal)"
    # the classic form's X is the CancelButton: the form has no ControlBox change and no FormClosing guard
    Check-BoxPin (-not ([string]$classicAst.Extent.Text).Contains('ControlBox') -and -not ([string]$classicAst.Extent.Text).Contains('Add_FormClosing')) "P42 pin: row $id the classic form keeps its close box (the X answers the CancelButton)" ''
    # the answer of every button, as the classic function returns it (the frozen Result column equals what the classic dialog answers for that DialogResult)
    $classicNoSpace = ([string]$classicAst.Extent.Text) -replace '\s', ''
    foreach ($b in @($row.Buttons)) {
        $wantResult = [string]$b.Result
        $classicSays = $false
        if ([string]$row.ResultKind -ceq 'bool') { $classicSays = ($classicNoSpace.Contains('$dialog.ShowDialog($form)-eq[Windows.Forms.DialogResult]::OK') -and $wantResult -ceq $(if ([string]$b.DR -ceq 'OK') { 'true' } else { 'false' })) }
        elseif ([string]$row.ResultKind -ceq 'picked') { $classicSays = ($classicNoSpace.Contains('-eq[Windows.Forms.DialogResult]::OK-and$list.SelectedItems.Count-eq1') -and $classicNoSpace.Contains('return$picked') -and $wantResult -ceq $(if ([string]$b.DR -ceq 'OK') { 'picked' } else { 'null' })) }
        else {
            if ($wantResult -ceq 'defer') { $classicSays = $classicNoSpace.Contains("return'defer'") -and [string]$b.DR -ceq 'Cancel' }
            else { $classicSays = $classicNoSpace.Contains("[Windows.Forms.DialogResult]::$($b.DR)") -and $classicNoSpace.Contains("return'$wantResult'") }
        }
        Check-BoxPin $classicSays "P42 pin: row $($row.Id) the classic dialog answers '$wantResult' for the button '$($b.Text)' (DialogResult $($b.DR))" "result kind=$($row.ResultKind) DialogResult='$($b.DR)' expected result='$wantResult'"
    }
}
# 5b-delete-end

# What a fluent dialog function answers for each of its buttons, read from the function's source (the twin of the classic DialogResult column), as id -> result text:
#   bool    : [bool] ($answer -ceq '<Id>') (the one button that answers true; every other button false)
#   map     : top-level statements `if ($answer -ceq '<Id>' [-and ...]) { return '<text>' }`, then a last `return '<text>'` for every other button
#   picked  : the chooser: Choose answers the picked row ('picked') when exactly one row is selected, every other button answers $null ('null')
# A button the source does not answer comes back as '(none)'.
function Get-PagesFluentButtonResults([string]$Source, [string]$FnName, [string]$Kind, [string[]]$Ids) {
    $out = @{}
    foreach ($id in $Ids) { $out[$id] = '(none)' }
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$null, [ref]$null)
    $script:p42ResultFn = $FnName
    $fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $script:p42ResultFn }, $true))
    if ($fn.Count -ne 1) { return $out }
    $text = ([string]$fn[0].Extent.Text) -replace '\s', ''
    if ($Kind -ceq 'bool') {
        $m = [regex]::Matches($text, "\[bool\]\(\`$answer-ceq'(\w+)'\)")
        if ($m.Count -ne 1) { return $out }
        foreach ($id in $Ids) { $out[$id] = $(if ($id -ceq [string]$m[0].Groups[1].Value) { 'true' } else { 'false' }) }
        return $out
    }
    if ($Kind -ceq 'picked') {
        if (-not ($text.Contains("if(`$answer-ceq'Choose'-and`$list.SelectedItems.Count-eq1)") -and $text.Contains('$picked=$null') -and $text.Contains('return$picked'))) { return $out }
        foreach ($id in $Ids) { $out[$id] = $(if ($id -ceq 'Choose') { 'picked' } else { 'null' }) }
        return $out
    }
    $map = @{}
    $default = ''
    $stmts = @($fn[0].Body.EndBlock.Statements)
    foreach ($st in $stmts) {
        if ($st -is [System.Management.Automation.Language.IfStatementAst] -and $st.Clauses.Count -eq 1) {
            $cond = ([string]$st.Clauses[0].Item1.Extent.Text) -replace '\s', ''
            $body = @($st.Clauses[0].Item2.Statements)
            if ($cond -match "^\`$answer-ceq'(\w+)'" -and $body.Count -eq 1 -and $body[0] -is [System.Management.Automation.Language.ReturnStatementAst]) { $map[[string]$Matches[1]] = (ConvertTo-PagesPlainText ([string]$body[0].Pipeline.Extent.Text)) }
        }
    }
    $last = $stmts[$stmts.Count - 1]
    if ($last -is [System.Management.Automation.Language.ReturnStatementAst]) { $default = (ConvertTo-PagesPlainText ([string]$last.Pipeline.Extent.Text)) }
    foreach ($id in $Ids) { $out[$id] = $(if ($map.ContainsKey($id)) { $map[$id] } elseif ($default -cne '') { $default } else { '(none)' }) }
    return $out
}
# The problems of one row's result column against a fluent source text (empty when every button answers what the row says).
function Get-PagesFluentResultProblems([string]$Source, $Row) {
    $problems = New-Object System.Collections.ArrayList
    $ids = @($Row.Buttons | ForEach-Object { [string]$_.Id })
    $got = Get-PagesFluentButtonResults $Source ([string]$Row.Fluent) ([string]$Row.ResultKind) $ids
    foreach ($b in @($Row.Buttons)) { if ([string]$got[[string]$b.Id] -cne [string]$b.Result) { [void]$problems.Add("button $($b.Id) answers '$($got[[string]$b.Id])', expected '$($b.Result)'") } }
    if ([string]$Row.Id -ceq 'setup-check') {
        $fnText = ([string](Get-PagesFunctionAstFromText $Source ([string]$Row.Fluent)).Extent.Text) -replace '\s', ''
        if (-not $fnText.Contains("if(`$answer-ceq'Prepare'-and`$offer.canPrepare){return'prepare'}")) { [void]$problems.Add("Prepare answers 'prepare' without the canPrepare guard") }
    }
    return $problems.ToArray()
}
function Get-PagesFunctionAstFromText([string]$Source, [string]$Name) {
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$null, [ref]$null)
    $script:p42Want = $Name
    $found = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $script:p42Want }, $true))
    if ($found.Count -eq 1) { return $found[0] }
    return $null
}
# The fluent chooser's Choose and double-click rules, from the function source: the problems (empty when both hold).
function Get-PagesChooserFluentProblems([string]$FunctionText) {
    $problems = New-Object System.Collections.ArrayList
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($FunctionText, [ref]$null, [ref]$null)
    $fluentDouble = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$n.Member.Extent.Text -ceq 'Add_MouseDoubleClick' -and $n.Expression.Extent.Text -ceq '$listItem' }, $true))
    $dbl = ''; if ($fluentDouble.Count -eq 1) { $dbl = ([string]$fluentDouble[0].Extent.Text -replace '\s', '') }
    if (-not ($fluentDouble.Count -eq 1 -and $dbl.Contains('$list.SelectedItems.Count-eq1') -and $dbl.Contains("'Choose'") -and $dbl.Contains('.Close()'))) { [void]$problems.Add("the double-click handlers on the row items: $($fluentDouble.Count), text=$dbl") }
    $ftNoSpace = ($FunctionText -replace '\s', '')
    if (-not ($ftNoSpace.Contains('$choose.IsEnabled=$false') -and $ftNoSpace.Contains('$enabled=($list.SelectedItems.Count-eq1)') -and $ftNoSpace.Contains('$choose.IsEnabled=$enabled') -and $ftNoSpace.Contains("if(`$enabled){`$state['Enter']='Choose'}else{`$state['Enter']=''}"))) { [void]$problems.Add('Choose is not disabled until one row is selected, or the selection does not move the Enter target') }
    return $problems.ToArray()
}

function Invoke-PagesDialogTablePins([string]$Root) {
    $table = @(Get-PagesDialogTable)
    $uiPath = Join-Path $Root 'fast-llm-ui.ps1'
    $text = Get-PagesFluentTextTable $Root
    Check-BoxPin ($table.Count -eq 7) 'P42 pin: the dialog table has the seven 4b dialogs' "rows=$($table.Count) expected=7"
    Check-BoxPin ($text.Count -ge 40) 'P42 pin: the two fluent string tables were read from the source' "keys=$($text.Count)"
    foreach ($row in $table) {
        $id = [string]$row.Id
        $fluentAst = Get-PagesFunctionAst (Join-Path $Root ([string]$row.File)) ([string]$row.Fluent)
        Check-BoxPin ($null -ne $fluentAst) "P42 pin: row $id the fluent function $($row.Fluent) is in $($row.File) exactly once" ''
        if ($null -eq $fluentAst) { continue }
        $fluentText = [string]$fluentAst.Extent.Text
        $p = Get-PagesFluentDialogParams $fluentAst
        Check-BoxPin ([int]$p['Count'] -eq 1) "P42 pin: row $id builds exactly one dialog through New-FastLlmUiFluentDialog" "calls=$($p['Count'])"
        if ([int]$p['Count'] -ne 1) { continue }
        # the key targets: the dialog host's own -Enter and -Escape arguments (the chooser starts with none: the selection handler moves it)
        $wantEnter = [string]$row.EnterId
        if ($row.ContainsKey('EnterDynamic')) { $wantEnter = '' }
        $gotEnter = ''; if ($p.ContainsKey('Enter')) { $gotEnter = ConvertTo-PagesPlainText ([string]$p['Enter']) }
        $gotEscape = ''; if ($p.ContainsKey('Escape')) { $gotEscape = ConvertTo-PagesPlainText ([string]$p['Escape']) }
        Check-BoxPin ($p.ContainsKey('Enter') -and $gotEnter -ceq $wantEnter) "P42 pin: row $id the fluent Enter target is '$wantEnter'" "actual Enter=$(if ($p.ContainsKey('Enter')) { "'$gotEnter'" } else { '(missing)' }) expected='$wantEnter'"
        Check-BoxPin ($p.ContainsKey('Escape') -and $gotEscape -ceq [string]$row.EscapeId) "P42 pin: row $id the fluent Escape target is '$($row.EscapeId)'" "actual Escape=$(if ($p.ContainsKey('Escape')) { "'$gotEscape'" } else { '(missing)' }) expected='$($row.EscapeId)'"
        Check-BoxPin (-not $p.ContainsKey('CloseEnabled')) "P42 pin: row $id keeps its close box (it answers the Escape target, as the classic form's X does)" "CloseEnabled argument=$(if ($p.ContainsKey('CloseEnabled')) { $p['CloseEnabled'] } else { '(none)' })"
        # reveal and tray: the same as the classic function
        Check-BoxPin (([bool]$fluentText.Contains('RevealUiForAction')) -eq [bool]$row.Reveal) "P42 pin: row $id reveals the window exactly when the classic dialog does ($($row.Reveal))" "fluent reveal=$($fluentText.Contains('RevealUiForAction')) expected=$($row.Reveal)"
        Check-BoxPin ($fluentText.Contains('SetTrayMenuAvailable $false') -and $fluentText.Contains('SetTrayMenuAvailable $true')) "P42 pin: row $id turns the tray menu off while open and on again" ''
        # the buttons: ids and captions (the fluent caption is the classic one, with the WinForms escape && shown as one &)
        $keys = Get-PagesFluentButtonKeys $fluentAst
        foreach ($b in @($row.Buttons)) {
            $key = ''; if ($keys.Contains([string]$b.Id)) { $key = [string]$keys[[string]$b.Id] }
            $fluentCaption = $null
            if ($id -ceq 'save-prompt') { $fluentCaption = [string]$b.Text } elseif ($key -ne '' -and $text.ContainsKey($key)) { $fluentCaption = [string]$text[$key] }
            Check-BoxPin ($keys.Contains([string]$b.Id)) "P42 pin: row $id has the button $($b.Id)" "buttons=$(@($keys.Keys) -join ',')"
            if ($id -cne 'save-prompt') { Check-BoxPin ($null -ne $fluentCaption -and $fluentCaption -ceq ([string]$b.Text).Replace('&&', '&')) "P42 pin: row $id button $($b.Id) shows the classic caption '$(([string]$b.Text))'" "string key='$key' fluent caption='$fluentCaption' classic='$($b.Text)'" }
        }
        # the title
        if ($id -cne 'save-prompt') {
            $titleKey = ''; if ($p.ContainsKey('Title') -and ([string]$p['Title'] -match '\$t\.(\w+)')) { $titleKey = [string]$Matches[1] }
            Check-BoxPin ($titleKey -ne '' -and $text.ContainsKey($titleKey) -and [string]$text[$titleKey] -ceq [string]$row.Title) "P42 pin: row $id the fluent title is '$($row.Title)'" "title key='$titleKey' value='$(if ($text.ContainsKey($titleKey)) { $text[$titleKey] })'"
        }
        # the answer of every button (the frozen Result column), read from the fluent function's return statements
        $resultProblems = @(Get-PagesFluentResultProblems ([System.IO.File]::ReadAllText((Join-Path $Root ([string]$row.File)))) $row)
        foreach ($b in @($row.Buttons)) {
            $bad = @($resultProblems | Where-Object { ([string]$_).StartsWith("button $($b.Id) ") })
            Check-BoxPin ($bad.Count -eq 0) "P42 pin: row $id the fluent function answers '$($b.Result)' for the button $($b.Id)" ($bad -join '; ')
        }
        Check-BoxPin ($resultProblems.Count -eq 0) "P42 pin: row $id answers nothing but the table's results" ($resultProblems -join '; ')
        # 5b-delete-begin
        if ([string]$row.Classic -cne '') { Invoke-PagesClassicDialogRowPins $row $uiPath }
        # 5b-delete-end
    }
    # mutants of the result column: each regression of an answer is found on a changed copy of the fluent source, and the unchanged source passes
    $srcConsent = [System.IO.File]::ReadAllText((Join-Path $Root 'src/FastLlm.UiFluentConsent.ps1'))
    $srcDialogs = [System.IO.File]::ReadAllText((Join-Path $Root 'src/FastLlm.UiFluentDialogs.ps1'))
    $srcSettings = [System.IO.File]::ReadAllText((Join-Path $Root 'src/FastLlm.UiFluentSettings.ps1'))
    $rowOf = @{}; foreach ($r in $table) { $rowOf[[string]$r.Id] = $r }
    Check-BoxPin (@(Get-PagesFluentResultProblems $srcConsent $rowOf['license-setting']).Count -eq 0 -and @(Get-PagesFluentResultProblems $srcConsent $rowOf['component-consent']).Count -eq 0 -and @(Get-PagesFluentResultProblems $srcConsent $rowOf['model-consent']).Count -eq 0 -and @(Get-PagesFluentResultProblems $srcConsent $rowOf['vc-review']).Count -eq 0 -and @(Get-PagesFluentResultProblems $srcDialogs $rowOf['setup-check']).Count -eq 0 -and @(Get-PagesFluentResultProblems $srcDialogs $rowOf['recipe-chooser']).Count -eq 0 -and @(Get-PagesFluentResultProblems $srcSettings $rowOf['save-prompt']).Count -eq 0) 'P42 mutation control: the unchanged fluent sources pass the result column of all seven rows' ''
    Check-BoxPin (@(Get-PagesFluentResultProblems $srcConsent.Replace("return [bool] (`$answer -ceq 'Accept')", "return [bool] (`$answer -ceq 'Cancel')") $rowOf['license-setting']).Count -ge 1) 'P42 mutation check: a licence setting dialog that answers true for Cancel is flagged' ''
    Check-BoxPin (@(Get-PagesFluentResultProblems $srcConsent.Replace("`$confirmed = [bool] (`$answer -ceq 'Install')", "`$confirmed = [bool] (`$answer -ceq 'Cancel')") $rowOf['component-consent']).Count -ge 1) 'P42 mutation check: a component consent that confirms on Cancel is flagged' ''
    Check-BoxPin (@(Get-PagesFluentResultProblems $srcConsent.Replace("return [bool] (`$answer -ceq 'Accept')", "return [bool] (`$answer -ceq 'Cancel')") $rowOf['model-consent']).Count -ge 1) 'P42 mutation check: a model consent that accepts on Cancel is flagged' ''
    Check-BoxPin (@(Get-PagesFluentResultProblems $srcConsent.Replace("return [bool] (`$answer -ceq 'Install')", "return [bool] (`$answer -ceq 'Later')") $rowOf['vc-review']).Count -ge 1) 'P42 mutation check: a VC++ review that installs on Do later is flagged' ''
    Check-BoxPin (@(Get-PagesFluentResultProblems $srcDialogs.Replace("if (`$answer -ceq 'Recheck') { return 'recheck' }", "if (`$answer -ceq 'Recheck') { return 'defer' }") $rowOf['setup-check']).Count -ge 1) 'P42 mutation check: a setup check whose Recheck answers defer is flagged' ''
    Check-BoxPin (@(Get-PagesFluentResultProblems $srcDialogs.Replace("if (`$answer -ceq 'Prepare' -and `$offer.canPrepare) { return 'prepare' }", "if (`$answer -ceq 'Prepare') { return 'prepare' }") $rowOf['setup-check']).Count -ge 1) 'P42 mutation check: a setup check that prepares while Prepare is disabled is flagged' ''
    Check-BoxPin (@(Get-PagesFluentResultProblems $srcDialogs.Replace("if (`$answer -ceq 'Choose' -and `$list.SelectedItems.Count -eq 1)", "if (`$answer -ceq 'Cancel' -and `$list.SelectedItems.Count -eq 1)") $rowOf['recipe-chooser']).Count -ge 1) 'P42 mutation check: a chooser that picks on Cancel is flagged' ''
    Check-BoxPin (@(Get-PagesFluentResultProblems $srcSettings.Replace("if (`$answer -ceq 'DontSave') { return 'discard' }", "if (`$answer -ceq 'DontSave') { return 'cancel' }") $rowOf['save-prompt']).Count -ge 1) 'P42 mutation check: a save prompt whose Dont save answers cancel is flagged' ''
    # the recipe chooser: Choose is disabled until a row is selected and the selection moves the Enter target; a double-click on a selected row chooses (classic: $list.Add_DoubleClick)
    $chooserFluent = Get-PagesFunctionAst (Join-Path $Root 'src/FastLlm.UiFluentDialogs.ps1') 'Show-FastLlmUiFluentRecipeChooser'
    if ($null -ne $chooserFluent) {
        $chooserProblems = @(Get-PagesChooserFluentProblems ([string]$chooserFluent.Extent.Text))
        Check-BoxPin (-not (@($chooserProblems | Where-Object { ([string]$_).StartsWith('the double-click') }).Count -gt 0)) 'P42 pin: the fluent chooser double-click chooses only a selected row (it answers Choose and closes), on each row item and not on the list' ($chooserProblems -join '; ')
        Check-BoxPin (-not (@($chooserProblems | Where-Object { ([string]$_).StartsWith('Choose is not') }).Count -gt 0)) 'P42 pin: the fluent Choose button is disabled until exactly one row is selected, and the selection moves the Enter target (Choose with a selection, none without)' ($chooserProblems -join '; ')
        $chooserText = [string]$chooserFluent.Extent.Text
        Check-BoxPin (@(Get-PagesChooserFluentProblems $chooserText).Count -eq 0) 'P42 mutation control: the unchanged fluent chooser passes both rules' ''
        Check-BoxPin (@(Get-PagesChooserFluentProblems $chooserText.Replace(".Close()", ".Hide()")).Count -ge 1) 'P42 mutation check: a double-click that does not close the chooser is flagged' ''
        Check-BoxPin (@(Get-PagesChooserFluentProblems $chooserText.Replace("if (`$list.SelectedItems.Count -eq 1) {`n                if ([string] `$state['Result']", "if (`$true) {`n                if ([string] `$state['Result']")).Count -ge 1) 'P42 mutation check: a double-click that chooses without a selected row is flagged' ''
        Check-BoxPin (@(Get-PagesChooserFluentProblems $chooserText.Replace('$choose.IsEnabled = $false', '$choose.IsEnabled = $true')).Count -ge 1) 'P42 mutation check: a Choose button that starts enabled is flagged' ''
        Check-BoxPin (@(Get-PagesChooserFluentProblems $chooserText.Replace("if (`$enabled) { `$state['Enter'] = 'Choose' } else { `$state['Enter'] = '' }", "`$state['Enter'] = 'Choose'")).Count -ge 1) 'P42 mutation check: an Enter target that does not follow the selection is flagged' ''
    }
    else { Check-BoxPin $false 'P42 pin: the fluent chooser function was found' '' }
    # 5b-delete-begin
    $chooserClassic = Get-PagesFunctionAst $uiPath 'ShowRecipeChooser'
    Check-BoxPin ($null -ne $chooserClassic) 'P42 pin: the classic chooser function ShowRecipeChooser is in fast-llm-ui.ps1 exactly once' ''
    if ($null -ne $chooserClassic) {
        $ct = [string]$chooserClassic.Extent.Text
        $ctNoSpace = ($ct -replace '\s', '')
        $classicDouble = @($chooserClassic.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$n.Member.Extent.Text -ceq 'Add_DoubleClick' }, $true))
        Check-BoxPin ($classicDouble.Count -eq 1 -and ([string]$classicDouble[0].Extent.Text -replace '\s', '').Contains('$list.SelectedItems.Count-eq1') -and ([string]$classicDouble[0].Extent.Text).Contains('[Windows.Forms.DialogResult]::OK')) "P42 pin: the classic chooser double-clicks a selected row to OK (fast-llm-ui.ps1 line $(if ($classicDouble.Count -eq 1) { $classicDouble[0].Extent.StartLineNumber } else { '?' }), `$list.Add_DoubleClick)" "handlers=$($classicDouble.Count)"
        Check-BoxPin ($ctNoSpace.Contains('$choose.Enabled=$false') -and $ctNoSpace.Contains('$choose.Enabled=($list.SelectedItems.Count-eq1)')) 'P42 pin: the classic Choose button is disabled until exactly one row is selected' ''
    }
    # 5b-delete-end
    # the save prompt: its result strings and its Save button
    $saveAst = Get-PagesFunctionAst (Join-Path $Root 'src/FastLlm.UiFluentSettings.ps1') 'Show-FastLlmUiFluentSavePrompt'
    if ($null -ne $saveAst) {
        $st = ([string]$saveAst.Extent.Text -replace '\s', '')
        Check-BoxPin ($st.Contains("if(`$answer-ceq'Save'){return'save'}") -and $st.Contains("if(`$answer-ceq'DontSave'){return'discard'}") -and $st.Contains("return'cancel'")) 'P42 pin: the save prompt returns save, discard or cancel (anything else is cancel)' ''
        Check-BoxPin ($st.Contains("['Save'].IsEnabled=`$SaveEnabled")) 'P42 pin: the save prompt disables Save when Settings is unavailable' ''
    }
    # the step list of this file runs P42 and P43
    $selfText = [System.IO.File]::ReadAllText($PSCommandPath)
    $stepsBlock = [regex]::Match($selfText, '(?s)\$script:steps = @\((.*?)\r?\n\)')
    Check-BoxPin ($stepsBlock.Success -and $stepsBlock.Groups[1].Value.Contains("'Invoke-P42-DialogKeys'") -and $stepsBlock.Groups[1].Value.Contains("'Invoke-P43-DialogFlows'")) 'P42 pin: the step list names Invoke-P42-DialogKeys and Invoke-P43-DialogFlows' "stepsBlockFound=$($stepsBlock.Success)"
}
# the P41 box table pins run here, after the P42 helpers they share are defined
Invoke-PagesBoxTablePins (Join-Path $root 'fast-llm-ui.ps1')
Invoke-PagesDialogTablePins $root
Write-Host ("INFO: P41 and P42 pins: $($script:boxPinPass) passed, $($script:boxPinFail) failed")
if ($script:boxPinFail -gt 0) { Write-Host "$($script:boxPinFail) checks FAILED"; exit 1 }


$onWindows = ($PSVersionTable.PSVersion.Major -le 5) -or [bool](Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue)
if (-not $onWindows) { Write-Host 'SKIP: ui-fluent-pages-tests (Windows only)'; exit 0 }

$script:pass = 0
$script:fail = 0
. (Join-Path $PSScriptRoot 'helpers/UiFluentShellHarness.ps1')

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { Write-Host 'FAIL: the suite must run on an STA thread (powershell -STA)'; exit 1 }
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
if (-not ('Bitworks.FastLlm.Tests.FluentHostNative' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'helpers/FluentHostNative.cs') -ErrorAction Stop }
if (-not ('Bitworks.FastLlm.FluentWindowNative' -as [type])) { Add-Type -Path (Join-Path $root 'src/WindowsFluentWindow.cs') -ErrorAction Stop }
$script:native = [Bitworks.FastLlm.Tests.FluentHostNative]

# Recorded, never shown: a throwing handler must not open a dialog that waits for a person.
$script:dispEx = New-Object System.Collections.Generic.List[string]
$script:threadEx = New-Object System.Collections.Generic.List[string]
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({ param($s, $e) $script:threadEx.Add($e.Exception.ToString()) })

$script:scns = New-Object System.Collections.Generic.List[object]   # windows, closed in cleanup
$script:objs = New-Object System.Collections.Generic.List[object]   # timers, disposed in cleanup
$script:loopStopped = $false
$script:busy = $false
$script:si = 0
$script:fatal = $null

Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force
. (Join-Path $root 'tests/helpers/UiControlStatesMatrix.ps1')
. (Join-Path $root 'src/FastLlm.Update.ps1')
. (Join-Path $root 'src/FastLlm.Components.ps1')
. (Join-Path $root 'src/FastLlm.ServingSettings.ps1')
. (Join-Path $root 'src/FastLlm.ConnectInfo.ps1')
# PR 4a CI round 1 (named test change): the Close FastLLM row runs the FormClosing handler's own statement, and P41 checks Test-FastLlmUiVcActionAllowed is loaded.
# The classic file dot-sources its prerequisite file next to the flow file; the suite loads it the same way.
. (Join-Path $root 'src/FastLlm.UiPrerequisite.ps1')
. (Join-Path $root 'src/FastLlm.UiFluentShell.ps1')
# PR 4b (B3): the VC++ review and offer functions the setup check and the VC++ review read (the window script dot-sources this file too).
if ($null -eq (Get-Command -Name Format-FastLlmUiVcReview -ErrorAction SilentlyContinue)) { . (Join-Path $root 'src/FastLlm.UiPrerequisite.ps1') }

# The real stop function exits the process, so a startup fault would end the suite silently: its text is kept for one check (P99), then a throwing one stands in.
$script:realStopText = [string](Get-Command Stop-FastLlmUiFluentStartup -CommandType Function).Definition
function Stop-FastLlmUiFluentStartup {
    param([string]$Reason)
    throw "startup stopped: $Reason"
}

# Counts what the shell's exception handlers record (plain code, a reference list), then runs the real one.
$script:unhandledLog = New-Object System.Collections.ArrayList
$script:origUnhandled = ${function:Invoke-FastLlmUiFluentUnhandled}
function Invoke-FastLlmUiFluentUnhandled {
    param($Exception)
    if ($null -ne $Exception) { [void]$script:unhandledLog.Add([string]$Exception.ToString()) } else { [void]$script:unhandledLog.Add('(null exception)') }
    & $script:origUnhandled -Exception $Exception
}
# After the shell starts, Application.ThreadException has ONE handler (the shell's replaces the suite's), so the exceptions the product recorded count too.
function Check-NoExceptions([string]$Name) {
    $d = @($script:dispEx.ToArray()); $t = @($script:threadEx.ToArray()); $u = @($script:unhandledLog.ToArray())
    Check (($d.Count -eq 0) -and ($t.Count -eq 0) -and ($u.Count -eq 0)) "$Name : no dispatcher or WinForms exception recorded" ("dispatcher=" + ($d -join ' | ') + " winforms=" + ($t -join ' | ') + " shell=" + ($u -join ' | '))
    $script:dispEx.Clear(); $script:threadEx.Clear(); $script:unhandledLog.Clear()
}

# The suite's own stubs stand in for the orchestration the pages read (fast-llm-ui.ps1). They are plain file-level functions, the real shape.
# GetUiStateSnapshot is NOT defined here: fast-llm-ui.ps1 defines it after the seam, so the stub is defined after Initialize (P0), as there.
$script:shellSnap = $null
$script:shellFailMsg = ''
$script:shellOk = $false
$script:markerKey = 'fl-FLPAGESMARKERKEY0123456789abcdefghijklmnopq'   # a well-formed key, so the copy routine treats it as one
$script:keyReadCalls = 0
$script:clipboardPayloads = New-Object System.Collections.ArrayList
$script:sideSelectionCalls = 0
$script:sideStepCalls = New-Object System.Collections.ArrayList
$script:connectDialogCalls = 0   # must stay 0 in fluent mode
function GetUiBackgroundRunStatus { return $null }
function ShowFailure($Message) { $script:shellFailMsg = [string]$Message }
function GetUiApiKeyStore { return $null }
function GetUiActionAvailabilityNow([bool]$Busy) { return Get-FastLlmUiSnapshotAvailability -Snapshot $script:shellSnap }
# Returns the marker key and counts the calls (a step that must never read the key checks the count did not move).
$script:keyReadNull = $false
function ReadUiApiKey { $script:keyReadCalls++; if ($script:keyReadNull) { return $null }; return [string]$script:markerKey }
function SetUiClipboardPayload($Payload) { [void]$script:clipboardPayloads.Add($Payload) }
function ReadSideSelection { $script:sideSelectionCalls++ }
$script:sideStepThrows = $false
function LaunchSideStep([string]$Step, [object[]]$Arguments) { if ($script:sideStepThrows) { throw 'side step boom' }; [void]$script:sideStepCalls.Add([pscustomobject]@{ Step = $Step; Arguments = @($Arguments) }) }
function ShowConnectDialog { $script:connectDialogCalls++ }
# The tray menu and reveal calls the driver-guidance dialog makes (fast-llm-ui.ps1 defines them); the suite records the tray calls.
$script:trayAvailability = New-Object System.Collections.ArrayList
# PR 4b (named test change): the reveal stub counts its calls (the reveal column of the 4b evidence table: five of the seven dialogs reveal the window).
$script:revealCalls = 0
function RevealUiForAction { $script:revealCalls++ }
function SetTrayMenuAvailable([bool]$Available) { [void]$script:trayAvailability.Add($Available) }
# The two first-time dialogs P13 checks are the real ones: their definitions are taken by name from fast-llm-ui.ps1 with the PowerShell parser (nothing is run
# from that file but these two functions), so the owner they pass is the one that ships. A missing function is a FAIL in P13.
$script:p13Missing = @()
$uiAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'fast-llm-ui.ps1'), [ref]$null, [ref]$null)
foreach ($fnName in 'ShowUiSideResult', 'ShowDriverGuidance') {
    $script:p13Want = $fnName
    $def = $uiAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $script:p13Want }, $true)
    if ($null -eq $def) { $script:p13Missing += $fnName; continue }
    . ([scriptblock]::Create([string]$def.Extent.Text))
}
# $script:child, $script:vcBroker and $script:updateRun are defined by Initialize-ShellEnv (the shared harness).
$script:selection = @()   # the side-step arguments the API check appends (fast-llm-ui.ps1 defines it)

# ---- PR 3b Task 8: the Models page's orchestration stand-ins ----
# The three Remove flows, the two list fills, ReadSelection and GetBarValue are the REAL functions of fast-llm-ui.ps1, taken by name with the PowerShell parser
# (nothing else is run from that file), so the tests run the code that ships, the two refresh lines included. Everything those functions CALL is a script-scope
# shadow below: the store, the operation lock, the picker, the settings writer and the three dialogs. All of them append to ONE ordered log.
$script:modelsLog = New-Object System.Collections.ArrayList
$script:modelsStore = New-Object System.Collections.ArrayList        # installed model rows: id, sizeBytes, inUse, inUseReason
$script:componentsStore = New-Object System.Collections.ArrayList    # installed component rows: id, label
$script:leftoverStore = New-Object System.Collections.ArrayList      # leftover partial downloads: name, sizeBytes, locked
$script:modelsLockThrows = $false      # true: another process holds the operation lock (the no-wait enter throws)
$script:modelsLockDepth = 0
$script:modelsLockMax = 0
$script:modelsRemoveCalls = 0
$script:modelsLockHeldSeen = New-Object System.Collections.ArrayList   # the -OperationLockHeld hand-off of every remove call
$script:modelsRebuilds = 0             # the model list rebuilds (wrapped below)
$script:componentsRebuilds = 0
$script:pickerCalls = 0
$script:pickerItems = @()
$script:pickerMessage = ''
$script:pickRequests = New-Object System.Collections.ArrayList
$script:settingsWrites = New-Object System.Collections.ArrayList       # the vulkanBarMitigation value of every Write-FastLlmUiSettings call
$script:dialogCalls = @{ switch = 0; models = 0; components = 0; recipe = 0 }
$script:modelsView = $null
$script:componentsView = $null
$script:barValues = @('auto', 'on', 'off')
# The real functions' script blocks, captured before the wrappers below replace them. Not Get-Command: a FunctionInfo is updated in place when the
# function is redefined in the same scope, so calling it from the wrapper would call the wrapper itself (endless recursion).
$script:realConfirmText = ${function:Get-FastLlmModelRemovalConfirmationText}
$script:realRefusalText = ${function:Get-FastLlmModelRemovalRefusalText}
$script:p22Missing = @()
# PR 4a (named test change): the classic functions below call ShowUiMessageBox (the confirmation seam), so the real seam function is taken from fast-llm-ui.ps1 too.
# $script:uiDialogView is $null as in the classic file until the shell registers the fluent view table (Initialize-FastLlmUiFluentShell sets it).
$script:uiDialogView = $null
foreach ($fnName in 'ShowUiMessageBox', 'InvokeUiUpdate', 'InvokeUiReinstall', 'ContinueSupportBundle', 'RemoveModelFromWindow', 'RemoveLeftoversFromWindow', 'RemoveComponentFromWindow', 'FillModelsPanel', 'FillComponentsPanel', 'ReadSelection', 'GetBarValue') {
    $script:p13Want = $fnName
    $def = $uiAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $script:p13Want }, $true)
    if ($null -eq $def) { $script:p22Missing += $fnName; continue }
    . ([scriptblock]::Create([string]$def.Extent.Text))
}
# PR 4a (T5): a recording wrapper over the real seam function. Every call goes to the real ShowUiMessageBox (so the fluent view table and the fluent box run exactly as
# in the window) and its arguments and answer are kept in $script:boxCalls, so a step can say what the classic caller received.
$script:boxCalls = New-Object System.Collections.ArrayList
$script:realShowBox = ${function:ShowUiMessageBox}
if ($null -ne $script:realShowBox) {
    function ShowUiMessageBox($Owner, [string]$Text, [string]$Caption, [string]$Buttons = 'OK', [string]$Icon = 'None', [string]$DefaultButton = 'Button1') {
        $answer = & $script:realShowBox $Owner $Text $Caption $Buttons $Icon $DefaultButton
        [void]$script:boxCalls.Add([pscustomobject]@{ Caption = $Caption; Buttons = $Buttons; Icon = $Icon; Default = $DefaultButton; Result = [string]$answer; Text = $Text })
        return $answer
    }
}
# The real classic wiring of the BAR box (its Add_SelectedIndexChanged statement), attached in P0 to the adapter.
$script:barWiringText = ''
$barStatement = $uiAst.Find({ param($node) $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$node.Member.Extent.Text -ceq 'Add_SelectedIndexChanged' -and [string]$node.Expression.Extent.Text -ceq '$barBox' }, $true)
if ($null -ne $barStatement) { $script:barWiringText = [string]$barStatement.Extent.Text }

function Get-FastLlmInstalledModels { param([string]$InstallRoot, [string]$CatalogPath) return @($script:modelsStore.ToArray()) }
function Remove-FastLlmInstalledModel {
    param([string]$InstallRoot, [string]$CatalogPath, [string]$ModelId, [switch]$OperationLockHeld)
    $script:modelsRemoveCalls++
    [void]$script:modelsLockHeldSeen.Add([bool]$OperationLockHeld)
    [void]$script:modelsLog.Add('remove:' + $ModelId)
    $hit = $null
    foreach ($installed in $script:modelsStore) { if ([string]$installed.id -ceq $ModelId) { $hit = $installed } }
    if ($null -eq $hit) { return [pscustomobject]@{ removed = $false; reason = 'not-installed' } }
    $script:modelsStore.Remove($hit)
    return [pscustomobject]@{ removed = $true; reason = 'ok' }
}
function Enter-FastLlmOperation {
    param([string]$InstallRoot)
    if ($script:modelsLockThrows) { [void]$script:modelsLog.Add('lock-refused'); throw 'The operation lock is held by another process.' }
    $script:modelsLockDepth++
    if ($script:modelsLockDepth -gt $script:modelsLockMax) { $script:modelsLockMax = $script:modelsLockDepth }
    [void]$script:modelsLog.Add('lock')
    $handle = [pscustomobject]@{ Kind = 'modelsLock' }
    Add-Member -InputObject $handle -MemberType ScriptMethod -Name Dispose -Value { $script:modelsLockDepth--; [void]$script:modelsLog.Add('release') }
    return $handle
}
function Get-FastLlmModelLeftovers { param([string]$InstallRoot) return @($script:leftoverStore.ToArray()) }
function Remove-FastLlmModelLeftovers {
    param([string]$InstallRoot, [string[]]$Names, [switch]$OperationLockHeld)
    [void]$script:modelsLockHeldSeen.Add([bool]$OperationLockHeld)
    [void]$script:modelsLog.Add('remove-leftovers:' + (@($Names) -join ','))
    $results = New-Object System.Collections.ArrayList
    foreach ($name in @($Names)) {
        $hit = $null
        foreach ($left in $script:leftoverStore) { if ([string]$left.name -ceq $name) { $hit = $left } }
        if ($null -ne $hit) { $script:leftoverStore.Remove($hit) }
        [void]$results.Add([pscustomobject]@{ removed = ($null -ne $hit); reason = '' })
    }
    return $results.ToArray()
}
function Get-FastLlmModelStoreFreeBytes { param([string]$InstallRoot) return [int64]123456789012 }
function Get-FastLlmComponentInventory { param([string]$ComponentsPath, [string]$InstallRoot) return @() }
function Get-FastLlmInstalledComponentRows { param([object[]]$Inventory) return @($script:componentsStore.ToArray()) }
function Remove-FastLlmComponent {
    param([string]$ComponentsPath, [string]$ComponentId, [string]$InstallRoot, [switch]$OperationLockHeld)
    $script:modelsRemoveCalls++
    [void]$script:modelsLockHeldSeen.Add([bool]$OperationLockHeld)
    [void]$script:modelsLog.Add('remove-component:' + $ComponentId)
    $hit = $null
    foreach ($comp in $script:componentsStore) { if ([string]$comp.id -ceq $ComponentId) { $hit = $comp } }
    if ($null -ne $hit) { $script:componentsStore.Remove($hit) }
}
# The confirmation text is the real function's; the wrapper only logs that the confirmation was asked for (the box shows right after this call).
function Get-FastLlmModelRemovalConfirmationText {
    param([string]$DisplayName, [int64]$SizeBytes)
    [void]$script:modelsLog.Add('confirm:' + $DisplayName)
    return (& $script:realConfirmText -DisplayName $DisplayName -SizeBytes $SizeBytes)
}
function Get-FastLlmStatus { param([string]$InstallRoot) return $null }
function Get-FastLlmUiSwitchPickerModel {
    param([string]$InstallRoot, [string]$CatalogPath, $Status, [scriptblock]$RowsProvider)
    $script:pickerCalls++
    return [pscustomobject]@{ items = @($script:pickerItems); message = [string]$script:pickerMessage }
}
function Invoke-FastLlmUiSwitchPick {
    param([string]$InstallRoot, [string]$CatalogPath, $Items, [string]$ModelId, [scriptblock]$Request)
    [void]$script:pickRequests.Add($ModelId)
    return [pscustomobject]@{ ok = $true; text = ('Switch to ' + $ModelId + ' requested (probe).') }
}
function Write-FastLlmUiSettings { param([string]$InstallRoot, $Settings) [void]$script:settingsWrites.Add([string]$Settings.vulkanBarMitigation) }
# The three dialogs the classic buttons open and the recipe list: counters only. Fluent mode must never reach the first three (P20, P99).
function ShowUiSwitchPicker { $script:dialogCalls['switch']++ }
function ShowModelsWindow { $script:dialogCalls['models']++ }
function ShowComponentsWindow { $script:dialogCalls['components']++ }
function StartRecipeList { $script:dialogCalls['recipe']++ }
# The list rebuilds, counted and logged (the real functions still run). The remove flows reach them through the view's refresh key, by name.
$script:origModelsList = ${function:Update-FastLlmUiFluentModelsList}
function Update-FastLlmUiFluentModelsList {
    $script:modelsRebuilds++
    [void]$script:modelsLog.Add('rebuild')
    & $script:origModelsList
}
$script:origComponentsList = ${function:Update-FastLlmUiFluentComponentsList}
function Update-FastLlmUiFluentComponentsList {
    $script:componentsRebuilds++
    [void]$script:modelsLog.Add('rebuild-components')
    & $script:origComponentsList
}

# ---- PR 3c Task 6: the Settings page's orchestration stand-ins ----
# Everything Save, Create a new key, the sign-in toggle and the three Components toggles CALL is a file-level shadow below (the real registry, the real key store
# and the real settings files are never touched). The REAL code under test is taken by name from fast-llm-ui.ps1 with the PowerShell parser: NewUiApiKey and
# ShowLicenseSettingConfirm (functions), and the wiring statements of the update, experimental and licence boxes and of settingsButton.Add_Click. The effect log
# holds only WRITES (reads are counted apart), in call order, so the Save sequence is one comparable string.
$script:setLog = New-Object System.Collections.ArrayList
$script:setFx = @{ serverPort = 8080; thinking = 'auto'; chatPage = 'off'; idleStopMinutes = 0; apiKey = 'off'; apiKeyUndetermined = $false
    contextProfile = 'default'; slots = 1; embeddings = 'off'; embeddingPort = 8081; embAvail = $false; longMeasured = $false }
$script:setReads = 0
$script:setLastServing = $null
$script:setProbeSlots = New-Object System.Collections.ArrayList   # the -Slots each long-probe read was given
$script:setProbeAsked = New-Object System.Collections.ArrayList   # 'profile:slots' of each probe read (Long at the held slots, and the held profile at 2)
$script:setProbeCalls = @{ emb = 0; long = 0 }   # how often Enter read each availability probe (never per tick, never on a Save's reload)
$script:setLastNew = $null             # the Settings additions the last serving write was GIVEN (name to value); a field the page did not pass is absent
$script:setAllowStored = $null
$script:setApiUnavailable = $false      # true: an 'on' throws api-key-unavailable until a rotate happened
$script:setRotateThrows = ''            # a message: rotate throws it
$script:setRefreshThrows = 0            # RefreshUiSwitchState throws this many times
$script:setSignInChecked = $false
$script:setSignInReads = 0
$script:setSignInReadThrows = $false
$script:setSignInSetThrows = $false
$script:setSignInSets = New-Object System.Collections.ArrayList
$script:setUpdateWrites = New-Object System.Collections.ArrayList
$script:setExpWrites = New-Object System.Collections.ArrayList
$script:setLicWrites = New-Object System.Collections.ArrayList
$script:setExpEvents = New-Object System.Collections.ArrayList
$script:settingsDialogCalls = 0         # ShowUiSettings: must stay 0 (the page replaces the dialog)
$script:experimentalRevert = $false
$script:licenseRevert = $false
$script:apiKeyStore = $null
$script:bgState = Get-UiBackgroundFixture -Name 'none'
# The function's script block, not a FunctionInfo: a FunctionInfo is updated in place when the function is redefined below, so the wrapper would call itself.
$script:realGetComponents = ${function:Get-FastLlmComponents}
$script:p30Missing = @()
foreach ($fnName in 'NewUiApiKey', 'ShowLicenseSettingConfirm') {
    $script:p13Want = $fnName
    $def = $uiAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $script:p13Want }, $true)
    if ($null -eq $def) { $script:p30Missing += $fnName; continue }
    . ([scriptblock]::Create([string]$def.Extent.Text))
}
# ---- PR 4b Task B3: the classic callers of the seven 4b dialogs ----
# The six classic functions below are the real ones of fast-llm-ui.ps1 (taken by name with the parser): each begins with its dispatch line, so with the fluent view table
# registered it returns what the fluent dialog returns, exactly as in the window. ContinueWithChosenRecipe is the real consumer of the chooser's row and of the component
# consent's answer. Everything they call that is not in src (the launcher, the VC++ lookups) is a stub below that records.
$script:p42Missing = @()
foreach ($fnName in 'ShowSetupAttention', 'ShowVcInstallReview', 'ShowExactModelConsent', 'ShowRecipeChooser', 'ShowComponentConsent', 'ContinueWithChosenRecipe') {
    $script:p13Want = $fnName
    $def = $uiAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $script:p13Want }, $true)
    if ($null -eq $def) { $script:p42Missing += $fnName; continue }
    . ([scriptblock]::Create([string]$def.Extent.Text))
}
$script:p42Launch = New-Object System.Collections.ArrayList     # LaunchStep calls: step name and arguments
$script:p42Begin = New-Object System.Collections.ArrayList      # BeginChosenRecipe calls: the row id
$script:p42Candidate = $null
$script:p42Fx = $null                                              # filled once by Initialize-P42Fixtures; StrictMode 2 needs it set before the first read
$script:p42Result = $null
$script:p42InstallDecision = 'offer-install'
function LaunchStep([string]$Step, [object[]]$Arguments) { [void]$script:p42Launch.Add([pscustomobject]@{ Step = $Step; Arguments = @($Arguments) }) }
function BeginChosenRecipe($Row) { [void]$script:p42Begin.Add([string]$Row.id) }
function GetVcCandidate { return $script:p42Candidate }
function GetVcInstallDecision($Inventory, $Candidate) { return [string]$script:p42InstallDecision }
# Start-Process state for the dialogs' link handlers. A link handler is a .GetNewClosure() block made by a function this suite dot-sources, and it resolves
# Start-Process through the SUITE's script scope: it reaches the script-scope recorder below (Task 7), never a global function. CI showed this: a global
# throwing stub was never called. So that one recorder counts every call and throws while Block is on. Block is on only inside the steps that click a link.
$global:FastLlmTestStartProcess = @{ Block = $false; Calls = 0 }

# The real wiring statements, by their target and member (attached in P0 to the adapters the shell made).
$script:settingsWiring = @{}
foreach ($pair in @(@('$updateBox', 'Add_CheckedChanged'), @('$experimentalBox', 'Add_CheckedChanged'), @('$licenseBox', 'Add_CheckedChanged'), @('$settingsButton', 'Add_Click'))) {
    $script:setWantTarget = [string]$pair[0]
    $script:setWantMember = [string]$pair[1]
    $wireAst = $uiAst.Find({ param($node) $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$node.Member.Extent.Text -ceq $script:setWantMember -and [string]$node.Expression.Extent.Text -ceq $script:setWantTarget }, $true)
    if ($null -ne $wireAst) { $script:settingsWiring[[string]$pair[0]] = [string]$wireAst.Extent.Text }
}

function Get-FastLlmServingSettings {
    param([string]$InstallRoot)
    $script:setReads++
    return [pscustomobject]@{ serverPort = [int]$script:setFx.serverPort; thinking = [string]$script:setFx.thinking; chatPage = [string]$script:setFx.chatPage; idleStopMinutes = [int]$script:setFx.idleStopMinutes
        apiKey = [string]$script:setFx.apiKey; apiKeyUndetermined = [bool]$script:setFx.apiKeyUndetermined; malformed = $false
        contextProfile = [string]$script:setFx.contextProfile; slots = [int]$script:setFx.slots; embeddings = [string]$script:setFx.embeddings; embeddingPort = [int]$script:setFx.embeddingPort }
}
# Settings additions (named test change): the stub takes the four new parameters untyped and records exactly the ones it was GIVEN ($PSBoundParameters), like the real
# writer, which leaves a key alone when its parameter is not bound. A given value is stored in the fixture, so the next read shows it.
function Set-FastLlmServingSettings {
    param([string]$InstallRoot, [int]$ServerPort, [string]$Thinking, [string]$ChatPage, [int]$IdleStopMinutes, $KvContextProfile, $KvSlots, $Embeddings, $EmbeddingPort)
    [void]$script:setLog.Add('serving')
    $script:setLastServing = @{ port = $ServerPort; thinking = $Thinking; chat = $ChatPage; idle = $IdleStopMinutes }
    $script:setFx.serverPort = $ServerPort; $script:setFx.thinking = $Thinking; $script:setFx.chatPage = $ChatPage; $script:setFx.idleStopMinutes = $IdleStopMinutes
    $given = @{}
    foreach ($pair in @(@('KvContextProfile', 'contextProfile'), @('KvSlots', 'slots'), @('Embeddings', 'embeddings'), @('EmbeddingPort', 'embeddingPort'))) {
        if ($PSBoundParameters.ContainsKey([string]$pair[0])) { $given[[string]$pair[0]] = $PSBoundParameters[[string]$pair[0]]; $script:setFx[[string]$pair[1]] = $PSBoundParameters[[string]$pair[0]] }
    }
    $script:setLastNew = $given
}
# Settings additions (named test change): the two availability probes are read on Enter, so the fixture decides them ('embAvail', 'longMeasured').
function Test-FastLlmUiFluentEmbeddingsAvailable { $script:setProbeCalls['emb']++; return [bool]$script:setFx['embAvail'] }
# The long probe takes the held requests-at-once value (it is read again when the requests box changes). A fixture with 'longAt' (a list of slot counts) is measured only for those.
# The Default profile at 2 is measured unless a fixture's 'twoMeasured' says otherwise (so the older sections test Long alone); the long profile follows longAt or longMeasured.
function Test-FastLlmUiFluentLongMeasured {
    param([int]$Slots = 1, [string]$ProfileId = 'long')
    $script:setProbeCalls['long']++
    [void]$script:setProbeSlots.Add([int]$Slots)
    [void]$script:setProbeAsked.Add($ProfileId + ':' + [string][int]$Slots)
    if ($ProfileId -ceq 'default') { if ($script:setFx.ContainsKey('twoMeasured')) { return [bool]$script:setFx['twoMeasured'] }; return $true }
    if ($script:setFx.ContainsKey('longAt')) { return [bool](@($script:setFx['longAt']) -contains [int]$Slots) }
    return [bool]$script:setFx['longMeasured']
}
function Set-FastLlmUiAllowSwitch {
    param([string]$InstallRoot, [bool]$Value)
    [void]$script:setLog.Add('allow')
    $script:setAllowStored = $Value
}
function Invoke-FastLlmApiKeySetting {
    param([string]$InstallRoot, [string]$Action)
    [void]$script:setLog.Add('apikey:' + $Action)
    if ($Action -ceq 'on' -and $script:setApiUnavailable) {
        $ex = New-Object System.InvalidOperationException('The stored API key cannot be read.')
        $ex.Data['FastLlmFailureCode'] = 'api-key-unavailable'
        throw $ex
    }
    if ($Action -ceq 'rotate') {
        if ([string]$script:setRotateThrows -ne '') { throw [string]$script:setRotateThrows }
        $script:setApiUnavailable = $false
    }
    elseif ($Action -ceq 'on') { $script:setFx.apiKey = 'on'; $script:setFx.apiKeyUndetermined = $false }
    elseif ($Action -ceq 'off') { $script:setFx.apiKey = 'off'; $script:setFx.apiKeyUndetermined = $false }
    return [pscustomobject]@{ lines = @('A new key was created (probe).') }
}
function RefreshUiSwitchState {
    [void]$script:setLog.Add('refresh')
    if ($script:setRefreshThrows -gt 0) { $script:setRefreshThrows--; throw 'refresh boom' }
}
function Get-FastLlmSignInDefaultInstallRoot { return (Join-Path ([System.IO.Path]::GetTempPath()) 'fastllm-settings-probe-signin') }
function New-SettingsSignInView { return [pscustomobject]@{ checked = [bool]$script:setSignInChecked; stateText = ('Probe sign-in state ' + [bool]$script:setSignInChecked); lastResultText = 'Probe last result' } }
function Get-FastLlmSignInSettingsView {
    param([string]$AppRoot, [string]$InstallRoot)
    $script:setSignInReads++
    if ($script:setSignInReadThrows) { throw 'sign-in read boom' }
    return (New-SettingsSignInView)
}
function Set-FastLlmSignInStartEnabled {
    param([string]$AppRoot, [string]$InstallRoot, [bool]$Enabled)
    [void]$script:setSignInSets.Add([string]$Enabled)
    if ($script:setSignInSetThrows) { throw 'sign-in write boom' }
    $script:setSignInChecked = $Enabled
    return (New-SettingsSignInView)
}
function Set-FastLlmUpdateSettings { param([string]$InstallRoot, [string]$UpdateCheck) [void]$script:setUpdateWrites.Add($UpdateCheck) }
function Set-FastLlmExperimentalSwitchMirrored { param([string]$SourceRoot, [string]$TargetRoot, [string]$Value) [void]$script:setExpWrites.Add($Value) }
function Set-FastLlmComponentLicenseSettingMirrored { param([string]$SourceRoot, [string]$TargetRoot, [string]$Mode, [object[]]$Accepted, [string]$AcceptedAt) [void]$script:setLicWrites.Add($Mode) }
function Clear-FastLlmUiDeclinedSetups { param([string]$InstallRoot) }
# The licence handler reads the components file next to fast-llm-ui.ps1 ($PSScriptRoot); here that is the tests folder, so the real reader is pointed at the repo file.
function Get-FastLlmComponents { param([string]$ComponentsPath) return (& $script:realGetComponents -ComponentsPath (Join-Path $root 'config/components.json')) }
# ShowUiSettings (the classic dialog) is a counter: the Settings page must never reach it.
function ShowUiSettings { $script:settingsDialogCalls++ }

function Invoke-P0-ShellStart {
    Initialize-ShellEnv
    $err = ''
    $initWatch = [System.Diagnostics.Stopwatch]::StartNew()
    try { Initialize-FastLlmUiFluentShell } catch { $err = $_.Exception.Message }
    Write-Host ("INFO: P0 Initialize-FastLlmUiFluentShell took " + $initWatch.ElapsedMilliseconds + " ms")
    Check ($err -eq '') 'P0 the startup did not stop (Initialize-FastLlmUiFluentShell returned)' $err
    if ($err -ne '') { $script:shellOk = $false; return }
    $script:shellOk = $true
    $f = $script:FastLlmUiFluent
    $win = $f.Window
    # The orchestration functions the refresh reads exist only from here, as in fast-llm-ui.ps1.
    Check ([string]$f.TickError -eq '') 'P0 the first refresh in Initialize did not fail (TickError empty before the orchestration functions exist)' "TickError=$($f.TickError)"
    function script:GetUiStateSnapshot([bool]$Busy) { return $script:shellSnap }
    Check ($null -ne $script:form.FastLlmFormState) 'P0 the orchestration form is now the form adapter' 'form has no FastLlmFormState'
    $script:scns.Add([pscustomobject]@{ Window = $win; Form = $script:form; Hwnd = [System.Windows.Interop.WindowInteropHelper]::new($win).Handle; Closed = @{ n = 0 }; Title = $win.Title })
    Check-NoExceptions 'P0'
    # The real wiring of fast-llm-ui.ps1 (its `$connectButton.Add_Click` line), a plain scriptblock that calls the file-level stub. Home's Connect an app row has no
    # Event, so only a raised adapter Click can reach it: P2 asserts it stays at 0 while the page is registered, and proves with a control that the counter can move.
    $script:connectButton.Add_Click({ try { ShowConnectDialog } catch { ShowFailure $_.Exception.Message } })
    # The same real-shaped wiring for the buttons whose classic click opens a dialog (Task 8 counts them: Switch, Downloaded models and Components never open one from
    # the Fluent pages) and for Choose another setup (StartRecipeList), plus the BAR box's real SelectedIndexChanged statement taken from fast-llm-ui.ps1.
    $script:switchButton.Add_Click({ try { ShowUiSwitchPicker } catch { ShowFailure $_.Exception.Message } })
    $script:modelsButton.Add_Click({ try { ShowModelsWindow } catch { ShowFailure $_.Exception.Message } })
    $script:componentsButton.Add_Click({ try { ShowComponentsWindow } catch { ShowFailure $_.Exception.Message } })
    $script:chooseButton.Add_Click({ try { StartRecipeList } catch { ShowFailure $_.Exception.Message } })
    if ($script:barWiringText -ne '') { . ([scriptblock]::Create($script:barWiringText)) }
    # PR 3c: the REAL wiring statements of the three Components toggles (their confirmations, mirroring and reverts) and of the classic Settings button, attached to
    # the adapters the shell made. The Settings button's Click opens today's dialog: it is a counter here and must stay 0 while the page is used (P30).
    foreach ($target in '$updateBox', '$experimentalBox', '$licenseBox', '$settingsButton') {
        # Dot-sourced from a file, so $PSScriptRoot inside the licence handler is a real folder (a [scriptblock]::Create block has none, and its Join-Path throws; the stub ignores the path).
        if ($script:settingsWiring.ContainsKey($target)) {
            $wireFile = Join-Path $script:InstallRoot ('wire-' + [guid]::NewGuid().ToString('N') + '.ps1')
            [System.IO.File]::WriteAllText($wireFile, [string]$script:settingsWiring[$target], (New-Object System.Text.UTF8Encoding($false)))
            . $wireFile
        }
    }
    # From here the loop owns the thread. A DispatcherTimer re-queues itself only after its Tick returns, and P0 does not return until the loop ends:
    # re-arm the step timer by hand so P1 onward run in the nested frame. The loop ends when the last step calls Stop-ShellLoop, so no step may follow that.
    $script:busy = $false
    $script:tick.Stop()
    $script:tick.Start()
    try { Start-FastLlmUiFluentLoop }
    catch { $script:fail++; Write-Host "FAIL: P0 Start-FastLlmUiFluentLoop threw -- $($_.Exception.ToString())" }
}

# P-steps for the later tasks go here, in order (each is a function named Invoke-P<n>-<Name> that returns early when $script:shellOk is false):
# P-SLOT task 5 filled below: P1, P2, P6, P14
# ---- Task 5: the page host, the navigation, the page status line ----
# Tools and Connect do not exist yet (Tasks 6 and 7 register the real pages). These steps register minimal test-only pages for them when the shell
# has not, so the host is tested with Home plus a page that is not Home. Each hook records what ran.
$script:pageEvents = New-Object System.Collections.ArrayList
$script:pagesLeaveAnswer = $true
$script:testPages = @{}
$script:liveRaised = New-Object System.Collections.ArrayList
$script:connectAdapterClicks = 0
function Test-PagesEnter { [void]$script:pageEvents.Add('enter') }
function Test-PagesLeave { [void]$script:pageEvents.Add('leave'); return [bool]$script:pagesLeaveAnswer }
function Test-PagesUpdate { [void]$script:pageEvents.Add('update') }

# Counts what the live region is raised on (the product function still runs).
$script:origLiveRegion = ${function:Send-FastLlmUiFluentLiveRegion}
function Send-FastLlmUiFluentLiveRegion {
    param($Element)
    [void]$script:liveRaised.Add($Element)
    & $script:origLiveRegion -Element $Element
}

function Get-LiveCount($Element) {
    $n = 0
    foreach ($e in @($script:liveRaised.ToArray())) { if ([object]::ReferenceEquals($e, $Element)) { $n++ } }
    return $n
}

$script:FastLlmUiXaml['Test.PagesPage.Tools'] = @'
<StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <TextBlock x:Name="ToolsStatusText" AutomationProperties.LiveSetting="Polite"/>
</StackPanel>
'@
$script:FastLlmUiXaml['Test.PagesPage.Connect'] = @'
<StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <TextBlock x:Name="ConnectStatusText" AutomationProperties.LiveSetting="Polite"/>
</StackPanel>
'@

# A page the shell registered for real keeps its own hooks: they run through these recorders (the host tests count Enter, Leave and Update).
$script:pagesRealHooks = @{}
function Test-PagesEnterReal {
    [void]$script:pageEvents.Add('enter')
    $orig = $script:pagesRealHooks[(Get-FastLlmUiFluentCurrentPage)]
    if ([string]$orig['Enter'] -ne '') { $null = & ([string]$orig['Enter']) }
}
function Test-PagesLeaveReal {
    [void]$script:pageEvents.Add('leave')
    $orig = $script:pagesRealHooks[(Get-FastLlmUiFluentCurrentPage)]
    $answer = [bool]$script:pagesLeaveAnswer
    if ([string]$orig['Leave'] -ne '') { foreach ($a in @(& ([string]$orig['Leave']))) { if ($a -is [bool] -and -not $a) { $answer = $false } } }
    return $answer
}
function Test-PagesUpdateReal {
    [void]$script:pageEvents.Add('update')
    $orig = $script:pagesRealHooks[(Get-FastLlmUiFluentCurrentPage)]
    if ([string]$orig['Update'] -ne '') { $null = & ([string]$orig['Update']) }
}

function Add-PagesTestPage([string]$Id, [string]$Nav, [string]$StatusName) {
    if (Test-FastLlmUiFluentPageRegistered -Id $Id) {
        # The real page steps aside for a test one: only its hooks are wrapped so the host checks can count them
        $entry = $script:FastLlmUiFluent.Pages[$Id]
        if (-not $script:pagesRealHooks.ContainsKey($Id)) {
            $script:pagesRealHooks[$Id] = @{ Enter = [string]$entry['Enter']; Leave = [string]$entry['Leave']; Update = [string]$entry['Update'] }
            $entry['Enter'] = 'Test-PagesEnterReal'; $entry['Leave'] = 'Test-PagesLeaveReal'; $entry['Update'] = 'Test-PagesUpdateReal'
        }
        return
    }
    # Registered XAML (literal here-strings), parsed by the one loader: the source-safety scan allows no other parse
    if ($Id -ceq 'Tools') { $page = New-FastLlmUiXamlElement -Name 'Test.PagesPage.Tools' } else { $page = New-FastLlmUiXamlElement -Name 'Test.PagesPage.Connect' }
    $els = $script:FastLlmUiFluent.Els
    Add-FastLlmUiFluentElements -Els $els -Root $page -Names @($StatusName)
    Register-FastLlmUiFluentPage -Id $Id -Element $page -Nav $Nav -Status $els[$StatusName] -Enter 'Test-PagesEnter' -Leave 'Test-PagesLeave' -Update 'Test-PagesUpdate'
    $script:testPages[$Id] = $page
}

function Get-NavEntry([string]$Id) {
    foreach ($n in @($script:FastLlmUiFluent.NavItems)) { if ([string]$n['Id'] -ceq $Id) { return $n } }
    return $null
}

function Invoke-P1-PageHostAndNav {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $s = $script:FastLlmUiFluentStrings
    $win = $f.Window
    # Before any test page: an item is enabled exactly when its page is registered
    $mismatch = @()
    foreach ($n in @($f.NavItems)) {
        $registered = ((Get-FastLlmUiFluentPageIdByNav -NavId ([string]$n['Id'])) -ne '')
        if ($registered -ne [bool]$n['Item'].IsEnabled -or $registered -ne [bool]$n['Enabled']) { $mismatch += [string]$n['Id'] }
    }
    Check ($mismatch.Count -eq 0) 'P1 a pane item is enabled exactly when a page is registered for it' ("mismatch=" + ($mismatch -join ','))
    Check ([bool](Get-NavEntry 'NavHome')['Item'].IsEnabled) 'P1 Home is enabled' ''
    # PR 3c (named test change): every pane item has a registered page now, so EVERY item is enabled and none carries the coming-later tooltip or help text.
    # (3b left Settings disabled here.) The disabled branch of Set-FastLlmUiFluentNavTip stays as the fail-safe for an unregistered page, tested below with a scratch item.
    Check ([bool](Get-NavEntry 'NavModels')['Item'].IsEnabled -and $null -eq (Get-NavEntry 'NavModels')['Item'].ToolTip) 'P1 Models is enabled in the pane and carries no coming-later tooltip' "enabled=$((Get-NavEntry 'NavModels')['Item'].IsEnabled) tip='$((Get-NavEntry 'NavModels')['Item'].ToolTip)'"
    $disabledNow = @(@($f.NavItems) | Where-Object { -not [bool]$_['Item'].IsEnabled -or -not [bool]$_['Enabled'] } | ForEach-Object { [string]$_['Id'] })
    Check ($disabledNow.Count -eq 0 -and @($f.NavItems).Count -eq 5) 'P1 every pane item (five) is enabled' "disabled=[$($disabledNow -join ',')] items=$(@($f.NavItems).Count)"
    foreach ($id in 'NavSettings') {
        $item = (Get-NavEntry $id)['Item']
        $help = [System.Windows.Automation.AutomationProperties]::GetHelpText($item)
        Check ($item.IsEnabled -and $null -eq $item.ToolTip -and $help -ceq '') "P1 $id is enabled with no coming-later tooltip or help text" "enabled=$($item.IsEnabled) tip='$($item.ToolTip)' help='$help'"
    }
    # The fail-safe: a scratch pane entry that is NOT enabled (no page behind it) gets the coming-later tooltip and help text, expanded and collapsed. It is never added to NavItems.
    $scratchNav = @{ Item = (New-Object System.Windows.Controls.ListBoxItem); Label = $null; Text = 'Probe item'; Enabled = $false; Id = 'NavProbe'; List = 'NavList' }
    $origCollapsed = [bool]$f.Keys['PaneCollapsed']
    try {
        $f.Keys['PaneCollapsed'] = $false
        Set-FastLlmUiFluentNavTip -Nav $scratchNav
        $tipWide = [string]$scratchNav['Item'].ToolTip
        $helpWide = [System.Windows.Automation.AutomationProperties]::GetHelpText($scratchNav['Item'])
        Check ($tipWide -ceq [string]$s.ComingLater -and $helpWide -ceq [string]$s.ComingLater -and [System.Windows.Controls.ToolTipService]::GetShowOnDisabled($scratchNav['Item'])) 'P1 the disabled-item fail-safe (scratch unregistered item, expanded pane) says ComingLater in its tooltip and help text' "tip='$tipWide' help='$helpWide' showOnDisabled=$([System.Windows.Controls.ToolTipService]::GetShowOnDisabled($scratchNav['Item']))"
        $f.Keys['PaneCollapsed'] = $true
        Set-FastLlmUiFluentNavTip -Nav $scratchNav
        $tipNarrow = [string]$scratchNav['Item'].ToolTip
        $wantNarrow = ([string]$s.ComingLaterFormat) -f 'Probe item'
        Check ($tipNarrow -ceq $wantNarrow) 'P1 the disabled-item fail-safe (collapsed pane) says the ComingLaterFormat text with the item label' "tip='$tipNarrow' want='$wantNarrow'"
    }
    finally { $f.Keys['PaneCollapsed'] = $origCollapsed }
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Home' -and [object]::ReferenceEquals($els.PageHost.Child, $f.Pages['Home']['Element']) -and $els.NavHome.IsSelected) 'P1 Home is hosted and selected by default' "current=$(Get-FastLlmUiFluentCurrentPage)"
    # A duplicate element name throws
    $dupThrew = ''
    try { Add-FastLlmUiFluentElements -Els $els -Root $win -Names @('PageHost') } catch { $dupThrew = $_.Exception.Message }
    Check ($dupThrew -match 'already has an element') 'P1 Add-FastLlmUiFluentElements throws on a duplicate name' "message=$dupThrew"
    # The test pages
    Add-PagesTestPage 'Tools' 'NavTools' 'ToolsStatusText'
    Add-PagesTestPage 'Connect' 'NavConnect' 'ConnectStatusText'
    $enabled = @(@($f.NavItems) | Where-Object { [bool]$_['Item'].IsEnabled } | ForEach-Object { [string]$_['Id'] })
    Check (($enabled -join ',') -ceq 'NavHome,NavModels,NavConnect,NavTools,NavSettings') 'P1 the enabled set is all five pane items, Settings last (no item stays disabled)' "enabled=$($enabled -join ',')"
    Check ($null -eq (Get-NavEntry 'NavTools')['Item'].ToolTip -and [string]::IsNullOrEmpty([System.Windows.Automation.AutomationProperties]::GetHelpText((Get-NavEntry 'NavTools')['Item']))) 'P1 a page that registers drops its coming-later tooltip and help text' ''
    # Set-FastLlmUiFluentPage returns exactly one bool
    $script:pageEvents.Clear()
    $r = Set-FastLlmUiFluentPage -Id 'Tools'
    Check (@($r).Count -eq 1 -and $r -is [bool] -and $r) 'P1 Set-FastLlmUiFluentPage returns exactly one bool (true) for a registered page' "count=$(@($r).Count) value=$r"
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Tools' -and [object]::ReferenceEquals($els.PageHost.Child, $f.Pages['Tools']['Element']) -and $els.NavTools.IsSelected -and -not $els.NavHome.IsSelected) 'P1 Tools is hosted and its item is selected' "current=$(Get-FastLlmUiFluentCurrentPage)"
    Check (($script:pageEvents -join ',') -ceq 'enter') 'P1 Enter ran once on arrival' "events=$($script:pageEvents -join ',')"
    $script:pageEvents.Clear()
    $r2 = Set-FastLlmUiFluentPage -Id 'Tools'
    Check (@($r2).Count -eq 1 -and $r2 -and $script:pageEvents.Count -eq 0) 'P1 the current page does nothing (no Leave, no Enter)' "events=$($script:pageEvents -join ',')"
    # PR 3c: Settings is registered now, so a scratch id stands for the unregistered page
    $r3 = Set-FastLlmUiFluentPage -Id 'ProbeUnregistered'
    Check (@($r3).Count -eq 1 -and $r3 -is [bool] -and -not $r3 -and (Get-FastLlmUiFluentCurrentPage) -ceq 'Tools') 'P1 an unregistered page (a scratch id) returns false and changes nothing' "value=$r3"
    $r4 = Set-FastLlmUiFluentPage -Id 'Connect'
    Check ($r4 -and (Get-FastLlmUiFluentCurrentPage) -ceq 'Connect' -and [object]::ReferenceEquals($els.PageHost.Child, $f.Pages['Connect']['Element']) -and $els.NavConnect.IsSelected) 'P1 Connect is hosted and selected' "current=$(Get-FastLlmUiFluentCurrentPage)"
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Invoke-Pump 100
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Home' -and $els.NavHome.IsSelected -and [object]::ReferenceEquals($els.PageHost.Child, $f.Pages['Home']['Element'])) 'P1 back on Home' ''
    # Down on Home selects Models (a registered page now, so the arrow keys reach it)
    $win.Activate()
    $null = $els.NavHome.Focus()
    Invoke-Pump 100
    $path = 'KeyDown routed event on the Home item'
    $threw = ''
    try {
        $src = [System.Windows.PresentationSource]::FromVisual($els.NavHome)
        $ke = New-Object System.Windows.Input.KeyEventArgs([System.Windows.Input.Keyboard]::PrimaryDevice, $src, 0, [System.Windows.Input.Key]::Down)
        $ke.RoutedEvent = [System.Windows.Input.Keyboard]::KeyDownEvent
        $els.NavHome.RaiseEvent($ke)
    }
    catch { $threw = $_.Exception.Message }
    Invoke-Pump 150
    if (-not $els.NavModels.IsSelected) {
        # The synthetic KeyDown did not reach the list navigation: post a real WM_KEYDOWN (VK_DOWN) to the window instead.
        $path = 'PostMessage WM_KEYDOWN VK_DOWN to the window'
        $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($win).Handle
        $nat = $script:native
        $null = $nat::PostMessage($hwnd, [uint32]0x0100, [IntPtr]0x28, [IntPtr]::Zero)
        Invoke-Pump 300 ({ $script:FastLlmUiFluent.Els.NavModels.IsSelected })
    }
    Write-Host ("INFO: P1 Down on Home: path used = " + $path + "; current page = " + (Get-FastLlmUiFluentCurrentPage))
    Check ($threw -eq '' -and $els.NavModels.IsSelected -and (Get-FastLlmUiFluentCurrentPage) -ceq 'Models' -and -not $els.NavHome.IsSelected -and -not $els.NavConnect.IsSelected) 'P1 Down on Home selects Models (a registered page now, no longer skipped)' "path=$path current=$(Get-FastLlmUiFluentCurrentPage) navModels=$($els.NavModels.IsSelected) navHome=$($els.NavHome.IsSelected) error=$threw"
    $null = Set-FastLlmUiFluentPage -Id 'Tools'
    Invoke-Pump 100
    # A null selection, an item with no page and a refused Leave all return the selection to the current page's item
    $els.NavList.SelectedItem = $null
    Invoke-Pump 150
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Tools' -and $els.NavTools.IsSelected) 'P1 a null selection re-selects the current page item' "current=$(Get-FastLlmUiFluentCurrentPage)"
    # Every item has a page now, so the Models page is taken out of the registry for this check and put back after it: its item then has no page, which is what
    # a disabled item was before (the guard under test is the same one). The same for Settings, whose item lives in the second list.
    $modelsEntry = $f.Pages['Models']
    $f.Pages.Remove('Models')
    try {
        $els.NavList.SelectedIndex = 1
        Invoke-Pump 150
        Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Tools' -and $els.NavTools.IsSelected -and -not $els.NavList.Items[1].IsSelected) 'P1 selecting an item that has no registered page re-selects the current page item' "current=$(Get-FastLlmUiFluentCurrentPage) toolsSelected=$($els.NavTools.IsSelected) item1Selected=$($els.NavList.Items[1].IsSelected)"
    }
    finally { $f.Pages['Models'] = $modelsEntry }
    $settingsEntry = $f.Pages['Settings']
    $f.Pages.Remove('Settings')
    try {
        $els.NavSettingsList.SelectedIndex = 0
        Invoke-Pump 150
        Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Tools' -and $els.NavTools.IsSelected -and $els.NavSettingsList.SelectedIndex -eq -1 -and -not $els.NavSettings.IsSelected) 'P1 selecting the Settings item with no registered page re-selects the current item and clears the second list' "current=$(Get-FastLlmUiFluentCurrentPage) toolsSelected=$($els.NavTools.IsSelected) settingsListIndex=$($els.NavSettingsList.SelectedIndex)"
    }
    finally { $f.Pages['Settings'] = $settingsEntry }
    $script:pagesLeaveAnswer = $false
    $script:pageEvents.Clear()
    $els.NavList.SelectedIndex = 0
    Invoke-Pump 150
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Tools' -and $els.NavTools.IsSelected -and -not $els.NavHome.IsSelected -and [object]::ReferenceEquals($els.PageHost.Child, $f.Pages['Tools']['Element']) -and $script:pageEvents.Contains('leave')) 'P1 a Leave that refuses keeps the page and re-selects its item' "current=$(Get-FastLlmUiFluentCurrentPage) events=$($script:pageEvents -join ',')"
    $r5 = Set-FastLlmUiFluentPage -Id 'Home'
    Check (@($r5).Count -eq 1 -and $r5 -is [bool] -and -not $r5) 'P1 Set-FastLlmUiFluentPage returns false when Leave refuses' "value=$r5"
    $script:pagesLeaveAnswer = $true
    $els.NavList.SelectedIndex = 0
    Invoke-Pump 150
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Home' -and $els.NavHome.IsSelected) 'P1 a click on Home leaves Tools once Leave allows it' "current=$(Get-FastLlmUiFluentCurrentPage)"
    Check-NoExceptions 'P1'
}

# ---- PR 3b Task 7: the Activity header's Copy full output button (the lead's flagged risk: Expander.Tag hosting) ----
# Run early (right after P1). Every check name starts with "P16 ACTIVITY-COPY-TAG" so the CI line is easy to find. If a check here fails, change the one
# value $script:FastLlmUiFluentActivityCopySlot in src/FastLlm.UiFluentHome.ps1 from 'Tag' to 'Body' (the plan's fallback slot) and rerun.
$script:activityCopyEvents = New-Object System.Collections.ArrayList
function Add-ActivityCopyEvent { [void]$script:activityCopyEvents.Add('LinkClicked') }
function Invoke-P16-ActivityCopyHeader {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $win = $f.Window
    $s = $script:FastLlmUiFluentStrings
    $slot = [string]$script:FastLlmUiFluentActivityCopySlot
    Write-Host "INFO: P16 the Activity copy slot is '$slot'"
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    $null = $win.Activate()
    $btn = $els['ActivityCopyButton']
    Check ($null -ne $btn -and $btn -is [System.Windows.Controls.Button] -and $btn.Name -ceq 'ActivityCopyButton') 'P16 ACTIVITY-COPY-TAG the code-built header button is in the shell element map (FindName does not find code-built elements)' ''
    if ($null -eq $btn) { return }
    # The failure link's visibility drives the header button (the same adapter), so show it for the checks and put it back after.
    $origVisible = [bool]$script:failureCopyLink.Visible
    $script:failureCopyLink.Visible = $true
    # In the Tag slot the button sits in the header and shows while Activity is collapsed; in the Body fallback it shows only when Activity is expanded.
    $els.ActivityExpander.IsExpanded = ($slot -ceq 'Body')
    Invoke-Pump 150
    Check ($btn.Visibility -eq [System.Windows.Visibility]::Visible -and $btn.IsVisible -and $btn.IsLoaded) 'P16 ACTIVITY-COPY-TAG the header button is visible and loaded (collapsed Activity in the Tag slot)' "visibility=$($btn.Visibility) isVisible=$($btn.IsVisible) loaded=$($btn.IsLoaded)"
    Check ($null -ne $btn.Style -and [object]::ReferenceEquals($btn.Style, $els.FailureCopyButton.Style)) 'P16 ACTIVITY-COPY-TAG the DynamicResource link style resolves (same style object as the failure bar copy link)' "style=$(if ($null -ne $btn.Style) { 'set but not the link style' } else { 'null' })"
    Check ($btn.FontSize -eq $els.FailureCopyButton.FontSize -and [string]$btn.FontFamily -ceq [string]$els.FailureCopyButton.FontFamily) 'P16 ACTIVITY-COPY-TAG the font is inherited as on the failure bar link' "size=$($btn.FontSize) family=$($btn.FontFamily) want size=$($els.FailureCopyButton.FontSize) family=$($els.FailureCopyButton.FontFamily)"
    Check ($btn.Focusable -and $btn.IsEnabled -and $btn.IsTabStop) 'P16 ACTIVITY-COPY-TAG the header button is focusable, enabled and a tab stop' "focusable=$($btn.Focusable) enabled=$($btn.IsEnabled) tabStop=$($btn.IsTabStop)"
    $peer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($btn)
    Check ($null -ne $peer -and $peer.GetName() -ceq [string]$s.CopyFullOutputActivity -and [string]$s.CopyFullOutputActivity -ceq 'Copy full output (Activity)') 'P16 ACTIVITY-COPY-TAG the header button has a peer named Copy full output (Activity)' "name='$(if ($null -ne $peer) { $peer.GetName() })'"
    Check ($null -ne $peer -and $peer.IsControlElement() -and $peer.IsKeyboardFocusable() -and $null -ne $peer.GetPattern([System.Windows.Automation.Peers.PatternInterface]::Invoke)) 'P16 ACTIVITY-COPY-TAG the peer is a control element, keyboard focusable, with the Invoke pattern' ''
    Check ([string]$btn.Content -ceq [string]$script:failureCopyLink.Text -or [string]$btn.Content -ceq (ConvertTo-FastLlmUiAccessText -Text ([string]$script:failureCopyLink.Text) -UseMnemonic ([bool]$script:failureCopyLink.UseMnemonic))) 'P16 ACTIVITY-COPY-TAG the visible text is the adapter caption' "content='$($btn.Content)'"
    # Tab order: toggle, then copy, then (expanded) the Activity box
    $toggle = $els.ActivityExpander.Template.FindName('Hd', $els.ActivityExpander)
    Check ($null -ne $toggle) 'P16 ACTIVITY-COPY-TAG the Expander toggle part is found' ''
    if ($null -ne $toggle) {
        $null = $toggle.Focus()
        Invoke-Pump 100
        $null = $toggle.MoveFocus((New-Object System.Windows.Input.TraversalRequest([System.Windows.Input.FocusNavigationDirection]::Next)))
        Invoke-Pump 100
        $now = [System.Windows.Input.Keyboard]::FocusedElement
        Check ([object]::ReferenceEquals($now, $btn)) 'P16 ACTIVITY-COPY-TAG Tab from the Activity toggle reaches the header button (reachable by Tab)' "focused=$(if ($null -ne $now) { $now.GetType().Name + ':' + [string]$now.Name } else { 'nothing' })"
        $els.ActivityExpander.IsExpanded = $true
        Invoke-Pump 150
        $null = $btn.Focus()
        $null = $btn.MoveFocus((New-Object System.Windows.Input.TraversalRequest([System.Windows.Input.FocusNavigationDirection]::Next)))
        Invoke-Pump 100
        $after = [System.Windows.Input.Keyboard]::FocusedElement
        Check ([object]::ReferenceEquals($after, $els.ActivityBox)) 'P16 ACTIVITY-COPY-TAG Tab from the header button reaches the Activity box (toggle, copy, box)' "focused=$(if ($null -ne $after) { $after.GetType().Name + ':' + [string]$after.Name } else { 'nothing' })"
        $els.ActivityExpander.IsExpanded = $false
    }
    # The copy runs: one adapter LinkClicked per click, by mouse-shaped click and by the UI Automation Invoke pattern
    [void]$script:failureCopyLink.PSObject.Methods['Add_LinkClicked'].Invoke([scriptblock]::Create('Add-ActivityCopyEvent'))
    $script:activityCopyEvents.Clear()
    $btn.RaiseEvent((New-ShellClick $btn ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Invoke-Pump 50
    Check ($script:activityCopyEvents.Count -eq 1) 'P16 ACTIVITY-COPY-TAG a click on the header button runs the copy (one adapter LinkClicked)' "events=$($script:activityCopyEvents.Count)"
    if ($null -ne $peer) { $peer.GetPattern([System.Windows.Automation.Peers.PatternInterface]::Invoke).Invoke() }
    Invoke-Pump 50
    Check ($script:activityCopyEvents.Count -eq 2) 'P16 ACTIVITY-COPY-TAG the UI Automation Invoke runs the copy too (one more LinkClicked)' "events=$($script:activityCopyEvents.Count)"
    # The failure bar's own link still raises exactly one and keeps its own name
    $script:activityCopyEvents.Clear()
    $els.FailureCopyButton.RaiseEvent((New-ShellClick $els.FailureCopyButton ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Invoke-Pump 50
    Check ($script:activityCopyEvents.Count -eq 1) 'P16 ACTIVITY-COPY-TAG the failure bar link still raises one LinkClicked' "events=$($script:activityCopyEvents.Count)"
    # Visible follows the adapter both ways
    $script:failureCopyLink.Visible = $false
    Check ($btn.Visibility -eq [System.Windows.Visibility]::Collapsed) 'P16 ACTIVITY-COPY-TAG the header button hides with the adapter' "visibility=$($btn.Visibility)"
    $script:failureCopyLink.Visible = $origVisible
    Check-NoExceptions 'P16'
}

# Home's Switch and Change go to Models once that page is registered (Task 6 registers it); until then Switch raises today's adapter click and Change does nothing.
$script:homeSwitchAdapterClicks = 0
function Add-HomeSwitchAdapterClick { $script:homeSwitchAdapterClicks++ }
function Invoke-P17-HomeSwitchAndChange {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $win = $f.Window
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    $null = $win.Activate()
    Check ($els.ChangeButton.IsEnabled -and $null -eq $els.ChangeButton.ToolTip) 'P17 Change is enabled and carries no coming-later tooltip' "enabled=$($els.ChangeButton.IsEnabled) tip='$($els.ChangeButton.ToolTip)'"
    if (Test-FastLlmUiFluentPageRegistered -Id 'Models') {
        $els.SwitchButton.RaiseEvent((New-ShellClick $els.SwitchButton ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Invoke-Pump 200
        $focused = [System.Windows.Input.FocusManager]::GetFocusedElement($win)
        Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Models' -and $els.NavModels.IsSelected -and ([object]::ReferenceEquals($focused, $els.NavModels) -or $els.NavModels.IsKeyboardFocused)) 'P17 Home Switch hosts Models and focuses the pane item' "current=$(Get-FastLlmUiFluentCurrentPage)"
        $null = Set-FastLlmUiFluentPage -Id 'Home'
        $els.ChangeButton.RaiseEvent((New-ShellClick $els.ChangeButton ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Invoke-Pump 200
        $box = $els['ModelsModelBox']
        Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Models' -and $null -ne $box -and $box.IsKeyboardFocusWithin) 'P17 Home Change hosts Models and focuses the model box' "current=$(Get-FastLlmUiFluentCurrentPage)"
        $null = Set-FastLlmUiFluentPage -Id 'Home'
    }
    else {
        [void]$script:switchButton.PSObject.Methods['Add_Click'].Invoke([scriptblock]::Create('Add-HomeSwitchAdapterClick'))
        $script:homeSwitchAdapterClicks = 0
        $els.SwitchButton.RaiseEvent((New-ShellClick $els.SwitchButton ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Invoke-Pump 100
        Check ($script:homeSwitchAdapterClicks -eq 1 -and (Get-FastLlmUiFluentCurrentPage) -ceq 'Home') 'P17 Models not registered yet: Home Switch raises today adapter click once and stays on Home' "clicks=$($script:homeSwitchAdapterClicks) current=$(Get-FastLlmUiFluentCurrentPage)"
        $els.ChangeButton.RaiseEvent((New-ShellClick $els.ChangeButton ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Invoke-Pump 100
        Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Home' -and $script:homeSwitchAdapterClicks -eq 1) 'P17 Models not registered yet: Home Change does nothing' "current=$(Get-FastLlmUiFluentCurrentPage)"
    }
    Check-NoExceptions 'P17'
}

function Invoke-P2-ConnectAnApp {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $win = $f.Window
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    $win.Activate()
    $script:pageEvents.Clear()
    $els.ConnectButton.RaiseEvent((New-ShellClick $els.ConnectButton ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Invoke-Pump 200
    $focused = [System.Windows.Input.FocusManager]::GetFocusedElement($win)
    $hasFocus = ([object]::ReferenceEquals($focused, $els.NavConnect) -or $els.NavConnect.IsKeyboardFocused)
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Connect' -and $els.NavConnect.IsSelected) 'P2 Connect an app hosts the Connect page' "current=$(Get-FastLlmUiFluentCurrentPage)"
    Check $hasFocus 'P2 Connect an app puts the focus on the Connect pane item' "focused=$(if ($null -ne $focused) { $focused.GetType().Name } else { 'nothing' })"
    Check ($script:connectDialogCalls -eq 0 -and (Test-FastLlmUiFluentPageRegistered -Id 'Connect')) 'P2 ShowConnectDialog stays at 0 while the Connect page is registered' "calls=$($script:connectDialogCalls)"
    # Control: the counter can move. The adapter event raised directly reaches the real wiring once; then the counter is put back.
    Invoke-FastLlmUiAdapterEvent -Adapter $script:connectButton -Event 'Click'
    Check ($script:connectDialogCalls -eq 1) 'P2 control: a raised adapter Click reaches the wired ShowConnectDialog stub once (the counter can move)' "calls=$($script:connectDialogCalls)"
    $script:connectDialogCalls = 0
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Check-NoExceptions 'P2'
}

function Invoke-P6-PageStatusLine {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $null = Set-FastLlmUiFluentPage -Id 'Tools'
    Invoke-FastLlmUiFluentTick
    $script:liveRaised.Clear(); $script:pageEvents.Clear()
    $script:statusLabel.Text = 'Pages status line one'
    Invoke-FastLlmUiFluentTick
    $composed = [string]$f.Keys['Composed']
    $toolsText = [string]$els.ToolsStatusText.Text
    $toolsName = [System.Windows.Automation.AutomationProperties]::GetName($els.ToolsStatusText)
    Check ($composed -match 'Pages status line one' -and $toolsText -ceq $composed -and $toolsName -ceq $composed) 'P6 a statusLabel change on Tools writes the composed line to the Tools status text and its name' "composed='$composed' text='$toolsText' name='$toolsName'"
    Check ((Get-LiveCount $els.ToolsStatusText) -eq 1 -and (Get-LiveCount $els.StatusDetail) -eq 0) 'P6 one event on the Tools status text and none on StatusDetail' "tools=$(Get-LiveCount $els.ToolsStatusText) detail=$(Get-LiveCount $els.StatusDetail)"
    Check (([string]$els.ConnectStatusText.Text) -ceq $composed) 'P6 every registered page shows the composed line, not only the current one' "connect='$($els.ConnectStatusText.Text)'"
    Check (@($script:pageEvents | Where-Object { $_ -ceq 'update' }).Count -ge 1) 'P6 the current page Update hook ran in the tick' "events=$($script:pageEvents -join ',')"
    $script:liveRaised.Clear()
    Invoke-FastLlmUiFluentTick
    Check ($script:liveRaised.Count -eq 0) 'P6 an unchanged line raises nothing' "raised=$($script:liveRaised.Count)"
    # A page swap raises nothing
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Invoke-Pump 100
    Check ($script:liveRaised.Count -eq 0) 'P6 a page swap raises no live-region event' "raised=$($script:liveRaised.Count)"
    # On Home the announcement is on StatusDetail only; Tools gets the text without an event
    $script:pageEvents.Clear()
    $script:statusLabel.Text = 'Pages status line two'
    Invoke-FastLlmUiFluentTick
    $composed2 = [string]$f.Keys['Composed']
    Check ((Get-LiveCount $els.StatusDetail) -eq 1 -and (Get-LiveCount $els.ToolsStatusText) -eq 0 -and ([string]$els.ToolsStatusText.Text) -ceq $composed2) 'P6 on Home the event is on StatusDetail only and Tools still gets the new text' "detail=$(Get-LiveCount $els.StatusDetail) tools=$(Get-LiveCount $els.ToolsStatusText) text='$($els.ToolsStatusText.Text)'"
    Check (@($script:pageEvents | Where-Object { $_ -ceq 'update' }).Count -eq 0) 'P6 a page that is not current gets no Update' "events=$($script:pageEvents -join ',')"
    Check (([string]$els.StatusDetail.Text) -ceq 'Pages status line two') 'P6 Home keeps the adapter text on StatusDetail (the page status only names it)' "text='$($els.StatusDetail.Text)'"
    Check-NoExceptions 'P6'
}

function Invoke-P14-TrayRestore {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $win = $f.Window
    # The tray button still raises the adapter click the orchestration listens to (once), and does not move the page
    $script:trayClicks = 0
    $script:trayButton.Add_Click({ $script:trayClicks++ })
    $null = Set-FastLlmUiFluentPage -Id 'Tools'
    $els.TrayButton.RaiseEvent((New-ShellClick $els.TrayButton ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Invoke-Pump 100
    Check ($script:trayClicks -eq 1 -and (Get-FastLlmUiFluentCurrentPage) -ceq 'Tools') 'P14 the Minimize to tray button raises its adapter click once and keeps the page' "clicks=$($script:trayClicks) current=$(Get-FastLlmUiFluentCurrentPage)"
    # The RestoreFromTray sequence (as the orchestration runs it) keeps the current page
    $win.WindowState = [System.Windows.WindowState]::Minimized
    $script:form.Hide()
    Invoke-Pump 100
    $script:form.Show()
    $script:form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $script:form.Activate()
    Invoke-Pump 150
    Check ($win.WindowState -eq [System.Windows.WindowState]::Normal -and (Get-FastLlmUiFluentCurrentPage) -ceq 'Tools' -and [object]::ReferenceEquals($els.PageHost.Child, $f.Pages['Tools']['Element']) -and $els.NavTools.IsSelected) 'P14 Restore from the tray keeps the page that was current' "state=$($win.WindowState) current=$(Get-FastLlmUiFluentCurrentPage)"
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Check-NoExceptions 'P14'
}

# ---- Task 6: the Tools page ----
$script:toolsClicks = New-Object System.Collections.ArrayList
function Add-ToolsClick([string]$Name) { [void]$script:toolsClicks.Add($Name) }
function Get-ToolsClickCount([string]$Name) { return @($script:toolsClicks.ToArray() | Where-Object { $_ -ceq $Name }).Count }

function Invoke-P3-ToolsBindings {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $null = Set-FastLlmUiFluentPage -Id 'Tools'
    Invoke-Pump 100
    $rows = @(Get-FastLlmUiFluentToolsBindings)
    Check ($rows.Count -eq 8) 'P3 the Tools table has its 8 rows' "rows=$($rows.Count)"
    foreach ($row in $rows) {
        $adapter = Get-Variable -Name ([string]$row.Name) -Scope Script -ValueOnly
        $el = $els[[string]$row.Element]
        $tag = [string]$row.Element
        $origText = [string]$adapter.Text
        $origEnabled = [bool]$adapter.Enabled
        $origVisible = [bool]$adapter.Visible
        # Text: the sink writes the access text of the adapter caption
        $adapter.Text = 'Probe &caption'
        $want = ConvertTo-FastLlmUiAccessText -Text 'Probe &caption' -UseMnemonic ([bool]$adapter.UseMnemonic)
        Check ([string]$el.Content -ceq [string]$want) "P3 $tag Text reaches the element as access text" "content='$($el.Content)' want='$want'"
        $adapter.Text = $origText
        # Enabled and Visible
        $adapter.Enabled = $false
        $offOk = (-not $el.IsEnabled)
        $adapter.Enabled = $true
        Check ($offOk -and $el.IsEnabled) "P3 $tag Enabled reaches the element both ways" "offOk=$offOk now=$($el.IsEnabled)"
        $adapter.Visible = $false
        $hidden = ($el.Visibility -eq [System.Windows.Visibility]::Collapsed)
        $adapter.Visible = $true
        Check ($hidden -and $el.Visibility -eq [System.Windows.Visibility]::Visible) "P3 $tag Visible reaches the element both ways" "hidden=$hidden now=$($el.Visibility)"
        $adapter.Enabled = $origEnabled
        $adapter.Visible = $origVisible
        # A real-shaped plain handler (a scriptblock that calls a file-level function, no closure) runs once per click
        $event = [string]$row.Event
        $handler = [scriptblock]::Create("Add-ToolsClick '" + [string]$row.Name + "'")
        [void]$adapter.PSObject.Methods[('Add_' + $event)].Invoke($handler)
        $el.RaiseEvent((New-ShellClick $el ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Invoke-Pump 50
        $expected = 1
        if ([string]$row.Name -ceq 'backgroundAttachButton') { $expected = 1 }
        Check ((Get-ToolsClickCount ([string]$row.Name)) -eq $expected) "P3 a click on $tag runs the plain handler once" "count=$(Get-ToolsClickCount ([string]$row.Name))"
    }
    Check ([string]$els.ToolsTitle.Text -ceq [string]$script:FastLlmUiFluentStrings.NavTools) 'P3 the page title is the Tools label' "title='$($els.ToolsTitle.Text)'"
    Check-NoExceptions 'P3'
}

function Invoke-P4-AttachFanOut {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $adapter = $script:backgroundAttachButton
    $origEnabled = [bool]$adapter.Enabled
    $origVisible = [bool]$adapter.Visible
    $homeVis = $els.AttachButton.Visibility
    $adapter.Enabled = $false
    Check ((-not $els.ToolsAttachButton.IsEnabled) -and (-not $els.AttachButton.IsEnabled)) 'P4 Enabled false reaches both the Tools and the Home Attach buttons' "tools=$($els.ToolsAttachButton.IsEnabled) home=$($els.AttachButton.IsEnabled)"
    $adapter.Enabled = $true
    Check ($els.ToolsAttachButton.IsEnabled -and $els.AttachButton.IsEnabled) 'P4 Enabled true reaches both' "tools=$($els.ToolsAttachButton.IsEnabled) home=$($els.AttachButton.IsEnabled)"
    $adapter.Visible = $false
    Check ($els.ToolsAttachButton.Visibility -eq [System.Windows.Visibility]::Collapsed -and $els.AttachButton.Visibility -eq $homeVis) 'P4 Visible follows the adapter on Tools while Home keeps the card visibility' "tools=$($els.ToolsAttachButton.Visibility) home=$($els.AttachButton.Visibility) (was $homeVis)"
    $adapter.Visible = $true
    Check ($els.AttachButton.Visibility -eq $homeVis) 'P4 Home Attach visibility is still the card own after the adapter shows' "home=$($els.AttachButton.Visibility) (was $homeVis)"
    # One click, one event, from either element (the P3 handler counts 'backgroundAttachButton')
    $before = Get-ToolsClickCount 'backgroundAttachButton'
    $els.ToolsAttachButton.RaiseEvent((New-ShellClick $els.ToolsAttachButton ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Invoke-Pump 50
    $afterTools = Get-ToolsClickCount 'backgroundAttachButton'
    $els.AttachButton.RaiseEvent((New-ShellClick $els.AttachButton ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Invoke-Pump 50
    $afterHome = Get-ToolsClickCount 'backgroundAttachButton'
    Check (($afterTools - $before) -eq 1 -and ($afterHome - $afterTools) -eq 1) 'P4 one click on either Attach button raises exactly one adapter event' "tools=$($afterTools - $before) home=$($afterHome - $afterTools)"
    $adapter.Enabled = $origEnabled
    $adapter.Visible = $origVisible
    Check-NoExceptions 'P4'
}

function Invoke-P5-GreyedReasons {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $s = $script:FastLlmUiFluentStrings
    $null = Set-FastLlmUiFluentPage -Id 'Tools'
    $doctor = $script:doctorButton
    $origEnabled = [bool]$doctor.Enabled
    $btn = $els.ToolsDiagnosticsButton
    Check ([System.Windows.Controls.ToolTipService]::GetShowOnDisabled($btn)) 'P5 the Diagnostics button shows its tooltip while disabled' ''
    # Busy: a disabled Diagnostics button says why
    $script:shellSnap = New-ShellSnap @{ Busy = $true }
    $doctor.Enabled = $false
    Invoke-FastLlmUiFluentTick
    $help = [System.Windows.Automation.AutomationProperties]::GetHelpText($btn)
    Check ([string]$btn.ToolTip -ceq [string]$s.WhyBusy -and $help -ceq [string]$s.WhyBusy) 'P5 a busy state shows WhyBusy as ToolTip and HelpText on Diagnostics' "tip='$($btn.ToolTip)' help='$help'"
    # Microsoft setup changes the code
    $script:shellSnap = New-ShellSnap @{ Busy = $true; VcBrokerActive = $true }
    Invoke-FastLlmUiFluentTick
    Check ([string]$btn.ToolTip -ceq [string]$s.WhyMicrosoftSetup) 'P5 Microsoft setup shows WhyMicrosoftSetup' "tip='$($btn.ToolTip)'"
    # Written on change only: a tooltip set by hand survives a tick with the same code
    $btn.ToolTip = 'hand-set'
    Invoke-FastLlmUiFluentTick
    Check ([string]$btn.ToolTip -ceq 'hand-set') 'P5 an unchanged code does not rewrite the tooltip' "tip='$($btn.ToolTip)'"
    # Idle with the button still disabled: an empty code shows nothing
    $script:shellSnap = New-ShellSnap
    Invoke-FastLlmUiFluentTick
    $help2 = [System.Windows.Automation.AutomationProperties]::GetHelpText($btn)
    Check ($null -eq $btn.ToolTip -and $help2 -ceq '') 'P5 an empty code (idle, still disabled) clears the reason and shows nothing' "tip='$($btn.ToolTip)' help='$help2'"
    # Enabled button shows nothing even when busy
    $doctor.Enabled = $true
    $script:shellSnap = New-ShellSnap @{ Busy = $true }
    Invoke-FastLlmUiFluentTick
    Check ($null -eq $btn.ToolTip) 'P5 an enabled button shows no reason' "tip='$($btn.ToolTip)'"
    $script:shellSnap = New-ShellSnap
    $doctor.Enabled = $origEnabled
    Invoke-FastLlmUiFluentTick
    Check ($null -eq $btn.ToolTip -and [System.Windows.Automation.AutomationProperties]::GetHelpText($btn) -ceq '') 'P5 idle clears the reason' "tip='$($btn.ToolTip)'"
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Check-NoExceptions 'P5'
}

# ---- Task 7: the Connect page ----
# The orchestration reads the Connect page makes when it opens are shadowed with fixtures, and the clipboard wrapper and Start-Process record instead of acting.
$script:connectFixture = $null
$script:connectKeyRow = $null
$script:connectInfoCalls = 0
$script:fieldClips = New-Object System.Collections.ArrayList
$script:fieldClipThrow = $false
$script:startedProcs = New-Object System.Collections.ArrayList
function Get-FastLlmConnectionInfo { param($Status, $InstallRoot, $Settings) $script:connectInfoCalls++; return $script:connectFixture }
function Get-FastLlmUiApiKeyRow { param($Info, $Settings, $ApiKeyStore) return $script:connectKeyRow }
function Set-FastLlmUiFluentClipboardText { param([string]$Text) if ($script:fieldClipThrow) { throw 'clipboard boom' }; [void]$script:fieldClips.Add($Text) }
# The ONE Start-Process stub of the suite (the dialogs' link closures resolve it too; see the state above): it counts each call, throws while Block is on
# (the link-failure steps), and otherwise records the target instead of opening it.
function Start-Process {
    param([string]$FilePath)
    $global:FastLlmTestStartProcess['Calls'] = [int]$global:FastLlmTestStartProcess['Calls'] + 1
    if ([bool]$global:FastLlmTestStartProcess['Block']) { throw 'Start-Process is blocked in this test' }
    [void]$script:startedProcs.Add($FilePath)
}

function New-ConnectFixture([hashtable]$O = @{}) {
    $d = @{ state = 'running'; baseUrl = 'http://127.0.0.1:8123/v1'; anthropicBaseUrl = 'http://127.0.0.1:8123'; modelName = 'probe-model'; contextTokens = 8192; apiKey = 'on'
        agentWarning = 'Probe agent warning'
        endpoints = @([pscustomobject]@{ path = '/v1/chat/completions'; label = 'Chat' }, [pscustomobject]@{ path = '/v1/messages'; label = 'Anthropic messages' })
        clients = @(
            [pscustomobject]@{ title = 'Probe client A'; snippet = "export K={KEY}`nexport U=http://127.0.0.1:8123"; docUrls = @('https://example.test/a', 'http://example.test/insecure') },
            [pscustomobject]@{ title = 'Probe client B'; snippet = 'plain snippet without a token'; docUrls = @() }) }
    foreach ($k in $O.Keys) { $d[$k] = $O[$k] }
    return [pscustomobject]$d
}
function New-ConnectRow([bool]$Visible = $true, [bool]$CanShow = $true, [string]$Note = 'Probe key note') {
    return [pscustomobject]@{ visible = $Visible; mask = '********'; canShow = $CanShow; note = $Note }
}
# Before any step opens Connect (P1 and P2 do), the page reads these defaults.
$script:connectFixture = New-ConnectFixture
$script:connectKeyRow = New-ConnectRow
# Sets the fixtures and opens Connect afresh (Home first, so the page is entered).
function Open-ConnectPage($Fixture, $Row) {
    $script:connectFixture = $Fixture
    $script:connectKeyRow = $Row
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    $null = Set-FastLlmUiFluentPage -Id 'Connect'
    Invoke-Pump 100
}
function Invoke-ConnectClick($Element) {
    $Element.RaiseEvent((New-ShellClick $Element ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Invoke-Pump 30
}

# Every place the marker could be: each text, name, help text, tooltip, tag and content in the window and the three pages, every adapter state, and the window's own state.
function Test-ConnectHasMarker($Value, [string]$Marker) {
    if ($null -eq $Value) { return $false }
    if ($Value -isnot [string]) { return $false }
    return ([string]$Value).Contains($Marker)
}
function Add-ConnectDictScan($Obj, [string]$Path, [string]$Marker, [hashtable]$Hits, [int]$Depth) {
    if ($null -eq $Obj -or $Depth -gt 6) { return }
    $base = $Obj.psobject.BaseObject
    if ($base -is [string]) { if (Test-ConnectHasMarker $base $Marker) { $Hits[$Path] = $true }; return }
    if ($base -is [System.Windows.DependencyObject] -or $base -is [Delegate] -or $base -is [scriptblock]) { return }
    if ($base -is [System.Collections.IDictionary]) {
        foreach ($key in @($base.Keys)) { Add-ConnectDictScan $base[$key] ($Path + '/' + [string]$key) $Marker $Hits ($Depth + 1) }
        return
    }
    if ($base -is [System.Management.Automation.PSCustomObject]) {
        foreach ($prop in @($base.psobject.Properties)) { Add-ConnectDictScan $prop.Value ($Path + '.' + [string]$prop.Name) $Marker $Hits ($Depth + 1) }
        return
    }
    if ($base -is [System.Collections.IEnumerable]) {
        $i = 0
        foreach ($item in $base) { Add-ConnectDictScan $item ($Path + '[' + $i + ']') $Marker $Hits ($Depth + 1); $i++ }
    }
}
function Add-ConnectWalk($Node, [string]$Marker, [hashtable]$Hits, [hashtable]$Seen) {
    $base = $Node.psobject.BaseObject
    $id = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($base)
    if ($Seen.ContainsKey($id)) { return }
    $Seen[$id] = $true
    $label = $base.GetType().Name
    if ($base -is [System.Windows.FrameworkElement]) { $label = $label + ':' + [string]$base.Name }
    if ($base -is [System.Windows.Controls.TextBlock] -and (Test-ConnectHasMarker $base.Text $Marker)) { $Hits[$label + '.Text'] = $true }
    if ($base -is [System.Windows.Controls.TextBox] -and (Test-ConnectHasMarker $base.Text $Marker)) { $Hits[$label + '.Text'] = $true }
    if ($base -is [System.Windows.Controls.ContentControl] -and (Test-ConnectHasMarker $base.Content $Marker)) { $Hits[$label + '.Content'] = $true }
    if ($base -is [System.Windows.Controls.HeaderedItemsControl] -and (Test-ConnectHasMarker $base.Header $Marker)) { $Hits[$label + '.Header'] = $true }
    if ($base -is [System.Windows.Window] -and (Test-ConnectHasMarker $base.Title $Marker)) { $Hits[$label + '.Title'] = $true }
    if ($base -is [System.Windows.FrameworkElement]) {
        if (Test-ConnectHasMarker $base.ToolTip $Marker) { $Hits[$label + '.ToolTip'] = $true }
        if (Test-ConnectHasMarker $base.Tag $Marker) { $Hits[$label + '.Tag'] = $true }
    }
    if (Test-ConnectHasMarker ([System.Windows.Automation.AutomationProperties]::GetName($base)) $Marker) { $Hits[$label + '.AutomationName'] = $true }
    if (Test-ConnectHasMarker ([System.Windows.Automation.AutomationProperties]::GetHelpText($base)) $Marker) { $Hits[$label + '.HelpText'] = $true }
    foreach ($child in [System.Windows.LogicalTreeHelper]::GetChildren($base)) {
        if ($child -is [System.Windows.DependencyObject]) { Add-ConnectWalk $child $Marker $Hits $Seen }
        # A TextBox's one non-element logical child is its own Text (already checked above as '.Text'); counting it again would report
        # the key box twice. Every other node's string child is still a holder.
        elseif ($base -is [System.Windows.Controls.TextBox]) { continue }
        elseif (Test-ConnectHasMarker $child $Marker) { $Hits[$label + '/child'] = $true }
    }
}
function Get-ConnectMarkerHolders([string]$Marker) {
    $f = $script:FastLlmUiFluent
    $hits = @{}
    $seen = @{}
    foreach ($root in @($f.Window, $f.Pages['Connect']['Element'], $f.Pages['Home']['Element'], $f.Pages['Tools']['Element'])) { Add-ConnectWalk $root $Marker $hits $seen }
    foreach ($row in (Get-FastLlmUiFluentControlTable)) {
        $adapter = Get-Variable -Name ([string]$row[0]) -Scope Script -ValueOnly
        Add-ConnectDictScan $adapter.__state ('adapter ' + [string]$row[0]) $Marker $hits 0
    }
    Add-ConnectDictScan $f 'state' $Marker $hits 0
    return @($hits.Keys | Sort-Object)
}

function Invoke-P7-ConnectContent {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $t = $script:FastLlmUiFluentConnectText
    $s = $script:FastLlmUiFluentStrings
    $fx = New-ConnectFixture
    Open-ConnectPage $fx (New-ConnectRow)
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Connect' -and [string]$els.ConnectTitle.Text -ceq 'Connect an app') 'P7 Connect is hosted and its title is Connect an app' "current=$(Get-FastLlmUiFluentCurrentPage) title='$($els.ConnectTitle.Text)'"
    $want = @(
        @{ P = 'ConnectBaseUrl'; L = 'Base URL'; V = 'http://127.0.0.1:8123/v1' },
        @{ P = 'ConnectAnthropicUrl'; L = 'Anthropic base URL'; V = 'http://127.0.0.1:8123' },
        @{ P = 'ConnectModelName'; L = 'Model name'; V = 'probe-model' },
        @{ P = 'ConnectContextLimit'; L = 'Context limit (tokens)'; V = '8192' })
    foreach ($w in $want) {
        $box = $els[$w.P + 'Box']; $copy = $els[$w.P + 'Copy']; $label = $els[$w.P + 'Label']
        Check ([string]$box.Text -ceq $w.V -and [string]$copy.Tag -ceq $w.V -and $box.IsReadOnly) "P7 $($w.L): the read-only box and the Copy tag hold the value" "box='$($box.Text)' tag='$($copy.Tag)'"
        Check ([string]$label.Text -ceq $w.L -and [System.Windows.Automation.AutomationProperties]::GetName($box) -ceq $w.L -and [object]::ReferenceEquals([System.Windows.Automation.AutomationProperties]::GetLabeledBy($box), $label)) "P7 $($w.L): the box name and LabeledBy come from the label" ''
        Check ([string]$copy.Content -ceq 'Copy' -and [System.Windows.Automation.AutomationProperties]::GetName($copy) -ceq (([string]$s.CopyFieldFormat) -f $w.L)) "P7 $($w.L): the Copy button says Copy and is named Copy plus the label" "content='$($copy.Content)' name='$([System.Windows.Automation.AutomationProperties]::GetName($copy))'"
    }
    Check ([string]$els.ConnectIntro.Text -ceq [string]$t.IntroRunning) 'P7 the intro follows a running state' "text='$($els.ConnectIntro.Text)'"
    $endpointWant = 'Endpoints on the base URL:' + [Environment]::NewLine + ((@($fx.endpoints) | ForEach-Object { '  ' + $_.path + ' - ' + $_.label }) -join [Environment]::NewLine)
    Check ([string]$els.ConnectEndpoints.Text -ceq $endpointWant) 'P7 the endpoint text is the classic formula' "text='$($els.ConnectEndpoints.Text)'"
    Check ([string]$els.ConnectAgentWarningText.Text -ceq 'Probe agent warning' -and $els.ConnectAgentWarning.Visibility -eq [System.Windows.Visibility]::Visible) 'P7 the agent warning shows in its caution border' ''
    Check ($els.ConnectKeyRow.Visibility -eq [System.Windows.Visibility]::Visible -and $els.ConnectKeyShow.IsEnabled -and $els.ConnectKeyCopy.IsEnabled -and [string]$els.ConnectKeyNote.Text -ceq 'Probe key note' -and $els.ConnectKeyNote.Visibility -eq [System.Windows.Visibility]::Visible) 'P7 a visible key row enables Show and Copy and shows its note' ''
    # The cards
    $cards = @($f.Connect['Cards'])
    Check ($cards.Count -eq 2 -and $els.ConnectClients.Children.Count -eq 2) 'P7 one card per client' "cards=$($cards.Count) children=$($els.ConnectClients.Children.Count)"
    $a = $cards[0]
    $snippetA = [string]$fx.clients[0].snippet
    $displayA = (Get-FastLlmConnectDisplayText -Snippet $snippetA) -replace "`n", [Environment]::NewLine
    Check ([string]$a.Copy.Tag -ceq $snippetA -and [string]$a.Copy.Tag -cmatch '\{KEY\}') 'P7 the card Copy keeps the snippet with its key token in Tag' "tag='$($a.Copy.Tag)'"
    Check ([string]$a.Box.Text -ceq $displayA -and $a.Box.IsReadOnly -and [string]$a.Box.Text -cnotmatch '\{KEY\}') 'P7 the card shows the snippet with the placeholder, read-only' "text='$($a.Box.Text)'"
    Check ([System.Windows.Automation.AutomationProperties]::GetName($a.Box) -ceq 'Probe client A' -and [object]::ReferenceEquals([System.Windows.Automation.AutomationProperties]::GetLabeledBy($a.Box), $a.Title) -and [System.Windows.Automation.AutomationProperties]::GetName($a.Copy) -ceq 'Copy Probe client A') 'P7 the card box is named and labelled by its title, and its Copy by Copy plus the title' ''
    Check (@($a.Links).Count -eq 2 -and @($cards[1].Links).Count -eq 0) 'P7 the doc links are one per url, none for a client without any' "links=$(@($a.Links).Count)"
    $script:startedProcs.Clear()
    $httpLink = @($a.Links | Where-Object { [string]$_.Tag -ceq 'http://example.test/insecure' })[0]
    $httpsLink = @($a.Links | Where-Object { [string]$_.Tag -ceq 'https://example.test/a' })[0]
    Invoke-ConnectClick $httpLink
    Check ($script:startedProcs.Count -eq 0) 'P7 an http doc link opens nothing' "started=$($script:startedProcs -join ',')"
    Invoke-ConnectClick $httpsLink
    Check ($script:startedProcs.Count -eq 1 -and [string]$script:startedProcs[0] -ceq 'https://example.test/a') 'P7 an https doc link opens its url' "started=$($script:startedProcs -join ',')"
    # Not running: the intro, and the two values that appear only once it runs
    Open-ConnectPage (New-ConnectFixture @{ state = 'not-running'; modelName = $null; contextTokens = $null; agentWarning = $null }) (New-ConnectRow $false $false '')
    Check ([string]$els.ConnectIntro.Text -ceq [string]$t.IntroNotRunning) 'P7 the intro follows a not-running state' "text='$($els.ConnectIntro.Text)'"
    Check ([string]$els.ConnectModelNameBox.Text -ceq '(shown when running)' -and [string]$els.ConnectContextLimitBox.Text -ceq '(shown when running)') 'P7 a model name and context limit that are not known say shown when running' ''
    Check ($els.ConnectKeyRow.Visibility -eq [System.Windows.Visibility]::Collapsed -and $els.ConnectKeyNote.Visibility -eq [System.Windows.Visibility]::Collapsed -and $els.ConnectAgentWarning.Visibility -eq [System.Windows.Visibility]::Collapsed) 'P7 no key row, note or warning when there is none' ''
    Open-ConnectPage (New-ConnectFixture) (New-ConnectRow $true $false 'Probe unreadable note')
    Check ($els.ConnectKeyRow.Visibility -eq [System.Windows.Visibility]::Visible -and -not $els.ConnectKeyShow.IsEnabled -and -not $els.ConnectKeyCopy.IsEnabled) 'P7 a key row that cannot be shown disables Show and Copy' ''
    Open-ConnectPage (New-ConnectFixture) (New-ConnectRow)
    Check-NoExceptions 'P7'
}

function Invoke-P8-ConnectKey {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $marker = [string]$script:markerKey
    Open-ConnectPage (New-ConnectFixture) (New-ConnectRow)
    $box = $els.ConnectKeyBox
    $show = $els.ConnectKeyShow
    $baseline = $script:keyReadCalls
    Check ([string]$box.Text -ceq '********' -and [string]$show.Content -ceq 'Show' -and $script:keyReadCalls -eq $baseline) 'P8 the key box starts masked and nothing has read the key' "text='$($box.Text)' reads=$($script:keyReadCalls - $baseline)"
    Check (($box -is [System.Windows.Controls.TextBox]) -and ($box -isnot [System.Windows.Controls.PasswordBox]) -and $box.IsReadOnly -and -not $box.IsUndoEnabled) 'P8 the key box is a read-only TextBox with undo off, not a PasswordBox' ''
    $peer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($box)
    $valuePattern = $peer.GetPattern([System.Windows.Automation.Peers.PatternInterface]::Value)
    Check ((Get-ShellPeerName $box) -ceq 'API key' -and $null -ne $valuePattern -and [bool]$valuePattern.IsReadOnly) 'P8 the key box peer is named API key and has a read-only ValuePattern' "name='$(Get-ShellPeerName $box)'"
    # Show: one read, the marker in the box, the caption is Hide
    Invoke-ConnectClick $show
    Check ($script:keyReadCalls -eq ($baseline + 1) -and [string]$box.Text -ceq $marker -and [string]$show.Content -ceq 'Hide') 'P8 Show reads the key once, the box holds it and the caption becomes Hide' "reads=$($script:keyReadCalls - $baseline) caption='$($show.Content)'"
    $holders = @(Get-ConnectMarkerHolders $marker)
    Check ($holders.Count -eq 1 -and $holders[0] -ceq 'TextBox:ConnectKeyBox.Text') 'P8 marker walk while shown: the marker is in the key box text and nowhere else' "holders=$($holders -join '; ')"
    # The Copy command of the shown box (Ctrl+C, Ctrl+Insert and the context menu are this command) goes through the key copy routine
    $script:fieldClips.Clear(); $script:clipboardPayloads.Clear()
    $target = $box.psobject.BaseObject
    $canCopy = [System.Windows.Input.ApplicationCommands]::Copy.CanExecute($null, $target)
    [System.Windows.Input.ApplicationCommands]::Copy.Execute($null, $target)
    Invoke-Pump 30
    $copied = @($script:clipboardPayloads.ToArray())
    $formatNames = @(); if ($copied.Count -eq 1) { $formatNames = @($copied[0].formats.Keys | Sort-Object) }
    Check ($canCopy -and $copied.Count -eq 1 -and [string]$copied[0].text -ceq $marker -and ($formatNames -join ',') -ceq 'CanIncludeInClipboardHistory,CanUploadToCloudClipboard,ExcludeClipboardContentFromMonitorProcessing' -and $script:fieldClips.Count -eq 0) 'P8 the Copy command on the shown box records the marker with the three exclusion formats and never the plain clipboard wrapper' "can=$canCopy payloads=$($copied.Count) formats=$($formatNames -join ',') plain=$($script:fieldClips.Count)"
    $menuItem = $box.ContextMenu.Items[0]
    Check ($box.ContextMenu.Items.Count -eq 1 -and [object]::ReferenceEquals($menuItem.Command, [System.Windows.Input.ApplicationCommands]::Copy) -and [object]::ReferenceEquals($menuItem.CommandTarget, $box) -and -not [System.Windows.Input.ApplicationCommands]::Cut.CanExecute($null, $target)) 'P8 the context menu is one Copy item bound to the Copy command, and Cut is blocked' ''
    # The context-menu Copy item itself is invoked (through its automation peer, the way a screen reader or a click runs it): the same key payload
    $script:fieldClips.Clear(); $script:clipboardPayloads.Clear()
    $menuPeer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($menuItem)
    $menuPeer.GetPattern([System.Windows.Automation.Peers.PatternInterface]::Invoke).Invoke()
    Invoke-Pump 100
    $menuCopied = @($script:clipboardPayloads.ToArray())
    $menuFormats = @(); if ($menuCopied.Count -eq 1) { $menuFormats = @($menuCopied[0].formats.Keys | Sort-Object) }
    Check ($menuCopied.Count -eq 1 -and [string]$menuCopied[0].text -ceq $marker -and ($menuFormats -join ',') -ceq 'CanIncludeInClipboardHistory,CanUploadToCloudClipboard,ExcludeClipboardContentFromMonitorProcessing' -and $script:fieldClips.Count -eq 0) 'P8 invoking the context-menu Copy item copies the key with the exclusion formats and nothing as plain text' "payloads=$($menuCopied.Count) formats=$($menuFormats -join ',')"
    # A drag of the key text: the DataObject.Copying event is raised with a constructed DataObjectCopyingEventArgs (a drag) and the handler cancels it
    $dragArgs = New-Object System.Windows.DataObjectCopyingEventArgs((New-Object System.Windows.DataObject), $true)
    $dragArgs.RoutedEvent = [System.Windows.DataObject]::CopyingEvent
    $dragArgs.Source = $box
    $box.RaiseEvent($dragArgs)
    Check ($dragArgs.CommandCancelled) 'P8 a drag of the key text (DataObject.Copying raised with a drag argument) is cancelled' ''
    # Select all, then copy: the page binding runs, not the TextBox's own copy (one key payload, no plain text)
    $script:fieldClips.Clear(); $script:clipboardPayloads.Clear()
    $null = $box.Focus()
    $box.SelectAll()
    [System.Windows.Input.ApplicationCommands]::Copy.Execute($null, $target)
    Invoke-Pump 50
    $selCopied = @($script:clipboardPayloads.ToArray())
    Check ($selCopied.Count -eq 1 -and [string]$selCopied[0].text -ceq $marker -and @($selCopied[0].formats.Keys).Count -eq 3 -and $script:fieldClips.Count -eq 0) 'P8 Copy after SelectAll still runs the page binding (the key payload with its formats, no plain text)' "payloads=$($selCopied.Count)"
    $box.Select(0, 0)
    # Hide masks without a read
    $before = $script:keyReadCalls
    Invoke-ConnectClick $show
    Check ([string]$box.Text -ceq '********' -and [string]$show.Content -ceq 'Show' -and $script:keyReadCalls -eq $before -and -not $box.CanUndo) 'P8 Hide masks the box without a read and CanUndo is false' "text='$($box.Text)' undo=$($box.CanUndo)"
    $holders = @(Get-ConnectMarkerHolders $marker)
    Check ($holders.Count -eq 0) 'P8 marker walk after Hide: the marker is nowhere' "holders=$($holders -join '; ')"
    # A failed read keeps the mask and says so
    $script:keyReadNull = $true
    Invoke-ConnectClick $show
    Check ([string]$box.Text -ceq '********' -and [string]$show.Content -ceq 'Show' -and ([string]$script:statusLabel.Text) -ceq 'The stored API key cannot be read.') 'P8 a failed read keeps the mask and sets the status text' "text='$($box.Text)' status='$($script:statusLabel.Text)'"
    $script:keyReadNull = $false
    # Re-masking: leave, IsVisibleChanged, a running-edge refresh
    $remask = @(
        @{ Name = 'leaving the page'; Do = { $null = Set-FastLlmUiFluentPage -Id 'Home' } },
        @{ Name = 'the page becoming invisible'; Do = { $pageElement = $script:FastLlmUiFluent.Pages['Connect']['Element']; $pageElement.Visibility = [System.Windows.Visibility]::Collapsed; $pageElement.Visibility = [System.Windows.Visibility]::Visible } },
        @{ Name = 'the tray path (form Hide)'; Do = { $script:form.Hide(); Invoke-Pump 100; $script:form.Show(); $script:form.Activate() } },
        @{ Name = 'a running-edge refresh'; Do = { $script:FastLlmUiFluent.Keys['Running'] = (-not [bool]$script:FastLlmUiFluent.Keys['Running']); Update-FastLlmUiFluentConnect } })
    foreach ($r in $remask) {
        $null = Set-FastLlmUiFluentPage -Id 'Connect'
        Invoke-Pump 50
        Invoke-ConnectClick $show
        $wasShown = ([string]$box.Text -ceq $marker)
        & $r.Do
        Invoke-Pump 50
        $holders = @(Get-ConnectMarkerHolders $marker)
        Check ($wasShown -and [string]$box.Text -ceq '********' -and [string]$show.Content -ceq 'Show' -and -not $box.CanUndo -and $holders.Count -eq 0) "P8 $($r.Name) masks a shown key (CanUndo false, the marker nowhere)" "wasShown=$wasShown text='$($box.Text)' undo=$($box.CanUndo) holders=$($holders -join '; ')"
    }
    # The refresh reads the content only on a running edge, never on another tick
    $null = Set-FastLlmUiFluentPage -Id 'Connect'
    Invoke-Pump 50
    # Bring the page in step with what the Home refresh will write (not running); that one change is an edge and may read.
    $f.Keys['Running'] = $false
    Update-FastLlmUiFluentConnect
    $calls = $script:connectInfoCalls
    Update-FastLlmUiFluentConnect
    Invoke-FastLlmUiFluentTick
    Update-FastLlmUiFluentConnect
    Check ($script:connectInfoCalls -eq $calls) 'P8 the connection info is not read again on a tick with no running edge' "calls=$($script:connectInfoCalls - $calls)"
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Check-NoExceptions 'P8'
}

function Invoke-P9-ConnectCopies {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $marker = [string]$script:markerKey
    $fx = New-ConnectFixture
    Open-ConnectPage $fx (New-ConnectRow)
    # A field Copy goes through the shadowed wrapper
    $script:fieldClips.Clear(); $script:clipboardPayloads.Clear()
    Invoke-ConnectClick $els.ConnectBaseUrlCopy
    Check ($script:fieldClips.Count -eq 1 -and [string]$script:fieldClips[0] -ceq 'http://127.0.0.1:8123/v1' -and $script:clipboardPayloads.Count -eq 0) 'P9 a field Copy sends its value through the plain clipboard wrapper' "clips=$($script:fieldClips -join ',')"
    $script:fieldClipThrow = $true
    Invoke-ConnectClick $els.ConnectModelNameCopy
    $script:fieldClipThrow = $false
    Check (([string]$script:statusLabel.Text) -ceq 'Could not copy: clipboard boom') 'P9 a failing field Copy sets the status text as the dialog does' "status='$($script:statusLabel.Text)'"
    # The key Copy: the marker plus the three exclusion formats
    $script:fieldClips.Clear(); $script:clipboardPayloads.Clear()
    Invoke-ConnectClick $els.ConnectKeyCopy
    $p = @($script:clipboardPayloads.ToArray())
    $names = @(); if ($p.Count -eq 1) { $names = @($p[0].formats.Keys | Sort-Object) }
    Check ($p.Count -eq 1 -and [string]$p[0].text -ceq $marker -and ($names -join ',') -ceq 'CanIncludeInClipboardHistory,CanUploadToCloudClipboard,ExcludeClipboardContentFromMonitorProcessing' -and $script:fieldClips.Count -eq 0) 'P9 the key Copy records the marker with the three exclusion formats, not through the plain wrapper' "payloads=$($p.Count) formats=$($names -join ',')"
    # A card Copy replaces the key token (with the key formats), and a card without a token copies plain
    $script:clipboardPayloads.Clear()
    $cards = @($f.Connect['Cards'])
    Invoke-ConnectClick $cards[0].Copy
    $p = @($script:clipboardPayloads.ToArray())
    $want = ([string]$fx.clients[0].snippet).Replace('{KEY}', $marker)
    Check ($p.Count -eq 1 -and [string]$p[0].text -ceq $want -and @($p[0].formats.Keys).Count -eq 3) 'P9 a card Copy replaces {KEY} with the key and carries the exclusion formats' "payloads=$($p.Count)"
    $script:clipboardPayloads.Clear()
    $readsBefore = $script:keyReadCalls
    Invoke-ConnectClick $cards[1].Copy
    $p = @($script:clipboardPayloads.ToArray())
    Check ($p.Count -eq 1 -and [string]$p[0].text -ceq 'plain snippet without a token' -and @($p[0].formats.Keys).Count -eq 0 -and $script:keyReadCalls -eq $readsBefore) 'P9 a card with no key token copies its text plain and reads no key' "payloads=$($p.Count) reads=$($script:keyReadCalls - $readsBefore)"
    # An unreadable key gives today's texts
    $script:keyReadNull = $true
    $script:clipboardPayloads.Clear()
    Invoke-ConnectClick $els.ConnectKeyCopy
    Check ($script:clipboardPayloads.Count -eq 0 -and ([string]$script:statusLabel.Text) -ceq 'The stored API key cannot be read.') 'P9 an unreadable key: the key Copy copies nothing and says so' "payloads=$($script:clipboardPayloads.Count) status='$($script:statusLabel.Text)'"
    Invoke-ConnectClick $cards[0].Copy
    $p = @($script:clipboardPayloads.ToArray())
    Check (([string]$script:statusLabel.Text) -ceq 'The stored API key cannot be read, so the card was copied without it.' -and $p.Count -eq 1 -and ([string]$p[0].text).Contains($marker) -eq $false) 'P9 an unreadable key: a card is copied without it and says so' "status='$($script:statusLabel.Text)' payloads=$($p.Count)"
    $script:keyReadNull = $false
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Check-NoExceptions 'P9'
}

function Invoke-P10-ConnectApiCheck {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $s = $script:FastLlmUiFluentStrings
    $btn = $els.ConnectCheckButton
    Check ([string]$btn.Content -ceq 'Check the API formats' -and [System.Windows.Controls.ToolTipService]::GetShowOnDisabled($btn)) 'P10 the check button says Check the API formats and shows its tooltip while disabled' "content='$($btn.Content)'"
    # Not running: disabled, with its reason
    $script:shellSnap = New-ShellSnap @{ RunReady = $true }
    Open-ConnectPage (New-ConnectFixture @{ state = 'not-running' }) (New-ConnectRow)
    $help = [System.Windows.Automation.AutomationProperties]::GetHelpText($btn)
    Check ((-not $btn.IsEnabled) -and [string]$btn.ToolTip -ceq [string]$s.WhyNotRunning -and $help -ceq [string]$s.WhyNotRunning) 'P10 not running: the button is disabled and says Start FastLLM first' "enabled=$($btn.IsEnabled) tip='$($btn.ToolTip)'"
    # Running, a side step in the way
    $script:shellSnap = New-ShellSnap @{ RunReady = $true; SideChildActive = $true }
    Open-ConnectPage (New-ConnectFixture) (New-ConnectRow)
    Check ((-not $btn.IsEnabled) -and [string]$btn.ToolTip -ceq [string]$s.WhySideStep) 'P10 during a side step: the button is disabled with the side-step reason' "enabled=$($btn.IsEnabled) tip='$($btn.ToolTip)'"
    # The rule is read on every tick: the side step ends, the button comes back and the reason goes
    $script:shellSnap = New-ShellSnap @{ RunReady = $true }
    Update-FastLlmUiFluentConnect
    Check ($btn.IsEnabled -and $null -eq $btn.ToolTip -and [System.Windows.Automation.AutomationProperties]::GetHelpText($btn) -ceq '') 'P10 running and idle: the button is enabled and shows no reason' "enabled=$($btn.IsEnabled) tip='$($btn.ToolTip)'"
    # Running with no run ready and no side step (a model load, an unattached background run): the reason is the tested function's code, never side-step
    $script:shellSnap = New-ShellSnap @{ RunReady = $false }
    Open-ConnectPage (New-ConnectFixture) (New-ConnectRow)
    $wantCode = [string](Get-FastLlmUiGreyedReason -Action 'apiCheck' -Snapshot $script:shellSnap -ConnectRunning $true)
    $wantText = [string](Get-FastLlmUiFluentToolsReasonText -Code $wantCode)
    Check ($wantCode -cne 'side-step' -and (-not $btn.IsEnabled) -and [string]$btn.ToolTip -ceq $wantText -and [string]$btn.ToolTip -cne [string]$s.WhySideStep) 'P10 running but no run ready and no side step: the shown reason is the function code, not the side-step reason' "code='$wantCode' tip='$($btn.ToolTip)'"
    $script:shellSnap = New-ShellSnap @{ RunReady = $true }
    Update-FastLlmUiFluentConnect
    # A click records ReadSideSelection, then the launch with its arguments
    $script:selection = @('--probe-selection')
    $selBefore = $script:sideSelectionCalls
    $script:sideStepCalls.Clear()
    Invoke-ConnectClick $btn
    $call = $null; if ($script:sideStepCalls.Count -eq 1) { $call = $script:sideStepCalls[0] }
    Check ($script:sideSelectionCalls -eq ($selBefore + 1) -and $null -ne $call -and [string]$call.Step -ceq 'api check' -and (@($call.Arguments) -join ' ') -ceq 'doctor -ApiCheck --probe-selection') 'P10 a click reads the side selection, then launches the api check side step with its arguments' "selection=$($script:sideSelectionCalls - $selBefore) calls=$($script:sideStepCalls.Count) args=$(if ($null -ne $call) { @($call.Arguments) -join ' ' })"
    # A throw reaches ShowFailure
    $script:sideStepThrows = $true
    $script:shellFailMsg = ''
    Invoke-ConnectClick $btn
    $script:sideStepThrows = $false
    Check ([string]$script:shellFailMsg -ceq 'side step boom') 'P10 a throw from the launch reaches ShowFailure' "message='$($script:shellFailMsg)'"
    $script:selection = @()
    $script:shellSnap = New-ShellSnap
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Check-NoExceptions 'P10'
}

# ---- Task 8: the keyboard, the control view and the first-time dialogs ----
function Get-PagesTabWalk($NavItem) {
    $win = $script:FastLlmUiFluent.Window
    $null = $win.Activate()
    $null = $NavItem.Focus()
    Invoke-Pump 200
    $cur = [System.Windows.Input.Keyboard]::FocusedElement
    $started = ($null -ne $cur) -and [object]::ReferenceEquals($cur, $NavItem)
    $stops = New-Object System.Collections.ArrayList
    if ($started) {
        for ($i = 0; $i -lt 60; $i++) {
            $null = $cur.MoveFocus((New-Object System.Windows.Input.TraversalRequest([System.Windows.Input.FocusNavigationDirection]::Next)))
            $cur = [System.Windows.Input.Keyboard]::FocusedElement
            if ($null -eq $cur) { break }
            if ([object]::ReferenceEquals($cur, $NavItem)) { break }
            $name = ''
            if ($cur -is [System.Windows.UIElement]) { $name = Get-ShellPeerName $cur }
            [void]$stops.Add([pscustomobject]@{ Element = $cur; Type = $cur.GetType().Name; Name = $name })
        }
    }
    return [pscustomobject]@{ Started = $started; Stops = $stops.ToArray() }
}

function Get-PagesStopsIn($Walk, $PageElement) {
    $in = New-Object System.Collections.ArrayList
    foreach ($stop in @($Walk.Stops)) {
        if ($stop.Element -is [System.Windows.DependencyObject] -and $PageElement.IsAncestorOf($stop.Element)) { [void]$in.Add($stop) }
    }
    return $in.ToArray()
}

# P11 walks the real window from a pane item with Tab: every stop has a readable name, and Connect's Copy buttons have distinct names.
function Invoke-P11-TabWalk {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $script:shellSnap = New-ShellSnap
    # Tools
    $null = Set-FastLlmUiFluentPage -Id 'Tools'
    Invoke-Pump 150
    $walk = Get-PagesTabWalk $els.NavTools
    $stops = @($walk.Stops)
    $unnamed = @($stops | Where-Object { -not (Test-ShellNameReadable ([string]$_.Name)) } | ForEach-Object { [string]$_.Type })
    $inPage = @(Get-PagesStopsIn $walk $f.Pages['Tools']['Element'])
    Write-Host ("INFO: P11 Tools tab stops: " + (($stops | ForEach-Object { [string]$_.Type + ':' + [string]$_.Name }) -join ' > '))
    Check ($walk.Started) 'P11 the focus can be placed on the Tools pane item (the window must be active for the walk)' "focused=$([System.Windows.Input.Keyboard]::FocusedElement)"
    Check ($inPage.Count -ge 3 -and $unnamed.Count -eq 0) 'P11 the Tools walk reaches the page and every tab stop has a readable name' "inPage=$($inPage.Count) stops=$($stops.Count) unnamed=[$($unnamed -join ',')]"
    # Connect: the field, key and card Copy buttons
    Open-ConnectPage (New-ConnectFixture) (New-ConnectRow)
    Invoke-Pump 150
    $walk = Get-PagesTabWalk $els.NavConnect
    $stops = @($walk.Stops)
    $unnamed = @($stops | Where-Object { -not (Test-ShellNameReadable ([string]$_.Name)) } | ForEach-Object { [string]$_.Type })
    $inPage = @(Get-PagesStopsIn $walk $f.Pages['Connect']['Element'])
    Write-Host ("INFO: P11 Connect tab stops: " + (($stops | ForEach-Object { [string]$_.Type + ':' + [string]$_.Name }) -join ' > '))
    Check ($walk.Started) 'P11 the focus can be placed on the Connect pane item' "focused=$([System.Windows.Input.Keyboard]::FocusedElement)"
    Check ($inPage.Count -ge 12 -and $unnamed.Count -eq 0) 'P11 the Connect walk reaches the page and every tab stop has a readable name' "inPage=$($inPage.Count) stops=$($stops.Count) unnamed=[$($unnamed -join ',')]"
    $copyNames = @($stops | Where-Object { $_.Element -is [System.Windows.Controls.Button] -and [string]$_.Element.Content -ceq 'Copy' } | ForEach-Object { [string]$_.Name })
    $distinct = @($copyNames | Sort-Object -Unique)
    Check ($copyNames.Count -eq 7 -and $distinct.Count -eq $copyNames.Count) 'P11 the seven Copy buttons (four fields, the key, two cards) have seven distinct names' "names=[$($copyNames -join ' | ')]"
    Check (@($copyNames | Where-Object { $_ -notmatch '^Copy ' }).Count -eq 0) 'P11 each Copy name says what it copies' "names=[$($copyNames -join ' | ')]"
    # Models: two models, one component and a leftover give the Remove buttons; the start options are expanded so their inputs are stops
    $fx = @(Reset-ModelsFixture)
    [void]$script:leftoverStore.Add([pscustomobject]@{ name = 'probe-leftover.part'; sizeBytes = [int64]1073741824; locked = $false })
    Open-ModelsPage
    $els.ModelsStartOptions.IsExpanded = $true
    Invoke-Pump 200
    $walk = Get-PagesTabWalk $els.NavModels
    $stops = @($walk.Stops)
    $unnamed = @($stops | Where-Object { -not (Test-ShellNameReadable ([string]$_.Name)) } | ForEach-Object { [string]$_.Type })
    $inPage = @(Get-PagesStopsIn $walk $f.Pages['Models']['Element'])
    Write-Host ("INFO: P11 Models tab stops: " + (($stops | ForEach-Object { [string]$_.Type + ':' + [string]$_.Name }) -join ' > '))
    Check ($walk.Started) 'P11 the focus can be placed on the Models pane item' "focused=$([System.Windows.Input.Keyboard]::FocusedElement)"
    Check ($inPage.Count -ge 8 -and $unnamed.Count -eq 0) 'P11 the Models walk reaches the page and every tab stop has a readable name' "inPage=$($inPage.Count) stops=$($stops.Count) unnamed=[$($unnamed -join ',')]"
    $removeNames = @($stops | Where-Object { $_.Element -is [System.Windows.Controls.Button] -and [string]$_.Element.Content -ceq 'Remove' } | ForEach-Object { [string]$_.Name })
    $removeDistinct = @($removeNames | Sort-Object -Unique)
    Check ($removeNames.Count -eq 3 -and $removeDistinct.Count -eq $removeNames.Count) 'P11 the three Remove buttons (two models, one component) are tab stops with three distinct names' "names=[$($removeNames -join ' | ')]"
    Check (@($removeNames | Where-Object { $_ -notmatch '^Remove .' }).Count -eq 0) 'P11 each Remove name says what it removes' "names=[$($removeNames -join ' | ')]"
    Check (@($stops | Where-Object { $_.Element -is [System.Windows.Controls.Primitives.RepeatButton] }).Count -eq 0) 'P11 the spin buttons are not tab stops' "types=[$((@($stops | ForEach-Object { [string]$_.Type }) -join ','))]"
    $namedStops = @($stops | Where-Object { $_.Element -is [System.Windows.DependencyObject] -and $f.Pages['Models']['Element'].IsAncestorOf($_.Element) } | ForEach-Object { [string]$_.Name })
    foreach ($want in 'Model', 'Install and model cache folder', 'Context (0 = catalog default)', 'Resizable BAR workaround', 'Remove leftover partial downloads') {
        Check ($namedStops -ccontains $want) "P11 the Models walk has a stop named $want" "stops=[$($namedStops -join ' | ')]"
    }
    $null = Reset-ModelsFixture
    # Settings (PR 3c): the walk from its pane item (the second list) reaches the page; every stop is named; the spin buttons are not stops; the footer comes last
    $null = Open-SettingsPage
    Invoke-Pump 200
    $walk = Get-PagesTabWalk $els.NavSettings
    $stops = @($walk.Stops)
    $unnamed = @($stops | Where-Object { -not (Test-ShellNameReadable ([string]$_.Name)) } | ForEach-Object { [string]$_.Type })
    $inPage = @(Get-PagesStopsIn $walk $f.Pages['Settings']['Element'])
    Write-Host ("INFO: P11 Settings tab stops: " + (($stops | ForEach-Object { [string]$_.Type + ':' + [string]$_.Name }) -join ' > '))
    Check ($walk.Started) 'P11 the focus can be placed on the Settings pane item' "focused=$([System.Windows.Input.Keyboard]::FocusedElement)"
    Check ($inPage.Count -ge 12 -and $unnamed.Count -eq 0) 'P11 the Settings walk reaches the page (at least 12 stops: the fields, the toggles and the footer) and every tab stop has a readable name' "inPage=$($inPage.Count) stops=$($stops.Count) unnamed=[$($unnamed -join ',')]"
    Check (@($stops | Where-Object { $_.Element -is [System.Windows.Controls.Primitives.RepeatButton] }).Count -eq 0) 'P11 the Settings spin buttons are not tab stops' "types=[$((@($stops | ForEach-Object { [string]$_.Type }) -join ','))]"
    $lastTwo = @($inPage | Select-Object -Last 2)
    Check ($lastTwo.Count -eq 2 -and [object]::ReferenceEquals($lastTwo[0].Element, $els.SettingsSaveButton) -and [object]::ReferenceEquals($lastTwo[1].Element, $els.SettingsDiscardButton)) 'P11 the last two Settings tab stops are Save, then Discard (the footer is last)' "last=[$((@($lastTwo | ForEach-Object { [string]$_.Type + ':' + [string]$_.Name }) -join ' > '))]"
    # The pane's own stops: with Settings current the walk starts in the second list and never visits an item of the first list (one selection, one tab stop)
    $navStops = @($stops | Where-Object { $_.Element -is [System.Windows.Controls.ListBoxItem] })
    Check ($navStops.Count -eq 0) 'P11 no other pane item is a tab stop while Settings is current (the first list is skipped)' "navStops=[$((@($navStops | ForEach-Object { [string]$_.Name }) -join ','))]"
    Close-SettingsPage
    Check-NoExceptions 'P11'
}

function Get-PagesNearestPeer($Element) {
    $up = $Element
    while ($null -ne $up) {
        if ($up -is [System.Windows.UIElement]) {
            $peer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($up)
            if ($null -ne $peer) { return $peer }
        }
        $up = [System.Windows.Media.VisualTreeHelper]::GetParent($up)
    }
    return $null
}

function Test-PagesPuaText([string]$Text) {
    if ($Text.Length -eq 0) { return $false }
    foreach ($c in $Text.ToCharArray()) { if ([int]$c -lt 0xE000 -or [int]$c -gt 0xF8FF) { return $false } }
    return $true
}

# One pane item: its glyph is in the visual tree and visible, is not among the control-view peers, and the item still has a readable name.
function Test-PagesNavGlyphHidden([string]$CheckName, $Element) {
    $glyph = $null
    foreach ($n in @(Get-ShellVisuals $Element)) { if ($n -is [System.Windows.Controls.TextBlock] -and (Test-PagesPuaText ([string]$n.Text))) { $glyph = $n; break } }
    $peer = Get-PagesNearestPeer $Element
    if ($null -eq $peer) { Check $false $CheckName 'no automation peer for the element or any ancestor'; return }
    $name = [string]$peer.GetName()
    $bad = New-Object System.Collections.ArrayList
    foreach ($k in @(Get-ShellControlViewPeers $peer)) {
        if ($k -is [System.Windows.Automation.Peers.UIElementAutomationPeer]) {
            $o = $k.Owner
            if ($o -is [System.Windows.Controls.TextBlock] -and ((Test-PagesPuaText ([string]$o.Text)) -or ($null -ne $glyph -and [object]::ReferenceEquals($o, $glyph)))) { [void]$bad.Add($k.GetType().Name + ':' + [string]$o.Text) }
        }
    }
    $ok = ($null -ne $glyph) -and [bool]$glyph.IsVisible -and ($bad.Count -eq 0) -and (Test-ShellNameReadable $name)
    Check $ok $CheckName "glyphFound=$($null -ne $glyph) glyphVisible=$(if ($null -ne $glyph) { $glyph.IsVisible } else { 'n/a' }) glyphPeersInControlView=[$($bad -join ',')] name='$name'"
}

# The TextBlocks below a root whose text is only private-use glyphs and that are not the decorative type. A glyph that is a part of a named control's own template
# or content presenter (an Expander arrow, a glyph button's content) has a TemplatedParent: the control carries the name, so those are listed, not failed.
function Get-PagesPuaTextBlocks($Root) {
    $loose = New-Object System.Collections.ArrayList
    $templated = New-Object System.Collections.ArrayList
    foreach ($n in @(Get-ShellVisuals $Root)) {
        if ($n -isnot [System.Windows.Controls.TextBlock]) { continue }
        if ($n -is [Bitworks.FastLlm.DecorativeTextBlock]) { continue }
        if (-not (Test-PagesPuaText ([string]$n.Text))) { continue }
        if ($null -ne $n.TemplatedParent) { [void]$templated.Add($n) } else { [void]$loose.Add($n) }
    }
    return [pscustomobject]@{ Loose = $loose.ToArray(); Templated = $templated.ToArray() }
}

function Invoke-P12-ControlView {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Invoke-Pump 150
    $f.Window.UpdateLayout()
    # Every pane item, the disabled ones too (S9 covers Home only)
    foreach ($nav in @($f.NavItems)) { Test-PagesNavGlyphHidden ('P12 nav item ' + [string]$nav['Id'] + ': glyph not in the UIA control view; name present') $nav['Item'] }
    # No loose glyph TextBlock on any page or in the shell
    foreach ($pageId in 'Home', 'Tools', 'Connect', 'Models', 'Settings') {
        $null = Set-FastLlmUiFluentPage -Id $pageId
        Invoke-Pump 150
        $f.Window.UpdateLayout()
        $found = Get-PagesPuaTextBlocks $f.Window
        foreach ($t in @($found.Templated)) { Write-Host ("INFO: P12 $pageId templated glyph TextBlock in a " + $t.TemplatedParent.GetType().Name) }
        Check (@($found.Loose).Count -eq 0) "P12 no non-decorative TextBlock holds a private-use glyph with $pageId hosted" ("loose=" + ((@($found.Loose) | ForEach-Object { [string]$_.Name + ':' + [string]$_.Text.Length }) -join ','))
    }
    # The Models spin buttons draw icon glyphs: they are template or content-presenter parts (listed, not failed), never loose TextBlocks
    $null = Set-FastLlmUiFluentPage -Id 'Models'
    Invoke-Pump 150
    $f.Window.UpdateLayout()
    $modelsGlyphs = Get-PagesPuaTextBlocks $els.ModelsContextRow
    Check (@($modelsGlyphs.Loose).Count -eq 0) 'P12 the Models spin button glyphs are not loose TextBlocks (decorative or template parts)' ("loose=" + ((@($modelsGlyphs.Loose) | ForEach-Object { [string]$_.Name + ':' + [string]$_.Text.Length }) -join ',') + " templated=$(@($modelsGlyphs.Templated).Count)")
    # The Settings spin buttons draw the same icon glyphs: template or content-presenter parts, never loose TextBlocks
    $null = Set-FastLlmUiFluentPage -Id 'Settings'
    Invoke-Pump 150
    $f.Window.UpdateLayout()
    $settingsGlyphs = Get-PagesPuaTextBlocks $els.SettingsPortRow
    Check (@($settingsGlyphs.Loose).Count -eq 0) 'P12 the Settings spin button glyphs are not loose TextBlocks (decorative or template parts)' ("loose=" + ((@($settingsGlyphs.Loose) | ForEach-Object { [string]$_.Name + ':' + [string]$_.Text.Length }) -join ',') + " templated=$(@($settingsGlyphs.Templated).Count)")
    Close-SettingsPage
    # Negative control: a plain TextBlock with a glyph is found by the scan and IS in the control view
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Invoke-Pump 100
    $plain = New-Object System.Windows.Controls.TextBlock
    $plain.Text = [string][char]0xE80F
    [void]$els.QuickPanel.Children.Add($plain)
    try {
        Invoke-Pump 150
        $els.QuickPanel.UpdateLayout()
        $scan = Get-PagesPuaTextBlocks $f.Window
        $scanned = $false
        foreach ($t in @($scan.Loose)) { if ([object]::ReferenceEquals($t, $plain)) { $scanned = $true } }
        $holder = Get-PagesNearestPeer $els.QuickPanel
        $inView = $false
        if ($null -ne $holder) {
            foreach ($k in @(Get-ShellControlViewPeers $holder)) {
                if ($k -is [System.Windows.Automation.Peers.UIElementAutomationPeer] -and [object]::ReferenceEquals($k.Owner, $plain)) { $inView = $true }
            }
        }
        Check ($scanned -and $inView -and [bool]$plain.IsVisible) 'P12 negative control: a plain TextBlock glyph is found by the scan and IS in the UIA control view' "scanned=$scanned inView=$inView visible=$($plain.IsVisible)"
    }
    finally { $els.QuickPanel.Children.Remove($plain) }
    Check-NoExceptions 'P12'
}

# A dialog or box shown over the real window: its owner (GW_OWNER) must be the WPF window handle, the window is disabled while it is up, and the box ladder closes it.
# PR 4a (named test change): the probe takes the id to press and the path the box must have. The side result and the driver guidance are WPF dialogs now and have
# one button, Close (id 'Close': Cancel does not exist there and would only close at the last rung); the SaveFileDialog is still a Win32 box (id 2, 'win32').
function Invoke-PagesOwnerProbe([string]$Tag, [string]$Caption, [scriptblock]$Show, $ButtonId = 2, [string]$ExpectPath = 'win32') {
    $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($script:FastLlmUiFluent.Window).Handle
    $box = @{}
    $t = Start-BoxAnswer $Caption $ButtonId $hwnd $box
    $err = ''
    try { $null = & $Show } catch { $err = $_.Exception.Message } finally { $t.Stop() }
    Invoke-Pump 100
    Write-Host ("INFO: P13 $Tag closed by rung: " + [string]$box.rung)
    Check ($err -eq '' -and $box.found -and -not $box.timedOut -and -not $box.hardStop) "P13 $Tag appeared and the box ladder closed it within 6 s" "error=$err found=$($box.found) timedOut=$($box.timedOut) hardStop=$($box.hardStop) lastRung=$($box.rung)"
    Check ([string]$box.path -ceq $ExpectPath) "P13 $Tag is a $ExpectPath dialog" "path='$($box.path)' expected='$ExpectPath'"
    Check ($box.owner -eq $hwnd.ToInt64()) "P13 $Tag is owned by the WPF window handle" "GW_OWNER=$($box.owner) expected=$($hwnd.ToInt64())"
    Check ($box.during -eq $false) "P13 the WPF window is disabled while $Tag is up" "IsWindowEnabled during=$($box.during)"
}

function Invoke-P13-DialogOwners {
    if (-not $script:shellOk) { return }
    Check (@($script:p13Missing).Count -eq 0) 'P13 ShowUiSideResult and ShowDriverGuidance were found in fast-llm-ui.ps1' ("missing=" + (@($script:p13Missing) -join ','))
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    $win = $script:FastLlmUiFluent.Window
    $null = $win.Activate()
    Invoke-Pump 100
    # SaveFileDialog.ShowDialog($form): a CommonDialog (the support bundle's save dialog), never confirmed
    $script:p13Caption = 'FastLLM pages save ' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    Invoke-PagesOwnerProbe 'SaveFileDialog.ShowDialog($form)' $script:p13Caption {
        $dialog = New-Object System.Windows.Forms.SaveFileDialog
        try {
            $dialog.Title = $script:p13Caption
            $dialog.Filter = 'Zip file (*.zip)|*.zip'
            $dialog.DefaultExt = 'zip'
            $dialog.OverwritePrompt = $false
            [void]$dialog.ShowDialog($script:form)
        }
        finally { $dialog.Dispose() }
    }
    # The driver-guidance form: the real ShowDriverGuidance
    $script:trayAvailability.Clear()
    $script:p13Diagnostic = [pscustomobject]@{ windows = $true; driverGuidance = @([pscustomobject]@{ inputGpuName = 'Probe display device'; knownFocusModel = $false }) }
    Invoke-PagesOwnerProbe 'the driver-guidance form' 'AMD driver guidance - read-only' { ShowDriverGuidance $script:p13Diagnostic } 'Close' 'wpf'
    Check (($script:trayAvailability.ToArray() -join ',') -ceq 'False,True') 'P13 the driver-guidance form turned the tray menu off while open and on again after' "calls=$($script:trayAvailability.ToArray() -join ',')"
    # ShowUiSideResult
    $script:p13Caption = 'FastLLM pages result ' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    Invoke-PagesOwnerProbe 'ShowUiSideResult' $script:p13Caption { ShowUiSideResult $script:p13Caption 'Probe result text' } 'Close' 'wpf'
    Check ($win.IsVisible -and $script:native::IsWindowEnabled([System.Windows.Interop.WindowInteropHelper]::new($win).Handle)) 'P13 the window is open and enabled again after the three dialogs' "visible=$($win.IsVisible)"
    Check-NoExceptions 'P13'
}

# The binding table's order is part of its contract: Home, then the shell, then the pages (Tools, then Models). The REAL table is bound to scratch elements of the
# same types, in order (no throw), and then with the Tools and Models rows first: ToolsAttachButton (Also) binds the Attach adapter, so Home's own Attach row
# finds it bound and throws loudly.
function New-PagesScratchElements([object[]]$Rows) {
    $scratch = @{}
    foreach ($row in $Rows) {
        $type = $script:FastLlmUiFluent.Els[[string]$row.Element].GetType()
        $scratch[[string]$row.Element] = New-Object -TypeName $type.FullName
    }
    return $scratch
}
function Invoke-PagesBindRows([object[]]$Rows, [hashtable]$Scratch) {
    foreach ($row in $Rows) {
        $adapter = Get-Variable -Name ([string]$row.Name) -Scope Script -ValueOnly
        $also = ($row.ContainsKey('Also') -and [bool]$row['Also'])
        try { Connect-FastLlmUiFluentControl -Adapter $adapter -Element $Scratch[[string]$row.Element] -Mode ([string]$row.Mode) -Event ([string]$row.Event) -Flags @($row.Flags) -Also:$also }
        catch { return [pscustomobject]@{ Error = $_.Exception.Message; Element = [string]$row.Element } }
    }
    return [pscustomobject]@{ Error = ''; Element = '' }
}
function Invoke-P15-RealTableOrder {
    if (-not $script:shellOk) { return }
    $homeRows = @(Get-FastLlmUiFluentHomeBindings)
    $table = @(Get-FastLlmUiFluentBindingTable)
    $toolRows = @(Get-FastLlmUiFluentToolsBindings)
    $modelsRows = @(Get-FastLlmUiFluentModelsBindings)
    $settingsRows = @(Get-FastLlmUiFluentSettingsBindings)
    # The shell rows are what lies between the Home rows and the page rows in the table (its order is the contract this step pins)
    $shellRows = @($table | Select-Object -Skip $homeRows.Count -First ($table.Count - $homeRows.Count - $toolRows.Count - $modelsRows.Count - $settingsRows.Count))
    $reversed = @($toolRows) + @($modelsRows) + @($settingsRows) + @($shellRows) + @($homeRows)
    $adapterNames = @(Get-FastLlmUiFluentControlTable | ForEach-Object { [string]$_[0] })
    $saved = @{}
    foreach ($n in $adapterNames) { $saved[$n] = Get-Variable -Name $n -Scope Script -ValueOnly }
    try {
        $tail = @($table | Select-Object -Last $settingsRows.Count)
        $tailSame = ($tail.Count -eq $settingsRows.Count)
        for ($i = 0; $i -lt $tail.Count -and $i -lt $settingsRows.Count; $i++) { if ([string]$tail[$i].Element -cne [string]$settingsRows[$i].Element) { $tailSame = $false } }
        Check ($table.Count -eq ($homeRows.Count + $shellRows.Count + $toolRows.Count + $modelsRows.Count + $settingsRows.Count) -and $toolRows.Count -eq 8 -and $modelsRows.Count -eq 8 -and $settingsRows.Count -eq 6 -and $tailSame -and @($toolRows | Where-Object { $_.ContainsKey('Also') -and [bool]$_['Also'] }).Count -ge 1 -and @($modelsRows | Where-Object { $_.ContainsKey('Also') -and [bool]$_['Also'] }).Count -eq 1 -and @($settingsRows | Where-Object { $_.ContainsKey('Also') -and [bool]$_['Also'] }).Count -eq 2) 'P15 the real table is the Home rows, then the shell rows, then the Tools, Models and Settings rows (the Settings rows last), and each page group carries its Also rows' "table=$($table.Count) home=$($homeRows.Count) shell=$($shellRows.Count) tools=$($toolRows.Count) models=$($modelsRows.Count) settings=$($settingsRows.Count) settingsLast=$tailSame"
        # In order: every row binds
        $null = Initialize-FastLlmUiFluentBindings -InstallRoot $script:InstallRoot -Catalog $script:catalog -UiSettings $script:uiSettings
        $scratch = New-PagesScratchElements $table
        $ok = Invoke-PagesBindRows $table $scratch
        Check ($ok.Error -eq '') 'P15 control: the real table in its pinned order binds every row without a throw' "error=$($ok.Error) at=$($ok.Element)"
        # Reversed by group: the Tools rows first
        $null = Initialize-FastLlmUiFluentBindings -InstallRoot $script:InstallRoot -Catalog $script:catalog -UiSettings $script:uiSettings
        $scratch = New-PagesScratchElements $reversed
        $bad = Invoke-PagesBindRows $reversed $scratch
        Check ($bad.Error -match 'is bound twice' -and $bad.Element -ceq 'AttachButton') 'P15 the Tools and Models rows bound before Home throw loudly: Home Attach row finds its adapter already bound' "error=$($bad.Error) at=$($bad.Element)"
    }
    finally {
        foreach ($n in $adapterNames) { Set-Variable -Name $n -Value $saved[$n] -Scope Script }
    }
    Check-NoExceptions 'P15'
}

# ======================================================================================================================
# PR 3b Task 8: the Models page (P20 to P25). Every check name starts with its step id. The stubs are at the top of the file.
# ======================================================================================================================
$script:p21Events = @{ bar = 0; model = 0; path = 0; barElement = 0 }
$script:p21Attached = $false
$script:p20CopyEvents = 0
$script:p20CopyAttached = $false
function Add-P21Event([string]$Name) { $script:p21Events[$Name]++ }
function Add-P20CopyEvent { $script:p20CopyEvents++ }

# The first catalog models with distinct display names and no ampersand (a caption adapter would strip it), as { id, name }.
function Get-ModelsFixtureModels {
    $out = New-Object System.Collections.ArrayList
    $names = New-Object System.Collections.ArrayList
    foreach ($entry in @($script:catalog.models)) {
        $name = [string](Get-FastLlmModelDisplayName -Model $entry)
        if ($name -ne '' -and $name.IndexOf('&') -lt 0 -and -not $names.Contains($name) -and $out.Count -lt 3) {
            [void]$names.Add($name)
            [void]$out.Add([pscustomobject]@{ id = [string]$entry.id; name = $name })
        }
    }
    return $out.ToArray()
}
$script:modelSizeA = [int64]2684354560
$script:modelSizeB = [int64]3221225472
# Two installed models, one engine component, no leftovers; the lock free. Returns the two fixture models.
function Reset-ModelsFixture {
    $fx = @(Get-ModelsFixtureModels)
    $script:modelsStore.Clear(); $script:componentsStore.Clear(); $script:leftoverStore.Clear()
    $script:modelsLockThrows = $false
    if ($fx.Count -ge 2) {
        [void]$script:modelsStore.Add([pscustomobject]@{ id = [string]$fx[0].id; sizeBytes = $script:modelSizeA; inUse = $false; inUseReason = '' })
        [void]$script:modelsStore.Add([pscustomobject]@{ id = [string]$fx[1].id; sizeBytes = $script:modelSizeB; inUse = $false; inUseReason = '' })
    }
    [void]$script:componentsStore.Add([pscustomobject]@{ id = 'probe-engine'; label = 'probe-engine (engine, 1.0, 12 MB)' })
    Reset-ModelsCounters
    return $fx
}
function Reset-ModelsCounters {
    $script:modelsLog.Clear(); $script:modelsLockHeldSeen.Clear()
    $script:modelsRebuilds = 0; $script:componentsRebuilds = 0; $script:modelsRemoveCalls = 0
    $script:modelsLockDepth = 0; $script:modelsLockMax = 0
    $script:liveRaised.Clear()
}
function Open-ModelsPage {
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    $null = Set-FastLlmUiFluentPage -Id 'Models'
    Invoke-Pump 100
}
# The Remove buttons of a list panel, in row order. They are code-built, so FindName never sees them; the panel's own children are walked in place.
function Get-ModelsRowButtons($Panel) {
    $list = New-Object System.Collections.ArrayList
    foreach ($row in $Panel.Children) {
        if ($row -is [System.Windows.Controls.Grid]) {
            foreach ($cell in $row.Children) { if ($cell -is [System.Windows.Controls.Button]) { [void]$list.Add($cell) } }
        }
    }
    return $list.ToArray()
}
# The texts of a list panel: each row's label, or the one empty-list line.
function Get-ModelsRowTexts($Panel) {
    $list = New-Object System.Collections.ArrayList
    foreach ($row in $Panel.Children) {
        if ($row -is [System.Windows.Controls.Grid]) {
            foreach ($cell in $row.Children) { if ($cell -is [System.Windows.Controls.TextBlock]) { [void]$list.Add([string]$cell.Text) } }
        }
        elseif ($row -is [System.Windows.Controls.TextBlock]) { [void]$list.Add([string]$row.Text) }
    }
    return $list.ToArray()
}
function Get-ModelsLogText { return (@($script:modelsLog.ToArray()) -join ',') }
function Get-ModelsUiMessage([string]$Which) { return [string]$script:FastLlmUiFluent['Models'][$Which].Text }

# Finds a message box by its caption, records its text, then answers it. PR 4a (named test change): the box is now a WPF dialog in fluent mode, so Mode 'click'
# is the harness answerer Start-BoxAnswer (WPF and Win32 ladder, path recorded; ButtonId 6 = Yes, fallback IDNO) and Mode 'enter' presses Enter on either kind:
# a posted VK_RETURN (PostKey on a Win32 box; the activated WPF dialog's PreviewKeyDown for a WPF one), and only if the box is still open 1.5 s later it presses No
# so the suite cannot hang: St['fellBack'] then says Enter did not close it. After 6 s a still-open box is stopped (St['hardStop']). St['path'] is 'wpf' or 'win32'.
function Start-ModelsBox([string]$Caption, [string]$Mode, [int]$ButtonId, [IntPtr]$Hwnd, [hashtable]$St) {
    $St['found'] = $false; $St['text'] = ''; $St['timedOut'] = $false; $St['hardStop'] = $false; $St['fellBack'] = $false; $St['rung'] = ''; $St['path'] = ''; $St['active'] = $false; $St['focus'] = ''
    if ($Mode -cne 'enter') {
        $answer = Start-BoxAnswer $Caption $ButtonId $Hwnd $St -FallbackId 7
        $St['fellBack'] = $false
        return $answer
    }
    $st = $St
    $nat = $script:native
    $findWpf = ${function:Find-PagesWpfBoxAny}
    $wpfRec = ${function:New-PagesWpfRec}
    $wpfKey = ${function:Send-PagesWpfKey}
    $wpfStop = ${function:Stop-PagesWpfBox}
    $wpfButton = ${function:Get-PagesWpfButton}
    $pressBtn = ${function:Invoke-WpfBoxButton}
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $loc = @{ foundAt = [long]0; sentEnter = $false }
    $body = {
        $h = [IntPtr]::Zero
        $wnd = & $findWpf $Hwnd $Caption
        if ($null -eq $wnd) { $h = $nat::FindWindowByTitle($Caption) }
        $ms = $sw.ElapsedMilliseconds
        if ($null -ne $wnd -or $h.ToInt64() -ne 0) {
            if (-not $st['found']) {
                $st['found'] = $true; $loc['foundAt'] = $ms
                if ($null -ne $wnd) { $rec = & $wpfRec $wnd $Caption $Hwnd; $st['text'] = [string]$rec['Text']; $st['path'] = 'wpf'; $st['focus'] = [string]$rec['Focus'] }
                else { $st['text'] = [string]$nat::GetText($h); $st['path'] = 'win32' }
            }
            $age = $ms - [long]$loc['foundAt']
            if ($age -ge 6000) {
                if (-not $st['hardStop']) { $st['hardStop'] = $true; if ($null -ne $wnd) { & $wpfStop $wnd } else { $null = $nat::PostClose($h) } }
            }
            elseif (-not $loc['sentEnter']) {
                $loc['sentEnter'] = $true
                $st['rung'] = 'PostKey VK_RETURN'
                if ($null -ne $wnd) { $null = & $wpfKey $wnd 'Return'; $st['active'] = [bool]$wnd.IsActive } else { $null = $nat::PostKey($h, 0x0D) }
            }
            elseif ($age -ge 1500 -and -not $st['fellBack']) {
                $st['fellBack'] = $true
                $st['rung'] = 'Enter did not close the box; press No'
                if ($null -ne $wnd) { $null = & $pressBtn (& $wpfButton $wnd 7) 0 } else { $null = $nat::PostButtonClick($h, 7) }
            }
        }
        elseif (-not $st['found'] -and $ms -gt 8000) { $st['timedOut'] = $true }
    }.GetNewClosure()
    $wf = New-Object System.Windows.Forms.Timer
    $wf.Interval = 50
    $wf.Add_Tick(({ & $body }).GetNewClosure())
    $dt = New-Object System.Windows.Threading.DispatcherTimer
    $dt.Interval = [TimeSpan]::FromMilliseconds(50)
    $dt.Add_Tick(({ & $body }).GetNewClosure())
    $ctl = New-PagesTimerPair $wf $dt
    $script:objs.Add($ctl)
    $wf.Start()
    $dt.Start()
    return $ctl
}
function Get-ModelsWindowHandle { return [System.Windows.Interop.WindowInteropHelper]::new($script:FastLlmUiFluent.Window).Handle }
# Clicks a code-built or named button the way a mouse click does (the routed Click event) while a box timer answers the confirmation, then pumps so the queued rebuild runs.
function Invoke-ModelsBoxClick($Button, [string]$Caption, [string]$Mode, [hashtable]$St) {
    $timer = Start-ModelsBox $Caption $Mode 6 (Get-ModelsWindowHandle) $St
    try { $Button.RaiseEvent((New-ShellClick $Button ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
    finally { $timer.Stop() }
    Invoke-Pump 300
    # PR 4a (named test change): every Remove confirmation of this helper is a WPF dialog in fluent mode, never a Win32 message box
    Check ([string]$St['path'] -ceq 'wpf') "P22 the '$Caption' box ($Mode) is a WPF dialog, not a Win32 box" ("path='$($St['path'])' expected='wpf' " + (Get-ModelsBoxDetail $St))
}
function Get-ModelsBoxDetail([hashtable]$St) {
    return "found=$($St['found']) path=$($St['path']) timedOut=$($St['timedOut']) hardStop=$($St['hardStop']) fellBack=$($St['fellBack']) rung='$($St['rung'])' text='$($St['text'])'"
}
function ConvertTo-ModelsPlainBoxText([string]$Text) { return $Text.Replace("`r`n", "`n").Trim() }

function Invoke-P20-HomeToModels {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $win = $f.Window
    Check (@($script:p22Missing).Count -eq 0) 'P20 the classic functions the Models steps run (the Remove flows, the two list fills, ReadSelection, GetBarValue) were found in fast-llm-ui.ps1' ("missing=" + (@($script:p22Missing) -join ','))
    Check ($script:barWiringText -ne '') 'P20 the BAR box classic wiring statement was found in fast-llm-ui.ps1' ''
    $fx = @(Reset-ModelsFixture)
    Check ($fx.Count -ge 2) 'P20 the catalog gives two fixture models with distinct display names' "count=$($fx.Count)"
    Check ([bool](Get-NavEntry 'NavModels')['Item'].IsEnabled -and (Get-FastLlmUiFluentPageIdByNav -NavId 'NavModels') -ceq 'Models') 'P20 Models is enabled in the pane and its page is registered' "enabled=$((Get-NavEntry 'NavModels')['Item'].IsEnabled) page='$(Get-FastLlmUiFluentPageIdByNav -NavId 'NavModels')'"
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    $null = $win.Activate()
    Invoke-Pump 100
    foreach ($k in @($script:dialogCalls.Keys)) { $script:dialogCalls[$k] = 0 }
    # Switch model on Home: Models is hosted and its pane item holds the focus
    $els.SwitchButton.RaiseEvent((New-ShellClick $els.SwitchButton ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Invoke-Pump 200
    $focused = [System.Windows.Input.FocusManager]::GetFocusedElement($win)
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Models' -and $els.NavModels.IsSelected -and ([object]::ReferenceEquals($focused, $els.NavModels) -or $els.NavModels.IsKeyboardFocused)) 'P20 Home Switch hosts Models and focuses the NavModels pane item' "current=$(Get-FastLlmUiFluentCurrentPage) navSelected=$($els.NavModels.IsSelected) focused=$(if ($null -ne $focused) { $focused.GetType().Name } else { 'nothing' })"
    # Change: Models is hosted and the model box has the focus
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    $els.ChangeButton.RaiseEvent((New-ShellClick $els.ChangeButton ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Invoke-Pump 200
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Models' -and $els.ModelsModelBox.IsKeyboardFocusWithin) 'P20 Home Change hosts Models and focuses the model box' "current=$(Get-FastLlmUiFluentCurrentPage) boxFocusWithin=$($els.ModelsModelBox.IsKeyboardFocusWithin)"
    # Change while the model box is disabled (a run is active): the focus is never lost, it rests on the Models pane item
    $origModelEnabled = [bool]$script:modelBox.Enabled
    $script:modelBox.Enabled = $false
    Invoke-FastLlmUiFluentTick
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    $els.ChangeButton.RaiseEvent((New-ShellClick $els.ChangeButton ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Invoke-Pump 200
    $focusedOff = [System.Windows.Input.FocusManager]::GetFocusedElement($win)
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Models' -and -not $els.ModelsModelBox.IsEnabled -and ([object]::ReferenceEquals($focusedOff, $els.NavModels) -or $els.NavModels.IsKeyboardFocused)) 'P20 Home Change with the model box disabled hosts Models and leaves the focus on the NavModels pane item' "current=$(Get-FastLlmUiFluentCurrentPage) boxEnabled=$($els.ModelsModelBox.IsEnabled) focused=$(if ($null -ne $focusedOff) { $focusedOff.GetType().Name } else { 'nothing' })"
    $script:modelBox.Enabled = $origModelEnabled
    Invoke-FastLlmUiFluentTick
    # The Models page and its rows never open today's dialogs
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Open-ModelsPage
    Check (($script:dialogCalls['switch'] + $script:dialogCalls['models'] + $script:dialogCalls['components']) -eq 0) 'P20 ShowUiSwitchPicker, ShowModelsWindow and ShowComponentsWindow stay at 0 after Switch, Change and the Models page opening' "switch=$($script:dialogCalls['switch']) models=$($script:dialogCalls['models']) components=$($script:dialogCalls['components'])"
    # Control: each counter can move (the real-shaped wiring of P0 is reached by a raised adapter Click), then it is put back
    $pairs = @(@('switchButton', 'switch'), @('modelsButton', 'models'), @('componentsButton', 'components'), @('chooseButton', 'recipe'))
    foreach ($pair in $pairs) {
        $before = [int]$script:dialogCalls[[string]$pair[1]]
        Invoke-FastLlmUiAdapterEvent -Adapter (Get-Variable -Name ([string]$pair[0]) -Scope Script -ValueOnly) -Event 'Click'
        Check ([int]$script:dialogCalls[[string]$pair[1]] -eq ($before + 1)) "P20 control: a raised $($pair[0]) Click reaches its wired dialog stub once (the counter can move)" "before=$before after=$($script:dialogCalls[[string]$pair[1]])"
        $script:dialogCalls[[string]$pair[1]] = 0
    }
    # The Activity copy button: one adapter LinkClicked per click, and its Visible follows failureCopyLink
    if (-not $script:p20CopyAttached) { [void]$script:failureCopyLink.PSObject.Methods['Add_LinkClicked'].Invoke([scriptblock]::Create('Add-P20CopyEvent')); $script:p20CopyAttached = $true }
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    $origVisible = [bool]$script:failureCopyLink.Visible
    $script:failureCopyLink.Visible = $true
    $copy = $els['ActivityCopyButton']
    Check ($null -ne $copy) 'P20 the Activity copy button is in the element map' ''
    if ($null -ne $copy) {
        $script:p20CopyEvents = 0
        $copy.RaiseEvent((New-ShellClick $copy ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Invoke-Pump 50
        Check ($script:p20CopyEvents -eq 1) 'P20 the Activity copy button raises exactly one LinkClicked per click' "events=$($script:p20CopyEvents)"
        $visibleOn = $copy.Visibility
        $script:failureCopyLink.Visible = $false
        $visibleOff = $copy.Visibility
        $script:failureCopyLink.Visible = $true
        $visibleBack = $copy.Visibility
        Check ($visibleOn -eq [System.Windows.Visibility]::Visible -and $visibleOff -eq [System.Windows.Visibility]::Collapsed -and $visibleBack -eq [System.Windows.Visibility]::Visible) 'P20 the Activity copy button Visible follows failureCopyLink both ways' "on=$visibleOn off=$visibleOff back=$visibleBack"
    }
    $script:failureCopyLink.Visible = $origVisible
    Check-NoExceptions 'P20'
}

# Two-way elements: one write, one adapter event, no echo. A key is routed the way WPF routes it: PreviewKeyDown first (the Number box reads Up, Down and Enter there),
# then KeyDown only if the preview was not marked Handled (the folder box reads Enter in KeyDown). One KeyEventArgs per raise. If the value did not follow, the same key is posted to the window.
function Send-ModelsKey($Element, $Key) {
    $src = [System.Windows.PresentationSource]::FromVisual($Element)
    if ($null -eq $src) { return $false }
    $preview = [System.Windows.Input.KeyEventArgs]::new([System.Windows.Input.Keyboard]::PrimaryDevice, $src, 0, $Key).psobject.BaseObject
    $preview.RoutedEvent = [System.Windows.Input.Keyboard]::PreviewKeyDownEvent
    $Element.RaiseEvent($preview)
    if (-not [bool]$preview.Handled) {
        $down = [System.Windows.Input.KeyEventArgs]::new([System.Windows.Input.Keyboard]::PrimaryDevice, $src, 0, $Key).psobject.BaseObject
        $down.RoutedEvent = [System.Windows.Input.Keyboard]::KeyDownEvent
        $Element.RaiseEvent($down)
    }
    return $true
}
function Send-ModelsKeyChecked($Element, $Key, [int]$Vk, [scriptblock]$Done) {
    $path = 'PreviewKeyDown then KeyDown routed events'
    $threw = ''
    try { $null = Send-ModelsKey $Element $Key } catch { $threw = $_.Exception.Message }
    Invoke-Pump 100
    if (-not [bool](& $Done)) {
        $path = 'PostMessage WM_KEYDOWN to the window (focus on the box)'
        $null = $script:FastLlmUiFluent.Window.Activate()
        $null = $Element.Focus()
        Invoke-Pump 100
        $null = $script:native::PostKey((Get-ModelsWindowHandle), $Vk)
        Invoke-Pump 250
    }
    Write-Host ("INFO: P21 key $Key on $($Element.Name): path used = $path $threw")
    return $path
}
function Invoke-P21-TwoWay {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $fx = @(Reset-ModelsFixture)
    Open-ModelsPage
    $els.ModelsStartOptions.IsExpanded = $true
    Invoke-Pump 150
    if (-not $script:p21Attached) {
        $script:p21Attached = $true
        [void]$script:barBox.PSObject.Methods['Add_SelectedIndexChanged'].Invoke([scriptblock]::Create('Add-P21Event ''bar'''))
        [void]$script:modelBox.PSObject.Methods['Add_SelectedIndexChanged'].Invoke([scriptblock]::Create('Add-P21Event ''model'''))
        [void]$script:pathBox.PSObject.Methods['Add_TextChanged'].Invoke([scriptblock]::Create('Add-P21Event ''path'''))
        $els.ModelsBarBox.Add_SelectionChanged({ $script:p21Events['barElement']++ })
    }
    $origBar = [int]$script:barBox.SelectedIndex
    $origPath = [string]$script:pathBox.Text
    # BAR: one pick is one settings write, one adapter event and one element SelectionChanged (no echo back from the adapter)
    $writes0 = $script:settingsWrites.Count; $bar0 = $script:p21Events['bar']; $el0 = $script:p21Events['barElement']
    $els.ModelsBarBox.SelectedIndex = 2
    Invoke-Pump 50
    $lastWrite = ''; if ($script:settingsWrites.Count -gt 0) { $lastWrite = [string]$script:settingsWrites[$script:settingsWrites.Count - 1] }
    Check (($script:settingsWrites.Count - $writes0) -eq 1 -and $lastWrite -ceq 'off' -and ($script:p21Events['bar'] - $bar0) -eq 1 -and ($script:p21Events['barElement'] - $el0) -eq 1 -and [int]$script:barBox.SelectedIndex -eq 2) 'P21 one BAR pick is one Write-FastLlmUiSettings (off), one adapter event and one element SelectionChanged' "writes=$($script:settingsWrites.Count - $writes0) last='$lastWrite' adapterEvents=$($script:p21Events['bar'] - $bar0) elementEvents=$($script:p21Events['barElement'] - $el0) adapterIndex=$($script:barBox.SelectedIndex)"
    # The orchestration sets the adapter: the element follows and nothing echoes back (one more write and event, from the adapter's own change)
    $writes1 = $script:settingsWrites.Count; $bar1 = $script:p21Events['bar']; $el1 = $script:p21Events['barElement']
    $script:barBox.SelectedIndex = 0
    Invoke-Pump 50
    Check ([int]$els.ModelsBarBox.SelectedIndex -eq 0 -and ($script:settingsWrites.Count - $writes1) -eq 1 -and ($script:p21Events['bar'] - $bar1) -eq 1 -and ($script:p21Events['barElement'] - $el1) -eq 1) 'P21 an adapter BAR set moves the element and echoes nothing back (one write, one adapter event, one element event)' "elementIndex=$($els.ModelsBarBox.SelectedIndex) writes=$($script:settingsWrites.Count - $writes1) adapterEvents=$($script:p21Events['bar'] - $bar1) elementEvents=$($script:p21Events['barElement'] - $el1)"
    $script:barBox.SelectedIndex = $origBar
    Invoke-Pump 50
    # The model pick: the adapter follows and the real ReadSelection puts -ModelId in the arguments
    $pickerIds = @($script:modelBox.Items)
    $model0 = $script:p21Events['model']
    $els.ModelsModelBox.SelectedIndex = 1
    Invoke-Pump 50
    Check ([int]$script:modelBox.SelectedIndex -eq 1 -and ($script:p21Events['model'] - $model0) -eq 1) 'P21 a model pick reaches the adapter once' "adapterIndex=$($script:modelBox.SelectedIndex) events=$($script:p21Events['model'] - $model0)"
    # The context box: typed 40000 and committed with Enter becomes 32768; abc reverts; Up from 32000 steps to 32768
    $ctx = $els.ModelsContextBox
    $ctx.Text = '40000'
    $p1 = Send-ModelsKeyChecked $ctx ([System.Windows.Input.Key]::Return) 0x0D ({ [decimal]$script:contextBox.Value -eq 32768 })
    Check ([decimal]$script:contextBox.Value -eq 32768 -and [string]$ctx.Text -ceq '32768') 'P21 a context typed as 40000 and committed with Enter is 32768 in the adapter and the box' "path=$p1 adapter=$($script:contextBox.Value) text='$($ctx.Text)'"
    $ctx.Text = 'abc'
    $p2 = Send-ModelsKeyChecked $ctx ([System.Windows.Input.Key]::Return) 0x0D ({ [string]$script:FastLlmUiFluent.Els.ModelsContextBox.Text -ceq '32768' })
    Check ([decimal]$script:contextBox.Value -eq 32768 -and [string]$ctx.Text -ceq '32768') 'P21 a context typed as abc reverts to the current value on Enter' "path=$p2 adapter=$($script:contextBox.Value) text='$($ctx.Text)'"
    $script:contextBox.Value = 32000
    Invoke-Pump 50
    Check ([string]$ctx.Text -ceq '32000') 'P21 an adapter Value set shows in the box (no echo write)' "text='$($ctx.Text)' adapter=$($script:contextBox.Value)"
    $p3 = Send-ModelsKeyChecked $ctx ([System.Windows.Input.Key]::Up) 0x26 ({ [decimal]$script:contextBox.Value -eq 32768 })
    Check ([decimal]$script:contextBox.Value -eq 32768 -and [string]$ctx.Text -ceq '32768') 'P21 Up from 32000 steps by the increment to the maximum 32768' "path=$p3 adapter=$($script:contextBox.Value) text='$($ctx.Text)'"
    # The spin buttons step the same way (not tab stops, named)
    $script:contextBox.Value = 1000
    Invoke-Pump 50
    $els.ModelsContextUp.RaiseEvent((New-ShellClick $els.ModelsContextUp ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Invoke-Pump 50
    Check ([decimal]$script:contextBox.Value -eq 2024 -and [string]$ctx.Text -ceq '2024') 'P21 the Increase spin button steps 1000 to 2024' "adapter=$($script:contextBox.Value) text='$($ctx.Text)'"
    $els.ModelsContextDown.RaiseEvent((New-ShellClick $els.ModelsContextDown ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Invoke-Pump 50
    Check ([decimal]$script:contextBox.Value -eq 1000 -and [string]$ctx.Text -ceq '1000') 'P21 the Decrease spin button steps 2024 back to 1000' "adapter=$($script:contextBox.Value) text='$($ctx.Text)'"
    Check ((-not $els.ModelsContextUp.IsTabStop) -and (-not $els.ModelsContextDown.IsTabStop)) 'P21 the spin buttons are not tab stops' "up=$($els.ModelsContextUp.IsTabStop) down=$($els.ModelsContextDown.IsTabStop)"
    # ReadSelection (the real function) reads the three adapters the way a launch does
    $origSelection = $script:selection
    ReadSelection
    $selectionText = (@($script:selection) -join ' ')
    $wantSelection = '-InstallRoot ' + [IO.Path]::GetFullPath($origPath) + ' -ContextSize 1000 -ModelId ' + [string]$pickerIds[1]
    Check ($selectionText -ceq $wantSelection) 'P21 ReadSelection reads the folder, the context and -ModelId from the adapters the elements wrote' "selection='$selectionText' want='$wantSelection'"
    $script:selection = $origSelection
    $script:modelBox.SelectedIndex = 0
    Invoke-Pump 50
    # The folder box: one keystroke is one adapter TextChanged; an adapter set shows in the box and echoes nothing
    $path0 = $script:p21Events['path']
    $els.ModelsFolderBox.Text = $origPath + '-edit'
    Invoke-Pump 50
    Check ([string]$script:pathBox.Text -ceq ($origPath + '-edit') -and ($script:p21Events['path'] - $path0) -eq 1) 'P21 a folder keystroke is one adapter TextChanged' "adapter='$($script:pathBox.Text)' events=$($script:p21Events['path'] - $path0)"
    $path1 = $script:p21Events['path']
    $script:pathBox.Text = $origPath
    Invoke-Pump 50
    Check ([string]$els.ModelsFolderBox.Text -ceq $origPath -and ($script:p21Events['path'] - $path1) -eq 1) 'P21 an adapter folder set shows in the box with exactly one adapter event (no echo)' "element='$($els.ModelsFolderBox.Text)' events=$($script:p21Events['path'] - $path1)"
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Check-NoExceptions 'P21'
}

# The Remove flows run the REAL functions of fast-llm-ui.ps1 (two refresh lines included) against the shadows; the log is one ordered list.
function Invoke-P22-RemoveFlows {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $win = $f.Window
    $hwnd = Get-ModelsWindowHandle
    $fx = @(Reset-ModelsFixture)
    if ($fx.Count -lt 2) { Check $false 'P22 the catalog gives two fixture models' "count=$($fx.Count)"; return }
    $a = $fx[0]; $b = $fx[1]
    $clickEvent = [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent
    Open-ModelsPage
    $buttons = @(Get-ModelsRowButtons $els.ModelsModelRows)
    $buttonDetail = "buttons=$($buttons.Count) tags=$((@($buttons | ForEach-Object { [string]$_.Tag }) -join ','))"
    Check ($buttons.Count -eq 2 -and [string]$buttons[0].Tag -ceq [string]$a.id -and [string]$buttons[1].Tag -ceq [string]$b.id) 'P22 the list has one Remove button per installed model, in store order' $buttonDetail
    if ($buttons.Count -ne 2) { return }
    Check ([System.Windows.Automation.AutomationProperties]::GetName($buttons[0]) -ceq ('Remove ' + [string]$a.name) -and [System.Windows.Automation.AutomationProperties]::GetName($buttons[1]) -ceq ('Remove ' + [string]$b.name) -and [string]$buttons[0].Content -ceq 'Remove') 'P22 each Remove says Remove and is named Remove plus its model' "name0='$([System.Windows.Automation.AutomationProperties]::GetName($buttons[0]))' name1='$([System.Windows.Automation.AutomationProperties]::GetName($buttons[1]))'"
    $btnA = $buttons[0]; $btnB = $buttons[1]
    Reset-ModelsCounters
    # Remove A, then B quickly. A is clicked synchronously (its confirmation answered Yes). B's click is queued at Input priority BEFORE the loop pumps, a model of a
    # click that is already waiting: the queued rebuild (Normal) must run first, then B's confirmation, lock, remove, release and rebuild.
    $boxA = @{}
    $timerA = Start-ModelsBox 'Remove model' 'click' 6 $hwnd $boxA
    try { $btnA.RaiseEvent((New-ShellClick $btnA $clickEvent)) } finally { $timerA.Stop() }
    $afterA = Get-ModelsLogText
    $boxB = @{}
    $timerB = Start-ModelsBox 'Remove model' 'click' 6 $hwnd $boxB
    $clickB = New-ShellClick $btnB $clickEvent
    $blockB = { $btnB.RaiseEvent($clickB) }.GetNewClosure()
    $actionB = [Action]$blockB
    $null = $win.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Input, $actionB)
    try {
        Invoke-Pump 8000 ({ $script:modelsRebuilds -ge 2 })
        Invoke-Pump 300
    }
    finally { $timerB.Stop() }
    $want = @("confirm:$($a.name)", 'lock', "remove:$($a.id)", 'release', 'rebuild', "confirm:$($b.name)", 'lock', "remove:$($b.id)", 'release', 'rebuild') -join ','
    $got = Get-ModelsLogText
    Check ($afterA -ceq "confirm:$($a.name),lock,remove:$($a.id),release") 'P22 after A is clicked synchronously the log is confirm, lock, remove, release and the rebuild is still queued' "log='$afterA'"
    Check ($got -ceq $want) 'P22 remove A then B: confirm A, lock, remove A, release, rebuild, confirm B, lock, remove B, release, rebuild' "log='$got' want='$want'"
    Check ($script:modelsRebuilds -eq 2 -and $script:modelsLockMax -eq 1 -and $script:modelsLockDepth -eq 0) 'P22 exactly 2 rebuilds, the lock never nested (maximum depth 1) and none is left held' "rebuilds=$($script:modelsRebuilds) maxDepth=$($script:modelsLockMax) depth=$($script:modelsLockDepth)"
    Check ((@($script:modelsLockHeldSeen.ToArray() | Where-Object { $_ }).Count -eq 2) -and $script:modelsLockHeldSeen.Count -eq 2) 'P22 both removes were handed the lock with -OperationLockHeld' "seen=$($script:modelsLockHeldSeen -join ',')"
    $texts = @(Get-ModelsRowTexts $els.ModelsModelRows)
    Check ($texts.Count -eq 1 -and [string]$texts[0] -ceq 'No models are downloaded.') 'P22 the list shows no model and No models are downloaded.' "texts=[$($texts -join ' | ')]"
    Check ((Get-ModelsUiMessage 'Message') -ceq "Removed $($b.name)." -and [string]$els.ModelsDownloadedMessage.Text -ceq "Removed $($b.name).") 'P22 the message is Removed and the name of model B' "adapter='$(Get-ModelsUiMessage 'Message')' element='$($els.ModelsDownloadedMessage.Text)'"
    Check ((Get-LiveCount $els.ModelsDownloadedMessage) -eq 2) 'P22 each message change was announced once (A removed, B removed)' "announcements=$(Get-LiveCount $els.ModelsDownloadedMessage)"
    $wantTextA = ConvertTo-ModelsPlainBoxText ([string](& $script:realConfirmText -DisplayName ([string]$a.name) -SizeBytes $script:modelSizeA))
    $wantTextB = ConvertTo-ModelsPlainBoxText ([string](& $script:realConfirmText -DisplayName ([string]$b.name) -SizeBytes $script:modelSizeB))
    Check ((ConvertTo-ModelsPlainBoxText ([string]$boxA['text'])) -ceq $wantTextA -and (ConvertTo-ModelsPlainBoxText ([string]$boxB['text'])) -ceq $wantTextB) 'P22 each box text is Get-FastLlmModelRemovalConfirmationText for its model' "A=$(Get-ModelsBoxDetail $boxA) B=$(Get-ModelsBoxDetail $boxB) wantA='$wantTextA' wantB='$wantTextB'"
    Check ([string]$boxA['path'] -ceq 'wpf' -and [string]$boxB['path'] -ceq 'wpf') 'P22 both Remove model confirmations are WPF dialogs, not Win32 boxes (PR 4a)' "A path='$($boxA['path'])' B path='$($boxB['path'])' expected='wpf'"
    Check ($boxA['found'] -and -not $boxA['hardStop'] -and $boxB['found'] -and -not $boxB['hardStop']) 'P22 both confirmation boxes appeared and were answered within 6 s' "A=$(Get-ModelsBoxDetail $boxA) B=$(Get-ModelsBoxDetail $boxB)"
    # A stale click on A's old button: not-installed text, one rebuild, no confirmation, no lock, no remove
    Reset-ModelsCounters
    $btnA.RaiseEvent((New-ShellClick $btnA $clickEvent))
    Invoke-Pump 300
    Check ((Get-ModelsUiMessage 'Message') -ceq [string](& $script:realRefusalText -Reason 'not-installed') -and (Get-ModelsLogText) -ceq 'rebuild' -and $script:modelsRemoveCalls -eq 0) 'P22 a stale click on a removed model shows the not-installed text with one rebuild, no lock and no remove' "message='$(Get-ModelsUiMessage 'Message')' log='$(Get-ModelsLogText)' removes=$($script:modelsRemoveCalls)"
    Check ((Get-LiveCount $els.ModelsDownloadedMessage) -eq 1) 'P22 the not-installed message was announced once' "announcements=$(Get-LiveCount $els.ModelsDownloadedMessage)"

    # Lock held by another process: the operation-in-progress text, no rebuild, no remove (models and leftovers); the busy sentence and one rebuild (component)
    $refusal = [string](& $script:realRefusalText -Reason 'operation-in-progress')
    $busyComponent = 'FastLLM is busy with another install or start. Try again when it has finished; nothing was removed.'
    $leftover = [pscustomobject]@{ name = 'probe-leftover.part'; sizeBytes = [int64]1073741824; locked = $false }
    $leftoverText = "1 leftover file(s), $(Format-FastLlmModelStoreGigabytes -Bytes ([int64]1073741824)) GB"
    $wantLeftoverBox = "Deletes the leftover partial downloads ($leftoverText) from this PC. Downloaded models are not touched. Continue?"
    $wantComponentBox = "Remove the component 'probe-engine'? Its files are deleted from this PC. You can install it again later."
    $null = Reset-ModelsFixture
    [void]$script:leftoverStore.Add($leftover)
    Open-ModelsPage
    $script:modelsLockThrows = $true
    Reset-ModelsCounters
    $modelButton = @(Get-ModelsRowButtons $els.ModelsModelRows)[0]
    $st = @{}
    Invoke-ModelsBoxClick $modelButton 'Remove model' 'click' $st
    Check ((Get-ModelsLogText) -ceq "confirm:$($a.name),lock-refused" -and $script:modelsRebuilds -eq 0 -and $script:modelsRemoveCalls -eq 0 -and (Get-ModelsUiMessage 'Message') -ceq $refusal) 'P22 model remove with the lock held elsewhere: operation-in-progress text, 0 rebuilds, no remove' "log='$(Get-ModelsLogText)' rebuilds=$($script:modelsRebuilds) removes=$($script:modelsRemoveCalls) message='$(Get-ModelsUiMessage 'Message')'"
    Reset-ModelsCounters
    $st = @{}
    Invoke-ModelsBoxClick $els.ModelsLeftoverButton 'Remove leftover partial downloads' 'click' $st
    Check ((Get-ModelsLogText) -ceq 'lock-refused' -and $script:modelsRebuilds -eq 0 -and $script:modelsRemoveCalls -eq 0 -and (Get-ModelsUiMessage 'Message') -ceq $refusal) 'P22 leftovers remove with the lock held elsewhere: operation-in-progress text, 0 rebuilds, no remove' "log='$(Get-ModelsLogText)' rebuilds=$($script:modelsRebuilds) message='$(Get-ModelsUiMessage 'Message')' box=$(Get-ModelsBoxDetail $st)"
    Check ((ConvertTo-ModelsPlainBoxText ([string]$st['text'])) -ceq (ConvertTo-ModelsPlainBoxText $wantLeftoverBox)) 'P22 the leftovers box text is the classic sentence with the leftover size text' "box=$(Get-ModelsBoxDetail $st) want='$wantLeftoverBox'"
    Reset-ModelsCounters
    $componentButton = @(Get-ModelsRowButtons $els.ModelsComponentRows)[0]
    $st = @{}
    Invoke-ModelsBoxClick $componentButton 'Remove component' 'click' $st
    Check ((Get-ModelsLogText) -ceq 'lock-refused,rebuild-components' -and $script:componentsRebuilds -eq 1 -and $script:modelsRemoveCalls -eq 0 -and (Get-ModelsUiMessage 'ComponentsMessage') -ceq $busyComponent) 'P22 component remove with the lock held elsewhere: the busy sentence and exactly 1 rebuild, no remove' "log='$(Get-ModelsLogText)' componentRebuilds=$($script:componentsRebuilds) removes=$($script:modelsRemoveCalls) message='$(Get-ModelsUiMessage 'ComponentsMessage')'"
    Check ((ConvertTo-ModelsPlainBoxText ([string]$st['text'])) -ceq (ConvertTo-ModelsPlainBoxText $wantComponentBox)) 'P22 the component box text is the classic sentence' "box=$(Get-ModelsBoxDetail $st) want='$wantComponentBox'"
    $script:modelsLockThrows = $false

    # Enter on each confirmation is No (Button2): nothing is locked, removed or rebuilt
    $null = Reset-ModelsFixture
    [void]$script:leftoverStore.Add($leftover)
    Open-ModelsPage
    Reset-ModelsCounters
    $st = @{}
    Invoke-ModelsBoxClick (@(Get-ModelsRowButtons $els.ModelsModelRows)[0]) 'Remove model' 'enter' $st
    Check ((Get-ModelsLogText) -ceq "confirm:$($a.name)" -and $script:modelsRebuilds -eq 0 -and $script:modelsRemoveCalls -eq 0 -and $st['found'] -and -not $st['fellBack'] -and -not $st['hardStop']) 'P22 Enter on the model confirmation is No: no lock, no remove, 0 rebuilds' "log='$(Get-ModelsLogText)' $(Get-ModelsBoxDetail $st)"
    Reset-ModelsCounters
    $st = @{}
    Invoke-ModelsBoxClick $els.ModelsLeftoverButton 'Remove leftover partial downloads' 'enter' $st
    Check ((Get-ModelsLogText) -ceq '' -and $script:modelsRebuilds -eq 0 -and $st['found'] -and -not $st['fellBack'] -and -not $st['hardStop']) 'P22 Enter on the leftovers confirmation is No: no lock, no remove, 0 rebuilds' "log='$(Get-ModelsLogText)' $(Get-ModelsBoxDetail $st)"
    Reset-ModelsCounters
    $st = @{}
    Invoke-ModelsBoxClick (@(Get-ModelsRowButtons $els.ModelsComponentRows)[0]) 'Remove component' 'enter' $st
    Check ((Get-ModelsLogText) -ceq '' -and $script:componentsRebuilds -eq 0 -and $st['found'] -and -not $st['fellBack'] -and -not $st['hardStop']) 'P22 Enter on the component confirmation is No: no lock, no remove, 0 rebuilds' "log='$(Get-ModelsLogText)' $(Get-ModelsBoxDetail $st)"

    # Yes on leftovers and on the component: the removes run under the lock and rebuild once
    Reset-ModelsCounters
    $st = @{}
    Invoke-ModelsBoxClick $els.ModelsLeftoverButton 'Remove leftover partial downloads' 'click' $st
    Check ((Get-ModelsLogText) -ceq 'lock,remove-leftovers:probe-leftover.part,release,rebuild' -and $script:modelsRebuilds -eq 1 -and (Get-ModelsUiMessage 'Message') -ceq 'Removed 1 leftover file(s).' -and ((ConvertTo-ModelsPlainBoxText ([string]$st['text'])) -ceq (ConvertTo-ModelsPlainBoxText $wantLeftoverBox))) 'P22 leftovers Yes: lock, remove, release, one rebuild and the Removed text' "log='$(Get-ModelsLogText)' rebuilds=$($script:modelsRebuilds) message='$(Get-ModelsUiMessage 'Message')' $(Get-ModelsBoxDetail $st)"
    Reset-ModelsCounters
    $st = @{}
    Invoke-ModelsBoxClick (@(Get-ModelsRowButtons $els.ModelsComponentRows)[0]) 'Remove component' 'click' $st
    Check ((Get-ModelsLogText) -ceq 'lock,remove-component:probe-engine,release,rebuild-components' -and $script:componentsRebuilds -eq 1 -and (Get-ModelsUiMessage 'ComponentsMessage') -ceq "Removed 'probe-engine'.") 'P22 component Yes: lock, remove, release, one rebuild and the Removed text' "log='$(Get-ModelsLogText)' rebuilds=$($script:componentsRebuilds) message='$(Get-ModelsUiMessage 'ComponentsMessage')'"
    $componentTexts = @(Get-ModelsRowTexts $els.ModelsComponentRows)
    Check ($componentTexts.Count -eq 1 -and [string]$componentTexts[0] -ceq 'No engine components are installed.') 'P22 the component list then shows No engine components are installed.' "texts=[$($componentTexts -join ' | ')]"
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Check-NoExceptions 'P22'
}

# The switch picker is computed on page open and on the Switch button's availability edge, never by an ordinary tick.
function Invoke-P23-Picker {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $null = Reset-ModelsFixture
    $script:pickerItems = @(
        [pscustomobject]@{ id = 'probe-switch-a'; text = 'Probe A  -  fits'; canSwitch = $true },
        [pscustomobject]@{ id = 'probe-switch-b'; text = 'Probe B  -  does not fit'; canSwitch = $false })
    $script:pickerMessage = ''
    $script:pickRequests.Clear()
    $origSwitch = [bool]$script:switchButton.Enabled
    $origStatus = [string]$script:statusLabel.Text
    $script:shellSnap = New-ShellSnap
    $script:switchButton.Enabled = $true
    $script:pickerCalls = 0
    Open-ModelsPage
    Check ($script:pickerCalls -eq 1 -and $els.ModelsSwitchList.Items.Count -eq 2) 'P23 entering Models with switching on computes the picker once and lists its items' "calls=$($script:pickerCalls) items=$($els.ModelsSwitchList.Items.Count)"
    for ($i = 0; $i -lt 40; $i++) { Invoke-FastLlmUiFluentTick }
    Check ($script:pickerCalls -eq 1) 'P23 40 ordinary ticks do not compute the picker again' "calls=$($script:pickerCalls)"
    Open-ModelsPage
    Check ($script:pickerCalls -eq 2) 'P23 leaving and entering the page computes it once more' "calls=$($script:pickerCalls)"
    $script:switchButton.Enabled = $false
    Invoke-FastLlmUiFluentTick
    Check ($script:pickerCalls -eq 2 -and $els.ModelsSwitchList.Items.Count -eq 0 -and -not $els.ModelsSwitchNow.IsEnabled) 'P23 switching turned off empties the list without a store read' "calls=$($script:pickerCalls) items=$($els.ModelsSwitchList.Items.Count) switchEnabled=$($els.ModelsSwitchNow.IsEnabled)"
    $script:switchButton.Enabled = $true
    Invoke-FastLlmUiFluentTick
    Check ($script:pickerCalls -eq 3 -and $els.ModelsSwitchList.Items.Count -eq 2) 'P23 switching turned off and on again while shown computes the picker once (the edge)' "calls=$($script:pickerCalls) items=$($els.ModelsSwitchList.Items.Count)"
    for ($i = 0; $i -lt 10; $i++) { Invoke-FastLlmUiFluentTick }
    Check ($script:pickerCalls -eq 3) 'P23 ticks after the edge compute nothing' "calls=$($script:pickerCalls)"
    # Selection drives the Switch button; a row that cannot be switched to keeps it off
    Check (-not $els.ModelsSwitchNow.IsEnabled) 'P23 Switch is off while nothing is selected' "enabled=$($els.ModelsSwitchNow.IsEnabled)"
    $els.ModelsSwitchList.SelectedIndex = 1
    Invoke-Pump 50
    Check (-not $els.ModelsSwitchNow.IsEnabled) 'P23 Switch stays off on a row that cannot be switched to' "enabled=$($els.ModelsSwitchNow.IsEnabled)"
    $els.ModelsSwitchList.SelectedIndex = 0
    Invoke-Pump 50
    Check ($els.ModelsSwitchNow.IsEnabled) 'P23 Switch is on for a row that can be switched to' "enabled=$($els.ModelsSwitchNow.IsEnabled)"
    $els.ModelsSwitchNow.RaiseEvent((New-ShellClick $els.ModelsSwitchNow ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Invoke-Pump 100
    $wantText = 'Switch to probe-switch-a requested (probe).'
    Check ($script:pickRequests.Count -eq 1 -and [string]$script:pickRequests[0] -ceq 'probe-switch-a' -and (Get-ModelsUiMessage 'SwitchMessage') -ceq $wantText -and [string]$script:statusLabel.Text -ceq $wantText -and [string]$els.ModelsSwitchMessage.Text -ceq $wantText) 'P23 Switch runs Invoke-FastLlmUiSwitchPick once with the picked id and sets the picker message and the status text' "requests=$($script:pickRequests -join ',') message='$(Get-ModelsUiMessage 'SwitchMessage')' status='$($script:statusLabel.Text)' element='$($els.ModelsSwitchMessage.Text)'"
    Check (-not $els.ModelsSwitchNow.IsEnabled) 'P23 Switch is disabled after a successful request until the next computation' "enabled=$($els.ModelsSwitchNow.IsEnabled)"
    $els.ModelsSwitchList.SelectedIndex = -1
    Invoke-Pump 30
    $els.ModelsSwitchList.SelectedIndex = 0
    Invoke-Pump 30
    for ($i = 0; $i -lt 5; $i++) { Invoke-FastLlmUiFluentTick }
    Check (-not $els.ModelsSwitchNow.IsEnabled -and $script:pickerCalls -eq 3) 'P23 reselecting the row and ticking does not re-enable Switch or recompute' "enabled=$($els.ModelsSwitchNow.IsEnabled) calls=$($script:pickerCalls)"
    Open-ModelsPage
    $els.ModelsSwitchList.SelectedIndex = 0
    Invoke-Pump 50
    Check ($script:pickerCalls -eq 4 -and $els.ModelsSwitchNow.IsEnabled) 'P23 the next computation (page opened again) makes Switch available again' "calls=$($script:pickerCalls) enabled=$($els.ModelsSwitchNow.IsEnabled)"
    # The switch-off edge after a successful request (the real request disables the Switch button) keeps the request's result: no empty message, no empty announcement
    $els.ModelsSwitchList.SelectedIndex = 0
    Invoke-Pump 50
    $els.ModelsSwitchNow.RaiseEvent((New-ShellClick $els.ModelsSwitchNow ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Invoke-Pump 100
    $live0 = Get-LiveCount $els.ModelsSwitchMessage
    $script:switchButton.Enabled = $false
    for ($i = 0; $i -lt 3; $i++) { Invoke-FastLlmUiFluentTick }
    Check ((Get-ModelsUiMessage 'SwitchMessage') -ceq $wantText -and [string]$els.ModelsSwitchMessage.Text -ceq $wantText -and (Get-LiveCount $els.ModelsSwitchMessage) -eq $live0 -and $els.ModelsSwitchList.Items.Count -eq 0) 'P23 the switch-off edge after a request keeps its message and announces nothing new' "message='$(Get-ModelsUiMessage 'SwitchMessage')' element='$($els.ModelsSwitchMessage.Text)' announcements=$(Get-LiveCount $els.ModelsSwitchMessage) before=$live0 items=$($els.ModelsSwitchList.Items.Count)"
    $script:switchButton.Enabled = $origSwitch
    $script:statusLabel.Text = $origStatus
    $script:pickerItems = @()
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Check-NoExceptions 'P23'
}

function Invoke-P24-Reasons {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $s = $script:FastLlmUiFluentStrings
    $null = Reset-ModelsFixture
    Open-ModelsPage
    $choose = $script:chooseButton
    $btn = $els.ModelsChooseButton
    $origChoose = [bool]$choose.Enabled
    Check ([System.Windows.Controls.ToolTipService]::GetShowOnDisabled($btn) -and [System.Windows.Controls.ToolTipService]::GetShowOnDisabled($els.ModelsModelBox)) 'P24 Choose and the inputs show their tooltip while disabled' ''
    $cases = @(
        @{ Name = 'before a preview'; Snap = @{}; Want = [string]$s.WhyNoPreview },
        @{ Name = 'busy'; Snap = @{ Busy = $true }; Want = [string]$s.WhyBusy },
        @{ Name = 'occupied by a background run'; Snap = @{ Background = 'starting-own' }; Want = [string]$s.WhyBackgroundRun })
    foreach ($case in $cases) {
        $script:shellSnap = New-ShellSnap $case.Snap
        $choose.Enabled = $false
        Invoke-FastLlmUiFluentTick
        $help = [System.Windows.Automation.AutomationProperties]::GetHelpText($btn)
        Check ([string]$btn.ToolTip -ceq [string]$case.Want -and $help -ceq [string]$case.Want) "P24 Choose another setup $($case.Name) says why ($($case.Want))" "tip='$($btn.ToolTip)' help='$help' code='$(Get-FastLlmUiGreyedReason -Action 'chooseSetup' -Snapshot $script:shellSnap)'"
    }
    $script:shellSnap = New-ShellSnap @{ PreviewReady = $true }
    $choose.Enabled = $true
    Invoke-FastLlmUiFluentTick
    Check ($null -eq $btn.ToolTip -and [System.Windows.Automation.AutomationProperties]::GetHelpText($btn) -ceq '' -and $btn.IsEnabled) 'P24 Choose another setup is enabled with no reason once a preview is ready' "enabled=$($btn.IsEnabled) tip='$($btn.ToolTip)'"
    $script:dialogCalls['recipe'] = 0
    $btn.RaiseEvent((New-ShellClick $btn ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Invoke-Pump 100
    Check ($script:dialogCalls['recipe'] -eq 1) 'P24 a Choose click runs StartRecipeList once' "calls=$($script:dialogCalls['recipe'])"
    $script:dialogCalls['recipe'] = 0
    # The four inputs while a child runs
    $script:shellSnap = New-ShellSnap @{ Busy = $true; ChildActive = $true; Step = 'model download' }
    $inputs = @(@('modelBox', 'ModelsModelBox'), @('pathBox', 'ModelsFolderBox'), @('contextBox', 'ModelsContextBox'), @('barBox', 'ModelsBarBox'))
    $origEnabled = @{}
    foreach ($pair in $inputs) { $adapter = Get-Variable -Name ([string]$pair[0]) -Scope Script -ValueOnly; $origEnabled[[string]$pair[0]] = [bool]$adapter.Enabled; $adapter.Enabled = $false }
    Invoke-FastLlmUiFluentTick
    foreach ($pair in $inputs) {
        $el = $els[[string]$pair[1]]
        $help = [System.Windows.Automation.AutomationProperties]::GetHelpText($el)
        Check ((-not $el.IsEnabled) -and [string]$el.ToolTip -ceq [string]$s.WhyBusy -and $help -ceq [string]$s.WhyBusy) "P24 $($pair[1]) is disabled and says WhyBusy while a child runs" "enabled=$($el.IsEnabled) tip='$($el.ToolTip)' help='$help'"
    }
    $script:shellSnap = New-ShellSnap
    foreach ($pair in $inputs) { (Get-Variable -Name ([string]$pair[0]) -Scope Script -ValueOnly).Enabled = $origEnabled[[string]$pair[0]] }
    Invoke-FastLlmUiFluentTick
    foreach ($pair in $inputs) {
        $el = $els[[string]$pair[1]]
        Check ($el.IsEnabled -and $null -eq $el.ToolTip -and [System.Windows.Automation.AutomationProperties]::GetHelpText($el) -ceq '') "P24 $($pair[1]) is enabled again and shows no reason" "enabled=$($el.IsEnabled) tip='$($el.ToolTip)'"
    }
    $choose.Enabled = $origChoose
    $script:shellSnap = New-ShellSnap
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Check-NoExceptions 'P24'
}

function Invoke-P25-DisabledRows {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $s = $script:FastLlmUiFluentStrings
    $fx = @(Reset-ModelsFixture)
    if ($fx.Count -lt 2) { Check $false 'P25 the catalog gives two fixture models' "count=$($fx.Count)"; return }
    # No leftovers: the button is disabled and says why. The second model is in use: its Remove is disabled with the reason as help text.
    $script:modelsStore[1].inUse = $true
    $script:modelsStore[1].inUseReason = 'serving'
    Open-ModelsPage
    $left = $els.ModelsLeftoverButton
    $leftHelp = [System.Windows.Automation.AutomationProperties]::GetHelpText($left)
    Check ((-not $left.IsEnabled) -and [string]$left.ToolTip -ceq [string]$s.WhyNoLeftovers -and $leftHelp -ceq [string]$s.WhyNoLeftovers -and [System.Windows.Controls.ToolTipService]::GetShowOnDisabled($left)) 'P25 the leftover button with no leftovers is disabled and says WhyNoLeftovers' "enabled=$($left.IsEnabled) tip='$($left.ToolTip)' help='$leftHelp'"
    $buttons = @(Get-ModelsRowButtons $els.ModelsModelRows)
    Check ($buttons.Count -eq 2) 'P25 two model rows' "buttons=$($buttons.Count)"
    if ($buttons.Count -eq 2) {
        $help0 = [System.Windows.Automation.AutomationProperties]::GetHelpText($buttons[0])
        $help1 = [System.Windows.Automation.AutomationProperties]::GetHelpText($buttons[1])
        Check ($buttons[0].IsEnabled -and $null -eq $buttons[0].ToolTip -and $help0 -ceq '') 'P25 the model that is not in use has an enabled Remove with no reason' "enabled=$($buttons[0].IsEnabled) tip='$($buttons[0].ToolTip)' help='$help0'"
        Check ((-not $buttons[1].IsEnabled) -and [string]$buttons[1].ToolTip -ceq 'serving' -and $help1 -ceq 'serving' -and [System.Windows.Controls.ToolTipService]::GetShowOnDisabled($buttons[1])) 'P25 the in-use model has a disabled Remove with its reason as tooltip and help text' "enabled=$($buttons[1].IsEnabled) tip='$($buttons[1].ToolTip)' help='$help1'"
        $texts = @(Get-ModelsRowTexts $els.ModelsModelRows)
        Check ($texts.Count -eq 2 -and [string]$texts[1] -ceq ("$($fx[1].name)  -  $(Format-FastLlmModelStoreGigabytes -Bytes $script:modelSizeB) GB  (in use: serving)")) 'P25 the in-use row text is the classic row text with (in use: reason)' "texts=[$($texts -join ' | ')]"
    }
    # With a leftover the button turns on and the reason goes
    [void]$script:leftoverStore.Add([pscustomobject]@{ name = 'probe-leftover.part'; sizeBytes = [int64]1073741824; locked = $false })
    Open-ModelsPage
    Check ($left.IsEnabled -and $null -eq $left.ToolTip -and [System.Windows.Automation.AutomationProperties]::GetHelpText($left) -ceq '') 'P25 with a leftover the button is enabled and shows no reason' "enabled=$($left.IsEnabled) tip='$($left.ToolTip)'"
    $null = Reset-ModelsFixture
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Check-NoExceptions 'P25'
}

# ======================================================================================================================
# PR 3c Task 6: the Settings page (P30 to P36). Every check name starts with its step id. The stand-ins are at the top of the file (the "Settings page's
# orchestration stand-ins" block); the effect log holds only the writes, in call order.
# ======================================================================================================================
$script:p35Attached = $false
function Get-SettingsEls { return $script:FastLlmUiFluent.Els }
function Get-SettingsState { return $script:FastLlmUiFluent['Settings'] }
function Get-SettingsLogText { return (@($script:setLog.ToArray()) -join ',') }

# The stores, the toggles' write lists, the snapshot and the adapters back to a quiet, available start. The key is known (off) unless the case says otherwise.
function Reset-SettingsFixture([hashtable]$O = @{}) {
    $fx = @{ serverPort = 8080; thinking = 'auto'; chatPage = 'off'; idleStopMinutes = 0; apiKey = 'off'; apiKeyUndetermined = $false
        contextProfile = 'default'; slots = 1; embeddings = 'off'; embeddingPort = 8081; embAvail = $false; longMeasured = $false }
    foreach ($k in $O.Keys) { $fx[$k] = $O[$k] }
    $script:setFx = $fx
    $script:setLog.Clear(); $script:setSignInSets.Clear(); $script:setUpdateWrites.Clear(); $script:setExpWrites.Clear(); $script:setLicWrites.Clear(); $script:setExpEvents.Clear()
    $script:setReads = 0; $script:setLastServing = $null; $script:setLastNew = $null; $script:setAllowStored = $null
    $script:setApiUnavailable = $false; $script:setRotateThrows = ''; $script:setRefreshThrows = 0
    $script:setSignInChecked = $false; $script:setSignInReads = 0; $script:setSignInReadThrows = $false; $script:setSignInSetThrows = $false
    $script:uiSettings.allowSwitch = $false
    $script:child = $null
    # The Models page's Context (the value ReadSelection reads): 0 unless a fixture sets 'context' (a Context above 0 disables Long and 2).
    $script:contextBox.Value = [decimal]$(if ($fx.ContainsKey('context')) { $fx['context'] } else { 0 })
    $script:bgState = Get-UiBackgroundFixture -Name 'none'
    $script:shellSnap = New-ShellSnap
    $script:settingsButton.Enabled = $true
    $script:shellFailMsg = ''
    $script:trayAvailability.Clear()
}
# Edits are never left behind: the held edits are dropped, the page goes back to Home (a clean leave never prompts).
function Close-SettingsPage {
    $st = Get-SettingsState
    if ($null -ne $st -and $null -ne $st['Held']) { Invoke-FastLlmUiFluentSettingsDiscard }
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Invoke-Pump 50
}
function Open-SettingsPage([hashtable]$Fixture = @{}) {
    $null = Close-SettingsPage
    Reset-SettingsFixture $Fixture
    $opened = [bool](Set-FastLlmUiFluentPage -Id 'Settings')
    Invoke-Pump 100
    return $opened
}

# ---- the dialog driver: ONE WinForms timer answers a list of expected dialogs, in order ----
# Steps: @{ Kind = 'prompt'; Action = 'Save' | 'Dont' | 'Cancel' | 'Escape' | 'Enter' } (the page's save prompt, a fluent dialog told apart by its DontSave button
# from a message box that has the same caption because each step starts only after the one before it is gone), @{ Kind = 'box'; Caption; Id; Fallback; Key } (a native
# box or form by its caption: press button Id, then the ladder BM_CLICK id, WM_COMMAND id, WM_COMMAND Fallback, WM_CLOSE; with Key, post that key first and press
# Fallback at 1.5 s), and the last step @{ Kind = 'watch' } which answers anything the case did NOT expect (Cancel on a prompt, OK on a box) and counts it, so an
# unexpected modal can never hang the suite. Each found dialog leaves a record in $St['recs'].
# ---- PR 4a (named test change): the box answerers meet WPF dialogs ----
# In fluent mode every routed message box is a WPF Window (Show-FastLlmUiFluentMessageBox), so the Win32-only ladders below (FindWindowByTitle, GetDlgItem, BM_CLICK,
# WM_COMMAND, WM_CLOSE) would never close it, and a YesNo dialog refuses WM_CLOSE. These file-level helpers give each answerer a WPF branch; the Win32 branch stays for
# the native forms (the licence confirmation, the WinForms prompt, the SaveFileDialog). A WPF dialog is found below the main window, else by its title through HwndSource.
# A pair of timers (WinForms and Dispatcher) that stop and dispose together, as the harness answerer returns.
function New-PagesTimerPair($Forms, $Disp) {
    $ctl = [pscustomobject]@{ Forms = $Forms; Disp = $Disp }
    Add-Member -InputObject $ctl -MemberType ScriptMethod -Name Stop -Value { try { $this.Forms.Stop() } catch { $null = $_ }; try { $this.Disp.Stop() } catch { $null = $_ } }
    Add-Member -InputObject $ctl -MemberType ScriptMethod -Name Dispose -Value { try { $this.Disp.Stop() } catch { $null = $_ }; try { $this.Forms.Dispose() } catch { $null = $_ } }
    return $ctl
}
function Find-PagesWpfBoxAny([IntPtr]$MainHwnd, [string]$Caption) {
    $w = Find-WpfBox $MainHwnd $Caption
    if ($null -ne $w) { return $w }
    try {
        $h = $script:native::FindWindowByTitle($Caption)
        if ($h.ToInt64() -ne 0) {
            $src = [System.Windows.Interop.HwndSource]::FromHwnd($h)
            if ($null -ne $src -and $src.RootVisual -is [System.Windows.Window] -and $src.RootVisual.IsVisible) { return $src.RootVisual }
        }
    }
    catch { $null = $_ }
    return $null
}
# The button of a WPF box for a Win32-style id: 1 OK, 2 Cancel, 6 Yes, 7 No, or a custom id. Ids 1 and 2 both close an OK box in Win32, so a missing one falls to the other.
function Get-PagesWpfButton($Wnd, $Id) {
    $b = Find-WpfBoxButton $Wnd (ConvertTo-WpfBoxKey $Id)
    if ($null -ne $b) { return $b }
    if ([string]$Id -eq '1' -or [string]$Id -eq '2') {
        foreach ($alt in @('OK', 'Cancel')) { $b = Find-WpfBoxButton $Wnd $alt; if ($null -ne $b) { return $b } }
    }
    return $null
}
# The last rung for a WPF box that would not answer: press No, Cancel or OK (never Yes). A bare Window.Close is refused by a YesNo box, so when no button is found
# the dialog's own result is set first and then it is closed.
function Stop-PagesWpfBox($Wnd) {
    foreach ($k in @('No', 'Cancel', 'OK', 'Close')) {
        $b = Find-WpfBoxButton $Wnd $k
        if ($null -ne $b -and (Invoke-WpfBoxButton $b 1)) { return }
    }
    try {
        $tag = $Wnd.Tag
        if ($tag -is [System.Collections.IDictionary] -and $tag.Contains('State') -and [string]$tag['State']['Result'] -ceq '') { $tag['State']['Result'] = 'No' }
        $Wnd.Close()
    }
    catch { $null = $_ }
}
# Posts Enter or Escape to a WPF dialog after activating it (a posted key reaches WPF only when the dialog is the active input source).
function Send-PagesWpfKey($Wnd, [string]$Key) {
    try { $null = $Wnd.Activate() } catch { $null = $_ }
    return [bool](Send-DialogKey $Key -Dialog $Wnd)
}
# Where the keyboard focus is in a WPF dialog (the logical focus, which is set whether or not the window is active): the element's type and name, the id of the
# footer button it is, and whether it is the driver-guidance device list or inside it.
function Get-PagesWpfFocusInfo($Wnd) {
    $out = @{ Text = ''; Id = ''; InDevices = $false }
    try {
        $fe = [System.Windows.Input.FocusManager]::GetFocusedElement($Wnd)
        if ($null -eq $fe) { return $out }
        $out['Text'] = $fe.GetType().Name + ':' + [string]$fe.Name
        $map = Get-WpfBoxTagMap $Wnd 'Buttons'
        if ($map -is [System.Collections.IDictionary]) {
            foreach ($k in @($map.Keys)) { if ([object]::ReferenceEquals($map[$k], $fe)) { $out['Id'] = [string]$k } }
        }
        $node = $fe
        while ($null -ne $node -and $node -is [System.Windows.Media.Visual]) {
            if ($node -is [System.Windows.FrameworkElement] -and [string]$node.Name -ceq 'DriverDevice') { $out['InDevices'] = $true; break }
            $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node)
        }
    }
    catch { $null = $_ }
    return $out
}
# The answer record of a WPF box when it first appears (the same fields the Win32 record has, plus Path and the focus facts).
function New-PagesWpfRec($Wnd, [string]$Caption, [IntPtr]$MainHwnd) {
    $dh = [System.Windows.Interop.WindowInteropHelper]::new($Wnd).Handle
    $focus = ''
    try { $fe = [System.Windows.Input.FocusManager]::GetFocusedElement($Wnd); if ($null -ne $fe) { $focus = $fe.GetType().Name + ':' + [string]$fe.Name } } catch { $null = $_ }
    # PR 4b (named test change): the record also says which window owns the dialog and whether that owner is disabled while the dialog is open (a link-error box over a dialog).
    $ownerTitle = ''
    $ownerEnabled = $true
    try { $ownerWindow = $Wnd.Owner; if ($null -ne $ownerWindow) { $ownerTitle = [string]$ownerWindow.Title; $ownerEnabled = [bool]$script:native::IsWindowEnabled([System.Windows.Interop.WindowInteropHelper]::new($ownerWindow).Handle) } } catch { $null = $_ }
    return @{ Kind = 'box'; Found = $true; Path = 'wpf'; Caption = $Caption; Text = [string](Get-WpfBoxText $Wnd); Owner = $script:native::GetOwner($dh).ToInt64()
        WpfEnabledDuring = [bool]$script:native::IsWindowEnabled($MainHwnd)
        OwnerTitle = $ownerTitle; OwnerWindowEnabled = $ownerEnabled
        HasYes = ($null -ne (Find-WpfBoxButton $Wnd 'Yes')); HasOk = ($null -ne (Find-WpfBoxButton $Wnd 'OK')); HasCancel = ($null -ne (Find-WpfBoxButton $Wnd 'Cancel'))
        Focus = $focus; Rung = ''; FellBack = $false; Closed = $false; Id = [long][System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($Wnd) }
}

# PR 4b (named test change): the Settings save prompt is a fluent dialog on the dialog host, so the three WinForms helpers that found it in Application.OpenForms and read its
# controls (Find-SettingsPrompt, Get-SettingsPromptButton, Get-SettingsPromptInfo) are gone. A dialog is the prompt when it has a DontSave button (the message box with the same
# caption has none). Its facts are read from the dialog's own tables: the body is the TextBlock (Els Body), the caption of a button is its automation name.
function Test-PagesIsSavePrompt($Wnd) {
    $map = Get-WpfBoxTagMap $Wnd 'Buttons'
    return [bool]($map -is [System.Collections.IDictionary] -and $map.Contains('DontSave') -and $map.Contains('Save') -and $map.Contains('Cancel'))
}
function Get-PagesButtonCaption($Button) {
    if ($null -eq $Button) { return '' }
    return [string][System.Windows.Automation.AutomationProperties]::GetName($Button)
}
function Get-PagesPromptInfo($Wnd) {
    $buttons = New-Object System.Collections.ArrayList
    $map = Get-WpfBoxTagMap $Wnd 'Buttons'
    foreach ($k in @($map.Keys)) { [void]$buttons.Add((Get-PagesButtonCaption $map[$k])) }
    $sorted = @($buttons.ToArray() | Sort-Object { [string]$_ } -CaseSensitive)
    $body = ''
    $els = Get-WpfBoxTagMap $Wnd 'Els'
    if ($els -is [System.Collections.IDictionary] -and $els.Contains('Body') -and $els['Body'] -is [System.Windows.Controls.TextBlock]) { $body = [string]$els['Body'].Text }
    $state = Get-WpfBoxTagMap $Wnd 'State'
    $enterCaption = ''; $escapeCaption = ''
    if ($state -is [System.Collections.IDictionary]) {
        if ($map.Contains([string]$state['Enter'])) { $enterCaption = Get-PagesButtonCaption $map[[string]$state['Enter']] }
        if ($map.Contains([string]$state['Escape'])) { $escapeCaption = Get-PagesButtonCaption $map[[string]$state['Escape']] }
    }
    return @{ Body = $body; Buttons = ($sorted -join '|'); SaveEnabled = [bool]$map['Save'].IsEnabled; EnterCaption = $enterCaption; EscapeCaption = $escapeCaption }
}
function New-SettingsWatch { return @{ Kind = 'watch'; Captions = @('FastLLM settings', 'Create a new key', 'Experimental community components'); Id = 2 } }
function Start-SettingsDialogs([object[]]$Steps, [hashtable]$St) {
    $St['i'] = 0
    $St['recs'] = New-Object System.Collections.ArrayList
    $St['unexpected'] = 0
    $St['hardStop'] = $false
    $St['timedOut'] = $false
    $st = $St
    $list = @($Steps)
    $nat = $script:native
    $wpf = Get-ModelsWindowHandle
    $isPrompt = ${function:Test-PagesIsSavePrompt}
    $promptInfo = ${function:Get-PagesPromptInfo}
    $findWpf = ${function:Find-PagesWpfBoxAny}
    $wpfButton = ${function:Get-PagesWpfButton}
    $wpfStop = ${function:Stop-PagesWpfBox}
    $wpfKey = ${function:Send-PagesWpfKey}
    $wpfRec = ${function:New-PagesWpfRec}
    $wpfFocus = ${function:Get-PagesWpfFocusInfo}
    $tagMap = ${function:Get-WpfBoxTagMap}
    $pressBtn = ${function:Invoke-WpfBoxButton}
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $loc = @{ stepStart = [long]0; foundAt = [long]0; rec = $null; acted = $false; fell = $false; hwnd = [long]0; actAt = [long]-1 }
    $names = @('BM_CLICK id', 'WM_COMMAND id', 'WM_COMMAND fallback', 'WM_CLOSE')
    $body = {
        $ms = $sw.ElapsedMilliseconds
        $idx = [int]$st['i']
        if ($idx -ge $list.Count) { return }
        $step = $list[$idx]
        $kind = [string]$step['Kind']
        if ($kind -ceq 'watch') {
            foreach ($caption in @($step['Captions'])) {
                $wb = & $findWpf $wpf ([string]$caption)
                if ($null -ne $wb) {
                    # an unexpected WPF box is answered No, Cancel or OK (never Yes) and counted
                    $st['unexpected'] = [int]$st['unexpected'] + 1
                    & $wpfStop $wb
                    continue
                }
                $h = $nat::FindWindowByTitle([string]$caption)
                if ($h.ToInt64() -ne 0) {
                    $st['unexpected'] = [int]$st['unexpected'] + 1
                    $null = $nat::PostButtonClick($h, [int]$step['Id'])
                    $null = $nat::PostCommand($h, [int]$step['Id'])
                }
            }
            return
        }
        if ($kind -ceq 'act') {
            # PR 4b (new step kind): once the dialog with this caption has been up for 150 ms, run Do ($Dialog window, $St) one time and go on to the next step at once, with
            # the dialog still open (select a row, tick the boxes, post a link click). With Closes, the step waits for the dialog to go (Fallback is the button pressed after 1.5 s).
            $wb = & $findWpf $wpf ([string]$step['Caption'])
            if ($null -ne $wb) {
                if ([long]$loc['actAt'] -lt 0) { $loc['actAt'] = $ms }
                $age = $ms - [long]$loc['actAt']
                if (-not [bool]$loc['acted']) {
                    if ($age -ge 150) {
                        $loc['acted'] = $true
                        $loc['foundAt'] = $ms
                        $closes = ($step['Closes'] -eq $true)
                        if (-not $closes) { $st['i'] = $idx + 1; $loc['acted'] = $false; $loc['actAt'] = [long]-1; $loc['stepStart'] = $ms }
                        try { $null = & $step['Do'] $wb $st } catch { $st['actError'] = [string]$_.Exception.Message }
                    }
                }
                elseif ((($ms - [long]$loc['foundAt']) -ge 1500) -and -not [bool]$loc['fell']) {
                    $loc['fell'] = $true
                    $st['actFellBack'] = $true
                    $fb = $step['Fallback']
                    if ($null -ne $fb) { $null = & $pressBtn (& $wpfButton $wb $fb) 0 } else { & $wpfStop $wb }
                }
            }
            elseif ([bool]$loc['acted']) {
                $st['i'] = $idx + 1; $loc['acted'] = $false; $loc['fell'] = $false; $loc['actAt'] = [long]-1; $loc['stepStart'] = $ms
            }
            elseif (($ms - [long]$loc['stepStart']) -gt 8000) {
                $st['timedOut'] = $true
                $st['i'] = $idx + 1; $loc['stepStart'] = $ms
            }
            return
        }
        if ($kind -ceq 'prompt') {
            # PR 4b (named test change): the Settings save prompt is a WPF dialog on the dialog host (caption 'FastLLM settings', told apart from the message box of the same
            # caption by its DontSave button), found like any fluent dialog. The record has the fields the WinForms record had, plus the path.
            $pw = & $findWpf $wpf 'FastLLM settings'
            if ($null -ne $pw -and -not (& $isPrompt $pw)) { $pw = $null }
            if ($null -ne $pw) {
                if ($null -eq $loc['rec']) {
                    $pi = & $promptInfo $pw
                    $rec = & $wpfRec $pw 'FastLLM settings' $wpf
                    $rec['Kind'] = 'prompt'; $rec['Body'] = [string]$pi['Body']; $rec['Buttons'] = [string]$pi['Buttons']; $rec['SaveEnabled'] = [bool]$pi['SaveEnabled']
                    $rec['AcceptText'] = [string]$pi['EnterCaption']; $rec['CancelText'] = [string]$pi['EscapeCaption']; $rec['ActiveText'] = ''
                    $rec['Action'] = [string]$step['Action']
                    $loc['rec'] = $rec
                    $loc['foundAt'] = $ms
                    [void]$st['recs'].Add($rec)
                }
                $rec = $loc['rec']
                $age = $ms - [long]$loc['foundAt']
                if (-not [bool]$loc['acted']) {
                    # act once the dialog has had time to load and take its first focus; the focused button's caption is the first focus
                    if ($age -ge 150) {
                        $loc['acted'] = $true
                        $focusInfo = & $wpfFocus $pw
                        $focusMap = & $tagMap $pw 'Buttons'
                        if ([string]$focusInfo['Id'] -cne '' -and $focusMap.Contains([string]$focusInfo['Id'])) { $rec['ActiveText'] = [string][System.Windows.Automation.AutomationProperties]::GetName($focusMap[[string]$focusInfo['Id']]) }
                        $rec['Focus'] = [string]$focusInfo['Text']
                        $rec['Active'] = [bool]$pw.IsActive
                        $action = [string]$step['Action']
                        $rec['Rung'] = 'action ' + $action
                        if ($action -ceq 'Enter') { $rec['KeyPosted'] = [bool](& $wpfKey $pw 'Return') }
                        elseif ($action -ceq 'Escape') { $rec['KeyPosted'] = [bool](& $wpfKey $pw 'Escape') }
                        else {
                            $id = $action
                            if ($action -ceq 'Dont') { $id = 'DontSave' }
                            $rec['KeyPosted'] = $false
                            $null = & $pressBtn (& $wpfButton $pw $id) 0
                        }
                    }
                }
                elseif ($age -ge 6000) {
                    if (-not [bool]$st['hardStop']) { $st['hardStop'] = $true; & $wpfStop $pw }
                }
                elseif ($age -ge 1500 -and -not [bool]$loc['fell']) {
                    $loc['fell'] = $true
                    $rec['FellBack'] = $true
                    $rec['Rung'] = 'did not close; Cancel pressed'
                    $null = & $pressBtn (& $wpfButton $pw 'Cancel') 0
                }
            }
            elseif ($null -ne $loc['rec']) {
                $loc['rec']['Closed'] = $true
                $st['i'] = $idx + 1; $loc['rec'] = $null; $loc['acted'] = $false; $loc['fell'] = $false; $loc['stepStart'] = $ms
            }
            elseif (($ms - [long]$loc['stepStart']) -gt 8000) {
                $st['timedOut'] = $true
                [void]$st['recs'].Add(@{ Kind = 'prompt'; Found = $false })
                $st['i'] = $idx + 1; $loc['stepStart'] = $ms
            }
            return
        }
        # a WPF message box by its caption (a fluent box), else a native box or form
        $wb = & $findWpf $wpf ([string]$step['Caption'])
        if ($null -ne $wb) {
            $wid = [long][System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($wb)
            # Two boxes with one caption in a row (Create a new key): a different window while the record is open means the first closed.
            if ($null -ne $loc['rec'] -and $wid -ne [long]$loc['hwnd']) {
                $loc['rec']['Closed'] = $true
                $st['i'] = $idx + 1; $loc['rec'] = $null; $loc['acted'] = $false; $loc['fell'] = $false; $loc['stepStart'] = $ms
                if ($loc.ContainsKey('rungDone')) { $loc.Remove('rungDone') }
                return
            }
            if ($null -eq $loc['rec']) {
                $loc['hwnd'] = $wid
                $rec = & $wpfRec $wb ([string]$step['Caption']) $wpf
                $loc['rec'] = $rec
                $loc['foundAt'] = $ms
                [void]$st['recs'].Add($rec)
            }
            $rec = $loc['rec']
            $age = $ms - [long]$loc['foundAt']
            if ($age -ge 6000) {
                if (-not [bool]$st['hardStop']) { $st['hardStop'] = $true; & $wpfStop $wb }
            }
            elseif ($null -ne $step['Key'] -or $step['Sys'] -eq $true) {
                if (-not [bool]$loc['acted']) {
                    # act once the dialog has had time to load and take its first focus (the focus facts are read just before the key or the close box)
                    if ($age -ge 150) {
                        $loc['acted'] = $true
                        $focusInfo = & $wpfFocus $wb
                        $rec['FocusInfo'] = $focusInfo
                        $rec['Focus'] = [string]$focusInfo['Text']
                        $rec['Active'] = [bool]$wb.IsActive
                        if ($step['Sys'] -eq $true) {
                            # the close box and Alt+F4 both arrive as WM_SYSCOMMAND SC_CLOSE
                            $rec['Rung'] = 'SC_CLOSE'
                            $dh = [System.Windows.Interop.WindowInteropHelper]::new($wb).Handle
                            $rec['KeyPosted'] = [bool]$nat::PostMessage($dh, [uint32]0x0112, [IntPtr]61536, [IntPtr]::Zero)
                        }
                        else {
                            $rec['Rung'] = 'PostKey'
                            $keyName = 'Return'
                            if ([int]$step['Key'] -eq 0x1B) { $keyName = 'Escape' }
                            $rec['KeyPosted'] = [bool](& $wpfKey $wb $keyName)
                        }
                    }
                }
                elseif ($age -ge 1500 -and -not [bool]$loc['fell']) {
                    $loc['fell'] = $true
                    $rec['FellBack'] = $true
                    # PR 4b (named test change): Fallback and Id may be a custom button id (a fluent dialog's own, such as Cancel or Later) as well as a Win32-style number
                    $fbv = $step['Fallback']
                    if ($null -ne $fbv -and [string]$fbv -cne '' -and [string]$fbv -cne '0') { $rec['Rung'] = 'key did not close it; button fallback'; $null = & $pressBtn (& $wpfButton $wb $fbv) 0 }
                    else { $rec['Rung'] = 'key did not close it; stop'; & $wpfStop $wb }
                }
            }
            else {
                $rung = [int][Math]::Floor($age / 1000)
                if ($rung -gt [int]$loc['rungDone'] -or -not $loc.ContainsKey('rungDone')) {
                    $loc['rungDone'] = $rung
                    $which = [Math]::Min($rung, 3)
                    $rec['Rung'] = [string]@('Invoke id', 'Click id', 'Invoke fallback', 'stop')[$which]
                    if ($which -eq 0) { $null = & $pressBtn (& $wpfButton $wb $step['Id']) 0 }
                    elseif ($which -eq 1) { $null = & $pressBtn (& $wpfButton $wb $step['Id']) 1 }
                    elseif ($which -eq 2) { $null = & $pressBtn (& $wpfButton $wb $step['Fallback']) 0 }
                    else { & $wpfStop $wb }
                }
            }
            return
        }
        # a native box or form by its caption
        $h = $nat::FindWindowByTitle([string]$step['Caption'])
        if ($h.ToInt64() -ne 0) {
            # Two boxes with the same caption can follow each other within one tick (the Create a new key Yes/No box, then its OK box): a different handle while the
            # record is still open means the first box closed, so close the record, advance and let the next tick take the new box as its own.
            if ($null -ne $loc['rec'] -and $h.ToInt64() -ne [long]$loc['hwnd']) {
                $loc['rec']['Closed'] = $true
                $st['i'] = $idx + 1; $loc['rec'] = $null; $loc['acted'] = $false; $loc['fell'] = $false; $loc['stepStart'] = $ms
                if ($loc.ContainsKey('rungDone')) { $loc.Remove('rungDone') }
                return
            }
            if ($null -eq $loc['rec']) {
                $loc['hwnd'] = $h.ToInt64()
                $rec = @{ Kind = 'box'; Found = $true; Path = 'win32'; Caption = [string]$step['Caption']; Text = [string]$nat::GetText($h); Owner = $nat::GetOwner($h).ToInt64()
                    WpfEnabledDuring = [bool]$nat::IsWindowEnabled($wpf); HasYes = ($nat::GetDlgItem($h, 6).ToInt64() -ne 0); HasOk = ($nat::GetDlgItem($h, 1).ToInt64() -ne 0)
                    HasCancel = ($nat::GetDlgItem($h, 2).ToInt64() -ne 0); Rung = ''; FellBack = $false; Closed = $false; Native = ($step['Native'] -eq $true) }
                $loc['rec'] = $rec
                $loc['foundAt'] = $ms
                [void]$st['recs'].Add($rec)
            }
            $rec = $loc['rec']
            $age = $ms - [long]$loc['foundAt']
            if ($age -ge 6000) {
                if (-not [bool]$st['hardStop']) { $st['hardStop'] = $true; $null = $nat::PostClose($h) }
            }
            elseif ($null -ne $step['Key']) {
                if (-not [bool]$loc['acted']) { $loc['acted'] = $true; $rec['Rung'] = 'PostKey'; $null = $nat::PostKey($h, [int]$step['Key']) }
                elseif ($age -ge 1500 -and -not [bool]$loc['fell']) {
                    $loc['fell'] = $true
                    $rec['FellBack'] = $true
                    if ([int]$step['Fallback'] -gt 0) { $rec['Rung'] = 'key did not close it; BM_CLICK fallback'; $null = $nat::PostButtonClick($h, [int]$step['Fallback']) }
                    else { $rec['Rung'] = 'key did not close it; WM_CLOSE'; $null = $nat::PostClose($h) }
                }
            }
            else {
                $rung = [int][Math]::Floor($age / 1000)
                if ($rung -gt [int]$loc['rungDone'] -or -not $loc.ContainsKey('rungDone')) {
                    $loc['rungDone'] = $rung
                    $which = [Math]::Min($rung, 3)
                    $rec['Rung'] = [string]$names[$which]
                    if ($which -eq 0) { $null = $nat::PostButtonClick($h, [int]$step['Id']) }
                    elseif ($which -eq 1) { $null = $nat::PostCommand($h, [int]$step['Id']) }
                    elseif ($which -eq 2) { $null = $nat::PostCommand($h, [int]$step['Fallback']) }
                    else { $null = $nat::PostClose($h) }
                }
            }
        }
        elseif ($null -ne $loc['rec']) {
            $loc['rec']['Closed'] = $true
            $st['i'] = $idx + 1; $loc['rec'] = $null; $loc['acted'] = $false; $loc['fell'] = $false; $loc['stepStart'] = $ms
            if ($loc.ContainsKey('rungDone')) { $loc.Remove('rungDone') }
        }
        elseif (($ms - [long]$loc['stepStart']) -gt 8000) {
            $st['timedOut'] = $true
            [void]$st['recs'].Add(@{ Kind = 'box'; Found = $false; Caption = [string]$step['Caption'] })
            $st['i'] = $idx + 1; $loc['stepStart'] = $ms
        }
    }.GetNewClosure()
    # Two timers drive one tick body: a WinForms timer (the proven path for a Win32 box) and a DispatcherTimer (a WPF ShowDialog is a nested dispatcher frame).
    $wf = New-Object System.Windows.Forms.Timer
    $wf.Interval = 50
    $wf.Add_Tick(({ & $body }).GetNewClosure())
    $dt = New-Object System.Windows.Threading.DispatcherTimer
    $dt.Interval = [TimeSpan]::FromMilliseconds(50)
    $dt.Add_Tick(({ & $body }).GetNewClosure())
    $ctl = New-PagesTimerPair $wf $dt
    $script:objs.Add($ctl)
    $wf.Start()
    $dt.Start()
    return $ctl
}
function Get-SettingsRecDetail([hashtable]$D) {
    $parts = New-Object System.Collections.ArrayList
    foreach ($r in @($D['recs'].ToArray())) {
        if (-not [bool]$r['Found']) { [void]$parts.Add($r['Kind'] + ' NOT FOUND'); continue }
        if ($r['Kind'] -ceq 'prompt') { [void]$parts.Add("prompt[action=$($r['Action']) buttons=$($r['Buttons']) saveEnabled=$($r['SaveEnabled']) accept='$($r['AcceptText'])' cancel='$($r['CancelText'])' active='$($r['ActiveText'])' fellBack=$($r['FellBack']) rung='$($r['Rung'])' body='$($r['Body'])']") }
        else { $focusText = ''; if ($r.ContainsKey('Focus')) { $focusText = " focus='$($r['Focus'])' active=$($r['Active']) keyPosted=$($r['KeyPosted'])" }; [void]$parts.Add("box[$($r['Caption']) path=$($r['Path']) rung='$($r['Rung'])' fellBack=$($r['FellBack']) yes=$($r['HasYes'])$focusText text='$($r['Text'])']") }
    }
    return ("dialogs=" + $D['recs'].Count + " " + ($parts.ToArray() -join ' ; ') + " unexpected=$($D['unexpected']) timedOut=$($D['timedOut']) hardStop=$($D['hardStop'])")
}
function Get-SettingsRec([hashtable]$D, [int]$Index) {
    if ($Index -lt $D['recs'].Count) { return $D['recs'][$Index] }
    return @{ Found = $false; Kind = 'missing' }
}
# PR 4a (named test change): a clean run is also one where every message box was a WPF dialog. In fluent mode no Win32 message box may appear.
# PR 4b (named test changes): (1) the 4a exemption for the licence confirmation caption is gone, because that dialog is now a fluent dialog on the host too, so a WinForms
# licence form would fail here; (2) a save prompt record must be a WPF dialog as well (its WinForms form is gone). The only native window left in these steps is the
# SaveFileDialog after the support bundle box, which a step marks Native.
function Test-SettingsRecClean([hashtable]$D) {
    foreach ($r in @($D['recs'].ToArray())) {
        if ([string]$r['Kind'] -ceq 'box' -and [bool]$r['Found'] -and [string]$r['Path'] -cne 'wpf' -and -not ($r.ContainsKey('Native') -and [bool]$r['Native'])) { return $false }
        if ([string]$r['Kind'] -ceq 'prompt' -and [bool]$r['Found'] -and [string]$r['Path'] -cne 'wpf') { return $false }
    }
    return (-not [bool]$D['timedOut'] -and -not [bool]$D['hardStop'] -and [int]$D['unexpected'] -eq 0)
}

# One edit of each Server field: how to make it, how to see it in the held values, and how to see it back at the saved value.
function Get-SettingsEditTable {
    $els = Get-SettingsEls
    $st = Get-SettingsState
    return @(
        @{ Name = 'Port'; Do = { $els.SettingsPortBox.Text = '9000'; $null = Send-ModelsKey $els.SettingsPortBox ([System.Windows.Input.Key]::Return) }; Held = { [int]$st['Held'].port -eq 9000 }; Back = { [string]$els.SettingsPortBox.Text -ceq '8080' } },
        @{ Name = 'Thinking'; Do = { $els.SettingsThinkingBox.SelectedIndex = 1 }; Held = { [int]$st['Held'].thinkingIndex -eq 1 }; Back = { [int]$els.SettingsThinkingBox.SelectedIndex -eq 0 } },
        @{ Name = 'Chat'; Do = { $els.SettingsChatBox.IsChecked = $true }; Held = { [bool]$st['Held'].chatPage }; Back = { $els.SettingsChatBox.IsChecked -eq $false } },
        @{ Name = 'Idle'; Do = { $els.SettingsIdleBox.SelectedIndex = 2 }; Held = { [int]$st['Held'].idleIndex -eq 2 }; Back = { [int]$els.SettingsIdleBox.SelectedIndex -eq 0 } },
        @{ Name = 'Key'; Do = { $els.SettingsKeyBox.IsChecked = $true }; Held = { [string]$st['Held'].keyBox -ceq 'checked' -and [bool]$st['Held'].keyTouched }; Back = { $els.SettingsKeyBox.IsChecked -eq $false } },
        @{ Name = 'Switch'; Do = { $els.SettingsSwitchBox.IsChecked = $true }; Held = { [bool]$st['Held'].allowSwitch }; Back = { $els.SettingsSwitchBox.IsChecked -eq $false } }
    )
}

function Get-SettingsBeforeObject([hashtable]$Fx) {
    # Settings additions (named test change): the before object also carries the four serving additions (the fixture's value, or the store's default when it has none).
    $add = @{ contextProfile = 'default'; slots = 1; embeddings = 'off'; embeddingPort = 8081 }
    foreach ($k in @($add.Keys)) { if ($Fx.ContainsKey($k)) { $add[$k] = $Fx[$k] } }
    return [pscustomobject]@{ serverPort = [int]$Fx.serverPort; thinking = [string]$Fx.thinking; chatPage = [string]$Fx.chatPage; idleStopMinutes = [int]$Fx.idleStopMinutes; apiKey = [string]$Fx.apiKey; allowSwitch = $false
        contextProfile = [string]$add.contextProfile; slots = [int]$add.slots; embeddings = [string]$add.embeddings; embeddingPort = [int]$add.embeddingPort }
}

# ---- P30: Save ----
function Invoke-P30-Save {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $hwnd = Get-ModelsWindowHandle
    $s = $script:FastLlmUiFluentStrings
    Check (@($script:p30Missing).Count -eq 0) 'P30 NewUiApiKey and ShowLicenseSettingConfirm were found in fast-llm-ui.ps1' ("missing=" + (@($script:p30Missing) -join ','))
    Check ($script:settingsWiring.Count -eq 4) 'P30 the real wiring statements of the update, experimental and licence boxes and of settingsButton.Add_Click were found in fast-llm-ui.ps1' "found=[$((@($script:settingsWiring.Keys) -join ','))]"
    # Control: the classic Settings button wiring is real-shaped and a raised Click reaches its counter; the page itself never does.
    $script:settingsDialogCalls = 0
    Invoke-FastLlmUiAdapterEvent -Adapter $script:settingsButton -Event 'Click'
    Check ($script:settingsDialogCalls -eq 1) 'P30 control: a raised settingsButton Click reaches the wired ShowUiSettings stub once (the counter can move)' "calls=$($script:settingsDialogCalls)"
    $script:settingsDialogCalls = 0

    # A. Opening fills the page from the saved values; an edit to each field makes it dirty and Discard puts that field back.
    Check (Open-SettingsPage @{}) 'P30 Set-FastLlmUiFluentPage -Id Settings hosts the registered Settings page' "current=$(Get-FastLlmUiFluentCurrentPage)"
    $st = Get-SettingsState
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Settings' -and $els.NavSettings.IsSelected -and [object]::ReferenceEquals($els.PageHost.Child, $f.Pages['Settings']['Element'])) 'P30 the Settings page is hosted and its pane item is selected' "current=$(Get-FastLlmUiFluentCurrentPage)"
    Check ([string]$els.SettingsPortBox.Text -ceq '8080' -and [int]$els.SettingsThinkingBox.SelectedIndex -eq 0 -and $els.SettingsChatBox.IsChecked -eq $false -and [int]$els.SettingsIdleBox.SelectedIndex -eq 0 -and $els.SettingsKeyBox.IsChecked -eq $false -and $els.SettingsSwitchBox.IsChecked -eq $false -and -not [bool]$st['Dirty']) 'P30 Enter fills the controls from the saved settings and the page starts clean' "port='$($els.SettingsPortBox.Text)' thinking=$($els.SettingsThinkingBox.SelectedIndex) chat=$($els.SettingsChatBox.IsChecked) idle=$($els.SettingsIdleBox.SelectedIndex) key=$($els.SettingsKeyBox.IsChecked) switch=$($els.SettingsSwitchBox.IsChecked) dirty=$($st['Dirty'])"
    foreach ($edit in @(Get-SettingsEditTable)) {
        & $edit.Do
        Invoke-Pump 30
        $heldOk = [bool](& $edit.Held)
        Check ([bool]$st['Dirty'] -and $heldOk) "P30 an edit to $($edit.Name) makes the page dirty and writes the held value" "dirty=$($st['Dirty']) held=$heldOk"
        Invoke-FastLlmUiFluentSettingsDiscard
        Invoke-Pump 30
        $backOk = [bool](& $edit.Back)
        Check ((-not [bool]$st['Dirty']) -and $backOk) "P30 Discard puts $($edit.Name) back to the saved value and the page is clean again" "dirty=$($st['Dirty']) back=$backOk"
    }
    Check ($script:setLog.Count -eq 0) 'P30 editing and discarding wrote nothing' "log=$(Get-SettingsLogText)"

    # B. A full Save: the effect sequence is classic's (the key action, the serving write, the switch write, the refresh), the status text is the saved note, the chat-off note follows.
    $null = Open-SettingsPage @{ chatPage = 'on' }
    $st = Get-SettingsState
    $before = Get-SettingsBeforeObject $script:setFx
    $els.SettingsPortBox.Text = '9000'; $null = Send-ModelsKey $els.SettingsPortBox ([System.Windows.Input.Key]::Return)
    $els.SettingsThinkingBox.SelectedIndex = 1
    $els.SettingsChatBox.IsChecked = $false
    $els.SettingsIdleBox.SelectedIndex = 2
    $els.SettingsKeyBox.IsChecked = $true
    $els.SettingsSwitchBox.IsChecked = $true
    Invoke-Pump 50
    Check ([bool]$st['Dirty']) 'P30 all six edits together are dirty' "dirty=$($st['Dirty'])"
    $d = @{}
    $timer = Start-SettingsDialogs @((New-SettingsWatch)) $d
    try { $r = @(Invoke-FastLlmUiFluentSettingsSave); Invoke-Pump 50 } finally { $timer.Stop() }
    Check ($r.Count -eq 1 -and $r[0] -is [bool] -and $r[0]) 'P30 Save returns exactly one bool (true) for a completed save' "count=$($r.Count) value=$($r -join ',')"
    Check ((Get-SettingsLogText) -ceq 'apikey:on,serving,allow,refresh') 'P30 Save writes in classic order: the key action, the serving settings, the switch setting, the refresh' "log=$(Get-SettingsLogText)"
    $ls = $script:setLastServing
    Check ($null -ne $ls -and [int]$ls.port -eq 9000 -and [string]$ls.thinking -ceq 'off' -and [string]$ls.chat -ceq 'off' -and [int]$ls.idle -eq 30 -and $script:setAllowStored -eq $true -and [bool]$script:uiSettings.allowSwitch) 'P30 Save writes the held values: port 9000, thinking off, chat off, idle 30, switch on (and the window setting follows)' "serving=$(if ($null -ne $ls) { $ls.port.ToString() + '/' + $ls.thinking + '/' + $ls.chat + '/' + $ls.idle } else { 'none' }) allow=$($script:setAllowStored) ui=$($script:uiSettings.allowSwitch)"
    $after = [pscustomobject]@{ serverPort = 9000; thinking = 'off'; chatPage = 'off'; idleStopMinutes = 30; apiKey = 'on'; allowSwitch = $true }
    $wantNote = (Get-FastLlmUiSettingsSavedNote -RunActive $false -Before $before -After $after) + ' ' + (Get-FastLlmUiChatPageOffNote -Port 9000)
    Check ([string]$script:statusLabel.Text -ceq $wantNote) 'P30 the status text is the saved note plus the chat-off note (chat went from on to off)' "status='$($script:statusLabel.Text)' want='$wantNote'"
    Check ((-not [bool]$st['Dirty']) -and [int]$st['Saved'].port -eq 9000 -and -not [bool]$st['Held'].keyTouched -and [string]$els.SettingsPortBox.Text -ceq '9000' -and $els.SettingsKeyBox.IsChecked -eq $true) 'P30 after a saved Save the page is reloaded: clean, Saved = Held, keyTouched cleared, the controls show the saved values' "dirty=$($st['Dirty']) saved=$($st['Saved'].port) touched=$($st['Held'].keyTouched) port='$($els.SettingsPortBox.Text)' key=$($els.SettingsKeyBox.IsChecked)"
    Check (Test-SettingsRecClean $d) 'P30 a completed save (not running) shows no box' (Get-SettingsRecDetail $d)

    # C. While a run is active the Information box shows the saved note too (the tick rewrites the status line). The Save button path.
    $null = Open-SettingsPage @{}
    $st = Get-SettingsState
    $script:child = [pscustomobject]@{ probe = $true }
    $els.SettingsPortBox.Text = '9001'; $null = Send-ModelsKey $els.SettingsPortBox ([System.Windows.Input.Key]::Return)
    $d = @{}
    $timer = Start-SettingsDialogs @(@{ Kind = 'box'; Caption = 'FastLLM settings'; Id = 2; Fallback = 2 }, (New-SettingsWatch)) $d
    try {
        $els.SettingsSaveButton.RaiseEvent((New-ShellClick $els.SettingsSaveButton ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Invoke-Pump 150
    }
    finally { $timer.Stop(); $script:child = $null }
    $wantRun = Get-FastLlmUiSettingsSavedNote -RunActive $true -Before (Get-SettingsBeforeObject @{ serverPort = 8080; thinking = 'auto'; chatPage = 'off'; idleStopMinutes = 0; apiKey = 'off' }) -After ([pscustomobject]@{ serverPort = 9001; thinking = 'auto'; chatPage = 'off'; idleStopMinutes = 0; apiKey = 'off'; allowSwitch = $false })
    $rec = Get-SettingsRec $d 0
    Check ([bool]$rec['Found'] -and (ConvertTo-ModelsPlainBoxText ([string]$rec['Text'])) -ceq $wantRun -and [string]$script:statusLabel.Text -ceq $wantRun -and (Test-SettingsRecClean $d)) 'P30 while a run is active the Save button shows the Information box with the saved note' ("want='$wantRun' status='$($script:statusLabel.Text)' " + (Get-SettingsRecDetail $d))
    Check ([bool]$rec['Found'] -and [long]$rec['Owner'] -eq $hwnd.ToInt64()) 'P30 the Information box is owned by the WPF window handle' "owner=$($rec['Owner']) expected=$($hwnd.ToInt64())"
    Check ((Get-SettingsLogText) -ceq 'serving,allow,refresh' -and [int]$script:setFx.serverPort -eq 9001) 'P30 the Save button runs the same sequence (no key action: the box agrees with the saved key)' "log=$(Get-SettingsLogText)"

    # D. A refused key decision: "not set" and untouched. Nothing is written, the page and its edits stay, the key row is marked, the Warning box has the key-free text.
    $null = Open-SettingsPage @{ apiKeyUndetermined = $true }
    $st = Get-SettingsState
    Check (($null -eq $els.SettingsKeyBox.IsChecked) -and [bool]$els.SettingsKeyBox.IsThreeState -and [string]$st['Held'].keyBox -ceq 'indeterminate') 'P30 a "not set" key opens the key box in its third state' "checked=$($els.SettingsKeyBox.IsChecked) threeState=$($els.SettingsKeyBox.IsThreeState) held=$($st['Held'].keyBox)"
    $els.SettingsPortBox.Text = '9000'; $null = Send-ModelsKey $els.SettingsPortBox ([System.Windows.Input.Key]::Return)
    $d = @{}
    $timer = Start-SettingsDialogs @(@{ Kind = 'box'; Caption = 'FastLLM settings'; Id = 2; Fallback = 2 }, (New-SettingsWatch)) $d
    try { $r = @(Invoke-FastLlmUiFluentSettingsSave); Invoke-Pump 100 } finally { $timer.Stop() }
    $rec = Get-SettingsRec $d 0
    $choice = Get-FastLlmUiApiKeyChoiceText
    Check ($r.Count -eq 1 -and $r[0] -is [bool] -and -not $r[0]) 'P30 a refused Save returns exactly one bool (false)' "count=$($r.Count) value=$($r -join ',')"
    Check ([bool]$rec['Found'] -and (ConvertTo-ModelsPlainBoxText ([string]$rec['Text'])) -ceq (ConvertTo-ModelsPlainBoxText $choice) -and (Test-SettingsRecClean $d)) 'P30 a refused key decision shows the Warning box with the key-free choice text' (Get-SettingsRecDetail $d)
    Check ((Get-SettingsLogText) -ceq '' -and $null -eq $script:setLastServing -and $null -eq $script:setAllowStored) 'P30 a refused key decision writes nothing at all (no key action, no serving write, no switch write)' "log=$(Get-SettingsLogText)"
    $mark = $els.SettingsKeyRow.BorderBrush
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Settings' -and [bool]$st['Dirty'] -and [int]$st['Held'].port -eq 9000 -and [string]$els.SettingsPortBox.Text -ceq '9000') 'P30 a refused Save keeps the page and the edits' "current=$(Get-FastLlmUiFluentCurrentPage) dirty=$($st['Dirty']) held=$($st['Held'].port) text='$($els.SettingsPortBox.Text)'"
    Check ([bool]$st['KeyMarked'] -and $mark -is [System.Windows.Media.SolidColorBrush] -and $mark.Color.A -gt 0 -and [string]$els.SettingsKeyHelp.Text -ceq $choice -and [System.Windows.Automation.AutomationProperties]::GetHelpText($els.SettingsKeyBox) -ceq $choice) 'P30 a refused key decision marks the key row: a caution border and the key-free text as its help' "marked=$($st['KeyMarked']) brush=$mark help='$($els.SettingsKeyHelp.Text)'"
    # Discard clears the mark and puts the "not set" third state back (and the saved port)
    Invoke-FastLlmUiFluentSettingsDiscard
    Invoke-Pump 30
    Check ((-not [bool]$st['KeyMarked']) -and ($null -eq $els.SettingsKeyBox.IsChecked) -and [bool]$els.SettingsKeyBox.IsThreeState -and [string]$st['Held'].keyBox -ceq 'indeterminate' -and -not [bool]$st['Held'].keyTouched -and [string]$els.SettingsPortBox.Text -ceq '8080' -and [string]$els.SettingsKeyHelp.Text -ceq [string]$script:FastLlmUiFluentSettingsText.KeyHelp) 'P30 Discard clears the key mark (help text back to the key help) and restores the "not set" third state and the saved port' "marked=$($st['KeyMarked']) checked=$($els.SettingsKeyBox.IsChecked) threeState=$($els.SettingsKeyBox.IsThreeState) held=$($st['Held'].keyBox) touched=$($st['Held'].keyTouched) help='$($els.SettingsKeyHelp.Text)'"
    # a key click clears a mark: refuse once more, then the first automation Toggle of the "not set" box (WPF goes null to false) clears the mark and the third state
    $els.SettingsPortBox.Text = '9000'; $null = Send-ModelsKey $els.SettingsPortBox ([System.Windows.Input.Key]::Return)
    $d = @{}
    $timer = Start-SettingsDialogs @(@{ Kind = 'box'; Caption = 'FastLLM settings'; Id = 2; Fallback = 2 }, (New-SettingsWatch)) $d
    try { $null = Invoke-FastLlmUiFluentSettingsSave; Invoke-Pump 100 } finally { $timer.Stop() }
    $markedBefore = [bool]$st['KeyMarked']
    $keyPeer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($els.SettingsKeyBox)
    $toggle = [System.Windows.Automation.Provider.IToggleProvider]($keyPeer.GetPattern([System.Windows.Automation.Peers.PatternInterface]::Toggle))
    $toggle.Toggle()
    Invoke-Pump 50
    $state1 = $els.SettingsKeyBox.IsChecked
    Check ($markedBefore -and $null -ne $state1 -and $state1 -eq $false -and [string]$st['Held'].keyBox -ceq 'unchecked' -and [bool]$st['Held'].keyTouched -and -not [bool]$els.SettingsKeyBox.IsThreeState -and -not [bool]$st['KeyMarked']) 'P30 the first Toggle of a refused "not set" box clears it (null to false), marks it touched, drops the third state and clears the mark' "markedBefore=$markedBefore after1=$state1 held=$($st['Held'].keyBox) touched=$($st['Held'].keyTouched) threeState=$($els.SettingsKeyBox.IsThreeState) marked=$($st['KeyMarked'])"
    $toggle.Toggle()
    Invoke-Pump 50
    $state2 = $els.SettingsKeyBox.IsChecked
    Check ($null -ne $state2 -and $state2 -eq $true -and [string]$st['Held'].keyBox -ceq 'checked') 'P30 the second Toggle ticks the box (it never goes back to "not set")' "after2=$state2 held=$($st['Held'].keyBox)"

    # E. api-key-unavailable: the "Create a new key" box (No), then the not-turned-on refusal; nothing is written. Then the Yes path: one rotate, the retry, the rest of the sequence.
    $null = Open-SettingsPage @{}
    $st = Get-SettingsState
    $els.SettingsKeyBox.IsChecked = $true
    $script:setApiUnavailable = $true
    Invoke-Pump 30
    $d = @{}
    $timer = Start-SettingsDialogs @(@{ Kind = 'box'; Caption = 'Create a new key'; Id = 7; Fallback = 7 }, @{ Kind = 'box'; Caption = 'FastLLM settings'; Id = 2; Fallback = 2 }, (New-SettingsWatch)) $d
    try { $r = @(Invoke-FastLlmUiFluentSettingsSave); Invoke-Pump 100 } finally { $timer.Stop() }
    $rec0 = Get-SettingsRec $d 0
    $rec1 = Get-SettingsRec $d 1
    Check ($r.Count -eq 1 -and -not $r[0]) 'P30 an unavailable stored key with No returns one bool (false)' "count=$($r.Count) value=$($r -join ',')"
    Check ([bool]$rec0['Found'] -and [bool]$rec0['HasYes'] -and (ConvertTo-ModelsPlainBoxText ([string]$rec0['Text'])) -ceq (Get-FastLlmUiNewKeyConfirmText -HasReadableKey $false) -and [long]$rec0['Owner'] -eq $hwnd.ToInt64()) 'P30 api-key-unavailable asks the Create a new key Yes/No box (owned by the WPF window); the answer is No' ("expected text='$(Get-FastLlmUiNewKeyConfirmText -HasReadableKey $false)' " + (Get-SettingsRecDetail $d))
    Check ([bool]$rec1['Found'] -and (ConvertTo-ModelsPlainBoxText ([string]$rec1['Text'])) -ceq ([string]$script:FastLlmUiFluentSettingsText.NotTurnedOn) -and (Test-SettingsRecClean $d)) 'P30 after No the Warning box says the key was not turned on and nothing was changed' (Get-SettingsRecDetail $d)
    Check ((Get-SettingsLogText) -ceq 'apikey:on' -and $null -eq $script:setLastServing -and $null -eq $script:setAllowStored) 'P30 after No the one write attempted is the key on (it threw); nothing else is written, no rotate' "log=$(Get-SettingsLogText)"
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Settings' -and [bool]$st['Dirty'] -and $els.SettingsKeyBox.IsChecked -eq $true) 'P30 after the refusal the page and the ticked key box stay' "dirty=$($st['Dirty']) key=$($els.SettingsKeyBox.IsChecked)"
    $script:setLog.Clear()
    $script:setApiUnavailable = $true
    $d = @{}
    $timer = Start-SettingsDialogs @(@{ Kind = 'box'; Caption = 'Create a new key'; Id = 6; Fallback = 7 }, @{ Kind = 'box'; Caption = 'Create a new key'; Id = 2; Fallback = 2 }, (New-SettingsWatch)) $d
    try { $r = @(Invoke-FastLlmUiFluentSettingsSave); Invoke-Pump 100 } finally { $timer.Stop() }
    Check ($r.Count -eq 1 -and $r[0] -and (Get-SettingsLogText) -ceq 'apikey:on,apikey:rotate,apikey:on,serving,allow,refresh' -and (Test-SettingsRecClean $d) -and $d['recs'].Count -eq 2) 'P30 with Yes: the key on is retried after exactly one rotate, then the serving write, the switch write and the refresh' ("log=$(Get-SettingsLogText) " + (Get-SettingsRecDetail $d))

    # F. "Not set", ticked, then Save writes the key on; a SECOND Save on the same visit is not refused (the reload cleared apiKeyUndetermined).
    $null = Open-SettingsPage @{ apiKeyUndetermined = $true }
    $st = Get-SettingsState
    $keyPeer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($els.SettingsKeyBox)
    $toggle = [System.Windows.Automation.Provider.IToggleProvider]($keyPeer.GetPattern([System.Windows.Automation.Peers.PatternInterface]::Toggle))
    $toggle.Toggle()
    Invoke-Pump 30
    $toggle.Toggle()
    Invoke-Pump 30
    $d = @{}
    $timer = Start-SettingsDialogs @((New-SettingsWatch)) $d
    try { $r = @(Invoke-FastLlmUiFluentSettingsSave); Invoke-Pump 100 } finally { $timer.Stop() }
    Check ($r.Count -eq 1 -and $r[0] -and (Get-SettingsLogText) -ceq 'apikey:on,serving,allow,refresh' -and (Test-SettingsRecClean $d)) 'P30 "not set", ticked (two Toggles), then Save writes the key on and the settings' ("log=$(Get-SettingsLogText) " + (Get-SettingsRecDetail $d))
    Check ((-not [bool]$st['Current'].apiKeyUndetermined) -and -not [bool]$els.SettingsKeyBox.IsThreeState -and $els.SettingsKeyBox.IsChecked -eq $true) 'P30 the reload after Save re-derives the key box: known (on), no third state' "undetermined=$($st['Current'].apiKeyUndetermined) threeState=$($els.SettingsKeyBox.IsThreeState) checked=$($els.SettingsKeyBox.IsChecked)"
    $script:setLog.Clear()
    $els.SettingsPortBox.Text = '9002'; $null = Send-ModelsKey $els.SettingsPortBox ([System.Windows.Input.Key]::Return)
    $d = @{}
    $timer = Start-SettingsDialogs @((New-SettingsWatch)) $d
    try { $r = @(Invoke-FastLlmUiFluentSettingsSave); Invoke-Pump 100 } finally { $timer.Stop() }
    Check ($r.Count -eq 1 -and $r[0] -and (Get-SettingsLogText) -ceq 'serving,allow,refresh' -and (Test-SettingsRecClean $d)) 'P30 a second Save on the same visit is not refused: no key action, no Warning box' ("log=$(Get-SettingsLogText) " + (Get-SettingsRecDetail $d))

    # G. A throw after the writes (the refresh) goes to ShowFailure, shows no Warning box, and the save still counts: Dirty is false and Save returns true.
    $null = Open-SettingsPage @{}
    $st = Get-SettingsState
    $els.SettingsPortBox.Text = '9000'; $null = Send-ModelsKey $els.SettingsPortBox ([System.Windows.Input.Key]::Return)
    $script:setRefreshThrows = 1
    $script:shellFailMsg = ''
    $d = @{}
    $timer = Start-SettingsDialogs @((New-SettingsWatch)) $d
    try { $r = @(Invoke-FastLlmUiFluentSettingsSave); Invoke-Pump 100 } finally { $timer.Stop() }
    Check ($r.Count -eq 1 -and $r[0] -and [string]$script:shellFailMsg -ceq 'refresh boom' -and (Test-SettingsRecClean $d) -and -not [bool]$st['Dirty'] -and [int]$st['Saved'].port -eq 9000) 'P30 a throw in the after-OK block goes to ShowFailure, shows no Warning box, and the save stays a completed save (clean, Saved = Held, returns true)' ("failure='$($script:shellFailMsg)' dirty=$($st['Dirty']) saved=$($st['Saved'].port) " + (Get-SettingsRecDetail $d))

    Close-SettingsPage
    Check ($script:settingsDialogCalls -eq 0) 'P30 ShowUiSettings (the classic dialog) was never reached by the page' "calls=$($script:settingsDialogCalls)"
    Check-NoExceptions 'P30'
}

# ---- P31: leaving the page with edits, through the pane (the prompt opens INSIDE the selection handler) ----
function Invoke-SettingsLeave([string]$Action, [hashtable]$Fixture, [object[]]$Boxes = @()) {
    $els = Get-SettingsEls
    $null = Open-SettingsPage $Fixture
    $st = Get-SettingsState
    $els.SettingsPortBox.Text = '9001'          # typed, NOT committed: Leave commits the Port box before the dirty test
    $els.SettingsThinkingBox.SelectedIndex = 1
    Invoke-Pump 30
    $d = @{}
    $steps = @(@{ Kind = 'prompt'; Action = $Action }) + @($Boxes) + @((New-SettingsWatch))
    $script:trayAvailability.Clear()
    $timer = Start-SettingsDialogs $steps $d
    try { $els.NavList.SelectedIndex = 0; Invoke-Pump 200 } finally { $timer.Stop() }
    return $d
}
function Get-SettingsPaneDetail {
    $els = Get-SettingsEls
    $st = Get-SettingsState
    return "current=$(Get-FastLlmUiFluentCurrentPage) navHome=$($els.NavHome.IsSelected) navSettings=$($els.NavSettings.IsSelected) list=$($els.NavList.SelectedIndex) settingsList=$($els.NavSettingsList.SelectedIndex) dirty=$($st['Dirty']) heldPort=$($st['Held'].port) thinking=$($st['Held'].thinkingIndex) log=$(Get-SettingsLogText)"
}
function Invoke-P31-Leave {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $hwnd = Get-ModelsWindowHandle
    $s = $script:FastLlmUiFluentStrings
    $okBox = @{ Kind = 'box'; Caption = 'FastLLM settings'; Id = 2; Fallback = 2 }
    $stays = @(@('Cancel', 'Cancel'), @('Escape', 'Escape'), @('Enter', 'Enter (the ruled target is Cancel)'))
    # Save ok: saved and left
    $d = Invoke-SettingsLeave 'Save' @{}
    $st = Get-SettingsState
    $rec = Get-SettingsRec $d 0
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Home' -and $els.NavHome.IsSelected -and $els.NavSettingsList.SelectedIndex -eq -1 -and (Get-SettingsLogText) -ceq 'serving,allow,refresh' -and [int]$script:setFx.serverPort -eq 9001 -and [string]$script:setFx.thinking -ceq 'off' -and (Test-SettingsRecClean $d)) 'P31 Save in the prompt: the typed (uncommitted) port and the thinking edit are saved and the page is left for Home' ((Get-SettingsPaneDetail) + ' ' + (Get-SettingsRecDetail $d))
    Check ([bool]$rec['Found'] -and [string]$rec['Buttons'] -ceq "Cancel|Don't save|Save" -and [bool]$rec['SaveEnabled'] -and [string]$rec['Body'] -ceq [string]$s.SavePrompt) 'P31 the prompt has Save, Dont save and Cancel, Save enabled, and the body is the SavePrompt text with no reason line' (Get-SettingsRecDetail $d)
    Check ([bool]$rec['Found'] -and [string]$rec['AcceptText'] -ceq 'Cancel' -and [string]$rec['CancelText'] -ceq 'Cancel' -and [string]$rec['ActiveText'] -ceq 'Cancel') 'P31 the prompt: Enter (AcceptButton), Escape (CancelButton) and the first focus are all Cancel (lead ruling)' (Get-SettingsRecDetail $d)
    Check ([bool]$rec['Found'] -and [long]$rec['Owner'] -eq $hwnd.ToInt64() -and -not [bool]$rec['WpfEnabledDuring']) 'P31 the prompt is owned by the WPF window handle and the window is disabled while it is up' "owner=$($rec['Owner']) expected=$($hwnd.ToInt64()) wpfEnabled=$($rec['WpfEnabledDuring'])"
    Check (($script:trayAvailability.ToArray() -join ',') -ceq 'False,True') 'P31 the prompt turned the tray menu off while open and on again after' "calls=$($script:trayAvailability.ToArray() -join ',')"
    # Save refused: stays, edits kept, key row marked
    $d = Invoke-SettingsLeave 'Save' @{ apiKeyUndetermined = $true } @($okBox)
    $st = Get-SettingsState
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Settings' -and $els.NavSettings.IsSelected -and $els.NavList.SelectedIndex -eq -1 -and [bool]$st['Dirty'] -and [int]$st['Held'].port -eq 9001 -and [int]$st['Held'].thinkingIndex -eq 1 -and [bool]$st['KeyMarked'] -and (Get-SettingsLogText) -ceq '' -and (Test-SettingsRecClean $d)) 'P31 Save refused in the prompt: the page stays selected in the second list, the edits are kept, the key row is marked and nothing is written' ((Get-SettingsPaneDetail) + " marked=$($st['KeyMarked']) " + (Get-SettingsRecDetail $d))
    # Don't save: reverted and left
    $d = Invoke-SettingsLeave 'Dont' @{}
    $st = Get-SettingsState
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Home' -and $els.NavHome.IsSelected -and $els.NavSettingsList.SelectedIndex -eq -1 -and (Get-SettingsLogText) -ceq '' -and [int]$st['Held'].port -eq 8080 -and [string]$els.SettingsPortBox.Text -ceq '8080' -and -not [bool]$st['Dirty'] -and (Test-SettingsRecClean $d)) "P31 Don't save: the edits are reverted, nothing is written and the page is left for Home" ((Get-SettingsPaneDetail) + " text='$($els.SettingsPortBox.Text)' " + (Get-SettingsRecDetail $d))
    # Cancel, Escape and Enter: stay with the edits
    foreach ($case in $stays) {
        $d = Invoke-SettingsLeave ([string]$case[0]) @{}
        $st = Get-SettingsState
        $rec = Get-SettingsRec $d 0
        Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Settings' -and $els.NavSettings.IsSelected -and $els.NavList.SelectedIndex -eq -1 -and [bool]$st['Dirty'] -and [int]$st['Held'].port -eq 9001 -and [string]$els.SettingsPortBox.Text -ceq '9001' -and [int]$st['Held'].thinkingIndex -eq 1 -and (Get-SettingsLogText) -ceq '' -and (Test-SettingsRecClean $d)) "P31 $($case[1]): the page stays (pane restored: the Settings item selected, the first list cleared), the edits are kept and nothing is written" ((Get-SettingsPaneDetail) + ' ' + (Get-SettingsRecDetail $d))
        Check ([bool]$rec['Found'] -and -not [bool]$rec['FellBack']) "P31 $($case[1]) closed the prompt by itself (the key, not the fallback click)" (Get-SettingsRecDetail $d)
    }
    # a clean leave never asks
    $null = Open-SettingsPage @{}
    $d = @{}
    $timer = Start-SettingsDialogs @((New-SettingsWatch)) $d
    try { $els.NavList.SelectedIndex = 0; Invoke-Pump 150 } finally { $timer.Stop() }
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Home' -and (Test-SettingsRecClean $d) -and $d['recs'].Count -eq 0) 'P31 leaving a clean Settings page asks nothing' ((Get-SettingsPaneDetail) + ' ' + (Get-SettingsRecDetail $d))
    Close-SettingsPage
    Check-NoExceptions 'P31'
}

# ---- P32: closing the window with edits ----
function Invoke-P32-Close {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $win = $f.Window
    $fs = $script:form.FastLlmFormState
    Check ($null -ne $fs['BeforeClosing']) 'P32 the shell registered the Settings close hook on the form adapter' ''
    $script:setCloseLog = New-Object System.Collections.ArrayList
    $recorder = { param($sender, $e) [void]$script:setCloseLog.Add([string]$e.CloseReason); $e.Cancel = $true }
    [void]$fs.FormClosing.Add($recorder)
    try {
        # Cancel in the prompt: no FormClosing guard ran, the timer still runs, the window and the edits stay
        $null = Open-SettingsPage @{}
        $st = Get-SettingsState
        $els.SettingsPortBox.Text = '9000'; $null = Send-ModelsKey $els.SettingsPortBox ([System.Windows.Input.Key]::Return)
        $script:setCloseLog.Clear()
        $d = @{}
        $timer = Start-SettingsDialogs @(@{ Kind = 'prompt'; Action = 'Cancel' }, (New-SettingsWatch)) $d
        try { $win.Close(); Invoke-Pump 150 } finally { $timer.Stop() }
        Check ($script:setCloseLog.Count -eq 0 -and [bool]$f.Timer.IsEnabled -and $win.IsVisible -and (Get-FastLlmUiFluentCurrentPage) -ceq 'Settings' -and [bool]$st['Dirty'] -and [int]$st['Held'].port -eq 9000 -and (Get-SettingsLogText) -ceq '' -and (Test-SettingsRecClean $d)) 'P32 dirty, X, Cancel: no FormClosing guard ran (the handler log is empty), the timer still runs, the window and the edits stay' ("guards=$($script:setCloseLog.Count) timer=$($f.Timer.IsEnabled) visible=$($win.IsVisible) " + (Get-SettingsPaneDetail) + ' ' + (Get-SettingsRecDetail $d))
        # Don't save on close: nothing is discarded before the guards run; the guards run once (the recorder stands for them and cancels, so the window stays), and the page is still dirty with its edits
        $script:setCloseLog.Clear()
        $d = @{}
        $timer = Start-SettingsDialogs @(@{ Kind = 'prompt'; Action = 'Dont' }, (New-SettingsWatch)) $d
        try { $win.Close(); Invoke-Pump 150 } finally { $timer.Stop() }
        Check ($script:setCloseLog.Count -eq 1 -and [string]$script:setCloseLog[0] -ceq 'UserClosing' -and (Get-SettingsLogText) -ceq '' -and [int]$st['Held'].port -eq 9000 -and [bool]$st['Dirty'] -and [string]$els.SettingsPortBox.Text -ceq '9000' -and (Test-SettingsRecClean $d)) "P32 dirty, X, Don't save: nothing is written or discarded before the guards, the FormClosing guards run once with UserClosing, and (a guard keeping the window open) the page is still dirty with its edits" ("guards=[$($script:setCloseLog.ToArray() -join ',')] heldPort=$($st['Held'].port) dirty=$($st['Dirty']) " + (Get-SettingsRecDetail $d))
        # Save ok on close: saved, then the guards run
        $els.SettingsPortBox.Text = '9003'; $null = Send-ModelsKey $els.SettingsPortBox ([System.Windows.Input.Key]::Return)
        $script:setCloseLog.Clear()
        $d = @{}
        $timer = Start-SettingsDialogs @(@{ Kind = 'prompt'; Action = 'Save' }, (New-SettingsWatch)) $d
        try { $win.Close(); Invoke-Pump 150 } finally { $timer.Stop() }
        Check ($script:setCloseLog.Count -eq 1 -and (Get-SettingsLogText) -ceq 'serving,allow,refresh' -and [int]$script:setFx.serverPort -eq 9003 -and (Test-SettingsRecClean $d)) 'P32 dirty, X, Save: the settings are saved, then the guards run once' ("guards=$($script:setCloseLog.Count) " + (Get-SettingsRecDetail $d) + " log=$(Get-SettingsLogText)")
        # Save refused on close: no guard runs, the window stays
        $null = Open-SettingsPage @{ apiKeyUndetermined = $true }
        $st = Get-SettingsState
        $els.SettingsPortBox.Text = '9000'; $null = Send-ModelsKey $els.SettingsPortBox ([System.Windows.Input.Key]::Return)
        $script:setCloseLog.Clear()
        $d = @{}
        $timer = Start-SettingsDialogs @(@{ Kind = 'prompt'; Action = 'Save' }, @{ Kind = 'box'; Caption = 'FastLLM settings'; Id = 2; Fallback = 2 }, (New-SettingsWatch)) $d
        try { $win.Close(); Invoke-Pump 150 } finally { $timer.Stop() }
        Check ($script:setCloseLog.Count -eq 0 -and $win.IsVisible -and [bool]$st['Dirty'] -and (Get-SettingsLogText) -ceq '' -and (Test-SettingsRecClean $d)) 'P32 dirty, X, Save refused: no guard ran, the window stays and the edits are kept' ("guards=$($script:setCloseLog.Count) " + (Get-SettingsRecDetail $d) + ' ' + (Get-SettingsPaneDetail))
        # Minimize to the tray while dirty: no prompt (the window is only hidden), and the edits are there after Restore
        $null = Open-SettingsPage @{}
        $st = Get-SettingsState
        $els.SettingsPortBox.Text = '9000'; $null = Send-ModelsKey $els.SettingsPortBox ([System.Windows.Input.Key]::Return)
        $script:setCloseLog.Clear()
        $d = @{}
        $timer = Start-SettingsDialogs @((New-SettingsWatch)) $d
        try {
            $win.WindowState = [System.Windows.WindowState]::Minimized
            $script:form.Hide()
            Invoke-Pump 150
            $script:form.Show()
            $script:form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
            $script:form.Activate()
            Invoke-Pump 200
        }
        finally { $timer.Stop() }
        Check ((Test-SettingsRecClean $d) -and $d['recs'].Count -eq 0 -and $script:setCloseLog.Count -eq 0 -and $win.WindowState -eq [System.Windows.WindowState]::Normal -and (Get-FastLlmUiFluentCurrentPage) -ceq 'Settings' -and [bool]$st['Dirty'] -and [int]$st['Held'].port -eq 9000 -and [string]$els.SettingsPortBox.Text -ceq '9000') 'P32 hide to the tray while dirty never asks, and the edits are kept after Restore' ((Get-SettingsRecDetail $d) + " guards=$($script:setCloseLog.Count) state=$($win.WindowState) " + (Get-SettingsPaneDetail))
        # The session-end hook (WindowsShutDown) while dirty: no prompt, nothing written; the guards still run (the recorder cancels)
        $d = @{}
        $timer = Start-SettingsDialogs @((New-SettingsWatch)) $d
        $refused = $null
        try { $refused = @(Invoke-FastLlmUiFormClosing -Form $script:form -CloseReason ([System.Windows.Forms.CloseReason]::WindowsShutDown)); Invoke-Pump 100 } finally { $timer.Stop() }
        Check ((Test-SettingsRecClean $d) -and $d['recs'].Count -eq 0 -and $script:setCloseLog.Count -eq 1 -and [string]$script:setCloseLog[0] -ceq 'WindowsShutDown' -and (Get-SettingsLogText) -ceq '' -and @($refused).Count -eq 1) 'P32 the session-end hook (WindowsShutDown) while dirty shows no prompt and writes nothing; the guards run once' ((Get-SettingsRecDetail $d) + " guards=[$($script:setCloseLog.ToArray() -join ',')] log=$(Get-SettingsLogText) results=$(@($refused).Count)")
    }
    finally { [void]$fs.FormClosing.Remove($recorder) }
    Close-SettingsPage
    Check (@($fs.FormClosing.ToArray() | Where-Object { [object]::ReferenceEquals($_, $recorder) }).Count -eq 0) 'P32 the recording FormClosing handler was removed again' ''
    Check-NoExceptions 'P32'
}

# ---- P33: Create a new key... ----
function Invoke-P33-NewKey {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $hwnd = Get-ModelsWindowHandle
    $null = Open-SettingsPage @{}
    $st = Get-SettingsState
    $script:apiKeyStore = 'probe-store-marker'
    $reads0 = $script:keyReadCalls
    $d = @{}
    $timer = Start-SettingsDialogs @(@{ Kind = 'box'; Caption = 'Create a new key'; Id = 6; Fallback = 7 }, @{ Kind = 'box'; Caption = 'Create a new key'; Id = 2; Fallback = 2 }, (New-SettingsWatch)) $d
    try { $els.SettingsNewKeyButton.RaiseEvent((New-ShellClick $els.SettingsNewKeyButton ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))); Invoke-Pump 150 } finally { $timer.Stop() }
    $yesNo = Get-SettingsRec $d 0
    $info = Get-SettingsRec $d 1
    Check ([bool]$yesNo['Found'] -and [bool]$yesNo['HasYes'] -and [long]$yesNo['Owner'] -eq $hwnd.ToInt64() -and [bool]$info['Found'] -and -not [bool]$info['HasYes'] -and [long]$info['Owner'] -eq $hwnd.ToInt64() -and (Test-SettingsRecClean $d)) 'P33 Create a new key shows the Yes/No box and then the OK box, both owned by the WPF window' (Get-SettingsRecDetail $d)
    Check ((Get-SettingsLogText) -ceq 'apikey:rotate') 'P33 the log has exactly one rotate and nothing else' "log=$(Get-SettingsLogText)"
    Check ($script:keyReadCalls -eq $reads0) 'P33 the stored key is never read (ReadUiApiKey moved by 0)' "reads before=$reads0 after=$($script:keyReadCalls)"
    Check ($null -eq $script:apiKeyStore) 'P33 the key store cache is cleared afterwards' "store=$($script:apiKeyStore)"
    Check (-not [bool]$st['Dirty'] -and (Get-FastLlmUiFluentCurrentPage) -ceq 'Settings') 'P33 a new key takes effect at once and is not a held edit (the page stays clean)' "dirty=$($st['Dirty'])"
    # No: nothing is rotated
    $script:setLog.Clear()
    $d = @{}
    $timer = Start-SettingsDialogs @(@{ Kind = 'box'; Caption = 'Create a new key'; Id = 7; Fallback = 7 }, (New-SettingsWatch)) $d
    try { $els.SettingsNewKeyButton.RaiseEvent((New-ShellClick $els.SettingsNewKeyButton ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))); Invoke-Pump 150 } finally { $timer.Stop() }
    Check ((Get-SettingsLogText) -ceq '' -and $d['recs'].Count -eq 1 -and (Test-SettingsRecClean $d)) 'P33 answering No creates nothing' ("log=$(Get-SettingsLogText) " + (Get-SettingsRecDetail $d))
    # A failing rotate: the Warning box shows the text with the key removed
    $script:setRotateThrows = 'Rotate failed for ' + [string]$script:markerKey
    $d = @{}
    $timer = Start-SettingsDialogs @(@{ Kind = 'box'; Caption = 'Create a new key'; Id = 6; Fallback = 7 }, @{ Kind = 'box'; Caption = 'FastLLM settings'; Id = 2; Fallback = 2 }, (New-SettingsWatch)) $d
    try { $els.SettingsNewKeyButton.RaiseEvent((New-ShellClick $els.SettingsNewKeyButton ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))); Invoke-Pump 150 } finally { $timer.Stop() }
    $warn = Get-SettingsRec $d 1
    Check ([bool]$warn['Found'] -and -not ([string]$warn['Text']).Contains([string]$script:markerKey) -and ([string]$warn['Text']).Contains('Rotate failed') -and (Test-SettingsRecClean $d)) 'P33 a failing rotate shows a Warning box whose text has no key in it' (Get-SettingsRecDetail $d)
    $script:setRotateThrows = ''
    Close-SettingsPage
    Check-NoExceptions 'P33'
}

# ---- P34: Settings unavailable ----
function Invoke-P34-Unavailable {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $s = $script:FastLlmUiFluentStrings
    $null = Open-SettingsPage @{}
    $st = Get-SettingsState
    Check ($els.SettingsServerGroup.IsEnabled -and $els.SettingsStartingGroup.IsEnabled -and $els.SettingsFooter.IsEnabled -and $els.SettingsUnavailableText.Visibility -eq [System.Windows.Visibility]::Collapsed) 'P34 an available Settings has its three groups enabled and no reason line' "server=$($els.SettingsServerGroup.IsEnabled) starting=$($els.SettingsStartingGroup.IsEnabled) footer=$($els.SettingsFooter.IsEnabled) line=$($els.SettingsUnavailableText.Visibility)"
    $els.SettingsPortBox.Text = '9000'; $null = Send-ModelsKey $els.SettingsPortBox ([System.Windows.Input.Key]::Return)
    $els.SettingsIdleBox.SelectedIndex = 3
    # a launch is running: Settings is unavailable
    $script:shellSnap = New-ShellSnap @{ Busy = $true; ChildActive = $true; Step = 'model download' }
    $script:settingsButton.Enabled = $false
    Invoke-FastLlmUiFluentTick
    Invoke-Pump 100
    Check ((-not $els.SettingsServerGroup.IsEnabled) -and (-not $els.SettingsStartingGroup.IsEnabled) -and (-not $els.SettingsFooter.IsEnabled) -and (-not $els.SettingsPortBox.IsEnabled) -and (-not $els.SettingsSaveButton.IsEnabled)) 'P34 a launch snapshot disables the Server group, the Starting group and the footer (so the fields, the sign-in toggle, Save and Discard)' "server=$($els.SettingsServerGroup.IsEnabled) starting=$($els.SettingsStartingGroup.IsEnabled) footer=$($els.SettingsFooter.IsEnabled) port=$($els.SettingsPortBox.IsEnabled) save=$($els.SettingsSaveButton.IsEnabled)"
    Check ([string]$els.SettingsUnavailableText.Text -ceq [string]$s.WhyBusy -and $els.SettingsUnavailableText.Visibility -eq [System.Windows.Visibility]::Visible -and [System.Windows.Automation.AutomationProperties]::GetHelpText($els.SettingsServerHeading) -ceq [string]$s.WhyBusy) 'P34 the reason line says WhyBusy and is visible; the Server heading carries it as help text' "text='$($els.SettingsUnavailableText.Text)' visibility=$($els.SettingsUnavailableText.Visibility) help='$([System.Windows.Automation.AutomationProperties]::GetHelpText($els.SettingsServerHeading))'"
    Check ($els.SettingsUpdateToggle.IsEnabled -and $els.SettingsExperimentalToggle.IsEnabled -and $els.SettingsLicenseToggle.IsEnabled) 'P34 the three Components and updates toggles stay enabled (as on today''s main window)' "update=$($els.SettingsUpdateToggle.IsEnabled) experimental=$($els.SettingsExperimentalToggle.IsEnabled) licence=$($els.SettingsLicenseToggle.IsEnabled)"
    Check ([bool]$st['Dirty'] -and [int]$st['Held'].port -eq 9000 -and [int]$st['Held'].idleIndex -eq 3 -and [string]$els.SettingsPortBox.Text -ceq '9000') 'P34 the held edits are kept while unavailable' "dirty=$($st['Dirty']) port=$($st['Held'].port) idle=$($st['Held'].idleIndex)"
    # Save is refused (a prompt's Save must never write while a run is starting), with no box and nothing written
    $d = @{}
    $timer = Start-SettingsDialogs @((New-SettingsWatch)) $d
    try { $r = @(Invoke-FastLlmUiFluentSettingsSave); Invoke-Pump 100 } finally { $timer.Stop() }
    Check ($r.Count -eq 1 -and $r[0] -is [bool] -and -not $r[0] -and (Get-SettingsLogText) -ceq '' -and (Test-SettingsRecClean $d) -and $d['recs'].Count -eq 0) 'P34 Save while unavailable returns one bool (false), shows no box and writes nothing' ("count=$($r.Count) value=$($r -join ',') log=$(Get-SettingsLogText) " + (Get-SettingsRecDetail $d))
    # leaving: the prompt has Save disabled and says why; Cancel keeps the page
    $d = @{}
    $timer = Start-SettingsDialogs @(@{ Kind = 'prompt'; Action = 'Cancel' }, (New-SettingsWatch)) $d
    try { $els.NavList.SelectedIndex = 0; Invoke-Pump 200 } finally { $timer.Stop() }
    $rec = Get-SettingsRec $d 0
    Check ([bool]$rec['Found'] -and -not [bool]$rec['SaveEnabled'] -and ([string]$rec['Body']).Contains([string]$s.WhyBusy) -and ([string]$rec['Body']).Contains([string]$s.SavePrompt) -and (Get-FastLlmUiFluentCurrentPage) -ceq 'Settings' -and (Test-SettingsRecClean $d)) 'P34 the prompt while unavailable has Save disabled and shows the reason under the question; Cancel keeps the page' ((Get-SettingsRecDetail $d) + ' ' + (Get-SettingsPaneDetail))
    # a different reason: Microsoft setup
    # as the window really has it: Microsoft setup runs under SetBusy (Busy true) with the broker process set; the broker alone leaves Settings available
    $script:shellSnap = New-ShellSnap @{ Busy = $true; VcBrokerActive = $true }
    Invoke-FastLlmUiFluentTick
    Invoke-Pump 50
    Check ([string]$els.SettingsUnavailableText.Text -ceq [string]$s.WhyMicrosoftSetup) 'P34 during Microsoft setup the reason line says WhyMicrosoftSetup' "text='$($els.SettingsUnavailableText.Text)' code='$(Get-FastLlmUiGreyedReason -Action 'settings' -Snapshot $script:shellSnap)'"
    # back to available: the edits are still there, the line goes
    $script:shellSnap = New-ShellSnap
    $script:settingsButton.Enabled = $true
    Invoke-FastLlmUiFluentTick
    Invoke-Pump 100
    Check ($els.SettingsServerGroup.IsEnabled -and $els.SettingsStartingGroup.IsEnabled -and $els.SettingsFooter.IsEnabled -and $els.SettingsUnavailableText.Visibility -eq [System.Windows.Visibility]::Collapsed -and [bool]$st['Dirty'] -and [int]$st['Held'].port -eq 9000 -and [string]$els.SettingsPortBox.Text -ceq '9000' -and [int]$els.SettingsIdleBox.SelectedIndex -eq 3) 'P34 back to available: the groups are enabled, the line is gone and the edits are still there' "server=$($els.SettingsServerGroup.IsEnabled) line=$($els.SettingsUnavailableText.Visibility) port='$($els.SettingsPortBox.Text)' idle=$($els.SettingsIdleBox.SelectedIndex)"
    Close-SettingsPage
    Check-NoExceptions 'P34'
}

# ---- P35: the sign-in toggle and the three Components and updates toggles ----
function Invoke-P35-Toggles {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $hwnd = Get-ModelsWindowHandle
    $null = Open-SettingsPage @{}
    $st = Get-SettingsState
    # Updates: one Set-FastLlmUpdateSettings per change, in the direction of the change
    $wantFirst = -not [bool]$els.SettingsUpdateToggle.IsChecked
    $els.SettingsUpdateToggle.IsChecked = $wantFirst
    Invoke-Pump 50
    $els.SettingsUpdateToggle.IsChecked = -not $wantFirst
    Invoke-Pump 50
    $wantTexts = @($(if ($wantFirst) { 'on' } else { 'off' }), $(if ($wantFirst) { 'off' } else { 'on' }))
    Check (($script:setUpdateWrites.ToArray() -join ',') -ceq ($wantTexts -join ',')) 'P35 the Updates toggle makes one Set-FastLlmUpdateSettings per change, in the direction of the change' "writes=$($script:setUpdateWrites.ToArray() -join ',') want=$($wantTexts -join ',')"
    # Experimental on: today's YesNo box (default No); Enter answers No: reverted, CheckedChanged ran twice (the revert re-enters under its guard), nothing mirrored
    if ($script:setExpEvents.Count -eq 0 -and -not $script:p35Attached) {
        $script:p35Attached = $true
        [void]$script:experimentalBox.PSObject.Methods['Add_CheckedChanged'].Invoke([scriptblock]::Create('[void]$script:setExpEvents.Add([string]$script:experimentalBox.Checked)'))
    }
    $script:setExpEvents.Clear()
    $d = @{}
    $timer = Start-SettingsDialogs @(@{ Kind = 'box'; Caption = 'Experimental community components'; Key = 0x0D; Fallback = 7 }, (New-SettingsWatch)) $d
    try { $els.SettingsExperimentalToggle.IsChecked = $true; Invoke-Pump 150 } finally { $timer.Stop() }
    $rec = Get-SettingsRec $d 0
    Check ([bool]$rec['Found'] -and [bool]$rec['HasYes'] -and [long]$rec['Owner'] -eq $hwnd.ToInt64() -and -not [bool]$rec['FellBack'] -and $script:setExpWrites.Count -eq 0 -and $els.SettingsExperimentalToggle.IsChecked -eq $false -and [bool]$script:experimentalBox.Checked -eq $false -and $script:setExpEvents.Count -eq 2 -and (Test-SettingsRecClean $d)) 'P35 Experimental on: Enter answers the YesNo box with its default No, the toggle is reverted, nothing is mirrored and CheckedChanged ran twice (the revert, under its guard)' ((Get-SettingsRecDetail $d) + " mirrored=$($script:setExpWrites.Count) toggle=$($els.SettingsExperimentalToggle.IsChecked) events=[$($script:setExpEvents.ToArray() -join ',')]")
    # Yes: mirrored once
    $script:setExpEvents.Clear()
    $d = @{}
    $timer = Start-SettingsDialogs @(@{ Kind = 'box'; Caption = 'Experimental community components'; Id = 6; Fallback = 7 }, (New-SettingsWatch)) $d
    try { $els.SettingsExperimentalToggle.IsChecked = $true; Invoke-Pump 150 } finally { $timer.Stop() }
    Check (($script:setExpWrites.ToArray() -join ',') -ceq 'on' -and $els.SettingsExperimentalToggle.IsChecked -eq $true -and $script:setExpEvents.Count -eq 1 -and (Test-SettingsRecClean $d)) 'P35 Experimental on with Yes: mirrored once (on), the toggle stays on, one CheckedChanged' ((Get-SettingsRecDetail $d) + " mirrored=[$($script:setExpWrites.ToArray() -join ',')] events=$($script:setExpEvents.Count)")
    $els.SettingsExperimentalToggle.IsChecked = $false
    Invoke-Pump 100
    Check (($script:setExpWrites.ToArray() -join ',') -ceq 'on,off') 'P35 Experimental off needs no box and is mirrored (off)' "mirrored=[$($script:setExpWrites.ToArray() -join ',')]"
    # Licence on: today's licence form (Enter and Escape both cancel); Escape: reverted, nothing written, no failure text
    Check (@($script:p30Missing | Where-Object { $_ -ceq 'ShowLicenseSettingConfirm' }).Count -eq 0) 'P35 the licence confirmation form (ShowLicenseSettingConfirm) is the real function of fast-llm-ui.ps1' ''
    $script:statusLabel.Text = 'status before the licence step'
    $d = @{}
    $timer = Start-SettingsDialogs @(@{ Kind = 'box'; Caption = 'Install engine components automatically'; Key = 0x1B; Fallback = 0 }, (New-SettingsWatch)) $d
    try { $els.SettingsLicenseToggle.IsChecked = $true; Invoke-Pump 150 } finally { $timer.Stop() }
    $rec = Get-SettingsRec $d 0
    Check ([bool]$rec['Found'] -and -not [bool]$rec['FellBack'] -and $script:setLicWrites.Count -eq 0 -and $els.SettingsLicenseToggle.IsChecked -eq $false -and [bool]$script:licenseBox.Checked -eq $false -and (Test-SettingsRecClean $d) -and -not ([string]$script:statusLabel.Text).Contains('could not be saved')) 'P35 Licence on: the real licence form opens, Escape cancels it, the toggle is reverted and nothing is written (and the revert is not the failure path)' ((Get-SettingsRecDetail $d) + " licenceWrites=$($script:setLicWrites.Count) toggle=$($els.SettingsLicenseToggle.IsChecked) status='$($script:statusLabel.Text)'")
    # Sign-in: one Set-FastLlmSignInStartEnabled per change; the toggle shows what was read back
    Check (-not [bool]$els.SettingsSignInToggle.IsChecked -and [string]$els.SettingsSignInState.Text -ceq 'Probe sign-in state False' -and [string]$els.SettingsSignInLast.Text -ceq 'Probe last result' -and [bool]$els.SettingsSignInToggle.IsEnabled) 'P35 Enter shows the sign-in view that was read: the toggle, its state line and the last result' "checked=$($els.SettingsSignInToggle.IsChecked) state='$($els.SettingsSignInState.Text)' last='$($els.SettingsSignInLast.Text)'"
    $reads0 = $script:setSignInReads
    $els.SettingsSignInToggle.IsChecked = $true
    Invoke-Pump 100
    Check (($script:setSignInSets.ToArray() -join ',') -ceq 'True' -and [string]$els.SettingsSignInState.Text -ceq 'Probe sign-in state True' -and $els.SettingsSignInToggle.IsChecked -eq $true) 'P35 the sign-in toggle makes exactly one Set-FastLlmSignInStartEnabled (True) and shows the returned view (no second write from the refill)' "sets=[$($script:setSignInSets.ToArray() -join ',')] state='$($els.SettingsSignInState.Text)'"
    # a failure: the Warning box (key-free), a re-read, and the toggle shows the stored truth
    $script:setSignInSetThrows = $true
    $d = @{}
    $timer = Start-SettingsDialogs @(@{ Kind = 'box'; Caption = 'FastLLM settings'; Id = 2; Fallback = 2 }, (New-SettingsWatch)) $d
    try { $els.SettingsSignInToggle.IsChecked = $false; Invoke-Pump 150 } finally { $timer.Stop(); $script:setSignInSetThrows = $false }
    $rec = Get-SettingsRec $d 0
    Check ([bool]$rec['Found'] -and ([string]$rec['Text']).Contains('sign-in write boom') -and ($script:setSignInSets.ToArray() -join ',') -ceq 'True,False' -and $script:setSignInReads -gt $reads0 -and $els.SettingsSignInToggle.IsChecked -eq $true -and (Test-SettingsRecClean $d)) 'P35 a failing sign-in write shows the Warning box, re-reads the setting and puts the toggle back to the stored value (no extra write)' ((Get-SettingsRecDetail $d) + " sets=[$($script:setSignInSets.ToArray() -join ',')] reads=$($script:setSignInReads - $reads0) toggle=$($els.SettingsSignInToggle.IsChecked)")
    # an unreadable sign-in setting disables the toggle with today's text
    $null = Close-SettingsPage
    Reset-SettingsFixture @{}
    $script:setSignInReadThrows = $true
    $null = Set-FastLlmUiFluentPage -Id 'Settings'
    Invoke-Pump 100
    $script:setSignInReadThrows = $false
    Check ((-not $els.SettingsSignInToggle.IsEnabled) -and [string]$els.SettingsSignInState.Text -ceq [string]$script:FastLlmUiFluentSettingsText.SignInUnreadable) 'P35 an unreadable sign-in setting disables the toggle and shows today''s text' "enabled=$($els.SettingsSignInToggle.IsEnabled) text='$($els.SettingsSignInState.Text)'"
    Close-SettingsPage
    Check-NoExceptions 'P35'
}

# ---- P36: the two-list pane and the keyboard ----
function Invoke-P36-Pane {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $win = $f.Window
    $none = [System.Windows.Input.KeyboardNavigationMode]::None
    $once = [System.Windows.Input.KeyboardNavigationMode]::Once
    $null = Open-SettingsPage @{}
    $st = Get-SettingsState
    $navMode = [System.Windows.Input.KeyboardNavigation]::GetTabNavigation($els.NavList)
    $setMode = [System.Windows.Input.KeyboardNavigation]::GetTabNavigation($els.NavSettingsList)
    Check ($els.NavSettings.IsSelected -and $els.NavList.SelectedIndex -eq -1 -and $els.NavSettingsList.SelectedIndex -eq 0 -and $navMode -eq $none -and $setMode -eq $once) 'P36 Settings selected: the first list is cleared and skipped by Tab (None), the second list holds the selection (Once)' "navSettings=$($els.NavSettings.IsSelected) list=$($els.NavList.SelectedIndex) settingsList=$($els.NavSettingsList.SelectedIndex) navMode=$navMode settingsMode=$setMode"
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Invoke-Pump 100
    $navMode = [System.Windows.Input.KeyboardNavigation]::GetTabNavigation($els.NavList)
    $setMode = [System.Windows.Input.KeyboardNavigation]::GetTabNavigation($els.NavSettingsList)
    Check ($els.NavHome.IsSelected -and $els.NavSettingsList.SelectedIndex -eq -1 -and $els.NavList.SelectedIndex -eq 0 -and $navMode -eq $once -and $setMode -eq $none) 'P36 Home selected: the second list is cleared and skipped by Tab, the first list holds the selection' "navHome=$($els.NavHome.IsSelected) list=$($els.NavList.SelectedIndex) settingsList=$($els.NavSettingsList.SelectedIndex) navMode=$navMode settingsMode=$setMode"
    # a refused Leave from Settings restores both lists
    $null = Open-SettingsPage @{}
    $st = Get-SettingsState
    $els.SettingsPortBox.Text = '9001'
    $d = @{}
    $timer = Start-SettingsDialogs @(@{ Kind = 'prompt'; Action = 'Cancel' }, (New-SettingsWatch)) $d
    try { $els.NavList.SelectedIndex = 2; Invoke-Pump 200 } finally { $timer.Stop() }
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Settings' -and $els.NavSettings.IsSelected -and $els.NavSettingsList.SelectedIndex -eq 0 -and $els.NavList.SelectedIndex -eq -1 -and [System.Windows.Input.KeyboardNavigation]::GetTabNavigation($els.NavList) -eq $none -and [System.Windows.Input.KeyboardNavigation]::GetTabNavigation($els.NavSettingsList) -eq $once -and (Test-SettingsRecClean $d)) 'P36 a refused Leave (Cancel) restores both lists: Settings selected again, the first list cleared, the tab modes as before' ((Get-SettingsPaneDetail) + ' ' + (Get-SettingsRecDetail $d))
    Close-SettingsPage
    # arrows across the two lists: Down from Tools reaches Settings, Up from Settings returns to Tools
    $null = Set-FastLlmUiFluentPage -Id 'Tools'
    $null = $win.Activate()
    $null = $els.NavTools.Focus()
    Invoke-Pump 150
    $pathDown = Send-ModelsKeyChecked $els.NavTools ([System.Windows.Input.Key]::Down) 0x28 ({ (Get-FastLlmUiFluentCurrentPage) -ceq 'Settings' })
    Invoke-Pump 150
    $focused = [System.Windows.Input.Keyboard]::FocusedElement
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Settings' -and $els.NavSettings.IsSelected -and $els.NavList.SelectedIndex -eq -1 -and ([object]::ReferenceEquals($focused, $els.NavSettings) -or $els.NavSettings.IsKeyboardFocused)) 'P36 Down on the last item of the first list (Tools) selects and focuses Settings in the second list' "path=$pathDown current=$(Get-FastLlmUiFluentCurrentPage) navSettings=$($els.NavSettings.IsSelected) focused=$(if ($null -ne $focused) { $focused.GetType().Name } else { 'nothing' })"
    $pathUp = Send-ModelsKeyChecked $els.NavSettings ([System.Windows.Input.Key]::Up) 0x26 ({ (Get-FastLlmUiFluentCurrentPage) -ceq 'Tools' })
    Invoke-Pump 150
    $focused = [System.Windows.Input.Keyboard]::FocusedElement
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Tools' -and $els.NavTools.IsSelected -and $els.NavSettingsList.SelectedIndex -eq -1 -and ([object]::ReferenceEquals($focused, $els.NavTools) -or $els.NavTools.IsKeyboardFocused)) 'P36 Up on the Settings item selects and focuses the last item of the first list (Tools)' "path=$pathUp current=$(Get-FastLlmUiFluentCurrentPage) navTools=$($els.NavTools.IsSelected) focused=$(if ($null -ne $focused) { $focused.GetType().Name } else { 'nothing' })"
    # Down from Tools with unsaved edits asks first and a Cancel keeps Settings out of reach: edits only exist while on Settings, so the Home arrow is the plain case
    # Tab from the pane lands in the page, and Shift+Tab returns to the selected item
    $null = Open-SettingsPage @{}
    $null = $win.Activate()
    $null = $els.NavSettings.Focus()
    Invoke-Pump 200
    $cur = [System.Windows.Input.Keyboard]::FocusedElement
    $started = ($null -ne $cur) -and [object]::ReferenceEquals($cur, $els.NavSettings)
    $null = $cur.MoveFocus((New-Object System.Windows.Input.TraversalRequest([System.Windows.Input.FocusNavigationDirection]::Next)))
    Invoke-Pump 100
    $inside = [System.Windows.Input.Keyboard]::FocusedElement
    $insidePage = ($null -ne $inside) -and ($inside -is [System.Windows.DependencyObject]) -and $f.Pages['Settings']['Element'].IsAncestorOf($inside)
    $null = $inside.MoveFocus((New-Object System.Windows.Input.TraversalRequest([System.Windows.Input.FocusNavigationDirection]::Previous)))
    Invoke-Pump 100
    $back = [System.Windows.Input.Keyboard]::FocusedElement
    Check ($started -and $insidePage -and $null -ne $back -and [object]::ReferenceEquals($back, $els.NavSettings)) 'P36 Tab from the Settings pane item lands in the page, and Shift+Tab returns to the selected item' "started=$started insidePage=$insidePage first=$(if ($null -ne $inside) { $inside.GetType().Name } else { 'nothing' }) back=$(if ($null -ne $back) { $back.GetType().Name } else { 'nothing' })"
    # and from Home: Tab from the pane never visits the Settings item
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    Invoke-Pump 100
    $walk = Get-PagesTabWalk $els.NavHome
    $settingsStops = @($walk.Stops | Where-Object { [object]::ReferenceEquals($_.Element, $els.NavSettings) })
    Check ($walk.Started -and $settingsStops.Count -eq 0) 'P36 with Home selected, the Tab walk from the pane never stops on the Settings item (the second list is skipped)' "started=$($walk.Started) stops=$($walk.Stops.Count) settingsStops=$($settingsStops.Count)"
    Close-SettingsPage
    Check-NoExceptions 'P36'
}

# ---- P38: the Settings additions (context profile, requests at once, embeddings and its port) ----
# Settings additions (new step): the four rows are held Server edits. Their availability is read on Enter through the two probes (stubbed by the fixture: 'embAvail' and
# 'longMeasured'); the recorder sees exactly the Set-FastLlmServingSettings parameters the page GAVE (an untouched field is not passed, a changed one is, with its held value).
function Get-P38Bound {
    if ($null -eq $script:setLastNew) { return '' }
    $keys = [string[]]@($script:setLastNew.Keys)
    [Array]::Sort($keys, [System.StringComparer]::Ordinal)
    return ($keys -join ',')
}
# The stops of a Tab walk from the Settings pane item that lie inside an element.
function Get-P38StopsInside($Walk, $Group) {
    $in = New-Object System.Collections.ArrayList
    foreach ($stop in @($Walk.Stops)) {
        if ($stop.Element -is [System.Windows.DependencyObject] -and ([object]::ReferenceEquals($stop.Element, $Group) -or $Group.IsAncestorOf($stop.Element))) { [void]$in.Add($stop) }
    }
    return $in.ToArray()
}
function Invoke-P38SaveWithDialogs {
    $d = @{}
    $timer = Start-SettingsDialogs @((New-SettingsWatch)) $d
    try { $r = @(Invoke-FastLlmUiFluentSettingsSave); Invoke-Pump 50 } finally { $timer.Stop() }
    $script:p38Save = @{ R = $r; D = $d }
}
function Invoke-P38-SettingsAdditions {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f.Els
    $win = $f.Window
    $s = $script:FastLlmUiFluentStrings
    $hidden = [System.Windows.Visibility]::Collapsed
    $shown = [System.Windows.Visibility]::Visible
    $two = $els.SettingsRequestsBox

    # A. The Embeddings rows follow the two answers read on Enter and the saved value (lead ruling A4): neither hides them, an available model or a saved 'on' shows them.
    # The measured-setup probe answers two questions on Enter: Long at the held requests value, and 2 for the held profile (fixture: default, 1).
    $probesBefore = @{ emb = [int]$script:setProbeCalls['emb']; long = [int]$script:setProbeCalls['long']; asked = [int]$script:setProbeAsked.Count }
    $null = Open-SettingsPage @{ embAvail = $false; embeddings = 'off' }
    $st = Get-SettingsState
    $askedOnEnter = @($script:setProbeAsked.ToArray() | Select-Object -Skip $probesBefore.asked)
    $askedSorted = (@($askedOnEnter | Sort-Object -CaseSensitive) -join ',')
    Check ([int]$script:setProbeCalls['emb'] -eq $probesBefore.emb + 1 -and [int]$script:setProbeCalls['long'] -eq $probesBefore.long + 2 -and $askedSorted -ceq 'default:2,long:1') 'P38 opening the page reads the embeddings probe once and the measured-setup probe once per question (Long at the held requests value, 2 for the held profile)' "emb=$($script:setProbeCalls['emb']) long=$($script:setProbeCalls['long']) before=$($probesBefore.emb)/$($probesBefore.long) asked='$($askedOnEnter -join ',')'"
    Check ($els.SettingsEmbeddingsGroup.Visibility -eq $hidden -and -not $els.SettingsEmbeddingsBox.IsVisible -and -not $els.SettingsEmbeddingPortRow.IsVisible -and -not $els.SettingsEmbeddingsHelp.IsVisible) 'P38 embeddings unavailable and saved off: both Embeddings rows (the box with its help, and the port row) are hidden' "group=$($els.SettingsEmbeddingsGroup.Visibility) box=$($els.SettingsEmbeddingsBox.IsVisible) port=$($els.SettingsEmbeddingPortRow.IsVisible)"
    $null = Open-SettingsPage @{ embAvail = $true; embeddings = 'off' }
    $st = Get-SettingsState
    Check ($els.SettingsEmbeddingsGroup.Visibility -eq $shown -and $els.SettingsEmbeddingsBox.IsVisible -and $els.SettingsEmbeddingsBox.IsChecked -eq $false -and $els.SettingsEmbeddingPortGroup.Visibility -eq $hidden -and -not $els.SettingsEmbeddingPortRow.IsVisible -and -not [bool]$st['Dirty']) 'P38 embeddings available and saved off: the box shows, unticked, and the port row is collapsed' "group=$($els.SettingsEmbeddingsGroup.Visibility) checked=$($els.SettingsEmbeddingsBox.IsChecked) portGroup=$($els.SettingsEmbeddingPortGroup.Visibility)"
    Check ([string]$els.SettingsEmbeddingsHelp.Text -ceq [string]$s.EmbeddingsHelp -and $els.SettingsEmbeddingsHelp.IsVisible -and [string][System.Windows.Automation.AutomationProperties]::GetName($els.SettingsEmbeddingsBox) -ceq [string]$s.Embeddings) 'P38 the Embeddings box has its caption as its name and its help line is shown' "help='$($els.SettingsEmbeddingsHelp.Text)' name='$([System.Windows.Automation.AutomationProperties]::GetName($els.SettingsEmbeddingsBox))'"
    $null = Open-SettingsPage @{ embAvail = $false; embeddings = 'on'; embeddingPort = 9100 }
    $st = Get-SettingsState
    Check ($els.SettingsEmbeddingsGroup.Visibility -eq $shown -and $els.SettingsEmbeddingsBox.IsVisible -and $els.SettingsEmbeddingsBox.IsChecked -eq $true -and $els.SettingsEmbeddingPortGroup.Visibility -eq $shown -and [string]$els.SettingsEmbeddingPortBox.Text -ceq '9100' -and -not [bool]$st['Dirty']) 'P38 embeddings unavailable but saved on (set by the CLI): the rows show with the saved values so the user can turn it off' "group=$($els.SettingsEmbeddingsGroup.Visibility) checked=$($els.SettingsEmbeddingsBox.IsChecked) portGroup=$($els.SettingsEmbeddingPortGroup.Visibility) text='$($els.SettingsEmbeddingPortBox.Text)'"
    $els.SettingsEmbeddingsBox.IsChecked = $false
    Invoke-Pump 50
    Check ($els.SettingsEmbeddingsBox.IsEnabled -and [string]$st['Held'].embeddings -ceq 'off' -and [int]$st['Held'].embeddingPort -eq 9100 -and [bool]$st['Dirty'] -and $els.SettingsEmbeddingPortGroup.Visibility -eq $hidden -and $els.SettingsEmbeddingsGroup.Visibility -eq $shown) 'P38 a saved-on box (model unavailable) can be unticked: held off, dirty, the port row collapses, the port is kept as a held value, the box stays shown' "enabled=$($els.SettingsEmbeddingsBox.IsEnabled) held=$($st['Held'].embeddings)/$($st['Held'].embeddingPort) dirty=$($st['Dirty']) portGroup=$($els.SettingsEmbeddingPortGroup.Visibility)"
    $d = @{}
    $timer = Start-SettingsDialogs @((New-SettingsWatch)) $d
    try { $r = @(Invoke-FastLlmUiFluentSettingsSave); Invoke-Pump 50 } finally { $timer.Stop() }
    Check ($r.Count -eq 1 -and $r[0] -and (Get-P38Bound) -ceq 'Embeddings' -and [string]$script:setLastNew['Embeddings'] -ceq 'off' -and (Test-SettingsRecClean $d)) 'P38 unticking a saved-on box and saving passes exactly -Embeddings off (not the port)' "bound=$(Get-P38Bound) log=$(Get-SettingsLogText)"
    Check ($els.SettingsEmbeddingsGroup.Visibility -eq $hidden -and $els.SettingsEmbeddingsBox.IsChecked -eq $false -and -not [bool]$st['Dirty'] -and [int]$script:setProbeCalls['emb'] -eq $probesBefore.emb + 3) 'P38 after that Save the page is reloaded without reading the probes again, and with the saved value now off and no model available the Embeddings rows are hidden (A4)' "group=$($els.SettingsEmbeddingsGroup.Visibility) emb=$($script:setProbeCalls['emb']) want=$($probesBefore.emb + 3)"
    # the probes are read on Enter only, never on a tick
    $callsBeforeTicks = @{ emb = [int]$script:setProbeCalls['emb']; long = [int]$script:setProbeCalls['long'] }
    for ($i = 0; $i -lt 3; $i++) { Invoke-FastLlmUiFluentTick; Invoke-Pump 30 }
    Check ([int]$script:setProbeCalls['emb'] -eq $callsBeforeTicks.emb -and [int]$script:setProbeCalls['long'] -eq $callsBeforeTicks.long) 'P38 three ticks on the page read neither probe' "emb=$($script:setProbeCalls['emb']) long=$($script:setProbeCalls['long']) before=$($callsBeforeTicks.emb)/$($callsBeforeTicks.long)"

    # B. The port row collapses and expands with the box, and focus is never left on a collapsed row.
    $null = Open-SettingsPage @{ embAvail = $true }
    $st = Get-SettingsState
    $null = $win.Activate()
    $null = $els.SettingsEmbeddingsBox.Focus()
    Invoke-Pump 100
    $els.SettingsEmbeddingsBox.IsChecked = $true
    Invoke-Pump 80
    Check ($els.SettingsEmbeddingPortGroup.Visibility -eq $shown -and $els.SettingsEmbeddingPortRow.IsVisible -and [string]$els.SettingsEmbeddingPortBox.Text -ceq '8081' -and [string]$st['Held'].embeddings -ceq 'on' -and [bool]$st['Dirty']) 'P38 ticking Embeddings shows the port row with the saved port 8081, and the page is dirty' "portGroup=$($els.SettingsEmbeddingPortGroup.Visibility) text='$($els.SettingsEmbeddingPortBox.Text)' held=$($st['Held'].embeddings) dirty=$($st['Dirty'])"
    Check ([string][System.Windows.Automation.AutomationProperties]::GetName($els.SettingsEmbeddingPortBox) -ceq [string]$s.EmbeddingPort -and [string]$els.SettingsEmbeddingPortLabel.Text -ceq [string]$s.EmbeddingPort) 'P38 the port box is named with its label text' "name='$([System.Windows.Automation.AutomationProperties]::GetName($els.SettingsEmbeddingPortBox))' label='$($els.SettingsEmbeddingPortLabel.Text)'"
    $walk = Get-PagesTabWalk $els.NavSettings
    $portStops = @($walk.Stops | Where-Object { [object]::ReferenceEquals($_.Element, $els.SettingsEmbeddingPortBox) })
    $boxStops = @($walk.Stops | Where-Object { [object]::ReferenceEquals($_.Element, $els.SettingsEmbeddingsBox) })
    Check ($walk.Started -and $boxStops.Count -eq 1 -and $portStops.Count -eq 1) 'P38 with Embeddings ticked, the Tab walk stops once on the Embeddings box and once on the port box' "started=$($walk.Started) box=$($boxStops.Count) port=$($portStops.Count) stops=$($walk.Stops.Count)"
    # focus is in the port row; the row collapses (Discard), and the keyboard is not left on it
    $null = $win.Activate()
    $null = $els.SettingsEmbeddingPortBox.Focus()
    Invoke-Pump 100
    Invoke-FastLlmUiFluentSettingsDiscard
    Invoke-Pump 80
    $kb = [System.Windows.Input.Keyboard]::FocusedElement
    $kbInGroup = ($null -ne $kb -and $kb -is [System.Windows.DependencyObject] -and ([object]::ReferenceEquals($kb, $els.SettingsEmbeddingPortGroup) -or $els.SettingsEmbeddingPortGroup.IsAncestorOf($kb)))
    Check ($els.SettingsEmbeddingPortGroup.Visibility -eq $hidden -and -not $els.SettingsEmbeddingPortBox.IsVisible -and -not $kbInGroup -and -not [bool]$st['Dirty']) 'P38 Discard with the keyboard focus in the port row collapses the row and the keyboard focus is not left inside it' "portGroup=$($els.SettingsEmbeddingPortGroup.Visibility) focus=$(if ($null -ne $kb) { $kb.GetType().Name } else { 'none' }) inGroup=$kbInGroup dirty=$($st['Dirty'])"
    Write-Host ("INFO: P38 after the port row collapsed with the focus in it, the keyboard focus is on " + $(if ($null -ne $kb) { $kb.GetType().Name + ':' + [string]$kb.Name } else { 'nothing' }))
    $walk = Get-PagesTabWalk $els.NavSettings
    $inGroup = @(Get-P38StopsInside $walk $els.SettingsEmbeddingPortGroup)
    $inPage = @(Get-PagesStopsIn $walk $f.Pages['Settings']['Element'])
    Check ($walk.Started -and $inGroup.Count -eq 0 -and $inPage.Count -gt 5) 'P38 with the row collapsed the Tab walk never stops inside it and still walks the page (no stranded focus)' "started=$($walk.Started) inGroup=$($inGroup.Count) inPage=$($inPage.Count)"
    # the focus is on the box itself while it is ticked and unticked (set directly, not by a key press): the box keeps the focus and the row goes
    $null = $win.Activate()
    $null = $els.SettingsEmbeddingsBox.Focus()
    Invoke-Pump 80
    $els.SettingsEmbeddingsBox.IsChecked = $true
    Invoke-Pump 50
    $els.SettingsEmbeddingsBox.IsChecked = $false
    Invoke-Pump 80
    $logical = [System.Windows.Input.FocusManager]::GetFocusedElement($win)
    Check ($els.SettingsEmbeddingPortGroup.Visibility -eq $hidden -and [object]::ReferenceEquals($logical, $els.SettingsEmbeddingsBox) -and -not [bool]$st['Dirty']) 'P38 ticking and unticking from the box leaves the focus on the box, the row collapsed and the page clean again' "portGroup=$($els.SettingsEmbeddingPortGroup.Visibility) focus=$(if ($null -ne $logical) { $logical.GetType().Name + ':' + $logical.Name } else { 'none' }) dirty=$($st['Dirty'])"

    # C. A3: the same port as the server's. The message shows at once (polite), Save is refused with no write and the edits stay, and changing the port clears the message.
    $null = Open-SettingsPage @{ embAvail = $true }
    $st = Get-SettingsState
    $els.SettingsEmbeddingsBox.IsChecked = $true
    Invoke-Pump 50
    Check ($els.SettingsEmbeddingPortSame.Visibility -eq $hidden -and [string]$els.SettingsEmbeddingPortSame.Text -ceq '') 'P38 ticking Embeddings with different ports (8080 and 8081) shows no same-port message' "visibility=$($els.SettingsEmbeddingPortSame.Visibility) text='$($els.SettingsEmbeddingPortSame.Text)'"
    $els.SettingsEmbeddingPortBox.Text = '8080'
    $null = Send-ModelsKey $els.SettingsEmbeddingPortBox ([System.Windows.Input.Key]::Return)
    Invoke-Pump 50
    $live = [System.Windows.Automation.AutomationProperties]::GetLiveSetting($els.SettingsEmbeddingPortSame)
    Check ($els.SettingsEmbeddingPortSame.Visibility -eq $shown -and $els.SettingsEmbeddingPortSame.IsVisible -and [string]$els.SettingsEmbeddingPortSame.Text -ceq [string]$s.EmbeddingPortSame -and $live -eq [System.Windows.Automation.AutomationLiveSetting]::Polite) 'P38 setting the embeddings port equal to the server port shows the inline EmbeddingPortSame message at once, as a polite live region' "visibility=$($els.SettingsEmbeddingPortSame.Visibility) text='$($els.SettingsEmbeddingPortSame.Text)' live=$live"
    Check ((Get-SettingsLogText) -ceq '') 'P38 the inline message wrote nothing' "log=$(Get-SettingsLogText)"
    $null = $win.Activate()
    Invoke-P38SaveWithDialogs
    $r = @($script:p38Save.R)
    Check ($r.Count -eq 1 -and $r[0] -is [bool] -and -not $r[0] -and (Get-SettingsLogText) -ceq '' -and $null -eq $script:setLastServing -and $null -eq $script:setLastNew -and $null -eq $script:setAllowStored -and (Test-SettingsRecClean $script:p38Save.D) -and $script:p38Save.D['recs'].Count -eq 0) 'P38 Save with equal ports returns one bool (false), writes nothing at all and shows no box' ("count=$($r.Count) value=$($r -join ',') log=$(Get-SettingsLogText) " + (Get-SettingsRecDetail $script:p38Save.D))
    $logical = [System.Windows.Input.FocusManager]::GetFocusedElement($win)
    Check ((Get-FastLlmUiFluentCurrentPage) -ceq 'Settings' -and [bool]$st['Dirty'] -and [string]$st['Held'].embeddings -ceq 'on' -and [int]$st['Held'].embeddingPort -eq 8080 -and [string]$els.SettingsEmbeddingPortBox.Text -ceq '8080' -and $els.SettingsEmbeddingsBox.IsChecked -eq $true -and $els.SettingsEmbeddingPortSame.Visibility -eq $shown) 'P38 after the refused Save the page and every edit stay, and the message still shows' "dirty=$($st['Dirty']) held=$($st['Held'].embeddings)/$($st['Held'].embeddingPort) text='$($els.SettingsEmbeddingPortBox.Text)' msg=$($els.SettingsEmbeddingPortSame.Visibility)"
    Check ([object]::ReferenceEquals($logical, $els.SettingsEmbeddingPortBox)) 'P38 the refused Save puts the focus on the port box' "focus=$(if ($null -ne $logical) { $logical.GetType().Name + ':' + $logical.Name } else { 'none' })"
    $els.SettingsEmbeddingPortBox.Text = '9100'
    $null = Send-ModelsKey $els.SettingsEmbeddingPortBox ([System.Windows.Input.Key]::Return)
    Invoke-Pump 50
    Check ($els.SettingsEmbeddingPortSame.Visibility -eq $hidden -and [string]$els.SettingsEmbeddingPortSame.Text -ceq '' -and [int]$st['Held'].embeddingPort -eq 9100) 'P38 changing the embeddings port clears the message' "visibility=$($els.SettingsEmbeddingPortSame.Visibility) text='$($els.SettingsEmbeddingPortSame.Text)' held=$($st['Held'].embeddingPort)"
    Invoke-P38SaveWithDialogs
    $r = @($script:p38Save.R)
    Check ($r.Count -eq 1 -and $r[0] -and (Get-SettingsLogText) -ceq 'serving,allow,refresh' -and (Get-P38Bound) -ceq 'EmbeddingPort,Embeddings' -and [string]$script:setLastNew['Embeddings'] -ceq 'on' -and [int]$script:setLastNew['EmbeddingPort'] -eq 9100 -and (Test-SettingsRecClean $script:p38Save.D)) 'P38 after the change the same Save goes through and passes exactly -Embeddings on and -EmbeddingPort 9100' ("bound=$(Get-P38Bound) log=$(Get-SettingsLogText) " + (Get-SettingsRecDetail $script:p38Save.D))
    # the server port moved onto the embeddings port shows the message too; unticking hides it; with Embeddings off equal ports are not refused
    $null = Open-SettingsPage @{ embAvail = $true }
    $st = Get-SettingsState
    $els.SettingsEmbeddingsBox.IsChecked = $true
    $els.SettingsPortBox.Text = '8081'
    $null = Send-ModelsKey $els.SettingsPortBox ([System.Windows.Input.Key]::Return)
    Invoke-Pump 50
    Check ($els.SettingsEmbeddingPortSame.Visibility -eq $shown -and [string]$els.SettingsEmbeddingPortSame.Text -ceq [string]$s.EmbeddingPortSame) 'P38 moving the server port onto the embeddings port (8081) shows the message' "visibility=$($els.SettingsEmbeddingPortSame.Visibility) held=$($st['Held'].port)/$($st['Held'].embeddingPort)"
    $els.SettingsEmbeddingsBox.IsChecked = $false
    Invoke-Pump 50
    Check ($els.SettingsEmbeddingPortSame.Visibility -eq $hidden -and $els.SettingsEmbeddingPortGroup.Visibility -eq $hidden) 'P38 unticking Embeddings hides the message with the port row' "visibility=$($els.SettingsEmbeddingPortSame.Visibility)"
    Invoke-P38SaveWithDialogs
    $r = @($script:p38Save.R)
    Check ($r.Count -eq 1 -and $r[0] -and (Get-SettingsLogText) -ceq 'serving,allow,refresh' -and [int]$script:setFx.serverPort -eq 8081 -and (Get-P38Bound) -ceq '') 'P38 with Embeddings off, equal ports are not refused (the guard is only for Embeddings on) and no addition is passed' ("bound=$(Get-P38Bound) log=$(Get-SettingsLogText) " + (Get-SettingsRecDetail $script:p38Save.D))

    # D. Long: disabled with its reason unless it is measured or already saved.
    $null = Open-SettingsPage @{ longMeasured = $false; contextProfile = 'default' }
    $st = Get-SettingsState
    $why = $els.SettingsContextProfileWhy
    Check (-not [bool]$els.SettingsContextProfileBox.Items[1].IsEnabled -and [bool]$els.SettingsContextProfileBox.Items[0].IsEnabled -and [int]$els.SettingsContextProfileBox.SelectedIndex -eq 0 -and $why.Visibility -eq $shown -and $why.IsVisible -and [string]$why.Text -ceq [string]$s.LongNotMeasured) 'P38 Long not measured and saved Default: the Long item is disabled, Default is selected and the reason line shows the LongNotMeasured text' "long=$($els.SettingsContextProfileBox.Items[1].IsEnabled) default=$($els.SettingsContextProfileBox.Items[0].IsEnabled) selected=$($els.SettingsContextProfileBox.SelectedIndex) why=$($why.Visibility) text='$($why.Text)'"
    Check ([System.Windows.Automation.AutomationProperties]::GetLiveSetting($why) -eq [System.Windows.Automation.AutomationLiveSetting]::Polite -and [string][System.Windows.Automation.AutomationProperties]::GetHelpText($els.SettingsContextProfileBox) -ceq [string]$s.LongNotMeasured -and [string]$els.SettingsContextProfileHelp.Text -ceq [string]$s.ContextProfileHelp) 'P38 the reason is a polite live region and the help text of the box; the ordinary help line stays' "live=$([System.Windows.Automation.AutomationProperties]::GetLiveSetting($why)) help='$([System.Windows.Automation.AutomationProperties]::GetHelpText($els.SettingsContextProfileBox))'"
    $null = Open-SettingsPage @{ longAt = @(2); contextProfile = 'long' }
    $st = Get-SettingsState
    Check ([bool]$els.SettingsContextProfileBox.Items[1].IsEnabled -and [int]$els.SettingsContextProfileBox.SelectedIndex -eq 1 -and $els.SettingsContextProfileWhy.Visibility -eq $hidden -and [string]$st['Held'].contextProfile -ceq 'long' -and -not [bool]$st['Dirty']) 'P38 Long not measured but already saved: the Long item is enabled and selected, no reason line, and the page is clean' "long=$($els.SettingsContextProfileBox.Items[1].IsEnabled) selected=$($els.SettingsContextProfileBox.SelectedIndex) why=$($els.SettingsContextProfileWhy.Visibility) held=$($st['Held'].contextProfile)"
    $null = Open-SettingsPage @{ longMeasured = $true; contextProfile = 'default' }
    $st = Get-SettingsState
    Check ([bool]$els.SettingsContextProfileBox.Items[1].IsEnabled -and $els.SettingsContextProfileWhy.Visibility -eq $hidden -and [string]$els.SettingsContextProfileWhy.Text -ceq '') 'P38 Long measured: the Long item is enabled and there is no reason line' "long=$($els.SettingsContextProfileBox.Items[1].IsEnabled) why=$($els.SettingsContextProfileWhy.Visibility)"
    $els.SettingsContextProfileBox.SelectedIndex = 1
    Invoke-Pump 30
    Check ([string]$st['Held'].contextProfile -ceq 'long' -and [bool]$st['Dirty']) 'P38 with Long measured, choosing Long holds long and makes the page dirty' "held=$($st['Held'].contextProfile) dirty=$($st['Dirty'])"

    # D2. The long probe follows the held requests-at-once value: measured at 1 only, so choosing 2 disables Long (with the reason) and going back to 1 enables it again.
    $null = Open-SettingsPage @{ longAt = @(1); contextProfile = 'default' }
    $st = Get-SettingsState
    Check ([bool]$els.SettingsContextProfileBox.Items[1].IsEnabled -and $els.SettingsContextProfileWhy.Visibility -eq $hidden -and @($script:setProbeAsked) -contains 'long:1') 'P38 Long measured at one request at once: on Enter the probe is asked for Long with slots 1 and Long is enabled' "long=$($els.SettingsContextProfileBox.Items[1].IsEnabled) slots=$($script:setProbeSlots[$script:setProbeSlots.Count - 1])"
    $callsBefore = [int]$script:setProbeCalls['long']
    $els.SettingsRequestsBox.SelectedIndex = 1
    Invoke-Pump 50
    Check ((-not [bool]$els.SettingsContextProfileBox.Items[1].IsEnabled) -and $els.SettingsContextProfileWhy.Visibility -eq $shown -and [string]$els.SettingsContextProfileWhy.Text -ceq [string]$s.LongNotMeasured -and [int]$script:setProbeCalls['long'] -eq $callsBefore + 1 -and [int]$script:setProbeSlots[$script:setProbeSlots.Count - 1] -eq 2) 'P38 choosing 2 requests at once asks the probe again with slots 2: Long is disabled and the reason shows' "long=$($els.SettingsContextProfileBox.Items[1].IsEnabled) why=$($els.SettingsContextProfileWhy.Visibility) calls=$($script:setProbeCalls['long']) want=$($callsBefore + 1)"
    $els.SettingsRequestsBox.SelectedIndex = 0
    Invoke-Pump 50
    Check ([bool]$els.SettingsContextProfileBox.Items[1].IsEnabled -and $els.SettingsContextProfileWhy.Visibility -eq $hidden -and [int]$script:setProbeCalls['long'] -eq $callsBefore + 2) 'P38 choosing 1 again enables Long and hides the reason' "long=$($els.SettingsContextProfileBox.Items[1].IsEnabled) calls=$($script:setProbeCalls['long'])"
    $els.SettingsRequestsBox.SelectedIndex = 1
    Invoke-Pump 50
    $callsBefore = [int]$script:setProbeCalls['long']
    Invoke-FastLlmUiFluentSettingsDiscard
    Invoke-Pump 50
    Check ([bool]$els.SettingsContextProfileBox.Items[1].IsEnabled -and $els.SettingsContextProfileWhy.Visibility -eq $hidden -and [int]$script:setProbeCalls['long'] -eq $callsBefore + 1) 'P38 Discard of the requests edit asks the probe for the saved slots (1) again: Long is enabled again' "long=$($els.SettingsContextProfileBox.Items[1].IsEnabled) calls=$($script:setProbeCalls['long']) want=$($callsBefore + 1)"
    $callsBefore = [int]$script:setProbeCalls['long']
    $els.SettingsThinkingBox.SelectedIndex = 1
    for ($i = 0; $i -lt 3; $i++) { Invoke-FastLlmUiFluentTick; Invoke-Pump 30 }
    Check ([int]$script:setProbeCalls['long'] -eq $callsBefore) 'P38 an unrelated edit and three ticks do not read the long probe again' "calls=$($script:setProbeCalls['long']) before=$callsBefore"

    # E. Each new row edits the held value and marks the page dirty; Discard puts it back.
    $edits = @(
        @{ Name = 'Context profile'; Fixture = @{ embAvail = $true; longMeasured = $true }; Do = { $els.SettingsContextProfileBox.SelectedIndex = 1 }; Held = { [string]$st['Held'].contextProfile -ceq 'long' }; Back = { [int]$els.SettingsContextProfileBox.SelectedIndex -eq 0 -and [string]$st['Held'].contextProfile -ceq 'default' } },
        @{ Name = 'Requests at once'; Fixture = @{ embAvail = $true; longMeasured = $true }; Do = { $els.SettingsRequestsBox.SelectedIndex = 1 }; Held = { [int]$st['Held'].slots -eq 2 }; Back = { [int]$els.SettingsRequestsBox.SelectedIndex -eq 0 -and [int]$st['Held'].slots -eq 1 } },
        @{ Name = 'Embeddings'; Fixture = @{ embAvail = $true; longMeasured = $true }; Do = { $els.SettingsEmbeddingsBox.IsChecked = $true }; Held = { [string]$st['Held'].embeddings -ceq 'on' }; Back = { $els.SettingsEmbeddingsBox.IsChecked -eq $false -and [string]$st['Held'].embeddings -ceq 'off' -and $els.SettingsEmbeddingPortGroup.Visibility -eq $hidden } },
        @{ Name = 'Embeddings port'; Fixture = @{ embAvail = $true; longMeasured = $true; embeddings = 'on' }; Do = { $els.SettingsEmbeddingPortBox.Text = '9100'; $null = Send-ModelsKey $els.SettingsEmbeddingPortBox ([System.Windows.Input.Key]::Return) }; Held = { [int]$st['Held'].embeddingPort -eq 9100 }; Back = { [string]$els.SettingsEmbeddingPortBox.Text -ceq '8081' -and [int]$st['Held'].embeddingPort -eq 8081 } }
    )
    foreach ($edit in $edits) {
        $null = Open-SettingsPage $edit.Fixture
        $st = Get-SettingsState
        & $edit.Do
        Invoke-Pump 30
        $heldOk = [bool](& $edit.Held)
        Check ([bool]$st['Dirty'] -and $heldOk) "P38 an edit to $($edit.Name) makes the page dirty and writes the held value" "dirty=$($st['Dirty']) held=$heldOk"
        Invoke-FastLlmUiFluentSettingsDiscard
        Invoke-Pump 30
        $backOk = [bool](& $edit.Back)
        Check ((-not [bool]$st['Dirty']) -and $backOk) "P38 Discard puts $($edit.Name) back to the saved value and the page is clean again" "dirty=$($st['Dirty']) back=$backOk"
    }
    Check ((Get-SettingsLogText) -ceq '') 'P38 the edits and Discards wrote nothing' "log=$(Get-SettingsLogText)"
    # Discard reverts all four at once and re-collapses the port row
    $null = Open-SettingsPage @{ embAvail = $true; longMeasured = $true }
    $st = Get-SettingsState
    $els.SettingsContextProfileBox.SelectedIndex = 1
    $els.SettingsRequestsBox.SelectedIndex = 1
    $els.SettingsEmbeddingsBox.IsChecked = $true
    $els.SettingsEmbeddingPortBox.Text = '9100'
    $null = Send-ModelsKey $els.SettingsEmbeddingPortBox ([System.Windows.Input.Key]::Return)
    Invoke-Pump 50
    Check ([bool]$st['Dirty'] -and [string]$st['Held'].contextProfile -ceq 'long' -and [int]$st['Held'].slots -eq 2 -and [string]$st['Held'].embeddings -ceq 'on' -and [int]$st['Held'].embeddingPort -eq 9100 -and $els.SettingsEmbeddingPortGroup.Visibility -eq $shown) 'P38 all four edits together are dirty and held, with the port row shown' "dirty=$($st['Dirty']) held=$($st['Held'].contextProfile)/$($st['Held'].slots)/$($st['Held'].embeddings)/$($st['Held'].embeddingPort)"
    Invoke-FastLlmUiFluentSettingsDiscard
    Invoke-Pump 50
    Check ((-not [bool]$st['Dirty']) -and [int]$els.SettingsContextProfileBox.SelectedIndex -eq 0 -and [int]$els.SettingsRequestsBox.SelectedIndex -eq 0 -and $els.SettingsEmbeddingsBox.IsChecked -eq $false -and [string]$els.SettingsEmbeddingPortBox.Text -ceq '8081' -and $els.SettingsEmbeddingPortGroup.Visibility -eq $hidden -and [string]$st['Held'].contextProfile -ceq 'default' -and [int]$st['Held'].slots -eq 1 -and [string]$st['Held'].embeddings -ceq 'off' -and [int]$st['Held'].embeddingPort -eq 8081) 'P38 Discard reverts all four rows, re-collapses the port row and leaves the page clean' "dirty=$($st['Dirty']) profile=$($els.SettingsContextProfileBox.SelectedIndex) slots=$($els.SettingsRequestsBox.SelectedIndex) emb=$($els.SettingsEmbeddingsBox.IsChecked) port='$($els.SettingsEmbeddingPortBox.Text)' portGroup=$($els.SettingsEmbeddingPortGroup.Visibility)"
    Check ((Get-SettingsLogText) -ceq '') 'P38 Discard wrote nothing' "log=$(Get-SettingsLogText)"

    # F. Save passes exactly the changed parameters (a changed field with its held value, an untouched field not at all).
    $null = Open-SettingsPage @{ embAvail = $true; longMeasured = $true }
    $st = Get-SettingsState
    $els.SettingsContextProfileBox.SelectedIndex = 1
    $els.SettingsRequestsBox.SelectedIndex = 1
    $els.SettingsEmbeddingsBox.IsChecked = $true
    $els.SettingsEmbeddingPortBox.Text = '9100'
    $null = Send-ModelsKey $els.SettingsEmbeddingPortBox ([System.Windows.Input.Key]::Return)
    Invoke-Pump 50
    Invoke-P38SaveWithDialogs
    $r = @($script:p38Save.R)
    Check ($r.Count -eq 1 -and $r[0] -is [bool] -and $r[0] -and (Get-SettingsLogText) -ceq 'serving,allow,refresh' -and (Test-SettingsRecClean $script:p38Save.D)) 'P38 Save with all four rows changed returns one bool (true) and keeps classic order' ("count=$($r.Count) log=$(Get-SettingsLogText) " + (Get-SettingsRecDetail $script:p38Save.D))
    Check ((Get-P38Bound) -ceq 'EmbeddingPort,Embeddings,KvContextProfile,KvSlots' -and [string]$script:setLastNew['KvContextProfile'] -ceq 'long' -and [int]$script:setLastNew['KvSlots'] -eq 2 -and [string]$script:setLastNew['Embeddings'] -ceq 'on' -and [int]$script:setLastNew['EmbeddingPort'] -eq 9100) 'P38 Save passes the four changed parameters with their held values: -KvContextProfile long, -KvSlots 2, -Embeddings on, -EmbeddingPort 9100' "bound=$(Get-P38Bound)"
    Check ((-not [bool]$st['Dirty']) -and [string]$script:setFx.contextProfile -ceq 'long' -and [int]$script:setFx.slots -eq 2 -and [string]$script:setFx.embeddings -ceq 'on' -and [int]$script:setFx.embeddingPort -eq 9100 -and [int]$els.SettingsRequestsBox.SelectedIndex -eq 1 -and [int]$els.SettingsContextProfileBox.SelectedIndex -eq 1) 'P38 after that Save the page is clean and shows the saved values (the reload reads them back)' "dirty=$($st['Dirty']) fixture=$($script:setFx.contextProfile)/$($script:setFx.slots)/$($script:setFx.embeddings)/$($script:setFx.embeddingPort)"
    $singles = @(
        @{ Name = 'only Embeddings toggled'; Fixture = @{ embAvail = $true; longMeasured = $true }; Do = { $els.SettingsEmbeddingsBox.IsChecked = $true }; Want = 'Embeddings' },
        @{ Name = 'only requests at once changed'; Fixture = @{ embAvail = $true; longMeasured = $true }; Do = { $els.SettingsRequestsBox.SelectedIndex = 1 }; Want = 'KvSlots' },
        @{ Name = 'only the context profile changed'; Fixture = @{ embAvail = $true; longMeasured = $true }; Do = { $els.SettingsContextProfileBox.SelectedIndex = 1 }; Want = 'KvContextProfile' },
        @{ Name = 'only the embeddings port changed (saved on)'; Fixture = @{ embAvail = $true; longMeasured = $true; embeddings = 'on' }; Do = { $els.SettingsEmbeddingPortBox.Text = '9100'; $null = Send-ModelsKey $els.SettingsEmbeddingPortBox ([System.Windows.Input.Key]::Return) }; Want = 'EmbeddingPort' },
        @{ Name = 'only an unrelated field changed'; Fixture = @{ embAvail = $true; longMeasured = $true; contextProfile = 'long'; slots = 2 }; Do = { $els.SettingsThinkingBox.SelectedIndex = 1 }; Want = '' },
        @{ Name = 'Embeddings ticked and unticked again, plus an unrelated field'; Fixture = @{ embAvail = $true; longMeasured = $true }; Do = { $els.SettingsEmbeddingsBox.IsChecked = $true; $els.SettingsEmbeddingsBox.IsChecked = $false; $els.SettingsThinkingBox.SelectedIndex = 1 }; Want = '' }
    )
    foreach ($case in $singles) {
        $null = Open-SettingsPage $case.Fixture
        $st = Get-SettingsState
        $fixtureBefore = @{ contextProfile = [string]$script:setFx.contextProfile; slots = [int]$script:setFx.slots; embeddings = [string]$script:setFx.embeddings; embeddingPort = [int]$script:setFx.embeddingPort }
        & $case.Do
        Invoke-Pump 50
        Invoke-P38SaveWithDialogs
        $r = @($script:p38Save.R)
        Check ($r.Count -eq 1 -and $r[0] -and (Get-SettingsLogText) -ceq 'serving,allow,refresh' -and (Get-P38Bound) -ceq $case.Want) "P38 Save with $($case.Name) passes exactly [$($case.Want)] of the four additions" "bound=$(Get-P38Bound) log=$(Get-SettingsLogText)"
        if ($case.Want -ceq '') {
            Check ([string]$script:setFx.contextProfile -ceq $fixtureBefore.contextProfile -and [int]$script:setFx.slots -eq $fixtureBefore.slots -and [string]$script:setFx.embeddings -ceq $fixtureBefore.embeddings -and [int]$script:setFx.embeddingPort -eq $fixtureBefore.embeddingPort) "P38 Save with $($case.Name) leaves the four stored additions as they were" "fixture=$($script:setFx.contextProfile)/$($script:setFx.slots)/$($script:setFx.embeddings)/$($script:setFx.embeddingPort)"
        }
        if ($case.Name -ceq 'only Embeddings toggled') {
            Check ($script:setLastNew.ContainsKey('Embeddings') -and -not $script:setLastNew.ContainsKey('KvContextProfile') -and -not $script:setLastNew.ContainsKey('KvSlots') -and -not $script:setLastNew.ContainsKey('EmbeddingPort')) 'P38 toggling only Embeddings does not touch the context profile, the slots or the port' "bound=$(Get-P38Bound)"
        }
    }

    # G. The saved note while a run is active (the note is also the Information box text), one change at a time.
    $notes = @(
        @{ Name = 'context profile'; Fixture = @{ embAvail = $true; longMeasured = $true }; Do = { $els.SettingsContextProfileBox.SelectedIndex = 1 }; Note = 'The new context profile applies at the next start.' },
        @{ Name = 'requests at once'; Fixture = @{ embAvail = $true; longMeasured = $true }; Do = { $els.SettingsRequestsBox.SelectedIndex = 1 }; Note = 'The new requests at once setting applies at the next start.' },
        @{ Name = 'embeddings'; Fixture = @{ embAvail = $true; longMeasured = $true }; Do = { $els.SettingsEmbeddingsBox.IsChecked = $true }; Note = 'The new embeddings setting applies at the next start.' },
        @{ Name = 'embeddings port'; Fixture = @{ embAvail = $true; longMeasured = $true; embeddings = 'on' }; Do = { $els.SettingsEmbeddingPortBox.Text = '9100'; $null = Send-ModelsKey $els.SettingsEmbeddingPortBox ([System.Windows.Input.Key]::Return) }; Note = 'The new embeddings port applies at the next start.' }
    )
    foreach ($case in $notes) {
        $null = Open-SettingsPage $case.Fixture
        $st = Get-SettingsState
        $script:child = [pscustomobject]@{ probe = $true }
        & $case.Do
        Invoke-Pump 50
        $d = @{}
        $timer = Start-SettingsDialogs @(@{ Kind = 'box'; Caption = 'FastLLM settings'; Id = 2; Fallback = 2 }, (New-SettingsWatch)) $d
        try {
            $els.SettingsSaveButton.RaiseEvent((New-ShellClick $els.SettingsSaveButton ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            Invoke-Pump 150
        }
        finally { $timer.Stop(); $script:child = $null }
        $rec = Get-SettingsRec $d 0
        Check ([bool]$rec['Found'] -and (ConvertTo-ModelsPlainBoxText ([string]$rec['Text'])) -ceq $case.Note -and [string]$script:statusLabel.Text -ceq $case.Note -and (Test-SettingsRecClean $d)) "P38 while a run is active a changed $($case.Name) shows the saved note in the Information box and the status line" ("want='$($case.Note)' status='$($script:statusLabel.Text)' " + (Get-SettingsRecDetail $d))
        Check ((Get-SettingsLogText) -ceq 'serving,allow,refresh') "P38 the Save button for a changed $($case.Name) writes once, in classic order" "log=$(Get-SettingsLogText)"
    }
    Check ([string]$script:setFx.embeddingPort -ceq '9100' -and [string]$script:setFx.embeddings -ceq 'on') 'P38 the last run-active Save stored the embeddings port 9100 (the fixture holds what was passed)' "fixture=$($script:setFx.embeddings)/$($script:setFx.embeddingPort)"

    # H. A value saved by the CLI shows, and survives an unrelated Save.
    $null = Open-SettingsPage @{ slots = 2 }
    $st = Get-SettingsState
    Check ([int]$els.SettingsRequestsBox.SelectedIndex -eq 1 -and [string]$els.SettingsRequestsBox.SelectedItem.Content -ceq [string]$s.RequestsAtOnceTwo -and [int]$st['Held'].slots -eq 2 -and -not [bool]$st['Dirty']) 'P38 a saved slots=2 shows 2 and the page opens clean' "selected=$($els.SettingsRequestsBox.SelectedIndex) item='$($els.SettingsRequestsBox.SelectedItem)' held=$($st['Held'].slots) dirty=$($st['Dirty'])"
    $els.SettingsThinkingBox.SelectedIndex = 1
    Invoke-Pump 30
    Invoke-P38SaveWithDialogs
    $r = @($script:p38Save.R)
    Check ($r.Count -eq 1 -and $r[0] -and (Get-SettingsLogText) -ceq 'serving,allow,refresh' -and -not $script:setLastNew.ContainsKey('KvSlots') -and (Get-P38Bound) -ceq '' -and [int]$script:setFx.slots -eq 2) 'P38 an unrelated Save does not pass -KvSlots, so slots=2 is kept' "bound=$(Get-P38Bound) slots=$($script:setFx.slots) log=$(Get-SettingsLogText)"
    Check ([int]$els.SettingsRequestsBox.SelectedIndex -eq 1 -and -not [bool]$st['Dirty']) 'P38 after the unrelated Save the page still shows 2 and is clean' "selected=$($els.SettingsRequestsBox.SelectedIndex) dirty=$($st['Dirty'])"
    $null = Open-SettingsPage @{ contextProfile = 'long'; slots = 2; embeddings = 'on'; embeddingPort = 9100; embAvail = $false; longMeasured = $false }
    $st = Get-SettingsState
    Check ([int]$els.SettingsContextProfileBox.SelectedIndex -eq 1 -and [int]$els.SettingsRequestsBox.SelectedIndex -eq 1 -and $els.SettingsEmbeddingsBox.IsChecked -eq $true -and [string]$els.SettingsEmbeddingPortBox.Text -ceq '9100' -and -not [bool]$st['Dirty']) 'P38 a file holding all four non-default values (CLI) opens showing all four, clean' "profile=$($els.SettingsContextProfileBox.SelectedIndex) slots=$($els.SettingsRequestsBox.SelectedIndex) emb=$($els.SettingsEmbeddingsBox.IsChecked) port='$($els.SettingsEmbeddingPortBox.Text)' dirty=$($st['Dirty'])"
    $els.SettingsIdleBox.SelectedIndex = 2
    Invoke-Pump 30
    Invoke-P38SaveWithDialogs
    $r = @($script:p38Save.R)
    Check ($r.Count -eq 1 -and $r[0] -and (Get-P38Bound) -ceq '' -and [string]$script:setFx.contextProfile -ceq 'long' -and [int]$script:setFx.slots -eq 2 -and [string]$script:setFx.embeddings -ceq 'on' -and [int]$script:setFx.embeddingPort -eq 9100) 'P38 an unrelated Save passes none of the four, so all four non-default values are kept' "bound=$(Get-P38Bound) fixture=$($script:setFx.contextProfile)/$($script:setFx.slots)/$($script:setFx.embeddings)/$($script:setFx.embeddingPort)"

    # I. The Long Save guard: Long held at a requests-at-once value where it is not measured (and not the saved pair) is refused by Save, with no write, the edits kept and
    # the focus on the context profile box; the probe is asked again with the new slots. A saved unmeasured pair is exempt.
    $null = Open-SettingsPage @{ longAt = @(1); contextProfile = 'default'; slots = 1 }
    $st = Get-SettingsState
    $els.SettingsContextProfileBox.SelectedIndex = 1
    Invoke-Pump 50
    $callsBefore = [int]$script:setProbeCalls['long']
    $els.SettingsRequestsBox.SelectedIndex = 1
    Invoke-Pump 50
    $lastSlots = if ($script:setProbeSlots.Count -gt 0) { [int]$script:setProbeSlots[$script:setProbeSlots.Count - 1] } else { -1 }
    Check ([int]$script:setProbeCalls['long'] -eq $callsBefore + 1 -and $lastSlots -eq 2) 'P38 I1 Long chosen at 1, then Requests at once changed to 2: the probe is asked again with slots 2' "calls=$($script:setProbeCalls['long']) want=$($callsBefore + 1) lastSlots=$lastSlots want=2"
    Check ($els.SettingsContextProfileWhy.Visibility -eq $shown -and $els.SettingsContextProfileWhy.IsVisible -and [string]$els.SettingsContextProfileWhy.Text -ceq [string]$s.LongNotMeasured) 'P38 I1 Long held at 2 (not measured, not the saved pair): the reason line shows the LongNotMeasured text' "visibility=$($els.SettingsContextProfileWhy.Visibility) text='$($els.SettingsContextProfileWhy.Text)' want='$($s.LongNotMeasured)'"
    $null = $win.Activate()
    $null = $els.SettingsThinkingBox.Focus()
    Invoke-Pump 50
    $script:setLastNew = $null
    $script:setLastServing = $null
    $logBefore = Get-SettingsLogText
    Invoke-P38SaveWithDialogs
    $r = @($script:p38Save.R)
    Check ($r.Count -eq 1 -and $r[0] -is [bool] -and -not $r[0] -and (Get-SettingsLogText) -ceq $logBefore -and $null -eq $script:setLastServing -and $null -eq $script:setLastNew -and (Test-SettingsRecClean $script:p38Save.D) -and $script:p38Save.D['recs'].Count -eq 0) 'P38 I1 Save with the unmeasured Long returns one bool (false), writes nothing and shows no box' ("count=$($r.Count) value=$(if ($r.Count -gt 0) { $r[0] } else { 'none' }) log='$(Get-SettingsLogText)' want='$logBefore' serving=$($null -ne $script:setLastServing) bound=$(Get-P38Bound)")
    $logical = [System.Windows.Input.FocusManager]::GetFocusedElement($win)
    Check ([object]::ReferenceEquals($logical, $els.SettingsContextProfileBox)) 'P38 I1 the refused Save puts the focus on the context profile box' "focus=$(if ($null -ne $logical) { $logical.GetType().Name + ':' + $logical.Name } else { 'none' }) want=SettingsContextProfileBox"
    Check ([string]$st['Held'].contextProfile -ceq 'long' -and [int]$st['Held'].slots -eq 2 -and [bool]$st['Dirty'] -and [int]$els.SettingsRequestsBox.SelectedIndex -eq 1 -and $els.SettingsContextProfileWhy.Visibility -eq $shown) 'P38 I1 the refused Save keeps the edits (held long and 2, dirty, requests box on 2) and the reason line' "held=$($st['Held'].contextProfile)/$($st['Held'].slots) dirty=$($st['Dirty']) requests=$($els.SettingsRequestsBox.SelectedIndex) why=$($els.SettingsContextProfileWhy.Visibility)"
    Write-Host ("INFO: P38 I1 after the refused Save the logical focus is on " + $(if ($null -ne $logical) { $logical.GetType().Name + ':' + [string]$logical.Name } else { 'nothing' }) + "; the probe was asked with slots " + (@($script:setProbeSlots) -join ','))
    $callsBefore = [int]$script:setProbeCalls['long']
    $els.SettingsRequestsBox.SelectedIndex = 0
    Invoke-Pump 50
    Check ($els.SettingsContextProfileWhy.Visibility -eq $shown -and [string]$els.SettingsContextProfileWhy.Text -ceq [string]$s.LongNotMeasured -and -not [bool]$two.Items[1].IsEnabled -and [int]$script:setProbeCalls['long'] -eq $callsBefore + 1) 'P38 I1 changing Requests at once back to 1 asks the probe again; the line stays only because the 2 item is still disabled (2 is not measured for Long), and Save is no longer refused' "why=$($els.SettingsContextProfileWhy.Visibility) text='$($els.SettingsContextProfileWhy.Text)' calls=$($script:setProbeCalls['long']) want=$($callsBefore + 1)"
    Invoke-P38SaveWithDialogs
    $r = @($script:p38Save.R)
    Check ($r.Count -eq 1 -and $r[0] -is [bool] -and $r[0] -and (Get-P38Bound) -ceq 'KvContextProfile' -and [string]$script:setLastNew['KvContextProfile'] -ceq 'long' -and -not $script:setLastNew.ContainsKey('KvSlots') -and (Test-SettingsRecClean $script:p38Save.D)) 'P38 I1 back at 1, Save writes -KvContextProfile long and no -KvSlots (the slots are the saved ones)' "count=$($r.Count) value=$(if ($r.Count -gt 0) { $r[0] } else { 'none' }) bound='$(Get-P38Bound)' want='KvContextProfile' log=$(Get-SettingsLogText)"

    # I2. A saved Long at 2, not measured: nothing is refused while the pair is the saved one, and an untouched or unrelated Save passes neither field.
    $null = Open-SettingsPage @{ contextProfile = 'long'; slots = 2; longMeasured = $false }
    $st = Get-SettingsState
    Check ($els.SettingsContextProfileWhy.Visibility -eq $hidden -and [string]$els.SettingsContextProfileWhy.Text -ceq '' -and [string]$st['Held'].contextProfile -ceq 'long' -and [int]$st['Held'].slots -eq 2 -and -not [bool]$st['Dirty']) 'P38 I2 a saved Long at 2 that is not measured opens with no reason line and a clean page (the saved-pair exception)' "why=$($els.SettingsContextProfileWhy.Visibility) text='$($els.SettingsContextProfileWhy.Text)' held=$($st['Held'].contextProfile)/$($st['Held'].slots) dirty=$($st['Dirty'])"
    $script:setLastNew = $null
    Invoke-P38SaveWithDialogs
    $r = @($script:p38Save.R)
    Check ((Get-P38Bound) -ceq '' -and [string]$script:setFx.contextProfile -ceq 'long' -and [int]$script:setFx.slots -eq 2 -and $els.SettingsContextProfileWhy.Visibility -eq $hidden) 'P38 I2 an untouched Save writes nothing new: neither -KvContextProfile nor -KvSlots is passed, the stored pair is kept and no reason line shows' "bound='$(Get-P38Bound)' stored=$($script:setFx.contextProfile)/$($script:setFx.slots) why=$($els.SettingsContextProfileWhy.Visibility) result=$(if ($r.Count -gt 0) { $r[0] } else { 'none' })"
    $els.SettingsThinkingBox.SelectedIndex = 1
    Invoke-Pump 30
    $script:setLastNew = $null
    Invoke-P38SaveWithDialogs
    $r = @($script:p38Save.R)
    Check ($r.Count -eq 1 -and $r[0] -is [bool] -and $r[0] -and (Get-P38Bound) -ceq '' -and [string]$script:setFx.contextProfile -ceq 'long' -and [int]$script:setFx.slots -eq 2) 'P38 I2 an unrelated Save at the saved unmeasured Long pair is not refused and passes none of the four' "count=$($r.Count) value=$(if ($r.Count -gt 0) { $r[0] } else { 'none' }) bound='$(Get-P38Bound)' stored=$($script:setFx.contextProfile)/$($script:setFx.slots)"

    # J. "2 requests at once" (P1): never offered where it can only fail. The 2 item is disabled with the one reason line unless 2 is already saved; Save refuses a held 2
    # that is not measured for the held profile (no write, edits kept, focus on the requests box); the probe is asked again when the profile changes.
    $null = Open-SettingsPage @{ longMeasured = $true; twoMeasured = $false; contextProfile = 'default'; slots = 1 }
    $st = Get-SettingsState
    Check ((-not [bool]$two.Items[1].IsEnabled) -and [bool]$two.Items[0].IsEnabled -and $els.SettingsContextProfileWhy.Visibility -eq $shown -and [string]$els.SettingsContextProfileWhy.Text -ceq [string]$s.LongNotMeasured -and [bool]$els.SettingsContextProfileBox.Items[1].IsEnabled -and (@($script:setProbeAsked) -contains 'default:2')) 'P38 J1 2 not measured for Default: the 2 item is disabled with the LongNotMeasured reason, Long (measured) stays enabled, and the probe was asked for default at 2' "two=$($two.Items[1].IsEnabled) why=$($els.SettingsContextProfileWhy.Visibility) asked=$(@($script:setProbeAsked) -join ',')"
    Check ([string][System.Windows.Automation.AutomationProperties]::GetHelpText($two) -ceq [string]$s.LongNotMeasured) 'P38 J1 the requests box reads the reason as its help text' "help=$([System.Windows.Automation.AutomationProperties]::GetHelpText($two))"
    $two.SelectedIndex = 1
    Invoke-Pump 50
    Check ([int]$st['Held'].slots -eq 2 -and [bool]$st['Dirty']) 'P38 J1 a held 2 (set past the disabled item) makes the page dirty' "held=$($st['Held'].slots) dirty=$($st['Dirty'])"
    $null = $win.Activate()
    $null = $els.SettingsThinkingBox.Focus()
    Invoke-Pump 50
    $script:setLastNew = $null; $script:setLastServing = $null
    $logBefore = Get-SettingsLogText
    Invoke-P38SaveWithDialogs
    $r = @($script:p38Save.R)
    Check ($r.Count -eq 1 -and $r[0] -is [bool] -and -not $r[0] -and (Get-SettingsLogText) -ceq $logBefore -and $null -eq $script:setLastServing -and $null -eq $script:setLastNew -and (Test-SettingsRecClean $script:p38Save.D) -and $script:p38Save.D['recs'].Count -eq 0) 'P38 J2 Save with the unmeasured 2 returns one bool (false), writes nothing and shows no box' "count=$($r.Count) log=$(Get-SettingsLogText)"
    $logical = [System.Windows.Input.FocusManager]::GetFocusedElement($win)
    Check ([object]::ReferenceEquals($logical, $two) -and [int]$st['Held'].slots -eq 2 -and [bool]$st['Dirty'] -and [int]$two.SelectedIndex -eq 1) 'P38 J2 the refused Save puts the focus on the requests box and keeps the edit' "focus=$(if ($null -ne $logical) { $logical.GetType().Name + ':' + $logical.Name } else { 'none' })"
    $two.SelectedIndex = 0
    Invoke-Pump 50
    Invoke-P38SaveWithDialogs
    $r = @($script:p38Save.R)
    Check ($r.Count -eq 1 -and $r[0] -is [bool] -and $r[0] -and -not $script:setLastNew.ContainsKey('KvSlots')) 'P38 J2 back at 1 (nothing else changed) Save goes through and passes no -KvSlots' "count=$($r.Count) bound=$(Get-P38Bound)"
    # the probe is asked again for the held profile when the profile changes (2 measured for Long only)
    $null = Open-SettingsPage @{ longAt = @(1, 2); twoMeasured = $false; contextProfile = 'default'; slots = 1 }
    $st = Get-SettingsState
    Check (-not [bool]$two.Items[1].IsEnabled) 'P38 J3 2 is not measured for Default: the 2 item is disabled' "two=$($two.Items[1].IsEnabled)"
    $askedBefore = @($script:setProbeAsked).Count
    $els.SettingsContextProfileBox.SelectedIndex = 1
    Invoke-Pump 50
    $asked = @($script:setProbeAsked)
    Check ($asked.Count -gt $askedBefore -and $asked[$asked.Count - 1] -ceq 'long:2' -and [bool]$two.Items[1].IsEnabled) 'P38 J3 choosing Long asks the probe for the long profile at 2 again, and the 2 item is enabled (measured for Long)' "asked=$($asked -join ',')"
    $els.SettingsContextProfileBox.SelectedIndex = 0
    Invoke-Pump 50
    Check (-not [bool]$two.Items[1].IsEnabled -and [string]$st['Held'].contextProfile -ceq 'default') 'P38 J3 choosing Default asks again and the 2 item is disabled again' "two=$($two.Items[1].IsEnabled)"
    # a saved 2 is never disabled (the saved-value exception), and an unrelated Save passes no -KvSlots
    $null = Open-SettingsPage @{ longMeasured = $false; twoMeasured = $false; contextProfile = 'default'; slots = 2 }
    $st = Get-SettingsState
    Check ([bool]$two.Items[1].IsEnabled -and [int]$two.SelectedIndex -eq 1 -and -not [bool]$st['Dirty']) 'P38 J4 a saved 2 stays enabled and selected, and the page is clean' "two=$($two.Items[1].IsEnabled) selected=$($two.SelectedIndex)"
    $els.SettingsThinkingBox.SelectedIndex = 1
    Invoke-Pump 30
    $script:setLastNew = $null
    Invoke-P38SaveWithDialogs
    $r = @($script:p38Save.R)
    Check ($r.Count -eq 1 -and $r[0] -and (Get-P38Bound) -ceq '' -and [int]$script:setFx.slots -eq 2) 'P38 J4 an unrelated Save with a saved unmeasured 2 is not refused and passes no -KvSlots' "bound=$(Get-P38Bound) slots=$($script:setFx.slots)"
    # a saved Long at 2 does not make Default at 2 safe: only the saved PAIR is exempt, so switching to Default while 2 is not measured for Default is refused
    $null = Open-SettingsPage @{ longAt = @(2); twoMeasured = $false; contextProfile = 'long'; slots = 2 }
    $st = Get-SettingsState
    $els.SettingsContextProfileBox.SelectedIndex = 0
    Invoke-Pump 50
    $null = $win.Activate()
    $script:setLastNew = $null; $script:setLastServing = $null
    $logBefore = Get-SettingsLogText
    Invoke-P38SaveWithDialogs
    $r = @($script:p38Save.R)
    $logical = [System.Windows.Input.FocusManager]::GetFocusedElement($win)
    Check ($r.Count -eq 1 -and $r[0] -is [bool] -and -not $r[0] -and (Get-SettingsLogText) -ceq $logBefore -and $null -eq $script:setLastNew -and [object]::ReferenceEquals($logical, $two) -and [string]$st['Held'].contextProfile -ceq 'default' -and [int]$st['Held'].slots -eq 2) 'P38 J5 a saved Long at 2 switched to Default (2 not measured for Default): Save is refused, nothing is written, the edit stays and the focus is on the requests box' "count=$($r.Count) log=$(Get-SettingsLogText) focus=$(if ($null -ne $logical) { $logical.Name } else { 'none' })"

    # K. A Context above 0 on the Models page (4096): Long and 2 are shown DISABLED with NeedsCatalogContext (it wins over LongNotMeasured), unless already saved; Save refuses a held change into the state.
    $null = Open-SettingsPage @{ context = 4096; longMeasured = $false; twoMeasured = $false; contextProfile = 'default'; slots = 1 }
    $st = Get-SettingsState
    $why = $els.SettingsContextProfileWhy
    Check ((-not [bool]$els.SettingsContextProfileBox.Items[1].IsEnabled) -and (-not [bool]$two.Items[1].IsEnabled) -and $why.Visibility -eq $shown -and [string]$why.Text -ceq [string]$s.NeedsCatalogContext) 'P38 K1 Context 4096 (and not measured): Long and 2 are disabled and the reason line says NeedsCatalogContext, not LongNotMeasured' "long=$($els.SettingsContextProfileBox.Items[1].IsEnabled) two=$($two.Items[1].IsEnabled) text='$($why.Text)'"
    $null = Open-SettingsPage @{ context = 4096; longMeasured = $true; twoMeasured = $true; contextProfile = 'default'; slots = 1 }
    $st = Get-SettingsState
    Check ((-not [bool]$els.SettingsContextProfileBox.Items[1].IsEnabled) -and (-not [bool]$two.Items[1].IsEnabled) -and [string]$why.Text -ceq [string]$s.NeedsCatalogContext) 'P38 K1 Context 4096 with both measured: still disabled for the context' "long=$($els.SettingsContextProfileBox.Items[1].IsEnabled) two=$($two.Items[1].IsEnabled)"
    $els.SettingsContextProfileBox.SelectedIndex = 1
    Invoke-Pump 50
    $null = $win.Activate()
    $script:setLastNew = $null; $script:setLastServing = $null
    $logBefore = Get-SettingsLogText
    Invoke-P38SaveWithDialogs
    $r = @($script:p38Save.R)
    Check ($r.Count -eq 1 -and $r[0] -is [bool] -and -not $r[0] -and (Get-SettingsLogText) -ceq $logBefore -and $null -eq $script:setLastServing -and $null -eq $script:setLastNew -and (Test-SettingsRecClean $script:p38Save.D)) 'P38 K2 Save with Long held while Context is above 0 returns one bool (false) and writes nothing' "count=$($r.Count) log=$(Get-SettingsLogText)"
    $logical = [System.Windows.Input.FocusManager]::GetFocusedElement($win)
    Check ([object]::ReferenceEquals($logical, $els.SettingsContextProfileBox) -and [string]$st['Held'].contextProfile -ceq 'long' -and [bool]$st['Dirty'] -and [string]$why.Text -ceq [string]$s.NeedsCatalogContext) 'P38 K2 the refused Save focuses the context profile box, keeps the edit and shows NeedsCatalogContext' "focus=$(if ($null -ne $logical) { $logical.GetType().Name + ':' + $logical.Name } else { 'none' })"
    $els.SettingsContextProfileBox.SelectedIndex = 0
    $two.SelectedIndex = 1
    Invoke-Pump 50
    Invoke-P38SaveWithDialogs
    $r = @($script:p38Save.R)
    $logical = [System.Windows.Input.FocusManager]::GetFocusedElement($win)
    Check ($r.Count -eq 1 -and -not $r[0] -and $null -eq $script:setLastNew -and [object]::ReferenceEquals($logical, $two)) 'P38 K2 Save with 2 held while Context is above 0 is refused too, with the focus on the requests box' "count=$($r.Count) focus=$(if ($null -ne $logical) { $logical.Name } else { 'none' })"
    $null = Open-SettingsPage @{ context = 4096; longMeasured = $false; contextProfile = 'long'; slots = 2 }
    $st = Get-SettingsState
    Check ([bool]$els.SettingsContextProfileBox.Items[1].IsEnabled -and [bool]$two.Items[1].IsEnabled -and -not [bool]$st['Dirty']) 'P38 K3 a saved Long and a saved 2 stay enabled with Context above 0, and the page is clean' "long=$($els.SettingsContextProfileBox.Items[1].IsEnabled) two=$($two.Items[1].IsEnabled)"
    $els.SettingsThinkingBox.SelectedIndex = 1
    Invoke-Pump 30
    $script:setLastNew = $null
    Invoke-P38SaveWithDialogs
    $r = @($script:p38Save.R)
    Check ($r.Count -eq 1 -and $r[0] -and (Get-P38Bound) -ceq '') 'P38 K3 an unrelated Save with a saved Long and 2 under Context above 0 is not refused and passes none of the four' "bound=$(Get-P38Bound)"

    # L. Live regions: a change of the reason line or of the same-port line is announced once (the view runs several times per edit), and the same-port message is the
    # embeddings port box's help text while it shows.
    $null = Open-SettingsPage @{ embAvail = $true; longMeasured = $true; twoMeasured = $false; contextProfile = 'default'; slots = 1 }
    $st = Get-SettingsState
    $whyLive = $els.SettingsContextProfileWhy
    $base = Get-LiveCount $whyLive
    Check ([string]$whyLive.Text -ceq [string]$s.LongNotMeasured -and $base -ge 1) 'P38 L1 opening with 2 unmeasured announced the reason line' "count=$base text='$($whyLive.Text)'"
    $els.SettingsThinkingBox.SelectedIndex = 1
    Invoke-Pump 30
    $els.SettingsIdleBox.SelectedIndex = 1
    Invoke-Pump 30
    Check ((Get-LiveCount $whyLive) -eq $base) 'P38 L1 unrelated edits re-run the view but do not announce the unchanged reason again' "count=$(Get-LiveCount $whyLive) base=$base"
    $els.SettingsContextProfileBox.SelectedIndex = 1
    Invoke-Pump 50
    $els.SettingsContextProfileBox.SelectedIndex = 0
    Invoke-Pump 50
    Check ((Get-LiveCount $whyLive) -eq $base + 1) 'P38 L1 choosing Long clears the reason (2 is measured for Long: nothing announced), and choosing Default brings it back (announced once more)' "count=$(Get-LiveCount $whyLive) want=$($base + 1)"
    $null = Open-SettingsPage @{ embAvail = $true; longMeasured = $true; twoMeasured = $true; contextProfile = 'default'; slots = 1; context = 4096 }
    $st = Get-SettingsState
    $countCtx = Get-LiveCount $whyLive
    $els.SettingsThinkingBox.SelectedIndex = 1
    Invoke-Pump 30
    Check ([string]$whyLive.Text -ceq [string]$s.NeedsCatalogContext -and (Get-LiveCount $whyLive) -eq $countCtx) 'P38 L1 the context reason shows and is not announced again by an unrelated edit' "count=$(Get-LiveCount $whyLive) was=$countCtx"
    $null = Open-SettingsPage @{ embAvail = $true; longMeasured = $true; twoMeasured = $true; contextProfile = 'default'; slots = 1 }
    $st = Get-SettingsState
    $same = $els.SettingsEmbeddingPortSame
    $els.SettingsEmbeddingsBox.IsChecked = $true
    Invoke-Pump 50
    $c0 = Get-LiveCount $same
    Check ($same.Visibility -eq $hidden -and [string][System.Windows.Automation.AutomationProperties]::GetHelpText($els.SettingsEmbeddingPortBox) -ceq '') 'P38 L2 with different ports there is no message and the port box has no help text' "help='$([System.Windows.Automation.AutomationProperties]::GetHelpText($els.SettingsEmbeddingPortBox))'"
    $els.SettingsEmbeddingPortBox.Text = '8080'
    $null = Send-ModelsKey $els.SettingsEmbeddingPortBox ([System.Windows.Input.Key]::Return)
    Invoke-Pump 50
    Check ($same.Visibility -eq $shown -and (Get-LiveCount $same) -eq $c0 + 1 -and [string][System.Windows.Automation.AutomationProperties]::GetHelpText($els.SettingsEmbeddingPortBox) -ceq [string]$s.EmbeddingPortSame) 'P38 L2 the port equal to the server port announces the same-port line once, and the message is the port box help text' "count=$(Get-LiveCount $same) want=$($c0 + 1) help='$([System.Windows.Automation.AutomationProperties]::GetHelpText($els.SettingsEmbeddingPortBox))'"
    $els.SettingsThinkingBox.SelectedIndex = 1
    Invoke-Pump 30
    $els.SettingsIdleBox.SelectedIndex = 2
    Invoke-Pump 30
    Check ((Get-LiveCount $same) -eq $c0 + 1) 'P38 L2 unrelated edits run the view again and do not announce the same message again' "count=$(Get-LiveCount $same) want=$($c0 + 1)"
    $els.SettingsEmbeddingPortBox.Text = '9100'
    $null = Send-ModelsKey $els.SettingsEmbeddingPortBox ([System.Windows.Input.Key]::Return)
    Invoke-Pump 50
    Check ($same.Visibility -eq $hidden -and [string][System.Windows.Automation.AutomationProperties]::GetHelpText($els.SettingsEmbeddingPortBox) -ceq '' -and (Get-LiveCount $same) -eq $c0 + 1) 'P38 L2 clearing the message clears the help text and announces nothing' "count=$(Get-LiveCount $same) help='$([System.Windows.Automation.AutomationProperties]::GetHelpText($els.SettingsEmbeddingPortBox))'"
    $els.SettingsEmbeddingPortBox.Text = '8080'
    $null = Send-ModelsKey $els.SettingsEmbeddingPortBox ([System.Windows.Input.Key]::Return)
    Invoke-Pump 50
    Check ((Get-LiveCount $same) -eq $c0 + 2) 'P38 L2 the message coming back is announced again (one more, once)' "count=$(Get-LiveCount $same) want=$($c0 + 2)"
    Close-SettingsPage
    Check-NoExceptions 'P38'
}

# Faults are injected last: each Initialize run replaces the shell state, so nothing after this may use the real shell.
function Invoke-P99-StartupFaults {
    if (-not $script:shellOk) { return }
    try { $script:FastLlmUiFluent.Timer.Stop() } catch { $null = $_ }
    Check ($script:connectDialogCalls -eq 0) 'P99 ShowConnectDialog was never called in fluent mode' "calls=$($script:connectDialogCalls)"
    Check ($script:settingsDialogCalls -eq 0) 'P99 ShowUiSettings (the classic Settings dialog) was never called by the Fluent Settings page' "calls=$($script:settingsDialogCalls)"
    # Text C is the same for a markup fault as for a theme fault, and the real stop function passes its reason on and exits 3
    $textXaml = Get-FastLlmUiUnsupportedText -Reason 'xaml-parse' -Folder 'C:\example'
    $textTheme = Get-FastLlmUiUnsupportedText -Reason 'theme-init' -Folder 'C:\example'
    Check (($textXaml -ceq $textTheme) -and $textXaml -match 'a fault in FastLLM') 'P99 a xaml-parse fault shows text C, the same as a theme-init fault' "xaml-parse='$textXaml'"
    Check ($script:realStopText -match 'Show-FastLlmUiUnsupported\s+-Reason\s+\$Reason' -and $script:realStopText -match 'exit 3') 'P99 the real Stop-FastLlmUiFluentStartup passes its reason to Show-FastLlmUiUnsupported and exits 3' $script:realStopText
    # An injected Tools markup fault: the Tools page does not parse, so the startup stops with xaml-parse (the suite's throwing double stands in for the exit)
    # The loader is shadowed for the one name (the XAML table is never written from a test): it throws the way a markup parse fault does.
    $script:realXamlLoader = ${function:New-FastLlmUiXamlElement}
    function New-FastLlmUiXamlElement { param([string]$Name) if ($Name -ceq 'FastLlm.Tools') { throw 'Exception calling "Parse" with "1" argument(s): injected Tools markup fault' }; return (& $script:realXamlLoader -Name $Name) }
    Initialize-ShellEnv
    $err = ''
    try { Initialize-FastLlmUiFluentShell } catch { $err = $_.Exception.Message }
    finally { Set-Item -Path Function:\New-FastLlmUiXamlElement -Value $script:realXamlLoader }
    Check ($err -ceq 'startup stopped: xaml-parse') 'P99 an injected Tools markup fault stops the startup with xaml-parse (text C, exit 3)' "error='$err'"
    Check ((${function:New-FastLlmUiXamlElement}).ToString() -ceq $script:realXamlLoader.ToString()) 'P99 the real XAML loader is restored' ''
    # The same for the Models page: its markup does not parse, so the startup stops with xaml-parse (text C, exit 3)
    function New-FastLlmUiXamlElement { param([string]$Name) if ($Name -ceq 'FastLlm.Models') { throw 'Exception calling "Parse" with "1" argument(s): injected Models markup fault' }; return (& $script:realXamlLoader -Name $Name) }
    Initialize-ShellEnv
    $errModels = ''
    try { Initialize-FastLlmUiFluentShell } catch { $errModels = $_.Exception.Message }
    finally { Set-Item -Path Function:\New-FastLlmUiXamlElement -Value $script:realXamlLoader }
    Check ($errModels -ceq 'startup stopped: xaml-parse') 'P99 an injected Models markup fault stops the startup with xaml-parse (text C, exit 3)' "error='$errModels'"
    Check ((${function:New-FastLlmUiXamlElement}).ToString() -ceq $script:realXamlLoader.ToString()) 'P99 the real XAML loader is restored after the Models fault' ''
    # The same for the Settings page (PR 3c)
    function New-FastLlmUiXamlElement { param([string]$Name) if ($Name -ceq 'FastLlm.Settings') { throw 'Exception calling "Parse" with "1" argument(s): injected Settings markup fault' }; return (& $script:realXamlLoader -Name $Name) }
    Initialize-ShellEnv
    $errSettings = ''
    try { Initialize-FastLlmUiFluentShell } catch { $errSettings = $_.Exception.Message }
    finally { Set-Item -Path Function:\New-FastLlmUiXamlElement -Value $script:realXamlLoader }
    Check ($errSettings -ceq 'startup stopped: xaml-parse') 'P99 an injected Settings markup fault stops the startup with xaml-parse (text C, exit 3)' "error='$errSettings'"
    Check ((${function:New-FastLlmUiXamlElement}).ToString() -ceq $script:realXamlLoader.ToString()) 'P99 the real XAML loader is restored after the Settings fault' ''
    Check (($script:dialogCalls['switch'] + $script:dialogCalls['models'] + $script:dialogCalls['components']) -eq 0) 'P99 ShowUiSwitchPicker, ShowModelsWindow and ShowComponentsWindow were never called by a Fluent page action' "switch=$($script:dialogCalls['switch']) models=$($script:dialogCalls['models']) components=$($script:dialogCalls['components'])"
    Check-NoExceptions 'P99'
}

# ---- P40: the SignInNotice row of the shell message area (PR 4a Task 6, the #84 lines) ----
function Invoke-P40-SignInNotice {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $els = $f['Els']
    $keys = $f['Keys']
    $saved = @{ Output = [string]$script:output.Text; Status = [string]$script:statusLabel.Text; Background = [string]$script:backgroundLabel.Text
        Snap = $script:shellSnap; Line = $keys['SignInLine']; Notice = $keys['Notice']; Held = [bool](Get-Variable -Name failureHeld -Scope Script -ValueOnly -ErrorAction SilentlyContinue); ViewText = [string](Get-Variable -Name failureViewText -Scope Script -ValueOnly -ErrorAction SilentlyContinue) }
    try {
        $notice = $els['SignInNotice']
        $bar = $els['SignInNoticeBar']
        Check ($null -ne $notice -and $null -ne $bar) 'P40 the shell has the SignInNotice row (SignInNotice and SignInNoticeBar)' "notice=$($null -ne $notice) bar=$($null -ne $bar)"
        if ($null -eq $notice -or $null -eq $bar) { return }
        $script:shellSnap = New-ShellSnap
        $script:failureHeld = $false
        $script:failureViewText = ''
        $script:backgroundLabel.Text = ''
        $keys['SignInLine'] = $null
        Invoke-FastLlmUiFluentTick
        Check ($bar.Visibility -eq [System.Windows.Visibility]::Collapsed -and [string]$notice.Text -ceq '') 'P40 with no sign-in line and no not-measured line the row is hidden and empty' "bar=$($bar.Visibility) text='$($notice.Text)'"
        # 1. The sign-in refusal line the window read at startup: the same non-blank text in the output box and the status line, captured once before the first tick
        $line = 'Sign-in start was refused (P40 probe line).'
        $script:output.Text = $line
        $script:statusLabel.Text = $line
        Save-FastLlmUiFluentSignInNotice
        Check ([string]$keys['SignInLine'] -ceq $line) 'P40 the capture keeps the startup line when the output box and the status line hold the same text' "kept='$($keys['SignInLine'])' expected='$line'"
        $liveBefore = Get-LiveCount $notice
        Invoke-FastLlmUiFluentTick
        Invoke-Pump 50
        Check ($bar.Visibility -eq [System.Windows.Visibility]::Visible -and [string]$notice.Text -ceq $line) 'P40 the row shows the sign-in line' "bar=$($bar.Visibility) text='$($notice.Text)' expected='$line'"
        Check ((Get-ShellPeerName $notice) -ceq $line) 'P40 the row is named by its text (peer name)' "peer='$(Get-ShellPeerName $notice)' expected='$line'"
        Check ([System.Windows.Automation.AutomationProperties]::GetLiveSetting($notice) -eq [System.Windows.Automation.AutomationLiveSetting]::Polite) 'P40 the row is a polite live region' "setting=$([System.Windows.Automation.AutomationProperties]::GetLiveSetting($notice))"
        Check ((Get-LiveCount $notice) -eq ($liveBefore + 1)) 'P40 showing the line raised the live region once' "before=$liveBefore after=$(Get-LiveCount $notice)"
        Invoke-FastLlmUiFluentTick
        Check ((Get-LiveCount $notice) -eq ($liveBefore + 1) -and [string]$keys['Notice'] -ceq $line) 'P40 a second tick with the same line does not announce it again' "count=$(Get-LiveCount $notice) notice='$($keys['Notice'])'"
        # 2. It hides after a successful start (a running card) and stays hidden when the card is not running again
        $script:shellSnap = New-ShellSnap @{ ChildActive = $true; Step = 'serving'; RunReady = $true }
        $cardState = [string](Get-FastLlmUiCardState -Snapshot $script:shellSnap).state
        Invoke-FastLlmUiFluentTick
        Check ($bar.Visibility -eq [System.Windows.Visibility]::Collapsed -and [string]$notice.Text -ceq '' -and $null -eq $keys['SignInLine']) 'P40 after a successful start (running card) the row is hidden and the line is dropped' "card='$cardState' bar=$($bar.Visibility) text='$($notice.Text)' kept='$($keys['SignInLine'])'"
        $script:shellSnap = New-ShellSnap
        Invoke-FastLlmUiFluentTick
        Check ($bar.Visibility -eq [System.Windows.Visibility]::Collapsed -and [string]$notice.Text -ceq '') 'P40 the row stays hidden when the card is no longer running' "bar=$($bar.Visibility) text='$($notice.Text)'"
        # 3. The no-measured-setup line (the existing text, on the background line) shows while it holds, and a different text hides it again
        $notMeasured = [string](Get-FastLlmSavedServingFailureText -Code 'serving-profile-not-measured')
        Check ($notMeasured -cne '') 'P40 the existing not-measured text is available' ''
        $script:backgroundLabel.Text = $notMeasured
        Invoke-FastLlmUiFluentTick
        Check ($bar.Visibility -eq [System.Windows.Visibility]::Visible -and [string]$notice.Text -ceq $notMeasured) 'P40 the row shows the existing not-measured text while the background line holds it' "bar=$($bar.Visibility) text='$($notice.Text)' expected='$notMeasured'"
        $script:backgroundLabel.Text = 'Some other background line.'
        Invoke-FastLlmUiFluentTick
        Check ($bar.Visibility -eq [System.Windows.Visibility]::Collapsed -and [string]$notice.Text -ceq '') 'P40 any other text hides the not-measured line again (no sign-in line is held)' "bar=$($bar.Visibility) text='$($notice.Text)'"
        $script:backgroundLabel.Text = ''
        $script:failureHeld = $true
        $script:failureViewText = $notMeasured
        Invoke-FastLlmUiFluentTick
        Check ($bar.Visibility -eq [System.Windows.Visibility]::Visible -and [string]$notice.Text -ceq $notMeasured) 'P40 the held start failure with the same text shows the row too' "bar=$($bar.Visibility) text='$($notice.Text)'"
    }
    finally {
        $script:output.Text = [string]$saved.Output
        $script:statusLabel.Text = [string]$saved.Status
        $script:backgroundLabel.Text = [string]$saved.Background
        $script:shellSnap = $saved.Snap
        $script:failureHeld = $saved.Held
        $script:failureViewText = $saved.ViewText
        $keys['SignInLine'] = $null
        Invoke-FastLlmUiFluentTick
    }
    Check-NoExceptions 'P40'
}

# ---- P41: the T5 default-button test. Every routed call site (and the side result and the driver guidance), opened through its real classic caller ----
# One data table (Get-PagesBoxTable, pinned to the classic AST on every platform) drives it. For each row the dialog is opened through the classic caller and
#   Enter is posted (the key plan's Enter target answers), then Escape (the Escape target answers, or a YesNo box stays open), then the close box is clicked
#   (SC_CLOSE: it answers the Escape target, or a YesNo box refuses it). The first focus is read just before the key. A box that stays open is then answered No by the
#   driver's fallback (never Yes), so FellBack is the evidence that the key or the close box did nothing. What the classic caller received is read from the recording
#   wrapper over the real seam ($script:boxCalls). Every box must be a WPF dialog ($rec Path 'wpf'): fluent mode shows no Win32 box.
# The callers: the five link handlers, the experimental toggle, NewUiApiKey, the three Remove flows, ContinueSupportBundle, InvokeUiUpdate and InvokeUiReinstall are the real
# functions and wiring statements of fast-llm-ui.ps1 (taken by the parser). Start-Process is shadowed by a throwing function for the whole step so no browser opens.
# Close FastLLM runs the handler's own `if(...)` statement from the parser (the whole handler would close the window); the "file already exists" box and the two licence
# link handlers run their own statement or script block from the parser (their callers need a native Save dialog or a WinForms form).
function Get-PagesAstNode([string]$Kind, [scriptblock]$Where) {
    $found = @($script:uiAst.FindAll($Where, $true))
    return $found
}
function Get-PagesBoxSources {
    $src = @{}
    $ast = $script:uiAst
    $ifs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text.Contains('ShowUiMessageBox') -and $n.Clauses[0].Item1.Extent.Text.Contains("'Close FastLLM'") }, $true))
    $src['CloseIf'] = $null
    if ($ifs.Count -eq 1) { $src['CloseIf'] = [scriptblock]::Create('param($sender, $event) ' + [string]$ifs[0].Extent.Text) }
    $ex = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Extent.Text.Contains('That file already exists') }, $true))
    $src['ExistsStmt'] = $null
    if ($ex.Count -eq 1) { $src['ExistsStmt'] = [scriptblock]::Create([string]$ex[0].Extent.Text) }
    foreach ($pair in @(@('LicenseSetting', 'ShowLicenseSettingConfirm'), @('LicenseConsent', 'ShowComponentConsent'))) {
        $script:p41Fn = [string]$pair[1]
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $script:p41Fn }, $true)
        $src[[string]$pair[0]] = $null
        if ($null -eq $fn) { continue }
        $wire = @($fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$n.Member.Extent.Text -ceq 'Add_LinkClicked' }, $true))
        if ($wire.Count -eq 1 -and $wire[0].Arguments.Count -eq 1) { $src[[string]$pair[0]] = & ([scriptblock]::Create([string]$wire[0].Arguments[0].Extent.Text)) }
    }
    return $src
}
# Attaches the real `<adapter>.Add_LinkClicked(...)` statements (the five link handlers) to the shell's adapters; returns the handler counts to put back.
function Add-PagesLinkWiring {
    $undo = @{}
    foreach ($target in '$vc', '$amd', '$resultsLink', '$barLink', '$bannerNotes') {
        $script:p41Target = [string]$target
        $wire = $script:uiAst.Find({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$n.Member.Extent.Text -ceq 'Add_LinkClicked' -and [string]$n.Expression.Extent.Text -ceq $script:p41Target }, $true)
        if ($null -eq $wire) { continue }
        $adapter = Get-Variable -Name ([string]$target).TrimStart('$') -Scope Script -ValueOnly
        $undo[[string]$target] = @{ Adapter = $adapter; Count = [int]$adapter.__handlers['LinkClicked'].Count }
        $wireFile = Join-Path $script:InstallRoot ('wire-' + [guid]::NewGuid().ToString('N') + '.ps1')
        [System.IO.File]::WriteAllText($wireFile, [string]$wire.Extent.Text, (New-Object System.Text.UTF8Encoding($false)))
        . $wireFile
    }
    return $undo
}
function Remove-PagesLinkWiring($Undo) {
    foreach ($k in @($Undo.Keys)) {
        $list = $Undo[$k]['Adapter'].__handlers['LinkClicked']
        $n0 = [int]$Undo[$k]['Count']
        if ($list.Count -gt $n0) { $list.RemoveRange($n0, $list.Count - $n0) }
    }
}

# Opens the box of one row through its real classic caller. Blocks until the box is answered (the driver timers answer it).
function Invoke-PagesBoxOpen([string]$Id) {
    $els = $script:FastLlmUiFluent['Els']
    $src = $script:p41Src
    $click = [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent
    switch ($Id) {
        'link-vc' { Invoke-FastLlmUiAdapterEvent -Adapter $script:vc -Event 'LinkClicked' }
        'link-amd' { Invoke-FastLlmUiAdapterEvent -Adapter $script:amd -Event 'LinkClicked' }
        'link-results' { $script:evidenceUrl = 'https://bitworks.io/probe-evidence'; Invoke-FastLlmUiAdapterEvent -Adapter $script:resultsLink -Event 'LinkClicked' }
        'link-bar' { Invoke-FastLlmUiAdapterEvent -Adapter $script:barLink -Event 'LinkClicked' }
        'link-release' { $script:bannerUrl = 'https://github.com/bitworks-io/amd-inference/releases/tag/probe'; Invoke-FastLlmUiAdapterEvent -Adapter $script:bannerNotes -Event 'LinkClicked' }
        'experimental' {
            $null = Open-SettingsPage @{}
            $els.SettingsExperimentalToggle.IsChecked = $false
            Invoke-Pump 50
            $els.SettingsExperimentalToggle.IsChecked = $true
            Invoke-Pump 100
            $els.SettingsExperimentalToggle.IsChecked = $false
            Invoke-Pump 50
            Close-SettingsPage
        }
        'license-setting' { & $src['LicenseSetting'] ([pscustomobject]@{ Tag = 'https://example.org/license-probe' }) $null }
        'license-consent' { & $src['LicenseConsent'] ([pscustomobject]@{ Tag = 'https://example.org/license-probe' }) $null }
        'newkey-ask' { $null = NewUiApiKey $script:form }
        'newkey-done' { $null = NewUiApiKey $script:form }
        'remove-model' {
            $null = Reset-ModelsFixture; Open-ModelsPage
            $b = @(Get-ModelsRowButtons $els.ModelsModelRows)[0]
            $b.RaiseEvent((New-ShellClick $b $click)); Invoke-Pump 100
        }
        'remove-leftovers' {
            $null = Reset-ModelsFixture
            [void]$script:leftoverStore.Add([pscustomobject]@{ name = 'probe-leftover.part'; sizeBytes = [int64]1073741824; locked = $false })
            Open-ModelsPage
            $els.ModelsLeftoverButton.RaiseEvent((New-ShellClick $els.ModelsLeftoverButton $click)); Invoke-Pump 100
        }
        'remove-component' {
            $null = Reset-ModelsFixture; Open-ModelsPage
            $b = @(Get-ModelsRowButtons $els.ModelsComponentRows)[0]
            $b.RaiseEvent((New-ShellClick $b $click)); Invoke-Pump 100
        }
        'bundle-list' { ContinueSupportBundle '{"entries":[{"name":"probe.txt","sizeBytes":2048}],"redactions":1}' }
        'bundle-exists' { & $src['ExistsStmt'] }
        'update' {
            $script:updateOffer = [pscustomobject]@{ version = '2099.01.01.1' }
            $script:sideChild = $null
            try { InvokeUiUpdate } finally { Remove-Variable -Name updateOffer -Scope Script -ErrorAction SilentlyContinue; Remove-Variable -Name sideChild -Scope Script -ErrorAction SilentlyContinue }
        }
        'reinstall' {
            $script:reinstallOffer = [pscustomobject]@{ from = '2099.01.01.1'; to = '2099.01.01.2' }
            $script:sideChild = $null
            try { InvokeUiReinstall } finally { Remove-Variable -Name reinstallOffer -Scope Script -ErrorAction SilentlyContinue; Remove-Variable -Name sideChild -Scope Script -ErrorAction SilentlyContinue }
        }
        'close' {
            $ev = [pscustomobject]@{ Cancel = $false }
            & $src['CloseIf'] $null $ev
            $script:p41CloseCancel = [bool]$ev.Cancel
        }
        'side' { ShowUiSideResult 'FastLLM P41 side result' ((1..60 | ForEach-Object { 'Probe line ' + $_ + ' of a long side result.' }) -join "`n") }
        'guidance' { ShowDriverGuidance $script:p41Diagnostic }
        default { throw "P41 has no opener for '$Id'" }
    }
}

# The steps a row needs besides the box under test: Pre answers an earlier box of the same caption (Create a new key asks, then confirms), PostEnter answers what
# Enter leads to (the confirmation box, the native Save dialog).
function Get-PagesBoxExtras([string]$Id) {
    $pre = @(); $post = @()
    if ($Id -ceq 'newkey-done') { $pre = @(@{ Kind = 'box'; Caption = 'Create a new key'; Id = 6; Fallback = 7 }) }
    if ($Id -ceq 'newkey-ask') { $post = @(@{ Kind = 'box'; Caption = 'Create a new key'; Id = 1; Fallback = 2 }) }
    # the native SaveFileDialog that OK leads to has the box's own title: its step is marked Native, so the clean check allows its Win32 record
    if ($Id -ceq 'bundle-list') { $post = @(@{ Kind = 'box'; Caption = 'Save support bundle'; Id = 2; Fallback = 2; Native = $true }) }
    return @{ Pre = $pre; Post = $post }
}

# One phase of one row: arms the driver (Enter, Escape or the close box on the box under test, then the extras and the watch), opens the caller, returns the records.
function Invoke-PagesBoxPhase([string]$Id, [string]$Caption, [string]$Buttons, [string]$Action) {
    $extras = Get-PagesBoxExtras $Id
    $fallback = 0
    if ($Buttons -ceq 'YesNo') { $fallback = 7 } elseif ($Buttons -ceq 'OKCancel') { $fallback = 2 } elseif ($Buttons -ceq 'OK') { $fallback = 1 }
    $main = @{ Kind = 'box'; Caption = $Caption; Fallback = $fallback }
    if ($Action -ceq 'enter') { $main['Key'] = 0x0D } elseif ($Action -ceq 'escape') { $main['Key'] = 0x1B } else { $main['Sys'] = $true }
    $steps = New-Object System.Collections.ArrayList
    foreach ($x in @($extras.Pre)) { [void]$steps.Add($x) }
    [void]$steps.Add($main)
    if ($Action -ceq 'enter') { foreach ($x in @($extras.Post)) { [void]$steps.Add($x) } }
    [void]$steps.Add((New-SettingsWatch))
    $script:boxCalls.Clear()
    $d = @{}
    $err = ''
    $timer = Start-SettingsDialogs $steps.ToArray() $d
    try { Invoke-PagesBoxOpen $Id } catch { $err = $_.Exception.Message } finally { $timer.Stop() }
    Invoke-Pump 100
    return @{ D = $d; Err = $err; Calls = @($script:boxCalls.ToArray()); PreCount = @($extras.Pre).Count }
}

# A MessageBox argument as the enum value (a 'bad:' string when the name is not one of the type), so two names of one value compare equal.
function ConvertTo-PagesBoxEnum([string]$TypeName, $Value) {
    $type = [type]('System.Windows.Forms.' + $TypeName)
    try { return ('v' + [string][int][System.Enum]::Parse($type, [string]$Value, $true)) } catch { return ('bad:' + [string]$Value) }
}

# The checks of one phase of one routed call site. Returns $false when the box never appeared (the row's other phases are then skipped, so a broken opener costs one wait).
function Test-PagesBoxPhase($Row, [string]$Action, [IntPtr]$MainHwnd) {
    $id = [string]$Row.Id
    $r = Invoke-PagesBoxPhase $id ([string]$Row.Caption) ([string]$Row.Buttons) $Action
    $d = $r.D
    $rec = Get-SettingsRec $d ([int]$r.PreCount)
    $calls = @($r.Calls | Where-Object { [string]$_.Caption -ceq [string]$Row.Caption -and [string]$_.Buttons -ceq [string]$Row.Buttons })
    $result = ''
    if ($calls.Count -gt 0) { $result = [string]$calls[0].Result }
    $exp = Get-PagesBoxExpect ([string]$Row.Buttons) ([string]$Row.Default)
    $detail = (Get-SettingsRecDetail $d) + " calls=$($r.Calls.Count) result='$result' error='$($r.Err)'"
    $n = "P41 $id $Action"
    $found = [bool]$rec['Found']
    Check ($found -and (Test-SettingsRecClean $d)) "$n : the box appeared as a WPF dialog and was answered within 6 s, with nothing unexpected" $detail
    if (-not $found) { return $false }
    Check ($calls.Count -eq 1) "$n : the classic caller reached ShowUiMessageBox once for this box" "calls=$($calls.Count) $detail"
    if ($Action -ceq 'enter') {
        # the classic caller passed the arguments the AST table says, the owner is the main window and it is disabled while the box is up
        # compared as enums: the call sites pass [MessageBoxIcon] values, and Information and Asterisk (also Warning and Exclamation, Error and Hand) share a value,
        # so the string the seam received can be the other name of the same value
        $got = ''
        $same = $false
        if ($calls.Count -gt 0) {
            $got = "$($calls[0].Buttons)/$($calls[0].Icon)/$($calls[0].Default)"
            $same = ((ConvertTo-PagesBoxEnum 'MessageBoxButtons' $calls[0].Buttons) -eq (ConvertTo-PagesBoxEnum 'MessageBoxButtons' $Row.Buttons)) -and
                ((ConvertTo-PagesBoxEnum 'MessageBoxIcon' $calls[0].Icon) -eq (ConvertTo-PagesBoxEnum 'MessageBoxIcon' $Row.Icon)) -and
                ((ConvertTo-PagesBoxEnum 'MessageBoxDefaultButton' $calls[0].Default) -eq (ConvertTo-PagesBoxEnum 'MessageBoxDefaultButton' $Row.Default))
        }
        Check $same "$n : the caller passed the table's buttons, icon and default button" "actual='$got' expected='$($Row.Buttons)/$($Row.Icon)/$($Row.Default)'"
        Check ([long]$rec['Owner'] -eq $MainHwnd.ToInt64() -and -not [bool]$rec['WpfEnabledDuring']) "$n : the box is owned by the main window and the main window is disabled while it is up" "owner=$($rec['Owner']) expected=$($MainHwnd.ToInt64()) mainEnabledDuring=$($rec['WpfEnabledDuring'])"
        $fi = $rec['FocusInfo']
        $focusId = ''
        if ($fi -is [System.Collections.IDictionary]) { $focusId = [string]$fi['Id'] }
        Check ($focusId -ceq [string]$exp.Focus) "$n : the first focus is the Enter target button" "actual focus id='$focusId' expected='$($exp.Focus)' focus='$($rec['Focus'])' active=$($rec['Active'])"
        Check ([bool]$rec['KeyPosted'] -and -not [bool]$rec['FellBack'] -and $result -ceq [string]$exp.Enter) "$n : Enter answers $($exp.Enter)" "actual result='$result' expected='$($exp.Enter)' fellBack=$($rec['FellBack']) keyPosted=$($rec['KeyPosted']) active=$($rec['Active']) focus='$($rec['Focus'])' rung='$($rec['Rung'])'"
        if ($id -ceq 'close') { Check ([bool]$script:p41CloseCancel -eq ($result -cne 'Yes')) "$n : the Close FastLLM handler cancels the close exactly when the answer is not Yes" "cancel=$($script:p41CloseCancel) result='$result'" }
    }
    elseif ($Action -ceq 'escape') {
        if ([string]$exp.Escape -cne '') {
            Check (-not [bool]$rec['FellBack'] -and $result -ceq [string]$exp.Escape) "$n : Escape answers $($exp.Escape)" "actual result='$result' expected='$($exp.Escape)' fellBack=$($rec['FellBack']) keyPosted=$($rec['KeyPosted']) active=$($rec['Active']) rung='$($rec['Rung'])'"
        }
        else {
            Check ([bool]$rec['FellBack'] -and $result -ceq 'No') "$n : Escape does nothing (the box stays open until the driver presses No)" "actual result='$result' expected='No' fellBack=$($rec['FellBack']) (true means it stayed open) keyPosted=$($rec['KeyPosted']) rung='$($rec['Rung'])'"
        }
    }
    else {
        if ([bool]$exp.XEnabled) {
            Check (-not [bool]$rec['FellBack'] -and $result -ceq [string]$exp.X) "$n : the close box answers $($exp.X)" "actual result='$result' expected='$($exp.X)' fellBack=$($rec['FellBack']) keyPosted=$($rec['KeyPosted']) rung='$($rec['Rung'])'"
        }
        else {
            Check ([bool]$rec['FellBack'] -and $result -ceq 'No') "$n : the close box is refused (the box stays open until the driver presses No)" "actual result='$result' expected='No' fellBack=$($rec['FellBack']) (true means it stayed open) keyPosted=$($rec['KeyPosted']) rung='$($rec['Rung'])'"
        }
    }
    return $true
}

# The two forms (no ShowUiMessageBox call): Close answers Enter, Escape and the close box for the side result; the driver guidance has no Enter target.
function Test-PagesFormPhase([string]$Kind, [string]$Action, [IntPtr]$MainHwnd) {
    $caption = 'FastLLM P41 side result'
    if ($Kind -ceq 'guidance') { $caption = 'AMD driver guidance - read-only' }
    $main = @{ Kind = 'box'; Caption = $caption }
    if ($Action -ceq 'enter') { $main['Key'] = 0x0D } elseif ($Action -ceq 'escape') { $main['Key'] = 0x1B } else { $main['Sys'] = $true }
    $d = @{}
    $err = ''
    $script:trayAvailability.Clear()
    $timer = Start-SettingsDialogs @($main, (New-SettingsWatch)) $d
    try { Invoke-PagesBoxOpen $Kind } catch { $err = $_.Exception.Message } finally { $timer.Stop() }
    Invoke-Pump 100
    $rec = Get-SettingsRec $d 0
    $n = "P41 $Kind $Action"
    $detail = (Get-SettingsRecDetail $d) + " error='$err'"
    $found = [bool]$rec['Found']
    Check ($found -and (Test-SettingsRecClean $d)) "$n : the form appeared as a WPF dialog and was closed within 6 s, with nothing unexpected" $detail
    if (-not $found) { return }
    # Enter on the side result closes it (Close is the Enter target); on the driver guidance there is no Enter target, so the dialog stays until the driver closes it
    $stays = ($Kind -ceq 'guidance' -and $Action -ceq 'enter')
    Check ([bool]$rec['FellBack'] -eq $stays) "$n : the form $(if ($stays) { 'stays open (no Enter target)' } else { 'closes' })" "fellBack=$($rec['FellBack']) expected=$stays keyPosted=$($rec['KeyPosted']) active=$($rec['Active']) rung='$($rec['Rung'])'"
    if ($Action -ceq 'enter') {
        $fi = $rec['FocusInfo']
        $okFocus = $false
        if ($fi -is [System.Collections.IDictionary]) { if ($Kind -ceq 'guidance') { $okFocus = [bool]$fi['InDevices'] } else { $okFocus = ([string]$fi['Id'] -ceq 'Close') } }
        Check $okFocus "$n : the first focus is $(if ($Kind -ceq 'guidance') { 'the device list' } else { 'the Close button' })" "focus='$($rec['Focus'])' info=$(if ($fi -is [System.Collections.IDictionary]) { "id='$($fi['Id'])' inDevices=$($fi['InDevices'])" } else { 'none' })"
        Check ([long]$rec['Owner'] -eq $MainHwnd.ToInt64() -and -not [bool]$rec['WpfEnabledDuring']) "$n : the form is owned by the main window, which is disabled while it is up" "owner=$($rec['Owner']) expected=$($MainHwnd.ToInt64()) mainEnabledDuring=$($rec['WpfEnabledDuring'])"
    }
    if ($Kind -ceq 'guidance') { Check (($script:trayAvailability.ToArray() -join ',') -ceq 'False,True') "$n : the tray menu was turned off while the form was open and on again after" "calls=$($script:trayAvailability.ToArray() -join ',')" }
}

function Invoke-P41-DialogKeys {
    if (-not $script:shellOk) { return }
    $f = $script:FastLlmUiFluent
    $win = $f.Window
    $hwnd = Get-ModelsWindowHandle
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    $null = $win.Activate()
    Invoke-Pump 100
    $missing = @('Get-FastLlmUiEvidenceUrl', 'Get-FastLlmUiSafeLicenseUrl', 'Get-FastLlmUiNewKeyConfirmText', 'Format-FastLlmUiSupportBundleList', 'Format-FastLlmUiUpdateConfirm', 'Format-FastLlmUiReinstallConfirm', 'Test-FastLlmUiVcActionAllowed', 'Format-FastLlmDriverGuidance') |
        Where-Object { $null -eq (Get-Command -Name $_ -ErrorAction SilentlyContinue) }
    Check (@($missing).Count -eq 0 -and @($script:p22Missing).Count -eq 0 -and $null -ne $script:realShowBox) 'P41 the callers and helpers the table needs are loaded (the classic functions, the seam and the recording wrapper)' ("missing=" + (@($missing) -join ',') + " classic=" + (@($script:p22Missing) -join ',') + " wrapper=$($null -ne $script:realShowBox)")
    Check ($null -ne $script:uiDialogView -and $null -ne $script:uiDialogView['MessageBox']) 'P41 the shell registered the fluent view table, so the seam shows the fluent box' "view=$($null -ne $script:uiDialogView)"
    # the clean check lets a Native step's Win32 record through (the SaveFileDialog after the support bundle box) and still rejects any other Win32 box
    $synth = { param([bool]$Native) $recs = New-Object System.Collections.ArrayList; [void]$recs.Add(@{ Kind = 'box'; Found = $true; Path = 'win32'; Caption = 'Save support bundle'; Native = $Native }); return @{ recs = $recs; timedOut = $false; hardStop = $false; unexpected = 0 } }
    Check ((Test-SettingsRecClean (& $synth $true)) -and -not (Test-SettingsRecClean (& $synth $false))) 'P41 pin: a Native Win32 record is clean, a non-Native Win32 record is still rejected' ''
    $script:p41Src = Get-PagesBoxSources
    $srcMissing = @($script:p41Src.Keys | Where-Object { $null -eq $script:p41Src[$_] })
    Check ($srcMissing.Count -eq 0) 'P41 the Close FastLLM statement, the already-exists statement and the two licence link handlers were found in fast-llm-ui.ps1' ("missing=" + ($srcMissing -join ','))
    $script:p41Diagnostic = [pscustomobject]@{ windows = $true; driverGuidance = @([pscustomobject]@{ schemaVersion = 1; qualification = $false; automaticDriverInstall = $false; hasOwnTrustedMapping = $false
        asOf = '2026-01-01'; inputGpuName = 'Probe display device'; reportedPnpDriverVersion = '1.0'; knownFocusModel = $false; note = '' }) }
    # Start-Process is shadowed for the whole step (a local function, seen by every callee): a link handler's catch block shows its box and no browser opens.
    function Start-Process { throw 'P41: Start-Process is blocked in this test' }
    $undo = Add-PagesLinkWiring
    $script:p41CloseCancel = $false
    $rowWatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        foreach ($row in @(Get-PagesBoxTable)) {
            $rowStart = $rowWatch.ElapsedMilliseconds
            foreach ($action in 'enter', 'escape', 'x') {
                $go = Test-PagesBoxPhase $row $action $hwnd
                if (-not $go) { break }
            }
            Write-Host ("INFO: P41 row $($row.Id) took " + ($rowWatch.ElapsedMilliseconds - $rowStart) + " ms")
        }
        foreach ($kind in 'side', 'guidance') {
            foreach ($action in 'enter', 'escape', 'x') { Test-PagesFormPhase $kind $action $hwnd }
        }
        # Owner checks. 1. A box opened while the window is in the tray (the owner hidden) still shows, unowned and centred, and is answerable; the window then restores.
        $script:form.Hide()
        Invoke-Pump 100
        $d = @{}
        $script:boxCalls.Clear()
        $timer = Start-SettingsDialogs @(@{ Kind = 'box'; Caption = 'Open AMD page'; Key = 0x0D; Fallback = 1 }, (New-SettingsWatch)) $d
        $err = ''
        try { Invoke-PagesBoxOpen 'link-amd' } catch { $err = $_.Exception.Message } finally { $timer.Stop() }
        Invoke-Pump 100
        $script:form.Show()
        $script:form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        $script:form.Activate()
        Invoke-Pump 150
        $rec = Get-SettingsRec $d 0
        $trayCalls = @($script:boxCalls.ToArray())
        Check ([bool]$rec['Found'] -and (Test-SettingsRecClean $d) -and [long]$rec['Owner'] -eq 0 -and -not [bool]$rec['WpfEnabledDuring'] -and -not [bool]$rec['FellBack'] -and $trayCalls.Count -eq 1 -and [string]$trayCalls[0].Result -ceq 'OK') 'P41 a box opened while the window is in the tray shows (unowned), the hidden main window is disabled while it is open, and Enter answers it OK' ((Get-SettingsRecDetail $d) + " owner=$($rec['Owner']) expected=0 calls=$($trayCalls.Count) result='$(if ($trayCalls.Count -gt 0) { $trayCalls[0].Result })' error='$err'")
        Check ($win.IsVisible -and [bool]$script:native::IsWindowEnabled($hwnd)) 'P41 after the tray box the window is back, visible and enabled' "visible=$($win.IsVisible) enabled=$($script:native::IsWindowEnabled($hwnd))"
    }
    finally {
        Remove-PagesLinkWiring $undo
        $null = Set-FastLlmUiFluentPage -Id 'Home'
    }
    # 2. The licence link error box (the two handlers) is owned by the main window in 4a: checked per row above (license-setting, license-consent); the list below names it.
    Write-Host 'INFO: P41 licence-link rows license-setting and license-consent check Owner = the main window handle in the enter phase'
    Check-NoExceptions 'P41'
}

# ---- P42: the T5 default-button test for the seven 4b dialogs (licence setting, component consent, exact model consent, VC++ review, setup check, recipe chooser, save prompt) ----
# One data table (Get-PagesDialogTable pins its targets to the classic AST on every platform) plus the Windows table below. For each dialog: Enter, then Escape, then the close box
# (SC_CLOSE), each through the dialog's real classic caller; the first focus, the owner and its disabled state, the tray calls, the reveal count and the result (read from what the
# caller received) are checked. The recipe chooser adds Enter with a selection and a double-click. A tray-hidden open runs the VC++ review with the main window hidden.
function Get-P42Rows {
    return @(
        @{ Id = 'license-setting'; Title = 'Install engine components automatically'; Fallback = 'Cancel'; Focus = 'Cancel'; Reveal = 0; Enter = 'declined'; Escape = 'declined'; X = 'declined' },
        @{ Id = 'component-consent'; Title = 'Install engine components'; Fallback = 'Cancel'; Focus = 'Cancel'; Reveal = 1; Enter = 'cancelled'; Escape = 'cancelled'; X = 'cancelled' },
        @{ Id = 'model-consent'; Title = 'Review exact model license and artifact'; Fallback = 'Cancel'; Focus = 'Cancel'; Reveal = 1; Enter = 'bool:False'; Escape = 'bool:False'; X = 'bool:False' },
        @{ Id = 'vc-review'; Title = 'Review Microsoft VC++ package and installation'; Fallback = 'Later'; Focus = 'Later'; Reveal = 1; Enter = 'bool:False'; Escape = 'bool:False'; X = 'bool:False' },
        @{ Id = 'setup-check'; Title = 'FastLLM setup check'; Fallback = 'Later'; Focus = 'Recheck'; Reveal = 1; Enter = 'str:recheck'; Escape = 'str:defer'; X = 'str:defer' },
        @{ Id = 'recipe-chooser'; Title = 'Choose another setup'; Fallback = 'Cancel'; Focus = 'list'; Reveal = 1; Enter = 'null'; Escape = 'null'; X = 'null'; EnterStays = $true },
        @{ Id = 'save-prompt'; Title = 'FastLLM settings'; Fallback = 'Cancel'; Focus = 'Cancel'; Reveal = 0; Enter = 'page:Settings'; Escape = 'page:Settings'; X = 'page:Settings' }
    )
}
function New-P42Watch {
    $caps = @('FastLLM settings', 'Create a new key', 'Experimental community components', 'Open license page', 'Install engine components automatically', 'Install engine components',
        'Review exact model license and artifact', 'Review Microsoft VC++ package and installation', 'FastLLM setup check', 'Choose another setup')
    return @{ Kind = 'watch'; Captions = $caps; Id = 2 }
}
function Initialize-P42Fixtures {
    if ($null -ne $script:p42Fx) { return }
    $model = @($script:catalog.models | Where-Object { [string]$_.id -ceq 'qwen3.8-27b-ud-q4-k-m-4af51b35' })[0]
    if ($null -eq $model) { $model = $script:catalog.models[0] }
    $cache = Join-Path $root 'test-vc-cache'
    $script:vcCacheRoot = $cache
    $candidate = [pscustomobject]@{ version = '14.51.36247.0'; fileName = 'VC_redist.x64.exe'; sizeBytes = 18731856
        sha256 = '843068991daaa1f73ad9f6239bce4d0f6a07a51f18c37ea2a867e9beca71295c'
        url = 'https://download.visualstudio.microsoft.com/download/pr/ebdab8e5-1d7b-4d9f-a11b-cbb1720c3b12/843068991DAAA1F73AD9F6239BCE4D0F6A07A51F18C37EA2A867E9BECA71295C/VC_redist.x64.exe'
        signerSubject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' }
    $script:p42Candidate = $candidate
    $run = Join-Path $cache ('vc-redist-' + ('a' * 32))
    $receipt = [pscustomobject]@{ status = 'prepared-not-installed'; path = (Join-Path $run 'VC_redist.x64.exe'); version = $candidate.version; sizeBytes = $candidate.sizeBytes
        sha256 = $candidate.sha256; signatureStatus = 'Valid'; installerExecuted = $false; compatibilityQualified = $false }
    $decision = [pscustomobject]@{ canProceed = $false; missing64BitHost = $false; missingVcRuntimeFiles = @('MSVCP140.dll'); missingVulkanLoader = $false; advisoryWarnings = @('Probe advisory warning.') }
    $diagnostic = [pscustomobject]@{ prerequisiteInventory = $null }
    $plan = [pscustomobject]@{ model = $model; hardwareFingerprint = 'probe-card'; selectedAdapters = @([pscustomobject]@{ device = 'Vulkan0'; name = 'Probe adapter' }) }
    $chain = @(
        [pscustomobject]@{ id = 'probe-comp-a'; displayName = 'Probe component A'; version = '1.0'; state = 'missing'; sourceHosts = @('example.org'); redirectHosts = @(); licenseLinks = @([pscustomobject]@{ title = 'Probe licence A'; url = 'https://example.org/license-a' }) },
        [pscustomobject]@{ id = 'probe-comp-b'; displayName = 'Probe component B'; version = '2.0'; state = 'missing'; sourceHosts = @('example.org'); redirectHosts = @('cdn.example.org'); licenseLinks = @([pscustomobject]@{ title = 'Probe licence B'; url = 'https://example.org/license-b' }) }
    )
    $consentRows = @(Get-FastLlmUiConsentRows -Chain $chain)
    $componentRow = [pscustomobject]@{ id = 'probe-recipe-2'; origin = 'bitworks'; variant = 'probe-card'; label = 'Probe setup two'; model = [string]$model.id; contextSize = 8192; contextText = '8,192 tokens'; engineText = 'Probe component B (from example.org; missing); requires Probe component A (from example.org; missing)'; engineId = 'probe-engine'
        chain = $chain; consentRequired = $true; installRequired = $true; experimental = $false; chainError = '' }
    $chooserRows = @(
        [pscustomobject]@{ id = 'probe-recipe-1'; origin = 'bitworks'; variant = 'probe-card'; label = 'Probe setup one'; model = [string]$model.id; contextSize = 8192; contextText = '8,192 tokens'; engineText = 'probe-engine'; engineId = 'probe-engine'; chain = @(); consentRequired = $false; installRequired = $false; experimental = $false; chainError = '' },
        [pscustomobject]@{ id = 'probe-recipe-2'; origin = 'bitworks'; variant = 'probe-card'; label = 'Probe setup two'; model = [string]$model.id; contextSize = 16384; contextText = '16,384 tokens'; engineText = 'probe-engine'; engineId = 'probe-engine'; chain = @(); consentRequired = $false; installRequired = $false; experimental = $false; chainError = '' }
    )
    $disclosure = Get-FastLlmUiLicenseDisclosure -Components @(Get-FastLlmComponents -ComponentsPath (Join-Path $root 'config/components.json'))
    $script:identifiedVariant = 'probe-card'
    $script:p42Fx = @{ Plan = $plan; Receipt = $receipt; Candidate = $candidate; Decision = $decision; Diagnostic = $diagnostic; ComponentRow = $componentRow; ConsentRows = $consentRows; ChooserRows = $chooserRows; Disclosure = $disclosure }
}
# Opens one dialog through its real classic caller and blocks until it is answered. The value the caller received is kept in $script:p42Result.
function Invoke-P42Open([string]$Id) {
    $fx = $script:p42Fx
    $els = Get-SettingsEls
    $script:p42Result = $null
    switch ($Id) {
        'license-setting' { $null = Open-SettingsPage @{}; $els.SettingsLicenseToggle.IsChecked = $true }
        'component-consent' { $script:p42Launch.Clear(); $script:statusLabel.Text = 'status before the consent'; ContinueWithChosenRecipe $fx.ComponentRow }
        'model-consent' { $script:p42Result = @(ShowExactModelConsent $fx.Plan) }
        'vc-review' { $script:p42Result = @(ShowVcInstallReview $fx.Receipt $fx.Candidate) }
        'setup-check' { $script:p42Result = @(ShowSetupAttention $fx.Decision $fx.Diagnostic) }
        'recipe-chooser' { $script:p42Begin.Clear(); $script:p42Result = @(ShowRecipeChooser $fx.ChooserRows) }
        'save-prompt' {
            $null = Open-SettingsPage @{}
            $els.SettingsPortBox.Text = '9001'
            $els.SettingsThinkingBox.SelectedIndex = 1
            Invoke-Pump 30
            $els.NavList.SelectedIndex = 0
            Invoke-Pump 100
        }
        default { throw "P42 has no opener for '$Id'" }
    }
}
# What the caller got, as one comparable string ('bad-return ...' when a [bool] contract is not exactly one bool).
function Get-P42Outcome([string]$Id) {
    $els = Get-SettingsEls
    $r = @($script:p42Result)
    switch ($Id) {
        'license-setting' {
            if ($script:setLicWrites.Count -gt 0) { return ('written:' + ($script:setLicWrites.ToArray() -join ',')) }
            if ($els.SettingsLicenseToggle.IsChecked -eq $false) { return 'declined' }
            return 'toggle-still-on'
        }
        'component-consent' {
            if ($script:p42Launch.Count -gt 0) { return ('launch:' + [string]$script:p42Launch[0].Step + ' x' + $script:p42Launch.Count) }
            if ([string]$script:statusLabel.Text -ceq 'Component install cancelled. Nothing was downloaded.') { return 'cancelled' }
            return ('status:' + [string]$script:statusLabel.Text)
        }
        { $_ -ceq 'model-consent' -or $_ -ceq 'vc-review' } {
            if ($r.Count -ne 1 -or $r[0] -isnot [bool]) { return ("bad-return count=$($r.Count) type=$(if ($r.Count -gt 0 -and $null -ne $r[0]) { $r[0].GetType().Name } else { 'null' })") }
            return ('bool:' + [string]$r[0])
        }
        'setup-check' {
            if ($r.Count -ne 1 -or $r[0] -isnot [string]) { return "bad-return count=$($r.Count)" }
            return ('str:' + [string]$r[0])
        }
        'recipe-chooser' {
            if ($r.Count -ne 1) { return "bad-return count=$($r.Count)" }
            if ($null -eq $r[0]) { return 'null' }
            return ('row:' + [string]$r[0].id)
        }
        'save-prompt' { return ('page:' + (Get-FastLlmUiFluentCurrentPage)) }
    }
    return 'unknown'
}
function Complete-P42Row([string]$Id) {
    if ($Id -ceq 'license-setting' -or $Id -ceq 'save-prompt') { Close-SettingsPage }
}
# One phase of one row. Returns $false when the dialog never appeared.
function Test-P42Phase($Row, [string]$Action, [IntPtr]$MainHwnd) {
    $id = [string]$Row.Id
    $main = @{ Kind = 'box'; Caption = [string]$Row.Title; Fallback = [string]$Row.Fallback }
    if ($Action -ceq 'enter') { $main['Key'] = 0x0D } elseif ($Action -ceq 'escape') { $main['Key'] = 0x1B } else { $main['Sys'] = $true }
    $d = @{}
    $err = ''
    $script:trayAvailability.Clear()
    $revealBefore = [int]$script:revealCalls
    $timer = Start-SettingsDialogs @($main, (New-P42Watch)) $d
    try { Invoke-P42Open $id } catch { $err = $_.Exception.Message } finally { $timer.Stop() }
    Invoke-Pump 100
    $rec = Get-SettingsRec $d 0
    $outcome = Get-P42Outcome $id
    $revealed = [int]$script:revealCalls - $revealBefore
    $trayText = ($script:trayAvailability.ToArray() -join ',')
    Complete-P42Row $id
    $n = "P42 $id $Action"
    $detail = (Get-SettingsRecDetail $d) + " outcome='$outcome' error='$err'"
    $found = [bool]$rec['Found']
    Check ($found -and (Test-SettingsRecClean $d)) "$n : the dialog appeared as a WPF dialog and was answered within 6 s, with nothing unexpected" $detail
    if (-not $found) { return $false }
    $want = [string]$Row[$(if ($Action -ceq 'enter') { 'Enter' } elseif ($Action -ceq 'escape') { 'Escape' } else { 'X' })]
    Check ($outcome -ceq $want) "$n : the classic caller received $want" "actual='$outcome' expected='$want' $detail"
    $stays = ($Action -ceq 'enter' -and $Row.ContainsKey('EnterStays'))
    Check ([bool]$rec['FellBack'] -eq $stays) "$n : $(if ($stays) { 'Enter does nothing (no row is selected: the driver presses Cancel)' } else { 'the key or the close box answered it without the fallback' })" "fellBack=$($rec['FellBack']) expected=$stays keyPosted=$($rec['KeyPosted']) rung='$($rec['Rung'])'"
    if ($Action -ceq 'enter') {
        $fi = $rec['FocusInfo']
        $focusOk = $false
        $focusText = ''
        if ($fi -is [System.Collections.IDictionary]) {
            $focusText = "id='$($fi['Id'])' text='$($fi['Text'])'"
            if ([string]$Row.Focus -ceq 'list') { $focusOk = ([string]$fi['Text'] -cmatch '^ListBox(Item)?:') } else { $focusOk = ([string]$fi['Id'] -ceq [string]$Row.Focus) }
        }
        Check $focusOk "$n : the first focus is $(if ([string]$Row.Focus -ceq 'list') { 'the list (Choose is disabled)' } else { "the Enter target button $($Row.Focus)" })" "actual $focusText expected='$($Row.Focus)'"
        Check ([long]$rec['Owner'] -eq $MainHwnd.ToInt64() -and -not [bool]$rec['WpfEnabledDuring']) "$n : the dialog is owned by the main window, which is disabled while it is up" "owner=$($rec['Owner']) expected=$($MainHwnd.ToInt64()) mainEnabledDuring=$($rec['WpfEnabledDuring'])"
        Check ($trayText -ceq 'False,True') "$n : the tray menu was turned off while open and on again after" "calls=$trayText"
        Check ($revealed -eq [int]$Row.Reveal) "$n : the window was revealed $($Row.Reveal) time(s) (the classic dialog's rule)" "reveal calls=$revealed expected=$($Row.Reveal)"
    }
    return $true
}
function Invoke-P42-DialogKeys {
    if (-not $script:shellOk) { return }
    $win = $script:FastLlmUiFluent.Window
    $hwnd = Get-ModelsWindowHandle
    $null = Set-FastLlmUiFluentPage -Id 'Home'
    $null = $win.Activate()
    Invoke-Pump 100
    Initialize-P42Fixtures
    $fx = $script:p42Fx
    Check (@($script:p42Missing).Count -eq 0 -and $null -ne $script:uiDialogView -and $null -ne $script:uiDialogView['ShowSetupAttention'] -and $null -ne $script:uiDialogView['ShowRecipeChooser']) 'P42 the six classic functions are loaded and the shell registered their fluent view keys' "missing=$(@($script:p42Missing) -join ',')"
    $texts = ''
    try { $texts = [string](Format-FastLlmUiModelConsent -Plan $fx.Plan) + [string](Format-FastLlmUiVcReview -Receipt $fx.Receipt -Candidate $fx.Candidate -CacheRoot $script:vcCacheRoot) } catch { $texts = '' ; Write-Host "INFO: P42 fixture error: $($_.Exception.Message)" }
    Check ($texts -cne '' -and $fx.Disclosure.links.Count -gt 0 -and [bool]$fx.Disclosure.canAccept -and @($fx.ConsentRows).Count -eq 2) 'P42 the fixtures (model plan, VC++ receipt, the real licence disclosure, two consent rows) are usable' "texts=$($texts.Length) links=$($fx.Disclosure.links.Count) canAccept=$($fx.Disclosure.canAccept) rows=$(@($fx.ConsentRows).Count)"
    $global:FastLlmTestStartProcess['Block'] = $true
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        foreach ($row in @(Get-P42Rows)) {
            $start = $watch.ElapsedMilliseconds
            foreach ($action in 'enter', 'escape', 'x') {
                $go = Test-P42Phase $row $action $hwnd
                if (-not $go) { break }
            }
            Write-Host ("INFO: P42 row $($row.Id) took " + ($watch.ElapsedMilliseconds - $start) + ' ms')
        }
        # The chooser with a selection: Enter chooses it; a double-click on a selected row chooses it; the real consumer receives the row.
        $listOf = { param($w) @(Get-ShellVisuals $w | Where-Object { $_ -is [System.Windows.Controls.ListBox] -and [string]$_.Name -ceq 'ChooserList' })[0] }
        $select = { param($w, $st) $l = & $listOf $w; $l.SelectedIndex = 1; $st['p42'] = @{ Enter = [string]$l.Items.Count } }.GetNewClosure()
        $double = {
            param($w, $st)
            $l = & $listOf $w
            $l.SelectedIndex = 0
            $e = New-Object System.Windows.Input.MouseButtonEventArgs([System.Windows.Input.Mouse]::PrimaryDevice, [Environment]::TickCount, [System.Windows.Input.MouseButton]::Left)
            $e.RoutedEvent = [System.Windows.Controls.Control]::MouseDoubleClickEvent
            # raised on the selected row item (the handler is on each row; a double-click on the list's scrollbar or empty area chooses nothing)
            $row = $l.Items[0]
            $e.Source = $row
            $row.RaiseEvent($e)
        }.GetNewClosure()
        foreach ($case in @(@('enter with a selection', 'probe-recipe-2', $true), @('double-click', 'probe-recipe-1', $false))) {
            $steps = @(@{ Kind = 'act'; Caption = 'Choose another setup'; Do = $(if ($case[2]) { $select } else { $double }); Closes = (-not $case[2]); Fallback = 'Cancel' })
            if ($case[2]) { $steps += @{ Kind = 'box'; Caption = 'Choose another setup'; Key = 0x0D; Fallback = 'Cancel' } }
            $steps += (New-P42Watch)
            $d = @{}
            $script:trayAvailability.Clear()
            $timer = Start-SettingsDialogs $steps $d
            $err = ''
            try { Invoke-P42Open 'recipe-chooser' } catch { $err = $_.Exception.Message } finally { $timer.Stop() }
            Invoke-Pump 100
            $outcome = Get-P42Outcome 'recipe-chooser'
            Check ($outcome -ceq ('row:' + [string]$case[1]) -and (Test-SettingsRecClean $d) -and -not [bool]$d['actFellBack'] -and [string]$d['actError'] -ceq '') "P42 recipe-chooser $($case[0]) chooses the selected row" "actual='$outcome' expected='row:$($case[1])' actError='$($d['actError'])' fellBack=$($d['actFellBack']) error='$err' $(Get-SettingsRecDetail $d)"
            # the real consumer of the picked row: not an install-required row, so BeginChosenRecipe gets it
            $script:p42Begin.Clear()
            ContinueWithChosenRecipe (@($script:p42Result)[0])
            Check ($script:p42Begin.Count -eq 1 -and [string]$script:p42Begin[0] -ceq [string]$case[1]) "P42 recipe-chooser $($case[0]): ContinueWithChosenRecipe begins the picked setup" "begin=$($script:p42Begin.ToArray() -join ',') expected=$($case[1])"
        }
        # Tray-hidden open: the main window is hidden (as in the tray); the VC++ review still shows (unowned, centred), disables the hidden window, and Enter answers Do later.
        $script:form.Hide()
        Invoke-Pump 100
        $d = @{}
        $timer = Start-SettingsDialogs @(@{ Kind = 'box'; Caption = 'Review Microsoft VC++ package and installation'; Key = 0x0D; Fallback = 'Later' }, (New-P42Watch)) $d
        $err = ''
        try { Invoke-P42Open 'vc-review' } catch { $err = $_.Exception.Message } finally { $timer.Stop() }
        Invoke-Pump 100
        $script:form.Show()
        $script:form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        $script:form.Activate()
        Invoke-Pump 150
        $rec = Get-SettingsRec $d 0
        $outcome = Get-P42Outcome 'vc-review'
        Check ([bool]$rec['Found'] -and (Test-SettingsRecClean $d) -and [long]$rec['Owner'] -eq 0 -and -not [bool]$rec['WpfEnabledDuring'] -and -not [bool]$rec['FellBack'] -and $outcome -ceq 'bool:False') 'P42 a VC++ review opened while the window is in the tray shows (unowned), the hidden main window is disabled while it is open, and Enter answers Do later (false)' ((Get-SettingsRecDetail $d) + " owner=$($rec['Owner']) expected=0 outcome='$outcome' error='$err'")
        Check ($win.IsVisible -and [bool]$script:native::IsWindowEnabled($hwnd)) 'P42 after the tray-hidden VC++ review the window is back, visible and enabled' "visible=$($win.IsVisible) enabled=$($script:native::IsWindowEnabled($hwnd))"
    }
    finally {
        $global:FastLlmTestStartProcess['Block'] = $false
        $null = Set-FastLlmUiFluentPage -Id 'Home'
    }
    Write-Host ("INFO: P42 took " + $watch.ElapsedMilliseconds + ' ms')
    Check-NoExceptions 'P42'
}

# ---- P43: flow steps of the 4b dialogs: consent accept (every box ticked) and cancel, the licence setting accept, the setup check with each answer, the VC++ review (install and
# do later), the exact model consent (accept and cancel), and the link that fails to open inside the licence dialog and the component consent (the warning box is owned by the dialog).
# The setup check, the VC++ review and the model consent run the real statements of fast-llm-ui.ps1 that consume their answers (taken by the parser); their callees are step stubs.
function Get-P43Statements {
    $ast = $script:uiAst
    $out = @{}
    $a = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Extent.Text -like '$choice=ShowSetupAttention*' }, $true))
    if ($a.Count -eq 1) {
        $sibs = @($a[0].Parent.Statements)
        $i = [array]::IndexOf($sibs, $a[0])
        if ($i -ge 0 -and $i + 1 -lt $sibs.Count -and $sibs[$i + 1] -is [System.Management.Automation.Language.SwitchStatementAst]) {
            $out['Setup'] = [scriptblock]::Create('param($decision, $diagnostic) ' + [string]$a[0].Extent.Text + "`n" + [string]$sibs[$i + 1].Extent.Text)
        }
    }
    $v = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text.Contains('ShowVcInstallReview') }, $true))
    if ($v.Count -eq 1) { $out['Vc'] = [scriptblock]::Create('param($receipt, $candidate) ' + [string]$v[0].Extent.Text) }
    $m = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -ceq '$script:flow.phase -eq ''consent''' -and $n.Extent.Text.Contains('ShowExactModelConsent') }, $true))
    if ($m.Count -eq 1) { $out['Model'] = [scriptblock]::Create('param($Plan) ' + [string]$m[0].Extent.Text) }
    return $out
}
# Runs one step list around an opener. Returns the record table and the opener's error text.
function Invoke-P43Run([object[]]$Steps, [scriptblock]$Open) {
    $d = @{ p42 = @{} }
    $err = ''
    $script:trayAvailability.Clear()
    $timer = Start-SettingsDialogs (@($Steps) + @((New-P42Watch))) $d
    try { & $Open } catch { $err = $_.Exception.Message } finally { $timer.Stop() }
    Invoke-Pump 100
    return @{ D = $d; Err = $err }
}
# A link click posted to the dispatcher (never run inside the answerer's tick, which would stop its timer in the nested frame the warning box opens).
# It is posted at Normal priority: it runs as soon as the tick returns. At Background priority it never ran on the Windows runner while the dialog was up
# (CI: the link was found, Start-Process was never reached and no exception was recorded). The likely cause: the WPF dispatcher defers Background items while it
# sees input pending. The other posted items in these suites use Input, Normal or Loaded.
# ClickRan, ClickDone and the operation's status are recorded, so a click that does not run is named in the failure detail.
function New-P43LinkClick([string]$LinkText) {
    $visuals = ${function:Get-ShellVisuals}
    return {
        param($w, $st)
        $link = @(& $visuals $w | Where-Object { $_ -is [System.Windows.Controls.Button] -and [System.Windows.Automation.AutomationProperties]::GetName($_) -ceq $LinkText })[0]
        $st['p42']['LinkFound'] = ($null -ne $link)
        $st['p42']['DialogHwnd'] = [System.Windows.Interop.WindowInteropHelper]::new($w).Handle.ToInt64()
        $st['p42']['ClickRan'] = $false
        $st['p42']['ClickDone'] = $false
        if ($null -eq $link) { return }
        $click = {
            $st['p42']['ClickRan'] = $true
            $link.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $link)))
            $st['p42']['ClickDone'] = $true
        }.GetNewClosure()
        $st['p42']['ClickOp'] = $w.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Normal, [Action]$click)
    }.GetNewClosure()
}
function Invoke-P43-DialogFlows {
    if (-not $script:shellOk) { return }
    $hwnd = Get-ModelsWindowHandle
    $els = Get-SettingsEls
    Initialize-P42Fixtures
    $fx = $script:p42Fx
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $global:FastLlmTestStartProcess['Block'] = $true
    $script:p43Log = New-Object System.Collections.ArrayList
    # step stubs for what the consumed statements call (local functions: seen by the parser-made script blocks through the call stack)
    function Move-FastLlmUiFlow { param($Flow, [Alias('Event')][string]$FlowEvent, [Parameter(ValueFromRemainingArguments = $true)]$Rest) [void]$script:p43Log.Add('move:' + $FlowEvent); return $Flow }
    function LaunchUiPhase { [void]$script:p43Log.Add('launch-phase') }
    function SetBusy([bool]$Busy) { [void]$script:p43Log.Add('busy:' + $Busy) }
    function StartVcBroker($Receipt) { [void]$script:p43Log.Add('broker') }
    $stmt = Get-P43Statements
    try {
        Check ($stmt.ContainsKey('Setup') -and $stmt.ContainsKey('Vc') -and $stmt.ContainsKey('Model')) 'P43 the three statements that consume the answers (setup check, VC++ review, model consent) were found in fast-llm-ui.ps1' "found=$(@($stmt.Keys) -join ',')"
        # ---- consent: accept with every box ticked ----
        $ticks = {
            param($w, $st)
            $boxes = @(Get-ShellVisuals $w | Where-Object { $_ -is [System.Windows.Controls.CheckBox] })
            $install = Find-WpfBoxButton $w 'Install'
            $states = New-Object System.Collections.ArrayList
            [void]$states.Add($boxes.Count)
            [void]$states.Add([bool]$install.IsEnabled)
            $boxes[0].IsChecked = $true; [void]$states.Add([bool]$install.IsEnabled)
            $boxes[1].IsChecked = $true; [void]$states.Add([bool]$install.IsEnabled)
            $boxes[1].IsChecked = $false; [void]$states.Add([bool]$install.IsEnabled)
            $boxes[1].IsChecked = $true; [void]$states.Add([bool]$install.IsEnabled)
            $st['p42']['States'] = ($states.ToArray() -join ',')
        }
        $openConsent = { $script:p42Launch.Clear(); $script:statusLabel.Text = 'status before the consent'; ContinueWithChosenRecipe $fx.ComponentRow }
        $r = Invoke-P43Run @(@{ Kind = 'act'; Caption = 'Install engine components'; Do = $ticks }, @{ Kind = 'box'; Caption = 'Install engine components'; Id = 'Install'; Fallback = 'Cancel' }) $openConsent
        $d = $r.D
        $args0 = ''; if ($script:p42Launch.Count -gt 0) { $args0 = (@($script:p42Launch[0].Arguments) -join ' ') }
        Check ([string]$d['p42']['States'] -ceq '2,False,False,True,False,True' -and [string]$d['actError'] -ceq '') 'P43 consent: Install is disabled until every box is ticked, and un-ticking one disables it again (2 boxes: none, one, both, one, both)' "states='$($d['p42']['States'])' expected='2,False,False,True,False,True' actError='$($d['actError'])' $(Get-SettingsRecDetail $d)"
        Check ($script:p42Launch.Count -eq 1 -and [string]$script:p42Launch[0].Step -ceq 'component install' -and $args0.Contains('-Install probe-engine') -and $args0.Contains('-AcceptLicense') -and (Test-SettingsRecClean $d)) 'P43 consent accept (every box ticked): the real caller launches the component install for the engine with -AcceptLicense' "launches=$($script:p42Launch.Count) step='$(if ($script:p42Launch.Count -gt 0) { $script:p42Launch[0].Step })' args='$args0' error='$($r.Err)' $(Get-SettingsRecDetail $d)"
        # ---- consent: Cancel (a click, with the boxes ticked) downloads nothing ----
        $r = Invoke-P43Run @(@{ Kind = 'act'; Caption = 'Install engine components'; Do = $ticks }, @{ Kind = 'box'; Caption = 'Install engine components'; Id = 'Cancel'; Fallback = 'Cancel' }) $openConsent
        Check ($script:p42Launch.Count -eq 0 -and [string]$script:statusLabel.Text -ceq 'Component install cancelled. Nothing was downloaded.' -and (Test-SettingsRecClean $r.D)) 'P43 consent Cancel (boxes ticked): nothing is launched and the status says nothing was downloaded' "launches=$($script:p42Launch.Count) status='$($script:statusLabel.Text)' $(Get-SettingsRecDetail $r.D)"
        # ---- licence setting: accept writes accept-automatically; Cancel (click) writes nothing ----
        # A toggle that is already on raises no change, so the page opens with the toggle (and the classic box behind it) put to off without the handler, then turned on.
        $openLicense = { $null = Open-SettingsPage @{}; $script:licenseRevert = $true; try { $els.SettingsLicenseToggle.IsChecked = $false; $script:licenseBox.Checked = $false } finally { $script:licenseRevert = $false }; $script:setLicWrites.Clear(); $els.SettingsLicenseToggle.IsChecked = $true }
        $r = Invoke-P43Run @(@{ Kind = 'box'; Caption = 'Install engine components automatically'; Id = 'Accept'; Fallback = 'Cancel' }) $openLicense
        Check (($script:setLicWrites.ToArray() -join ',') -ceq 'accept-automatically' -and $els.SettingsLicenseToggle.IsChecked -eq $true -and (Test-SettingsRecClean $r.D)) 'P43 licence setting Accept: the setting is written (accept-automatically) and the toggle stays on' "writes=$($script:setLicWrites.ToArray() -join ',') toggle=$($els.SettingsLicenseToggle.IsChecked) error='$($r.Err)' $(Get-SettingsRecDetail $r.D)"
        Close-SettingsPage
        $r = Invoke-P43Run @(@{ Kind = 'box'; Caption = 'Install engine components automatically'; Id = 'Cancel'; Fallback = 'Cancel' }) $openLicense
        Check ($script:setLicWrites.Count -eq 0 -and $els.SettingsLicenseToggle.IsChecked -eq $false -and (Test-SettingsRecClean $r.D)) 'P43 licence setting Cancel (click): nothing is written and the toggle is reverted' "writes=$($script:setLicWrites.ToArray() -join ',') toggle=$($els.SettingsLicenseToggle.IsChecked) $(Get-SettingsRecDetail $r.D)"
        Close-SettingsPage
        # ---- licence setting, a disclosure that cannot be accepted (canAccept false): Accept is disabled, and Enter and Escape both answer Cancel (false) ----
        $offDisclosure = [pscustomobject]@{ canAccept = $false; identities = @(); links = @($fx.Disclosure.links) }
        $accState = {
            param($w, $st)
            $accept = Find-WpfBoxButton $w 'Accept'
            $st['p42']['AcceptFound'] = ($null -ne $accept)
            if ($null -ne $accept) { $st['p42']['AcceptEnabled'] = [bool]$accept.IsEnabled }
        }
        foreach ($case in @(@('Enter', 0x0D), @('Escape', 0x1B))) {
            $script:p43Licence = 'unset'
            $r = Invoke-P43Run @(@{ Kind = 'act'; Caption = 'Install engine components automatically'; Do = $accState }, @{ Kind = 'box'; Caption = 'Install engine components automatically'; Key = [int]$case[1]; Fallback = 'Cancel' }) { $script:p43Licence = Show-FastLlmUiFluentLicenseSettingConfirm -Disclosure $offDisclosure }
            Check ([bool]$r.D['p42']['AcceptFound'] -and $r.D['p42']['AcceptEnabled'] -eq $false -and $script:p43Licence -is [bool] -and $script:p43Licence -eq $false -and -not [bool]$r.D['actFellBack'] -and (Test-SettingsRecClean $r.D)) "P43 licence setting with canAccept false: Accept is disabled and $($case[0]) answers Cancel (false)" "found=$($r.D['p42']['AcceptFound']) acceptEnabled=$($r.D['p42']['AcceptEnabled']) answer='$($script:p43Licence)' fellBack=$($r.D['actFellBack']) error='$($r.Err)' $(Get-SettingsRecDetail $r.D)"
        }
        # ---- setup check: each answer ----
        $script:flow = [pscustomobject]@{ phase = 'setup-attention' }
        $script:statusLabel.Text = ''
        foreach ($case in @(@('Recheck', 'move:setup-recheck,launch-phase', ''), @('Prepare', '', ''), @('Later', 'move:setup-defer', 'Setup deferred. No software was installed.'))) {
            $script:p43Log.Clear(); $script:p42Launch.Clear(); $script:statusLabel.Text = ''
            $decision = $fx.Decision; $diagnostic = $fx.Diagnostic
            $r = Invoke-P43Run @(@{ Kind = 'box'; Caption = 'FastLLM setup check'; Id = [string]$case[0]; Fallback = 'Later' }) { & $stmt['Setup'] $decision $diagnostic }
            $launch = ''; if ($script:p42Launch.Count -gt 0) { $launch = [string]$script:p42Launch[0].Step }
            $wantLaunch = ''; if ($case[0] -ceq 'Prepare') { $wantLaunch = 'vc prepare' }
            Check (($script:p43Log.ToArray() -join ',') -ceq [string]$case[1] -and $launch -ceq $wantLaunch -and [string]$script:statusLabel.Text -ceq [string]$case[2] -and (Test-SettingsRecClean $r.D)) "P43 setup check $($case[0]): the real consumer does today's step" "log='$($script:p43Log.ToArray() -join ',')' expected='$($case[1])' launch='$launch' expected='$wantLaunch' status='$($script:statusLabel.Text)' expected='$($case[2])' error='$($r.Err)' $(Get-SettingsRecDetail $r.D)"
        }
        # ---- VC++ review: install and do later ----
        foreach ($case in @(@('Install', 'broker', ''), @('Later', 'move:setup-defer', 'Microsoft VC++ download prepared; installation deferred.'))) {
            $script:p43Log.Clear(); $script:statusLabel.Text = ''
            $receipt = $fx.Receipt; $candidate = $fx.Candidate
            $r = Invoke-P43Run @(@{ Kind = 'box'; Caption = 'Review Microsoft VC++ package and installation'; Id = [string]$case[0]; Fallback = 'Later' }) { & $stmt['Vc'] $receipt $candidate }
            Check (($script:p43Log.ToArray() -join ',') -ceq [string]$case[1] -and [string]$script:statusLabel.Text -ceq [string]$case[2] -and (Test-SettingsRecClean $r.D)) "P43 VC++ review $($case[0]): the real consumer starts the broker only on Install, and defers otherwise" "log='$($script:p43Log.ToArray() -join ',')' expected='$($case[1])' status='$($script:statusLabel.Text)' expected='$($case[2])' error='$($r.Err)' $(Get-SettingsRecDetail $r.D)"
        }
        # ---- exact model consent: accept and cancel (the caret is at the start) ----
        $caret = { param($w, $st) $tb = @(Get-ShellVisuals $w | Where-Object { $_ -is [System.Windows.Controls.TextBox] -and [string]$_.Name -ceq 'ModelConsentText' })[0]; $st['p42']['Caret'] = "$($tb.SelectionStart),$($tb.SelectionLength)" }
        foreach ($case in @(@('Accept', 'move:consent-approved', ''), @('Cancel', 'move:consent-declined,busy:False', 'Model download declined. No new license receipt was created.'))) {
            $script:p43Log.Clear(); $script:statusLabel.Text = ''
            $script:flow = [pscustomobject]@{ phase = 'consent' }
            $plan = $fx.Plan
            $r = Invoke-P43Run @(@{ Kind = 'act'; Caption = 'Review exact model license and artifact'; Do = $caret }, @{ Kind = 'box'; Caption = 'Review exact model license and artifact'; Id = [string]$case[0]; Fallback = 'Cancel' }) { & $stmt['Model'] $plan }
            Check (($script:p43Log.ToArray() -join ',') -ceq [string]$case[1] -and [string]$script:statusLabel.Text -ceq [string]$case[2] -and [string]$r.D['p42']['Caret'] -ceq '0,0' -and (Test-SettingsRecClean $r.D)) "P43 model consent $($case[0]): the real consumer moves the flow as today, and the review text opens with the caret at the start" "log='$($script:p43Log.ToArray() -join ',')' expected='$($case[1])' status='$($script:statusLabel.Text)' caret='$($r.D['p42']['Caret'])' error='$($r.Err)' $(Get-SettingsRecDetail $r.D)"
        }
        # ---- a link that fails to open: the warning box is owned by the dialog, which is disabled while it is up ----
        $licenseLink = @($fx.Disclosure.links | Where-Object { $_.url })[0]
        $componentLink = @($fx.ConsentRows)[0].links[0]
        $linkCases = @(
            @{ Name = 'licence setting'; Title = 'Install engine components automatically'; Text = [string]$licenseLink.linkText; Body = 'Unable to open the license page. Check your default browser. Nothing was changed.'; Open = $openLicense; After = { Close-SettingsPage } },
            @{ Name = 'component consent'; Title = 'Install engine components'; Text = [string]$componentLink.linkText; Body = 'Unable to open the license page. Check your default browser. Nothing was downloaded.'; Open = $openConsent; After = { } }
        )
        foreach ($case in $linkCases) {
            $global:FastLlmTestStartProcess['Calls'] = 0
            $steps = @(@{ Kind = 'act'; Caption = [string]$case.Title; Do = (New-P43LinkClick ([string]$case.Text)) },
                @{ Kind = 'box'; Caption = 'Open license page'; Key = 0x0D; Fallback = 1 },
                @{ Kind = 'box'; Caption = [string]$case.Title; Key = 0x1B; Fallback = 'Cancel' })
            $r = Invoke-P43Run $steps $case.Open
            & $case.After
            $d = $r.D
            $warn = Get-SettingsRec $d 0
            $opStatus = 'none'; if ($null -ne $d['p42']['ClickOp']) { $opStatus = [string]$d['p42']['ClickOp'].Status }
            Check ([bool]$d['p42']['LinkFound'] -and [bool]$d['p42']['ClickRan'] -and $global:FastLlmTestStartProcess['Calls'] -ge 1) "P43 $($case.Name): the link was found and clicked, and Start-Process was reached (so the stub threw)" "linkFound=$($d['p42']['LinkFound']) clickRan=$($d['p42']['ClickRan']) clickDone=$($d['p42']['ClickDone']) op=$opStatus startProcessCalls=$($global:FastLlmTestStartProcess['Calls']) link='$($case.Text)' $(Get-SettingsRecDetail $d)"
            Check ([bool]$warn['Found'] -and [string]$warn['Caption'] -ceq 'Open license page' -and ([string]$warn['Text']).Contains([string]$case.Body)) "P43 $($case.Name): the warning box shows today's text" "text='$($warn['Text'])' expected to contain '$($case.Body)'"
            Check ([bool]$warn['Found'] -and [long]$warn['Owner'] -eq [long]$d['p42']['DialogHwnd'] -and [string]$warn['OwnerTitle'] -ceq [string]$case.Title -and -not [bool]$warn['OwnerWindowEnabled']) "P43 $($case.Name): the warning box is owned by the dialog (not the main window), and the dialog is disabled while it is open" "owner=$($warn['Owner']) dialog=$($d['p42']['DialogHwnd']) ownerTitle='$($warn['OwnerTitle'])' expected='$($case.Title)' ownerEnabled=$($warn['OwnerWindowEnabled'])"
            Check ((Test-SettingsRecClean $d) -and [string]$d['actError'] -ceq '') "P43 $($case.Name): the warning box and the dialog were answered by their keys, with nothing unexpected" "actError='$($d['actError'])' error='$($r.Err)' $(Get-SettingsRecDetail $d)"
        }
    }
    finally {
        $global:FastLlmTestStartProcess['Block'] = $false
        Remove-Variable -Name flow -Scope Script -ErrorAction SilentlyContinue
        $null = Set-FastLlmUiFluentPage -Id 'Home'
    }
    Write-Host ("INFO: P43 took " + $watch.ElapsedMilliseconds + ' ms')
    Check-NoExceptions 'P43'
}

$script:steps = @(
    # P0 enters the shell's message loop; every step after it runs inside that loop's frame
    'Invoke-P0-ShellStart',
    'Invoke-P1-PageHostAndNav', 'Invoke-P16-ActivityCopyHeader', 'Invoke-P2-ConnectAnApp', 'Invoke-P17-HomeSwitchAndChange', 'Invoke-P6-PageStatusLine', 'Invoke-P14-TrayRestore',
    'Invoke-P3-ToolsBindings', 'Invoke-P4-AttachFanOut', 'Invoke-P5-GreyedReasons',
    'Invoke-P7-ConnectContent', 'Invoke-P8-ConnectKey', 'Invoke-P9-ConnectCopies', 'Invoke-P10-ConnectApiCheck',
    'Invoke-P20-HomeToModels', 'Invoke-P21-TwoWay', 'Invoke-P22-RemoveFlows', 'Invoke-P23-Picker', 'Invoke-P24-Reasons', 'Invoke-P25-DisabledRows',
    'Invoke-P30-Save', 'Invoke-P31-Leave', 'Invoke-P32-Close', 'Invoke-P33-NewKey', 'Invoke-P34-Unavailable', 'Invoke-P35-Toggles', 'Invoke-P36-Pane', 'Invoke-P38-SettingsAdditions',
    'Invoke-P40-SignInNotice', 'Invoke-P41-DialogKeys', 'Invoke-P42-DialogKeys', 'Invoke-P43-DialogFlows',
    'Invoke-P11-TabWalk', 'Invoke-P12-ControlView', 'Invoke-P13-DialogOwners', 'Invoke-P15-RealTableOrder',
    # P-SLOT step names of the later tasks are added here, before P99
    'Invoke-P99-StartupFaults'
)

$tick = New-Object System.Windows.Threading.DispatcherTimer
$tick.Interval = [TimeSpan]::FromMilliseconds(50)
$script:tick = $tick
$deadline = New-Object System.Windows.Threading.DispatcherTimer
# 420 s: the Models steps (P20-P23) and the larger pages added since the 240 s figure took most of it on the slowest Windows CI runner.
# 600 s (PR 3c): the Settings steps P30-P36 drive about forty modal dialogs (the save prompt, the message boxes, the confirmations), each found by a 50 ms timer, and
# the box ladder waits a full second per rung when a first answer does not land, so the suite needs room for them on the same slowest runner.
$deadline.Interval = [TimeSpan]::FromSeconds(600)
$script:deadline = $deadline

$tick.Add_Tick({
    if ($script:busy -or $script:loopStopped) { return }
    $script:busy = $true
    try {
        if ($script:si -ge $script:steps.Count) { Stop-ShellLoop; return }
        $name = $script:steps[$script:si]
        $script:si++
        Write-Host "INFO: step $name started"
        $stepWatch = [System.Diagnostics.Stopwatch]::StartNew()
        try { $null = & $name }
        catch { $script:fail++; Write-Host "FAIL: step $name threw -- $($_.Exception.ToString())" }
        Write-Host ("INFO: step $name took " + $stepWatch.ElapsedMilliseconds + " ms")
        if ($script:si -ge $script:steps.Count) { Stop-ShellLoop }
    }
    finally { $script:busy = $false }
})
$deadline.Add_Tick({
    $script:deadline.Stop()
    $where = if ($script:si -gt 0 -and $script:si -le $script:steps.Count) { $script:steps[$script:si - 1] } else { 'before the first step' }
    Write-Host "FAIL: the 600 s suite deadline was hit during step $where"
    # a step may be stuck in a modal loop: ending the process is the only way out and it must not hang CI
    [Environment]::Exit(1)
})

$script:dispHandler = [System.Windows.Threading.DispatcherUnhandledExceptionEventHandler] { param($s, $e) $script:dispEx.Add($e.Exception.ToString()); $e.Handled = $true }
[System.Windows.Threading.Dispatcher]::CurrentDispatcher.add_UnhandledException($script:dispHandler)
try {
    $tick.Start()
    $deadline.Start()
    [System.Windows.Threading.Dispatcher]::Run()
}
finally { Stop-ShellLoop }

# Results are printed BEFORE cleanup; cleanup is by index and warn-only.
if ($script:fail -eq 0) { Write-Host "$($script:pass) checks passed" } else { Write-Host "$($script:fail) checks FAILED, $($script:pass) passed" }

try {
    for ($i = 0; $i -lt $script:scns.Count; $i++) {
        try { Unregister-FastLlmUiWindowHooks -Window $script:scns[$i].Window } catch { Write-Host "WARN: cleanup: $($_.Exception.Message)" }
        try { $script:scns[$i].Form.FastLlmFormState.FormClosing.Clear() } catch { Write-Host "WARN: cleanup: $($_.Exception.Message)" }
        try { $script:scns[$i].Window.Close() } catch { Write-Host "WARN: cleanup: $($_.Exception.Message)" }
    }
    for ($i = 0; $i -lt $script:objs.Count; $i++) {
        try { $script:objs[$i].Dispose() } catch { Write-Host "WARN: cleanup: $($_.Exception.Message)" }
    }
    try { Clear-FastLlmUiFluentTrayIcon } catch { Write-Host "WARN: cleanup: $($_.Exception.Message)" }
}
catch { Write-Host "WARN: cleanup: $($_.Exception.Message)" }

if ($script:fail -gt 0) { exit 1 }
exit 0
