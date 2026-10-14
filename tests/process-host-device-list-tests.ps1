#requires -Version 5.1
# Mock-only: runs disposable PowerShell children that print fixture server lines. No engine, model or GPU.
# Covers the strict ProcessHost capture of exactly two server line shapes (the level-4 device_info entries and the
# llama_prepare_model_devices "using device" lines), its bounds, and that the existing selected-device capture is unchanged.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$repo = Split-Path $PSScriptRoot -Parent
$passes = 0
function Check($ok, $message) { if (-not $ok) { throw $message }; $script:passes++ }
if (-not ('Bitworks.FastLlm.ProcessHost' -as [type])) { Add-Type -Path (Join-Path $repo 'src/ProcessHost.cs') -ErrorAction Stop }

function Start-FixtureChild([string]$ScriptText) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = (Get-Process -Id $PID).Path
    $info.Arguments = '-NoLogo -NoProfile -NonInteractive -OutputFormat Text -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ScriptText))
    $child = New-Object Bitworks.FastLlm.ProcessHost
    $child.Start($info)
    return $child
}
function Wait-FixtureChild($Child) {
    Check ($Child.Process.WaitForExit(20000)) 'Disposable child did not exit.'
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while (-not $Child.OutputCompleted -and $deadline.ElapsedMilliseconds -lt 5000) { Start-Sleep -Milliseconds 20 }
    Check $Child.OutputCompleted 'Child output did not complete.'
}
function Normalize([string]$Text) { return $Text.Replace("`r`n", "`n") }

# ---- the two shapes are captured, in the real b10698 prefixed form and in the unprefixed form; everything else, including near misses, is counted and never retained
# Real b10698 shapes: common_init() turns the log prefix on, so each line starts "<M.SS.mmm.uuu> <L> "; a COM_TRC device_info entry also carries the "cmn  %12.*s: " tag.
$main = Start-FixtureChild @'
Write-Output '0.00.402.123 I cmn  common_param:   - Vulkan0 : AMD Radeon RX 7900 XTX (24560 MiB, 24100 MiB free)'
Write-Output '  - CPU     : AMD Ryzen 9 7950X 16-Core Processor (65536 MiB, 32000 MiB free)'
# Tolerance case (labelled): the pattern accepts any single capital level letter, so this one positive D line is still captured.
Write-Output 'D cmn  common_param:   - Vulkan1 : AMD Radeon RX 7900 XT (20464 MiB, 20304 MiB free)'
Write-Output 'I   - Vulkan2 : AMD Radeon Graphics (2048 MiB, 2000 MiB free)'
Write-Output '0.01.234.567 I llama_prepare_model_devices: using device Vulkan0 (AMD Radeon RX 7900 XTX) (0000:03:00.0) - 24100 MiB free'
Write-Output 'llama_prepare_model_devices: using device Vulkan1 (AMD Radeon RX 7900 XT) (unknown id) - 18000 MiB free'
Write-Output '0.01.234.567 I llama_prepare_model_devices: using device Vulkan2 (AMD Radeon RX 7900 XT) (unknown id) - 20304 MiB free'
Write-Output '  - Vulkan3 : broken (NaN MiB, 5 MiB free)'
Write-Output 'user said  - hello (1 MiB, 2 MiB free)'
Write-Output 'llama_prepare_model_devices: using device Vulkan3 (AMD Radeon) (0000:05:00.0) - NaN MiB free'
Write-Output 'prompt secret content'
Write-Output 'ggml_vulkan: 0 = AMD Radeon RX 7900 XTX (AMD proprietary driver) | uma: 0 | fp16: 1 | warp size: 64'
'@
try {
    Wait-FixtureChild $main
    $info = Normalize $main.FreezeDeviceInfoEntries()
    $using = Normalize $main.FreezeUsingDeviceEntries()
    Check ($info -ceq "device-info Vulkan0 24560 24100 AMD Radeon RX 7900 XTX`ndevice-info CPU 65536 32000 AMD Ryzen 9 7950X 16-Core Processor`ndevice-info Vulkan1 20464 20304 AMD Radeon RX 7900 XT`ndevice-info Vulkan2 2048 2000 AMD Radeon Graphics`n") 'device_info entries (real timestamp+level+cmn-tag line, unprefixed padded name, tag without timestamp, level-letter only) were not captured as normalized lines.'
    Check ($using -ceq "using-device Vulkan0 0000:03:00.0 24100 AMD Radeon RX 7900 XTX`nusing-device Vulkan1 unknown 18000 AMD Radeon RX 7900 XT`nusing-device Vulkan2 unknown 20304 AMD Radeon RX 7900 XT`n") 'using-device lines (real timestamp+level prefix and unprefixed; BDF and unknown id) were not captured as normalized lines.'
    Check (($info + $using) -notmatch 'secret|NaN|hello|broken|ggml_vulkan|warp|proprietary|cmn|common_param') 'Text outside the two strict shapes was retained.'
    Check ($main.DeviceInfoLikeLines -eq 6 -and $main.DeviceInfoMalformedLines -eq 2 -and $main.UsingDeviceLikeLines -eq 4 -and $main.UsingDeviceMalformedLines -eq 1 -and
           -not $main.DeviceInfoOverflow -and -not $main.UsingDeviceOverflow) 'Like/malformed counters or overflow flags differ.'
    Check ($main.DeviceListCaptureDiagnostics() -match 'deviceInfo\(like=6, captured=4, malformed=2, dropped=0\), usingDevice\(like=4, captured=3, malformed=1, dropped=0\)' -and
           $main.DeviceListCaptureDiagnostics() -notmatch 'Radeon|secret|Vulkan|CPU') 'Diagnostics differ or leaked server text.'
    # The existing selected-device capture sees the same lines exactly as before (its pattern is unanchored, so the real prefix never mattered).
    Check ((Normalize $main.FreezeSelectedDeviceIdentity()) -ceq "selected-device Vulkan0 0000:03:00.0`n" -and $main.SelectedDeviceLikeLines -eq 4 -and $main.SelectedDeviceMalformedLines -eq 3 -and
           $main.SelectedDeviceUnknownIdLines -eq 2 -and $main.SelectedDeviceBadFormatLines -eq 1 -and -not $main.SelectedDeviceIdentityOverflow) 'The existing selected-device capture changed.'
    Check ((Normalize $main.FreezeSelectedUnknownDeviceIdentity()) -ceq "selected-device-unknown Vulkan1`nselected-device-unknown Vulkan2`n") 'The existing unknown-id capture changed.'
} finally { $main.Dispose() }

