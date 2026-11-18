# Optional per-user "start at sign-in": the HKCU Run registration helper and the one-attempt launcher.
# Nothing here runs at install time. The registry is the truth for whether it is on; settings.json is never consulted.
# Registry and host access go through the seams $script:FastLlmSignInRegistry and $script:FastLlmSignInHost so tests need
# neither a real registry nor a real host. Windows PowerShell 5.1 compatible.
# The launcher entry point is tools/signin-start.ps1, started through FastLLM.cmd /signin.
Set-StrictMode -Version 2.0

# The one reader of the model-switching opt-in, shared with the control window. This file never loads the window's code.
. (Join-Path $PSScriptRoot 'FastLlm.UiSettings.ps1')

$script:FastLlmSignInValueName = 'FastLLM'
$script:FastLlmSignInRunKeyPath = 'Software\Microsoft\Windows\CurrentVersion\Run'
$script:FastLlmSignInApprovedKeyPath = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
$script:FastLlmSignInLauncherName = 'FastLLM.cmd'
$script:FastLlmSignInLauncherArgument = '/signin'
$script:FastLlmSignInResultFile = 'signin-start.json'
$script:FastLlmSignInRequestFile = 'signin-start-request.json'

function New-FastLlmSignInRegistry {
    [CmdletBinding()]
    param([string]$RunKeyPath = $script:FastLlmSignInRunKeyPath,
          [string]$ApprovedKeyPath = $script:FastLlmSignInApprovedKeyPath)
    $runPath = $RunKeyPath
    $approvedPath = $ApprovedKeyPath
    return @{
        GetRunValue = {
            param($Name)
            $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($runPath, $false)
            if ($null -eq $key) { return $null }
            try { $value = $key.GetValue($Name, $null); if ($null -eq $value) { return $null }; return [string]$value }
            finally { $key.Close() }
        }.GetNewClosure()
        SetRunValue = {
            param($Name, $Value)
            $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($runPath)
            try { $key.SetValue($Name, [string]$Value, [Microsoft.Win32.RegistryValueKind]::String) }
            finally { $key.Close() }
        }.GetNewClosure()
        RemoveRunValue = {
            param($Name)
            $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($runPath, $true)
            if ($null -eq $key) { return }
            try { $key.DeleteValue($Name, $false) } finally { $key.Close() }
        }.GetNewClosure()
        GetApprovedValue = {
            param($Name)
            $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($approvedPath, $false)
            if ($null -eq $key) { return $null }
            try {
                $value = $key.GetValue($Name, $null)
                if ($value -is [byte[]]) { return ,$value }
                return $null
            } finally { $key.Close() }
        }.GetNewClosure()
        RemoveApprovedValue = {
            param($Name)
            $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($approvedPath, $true)
            if ($null -eq $key) { return }
            try { $key.DeleteValue($Name, $false) } finally { $key.Close() }
        }.GetNewClosure()
    }
}

if (-not (Get-Variable -Scope Script -Name FastLlmSignInRegistry -ErrorAction SilentlyContinue)) {
    $script:FastLlmSignInRegistry = $null
}
function Get-FastLlmSignInRegistry {
    if ($null -eq $script:FastLlmSignInRegistry) { $script:FastLlmSignInRegistry = New-FastLlmSignInRegistry }
    return $script:FastLlmSignInRegistry
}

# The exact Run value text: FastLLM.cmd next to the app (the only launcher that sets a script policy) with the /signin
# argument, quoted so a path with spaces stays one token.
function Get-FastLlmSignInStartCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$AppRoot)
    if ([string]::IsNullOrWhiteSpace($AppRoot)) { throw 'AppRoot is required.' }
    if ($AppRoot.Contains('"')) { throw 'AppRoot must not contain a double quote.' }
    return '"' + $AppRoot.TrimEnd('\') + '\' + $script:FastLlmSignInLauncherName + '" ' + $script:FastLlmSignInLauncherArgument
}

