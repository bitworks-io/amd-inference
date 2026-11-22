# What happens when -Window fluent is asked for on a PC that cannot run WPF: the support decision, the execution-policy flag rule,
# the approved texts (spec 6.9, verbatim) and the run-log event. No window opens on such a PC; the caller exits with code 3.
Set-StrictMode -Version 2.0

# Pure decision. On Windows PowerShell 5.1 the .NET Framework Release must be an integer >= 461308 (4.7.1); then the WPF assemblies must load.
function Get-FastLlmUiFluentSupport {
    [CmdletBinding()]
    param(
        [object] $NetFrameworkRelease,
        # The name IsCoreClr alone would collide with pwsh 7's read-only automatic variable, so the variable is $CoreClr.
        [Parameter(Mandatory = $true)][Alias('IsCoreClr')][bool] $CoreClr,
        [Parameter(Mandatory = $true)][scriptblock] $LoadAssemblies
    )
    if (-not $CoreClr) {
        $release = 0
        $isNumber = $null -ne $NetFrameworkRelease -and (($NetFrameworkRelease -is [int]) -or ($NetFrameworkRelease -is [long]) -or ([string] $NetFrameworkRelease -match '^\d{1,10}$'))
        if ($isNumber) { $release = [long] $NetFrameworkRelease }
        if (-not $isNumber -or $release -lt 461308) { return @{ supported = $false; reason = 'dotnet-too-old' } }
    }
    try { & $LoadAssemblies | Out-Null }
    catch { return @{ supported = $false; reason = 'wpf-unavailable' } }
    return @{ supported = $true; reason = '' }
}

# Windows PowerShell 5.1 targets no framework, so WPF reads every accessibility switch as legacy (no peer for the steps list, no live-region
# announcements). Setting the switches all together, before any WPF type is touched, turns the modern behaviour on; WPF verifies they agree on
# first read. Harmless on pwsh 7, where they are already modern. Self-contained: dropping this function and its one call removes the change.
function Set-FastLlmUiFluentAccessibilitySwitches {
    [CmdletBinding()] param()
    foreach ($name in 'Switch.UseLegacyAccessibilityFeatures', 'Switch.UseLegacyAccessibilityFeatures.2', 'Switch.UseLegacyAccessibilityFeatures.3',
        'Switch.UseLegacyAccessibilityFeatures.4', 'Switch.UseLegacyAccessibilityFeatures.5', 'Switch.UseLegacyToolTipDisplay',
        'Switch.System.Windows.Controls.ItemsControlDoesNotSupportAutomation', 'Switch.System.Windows.Controls.OptOutOfGridColumnResizeUsingKeyboard') {
        [System.AppContext]::SetSwitch($name, $false)
    }
}

# The real host check: reads the registry and loads the WPF assemblies. Off Windows it never touches the registry.
function Test-FastLlmUiFluentHost {
    [CmdletBinding()]
    param()
    # First, before any WPF type is loaded or touched.
    try { Set-FastLlmUiFluentAccessibilitySwitches } catch { return @{ supported = $false; reason = 'wpf-unavailable' } }
    if ($env:OS -ne 'Windows_NT') { return @{ supported = $false; reason = 'wpf-unavailable' } }
    $release = $null
    try {
        $key = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release -ErrorAction SilentlyContinue
        if ($null -ne $key -and $null -ne $key.PSObject.Properties['Release']) { $release = $key.Release }
    }
    catch { $release = $null }
    $isCore = $PSVersionTable.PSEdition -eq 'Core'
    $decision = Get-FastLlmUiFluentSupport -NetFrameworkRelease $release -IsCoreClr $isCore -LoadAssemblies { Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop }
    # After the assemblies are loaded: read the switches back. A legacy read never blocks the window; it is recorded once.
    if ($decision.supported) { try { Invoke-FastLlmUiFluentAccessibilityCheck -CoreClr $isCore } catch { $null = $_ } }
    return $decision
}

