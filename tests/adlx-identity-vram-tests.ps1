#requires -Version 7.0
# Mock-only: runs on any OS. No ADLX, no Windows APIs, no child collector process.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$repo=Split-Path $PSScriptRoot -Parent
$count=0
function Check($condition,$message){if(-not $condition){throw $message};$script:count++}
function Reject($block,$message){$threw=$false;try{& $block | Out-Null}catch{$threw=$true};Check $threw $message}
function RejectText($block,$pattern,$message){
    $text=$null;try{& $block | Out-Null}catch{$text=$_.Exception.Message}
    Check ($null -ne $text -and $text -match $pattern) ($message+" (got: $text)")
}
$wrapperPath=Join-Path $repo 'tools/adlx-identity-vram.ps1'
$sourcePath=Join-Path $repo 'tools/adlx-identity-vram.c'
$buildPath=Join-Path $repo 'tools/build-adlx-identity-vram.sh'
. $wrapperPath -LibraryOnly

# --- parameter bounds
$p=Assert-AdlxIdentityParameters -Mode identity -IntervalMs $null -Count $null -TimeoutSeconds $null
Check ($p.Mode -ceq 'identity' -and $p.TimeoutSeconds -eq 60 -and $null -eq $p.IntervalMs) 'identity defaults'
Check ((Assert-AdlxIdentityParameters -Mode identity -IntervalMs $null -Count $null -TimeoutSeconds 5).TimeoutSeconds -eq 5) 'identity timeout lower bound'
Check ((Assert-AdlxIdentityParameters -Mode identity -IntervalMs $null -Count $null -TimeoutSeconds 300).TimeoutSeconds -eq 300) 'identity timeout upper bound'
Reject {Assert-AdlxIdentityParameters -Mode identity -IntervalMs $null -Count $null -TimeoutSeconds 4} 'identity timeout 4 accepted'
Reject {Assert-AdlxIdentityParameters -Mode identity -IntervalMs $null -Count $null -TimeoutSeconds 301} 'identity timeout 301 accepted'
Reject {Assert-AdlxIdentityParameters -Mode identity -IntervalMs 1000 -Count $null -TimeoutSeconds $null} 'identity with interval accepted'
Reject {Assert-AdlxIdentityParameters -Mode identity -IntervalMs $null -Count 3 -TimeoutSeconds $null} 'identity with count accepted'
Reject {Assert-AdlxIdentityParameters -Mode $null -IntervalMs $null -Count $null -TimeoutSeconds $null} 'missing mode accepted'
Reject {Assert-AdlxIdentityParameters -Mode Sample -IntervalMs 1000 -Count 3 -TimeoutSeconds $null} 'mode is case-sensitive lower-case'
Reject {Assert-AdlxIdentityParameters -Mode tune -IntervalMs 1000 -Count 3 -TimeoutSeconds $null} 'unknown mode accepted'
$s=Assert-AdlxIdentityParameters -Mode sample -IntervalMs 1000 -Count 10 -TimeoutSeconds $null
Check ($s.Mode -ceq 'sample' -and $s.IntervalMs -eq 1000 -and $s.Count -eq 10 -and $s.TimeoutSeconds -eq 70) 'sample default timeout is wall+60'
Check ((Assert-AdlxIdentityParameters -Mode sample -IntervalMs 200 -Count 1 -TimeoutSeconds $null).Count -eq 1) 'min interval and count accepted'
Check ((Assert-AdlxIdentityParameters -Mode sample -IntervalMs 5000 -Count 1440 -TimeoutSeconds $null).TimeoutSeconds -eq 7260) '2h exact plan accepted'
Check ((Assert-AdlxIdentityParameters -Mode sample -IntervalMs 200 -Count 36000 -TimeoutSeconds $null).TimeoutSeconds -eq 7260) 'max count at min interval is exactly 2h'
Reject {Assert-AdlxIdentityParameters -Mode sample -IntervalMs 199 -Count 10 -TimeoutSeconds $null} 'interval 199 accepted'
Reject {Assert-AdlxIdentityParameters -Mode sample -IntervalMs 5001 -Count 10 -TimeoutSeconds $null} 'interval 5001 accepted'
Reject {Assert-AdlxIdentityParameters -Mode sample -IntervalMs 1000 -Count 0 -TimeoutSeconds $null} 'count 0 accepted'
Reject {Assert-AdlxIdentityParameters -Mode sample -IntervalMs 1000 -Count 36001 -TimeoutSeconds $null} 'count 36001 accepted'
Reject {Assert-AdlxIdentityParameters -Mode sample -IntervalMs 5000 -Count 36000 -TimeoutSeconds $null} '50h plan accepted'
RejectText {Assert-AdlxIdentityParameters -Mode sample -IntervalMs 5000 -Count 1441 -TimeoutSeconds $null} 'wall time' '2h+5s plan accepted'
Reject {Assert-AdlxIdentityParameters -Mode sample -IntervalMs $null -Count 10 -TimeoutSeconds $null} 'sample without interval accepted'
Reject {Assert-AdlxIdentityParameters -Mode sample -IntervalMs 1000 -Count $null -TimeoutSeconds $null} 'sample without count accepted'
Reject {Assert-AdlxIdentityParameters -Mode sample -IntervalMs 1000 -Count 10 -TimeoutSeconds 14} 'timeout below wall+5 accepted'
Check ((Assert-AdlxIdentityParameters -Mode sample -IntervalMs 1000 -Count 10 -TimeoutSeconds 15).TimeoutSeconds -eq 15) 'timeout wall+5 accepted'
Reject {Assert-AdlxIdentityParameters -Mode sample -IntervalMs 1000 -Count 10 -TimeoutSeconds 7501} 'timeout above 7500 accepted'

