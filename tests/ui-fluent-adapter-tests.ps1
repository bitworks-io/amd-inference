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

Write-Host "UI fluent adapter tests passed: $checks"
