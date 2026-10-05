#requires -Version 5.1
[CmdletBinding()]
param([string]$SetupScript = (Join-Path (Split-Path $PSScriptRoot -Parent) 'tools/setup-windows-lab.ps1'))
$ErrorActionPreference = 'Stop'
$tokens=$null; $parseErrors=$null
$ast = [Management.Automation.Language.Parser]::ParseFile($SetupScript,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) { $parseErrors | Format-List; throw 'Setup script does not parse.' }
# Load ONLY helper function definitions, never the privileged setup entry point.
foreach ($name in @('ConvertTo-LabPublicKey','Add-LabPublicKey','New-LabSshConfiguration',
    'Assert-LabEffectiveConfiguration','Get-LabBlockingRules','Get-LabEffectiveConfiguration')) {
    $function = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    if (-not $function) { throw "Missing helper $name" }
    . ([scriptblock]::Create($function.Extent.Text))
}
$script:checks=0
function Assert-True($Value,[string]$Message) {
    if (-not $Value) { throw $Message }; $script:checks++
}
function Assert-Throws([scriptblock]$Action,[string]$Message) {
    $caught=$false; try { & $Action | Out-Null } catch { $caught=$true }
    Assert-True $caught $Message
}
# Synthetic PUBLIC blobs only; these are not deployment credentials.
$prefix=[byte[]](0,0,0,11,115,115,104,45,101,100,50,53,53,49,57,0,0,0,32)
$keyA='ssh-ed25519 '+[Convert]::ToBase64String([byte[]]($prefix+@(1..32)))
$keyB='ssh-ed25519 '+[Convert]::ToBase64String([byte[]]($prefix+@(33..64)))
Assert-True ((ConvertTo-LabPublicKey "$keyA a comment") -ceq $keyA) 'Key normalization failed.'
foreach ($bad in @('-----BEGIN OPENSSH PRIVATE KEY-----',"$keyA`n$keyB",'ssh-ed25519 AAAA',
    ('restrict '+$keyA),($keyA.Replace('ssh-ed25519','ssh-rsa')))) {
    Assert-Throws { ConvertTo-LabPublicKey $bad } 'Accepted malformed or unsupported key.'
}
Assert-True ((Add-LabPublicKey '' $keyA) -ceq ($keyA+"`r`n")) 'First key append failed.'
$old="$keyA old-comment`r`n"
Assert-True ((Add-LabPublicKey $old $keyA) -ceq $old) 'Duplicate key added on repeat.'
Assert-True ((Add-LabPublicKey $old $keyB).Contains($old.TrimEnd())) 'Existing key was lost.'
Assert-True ((Add-LabPublicKey ("restrict $keyA`r`n") $keyA).EndsWith("`r`n$keyA`r`n")) 'Restricted entry incorrectly treated as full authorization.'
$accounts=@(
    [pscustomobject]@{Name='fastllm-test';KeyPath='C:\ProgramData\ssh\fastllm-test_authorized_keys'},
    [pscustomobject]@{Name='fastllm-admin';KeyPath='C:\ProgramData\ssh\fastllm-admin_authorized_keys'}
)
$base="Port 22`r`nSubsystem sftp sftp-server.exe`r`nMatch Group administrators`r`n    AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys`r`n"
$config=New-LabSshConfiguration $base $accounts
Assert-True ($config.IndexOf('Match User fastllm-admin') -lt $config.IndexOf('Match Group administrators')) 'Admin block loses to generic administrator block.'
Assert-True ($config.IndexOf('Subsystem sftp') -lt $config.IndexOf('# BEGIN FASTLLM')) 'Global directive moved into Match context.'
Assert-True ((New-LabSshConfiguration $config $accounts) -ceq $config) 'Configuration is not idempotent.'
Assert-True ($config.Contains('AuthorizedKeysFile "C:/ProgramData/ssh/fastllm-admin_authorized_keys"')) 'Admin does not have its own key path.'
Assert-True ($config.Contains('AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys')) 'Unrelated admin rule modified.'
$legacy=$base+"# BEGIN FASTLLM LAB ACCESS`r`nMatch User fastllm-test`r`n    PasswordAuthentication no`r`nMatch all`r`n# END FASTLLM LAB ACCESS`r`n"
Assert-True ((New-LabSshConfiguration $legacy $accounts) -ceq $config) 'Legacy setup migration failed.'
Assert-True ((New-LabSshConfiguration 'Port 22' $accounts).Contains('Match User fastllm-admin')) 'Fresh/no-Match config failed.'
Assert-Throws { New-LabSshConfiguration ($base+'# BEGIN FASTLLM LAB ACCESS') $accounts } 'Unclosed managed block accepted.'
Assert-Throws { New-LabSshConfiguration ($legacy+"# BEGIN FASTLLM LAB ACCESS`n# END FASTLLM LAB ACCESS`n") $accounts } 'Duplicate managed blocks accepted.'
$effective=@('port 22','pubkeyauthentication yes','authenticationmethods publickey','passwordauthentication no',
    'kbdinteractiveauthentication no','authorizedkeysfile C:/ProgramData/ssh/fastllm-admin_authorized_keys')
Assert-LabEffectiveConfiguration $effective $accounts[1].KeyPath
$script:checks++
Assert-Throws { Assert-LabEffectiveConfiguration ($effective -replace 'passwordauthentication no','passwordauthentication yes') $accounts[1].KeyPath } 'Password-enabled override accepted.'
Assert-Throws { Assert-LabEffectiveConfiguration ($effective -replace 'fastllm-admin_authorized_keys','administrators_authorized_keys') $accounts[1].KeyPath } 'Shared admin key override accepted.'
Assert-Throws { Assert-LabEffectiveConfiguration ($effective -replace 'port 22','port 2222') $accounts[1].KeyPath } 'Wrong SSH port accepted.'

