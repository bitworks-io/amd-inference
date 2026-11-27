#requires -Version 5.1
# The unsupported-PC path of -Window fluent: the support decision, the policy-flag rule, the approved texts (spec 6.9, verbatim) and the run-log event.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force
. (Join-Path $root 'src/FastLlm.UiFluentSupport.ps1')
$checks=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:checks++}
$ok={ }
$bad={ throw 'cannot load' }

# --- support decision ---
function Decide($Rel,[bool]$Core,[scriptblock]$Load){Get-FastLlmUiFluentSupport -NetFrameworkRelease $Rel -IsCoreClr $Core -LoadAssemblies $Load}
foreach($rel in $null,'x',461307,'461307'){
    $d=Decide $rel $false $ok
    Check (-not $d.supported -and $d.reason -ceq 'dotnet-too-old') "5.1 release '$rel' is dotnet-too-old"
}
foreach($rel in 461308,528040,'461308'){
    $d=Decide $rel $false $ok
    Check ($d.supported -and $d.reason -ceq '') "5.1 release '$rel' is supported"
}
foreach($rel in $null,'x',461307,461308){
    $d=Decide $rel $true $ok
    Check ($d.supported -and $d.reason -ceq '') "Core ignores release '$rel'"
}
$d=Decide 461308 $false $bad
Check (-not $d.supported -and $d.reason -ceq 'wpf-unavailable') '5.1 loader throw is wpf-unavailable'
$d=Decide $null $true $bad
Check (-not $d.supported -and $d.reason -ceq 'wpf-unavailable') 'Core loader throw is wpf-unavailable'
$d=Decide 100 $false $bad
Check ($d.reason -ceq 'dotnet-too-old') 'too old wins over a loader throw'
if($env:OS -ne 'Windows_NT'){
    $h=Test-FastLlmUiFluentHost
    Check (-not $h.supported -and $h.reason -ceq 'wpf-unavailable') 'off Windows the host check says wpf-unavailable'
}

# --- accessibility switches (Windows PowerShell 5.1 reads WPF as legacy without them) ---
Set-FastLlmUiFluentAccessibilitySwitches
$switchNames='Switch.UseLegacyAccessibilityFeatures','Switch.UseLegacyAccessibilityFeatures.2','Switch.UseLegacyAccessibilityFeatures.3','Switch.UseLegacyAccessibilityFeatures.4','Switch.UseLegacyAccessibilityFeatures.5','Switch.UseLegacyToolTipDisplay','Switch.System.Windows.Controls.ItemsControlDoesNotSupportAutomation','Switch.System.Windows.Controls.OptOutOfGridColumnResizeUsingKeyboard'
foreach($n in $switchNames){
    $val=$true
    $isSet=[System.AppContext]::TryGetSwitch($n,[ref]$val)
    Check ($isSet -and -not $val) "accessibility switch set to false: $n"
}
$hostSrc=Get-Content -LiteralPath (Join-Path $root 'src/FastLlm.UiFluentSupport.ps1') -Raw
$hostBody=$hostSrc.Substring($hostSrc.IndexOf('function Test-FastLlmUiFluentHost'))
Check ($hostBody.IndexOf('Set-FastLlmUiFluentAccessibilitySwitches') -ge 0 -and $hostBody.IndexOf('Set-FastLlmUiFluentAccessibilitySwitches') -lt $hostBody.IndexOf('Get-FastLlmUiFluentSupport') -and $hostBody.IndexOf('Set-FastLlmUiFluentAccessibilitySwitches') -lt $hostBody.IndexOf('Add-Type')) 'the switches are set before any assembly load in the host check'

