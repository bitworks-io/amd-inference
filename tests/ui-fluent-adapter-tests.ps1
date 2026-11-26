#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/FastLlm.UiFluentAdapter.ps1')
$checks=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:checks++}
function Throws([scriptblock]$Block,[string]$Member,[string]$Label){
    $msg=$null; try{& $Block}catch{$msg=$_.Exception.Message}
    Check ($null -ne $msg) "$Label : did not throw"
    Check ($msg -like "*$Member*") "$Label : message names $Member (got: $msg)"
}
$kinds='Button','Label','LinkLabel','TextBox','ComboBox','NumericUpDown','CheckBox','ProgressBar','ToolTip'
$table=Get-FastLlmUiAdapterMemberTable

foreach($k in $kinds){
    $a=New-FastLlmUiAdapter -Kind $k -Name "n$k"
    Check ($a.__kind -ceq $k -and $a.__name -ceq "n$k") "$k identity"
    Check ($table.Contains($k)) "$k in table"
    # unknown members throw on get and set
    Throws { $null=$a.NoSuchMember } 'NoSuchMember' "$k get unknown"
    Throws { $a.NoSuchMember=1 } 'NoSuchMember' "$k set unknown"
    # every table member exists
    $spec=$table[$k]
    foreach($m in @($spec.Values)+@($spec.Layout)+@($spec.ReadOnly)+@($spec.Methods)){Check ($null -ne ($a.psobject.Members[$m])) "$k has $m"}
    foreach($e in $spec.Events){Check ($null -ne ($a.psobject.Members['Add_'+$e])) "$k has Add_$e"}
    # text round trip + sink + event once per change
    $got=@(); $sinkCalls=New-Object System.Collections.ArrayList
    Set-FastLlmUiAdapterSink -Adapter $a -Sink { param($Property,$Value) [void]$sinkCalls.Add("$Property=$Value") }
    $fired=New-Object System.Collections.ArrayList
    $a.Add_TextChanged({ param($sender,$e) [void]$fired.Add($sender.__name) })
    $a.Text='x'
    Check ($a.Text -ceq 'x') "$k text round trip"
    Check ($sinkCalls[0] -ceq 'Text=x') "$k sink receives Text"
    Check ($fired.Count -eq 1 -and $fired[0] -ceq "n$k") "$k TextChanged once, sender is adapter"
    $a.Text='x'
    Check ($fired.Count -eq 1) "$k TextChanged not fired for unchanged"
    $a.Text='X'
    Check ($fired.Count -eq 2) "$k TextChanged is case sensitive"
    $a.Enabled=$false; $a.Visible=$false
    Check ((-not $a.Enabled) -and (-not $a.Visible)) "$k Enabled/Visible"
    Check ($sinkCalls -contains 'Enabled=False') "$k sink Enabled"

    # every Values member: distinct value, get returns it, sink got exactly (member, value)
    $b2=New-FastLlmUiAdapter -Kind $k -Name "v$k"
    if($k -ceq 'ComboBox'){[void]$b2.Items.Add('i0');[void]$b2.Items.Add('i1');[void]$b2.Items.Add('i2')}
    $pairs=New-Object System.Collections.ArrayList
    Set-FastLlmUiAdapterSink -Adapter $b2 -Sink { param($Property,$Value) [void]$pairs.Add(@($Property,$Value)) }
    foreach($m in $spec.Values){
        $cur=$b2.$m
        if($cur -is [bool]){$v=-not $cur}elseif($m -ceq 'SelectedIndex'){$v=2}elseif($cur -is [int]){$v=42}else{$v="v-$m"}
        $pairs.Clear(); $b2.$m=$v
        Check ($b2.$m -eq $v) "$k $m get returns set value"
        Check ($pairs.Count -eq 1 -and $pairs[0][0] -ceq $m -and $pairs[0][1] -eq $v) "$k $m sink received ($m,$v)"
    }
    # every Layout member: round trip
    foreach($m in $spec.Layout){
        $cur=$b2.$m
        if($cur -is [bool]){$v=-not $cur}elseif($cur -is [int]){$v=42}else{$v="v-$m"}
        $b2.$m=$v
        Check ($b2.$m -eq $v) "$k $m layout round trip"
    }
    # every ReadOnly member: get works, set throws
    foreach($m in $spec.ReadOnly){
        $null=$b2.$m
        $thrown=$false; try{$b2.$m=1}catch{$thrown=$true}
        Check $thrown "$k $m is read-only"
    }
}

