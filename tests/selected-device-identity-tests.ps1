#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$parser = Join-Path $repo 'src/FastLlm.SelectedDeviceIdentity.ps1'
$tokens = $null; $errors = $null
$null = [Management.Automation.Language.Parser]::ParseFile($parser, [ref]$tokens, [ref]$errors)
if (@($errors).Count) { throw ('Selected-device parser errors: ' + (@($errors | ForEach-Object Message) -join ' | ')) }
. $parser
$passes = 0
function Check($ok, $message) { if (-not $ok) { throw $message }; $script:passes++ }
$line0 = 'selected-device Vulkan0 0000:03:00.0'
$line1 = 'selected-device Vulkan1 0000:04:00.0'
$good = ConvertFrom-FastLlmSelectedDeviceIdentity -Text ($line0+"`n"+$line1) -ExpectedDevices @('Vulkan1','Vulkan0') -LikeLines 2 -MalformedLines 0
Check ($good.identityVerified -and $good.selectedDevices.Count -eq 2 -and -not $good.physicalResidencyVerified -and -not $good.operationPlacementVerified) 'Unique same-child identities failed or overstated.'
Check (-not (ConvertFrom-FastLlmSelectedDeviceIdentity -Text '' -ExpectedDevices @('Vulkan0') -LikeLines 0 -MalformedLines 0).identityVerified) 'Missing identity passed.'
Check (-not (ConvertFrom-FastLlmSelectedDeviceIdentity -Text $line0 -ExpectedDevices @('Vulkan0') -LikeLines 2 -MalformedLines 1).identityVerified) 'Valid plus malformed line passed.'
Check (-not (ConvertFrom-FastLlmSelectedDeviceIdentity -Text ($line0+"`n"+$line0) -ExpectedDevices @('Vulkan0') -LikeLines 2 -MalformedLines 0).identityVerified) 'Duplicate line passed.'
Check (-not (ConvertFrom-FastLlmSelectedDeviceIdentity -Text ($line0+"`n"+'selected-device Vulkan1 0000:03:00.0') -ExpectedDevices @('Vulkan0','Vulkan1') -LikeLines 2 -MalformedLines 0).identityVerified) 'Duplicate BDF passed.'
Check (-not (ConvertFrom-FastLlmSelectedDeviceIdentity -Text $line0 -ExpectedDevices @('Vulkan1') -LikeLines 1 -MalformedLines 0).identityVerified) 'Unexpected device passed.'
Check (-not (ConvertFrom-FastLlmSelectedDeviceIdentity -Text $line0 -ExpectedDevices @('Vulkan0') -LikeLines 1 -MalformedLines 0 -Overflow $true).identityVerified) 'Overflow passed.'
Check (-not (ConvertFrom-FastLlmSelectedDeviceIdentity -Text 'selected-device Vulkan0 unknown id' -ExpectedDevices @('Vulkan0') -LikeLines 1 -MalformedLines 0).identityVerified) 'Unknown BDF passed.'
Check (-not (ConvertFrom-FastLlmSelectedDeviceIdentity -Text $line0 -ExpectedDevices @('Vulkan0','Vulkan0') -LikeLines 1 -MalformedLines 0).identityVerified) 'Duplicate expected device passed.'
if (-not ('Bitworks.FastLlm.ProcessHost' -as [type])) { Add-Type -Path (Join-Path $repo 'src/ProcessHost.cs') -ErrorAction Stop }
$modulePath = Join-Path $repo 'src/FastLlm.psm1'
Import-Module $modulePath -Force
$module = Get-Module FastLlm
$child = New-Object Bitworks.FastLlm.ProcessHost
try {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = (Get-Process -Id $PID).Path
    $command = @'
Write-Output 'I llama_prepare_model_devices: using device Vulkan0 (AMD Radeon RX 7900 XTX) (0000:03:00.0) - 20000 MiB free'
Write-Output 'I llama_prepare_model_devices: using device Vulkan1 (path/to/unsafe) (0000:04:00.0) - 18000 MiB free'
Write-Output 'I llama_prepare_model_devices: using device Vulkan2 (AMD Radeon) (unknown id) - 16000 MiB free'
Write-Output 'I llama_prepare_model_devices: using device Vulkan3 (AMD Radeon) (0000:05:00.0) - NaN MiB free'
Write-Output 'prompt secret content'
'@
    $info.Arguments = & $module {param($A) Join-FastLlmProcessArguments $A} @('-NoLogo','-NoProfile','-Command',$command)
    $child.Start($info)
    Check ($child.Process.WaitForExit(10000)) 'Disposable child did not exit.'
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while (-not $child.OutputCompleted -and $deadline.ElapsedMilliseconds -lt 3000) { Start-Sleep -Milliseconds 20 }
    Check $child.OutputCompleted 'Child output did not complete.'
    $text = $child.FreezeSelectedDeviceIdentity()
    Check ($text -eq "selected-device Vulkan0 0000:03:00.0`nselected-device Vulkan1 0000:04:00.0`n" -or
           $text -eq "selected-device Vulkan0 0000:03:00.0`r`nselected-device Vulkan1 0000:04:00.0`r`n") 'Capture lost normalized identity or retained descriptions.'
    Check ($text -notmatch 'path|secret|Radeon|unknown|NaN' -and $child.SelectedDeviceLikeLines -eq 4 -and
           $child.SelectedDeviceMalformedLines -eq 2 -and $child.SelectedDeviceUnknownIdLines -eq 1 -and
           $child.SelectedDeviceBadFormatLines -eq 1 -and -not $child.SelectedDeviceIdentityOverflow) 'Malformed/secret output escaped bounded capture.'
    Check ($child.SelectedDeviceIdentityDiagnostics() -match 'unknownId=1, badFormat=1' -and
           $child.SelectedDeviceIdentityDiagnostics() -notmatch 'Radeon|path|secret|Vulkan') 'Reason-only diagnostics leaked native text.'
    $evidence = ConvertFrom-FastLlmSelectedDeviceIdentity -Text $text -ExpectedDevices @('Vulkan0','Vulkan1') -LikeLines $child.SelectedDeviceLikeLines -MalformedLines $child.SelectedDeviceMalformedLines -Overflow $child.SelectedDeviceIdentityOverflow
    Check (-not $evidence.identityVerified -and $evidence.failureReason -eq 'malformed-selected-device-line') 'Malformed same-child lines passed verification.'
} finally { $child.Dispose() }
$validChild = New-Object Bitworks.FastLlm.ProcessHost
try {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = (Get-Process -Id $PID).Path
    $command = @'
Write-Output 'I llama_prepare_model_devices: using device Vulkan1 (AMD Radeon RX 7900 XT) (0000:04:00.0) - 18000 MiB free'
Write-Output 'I llama_prepare_model_devices: using device Vulkan0 (AMD Radeon RX 7900 XTX) (0000:03:00.0) - 20000 MiB free'
'@
    $info.Arguments = & $module {param($A) Join-FastLlmProcessArguments $A} @('-NoLogo','-NoProfile','-Command',$command)
    $validChild.Start($info)
    Check ($validChild.Process.WaitForExit(10000)) 'Valid disposable child did not exit.'
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while (-not $validChild.OutputCompleted -and $deadline.ElapsedMilliseconds -lt 3000) { Start-Sleep -Milliseconds 20 }
    Check $validChild.OutputCompleted 'Valid child output did not complete.'
    $text = $validChild.FreezeSelectedDeviceIdentity()
    $evidence = ConvertFrom-FastLlmSelectedDeviceIdentity -Text $text -ExpectedDevices @('Vulkan0','Vulkan1') -LikeLines $validChild.SelectedDeviceLikeLines -MalformedLines $validChild.SelectedDeviceMalformedLines -Overflow $validChild.SelectedDeviceIdentityOverflow
    Check ($evidence.identityVerified -and -not $evidence.physicalIdentityVerified -and $evidence.selectedDevices.Count -eq 2 -and
           $validChild.SelectedDeviceUnknownIdLines -eq 0 -and $validChild.SelectedDeviceBadFormatLines -eq 0) 'Valid same-child identity was not recognized conservatively.'
} finally { $validChild.Dispose() }
Write-Host "Selected-device identity assertions passed: $passes"
