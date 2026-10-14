function Get-FastLlmStatistics {
    param([double[]]$Values)
    if (-not $Values -or @($Values | Where-Object { [double]::IsNaN($_) -or [double]::IsInfinity($_) -or $_ -lt 0 }).Count) { throw 'Statistics require finite non-negative samples.' }
    $sorted=@($Values | Sort-Object)
    $count=$sorted.Count
    $median=if($count%2){$sorted[[int][Math]::Floor($count/2)]}else{($sorted[$count/2-1]+$sorted[$count/2])/2}
    return [pscustomobject]@{count=$count;median=$median;minimum=$sorted[0];maximum=$sorted[-1];p95=$sorted[[int][Math]::Ceiling($count*0.95)-1];p95Caution=($count -lt 20)}
}

function Get-FastLlmPromptArtifactSha256 {
    param([object[]]$TokenIds)
    if(-not $TokenIds -or $TokenIds.Count -eq 0){throw 'Prompt token artifact must not be empty.'}
    $culture=[Globalization.CultureInfo]::InvariantCulture
    $builder=New-Object Text.StringBuilder
    [void]$builder.Append("fastllm-prompt-tokens-v1`n")
    [void]$builder.Append($TokenIds.Count.ToString($culture))
    [void]$builder.Append("`n")
    foreach($token in $TokenIds){
        if(($token -isnot [int] -and $token -isnot [long]) -or [long]$token -lt 0 -or [long]$token -gt [int]::MaxValue){
            throw 'Prompt token artifact contains an invalid token ID.'
        }
        $value=[long]$token
        [void]$builder.Append($value.ToString($culture))
        [void]$builder.Append("`n")
    }
    $hash=[Security.Cryptography.SHA256]::Create()
    try {
        $bytes=[Text.Encoding]::ASCII.GetBytes($builder.ToString())
        return ([BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
    } finally { $hash.Dispose() }
}

function Test-FastLlmBenchmarkFiniteNumber {
    param($Value,[bool]$Positive=$false)
    if($Value -isnot [int] -and $Value -isnot [long] -and $Value -isnot [double] -and
       $Value -isnot [single] -and $Value -isnot [decimal]){return $false}
    $number=[double]$Value
    if([double]::IsNaN($number) -or [double]::IsInfinity($number)){return $false}
    return $(if($Positive){$number -gt 0}else{$number -ge 0})
}

function ConvertFrom-FastLlmBenchmarkResponse {
    param($Response, [int]$ExpectedTokens)
    if ($Response.Status -ne 200) { throw 'Benchmark inference failed.' }
    if(-not $Response.Events -or -not $Response.EventTimesMs -or
       $Response.Events.Count -ne $Response.EventTimesMs.Count -or
       -not (Test-FastLlmBenchmarkFiniteNumber $Response.ElapsedMs)){
        throw 'Benchmark event timing shape is invalid.'
    }
    $priorMs=[double]0
    foreach($eventMs in $Response.EventTimesMs){
        if(-not (Test-FastLlmBenchmarkFiniteNumber $eventMs) -or
           [double]$eventMs -lt $priorMs -or [double]$eventMs -gt [double]$Response.ElapsedMs){
            throw 'Benchmark event timestamps are invalid.'
        }
        $priorMs=[double]$eventMs
    }
    $firstMs=$null;$last=$null;$finalCount=0
    for($i=0;$i -lt $Response.Events.Count;$i++) {
        if($Response.Events[$i] -eq '[DONE]'){continue}
        $item=ConvertFrom-Json $Response.Events[$i]
        $content=$item.PSObject.Properties['content']
        if($null -eq $firstMs -and $content -and -not [string]::IsNullOrEmpty([string]$content.Value)){$firstMs=$Response.EventTimesMs[$i]}
        $stop=$item.PSObject.Properties['stop']
        if($stop){
            if($stop.Value -isnot [bool]){throw 'Benchmark stream stop flags must be JSON booleans.'}
            if($stop.Value){$last=$item;$finalCount++}
        }
    }
    if($null -eq $firstMs -or $finalCount -ne 1 -or -not $last.PSObject.Properties['timings']){throw 'Benchmark stream requires first text and exactly one final stop with timings.'}
    $timing=$last.timings
    foreach($name in @('prompt_n','predicted_n')){
        $property=$timing.PSObject.Properties[$name]
        if(-not $property -or ($property.Value -isnot [int] -and $property.Value -isnot [long]) -or
           [long]$property.Value -lt 1 -or [long]$property.Value -gt [int]::MaxValue){
            throw 'Benchmark response token counts must be positive exact integers.'
        }
    }
    foreach($name in @('prompt_ms','predicted_ms')){
        $property=$timing.PSObject.Properties[$name]
        if(-not $property -or -not (Test-FastLlmBenchmarkFiniteNumber $property.Value $true)){
            throw 'Benchmark response durations must be finite positive numbers.'
        }
    }
    if([int]$timing.predicted_n -ne $ExpectedTokens -or [double]$timing.predicted_ms -le 0 -or [double]$timing.prompt_ms -le 0 -or [int]$timing.prompt_n -le 0){throw 'Benchmark token count/timings do not match the fixed workload.'}
    $pp=1000*[double]$timing.prompt_n/[double]$timing.prompt_ms
    $tg=1000*[double]$timing.predicted_n/[double]$timing.predicted_ms
    foreach($number in @($pp,$tg,$firstMs,$Response.ElapsedMs)){if([double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt 0){throw 'Non-finite benchmark measurement.'}}
    return [pscustomobject]@{promptTokens=[int]$timing.prompt_n;outputTokens=[int]$timing.predicted_n;promptTokensPerSecond=$pp;generationTokensPerSecond=$tg;timeToFirstTextMs=[double]$firstMs;completionMs=[double]$Response.ElapsedMs}
}

# ---------------------------------------------------------------------------
# v-next additions. Everything above this line is byte-identical to the
# reviewed c8b64fe0 producer (statistics, prompt artifact digest, response
# parsing). Sample semantics are unchanged; see docs/research/
# BENCHMARK-PRODUCER-VNEXT-SPEC-2026-10-06.md.
# ---------------------------------------------------------------------------

# Test seam: tests install scriptblocks by name; production leaves this empty.
$script:FastLlmBenchmarkSeams = @{}
# Tests set this to allow seams; a production run refuses to start with any seam installed.
$script:FastLlmBenchmarkAllowSeams = $false
$script:FastLlmRefusalReasons = @('access-denied','timeout','not-found','other')
$script:FastLlmPowerPlanGuids = @{
    '381b4222-f694-41f0-9685-ff5bb260df2e' = 'balanced'
    '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' = 'high-performance'
    'a1841308-3541-4fab-bc81-f71556f20b4a' = 'power-saver'
    'e9a42b02-d5df-448d-aa00-03f14749eb61' = 'ultimate-performance'
}
$script:FastLlmFirmwarePlaceholders = @(
    'System Product Name','System Manufacturer','System Version','To Be Filled By O.E.M.','Default string',
    'Not Applicable','Not Specified','None','N/A','Unknown','Undefined','Type1ProductConfigId',
    'Base Board Product Name','Base Board Manufacturer','Board Product Name','Type2 - Board Product Name',
    'Type2 - Board Manufacturer','OEM','Default'
)
$script:FastLlmBiosValueNames = @('BaseBoardManufacturer','BaseBoardProduct','BIOSVendor','BIOSVersion','BIOSReleaseDate','SystemManufacturer','SystemProductName')
# Intel CPU PEG root-port device IDs (PCI vendor 8086) known to attach a slot directly to the CPU.
# Reviewed table: add an entry only with an observed host and a source note.
$script:FastLlmCpuRootPortDeviceIds = @{
    '460D' = '12th-gen-peg'
    'A70D' = '13th-14th-gen-peg'
}
$script:FastLlmTelemetryMetricNames = @('gpuClockMHz','gpuVramClockMHz','gpuUsagePercent','gpuTotalBoardPowerW','gpuTemperatureC','gpuHotspotTemperatureC')
$script:FastLlmTelemetryIntervalMs = 1000
$script:FastLlmTelemetryPlannedCount = 7200
$script:FastLlmProducerVersion = 'vnext.2'
# Host capture fields that must be identical before and after the timed window.
$script:FastLlmHostStableFields = @('powerPlan','cpuTopology','smbiosMemory','boardBios')
# Relative VRAM tolerance between the engine-reported recipe VRAM and the ADLX total VRAM.
$script:FastLlmRecipeVramTolerance = 0.06
$script:FastLlmBenchmarkInputRelativePaths = @('src/WindowsCpuTopology.cs','src/WindowsSmbiosMemory.cs','src/WindowsVulkanLuidJoin.cs','src/WindowsPciAddress.cs','src/WindowsPciLink.cs','src/WindowsAcpiMcfg.cs','src/WindowsInventory.ps1','src/WindowsInventory.cs','src/WindowsGpuIdentity.cs','src/WindowsHostInventory.cs','src/ProcessHost.cs','src/FastLlm.Runtime.ps1','src/FastLlm.psm1','tools/collect-vulkan-luid-join.ps1','tools/adlx-identity-vram.ps1','tools/benchmark.ps1',
    'src/FastLlm.FileReplace.ps1','src/FastLlm.SelectedDeviceIdentity.ps1','src/FastLlm.OffloadLab.ps1','src/FastLlm.VulkanMemoryPolicy.ps1','src/FastLlm.DeviceBinding.ps1',
    'src/FastLlm.OffloadBenchmark.ps1','src/FastLlm.Soak.ps1','src/FastLlm.DriverGuidance.ps1','src/FastLlm.DriverGuidanceView.ps1','src/FastLlm.PrerequisiteDiagnostics.ps1',
    'src/WindowsBootTime.cs','src/WindowsGpuTelemetry.cs')
# Every file the module loads at import (the dot-sourced .ps1 files, transitively, and the C# sources they Add-Type) is listed above, except this
# producer itself, which the report pins as producer.sourceSha256. tests/benchmark-vnext-tests.ps1 parses the dot-source and Add-Type lines and fails when
# a loaded file is missing from the list. Classification (producer.inputClassification): 'identity' = the collectors (tools/* except tools/benchmark.ps1)
# and every C# source; 'runtime' = every other file (the module .ps1/.psm1 files, WindowsInventory.ps1 and the tools/benchmark.ps1 entry script).

function Get-FastLlmBenchmarkSeam {
    param([string]$Name)
    if ($script:FastLlmBenchmarkSeams.ContainsKey($Name)) { return $script:FastLlmBenchmarkSeams[$Name] }
    return $null
}

function Get-FastLlmBenchmarkProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-FastLlmBenchmarkFileSha256 {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path) -or -not [IO.File]::Exists($Path)) { return $null }
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try { return ([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
        finally { $stream.Dispose() }
    } finally { $hash.Dispose() }
}

# Typed reason from the error category, exception types and HRESULT only. Exception
# message text is never inspected and never copied into a report.
function Get-FastLlmBenchmarkErrorReason {
    param($ErrorRecord)
    $ex = $ErrorRecord
    if ($ErrorRecord -is [Management.Automation.ErrorRecord]) {
        $category = [string]$ErrorRecord.CategoryInfo.Category
        if ($category -eq 'PermissionDenied') { return 'access-denied' }
        if ($category -eq 'OperationTimeout') { return 'timeout' }
        if ($category -eq 'ObjectNotFound') { return 'not-found' }
        $ex = $ErrorRecord.Exception
    }
    $depth = 0
    while ($null -ne $ex -and $depth -lt 6) {
        if ($ex -is [UnauthorizedAccessException] -or $ex -is [Security.SecurityException]) { return 'access-denied' }
        if ($ex -is [TimeoutException]) { return 'timeout' }
        if ($ex -is [IO.FileNotFoundException] -or $ex -is [IO.DirectoryNotFoundException]) { return 'not-found' }
        if ($ex -is [ComponentModel.Win32Exception]) {
            $code = [int]$ex.NativeErrorCode
            if ($code -eq 5) { return 'access-denied' }
            if ($code -eq 1460) { return 'timeout' }
            if ($code -eq 2 -or $code -eq 3) { return 'not-found' }
        }
        $hresult = [int]$ex.HResult
        if ($hresult -eq -2147024891) { return 'access-denied' }
        if ($hresult -eq -2147023436) { return 'timeout' }
        if ($hresult -eq -2147024894 -or $hresult -eq -2147024893) { return 'not-found' }
        $ex = $ex.InnerException
        $depth++
    }
    return 'other'
}

function New-FastLlmBenchmarkField {
    param([string]$Status, $Value = $null, $Reason = $null)
    return [ordered]@{ status = $Status; reason = $Reason; value = $Value }
}

function New-FastLlmBenchmarkRefusedField {
    param($ErrorRecord)
    return (New-FastLlmBenchmarkField 'refused' $null (Get-FastLlmBenchmarkErrorReason $ErrorRecord))
}

function Format-FastLlmBenchmarkUtc {
    param([DateTime]$Value)
    return $Value.ToUniversalTime().ToString('o')
}

# Hard failures raised by this producer carry a typed reason in Exception.Data. The message is
# for the caller only; reports record the typed reason, never message text.
function New-FastLlmBenchmarkFailure {
    param([string]$Reason, [string]$Message, [string[]]$Paths = @())
    $exception = New-Object InvalidOperationException($Message)
    $exception.Data['fastllmFailureReason'] = $Reason
    # Fixed relative input paths only (producer strings, never exception text); they make an input failure traceable.
    if (@($Paths).Count -gt 0) { $exception.Data['fastllmFailurePaths'] = (@($Paths) -join '|') }
    return $exception
}

function Get-FastLlmBenchmarkFailureData {
    param($ErrorRecord, [string]$Key)
    $ex = $ErrorRecord
    if ($ErrorRecord -is [Management.Automation.ErrorRecord]) { $ex = $ErrorRecord.Exception }
    $depth = 0
    while ($null -ne $ex -and $depth -lt 6) {
        if ($null -ne $ex.Data -and $ex.Data.Contains($Key)) { return [string]$ex.Data[$Key] }
        $ex = $ex.InnerException
        $depth++
    }
    return $null
}

# Input paths recorded with a typed failure. Only entries of the fixed input list can ever be returned.
function Get-FastLlmBenchmarkFailurePaths {
    param($ErrorRecord)
    $text = Get-FastLlmBenchmarkFailureData $ErrorRecord 'fastllmFailurePaths'
    if ([string]::IsNullOrEmpty($text)) { return @() }
    return @($text.Split('|') | Where-Object { $script:FastLlmBenchmarkInputRelativePaths -ccontains $_ })
}

# Host capture changes recorded with a typed failure: field and typed reason, both from closed sets.
function Get-FastLlmBenchmarkFailureHostChanges {
    param($ErrorRecord)
    $text = Get-FastLlmBenchmarkFailureData $ErrorRecord 'fastllmHostCaptureChanges'
    if ([string]::IsNullOrEmpty($text)) { return @() }
    $changes = @()
    foreach ($item in $text.Split('|')) {
        $parts = $item.Split(':')
        if ($parts.Count -eq 2 -and $script:FastLlmHostStableFields -ccontains $parts[0] -and @('host-capture-changed','host-capture-status-changed') -ccontains $parts[1]) {
            $changes += [ordered]@{ field = $parts[0]; reason = $parts[1] }
        }
    }
    return @($changes)
}

function Get-FastLlmBenchmarkFailureReason {
    param($ErrorRecord)
    $ex = $ErrorRecord
    if ($ErrorRecord -is [Management.Automation.ErrorRecord]) { $ex = $ErrorRecord.Exception }
    $depth = 0
    while ($null -ne $ex -and $depth -lt 6) {
        if ($null -ne $ex.Data -and $ex.Data.Contains('fastllmFailureReason')) { return [string]$ex.Data['fastllmFailureReason'] }
        $ex = $ex.InnerException
        $depth++
    }
    return 'unclassified'
}

# Child PowerShell start info. The child sets no script-policy switch of its own: it inherits the entry policy
# (FastLLM.cmd's process-scope setting reaches it through the environment), so it never weakens AllSigned or
# Group Policy. ClearEngineEnvironment removes the same engine variables the server launch strips
# (VK_*, GGML_*, ...), so the join sees the neutral environment.
function New-FastLlmBenchmarkChildStartInfo {
    param([string]$ScriptPath, [string[]]$ScriptArguments = @(), [switch]$ClearEngineEnvironment)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = (Get-Process -Id $PID).Path
    $info.UseShellExecute = $false
    $arguments = @('-NoLogo','-NoProfile','-NonInteractive','-OutputFormat','Text','-File',$ScriptPath)
    foreach ($argument in @($ScriptArguments)) { $arguments += [string]$argument }
    $info.Arguments = Join-FastLlmProcessArguments $arguments
    if ($ClearEngineEnvironment) {
        foreach ($name in @($info.EnvironmentVariables.Keys)) {
            if (Test-FastLlmEnvironmentNameRequiresClearing -Name ([string]$name)) { $info.EnvironmentVariables.Remove([string]$name) }
        }
    }
    return $info
}

# Input file hashes, computed at the start and re-verified at the end. A missing input is reported
# in Missing (the hash is null); an unreadable one is a typed hard failure.
function Get-FastLlmBenchmarkInputHashes {
    param([string]$Root)
    $hashes = [ordered]@{}
    $missing = @()
    foreach ($relative in $script:FastLlmBenchmarkInputRelativePaths) {
        try { $hash = Get-FastLlmBenchmarkFileSha256 (Join-Path $Root $relative) }
        catch { throw (New-FastLlmBenchmarkFailure 'input-unreadable' ('A required benchmark input file could not be read: ' + $relative) @($relative)) }
        if ($null -eq $hash) { $missing += $relative }
        $hashes[$relative] = $hash
    }
    return [pscustomobject]@{ Hashes = $hashes; Missing = @($missing) }
}

# 'identity' = the collectors (tools/* except the tools/benchmark.ps1 entry script) and every C# source; 'runtime' = every other input.
function Get-FastLlmBenchmarkInputClass {
    param([string]$Relative)
    if ($Relative -ceq 'tools/benchmark.ps1') { return 'runtime' }
    if ($Relative.StartsWith('tools/', [StringComparison]::Ordinal) -or $Relative.EndsWith('.cs', [StringComparison]::Ordinal)) { return 'identity' }
    return 'runtime'
}

function Get-FastLlmBenchmarkInputClassification {
    $classes = [ordered]@{}
    foreach ($relative in $script:FastLlmBenchmarkInputRelativePaths) { $classes[$relative] = Get-FastLlmBenchmarkInputClass $relative }
    return $classes
}

function Assert-FastLlmBenchmarkInputsPresent {
    param($Inputs)
    if (@($Inputs.Missing).Count -gt 0) { throw (New-FastLlmBenchmarkFailure 'input-missing' ('A required benchmark input file is missing: ' + (@($Inputs.Missing) -join ', ')) @($Inputs.Missing)) }
}

function Assert-FastLlmBenchmarkInputsUnchanged {
    param($Start, $End)
    Assert-FastLlmBenchmarkInputsPresent $End
    $changed = @()
    foreach ($relative in $script:FastLlmBenchmarkInputRelativePaths) {
        if ([string]$Start.Hashes[$relative] -cne [string]$End.Hashes[$relative]) { $changed += $relative }
    }
    if ($changed.Count -gt 0) { throw (New-FastLlmBenchmarkFailure 'input-changed' ('A benchmark input file changed during the run: ' + ($changed -join ', ')) @($changed)) }
}

# Host capture fields that must be stable across the run. A field is compared only when both
# phases captured it. A status flip (for example captured then refused) is its own typed change,
# host-capture-status-changed; a value difference is host-capture-changed. A field that was not
# captured in either phase is not compared and is not listed as compared.
function Get-FastLlmBenchmarkHostCaptureComparison {
    param($Pre, $Post)
    $compared = @()
    $changes = @()
    foreach ($name in $script:FastLlmHostStableFields) {
        $before = Get-FastLlmBenchmarkProperty (Get-FastLlmBenchmarkProperty $Pre 'fields') $name
        $after = Get-FastLlmBenchmarkProperty (Get-FastLlmBenchmarkProperty $Post 'fields') $name
        $beforeStatus = [string](Get-FastLlmBenchmarkProperty $before 'status')
        $afterStatus = [string](Get-FastLlmBenchmarkProperty $after 'status')
        if ($beforeStatus -cne $afterStatus) { $changes += [ordered]@{ field = $name; reason = 'host-capture-status-changed' }; continue }
        if ($beforeStatus -cne 'captured') { continue }
        $beforeJson = ConvertTo-Json -InputObject (Get-FastLlmBenchmarkProperty $before 'value') -Depth 10 -Compress
        $afterJson = ConvertTo-Json -InputObject (Get-FastLlmBenchmarkProperty $after 'value') -Depth 10 -Compress
        if ($beforeJson -cne $afterJson) { $changes += [ordered]@{ field = $name; reason = 'host-capture-changed' } }
        else { $compared += $name }
    }
    return [pscustomobject]@{ ComparedFields = @($compared); Changes = @($changes) }
}

function Get-FastLlmBenchmarkHostCaptureChanges {
    param($Pre, $Post)
    $comparison = Get-FastLlmBenchmarkHostCaptureComparison $Pre $Post
    return @($comparison.Changes | ForEach-Object { $_.field })
}

function Assert-FastLlmBenchmarkHostCaptureStable {
    param($Pre, $Post)
    $comparison = Get-FastLlmBenchmarkHostCaptureComparison $Pre $Post
    $changes = @($comparison.Changes)
    if ($changes.Count -gt 0) {
        $reason = 'host-capture-status-changed'
        if (@($changes | Where-Object { $_.reason -ceq 'host-capture-changed' }).Count -gt 0) { $reason = 'host-capture-changed' }
        $failure = New-FastLlmBenchmarkFailure $reason ('Host capture changed during the benchmark: ' + (@($changes | ForEach-Object { $_.field }) -join ', '))
        $failure.Data['fastllmHostCaptureChanges'] = (@($changes | ForEach-Object { $_.field + ':' + $_.reason }) -join '|')
        throw $failure
    }
    return @($comparison.ComparedFields)
}

function ConvertFrom-FastLlmBenchmarkPowerPlanText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $match = [regex]::Match($Text, '(?i)\b([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\b')
    if (-not $match.Success) { return $null }
    $guid = $match.Groups[1].Value.ToLowerInvariant()
    $plan = 'other'
    if ($script:FastLlmPowerPlanGuids.ContainsKey($guid)) { $plan = $script:FastLlmPowerPlanGuids[$guid] }
    return [ordered]@{ guid = $guid; plan = $plan }
}

function Get-FastLlmBenchmarkPowerPlanText {
    $seam = Get-FastLlmBenchmarkSeam 'PowerPlanText'
    if ($seam) { return [string](& $seam) }
    # Bounded: a hung powercfg must not hang the benchmark. The process is killed at the deadline.
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $env:SystemRoot 'System32\powercfg.exe'
    $info.Arguments = '/getactivescheme'
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($info)
    try {
        $reader = $process.StandardOutput.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) {
            try { $process.Kill() } catch { }
            throw (New-Object TimeoutException('powercfg exceeded its deadline.'))
        }
        if (-not $reader.Wait(5000)) { throw (New-Object TimeoutException('powercfg output exceeded its deadline.')) }
        if ($process.ExitCode -ne 0) { throw (New-Object InvalidOperationException('powercfg failed.')) }
        return [string]$reader.Result.Trim()
    } finally { $process.Dispose() }
}

function ConvertTo-FastLlmBenchmarkFirmwareString {
    param($Value)
    if ($Value -isnot [string]) { return $null }
    $text = $Value.Trim()
    if ($text.Length -eq 0 -or $text.Length -gt 128 -or $text -match '[\x00-\x1f\x7f]') { return $null }
    return $text
}

function Test-FastLlmBenchmarkFirmwarePlaceholder {
    param([string]$Text)
    foreach ($candidate in $script:FastLlmFirmwarePlaceholders) {
        if ($Text -ieq $candidate) { return $true }
    }
    return $false
}

function Read-FastLlmBenchmarkBiosRegistry {
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('HARDWARE\DESCRIPTION\System\BIOS')
    if ($null -eq $key) { throw (New-Object IO.FileNotFoundException('BIOS registry key unavailable.')) }
    try {
        $values = @{}
        foreach ($name in $script:FastLlmBiosValueNames) { $values[$name] = $key.GetValue($name, $null) }
        return $values
    } finally { $key.Dispose() }
}

function Get-FastLlmBenchmarkBiosField {
    $seam = Get-FastLlmBenchmarkSeam 'BiosRegistry'
    try {
        if ($seam) { $raw = & $seam } else { $raw = Read-FastLlmBenchmarkBiosRegistry }
        if ($null -eq $raw) { throw (New-Object IO.FileNotFoundException('BIOS registry key unavailable.')) }
        $values = [ordered]@{}
        foreach ($name in $script:FastLlmBiosValueNames) {
            $text = ConvertTo-FastLlmBenchmarkFirmwareString (Get-FastLlmBenchmarkProperty $raw $name)
            if ($null -eq $text) {
                $values[$name] = [ordered]@{ status = 'unknown'; reason = 'not-reported'; value = $null; placeholder = $false }
            } else {
                # Firmware placeholder strings pass through unchanged and are only flagged.
                $values[$name] = [ordered]@{ status = 'captured'; reason = $null; value = $text; placeholder = (Test-FastLlmBenchmarkFirmwarePlaceholder $text) }
            }
        }
        return (New-FastLlmBenchmarkField 'captured' $values)
    } catch { return (New-FastLlmBenchmarkRefusedField $_) }
}

function Get-FastLlmBenchmarkSmbiosField {
    $seam = Get-FastLlmBenchmarkSeam 'Smbios'
    try {
        if ($seam) { $report = & $seam }
        else {
            if (-not ('Bitworks.FastLlm.WindowsSmbiosMemory' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'WindowsSmbiosMemory.cs') -ErrorAction Stop }
            $report = [Bitworks.FastLlm.WindowsSmbiosMemory]::Read()
        }
        $devices = @(foreach ($d in @(Get-FastLlmBenchmarkProperty $report 'Devices')) {
            if ($null -eq $d) { continue }
            [ordered]@{
                ordinal = Get-FastLlmBenchmarkProperty $d 'Ordinal'
                capacityStatus = Get-FastLlmBenchmarkProperty $d 'CapacityStatus'
                installedCapacityBytes = Get-FastLlmBenchmarkProperty $d 'InstalledCapacityBytes'
                ratedSpeedStatus = Get-FastLlmBenchmarkProperty $d 'RatedSpeedStatus'
                ratedSpeedMTps = Get-FastLlmBenchmarkProperty $d 'RatedSpeedMTps'
                configuredSpeedStatus = Get-FastLlmBenchmarkProperty $d 'ConfiguredSpeedStatus'
                configuredSpeedMTps = Get-FastLlmBenchmarkProperty $d 'ConfiguredSpeedMTps'
            }
        })
        $value = [ordered]@{
            kind = 'windows-smbios-type17-memory'
            source = 'GetSystemFirmwareTable.RSMB.Type17'
            smbiosMajor = Get-FastLlmBenchmarkProperty $report 'SmbiosMajor'
            smbiosMinor = Get-FastLlmBenchmarkProperty $report 'SmbiosMinor'
            type17Structures = Get-FastLlmBenchmarkProperty $report 'Type17Structures'
            populatedCount = Get-FastLlmBenchmarkProperty $report 'PopulatedCount'
            emptyCount = Get-FastLlmBenchmarkProperty $report 'EmptyCount'
            logicalDeviceCountExcluded = Get-FastLlmBenchmarkProperty $report 'LogicalDeviceCountExcluded'
            installedCapacityComplete = Get-FastLlmBenchmarkProperty $report 'InstalledCapacityComplete'
            knownInstalledCapacityBytes = Get-FastLlmBenchmarkProperty $report 'KnownInstalledCapacityBytes'
            devices = $devices
            capacityMeaning = 'SMBIOS reported installed capacity, not OS usable physical memory'
        }
        return (New-FastLlmBenchmarkField 'captured' $value)
    } catch { return (New-FastLlmBenchmarkRefusedField $_) }
}

function Get-FastLlmBenchmarkCpuTopologyField {
    $seam = Get-FastLlmBenchmarkSeam 'CpuTopology'
    try {
        if ($seam) { $topology = & $seam }
        else {
            if (-not ('Bitworks.FastLlm.WindowsCpuTopology' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'WindowsCpuTopology.cs') -ErrorAction Stop }
            $topology = [Bitworks.FastLlm.WindowsCpuTopology]::Read()
        }
        $value = [ordered]@{
            physicalCores = [int](Get-FastLlmBenchmarkProperty $topology 'PhysicalCores')
            packages = [int](Get-FastLlmBenchmarkProperty $topology 'Packages')
            logicalProcessors = [int](Get-FastLlmBenchmarkProperty $topology 'LogicalProcessors')
            source = 'GetLogicalProcessorInformationEx.RelationAll'
        }
        return (New-FastLlmBenchmarkField 'captured' $value)
    } catch { return (New-FastLlmBenchmarkRefusedField $_) }
}

# Replaces every raw errors[].message with a typed reason. The four CIM sections also become
# refusal records. The input object is not modified.
function ConvertTo-FastLlmBenchmarkSanitizedInventory {
    param($Inventory, [string]$Phase)
    $map = @{ pnpControllers = 'cim-video-controller'; processors = 'cim-processors'; system = 'cim-system'; os = 'cim-os' }
    $errors = @()
    $refusals = @()
    foreach ($entry in @(Get-FastLlmBenchmarkProperty $Inventory 'errors')) {
        if ($null -eq $entry) { continue }
        $section = [string](Get-FastLlmBenchmarkProperty $entry 'section')
        if ($section -notmatch '^[A-Za-z]{1,32}$') { $section = 'unknown' }
        $reason = [string](Get-FastLlmBenchmarkProperty $entry 'reason')
        if ($script:FastLlmRefusalReasons -cnotcontains $reason) { $reason = 'other' }
        $errors += [pscustomobject]@{ section = $section; reason = $reason }
        if ($map.ContainsKey($section)) { $refusals += [pscustomobject]@{ item = $map[$section]; reason = $reason; phase = $Phase } }
    }
    $copy = [ordered]@{}
    if ($Inventory -is [Collections.IDictionary]) { foreach ($key in $Inventory.Keys) { $copy[[string]$key] = $Inventory[$key] } }
    else { foreach ($property in $Inventory.PSObject.Properties) { $copy[$property.Name] = $property.Value } }
    if ($copy.Contains('errors')) { $copy['errors'] = @($errors) }
    return [pscustomobject]@{ Inventory = $copy; Refusals = @($refusals) }
}

# One phased host capture. Each field is captured, unknown or refused with a typed reason.
function Get-FastLlmBenchmarkHostCapture {
    param([ValidateSet('pre','post')][string]$Phase)
    $started = [DateTime]::UtcNow
    $inventory = $null
    $refusals = @()
    $nativeField = $null
    $cpuLabel = $null
    try {
        $seam = Get-FastLlmBenchmarkSeam 'HostInventory'
        if ($seam) { $raw = & $seam } else { $raw = Get-FastLlmWindowsInventory }
        if ($null -eq $raw) { throw (New-Object IO.FileNotFoundException('Inventory unavailable.')) }
        if ((Get-FastLlmBenchmarkProperty $raw 'applicable') -eq $false) {
            $nativeField = New-FastLlmBenchmarkField 'unknown' $null 'unsupported-platform'
            $cpuLabel = New-FastLlmBenchmarkField 'unknown' $null 'unsupported-platform'
        } else {
            $sanitized = ConvertTo-FastLlmBenchmarkSanitizedInventory $raw $Phase
            $inventory = $sanitized.Inventory
            $refusals = @($sanitized.Refusals)
            $nativeHost = Get-FastLlmBenchmarkProperty $inventory 'nativeHost'
            if ($null -eq $nativeHost) { $nativeField = New-FastLlmBenchmarkField 'unknown' $null 'not-reported' }
            elseif ((Get-FastLlmBenchmarkProperty $nativeHost 'status') -eq 'captured') { $nativeField = New-FastLlmBenchmarkField 'captured' $nativeHost }
            else { $nativeField = New-FastLlmBenchmarkField 'unknown' $nativeHost 'incomplete' }
            $names = Get-FastLlmBenchmarkProperty (Get-FastLlmBenchmarkProperty $nativeHost 'advisory') 'cpuNames'
            if ($null -ne $names -and (Get-FastLlmBenchmarkProperty $names 'status') -eq 'captured' -and (Get-FastLlmBenchmarkProperty $names 'completeScan') -eq $true) {
                $cpuLabel = New-FastLlmBenchmarkField 'captured' @(Get-FastLlmBenchmarkProperty $names 'value')
            } else { $cpuLabel = New-FastLlmBenchmarkField 'unknown' $null 'incomplete-scan' }
        }
    } catch {
        $nativeField = New-FastLlmBenchmarkRefusedField $_
        $cpuLabel = New-FastLlmBenchmarkRefusedField $_
        $inventory = $null
    }
    $topologyField = Get-FastLlmBenchmarkCpuTopologyField
    $powerText = $null
    $powerField = $null
    try {
        $powerText = Get-FastLlmBenchmarkPowerPlanText
        $parsed = ConvertFrom-FastLlmBenchmarkPowerPlanText $powerText
        if ($null -eq $parsed) { $powerField = New-FastLlmBenchmarkField 'unknown' $null 'not-reported' }
        else { $powerField = New-FastLlmBenchmarkField 'captured' $parsed }
    } catch {
        $powerField = New-FastLlmBenchmarkRefusedField $_
        $powerText = $null
    }
    $smbiosField = Get-FastLlmBenchmarkSmbiosField
    $biosField = Get-FastLlmBenchmarkBiosField
    $ended = [DateTime]::UtcNow
    return [pscustomobject]@{
        Capture = [ordered]@{
            phase = $Phase
            startUtc = (Format-FastLlmBenchmarkUtc $started)
            endUtc = (Format-FastLlmBenchmarkUtc $ended)
            fields = [ordered]@{
                nativeHost = $nativeField
                cpuLabel = $cpuLabel
                cpuTopology = $topologyField
                powerPlan = $powerField
                smbiosMemory = $smbiosField
                boardBios = $biosField
            }
        }
        Inventory = $inventory
        PowerPlanText = $powerText
        Refusals = @($refusals)
    }
}

# ---------------------------------------------------------------------------
# Selected-device identity binding (pure decision logic over probe rows).
# ---------------------------------------------------------------------------

function ConvertTo-FastLlmBenchmarkLuidHex {
    param($Low, $High)
    $lowPart = [long]$Low -band 4294967295
    $highPart = [long]$High -band 4294967295
    return ('{0:x8}{1:x8}' -f $highPart, $lowPart)
}

function Get-FastLlmBenchmarkAdlxValue {
    param($Record, [string]$Name)
    $field = Get-FastLlmBenchmarkProperty $Record $Name
    if ($null -eq $field) { return $null }
    if ((Get-FastLlmBenchmarkProperty $field 'status') -ne 'available') { return $null }
    return (Get-FastLlmBenchmarkProperty $field 'value')
}

function ConvertFrom-FastLlmBenchmarkLocation {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text) -or $Text.Length -gt 128) { return $null }
    if ($Text -cmatch '^PCI segment ([0-9]{1,5}) bus ([0-9]{1,3}), device ([0-9]{1,2}), function ([0-9])$') {
        return [pscustomobject]@{ segmentExplicit = $true; segment = [int]$Matches[1]; bus = [int]$Matches[2]; device = [int]$Matches[3]; function = [int]$Matches[4] }
    }
    if ($Text -cmatch '^PCI bus ([0-9]{1,3}), device ([0-9]{1,2}), function ([0-9])$') {
        return [pscustomobject]@{ segmentExplicit = $false; segment = 0; bus = [int]$Matches[1]; device = [int]$Matches[2]; function = [int]$Matches[3] }
    }
    return $null
}