# ---- the exact real-shape lines from the b10698 source (common_init prefix, COM_TRC cmn tag); real level letter I (LOG_TRC logs at INFO level in b10698; the pattern also tolerates any other capital letter, so a D line is still captured), and unprefixed
$real = Start-FixtureChild @'
Write-Output '0.00.402.123 I cmn  common_param:   - Vulkan0 : AMD Radeon RX 7900 XT (20464 MiB, 20304 MiB free)'
Write-Output '0.00.402.123 I cmn  common_param:   - Vulkan1 : AMD Radeon RX 7900 XT (20464 MiB, 20304 MiB free)'
Write-Output '  - Vulkan2 : AMD Radeon RX 7900 XT (20464 MiB, 20304 MiB free)'
Write-Output '0.01.234.567 I llama_prepare_model_devices: using device Vulkan0 (AMD Radeon RX 7900 XT) (unknown id) - 20304 MiB free'
Write-Output 'llama_prepare_model_devices: using device Vulkan1 (AMD Radeon RX 7900 XT) (unknown id) - 20304 MiB free'
'@
try {
    Wait-FixtureChild $real
    Check ((Normalize $real.FreezeDeviceInfoEntries()) -ceq "device-info Vulkan0 20464 20304 AMD Radeon RX 7900 XT`ndevice-info Vulkan1 20464 20304 AMD Radeon RX 7900 XT`ndevice-info Vulkan2 20464 20304 AMD Radeon RX 7900 XT`n" -and
           (Normalize $real.FreezeUsingDeviceEntries()) -ceq "using-device Vulkan0 unknown 20304 AMD Radeon RX 7900 XT`nusing-device Vulkan1 unknown 20304 AMD Radeon RX 7900 XT`n" -and
           $real.DeviceInfoLikeLines -eq 3 -and $real.DeviceInfoMalformedLines -eq 0 -and $real.UsingDeviceLikeLines -eq 2 -and $real.UsingDeviceMalformedLines -eq 0) 'The exact real b10698 line shapes (D and I level letters, prefixed and unprefixed) were not captured.'
} finally { $real.Dispose() }

