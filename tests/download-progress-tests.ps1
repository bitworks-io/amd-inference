#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$modulePath = Join-Path $PSScriptRoot '../src/FastLlm.psm1'
Import-Module $modulePath -Force
$module = Get-Module FastLlm
$script:checks = 0
function Check([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
    Write-Host "PASS: $Message"
}

$size = [int64] 16464440224
$resume = [int64] (4GB)
$current = [int64] (5GB)
$progress = & $module {
    param($Size, $Resume, $Current)
    Get-FastLlmDownloadProgress -SizeBytes $Size -ResumeBytes $Resume -CurrentBytes $Current -PreviousBytes $Resume -ElapsedSeconds 100
} $size $resume $current
Check ($progress.bytes -eq $current -and $progress.bytes -gt [int64] [int]::MaxValue) 'progress keeps multi-GB counters as 64-bit values'
Check ($progress.newBytes -eq [int64] (1GB)) 'resume rate counts only newly transferred bytes'
Check ([Math]::Abs($progress.averageBytesPerSecond - ((1GB) / 100.0)) -lt 1) 'resume average rate uses this attempt duration'
Check ($progress.percent -gt 32 -and $progress.percent -lt 33) 'percentage includes retained partial bytes'
Check ($progress.etaSeconds -gt 0 -and -not $progress.stalled) 'established transfer gives a cautious ETA'

$early = & $module {
    param($Size, $Resume, $Current)
    Get-FastLlmDownloadProgress -SizeBytes $Size -ResumeBytes $Resume -CurrentBytes $Current -PreviousBytes $Resume -ElapsedSeconds 10
} $size $resume $current
Check ($null -eq $early.etaSeconds) 'short transfer sample has no ETA'

$stalled = & $module {
    param($Size, $Current)
    Get-FastLlmDownloadProgress -SizeBytes $Size -ResumeBytes 0 -CurrentBytes $Current -PreviousBytes $Current -ElapsedSeconds 60
} $size $current
$stallText = & $module { param($P, $S) Format-FastLlmDownloadProgress -Progress $P -SizeBytes $S } $stalled $size
Check ($stalled.stalled -and $null -eq $stalled.etaSeconds) 'stalled interval suppresses ETA'
Check ($stallText -match 'waiting for data' -and $stallText -notmatch 'remaining') 'stalled message does not imply progress'

$beforePartial = & $module {
    param($Size)
    Get-FastLlmDownloadProgress -SizeBytes $Size -ResumeBytes 0 -CurrentBytes 0 -PreviousBytes 0 -ElapsedSeconds 10
} $size
$beforePartialText = & $module { param($P, $S) Format-FastLlmDownloadProgress -Progress $P -SizeBytes $S } $beforePartial $size
Check ($beforePartial.percent -eq 0 -and $beforePartial.stalled -and $beforePartialText -match 'waiting for data') 'first report remains useful before a partial file exists'

$complete = & $module {
    param($Size, $Resume)
    Get-FastLlmDownloadProgress -SizeBytes $Size -ResumeBytes $Resume -CurrentBytes $Size -PreviousBytes $Resume -ElapsedSeconds 1000
} $size $resume
$completeText = & $module { param($P, $S) Format-FastLlmDownloadProgress -Progress $P -SizeBytes $S } $complete $size
Check ($complete.complete -and $complete.percent -eq 100 -and $null -eq $complete.etaSeconds) 'completion reports 100 percent without ETA'
Check ($completeText -match 'transfer complete' -and $completeText -notmatch 'remaining') 'completion message is final for transfer phase'

$source = [System.IO.File]::ReadAllText($modulePath)
Check ($source.Contains("Write-Host (Format-FastLlmDownloadProgress -Progress `$progress -SizeBytes `$SizeBytes)")) 'downloader emits bounded human-readable progress through host output'
Check ($source.Contains('$currentProgressBytes = [int64] $existingBytes') -and $source.Contains('-CurrentBytes $currentProgressBytes')) 'progress cadence uses zero or resumed bytes while no partial exists'
Check ($source.Contains('Transfer complete. Verifying artifact size and SHA-256.') -and $source.Contains('Verified artifact ready.')) 'downloader reports verification and ready phases'
Check ($source.Contains("'--speed-limit', '1024'") -and $source.Contains("'--continue-at', '-'") -and $source.Contains("'--max-filesize', [string] `$SizeBytes")) 'existing slow-link, resume, and transfer ceilings remain configured'

Write-Host "$script:checks download-progress checks passed. No network transfer executed."