function Get-FastLlmBenchmarkPciIdFromInstanceId {
    param([string]$InstanceId)
    if ($InstanceId -match '^PCI\\(VEN_[0-9A-Fa-f]{4}&DEV_[0-9A-Fa-f]{4}&SUBSYS_[0-9A-Fa-f]{8}&REV_[0-9A-Fa-f]{2})\\') {
        return $Matches[1].ToUpperInvariant()
    }
    return $null
}

# Decides the binding from one identity snapshot and the optional ADLX identity result.
#   Snapshot: { vulkan[], dxgi[], pnp[], joins[], vulkanError, dxgiError, setupApiError } or $null
#   Adlx:     { status, reason, records[], header } or $null
# Hard failures (throw): ADLX PNP/LUID contradiction and ADLX driver vs SetupAPI driver mismatch.
function Resolve-FastLlmBenchmarkBinding {
    param($Snapshot, $Adlx, $ProbeFailureReason = $null)
    $adlxBlock = [ordered]@{
        status = 'unknown'; reason = 'not-configured'; crossCheck = 'not-run'
        pnpMatch = $null; luidMatch = $null; driverVersionMatch = $null
        collectorSha256 = $null; adlxLibraryVersion = $null; wrapperSourceSha256 = $null
    }
    $adlxStatus = [string](Get-FastLlmBenchmarkProperty $Adlx 'status')
    if ($adlxStatus -eq 'captured') { $adlxBlock.status = 'captured'; $adlxBlock.reason = $null }
    elseif ($null -ne $Adlx) {
        $adlxReason = Get-FastLlmBenchmarkProperty $Adlx 'reason'
        if ($null -ne $adlxReason) { $adlxBlock.reason = [string]$adlxReason } else { $adlxBlock.reason = 'not-captured' }
    }
    $header = Get-FastLlmBenchmarkProperty $Adlx 'header'
    if ($null -ne $header) {
        $adlxBlock.collectorSha256 = Get-FastLlmBenchmarkProperty $header 'collectorSha256'
        $adlxBlock.adlxLibraryVersion = Get-FastLlmBenchmarkProperty $header 'adlxDriverVersion'
        $adlxBlock.wrapperSourceSha256 = Get-FastLlmBenchmarkProperty $header 'wrapperSourceSha256'
    }
    $binding = [ordered]@{
        status = 'unbound'; method = $null; reason = $null; selection = 'unbound'
        vulkanDeviceCount = 0; vulkanGpuCount = 0; amdAdapterCount = 0
        adapters = @(); adlx = $adlxBlock; snapshots = $null; qualified = $false
        probeFailureReason = $null
        collectionErrors = $null
        note = 'Separate-process join snapshots (Vulkan LUID to DXGI to D3DKMT to SetupAPI) taken before and after the timed window. Bound means exactly one non-CPU Vulkan device, it is AMD, and its join is unique; it does not prove which adapter the server process used when more than one is present.'
    }
    if ($null -eq $Snapshot) {
        $binding.reason = 'identity-probe-failed'
        $binding.probeFailureReason = $ProbeFailureReason
        return [pscustomobject]@{ Binding = $binding; Joined = $null }
    }
    # Audit flags only; they are not part of the binding fingerprint, so pre/post agreement is unchanged.
    $binding.collectionErrors = [ordered]@{
        vulkan = [bool](Get-FastLlmBenchmarkProperty $Snapshot 'vulkanError')
        dxgi = [bool](Get-FastLlmBenchmarkProperty $Snapshot 'dxgiError')
        setupApi = [bool](Get-FastLlmBenchmarkProperty $Snapshot 'setupApiError')
    }
    $vulkan = @(Get-FastLlmBenchmarkProperty $Snapshot 'vulkan' | Where-Object { $null -ne $_ })
    $binding.vulkanDeviceCount = $vulkan.Count
    $amd = @($vulkan | Where-Object {
        [uint32](Get-FastLlmBenchmarkProperty $_ 'vendorId') -eq 4098 -and
        ([int]$(if ($null -ne (Get-FastLlmBenchmarkProperty $_ 'deviceType')) { Get-FastLlmBenchmarkProperty $_ 'deviceType' } else { 2 })) -ne 4 })
    $binding.amdAdapterCount = $amd.Count
    $gpus = @($vulkan | Where-Object { ([int]$(if ($null -ne (Get-FastLlmBenchmarkProperty $_ 'deviceType')) { Get-FastLlmBenchmarkProperty $_ 'deviceType' } else { 2 })) -ne 4 })
    $binding.vulkanGpuCount = $gpus.Count
    # Any Vulkan enumeration error leaves the device set untrustworthy (a partial list can hide a
    # second adapter), so it is never bound, whatever the visible devices look like.
    if ([bool](Get-FastLlmBenchmarkProperty $Snapshot 'vulkanError')) {
        $binding.reason = 'vulkan-enumeration-failed'
        return [pscustomobject]@{ Binding = $binding; Joined = $null }
    }
    if ($amd.Count -eq 0) {
        $binding.reason = 'no-amd-adapter'
        return [pscustomobject]@{ Binding = $binding; Joined = $null }
    }
    $joins = @(Get-FastLlmBenchmarkProperty $Snapshot 'joins' | Where-Object { $null -ne $_ })
    if ($amd.Count -gt 1) {
        $binding.status = 'ambiguous'
        $binding.reason = 'multiple-amd-adapters'
        $binding.adapters = @(foreach ($device in $amd) {
            $row = @($joins | Where-Object { [int](Get-FastLlmBenchmarkProperty $_ 'vulkanIndex') -eq [int](Get-FastLlmBenchmarkProperty $device 'index') })
            $joinStatus = 'missing'
            if ($row.Count -eq 1) { $joinStatus = [string](Get-FastLlmBenchmarkProperty $row[0] 'status') }
            [ordered]@{ vulkanIndex = [int](Get-FastLlmBenchmarkProperty $device 'index'); deviceName = [string](Get-FastLlmBenchmarkProperty $device 'deviceName'); joinStatus = $joinStatus }
        })
        return [pscustomobject]@{ Binding = $binding; Joined = $null }
    }
    if ($gpus.Count -gt 1) {
        # Any second non-CPU Vulkan device, AMD or not, makes the selection ambiguous.
        $binding.status = 'ambiguous'
        $binding.reason = 'multiple-vulkan-gpus'
        $binding.adapters = @(foreach ($gpu in $gpus) {
            [ordered]@{ vulkanIndex = [int](Get-FastLlmBenchmarkProperty $gpu 'index'); deviceName = [string](Get-FastLlmBenchmarkProperty $gpu 'deviceName'); joinStatus = 'not-evaluated' }
        })
        return [pscustomobject]@{ Binding = $binding; Joined = $null }
    }
    $device = $amd[0]
    $deviceIndex = [int](Get-FastLlmBenchmarkProperty $device 'index')
    $matched = @($joins | Where-Object { [int](Get-FastLlmBenchmarkProperty $_ 'vulkanIndex') -eq $deviceIndex })
    if ($matched.Count -ne 1) {
        $binding.reason = 'join-missing'
        return [pscustomobject]@{ Binding = $binding; Joined = $null }
    }
    $join = $matched[0]
    if ([string](Get-FastLlmBenchmarkProperty $join 'status') -ne 'unique') {
        if ([string](Get-FastLlmBenchmarkProperty $join 'status') -eq 'ambiguous') { $binding.status = 'ambiguous' }
        $binding.reason = 'join-' + [string](Get-FastLlmBenchmarkProperty $join 'failedHop') + '-' + [string](Get-FastLlmBenchmarkProperty $join 'status')
        $binding.adapters = @([ordered]@{ vulkanIndex = $deviceIndex; deviceName = [string](Get-FastLlmBenchmarkProperty $device 'deviceName'); joinStatus = [string](Get-FastLlmBenchmarkProperty $join 'status'); joinReason = [string](Get-FastLlmBenchmarkProperty $join 'reason') })
        return [pscustomobject]@{ Binding = $binding; Joined = $null }
    }
    $pnpInstance = [string](Get-FastLlmBenchmarkProperty $join 'pnpInstanceId')
    $setupDriver = [string](Get-FastLlmBenchmarkProperty $join 'driverVersion')
    $dxgiRow = @(Get-FastLlmBenchmarkProperty $Snapshot 'dxgi' | Where-Object { $null -ne $_ -and [int](Get-FastLlmBenchmarkProperty $_ 'index') -eq [int](Get-FastLlmBenchmarkProperty $join 'dxgiAdapterIndex') })
    if ($dxgiRow.Count -ne 1) {
        $binding.reason = 'join-dxgi-row-missing'
        return [pscustomobject]@{ Binding = $binding; Joined = $null }
    }
    $dxgiRow = $dxgiRow[0]
    $dxgiLuid = ([string](Get-FastLlmBenchmarkProperty $dxgiRow 'adapterLuid')).ToLowerInvariant()
    $pnpRows = @(Get-FastLlmBenchmarkProperty $Snapshot 'pnp' | Where-Object { $null -ne $_ -and ([string](Get-FastLlmBenchmarkProperty $_ 'instanceId')) -ieq $pnpInstance })
    $pnpRow = $null
    if ($pnpRows.Count -eq 1) { $pnpRow = $pnpRows[0] }

    $adlxRecord = $null
    $adlxDriver = $null
    if ($adlxStatus -eq 'captured') {
        $anyPnp = $false
        $records = @()
        foreach ($record in @(Get-FastLlmBenchmarkProperty $Adlx 'records')) {
            if ($null -eq $record) { continue }
            $pnpString = Get-FastLlmBenchmarkAdlxValue $record 'pnpString'
            if ($pnpString -is [string] -and $pnpString.Length -gt 0) {
                $anyPnp = $true
                if ($pnpString -ieq $pnpInstance) { $records += $record }
            }
        }
        if (-not $anyPnp) {
            $adlxBlock.status = 'unknown'
            $adlxBlock.reason = 'adlx-pnp-unavailable'
        } elseif ($records.Count -ne 1) {
            throw (New-FastLlmBenchmarkFailure 'adlx-identity-mismatch' 'ADLX identity does not match the joined adapter.')
        } else {
            $adlxRecord = $records[0]
            $adlxBlock.pnpMatch = $true
            $luid = Get-FastLlmBenchmarkAdlxValue $adlxRecord 'luid'
            if ($null -eq $luid) { $adlxBlock.luidMatch = $null }
            else {
                $adlxLuid = ConvertTo-FastLlmBenchmarkLuidHex (Get-FastLlmBenchmarkProperty $luid 'lowPart') (Get-FastLlmBenchmarkProperty $luid 'highPart')
                if ($adlxLuid -ne $dxgiLuid) { throw (New-FastLlmBenchmarkFailure 'adlx-luid-mismatch' 'ADLX LUID does not match the joined adapter.') }
                $adlxBlock.luidMatch = $true
            }
            $adlxDriver = Get-FastLlmBenchmarkAdlxValue $adlxRecord 'amdWindowsDriverVersion'
            if ($adlxDriver -is [string] -and $adlxDriver.Trim().Length -gt 0) {
                if ($adlxDriver.Trim() -ine $setupDriver.Trim()) { throw (New-FastLlmBenchmarkFailure 'adlx-driver-mismatch' 'ADLX driver version differs from the SetupAPI driver version.') }
                $adlxBlock.driverVersionMatch = $true
            } else { $adlxDriver = $null }
            if ($adlxBlock.pnpMatch -eq $true -and $adlxBlock.luidMatch -eq $true -and $adlxBlock.driverVersionMatch -eq $true) { $adlxBlock.crossCheck = 'passed' }
            else { $adlxBlock.crossCheck = 'partial' }
        }
    }

    $amdSoftware = New-FastLlmBenchmarkField 'unknown' $null 'adlx-not-available'
    $pcieBus = New-FastLlmBenchmarkField 'unknown' $null 'adlx-not-available'
    $vbios = New-FastLlmBenchmarkField 'unknown' $null 'adlx-not-available'
    if ($null -ne $adlxRecord) {
        $version = Get-FastLlmBenchmarkAdlxValue $adlxRecord 'amdSoftwareVersion'
        if ($version -is [string] -and $version.Length -gt 0) { $amdSoftware = New-FastLlmBenchmarkField 'captured' $version }
        else { $amdSoftware = New-FastLlmBenchmarkField 'unknown' $null 'not-reported' }
        $busType = Get-FastLlmBenchmarkAdlxValue $adlxRecord 'pciBusType'
        $laneWidth = Get-FastLlmBenchmarkAdlxValue $adlxRecord 'pciBusLaneWidth'
        $typeName = [string](Get-FastLlmBenchmarkProperty $busType 'name')
        $generation = $null
        if ($typeName -match '^PCIE_([0-9]+)_[0-9]+$') { $generation = [int]$Matches[1] }
        if ($null -ne $generation -and ($laneWidth -is [int] -or $laneWidth -is [long]) -and [long]$laneWidth -gt 0) {
            $pcieBus = New-FastLlmBenchmarkField 'captured' ([ordered]@{ type = $typeName; generation = $generation; laneWidth = [int]$laneWidth; provenance = 'adlx-driver-reported' })
        } else { $pcieBus = New-FastLlmBenchmarkField 'unknown' $null 'not-reported' }
        $bios = Get-FastLlmBenchmarkAdlxValue $adlxRecord 'biosInfo'
        if ($null -ne $bios) {
            $vbios = New-FastLlmBenchmarkField 'captured' ([ordered]@{
                partNumber = Get-FastLlmBenchmarkProperty $bios 'partNumber'
                version = Get-FastLlmBenchmarkProperty $bios 'version'
                date = Get-FastLlmBenchmarkProperty $bios 'date'
            })
        } else { $vbios = New-FastLlmBenchmarkField 'unknown' $null 'not-reported' }
    }
    $kmt = Get-FastLlmBenchmarkProperty $join 'kmtAddress'
    $binding.status = 'bound'
    $binding.method = 'single-adapter-elimination+luid-chain'
    $binding.selection = 'single-amd-adapter'
    $binding.reason = $null
    $binding.adapters = @([ordered]@{
        vulkanIndex = $deviceIndex
        deviceName = [string](Get-FastLlmBenchmarkProperty $device 'deviceName')
        pnpInstanceId = $pnpInstance
        pci = [ordered]@{
            vendorId = ('{0:X4}' -f [uint32](Get-FastLlmBenchmarkProperty $dxgiRow 'vendorId'))
            deviceId = ('{0:X4}' -f [uint32](Get-FastLlmBenchmarkProperty $dxgiRow 'deviceId'))
            subsystemId = ('{0:X8}' -f [uint32](Get-FastLlmBenchmarkProperty $dxgiRow 'subSysId'))
            revision = ('{0:X2}' -f [uint32](Get-FastLlmBenchmarkProperty $dxgiRow 'revision'))
        }
        dxgiLuid = $dxgiLuid
        kmt = [ordered]@{ bus = [int](Get-FastLlmBenchmarkProperty $kmt 'bus'); device = [int](Get-FastLlmBenchmarkProperty $kmt 'device'); function = [int](Get-FastLlmBenchmarkProperty $kmt 'function'); segmentKnown = $false }
        driverVersion = $setupDriver
        driverVersionSources = [ordered]@{ setupApi = $setupDriver; adlxAmdWindowsDriverVersion = $adlxDriver; crossCheck = $adlxBlock.crossCheck }
        amdSoftwareVersion = $amdSoftware
        pcieBus = $pcieBus
        vbios = $vbios
    })
    $joined = [pscustomobject]@{ Join = $join; Vulkan = $device; Dxgi = $dxgiRow; Pnp = $pnpRow; AdlxRecord = $adlxRecord }
    return [pscustomobject]@{ Binding = $binding; Joined = $joined }
}