# --- executable digest
$tempBase=[IO.Path]::GetTempPath()
if($IsMacOS -and $tempBase.StartsWith('/var/')){$tempBase='/private'+$tempBase}  # /var is a symlink on macOS
$tmp=Join-Path $tempBase ('adlx-identity-tests-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tmp | Out-Null
try {
    $exe=Join-Path $tmp 'adlx-identity-vram.exe'
    [IO.File]::WriteAllBytes($exe,[byte[]](1,2,3,4,5))
    $good=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()
    $found=Assert-AdlxExecutable -Path $exe -ExpectedSha256 $good
    Check ($found.Sha256 -eq $good -and $found.Path -eq $exe) 'matching digest accepted'
    Check ((Assert-AdlxExecutable -Path $exe -ExpectedSha256 $good.ToUpperInvariant()).Sha256 -eq $good) 'upper-case digest accepted'
    RejectText {Assert-AdlxExecutable -Path $exe -ExpectedSha256 ('0'*64)} 'digest mismatch' 'wrong digest accepted'
    Reject {Assert-AdlxExecutable -Path $exe -ExpectedSha256 ''} 'empty digest accepted'
    Reject {Assert-AdlxExecutable -Path $exe -ExpectedSha256 $null} 'null digest accepted'
    Reject {Assert-AdlxExecutable -Path $exe -ExpectedSha256 $good.Substring(1)} 'short digest accepted'
    Reject {Assert-AdlxExecutable -Path $exe -ExpectedSha256 ($good+'0')} 'long digest accepted'
    Reject {Assert-AdlxExecutable -Path $exe -ExpectedSha256 ('g'*64)} 'non-hex digest accepted'
    Reject {Assert-AdlxExecutable -Path 'relative.exe' -ExpectedSha256 $good} 'relative executable accepted'
    Reject {Assert-AdlxExecutable -Path (Join-Path $tmp 'missing.exe') -ExpectedSha256 $good} 'missing executable accepted'
    Reject {Assert-AdlxExecutable -Path $tmp -ExpectedSha256 $good} 'directory executable accepted'
    $required=(Get-Command $wrapperPath).Parameters['ExpectedExecutableSha256']
    Check ($null -ne $required) 'wrapper declares ExpectedExecutableSha256'

    # --- output path
    $out=Join-Path $tmp 'identity.jsonl'
    Check ((Assert-AdlxIdentityOutputPath -Path $out -Mode identity) -eq $out) 'fresh .jsonl accepted'
    Check ((Assert-AdlxIdentityOutputPath -Path (Join-Path $tmp 'identity.json') -Mode identity) -like '*identity.json') 'fresh .json accepted for identity'
    Check ((Assert-AdlxIdentityOutputPath -Path (Join-Path $tmp 'IDENT.JSONL') -Mode sample) -like '*IDENT.JSONL') 'upper-case .JSONL accepted for sample'
    Reject {Assert-AdlxIdentityOutputPath -Path (Join-Path $tmp 'sample.json') -Mode sample} 'sample .json accepted'
    Reject {Assert-AdlxIdentityOutputPath -Path (Join-Path $tmp 'x.txt') -Mode identity} '.txt accepted'
    Reject {Assert-AdlxIdentityOutputPath -Path (Join-Path $tmp 'x') -Mode identity} 'extensionless accepted'
    Reject {Assert-AdlxIdentityOutputPath -Path 'relative.jsonl' -Mode identity} 'relative path accepted'
    Reject {Assert-AdlxIdentityOutputPath -Path '' -Mode identity} 'empty path accepted'
    Reject {Assert-AdlxIdentityOutputPath -Path (Join-Path $tmp 'no-parent/x.jsonl') -Mode identity} 'missing parent accepted'
    [IO.File]::WriteAllText($out,'x')
    RejectText {Assert-AdlxIdentityOutputPath -Path $out -Mode identity} 'already exists' 'existing file overwrite accepted'
    Check ([IO.File]::ReadAllText($out) -ceq 'x') 'existing file untouched by refusal'
    $dir=Join-Path $tmp 'dir.jsonl';New-Item -ItemType Directory $dir | Out-Null
    RejectText {Assert-AdlxIdentityOutputPath -Path $dir -Mode identity} 'already exists' 'existing directory accepted'
    if(-not $IsWindows){
        $real=Join-Path $tmp 'real';New-Item -ItemType Directory $real | Out-Null
        $link=Join-Path $tmp 'link';New-Item -ItemType SymbolicLink -Path $link -Target $real | Out-Null
        RejectText {Assert-AdlxIdentityOutputPath -Path (Join-Path $link 'x.jsonl') -Mode identity} 'reparse' 'reparse-point parent accepted'
        $dangling=Join-Path $tmp 'dangling.jsonl'
        New-Item -ItemType SymbolicLink -Path $dangling -Target (Join-Path $tmp 'nowhere') | Out-Null
        RejectText {Assert-AdlxIdentityOutputPath -Path $dangling -Mode identity} 'already exists' 'dangling link output accepted'
    }

    # --- fixture JSON lines
    function F($status,$result,$value){ '{"status":"'+$status+'","adlxResult":'+$result+',"value":'+$value+'}' }
    function Fields($names,$overrides){
        $parts=@()
        foreach($n in $names){
            if($overrides.ContainsKey($n)){$parts+=('"'+$n+'":'+$overrides[$n])}
            else{$parts+=('"'+$n+'":'+(F 'available' 0 '1'))}
        }
        $parts -join ','
    }
    $tail=',"qualification":false,"servingDeviceBound":false}'
    function IdentityLine($index,$overrides,$extraTail){
        if($null -eq $overrides){$overrides=@{}}
        $t=$tail;if($extraTail){$t=$extraTail}
        '{"schemaVersion":1,"kind":"adlx-identity","gpuIndex":'+$index+',"gpuCount":2,"utcFileTime":133700000000000000,'+(Fields $script:AdlxIdentityFields $overrides)+$t
    }
    function SampleLine($index,$sampleNo,$overrides){
        if($null -eq $overrides){$overrides=@{}}
        '{"schemaVersion":1,"kind":"adlx-sample","gpuIndex":'+$index+',"gpuCount":2,"utcFileTime":133700000000000000,"sample":'+$sampleNo+','+(Fields $script:AdlxSampleFields $overrides)+$tail
    }
    $row=ConvertFrom-AdlxCollectorLine -Line (IdentityLine 0 @{}) -Mode identity
    Check ($row.gpuIndex -eq 0 -and $row.kind -ceq 'adlx-identity' -and $row.qualification -eq $false -and $row.servingDeviceBound -eq $false) 'identity fixture parses'
    $mixed=@{
        pciBusType=(F 'unsupported-interface' 6 'null')
        productName=(F 'failed' 3 'null')
        pciBusLaneWidth=(F 'available' 0 '16')
    }
    $row=ConvertFrom-AdlxCollectorLine -Line (IdentityLine 1 $mixed) -Mode identity
    Check ($row.pciBusType.status -ceq 'unsupported-interface' -and $row.productName.adlxResult -eq 3 -and $row.pciBusLaneWidth.value -eq 16) 'identity statuses and raw results preserved'
    $row=ConvertFrom-AdlxCollectorLine -Line (SampleLine 1 7 @{gpuVramMB=(F 'available' 0 '4096');gpuUsagePercent=(F 'unsupported' 0 'null')}) -Mode sample
    Check ($row.kind -ceq 'adlx-sample' -and $row.sample -eq 7 -and $row.gpuVramMB.value -eq 4096 -and $row.gpuUsagePercent.status -ceq 'unsupported') 'sample fixture parses'
    Reject {ConvertFrom-AdlxCollectorLine -Line (SampleLine 0 0 @{}) -Mode identity} 'sample line accepted as identity'
    Reject {ConvertFrom-AdlxCollectorLine -Line (IdentityLine 0 @{}) -Mode sample} 'identity line accepted as sample'
    Reject {ConvertFrom-AdlxCollectorLine -Line ((IdentityLine 0 @{}).Replace('"qualification":false','"qualification":true')) -Mode identity} 'qualification true accepted'
    Reject {ConvertFrom-AdlxCollectorLine -Line ((IdentityLine 0 @{}).Replace('"servingDeviceBound":false','"servingDeviceBound":true')) -Mode identity} 'servingDeviceBound true accepted'
    Reject {ConvertFrom-AdlxCollectorLine -Line ((IdentityLine 0 @{}).Replace(',"qualification":false,"servingDeviceBound":false','')) -Mode identity} 'missing qualification accepted'
    Reject {ConvertFrom-AdlxCollectorLine -Line ((IdentityLine 0 @{}).Replace('"schemaVersion":1','"schemaVersion":2')) -Mode identity} 'schema 2 accepted'
    Reject {ConvertFrom-AdlxCollectorLine -Line (IdentityLine 2 @{}) -Mode identity} 'gpuIndex >= gpuCount accepted'
    Reject {ConvertFrom-AdlxCollectorLine -Line (IdentityLine 0 @{vendorId=(F 'maybe' 0 'null')}) -Mode identity} 'unknown status accepted'
    Reject {ConvertFrom-AdlxCollectorLine -Line (IdentityLine 0 @{vendorId=(F 'failed' 'null' 'null')}) -Mode identity} 'failed without raw result accepted'
    Reject {ConvertFrom-AdlxCollectorLine -Line ((IdentityLine 0 @{}).Replace('"vendorId":','"vendorIdX":')) -Mode identity} 'missing identity field accepted'
    Reject {ConvertFrom-AdlxCollectorLine -Line ((SampleLine 0 0 @{}).Replace('"gpuVramMB":','"gpuVramX":')) -Mode sample} 'missing sample field accepted'
    Reject {ConvertFrom-AdlxCollectorLine -Line 'not json' -Mode identity} 'non-JSON accepted'
    Reject {ConvertFrom-AdlxCollectorLine -Line ('{'+('a'*9000)+'}') -Mode identity} 'oversize line accepted'
    Reject {ConvertFrom-AdlxCollectorLine -Line (SampleLine 0 36000 @{}) -Mode sample} 'sample index 36000 accepted'
    foreach($name in @('pnpString','vendorId','deviceId','revisionId','subSystemId','subSystemVendorId','name','totalVramMB','vramType','uniqueId','asicFamilyType','type','isExternal','hasDesktops','driverPath','biosInfo','productName','pciBusType','pciBusLaneWidth','multiGpuMode')){
        Check ($script:AdlxIdentityFields -contains $name) "identity field list lacks $name"
    }
    foreach($name in @('gpuVramMB','gpuUsagePercent','gpuClockMHz','gpuVramClockMHz','gpuTotalBoardPowerW','gpuTemperatureC','gpuHotspotTemperatureC')){
        Check ($script:AdlxSampleFields -contains $name) "sample field list lacks $name"
    }

    # --- line sink (real DataReceivedEventArgs built by reflection)
    Initialize-AdlxLineSink
    function Feed($sink,$text){
        $args=[Activator]::CreateInstance([Diagnostics.DataReceivedEventArgs],[Reflection.BindingFlags]'NonPublic,Instance',$null,@($text),$null)
        $sink.Handler.Invoke($null,$args)
    }
    $sinkPath=Join-Path $tmp 'sink.jsonl'
    $sink=New-Object Bitworks.FastLlm.AdlxLineSink($sinkPath,'adlx-sample',4,[long]65536)
    $sink.WriteRaw('{"kind":"header"}')
    Feed $sink (SampleLine 0 0 @{})
    Feed $sink (SampleLine 1 0 @{})
    Feed $sink $null
    Feed $sink ''
    Check ($sink.Lines -eq 2 -and $null -eq $sink.Error -and $sink.First.Count -eq 2) 'sink counts valid lines and ignores EOF/blank'
    Reject {New-Object Bitworks.FastLlm.AdlxLineSink($sinkPath,'adlx-sample',4,[long]65536)} 'sink overwrote existing file'
    Feed $sink (IdentityLine 0 @{})
    Check ($sink.Error -ceq 'unexpected-collector-line' -and $sink.Lines -eq 2) 'sink rejects wrong kind'
    Feed $sink (SampleLine 0 1 @{})
    Check ($sink.Lines -eq 2) 'sink stops after first error'
    $sink.Dispose()
    $written=@([IO.File]::ReadAllLines($sinkPath))
    Check ($written.Count -eq 3 -and $written[0] -ceq '{"kind":"header"}' -and $written[1] -ceq (SampleLine 0 0 @{})) 'sink file holds header plus accepted lines only'
    $sink2=New-Object Bitworks.FastLlm.AdlxLineSink((Join-Path $tmp 'sink2.jsonl'),'adlx-sample',1,[long]65536)
    Feed $sink2 (SampleLine 0 0 @{}); Feed $sink2 (SampleLine 1 0 @{})
    Check ($sink2.Error -ceq 'too-many-lines' -and $sink2.Lines -eq 1) 'sink enforces line limit'
    $sink2.Dispose()
    $sink3=New-Object Bitworks.FastLlm.AdlxLineSink($null,'adlx-sample',4,[long]65536)
    Feed $sink3 ((SampleLine 0 0 @{}).Replace($tail,',"qualification":true,"servingDeviceBound":false}'))
    Check ($sink3.Error -ceq 'unexpected-collector-line') 'sink rejects qualification not false'
    $sink3.Dispose()
    $sink4=New-Object Bitworks.FastLlm.AdlxLineSink($null,'adlx-identity',4,[long]65536)
    Feed $sink4 (IdentityLine 0 @{}); Feed $sink4 (IdentityLine 1 @{})
    Check ($sink4.Collected.Count -eq 2 -and $sink4.Last -ceq (IdentityLine 1 @{})) 'memory sink collects lines'
    $sink4.Dispose()
    $sink5=New-Object Bitworks.FastLlm.AdlxLineSink($null,'adlx-identity',4,[long]100)
    Feed $sink5 (IdentityLine 0 @{})
    Check ($sink5.Error -ceq 'output-byte-limit') 'sink enforces byte limit'
    $sink5.Dispose()

    # --- header/footer/document shape
    $plan=Assert-AdlxIdentityParameters -Mode sample -IntervalMs 1000 -Count 2 -TimeoutSeconds $null
    $header=New-AdlxHeaderRecord -Plan $plan -WrapperSha256 ('a'*64) -Executable ([pscustomobject]@{Sha256=('b'*64)}) `
        -Driver ([pscustomobject]@{Path='C:\Windows\System32\amdadlx64.dll';Version='1.2.3';Sha256=('c'*64);Signer='O=Advanced Micro Devices, Inc.'}) -StartedUtc '2026-10-06T00:00:00Z'
    $hl=ConvertTo-AdlxJsonLine $header
    $hj=$hl | ConvertFrom-Json
    Check ($hl -notmatch "`n" -and $hj.kind -ceq 'adlx-run-header' -and $hj.qualification -eq $false -and $hj.servingDeviceBound -eq $false -and
           $hj.wrapperSourceSha256 -ceq ('a'*64) -and $hj.collectorSha256 -ceq ('b'*64) -and $hj.adlxDriverSha256 -ceq ('c'*64) -and
           $hj.adlxDriverVersion -ceq '1.2.3' -and $hj.adlxDriverSigner -like 'O=Advanced*' -and $hj.adlxDriverPath -like '*amdadlx64.dll') 'header carries wrapper, exe, DLL hash/version/signer'
    $fl=ConvertTo-AdlxJsonLine (New-AdlxFooterRecord -Status failed -CollectorLines 3 -ExitCode 4 -ErrorText 'x "y"' -EndedUtc '2026-10-06T00:00:01Z')
    $fj=$fl | ConvertFrom-Json
    Check ($fj.kind -ceq 'adlx-run-footer' -and $fj.status -ceq 'failed' -and $fj.qualification -eq $false -and $fj.error -ceq 'x "y"') 'footer shape'
    $doc=New-AdlxIdentityDocument -HeaderLine $hl -RecordLines @((IdentityLine 0 @{}),(IdentityLine 1 @{})) -FooterLine $fl
    $dj=$doc | ConvertFrom-Json
    Check ($dj.kind -ceq 'adlx-identity-report' -and @($dj.records).Count -eq 2 -and $dj.header.kind -ceq 'adlx-run-header' -and $dj.footer.kind -ceq 'adlx-run-footer' -and $dj.qualification -eq $false) 'identity document parses'
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

# --- wrapper refuses non-Windows hosts before touching anything
$pwshPath=(Get-Process -Id $PID).Path
if(-not $IsWindows){
    $probeOut=Join-Path ([IO.Path]::GetTempPath()) ('adlx-probe-'+[guid]::NewGuid().ToString('N')+'.jsonl')
    $stderr=& $pwshPath -NoProfile -File $wrapperPath -Mode identity -ExecutablePath '/nope' -ExpectedExecutableSha256 ('0'*64) -OutputPath $probeOut 2>&1 | Out-String
    Check ($LASTEXITCODE -eq 1 -and $stderr -match '64-bit Windows' -and -not (Test-Path -LiteralPath $probeOut)) 'wrapper exits 1 on non-Windows without creating output'
    $global:LASTEXITCODE = 0  # The expected child failure was asserted above.
}

# --- static scan: no mutating ADLX calls in the C source
$c=Get-Content -LiteralPath $sourcePath -Raw
foreach($forbidden in @('->Set','Apply','Reset','SetManual','SetPower','PowerOn','StartPowerOff','AbortPowerOff','IGPUTuning','ManualVRAMTuning','ManualPowerTuning','PresetTuning','GetGPUTuningServices')){
    Check (-not $c.Contains($forbidden)) "C source contains forbidden token $forbidden"
}
Check ($c -notmatch '->pVtbl->(?:Set|Apply|Reset|Start|Stop|Abort|PowerOn)') 'C source calls a mutating vtable method'
foreach($required in @('IsSupportedGPUVRAM','GPUVRAM(','GPUUsage','GPUClockSpeed','GPUVRAMClockSpeed','GPUTotalBoardPower','GPUTemperature','GPUHotspotTemperature','IID_IADLXGPU1()','IID_IADLXGPU2()','PCIBusType','PCIBusLaneWidth','MultiGPUMode','ProductName','IsPowerOff','DriverVersion','BIOSInfo','TotalVRAM','UniqueId')){
    Check ($c.Contains($required)) "C source lacks $required"
}
Check ($c.Contains('"adlx-identity"') -and $c.Contains('"adlx-sample"') -and $c.Contains('\"qualification\":false,\"servingDeviceBound\":false') -and $c.Contains('#define SCHEMA_VERSION 1')) 'C source lacks schema/kind/qualification markers'
Check (([regex]::Matches($c,'record_close\(')).Count -ge 3 -and $c.Contains('fflush(stdout)')) 'records are flushed per line'

# --- the DLL loads only from the system directory
Check (([regex]::Matches($c,'LoadLibrary')).Count -eq 1 -and $c.Contains('LoadLibraryExW(dll, NULL, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32)')) 'single System32-restricted LoadLibraryExW'
Check ($c.Contains('GetSystemDirectoryW(dll, MAX_PATH)') -and $c.Contains('L"\\amdadlx64.dll"')) 'DLL path is built from GetSystemDirectoryW'
Check ($c -notmatch 'SetDllDirectory|AddDllDirectory|GetModuleHandle|LoadPackagedLibrary|LOAD_WITH_ALTERED_SEARCH_PATH|getenv|argv\[[^\]]*\]\s*\)\s*;\s*\n\s*lib') 'no alternate DLL search path or environment use'
Check (([regex]::Matches($c,'GetProcAddress')).Count -eq 2) 'only ADLXInitialize and ADLXTerminate are resolved'
# CLI bounds are enforced by the collector itself as well
Check ($c.Contains('#define MIN_INTERVAL_MS 200u') -and $c.Contains('#define MAX_INTERVAL_MS 5000u') -and $c.Contains('#define MAX_COUNT 36000u') -and $c.Contains('#define MAX_WALL_MS 7200000ull') -and $c.Contains('#define MAX_GPUS 8')) 'collector CLI bounds'
# Enum decoding: ADLX_PCI_BUS_TYPE values 0-7 keep raw values in the output
foreach($label in @('UNDEFINED','PCI','AGP','PCIE','PCIE_2_0','PCIE_3_0','PCIE_4_0','PCIE_5_0')){ Check ($c.Contains('return "'+$label+'";')) "PCI bus label $label" }
Check ($c.Contains('{\"raw\":%d,\"name\":')) 'enum fields keep the raw value'

# --- wrapper and build script contracts
$w=Get-Content -LiteralPath $wrapperPath -Raw
Check ($w -notmatch '\?\?' -and $w -notmatch '\[short\]' -and $w -notmatch '(?m)=\s*\$\w+\s*\?\s' -and $w -notmatch '\)\s*\?\s*[\$''"\(]') 'wrapper avoids ternary, ??, and [short]'
Check ($w.StartsWith('#requires -Version 5.1') -and $w.Contains('Bitworks.FastLlm.ProcessHost') -and $w.Contains('Is64BitProcess') -and $w.Contains('WindowsBuiltInRole]::Administrator')) 'wrapper guards and ProcessHost reuse'
Check ($w -match 'Get-AuthenticodeSignature' -and $w -match "SystemDirectory\) 'amdadlx64.dll'" -and $w -match 'O=Advanced Micro Devices') 'wrapper records System32 DLL signer'
Check ($w -notmatch 'Start-Process|Invoke-Expression|\biex\b') 'wrapper avoids shell launch'
$b=Get-Content -LiteralPath $buildPath -Raw
Check ($b.Contains("sdk_commit='32b5a740d42295c5dfe9026b9f52683da0f3af91'") -and $b.Contains("sdk_zip_sha256='99850ddd58e3f5bbfdbe41c87248da8d5394227eaa32b19aad3206b4c3b2677c'") -and $b.Contains("!= '0.16.0'") -and $b.Contains('-Wall -Wextra -Werror') -and $b.Contains('mktemp -d')) 'build script pins SDK/Zig and uses -Werror'
# --- pinned sources stay unmodified
$v1=(Get-FileHash -LiteralPath (Join-Path $repo 'tools/adlx-telemetry.c') -Algorithm SHA256).Hash.ToLowerInvariant()
Check ($v1 -eq 'f40506f015e3dd6ecaa9f11671ff3cc127896b539faac18ae572a12a4bb16a24') 'pinned v1 collector source unchanged'
Write-Host "adlx-identity-vram-tests: $count checks passed"