# --- accessibility read-back: a legacy read never blocks, is recorded once with names only ---
$script:logged=@()
$logger={param($Fields) $script:logged+=,$Fields}
Invoke-FastLlmUiFluentAccessibilityCheck -CoreClr $false -Reader { @{typeFound=$true;legacy=@('WindowsBase.UseNetFx47CompatibleAccessibilityFeatures','PresentationFramework.ItemsControlDoesNotSupportAutomation')} } -Log $logger
Check ($script:logged.Count -eq 1 -and $script:logged[0].Keys.Count -eq 1 -and $script:logged[0]['fields'] -ceq 'WindowsBase.UseNetFx47CompatibleAccessibilityFeatures,PresentationFramework.ItemsControlDoesNotSupportAutomation') 'legacy read: exactly one event, field names only'
$script:logged=@()
Invoke-FastLlmUiFluentAccessibilityCheck -CoreClr $false -Reader { @{typeFound=$true;legacy=@()} } -Log $logger
Check ($script:logged.Count -eq 0) 'modern read: nothing recorded'
Invoke-FastLlmUiFluentAccessibilityCheck -CoreClr $false -Reader { @{typeFound=$false;legacy=@()} } -Log $logger
Check ($script:logged.Count -eq 1 -and $script:logged[0]['fields'] -ceq 'type-missing') 'type missing on 5.1: type-missing recorded'
$script:logged=@()
Invoke-FastLlmUiFluentAccessibilityCheck -CoreClr $true -Reader { @{typeFound=$false;legacy=@()} } -Log $logger
Check ($script:logged.Count -eq 0) 'type missing on pwsh 7: nothing recorded'
$threw=$false; try{Invoke-FastLlmUiFluentAccessibilityCheck -CoreClr $false -Reader { throw 'x' } -Log $logger}catch{$threw=$true}
Check $threw 'a failing reader throws to the host check, which swallows it (host never blocks)'
$hostSrc2=Get-Content -LiteralPath (Join-Path $root 'src/FastLlm.UiFluentSupport.ps1') -Raw
Check ($hostSrc2.Contains('try { Invoke-FastLlmUiFluentAccessibilityCheck -CoreClr $isCore } catch') -and $hostSrc2.IndexOf('Invoke-FastLlmUiFluentAccessibilityCheck -CoreClr') -gt $hostSrc2.IndexOf('Get-FastLlmUiFluentSupport -NetFrameworkRelease')) 'the host check reads back after the assemblies are loaded and swallows a fault'
Check ((Get-Content -LiteralPath (Join-Path $root 'src/FastLlm.RunLog.ps1') -Raw).Contains("'window-accessibility-legacy' = @('fields')")) 'the run log allows the event with the one field'

# The read-back checks every assembly copy of the switch class and names a legacy field <Assembly>.<Property>; the shell sets the switches before anything else.
$sup=Get-Content -LiteralPath (Join-Path $root 'src/FastLlm.UiFluentSupport.ps1') -Raw
Check ($sup.Contains('[System.Windows.DependencyObject].Assembly') -and $sup.Contains('[System.Windows.UIElement].Assembly') -and $sup.Contains('[System.Windows.Controls.ItemsControl].Assembly') -and $sup.Contains("`$short + '.' + `$name")) 'the read-back covers WindowsBase, PresentationCore and PresentationFramework'
$shellSrc=Get-Content -LiteralPath (Join-Path $root 'src/FastLlm.UiFluentShell.ps1') -Raw
$firstDot=$shellSrc.IndexOf('. (Join-Path $PSScriptRoot')
Check ($shellSrc.Substring($firstDot).StartsWith(". (Join-Path `$PSScriptRoot 'FastLlm.UiFluentSupport.ps1')") -and $shellSrc.IndexOf('Set-FastLlmUiFluentAccessibilitySwitches') -lt $shellSrc.IndexOf('Set-StrictMode') -and $shellSrc.IndexOf('Set-StrictMode') -lt $shellSrc.IndexOf("FastLlm.UiFluentAdapter.ps1'")) 'the shell file sets the switches before every other statement and dot-source'

