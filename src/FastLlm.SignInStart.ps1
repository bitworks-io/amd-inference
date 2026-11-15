# Optional per-user "start at sign-in": the HKCU Run registration helper and the one-attempt launcher.
# Nothing here runs at install time. The registry is the truth for whether it is on; settings.json is never consulted.
# Registry and host access go through the seams $script:FastLlmSignInRegistry and $script:FastLlmSignInHost so tests need
# neither a real registry nor a real host. Windows PowerShell 5.1 compatible.
# The launcher entry point is tools/signin-start.ps1, started through FastLLM.cmd /signin.
Set-StrictMode -Version 2.0

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
        $arguments.SourceRoot = $SourceRoot
        $arguments.InstallRoot = $InstallRoot
        $arguments.NoWait = $true
        $start = $hostSeam.Start
        & $start $arguments
    } catch {
        $message = [string]$_.Exception.Message
        if ($message -match 'active serving operation') { return (Write-FastLlmSignInResult -InstallRoot $InstallRoot -Result 'skipped-occupied' -FailureCode $null) }
        $code = 'host-start-failed'
        if ($message -match 'Windows job') { $code = 'job-contained' }
        elseif ($message -match 'standard-user') { $code = 'elevated-session' }
        return (Write-FastLlmSignInResult -InstallRoot $InstallRoot -Result 'host-failed' -FailureCode $code)
    }
    return (Write-FastLlmSignInResult -InstallRoot $InstallRoot -Result 'started' -FailureCode $null)
}