function ConvertTo-FastLlmBenchmarkComparableName {
    param($Text)
    if ($Text -isnot [string]) { return $null }
    $normalized = ([regex]::Replace($Text.Trim(), '\s+', ' ')).ToLowerInvariant()
    if ($normalized.Length -eq 0) { return $null }
    return $normalized
}

# Engine view versus joined device: recipe.adapters[0].name against the bound Vulkan device name
# and recipe vramMiB against the ADLX totalVramMB (relative tolerance). Only an explicit mismatch
# is a finding; missing inputs are 'not-checked' with a reason.
function Test-FastLlmBenchmarkRecipeAdapterAgreement {
    param($Recipe, $Resolved)
    $evidence = [ordered]@{
        status = 'not-checked'; reason = $null
        name = [ordered]@{ status = 'not-checked'; reason = $null; recipe = $null; recipeRaw = $null; bound = $null; boundRaw = $null }
        vram = [ordered]@{ status = 'not-checked'; reason = $null; recipeMiB = $null; adlxTotalMiB = $null; toleranceFraction = $script:FastLlmRecipeVramTolerance }
    }
    $binding = Get-FastLlmBenchmarkProperty $Resolved 'Binding'
    $joined = Get-FastLlmBenchmarkProperty $Resolved 'Joined'
    if ((Get-FastLlmBenchmarkProperty $binding 'status') -ne 'bound' -or $null -eq $joined) { $evidence.reason = 'binding-not-bound'; return $evidence }
    $adapters = @(Get-FastLlmBenchmarkProperty $Recipe 'adapters' | Where-Object { $null -ne $_ })
    if ($adapters.Count -ne 1) { $evidence.reason = 'recipe-adapter-count-not-one'; return $evidence }
    $adapter = $adapters[0]
    $recipeName = ConvertTo-FastLlmBenchmarkComparableName (Get-FastLlmBenchmarkProperty $adapter 'name')
    $boundAdapter = @(Get-FastLlmBenchmarkProperty $binding 'adapters')[0]
    $boundName = ConvertTo-FastLlmBenchmarkComparableName ([string](Get-FastLlmBenchmarkProperty $boundAdapter 'deviceName'))
    # recipe and bound are both the normalized comparison form; the raw strings are kept in recipeRaw and boundRaw.
    $evidence.name.recipe = $recipeName
    $evidence.name.recipeRaw = Get-FastLlmBenchmarkProperty $adapter 'name'
    $evidence.name.bound = $boundName
    $evidence.name.boundRaw = [string](Get-FastLlmBenchmarkProperty $boundAdapter 'deviceName')
    if ($null -eq $recipeName -or $null -eq $boundName) { $evidence.name.reason = 'name-unavailable' }
    elseif ($recipeName -ceq $boundName) { $evidence.name.status = 'agree' }
    else { $evidence.name.status = 'mismatch' }
    $recipeVram = Get-FastLlmBenchmarkProperty $adapter 'vramMiB'
    $adlxVram = $null
    if ($null -ne (Get-FastLlmBenchmarkProperty $joined 'AdlxRecord')) { $adlxVram = Get-FastLlmBenchmarkAdlxValue $joined.AdlxRecord 'totalVramMB' }
    if (($recipeVram -isnot [int] -and $recipeVram -isnot [long]) -or [long]$recipeVram -lt 1) { $evidence.vram.reason = 'recipe-vram-unavailable' }
    elseif (($adlxVram -isnot [int] -and $adlxVram -isnot [long] -and $adlxVram -isnot [double]) -or [double]$adlxVram -lt 1) { $evidence.vram.recipeMiB = [long]$recipeVram; $evidence.vram.reason = 'adlx-vram-unavailable' }
    else {
        $evidence.vram.recipeMiB = [long]$recipeVram
        $evidence.vram.adlxTotalMiB = [long][Math]::Round([double]$adlxVram)
        $relative = [Math]::Abs([double]$recipeVram - [double]$adlxVram) / [Math]::Max([double]$recipeVram, [double]$adlxVram)
        if ($relative -le $script:FastLlmRecipeVramTolerance) { $evidence.vram.status = 'agree' } else { $evidence.vram.status = 'mismatch' }
    }
    if ($evidence.name.status -eq 'mismatch') { $evidence.status = 'mismatch'; $evidence.reason = 'recipe-adapter-name-mismatch' }
    elseif ($evidence.vram.status -eq 'mismatch') { $evidence.status = 'mismatch'; $evidence.reason = 'recipe-adapter-vram-mismatch' }
    elseif ($evidence.name.status -eq 'agree' -or $evidence.vram.status -eq 'agree') { $evidence.status = 'agree' }
    else { $evidence.reason = 'inputs-unavailable' }
    return $evidence
}