# ---- negative prefix cases: an extra prefix token, a doubled timestamp, a short cmn tag, colour escape codes, and an over-long line are counted and never retained
$neg = Start-FixtureChild @'
$e = [string][char]27
Write-Output '0.00.402.123 I cmn  common_param:   - Vulkan0 : AMD Radeon RX 7900 XTX (24560 MiB, 24100 MiB free)'
Write-Output '0.00.402.123 D D cmn  common_param:   - Vulkan1 : extra token (1 MiB, 1 MiB free)'
Write-Output '0.00.402.123 0.00.402.123 D cmn  common_param:   - Vulkan2 : double timestamp (1 MiB, 1 MiB free)'
Write-Output '0.00.402.123 D cmn  common_par:   - Vulkan3 : short cmn tag (1 MiB, 1 MiB free)'
Write-Output ($e + '[0;34m0.00.402.123' + $e + '[0m D cmn  common_param:   - Vulkan4 : colour codes (1 MiB, 1 MiB free)')
Write-Output ('0.00.402.123 D cmn  common_param:   - Vulkan5 : over-long (1 MiB, 1 MiB free)' + (' ' * 200))
Write-Output '0.01.234.567 I llama_prepare_model_devices: using device Vulkan0 (AMD Radeon RX 7900 XTX) (0000:03:00.0) - 24100 MiB free'
Write-Output '0.01.234.567 I X llama_prepare_model_devices: using device Vulkan1 (extra token) (0000:04:00.0) - 1 MiB free'
Write-Output ($e + '[0;34m0.01.234.567' + $e + '[0m I llama_prepare_model_devices: using device Vulkan2 (colour codes) (0000:05:00.0) - 1 MiB free')
Write-Output ('0.01.234.567 I llama_prepare_model_devices: using device Vulkan3 (over-long) (0000:06:00.0) - 1 MiB free' + (' ' * 200))
'@
try {
    Wait-FixtureChild $neg
    $info = Normalize $neg.FreezeDeviceInfoEntries(); $using = Normalize $neg.FreezeUsingDeviceEntries()
    Check ($info -ceq "device-info Vulkan0 24560 24100 AMD Radeon RX 7900 XTX`n" -and $using -ceq "using-device Vulkan0 0000:03:00.0 24100 AMD Radeon RX 7900 XTX`n") 'A line with an extra prefix token, colour escape codes or over-length was retained.'
    Check ($neg.DeviceInfoLikeLines -eq 6 -and $neg.DeviceInfoMalformedLines -eq 5 -and $neg.UsingDeviceLikeLines -eq 4 -and $neg.UsingDeviceMalformedLines -eq 3) 'Negative prefix cases were not counted as malformed.'
} finally { $neg.Dispose() }

# ---- length bounds: description 128 is the maximum; a line over 256 characters never reaches the pattern
$long = Start-FixtureChild @'
$ok = 'A' * 128
$tooLong = 'A' * 129
Write-Output ('  - Vulkan0 : ' + $ok + ' (1 MiB, 1 MiB free)')
Write-Output ('  - Vulkan1 : ' + $tooLong + ' (1 MiB, 1 MiB free)')
Write-Output ('  - Vulkan2 : ' + ('B' * 300) + ' (1 MiB, 1 MiB free)')
Write-Output ('llama_prepare_model_devices: using device Vulkan0 (' + ('C' * 300) + ') (0000:03:00.0) - 1 MiB free')
Write-Output ('llama_prepare_model_devices: using device Vulkan1 (' + $tooLong + ') (0000:03:00.0) - 1 MiB free')
'@
try {
    Wait-FixtureChild $long
    $info = Normalize $long.FreezeDeviceInfoEntries(); $using = Normalize $long.FreezeUsingDeviceEntries()
    Check ($info -ceq ("device-info Vulkan0 1 1 " + ('A' * 128) + "`n") -and $using -ceq '') 'The 128-character description limit or the 256-character line limit was not enforced.'
    Check ($long.DeviceInfoLikeLines -eq 3 -and $long.DeviceInfoMalformedLines -eq 2 -and $long.UsingDeviceLikeLines -eq 2 -and $long.UsingDeviceMalformedLines -eq 2) 'Over-length lines were not counted as malformed.'
} finally { $long.Dispose() }

