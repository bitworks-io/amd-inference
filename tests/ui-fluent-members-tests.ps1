#requires -Version 5.1
# Member coverage for the Fluent window: every member the window script uses on an adapter-bound control name AFTER the rebinding seam
# must exist on that control's adapter kind (Get-FastLlmUiAdapterMemberTable), used the way the adapter allows (read, write or call).
# The scan covers everything after the seam AND every function body anywhere in the file (a function defined before the seam is called after it).
# Only top-level statements before the seam are classic-only and are not scanned.
# Pure: the window script is parsed, never run. Also checks the carried UpdateActive rule (every update run records its kind), that $form is
# only ever used as an owner or a member target (so the adapter never has to be a real Control), that -Window is case-sensitive, and that
# the classic window is unchanged apart from the named changes (a pinned hash, see "Classic window" below).
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/FastLlm.UiFluentAdapter.ps1')
. (Join-Path $root 'src/FastLlm.UiFluentBindings.ps1')
$checks=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:checks++}

# What the form adapter (src/FastLlm.UiFluentForm.ps1) offers: Text, WindowState and the stored-only members can be set; the rest is read or called.
$formSpec=@{
    Get=@('Text','Visible','Font','WindowState','Controls','Size','MinimumSize','StartPosition','BackColor','Handle')
    Set=@('Text','Font','WindowState','Size','MinimumSize','StartPosition','BackColor')
    Invoke=@('Hide','Show','Activate','Close','Dispose','BeginInvoke','Add_Shown','Add_FormClosing')
}
$table=Get-FastLlmUiAdapterMemberTable
$kinds=@{form='Form'}
foreach($row in (Get-FastLlmUiFluentControlTable)){$kinds[[string]$row[0]]=[string]$row[1]}

function Get-MemberUses([System.Management.Automation.Language.Ast]$Tree,[int]$AfterLine){
    $uses=New-Object System.Collections.ArrayList
    $nodes=$Tree.FindAll({param($n) $n -is [System.Management.Automation.Language.MemberExpressionAst] -and -not $n.Static -and $n.Expression -is [System.Management.Automation.Language.VariableExpressionAst]},$true)
    foreach($n in $nodes){
        $owner=$n.Parent
        while($null -ne $owner -and $owner -isnot [System.Management.Automation.Language.FunctionDefinitionAst]){$owner=$owner.Parent}
        # Top-level statements before the seam are classic-only; a function body is scanned wherever it is defined.
        if($n.Extent.StartLineNumber -le $AfterLine -and $null -eq $owner){continue}
        $name=([string]$n.Expression.VariablePath.UserPath) -replace '^script:',''
        if(-not $kinds.ContainsKey($name)){continue}
        # A function that assigns its own variable of the same name, or takes it as a parameter (a dialog's local $title), is not using the window's control.
        if($null -ne $owner){
            $shadow=@($owner.FindAll({param($a) $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and $a.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and ([string]$a.Left.VariablePath.UserPath) -ceq $name},$true))
            $params=@(); if($null -ne $owner.Parameters){$params=@($owner.Parameters)}elseif($null -ne $owner.Body.ParamBlock){$params=@($owner.Body.ParamBlock.Parameters)}
            $shadowParam=@($params|Where-Object{([string]$_.Name.VariablePath.UserPath) -ceq $name})
            if($shadow.Count -gt 0 -or $shadowParam.Count -gt 0){continue}
        }
        $member=if($n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]){[string]$n.Member.Value}else{'<dynamic>'}
        $ops=@()
        if($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst]){$ops=@('invoke')}
        else{
            $p=$n.Parent
            if($p -is [System.Management.Automation.Language.AssignmentStatementAst] -and [object]::ReferenceEquals($p.Left,$n)){
                $ops=if([string]$p.Operator -ceq 'Equals'){@('set')}else{@('set','get')}
            }
            elseif($p -is [System.Management.Automation.Language.UnaryExpressionAst] -and [string]$p.TokenKind -match 'PlusPlus|MinusMinus'){$ops=@('set','get')}
            else{$ops=@('get')}
        }
        foreach($op in $ops){[void]$uses.Add([pscustomobject]@{Name=$name;Kind=$kinds[$name];Member=$member;Op=$op;Line=$n.Extent.StartLineNumber})}
    }
    return ,$uses.ToArray()
}

function Get-UseProblem($Use){
    if($Use.Member -ceq '<dynamic>'){return 'dynamic member name'}
    if($Use.Kind -ceq 'Form'){
        $ok=switch($Use.Op){'get'{$formSpec.Get -ccontains $Use.Member}'set'{$formSpec.Set -ccontains $Use.Member}'invoke'{$formSpec.Invoke -ccontains $Use.Member}}
        if($ok){return $null}else{return "form adapter has no member usable for $($Use.Op): $($Use.Member)"}
    }
    $spec=$table[$Use.Kind]
    $events=@($spec.Events|ForEach-Object{'Add_'+$_})
    $ok=switch($Use.Op){
        'set'{($spec.Values -ccontains $Use.Member) -or ($spec.Layout -ccontains $Use.Member)}
        'get'{($spec.Values -ccontains $Use.Member) -or ($spec.ReadOnly -ccontains $Use.Member) -or ($spec.Layout -ccontains $Use.Member)}
        'invoke'{($spec.Methods -ccontains $Use.Member) -or ($events -ccontains $Use.Member)}
    }
    if($ok){return $null}
    return "$($Use.Kind) adapter has no member usable for $($Use.Op): $($Use.Member)"
}

function Get-Findings([System.Management.Automation.Language.Ast]$Tree,[int]$AfterLine){
    $found=New-Object System.Collections.ArrayList
    foreach($u in (Get-MemberUses -Tree $Tree -AfterLine $AfterLine)){
        $p=Get-UseProblem $u
        if($p){[void]$found.Add("line $($u.Line) `$$($u.Name): $p")}
    }
    return ,$found.ToArray()
}

# The real script, from the seam on.
$path=Join-Path $root 'fast-llm-ui.ps1'
$errors=$null
$tree=[System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$null,[ref]$errors)
Check ($errors.Count -eq 0) 'fast-llm-ui.ps1 parses'
# The seam is the one top-level statement that calls Initialize-FastLlmUiFluentShell, whether or not a guard wraps it (5b removes the guard).
function Get-TopLevelCalls($Ast,[string]$Name){
    $calls=@($Ast.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -ceq $Name},$true)|Where-Object{
        $fnOwner=$_.Parent; while($null -ne $fnOwner -and $fnOwner -isnot [System.Management.Automation.Language.FunctionDefinitionAst]){$fnOwner=$fnOwner.Parent}
        $null -eq $fnOwner})
    return ,$calls
}
$seamCalls=Get-TopLevelCalls $tree 'Initialize-FastLlmUiFluentShell'
Check ($seamCalls.Count -eq 1) 'the rebinding seam statement (the one top-level call of Initialize-FastLlmUiFluentShell) appears exactly once'
# Self-check: the finder takes the call guarded or bare, and never one inside a function body.
$seamSynGuard=[System.Management.Automation.Language.Parser]::ParseInput("if (`$Window -ceq 'fluent') { Initialize-FastLlmUiFluentShell }`nfunction F { Initialize-FastLlmUiFluentShell }",[ref]$null,[ref]$null)
$seamSynBare=[System.Management.Automation.Language.Parser]::ParseInput("`$a=1`nInitialize-FastLlmUiFluentShell`nfunction F { Initialize-FastLlmUiFluentShell }",[ref]$null,[ref]$null)
$seamSynTwo=[System.Management.Automation.Language.Parser]::ParseInput("Initialize-FastLlmUiFluentShell`nInitialize-FastLlmUiFluentShell",[ref]$null,[ref]$null)
$seamSynNone=[System.Management.Automation.Language.Parser]::ParseInput('function F { Initialize-FastLlmUiFluentShell }',[ref]$null,[ref]$null)
$seamSynGuardCalls=Get-TopLevelCalls $seamSynGuard 'Initialize-FastLlmUiFluentShell'
$seamSynBareCalls=Get-TopLevelCalls $seamSynBare 'Initialize-FastLlmUiFluentShell'
$seamSynTwoCalls=Get-TopLevelCalls $seamSynTwo 'Initialize-FastLlmUiFluentShell'
$seamSynNoneCalls=Get-TopLevelCalls $seamSynNone 'Initialize-FastLlmUiFluentShell'
Check ($seamSynGuardCalls.Count -eq 1 -and $seamSynBareCalls.Count -eq 1 -and $seamSynBareCalls[0].Extent.StartLineNumber -eq 2) 'self-check: the seam finder takes a guarded or a bare top-level call and skips the one in a function'
Check ($seamSynTwoCalls.Count -eq 2 -and $seamSynNoneCalls.Count -eq 0) 'self-check: the seam finder counts two top-level calls as two and a call only inside a function as none'
$seam=[int]$seamCalls[0].Extent.StartLineNumber
# 5b-delete-begin
$seamText="if (`$Window -ceq 'fluent') { Initialize-FastLlmUiFluentShell }"
$seamLines=@()
$lineNo=0
foreach($l in (Get-Content -LiteralPath $path)){$lineNo++;if($l -ceq $seamText){$seamLines+=$lineNo}}
Check ($seamLines.Count -eq 1 -and [int]$seamLines[0] -eq $seam) 'the rebinding seam line appears exactly once, guarded by the -Window switch'
# 5b-delete-end

# Every control the inventory names is bound to a kind the table knows.
foreach($k in $kinds.Keys){Check (($k -ieq 'form') -or $table.Contains($kinds[$k])) "control $k has a known adapter kind"}
$uses=Get-MemberUses -Tree $tree -AfterLine $seam
Check ($uses.Count -gt 100) "the scan sees the orchestration's member uses ($($uses.Count))"
foreach($need in 'statusLabel','output','modelBox','installButton','bannerLabel','form','failureCopyLink','licenseBox'){
    Check (@($uses|Where-Object{$_.Name -ceq $need}).Count -gt 0) "the scan found uses of $need after the seam"
}
# The kinds of access are told apart.
Check (@($uses|Where-Object{$_.Name -ceq 'statusLabel' -and $_.Member -ceq 'Text' -and $_.Op -ceq 'set'}).Count -gt 0) 'a write is classified as set'
Check (@($uses|Where-Object{$_.Name -ceq 'statusLabel' -and $_.Member -ceq 'Text' -and $_.Op -ceq 'get'}).Count -gt 0) 'a read is classified as get'
Check (@($uses|Where-Object{$_.Name -ceq 'output' -and $_.Member -ceq 'AppendText' -and $_.Op -ceq 'invoke'}).Count -gt 0) 'a call is classified as invoke'
# Functions defined BEFORE the seam but called after it are scanned too.
foreach($fn in 'GetBarValue','ClearFailureCapture','SetFailureCapture','ClearPreviousRunNotes'){
    $def=$tree.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $fn},$true)
    Check ($null -ne $def -and $def.Extent.StartLineNumber -lt $seam) "$fn is defined before the seam"
    Check (@($uses|Where-Object{$_.Line -ge $def.Extent.StartLineNumber -and $_.Line -le $def.Extent.EndLineNumber}).Count -gt 0) "the scan covers the body of $fn (defined before the seam)"
}

$findings=Get-Findings -Tree $tree -AfterLine $seam
foreach($f in $findings){Write-Host "FINDING: $f"}
Check ($findings.Count -eq 0) "every member used after the seam exists on its adapter ($($findings.Count) finding(s))"

# Self-check: unknown members and wrong-way use are reported (a synthetic source).
$synthetic=@'
$statusLabel.Bogus='x'
$output.Nope()
$statusLabel.Text='ok'
$output.AppendText('ok')
$modelBox.Items.Add('ok')
$bannerLabel.Right
$modelBox.Items='x'
$form.Show()
'@
$synTree=[System.Management.Automation.Language.Parser]::ParseInput($synthetic,[ref]$null,[ref]$errors)
$synFindings=Get-Findings -Tree $synTree -AfterLine 0
Check ($synFindings.Count -eq 3) "the self-check flags exactly the bogus set, the bogus call and the write to a read-only member (got $($synFindings.Count))"
Check (@($synFindings|Where-Object{$_ -match 'statusLabel.*Bogus'}).Count -eq 1) 'self-check: statusLabel.Bogus is flagged'
Check (@($synFindings|Where-Object{$_ -match 'output.*Nope'}).Count -eq 1) 'self-check: output.Nope() is flagged'
Check (@($synFindings|Where-Object{$_ -match 'modelBox.*Items'}).Count -eq 1) 'self-check: writing the read-only Items is flagged'
$pre=Get-Findings -Tree $synTree -AfterLine 100
Check ($pre.Count -eq 0) 'self-check: top-level uses before the seam are not scanned'
$fnSource='function Early { $statusLabel.Bogus=''x'' }'+"`n"+'$output.Nope()'
$fnTree=[System.Management.Automation.Language.Parser]::ParseInput($fnSource,[ref]$null,[ref]$errors)
$fnFindings=Get-Findings -Tree $fnTree -AfterLine 100
Check ($fnFindings.Count -eq 1 -and $fnFindings[0] -match 'statusLabel.*Bogus') 'self-check: a function defined on line 1 is scanned (AfterLine 100) and its bogus member is flagged'

# Carried UpdateActive check: every update run records its kind, and only 'update' or 'reinstall'.
$runs=@($tree.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and ([string]$n.Left.VariablePath.UserPath) -ceq 'script:updateRun' -and $n.Right.Extent.Text -match '^\[pscustomobject\]@\{'},$true))
Check ($runs.Count -ge 2) "the script starts update runs ($($runs.Count))"
foreach($r in $runs){
    $hash=$r.Right.Find({param($n) $n -is [System.Management.Automation.Language.HashtableAst]},$true)
    $kv=@($hash.KeyValuePairs|Where-Object{[string]$_.Item1.Extent.Text -ceq 'kind'})
    Check ($kv.Count -eq 1) "update run at line $($r.Extent.StartLineNumber) sets kind once"
    $val=[string]$kv[0].Item2.Extent.Text
    Check ($val -ceq "'update'" -or $val -ceq "'reinstall'") "update run at line $($r.Extent.StartLineNumber) sets kind to update or reinstall (got $val)"
}

# $form is a member target or an owner, never a bare value: the adapter is not a real Control. An owner position is the first argument of
# [Windows.Forms.MessageBox]::Show or the argument of .ShowDialog; NewUiApiKey passes its owner on, and is checked to use it only that way.
# Allowlist (exact text of the statement part): the two uses below.
$bareAllow=@{
# 5b-delete-begin
    # The classic startup branch (the fluent branch starts its own loop); pinned by ui-flow-tests.
    '[Windows.Forms.Application]::Run($form)'='classic-only startup, never reached with -Window fluent'
# 5b-delete-end
}
function Get-OwnerKind($Node){
    $p=$Node.Parent
    if($p -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $null -ne $p.Arguments -and @($p.Arguments).Count -gt 0){
        $member=if($p.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]){[string]$p.Member.Value}else{''}
        if($member -ceq 'ShowDialog' -and @($p.Arguments|Where-Object{[object]::ReferenceEquals($_,$Node)}).Count -eq 1){return 'ShowDialog'}
        if($p.Static -and $member -ceq 'Show' -and $p.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and
           [string]$p.Expression.TypeName.Name -cmatch '^(System\.)?Windows\.Forms\.MessageBox$' -and [object]::ReferenceEquals(@($p.Arguments)[0],$Node)){return 'MessageBox.Show'}
    }
    if($p -is [System.Management.Automation.Language.CommandAst] -and [string]$p.GetCommandName() -ceq 'NewUiApiKey'){return 'NewUiApiKey'}
    # The seam's box call (ShowUiMessageBox <owner> ...): the owner is the first argument and is only handed on to MessageBox.Show or the fluent box host.
    if($p -is [System.Management.Automation.Language.CommandAst] -and [string]$p.GetCommandName() -ceq 'ShowUiMessageBox' -and $p.CommandElements.Count -ge 2 -and [object]::ReferenceEquals($p.CommandElements[1],$Node)){return 'ShowUiMessageBox'}
    return $null
}
function Get-FormBareUses([System.Management.Automation.Language.Ast]$Tree,[int]$AfterLine){
    $result=New-Object System.Collections.ArrayList
    $vars=$Tree.FindAll({param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and (([string]$n.VariablePath.UserPath) -replace '^script:','') -ieq 'form'},$true)
    foreach($v in $vars){
        $fn=$v.Parent
        while($null -ne $fn -and $fn -isnot [System.Management.Automation.Language.FunctionDefinitionAst]){$fn=$fn.Parent}
        if($v.Extent.StartLineNumber -le $AfterLine -and $null -eq $fn){continue}
        $p=$v.Parent
        if($p -is [System.Management.Automation.Language.MemberExpressionAst] -and [object]::ReferenceEquals($p.Expression,$v) -and $p -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst]){continue}
        if($p -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [object]::ReferenceEquals($p.Expression,$v)){continue}
        if($p -is [System.Management.Automation.Language.AssignmentStatementAst] -and [object]::ReferenceEquals($p.Left,$v)){continue}
        $kind=Get-OwnerKind $v
        $text=[string]$p.Extent.Text
        if($null -ne $kind){$cls=$kind}
        elseif($bareAllow.ContainsKey($text)){$cls='allowed'}
        else{$cls='finding'}
        [void]$result.Add([pscustomobject]@{Kind=$cls;Line=$v.Extent.StartLineNumber;Text=$text})
    }
    return ,$result.ToArray()
}
$formUses=Get-FormBareUses -Tree $tree -AfterLine $seam
foreach($u in @($formUses|Where-Object{$_.Kind -ceq 'finding'})){Write-Host "FINDING: line $($u.Line) `$form used as a bare value: $($u.Text)"}
Check (@($formUses|Where-Object{$_.Kind -ceq 'finding'}).Count -eq 0) '$form is only used as an owner or a member target (no bare use that needs a real Control)'
$ownerCounts=@{}; foreach($u in $formUses){if(-not $ownerCounts.ContainsKey($u.Kind)){$ownerCounts[$u.Kind]=0};$ownerCounts[$u.Kind]++}
Write-Host ('$form owner and allowlisted uses by kind: '+(($ownerCounts.Keys|Sort-Object|ForEach-Object{"$_=$($ownerCounts[$_])"}) -join ', '))
Check ($ownerCounts['ShowDialog'] -gt 0 -and $ownerCounts['ShowUiMessageBox'] -gt 0) 'the scan sees ShowDialog and ShowUiMessageBox owner uses'
# 5b-delete-begin
Check ($ownerCounts['ShowDialog'] -gt 0 -and $ownerCounts['MessageBox.Show'] -gt 0) 'the scan sees ShowDialog and MessageBox owner uses'
foreach($allowKey in $bareAllow.Keys){
    $allowHits=@($formUses|Where-Object{$_.Kind -ceq 'allowed' -and $_.Text -ceq $allowKey}).Count
    Check ($allowHits -eq 1) "allowlisted bare use appears exactly once (no dead entry): $allowKey (found $allowHits)"
}
Check (@($formUses|Where-Object{$_.Kind -ceq 'allowed'}).Count -eq $bareAllow.Count) 'every allowlisted bare use is accounted for'
# 5b-delete-end
# NewUiApiKey takes the owner as a parameter and may only pass it on as a MessageBox owner.
$keyFn=$tree.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'NewUiApiKey'},$true)
Check ($null -ne $keyFn) 'NewUiApiKey is defined'
$ownerVars=@($keyFn.Body.FindAll({param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and ([string]$n.VariablePath.UserPath) -ieq 'Owner'},$true))
Check ($ownerVars.Count -ge 2 -and @($ownerVars|Where-Object{(Get-OwnerKind $_) -cin 'MessageBox.Show','ShowUiMessageBox'}).Count -eq $ownerVars.Count) 'NewUiApiKey uses its Owner only as a MessageBox owner'
# Self-check.
$bareSyn=@'
Foo $form
$x.Bar($form)
[Windows.Forms.MessageBox]::Show($form,'ok')
[Windows.Forms.MessageBox]::Show('ok',$form)
$d.ShowDialog($form)
$form.Show()
'@
$bareTree=[System.Management.Automation.Language.Parser]::ParseInput($bareSyn,[ref]$null,[ref]$errors)
$bareAll=Get-FormBareUses -Tree $bareTree -AfterLine 0
$bareFound=@($bareAll|Where-Object{$_.Kind -ceq 'finding'})
Check ($bareFound.Count -eq 3 -and @($bareFound|Where-Object{$_.Text -ceq 'Foo $form'}).Count -eq 1) 'self-check: Foo $form, a method argument and a second MessageBox argument are flagged; owner uses and member use are not'

# 5b-delete-begin
# -Window is case-sensitive: -Window Fluent is refused instead of silently running the classic window.
$windowParam=@($tree.ParamBlock.Parameters|Where-Object{([string]$_.Name.VariablePath.UserPath) -ceq 'Window'})
Check ($windowParam.Count -eq 1) 'the window script has a -Window parameter'
$vs=@($windowParam[0].Attributes|Where-Object{$_ -is [System.Management.Automation.Language.AttributeAst] -and [string]$_.TypeName.Name -ceq 'ValidateSet'})
Check ($vs.Count -eq 1) '-Window has a ValidateSet'
Check (@($vs[0].PositionalArguments|ForEach-Object{[string]$_.Value}) -join ',' -ceq 'classic,fluent') '-Window accepts classic and fluent'
Check (@($vs[0].NamedArguments|Where-Object{[string]$_.ArgumentName -ceq 'IgnoreCase' -and [string]$_.Argument.Extent.Text -ceq '$false'}).Count -eq 1) '-Window ValidateSet has IgnoreCase=$false (-Window Fluent is refused)'
# 5b-delete-end

function Get-NormalizedText([string]$Path){
    $bytes=[IO.File]::ReadAllBytes($Path)
    $start=0; if($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF){$start=3}
    return ([Text.Encoding]::UTF8.GetString($bytes,$start,$bytes.Length-$start)).Replace("`r`n","`n")
}
# 5b-delete-begin
# Classic window: unchanged apart from the named changes. Undo each named change by an exact (current, original) pair; each must match
# exactly once; the result must hash to the window script at the point this branch left main (the same text, BOM stripped, CRLF as LF).
# PR 3 and PR 4 add their pairs here BY NAME; the flip PR, which drops the classic window, deletes this check.
$classicPinnedSha256='343acd14d0bdacdb3b44a67497ad0673de7a6f64e39ca105791015662f7083aa'
$namedChanges=@(
    @{Name='param'
      Cur=@'
param([string]$InstallRoot,[ValidateSet('classic','fluent',IgnoreCase=$false)][string]$Window='classic')

'@
      Orig=@'
param([string]$InstallRoot)

'@}
    @{Name='support check'
      Cur=@'
# The Fluent window (opt-in with -Window fluent) is checked before anything else is built; an unsupported PC opens no window.
if ($Window -ceq 'fluent') { . (Join-Path $PSScriptRoot 'src/FastLlm.UiFluentShell.ps1'); $fluentSupport=Test-FastLlmUiFluentHost; if (-not $fluentSupport.supported) { Show-FastLlmUiUnsupported -Reason $fluentSupport.reason -InstallRoot $InstallRoot -Folder $PSScriptRoot; exit 3 } }

'@
      Orig=''}
    @{Name='failureHeld start'
      Cur=@'
$script:failureCapture=$null
$script:failureHeld=$false;$script:failureViewText=''

'@
      Orig=@'
$script:failureCapture=$null

'@}
    @{Name='ClearFailureCapture clear'
      Cur=@'
function ClearFailureCapture {$script:failureCapture=$null;$script:failureHeld=$false;$script:failureViewText='';$failureCopyLink.Visible=$false}
'@
      Orig=@'
function ClearFailureCapture {$script:failureCapture=$null;$failureCopyLink.Visible=$false}
'@}
    @{Name='seam'
      Cur=@'
if ($Window -ceq 'fluent') { Initialize-FastLlmUiFluentShell }

'@
      Orig=''}
    @{Name='snapshot arguments'
      Cur=@'
 -Background $script:bgState `
        -FailureHeld ([bool]$script:failureHeld) -FlowPhase ([string]$(if($script:flow){$script:flow.phase}))

'@
      Orig=@'
 -Background $script:bgState

'@}
    @{Name='ShowFailure set'
      Cur=@'
    $script:failureHeld=$true

'@
      Orig=''}
    @{Name='ShowFailure view text'
      Cur=@'
    $script:failureViewText=[string]$view.text

'@
      Orig=''}
    @{Name='GetUiTrayIcon'
      Cur=@'
# The tray icon: the stock application icon, or the drawn one in the Fluent window.
function GetUiTrayIcon { if ($script:Window -ceq 'fluent') { return Get-FastLlmUiFluentTrayIcon } ; return [Drawing.SystemIcons]::Application }

'@
      Orig=''}
    @{Name='tray assignment'
      Cur=@'
$script:trayIcon.Icon=GetUiTrayIcon
'@
      Orig=@'
$script:trayIcon.Icon=[Drawing.SystemIcons]::Application
'@}
    @{Name='startup branch'
      Cur=@'
try{if($Window -ceq 'fluent'){Start-FastLlmUiFluentLoop}else{[Windows.Forms.Application]::EnableVisualStyles();[Windows.Forms.Application]::Run($form)}}finally{
'@
      Orig=@'
try{[Windows.Forms.Application]::EnableVisualStyles();[Windows.Forms.Application]::Run($form)}finally{
'@}
    @{Name='key box copy guard'
      Cur=@'
        # Ctrl+C, Ctrl+Insert and the box's own menu would copy the shown key as plain text, with no clipboard-history or cloud-sync exclusion; the
        # guard turns them off and sends every copy of the box through the same call as the Copy button.
        Register-FastLlmUiKeyBoxCopyGuard -TextBox $keyBox -Copy {
            [void](Invoke-FastLlmUiKeyCopy -KeyOnly -ReadKey {ReadUiApiKey} -SetClipboard {param($Payload) SetUiClipboardPayload $Payload} -SetStatus {param($Text) $statusLabel.Text=[string]$Text})
        }

'@
      Orig=''}
    @{Name='self-test measurement note'
      Cur='if($s.PSObject.Properties[''selfTest''] -and $s.selfTest){$lines+=Format-FastLlmUiSelfTest -SelfTest $s.selfTest -MeasurementNote $(if($s.PSObject.Properties[''measurementNote'']){[string]$s.measurementNote}else{''''});$script:servingNotesDone=$true}'
      Orig='if($s.PSObject.Properties[''selfTest''] -and $s.selfTest){$lines+=Format-FastLlmUiSelfTest -SelfTest $s.selfTest;$script:servingNotesDone=$true}'}
    @{Name='model picker ids'
      Cur='foreach($pickerId in @(Get-FastLlmUiPickerModelIds -Catalog $catalog)) { $modelBox.Items.Add($pickerId)|Out-Null }'
      Orig='foreach($model in $catalog.models) { if(-not $model.PSObject.Properties[''autoEligible''] -or $model.autoEligible){$modelBox.Items.Add([string]$model.id)|Out-Null} }'}
    @{Name='models list refresh'
      Cur=@'
function FillModelsPanel {
    $view=$script:modelsView
    # The Fluent window's Models page rebuilds its own list: its view names the function (the classic view has no refresh key).
    if($null -ne $view -and $view['refresh']){& $view['refresh'];return}
'@
      Orig=@'
function FillModelsPanel {
    $view=$script:modelsView
'@}
    @{Name='components list refresh'
      Cur=@'
function FillComponentsPanel {
    $view=$script:componentsView
    # The Fluent window's Models page rebuilds its own list: its view names the function (the classic view has no refresh key).
    if($null -ne $view -and $view['refresh']){& $view['refresh'];return}
'@
      Orig=@'
function FillComponentsPanel {
    $view=$script:componentsView
'@}
    @{Name='settings height call site'
      Cur='FitUiSettingsDialog $dialog (GetUiSettingsDialogMaxHeight $form.Handle)'
      Orig='FitUiSettingsDialog $dialog (GetUiSettingsDialogMaxHeight $form)'}
    @{Name='settings height body'
      Cur=@'
function GetUiSettingsDialogMaxHeight($OwnerHandle){
    return [int][Windows.Forms.Screen]::FromHandle($OwnerHandle).WorkingArea.Height
'@
      Orig=@'
function GetUiSettingsDialogMaxHeight($Owner){
    return [int][Windows.Forms.Screen]::FromControl($Owner).WorkingArea.Height
'@}
    @{Name='dialog view init'
      Cur=@'
$script:uiDialogView=$null

'@
      Orig=''}
    @{Name='ShowUiMessageBox'
      Cur=@'
function ShowUiMessageBox($Owner,[string]$Text,[string]$Caption,[string]$Buttons='OK',[string]$Icon='None',[string]$DefaultButton='Button1'){
    if($null -ne $script:uiDialogView){return & $script:uiDialogView['MessageBox'] -Owner $Owner -Text $Text -Caption $Caption -Buttons $Buttons -Icon $Icon -DefaultButton $DefaultButton}
    return [Windows.Forms.MessageBox]::Show($Owner,$Text,$Caption,$Buttons,$Icon,$DefaultButton)
}
function SetUiBanner([string]$Text,
'@
      Orig=@'
function SetUiBanner([string]$Text,
'@}
    @{Name='box vc link'
      Cur=@'
$vc.Add_LinkClicked({try{Start-Process 'https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist'}catch{$null=ShowUiMessageBox $form 'Unable to open Microsoft''s prerequisite page. Check your default browser. No software was installed.' 'Open prerequisite page' 'OK' 'Warning'}})
'@
      Orig=@'
$vc.Add_LinkClicked({try{Start-Process 'https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist'}catch{[void][Windows.Forms.MessageBox]::Show($form,'Unable to open Microsoft''s prerequisite page. Check your default browser. No software was installed.','Open prerequisite page','OK','Warning')}})
'@}
    @{Name='box amd link'
      Cur=@'
$amd.Add_LinkClicked({try{Start-Process 'https://www.amd.com/en/support/download/drivers.html'}catch{$null=ShowUiMessageBox $form 'Unable to open AMD''s driver page. Check your default browser. No driver changes were made.' 'Open AMD page' 'OK' 'Warning'}})
'@
      Orig=@'
$amd.Add_LinkClicked({try{Start-Process 'https://www.amd.com/en/support/download/drivers.html'}catch{[void][Windows.Forms.MessageBox]::Show($form,'Unable to open AMD''s driver page. Check your default browser. No driver changes were made.','Open AMD page','OK','Warning')}})
'@}
    @{Name='box results link'
      Cur=@'
    }catch{$null=ShowUiMessageBox $form 'Unable to open the results page. Check your default browser.' 'Open results page' 'OK' 'Warning'}
'@
      Orig=@'
    }catch{[void][Windows.Forms.MessageBox]::Show($form,'Unable to open the results page. Check your default browser.','Open results page','OK','Warning')}
'@}
    @{Name='box bar link'
      Cur=@'
$barLink.Add_LinkClicked({try{Start-Process 'https://github.com/bitworks-io/amd-inference/blob/main/docs/RESIZABLE-BAR.md'}catch{$null=ShowUiMessageBox $form 'Unable to open the Resizable BAR page. Check your default browser.' 'Open Resizable BAR page' 'OK' 'Warning'}})
'@
      Orig=@'
$barLink.Add_LinkClicked({try{Start-Process 'https://github.com/bitworks-io/amd-inference/blob/main/docs/RESIZABLE-BAR.md'}catch{[void][Windows.Forms.MessageBox]::Show($form,'Unable to open the Resizable BAR page. Check your default browser.','Open Resizable BAR page','OK','Warning')}})
'@}
    @{Name='box release link'
      Cur=@'
    }catch{$null=ShowUiMessageBox $form 'Unable to open the release page. Check your default browser.' 'Open release page' 'OK' 'Warning'}
'@
      Orig=@'
    }catch{[void][Windows.Forms.MessageBox]::Show($form,'Unable to open the release page. Check your default browser.','Open release page','OK','Warning')}
'@}
    @{Name='box experimental'
      Cur=@'
            $answer=ShowUiMessageBox $form $script:FastLlmExperimentalParagraph 'Experimental community components' 'YesNo' 'Warning' 'Button2'
'@
      Orig=@'
            $answer=[Windows.Forms.MessageBox]::Show($form,$script:FastLlmExperimentalParagraph,'Experimental community components','YesNo','Warning','Button2')
'@}
    @{Name='box license link 1'
      Cur=@'
                }catch{$null=ShowUiMessageBox $form 'Unable to open the license page. Check your default browser. Nothing was changed.' 'Open license page' 'OK' 'Warning'}
'@
      Orig=@'
                }catch{[void][Windows.Forms.MessageBox]::Show($form,'Unable to open the license page. Check your default browser. Nothing was changed.','Open license page','OK','Warning')}
'@}
    @{Name='box new key ask'
      Cur=@'
    if((ShowUiMessageBox $Owner $question 'Create a new key' 'YesNo' 'Question') -ne [Windows.Forms.DialogResult]::Yes){return $false}
'@
      Orig=@'
    if([Windows.Forms.MessageBox]::Show($Owner,$question,'Create a new key','YesNo','Question') -ne [Windows.Forms.DialogResult]::Yes){return $false}
'@}
    @{Name='box new key shown'
      Cur=@'
    $null=ShowUiMessageBox $Owner ((@($change.lines) -join [Environment]::NewLine).Replace('Show it with: fast-llm.ps1 settings -ApiKey show','Show or copy it in Connect an app.')) 'Create a new key' 'OK' 'Information'
'@
      Orig=@'
    [void][Windows.Forms.MessageBox]::Show($Owner,(@($change.lines) -join [Environment]::NewLine).Replace('Show it with: fast-llm.ps1 settings -ApiKey show','Show or copy it in Connect an app.'),'Create a new key','OK','Information')
'@}
    @{Name='box remove component'
      Cur=@'
    $answer=ShowUiMessageBox $view.dialog "Remove the component '$ComponentId'? Its files are deleted from this PC. You can install it again later." 'Remove component' 'YesNo' 'Question' 'Button2'
'@
      Orig=@'
    $answer=[Windows.Forms.MessageBox]::Show($view.dialog,"Remove the component '$ComponentId'? Its files are deleted from this PC. You can install it again later.",'Remove component','YesNo','Question','Button2')
'@}
    @{Name='box remove model'
      Cur=@'
    $answer=ShowUiMessageBox $view.dialog $text 'Remove model' 'YesNo' 'Question' 'Button2'
'@
      Orig=@'
    $answer=[Windows.Forms.MessageBox]::Show($view.dialog,$text,'Remove model','YesNo','Question','Button2')
'@}
    @{Name='box remove leftovers'
      Cur=@'
    $answer=ShowUiMessageBox $view.dialog "Deletes the leftover partial downloads ($($view.leftoverText)) from this PC. Downloaded models are not touched. Continue?" 'Remove leftover partial downloads' 'YesNo' 'Question' 'Button2'
'@
      Orig=@'
    $answer=[Windows.Forms.MessageBox]::Show($view.dialog,"Deletes the leftover partial downloads ($($view.leftoverText)) from this PC. Downloaded models are not touched. Continue?",'Remove leftover partial downloads','YesNo','Question','Button2')
'@}
    @{Name='box support bundle list'
      Cur=@'
    $answer=ShowUiMessageBox $form (Format-FastLlmUiSupportBundleList -Listing $listing) 'Save support bundle' ([Windows.Forms.MessageBoxButtons]::OKCancel) ([Windows.Forms.MessageBoxIcon]::Information)
'@
      Orig=@'
    $answer=[Windows.Forms.MessageBox]::Show($form,(Format-FastLlmUiSupportBundleList -Listing $listing),'Save support bundle',[Windows.Forms.MessageBoxButtons]::OKCancel,[Windows.Forms.MessageBoxIcon]::Information)
'@}
    @{Name='box support bundle exists'
      Cur=@'
            if(Test-Path -LiteralPath $dialog.FileName){$null=ShowUiMessageBox $form 'That file already exists. A support bundle is never written over a file; choose a new name.' 'Save support bundle'}
'@
      Orig=@'
            if(Test-Path -LiteralPath $dialog.FileName){[void][Windows.Forms.MessageBox]::Show($form,'That file already exists. A support bundle is never written over a file; choose a new name.','Save support bundle')}
'@}
    @{Name='box license link 2'
      Cur=@'
                    }catch{$null=ShowUiMessageBox $form 'Unable to open the license page. Check your default browser. Nothing was downloaded.' 'Open license page' 'OK' 'Warning'}
'@
      Orig=@'
                    }catch{[void][Windows.Forms.MessageBox]::Show($form,'Unable to open the license page. Check your default browser. Nothing was downloaded.','Open license page','OK','Warning')}
'@}
    @{Name='box update'
      Cur=@'
    $choice=ShowUiMessageBox $form (Format-FastLlmUiUpdateConfirm -Version $version) 'Update FastLLM' 'YesNo' 'Question' 'Button2'
'@
      Orig=@'
    $choice=[Windows.Forms.MessageBox]::Show($form,(Format-FastLlmUiUpdateConfirm -Version $version),'Update FastLLM','YesNo','Question','Button2')
'@}
    @{Name='box reinstall'
      Cur=@'
    $choice=ShowUiMessageBox $form (Format-FastLlmUiReinstallConfirm -From ([string]$offer.from) -To ([string]$offer.to)) 'Reinstall previous version' 'YesNo' 'Question' 'Button2'
'@
      Orig=@'
    $choice=[Windows.Forms.MessageBox]::Show($form,(Format-FastLlmUiReinstallConfirm -From ([string]$offer.from) -To ([string]$offer.to)),'Reinstall previous version','YesNo','Question','Button2')
'@}
    @{Name='box close'
      Cur=@'
        if((ShowUiMessageBox $form 'Closing stops this window''s active download or inference process. Continue?' 'Close FastLLM' 'YesNo' 'Question') -ne 'Yes'){
'@
      Orig=@'
        if([Windows.Forms.MessageBox]::Show($form,'Closing stops this window''s active download or inference process. Continue?','Close FastLLM','YesNo','Question') -ne 'Yes'){
'@}
    @{Name='side result dispatch'
      Cur=@'
function ShowUiSideResult([string]$Title,[string]$Text) {
    if($null -ne $script:uiDialogView){& $script:uiDialogView['ShowUiSideResult'] -Title $Title -Text $Text;return}
'@
      Orig=@'
function ShowUiSideResult([string]$Title,[string]$Text) {
'@}
    @{Name='driver guidance dispatch'
      Cur=@'
function ShowDriverGuidance($Diagnostic) {
    if($null -ne $script:uiDialogView){& $script:uiDialogView['ShowDriverGuidance'] -Diagnostic $Diagnostic;return}
'@
      Orig=@'
function ShowDriverGuidance($Diagnostic) {
'@}
    @{Name='licence setting confirm dispatch'
      Cur=@'
function ShowLicenseSettingConfirm($Disclosure) {
    if($null -ne $script:uiDialogView){return & $script:uiDialogView['ShowLicenseSettingConfirm'] -Disclosure $Disclosure}
'@
      Orig=@'
function ShowLicenseSettingConfirm($Disclosure) {
'@}
    @{Name='component consent dispatch'
      Cur=@'
function ShowComponentConsent($Row,[object[]]$ConsentRows,[bool]$Chosen=$true) {
    if($null -ne $script:uiDialogView){return & $script:uiDialogView['ShowComponentConsent'] -Row $Row -ConsentRows $ConsentRows -Chosen $Chosen}
'@
      Orig=@'
function ShowComponentConsent($Row,[object[]]$ConsentRows,[bool]$Chosen=$true) {
'@}
    @{Name='exact model consent dispatch'
      Cur=@'
function ShowExactModelConsent($Plan) {
    if($null -ne $script:uiDialogView){return & $script:uiDialogView['ShowExactModelConsent'] -Plan $Plan}
'@
      Orig=@'
function ShowExactModelConsent($Plan) {
'@}
    @{Name='VC install review dispatch'
      Cur=@'
function ShowVcInstallReview($Receipt,$Candidate) {
    if($null -ne $script:uiDialogView){return & $script:uiDialogView['ShowVcInstallReview'] -Receipt $Receipt -Candidate $Candidate}
'@
      Orig=@'
function ShowVcInstallReview($Receipt,$Candidate) {
'@}
    @{Name='setup attention dispatch'
      Cur=@'
function ShowSetupAttention($Decision,$Diagnostic) {
    if($null -ne $script:uiDialogView){return & $script:uiDialogView['ShowSetupAttention'] -Decision $Decision -Diagnostic $Diagnostic}
'@
      Orig=@'
function ShowSetupAttention($Decision,$Diagnostic) {
'@}
    @{Name='recipe chooser dispatch'
      Cur=@'
function ShowRecipeChooser($Rows) {
    if($null -ne $script:uiDialogView){return & $script:uiDialogView['ShowRecipeChooser'] -Rows $Rows}
'@
      Orig=@'
function ShowRecipeChooser($Rows) {
'@}
)
function Get-Sha256Text([string]$Text){
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) -replace '-','').ToLowerInvariant()}finally{$sha.Dispose()}
}
function Undo-NamedChanges([string]$Text){
    $problems=@()
    foreach($c in $namedChanges){
        $cur=([string]$c.Cur).Replace("`r`n","`n"); $orig=([string]$c.Orig).Replace("`r`n","`n")
        $hits=0; $at=0
        while(($i=$Text.IndexOf($cur,$at,[StringComparison]::Ordinal)) -ge 0){$hits++;$at=$i+$cur.Length}
        if($hits -ne 1){$problems+="named change '$($c.Name)' matched $hits times (need exactly 1)";continue}
        $Text=$Text.Replace($cur,$orig)
    }
    return [pscustomobject]@{Text=$Text;Problems=$problems}
}
Check ($namedChanges.Count -eq 46) 'forty-six named changes are listed (param, support check, failureHeld start, ClearFailureCapture clear, seam, snapshot arguments, ShowFailure set, ShowFailure view text, GetUiTrayIcon, tray assignment, startup branch, key box copy guard, self-test measurement note, model picker ids, models list refresh, components list refresh, settings height call site, settings height body, dialog view init, ShowUiMessageBox, 18 box call sites, side result dispatch, driver guidance dispatch, six consent and dialog dispatches)'
$currentText=Get-NormalizedText $path
$undone=Undo-NamedChanges $currentText
foreach($pr in $undone.Problems){Write-Host "FINDING: $pr"}
Check ($undone.Problems.Count -eq 0) 'every named change is present exactly once'
$computedHash=Get-Sha256Text $undone.Text
if($computedHash -cne $classicPinnedSha256){
    Write-Host "FINDING: the classic window hash is $computedHash (pinned $classicPinnedSha256), computed against base 6436d2c (PR 1, #85) with the named changes undone."
    Write-Host 'FINDING: if the change is a deliberate fluent-only edit of fast-llm-ui.ps1, add a named pair @{Name=...;Cur=...;Orig=...} to $namedChanges (Cur is the new text, Orig is the base text) and update the pair-count check; if the classic window itself was intentionally changed, re-pin $classicPinnedSha256 to the computed hash.'
}
Check ($computedHash -ceq $classicPinnedSha256) 'with the named changes undone, the window script is byte-identical to the classic window on main'
# Mutation: one changed character anywhere else must break the pin.
$mut=$currentText.Replace("'Bitworks FastLLM (Preview)'","'Bitworks FastLLM (Preview!'")
Check ($mut -cne $currentText) 'the mutation changed the text'
$mutUndone=Undo-NamedChanges $mut
Check ($mutUndone.Problems.Count -eq 0 -and (Get-Sha256Text $mutUndone.Text) -cne $classicPinnedSha256) 'mutation check: a one-character change elsewhere fails the pin'
$mut2=$currentText.Replace("function GetBarValue","function GetBarValuf")
Check ($mut2 -cne $currentText -and (Get-Sha256Text (Undo-NamedChanges $mut2).Text) -cne $classicPinnedSha256) 'mutation check: a change in a function name fails the pin'
# A damaged named change is a finding, not a silent pass.
$broken=$currentText.Replace("if (`$Window -ceq 'fluent') { Initialize-FastLlmUiFluentShell }","if (`$Window -ceq 'fluent') { Initialize-FastLlmUiFluentShell2 }")
Check ((Undo-NamedChanges $broken).Problems.Count -ge 1) 'mutation check: an altered named change is reported'
# 5b-delete-end

# Structural T2: every adapter in the control table is bound by a binding row (a `Name = '...'` row of a Get-FastLlmUiFluent*Bindings function or
# of the shell's binding table) or is on the pending list with its PR. The suite does not load the shell or Home off Windows, so the bound names are read by AST.
# A later task removes an entry from the pending list when it binds the adapter.
$pendingAdapters=@{
    # PR 3b: Models (all bound by Get-FastLlmUiFluentModelsBindings now).
    # PR 3c: Settings (all bound by Get-FastLlmUiFluentSettingsBindings now).
# 5b-delete-begin
    # Never: the tooltip text is on the card.
    'statusTip'='never (its text is on the card)'
# 5b-delete-end
}
# A binding function counts only when Get-FastLlmUiFluentBindingTable calls it: one the table never calls binds nothing at run time.
function Get-CalledBindingFunctions([string[]]$Files){
    $called=New-Object System.Collections.ArrayList
    foreach($f in $Files){
        $a=[System.Management.Automation.Language.Parser]::ParseFile($f,[ref]$null,[ref]$null)
        foreach($table in @($a.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-FastLlmUiFluentBindingTable'},$true))){
            foreach($c in @($table.Body.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst]},$true))){[void]$called.Add([string]$c.GetCommandName())}
        }
    }
    return ,$called.ToArray()
}
function Get-UncalledBindingFunctions([string[]]$Files){
    $called=Get-CalledBindingFunctions $Files
    $bad=New-Object System.Collections.ArrayList
    foreach($f in $Files){
        $a=[System.Management.Automation.Language.Parser]::ParseFile($f,[ref]$null,[ref]$null)
        foreach($fn in @($a.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -cmatch '^Get-FastLlmUiFluent\w*Bindings$'},$true))){
            if($called -cnotcontains $fn.Name){[void]$bad.Add($fn.Name)}
        }
    }
    return ,$bad.ToArray()
}
function Get-BoundAdapterNames([string[]]$Files){
    $names=New-Object System.Collections.ArrayList
    $called=Get-CalledBindingFunctions $Files
    foreach($f in $Files){
        $a=[System.Management.Automation.Language.Parser]::ParseFile($f,[ref]$null,[ref]$null)
        $fns=@($a.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and (($n.Name -cmatch '^Get-FastLlmUiFluent\w*Bindings$' -and $called -ccontains $n.Name) -or $n.Name -ceq 'Get-FastLlmUiFluentBindingTable')},$true))
        foreach($fn in $fns){
            foreach($h in @($fn.Body.FindAll({param($n) $n -is [System.Management.Automation.Language.HashtableAst]},$true))){
                foreach($kv in $h.KeyValuePairs){
                    if([string]$kv.Item1.Extent.Text -ceq 'Name' -and $kv.Item2.Extent.Text -match "^'([^']+)'$"){[void]$names.Add($Matches[1])}
                }
            }
        }
    }
    return ,$names.ToArray()
}
function Get-UnboundAdapters([string[]]$Bound,[string[]]$Table,[hashtable]$Pending){
    return ,@($Table|Where-Object{($Bound -cnotcontains $_) -and (-not $Pending.ContainsKey($_))})
}
$fluentSrcFiles=@(Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter 'FastLlm.UiFluent*.ps1' -File|ForEach-Object{$_.FullName})
$boundNames=Get-BoundAdapterNames $fluentSrcFiles
$uncalled=Get-UncalledBindingFunctions $fluentSrcFiles
foreach($u in $uncalled){Write-Host "FINDING: $u is a binding function the binding table never calls"}
Check ($uncalled.Count -eq 0) 'every Get-FastLlmUiFluent*Bindings function is called from Get-FastLlmUiFluentBindingTable'
# Self-check: a planted binding function the table does not call is reported, and its rows are not counted as bound.
$plantBindDir=Join-Path ([IO.Path]::GetTempPath()) ('fastllm-uncalled-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $plantBindDir)
$plantBindFile=Join-Path $plantBindDir 'FastLlm.UiFluentPlant.ps1'
$plantBindText=@'
function Get-FastLlmUiFluentCalledBindings { return @(@{ Name = 'plantCalledAdapter'; Element = 'X' }) }
function Get-FastLlmUiFluentUncalledBindings { return @(@{ Name = 'plantUncalledAdapter'; Element = 'Y' }) }
function Get-FastLlmUiFluentBindingTable { return @(Get-FastLlmUiFluentCalledBindings) }
'@
[IO.File]::WriteAllText($plantBindFile,$plantBindText)
$plantUncalled=Get-UncalledBindingFunctions @($plantBindFile)
$plantBound=Get-BoundAdapterNames @($plantBindFile)
Remove-Item -LiteralPath $plantBindFile -Force
Remove-Item -LiteralPath $plantBindDir -Force
Check ($plantUncalled.Count -eq 1 -and $plantUncalled[0] -ceq 'Get-FastLlmUiFluentUncalledBindings' -and $plantBound -ccontains 'plantCalledAdapter' -and $plantBound -cnotcontains 'plantUncalledAdapter') 'self-check: a planted binding function the table never calls is reported and binds nothing'
$tableNames=@(Get-FastLlmUiFluentControlTable|ForEach-Object{[string]$_[0]})
Check ($boundNames.Count -gt 20) "the bound-name scan sees the shell and Home binding rows ($($boundNames.Count))"
Check ($boundNames -ccontains 'backgroundAttachButton') 'backgroundAttachButton is bound on Home (by AST)'
Check ($boundNames -ccontains 'bannerLabel' -and $boundNames -ccontains 'statusLabel') 'both the shell rows and the Home rows are read'
$unbound=Get-UnboundAdapters $boundNames $tableNames $pendingAdapters
foreach($u in $unbound){Write-Host "FINDING: adapter $u is neither bound by a binding row nor on the pending list"}
Check ($unbound.Count -eq 0) 'every adapter is bound or pending with its PR'
foreach($pk in $pendingAdapters.Keys){
    Check ($tableNames -ccontains $pk) "pending adapter $pk is in the control table"
    Check ($boundNames -cnotcontains $pk) "pending adapter $pk is not also bound (remove it from the pending list when it is bound)"
}
# Self-check: a planted unbound adapter is flagged, and a bound one on the pending list is a finding.
$plantUnbound=Get-UnboundAdapters $boundNames ($tableNames+'plantedButton') $pendingAdapters
Check ($plantUnbound.Count -eq 1 -and $plantUnbound[0] -ceq 'plantedButton') 'self-check: a planted unbound adapter is flagged'
$plantPending=@('statusLabel'|Where-Object{$boundNames -ccontains $_})
Check ($plantPending.Count -eq 1) 'self-check: the bound-name list would catch a bound adapter put on the pending list'

# ===== PR 3b: Models pins (Task 1) =====
# Row events: the rows that open a page or a section must never carry a Click event, or today's dialogs (switch picker, models and components
# windows, Connect dialog) would open from the fluent window. Read by AST from the binding rows (a hashtable with a literal Name). A row for one of
# these names must have Event = ''. A name with no row yet must be on the pending list (adapter pending, or the row not flipped yet).
$eventlessRowNames=@('switchButton','modelsButton','componentsButton','connectButton','settingsButton','updateBox','experimentalBox','licenseBox')
# Every protected row is eventless now (Home's Switch row was flipped by PR 3b Task 7); a row listed here that is already eventless is a finding.
$eventlessPending=@{}
function Get-EventlessRowFindings([string[]]$Texts,[string[]]$Names,[hashtable]$Pending,[hashtable]$AdapterPending){
    $found=New-Object System.Collections.ArrayList
    $seen=@{}
    foreach($t in $Texts){
        $a=[System.Management.Automation.Language.Parser]::ParseInput($t,[ref]$null,[ref]$null)
        foreach($h in @($a.FindAll({param($n) $n -is [System.Management.Automation.Language.HashtableAst]},$true))){
            $rowName=$null;$rowEvent=$null;$hasEvent=$false
            foreach($kv in $h.KeyValuePairs){
                $k=[string]$kv.Item1.Extent.Text
                if($k -ceq 'Name' -and $kv.Item2.Extent.Text -match "^'([^']+)'$"){$rowName=$Matches[1]}
                if($k -ceq 'Event'){$hasEvent=$true;$rowEvent=[string]$kv.Item2.Extent.Text}
            }
            if($null -eq $rowName -or $Names -cnotcontains $rowName){continue}
            $seen[$rowName]=$true
            $eventless=($hasEvent -and $rowEvent -ceq "''")
            if($Pending.ContainsKey($rowName)){
                if($eventless){[void]$found.Add("row $rowName is already eventless; remove it from the pending list")}
            }
            elseif(-not $eventless){[void]$found.Add("row $rowName must have Event = '' (found: $(if($hasEvent){$rowEvent}else{'no Event key'}))")}
        }
    }
    foreach($n in $Names){
        if(-not $seen.ContainsKey($n) -and -not $AdapterPending.ContainsKey($n)){[void]$found.Add("no binding row for $n and it is not on the adapter pending list")}
    }
    return ,$found.ToArray()
}
$rowTexts=@($fluentSrcFiles|ForEach-Object{[IO.File]::ReadAllText($_)})
$rowFindings=Get-EventlessRowFindings $rowTexts $eventlessRowNames $eventlessPending $pendingAdapters
foreach($f in $rowFindings){Write-Host "FINDING: $f"}
Check ($rowFindings.Count -eq 0) 'the switch, models, components, connect, settings and Components-and-updates toggle rows have Event = '''' (pending ones are listed)'
$plantRows="function Get-FastLlmUiFluentPlantBindings { return @(@{ Name = 'connectButton'; Element = 'X'; Mode = 'Content'; Event = 'Click'; Flags = @() }) }"
$plantRowFindings=Get-EventlessRowFindings @($plantRows) @('connectButton') @{} @{}
Check ($plantRowFindings.Count -eq 1 -and $plantRowFindings[0] -cmatch '^row connectButton must have Event') 'self-check: a planted Click event on a protected row is flagged'
$plantNoEvent="function Get-FastLlmUiFluentPlantBindings { return @(@{ Name = 'connectButton'; Element = 'X' }) }"
Check ((Get-EventlessRowFindings @($plantNoEvent) @('connectButton') @{} @{}).Count -eq 1) 'self-check: a protected row with no Event key is flagged'
$plantEventless="function Get-FastLlmUiFluentPlantBindings { return @(@{ Name = 'switchButton'; Element = 'X'; Event = '' }) }"
Check ((Get-EventlessRowFindings @($plantEventless) @('switchButton') @{'switchButton'='x'} @{}).Count -eq 1) 'self-check: an eventless row left on the pending list is flagged'
Check ((Get-EventlessRowFindings @('function F { 1 }') @('modelsButton') @{} @{}).Count -eq 1) 'self-check: a protected name with no row and no pending entry is flagged'

# The tick hook: Update-FastLlmUiFluentModels (the Models page's tick hook, added by PR 3b) must call no list build, store read, panel fill or picker
# function; the page computes those only when it opens or when an action asks. When the function is not in the tree yet the pin has nothing to read.
# The one allowed call is the picker (or its helper Update-FastLlmUiFluentModelsPicker) inside the edge branch (an If statement), which the lead accepted.
$tickForbidden=@('Get-FastLlmUiSwitchPickerModel','Update-FastLlmUiFluentModelsPicker','Update-FastLlmUiFluentModelsList','Get-FastLlmInstalledModels','Get-FastLlmComponentInventory','Get-FastLlmModelLeftovers','FillModelsPanel','FillComponentsPanel')
function Get-TickHookFindings([string[]]$Texts,[string[]]$Forbidden,[string]$FunctionName){
    $found=New-Object System.Collections.ArrayList
    foreach($t in $Texts){
        $a=[System.Management.Automation.Language.Parser]::ParseInput($t,[ref]$null,[ref]$null)
        foreach($fn in @($a.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $FunctionName},$true))){
            foreach($c in @($fn.Body.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst]},$true))){
                $cn=[string]$c.GetCommandName()
                if($Forbidden -ccontains $cn){
                    $inIf=$false
                    $p=$c.Parent
                    while($null -ne $p -and $p -ne $fn){if($p -is [System.Management.Automation.Language.IfStatementAst]){$inIf=$true};$p=$p.Parent}
                    if(($cn -ceq 'Get-FastLlmUiSwitchPickerModel' -or $cn -ceq 'Update-FastLlmUiFluentModelsPicker') -and $inIf){continue}
                    [void]$found.Add("$FunctionName calls $cn")
                }
            }
        }
    }
    return ,$found.ToArray()
}
$tickFindings=Get-TickHookFindings $rowTexts $tickForbidden 'Update-FastLlmUiFluentModels'
foreach($f in $tickFindings){Write-Host "FINDING: $f"}
Check ($tickFindings.Count -eq 0) 'Update-FastLlmUiFluentModels calls no list build, store read, panel fill or picker outside the edge branch'
foreach($fb in $tickForbidden){
    $plantTick="function Update-FastLlmUiFluentModels { $fb -X 1 }"
    Check ((Get-TickHookFindings @($plantTick) $tickForbidden 'Update-FastLlmUiFluentModels').Count -eq 1) "self-check: a planted $fb call in the tick hook is flagged"
}
Check ((Get-TickHookFindings @('function Update-FastLlmUiFluentModels { if ($edge) { Get-FastLlmUiSwitchPickerModel } }') $tickForbidden 'Update-FastLlmUiFluentModels').Count -eq 0) 'self-check: the picker inside an If (the edge branch) is allowed'
Check ((Get-TickHookFindings @('function Update-FastLlmUiFluentModels { Get-FastLlmUiSwitchPickerModel }') $tickForbidden 'Update-FastLlmUiFluentModels').Count -eq 1) 'self-check: the picker outside an If is flagged'
Check ((Get-TickHookFindings @('function Update-FastLlmUiFluentOther { FillModelsPanel }') $tickForbidden 'Update-FastLlmUiFluentModels').Count -eq 0) 'self-check: another function is not scanned'
# ===== end PR 3b: Models pins (Task 1) =====

# ===== PR 3b: form BeginInvoke and the fluent view contract (Task 5) =====
# The form adapter's BeginInvoke ScriptMethod (the remove flows queue their list rebuild with it) must call exactly one Dispatcher.BeginInvoke on
# $Window.Dispatcher, at Normal priority, with the $Method parameter, inside a closure over $Window. Read by AST so it runs on every platform.
# Mutants it kills: Background, ApplicationIdle or Input priority; a synchronous Invoke; a body that drops $Method; a missing GetNewClosure.
function Get-FormBeginInvokeFindings([string]$Text){
    $found=New-Object System.Collections.ArrayList
    $a=[System.Management.Automation.Language.Parser]::ParseInput($Text,[ref]$null,[ref]$null)
    $cmds=@($a.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -ceq 'Add-Member' -and $n.Extent.Text -cmatch '-Name\s+BeginInvoke\b'},$true))
    if($cmds.Count -ne 1){[void]$found.Add("expected exactly one Add-Member ... -Name BeginInvoke, found $($cmds.Count)");return ,$found.ToArray()}
    $cmd=$cmds[0]
    if($cmd.Extent.Text -cnotmatch '-MemberType\s+ScriptMethod\b'){[void]$found.Add('BeginInvoke is not a ScriptMethod')}
    $sb=@($cmd.FindAll({param($n) $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst]},$true))
    if($sb.Count -ne 1){[void]$found.Add("BeginInvoke has $($sb.Count) script blocks, expected 1");return ,$found.ToArray()}
    $closure=@($cmd.FindAll({param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and [string]$n.Member.Value -ceq 'GetNewClosure' -and [object]::ReferenceEquals($n.Expression,$sb[0])},$true))
    if($closure.Count -ne 1){[void]$found.Add('the BeginInvoke script block is not closed with GetNewClosure() (it reads $Window)')}
    $body=$sb[0].ScriptBlock
    $pb=$body.ParamBlock
    if($null -eq $pb -or @($pb.Parameters).Count -ne 1 -or ([string]$pb.Parameters[0].Name.VariablePath.UserPath) -cne 'Method'){[void]$found.Add('BeginInvoke must take exactly one parameter, $Method')}
    $calls=@($body.FindAll({param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst]},$true))
    $bi=@($calls|Where-Object{$_.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and [string]$_.Member.Value -ceq 'BeginInvoke'})
    if($bi.Count -ne 1){[void]$found.Add("the body must call .BeginInvoke( exactly once, found $($bi.Count)");return ,$found.ToArray()}
    $others=@($calls|Where-Object{-not [object]::ReferenceEquals($_,$bi[0])})
    if($others.Count -gt 0){[void]$found.Add('the body makes another method call: '+$others[0].Extent.Text)}
    $c=$bi[0]
    if($c.Expression.Extent.Text -cne '$Window.Dispatcher'){[void]$found.Add('BeginInvoke is not called on $Window.Dispatcher: '+$c.Expression.Extent.Text)}
    $cargs=@($c.Arguments)
    if($cargs.Count -ne 2){[void]$found.Add("BeginInvoke takes $($cargs.Count) arguments, expected 2");return ,$found.ToArray()}
    if($cargs[0].Extent.Text -cne '[System.Windows.Threading.DispatcherPriority]::Normal'){[void]$found.Add('the priority is not DispatcherPriority::Normal: '+$cargs[0].Extent.Text)}
    $refs=@($cargs[1].FindAll({param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and ([string]$n.VariablePath.UserPath) -ceq 'Method'},$true))
    $lit=@($cargs[1].FindAll({param($n) $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst]},$true))
    if($refs.Count -ne 1 -or $lit.Count -gt 0){[void]$found.Add('the second argument must be the $Method parameter: '+$cargs[1].Extent.Text)}
    return ,$found.ToArray()
}
$formText=[IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.UiFluentForm.ps1'))
$biFindings=Get-FormBeginInvokeFindings $formText
foreach($f in $biFindings){Write-Host "FINDING: $f"}
Check ($biFindings.Count -eq 0) 'the form adapter BeginInvoke is a Normal-priority Dispatcher.BeginInvoke of $Method in a closure over $Window'
$biGood='[System.Windows.Threading.DispatcherPriority]::Normal, [System.Delegate] $Method'
Check ($formText.Contains($biGood)) 'self-check: the real BeginInvoke text contains the priority and delegate arguments the plants replace'
foreach($prio in 'Background','ApplicationIdle','Input','Send','Loaded'){
    $plant=$formText.Replace('DispatcherPriority]::Normal, [System.Delegate] $Method',"DispatcherPriority]::$prio, [System.Delegate] `$Method")
    Check ((Get-FormBeginInvokeFindings $plant).Count -ge 1) "self-check: a $prio priority in the form BeginInvoke is flagged"
}
$plantInvoke=$formText.Replace('$Window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Normal, [System.Delegate] $Method)','$Window.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Normal, [System.Delegate] $Method)')
Check ($plantInvoke -cne $formText -and (Get-FormBeginInvokeFindings $plantInvoke).Count -ge 1) 'self-check: a synchronous Dispatcher.Invoke in place of BeginInvoke is flagged'
$plantEmpty=$formText.Replace('[System.Delegate] $Method)','{})')
Check ($plantEmpty -cne $formText -and (Get-FormBeginInvokeFindings $plantEmpty).Count -ge 1) 'self-check: a body that passes {} instead of $Method is flagged'
$plantOther=$formText.Replace('$Window.Dispatcher.BeginInvoke(','$Window.Dispatcher.Thread.BeginInvoke(')
Check ($plantOther -cne $formText -and (Get-FormBeginInvokeFindings $plantOther).Count -ge 1) 'self-check: another receiver than $Window.Dispatcher is flagged'
$plantNoClosure=$formText.Replace('[System.Delegate] $Method) }.GetNewClosure())','[System.Delegate] $Method) })')
Check ($plantNoClosure -cne $formText -and (Get-FormBeginInvokeFindings $plantNoClosure).Count -ge 1) 'self-check: a BeginInvoke script block without GetNewClosure is flagged'
$plantSync=$formText.Replace('-Name BeginInvoke -Value ({ param($Method) return','-Name BeginInvoke -Value ({ param($Method) $Method.Invoke(); return')
Check ($plantSync -cne $formText -and (Get-FormBeginInvokeFindings $plantSync).Count -ge 1) 'self-check: a body that also runs $Method synchronously is flagged'
Check ((Get-FormBeginInvokeFindings 'function F { 1 }').Count -eq 1) 'self-check: no BeginInvoke ScriptMethod at all is flagged'

# The fluent view contract. The three Remove* functions of fast-llm-ui.ps1 read the open window's view hashtable ($script:modelsView or
# $script:componentsView). The fluent Models page builds its own view with New-FastLlmUiFluentModelsView / New-FastLlmUiFluentComponentsView (PR 3b
# Task 6), and every key those bodies read (plus refresh) must be a key of that hashtable literal. panel and free are the classic WinForms controls and must
# be absent; dialog is $script:form; file is Join-Path $script:FastLlmUiFluentSourceRoot of the same config/ literal the classic view uses.
$viewRead=@{}
$classicAst=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'fast-llm-ui.ps1'),[ref]$null,[ref]$null)
function Get-ViewReadKeys($Ast,[string]$FunctionName){
    $keys=New-Object System.Collections.ArrayList
    foreach($fn in @($Ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $FunctionName},$true))){
        foreach($m in @($fn.Body.FindAll({param($n) $n -is [System.Management.Automation.Language.MemberExpressionAst] -and $n.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and ([string]$n.Expression.VariablePath.UserPath) -ceq 'view' -and $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]},$true))){
            if(-not $keys.Contains([string]$m.Member.Value)){[void]$keys.Add([string]$m.Member.Value)}
        }
    }
    return $keys.ToArray()
}
$modelsRead=@((Get-ViewReadKeys $classicAst 'RemoveModelFromWindow')+(Get-ViewReadKeys $classicAst 'RemoveLeftoversFromWindow')|Sort-Object -Unique)
$componentsRead=@(Get-ViewReadKeys $classicAst 'RemoveComponentFromWindow'|Sort-Object -Unique)
Check (($modelsRead -join ',') -ceq 'dialog,file,leftoverButton,leftoverText,message,root') "the model and leftovers remove flows read exactly dialog, file, leftoverButton, leftoverText, message, root of the view (found: $($modelsRead -join ','))"
Check (($componentsRead -join ',') -ceq 'dialog,file,message,root') "the component remove flow reads exactly dialog, file, message, root of the view (found: $($componentsRead -join ','))"
$classicConfig=@{}
foreach($pair in @(@('RemoveModelFromWindow','ShowModelsWindow','catalog.json'),@('RemoveComponentFromWindow','ShowComponentsWindow','components.json'))){
    $classicConfig[$pair[2]]=$classicAst.Extent.Text.Contains("(Join-Path `$PSScriptRoot 'config/$($pair[2])')")
}
Check ($classicConfig['catalog.json'] -and $classicConfig['components.json']) 'the classic views join $PSScriptRoot with the literals config/catalog.json and config/components.json'

function Get-ViewContractFindings([string[]]$Texts,[string]$FunctionName,[string[]]$Read,[string]$ConfigFile,[string]$Refresh=''){
    $found=New-Object System.Collections.ArrayList
    $fns=@()
    foreach($t in $Texts){
        $a=[System.Management.Automation.Language.Parser]::ParseInput($t,[ref]$null,[ref]$null)
        $fns+=@($a.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $FunctionName},$true))
    }
    if($fns.Count -ne 1){[void]$found.Add("$FunctionName is defined $($fns.Count) times, expected 1");return ,$found.ToArray()}
    $tables=@($fns[0].Body.FindAll({param($n) $n -is [System.Management.Automation.Language.HashtableAst]},$true))
    $view=$null
    foreach($h in $tables){$ks=@($h.KeyValuePairs|ForEach-Object{[string]$_.Item1.Extent.Text}); if($ks -ccontains 'dialog'){$view=$h;break}}
    if($null -eq $view){[void]$found.Add("$FunctionName builds no hashtable with a dialog key");return ,$found.ToArray()}
    $map=@{}
    foreach($kv in $view.KeyValuePairs){$map[[string]$kv.Item1.Extent.Text]=[string]$kv.Item2.Extent.Text}
    foreach($k in @($Read)+@('refresh')){if(-not $map.ContainsKey($k)){[void]$found.Add("$FunctionName has no key $k")}}
    foreach($k in 'panel','free'){if($map.ContainsKey($k)){[void]$found.Add("$FunctionName has the classic control key $k")}}
    if($Refresh -ne ''){
        # The refresh value is the NAME of the list update that rebuilds this view's rows, and that name is a function defined in the scanned files.
        if($map.ContainsKey('refresh') -and $map['refresh'] -cne "'$Refresh'"){[void]$found.Add("$FunctionName refresh is not '$Refresh': "+$map['refresh'])}
        $refreshDefined=@($Texts|Where-Object{$_ -cmatch "(?m)^function\s+$([regex]::Escape($Refresh))\b"})
        if($refreshDefined.Count -ne 1){[void]$found.Add("the refresh target $Refresh is defined $($refreshDefined.Count) times, expected 1")}
    }
    if($map.ContainsKey('dialog') -and $map['dialog'] -cne '$script:form'){[void]$found.Add("$FunctionName dialog is not `$script:form: "+$map['dialog'])}
    if($map.ContainsKey('file') -and $map['file'] -cne "(Join-Path `$script:FastLlmUiFluentSourceRoot 'config/$ConfigFile')" -and $map['file'] -cne "Join-Path `$script:FastLlmUiFluentSourceRoot 'config/$ConfigFile'"){[void]$found.Add("$FunctionName file is not Join-Path `$script:FastLlmUiFluentSourceRoot 'config/$ConfigFile': "+$map['file'])}
    return ,$found.ToArray()
}
$viewSpecs=@(
    @{Fn='New-FastLlmUiFluentModelsView';Read=$modelsRead;Config='catalog.json';Refresh='Update-FastLlmUiFluentModelsList'},
    @{Fn='New-FastLlmUiFluentComponentsView';Read=$componentsRead;Config='components.json';Refresh='Update-FastLlmUiFluentComponentsList'})
$viewGood=@{
    'New-FastLlmUiFluentModelsView'="function New-FastLlmUiFluentModelsView { return @{dialog=`$script:form;message=`$m;leftoverButton=`$b;leftoverText='';root=`$r;file=(Join-Path `$script:FastLlmUiFluentSourceRoot 'config/catalog.json');refresh='Update-FastLlmUiFluentModelsList'} }`nfunction Update-FastLlmUiFluentModelsList { }"
    'New-FastLlmUiFluentComponentsView'="function New-FastLlmUiFluentComponentsView { return @{dialog=`$script:form;message=`$m;root=`$r;file=(Join-Path `$script:FastLlmUiFluentSourceRoot 'config/components.json');refresh='Update-FastLlmUiFluentComponentsList'} }`nfunction Update-FastLlmUiFluentComponentsList { }"}
foreach($spec in $viewSpecs){
    $fn=$spec.Fn
    # The real constructor: Task 6 adds it. Until a source file defines it, only the self-checks run; once defined the contract is enforced.
    $defined=@($rowTexts|Where-Object{$_ -cmatch "(?m)^function\s+$([regex]::Escape($fn))\b"})
    if($defined.Count -gt 0){
        $vf=Get-ViewContractFindings $rowTexts $fn $spec.Read $spec.Config $spec.Refresh
        foreach($f in $vf){Write-Host "FINDING: $f"}
        Check ($vf.Count -eq 0) "$fn names every key the Remove* bodies read, plus refresh, with no panel or free, dialog = `$script:form and the config/ file"
    }
    else{Write-Host "INFO: $fn is not defined yet (PR 3b Task 6); the contract pin is enforced once it is"}
    $good=$viewGood[$fn]
    Check ((Get-ViewContractFindings @($good) $fn $spec.Read $spec.Config $spec.Refresh).Count -eq 0) "self-check: a well formed $fn passes"
    foreach($k in @($spec.Read)+@('refresh')){
        $plant=$good -creplace "(?<![A-Za-z])$k=","renamed_$k="
        Check ($plant -cne $good -and (Get-ViewContractFindings @($plant) $fn $spec.Read $spec.Config $spec.Refresh).Count -ge 1) "self-check: a view without the $k key (renamed or dropped) is flagged in $fn"
    }
    foreach($k in 'panel','free'){
        Check ((Get-ViewContractFindings @($good.Replace('refresh=',"$k=`$p;refresh=")) $fn $spec.Read $spec.Config $spec.Refresh).Count -ge 1) "self-check: a $k key in $fn is flagged"
    }
    Check ((Get-ViewContractFindings @($good.Replace('dialog=$script:form','dialog=$null')) $fn $spec.Read $spec.Config $spec.Refresh).Count -ge 1) "self-check: a dialog that is not `$script:form is flagged in $fn"
    Check ((Get-ViewContractFindings @($good.Replace("config/$($spec.Config)",'config/other.json')) $fn $spec.Read $spec.Config $spec.Refresh).Count -ge 1) "self-check: another config file is flagged in $fn"
    # The refresh VALUE, not only its key: each view rebuilds its own list (swapped targets, an empty name, or a target no file defines are flagged)
    $otherRefresh=@('Update-FastLlmUiFluentModelsList','Update-FastLlmUiFluentComponentsList')|Where-Object{$_ -cne $spec.Refresh}|Select-Object -First 1
    Check ((Get-ViewContractFindings @($good.Replace("refresh='$($spec.Refresh)'","refresh='$otherRefresh'")) $fn $spec.Read $spec.Config $spec.Refresh).Count -ge 1) "self-check: $fn with the other view's refresh target is flagged"
    Check ((Get-ViewContractFindings @($good.Replace("refresh='$($spec.Refresh)'","refresh=''")) $fn $spec.Read $spec.Config $spec.Refresh).Count -ge 1) "self-check: $fn with an empty refresh is flagged"
    Check ((Get-ViewContractFindings @($good.Substring(0,$good.IndexOf("`nfunction $($spec.Refresh)"))) $fn $spec.Read $spec.Config $spec.Refresh).Count -ge 1) "self-check: $fn whose refresh target is defined nowhere is flagged"
    Check ((Get-ViewContractFindings @('function F { 1 }') $fn $spec.Read $spec.Config $spec.Refresh).Count -eq 1) "self-check: a missing $fn is flagged"
}
# ===== end PR 3b: form BeginInvoke and the fluent view contract (Task 5) =====

# Pages (G2, N1): every page registered with Register-FastLlmUiFluentPage passes a -Status element, and that element is a TextBlock with a Polite live
# setting in the page's registered XAML; the set of registered FastLlm.<Page> markup equals the set of registered ids; and every pane item that is not
# a registered page is one of the coming-later items. Read by AST and XML, so it runs on every platform.
$comingLater=@()
function Get-PagePinFindings([string[]]$Texts){
    $found=New-Object System.Collections.ArrayList
    $regs=New-Object System.Collections.ArrayList
    $xaml=@{}
    $navIds=New-Object System.Collections.ArrayList
    foreach($t in $Texts){
        $err=$null
        $a=[System.Management.Automation.Language.Parser]::ParseInput($t,[ref]$null,[ref]$err)
        if(@($err).Count -gt 0){[void]$found.Add('a file does not parse: '+@($err)[0].Message);continue}
        foreach($c in @($a.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -ceq 'Register-FastLlmUiFluentPage'},$true))){
            $r=@{Id='';Nav='';StatusName='';HasStatus=$false}
            $els=@($c.CommandElements)
            for($i=1;$i -lt $els.Count;$i++){
                if($els[$i] -isnot [System.Management.Automation.Language.CommandParameterAst]){continue}
                $arg=$null; if($i+1 -lt $els.Count -and $els[$i+1] -isnot [System.Management.Automation.Language.CommandParameterAst]){$arg=$els[$i+1]}
                switch -CaseSensitive ([string]$els[$i].ParameterName){
                    'Id'{if($null -ne $arg){$r.Id=[string]$arg.Extent.Text.Trim("'")}}
                    'Nav'{if($null -ne $arg){$r.Nav=[string]$arg.Extent.Text.Trim("'")}}
                    'Status'{if($null -ne $arg){$r.HasStatus=$true;if($arg.Extent.Text -match "^\`$Els\['([A-Za-z0-9]+)'\]$"){$r.StatusName=$Matches[1]}}}
                }
            }
            [void]$regs.Add([pscustomobject]$r)
        }
        foreach($asg in @($a.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.IndexExpressionAst] -and $n.Left.Target.Extent.Text -ceq '$script:FastLlmUiXaml' -and $n.Left.Index -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Right -is [System.Management.Automation.Language.CommandExpressionAst] -and $n.Right.Expression -is [System.Management.Automation.Language.StringConstantExpressionAst]},$true))){
            $xaml[[string]$asg.Left.Index.Value]=[string]$asg.Right.Expression.Value
        }
        foreach($h in @($a.FindAll({param($n) $n -is [System.Management.Automation.Language.HashtableAst]},$true))){
            foreach($kv in $h.KeyValuePairs){ if([string]$kv.Item1.Extent.Text -ceq 'Id' -and $kv.Item2.Extent.Text -match "^'(Nav[A-Za-z]+)'$"){[void]$navIds.Add($Matches[1])} }
        }
    }
    $pageNames=@($xaml.Keys|Where-Object{$_ -cmatch '^FastLlm\.' -and $_ -cne 'FastLlm.Shell' -and $_ -cne 'FastLlm.Dialog'}|ForEach-Object{$_.Substring(8)}|Sort-Object)
    $ids=@($regs|ForEach-Object{[string]$_.Id}|Sort-Object)
    if(($pageNames -join ',') -cne ($ids -join ',')){[void]$found.Add("the registered page markup ($($pageNames -join ',')) differs from the registered page ids ($($ids -join ','))")}
    foreach($r in $regs){
        if(-not $r.HasStatus -or $r.StatusName -ceq ''){[void]$found.Add("page '$($r.Id)' is registered without a -Status element taken from `$Els");continue}
        if(-not $xaml.ContainsKey('FastLlm.'+$r.Id)){continue}
        $doc=New-Object System.Xml.XmlDocument
        try{$doc.LoadXml($xaml['FastLlm.'+$r.Id])}catch{[void]$found.Add("the markup of page '$($r.Id)' does not parse");continue}
        $node=@($doc.SelectNodes('//*')|Where-Object{$_.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml') -ceq $r.StatusName})
        if($node.Count -ne 1){[void]$found.Add("page '$($r.Id)': the status element '$($r.StatusName)' is not in its markup exactly once");continue}
        if($node[0].LocalName -cne 'TextBlock' -or $node[0].GetAttribute('AutomationProperties.LiveSetting') -cne 'Polite'){[void]$found.Add("page '$($r.Id)': the status element '$($r.StatusName)' is not a TextBlock with AutomationProperties.LiveSetting Polite")}
    }
    $registeredNav=@($regs|ForEach-Object{[string]$_.Nav})
    foreach($n in $registeredNav){ if($navIds -cnotcontains $n){[void]$found.Add("page nav item '$n' is not a pane item")} }
    foreach($n in @($navIds|Select-Object -Unique)){
        if($registeredNav -cnotcontains $n -and $comingLater -cnotcontains $n){[void]$found.Add("pane item '$n' is neither a registered page nor a coming-later item")}
    }
    return ,@($found.ToArray())
}
$pageTexts=@($fluentSrcFiles|ForEach-Object{[IO.File]::ReadAllText($_)})
# Registering a page refuses a status line that is not a Polite live region: the guard is an if on GetLiveSetting of the status element, with a throw.
function Get-RegisterGuardFindings([string]$ShellText){
    $a=[System.Management.Automation.Language.Parser]::ParseInput($ShellText,[ref]$null,[ref]$null)
    $fn=@($a.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Register-FastLlmUiFluentPage'},$true))
    if($fn.Count -ne 1){return ,@('Register-FastLlmUiFluentPage is not defined exactly once')}
    $ok=$false
    foreach($i in @($fn[0].Body.FindAll({param($n) $n -is [System.Management.Automation.Language.IfStatementAst]},$true))){
        $cond=[string]$i.Clauses[0].Item1.Extent.Text
        $throws=@($i.Clauses[0].Item2.FindAll({param($n) $n -is [System.Management.Automation.Language.ThrowStatementAst]},$true)).Count -gt 0
        if($cond.Contains('GetLiveSetting($Status)') -and $cond.Contains('AutomationLiveSetting]::Polite') -and $throws){$ok=$true}
    }
    if($ok){return ,@()}
    return ,@('Register-FastLlmUiFluentPage does not throw for a status line that is not Polite')
}
$shellText=[IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.UiFluentShell.ps1'))
Check ((Get-RegisterGuardFindings $shellText).Count -eq 0) 'Register-FastLlmUiFluentPage throws when the status line is not a Polite live region'
Check ((Get-RegisterGuardFindings $shellText.Replace('GetLiveSetting($Status) -ne','$false -ne')).Count -eq 1) 'self-check: a registration guard that no longer reads the live setting is flagged'
$pageFindings=Get-PagePinFindings $pageTexts
foreach($pf in $pageFindings){Write-Host "FINDING: $pf"}
Check ($pageFindings.Count -eq 0 -and $pageTexts.Count -ge 8) "every registered page has a Polite TextBlock status line, the page markup equals the registered ids, and every other pane item is coming later ($($pageFindings -join '; '))"
$plantXamlOpen="`$script:FastLlmUiXaml['FastLlm.Plant'] = @'"
$plantXamlClose="'@"
$plantNs='xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"'
$plantXaml=($plantXamlOpen,"<TextBlock $plantNs x:Name=`"PlantStatus`"/>",$plantXamlClose) -join "`n"
$planted=("function Register-Plant { Register-FastLlmUiFluentPage -Id 'Plant' -Element `$Page -Nav 'NavPlant' }",$plantXaml) -join "`n"
$plantedBad=Get-PagePinFindings (@($pageTexts)+@($planted))
Check (@($plantedBad|Where-Object{$_ -like "*Plant*without a -Status*"}).Count -eq 1) 'self-check: a page registered without -Status is flagged'
$plantedXaml=("function Register-Plant { Register-FastLlmUiFluentPage -Id 'Plant' -Element `$Page -Nav 'NavTools' -Status `$Els['PlantStatus'] }",$plantXaml) -join "`n"
Check (@((Get-PagePinFindings (@($pageTexts)+@($plantedXaml)))|Where-Object{$_ -like "*PlantStatus*not a TextBlock with*Polite*"}).Count -eq 1) 'self-check: a status element without a Polite live setting is flagged'
$plantedIdOnly=($plantXamlOpen,"<Grid $plantNs/>",$plantXamlClose) -join "`n"
Check (@((Get-PagePinFindings (@($pageTexts)+@($plantedIdOnly)))|Where-Object{$_ -like "*differs from the registered page ids*"}).Count -eq 1) 'self-check: page markup that is not a registered page is flagged'
$dropHome=@($pageTexts|ForEach-Object{$_ -replace "Register-FastLlmUiFluentPage -Id 'Tools'","Register-FastLlmUiFluentPageGone -Id 'Tools'"})
Check (@((Get-PagePinFindings $dropHome)|Where-Object{$_ -like "*differs from the registered page ids*" -or $_ -like "*neither a registered page nor*"}).Count -ge 1) 'self-check: a page left out of the registry is flagged'

# Initialize-FastLlmUiFluentBindings rebinds with Set-Variable -Scope Script. The bindings file is dot-sourced into the window script, so
# "Script" is that script's own scope: proven with a scratch script that dot-sources it the same way and reads the names there.
$scratchDir=Join-Path ([IO.Path]::GetTempPath()) ('fastllm-bindings-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $scratchDir)
$scratch=Join-Path $scratchDir 'scope-proof.ps1'
$scratchText=@'
param([string]$Root,[string]$InstallRoot,[string]$Via='direct')
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
. (Join-Path $Root 'src/FastLlm.UiFluentAdapter.ps1')
. (Join-Path $Root 'src/FastLlm.Components.ps1')
. (Join-Path $Root 'src/FastLlm.UiFluentBindings.ps1')
$catalog=[pscustomobject]@{models=@([pscustomobject]@{id='m-one'},[pscustomobject]@{id='m-hidden';autoEligible=$false},[pscustomobject]@{id='m-two';autoEligible=$true})}
$settings=[pscustomobject]@{vulkanBarMitigation='on';updateCheck='on';experimentalComponents='off'}
function ReadFromFunction { return $modelBox }
if($Via -ceq 'wrapper'){
    # The shell's real path: a function defined in a second dot-sourced file calls the bindings and discards the map.
    . (Join-Path (Split-Path -Parent $PSCommandPath) 'shell-wrapper.ps1')
    Invoke-ScratchShellInit -InstallRoot $InstallRoot -Catalog $catalog -UiSettings $settings
    $made=[ordered]@{}
    foreach($row in (Get-FastLlmUiFluentControlTable)){$made[[string]$row[0]]=(Get-Variable -Name ([string]$row[0]) -Scope Script -ValueOnly)}
}else{
    $made=Initialize-FastLlmUiFluentBindings -InstallRoot $InstallRoot -Catalog $catalog -UiSettings $settings
}
[pscustomobject]@{
    names=@($made.Keys).Count
    bound=@(Get-FastLlmUiFluentControlTable|Where-Object{$v=Get-Variable -Name ([string]$_[0]) -Scope Script -ErrorAction SilentlyContinue;$null -ne $v -and $v.Value.__name -ceq [string]$_[0]}).Count
    scriptScope=[bool](Get-Variable -Name modelBox -Scope Script -ErrorAction SilentlyContinue)
    sameObject=[object]::ReferenceEquals($script:modelBox,$made['modelBox'])
    viaFunction=[object]::ReferenceEquals((ReadFromFunction),$made['modelBox'])
    items=@($modelBox.Items|ForEach-Object{[string]$_})
    barIndex=[int]$barBox.SelectedIndex
    path=[string]$pathBox.Text
    bar=[string]$barBox.SelectedItem
    update=[bool]$updateBox.Checked
    experimental=[bool]$experimentalBox.Checked
    license=[bool]$licenseBox.Checked
    ctxMax=[decimal]$contextBox.Maximum
    ctxInc=[decimal]$contextBox.Increment
    disabled=@('openChatButton','chooseButton','switchButton'|Where-Object{-not (Get-Variable $_ -ValueOnly).Enabled})
    hidden=@('progress','resultsLink','failureCopyLink','barLink','bannerLabel','bannerNotes','bannerButton','reinstallButton'|Where-Object{-not (Get-Variable $_ -ValueOnly).Visible})
    install=[string]$installButton.Text
}
'@
Set-Content -LiteralPath $scratch -Value $scratchText -Encoding ASCII
$wrapperText=@'
function Invoke-ScratchShellInit {
    param($InstallRoot,$Catalog,$UiSettings)
    [void](Initialize-FastLlmUiFluentBindings -InstallRoot $InstallRoot -Catalog $Catalog -UiSettings $UiSettings)
}
'@
$wrapperFile=Join-Path $scratchDir 'shell-wrapper.ps1'
Set-Content -LiteralPath $wrapperFile -Value $wrapperText -Encoding ASCII
$proof=& $scratch -Root $root -InstallRoot $scratchDir
$proofWrapped=& $scratch -Root $root -InstallRoot $scratchDir -Via 'wrapper'
Check ($null -eq (Get-Variable -Name modelBox -Scope Script -ErrorAction SilentlyContinue)) 'the rebinding stayed in the scratch script, not in this test script'
Check ($proof.scriptScope -and $proof.sameObject -and $proof.viaFunction) 'Set-Variable -Scope Script rebinds the dot-sourcing script scope (also seen from a function defined there)'
Check ($proof.names -eq @(Get-FastLlmUiFluentControlTable).Count) 'one adapter per inventory name'
Check ($proof.bound -eq @(Get-FastLlmUiFluentControlTable).Count) 'every inventory name is rebound at the scratch script scope'
Check ($proofWrapped.bound -eq @(Get-FastLlmUiFluentControlTable).Count -and $proofWrapped.scriptScope -and $proofWrapped.sameObject -and $proofWrapped.viaFunction) 'called through a wrapper function from a second dot-sourced file (the shell path), every name is still rebound at the window script scope'
Check ((@($proofWrapped.items) -join '|') -ceq (@($proof.items) -join '|')) 'the wrapper path produces the same model items'
Check (($proof.items -join '|') -ceq 'Recommended for installed GPU|m-one|m-two') "model items are the default plus the eligible catalog ids (got $($proof.items -join '|'))"
Check ($proof.barIndex -eq 1 -and $proof.bar -ceq 'On') 'the BAR box follows the saved setting'
Check ($proof.path -ceq $scratchDir) 'the folder box shows the install root'
Check ($proof.update -and -not $proof.experimental -and -not $proof.license) 'check boxes follow the saved settings and the licence mode'
Check ($proof.ctxMax -eq 32768 -and $proof.ctxInc -eq 1024) 'the context box has the classic maximum and step'
Check (($proof.disabled -join ',') -ceq 'openChatButton,chooseButton,switchButton') 'open chat, choose and switch start disabled'
Check (@($proof.hidden).Count -eq 8) 'the eight hidden controls start hidden'
Check ($proof.install -ceq 'Install && start') 'a button keeps its classic text unchanged'
[void](Remove-Item -LiteralPath $scratch -Force)
[void](Remove-Item -LiteralPath $wrapperFile -Force)
[void](Remove-Item -LiteralPath $scratchDir -Force)

# Classic untouched: the accessibility switches have exactly three call sites (the top of the shell file, which runs when the shell is dot-sourced,
# Test-FastLlmUiFluentHost, and Invoke-FastLlmUiFluentAccessibilityProbe, the body of doctor's child process); the first two are reachable only
# through the fluent guard of the support-check statement, and the probe is never called in-process (checked below).
function Get-FileAst([string]$Path){ return [System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$null,[ref]$null) }
# A fluent text table against its frozen literal: the same keys (sorted, so a plain hashtable also compares) and the same value for every key.
function Get-FrozenTableProblems($Actual,$Frozen){
    $found=New-Object System.Collections.ArrayList
    $ak=@($Actual.Keys|ForEach-Object{[string]$_}|Sort-Object {$_} -CaseSensitive)
    $fk=@($Frozen.Keys|ForEach-Object{[string]$_}|Sort-Object {$_} -CaseSensitive)
    if(($ak -join "`n") -cne ($fk -join "`n")){[void]$found.Add("the table keys ($($ak -join ',')) differ from the frozen keys ($($fk -join ','))")}
    foreach($k in $fk){
        if($Actual.Contains($k) -and ([string]$Actual[$k]) -cne ([string]$Frozen[$k])){[void]$found.Add("the value of $k is '$($Actual[$k])', frozen '$($Frozen[$k])'")}
    }
    return ,$found.ToArray()
}
function Copy-Table($Table){ $c=[ordered]@{}; foreach($k in @($Table.Keys)){$c[$k]=$Table[$k]}; return $c }
function Get-CommandCalls($Ast,[string]$CommandName){ return ,@($Ast.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -ceq $CommandName},$true)) }
function Get-Ancestor($Node,[type]$Type){ $a=$Node.Parent; while($null -ne $a -and $a -isnot $Type){$a=$a.Parent}; return $a }
# 5b-delete-begin
$guardPattern='\$Window\s+-ceq\s+''fluent'''
# 5b-delete-end
$scanFiles=@(Join-Path $root 'fast-llm-ui.ps1')+@(Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter '*.ps1' -File|ForEach-Object{$_.FullName})+@(Join-Path $root 'fast-llm.ps1')
$setCalls=@();$hostCalls=@()
foreach($f in $scanFiles){
    if(-not (Test-Path -LiteralPath $f)){continue}
    $ast=Get-FileAst $f
    foreach($c in (Get-CommandCalls $ast 'Set-FastLlmUiFluentAccessibilitySwitches')){$setCalls+=[pscustomobject]@{File=$f;Node=$c}}
    foreach($c in (Get-CommandCalls $ast 'Test-FastLlmUiFluentHost')){$hostCalls+=[pscustomobject]@{File=$f;Node=$c}}
}
Check ($setCalls.Count -eq 3) 'the accessibility switches are set at exactly three call sites'
$inSupport=@($setCalls|Where-Object{$_.File.EndsWith('FastLlm.UiFluentSupport.ps1')})
$inShell=@($setCalls|Where-Object{$_.File.EndsWith('FastLlm.UiFluentShell.ps1')})
Check ($inSupport.Count -eq 2 -and $inShell.Count -eq 1) 'two call sites in the support file and one in the shell file, nowhere else'
$supportOwners=@($inSupport|ForEach-Object{ $o=Get-Ancestor $_.Node ([System.Management.Automation.Language.FunctionDefinitionAst]); if($null -ne $o){$o.Name}else{''} }|Sort-Object)
Check (($supportOwners -join ',') -ceq 'Invoke-FastLlmUiFluentAccessibilityProbe,Test-FastLlmUiFluentHost') 'the support-file calls are inside Test-FastLlmUiFluentHost and Invoke-FastLlmUiFluentAccessibilityProbe'
# The probe is never invoked in any process but doctor's child: no command call anywhere, and its only mention outside its definition is the launch string.
$probeCalls=0;$probeMentions=@()
foreach($f in $scanFiles){
    if(-not (Test-Path -LiteralPath $f)){continue}
    foreach($pc in (Get-CommandCalls (Get-FileAst $f) 'Invoke-FastLlmUiFluentAccessibilityProbe')){$probeCalls++}
    $text=Get-Content -LiteralPath $f -Raw
    $probeMentions+=@([regex]::Matches($text,'Invoke-FastLlmUiFluentAccessibilityProbe')|ForEach-Object{ [pscustomobject]@{File=$f;Index=$_.Index} })
}
Check ($probeCalls -eq 0) 'Invoke-FastLlmUiFluentAccessibilityProbe is never invoked by AST in any script'
$probeSupport=Join-Path $root 'src/FastLlm.UiFluentSupport.ps1'
$probeOutside=@($probeMentions|Where-Object{ -not $_.File.EndsWith('FastLlm.UiFluentSupport.ps1') })
$supText=Get-Content -LiteralPath $probeSupport -Raw
$launchLine=@($supText -split "`r?`n"|Where-Object{$_ -match 'Invoke-FastLlmUiFluentAccessibilityProbe' -and $_ -notmatch '^\s*function ' -and $_ -notmatch '^\s*#'})
Check ($probeOutside.Count -eq 0 -and $launchLine.Count -eq 1 -and $launchLine[0].Contains('-Command') -and $launchLine[0].Contains('$info.Arguments')) 'the probe is mentioned outside its definition only in the doctor child launch string'
Check ($null -eq (Get-Ancestor $inShell[0].Node ([System.Management.Automation.Language.FunctionDefinitionAst]))) 'the shell-file call runs at dot-source time (top level)'
Check ($hostCalls.Count -eq 1 -and $hostCalls[0].File.EndsWith('fast-llm-ui.ps1')) 'Test-FastLlmUiFluentHost is called only from fast-llm-ui.ps1, once'
# 5b-delete-begin
function Test-InFluentGuard($Node){
    $g=$Node.Parent
    while($null -ne $g){ if($g -is [System.Management.Automation.Language.IfStatementAst] -and $g.Clauses[0].Item1.Extent.Text -match $guardPattern){return $true}; $g=$g.Parent }
    return $false
}
Check (Test-InFluentGuard $hostCalls[0].Node) 'the support check call is inside the fluent guard'
# 5b-delete-end
Check ($null -eq (Get-Ancestor $hostCalls[0].Node ([System.Management.Automation.Language.FunctionDefinitionAst])) -and $hostCalls[0].Node.Extent.StartLineNumber -lt $seam) 'the support check call is a top-level statement of the window script, before the seam'
# Every dot-source of the shell or support file in the window script is inside the fluent guard, and no file dot-sourced before the seam mentions them.
$uiAst=Get-FileAst (Join-Path $root 'fast-llm-ui.ps1')
$dotCmds=@($uiAst.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot},$true))
$fluentDots=@($dotCmds|Where-Object{$_.Extent.Text -match 'UiFluentShell\.ps1|UiFluentSupport\.ps1'})
Check ($fluentDots.Count -eq 1) 'the window script dot-sources the shell file once'
# 5b-delete-begin
Check ($fluentDots.Count -eq 1 -and (Test-InFluentGuard $fluentDots[0])) 'the window script dot-sources the shell file once, only inside the fluent guard'
# 5b-delete-end
$preSeam=@($dotCmds|Where-Object{$_.Extent.StartLineNumber -lt $seam -and $_.Extent.Text -notmatch 'UiFluentShell'})
$leaks=@()
foreach($d in $preSeam){
    if($d.Extent.Text -match "'(src/[^']+\.ps1)'"){
        $file=Join-Path $root $Matches[1]
        if((Test-Path -LiteralPath $file) -and ((Get-Content -LiteralPath $file -Raw) -match 'UiFluentShell\.ps1|UiFluentSupport\.ps1|Set-FastLlmUiFluentAccessibilitySwitches')){$leaks+=$Matches[1]}
    }
}
Check ($preSeam.Count -gt 5 -and $leaks.Count -eq 0) 'no file dot-sourced before the seam mentions the fluent shell, the support file or the setter'
# The real support-check statement (found by its source line: the dot-source of the shell file and the Test-FastLlmUiFluentHost call), run against a
# mock setter. Positive control: its shell path redirected to a scratch file that only calls the mock setter.
$supportLines=@((Get-Content -LiteralPath (Join-Path $root 'fast-llm-ui.ps1'))|Where-Object{$_ -cmatch 'UiFluentShell\.ps1' -and $_ -cmatch 'Test-FastLlmUiFluentHost' -and $_ -cnotmatch '^\s*#'})
Check ($supportLines.Count -eq 1) 'the support-check statement is found by its source line'
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('fluent-guard-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path (Join-Path $scratch 'src') -Force)
Set-Content -LiteralPath (Join-Path $scratch 'src/FastLlm.UiFluentShell.ps1') -Value 'Set-FastLlmUiFluentAccessibilitySwitches; $guardCounter.dot++; function Test-FastLlmUiFluentHost { @{ supported = $true; reason = "" } }' -Encoding ASCII
$statement=([string]$supportLines[0]).Replace('$PSScriptRoot',"'"+$scratch.Replace("'","''")+"'")
$guardCounter=@{ setter = 0; dot = 0 }
function Set-FastLlmUiFluentAccessibilitySwitches { $guardCounter.setter++ }
try{
# 5b-delete-begin
    # A classic start never executes the accessibility setter: the same statement with $Window=classic.
    & { $Window='classic'; Invoke-Expression $statement }
    Check ($guardCounter.setter -eq 0 -and $guardCounter.dot -eq 0) 'a classic start never executes the accessibility setter (nor dot-sources the shell file)'
# 5b-delete-end
    & { $Window='fluent'; Invoke-Expression $statement }
    Check ($guardCounter.setter -eq 1 -and $guardCounter.dot -eq 1) 'positive control: a start through the same statement dot-sources the shell file and runs the setter'
    # Mutant: a statement that no longer dot-sources the shell file does not run the setter, so the control above would fail on it.
    $guardCounter.setter=0; $guardCounter.dot=0
    $noDot=$statement.Replace('. (Join-Path','$null=(Join-Path')
    try{ & { $Window='fluent'; Invoke-Expression $noDot } }catch{ $null=$_ }
    Check ($noDot -cne $statement -and $guardCounter.setter -eq 0 -and $guardCounter.dot -eq 0) 'mutation check: a support-check statement that dot-sources nothing runs no setter'
}finally{ if(Test-Path -LiteralPath $scratch){Remove-Item -LiteralPath $scratch -Recurse -Force} }

# Connect text drift pin: every value of $script:FastLlmUiFluentConnectText (src/FastLlm.UiFluentConnect.ps1, read by AST, never run) equals a string constant of
# ShowConnectDialog, and every constant that function assigns to a .Text is in the table or is 'Close'. The copy is temporary: the flip deletes the dialog.
$connectAst=Get-FileAst (Join-Path $root 'src/FastLlm.UiFluentConnect.ps1')
$connectAssign=@($connectAst.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$script:FastLlmUiFluentConnectText'},$true))
Check ($connectAssign.Count -eq 1) 'the Connect text table is assigned exactly once'
$connectTable=& ([scriptblock]::Create($connectAssign[0].Right.Extent.Text))
$connectKeys=@('Title','IntroRunning','IntroNotRunning','BaseUrl','AnthropicBaseUrl','ModelName','ContextLimit','ShownWhenRunning','ApiKey','Show','Hide','Copy','KeyUnreadable','CouldNotCopy','Endpoints','EndpointIndent','EndpointSeparator','Documentation','CheckFormats')
Check ((@($connectTable.Keys) -join ',') -ceq ($connectKeys -join ',')) 'the Connect text table has the 19 planned keys, in order'
# The frozen Connect table: the 19 values, written out as literals. Every value is a string constant of the classic ShowConnectDialog (the unconditional
# check below, deleted with the dialog at the flip); the check here reads only the fluent source.
$connectFrozen=[ordered]@{
    Title='Connect an app'
    IntroRunning='FastLLM is running. Use these values in your app. They stay on this computer (127.0.0.1).'
    IntroNotRunning='FastLLM is not running. The model name and context limit appear once it is running; the address below is where it will listen.'
    BaseUrl='Base URL'
    AnthropicBaseUrl='Anthropic base URL'
    ModelName='Model name'
    ContextLimit='Context limit (tokens)'
    ShownWhenRunning='(shown when running)'
    ApiKey='API key'
    Show='Show'
    Hide='Hide'
    Copy='Copy'
    KeyUnreadable='The stored API key cannot be read.'
    CouldNotCopy='Could not copy: '
    Endpoints='Endpoints on the base URL:'
    EndpointIndent='  '
    EndpointSeparator=' - '
    Documentation='Documentation: '
    CheckFormats='Check the API formats'
}
Check ($connectFrozen.Count -eq 19 -and ((@($connectFrozen.Keys) -join ',') -ceq ($connectKeys -join ','))) 'the frozen Connect table holds the 19 planned keys, in order'
Check ((Get-FrozenTableProblems $connectTable $connectFrozen).Count -eq 0) 'the Connect text table equals its frozen literal (19 keys, every value)'
$cnMutValue=Copy-Table $connectTable; $cnMutValue['KeyUnreadable']='The stored API key cannot be read'
$cnMutKey=Copy-Table $connectTable; $cnMutKey['Extra']='A new caption'
$cnMutDrop=Copy-Table $connectTable; $cnMutDrop.Remove('Hide')
Check ((Get-FrozenTableProblems $cnMutValue $connectFrozen).Count -ge 1) 'mutation check: a changed Connect table value fails the frozen literal'
Check ((Get-FrozenTableProblems $cnMutKey $connectFrozen).Count -ge 1) 'mutation check: a new Connect table key fails the frozen literal'
Check ((Get-FrozenTableProblems $cnMutDrop $connectFrozen).Count -ge 1) 'mutation check: a dropped Connect table key fails the frozen literal'
Check ((Get-FrozenTableProblems (Copy-Table $connectTable) $connectFrozen).Count -eq 0) 'control: an unchanged copy of the Connect table passes the frozen literal'
# 5b-delete-begin
$dialogFn=@($uiAst.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'ShowConnectDialog'},$true))
Check ($dialogFn.Count -eq 1) 'ShowConnectDialog is found by AST'
$dialogConstants=@($dialogFn[0].FindAll({param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst]},$true)|ForEach-Object{[string]$_.Value})
$dialogTextConstants=New-Object System.Collections.ArrayList
foreach($assignment in @($dialogFn[0].FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.MemberExpressionAst] -and [string]$n.Left.Member.Value -ceq 'Text'},$true))){
    foreach($k in @($assignment.Right.FindAll({param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst]},$true))){
        # A member name ([Environment]::NewLine) is not a caption.
        if($k.Parent -is [System.Management.Automation.Language.MemberExpressionAst] -and [object]::ReferenceEquals($k.Parent.Member,$k)){continue}
        # Nor is a comparison operand (-ceq 'running') or a command name.
        if($k.Parent -is [System.Management.Automation.Language.BinaryExpressionAst] -and [string]$k.Parent.Operator -cnotmatch '^(Plus|Format)$'){continue}
        if($k.Parent -is [System.Management.Automation.Language.CommandAst] -and [object]::ReferenceEquals($k.Parent.CommandElements[0],$k)){continue}
        if(([string]$k.Value).Trim() -ne ''){[void]$dialogTextConstants.Add([string]$k.Value)}
    }
}
function Get-ConnectDriftProblems($Table,[string[]]$Constants,[string[]]$TextConstants){
    $problems=New-Object System.Collections.ArrayList
    foreach($key in @($Table.Keys)){if($Constants -cnotcontains [string]$Table[$key]){[void]$problems.Add("table value $key is not a constant of ShowConnectDialog")}}
    $allowed=@($Table.Values|ForEach-Object{[string]$_})+@('Close')
    foreach($text in $TextConstants){if($allowed -cnotcontains $text){[void]$problems.Add("ShowConnectDialog assigns '$text' to a .Text and the table has no such value")}}
    return ,$problems.ToArray()
}
$driftProblems=Get-ConnectDriftProblems $connectTable $dialogConstants $dialogTextConstants
foreach($pr in $driftProblems){Write-Host "FINDING: $pr"}
Check ($driftProblems.Count -eq 0 -and $dialogTextConstants.Count -gt 10) "every Connect text value equals a ShowConnectDialog constant, and every constant it assigns to a .Text is in the table or is Close ($($dialogTextConstants.Count) assigned)"
$mutatedTable=[ordered]@{}
foreach($key in @($connectTable.Keys)){$mutatedTable[$key]=[string]$connectTable[$key]}
$mutatedTable['KeyUnreadable']='The stored API key cannot be read'
Check ((Get-ConnectDriftProblems $mutatedTable $dialogConstants $dialogTextConstants).Count -ge 1) 'mutation check: a changed table value fails the drift pin'
Check ((Get-ConnectDriftProblems $connectTable $dialogConstants @($dialogTextConstants.ToArray()+'A new caption')).Count -ge 1) 'mutation check: a new .Text constant in the dialog that the table lacks fails the drift pin'
# The frozen literal against the classic dialog, unconditional: ShowConnectDialog must be found (checked above), and the literal must pass the same drift pin.
$cnFrozenDrift=Get-ConnectDriftProblems $connectFrozen $dialogConstants $dialogTextConstants
foreach($pr in $cnFrozenDrift){Write-Host "FINDING: $pr"}
Check ($dialogFn.Count -eq 1 -and $cnFrozenDrift.Count -eq 0 -and $dialogTextConstants.Count -gt 10) 'the frozen Connect literal equals the classic ShowConnectDialog texts (every value is a classic constant, every classic .Text constant is in the literal or is Close)'
# 5b-delete-end

# ===== PR 3b: input style pins (Task 3) =====
# The shell's TextBox, ComboBox, ComboBoxItem and spin button styles, read from the registered shell markup (XML), so they run on every platform. Each pin names
# one rule; the plants below change one character-run of the real shell text and each must be flagged.
function Get-StylePinFailures([string]$ShellText){
    $fails=New-Object System.Collections.ArrayList
    function StyleCheck($name,$ok){ if(-not $ok){ [void]$fails.Add($name) } }
    $m=[regex]::Match($ShellText,"(?s)\`$script:FastLlmUiXaml\['FastLlm.Shell'\] = @'\r?\n(.*?)\r?\n'@")
    if(-not $m.Success){return ,@('the shell markup is not found')}
    $x=[xml]$m.Groups[1].Value
    $xn='http://schemas.microsoft.com/winfx/2006/xaml'
    $styles=@{}
    foreach($st in $x.SelectNodes("//*[local-name()='Style']")){ $k=$st.GetAttribute('Key',$xn); if($k){$styles[$k]=$st} }
    foreach($pair in @(@('FastLlm.TextBoxStyle','TextBox'),@('FastLlm.ComboBoxStyle','ComboBox'),@('FastLlm.ComboBoxItemStyle','ComboBoxItem'),@('FastLlm.SpinButtonStyle','RepeatButton'))){
        $k=$pair[0]; $has=$styles.ContainsKey($k)
        StyleCheck "$k registered" $has
        if(-not $has){continue}
        $st=$styles[$k]; $xml=$st.OuterXml
        StyleCheck "$k TargetType" ($st.GetAttribute('TargetType') -ceq $pair[1])
        StyleCheck "$k no event attribute" (-not [regex]::IsMatch($xml,'\s(Click|Loaded|Unloaded|GotFocus|LostFocus|TextChanged|SelectionChanged|PreviewKeyDown|KeyDown|MouseDown|Checked|Unchecked|Initialized)\s*='))
        StyleCheck "$k no literal colour" (-not [regex]::IsMatch($xml,'(?i)(Brush|Background|Foreground|Fill|Stroke|Value)="(#|White|Black|Red|Gray|Blue|Green)'))
        StyleCheck "$k no SystemColors literal" (-not $xml.Contains('SystemColors'))
        StyleCheck "$k disabled look" ($xml.Contains('Property="IsEnabled" Value="False"') -and $xml.Contains('FastLlm.DisabledTextBrush'))
    }
    $tb=$styles['FastLlm.TextBoxStyle']; if($tb){ $o=$tb.OuterXml
        StyleCheck 'TextBox strong stroke' $o.Contains('BorderBrush" Value="{DynamicResource FastLlm.ControlStrongStrokeBrush}"')
        StyleCheck 'TextBox radius 4' ([regex]::IsMatch($o,'CornerRadius="4"'))
        StyleCheck 'TextBox MinHeight' $o.Contains('Property="MinHeight" Value="{DynamicResource FastLlm.ControlHeight}"')
        StyleCheck 'TextBox ring 2px' ([regex]::IsMatch($o,'x:Name="Ring" BorderBrush="\{DynamicResource FastLlm\.FocusBrush\}" BorderThickness="2"'))
        StyleCheck 'TextBox ring on focus' $o.Contains('Property="IsKeyboardFocused" Value="True"')
        StyleCheck 'TextBox content host' $o.Contains('x:Name="PART_ContentHost"') }
    $cb=$styles['FastLlm.ComboBoxStyle']; if($cb){ $o=$cb.OuterXml
        StyleCheck 'Combo strong stroke' $o.Contains('BorderBrush" Value="{DynamicResource FastLlm.ControlStrongStrokeBrush}"')
        StyleCheck 'Combo ring 2px' ([regex]::IsMatch($o,'x:Name="Ring" BorderBrush="\{DynamicResource FastLlm\.FocusBrush\}" BorderThickness="2"'))
        StyleCheck 'Combo ring on focus-within' $o.Contains('Property="IsKeyboardFocusWithin" Value="True"')
        StyleCheck 'Combo toggle + popup' ($o.Contains('ToggleButton') -and $o.Contains('x:Name="PART_Popup"'))
        StyleCheck 'Combo popup themed border' ([regex]::IsMatch($o,'(?s)<Popup.*?FastLlm\.ControlStrongStrokeBrush'))
        StyleCheck 'Combo item style linked' $o.Contains('Property="ItemContainerStyle" Value="{StaticResource FastLlm.ComboBoxItemStyle}"')
        StyleCheck 'Combo popup not opened by click-less' (-not $o.Contains('StaysOpenOnEdit')) }
    $ci=$styles['FastLlm.ComboBoxItemStyle']; if($ci){ $o=$ci.OuterXml
        StyleCheck 'Item selected accent' ([regex]::IsMatch($o,'(?s)Property="IsSelected" Value="True".*?TextOnAccentBrush.*?AccentFillBrush'))
        StyleCheck 'Item focus ring 2px' ([regex]::IsMatch($o,'BorderThickness="2"') -and $o.Contains('IsKeyboardFocused'))}
    $sp=$styles['FastLlm.SpinButtonStyle']; if($sp){
        $set=@{}; foreach($el in $sp.SelectNodes("*[local-name()='Setter']")){ $set[$el.GetAttribute('Property')]=$el }
        StyleCheck 'Spin not tab stop' ($set.ContainsKey('IsTabStop') -and $set['IsTabStop'].GetAttribute('Value') -ceq 'False')
        StyleCheck 'Spin not focusable (a click keeps the keyboard focus in the context box)' ($set.ContainsKey('Focusable') -and $set['Focusable'].GetAttribute('Value') -ceq 'False')
        StyleCheck 'Spin icon font' ($set.ContainsKey('FontFamily') -and $set['FontFamily'].GetAttribute('Value') -ceq '{DynamicResource FastLlm.IconFont}')
        StyleCheck 'Spin focus ring' ($set.ContainsKey('FocusVisualStyle') -and $set['FocusVisualStyle'].GetAttribute('Value') -ceq '{DynamicResource FastLlm.FocusVisual}') }
    # No x:Name of a template part reaches Els: each one sits inside a template or a style.
    foreach($n in @($x.SelectNodes("//*[@*[local-name()='Name']]"))){
        $anc=$n; $in=$false
        while($null -ne $anc -and $anc -is [System.Xml.XmlElement]){ if($anc.LocalName -in 'ControlTemplate','Style'){$in=$true}; $anc=$anc.ParentNode }
        if($n.GetAttribute('Name',$xn) -match '^(Ring|Bd|PART_)'){ StyleCheck "template name $($n.GetAttribute('Name',$xn)) inside template" $in }
    }
    return ,$fails.ToArray()
}
$styleFails=Get-StylePinFailures $shellText
foreach($sf in $styleFails){Write-Host "FINDING: style pin $sf"}
Check ($styleFails.Count -eq 0) 'the shell input styles (TextBox, ComboBox, ComboBoxItem, spin button) hold every style rule'
# Plants: each replaces one run of the real shell text and must be flagged.
$stylePlants=@(
    @{Name='combo ring on mouse over (focus-within lost)';Old='<Trigger Property="IsKeyboardFocusWithin" Value="True"><Setter TargetName="Ring" Property="Visibility" Value="Visible"/></Trigger>';New='<Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Ring" Property="Visibility" Value="Visible"/></Trigger>'}
    @{Name='disabled text is the primary brush';Old='<Setter Property="Foreground" Value="{DynamicResource FastLlm.DisabledTextBrush}"/>';New='<Setter Property="Foreground" Value="{DynamicResource FastLlm.TextPrimaryBrush}"/>'}
    @{Name='an event attribute in a style';Old='<ToggleButton ClickMode="Press" Focusable="False"';New='<ToggleButton Click="OnX" ClickMode="Press" Focusable="False"'}
    @{Name='selected item not accent';Old='<Setter Property="Foreground" Value="{DynamicResource FastLlm.TextOnAccentBrush}"/>';New='<Setter Property="Foreground" Value="{DynamicResource FastLlm.TextPrimaryBrush}"/>'}
    @{Name='a literal colour';Old='      <Setter Property="Foreground" Value="{DynamicResource FastLlm.TextPrimaryBrush}"/>'+"`n"+'      <Setter Property="Background" Value="{DynamicResource FastLlm.CardBrush}"/>'+"`n"+'      <Setter Property="BorderBrush" Value="{DynamicResource FastLlm.ControlStrongStrokeBrush}"/>';New='      <Setter Property="Foreground" Value="#FF000000"/>'+"`n"+'      <Setter Property="Background" Value="{DynamicResource FastLlm.CardBrush}"/>'+"`n"+'      <Setter Property="BorderBrush" Value="{DynamicResource FastLlm.ControlStrongStrokeBrush}"/>'}
    @{Name='combo style key renamed';Old='x:Key="FastLlm.ComboBoxStyle"';New='x:Key="FastLlm.ComboBoxStyleX"'}
    @{Name='ring 1px';Old='<Border x:Name="Ring" BorderBrush="{DynamicResource FastLlm.FocusBrush}" BorderThickness="2" CornerRadius="4" Visibility="Collapsed" IsHitTestVisible="False"/>';New='<Border x:Name="Ring" BorderBrush="{DynamicResource FastLlm.FocusBrush}" BorderThickness="1" CornerRadius="4" Visibility="Collapsed" IsHitTestVisible="False"/>'}
    @{Name='spin button without the icon font';Old='      <Setter Property="FontFamily" Value="{DynamicResource FastLlm.IconFont}"/>'+"`n"+'      <Setter Property="FontSize" Value="10"/>';New='      <Setter Property="FontSize" Value="10"/>'}
    @{Name='spin button is a tab stop';Old='<Setter Property="IsTabStop" Value="False"/>'+"`n"+'      <Setter Property="FocusVisualStyle" Value="{DynamicResource FastLlm.FocusVisual}"/>'+"`n"+'      <Setter Property="FontFamily" Value="{DynamicResource FastLlm.IconFont}"/>';New='<Setter Property="IsTabStop" Value="True"/>'+"`n"+'      <Setter Property="FocusVisualStyle" Value="{DynamicResource FastLlm.FocusVisual}"/>'+"`n"+'      <Setter Property="FontFamily" Value="{DynamicResource FastLlm.IconFont}"/>'}
    @{Name='spin button takes the focus on a click (Focusable removed)';Old='      <Setter Property="Focusable" Value="False"/>'+"`
"+'      <Setter Property="Foreground" Value="{DynamicResource FastLlm.TextPrimaryBrush}"/>';New='      <Setter Property="Foreground" Value="{DynamicResource FastLlm.TextPrimaryBrush}"/>'}
    @{Name='text box with the weak stroke';Old='<Setter Property="BorderBrush" Value="{DynamicResource FastLlm.ControlStrongStrokeBrush}"/>'+"`n"+'      <Setter Property="CaretBrush"';New='<Setter Property="BorderBrush" Value="{DynamicResource FastLlm.ControlStrokeBrush}"/>'+"`n"+'      <Setter Property="CaretBrush"'}
)
foreach($plant in $stylePlants){
    $shellLf=$shellText.Replace("`r`n","`n")
    Check ($shellLf.IndexOf([string]$plant.Old,[StringComparison]::Ordinal) -ge 0) "style plant '$($plant.Name)' matches the real shell text"
    $mutated=$shellLf.Replace([string]$plant.Old,[string]$plant.New)
    Check ((Get-StylePinFailures $mutated).Count -ge 1) "self-check: a style mutant is flagged ($($plant.Name))"
}
# ===== Opaque flyout pin: a popup is its own window, so its surface must not be the translucent Card =====
# Every <Popup> Border and every ContextMenu / ToolTip template in src/FastLlm.UiFluent*.ps1 paints FastLlm.FlyoutBrush, never FastLlm.CardBrush; the Models and Settings
# drop-downs all use the one FastLlm.ComboBoxStyle that owns the popup. Cards on the page itself keep CardBrush.
function Get-FlyoutPinFailures([hashtable]$Sources){
    $fails=New-Object System.Collections.ArrayList
    $popups=0
    foreach($name in $Sources.Keys){
        $t=[string]$Sources[$name]
        foreach($pm in [regex]::Matches($t,'(?s)<Popup\b.*?</Popup>')){
            $popups++
            $b=[regex]::Match($pm.Value,'<Border\b[^>]*?\sBackground="([^"]*)"')
            if(-not $b.Success -or $b.Groups[1].Value -cne '{DynamicResource FastLlm.FlyoutBrush}'){[void]$fails.Add("$name`: a Popup Border does not use FastLlm.FlyoutBrush")}
            if($pm.Value.Contains('FastLlm.CardBrush')){[void]$fails.Add("$name`: a Popup uses FastLlm.CardBrush")}
        }
        foreach($tm in [regex]::Matches($t,'(?s)<ControlTemplate\s+TargetType="(ContextMenu|ToolTip|MenuItem)">.*?</ControlTemplate>')){
            if($tm.Value.Contains('FastLlm.CardBrush') -or $tm.Value -cnotmatch 'Background="\{DynamicResource FastLlm\.FlyoutBrush\}"'){[void]$fails.Add("$name`: a $($tm.Groups[1].Value) template does not use FastLlm.FlyoutBrush")}
        }
        foreach($st in [regex]::Matches($t,'(?s)<Style\b[^>]*TargetType="(ContextMenu|ToolTip)"[^>]*>.*?</Style>')){
            if($st.Value.Contains('FastLlm.CardBrush')){[void]$fails.Add("$name`: a $($st.Groups[1].Value) style uses FastLlm.CardBrush")}
        }
        foreach($cm in [regex]::Matches($t,"(?s)ContextMenu[^\r\n]*\r?\n[^\r\n]*SetResourceReference[^\r\n]*'FastLlm\.CardBrush'")){[void]$fails.Add("$name`: a ContextMenu is painted with FastLlm.CardBrush")}
    }
    if($popups -lt 1){[void]$fails.Add('no Popup was found in the Fluent sources')}
    return ,@($fails)
}
$flyoutSources=@{}
foreach($f in Get-ChildItem -Path (Join-Path $root 'src') -Filter 'FastLlm.UiFluent*.ps1'){$flyoutSources[$f.Name]=[System.IO.File]::ReadAllText($f.FullName)}
$flyoutFails=Get-FlyoutPinFailures $flyoutSources
foreach($pr in $flyoutFails){Write-Host "FINDING: $pr"}
Check ($flyoutFails.Count -eq 0) 'every Fluent popup, context menu and tooltip surface uses the opaque FastLlm.FlyoutBrush'
Check ($flyoutSources['FastLlm.UiFluentShell.ps1'] -cmatch '(?s)<Popup x:Name="PART_Popup".*?<Border Background="\{DynamicResource FastLlm\.FlyoutBrush\}"') 'the ComboBox popup Border paints FastLlm.FlyoutBrush'
$mutShell=$flyoutSources.Clone(); $mutShell['FastLlm.UiFluentShell.ps1']=$flyoutSources['FastLlm.UiFluentShell.ps1'].Replace('<Border Background="{DynamicResource FastLlm.FlyoutBrush}" BorderBrush="{DynamicResource FastLlm.ControlStrongStrokeBrush}" BorderThickness="1" CornerRadius="4" Margin="0,2,0,0"','<Border Background="{DynamicResource FastLlm.CardBrush}" BorderBrush="{DynamicResource FastLlm.ControlStrongStrokeBrush}" BorderThickness="1" CornerRadius="4" Margin="0,2,0,0"')
Check ($mutShell['FastLlm.UiFluentShell.ps1'] -cne $flyoutSources['FastLlm.UiFluentShell.ps1'] -and (Get-FlyoutPinFailures $mutShell).Count -ge 1) 'mutation check: CardBrush put back into the popup is flagged'
$mutMenu=$flyoutSources.Clone(); $mutMenu['FastLlm.UiFluentHome.ps1']=$flyoutSources['FastLlm.UiFluentHome.ps1']+"`n<ControlTemplate TargetType=`"ContextMenu`"><Border Background=`"{DynamicResource FastLlm.CardBrush}`"/></ControlTemplate>"
Check ((Get-FlyoutPinFailures $mutMenu).Count -ge 1) 'mutation check: a ContextMenu template on CardBrush is flagged'
$settingsSrc=$flyoutSources['FastLlm.UiFluentSettings.ps1']
$settingsCombos=@([regex]::Matches($settingsSrc,'<ComboBox\b[^>]*>'))
Check ($settingsCombos.Count -ge 4 -and @($settingsCombos|Where-Object{$_.Value -cnotmatch 'Style="\{DynamicResource FastLlm\.ComboBoxStyle\}"'}).Count -eq 0) 'the Settings drop-downs all use FastLlm.ComboBoxStyle (the one popup)'
Check ($flyoutSources['FastLlm.UiFluentModels.ps1'] -cmatch 'x:Name="ModelsModelBox"[^>]*Style="\{DynamicResource FastLlm\.ComboBoxStyle\}"') 'ModelsModelBox uses the same FastLlm.ComboBoxStyle'
Check ((Get-FlyoutPinFailures @{x='<Popup x:Name="P"><Border Background="{DynamicResource FastLlm.CardBrush}"/></Popup>'}).Count -ge 1) 'mutation check: a bare Popup on CardBrush is flagged'

# ===== PR 3c review fix: caption wrapping (a non-wrapping AccessText clips at 2.25 text scale) =====
# The caption presenter of the CheckBox and the switch, and the selection presenter of the ComboBox, each carry a Resources dictionary whose AccessText and TextBlock styles set TextWrapping Wrap.
function Get-WrapPinFailures([string]$ShellText){
    $fails=New-Object System.Collections.ArrayList
    $m=[regex]::Match($ShellText,"(?s)\`$script:FastLlmUiXaml\['FastLlm.Shell'\] = @'\r?\n(.*?)\r?\n'@")
    if(-not $m.Success){return ,@('the shell markup is not found')}
    $x=[xml]$m.Groups[1].Value
    $xn='http://schemas.microsoft.com/winfx/2006/xaml'
    foreach($spec in @(@('FastLlm.CheckBoxStyle','caption'),@('FastLlm.ToggleSwitchStyle','caption'),@('FastLlm.ComboBoxStyle','selection'))){
        $st=$null; foreach($n in $x.SelectNodes("//*[local-name()='Style']")){ if($n.GetAttribute('Key',$xn) -ceq $spec[0]){$st=$n} }
        if($null -eq $st){[void]$fails.Add("$($spec[0]) is not found");continue}
        $want=@($st.SelectNodes(".//*[local-name()='ContentPresenter']") | Where-Object { if($spec[1] -ceq 'selection'){ ([string]$_.GetAttribute('Content')).Contains('SelectionBoxItem') } else { $_.GetAttribute('RecognizesAccessKey') -ceq 'True' } })
        if($want.Count -ne 1){[void]$fails.Add("$($spec[0]) has $($want.Count) $($spec[1]) presenters, expected 1");continue}
        foreach($target in 'AccessText','TextBlock'){
            $wantWrap='Wrap'
            if($spec[1] -ceq 'selection' -and $target -ceq 'TextBlock'){$wantWrap='NoWrap'}   # PR 3c CI round 1: a selection box is one line, trimmed
            $hit=@($want[0].SelectNodes("*[local-name()='ContentPresenter.Resources']/*[local-name()='Style']") | Where-Object { $_.GetAttribute('TargetType') -ceq $target -and @($_.SelectNodes("*[local-name()='Setter'][@Property='TextWrapping'][@Value='$wantWrap']")).Count -eq 1 })
            if($hit.Count -ne 1){[void]$fails.Add("the $($spec[1]) presenter of $($spec[0]) has no $target style with TextWrapping $wantWrap")}
        }
        if($spec[1] -ceq 'selection'){
            $tbStyle=@($want[0].SelectNodes("*[local-name()='ContentPresenter.Resources']/*[local-name()='Style']") | Where-Object { $_.GetAttribute('TargetType') -ceq 'TextBlock' })
            if($tbStyle.Count -eq 1){
                if(@($tbStyle[0].SelectNodes("*[local-name()='Setter'][@Property='TextTrimming'][@Value='CharacterEllipsis']")).Count -ne 1){[void]$fails.Add("the selection TextBlock style of $($spec[0]) does not trim with CharacterEllipsis")}
                if(@($tbStyle[0].SelectNodes("*[local-name()='Setter'][@Property='ToolTip'][@Value='{Binding Text, RelativeSource={RelativeSource Self}}']")).Count -ne 1){[void]$fails.Add("the selection TextBlock style of $($spec[0]) does not carry its text as the ToolTip")}
            }
        }
    }
    return ,$fails.ToArray()
}
$wrapFails=Get-WrapPinFailures $shellText
foreach($wf in $wrapFails){Write-Host "FINDING: wrap pin $wf"}
Check ($wrapFails.Count -eq 0) 'the CheckBox and switch caption presenters and the ComboBox selection presenter wrap their text'
$wrapOne='<Style TargetType="AccessText"><Setter Property="TextWrapping" Value="Wrap"/></Style>'
$wrapLf=$shellText.Replace("`r`n","`n")
$wrapPos=@(); $wi=0; while(($wi=$wrapLf.IndexOf($wrapOne,$wi,[StringComparison]::Ordinal)) -ge 0){$wrapPos+=$wi;$wi+=$wrapOne.Length}
Check ($wrapPos.Count -eq 3) 'the shell markup holds the wrapping AccessText style exactly three times' "found=$($wrapPos.Count)"
for($wk=0;$wk -lt $wrapPos.Count;$wk++){
    $mutated=$wrapLf.Remove($wrapPos[$wk],$wrapOne.Length).Insert($wrapPos[$wk],'<Style TargetType="AccessText"><Setter Property="TextWrapping" Value="NoWrap"/></Style>')
    Check ((Get-WrapPinFailures $mutated).Count -ge 1) "self-check: a presenter without the wrapping AccessText style is flagged (presenter $($wk + 1) of 3)"
}
# PR 3c CI round 1: the selection TextBlock style does not wrap, trims and carries a tooltip. Each of the three parts is mutated away and must be flagged.
$selLf=$shellText.Replace("`r`n","`n")
foreach($selPlant in @(
    @{Name='selection wraps again';Old='<Setter Property="TextWrapping" Value="NoWrap"/>';New='<Setter Property="TextWrapping" Value="Wrap"/>'},
    @{Name='selection does not trim';Old='<Setter Property="TextTrimming" Value="CharacterEllipsis"/>';New='<Setter Property="TextTrimming" Value="None"/>'},
    @{Name='selection has no tooltip';Old='<Setter Property="ToolTip" Value="{Binding Text, RelativeSource={RelativeSource Self}}"/>';New='<Setter Property="Cursor" Value="Arrow"/>'})){
    Check ($selLf.IndexOf([string]$selPlant.Old,[StringComparison]::Ordinal) -ge 0) "selection plant '$($selPlant.Name)' matches the real shell text"
    Check ((Get-WrapPinFailures $selLf.Replace([string]$selPlant.Old,[string]$selPlant.New)).Count -ge 1) "self-check: a selection style mutant is flagged ($($selPlant.Name))"
}
# ===== end PR 3b: input style pins (Task 3) =====

# ===== PR 3b: Home Switch/Change and Activity copy pins (Task 7) =====
$homeSrc=[IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.UiFluentHome.ps1'))
$shellSrc=$shellText
function Get-HomePinFunc([string]$Text,[string]$Name){
    $a=[System.Management.Automation.Language.Parser]::ParseInput($Text,[ref]$null,[ref]$null)
    $f=@($a.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name},$true))
    if($f.Count -eq 1){return [string]$f[0].Extent.Text}
    return ''
}
$t7Switch=Get-HomePinFunc $homeSrc 'Invoke-FastLlmUiFluentHomeSwitch'
$t7Change=Get-HomePinFunc $homeSrc 'Invoke-FastLlmUiFluentHomeChange'
$t7Init=Get-HomePinFunc $homeSrc 'Initialize-FastLlmUiFluentHome'
Check ($t7Switch -cmatch "Test-FastLlmUiFluentPageRegistered -Id 'Models'" -and $t7Switch -cmatch "Set-FastLlmUiFluentPage -Id 'Models' -FocusNav") 'Task 7: Home Switch navigates to Models, focusing the pane item'
# 5b-delete-begin
Check ($t7Switch -cmatch "Test-FastLlmUiFluentPageRegistered -Id 'Models'" -and $t7Switch -cmatch "Set-FastLlmUiFluentPage -Id 'Models' -FocusNav" -and $t7Switch -cmatch "Invoke-FastLlmUiAdapterEvent -Adapter \`$script:switchButton -Event 'Click'") 'Task 7: Home Switch navigates to Models (focusing the pane item) when registered, else raises the adapter click'
# 5b-delete-end
Check ($t7Change -cmatch "Test-FastLlmUiFluentPageRegistered -Id 'Models'" -and $t7Change -cmatch "Set-FastLlmUiFluentPage -Id 'Models'" -and $t7Change -cnotmatch '-FocusNav' -and $t7Change -cmatch "\['ModelsModelBox'\]" -and $t7Change -cmatch '\.Focus\(\)') 'Task 7: Home Change navigates to Models and focuses the model box'
Check ($t7Init -cmatch "\`$Els\['SwitchButton'\]\.Add_Click\(\{[^}]*Invoke-FastLlmUiFluentHomeSwitch" -and $t7Init -cmatch "\`$Els\['ChangeButton'\]\.Add_Click\(\{[^}]*Invoke-FastLlmUiFluentHomeChange") 'Task 7: Switch and Change clicks are wired to the plain handlers'
Check ($homeSrc -cnotmatch '<Button x:Name="ChangeButton"[^>]*IsEnabled="False"' -and $t7Init -cnotmatch "ChangeButton'\]\.ToolTip" -and $t7Init -cnotmatch "SetShowOnDisabled\(\`$Els\['ChangeButton'\]") 'Task 7: Change is enabled with no coming-later tooltip'
# the header button: strings, name, Els, table row, hosting
Check ($homeSrc -cmatch "(?m)^\s*CopyFullOutputActivity\s*=\s*'Copy full output \(Activity\)'\s*$") 'Task 7: the string CopyFullOutputActivity is exactly Copy full output (Activity)'
Check ($t7Init -cmatch '\$copy = New-Object System\.Windows\.Controls\.Button' -and $t7Init -cmatch "\`$copy\.Name = 'ActivityCopyButton'" -and $t7Init -cmatch "SetResourceReference\(\[System\.Windows\.FrameworkElement\]::StyleProperty, 'FastLlm\.LinkButtonStyle'\)" -and $t7Init -cmatch 'SetName\(\$copy,\s*\[string\]\s*\$s\.CopyFullOutputActivity\)' -and $t7Init -cmatch "\`$Els\['ActivityCopyButton'\] = \`$copy") 'Task 7: the header button is created in code, styled as the failure link, named from CopyFullOutputActivity and put in Els'
Check ($t7Init -cmatch "FastLlmUiFluentActivityCopySlot -ceq 'Body'" -and $t7Init -cmatch "\`$Els\['ActivityBody'\]\.Children\.Insert\(0, \`$copy\)" -and $t7Init -cmatch "else \{ \`$Els\['ActivityExpander'\]\.Tag = \`$copy \}" -and $homeSrc -cmatch "FastLlmUiFluentActivityCopySlot = 'Tag'" -and $t7Init -cmatch 'HorizontalAlignment\]::Right') 'Task 7: slot Tag puts the button in Expander.Tag, slot Body inserts it first in the ActivityBody panel, right-aligned'
Check ($homeSrc -cmatch '<StackPanel x:Name="ActivityBody">\s*<TextBox x:Name="ActivityBox"' -and $homeSrc -cnotmatch 'x:Name="ActivityCopyButton"' -and $homeSrc -cnotmatch 'ACTIVITY_COPY') 'Task 7: the Home markup holds the ActivityBody panel and no copy button or placeholder (the button is code-built)'
$rowAst=[System.Management.Automation.Language.Parser]::ParseInput($shellSrc,[ref]$null,[ref]$null)
$t7Rows=@($rowAst.FindAll({param($n) $n -is [System.Management.Automation.Language.HashtableAst] -and ($n.Extent.Text -cmatch "Name\s*=\s*'failureCopyLink'")},$true))
$t7Second=@($t7Rows|Where-Object{$_.Extent.Text -cmatch "Element\s*=\s*'ActivityCopyButton'"})
Check ($t7Rows.Count -eq 2 -and $t7Second.Count -eq 1 -and $t7Second[0].Extent.Text -cmatch "Mode\s*=\s*'Content'" -and $t7Second[0].Extent.Text -cmatch "Event\s*=\s*'LinkClicked'" -and $t7Second[0].Extent.Text -cmatch 'Also\s*=\s*\$true' -and $t7Rows[0].Extent.Text -cmatch "Element\s*=\s*'FailureCopyButton'" -and $t7Rows[0].Extent.Text -cnotmatch 'Also') 'Task 7: the binding table has the ActivityCopyButton row after FailureCopyButton, joining failureCopyLink with Also and LinkClicked'
$t7Style=[regex]::Match($shellSrc,'(?s)<Style x:Key="FastLlm\.ExpanderStyle".*?</Style>').Value
$t7Hd=$t7Style.IndexOf('x:Name="Hd"');$t7Tg=$t7Style.IndexOf('Content="{TemplateBinding Tag}"');$t7Bd=$t7Style.IndexOf('x:Name="Body"')
Check ($t7Hd -gt 0 -and $t7Tg -gt $t7Hd -and $t7Bd -gt $t7Tg -and $t7Style -cmatch 'Grid\.Column="1"[^>]*Content="\{TemplateBinding Tag\}"|x:Name="TagHost" Grid\.Column="1"') 'Task 7: the Expander style presents the Tag after the toggle and before the body (tab order toggle, copy, body)'
# Plants: one change in the real Home or Shell text each; the matching check must fail. The pins above are read from named variables, so a plant re-evaluates the
# one expression it is aimed at.
function Test-T7Pin([string]$HomeText,[string]$ShellTextIn,[string]$Which){
    $sw=Get-HomePinFunc $HomeText 'Invoke-FastLlmUiFluentHomeSwitch'
    $ch=Get-HomePinFunc $HomeText 'Invoke-FastLlmUiFluentHomeChange'
    $in=Get-HomePinFunc $HomeText 'Initialize-FastLlmUiFluentHome'
    switch($Which){
        'switch'{return ($sw -cmatch "Set-FastLlmUiFluentPage -Id 'Models' -FocusNav")}
        'change'{return ($ch -cmatch "\['ModelsModelBox'\]" -and $ch -cnotmatch '-FocusNav')}
        'wire'{return ($in -cmatch "\`$Els\['SwitchButton'\]\.Add_Click\(\{[^}]*Invoke-FastLlmUiFluentHomeSwitch")}
        'tag'{$st=[regex]::Match($ShellTextIn,'(?s)<Style x:Key="FastLlm\.ExpanderStyle".*?</Style>').Value;return ($st.Contains('Content="{TemplateBinding Tag}"'))}
        'name'{return ($in -cmatch 'SetName\(\$copy,\s*\[string\]\s*\$s\.CopyFullOutputActivity\)')}
    }
}
Check ((Test-T7Pin $homeSrc $shellSrc 'switch') -and (Test-T7Pin $homeSrc $shellSrc 'change') -and (Test-T7Pin $homeSrc $shellSrc 'wire') -and (Test-T7Pin $homeSrc $shellSrc 'tag') -and (Test-T7Pin $homeSrc $shellSrc 'name')) 'Task 7 plant helper: every aimed expression holds on the real text'
Check (-not (Test-T7Pin $homeSrc.Replace("Set-FastLlmUiFluentPage -Id 'Models' -FocusNav","Set-FastLlmUiFluentPage -Id 'Models'") $shellSrc 'switch')) 'self-check: Home Switch without -FocusNav is flagged'
Check (-not (Test-T7Pin $homeSrc.Replace("['ModelsModelBox']","['ModelsFolderBox']") $shellSrc 'change')) 'self-check: Home Change that focuses another box is flagged'
Check (-not (Test-T7Pin $homeSrc.Replace('Invoke-FastLlmUiFluentHomeSwitch })','Invoke-FastLlmUiFluentHomeConnect })') $shellSrc 'wire')) 'self-check: a Switch click wired to another handler is flagged'
Check (-not (Test-T7Pin $homeSrc $shellSrc.Replace('Content="{TemplateBinding Tag}"','Content="{TemplateBinding Header}"') 'tag')) 'self-check: an Expander style that presents the Header instead of the Tag is flagged'
Check (-not (Test-T7Pin $homeSrc.Replace('SetName($copy, [string] $s.CopyFullOutputActivity)','SetName($copy, [string] $s.Activity)') $shellSrc 'name')) 'self-check: a header copy button named like the Activity heading is flagged'
# No runtime string goes into registered XAML: no src/FastLlm.UiFluent*.ps1 file calls .Replace( or -replace on a $script:FastLlmUiXaml[...] value or on a here-string
# assigned to one, and every table entry is assigned a constant here-string.
function Get-XamlRewriteFindings([string]$Text){
    $a=[System.Management.Automation.Language.Parser]::ParseInput($Text,[ref]$null,[ref]$null)
    $found=New-Object System.Collections.ArrayList
    $isTable='\$script:FastLlmUiXaml\['
    foreach($n in @($a.FindAll({param($x) $x -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $x.Member.Extent.Text -ceq 'Replace' -and $x.Expression.Extent.Text -cmatch '\$script:FastLlmUiXaml\['},$true))){[void]$found.Add($n.Extent.Text)}
    foreach($n in @($a.FindAll({param($x) $x -is [System.Management.Automation.Language.BinaryExpressionAst] -and ([string]$x.Operator) -match 'replace' -and $x.Left.Extent.Text -cmatch '\$script:FastLlmUiXaml\['},$true))){[void]$found.Add($n.Extent.Text)}
    foreach($n in @($a.FindAll({param($x) $x -is [System.Management.Automation.Language.AssignmentStatementAst] -and $x.Left.Extent.Text -cmatch '\$script:FastLlmUiXaml\[' -and $x.Right.Extent.Text -cnotmatch "^@'"},$true))){[void]$found.Add($n.Extent.Text)}
    return ,$found.ToArray()
}
$t7XamlFindings=@()
foreach($uf in @(Get-ChildItem (Join-Path $root 'src') -Filter 'FastLlm.UiFluent*.ps1')){foreach($fnd in (Get-XamlRewriteFindings ([IO.File]::ReadAllText($uf.FullName)))){$t7XamlFindings+=($uf.Name+': '+$fnd.Substring(0,[Math]::Min(80,$fnd.Length)))}}
foreach($fnd in $t7XamlFindings){Write-Host "FINDING: $fnd"}
Check ($t7XamlFindings.Count -eq 0) 'Task 7: no UiFluent file rewrites registered XAML (no .Replace or -replace on a table value; every table entry is a constant here-string)'
Check ((Get-XamlRewriteFindings "`$script:FastLlmUiXaml['X'] = ([string] `$script:FastLlmUiXaml['X']).Replace('a','b')").Count -ge 1) 'self-check: a .Replace on a XAML table value is flagged'
Check ((Get-XamlRewriteFindings "`$script:FastLlmUiXaml['X'] = (`$script:FastLlmUiXaml['X'] -replace 'a','b')").Count -ge 1) 'self-check: a -replace on a XAML table value is flagged'
Check ((Get-XamlRewriteFindings "`$script:FastLlmUiXaml['X'] = `$markup").Count -eq 1) 'self-check: a table entry assigned a non-constant is flagged'
# ===== end PR 3b: Home Switch/Change and Activity copy pins (Task 7) =====

# ===== PR 3b: the Models page pins (Task 6) =====
$modelsPath=Join-Path $root 'src/FastLlm.UiFluentModels.ps1'
$modelsText=[IO.File]::ReadAllText($modelsPath)
$modelsAst=Get-FileAst $modelsPath
function Get-AstFunction($Ast,[string]$Name){ return ,@($Ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name},$true)) }
function Get-CommandNames($Ast){ return ,@($Ast.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst]},$true)|ForEach-Object{[string]$_.GetCommandName()}) }

# The page is wired into the shell: dot-sourced, parsed, initialised and registered, and the Models rows join the binding table; the Home Change/Switch targets
# (ModelsModelBox in Els, NavModels in Els) exist.
Check ($shellText.Contains("'FastLlm.UiFluentModels.ps1'")) 'the shell dot-sources the Models file'
foreach($need in "New-FastLlmUiXamlElement -Name 'FastLlm.Models'",'Initialize-FastLlmUiFluentModels -Page $modelsPage','Register-FastLlmUiFluentModelsPage -Page $modelsPage',"@(Get-FastLlmUiFluentModelsBindings)","`$f['Els']['NavModels'] = `$items[1].Item"){
    Check ($shellText.Contains($need)) "the shell has: $need"
}
Check ($modelsText -cmatch "(?s)Add-FastLlmUiFluentElements[^\r\n]*'ModelsModelBox'|'ModelsModelBox'") 'the Models page collects ModelsModelBox into Els (Home Change focuses it)'
# Models binds exactly the eight rows of the plan; the two sections bind Visual with no event; no page row opens a dialog.
$bindFn=Get-AstFunction $modelsAst 'Get-FastLlmUiFluentModelsBindings'
Check ($bindFn.Count -eq 1) 'Get-FastLlmUiFluentModelsBindings is defined once'
$bindRows=@($bindFn[0].Body.FindAll({param($n) $n -is [System.Management.Automation.Language.HashtableAst]},$true)|ForEach-Object{ ($_.KeyValuePairs|ForEach-Object{$_.Item1.Extent.Text+'='+$_.Item2.Extent.Text}) -join ';' })
Check ($bindRows.Count -eq 8) 'the Models binding table has eight rows'
foreach($want in @("Name='modelBox';Element='ModelsModelBox';Mode='Combo'","Name='pathBox';Element='ModelsFolderBox';Mode='Input'","Name='contextBox';Element='ModelsContextBox';Mode='Number'","Name='barBox';Element='ModelsBarBox';Mode='Combo'","Name='chooseButton';Element='ModelsChooseButton';Mode='Content';Event='Click'","Name='switchLabel';Element='ModelsSwitchLine';Mode='TextBlock'","Name='modelsButton';Element='ModelsDownloadedSection';Mode='Visual';Event=''","Name='componentsButton';Element='ModelsComponentsSection';Mode='Visual';Event=''")){
    $wantNorm=$want -replace '\s',''
    Check (@($bindRows|Where-Object{($_ -replace '\s','').StartsWith($wantNorm)}).Count -eq 1) "the Models binding table has the row $want"
}
# Today's dialogs are unreachable from the page.
$modelsCalls=Get-CommandNames $modelsAst
foreach($dlg in 'ShowUiSwitchPicker','ShowModelsWindow','ShowComponentsWindow','ShowConnectDialog'){ Check ($modelsCalls -cnotcontains $dlg) "the Models page never calls $dlg" }
# The views are made by the list updates (never in Initialize, where the script's own null assignments run later) and never cleared.
$initFn=Get-AstFunction $modelsAst 'Initialize-FastLlmUiFluentModels'
Check ($initFn.Count -eq 1 -and (Get-CommandNames $initFn[0]) -cnotcontains 'New-FastLlmUiFluentModelsView' -and (Get-CommandNames $initFn[0]) -cnotcontains 'New-FastLlmUiFluentComponentsView') 'the views are not made in Initialize'
Check ($modelsText -cnotmatch '\$script:(modelsView|componentsView)\s*=\s*\$null') 'the page never clears the views'
foreach($pair in @(@('Update-FastLlmUiFluentModelsList','New-FastLlmUiFluentModelsView'),@('Update-FastLlmUiFluentComponentsList','New-FastLlmUiFluentComponentsView'))){
    $fnList=Get-AstFunction $modelsAst $pair[0]
    Check ($fnList.Count -eq 1 -and (Get-CommandNames $fnList[0]) -ccontains $pair[1]) "$($pair[0]) makes its view first"
}
# The Remove buttons call today's functions with today's shapes; the leftover handler passes nothing.
foreach($pair in @(@('Invoke-FastLlmUiFluentModelsRemoveModel','RemoveModelFromWindow','([string] $Sender.Tag)'),@('Invoke-FastLlmUiFluentModelsRemoveLeftovers','RemoveLeftoversFromWindow',''),@('Invoke-FastLlmUiFluentModelsRemoveComponent','RemoveComponentFromWindow','([string] $Sender.Tag)'))){
    $h=Get-AstFunction $modelsAst $pair[0]
    $calls=@(); if($h.Count -eq 1){$calls=@($h[0].Body.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -ceq $pair[1]},$true))}
    Check ($calls.Count -eq 1 -and (($calls[0].CommandElements|Select-Object -Skip 1|ForEach-Object{$_.Extent.Text}) -join ' ') -ceq $pair[2]) "$($pair[0]) calls $($pair[1]) $($pair[2])"
}
# Leave commits a pending number edit, and the spin buttons step through the same commit block (which calls Step-FastLlmUiNumericValue in Home.ps1).
$exitFn=Get-AstFunction $modelsAst 'Exit-FastLlmUiFluentModels'
Check ($exitFn.Count -eq 1 -and $exitFn[0].Body.Extent.Text.Contains("`$script:contextBox.__state['CommitEdit']") -and $exitFn[0].Body.Extent.Text -cmatch "& \`$commit ''") 'the Models Leave runs the context box CommitEdit block'
$spinFn=Get-AstFunction $modelsAst 'Invoke-FastLlmUiFluentModelsSpin'
Check ($spinFn.Count -eq 1 -and $spinFn[0].Body.Extent.Text.Contains("`$script:contextBox.__state['CommitEdit']") -and $spinFn[0].Body.Extent.Text -cmatch '& \$commit \$Direction') 'the spin handler runs CommitEdit with its direction'
Check ($initFn[0].Body.Extent.Text -cmatch "ModelsContextUp'\]\.Add_Click\(\{[^}]*Invoke-FastLlmUiFluentModelsSpin -Direction 'Up'" -and $initFn[0].Body.Extent.Text -cmatch "ModelsContextDown'\]\.Add_Click\(\{[^}]*Invoke-FastLlmUiFluentModelsSpin -Direction 'Down'") 'the up and down spin buttons call the spin handler with Up and Down'
$homeAst=Get-FileAst (Join-Path $root 'src/FastLlm.UiFluentHome.ps1')
$connectCtl=Get-AstFunction $homeAst 'Connect-FastLlmUiFluentControl'
Check ($connectCtl.Count -eq 1 -and $connectCtl[0].Body.Extent.Text -cmatch '\$step = \$\{function:Step-FastLlmUiNumericValue\}' -and $connectCtl[0].Body.Extent.Text -cmatch '& \$step -Current \$value -Increment') 'the Number commit block steps through Step-FastLlmUiNumericValue'
# The Number box's Up and Down keys: a WPF TextBox's class handler marks Up and Down handled before instance KeyDown handlers run, so the keys are read in
# PreviewKeyDown and marked handled there (Return is read there too and left unhandled).
function Test-NumberKeyWiring([string]$Body){
    $m=[regex]::Match($Body,"(?s)elseif \(\`$Mode -ceq 'Number'\) \{\s*# Commits the typed text.*?\n    \}")
    if(-not $m.Success){return $false}
    $t=$m.Value
    return ($t -cmatch '\$Element\.Add_PreviewKeyDown\(\{' -and $t -cnotmatch '\$Element\.Add_KeyDown\(' -and $t -cmatch "Key\]::Up\) \{ \`$direction = 'Up'; \`$routed\.Handled = \`$true \}" -and $t -cmatch "Key\]::Down\) \{ \`$direction = 'Down'; \`$routed\.Handled = \`$true \}" -and $t -cmatch "Key\]::Return\) \{ \`$direction = '' \}")
}
$numBody=$connectCtl[0].Body.Extent.Text
Check (Test-NumberKeyWiring $numBody) 'the Number box reads Up, Down and Return in PreviewKeyDown, and marks only Up and Down handled'
Check (-not (Test-NumberKeyWiring $numBody.Replace('$Element.Add_PreviewKeyDown({','$Element.Add_KeyDown({'))) 'self-check: the Number keys read in KeyDown (a TextBox swallows Up and Down there) are flagged'
Check (-not (Test-NumberKeyWiring $numBody.Replace("`$direction = 'Up'; `$routed.Handled = `$true","`$direction = 'Up'"))) 'self-check: Up left unhandled (the caret also moves) is flagged'

# The picker is computed once, by ShowUiSwitchPicker's opening statements ($status, its try, the picker call), inside an if on the Switch button's Enabled; that is the only call site in the file.
function Get-PickerGuardFindings([string]$Text,[string[]]$Want){
    $found=New-Object System.Collections.ArrayList
    $a=[System.Management.Automation.Language.Parser]::ParseInput($Text,[ref]$null,[ref]$null)
    $calls=@($a.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -ceq 'Get-FastLlmUiSwitchPickerModel'},$true))
    if($calls.Count -ne 1){[void]$found.Add("Get-FastLlmUiSwitchPickerModel has $($calls.Count) call sites, expected 1");return ,$found.ToArray()}
    $p=$calls[0].Parent; $guard=$null
    while($null -ne $p){ if($p -is [System.Management.Automation.Language.IfStatementAst]){$guard=$p;break}; $p=$p.Parent }
    if($null -eq $guard -or $guard.Clauses[0].Item1.Extent.Text -cnotmatch '\$script:switchButton\.Enabled'){[void]$found.Add('the picker call is not inside an if on $script:switchButton.Enabled');return ,$found.ToArray()}
    $body=@($guard.Clauses[0].Item2.Statements|ForEach-Object{$_.Extent.Text})
    $want=@($Want|ForEach-Object{([string]$_).Replace("`r`n","`n")})
    if($body.Count -ne 4 -or $want.Count -ne 3 -or ([string]$body[0]).Replace("`r`n","`n") -cne $want[0] -or ([string]$body[1]).Replace("`r`n","`n") -cne $want[1] -or ([string]$body[2]).Replace("`r`n","`n") -cne $want[2]){[void]$found.Add('the guarded statements are not the first three statements of ShowUiSwitchPicker (status, its try, the picker call), with the source root, then the message write')}
    elseif($body[3] -cne "`$m['SwitchMessage'].Text = [string] `$picker.message"){[void]$found.Add('the fourth guarded statement is not the picker message write (the message is written only when the picker is computed)')}
    return ,$found.ToArray()
}
# The three statements ShowUiSwitchPicker opens with, as literals (the source root in place of the script root); the check against the classic function is below.
$pickerWant=@(
    '$status=$null',
    'try{$status=Get-FastLlmStatus -InstallRoot $script:installPath}catch{}',
    '$picker=Get-FastLlmUiSwitchPickerModel -InstallRoot $script:installPath -CatalogPath (Join-Path $script:FastLlmUiFluentSourceRoot ''config/catalog.json'') -Status $status'
)
$pickerFindings=Get-PickerGuardFindings $modelsText $pickerWant
foreach($f in $pickerFindings){Write-Host "FINDING: $f"}
Check ($pickerFindings.Count -eq 0) 'the picker is computed by ShowUiSwitchPicker statements inside the Switch-button-enabled guard, at one call site'
Check ((Get-PickerGuardFindings $modelsText.Replace('if ([bool] $script:switchButton.Enabled) {','if ($true) {') $pickerWant).Count -ge 1) 'mutation check: a picker without the switchButton.Enabled guard is flagged'
Check ((Get-PickerGuardFindings $modelsText.Replace("-CatalogPath (Join-Path `$script:FastLlmUiFluentSourceRoot 'config/catalog.json') -Status `$status","-CatalogPath (Join-Path `$script:FastLlmUiFluentSourceRoot 'config/other.json') -Status `$status") $pickerWant).Count -ge 1) 'mutation check: a changed picker statement is flagged'
Check ((Get-PickerGuardFindings ($modelsText+"`nfunction Plant { Get-FastLlmUiSwitchPickerModel -InstallRoot x -CatalogPath y }") $pickerWant).Count -ge 1) 'mutation check: a second picker call site is flagged'
Check ((Get-PickerGuardFindings $modelsText.Replace('try{$status=Get-FastLlmStatus -InstallRoot $script:installPath}catch{}','$status=$null') $pickerWant).Count -ge 1) 'mutation check: a picker without its status statement is flagged'
Check ((Get-PickerGuardFindings $modelsText $pickerWant).Count -eq 0) 'control: the unmutated Models page passes the picker guard pin'
# 5b-delete-begin
# The literal statements against the classic ShowUiSwitchPicker, unconditional: the function must be found, and its first three statements are the literals.
$pickerClassicAst=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'fast-llm-ui.ps1'),[ref]$null,[ref]$null)
$pickerClassicFn=@($pickerClassicAst.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'ShowUiSwitchPicker'},$true))
Check ($pickerClassicFn.Count -eq 1) 'ShowUiSwitchPicker is found in the classic window script'
$pickerClassicWant=@($pickerClassicFn[0].Body.EndBlock.Statements|Select-Object -First 3|ForEach-Object{([string]$_.Extent.Text).Replace('(Join-Path $PSScriptRoot','(Join-Path $script:FastLlmUiFluentSourceRoot')})
Check ($pickerClassicWant.Count -eq 3 -and ($pickerClassicWant -join "`n") -ceq ($pickerWant -join "`n")) 'the literal picker statements equal the first three statements of the classic ShowUiSwitchPicker'
# 5b-delete-end
# The tick hook: the helper may be called only inside the If of the edge; the edge compares the stored state with the button.
$tickFn=Get-AstFunction $modelsAst 'Update-FastLlmUiFluentModels'
Check ($tickFn.Count -eq 1 -and $tickFn[0].Body.Extent.Text -cmatch 'if \(\[bool\] \$script:switchButton\.Enabled -ne \[bool\] \$m\[''SwitchWas''\]\) \{ Update-FastLlmUiFluentModelsPicker \}') 'the tick hook computes the picker only on the Switch button edge'
Check ($tickFn[0].Body.Extent.Text.Contains("Update-FastLlmUiFluentModelsPicker") -and (Get-TickHookFindings @($modelsText.Replace('if ([bool] $script:switchButton.Enabled -ne [bool] $m[''SwitchWas'']) { Update-FastLlmUiFluentModelsPicker }','Update-FastLlmUiFluentModelsPicker')) $tickForbidden 'Update-FastLlmUiFluentModels').Count -ge 1) 'mutation check: the picker helper called on every tick is flagged'

# Live regions: the three message lines are Polite in the registered markup, and each message adapter's TextChanged handler sends the announcement.
$modelsXamlAssign=@($modelsAst.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$script:FastLlmUiXaml[''FastLlm.Models'']'},$true))
Check ($modelsXamlAssign.Count -eq 1) 'the Models markup is assigned once, as one string constant'
$modelsXaml=[string]$modelsXamlAssign[0].Right.Expression.Value
function Get-LiveRegionFindings([string]$Xaml,[string]$Source){
    $found=New-Object System.Collections.ArrayList
    $doc=New-Object System.Xml.XmlDocument; $doc.LoadXml($Xaml)
    $xn='http://schemas.microsoft.com/winfx/2006/xaml'
    foreach($name in 'ModelsSwitchMessage','ModelsDownloadedMessage','ModelsComponentsMessage'){
        $node=@($doc.SelectNodes('//*')|Where-Object{$_.GetAttribute('Name',$xn) -ceq $name})
        if($node.Count -ne 1 -or $node[0].GetAttribute('AutomationProperties.LiveSetting') -cne 'Polite'){[void]$found.Add("$name is not a single element with LiveSetting Polite")}
        $a=[System.Management.Automation.Language.Parser]::ParseInput($Source,[ref]$null,[ref]$null)
        $hooks=@($a.FindAll({param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -ceq 'Add_TextChanged' -and $n.Extent.Text.Contains("'$name'")},$true))
        if($hooks.Count -ne 1 -or (Get-CommandNames $hooks[0]) -cnotcontains 'Send-FastLlmUiFluentLiveRegion'){[void]$found.Add("the TextChanged handler for $name does not call Send-FastLlmUiFluentLiveRegion")}
    }
    return ,$found.ToArray()
}
$liveFindings=Get-LiveRegionFindings $modelsXaml $modelsText
foreach($f in $liveFindings){Write-Host "FINDING: $f"}
Check ($liveFindings.Count -eq 0) 'the three Models message lines are polite live regions and announce on TextChanged'
Check ((Get-LiveRegionFindings $modelsXaml.Replace('<TextBlock x:Name="ModelsDownloadedMessage" Margin="0,8,0,0" TextWrapping="Wrap" AutomationProperties.LiveSetting="Polite"/>','<TextBlock x:Name="ModelsDownloadedMessage" Margin="0,8,0,0" TextWrapping="Wrap"/>') $modelsText).Count -eq 1) 'mutation check: a message line without LiveSetting is flagged'
Check ((Get-LiveRegionFindings $modelsXaml $modelsText.Replace("Send-FastLlmUiFluentLiveRegion -Element `$script:FastLlmUiFluent['Els']['ModelsComponentsMessage']","`$null = 1")).Count -eq 1) 'mutation check: a TextChanged handler without the announcement is flagged'
# The markup: no event attribute, the input styles, one x:Name each, and the named elements the shell, Home and the tests rely on.
Check ($modelsXaml -cnotmatch '\s(Click|Loaded|TextChanged|SelectionChanged|KeyDown|PreviewKeyDown|GotFocus|LostFocus)\s*=') 'the Models markup has no event attribute'
foreach($pair in @(@('ModelsModelBox','FastLlm.ComboBoxStyle'),@('ModelsBarBox','FastLlm.ComboBoxStyle'),@('ModelsFolderBox','FastLlm.TextBoxStyle'),@('ModelsContextBox','FastLlm.TextBoxStyle'),@('ModelsContextUp','FastLlm.SpinButtonStyle'),@('ModelsContextDown','FastLlm.SpinButtonStyle'),@('ModelsStartOptions','FastLlm.ExpanderStyle'))){
    Check ($modelsXaml -cmatch ('x:Name="'+$pair[0]+'"[^>]*Style="\{DynamicResource '+[regex]::Escape($pair[1])+'\}"')) "$($pair[0]) uses $($pair[1])"
}
Check ($modelsXaml -cmatch 'x:Name="ModelsStartOptions"[^>]*IsExpanded="False"') 'the Start options expander starts collapsed'
$modelsXamlDoc=New-Object System.Xml.XmlDocument; $modelsXamlDoc.LoadXml($modelsXaml)
$modelsNames=@($modelsXamlDoc.SelectNodes('//*[@*[local-name()=''Name'']]')|ForEach-Object{$_.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml')})
Check (@($modelsNames|Select-Object -Unique).Count -eq $modelsNames.Count) 'every Models x:Name is unique'
Check (@($modelsNames|Where-Object{$_ -cnotmatch '^Models'}).Count -eq 1 -and @($modelsNames|Where-Object{$_ -ceq 'Bd'}).Count -eq 1) 'every Models x:Name is Models-prefixed (the one template part is Bd, inside the list item template)'
$collected=@([regex]::Matches($initFn[0].Body.Extent.Text,"'(Models[A-Za-z]+)'")|ForEach-Object{$_.Groups[1].Value}|Select-Object -Unique)
Check (@($modelsNames|Where-Object{$_ -cmatch '^Models' -and $collected -cnotcontains $_}).Count -eq 0) 'Initialize collects every Models x:Name into Els'

# The copied text drift pin (as the Connect one): every value of $script:FastLlmUiFluentModelsText equals a constant or a format template of the four classic
# functions, or the first argument of a top-level LabelAt call; and every constant or template those functions assign to a .Text is in the table or on the allowlist.
$modelsTextAssign=@($modelsAst.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$script:FastLlmUiFluentModelsText'},$true))
Check ($modelsTextAssign.Count -eq 1) 'the Models text table is assigned exactly once'
$modelsTable=& ([scriptblock]::Create($modelsTextAssign[0].Right.Extent.Text))
Check ((@($modelsTable.Keys) -join ',') -ceq 'Model,Context,Folder,Bar,SwitchTitle,SwitchIntro,SwitchNow,DownloadedModels,RemoveLeftovers,Remove,NoModels,NoComponents,FreeFormat,ModelRowFormat,InUseFormat,LeftoversFormat,ModelListReadFormat,ComponentListReadFormat') 'the Models text table has the 18 planned keys, in order'
# The frozen Models table: the 18 values as literals. Every value is a constant or a format template of the four classic functions (the unconditional check
# below, deleted with them at the flip); the check here reads only the fluent source.
$modelsFrozen=[ordered]@{
    Model='Model'
    Context='Context (0 = catalog default)'
    Folder='Install and model cache folder'
    Bar='Resizable BAR workaround'
    SwitchTitle='Switch model'
    SwitchIntro='FastLLM finishes the requests in progress, stops the running model and starts the one you pick. If the new model cannot start, the old one is started again. "Fits" is an estimate; FastLLM checks again when it switches.'
    SwitchNow='Switch'
    DownloadedModels='Downloaded models'
    RemoveLeftovers='Remove leftover partial downloads'
    Remove='Remove'
    NoModels='No models are downloaded.'
    NoComponents='No engine components are installed.'
    FreeFormat='Free disk space: {0} GB'
    ModelRowFormat='{0}  -  {1} GB'
    InUseFormat='  (in use: {0})'
    LeftoversFormat='{0} leftover file(s), {1} GB'
    ModelListReadFormat='The model list could not be read: {0}'
    ComponentListReadFormat='The component list could not be read: {0}'
}
Check ($modelsFrozen.Count -eq 18 -and ((@($modelsFrozen.Keys) -join ',') -ceq (@($modelsTable.Keys) -join ','))) 'the frozen Models table holds the 18 planned keys, in order'
Check ((Get-FrozenTableProblems $modelsTable $modelsFrozen).Count -eq 0) 'the Models text table equals its frozen literal (18 keys, every value)'
$mdMutValue=Copy-Table $modelsTable; $mdMutValue['NoModels']='No models are downloaded'
$mdMutTemplate=Copy-Table $modelsTable; $mdMutTemplate['FreeFormat']='Free disk space: {0} GiB'
$mdMutKey=Copy-Table $modelsTable; $mdMutKey['Extra']='A new caption'
Check ((Get-FrozenTableProblems $mdMutValue $modelsFrozen).Count -ge 1) 'mutation check: a changed Models table value fails the frozen literal'
Check ((Get-FrozenTableProblems $mdMutTemplate $modelsFrozen).Count -ge 1) 'mutation check: an edited Models template fails the frozen literal'
Check ((Get-FrozenTableProblems $mdMutKey $modelsFrozen).Count -ge 1) 'mutation check: a new Models table key fails the frozen literal'
Check ((Get-FrozenTableProblems (Copy-Table $modelsTable) $modelsFrozen).Count -eq 0) 'control: an unchanged copy of the Models table passes the frozen literal'
# 5b-delete-begin
$classicFns=@('ShowUiSwitchPicker','ShowModelsWindow','FillModelsPanel','FillComponentsPanel')
function Get-TemplateText($Expandable){
    $text=[string]$Expandable.Value
    $start=$Expandable.Extent.StartOffset
    # Replace each nested expression, last first, by its index; the string constant offsets are relative to the whole script, the value excludes the quotes.
    $nested=@($Expandable.NestedExpressions)
    $raw=$Expandable.Extent.Text
    for($i=$nested.Count-1;$i -ge 0;$i--){
        $ns=$nested[$i].Extent.StartOffset-$start; $ne=$nested[$i].Extent.EndOffset-$start
        $raw=$raw.Substring(0,$ns)+('{'+$i+'}')+$raw.Substring($ne)
    }
    return $raw.Substring(1,$raw.Length-2)
}
$classicValues=New-Object System.Collections.ArrayList
$classicAssigned=New-Object System.Collections.ArrayList
foreach($cfn in $classicFns){
    foreach($fnAst in (Get-AstFunction $classicAst $cfn)){
        foreach($k in @($fnAst.FindAll({param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst]},$true))){ [void]$classicValues.Add([string]$k.Value) }
        foreach($ex in @($fnAst.FindAll({param($n) $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]},$true))){ [void]$classicValues.Add((Get-TemplateText $ex)) }
        foreach($asg in @($fnAst.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and (($n.Left -is [System.Management.Automation.Language.MemberExpressionAst] -and [string]$n.Left.Member.Value -ceq 'Text') -or ($n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and ([string]$n.Left.VariablePath.UserPath) -ceq 'text'))},$true))){
            foreach($k in @($asg.Right.FindAll({param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]},$true))){
                if($k.Parent -is [System.Management.Automation.Language.MemberExpressionAst] -and [object]::ReferenceEquals($k.Parent.Member,$k)){continue}
                if($k.Parent -is [System.Management.Automation.Language.BinaryExpressionAst] -and [string]$k.Parent.Operator -cnotmatch '^(Plus|Format)$'){continue}
                if($k.Parent -is [System.Management.Automation.Language.CommandAst] -and [object]::ReferenceEquals($k.Parent.CommandElements[0],$k)){continue}
                $v=if($k -is [System.Management.Automation.Language.ExpandableStringExpressionAst]){Get-TemplateText $k}else{[string]$k.Value}
                if($v.Trim() -ne ''){[void]$classicAssigned.Add($v)}
            }
        }
    }
}
foreach($labelCall in @($classicAst.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -ceq 'LabelAt'},$true))){
    if($labelCall.CommandElements.Count -ge 2 -and $labelCall.CommandElements[1] -is [System.Management.Automation.Language.StringConstantExpressionAst]){[void]$classicValues.Add([string]$labelCall.CommandElements[1].Value)}
}
function Get-ModelsDriftProblems($Table,[string[]]$Values,[string[]]$Assigned){
    $problems=New-Object System.Collections.ArrayList
    foreach($key in @($Table.Keys)){if($Values -cnotcontains [string]$Table[$key]){[void]$problems.Add("table value $key is not a constant or template of the classic Models code")}}
    $allowed=@($Table.Values|ForEach-Object{[string]$_})+@('Close','FastLLM components','Downloaded models')
    foreach($text in $Assigned){if($allowed -cnotcontains $text){[void]$problems.Add("the classic code assigns '$text' to a .Text and the table has no such value")}}
    return ,$problems.ToArray()
}
$modelsDrift=Get-ModelsDriftProblems $modelsTable $classicValues.ToArray() $classicAssigned.ToArray()
foreach($pr in $modelsDrift){Write-Host "FINDING: $pr"}
Check ($modelsDrift.Count -eq 0 -and $classicAssigned.Count -gt 8) "every Models text value is a classic constant or template, and every classic .Text constant is in the table ($($classicAssigned.Count) assigned)"
$mutatedModels=[ordered]@{}; foreach($key in @($modelsTable.Keys)){$mutatedModels[$key]=[string]$modelsTable[$key]}
$mutatedModels['NoModels']='No models are downloaded'
Check ((Get-ModelsDriftProblems $mutatedModels $classicValues.ToArray() $classicAssigned.ToArray()).Count -ge 1) 'mutation check: a changed table value fails the Models drift pin'
$mutatedModels=[ordered]@{}; foreach($key in @($modelsTable.Keys)){$mutatedModels[$key]=[string]$modelsTable[$key]}
$mutatedModels['FreeFormat']='Free disk space: {0} GiB'
Check ((Get-ModelsDriftProblems $mutatedModels $classicValues.ToArray() $classicAssigned.ToArray()).Count -ge 1) 'mutation check: an edited template fails the Models drift pin'
Check ((Get-ModelsDriftProblems $modelsTable $classicValues.ToArray() @($classicAssigned.ToArray()+'A new caption')).Count -ge 1) 'mutation check: a new .Text literal in the classic code that the table lacks fails the Models drift pin'
# The frozen literal against the classic code, unconditional: each of the four functions must be found, and the literal passes the same drift pin.
foreach($cfn in $classicFns){ Check ((Get-AstFunction $classicAst $cfn).Count -eq 1) "the classic function $cfn is found in the window script" }
$mdFrozenDrift=Get-ModelsDriftProblems $modelsFrozen $classicValues.ToArray() $classicAssigned.ToArray()
foreach($pr in $mdFrozenDrift){Write-Host "FINDING: $pr"}
Check ($mdFrozenDrift.Count -eq 0 -and $classicAssigned.Count -gt 8) "the frozen Models literal equals the classic Models texts (every value is a classic constant or template, every classic .Text constant is in the literal; $($classicAssigned.Count) assigned)"
# 5b-delete-end

# The list models (pure), with the store functions shadowed. The real functions are taken from the file by AST; the text table is the real one.
$script:FastLlmUiFluentModelsText=$modelsTable
foreach($fnName in 'Get-FastLlmUiFluentModelsListModel','Get-FastLlmUiFluentComponentsListModel'){
    $def=Get-AstFunction $modelsAst $fnName
    Check ($def.Count -eq 1) "$fnName is defined once"
    . ([scriptblock]::Create($def[0].Extent.Text))
}
$script:storeState=@{models=@();leftovers=@();free=$null;throwModels=$false;throwLeftovers=$false;components=@();throwComponents=$false}
function Get-FastLlmInstalledModels { param($InstallRoot,$CatalogPath) if($script:storeState.throwModels){throw 'the catalog is unreadable'}; return @($script:storeState.models) }
function Get-FastLlmModelLeftovers { param($InstallRoot) if($script:storeState.throwLeftovers){throw 'no access'}; return @($script:storeState.leftovers) }
function Get-FastLlmModelStoreFreeBytes { param($InstallRoot) return $script:storeState.free }
function Format-FastLlmModelStoreGigabytes { param([int64]$Bytes) return ([double]$Bytes/1e9).ToString('0.0',[Globalization.CultureInfo]::InvariantCulture) }
function Get-FastLlmModelDisplayName { param($Model) return [string]$Model.name }
function Get-FastLlmComponentInventory { param($ComponentsPath,$InstallRoot) if($script:storeState.throwComponents){throw 'inventory failed'}; return @($script:storeState.components) }
function Get-FastLlmInstalledComponentRows { param([object[]]$Inventory) return @($Inventory|ForEach-Object{[pscustomobject]@{id=[string]$_.id;kind='engine';label=([string]$_.id+' (engine, 1.0) - 1.0 GB')}}) }
$fixtureCatalog=[pscustomobject]@{models=@([pscustomobject]@{id='m-a';name='Alpha'},[pscustomobject]@{id='m-b';name='Beta'})}
function New-ModelRow([string]$Id,[int64]$Bytes,[bool]$InUse,[string]$Reason){ return [pscustomobject]@{id=$Id;sizeBytes=$Bytes;inUse=$InUse;inUseReason=$Reason} }
$script:storeState.models=@()
$empty=Get-FastLlmUiFluentModelsListModel -Root 'C:\r' -File 'f' -Catalog $fixtureCatalog
Check (@($empty.rows).Count -eq 0 -and $empty.freeText -ceq '' -and $empty.leftoverEnabled -eq $false -and @($empty.leftoverNames).Count -eq 0 -and $empty.leftoverText -ceq '' -and $empty.message -ceq '') 'the list model of an empty store is empty, with no free text, leftovers or message'
$script:storeState.models=@((New-ModelRow 'm-a' 4300000000 $false ''),(New-ModelRow 'm-b' 12000000000 $true 'serving'))
$script:storeState.free=250000000000
$two=Get-FastLlmUiFluentModelsListModel -Root 'C:\r' -File 'f' -Catalog $fixtureCatalog
Check (@($two.rows).Count -eq 2 -and $two.rows[0].text -ceq 'Alpha  -  4.3 GB' -and $two.rows[0].removable -eq $true -and $two.rows[0].id -ceq 'm-a' -and $two.rows[0].name -ceq 'Alpha') 'a removable row has the classic row text'
Check ($two.rows[1].text -ceq 'Beta  -  12.0 GB  (in use: serving)' -and $two.rows[1].removable -eq $false -and $two.rows[1].inUseReason -ceq 'serving') 'an in-use row says why, and cannot be removed'
Check ($two.freeText -ceq 'Free disk space: 250.0 GB') 'the free space has the classic text'
$mutRemovable=Get-FastLlmUiFluentModelsListModel -Root 'C:\r' -File 'f' -Catalog $fixtureCatalog
Check (@($mutRemovable.rows|Where-Object{$_.inUseReason -cne '' -and $_.removable}).Count -eq 0) 'no in-use row is removable'
$modelsFnText=(Get-AstFunction $modelsAst 'Get-FastLlmUiFluentModelsListModel')[0].Extent.Text
$plantFn=$modelsFnText.Replace('removable = [bool] (-not $row.inUse)','removable = $true')
Check ($plantFn -cne $modelsFnText) 'the in-use plant matches the real text'
. ([scriptblock]::Create($plantFn))
$plantRows=Get-FastLlmUiFluentModelsListModel -Root 'C:\r' -File 'f' -Catalog $fixtureCatalog
Check (@($plantRows.rows|Where-Object{$_.inUseReason -cne '' -and $_.removable}).Count -ge 1) 'mutation check: a list model that makes an in-use row removable is caught by the no-in-use-removable check'
. ([scriptblock]::Create($modelsFnText))
$script:storeState.leftovers=@([pscustomobject]@{name='a.partial';sizeBytes=1000000000;locked=$false},[pscustomobject]@{name='b.partial';sizeBytes=500000000;locked=$true})
$left=Get-FastLlmUiFluentModelsListModel -Root 'C:\r' -File 'f' -Catalog $fixtureCatalog
Check ($left.leftoverEnabled -eq $true -and (@($left.leftoverNames) -join ',') -ceq 'a.partial' -and $left.leftoverText -ceq '2 leftover file(s), 1.5 GB') 'locked leftovers are counted and sized but never named for removal'
$script:storeState.free=$null
$noFree=Get-FastLlmUiFluentModelsListModel -Root 'C:\r' -File 'f' -Catalog $fixtureCatalog
Check ($noFree.freeText -ceq '') 'an unknown free space shows no free text'
$script:storeState.throwModels=$true; $script:storeState.throwLeftovers=$true
$bad=Get-FastLlmUiFluentModelsListModel -Root 'C:\r' -File 'f' -Catalog $fixtureCatalog
Check ($bad.message -ceq 'The model list could not be read: the catalog is unreadable' -and @($bad.rows).Count -eq 0 -and $bad.leftoverEnabled -eq $false) 'an unreadable list gives the list-read text and no rows; unreadable leftovers are ignored'
$script:storeState.throwModels=$false; $script:storeState.throwLeftovers=$false
$folder=Get-FastLlmUiFluentModelsListModel -Catalog $fixtureCatalog -RootError 'Illegal characters in path.'
Check ($folder.message -ceq 'The model list could not be read: Illegal characters in path.' -and @($folder.rows).Count -eq 0 -and $folder.freeText -ceq '') 'an unusable folder shows the list-read text and reads nothing'
$script:storeState.components=@([pscustomobject]@{id='vulkan'},[pscustomobject]@{id='hip'})
$comp=Get-FastLlmUiFluentComponentsListModel -Root 'C:\r' -File 'f'
Check (@($comp.rows).Count -eq 2 -and $comp.rows[0].id -ceq 'vulkan' -and $comp.rows[0].text -ceq 'vulkan (engine, 1.0) - 1.0 GB' -and $comp.message -ceq '') 'the component list model has the row id and label'
$script:storeState.throwComponents=$true
$compBad=Get-FastLlmUiFluentComponentsListModel -Root 'C:\r' -File 'f'
Check ($compBad.message -ceq 'The component list could not be read: inventory failed' -and @($compBad.rows).Count -eq 0) 'an unreadable component list gives the classic text'
Check ((Get-FastLlmUiFluentComponentsListModel -RootError 'bad folder').message -ceq 'The component list could not be read: bad folder') 'an unusable folder shows the component list-read text'
# ===== end PR 3b: the Models page pins (Task 6) =====

# ===== PR 3b review fix round 1: pins for the surviving mutants =====
$modelsLf=$modelsText.Replace("`r`n","`n")
$homeLf=$homeSrc.Replace("`r`n","`n")
function Get-FnAst([string]$Text,[string]$Name){
    $a=[System.Management.Automation.Language.Parser]::ParseInput($Text,[ref]$null,[ref]$null)
    return ,@($a.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name},$true))
}
function Test-InsideClause($Node,$Guard){ return ($Node.Extent.StartOffset -ge $Guard.Clauses[0].Item2.Extent.StartOffset -and $Node.Extent.EndOffset -le $Guard.Clauses[0].Item2.Extent.EndOffset) }

# B1 and C-a: the picker function writes the message only in the on branch (the Switch button enabled), and stores SwitchWas from the button.
function Get-PickerMessageFindings([string]$Text){
    $found=New-Object System.Collections.ArrayList
    $fn=Get-FnAst $Text 'Update-FastLlmUiFluentModelsPicker'
    if($fn.Count -ne 1){[void]$found.Add('the picker function is not defined once');return ,$found.ToArray()}
    $msg=@($fn[0].Body.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$m[''SwitchMessage''].Text'},$true))
    if($msg.Count -ne 1){[void]$found.Add("the picker function writes SwitchMessage.Text $($msg.Count) times, expected 1")}
    else{
        $p=$msg[0].Parent; $guard=$null
        while($null -ne $p -and $p -ne $fn[0]){ if($p -is [System.Management.Automation.Language.IfStatementAst]){$guard=$p;break}; $p=$p.Parent }
        if($null -eq $guard -or $guard.Clauses[0].Item1.Extent.Text -cnotmatch '\$script:switchButton\.Enabled' -or -not (Test-InsideClause $msg[0] $guard)){[void]$found.Add('the SwitchMessage write is not in the on branch of the if on $script:switchButton.Enabled (an off edge would wipe the request result)')}
    }
    $was=@($fn[0].Body.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$m[''SwitchWas'']'},$true))
    $en=@($fn[0].Body.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$enabled'},$true))
    if($was.Count -ne 1 -or $was[0].Right.Extent.Text -cne '$enabled' -or $en.Count -ne 1 -or $en[0].Right.Extent.Text -cnotmatch '^\[bool\]\s*\$script:switchButton\.Enabled$'){[void]$found.Add('SwitchWas is not assigned once from the Switch button Enabled')}
    return ,$found.ToArray()
}
$pmf=Get-PickerMessageFindings $modelsText
foreach($f in $pmf){Write-Host "FINDING: $f"}
Check ($pmf.Count -eq 0) 'the picker writes the switch message only in its on branch, and stores SwitchWas from the Switch button'
$msgLine="        # The picker's message is written only when the picker is computed: a switch-off edge (a successful Switch disables the button) must not wipe the request's result.`n        `$m['SwitchMessage'].Text = [string] `$picker.message`n"
Check ($modelsLf.Contains($msgLine)) 'the message write and its comment are found in the real text (the plant below moves them)'
$movedOut=$modelsLf.Replace($msgLine,'').Replace("    foreach (`$pickerItem in @(`$picker.items)) { `$null = `$list.Items.Add([string] `$pickerItem.text) }`n","    foreach (`$pickerItem in @(`$picker.items)) { `$null = `$list.Items.Add([string] `$pickerItem.text) }`n    `$m['SwitchMessage'].Text = [string] `$picker.message`n")
Check ($movedOut -cne $modelsLf -and (Get-PickerMessageFindings $movedOut).Count -ge 1) 'mutation check: the message write moved out of the on branch is flagged (B1)'
Check ((Get-PickerGuardFindings $movedOut $pickerWant).Count -ge 1) 'mutation check: the message write moved out of the guard fails the picker guard pin too (B1)'
Check ((Get-PickerMessageFindings $modelsLf.Replace("`$m['SwitchWas'] = `$enabled","`$null = `$enabled")).Count -ge 1) 'mutation check: SwitchWas not assigned is flagged (C-a)'
Check ((Get-PickerMessageFindings $modelsLf.Replace("`$m['SwitchWas'] = `$enabled","`$m['SwitchWas'] = `$true")).Count -ge 1) 'mutation check: SwitchWas assigned a constant is flagged (C-a)'

# B4: Enter wraps its body like Enter-FastLlmUiFluentConnect: one try, every call inside it, and a catch that shows the failure.
function Get-EnterWrapFindings([string]$Text){
    $found=New-Object System.Collections.ArrayList
    $fn=Get-FnAst $Text 'Enter-FastLlmUiFluentModels'
    if($fn.Count -ne 1){[void]$found.Add('Enter-FastLlmUiFluentModels is not defined once');return ,$found.ToArray()}
    $tries=@($fn[0].Body.FindAll({param($n) $n -is [System.Management.Automation.Language.TryStatementAst]},$true))
    if($tries.Count -ne 1 -or $tries[0].CatchClauses.Count -ne 1){[void]$found.Add('Enter has not exactly one try with one catch');return ,$found.ToArray()}
    $catchCalls=@($tries[0].CatchClauses[0].Body.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst]},$true)|Where-Object{[string]$_.GetCommandName() -ceq 'ShowFailure'})
    if($catchCalls.Count -ne 1 -or $catchCalls[0].Extent.Text -cne 'ShowFailure $_.Exception.Message'){[void]$found.Add('the catch is not ShowFailure $_.Exception.Message')}
    foreach($want in 'Update-FastLlmUiFluentModelsList','Update-FastLlmUiFluentComponentsList','Update-FastLlmUiFluentModelsPicker','Update-FastLlmUiFluentModels'){
        $inTry=@($tries[0].Body.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -ceq $want},$true))
        if($inTry.Count -ne 1){[void]$found.Add("$want is not called once inside the try")}
    }
    return ,$found.ToArray()
}
$ewf=Get-EnterWrapFindings $modelsText
foreach($f in $ewf){Write-Host "FINDING: $f"}
Check ($ewf.Count -eq 0) 'Enter-FastLlmUiFluentModels runs its body in a try whose catch is ShowFailure (as Connect Enter does)'
Check ((Get-EnterWrapFindings $modelsLf.Replace('    catch { ShowFailure $_.Exception.Message }','    catch { $null = $_ }')).Count -ge 1) 'mutation check: a catch that swallows the failure is flagged (B4)'
Check ((Get-EnterWrapFindings $modelsLf.Replace("        Update-FastLlmUiFluentModelsPicker`n        Update-FastLlmUiFluentModels`n    }`n    catch { ShowFailure `$_.Exception.Message }","        Update-FastLlmUiFluentModels`n    }`n    catch { ShowFailure `$_.Exception.Message }`n    Update-FastLlmUiFluentModelsPicker")).Count -ge 1) 'mutation check: a call moved out of the try is flagged (B4)'

# C-b: the tick hook, transitively. Every file-level function reachable from Update-FastLlmUiFluentModels is scanned; the only way to the picker is the edge-guarded if
# of the root itself (the picker is not entered by the walk: it is the one place the store is read).
$tickReachForbidden=$tickForbidden+@('Update-FastLlmUiFluentComponentsList','Get-FastLlmInstalledComponentRows','Get-FastLlmStatus','Get-FastLlmModelStoreFreeBytes')
function Get-TickReachFindings([string[]]$Texts,[string]$Root,[string[]]$Forbidden,[string]$Edge){
    $found=New-Object System.Collections.ArrayList
    $defs=@{}
    foreach($t in $Texts){
        $a=[System.Management.Automation.Language.Parser]::ParseInput($t,[ref]$null,[ref]$null)
        foreach($fd in @($a.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true))){ $defs[[string]$fd.Name]=$fd }
    }
    if(-not $defs.ContainsKey($Root)){return ,$found.ToArray()}
    $seen=@{}; $seen[$Root]=$true
    $queue=New-Object System.Collections.Queue
    $queue.Enqueue($Root)
    while($queue.Count -gt 0){
        $name=[string]$queue.Dequeue()
        $fd=$defs[$name]
        foreach($c in @($fd.Body.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst]},$true))){
            $cn=[string]$c.GetCommandName()
            if($cn -eq ''){continue}
            if($cn -ceq $Edge){
                $inIf=$false; $p=$c.Parent
                while($null -ne $p -and $p -ne $fd){ if($p -is [System.Management.Automation.Language.IfStatementAst]){$inIf=$true}; $p=$p.Parent }
                if($name -ceq $Root -and $inIf){continue}
                [void]$found.Add("$name calls $cn outside the edge-guarded if of $Root")
                continue
            }
            if($Forbidden -ccontains $cn){[void]$found.Add("$name (reached from $Root) calls $cn");continue}
            if($defs.ContainsKey($cn) -and -not $seen.ContainsKey($cn)){$seen[$cn]=$true;$queue.Enqueue($cn)}
        }
    }
    return ,$found.ToArray()
}
$treach=Get-TickReachFindings $rowTexts 'Update-FastLlmUiFluentModels' $tickReachForbidden 'Update-FastLlmUiFluentModelsPicker'
foreach($f in $treach){Write-Host "FINDING: $f"}
Check ($treach.Count -eq 0) 'no function reachable from the Models tick hook reads a store or builds a list, and the picker is reached only by the edge-guarded if'
$planted=[regex]::Replace($modelsLf,'\$enabled = \$false(\n    if \(\$null -ne \$picker)','$enabled = $false; Get-FastLlmStatus$1')
Check ($planted -cne $modelsLf -and (Get-TickReachFindings @($planted) 'Update-FastLlmUiFluentModels' $tickReachForbidden 'Update-FastLlmUiFluentModelsPicker').Count -ge 1) 'mutation check: Get-FastLlmStatus planted in Update-FastLlmUiFluentModelsSwitchState (two calls deep) is flagged (C-b)'
foreach($fb in 'Update-FastLlmUiFluentComponentsList','Get-FastLlmInstalledComponentRows','Get-FastLlmModelStoreFreeBytes'){
    $pl=[regex]::Replace($modelsLf,'\$enabled = \$false(\n    if \(\$null -ne \$picker)',('$enabled = $false; '+$fb+'$1'))
    Check ((Get-TickReachFindings @($pl) 'Update-FastLlmUiFluentModels' $tickReachForbidden 'Update-FastLlmUiFluentModelsPicker').Count -ge 1) "mutation check: $fb planted in the switch state helper is flagged (C-b)"
}
$plPicker=[regex]::Replace($modelsLf,'\$enabled = \$false(\n    if \(\$null -ne \$picker)','$enabled = $false; Update-FastLlmUiFluentModelsPicker$1')
Check ((Get-TickReachFindings @($plPicker) 'Update-FastLlmUiFluentModels' $tickReachForbidden 'Update-FastLlmUiFluentModelsPicker').Count -ge 1) 'mutation check: the picker called from the switch state helper (outside the root edge if) is flagged (C-b)'
Check ((Get-TickReachFindings @($modelsLf.Replace('if ([bool] $script:switchButton.Enabled -ne [bool] $m[''SwitchWas'']) { Update-FastLlmUiFluentModelsPicker }','Update-FastLlmUiFluentModelsPicker')) 'Update-FastLlmUiFluentModels' $tickReachForbidden 'Update-FastLlmUiFluentModelsPicker').Count -ge 1) 'mutation check: the picker called every tick in the root is flagged by the transitive walk (C-b)'

# C-d: the Picked lock. The Switch state needs -not Picked, and a successful Switch click sets it.
function Get-PickedLockFindings([string]$Text){
    $found=New-Object System.Collections.ArrayList
    $st=Get-FnAst $Text 'Update-FastLlmUiFluentModelsSwitchState'
    if($st.Count -ne 1 -or $st[0].Body.Extent.Text -cnotmatch 'if \(\$null -ne \$picker -and \[bool\] \$script:switchButton\.Enabled -and -not \[bool\] \$m\[''Picked''\]\) \{'){[void]$found.Add('the Switch state does not require -not $m[''Picked'']')}
    $now=Get-FnAst $Text 'Invoke-FastLlmUiFluentModelsSwitchNow'
    $set=@(); if($now.Count -eq 1){$set=@($now[0].Body.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$m[''Picked'']'},$true))}
    $ok=$false
    if($set.Count -eq 1 -and $set[0].Right.Extent.Text -ceq '$true'){
        $p=$set[0].Parent
        while($null -ne $p -and $p -ne $now[0]){ if($p -is [System.Management.Automation.Language.IfStatementAst] -and $p.Clauses[0].Item1.Extent.Text -ceq '$outcome.ok'){$ok=$true}; $p=$p.Parent }
    }
    if(-not $ok){[void]$found.Add('a successful Switch click does not set Picked inside the if on $outcome.ok')}
    return ,$found.ToArray()
}
$plf=Get-PickedLockFindings $modelsText
foreach($f in $plf){Write-Host "FINDING: $f"}
Check ($plf.Count -eq 0) 'the Switch state needs -not Picked and a successful Switch click sets Picked'
Check ((Get-PickedLockFindings $modelsLf.Replace(" -and -not [bool] `$m['Picked']",'')).Count -ge 1) 'mutation check: the Switch state without the -not Picked term is flagged (C-d)'
Check ((Get-PickedLockFindings $modelsLf.Replace("`$m['Picked'] = `$true","`$m['Picked'] = `$false")).Count -ge 1) 'mutation check: a Switch click that never sets Picked is flagged (C-d)'

# C-e: the view wiring. Each Remove's IsEnabled and help text come from the row, the leftover button's Tag is the leftover names, and the view's leftoverText is written.
function Get-ListWiringFindings([string]$Text){
    $found=New-Object System.Collections.ArrayList
    $ul=Get-FnAst $Text 'Update-FastLlmUiFluentModelsList'
    $row=Get-FnAst $Text 'New-FastLlmUiFluentModelsRow'
    if($ul.Count -ne 1 -or $row.Count -ne 1){[void]$found.Add('the list update or the row builder is not defined once');return ,$found.ToArray()}
    $u=$ul[0].Body.Extent.Text; $r=$row[0].Body.Extent.Text
    if($u -cnotmatch '-Enabled \(\[bool\] \$row\.removable\)'){[void]$found.Add('a model row''s Remove IsEnabled is not from the row removable')}
    if($u -cnotmatch '-Reason \(\[string\] \$row\.inUseReason\)'){[void]$found.Add('a model row''s help text is not from the row inUseReason')}
    if($r -cnotmatch '\$remove\.IsEnabled = \$Enabled\b'){[void]$found.Add('the row builder does not set IsEnabled from -Enabled')}
    if($r -cnotmatch 'SetHelpText\(\$remove, \$Reason\)'){[void]$found.Add('the row builder does not set the help text from -Reason')}
    if($u -cnotmatch '\$leftoverButton\.Tag = @\(\$model\.leftoverNames\)'){[void]$found.Add('the leftover button Tag is not the leftover names')}
    if($u -cnotmatch '\$view\[''leftoverText''\] = \[string\] \$model\.leftoverText'){[void]$found.Add('the view leftoverText is not assigned from the model')}
    if($u -cnotmatch 'ToolTip = \[string\] \$s\.WhyNoLeftovers' -or $u -cnotmatch 'SetHelpText\(\$leftoverButton, \[string\] \$s\.WhyNoLeftovers\)'){[void]$found.Add('the leftover button does not say WhyNoLeftovers (tooltip and help text) when disabled')}
    return ,$found.ToArray()
}
$lwf=Get-ListWiringFindings $modelsText
foreach($f in $lwf){Write-Host "FINDING: $f"}
Check ($lwf.Count -eq 0) 'the list update wires the Remove state, the leftover button and the view leftoverText from the model'
Check ((Get-ListWiringFindings $modelsLf.Replace('-Enabled ([bool] $row.removable)','-Enabled $true')).Count -ge 1) 'mutation check: a Remove with -Enabled $true is flagged (C-e)'
Check ((Get-ListWiringFindings $modelsLf.Replace('-Reason ([string] $row.inUseReason)','-Reason ''''')).Count -ge 1) 'mutation check: a Remove with no reason is flagged (C-e)'
Check ((Get-ListWiringFindings $modelsLf.Replace('$leftoverButton.Tag = @($model.leftoverNames)','$leftoverButton.Tag = @()')).Count -ge 1) 'mutation check: a leftover button with Tag = @() is flagged (C-e)'
Check ((Get-ListWiringFindings $modelsLf.Replace("    if (`$null -ne `$view) { `$view['leftoverText'] = [string] `$model.leftoverText }`n",'')).Count -ge 1) 'mutation check: the view leftoverText assignment deleted is flagged (C-e)'
Check ((Get-ListWiringFindings $modelsLf.Replace('$remove.IsEnabled = $Enabled','$remove.IsEnabled = $true')).Count -ge 1) 'mutation check: the row builder ignoring -Enabled is flagged (C-e)'

# C-f: the reasons. The rows are Choose and the four inputs (and the leftover button's own reason above), and each code reads its own string.
function Get-ReasonWiringFindings([string]$Text){
    $found=New-Object System.Collections.ArrayList
    $rows=Get-FnAst $Text 'Get-FastLlmUiFluentModelsReasonRows'
    if($rows.Count -ne 1){[void]$found.Add('the reason rows function is not defined once');return ,$found.ToArray()}
    $got=@($rows[0].Body.FindAll({param($n) $n -is [System.Management.Automation.Language.HashtableAst]},$true)|ForEach-Object{($_.Extent.Text -replace '\s+',' ')})
    $want=@("@{ Element = 'ModelsChooseButton'; Adapter = 'chooseButton'; Action = 'chooseSetup' }","@{ Element = 'ModelsModelBox'; Adapter = 'modelBox'; Action = 'startInputs' }","@{ Element = 'ModelsFolderBox'; Adapter = 'pathBox'; Action = 'startInputs' }","@{ Element = 'ModelsContextBox'; Adapter = 'contextBox'; Action = 'startInputs' }","@{ Element = 'ModelsBarBox'; Adapter = 'barBox'; Action = 'startInputs' }")
    if(($got -join '|') -cne ($want -join '|')){[void]$found.Add('the reason rows are not Choose and the four inputs (model, folder, context, BAR) in order')}
    $txt=Get-FnAst $Text 'Get-FastLlmUiFluentModelsReasonText'
    if($txt.Count -ne 1 -or $txt[0].Body.Extent.Text -cnotmatch "'background' \{ return \[string\] \`$s\.WhyBackgroundRun \}" -or $txt[0].Body.Extent.Text -cnotmatch "'no-preview' \{ return \[string\] \`$s\.WhyNoPreview \}"){[void]$found.Add('the reason codes background and no-preview do not map to WhyBackgroundRun and WhyNoPreview')}
    return ,$found.ToArray()
}
$rwf=Get-ReasonWiringFindings $modelsText
foreach($f in $rwf){Write-Host "FINDING: $f"}
Check ($rwf.Count -eq 0) 'the reason rows are Choose and the four inputs, and each Models reason code maps to its own string'
Check ((Get-ReasonWiringFindings $modelsLf.Replace("        @{ Element = 'ModelsBarBox';       Adapter = 'barBox';       Action = 'startInputs' }`n",'').Replace("Action = 'startInputs' },`n    )","Action = 'startInputs' }`n    )")).Count -ge 1) 'mutation check: the BAR box row dropped from the reason rows is flagged (C-f)'
Check ((Get-ReasonWiringFindings $modelsLf.Replace("'background' { return [string] `$s.WhyBackgroundRun }","'background' { return [string] `$s.WhyNoPreview }").Replace("'no-preview' { return [string] `$s.WhyNoPreview }","'no-preview' { return [string] `$s.WhyBackgroundRun }")).Count -ge 1) 'mutation check: WhyNoPreview swapped with WhyBackgroundRun is flagged (C-f)'

# B2: no fixed Width on a ComboBox, a TextBox or the context row in the Models markup (a fixed width clips at large text); a MinWidth is allowed.
function Get-FixedWidthFindings([string]$Xaml){
    $found=New-Object System.Collections.ArrayList
    $doc=New-Object System.Xml.XmlDocument; $doc.LoadXml($Xaml)
    $xn='http://schemas.microsoft.com/winfx/2006/xaml'
    foreach($node in @($doc.SelectNodes('//*'))){
        $nm=$node.GetAttribute('Name',$xn)
        if(($node.LocalName -in 'ComboBox','TextBox' -or $nm -ceq 'ModelsContextRow') -and $node.HasAttribute('Width')){[void]$found.Add("$($node.LocalName) $nm has a fixed Width")}
    }
    $row=@($doc.SelectNodes('//*')|Where-Object{$_.GetAttribute('Name',$xn) -ceq 'ModelsContextRow'})
    $bar=@($doc.SelectNodes('//*')|Where-Object{$_.GetAttribute('Name',$xn) -ceq 'ModelsBarBox'})
    if($row.Count -ne 1 -or $row[0].GetAttribute('MinWidth') -cne '260' -or $bar.Count -ne 1 -or $bar[0].GetAttribute('MinWidth') -cne '260'){[void]$found.Add('the context row and the BAR box do not both carry MinWidth 260')}
    return ,$found.ToArray()
}
$fwf=Get-FixedWidthFindings $modelsXaml
foreach($f in $fwf){Write-Host "FINDING: $f"}
Check ($fwf.Count -eq 0) 'the Models markup has no fixed Width on a ComboBox, a TextBox or the context row (MinWidth 260 on the row and the BAR box)'
Check ((Get-FixedWidthFindings $modelsXaml.Replace('<ComboBox x:Name="ModelsBarBox" HorizontalAlignment="Left" MinWidth="260"','<ComboBox x:Name="ModelsBarBox" HorizontalAlignment="Left" Width="260"')).Count -ge 1) 'mutation check: a fixed Width on the BAR box is flagged (B2)'
Check ((Get-FixedWidthFindings $modelsXaml.Replace('<Grid x:Name="ModelsContextRow" HorizontalAlignment="Left" MinWidth="260">','<Grid x:Name="ModelsContextRow" HorizontalAlignment="Left" Width="260">')).Count -ge 1) 'mutation check: a fixed Width on the context row is flagged (B2)'
Check ((Get-FixedWidthFindings $modelsXaml.Replace('<TextBox x:Name="ModelsFolderBox"','<TextBox Width="300" x:Name="ModelsFolderBox"')).Count -ge 1) 'mutation check: a fixed Width on a text box is flagged (B2)'
# The switch list scrolls by pixel (CanContentScroll False): its multi-line rows scroll smoothly, every row is realized (so every row has a peer), and its
# viewer's extent is in pixels, which the render harness's outside rule reads (CI round 1: item units made every row 'outside').
function Test-SwitchListPixelScroll([string]$Xaml){ return ([regex]::Match($Xaml,'<ListBox x:Name="ModelsSwitchList"[^>]*>').Value -cmatch 'ScrollViewer\.CanContentScroll="False"') }
Check (Test-SwitchListPixelScroll $modelsXaml) 'the Models switch list scrolls by pixel (ScrollViewer.CanContentScroll False)'
Check (-not (Test-SwitchListPixelScroll $modelsXaml.Replace(' ScrollViewer.CanContentScroll="False"',''))) 'mutation check: a switch list that scrolls by item is flagged'
# The leftover button's caption wraps inside the button at large text (CI round 1: clipped at text 2.25 in the 640 wide shell).
function Test-LeftoverCaptionWraps([string]$Text){
    return ($Text -cmatch '\$leftoverCaption = New-Object System\.Windows\.Controls\.AccessText' -and $Text -cmatch '\$leftoverCaption\.TextWrapping = \[System\.Windows\.TextWrapping\]::Wrap' -and $Text -cmatch "\`$Els\['ModelsLeftoverButton'\]\.Content = \`$leftoverCaption" -and $Text -cmatch "AutomationProperties\]::SetName\(\`$Els\['ModelsLeftoverButton'\], \[string\] \`$t\.RemoveLeftovers\)")
}
$modelsFileText=[IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.UiFluentModels.ps1'))
Check (Test-LeftoverCaptionWraps $modelsFileText) 'the leftover button caption is a wrapping AccessText'
Check (-not (Test-LeftoverCaptionWraps $modelsFileText.Replace('$leftoverCaption.TextWrapping = [System.Windows.TextWrapping]::Wrap','$leftoverCaption.TextWrapping = [System.Windows.TextWrapping]::NoWrap'))) 'mutation check: a leftover caption that does not wrap is flagged'
Check (-not (Test-LeftoverCaptionWraps $modelsFileText.Replace("[System.Windows.Automation.AutomationProperties]::SetName(`$Els['ModelsLeftoverButton'], [string] `$t.RemoveLeftovers)",''))) 'mutation check: a leftover button with AccessText content and no explicit name (an unnamed button, CI round 2) is flagged'

# B3: Home Change never loses the keyboard focus: a disabled or missing model box, or a box that still cannot take the focus, falls back to the Models pane item.
function Get-ChangeFallbackFindings([string]$Text){
    $found=New-Object System.Collections.ArrayList
    $fn=Get-FnAst $Text 'Invoke-FastLlmUiFluentHomeChange'
    if($fn.Count -ne 1){[void]$found.Add('Home Change is not defined once');return ,$found.ToArray()}
    $b=$fn[0].Body.Extent.Text
    if($b -cnotmatch "\`$nav = \`$script:FastLlmUiFluent\['Els'\]\['NavModels'\]"){[void]$found.Add('Change does not read the NavModels pane item')}
    if($b -cnotmatch 'if \(\$null -eq \$box -or -not \[bool\] \$box\.IsEnabled\) \{\s*if \(\$null -ne \$nav\) \{ \$null = \$nav\.Focus\(\) \}\s*return\s*\}'){[void]$found.Add('a missing or disabled model box does not move the focus to NavModels')}
    if($b -cnotmatch '\$focusLater = \{ if \(-not \[bool\] \$box\.Focus\(\) -and \$null -ne \$nav\) \{ \$null = \$nav\.Focus\(\) \} \}\.GetNewClosure\(\)'){[void]$found.Add('the deferred focus does not fall back to NavModels')}
    return ,$found.ToArray()
}
$cff=Get-ChangeFallbackFindings $homeSrc
foreach($f in $cff){Write-Host "FINDING: $f"}
Check ($cff.Count -eq 0) 'Home Change falls back to the NavModels pane item when the model box is disabled or cannot take the focus'
Check ((Get-ChangeFallbackFindings $homeLf.Replace("        if (`$null -ne `$nav) { `$null = `$nav.Focus() }`n        return`n","        return`n")).Count -ge 1) 'mutation check: Change without the disabled-box fallback is flagged (B3)'
Check ((Get-ChangeFallbackFindings $homeLf.Replace('$focusLater = { if (-not [bool] $box.Focus() -and $null -ne $nav) { $null = $nav.Focus() } }.GetNewClosure()','$focusLater = { $null = $box.Focus() }.GetNewClosure()')).Count -ge 1) 'mutation check: Change without the deferred fallback is flagged (B3)'
Check ((Get-ChangeFallbackFindings $homeLf.Replace('if ($null -eq $box -or -not [bool] $box.IsEnabled) {','if ($null -eq $box) {')).Count -ge 1) 'mutation check: Change that ignores a disabled box is flagged (B3)'
# D: the render harness hosts every page the way the Window hands text down. The shell Window's FontFamily, FontSize and Foreground resources and the host's three
# SetResourceReference calls must name the same resources, so the two cannot drift (read as text: the harness needs WPF to run, this pin does not).
function Get-HostTextFindings([string]$ShellMarkup,[string]$HarnessText){
    $found=New-Object System.Collections.ArrayList
    $m=[regex]::Match($ShellMarkup,"(?s)\`$script:FastLlmUiXaml\['FastLlm.Shell'\] = @'\r?\n(.*?)\r?\n'@")
    if(-not $m.Success){[void]$found.Add('the shell markup is not found');return ,$found.ToArray()}
    $root=([xml]$m.Groups[1].Value).DocumentElement
    $want=@{}
    foreach($pair in @(@('FontFamily','TextFont'),@('FontSize','BodySize'),@('Foreground','TextPrimaryBrush'))){
        $attr=$root.GetAttribute($pair[0])
        if($attr -cne ('{DynamicResource FastLlm.'+$pair[1]+'}')){[void]$found.Add("the shell Window $($pair[0]) is not {DynamicResource FastLlm.$($pair[1])}: $attr")}
        $want[$pair[0]]='FastLlm.'+$pair[1]
    }
    $got=@{}
    foreach($mm in [regex]::Matches($HarnessText,"\`$sv\.SetResourceReference\(\[System\.Windows\.Documents\.TextElement\]::(FontFamily|FontSize|Foreground)Property, '([^']+)'\)")){$got[$mm.Groups[1].Value]=$mm.Groups[2].Value}
    foreach($k in 'FontFamily','FontSize','Foreground'){
        if(-not $got.ContainsKey($k)){[void]$found.Add("the harness host has no $k reference")}
        elseif($got[$k] -cne $want[$k]){[void]$found.Add("the harness host $k names $($got[$k]), the Window uses $($want[$k])")}
    }
    if($HarnessText -cnotmatch '\$sv\.Resources = \$dict'){[void]$found.Add('the harness host does not take the case theme dictionary')}
    return ,$found.ToArray()
}
$harnessText=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'helpers/UiRenderHarness.ps1'))
$htf=Get-HostTextFindings $shellText $harnessText
foreach($f in $htf){Write-Host "FINDING: $f"}
Check ($htf.Count -eq 0) 'the render harness host and the shell Window name the same three text resources (family, size, colour)'
Check ((Get-HostTextFindings $shellText $harnessText.Replace("'FastLlm.BodySize')","'FastLlm.SubtitleSize')")).Count -ge 1) 'mutation check: a harness host size resource that differs from the Window is flagged (D)'
Check ((Get-HostTextFindings $shellText $harnessText.Replace("FontFamilyProperty, 'FastLlm.TextFont')","FontFamilyProperty, 'FastLlm.DisplayFont')")).Count -ge 1) 'mutation check: a harness host family resource that differs from the Window is flagged (D)'
Check ((Get-HostTextFindings $shellText $harnessText.Replace("ForegroundProperty, 'FastLlm.TextPrimaryBrush')","ForegroundProperty, 'FastLlm.TextSecondaryBrush')")).Count -ge 1) 'mutation check: a harness host colour resource that differs from the Window is flagged (D)'
Check ((Get-HostTextFindings $shellText $harnessText.Replace("    `$sv.SetResourceReference([System.Windows.Documents.TextElement]::FontSizeProperty, 'FastLlm.BodySize')`n","").Replace("    `$sv.SetResourceReference([System.Windows.Documents.TextElement]::FontSizeProperty, 'FastLlm.BodySize')`r`n","")).Count -ge 1) 'mutation check: a harness host without the size reference is flagged (D)'
Check ((Get-HostTextFindings $shellText.Replace('FontSize="{DynamicResource FastLlm.BodySize}"','FontSize="14"') $harnessText).Count -ge 1) 'mutation check: a Window with a literal font size is flagged (D)'
# ===== end PR 3b review fix round 1 =====

# ===== PR 3b: every new user-visible fluent string, exact text (lead gate F3/F9) =====
# The approved wording, written out here as literals (never read back from the table), so a one-character change to any of them fails on macOS.
# The Windows steps compare against the table entry and cannot see a changed string.
$approvedStrings3b=[ordered]@{
    ModelsStartWith        = 'Model to start with'
    ModelsStartOptions     = 'Start options'
    ModelsComponents       = 'Engine components'
    RemoveFormat           = 'Remove {0}'
    SpinUp                 = 'Increase'
    SpinDown               = 'Decrease'
    CopyFullOutputActivity = 'Copy full output (Activity)'
    WhyNoPreview           = 'Start once to preview a setup first'
    WhyBackgroundRun       = 'Available when the background run has ended'
    WhyNoLeftovers         = 'No leftover partial downloads were found'
    WhyBusy                = 'Available when the current task has finished'
}
# The string table's value for each key, read from the Home.ps1 AST (the [ordered]@{...} assigned to $script:FastLlmUiFluentStrings); $null when missing.
function Get-FluentStringTableValues([string]$Text){
    $ast=[System.Management.Automation.Language.Parser]::ParseInput($Text,[ref]$null,[ref]$null)
    $assign=@($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$script:FastLlmUiFluentStrings'},$true))
    $values=@{}
    if($assign.Count -ne 1){return $values}
    $table=@($assign[0].Right.FindAll({param($n) $n -is [System.Management.Automation.Language.HashtableAst]},$true))
    if($table.Count -lt 1){return $values}
    foreach($pair in $table[0].KeyValuePairs){
        $k=[string]$pair.Item1.Extent.Text
        $v=@($pair.Item2.FindAll({param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst]},$true))
        if($v.Count -eq 1){$values[$k]=[string]$v[0].Value}
    }
    return $values
}
function Get-ApprovedStringFindings([string]$Text){
    $f=New-Object System.Collections.ArrayList
    $actual=Get-FluentStringTableValues $Text
    foreach($k in $approvedStrings3b.Keys){
        if(-not $actual.ContainsKey($k)){[void]$f.Add("$k is missing from the string table");continue}
        if([string]$actual[$k] -cne [string]$approvedStrings3b[$k]){[void]$f.Add("$k is '$($actual[$k])', approved '$($approvedStrings3b[$k])'")}
    }
    return $f.ToArray()
}
$homeStringsText=[IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.UiFluentHome.ps1'))
$asf=@(Get-ApprovedStringFindings $homeStringsText)
foreach($x in $asf){Write-Host "FINDING: $x"}
Check ($asf.Count -eq 0) 'every new 3b user-visible fluent string (3 headings, Remove {0}, Increase/Decrease, Copy full output (Activity), the greyed reasons) is exactly its approved text'
Check (@(Get-ApprovedStringFindings $homeStringsText.Replace("'Available when the background run has ended'","'Available when the background run has finished'")).Count -ge 1) 'mutation check (lead F3): WhyBackgroundRun "has ended" changed to "has finished" is flagged'
Check (@(Get-ApprovedStringFindings $homeStringsText.Replace("'Remove {0}'","'Remove'")).Count -ge 1) 'mutation check (lead F9): RemoveFormat "Remove {0}" changed to "Remove" is flagged'
Check (@(Get-ApprovedStringFindings $homeStringsText.Replace("'Engine components'","'Engine component'")).Count -ge 1) 'mutation check: a one-character change to a heading is flagged'
Check (@(Get-ApprovedStringFindings $homeStringsText.Replace("    SpinDown             = 'Decrease'`n",'')).Count -ge 1 -or @(Get-ApprovedStringFindings $homeStringsText.Replace("    SpinDown             = 'Decrease'`r`n",'')).Count -ge 1) 'mutation check: a missing approved key is flagged'
# ===== end PR 3b: approved strings =====

# ===== PR 3c: every new user-visible fluent string, exact text (the 3b lead-gate rule, applied to 3c) =====
$approvedStrings3c=[ordered]@{
    SettingsServer     = 'Server'
    SettingsStarting   = 'Starting'
    SettingsComponents = 'Components and updates'
    Discard            = 'Discard'
    SavePrompt         = 'Save your changes?'
    DontSave           = "Don't save"
}
function Get-Approved3cStringFindings([string]$Text){
    $f=New-Object System.Collections.ArrayList
    $actual=Get-FluentStringTableValues $Text
    foreach($k in $approvedStrings3c.Keys){
        if(-not $actual.ContainsKey($k)){[void]$f.Add("$k is missing from the string table");continue}
        if([string]$actual[$k] -cne [string]$approvedStrings3c[$k]){[void]$f.Add("$k is '$($actual[$k])', approved '$($approvedStrings3c[$k])'")}
    }
    return $f.ToArray()
}
$as3c=@(Get-Approved3cStringFindings $homeStringsText)
foreach($x in $as3c){Write-Host "FINDING: $x"}
Check ($as3c.Count -eq 0) 'every new 3c user-visible fluent string (Server, Starting, Components and updates, Discard, Save your changes?, Don''t save) is exactly its approved text'
Check (@(Get-Approved3cStringFindings $homeStringsText.Replace("'Save your changes?'","'Save your changes'")).Count -ge 1) 'mutation check: the save prompt text changed by one character is flagged'
Check (@(Get-Approved3cStringFindings $homeStringsText.Replace('"Don''t save"','"Do not save"')).Count -ge 1) 'mutation check: the Don''t save caption reworded is flagged'
Check (@(Get-Approved3cStringFindings $homeStringsText.Replace("'Components and updates'","'Components & updates'")).Count -ge 1) 'mutation check: a heading reworded is flagged'
# ===== end PR 3c: approved strings =====

# ===== PR 4a: the box captions, exact text (lead ruling D3; the 3b lead-gate rule applied to 4a) =====
$approvedStrings4a=[ordered]@{ BoxOK = 'OK'; BoxCancel = 'Cancel'; BoxYes = 'Yes'; BoxNo = 'No' }
function Get-Approved4aStringFindings([string]$Text){
    $f=New-Object System.Collections.ArrayList
    $actual=Get-FluentStringTableValues $Text
    foreach($k in $approvedStrings4a.Keys){
        if(-not $actual.ContainsKey($k)){[void]$f.Add("$k is missing from the string table");continue}
        if([string]$actual[$k] -cne [string]$approvedStrings4a[$k]){[void]$f.Add("$k is '$($actual[$k])', approved '$($approvedStrings4a[$k])'")}
    }
    return $f.ToArray()
}
$as4a=@(Get-Approved4aStringFindings $homeStringsText)
foreach($x in $as4a){Write-Host "FINDING: $x"}
Check ($as4a.Count -eq 0) 'the four box captions (OK, Cancel, Yes, No) are exactly their approved text'
Check (@(Get-Approved4aStringFindings ($homeStringsText -replace "BoxNo(\s*)= 'No'","BoxNo`$1= 'no'")).Count -ge 1) 'mutation check: a box caption with a changed case is flagged'
Check (@(Get-Approved4aStringFindings ($homeStringsText -replace "BoxYes(\s*)= 'Yes'","BoxYes`$1= 'Yes '")).Count -ge 1) 'mutation check: a box caption with a trailing space is flagged'
# ===== end PR 4a: approved strings =====

# ===== PR 4a: dialog body controls follow the theme (4b review: a light native box in dark is the section 6 anti-goal) =====
function Get-DialogThemeFindings([string]$Text){
    $f=New-Object System.Collections.ArrayList
    $ast=[System.Management.Automation.Language.Parser]::ParseInput($Text,[ref]$null,[ref]$null)
    $readBox=@($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'New-FastLlmUiFluentDialogReadBox'},$true))
    if($readBox.Count -ne 1){[void]$f.Add('the read box function is missing');return $f.ToArray()}
    $rb=$readBox[0].Body.Extent.Text
    foreach($pair in @(@('Control]::BackgroundProperty','FastLlm.CardBrush'),@('Control]::ForegroundProperty','FastLlm.TextPrimaryBrush'),@('Control]::BorderBrushProperty','FastLlm.ControlStrongStrokeBrush'),@('TextBoxBase]::CaretBrushProperty','FastLlm.TextPrimaryBrush'))){
        if($rb -cnotmatch ([regex]::Escape($pair[0])+", '"+[regex]::Escape($pair[1])+"'")){[void]$f.Add("the read box does not take $($pair[1]) for $($pair[0])")}
    }
    $guide=@($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Show-FastLlmUiFluentDriverGuidance'},$true))
    if($guide.Count -ne 1 -or $guide[0].Body.Extent.Text -cnotmatch [regex]::Escape("`$devices.SetResourceReference([System.Windows.FrameworkElement]::StyleProperty, 'FastLlm.ComboBoxStyle')")){[void]$f.Add('the driver guidance device list does not take the Fluent ComboBox style')}
    return $f.ToArray()
}
$dlgThemeText=[IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.UiFluentDialogs.ps1'))
$dtf=@(Get-DialogThemeFindings $dlgThemeText)
foreach($x in $dtf){Write-Host "FINDING: $x"}
Check ($dtf.Count -eq 0) 'the dialog read box takes the theme brushes and the driver guidance device list takes the Fluent ComboBox style'
Check (@(Get-DialogThemeFindings $dlgThemeText.Replace("BackgroundProperty, 'FastLlm.CardBrush'","BackgroundProperty, 'FastLlm.LayerBrush'")).Count -ge 1) 'mutation check: a read box with another background is flagged'
Check (@(Get-DialogThemeFindings $dlgThemeText.Replace("`$devices.SetResourceReference([System.Windows.FrameworkElement]::StyleProperty, 'FastLlm.ComboBoxStyle')",'')).Count -ge 1) 'mutation check: a device list without the Fluent style is flagged'
# ===== end PR 4a: dialog theme =====


# ===== PR 3c: Settings pins (Task 2) =====
# Written RED before the page: the pins that read src/FastLlm.UiFluentSettings.ps1 fail until the page exists (Task 4). Every pin also runs against an
# embedded, well formed sample (or the real shell, Home and Form text) with planted mutations, so the pin itself is proven to flag each mutant on every platform.
$LA='System.Management.Automation.Language'
function ConvertTo-PinAst([string]$Text){ return [System.Management.Automation.Language.Parser]::ParseInput($Text,[ref]$null,[ref]$null) }
function Get-OptionalText([string]$Rel){ $p=Join-Path $root $Rel; if(Test-Path -LiteralPath $p){return [IO.File]::ReadAllText($p)}; return '' }
function Get-EnclosingFunctionAst($Node){ $p=$Node.Parent; while($null -ne $p -and $p -isnot [System.Management.Automation.Language.FunctionDefinitionAst]){$p=$p.Parent}; return $p }
$settingsText=Get-OptionalText 'src/FastLlm.UiFluentSettings.ps1'
$homeText=Get-OptionalText 'src/FastLlm.UiFluentHome.ps1'

# ---- (1) The effect-sequence pin: a two-segment projection of today's Save against the fluent copy ----
# Projection: the calls named below (Invoke-FastLlmApiKeySetting with its -Action value), [Windows.Forms.MessageBox]::Show with its title, icon and whether its
# text went through ConvertTo-FastLlmKeyFreeText (keyfree or raw; the key-free call itself is that flag, so computing it a second time for the key row is fluent-only), and the assignments to $script:apiKeyStore and $script:uiSettings.allowSwitch, in execution order (a call is
# after the calls inside its own arguments). Fluent-only statements (the availability guard, the key-row mark, the reload) are not projected.
# The serving write is projected by name; the four Settings additions (-KvContextProfile, -KvSlots, -Embeddings, -EmbeddingPort) are fluent-only ARGUMENTS of that same call
# (classic never passes them) and are pinned argument by argument in the Settings additions block (Get-SaSaveArgFindings), with the same-port guard.
$fxCommands=@('Get-FastLlmUiApiKeySaveAction','Get-FastLlmUiApiKeyChoiceText','Invoke-FastLlmApiKeySetting','NewUiApiKey','Set-FastLlmServingSettings','Set-FastLlmUiAllowSwitch','RefreshUiSwitchState','Get-FastLlmUiSettingsSavedNote','Get-FastLlmUiChatPageOffNote','ShowFailure')
function Test-FxKeyFree($Show,$Message=$null){
    $msg=$Message
    if($null -eq $msg){
        $callArgs=@($Show.Arguments); if($callArgs.Count -lt 2){return $false}
        $msg=$callArgs[1]
    }
    $isCtf={param($n) $n -is [System.Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -ceq 'ConvertTo-FastLlmKeyFreeText'}
    if(@($msg.FindAll($isCtf,$true)).Count -gt 0){return $true}
    $vars=@($msg.FindAll({param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst]},$true))
    if($vars.Count -ne 1){return $false}
    $fn=Get-EnclosingFunctionAst $Show
    if($null -eq $fn){return $false}
    $name=([string]$vars[0].VariablePath.UserPath).ToLowerInvariant()
    foreach($asg in @($fn.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.VariableExpressionAst]},$true))){
        if(([string]$asg.Left.VariablePath.UserPath).ToLowerInvariant() -ceq $name -and @($asg.Right.FindAll($isCtf,$true)).Count -gt 0){return $true}
    }
    return $false
}
function Get-EffectSequence($Scope){
    $rows=New-Object System.Collections.ArrayList
    $nodes=@($Scope.FindAll({param($x) $x -is [System.Management.Automation.Language.CommandAst] -or $x -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -or $x -is [System.Management.Automation.Language.AssignmentStatementAst]},$true))
    foreach($n in $nodes){
        $tok=$null
        if($n -is [System.Management.Automation.Language.CommandAst]){
            $name=[string]$n.GetCommandName()
            if($fxCommands -ccontains $name){
                $tok=$name
                if($name -ceq 'Invoke-FastLlmApiKeySetting'){
                    $act='?'; $els=@($n.CommandElements)
                    for($i=1;$i -lt $els.Count;$i++){
                        if($els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and [string]$els[$i].ParameterName -ceq 'Action'){
                            if($null -ne $els[$i].Argument){$act=$els[$i].Argument.Extent.Text}elseif($i+1 -lt $els.Count){$act=$els[$i+1].Extent.Text}
                        }
                    }
                    $tok="$name -Action $act"
                }
            }
            elseif($name -ceq 'Show-FastLlmUiFluentMessageBox'){
                # The fluent box projects as the system box it replaces: the same caption, icon and key-free state, read from its named arguments (Text, Caption, Icon).
                $named=@{}; $els=@($n.CommandElements)
                for($i=1;$i -lt $els.Count;$i++){
                    if($els[$i] -is [System.Management.Automation.Language.CommandParameterAst]){
                        $pn=([string]$els[$i].ParameterName).ToLowerInvariant()
                        if($null -ne $els[$i].Argument){$named[$pn]=$els[$i].Argument}elseif($i+1 -lt $els.Count){$named[$pn]=$els[$i+1]}
                    }
                }
                $title='?'; $icon='?'; $keyFree=$false
                if($named.ContainsKey('caption')){$title=$named['caption'].Extent.Text}
                if($named.ContainsKey('icon')){$icon=$named['icon'].Extent.Text}
                if($named.ContainsKey('text')){$keyFree=[bool](Test-FxKeyFree $n $named['text'])}
                $tok='MessageBox '+$title+' '+$icon+$(if($keyFree){' keyfree'}else{' raw'})
            }
        }
        elseif($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst]){
            if($n.Static -and $n.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and [string]$n.Expression.TypeName.Name -cmatch '(^|\.)MessageBox$' -and $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and [string]$n.Member.Value -ceq 'Show'){
                $a=@($n.Arguments)
                $title='?'; $icon='?'; if($a.Count -ge 5){$title=$a[2].Extent.Text;$icon=$a[4].Extent.Text}
                $tok='MessageBox '+$title+' '+$icon+$(if(Test-FxKeyFree $n){' keyfree'}else{' raw'})
            }
        }
        else{
            $left=($n.Left.Extent.Text -replace '\s','')
            if($left -ceq '$script:apiKeyStore'){$tok='assign $script:apiKeyStore'+$(if($n.Right.Extent.Text -ceq '$null'){'=$null'}else{'=?'})}
            elseif($left -ceq '$script:uiSettings.allowSwitch'){$tok='assign $script:uiSettings.allowSwitch'}
        }
        if($null -ne $tok){[void]$rows.Add([pscustomobject]@{Tok=$tok;End=$n.Extent.EndOffset;Start=$n.Extent.StartOffset})}
    }
    $ordered=@($rows|Sort-Object -Property @{Expression={$_.End}},@{Expression={$_.Start};Descending=$true})
    $out=New-Object System.Collections.ArrayList
    foreach($r in $ordered){ [void]$out.Add([string]$r.Tok) }
    return ,$out.ToArray()
}
function Get-EffectFindings([string]$Text,$Classic){
    $found=New-Object System.Collections.ArrayList
    $a=ConvertTo-PinAst $Text
    $fns=@($a.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Invoke-FastLlmUiFluentSettingsSave'},$true))
    if($fns.Count -ne 1){[void]$found.Add("Invoke-FastLlmUiFluentSettingsSave is defined $($fns.Count) times, expected 1");return ,$found.ToArray()}
    $tries=@($fns[0].Body.EndBlock.Statements|Where-Object{$_ -is [System.Management.Automation.Language.TryStatementAst]})
    if($tries.Count -lt 2){[void]$found.Add("the Save copy has $($tries.Count) top-level try statements, expected the save try first and the after-OK try last");return ,$found.ToArray()}
    foreach($tr in $tries){ if(@($tr.CatchClauses).Count -ne 1){[void]$found.Add('a top-level try of the Save copy has no single catch')} }
    if($found.Count -gt 0){return ,$found.ToArray()}
    # A try between them (the reload of the settings) has no effect of the projection in its body.
    for($m=1;$m -lt $tries.Count-1;$m++){ $mid=(Get-EffectSequence $tries[$m].Body) -join ' | '; if($mid -ne ''){[void]$found.Add("a top-level try between the save try and the after-OK try has projected effects: $mid")} }
    $last=$tries.Count-1
    $pairs=@(@('save try',$tries[0].Body,'Try'),@('refusal catch',$tries[0].CatchClauses[0].Body,'Catch'),@('after-OK block',$tries[$last].Body,'Ok'),@('after-OK failure path',$tries[$last].CatchClauses[0].Body,'WrapCatch'))
    foreach($p in $pairs){
        $got=(Get-EffectSequence $p[1]) -join ' | '
        $want=@($Classic[$p[2]]) -join ' | '
        if($got -cne $want){[void]$found.Add("effect sequence of the $($p[0]) differs from today's: got [$got], want [$want]")}
    }
    return ,$found.ToArray()
}
# The frozen effect sequences of today's Save closure (the try), its refusal catch, the after-OK block and the click wrapper's failure path, as literal token lists.
# The tokens are the projection of Get-EffectSequence; the check against the classic closure is below the pin (deleted with the dialog at the flip).
$effectFrozen=@{
    Try=@('Get-FastLlmUiApiKeySaveAction','Get-FastLlmUiApiKeyChoiceText','Invoke-FastLlmApiKeySetting -Action on','NewUiApiKey','Invoke-FastLlmApiKeySetting -Action on','Invoke-FastLlmApiKeySetting -Action off','assign $script:apiKeyStore=$null','Set-FastLlmServingSettings','Set-FastLlmUiAllowSwitch','assign $script:uiSettings.allowSwitch')
    Catch=@('MessageBox ''FastLLM settings'' ''Warning'' keyfree')
    Ok=@('RefreshUiSwitchState','Get-FastLlmUiSettingsSavedNote','Get-FastLlmUiChatPageOffNote','MessageBox ''FastLLM settings'' ''Information'' raw')
    WrapCatch=@('ShowFailure')
}
Check ($effectFrozen.Try.Count -eq 10 -and $effectFrozen.Catch.Count -eq 1 -and $effectFrozen.Ok.Count -eq 4 -and $effectFrozen.WrapCatch.Count -eq 1) 'the frozen effect sequences hold the ten save steps, the one refusal box, the four after-OK steps and ShowFailure'
$fxGood=@'
function Invoke-FastLlmUiFluentSettingsSave {
    $null = $script:settingsPortCommit
    if (-not [bool] $script:settingsButton.Enabled) { return $false }
    $before = $current
    $stage = 'key'
    try {
        $keyAction = Get-FastLlmUiApiKeySaveAction -Current ([string] $current.apiKey) -Undetermined ([bool] $current.apiKeyUndetermined) -BoxState (ConvertTo-FastLlmUiKeyBoxState -IsChecked $x) -Touched ([bool] $held.keyTouched)
        if ($keyAction -ceq 'ask') { throw (Get-FastLlmUiApiKeyChoiceText) }
        if ($keyAction -ceq 'on') {
            try { $null = Invoke-FastLlmApiKeySetting -InstallRoot $script:installPath -Action on }
            catch {
                if ([string] $_.Exception.Data['FastLlmFailureCode'] -cne 'api-key-unavailable') { throw }
                if (-not (NewUiApiKey $script:form)) { throw 'not turned on' }
                $null = Invoke-FastLlmApiKeySetting -InstallRoot $script:installPath -Action on
            }
        }
        elseif ($keyAction -ceq 'off') {
            $null = Invoke-FastLlmApiKeySetting -InstallRoot $script:installPath -Action off
        }
        $stage = 'serving'
        $script:apiKeyStore = $null
        Set-FastLlmServingSettings -InstallRoot $script:installPath -ServerPort 1
        Set-FastLlmUiAllowSwitch -InstallRoot $script:settingsRoot -Value $true
        $script:uiSettings.allowSwitch = $true
    }
    catch {
        $saveFailureText = [string] $_.Exception.Message
        [void] [Windows.Forms.MessageBox]::Show($script:form, (ConvertTo-FastLlmKeyFreeText -Text ([ref] $saveFailureText)), 'FastLLM settings', 'OK', 'Warning')
        return $false
    }
    $null = Update-Reload
    try {
        RefreshUiSwitchState
        $runActive = $true
        $script:statusLabel.Text = Get-FastLlmUiSettingsSavedNote -RunActive $runActive -Before $before -After $after
        if ($chatWasOn) { $script:statusLabel.Text = ([string] $script:statusLabel.Text + ' ' + (Get-FastLlmUiChatPageOffNote -Port 1)) }
        if ($runActive) { [void] [Windows.Forms.MessageBox]::Show($script:form, [string] $script:statusLabel.Text, 'FastLLM settings', 'OK', 'Information') }
    }
    catch { ShowFailure $_.Exception.Message }
    return $true
}
'@
$fxGoodFindings=Get-EffectFindings $fxGood $effectFrozen
foreach($f in $fxGoodFindings){Write-Host "FINDING: $f"}
Check ($fxGoodFindings.Count -eq 0) 'self-check: a well formed Save copy has today''s effect sequence in both segments'
function Edit-FxPlant([string]$From,[string]$To){ if($fxGood.IndexOf($From,[StringComparison]::Ordinal) -lt 0){throw "FAIL: plant anchor missing: $From"}; return $fxGood.Replace($From,$To) }
$fxServingLine="        Set-FastLlmServingSettings -InstallRoot `$script:installPath -ServerPort 1`n"
$fxSwitchLine="        Set-FastLlmUiAllowSwitch -InstallRoot `$script:settingsRoot -Value `$true`n"
$fxPlants=[ordered]@{
    'serving written before the key decision'=(Edit-FxPlant "    try {`n        `$keyAction" ("    try {`n"+$fxServingLine+"        `$keyAction")).Replace("        `$script:apiKeyStore = `$null`n"+$fxServingLine,"        `$script:apiKeyStore = `$null`n")
    'the store clear dropped'=(Edit-FxPlant "        `$script:apiKeyStore = `$null`n" '')
    'the switch saved before serving'=(Edit-FxPlant ($fxServingLine+$fxSwitchLine) ($fxSwitchLine+$fxServingLine))
    'the chat-off note dropped'=(Edit-FxPlant "        if (`$chatWasOn) { `$script:statusLabel.Text = ([string] `$script:statusLabel.Text + ' ' + (Get-FastLlmUiChatPageOffNote -Port 1)) }`n" '')
    '-Action on became rotate'=(Edit-FxPlant 'try { $null = Invoke-FastLlmApiKeySetting -InstallRoot $script:installPath -Action on }' 'try { $null = Invoke-FastLlmApiKeySetting -InstallRoot $script:installPath -Action rotate }')
    'the refusal box without the key-free text'=(Edit-FxPlant '(ConvertTo-FastLlmKeyFreeText -Text ([ref] $saveFailureText))' '$saveFailureText')
    'the refusal box icon changed'=(Edit-FxPlant "'FastLLM settings', 'OK', 'Warning')" "'FastLLM settings', 'OK', 'Error')")
    'the after-OK block moved into the save try'=(Edit-FxPlant "        `$script:uiSettings.allowSwitch = `$true`n    }" "        `$script:uiSettings.allowSwitch = `$true`n        RefreshUiSwitchState`n    }").Replace("    try {`n        RefreshUiSwitchState`n        `$runActive","    try {`n        `$runActive")
    'ShowFailure dropped from the after-OK path'=(Edit-FxPlant 'catch { ShowFailure $_.Exception.Message }' 'catch { $null = $_ }')
    'the new-key offer dropped'=(Edit-FxPlant "                if (-not (NewUiApiKey `$script:form)) { throw 'not turned on' }`n" '')
    'an effect hidden in a try between the two'=(Edit-FxPlant "    `$null = Update-Reload`n" "    try { RefreshUiSwitchState } catch { `$null = `$_ }`n")
    'the key decision dropped'=(Edit-FxPlant "        `$keyAction = Get-FastLlmUiApiKeySaveAction -Current ([string] `$current.apiKey) -Undetermined ([bool] `$current.apiKeyUndetermined) -BoxState (ConvertTo-FastLlmUiKeyBoxState -IsChecked `$x) -Touched ([bool] `$held.keyTouched)" "        `$keyAction = 'on'")
}
foreach($k in $fxPlants.Keys){
    Check ($fxPlants[$k] -cne $fxGood -and (Get-EffectFindings $fxPlants[$k] $effectFrozen).Count -ge 1) "mutation check: the effect-sequence pin flags: $k"
}
# The fluent box is the same effect as the system box: the well formed copy with both boxes as Show-FastLlmUiFluentMessageBox has no finding, and its mutants are flagged.
$fxFluent=$fxGood.Replace("[void] [Windows.Forms.MessageBox]::Show(`$script:form, (ConvertTo-FastLlmKeyFreeText -Text ([ref] `$saveFailureText)), 'FastLLM settings', 'OK', 'Warning')","[void] (Show-FastLlmUiFluentMessageBox -Owner `$script:form -Text (ConvertTo-FastLlmKeyFreeText -Text ([ref] `$saveFailureText)) -Caption 'FastLLM settings' -Buttons 'OK' -Icon 'Warning')").Replace("[void] [Windows.Forms.MessageBox]::Show(`$script:form, [string] `$script:statusLabel.Text, 'FastLLM settings', 'OK', 'Information')","[void] (Show-FastLlmUiFluentMessageBox -Owner `$script:form -Text ([string] `$script:statusLabel.Text) -Caption 'FastLLM settings' -Buttons 'OK' -Icon 'Information')")
Check ($fxFluent -cne $fxGood -and $fxFluent.Contains('Show-FastLlmUiFluentMessageBox') -and -not $fxFluent.Contains('MessageBox]::Show')) 'self-check: the fluent variant of the well formed Save copy uses only the fluent box'
$fxFluentFindings=Get-EffectFindings $fxFluent $effectFrozen
foreach($f in $fxFluentFindings){Write-Host "FINDING: $f"}
Check ($fxFluentFindings.Count -eq 0) 'self-check: the fluent box projects as the classic box (same caption, icon and key-free state, no finding)'
$fxFluentPlants=[ordered]@{
    'fluent refusal box without the key-free text'=$fxFluent.Replace('-Text (ConvertTo-FastLlmKeyFreeText -Text ([ref] $saveFailureText))','-Text $saveFailureText')
    'fluent refusal box icon changed'=$fxFluent.Replace("-Caption 'FastLLM settings' -Buttons 'OK' -Icon 'Warning'","-Caption 'FastLLM settings' -Buttons 'OK' -Icon 'Error'")
    'fluent refusal box caption changed'=$fxFluent.Replace("-Caption 'FastLLM settings' -Buttons 'OK' -Icon 'Warning'","-Caption 'Settings' -Buttons 'OK' -Icon 'Warning'")
    'fluent after-OK box icon changed'=$fxFluent.Replace("-Icon 'Information'","-Icon 'Warning'")
    'fluent after-OK box dropped'=$fxFluent.Replace("if (`$runActive) { [void] (Show-FastLlmUiFluentMessageBox -Owner `$script:form -Text ([string] `$script:statusLabel.Text) -Caption 'FastLLM settings' -Buttons 'OK' -Icon 'Information') }",'')
    'fluent refusal box without its text'=$fxFluent.Replace('-Text (ConvertTo-FastLlmKeyFreeText -Text ([ref] $saveFailureText)) ','')
}
foreach($k in $fxFluentPlants.Keys){
    Check ($fxFluentPlants[$k] -cne $fxFluent -and (Get-EffectFindings $fxFluentPlants[$k] $effectFrozen).Count -ge 1) "mutation check: the effect-sequence pin flags: $k"
}
$fxReal=Get-EffectFindings $settingsText $effectFrozen
foreach($f in $fxReal){Write-Host "FINDING: $f"}
Check ($settingsText -ne '' -and $fxReal.Count -eq 0) 'the Settings page Save copy has the effect sequence of today''s Save and after-OK block (two segments)'
# 5b-delete-begin
function Get-ClassicEffectParts($Ast){
    $parts=@{}
    $bd=@($Ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'BuildUiSettingsDialog'},$true))
    $show=@($Ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'ShowUiSettings'},$true))
    if($bd.Count -ne 1 -or $show.Count -ne 1){return $null}
    $click=@($bd[0].FindAll({param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$n.Member.Value -ceq 'Add_Click' -and $n.Expression.Extent.Text -ceq '$saveButton'},$true))
    if($click.Count -ne 1){return $null}
    $try=@($click[0].Arguments[0].ScriptBlock.EndBlock.Statements)[0]
    $okIf=@($show[0].FindAll({param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -cmatch "-ceq 'OK'"},$true))
    $wrap=@($Ast.FindAll({param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$n.Member.Value -ceq 'Add_Click' -and $n.Expression.Extent.Text -ceq '$settingsButton'},$true))
    if($try -isnot [System.Management.Automation.Language.TryStatementAst] -or $okIf.Count -ne 1 -or $wrap.Count -ne 1){return $null}
    $wtry=@($wrap[0].Arguments[0].ScriptBlock.EndBlock.Statements)[0]
    $parts['Try']=Get-EffectSequence $try.Body
    $parts['Catch']=Get-EffectSequence $try.CatchClauses[0].Body
    $parts['Ok']=Get-EffectSequence $okIf[0].Clauses[0].Item2
    $parts['WrapCatch']=Get-EffectSequence $wtry.CatchClauses[0].Body
    return $parts
}
$classicParts=Get-ClassicEffectParts $classicAst
Check ($null -ne $classicParts) 'the classic Save closure, the OK block and the settingsButton wrapper are found by AST'
foreach($fxPart in 'Try','Catch','Ok','WrapCatch'){ Check ($null -ne $classicParts -and (@($classicParts[$fxPart]) -join ' | ') -ceq (@($effectFrozen[$fxPart]) -join ' | ')) "the frozen $fxPart effect sequence equals the classic one" }
Check ((@($classicParts['Try']) -join ' | ') -ceq 'Get-FastLlmUiApiKeySaveAction | Get-FastLlmUiApiKeyChoiceText | Invoke-FastLlmApiKeySetting -Action on | NewUiApiKey | Invoke-FastLlmApiKeySetting -Action on | Invoke-FastLlmApiKeySetting -Action off | assign $script:apiKeyStore=$null | Set-FastLlmServingSettings | Set-FastLlmUiAllowSwitch | assign $script:uiSettings.allowSwitch') 'the classic save try projects to the ten steps (key decision, key write, store cleared, serving, switch)'
Check ((@($classicParts['Catch']) -join ' | ') -ceq "MessageBox 'FastLLM settings' 'Warning' keyfree") 'the classic refusal catch projects to the one Warning box whose text is key-free'
Check ((@($classicParts['Ok']) -join ' | ') -ceq "RefreshUiSwitchState | Get-FastLlmUiSettingsSavedNote | Get-FastLlmUiChatPageOffNote | MessageBox 'FastLLM settings' 'Information' raw" -and (@($classicParts['WrapCatch']) -join ' | ') -ceq 'ShowFailure') 'the classic after-OK block and the click wrapper project to the refresh, the notes, the Information box and ShowFailure'
# 5b-delete-end

# ---- (2) The mapping pin: held values to saved values, and saved values to held ones, for every input, from the classic AST and the fluent functions ----
function Get-PinFunctionText([string]$Rel,[string]$Name){
    $p=Join-Path $root $Rel
    if(-not (Test-Path -LiteralPath $p)){return ''}
    $fnDef=@((Get-FileAst $p).FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name},$true))
    if($fnDef.Count -ne 1){return ''}
    return [string]$fnDef[0].Extent.Text
}
$mapFromText=Get-PinFunctionText 'src/FastLlm.UiState.ps1' 'ConvertFrom-FastLlmUiSettingsHeld'
$mapToText=Get-PinFunctionText 'src/FastLlm.UiState.ps1' 'ConvertTo-FastLlmUiSettingsHeld'
$mapBoxText=Get-PinFunctionText 'src/FastLlm.UiFlow.ps1' 'Get-FastLlmUiApiKeyBoxState'
$mapFrom=($mapFromText -ne ''); $mapTo=($mapToText -ne ''); $mapBox=($mapBoxText -ne '')
if($mapFrom){ . ([scriptblock]::Create($mapFromText)) }
if($mapTo){ . ([scriptblock]::Create($mapToText)) }
if($mapBox){ . ([scriptblock]::Create($mapBoxText)) }
Check ($mapFrom -and $mapTo -and $mapBox) 'ConvertFrom-FastLlmUiSettingsHeld, ConvertTo-FastLlmUiSettingsHeld and Get-FastLlmUiApiKeyBoxState are each defined once'
# The frozen expectations of today's dialog expressions, one table per expression and input: what the held value saves as (thinking, idle, port, chat, switch) and
# what each saved value is held as (thinking, idle, chat, port). The check against the classic dialog expressions is below the pin (deleted at the flip).
$mapWantFrozen=@{
    Thinking=@{'-1'='auto';'0'='auto';'1'='off';'2'='auto'}
    Idle=@{'-1'=0;'0'=0;'1'=15;'2'=30;'3'=60}
    Port=@{'1024'=1024;'11434'=11434;'65535'=65535}
    Chat=@{'True'='on';'False'='off'}
    Switch=@{'True'=$true;'False'=$false}
    InitThinking=@{'auto'=0;'off'=1;'weird'=0;''=0}
    InitIdle=@{'0'=0;'15'=1;'30'=2;'60'=3;'45'=0;'-1'=0;'999'=0}
    InitChat=@{'on'=$true;'off'=$false;''=$false}
    InitPort=@{'8080'=8080}
}
function Get-MappingDisagreements([scriptblock]$From,[scriptblock]$To,$Want){
    $bad=New-Object System.Collections.ArrayList
    foreach($port in 1024,11434,65535){foreach($think in -1,0,1,2){foreach($chat in $true,$false){foreach($idle in -1,0,1,2,3){foreach($sw in $true,$false){
        $held=[pscustomobject]@{port=$port;thinkingIndex=$think;chatPage=$chat;idleIndex=$idle;keyBox='unchecked';keyTouched=$false;allowSwitch=$sw}
        $got=& $From -Held $held
        $wantThinking=[string]$Want.Thinking[[string]$think]
        $wantIdle=[int]$Want.Idle[[string]$idle]
        $wantPort=[int]$Want.Port[[string]$port]
        $wantChat=[string]$Want.Chat[[string]$chat]
        $wantSwitch=[bool]$Want.Switch[[string]$sw]
        if([string]$got.thinking -cne $wantThinking){[void]$bad.Add("thinkingIndex $think saves '$($got.thinking)', today saves '$wantThinking'")}
        if([int]$got.idleStopMinutes -ne $wantIdle -or $got.idleStopMinutes -isnot [int]){[void]$bad.Add("idleIndex $idle saves '$($got.idleStopMinutes)', today saves $wantIdle")}
        if([int]$got.serverPort -ne $wantPort -or $got.serverPort -isnot [int]){[void]$bad.Add("port $port saves '$($got.serverPort)', today saves $wantPort")}
        if([string]$got.chatPage -cne $wantChat){[void]$bad.Add("chat $chat saves '$($got.chatPage)', today saves '$wantChat'")}
        if([bool]$got.allowSwitch -ne $wantSwitch){[void]$bad.Add("switch $sw saves '$($got.allowSwitch)', today saves $wantSwitch")}
    }}}}}
    foreach($think in 'auto','off','weird',''){foreach($idle in 0,15,30,60,45,-1,999){foreach($chat in 'on','off',''){foreach($keyCase in @(@{apiKey='on';apiKeyUndetermined=$false},@{apiKey='off';apiKeyUndetermined=$false},@{apiKey='on';apiKeyUndetermined=$true})){
        $cur=[pscustomobject]@{serverPort=8080;thinking=$think;chatPage=$chat;idleStopMinutes=$idle;apiKey=$keyCase.apiKey;apiKeyUndetermined=$keyCase.apiKeyUndetermined;allowSwitch=$false}
        $h=& $To -Current $cur
        $wantT=[int]$Want.InitThinking[[string]$think]
        $wantI=[int]$Want.InitIdle[[string]$idle]
        $wantC=[bool]$Want.InitChat[[string]$chat]
        $wantP=[int]$Want.InitPort['8080']
        if([int]$h.thinkingIndex -ne $wantT){[void]$bad.Add("saved thinking '$think' is held as $($h.thinkingIndex), today shows $wantT")}
        if([int]$h.idleIndex -ne $wantI){[void]$bad.Add("saved idle $idle is held as $($h.idleIndex), today shows $wantI")}
        if([bool]$h.chatPage -ne $wantC){[void]$bad.Add("saved chat '$chat' is held as $($h.chatPage), today shows $wantC")}
        if([int]$h.port -ne $wantP){[void]$bad.Add("saved port is held as $($h.port), today shows $wantP")}
        $state=[string](Get-FastLlmUiApiKeyBoxState -Settings $cur)
        if([string]$h.keyBox -cne $state){[void]$bad.Add("the key box is held as '$($h.keyBox)', today shows '$state'")}
    }}}}
    return ,@($bad.ToArray()|Select-Object -Unique)
}
if($mapFrom -and $mapTo -and $mapBox){
    $mapReal=Get-MappingDisagreements ${function:ConvertFrom-FastLlmUiSettingsHeld} ${function:ConvertTo-FastLlmUiSettingsHeld} $mapWantFrozen
    foreach($m in $mapReal){Write-Host "FINDING: $m"}
    Check ($mapReal.Count -eq 0) 'the held-to-saved and saved-to-held mappings agree with today''s dialog expressions for every input (thinking, idle table, port cast, chat on/off, switch)'
    # Mutants of the fluent functions, each written whole so the comparison is what is proven.
    $fromGood={param($Held) [pscustomobject]@{serverPort=[int]$Held.port;thinking=[string]$(if([int]$Held.thinkingIndex -eq 1){'off'}else{'auto'});chatPage=[string]$(if([bool]$Held.chatPage){'on'}else{'off'});idleStopMinutes=[int]@(0,15,30,60)[[Math]::Max(0,[int]$Held.idleIndex)];allowSwitch=[bool]$Held.allowSwitch}}
    $toGood={param($Current) [pscustomobject]@{port=[int]$Current.serverPort;thinkingIndex=[int]$(if([string]$Current.thinking -ceq 'off'){1}else{0});chatPage=[bool]([string]$Current.chatPage -ceq 'on');idleIndex=[int]$(switch([int]$Current.idleStopMinutes){15{1}30{2}60{3}default{0}});keyBox=[string](Get-FastLlmUiApiKeyBoxState -Settings $Current);keyTouched=$false;allowSwitch=[bool]$Current.allowSwitch}}
    Check ((Get-MappingDisagreements $fromGood $toGood $mapWantFrozen).Count -eq 0) 'self-check: a correct pair of mapping functions agrees with today''s expressions'
    $mapPlants=[ordered]@{
        'thinking off at index 0'=@($fromGood.ToString().Replace('-eq 1)','-eq 0)'),$toGood)
        'idle table with 45'=@($fromGood.ToString().Replace('@(0,15,30,60)','@(0,15,30,45)'),$toGood)
        'idle index not clamped at 0'=@($fromGood.ToString().Replace('[Math]::Max(0,[int]$Held.idleIndex)','([int]$Held.idleIndex+0)'),$toGood)
        'chat on and off swapped'=@($fromGood.ToString().Replace("{'on'}else{'off'}","{'off'}else{'on'}"),$toGood)
        'port off by one'=@($fromGood.ToString().Replace('[int]$Held.port','([int]$Held.port+1)'),$toGood)
        'switch inverted'=@($fromGood.ToString().Replace('allowSwitch=[bool]$Held.allowSwitch','allowSwitch=-not [bool]$Held.allowSwitch'),$toGood)
        'saved idle 30 held as 3'=@($fromGood,$toGood.ToString().Replace('30{2}','30{3}'))
        'saved thinking never held off'=@($fromGood,$toGood.ToString().Replace("-ceq 'off'","-ceq 'never'"))
        'saved chat held inverted'=@($fromGood,$toGood.ToString().Replace("-ceq 'on')","-ceq 'off')"))
        'the key box state invented'=@($fromGood,$toGood.ToString().Replace('keyBox=[string](Get-FastLlmUiApiKeyBoxState -Settings $Current)',"keyBox='unchecked'"))
    }
    foreach($k in $mapPlants.Keys){
        $pf=[scriptblock]::Create($mapPlants[$k][0].ToString()); $pt=[scriptblock]::Create($mapPlants[$k][1].ToString())
        Check ($mapPlants[$k][0].ToString() -cne $fromGood.ToString() -or $mapPlants[$k][1].ToString() -cne $toGood.ToString()) "the mapping plant '$k' changed the text"
        Check ((Get-MappingDisagreements $pf $pt $mapWantFrozen).Count -ge 1) "mutation check: the mapping pin flags: $k"
    }
}

# 5b-delete-begin
$settingsDialogFn=@($classicAst.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'BuildUiSettingsDialog'},$true))[0]
function Get-AssignRight($Scope,[string]$LeftText){
    $m=@($Scope.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and ($n.Left.Extent.Text -replace '\s','') -ceq $LeftText},$true))
    if($m.Count -ne 1){throw "FAIL: the classic dialog has $($m.Count) assignments to $LeftText, expected 1"}
    return [string]$m[0].Right.Extent.Text
}
function Get-CommandArgText($Scope,[string]$Command,[string]$Param){
    $c=@($Scope.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -ceq $Command},$true))
    if($c.Count -ne 1){throw "FAIL: the classic dialog has $($c.Count) calls of $Command, expected 1"}
    $els=@($c[0].CommandElements)
    for($i=1;$i -lt $els.Count-1;$i++){ if($els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and [string]$els[$i].ParameterName -ceq $Param){return [string]$els[$i+1].Extent.Text} }
    throw "FAIL: $Command has no -$Param"
}
$clThinking=Get-AssignRight $settingsDialogFn '$savedThinking'
$clIdle=Get-AssignRight $settingsDialogFn '$savedIdle'
$clPort=Get-CommandArgText $settingsDialogFn 'Set-FastLlmServingSettings' 'ServerPort'
$clChat=Get-CommandArgText $settingsDialogFn 'Set-FastLlmServingSettings' 'ChatPage'
$clSwitch=Get-CommandArgText $settingsDialogFn 'Set-FastLlmUiAllowSwitch' 'Value'
$clInitThinking=Get-AssignRight $settingsDialogFn '$thinkingBox.SelectedIndex'
$clInitIdle=Get-AssignRight $settingsDialogFn '$idleBox.SelectedIndex'
$clInitChat=Get-AssignRight $settingsDialogFn '$chatBox.Checked'
$clInitPort=Get-AssignRight $settingsDialogFn '$portBox.Value'
function Invoke-ClassicExpr([string]$Expr,[string]$Param,$Value){
    $names='thinkingBox','idleBox','portBox','chatBox','switchBox','current'
    $sb=[scriptblock]::Create('param('+(($names|ForEach-Object{'$'+$_}) -join ',')+') '+$Expr)
    $argsList=@(); foreach($n in $names){ if($n -ceq $Param){$argsList+=,$Value}else{$argsList+=,$null} }
    return (& $sb @argsList)
}
function Get-MappingWantFromClassic{
    $w=@{Thinking=@{};Idle=@{};Port=@{};Chat=@{};Switch=@{};InitThinking=@{};InitIdle=@{};InitChat=@{};InitPort=@{}}
    foreach($think in -1,0,1,2){ $w.Thinking[[string]$think]=[string](Invoke-ClassicExpr $clThinking 'thinkingBox' ([pscustomobject]@{SelectedIndex=$think})) }
    foreach($idle in -1,0,1,2,3){ $w.Idle[[string]$idle]=[int](Invoke-ClassicExpr $clIdle 'idleBox' ([pscustomobject]@{SelectedIndex=$idle})) }
    foreach($port in 1024,11434,65535){ $w.Port[[string]$port]=[int](Invoke-ClassicExpr $clPort 'portBox' ([pscustomobject]@{Value=[decimal]$port})) }
    foreach($chat in $true,$false){ $w.Chat[[string]$chat]=[string](Invoke-ClassicExpr $clChat 'chatBox' ([pscustomobject]@{Checked=$chat})) }
    foreach($sw in $true,$false){ $w.Switch[[string]$sw]=[bool](Invoke-ClassicExpr $clSwitch 'switchBox' ([pscustomobject]@{Checked=$sw})) }
    $base=@{serverPort=8080;apiKey='on';apiKeyUndetermined=$false;allowSwitch=$false}
    foreach($think in 'auto','off','weird',''){ $cur=[pscustomobject]($base+@{thinking=$think;chatPage='on';idleStopMinutes=0}); $w.InitThinking[[string]$think]=[int](Invoke-ClassicExpr $clInitThinking 'current' $cur) }
    foreach($idle in 0,15,30,60,45,-1,999){ $cur=[pscustomobject]($base+@{thinking='auto';chatPage='on';idleStopMinutes=$idle}); $w.InitIdle[[string]$idle]=[int](Invoke-ClassicExpr $clInitIdle 'current' $cur) }
    foreach($chat in 'on','off',''){ $cur=[pscustomobject]($base+@{thinking='auto';chatPage=$chat;idleStopMinutes=0}); $w.InitChat[[string]$chat]=[bool](Invoke-ClassicExpr $clInitChat 'current' $cur) }
    $cur=[pscustomobject]($base+@{thinking='auto';chatPage='on';idleStopMinutes=0}); $w.InitPort['8080']=[int](Invoke-ClassicExpr $clInitPort 'current' $cur)
    return $w
}
function Format-MappingWant($Want){ return (@($Want.Keys|Sort-Object|ForEach-Object{ $sec=$_; $sec+'{'+((@($Want[$sec].Keys|Sort-Object|ForEach-Object{ "$_="+[string]$Want[$sec][$_] })) -join ';')+'}' }) -join ' ') }
$mapWantClassic=Get-MappingWantFromClassic
Check ((Format-MappingWant $mapWantClassic) -ceq (Format-MappingWant $mapWantFrozen)) 'the frozen mapping expectations equal what the classic dialog expressions give for every input'
# 5b-delete-end
# ---- (3) The text drift pin, extended from 3b's: constants, templates, Items.Add arguments, and a +[string][char]0x2026 concatenation as that character ----
# 5b-delete-begin
function Test-ConstantOnlyNode($Node){
    return (@($Node.FindAll({param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -or $n -is [System.Management.Automation.Language.CommandAst] -or $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -or $n -is [System.Management.Automation.Language.MemberExpressionAst] -or $n -is [System.Management.Automation.Language.SubExpressionAst] -or $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -or $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -or $n -is [System.Management.Automation.Language.IndexExpressionAst]},$true)).Count -eq 0)
}
function Get-ConcatValue($Node){ return [string](& ([scriptblock]::Create($Node.Extent.Text))) }
function Get-SettingsClassicTexts($Fn){
    $values=New-Object System.Collections.ArrayList
    $assigned=New-Object System.Collections.ArrayList
    $isConcat={param($n) $n -is [System.Management.Automation.Language.BinaryExpressionAst] -and [string]$n.Operator -ceq 'Plus' -and (Test-ConstantOnlyNode $n)}
    # (d) a constant concatenation counts as the one string it builds (the part constants are not texts of their own).
    $concats=@($Fn.FindAll($isConcat,$true))
    foreach($c in $concats){ $top=$c; $p=$c.Parent; while($null -ne $p){ if($p -is [System.Management.Automation.Language.BinaryExpressionAst] -and [string]$p.Operator -ceq 'Plus' -and (Test-ConstantOnlyNode $p)){$top=$p}; $p=$p.Parent }; if([object]::ReferenceEquals($top,$c)){ [void]$values.Add((Get-ConcatValue $c)) } }
    # (a) string constants and (b) expandable-string templates.
    foreach($k in @($Fn.FindAll({param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst]},$true))){ [void]$values.Add([string]$k.Value) }
    foreach($ex in @($Fn.FindAll({param($n) $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]},$true))){ [void]$values.Add((Get-TemplateText $ex)) }
    $skip={param($k)
        if($k.Parent -is [System.Management.Automation.Language.MemberExpressionAst] -and [object]::ReferenceEquals($k.Parent.Member,$k)){return $true}
        if($k.Parent -is [System.Management.Automation.Language.BinaryExpressionAst] -and [string]$k.Parent.Operator -cnotmatch '^(Plus|Format)$'){return $true}
        if($k.Parent -is [System.Management.Automation.Language.CommandAst] -and [object]::ReferenceEquals($k.Parent.CommandElements[0],$k)){return $true}
        return $false }
    $addText={param($k)
        if(& $skip $k){return}
        $v=if($k -is [System.Management.Automation.Language.ExpandableStringExpressionAst]){Get-TemplateText $k}else{[string]$k.Value}
        if($v.Trim() -ne ''){[void]$assigned.Add($v)} }
    # Text assignments (the right side, a concatenation as one value).
    foreach($asg in @($Fn.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.MemberExpressionAst] -and [string]$n.Left.Member.Value -ceq 'Text'},$true))){
        $rc=@($asg.Right.FindAll($isConcat,$true))
        $topConcat=@($rc|Where-Object{ $q=$_.Parent; $isTop=$true; while($null -ne $q -and -not [object]::ReferenceEquals($q,$asg)){ if($q -is [System.Management.Automation.Language.BinaryExpressionAst] -and [string]$q.Operator -ceq 'Plus' -and (Test-ConstantOnlyNode $q)){$isTop=$false}; $q=$q.Parent }; $isTop })
        foreach($c in $topConcat){ [void]$assigned.Add((Get-ConcatValue $c)) }
        foreach($k in @($asg.Right.FindAll({param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]},$true))){
            $inside=$false; foreach($c in $topConcat){ if($k.Extent.StartOffset -ge $c.Extent.StartOffset -and $k.Extent.EndOffset -le $c.Extent.EndOffset){$inside=$true} }
            if(-not $inside){ & $addText $k }
        }
    }
    # (c) Items.Add(<constant>) arguments, and the constants of a foreach array whose body adds the loop variable to Items.
    foreach($call in @($Fn.FindAll({param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$n.Member.Value -ceq 'Add' -and $n.Expression -is [System.Management.Automation.Language.MemberExpressionAst] -and [string]$n.Expression.Member.Value -ceq 'Items'},$true))){
        foreach($arg in @($call.Arguments)){ if($arg -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $arg -is [System.Management.Automation.Language.ExpandableStringExpressionAst]){ & $addText $arg } }
    }
    foreach($fe in @($Fn.FindAll({param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst]},$true))){
        $var=[string]$fe.Variable.VariablePath.UserPath
        $adds=@($fe.Body.FindAll({param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$n.Member.Value -ceq 'Add' -and $n.Expression -is [System.Management.Automation.Language.MemberExpressionAst] -and [string]$n.Expression.Member.Value -ceq 'Items' -and @($n.Arguments|Where-Object{$_ -is [System.Management.Automation.Language.VariableExpressionAst] -and [string]$_.VariablePath.UserPath -ceq $var}).Count -gt 0},$true))
        if($adds.Count -gt 0){ foreach($k in @($fe.Condition.FindAll({param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst]},$true))){ & $addText $k } }
    }
    return [pscustomobject]@{Values=@($values.ToArray());Assigned=@($assigned.ToArray())}
}
function Get-SettingsDriftProblems($Table,[string[]]$Values,[string[]]$Assigned){
    $problems=New-Object System.Collections.ArrayList
    foreach($key in @($Table.Keys)){if($Values -cnotcontains [string]$Table[$key]){[void]$problems.Add("table value $key is not a constant, template or built string of the classic Settings dialog")}}
    $allowed=@($Table.Values|ForEach-Object{[string]$_})
    foreach($text in $Assigned){if($allowed -cnotcontains $text){[void]$problems.Add("the classic dialog assigns '$text' to a .Text or an Items list and the table has no such value")}}
    return ,$problems.ToArray()
}
$settingsClassic=Get-SettingsClassicTexts $settingsDialogFn
Check ($settingsClassic.Assigned.Count -gt 20) "the classic Settings dialog assigns its texts ($($settingsClassic.Assigned.Count) found)"
Check (($settingsClassic.Assigned -ccontains ('Create a new key'+[string][char]0x2026)) -and ($settingsClassic.Values -ccontains ('Create a new key'+[string][char]0x2026))) 'a +[string][char]0x2026 concatenation counts as the ellipsis character (Create a new key...)'
Check (($settingsClassic.Assigned -ccontains 'After 15 minutes') -and ($settingsClassic.Assigned -ccontains 'Never (default)') -and ($settingsClassic.Assigned -ccontains 'Auto (recommended)')) 'the Items.Add choices of Thinking and idle (constants and a foreach array) are among the assigned texts'
Check (($settingsClassic.Assigned -ccontains 'Cancel') -and ($settingsClassic.Assigned -ccontains 'Save')) 'the classic Save and Cancel captions are assigned texts (Cancel is the prompt''s, in the table)'
$refTable=[ordered]@{}; $ri=0; foreach($v in @($settingsClassic.Assigned|Select-Object -Unique)){ $refTable["K$ri"]=$v; $ri++ }
Check ((Get-SettingsDriftProblems $refTable $settingsClassic.Values $settingsClassic.Assigned).Count -eq 0) 'self-check: a table of exactly the classic texts has no drift'
$driftPlant=[ordered]@{}; foreach($key in $refTable.Keys){$driftPlant[$key]=[string]$refTable[$key]}
foreach($key in @($driftPlant.Keys)){ if($driftPlant[$key] -ceq 'After 15 minutes'){$driftPlant[$key]='After 15 min'} }
Check ((Get-SettingsDriftProblems $driftPlant $settingsClassic.Values $settingsClassic.Assigned).Count -ge 1) 'mutation check: a changed idle choice fails the Settings drift pin'
$driftPlant=[ordered]@{}; foreach($key in $refTable.Keys){$driftPlant[$key]=[string]$refTable[$key]}
foreach($key in @($driftPlant.Keys)){ if($driftPlant[$key].StartsWith('Frees the GPU memory.',[StringComparison]::Ordinal)){$driftPlant[$key]='Frees GPU memory.'} }
Check ((Get-SettingsDriftProblems $driftPlant $settingsClassic.Values $settingsClassic.Assigned).Count -ge 1) 'mutation check: an edited help line fails the Settings drift pin'
Check ((Get-SettingsDriftProblems $refTable $settingsClassic.Values @($settingsClassic.Assigned+'A new caption')).Count -ge 1) 'mutation check: a new .Text literal in the classic dialog that the table lacks fails the Settings drift pin'
$driftPlant=[ordered]@{}; foreach($key in $refTable.Keys){$driftPlant[$key]=[string]$refTable[$key]}
foreach($key in @($driftPlant.Keys)){ if($driftPlant[$key] -ceq ('Create a new key'+[string][char]0x2026)){$driftPlant[$key]='Create a new key...'} }
Check ((Get-SettingsDriftProblems $driftPlant $settingsClassic.Values $settingsClassic.Assigned).Count -ge 1) 'mutation check: the ellipsis built as three dots fails the Settings drift pin'
# 5b-delete-end
$settingsAst=ConvertTo-PinAst $settingsText
$settingsTextAssign=@($settingsAst.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$script:FastLlmUiFluentSettingsText'},$true))
Check ($settingsTextAssign.Count -eq 1) 'the Settings text table is assigned exactly once'
$settingsTable=& ([scriptblock]::Create($settingsTextAssign[0].Right.Extent.Text))
# The frozen Settings table: the 24 values as literals (the ellipsis is character 0x2026). Every value is a constant, a template or a built string of the classic Settings
# dialog, and every text the dialog shows is in it (the unconditional check below, deleted with the dialog at the flip); the check here reads only the fluent source.
$settingsFrozen=[ordered]@{
    Title='FastLLM settings'
    Port='Port (127.0.0.1 only)'
    Thinking='Thinking'
    ThinkingAuto='Auto (recommended)'
    ThinkingOff='Off: faster answers. Quality with thinking off is not measured by Bitworks.'
    Chat='Local chat page (off by default)'
    ChatHelp='Chats are kept by your browser, not by FastLLM.'
    Idle='Stop the model when idle'
    IdleNever='Never (default)'
    IdleAfter15='After 15 minutes'
    IdleAfter30='After 30 minutes'
    IdleAfter60='After 60 minutes'
    IdleHelp='Frees the GPU memory. Apps get no answer until you start FastLLM again.'
    Key='Require an API key (off by default)'
    KeyNotSet='Require an API key (not set: tick or clear this box to choose)'
    KeyHelp='Apps must then send the key. It keeps web pages and other Windows accounts on this PC out; it does not stop programs you run. Applies at the next start.'
    NewKey='Create a new key'+[string][char]0x2026
    SignIn='Start FastLLM when I sign in'
    SignInUnreadable='Start at sign-in could not be read on this PC.'
    Switch='Allow switching models while FastLLM runs'
    SwitchHelp='Off by default; applies from the next start. A switch checks the new model again and starts the old one if it cannot start. Stop always wins.'
    Save='Save'
    Cancel='Cancel'
    NotTurnedOn='The API key was not turned on: the stored key cannot be read and no new key was created. Nothing was changed.'
}
Check ($settingsFrozen.Count -eq 24 -and ((@($settingsFrozen.Keys) -join ',') -ceq (@($settingsTable.Keys) -join ','))) 'the frozen Settings table holds the 24 keys of the Settings text table, in order'
Check ((Get-FrozenTableProblems $settingsTable $settingsFrozen).Count -eq 0) 'the Settings text table equals its frozen literal (24 keys, every value)'
Check ($settingsFrozen['NewKey'] -ceq ('Create a new key'+[string][char]0x2026) -and $settingsTable['NewKey'].EndsWith([string][char]0x2026) -and $settingsTable['NewKey'].Length -eq 17) 'the Create a new key caption ends in the single ellipsis character, not three dots'
$stMutIdle=Copy-Table $settingsTable; $stMutIdle['IdleAfter15']='After 15 min'
$stMutHelp=Copy-Table $settingsTable; $stMutHelp['IdleHelp']='Frees GPU memory.'
$stMutDots=Copy-Table $settingsTable; $stMutDots['NewKey']='Create a new key...'
$stMutKey=Copy-Table $settingsTable; $stMutKey['Extra']='A new caption'
Check ((Get-FrozenTableProblems $stMutIdle $settingsFrozen).Count -ge 1) 'mutation check: a changed idle choice fails the Settings frozen literal'
Check ((Get-FrozenTableProblems $stMutHelp $settingsFrozen).Count -ge 1) 'mutation check: an edited help line fails the Settings frozen literal'
Check ((Get-FrozenTableProblems $stMutDots $settingsFrozen).Count -ge 1) 'mutation check: the ellipsis built as three dots fails the Settings frozen literal'
Check ((Get-FrozenTableProblems $stMutKey $settingsFrozen).Count -ge 1) 'mutation check: a new Settings table key fails the Settings frozen literal'
Check ((Get-FrozenTableProblems (Copy-Table $settingsTable) $settingsFrozen).Count -eq 0) 'control: an unchanged copy of the Settings table passes the frozen literal'
# 5b-delete-begin
$settingsDrift=Get-SettingsDriftProblems $settingsTable $settingsClassic.Values $settingsClassic.Assigned
foreach($pr in $settingsDrift){Write-Host "FINDING: $pr"}
Check ($settingsDrift.Count -eq 0) 'every Settings text value is a classic constant, template or built string, and every classic .Text and Items text is in the table'
$settingsFrozenDrift=Get-SettingsDriftProblems $settingsFrozen $settingsClassic.Values $settingsClassic.Assigned
foreach($pr in $settingsFrozenDrift){Write-Host "FINDING: $pr"}
Check ($null -ne $settingsDialogFn -and $settingsFrozenDrift.Count -eq 0 -and $settingsClassic.Assigned.Count -gt 20) 'the frozen Settings literal equals the classic Settings dialog texts (every value is a classic constant, template or built string, every classic text is in the literal)'
# 5b-delete-end
# Cancel is used only by the prompt: the key whose value is 'Cancel' is read only inside Show-FastLlmUiFluentSavePrompt.
$cancelKeys=@($settingsTable.Keys|Where-Object{[string]$settingsTable[$_] -ceq 'Cancel'})
Check ($cancelKeys.Count -eq 1) 'the Settings text table has exactly one Cancel value'
$cancelUses=@($settingsAst.FindAll({param($n) ($n -is [System.Management.Automation.Language.MemberExpressionAst] -and $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and [string]$n.Member.Value -ceq [string]$cancelKeys[0]) -or ($n -is [System.Management.Automation.Language.IndexExpressionAst] -and $n.Index -is [System.Management.Automation.Language.StringConstantExpressionAst] -and [string]$n.Index.Value -ceq [string]$cancelKeys[0])},$true))
$cancelOwners=@($cancelUses|ForEach-Object{$o=Get-EnclosingFunctionAst $_; if($null -ne $o){$o.Name}else{''}}|Select-Object -Unique)
Check ($cancelUses.Count -ge 1 -and $cancelOwners.Count -eq 1 -and $cancelOwners[0] -ceq 'Show-FastLlmUiFluentSavePrompt') 'the Cancel text is read only inside Show-FastLlmUiFluentSavePrompt'

# ---- (4) The close-hook pin (AST, Invoke-FastLlmUiFormClosing) ----
# The BeforeClosing call is inside the try, before the foreach over FormClosing, guarded by CloseReason -ne WindowsShutDown, its $true returns $true without running
# the loop, and BeforeClosing is read nowhere else (so Hide, Show and Close cannot reach it).
$closeOwners=@('New-FastLlmUiFormAdapter','Invoke-FastLlmUiFormClosing','Initialize-FastLlmUiFluentShell')
function Get-CloseHookFindings([string]$FormSrc,[string[]]$OtherTexts){
    $found=New-Object System.Collections.ArrayList
    $a=ConvertTo-PinAst $FormSrc
    $fns=@($a.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Invoke-FastLlmUiFormClosing'},$true))
    if($fns.Count -ne 1){[void]$found.Add('Invoke-FastLlmUiFormClosing is not defined exactly once');return ,$found.ToArray()}
    $try=@($fns[0].Body.EndBlock.Statements|Where-Object{$_ -is [System.Management.Automation.Language.TryStatementAst]})
    if($try.Count -ne 1){[void]$found.Add('Invoke-FastLlmUiFormClosing has no single top-level try');return ,$found.ToArray()}
    $loop=@($try[0].Body.FindAll({param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] -and $n.Condition.Extent.Text -cmatch 'FormClosing'},$true))
    if($loop.Count -ne 1){[void]$found.Add('the FormClosing foreach is not inside the try exactly once');return ,$found.ToArray()}
    $calls=@($fns[0].Body.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand -and $n.CommandElements[0].Extent.Text -ceq '$hook'},$true))
    if($calls.Count -ne 1){[void]$found.Add("the hook is called $($calls.Count) times, expected 1");return ,$found.ToArray()}
    if(-not ($calls[0].Extent.StartOffset -ge $try[0].Body.Extent.StartOffset -and $calls[0].Extent.EndOffset -le $try[0].Body.Extent.EndOffset)){[void]$found.Add('the hook call is not inside the try')}
    if($calls[0].Extent.StartOffset -ge $loop[0].Extent.StartOffset){[void]$found.Add('the hook call is after the FormClosing loop starts (Cancel would run the guards)')}
    # The guard: an if whose condition holds the hook test and CloseReason -ne WindowsShutDown, around the inner if that returns $true.
    $guard=$null; $p=$calls[0].Parent
    $inner=$null
    while($null -ne $p -and $p -isnot [System.Management.Automation.Language.FunctionDefinitionAst]){
        if($p -is [System.Management.Automation.Language.IfStatementAst]){ if($null -eq $inner){$inner=$p}else{$guard=$p;break} }
        $p=$p.Parent
    }
    if($null -eq $guard){[void]$found.Add('the hook call has no guard if around its test')}
    else{
        $cond=[string]$guard.Clauses[0].Item1.Extent.Text
        if($cond -cnotmatch '\$null -ne \$hook' -or $cond -cnotmatch '\$CloseReason -ne \[System\.Windows\.Forms\.CloseReason\]::WindowsShutDown'){[void]$found.Add("the hook is not guarded by a set hook and CloseReason -ne WindowsShutDown: $cond")}
    }
    if($null -eq $inner){[void]$found.Add('the hook result is not tested by an if')}
    else{
        $ret=@($inner.Clauses[0].Item2.FindAll({param($n) $n -is [System.Management.Automation.Language.ReturnStatementAst] -and $n.Pipeline.Extent.Text -ceq '$true'},$true))
        if($ret.Count -ne 1){[void]$found.Add('a true hook result does not return $true before the loop')}
    }
    # BeforeClosing is read or set only by the adapter, the closing function and the shell registration: never in Hide, Show, Close or any other function.
    foreach($t in @($FormSrc)+@($OtherTexts)){
        $b=ConvertTo-PinAst $t
        foreach($m in [regex]::Matches($t,'BeforeClosing')){
            $owner=@($b.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Extent.StartOffset -le $m.Index -and $n.Extent.EndOffset -ge $m.Index},$true)|Sort-Object {$_.Extent.StartOffset}|Select-Object -Last 1)
            $ownerName=''; if($owner.Count -gt 0){$ownerName=[string]$owner[0].Name}
            if($closeOwners -cnotcontains $ownerName){[void]$found.Add("BeforeClosing is referenced in '$ownerName' (only the adapter, the closing function and the shell registration may)")}
        }
    }
    $hide=@($a.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.Extent.Text -cmatch '-Name (Hide|Show|Close)\b'},$true))
    foreach($h in $hide){ if($h.Extent.Text.Contains('BeforeClosing')){[void]$found.Add('the Hide, Show or Close member reaches BeforeClosing')} }
    return ,$found.ToArray()
}
$closeOthers=@($shellText,(Get-OptionalText 'fast-llm-ui.ps1'))+@($fluentSrcFiles|Where-Object{$_ -notmatch 'UiFluent(Form|Shell)\.ps1$'}|ForEach-Object{[IO.File]::ReadAllText($_)})
$closeFindings=Get-CloseHookFindings $formText $closeOthers
foreach($f in $closeFindings){Write-Host "FINDING: $f"}
Check ($closeFindings.Count -eq 0) 'the close hook runs inside the try before the FormClosing loop, guarded against WindowsShutDown, returns $true without the loop, and is read nowhere else'
$hookBlock="        `$hook = `$state['BeforeClosing']`n        if (`$null -ne `$hook -and `$CloseReason -ne [System.Windows.Forms.CloseReason]::WindowsShutDown) {`n            if ([bool] (@(& `$hook) | Select-Object -Last 1)) { return `$true }`n        }`n"
$loopLine="        foreach (`$h in @(`$state.FormClosing)) { `$null = & `$h `$Form `$fcArgs }`n"
Check ($formText.Contains($hookBlock+$loopLine)) 'self-check: the real hook block and the FormClosing loop are the text the plants move'
$closePlants=[ordered]@{
    'the hook call after the FormClosing loop'=$formText.Replace($hookBlock+$loopLine,$loopLine+$hookBlock)
    'no WindowsShutDown guard'=$formText.Replace(' -and $CloseReason -ne [System.Windows.Forms.CloseReason]::WindowsShutDown','')
    'a missing return'=$formText.Replace('{ return $true }
        }
        foreach','{ $null = $true }
        }
        foreach')
    'the hook read by Hide'=$formText.Replace('-Name Hide -Value ({ $Window.Hide() }','-Name Hide -Value ({ $null = $state[''BeforeClosing'']; $Window.Hide() }')
    'the hook read in another function'=($formText+"`nfunction Get-Stray { param(`$Form) return `$Form.FastLlmFormState['BeforeClosing'] }")
    'the hook never called'=$formText.Replace('if ([bool] (@(& $hook) | Select-Object -Last 1)) { return $true }','$null = 1')
}
foreach($k in $closePlants.Keys){ Check ($closePlants[$k] -cne $formText -and (Get-CloseHookFindings $closePlants[$k] $closeOthers).Count -ge 1) "mutation check: the close-hook pin flags: $k" }

# ---- (5) WPF wiring pins (AST): the Toggle branch, NavSettingsList, the TabNavigation swap and the key-box click ----
function Get-ToggleWiringFindings([string]$Text){
    $found=New-Object System.Collections.ArrayList
    $a=ConvertTo-PinAst $Text
    $connect=@($a.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Connect-FastLlmUiFluentControl'},$true))
    $sinkFn=@($a.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'New-FastLlmUiFluentSink'},$true))
    if($connect.Count -ne 1 -or $sinkFn.Count -ne 1){[void]$found.Add('Connect-FastLlmUiFluentControl or New-FastLlmUiFluentSink is not defined exactly once');return ,$found.ToArray()}
    $toggleBodies=@()
    foreach($i in @($connect[0].FindAll({param($n) $n -is [System.Management.Automation.Language.IfStatementAst]},$true))){
        foreach($c in $i.Clauses){ if($c.Item1.Extent.Text -ceq "`$Mode -ceq 'Toggle'" -and @($c.Item2.FindAll({param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$n.Member.Value -cmatch '^Add_'},$true)).Count -gt 0){$toggleBodies+=,$c.Item2} }
    }
    if($toggleBodies.Count -ne 1){[void]$found.Add("the Toggle handler branch is found $($toggleBodies.Count) times, expected 1")}
    else{
        $adds=@($toggleBodies[0].FindAll({param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$n.Member.Value -cmatch '^Add_'},$true))
        $names=@($adds|ForEach-Object{[string]$_.Member.Value})
        foreach($need in 'Add_Checked','Add_Unchecked'){ if($names -cnotcontains $need){[void]$found.Add("the Toggle branch does not attach $need")} }
        if($names -ccontains 'Add_Click'){[void]$found.Add('the Toggle branch attaches Click (a UIA Toggle does not raise it)')}
        foreach($n in $names){ if($n -cnotin 'Add_Checked','Add_Unchecked','Add_Indeterminate'){[void]$found.Add("the Toggle branch attaches $n, expected only Checked, Unchecked and Indeterminate")} }
        foreach($ad in $adds){
            $setCalls=@($ad.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand},$true))
            if($setCalls.Count -ne 1 -or $setCalls[0].CommandElements[0].Extent.Text -cne '$setFrom' -or $setCalls[0].Extent.Text -cnotmatch "-Property 'Checked'"){[void]$found.Add("the $($ad.Member.Value) handler does not call `$setFrom -Property 'Checked' exactly once")}
            # The re-sync after the adapter write: a revert inside the adapter's handler ran with FromElement set, so only this element write turns the toggle back off.
            $resync=@($ad.FindAll({param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -ceq '$Element.IsChecked -ne [bool] $Adapter.Checked' -and $n.Clauses[0].Item2.Extent.Text -cmatch '^\{\s*\$Element\.IsChecked = \[bool\] \$Adapter\.Checked\s*\}$'},$true))
            if($resync.Count -ne 1 -or $setCalls.Count -ne 1 -or $resync[0].Extent.StartOffset -lt $setCalls[0].Extent.EndOffset){[void]$found.Add("the $($ad.Member.Value) handler does not re-sync IsChecked from the adapter after the write")}
        }
    }
    $setFromAsg=@($connect[0].FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$setFrom'},$true))
    if($setFromAsg.Count -ne 1 -or $setFromAsg[0].Right.Extent.Text -cne '${function:Set-FastLlmUiAdapterFromElement}'){[void]$found.Add('$setFrom is not Set-FastLlmUiAdapterFromElement')}
    # The Event block never attaches Click for a Toggle.
    $clicks=@($connect[0].FindAll({param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$n.Member.Value -ceq 'Add_Click'},$true))
    if($clicks.Count -ne 1){[void]$found.Add("the control binder attaches Click $($clicks.Count) times, expected 1 (the Event block)")}
    else{
        $guard=$null;$p=$clicks[0].Parent
        while($null -ne $p -and $p -isnot [System.Management.Automation.Language.FunctionDefinitionAst]){ if($p -is [System.Management.Automation.Language.IfStatementAst]){$guard=$p;break}; $p=$p.Parent }
        if($null -eq $guard -or $guard.Clauses[0].Item1.Extent.Text -cnotmatch "\`$Event" -or $guard.Clauses[0].Item1.Extent.Text -cnotmatch "\`$Mode -cne 'Toggle'"){[void]$found.Add('the Event Click block is not guarded by $Mode -cne ''Toggle''')}
    }
    # The sink: the Toggle branch checks FromElement before it writes IsChecked.
    $sinkBranch=@(); foreach($i in @($sinkFn[0].FindAll({param($n) $n -is [System.Management.Automation.Language.IfStatementAst]},$true))){ foreach($c in $i.Clauses){ if($c.Item1.Extent.Text -ceq "`$Mode -ceq 'Toggle'"){$sinkBranch+=,$c.Item2} } }
    $withFrom=@($sinkBranch|Where-Object{$_.Extent.Text -cmatch "__state\['FromElement'\]" -and $_.Extent.Text -cmatch 'IsChecked'})
    if($withFrom.Count -ne 1){[void]$found.Add('the Toggle sink branch does not check FromElement before writing IsChecked')}
    elseif($withFrom[0].Extent.Text.IndexOf("__state['FromElement']",[StringComparison]::Ordinal) -gt $withFrom[0].Extent.Text.IndexOf('IsChecked =',[StringComparison]::Ordinal) -and $withFrom[0].Extent.Text.IndexOf('IsChecked =',[StringComparison]::Ordinal) -ge 0){[void]$found.Add('the Toggle sink branch checks FromElement after it writes IsChecked')}
    return ,$found.ToArray()
}
$toggleFindings=Get-ToggleWiringFindings $homeText
foreach($f in $toggleFindings){Write-Host "FINDING: $f"}
Check ($toggleFindings.Count -eq 0) 'the Toggle mode attaches Checked and Unchecked (never Click), each writing the adapter once, and the sink checks FromElement'
$togglePlants=[ordered]@{
    'Add_Click in the Toggle branch'=$homeText.Replace('$Element.Add_Checked(','$Element.Add_Click(')
    'Unchecked not attached'=$homeText.Replace('$Element.Add_Unchecked(','$Element.Add_Indeterminate2(')
    'a Toggle handler that does not write the adapter'=$homeText.Replace("& `$setFrom -Adapter `$Adapter -Property 'Checked' -Value ([bool] (`$Element.IsChecked -eq `$true)); if (`$Element.IsChecked -ne [bool] `$Adapter.Checked) { `$Element.IsChecked = [bool] `$Adapter.Checked } }.GetNewClosure())`n        `$Element.Add_Unchecked(","`$null = 1 }.GetNewClosure())`n        `$Element.Add_Unchecked(")
    'a Toggle handler that writes the wrong property'=$homeText.Replace("-Property 'Checked' -Value ([bool] (`$Element.IsChecked -eq `$true)); if (`$Element.IsChecked -ne [bool] `$Adapter.Checked) { `$Element.IsChecked = [bool] `$Adapter.Checked } }.GetNewClosure())`n        `$Element.Add_Indeterminate(","-Property 'Text' -Value ([bool] (`$Element.IsChecked -eq `$true)); if (`$Element.IsChecked -ne [bool] `$Adapter.Checked) { `$Element.IsChecked = [bool] `$Adapter.Checked } }.GetNewClosure())`n        `$Element.Add_Indeterminate(")
    'a Toggle handler without the re-sync'=$homeText.Replace("-Property 'Checked' -Value ([bool] (`$Element.IsChecked -eq `$true)); if (`$Element.IsChecked -ne [bool] `$Adapter.Checked) { `$Element.IsChecked = [bool] `$Adapter.Checked } }.GetNewClosure())`n        `$Element.Add_Unchecked(","-Property 'Checked' -Value ([bool] (`$Element.IsChecked -eq `$true)) }.GetNewClosure())`n        `$Element.Add_Unchecked(")
    'the Event Click block open to a Toggle'=$homeText.Replace("if (`$Event -and `$Mode -cne 'Toggle') {","if (`$Event) {")
    'the sink without the FromElement check'=$homeText.Replace("                if (`$Adapter.__state['FromElement']) { return }`n                if (`$Element.IsChecked -ne","                if (`$Element.IsChecked -ne")
}
foreach($k in $togglePlants.Keys){ Check ($togglePlants[$k] -cne $homeText -and (Get-ToggleWiringFindings $togglePlants[$k]).Count -ge 1) "mutation check: the Toggle wiring pin flags: $k" }
# The three immediate toggles are bound in Toggle mode with no Event (a Click would reach today's handlers twice).
function Get-ToggleRowFindings([string[]]$Texts){
    $found=New-Object System.Collections.ArrayList; $seen=@{}
    foreach($t in $Texts){
        $a=ConvertTo-PinAst $t
        foreach($h in @($a.FindAll({param($n) $n -is [System.Management.Automation.Language.HashtableAst]},$true))){
            $rowName=$null;$mode=$null;$event=$null
            foreach($kv in $h.KeyValuePairs){
                $k=[string]$kv.Item1.Extent.Text
                if($k -ceq 'Name' -and $kv.Item2.Extent.Text -match "^'([^']+)'$"){$rowName=$Matches[1]}
                if($k -ceq 'Mode'){$mode=[string]$kv.Item2.Extent.Text}
                if($k -ceq 'Event'){$event=[string]$kv.Item2.Extent.Text}
            }
            if($null -eq $rowName -or @('updateBox','experimentalBox','licenseBox') -cnotcontains $rowName){continue}
            $seen[$rowName]=$true
            if($mode -cne "'Toggle'"){[void]$found.Add("row $rowName is not Mode = 'Toggle' (found: $mode)")}
            if($null -ne $event -and $event -cne "''"){[void]$found.Add("row $rowName has an Event ($event)")}
        }
    }
    foreach($n in 'updateBox','experimentalBox','licenseBox'){ if(-not $seen.ContainsKey($n)){[void]$found.Add("no row binds $n")} }
    return ,$found.ToArray()
}
$toggleRowGood="function Get-FastLlmUiFluentPlantBindings { return @(@{ Name = 'updateBox'; Element = 'A'; Mode = 'Toggle'; Event = ''; Flags = @() },@{ Name = 'experimentalBox'; Element = 'B'; Mode = 'Toggle' },@{ Name = 'licenseBox'; Element = 'C'; Mode = 'Toggle'; Event = '' }) }"
Check ((Get-ToggleRowFindings @($toggleRowGood)).Count -eq 0) 'self-check: three Toggle rows with no Event pass'
Check ((Get-ToggleRowFindings @($toggleRowGood.Replace("Name = 'updateBox'; Element = 'A'; Mode = 'Toggle'","Name = 'updateBox'; Element = 'A'; Mode = 'Content'"))).Count -ge 1) 'mutation check: a Content-mode update row is flagged'
Check ((Get-ToggleRowFindings @($toggleRowGood.Replace("Mode = 'Toggle'; Event = ''; Flags","Mode = 'Toggle'; Event = 'Click'; Flags"))).Count -ge 1) 'mutation check: a Click event on a Toggle row is flagged'
Check ((Get-ToggleRowFindings @($toggleRowGood.Replace("@{ Name = 'licenseBox'; Element = 'C'; Mode = 'Toggle'; Event = '' }",''))).Count -ge 1) 'mutation check: an unbound licence toggle is flagged'
$toggleRows=Get-ToggleRowFindings $pageTexts
foreach($f in $toggleRows){Write-Host "FINDING: $f"}
Check ($toggleRows.Count -eq 0) 'the update, experimental and licence rows are Mode = Toggle with no Event'

# NavSettingsList: its SelectionChanged is attached and navigates through the list-taking handler; the TabNavigation swap sets both lists on every page change.
function Get-NavSettingsFindings([string]$Text){
    $found=New-Object System.Collections.ArrayList
    $a=ConvertTo-PinAst $Text
    $hooks=@($a.FindAll({param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$n.Member.Value -ceq 'Add_SelectionChanged' -and $n.Expression.Extent.Text -cmatch 'NavSettingsList'},$true))
    if($hooks.Count -ne 1){[void]$found.Add("NavSettingsList.Add_SelectionChanged is attached $($hooks.Count) times, expected 1")}
    else{
        $cmds=@($hooks[0].FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -ceq 'Invoke-FastLlmUiFluentNavSelection'},$true))
        $ok=$false
        foreach($c in $cmds){ $els=@($c.CommandElements); for($i=1;$i -lt $els.Count-1;$i++){ if($els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and [string]$els[$i].ParameterName -ceq 'List' -and $els[$i+1].Extent.Text -ceq 'NavSettingsList'){$ok=$true} } }
        if(-not $ok){[void]$found.Add('the NavSettingsList handler does not call Invoke-FastLlmUiFluentNavSelection -List NavSettingsList')}
    }
    $swap=@($a.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Update-FastLlmUiFluentNavLists'},$true))
    if($swap.Count -ne 1){[void]$found.Add('Update-FastLlmUiFluentNavLists is not defined exactly once')}
    else{
        $loops=@($swap[0].FindAll({param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst]},$true))
        if($loops.Count -ne 1 -or $loops[0].Condition.Extent.Text -cnotmatch "'NavList'" -or $loops[0].Condition.Extent.Text -cnotmatch "'NavSettingsList'"){[void]$found.Add('the TabNavigation swap does not loop over both NavList and NavSettingsList')}
        else{
            $ifs=@($loops[0].Body.FindAll({param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -ceq '$name -ceq $Holder'},$true))
            if($ifs.Count -ne 1){[void]$found.Add('the swap does not branch on the holder list')}
            else{
                $setOf={param($block) @($block.FindAll({param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Static -and [string]$n.Member.Value -ceq 'SetTabNavigation'},$true))}
                $holderSet=@(& $setOf $ifs[0].Clauses[0].Item2)
                $otherSet=@(); if($null -ne $ifs[0].ElseClause){$otherSet=@(& $setOf $ifs[0].ElseClause)}
                if($holderSet.Count -ne 1 -or $holderSet[0].Extent.Text -cnotmatch 'KeyboardNavigationMode\]::Once'){[void]$found.Add('the holder list is not set to TabNavigation Once')}
                if($otherSet.Count -ne 1 -or $otherSet[0].Extent.Text -cnotmatch 'KeyboardNavigationMode\]::None'){[void]$found.Add('the other list is not set to TabNavigation None')}
                # The item WPF remembers as last focused survives TabNavigation None, so every item is also a tab stop only in the holder list.
                $tabStops=@($loops[0].Body.FindAll({param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Static -and [string]$n.Member.Value -ceq 'SetIsTabStop'},$true))
                $itemLoops=@($loops[0].Body.FindAll({param($n) $n -is [System.Management.Automation.Language.ForStatementAst]},$true))
                if($tabStops.Count -ne 1 -or $itemLoops.Count -ne 1 -or $tabStops[0].Extent.StartOffset -lt $itemLoops[0].Extent.StartOffset -or $tabStops[0].Extent.EndOffset -gt $itemLoops[0].Extent.EndOffset -or $tabStops[0].Arguments.Count -ne 2 -or $tabStops[0].Arguments[0].Extent.Text -cne '$item' -or $tabStops[0].Arguments[1].Extent.Text -cnotmatch '^\(\$name -ceq \$Holder\)$'){[void]$found.Add('the swap does not set KeyboardNavigation.SetIsTabStop($item, ($name -ceq $Holder)) on every item of both lists')}
            }
        }
    }
    $page=@($a.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Set-FastLlmUiFluentPage'},$true))
    if($page.Count -ne 1 -or @($page[0].FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -ceq 'Update-FastLlmUiFluentNavLists'},$true)).Count -ne 1){[void]$found.Add('Set-FastLlmUiFluentPage does not call Update-FastLlmUiFluentNavLists exactly once')}
    return ,$found.ToArray()
}
$navFindings=Get-NavSettingsFindings $shellText
foreach($f in $navFindings){Write-Host "FINDING: $f"}
Check ($navFindings.Count -eq 0) 'NavSettingsList navigates through Invoke-FastLlmUiFluentNavSelection -List NavSettingsList, and every page change swaps TabNavigation Once/None between the two lists'
$navPlants=[ordered]@{
    'the NavSettingsList handler removed'=$shellText.Replace("    `$f['Els']['NavSettingsList'].Add_SelectionChanged({ Invoke-FastLlmUiFluentNavSelection -List NavSettingsList })`n",'')
    'the NavSettingsList handler routed to NavList'=$shellText.Replace("Add_SelectionChanged({ Invoke-FastLlmUiFluentNavSelection -List NavSettingsList })","Add_SelectionChanged({ Invoke-FastLlmUiFluentNavSelection -List NavList })")
    'the swap sets only NavList'=$shellText.Replace("foreach (`$name in 'NavList', 'NavSettingsList') {","foreach (`$name in 'NavList') {")
    'the swap Once and None exchanged'=$shellText.Replace('SetTabNavigation($list, [System.Windows.Input.KeyboardNavigationMode]::Once)','SetTabNavigation($list, [System.Windows.Input.KeyboardNavigationMode]::Tmp)').Replace('SetTabNavigation($list, [System.Windows.Input.KeyboardNavigationMode]::None)','SetTabNavigation($list, [System.Windows.Input.KeyboardNavigationMode]::Once)').Replace('KeyboardNavigationMode]::Tmp)','KeyboardNavigationMode]::None)')
    'the item tab stops not set'=$shellText.Replace('[System.Windows.Input.KeyboardNavigation]::SetIsTabStop($item, ($name -ceq $Holder))','$null = $item')
    'the item tab stops set in both lists'=$shellText.Replace('SetIsTabStop($item, ($name -ceq $Holder))','SetIsTabStop($item, $true)')
    'the page change not swapping'=$shellText.Replace('Update-FastLlmUiFluentNavLists -Holder','Update-FastLlmUiFluentNavListsGone -Holder')
}
foreach($k in $navPlants.Keys){ Check ($navPlants[$k] -cne $shellText -and (Get-NavSettingsFindings $navPlants[$k]).Count -ge 1) "mutation check: the pane pin flags: $k" }

# The key box click: today's $keyBox.Add_Click body, keyTouched set and IsThreeState cleared, attached to SettingsKeyBox.
function Get-KeyClickFindings([string]$Text){
    $found=New-Object System.Collections.ArrayList
    $a=ConvertTo-PinAst $Text
    $fn=@($a.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Invoke-FastLlmUiFluentSettingsKeyClick'},$true))
    if($fn.Count -ne 1){[void]$found.Add('Invoke-FastLlmUiFluentSettingsKeyClick is not defined exactly once');return ,$found.ToArray()}
    $asg=@($fn[0].Body.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst]},$true))
    $touch=@($asg|Where-Object{$_.Left.Extent.Text -cmatch 'keyTouched' -and $_.Right.Extent.Text -ceq '$true'})
    $three=@($asg|Where-Object{$_.Left.Extent.Text -cmatch '\.IsThreeState$' -and $_.Right.Extent.Text -ceq '$false'})
    if($touch.Count -ne 1){[void]$found.Add('the key click does not set keyTouched to $true')}
    if($three.Count -ne 1){[void]$found.Add('the key click does not set IsThreeState to $false')}
    $att=@($a.FindAll({param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$n.Member.Value -ceq 'Add_Click' -and $n.Expression.Extent.Text -cmatch 'SettingsKeyBox'},$true))
    if($att.Count -ne 1 -or @($att[0].FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -ceq 'Invoke-FastLlmUiFluentSettingsKeyClick'},$true)).Count -ne 1){[void]$found.Add('SettingsKeyBox.Add_Click does not call Invoke-FastLlmUiFluentSettingsKeyClick')}
    return ,$found.ToArray()
}
$keyClickGood=@'
function Invoke-FastLlmUiFluentSettingsKeyClick {
    $script:FastLlmUiFluentSettings['Held'].keyTouched = $true
    $script:FastLlmUiFluentSettings['Els']['SettingsKeyBox'].IsThreeState = $false
}
function Initialize-FastLlmUiFluentSettings {
    $Els['SettingsKeyBox'].Add_Click({ param($sender, $routed) Invoke-FastLlmUiFluentSettingsKeyClick })
}
'@
Check ((Get-KeyClickFindings $keyClickGood).Count -eq 0) 'self-check: a key click that sets both and is attached passes'
Check ((Get-KeyClickFindings $keyClickGood.Replace("    `$script:FastLlmUiFluentSettings['Held'].keyTouched = `$true`n",'')).Count -ge 1) 'mutation check: a key click that does not set keyTouched is flagged'
Check ((Get-KeyClickFindings $keyClickGood.Replace("    `$script:FastLlmUiFluentSettings['Els']['SettingsKeyBox'].IsThreeState = `$false`n",'')).Count -ge 1) 'mutation check: a key click that leaves IsThreeState on is flagged'
Check ((Get-KeyClickFindings $keyClickGood.Replace("    `$Els['SettingsKeyBox'].Add_Click({ param(`$sender, `$routed) Invoke-FastLlmUiFluentSettingsKeyClick })`n",'')).Count -ge 1) 'mutation check: a key click handler that is never attached is flagged'
Check ((Get-KeyClickFindings $keyClickGood.Replace('keyTouched = $true','keyTouched = $false')).Count -ge 1) 'mutation check: keyTouched set to $false is flagged'
$keyClickReal=Get-KeyClickFindings $settingsText
foreach($f in $keyClickReal){Write-Host "FINDING: $f"}
Check ($settingsText -ne '' -and $keyClickReal.Count -eq 0) 'the Settings key box click sets keyTouched and clears IsThreeState'
# ---- PR 3c review fix: Settings save prompt, close and Save structure pins (AST on the real page text, each with a text mutant) ----
function Get-SettingsFlowFindings([string]$Text){
    $found=New-Object System.Collections.ArrayList
    $a=ConvertTo-PinAst $Text
    $fnOf={param($name) @($a.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))}
    $isCall={param($n,$cmd) $n -is [System.Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -ceq $cmd}
    # 1. Only leaving the page discards: the one Discard call of the exit decision sits in an if on $Reason -ceq 'leave'; the close entry point never calls it.
    $resolve=@(& $fnOf 'Resolve-FastLlmUiFluentSettingsExit')
    $closeFn=@(& $fnOf 'Test-FastLlmUiFluentSettingsCloseRefused')
    if($resolve.Count -ne 1 -or $closeFn.Count -ne 1){[void]$found.Add('Resolve-FastLlmUiFluentSettingsExit or Test-FastLlmUiFluentSettingsCloseRefused is not defined exactly once')}
    else{
        $dis=@($resolve[0].FindAll({param($n) & $isCall $n 'Invoke-FastLlmUiFluentSettingsDiscard'},$true))
        if($dis.Count -ne 1){[void]$found.Add("the exit decision calls Discard $($dis.Count) times, expected 1")}
        else{
            $p=$dis[0].Parent; $guarded=$false
            while($null -ne $p -and $p -isnot [System.Management.Automation.Language.FunctionDefinitionAst]){ if($p -is [System.Management.Automation.Language.IfStatementAst] -and $p.Clauses[0].Item1.Extent.Text -ceq "`$Reason -ceq 'leave'"){$guarded=$true}; $p=$p.Parent }
            if(-not $guarded){[void]$found.Add("the Discard call of the exit decision is not guarded by `$Reason -ceq 'leave' (a close must not discard before the FormClosing guards run)")}
        }
        if(@($closeFn[0].FindAll({param($n) & $isCall $n 'Invoke-FastLlmUiFluentSettingsDiscard'},$true)).Count -ne 0){[void]$found.Add('the close entry point calls Discard')}
        $reasonArgs=@($closeFn[0].FindAll({param($n) & $isCall $n 'Resolve-FastLlmUiFluentSettingsExit'},$true))
        if($reasonArgs.Count -ne 1 -or $reasonArgs[0].Extent.Text -cnotmatch "-Reason 'close'"){[void]$found.Add("the close entry point does not resolve with -Reason 'close'")}
    }
    # 2. The prompt: Enter, Escape and the first focus all land on Cancel (lead ruling 3); the tray menu is made unavailable before it shows and restored in a finally.
    $prompt=@(& $fnOf 'Show-FastLlmUiFluentSavePrompt')
    if($prompt.Count -ne 1){[void]$found.Add('Show-FastLlmUiFluentSavePrompt is not defined exactly once')}
    else{
        # 4b: the prompt is on the dialog host: Enter and Escape are the Enter and Escape targets of its one dialog call (the host focuses the Enter target first).
        $dlgCalls=@($prompt[0].FindAll({param($n) & $isCall $n 'New-FastLlmUiFluentDialog'},$true))
        if($dlgCalls.Count -ne 1){[void]$found.Add('the prompt does not build exactly one host dialog')}
        else{
            foreach($param in 'Enter','Escape'){
                $els=@($dlgCalls[0].CommandElements); $val=$null
                for($i=1;$i -lt $els.Count-1;$i++){ if($els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and [string]$els[$i].ParameterName -ceq $param){$val=[string]$els[$i+1].Extent.Text} }
                if($val -cne "'Cancel'"){[void]$found.Add("the prompt's $param target is not the Cancel button")}
            }
            $captions=@($prompt[0].FindAll({param($n) $n -is [System.Management.Automation.Language.HashtableAst]},$true)|ForEach-Object{ ($_.KeyValuePairs|ForEach-Object{[string]$_.Item1.Extent.Text}) -join ',' })
            if(@($captions) -cnotcontains 'Save,DontSave,Cancel'){[void]$found.Add('the prompt buttons are not Save, DontSave and Cancel in that order')}
            $saveOn=@($prompt[0].FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq "`$dialog['Buttons']['Save'].IsEnabled" -and $n.Right.Extent.Text -ceq '$SaveEnabled'},$true))
            if($saveOn.Count -ne 1){[void]$found.Add('the Save button is not enabled by SaveEnabled')}
            if($prompt[0].Extent.Text -cmatch 'System\.Windows\.Forms|ShowDialog'){[void]$found.Add('the prompt still builds a WinForms form')}
        }
        $trays=@($prompt[0].FindAll({param($n) & $isCall $n 'SetTrayMenuAvailable'},$true))
        $off=@($trays|Where-Object{$_.Extent.Text -ceq 'SetTrayMenuAvailable $false'}); $on=@($trays|Where-Object{$_.Extent.Text -ceq 'SetTrayMenuAvailable $true'})
        $tries=@($prompt[0].FindAll({param($n) $n -is [System.Management.Automation.Language.TryStatementAst]},$true))
        if($off.Count -ne 1 -or $on.Count -ne 1 -or $tries.Count -ne 1 -or $null -eq $tries[0].Finally){[void]$found.Add('the prompt does not call SetTrayMenuAvailable $false once and $true once around one try with a finally')}
        else{
            if($off[0].Extent.EndOffset -gt $tries[0].Extent.StartOffset){[void]$found.Add('SetTrayMenuAvailable $false is not called before the try that shows the prompt')}
            if($on[0].Extent.StartOffset -lt $tries[0].Finally.Extent.StartOffset -or $on[0].Extent.EndOffset -gt $tries[0].Finally.Extent.EndOffset){[void]$found.Add('SetTrayMenuAvailable $true is not called in the finally')}
        }
    }
    # 3. Save: the unavailable guard first, the refused-save return after the save try and before the reload, the reload after the save try and before the after-OK block.
    $save=@(& $fnOf 'Invoke-FastLlmUiFluentSettingsSave')
    if($save.Count -ne 1){[void]$found.Add('Invoke-FastLlmUiFluentSettingsSave is not defined exactly once')}
    else{
        $top=@($save[0].Body.EndBlock.Statements)
        $tryIdx=@(); for($i=0;$i -lt $top.Count;$i++){ if($top[$i] -is [System.Management.Automation.Language.TryStatementAst]){$tryIdx+=$i} }
        if($tryIdx.Count -ne 3){[void]$found.Add("Save has $($tryIdx.Count) top-level try statements, expected 3 (save, reload, after-OK)")}
        else{
            $guard=-1; for($i=0;$i -lt $top.Count;$i++){ if($top[$i] -is [System.Management.Automation.Language.IfStatementAst] -and $top[$i].Clauses[0].Item1.Extent.Text -ceq '-not [bool] $script:settingsButton.Enabled' -and $top[$i].Clauses[0].Item2.Extent.Text -cmatch 'return \$false'){$guard=$i;break} }
            if($guard -lt 0 -or $guard -gt $tryIdx[0]){[void]$found.Add('Save has no unavailable guard (-not [bool] $script:settingsButton.Enabled -> return $false) before the save try')}
            $refused=-1; for($i=0;$i -lt $top.Count;$i++){ if($top[$i] -is [System.Management.Automation.Language.IfStatementAst] -and $top[$i].Clauses[0].Item1.Extent.Text -ceq '-not $saved' -and $top[$i].Clauses[0].Item2.Extent.Text -cmatch '^\{\s*return \$false\s*\}$'){$refused=$i;break} }
            if($refused -le $tryIdx[0] -or $refused -ge $tryIdx[1]){[void]$found.Add('Save has no `if (-not $saved) { return $false }` between the save try and the reload try')}
            $reload=@($top[$tryIdx[1]].Body.FindAll({param($n) & $isCall $n 'Update-FastLlmUiFluentSettingsLoad'},$true))
            if($reload.Count -ne 1){[void]$found.Add('the reload try between the refused-save return and the after-OK block does not call Update-FastLlmUiFluentSettingsLoad once')}
            if(@($top[$tryIdx[2]].Body.FindAll({param($n) & $isCall $n 'RefreshUiSwitchState'},$true)).Count -ne 1){[void]$found.Add('the last try is not the after-OK block (RefreshUiSwitchState)')}
        }
    }
    return ,$found.ToArray()
}
$flowFindings=Get-SettingsFlowFindings $settingsText
foreach($f in $flowFindings){Write-Host "FINDING: $f"}
Check ($settingsText -ne '' -and $flowFindings.Count -eq 0) 'the Settings close never discards, the prompt defaults to Cancel and restores the tray menu in a finally, and Save keeps its guard, refused-save return and reload in order'
$flowPlants=[ordered]@{
    'a close that discards (the guard removed)'=$settingsText.Replace("if (`$Reason -ceq 'leave') { Invoke-FastLlmUiFluentSettingsDiscard }","Invoke-FastLlmUiFluentSettingsDiscard")
    'a close that discards (the guard on close)'=$settingsText.Replace("if (`$Reason -ceq 'leave') { Invoke-FastLlmUiFluentSettingsDiscard }","if (`$Reason -ceq 'close') { Invoke-FastLlmUiFluentSettingsDiscard }")
    'Enter saves (-Enter Save; the host also focuses the Enter target)'=$settingsText.Replace("-Enter 'Cancel' -Escape 'Cancel'","-Enter 'Save' -Escape 'Cancel'")
    'Escape saves (-Escape Save)'=$settingsText.Replace("-Enter 'Cancel' -Escape 'Cancel'","-Enter 'Cancel' -Escape 'Save'")
    'the first focus on Dont save (-Enter DontSave)'=$settingsText.Replace("-Enter 'Cancel' -Escape 'Cancel'","-Enter 'DontSave' -Escape 'Cancel'")
    'Save always enabled'=$settingsText.Replace("`$dialog['Buttons']['Save'].IsEnabled = `$SaveEnabled","`$dialog['Buttons']['Save'].IsEnabled = `$true")
    'the prompt back on a WinForms form'=$settingsText.Replace('    $body = New-Object System.Windows.Controls.TextBlock','    $body = New-Object System.Windows.Forms.Label')
    'the refused-save return dropped'=$settingsText.Replace("    if(-not `$saved){return `$false}`n",'')
    'the unavailable guard dropped'=$settingsText.Replace("    if (-not [bool] `$script:settingsButton.Enabled) {`n        Update-FastLlmUiFluentSettings`n        return `$false`n    }`n",'')
    'the reload after Save dropped'=$settingsText.Replace("        Update-FastLlmUiFluentSettingsLoad`n    }catch{ShowFailure",'        $null = 1'+"`n    }catch{ShowFailure")
    'the tray restore moved out of the finally'=$settingsText.Replace('finally { SetTrayMenuAvailable $true }','finally { }')
    'the tray never made unavailable'=$settingsText.Replace("    SetTrayMenuAvailable `$false`n",'')
}
foreach($k in $flowPlants.Keys){ Check ($flowPlants[$k] -cne $settingsText -and (Get-SettingsFlowFindings $flowPlants[$k]).Count -ge 1) "mutation check: the Settings flow pin flags: $k" }
# ===== end PR 3c: Settings pins (Task 2) =====



# ===== PR 4a: the dialog host and the fluent message box (Tasks 2 and 3) =====
# Every pin reads src/FastLlm.UiFluentDialogs.ps1 (AST and the registered markup) and runs again on planted mutants, so each is proven on every platform.
$dlgText=Get-OptionalText 'src/FastLlm.UiFluentDialogs.ps1'
$dlgHome=Get-OptionalText 'src/FastLlm.UiFluentHome.ps1'
Check ($dlgText -ne '') 'src/FastLlm.UiFluentDialogs.ps1 exists'
$dlgShell=Get-OptionalText 'src/FastLlm.UiFluentShell.ps1'
Check ($dlgShell.Contains(". (Join-Path `$PSScriptRoot 'FastLlm.UiFluentDialogs.ps1')")) 'the shell dot-sources the dialog host like the page files'
function Get-DlgXaml([string]$Text){
    $m=[regex]::Match($Text,"(?s)\`$script:FastLlmUiXaml\['FastLlm.Dialog'\] = @'\r?\n(.*?)\r?\n'@")
    if($m.Success){return $m.Groups[1].Value}
    return ''
}
function Get-DlgFn([string]$Text,[string]$Name){
    $a=ConvertTo-PinAst $Text
    $f=@($a.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name},$true))
    if($f.Count -ne 1){return $null}
    return $f[0]
}
function Test-DlgCall($n,[string]$Name){ return ($n -is [System.Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -ceq $Name) }
function Get-DlgParamText($Call,[string]$Param){
    $els=@($Call.CommandElements)
    for($i=1;$i -lt $els.Count-1;$i++){ if($els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and [string]$els[$i].ParameterName -ceq $Param){return [string]$els[$i+1].Extent.Text} }
    return $null
}
function Get-DlgFindings([string]$Text){
    $f=New-Object System.Collections.ArrayList
    $ast=ConvertTo-PinAst $Text
    # --- the markup: constant, parses, no event attribute, no IsDefault or IsCancel at all, the footer presenter wraps ---
    $xaml=Get-DlgXaml $Text
    if($xaml -eq ''){[void]$f.Add('the FastLlm.Dialog markup is not a constant here-string in the table');return ,$f.ToArray()}
    $x=$null; try{$x=[xml]$xaml}catch{[void]$f.Add('the dialog markup does not parse')}
    if($null -ne $x){
        foreach($n in $x.SelectNodes('//*')){
            foreach($a in $n.Attributes){
                if($a.LocalName -cin @('IsDefault','IsCancel')){[void]$f.Add("the dialog markup sets $($a.LocalName) (Enter and Escape go through the key plan)")}
                if($a.LocalName -cin @('Click','Loaded','Closing','Closed','KeyDown','PreviewKeyDown','KeyUp','MouseDown','Checked','TextChanged','SelectionChanged')){[void]$f.Add("the dialog markup has the event attribute $($a.LocalName)")}
            }
        }
        $xn='http://schemas.microsoft.com/winfx/2006/xaml'
        $footer=@($x.SelectNodes('//*[local-name()="UniformGrid"]')|Where-Object{$_.GetAttribute('Name',$xn) -ceq 'DlgFooter'})
        if($footer.Count -ne 1){[void]$f.Add('the dialog markup has no DlgFooter panel')}
        else{
            # An implicit style in the footer Resources does not reach the element a Button template makes from string content, so the wrap is in code (checked below).
            if(@($footer[0].SelectNodes("*[local-name()='UniformGrid.Resources']")).Count -ne 0){[void]$f.Add('the footer keeps a Resources block that cannot reach the button captions')}
        }
        foreach($need in 'DlgIconHost','DlgBodyScroll','DlgFooter'){ if(@($x.SelectNodes('//*')|Where-Object{$_.GetAttribute('Name',$xn) -ceq $need}).Count -ne 1){[void]$f.Add("the dialog markup has no $need")} }
    }
    # --- no IsDefault or IsCancel member anywhere in the code ---
    foreach($n in @($ast.FindAll({param($a) $a -is [System.Management.Automation.Language.MemberExpressionAst] -and $a.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and @('IsDefault','IsCancel') -ccontains [string]$a.Member.Value},$true))){[void]$f.Add("code uses $($n.Member.Value): $($n.Extent.Text)")}
    # --- the dialog builder ---
    $new=Get-DlgFn $Text 'New-FastLlmUiFluentDialog'
    if($null -eq $new){[void]$f.Add('New-FastLlmUiFluentDialog is not defined exactly once')}
    else{
        $nt=$new.Extent.Text
        if($nt -cnotmatch '\$captionText = New-Object System\.Windows\.Controls\.AccessText' -or $nt -cnotmatch '\$captionText\.TextWrapping = \[System\.Windows\.TextWrapping\]::Wrap\b' -or $nt -cnotmatch '\$button\.Content = \$captionText\b'){[void]$f.Add('a footer button caption is not a code-built wrapping AccessText')}
        if($nt -cnotmatch 'AutomationProperties\]::SetName\(\$button, \$caption\)'){[void]$f.Add('a footer button is not named by its caption')}
        $inv=@($new.FindAll({param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst]},$true))
        $keyHook=@($inv|Where-Object{$_.Member.Extent.Text -ceq 'Add_PreviewKeyDown' -and $_.Expression.Extent.Text -ceq '$win'})
        if($keyHook.Count -ne 1){[void]$f.Add('the dialog Window has no single PreviewKeyDown handler')}
        else{
            $h=$keyHook[0].Extent.Text
            if($h -cnotmatch 'Key\]::Return' -or $h -cnotmatch 'Key\]::Escape'){[void]$f.Add('the key handler does not read Return and Escape')}
            if($h -cnotmatch "\`$state\['Enter'\]" -or $h -cnotmatch "\`$state\['Escape'\]"){[void]$f.Add('the key handler does not answer the Enter and Escape targets')}
            if($h -cnotmatch [regex]::Escape("`$state['Enter'] -cne '') { `$e.Handled = `$true; & `$close ([string] `$state['Enter'])") -or $h -cnotmatch [regex]::Escape("`$state['Escape'] -cne '') { & `$close ([string] `$state['Escape'])")){[void]$f.Add('the key handler does not close with the matching target')}
            if($h -cnotmatch 'FocusedElement' -or $h -cnotmatch '-is \[System.Windows.Controls.Button\]'){[void]$f.Add('the key handler lets Enter override a focused button')}
            # Enter on a focused button presses that button through the dialog (a footer button answers its own id; any other gets its Click), never left to the
            # Button's own AcceptsReturn handling (CI-proof: initial focus is on a footer button).
            # An open drop-down list takes Escape itself: the Escape branch returns, before it handles the key, for a ComboBoxItem and for an open ComboBox (R6).
            $escAt=$h.IndexOf('Key]::Escape',[StringComparison]::Ordinal)
            $escHandled=$h.IndexOf('$e.Handled = $true',[Math]::Max($escAt,0),[StringComparison]::Ordinal)
            $itemAt=$h.IndexOf('if ($focused -is [System.Windows.Controls.ComboBoxItem]) { return }',[StringComparison]::Ordinal)
            $openAt=$h.IndexOf('if ($focused -is [System.Windows.Controls.ComboBox] -and [bool] $focused.IsDropDownOpen) { return }',[StringComparison]::Ordinal)
            if($escAt -lt 0 -or $itemAt -lt $escAt -or $itemAt -gt $escHandled){[void]$f.Add('Escape on an open drop-down item answers the dialog (it must close the list only)')}
            if($escAt -lt 0 -or $openAt -lt $escAt -or $openAt -gt $escHandled){[void]$f.Add('Escape on an open ComboBox answers the dialog (it must close the list only)')}
            if($h -cnotmatch [regex]::Escape('& $close $focusedId') -or $h -cnotmatch [regex]::Escape('RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))')){[void]$f.Add('a focused button is not pressed by the dialog on Enter')}
        }
        $closing=@($inv|Where-Object{$_.Member.Extent.Text -ceq 'Add_Closing'})
        if($closing.Count -ne 1){[void]$f.Add('the dialog Window has no single Closing handler')}
        else{
            $c=$closing[0].Extent.Text
            # Once an answer is set (a button, or the key plan) the close goes through: the early return is the first thing the handler does (R8).
            $earlyAt=$c.IndexOf("if ([string] `$state['Result'] -cne '') { return }",[StringComparison]::Ordinal)
            $cancelAt=$c.IndexOf('$e.Cancel = $true',[StringComparison]::Ordinal)
            if($earlyAt -lt 0 -or ($cancelAt -ge 0 -and $earlyAt -gt $cancelAt)){[void]$f.Add('the Closing handler does not let a close through once the dialog has an answer')}
            if($c -cnotmatch '\$e\.Cancel = \$true'){[void]$f.Add('the Closing handler never refuses a close')}
            if($c -cnotmatch "CloseEnabled'\]"){[void]$f.Add('the Closing handler does not read CloseEnabled')}
            if($c -cnotmatch "\`$state\['Result'\] = \[string\] \`$state\['Escape'\]"){[void]$f.Add('the close box does not answer the Escape target')}
        }
        $names=@($inv|Where-Object{$_.Member.Extent.Text -ceq 'SetName' -and $_.Extent.Text -ceq '[System.Windows.Automation.AutomationProperties]::SetName($button, $caption)'})
        if($names.Count -ne 1){[void]$f.Add('every code-built button is not named by its caption')}
        $loaded=@($inv|Where-Object{$_.Member.Extent.Text -ceq 'Add_Loaded' -and $_.Extent.Text -cmatch '\$target\.Focus\(\)'})
        if($loaded.Count -ne 1){[void]$f.Add('the first focus is not set on the target in Loaded')}
        if($new.Extent.Text.IndexOf('@($Enter, $Escape)',[StringComparison]::Ordinal) -lt 0){[void]$f.Add('the first focus target is not chosen from Enter, then Escape')}
        if($new.Extent.Text.IndexOf('$win.Tag = $result',[StringComparison]::Ordinal) -lt 0){[void]$f.Add('the dialog Window.Tag is not the returned table (the test answerer reads it)')}
        # The owner's resources (the styles and the live theme dictionary) are merged into the dialog, so it follows the theme (R9).
        $merge=@($inv|Where-Object{$_.Member.Extent.Text -ceq 'Add' -and $_.Expression.Extent.Text -ceq '$win.Resources.MergedDictionaries' -and @($_.Arguments).Count -eq 1 -and $_.Arguments[0].Extent.Text -ceq '$ownerWindow.Resources'})
        if($merge.Count -ne 1){[void]$f.Add('the owner resources are not merged into the dialog')}
        # A hidden owner is recorded for Show (its handle), only when the owner exists and is not visible (R5).
        if($new.Extent.Text.IndexOf('if ($null -ne $ownerWindow -and -not [bool] $ownerWindow.IsVisible) {',[StringComparison]::Ordinal) -lt 0){[void]$f.Add('the hidden owner is not recorded only for a hidden owner')}
        if($new.Extent.Text.IndexOf('HiddenOwner = $hiddenOwner }',[StringComparison]::Ordinal) -lt 0){[void]$f.Add('the dialog table does not carry the hidden owner handle')}
        # Ownership: the Owner is set only inside an if whose condition reads IsVisible (a hidden owner is never set).
        $own=@($new.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$win.Owner'},$true))
        if($own.Count -ne 1){[void]$f.Add('the Owner is not assigned exactly once')}
        else{
            $p=$own[0].Parent; while($null -ne $p -and $p -isnot [System.Management.Automation.Language.IfStatementAst]){$p=$p.Parent}
            if($null -eq $p -or $p.Clauses[0].Item1.Extent.Text -cnotmatch 'IsVisible'){[void]$f.Add('the Owner is set without the owner-visible guard')}
        }
        if(@($new.FindAll({param($n) Test-DlgCall $n 'ConvertTo-FastLlmUiAccessText'},$true)).Count -ne 1){[void]$f.Add('the button captions do not go through ConvertTo-FastLlmUiAccessText')}
    }
    # --- the dialog is shown modally and answers its id ---
    $show=Get-DlgFn $Text 'Show-FastLlmUiFluentDialog'
    if($null -eq $show -or @($show.FindAll({param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Extent.Text -ceq 'ShowDialog'},$true)).Count -ne 1){[void]$f.Add('Show-FastLlmUiFluentDialog does not call ShowDialog once')}
    # A hidden owner is disabled by handle before ShowDialog and enabled again in a finally (R5): a system box disables its owner even when it is in the tray.
    if($null -ne $show){
        $tries=@($show.FindAll({param($n) $n -is [System.Management.Automation.Language.TryStatementAst]},$true))
        if($tries.Count -ne 1 -or $null -eq $tries[0].Finally -or $tries[0].Finally.Extent.Text -cnotmatch [regex]::Escape('SetWindowEnabled($hiddenOwner, $true)')){[void]$f.Add('the hidden owner is not enabled again in a finally')}
        elseif($tries[0].Body.Extent.Text -cnotmatch 'ShowDialog\(\)'){[void]$f.Add('ShowDialog is not inside the try that restores the hidden owner')}
        $offAt=$show.Extent.Text.IndexOf('SetWindowEnabled($hiddenOwner, $false)',[StringComparison]::Ordinal)
        $tryAt=$show.Extent.Text.IndexOf('try {',[StringComparison]::Ordinal)
        if($offAt -lt 0 -or $tryAt -lt 0 -or $offAt -gt $tryAt){[void]$f.Add('the hidden owner is not disabled before ShowDialog')}
    }
    # --- the icon table has a row for every name of every MessageBoxIcon value, with the glyph and help of that value's canonical row (R4, R10) ---
    $im=[regex]::Match($Text,"(?s)\`$script:FastLlmUiFluentDialogIcons = @\{(.*?)\r?\n\}")
    if(-not $im.Success){[void]$f.Add('the icon table is missing')}
    else{
        $rows=@{}
        foreach($r in [regex]::Matches($im.Groups[1].Value,"(?m)^\s*(\w+)\s*=\s*@\{\s*Glyph\s*=\s*(0x[0-9A-Fa-f]+|\d+);\s*Help\s*=\s*'([^']*)'\s*\}")){ $rows[$r.Groups[1].Value]=$r.Groups[2].Value+'|'+$r.Groups[3].Value }
        # the nine names of System.Windows.Forms.MessageBoxIcon with their values (None 0, Hand/Stop/Error 16, Question 32, Exclamation/Warning 48, Asterisk/Information 64)
        $canon=[ordered]@{None='None';Error='Error';Hand='Error';Stop='Error';Question='Question';Warning='Warning';Exclamation='Warning';Information='Information';Asterisk='Information'}
        foreach($name in $canon.Keys){
            if(-not $rows.ContainsKey($name)){[void]$f.Add("the icon table has no row for MessageBoxIcon.$name");continue}
            if($rows[$name] -cne $rows[[string]$canon[$name]]){[void]$f.Add("the icon row $name is not the row of $($canon[$name])")}
        }
    }
    # --- the icon is a decorative text block ---
    $icon=Get-DlgFn $Text 'Set-FastLlmUiFluentDialogIcon'
    if($null -eq $icon -or $icon.Extent.Text -cnotmatch 'New-Object Bitworks\.FastLlm\.DecorativeTextBlock'){[void]$f.Add('the icon is not a DecorativeTextBlock')}
    # --- the DialogResult conversion (D1 a: an enum value, never a string) ---
    $conv=Get-DlgFn $Text 'ConvertTo-FastLlmUiFluentDialogResult'
    if($null -eq $conv){[void]$f.Add('ConvertTo-FastLlmUiFluentDialogResult is not defined exactly once')}
    else{
        $rets=@($conv.FindAll({param($n) $n -is [System.Management.Automation.Language.ReturnStatementAst]},$true))
        if($rets.Count -ne 1 -or $rets[0].Pipeline.Extent.Text -cne '[System.Enum]::Parse([System.Windows.Forms.DialogResult], [string] $name)'){[void]$f.Add('the answer is not returned as a [System.Windows.Forms.DialogResult] value')}
        if($conv.Extent.Text -cnotmatch "FastLlmUiFluentDialogResultNames\[\`$Id\]"){[void]$f.Add('the answer is not mapped through the result table')}
    }
    # --- the message box ---
    $box=Get-DlgFn $Text 'Show-FastLlmUiFluentMessageBox'
    if($null -eq $box){[void]$f.Add('Show-FastLlmUiFluentMessageBox is not defined exactly once')}
    else{
        $plan=@($box.FindAll({param($n) Test-DlgCall $n 'Get-FastLlmUiDialogKeyPlan'},$true))
        if($plan.Count -ne 1 -or (Get-DlgParamText $plan[0] 'Buttons') -cne '$Buttons' -or (Get-DlgParamText $plan[0] 'DefaultButton') -cne '$DefaultButton'){[void]$f.Add('the box does not call the key plan once with its Buttons and DefaultButton')}
        $dlg=@($box.FindAll({param($n) Test-DlgCall $n 'New-FastLlmUiFluentDialog'},$true))
        if($dlg.Count -ne 1){[void]$f.Add('the box does not build one dialog')}
        else{
            $want=@{Enter="([string] `$plan['enter'])";Escape="([string] `$plan['escape'])";CloseEnabled="([bool] `$plan['closeEnabled'])";Owner='$Owner';Title='$Caption'}
            foreach($k in $want.Keys){ if((Get-DlgParamText $dlg[0] $k) -cne $want[$k]){[void]$f.Add("the box dialog's -$k is not $($want[$k])")} }
        }
        $last=@($box.Body.EndBlock.Statements)[-1]
        if($last -isnot [System.Management.Automation.Language.ReturnStatementAst] -or $last.Pipeline.Extent.Text -cne '(ConvertTo-FastLlmUiFluentDialogResult -Id $answer)'){[void]$f.Add('the box does not return the converted DialogResult')}
        foreach($k in 'BoxOK','BoxCancel','BoxYes','BoxNo'){ if($box.Extent.Text -cnotmatch "\`$s\.$k\b"){[void]$f.Add("the box does not read the string $k")} }
        if($box.Extent.Text -cmatch 'MessageBox\]::Show'){[void]$f.Add('the fluent box calls the WinForms MessageBox')}
    }
    # --- the answer table ---
    $m=[regex]::Match($Text,"(?s)\`$script:FastLlmUiFluentDialogResultNames = @\{(.*?)\}")
    if(-not $m.Success){[void]$f.Add('the result table is missing')}
    else{
        $pairs=@([regex]::Matches($m.Groups[1].Value,"(\w+)\s*=\s*'(\w+)'")|ForEach-Object{$_.Groups[1].Value+'='+$_.Groups[2].Value})
        if((($pairs|Sort-Object) -join ',') -cne 'Cancel=Cancel,No=No,OK=OK,Yes=Yes'){[void]$f.Add("the result table is not the four identity pairs: $($pairs -join ',')")}
    }
    return ,$f.ToArray()
}
$dlgFindings=Get-DlgFindings $dlgText
foreach($fn in $dlgFindings){Write-Host "FINDING: $fn"}
Check ($dlgText -ne '' -and $dlgFindings.Count -eq 0) 'the dialog host: constant markup without IsDefault or IsCancel, a wrapping footer, key plan Enter and Escape, a refusing close box, named buttons, DecorativeTextBlock icon, and a message box that returns DialogResult values'
function Edit-DlgPlant([string]$From,[string]$To){ if($dlgText.IndexOf($From,[StringComparison]::Ordinal) -lt 0){throw "FAIL: plant anchor missing: $From"}; return $dlgText.Replace($From,$To) }
$dlgPlants=[ordered]@{
    'a button with IsDefault (code)'=Edit-DlgPlant '        $button.MinWidth = 88' "        `$button.MinWidth = 88`n        `$button.IsDefault = `$true"
    'a button with IsCancel (code)'=Edit-DlgPlant '        $button.MinWidth = 88' "        `$button.MinWidth = 88`n        `$button.IsCancel = `$true"
    'IsDefault in the markup'=Edit-DlgPlant '<UniformGrid x:Name="DlgFooter"' '<UniformGrid IsDefault="True" x:Name="DlgFooter"'
    'an event attribute in the markup'=Edit-DlgPlant '<Border x:Name="DlgIconHost"' '<Border Loaded="x" x:Name="DlgIconHost"'
    'a footer caption AccessText that does not wrap'=Edit-DlgPlant '$captionText.TextWrapping = [System.Windows.TextWrapping]::Wrap' '$captionText.TextWrapping = [System.Windows.TextWrapping]::NoWrap'
    'a footer caption that is a plain string again'=Edit-DlgPlant '$button.Content = $captionText' '$button.Content = $caption'
    'the key hook moved off PreviewKeyDown'=Edit-DlgPlant '$win.Add_PreviewKeyDown({' '$win.Add_KeyDown({'
    'Enter overriding a focused button'=Edit-DlgPlant 'if ($focused -is [System.Windows.Controls.Button]) {' 'if ($false) {'
    'a focused footer button answering the Enter target'=Edit-DlgPlant '& $close $focusedId' "& `$close ([string] `$state['Enter'])"
    'a focused button left to its own Enter handling'=Edit-DlgPlant 'else { $focused.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)) }' 'else { }'
    'Escape answering the Enter target'=Edit-DlgPlant "if ([string] `$state['Escape'] -cne '') { & `$close ([string] `$state['Escape']) }" "if ([string] `$state['Escape'] -cne '') { & `$close ([string] `$state['Enter']) }"
    'a close box that never refuses'=Edit-DlgPlant '$e.Cancel = $true' '$e.Cancel = $false'
    'a close box that ignores CloseEnabled'=Edit-DlgPlant "if ([bool] `$state['CloseEnabled']) { `$state['Result']" "if (`$true) { `$state['Result']"
    'a button without its automation name'=Edit-DlgPlant '[System.Windows.Automation.AutomationProperties]::SetName($button, $caption)' '$null = $caption'
    'the first focus dropped'=Edit-DlgPlant '$null = $target.Focus(); ' ''
    'the first focus on the first button'=Edit-DlgPlant 'foreach ($candidate in @($Enter, $Escape)) {' 'foreach ($candidate in @()) {'
    'the Window.Tag dropped'=Edit-DlgPlant '$win.Tag = $result' '$null = $result'
    'a hidden owner set as owner'=Edit-DlgPlant 'if ($null -ne $ownerWindow -and [bool] $ownerWindow.IsVisible)' 'if ($null -ne $ownerWindow)'
    'an icon that is a plain TextBlock'=Edit-DlgPlant 'New-Object Bitworks.FastLlm.DecorativeTextBlock' 'New-Object System.Windows.Controls.TextBlock'
    'the box answering the string (D1 a)'=Edit-DlgPlant '[System.Enum]::Parse([System.Windows.Forms.DialogResult], [string] $name)' '[string] $name'
    'the box returning the raw id'=Edit-DlgPlant 'return (ConvertTo-FastLlmUiFluentDialogResult -Id $answer)' 'return $answer'
    'the key plan called without the default button'=Edit-DlgPlant '-Buttons $Buttons -DefaultButton $DefaultButton' '-Buttons $Buttons'
    'Enter taken from the Escape answer'=Edit-DlgPlant "-Enter ([string] `$plan['enter'])" "-Enter ([string] `$plan['escape'])"
    'the close box always enabled'=Edit-DlgPlant "-CloseEnabled ([bool] `$plan['closeEnabled'])" '-CloseEnabled $true'
    'the box owner dropped'=Edit-DlgPlant "-CloseEnabled ([bool] `$plan['closeEnabled']) -Owner `$Owner" "-CloseEnabled ([bool] `$plan['closeEnabled'])"
    'a caption string not read (BoxNo)'=Edit-DlgPlant '[string] $s.BoxNo' "'No'"
    'a result table that maps Yes to No'=Edit-DlgPlant "Yes = 'Yes'" "Yes = 'No'"
    'the Closing early return deleted (R8)'=Edit-DlgPlant "        if ([string] `$state['Result'] -cne '') { return }`n        if ([bool] `$state['CloseEnabled'])" "        if ([bool] `$state['CloseEnabled'])"
    'the owner resources merge deleted (R9)'=Edit-DlgPlant '        $win.Resources.MergedDictionaries.Add($ownerWindow.Resources)' '        $null = $ownerWindow'
    'the Asterisk icon row dropped (R4, R10)'=Edit-DlgPlant "    Asterisk    = @{ Glyph = 0xE946; Help = 'Information' }`n" ''
    'the Exclamation icon row dropped (R4, R10)'=Edit-DlgPlant "    Exclamation = @{ Glyph = 0xE7BA; Help = 'Warning' }`n" ''
    'the Hand icon row dropped (R4, R10)'=Edit-DlgPlant "    Hand        = @{ Glyph = 0xEA39; Help = '' }`n" ''
    'the Stop icon row dropped (R4, R10)'=Edit-DlgPlant "    Stop        = @{ Glyph = 0xEA39; Help = '' }`n" ''
    'the Asterisk icon row with another glyph (R4, R10)'=Edit-DlgPlant "    Asterisk    = @{ Glyph = 0xE946;" "    Asterisk    = @{ Glyph = 0xE947;"
    'the hidden owner never disabled (R5)'=Edit-DlgPlant '        $null = [Bitworks.FastLlm.FluentWindowNative]::SetWindowEnabled($hiddenOwner, $false)' '        $null = $hiddenOwner'
    'the hidden owner never enabled again (R5)'=Edit-DlgPlant '    finally { if ($disabled) { $null = [Bitworks.FastLlm.FluentWindowNative]::SetWindowEnabled($hiddenOwner, $true) } }' '    finally { }'
    'the hidden owner enabled after the try, not in a finally (R5)'=Edit-DlgPlant "    try { `$null = `$Dialog['Window'].ShowDialog() }`n    finally { if (`$disabled) { `$null = [Bitworks.FastLlm.FluentWindowNative]::SetWindowEnabled(`$hiddenOwner, `$true) } }" "    try { `$null = `$Dialog['Window'].ShowDialog() }`n    finally { }`n    if (`$disabled) { `$null = [Bitworks.FastLlm.FluentWindowNative]::SetWindowEnabled(`$hiddenOwner, `$true) }"
    'the hidden owner handle taken for a shown owner too (R5)'=Edit-DlgPlant 'if ($null -ne $ownerWindow -and -not [bool] $ownerWindow.IsVisible) {' 'if ($null -ne $ownerWindow) {'
    'the hidden owner handle not carried (R5)'=Edit-DlgPlant '; HiddenOwner = $hiddenOwner }' ' }'
    'Escape answering with an open drop-down item (R6)'=Edit-DlgPlant '            if ($focused -is [System.Windows.Controls.ComboBoxItem]) { return }' '            $null = $focused'
    'Escape answering with an open ComboBox (R6)'=Edit-DlgPlant '            if ($focused -is [System.Windows.Controls.ComboBox] -and [bool] $focused.IsDropDownOpen) { return }' '            $null = $focused'
}
foreach($k in $dlgPlants.Keys){ Check ($dlgPlants[$k] -cne $dlgText -and (Get-DlgFindings $dlgPlants[$k]).Count -ge 1) "mutation check: the dialog host pin flags: $k" }

# The four box captions are in the string table (D3), equal to what Windows shows in English; the box reads them from the table.
foreach($pair in @(@('BoxOK','OK'),@('BoxCancel','Cancel'),@('BoxYes','Yes'),@('BoxNo','No'))){
    Check ([regex]::IsMatch($dlgHome,"(?m)^\s+$($pair[0])\s*=\s*'$($pair[1])'\s*$")) "the string table has $($pair[0]) = '$($pair[1])'"
}

# The DialogResult mapping table, run for real: every id of every box kind maps to a System.Windows.Forms.DialogResult member name of the same spelling.
. (Join-Path $root 'src/FastLlm.UiState.ps1')
. (Join-Path $root 'src/FastLlm.UiXaml.ps1')
. (Join-Path $root 'src/FastLlm.UiFluentDialogs.ps1')
$dlgEnum=@('None','OK','Cancel','Abort','Retry','Ignore','Yes','No')
$dlgIds=@(); foreach($k in 'OK','OKCancel','YesNo'){ foreach($d in 'Button1','Button2'){ $dlgIds+=@((Get-FastLlmUiDialogKeyPlan -Buttons $k -DefaultButton $d)['order']) } }
Check (@($dlgIds|Select-Object -Unique).Count -eq 4) 'the three box kinds use exactly the four ids OK, Cancel, Yes and No'
foreach($id in ($dlgIds|Select-Object -Unique)){
    $name=$script:FastLlmUiFluentDialogResultNames[$id]
    Check ($name -is [string] -and $name -ceq $id -and $dlgEnum -ccontains $name) "answer id $id maps to the DialogResult member of the same name"
}
Check ($script:FastLlmUiFluentDialogResultNames.Count -eq 4) 'the result table has exactly four rows'
Check ($script:FastLlmUiXaml.ContainsKey('FastLlm.Dialog') -and [string]$script:FastLlmUiXaml['FastLlm.Dialog'] -ceq (Get-DlgXaml $dlgText)) 'the registered dialog markup is the constant here-string of the file'
# ===== end PR 4a: the dialog host and the fluent message box (Tasks 2 and 3) =====


# ===== PR 4a Task 4: the classic seam (D1 = A: explicit named entries) =====
# Every message box the reachable classic orchestration opens goes through ShowUiMessageBox, which hands it to $script:uiDialogView['MessageBox'] when the Fluent
# shell has set that table (and is exactly MessageBox.Show's six-argument owner overload otherwise); the two custom dialogs dispatch on their own first line.
$seamUiText=Get-NormalizedText $path
$seamShellText=Get-NormalizedText (Join-Path $root 'src/FastLlm.UiFluentShell.ps1')
function Edit-SeamPlant([string]$Text,[string]$From,[string]$To){ if($Text.IndexOf($From,[StringComparison]::Ordinal) -lt 0){throw "FAIL: seam plant anchor missing: $From"}; return $Text.Replace($From,$To) }
# 5b-delete-begin
$seamDispatchLine='if($null -ne $script:uiDialogView){return & $script:uiDialogView[''MessageBox''] -Owner $Owner -Text $Text -Caption $Caption -Buttons $Buttons -Icon $Icon -DefaultButton $DefaultButton}'
$seamPassLine='return [Windows.Forms.MessageBox]::Show($Owner,$Text,$Caption,$Buttons,$Icon,$DefaultButton)'
# 5b-delete-end
$seamParams='$Owner,[string]$Text,[string]$Caption,[string]$Buttons=''OK'',[string]$Icon=''None'',[string]$DefaultButton=''Button1'''
# Ruling c: every direct MessageBox.Show left in the window script, by enclosing function and count. A new direct call anywhere fails the suite.
#  ShowUiMessageBox: the passthrough itself. ShowFailure and EnsureTrayIcon: the window cannot be restored (native by design, 6.6).
#  BuildUiSettingsDialog and ShowUiSettings: the classic Settings dialog, unreachable in the Fluent window (its page replaces it); deleted at the flip.
# 5b-delete-begin
$seamNativeShows=@{ShowUiMessageBox=1;ShowFailure=1;EnsureTrayIcon=2;BuildUiSettingsDialog=3;ShowUiSettings=1}
# 5b-delete-end
$seamViewKeys=@{MessageBox='Show-FastLlmUiFluentMessageBox';ShowUiSideResult='Show-FastLlmUiFluentSideResult';ShowDriverGuidance='Show-FastLlmUiFluentDriverGuidance';ShowLicenseSettingConfirm='Show-FastLlmUiFluentLicenseSettingConfirm';ShowComponentConsent='Show-FastLlmUiFluentComponentConsent';ShowExactModelConsent='Show-FastLlmUiFluentExactModelConsent';ShowVcInstallReview='Show-FastLlmUiFluentVcInstallReview';ShowSetupAttention='Show-FastLlmUiFluentSetupAttention';ShowRecipeChooser='Show-FastLlmUiFluentRecipeChooser'}
# 5b-delete-begin
# 4b B1: the six consent and dialog functions dispatch on their first statement and RETURN the fluent result, passing every parameter by name.
$seamDispatch46=[ordered]@{ShowLicenseSettingConfirm='-Disclosure $Disclosure';ShowComponentConsent='-Row $Row -ConsentRows $ConsentRows -Chosen $Chosen';ShowExactModelConsent='-Plan $Plan';ShowVcInstallReview='-Receipt $Receipt -Candidate $Candidate';ShowSetupAttention='-Decision $Decision -Diagnostic $Diagnostic';ShowRecipeChooser='-Rows $Rows'}
function Get-SeamFindings([string]$UiText,[string]$ShellText){
    $f=New-Object System.Collections.ArrayList
    $e=$null
    $ui=[System.Management.Automation.Language.Parser]::ParseInput($UiText,[ref]$null,[ref]$e)
    $sh=[System.Management.Automation.Language.Parser]::ParseInput($ShellText,[ref]$null,[ref]$e)
    $isFn={param($n,$name) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name}
    # 1. The classic body: the dispatch line, then the six-argument owner overload, nothing else.
    $box=@($ui.FindAll({param($n) & $isFn $n 'ShowUiMessageBox'},$true))
    if($box.Count -ne 1){[void]$f.Add('ShowUiMessageBox is not defined exactly once')}
    else{
        $ps=@($box[0].Parameters|ForEach-Object{[string]$_.Extent.Text}) -join ','
        if($ps -cne $seamParams){[void]$f.Add("ShowUiMessageBox parameters changed: $ps")}
        $st=@($box[0].Body.EndBlock.Statements)
        if($st.Count -ne 2 -or $st[0].Extent.Text -cne $seamDispatchLine -or $st[1].Extent.Text -cne $seamPassLine){[void]$f.Add('ShowUiMessageBox is not exactly the dispatch line plus the six-argument MessageBox.Show passthrough')}
    }
    # 2. The direct MessageBox.Show census (ruling c).
    $counts=@{}
    foreach($n in @($ui.FindAll({param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Static -and $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and [string]$n.Member.Value -ceq 'Show' -and $n.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and [string]$n.Expression.TypeName.Name -cmatch '^(System\.)?Windows\.Forms\.MessageBox$'},$true))){
        $p=$n.Parent; while($null -ne $p -and $p -isnot [System.Management.Automation.Language.FunctionDefinitionAst]){$p=$p.Parent}
        $name=if($null -ne $p){[string]$p.Name}else{'(script level)'}
        if(-not $counts.ContainsKey($name)){$counts[$name]=0}; $counts[$name]++
    }
    foreach($k in @($counts.Keys)){ if(-not $seamNativeShows.ContainsKey($k)){[void]$f.Add("a direct MessageBox.Show in $k is not on the native list (use ShowUiMessageBox)")} elseif($counts[$k] -ne $seamNativeShows[$k]){[void]$f.Add("MessageBox.Show count in ${k}: $($counts[$k]), expected $($seamNativeShows[$k])")} }
    foreach($k in @($seamNativeShows.Keys)){ if(-not $counts.ContainsKey($k)){[void]$f.Add("the native MessageBox.Show list names $k, which has none left")} }
    # 3. Every view key the classic script reads exists in the shell's table, bound to the named Fluent function.
    $used=@{}
    foreach($n in @($ui.FindAll({param($n) $n -is [System.Management.Automation.Language.IndexExpressionAst] -and $n.Target -is [System.Management.Automation.Language.VariableExpressionAst] -and [string]$n.Target.VariablePath.UserPath -ceq 'script:uiDialogView'},$true))){
        $k=if($n.Index -is [System.Management.Automation.Language.StringConstantExpressionAst]){[string]$n.Index.Value}else{'(not a literal)'}
        $used[$k]=$true
    }
    if($used.Count -ne 9){[void]$f.Add("the classic script reads $($used.Count) distinct view keys, expected 9")}
    $init=@($ui.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$script:uiDialogView' -and $n.Right.Extent.Text -ceq '$null'},$true))
    if($init.Count -ne 1){[void]$f.Add('the classic script does not set $script:uiDialogView=$null exactly once')}
    foreach($k in @($used.Keys)){ if(-not $seamViewKeys.ContainsKey($k)){[void]$f.Add("the classic script reads view key '$k', which is not a known entry")} }
    $setv=@($sh.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -ceq 'Set-Variable' -and $n.Extent.Text -cmatch '-Name uiDialogView\b'},$true))
    if($setv.Count -ne 1){[void]$f.Add('Initialize-FastLlmUiFluentShell does not set uiDialogView exactly once')}
    else{
        $inFn=$setv[0].Parent; while($null -ne $inFn -and $inFn -isnot [System.Management.Automation.Language.FunctionDefinitionAst]){$inFn=$inFn.Parent}
        if($null -eq $inFn -or $inFn.Name -cne 'Initialize-FastLlmUiFluentShell'){[void]$f.Add('uiDialogView is not set inside Initialize-FastLlmUiFluentShell')}
        if($setv[0].Extent.Text -cnotmatch '-Scope Script\b'){[void]$f.Add('uiDialogView is not set in the Script scope')}
        $hash=$setv[0].Find({param($n) $n -is [System.Management.Automation.Language.HashtableAst]},$true)
        if($null -eq $hash){[void]$f.Add('the uiDialogView value is not a hashtable literal')}
        else{
            $tbl=@{}; foreach($kv in $hash.KeyValuePairs){$tbl[[string]$kv.Item1.Extent.Text]=[string]$kv.Item2.Extent.Text}
            foreach($k in @($used.Keys)){ if(-not $tbl.ContainsKey($k)){[void]$f.Add("view key '$k' is read by the classic script but is not in the shell's table")} }
            foreach($k in @($seamViewKeys.Keys)){ if(-not $tbl.ContainsKey($k) -or $tbl[$k] -cne ('${function:'+$seamViewKeys[$k]+'}')){[void]$f.Add("the shell's table entry $k is not `${function:$($seamViewKeys[$k])}")} }
            if($tbl.Count -ne $seamViewKeys.Count){[void]$f.Add("the shell's table has $($tbl.Count) entries, expected $($seamViewKeys.Count)")}
        }
    }
    # 4. The two custom dialogs dispatch on their first statement, passing their parameters by name.
    foreach($d in @(@('ShowUiSideResult','if($null -ne $script:uiDialogView){& $script:uiDialogView[''ShowUiSideResult''] -Title $Title -Text $Text;return}'),@('ShowDriverGuidance','if($null -ne $script:uiDialogView){& $script:uiDialogView[''ShowDriverGuidance''] -Diagnostic $Diagnostic;return}'))){
        $dn=$d[0]; $fn=@($ui.FindAll({param($n) & $isFn $n $dn},$true))
        if($fn.Count -ne 1 -or @($fn[0].Body.EndBlock.Statements).Count -lt 2 -or @($fn[0].Body.EndBlock.Statements)[0].Extent.Text -cne $d[1]){[void]$f.Add("$dn does not start with its dispatch line")}
    }
    # 5. 4b B1: the six dialog functions: first statement is the dispatch line (returns the fluent result, every parameter named), then the classic body follows.
    foreach($dn in @($seamDispatch46.Keys)){
        $want='if($null -ne $script:uiDialogView){return & $script:uiDialogView['''+$dn+'''] '+$seamDispatch46[$dn]+'}'
        $fn=@($ui.FindAll({param($n) & $isFn $n $dn},$true))
        if($fn.Count -ne 1 -or @($fn[0].Body.EndBlock.Statements).Count -lt 2 -or @($fn[0].Body.EndBlock.Statements)[0].Extent.Text -cne $want){[void]$f.Add("$dn does not start with its dispatch line (return, every parameter by name)")}
    }
    return ,$f.ToArray()
}
$seamFindings=Get-SeamFindings $seamUiText $seamShellText
foreach($x in $seamFindings){Write-Host "FINDING: $x"}
Check ($seamFindings.Count -eq 0) 'the classic seam: ShowUiMessageBox body, the native MessageBox.Show list by function and count, and every view key present in the shell table'
$seamPlants=[ordered]@{
    'the passthrough drops DefaultButton (5-argument overload)'=@((Edit-SeamPlant $seamUiText ',$Icon,$DefaultButton)' ',$Icon)'),$seamShellText)
    'the passthrough drops Icon and DefaultButton (4 arguments)'=@((Edit-SeamPlant $seamUiText ',$Buttons,$Icon,$DefaultButton)' ',$Buttons)'),$seamShellText)
    'the passthrough loses the owner (owner-less overload)'=@((Edit-SeamPlant $seamUiText 'Show($Owner,$Text,$Caption,$Buttons,$Icon,$DefaultButton)' 'Show($Text,$Caption,$Buttons,$Icon,$DefaultButton)'),$seamShellText)
    'the dispatch line forgets to pass DefaultButton'=@((Edit-SeamPlant $seamUiText ' -Icon $Icon -DefaultButton $DefaultButton}' ' -Icon $Icon}'),$seamShellText)
    'a DefaultButton default changed'=@((Edit-SeamPlant $seamUiText "[string]`$DefaultButton='Button1'){" "[string]`$DefaultButton='Button2'){"),$seamShellText)
    'a new direct MessageBox.Show in InvokeUiUpdate'=@((Edit-SeamPlant $seamUiText 'function InvokeUiUpdate {' "function InvokeUiUpdate {`n    [void][Windows.Forms.MessageBox]::Show(`$form,'x','y')"),$seamShellText)
    'a new direct MessageBox.Show at script level'=@(($seamUiText+"`n[void][System.Windows.Forms.MessageBox]::Show('x')`n"),$seamShellText)
    'a native ShowFailure Show removed'=@((Edit-SeamPlant $seamUiText "[void][Windows.Forms.MessageBox]::Show('FastLLM needs attention," "[void][Console]::WriteLine('FastLLM needs attention,"),$seamShellText)
    'a view key misspelled in the classic script'=@((Edit-SeamPlant $seamUiText "uiDialogView['MessageBox']" "uiDialogView['MessageBoks']"),$seamShellText)
    'a view key misspelled in the shell table'=@($seamUiText,(Edit-SeamPlant $seamShellText 'ShowDriverGuidance = ${function:' 'ShowDriverGuidence = ${function:'))
    'a shell entry bound to the wrong function'=@($seamUiText,(Edit-SeamPlant $seamShellText 'MessageBox = ${function:Show-FastLlmUiFluentMessageBox}' 'MessageBox = ${function:Show-FastLlmUiFluentSideResult}'))
    'the side result dispatch missing'=@((Edit-SeamPlant $seamUiText "    if(`$null -ne `$script:uiDialogView){& `$script:uiDialogView['ShowUiSideResult'] -Title `$Title -Text `$Text;return}`n" ''),$seamShellText)
    'the licence setting dispatch drops return'=@((Edit-SeamPlant $seamUiText "{return & `$script:uiDialogView['ShowLicenseSettingConfirm']" "{& `$script:uiDialogView['ShowLicenseSettingConfirm']"),$seamShellText)
    'the component consent dispatch drops -Chosen'=@((Edit-SeamPlant $seamUiText ' -ConsentRows $ConsentRows -Chosen $Chosen}' ' -ConsentRows $ConsentRows}'),$seamShellText)
    'the recipe chooser dispatch key misspelled'=@((Edit-SeamPlant $seamUiText "uiDialogView['ShowRecipeChooser']" "uiDialogView['ShowRecipeChoser']"),$seamShellText)
    'the setup attention shell entry misspelled'=@($seamUiText,(Edit-SeamPlant $seamShellText 'ShowSetupAttention = ${function:' 'ShowSetupAttenton = ${function:'))
    'the VC review dispatch drops return'=@((Edit-SeamPlant $seamUiText "{return & `$script:uiDialogView['ShowVcInstallReview']" "{& `$script:uiDialogView['ShowVcInstallReview']"),$seamShellText)
    'the exact model consent dispatch is missing'=@((Edit-SeamPlant $seamUiText "    if(`$null -ne `$script:uiDialogView){return & `$script:uiDialogView['ShowExactModelConsent'] -Plan `$Plan}`n" ''),$seamShellText)
    'the table set in the Local scope'=@($seamUiText,(Edit-SeamPlant $seamShellText '-Name uiDialogView -Scope Script' '-Name uiDialogView -Scope Local'))
}
# CONTROL: the unmutated texts give exactly 0 findings (a counter that is always 1 or always 0 fails here or below). Each plant must also differ from the real text.
Check ((Get-SeamFindings $seamUiText $seamShellText).Count -eq 0) 'control: the unmutated classic and shell texts give no classic-seam findings'
foreach($k in $seamPlants.Keys){ Check (($seamPlants[$k][0] -cne $seamUiText) -or ($seamPlants[$k][1] -cne $seamShellText)) "the seam plant changes the text: $k" }
foreach($k in $seamPlants.Keys){ Check ((Get-SeamFindings $seamPlants[$k][0] $seamPlants[$k][1]).Count -ge 1) "mutation check: the classic seam pin flags: $k" }
# 5b-delete-end
# The dispatch table, frozen: each of the nine dispatch functions of the window script has one call of its view entry, `& $script:uiDialogView['<Key>'] <arguments>`, in
# its first statement (the whole statement or, while the classic body follows, the guard around it), with every parameter passed by name; the box and the six consent and
# dialog functions return its result, the side result and the driver guidance do not. The literal is checked against the classic dispatch lines below (deleted at the flip).
$dispatchFrozen=[ordered]@{
    ShowUiMessageBox=@{Key='MessageBox';Args='-Owner $Owner -Text $Text -Caption $Caption -Buttons $Buttons -Icon $Icon -DefaultButton $DefaultButton';Return=$true}
    ShowUiSideResult=@{Key='ShowUiSideResult';Args='-Title $Title -Text $Text';Return=$false}
    ShowDriverGuidance=@{Key='ShowDriverGuidance';Args='-Diagnostic $Diagnostic';Return=$false}
    ShowLicenseSettingConfirm=@{Key='ShowLicenseSettingConfirm';Args='-Disclosure $Disclosure';Return=$true}
    ShowComponentConsent=@{Key='ShowComponentConsent';Args='-Row $Row -ConsentRows $ConsentRows -Chosen $Chosen';Return=$true}
    ShowExactModelConsent=@{Key='ShowExactModelConsent';Args='-Plan $Plan';Return=$true}
    ShowVcInstallReview=@{Key='ShowVcInstallReview';Args='-Receipt $Receipt -Candidate $Candidate';Return=$true}
    ShowSetupAttention=@{Key='ShowSetupAttention';Args='-Decision $Decision -Diagnostic $Diagnostic';Return=$true}
    ShowRecipeChooser=@{Key='ShowRecipeChooser';Args='-Rows $Rows';Return=$true}
}
function Get-DispatchFindings([string]$UiText,[string]$ShellText){
    $f=New-Object System.Collections.ArrayList
    $e=$null
    $ui=[System.Management.Automation.Language.Parser]::ParseInput($UiText,[ref]$null,[ref]$e)
    $sh=[System.Management.Automation.Language.Parser]::ParseInput($ShellText,[ref]$null,[ref]$e)
    foreach($dn in @($dispatchFrozen.Keys)){
        $want=$dispatchFrozen[$dn]
        $fn=@($ui.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $dn},$true))
        if($fn.Count -ne 1){[void]$f.Add("$dn is not defined exactly once");continue}
        if($dn -ceq 'ShowUiMessageBox'){
            $ps=@($fn[0].Parameters|ForEach-Object{[string]$_.Extent.Text}) -join ','
            if($ps -cne $seamParams){[void]$f.Add("ShowUiMessageBox parameters changed: $ps")}
        }
        $calls=@($fn[0].Body.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand -and $n.CommandElements[0] -is [System.Management.Automation.Language.IndexExpressionAst] -and $n.CommandElements[0].Target.Extent.Text -ceq '$script:uiDialogView'},$true))
        if($calls.Count -ne 1){[void]$f.Add("$dn calls the dialog view table $($calls.Count) times, expected once");continue}
        $c=$calls[0]
        $idx=$c.CommandElements[0].Index
        if($idx -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -or [string]$idx.Value -cne [string]$want.Key){[void]$f.Add("$dn dispatches to view entry '$($idx.Extent.Text)', expected '$($want.Key)'")}
        $argText=@($c.CommandElements|Select-Object -Skip 1|ForEach-Object{$_.Extent.Text}) -join ' '
        if($argText -cne [string]$want.Args){[void]$f.Add("$dn passes ($argText), expected ($($want.Args)) (every parameter by name)")}
        $first=@($fn[0].Body.EndBlock.Statements)[0]
        if($null -eq $first -or $c.Extent.StartOffset -lt $first.Extent.StartOffset -or $c.Extent.EndOffset -gt $first.Extent.EndOffset){[void]$f.Add("$dn does not dispatch in its first statement")}
        $inReturn=$false; $q=$c.Parent
        while($null -ne $q -and -not [object]::ReferenceEquals($q,$fn[0])){ if($q -is [System.Management.Automation.Language.ReturnStatementAst]){$inReturn=$true}; $q=$q.Parent }
        if($inReturn -ne [bool]$want.Return){[void]$f.Add("$dn $(if($want.Return){'does not return'}else{'returns'}) the dispatch result")}
    }
    # Every view key the window script reads exists in the shell's table, bound to the named Fluent function.
    $used=@{}
    foreach($n in @($ui.FindAll({param($n) $n -is [System.Management.Automation.Language.IndexExpressionAst] -and $n.Target -is [System.Management.Automation.Language.VariableExpressionAst] -and [string]$n.Target.VariablePath.UserPath -ceq 'script:uiDialogView'},$true))){
        $k=if($n.Index -is [System.Management.Automation.Language.StringConstantExpressionAst]){[string]$n.Index.Value}else{'(not a literal)'}
        $used[$k]=$true
    }
    if($used.Count -ne 9){[void]$f.Add("the window script reads $($used.Count) distinct view keys, expected 9")}
    $init=@($ui.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$script:uiDialogView' -and $n.Right.Extent.Text -ceq '$null'},$true))
    if($init.Count -ne 1){[void]$f.Add('the window script does not set $script:uiDialogView=$null exactly once')}
    foreach($k in @($used.Keys)){ if(-not $seamViewKeys.ContainsKey($k)){[void]$f.Add("the window script reads view key '$k', which is not a known entry")} }
    $setv=@($sh.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -ceq 'Set-Variable' -and $n.Extent.Text -cmatch '-Name uiDialogView\b'},$true))
    if($setv.Count -ne 1){[void]$f.Add('Initialize-FastLlmUiFluentShell does not set uiDialogView exactly once')}
    else{
        $inFn=$setv[0].Parent; while($null -ne $inFn -and $inFn -isnot [System.Management.Automation.Language.FunctionDefinitionAst]){$inFn=$inFn.Parent}
        if($null -eq $inFn -or $inFn.Name -cne 'Initialize-FastLlmUiFluentShell'){[void]$f.Add('uiDialogView is not set inside Initialize-FastLlmUiFluentShell')}
        if($setv[0].Extent.Text -cnotmatch '-Scope Script\b'){[void]$f.Add('uiDialogView is not set in the Script scope')}
        $hash=$setv[0].Find({param($n) $n -is [System.Management.Automation.Language.HashtableAst]},$true)
        if($null -eq $hash){[void]$f.Add('the uiDialogView value is not a hashtable literal')}
        else{
            $tbl=@{}; foreach($kv in $hash.KeyValuePairs){$tbl[[string]$kv.Item1.Extent.Text]=[string]$kv.Item2.Extent.Text}
            foreach($k in @($used.Keys)){ if(-not $tbl.ContainsKey($k)){[void]$f.Add("view key '$k' is read by the window script but is not in the shell's table")} }
            foreach($k in @($seamViewKeys.Keys)){ if(-not $tbl.ContainsKey($k) -or $tbl[$k] -cne ('${function:'+$seamViewKeys[$k]+'}')){[void]$f.Add("the shell's table entry $k is not `${function:$($seamViewKeys[$k])}")} }
            if($tbl.Count -ne $seamViewKeys.Count){[void]$f.Add("the shell's table has $($tbl.Count) entries, expected $($seamViewKeys.Count)")}
        }
    }
    return ,$f.ToArray()
}
function Remove-SeamLine([string]$Text,[string]$Needle){
    $lines=@($Text.Split("`n")|Where-Object{-not $_.Contains($Needle)})
    return ($lines -join "`n")
}
$dispFindings=Get-DispatchFindings $seamUiText $seamShellText
foreach($x in $dispFindings){Write-Host "FINDING: $x"}
Check ($dispFindings.Count -eq 0) 'the dispatch table: each of the nine dispatch functions passes every parameter to its own view entry in its first statement, and every view key is present in the shell table'
$dispPlants=[ordered]@{
    'a DefaultButton default changed'=@((Edit-SeamPlant $seamUiText "[string]`$DefaultButton='Button1'){" "[string]`$DefaultButton='Button2'){"),$seamShellText)
    'the dispatch line forgets to pass DefaultButton'=@((Edit-SeamPlant $seamUiText ' -Icon $Icon -DefaultButton $DefaultButton' ' -Icon $Icon'),$seamShellText)
    'a view key misspelled in the window script'=@((Edit-SeamPlant $seamUiText "uiDialogView['MessageBox']" "uiDialogView['MessageBoks']"),$seamShellText)
    'a view key misspelled in the shell table'=@($seamUiText,(Edit-SeamPlant $seamShellText 'ShowDriverGuidance = ${function:' 'ShowDriverGuidence = ${function:'))
    'a shell entry bound to the wrong function'=@($seamUiText,(Edit-SeamPlant $seamShellText 'MessageBox = ${function:Show-FastLlmUiFluentMessageBox}' 'MessageBox = ${function:Show-FastLlmUiFluentSideResult}'))
    'the side result dispatch missing'=@((Remove-SeamLine $seamUiText "uiDialogView['ShowUiSideResult']"),$seamShellText)
    'the licence setting dispatch drops return'=@((Edit-SeamPlant $seamUiText "return & `$script:uiDialogView['ShowLicenseSettingConfirm']" "& `$script:uiDialogView['ShowLicenseSettingConfirm']"),$seamShellText)
    'the component consent dispatch drops -Chosen'=@((Edit-SeamPlant $seamUiText ' -ConsentRows $ConsentRows -Chosen $Chosen' ' -ConsentRows $ConsentRows'),$seamShellText)
    'the recipe chooser dispatch key misspelled'=@((Edit-SeamPlant $seamUiText "uiDialogView['ShowRecipeChooser']" "uiDialogView['ShowRecipeChoser']"),$seamShellText)
    'the setup attention shell entry misspelled'=@($seamUiText,(Edit-SeamPlant $seamShellText 'ShowSetupAttention = ${function:' 'ShowSetupAttenton = ${function:'))
    'the VC review dispatch drops return'=@((Edit-SeamPlant $seamUiText "return & `$script:uiDialogView['ShowVcInstallReview']" "& `$script:uiDialogView['ShowVcInstallReview']"),$seamShellText)
    'the exact model consent dispatch is missing'=@((Remove-SeamLine $seamUiText "uiDialogView['ShowExactModelConsent']"),$seamShellText)
    'the table set in the Local scope'=@($seamUiText,(Edit-SeamPlant $seamShellText '-Name uiDialogView -Scope Script' '-Name uiDialogView -Scope Local'))
}
Check ((Get-DispatchFindings $seamUiText $seamShellText).Count -eq 0) 'control: the unmutated window script and shell texts give no dispatch findings'
foreach($k in $dispPlants.Keys){ Check (($dispPlants[$k][0] -cne $seamUiText) -or ($dispPlants[$k][1] -cne $seamShellText)) "the dispatch plant changes the text: $k" }
foreach($k in $dispPlants.Keys){ Check ((Get-DispatchFindings $dispPlants[$k][0] $dispPlants[$k][1]).Count -ge 1) "mutation check: the dispatch pin flags: $k" }
# 5b-delete-begin
# The frozen dispatch table against the classic dispatch lines, unconditional: each function is found once and its first statement is the guarded dispatch line built from the literal.
foreach($dn in @($dispatchFrozen.Keys)){
    $want=$dispatchFrozen[$dn]
    $classicFn=@($tree.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $dn},$true))
    $classicFirst=''; if($classicFn.Count -eq 1){ $classicFirst=[string]@($classicFn[0].Body.EndBlock.Statements)[0].Extent.Text }
    $wantLine='if($null -ne $script:uiDialogView){'+$(if($want.Return){'return '}else{''})+'& $script:uiDialogView['''+$want.Key+'''] '+$want.Args+$(if($want.Return){''}else{';return'})+'}'
    Check ($classicFn.Count -eq 1 -and $classicFirst -ceq $wantLine) "the frozen dispatch literal of $dn equals the first statement of the classic function"
}
# 5b-delete-end
# ===== end PR 4a Task 4 =====

# ===== PR 4a Task 5: side result and driver guidance (builder D) =====
# The text table is copied from the two classic functions (drift pin), the key targets are the classic ones (side result: Close answers Enter and Escape;
# driver guidance: Escape only, no Enter target), and each runs again on a planted mutant.
$sdText=Get-OptionalText 'src/FastLlm.UiFluentDialogs.ps1'
$sdTextAssign=@((ConvertTo-PinAst $sdText).FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$script:FastLlmUiFluentDialogText'},$true))
Check ($sdTextAssign.Count -eq 1) 'the dialog text table is assigned exactly once'
$sdTable=& ([scriptblock]::Create($sdTextAssign[0].Right.Extent.Text))
Check ((@($sdTable.Keys)[0..12] -join ',') -ceq 'SideClose,GuidanceTitle,GuidanceLabel,OpenPage,GuidanceClose,NoReport,NoEntries,NoEntriesStatus,TooMany,Invalid,OpenFailed,Viewed,Url') 'the dialog text table starts with the 13 planned 4a keys, in order (the 4b keys follow, pinned in their own block)'
$sd4aTable=[ordered]@{}; foreach($key in @($sdTable.Keys)[0..12]){$sd4aTable[$key]=[string]$sdTable[$key]}
# The frozen dialog text table: the 38 values as literals (the 13 side result and driver guidance texts, then the 25 setup check and chooser texts; a WinForms && is one & here).
# Every value is a string of the classic functions (the unconditional checks below, deleted with them at the flip); the check here reads only the fluent source.
$dlgFrozen=[ordered]@{
    SideClose='Close'
    GuidanceTitle='AMD driver guidance - read-only'
    GuidanceLabel='Choose a detected display device (not a verified serving-GPU match)'
    OpenPage='Open official AMD page'
    GuidanceClose='Close'
    NoReport='No Windows driver guidance report was returned.'
    NoEntries='No readable display-device guidance is available. Use Diagnostics for the inventory error and AMD Windows drivers to select your product manually.'
    NoEntriesStatus='Driver guidance unavailable. No driver changes made.'
    TooMany='Driver guidance exceeds the display-device limit.'
    Invalid='The advisory could not be validated. Use the main AMD Windows drivers link.'
    OpenFailed='Unable to open the official AMD page. No driver changes were made.'
    Viewed='Driver guidance viewed. No driver changes made.'
    Url='https://www.amd.com/en/support/download/drivers.html'
    SetupTitle='FastLLM setup check'
    SetupIntro='This PC is missing a required component for the current Vulkan lane. Review the latest setup check before continuing.'
    SetupNeed64='Use 64-bit Windows PowerShell or PowerShell 7.'
    SetupVcMissing='Install the current Microsoft Visual C++ 2015-2022 Redistributable (x64). Missing: {0}.'
    SetupNoLoader='Install an AMD Windows driver with Vulkan support. The System32 Vulkan loader is not present.'
    SetupAfter='After prerequisite setup and any required reboot, choose Recheck. This reruns read-only diagnostics. Compatibility and GPU performance remain unqualified.'
    SetupMsLink='Official Microsoft VC++ download information'
    SetupAmdLink='Official AMD driver downloads'
    SetupMsUrl='https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist'
    SetupAmdUrl='https://www.amd.com/en/support/download/drivers.html'
    SetupMsFailed='Unable to open the official Microsoft page. No software was installed.'
    SetupAmdFailed='Unable to open the official AMD page. No driver changes were made.'
    SetupRecheck='Recheck'
    SetupPrepare='Prepare & review VC++'
    SetupLater='Do later'
    ChooserTitle='Choose another setup'
    ChooserIntro='Setups for your card. Pick one, then Choose. Experimental setups are shown only while Experimental community components is on. Nothing is downloaded until you confirm.'
    ChooserNotice=' {0}'
    ChooserSetup='Setup'
    ChooserModel='Model'
    ChooserContext='Context'
    ChooserEngine='Engine and sources'
    ChooserChoose='Choose'
    ChooserCancel='Cancel'
    ChooserCellName='{0}: {1}'
}
Check ($dlgFrozen.Count -eq 38 -and ((@($dlgFrozen.Keys) -join ',') -ceq (@($sdTable.Keys) -join ','))) 'the frozen dialog text table holds the 38 keys of the dialog text table, in order'
Check ((Get-FrozenTableProblems $sdTable $dlgFrozen).Count -eq 0) 'the dialog text table (side result, driver guidance, setup check, chooser) equals its frozen literal (38 keys, every value)'
$dtMutValue=Copy-Table $sdTable; $dtMutValue['NoEntriesStatus']=[string]$sdTable['NoEntriesStatus']+'.'
$dtMutAmp=Copy-Table $sdTable; $dtMutAmp['SetupPrepare']='Prepare && review VC++'
$dtMutKey=Copy-Table $sdTable; $dtMutKey['Extra']='A new caption'
$dtMutDrop=Copy-Table $sdTable; $dtMutDrop.Remove('ChooserCancel')
Check ((Get-FrozenTableProblems $dtMutValue $dlgFrozen).Count -ge 1) 'mutation check: a changed side result or driver guidance text fails the frozen dialog literal'
Check ((Get-FrozenTableProblems $dtMutAmp $dlgFrozen).Count -ge 1) 'mutation check: the classic && copied as && (not the displayed &) fails the frozen dialog literal'
Check ((Get-FrozenTableProblems $dtMutKey $dlgFrozen).Count -ge 1) 'mutation check: a new dialog text key fails the frozen dialog literal'
Check ((Get-FrozenTableProblems $dtMutDrop $dlgFrozen).Count -ge 1) 'mutation check: a dropped dialog text key fails the frozen dialog literal'
Check ((Get-FrozenTableProblems (Copy-Table $sdTable) $dlgFrozen).Count -eq 0) 'control: an unchanged copy of the dialog text table passes the frozen literal'
# 5b-delete-begin
function Get-SideDriftLiterals($Ast){
    $vals=New-Object System.Collections.ArrayList
    foreach($fnName in 'ShowUiSideResult','ShowDriverGuidance'){
        foreach($fnAst in (Get-AstFunction $Ast $fnName)){
            foreach($k in @($fnAst.FindAll({param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst]},$true))){ [void]$vals.Add([string]$k.Value) }
        }
    }
    return ,$vals.ToArray()
}
function Get-SideDriftProblems($Table,[string[]]$Values){
    $problems=New-Object System.Collections.ArrayList
    foreach($key in @($Table.Keys)){if($Values -cnotcontains [string]$Table[$key]){[void]$problems.Add("table value $key is not a string constant of ShowUiSideResult or ShowDriverGuidance")}}
    return ,$problems.ToArray()
}
$sdClassic=Get-SideDriftLiterals $classicAst
$sdDrift=Get-SideDriftProblems $sd4aTable $sdClassic
foreach($pr in $sdDrift){Write-Host "FINDING: $pr"}
Check ($sdDrift.Count -eq 0 -and $sdClassic.Count -gt 20) "every dialog text value is a classic literal of ShowUiSideResult or ShowDriverGuidance ($($sdClassic.Count) literals read)"
foreach($sdKey in @($sd4aTable.Keys)){
    $mut=[ordered]@{}; foreach($key in @($sd4aTable.Keys)){$mut[$key]=[string]$sd4aTable[$key]}
    $mut[$sdKey]=[string]$sd4aTable[$sdKey]+'.'
    Check ((Get-SideDriftProblems $mut $sdClassic).Count -ge 1) "mutation check: a changed $sdKey literal fails the dialog text drift pin"
}
# The frozen literal against the classic functions, unconditional: both are found, and the first 13 literals are strings of them.
$sd4aFrozen=[ordered]@{}; foreach($key in @($dlgFrozen.Keys)[0..12]){$sd4aFrozen[$key]=[string]$dlgFrozen[$key]}
$sdFrozenDrift=Get-SideDriftProblems $sd4aFrozen $sdClassic
foreach($pr in $sdFrozenDrift){Write-Host "FINDING: $pr"}
Check ((Get-AstFunction $classicAst 'ShowUiSideResult').Count -eq 1 -and (Get-AstFunction $classicAst 'ShowDriverGuidance').Count -eq 1 -and $sdFrozenDrift.Count -eq 0 -and $sdClassic.Count -gt 20) 'the frozen side result and driver guidance literal equals the classic ShowUiSideResult and ShowDriverGuidance strings'
# The classic key targets, read from the classic AST: the side result has AcceptButton and CancelButton = Close; driver guidance has CancelButton only.
$sdSideClassic=(Get-AstFunction $classicAst 'ShowUiSideResult')[0].Extent.Text
$sdDriverClassic=(Get-AstFunction $classicAst 'ShowDriverGuidance')[0].Extent.Text
Check ($sdSideClassic.Contains('$dialog.AcceptButton=$close') -and $sdSideClassic.Contains('$dialog.CancelButton=$close')) 'classic ShowUiSideResult: Close is both AcceptButton and CancelButton'
Check ($sdDriverClassic.Contains('$dialog.CancelButton=$close') -and -not $sdDriverClassic.Contains('AcceptButton')) 'classic ShowDriverGuidance: Close is the CancelButton and there is no AcceptButton'
# 5b-delete-end
function Get-SideKeyTargets([string]$Text,[string]$FnName){
    $fn=Get-DlgFn $Text $FnName
    if($null -eq $fn){return $null}
    $calls=@($fn.FindAll({param($n) Test-DlgCall $n 'New-FastLlmUiFluentDialog'},$true))
    if($calls.Count -ne 1){return $null}
    $e=Get-DlgParamText $calls[0] 'Enter'; $x=Get-DlgParamText $calls[0] 'Escape'
    return [pscustomobject]@{Enter=$(if($null -eq $e){'<none>'}else{$e});Escape=$(if($null -eq $x){'<none>'}else{$x})}
}
function Get-SideFindings([string]$Text){
    $f=New-Object System.Collections.ArrayList
    $side=Get-SideKeyTargets $Text 'Show-FastLlmUiFluentSideResult'
    $drv=Get-SideKeyTargets $Text 'Show-FastLlmUiFluentDriverGuidance'
    if($null -eq $side -or $side.Enter -cne "'Close'" -or $side.Escape -cne "'Close'"){[void]$f.Add('the side result does not answer Enter and Escape with Close')}
    if($null -eq $drv -or $drv.Enter -cnotin @("''",'<none>')){[void]$f.Add('driver guidance has an Enter target (the classic form has no AcceptButton)')}
    if($null -eq $drv -or $drv.Escape -cne "'Close'"){[void]$f.Add('driver guidance does not answer Escape with Close')}
    foreach($name in 'Show-FastLlmUiFluentSideResult','Show-FastLlmUiFluentDriverGuidance'){
        $fn=Get-DlgFn $Text $name
        if($null -eq $fn){[void]$f.Add("$name is not defined once");continue}
        if($fn.Extent.Text -cmatch 'IsDefault|IsCancel'){[void]$f.Add("$name sets IsDefault or IsCancel")}
    }
    $box=Get-DlgFn $Text 'New-FastLlmUiFluentDialogReadBox'
    if($null -eq $box -or -not $box.Extent.Text.Contains('$box.IsReadOnly = $true') -or -not $box.Extent.Text.Contains('$box.IsUndoEnabled = $false') -or -not $box.Extent.Text.Contains('TextWrapping]::Wrap') -or -not $box.Extent.Text.Contains('$box.AcceptsReturn = $false')){[void]$f.Add('the read box is not read-only, undo-free, wrapping and Enter-transparent')}
    $drvFn=Get-DlgFn $Text 'Show-FastLlmUiFluentDriverGuidance'
    if($null -ne $drvFn -and -not $drvFn.Extent.Text.Contains('SetCanContentScroll($devices, $false)')){[void]$f.Add('the device list scrolls by item (CanContentScroll is not False)')}
    if($null -ne $drvFn){
        $names=@($drvFn.FindAll({param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Static -and [string]$n.Member.Value -in @('SetName','SetLabeledBy')},$true)).Count
        if($names -lt 3){[void]$f.Add('the driver guidance inputs do not each carry Name and LabeledBy')}
    }
    return ,$f.ToArray()
}
$sdReal=Get-SideFindings $sdText
foreach($pr in $sdReal){Write-Host "FINDING: $pr"}
Check ($sdReal.Count -eq 0) 'side result: Enter = Escape = Close; driver guidance: Escape = Close and no Enter target; read-only undo-free wrapping box; the list scrolls by pixel; every input has Name and LabeledBy'
$sdPlants=[ordered]@{
    'driver guidance Enter = Close'=$sdText.Replace("-Enter '' -Escape 'Close' -Owner `$script:form`n    `$work","-Enter 'Close' -Escape 'Close' -Owner `$script:form`n    `$work")
    'side result Enter removed'=$sdText.Replace("-Enter 'Close' -Escape 'Close' -Owner `$script:form`n    `$work = [System.Windows.SystemParameters]::WorkArea`n    `$dialog['Window'].Width = [Math]::Min(`$work.Width * 0.9, 760.0","-Escape 'Close' -Owner `$script:form`n    `$work = [System.Windows.SystemParameters]::WorkArea`n    `$dialog['Window'].Width = [Math]::Min(`$work.Width * 0.9, 760.0")
    'side result Escape removed'=$sdText.Replace("-Buttons `$buttons -Enter 'Close' -Escape 'Close' -Owner `$script:form`n    `$work = [System.Windows.SystemParameters]::WorkArea`n    `$dialog['Window'].Width = [Math]::Min(`$work.Width * 0.9, 760.0","-Buttons `$buttons -Enter 'Close' -Owner `$script:form`n    `$work = [System.Windows.SystemParameters]::WorkArea`n    `$dialog['Window'].Width = [Math]::Min(`$work.Width * 0.9, 760.0")
    'driver guidance Escape removed'=$sdText.Replace("-Enter '' -Escape 'Close'","-Enter ''")
    'undo left on'=$sdText.Replace('$box.IsUndoEnabled = $false','$box.IsUndoEnabled = $true')
    'the read box swallowing Enter'=$sdText.Replace('$box.AcceptsReturn = $false','$box.AcceptsReturn = $true')
    'list scrolls by item'=$sdText.Replace('SetCanContentScroll($devices, $false)','SetCanContentScroll($devices, $true)')
    'a LabeledBy dropped'=$sdText.Replace('        [System.Windows.Automation.AutomationProperties]::SetLabeledBy($field, $label)','')
    'IsDefault on the driver close'=$sdText.Replace("-Enter '' -Escape 'Close'","-Enter '' -Escape 'Close'; `$IsDefault = 1")
}
foreach($k in $sdPlants.Keys){ Check ($sdPlants[$k] -cne $sdText -and (Get-SideFindings $sdPlants[$k]).Count -ge 1) "mutation check: the side result and driver guidance pins flag: $k" }
# ===== end PR 4a Task 5 =====


# ===== PR 4a Task 6: the #84 lines in the shell message area (SignInNotice) =====
# The element is constant XAML (polite, named by its text, theme brushes, wrapping); its text is the startup's own sign-in line (captured from the
# output/status writes at the loop start, no literal and no second read) or the existing not-measured line; it hides once a start has succeeded.
$snText=[IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.UiFluentShell.ps1'))
function Get-SignInNoticeFindings([string]$Text){
    $f=New-Object System.Collections.ArrayList
    $m=[regex]::Match($Text,"(?s)\`$script:FastLlmUiXaml\['FastLlm.Shell'\] = @'\r?\n(.*?)\r?\n'@")
    $x=if($m.Success){$m.Groups[1].Value}else{''}
    $el=[regex]::Match($x,'(?s)<TextBlock x:Name="SignInNotice"[^>]*>')
    if(-not $el.Success){[void]$f.Add('there is no SignInNotice TextBlock in the shell XAML')}
    else{
        if($el.Value -cnotmatch 'AutomationProperties\.LiveSetting="Polite"'){[void]$f.Add('SignInNotice is not a polite live region')}
        if($el.Value -cmatch 'AutomationProperties\.Name|\bText='){[void]$f.Add('SignInNotice carries a literal name or text (its name is its text)')}
        if($el.Value -cnotmatch 'TextWrapping="Wrap"'){[void]$f.Add('SignInNotice does not wrap')}
        if($el.Value -cnotmatch 'Foreground="\{DynamicResource FastLlm\.'){[void]$f.Add('SignInNotice has no theme foreground')}
    }
    if($x -cnotmatch '<Border x:Name="SignInNoticeBar" Visibility="Collapsed"'){[void]$f.Add('the notice bar is not a collapsed Border')}
    $upd=Get-DlgFn $Text 'Update-FastLlmUiFluentMessages'
    $sav=Get-DlgFn $Text 'Save-FastLlmUiFluentSignInNotice'
    $loop=Get-DlgFn $Text 'Start-FastLlmUiFluentLoop'
    if($null -eq $upd -or $null -eq $sav -or $null -eq $loop){[void]$f.Add('the message refresh, the capture or the loop is not defined once');return ,$f.ToArray()}
    $ut=$upd.Extent.Text
    if(-not $sav.Extent.Text.Contains('$script:statusLabel.Text') -or -not $sav.Extent.Text.Contains('$script:output.Text')){[void]$f.Add('the capture does not read the startup status and output text')}
    if($sav.Extent.Text -cmatch 'Get-FastLlmSignInAttentionText|Read-FastLlmSignInResult|Get-FastLlmSignInResultText'){[void]$f.Add('the capture reads the sign-in result again')}
    if($sav.Extent.Text -cmatch "\`$keys\['SignInLine'\] = '"){[void]$f.Add('the capture stores a literal line')}
    $capture=@($loop.FindAll({param($n) Test-DlgCall $n 'Save-FastLlmUiFluentSignInNotice'},$true))
    $tick=@($loop.FindAll({param($n) Test-DlgCall $n 'Invoke-FastLlmUiFluentTick'},$true))
    if($capture.Count -ne 1 -or $tick.Count -ne 1 -or $capture[0].Extent.StartOffset -ge $tick[0].Extent.StartOffset){[void]$f.Add('the capture is not called once before the first tick')}
    if(-not $ut.Contains("`$e['SignInNotice'].Text = `$noticeText") -or -not $ut.Contains("[string] `$keys['SignInLine']")){[void]$f.Add('the notice text is not the captured line')}
    if(-not $ut.Contains("Get-FastLlmSavedServingFailureText -Code 'serving-profile-not-measured'") -or -not $ut.Contains('$script:backgroundLabel.Text') -or -not $ut.Contains('{ $noticeText = [string] $notMeasured }')){[void]$f.Add('the not-measured line is not the existing text compared with the background line')}
    if($ut -cnotmatch "(?s)Get-FastLlmUiCardState.*?'running' -or .*?'running-background'.*?\`$keys\['SignInLine'\] = \`$null"){[void]$f.Add('the sign-in line is not cleared once a start has succeeded')}
    if($ut -cnotmatch "SignInNoticeBar'\]\.Visibility = if \(\`$noticeText -cne ''\)"){[void]$f.Add('the bar does not show only while there is a notice')}
    if($ut -cnotmatch "SignInNotice'\]\.Text = .*?\r?\n\s*if \(\`$noticeText -cne ''\) \{ Send-FastLlmUiFluentLiveRegion"){[void]$f.Add('a notice change does not raise the live region')}
    return ,$f.ToArray()
}
$snReal=Get-SignInNoticeFindings $snText
foreach($pr in $snReal){Write-Host "FINDING: $pr"}
Check ($snReal.Count -eq 0) 'SignInNotice: polite, wrapping, themed, named by its text; the text is the startup line or the existing not-measured line (no literal); it hides after a successful start'
$snPlants=[ordered]@{
    'not polite'=$snText.Replace('AutomationProperties.LiveSetting="Polite"','AutomationProperties.LiveSetting="Assertive"')
    'literal name'=$snText.Replace('<TextBlock x:Name="SignInNotice" ','<TextBlock x:Name="SignInNotice" AutomationProperties.Name="Sign-in notice" ')
    'no wrap'=$snText.Replace('<TextBlock x:Name="SignInNotice" TextWrapping="Wrap" ','<TextBlock x:Name="SignInNotice" ')
    'literal text'=$snText.Replace('$e[''SignInNotice''].Text = $noticeText','$e[''SignInNotice''].Text = ''Sign-in start was refused.''')
    'second read'=$snText.Replace('$line = [string] $script:statusLabel.Text','$line = [string] (Get-FastLlmSignInAttentionText -InstallRoot $InstallRoot)')
    'never hides'=$snText.Replace('$keys[''SignInLine''] = $null }','$null = 1 }')
    'capture after the tick'=$snText.Replace("    Save-FastLlmUiFluentSignInNotice`n    Invoke-FastLlmUiFluentTick","    Invoke-FastLlmUiFluentTick`n    Save-FastLlmUiFluentSignInNotice")
    'not-measured text dropped'=$snText.Replace('{ $noticeText = [string] $notMeasured }','{ }')
    'bar always visible'=$snText.Replace('$e[''SignInNoticeBar''].Visibility = if ($noticeText -cne '''')','$e[''SignInNoticeBar''].Visibility = if ($true)')
}
foreach($k in $snPlants.Keys){ Check ($snPlants[$k] -cne $snText -and (Get-SignInNoticeFindings $snPlants[$k]).Count -ge 1) "mutation check: the SignInNotice pins flag: $k" }
# ===== end PR 4a Task 6 (#84 lines) =====


# ===== PR 4b Task B2 (builder R): the setup check, the recipe chooser and the save prompt on the host =====
# Texts are the classic literals (drift pin, with the pinned rule that a WinForms && is one & here), the key targets are the classic AcceptButton and CancelButton
# read from the classic AST, the setup check returns today's three strings, Choose is disabled until a row is selected, and a double-click on a selected row
# chooses (classic: the ListView's Add_DoubleClick in ShowRecipeChooser, so it is today's behaviour, not an addition). Each runs again on planted mutants.
$r4Keys=@('SetupTitle','SetupIntro','SetupNeed64','SetupVcMissing','SetupNoLoader','SetupAfter','SetupMsLink','SetupAmdLink','SetupMsUrl','SetupAmdUrl','SetupMsFailed','SetupAmdFailed','SetupRecheck','SetupPrepare','SetupLater','ChooserTitle','ChooserIntro','ChooserNotice','ChooserSetup','ChooserModel','ChooserContext','ChooserEngine','ChooserChoose','ChooserCancel','ChooserCellName')
Check ($sdTable.Count -eq 13+$r4Keys.Count -and (@($sdTable.Keys)[13..(12+$r4Keys.Count)] -join ',') -ceq ($r4Keys -join ',')) 'the dialog text table has the 4b setup check and chooser keys after the 4a keys, in order'
$r4Str='System.Management.Automation.Language.StringConstantExpressionAst'
function Get-R4Norm($Node){
    $v=[string]$Node.Value
    if($Node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]){$v=[regex]::Replace($v,'\$\(.*\)','{0}')}
    return $v
}
# The string node a statement assigns directly (a constant or an expandable string), else $null.
function Get-R4RightText($Right){
    $e=$Right
    if($e -is [System.Management.Automation.Language.PipelineAst] -and $e.PipelineElements.Count -eq 1){$e=$e.PipelineElements[0]}
    if($e -is [System.Management.Automation.Language.CommandExpressionAst]){$e=$e.Expression}
    if(Test-R4Text $e){return $e}
    return $null
}
function Test-R4Text($Node){ return ($Node -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $Node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) }
# Every string of the two classic functions (a $(...) part is {0}), and the texts the user can see: assigned to .Text, added to the lines or the columns, or opened.
function Get-R4Classic($Ast){
    $all=New-Object System.Collections.ArrayList; $shown=New-Object System.Collections.ArrayList
    foreach($fnName in 'ShowSetupAttention','ShowRecipeChooser'){
        foreach($fnAst in (Get-AstFunction $Ast $fnName)){
            foreach($k in @($fnAst.FindAll({param($n) Test-R4Text $n},$true))){ [void]$all.Add((Get-R4Norm $k)) }
            foreach($a in @($fnAst.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -cmatch '\.Text$'},$true))){
                $r=Get-R4RightText $a.Right
                if($null -ne $r){ [void]$shown.Add((Get-R4Norm $r)) }
            }
            foreach($m in @($fnAst.FindAll({param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$n.Member.Extent.Text -ceq 'Add' -and $n.Expression.Extent.Text -cin @('$lines','$list.Columns')},$true))){
                foreach($arg in @($m.Arguments)){ if(Test-R4Text $arg){ [void]$shown.Add((Get-R4Norm $arg)) } }
            }
            foreach($c in @($fnAst.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -ceq 'Start-Process'},$true))){
                if($c.CommandElements.Count -ge 2 -and (Test-R4Text $c.CommandElements[1])){ [void]$shown.Add((Get-R4Norm $c.CommandElements[1])) }
            }
        }
    }
    $shown2=@($shown|Where-Object{$_ -cne ''}|Select-Object -Unique)
    return [pscustomobject]@{All=@($all);Shown=$shown2}
}
# The table against the classic: every value is a classic string (a & is && in WinForms; ChooserCellName is the one non-classic text), and every classic shown text is in the table.
# 5b-delete-begin
function Get-R4DriftProblems($Table,$Classic,[string[]]$Extra=@()){
    $problems=New-Object System.Collections.ArrayList
    $norm=@{}
    foreach($key in $r4Keys){
        $v=[string]$Table[$key]
        if($key -ceq 'ChooserCellName'){ if($v -cne '{0}: {1}'){[void]$problems.Add("the non-classic $key is not '{0}: {1}'")}; continue }
        $c=$v.Replace('&','&&'); $norm[$c]=$true
        if($Classic.All -cnotcontains $c){[void]$problems.Add("table value $key is not a string of ShowSetupAttention or ShowRecipeChooser")}
    }
    foreach($s in @($Classic.Shown)+@($Extra)){ if(-not $norm.ContainsKey([string]$s)){[void]$problems.Add("the classic text '$s' is not in the table")} }
    return ,$problems.ToArray()
}
$r4Classic=Get-R4Classic $classicAst
$r4DriftFrozen=Get-R4DriftProblems $dlgFrozen $r4Classic
foreach($pr in $r4DriftFrozen){Write-Host "FINDING: $pr"}
Check ((Get-AstFunction $classicAst 'ShowSetupAttention').Count -eq 1 -and (Get-AstFunction $classicAst 'ShowRecipeChooser').Count -eq 1 -and $r4DriftFrozen.Count -eq 0 -and $r4Classic.Shown.Count -ge 20) "the frozen setup check and chooser literal equals the classic texts (&& read as &; $($r4Classic.Shown.Count) classic texts read)"
$r4Drift=Get-R4DriftProblems $sdTable $r4Classic
foreach($pr in $r4Drift){Write-Host "FINDING: $pr"}
Check ($r4Drift.Count -eq 0 -and $r4Classic.Shown.Count -ge 20) "every setup check and chooser text value is a classic string (&& read as &), and every classic text is in the table ($($r4Classic.Shown.Count) classic texts read)"
foreach($rk in $r4Keys){
    if($rk -ceq 'ChooserCellName'){continue}
    $mut=[ordered]@{}; foreach($key in @($sdTable.Keys)){$mut[$key]=[string]$sdTable[$key]}
    $mut[$rk]=[string]$sdTable[$rk]+'.'
    Check ((Get-R4DriftProblems $mut $r4Classic).Count -ge 1) "mutation check: a changed $rk literal fails the setup check and chooser drift pin"
}
$mut=[ordered]@{}; foreach($key in @($sdTable.Keys)){$mut[$key]=[string]$sdTable[$key]}; $mut['ChooserCellName']='{1}: {0}'
Check ((Get-R4DriftProblems $mut $r4Classic).Count -ge 1) 'mutation check: a changed ChooserCellName fails the drift pin'
$mut=[ordered]@{}; foreach($key in @($sdTable.Keys)){$mut[$key]=[string]$sdTable[$key]}; $mut['SetupPrepare']='Prepare && review VC++'
Check ((Get-R4DriftProblems $mut $r4Classic).Count -ge 1) 'mutation check: the classic && copied as && (not the displayed &) fails the drift pin'
Check ((Get-R4DriftProblems $sdTable $r4Classic @('A new caption')).Count -ge 1) 'mutation check: a new shown literal in the classic functions that the table lacks fails the drift pin'
# 5b-delete-end

# --- the key targets: frozen literals (the classic AcceptButton and CancelButton captions); the check against the classic AST is below ---
$r4SetupKeys=@{Enter='Recheck';Escape='Do later'}
$r4ChooserKeys=@{Enter='Choose';Escape='Cancel'}
# 5b-delete-begin
function Get-R4ClassicKeys($Ast,[string]$FnName){
    $fn=(Get-AstFunction $Ast $FnName)[0]
    $caption=@{}
    foreach($a in @($fn.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -cmatch '^\$\w+\.Text$'},$true))){
        $r=Get-R4RightText $a.Right; if($null -ne $r){ $caption[($a.Left.Extent.Text -replace '\.Text$','')]=(Get-R4Norm $r).Replace('&&','&') }
    }
    $out=@{}
    foreach($pair in @(@('Enter','AcceptButton'),@('Escape','CancelButton'))){
        $asg=@($fn.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq ('$dialog.'+$pair[1])},$true))
        $out[$pair[0]]=if($asg.Count -eq 1 -and $caption.ContainsKey($asg[0].Right.Extent.Text)){$caption[$asg[0].Right.Extent.Text]}else{'<none>'}
    }
    return $out
}
$r4SetupKeysClassic=Get-R4ClassicKeys $classicAst 'ShowSetupAttention'
$r4ChooserKeysClassic=Get-R4ClassicKeys $classicAst 'ShowRecipeChooser'
Check ($r4SetupKeysClassic['Enter'] -ceq 'Recheck' -and $r4SetupKeysClassic['Escape'] -ceq 'Do later') 'classic ShowSetupAttention: Enter = Recheck, Escape = Do later'
Check ($r4ChooserKeysClassic['Enter'] -ceq 'Choose' -and $r4ChooserKeysClassic['Escape'] -ceq 'Cancel') 'classic ShowRecipeChooser: Enter = Choose, Escape = Cancel'
Check ($r4SetupKeysClassic['Enter'] -ceq $r4SetupKeys['Enter'] -and $r4SetupKeysClassic['Escape'] -ceq $r4SetupKeys['Escape'] -and $r4ChooserKeysClassic['Enter'] -ceq $r4ChooserKeys['Enter'] -and $r4ChooserKeysClassic['Escape'] -ceq $r4ChooserKeys['Escape']) 'the frozen setup check and chooser key targets equal the classic AcceptButton and CancelButton captions'
$r4SetupFn=(Get-AstFunction $classicAst 'ShowSetupAttention')[0]; $r4ChooserFn=(Get-AstFunction $classicAst 'ShowRecipeChooser')[0]
# 5b-delete-end
function Get-R4Returns($Fn){
    $r=New-Object System.Collections.ArrayList
    foreach($x in @($Fn.FindAll({param($n) $n -is [System.Management.Automation.Language.ReturnStatementAst]},$true))){ if($null -ne $x.Pipeline -and $x.Pipeline.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst] -and (Test-R4Text $x.Pipeline.PipelineElements[0].Expression)){[void]$r.Add([string]$x.Pipeline.PipelineElements[0].Expression.Value)} }
    return ,$r.ToArray()
}
# 5b-delete-begin
Check (((Get-R4Returns $r4SetupFn) -join ',') -ceq 'recheck,prepare,defer') 'classic ShowSetupAttention returns recheck, prepare or defer'
# Lead condition 1: the classic chooser has a double-click on the list that chooses a selected row.
$r4Dbl=@($r4ChooserFn.FindAll({param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$n.Member.Extent.Text -ceq 'Add_DoubleClick' -and $n.Expression.Extent.Text -ceq '$list'},$true))
Check ($r4Dbl.Count -eq 1 -and $r4Dbl[0].Extent.Text -cmatch '\$list\.SelectedItems\.Count -eq 1\)\{\$dialog\.DialogResult=\[Windows\.Forms\.DialogResult\]::OK\}') 'classic ShowRecipeChooser: a double-click on the list, with one row selected, answers OK (Choose); so the fluent double-click is today''s behaviour'
Check ($r4ChooserFn.Extent.Text.Contains('$choose.Enabled=$false') -and $r4ChooserFn.Extent.Text.Contains('$list.Add_SelectedIndexChanged({$choose.Enabled=($list.SelectedItems.Count -eq 1)}')) 'classic ShowRecipeChooser: Choose is disabled until one row is selected'
# 5b-delete-end

# --- the fluent side ---
function Get-R4Table([string]$Text){
    $a=@((ConvertTo-PinAst $Text).FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$script:FastLlmUiFluentDialogText'},$true))
    if($a.Count -ne 1){return $null}
    return (& ([scriptblock]::Create($a[0].Right.Extent.Text)))
}
function Get-R4Keys([string]$Text,[string]$FnName,$Table){
    $fn=Get-DlgFn $Text $FnName
    if($null -eq $fn){return $null}
    $calls=@($fn.FindAll({param($n) Test-DlgCall $n 'New-FastLlmUiFluentDialog'},$true))
    if($calls.Count -ne 1){return $null}
    $asg=@($fn.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$buttons'},$true))
    if($asg.Count -ne 1){return $null}
    $ids=@{}
    foreach($h in @($asg[0].Right.FindAll({param($n) $n -is [System.Management.Automation.Language.HashtableAst]},$true))){
        foreach($kv in $h.KeyValuePairs){ $m=[regex]::Match($kv.Item2.Extent.Text,'\$t\.(\w+)'); if($m.Success -and $Table.Contains($m.Groups[1].Value)){$ids[[string]$kv.Item1.Extent.Text]=[string]$Table[$m.Groups[1].Value]} }
    }
    $out=@{}
    foreach($p in 'Enter','Escape'){
        $raw=Get-DlgParamText $calls[0] $p
        $id=if($null -eq $raw){''}else{$raw.Trim("'")}
        $out[$p+'Id']=$id
        $out[$p]=if($id -ceq ''){'<none>'}elseif($ids.ContainsKey($id)){$ids[$id]}else{'<unknown id>'}
    }
    $out['Ids']=$ids
    return $out
}
function Get-R4Findings([string]$Text){
    $f=New-Object System.Collections.ArrayList
    $table=Get-R4Table $Text
    if($null -eq $table){return ,@('the dialog text table is not assigned exactly once')}
    foreach($name in 'Show-FastLlmUiFluentSetupAttention','Show-FastLlmUiFluentRecipeChooser'){
        $fn=Get-DlgFn $Text $name
        if($null -eq $fn){[void]$f.Add("$name is not defined once");continue}
        if($fn.Extent.Text -cmatch 'IsDefault|IsCancel|AcceptButton|CancelButton'){[void]$f.Add("$name sets IsDefault, IsCancel, AcceptButton or CancelButton")}
        $first=@($fn.Body.EndBlock.Statements)[0]
        if($null -eq $first -or $first.Extent.Text -cne 'RevealUiForAction'){[void]$f.Add("$name does not reveal the window first")}
        $trays=@($fn.FindAll({param($n) Test-DlgCall $n 'SetTrayMenuAvailable'},$true))
        $off=@($trays|Where-Object{$_.Extent.Text -ceq 'SetTrayMenuAvailable $false'}); $on=@($trays|Where-Object{$_.Extent.Text -ceq 'SetTrayMenuAvailable $true'})
        $tries=@($fn.FindAll({param($n) $n -is [System.Management.Automation.Language.TryStatementAst] -and $null -ne $n.Finally},$true))
        if($off.Count -ne 1 -or $on.Count -ne 1 -or $tries.Count -ne 1){[void]$f.Add("$name does not make the tray menu unavailable once, show inside one try, and restore it in the finally")}
        elseif($off[0].Extent.EndOffset -gt $tries[0].Extent.StartOffset -or $on[0].Extent.StartOffset -lt $tries[0].Finally.Extent.StartOffset -or $on[0].Extent.EndOffset -gt $tries[0].Finally.Extent.EndOffset){[void]$f.Add("$name does not restore the tray menu in the finally")}
        $owners=@($fn.FindAll({param($n) Test-DlgCall $n 'New-FastLlmUiFluentDialog'},$true)|Where-Object{(Get-DlgParamText $_ 'Owner') -ceq '$script:form'})
        if($owners.Count -ne 1){[void]$f.Add("$name does not own its dialog by the main window")}
        if($fn.Extent.Text -cmatch '\bWidth\s*=\s*"|Width="'){[void]$f.Add("$name sets a Width attribute")}
    }
    # setup check: Enter = Recheck, Escape = Do later (the classic AcceptButton and CancelButton); the three result strings; Prepare gated by the offer.
    $su=Get-R4Keys $Text 'Show-FastLlmUiFluentSetupAttention' $table
    if($null -eq $su){[void]$f.Add('the setup check has no single dialog call or button table')}
    else{
        if($su['Enter'] -cne $r4SetupKeys['Enter']){[void]$f.Add("the setup check Enter answers '$($su['Enter'])', the classic AcceptButton is '$($r4SetupKeys['Enter'])'")}
        if($su['Escape'] -cne $r4SetupKeys['Escape']){[void]$f.Add("the setup check Escape answers '$($su['Escape'])', the classic CancelButton is '$($r4SetupKeys['Escape'])'")}
        if(-not (@($su['Ids'].Values) -ccontains 'Prepare & review VC++')){[void]$f.Add('the setup check has no Prepare & review VC++ button')}
    }
    $suFn=Get-DlgFn $Text 'Show-FastLlmUiFluentSetupAttention'
    if($null -ne $suFn){
        if(((Get-R4Returns $suFn) -join ',') -cne 'recheck,prepare,defer'){[void]$f.Add("the setup check returns '$((Get-R4Returns $suFn) -join ',')', not recheck, prepare, defer")}
        $t=$suFn.Extent.Text
        if($t -cnotmatch [regex]::Escape("if (`$answer -ceq 'Recheck') { return 'recheck' }") -or $t -cnotmatch [regex]::Escape("if (`$answer -ceq 'Prepare' -and `$offer.canPrepare) { return 'prepare' }")){[void]$f.Add('the setup check does not map Recheck to recheck and Prepare (only when the offer allows it) to prepare')}
        if($t -cnotmatch [regex]::Escape("`$dialog['Buttons']['Prepare'].IsEnabled = [bool] `$offer.canPrepare")){[void]$f.Add('the Prepare button is not enabled by the offer (canPrepare)')}
        foreach($need in 'SetupMicrosoftLink','SetupAmdLink'){ if($t -cnotmatch [regex]::Escape("-Name '$need'")){[void]$f.Add("the setup check has no $need link")} }
        if(@($suFn.FindAll({param($n) Test-DlgCall $n 'Start-Process'},$true)).Count -ne 2){[void]$f.Add('the setup check does not open exactly its two links')}
        if($t -cnotmatch [regex]::Escape('catch { $details.Text = $msFailed }') -or $t -cnotmatch [regex]::Escape('catch { $details.Text = $amdFailed }')){[void]$f.Add('a link that fails to open does not say so in the text box')}
        if($t -cnotmatch [regex]::Escape('SetName($details,')){[void]$f.Add('the setup check text box has no automation name')}
    }
    $linkFn=Get-DlgFn $Text 'New-FastLlmUiFluentDialogLinkButton'
    if($null -eq $linkFn -or -not $linkFn.Extent.Text.Contains('SetName($link, $Text)') -or -not $linkFn.Extent.Text.Contains('$link.Name = $Name')){[void]$f.Add('a link button is not named')}
    # recipe chooser
    $ch=Get-R4Keys $Text 'Show-FastLlmUiFluentRecipeChooser' $table
    $chFn=Get-DlgFn $Text 'Show-FastLlmUiFluentRecipeChooser'
    if($null -eq $ch -or $null -eq $chFn){[void]$f.Add('the chooser has no single dialog call or button table')}
    else{
        $ct=$chFn.Extent.Text
        if($ch['EnterId'] -cne ''){[void]$f.Add('the chooser starts with an Enter target (Choose is disabled until a row is selected)')}
        if($ch['Escape'] -cne $r4ChooserKeys['Escape']){[void]$f.Add("the chooser Escape answers '$($ch['Escape'])', the classic CancelButton is '$($r4ChooserKeys['Escape'])'")}
        $sel=@($chFn.FindAll({param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$n.Member.Extent.Text -ceq 'Add_SelectionChanged' -and $n.Expression.Extent.Text -ceq '$list'},$true))
        if($sel.Count -ne 1){[void]$f.Add('the chooser has no single selection handler')}
        else{
            $h=$sel[0].Extent.Text
            if($h -cnotmatch [regex]::Escape('$enabled = ($list.SelectedItems.Count -eq 1)') -or $h -cnotmatch [regex]::Escape('$choose.IsEnabled = $enabled')){[void]$f.Add('Choose is not enabled exactly while one row is selected')}
            $m=[regex]::Match($h,"if \(\`$enabled\) \{ \`$state\['Enter'\] = '(\w+)' \} else \{ \`$state\['Enter'\] = '' \}")
            if(-not $m.Success){[void]$f.Add('the Enter target does not follow the selection (Choose when enabled, nothing otherwise)')}
            elseif($ch['Ids'].ContainsKey($m.Groups[1].Value) -and $ch['Ids'][$m.Groups[1].Value] -cne $r4ChooserKeys['Enter']){[void]$f.Add("the chooser Enter answers '$($ch['Ids'][$m.Groups[1].Value])', the classic AcceptButton is '$($r4ChooserKeys['Enter'])'")}
            elseif(-not $ch['Ids'].ContainsKey($m.Groups[1].Value)){[void]$f.Add('the chooser Enter target is not a button')}
        }
        if($ct -cnotmatch [regex]::Escape('$choose.IsEnabled = $false')){[void]$f.Add('Choose is enabled before a row is selected')}
        # PR 4b review fix P2: the double-click is on each row item (a double-click on the list's scrollbar or empty area must not choose), never on the list.
        $dblAll=@($chFn.FindAll({param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$n.Member.Extent.Text -ceq 'Add_MouseDoubleClick'},$true))
        $dbl=@($dblAll|Where-Object{$_.Expression.Extent.Text -ceq '$listItem'})
        if($dblAll.Count -ne 1 -or $dbl.Count -ne 1 -or $ct -cnotmatch [regex]::Escape('foreach ($listItem in @($list.Items))') -or $dbl[0].Extent.Text -cnotmatch [regex]::Escape('if ($list.SelectedItems.Count -eq 1)') -or $dbl[0].Extent.Text -cnotmatch [regex]::Escape("`$state['Result'] = 'Choose'") -or $dbl[0].Extent.Text -cnotmatch [regex]::Escape('$win.Close()')){[void]$f.Add('a double-click on a selected row item does not choose (classic: Add_DoubleClick, one row selected, OK; it is attached to each row, not to the list)')}
        # PR 4b review fix P1: the header lines up with the rows. No sideways scrolling (rows are measured at the list width), and the header follows the first row.
        if($ct -cnotmatch [regex]::Escape('SetHorizontalScrollBarVisibility($list, [System.Windows.Controls.ScrollBarVisibility]::Disabled)')){[void]$f.Add('the chooser list can scroll sideways (HorizontalScrollBarVisibility is not Disabled), so its star columns do not line up with the header')}
        $sync=@($chFn.FindAll({param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$n.Member.Extent.Text -ceq 'Add_SizeChanged' -and $n.Expression.Extent.Text -ceq '$firstRow'},$true))
        if($sync.Count -ne 1 -or $sync[0].Extent.Text -cnotmatch [regex]::Escape('$firstRow.TranslatePoint(') -or $sync[0].Extent.Text -cnotmatch [regex]::Escape('$headerGrid.Margin =') -or $sync[0].Extent.Text -cnotmatch [regex]::Escape('$firstRow.ActualWidth') -or $ct -cnotmatch [regex]::Escape('if ($null -eq $firstRow) { $firstRow = $grid }')){[void]$f.Add('the chooser header does not follow the first row (a SizeChanged handler on the first row that sets the header Margin from its offset and width)')}
        # PR 4b review fix P3: the list takes the theme brushes, as the Models switch list does.
        foreach($brush in @(@('BackgroundProperty','FastLlm.CardBrush'),@('ForegroundProperty','FastLlm.TextPrimaryBrush'),@('BorderBrushProperty','FastLlm.ControlStrongStrokeBrush'))){
            if($ct -cnotmatch [regex]::Escape("`$list.SetResourceReference([System.Windows.Controls.Control]::$($brush[0]), '$($brush[1])')")){[void]$f.Add("the chooser list $($brush[0]) is not the theme brush $($brush[1])")}
        }
        if($ct -cnotmatch [regex]::Escape('SetCanContentScroll($list, $false)')){[void]$f.Add('the chooser list scrolls by item (CanContentScroll is not False)')}
        if($ct -cnotmatch [regex]::Escape('SetName($list, $introText)') -or $ct -cnotmatch [regex]::Escape('SetLabeledBy($list, $intro)')){[void]$f.Add('the chooser list has no Name and LabeledBy')}
        if($ct -cnotmatch [regex]::Escape('$win.Add_Loaded({ $null = $list.Focus() }')){[void]$f.Add('the first focus is not the list while Choose is disabled')}
        if($ct -cnotmatch [regex]::Escape('SetName($cell,') -or $ct -cnotmatch [regex]::Escape('$cell.Name =') -or $ct -cnotmatch [regex]::Escape('SetName($item, [string] $row.label)')){[void]$f.Add('a chooser cell or row has no name')}
        if($ct -cnotmatch [regex]::Escape('if ($answer -ceq ''Choose'' -and $list.SelectedItems.Count -eq 1)')){[void]$f.Add('the chooser returns a row without Choose and one selected row')}
        if($ct -cnotmatch [regex]::Escape('if ($shown.Count -eq 0) { return $null }') -or $ct -cnotmatch [regex]::Escape('$script:statusLabel.Text = $script:chooserNotice')){[void]$f.Add('the chooser lost its empty-list return or its notice on the status line')}
        foreach($col in @('label','model','contextText','engineText')){ if($ct -cnotmatch "Key = '$col'"){[void]$f.Add("the chooser has no $col column")} }
    }
    return ,$f.ToArray()
}
$r4Real=Get-R4Findings $sdText
foreach($pr in $r4Real){Write-Host "FINDING: $pr"}
Check ($r4Real.Count -eq 0) 'setup check and chooser: Enter and Escape are the classic AcceptButton and CancelButton, the result strings, Prepare gated by the offer, Choose disabled until a selection, the double-click, names, focus, reveal and tray in a finally'
function Edit-R4Plant([string]$From,[string]$To){ if($sdText.IndexOf($From,[StringComparison]::Ordinal) -lt 0){throw "FAIL: 4b plant anchor missing: $From"}; return $sdText.Replace($From,$To) }
$r4Plants=[ordered]@{
    'the setup Enter is Do later'=Edit-R4Plant "-Buttons `$buttons -Enter 'Recheck' -Escape 'Later'" "-Buttons `$buttons -Enter 'Later' -Escape 'Later'"
    'the setup Escape is Recheck'=Edit-R4Plant "-Enter 'Recheck' -Escape 'Later'" "-Enter 'Recheck' -Escape 'Recheck'"
    'the setup Enter removed'=Edit-R4Plant "-Enter 'Recheck' -Escape 'Later'" "-Escape 'Later'"
    'the prepare string changed to yes'=Edit-R4Plant "return 'prepare'" "return 'yes'"
    'the recheck string changed'=Edit-R4Plant "return 'recheck'" "return 'retry'"
    'the defer string changed'=Edit-R4Plant "return 'defer'" "return 'later'"
    'prepare returned without the offer'=Edit-R4Plant "-ceq 'Prepare' -and `$offer.canPrepare" "-ceq 'Prepare'"
    'Prepare always enabled'=Edit-R4Plant "`$dialog['Buttons']['Prepare'].IsEnabled = [bool] `$offer.canPrepare" "`$dialog['Buttons']['Prepare'].IsEnabled = `$true"
    'a link failure silent'=Edit-R4Plant 'catch { $details.Text = $msFailed }' 'catch { $null = $msFailed }'
    'a link button unnamed'=Edit-R4Plant '[System.Windows.Automation.AutomationProperties]::SetName($link, $Text)' '$null = $Text'
    'the setup check owner dropped'=Edit-R4Plant "-Enter 'Recheck' -Escape 'Later' -Owner `$script:form" "-Enter 'Recheck' -Escape 'Later'"
    'the setup tray restore out of the finally'=Edit-R4Plant 'try { $answer = Show-FastLlmUiFluentDialog -Dialog $dialog } finally { SetTrayMenuAvailable $true }' "try { `$answer = Show-FastLlmUiFluentDialog -Dialog `$dialog } finally { }`n    SetTrayMenuAvailable `$true"
    'the setup reveal dropped'=Edit-R4Plant "    RevealUiForAction`n    `$t = `$script:FastLlmUiFluentDialogText`n    `$lines" "    `$t = `$script:FastLlmUiFluentDialogText`n    `$lines"
    'the chooser starts with Enter = Choose'=Edit-R4Plant "-Enter '' -Escape 'Cancel'" "-Enter 'Choose' -Escape 'Cancel'"
    'the chooser Escape is Choose'=Edit-R4Plant "-Enter '' -Escape 'Cancel'" "-Enter '' -Escape 'Choose'"
    'Choose enabled at the start'=Edit-R4Plant '$choose.IsEnabled = $false' '$choose.IsEnabled = $true'
    'Choose enabled without a selection'=Edit-R4Plant '$enabled = ($list.SelectedItems.Count -eq 1)' '$enabled = ($list.SelectedItems.Count -ge 0)'
    'the Enter target always Choose'=Edit-R4Plant "if (`$enabled) { `$state['Enter'] = 'Choose' } else { `$state['Enter'] = '' }" "`$state['Enter'] = 'Choose'"
    'the Enter target Cancel on selection'=Edit-R4Plant "if (`$enabled) { `$state['Enter'] = 'Choose' }" "if (`$enabled) { `$state['Enter'] = 'Cancel' }"
    'the double-click without a selection guard'=Edit-R4Plant "            if (`$list.SelectedItems.Count -eq 1) {`n                if ([string] `$state['Result'] -ceq '')" "            if (`$true) {`n                if ([string] `$state['Result'] -ceq '')"
    'the double-click answers Cancel'=Edit-R4Plant "`$state['Result'] = 'Choose'" "`$state['Result'] = 'Cancel'"
    'the double-click removed'=Edit-R4Plant '$listItem.Add_MouseDoubleClick({' '$listItem.Add_MouseRightButtonUp({'
    'the double-click back on the list'=Edit-R4Plant '$listItem.Add_MouseDoubleClick({' '$list.Add_MouseDoubleClick({'
    'the list scrolls sideways (Auto)'=Edit-R4Plant 'SetHorizontalScrollBarVisibility($list, [System.Windows.Controls.ScrollBarVisibility]::Disabled)' 'SetHorizontalScrollBarVisibility($list, [System.Windows.Controls.ScrollBarVisibility]::Auto)'
    'the header sync handler dropped'=Edit-R4Plant '$firstRow.Add_SizeChanged({' '$firstRow.Add_MouseEnter({'
    'the header sync no longer writes the Margin'=Edit-R4Plant '$headerGrid.Margin = New-Object System.Windows.Thickness($offset' '$null = New-Object System.Windows.Thickness($offset'
    'the first row not kept'=Edit-R4Plant 'if ($null -eq $firstRow) { $firstRow = $grid }' '$null = $grid'
    'the list Background dropped'=Edit-R4Plant "`$list.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, 'FastLlm.CardBrush')" '$null = $list'
    'the list Foreground dropped'=Edit-R4Plant "`$list.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'FastLlm.TextPrimaryBrush')" '$null = $list'
    'the list BorderBrush dropped'=Edit-R4Plant "`$list.SetResourceReference([System.Windows.Controls.Control]::BorderBrushProperty, 'FastLlm.ControlStrongStrokeBrush')" '$null = $list'
    'the list scrolls by item'=Edit-R4Plant 'SetCanContentScroll($list, $false)' 'SetCanContentScroll($list, $true)'
    'the list LabeledBy dropped'=Edit-R4Plant '[System.Windows.Automation.AutomationProperties]::SetLabeledBy($list, $intro)' '$null = $intro'
    'the first focus not the list'=Edit-R4Plant '$win.Add_Loaded({ $null = $list.Focus() }.GetNewClosure())' '$win.Add_Loaded({ $null = $choose.Focus() }.GetNewClosure())'
    'a cell unnamed'=Edit-R4Plant '            $cell.Name = ''ChooserCell'' + [string] $column[''Key'']' '            $null = $column'
    'a row returned without Choose'=Edit-R4Plant "if (`$answer -ceq 'Choose' -and `$list.SelectedItems.Count -eq 1)" 'if ($list.SelectedItems.Count -eq 1)'
    'the chooser notice off the status line'=Edit-R4Plant 'if ($script:chooserNotice) { $script:statusLabel.Text = $script:chooserNotice }' '$null = 1'
    'the chooser tray restore out of the finally'=Edit-R4Plant "    finally { SetTrayMenuAvailable `$true }`n    return `$picked" "    finally { }`n    SetTrayMenuAvailable `$true`n    return `$picked"
    'the chooser column dropped'=Edit-R4Plant "        @{ Key = 'model'; Header = [string] `$t.ChooserModel; Weight = 170 },`n" ''
    'IsDefault on a chooser button'=Edit-R4Plant '    $choose.IsEnabled = $false' "    `$choose.IsEnabled = `$false; `$choose.IsDefault = `$true"
}
foreach($k in $r4Plants.Keys){ Check ($r4Plants[$k] -cne $sdText -and (Get-R4Findings $r4Plants[$k]).Count -ge 1) "mutation check: the setup check and chooser pins flag: $k" }
# --- PR 4b review fix G2: the setup check text is built by the classic sequence of $lines.Add calls, each under its classic condition, in the classic order ---
# Every $lines.Add of the function, in source order, as "conditions => text": the conditions are the enclosing if clause conditions and foreach collections (without
# white space), the text is the classic literal (a $(...) part is {0}), or for the fluent function the table value its $t.Key names; any other argument is its own text.
function Get-R4LineSequence($Fn,[bool]$Fluent,$Table){
    $seq=New-Object System.Collections.ArrayList
    $adds=@($Fn.FindAll({param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$n.Member.Extent.Text -ceq 'Add' -and $n.Expression.Extent.Text -ceq '$lines'},$true))
    foreach($add in $adds){
        $conds=New-Object System.Collections.ArrayList
        $node=$add.Parent
        while($null -ne $node -and -not [object]::ReferenceEquals($node,$Fn)){
            if($node -is [System.Management.Automation.Language.IfStatementAst]){
                foreach($clause in $node.Clauses){ if($clause.Item2.Extent.StartOffset -le $add.Extent.StartOffset -and $clause.Item2.Extent.EndOffset -ge $add.Extent.EndOffset){ [void]$conds.Insert(0,('if:'+($clause.Item1.Extent.Text -replace '\s',''))) } }
            }
            elseif($node -is [System.Management.Automation.Language.ForEachStatementAst]){ [void]$conds.Insert(0,('foreach:'+($node.Condition.Extent.Text -replace '\s',''))) }
            $node=$node.Parent
        }
        $arg=$add.Arguments[0]
        $text=($arg.Extent.Text -replace '\s','')
        if($arg -is [System.Management.Automation.Language.StringConstantExpressionAst]){ $text='"'+[string]$arg.Value+'"' }
        elseif($arg -is [System.Management.Automation.Language.ExpandableStringExpressionAst]){ $text='"'+[regex]::Replace([string]$arg.Value,'\$\(.*\)','{0}')+'"' }
        elseif($Fluent){
            $m=[regex]::Match([string]$arg.Extent.Text,'^\[string\]\s*\$t\.(\w+)$')
            if(-not $m.Success){ $m=[regex]::Match([string]$arg.Extent.Text,'^\[string\]::Format\(\[string\]\s*\$t\.(\w+),') }
            if($m.Success -and $Table.Contains($m.Groups[1].Value)){ $text='"'+[string]$Table[$m.Groups[1].Value]+'"' }
        }
        [void]$seq.Add((($conds.ToArray() -join '&')+' => '+$text))
    }
    return ,$seq.ToArray()
}
# The setup check's line sequence, frozen: every $lines.Add of the classic ShowSetupAttention in source order as "conditions => text" (a $(...) part is {0}); the check against the classic function is below.
$r4SeqFrozen=@(
    ' => "This PC is missing a required component for the current Vulkan lane. Review the latest setup check before continuing."',
    ' => ""',
    'if:$Decision.missing64BitHost => "Use 64-bit Windows PowerShell or PowerShell 7."',
    'if:@($Decision.missingVcRuntimeFiles).Count-gt0 => "Install the current Microsoft Visual C++ 2015-2022 Redistributable (x64). Missing: {0}."',
    'if:@($Decision.missingVcRuntimeFiles).Count-gt0 => $offer.message',
    'if:$Decision.missingVulkanLoader => "Install an AMD Windows driver with Vulkan support. The System32 Vulkan loader is not present."',
    ' => ""',
    ' => "After prerequisite setup and any required reboot, choose Recheck. This reruns read-only diagnostics. Compatibility and GPU performance remain unqualified."',
    'foreach:@($Decision.advisoryWarnings) => [string]$warning'
)
function Get-R4SetupSeqFindings([string]$Text){
    $f=New-Object System.Collections.ArrayList
    $table=Get-R4Table $Text
    $fn=Get-DlgFn $Text 'Show-FastLlmUiFluentSetupAttention'
    if($null -eq $table -or $null -eq $fn){[void]$f.Add('the setup check or its text table is not defined once');return ,$f.ToArray()}
    $classic=$r4SeqFrozen
    $fluent=Get-R4LineSequence $fn $true $table
    if($classic.Count -lt 8){[void]$f.Add("the classic setup check sequence could not be read ($($classic.Count) lines)")}
    if(($classic -join "`n") -cne ($fluent -join "`n")){[void]$f.Add("the setup check line sequence differs from the classic one (classic: $($classic -join ' | '); fluent: $($fluent -join ' | '))")}
    return ,$f.ToArray()
}
$r4Seq=Get-R4SetupSeqFindings $sdText
foreach($pr in $r4Seq){Write-Host "FINDING: $pr"}
Check ($r4Seq.Count -eq 0 -and $r4SeqFrozen.Count -eq 9) "the setup check adds the classic lines, each under its classic condition, in the classic order ($($r4SeqFrozen.Count) lines in the frozen sequence)"
# 5b-delete-begin
Check ($null -ne $r4SetupFn -and ((Get-R4LineSequence $r4SetupFn $false $null) -join "`n") -ceq ($r4SeqFrozen -join "`n")) 'the frozen setup check line sequence equals the lines the classic ShowSetupAttention adds, each under its condition, in order'
# 5b-delete-end
$r4SeqPlants=[ordered]@{
    'the 64-bit and loader conditions swapped'=Edit-R4Plant 'if ($Decision.missing64BitHost) { [void]$lines.Add([string] $t.SetupNeed64) }' 'if ($Decision.missingVulkanLoader) { [void]$lines.Add([string] $t.SetupNeed64) }'
    'the loader line under the 64-bit condition'=Edit-R4Plant 'if ($Decision.missingVulkanLoader) { [void]$lines.Add([string] $t.SetupNoLoader) }' 'if ($Decision.missing64BitHost) { [void]$lines.Add([string] $t.SetupNoLoader) }'
    'two lines reordered'=Edit-R4Plant "    [void]`$lines.Add('')`n    [void]`$lines.Add([string] `$t.SetupAfter)" "    [void]`$lines.Add([string] `$t.SetupAfter)`n    [void]`$lines.Add('')"
    'the offer message dropped'=Edit-R4Plant '{ [void]$lines.Add($offer.message) }' '{ $null = $offer.message }'
    'the advisory warnings dropped'=Edit-R4Plant 'foreach ($warning in @($Decision.advisoryWarnings)) { [void]$lines.Add([string] $warning) }' '$null = $Decision'
    'the missing files line unguarded'=Edit-R4Plant 'if (@($Decision.missingVcRuntimeFiles).Count -gt 0) {' 'if ($true) {'
}
foreach($k in $r4SeqPlants.Keys){ Check ($r4SeqPlants[$k] -cne $sdText -and (Get-R4SetupSeqFindings $r4SeqPlants[$k]).Count -ge 1) "mutation check: the setup check line sequence pin flags: $k" }
# ===== end PR 4b Task B2 (builder R) =====

# ===== PR 4b Task B2 (builder K): the four consent-family dialogs, src/FastLlm.UiFluentConsent.ps1 =====
# Every pin reads the dialog file (AST) and the classic functions (AST), and runs again on planted mutants, so each is proven on every platform.
$ckText=Get-OptionalText 'src/FastLlm.UiFluentConsent.ps1'
$ckShell=Get-OptionalText 'src/FastLlm.UiFluentShell.ps1'
Check ($ckText -ne '') 'src/FastLlm.UiFluentConsent.ps1 exists'
Check ($ckShell.Contains(". (Join-Path `$PSScriptRoot 'FastLlm.UiFluentDialogs.ps1')`r`n. (Join-Path `$PSScriptRoot 'FastLlm.UiFluentConsent.ps1')") -or $ckShell.Contains(". (Join-Path `$PSScriptRoot 'FastLlm.UiFluentDialogs.ps1')`n. (Join-Path `$PSScriptRoot 'FastLlm.UiFluentConsent.ps1')")) 'the shell dot-sources the consent dialogs right after the dialog host'
# The fluent function that answers each classic function.
$ckPairs=[ordered]@{
    ShowLicenseSettingConfirm='Show-FastLlmUiFluentLicenseSettingConfirm'
    ShowComponentConsent='Show-FastLlmUiFluentComponentConsent'
    ShowExactModelConsent='Show-FastLlmUiFluentExactModelConsent'
    ShowVcInstallReview='Show-FastLlmUiFluentVcInstallReview'
}
$ckKeys='LicenseTitle,LicenseIntro,LicensePlain,LicenseLinkError,LinkErrorCaption,LicenseAccept,ConsentCancel,ComponentTitle,ComponentNameFmt,ComponentSource,ComponentRedirect,ComponentJoin,ComponentPlain,ComponentLinkError,ComponentInstall,ModelTitle,ModelAccept,VcTitle,VcInstall,VcLater'
# Replaces From with To once, inside one function of the text (the key targets of three dialogs share one spelling).
function Edit-CkFn([string]$Text,[string]$FnName,[string]$From,[string]$To){
    $fn=Get-DlgFn $Text $FnName
    if($null -eq $fn){throw "FAIL: consent plant function missing: $FnName"}
    $body=$fn.Extent.Text
    $i=$body.IndexOf($From,[StringComparison]::Ordinal)
    if($i -lt 0){throw "FAIL: consent plant anchor missing in ${FnName}: $From"}
    $new=$body.Substring(0,$i)+$To+$body.Substring($i+$From.Length)
    return $Text.Substring(0,$fn.Extent.StartOffset)+$new+$Text.Substring($fn.Extent.EndOffset)
}
function Edit-CkFnLast([string]$Text,[string]$FnName,[string]$From,[string]$To){
    $fn=Get-DlgFn $Text $FnName
    if($null -eq $fn){throw "FAIL: consent plant function missing: $FnName"}
    $body=$fn.Extent.Text
    $i=$body.LastIndexOf($From,[StringComparison]::Ordinal)
    if($i -lt 0){throw "FAIL: consent plant anchor missing in ${FnName}: $From"}
    return $Text.Substring(0,$fn.Extent.StartOffset)+$body.Substring(0,$i)+$To+$body.Substring($i+$From.Length)+$Text.Substring($fn.Extent.EndOffset)
}
function Get-CkTable([string]$Text){
    $a=ConvertTo-PinAst $Text
    $asg=@($a.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$script:FastLlmUiFluentConsentText'},$true))
    if($asg.Count -ne 1){return $null}
    return (& ([scriptblock]::Create($asg[0].Right.Extent.Text)))
}
# --- 1. The text table: a classic literal each (the one rule: a WinForms && is shown as &), merged once into the shared table, no literal left in a function ---
# The frozen consent facts, generated from the classic functions and written out as literals: the 20 texts (a WinForms && is one & here), the keys each fluent function
# may read (the texts that are literals of its own classic function), and per classic function the parameter names, the AcceptButton and CancelButton captions, the caption of
# the button that answers OK, and the number of RevealUiForAction calls. The checks against the classic functions are in the 5b-delete blocks below.
$ckFrozen=[ordered]@{
    LicenseTitle='Install engine components automatically'
    LicenseIntro='With this on, FastLLM installs engine components without asking again, and counts that as accepting the licenses below. Open each link and read it first. You can turn this off at any time.'
    LicensePlain='{0} (this link cannot be opened from here)'
    LicenseLinkError='Unable to open the license page. Check your default browser. Nothing was changed.'
    LinkErrorCaption='Open license page'
    LicenseAccept='I accept these licenses'
    ConsentCancel='Cancel'
    ComponentTitle='Install engine components'
    ComponentNameFmt='{0} ({1}) - {2}'
    ComponentSource='Source: '
    ComponentRedirect='; the download may be redirected via '
    ComponentJoin=', '
    ComponentPlain='{0} (this link cannot be opened from here, so this component cannot be accepted)'
    ComponentLinkError='Unable to open the license page. Check your default browser. Nothing was downloaded.'
    ComponentInstall='Install'
    ModelTitle='Review exact model license and artifact'
    ModelAccept='Accept license & download'
    VcTitle='Review Microsoft VC++ package and installation'
    VcInstall='Install Microsoft runtime'
    VcLater='Do later'
}
$ckOwnKeys=@{
    'Show-FastLlmUiFluentLicenseSettingConfirm'=@('LicenseTitle','LicenseIntro','LicensePlain','LicenseLinkError','LinkErrorCaption','LicenseAccept','ConsentCancel')
    'Show-FastLlmUiFluentComponentConsent'=@('LinkErrorCaption','ConsentCancel','ComponentTitle','ComponentNameFmt','ComponentSource','ComponentRedirect','ComponentJoin','ComponentPlain','ComponentLinkError','ComponentInstall')
    'Show-FastLlmUiFluentExactModelConsent'=@('ConsentCancel','ModelTitle','ModelAccept')
    'Show-FastLlmUiFluentVcInstallReview'=@('ConsentCancel','VcTitle','VcInstall','VcLater')
    'New-FastLlmUiFluentConsentLink'=@('LicenseTitle','LicenseIntro','LicensePlain','LicenseLinkError','LinkErrorCaption','LicenseAccept','ConsentCancel','ComponentTitle','ComponentNameFmt','ComponentSource','ComponentRedirect','ComponentJoin','ComponentPlain','ComponentLinkError','ComponentInstall')
}
$ckClassicFrozen=[ordered]@{
    ShowLicenseSettingConfirm=@{Params='Disclosure';Accept='Cancel';Cancel='Cancel';Ok='I accept these licenses';Reveal=0}
    ShowComponentConsent=@{Params='Row,ConsentRows,Chosen';Accept='Cancel';Cancel='Cancel';Ok='Install';Reveal=1}
    ShowExactModelConsent=@{Params='Plan';Accept='Cancel';Cancel='Cancel';Ok='Accept license & download';Reveal=1}
    ShowVcInstallReview=@{Params='Receipt,Candidate';Accept='Do later';Cancel='Do later';Ok='Install Microsoft runtime';Reveal=1}
}
$ckComponentKeysFrozen='confirmed,ticked'
# 5b-delete-begin
function Get-CkClassicLiterals($Ast){
    $const=New-Object System.Collections.ArrayList; $expand=New-Object System.Collections.ArrayList
    foreach($fnName in $ckPairs.Keys){
        foreach($fnAst in (Get-AstFunction $Ast $fnName)){
            foreach($k in @($fnAst.FindAll({param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst]},$true))){ [void]$const.Add([string]$k.Value) }
            foreach($k in @($fnAst.FindAll({param($n) $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]},$true))){ [void]$expand.Add([string]$k.Value) }
        }
    }
    return @{Const=$const.ToArray();Expand=$expand.ToArray()}
}
function Get-CkClassicLiteralsOf($Ast,[string[]]$FnNames){
    $const=New-Object System.Collections.ArrayList; $expand=New-Object System.Collections.ArrayList
    foreach($fnName in $FnNames){ foreach($fnAst in (Get-AstFunction $Ast $fnName)){
        foreach($k in @($fnAst.FindAll({param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst]},$true))){ [void]$const.Add([string]$k.Value) }
        foreach($k in @($fnAst.FindAll({param($n) $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]},$true))){ [void]$expand.Add([string]$k.Value) }
    } }
    return @{Const=$const.ToArray();Expand=$expand.ToArray()}
}
function Get-CkDriftProblems($Table,$Classic){
    $p=New-Object System.Collections.ArrayList
    if($null -eq $Table){[void]$p.Add('the consent text table is not assigned exactly once');return ,$p.ToArray()}
    $mapped=@($Classic.Const|ForEach-Object{$_.Replace('&&','&')})
    foreach($key in @($Table.Keys)){
        $v=[string]$Table[$key]
        if($v.Contains('&&')){[void]$p.Add("table value $key keeps the WinForms && escape (shown as &)");continue}
        $isExpandPrefix=@($Classic.Expand|Where-Object{$_.StartsWith($v+'$(',[StringComparison]::Ordinal)}).Count -gt 0
        if($mapped -cnotcontains $v -and -not $isExpandPrefix){[void]$p.Add("table value $key is not a classic literal (with && shown as &) of the four consent functions")}
    }
    return ,$p.ToArray()
}
# 5b-delete-end
$ckTable=Get-CkTable $ckText
Check ($null -ne $ckTable -and (@($ckTable.Keys) -join ',') -ceq $ckKeys) 'the consent text table has the 20 planned keys, in order'
Check ($ckFrozen.Count -eq 20 -and (@($ckFrozen.Keys) -join ',') -ceq $ckKeys) 'the frozen consent table holds the 20 planned keys, in order'
Check ((Get-FrozenTableProblems $ckTable $ckFrozen).Count -eq 0) 'the consent text table equals its frozen literal (20 keys, every value, a WinForms && shown as one &)'
$ckMutValue=Copy-Table $ckTable; $ckMutValue['VcLater']='Later'
$ckMutAmp=Copy-Table $ckTable; $ckMutAmp['ModelAccept']='Accept license && download'
$ckMutKey=Copy-Table $ckTable; $ckMutKey['Extra']='A new caption'
Check ((Get-FrozenTableProblems $ckMutValue $ckFrozen).Count -ge 1) 'mutation check: a changed consent text fails the frozen literal'
Check ((Get-FrozenTableProblems $ckMutAmp $ckFrozen).Count -ge 1) 'mutation check: a consent caption that keeps the WinForms && fails the frozen literal'
Check ((Get-FrozenTableProblems $ckMutKey $ckFrozen).Count -ge 1) 'mutation check: a new consent text key fails the frozen literal'
Check ((Get-FrozenTableProblems (Copy-Table $ckTable) $ckFrozen).Count -eq 0) 'control: an unchanged copy of the consent table passes the frozen literal'
$ckAmpFrozen=@($ckFrozen.Keys|Where-Object{([string]$ckFrozen[$_]).Contains('&')})
Check ($ckAmpFrozen.Count -eq 1 -and $ckAmpFrozen[0] -ceq 'ModelAccept' -and -not ([string]$ckTable['ModelAccept']).Contains('&&') -and ([string]$ckTable['ModelAccept']) -ceq 'Accept license & download') 'the && rule: the one consent caption with an ampersand is shown with a single & in the table'
# 5b-delete-begin
$ckClassic=Get-CkClassicLiterals $classicAst
$ckDrift=Get-CkDriftProblems $ckTable $ckClassic
foreach($x in $ckDrift){Write-Host "FINDING: $x"}
Check ($ckDrift.Count -eq 0 -and $ckClassic.Const.Count -gt 30) "every consent text value is a classic literal of the four consent functions ($($ckClassic.Const.Count) literals read)"
foreach($key in @($ckTable.Keys)){
    $mut=[ordered]@{}; foreach($k2 in @($ckTable.Keys)){$mut[$k2]=[string]$ckTable[$k2]}
    $mut[$key]=[string]$ckTable[$key]+'.'
    Check ((Get-CkDriftProblems $mut $ckClassic).Count -ge 1) "mutation check: a changed $key literal fails the consent text drift pin"
}
# The && rule: exactly one classic caption has the escape, its table value shows one &, and no classic caption has a lone & (which would be a mnemonic).
$ckFrozenDrift=Get-CkDriftProblems $ckFrozen $ckClassic
foreach($x in $ckFrozenDrift){Write-Host "FINDING: $x"}
Check ($ckFrozenDrift.Count -eq 0 -and $ckClassic.Const.Count -gt 30) 'the frozen consent literal equals the classic texts of the four consent functions (every value is a classic literal, a WinForms && shown as &)'
$ckOwnClassic=@{}
foreach($ownName in @($ckOwnKeys.Keys)){
    $ownFns=@(if($ownName -ceq 'New-FastLlmUiFluentConsentLink'){'ShowLicenseSettingConfirm','ShowComponentConsent'}else{@($ckPairs.Keys|Where-Object{$ckPairs[$_] -ceq $ownName})})
    $oneLits=Get-CkClassicLiteralsOf $classicAst $ownFns
    $ownClassic=@($ckFrozen.Keys|Where-Object{(Get-CkDriftProblems ([ordered]@{$_=[string]$ckFrozen[$_]}) $oneLits).Count -eq 0})
    Check ($ownClassic.Count -gt 0 -and ($ownClassic -join ',') -ceq (@($ckOwnKeys[$ownName]) -join ',')) "the frozen keys that $ownName may read equal the texts that are literals of its own classic function"
}
$ckAmp=@($ckClassic.Const|Where-Object{$_.Contains('&')})
Check ($ckAmp.Count -eq 1 -and $ckAmp[0] -ceq 'Accept license && download' -and ([string]$ckTable['ModelAccept']) -ceq 'Accept license & download') 'the && rule: the one classic caption with the WinForms escape is shown with a single & in the table'
$ckAmpMut=[ordered]@{}; foreach($k2 in @($ckTable.Keys)){$ckAmpMut[$k2]=[string]$ckTable[$k2]}
$ckAmpMut['ModelAccept']='Accept license && download'
Check ((Get-CkDriftProblems $ckAmpMut $ckClassic).Count -ge 1) 'mutation check: a table caption that keeps && fails the && rule'
$ckAmpMut['ModelAccept']='Accept license and download'
Check ((Get-CkDriftProblems $ckAmpMut $ckClassic).Count -ge 1) 'mutation check: a table caption that drops the & fails the && rule'
# 5b-delete-end
function Get-CkTextFindings([string]$Text){
    $f=New-Object System.Collections.ArrayList
    $a=ConvertTo-PinAst $Text
    $merge=@($a.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$script:FastLlmUiFluentDialogText[$consentKey]' -and $n.Right.Extent.Text -ceq '$script:FastLlmUiFluentConsentText[$consentKey]'},$true))
    if($merge.Count -ne 1){[void]$f.Add('the consent table is not merged into $script:FastLlmUiFluentDialogText exactly once')}
    foreach($name in @($ckPairs.Values)+'New-FastLlmUiFluentConsentLink'){
        $fn=Get-DlgFn $Text $name
        if($null -eq $fn){[void]$f.Add("$name is not defined once");continue}
        foreach($k in @($fn.FindAll({param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]},$true))){
            if(([string]$k.Value).Contains(' ')){[void]$f.Add("$name has the literal '$($k.Value)' (every word lives in the text table)")}
        }
    }
    if($Text -cmatch '\bWidth\s*=\s*"|\bWidth="|IsDefault|IsCancel'){[void]$f.Add('the consent file sets Width= markup, IsDefault or IsCancel')}
    return ,$f.ToArray()
}
# Every text a fluent function reads must be a literal of its OWN classic function (a swap between two dialogs keeps every value a classic literal).
function Get-CkUsageFindings([string]$Text,$Table){
    $f=New-Object System.Collections.ArrayList
    $own=@{}
    foreach($c in $ckPairs.Keys){ $own[$ckPairs[$c]]=@($c) }
    $own['New-FastLlmUiFluentConsentLink']=@('ShowLicenseSettingConfirm','ShowComponentConsent')
    foreach($name in @($own.Keys)){
        $fn=Get-DlgFn $Text $name
        if($null -eq $fn){[void]$f.Add("$name is not defined once");continue}
        $used=@($fn.FindAll({param($n) $n -is [System.Management.Automation.Language.MemberExpressionAst] -and $n.Expression.Extent.Text -ceq '$t' -and $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]},$true))
        foreach($u in $used){
            $key=[string]$u.Member.Value
            if(-not $Table.Contains($key)){[void]$f.Add("$name reads `$t.$key, which is not a consent text key");continue}
            if(@($ckOwnKeys[$name]) -cnotcontains $key){[void]$f.Add("$name reads `$t.$key, which is not a literal of its classic function")}
        }
    }
    return ,$f.ToArray()
}
$ckUsage=Get-CkUsageFindings $ckText $ckTable
foreach($x in $ckUsage){Write-Host "FINDING: $x"}
Check ($ckUsage.Count -eq 0) 'each fluent consent function (and the link helper) reads only texts that are literals of its own classic function'
$ckTextReal=Get-CkTextFindings $ckText
foreach($x in $ckTextReal){Write-Host "FINDING: $x"}
Check ($ckTextReal.Count -eq 0) 'the consent table is merged once into the shared dialog table and no function carries a literal word'
$ckDlgTable=$null
$ckDlgAsg=@((ConvertTo-PinAst $sdText).FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$script:FastLlmUiFluentDialogText'},$true))
if($ckDlgAsg.Count -eq 1){$ckDlgTable=& ([scriptblock]::Create($ckDlgAsg[0].Right.Extent.Text))}
Check ($null -ne $ckDlgTable -and @($ckDlgTable.Keys|Where-Object{$ckTable.Contains($_)}).Count -eq 0) 'no consent text key collides with a key of the dialog host table'
# --- 2. The parameters are the classic ones (the shell's dispatch passes them by name) ---
function Get-CkParamNames($FnAst){
    if($null -ne $FnAst.Parameters){return (@($FnAst.Parameters|ForEach-Object{[string]$_.Name.VariablePath.UserPath}) -join ',')}
    if($null -ne $FnAst.Body.ParamBlock){return (@($FnAst.Body.ParamBlock.Parameters|ForEach-Object{[string]$_.Name.VariablePath.UserPath}) -join ',')}
    return ''
}
function Get-CkParamFindings([string]$Text){
    $f=New-Object System.Collections.ArrayList
    foreach($c in $ckPairs.Keys){
        $fl=Get-DlgFn $Text $ckPairs[$c]
        if($null -eq $fl){[void]$f.Add("$($ckPairs[$c]) is not defined once");continue}
        if([string]$ckClassicFrozen[$c].Params -cne (Get-CkParamNames $fl)){[void]$f.Add("$($ckPairs[$c]) takes ($(Get-CkParamNames $fl)), classic $c takes ($($ckClassicFrozen[$c].Params))")}
    }
    return ,$f.ToArray()
}
$ckParam=Get-CkParamFindings $ckText
foreach($x in $ckParam){Write-Host "FINDING: $x"}
Check ($ckParam.Count -eq 0) 'each fluent consent function takes the parameters of its classic function'
Check ((Get-CkParamFindings (Edit-CkFn $ckText 'Show-FastLlmUiFluentExactModelConsent' 'param($Plan)' 'param($Model)')).Count -ge 1) 'mutation check: a renamed parameter fails the consent parameter pin'
# --- 3. Key targets: Enter and Escape are the classic AcceptButton and CancelButton, read from the classic AST ---
# The classic caption of the button the form assigns to AcceptButton / CancelButton, and of the one with DialogResult OK (the accept button).
# 5b-delete-begin
function Get-CkClassicTargets($Ast,[string]$Fn){
    $fnAst=(Get-AstFunction $Ast $Fn)[0]
    $assign={param($left) @($fnAst.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq $left},$true))}
    $caption={param($var) $t=@(& $assign ($var+'.Text')); if($t.Count -ne 1){return $null}; return ([string]$t[0].Right.Expression.Value).Replace('&&','&')}
    $r=@{}
    foreach($m in 'AcceptButton','CancelButton'){ $a=@(& $assign ('$dialog.'+$m)); if($a.Count -ne 1){return $null}; $r[$m]=& $caption $a[0].Right.Extent.Text }
    $ok=@($fnAst.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -cmatch '^\$\w+\.DialogResult$' -and $n.Right.Extent.Text -ceq '[Windows.Forms.DialogResult]::OK'},$true))
    if($ok.Count -ne 1){return $null}
    $r['Ok']=& $caption (($ok[0].Left.Extent.Text) -replace '\.DialogResult$','')
    return $r
}
# 5b-delete-end
# The same from the fluent function: the Enter and Escape ids of its New-FastLlmUiFluentDialog call and the id -> caption table of its $buttons, as captions.
function Get-CkFluentTargets([string]$Text,[string]$FnName,$Table){
    $fn=Get-DlgFn $Text $FnName
    if($null -eq $fn){return $null}
    $calls=@($fn.FindAll({param($n) Test-DlgCall $n 'New-FastLlmUiFluentDialog'},$true))
    if($calls.Count -ne 1){return $null}
    $bt=@($fn.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$buttons'},$true))
    if($bt.Count -ne 1){return $null}
    $h=$bt[0].Right.Find({param($n) $n -is [System.Management.Automation.Language.HashtableAst]},$true)
    if($null -eq $h){return $null}
    $cap=@{}
    foreach($kv in $h.KeyValuePairs){ $mm=[regex]::Match([string]$kv.Item2.Extent.Text,'^\[string\] \$t\.(\w+)$'); if(-not $mm.Success -or -not $Table.Contains($mm.Groups[1].Value)){return $null}; $cap[[string]$kv.Item1.Extent.Text]=[string]$Table[$mm.Groups[1].Value] }
    $idOf={param($p) $x=Get-DlgParamText $calls[0] $p; if($null -eq $x){return '<none>'}; return $x.Trim("'")}
    $enter=& $idOf 'Enter'; $esc=& $idOf 'Escape'
    # The accept answer: the id the [bool] return (or the component's confirmed) compares the dialog's answer with.
    $okId=$null
    $mm=[regex]::Match($fn.Extent.Text,"(?:return|\`$confirmed =) \[bool\] \(\`$answer -ceq '(\w+)'\)")
    if($mm.Success){$okId=$mm.Groups[1].Value}
    return @{Enter=$(if($cap.ContainsKey($enter)){$cap[$enter]}else{"<$enter>"});Escape=$(if($cap.ContainsKey($esc)){$cap[$esc]}else{"<$esc>"});Ok=$(if($null -ne $okId -and $cap.ContainsKey($okId)){$cap[$okId]}else{$null})}
}
function Get-CkTargetFindings([string]$Text,$Table){
    $f=New-Object System.Collections.ArrayList
    foreach($c in $ckPairs.Keys){
        $frozenT=$ckClassicFrozen[$c]
        $cl=[pscustomobject]@{AcceptButton=[string]$frozenT.Accept;CancelButton=[string]$frozenT.Cancel;Ok=[string]$frozenT.Ok}; $fl=Get-CkFluentTargets $Text $ckPairs[$c] $Table
        if($null -eq $cl -or $null -eq $fl){[void]$f.Add("${c}: the classic or the fluent targets could not be read");continue}
        if($fl.Enter -cne $cl.AcceptButton){[void]$f.Add("${c}: Enter answers '$($fl.Enter)', the classic AcceptButton is '$($cl.AcceptButton)'")}
        if($fl.Escape -cne $cl.CancelButton){[void]$f.Add("${c}: Escape answers '$($fl.Escape)', the classic CancelButton is '$($cl.CancelButton)'")}
        # A bool function (and the component object's confirmed) is true only for the classic DialogResult OK button.
        if($fl.Ok -cne $cl.Ok){[void]$f.Add("${c}: the result is true for '$($fl.Ok)', the classic OK button is '$($cl.Ok)'")}
    }
    return ,$f.ToArray()
}
# 5b-delete-begin
$ckClassicTargets=Get-CkClassicTargets $classicAst 'ShowVcInstallReview'
Check ($null -ne $ckClassicTargets -and $ckClassicTargets.AcceptButton -ceq 'Do later' -and $ckClassicTargets.CancelButton -ceq 'Do later' -and $ckClassicTargets.Ok -ceq 'Install Microsoft runtime') 'classic VC review: Enter and Escape are Do later; OK is Install Microsoft runtime'
foreach($c in 'ShowLicenseSettingConfirm','ShowComponentConsent','ShowExactModelConsent'){ $t0=Get-CkClassicTargets $classicAst $c; Check ($null -ne $t0 -and $t0.AcceptButton -ceq 'Cancel' -and $t0.CancelButton -ceq 'Cancel') "classic ${c}: Enter and Escape are Cancel" }
foreach($c in @($ckClassicFrozen.Keys)){
    $t0=Get-CkClassicTargets $classicAst $c; $fz=$ckClassicFrozen[$c]
    $cfn=Get-AstFunction $classicAst $c
    Check ($null -ne $t0 -and $cfn.Count -eq 1 -and $t0.AcceptButton -ceq $fz.Accept -and $t0.CancelButton -ceq $fz.Cancel -and $t0.Ok -ceq $fz.Ok -and (Get-CkParamNames $cfn[0]) -ceq $fz.Params -and @($cfn[0].FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -ceq 'RevealUiForAction'},$true)).Count -eq $fz.Reveal) "the frozen facts of ${c} (parameters, Enter, Escape, the OK button, the reveal count) equal the classic function"
}
$ckComponentClassicFn=Get-AstFunction $classicAst 'ShowComponentConsent'
$ckComponentClassicObj=@($ckComponentClassicFn[0].FindAll({param($n) $n -is [System.Management.Automation.Language.ConvertExpressionAst] -and $n.Type.TypeName.Name -ceq 'pscustomobject'},$true))
$ckComponentClassicHash=$ckComponentClassicObj[0].Child.Find({param($n) $n -is [System.Management.Automation.Language.HashtableAst]},$true)
Check ($ckComponentClassicFn.Count -eq 1 -and $ckComponentClassicObj.Count -eq 1 -and (@($ckComponentClassicHash.KeyValuePairs|ForEach-Object{[string]$_.Item1.Extent.Text}) -join ',') -ceq $ckComponentKeysFrozen) 'the frozen component result keys equal the classic ShowComponentConsent object'
# 5b-delete-end
$ckTarget=Get-CkTargetFindings $ckText $ckTable
foreach($x in $ckTarget){Write-Host "FINDING: $x"}
Check ($ckTarget.Count -eq 0) 'every consent dialog answers Enter and Escape with the classic AcceptButton and CancelButton, and is true only for the classic OK button'
$ckPlants=[ordered]@{
    'licence: Enter = accept'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentLicenseSettingConfirm' "-Enter 'Cancel'" "-Enter 'Accept'")
    'licence: Escape = accept'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentLicenseSettingConfirm' "-Escape 'Cancel'" "-Escape 'Accept'")
    'component: Enter = Install'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentComponentConsent' "-Enter 'Cancel'" "-Enter 'Install'")
    'component: Escape removed'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentComponentConsent' " -Escape 'Cancel'" '')
    'model: Enter = accept'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentExactModelConsent' "-Enter 'Cancel'" "-Enter 'Accept'")
    'model: Escape removed'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentExactModelConsent' " -Escape 'Cancel'" '')
    'VC: Enter = Install'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentVcInstallReview' "-Enter 'Later'" "-Enter 'Install'")
    'VC: Escape = Install'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentVcInstallReview' "-Escape 'Later'" "-Escape 'Install'")
    'licence: true for Cancel'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentLicenseSettingConfirm' "-ceq 'Accept'" "-ceq 'Cancel'")
    'model: true for Cancel'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentExactModelConsent' "-ceq 'Accept'" "-ceq 'Cancel'")
    'VC: true for Later'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentVcInstallReview' "-ceq 'Install'" "-ceq 'Later'")
    'VC: the buttons swapped'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentVcInstallReview' '@{ Install = [string] $t.VcInstall; Later = [string] $t.VcLater }' '@{ Install = [string] $t.VcLater; Later = [string] $t.VcInstall }')
}
foreach($k in $ckPlants.Keys){ Check ($ckPlants[$k] -cne $ckText -and (Get-CkTargetFindings $ckPlants[$k] $ckTable).Count -ge 1) "mutation check: the consent key-target pin flags: $k" }
# --- 4. The return contract: one [bool] for three dialogs; the component object has today's properties, in today's order ---
function Get-CkReturnFindings([string]$Text){
    $f=New-Object System.Collections.ArrayList
    foreach($name in 'Show-FastLlmUiFluentLicenseSettingConfirm','Show-FastLlmUiFluentExactModelConsent','Show-FastLlmUiFluentVcInstallReview'){
        $fn=Get-DlgFn $Text $name
        if($null -eq $fn){[void]$f.Add("$name is not defined once");continue}
        $shows=@($fn.FindAll({param($n) Test-DlgCall $n 'Show-FastLlmUiFluentDialog'},$true))
        if($shows.Count -ne 1 -or $shows[0].Parent.Parent -isnot [System.Management.Automation.Language.AssignmentStatementAst] -or $shows[0].Parent.Parent.Left.Extent.Text -cne '$answer'){[void]$f.Add("$name does not keep the dialog's answer (a leaked string would break its one-bool contract)")}
        # No bare expression at the top of the function (it would join the [bool] in the output): only the reveal, the void AutomationProperties setters, the tray call and the Loaded hook are bare.
        foreach($st in @($fn.Body.EndBlock.Statements)){
            if($st -is [System.Management.Automation.Language.PipelineAst] -and $st.Extent.Text -cnotmatch '^(RevealUiForAction|\[System\.Windows\.Automation\.AutomationProperties\]::Set(Name|LabeledBy)\(|SetTrayMenuAvailable \$false|\$dialog\[''Window''\]\.Add_Loaded\()'){[void]$f.Add("$name has a bare statement that would leak into its result: $($st.Extent.Text)")}
        }
        $ret=@($fn.FindAll({param($n) $n -is [System.Management.Automation.Language.ReturnStatementAst]},$true))
        if($ret.Count -ne 1 -or $ret[0].Extent.Text -cnotmatch "^return \[bool\] \(\`$answer -ceq '\w+'\)$"){[void]$f.Add("$name does not end in exactly one 'return [bool] (`$answer -ceq ...)'")}
    }
    $cc=Get-DlgFn $Text 'Show-FastLlmUiFluentComponentConsent'
    if($null -eq $cc){[void]$f.Add('the component consent is not defined once');return ,$f.ToArray()}
    $obj=@($cc.FindAll({param($n) $n -is [System.Management.Automation.Language.ConvertExpressionAst] -and $n.Type.TypeName.Name -ceq 'pscustomobject'},$true))
    if($obj.Count -ne 1){[void]$f.Add('the component result is not one [pscustomobject] literal');return ,$f.ToArray()}
    $keysOf={param($c) $h=$c.Child.Find({param($n) $n -is [System.Management.Automation.Language.HashtableAst]},$true); (@($h.KeyValuePairs|ForEach-Object{[string]$_.Item1.Extent.Text}) -join ',')}
    $fluentKeys=& $keysOf $obj[0]; $classicKeys=$ckComponentKeysFrozen
    if($fluentKeys -cne $classicKeys){[void]$f.Add("the component result has ($fluentKeys), today's object has ($classicKeys)")}
    $ret=@($cc.FindAll({param($n) $n -is [System.Management.Automation.Language.ReturnStatementAst]},$true))
    if($ret.Count -ne 1 -or $ret[0].Extent.Text -cne 'return [pscustomobject] @{ confirmed = $confirmed; ticked = $ticked }'){[void]$f.Add('the component consent does not return the object with confirmed and ticked as variables')}
    if(-not $cc.Extent.Text.Contains('$confirmed = [bool] ($answer -ceq ''Install'')') -or -not $cc.Extent.Text.Contains('$ticked = @($boxes | ForEach-Object { [bool] ($_.IsChecked -eq $true) })')){[void]$f.Add('confirmed is not the Install answer, or ticked is not the state of every box')}
    return ,$f.ToArray()
}
$ckRet=Get-CkReturnFindings $ckText
foreach($x in $ckRet){Write-Host "FINDING: $x"}
Check ($ckRet.Count -eq 0) 'the licence, model and VC dialogs return one [bool] each; the component dialog returns {confirmed, ticked} as today'
$ckRetPlants=[ordered]@{
    'the component result drops ticked'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentComponentConsent' 'return [pscustomobject] @{ confirmed = $confirmed; ticked = $ticked }' 'return [pscustomobject] @{ confirmed = $confirmed }')
    'the component result drops confirmed'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentComponentConsent' 'return [pscustomobject] @{ confirmed = $confirmed; ticked = $ticked }' 'return [pscustomobject] @{ ticked = $ticked }')
    'the component result renames ticked'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentComponentConsent' 'ticked = $ticked }' 'checked = $ticked }')
    'the component result swaps its order'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentComponentConsent' 'confirmed = $confirmed; ticked = $ticked' 'ticked = $ticked; confirmed = $confirmed')
    'the component confirmed ignores the answer'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentComponentConsent' "`$confirmed = [bool] (`$answer -ceq 'Install')" '$confirmed = $true')
    'the licence dialog leaks the answer string'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentLicenseSettingConfirm' 'try { $answer = Show-FastLlmUiFluentDialog' 'try { Show-FastLlmUiFluentDialog')
    'the model dialog returns the string'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentExactModelConsent' "return [bool] (`$answer -ceq 'Accept')" 'return $answer')
    'the VC dialog returns a second value'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentVcInstallReview' "return [bool] (`$answer -ceq 'Install')" "`$true`n    return [bool] (`$answer -ceq 'Install')")
}
foreach($k in $ckRetPlants.Keys){ Check ($ckRetPlants[$k] -cne $ckText -and (Get-CkReturnFindings $ckRetPlants[$k]).Count -ge 1) "mutation check: the consent return pin flags: $k" }
# --- 5. Lead condition 2: Install is enabled only when every box is ticked; the same boxes and the same condition as the classic dialog ---
# The classic facts, frozen: a box for each row with needsAccept, enabled unless the row is blocked; Install starts disabled; the enable rule is Test-FastLlmUiConsentComplete over
# the box count and the state of every box. The check against the classic ShowComponentConsent and UpdateConsentInstallState is below (deleted with them at the flip).
$ckInstallFrozen=@{Boxes='$consentRow.needsAccept';BoxEnabled='(-not $consentRow.blocked)';RowCount='$boxes.Count';Ticked='$ticked'}
# Classic: a box for each row with needsAccept, enabled unless the row is blocked; Install starts disabled and UpdateConsentInstallState sets it from
# Test-FastLlmUiConsentComplete over the row count and the state of every box. The fluent function must read the same.
function Get-CkInstallFindings([string]$Text){
    $f=New-Object System.Collections.ArrayList
    $fn=Get-DlgFn $Text 'Show-FastLlmUiFluentComponentConsent'
    if($null -eq $fn){[void]$f.Add('the component consent is not defined once');return ,$f.ToArray()}
    # which rows have a box: the if around the CheckBox
    $ifOf={param($ast,$ctor) @($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item2.Extent.Text.Contains($ctor)},$true))}
    $fi=@(& $ifOf $fn 'New-Object System.Windows.Controls.CheckBox')
    if($fi.Count -ne 1 -or $fi[0].Clauses[0].Item1.Extent.Text -cne $ckInstallFrozen.Boxes){[void]$f.Add('the boxes are not the classic ones (a box for each row with needsAccept)')}
    $fb=@($fn.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$box.IsEnabled'},$true))
    if($fb.Count -ne 1 -or $fb[0].Right.Extent.Text -cne $ckInstallFrozen.BoxEnabled){[void]$f.Add('a box is not enabled by the classic rule (a blocked row cannot be ticked)')}
    # Every box joins the list unconditionally (a guarded Add would leave a blocked row out of the enable rule: Install could enable with a component unaccepted)
    if($fi.Count -eq 1){ $adds=@($fi[0].Clauses[0].Item2.Statements|Where-Object{$_.Extent.Text -ceq '$boxes.Add($box)'}); if($adds.Count -ne 1 -or @($fn.FindAll({param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression.Extent.Text -ceq '$boxes' -and [string]$n.Member.Value -ceq 'Add'},$true)).Count -ne 1){[void]$f.Add('a box is not added to the list unconditionally, directly in the needsAccept block (exactly once)')} }
    # Install starts disabled
    $fa=@($fn.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$install.IsEnabled' -and $n.Right.Extent.Text -ceq '$false'},$true))
    if($fa.Count -ne 1){[void]$f.Add('Install does not start disabled (as the classic one)')}
    # the enable rule: the same function over the same row count and the state of every box
    $classicRow=[string]$ckInstallFrozen.RowCount; $classicTicked=[string]$ckInstallFrozen.Ticked
    $fu=@($fn.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$update'},$true))
    if($fu.Count -ne 1){[void]$f.Add('the fluent dialog has no $update block')}
    else{
        $ut=$fu[0].Right.Extent.Text
        $uc=@($fu[0].Right.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand -and $n.CommandElements[0].Extent.Text -ceq '$complete'},$true))
        if($uc.Count -ne 1 -or (Get-DlgParamText $uc[0] 'RowCount') -cne $classicRow -or (Get-DlgParamText $uc[0] 'Ticked') -cne $classicTicked){[void]$f.Add('the enable rule is not Test-FastLlmUiConsentComplete over the box count and every box state')}
        # The block is exactly two statements: the state of every box, then Install from the rule over it (no box skipped, no other source).
        $sb=$fu[0].Right.Find({param($n) $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst]},$true)
        $stm=@(); if($null -ne $sb){$stm=@($sb.ScriptBlock.EndBlock.Statements|ForEach-Object{[string]$_.Extent.Text})}
        if($stm.Count -ne 2 -or $stm[0] -cne '$ticked = @($boxes | ForEach-Object { [bool] ($_.IsChecked -eq $true) })' -or $stm[1] -cne '$install.IsEnabled = [bool] (& $complete -RowCount $boxes.Count -Ticked $ticked)'){[void]$f.Add('the enable block is not exactly: read every box, then Install.IsEnabled from the rule')}
        if([regex]::Matches($fn.Extent.Text,[regex]::Escape('@($boxes | ForEach-Object { [bool] ($_.IsChecked -eq $true) })')).Count -ne 2){[void]$f.Add('the state of every box is not read the same way for the enable rule and for the result')}
    }
    if($fn.Extent.Text -cnotmatch '\$complete = \$\{function:Test-FastLlmUiConsentComplete\}'){[void]$f.Add('the rule is not the function Test-FastLlmUiConsentComplete (captured by ${function:...})')}
    # every box (checked or cleared) re-evaluates it
    if(@($fn.FindAll({param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] -and $n.Condition.Extent.Text -ceq '$boxes' -and $n.Body.Extent.Text -ceq '{ $box.Add_Checked($update); $box.Add_Unchecked($update) }'},$true)).Count -ne 1){[void]$f.Add('every box does not re-evaluate Install when it is checked or cleared')}
    return ,$f.ToArray()
}
# 5b-delete-begin
$ckClInstFn=Get-AstFunction $classicAst 'ShowComponentConsent'; $ckClUpdFn=Get-AstFunction $classicAst 'UpdateConsentInstallState'
$ckClBoxIf=@($ckClInstFn[0].FindAll({param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item2.Extent.Text.Contains('New-Object Windows.Forms.CheckBox')},$true))
$ckClBoxEn=@($ckClInstFn[0].FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$box.Enabled'},$true))
$ckClInstOff=@($ckClInstFn[0].FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$install.Enabled' -and $n.Right.Extent.Text -ceq '$false'},$true))
$ckClRule=@($ckClUpdFn[0].FindAll({param($n) Test-DlgCall $n 'Test-FastLlmUiConsentComplete'},$true))
Check ($ckClInstFn.Count -eq 1 -and $ckClUpdFn.Count -eq 1 -and $ckClBoxIf.Count -eq 1 -and $ckClBoxEn.Count -eq 1 -and $ckClInstOff.Count -eq 1 -and $ckClRule.Count -eq 1) 'the classic ShowComponentConsent and UpdateConsentInstallState hold the one box test, the one box enable, the one Install-off and the one enable rule'
Check ($ckClBoxIf[0].Clauses[0].Item1.Extent.Text -ceq $ckInstallFrozen.Boxes -and $ckClBoxEn[0].Right.Extent.Text -ceq $ckInstallFrozen.BoxEnabled -and ((Get-DlgParamText $ckClRule[0] 'RowCount') -replace '\$view\.boxes','$boxes') -ceq $ckInstallFrozen.RowCount -and (Get-DlgParamText $ckClRule[0] 'Ticked') -ceq $ckInstallFrozen.Ticked) 'the frozen Install enablement facts equal the classic dialog (the boxes, the box enable rule, the row count and the ticked state)'
# 5b-delete-end
$ckInst=Get-CkInstallFindings $ckText
foreach($x in $ckInst){Write-Host "FINDING: $x"}
Check ($ckInst.Count -eq 0) 'component consent: Install starts disabled and is enabled only when every box is ticked, the same boxes and condition as the classic dialog'
$ckInstPlants=[ordered]@{
    'one box is not required (the first is skipped, the count one short)'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentComponentConsent' '$update = {' "`$update = {`n        `$boxes = @(`$boxes | Select-Object -Skip 1)")
    'the box count one short'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentComponentConsent' '-RowCount $boxes.Count' '-RowCount ($boxes.Count - 1)')
    'an indeterminate box counts as ticked'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentComponentConsent' '[bool] ($_.IsChecked -eq $true)' '[bool] ($_.IsChecked -ne $false)')
    'Install starts enabled'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentComponentConsent' '$install.IsEnabled = $false' '$install.IsEnabled = $true')
    'Install is not re-evaluated when a box is cleared'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentComponentConsent' '; $box.Add_Unchecked($update)' '')
    'Install is not re-evaluated when a box is checked'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentComponentConsent' '$box.Add_Checked($update); ' '')
    'a blocked row can be ticked'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentComponentConsent' '$box.IsEnabled = (-not $consentRow.blocked)' '$box.IsEnabled = $true')
    'a blocked row is left out of the list (a guarded Add)'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentComponentConsent' '$boxes.Add($box)' 'if (-not $consentRow.blocked) { $boxes.Add($box) }')
    'a box is added twice'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentComponentConsent' '$boxes.Add($box)' '$boxes.Add($box); $boxes.Add($box)')
    'a row without needsAccept gets a box'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentComponentConsent' 'if ($consentRow.needsAccept) {' 'if ($true) {')
    'the rule is a hand-written all-ticked test'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentComponentConsent' '$complete = ${function:Test-FastLlmUiConsentComplete}' '$complete = { param($RowCount, $Ticked) $true }')
    'ticked is read after the dialog from the wrong source'=(Edit-CkFnLast $ckText 'Show-FastLlmUiFluentComponentConsent' '[bool] ($_.IsChecked -eq $true)' '$true')
}
foreach($k in $ckInstPlants.Keys){ Check ($ckInstPlants[$k] -cne $ckText -and (Get-CkInstallFindings $ckInstPlants[$k]).Count -ge 1) "mutation check: the consent Install enablement pin flags: $k" }
# --- 5b. PR 4b review fix G1: the licence Accept button is enabled by the disclosure (classic: $accept.Enabled=[bool]$Disclosure.canAccept) ---
$ckAcceptFrozen='[bool]$Disclosure.canAccept'
function Get-CkAcceptFindings([string]$Text){
    $f=New-Object System.Collections.ArrayList
    $fn=Get-DlgFn $Text 'Show-FastLlmUiFluentLicenseSettingConfirm'
    if($null -eq $fn){[void]$f.Add('the licence confirm is not defined once');return ,$f.ToArray()}
    $fa=@($fn.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq "`$dialog['Buttons']['Accept'].IsEnabled"},$true))
    if($fa.Count -ne 1 -or ($fa[0].Right.Extent.Text -replace '\s','') -cne ($ckAcceptFrozen -replace '\s','')){[void]$f.Add('the licence Accept button is not enabled by the classic rule ([bool] $Disclosure.canAccept)')}
    return ,$f.ToArray()
}
# 5b-delete-begin
$ckClAccFn=Get-AstFunction $classicAst 'ShowLicenseSettingConfirm'
$ckClAcc=@($ckClAccFn[0].FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$accept.Enabled'},$true))
Check ($ckClAccFn.Count -eq 1 -and $ckClAcc.Count -eq 1 -and $ckClAcc[0].Right.Extent.Text -ceq $ckAcceptFrozen) 'the frozen licence Accept rule equals the classic ShowLicenseSettingConfirm statement ($accept.Enabled)'
# 5b-delete-end
$ckAcc=Get-CkAcceptFindings $ckText
foreach($x in $ckAcc){Write-Host "FINDING: $x"}
Check ($ckAcc.Count -eq 0) 'licence confirm: Accept is enabled by the disclosure (canAccept), as the classic dialog'
$ckAccPlants=[ordered]@{
    'Accept always enabled'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentLicenseSettingConfirm' '[bool] $Disclosure.canAccept' '$true')
    'Accept enabled by the opposite'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentLicenseSettingConfirm' '[bool] $Disclosure.canAccept' '(-not $Disclosure.canAccept)')
    'Accept enablement dropped'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentLicenseSettingConfirm' "`$dialog['Buttons']['Accept'].IsEnabled = [bool] `$Disclosure.canAccept" '$null = $Disclosure')
}
foreach($k in $ckAccPlants.Keys){ Check ($ckAccPlants[$k] -cne $ckText -and (Get-CkAcceptFindings $ckAccPlants[$k]).Count -ge 1) "mutation check: the licence Accept enablement pin flags: $k" }
# --- 6. Reveal and tray: as the classic functions (reveal where classic reveals; the tray menu off before the try and on in its finally) ---
function Get-CkFlowFindings([string]$Text){
    $f=New-Object System.Collections.ArrayList
    foreach($c in $ckPairs.Keys){
        $fn=Get-DlgFn $Text $ckPairs[$c]
        if($null -eq $fn){[void]$f.Add("$($ckPairs[$c]) is not defined once");continue}
        $isCall={param($n,$name) $n -is [System.Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -ceq $name}
        $cr=[int]$ckClassicFrozen[$c].Reveal; $fr=@($fn.FindAll({param($n) & $isCall $n 'RevealUiForAction'},$true)).Count
        if($cr -ne $fr){[void]$f.Add("$($ckPairs[$c]) calls RevealUiForAction $fr time(s), classic $c calls it $cr")}
        $trays=@($fn.FindAll({param($n) & $isCall $n 'SetTrayMenuAvailable'},$true))
        $off=@($trays|Where-Object{$_.Extent.Text -ceq 'SetTrayMenuAvailable $false'}); $on=@($trays|Where-Object{$_.Extent.Text -ceq 'SetTrayMenuAvailable $true'})
        $tries=@($fn.FindAll({param($n) $n -is [System.Management.Automation.Language.TryStatementAst]},$true))
        if($off.Count -ne 1 -or $on.Count -ne 1 -or $tries.Count -ne 1 -or $null -eq $tries[0].Finally){[void]$f.Add("$($ckPairs[$c]) does not call SetTrayMenuAvailable `$false once and `$true once around one try with a finally");continue}
        if($off[0].Extent.EndOffset -gt $tries[0].Extent.StartOffset){[void]$f.Add("$($ckPairs[$c]): the tray menu is not turned off before the try")}
        if($on[0].Extent.StartOffset -lt $tries[0].Finally.Extent.StartOffset -or $on[0].Extent.EndOffset -gt $tries[0].Finally.Extent.EndOffset){[void]$f.Add("$($ckPairs[$c]): the tray menu is not restored in the finally")}
        $show=@($fn.FindAll({param($n) & $isCall $n 'Show-FastLlmUiFluentDialog'},$true))
        if($show.Count -ne 1 -or $show[0].Extent.StartOffset -lt $tries[0].Body.Extent.StartOffset -or $show[0].Extent.EndOffset -gt $tries[0].Body.Extent.EndOffset){[void]$f.Add("$($ckPairs[$c]): the dialog is not shown inside the try")}
        $own=@($fn.FindAll({param($n) & $isCall $n 'New-FastLlmUiFluentDialog'},$true))
        if($own.Count -ne 1 -or (Get-DlgParamText $own[0] 'Owner') -cne '$script:form'){[void]$f.Add("$($ckPairs[$c]) does not own its dialog by the main window")}
    }
    return ,$f.ToArray()
}
$ckFlow=Get-CkFlowFindings $ckText
foreach($x in $ckFlow){Write-Host "FINDING: $x"}
Check ($ckFlow.Count -eq 0) 'the consent dialogs reveal the window where classic does, and turn the tray menu off before and on in a finally, owned by the main window'
$ckFlowPlants=[ordered]@{
    'model: no reveal'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentExactModelConsent' "    RevealUiForAction`n" '')
    'VC: no reveal'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentVcInstallReview' "    RevealUiForAction`n" '')
    'component: no reveal'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentComponentConsent' "    RevealUiForAction`n" '')
    'licence: a reveal the classic one does not have'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentLicenseSettingConfirm' '$t = $script:FastLlmUiFluentDialogText' "RevealUiForAction`n    `$t = `$script:FastLlmUiFluentDialogText")
    'licence: the tray menu is not restored in a finally'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentLicenseSettingConfirm' "    finally { SetTrayMenuAvailable `$true }`n" "    finally { }`n    SetTrayMenuAvailable `$true`n")
    'model: the tray menu stays on'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentExactModelConsent' "    SetTrayMenuAvailable `$false`n" '')
    'component: owned by nothing'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentComponentConsent' '-Escape ''Cancel'' -Owner $script:form' '-Escape ''Cancel'' -Owner $null')
}
foreach($k in $ckFlowPlants.Keys){ Check ($ckFlowPlants[$k] -cne $ckText -and (Get-CkFlowFindings $ckFlowPlants[$k]).Count -ge 1) "mutation check: the consent reveal and tray pin flags: $k" }
# --- 7. Links and accessibility: links open only through the safe-url check, the error box is owned by this dialog, every input and button is named ---
function Get-CkA11yFindings([string]$Text){
    $f=New-Object System.Collections.ArrayList
    $lk=Get-DlgFn $Text 'New-FastLlmUiFluentConsentLink'
    if($null -eq $lk){[void]$f.Add('the link helper is not defined once');return ,$f.ToArray()}
    $names=@($lk.FindAll({param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Static -and [string]$n.Member.Value -ceq 'SetName'},$true)).Count
    if($names -lt 1){[void]$f.Add('a link button is not named')}
    $catch=@($lk.FindAll({param($n) $n -is [System.Management.Automation.Language.CatchClauseAst]},$true))
    if($catch.Count -ne 1){[void]$f.Add('the link click does not have exactly one catch')}
    else{
        $mb=@($catch[0].Body.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand -and $n.CommandElements[0].Extent.Text -ceq '$messageBox'},$true))
        if($mb.Count -ne 1 -or (Get-DlgParamText $mb[0] 'Owner') -cne '$Context[''Dialog'']'){[void]$f.Add('the link-error box is not owned by the consent dialog ($Context[''Dialog''])')}
        if($mb.Count -eq 1 -and ((Get-DlgParamText $mb[0] 'Buttons') -cne "'OK'" -or (Get-DlgParamText $mb[0] 'Icon') -cne "'Warning'" -or (Get-DlgParamText $mb[0] 'Text') -cne '$ErrorText' -or (Get-DlgParamText $mb[0] 'Caption') -cne '$errorCaption')){[void]$f.Add('the link-error box is not an OK warning with the dialog text and the Open license page caption')}
    }
    if($lk.Extent.Text -cnotmatch '\$safeUrl = \$\{function:Get-FastLlmUiSafeLicenseUrl\}' -or $lk.Extent.Text -cnotmatch '\$target = & \$safeUrl -Url \(\[string\] \$sender\.Tag\)' -or $lk.Extent.Text -cnotmatch 'if \(\$target\) \{ Start-Process \$target \}'){[void]$f.Add('a link does not open only through Get-FastLlmUiSafeLicenseUrl')}
    if($lk.Extent.Text -cnotmatch 'if \(\$LicenseLink\.url\)'){[void]$f.Add('a licence without a url is not plain text')}
    foreach($name in 'Show-FastLlmUiFluentLicenseSettingConfirm','Show-FastLlmUiFluentComponentConsent'){
        $fn=Get-DlgFn $Text $name
        if($null -eq $fn){[void]$f.Add("$name is not defined once");continue}
        $set=@($fn.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$context[''Dialog'']' -and $n.Right.Extent.Text -ceq '$dialog'},$true))
        if($set.Count -ne 1){[void]$f.Add("$name does not hand the dialog to its link-error box")}
        $calls=@($fn.FindAll({param($n) Test-DlgCall $n 'New-FastLlmUiFluentConsentLink'},$true))
        if($calls.Count -ne 1 -or (Get-DlgParamText $calls[0] 'Context') -cne '$context'){[void]$f.Add("$name does not pass its context to its links")}
    }
    $cc=Get-DlgFn $Text 'Show-FastLlmUiFluentComponentConsent'
    if($null -ne $cc){
        # As the Settings check boxes: the box is named by its own caption, the same string it shows (no LabeledBy to another text).
        if(-not $cc.Extent.Text.Contains('$box.Content = ConvertTo-FastLlmUiAccessText -Text $acceptText -UseMnemonic $false') -or -not $cc.Extent.Text.Contains('[System.Windows.Automation.AutomationProperties]::SetName($box, $acceptText)')){[void]$f.Add('an accept check box is not named by the same string it shows')}
        if($cc.Extent.Text.Contains('SetLabeledBy')){[void]$f.Add('an accept check box is labelled by another text (its name is its own caption)')}
        if($cc.Extent.Text -cnotmatch "SetResourceReference\(\[System\.Windows\.FrameworkElement\]::StyleProperty, 'FastLlm\.CheckBoxStyle'\)"){[void]$f.Add('an accept check box does not use the 3c check box style (wrapping caption)')}
    }
    foreach($name in 'Show-FastLlmUiFluentExactModelConsent','Show-FastLlmUiFluentVcInstallReview'){
        $fn=Get-DlgFn $Text $name
        if($null -eq $fn){continue}
        if(-not $fn.Extent.Text.Contains('[System.Windows.Automation.AutomationProperties]::SetName($details,')){[void]$f.Add("$name does not name its read-only box")}
        if(@($fn.FindAll({param($n) Test-DlgCall $n 'New-FastLlmUiFluentDialogReadBox'},$true)).Count -ne 1){[void]$f.Add("$name does not use the read box")}
    }
    $mc=Get-DlgFn $Text 'Show-FastLlmUiFluentExactModelConsent'
    if($null -ne $mc -and ($mc.Extent.Text -cnotmatch '(?s)\$details\.SelectionStart = 0\s+\$details\.SelectionLength = 0\s+\$buttons' -or $mc.Extent.Text -cnotmatch 'Add_Loaded\(\{ \$details\.SelectionStart = 0; \$details\.SelectionLength = 0 \}')){[void]$f.Add('the model review caret is not reset to the start (before and when shown)')}
    return ,$f.ToArray()
}
$ckA11y=Get-CkA11yFindings $ckText
foreach($x in $ckA11y){Write-Host "FINDING: $x"}
Check ($ckA11y.Count -eq 0) 'consent links open only when safe, the link-error box is owned by its dialog, inputs and links are named, the model caret starts at the top'
$ckA11yPlants=[ordered]@{
    'the link error is owned by the main window'=$ckText.Replace('-Owner $Context[''Dialog'']','-Owner $script:form')
    'the link error is owned by nothing'=$ckText.Replace('-Owner $Context[''Dialog''] -Text $ErrorText','-Text $ErrorText')
    'the link error is not a warning'=$ckText.Replace("-Buttons 'OK' -Icon 'Warning'","-Buttons 'OK' -Icon 'None'")
    'a link opens the raw url'=$ckText.Replace('$target = & $safeUrl -Url ([string] $sender.Tag)','$target = [string] $sender.Tag')
    'a link is not named'=$ckText.Replace('[System.Windows.Automation.AutomationProperties]::SetName($link, $linkText)','')
    'the dialog is not handed to the licence box'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentLicenseSettingConfirm' '$context[''Dialog''] = $dialog' '')
    'the dialog is not handed to the component box'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentComponentConsent' '$context[''Dialog''] = $dialog' '')
    'a check box is labelled by the row name line'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentComponentConsent' '$box.Tag = [string] $consentRow.id' '[System.Windows.Automation.AutomationProperties]::SetLabeledBy($box, $nameLabel); $box.Tag = [string] $consentRow.id')
    'a check box loses its name'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentComponentConsent' '[System.Windows.Automation.AutomationProperties]::SetName($box, $acceptText)' '')
    'a check box is named by another string'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentComponentConsent' '[System.Windows.Automation.AutomationProperties]::SetName($box, $acceptText)' '[System.Windows.Automation.AutomationProperties]::SetName($box, [string] $consentRow.name)')
    'a check box loses the wrapping style'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentComponentConsent' "'FastLlm.CheckBoxStyle'" "'FastLlm.ButtonStyle'")
    'the model box is not named'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentExactModelConsent' '[System.Windows.Automation.AutomationProperties]::SetName($details, [string] $t.ModelTitle)' '')
    'the VC box is not named'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentVcInstallReview' '[System.Windows.Automation.AutomationProperties]::SetName($details, [string] $t.VcTitle)' '')
    'the model caret is left alone'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentExactModelConsent' '$details.SelectionLength = 0 }.GetNewClosure()' '}.GetNewClosure()')
    'a plain licence becomes a link'=$ckText.Replace('if ($LicenseLink.url) {','if ($true) {')
}
foreach($k in $ckA11yPlants.Keys){ Check ($ckA11yPlants[$k] -cne $ckText -and (Get-CkA11yFindings $ckA11yPlants[$k]).Count -ge 1) "mutation check: the consent link and accessibility pin flags: $k" }
$ckLitPlants=[ordered]@{
    'a literal word in a function'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentVcInstallReview' '[string] $t.VcLater }' "'Do later' }")
    'IsDefault set'=($ckText+"`n# `$b.IsDefault = `$true`n")
    'Width markup'=($ckText+"`n# <Grid Width=`"5`"/>`n")
    'a licence function reads the component link-error text'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentLicenseSettingConfirm' '$t.LicenseLinkError' '$t.ComponentLinkError')
    'a licence function reads the component plain text'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentLicenseSettingConfirm' '$t.LicensePlain' '$t.ComponentPlain')
    'the component dialog reads the licence title'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentComponentConsent' '$t.ComponentTitle' '$t.LicenseTitle')
    'the VC dialog reads the model title'=(Edit-CkFn $ckText 'Show-FastLlmUiFluentVcInstallReview' '$t.VcTitle' '$t.ModelTitle')
    'the table merge dropped'=$ckText.Replace('$script:FastLlmUiFluentDialogText[$consentKey] = $script:FastLlmUiFluentConsentText[$consentKey]','$null = 1')
}
foreach($k in $ckLitPlants.Keys){ Check ($ckLitPlants[$k] -cne $ckText -and ((Get-CkTextFindings $ckLitPlants[$k]).Count -ge 1 -or (Get-CkUsageFindings $ckLitPlants[$k] $ckTable).Count -ge 1)) "mutation check: the consent text pins flag: $k" }
# ===== end PR 4b Task B2 (builder K) =====


# ===== PR 5a (flip-ready) concept checks: keyboard reachability of the dialogs, the tray menu restored in a finally, GDI objects disposed in a finally =====
# The classic window's TabStop and Dispose-in-finally pins protect a concept each; these read the fluent source only (cross-platform).
# D1 (keyboard reachability): the dialog host markup cycles Tab and Ctrl+Tab inside the dialog, and no code of the dialog host or the consent file takes a button out of the
# tab order (the one IsTabStop in the host is the body scroller, which is a pane and not a control the user can act on).
$tabHostText=Get-OptionalText 'src/FastLlm.UiFluentDialogs.ps1'
$tabConsentText=Get-OptionalText 'src/FastLlm.UiFluentConsent.ps1'
function Get-DialogTabFindings([string]$HostText,[string]$ConsentText){
    $f=New-Object System.Collections.ArrayList
    if(-not $HostText.Contains('KeyboardNavigation.TabNavigation="Cycle"')){[void]$f.Add('the dialog host markup does not cycle Tab (KeyboardNavigation.TabNavigation="Cycle")')}
    if(-not $HostText.Contains('KeyboardNavigation.ControlTabNavigation="Cycle"')){[void]$f.Add('the dialog host markup does not cycle Ctrl+Tab (KeyboardNavigation.ControlTabNavigation="Cycle")')}
    foreach($pair in @(@('the dialog host',$HostText),@('the consent file',$ConsentText))){
        $a=[System.Management.Automation.Language.Parser]::ParseInput([string]$pair[1],[ref]$null,[ref]$null)
        $sets=@($a.FindAll({param($n) ($n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -cmatch 'IsTabStop$') -or ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$n.Member.Extent.Text -ceq 'SetIsTabStop')},$true))
        if($sets.Count -gt 0){[void]$f.Add("$($pair[0]) takes a control out of the tab order in code: $($sets[0].Extent.Text)")}
    }
    # The only IsTabStop attribute of the host markup is the body scroller; a footer button never carries one, and the consent file has none.
    $attrs=@([regex]::Matches($HostText,'<(\w+)\b[^>]*\bIsTabStop="False"')|ForEach-Object{$_.Groups[1].Value})
    if(($attrs -join ',') -cne 'ScrollViewer'){[void]$f.Add("the dialog host markup has IsTabStop=False on [$($attrs -join ',')], expected only the ScrollViewer body")}
    if($ConsentText -cmatch 'IsTabStop'){[void]$f.Add('the consent file mentions IsTabStop')}
    return ,$f.ToArray()
}
$tabFindings=Get-DialogTabFindings $tabHostText $tabConsentText
foreach($x in $tabFindings){Write-Host "FINDING: $x"}
Check ($tabHostText -ne '' -and $tabConsentText -ne '' -and $tabFindings.Count -eq 0) 'the dialog host cycles Tab and Ctrl+Tab, and no dialog code takes a footer button out of the tab order (D4: TabStop)'
Check ((Get-DialogTabFindings $tabHostText.Replace('KeyboardNavigation.TabNavigation="Cycle"','KeyboardNavigation.TabNavigation="None"') $tabConsentText).Count -ge 1) 'mutation check: a dialog host that no longer cycles Tab is flagged'
Check ((Get-DialogTabFindings $tabHostText.Replace('KeyboardNavigation.ControlTabNavigation="Cycle"','KeyboardNavigation.ControlTabNavigation="Continue"') $tabConsentText).Count -ge 1) 'mutation check: a dialog host that no longer cycles Ctrl+Tab is flagged'
Check ((Get-DialogTabFindings $tabHostText ($tabConsentText+"`n    `$dialog['Buttons']['Accept'].IsTabStop = `$false`n")).Count -ge 1) 'mutation check: a consent footer button taken out of the tab order in code is flagged'
Check ((Get-DialogTabFindings ($tabHostText+"`n<Button x:Name=`"X`" IsTabStop=`"False`"/>`n") $tabConsentText).Count -ge 1) 'mutation check: a markup button with IsTabStop=False is flagged'
Check ((Get-DialogTabFindings $tabHostText $tabConsentText).Count -eq 0) 'control: the unmutated dialog host and consent file have no tab finding'

# D2 (the tray menu): every fluent dialog function that turns the tray menu off turns it on again in the finally of a try that shows the dialog, exactly once each.
$trayFiles=@($fluentSrcFiles|Sort-Object)
$trayExpected='Show-FastLlmUiFluentComponentConsent,Show-FastLlmUiFluentDriverGuidance,Show-FastLlmUiFluentExactModelConsent,Show-FastLlmUiFluentLicenseSettingConfirm,Show-FastLlmUiFluentRecipeChooser,Show-FastLlmUiFluentSavePrompt,Show-FastLlmUiFluentSetupAttention,Show-FastLlmUiFluentVcInstallReview'
function Get-TrayFinallyFindings([string[]]$Texts,[string]$Expected){
    $f=New-Object System.Collections.ArrayList
    $names=New-Object System.Collections.ArrayList
    foreach($tx in $Texts){
        $a=[System.Management.Automation.Language.Parser]::ParseInput($tx,[ref]$null,[ref]$null)
        $offs=@($a.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -ceq 'SetTrayMenuAvailable' -and $n.Extent.Text -ceq 'SetTrayMenuAvailable $false'},$true))
        foreach($off in $offs){
            $fn=$off.Parent; while($null -ne $fn -and $fn -isnot [System.Management.Automation.Language.FunctionDefinitionAst]){$fn=$fn.Parent}
            if($null -eq $fn){[void]$f.Add('a top-level SetTrayMenuAvailable $false');continue}
            if($names -ccontains $fn.Name){continue}
            [void]$names.Add($fn.Name)
            $ons=@($fn.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -ceq 'SetTrayMenuAvailable' -and $n.Extent.Text -ceq 'SetTrayMenuAvailable $true'},$true))
            $offsHere=@($fn.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -ceq 'SetTrayMenuAvailable' -and $n.Extent.Text -ceq 'SetTrayMenuAvailable $false'},$true))
            if($offsHere.Count -ne 1 -or $ons.Count -ne 1){[void]$f.Add("$($fn.Name) calls SetTrayMenuAvailable `$false $($offsHere.Count) time(s) and `$true $($ons.Count) time(s), expected once each");continue}
            $okTry=$false
            foreach($tr in @($fn.FindAll({param($n) $n -is [System.Management.Automation.Language.TryStatementAst] -and $null -ne $n.Finally},$true))){
                $inFinally=($ons[0].Extent.StartOffset -ge $tr.Finally.Extent.StartOffset -and $ons[0].Extent.EndOffset -le $tr.Finally.Extent.EndOffset)
                $shows=@($tr.Body.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -ceq 'Show-FastLlmUiFluentDialog'},$true))
                if($inFinally -and $shows.Count -ge 1 -and $offsHere[0].Extent.EndOffset -le $tr.Extent.StartOffset){$okTry=$true}
            }
            if(-not $okTry){[void]$f.Add("$($fn.Name) does not restore the tray menu in the finally of the try that shows the dialog (after turning it off before the try)")}
        }
    }
    if((@($names|Sort-Object) -join ',') -cne $Expected){[void]$f.Add("the functions that turn the tray menu off are [$((@($names|Sort-Object)) -join ',')], expected [$Expected]")}
    return ,$f.ToArray()
}
$trayTexts=@($trayFiles|ForEach-Object{[IO.File]::ReadAllText($_)})
$trayFindings=Get-TrayFinallyFindings $trayTexts $trayExpected
foreach($x in $trayFindings){Write-Host "FINDING: $x"}
Check ($trayFindings.Count -eq 0) 'each of the eight fluent dialog functions that turn the tray menu off restores it in the finally of the try that shows the dialog (D4: cleanup in a finally)'
$trayConsentIdx=[Array]::IndexOf($trayFiles,@($trayFiles|Where-Object{$_ -match 'UiFluentConsent\.ps1$'})[0])
$trayDialogsIdx=[Array]::IndexOf($trayFiles,@($trayFiles|Where-Object{$_ -match 'UiFluentDialogs\.ps1$'})[0])
$trayPlantA=@($trayTexts); $trayPlantA[$trayConsentIdx]=$trayTexts[$trayConsentIdx].Replace("    finally { SetTrayMenuAvailable `$true }`n","    finally { }`n    SetTrayMenuAvailable `$true`n")
$trayPlantB=@($trayTexts); $trayPlantB[$trayDialogsIdx]=$trayTexts[$trayDialogsIdx].Replace('try { $answer = Show-FastLlmUiFluentDialog -Dialog $dialog } finally { SetTrayMenuAvailable $true }','try { $answer = Show-FastLlmUiFluentDialog -Dialog $dialog } finally { }; SetTrayMenuAvailable $true')
$trayPlantC=@($trayTexts); $trayPlantC[$trayDialogsIdx]=$trayTexts[$trayDialogsIdx]+"`nfunction Show-FastLlmUiFluentPlant { SetTrayMenuAvailable `$false; try { `$null = Show-FastLlmUiFluentDialog -Dialog `$d } finally { SetTrayMenuAvailable `$true } }`n"
Check ($trayPlantA[$trayConsentIdx] -cne $trayTexts[$trayConsentIdx] -and (Get-TrayFinallyFindings $trayPlantA $trayExpected).Count -ge 1) 'mutation check: a consent dialog that restores the tray menu after the try (not in the finally) is flagged'
Check ($trayPlantB[$trayDialogsIdx] -cne $trayTexts[$trayDialogsIdx] -and (Get-TrayFinallyFindings $trayPlantB $trayExpected).Count -ge 1) 'mutation check: the setup check that restores the tray menu after the try is flagged'
Check ((Get-TrayFinallyFindings $trayPlantC $trayExpected).Count -ge 1) 'mutation check: a new dialog function that turns the tray menu off is flagged until it is listed'
Check ((Get-TrayFinallyFindings $trayTexts $trayExpected).Count -eq 0) 'control: the unmutated fluent sources have no tray finding'

# D2 (the tray icon): every GDI object of the drawn tray icon is disposed in a finally; the one other Dispose is the cache release (the icon's owner letting it go).
$icoText=Get-OptionalText 'src/FastLlm.UiFluentIcon.ps1'
function Get-IconDisposeFindings([string]$Text){
    $f=New-Object System.Collections.ArrayList
    $a=[System.Management.Automation.Language.Parser]::ParseInput($Text,[ref]$null,[ref]$null)
    $drawn=New-Object System.Collections.ArrayList
    $other=New-Object System.Collections.ArrayList
    foreach($d in @($a.FindAll({param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and [string]$n.Member.Value -ceq 'Dispose'},$true))){
        $fn=$d.Parent; while($null -ne $fn -and $fn -isnot [System.Management.Automation.Language.FunctionDefinitionAst]){$fn=$fn.Parent}
        $fname=if($null -ne $fn){[string]$fn.Name}else{''}
        $inFinally=$false; $q=$d.Parent
        while($null -ne $q){ if($q.Parent -is [System.Management.Automation.Language.TryStatementAst] -and [object]::ReferenceEquals($q.Parent.Finally,$q)){$inFinally=$true}; $q=$q.Parent }
        if($fname -ceq 'New-FastLlmUiTrayIcon'){
            [void]$drawn.Add([string]$d.Expression.Extent.Text)
            if(-not $inFinally){[void]$f.Add("the Dispose of $($d.Expression.Extent.Text) in $fname is not in a finally")}
        }
        else{[void]$other.Add($fname+':'+[string]$d.Expression.Extent.Text)}
    }
    if((@($drawn|Sort-Object) -join ',') -cne '$bmp,$brush,$g,$path,$pen,$tmp'){[void]$f.Add("the drawn icon disposes [$((@($drawn|Sort-Object)) -join ',')], expected [`$bmp,`$brush,`$g,`$path,`$pen,`$tmp]")}
    if((@($other) -join ',') -cne 'Clear-FastLlmUiFluentTrayIcon:$script:FastLlmUiFluentTrayIconCache'){[void]$f.Add("the other Dispose calls are [$(@($other) -join ',')], expected only the cache release in Clear-FastLlmUiFluentTrayIcon")}
    return ,$f.ToArray()
}
$icoFindings=Get-IconDisposeFindings $icoText
foreach($x in $icoFindings){Write-Host "FINDING: $x"}
Check ($icoText -ne '' -and $icoFindings.Count -eq 0) 'every GDI object of the drawn tray icon (brush, path, pen, graphics, bitmap, copied icon) is disposed in a finally, and the only other Dispose is the cache release (D4: Dispose in finally)'
Check ((Get-IconDisposeFindings $icoText.Replace('finally { $pen.Dispose() }','$pen.Dispose()')).Count -ge 1) 'mutation check: a pen disposed outside a finally is flagged'
Check ((Get-IconDisposeFindings $icoText.Replace('finally { $path.Dispose() }','finally { }')).Count -ge 1) 'mutation check: a path never disposed is flagged'
Check ((Get-IconDisposeFindings $icoText.Replace('try { $g.FillPath($brush, $path) } finally { $brush.Dispose() }','$g.FillPath($brush, $path); $brush.Dispose()')).Count -ge 1) 'mutation check: a brush disposed after the draw instead of in a finally is flagged'
Check ((Get-IconDisposeFindings ($icoText+"`nfunction Plant { `$x.Dispose() }`n")).Count -ge 1) 'mutation check: a new Dispose outside the drawn icon and the cache release is flagged'
Check ((Get-IconDisposeFindings $icoText).Count -eq 0) 'control: the unmutated icon source has no dispose finding'
# ===== end PR 5a concept checks =====

# ===== PR 4b review fix G3: closure lint =====
# A scriptblock that has .GetNewClosure() called on it is bound to a dynamic module, which sees only GLOBAL functions: a bare call to a function the test file (or a
# helper it dot-sources) defines at file scope throws under -File on Windows CI (PR 4b C1 and C2: Get-WpfBoxTagMap and Get-ShellVisuals inside driver closures), and no macOS
# run reaches it. Inside such a block the function must be called through a variable captured outside it (`$f = ${function:Name}` and `& $f ...`) or a `$script:` scriptblock.
# Cmdlets, global functions (function global:Name) and functions defined inside the block itself are fine. The allowed exceptions are listed here, one "file|function" each.
$closureLintAllowed=@()
function Get-ClosureLintFindings([string]$FileText,[string[]]$HelperTexts,[string]$FileLabel){
    $f=New-Object System.Collections.ArrayList
    $tree=ConvertTo-PinAst $FileText
    $defined=@{}
    foreach($t in @($FileText)+@($HelperTexts)){
        foreach($d in @((ConvertTo-PinAst $t).FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true))){
            $nm=[string]$d.Name
            if($nm -match '^(?i)global:'){continue}
            $defined[($nm -replace '^(?i)script:','').ToLowerInvariant()]=$true
        }
    }
    $sbOf={param($call)
        $e=$call.Expression
        if($e -is [System.Management.Automation.Language.ScriptBlockExpressionAst]){return $e}
        if($e -is [System.Management.Automation.Language.VariableExpressionAst]){
            $asg=@($tree.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq $e.Extent.Text -and $n.Right.Extent.Text.TrimStart().StartsWith('{')},$true))
            if($asg.Count -ge 1){return $asg[0].Right.Find({param($n) $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst]},$true)}
        }
        return $null
    }
    $closures=@($tree.FindAll({param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$n.Member.Extent.Text -ceq 'GetNewClosure'},$true))
    foreach($c in $closures){
        $sb=& $sbOf $c
        if($null -eq $sb){continue}
        $local=@{}
        foreach($d in @($sb.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true))){ $local[([string]$d.Name).ToLowerInvariant()]=$true }
        foreach($cmd in @($sb.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst]},$true))){
            $name=[string]$cmd.GetCommandName()
            if($name -eq ''){continue}
            $key=$name.ToLowerInvariant()
            if($defined.ContainsKey($key) -and -not $local.ContainsKey($key) -and ($closureLintAllowed -cnotcontains ($FileLabel+'|'+$name))){
                [void]$f.Add("$FileLabel line $($cmd.Extent.StartLineNumber): a .GetNewClosure() block calls the file-scope function '$name' by name (capture `${function:$name} outside and call it with &)")
            }
        }
    }
    return ,$f.ToArray()
}
$closureLintFiles=@(Get-ChildItem -LiteralPath (Join-Path $root 'tests') -Filter 'ui-fluent-*.ps1'|ForEach-Object{$_.Name})+@('ui-render-tests.ps1')
$closureLintAll=New-Object System.Collections.ArrayList
$closureLintTexts=@{}
foreach($cf in $closureLintFiles){
    $ct0=[IO.File]::ReadAllText((Join-Path $root "tests/$cf"))
    $closureLintTexts[$cf]=$ct0
    $helpers=@()
    foreach($m in [regex]::Matches($ct0,'helpers[\\/]([\w.-]+\.ps1)')){ $hp=Join-Path $root "tests/helpers/$($m.Groups[1].Value)"; if(Test-Path -LiteralPath $hp){$helpers+=[IO.File]::ReadAllText($hp)} }
    foreach($x in (Get-ClosureLintFindings $ct0 $helpers $cf)){ [void]$closureLintAll.Add($x) }
}
foreach($x in $closureLintAll){Write-Host "FINDING: $x"}
Check ($closureLintAll.Count -eq 0 -and $closureLintFiles.Count -ge 8) "closure lint: no .GetNewClosure() block in $($closureLintFiles.Count) UI test files calls a file-scope function by bare name"
# Proven against the two real bugs (the C1 and C2 fixes reverted on scratch copies of the text) and a bare call in an inline closure.
$clPages=[string]$closureLintTexts['ui-fluent-pages-tests.ps1']
$clHelpers=@(); foreach($m in [regex]::Matches($clPages,'helpers[\\/]([\w.-]+\.ps1)')){ $clHelpers+=[IO.File]::ReadAllText((Join-Path $root "tests/helpers/$($m.Groups[1].Value)")) }
$clC1=$clPages.Replace("`$focusMap = & `$tagMap `$pw 'Buttons'","`$focusMap = Get-WpfBoxTagMap `$pw 'Buttons'")
$clC2=$clPages.Replace('$link = @(& $visuals $w |','$link = @(Get-ShellVisuals $w |')
Check ($clC1 -cne $clPages -and (Get-ClosureLintFindings $clC1 $clHelpers 'ui-fluent-pages-tests.ps1').Count -ge 1 -and ((Get-ClosureLintFindings $clC1 $clHelpers 'ui-fluent-pages-tests.ps1') -join ' ') -cmatch 'Get-WpfBoxTagMap') 'mutation check: the closure lint flags the C1 bug (Get-WpfBoxTagMap called by name inside the driver closure)'
Check ($clC2 -cne $clPages -and (Get-ClosureLintFindings $clC2 $clHelpers 'ui-fluent-pages-tests.ps1').Count -ge 1 -and ((Get-ClosureLintFindings $clC2 $clHelpers 'ui-fluent-pages-tests.ps1') -join ' ') -cmatch 'Get-ShellVisuals') 'mutation check: the closure lint flags the C2 bug (Get-ShellVisuals called by name inside New-P43LinkClick)'
$clSyn1="function Get-Thing { 1 }`n`$a = { Get-Thing }.GetNewClosure()"
$clSyn2="function Get-Thing { 1 }`n`$f = `${function:Get-Thing}`n`$a = { & `$f }.GetNewClosure()`n`$b = { Get-Thing }"
$clSyn3="function Get-Thing { 1 }`n`$b = { `$x = 1; Get-Thing }.GetNewClosure()"
Check ((Get-ClosureLintFindings $clSyn1 @() 'syn').Count -eq 1 -and (Get-ClosureLintFindings $clSyn2 @() 'syn').Count -eq 0 -and (Get-ClosureLintFindings $clSyn3 @() 'syn').Count -eq 1) 'mutation check: the closure lint flags a bare call in a closure, and passes a captured call and a bare call in a block that is not a closure'
# ===== end PR 4b review fix G3 =====

# ===== Settings additions (Task S2): the page rows, Save and the availability probes. Each pin runs on the real page text and on planted mutants. =====
# The approved wording of the new rows, as literals (never read back from the table). LongNotMeasured is the reason line of a disabled Long; it follows the
# planner's own refusal ('Not measured for this model and engine.', psm1 $script:FastLlmServingProfileNotMeasured) and says what a start would do.
$approvedStringsSa=[ordered]@{
    ContextProfile        = 'Context profile'
    ContextProfileDefault = 'Default (recommended)'
    ContextProfileLong    = 'Long: the measured long-context setup'
    ContextProfileHelp    = 'Long uses the measured long-context setup of the model and engine; a start is refused when none is measured. Applies at the next start.'
    LongNotMeasured       = 'Not measured for this model and engine, so a start with it would be refused.'
    NeedsCatalogContext   = 'Needs Context set to 0 (catalog default) on the Models page.'
    RequestsAtOnce        = 'Requests at once'
    RequestsAtOnceOne     = '1 (default)'
    RequestsAtOnceTwo     = '2'
    RequestsAtOnceHelp    = '2 needs a measured setup that allows it, and each request then gets half the context. Applies at the next start.'
    Embeddings            = 'Embeddings server (off by default)'
    EmbeddingsHelp        = 'Starts a second local server for embeddings (/v1/embeddings) on the CPU after the model is ready. A start is refused when no approved, measured embedding model is installed. Applies at the next start.'
    EmbeddingPort         = 'Embeddings port (127.0.0.1 only)'
    EmbeddingPortSame     = 'The embeddings port must differ from the server port. Nothing was saved.'
}
function Get-ApprovedSaStringFindings([string]$Text){
    $f=New-Object System.Collections.ArrayList
    $actual=Get-FluentStringTableValues $Text
    foreach($k in $approvedStringsSa.Keys){
        if(-not $actual.ContainsKey($k)){[void]$f.Add("$k is missing from the string table");continue}
        if([string]$actual[$k] -cne [string]$approvedStringsSa[$k]){[void]$f.Add("$k is '$($actual[$k])', approved '$($approvedStringsSa[$k])'")}
    }
    return $f.ToArray()
}
$asSa=@(Get-ApprovedSaStringFindings $homeStringsText)
foreach($x in $asSa){Write-Host "FINDING: $x"}
Check ($asSa.Count -eq 0) 'every Settings additions string (14: context profile, requests at once, embeddings, the port, the same-port message, the Long reason and the context reason) is exactly its approved text'
Check (@(Get-ApprovedSaStringFindings $homeStringsText.Replace("'Default (recommended)'","'Default'")).Count -ge 1) 'mutation check: the Default context profile caption reworded is flagged'
Check (@(Get-ApprovedSaStringFindings $homeStringsText.Replace("so a start with it would be refused.'","so a start would be refused.'")).Count -ge 1) 'mutation check: the Long reason reworded is flagged'
Check (@(Get-ApprovedSaStringFindings $homeStringsText.Replace("Nothing was saved.'","Nothing saved.'")).Count -ge 1) 'mutation check: the same-port message reworded is flagged'
Check (@(Get-ApprovedSaStringFindings $homeStringsText.Replace("on the Models page.'","on the Models tab.'")).Count -ge 1) 'mutation check: the context reason reworded is flagged'
Check (@(Get-ApprovedSaStringFindings $homeStringsText.Replace("    NeedsCatalogContext  = 'Needs Context set to 0 (catalog default) on the Models page.'`n",'')).Count -ge 1) 'mutation check: the context reason dropped is flagged'
Check (@(Get-ApprovedSaStringFindings $homeStringsText.Replace("    RequestsAtOnceTwo    = '2'`n",'')).Count -ge 1) 'mutation check: a missing approved key is flagged'
Check (@(Get-ApprovedSaStringFindings $homeStringsText.Replace("'Embeddings server (off by default)'","'Embeddings server (on by default)'")).Count -ge 1) 'mutation check: the Embeddings caption changed is flagged'
Check ((Get-FluentStringTableValues $homeStringsText)['LongNotMeasured'].StartsWith('Not measured for this model and engine') -and [IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.psm1')).Contains("`$script:FastLlmServingProfileNotMeasured = 'Not measured for this model and engine.'") -and [IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.ServingSettings.ps1')).Contains('has no measured setup for this model and engine')) 'the Long reason starts with the planner''s own refusal wording, and the start text of serving-profile-not-measured says the same thing'

# ---- helpers ----
function Get-SaFn([string]$Text,[string]$Name){
    $a=ConvertTo-PinAst $Text
    $m=@($a.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name},$true))
    if($m.Count -ne 1){return $null}
    return $m[0]
}
function Get-SaCalls($Scope,[string]$Cmd){ return @($Scope.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -ceq $Cmd},$true)) }
function Get-SaCommandParams($Cmd){
    $p=[ordered]@{}; $els=@($Cmd.CommandElements)
    for($i=1;$i -lt $els.Count;$i++){
        if($els[$i] -is [System.Management.Automation.Language.CommandParameterAst]){
            if($null -ne $els[$i].Argument){$p[[string]$els[$i].ParameterName]=[string]$els[$i].Argument.Extent.Text}
            elseif($i+1 -lt $els.Count -and $els[$i+1] -isnot [System.Management.Automation.Language.CommandParameterAst]){$p[[string]$els[$i].ParameterName]=[string]$els[$i+1].Extent.Text}
            else{$p[[string]$els[$i].ParameterName]=''}
        }
    }
    return $p
}
# Counts a finder's findings. Most finders end in `return ,$f.ToArray()`, so @(& $Finder $Text).Count is 1 for ANY non-empty or empty list (the comma nests the
# array): that vacuous count let a mutant that no finding flags pass. Here the nesting is unwrapped and empty or null items are not counted.
function Measure-SaFindings([scriptblock]$Finder,[string]$Text){
    $n=0
    foreach($item in @(& $Finder $Text)){ foreach($x in @($item)){ if($null -ne $x -and [string]$x -cne ''){$n++} } }
    return $n
}
# ONE predicate decides "caught": a plant expects it true, a control expects it false, so reverting the counting breaks the control too.
function Test-SaCaught([scriptblock]$Finder,[string]$Text){ return [bool]((Measure-SaFindings $Finder $Text) -ge 1) }
function Test-SaPlant([string]$Name,[string]$Plant,[string]$Real,[scriptblock]$Finder){
    Check ($Plant -cne $Real -and (Test-SaCaught $Finder $Plant)) "mutation check: $Name"
}
# The counter's own CONTROLS: a nested empty list, nothing and null are 0; nested lists of 1 and 2 are 1 and 2; a bare string is 1.
Check ((Measure-SaFindings {param($t) return ,@()} 'x') -eq 0 -and (Measure-SaFindings {param($t) return} 'x') -eq 0 -and (Measure-SaFindings {param($t) return $null} 'x') -eq 0 -and (Measure-SaFindings {param($t) return ,@('a')} 'x') -eq 1 -and (Measure-SaFindings {param($t) return ,@('a','b')} 'x') -eq 2 -and (Measure-SaFindings {param($t) return 'a'} 'x') -eq 1) 'the finding counter counts a nested list, an empty list, nothing, null and a bare string correctly (a vacuous counter fails here)'
Check (@(& {param($t) return ,@('a','b')} 'x').Count -eq 1) 'self-check: the naive @(& $Finder).Count is 1 for a two-finding list (the flaw the counter replaces)'
# A permanent CONTROL for a finder: the real text with only a comment appended must give 0 findings (a finder or counter that flags everything fails here).
function Test-SaControl([string]$Name,[string]$Real,[scriptblock]$Finder){
    Check (-not (Test-SaCaught $Finder ($Real+"`n# control: a comment-only change`n"))) "control check: a comment-only change is not flagged by $Name"
}

# ---- (a) Save passes each of the four held values to the one serving write only when the user changed it, and they are the only arguments beyond today's ----
# The effect-sequence projection (above) names calls, not arguments; this pin names the four as the fluent-only arguments of the same Set-FastLlmServingSettings
# call. They are not written as parameters: a hashtable @extra is splatted last on that line, and each of its four keys is added only under its own changed-test
# (the held value against the saved one), with its value taken from $values. So an untouched Save passes none of them and the stored file is as it was.
# The parameter keys of the classic Save's one Set-FastLlmServingSettings call, frozen; the check against the classic dialog is below (deleted with it at the flip).
$saClassicKeys=@('ChatPage','IdleStopMinutes','InstallRoot','ServerPort','Thinking')
$saFluentOnly=@('Embeddings','EmbeddingPort','KvContextProfile','KvSlots')
Check (@($saClassicKeys|Where-Object{$saFluentOnly -ccontains $_}).Count -eq 0 -and $saClassicKeys.Count -eq 5) 'the frozen classic Save keys hold today''s five parameters and none of the four serving additions (they are fluent-only)'
# 5b-delete-begin
$saClassicServing=Get-SaCommandParams (@(Get-SaCalls $settingsDialogFn 'Set-FastLlmServingSettings'))[0]
Check ((@($saClassicServing.Keys|Sort-Object) -join ',') -ceq (@($saClassicKeys|Sort-Object) -join ',')) 'the frozen classic Save keys equal the parameters of the classic dialog''s Set-FastLlmServingSettings call'
Check (@($saClassicServing.Keys|Where-Object{$saFluentOnly -ccontains $_}).Count -eq 0 -and @($saClassicServing.Keys).Count -ge 5) 'classic Save never passes the four serving additions (they are fluent-only)'
# 5b-delete-end
function Get-SaSaveArgFindings([string]$Text){
    $f=New-Object System.Collections.ArrayList
    $fn=Get-SaFn $Text 'Invoke-FastLlmUiFluentSettingsSave'
    if($null -eq $fn){[void]$f.Add('Invoke-FastLlmUiFluentSettingsSave is not defined once');return ,$f.ToArray()}
    $calls=@(Get-SaCalls $fn 'Set-FastLlmServingSettings')
    if($calls.Count -ne 1){[void]$f.Add("Save calls Set-FastLlmServingSettings $($calls.Count) times, expected 1");return ,$f.ToArray()}
    $p=Get-SaCommandParams $calls[0]
    $expectNames=@($saClassicKeys|Sort-Object) -join ','
    $gotNames=@($p.Keys|Sort-Object) -join ','
    if($gotNames -cne $expectNames){[void]$f.Add("the serving write passes [$gotNames] as parameters, expected exactly today's [$expectNames] (the four are only in @extra)")}
    $els=@($calls[0].CommandElements)
    $splats=@($els|Where-Object{$_ -is [System.Management.Automation.Language.VariableExpressionAst] -and $_.Splatted})
    if($splats.Count -ne 1 -or $splats[0].VariablePath.UserPath -cne 'extra' -or $els[$els.Count-1] -isnot [System.Management.Automation.Language.VariableExpressionAst]){[void]$f.Add('the serving write does not end with exactly one splat of @extra')}
    $idle=-1;$spl=-1; for($i=0;$i -lt $els.Count;$i++){ if($els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $els[$i].ParameterName -ceq 'IdleStopMinutes'){$idle=$i}; if($els[$i] -is [System.Management.Automation.Language.VariableExpressionAst] -and $els[$i].Splatted){$spl=$i} }
    if($idle -lt 0 -or $spl -lt $idle){[void]$f.Add('@extra is not appended after -IdleStopMinutes on the same line')}
    # @extra is created once, empty, before the write, and only the four keys are ever added, each under its own changed-test, with its value from $values.
    $init=@($fn.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$extra'},$true))
    if($init.Count -ne 1 -or $init[0].Right.Extent.Text -cne '@{}' -or $init[0].Extent.StartOffset -gt $calls[0].Extent.StartOffset){[void]$f.Add('$extra is not created once as an empty @{} before the serving write')}
    $adds=@($fn.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.IndexExpressionAst] -and $n.Left.Target.Extent.Text -ceq '$extra'},$true))
    $want=[ordered]@{
        KvContextProfile=@{Test='[string]$values.contextProfile -cne [string]$st[''Saved''].contextProfile';Value='[string]$values.contextProfile'}
        KvSlots=@{Test='[int]$values.slots -ne [int]$st[''Saved''].slots';Value='[int]$values.slots'}
        Embeddings=@{Test='[string]$values.embeddings -cne [string]$st[''Saved''].embeddings';Value='[string]$values.embeddings'}
        EmbeddingPort=@{Test='[int]$values.embeddingPort -ne [int]$st[''Saved''].embeddingPort';Value='[int]$values.embeddingPort'}
    }
    if($adds.Count -ne 4){[void]$f.Add("@extra gets $($adds.Count) keys added, expected exactly 4")}
    foreach($ad in $adds){
        $key=$ad.Left.Index.Extent.Text.Trim("'")
        if(-not $want.Contains($key)){[void]$f.Add("@extra gets an unexpected key '$key'");continue}
        if($ad.Right.Extent.Text -cne $want[$key].Value){[void]$f.Add("@extra['$key'] is '$($ad.Right.Extent.Text)', expected '$($want[$key].Value)' (from the held values)")}
        $q=$ad.Parent; $ifs=$null; while($null -ne $q -and $q -isnot [System.Management.Automation.Language.FunctionDefinitionAst]){ if($q -is [System.Management.Automation.Language.IfStatementAst]){$ifs=$q;break}; $q=$q.Parent }
        if($null -eq $ifs -or $ifs.Clauses.Count -ne 1 -or $null -ne $ifs.ElseClause){[void]$f.Add("@extra['$key'] is not added under one changed-test if without an else")}
        elseif($ifs.Clauses[0].Item1.Extent.Text -cne $want[$key].Test){[void]$f.Add("@extra['$key'] is added under '$($ifs.Clauses[0].Item1.Extent.Text)', expected '$($want[$key].Test)'")}
    }
    foreach($k in $want.Keys){ if(@($adds|Where-Object{$_.Left.Index.Extent.Text.Trim("'") -ceq $k}).Count -ne 1){[void]$f.Add("@extra never gets exactly one -$k")} }
    if($fn.Body.Extent.Text -cmatch '\$extra\.(Add|Remove|Clear)|\$extra\s*\+=|-Kv(ContextProfile|Slots)|-Embeddings(Port)?\b'){[void]$f.Add('another route adds a serving addition outside the four changed-tests')}
    return ,$f.ToArray()
}
$saSaveReal=Get-SaSaveArgFindings $settingsText
foreach($x in $saSaveReal){Write-Host "FINDING: $x"}
Check ($settingsText -ne '' -and $saSaveReal.Count -eq 0) 'the Save copy passes -KvContextProfile, -KvSlots, -Embeddings and -EmbeddingPort (through @extra) only when changed, each from the held values ($values), and nothing else is added to the serving write'
$saLineSlots="        if([int]`$values.slots -ne [int]`$st['Saved'].slots){`$extra['KvSlots']=[int]`$values.slots}`n"
Check ($settingsText.Contains($saLineSlots)) 'self-check: the KvSlots changed-test line anchors for the planted mutants exists'
Test-SaPlant 'the save-argument pin flags KvSlots added unconditionally with 1 (resets a saved 2)' $settingsText.Replace($saLineSlots,"        `$extra['KvSlots']=1`n") $settingsText ${function:Get-SaSaveArgFindings}
Test-SaPlant 'the save-argument pin flags KvSlots added unconditionally from the held value' $settingsText.Replace($saLineSlots,"        `$extra['KvSlots']=[int]`$values.slots`n") $settingsText ${function:Get-SaSaveArgFindings}
Test-SaPlant 'the save-argument pin flags the embeddings key added unconditionally' $settingsText.Replace("if([string]`$values.embeddings -cne [string]`$st['Saved'].embeddings){`$extra['Embeddings']=[string]`$values.embeddings}","`$extra['Embeddings']=[string]`$values.embeddings") $settingsText ${function:Get-SaSaveArgFindings}
Test-SaPlant 'the save-argument pin flags the profile key added unconditionally' $settingsText.Replace("if([string]`$values.contextProfile -cne [string]`$st['Saved'].contextProfile){`$extra['KvContextProfile']=[string]`$values.contextProfile}","`$extra['KvContextProfile']=[string]`$values.contextProfile") $settingsText ${function:Get-SaSaveArgFindings}
Test-SaPlant 'the save-argument pin flags the port key added unconditionally' $settingsText.Replace("if([int]`$values.embeddingPort -ne [int]`$st['Saved'].embeddingPort){`$extra['EmbeddingPort']=[int]`$values.embeddingPort}","`$extra['EmbeddingPort']=[int]`$values.embeddingPort") $settingsText ${function:Get-SaSaveArgFindings}
Test-SaPlant 'the save-argument pin flags a literal long profile' $settingsText.Replace("`$extra['KvContextProfile']=[string]`$values.contextProfile","`$extra['KvContextProfile']='long'") $settingsText ${function:Get-SaSaveArgFindings}
Test-SaPlant 'the save-argument pin flags a literal 2 for requests at once' $settingsText.Replace("`$extra['KvSlots']=[int]`$values.slots","`$extra['KvSlots']=2") $settingsText ${function:Get-SaSaveArgFindings}
Test-SaPlant 'the save-argument pin flags a literal on for embeddings' $settingsText.Replace("`$extra['Embeddings']=[string]`$values.embeddings","`$extra['Embeddings']='on'") $settingsText ${function:Get-SaSaveArgFindings}
Test-SaPlant 'the save-argument pin flags the server port taken for the embeddings port' $settingsText.Replace("`$extra['EmbeddingPort']=[int]`$values.embeddingPort","`$extra['EmbeddingPort']=[int]`$values.serverPort") $settingsText ${function:Get-SaSaveArgFindings}
Test-SaPlant 'the save-argument pin flags the changed-test comparing the wrong field (slots against the saved port)' $settingsText.Replace("[int]`$values.slots -ne [int]`$st['Saved'].slots","[int]`$values.slots -ne [int]`$st['Saved'].embeddingPort") $settingsText ${function:Get-SaSaveArgFindings}
Test-SaPlant 'the save-argument pin flags the embeddings changed-test comparing against the held value' $settingsText.Replace("[string]`$values.embeddings -cne [string]`$st['Saved'].embeddings","[string]`$values.embeddings -cne [string]`$held.embeddings") $settingsText ${function:Get-SaSaveArgFindings}
Test-SaPlant 'the save-argument pin flags the changed-test inverted' $settingsText.Replace("[int]`$values.slots -ne [int]`$st['Saved'].slots","[int]`$values.slots -eq [int]`$st['Saved'].slots") $settingsText ${function:Get-SaSaveArgFindings}
Test-SaPlant 'the save-argument pin flags the embeddings port dropped from the keys' $settingsText.Replace("if([int]`$values.embeddingPort -ne [int]`$st['Saved'].embeddingPort){`$extra['EmbeddingPort']=[int]`$values.embeddingPort}`n",'') $settingsText ${function:Get-SaSaveArgFindings}
Test-SaPlant 'the save-argument pin flags an extra key added to @extra' $settingsText.Replace($saLineSlots,$saLineSlots+"        if([int]`$values.serverPort -ne [int]`$st['Saved'].port){`$extra['ServerPort']=1}`n") $settingsText ${function:Get-SaSaveArgFindings}
Test-SaPlant 'the save-argument pin flags the splat dropped from the serving write' $settingsText.Replace(' -IdleStopMinutes $savedIdle @extra',' -IdleStopMinutes $savedIdle') $settingsText ${function:Get-SaSaveArgFindings}
Test-SaPlant 'the save-argument pin flags a direct -KvSlots parameter back on the write' $settingsText.Replace(' -IdleStopMinutes $savedIdle @extra',' -IdleStopMinutes $savedIdle -KvSlots ([int]$values.slots) @extra') $settingsText ${function:Get-SaSaveArgFindings}
Test-SaPlant 'the save-argument pin flags the idle argument dropped' $settingsText.Replace(' -IdleStopMinutes $savedIdle',' ') $settingsText ${function:Get-SaSaveArgFindings}

# ---- (b) the A3 guard: Embeddings on with the server's port refuses Save before the try, and nothing is written ----
function Get-SaGuardFindings([string]$Text){
    $f=New-Object System.Collections.ArrayList
    $fn=Get-SaFn $Text 'Invoke-FastLlmUiFluentSettingsSave'
    if($null -eq $fn){[void]$f.Add('Invoke-FastLlmUiFluentSettingsSave is not defined once');return ,$f.ToArray()}
    $top=@($fn.Body.EndBlock.Statements)
    $firstTry=-1; for($i=0;$i -lt $top.Count;$i++){ if($top[$i] -is [System.Management.Automation.Language.TryStatementAst]){$firstTry=$i;break} }
    $guard=-1
    for($i=0;$i -lt $top.Count;$i++){
        if($top[$i] -is [System.Management.Automation.Language.IfStatementAst] -and $top[$i].Clauses[0].Item1.Extent.Text -ceq "[string] `$held.embeddings -ceq 'on' -and [int] `$held.embeddingPort -eq [int] `$held.port"){$guard=$i;break}
    }
    if($guard -lt 0){[void]$f.Add('Save has no top-level guard on the embeddings port equal to the server port with Embeddings on');return ,$f.ToArray()}
    if($firstTry -lt 0 -or $guard -gt $firstTry){[void]$f.Add('the same-port guard is not before the save try')}
    $body=$top[$guard].Clauses[0].Item2
    if($body.Extent.Text -cnotmatch 'return \$false'){[void]$f.Add('the same-port guard does not return $false')}
    if(@(Get-SaCalls $body 'Set-FastLlmServingSettings').Count -ne 0 -or $body.Extent.Text -cmatch 'Invoke-FastLlmApiKeySetting|Set-FastLlmUiAllowSwitch'){[void]$f.Add('the same-port guard writes something')}
    if(@($body.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -ceq 'Update-FastLlmUiFluentSettingsEmbeddingPortView'},$true)).Count -ne 1){[void]$f.Add('the same-port guard does not show the inline message (Update-FastLlmUiFluentSettingsEmbeddingPortView)')}
    return ,$f.ToArray()
}
$saGuardReal=Get-SaGuardFindings $settingsText
foreach($x in $saGuardReal){Write-Host "FINDING: $x"}
Check ($settingsText -ne '' -and $saGuardReal.Count -eq 0) 'the Save copy refuses Embeddings on with the server port before the try, writes nothing and shows the inline message'
$saGuardBlock="    if ([string] `$held.embeddings -ceq 'on' -and [int] `$held.embeddingPort -eq [int] `$held.port) {`n        Update-FastLlmUiFluentSettingsEmbeddingPortView`n        `$null = `$e['SettingsEmbeddingPortBox'].Focus()`n        return `$false`n    }`n"
Check ($settingsText.Contains($saGuardBlock)) 'self-check: the guard block anchor for the planted mutants exists'
Test-SaPlant 'the A3 guard pin flags the guard dropped' $settingsText.Replace($saGuardBlock,'') $settingsText ${function:Get-SaGuardFindings}
Test-SaPlant 'the A3 guard pin flags the guard moved into the try' ($settingsText.Replace($saGuardBlock,'').Replace("        `$values = ConvertFrom-FastLlmUiSettingsHeld -Held `$held`n","        `$values = ConvertFrom-FastLlmUiSettingsHeld -Held `$held`n"+$saGuardBlock)) $settingsText ${function:Get-SaGuardFindings}
Test-SaPlant 'the A3 guard pin flags the guard keyed on Embeddings off' $settingsText.Replace("-ceq 'on' -and [int] `$held.embeddingPort -eq [int] `$held.port","-ceq 'off' -and [int] `$held.embeddingPort -eq [int] `$held.port") $settingsText ${function:Get-SaGuardFindings}
Test-SaPlant 'the A3 guard pin flags a guard that does not refuse' $settingsText.Replace($saGuardBlock,$saGuardBlock.Replace('return $false','return $true')) $settingsText ${function:Get-SaGuardFindings}
Test-SaPlant 'the A3 guard pin flags a guard that compares another port' $settingsText.Replace("-eq [int] `$held.port) {`n        Update-FastLlmUiFluentSettingsEmbeddingPortView","-eq [int] `$held.port + 1) {`n        Update-FastLlmUiFluentSettingsEmbeddingPortView") $settingsText ${function:Get-SaGuardFindings}

# ---- (b2) Long held at a requests-at-once value where it is not measured (and not the saved pair) shows the reason and refuses Save before the try ----
function Get-SaLongGuardFindings([string]$Text){
    $f=New-Object System.Collections.ArrayList
    $fn=Get-SaFn $Text 'Invoke-FastLlmUiFluentSettingsSave'
    if($null -eq $fn){[void]$f.Add('Invoke-FastLlmUiFluentSettingsSave is not defined once');return ,$f.ToArray()}
    $top=@($fn.Body.EndBlock.Statements)
    $firstTry=-1; for($i=0;$i -lt $top.Count;$i++){ if($top[$i] -is [System.Management.Automation.Language.TryStatementAst]){$firstTry=$i;break} }
    $guard=-1
    for($i=0;$i -lt $top.Count;$i++){ if($top[$i] -is [System.Management.Automation.Language.IfStatementAst] -and $top[$i].Clauses[0].Item1.Extent.Text -ceq 'Test-FastLlmUiFluentSettingsLongUnmeasuredHeld'){$guard=$i;break} }
    if($guard -lt 0){[void]$f.Add('Save has no top-level guard on Test-FastLlmUiFluentSettingsLongUnmeasuredHeld');return ,$f.ToArray()}
    if($firstTry -lt 0 -or $guard -gt $firstTry){[void]$f.Add('the Long guard is not before the save try')}
    $body=$top[$guard].Clauses[0].Item2
    if($body.Extent.Text -cnotmatch 'return \$false'){[void]$f.Add('the Long guard does not return $false')}
    if(@(Get-SaCalls $body 'Set-FastLlmServingSettings').Count -ne 0 -or $body.Extent.Text -cmatch 'Invoke-FastLlmApiKeySetting|Set-FastLlmUiAllowSwitch'){[void]$f.Add('the Long guard writes something')}
    if(@(Get-SaCalls $body 'Set-FastLlmUiFluentSettingsAdditionsView').Count -ne 1){[void]$f.Add('the Long guard does not show the reason line (the additions view)')}
    if($body.Extent.Text -cnotmatch [regex]::Escape("`$e['SettingsContextProfileBox'].Focus()")){[void]$f.Add('the Long guard does not put the focus on the context profile box')}
    $h=Get-SaFn $Text 'Test-FastLlmUiFluentSettingsLongUnmeasuredHeld'
    if($null -eq $h){[void]$f.Add('Test-FastLlmUiFluentSettingsLongUnmeasuredHeld is not defined once');return ,$f.ToArray()}
    # Behaviour of the helper itself, from its AST, over the page state it reads.
    $hadState=[bool](Get-Variable -Name FastLlmUiFluent -Scope Script -ErrorAction SilentlyContinue); $prevState=$null; if($hadState){$prevState=$script:FastLlmUiFluent}
    try{
        Invoke-Expression $h.Extent.Text
        $cases=@(
            @{p='long';slots=2;measured=$false;sp='default';ss=1;want=$true;name='long at 2, not measured, saved default'}
            @{p='long';slots=2;measured=$false;sp='long';ss=1;want=$true;name='long at 2, not measured, saved long at 1'}
            @{p='long';slots=2;measured=$false;sp='long';ss=2;want=$false;name='the saved pair itself'}
            @{p='long';slots=2;measured=$true;sp='default';ss=1;want=$false;name='measured'}
            @{p='default';slots=2;measured=$false;sp='default';ss=1;want=$false;name='default profile'}
            @{p='long';slots=1;measured=$false;sp='default';ss=1;want=$true;name='long at 1, not measured'}
        )
        foreach($c in $cases){
            $script:FastLlmUiFluent=@{ Settings=@{ Held=[pscustomobject]@{contextProfile=$c.p;slots=$c.slots}; Saved=[pscustomobject]@{contextProfile=$c.sp;slots=$c.ss}; LongMeasured=$c.measured } }
            $r=@(Test-FastLlmUiFluentSettingsLongUnmeasuredHeld)
            if($r.Count -ne 1 -or $r[0] -isnot [bool] -or [bool]$r[0] -ne [bool]$c.want){[void]$f.Add("the Long helper answers wrong for: $($c.name)")}
        }
        $script:FastLlmUiFluent=@{ Settings=@{ Held=$null; Saved=$null; LongMeasured=$false } }
        if([bool](Test-FastLlmUiFluentSettingsLongUnmeasuredHeld)){[void]$f.Add('the Long helper answers true with nothing held')}
    }finally{ if($hadState){$script:FastLlmUiFluent=$prevState}else{Remove-Variable -Name FastLlmUiFluent -Scope Script -ErrorAction SilentlyContinue} }
    # The reason line shows from the same helper, with the one existing string.
    $v=Get-SaFn $Text 'Set-FastLlmUiFluentSettingsAdditionsView'
    if($null -eq $v -or $v.Body.Extent.Text.IndexOf("if ((Test-FastLlmUiFluentSettingsLongUnmeasuredHeld) -or (Test-FastLlmUiFluentSettingsTwoUnmeasuredHeld)) { `$why = [string] `$s.LongNotMeasured }",[StringComparison]::Ordinal) -lt 0){[void]$f.Add('the reason line does not show LongNotMeasured for the held unmeasured pair')}
    $ed=Get-SaFn $Text 'Invoke-FastLlmUiFluentSettingsEdit'
    if($null -eq $ed -or @(Get-SaCalls $ed 'Set-FastLlmUiFluentSettingsAdditionsView').Count -ne 1){[void]$f.Add('an edit does not refresh the additions view (the reason line follows the held profile)')}
    return ,$f.ToArray()
}
$saLongGuardReal=Get-SaLongGuardFindings $settingsText
foreach($x in $saLongGuardReal){Write-Host "FINDING: $x"}
Check ($settingsText -ne '' -and $saLongGuardReal.Count -eq 0) 'Save refuses Long held where it is not measured (and not the saved pair) before the try, writes nothing, shows the reason and focuses the context profile box'
$saLongGuardBlock="    if (Test-FastLlmUiFluentSettingsLongUnmeasuredHeld) {`n        Set-FastLlmUiFluentSettingsAdditionsView`n        `$null = `$e['SettingsContextProfileBox'].Focus()`n        return `$false`n    }`n"
Check ($settingsText.Contains($saLongGuardBlock)) 'self-check: the Long guard block anchors for the planted mutants'
Test-SaPlant 'the Long guard pin flags the guard dropped' $settingsText.Replace($saLongGuardBlock,'') $settingsText ${function:Get-SaLongGuardFindings}
Test-SaPlant 'the Long guard pin flags the guard moved after the try' ($settingsText.Replace($saLongGuardBlock,'').Replace("    if(-not `$saved){return `$false}`n",$saLongGuardBlock+"    if(-not `$saved){return `$false}`n")) $settingsText ${function:Get-SaLongGuardFindings}
Test-SaPlant 'the Long guard pin flags a guard that does not refuse' $settingsText.Replace($saLongGuardBlock,$saLongGuardBlock.Replace('return $false','return $true')) $settingsText ${function:Get-SaLongGuardFindings}
Test-SaPlant 'the Long guard pin flags a guard without the focus' $settingsText.Replace($saLongGuardBlock,$saLongGuardBlock.Replace("        `$null = `$e['SettingsContextProfileBox'].Focus()`n",'')) $settingsText ${function:Get-SaLongGuardFindings}
Test-SaPlant 'the Long guard pin flags the saved-pair exception ignored' $settingsText.Replace("    if ([string] `$st['Saved'].contextProfile -ceq 'long' -and [int] `$st['Saved'].slots -eq [int] `$held.slots) { return `$false }`n",'') $settingsText ${function:Get-SaLongGuardFindings}
Test-SaPlant 'the Long guard pin flags the saved-pair exception on the profile alone' $settingsText.Replace(" -and [int] `$st['Saved'].slots -eq [int] `$held.slots) { return `$false }",") { return `$false }") $settingsText ${function:Get-SaLongGuardFindings}
Test-SaPlant 'the Long guard pin flags the measured answer ignored' $settingsText.Replace("    if ([bool] `$st['LongMeasured']) { return `$false }`n",'') $settingsText ${function:Get-SaLongGuardFindings}
Test-SaPlant 'the Long guard pin flags the guard firing on the default profile too' $settingsText.Replace("    if ([string] `$held.contextProfile -cne 'long') { return `$false }`n",'') $settingsText ${function:Get-SaLongGuardFindings}
Test-SaPlant 'the Long guard pin flags the reason line not shown' $settingsText.Replace("    if ((Test-FastLlmUiFluentSettingsLongUnmeasuredHeld) -or (Test-FastLlmUiFluentSettingsTwoUnmeasuredHeld)) { `$why = [string] `$s.LongNotMeasured }`n",'') $settingsText ${function:Get-SaLongGuardFindings}

# ---- (b3) "2 requests at once" held where the held profile has no measured row at 2 (and 2 is not the saved value), and a held change into Long or 2 while the
# Models page's Context is above 0: each shows the reason and refuses Save before the try, writes nothing and focuses its box ----
function Get-SaTopGuard($Fn,[string]$CondText){
    $top=@($Fn.Body.EndBlock.Statements)
    $firstTry=-1; for($i=0;$i -lt $top.Count;$i++){ if($top[$i] -is [System.Management.Automation.Language.TryStatementAst]){$firstTry=$i;break} }
    for($i=0;$i -lt $top.Count;$i++){ if($top[$i] -is [System.Management.Automation.Language.IfStatementAst] -and $top[$i].Clauses[0].Item1.Extent.Text -ceq $CondText){ return [pscustomobject]@{ If=$top[$i]; BeforeTry=[bool]($firstTry -ge 0 -and $i -lt $firstTry) } } }
    return $null
}
function Get-SaTwoGuardFindings([string]$Text){
    $f=New-Object System.Collections.ArrayList
    $fn=Get-SaFn $Text 'Invoke-FastLlmUiFluentSettingsSave'
    if($null -eq $fn){[void]$f.Add('Invoke-FastLlmUiFluentSettingsSave is not defined once');return ,$f.ToArray()}
    $g=Get-SaTopGuard $fn 'Test-FastLlmUiFluentSettingsTwoUnmeasuredHeld'
    if($null -eq $g){[void]$f.Add('Save has no top-level guard on Test-FastLlmUiFluentSettingsTwoUnmeasuredHeld');return ,$f.ToArray()}
    if(-not $g.BeforeTry){[void]$f.Add('the 2 guard is not before the save try')}
    $body=$g.If.Clauses[0].Item2
    if($body.Extent.Text -cnotmatch 'return \$false'){[void]$f.Add('the 2 guard does not return $false')}
    if(@(Get-SaCalls $body 'Set-FastLlmServingSettings').Count -ne 0 -or $body.Extent.Text -cmatch 'Invoke-FastLlmApiKeySetting|Set-FastLlmUiAllowSwitch'){[void]$f.Add('the 2 guard writes something')}
    if(@(Get-SaCalls $body 'Set-FastLlmUiFluentSettingsAdditionsView').Count -ne 1){[void]$f.Add('the 2 guard does not show the reason line (the additions view)')}
    if($body.Extent.Text -cnotmatch [regex]::Escape("`$e['SettingsRequestsBox'].Focus()")){[void]$f.Add('the 2 guard does not put the focus on the requests box')}
    $h=Get-SaFn $Text 'Test-FastLlmUiFluentSettingsTwoUnmeasuredHeld'
    if($null -eq $h){[void]$f.Add('Test-FastLlmUiFluentSettingsTwoUnmeasuredHeld is not defined once');return ,$f.ToArray()}
    $hadState=[bool](Get-Variable -Name FastLlmUiFluent -Scope Script -ErrorAction SilentlyContinue); $prevState=$null; if($hadState){$prevState=$script:FastLlmUiFluent}
    try{
        Invoke-Expression $h.Extent.Text
        $cases=@(
            @{slots=2;measured=$false;ss=1;want=$true;name='2, not measured, saved 1'}
            @{slots=2;measured=$false;ss=2;sp='default';want=$false;name='the saved pair itself (2 with the same profile)'}
            @{slots=2;measured=$false;ss=2;sp='long';want=$true;name='saved Long at 2 does not make Default at 2 safe (only the saved pair is exempt)'}
            @{slots=2;measured=$true;ss=1;want=$false;name='2, measured'}
            @{slots=1;measured=$false;ss=1;want=$false;name='1 needs no row'}
            @{slots=1;measured=$false;ss=2;want=$false;name='back to 1'}
        )
        foreach($c in $cases){
            $savedProfile='default'; if($c.ContainsKey('sp')){$savedProfile=[string]$c.sp}
            $script:FastLlmUiFluent=@{ Settings=@{ Held=[pscustomobject]@{contextProfile='default';slots=$c.slots}; Saved=[pscustomobject]@{contextProfile=$savedProfile;slots=$c.ss}; TwoMeasured=$c.measured } }
            $r=@(Test-FastLlmUiFluentSettingsTwoUnmeasuredHeld)
            if($r.Count -ne 1 -or $r[0] -isnot [bool] -or [bool]$r[0] -ne [bool]$c.want){[void]$f.Add("the 2 helper answers wrong for: $($c.name)")}
        }
        $script:FastLlmUiFluent=@{ Settings=@{ Held=$null; Saved=$null; TwoMeasured=$false } }
        if([bool](Test-FastLlmUiFluentSettingsTwoUnmeasuredHeld)){[void]$f.Add('the 2 helper answers true with nothing held')}
    }finally{ if($hadState){$script:FastLlmUiFluent=$prevState}else{Remove-Variable -Name FastLlmUiFluent -Scope Script -ErrorAction SilentlyContinue} }
    return ,$f.ToArray()
}
$saTwoGuardReal=Get-SaTwoGuardFindings $settingsText
foreach($x in $saTwoGuardReal){Write-Host "FINDING: $x"}
Check ($settingsText -ne '' -and $saTwoGuardReal.Count -eq 0) 'Save refuses 2 requests at once held where it is not measured (and not the saved value) before the try, writes nothing, shows the reason and focuses the requests box'
$saTwoGuardBlock="    if (Test-FastLlmUiFluentSettingsTwoUnmeasuredHeld) {`n        Set-FastLlmUiFluentSettingsAdditionsView`n        `$null = `$e['SettingsRequestsBox'].Focus()`n        return `$false`n    }`n"
Check ($settingsText.Contains($saTwoGuardBlock)) 'self-check: the 2 guard block anchors for the planted mutants'
Test-SaPlant 'the 2 guard pin flags the guard dropped' $settingsText.Replace($saTwoGuardBlock,'') $settingsText ${function:Get-SaTwoGuardFindings}
Test-SaPlant 'the 2 guard pin flags the guard moved after the try' ($settingsText.Replace($saTwoGuardBlock,'').Replace("    if(-not `$saved){return `$false}`n",$saTwoGuardBlock+"    if(-not `$saved){return `$false}`n")) $settingsText ${function:Get-SaTwoGuardFindings}
Test-SaPlant 'the 2 guard pin flags a guard that does not refuse' $settingsText.Replace($saTwoGuardBlock,$saTwoGuardBlock.Replace('return $false','return $true')) $settingsText ${function:Get-SaTwoGuardFindings}
Test-SaPlant 'the 2 guard pin flags a guard without the focus' $settingsText.Replace($saTwoGuardBlock,$saTwoGuardBlock.Replace("        `$null = `$e['SettingsRequestsBox'].Focus()`n",'')) $settingsText ${function:Get-SaTwoGuardFindings}
Test-SaPlant 'the 2 guard pin flags the saved-pair exception dropped' $settingsText.Replace("    if ([int] `$st['Saved'].slots -eq 2 -and [string] `$st['Saved'].contextProfile -ceq [string] `$held.contextProfile) { return `$false }`n",'') $settingsText ${function:Get-SaTwoGuardFindings}
Test-SaPlant 'the 2 guard pin flags the exception on the saved slots alone (a saved Long at 2 would exempt Default at 2)' $settingsText.Replace(" -and [string] `$st['Saved'].contextProfile -ceq [string] `$held.contextProfile) { return `$false }",") { return `$false }") $settingsText ${function:Get-SaTwoGuardFindings}
Test-SaPlant 'the 2 guard pin flags the measured answer ignored' $settingsText.Replace("    if ([bool] `$st['TwoMeasured']) { return `$false }`n",'') $settingsText ${function:Get-SaTwoGuardFindings}
Test-SaPlant 'the 2 guard pin flags the guard firing on 1 too' $settingsText.Replace("    if ([int] `$held.slots -ne 2) { return `$false }`n",'') $settingsText ${function:Get-SaTwoGuardFindings}

function Get-SaCatalogGuardFindings([string]$Text){
    $f=New-Object System.Collections.ArrayList
    $fn=Get-SaFn $Text 'Invoke-FastLlmUiFluentSettingsSave'
    if($null -eq $fn){[void]$f.Add('Invoke-FastLlmUiFluentSettingsSave is not defined once');return ,$f.ToArray()}
    $g=Get-SaTopGuard $fn "`$catalogContextBox -cne ''"
    if($null -eq $g){[void]$f.Add('Save has no top-level guard on the held change into the context state');return ,$f.ToArray()}
    if(-not $g.BeforeTry){[void]$f.Add('the context guard is not before the save try')}
    $body=$g.If.Clauses[0].Item2
    if($body.Extent.Text -cnotmatch 'return \$false'){[void]$f.Add('the context guard does not return $false')}
    if(@(Get-SaCalls $body 'Set-FastLlmServingSettings').Count -ne 0 -or $body.Extent.Text -cmatch 'Invoke-FastLlmApiKeySetting|Set-FastLlmUiAllowSwitch'){[void]$f.Add('the context guard writes something')}
    if(@(Get-SaCalls $body 'Set-FastLlmUiFluentSettingsAdditionsView').Count -ne 1){[void]$f.Add('the context guard does not show the reason line (the additions view)')}
    if($body.Extent.Text -cnotmatch [regex]::Escape("`$e['SettingsContextProfileBox'].Focus()") -or $body.Extent.Text -cnotmatch [regex]::Escape("`$e['SettingsRequestsBox'].Focus()")){[void]$f.Add('the context guard does not focus the changed box (the context profile box or the requests box)')}
    $as=@($fn.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$catalogContextBox'},$true))
    if($as.Count -ne 1 -or $as[0].Right.Extent.Text -cne '[string] (Get-FastLlmUiFluentSettingsCatalogContextHeld)'){[void]$f.Add('the context guard does not read Get-FastLlmUiFluentSettingsCatalogContextHeld')}
    $h=Get-SaFn $Text 'Get-FastLlmUiFluentSettingsCatalogContextHeld'
    if($null -eq $h){[void]$f.Add('Get-FastLlmUiFluentSettingsCatalogContextHeld is not defined once');return ,$f.ToArray()}
    $hadState=[bool](Get-Variable -Name FastLlmUiFluent -Scope Script -ErrorAction SilentlyContinue); $prevState=$null; if($hadState){$prevState=$script:FastLlmUiFluent}
    try{
        Invoke-Expression $h.Extent.Text
        $cases=@(
            @{ctx=4096;p='long';slots=1;sp='default';ss=1;want='profile';name='Long held, Context above 0'}
            @{ctx=4096;p='default';slots=2;sp='default';ss=1;want='requests';name='2 held, Context above 0'}
            @{ctx=4096;p='long';slots=1;sp='long';ss=1;want='';name='Long is already the saved value'}
            @{ctx=4096;p='default';slots=2;sp='default';ss=2;want='';name='2 is already the saved value'}
            @{ctx=0;p='long';slots=2;sp='default';ss=1;want='';name='Context 0'}
            @{ctx=4096;p='default';slots=1;sp='default';ss=1;want='';name='nothing changed into the state'}
        )
        foreach($c in $cases){
            $script:FastLlmUiFluent=@{ Settings=@{ Held=[pscustomobject]@{contextProfile=$c.p;slots=$c.slots}; Saved=[pscustomobject]@{contextProfile=$c.sp;slots=$c.ss}; ContextSize=$c.ctx } }
            $r=@(Get-FastLlmUiFluentSettingsCatalogContextHeld)
            if($r.Count -ne 1 -or $r[0] -isnot [string] -or [string]$r[0] -cne [string]$c.want){[void]$f.Add("the context helper answers wrong for: $($c.name)")}
        }
        $script:FastLlmUiFluent=@{ Settings=@{ Held=$null; Saved=$null; ContextSize=4096 } }
        if([string](Get-FastLlmUiFluentSettingsCatalogContextHeld) -cne ''){[void]$f.Add('the context helper answers a box with nothing held')}
    }finally{ if($hadState){$script:FastLlmUiFluent=$prevState}else{Remove-Variable -Name FastLlmUiFluent -Scope Script -ErrorAction SilentlyContinue} }
    $rd=Get-SaFn $Text 'Read-FastLlmUiFluentSettingsContextSize'
    if($null -eq $rd -or $rd.Body.Extent.Text -cnotmatch [regex]::Escape('[int] $script:contextBox.Value') -or $rd.Body.Extent.Text -cnotmatch 'catch \{ return 0 \}'){[void]$f.Add('the context size is not read from the context adapter ($script:contextBox.Value) with a 0 on failure, as ReadSelection reads it')}
    return ,$f.ToArray()
}
$saCatalogGuardReal=Get-SaCatalogGuardFindings $settingsText
foreach($x in $saCatalogGuardReal){Write-Host "FINDING: $x"}
Check ($settingsText -ne '' -and $saCatalogGuardReal.Count -eq 0) 'Save refuses a held change into Long or 2 while the Models page Context is above 0 before the try, writes nothing, shows the reason and focuses the changed box'
$saCatalogGuardBlock="    `$catalogContextBox = [string] (Get-FastLlmUiFluentSettingsCatalogContextHeld)`n    if (`$catalogContextBox -cne '') {`n        Set-FastLlmUiFluentSettingsAdditionsView`n        if (`$catalogContextBox -ceq 'profile') { `$null = `$e['SettingsContextProfileBox'].Focus() } else { `$null = `$e['SettingsRequestsBox'].Focus() }`n        return `$false`n    }`n"
Check ($settingsText.Contains($saCatalogGuardBlock)) 'self-check: the context guard block anchors for the planted mutants'
Test-SaPlant 'the context guard pin flags the guard dropped' $settingsText.Replace($saCatalogGuardBlock,'') $settingsText ${function:Get-SaCatalogGuardFindings}
Test-SaPlant 'the context guard pin flags the guard moved after the try' ($settingsText.Replace($saCatalogGuardBlock,'').Replace("    if(-not `$saved){return `$false}`n",$saCatalogGuardBlock+"    if(-not `$saved){return `$false}`n")) $settingsText ${function:Get-SaCatalogGuardFindings}
Test-SaPlant 'the context guard pin flags a guard that does not refuse' $settingsText.Replace($saCatalogGuardBlock,$saCatalogGuardBlock.Replace('return $false','return $true')) $settingsText ${function:Get-SaCatalogGuardFindings}
Test-SaPlant 'the context guard pin flags a guard without the requests focus' $settingsText.Replace($saCatalogGuardBlock,$saCatalogGuardBlock.Replace("else { `$null = `$e['SettingsRequestsBox'].Focus() }",'')) $settingsText ${function:Get-SaCatalogGuardFindings}
Test-SaPlant 'the context guard pin flags the context condition dropped from the helper' $settingsText.Replace("    if ([int] `$st['ContextSize'] -le 0) { return '' }`n",'') $settingsText ${function:Get-SaCatalogGuardFindings}
Test-SaPlant 'the context guard pin flags the saved-Long exception dropped' $settingsText.Replace(" -and [string] `$st['Saved'].contextProfile -cne 'long') { return 'profile' }",") { return 'profile' }") $settingsText ${function:Get-SaCatalogGuardFindings}
Test-SaPlant 'the context guard pin flags the saved-2 exception dropped' $settingsText.Replace(" -and [int] `$st['Saved'].slots -ne 2) { return 'requests' }",") { return 'requests' }") $settingsText ${function:Get-SaCatalogGuardFindings}
Test-SaPlant 'the context guard pin flags the context size not read from the adapter' $settingsText.Replace('try { return [int] $script:contextBox.Value }','try { return 0 }') $settingsText ${function:Get-SaCatalogGuardFindings}

# ---- (b4) a change of the same-port line or of the reason line is announced once per change (live region), and the same-port reason is the port box's help text ----
function Get-SaLiveFindings([string]$Text){
    $f=New-Object System.Collections.ArrayList
    $v=Get-SaFn $Text 'Set-FastLlmUiFluentSettingsAdditionsView'
    $p=Get-SaFn $Text 'Update-FastLlmUiFluentSettingsEmbeddingPortView'
    if($null -eq $v -or $null -eq $p){[void]$f.Add('the additions view or the port row view is not defined once');return ,$f.ToArray()}
    $vs=@(Get-SaCalls $v 'Send-FastLlmUiFluentLiveRegion'); $ps=@(Get-SaCalls $p 'Send-FastLlmUiFluentLiveRegion')
    if($vs.Count -ne 1 -or [string](Get-SaCommandParams $vs[0])['Element'] -cne "`$e['SettingsContextProfileWhy']"){[void]$f.Add('the reason line change is not announced once from the additions view (Send-FastLlmUiFluentLiveRegion on SettingsContextProfileWhy)')}
    if($ps.Count -ne 1 -or [string](Get-SaCommandParams $ps[0])['Element'] -cne '$line'){[void]$f.Add('the same-port line change is not announced once from the port row view (Send-FastLlmUiFluentLiveRegion on the line)')}
    # Each send sits under a test of the text against the last announced text, which it stores first; so a view run with the same text announces nothing.
    foreach($pair in @(@($vs,'WhyText','$why',$v),@($ps,'SameText','$sameText',$p))){
        if($pair[0].Count -ne 1){continue}
        $q=$pair[0][0].Parent; $outer=$null; $inner=$null
        while($null -ne $q -and $q -isnot [System.Management.Automation.Language.FunctionDefinitionAst]){ if($q -is [System.Management.Automation.Language.IfStatementAst]){ if($null -eq $inner){$inner=$q}else{$outer=$q;break} }; $q=$q.Parent }
        $want="[string] `$st['$($pair[1])'] -cne $($pair[2])"
        if($pair[1] -ceq 'WhyText'){$want="-not [bool] `$st['Settling'] -and "+$want}
        if($pair[1] -ceq 'SameText'){$want="[string] `$f['Settings']['SameText'] -cne $($pair[2])"}
        if($null -eq $outer -or $outer.Clauses[0].Item1.Extent.Text -cne $want){[void]$f.Add("the announcement of $($pair[1]) is not under '$want' (once per change, not on every view run)")}
        elseif($outer.Clauses[0].Item2.Extent.Text.IndexOf("['$($pair[1])'] = $($pair[2])",[StringComparison]::Ordinal) -lt 0){[void]$f.Add("the last announced text ($($pair[1])) is not stored before the announcement")}
    }
    $en=Get-SaFn $Text 'Enter-FastLlmUiFluentSettings'
    if($null -eq $en -or $en.Body.Extent.Text.IndexOf("`$enterState['Settling'] = `$true",[StringComparison]::Ordinal) -lt 0 -or $en.Body.Extent.Text.IndexOf("finally { `$enterState['Settling'] = `$false }",[StringComparison]::Ordinal) -lt 0 -or $en.Body.Extent.Text.IndexOf("`$enterState['WhyText'] = ''",[StringComparison]::Ordinal) -lt 0 -or $en.Body.Extent.Text.IndexOf("`$enterState['SameText'] = ''",[StringComparison]::Ordinal) -lt 0){[void]$f.Add('Enter does not reset the last announced texts and settle the first fill (so a visit announces what it shows once, from the real probe answers)')}
    $ph=@($p.FindAll({param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Extent.Text -cmatch 'SetHelpText\(\$e\[''SettingsEmbeddingPortBox''\], \$sameText\)'},$true))
    if($ph.Count -ne 1){[void]$f.Add('the embeddings port box does not get the same-port message as its help text (set to the message while showing, cleared otherwise)')}
    $vh=@($v.FindAll({param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Extent.Text -cmatch 'SetHelpText\(\$e\[''SettingsRequestsBox''\], \$why\)'},$true))
    if($vh.Count -ne 1){[void]$f.Add('the requests box does not get the reason line as its help text')}
    return ,$f.ToArray()
}
$saLiveReal=Get-SaLiveFindings $settingsText
foreach($x in $saLiveReal){Write-Host "FINDING: $x"}
Check ($settingsText -ne '' -and $saLiveReal.Count -eq 0) 'the reason line and the same-port line are announced once per change (never on every view run), and their texts are the help text of the boxes they explain'
Test-SaPlant 'the live pin flags the reason announcement dropped' $settingsText.Replace("        if (`$why -cne '') { Send-FastLlmUiFluentLiveRegion -Element `$e['SettingsContextProfileWhy'] }`n",'') $settingsText ${function:Get-SaLiveFindings}
Test-SaPlant 'the live pin flags the same-port announcement dropped' $settingsText.Replace("        if (`$sameText -cne '') { Send-FastLlmUiFluentLiveRegion -Element `$line }`n",'') $settingsText ${function:Get-SaLiveFindings}
Test-SaPlant 'the live pin flags the reason announced from the first fill of a visit (Settling ignored)' $settingsText.Replace("    if (-not [bool] `$st['Settling'] -and [string] `$st['WhyText'] -cne `$why) {","    if ([string] `$st['WhyText'] -cne `$why) {") $settingsText ${function:Get-SaLiveFindings}
Test-SaPlant 'the live pin flags Enter not settling the first fill' $settingsText.Replace("        `$enterState['Settling'] = `$true`n",'') $settingsText ${function:Get-SaLiveFindings}
Test-SaPlant 'the live pin flags the reason announced on every view run' $settingsText.Replace("    if (-not [bool] `$st['Settling'] -and [string] `$st['WhyText'] -cne `$why) {","    if (`$true) {") $settingsText ${function:Get-SaLiveFindings}
Test-SaPlant 'the live pin flags the same-port line announced on every view run' $settingsText.Replace("    if ([string] `$f['Settings']['SameText'] -cne `$sameText) {","    if (`$true) {") $settingsText ${function:Get-SaLiveFindings}
Test-SaPlant 'the live pin flags the last announced reason never stored' $settingsText.Replace("        `$st['WhyText'] = `$why`n",'') $settingsText ${function:Get-SaLiveFindings}
Test-SaPlant 'the live pin flags the last announced same-port text never stored' $settingsText.Replace("        `$f['Settings']['SameText'] = `$sameText`n",'') $settingsText ${function:Get-SaLiveFindings}
Test-SaPlant 'the live pin flags the port box help text dropped' $settingsText.Replace("    [System.Windows.Automation.AutomationProperties]::SetHelpText(`$e['SettingsEmbeddingPortBox'], `$sameText)`n",'') $settingsText ${function:Get-SaLiveFindings}
Test-SaPlant 'the live pin flags the requests box help text dropped' $settingsText.Replace("    [System.Windows.Automation.AutomationProperties]::SetHelpText(`$e['SettingsRequestsBox'], `$why)`n",'') $settingsText ${function:Get-SaLiveFindings}

# ---- (c) the inline message and the port row follow the held values (A2, A3) ----
function Get-SaInlineFindings([string]$Text){
    $f=New-Object System.Collections.ArrayList
    $fn=Get-SaFn $Text 'Update-FastLlmUiFluentSettingsEmbeddingPortView'
    if($null -eq $fn){[void]$f.Add('Update-FastLlmUiFluentSettingsEmbeddingPortView is not defined once');return ,$f.ToArray()}
    $b=$fn.Body.Extent.Text
    if($b -cnotmatch [regex]::Escape("`$on = [bool] ([string] `$held.embeddings -ceq 'on')")){[void]$f.Add('the port row does not follow the held Embeddings value')}
    if($b -cnotmatch [regex]::Escape("if (`$on) { `$e['SettingsEmbeddingPortGroup'].Visibility = [System.Windows.Visibility]::Visible } else { `$e['SettingsEmbeddingPortGroup'].Visibility = [System.Windows.Visibility]::Collapsed }")){[void]$f.Add('the port row is not shown only while Embeddings is on')}
    if($b -cnotmatch [regex]::Escape("`$same = [bool] (`$on -and [int] `$held.embeddingPort -eq [int] `$held.port)")){[void]$f.Add('the inline message does not compare the two held ports while Embeddings is on')}
    if($b -cnotmatch [regex]::Escape("`$line.Text = [string] `$script:FastLlmUiFluentStrings.EmbeddingPortSame")){[void]$f.Add('the inline message text is not EmbeddingPortSame')}
    if($b -cnotmatch "(?s)if \(\`$same\) \{.*?Visibility\]?\s*=?.*?Visible.*?\}\s*else \{.*?Collapsed"){[void]$f.Add('the inline message is not shown only while the ports are the same')}
    foreach($caller in 'Invoke-FastLlmUiFluentSettingsEdit','Invoke-FastLlmUiFluentSettingsPortCommit','Invoke-FastLlmUiFluentSettingsEmbeddingPortCommit','Set-FastLlmUiFluentSettingsAdditionsView'){
        $cf=Get-SaFn $Text $caller
        if($null -eq $cf -or @(Get-SaCalls $cf 'Update-FastLlmUiFluentSettingsEmbeddingPortView').Count -ne 1){[void]$f.Add("$caller does not refresh the port row and the inline message once")}
    }
    $x=@([regex]::Matches($Text,'x:Name="SettingsEmbeddingPortSame"[^>]*>'))
    if($x.Count -ne 1 -or $x[0].Value -cnotmatch 'Visibility="Collapsed"' -or $x[0].Value -cnotmatch 'AutomationProperties\.LiveSetting="Polite"'){[void]$f.Add('the inline message TextBlock is not collapsed at first and polite')}
    $g=@([regex]::Matches($Text,'x:Name="SettingsEmbeddingPortGroup"[^>]*>'))
    if($g.Count -ne 1 -or $g[0].Value -cnotmatch 'Visibility="Collapsed"'){[void]$f.Add('the port row group is not collapsed at first')}
    return ,$f.ToArray()
}
$saInlineReal=Get-SaInlineFindings $settingsText
foreach($x in $saInlineReal){Write-Host "FINDING: $x"}
Check ($settingsText -ne '' -and $saInlineReal.Count -eq 0) 'the embeddings port row shows only while Embeddings is on, and the inline same-port message is wired to the held ports and is polite'
Test-SaPlant 'the inline pin flags the port row always visible' $settingsText.Replace("if (`$on) { `$e['SettingsEmbeddingPortGroup'].Visibility = [System.Windows.Visibility]::Visible } else {","if (`$true) { `$e['SettingsEmbeddingPortGroup'].Visibility = [System.Windows.Visibility]::Visible } else {") $settingsText ${function:Get-SaInlineFindings}
Test-SaPlant 'the inline pin flags the message text never set' $settingsText.Replace("        `$line.Text = [string] `$script:FastLlmUiFluentStrings.EmbeddingPortSame`n","        `$line.Text = ''`n") $settingsText ${function:Get-SaInlineFindings}
Test-SaPlant 'the inline pin flags the message shown when Embeddings is off' $settingsText.Replace("`$same = [bool] (`$on -and [int]","`$same = [bool] ([int]") $settingsText ${function:Get-SaInlineFindings}
Test-SaPlant 'the inline pin flags a server port change that does not refresh the message' $settingsText.Replace("    if (`$box.Text -cne `$shown) { `$box.Text = `$shown }`n    Update-FastLlmUiFluentSettingsEmbeddingPortView`n    `$st['Dirty'] = [bool] (Test-FastLlmUiSettingsDirty -Saved `$st['Saved'] -Held `$held)`n}`n`n# The Embeddings port box","    if (`$box.Text -cne `$shown) { `$box.Text = `$shown }`n    `$st['Dirty'] = [bool] (Test-FastLlmUiSettingsDirty -Saved `$st['Saved'] -Held `$held)`n}`n`n# The Embeddings port box") $settingsText ${function:Get-SaInlineFindings}
Test-SaPlant 'the inline pin flags an edit that does not refresh the message' $settingsText.Replace("    Update-FastLlmUiFluentSettingsEmbeddingPortView`n    `$st['Dirty'] = [bool] (Test-FastLlmUiSettingsDirty -Saved `$st['Saved'] -Held `$held)`n}`n`n# The Port box commits","    `$st['Dirty'] = [bool] (Test-FastLlmUiSettingsDirty -Saved `$st['Saved'] -Held `$held)`n}`n`n# The Port box commits") $settingsText ${function:Get-SaInlineFindings}
Test-SaPlant 'the inline pin flags the message not polite' $settingsText.Replace('x:Name="SettingsEmbeddingPortSame" Margin="0,4,0,0" TextWrapping="Wrap" Visibility="Collapsed" Foreground="{DynamicResource FastLlm.CautionTextBrush}"
                         AutomationProperties.LiveSetting="Polite"','x:Name="SettingsEmbeddingPortSame" Margin="0,4,0,0" TextWrapping="Wrap" Visibility="Collapsed" Foreground="{DynamicResource FastLlm.CautionTextBrush}"') $settingsText ${function:Get-SaInlineFindings}

# ---- (d) the rows are shown or enabled only from the view (A4 and the Long ruling), never unconditionally ----
function Get-SaViewFindings([string]$Text){
    $f=New-Object System.Collections.ArrayList
    $fn=Get-SaFn $Text 'Set-FastLlmUiFluentSettingsAdditionsView'
    if($null -eq $fn){[void]$f.Add('Set-FastLlmUiFluentSettingsAdditionsView is not defined once');return ,$f.ToArray()}
    $calls=@(Get-SaCalls $fn 'Get-FastLlmUiSettingsAdditionsView')
    if($calls.Count -ne 1){[void]$f.Add("the view is read $($calls.Count) times, expected 1")}
    else{
        $p=Get-SaCommandParams $calls[0]
        $want=[ordered]@{ EmbeddingsAvailable="([bool] `$st['EmbeddingsAvailable'])"; SavedEmbeddings="([string] `$st['Saved'].embeddings)"; LongMeasured="([bool] `$st['LongMeasured'])"; SavedContextProfile="([string] `$st['Saved'].contextProfile)"; TwoMeasured="([bool] `$st['TwoMeasured'])"; SavedSlots="([int] `$st['Saved'].slots)"; ContextSize="([int] `$st['ContextSize'])" }
        foreach($k in $want.Keys){ if(-not $p.Contains($k) -or [string]$p[$k] -cne [string]$want[$k]){[void]$f.Add("the view's -$k is not '$($want[$k])'")} }
    }
    $a=ConvertTo-PinAst $Text
    # Every write of the Embeddings group's Visibility is in the view function, inside the showEmbeddings if or its else.
    $vis=@($a.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -cmatch "SettingsEmbeddingsGroup'\]\.Visibility"},$true))
    if($vis.Count -ne 2){[void]$f.Add("the Embeddings group's Visibility is written $($vis.Count) times, expected 2 (shown and hidden)")}
    foreach($v in $vis){
        $enc=Get-EnclosingFunctionAst $v
        if($null -eq $enc -or $enc.Name -cne 'Set-FastLlmUiFluentSettingsAdditionsView'){[void]$f.Add('the Embeddings group is shown or hidden outside the view function')}
        $p=$v.Parent; $ok=$false; while($null -ne $p -and $p -isnot [System.Management.Automation.Language.FunctionDefinitionAst]){ if($p -is [System.Management.Automation.Language.IfStatementAst] -and $p.Clauses[0].Item1.Extent.Text -ceq "[bool] `$view['showEmbeddings']"){$ok=$true}; $p=$p.Parent }
        if(-not $ok){[void]$f.Add('a write of the Embeddings group Visibility is not under the showEmbeddings condition')}
    }
    $en=@($a.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -cmatch "SettingsContextProfileBox'\]\.Items\[\d\]\.IsEnabled"},$true))
    if($en.Count -ne 1 -or $en[0].Left.Extent.Text -cne "`$e['SettingsContextProfileBox'].Items[1].IsEnabled" -or $en[0].Right.Extent.Text -cne "[bool] `$view['longEnabled']"){[void]$f.Add('the Long item is not enabled by view.longEnabled alone')}
    $en2=@($a.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -cmatch "SettingsRequestsBox'\]\.Items\[\d\]\.IsEnabled"},$true))
    if($en2.Count -ne 1 -or $en2[0].Left.Extent.Text -cne "`$e['SettingsRequestsBox'].Items[1].IsEnabled" -or $en2[0].Right.Extent.Text -cne "[bool] `$view['twoEnabled']"){[void]$f.Add('the 2 item is not enabled by view.twoEnabled alone')}
    if($null -ne $fn){
        $b=$fn.Body.Extent.Text
        if($b -cnotmatch [regex]::Escape("if ([string] `$view['longReasonCode'] -ceq 'long-not-measured' -or [string] `$view['twoReasonCode'] -ceq 'long-not-measured') { `$why = [string] `$s.LongNotMeasured }")){[void]$f.Add('the reason line is not the LongNotMeasured string for the long-not-measured code (Long or 2)')}
        # The context reason is written LAST, so it wins when both reasons apply (it is the actionable one).
        $iNot=$b.IndexOf('$why = [string] $s.LongNotMeasured',[StringComparison]::Ordinal); $iCtx=$b.IndexOf('$why = [string] $s.NeedsCatalogContext',[StringComparison]::Ordinal)
        if($iCtx -lt 0 -or $iNot -lt 0 -or $iCtx -lt $iNot){[void]$f.Add('the NeedsCatalogContext reason is not written after (so over) the LongNotMeasured reason')}
        if($b -cnotmatch [regex]::Escape("if ([string] `$view['longReasonCode'] -ceq 'needs-catalog-context' -or [string] `$view['twoReasonCode'] -ceq 'needs-catalog-context' -or [string] (Get-FastLlmUiFluentSettingsCatalogContextHeld) -cne '') { `$why = [string] `$s.NeedsCatalogContext }")){[void]$f.Add('the reason line is not NeedsCatalogContext for the needs-catalog-context code or a held change into the context state')}
        if($b -cnotmatch [regex]::Escape("`$e['SettingsContextProfileWhy'].Text = `$why")){[void]$f.Add('the reason line is not written to SettingsContextProfileWhy')}
    }
    $xg=@([regex]::Matches($Text,'x:Name="SettingsEmbeddingsGroup"[^>]*>'))
    if($xg.Count -ne 1 -or $xg[0].Value -cnotmatch 'Visibility="Collapsed"'){[void]$f.Add('the Embeddings rows are not collapsed at first')}
    $xw=@([regex]::Matches($Text,'x:Name="SettingsContextProfileWhy"[^>]*>'))
    if($xw.Count -ne 1 -or $xw[0].Value -cnotmatch 'Visibility="Collapsed"'){[void]$f.Add('the Long reason line is not collapsed at first')}
    return ,$f.ToArray()
}
$saViewReal=Get-SaViewFindings $settingsText
foreach($x in $saViewReal){Write-Host "FINDING: $x"}
Check ($settingsText -ne '' -and $saViewReal.Count -eq 0) 'both Embeddings rows are shown only when the view says so, and Long is disabled with its reason only from the view (never unconditional)'
Test-SaPlant 'the view pin flags the Embeddings rows always visible' $settingsText.Replace("if ([bool] `$view['showEmbeddings']) {","if (`$true) {") $settingsText ${function:Get-SaViewFindings}
Test-SaPlant 'the view pin flags the Embeddings rows shown from the saved value alone' $settingsText.Replace("if ([bool] `$view['showEmbeddings']) {","if ([string] `$st['Saved'].embeddings -ceq 'on') {") $settingsText ${function:Get-SaViewFindings}
Test-SaPlant 'the view pin flags item 2 always enabled' $settingsText.Replace("Items[1].IsEnabled = [bool] `$view['twoEnabled']","Items[1].IsEnabled = `$true") $settingsText ${function:Get-SaViewFindings}
Test-SaPlant 'the view pin flags the context reason dropped' $settingsText.Replace("{ `$why = [string] `$s.NeedsCatalogContext }","{ `$why = `$why }") $settingsText ${function:Get-SaViewFindings}
Test-SaPlant 'the view pin flags the wrong reason precedence (the context reason written first)' $settingsText.Replace("-cne '') { `$why = [string] `$s.NeedsCatalogContext }","-cne '') { if (`$why -ceq '') { `$why = [string] `$s.NeedsCatalogContext } }") $settingsText ${function:Get-SaViewFindings}
Test-SaPlant 'the view pin flags the context size fed from a literal 0' $settingsText.Replace("-ContextSize ([int] `$st['ContextSize'])","-ContextSize 0") $settingsText ${function:Get-SaViewFindings}
Test-SaPlant 'the view pin flags the saved slots dropped from the view' $settingsText.Replace("-SavedSlots ([int] `$st['Saved'].slots)","-SavedSlots 1") $settingsText ${function:Get-SaViewFindings}
Test-SaPlant 'the view pin flags the 2 measured answer ignored' $settingsText.Replace("-TwoMeasured ([bool] `$st['TwoMeasured'])","-TwoMeasured `$true") $settingsText ${function:Get-SaViewFindings}
Test-SaPlant 'the view pin flags Long always enabled' $settingsText.Replace("Items[1].IsEnabled = [bool] `$view['longEnabled']","Items[1].IsEnabled = `$true") $settingsText ${function:Get-SaViewFindings}
Test-SaPlant 'the view pin flags the reason line dropped' $settingsText.Replace("{ `$why = [string] `$s.LongNotMeasured }","{ `$why = '' }") $settingsText ${function:Get-SaViewFindings}
Test-SaPlant 'the view pin flags the Embeddings group shown on Enter' $settingsText.Replace('x:Name="SettingsEmbeddingsGroup" Visibility="Collapsed"','x:Name="SettingsEmbeddingsGroup"') $settingsText ${function:Get-SaViewFindings}
Test-SaPlant 'the view pin flags the availability fed from a literal' $settingsText.Replace("-EmbeddingsAvailable ([bool] `$st['EmbeddingsAvailable'])","-EmbeddingsAvailable `$true") $settingsText ${function:Get-SaViewFindings}
Test-SaPlant 'the view pin flags the saved embeddings dropped from the view' $settingsText.Replace("-SavedEmbeddings ([string] `$st['Saved'].embeddings)","-SavedEmbeddings 'off'") $settingsText ${function:Get-SaViewFindings}
Test-SaPlant 'the view pin flags the group shown from another function' ($settingsText+"`nfunction Show-Embeddings { `$e['SettingsEmbeddingsGroup'].Visibility = [System.Windows.Visibility]::Visible }`n") $settingsText ${function:Get-SaViewFindings}

# ---- (e) the availability is read on Enter (the long probe also when the requests box changes), never on a tick or a reload; each probe is non-throwing and read-only ----
function Get-SaProbeFindings([string]$Text){
    $f=New-Object System.Collections.ArrayList
    $a=ConvertTo-PinAst $Text
    $eu=@($a.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -ceq 'Test-FastLlmUiFluentEmbeddingsAvailable'},$true))
    if($eu.Count -ne 1){[void]$f.Add("Test-FastLlmUiFluentEmbeddingsAvailable is called $($eu.Count) times, expected 1 (Enter)")}
    else{ $enc=Get-EnclosingFunctionAst $eu[0]; if($null -eq $enc -or $enc.Name -cne 'Enter-FastLlmUiFluentSettings'){[void]$f.Add('Test-FastLlmUiFluentEmbeddingsAvailable is called outside Enter-FastLlmUiFluentSettings (a tick, an edit or a reload must not probe)')} }
    # The long probe is called once, inside the long-state function, with the held slots; that function is called from Enter (forced), the edit and the discard only.
    $lu=@($a.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -ceq 'Test-FastLlmUiFluentLongMeasured'},$true))
    if($lu.Count -ne 2){[void]$f.Add("Test-FastLlmUiFluentLongMeasured is called $($lu.Count) times, expected 2 (Long at the held slots, and the held profile at 2; both in the long-state function)")}
    else{
        foreach($lc in $lu){
            $enc=Get-EnclosingFunctionAst $lc
            if($null -eq $enc -or $enc.Name -cne 'Update-FastLlmUiFluentSettingsLongState'){[void]$f.Add('Test-FastLlmUiFluentLongMeasured is called outside Update-FastLlmUiFluentSettingsLongState (a tick or a reload must not probe)')}
        }
        $lp=@($lu|ForEach-Object{ $q=Get-SaCommandParams $_; "$($q['ProfileId'])|$($q['Slots'])" })
        if($lp -cnotcontains "'long'|`$slots"){[void]$f.Add('the long probe is not asked for Long with the held slots ($slots)')}
        if($lp -cnotcontains '$profileId|2'){[void]$f.Add('the 2 probe is not asked for the held profile at 2 requests at once')}
    }
    $ls=Get-SaFn $Text 'Update-FastLlmUiFluentSettingsLongState'
    if($null -eq $ls){[void]$f.Add('Update-FastLlmUiFluentSettingsLongState is not defined once')}
    else{
        $b=$ls.Body.Extent.Text
        foreach($need in "`$slots = [int] `$st['Held'].slots","`$profileId = [string] `$st['Held'].contextProfile","if (`$Force -or [int] `$st['LongSlots'] -ne `$slots) {","`$st['LongMeasured'] = [bool] (Test-FastLlmUiFluentLongMeasured -ProfileId 'long' -Slots `$slots)","`$st['LongSlots'] = `$slots","if (`$Force -or [string] `$st['TwoProfile'] -cne `$profileId) {","`$st['TwoMeasured'] = [bool] (Test-FastLlmUiFluentLongMeasured -ProfileId `$profileId -Slots 2)","`$st['TwoProfile'] = `$profileId","`$st['ContextSize'] = [int] (Read-FastLlmUiFluentSettingsContextSize)"){ if($b.IndexOf($need,[StringComparison]::Ordinal) -lt 0){[void]$f.Add("the long-state function lacks: $need")} }
        if(@(Get-SaCalls $ls 'Set-FastLlmUiFluentSettingsAdditionsView').Count -ne 1){[void]$f.Add('the long-state function does not show the answer through the additions view once')}
    }
    $callers=@($a.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -ceq 'Update-FastLlmUiFluentSettingsLongState'},$true))
    $byFn=@{}
    foreach($c in $callers){ $enc=Get-EnclosingFunctionAst $c; $name=$(if($null -eq $enc){'(none)'}else{$enc.Name}); if(-not $byFn.ContainsKey($name)){$byFn[$name]=@()}; $byFn[$name]+=$c }
    $gotFns=@($byFn.Keys|Sort-Object) -join ','
    $wantFns=@('Enter-FastLlmUiFluentSettings','Invoke-FastLlmUiFluentSettingsDiscard','Invoke-FastLlmUiFluentSettingsEdit') -join ','
    if($gotFns -cne $wantFns -or $callers.Count -ne 3){[void]$f.Add("the long state is refreshed from [$gotFns] ($($callers.Count) calls), expected exactly Enter, the edit and the discard")}
    if($byFn.ContainsKey('Enter-FastLlmUiFluentSettings')){
        $ec=$byFn['Enter-FastLlmUiFluentSettings'][0]
        if(-not ($ec.Extent.Text -ceq 'Update-FastLlmUiFluentSettingsLongState -Force')){[void]$f.Add('Enter does not force the long state')}
        $load=@(Get-SaCalls (Get-SaFn $Text 'Enter-FastLlmUiFluentSettings') 'Update-FastLlmUiFluentSettingsLoad')
        if($load.Count -ne 1 -or $load[0].Extent.StartOffset -gt $ec.Extent.StartOffset){[void]$f.Add('Enter reads the long state before the settings are loaded (the held slots are not known yet)')}
    }
    if($byFn.ContainsKey('Invoke-FastLlmUiFluentSettingsEdit')){
        $ec=$byFn['Invoke-FastLlmUiFluentSettingsEdit'][0]
        if($ec.Extent.Text -cne 'Update-FastLlmUiFluentSettingsLongState'){[void]$f.Add('the edit does not refresh the long state unforced')}
        $sa=@((Get-SaFn $Text 'Invoke-FastLlmUiFluentSettingsEdit').FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$held.slots'},$true))
        if($sa.Count -ne 1 -or $sa[0].Extent.StartOffset -gt $ec.Extent.StartOffset){[void]$f.Add('the edit refreshes the long state before it has read the held slots')}
    }
    if($byFn.ContainsKey('Invoke-FastLlmUiFluentSettingsDiscard') -and $byFn['Invoke-FastLlmUiFluentSettingsDiscard'][0].Extent.Text -cne 'Update-FastLlmUiFluentSettingsLongState'){[void]$f.Add('the discard does not refresh the long state unforced')}
    $emb=Get-SaFn $Text 'Test-FastLlmUiFluentEmbeddingsAvailable'
    if($null -eq $emb){[void]$f.Add('Test-FastLlmUiFluentEmbeddingsAvailable is not defined once')}
    else{
        $t=@($emb.Body.EndBlock.Statements|Where-Object{$_ -is [System.Management.Automation.Language.TryStatementAst]})
        if($t.Count -ne 1 -or @(Get-SaCalls $t[0].Body 'Assert-FastLlmEmbeddingsAvailable').Count -ne 1 -or $t[0].Body.Extent.Text -cnotmatch 'return \$true' -or @($t[0].CatchClauses).Count -ne 1 -or $t[0].CatchClauses[0].Body.Extent.Text -cnotmatch '^\{\s*return \$false\s*\}$'){[void]$f.Add('the embeddings probe is not Assert-FastLlmEmbeddingsAvailable inside a try that returns $true, with a catch that returns $false')}
        elseif((Get-SaCommandParams (Get-SaCalls $t[0].Body 'Assert-FastLlmEmbeddingsAvailable')[0]).Keys -ccontains 'Port'){[void]$f.Add('the embeddings probe passes a port')}
    }
    $lg=Get-SaFn $Text 'Test-FastLlmUiFluentLongMeasured'
    if($null -eq $lg){[void]$f.Add('Test-FastLlmUiFluentLongMeasured is not defined once')}
    else{
        $t=@($lg.Body.EndBlock.Statements|Where-Object{$_ -is [System.Management.Automation.Language.TryStatementAst]})
        if($t.Count -ne 1 -or @($t[0].CatchClauses).Count -ne 1 -or $t[0].CatchClauses[0].Body.Extent.Text -cnotmatch '^\{\s*return \$false\s*\}$'){[void]$f.Add('the long probe is not one try with a catch that returns $false')}
        $find=@(Get-SaCalls $lg 'Find-FastLlmServingProfileRow')
        if($find.Count -ne 1){[void]$f.Add("the long probe asks Find-FastLlmServingProfileRow $($find.Count) times, expected 1")}
        else{
            $p=Get-SaCommandParams $find[0]
            if([string]$p['ProfileId'] -cne '$HeldProfile'){[void]$f.Add("the probe asks for profile '$($p['ProfileId'])', expected the asked profile (`$HeldProfile)")}
            if([string]$p['EngineId'] -cne '$engineId'){[void]$f.Add('the long probe does not use the built-in engine id')}
            if([string]$p['Slots'] -cne '$HeldSlots'){[void]$f.Add("the long probe asks with -Slots '$($p['Slots'])', expected the held slots (`$HeldSlots)")}
            if([string]$p['Backend'] -cne '([string] $backend)'){[void]$f.Add('the long probe does not ask each candidate backend')}
        }
        foreach($need in 'Read-FastLlmServingProfiles','Get-FastLlmBuiltInEngineId','Get-FastLlmCatalog'){ if(@(Get-SaCalls $lg $need).Count -ne 1){[void]$f.Add("the long probe does not call $need once")} }
        # The backends are the engines installed under this install (a path check), or the catalog-enabled ones when none is installed; never every backend the rows name.
        if(@(Get-SaCalls $lg 'Get-FastLlmEngineExecutable').Count -ne 1 -or $lg.Body.Extent.Text.IndexOf('if ($null -ne (Get-FastLlmEngineExecutable',[StringComparison]::Ordinal) -lt 0 -or $lg.Body.Extent.Text.IndexOf('$installed += $key',[StringComparison]::Ordinal) -lt 0){[void]$f.Add('the long probe does not keep only the backends whose engine is installed')}
        if($lg.Body.Extent.Text.IndexOf('$backends = @($installed)',[StringComparison]::Ordinal) -lt 0 -or $lg.Body.Extent.Text.IndexOf('if ($backends.Count -eq 0) { $backends = @($enabled) }',[StringComparison]::Ordinal) -lt 0){[void]$f.Add('the long probe backends are not the installed ones, with the catalog-enabled ones as the only fallback')}
        if(@(Get-SaCalls $lg 'Get-FastLlmServingProfileValue').Count -ne 0){[void]$f.Add('the long probe takes its backends from the rows (any backend), not from the install')}
        if($lg.Body.Extent.Text -cmatch '-Slots\s+1\b'){[void]$f.Add('the long probe asks with a literal -Slots 1')}
        if($lg.Body.Extent.Text.IndexOf('} $configRoot $modelId $script:installPath $Slots',[StringComparison]::Ordinal) -lt 0){[void]$f.Add('the long probe does not pass its -Slots and the install root to the planner scope')}
        if($lg.Body.Extent.Text -cnotmatch [regex]::Escape("if ([int] `$script:modelBox.SelectedIndex -gt 0) { `$modelId = [string] `$script:modelBox.SelectedItem }")){[void]$f.Add('the long probe does not take the model as ReadSelection does (the chosen model, or Automatic)')}
        if($lg.Body.Extent.Text -cmatch 'Set-|Write-|Remove-|Out-File|Add-Content|New-Item'){[void]$f.Add('the long probe writes something')}
    }
    return ,$f.ToArray()
}
$saProbeReal=Get-SaProbeFindings $settingsText
foreach($x in $saProbeReal){Write-Host "FINDING: $x"}
Check ($settingsText -ne '' -and $saProbeReal.Count -eq 0) 'the embeddings probe runs on Enter only, the long probe on Enter and when the requests box changes (with the held slots, for the installed backends), both non-throwing and read-only'
$saEnterEmb="        `$enterState['EmbeddingsAvailable'] = [bool] (Test-FastLlmUiFluentEmbeddingsAvailable)`n"
$saEnterLong="        Update-FastLlmUiFluentSettingsLongState -Force`n"
$saEditLong="    Update-FastLlmUiFluentSettingsLongState`n    Set-FastLlmUiFluentSettingsAdditionsView`n    Update-FastLlmUiFluentSettingsEmbeddingPortView`n    `$st['Dirty']"
$saDiscLong="    Set-FastLlmUiFluentSettingsView`n    Update-FastLlmUiFluentSettingsLongState`n}"
$saGuardLine="    if (`$Force -or [int] `$st['LongSlots'] -ne `$slots) {`n"
Check ($settingsText.Contains($saEnterEmb) -and $settingsText.Contains($saEnterLong) -and $settingsText.Contains($saEditLong) -and $settingsText.Contains($saDiscLong) -and $settingsText.Contains($saGuardLine)) 'self-check: the probe call anchors for the planted mutants exist'
Test-SaPlant 'the probe pin flags the embeddings probe moved into the tick hook' ($settingsText.Replace($saEnterEmb,'').Replace("    `$keys = `$f['Keys']`n    `$text = Get-FastLlmUiFluentSettingsUnavailableText","    `$keys = `$f['Keys']`n"+$saEnterEmb.Replace('        $enterState','    $script:FastLlmUiFluent[''Settings'']')+"    `$text = Get-FastLlmUiFluentSettingsUnavailableText")) $settingsText ${function:Get-SaProbeFindings}
Test-SaPlant 'the probe pin flags the long state also refreshed on every reload' $settingsText.Replace("    `$st['Current'] = `$current`n","    `$st['Current'] = `$current`n    Update-FastLlmUiFluentSettingsLongState -Force`n") $settingsText ${function:Get-SaProbeFindings}
Test-SaPlant 'the probe pin flags the long state also refreshed on the tick' $settingsText.Replace("    `$keys = `$f['Keys']`n    `$text = Get-FastLlmUiFluentSettingsUnavailableText","    `$keys = `$f['Keys']`n    Update-FastLlmUiFluentSettingsLongState -Force`n    `$text = Get-FastLlmUiFluentSettingsUnavailableText") $settingsText ${function:Get-SaProbeFindings}
Test-SaPlant 'the probe pin flags the long state dropped from Enter' $settingsText.Replace($saEnterLong,'') $settingsText ${function:Get-SaProbeFindings}
Test-SaPlant 'the probe pin flags the long state not forced on Enter' $settingsText.Replace($saEnterLong,"        Update-FastLlmUiFluentSettingsLongState`n") $settingsText ${function:Get-SaProbeFindings}
Test-SaPlant 'the probe pin flags the long state read before the settings are loaded' $settingsText.Replace($saEnterLong,'').Replace("        `$enterState['Settling'] = `$true`n","        Update-FastLlmUiFluentSettingsLongState -Force`n        `$enterState['Settling'] = `$true`n") $settingsText ${function:Get-SaProbeFindings}
Test-SaPlant 'the probe pin flags the long state not recomputed when the requests box changes' $settingsText.Replace($saEditLong,"    Update-FastLlmUiFluentSettingsEmbeddingPortView`n    `$st['Dirty']") $settingsText ${function:Get-SaProbeFindings}
Test-SaPlant 'the probe pin flags the long state not recomputed on a discard' $settingsText.Replace($saDiscLong,"    Set-FastLlmUiFluentSettingsView`n}") $settingsText ${function:Get-SaProbeFindings}
Test-SaPlant 'the probe pin flags the long state asked with a literal slots value' $settingsText.Replace("`$slots = [int] `$st['Held'].slots","`$slots = 1") $settingsText ${function:Get-SaProbeFindings}
Test-SaPlant 'the probe pin flags the unchanged-slots guard dropped (a probe on every edit)' $settingsText.Replace($saGuardLine,"    if (`$true) {`n") $settingsText ${function:Get-SaProbeFindings}
Test-SaPlant 'the probe pin flags the long probe asking for the default profile' $settingsText.Replace("Test-FastLlmUiFluentLongMeasured -ProfileId 'long'","Test-FastLlmUiFluentLongMeasured -ProfileId 'default'") $settingsText ${function:Get-SaProbeFindings}
Test-SaPlant 'the probe pin flags the planner scope asking a literal long profile' $settingsText.Replace('-ProfileId $HeldProfile -Slots $HeldSlots',"-ProfileId 'long' -Slots `$HeldSlots") $settingsText ${function:Get-SaProbeFindings}
Test-SaPlant 'the probe pin flags the 2 probe asked with the wrong profile (always long)' $settingsText.Replace("Test-FastLlmUiFluentLongMeasured -ProfileId `$profileId -Slots 2","Test-FastLlmUiFluentLongMeasured -ProfileId 'long' -Slots 2") $settingsText ${function:Get-SaProbeFindings}
Test-SaPlant 'the probe pin flags the 2 probe asked at slots 1' $settingsText.Replace("Test-FastLlmUiFluentLongMeasured -ProfileId `$profileId -Slots 2","Test-FastLlmUiFluentLongMeasured -ProfileId `$profileId -Slots 1") $settingsText ${function:Get-SaProbeFindings}
Test-SaPlant 'the probe pin flags the 2 probe not re-asked when the profile changes' $settingsText.Replace("if (`$Force -or [string] `$st['TwoProfile'] -cne `$profileId) {","if (`$Force) {") $settingsText ${function:Get-SaProbeFindings}
Test-SaPlant 'the probe pin flags the context size not read in the long-state function' $settingsText.Replace("    `$st['ContextSize'] = [int] (Read-FastLlmUiFluentSettingsContextSize)`n",'') $settingsText ${function:Get-SaProbeFindings}
Test-SaPlant 'the probe pin flags the long probe asking with slots 1' $settingsText.Replace('-ProfileId $HeldProfile -Slots $HeldSlots','-ProfileId $HeldProfile -Slots 1') $settingsText ${function:Get-SaProbeFindings}
Test-SaPlant 'the probe pin flags the long probe never passing the held slots in' $settingsText.Replace('} $configRoot $modelId $script:installPath $Slots','} $configRoot $modelId $script:installPath 1') $settingsText ${function:Get-SaProbeFindings}
Test-SaPlant 'the probe pin flags the long probe taking any backend the rows name' $settingsText.Replace('$backends = @($installed)','$backends = @($rows | ForEach-Object { Get-FastLlmServingProfileValue -Row $_ -Name ''backend'' } | Where-Object { $_ -is [string] } | Select-Object -Unique)') $settingsText ${function:Get-SaProbeFindings}
Test-SaPlant 'the probe pin flags the long probe counting an engine that is not installed' $settingsText.Replace('if ($null -ne (Get-FastLlmEngineExecutable -InstallRoot $InstallRoot -EngineVersion $version -BackendKey $key -EntryPoint ([string] $asset.entryPoint))) { $installed += $key }','$installed += $key') $settingsText ${function:Get-SaProbeFindings}
Test-SaPlant 'the probe pin flags the long probe with no enabled-engine fallback dropped to every backend' $settingsText.Replace('if ($backends.Count -eq 0) { $backends = @($enabled) }','if ($backends.Count -eq 0) { $backends = @(''rocm'', ''vulkan'') }') $settingsText ${function:Get-SaProbeFindings}
Test-SaPlant 'the probe pin flags the embeddings probe that throws into the page' $settingsText.Replace("    catch { return `$false }`n}`n`n# Does this install have","    catch { return `$true }`n}`n`n# Does this install have") $settingsText ${function:Get-SaProbeFindings}
Test-SaPlant 'the probe pin flags the embeddings probe that does not ask the start check' $settingsText.Replace('        Assert-FastLlmEmbeddingsAvailable -CatalogPath','        $null = Get-Item -CatalogPath') $settingsText ${function:Get-SaProbeFindings}
Test-SaPlant 'the probe pin flags the long probe that fails open' ($settingsText.Substring(0,$settingsText.IndexOf('function Test-FastLlmUiFluentLongMeasured'))+$settingsText.Substring($settingsText.IndexOf('function Test-FastLlmUiFluentLongMeasured')).Replace("    catch { return `$false }`n","    catch { return `$true }`n")) $settingsText ${function:Get-SaProbeFindings}
Test-SaPlant 'the probe pin flags the long probe ignoring the chosen model' $settingsText.Replace("if ([int] `$script:modelBox.SelectedIndex -gt 0) { `$modelId = [string] `$script:modelBox.SelectedItem }",'') $settingsText ${function:Get-SaProbeFindings}

# ---- (f) the edits write Held, the Embeddings port goes through the shared clamp, Discard reverts all four, and each input is named from one string ----
function Get-SaEditFindings([string]$Text){
    $f=New-Object System.Collections.ArrayList
    $edit=Get-SaFn $Text 'Invoke-FastLlmUiFluentSettingsEdit'
    if($null -eq $edit){[void]$f.Add('Invoke-FastLlmUiFluentSettingsEdit is not defined once')}
    else{
        $want=[ordered]@{
            '$held.contextProfile'="[string] `$(if ([int] `$e['SettingsContextProfileBox'].SelectedIndex -eq 1) { 'long' } else { 'default' })"
            '$held.slots'="[int] `$(if ([int] `$e['SettingsRequestsBox'].SelectedIndex -eq 1) { 2 } else { 1 })"
            '$held.embeddings'="[string] `$(if (`$e['SettingsEmbeddingsBox'].IsChecked -eq `$true) { 'on' } else { 'off' })"
        }
        foreach($k in $want.Keys){
            $m=@($edit.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq $k},$true))
            if($m.Count -ne 1 -or $m[0].Right.Extent.Text -cne $want[$k]){[void]$f.Add("the edit does not write $k from its control")}
        }
    }
    $pc=Get-SaFn $Text 'Invoke-FastLlmUiFluentSettingsEmbeddingPortCommit'
    if($null -eq $pc){[void]$f.Add('Invoke-FastLlmUiFluentSettingsEmbeddingPortCommit is not defined once')}
    else{
        $b=$pc.Body.Extent.Text
        if(([regex]::Matches($b,[regex]::Escape('-Minimum ([decimal] 1024) -Maximum ([decimal] 65535)'))).Count -ne 3){[void]$f.Add('the embeddings port does not take the 1024..65535 clamp for the typed text and both steps')}
        if(([regex]::Matches($b,[regex]::Escape('-Increment ([decimal] 1)'))).Count -ne 2){[void]$f.Add('the embeddings port steps are not 1')}
        if($b -cnotmatch [regex]::Escape('$held.embeddingPort = [int] $value')){[void]$f.Add('the embeddings port commit does not write the held value')}
        if(@(Get-SaCalls $pc 'ConvertTo-FastLlmUiNumericValue').Count -ne 1 -or @(Get-SaCalls $pc 'Step-FastLlmUiNumericValue').Count -ne 2){[void]$f.Add('the embeddings port does not use the shared clamp functions')}
    }
    foreach($caller in 'Resolve-FastLlmUiFluentSettingsExit','Invoke-FastLlmUiFluentSettingsSave'){
        $cf=Get-SaFn $Text $caller
        if($null -eq $cf -or @(Get-SaCalls $cf 'Invoke-FastLlmUiFluentSettingsEmbeddingPortCommit').Count -ne 1){[void]$f.Add("$caller does not commit the typed embeddings port first")}
    }
    $dis=Get-SaFn $Text 'Invoke-FastLlmUiFluentSettingsDiscard'
    if($null -eq $dis){[void]$f.Add('Invoke-FastLlmUiFluentSettingsDiscard is not defined once')}
    else{
        $h=@($dis.FindAll({param($n) $n -is [System.Management.Automation.Language.HashtableAst]},$true))
        $keys=@(); if($h.Count -eq 1){$keys=@($h[0].KeyValuePairs|ForEach-Object{[string]$_.Item1.Extent.Text})}
        foreach($k in 'contextProfile','slots','embeddings','embeddingPort'){ if($keys -cnotcontains $k){[void]$f.Add("Discard does not revert $k")} }
        foreach($pair in @(@('contextProfile','[string] $st[''Saved''].contextProfile'),@('slots','[int] $st[''Saved''].slots'),@('embeddings','[string] $st[''Saved''].embeddings'),@('embeddingPort','[int] $st[''Saved''].embeddingPort'))){
            if($h.Count -eq 1){ $kv=@($h[0].KeyValuePairs|Where-Object{[string]$_.Item1.Extent.Text -ceq $pair[0]}); if($kv.Count -eq 1 -and $kv[0].Item2.Extent.Text -cne $pair[1]){[void]$f.Add("Discard reverts $($pair[0]) from '$($kv[0].Item2.Extent.Text)', expected the saved value")} }
        }
    }
    $init=Get-SaFn $Text 'Initialize-FastLlmUiFluentSettings'
    if($null -eq $init){[void]$f.Add('Initialize-FastLlmUiFluentSettings is not defined once')}
    else{
        $named=@(Get-SaCalls $init 'Set-FastLlmUiFluentConnectInputName'|ForEach-Object{ $p=Get-SaCommandParams $_; "$($p['Box'])|$($p['Label'])|$($p['Text'])" })
        foreach($row in @("`$Els['SettingsContextProfileBox']|`$Els['SettingsContextProfileLabel']|([string] `$s.ContextProfile)","`$Els['SettingsRequestsBox']|`$Els['SettingsRequestsLabel']|([string] `$s.RequestsAtOnce)","`$Els['SettingsEmbeddingPortBox']|`$Els['SettingsEmbeddingPortLabel']|([string] `$s.EmbeddingPort)")){
            if($named -cnotcontains $row){[void]$f.Add("an input is not named and labelled from one string: $row")}
        }
        $ib=$init.Body.Extent.Text
        if($ib -cnotmatch [regex]::Escape("`$Els['SettingsEmbeddingsBox'].Content = ConvertTo-FastLlmUiAccessText -Text ([string] `$s.Embeddings) -UseMnemonic `$false") -or $ib -cnotmatch [regex]::Escape("SetName(`$Els['SettingsEmbeddingsBox'], [string] `$s.Embeddings)")){[void]$f.Add('the Embeddings check box is not named by its own caption')}
        foreach($ev in "`$Els['SettingsContextProfileBox'].Add_SelectionChanged({ param(`$sender, `$routed) Invoke-FastLlmUiFluentSettingsEdit })","`$Els['SettingsRequestsBox'].Add_SelectionChanged({ param(`$sender, `$routed) Invoke-FastLlmUiFluentSettingsEdit })","`$Els['SettingsEmbeddingsBox'].Add_Checked({ param(`$sender, `$routed) Invoke-FastLlmUiFluentSettingsEdit })","`$Els['SettingsEmbeddingsBox'].Add_Unchecked({ param(`$sender, `$routed) Invoke-FastLlmUiFluentSettingsEdit })"){
            if($ib -cnotmatch [regex]::Escape($ev)){[void]$f.Add("an edit is not wired: $ev")}
        }
    }
    return ,$f.ToArray()
}
$saEditReal=Get-SaEditFindings $settingsText
foreach($x in $saEditReal){Write-Host "FINDING: $x"}
Check ($settingsText -ne '' -and $saEditReal.Count -eq 0) 'the four edits write the held values, the embeddings port uses the shared 1024..65535 clamp, Discard reverts all four, and each input is named and labelled from one string'
Test-SaPlant 'the edit pin flags requests at once held as a literal' $settingsText.Replace("`$held.slots = [int] `$(if ([int] `$e['SettingsRequestsBox'].SelectedIndex -eq 1) { 2 } else { 1 })","`$held.slots = [int] 2") $settingsText ${function:Get-SaEditFindings}
Test-SaPlant 'the edit pin flags the context profile ignoring its control' $settingsText.Replace("`$held.contextProfile = [string] `$(if ([int] `$e['SettingsContextProfileBox'].SelectedIndex -eq 1) { 'long' } else { 'default' })","`$held.contextProfile = 'default'") $settingsText ${function:Get-SaEditFindings}
Test-SaPlant 'the edit pin flags Embeddings held inverted' $settingsText.Replace("IsChecked -eq `$true) { 'on' } else { 'off' })","IsChecked -eq `$true) { 'off' } else { 'on' })") $settingsText ${function:Get-SaEditFindings}
Test-SaPlant 'the edit pin flags an embeddings port clamp that reaches 65536' $settingsText.Replace('-Minimum ([decimal] 1024) -Maximum ([decimal] 65535)','-Minimum ([decimal] 1024) -Maximum ([decimal] 65536)') $settingsText ${function:Get-SaEditFindings}
Test-SaPlant 'the edit pin flags Discard not reverting the embeddings port' $settingsText.Replace('; embeddingPort = [int] $st[''Saved''].embeddingPort','') $settingsText ${function:Get-SaEditFindings}
Test-SaPlant 'the edit pin flags Discard reverting slots to a literal' $settingsText.Replace('slots = [int] $st[''Saved''].slots','slots = 1') $settingsText ${function:Get-SaEditFindings}
Test-SaPlant 'the edit pin flags an input labelled by another string' $settingsText.Replace("-Label `$Els['SettingsRequestsLabel'] -Text ([string] `$s.RequestsAtOnce)","-Label `$Els['SettingsRequestsLabel'] -Text ([string] `$s.ContextProfile)") $settingsText ${function:Get-SaEditFindings}
Test-SaPlant 'the edit pin flags Save not committing the typed embeddings port' $settingsText.Replace("    Invoke-FastLlmUiFluentSettingsPortCommit -Direction ''`n    Invoke-FastLlmUiFluentSettingsEmbeddingPortCommit -Direction ''`n    # A fluent-only guard: Settings","    Invoke-FastLlmUiFluentSettingsPortCommit -Direction ''`n    # A fluent-only guard: Settings") $settingsText ${function:Get-SaEditFindings}
Test-SaPlant 'the edit pin flags a requests box that is not wired' $settingsText.Replace("    `$Els['SettingsRequestsBox'].Add_SelectionChanged({ param(`$sender, `$routed) Invoke-FastLlmUiFluentSettingsEdit })`n",'') $settingsText ${function:Get-SaEditFindings}

# ---- (g) the four new saved-note literals of Get-FastLlmUiSettingsSavedNote, as literals read from the function's AST ----
$approvedNotesSa=@('The new context profile applies at the next start.','The new requests at once setting applies at the next start.','The new embeddings setting applies at the next start.','The new embeddings port applies at the next start.')
function Get-SaNoteFindings([string]$Text){
    $f=New-Object System.Collections.ArrayList
    $fn=Get-SaFn $Text 'Get-FastLlmUiSettingsSavedNote'
    if($null -eq $fn){[void]$f.Add('Get-FastLlmUiSettingsSavedNote is not defined once');return ,$f.ToArray()}
    $consts=@($fn.FindAll({param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst]},$true)|ForEach-Object{[string]$_.Value})
    foreach($lit in $approvedNotesSa){
        $c=@($consts|Where-Object{$_ -ceq $lit}).Count
        if($c -ne 1){[void]$f.Add("the saved note literal '$lit' appears $c times, expected exactly 1")}
    }
    return ,$f.ToArray()
}
$flowSaText=[IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.UiFlow.ps1'))
$saNoteReal=Get-SaNoteFindings $flowSaText
foreach($x in $saNoteReal){Write-Host "FINDING: $x"}
Check ($saNoteReal.Count -eq 0) 'the four Settings additions saved-note literals each appear exactly once in Get-FastLlmUiSettingsSavedNote'
Test-SaPlant 'the saved-note pin flags a one-character change to the context profile note' $flowSaText.Replace('The new context profile applies at the next start.','The new context profile applies at next start.') $flowSaText ${function:Get-SaNoteFindings}
Test-SaPlant 'the saved-note pin flags a one-character change to the embeddings port note' $flowSaText.Replace('The new embeddings port applies at the next start.','The new embeddings ports applies at the next start.') $flowSaText ${function:Get-SaNoteFindings}
Test-SaPlant 'the saved-note pin flags a dropped embeddings note' $flowSaText.Replace('The new embeddings setting applies at the next start.','x') $flowSaText ${function:Get-SaNoteFindings}
Test-SaPlant 'the saved-note pin flags a duplicated requests note' $flowSaText.Replace("return 'The new embeddings port applies at the next start.'","return 'The new requests at once setting applies at the next start.'") $flowSaText ${function:Get-SaNoteFindings}
# CONTROLS (permanent): the real text with only a comment appended is flagged by NO finder, so a counter or finder that flags everything (or a vacuous count) fails.
Test-SaControl 'the save-argument finder' $settingsText ${function:Get-SaSaveArgFindings}
Test-SaControl 'the A3 guard finder' $settingsText ${function:Get-SaGuardFindings}
Test-SaControl 'the Long guard finder' $settingsText ${function:Get-SaLongGuardFindings}
Test-SaControl 'the 2 guard finder' $settingsText ${function:Get-SaTwoGuardFindings}
Test-SaControl 'the context guard finder' $settingsText ${function:Get-SaCatalogGuardFindings}
Test-SaControl 'the live region finder' $settingsText ${function:Get-SaLiveFindings}
Test-SaControl 'the inline finder' $settingsText ${function:Get-SaInlineFindings}
Test-SaControl 'the view finder' $settingsText ${function:Get-SaViewFindings}
Test-SaControl 'the probe finder' $settingsText ${function:Get-SaProbeFindings}
Test-SaControl 'the edit finder' $settingsText ${function:Get-SaEditFindings}
Test-SaControl 'the saved-note finder' $flowSaText ${function:Get-SaNoteFindings}
# ===== end Settings additions (Task S2) =====

Write-Host "UI fluent member coverage tests passed: $checks"