# Records the cross-check on the binding. A mismatch makes the binding ambiguous (typed reason) and
# drops the joined device, so nothing is filled from, or telemetry bound to, a doubtful device.
function Set-FastLlmBenchmarkBindingRecipeCrossCheck {
    param($Resolved, $Recipe)
    $evidence = Test-FastLlmBenchmarkRecipeAdapterAgreement $Recipe $Resolved
    $binding = $Resolved.Binding
    $binding['recipeAdapterCrossCheck'] = $evidence
    if ($evidence.status -eq 'mismatch') {
        $binding.status = 'ambiguous'
        $binding.reason = $evidence.reason
        $binding.method = $null
        $binding.selection = 'unbound'
        $Resolved.Joined = $null
    }
    return $evidence
}

function Get-FastLlmBenchmarkBindingFingerprint {
    param($Binding)
    $adlx = Get-FastLlmBenchmarkProperty $Binding 'adlx'
    $subset = [ordered]@{
        status = Get-FastLlmBenchmarkProperty $Binding 'status'
        reason = Get-FastLlmBenchmarkProperty $Binding 'reason'
        amdAdapterCount = Get-FastLlmBenchmarkProperty $Binding 'amdAdapterCount'
        vulkanDeviceCount = Get-FastLlmBenchmarkProperty $Binding 'vulkanDeviceCount'
        adapters = Get-FastLlmBenchmarkProperty $Binding 'adapters'
        adlxStatus = Get-FastLlmBenchmarkProperty $adlx 'status'
        adlxCrossCheck = Get-FastLlmBenchmarkProperty $adlx 'crossCheck'
    }
    $json = ConvertTo-Json -InputObject $subset -Depth 10 -Compress
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($json)))).Replace('-','').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

# Pre and post snapshots must agree exactly; otherwise the run is a hard failure.
function Assert-FastLlmBenchmarkBindingAgreement {
    param($Pre, $Post)
    $preFingerprint = Get-FastLlmBenchmarkBindingFingerprint $Pre
    $postFingerprint = Get-FastLlmBenchmarkBindingFingerprint $Post
    if ($preFingerprint -ne $postFingerprint) { throw (New-FastLlmBenchmarkFailure 'binding-changed' 'Selected-device binding changed during the benchmark.') }
    return $preFingerprint
}

# Reviewed-gate hardware identity. Emitted only for a bound single adapter, and only when every
# field is proven. Returns { HardwareIdentity (or $null), OmitReason, Provenance }.
function New-FastLlmBenchmarkHardwareIdentity {
    param($Binding, $Joined, $PciLink, $VramMiB, $McfgSegments = $null)
    $omit = { param($reason) [pscustomobject]@{ HardwareIdentity = $null; OmitReason = $reason; Provenance = $null } }
    if ((Get-FastLlmBenchmarkProperty $Binding 'status') -ne 'bound' -or $null -eq $Joined) { return (& $omit 'binding-not-bound') }
    $adapter = @(Get-FastLlmBenchmarkProperty $Binding 'adapters')[0]
    $kmt = Get-FastLlmBenchmarkProperty $adapter 'kmt'
    # The segment is proven only by ACPI MCFG listing exactly one segment group, and it is 0.
    # A Vulkan pciBusInfo domain or an explicit SetupAPI segment is recorded as corroboration
    # and must agree with MCFG; a disagreement omits the identity.
    $mcfg = @($McfgSegments | Where-Object { $null -ne $_ })
    $mcfgZero = ($mcfg.Count -eq 1 -and [int]$mcfg[0] -eq 0)
    $conflict = $false
    $corroboration = @()
    $vulkanPci = Get-FastLlmBenchmarkProperty $Joined.Vulkan 'pciBusInfo'
    if ([bool](Get-FastLlmBenchmarkProperty $Joined.Vulkan 'pciBusInfoAdvertised') -and $null -ne $vulkanPci) {
        if ([int](Get-FastLlmBenchmarkProperty $vulkanPci 'domain') -eq 0) { $corroboration += 'vulkan-pci-bus-info-domain-0' } else { $conflict = $true }
    }
    $location = ConvertFrom-FastLlmBenchmarkLocation ([string](Get-FastLlmBenchmarkProperty $Joined.Pnp 'locationInfo'))
    if ($null -ne $location -and $location.segmentExplicit) {
        if ($location.segment -eq 0) { $corroboration += 'setupapi-location-explicit-segment-0' } else { $conflict = $true }
    }
    if (-not $mcfgZero) { return (& $omit 'pci-segment-unknown') }
    if ($conflict) { return (& $omit 'pci-segment-conflict') }
    $segmentProof = 'acpi-mcfg-single-segment-0'
    if (($VramMiB -isnot [int] -and $VramMiB -isnot [long]) -or [long]$VramMiB -lt 1) { return (& $omit 'vram-unknown') }
    $pciId = Get-FastLlmBenchmarkPciIdFromInstanceId ([string](Get-FastLlmBenchmarkProperty $adapter 'pnpInstanceId'))
    if ($null -eq $pciId) { return (& $omit 'pci-id-unknown') }
    $link = $null
    foreach ($candidate in @($PciLink)) {
        if ($null -ne $candidate -and ([string](Get-FastLlmBenchmarkProperty $candidate 'InstanceId')) -ieq [string](Get-FastLlmBenchmarkProperty $adapter 'pnpInstanceId')) { $link = $candidate; break }
    }
    $rootPort = [string](Get-FastLlmBenchmarkProperty $link 'RootPortInstanceId')
    $rootPath = [string](Get-FastLlmBenchmarkProperty $link 'RootPortLocationPath')
    if ($null -eq $link -or [string]::IsNullOrEmpty($rootPort) -or [string]::IsNullOrEmpty($rootPath)) { return (& $omit 'root-port-unknown') }
    $attachment = $null
    if ($rootPort -match '^PCI\\VEN_8086&DEV_([0-9A-Fa-f]{4})&') {
        $deviceId = $Matches[1].ToUpperInvariant()
        if ($script:FastLlmCpuRootPortDeviceIds.ContainsKey($deviceId)) { $attachment = 'cpu' }
    }
    if ($null -eq $attachment) { return (& $omit 'attachment-unclassified') }
    $pcie = Get-FastLlmBenchmarkProperty (Get-FastLlmBenchmarkProperty $adapter 'pcieBus') 'value'
    if ((Get-FastLlmBenchmarkProperty (Get-FastLlmBenchmarkProperty $adapter 'pcieBus') 'status') -ne 'captured' -or $null -eq $pcie) { return (& $omit 'link-unknown') }
    if ((Get-FastLlmBenchmarkProperty (Get-FastLlmBenchmarkProperty $Binding 'adlx') 'crossCheck') -ne 'passed') { return (& $omit 'cross-check-incomplete') }
    $identity = [ordered]@{
        adapters = @([ordered]@{
            pciId = $pciId
            vramMiB = [int]$VramMiB
            busId = ('0000:{0:x2}:{1:x2}.{2:x1}' -f [int]$kmt.bus, [int]$kmt.device, [int]$kmt.function)
            rootComplexId = $rootPath
            upstreamPort = $rootPort
            attachment = $attachment
            linkWidth = [int](Get-FastLlmBenchmarkProperty $pcie 'laneWidth')
            linkGeneration = [int](Get-FastLlmBenchmarkProperty $pcie 'generation')
        })
        topology = [ordered]@{ gpuLinks = @(); peerToPeer = $false }
    }
    $provenance = [ordered]@{
        pciId = 'setupapi-instance-id'
        vramMiB = 'engine-reported'
        busId = 'd3dkmt-adapter-address'
        pciSegment = $segmentProof
        pciSegmentCorroboration = @($corroboration)
        rootComplexId = 'setupapi-ancestor-walk'
        upstreamPort = 'setupapi-ancestor-walk'
        attachment = 'reviewed-intel-peg-root-port-table'
        linkWidth = 'adlx-driver-reported'
        linkGeneration = 'adlx-driver-reported'
        note = 'The SetupAPI endpoint link is the GPU internal link and is not used as the slot link.'
    }
    return [pscustomobject]@{ HardwareIdentity = $identity; OmitReason = $null; Provenance = $provenance }
}