# on = the Run value exists, matches the expected command exactly, and is not disabled in Windows' Startup apps list.
function Get-FastLlmSignInStartState {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$AppRoot)
    $registry = Get-FastLlmSignInRegistry
    $name = $script:FastLlmSignInValueName
    $getRun = $registry.GetRunValue
    $value = & $getRun $name
    if ($null -eq $value) { return [pscustomobject]@{ on = $false; reason = 'value-missing' } }
    if (-not ([string]$value -ceq (Get-FastLlmSignInStartCommand -AppRoot $AppRoot))) {
        return [pscustomobject]@{ on = $false; reason = 'command-differs' }
    }
    $getApproved = $registry.GetApprovedValue
    $flags = & $getApproved $name
    if ($null -ne $flags -and @($flags).Count -gt 0 -and [int]@($flags)[0] -eq 3) {
        return [pscustomobject]@{ on = $false; reason = 'disabled-in-startup-apps' }
    }
    return [pscustomobject]@{ on = $true; reason = 'on' }
}

function Set-FastLlmSignInStart {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$AppRoot)
    $registry = Get-FastLlmSignInRegistry
    $command = Get-FastLlmSignInStartCommand -AppRoot $AppRoot
    $setRun = $registry.SetRunValue
    $removeApproved = $registry.RemoveApprovedValue
    & $setRun $script:FastLlmSignInValueName $command
    # Turning it on is an explicit choice: drop an older "disabled" flag so the state reads on.
    & $removeApproved $script:FastLlmSignInValueName
}

function Remove-FastLlmSignInStart {
    [CmdletBinding()]
    param()
    $registry = Get-FastLlmSignInRegistry
    $removeRun = $registry.RemoveRunValue
    $removeApproved = $registry.RemoveApprovedValue
    & $removeRun $script:FastLlmSignInValueName
    & $removeApproved $script:FastLlmSignInValueName
}

# --- the launcher -----------------------------------------------------------------------------------------------------

function New-FastLlmSignInHost {
    return @{
        IsElevated = {
            if ($env:OS -cne 'Windows_NT') { return $false }
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            return (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        }
        IsOccupied = { param($InstallRoot) Test-FastLlmBackgroundOperationOccupied -InstallRoot $InstallRoot }
        Sleep = { param($Seconds) Start-Sleep -Seconds $Seconds }
        Start = { param($Arguments) Start-FastLlmBackgroundHost @Arguments | Out-Null }
    }
}
if (-not (Get-Variable -Scope Script -Name FastLlmSignInHost -ErrorAction SilentlyContinue)) {
    $script:FastLlmSignInHost = $null
}

# FastLLM's per-user data root (state, operation lock, models, engines), the same default the window uses.
function Get-FastLlmSignInDefaultInstallRoot {
    return (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Bitworks\FastLLM')
}

function Get-FastLlmSignInStateFolder {
    param([string]$InstallRoot)
    $root = [IO.Path]::GetFullPath($InstallRoot)
    $state = Join-Path $root 'state'
    foreach ($folder in @($root, $state)) {
        if (Test-Path -LiteralPath $folder) {
            $item = Get-Item -LiteralPath $folder -Force
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'Unsafe sign-in state directory.'
            }
        }
    }
    New-Item -ItemType Directory -Path $state -Force | Out-Null
    return $state
}

function Write-FastLlmSignInResult {
    param([string]$InstallRoot, [string]$Result, $FailureCode)
    $state = Get-FastLlmSignInStateFolder -InstallRoot $InstallRoot
    $target = Join-Path $state $script:FastLlmSignInResultFile
    if (Test-Path -LiteralPath $target) {
        $existing = Get-Item -LiteralPath $target -Force
        if ($existing.PSIsContainer -or ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe sign-in result path.' }
    }
    $document = [ordered]@{
        time = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
        result = $Result
        failureCode = $FailureCode
    }
    $text = ($document | ConvertTo-Json -Compress)
    $temporary = Join-Path $state ($script:FastLlmSignInResultFile + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $backup = Join-Path $state ($script:FastLlmSignInResultFile + '.' + [Guid]::NewGuid().ToString('N') + '.bak.tmp')
    try {
        [IO.File]::WriteAllText($temporary, $text, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $target) { [IO.File]::Replace($temporary, $target, $backup) }
        else { [IO.File]::Move($temporary, $target) }
    } finally {
        foreach ($leftover in @($temporary, $backup)) {
            if (Test-Path -LiteralPath $leftover) { Remove-Item -LiteralPath $leftover -Force -ErrorAction SilentlyContinue }
        }
    }
    return [pscustomobject]@{ result = $Result; failureCode = $FailureCode }
}

# The request saved when the user turns the option on: profile, model and context only. Returns the host arguments, or a needs-setup failure code.
function Read-FastLlmSignInRequest {
    param([string]$InstallRoot)
    $state = Join-Path ([IO.Path]::GetFullPath($InstallRoot)) 'state'
    $path = Join-Path $state $script:FastLlmSignInRequestFile
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return [pscustomobject]@{ ok = $false; code = 'needs-setup-request' } }
    $item = Get-Item -LiteralPath $path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 65536) {
        return [pscustomobject]@{ ok = $false; code = 'needs-setup-request' }
    }
    try {
        $request = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path)) -ErrorAction Stop
        $names = @($request.PSObject.Properties.Name)
        function Get-Field([string]$Field, $Default) { if ($names -ccontains $Field) { return $request.$Field }; return $Default }
        $profile = [string](Get-Field 'profile' '')
        if (@('fast', 'balanced', 'quality') -cnotcontains $profile) { return [pscustomobject]@{ ok = $false; code = 'needs-setup-request' } }
        $modelId = [string](Get-Field 'modelId' '')
        if ([string]::IsNullOrWhiteSpace($modelId)) { return [pscustomobject]@{ ok = $false; code = 'needs-setup-model' } }
        $context = [int](Get-Field 'contextSize' 0)
        if ($context -lt 0 -or $context -gt 1048576) { return [pscustomobject]@{ ok = $false; code = 'needs-setup-request' } }
        # Serving settings (port, thinking, chat page, idle stop) are not saved here: the launch takes them from the user's saved settings.
        return [pscustomobject]@{ ok = $true; code = $null; arguments = @{ Profile = $profile; ModelId = $modelId; ContextSize = $context } }
    } catch {
        return [pscustomobject]@{ ok = $false; code = 'needs-setup-request' }
    }
}