function Get-NetFirewallRule {
    [CmdletBinding()]param([string]$PolicyStore)
    if ($PolicyStore -ne 'ActiveStore' -or $ErrorActionPreference -ne 'Stop') { throw 'Bad query contract.' }
    if ($script:failFirewall) { throw 'Simulated firewall access denied' }
    $script:rules
}
$script:failFirewall=$false; $script:rules=@()
Assert-True (@(Get-LabBlockingRules).Count -eq 0) 'Empty rule set failed.'
$script:rules=@([pscustomobject]@{Enabled='True';Direction='Inbound';Action='Allow'})
Assert-True (@(Get-LabBlockingRules).Count -eq 0) 'No matching blocks failed.'
$script:rules+=@(
    [pscustomobject]@{Enabled='False';Direction='Inbound';Action='Block'},
    [pscustomobject]@{Enabled='True';Direction='Outbound';Action='Block'},
    [pscustomobject]@{Enabled='True';Direction='Inbound';Action='Block'}
)
Assert-True (@(Get-LabBlockingRules).Count -eq 1) 'Wrong block-rule filter.'
$script:failFirewall=$true
Assert-Throws { Get-LabBlockingRules } 'Genuine firewall failure swallowed.'

# Mock task scheduler only: no SYSTEM task is created by this suite.
$labBackup='C:/ProgramData/ssh/fastllm-backup-fixture'; $labSshd='C:/Windows/System32/OpenSSH/sshd.exe'; $labConfig='C:/ProgramData/ssh/sshd_config'
$oldSystemRoot=$env:SystemRoot
try {
    # Use current filesystem roots for Join-Path on non-Windows hosts.
    $labBackup=$PSScriptRoot; $env:SystemRoot=[IO.Path]::GetPathRoot($PSScriptRoot)
    $script:removed=$false; $script:taskFailure=$false
    function New-ScheduledTaskAction { param($Execute,$Argument,$WorkingDirectory) $script:actionArgs=$Argument; [pscustomobject]@{} }
    function New-ScheduledTaskPrincipal { param($UserId,$LogonType,$RunLevel)
        Assert-True ($UserId -eq 'S-1-5-18' -and $LogonType -eq 'ServiceAccount' -and $RunLevel -eq 'Highest') 'Check must run under SYSTEM.'
        [pscustomobject]@{}
    }
    function New-ScheduledTaskSettingsSet { param($ExecutionTimeLimit,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries)
        Assert-True ($ExecutionTimeLimit.TotalSeconds -eq 45) 'Check task must have deadline.'; [pscustomobject]@{}
    }
    function Register-ScheduledTask { param($TaskName,$Action,$Principal,$Settings) $script:taskName=$TaskName }
    function Start-ScheduledTask { param($TaskName) }
    function Get-ScheduledTask { param($TaskName) [pscustomobject]@{State='Ready'} }
    function Get-ScheduledTaskInfo { param($TaskName) [pscustomobject]@{LastRunTime=[datetime]'2026-01-01';LastTaskResult=$(if($script:taskFailure){1}else{0})} }
    function Unregister-ScheduledTask { param($TaskName,[switch]$Confirm)
        Assert-True ($TaskName -ceq $script:taskName) 'Wrong task removed.'; $script:removed=$true
    }
    function Test-Path { param($LiteralPath) $true }
    function Get-Content { param($LiteralPath) if ($LiteralPath -notlike '*.errors.txt') { $effective } }
    $result=@(Get-LabEffectiveConfiguration 'fastllm-admin' '192.0.2.2')
    Assert-True ($result -contains 'authenticationmethods publickey') 'Missing effective configuration output.'
    Assert-True $script:removed 'Successful task not removed.'
    Assert-True ($script:actionArgs.Contains('-T -f "C:/ProgramData/ssh/sshd_config" -C "user=fastllm-admin,host=lab-client,addr=192.0.2.2"')) 'Wrong SYSTEM command.'
    $script:removed=$false; $script:taskFailure=$true
    Assert-Throws { Get-LabEffectiveConfiguration 'fastllm-test' '192.0.2.2' } 'Failed SYSTEM check accepted.'
    Assert-True $script:removed 'Failed task not removed.'
    Assert-Throws { Get-LabEffectiveConfiguration 'bad%name' '192.0.2.2' } 'Unsafe cmd substitution accepted.'
} finally { $env:SystemRoot=$oldSystemRoot }

$source=[IO.File]::ReadAllText($SetupScript)
foreach ($forbidden in @('Set-NetFirewallProfile','Disable-NetFirewallRule','Set-LocalUser','Set-ExecutionPolicy','LocalAccountTokenFilterPolicy')) {
    Assert-True (-not $source.Contains($forbidden)) "Unexpected broad mutation: $forbidden"
}
Assert-True ($source.Contains('Remove-LocalGroupMember -Group $adminGroup -Member $AdminUserName')) 'Failure does not revoke new admin membership.'
Assert-True ($source.Contains('Profile=''Any''') -and $source.Contains('RemoteAddress=''Any''')) 'Bench firewall scope changed.'
Assert-True (-not $source.Contains('AAAAC3N')) 'Deployment key embedded in reusable script.'
Write-Host "PASS: $script:checks lab-access helper/source checks on PowerShell $($PSVersionTable.PSVersion). No privileged setup executed."