# ---------------------------------------------------------------------------
# Identity probe, PCI link and ADLX collectors (each isolated so tests can replace it).
# ---------------------------------------------------------------------------

# Runs tools/collect-vulkan-luid-join.ps1 as a bounded child (deadline plus tree kill) so that
# vulkan-1.dll is never loaded into the benchmark process. Its JSON report is kept as a sidecar
# bound by SHA-256. Raw native error strings are reduced to booleans.
function Get-FastLlmBenchmarkIdentitySnapshot {
    param([string]$SidecarPath)
    $seam = Get-FastLlmBenchmarkSeam 'IdentitySnapshot'
    if ($seam) { return (& $seam $SidecarPath) }
    if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) { throw (New-Object PlatformNotSupportedException('Identity probe requires 64-bit Windows.')) }
    $tool = Join-Path (Split-Path $PSScriptRoot -Parent) 'tools/collect-vulkan-luid-join.ps1'
    if (-not [IO.File]::Exists($tool)) { throw (New-Object IO.FileNotFoundException('Join collector unavailable.')) }
    Initialize-FastLlmProcessHost
    # The join child runs with the same engine-variable clearing as the server launch (VK_*, GGML_*, ...).
    $info = New-FastLlmBenchmarkChildStartInfo $tool @('-OutputPath',$SidecarPath) -ClearEngineEnvironment
    $child = New-Object Bitworks.FastLlm.ProcessHost
    try {
        $child.Start($info)
        if (-not (Wait-FastLlmBenchmarkChild $child 120000)) { throw (New-Object TimeoutException('Identity join collector exceeded its deadline.')) }
        if ($child.Process.ExitCode -ne 0) { throw (New-Object InvalidOperationException('Identity join collector failed.')) }
    } finally { $child.Dispose() }
    $doc = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($SidecarPath)) -ErrorAction Stop
    if ($doc.schema -cne 'fastllm.vulkan-luid-join.v1' -or $doc.qualified -ne $false) { throw (New-Object InvalidOperationException('Identity join report did not match its schema.')) }
    $errors = $doc.collectionErrors
    return [pscustomobject]@{
        vulkan = @($doc.devices); dxgi = @($doc.dxgiAdapters); pnp = @($doc.setupApiDisplayDevices); kmt = @($doc.kmtAddresses); joins = @($doc.joins)
        vulkanError = [bool]$errors.vulkan; dxgiError = [bool]$errors.dxgi; setupApiError = [bool]$errors.setupApi
        sidecar = [ordered]@{ fileName = [IO.Path]::GetFileName($SidecarPath); sha256 = (Get-FastLlmBenchmarkFileSha256 $SidecarPath) }
    }
}

function Get-FastLlmBenchmarkMcfgEvidence {
    $seam = Get-FastLlmBenchmarkSeam 'Mcfg'
    try {
        if ($seam) { $segments = @(& $seam) }
        else {
            if (-not ('Bitworks.FastLlm.WindowsAcpiMcfg' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'WindowsAcpiMcfg.cs') -ErrorAction Stop }
            $segments = @([Bitworks.FastLlm.WindowsAcpiMcfg]::Read())
        }
        return [ordered]@{ source = 'acpi-mcfg'; status = 'captured'; reason = $null; segments = @($segments | ForEach-Object { [int]$_ }) }
    } catch {
        return [ordered]@{ source = 'acpi-mcfg'; status = 'unknown'; reason = (Get-FastLlmBenchmarkErrorReason $_); segments = @() }
    }
}

function Get-FastLlmBenchmarkPciLink {
    $seam = Get-FastLlmBenchmarkSeam 'PciLink'
    if ($seam) { return @(& $seam) }
    if (-not ('Bitworks.FastLlm.WindowsPciLink' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'WindowsPciLink.cs') -ErrorAction Stop }
    $devices = @([Bitworks.FastLlm.WindowsPciLink]::Collect())
    return @(foreach ($device in $devices) { ConvertTo-FastLlmBenchmarkPciLinkEntry $device })
}

# One device's link entry. The root-port link conversion is isolated per device: a conversion failure
# leaves RootPortLink null with a typed reason, and the root port identity fields survive, so the
# hardware identity never depends on the link corroboration.
function ConvertTo-FastLlmBenchmarkPciLinkEntry {
    param($Device)
    $link = $null
    $linkReason = $null
    try {
        $rootNode = $null
        foreach ($ancestor in @($Device.Ancestors)) {
            if ($null -ne $ancestor -and -not [string]::IsNullOrEmpty([string]$Device.RootPortInstanceId) -and ([string]$ancestor.InstanceId) -ieq [string]$Device.RootPortInstanceId) { $rootNode = $ancestor; break }
        }
        if ($null -eq $rootNode) { $linkReason = 'root-port-node-not-found' }
        else { $link = ConvertTo-FastLlmBenchmarkRootPortLink $rootNode }
    } catch { $link = $null; $linkReason = 'root-port-link-conversion-failed' }
    return [pscustomobject]@{
        InstanceId = $Device.Device.InstanceId
        RootPortInstanceId = $Device.RootPortInstanceId
        RootPortLocationPath = $Device.RootPortLocationPath
        RootPortLink = $link
        RootPortLinkReason = $linkReason
    }
}

# Typed reason for an unreadable SetupAPI link property, from its native error code only (never text).
# 37 is CR_NO_SUCH_VALUE (property unavailable), the value both benches return for every root-port link property.
function Get-FastLlmBenchmarkLinkPropertyReason {
    param($Property)
    if ($null -eq $Property) { return 'property-not-read' }
    if ($null -ne (Get-FastLlmBenchmarkProperty $Property 'Raw')) { return $null }
    $code = Get-FastLlmBenchmarkProperty $Property 'ErrorCode'
    if ($null -ne $code) {
        if ([long]$code -eq 37) { return 'property-unavailable' }
        if ([long]$code -eq 26) { return 'property-over-limit' }
        return 'property-read-failed'
    }
    $nativeError = Get-FastLlmBenchmarkProperty $Property 'Error'
    if ($null -ne $nativeError) {
        if ([string]$nativeError -ceq 'unexpected-property-type-or-length') { return 'unexpected-type-or-length' }
        if ([string]$nativeError -ceq 'not-read') { return 'property-not-read' }
        return 'property-read-failed'
    }
    return 'property-not-read'
}

# The root port's current and maximum link, as read by SetupAPI (corroboration only; null when not read).
function ConvertTo-FastLlmBenchmarkRootPortLink {
    param($Node)
    if ($null -eq $Node) { return $null }
    $state = {
        param($Width, $Speed)
        $widthValue = $null; $generation = $null; $speedText = $null
        $widthReason = Get-FastLlmBenchmarkLinkPropertyReason $Width
        $speedReason = Get-FastLlmBenchmarkLinkPropertyReason $Speed
        if ($null -eq $widthReason) { $widthValue = [int](Get-FastLlmBenchmarkProperty $Width 'Raw') }
        if ($null -ne $Speed) {
            if ($null -ne (Get-FastLlmBenchmarkProperty $Speed 'Generation')) { $generation = [int](Get-FastLlmBenchmarkProperty $Speed 'Generation') }
            if ($null -ne (Get-FastLlmBenchmarkProperty $Speed 'Decoded')) { $speedText = [string](Get-FastLlmBenchmarkProperty $Speed 'Decoded') }
            if ($null -eq $speedReason -and $null -eq $generation) { $speedReason = 'undecodable-value' }
        }
        return [pscustomobject]@{ width = $widthValue; generation = $generation; speed = $speedText; widthReason = $widthReason; speedReason = $speedReason }
    }
    return [pscustomobject]@{
        current = (& $state (Get-FastLlmBenchmarkProperty $Node 'CurrentLinkWidth') (Get-FastLlmBenchmarkProperty $Node 'CurrentLinkSpeed'))
        max = (& $state (Get-FastLlmBenchmarkProperty $Node 'MaxLinkWidth') (Get-FastLlmBenchmarkProperty $Node 'MaxLinkSpeed'))
    }
}

# Adds the root-port link corroboration to the pciLinkEvidence block. The ADLX-labelled link in the
# binding and hardwareIdentity is unchanged; a disagreement is recorded, never fatal.
function Add-FastLlmBenchmarkRootPortLinkEvidence {
    param($Evidence, $MatchedLink, $AdlxPcieBus)
    $Evidence['provenance'] = 'setupapi-root-port-link'
    $Evidence['current'] = $null
    $Evidence['max'] = $null
    $Evidence['linkReason'] = $null
    $comparison = [ordered]@{ status = 'not-compared'; reason = 'root-port-link-not-read'; widthMatchesCurrent = $null; generationMatchesCurrent = $null; currentLinkReason = $null }
    $link = Get-FastLlmBenchmarkProperty $MatchedLink 'RootPortLink'
    if ($null -eq $link) {
        $Evidence['linkReason'] = Get-FastLlmBenchmarkProperty $MatchedLink 'RootPortLinkReason'
        if ($null -eq $Evidence['linkReason']) { $Evidence['linkReason'] = 'root-port-link-not-read' }
    }
    if ($null -ne $link) {
        $current = Get-FastLlmBenchmarkProperty $link 'current'
        $max = Get-FastLlmBenchmarkProperty $link 'max'
        $Evidence['current'] = [ordered]@{ width = (Get-FastLlmBenchmarkProperty $current 'width'); speed = (Get-FastLlmBenchmarkProperty $current 'speed'); generation = (Get-FastLlmBenchmarkProperty $current 'generation')
            widthReason = (Get-FastLlmBenchmarkProperty $current 'widthReason'); speedReason = (Get-FastLlmBenchmarkProperty $current 'speedReason') }
        $Evidence['max'] = [ordered]@{ width = (Get-FastLlmBenchmarkProperty $max 'width'); speed = (Get-FastLlmBenchmarkProperty $max 'speed'); generation = (Get-FastLlmBenchmarkProperty $max 'generation')
            widthReason = (Get-FastLlmBenchmarkProperty $max 'widthReason'); speedReason = (Get-FastLlmBenchmarkProperty $max 'speedReason') }
        $comparison.reason = 'adlx-link-unavailable'
        $adlxWidth = Get-FastLlmBenchmarkProperty $AdlxPcieBus 'laneWidth'
        $adlxGeneration = Get-FastLlmBenchmarkProperty $AdlxPcieBus 'generation'
        $currentWidth = $Evidence['current'].width
        $currentGeneration = $Evidence['current'].generation
        if ($null -ne $adlxWidth -and $null -ne $adlxGeneration -and $null -ne $currentWidth -and $null -ne $currentGeneration) {
            $comparison.widthMatchesCurrent = ([int]$adlxWidth -eq [int]$currentWidth)
            $comparison.generationMatchesCurrent = ([int]$adlxGeneration -eq [int]$currentGeneration)
            $comparison.reason = $null
            if ($comparison.widthMatchesCurrent -and $comparison.generationMatchesCurrent) { $comparison.status = 'agree' } else { $comparison.status = 'disagree' }
        } elseif ($null -ne $adlxWidth -and $null -ne $adlxGeneration) {
            $comparison.reason = 'root-port-current-link-unreadable'
            $currentReason = $Evidence['current'].widthReason
            if ($null -eq $currentReason) { $currentReason = $Evidence['current'].speedReason }
            $comparison.currentLinkReason = $currentReason
        }
    }
    $Evidence['adlxComparison'] = $comparison
    return $Evidence
}

function Assert-FastLlmBenchmarkAdlxConfig {
    param([string]$Path, [string]$Sha256)
    $hasPath = -not [string]::IsNullOrWhiteSpace($Path)
    $hasSha = -not [string]::IsNullOrWhiteSpace($Sha256)
    if (-not $hasPath -and -not $hasSha) { return $false }
    if ($hasPath -ne $hasSha) { throw 'AdlxExecutablePath and AdlxExecutableSha256 must be supplied together.' }
    if ($Sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'AdlxExecutableSha256 must be a 64-character hexadecimal SHA-256.' }
    if (-not [IO.Path]::IsPathRooted($Path)) { throw 'AdlxExecutablePath must be an absolute file path.' }
    if (-not [IO.File]::Exists($Path)) { throw 'The ADLX executable was not found.' }
    if ((Get-FastLlmBenchmarkFileSha256 $Path) -ne $Sha256.ToLowerInvariant()) { throw 'The ADLX executable digest does not match the expected SHA-256.' }
    return $true
}

function Wait-FastLlmBenchmarkChild {
    param($Child, [int]$TimeoutMs)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.ElapsedMilliseconds -lt $TimeoutMs) {
        if ($Child.Process.HasExited -and $Child.OutputCompleted) { return $true }
        Start-Sleep -Milliseconds 50
    }
    return $false
}

function Get-FastLlmBenchmarkAdlxIdentity {
    param([string]$ExecutablePath, [string]$ExpectedSha256, [string]$OutputPath)
    $seam = Get-FastLlmBenchmarkSeam 'AdlxIdentity'
    if ($seam) { return (& $seam $ExecutablePath $ExpectedSha256 $OutputPath) }
    Initialize-FastLlmProcessHost
    $tool = Join-Path (Split-Path $PSScriptRoot -Parent) 'tools/adlx-identity-vram.ps1'
    $info = New-FastLlmBenchmarkChildStartInfo $tool @('-Mode','identity','-ExecutablePath',$ExecutablePath,'-ExpectedExecutableSha256',$ExpectedSha256,'-OutputPath',$OutputPath) -ClearEngineEnvironment
    $child = New-Object Bitworks.FastLlm.ProcessHost
    try {
        $child.Start($info)
        if (-not (Wait-FastLlmBenchmarkChild $child 120000) -or $child.Process.ExitCode -ne 0) { throw (New-FastLlmBenchmarkFailure 'adlx-identity-collection-failed' 'ADLX identity collection failed.') }
    } finally { $child.Dispose() }
    $document = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($OutputPath)) -ErrorAction Stop
    if ($document.kind -cne 'adlx-identity-report' -or $document.qualification -ne $false -or $document.footer.status -cne 'complete') {
        throw (New-FastLlmBenchmarkFailure 'adlx-identity-report-invalid' 'ADLX identity report did not match its schema.')
    }
    return [pscustomobject]@{ status = 'captured'; reason = $null; records = @($document.records); header = $document.header; path = $OutputPath }
}