# UseMnemonic defaults
foreach($k in 'Button','CheckBox','LinkLabel'){Check ((New-FastLlmUiAdapter -Kind $k -Name 'm').UseMnemonic) "$k UseMnemonic default true"}
$l=New-FastLlmUiAdapter -Kind Label -Name 'l'; $l.UseMnemonic=$false; Check (-not $l.UseMnemonic) 'Label UseMnemonic settable'

# layout
$b=New-FastLlmUiAdapter -Kind Button -Name 'b'; $b.Left=10; $b.Width=5
Check ($b.Left -eq 10 -and $b.Right -eq 15) 'layout Left/Width/Right'
$b.Font=$null; Check ($null -eq $b.Font) 'Font settable'

# CheckBox
$c=New-FastLlmUiAdapter -Kind CheckBox -Name 'c'; $n=0
$c.Add_CheckedChanged({ param($sender,$e) $script:n++ })
Check (-not $c.Checked) 'Checked default'
$c.Checked=$true; $c.Checked=$true
Check ($c.Checked -and $n -eq 1) 'CheckedChanged once per change'
$c.Checked=$false; Check ($n -eq 2) 'CheckedChanged on revert'

# ComboBox
$cb=New-FastLlmUiAdapter -Kind ComboBox -Name 'cb'; $n=0
$cb.Add_SelectedIndexChanged({ param($sender,$e) $script:n++ })
Check ($cb.Items.Add('a') -eq 0 -and $cb.Items.Add('b') -eq 1 -and $cb.Items.Count -eq 2) 'Items.Add returns index'
Check ($cb.Items[1] -ceq 'b' -and $cb.Items.Item(0) -ceq 'a') 'Items indexer'
Check ($null -eq $cb.SelectedItem -and $cb.SelectedIndex -eq -1) 'SelectedItem null when none'
$cb.SelectedIndex=1; $cb.SelectedIndex=1
Check ($cb.SelectedItem -ceq 'b' -and $n -eq 1) 'SelectedItem follows SelectedIndex, event once'
$cb.SelectedIndex=0; Check ($cb.SelectedItem -ceq 'a' -and $n -eq 2) 'SelectedItem follows again'
Throws { $cb.SelectedIndex=-2 } 'SelectedIndex' 'SelectedIndex -2 throws'
Throws { $cb.SelectedIndex=$cb.Items.Count } 'SelectedIndex' 'SelectedIndex Count throws'
$ae=$null; try{$cb.SelectedIndex=2}catch{$ae=$_.Exception;while($null -ne $ae.InnerException){$ae=$ae.InnerException}}
Check ($ae -is [System.ArgumentOutOfRangeException]) 'SelectedIndex throws ArgumentOutOfRangeException'
Check ($cb.SelectedIndex -eq 0) 'failed set leaves the index'
$cb.SelectedIndex=-1; Check ($cb.SelectedIndex -eq -1 -and $null -eq $cb.SelectedItem) 'SelectedIndex -1 accepted'

# NumericUpDown
$nu=New-FastLlmUiAdapter -Kind NumericUpDown -Name 'nu'
$nu.Maximum=262144; $nu.Increment=1024; $nu.Value=4096
Check ($nu.Maximum -eq 262144 -and $nu.Increment -eq 1024 -and $nu.Value -eq 4096) 'NumericUpDown round trip'