# Whether the user allows switching models while FastLLM runs: read through the shared reader the window uses (Get-FastLlmUiAllowSwitch, src/FastLlm.UiSettings.ps1), so a sign-in
# start and a window start see the same answer. Fails closed: an absent, false or unreadable setting is off, and never stops a start.
function Get-FastLlmSignInAllowSwitch {
    param([string]$InstallRoot)
    try {
        return [bool](Get-FastLlmUiAllowSwitch -InstallRoot $InstallRoot)
    } catch { return $false }
}

# One attempt: wait, then start the background host once from the saved request, and record the outcome. No retry.
# Only a short code is recorded; an exception message never reaches the result file.
function Invoke-FastLlmSignInLaunch {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$SourceRoot,
          [Parameter(Mandatory=$true)][string]$InstallRoot,
          [ValidateRange(0,120)][int]$DelaySeconds = 20)
    if ($null -eq $script:FastLlmSignInHost) { $script:FastLlmSignInHost = New-FastLlmSignInHost }
    $hostSeam = $script:FastLlmSignInHost
    $isElevated = $hostSeam.IsElevated
    if (& $isElevated) { return (Write-FastLlmSignInResult -InstallRoot $InstallRoot -Result 'refused-elevated' -FailureCode 'elevated-session') }
    $sleep = $hostSeam.Sleep
    if ($DelaySeconds -gt 0) { & $sleep $DelaySeconds }
    $request = Read-FastLlmSignInRequest -InstallRoot $InstallRoot
    if (-not $request.ok) { return (Write-FastLlmSignInResult -InstallRoot $InstallRoot -Result 'needs-setup' -FailureCode $request.code) }
    try {
        $isOccupied = $hostSeam.IsOccupied
        if (& $isOccupied $InstallRoot) { return (Write-FastLlmSignInResult -InstallRoot $InstallRoot -Result 'skipped-occupied' -FailureCode $null) }
        $arguments = $request.arguments
        # The user's current saved serving settings, resolved by the settings module exactly as the command line does.
        $serving = Get-FastLlmServingHostArguments -InstallRoot $InstallRoot
        foreach ($key in @($serving.Keys)) { $arguments[$key] = $serving[$key] }
        # The window's opt-in model switching: with it saved on, the host is asked for -SwitchAllowed exactly as a window background start is
        # (so the switch basis is written and the model picker works after a sign-in start). Off or unreadable adds nothing.
        if (Get-FastLlmSignInAllowSwitch -InstallRoot $InstallRoot) { $arguments.SwitchAllowed = $true }
        $arguments.SourceRoot = $SourceRoot
        $arguments.InstallRoot = $InstallRoot
        $arguments.NoWait = $true
        $start = $hostSeam.Start
        & $start $arguments
    } catch {
        $message = [string]$_.Exception.Message
        if ($message -match 'active serving operation') { return (Write-FastLlmSignInResult -InstallRoot $InstallRoot -Result 'skipped-occupied' -FailureCode $null) }
        $code = 'host-start-failed'
        # A typed API key refusal (the key is on and cannot be read, or whether it is required cannot be known) is recorded by its own
        # code, so the result says why nothing was started. Only a code of the fixed api-key form is taken; never any message text.
        $typedCode = $null
        if ($null -ne $_.Exception.Data) { $typedCode = $_.Exception.Data['FastLlmFailureCode'] }
        if ($typedCode -is [string] -and $typedCode -cmatch '^api-key-[a-z-]{1,40}$') { $code = $typedCode }
        elseif ($message -match 'Windows job') { $code = 'job-contained' }
        elseif ($message -match 'standard-user') { $code = 'elevated-session' }
        return (Write-FastLlmSignInResult -InstallRoot $InstallRoot -Result 'host-failed' -FailureCode $code)
    }
    return (Write-FastLlmSignInResult -InstallRoot $InstallRoot -Result 'started' -FailureCode $null)
}

