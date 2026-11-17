# Shared by the two suites that read PowerShell's own module log (sidecar-tests.ps1, api-key-wiring-tests.ps1).
# Windows only: every function here is plain .NET calls and language constructs - no cmdlet - so that while module logging is on, these
# helpers log nothing of their own. They print numbers only, never the text of a logged event.
if ($env:OS -eq 'Windows_NT') {
    try { if ($PSVersionTable.PSVersion.Major -ge 6) { Add-Type -AssemblyName System.Diagnostics.EventLog } else { Add-Type -AssemblyName System.Core } } catch { $null = $_ }
}

function Open-ModuleLogReader([string] $LogName, [string] $XPath, [bool] $NewestFirst) {
    $query = [Diagnostics.Eventing.Reader.EventLogQuery]::new($LogName, [Diagnostics.Eventing.Reader.PathType]::LogName, $XPath)
    $query.ReverseDirection = $NewestFirst
    return [Diagnostics.Eventing.Reader.EventLogReader]::new($query)
}

function Get-ModuleLogWindowXPath([int] $ProcessId, [DateTime] $BeginUtc, [bool] $OnlyThisProcess) {
    $since = "TimeCreated[@SystemTime>='$($BeginUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))']"
    if ($OnlyThisProcess) { return "*[System[(EventID=4103) and Execution[@ProcessID=$ProcessId] and $since]]" }
    return "*[System[$since]]"
}

# The log's own numbers: mode, size limit, size on disk, record count, full flag, oldest record id.
function Get-ModuleLogSnapshot([string] $LogName) {
    try {
        $config = [Diagnostics.Eventing.Reader.EventLogConfiguration]::new($LogName)
        $info = [Diagnostics.Eventing.Reader.EventLogSession]::GlobalSession.GetLogInformation($LogName, [Diagnostics.Eventing.Reader.PathType]::LogName)
        return "LogMode=$($config.LogMode) MaximumSizeInBytes=$($config.MaximumSizeInBytes) FileSize=$($info.FileSize) RecordCount=$($info.RecordCount) IsLogFull=$($info.IsLogFull) OldestRecordNumber=$($info.OldestRecordNumber)"
    }
    catch { return 'unavailable (' + $_.Exception.GetType().Name + ')' }
}

# The RecordId of the newest event 4103 of this process whose message holds the text, or -1. Newest first: a canary just written is near the front.
function Find-ModuleLogRecordId([string] $LogName, [int] $ProcessId, [DateTime] $BeginUtc, [string] $Needle) {
    $reader = $null
    try {
        $reader = Open-ModuleLogReader $LogName (Get-ModuleLogWindowXPath $ProcessId $BeginUtc $true) $true
        while ($null -ne ($record = $reader.ReadEvent())) {
            try {
                $description = $record.FormatDescription()
                if ($null -ne $description -and $description.IndexOf($Needle, [StringComparison]::Ordinal) -ge 0) { return [long] $record.RecordId }
            }
            finally { $record.Dispose() }
        }
    }
    catch { $null = $_ }
    finally { if ($null -ne $reader) { $reader.Dispose() } }
    return [long] -1
}

function Test-ModuleLogRecordExists([string] $LogName, [long] $RecordId) {
    $reader = $null
    try {
        $reader = Open-ModuleLogReader $LogName "*[System[EventRecordID=$RecordId]]" $false
        $record = $reader.ReadEvent()
        if ($null -eq $record) { return $false }
        $record.Dispose()
        return $true
    }
    catch { return $false }
    finally { if ($null -ne $reader) { $reader.Dispose() } }
}

function Get-ModuleLogNewestRecordId([string] $LogName) {
    $reader = $null
    try {
        $reader = Open-ModuleLogReader $LogName '*' $true
        $record = $reader.ReadEvent()
        if ($null -eq $record) { return [long] -1 }
        $id = [long] $record.RecordId
        $record.Dispose()
        return $id
    }
    catch { return [long] -1 }
    finally { if ($null -ne $reader) { $reader.Dispose() } }
}

# Records still in the log since the window began, counted by event id and by this process / another one. No message is rendered.
function Get-ModuleLogWindowCounts([string] $LogName, [int] $ProcessId, [DateTime] $BeginUtc) {
    $counts = @{}
    $reader = $null
    try {
        $reader = Open-ModuleLogReader $LogName (Get-ModuleLogWindowXPath $ProcessId $BeginUtc $false) $false
        while ($null -ne ($record = $reader.ReadEvent())) {
            $owner = 'other'
            if ($record.ProcessId -eq $ProcessId) { $owner = 'this' }
            $key = "$($record.Id)/$owner"
            if ($counts.ContainsKey($key)) { $counts[$key] = $counts[$key] + 1 } else { $counts[$key] = 1 }
            $record.Dispose()
        }
    }
    catch { $counts['error/' + $_.Exception.GetType().Name] = 1 }
    finally { if ($null -ne $reader) { $reader.Dispose() } }
    $keys = [string[]] @($counts.Keys)
    [Array]::Sort($keys)
    $parts = @(foreach ($key in $keys) { "$key=$($counts[$key])" })
    return ($parts -join ' ')
}

# The three conditions of the "really recorded" check, each by itself.
function Get-ModuleLogFlags([string] $Text, [string] $CanaryOne, [string] $CanaryTwo) {
    $one = $Text.IndexOf($CanaryOne, [StringComparison]::Ordinal) -ge 0
    $two = $Text.IndexOf($CanaryTwo, [StringComparison]::Ordinal) -ge 0
    $holder = $Text.IndexOf('System.Security.SecureString', [StringComparison]::Ordinal) -ge 0
    return "canary one: $one, canary two: $two, key holder type name: $holder"
}

# What canary one's first sighting looked like (Windows): its record id and the log's numbers at that moment.
function Get-ModuleLogFirstSeen([string] $LogName, [int] $ProcessId, [DateTime] $BeginUtc, [string] $CanaryOne) {
    return [pscustomobject] @{
        recordId = (Find-ModuleLogRecordId $LogName $ProcessId $BeginUtc $CanaryOne)
        snapshot = (Get-ModuleLogSnapshot $LogName)
    }
}

# The INFO lines, called once logging is off, whether the check passes or fails. Numbers only.
function Get-ModuleLogEvidenceLines([string] $Kind, [string] $LogName, [int] $ProcessId, [DateTime] $BeginUtc, $Evidence, [string] $FinalText, [string] $CanaryOne, [string] $CanaryTwo) {
    if ($Kind -ceq 'windows') {
        $oneId = [long] $Evidence.oneId
        $newest = Get-ModuleLogNewestRecordId $LogName
        $since = 'unknown'
        $stillThere = 'unknown'
        if ($oneId -ge 0) { $since = [string] ($newest - $oneId); $stillThere = [string] (Test-ModuleLogRecordExists $LogName $oneId) }
        return @(
            "INFO: module log, log '$LogName', canary one first seen: record id $oneId; the log then: $($Evidence.oneSnapshot)",
            "INFO: module log, final read: $($FinalText.Length) characters; the log now: $(Get-ModuleLogSnapshot $LogName); newest record id $newest; records written since canary one: $since; canary one's record still in the log: $stillThere",
            "INFO: module log, records in the log since the window began (event id/process=count): $(Get-ModuleLogWindowCounts $LogName $ProcessId $BeginUtc)",
            "INFO: module log, last read inside the canary wait: $($Evidence.lastWait)",
            "INFO: module log, final read: $(Get-ModuleLogFlags $FinalText $CanaryOne $CanaryTwo)")
    }
    return @("INFO: module log, source '$Kind': $($FinalText.Length) characters")
}
