#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
$count=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:count++;Write-Host "PASS: $Message"}

$source=Join-Path $root 'src/WindowsGpuTelemetry.cs'
Add-Type -Path $source -ErrorAction Stop
$luid=$null;$physical=$null
Check ([Bitworks.FastLlm.WindowsGpuTelemetry]::TryParseInstance('pid_1234_luid_0x00000001_0x0000000a_phys_2',1234,[ref]$luid,[ref]$physical) -and
    $luid -eq '0x000000010000000A' -and $physical -eq 2) 'PDH instance binds PID and preserves WDDM LUID/physical index'
$luid=$null;$physical=$null
Check (-not [Bitworks.FastLlm.WindowsGpuTelemetry]::TryParseInstance('pid_1235_luid_0x00000001_0x0000000a_phys_2',1234,[ref]$luid,[ref]$physical)) 'another process instance cannot be attributed to the target'
$luid=$null;$physical=$null
Check (-not [Bitworks.FastLlm.WindowsGpuTelemetry]::TryParseInstance('pid_1234_luid_0x00000001_0x0000000a_phys_2_eng_0',1234,[ref]$luid,[ref]$physical)) 'malformed or engine-scoped instance is not silently counted as memory'
Check ((Get-Content -LiteralPath $source -Raw) -match 'PdhAddEnglishCounterW' -and
    (Get-Content -LiteralPath $source -Raw) -match 'MaxArrayBytes = 4 \* 1024 \* 1024') 'telemetry uses locale-independent bounded PDH counter arrays'
$nativeImports=@([Bitworks.FastLlm.WindowsGpuTelemetry].GetMethods([Reflection.BindingFlags]'NonPublic,Static') |
    Where-Object { $_.GetCustomAttributes([Runtime.InteropServices.DllImportAttribute],$false).Count -gt 0 })
Check ($nativeImports.Count -eq 6 -and @($nativeImports | Where-Object {
    $attrs=$_.GetCustomAttributes([Runtime.InteropServices.DefaultDllImportSearchPathsAttribute],$false)
    $attrs.Count -ne 1 -or $attrs[0].Paths -ne [Runtime.InteropServices.DllImportSearchPath]::System32
}).Count -eq 0) 'every native PDH and IP Helper import is restricted to System32'
Check ([Bitworks.FastLlm.WindowsGpuTelemetry]::IsUnavailableOptionalCounterStatus([Convert]::ToUInt32('800007D1',16)) -and
    [Bitworks.FastLlm.WindowsGpuTelemetry]::IsUnavailableOptionalCounterStatus([Convert]::ToUInt32('800007D5',16)) -and
    [Bitworks.FastLlm.WindowsGpuTelemetry]::IsUnavailableOptionalCounterStatus([Convert]::ToUInt32('C0000BB9',16)) -and
    -not [Bitworks.FastLlm.WindowsGpuTelemetry]::IsUnavailableOptionalCounterStatus([Convert]::ToUInt32('C0000BBD',16)) -and
    -not [Bitworks.FastLlm.WindowsGpuTelemetry]::IsUnavailableOptionalCounterStatus([Convert]::ToUInt32('C0000BBB',16))) 'only documented absent optional statuses become null, not malformed input or resource failure'
Check ([Bitworks.FastLlm.WindowsGpuTelemetry]::MatchesSupervisedProcessIdentity(1234,638000000000000000,1234,638000000000000000) -and
    -not [Bitworks.FastLlm.WindowsGpuTelemetry]::MatchesSupervisedProcessIdentity(1234,638000000000000000,1235,638000000000000000) -and
    -not [Bitworks.FastLlm.WindowsGpuTelemetry]::MatchesSupervisedProcessIdentity(1234,638000000000000000,1234,638000000000000001)) 'supervisor child binding rejects changed PID or start ticks'

