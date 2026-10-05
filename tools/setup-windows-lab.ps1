#requires -Version 5.1
<#
Private bench administration, NOT part of the inference installer.
Run from an elevated local/RDP console, never from an SSH session.
Supplied keys gain standard-user and full administrator SSH access respectively.
TCP 22 is allowed on every firewall profile from ANY source address.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$TestPublicKeyPath,
    [Parameter(Mandatory=$true)][string]$AdminPublicKeyPath,
    [ValidatePattern('^[a-z][a-z0-9-]{0,19}$')][string]$TestUserName = 'fastllm-test',
    [ValidatePattern('^[a-z][a-z0-9-]{0,19}$')][string]$AdminUserName = 'fastllm-admin',
    [string[]]$ValidationClientAddress = @('127.0.0.1')
)
$ErrorActionPreference = 'Stop'

function ConvertTo-LabPublicKey([string]$Text) {
    # One plain Ed25519 key, no private keys, certificates, or authorized_keys options.
    $line = $Text.Trim().TrimStart([char]0xFEFF)
    if ($line.Length -gt 4096 -or $line -notmatch '^ssh-ed25519 ([A-Za-z0-9+/]+={0,2})(?: [^\r\n]*)?$') {
        throw 'Supply one plain ssh-ed25519 PUBLIC key per file.'
    }
    $blob = [Convert]::FromBase64String($Matches[1])
    $prefix = [byte[]](0,0,0,11,115,115,104,45,101,100,50,53,53,49,57,0,0,0,32)
    if ($blob.Length -ne 51) { throw 'Invalid Ed25519 public-key length.' }
    for ($i=0; $i -lt $prefix.Length; $i++) {
        if ($blob[$i] -ne $prefix[$i]) { throw 'Invalid Ed25519 public-key encoding.' }
    }
    # Drop the optional comment; it is not part of the authorization identity.
    'ssh-ed25519 ' + [Convert]::ToBase64String($blob)
}

function Add-LabPublicKey([string]$Existing, [string]$Key) {
    $identity = ($Key -split ' ')[1]
    foreach ($line in ($Existing -split '\r?\n')) {
        # Do not treat restricted/option-prefixed entries as an unrestricted grant.
        if ($line -match '^ssh-ed25519\s+(\S+)(?:\s|$)' -and $Matches[1] -ceq $identity) {
            return $Existing
        }
    }
    if ([string]::IsNullOrWhiteSpace($Existing)) { return $Key + "`r`n" }
    $Existing.TrimEnd() + "`r`n" + $Key + "`r`n"
}