# --- the window and command-line switch ---------------------------------------------------------------------------------
# The Run value is the truth: nothing here reads or writes settings.json. Only the explicit switch (window checkbox or
# `settings -StartAtSignIn on`) ever calls Set-FastLlmSignInStart; no start, install or bench path does.

# The last recorded sign-in attempt (state\signin-start.json), or $null when none was recorded or the file is unreadable.
function Read-FastLlmSignInResult {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$InstallRoot)
    $path = Join-Path (Join-Path ([IO.Path]::GetFullPath($InstallRoot)) 'state') $script:FastLlmSignInResultFile
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $item = Get-Item -LiteralPath $path -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 65536) { return $null }
        $document = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path)) -ErrorAction Stop
        $names = @($document.PSObject.Properties.Name)
        if ($names -cnotcontains 'result') { return $null }
        $time = ''
        if ($names -ccontains 'time') {
            # Windows PowerShell 5.1 keeps the text; PowerShell 7 turns it into a date. Both read back as the same UTC text.
            if ($document.time -is [DateTime]) { $time = ([DateTime]$document.time).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture) }
            else { $time = [string]$document.time }
        }
        $code = $null
        if ($names -ccontains 'failureCode' -and $null -ne $document.failureCode) { $code = [string]$document.failureCode }
        return [pscustomobject]@{ time = $time; result = [string]$document.result; failureCode = $code }
    } catch { return $null }
}

# Plain words for the last attempt. Only the short recorded code is shown, never an exception message.
function Get-FastLlmSignInResultText {
    [CmdletBinding()]
    param($Result)
    if ($null -eq $Result) { return 'No start at sign-in has been recorded yet.' }
    $when = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$Result.time)) { $when = ' (' + [string]$Result.time + ')' }
    switch ([string]$Result.result) {
        'started' { return 'Started at sign-in' + $when + '.' }
        'skipped-occupied' { return 'Start at sign-in was skipped because FastLLM was already running or busy' + $when + '.' }
        'refused-elevated' { return 'Start at sign-in was refused because the session was running as administrator' + $when + '.' }
        'needs-setup' {
            $detail = 'it has no saved start setup'
            if ([string]$Result.failureCode -ceq 'needs-setup-model') { $detail = 'it has no saved model' }
            return 'Start at sign-in did not start FastLLM because ' + $detail + $when + '.'
        }
        'host-failed' {
            $code = [string]$Result.failureCode
            if ([string]::IsNullOrWhiteSpace($code)) { $code = 'host-start-failed' }
            return 'Start at sign-in failed: ' + $code + $when + '.'
        }
        default { return 'The last start at sign-in recorded an unknown result' + $when + '.' }
    }
}

# What Settings shows for the switch. checked is true only for state 'on'.
function Get-FastLlmSignInStateText {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$State)
    switch ([string]$State.reason) {
        'on' { return 'FastLLM starts when you sign in.' }
        'command-differs' { return 'Off. The saved sign-in entry points to a different FastLLM location; turn it on here to use this one.' }
        'disabled-in-startup-apps' { return "Windows has this turned off in Startup apps. FastLLM will not change that: turn it back on in Windows Settings, Apps, Startup, then it shows here." }
        default { return 'Off.' }
    }
}

