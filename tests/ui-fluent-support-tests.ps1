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
Write-Host "ui-fluent-support-tests: $checks checks passed"