function Start-FastLlmBenchmarkTelemetry {
    param([string]$ExecutablePath, [string]$ExpectedSha256, [string]$SidecarPath)
    $seam = Get-FastLlmBenchmarkSeam 'TelemetryStart'
    if ($seam) { return (& $seam $SidecarPath $script:FastLlmTelemetryIntervalMs $script:FastLlmTelemetryPlannedCount) }
    Initialize-FastLlmProcessHost
    $tool = Join-Path (Split-Path $PSScriptRoot -Parent) 'tools/adlx-identity-vram.ps1'
    $info = New-FastLlmBenchmarkChildStartInfo $tool @('-Mode','sample','-IntervalMs',[string]$script:FastLlmTelemetryIntervalMs,'-Count',[string]$script:FastLlmTelemetryPlannedCount,
        '-ExecutablePath',$ExecutablePath,'-ExpectedExecutableSha256',$ExpectedSha256,'-OutputPath',$SidecarPath) -ClearEngineEnvironment
    $child = New-Object Bitworks.FastLlm.ProcessHost
    $started = [DateTime]::UtcNow
    $readiness = [ordered]@{ polls = 0; openFailures = 0; openFailureReasons = [ordered]@{}; emptyReads = 0 }
    try {
        $child.Start($info)
        # Do not start the timed window before the first telemetry row exists.
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $ready = $false
        while ($timer.ElapsedMilliseconds -lt 30000 -and -not $ready) {
            if ($child.Process.HasExited) { throw (New-FastLlmBenchmarkFailure 'telemetry-sampler-exited' 'ADLX telemetry sampler exited before sampling.') }
            if ([IO.File]::Exists($SidecarPath)) {
                $stream = $null
                $readiness.polls++
                try {
                    $stream = [IO.File]::Open($SidecarPath, 'Open', 'Read', 'ReadWrite')
                    $buffer = New-Object byte[] 65536
                    $count = $stream.Read($buffer, 0, $buffer.Length)
                    if ([Text.Encoding]::UTF8.GetString($buffer, 0, $count).Contains('"kind":"adlx-sample"')) { $ready = $true } else { $readiness.emptyReads++ }
                } catch {
                    # Counted and typed, never hidden: the totals appear in the report.
                    $readiness.openFailures++
                    $reason = Get-FastLlmBenchmarkErrorReason $_
                    if ($readiness.openFailureReasons.Contains($reason)) { $readiness.openFailureReasons[$reason]++ } else { $readiness.openFailureReasons[$reason] = 1 }
                } finally { if ($null -ne $stream) { $stream.Dispose() } }
            }
            if (-not $ready) { Start-Sleep -Milliseconds 100 }
        }
        if (-not $ready) { throw (New-FastLlmBenchmarkFailure 'telemetry-sampler-not-ready' ('ADLX telemetry sampler produced no readable rows within 30 seconds (open failures: {0}).' -f $readiness.openFailures)) }
    } catch { $child.Dispose(); Wait-FastLlmBenchmarkSidecarRelease $SidecarPath | Out-Null; throw }
    return [pscustomobject]@{ Host = $child; SidecarPath = $SidecarPath; StartedUtc = $started; IntervalMs = $script:FastLlmTelemetryIntervalMs; PlannedCount = $script:FastLlmTelemetryPlannedCount; Readiness = $readiness }
}

function Stop-FastLlmBenchmarkTelemetry {
    param($Handle)
    if ($null -eq $Handle) { return $null }
    $seam = Get-FastLlmBenchmarkSeam 'TelemetryStop'
    if ($seam) { return (& $seam $Handle) }
    $terminated = $false
    $child = Get-FastLlmBenchmarkProperty $Handle 'Host'
    if ($null -ne $child) {
        if (-not $child.Process.HasExited) { $terminated = $true }
        $child.Dispose()
    }
    # Wait for the killed sampler to release the sidecar before it is hashed.
    Wait-FastLlmBenchmarkSidecarRelease ([string](Get-FastLlmBenchmarkProperty $Handle 'SidecarPath')) | Out-Null
    return [pscustomobject]@{ TerminatedByProducer = $terminated }
}

# Waits (bounded) until the sidecar can be opened exclusively, that is until the killed sampler has
# released it, so the file is not hashed while still held. Returns true when it is free or absent.
function Wait-FastLlmBenchmarkSidecarRelease {
    param([string]$Path, [int]$TimeoutMs = 5000)
    if ([string]::IsNullOrEmpty($Path)) { return $true }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.ElapsedMilliseconds -lt $TimeoutMs) {
        if (-not [IO.File]::Exists($Path)) { return $true }
        try { $probe = [IO.File]::Open($Path, 'Open', 'Read', 'None'); $probe.Dispose(); return $true } catch { Start-Sleep -Milliseconds 100 }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Telemetry parsing and accounting (pure).
# ---------------------------------------------------------------------------

function ConvertFrom-FastLlmBenchmarkTelemetryLine {
    param([string]$Line)
    $object = ConvertFrom-Json -InputObject $Line -ErrorAction Stop
    $kind = Get-FastLlmBenchmarkProperty $object 'kind'
    if ($kind -cne 'adlx-sample') { return $null }
    $fileTime = Get-FastLlmBenchmarkProperty $object 'utcFileTime'
    if ($null -eq $fileTime) { throw 'Telemetry row has no timestamp.' }
    $metrics = @{}
    foreach ($name in $script:FastLlmTelemetryMetricNames) {
        $field = Get-FastLlmBenchmarkProperty $object $name
        $metrics[$name] = [pscustomobject]@{ status = [string](Get-FastLlmBenchmarkProperty $field 'status'); value = (Get-FastLlmBenchmarkProperty $field 'value') }
    }
    return [pscustomobject]@{
        sample = Get-FastLlmBenchmarkProperty $object 'sample'
        gpuIndex = Get-FastLlmBenchmarkProperty $object 'gpuIndex'
        utc = [DateTime]::FromFileTimeUtc([long]$fileTime)
        pnp = [string](Get-FastLlmBenchmarkProperty (Get-FastLlmBenchmarkProperty $object 'pnpString') 'value')
        metrics = $metrics
    }
}

# Reads the JSON-lines sidecar. A header and footer are tolerated; a torn final line is
# counted rather than fatal. Returns rows plus structural counters.
function Read-FastLlmBenchmarkTelemetrySidecar {
    param([string]$Path, [int]$MaxAttempts = 10, [int]$RetryDelayMs = 200)
    # Open shared for read and write so a sampler that has not yet released the file does not
    # block the read; bounded retries, then the last failure propagates (typed by the caller).
    $lines = $null
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $stream = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
            try {
                $reader = New-Object IO.StreamReader($stream, (New-Object Text.UTF8Encoding($false)), $true)
                $collected = New-Object 'System.Collections.Generic.List[string]'
                while ($null -ne ($text = $reader.ReadLine())) { $collected.Add($text) }
                $lines = @($collected | Where-Object { $_.Length -gt 0 })
            } finally { $stream.Dispose() }
            break
        } catch {
            if ($attempt -ge $MaxAttempts) { throw }
            Start-Sleep -Milliseconds $RetryDelayMs
        }
    }
    $rows = @()
    $malformed = 0
    $torn = $false
    $footerSeen = $false
    $footerStatus = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        try {
            $row = ConvertFrom-FastLlmBenchmarkTelemetryLine $lines[$i]
            if ($null -ne $row) { $rows += $row }
            elseif ($lines[$i].Contains('"kind":"adlx-run-footer"')) {
                $footerSeen = $true
                $footerStatus = [string](Get-FastLlmBenchmarkProperty (ConvertFrom-Json -InputObject $lines[$i]) 'status')
            }
        } catch {
            if ($i -eq $lines.Count - 1) { $torn = $true } else { $malformed++ }
        }
    }
    return [pscustomobject]@{ Rows = @($rows); TornLastLine = $torn; MalformedLines = $malformed; FooterSeen = $footerSeen; FooterStatus = $footerStatus; LineCount = $lines.Count }
}

function Get-FastLlmBenchmarkMetricStatistics {
    param([object[]]$Values, [int]$UnavailableCount)
    $numbers = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ } | Sort-Object)
    if ($numbers.Count -eq 0) {
        return [ordered]@{ count = 0; minimum = $null; median = $null; maximum = $null; mean = $null; unavailableCount = $UnavailableCount }
    }
    $count = $numbers.Count
    if ($count % 2) { $median = $numbers[[int][Math]::Floor($count / 2)] } else { $median = ($numbers[$count / 2 - 1] + $numbers[$count / 2]) / 2 }
    $sum = [double]0
    foreach ($number in $numbers) { $sum += $number }
    return [ordered]@{ count = $count; minimum = $numbers[0]; median = $median; maximum = $numbers[$count - 1]; mean = ($sum / $count); unavailableCount = $UnavailableCount }
}

# Summary of the telemetry rows whose timestamps fall inside [Start, End] (inclusive).
function Get-FastLlmBenchmarkTelemetryWindowSummary {
    param([object[]]$Rows, [DateTime]$Start, [DateTime]$End)
    $inside = @($Rows | Where-Object { $_.utc -ge $Start -and $_.utc -le $End })
    $metrics = [ordered]@{}
    foreach ($name in $script:FastLlmTelemetryMetricNames) {
        $values = @()
        $unavailable = 0
        foreach ($row in $inside) {
            $metric = $row.metrics[$name]
            if ($metric.status -eq 'available' -and ($metric.value -is [int] -or $metric.value -is [long] -or $metric.value -is [double] -or $metric.value -is [decimal])) { $values += $metric.value }
            else { $unavailable++ }
        }
        $metrics[$name] = Get-FastLlmBenchmarkMetricStatistics $values $unavailable
    }
    return [ordered]@{ rowCount = $inside.Count; metrics = $metrics }
}

# Cadence, gap, drop and overlap accounting for the rows of the bound device.
function Get-FastLlmBenchmarkTelemetryAccounting {
    param([DateTime[]]$Utc, [int]$IntervalMs, [DateTime]$WindowStart, [DateTime]$WindowEnd)
    $times = @($Utc | Sort-Object)
    $windowMs = ($WindowEnd - $WindowStart).TotalMilliseconds
    $result = [ordered]@{
        sampleCount = $times.Count; nominalIntervalMs = $IntervalMs
        firstSampleUtc = $null; lastSampleUtc = $null
        observedMedianIntervalMs = $null; largestGapMs = $null; droppedCount = 0
        overlapWithTimedWindow = [ordered]@{
            windowMs = $windowMs; overlapMs = 0; coverageFraction = 0
            firstSampleAtOrBeforeWindowStart = $false; lastSampleAtOrAfterWindowEnd = $false
            rowsInsideWindow = 0; largestGapAroundWindowMs = $null
        }
    }
    if ($times.Count -eq 0) { return $result }
    $result.firstSampleUtc = Format-FastLlmBenchmarkUtc $times[0]
    $result.lastSampleUtc = Format-FastLlmBenchmarkUtc $times[$times.Count - 1]
    $gaps = @()
    $dropped = 0
    for ($i = 1; $i -lt $times.Count; $i++) {
        $gap = ($times[$i] - $times[$i - 1]).TotalMilliseconds
        $gaps += $gap
        if ($gap -gt (1.5 * $IntervalMs)) { $dropped += ([int][Math]::Round($gap / $IntervalMs) - 1) }
    }
    if ($gaps.Count -gt 0) {
        $sorted = @($gaps | Sort-Object)
        $result.largestGapMs = $sorted[$sorted.Count - 1]
        if ($sorted.Count % 2) { $result.observedMedianIntervalMs = $sorted[[int][Math]::Floor($sorted.Count / 2)] }
        else { $result.observedMedianIntervalMs = ($sorted[$sorted.Count / 2 - 1] + $sorted[$sorted.Count / 2]) / 2 }
    } else { $result.largestGapMs = 0 }
    $result.droppedCount = $dropped
    $first = $times[0]
    $last = $times[$times.Count - 1]
    $overlapStart = $first; if ($WindowStart -gt $overlapStart) { $overlapStart = $WindowStart }
    $overlapEnd = $last; if ($WindowEnd -lt $overlapEnd) { $overlapEnd = $WindowEnd }
    $overlapMs = [Math]::Max([double]0, ($overlapEnd - $overlapStart).TotalMilliseconds)
    $overlap = $result.overlapWithTimedWindow
    $overlap.overlapMs = $overlapMs
    if ($windowMs -gt 0) { $overlap.coverageFraction = [Math]::Min(1.0, $overlapMs / $windowMs) }
    $overlap.firstSampleAtOrBeforeWindowStart = ($first -le $WindowStart)
    $overlap.lastSampleAtOrAfterWindowEnd = ($last -ge $WindowEnd)
    $inside = @($times | Where-Object { $_ -ge $WindowStart -and $_ -le $WindowEnd })
    $overlap.rowsInsideWindow = $inside.Count
    $around = @()
    $before = @($times | Where-Object { $_ -lt $WindowStart } | Select-Object -Last 1)
    $after = @($times | Where-Object { $_ -gt $WindowEnd } | Select-Object -First 1)
    $around += $before
    $around += $inside
    $around += $after
    $around = @($around | Where-Object { $null -ne $_ })
    $largestAround = 0
    for ($i = 1; $i -lt $around.Count; $i++) {
        $gap = ($around[$i] - $around[$i - 1]).TotalMilliseconds
        if ($gap -gt $largestAround) { $largestAround = $gap }
    }
    if ($around.Count -gt 1) { $overlap.largestGapAroundWindowMs = $largestAround }
    return $result
}

# Assembles the report telemetry block. Rows are filtered to the bound device by PnP instance.
function New-FastLlmBenchmarkTelemetryReport {
    param($Sidecar, [string]$BoundPnpInstanceId, [int]$IntervalMs, [DateTime]$WindowStart, [DateTime]$WindowEnd,
          [object[]]$SampleWindows, [bool]$TerminatedByProducer, [string]$SidecarFileName, [string]$SidecarSha256, $SidecarBytes, $Readiness = $null)
    $rows = @($Sidecar.Rows | Where-Object { $_.pnp -ieq $BoundPnpInstanceId } | Sort-Object { $_.utc })
    $accounting = Get-FastLlmBenchmarkTelemetryAccounting ([DateTime[]]@($rows | ForEach-Object { $_.utc })) $IntervalMs $WindowStart $WindowEnd
    $overlap = $accounting.overlapWithTimedWindow
    $status = 'unknown'
    $reason = $null
    if ($rows.Count -eq 0) { $reason = 'no-rows-for-bound-device' }
    elseif ($overlap.firstSampleAtOrBeforeWindowStart -and $overlap.lastSampleAtOrAfterWindowEnd -and
            $null -ne $overlap.largestGapAroundWindowMs -and $overlap.largestGapAroundWindowMs -le (2 * $IntervalMs)) { $status = 'captured' }
    else { $status = 'partial' }
    $perSample = @(foreach ($window in $SampleWindows) {
        $summary = Get-FastLlmBenchmarkTelemetryWindowSummary $rows $window.start $window.end
        [ordered]@{
            requestedPromptTokens = $window.requestedPromptTokens; repetition = $window.repetition
            startUtc = (Format-FastLlmBenchmarkUtc $window.start); endUtc = (Format-FastLlmBenchmarkUtc $window.end)
            rowCount = $summary.rowCount; metrics = $summary.metrics
        }
    })
    $block = [ordered]@{
        status = $status; reason = $reason
        observer = 'adlx-driver-reported'
        boundDevicePnpInstanceId = $BoundPnpInstanceId
        cadenceMs = $IntervalMs
        sampleCount = $accounting.sampleCount
        firstSampleUtc = $accounting.firstSampleUtc; lastSampleUtc = $accounting.lastSampleUtc
        observedMedianIntervalMs = $accounting.observedMedianIntervalMs
        largestGapMs = $accounting.largestGapMs; droppedCount = $accounting.droppedCount
        overlapWithTimedWindow = $overlap
        tornLastLine = [bool]$Sidecar.TornLastLine; malformedLines = [int]$Sidecar.MalformedLines
        footerSeen = [bool]$Sidecar.FooterSeen; footerStatus = $Sidecar.FooterStatus; readiness = $Readiness; terminatedByProducer = $TerminatedByProducer
        sidecar = [ordered]@{ format = 'adlx-sample-jsonl'; fileName = $SidecarFileName; sha256 = $SidecarSha256; bytes = $SidecarBytes; lines = [int]$Sidecar.LineCount }
        perSample = $perSample
    }
    return $block
}

function New-FastLlmBenchmarkUnknownTelemetry {
    param([string]$Reason)
    return [ordered]@{ status = 'unknown'; reason = $Reason; observer = 'adlx-driver-reported'; sidecar = $null; perSample = @() }
}

