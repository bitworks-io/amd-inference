#requires -Version 5.1
# Start at sign-in: the per-user Run registration helper and the one-attempt launcher.
# Registry and host access go through seams, so this suite touches no real registry (except the Windows-only round trip
# against a throwaway key) and starts no process.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$repo = Split-Path -Parent $PSScriptRoot
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
Assert-Equal (Get-FastLlmSignInStartCommand -AppRoot 'C:\Program Files\Example App') '"C:\Program Files\Example App\FastLLM-SignIn.cmd"' 'command is quoted and exact for a path with spaces'
Assert-Equal (Get-FastLlmSignInStartCommand -AppRoot 'C:\Example\App\') '"C:\Example\App\FastLLM-SignIn.cmd"' 'a trailing backslash is not doubled'
Assert-Equal (Get-FastLlmSignInStartCommand -AppRoot 'D:\a b\c d') '"D:\a b\c d\FastLLM-SignIn.cmd"' 'spaces in several segments'
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

$script:FastLlmSignInRegistry.Store.run['FastLLM'] = '"C:\Other\FastLLM-SignIn.cmd"'
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

# --- the launcher ------------------------------------------------------------------------------------------------------
$script:Calls = New-Object System.Collections.ArrayList
function New-FakeHost([bool]$Elevated = $false, [bool]$Occupied = $false, $StartBehavior = 'ok') {
    $calls = $script:Calls
    return @{
        IsElevated = { [void]$calls.Add('elevated'); $Elevated }.GetNewClosure()
        IsOccupied = { param($InstallRoot) [void]$calls.Add('occupied'); $Occupied }.GetNewClosure()
        Sleep = { param($Seconds) [void]$calls.Add("sleep:$Seconds") }.GetNewClosure()
        Start = {
            param($Arguments)
            [void]$calls.Add('start')
            $script:LastStartArguments = $Arguments
            if ($StartBehavior -eq 'throw') { throw 'secret-looking message must never be recorded' }
            if ($StartBehavior -eq 'busy') { throw 'This installation already has an active serving operation.' }
            if ($StartBehavior -eq 'job') { throw 'The current process is contained in a Windows job; a persistent host cannot be launched from it.' }
        }.GetNewClosure()
    }
}
function New-Install([bool]$WithRequest = $true, $RequestOverride = $null) {
    $root = Join-Path $work ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $root 'state') -Force | Out-Null
    if ($WithRequest) {
        $request = [ordered]@{ profile = 'balanced'; modelId = 'example-model'; contextSize = 8192; serverPort = 8081; thinking = 'auto'; chatPage = 'off'; idleStopMinutes = 30 }
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

# started
$root = New-Install
$r = Invoke-Case (New-FakeHost) $root
Assert-Equal $r.result 'started' 'started result returned'
$file = Read-Result $root
Assert-Equal $file.result 'started' 'started result written'
Assert-True ($null -eq $file.failureCode) 'started has no failure code'
Assert-True ($file.time -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$') 'time is UTC ISO 8601'
Assert-Equal (@($file.PSObject.Properties.Name | Sort-Object) -join ',') 'failureCode,result,time' 'the result file holds only time, result and failureCode'
Assert-Equal (Count-Calls 'start') 1 'the host is started once'
Assert-True ($script:Calls -contains 'sleep:7') 'the launcher waits the given fixed time first'
$a = $script:LastStartArguments
Assert-Equal $a.ModelId 'example-model' 'the saved model is passed through'
Assert-Equal $a.Profile 'balanced' 'the saved profile is passed through'
Assert-Equal ([int]$a.ContextSize) 8192 'the saved context is passed through'
Assert-Equal ([int]$a.ServerPort) 8081 'the saved port is passed through'
Assert-Equal ([int]$a.IdleStopMinutes) 30 'the saved idle stop is passed through'
Assert-True ($a.NoWait -eq $true) 'the start is NoWait'
Assert-Equal $a.InstallRoot $root 'the install root is passed through'

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
$root = New-Install -RequestOverride ([ordered]@{ profile = 'balanced'; modelId = ''; contextSize = 0; serverPort = 0; thinking = 'auto'; chatPage = 'off'; idleStopMinutes = 0 })
$r = Invoke-Case (New-FakeHost) $root
Assert-Equal $r.result 'needs-setup' 'a request without a model needs setup'
$root = New-Install -RequestOverride ([ordered]@{ profile = 'turbo'; modelId = 'example-model'; contextSize = 0; serverPort = 0; thinking = 'auto'; chatPage = 'off'; idleStopMinutes = 0 })
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

# --- static checks: install registers nothing; uninstall removes both values; the launcher files exist -------------------
$iss = Get-Content -LiteralPath (Join-Path $repo 'installer/FastLLM.iss') -Raw
$beforeUninstall = $iss.Substring(0, $iss.IndexOf('procedure CurUninstallStepChanged'))
Assert-True ($beforeUninstall -notmatch '(?i)CurrentVersion\\Run') 'nothing before the uninstall step names the Run key (install never registers)'
Assert-True ($iss -notmatch '(?im)^\[Registry\]') 'the installer has no [Registry] section that could create the value'
$uninstall = $iss.Substring($iss.IndexOf('procedure CurUninstallStepChanged'))
Assert-True ($uninstall -match "RegDeleteValue\(HKCU, 'Software\\Microsoft\\Windows\\CurrentVersion\\Run', 'FastLLM'\)") 'uninstall removes the Run value'
Assert-True ($uninstall -match "RegDeleteValue\(HKCU, 'Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved\\Run', 'FastLLM'\)") 'uninstall removes the StartupApproved value'
$cmdText = Get-Content -LiteralPath (Join-Path $repo 'FastLLM-SignIn.cmd') -Raw
Assert-True ($cmdText -match 'signin-start\.ps1') 'the sign-in cmd runs the launcher tool'
Assert-True ($cmdText -notmatch '(?i)bypass') 'the sign-in cmd never uses Bypass'
Assert-True ($cmdText -match '(?im)^\s*if /i "%FASTLLM_POLICY%"=="Restricted" set "FASTLLM_EP=-ExecutionPolicy RemoteSigned"\s*$') 'the sign-in cmd lifts a Restricted policy like FastLLM.cmd'
Assert-True ($cmdText -match '(?im)^\s*if /i "%FASTLLM_POLICY%"=="Undefined" set "FASTLLM_EP=-ExecutionPolicy RemoteSigned"\s*$') 'the sign-in cmd lifts an Undefined policy like FastLLM.cmd'
Assert-True (Test-Path -LiteralPath (Join-Path $repo 'tools/signin-start.ps1')) 'the launcher tool exists'
$module = Get-Content -LiteralPath (Join-Path $repo 'src/FastLlm.SignInStart.ps1') -Raw
Assert-True ($module -notmatch '\?\?|-AsHashtable|ForEach-Object\s+-Parallel') 'no PowerShell 7 only syntax in the helper'

# --- Windows only: the default registry against a throwaway key ---------------------------------------------------------
if ($env:OS -eq 'Windows_NT') {
    $sub = 'Software\FastLlmSignInTests-' + [guid]::NewGuid().ToString('N')
    try {
        $real = New-FastLlmSignInRegistry -RunKeyPath ($sub + '\Run') -ApprovedKeyPath ($sub + '\Approved')
        $script:FastLlmSignInRegistry = $real
        Assert-True ($null -eq (& $real.GetRunValue 'FastLLM')) 'a fresh key has no value'
        Set-FastLlmSignInStart -AppRoot $app
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
