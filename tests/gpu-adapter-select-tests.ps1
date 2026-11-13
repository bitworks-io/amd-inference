#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$repo=Split-Path $PSScriptRoot -Parent
Add-Type -Path (Join-Path $repo 'src/WindowsGpuProcessMemory.cs') -ErrorAction Stop
. (Join-Path $repo 'src/FastLlm.SpillCheckHip.ps1')
$type=[Bitworks.FastLlm.WindowsGpuProcessMemory]
$count=0
function Check($condition,$message){if(-not $condition){throw $message};$script:count++}
function U($hex){[uint32]::Parse($hex,[System.Globalization.NumberStyles]::AllowHexSpecifier)}
$onWindows=([Environment]::OSVersion.Platform -eq 'Win32NT')
$GiB=[uint64]1073741824
$MiB=[uint64]1048576
function Obs($luid,$dedicated,$shared,$err=$null){[pscustomobject]@{Luid=$luid;DedicatedBytes=$dedicated;SharedBytes=$shared;Error=$err}}
$A='0000000000001234'
$B='0000000000005678'

# Enumeration layout: values from the public D3DKMT headers (x64).
Check ([Environment]::Is64BitProcess) 'The layout tests need a 64-bit PowerShell.'
Check ($type::EnumLayoutIsExpected()) 'D3DKMT_ENUMADAPTERS2 / D3DKMT_ADAPTERINFO Win64 layout constants are inconsistent.'
Check ($type::EnumAdapters2Size -eq 16 -and $type::OffsetEnumNumAdapters -eq 0 -and $type::OffsetEnumAdapters -eq 8) 'D3DKMT_ENUMADAPTERS2 layout differs from the header.'
Check ($type::AdapterInfoSize -eq 20 -and $type::OffsetInfoHandle -eq 0 -and $type::OffsetInfoLuidLow -eq 4 -and $type::OffsetInfoLuidHigh -eq 8 -and
       $type::OffsetInfoNumOfSources -eq 12 -and $type::OffsetInfoPrecisePresent -eq 16) 'D3DKMT_ADAPTERINFO layout differs from the header.'
Check ($type::CloseAdapterSize -eq 4 -and $type::MaxEnumAdapters -eq 64) 'D3DKMT_CLOSEADAPTER size or the adapter cap differs.'

# LUID text format: high part then low part, 16 lowercase hex digits, and it round-trips with the parser Read() uses.
Check ($type::FormatLuid([uint32]0x1234,0) -eq '0000000000001234') 'LUID format is not high-then-low 16 hex digits.'
Check ($type::FormatLuid((U 'ABCDEF01'),[int]0x00000002) -eq '00000002abcdef01') 'LUID format is not lowercase high-then-low.'
Check ($type::FormatLuid([uint32]1,-1) -eq 'ffffffff00000001') 'A negative high part was not formatted as its unsigned bits.'
foreach($pair in @(@([uint32]0,0),@([uint32]1,0),@((U 'FFFFFFFF'),2147483647),@((U '80000000'),-2147483648),@((U 'DEADBEEF'),-1))){
    $text=$type::FormatLuid([uint32]$pair[0],[int]$pair[1])
    Check ($text.Length -eq 16 -and $text -ceq $text.ToLowerInvariant()) 'Formatted LUID is not 16 lowercase hex digits.'
    [uint32]$low=0;[int]$high=0
    Check ($type::TryParseLuid($text,[ref]$low,[ref]$high)) 'The parser refused a formatted LUID.'
    Check ($low -eq [uint32]$pair[0] -and $high -eq [int]$pair[1]) 'LUID did not round-trip.'
}
[uint32]$l=0;[int]$h=0
Check (-not $type::TryParseLuid('xyz',[ref]$l,[ref]$h) -and -not $type::TryParseLuid($null,[ref]$l,[ref]$h) -and -not $type::TryParseLuid('000000000000123g',[ref]$l,[ref]$h)) 'The LUID parser accepted malformed input.'

# Enumerator never throws; off Windows it returns an error code and no LUIDs.
$result=$type::EnumerateAdapterLuids()
Check ($null -ne $result -and $null -ne $result.Luids) 'The enumerator returned no result object.'
if(-not $onWindows){
    Check ($result.Luids.Count -eq 0 -and $result.Error -eq 'not-windows') 'The enumerator did not report not-windows off Windows.'
}else{
    Check ($result.Error -or $result.Luids.Count -ge 0) 'The enumerator result is inconsistent.'
    foreach($luid in $result.Luids){Check ($luid -cmatch '^[0-9a-f]{16}$') 'Enumerated LUID is not in the Read() format.'}
}