# Telemetry block for a sidecar that could not be read. The sidecar is still bound by SHA-256 when
# the file can be hashed; otherwise the digest is null with a typed reason. No exception text.
function New-FastLlmBenchmarkTelemetryReadFailure {
    param($ErrorRecord, [string]$TelemetryPath, [bool]$TerminatedByProducer, $Readiness)
    $telemetry = New-FastLlmBenchmarkUnknownTelemetry 'sidecar-read-failed'
    $telemetry['readFailureReason'] = (Get-FastLlmBenchmarkErrorReason $ErrorRecord)
    $telemetry['terminatedByProducer'] = $TerminatedByProducer
    $telemetry['readiness'] = $Readiness
    $telemetry['sidecarFileName'] = [IO.Path]::GetFileName($TelemetryPath)
    $bound = [ordered]@{ format = 'adlx-sample-jsonl'; fileName = [IO.Path]::GetFileName($TelemetryPath); sha256 = $null; bytes = $null }
    try {
        if ([IO.File]::Exists($TelemetryPath)) {
            $bound.sha256 = Get-FastLlmBenchmarkFileSha256 $TelemetryPath
            $bound.bytes = ([IO.FileInfo]$TelemetryPath).Length
        }
    } catch { $bound['hashFailureReason'] = (Get-FastLlmBenchmarkErrorReason $_) }
    $telemetry['sidecar'] = $bound
    return $telemetry
}

# Writes the serialized result. CreateNew never replaces an existing file; if the write fails after
# this call created the file, only that file is deleted. A file that already existed is never touched.
function Write-FastLlmBenchmarkOutputFile {
    param([string]$Path, [byte[]]$Bytes)
    $file = $null
    $created = $false
    try {
        $file = [IO.File]::Open($Path, 'CreateNew', 'Write', 'None')
        $created = $true
        $fault = Get-FastLlmBenchmarkSeam 'OutputWriteFault'
        if ($fault) { & $fault }
        $file.Write($Bytes, 0, $Bytes.Length)
        $file.Flush()
    } catch {
        if ($null -ne $file) { try { $file.Dispose() } catch { }; $file = $null }
        if ($created) { try { [IO.File]::Delete($Path) } catch { } }
        throw
    } finally { if ($null -ne $file) { $file.Dispose() } }
}

# ---------------------------------------------------------------------------
# Producer entry point.
# ---------------------------------------------------------------------------

# Fills recipe.adapters[0].driverVersion only from a fully cross-checked binding. A non-null
# existing value that disagrees with the proven one is a hard failure.
function Set-FastLlmBenchmarkRecipeDriverVersion {
    param($Recipe, $Binding)
    $evidence = [ordered]@{ status = 'not-filled'; reason = $null; source = $null; value = $null }
    $adapters = @(Get-FastLlmBenchmarkProperty $Recipe 'adapters' | Where-Object { $null -ne $_ })
    $adlx = Get-FastLlmBenchmarkProperty $Binding 'adlx'
    if ((Get-FastLlmBenchmarkProperty $Binding 'status') -ne 'bound') { $evidence.reason = 'binding-not-bound'; return $evidence }
    if ((Get-FastLlmBenchmarkProperty $adlx 'crossCheck') -ne 'passed') { $evidence.reason = 'cross-check-not-passed'; return $evidence }
    if ($adapters.Count -ne 1) { $evidence.reason = 'recipe-adapter-count-not-one'; return $evidence }
    if ([int](Get-FastLlmBenchmarkProperty $Binding 'vulkanGpuCount') -ne 1) { $evidence.reason = 'vulkan-gpu-count-not-one'; return $evidence }
    $bindingAdapters = @(Get-FastLlmBenchmarkProperty $Binding 'adapters')
    $proven = [string](Get-FastLlmBenchmarkProperty $bindingAdapters[0] 'driverVersion')
    if ([string]::IsNullOrWhiteSpace($proven)) { $evidence.reason = 'driver-version-unavailable'; return $evidence }
    $adapter = $adapters[0]
    $existing = Get-FastLlmBenchmarkProperty $adapter 'driverVersion'
    if ($null -ne $existing -and -not [string]::IsNullOrWhiteSpace([string]$existing) -and ([string]$existing).Trim() -ine $proven.Trim()) {
        throw (New-FastLlmBenchmarkFailure 'recipe-driver-conflict' 'The recipe adapter driver version disagrees with the proven driver version.')
    }
    $source = 'setupapi-device-property+adlx-cross-check'
    if ($adapter -is [Collections.IDictionary]) { $adapter['driverVersion'] = $proven; $adapter['driverVersionSource'] = $source }
    else {
        foreach ($pair in @(@('driverVersion', $proven), @('driverVersionSource', $source))) {
            if ($null -ne $adapter.PSObject.Properties[$pair[0]]) { $adapter.PSObject.Properties[$pair[0]].Value = $pair[1] }
            else { Add-Member -InputObject $adapter -NotePropertyName $pair[0] -NotePropertyValue $pair[1] }
        }
    }
    $evidence.status = 'filled'; $evidence.source = $source; $evidence.value = $proven
    return $evidence
}

# Failure report. Carries a typed reason and class, never exception text; sidecars are listed with
# their digests so the preserved evidence stays bound to it.
function New-FastLlmBenchmarkFailureReport {
    param($ErrorRecord, [string]$Stage, [string]$ProducerSha, [string[]]$SidecarPaths, $Partial)
    $sidecars = @(foreach ($path in @($SidecarPaths)) {
        $exists = [IO.File]::Exists($path)
        $entry = [ordered]@{ fileName = [IO.Path]::GetFileName($path); exists = $exists; sha256 = $null; bytes = $null }
        if ($exists) {
            try { $entry.sha256 = Get-FastLlmBenchmarkFileSha256 $path; $entry.bytes = ([IO.FileInfo]$path).Length }
            catch { $entry['readFailureReason'] = Get-FastLlmBenchmarkErrorReason $_ }
        }
        $entry
    })
    return [ordered]@{
        schemaVersion = 1; resultKind = 'native-windows-api-benchmark-failure'; status = 'failed'
        reason = (Get-FastLlmBenchmarkFailureReason $ErrorRecord)
        errorClass = (Get-FastLlmBenchmarkErrorReason $ErrorRecord)
        stage = $Stage
        recordedAt = (Get-Date).ToUniversalTime().ToString('o')
        producer = [ordered]@{ name = 'fastllm-benchmark-vnext'; version = $script:FastLlmProducerVersion; sourceSha256 = $ProducerSha }
        sidecars = $sidecars
        partial = $Partial
        note = 'No benchmark result was produced. Sidecars and partial evidence are preserved. Raw exception text is never recorded.'
    }
}