# --- doctor: window accessibility in a child process ---
function Probe([scriptblock]$Runner,[bool]$Win=$true,[bool]$Core=$true){Get-FastLlmDoctorWindowAccessibility -SupportScript 'x' -ChildRunner $Runner -Windows $Win -CoreClr $Core}
$r=Probe { @{timedOut=$false;exitCode=0;stdout="{`"typeFound`":true,`"legacy`":[]}`n"} }
Check ($r.status -ceq 'modern' -and @($r.fields).Count -eq 0 -and $r.reason -ceq '' -and $r.summary -ceq 'Window accessibility: modern') 'doctor a11y: modern'
$r=Probe { @{timedOut=$false;exitCode=0;stdout='{"typeFound":true,"legacy":["PresentationCore.UseLegacyToolTipDisplay","WindowsBase.UseNetFx47CompatibleAccessibilityFeatures"]}'} }
Check ($r.status -ceq 'legacy' -and @($r.fields).Count -eq 2 -and $r.reason -ceq '' -and $r.summary -ceq 'Window accessibility: legacy (fields: PresentationCore.UseLegacyToolTipDisplay, WindowsBase.UseNetFx47CompatibleAccessibilityFeatures)') 'doctor a11y: legacy names the fields'
$r=Probe { @{timedOut=$false;exitCode=0;stdout='{"typeFound":true,"legacy":["WindowsBase.UseLegacyToolTipDisplay"]}'} }
Check ($r.status -ceq 'legacy' -and @($r.fields).Count -eq 1 -and @($r.fields)[0] -ceq 'WindowsBase.UseLegacyToolTipDisplay') 'doctor a11y: one legacy field stays a list'
$r=Probe { @{timedOut=$false;exitCode=0;stdout='{"typeFound":false,"legacy":[]}'} } $true $true
Check ($r.status -ceq 'modern') 'doctor a11y: missing type on pwsh 7 is modern'
$r=Probe { @{timedOut=$false;exitCode=0;stdout='{"typeFound":false,"legacy":[]}'} } $true $false
Check ($r.status -ceq 'legacy' -and @($r.fields)[0] -ceq 'type-missing') 'doctor a11y: missing type on 5.1 is legacy type-missing'
$r=Probe { @{timedOut=$true;exitCode=-1;stdout=''} }
Check ($r.status -ceq 'not-checked' -and $r.reason -ceq 'timeout' -and $r.summary -ceq 'Window accessibility: not checked (timeout)') 'doctor a11y: timeout'
$r=Probe { @{timedOut=$false;exitCode=0;stdout='{"loadFailed":true}'} }
Check ($r.status -ceq 'not-checked' -and $r.reason -ceq 'wpf-load-failed') 'doctor a11y: wpf load failure'
$r=Probe { throw 'secret path C:\x' }
Check ($r.status -ceq 'not-checked' -and $r.reason -ceq 'child-failed' -and -not $r.summary.Contains('secret')) 'doctor a11y: a throwing runner is child-failed, no exception text'
foreach($bad in @(@{timedOut=$false;exitCode=1;stdout='{"typeFound":true,"legacy":[]}'},@{timedOut=$false;exitCode=0;stdout='garbage'},@{timedOut=$false;exitCode=0;stdout=''},
    @{timedOut=$false;exitCode=0;stdout='{"typeFound":true}'},@{timedOut=$false;exitCode=0;stdout='{"typeFound":"yes","legacy":[]}'},
    @{timedOut=$false;exitCode=0;stdout='{"typeFound":true,"legacy":["C:\\secret\\x.dll"]}'},@{timedOut=$false;exitCode=0;stdout="{`"typeFound`":true,`"legacy`":[]}`nsecond"},@{timedOut=$false;exitCode=0;stdout='null'})){
    $badRun=$bad
    $r=Probe { $badRun }.GetNewClosure()
    Check ($r.status -ceq 'not-checked' -and $r.reason -ceq 'child-failed' -and $r.summary -ceq 'Window accessibility: not checked (child-failed)') "doctor a11y: garbage child output is child-failed ($($bad.stdout))"
}
$launch=$sup.Substring($sup.IndexOf('function Invoke-FastLlmDoctorAccessibilityChild'),$sup.IndexOf('function Get-FastLlmDoctorWindowAccessibility')-$sup.IndexOf('function Invoke-FastLlmDoctorAccessibilityChild'))
Check ($launch -notmatch '(?i)EncodedCommand' -and $launch -notmatch '(?i)ExecutionPolicy' -and $launch.Contains('Invoke-FastLlmUiFluentAccessibilityProbe') -and $launch.Contains('. $env:FASTLLM_DOCTOR_A11Y_SUPPORT')) 'the doctor child launch is plain: no EncodedCommand, no ExecutionPolicy'
$r=Probe { throw 'runner must not run' } $false
Check ($r.status -ceq 'not-checked' -and $r.reason -ceq 'not-windows' -and $r.summary -ceq 'Window accessibility: not checked (not-windows)') 'doctor a11y: not Windows never starts a child'
if($env:OS -ne 'Windows_NT'){
    $r=Get-FastLlmDoctorWindowAccessibility
    Check ($r.status -ceq 'not-checked' -and $r.reason -ceq 'not-windows') 'doctor a11y: the real call off Windows is not-windows'
}else{
    # The REAL child, on the running shell: switches set first in a fresh process, so both 5.1 and 7 read modern.
    $r=Get-FastLlmDoctorWindowAccessibility -SupportScript (Join-Path $root 'src/FastLlm.UiFluentSupport.ps1')
    Check ($r.status -ceq 'modern' -and $r.reason -ceq '' -and @($r.fields).Count -eq 0) ("doctor a11y: the real child reads modern (status=$($r.status) reason=$($r.reason) fields=$(@($r.fields) -join ','))")
}
# The setter never runs in doctor's OWN process: a counting stand-in for it, the helper with a stub runner, then the doctor branch's own statement.
$setterCounter=@{calls=0}
function Set-FastLlmUiFluentAccessibilitySwitches { $setterCounter.calls++ }
$null=Get-FastLlmDoctorWindowAccessibility -SupportScript 'x' -ChildRunner { @{timedOut=$false;exitCode=0;stdout='{"typeFound":true,"legacy":[]}'} } -Windows $true
$null=Get-FastLlmDoctorWindowAccessibility -SupportScript 'x' -ChildRunner { @{timedOut=$true;exitCode=-1;stdout=''} } -Windows $true
Check ($setterCounter.calls -eq 0) 'doctor a11y: the helper with a stub runner never calls the setter in-process'
$doctorAst=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'fast-llm.ps1'),[ref]$null,[ref]$null)
$doctorTry=@($doctorAst.FindAll({param($n) $n -is [System.Management.Automation.Language.TryStatementAst] -and $n.Body.Extent.Text.Contains('Get-FastLlmDoctorWindowAccessibility -SupportScript')},$true))
$doctorTry=@($doctorTry|Sort-Object{$_.Extent.Text.Length}|Select-Object -First 1)
Check ($doctorTry.Count -eq 1 -and $doctorTry[0].Extent.Text.StartsWith('try { $windowAccessibility = ') -and $doctorTry[0].Extent.Text -match 'catch') 'the doctor branch statement that builds windowAccessibility is found by AST'
$projectRoot=$root
Invoke-Expression $doctorTry[0].Extent.Text
Check ($null -ne $windowAccessibility -and $windowAccessibility.status -cin 'modern','legacy','not-checked' -and $setterCounter.calls -eq 0) 'doctor a11y: the doctor branch call sequence never calls the setter in-process'
Remove-Item -Path Function:\Set-FastLlmUiFluentAccessibilitySwitches
$doctorSrc=Get-Content -LiteralPath (Join-Path $root 'fast-llm.ps1') -Raw
Check ($doctorSrc.Contains('windowAccessibility = $windowAccessibility') -and $doctorSrc.Contains('Get-FastLlmDoctorWindowAccessibility -SupportScript')) 'doctor JSON carries windowAccessibility'
Check ($sup.Contains("EnvironmentVariables['FASTLLM_DOCTOR_A11Y_SUPPORT']") -and $sup.Contains('-NoProfile -NonInteractive') -and $sup.Contains('GetCurrentProcess().MainModule.FileName') -and $sup.Contains('$process.Kill()')) 'the child uses the same shell, no profile, and is killed by its own Process object'