# The WPF accessibility fields as WPF itself reads them (internal type). Legacy: the names of the fields that read True. A missing property is not legacy.
function Get-FastLlmUiFluentAccessibilityState {
    [CmdletBinding()] param()
    # WPF compiles the switch class into more than one assembly; each copy caches its own reads, so every copy is read.
    $assemblies = @([System.Windows.DependencyObject].Assembly, [System.Windows.UIElement].Assembly, [System.Windows.Controls.ItemsControl].Assembly)
    $legacy = New-Object System.Collections.ArrayList
    $found = $false
    $seen = @{}
    foreach ($assembly in $assemblies) {
        $short = $assembly.GetName().Name
        if ($seen.ContainsKey($short)) { continue }
        $seen[$short] = $true
        $type = $assembly.GetType('System.Windows.AccessibilitySwitches')
        if ($null -eq $type) { continue }
        $found = $true
        foreach ($name in 'UseNetFx47CompatibleAccessibilityFeatures', 'UseNetFx471CompatibleAccessibilityFeatures', 'UseNetFx472CompatibleAccessibilityFeatures',
            'UseNetFx48CompatibleAccessibilityFeatures', 'UseLegacyToolTipDisplay', 'ItemsControlDoesNotSupportAutomation') {
            $property = $type.GetProperty($name, [System.Reflection.BindingFlags] 'NonPublic,Static')
            if ($null -eq $property) { continue }
            if ([bool] $property.GetValue($null)) { [void] $legacy.Add($short + '.' + $name) }
        }
    }
    return @{ typeFound = $found; legacy = @($legacy.ToArray()) }
}

# Records window-accessibility-legacy once, with the legacy field NAMES only (no path, no value). -Reader and -Log are seams for tests.
# Missing type: nothing on pwsh 7, 'type-missing' on Windows PowerShell 5.1.
function Invoke-FastLlmUiFluentAccessibilityCheck {
    [CmdletBinding()]
    param(
        [bool] $CoreClr = ($PSVersionTable.PSEdition -eq 'Core'),
        [scriptblock] $Reader = { Get-FastLlmUiFluentAccessibilityState },
        [scriptblock] $Log,
        [string] $InstallRoot
    )
    if ($null -eq $Log) {
        if (-not $InstallRoot) { $found = Get-Variable -Name InstallRoot -ValueOnly -ErrorAction SilentlyContinue; if ($found) { $InstallRoot = [string] $found } }
        if (-not $InstallRoot) { return }
        $root = $InstallRoot
        $Log = { param($Fields) [void] (Write-FastLlmRunLogEvent -InstallRoot $root -RunId ([guid]::NewGuid().ToString('N')) -Event 'window-accessibility-legacy' -Fields $Fields) }.GetNewClosure()
    }
    $state = & $Reader
    $names = @()
    if (-not $state.typeFound) { if (-not $CoreClr) { $names = @('type-missing') } }
    else { $names = @($state.legacy) }
    if ($names.Count -eq 0) { return }
    & $Log @{ fields = ($names -join ',') }
}

# FastLLM.cmd's rule: the flag is added only when the effective policy without the Process scope is Restricted or Undefined.
# Never weakens AllSigned or a Group Policy setting. Returns '' or '-ExecutionPolicy RemoteSigned ' (trailing space).
function Get-FastLlmUiCliPolicyFlag {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary] $Policies)
    $effective = 'Restricted'
    foreach ($scope in 'MachinePolicy', 'UserPolicy', 'CurrentUser', 'LocalMachine') {
        if ($Policies.Contains($scope) -and [string] $Policies[$scope] -ine 'Undefined') { $effective = [string] $Policies[$scope]; break }
    }
    if ($effective -ieq 'Restricted' -or $effective -ieq 'Undefined') { return '-ExecutionPolicy RemoteSigned ' }
    return ''
}

