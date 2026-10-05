#requires -Version 5.1
param([ValidateSet('single','duplicate','overflow','oversized-record')][string]$Mode='single')
$report=[ordered]@{
    schemaVersion=1;applicable=$true;qualified=$false;stableAcrossCollection=$true
    identityScope='independent-process-address-scope-advisory';pciSegmentKnown=$false
    ggmlJoin=$null;ggmlJoinReason='unknown-pci-segment';ggmlEvidenceStatus='unavailable';ggmlDeviceCount=$null
    matches=@([ordered]@{luid='00000001000000ab';vendorId=4098;deviceId=29772;
        addressScope='bus-device-function-only';pciSegmentKnown=$false;bus=3;device=0;function=0;
        status='address-scope-dxgi-pnp';pnpInstanceId='PCI\VEN_1002&DEV_744C&SUBSYS_00000000\1';
        driverVersion='32.0.31041.1004';ggmlDevice=$null;ggmlJoin=$null;ggmlJoinReason='unknown-pci-segment';
        serverProcessBound=$false;qualificationApproved=$false})
}
$line='FASTLLM_PCI_IDENTITY_JSON:'+($report|ConvertTo-Json -Depth 8 -Compress)
if($Mode -eq 'oversized-record'){$line='FASTLLM_PCI_IDENTITY_JSON:'+((@{padding=('X'*9000)}|ConvertTo-Json -Compress))}
Write-Output $line
if($Mode -eq 'duplicate'){Write-Output $line}
if($Mode -eq 'overflow'){for($i=0;$i -lt 400;$i++){Write-Output ('X'*1024)}}