# --- policy flag ---
function Pol([string]$M='Undefined',[string]$U='Undefined',[string]$C='Undefined',[string]$L='Undefined'){Get-FastLlmUiCliPolicyFlag -Policies @{MachinePolicy=$M;UserPolicy=$U;CurrentUser=$C;LocalMachine=$L}}
$flag='-ExecutionPolicy RemoteSigned '
Check ((Pol 'AllSigned') -ceq '') 'MachinePolicy AllSigned: no flag'
Check ((Pol 'Undefined' 'RemoteSigned') -ceq '') 'UserPolicy RemoteSigned: no flag'
Check ((Pol) -ceq $flag) 'all Undefined: flag'
Check ((Pol 'Undefined' 'Undefined' 'Restricted') -ceq $flag) 'CurrentUser Restricted: flag'
Check ((Pol 'Undefined' 'Undefined' 'Undefined' 'Bypass') -ceq '') 'LocalMachine Bypass: no flag'
Check ((Pol 'Undefined' 'Undefined' 'Restricted' 'Bypass') -ceq $flag) 'CurrentUser wins over LocalMachine'
Check ((Pol 'Restricted' 'Undefined' 'Bypass') -ceq $flag) 'MachinePolicy Restricted wins: flag'
Check ((Pol 'Undefined' 'Undefined' 'Undefined' 'Unrestricted') -ceq '') 'LocalMachine Unrestricted: no flag'
Check ((Get-FastLlmUiCliPolicyFlag -Policies @{MachinePolicy='Undefined';UserPolicy='Undefined';CurrentUser='Undefined';LocalMachine='Undefined';Process='Bypass'}) -ceq $flag) 'Process is ignored'

