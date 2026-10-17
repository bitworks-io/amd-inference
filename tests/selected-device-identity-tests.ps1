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
# An engine-reported "unknown id" is a well-formed line without an id: never verified, never mapped to an adapter, reported with its own reason.
$unk = ConvertFrom-FastLlmSelectedDeviceIdentity -Text '' -ExpectedDevices @('Vulkan0') -LikeLines 1 -MalformedLines 0 -UnknownIdLines 1
Check (-not $unk.identityVerified -and $unk.failureReason -ceq 'engine-reported-unknown-device-id' -and @($unk.selectedDevices).Count -eq 0 -and -not $unk.physicalIdentityVerified) 'An unknown device id was not reported with its own reason.'
$mixed = ConvertFrom-FastLlmSelectedDeviceIdentity -Text $line0 -ExpectedDevices @('Vulkan0','Vulkan1') -LikeLines 2 -MalformedLines 0 -UnknownIdLines 1
Check (-not $mixed.identityVerified -and $mixed.failureReason -ceq 'engine-reported-unknown-device-id') 'A known id next to an unknown id was verified.'
$unkBad = ConvertFrom-FastLlmSelectedDeviceIdentity -Text '' -ExpectedDevices @('Vulkan0') -LikeLines 2 -MalformedLines 1 -UnknownIdLines 1
Check (-not $unkBad.identityVerified -and $unkBad.failureReason -ceq 'malformed-selected-device-line') 'A genuinely malformed line next to an unknown id lost its reason.'
Check ((ConvertFrom-FastLlmSelectedDeviceIdentity -Text '' -ExpectedDevices @('Vulkan0') -LikeLines 1 -MalformedLines 0 -UnknownIdLines 2).failureReason -ceq 'invalid-capture-counts') 'More unknown-id lines than selected lines was accepted.'
Check ((ConvertFrom-FastLlmSelectedDeviceIdentity -Text $line0 -ExpectedDevices @('Vulkan0') -LikeLines 1 -MalformedLines 0).identityVerified) 'The old call shape without UnknownIdLines stopped working.'
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
           $child.SelectedDeviceMalformedLines -eq 1 -and $child.SelectedDeviceUnknownIdLines -eq 1 -and
           $child.SelectedDeviceBadFormatLines -eq 1 -and -not $child.SelectedDeviceIdentityOverflow) 'Malformed/secret output escaped bounded capture.'
    Check ($child.SelectedDeviceIdentityDiagnostics() -match 'unknownId=1, badFormat=1' -and
           $child.SelectedDeviceIdentityDiagnostics() -notmatch 'Radeon|path|secret|Vulkan') 'Reason-only diagnostics leaked native text.'
    $evidence = ConvertFrom-FastLlmSelectedDeviceIdentity -Text $text -ExpectedDevices @('Vulkan0','Vulkan1') -LikeLines $child.SelectedDeviceLikeLines -MalformedLines $child.SelectedDeviceMalformedLines -UnknownIdLines $child.SelectedDeviceUnknownIdLines -Overflow $child.SelectedDeviceIdentityOverflow
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
# The real current-engine line shapes (llama.cpp b11658), through the real capture.
function Capture-RealLines([string]$Body) {
    $c = New-Object Bitworks.FastLlm.ProcessHost
    $i = New-Object Diagnostics.ProcessStartInfo
    $i.FileName = (Get-Process -Id $PID).Path
    $i.Arguments = & $module {param($A) Join-FastLlmProcessArguments $A} @('-NoLogo','-NoProfile','-Command',$Body)
    $c.Start($i)
    Check ($c.Process.WaitForExit(10000)) 'Real-shape child did not exit.'
    $d = [Diagnostics.Stopwatch]::StartNew()
    while (-not $c.OutputCompleted -and $d.ElapsedMilliseconds -lt 3000) { Start-Sleep -Milliseconds 20 }
    Check $c.OutputCompleted 'Real-shape child output did not complete.'
    return $c
}
foreach ($prefix in @('llama_prepare_model_devices')) {
    $vk = Capture-RealLines ("Write-Output '$prefix" + ": using device Vulkan0 (AMD Radeon RX 7900 XT) (unknown id) - 19653 MiB free'")
    try {
        $vkText = $vk.FreezeSelectedDeviceIdentity()
        $vkEvidence = ConvertFrom-FastLlmSelectedDeviceIdentity -Text $vkText -ExpectedDevices @('Vulkan0') -LikeLines $vk.SelectedDeviceLikeLines -MalformedLines $vk.SelectedDeviceMalformedLines -UnknownIdLines $vk.SelectedDeviceUnknownIdLines -Overflow $vk.SelectedDeviceIdentityOverflow
        Check ($vk.SelectedDeviceIdentityDiagnostics() -ceq 'like=1, captured=0, malformed=0, unknownId=1, badFormat=0, dropped=0') "The Vulkan unknown-id line ($prefix) is not counted as malformed."
        Check (-not $vkEvidence.identityVerified -and $vkEvidence.failureReason -ceq 'engine-reported-unknown-device-id' -and @($vkEvidence.selectedDevices).Count -eq 0) "The Vulkan unknown-id line ($prefix) did not give the unknown-id reason."
        Check ($vkText -notmatch 'Radeon|19653') 'The unknown-id capture kept the description.'
    } finally { $vk.Dispose() }
    $hip = Capture-RealLines ("Write-Output '$prefix" + ": using device ROCm0 (AMD Radeon RX 7900 XT) (0000:03:00.0) - 20301 MiB free'")
    try {
        Check ($hip.SelectedDeviceIdentityDiagnostics() -ceq 'like=1, captured=1, malformed=0, unknownId=0, badFormat=0, dropped=0') "The HIP-shape line ($prefix) is not captured."
        Check ((($hip.FreezeSelectedDeviceIdentity()).Replace("`r`n","`n")) -ceq "selected-device ROCm0 0000:03:00.0`n") 'The HIP-shape capture kept more than the name and address.'
    } finally { $hip.Dispose() }
}
$bad = Capture-RealLines @'
Write-Output 'llama_prepare_model_devices: using device Vulkan0 (AMD Radeon RX 7900 XT) (not a bdf) - 19653 MiB free'
Write-Output 'llama_prepare_model_devices: using device Vulkan1 (AMD Radeon RX 7900 XT) (0000:03:00.0) - lots MiB free'
Write-Output 'llama_prepare_model_devices: using device CUDA0 (x) (0000:03:00.0) - 5 MiB free'
'@
try {
    Check ($bad.SelectedDeviceIdentityDiagnostics() -ceq 'like=3, captured=0, malformed=3, unknownId=0, badFormat=3, dropped=0') 'Genuinely malformed lines stopped being malformed.'
    $badEvidence = ConvertFrom-FastLlmSelectedDeviceIdentity -Text ($bad.FreezeSelectedDeviceIdentity()) -ExpectedDevices @('Vulkan0') -LikeLines $bad.SelectedDeviceLikeLines -MalformedLines $bad.SelectedDeviceMalformedLines -UnknownIdLines $bad.SelectedDeviceUnknownIdLines -Overflow $false
    Check (-not $badEvidence.identityVerified -and $badEvidence.failureReason -ceq 'malformed-selected-device-line') 'Malformed lines are not fail-closed.'
} finally { $bad.Dispose() }
Write-Host "Selected-device identity assertions passed: $passes"