function New-TcpOwnerTable([object[]]$Rows){
    $bytes=New-Object byte[] (4 + 24*$Rows.Count)
    [BitConverter]::GetBytes([uint32]$Rows.Count).CopyTo($bytes,0)
    for($i=0;$i -lt $Rows.Count;$i++){
        $offset=4+24*$i;$row=$Rows[$i]
        [BitConverter]::GetBytes([uint32]$row.state).CopyTo($bytes,$offset)
        [byte[]]$address=$row.address
        [Array]::Copy($address,0,$bytes,$offset+4,4)
        $bytes[$offset+8]=[byte]($row.port -shr 8)
        $bytes[$offset+9]=[byte]($row.port -band 255)
        [BitConverter]::GetBytes([uint32]$row.pid).CopyTo($bytes,$offset+20)
    }
    return ,$bytes
}
$loopback=[byte[]]@(127,0,0,1)
$rows=@(
    @{state=2;address=$loopback;port=8080;pid=1234},
    @{state=2;address=$loopback;port=8080;pid=1234},
    @{state=2;address=$loopback;port=8081;pid=3333},
    @{state=5;address=$loopback;port=8080;pid=4444},
    @{state=2;address=([byte[]]@(0,0,0,0));port=8080;pid=5555}
)
$owners=[Bitworks.FastLlm.WindowsGpuTelemetry]::ParseLoopbackListenerOwners((New-TcpOwnerTable $rows),8080)
Check ($owners.Count -eq 1 -and $owners[0] -eq 1234) 'TCP listener parser uses exact IPv4 loopback, LISTEN state, network-order port, and deduplicates PID'
$rows+=@{state=2;address=$loopback;port=8080;pid=2345}
$owners=[Bitworks.FastLlm.WindowsGpuTelemetry]::ParseLoopbackListenerOwners((New-TcpOwnerTable $rows),8080)
Check ($owners.Count -eq 2 -and $owners[0] -eq 1234 -and $owners[1] -eq 2345) 'ambiguous listener owners remain visible for fail-closed caller check'
$malformed=New-TcpOwnerTable $rows
[BitConverter]::GetBytes([uint32]8193).CopyTo($malformed,0)
$rejected=$false
try{[Bitworks.FastLlm.WindowsGpuTelemetry]::ParseLoopbackListenerOwners($malformed,8080)|Out-Null}catch{$rejected=$true}
Check $rejected 'TCP owner table parser rejects oversized or truncated row count'

$tool=Join-Path $root 'tools/gpu-memory-sample.ps1'
$tokens=$null;$errors=$null
[Management.Automation.Language.Parser]::ParseFile($tool,[ref]$tokens,[ref]$errors)|Out-Null
Check ($errors.Count -eq 0) 'telemetry entrypoint parses in PowerShell 5.1 syntax'
$text=Get-Content -LiteralPath $tool -Raw
Check ($text -match 'serverStartUtcTicks' -and $text -match 'StartTime\.ToUniversalTime\(\)\.Ticks' -and
    $text -match 'GetLoopbackListenerOwners' -and $text -match 'Get-FastLlmStatus' -and
    $text -match 'MatchesSupervisedProcessIdentity' -and $text -match 'predates supervisor child identity' -and
    $text -notmatch 'Get-NetTCPConnection') 'each sample requires supervisor-recorded child, native loopback listener, and active run without CIM'
Check ($text -match 'Hash\.ToLowerInvariant\(\) -cne' -and
    $text -match 'WindowsBuiltInRole\]::Administrator' -and
    $text -match "processBinding='exact supervisor-recorded child PID") 'binary digest comparison is case-correct, standard-user, and binding is explicit'
Check ($text -match 'physicalResidencyVerified=\$false' -and $text -match 'qualificationApproved=\$false' -and
    $text -match 'CreateNew' -and $text -match 'Samples \* \$IntervalSeconds -gt 3600' -and
    $text -match 'clock\.Elapsed\.TotalSeconds -gt 3600') 'report remains diagnostic-only, bounded, and non-overwriting'
Write-Host "$count GPU telemetry checks passed. Native PDH availability and accuracy require a Windows lab run."