# --- exact texts ---
$F='C:\Example\FastLLM'
$crlf="`r`n"
function Cmd([string]$P,[string]$Tail){"powershell -NoProfile ${P}-File `"$F\fast-llm.ps1`" $Tail"}
function Block([string]$P){
    @("FastLLM's command line still works. In Command Prompt or PowerShell, run this the first time (it asks before downloading a model):",
      (Cmd $P 'install'),
      'Then, and every time after:',
      (Cmd $P 'start')) -join $crlf
}
foreach($p in '',$flag){
    $a="FastLLM's window isn't supported on this PC. It needs Microsoft .NET Framework 4.7.1 or later, and this PC has an older version. To fix it, update Windows, or install .NET Framework 4.8 from Microsoft."+$crlf+$crlf+(Block $p)
    $b="FastLLM's window isn't supported on this PC: the Windows desktop window components (WPF) could not be loaded. Repairing .NET Framework 4.8 from Microsoft, or updating Windows, usually fixes this."+$crlf+$crlf+(Block $p)
    $c="FastLLM's window could not open because of a fault in FastLLM, not in your PC."+$crlf+$crlf+(Block $p)+$crlf+$crlf+'To help us fix it, save a support bundle:'+$crlf+(Cmd $p 'doctor -SupportBundle <new-file>.zip')
    Check ((Get-FastLlmUiUnsupportedText -Reason 'dotnet-too-old' -Folder $F -PolicyFlag $p) -ceq $a) "text A (flag '$p')"
    Check ((Get-FastLlmUiUnsupportedText -Reason 'wpf-unavailable' -Folder $F -PolicyFlag $p) -ceq $b) "text B (flag '$p')"
    Check ((Get-FastLlmUiUnsupportedText -Reason 'theme-init' -Folder $F -PolicyFlag $p) -ceq $c) "text C theme-init (flag '$p')"
    Check ((Get-FastLlmUiUnsupportedText -Reason 'xaml-parse' -Folder $F -PolicyFlag $p) -ceq $c) "text C xaml-parse (flag '$p')"
}
$threw=$false; try{Get-FastLlmUiUnsupportedText -Reason 'bogus' -Folder $F -PolicyFlag ''}catch{$threw=$true}
Check $threw 'unknown reason throws'
Check (-not ((Get-FastLlmUiUnsupportedText -Reason 'dotnet-too-old' -Folder $F -PolicyFlag '') -match '[^\x00-\x7F]')) 'text is ASCII'

# --- Show + run log ---
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('fluent-support-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try{
    $pol=@{MachinePolicy='Undefined';UserPolicy='Undefined';CurrentUser='Undefined';LocalMachine='Undefined'}
    $out=@(Show-FastLlmUiUnsupported -Reason 'dotnet-too-old' -InstallRoot $tmp -Folder $F -Policies $pol -NoMessageBox 6>&1 | ForEach-Object{[string]$_})
    Check ($out.Count -eq 1 -and $out[0] -ceq (Get-FastLlmUiUnsupportedText -Reason 'dotnet-too-old' -Folder $F -PolicyFlag $flag)) 'console text is text A with the flag'
    $pol2=@{MachinePolicy='AllSigned';UserPolicy='Undefined';CurrentUser='Undefined';LocalMachine='Undefined'}
    $out2=@(Show-FastLlmUiUnsupported -Reason 'theme-init' -InstallRoot $tmp -Folder $F -Policies $pol2 -NoMessageBox 6>&1 | ForEach-Object{[string]$_})
    Check ($out2[0] -ceq (Get-FastLlmUiUnsupportedText -Reason 'theme-init' -Folder $F -PolicyFlag '')) 'AllSigned: no flag on the console'
    $logs=@(Get-ChildItem -LiteralPath $tmp -Recurse -Filter 'run-*.jsonl')
    Check ($logs.Count -eq 2) 'two run logs, one per call'
    $lines=@($logs | ForEach-Object{[IO.File]::ReadAllLines($_.FullName)[0] | ConvertFrom-Json})
    foreach($l in $lines){
        Check ($l.event -ceq 'window-unsupported' -and $l.runId -cmatch '^[0-9a-f]{32}$') 'event name and 32-hex run id'
        Check ((@($l.PSObject.Properties.Name | Sort-Object) -join ',') -ceq 'event,reason,runId,ts') 'only reason beyond the envelope'
        Check ($l.reason -cin 'dotnet-too-old','theme-init') 'reason recorded'
        Check (-not ([IO.File]::ReadAllText($logs[0].FullName)).Contains('Example')) 'no path in the log'
    }
    $t=$false; try{Write-FastLlmRunLogEvent -InstallRoot $tmp -RunId ('a'*32) -Event 'window-unsupported' -Fields @{reason='x';folder=$F}}catch{$t=$true}
    Check $t 'window-unsupported drops (refuses) any other field'
    # A policy read that fails adds NO flag (never suggest weakening a policy that could not be read); a working read still decides.
    $out3=@(Show-FastLlmUiUnsupported -Reason 'dotnet-too-old' -InstallRoot $tmp -Folder $F -PolicyReader { throw 'policy read failed' } -NoMessageBox 6>&1 | ForEach-Object{[string]$_})
    Check ($out3.Count -eq 1 -and $out3[0] -ceq (Get-FastLlmUiUnsupportedText -Reason 'dotnet-too-old' -Folder $F -PolicyFlag '')) 'a failed policy read gives text with no flag'
    Check (-not ($out3[0] -match '-ExecutionPolicy')) 'a failed policy read: no -ExecutionPolicy in the text'
    $out4=@(Show-FastLlmUiUnsupported -Reason 'dotnet-too-old' -InstallRoot $tmp -Folder $F -PolicyReader { @([pscustomobject]@{Scope='LocalMachine';ExecutionPolicy='Restricted'}) } -NoMessageBox 6>&1 | ForEach-Object{[string]$_})
    Check ($out4[0] -ceq (Get-FastLlmUiUnsupportedText -Reason 'dotnet-too-old' -Folder $F -PolicyFlag '-ExecutionPolicy RemoteSigned ')) 'a working read of Restricted still adds the flag'
}finally{ if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Recurse -Force} }

# --- the window script's own support check, run for real (lead gate M2) ---
# The two statements of fast-llm-ui.ps1 that decide it ($fluentSupport=Test-FastLlmUiFluentHost and the if that shows the message and exits 3) are taken by AST
# and run in a child PowerShell with stubs: an unsupported PC shows the message, exits 3 and builds no window; a supported PC goes on to build the window.
$uiAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'fast-llm-ui.ps1'),[ref]$null,[ref]$null)
$supportIf=@($uiAst.FindAll({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses.Count -ge 1 -and [string]$n.Clauses[0].Item1.Extent.Text -ceq '-not $fluentSupport.supported'},$true))
$supportSet=@($uiAst.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and [string]$n.Left.Extent.Text -ceq '$fluentSupport' -and [string]$n.Right.Extent.Text -ceq 'Test-FastLlmUiFluentHost'},$true))
$shellInit=@($uiAst.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -ceq 'Initialize-FastLlmUiFluentShell'},$true))
Check ($supportIf.Count -eq 1 -and $supportSet.Count -eq 1 -and $shellInit.Count -eq 1) 'the window script has one support assignment, one support if and one Initialize-FastLlmUiFluentShell call'
Check ($supportSet[0].Extent.StartOffset -lt $supportIf[0].Extent.StartOffset -and $supportIf[0].Extent.EndOffset -lt $shellInit[0].Extent.StartOffset) 'the support check runs before the window is built (Initialize-FastLlmUiFluentShell comes after it)'
Check ([string]$supportIf[0].Clauses[0].Item2.Extent.Text -match 'Show-FastLlmUiUnsupported\s+-Reason\s+\$fluentSupport\.reason' -and [string]$supportIf[0].Clauses[0].Item2.Extent.Text -match 'exit 3') 'the unsupported branch shows the message with the reason and exits 3'
$childRoot=Join-Path ([IO.Path]::GetTempPath()) ('fastllm-support-child-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $childRoot -Force | Out-Null
try{
    $hostExe=(Get-Process -Id $PID).Path
    function Invoke-SupportChild([string]$SupportedLiteral,[string]$IfText){
        $marker=Join-Path $childRoot ('marker-'+[Guid]::NewGuid().ToString('N')+'.txt')
        $lines=@(
            '$ErrorActionPreference=''Stop'''
            '$InstallRoot='''+$childRoot.Replace("'","''")+''''
            '$marker='''+$marker.Replace("'","''")+''''
            'function Test-FastLlmUiFluentHost { [pscustomobject]@{ supported = '+$SupportedLiteral+'; reason = ''dotnet-too-old'' } }'
            'function Show-FastLlmUiUnsupported { param($Reason,$InstallRoot,$Folder) [IO.File]::AppendAllText($marker, ''shown:''+[string]$Reason+'';'') }'
            'function Initialize-FastLlmUiFluentShell { [IO.File]::AppendAllText($marker, ''window-built;'') }'
            [string]$supportSet[0].Extent.Text
            $IfText
            'Initialize-FastLlmUiFluentShell'
            'exit 0'
        )
        $script=Join-Path $childRoot ('child-'+[Guid]::NewGuid().ToString('N')+'.ps1')
        [IO.File]::WriteAllText($script,($lines -join "`n"),(New-Object Text.UTF8Encoding($false)))
        & $hostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script *> $null
        $code=$LASTEXITCODE
        $seen=''; if(Test-Path -LiteralPath $marker){ $seen=[IO.File]::ReadAllText($marker) }
        return @{ Code=$code; Seen=$seen }
    }
    $realIf=[string]$supportIf[0].Extent.Text
    $r=Invoke-SupportChild '$false' $realIf
    Check ($r.Code -eq 3 -and $r.Seen -ceq 'shown:dotnet-too-old;') "an unsupported PC (the real statements): the message is shown with its reason, the window script exits 3, and no window is built (code=$($r.Code) seen='$($r.Seen)')"
    $r=Invoke-SupportChild '$true' $realIf
    Check ($r.Code -eq 0 -and $r.Seen -ceq 'window-built;') "control: a supported PC shows no message and goes on to build the window (code=$($r.Code) seen='$($r.Seen)')"
    $m=Invoke-SupportChild '$false' ($realIf.Replace('if (-not $fluentSupport.supported) {','if ($false) {'))
    Check ($realIf.Contains('if (-not $fluentSupport.supported) {') -and -not ($m.Code -eq 3 -and $m.Seen -ceq 'shown:dotnet-too-old;')) "mutation check: a support if that never fires lets an unsupported PC build the window (code=$($m.Code) seen='$($m.Seen)')"
    $m=Invoke-SupportChild '$false' ($realIf.Replace('exit 3','exit 0'))
    Check ($realIf.Contains('exit 3') -and $m.Code -ne 3) "mutation check: an unsupported branch that does not exit 3 is caught (code=$($m.Code))"
}finally{ if(Test-Path -LiteralPath $childRoot){Remove-Item -LiteralPath $childRoot -Recurse -Force} }
Write-Host "ui-fluent-support-tests: $checks checks passed"