function New-LabSshConfiguration([string]$Existing, [object[]]$Accounts) {
    $begin = '# BEGIN FASTLLM LAB ACCESS'
    $end = '# END FASTLLM LAB ACCESS'
    $starts = [regex]::Matches($Existing, '(?m)^# BEGIN FASTLLM LAB ACCESS\r?$').Count
    $ends = [regex]::Matches($Existing, '(?m)^# END FASTLLM LAB ACCESS\r?$').Count
    if ($starts -ne $ends -or $starts -gt 1) { throw 'Malformed/duplicate FastLLM configuration markers.' }
    $base = [regex]::Replace($Existing, '(?ms)^# BEGIN FASTLLM LAB ACCESS\r?\n.*?^# END FASTLLM LAB ACCESS\r?\n?', '')
    if ($base.Contains($begin) -or $base.Contains($end)) { throw 'Unrecognized FastLLM configuration marker layout.' }
    $parts = @($begin)
    foreach ($account in $Accounts) {
        if ($account.Name -cnotmatch '^[a-z][a-z0-9-]{0,19}$' -or $account.KeyPath -match '["\r\n%]') {
            throw 'Unsafe account/configuration value.'
        }
        $parts += @("Match User $($account.Name)",
            ('    AuthorizedKeysFile "{0}"' -f $account.KeyPath.Replace('\','/')),
            '    PubkeyAuthentication yes', '    AuthenticationMethods publickey',
            '    PasswordAuthentication no', '    KbdInteractiveAuthentication no')
    }
    $parts += @('Match all', $end)
    # First matching value wins. Insert BEFORE the generic administrators Match,
    # but AFTER global directives; never append admin settings behind that rule.
    $firstMatch = [regex]::Match($base, '(?im)^[ \t]*Match[ \t]+')
    $cut = if ($firstMatch.Success) { $firstMatch.Index } else { $base.Length }
    $global = $base.Substring(0,$cut).TrimEnd()
    $tail = $base.Substring($cut).TrimStart([char]13,[char]10)
    $global + "`r`n`r`n" + ($parts -join "`r`n") + "`r`n" + $tail
}

function Assert-LabPlainPath([string]$Path) {
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Refusing a linked path or ancestor: $cursor"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Set-LabAcl([string]$Path, [Security.Principal.SecurityIdentifier]$Reader, [switch]$InitializeBackup) {
    Assert-LabPlainPath $Path
    if ($InitializeBackup -and $Path -ne $labBackup) { throw 'Invalid backup initialization target.' }
    $labAclHistory.Add([pscustomobject]@{Path=$Path; Sddl=(Get-Acl -LiteralPath $Path).Sddl})
    if (-not $InitializeBackup) {
        $labAclHistory | Export-Clixml -LiteralPath (Join-Path $labBackup 'permissions.xml')
    }
    $inheritance = [Security.AccessControl.InheritanceFlags]::None
    if ((Get-Item -LiteralPath $Path -Force).PSIsContainer) {
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    } else { $acl = [Security.AccessControl.FileSecurity]::new() }
    $acl.SetOwner($labAdmins)
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($sid in @($labAdmins,$labSystem)) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,
            [Security.AccessControl.FileSystemRights]::FullControl, $inheritance,
            [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
    }
    if ($null -ne $Reader) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($Reader,
            [Security.AccessControl.FileSystemRights]::ReadAndExecute, [Security.AccessControl.AccessControlType]::Allow))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
    if ($InitializeBackup) {
        # Verify creation AND rewriting after applying inheritable admin/SYSTEM ACLs.
        $labAclHistory | Export-Clixml -LiteralPath (Join-Path $labBackup 'permissions.xml')
        $labAclHistory | Export-Clixml -LiteralPath (Join-Path $labBackup 'permissions.xml')
    }
}

function Get-LabEffectiveConfiguration([string]$UserName, [string]$ClientAddress) {
    $taskName = 'FastLLM-SSH-Check-' + [guid]::NewGuid().ToString('N')
    $output = Join-Path $labBackup ($taskName + '.txt')
    $errors = Join-Path $labBackup ($taskName + '.errors.txt')
    $connection = "user=$UserName,host=lab-client,addr=$ClientAddress"
    foreach ($value in @($labSshd,$labConfig,$output,$errors,$connection)) {
        if ($value -match '[%"\r\n]') { throw 'Unsafe SYSTEM validation command path/value.' }
    }
    $arguments = '/d /v:off /s /c ""{0}" -T -f "{1}" -C "{2}" 1>"{3}" 2>"{4}""' -f $labSshd,$labConfig,$connection,$output,$errors
    $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\cmd.exe') -Argument $arguments -WorkingDirectory $labBackup
    $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds 45) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $registered = $false
    try {
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings | Out-Null
        $registered = $true
        Start-ScheduledTask -TaskName $taskName
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $finished = $false
        while ($timer.Elapsed.TotalSeconds -lt 55) {
            $state = (Get-ScheduledTask -TaskName $taskName).State
            $info = Get-ScheduledTaskInfo -TaskName $taskName
            if ($state -notin @('Running','Queued') -and $info.LastRunTime.Year -gt 2000 -and $info.LastTaskResult -ne 267009) {
                $finished = $true; break
            }
            Start-Sleep -Milliseconds 250
        }
        if (-not $finished) { throw "SYSTEM validation timed out: $UserName" }
        if ($info.LastTaskResult -ne 0) {
            if (Test-Path -LiteralPath $errors) { Get-Content -LiteralPath $errors | ForEach-Object { Write-Host $_ } }
            throw "SYSTEM validation failed for $UserName (exit $($info.LastTaskResult))."
        }
        if (-not (Test-Path -LiteralPath $output)) { throw 'SYSTEM validation produced no output.' }
        Get-Content -LiteralPath $output
    } finally {
        if ($registered) {
            if ((Get-ScheduledTask -TaskName $taskName).State -in @('Running','Queued')) {
                Stop-ScheduledTask -TaskName $taskName
            }
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            Write-Host "Removed temporary validation task: $taskName"
        }
    }
}