# Selection rule.
$r=Select-FastLlmProcessAdapter -Observations @(Obs $A (15*$GiB) ([uint64](0.05*$GiB)))
Check ($r.Luid -eq $A -and $null -eq $r.Reason) 'A single dGPU holding the model was not selected.'
$r=Select-FastLlmProcessAdapter -Observations @((Obs $A (64*$MiB) 0),(Obs $B (15*$GiB) 0))
Check ($r.Luid -eq $B -and $null -eq $r.Reason) 'The iGPU/dGPU pair did not select the dGPU.'
$r=Select-FastLlmProcessAdapter -Observations @((Obs $A (64*$MiB) 0),(Obs $B ([uint64](0.5*$GiB)) (9*$GiB)))
Check ($r.Luid -eq $B -and $null -eq $r.Reason) 'A heavily spilled dGPU (0.5 GiB dedicated + 9 GiB shared) was not identified.'
$spill=Get-Content -LiteralPath (Join-Path $repo 'src/FastLlm.SpillCheck.ps1') -Raw
$m=[regex]::Match($spill,'\$script:FastLlmSpillFloorMiB\s*=\s*(\d+)')
Check $m.Success 'The spill floor constant was not found in FastLlm.SpillCheck.ps1.'
Check ((9*$GiB) -gt ([uint64]$m.Groups[1].Value*$MiB)) 'The heavy-spill shared bytes are not above the spill floor.'
$r=Select-FastLlmProcessAdapter -Observations @((Obs $A (2*$GiB) 0),(Obs $B (3*$GiB) 0))
Check ($null -eq $r.Luid -and $r.Reason -eq 'adapter-ambiguous') 'Two adapters over the minimum were not ambiguous.'
$r=Select-FastLlmProcessAdapter -Observations @((Obs $A (64*$MiB) 0),(Obs $B (512*$MiB) (100*$MiB)))
Check ($null -eq $r.Luid -and $r.Reason -eq 'adapter-not-identified') 'Adapters all under the minimum were not "not identified".'
$r=Select-FastLlmProcessAdapter -Observations @((Obs $A $null $null 'query-adapter-ntstatus-c0000001'),(Obs $B $null $null 'read-timeout'))
Check ($null -eq $r.Luid -and $r.Reason -eq 'no-readings') 'All-errored observations were not "no-readings".'
$r=Select-FastLlmProcessAdapter -Observations @()
Check ($null -eq $r.Luid -and $r.Reason -eq 'no-readings') 'An empty list was not "no-readings".'
$r=Select-FastLlmProcessAdapter -Observations $null
Check ($null -eq $r.Luid -and $r.Reason -eq 'no-readings') 'A null list was not "no-readings".'
$r=Select-FastLlmProcessAdapter -Observations @(Obs $A $GiB 0)
Check ($r.Luid -eq $A) 'Exactly 1 GiB was not selected.'
$r=Select-FastLlmProcessAdapter -Observations @(Obs $A ($GiB-1) 0)
Check ($null -eq $r.Luid -and $r.Reason -eq 'adapter-not-identified') '1 GiB minus 1 byte was selected.'
$r=Select-FastLlmProcessAdapter -Observations @(Obs $A ($GiB-1) 1)
Check ($r.Luid -eq $A) 'Dedicated + shared reaching exactly 1 GiB was not selected.'
$r=Select-FastLlmProcessAdapter -Observations @((Obs $A $null 5) ,(Obs $B (2*$GiB) 0))
Check ($r.Luid -eq $B) 'An observation with null bytes was not ignored.'
$r=Select-FastLlmProcessAdapter -Observations @((Obs $A (9*$GiB) 0 'read-timeout'),(Obs $B (2*$GiB) 0))
Check ($r.Luid -eq $B) 'An errored observation was not ignored.'
$r=Select-FastLlmProcessAdapter -Observations @((Obs $A ([uint64]::MaxValue) ([uint64]::MaxValue)),(Obs $B (2*$GiB) 0))
Check ($r.Reason -eq 'adapter-ambiguous') 'A maximal dedicated + shared sum did not count as a candidate.'
$r=Select-FastLlmProcessAdapter -Observations @(Obs $A (2*$GiB) 0) -MinTotalBytes (4*$GiB)
Check ($null -eq $r.Luid -and $r.Reason -eq 'adapter-not-identified') 'A custom minimum was ignored.'

# Source-level guarantees.
$native=Get-Content -LiteralPath (Join-Path $repo 'src/WindowsGpuProcessMemory.cs') -Raw
Check ($native.Contains('D3DKMTEnumAdapters2') -and $native.Contains('D3DKMTCloseAdapter') -and $native.Contains('DllImportSearchPath.System32')) 'Enumerator lacks the documented entry points or the system DLL restriction.'
Check (-not $native.Contains('D3DKMTOpenAdapter')) 'The enumerator must not open adapters by name.'
$select=Get-Content -LiteralPath (Join-Path $repo 'src/FastLlm.SpillCheckHip.ps1') -Raw
Check (-not ($select -match 'Add-Type|Invoke-Expression|\biex\b')) 'The pure selector must not load code or call the native layer.'
Write-Host "$count GPU adapter enumeration, LUID format and selection checks passed."
