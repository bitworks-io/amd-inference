#requires -Version 5.1
# Serving settings tests: port read/write, strict validation, precedence, and the bench-path tripwire.
# Pure file work in temp folders; no engine, GPU or network.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/FastLlm.ServingSettings.ps1')
$script:count=0
function Check($Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:count++;Write-Host "PASS: $Message"}
function Throws([scriptblock]$Action,[string]$Pattern) {
    $caught=$false;$observed='no exception'
    try { & $Action | Out-Null } catch {
        $caught=[bool]([string]$_.Exception.Message -match $Pattern)
        $observed=[regex]::Replace([string]$_.Exception.Message,'[\x00-\x1f\x7f]',' ')
        if($observed.Length -gt 240){$observed=$observed.Substring(0,240)}
    }
    if(-not $caught){throw "FAIL: rejects $Pattern (observed: $observed)"}
    Check $true "rejects $Pattern"
}
function Write-Utf8([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object Text.UTF8Encoding($false)))}
function New-Root {
    $path=Join-Path ([IO.Path]::GetTempPath()) ('serving-settings-tests-'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}
$work=New-Root
try {
    # absent-file-defaults
    $r=Join-Path $work 'a'; New-Item -ItemType Directory -Path $r | Out-Null
    $s=Get-FastLlmServingSettings -InstallRoot $r
    Check ($s.serverPort -eq 8080) 'absent-file-defaults: port 8080'
    Check ($s.malformed -eq $false) 'absent-file-defaults: not malformed'
    Check ($s.thinking -ceq 'auto' -and $s.chatPage -ceq 'off') 'absent-file-defaults: thinking auto, chatPage off'

    # set-port-preserves-unknown
    $r=Join-Path $work 'b'; New-Item -ItemType Directory -Path $r | Out-Null
    Write-Utf8 (Join-Path $r 'settings.json') '{"vulkanBarMitigation":"on","x":1}'
    Set-FastLlmServingSettings -InstallRoot $r -ServerPort 18181
    $o=Get-Content -LiteralPath (Join-Path $r 'settings.json') -Raw | ConvertFrom-Json
    Check ($o.vulkanBarMitigation -ceq 'on' -and $o.x -eq 1 -and $o.serverPort -eq 18181) 'set-port-preserves-unknown: all three keys present'
    Check ((Get-FastLlmServingSettings -InstallRoot $r).serverPort -eq 18181) 'set-port-preserves-unknown: Get reads 18181'
    Check (@(Get-ChildItem -LiteralPath $r -Filter '*.tmp-*').Count -eq 0) 'set-port-preserves-unknown: no temp file left'

    # default-port-removes-key
    Set-FastLlmServingSettings -InstallRoot $r -ServerPort 8080
    $o=Get-Content -LiteralPath (Join-Path $r 'settings.json') -Raw | ConvertFrom-Json
    Check (-not ($o.PSObject.Properties.Name -contains 'serverPort')) 'default-port-removes-key: serverPort absent'
    Check ($o.x -eq 1) 'default-port-removes-key: unknown key kept'

    # port-range
    $r=Join-Path $work 'c'; New-Item -ItemType Directory -Path $r | Out-Null
    foreach($bad in 1023,0,65536,-1){ Throws { Set-FastLlmServingSettings -InstallRoot $r -ServerPort $bad } 'serving-settings-invalid-port' }
    foreach($bad in ([double]18181.5),'18181.5','abc','',$null){ Throws { Set-FastLlmServingSettings -InstallRoot $r -ServerPort $bad } 'serving-settings-invalid-port' }
    Check (-not (Test-Path -LiteralPath (Join-Path $r 'settings.json'))) 'port-range: refused non-integers wrote nothing'
    Throws { Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{ServerPort=18181.5} } 'serving-settings-invalid-port'
    Set-FastLlmServingSettings -InstallRoot $r -ServerPort '18181'
    Check ((Get-FastLlmServingSettings -InstallRoot $r).serverPort -eq 18181) 'port-range: integer text accepted'
    foreach($good in 1024,65535){ Set-FastLlmServingSettings -InstallRoot $r -ServerPort $good; Check ((Get-FastLlmServingSettings -InstallRoot $r).serverPort -eq $good) "port-range: $good accepted" }
    Check ((Test-FastLlmServerPort -Port 1023) -eq $false -and (Test-FastLlmServerPort -Port 1024) -eq $true -and (Test-FastLlmServerPort -Port 65535) -eq $true -and (Test-FastLlmServerPort -Port 65536) -eq $false) 'port-range: Test-FastLlmServerPort bounds'
    # invalid stored value reads as the default
    Write-Utf8 (Join-Path $r 'settings.json') '{"serverPort":80}'
    Check ((Get-FastLlmServingSettings -InstallRoot $r).serverPort -eq 8080) 'port-range: invalid stored port reads as default'
    Write-Utf8 (Join-Path $r 'settings.json') '{"serverPort":"18181"}'
    Check ((Get-FastLlmServingSettings -InstallRoot $r).serverPort -eq 8080) 'port-range: non-integer stored port reads as default'

    # malformed-settings-refuse-write
    $r=Join-Path $work 'd'; New-Item -ItemType Directory -Path $r | Out-Null
    Write-Utf8 (Join-Path $r 'settings.json') '{bad'
    $s=Get-FastLlmServingSettings -InstallRoot $r
    Check ($s.malformed -eq $true -and $s.serverPort -eq 8080) 'malformed-settings-refuse-write: Get returns defaults with malformed'
    Throws { Set-FastLlmServingSettings -InstallRoot $r -ServerPort 18181 } 'serving-settings-malformed'
    Check ((Get-Content -LiteralPath (Join-Path $r 'settings.json') -Raw) -ceq '{bad') 'malformed-settings-refuse-write: file untouched'

    # resolve-precedence
    $r=Join-Path $work 'e'; New-Item -ItemType Directory -Path $r | Out-Null
    Set-FastLlmServingSettings -InstallRoot $r -ServerPort 18181
    $x=Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{ServerPort=19191}
    Check ($x.serverPort -eq 19191 -and $x.source -ceq 'parameter') 'resolve-precedence: parameter wins'
    $x=Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{}
    Check ($x.serverPort -eq 18181 -and $x.source -ceq 'settings') 'resolve-precedence: settings next'
    $x=Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{} -IgnoreUserSettings
    Check ($x.serverPort -eq 8080 -and $x.source -ceq 'default') 'resolve-precedence: ignore settings gives default'
    Check ($x.thinking -ceq 'auto' -and $x.chatPage -ceq 'off') 'resolve-precedence: thinking and chatPage defaults'
    Throws { Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{ServerPort=80} } 'serving-settings-invalid-port'

    # thinking-settings-roundtrip: Off is stored, Auto removes the key, an invalid value throws, unknown keys survive.
    $r=Join-Path $work 'thinking'; New-Item -ItemType Directory -Path $r | Out-Null
    Write-Utf8 (Join-Path $r 'settings.json') '{"x":1,"serverPort":18181}'
    Set-FastLlmServingSettings -InstallRoot $r -Thinking 'off'
    $o=Get-Content -LiteralPath (Join-Path $r 'settings.json') -Raw | ConvertFrom-Json
    Check ($o.thinking -ceq 'off' -and $o.x -eq 1 -and $o.serverPort -eq 18181) 'thinking-settings-roundtrip: off is stored beside the other keys'
    Check ((Get-FastLlmServingSettings -InstallRoot $r).thinking -ceq 'off') 'thinking-settings-roundtrip: Get reads off'
    Set-FastLlmServingSettings -InstallRoot $r -Thinking 'auto'
    $o=Get-Content -LiteralPath (Join-Path $r 'settings.json') -Raw | ConvertFrom-Json
    Check (-not ($o.PSObject.Properties.Name -contains 'thinking') -and $o.x -eq 1 -and $o.serverPort -eq 18181) 'thinking-settings-roundtrip: auto removes the key'
    Check ((Get-FastLlmServingSettings -InstallRoot $r).thinking -ceq 'auto') 'thinking-settings-roundtrip: Get reads auto'
    foreach($bad in 'on','OFF','','banana',$null){ Throws { Set-FastLlmServingSettings -InstallRoot $r -Thinking $bad } 'serving-settings-invalid-thinking' }
    foreach($bogus in '{"thinking":"on"}','{"thinking":"OFF"}','{"thinking":1}','{"thinking":null}'){
        Write-Utf8 (Join-Path $r 'settings.json') $bogus
        Check ((Get-FastLlmServingSettings -InstallRoot $r).thinking -ceq 'auto') "thinking-settings-roundtrip: stored $bogus reads as auto"
    }
    Write-Utf8 (Join-Path $r 'settings.json') '{"thinking":"off"}'
    $x=Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{}
    Check ($x.thinking -ceq 'off') 'thinking-resolve: settings give off'
    $x=Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{Thinking='auto'}
    Check ($x.thinking -ceq 'auto') 'thinking-resolve: an explicit parameter wins over settings'
    $x=Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{} -IgnoreUserSettings
    Check ($x.thinking -ceq 'auto') 'thinking-resolve: ignore settings gives auto'
    Write-Utf8 (Join-Path $r 'settings.json') '{}'
    $x=Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{Thinking='off'}
    Check ($x.thinking -ceq 'off') 'thinking-resolve: an explicit off applies with no settings'
    Throws { Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{Thinking='maybe'} } 'serving-settings-invalid-thinking'
    Write-Utf8 (Join-Path $r 'settings.json') '{not json'
    $x=Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{}
    Check ($x.settingsMalformed -and $x.serverPort -eq 8080) 'malformed-settings: resolve reports malformed and uses the defaults'
    $x=Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{} -IgnoreUserSettings
    Check (-not $x.settingsMalformed) 'malformed-settings: ignoring user settings does not report malformed'
    Write-Utf8 (Join-Path $r 'settings.json') '{}'
    Check (-not (Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{}).settingsMalformed) 'malformed-settings: good settings are not malformed'
    Check ((Get-FastLlmServingMalformedWarning) -ceq 'settings.json is not valid JSON, so FastLLM is using the default settings. Fix or delete the file to change settings.') 'malformed-settings: the warning text'

    # chatpage-settings-roundtrip: On is stored, Off removes the key, an invalid value throws, unknown keys survive.
    $r=Join-Path $work 'chatpage'; New-Item -ItemType Directory -Path $r | Out-Null
    Write-Utf8 (Join-Path $r 'settings.json') '{"x":1,"serverPort":18181,"thinking":"off"}'
    Set-FastLlmServingSettings -InstallRoot $r -ChatPage 'on'
    $o=Get-Content -LiteralPath (Join-Path $r 'settings.json') -Raw | ConvertFrom-Json
    Check ($o.chatPage -ceq 'on' -and $o.x -eq 1 -and $o.serverPort -eq 18181 -and $o.thinking -ceq 'off') 'chatpage-settings-roundtrip: on is stored beside the other keys'
    Check ((Get-FastLlmServingSettings -InstallRoot $r).chatPage -ceq 'on') 'chatpage-settings-roundtrip: Get reads on'
    Set-FastLlmServingSettings -InstallRoot $r -ChatPage 'off'
    $o=Get-Content -LiteralPath (Join-Path $r 'settings.json') -Raw | ConvertFrom-Json
    Check (-not ($o.PSObject.Properties.Name -contains 'chatPage') -and $o.x -eq 1 -and $o.thinking -ceq 'off') 'chatpage-settings-roundtrip: off removes the key'
    Check ((Get-FastLlmServingSettings -InstallRoot $r).chatPage -ceq 'off') 'chatpage-settings-roundtrip: Get reads off'
    foreach($bad in 'auto','ON','','banana',$null){ Throws { Set-FastLlmServingSettings -InstallRoot $r -ChatPage $bad } 'serving-settings-invalid-chatpage' }
    foreach($bogus in '{"chatPage":"auto"}','{"chatPage":"ON"}','{"chatPage":true}','{"chatPage":1}','{"chatPage":null}'){
        Write-Utf8 (Join-Path $r 'settings.json') $bogus
        Check ((Get-FastLlmServingSettings -InstallRoot $r).chatPage -ceq 'off') "chatpage-settings-roundtrip: stored $bogus reads as off"
    }
    Write-Utf8 (Join-Path $r 'settings.json') '{"chatPage":"on"}'
    $x=Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{}
    Check ($x.chatPage -ceq 'on') 'chatpage-resolve: settings give on'
    $x=Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{ChatPage='off'}
    Check ($x.chatPage -ceq 'off') 'chatpage-resolve: an explicit parameter wins over settings'
    $x=Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{} -IgnoreUserSettings
    Check ($x.chatPage -ceq 'off') 'chatpage-resolve: ignore settings gives off'
    Write-Utf8 (Join-Path $r 'settings.json') '{}'
    $x=Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{ChatPage='on'}
    Check ($x.chatPage -ceq 'on') 'chatpage-resolve: an explicit on applies with no settings'
    Throws { Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{ChatPage='maybe'} } 'serving-settings-invalid-chatpage'

    # idle-stop-settings: opt-in stop after N idle minutes; 0 (Never) is the default and removes the key.
    $r=Join-Path $work 'idle'; New-Item -ItemType Directory -Path $r | Out-Null
    Check ((Get-FastLlmServingSettings -InstallRoot $r).idleStopMinutes -eq 0) 'idle-stop-settings: absent file reads 0 (Never)'
    Write-Utf8 (Join-Path $r 'settings.json') '{"x":1,"serverPort":18181}'
    foreach($minutes in 15,30,60){
        Set-FastLlmServingSettings -InstallRoot $r -IdleStopMinutes $minutes
        $o=Get-Content -LiteralPath (Join-Path $r 'settings.json') -Raw | ConvertFrom-Json
        Check ($o.idleStopMinutes -eq $minutes -and $o.x -eq 1 -and $o.serverPort -eq 18181) "idle-stop-settings: $minutes is stored as a number beside the other keys"
        Check ((Get-FastLlmServingSettings -InstallRoot $r).idleStopMinutes -eq $minutes) "idle-stop-settings: Get reads $minutes"
    }
    Set-FastLlmServingSettings -InstallRoot $r -IdleStopMinutes '30'
    Check ((Get-FastLlmServingSettings -InstallRoot $r).idleStopMinutes -eq 30) 'idle-stop-settings: the text 30 is accepted'
    Set-FastLlmServingSettings -InstallRoot $r -IdleStopMinutes 0
    $o=Get-Content -LiteralPath (Join-Path $r 'settings.json') -Raw | ConvertFrom-Json
    Check (-not ($o.PSObject.Properties.Name -contains 'idleStopMinutes') -and $o.x -eq 1) 'idle-stop-settings: 0 removes the key and keeps the others'
    foreach($bad in 1,10,45,90,-15,'auto','15.5','',' ',$null,$true,15.5,'0x0F'){ Throws { Set-FastLlmServingSettings -InstallRoot $r -IdleStopMinutes $bad } 'serving-settings-invalid-idle-stop' }
    Set-FastLlmServingSettings -InstallRoot $r -IdleStopMinutes 15
    Set-FastLlmServingSettings -InstallRoot $r -ServerPort 18182
    Check ((Get-FastLlmServingSettings -InstallRoot $r).idleStopMinutes -eq 15) 'idle-stop-settings: saving another setting keeps the idle stop'
    foreach($bogus in '{"idleStopMinutes":"15"}','{"idleStopMinutes":45}','{"idleStopMinutes":true}','{"idleStopMinutes":-15}','{"idleStopMinutes":15.5}','{"idleStopMinutes":null}'){
        Write-Utf8 (Join-Path $r 'settings.json') $bogus
        Check ((Get-FastLlmServingSettings -InstallRoot $r).idleStopMinutes -eq 0) "idle-stop-settings: stored $bogus reads as 0"
    }
    Write-Utf8 (Join-Path $r 'settings.json') '{"idleStopMinutes":30}'
    $x=Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{}
    Check ($x.idleStopMinutes -eq 30 -and $x.source -ceq 'settings') 'idle-stop-resolve: settings give 30'
    $x=Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{IdleStopMinutes=60}
    Check ($x.idleStopMinutes -eq 60 -and $x.source -ceq 'parameter') 'idle-stop-resolve: an explicit parameter wins over settings'
    $x=Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{IdleStopMinutes=0}
    Check ($x.idleStopMinutes -eq 0) 'idle-stop-resolve: an explicit 0 turns it off for this run'
    Check ((Get-Content -LiteralPath (Join-Path $r 'settings.json') -Raw | ConvertFrom-Json).idleStopMinutes -eq 30) 'idle-stop-resolve: a per-run value is never written to settings.json'
    # The bench path reads no user settings: its effective idle stop is 0 whatever is saved.
    $x=Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{} -IgnoreUserSettings
    Check ($x.idleStopMinutes -eq 0) 'idle-stop-bench: with user settings ignored the effective idle stop is 0'
    Throws { Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{IdleStopMinutes=45} } 'serving-settings-invalid-idle-stop'
    Write-Utf8 (Join-Path $r 'settings.json') '{ not json'
    Check ((Get-FastLlmServingSettings -InstallRoot $r).idleStopMinutes -eq 0) 'idle-stop-settings: a malformed file reads 0'

    # context-profile-settings: long is stored, default removes the key, an invalid value throws, unknown keys survive.
    $r=Join-Path $work 'context-profile'; New-Item -ItemType Directory -Path $r | Out-Null
    $s=Get-FastLlmServingSettings -InstallRoot $r
    Check ($s.contextProfile -ceq 'default' -and $s.slots -eq 1) 'context-profile-settings: an absent file reads default and 1 slot'
    Write-Utf8 (Join-Path $r 'settings.json') '{"x":1,"serverPort":18181,"thinking":"off"}'
    Set-FastLlmServingSettings -InstallRoot $r -ContextProfile 'long'
    $o=Get-Content -LiteralPath (Join-Path $r 'settings.json') -Raw | ConvertFrom-Json
    Check ($o.contextProfile -ceq 'long' -and $o.x -eq 1 -and $o.serverPort -eq 18181 -and $o.thinking -ceq 'off') 'context-profile-settings: long is stored beside the other keys'
    Check ((Get-FastLlmServingSettings -InstallRoot $r).contextProfile -ceq 'long') 'context-profile-settings: Get reads long'
    Set-FastLlmServingSettings -InstallRoot $r -ServerPort 18182
    Check ((Get-FastLlmServingSettings -InstallRoot $r).contextProfile -ceq 'long') 'context-profile-settings: saving another setting keeps the context profile'
    Set-FastLlmServingSettings -InstallRoot $r -ContextProfile 'default'
    $o=Get-Content -LiteralPath (Join-Path $r 'settings.json') -Raw | ConvertFrom-Json
    Check (-not ($o.PSObject.Properties.Name -contains 'contextProfile') -and $o.x -eq 1 -and $o.thinking -ceq 'off') 'context-profile-settings: default removes the key and keeps the others'
    Check ((Get-FastLlmServingSettings -InstallRoot $r).contextProfile -ceq 'default') 'context-profile-settings: Get reads default'
    foreach($bad in 'LONG','Default','short','on','','banana',$null,1,$true){ Throws { Set-FastLlmServingSettings -InstallRoot $r -ContextProfile $bad } 'serving-settings-invalid-context-profile' }
    Check (-not ((Get-Content -LiteralPath (Join-Path $r 'settings.json') -Raw | ConvertFrom-Json).PSObject.Properties.Name -contains 'contextProfile')) 'context-profile-settings: a refused value writes nothing'
    foreach($bogus in '{"contextProfile":"LONG"}','{"contextProfile":"short"}','{"contextProfile":1}','{"contextProfile":true}','{"contextProfile":null}','{"contextProfile":["long"]}'){
        Write-Utf8 (Join-Path $r 'settings.json') $bogus
        Check ((Get-FastLlmServingSettings -InstallRoot $r).contextProfile -ceq 'default') "context-profile-settings: stored $bogus reads as default"
    }
    Write-Utf8 (Join-Path $r 'settings.json') '{"contextProfile":"long"}'
    $x=Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{}
    Check ($x.contextProfile -ceq 'long' -and $x.source -ceq 'settings') 'context-profile-resolve: settings give long'
    $x=Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{ContextProfile='default'}
    Check ($x.contextProfile -ceq 'default' -and $x.source -ceq 'parameter') 'context-profile-resolve: an explicit parameter wins over settings'
    Check ((Get-Content -LiteralPath (Join-Path $r 'settings.json') -Raw | ConvertFrom-Json).contextProfile -ceq 'long') 'context-profile-resolve: a per-run value is never written to settings.json'
    Write-Utf8 (Join-Path $r 'settings.json') '{}'
    $x=Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{ContextProfile='long'}
    Check ($x.contextProfile -ceq 'long' -and $x.slots -eq 1) 'context-profile-resolve: an explicit long applies with no settings'
    $x=Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{}
    Check ($x.contextProfile -ceq 'default' -and $x.slots -eq 1 -and $x.source -ceq 'default') 'context-profile-resolve: no parameter and no setting give the defaults'
    Throws { Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{ContextProfile='maybe'} } 'serving-settings-invalid-context-profile'

    # slots-settings: 2 is stored as a number, 1 removes the key, only 1 and 2 are accepted.
    $r=Join-Path $work 'slots'; New-Item -ItemType Directory -Path $r | Out-Null
    Write-Utf8 (Join-Path $r 'settings.json') '{"x":1,"contextProfile":"long"}'
    Set-FastLlmServingSettings -InstallRoot $r -Slots 2
    $o=Get-Content -LiteralPath (Join-Path $r 'settings.json') -Raw | ConvertFrom-Json
    Check ($o.slots -eq 2 -and ($o.slots -is [int] -or $o.slots -is [long]) -and $o.x -eq 1 -and $o.contextProfile -ceq 'long') 'slots-settings: 2 is stored as a number beside the other keys'
    Check ((Get-FastLlmServingSettings -InstallRoot $r).slots -eq 2) 'slots-settings: Get reads 2'
    Set-FastLlmServingSettings -InstallRoot $r -Slots '2'
    Check ((Get-Content -LiteralPath (Join-Path $r 'settings.json') -Raw | ConvertFrom-Json).slots -eq 2) 'slots-settings: the text 2 is accepted and stored as a number'
    Set-FastLlmServingSettings -InstallRoot $r -Slots 1
    $o=Get-Content -LiteralPath (Join-Path $r 'settings.json') -Raw | ConvertFrom-Json
    Check (-not ($o.PSObject.Properties.Name -contains 'slots') -and $o.x -eq 1 -and $o.contextProfile -ceq 'long') 'slots-settings: 1 removes the key and keeps the others'
    Check ((Get-FastLlmServingSettings -InstallRoot $r).slots -eq 1) 'slots-settings: Get reads 1'
    foreach($bad in 0,3,4,-1,-2,'two','2.0','1.5','',' ',' 2','0x2',$null,$true,2.5,([double]2)){ Throws { Set-FastLlmServingSettings -InstallRoot $r -Slots $bad } 'serving-settings-invalid-slots' }
    Check (-not ((Get-Content -LiteralPath (Join-Path $r 'settings.json') -Raw | ConvertFrom-Json).PSObject.Properties.Name -contains 'slots')) 'slots-settings: a refused value writes nothing'
    foreach($bogus in '{"slots":"2"}','{"slots":3}','{"slots":0}','{"slots":true}','{"slots":-2}','{"slots":2.5}','{"slots":null}','{"slots":[2]}'){
        Write-Utf8 (Join-Path $r 'settings.json') $bogus
        Check ((Get-FastLlmServingSettings -InstallRoot $r).slots -eq 1) "slots-settings: stored $bogus reads as 1"
    }
    Write-Utf8 (Join-Path $r 'settings.json') '{"slots":2}'
    $x=Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{}
    Check ($x.slots -eq 2 -and $x.source -ceq 'settings') 'slots-resolve: settings give 2'
    $x=Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{Slots=1}
    Check ($x.slots -eq 1 -and $x.source -ceq 'parameter') 'slots-resolve: an explicit 1 wins over settings for this run'
    $x=Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{Slots='2'}
    Check ($x.slots -eq 2 -and $x.slots -is [int]) 'slots-resolve: the text 2 resolves to the number 2'
    Throws { Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{Slots=3} } 'serving-settings-invalid-slots'
    Throws { Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{Slots='many'} } 'serving-settings-invalid-slots'

    # serving-options-bench: the bench path reads no user settings, so both options are their defaults whatever is saved.
    Write-Utf8 (Join-Path $r 'settings.json') '{"contextProfile":"long","slots":2,"serverPort":18181}'
    $x=Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{}
    Check ($x.contextProfile -ceq 'long' -and $x.slots -eq 2) 'serving-options-bench: without the switch both saved options apply'
    $x=Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{} -IgnoreUserSettings
    Check ($x.contextProfile -ceq 'default' -and $x.slots -eq 1 -and $x.serverPort -eq 8080 -and $x.source -ceq 'default') 'serving-options-bench: with user settings ignored both options are their defaults'
    $x=Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{ContextProfile='long'} -IgnoreUserSettings
    Check ($x.contextProfile -ceq 'long' -and $x.slots -eq 1) 'serving-options-bench: an explicit parameter still applies with user settings ignored'
    # A malformed file gives the defaults and is never overwritten.
    Write-Utf8 (Join-Path $r 'settings.json') '{ "contextProfile":"long", not json'
    $s=Get-FastLlmServingSettings -InstallRoot $r
    Check ($s.malformed -eq $true -and $s.contextProfile -ceq 'default' -and $s.slots -eq 1) 'serving-options-malformed: a malformed file reads default and 1 slot'
    $x=Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{}
    Check ($x.settingsMalformed -and $x.contextProfile -ceq 'default' -and $x.slots -eq 1) 'serving-options-malformed: resolve reports malformed and uses the defaults'
    Throws { Set-FastLlmServingSettings -InstallRoot $r -ContextProfile 'long' } 'serving-settings-malformed'
    Throws { Set-FastLlmServingSettings -InstallRoot $r -Slots 2 } 'serving-settings-malformed'
    Check ((Get-Content -LiteralPath (Join-Path $r 'settings.json') -Raw) -ceq '{ "contextProfile":"long", not json') 'serving-options-malformed: the file is untouched'

    # tripwire-plan-reads-no-settings
    $watched='FastLlm.psm1','FastLlm.Runtime.ps1','FastLlm.Preload.ps1','FastLlm.Recipes.ps1','FastLlm.RunLog.ps1','FastLlm.ModelStore.ps1'
    foreach($name in $watched){
        $file=Join-Path (Join-Path $root 'src') $name
        if(-not (Test-Path -LiteralPath $file -PathType Leaf)){ Check $true "tripwire: $name absent, skipped"; continue }
        $text=Get-Content -LiteralPath $file -Raw
        Check ($text -notmatch 'Get-FastLlmServingSettings' -and $text -notmatch 'Resolve-FastLlmServingOptions' -and $text -notmatch 'settings\.json') "tripwire-plan-reads-no-settings: $name"
    }
}
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
# host arguments for a start at sign-in: one code path with Resolve-FastLlmServingOptions
foreach($case in 1){
    $r=New-Root
    $h=Get-FastLlmServingHostArguments -InstallRoot $r
    Check ($h.ServerPort -eq 0 -and $h.Thinking -ceq 'auto' -and $h.ChatPage -ceq 'off' -and $h['Idle'+'StopMinutes'] -eq 0) 'host-arguments: no settings file gives the defaults (catalog port 0)'
    Write-Utf8 (Join-Path $r 'settings.json') '{"serverPort":18181,"thinking":"off","chatPage":"on","idleStopMinutes":30}'
    $h=Get-FastLlmServingHostArguments -InstallRoot $r
    Check ($h.ServerPort -eq 18181 -and $h.Thinking -ceq 'off' -and $h.ChatPage -ceq 'on' -and $h['Idle'+'StopMinutes'] -eq 30) 'host-arguments: saved settings are returned'
    Write-Utf8 (Join-Path $r 'settings.json') '{"serverPort":8080}'
    Check ((Get-FastLlmServingHostArguments -InstallRoot $r).ServerPort -eq 0) 'host-arguments: the default port 8080 maps to the catalog port 0, as the CLI does'
    Write-Utf8 (Join-Path $r 'settings.json') '{"serverPort":80,"thinking":"loud","chatPage":"maybe","idleStopMinutes":7}'
    $h=Get-FastLlmServingHostArguments -InstallRoot $r
    Check ($h.ServerPort -eq 0 -and $h.Thinking -ceq 'auto' -and $h.ChatPage -ceq 'off' -and $h['Idle'+'StopMinutes'] -eq 0) 'host-arguments: invalid stored values give the defaults'
    Write-Utf8 (Join-Path $r 'settings.json') '{ broken'
    $h=Get-FastLlmServingHostArguments -InstallRoot $r
    Check ($h.ServerPort -eq 0 -and $h.Thinking -ceq 'auto') 'host-arguments: malformed settings give the defaults'
    $o=Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{}
    Check ($h.ChatPage -ceq $o.chatPage) 'host-arguments: agrees with Resolve-FastLlmServingOptions'
}
Write-Host "serving-settings-tests: $script:count checks passed"
