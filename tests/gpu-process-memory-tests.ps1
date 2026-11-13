#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$repo=Split-Path $PSScriptRoot -Parent
Add-Type -Path (Join-Path $repo 'src/WindowsGpuProcessMemory.cs') -ErrorAction Stop
$type=[Bitworks.FastLlm.WindowsGpuProcessMemory]
$count=0
function Check($condition,$message){if(-not $condition){throw $message};$script:count++}
function Thrown($block){try{& $block | Out-Null}catch{return $_.Exception};return $null}
function Inner($ex){if($ex -and $ex.InnerException){return $ex.InnerException};return $ex}
$onWindows=([Environment]::OSVersion.Platform -eq 'Win32NT')

# Layout: values taken from the public D3DKMT headers (x64, D3DKMT_QUERYSTATISTICS == 0x328 bytes).
Check ([Environment]::Is64BitProcess) 'The layout tests need a 64-bit PowerShell.'
Check ($type::LayoutIsExpected()) 'D3DKMT_QUERYSTATISTICS Win64 layout constants are inconsistent.'
Check ($type::StatisticsSize -eq 0x328) 'sizeof(D3DKMT_QUERYSTATISTICS) differs from the header value.'
Check ($type::OffsetType -eq 0 -and $type::OffsetAdapterLuid -eq 4 -and $type::OffsetProcessHandle -eq 16) 'Header offsets of Type/AdapterLuid/hProcess differ.'
Check ($type::OffsetQueryResult -eq 24 -and $type::QueryResultSize -eq 776) 'QueryResult offset or union size differs from the header.'
Check ($type::OffsetSegmentId -eq ($type::OffsetQueryResult + $type::QueryResultSize) -and $type::OffsetSegmentId -eq 800) 'SegmentId does not directly follow the QueryResult union.'
Check ($type::ResultOffsetNbSegments -eq 0 -and $type::ResultOffsetAperture -eq 40 -and $type::ResultOffsetSegmentBytesCommitted -eq 8 -and
       $type::ResultOffsetProcessSegmentBytesCommitted -eq 0) 'Result field offsets differ from the header.'
Check ($type::QueryTypeAdapter -eq 0 -and $type::QueryTypeSegment -eq 3 -and $type::QueryTypeProcessSegment -eq 4) 'D3DKMT_QUERYSTATISTICS_TYPE values differ from the header.'
Check ($type::MaxSegments -eq 32) 'D3DKMT_MAX_SEGMENT_COUNT differs from the header.'

# Split: aperture -> shared, everything else -> dedicated; overflow and mismatched input are refused, never wrapped.
[uint64]$dedicated=0;[uint64]$shared=0
Check ($type::TrySplit([bool[]]@($false,$true,$false,$true),[uint64[]]@(100,10,1000,1),[ref]$dedicated,[ref]$shared)) 'Split refused ordinary input.'
Check ($dedicated -eq 1100 -and $shared -eq 11) 'Split did not separate dedicated from shared bytes.'
Check ($type::TrySplit([bool[]]@(),[uint64[]]@(),[ref]$dedicated,[ref]$shared) -and $dedicated -eq 0 -and $shared -eq 0) 'Empty split was not zero.'
$max=[uint64]::MaxValue
Check ($type::TrySplit([bool[]]@($false,$true),[uint64[]]@($max,$max),[ref]$dedicated,[ref]$shared) -and $dedicated -eq $max -and $shared -eq $max) 'Separate maximal buckets were rejected.'
Check (-not $type::TrySplit([bool[]]@($false,$false),[uint64[]]@($max,1),[ref]$dedicated,[ref]$shared)) 'Dedicated overflow wrapped silently.'
Check (-not $type::TrySplit([bool[]]@($true,$true),[uint64[]]@($max,1),[ref]$dedicated,[ref]$shared)) 'Shared overflow wrapped silently.'
Check (-not $type::TrySplit([bool[]]@($true),[uint64[]]@(1,2),[ref]$dedicated,[ref]$shared)) 'Mismatched split input was accepted.'

# Platform and argument guards.
$self=[System.Diagnostics.Process]::GetCurrentProcess()
if(-not $onWindows){
    $ex=Inner (Thrown {$type::Read('0000000000000001',$self)})
    Check ($ex -is [System.PlatformNotSupportedException]) 'Read did not throw PlatformNotSupportedException off Windows.'
}else{
    $ex=Inner (Thrown {$type::Read('xyz',$self)})
    Check ($ex -is [System.ArgumentException]) 'Read accepted a malformed LUID.'
    $ex=Inner (Thrown {$type::Read('0000000000000001',$null)})
    Check ($ex -is [System.ArgumentNullException]) 'Read accepted a null process.'
}

# Source-level guarantees.
$native=Get-Content -LiteralPath (Join-Path $repo 'src/WindowsGpuProcessMemory.cs') -Raw
Check ($native.Contains('namespace Bitworks.FastLlm') -and $native.Contains('D3DKMTQueryStatistics') -and $native.Contains('gdi32.dll') -and
       $native.Contains('DllImportSearchPath.System32')) 'Reader lacks the documented query entry point or the system DLL restriction.'
Check (-not $native.Contains('D3DKMTOpenAdapter')) 'The statistics query must not open an adapter handle.'
Write-Host "$count GPU process-memory layout, split and guard checks passed."
