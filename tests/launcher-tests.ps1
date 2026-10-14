#requires -Version 5.1
# Executes the real FastLLM.cmd against a stub fast-llm-ui.ps1 under several CurrentUser execution policies.
# Run it in Windows PowerShell 5.1: that is the engine FastLLM.cmd launches, and its CurrentUser policy lives in the registry.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
if ($env:CI -ne 'true') { Write-Host 'launcher-tests: skipped (CI only: it changes the CurrentUser execution policy)'; exit 0 }
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path $env:RUNNER_TEMP ('launcher-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$out = Join-Path $work 'stub-out.json'
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "ASSERT: $Message" } }

# The stub is an unsigned local file with no mark of the web, so only RemoteSigned (or looser) lets it run.
Copy-Item -LiteralPath (Join-Path $repo 'FastLLM.cmd') -Destination (Join-Path $work 'FastLLM.cmd')
Set-Content -LiteralPath (Join-Path $work 'fast-llm-ui.ps1') -Encoding ascii -Value @'
[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Rest)
$o = [ordered]@{ pref = [string]$env:PSExecutionPolicyPreference; effective = [string](Get-ExecutionPolicy) }
Set-Content -LiteralPath $env:FASTLLM_TEST_OUT -Encoding ascii -Value ($o | ConvertTo-Json -Compress)
'@

# Runs the launcher with stdin closed (so a trailing `pause` returns at once), a bounded wait, and no
# PSExecutionPolicyPreference in the child environment (so this process cannot mask the launcher's own choice).
function Invoke-Launcher {
    if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $psi.Arguments = '/d /c ""' + (Join-Path $work 'FastLLM.cmd') + '""'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $work
    $null = $psi.EnvironmentVariables.Remove('PSExecutionPolicyPreference')
    $psi.EnvironmentVariables['FASTLLM_TEST_OUT'] = $out
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $so = $p.StandardOutput.ReadToEndAsync()
    $se = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(120000)) {
        & taskkill.exe /T /F /PID $p.Id | Out-Null
        throw 'FastLLM.cmd did not exit within 120 s'
    }
    $p.WaitForExit()
    Write-Host ("  launcher exit {0}; stdout: {1}; stderr: {2}" -f $p.ExitCode, $so.Result.Trim(), $se.Result.Trim())
    if (Test-Path -LiteralPath $out) { return (Get-Content -LiteralPath $out -Raw | ConvertFrom-Json) }
    return $null
}

# The effective policy as the launcher's own powershell.exe sees it: measured in a clean child, because this
# process may carry a Process-scope policy (from its command line or PSExecutionPolicyPreference) that the launcher does not.
function Get-ChildEffectivePolicy {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psi.Arguments = '-NoLogo -NoProfile -NonInteractive -Command Get-ExecutionPolicy'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $null = $psi.EnvironmentVariables.Remove('PSExecutionPolicyPreference')
    $p = [System.Diagnostics.Process]::Start($psi)
    $text = $p.StandardOutput.ReadToEnd()
    if (-not $p.WaitForExit(60000)) { & taskkill.exe /T /F /PID $p.Id | Out-Null; throw 'policy probe did not exit within 60 s' }
    return $text.Trim()
}

$original = Get-ExecutionPolicy -Scope CurrentUser
$failed = $false
try {
    foreach ($case in 'Restricted', 'RemoteSigned', 'AllSigned', 'Undefined') {
        Write-Host "case: CurrentUser=$case"
        # A Process-scope policy in this process makes Set-ExecutionPolicy report an override error even though the
        # CurrentUser value is written; check the written value and the child's effective policy instead.
        Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy $case -Force -ErrorAction SilentlyContinue
        Assert-True ([string](Get-ExecutionPolicy -Scope CurrentUser) -eq $case) "CurrentUser policy was not set to $case"
        $effective = Get-ChildEffectivePolicy
        Write-Host "  effective policy (clean child): $effective"
        if ($case -ne 'Undefined') {
            Assert-True ($effective -eq $case) "precondition: a clean child sees '$effective', not $case (Group Policy on this runner?)"
        }
        $r = Invoke-Launcher
        switch ($case) {
            'Restricted' {
                Assert-True ($null -ne $r) 'Restricted: the stub did not run (the launcher must lift Restricted to RemoteSigned)'
                Assert-True ($r.pref -eq 'RemoteSigned') "Restricted: PSExecutionPolicyPreference was '$($r.pref)', expected RemoteSigned"
            }
            'RemoteSigned' {
                Assert-True ($null -ne $r) 'RemoteSigned: the stub did not run'
                Assert-True ([string]::IsNullOrEmpty($r.pref)) "RemoteSigned: the launcher added a process override ('$($r.pref)')"
            }
            'AllSigned' {
                # An unsigned script must stay blocked; if it ran, the launcher weakened AllSigned.
                Assert-True ($null -eq $r) 'AllSigned: the unsigned stub ran, so the launcher overrode the policy'
            }
            'Undefined' {
                # CurrentUser=Undefined defers to LocalMachine. The effective value is reported above: a Windows Server
                # runner normally resolves to RemoteSigned (no flag expected), a client SKU to Restricted (flag expected).
                if ($effective -in 'Restricted', 'Undefined') {
                    Assert-True ($null -ne $r) "Undefined (effective $effective): the stub did not run"
                    Assert-True ($r.pref -eq 'RemoteSigned') "Undefined (effective $effective): expected RemoteSigned, got '$($r.pref)'"
                } elseif ($effective -eq 'AllSigned') {
                    Assert-True ($null -eq $r) 'Undefined (effective AllSigned): the unsigned stub ran'
                } else {
                    Assert-True ($null -ne $r) "Undefined (effective $effective): the stub did not run"
                    Assert-True ([string]::IsNullOrEmpty($r.pref)) "Undefined (effective $effective): the launcher added an override ('$($r.pref)')"
                }
            }
        }
        Write-Host "  ok"
    }
} catch {
    $failed = $true
    Write-Host ($_ | Out-String)
} finally {
    Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy $original -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
if ($failed) { Write-Host 'launcher-tests: FAILED'; exit 1 }
Write-Host 'launcher-tests: passed'