function Invoke-FastLlmBenchmark {
    [CmdletBinding()]
    param([string]$InstallRoot,[string]$OutputPath,[int[]]$PromptTokens=@(512,4096),[ValidateRange(1,1024)][int]$GenerationTokens=128,[ValidateRange(5,100)][int]$Repetitions=5,
          [string]$AdlxExecutablePath,[string]$AdlxExecutableSha256)
    if($env:OS -ne 'Windows_NT'){throw 'Physical qualification runs require native Windows.'}
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run benchmarks as a standard user.'}
    if (-not $PromptTokens -or @($PromptTokens | Select-Object -Unique).Count -ne $PromptTokens.Count) { throw 'Prompt sizes must be nonempty and unique.' }
    $activeSeams=@($script:FastLlmBenchmarkSeams.Keys|ForEach-Object{[string]$_}|Sort-Object)
    if($activeSeams.Count -gt 0 -and -not $script:FastLlmBenchmarkAllowSeams){throw 'Benchmark test seams are active; refusing to produce a result.'}
    $adlxConfigured=Assert-FastLlmBenchmarkAdlxConfig $AdlxExecutablePath $AdlxExecutableSha256
    $state=Get-FastLlmStatus $InstallRoot
    if(-not $state.active -or $state.phase -ne 'ready' -or -not $state.recipe){throw 'Start a supervised FastLLM server and wait for ready before benchmarking.'}
    foreach($length in $PromptTokens){if($length -lt 16 -or $length+$GenerationTokens+8 -gt $state.recipe.contextSize){throw 'Requested prompt/output exceeds the effective context budget.'}}
    if(Test-Path -LiteralPath $OutputPath){throw 'Benchmark output already exists; choose a new result file.'}
    $benchLockPath=Join-Path (Get-FastLlmStateRoot $InstallRoot) 'benchmark.lock'
    if((Test-Path $benchLockPath) -and ((Get-Item $benchLockPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Unsafe benchmark lock.'}
    $benchLock=[IO.File]::Open($benchLockPath,'OpenOrCreate','ReadWrite','None')
    $createdFiles=New-Object 'System.Collections.Generic.List[string]'
    $telemetryHandle=$null
    $runStarted=$false
    $stage='setup'
    $preHost=$null;$postHost=$null;$preResolved=$null;$postResolved=$null;$samples=@()
    $requestFirstStart=$null;$recipeDriverEvidence=$null;$pciLinkEvidence=$null;$mcfgEvidence=$null;$telemetryReadiness=$null
    $outputFull=$null;$producerSha=$null;$failurePath=$null
    $inputsStart=$null;$inputsEnd=$null
    try{
        $outputFull=[IO.Path]::GetFullPath($OutputPath)
        $outputStem=Join-Path ([IO.Path]::GetDirectoryName($outputFull)) ([IO.Path]::GetFileNameWithoutExtension($outputFull))
        $sidecarPaths=@{
            telemetry=$outputStem+'.telemetry.jsonl'
            adlxPre=$outputStem+'.adlx-identity.json'
            adlxPost=$outputStem+'.adlx-identity-post.json'
            joinPre=$outputStem+'.luid-join-pre.json'
            joinPost=$outputStem+'.luid-join-post.json'
        }
        $failurePath=$outputStem+'.failure.json'
        foreach($sidecarPath in @($sidecarPaths.Values)+@($failurePath)){if(Test-Path -LiteralPath $sidecarPath){throw 'A benchmark sidecar file already exists; choose a new result file.'}}
        $runStarted=$true
        # The output directory exists before any check that can fail (input, tokenization, corpus), so the failure report can always be written.
        New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($outputFull)) -Force|Out-Null
        $stage='pre-timing'
        $producerPath=Join-Path $PSScriptRoot 'FastLlm.Benchmark.ps1'
        $producerSha=Get-FastLlmBenchmarkFileSha256 $producerPath
        # Input hashes are taken before any request and re-verified after the window; a missing input is a hard failure.
        $inputRoot=Split-Path $PSScriptRoot -Parent
        $inputRootSeam=Get-FastLlmBenchmarkSeam 'InputRoot'
        if($inputRootSeam){$inputRoot=[string](& $inputRootSeam)}
        $inputsStart=Get-FastLlmBenchmarkInputHashes $inputRoot
        Assert-FastLlmBenchmarkInputsPresent $inputsStart
        $baseUrl=$state.endpoint -replace '/v1$',''
        $maximumPrompt=($PromptTokens | Measure-Object -Maximum).Maximum
        $corpus=('A local inference system should produce accurate useful answers. Measure speed consistently while preserving model quality. '+[Environment]::NewLine)*([int][Math]::Ceiling($maximumPrompt/16)+2)
        $tokenized=Invoke-FastLlmHttp -BaseUrl $baseUrl -Path '/tokenize' -Body @{content=$corpus;add_special=$false} -TimeoutMs 30000
        if($tokenized.Status -ne 200){throw (New-FastLlmBenchmarkFailure 'tokenization-failed' 'Benchmark tokenization failed.')}
        $tokens=@((ConvertFrom-Json $tokenized.Body).tokens)
        if($tokens.Count -lt ($PromptTokens | Measure-Object -Maximum).Maximum){throw (New-FastLlmBenchmarkFailure 'corpus-too-short' 'Benchmark corpus did not produce enough tokens.')}
        $promptArrays=@{}
        $promptHashes=@{}
        $promptArtifacts=@(foreach($length in $PromptTokens){
            $prompt=@($tokens[0..($length-1)])
            $promptArrays[$length]=$prompt
            $promptHashes[$length]=Get-FastLlmPromptArtifactSha256 $prompt
            [pscustomobject]@{requestedPromptTokens=$length;tokenCount=$prompt.Count;sha256=$promptHashes[$length];format='fastllm-prompt-tokens-v1'}
        })

        # --- before the first timed sample: host capture, identity binding, telemetry start ---
        $preHost=Get-FastLlmBenchmarkHostCapture 'pre'
        if($preHost.Capture.fields.powerPlan.status -ne 'captured'){throw (New-FastLlmBenchmarkFailure 'power-plan-unreadable-pre' 'The active power plan could not be read before the benchmark.')}
        $adlx=$null
        if($adlxConfigured){
            $adlxIdentityPath=$sidecarPaths.adlxPre
            $createdFiles.Add($adlxIdentityPath)
            $adlx=Get-FastLlmBenchmarkAdlxIdentity $AdlxExecutablePath $AdlxExecutableSha256 $adlxIdentityPath
        }
        $preSnapshot=$null;$probeReason=$null
        $preProbeStart=[DateTime]::UtcNow
        $createdFiles.Add($sidecarPaths.joinPre)
        try{$preSnapshot=Get-FastLlmBenchmarkIdentitySnapshot $sidecarPaths.joinPre}catch{$probeReason=Get-FastLlmBenchmarkErrorReason $_}
        $preResolved=Resolve-FastLlmBenchmarkBinding $preSnapshot $adlx $probeReason
        $preProbeEnd=[DateTime]::UtcNow
        # Engine view versus joined device (name, VRAM): a mismatch makes the binding ambiguous before anything is filled from it.
        Set-FastLlmBenchmarkBindingRecipeCrossCheck $preResolved $state.recipe|Out-Null
        $preFingerprint=Get-FastLlmBenchmarkBindingFingerprint $preResolved.Binding
        $recipeDriverEvidence=Set-FastLlmBenchmarkRecipeDriverVersion $state.recipe $preResolved.Binding
        $pciLink=@()
        $pciLinkEvidence=[ordered]@{status='not-run';reason='binding-not-bound'}
        $mcfgEvidence=Get-FastLlmBenchmarkMcfgEvidence
        if($preResolved.Binding.status -eq 'bound'){
            try{
                $pciLink=@(Get-FastLlmBenchmarkPciLink)
                $matchedLink=@($pciLink|Where-Object{([string](Get-FastLlmBenchmarkProperty $_ 'InstanceId')) -ieq [string]$preResolved.Binding.adapters[0].pnpInstanceId})
                if($matchedLink.Count -eq 1 -and -not [string]::IsNullOrEmpty([string](Get-FastLlmBenchmarkProperty $matchedLink[0] 'RootPortInstanceId'))){$pciLinkEvidence=[ordered]@{status='captured';reason=$null}}
                elseif($matchedLink.Count -eq 1){$pciLinkEvidence=[ordered]@{status='unknown';reason='root-port-not-found'}}
                else{$pciLinkEvidence=[ordered]@{status='unknown';reason='device-not-found'}}
            }catch{$pciLink=@();$pciLinkEvidence=[ordered]@{status='unknown';reason=(Get-FastLlmBenchmarkErrorReason $_)}}
            # Root-port link corroboration (SetupAPI); the ADLX-labelled link is unchanged and a disagreement is only recorded.
            $matchedForLink=$null
            foreach($candidateLink in @($pciLink)){if($null -ne $candidateLink -and ([string](Get-FastLlmBenchmarkProperty $candidateLink 'InstanceId')) -ieq [string]$preResolved.Binding.adapters[0].pnpInstanceId){$matchedForLink=$candidateLink;break}}
            $pciLinkEvidence=Add-FastLlmBenchmarkRootPortLinkEvidence $pciLinkEvidence $matchedForLink (Get-FastLlmBenchmarkProperty $preResolved.Binding.adapters[0].pcieBus 'value')
        }
        $boundPnp=$null
        if($preResolved.Binding.status -eq 'bound'){$boundPnp=$preResolved.Binding.adapters[0].pnpInstanceId}
        $telemetryUnknownReason='not-configured'
        $telemetryPath=$sidecarPaths.telemetry
        $telemetryReadiness=$null
        if($adlxConfigured){
            if($null -eq $boundPnp){$telemetryUnknownReason='binding-not-bound'}
            else{
                $createdFiles.Add($telemetryPath)
                $telemetryHandle=Start-FastLlmBenchmarkTelemetry $AdlxExecutablePath $AdlxExecutableSha256 $telemetryPath
                $telemetryReadiness=Get-FastLlmBenchmarkProperty $telemetryHandle 'Readiness'
            }
        }

        $stage='timed'
        # --- timed region: sample semantics identical to c8b64fe0, plus two clock reads per request ---
        $samples=@();$evaluatedCounts=@{};$sampleWindows=@()
        $requestFirstStart=$null;$requestLastEnd=$null
        # One discarded warmup per prompt size, then interleaved randomized repetitions.
        for($round=0;$round -le $Repetitions;$round++){
            foreach($length in @($PromptTokens | Sort-Object {Get-Random})){
                $current=Get-FastLlmStatus $InstallRoot
                if(-not $current.active -or $current.phase -ne 'ready' -or $current.runId -ne $state.runId){throw 'Server identity changed during benchmark.'}
                $startedAt=[DateTime]::UtcNow
                $response=Invoke-FastLlmHttp -BaseUrl $baseUrl -Path '/completion' -TimeoutMs 180000 -Body @{
                    prompt=$promptArrays[$length];n_predict=$GenerationTokens;temperature=0;seed=42;cache_prompt=$false;ignore_eos=$true;stream=$true
                }
                $endedAt=[DateTime]::UtcNow
                if($null -eq $requestFirstStart){$requestFirstStart=$startedAt}
                $requestLastEnd=$endedAt
                $sample=ConvertFrom-FastLlmBenchmarkResponse $response $GenerationTokens
                if ($sample.promptTokens -notin @($length, ($length+1))) { throw 'Server evaluated a different prompt length (possible cache reuse or truncation).' }
                if($evaluatedCounts.ContainsKey($length)){
                    if($evaluatedCounts[$length] -ne $sample.promptTokens){throw 'Warmup and measured runs evaluated different prompt counts.'}
                }else{$evaluatedCounts[$length]=$sample.promptTokens}
                if($round -gt 0){
                    $sample|Add-Member -NotePropertyName requestedPromptTokens -NotePropertyValue $length
                    $sample|Add-Member -NotePropertyName repetition -NotePropertyValue $round
                    $sample|Add-Member -NotePropertyName promptArtifactSha256 -NotePropertyValue $promptHashes[$length]
                    $sample|Add-Member -NotePropertyName startUtc -NotePropertyValue (Format-FastLlmBenchmarkUtc $startedAt)
                    $sample|Add-Member -NotePropertyName endUtc -NotePropertyValue (Format-FastLlmBenchmarkUtc $endedAt)
                    $samples+=$sample
                    $sampleWindows+=[pscustomobject]@{requestedPromptTokens=$length;repetition=$round;start=$startedAt;end=$endedAt}
                }
                Write-Host "Prompt $length, run $round/${Repetitions}: $([Math]::Round($sample.generationTokensPerSecond,2)) generated tokens/s"
            }
        }
        $current=Get-FastLlmStatus $InstallRoot
        if(-not $current.active -or $current.phase -ne 'ready' -or $current.runId -ne $state.runId){throw (New-FastLlmBenchmarkFailure 'server-changed' 'Server changed before benchmark completion.')}
        $summary=@(foreach($length in $PromptTokens){$group=@($samples|Where-Object requestedPromptTokens -eq $length);[pscustomobject]@{promptTokens=$length;generation=Get-FastLlmStatistics $group.generationTokensPerSecond;prefill=Get-FastLlmStatistics $group.promptTokensPerSecond;firstText=Get-FastLlmStatistics $group.timeToFirstTextMs;completion=Get-FastLlmStatistics $group.completionMs}})

        $stage='post-timing'
        # --- after the last timed sample: second identity snapshot, post host capture, telemetry stop ---
        $postSnapshot=$null;$probeReason=$null
        $postProbeStart=[DateTime]::UtcNow
        $createdFiles.Add($sidecarPaths.joinPost)
        try{$postSnapshot=Get-FastLlmBenchmarkIdentitySnapshot $sidecarPaths.joinPost}catch{$probeReason=Get-FastLlmBenchmarkErrorReason $_}
        $adlxPost=$null
        if($adlxConfigured){
            # The ADLX identity is read again; a configured but failing ADLX is a hard failure.
            $createdFiles.Add($sidecarPaths.adlxPost)
            $adlxPost=Get-FastLlmBenchmarkAdlxIdentity $AdlxExecutablePath $AdlxExecutableSha256 $sidecarPaths.adlxPost
        }
        $postResolved=Resolve-FastLlmBenchmarkBinding $postSnapshot $adlxPost $probeReason
        Set-FastLlmBenchmarkBindingRecipeCrossCheck $postResolved $state.recipe|Out-Null
        $postProbeEnd=[DateTime]::UtcNow
        $postHost=Get-FastLlmBenchmarkHostCapture 'post'
        if($null -eq $postHost.PowerPlanText -or $postHost.Capture.fields.powerPlan.status -ne 'captured'){throw (New-FastLlmBenchmarkFailure 'power-plan-unreadable-post' 'The active power plan could not be read after the benchmark.')}
        $telemetryStop=$null
        if($null -ne $telemetryHandle){
            $telemetryStop=Stop-FastLlmBenchmarkTelemetry $telemetryHandle
            $telemetryHandle=$null
        }
        # The host facts that must be stable (power plan, board/BIOS, CPU topology, SMBIOS memory) must match pre and post.
        $hostStableFields=Assert-FastLlmBenchmarkHostCaptureStable $preHost.Capture $postHost.Capture
        $postFingerprint=Assert-FastLlmBenchmarkBindingAgreement $preResolved.Binding $postResolved.Binding
        $binding=$preResolved.Binding
        $binding.snapshots=[ordered]@{
            pre=[ordered]@{startUtc=(Format-FastLlmBenchmarkUtc $preProbeStart);endUtc=(Format-FastLlmBenchmarkUtc $preProbeEnd);fingerprintSha256=$preFingerprint;sidecar=(Get-FastLlmBenchmarkProperty $preSnapshot 'sidecar')}
            post=[ordered]@{startUtc=(Format-FastLlmBenchmarkUtc $postProbeStart);endUtc=(Format-FastLlmBenchmarkUtc $postProbeEnd);fingerprintSha256=$postFingerprint;sidecar=(Get-FastLlmBenchmarkProperty $postSnapshot 'sidecar')}
            agree=$true
        }
        if($adlxConfigured -and $null -ne (Get-FastLlmBenchmarkProperty $adlx 'path')){
            $binding.adlx.identityDocument=[ordered]@{fileName=[IO.Path]::GetFileName($adlxIdentityPath);sha256=(Get-FastLlmBenchmarkFileSha256 $adlxIdentityPath)}
            $binding.adlx.identityDocumentPost=[ordered]@{fileName=[IO.Path]::GetFileName($sidecarPaths.adlxPost);sha256=(Get-FastLlmBenchmarkFileSha256 $sidecarPaths.adlxPost)}
        }

        $windowStart=$sampleWindows[0].start;$windowEnd=$sampleWindows[0].end
        foreach($window in $sampleWindows){if($window.start -lt $windowStart){$windowStart=$window.start};if($window.end -gt $windowEnd){$windowEnd=$window.end}}
        $timedWindow=[ordered]@{
            firstStartUtc=(Format-FastLlmBenchmarkUtc $windowStart);lastEndUtc=(Format-FastLlmBenchmarkUtc $windowEnd)
            scope='measured-samples';sampleCount=$samples.Count
            includingWarmup=[ordered]@{firstStartUtc=(Format-FastLlmBenchmarkUtc $requestFirstStart);lastEndUtc=(Format-FastLlmBenchmarkUtc $requestLastEnd)}
        }
        if($null -ne $telemetryStop){
            # The sidecar is read shared with bounded retries. A persistent read failure is a typed
            # telemetry reason; the timed samples are already complete and are never discarded for it.
            try{
                $sidecarBytes=$null
                if([IO.File]::Exists($telemetryPath)){$sidecarBytes=([IO.FileInfo]$telemetryPath).Length}
                $sidecar=Read-FastLlmBenchmarkTelemetrySidecar $telemetryPath
                $telemetry=New-FastLlmBenchmarkTelemetryReport $sidecar $boundPnp $script:FastLlmTelemetryIntervalMs $windowStart $windowEnd $sampleWindows ([bool]$telemetryStop.TerminatedByProducer) ([IO.Path]::GetFileName($telemetryPath)) (Get-FastLlmBenchmarkFileSha256 $telemetryPath) $sidecarBytes $telemetryReadiness
            }catch{
                $telemetry=New-FastLlmBenchmarkTelemetryReadFailure $_ $telemetryPath ([bool]$telemetryStop.TerminatedByProducer) $telemetryReadiness
            }
        }else{
            $telemetry=New-FastLlmBenchmarkUnknownTelemetry $telemetryUnknownReason
        }

        $recipeAdapters=@(Get-FastLlmBenchmarkProperty $state.recipe 'adapters' | Where-Object {$null -ne $_})
        $vramMiB=$null
        if($recipeAdapters.Count -eq 1){$vramMiB=Get-FastLlmBenchmarkProperty $recipeAdapters[0] 'vramMiB'}
        $identity=New-FastLlmBenchmarkHardwareIdentity $binding $preResolved.Joined $pciLink $vramMiB @($mcfgEvidence.segments)

        $inventory=$postHost.Inventory
        $inventoryError=$null
        if($null -eq $inventory){$inventoryError='windows-inventory-unavailable'}
        # Inputs were hashed before the first request; any difference now, or a vanished file, is a hard failure.
        $inputsEnd=Get-FastLlmBenchmarkInputHashes $inputRoot
        Assert-FastLlmBenchmarkInputsUnchanged $inputsStart $inputsEnd
        $inputs=$inputsStart.Hashes
        $result=[ordered]@{
            schemaVersion=1;resultKind='native-windows-api-benchmark-not-full-qualification';recordedAt=(Get-Date).ToUniversalTime().ToString('o')
            modelId=$state.modelId;modelSha256=$state.modelSha256;engineVersion=$state.engineVersion;recipe=$state.recipe
            os=[Environment]::OSVersion.VersionString;processorCount=[Environment]::ProcessorCount;powerPlan=$postHost.PowerPlanText
            windowsInventory=$inventory;inventoryError=$inventoryError
            methodology=@{corpus='fastllm-repeated-prose-v1';sampling='greedy-seed42';prefixCache=$false;warmupPerPrompt=1;generationTokens=$GenerationTokens;repetitions=$Repetitions;concurrency=1;randomizedPromptOrder=$true;promptArtifacts=$promptArtifacts}
            canary=$state.canary;placement=$state.placement;samples=$samples;summary=$summary
            qualification=@{approved=$false;qualityEvaluation=$false;physicalResidency=$false;peakVramMeasured=$false;soak=$false;exclusiveWorkloadConfirmed=$false}
            producer=[ordered]@{name='fastllm-benchmark-vnext';version=$script:FastLlmProducerVersion;sourceSha256=$producerSha;sampleSemanticsBaselineSha256='c8b64fe0a2e78e3974b63a127da9ae385ca84b51fba69505ee323ab5d464a43b';activeSeams=@($activeSeams);inputSha256=$inputs;inputClassification=(Get-FastLlmBenchmarkInputClassification)}
            hostCapture=@($preHost.Capture,$postHost.Capture)
            hostCaptureStability=[ordered]@{status='stable';comparedFields=@($hostStableFields)}
            pciSegmentEvidence=$mcfgEvidence
            pciLinkEvidence=$pciLinkEvidence
            recipeDriverEvidence=$recipeDriverEvidence
            binding=$binding
            telemetry=$telemetry
            timedWindow=$timedWindow
            refusals=@(@($preHost.Refusals)+@($postHost.Refusals))
        }
        if($null -ne $identity.HardwareIdentity){
            $result['hardwareIdentity']=$identity.HardwareIdentity
            $result['hardwareIdentityProvenance']=$identity.Provenance
        }else{
            $result['hardwareIdentityOmitted']=[ordered]@{reason=$identity.OmitReason}
        }
        if((Get-FastLlmBenchmarkFileSha256 $producerPath) -ne $producerSha){throw (New-FastLlmBenchmarkFailure 'producer-source-changed' 'Benchmark producer source changed during the run.')}
        # Serialize first, then CreateNew (never replaces another experiment); a failed write deletes only the file this call created. No prompt/completion text is exported.
        $resultBytes=[Text.Encoding]::UTF8.GetBytes(($result|ConvertTo-Json -Depth 16))
        Write-FastLlmBenchmarkOutputFile $outputFull $resultBytes
        return $result
    }catch{
        # Evidence is preserved on failure: the sidecars stay on disk and a failure report records the
        # typed reason, the stage and the partial evidence. Raw exception text is never written.
        $failure=$_
        if($null -ne $telemetryHandle){try{Stop-FastLlmBenchmarkTelemetry $telemetryHandle|Out-Null}catch{};$telemetryHandle=$null}
        if($runStarted -and $null -ne $failurePath){
            try{
                $partial=[ordered]@{
                    completedMeasuredSamples=@($samples).Count;timedRequestsStarted=($null -ne $requestFirstStart)
                    samples=@($samples)
                    hostCapture=@(@($preHost,$postHost)|Where-Object{$null -ne $_}|ForEach-Object{$_.Capture})
                    refusals=@(@(@($preHost)+@($postHost))|Where-Object{$null -ne $_}|ForEach-Object{@($_.Refusals)})
                    preBinding=$(if($null -ne $preResolved){$preResolved.Binding}else{$null})
                    postBinding=$(if($null -ne $postResolved){$postResolved.Binding}else{$null})
                    pciSegmentEvidence=$mcfgEvidence;pciLinkEvidence=$pciLinkEvidence;recipeDriverEvidence=$recipeDriverEvidence
                    telemetryReadiness=$telemetryReadiness
                    inputEvidence=[ordered]@{
                        startSha256=$(if($null -ne $inputsStart){$inputsStart.Hashes}else{$null})
                        endSha256=$(if($null -ne $inputsEnd){$inputsEnd.Hashes}else{$null})
                        paths=@(Get-FastLlmBenchmarkFailurePaths $failure)
                    }
                    hostCaptureChanges=@(Get-FastLlmBenchmarkFailureHostChanges $failure)
                }
                $failureReport=New-FastLlmBenchmarkFailureReport $failure $stage $producerSha @($createdFiles) $partial
                # Serialize first, then open: a throw while serializing never leaves an empty failure.json.
                $serializeFault=Get-FastLlmBenchmarkSeam 'FailureSerializeFault'
                if($serializeFault){& $serializeFault}
                $failureBytes=[Text.Encoding]::UTF8.GetBytes(($failureReport|ConvertTo-Json -Depth 16))
                # Same pattern as Write-FastLlmBenchmarkOutputFile (S2): a failed write deletes only the file this call created, so no empty or partial failure.json remains.
                $failureFile=$null;$failureCreated=$false
                try{
                    $failureFile=[IO.File]::Open($failurePath,'CreateNew','Write','None')
                    $failureCreated=$true
                    $writeFault=Get-FastLlmBenchmarkSeam 'FailureWriteFault'
                    if($writeFault){& $writeFault}
                    $failureFile.Write($failureBytes,0,$failureBytes.Length)
                    $failureFile.Flush()
                }catch{
                    if($null -ne $failureFile){try{$failureFile.Dispose()}catch{};$failureFile=$null}
                    if($failureCreated){try{[IO.File]::Delete($failurePath)}catch{}}
                    throw
                }finally{if($null -ne $failureFile){$failureFile.Dispose()}}
            }catch{}
        }
        throw $failure
    }finally{
        if($null -ne $telemetryHandle){try{Stop-FastLlmBenchmarkTelemetry $telemetryHandle|Out-Null}catch{}}
        $benchLock.Dispose()
    }
}
