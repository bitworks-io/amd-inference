#requires -Version 5.1
# Member coverage for the Fluent window: every member the window script uses on an adapter-bound control name AFTER the rebinding seam
# must exist on that control's adapter kind (Get-FastLlmUiAdapterMemberTable), used the way the adapter allows (read, write or call).
# Pure: the window script is parsed, never run. Also checks the carried UpdateActive rule: every update run records its kind.
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
        if($n.Extent.StartLineNumber -le $AfterLine){continue}
        $name=([string]$n.Expression.VariablePath.UserPath) -replace '^script:',''
        if(-not $kinds.ContainsKey($name)){continue}
        # A function that assigns its own variable of the same name (a dialog's local $title) is not using the window's control.
        $owner=$n.Parent
        while($null -ne $owner -and $owner -isnot [System.Management.Automation.Language.FunctionDefinitionAst]){$owner=$owner.Parent}
        if($null -ne $owner){
            $shadow=@($owner.FindAll({param($a) $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and $a.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and ([string]$a.Left.VariablePath.UserPath) -ceq $name},$true))
            if($shadow.Count -gt 0){continue}
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
Check ($pre.Count -eq 0) 'self-check: uses before the seam are not scanned'

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

# Initialize-FastLlmUiFluentBindings rebinds with Set-Variable -Scope Script. The bindings file is dot-sourced into the window script, so
# "Script" is that script's own scope: proven with a scratch script that dot-sources it the same way and reads the names there.
$scratchDir=Join-Path ([IO.Path]::GetTempPath()) ('fastllm-bindings-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $scratchDir)
$scratch=Join-Path $scratchDir 'scope-proof.ps1'
$scratchText=@'
param([string]$Root,[string]$InstallRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
. (Join-Path $Root 'src/FastLlm.UiFluentAdapter.ps1')
. (Join-Path $Root 'src/FastLlm.Components.ps1')
. (Join-Path $Root 'src/FastLlm.UiFluentBindings.ps1')
$catalog=[pscustomobject]@{models=@([pscustomobject]@{id='m-one'},[pscustomobject]@{id='m-hidden';autoEligible=$false},[pscustomobject]@{id='m-two';autoEligible=$true})}
$settings=[pscustomobject]@{vulkanBarMitigation='on';updateCheck='on';experimentalComponents='off'}
function ReadFromFunction { return $modelBox }
$made=Initialize-FastLlmUiFluentBindings -InstallRoot $InstallRoot -Catalog $catalog -UiSettings $settings
[pscustomobject]@{
    names=@($made.Keys).Count
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
$proof=& $scratch -Root $root -InstallRoot $scratchDir
Check ($null -eq (Get-Variable -Name modelBox -Scope Script -ErrorAction SilentlyContinue)) 'the rebinding stayed in the scratch script, not in this test script'
Check ($proof.scriptScope -and $proof.sameObject -and $proof.viaFunction) 'Set-Variable -Scope Script rebinds the dot-sourcing script scope (also seen from a function defined there)'
Check ($proof.names -eq @(Get-FastLlmUiFluentControlTable).Count) 'one adapter per inventory name'
Check (($proof.items -join '|') -ceq 'Recommended for installed GPU|m-one|m-two') "model items are the default plus the eligible catalog ids (got $($proof.items -join '|'))"
Check ($proof.barIndex -eq 1 -and $proof.bar -ceq 'On') 'the BAR box follows the saved setting'
Check ($proof.path -ceq $scratchDir) 'the folder box shows the install root'
Check ($proof.update -and -not $proof.experimental -and -not $proof.license) 'check boxes follow the saved settings and the licence mode'
Check ($proof.ctxMax -eq 32768 -and $proof.ctxInc -eq 1024) 'the context box has the classic maximum and step'
Check (($proof.disabled -join ',') -ceq 'openChatButton,chooseButton,switchButton') 'open chat, choose and switch start disabled'
Check (@($proof.hidden).Count -eq 8) 'the eight hidden controls start hidden'
Check ($proof.install -ceq 'Install && start') 'a button keeps its classic text unchanged'
[void](Remove-Item -LiteralPath $scratch -Force)
[void](Remove-Item -LiteralPath $scratchDir -Force)

Write-Host "UI fluent member coverage tests passed: $checks"
