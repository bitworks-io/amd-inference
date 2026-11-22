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
    foreach($m in @($spec.Values)+@($spec.Layout)+@($spec.Methods)){Check ($null -ne ($a.psobject.Members[$m])) "$k has $m"}
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
$cb.SelectedIndex=9; Check ($null -eq $cb.SelectedItem) 'SelectedItem null out of range'

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
$tb.SelectionStart=$tb.TextLength; Check ($tb.SelectionStart -eq 4) 'SelectionStart'
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

# Access text
Check ((ConvertTo-FastLlmUiAccessText -Text 'Install && start' -UseMnemonic $true) -ceq 'Install & start') 'access: &&'
$s='Settings'+[char]0x2026
Check ((ConvertTo-FastLlmUiAccessText -Text $s -UseMnemonic $true) -ceq $s) 'access: ellipsis unchanged'
Check ((ConvertTo-FastLlmUiAccessText -Text '&Save' -UseMnemonic $true) -ceq '_Save') 'access: &S'
Check ((ConvertTo-FastLlmUiAccessText -Text 'a_b' -UseMnemonic $true) -ceq 'a__b') 'access: underscore'
$t='Not running. Install & start '+[char]0x2026
Check ((ConvertTo-FastLlmUiAccessText -Text $t -UseMnemonic $false) -ceq $t) 'access: no mnemonic unchanged'
Check ((ConvertTo-FastLlmUiAccessText -Text '' -UseMnemonic $true) -ceq '') 'access: empty'

Write-Host "UI fluent adapter tests passed: $checks"