# ---- count bound: 16 entries of each shape, the rest dropped and flagged
$many = Start-FixtureChild @'
1..20 | ForEach-Object { Write-Output ('  - Dev' + $_ + ' : d (1 MiB, 1 MiB free)') }
1..18 | ForEach-Object { Write-Output 'llama_prepare_model_devices: using device Vulkan0 (d) (0000:03:00.0) - 1 MiB free' }
'@
try {
    Wait-FixtureChild $many
    $info = Normalize $many.FreezeDeviceInfoEntries(); $using = Normalize $many.FreezeUsingDeviceEntries()
    Check (@($info -split "`n" | Where-Object { $_ }).Count -eq 16 -and @($using -split "`n" | Where-Object { $_ }).Count -eq 16 -and $many.DeviceInfoOverflow -and $many.UsingDeviceOverflow -and
           $many.DeviceInfoLikeLines -eq 20 -and $many.UsingDeviceLikeLines -eq 18) 'The 16-entry bound or its overflow flag differs.'
    Check ($info -match 'Dev16 ' -and $info -notmatch 'Dev17 ') 'The first 16 entries were not the ones kept.'
} finally { $many.Dispose() }

# ---- freezing stops the capture: lines that arrive afterwards are neither retained nor counted
$late = Start-FixtureChild @'
Start-Sleep -Milliseconds 2000
Write-Output '  - Vulkan0 : late (1 MiB, 1 MiB free)'
Write-Output 'llama_prepare_model_devices: using device Vulkan0 (late) (0000:03:00.0) - 1 MiB free'
'@
try {
    $earlyInfo = $late.FreezeDeviceInfoEntries(); $earlyUsing = $late.FreezeUsingDeviceEntries()
    Wait-FixtureChild $late
    Check ($earlyInfo -ceq '' -and $earlyUsing -ceq '' -and $late.FreezeDeviceInfoEntries() -ceq '' -and $late.FreezeUsingDeviceEntries() -ceq '' -and $late.DeviceInfoLikeLines -eq 0 -and $late.UsingDeviceLikeLines -eq 0) 'Output after the freeze was captured or counted.'
} finally { $late.Dispose() }

# ---- a child that prints nothing relevant retains and counts nothing
$quiet = Start-FixtureChild "Write-Output 'listening on 127.0.0.1'; Write-Output 'prompt: secret'"
try {
    Wait-FixtureChild $quiet
    Check ($quiet.FreezeDeviceInfoEntries() -ceq '' -and $quiet.FreezeUsingDeviceEntries() -ceq '' -and $quiet.DeviceInfoLikeLines -eq 0 -and $quiet.UsingDeviceLikeLines -eq 0 -and
           $quiet.DeviceListCaptureDiagnostics() -match 'like=0, captured=0, malformed=0, dropped=0\), usingDevice\(like=0') 'Unrelated output was retained or counted.'
} finally { $quiet.Dispose() }

# ---- the capture is the only addition: the module still loads and the existing counters keep their types
Import-Module (Join-Path $repo 'src/FastLlm.psm1') -Force
Check ($null -ne (Get-Module FastLlm)) 'The module did not load with the extended ProcessHost.'
$source = [IO.File]::ReadAllText((Join-Path $repo 'src/ProcessHost.cs'))
Check ($source -notmatch '[^\x00-\x7f]') 'ProcessHost.cs must stay ASCII only.'
Check ($source.Contains('DeviceListMaxEntries = 16') -and $source.Contains('DeviceListMaxLineLength = 256') -and [regex]::Matches($source, 'TimeSpan\.FromMilliseconds\(100\)').Count -ge 4) 'The capture bounds or regex time limits are missing.'
Write-Host "Process host device-list capture assertions passed: $passes"
