#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$root = Split-Path $PSScriptRoot -Parent
Add-Type -Path (Join-Path $root 'src/WindowsSmbiosMemory.cs')
$script:checks = 0
function Check([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message }; $script:checks++ }
function Reject([scriptblock]$Action,[string]$Message) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Check $rejected $Message
}
function New-Type17([int]$Length=0x5c,[int]$Size=16384,[int]$Rated=5600,[int]$Configured=4800,
                    [uint32]$ExtendedSize=0,[uint32]$ExtendedRated=0,[uint32]$ExtendedConfigured=0,
                    [byte]$MemoryType=0x22,[string]$PrivateString='') {
    [byte[]]$text = @()
    if ($PrivateString) { $text = [Text.Encoding]::ASCII.GetBytes($PrivateString) }
    $bytes = New-Object byte[] ($Length + $text.Length + 2)
    $bytes[0] = 17; $bytes[1] = [byte]$Length
    [BitConverter]::GetBytes([uint16]$Size).CopyTo($bytes,0x0c)
    $bytes[0x12] = $MemoryType
    if ($Length -ge 0x17) { [BitConverter]::GetBytes([uint16]$Rated).CopyTo($bytes,0x15) }
    if ($Length -ge 0x20) { [BitConverter]::GetBytes($ExtendedSize).CopyTo($bytes,0x1c) }
    if ($Length -ge 0x22) { [BitConverter]::GetBytes([uint16]$Configured).CopyTo($bytes,0x20) }
    if ($Length -ge 0x58) { [BitConverter]::GetBytes($ExtendedRated).CopyTo($bytes,0x54) }
    if ($Length -ge 0x5c) { [BitConverter]::GetBytes($ExtendedConfigured).CopyTo($bytes,0x58) }
    if ($text.Length -gt 0) { [Array]::Copy($text,0,$bytes,$Length,$text.Length) }
    return [byte[]]$bytes
}
function New-Smbios([byte[][]]$Records,[byte]$Major=3,[byte]$Minor=3,[bool]$EndMarker=$true) {
    $table = New-Object 'System.Collections.Generic.List[byte]'
    foreach ($record in $Records) { $table.AddRange($record) }
    if ($EndMarker) { $table.AddRange([byte[]]@(127,4,0,0,0,0)) }
    $header = New-Object byte[] 8
    $header[1] = $Major; $header[2] = $Minor
    [BitConverter]::GetBytes([uint32]$table.Count).CopyTo($header,4)
    return [byte[]]($header + $table.ToArray())
}

$raw = New-Smbios -Records @((New-Type17 -PrivateString 'SECRET-SERIAL'),(New-Type17 -Size 0))
$report = [Bitworks.FastLlm.WindowsSmbiosMemory]::Parse($raw)
Check ($report.PopulatedCount -eq 1 -and $report.EmptyCount -eq 1 -and $report.Type17Structures -eq 2) 'Type 17 populated/empty counts are wrong.'
Check ($report.KnownInstalledCapacityBytes -eq 17179869184 -and $report.InstalledCapacityComplete) 'Installed DIMM capacity is wrong.'
Check ($report.Devices[0].ConfiguredSpeedMTps -eq 4800 -and $report.Devices[0].RatedSpeedMTps -eq 5600) 'Configured and rated MT/s were conflated.'
Check ($report.Devices[0].CapacityStatus -eq 'reported' -and -not $report.Qualified) 'Fixture was over-qualified.'
Check (-not (($report | ConvertTo-Json -Depth 5) -match 'SECRET-SERIAL|Raw|UUID|AssetTag|PartNumber')) 'Firmware strings or raw bytes escaped the report.'

$old = [Bitworks.FastLlm.WindowsSmbiosMemory]::Parse((New-Smbios -Records @((New-Type17 -Length 0x1b)) -Major 2 -Minor 6))
Check ($old.Devices[0].ConfiguredSpeedStatus -eq 'not-reported' -and $null -eq $old.Devices[0].ConfiguredSpeedMTps -and
       $old.Devices[0].RatedSpeedStatus -eq 'legacy-unit-ambiguous' -and $null -eq $old.Devices[0].RatedSpeedMTps) 'Legacy rated speed was mislabeled MT/s or used as configured speed.'
$oldConfigured = [Bitworks.FastLlm.WindowsSmbiosMemory]::Parse((New-Smbios -Records @((New-Type17 -Length 0x22)) -Major 2 -Minor 7))
Check ($oldConfigured.Devices[0].ConfiguredSpeedStatus -eq 'legacy-unit-ambiguous' -and
       $null -eq $oldConfigured.Devices[0].ConfiguredSpeedMTps) 'SMBIOS 2.7 configured speed was mislabeled MT/s.'