function Assert-LabEffectiveConfiguration([string[]]$Lines, [string]$KeyPath) {
    foreach ($expected in @('pubkeyauthentication yes','authenticationmethods publickey',
        'passwordauthentication no','kbdinteractiveauthentication no',
        ('authorizedkeysfile ' + $KeyPath.Replace('\','/')))) {
        if ($Lines -inotcontains $expected) { throw "Conflicting effective SSH setting; expected: $expected" }
    }
    if ($Lines -inotcontains 'port 22') { throw 'This lab setup requires SSH port 22.' }
}

function Get-LabBlockingRules {
    # Filtering the CIM query itself produces CmdletizationQuery_NotFound on zero matches.
    Get-NetFirewallRule -PolicyStore ActiveStore -ErrorAction Stop | Where-Object {
        [string]$_.Enabled -eq 'True' -and [string]$_.Direction -eq 'Inbound' -and [string]$_.Action -eq 'Block'
    }
}

if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) {
    throw 'Use 64-bit Windows PowerShell 5.1 or PowerShell 7 on the Windows bench.'
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run from Administrator PowerShell in a local or RDP session.'
}
if ($env:SSH_CONNECTION) { throw 'Run locally or through RDP: setup must restart SSH.' }
$TestUserName = $TestUserName.ToLowerInvariant()
$AdminUserName = $AdminUserName.ToLowerInvariant()
if ($TestUserName -eq $AdminUserName) { throw 'The test and administrator accounts must be different.' }
$ValidationClientAddress = @(@('127.0.0.1') + $ValidationClientAddress | Select-Object -Unique)
foreach ($address in $ValidationClientAddress) {
    $parsedAddress = $null
    if (-not [Net.IPAddress]::TryParse($address, [ref]$parsedAddress)) { throw "Invalid validation client IP address: $address" }
}
$testKey = ConvertTo-LabPublicKey ([IO.File]::ReadAllText((Resolve-Path -LiteralPath $TestPublicKeyPath).Path))
$adminKey = ConvertTo-LabPublicKey ([IO.File]::ReadAllText((Resolve-Path -LiteralPath $AdminPublicKeyPath).Path))
if ($testKey -eq $adminKey) { throw 'Use different client public keys for standard-user and administrator access.' }

$labAdmins = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
$labSystem = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
$labReaders = [Security.Principal.SecurityIdentifier]::new('S-1-5-11')
$labAclHistory = [Collections.Generic.List[object]]::new()
$utf8 = [Text.UTF8Encoding]::new($false)
$labRoot = Join-Path $env:ProgramData 'ssh'
Assert-LabPlainPath $labRoot
New-Item -ItemType Directory -Path $labRoot -Force | Out-Null
$labBackup = Join-Path $labRoot ('fastllm-backup-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $labBackup | Out-Null
Set-LabAcl $labBackup $null -InitializeBackup
Start-Transcript -LiteralPath (Join-Path $labBackup 'setup-log.txt') | Out-Null
$filesBefore = [Collections.Generic.List[object]]::new()
$configWritten = $false
$adminMembershipAdded = $false
$serviceBefore = $null
$success = $false
try {
    Write-Host 'FastLLM Windows bench setup - revision 2026.10.04.3'
    Write-Host "Backups and report: $labBackup"
    Write-Warning "This grants $AdminUserName full administrator SSH access and opens TCP 22 to ANY source on ALL profiles."
    Write-Host 'RDP, UAC, passwords for existing accounts, and host-key identities are preserved.'
    foreach ($feature in @('OpenSSH.Client~~~~0.0.1.0','OpenSSH.Server~~~~0.0.1.0')) {
        if ((Get-WindowsCapability -Online -Name $feature).State -ne 'Installed') {
            Write-Host "Installing $feature (Internet/Windows Update required)..."
            $installed = Add-WindowsCapability -Online -Name $feature
            if ($installed.RestartNeeded) { throw 'Windows requests a reboot. Reboot, then rerun this script.' }
            if ((Get-WindowsCapability -Online -Name $feature).State -ne 'Installed') { throw "Installation incomplete: $feature" }
        }
    }
    $labBin = Join-Path $env:SystemRoot 'System32\OpenSSH'
    $labSshd = Join-Path $labBin 'sshd.exe'
    $keygen = Join-Path $labBin 'ssh-keygen.exe'
    $serviceBefore = Get-CimInstance Win32_Service -Filter "Name='sshd'"
    if (-not $serviceBefore -or $serviceBefore.PathName.Trim('"') -ine $labSshd -or $serviceBefore.StartName -ne 'LocalSystem') {
        throw 'Unexpected SSH service path/account. Only the inbox LocalSystem service is supported.'
    }
    $serviceBefore | Select-Object State, StartMode, PathName, StartName |
        Export-Clixml -LiteralPath (Join-Path $labBackup 'service-before.xml')
    $adminGroup = Get-LocalGroup -SID $labAdmins
    $usersGroup = Get-LocalGroup -SID 'S-1-5-32-545'
    $accounts = @(
        [pscustomobject]@{Name=$TestUserName;Key=$testKey;Admin=$false;User=$null;KeyPath=(Join-Path $labRoot ($TestUserName + '_authorized_keys'))},
        [pscustomobject]@{Name=$AdminUserName;Key=$adminKey;Admin=$true;User=$null;KeyPath=(Join-Path $labRoot ($AdminUserName + '_authorized_keys'))}
    )
    foreach ($account in $accounts) {
        $account.User = Get-LocalUser | Where-Object Name -eq $account.Name
        if (-not $account.User) {
            $password = Read-Host "Choose a LOCAL Windows password for $($account.Name) (do not send it to us)" -AsSecureString
            try { $account.User = New-LocalUser -Name $account.Name -Password $password -Description 'Bitworks FastLLM lab access' }
            finally { $password.Dispose() }
        }
        if (-not $account.User.Enabled) { throw "$($account.Name) is disabled; review it before proceeding." }
        $resolvedSid = ([Security.Principal.NTAccount]::new($env:COMPUTERNAME,$account.Name)).Translate([Security.Principal.SecurityIdentifier])
        if ($resolvedSid.Value -ne $account.User.SID.Value) { throw 'Local account/SID lookup mismatch.' }
        $isAdmin = @(Get-LocalGroupMember -Group $adminGroup | Where-Object { $_.SID.Value -eq $account.User.SID.Value }).Count -gt 0
        if (-not $account.Admin -and $isAdmin) { throw "$TestUserName must remain a standard user; refusing to demote or repurpose an existing administrator." }
        if (-not @(Get-LocalGroupMember -Group $usersGroup | Where-Object { $_.SID.Value -eq $account.User.SID.Value }).Count) {
            Add-LocalGroupMember -Group $usersGroup -Member $account.User
        }
        if ($account.Admin -and -not $isAdmin) {
            Add-LocalGroupMember -Group $adminGroup -Member $account.User
            $adminMembershipAdded = $true
        }
    }
    $adminMembers = @(Get-LocalGroupMember -Group $adminGroup)
    foreach ($account in $accounts) {
        $member = @($adminMembers | Where-Object { $_.SID.Value -eq $account.User.SID.Value }).Count -gt 0
        if ($member -ne $account.Admin) { throw "Administrator membership verification failed: $($account.Name)" }
    }

    Set-LabAcl $labRoot $labReaders
    $logs = Join-Path $labRoot 'logs'
    Assert-LabPlainPath $logs
    New-Item -ItemType Directory -Path $logs -Force | Out-Null
    Set-LabAcl $logs $null
    $labConfig = Join-Path $labRoot 'sshd_config'
    Assert-LabPlainPath $labConfig
    if (-not (Test-Path -LiteralPath $labConfig)) {
        Copy-Item -LiteralPath (Join-Path $labBin 'sshd_config_default') -Destination $labConfig
    }
    Copy-Item -LiteralPath $labConfig -Destination (Join-Path $labBackup 'sshd_config.before')
    foreach ($account in $accounts) {
        Assert-LabPlainPath $account.KeyPath
        $existed = Test-Path -LiteralPath $account.KeyPath
        $copy = Join-Path $labBackup ($account.Name + '.keys.before')
        if ($existed) { Copy-Item -LiteralPath $account.KeyPath -Destination $copy }
        $filesBefore.Add([pscustomobject]@{Path=$account.KeyPath;Existed=$existed;Backup=$copy})
    }
    foreach ($name in @('ssh_host_rsa_key','ssh_host_ecdsa_key','ssh_host_ed25519_key')) {
        Assert-LabPlainPath (Join-Path $labRoot $name)
        Assert-LabPlainPath (Join-Path $labRoot ($name + '.pub'))
    }
    & $keygen -A
    if ($LASTEXITCODE -ne 0) { throw 'Host-key generation failed.' }
    foreach ($name in @('ssh_host_rsa_key','ssh_host_ecdsa_key','ssh_host_ed25519_key')) {
        $path = Join-Path $labRoot $name
        if (Test-Path -LiteralPath $path) { Set-LabAcl $path $null }
    }
    foreach ($account in $accounts) {
        $old = if (Test-Path -LiteralPath $account.KeyPath) { [IO.File]::ReadAllText($account.KeyPath) } else { '' }
        [IO.File]::WriteAllText($account.KeyPath,(Add-LabPublicKey $old $account.Key),$utf8)
        $reader = if ($account.Admin) { $null } else { $account.User.SID }
        Set-LabAcl $account.KeyPath $reader
    }
    $newConfig = New-LabSshConfiguration ([IO.File]::ReadAllText($labConfig)) $accounts
    $configWritten = $true
    [IO.File]::WriteAllText($labConfig,$newConfig,$utf8)
    Set-LabAcl $labConfig $labReaders
    & $labSshd -t -f $labConfig
    if ($LASTEXITCODE -ne 0) { throw 'SSH configuration validation failed.' }
    foreach ($account in $accounts) {
        foreach ($address in $ValidationClientAddress) {
            Write-Host "Checking effective settings as SYSTEM: $($account.Name), source $address (up to 55 seconds)..."
            Assert-LabEffectiveConfiguration @(Get-LabEffectiveConfiguration $account.Name $address) $account.KeyPath
        }
    }

    & (Join-Path $env:SystemRoot 'System32\netsh.exe') advfirewall export (Join-Path $labBackup 'firewall-before.wfw')
    if ($LASTEXITCODE -ne 0) { throw 'Firewall backup failed.' }
    $ruleName = 'FastLLM-Lab-SSH-In-TCP22'
    $ruleOptions = @{
        Name=$ruleName; PolicyStore='PersistentStore'; Enabled='True'; Direction='Inbound'; Action='Allow'; Profile='Any'
        Protocol='TCP'; LocalPort='22'; RemotePort='Any'; LocalAddress='Any'; RemoteAddress='Any'
        Program='Any'; Service='Any'; InterfaceAlias='*'; InterfaceType='Any'
        Authentication='NotRequired'; Encryption='NotRequired'; EdgeTraversalPolicy='Block'
    }
    $existing = @(Get-NetFirewallRule -PolicyStore PersistentStore -ErrorAction Stop | Where-Object Name -eq $ruleName)
    if ($existing.Count) { Set-NetFirewallRule @ruleOptions }
    else { New-NetFirewallRule @ruleOptions -DisplayName 'FastLLM lab - SSH TCP 22 - all profiles and sources' | Out-Null }
    Set-Service -Name sshd -StartupType Automatic
    if ((Get-Service sshd).Status -eq 'Running') { Restart-Service -Name sshd }
    else { Start-Service -Name sshd }
    Start-Sleep -Seconds 2
    $ready = Get-CimInstance Win32_Service -Filter "Name='sshd'"
    if ($ready.State -ne 'Running') { throw 'sshd did not remain running.' }
    $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction Stop |
        Where-Object { $_.OwningProcess -eq $ready.ProcessId -and $_.LocalPort -eq 22 })
    $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred |
        Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' })
    if (-not @($listeners | Where-Object { $_.LocalAddress -eq '0.0.0.0' -or $_.LocalAddress -in @($addresses.IPAddress) }).Count) {
        throw 'SSH has no IPv4 LAN listener on port 22. Check existing Port/ListenAddress directives.'
    }
    $effectiveRule = Get-NetFirewallRule -PolicyStore ActiveStore -Name $ruleName -ErrorAction Stop
    if ([string]$effectiveRule.Enabled -ne 'True' -or [string]$effectiveRule.Action -ne 'Allow') { throw 'Effective firewall allow rule is not enabled.' }
    Write-Host "`n=== FIREWALL ==="
    $effectiveRule | Format-List Name, Enabled, Direction, Action, Profile
    $effectiveRule | Get-NetFirewallAddressFilter | Format-List LocalAddress, RemoteAddress
    $profiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore)
    $profiles | Format-Table Name, Enabled, AllowInboundRules, AllowLocalFirewallRules -AutoSize
    if (@($profiles | Where-Object { [string]$_.Enabled -eq 'True' -and
        ([string]$_.AllowInboundRules -eq 'False' -or [string]$_.AllowLocalFirewallRules -eq 'False') }).Count) {
        Write-Warning 'A firewall profile suppresses inbound/local allow rules. Remote access may still be blocked.'
    }
    $blocks = @(Get-LabBlockingRules)
    if ($blocks.Count) {
        Write-Warning 'Enabled inbound BLOCK rules exist (possibly unrelated); they override matching allow rules and were not disabled.'
        $blocks | Format-Table Name, DisplayName, Profile -AutoSize
    } else { Write-Host 'Enabled inbound block rules: None.' }
    $report = @(
        'READY FOR REMOTE VERIFICATION - not a completed remote login test.'
        "Computer: $env:COMPUTERNAME"
        "Standard SSH user: $TestUserName"
        "Administrator SSH user: $AdminUserName"
        ($addresses | Select-Object InterfaceAlias, IPAddress | Format-Table -AutoSize | Out-String)
        ($listeners | Select-Object LocalAddress, LocalPort | Format-Table -AutoSize | Out-String)
        'Public Ed25519 HOST fingerprint (different on each PC):'
        (& $keygen -lf (Join-Path $labRoot 'ssh_host_ed25519_key.pub'))
        "Backups and diagnostic transcript: $labBackup"
        'TCP 22 allows all source addresses/all profiles. No RDP, UAC, VPN, or inference API changes.'
    )
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the host public-key fingerprint.' }
    $report | Set-Content -LiteralPath (Join-Path $labBackup 'connection-details.txt') -Encoding UTF8
    $report | ForEach-Object { Write-Host $_ }
    $success = $true
} catch {
    Write-Host "SETUP FAILED: $($_.Exception.Message)" -ForegroundColor Red
    if ($configWritten) {
        try { Copy-Item -LiteralPath (Join-Path $labBackup 'sshd_config.before') -Destination $labConfig }
        catch { Write-Warning "Configuration restore failed: $($_.Exception.Message)" }
    }
    foreach ($file in $filesBefore) {
        try {
            if ($file.Existed) { Copy-Item -LiteralPath $file.Backup -Destination $file.Path }
            elseif (Test-Path -LiteralPath $file.Path) { Remove-Item -LiteralPath $file.Path -Force }
        } catch { Write-Warning "Key-file rollback needs attention: $($file.Path): $($_.Exception.Message)" }
    }
    if ($adminMembershipAdded) {
        try { Remove-LocalGroupMember -Group $adminGroup -Member $AdminUserName; Write-Host 'Revoked administrator membership added by this failed run.' }
        catch { Write-Warning "ADMIN MEMBERSHIP ROLLBACK FAILED for $AdminUserName; remove it manually. $($_.Exception.Message)" }
    }
    if ($serviceBefore -and $configWritten) {
        try {
            $startup = switch ($serviceBefore.StartMode) { 'Auto' {'Automatic'} 'Disabled' {'Disabled'} default {'Manual'} }
            Set-Service -Name sshd -StartupType $startup
            if ($serviceBefore.State -eq 'Running') { Restart-Service -Name sshd }
            elseif ((Get-Service sshd).Status -eq 'Running') { Stop-Service -Name sshd }
        } catch { Write-Warning "SSH service restore needs attention: $($_.Exception.Message)" }
    }
    Write-Warning 'Installed components, newly created standard accounts, host-key/ACL repairs, and any completed TCP22 allow-rule change remain. The full firewall backup is not automatically imported.'
    throw
} finally {
    Stop-Transcript | Out-Null
    Write-Host "Report folder: $labBackup"
    if (-not $success) { Write-Host 'Send setup-log.txt for diagnosis. Do not send passwords or private keys.' }
}
