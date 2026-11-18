# Shared by the two suites that read PowerShell's own module log (sidecar-tests.ps1, api-key-wiring-tests.ps1).
# The window is captured LIVE: a subscription (tests/helpers/ModuleLogTap.cs) keeps each event 4103 of this process as it is written, so the
# size of the operational log - a circular log that overwrites its oldest records when it fills - cannot take anything out of the window. The
# tap also keeps the id of every record delivered, so the suites can prove that no record between the two canaries was missed.
# Windows only. Every function here is plain .NET calls and language constructs - no cmdlet - so that while module logging is on, these
# helpers log nothing of their own. They print numbers only, never the text of a logged event. Nothing here changes a system setting.
$script:moduleLogTapRoot = $PSScriptRoot
$script:moduleLogTapStartError = ''
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

# Starts the live capture. Call it BEFORE module logging is turned on, so that compiling the tap and creating it log nothing. The type is
# compiled once per process. Windows PowerShell 5.1 compiles it against the assembly that holds EventLogWatcher (System.Core). PowerShell 7
# gives Add-Type only the references it is told about, so it is given its own reference assemblies as well.
function Start-ModuleLogTap([string] $LogName, [int] $ProcessId) {
    if (-not ('FastLlmTests.ModuleLogTap' -as [type])) {
        $references = @([Diagnostics.Eventing.Reader.EventLogWatcher].Assembly.Location)
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $referenceDirectory = Join-Path $PSHOME 'ref'
            if (-not (Test-Path -LiteralPath $referenceDirectory)) { throw "FAIL: module logging: the reference assemblies of this PowerShell ($referenceDirectory) are missing, so the live capture cannot be compiled" }
            $references = @(Get-ChildItem -LiteralPath $referenceDirectory -Filter '*.dll' | ForEach-Object { $_.FullName }) + $references
        }
        Add-Type -Path (Join-Path $script:moduleLogTapRoot 'ModuleLogTap.cs') -ReferencedAssemblies $references -ErrorAction Stop
    }
    # A log that cannot be subscribed to (not registered, not readable) leaves no tap, as a log that could not be read always did: the canary
    # is never seen, PowerShell 7 skips the check and says so, and Windows PowerShell 5.1 fails it ("must run to the end"). The reason is kept.
    $script:moduleLogTapStartError = ''
    try { return New-Object 'FastLlmTests.ModuleLogTap' @($LogName, $ProcessId) }
    catch {
        $failure = $_.Exception
        if ($null -ne $failure.InnerException) { $failure = $failure.InnerException }
        $script:moduleLogTapStartError = $failure.GetType().Name
        return $null
    }
}

function Stop-ModuleLogTap($Tap) {
    if ($null -ne $Tap) { $Tap.Dispose() }
}

# How many record ids from First to Last (both included) are not in Ids; -1 when the range is not a range. Duplicates and order do not matter.
function Get-ModuleLogMissingCount([long[]] $Ids, [long] $First, [long] $Last) {
    if ($First -lt 0 -or $Last -lt $First) { return [long] -1 }
    $seen = [Collections.Generic.HashSet[long]]::new()
    foreach ($id in $Ids) { [void] $seen.Add($id) }
    $missing = [long] 0
    for ($id = $First; $id -le $Last; $id++) { if (-not $seen.Contains($id)) { $missing++ } }
    return $missing
}

# What the live capture proves: no subscription error, and every record id from canary one's record to canary two's was delivered.
function Get-ModuleLogTapReport($Tap, [string] $CanaryOne, [string] $CanaryTwo) {
    $oneId = [long] $Tap.FindRecord($CanaryOne)
    $twoId = [long] $Tap.FindRecord($CanaryTwo)
    return [pscustomobject] @{
        errors = [int] $Tap.Errors
        errorType = [string] $Tap.FirstErrorType
        oneId = $oneId
        twoId = $twoId
        missing = (Get-ModuleLogMissingCount $Tap.RecordIds() $oneId $twoId)
        delivered = [int] $Tap.RecordIds().Length
    }
}

function Test-ModuleLogTapComplete($Report) {
    return ($Report.errors -eq 0 -and $Report.oneId -ge 0 -and $Report.twoId -ge $Report.oneId -and $Report.missing -eq 0)
}

# The INFO lines, called once logging is off, whether the check passes or fails. Numbers only.
function Get-ModuleLogEvidenceLines([string] $Kind, [string] $LogName, [int] $ProcessId, [DateTime] $BeginUtc, $Evidence, [string] $FinalText, [string] $CanaryOne, [string] $CanaryTwo, $TapReport = $null) {
    if ($Kind -ceq 'windows') {
        $oneId = [long] $Evidence.oneId
        $newest = Get-ModuleLogNewestRecordId $LogName
        $since = 'unknown'
        $stillThere = 'unknown'
        $wrapped = 'unknown'
        if ($oneId -ge 0) { $since = [string] ($newest - $oneId); $present = Test-ModuleLogRecordExists $LogName $oneId; $stillThere = [string] $present; $wrapped = [string] (-not $present) }
        $live = 'no live capture'
        if ($null -ne $TapReport) { $live = "records delivered $($TapReport.delivered), canary one record id $($TapReport.oneId), canary two record id $($TapReport.twoId), missing between them $($TapReport.missing), subscription errors $($TapReport.errors) $($TapReport.errorType)" }
        return @(
            "INFO: module log, log '$LogName', canary one first seen: record id $oneId; the log then: $($Evidence.oneSnapshot)",
            "INFO: module log, final read: $($FinalText.Length) characters; the log now: $(Get-ModuleLogSnapshot $LogName); newest record id $newest; records written since canary one: $since; canary one's record still in the log: $stillThere; the on-disk log wrapped during the window: $wrapped",
            "INFO: module log, live capture: $live",
            "INFO: module log, records in the log since the window began (event id/process=count): $(Get-ModuleLogWindowCounts $LogName $ProcessId $BeginUtc)",
            "INFO: module log, last read inside the canary wait: $($Evidence.lastWait)",
            "INFO: module log, final read: $(Get-ModuleLogFlags $FinalText $CanaryOne $CanaryTwo)")
    }
    return @("INFO: module log, source '$Kind': $($FinalText.Length) characters")
}