$oldThree = [Bitworks.FastLlm.WindowsSmbiosMemory]::Parse((New-Smbios -Records @((New-Type17)) -Major 3 -Minor 0))
Check ($oldThree.Devices[0].ConfiguredSpeedStatus -eq 'legacy-unit-ambiguous' -and
       $null -eq $oldThree.Devices[0].ConfiguredSpeedMTps) 'SMBIOS 3.0 speed unit ambiguity was ignored.'
$extended = [Bitworks.FastLlm.WindowsSmbiosMemory]::Parse((New-Smbios -Records @((New-Type17 -Size 0x7fff -ExtendedSize 32768 -Rated 0xffff -ExtendedRated 70000 -Configured 0xffff -ExtendedConfigured 66000))))
Check ($extended.Devices[0].InstalledCapacityBytes -eq 34359738368 -and
       $extended.Devices[0].RatedSpeedMTps -eq 70000 -and $extended.Devices[0].ConfiguredSpeedMTps -eq 66000) 'Versioned extended values were lost.'
$contradictoryExtended = [Bitworks.FastLlm.WindowsSmbiosMemory]::Parse((New-Smbios -Records @((New-Type17 -Rated 0xffff -ExtendedRated 60000 -Configured 0xffff -ExtendedConfigured 4800))))
Check ($contradictoryExtended.Devices[0].RatedSpeedStatus -eq 'extended-invalid' -and
       $null -eq $contradictoryExtended.Devices[0].RatedSpeedMTps -and
       $contradictoryExtended.Devices[0].ConfiguredSpeedStatus -eq 'extended-invalid' -and
       $null -eq $contradictoryExtended.Devices[0].ConfiguredSpeedMTps) 'Contradictory sub-65535 extended speeds were accepted.'
$unknown = [Bitworks.FastLlm.WindowsSmbiosMemory]::Parse((New-Smbios -Records @((New-Type17 -Size 0xffff -Rated 0 -Configured 0))))
Check ($unknown.PopulatedCount -eq 1 -and -not $unknown.InstalledCapacityComplete -and
       $null -eq $unknown.Devices[0].InstalledCapacityBytes -and $null -eq $unknown.Devices[0].ConfiguredSpeedMTps) 'Unknown size/speed became fabricated facts.'
$logical = [Bitworks.FastLlm.WindowsSmbiosMemory]::Parse((New-Smbios -Records @((New-Type17 -MemoryType 0x1f),(New-Type17))))
Check ($logical.LogicalDeviceCountExcluded -eq 1 -and $logical.PopulatedCount -eq 1) 'Logical Type 17 capacity was double counted.'

$badLength = [byte[]]$raw.Clone(); $badLength[4] = [byte]($badLength[4] - 1)
Reject { [Bitworks.FastLlm.WindowsSmbiosMemory]::Parse($badLength) } 'Changed header length accepted.'
$badFormat = [byte[]]$raw.Clone(); $badFormat[9] = 0xff
Reject { [Bitworks.FastLlm.WindowsSmbiosMemory]::Parse($badFormat) } 'Formatted length beyond table accepted.'
$noTerminator = [byte[]]$raw.Clone(); $noTerminator[$noTerminator.Length - 1] = 1
Reject { [Bitworks.FastLlm.WindowsSmbiosMemory]::Parse($noTerminator) } 'Unterminated structure accepted.'
Reject { [Bitworks.FastLlm.WindowsSmbiosMemory]::Parse((New-Smbios -Records @((New-Type17)) -EndMarker $false)) } 'Missing end marker accepted.'
Reject { [Bitworks.FastLlm.WindowsSmbiosMemory]::Parse((New-Smbios -Records @((New-Type17)) -Major 2 -Minor 0)) } 'Unsupported SMBIOS version accepted.'
$tooMany = @(); for ($index = 0; $index -lt 33; $index++) { $tooMany += ,(New-Type17) }
Reject { [Bitworks.FastLlm.WindowsSmbiosMemory]::Parse((New-Smbios -Records $tooMany)) } 'Type 17 output bound was bypassed.'
Check ([Bitworks.FastLlm.WindowsSmbiosMemory]::MaximumTableBytes -eq 1048576) 'Firmware table allocation cap changed.'
Write-Output "SMBIOS memory checks: $script:checks passed"