# TextBox
$tb=New-FastLlmUiAdapter -Kind TextBox -Name 'tb'; $n=0; $calls=New-Object System.Collections.ArrayList
Set-FastLlmUiAdapterSink -Adapter $tb -Sink { param($Property,$Value) [void]$calls.Add("$Property=$Value") }
$tb.Add_TextChanged({ param($sender,$e) $script:n++ })
$tb.AppendText('ab'); $tb.AppendText('cd')
Check ($tb.Text -ceq 'abcd' -and $tb.TextLength -eq 4 -and $n -eq 2) 'AppendText concatenates and raises TextChanged'
Check ($tb.SelectionStart -eq 4) 'AppendText moves SelectionStart to the end'
$tb.SelectionStart=1; Check ($tb.SelectionStart -eq 1) 'SelectionStart settable'
$calls.Clear(); $tb.ScrollToCaret()
Check ($calls.Count -eq 1 -and $calls[0] -ceq 'ScrollToEnd=True') 'ScrollToCaret sends ScrollToEnd'
Throws { $null=$tb.Items } 'Items' 'TextBox has no Items'

# ToolTip
$tt=New-FastLlmUiAdapter -Kind ToolTip -Name 'tt'; $tt.SetToolTip($b,'hi')
Check $true 'SetToolTip is a no-op'

# Events: sender and args, order
$bt=New-FastLlmUiAdapter -Kind Button -Name 'bt'; $order=New-Object System.Collections.ArrayList
$bt.Add_Click({ param($sender,$e) [void]$order.Add("1:$($sender.__name):$($e.GetType().Name)") })
$bt.Add_Click({ param($sender,$e) [void]$order.Add('2') })
Invoke-FastLlmUiAdapterEvent -Adapter $bt -Event Click
Check (($order -join '|') -ceq '1:bt:EventArgs|2') 'handlers run in order with ($sender,$e)'
$sent=$null; $bt.Add_Click({ param($sender,$e) $script:sent=$e })
$o=New-Object psobject; Invoke-FastLlmUiAdapterEvent -Adapter $bt -Event Click -EventArgs $o
Check ([object]::ReferenceEquals($sent,$o)) 'explicit EventArgs passed through'
Throws { Invoke-FastLlmUiAdapterEvent -Adapter $bt -Event Nope } 'Nope' 'unknown event throws'
$ln=New-FastLlmUiAdapter -Kind LinkLabel -Name 'ln'; $got=$null
$ln.Add_LinkClicked({ param($sender,$e) $script:got=$e })
Invoke-FastLlmUiAdapterEvent -Adapter $ln -Event LinkClicked
Check ($null -ne $got) 'LinkClicked delivers args'
Throws { $bt.Add_LinkClicked({}) } 'Add_LinkClicked' 'Button has no LinkClicked'

# Click on CheckBox and LinkLabel
foreach($k in 'CheckBox','LinkLabel'){
    $x=New-FastLlmUiAdapter -Kind $k -Name "x$k"; $hit=$null
    $x.Add_Click({ param($sender,$e) $script:hit=$sender.__name })
    Invoke-FastLlmUiAdapterEvent -Adapter $x -Event Click
    Check ($hit -ceq "x$k") "$k Click raised with sender"
}

# The unknown-member throw on get relies on the caller's StrictMode 2
$u=New-FastLlmUiAdapter -Kind Button -Name 'u'
$strictThrows=& { Set-StrictMode -Version 2; try{$null=$u.NoSuchMember;$false}catch{$true} }
Check $strictThrows 'unknown get throws under StrictMode 2 in a child scope'
$looseNull=& { Set-StrictMode -Off; $null -eq $u.NoSuchMember }
Check $looseNull 'unknown get returns null without StrictMode (the documented dependency)'

