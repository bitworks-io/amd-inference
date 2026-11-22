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
    Invoke=@('Hide','Show','Activate','Close','Dispose','Add_Shown','Add_FormClosing')
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
$seamText="if (`$Window -ceq 'fluent') { Initialize-FastLlmUiFluentShell }"
$seamLines=@()
$lineNo=0
foreach($l in (Get-Content -LiteralPath $path)){$lineNo++;if($l -ceq $seamText){$seamLines+=$lineNo}}
Check ($seamLines.Count -eq 1) 'the rebinding seam line appears exactly once'
$seam=[int]$seamLines[0]

# Every control the inventory names is bound to a kind the table knows.
foreach($k in $kinds.Keys){Check (($k -ceq 'form') -or $table.Contains($kinds[$k])) "control $k has a known adapter kind"}
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
    # PR 3: Screen.FromControl needs a Control
    'GetUiSettingsDialogMaxHeight $form'='the settings dialog height cap reads the screen through Screen.FromControl (carried to PR 3)'
    # The classic startup branch (the fluent branch starts its own loop); pinned by ui-flow-tests.
    '[Windows.Forms.Application]::Run($form)'='classic-only startup, never reached with -Window fluent'
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
    return $null
}
function Get-FormBareUses([System.Management.Automation.Language.Ast]$Tree,[int]$AfterLine){
    $result=New-Object System.Collections.ArrayList
    $vars=$Tree.FindAll({param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and (([string]$n.VariablePath.UserPath) -replace '^script:','') -ceq 'form'},$true)
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
Check ($ownerCounts['ShowDialog'] -gt 0 -and $ownerCounts['MessageBox.Show'] -gt 0) 'the scan sees ShowDialog and MessageBox owner uses'
Check (@($formUses|Where-Object{$_.Kind -ceq 'allowed'}).Count -eq $bareAllow.Count) 'each allowlisted bare use appears exactly once (the allowlist has no dead entry)'
# NewUiApiKey takes the owner as a parameter and may only pass it on as a MessageBox owner.
$keyFn=$tree.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'NewUiApiKey'},$true)
Check ($null -ne $keyFn) 'NewUiApiKey is defined'
$ownerVars=@($keyFn.Body.FindAll({param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and ([string]$n.VariablePath.UserPath) -ceq 'Owner'},$true))
Check ($ownerVars.Count -ge 2 -and @($ownerVars|Where-Object{(Get-OwnerKind $_) -ceq 'MessageBox.Show'}).Count -eq $ownerVars.Count) 'NewUiApiKey uses its Owner only as a MessageBox owner'
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

# -Window is case-sensitive: -Window Fluent is refused instead of silently running the classic window.
$windowParam=@($tree.ParamBlock.Parameters|Where-Object{([string]$_.Name.VariablePath.UserPath) -ceq 'Window'})
Check ($windowParam.Count -eq 1) 'the window script has a -Window parameter'
$vs=@($windowParam[0].Attributes|Where-Object{$_ -is [System.Management.Automation.Language.AttributeAst] -and [string]$_.TypeName.Name -ceq 'ValidateSet'})
Check ($vs.Count -eq 1) '-Window has a ValidateSet'
Check (@($vs[0].PositionalArguments|ForEach-Object{[string]$_.Value}) -join ',' -ceq 'classic,fluent') '-Window accepts classic and fluent'
Check (@($vs[0].NamedArguments|Where-Object{[string]$_.ArgumentName -ceq 'IgnoreCase' -and [string]$_.Argument.Extent.Text -ceq '$false'}).Count -eq 1) '-Window ValidateSet has IgnoreCase=$false (-Window Fluent is refused)'

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
)
function Get-NormalizedText([string]$Path){
    $bytes=[IO.File]::ReadAllBytes($Path)
    $start=0; if($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF){$start=3}
    return ([Text.Encoding]::UTF8.GetString($bytes,$start,$bytes.Length-$start)).Replace("`r`n","`n")
}
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
Check ($namedChanges.Count -eq 11) 'eleven named changes are listed (param, support check, failureHeld start, ClearFailureCapture clear, seam, snapshot arguments, ShowFailure set, ShowFailure view text, GetUiTrayIcon, tray assignment, startup branch)'
$currentText=Get-NormalizedText $path
$undone=Undo-NamedChanges $currentText
foreach($pr in $undone.Problems){Write-Host "FINDING: $pr"}
Check ($undone.Problems.Count -eq 0) 'every named change is present exactly once'
Check ((Get-Sha256Text $undone.Text) -ceq $classicPinnedSha256) 'with the named changes undone, the window script is byte-identical to the classic window on main'
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

Write-Host "UI fluent member coverage tests passed: $checks"