function Get-FastLlmSignInSettingsView {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$AppRoot, [Parameter(Mandatory=$true)][string]$InstallRoot)
    $state = Get-FastLlmSignInStartState -AppRoot $AppRoot
    $result = Read-FastLlmSignInResult -InstallRoot $InstallRoot
    return [pscustomobject]@{
        checked = ([bool]$state.on -and [string]$state.reason -ceq 'on')
        reason = [string]$state.reason
        stateText = (Get-FastLlmSignInStateText -State $state)
        lastResult = $result
        lastResultText = (Get-FastLlmSignInResultText -Result $result)
        refused = $false
    }
}

# --- the saved request ---------------------------------------------------------------------------------------------------
# The request the launcher reads (Read-FastLlmSignInRequest): profile, modelId, contextSize. Ids and numbers only: no paths, prompts or secrets.
# Serving settings (port, thinking, chat page, idle stop) are read at launch from the user's saved settings, not copied here.
# The API-key flag is not part of the request yet: B11 adds it when the key exists.

# Seam: the fingerprint of this PC's hardware, as the planner computes it. $null when it cannot be read.
if (-not (Get-Variable -Scope Script -Name FastLlmSignInHardware -ErrorAction SilentlyContinue)) { $script:FastLlmSignInHardware = $null }
function Get-FastLlmSignInHardwareFingerprint {
    param([string]$SourceRoot, [string]$InstallRoot)
    if ($null -ne $script:FastLlmSignInHardware) { $seam = $script:FastLlmSignInHardware; return (& $seam $SourceRoot $InstallRoot) }
    try {
        $module = Get-Module FastLlm
        if ($null -eq $module) { return $null }
        $catalog = Join-Path (Join-Path $SourceRoot 'config') 'catalog.json'
        return (& $module { param($Catalog, $Root) Get-FastLlmFingerprint -Hardware (Get-FastLlmHardware -CatalogPath $Catalog -InstallRoot $Root) } $catalog $InstallRoot)
    } catch { return $null }
}

# The request built from the setup that reached Ready on this PC (state\<fingerprint>.last-ready.json, written by the runtime only at Ready),
# or $null when there is no usable record. Records from before the profile was recorded are not used.
function Get-FastLlmSignInReadyRequest {
    param([string]$InstallRoot, [string]$Fingerprint)
    if ([string]::IsNullOrWhiteSpace($Fingerprint) -or $Fingerprint -notmatch '^[0-9A-Za-z_-]{1,128}$') { return $null }
    $path = Join-Path (Join-Path ([IO.Path]::GetFullPath($InstallRoot)) 'state') ($Fingerprint + '.last-ready.json')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $item = Get-Item -LiteralPath $path -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 16384) { return $null }
        $record = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path)) -ErrorAction Stop
        $names = @($record.PSObject.Properties.Name)
        foreach ($required in @('kind', 'hardwareFingerprint', 'modelId', 'profile', 'requestedContextSize')) { if ($names -cnotcontains $required) { return $null } }
        if ([string]$record.kind -cne 'api-smoke-only' -or [string]$record.hardwareFingerprint -cne $Fingerprint) { return $null }
        if ([string]::IsNullOrWhiteSpace([string]$record.modelId)) { return $null }
        if (@('fast', 'balanced', 'quality') -cnotcontains [string]$record.profile) { return $null }
        $context = [int]$record.requestedContextSize
        if ($context -lt 0 -or $context -gt 1048576) { return $null }
        return [ordered]@{ profile = [string]$record.profile; modelId = [string]$record.modelId; contextSize = $context }
    } catch { return $null }
}

