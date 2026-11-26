#requires -Version 5.1
# Start at sign-in: the per-user Run registration helper and the one-attempt launcher.
# Registry and host access go through seams, so this suite touches no real registry (except the Windows-only round trip
# against a throwaway key) and starts no process.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'src/FastLlm.ServingSettings.ps1')
. (Join-Path $repo 'src/FastLlm.SignInStart.ps1')
$script:checks = 0
function Assert-True($Value, [string]$Message) { if (-not $Value) { throw "ASSERT: $Message" }; $script:checks++ }
function Assert-Equal($Actual, $Expected, [string]$Message) { Assert-True ($Actual -ceq $Expected) "$Message (expected '$Expected', got '$Actual')" }
$work = Join-Path ([IO.Path]::GetTempPath()) ('signin-start-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$script:ExpectedValueName = 'FastLLM'

# An in-memory registry with the seam's exact shape.
function New-FakeRegistry {
    $store = @{ run = @{}; approved = @{}; calls = New-Object System.Collections.ArrayList }
    $registry = @{
        Store = $store
        GetRunValue = { param($Name) if ($store.run.ContainsKey($Name)) { return [string]$store.run[$Name] }; return $null }.GetNewClosure()
        SetRunValue = { param($Name, $Value) [void]$store.calls.Add("set-run:$Name"); $store.run[$Name] = $Value }.GetNewClosure()
        RemoveRunValue = { param($Name) [void]$store.calls.Add("remove-run:$Name"); $store.run.Remove($Name) }.GetNewClosure()
        GetApprovedValue = { param($Name) if ($store.approved.ContainsKey($Name)) { return ,([byte[]]$store.approved[$Name]) }; return $null }.GetNewClosure()
        RemoveApprovedValue = { param($Name) [void]$store.calls.Add("remove-approved:$Name"); $store.approved.Remove($Name) }.GetNewClosure()
    }
    return $registry
}

# --- the command text -------------------------------------------------------------------------------------------------
Assert-Equal (Get-FastLlmSignInStartCommand -AppRoot 'C:\Program Files\Example App') '"C:\Program Files\Example App\FastLLM.cmd" /signin' 'command is quoted and exact for a path with spaces'
Assert-Equal (Get-FastLlmSignInStartCommand -AppRoot 'C:\Example\App\') '"C:\Example\App\FastLLM.cmd" /signin' 'a trailing backslash is not doubled'
Assert-Equal (Get-FastLlmSignInStartCommand -AppRoot 'D:\a b\c d') '"D:\a b\c d\FastLLM.cmd" /signin' 'spaces in several segments'
$thrown = $false; try { Get-FastLlmSignInStartCommand -AppRoot 'C:\Bad"Path' | Out-Null } catch { $thrown = $true }
Assert-True $thrown 'a quote in the app path is refused'
$thrown = $false; try { Get-FastLlmSignInStartCommand -AppRoot '' | Out-Null } catch { $thrown = $true }
Assert-True $thrown 'an empty app path is refused'

# --- the state: "on" needs three registry facts ----------------------------------------------------------------------
$app = 'C:\Program Files\Example App'
$expected = Get-FastLlmSignInStartCommand -AppRoot $app
$script:FastLlmSignInRegistry = New-FakeRegistry
$state = Get-FastLlmSignInStartState -AppRoot $app
Assert-True ($state.on -eq $false) 'no Run value is off'
Assert-Equal $state.reason 'value-missing' 'no Run value gives value-missing'

Set-FastLlmSignInStart -AppRoot $app
Assert-Equal $script:FastLlmSignInRegistry.Store.run['FastLLM'] $expected 'Set writes exactly the command under the value name FastLLM'
$state = Get-FastLlmSignInStartState -AppRoot $app
Assert-True ($state.on -eq $true) 'Run value present, matching, not disabled is on'
Assert-Equal $state.reason 'on' 'on reason'

$script:FastLlmSignInRegistry.Store.run['FastLLM'] = '"C:\Other\FastLLM.cmd" /signin'
$state = Get-FastLlmSignInStartState -AppRoot $app
Assert-True ($state.on -eq $false) 'a different command is off'
Assert-Equal $state.reason 'command-differs' 'a different command gives command-differs'
$script:FastLlmSignInRegistry.Store.run['FastLLM'] = $expected.ToLowerInvariant()
Assert-Equal (Get-FastLlmSignInStartState -AppRoot $app).reason 'command-differs' 'the match is exact, including case'
$script:FastLlmSignInRegistry.Store.run['FastLLM'] = $expected + ' '
Assert-Equal (Get-FastLlmSignInStartState -AppRoot $app).reason 'command-differs' 'the match is exact, including trailing text'

$script:FastLlmSignInRegistry.Store.run['FastLLM'] = $expected
$script:FastLlmSignInRegistry.Store.approved['FastLLM'] = [byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
$state = Get-FastLlmSignInStartState -AppRoot $app
Assert-True ($state.on -eq $false) 'disabled in Startup apps is off'
Assert-Equal $state.reason 'disabled-in-startup-apps' 'first byte 0x03 gives disabled-in-startup-apps'
$script:FastLlmSignInRegistry.Store.approved['FastLLM'] = [byte[]](2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
Assert-Equal (Get-FastLlmSignInStartState -AppRoot $app).reason 'on' 'first byte 0x02 is enabled'
$script:FastLlmSignInRegistry.Store.approved['FastLLM'] = [byte[]]@()
Assert-Equal (Get-FastLlmSignInStartState -AppRoot $app).reason 'on' 'an empty approval value is not a disable flag'

# value missing wins over a stale disable flag
$script:FastLlmSignInRegistry.Store.run.Remove('FastLLM')
$script:FastLlmSignInRegistry.Store.approved['FastLLM'] = [byte[]](3, 0, 0, 0)
Assert-Equal (Get-FastLlmSignInStartState -AppRoot $app).reason 'value-missing' 'a missing value is reported before the disable flag'

# Set re-enables a value the user had disabled earlier, then Remove deletes both values
Set-FastLlmSignInStart -AppRoot $app
Assert-True (-not $script:FastLlmSignInRegistry.Store.approved.ContainsKey('FastLLM')) 'Set clears an older disable flag'
Assert-Equal (Get-FastLlmSignInStartState -AppRoot $app).reason 'on' 'on again after Set'
$script:FastLlmSignInRegistry.Store.approved['FastLLM'] = [byte[]](2, 0, 0, 0)
Remove-FastLlmSignInStart
Assert-True (-not $script:FastLlmSignInRegistry.Store.run.ContainsKey('FastLLM')) 'Remove deletes the Run value'
Assert-True (-not $script:FastLlmSignInRegistry.Store.approved.ContainsKey('FastLLM')) 'Remove deletes the StartupApproved value'
Remove-FastLlmSignInStart   # removing what is not there is fine
Assert-Equal (Get-FastLlmSignInStartState -AppRoot $app).reason 'value-missing' 'off after Remove'

# A registry with no Run key at all: reads are empty, Remove is a no-op, Set creates the key and value.
$missing = New-FakeRegistry
$script:FastLlmSignInRegistry = $missing
Assert-Equal (Get-FastLlmSignInStartState -AppRoot $app).reason 'value-missing' 'Run key missing gives value-missing'
Remove-FastLlmSignInStart
Assert-Equal $missing.Store.run.Count 0 'Remove on a missing key leaves nothing behind'
Set-FastLlmSignInStart -AppRoot $app
Assert-Equal (Get-FastLlmSignInStartState -AppRoot $app).reason 'on' 'Set creates the value when the key was missing'

# --- the launcher ------------------------------------------------------------------------------------------------------
$script:Calls = New-Object System.Collections.ArrayList
$script:Captured = @{}
function New-FakeHost([bool]$Elevated = $false, [bool]$Occupied = $false, $StartBehavior = 'ok') {
    $calls = $script:Calls
    $captured = $script:Captured
    return @{
        IsElevated = { [void]$calls.Add('elevated'); $Elevated }.GetNewClosure()
        IsOccupied = { param($InstallRoot) [void]$calls.Add('occupied'); $Occupied }.GetNewClosure()
        Sleep = { param($Seconds) [void]$calls.Add("sleep:$Seconds") }.GetNewClosure()
        Start = {
            param($Arguments)
            [void]$calls.Add('start')
            $captured['arguments'] = $Arguments
            if ($StartBehavior -eq 'throw') { throw 'secret-looking message must never be recorded' }
            if ($StartBehavior -eq 'busy') { throw 'This installation already has an active serving operation.' }
            if ($StartBehavior -eq 'job') { throw 'The current process is contained in a Windows job; a persistent host cannot be launched from it.' }
            if ($StartBehavior -eq 'embeddings-refused' -or $StartBehavior -eq 'embeddings-odd-code') {
                # What the background start throws when embeddings are on and no embedding model is installed: a typed failure whose data carries the code.
                $typed = New-Object -TypeName System.InvalidOperationException -ArgumentList 'embeddings-no-model: secret-looking message must never be recorded'
                $typed.Data['FastLlmFailureCode'] = $(if ($StartBehavior -eq 'embeddings-odd-code') { 'embeddings-secret-looking fl-TEXT' } else { 'embeddings-no-model' })
                throw $typed
            }
            if ($StartBehavior -eq 'key-unavailable' -or $StartBehavior -eq 'key-odd-code') {
                # What the background start throws when the key is on and the store cannot be read: a typed failure whose data carries the code.
                $typed = New-Object -TypeName System.InvalidOperationException -ArgumentList 'api-key-unavailable: secret-looking message must never be recorded'
                $typed.Data['FastLlmFailureCode'] = $(if ($StartBehavior -eq 'key-odd-code') { 'api-key-secret-looking fl-TEXT' } else { 'api-key-unavailable' })
                throw $typed
            }
        }.GetNewClosure()
    }
}
function New-Install([bool]$WithRequest = $true, $RequestOverride = $null) {
    $root = Join-Path $work ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $root 'state') -Force | Out-Null
    if ($WithRequest) {
        $request = [ordered]@{ profile = 'balanced'; modelId = 'example-model'; contextSize = 8192 }
        if ($null -ne $RequestOverride) { $request = $RequestOverride }
        [IO.File]::WriteAllText((Join-Path $root 'state/signin-start-request.json'), (($request | ConvertTo-Json -Compress)), (New-Object Text.UTF8Encoding($false)))
    }
    return $root
}
function Read-Result([string]$Root) {
    $path = Join-Path $Root 'state/signin-start.json'
    Assert-True (Test-Path -LiteralPath $path) 'the result file exists'
    return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
}
function Count-Calls([string]$Name) { @($script:Calls | Where-Object { $_ -ceq $Name }).Count }
function Invoke-Case($HostSeam, [string]$Root) {
    $script:Calls.Clear()
    $script:FastLlmSignInHost = $HostSeam
    return (Invoke-FastLlmSignInLaunch -SourceRoot $repo -InstallRoot $Root -DelaySeconds 7)
}

# the default data root is the per-user data folder, never the app folder
Assert-Equal (Get-FastLlmSignInDefaultInstallRoot) (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Bitworks\FastLLM') 'default data root is LocalApplicationData\\Bitworks\\FastLLM'

# started
$root = New-Install
$r = Invoke-Case (New-FakeHost) $root
Assert-Equal $r.result 'started' 'started result returned'
$file = Read-Result $root
Assert-Equal $file.result 'started' 'started result written'
Assert-True ($null -eq $file.failureCode) 'started has no failure code'
Assert-True ((Get-Content -LiteralPath (Join-Path $root 'state/signin-start.json') -Raw) -match '"time":"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"') 'time is UTC ISO 8601 (checked on the raw text, since ConvertFrom-Json may turn it into a date)'
Assert-Equal (@($file.PSObject.Properties.Name | Sort-Object) -join ',') 'failureCode,result,time' 'the result file holds only time, result and failureCode'
Assert-Equal (Count-Calls 'start') 1 'the host is started once'
Assert-True ($script:Calls -contains 'sleep:7') 'the launcher waits the given fixed time first'
$a = $script:Captured['arguments']
Assert-Equal $a.ModelId 'example-model' 'the saved model is passed through'
Assert-Equal $a.Profile 'balanced' 'the saved profile is passed through'
Assert-Equal ([int]$a.ContextSize) 8192 'the saved context is passed through'
# no settings.json in this install: the serving settings are the defaults
Assert-Equal ([int]$a.ServerPort) 0 'no settings: the catalog port (0)'
Assert-Equal $a.Thinking 'auto' 'no settings: thinking auto'
Assert-Equal $a.ChatPage 'off' 'no settings: chat page off'
Assert-Equal ([int]$a['Idle' + 'StopMinutes']) 0 'no settings: idle stop never'
Assert-True ($a.NoWait -eq $true) 'the start is NoWait'
Assert-Equal $a.InstallRoot $root 'the data root is passed through as InstallRoot'
Assert-Equal $a.SourceRoot $repo 'the app root is passed through as SourceRoot'
Assert-True ($a.SourceRoot -cne $a.InstallRoot) 'SourceRoot and InstallRoot are two distinct values'

# serving settings come from the user's saved settings at launch, not from the saved request
$root = New-Install
[IO.File]::WriteAllText((Join-Path $root 'settings.json'), '{"serverPort":18181,"thinking":"off","chatPage":"on","idleStopMinutes":30,"other":1}', (New-Object Text.UTF8Encoding($false)))
$null = Invoke-Case (New-FakeHost) $root
$a = $script:Captured['arguments']
Assert-Equal ([int]$a.ServerPort) 18181 'saved port reaches the host'
Assert-Equal $a.Thinking 'off' 'saved thinking reaches the host'
Assert-Equal $a.ChatPage 'on' 'saved chat page reaches the host'
Assert-Equal ([int]$a['Idle' + 'StopMinutes']) 30 'saved idle stop reaches the host'
Assert-Equal $a.ModelId 'example-model' 'the request still supplies the model'
# the settings are read at launch: a later change applies without touching the request
[IO.File]::WriteAllText((Join-Path $root 'settings.json'), '{"idleStopMinutes":60}', (New-Object Text.UTF8Encoding($false)))
$null = Invoke-Case (New-FakeHost) $root
$a = $script:Captured['arguments']
Assert-Equal ([int]$a['Idle' + 'StopMinutes']) 60 'a changed setting applies at the next launch'
Assert-Equal ([int]$a.ServerPort) 0 'a setting removed from the file falls back to the default'
# malformed settings give the defaults
[IO.File]::WriteAllText((Join-Path $root 'settings.json'), '{ not json', (New-Object Text.UTF8Encoding($false)))
$r = Invoke-Case (New-FakeHost) $root
Assert-Equal $r.result 'started' 'malformed settings still start'
$a = $script:Captured['arguments']
Assert-Equal ([int]$a.ServerPort) 0 'malformed settings: the catalog port'
Assert-Equal $a.Thinking 'auto' 'malformed settings: thinking auto'
Assert-Equal $a.ChatPage 'off' 'malformed settings: chat page off'
Assert-Equal ([int]$a['Idle' + 'StopMinutes']) 0 'malformed settings: idle stop never'
# the request file neither accepts nor forwards serving keys
$root = New-Install -RequestOverride ([ordered]@{ profile = 'fast'; modelId = 'example-model'; contextSize = 0; serverPort = 9999; thinking = 'off'; chatPage = 'on'; idleStopMinutes = 60 })
$null = Invoke-Case (New-FakeHost) $root
$a = $script:Captured['arguments']
Assert-Equal ([int]$a.ServerPort) 0 'a port in the request file is ignored'
Assert-Equal $a.Thinking 'auto' 'thinking in the request file is ignored'
Assert-Equal $a.ChatPage 'off' 'chat page in the request file is ignored'
Assert-Equal ([int]$a['Idle' + 'StopMinutes']) 0 'idle stop in the request file is ignored'

# DELIBERATE CHANGE: the sign-in start applies the saved context profile, requests at once and embeddings exactly as start does (they used to be
# left out of the arguments, so a saved setup silently became the default one).
$root = New-Install
[IO.File]::WriteAllText((Join-Path $root 'settings.json'), '{"contextProfile":"long"}', (New-Object Text.UTF8Encoding($false)))
$null = Invoke-Case (New-FakeHost) $root
$a = $script:Captured['arguments']
Assert-Equal $a.KvContextProfile 'long' 'a saved long context profile reaches the host'
Assert-True (-not $a.ContainsKey('KvSlots') -and -not $a.ContainsKey('Embeddings') -and -not $a.ContainsKey('EmbeddingPort')) 'only the saved context profile is added'
[IO.File]::WriteAllText((Join-Path $root 'settings.json'), '{"slots":2,"embeddings":"on","embeddingPort":8091}', (New-Object Text.UTF8Encoding($false)))
$null = Invoke-Case (New-FakeHost) $root
$a = $script:Captured['arguments']
Assert-True ([int]$a.KvSlots -eq 2 -and -not $a.ContainsKey('KvContextProfile')) 'saved 2 requests at once reach the host'
Assert-True ($a.Embeddings -ceq 'on' -and [int]$a.EmbeddingPort -eq 8091) 'saved embeddings on and their port reach the host'
$root = New-Install
$null = Invoke-Case (New-FakeHost) $root
$a = $script:Captured['arguments']
Assert-Equal (@($a.Keys | Sort-Object) -join ',') 'ChatPage,ContextSize,IdleStopMinutes,InstallRoot,ModelId,NoWait,Profile,ServerPort,SourceRoot,Thinking' 'with the three settings at their defaults the arguments are the ones they always were'
# the embeddings refusal of the background start is recorded by its own code; only a code of the fixed form, never message text
$root = New-Install
[IO.File]::WriteAllText((Join-Path $root 'settings.json'), '{"embeddings":"on"}', (New-Object Text.UTF8Encoding($false)))
$r = Invoke-Case (New-FakeHost -StartBehavior 'embeddings-refused') $root
$file = Read-Result $root
Assert-Equal $r.result 'host-failed' 'an embeddings refusal is a failed start'
Assert-Equal ([string]$file.failureCode) 'embeddings-no-model' 'the embeddings refusal is recorded by its own code'
Assert-True ((Get-Content -LiteralPath (Join-Path $root 'state/signin-start.json') -Raw) -notmatch 'secret-looking') 'the embeddings refusal never records message text'
$r = Invoke-Case (New-FakeHost -StartBehavior 'embeddings-odd-code') $root
Assert-Equal ([string](Read-Result $root).failureCode) 'host-start-failed' 'an embeddings code that is not of the fixed form is recorded as host-start-failed'

# skipped-occupied (lock held before the start)
$root = New-Install
$r = Invoke-Case (New-FakeHost -Occupied $true) $root
Assert-Equal $r.result 'skipped-occupied' 'occupied lock is skipped'
Assert-Equal (Read-Result $root).result 'skipped-occupied' 'skipped-occupied written'
Assert-Equal (Count-Calls 'start') 0 'an occupied lock never calls the host'

# skipped-occupied (the host reports an active operation at start)
$root = New-Install
$r = Invoke-Case (New-FakeHost -StartBehavior 'busy') $root
Assert-Equal $r.result 'skipped-occupied' 'an active operation reported by the host is skipped'
Assert-Equal (Count-Calls 'start') 1 'still one attempt'

# refused-elevated
$root = New-Install
$r = Invoke-Case (New-FakeHost -Elevated $true) $root
Assert-Equal $r.result 'refused-elevated' 'an elevated session is refused'
$file = Read-Result $root
Assert-Equal $file.result 'refused-elevated' 'refused-elevated written'
Assert-True (-not [string]::IsNullOrEmpty([string]$file.failureCode)) 'refused-elevated carries a failure code'
Assert-Equal (Count-Calls 'start') 0 'an elevated session never calls the host'

# needs-setup: no saved request, a malformed one, and one without a model
$root = New-Install -WithRequest $false
$r = Invoke-Case (New-FakeHost) $root
Assert-Equal $r.result 'needs-setup' 'no saved request needs setup'
Assert-True ((Read-Result $root).failureCode -like 'needs-setup-*') 'needs-setup failure code is needs-setup-*'
Assert-Equal (Count-Calls 'start') 0 'needs-setup never calls the host'
$root = New-Install -WithRequest $false
[IO.File]::WriteAllText((Join-Path $root 'state/signin-start-request.json'), '{ not json', (New-Object Text.UTF8Encoding($false)))
$r = Invoke-Case (New-FakeHost) $root
Assert-Equal $r.result 'needs-setup' 'a malformed request needs setup'
Assert-Equal (Count-Calls 'start') 0 'a malformed request never calls the host'
$root = New-Install -RequestOverride ([ordered]@{ profile = 'balanced'; modelId = ''; contextSize = 0 })
$r = Invoke-Case (New-FakeHost) $root
Assert-Equal $r.result 'needs-setup' 'a request without a model needs setup'
$root = New-Install -RequestOverride ([ordered]@{ profile = 'turbo'; modelId = 'example-model'; contextSize = 0 })
$r = Invoke-Case (New-FakeHost) $root
Assert-Equal $r.result 'needs-setup' 'an unknown profile needs setup'
Assert-Equal (Count-Calls 'start') 0 'an invalid request never calls the host'

# host-failed: one attempt, no retry, the message is never recorded
$root = New-Install
$r = Invoke-Case (New-FakeHost -StartBehavior 'throw') $root
Assert-Equal $r.result 'host-failed' 'a host failure is recorded'
$file = Read-Result $root
Assert-Equal $file.result 'host-failed' 'host-failed written'
Assert-True (-not [string]::IsNullOrEmpty([string]$file.failureCode)) 'host-failed carries a failure code'
Assert-True ((Get-Content -LiteralPath (Join-Path $root 'state/signin-start.json') -Raw) -notmatch 'secret-looking') 'the exception message is never written'
Assert-Equal (Count-Calls 'start') 1 'a failed host start is not retried'
$root = New-Install
$r = Invoke-Case (New-FakeHost -StartBehavior 'job') $root
Assert-Equal $r.result 'host-failed' 'a job-contained start is host-failed'
Assert-Equal (Count-Calls 'start') 1 'a job-contained start is not retried'

# an API key refusal is recorded by its own code (never as the generic host-start-failed), and nothing is started without the key
$root = New-Install
$r = Invoke-Case (New-FakeHost -StartBehavior 'key-unavailable') $root
$file = Read-Result $root
Assert-Equal $r.result 'host-failed' 'a start refused for the API key is host-failed'
Assert-Equal ([string]$file.failureCode) 'api-key-unavailable' 'the result carries the typed api-key code of the refusal'
Assert-True ((Get-Content -LiteralPath (Join-Path $root 'state/signin-start.json') -Raw) -notmatch 'secret-looking') 'the message of a key refusal is never written'
Assert-Equal (Count-Calls 'start') 1 'a start refused for the API key is not retried'
# only a code of the fixed api-key form is taken from a failure; anything else stays the generic code
$root = New-Install
$r = Invoke-Case (New-FakeHost -StartBehavior 'key-odd-code') $root
$file = Read-Result $root
Assert-Equal ([string]$file.failureCode) 'host-start-failed' 'a code that is not of the api-key form is not recorded'
Assert-True ((Get-Content -LiteralPath (Join-Path $root 'state/signin-start.json') -Raw) -notmatch 'secret-looking|fl-TEXT') 'nothing from such a failure reaches the result'
# a key store with no saved setting: whether the key is required cannot be known, so nothing is started, and the result says why
$root = New-Install
[IO.File]::WriteAllBytes((Join-Path $root 'api-key.dat'), [byte[]](1, 2, 3, 4))
$r = Invoke-Case (New-FakeHost) $root
$file = Read-Result $root
Assert-Equal $r.result 'host-failed' 'a key store without a saved setting does not start'
Assert-Equal ([string]$file.failureCode) 'api-key-setting-unreadable' 'the result carries api-key-setting-unreadable'
Assert-Equal (Count-Calls 'start') 0 'the host is never asked to start when the key setting cannot be known'
# the same installation with the setting chosen starts, and the start is asked for the key exactly when it is on
[IO.File]::WriteAllText((Join-Path $root 'settings.json'), '{ "apiKey": "on" }')
$r = Invoke-Case (New-FakeHost) $root
Assert-Equal $r.result 'started' 'with the key setting on the start is requested'
Assert-Equal ([string]$script:Captured['arguments'].UseApiKey) 'on' 'the start is asked for the key'
[IO.File]::WriteAllText((Join-Path $root 'settings.json'), '{ "apiKey": "off" }')
$r = Invoke-Case (New-FakeHost) $root
Assert-Equal $r.result 'started' 'with the key setting off the start is requested'
Assert-True (-not $script:Captured['arguments'].ContainsKey('UseApiKey')) 'without the key the start arguments have no key flag'

# the saved allowSwitch (the window's "Allow switching models" setting) is honoured by the sign-in start, read through the window's own function:
# the host is then asked for -SwitchAllowed exactly as a window background start is, so the basis is written and the picker works after a sign-in start
$root = New-Install
[IO.File]::WriteAllText((Join-Path $root 'settings.json'), '{ "allowSwitch": true, "serverPort": 18181 }')
$r = Invoke-Case (New-FakeHost) $root
Assert-Equal $r.result 'started' 'with allowSwitch saved the start is requested'
Assert-True ($script:Captured['arguments'].ContainsKey('SwitchAllowed') -and $script:Captured['arguments'].SwitchAllowed -eq $true) 'a saved allowSwitch true: the launch arguments carry SwitchAllowed'
Assert-Equal ([int]$script:Captured['arguments'].ServerPort) 18181 'with allowSwitch saved the other saved serving settings still reach the host'
Assert-True (-not $script:Captured['arguments'].ContainsKey('UseApiKey')) 'allowSwitch alone does not ask for the key'
foreach ($noSwitch in @(
        @{ name = 'allowSwitch absent'; text = '{ "serverPort": 18181 }' },
        @{ name = 'allowSwitch false'; text = '{ "allowSwitch": false }' },
        @{ name = 'allowSwitch the text "true"'; text = '{ "allowSwitch": "true" }' },
        @{ name = 'allowSwitch 1'; text = '{ "allowSwitch": 1 }' },
        @{ name = 'settings that do not parse'; text = '{ not json' },
        @{ name = 'settings that are an array'; text = '[ { "allowSwitch": true } ]' })) {
    $root = New-Install
    [IO.File]::WriteAllText((Join-Path $root 'settings.json'), $noSwitch.text)
    $r = Invoke-Case (New-FakeHost) $root
    Assert-Equal $r.result 'started' "$($noSwitch.name): the launch still starts"
    Assert-True (-not $script:Captured['arguments'].ContainsKey('SwitchAllowed')) "$($noSwitch.name): no SwitchAllowed in the launch arguments"
}
$root = New-Install
$r = Invoke-Case (New-FakeHost) $root
Assert-True ($r.result -ceq 'started' -and -not $script:Captured['arguments'].ContainsKey('SwitchAllowed')) 'no settings.json: no SwitchAllowed, and the launch starts'
# the key and the switch setting are independent: both ride on the one start
$root = New-Install
[IO.File]::WriteAllText((Join-Path $root 'settings.json'), '{ "apiKey": "on", "allowSwitch": true }')
$r = Invoke-Case (New-FakeHost) $root
Assert-True ($r.result -ceq 'started' -and [string]$script:Captured['arguments'].UseApiKey -ceq 'on' -and $script:Captured['arguments'].SwitchAllowed -eq $true) 'key on and allowSwitch true: the one start carries UseApiKey on and SwitchAllowed'
# unreadable settings with the key store present: #65's typed refusal stays, and nothing is started (the switch setting is never a way around it)
$root = New-Install
[IO.File]::WriteAllBytes((Join-Path $root 'api-key.dat'), [byte[]](1, 2, 3, 4))
[IO.File]::WriteAllText((Join-Path $root 'settings.json'), '{ not json')
$r = Invoke-Case (New-FakeHost) $root
$file = Read-Result $root
Assert-True ($r.result -ceq 'host-failed' -and [string]$file.failureCode -ceq 'api-key-setting-unreadable' -and (Count-Calls 'start') -eq 0) 'unreadable settings with a key store: the typed api-key-setting-unreadable refusal, nothing started'

# the sign-in path never loads window code: the opt-in reader is the shared src/FastLlm.UiSettings.ps1, and SignInStart.ps1 neither loads nor names
# the window's files (a source scan), and the reader resolves with the window's files absent (a child process with only the two files copied)
$signInSource = [IO.File]::ReadAllText((Join-Path $repo 'src/FastLlm.SignInStart.ps1'))
$signInCode = (($signInSource -split "`n") | Where-Object { $_.TrimStart() -cnotlike '#*' }) -join "`n"
Assert-True ($signInCode -cnotmatch 'FastLlm\.UiFlow|fast-llm-ui|Windows\.Forms|Add-Type|Read-FastLlmUiSettings|Write-FastLlmUiSettings') 'SignInStart.ps1 code neither loads nor references FastLlm.UiFlow.ps1, fast-llm-ui.ps1, forms or the window settings functions'
Assert-True ($signInCode -cmatch "FastLlm\.UiSettings\.ps1") 'SignInStart.ps1 loads the shared reader file FastLlm.UiSettings.ps1'
$sharedSource = [IO.File]::ReadAllText((Join-Path $repo 'src/FastLlm.UiSettings.ps1'))
Assert-True ($sharedSource -cnotmatch '(?m)^\s*[^#\r\n]*(\. \(Join-Path|Add-Type|Windows\.Forms|System\.Windows|\bSet-Content\b|WriteAllText|Out-File)') 'the shared reader file loads nothing, has no forms or Add-Type and writes nothing'
$readerDefinitions = @(Get-ChildItem -LiteralPath (Join-Path $repo 'src') -Filter '*.ps1' | Where-Object { [IO.File]::ReadAllText($_.FullName) -cmatch '(?m)^function Get-FastLlmUiAllowSwitch\b' } | ForEach-Object Name)
Assert-True ($readerDefinitions.Count -eq 1 -and $readerDefinitions[0] -ceq 'FastLlm.UiSettings.ps1') 'there is one copy of the reader and it lives in FastLlm.UiSettings.ps1'
$isolated = Join-Path $work ('isolated-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $isolated | Out-Null
foreach ($copyName in @('FastLlm.SignInStart.ps1', 'FastLlm.UiSettings.ps1')) { Copy-Item -LiteralPath (Join-Path $repo "src/$copyName") -Destination (Join-Path $isolated $copyName) }
Assert-True (@(Get-ChildItem -LiteralPath $isolated -File).Count -eq 2 -and -not (Test-Path -LiteralPath (Join-Path $isolated 'FastLlm.UiFlow.ps1'))) 'the isolated folder holds only the sign-in file and the shared reader (no window file)'
$isolatedInstall = New-Install
$isolatedChild = Join-Path $work ('isolated-child-' + [guid]::NewGuid().ToString('N') + '.ps1')
[IO.File]::WriteAllText($isolatedChild, @'
param([string]$Folder, [string]$Root)
$ErrorActionPreference = 'Stop'
. (Join-Path $Folder 'FastLlm.SignInStart.ps1')
$source = (Get-Command Get-FastLlmUiAllowSwitch).ScriptBlock.File
$uiFlowLoaded = [bool](Get-Command Get-FastLlmUiPendingDecision -ErrorAction SilentlyContinue)
$settingsPath = Join-Path $Root 'settings.json'
$absent = Get-FastLlmSignInAllowSwitch -InstallRoot $Root
[IO.File]::WriteAllText($settingsPath, '{ "allowSwitch": true }')
$on = Get-FastLlmSignInAllowSwitch -InstallRoot $Root
[IO.File]::WriteAllText($settingsPath, '{ not json')
$bad = Get-FastLlmSignInAllowSwitch -InstallRoot $Root
Write-Output ('RESULT ' + (Split-Path -Leaf $source) + ' ' + $uiFlowLoaded + ' ' + $absent + ' ' + $on + ' ' + $bad)
'@, (New-Object Text.UTF8Encoding($false)))
$isolatedShell = (Get-Process -Id $PID).Path
$isolatedOutput = @(& $isolatedShell -NoLogo -NoProfile -NonInteractive -File $isolatedChild -Folder $isolated -Root $isolatedInstall 2>&1 | ForEach-Object { [string]$_ })
Assert-True (($isolatedOutput -join "`n") -ceq 'RESULT FastLlm.UiSettings.ps1 False False True False') "with the window's files absent the sign-in reader resolves from the shared file: not loaded, absent off, true on, unreadable off (got: $($isolatedOutput -join ' | '))"

# the launcher tool itself: it runs in its own process, so it must bring in the FastLlm module (the key-store pre-check of the real
# background start lives there). The real Start-FastLlmBackgroundHost runs with its Windows-only checks and its request writer replaced
# by a probe that records the request and stops: nothing is ever launched.
function Invoke-LauncherTool([string]$Root, [string]$StoreMode) {
    $probeFile = Join-Path $Root 'probe-request.json'
    $childPath = Join-Path $work ('launcher-child-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $childText = @'
param([string]$Repo, [string]$Root, [string]$StoreMode, [string]$ProbeFile)
$ErrorActionPreference = 'Stop'
$script:FastLlmSignInHost = @{
    IsElevated = { $false }
    IsOccupied = { param($InstallRoot) $false }
    Sleep = { param($Seconds) }
    Start = {
        param($Arguments)
        if ($StoreMode -ceq 'readable') {
            & (Get-Module FastLlm) {
                param($Protector)
                $script:FastLlmApiKeyProtector = $Protector
            } @{
                Protect = { param([byte[]]$Bytes) $out = New-Object 'System.Collections.Generic.List[byte]'; foreach ($b in $Bytes) { $out.Add([byte]($b -bxor 0x5A)) }; return , ($out.ToArray()) }
                Unprotect = { param([byte[]]$Bytes) $out = New-Object 'System.Collections.Generic.List[byte]'; foreach ($b in $Bytes) { $out.Add([byte]($b -bxor 0x5A)) }; return , ($out.ToArray()) }
            }
            $null = Initialize-FastLlmApiKeyStore -InstallRoot $Root
        }
        else { [IO.File]::WriteAllBytes((Join-Path $Root 'api-key.dat'), [byte[]](1, 2, 3, 4, 5, 6, 7, 8)) }
        function Assert-FastLlmBackgroundNativeHost { }
        function Assert-FastLlmBackgroundPrivateState { param($InstallRoot) }
        function Get-FastLlmBackgroundHostStatus { param($InstallRoot, $SourceRoot) return [pscustomobject]@{ occupied = $false } }
        function Get-FastLlmBackgroundSourcePins { param($SourceRoot) return @{} }
        function Write-FastLlmBackgroundDocument { param($Path, $Value, [switch]$CreateNew) [IO.File]::WriteAllText($ProbeFile, ($Value | ConvertTo-Json -Compress)); throw 'launcher-probe: the request was written; nothing is launched' }
        Start-FastLlmBackgroundHost @Arguments | Out-Null
    }
}
. (Join-Path $Repo 'tools/signin-start.ps1') -InstallRoot $Root -DelaySeconds 0
'@
    [IO.File]::WriteAllText($childPath, $childText, (New-Object Text.UTF8Encoding($false)))
    $shell = (Get-Process -Id $PID).Path
    $null = & $shell -NoLogo -NoProfile -NonInteractive -File $childPath -Repo $repo -Root $Root -StoreMode $StoreMode -ProbeFile $probeFile 2>&1
    $code = $LASTEXITCODE
    Remove-Item -LiteralPath $childPath -Force
    return [pscustomobject]@{ exitCode = $code; probeFile = $probeFile }
}
$root = New-Install
[IO.File]::WriteAllText((Join-Path $root 'settings.json'), '{ "apiKey": "on" }')
$tool = Invoke-LauncherTool $root 'readable'
$file = Read-Result $root
Assert-True (Test-Path -LiteralPath $tool.probeFile) "the launcher tool with the key on and a readable key store reaches the point where the request is written (result: $($file.result) $($file.failureCode))"
Assert-Equal ([string](Get-Content -LiteralPath $tool.probeFile -Raw | ConvertFrom-Json).apiKey) 'on' 'the request of a sign-in start with the key on carries the key flag (the host then runs the 401/200 proof)'
$root = New-Install
[IO.File]::WriteAllText((Join-Path $root 'settings.json'), '{ "apiKey": "on" }')
$tool = Invoke-LauncherTool $root 'unreadable'
$file = Read-Result $root
Assert-Equal ([string]$file.result) 'host-failed' 'an unreadable key store is a failed start'
Assert-Equal ([string]$file.failureCode) 'api-key-unavailable' 'the launcher tool records the typed api-key-unavailable code for an unreadable key store'
Assert-True (-not (Test-Path -LiteralPath $tool.probeFile)) 'nothing is requested when the key store is unreadable'

# the real launcher tool (its own process, the real background start): a saved allowSwitch reaches the request the host is given
$root = New-Install
[IO.File]::WriteAllText((Join-Path $root 'settings.json'), '{ "apiKey": "on", "allowSwitch": true }')
$tool = Invoke-LauncherTool $root 'readable'
$file = Read-Result $root
Assert-True (Test-Path -LiteralPath $tool.probeFile) "the launcher tool with the key and the switch setting on reaches the point where the request is written (result: $($file.result) $($file.failureCode))"
$probeRequest = Get-Content -LiteralPath $tool.probeFile -Raw | ConvertFrom-Json
Assert-True ([string]$probeRequest.apiKey -ceq 'on' -and $probeRequest.allowSwitch -eq $true) 'the request of a sign-in start carries both the key flag and allowSwitch (the host then writes the switch basis)'
$root = New-Install
[IO.File]::WriteAllText((Join-Path $root 'settings.json'), '{ "apiKey": "on" }')
$tool = Invoke-LauncherTool $root 'readable'
$probeRequest = Get-Content -LiteralPath $tool.probeFile -Raw | ConvertFrom-Json
Assert-True ([string]$probeRequest.apiKey -ceq 'on' -and -not $probeRequest.PSObject.Properties['allowSwitch']) 'without a saved allowSwitch the request of a sign-in start has no allowSwitch field'

# a second run overwrites the first result
$root = New-Install
$null = Invoke-Case (New-FakeHost -StartBehavior 'throw') $root
$null = Invoke-Case (New-FakeHost) $root
Assert-Equal (Read-Result $root).result 'started' 'the latest attempt replaces the previous result'
Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $root 'state') -Filter '*.tmp*').Count -eq 0) 'no temporary file is left behind'

# a reparse-point or file state folder is refused (the result is not written through it)
if ($env:OS -eq 'Windows_NT') {
    $root = Join-Path $work 'junction-root'
    New-Item -ItemType Directory -Path $root | Out-Null
    $target = Join-Path $work 'junction-target'
    New-Item -ItemType Directory -Path $target | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $root 'state') -Target $target | Out-Null
    $thrown = $false
    try { $null = Invoke-Case (New-FakeHost) $root } catch { $thrown = $true }
    Assert-True $thrown 'a junction state folder is refused'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $target 'signin-start.json'))) 'nothing is written through a junction'
}

