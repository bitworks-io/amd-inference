# b10698: src/llama.cpp llama_prepare_model_devices prints the GGML device_id
# selected by the model load. For Vulkan, ggml-vulkan.cpp supplies a full PCI
# BDF only when VK_EXT_pci_bus_info is available. This is same-child selection
# evidence, not proof of operation placement or dedicated-memory residency.
function ConvertFrom-FastLlmSelectedDeviceIdentity {
    param(
        [AllowEmptyString()][string] $Text,
        [string[]] $ExpectedDevices,
        [int] $LikeLines,
        [int] $MalformedLines,
        [bool] $Overflow = $false
    )
    $observed = @()
    $reason = $null
    $expected = @($ExpectedDevices)
    if ($expected.Count -lt 1 -or $expected.Count -gt 8 -or
        @($expected | Where-Object { $_ -cnotmatch '^Vulkan[0-9]{1,2}$' }).Count -gt 0 -or
        @($expected | Select-Object -Unique).Count -ne $expected.Count) {
        $reason = 'invalid-expected-devices'
    } elseif ($LikeLines -lt 0 -or $MalformedLines -lt 0 -or $LikeLines -gt 1000000 -or $MalformedLines -gt $LikeLines) {
        $reason = 'invalid-capture-counts'
    } elseif ($Overflow) {
        $reason = 'identity-capture-overflow'
    } elseif ($MalformedLines -gt 0) {
        $reason = 'malformed-selected-device-line'
    }
    $lines = @($Text -split "`r?`n" | Where-Object { $_ -ne '' })
    if ($null -eq $reason) {
        if ($lines.Count -gt 16 -or $lines.Count -ne $LikeLines) {
            $reason = 'selected-device-count-mismatch'
        } else {
            foreach ($line in $lines) {
                if ($line -cnotmatch '^selected-device (Vulkan[0-9]{1,2}) ([0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7])$') {
                    $reason = 'malformed-normalized-identity'
                    break
                }
                $observed += [pscustomobject]@{ device=$Matches[1]; pciBdf=$Matches[2] }
            }
        }
    }
    if ($null -eq $reason) {
        if ($observed.Count -ne $expected.Count) {
            $reason = 'missing-or-extra-selected-device'
        } elseif (@($observed | Select-Object -ExpandProperty device -Unique).Count -ne $observed.Count -or
                  @($observed | Select-Object -ExpandProperty pciBdf -Unique).Count -ne $observed.Count) {
            $reason = 'duplicate-selected-device-identity'
        } else {
            foreach ($device in $expected) {
                if (@($observed | Where-Object { $_.device -ceq $device }).Count -ne 1) {
                    $reason = 'unexpected-selected-device'
                    break
                }
            }
        }
    }
    [pscustomobject]@{
        source = 'same-child-model-selection-log'
        identityVerified = ($null -eq $reason)
        failureReason = $reason
        selectedDevices = @($observed)
        physicalIdentityVerified = $false
        physicalResidencyVerified = $false
        operationPlacementVerified = $false
    }
}
