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

# The real host check: reads the registry and loads the WPF assemblies. Off Windows it never touches the registry.
function Test-FastLlmUiFluentHost {
    [CmdletBinding()]
    param()
    if ($env:OS -ne 'Windows_NT') { return @{ supported = $false; reason = 'wpf-unavailable' } }
    $release = $null
    try {
        $key = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release -ErrorAction SilentlyContinue
        if ($null -ne $key -and $null -ne $key.PSObject.Properties['Release']) { $release = $key.Release }
    }
    catch { $release = $null }
    $isCore = $PSVersionTable.PSEdition -eq 'Core'
    return Get-FastLlmUiFluentSupport -NetFrameworkRelease $release -IsCoreClr $isCore -LoadAssemblies { Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop }
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
