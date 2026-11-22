#requires -Version 5.1
# Control adapters for the Fluent window. Each adapter is a [pscustomobject] that stands in for one WinForms
# control, so the orchestration code can drive the new window unchanged. Pure: no WPF, no Windows-only calls.
# A member that is not defined throws on get and on set. The throw on get relies on the caller's StrictMode 2,
# which fast-llm-ui.ps1 sets; the throw on set is the object shape and holds in any mode.
# Internal note properties: __kind, __name, __state (hashtable), __handlers (event -> List[scriptblock]), __sink.

# The ONE table of members per kind. The member-coverage test reads it.
#   Values   : get/set members that call the sink and, where one exists, raise a change event
#   ReadOnly : get-only members (computed, or the Items collection)
#   Layout   : get/set stored members with no other effect
#   Events   : the Add_<Event> methods
#   Methods  : real calls
function Get-FastLlmUiAdapterMemberTable {
    [CmdletBinding()] param()
    $common=@('Text','Enabled','Visible')
    $layout=@('Left','Width','Height','Font','ForeColor','Location','Size','AutoSize','TabIndex','TabStop','AccessibleName')
    $text=@('AutoEllipsis','TextAlign','UseMnemonic','PreferredWidth')
    return [ordered]@{
        Button=@{Values=$common;Layout=$layout+$text;Events=@('Click','TextChanged');ReadOnly=@('Right');Methods=@()}
        Label=@{Values=$common;Layout=$layout+$text;Events=@('TextChanged');ReadOnly=@('Right');Methods=@()}
        LinkLabel=@{Values=$common;Layout=$layout+$text;Events=@('Click','LinkClicked','TextChanged');ReadOnly=@('Right');Methods=@()}
        CheckBox=@{Values=$common+@('Checked');Layout=$layout+$text;Events=@('Click','CheckedChanged','TextChanged');ReadOnly=@('Right');Methods=@()}
        ComboBox=@{Values=$common+@('SelectedIndex');Layout=$layout+@('DropDownStyle');Events=@('SelectedIndexChanged','TextChanged');ReadOnly=@('Right','Items','SelectedItem');Methods=@()}
        NumericUpDown=@{Values=$common+@('Value','Maximum','Increment');Layout=$layout;Events=@('TextChanged');ReadOnly=@('Right');Methods=@()}
        TextBox=@{Values=$common+@('SelectionStart');Layout=$layout+@('Multiline','ReadOnly','ScrollBars');Events=@('TextChanged');ReadOnly=@('Right','TextLength');Methods=@('AppendText','ScrollToCaret')}
        ProgressBar=@{Values=$common;Layout=$layout+@('Style');Events=@('TextChanged');ReadOnly=@('Right');Methods=@()}
        ToolTip=@{Values=$common;Layout=@();Events=@('TextChanged');ReadOnly=@();Methods=@('SetToolTip')}
    }
}

# WinForms access text (&& literal ampersand, &x access key) to WPF access text (__ literal underscore, _x access key).
function ConvertTo-FastLlmUiAccessText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text,[Parameter(Mandatory)][bool]$UseMnemonic)
    # No mnemonic: WinForms shows the text as is, so every underscore is escaped for WPF access text and the ampersand stays literal.
    if(-not $UseMnemonic){return $Text.Replace('_','__')}
    $sb=New-Object System.Text.StringBuilder
    for($i=0;$i -lt $Text.Length;$i++){
        $c=$Text[$i]
        if($c -ceq '&'){
            if($i+1 -ge $Text.Length){continue}
            $n=$Text[$i+1]; $i++
            if($n -ceq '&'){[void]$sb.Append('&')}
            elseif($n -ceq '_'){[void]$sb.Append('___')}
            else{[void]$sb.Append('_').Append($n)}
        }
        elseif($c -ceq '_'){[void]$sb.Append('__')}
        else{[void]$sb.Append($c)}
    }
    return $sb.ToString()
}

# What WinForms shows for a caption, as plain text (for a WPF TextBlock, which has no access keys). With a mnemonic: && is &, &x is x
# (the key is underlined in WinForms, not drawn here), and a lone trailing & is dropped, as WinForms does. Without one the text is unchanged.
function ConvertTo-FastLlmUiDisplayText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text,[Parameter(Mandatory)][bool]$UseMnemonic)
    if(-not $UseMnemonic){return $Text}
    $sb=New-Object System.Text.StringBuilder
    for($i=0;$i -lt $Text.Length;$i++){
        $c=$Text[$i]
        if($c -ceq '&'){
            if($i+1 -ge $Text.Length){continue}
            $i++
            [void]$sb.Append($Text[$i])
        }
        else{[void]$sb.Append($c)}
    }
    return $sb.ToString()
}