# Access text
Check ((ConvertTo-FastLlmUiAccessText -Text 'Install && start' -UseMnemonic $true) -ceq 'Install & start') 'access: &&'
$s='Settings'+[char]0x2026
Check ((ConvertTo-FastLlmUiAccessText -Text $s -UseMnemonic $true) -ceq $s) 'access: ellipsis unchanged'
Check ((ConvertTo-FastLlmUiAccessText -Text '&Save' -UseMnemonic $true) -ceq '_Save') 'access: &S'
Check ((ConvertTo-FastLlmUiAccessText -Text 'a_b' -UseMnemonic $true) -ceq 'a__b') 'access: underscore'
$t='Not running. Install & start '+[char]0x2026
Check ((ConvertTo-FastLlmUiAccessText -Text $t -UseMnemonic $false) -ceq $t) 'access: no mnemonic unchanged'
Check ((ConvertTo-FastLlmUiAccessText -Text '' -UseMnemonic $true) -ceq '') 'access: empty'
Check ((ConvertTo-FastLlmUiAccessText -Text 'a_b' -UseMnemonic $false) -ceq 'a__b') 'access: no mnemonic escapes underscore'
Check ((ConvertTo-FastLlmUiAccessText -Text 'a & b' -UseMnemonic $false) -ceq 'a & b') 'access: no mnemonic keeps ampersand'
Check ((ConvertTo-FastLlmUiAccessText -Text 'a && b_c' -UseMnemonic $false) -ceq 'a && b__c') 'access: no mnemonic keeps double ampersand'
Check ((ConvertTo-FastLlmUiDisplayText -Text 'Install && start' -UseMnemonic $true) -ceq 'Install & start') 'display: &&'
Check ((ConvertTo-FastLlmUiDisplayText -Text '&Save a_b' -UseMnemonic $true) -ceq 'Save a_b') 'display: &S and underscore kept'
Check ((ConvertTo-FastLlmUiDisplayText -Text 'Tail &' -UseMnemonic $true) -ceq 'Tail ') 'display: lone trailing ampersand dropped'
Check ((ConvertTo-FastLlmUiDisplayText -Text 'a && b_c &x' -UseMnemonic $false) -ceq 'a && b_c &x') 'display: no mnemonic unchanged'
Check ((ConvertTo-FastLlmUiDisplayText -Text '' -UseMnemonic $true) -ceq '') 'display: empty'


# Joined sinks (one adapter on two elements): both run, in order, with the same property and value
$log=New-Object System.Collections.ArrayList
$s1={param($Property,$Value) [void]$log.Add("1:${Property}=$Value")}.GetNewClosure()
$s2={param($Property,$Value) [void]$log.Add("2:${Property}=$Value")}.GetNewClosure()
$joined=Join-FastLlmUiFluentSinks -First $s1 -Second $s2
& $joined 'Text' 'abc'
Check (($log -join '|') -ceq '1:Text=abc|2:Text=abc') 'joined sinks run in order'
$tri=Join-FastLlmUiFluentSinks -First $joined -Second {param($Property,$Value) [void]$log.Add("3:$Property")}.GetNewClosure()
$log.Clear(); & $tri 'Enabled' $true
Check (($log -join '|') -ceq '1:Enabled=True|2:Enabled=True|3:Enabled') 'a joined sink joins again, in order'

# Add-FastLlmUiAdapterSink: the first bind sets, -Also joins, a bind without -Also on a bound adapter throws
$j=New-FastLlmUiAdapter -Kind Button -Name 'j'
$log.Clear()
Add-FastLlmUiAdapterSink -Adapter $j -Sink $s1
Add-FastLlmUiAdapterSink -Adapter $j -Sink $s2 -Also
$j.Text='x'
Check (($log -join '|') -ceq '1:Text=x|2:Text=x') 'Also joins the second sink to the first: one write reaches both, in order'
$j.Enabled=$false
Check ($log.Count -eq 4 -and $log[3] -ceq '2:Enabled=False') 'the joined adapter keeps writing to both sinks'
Throws { Add-FastLlmUiAdapterSink -Adapter $j -Sink $s1 } 'bound twice' 'a second bind without Also throws'
$k2=New-FastLlmUiAdapter -Kind Button -Name 'k2'
$log.Clear()
Add-FastLlmUiAdapterSink -Adapter $k2 -Sink $s2 -Also
$k2.Text='y'
Check (($log -join '|') -ceq '2:Text=y') 'Also on an unbound adapter binds (join if bound, else bind)'
# A reversed table (the page row with Also first, then the Home row without it) fails loudly.
$rev=New-FastLlmUiAdapter -Kind Button -Name 'rev'
Add-FastLlmUiAdapterSink -Adapter $rev -Sink $s2 -Also
Throws { Add-FastLlmUiAdapterSink -Adapter $rev -Sink $s1 } 'rev' 'a reversed table throws at the row without Also'