# The approved text for a reason code, as one string with CRLF line ends. Folder is the window script's own folder.
function Get-FastLlmUiUnsupportedText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Reason,
        [Parameter(Mandatory = $true)][string] $Folder,
        [string] $PolicyFlag = ''
    )
    $script = "$Folder\fast-llm.ps1"
    $block = @(
        "FastLLM's command line still works. In Command Prompt or PowerShell, run this the first time (it asks before downloading a model):",
        "powershell -NoProfile ${PolicyFlag}-File `"$script`" install",
        'Then, and every time after:',
        "powershell -NoProfile ${PolicyFlag}-File `"$script`" start"
    )
    $lines = switch ($Reason) {
        'dotnet-too-old' {
            @("FastLLM's window isn't supported on this PC. It needs Microsoft .NET Framework 4.7.1 or later, and this PC has an older version. To fix it, update Windows, or install .NET Framework 4.8 from Microsoft.", '') + $block
        }
        'wpf-unavailable' {
            @("FastLLM's window isn't supported on this PC: the Windows desktop window components (WPF) could not be loaded. Repairing .NET Framework 4.8 from Microsoft, or updating Windows, usually fixes this.", '') + $block
        }
        { $_ -ceq 'theme-init' -or $_ -ceq 'xaml-parse' } {
            @("FastLLM's window could not open because of a fault in FastLLM, not in your PC.", '') + $block +
            @('', 'To help us fix it, save a support bundle:', "powershell -NoProfile ${PolicyFlag}-File `"$script`" doctor -SupportBundle <new-file>.zip")
        }
        default { throw "ui-unsupported-reason: unknown reason '$Reason'." }
    }
    return (@($lines) -join "`r`n")
}

# Tells the user why no window opens: console, a standard message box (interactive sessions only) and the run-log reason code.
# Returns nothing; the caller exits 3. -NoMessageBox is for tests. -Policies lets a test bypass the policy read; -PolicyReader replaces it
# (a scriptblock returning Get-ExecutionPolicy -List style objects). If the read fails, the text carries NO policy flag: never suggest weakening a policy we could not read.
function Show-FastLlmUiUnsupported {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Reason,
        [Parameter(Mandatory = $true)][string] $InstallRoot,
        [Parameter(Mandatory = $true)][string] $Folder,
        [System.Collections.IDictionary] $Policies,
        [scriptblock] $PolicyReader = { Get-ExecutionPolicy -List },
        [switch] $NoMessageBox
    )
    $policyFlag = ''
    if ($null -eq $Policies) {
        $read = $null
        try {
            $read = @{}
            foreach ($p in @(& $PolicyReader)) { $read[[string] $p.Scope] = [string] $p.ExecutionPolicy }
        }
        catch { $read = $null }
        if ($null -ne $read) { $policyFlag = Get-FastLlmUiCliPolicyFlag -Policies $read }
    }
    else { $policyFlag = Get-FastLlmUiCliPolicyFlag -Policies $Policies }
    $text = Get-FastLlmUiUnsupportedText -Reason $Reason -Folder $Folder -PolicyFlag $policyFlag
    Write-Host $text
    if (-not $NoMessageBox -and [Environment]::UserInteractive) {
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
            [void] [System.Windows.Forms.MessageBox]::Show($text, 'FastLLM', 'OK', 'Warning')
        }
        catch { }
    }
    try { [void] (Write-FastLlmRunLogEvent -InstallRoot $InstallRoot -RunId ([guid]::NewGuid().ToString('N')) -Event 'window-unsupported' -Fields @{ reason = $Reason }) } catch { }
}

# --- doctor: the window accessibility mode on this PC ---
# The check runs in a fresh child process of the same shell, so doctor's own process never has its switches touched. The child prints one JSON
# line; only field names leave this function (no path, no value, no exception text). Failures map to a reason code:
# not-windows, wpf-load-failed, timeout, child-failed.

# Runs the child and returns @{ timedOut; exitCode; stdout }. Kills only its own Process object.
function Invoke-FastLlmDoctorAccessibilityChild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $SupportScript,
        [int] $TimeoutSeconds = 30
    )
    $childScript = @'
$ErrorActionPreference = 'Stop'
try {
    . $env:FASTLLM_DOCTOR_A11Y_SUPPORT
    Set-FastLlmUiFluentAccessibilitySwitches
    $loaded = $true
    try { Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop } catch { $loaded = $false }
    if (-not $loaded) { [Console]::Out.WriteLine('{"loadFailed":true}'); exit 0 }
    $state = Get-FastLlmUiFluentAccessibilityState
    [Console]::Out.WriteLine((@{ typeFound = [bool] $state.typeFound; legacy = @($state.legacy) } | ConvertTo-Json -Compress))
    exit 0
}
catch { exit 1 }
'@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $info.Arguments = '-NoProfile -NonInteractive -EncodedCommand ' + $encoded
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.EnvironmentVariables['FASTLLM_DOCTOR_A11Y_SUPPORT'] = $SupportScript
    $process = [System.Diagnostics.Process]::Start($info)
    try {
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { $null = $_ }
            try { [void] $process.WaitForExit(5000) } catch { $null = $_ }
            return @{ timedOut = $true; exitCode = -1; stdout = '' }
        }
        $process.WaitForExit()
        return @{ timedOut = $false; exitCode = [int] $process.ExitCode; stdout = [string] $outTask.Result }
    }
    finally { $process.Dispose() }
}

# Returns [pscustomobject] status (modern|legacy|not-checked), fields (names), reason (code or ''), summary (the plain line).
# -ChildRunner, -Windows and -CoreClr are seams for tests; the runner returns @{ timedOut; exitCode; stdout }.
function Get-FastLlmDoctorWindowAccessibility {
    [CmdletBinding()]
    param(
        [string] $SupportScript = (Join-Path $PSScriptRoot 'FastLlm.UiFluentSupport.ps1'),
        [scriptblock] $ChildRunner,
        [bool] $Windows = ($env:OS -eq 'Windows_NT'),
        [bool] $CoreClr = ($PSVersionTable.PSEdition -eq 'Core')
    )
    function New-Result([string] $Status, [string[]] $Fields, [string] $Reason) {
        $summary = switch ($Status) {
            'modern' { 'Window accessibility: modern' }
            'legacy' { 'Window accessibility: legacy (fields: ' + (@($Fields) -join ', ') + ')' }
            default { 'Window accessibility: not checked (' + $Reason + ')' }
        }
        return [pscustomobject] @{ status = $Status; fields = @($Fields); reason = $Reason; summary = $summary }
    }
    if (-not $Windows) { return New-Result 'not-checked' @() 'not-windows' }
    if ($null -eq $ChildRunner) { $ChildRunner = { param($Script) Invoke-FastLlmDoctorAccessibilityChild -SupportScript $Script -TimeoutSeconds 30 } }
    try { $run = & $ChildRunner $SupportScript } catch { return New-Result 'not-checked' @() 'child-failed' }
    if ($null -eq $run -or $run -isnot [System.Collections.IDictionary]) { return New-Result 'not-checked' @() 'child-failed' }
    if ($run['timedOut'] -eq $true) { return New-Result 'not-checked' @() 'timeout' }
    if ($run['exitCode'] -ne 0) { return New-Result 'not-checked' @() 'child-failed' }
    $lines = @(([string] $run['stdout']) -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 })
    if ($lines.Count -ne 1) { return New-Result 'not-checked' @() 'child-failed' }
    try { $parsed = $lines[0] | ConvertFrom-Json } catch { return New-Result 'not-checked' @() 'child-failed' }
    if ($null -eq $parsed) { return New-Result 'not-checked' @() 'child-failed' }
    if ($parsed.PSObject.Properties['loadFailed'] -and $parsed.loadFailed -eq $true) { return New-Result 'not-checked' @() 'wpf-load-failed' }
    if (-not $parsed.PSObject.Properties['typeFound'] -or $parsed.typeFound -isnot [bool] -or -not $parsed.PSObject.Properties['legacy']) { return New-Result 'not-checked' @() 'child-failed' }
    $names = @()
    foreach ($item in @($parsed.legacy)) {
        if ($item -isnot [string] -or $item -cnotmatch '^[A-Za-z0-9]{1,40}\.[A-Za-z0-9]{1,60}$') { return New-Result 'not-checked' @() 'child-failed' }
        $names += $item
    }
    # A missing switch type is legacy on Windows PowerShell 5.1 and nothing on pwsh 7, as in the window's own check.
    if (-not $parsed.typeFound -and -not $CoreClr) { $names = @('type-missing') }
    if ($names.Count -eq 0) { return New-Result 'modern' @() '' }
    return New-Result 'legacy' $names ''
}
