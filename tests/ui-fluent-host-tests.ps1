#requires -Version 5.1
# WPF host mechanics for the Fluent window, proven on a real STA thread (Windows only): a WinForms timer under the WPF
# dispatcher, the tray, modal dialogs vs the WPF window, close guards through a hidden form, PowerShell adapter objects.
# Everything runs in ONE dispatcher loop driven by a step timer; results are evaluated after the loop has ended.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
$checks=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:checks++}

$onWindows=($PSVersionTable.PSVersion.Major -le 5) -or [bool](Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue)
if(-not $onWindows){Write-Host 'SKIP: Windows only';exit 0}

# H0: setup
Check ([Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA') 'runs on an STA thread'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms,System.Drawing
if(-not ('Bitworks.FastLlm.Tests.FluentHostNative' -as [type])){
    Add-Type -Path (Join-Path $PSScriptRoot 'helpers/FluentHostNative.cs') -ErrorAction Stop
}
Check ([bool]('Bitworks.FastLlm.Tests.FluentHostNative' -as [type])) 'the host helper compiles'
$native=[Bitworks.FastLlm.Tests.FluentHostNative]

function New-HostWindow{
    $w=[System.Windows.Window]::new()
    $w.Left=-32000;$w.Top=-32000;$w.Width=400;$w.Height=300
    $w.WindowStartupLocation='Manual'
    $w.ShowActivated=$false;$w.ShowInTaskbar=$false
    $w.Title='FastLLM host check'
    return $w
}

# One dialog probe: a WinForms form shown modally over $Owner; the form's own timer reads the WPF window state while it is up.
function Invoke-HostDialogProbe([object]$Owner,[string]$Title,[IntPtr]$Hwnd){
    $st=@{opened=$false;during=$null;timedOut=$false;after=$null}
    $f=New-Object System.Windows.Forms.Form
    $f.Text=$Title;$f.StartPosition='Manual';$f.ShowInTaskbar=$false
    $f.Location=New-Object System.Drawing.Point(-32000,-32000)
    $f.Size=New-Object System.Drawing.Size(200,100)
    $t=New-Object System.Windows.Forms.Timer
    $t.Interval=200
    $d=New-Object System.Windows.Forms.Timer
    $d.Interval=5000
    $nat=[Bitworks.FastLlm.Tests.FluentHostNative]
    $t.Add_Tick(({$t.Stop();$st.during=$nat::IsWindowEnabled($Hwnd);$f.Close()}).GetNewClosure())
    $d.Add_Tick(({$d.Stop();$st.timedOut=$true;$f.Close()}).GetNewClosure())
    $f.Add_Shown(({$st.opened=$true;$t.Start()}).GetNewClosure())
    try{
        $d.Start()
        $null=$f.ShowDialog($Owner)
        $st.after=$nat::IsWindowEnabled($Hwnd)
    }finally{
        $t.Dispose();$d.Dispose();$f.Dispose()
    }
    return $st
}

# One message box probe: a timer finds the box by its caption, reads the WPF window state, then closes the box with WM_CLOSE.
function Invoke-HostBoxProbe([object]$Owner,[string]$Title,[IntPtr]$Hwnd){
    $st=@{boxFound=$false;during=$null;posts=0;timedOut=$false;after=$null;sw=[System.Diagnostics.Stopwatch]::StartNew()}
    $t=New-Object System.Windows.Forms.Timer
    $t.Interval=50
    $nat=[Bitworks.FastLlm.Tests.FluentHostNative]
    $t.Add_Tick(({
        $ms=$st.sw.ElapsedMilliseconds
        $h=$nat::FindWindowByTitle($Title)
        if($h.ToInt64() -ne 0){
            if(-not $st.boxFound){$st.boxFound=$true;$st.during=$nat::IsWindowEnabled($Hwnd)}
            if($st.posts -lt 100){$st.posts++;$null=$nat::PostClose($h)}
        }elseif(-not $st.boxFound -and $ms -gt 5000){
            $st.timedOut=$true
            $t.Stop()
            try{[System.Windows.Forms.SendKeys]::SendWait('{ESC}')}catch{}
        }
    }).GetNewClosure())
    try{
        $t.Start()
        $null=[System.Windows.Forms.MessageBox]::Show($Owner,'check',$Title)
        $st.after=$nat::IsWindowEnabled($Hwnd)
    }finally{
        $t.Stop();$t.Dispose()
    }
    return $st
}

$res=@{}
$info=New-Object System.Collections.Generic.List[string]
$script:busy=$false
$script:si=0
$script:stepWatch=[System.Diagnostics.Stopwatch]::StartNew()
$script:loopStopped=$false
$script:hwnd=[IntPtr]::Zero
$script:h1=@{ticks=0;timer=$null;sw=$null}
$script:st5=@{calls=0;cfClosed=$false;through=$false;w2Closed=$false;stage=0}
$script:objs=New-Object System.Collections.Generic.List[object]   # disposed after the loop, whatever happened

$win=New-HostWindow
$script:win=$win
$script:w2=$null
$script:cf=$null
$script:hf=$null
$script:tray=$null

function Stop-HostLoop{
    if($script:loopStopped){return}
    $script:loopStopped=$true
    try{$script:tick.Stop();$script:deadline.Stop()}catch{}
    try{$script:win.Close()}catch{}
    finally{[System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()}
}

# Steps: each returns $true when done, anything else to be run again on the next tick (each step has 15 s in all).
$script:steps=@(
    # H1: WinForms timer ticks under the WPF dispatcher
    {
        if($null -eq $script:h1.timer){
            $t=New-Object System.Windows.Forms.Timer
            $t.Interval=50
            $h1=$script:h1
            $t.Add_Tick(({$h1.ticks++}).GetNewClosure())
            $script:h1.timer=$t;$script:objs.Add($t)
            $script:h1.sw=[System.Diagnostics.Stopwatch]::StartNew()
            $t.Start()
            return $false
        }
        if($script:h1.sw.ElapsedMilliseconds -lt 1000){return $false}
        $script:h1.timer.Stop()
        $script:res['h1']=@{ticks=[int]$script:h1.ticks}
        return $true
    },
    # H2: tray
    {
        $r=@{created=$false;threw=$null;clicked=$false}
        $tray=$null
        try{
            $tray=New-Object System.Windows.Forms.NotifyIcon
            $script:tray=$tray
            $tray.Icon=[System.Drawing.SystemIcons]::Application
            $tray.Text='FastLLM host check'
            $menu=New-Object System.Windows.Forms.ContextMenuStrip
            $item=New-Object System.Windows.Forms.ToolStripMenuItem 'Check item'
            $null=$menu.Items.Add($item)
            $tray.ContextMenuStrip=$menu
            $flag=@{v=$false}
            $item.Add_Click(({$flag.v=$true}).GetNewClosure())
            $r.created=$true
            try{$tray.Visible=$true;$r.threw=$false}catch{$r.threw=$_.Exception.Message}
            $item.PerformClick()
            $r.clicked=[bool]$flag.v
            $menu.Dispose()
        }finally{
            if($null -ne $tray){
                try{$tray.Visible=$false}catch{}
                try{$tray.Dispose()}catch{}
            }
        }
        $script:res['h2']=$r
        return $true
    },
    # H3: modality with an owner wrapper over the WPF handle
    {
        $r=@{}
        $owner=New-Object System.Windows.Forms.NativeWindow
        $owner.AssignHandle($script:hwnd)
        try{
            $r.dialog=Invoke-HostDialogProbe $owner 'FastLLM host dialog A' $script:hwnd
            $r.box=Invoke-HostBoxProbe $owner 'FastLLM host box A' $script:hwnd
        }finally{$owner.ReleaseHandle()}
        $script:res['h3']=$r
        return $true
    },
    # H4: hidden form owner and thread-modal events (evidence only)
    {
        $r=@{}
        $m=@{enter=0;leave=0}
        $enterH=[EventHandler]({param($s,$e) $m.enter++}.GetNewClosure())
        $leaveH=[EventHandler]({param($s,$e) $m.leave++}.GetNewClosure())
        $hf=New-Object System.Windows.Forms.Form
        $script:hf=$hf
        $null=$hf.Handle
        [System.Windows.Forms.Application]::add_EnterThreadModal($enterH)
        [System.Windows.Forms.Application]::add_LeaveThreadModal($leaveH)
        try{
            $m.enter=0;$m.leave=0
            $r.dialog=Invoke-HostDialogProbe $hf 'FastLLM host dialog B' $script:hwnd
            $r.dialogEnter=[int]$m.enter;$r.dialogLeave=[int]$m.leave
            $m.enter=0;$m.leave=0
            $r.box=Invoke-HostBoxProbe $hf 'FastLLM host box B' $script:hwnd
            $r.boxEnter=[int]$m.enter;$r.boxLeave=[int]$m.leave
        }finally{
            [System.Windows.Forms.Application]::remove_EnterThreadModal($enterH)
            [System.Windows.Forms.Application]::remove_LeaveThreadModal($leaveH)
            try{$hf.Dispose()}catch{}
        }
        $script:res['h4']=$r
        return $true
    },
    # H5: close guards through a hidden form (two Close() calls on two ticks)
    {
        $st5=$script:st5
        if($st5.stage -eq 0){
            $cf=New-Object System.Windows.Forms.Form
            $script:cf=$cf
            $null=$cf.Handle
            $w2=New-HostWindow
            $w2.Title='FastLLM host check 2'
            $script:w2=$w2
            $cf.Add_FormClosing(({param($s,$e) $st5.calls++;if($st5.calls -eq 1){$e.Cancel=$true}}).GetNewClosure())
            $cf.Add_FormClosed(({$st5.cfClosed=$true}).GetNewClosure())
            $w2.Add_Closed(({$st5.w2Closed=$true}).GetNewClosure())
            $w2.Add_Closing(({param($s,$e)
                if($st5.through){return}
                $e.Cancel=$true
                try{$cf.Close()}catch{}
                if($cf.IsDisposed -or $st5.cfClosed){
                    $st5.through=$true
                    $sender=$s
                    $act=[Action]({$sender.Close()}).GetNewClosure()
                    $null=$sender.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Normal,$act)
                }
            }).GetNewClosure())
            $w2.Show()
            $w2.Close()
            $script:res['h5a']=@{calls=[int]$st5.calls;w2Closed=[bool]$st5.w2Closed}
            $st5.stage=1
            return $false
        }
        if($st5.stage -eq 1){
            $script:w2.Close()
            $script:res['h5b']=@{calls=[int]$st5.calls}
            $st5.stage=2
            return $false
        }
        if(-not $st5.w2Closed){return $false}
        $script:res['h5c']=@{calls=[int]$st5.calls;cfClosed=[bool]$st5.cfClosed;cfDisposed=[bool]$script:cf.IsDisposed;w2Closed=[bool]$st5.w2Closed}
        return $true
    },
    # H6: adapter mechanics under StrictMode 2, no visible window needed
    {
        $r=@{}
        $st6=@{clicked=$false}
        $tb=New-Object System.Windows.Controls.TextBlock
        $btn=New-Object System.Windows.Controls.Button
        $a=[pscustomobject]@{__handlers=(New-Object 'System.Collections.Generic.List[scriptblock]');__tb=$tb;__btn=$btn}
        Add-Member -InputObject $a -MemberType ScriptProperty -Name Text -Value {$this.__tb.Text} -SecondValue {param($v) $this.__tb.Text=[string]$v}
        Add-Member -InputObject $a -MemberType ScriptProperty -Name Enabled -Value {$this.__btn.IsEnabled} -SecondValue {param($v) $this.__btn.IsEnabled=[bool]$v}
        Add-Member -InputObject $a -MemberType ScriptProperty -Name Visible -Value {$this.__btn.Visibility -eq 'Visible'} -SecondValue {param($v) $this.__btn.Visibility=$(if([bool]$v){'Visible'}else{'Collapsed'})}
        Add-Member -InputObject $a -MemberType ScriptMethod -Name Add_Click -Value {param($sb) $this.__handlers.Add($sb)}
        $btn.Add_Click(({param($s,$e) foreach($h in $a.__handlers){& $h}}).GetNewClosure())
        $a.Text='x'
        $r.text=($tb.Text -ceq 'x') -and ($a.Text -ceq 'x')
        $a.Enabled=$false
        $r.enabled=(-not $btn.IsEnabled) -and (-not $a.Enabled)
        $a.Visible=$false
        $r.visible=($btn.Visibility -eq [System.Windows.Visibility]::Collapsed) -and (-not $a.Visible)
        $a.Add_Click(({$st6.clicked=$true}).GetNewClosure())
        $btn.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        $r.click=[bool]$st6.clicked
        $threwSet=$false
        try{$a.Nope='x'}catch{$threwSet=$true}
        $threwGet=$false
        try{$null=& {Set-StrictMode -Version 2;$a.Nope}}catch{$threwGet=$true}
        $r.unknownSet=$threwSet
        $r.unknownGet=$threwGet
        $script:res['h6']=$r
        return $true
    }
)

$tick=New-Object System.Windows.Threading.DispatcherTimer
$tick.Interval=[TimeSpan]::FromMilliseconds(50)
$script:tick=$tick
$deadline=New-Object System.Windows.Threading.DispatcherTimer
$deadline.Interval=[TimeSpan]::FromSeconds(60)
$script:deadline=$deadline

$tick.Add_Tick({
    if($script:busy -or $script:loopStopped){return}
    $script:busy=$true
    try{
        if($script:si -ge $script:steps.Count){Stop-HostLoop;return}
        $out=@(& $script:steps[$script:si])
        if($out.Count -gt 0 -and $out[$out.Count-1] -is [bool] -and $out[$out.Count-1]){
            $script:si++
            $script:stepWatch.Restart()
        }elseif($script:stepWatch.ElapsedMilliseconds -gt 15000){
            $script:res['error']="step $($script:si) did not finish within 15 s"
            Stop-HostLoop
        }
        if($script:si -ge $script:steps.Count){Stop-HostLoop}
    }catch{
        $script:res['error']="step $($script:si): "+$_.Exception.ToString()
        Stop-HostLoop
    }finally{$script:busy=$false}
})
$deadline.Add_Tick({
    $script:deadline.Stop()
    $script:res['deadline']=$true
    if($script:busy){
        # a step is stuck inside a modal loop: ending the process is the only way out, and it must not hang CI
        Write-Host 'FAIL: host loop deadline hit while a step was blocked in a modal loop'
        [Environment]::Exit(1)
    }
    Stop-HostLoop
})

try{
    $script:hwnd=[System.Windows.Interop.WindowInteropHelper]::new($win).EnsureHandle()
    Check ($script:hwnd.ToInt64() -ne 0) 'the WPF window has a handle'
    $win.Show()
    $tick.Start()
    $deadline.Start()
    [System.Windows.Threading.Dispatcher]::Run()
}finally{
    Stop-HostLoop
    foreach($o in @($script:objs)){try{$o.Dispose()}catch{}}
    foreach($o in @($script:cf,$script:hf,$script:tray)){if($null -ne $o){try{$o.Dispose()}catch{}}}
    if($null -ne $script:w2){try{$script:st5.through=$true;$script:w2.Close()}catch{}}
}

# Evaluation happens here, after the dispatcher has ended, so a throwing Check can never strand the loop.
function Add-Info([string]$Text){$info.Add("INFO: host $Text")}
if($script:res.ContainsKey('h1')){Add-Info "winforms-timer-ticks: $($script:res.h1.ticks)"}
if($script:res.ContainsKey('h3')){Add-Info "owner-wrapper-disables: showdialog=$(([string]($script:res.h3.dialog.during -eq $false)).ToLowerInvariant()) messagebox=$(([string]($script:res.h3.box.during -eq $false)).ToLowerInvariant())"}
if($script:res.ContainsKey('h4')){
    $h4=$script:res.h4
    Add-Info "thread-modal-events: showdialog-enter=$($h4.dialogEnter) showdialog-leave=$($h4.dialogLeave) messagebox-enter=$($h4.boxEnter) messagebox-leave=$($h4.boxLeave) wpf-enabled-during=$(([string]$h4.dialog.during).ToLowerInvariant())/$(([string]$h4.box.during).ToLowerInvariant())"
}
if($script:res.ContainsKey('h5c')){Add-Info "close-guards: first-cancelled=$(([string](($script:res.h5a.calls -eq 1) -and (-not $script:res.h5a.w2Closed))).ToLowerInvariant()) second-closed=$(([string]($script:res.h5c.cfClosed -and $script:res.h5c.w2Closed)).ToLowerInvariant())"}
if($script:res.ContainsKey('h6') -and $script:res.h6.text -and $script:res.h6.enabled -and $script:res.h6.visible -and $script:res.h6.click -and $script:res.h6.unknownSet -and $script:res.h6.unknownGet){Add-Info 'adapter: ok'}
foreach($l in $info){Write-Host $l}

Check (-not $script:res.ContainsKey('error')) ("the host loop ran without an error: $($script:res['error'])")
Check (-not $script:res.ContainsKey('deadline')) 'the host loop finished before its 60 s deadline'
foreach($k in 'h1','h2','h3','h4','h5a','h5b','h5c','h6'){Check $script:res.ContainsKey($k) "host step $k produced a result"}

# H1
Check ($script:res.h1.ticks -ge 5) 'a WinForms timer ticks under the WPF dispatcher'
# H2
Check $script:res.h2.created 'the tray icon is created'
Check ($script:res.h2.threw -eq $false) 'showing the tray icon does not throw'
Check $script:res.h2.clicked 'a tray menu item click reaches its handler'
# H3
foreach($pair in @(@('dialog','ShowDialog'),@('box','MessageBox'))){
    $p=$script:res.h3[$pair[0]]
    if($pair[0] -eq 'dialog'){Check ($p.opened -and -not $p.timedOut) 'the owned dialog opened (Shown fired in time)'}
    else{Check ($p.boxFound -and -not $p.timedOut) 'the owned message box opened (found by its caption)'}
    Check ($p.during -eq $false) $(if($pair[0] -eq 'dialog'){'an owned ShowDialog disables the WPF window'}else{'an owned MessageBox disables the WPF window'})
    Check ($p.after -eq $true) "the WPF window is enabled again after the $($pair[1]) closed"
}
# H4 is evidence only, except that every probe must have actually opened and closed (no false evidence)
Check ($script:res.h4.dialog.opened -and -not $script:res.h4.dialog.timedOut -and $script:res.h4.dialog.after -eq $true) 'the hidden-form dialog probe opened and closed'
Check ($script:res.h4.box.boxFound -and -not $script:res.h4.box.timedOut -and $script:res.h4.box.after -eq $true) 'the hidden-form message box probe opened and closed'
# H5
Check ($script:res.h5a.calls -eq 1) 'first close attempt: the hidden form FormClosing ran once'
Check (-not $script:res.h5a.w2Closed) 'first close attempt: the WPF window is still open'
Check ($script:res.h5c.calls -eq 2) 'second close attempt: FormClosing ran twice'
Check ($script:res.h5c.cfClosed -and $script:res.h5c.cfDisposed) 'second close attempt: the hidden form closed'
Check $script:res.h5c.w2Closed 'second close attempt: the WPF window closed'
# H6
Check $script:res.h6.text 'an adapter Text write reaches TextBlock.Text'
Check $script:res.h6.enabled 'an adapter Enabled write reaches Button.IsEnabled'
Check $script:res.h6.visible 'an adapter Visible write maps to Visibility Collapsed'
Check $script:res.h6.click 'a routed click reaches an adapter Add_Click handler'
Check $script:res.h6.unknownSet 'writing an unknown adapter member throws'
Check $script:res.h6.unknownGet 'reading an unknown adapter member throws under StrictMode 2'

Write-Host "UI fluent host tests passed: $checks"
exit 0