# --- PR 3b Task 2: the number clamp (WinForms ParseEditText), the one element write, and the wiring pins ---
$savedCulture=[Threading.Thread]::CurrentThread.CurrentCulture
[Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo('en-US')
try{
    $clampRows=@(
        @{T='';E=7},@{T='abc';E=7},@{T='-5';E=0},@{T='40000';E=32768},@{T='2048';E=2048},@{T=' 4096 ';E=4096},
        @{T='1,024';E=1024},@{T='1500.7';E=[decimal]1500.7},@{T='0x10';E=7},@{T='32768';E=32768},@{T='0';E=0})
    foreach($r in $clampRows){
        $v=ConvertTo-FastLlmUiNumericValue -Text $r.T -Current 7 -Minimum 0 -Maximum 32768
        Check (@($v).Count -eq 1 -and $v -is [decimal]) "clamp '$($r.T)': one decimal"
        Check ($v -eq [decimal]$r.E) "clamp '$($r.T)' (0..32768): expected $($r.E), got $v"
    }
    Check ((ConvertTo-FastLlmUiNumericValue -Text '80' -Current 5000 -Minimum 1024 -Maximum 65535) -eq 1024) 'port clamp: 80 rises to 1024'
    Check ((ConvertTo-FastLlmUiNumericValue -Text '70000' -Current 5000 -Minimum 1024 -Maximum 65535) -eq 65535) 'port clamp: 70000 falls to 65535 (a 32768-only mutant clamps wrong)'
    Check ((ConvertTo-FastLlmUiNumericValue -Text '40000' -Current 5000 -Minimum 0 -Maximum 32768) -eq 32768) 'context clamp: 40000 is 32768, not 65535'
    Check ((ConvertTo-FastLlmUiNumericValue -Text 'x' -Current 5000 -Minimum 1024 -Maximum 65535) -eq 5000) 'port clamp: a parse failure keeps Current'
}finally{[Threading.Thread]::CurrentThread.CurrentCulture=$savedCulture}

Check ((Step-FastLlmUiNumericValue -Current 1024 -Increment 1024 -Minimum 0 -Maximum 32768 -Up) -eq 2048) 'step up'
Check ((Step-FastLlmUiNumericValue -Current 1024 -Increment 1024 -Minimum 0 -Maximum 32768) -eq 0) 'step down to the minimum'
Check ((Step-FastLlmUiNumericValue -Current 32768 -Increment 1024 -Minimum 0 -Maximum 32768 -Up) -eq 32768) 'step up stops at the maximum'
Check ((Step-FastLlmUiNumericValue -Current 500 -Increment 1024 -Minimum 0 -Maximum 32768) -eq 0) 'step down clamps at 0'
Check ((Step-FastLlmUiNumericValue -Current 0 -Increment 1024 -Minimum 0 -Maximum 32768) -eq 0) 'step down at the minimum stays'
Check ((Step-FastLlmUiNumericValue -Current 65535 -Increment 1 -Minimum 1024 -Maximum 65535 -Up) -eq 65535) 'port step up stops at 65535'
Check ((Step-FastLlmUiNumericValue -Current 1024 -Increment 1 -Minimum 1024 -Maximum 65535) -eq 1024) 'port step down stops at 1024'
$stepOut=Step-FastLlmUiNumericValue -Current 1 -Increment 1 -Minimum 0 -Maximum 5 -Up
Check (@($stepOut).Count -eq 1 -and $stepOut -is [decimal]) 'step returns one decimal'

# One element write: one event, the sink sees FromElement true, the flag clears (also after a throw), a same-value write is silent.
$cb=New-FastLlmUiAdapter -Kind ComboBox -Name 'cb'
foreach($i in 'a','b','c'){[void]$cb.Items.Add($i)}
$seen=New-Object System.Collections.ArrayList; $evs=New-Object System.Collections.ArrayList
Set-FastLlmUiAdapterSink -Adapter $cb -Sink { param($Property,$Value) [void]$seen.Add(('{0}={1}/{2}' -f $Property,$Value,[bool]$cb.__state['FromElement'])) }.GetNewClosure()
$cb.Add_SelectedIndexChanged({ param($sender,$e) [void]$evs.Add([bool]$sender.__state['FromElement']) }.GetNewClosure())
$out=Set-FastLlmUiAdapterFromElement -Adapter $cb -Property SelectedIndex -Value 1
Check ($null -eq $out) 'the element write returns nothing'
Check ($cb.SelectedIndex -eq 1) 'the element write sets the member'
Check ($evs.Count -eq 1 -and $evs[0]) 'one element write raises exactly one change event, with FromElement set in the handler'
Check ($seen.Count -eq 1 -and $seen[0] -ceq 'SelectedIndex=1/True') 'the sink saw the write once with FromElement true'
Check (-not [bool]$cb.__state['FromElement']) 'FromElement is clear after the write'
Set-FastLlmUiAdapterFromElement -Adapter $cb -Property SelectedIndex -Value 1
Check ($evs.Count -eq 1) 'a same-value element write raises nothing'
$cb.SelectedIndex=2
Check ($evs.Count -eq 2 -and -not $evs[1]) 'a code write (not from the element) raises with FromElement clear'
$cb.Add_SelectedIndexChanged({ throw 'boom' })
$threw=$false; try{Set-FastLlmUiAdapterFromElement -Adapter $cb -Property SelectedIndex -Value 0}catch{$threw=$true}
Check $threw 'a throwing handler propagates'
Check (-not [bool]$cb.__state['FromElement']) 'FromElement is clear after a throwing handler'

$num=New-FastLlmUiAdapter -Kind NumericUpDown -Name 'num'
$numSeen=New-Object System.Collections.ArrayList
Set-FastLlmUiAdapterSink -Adapter $num -Sink { param($Property,$Value) [void]$numSeen.Add("$Property=$Value") }.GetNewClosure()
Set-FastLlmUiAdapterFromElement -Adapter $num -Property Value -Value ([decimal]2048)
Check ($num.Value -eq 2048 -and $numSeen.Count -eq 1 -and $numSeen[0] -ceq 'Value=2048') 'a number commit is one Value write'
$tb=New-FastLlmUiAdapter -Kind TextBox -Name 'tb'; $tbEv=0
$tb.Add_TextChanged({ $script:tbEv++ })
Set-FastLlmUiAdapterFromElement -Adapter $tb -Property Text -Value 'k'
Check ($tbEv -eq 1 -and $tb.Text -ceq 'k') 'one keystroke is one Text write and one TextChanged'

# macOS wiring pins over the real Home.ps1 (a text that can be mutated). Returns the list of problems; empty means every pin holds.
function Get-WiringProblems([string]$Source){
    $problems=New-Object System.Collections.ArrayList
    $err=$null; $ast=[System.Management.Automation.Language.Parser]::ParseInput($Source,[ref]$null,[ref]$err)
    if($err.Count -gt 0){[void]$problems.Add('does not parse');return $problems}
    $fnOf={param($name) @($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))}
    $conn=@(& $fnOf 'Connect-FastLlmUiFluentControl')
    $sinkFn=@(& $fnOf 'New-FastLlmUiFluentSink')
    if($conn.Count -ne 1 -or $sinkFn.Count -ne 1){[void]$problems.Add('functions missing');return $problems}
    $callsOf={param($root,$var) @($root.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.InvocationOperator -eq 'Ampersand' -and $n.CommandElements[0].Extent.Text -ceq $var},$true)).Count}
    $attach=@($conn[0].Body.FindAll({param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Extent.Text -clike 'Add_*'},$true))
    # The Number keys are read in PreviewKeyDown: a TextBox's class handler marks Up and Down handled before instance KeyDown handlers run.
    $want=@{SelectionChanged='$setFrom';TextChanged='$setFrom';PreviewKeyDown='$commit';LostKeyboardFocus='$commit'}
    foreach($ev in 'SelectionChanged','TextChanged','PreviewKeyDown','LostKeyboardFocus'){
        $m=@($attach | Where-Object { $_.Member.Extent.Text -ceq "Add_$ev" })
        if($m.Count -ne 1){[void]$problems.Add("Add_$ev attached $($m.Count) times, expected 1");continue}
        $sb=@($m[0].Arguments[0].FindAll({param($n) $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst]},$true))
        if($sb.Count -lt 1){[void]$problems.Add("Add_$ev has no handler block");continue}
        $n=& $callsOf $sb[0] $want[$ev]
        if($n -ne 1){[void]$problems.Add("Add_$ev handler calls $($want[$ev]) $n times, expected 1")}
    }
    $commitDef=@($conn[0].Body.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$commit'},$true))
    if($commitDef.Count -ne 1){[void]$problems.Add('$commit is not defined exactly once')}
    else{$n=& $callsOf $commitDef[0].Right '$setFrom'; if($n -ne 1){[void]$problems.Add("the number commit calls Set-FastLlmUiAdapterFromElement $n times, expected 1")}}
    $setDef=@($conn[0].Body.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$setFrom' -and $n.Right.Extent.Text -like '*Set-FastLlmUiAdapterFromElement*'},$true))
    if($setDef.Count -ne 1){[void]$problems.Add('$setFrom is not the Set-FastLlmUiAdapterFromElement function')}
    foreach($mode in 'Combo','Number','Input'){
        $ifs=@($sinkFn[0].Body.FindAll({param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -match ("-ceq '"+$mode+"'")},$true))
        if($ifs.Count -ne 1){[void]$problems.Add("sink has $($ifs.Count) $mode branches, expected 1");continue}
        if($ifs[0].Clauses[0].Item2.Extent.Text -cnotmatch "FromElement"){[void]$problems.Add("the sink's $mode branch does not check FromElement")}
    }
    return $problems
}
$homeText=[IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.UiFluentHome.ps1'))
$base=@(Get-WiringProblems $homeText)
Check ($base.Count -eq 0) ("the wiring pins hold on Home.ps1: "+($base -join '; '))
function Test-Plant([string]$Label,[string]$From,[string]$To,[int]$Which=0){
    $idx=-1; for($i=0;$i -le $Which;$i++){$idx=$homeText.IndexOf($From,$idx+1,[StringComparison]::Ordinal); if($idx -lt 0){break}}
    Check ($idx -ge 0) "plant '$Label': the marker text exists in Home.ps1"
    $mut=$homeText.Substring(0,$idx)+$To+$homeText.Substring($idx+$From.Length)
    Check (@(Get-WiringProblems $mut).Count -gt 0) "plant '$Label' is caught by the wiring pins"
}
Test-Plant 'missing SelectionChanged attach' '.Add_SelectionChanged(' '.Add_SelectionChangedX('
Test-Plant 'missing TextChanged attach' '.Add_TextChanged(' '.Add_TextChangedX('
Test-Plant 'missing PreviewKeyDown attach' '.Add_PreviewKeyDown({' '.Add_PreviewKeyDownX({'
Test-Plant 'Number keys back in KeyDown' '$Element.Add_PreviewKeyDown({' '$Element.Add_KeyDown({'
Test-Plant 'missing LostKeyboardFocus attach' '.Add_LostKeyboardFocus(' '.Add_LostKeyboardFocusX('
Test-Plant 'combo handler double call' "-Property 'SelectedIndex'" "-Property 'SelectedIndex'; & `$setFrom -Adapter `$Adapter -Property 'SelectedIndex' -Value 0"
Test-Plant 'number commit double call' "-Property 'Value' -Value `$value" "-Property 'Value' -Value `$value; & `$setFrom -Adapter `$Adapter -Property 'Value' -Value 0"
Test-Plant 'combo branch loses the FromElement check' "if (`$Adapter.__state['FromElement']) { return }" "if (`$false) { return }" 0
Test-Plant 'number branch loses the FromElement check' "if (`$Adapter.__state['FromElement']) { return }" "if (`$false) { return }" 1
Test-Plant 'input branch loses the FromElement check' "if (`$Adapter.__state['FromElement']) { return }" "if (`$false) { return }" 2

Write-Host "UI fluent adapter tests passed: $checks"