function Write-FastLlmSignInRequest {
    param([string]$InstallRoot, $Request)
    $state = Get-FastLlmSignInStateFolder -InstallRoot $InstallRoot
    $target = Join-Path $state $script:FastLlmSignInRequestFile
    if (Test-Path -LiteralPath $target) {
        $existing = Get-Item -LiteralPath $target -Force
        if ($existing.PSIsContainer -or ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe sign-in request path.' }
    }
    $temporary = Join-Path $state ($script:FastLlmSignInRequestFile + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $backup = Join-Path $state ($script:FastLlmSignInRequestFile + '.' + [Guid]::NewGuid().ToString('N') + '.bak.tmp')
    try {
        [IO.File]::WriteAllText($temporary, ($Request | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $target) { [IO.File]::Replace($temporary, $target, $backup) }
        else { [IO.File]::Move($temporary, $target) }
    } finally {
        foreach ($leftover in @($temporary, $backup)) {
            if (Test-Path -LiteralPath $leftover) { Remove-Item -LiteralPath $leftover -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Remove-FastLlmSignInRequest {
    param([string]$InstallRoot)
    $path = Join-Path (Join-Path ([IO.Path]::GetFullPath($InstallRoot)) 'state') $script:FastLlmSignInRequestFile
    if (Test-Path -LiteralPath $path) {
        $item = Get-Item -LiteralPath $path -Force
        if (-not $item.PSIsContainer -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { Remove-Item -LiteralPath $path -Force }
    }
}

# Apply the switch, then re-read the state so the caller shows the truth, not the request. Windows' own Startup apps switch is never rewritten:
# when it is disabled there, asking for "on" changes nothing and the view says what the user must do. Turning on needs a setup that has reached
# Ready on this PC; without one nothing is written. The request is saved before the Run value and removed again if the Run value cannot be set.
function Set-FastLlmSignInStartEnabled {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$AppRoot, [Parameter(Mandatory=$true)][string]$InstallRoot, [Parameter(Mandatory=$true)][bool]$Enabled)
    $refusal = $null
    if ($Enabled) {
        $before = Get-FastLlmSignInStartState -AppRoot $AppRoot
        if ([string]$before.reason -cne 'disabled-in-startup-apps') {
            $fingerprint = Get-FastLlmSignInHardwareFingerprint -SourceRoot $AppRoot -InstallRoot $InstallRoot
            $request = Get-FastLlmSignInReadyRequest -InstallRoot $InstallRoot -Fingerprint $fingerprint
            if ($null -eq $request) {
                $refusal = 'Start FastLLM once with the setup you want; then turn this on.'
            } else {
                Write-FastLlmSignInRequest -InstallRoot $InstallRoot -Request $request
                try { Set-FastLlmSignInStart -AppRoot $AppRoot }
                catch { try { Remove-FastLlmSignInRequest -InstallRoot $InstallRoot } catch { $null = $_ }; throw }
            }
        }
    } else {
        Remove-FastLlmSignInStart
        Remove-FastLlmSignInRequest -InstallRoot $InstallRoot
    }
    $view = Get-FastLlmSignInSettingsView -AppRoot $AppRoot -InstallRoot $InstallRoot
    if ($null -ne $refusal) { $view.stateText = $refusal; $view.refused = $true }
    return $view
}

# Command-line parity for the `settings` action. $View is a Get-FastLlmSignInSettingsView object, or $null when the registry cannot be read
# (for example on a machine that is not Windows).
function Get-FastLlmSignInCliFields {
    [CmdletBinding()]
    param($View)
    if ($null -eq $View) { return [ordered]@{ startAtSignIn = 'unavailable'; startAtSignInReason = 'registry-unavailable'; lastSignInStart = $null } }
    $last = $null
    if ($null -ne $View.lastResult) { $last = [ordered]@{ time = $View.lastResult.time; result = $View.lastResult.result; failureCode = $View.lastResult.failureCode } }
    $word = 'off'
    if ($View.checked) { $word = 'on' }
    return [ordered]@{ startAtSignIn = $word; startAtSignInReason = $View.reason; lastSignInStart = $last }
}

function Format-FastLlmSignInCliLines {
    [CmdletBinding()]
    param($View)
    if ($null -eq $View) { return @('startAtSignIn: unavailable') }
    $word = 'off'
    if ($View.checked) { $word = 'on' }
    $lines = @('startAtSignIn: ' + $word)
    if ($View.refused -or ($View.reason -cne 'on' -and $View.reason -cne 'value-missing')) { $lines += ('startAtSignIn note: ' + $View.stateText) }
    if ($null -ne $View.lastResult) { $lines += ('lastSignInStart: ' + $View.lastResultText) }
    return $lines
}

# The view for the settings action. $Enabled is $null to only read. A registry that cannot be read gives $null instead of an error.
function Invoke-FastLlmSignInSettingsAction {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$AppRoot, [Parameter(Mandatory=$true)][string]$InstallRoot, $Enabled)
    if ($null -ne $Enabled) { return (Set-FastLlmSignInStartEnabled -AppRoot $AppRoot -InstallRoot $InstallRoot -Enabled ([bool]$Enabled)) }
    try { return (Get-FastLlmSignInSettingsView -AppRoot $AppRoot -InstallRoot $InstallRoot) } catch { return $null }
}