# --- the Settings switch: state text, last result, toggling, command line --------------------------------------------------
$switchApp = 'C:\Program Files\Example App'
$switchCommand = Get-FastLlmSignInStartCommand -AppRoot $switchApp
function New-SwitchInstall { $r = Join-Path $work ('switch-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path (Join-Path $r 'state') -Force | Out-Null; return $r }
$script:FastLlmSignInHardware = { param($SourceRoot, $InstallRoot) 'testprint0001' }
function Write-ReadyRecord($Root, $Extra = @{}) {
    $record = [ordered]@{ kind = 'api-smoke-only'; hardwareFingerprint = 'testprint0001'; modelId = 'example-model'; modelSha256 = 'abc'; catalogSha256 = 'def'; profile = 'balanced'; requestedContextSize = 8192; backend = 'vulkan' }
    foreach ($key in @($Extra.Keys)) { if ($null -eq $Extra[$key]) { $record.Remove($key) } else { $record[$key] = $Extra[$key] } }
    [IO.File]::WriteAllText((Join-Path $Root 'state/testprint0001.last-ready.json'), ($record | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
}
function Read-SwitchRequestFile($Root) { $p = Join-Path $Root 'state/signin-start-request.json'; if (Test-Path -LiteralPath $p) { return (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json) }; return $null }
function Write-SwitchResult($Root, $Json) { [IO.File]::WriteAllText((Join-Path $Root 'state/signin-start.json'), $Json, (New-Object Text.UTF8Encoding($false))) }

# checked only for state 'on'
$root = New-SwitchInstall
$script:FastLlmSignInRegistry = New-FakeRegistry
$view = Get-FastLlmSignInSettingsView -AppRoot $switchApp -InstallRoot $root
Assert-True ($view.checked -eq $false) 'value missing: unchecked'
Assert-Equal $view.stateText 'Off.' 'value missing: plain off text'
$script:FastLlmSignInRegistry.Store.run['FastLLM'] = $switchCommand
$view = Get-FastLlmSignInSettingsView -AppRoot $switchApp -InstallRoot $root
Assert-True ($view.checked -eq $true) 'on: checked'
Assert-Equal $view.stateText 'FastLLM starts when you sign in.' 'on: text'
$script:FastLlmSignInRegistry.Store.run['FastLLM'] = '"C:\Other\FastLLM.cmd" /signin'
$view = Get-FastLlmSignInSettingsView -AppRoot $switchApp -InstallRoot $root
Assert-True ($view.checked -eq $false) 'mismatched command: unchecked'
Assert-True ($view.stateText -like '*different FastLLM location*') 'mismatched command: says why'
$script:FastLlmSignInRegistry.Store.run['FastLLM'] = $switchCommand
$script:FastLlmSignInRegistry.Store.approved['FastLLM'] = [byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
$view = Get-FastLlmSignInSettingsView -AppRoot $switchApp -InstallRoot $root
Assert-True ($view.checked -eq $false) 'disabled in Startup apps: unchecked'
Assert-True ($view.stateText -like '*Startup apps*' -and $view.stateText -like '*turn it back on*') 'disabled in Startup apps: tells the user to re-enable it in Windows'

# toggling calls Set/Remove exactly once and re-reads the state
$root = New-SwitchInstall
Write-ReadyRecord $root
$script:FastLlmSignInRegistry = New-FakeRegistry
$view = Set-FastLlmSignInStartEnabled -AppRoot $switchApp -InstallRoot $root -Enabled $true
Assert-Equal @($script:FastLlmSignInRegistry.Store.calls | Where-Object { $_ -ceq 'set-run:FastLLM' }).Count 1 'on calls Set exactly once'
Assert-Equal @($script:FastLlmSignInRegistry.Store.calls | Where-Object { $_ -like 'remove-run:*' }).Count 0 'on never calls Remove'
Assert-True ($view.checked -eq $true) 'on is read back as checked'
$view = Set-FastLlmSignInStartEnabled -AppRoot $switchApp -InstallRoot $root -Enabled $false
Assert-Equal @($script:FastLlmSignInRegistry.Store.calls | Where-Object { $_ -ceq 'remove-run:FastLLM' }).Count 1 'off calls Remove exactly once'
Assert-Equal @($script:FastLlmSignInRegistry.Store.calls | Where-Object { $_ -ceq 'set-run:FastLLM' }).Count 1 'off never calls Set again'
Assert-True ($view.checked -eq $false) 'off is read back as unchecked'
# disabled by Windows: asking for on writes nothing and says so
$script:FastLlmSignInRegistry = New-FakeRegistry
$script:FastLlmSignInRegistry.Store.run['FastLLM'] = $switchCommand
$script:FastLlmSignInRegistry.Store.approved['FastLLM'] = [byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
$view = Set-FastLlmSignInStartEnabled -AppRoot $switchApp -InstallRoot $root -Enabled $true
Assert-Equal $script:FastLlmSignInRegistry.Store.calls.Count 0 'a Startup apps disable is never rewritten'
Assert-True ($view.checked -eq $false -and $view.reason -ceq 'disabled-in-startup-apps') 'it still reads as disabled by Windows'

# the last attempt in plain words
Assert-True ($null -eq (Read-FastLlmSignInResult -InstallRoot $root)) 'no result file: no last result'
Assert-Equal (Get-FastLlmSignInResultText -Result $null) 'No start at sign-in has been recorded yet.' 'no result file: plain text'
Write-SwitchResult $root '{"time":"2026-01-02T03:04:05Z","result":"started","failureCode":null}'
Assert-Equal (Get-FastLlmSignInResultText -Result (Read-FastLlmSignInResult -InstallRoot $root)) 'Started at sign-in (2026-01-02T03:04:05Z).' 'started text'
Write-SwitchResult $root '{"time":"2026-01-02T03:04:05Z","result":"host-failed","failureCode":"job-contained"}'
Assert-Equal (Get-FastLlmSignInResultText -Result (Read-FastLlmSignInResult -InstallRoot $root)) 'Start at sign-in failed: job-contained (2026-01-02T03:04:05Z).' 'failed text carries the code'
Write-SwitchResult $root '{"time":"2026-01-02T03:04:05Z","result":"skipped-occupied","failureCode":null}'
Assert-True ((Get-FastLlmSignInResultText -Result (Read-FastLlmSignInResult -InstallRoot $root)) -like '*already running or busy*') 'skipped text'
Write-SwitchResult $root '{"time":"2026-01-02T03:04:05Z","result":"refused-elevated","failureCode":"elevated-session"}'
Assert-True ((Get-FastLlmSignInResultText -Result (Read-FastLlmSignInResult -InstallRoot $root)) -like '*administrator*') 'elevated text'
Write-SwitchResult $root '{"time":"2026-01-02T03:04:05Z","result":"needs-setup","failureCode":"needs-setup-model"}'
Assert-True ((Get-FastLlmSignInResultText -Result (Read-FastLlmSignInResult -InstallRoot $root)) -like '*no saved model*') 'needs-setup text'
Write-SwitchResult $root '{ not json'
Assert-True ($null -eq (Read-FastLlmSignInResult -InstallRoot $root)) 'a malformed result file reads as no result'
Write-SwitchResult $root '{"time":"2026-01-02T03:04:05Z","result":"started","failureCode":null}'
$script:FastLlmSignInRegistry = New-FakeRegistry
Assert-True ((Get-FastLlmSignInSettingsView -AppRoot $switchApp -InstallRoot $root).lastResultText -like 'Started at sign-in*') 'the view carries the last result text'

# command line: show, on, off
$root = New-SwitchInstall
Write-ReadyRecord $root
$script:FastLlmSignInRegistry = New-FakeRegistry
$view = Invoke-FastLlmSignInSettingsAction -AppRoot $switchApp -InstallRoot $root -Enabled $null
Assert-Equal $script:FastLlmSignInRegistry.Store.calls.Count 0 'show reads only'
Assert-True (@(Format-FastLlmSignInCliLines -View $view) -ccontains 'startAtSignIn: off') 'show: off'
$view = Invoke-FastLlmSignInSettingsAction -AppRoot $switchApp -InstallRoot $root -Enabled $true
Assert-True (@(Format-FastLlmSignInCliLines -View $view) -ccontains 'startAtSignIn: on') 'on: shows on'
Assert-Equal (Get-FastLlmSignInCliFields -View $view).startAtSignIn 'on' 'on: json field'
Assert-Equal @($script:FastLlmSignInRegistry.Store.calls | Where-Object { $_ -ceq 'set-run:FastLLM' }).Count 1 'cli on calls Set once'
$view = Invoke-FastLlmSignInSettingsAction -AppRoot $switchApp -InstallRoot $root -Enabled $false
Assert-True (@(Format-FastLlmSignInCliLines -View $view) -ccontains 'startAtSignIn: off') 'off: shows off'
Assert-Equal @($script:FastLlmSignInRegistry.Store.calls | Where-Object { $_ -ceq 'remove-run:FastLLM' }).Count 1 'cli off calls Remove once'
Assert-Equal (@(Format-FastLlmSignInCliLines -View $null)[0]) 'startAtSignIn: unavailable' 'an unreadable registry shows unavailable'
Assert-Equal (Get-FastLlmSignInCliFields -View $null).startAtSignIn 'unavailable' 'an unreadable registry gives an unavailable json field'

# the saved request: built from the Ready record, written before the Run value, removed with it
$root = New-SwitchInstall
$script:FastLlmSignInRegistry = New-FakeRegistry
$view = Set-FastLlmSignInStartEnabled -AppRoot $switchApp -InstallRoot $root -Enabled $true
Assert-True ($view.refused -eq $true -and $view.checked -eq $false) 'on with no Ready record is refused'
Assert-Equal $view.stateText 'Start FastLLM once with the setup you want; then turn this on.' 'the refusal is plain words'
Assert-Equal $script:FastLlmSignInRegistry.Store.calls.Count 0 'a refusal writes nothing to the registry'
Assert-True ($null -eq (Read-SwitchRequestFile $root)) 'a refusal writes no request'
# records that do not qualify are refused too: another PC, no profile (older record), bad profile, bad context, wrong kind
foreach ($case in @(
    @{ name = 'another PC'; extra = @{ hardwareFingerprint = 'otherprint' } },
    @{ name = 'no profile'; extra = @{ profile = $null } },
    @{ name = 'unknown profile'; extra = @{ profile = 'turbo' } },
    @{ name = 'no context'; extra = @{ requestedContextSize = $null } },
    @{ name = 'negative context'; extra = @{ requestedContextSize = -1 } },
    @{ name = 'no model'; extra = @{ modelId = '' } },
    @{ name = 'wrong kind'; extra = @{ kind = 'other' } })) {
    $root = New-SwitchInstall
    Write-ReadyRecord $root $case.extra
    $script:FastLlmSignInRegistry = New-FakeRegistry
    $view = Set-FastLlmSignInStartEnabled -AppRoot $switchApp -InstallRoot $root -Enabled $true
    Assert-True ($view.refused -eq $true -and $script:FastLlmSignInRegistry.Store.calls.Count -eq 0 -and $null -eq (Read-SwitchRequestFile $root)) "a Ready record that is $($case.name) is refused and nothing is written"
}
$root = New-SwitchInstall
[IO.File]::WriteAllText((Join-Path $root 'state/testprint0001.last-ready.json'), '{ not json', (New-Object Text.UTF8Encoding($false)))
$script:FastLlmSignInRegistry = New-FakeRegistry
Assert-True ((Set-FastLlmSignInStartEnabled -AppRoot $switchApp -InstallRoot $root -Enabled $true).refused -eq $true) 'a garbled Ready record is refused'
$script:FastLlmSignInHardware = { param($SourceRoot, $InstallRoot) $null }
$root = New-SwitchInstall
Write-ReadyRecord $root
Assert-True ((Set-FastLlmSignInStartEnabled -AppRoot $switchApp -InstallRoot $root -Enabled $true).refused -eq $true) 'an unreadable hardware fingerprint is refused'
$script:FastLlmSignInHardware = { param($SourceRoot, $InstallRoot) 'testprint0001' }

# a Ready record: the request is written with the launcher's fields, then the Run value (order proven by a recording registry)
$root = New-SwitchInstall
Write-ReadyRecord $root
$script:FastLlmSignInRegistry = New-FakeRegistry
$requestPath = Join-Path $root 'state/signin-start-request.json'
$store = $script:FastLlmSignInRegistry.Store
$script:FastLlmSignInRegistry.SetRunValue = { param($Name, $Value) $store['requestExisted'] = (Test-Path -LiteralPath $requestPath); [void]$store.calls.Add("set-run:$Name"); $store.run[$Name] = $Value }.GetNewClosure()
$view = Set-FastLlmSignInStartEnabled -AppRoot $switchApp -InstallRoot $root -Enabled $true
Assert-True ($view.checked -eq $true -and $view.refused -eq $false) 'on with a Ready record turns on'
Assert-True ($store['requestExisted'] -eq $true) 'the request exists before the Run value is set'
$requestFile = Read-SwitchRequestFile $root
Assert-Equal (@($requestFile.PSObject.Properties.Name) -join ',') 'profile,modelId,contextSize' 'the request holds exactly the launcher fields'
Assert-Equal $requestFile.profile 'balanced' 'request profile'
Assert-Equal $requestFile.modelId 'example-model' 'request model'
Assert-Equal ([int]$requestFile.contextSize) 8192 'request context'
Assert-True ((Get-Content -LiteralPath $requestPath -Raw) -notmatch '(?i)[a-z]:\\|/|key|token|prompt') 'the request holds no path, key or prompt text'
Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $root 'state') -Filter '*.tmp*').Count -eq 0) 'no temporary file is left behind'
# the launcher reads exactly that request and starts the host with its values (end to end through the seams)
$script:Calls = New-Object System.Collections.ArrayList
$launch = Invoke-Case (New-FakeHost) $root
Assert-Equal $launch.result 'started' 'a written request launches (no needs-setup)'
$a = $script:Captured['arguments']
Assert-Equal $a.ModelId 'example-model' 'the host gets the saved model'
Assert-Equal $a.Profile 'balanced' 'the host gets the saved profile'
Assert-Equal ([int]$a.ContextSize) 8192 'the host gets the saved context'
# toggle-off removes the Run value and the request
$view = Set-FastLlmSignInStartEnabled -AppRoot $switchApp -InstallRoot $root -Enabled $false
Assert-True (-not (Test-Path -LiteralPath $requestPath)) 'off removes the saved request'
Assert-True ($view.checked -eq $false -and -not $script:FastLlmSignInRegistry.Store.run.ContainsKey('FastLLM')) 'off removes the Run value'
$null = Set-FastLlmSignInStartEnabled -AppRoot $switchApp -InstallRoot $root -Enabled $false   # off twice is harmless
# a missing or garbled request still gives needs-setup
$launch = Invoke-Case (New-FakeHost) $root
Assert-Equal $launch.result 'needs-setup' 'with the request removed the launcher gives needs-setup'
# a Run-value failure rolls the request back
$root = New-SwitchInstall
Write-ReadyRecord $root
$script:FastLlmSignInRegistry = New-FakeRegistry
$script:FastLlmSignInRegistry.SetRunValue = { param($Name, $Value) throw 'registry write denied' }
$thrown = $false
try { $null = Set-FastLlmSignInStartEnabled -AppRoot $switchApp -InstallRoot $root -Enabled $true } catch { $thrown = $true }
Assert-True $thrown 'a Run-value failure is reported'
Assert-True ($null -eq (Read-SwitchRequestFile $root)) 'a Run-value failure removes the request again'
# a Startup apps disable writes neither the request nor the value
$root = New-SwitchInstall
Write-ReadyRecord $root
$script:FastLlmSignInRegistry = New-FakeRegistry
$script:FastLlmSignInRegistry.Store.run['FastLLM'] = $switchCommand
$script:FastLlmSignInRegistry.Store.approved['FastLLM'] = [byte[]](3, 0, 0, 0)
$null = Set-FastLlmSignInStartEnabled -AppRoot $switchApp -InstallRoot $root -Enabled $true
Assert-True ($null -eq (Read-SwitchRequestFile $root)) 'a Startup apps disable writes no request'
# the runtime writes the profile and requested context into the Ready record, and only at Ready
$runtimeText = Get-Content -LiteralPath (Join-Path $repo 'src/FastLlm.Runtime.ps1') -Raw
Assert-True ($runtimeText -match "lastReady\.profile = \[string\]\`$Plan\.profile" -and $runtimeText -match 'lastReady\.requestedContextSize') 'the Ready record carries the profile and the requested context'
Assert-True ($runtimeText.IndexOf('$lastReady = [ordered]') -gt $runtimeText.IndexOf('$reachedReady = $true')) 'the Ready record is written only after Ready'

# nothing in a start path registers it: only the settings action and the window checkbox name the writers
$callers = @()
foreach ($file in @(Get-ChildItem -LiteralPath $repo -Recurse -File -Include '*.ps1', '*.psm1', '*.cmd' | Where-Object { $_.FullName -notmatch '[\\/](tests|\.git)[\\/]' })) {
    $text = Get-Content -LiteralPath $file.FullName -Raw
    if ($text -match 'Set-FastLlmSignInStart(Enabled)?\b|Invoke-FastLlmSignInSettingsAction') { $callers += $file.Name }
}
Assert-True ($callers.Count -eq 4 -and $callers -ccontains 'FastLlm.SignInStart.ps1' -and $callers -ccontains 'fast-llm-ui.ps1' -and $callers -ccontains 'FastLlm.UiFluentSettings.ps1' -and $callers -ccontains 'fast-llm.ps1') 'only the sign-in module, the window, the fluent Settings page and the CLI settings action can register'
# the fluent Settings page is the window checkbox handler's copy: its one call sits only inside Invoke-FastLlmUiFluentSettingsSignIn
$fluentSettingsText = Get-Content -LiteralPath (Join-Path $repo 'src/FastLlm.UiFluentSettings.ps1') -Raw
$fluentSignInAt = $fluentSettingsText.IndexOf('function Invoke-FastLlmUiFluentSettingsSignIn')
$fluentSignInEnd = $fluentSettingsText.IndexOf("`nfunction ", $fluentSignInAt + 1)
if ($fluentSignInEnd -lt 0) { $fluentSignInEnd = $fluentSettingsText.Length }
Assert-True ($fluentSignInAt -ge 0 -and [regex]::Matches($fluentSettingsText, 'Set-FastLlmSignInStart(Enabled)?\b|Invoke-FastLlmSignInSettingsAction').Count -eq 1 -and $fluentSettingsText.IndexOf('Set-FastLlmSignInStartEnabled') -gt $fluentSignInAt -and $fluentSettingsText.IndexOf('Set-FastLlmSignInStartEnabled') -lt $fluentSignInEnd) 'the fluent Settings page registers only inside Invoke-FastLlmUiFluentSettingsSignIn'
$cliText = Get-Content -LiteralPath (Join-Path $repo 'fast-llm.ps1') -Raw
$settingsCase = $cliText.Substring($cliText.IndexOf("        'settings' {"), $cliText.IndexOf("        'status' {") - $cliText.IndexOf("        'settings' {"))
Assert-True ($settingsCase -match "ContainsKey\('StartAtSignIn'\)") 'the CLI registers only when -StartAtSignIn is bound'
Assert-True ($cliText -match "ContainsKey\('StartAtSignIn'\) -and \`$effectiveAction -ne 'settings'") 'the CLI refuses -StartAtSignIn outside settings'
$beforeSettings = $cliText.Substring(0, $cliText.IndexOf("        'settings' {"))
Assert-True ($beforeSettings -notmatch 'Set-FastLlmSignInStart|Invoke-FastLlmSignInSettingsAction') 'no earlier action in the CLI registers'
Assert-True ($cliText -match '(?s)\[ValidateSet\(''on'', ''off''\)\]\s*\[string\] \$StartAtSignIn') 'the CLI parameter is on or off'
$uiText = Get-Content -LiteralPath (Join-Path $repo 'fast-llm-ui.ps1') -Raw
$clickAt = $uiText.IndexOf('$startBox.Add_Click')
Assert-True ($clickAt -gt 0 -and $uiText.IndexOf('Set-FastLlmSignInStartEnabled') -gt $clickAt -and $uiText.LastIndexOf('Set-FastLlmSignInStartEnabled') -eq $uiText.IndexOf('Set-FastLlmSignInStartEnabled')) 'the window registers only from the checkbox click handler'
Assert-True ($uiText -match 'Get-FastLlmSignInSettingsView') 'the window reads the checked state from the Run value view'
Assert-True ($uiText -notmatch '(?i)settings\.json[^\r\n]*signin|signin[^\r\n]*settings\.json') 'no settings.json key for start at sign-in'
$servingModule = Get-Content -LiteralPath (Join-Path $repo 'src/FastLlm.ServingSettings.ps1') -Raw
Assert-True ($servingModule -notmatch '(?i)signin|StartAtSignIn') 'the serving settings file never stores the switch'
# no existing parameter name is a prefix of the new one, and the new one is not a prefix of an existing one
$paramNames = @([regex]::Matches((($cliText -split '(?m)^param\(')[1] -split '(?m)^\)')[0], '(?m)^\s*(?:\[[^\]]*\]\s*)+\$([A-Za-z]+)') | ForEach-Object { $_.Groups[1].Value })
Assert-True ($paramNames -contains 'StartAtSignIn') 'the parameter is declared'
foreach ($other in @($paramNames | Where-Object { $_ -cne 'StartAtSignIn' })) {
    Assert-True (-not $other.StartsWith('StartAtSignIn', [StringComparison]::OrdinalIgnoreCase) -and -not 'StartAtSignIn'.StartsWith($other, [StringComparison]::OrdinalIgnoreCase)) "parameter $other does not collide with StartAtSignIn as a prefix"
}
Assert-True (@($paramNames | Where-Object { $_.StartsWith('Start', [StringComparison]::OrdinalIgnoreCase) }).Count -eq 1) 'the prefix -Start still resolves to one parameter'

# --- static checks: install registers nothing; uninstall removes both values; the launcher files exist -------------------
$iss = Get-Content -LiteralPath (Join-Path $repo 'installer/FastLLM.iss') -Raw
$beforeUninstall = $iss.Substring(0, $iss.IndexOf('procedure CurUninstallStepChanged'))
Assert-True ($beforeUninstall -notmatch '(?i)CurrentVersion\\Run') 'nothing before the uninstall step names the Run key (install never registers)'
Assert-True ($iss -notmatch '(?im)^\[Registry\]') 'the installer has no [Registry] section that could create the value'
$uninstall = $iss.Substring($iss.IndexOf('procedure CurUninstallStepChanged'))
Assert-True ($uninstall -match "RegDeleteValue\(HKCU, 'Software\\Microsoft\\Windows\\CurrentVersion\\Run', 'FastLLM'\)") 'uninstall removes the Run value'
Assert-True ($uninstall -match "RegDeleteValue\(HKCU, 'Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved\\Run', 'FastLLM'\)") 'uninstall removes the StartupApproved value'
$cmdText = Get-Content -LiteralPath (Join-Path $repo 'FastLLM.cmd') -Raw
Assert-True (-not (Test-Path -LiteralPath (Join-Path $repo 'FastLLM-SignIn.cmd'))) 'there is no second launcher: FastLLM.cmd is the only one that sets a policy'
Assert-True ($cmdText -match '(?m)^if /i "%~1"=="/signin" goto signin\s*$') 'FastLLM.cmd branches on the /signin argument'
Assert-True ($cmdText -match 'signin-start\.ps1') 'the sign-in branch runs the launcher tool'
Assert-True ($cmdText -notmatch '(?i)bypass') 'FastLLM.cmd never uses Bypass'
Assert-True ($cmdText -notmatch '(?i)-InstallRoot') 'FastLLM.cmd never passes the app folder as the data root'
$toolText = Get-Content -LiteralPath (Join-Path $repo 'tools/signin-start.ps1') -Raw
Assert-True ($toolText -match 'Get-FastLlmSignInDefaultInstallRoot') 'the launcher tool defaults the data root through the helper'
Assert-True ($toolText -notmatch '\$InstallRoot\s*=\s*\$source') 'the launcher tool never defaults the data root to the app folder'
Assert-True ($cmdText -match '(?im)^\s*if /i "%FASTLLM_POLICY%"=="Restricted" set "FASTLLM_EP=-ExecutionPolicy RemoteSigned"\s*$') 'the sign-in cmd lifts a Restricted policy like FastLLM.cmd'
Assert-True ($cmdText -match '(?im)^\s*if /i "%FASTLLM_POLICY%"=="Undefined" set "FASTLLM_EP=-ExecutionPolicy RemoteSigned"\s*$') 'the sign-in cmd lifts an Undefined policy like FastLLM.cmd'
Assert-True (Test-Path -LiteralPath (Join-Path $repo 'tools/signin-start.ps1')) 'the launcher tool exists'
$module = Get-Content -LiteralPath (Join-Path $repo 'src/FastLlm.SignInStart.ps1') -Raw
Assert-True (-not $module.Contains('Idle' + 'StopMinutes')) 'the sign-in helper never names the idle stop parameter (the bench invariant exempts only the settings module)'
Assert-True ($module -notmatch '(?i)idle' + 'stop') 'the sign-in helper never names the idle stop in any case'
Assert-True ($module -notmatch '\?\?|-AsHashtable|ForEach-Object\s+-Parallel') 'no PowerShell 7 only syntax in the helper'

# --- Windows only: the default registry against a throwaway key ---------------------------------------------------------
if ($env:OS -eq 'Windows_NT') {
    $sub = 'Software\FastLlmSignInTests-' + [guid]::NewGuid().ToString('N')
    try {
        $real = New-FastLlmSignInRegistry -RunKeyPath ($sub + '\Run') -ApprovedKeyPath ($sub + '\Approved')
        $script:FastLlmSignInRegistry = $real
        Assert-True ($null -eq (& $real.GetRunValue 'FastLLM')) 'a missing Run key reads as no value'
        Assert-True ($null -eq (& $real.GetApprovedValue 'FastLLM')) 'a missing StartupApproved key reads as no value'
        Assert-Equal (Get-FastLlmSignInStartState -AppRoot $app).reason 'value-missing' 'a missing Run key is value-missing'
        Remove-FastLlmSignInStart   # nothing to remove from missing keys; must not throw
        Assert-True ($null -eq [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($sub + '\Run')) 'removing from a missing Run key does not create it'
        Set-FastLlmSignInStart -AppRoot $app
        Assert-True ($null -ne [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($sub + '\Run')) 'Set creates a missing Run key'
        Assert-Equal (& $real.GetRunValue 'FastLLM') $expected 'the real registry round-trips the command'
        Assert-Equal (Get-FastLlmSignInStartState -AppRoot $app).reason 'on' 'on against the real registry'
        $approved = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($sub + '\Approved')
        $approved.SetValue('FastLLM', [byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0), [Microsoft.Win32.RegistryValueKind]::Binary)
        $approved.Close()
        Assert-Equal (Get-FastLlmSignInStartState -AppRoot $app).reason 'disabled-in-startup-apps' 'the real binary flag is read'
        Remove-FastLlmSignInStart
        Assert-Equal (Get-FastLlmSignInStartState -AppRoot $app).reason 'value-missing' 'Remove deletes against the real registry'
    } finally {
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($sub, $false)
    }
} else {
    Write-Host 'signin-start-tests: real-registry round trip is Windows-only, runs in CI'
}

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "signin-start-tests: $($script:checks) checks passed"