function New-FastLlmUiAdapter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Button','Label','LinkLabel','TextBox','ComboBox','NumericUpDown','CheckBox','ProgressBar','ToolTip')][string]$Kind,
        [Parameter(Mandatory)][string]$Name
    )
    $spec=(Get-FastLlmUiAdapterMemberTable)[$Kind]
    $a=[pscustomobject]@{__kind=$Kind;__name=$Name;__state=@{};__handlers=@{};__sink=$null}
    $st=$a.__state
    $changeEvent=@{Text='TextChanged';Checked='CheckedChanged';SelectedIndex='SelectedIndexChanged'}
    $defaults=@{Text='';Enabled=$true;Visible=$true;Checked=$false;SelectedIndex=-1;Value=0;Maximum=100;Increment=1;SelectionStart=0
        Left=0;Width=0;Height=0;Font=$null;ForeColor=$null;Location=$null;Size=$null;AutoSize=$false;TabIndex=0;TabStop=$true;AccessibleName=''
        AutoEllipsis=$false;TextAlign=$null;UseMnemonic=($Kind -in 'Button','CheckBox','LinkLabel','Label');PreferredWidth=0
        DropDownStyle=$null;Multiline=$false;ReadOnly=$false;ScrollBars=$null;Style=$null}
    if('System.Drawing.Font' -as [type]){try{$defaults.Font=New-Object System.Drawing.Font('Segoe UI',[single]10)}catch{$defaults.Font=$null}}

    foreach($ev in $spec.Events){$a.__handlers[$ev]=New-Object 'System.Collections.Generic.List[scriptblock]'}

    foreach($m in $spec.Values){
        $st[$m]=$defaults[$m]
        $raise=''
        if($changeEvent.ContainsKey($m)){
            $raise='if($changed){$e=[System.EventArgs]::Empty;foreach($h in @($this.__handlers[''@E''])){& $h $this $e}}'.Replace('@E',$changeEvent[$m])
        }
        $coerce=''; if($m -ceq 'Text'){$coerce='if($null -eq $v){$v=''''}else{$v=[string]$v}'}
        if($m -ceq 'SelectedIndex'){$coerce='if($v -lt -1 -or $v -ge $this.__state[''Items''].Count){throw [System.ArgumentOutOfRangeException]::new(''SelectedIndex'')}'}
        $setText=('param($v)'+"`n"+$coerce+"`n"+'$s=$this.__state;$old=$s[''@M'']'+"`n"+
            'if(($v -is [string]) -or ($old -is [string])){$changed=($old -cne $v)}else{$changed=($old -ne $v)}'+"`n"+
            '$s[''@M'']=$v'+"`n"+'$sk=$this.__sink;if($null -ne $sk){& $sk ''@M'' $v}'+"`n"+$raise).Replace('@M',$m)
        Add-Member -InputObject $a -MemberType ScriptProperty -Name $m -Value ([scriptblock]::Create('$this.__state[''@M'']'.Replace('@M',$m))) -SecondValue ([scriptblock]::Create($setText))
    }
    foreach($m in $spec.Layout){
        $st[$m]=$defaults[$m]
        Add-Member -InputObject $a -MemberType ScriptProperty -Name $m -Value ([scriptblock]::Create('$this.__state[''@M'']'.Replace('@M',$m))) -SecondValue ([scriptblock]::Create('param($v) $this.__state[''@M'']=$v'.Replace('@M',$m)))
    }
    if($spec.ReadOnly -contains 'Right'){
        Add-Member -InputObject $a -MemberType ScriptProperty -Name Right -Value ([scriptblock]::Create('$this.__state[''Left'']+$this.__state[''Width'']'))
    }
    foreach($ev in $spec.Events){
        Add-Member -InputObject $a -MemberType ScriptMethod -Name ('Add_'+$ev) -Value ([scriptblock]::Create('param($h) $this.__handlers[''@E''].Add($h)'.Replace('@E',$ev)))
    }
    if($Kind -ceq 'ComboBox'){
        $st['Items']=New-Object System.Collections.ArrayList
        Add-Member -InputObject $a -MemberType ScriptProperty -Name Items -Value {,$this.__state['Items']}
        Add-Member -InputObject $a -MemberType ScriptProperty -Name SelectedItem -Value {
            $i=$this.__state['SelectedIndex'];$l=$this.__state['Items']
            if($i -ge 0 -and $i -lt $l.Count){$l[$i]}else{$null}}
    }
    if($Kind -ceq 'TextBox'){
        Add-Member -InputObject $a -MemberType ScriptProperty -Name TextLength -Value {$this.__state['Text'].Length}
        Add-Member -InputObject $a -MemberType ScriptMethod -Name AppendText -Value {param($s) $this.Text=$this.__state['Text']+[string]$s;$this.SelectionStart=$this.__state['Text'].Length}
        Add-Member -InputObject $a -MemberType ScriptMethod -Name ScrollToCaret -Value {$sk=$this.__sink;if($null -ne $sk){& $sk 'ScrollToEnd' $true}}
    }
    if($Kind -ceq 'ToolTip'){
        Add-Member -InputObject $a -MemberType ScriptMethod -Name SetToolTip -Value {param($control,$text)}
    }
    return $a
}

function Set-FastLlmUiAdapterSink {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Adapter,[Parameter(Mandatory)][AllowNull()][scriptblock]$Sink)
    $Adapter.__sink=$Sink
}

function Invoke-FastLlmUiAdapterEvent {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Adapter,[Parameter(Mandatory)][string]$Event,$EventArgs)
    $list=$Adapter.__handlers[$Event]
    if($null -eq $list){throw "Adapter '$($Adapter.__name)' has no event '$Event'."}
    if($null -eq $EventArgs){
        $EventArgs=[System.EventArgs]::Empty
        if($Event -ceq 'LinkClicked' -and ('System.Windows.Forms.LinkLabelLinkClickedEventArgs' -as [type])){
            try{$EventArgs=New-Object System.Windows.Forms.LinkLabelLinkClickedEventArgs((New-Object System.Windows.Forms.LinkLabel+Link))}catch{$EventArgs=[System.EventArgs]::Empty}
        }
    }
    foreach($h in @($list)){& $h $Adapter $EventArgs}
}
