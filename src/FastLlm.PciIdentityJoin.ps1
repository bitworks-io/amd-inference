# Standalone advisory join. Never imported by the planner or normal benchmark.
function ConvertFrom-FastLlmPciLocation {
    param([string]$Text)
    if([string]::IsNullOrWhiteSpace($Text) -or $Text.Length -gt 128){return $null}
    $segment=0;$explicit=$false
    if($Text -cmatch '^PCI segment ([0-9]{1,5}) bus ([0-9]{1,3}), device ([0-9]{1,2}), function ([0-9])$'){
        $segment=[int]$Matches[1];$bus=[int]$Matches[2];$device=[int]$Matches[3];$function=[int]$Matches[4];$explicit=$true
    }elseif($Text -cmatch '^PCI bus ([0-9]{1,3}), device ([0-9]{1,2}), function ([0-9])$'){
        $bus=[int]$Matches[1];$device=[int]$Matches[2];$function=[int]$Matches[3]
    }else{return $null}
    if($segment -gt 65535 -or $bus -gt 255 -or $device -gt 31 -or $function -gt 7){return $null}
    return [pscustomobject]@{segment=$segment;segmentExplicit=$explicit;bus=$bus;device=$device;function=$function;
        addressKey=('{0}:{1}:{2}' -f $bus,$device,$function)}
}

function ConvertFrom-FastLlmPciInstanceId {
    param([string]$Text)
    if([string]::IsNullOrWhiteSpace($Text) -or $Text.Length -gt 512 -or
       $Text -cnotmatch '^PCI\\VEN_([0-9A-Fa-f]{4})&DEV_([0-9A-Fa-f]{4})(?:&|\\)'){return $null}
    return [pscustomobject]@{vendorId=[Convert]::ToUInt32($Matches[1],16);deviceId=[Convert]::ToUInt32($Matches[2],16)}
}

function Join-FastLlmPciAddressScope {
    param([object[]]$Dxgi,[object[]]$Pnp,[object[]]$Kmt)
    if(@($Dxgi).Count -gt 64 -or @($Pnp).Count -gt 128 -or @($Kmt).Count -gt 64){throw 'PCI identity snapshot exceeds bounded adapter counts.'}
    $pnpRows=@()
    foreach($item in @($Pnp)){
        $location=ConvertFrom-FastLlmPciLocation ([string]$item.LocationInfo)
        $ids=ConvertFrom-FastLlmPciInstanceId ([string]$item.InstanceId)
        if($location -and $ids){$pnpRows+= [pscustomobject]@{record=$item;location=$location;ids=$ids}}
    }
    $results=@()
    foreach($adapter in @($Dxgi)){
        $luid=[string]$adapter.Luid
        if($luid -cnotmatch '^[0-9a-fA-F]{16}$' -or [long]$adapter.VendorId -lt 0 -or [long]$adapter.VendorId -gt 65535 -or
           [long]$adapter.DeviceId -lt 0 -or [long]$adapter.DeviceId -gt 65535){throw 'DXGI adapter identity has invalid LUID or PCI IDs.'}
        $row=[ordered]@{luid=$luid.ToLowerInvariant();vendorId=[long]$adapter.VendorId;deviceId=[long]$adapter.DeviceId;
            addressScope='bus-device-function-only';pciSegmentKnown=$false;bus=$null;device=$null;function=$null;
            status='unmatched';pnpInstanceId=$null;driverVersion=$null;ggmlDevice=$null;ggmlJoin=$null;
            ggmlJoinReason='unknown-pci-segment';serverProcessBound=$false;qualificationApproved=$false}
        if(@($Dxgi | Where-Object { [string]$_.Luid -ieq $luid }).Count -ne 1){$row.status='ambiguous-dxgi-luid';$results+=[pscustomobject]$row;continue}
        $kmtHits=@($Kmt | Where-Object { [string]$_.Luid -ieq $luid })
        if($kmtHits.Count -ne 1 -or $kmtHits[0].Error -or $null -eq $kmtHits[0].Bus -or $null -eq $kmtHits[0].Device -or $null -eq $kmtHits[0].Function){
            $row.status='missing-kmt-address';$results+=[pscustomobject]$row;continue
        }
        $bus=[long]$kmtHits[0].Bus;$device=[long]$kmtHits[0].Device;$function=[long]$kmtHits[0].Function
        if($bus -lt 0 -or $bus -gt 255 -or $device -lt 0 -or $device -gt 31 -or $function -lt 0 -or $function -gt 7){
            $row.status='invalid-kmt-address';$results+=[pscustomobject]$row;continue
        }
        $row.bus=$bus;$row.device=$device;$row.function=$function
        $addressKey='{0}:{1}:{2}' -f $bus,$device,$function
        if(@($Kmt | Where-Object { $null -ne $_.Bus -and $null -ne $_.Device -and $null -ne $_.Function -and
            [long]$_.Bus -eq $bus -and [long]$_.Device -eq $device -and [long]$_.Function -eq $function }).Count -ne 1){
            $row.status='ambiguous-kmt-address';$results+=[pscustomobject]$row;continue
        }
        $addressRows=@($pnpRows | Where-Object { $_.location.addressKey -ceq $addressKey })
        if($addressRows.Count -ne 1){$row.status=if($addressRows.Count){'ambiguous-pnp-address'}else{'missing-pnp-address'};$results+=[pscustomobject]$row;continue}
        $candidate=$addressRows[0]
        if($candidate.ids.vendorId -ne $row.vendorId -or $candidate.ids.deviceId -ne $row.deviceId){
            $row.status='pci-id-mismatch';$results+=[pscustomobject]$row;continue
        }
        $unknownPeers=@($Pnp | Where-Object {
            $peerIds=ConvertFrom-FastLlmPciInstanceId ([string]$_.InstanceId)
            $peerIds -and $peerIds.vendorId -eq $row.vendorId -and $peerIds.deviceId -eq $row.deviceId -and
            -not (ConvertFrom-FastLlmPciLocation ([string]$_.LocationInfo))
        })
        if($unknownPeers.Count){$row.status='unlocated-pnp-peer';$results+=[pscustomobject]$row;continue}
        if($candidate.record.LocationError -or $candidate.record.DriverVersionError -or
           [string]::IsNullOrWhiteSpace([string]$candidate.record.DriverVersion) -or
           [string]$candidate.record.DriverVersion -cnotmatch '^[0-9]+(?:\.[0-9]+){1,5}$'){
            $row.status='missing-driver-version';$results+=[pscustomobject]$row;continue
        }
        $row.status='address-scope-dxgi-pnp'
        $row.pnpInstanceId=[string]$candidate.record.InstanceId
        $row.driverVersion=[string]$candidate.record.DriverVersion
        $results+=[pscustomobject]$row
    }
    return @($results)
}

function Assert-FastLlmPciIdentityDocument {
    param($Document)
    if($Document.schemaVersion -ne 1 -or $Document.applicable -isnot [bool] -or $Document.applicable -ne $true -or
       $Document.qualified -isnot [bool] -or $Document.qualified -ne $false -or
       $Document.identityScope -cne 'independent-process-address-scope-advisory' -or
       $Document.pciSegmentKnown -isnot [bool] -or $Document.pciSegmentKnown -ne $false -or $null -ne $Document.ggmlJoin -or
       $Document.ggmlJoinReason -cne 'unknown-pci-segment' -or
       $Document.stableAcrossCollection -isnot [bool] -or @($Document.matches).Count -gt 64 -or
       (-not $Document.stableAcrossCollection -and @($Document.matches).Count)){
        throw 'Invalid PCI identity advisory document.'
    }
    foreach($row in @($Document.matches)){
        if($row.luid -cnotmatch '^[0-9a-f]{16}$' -or $row.status -notin @('unmatched','ambiguous-dxgi-luid',
            'missing-kmt-address','invalid-kmt-address','ambiguous-kmt-address','missing-pnp-address',
            'ambiguous-pnp-address','pci-id-mismatch','unlocated-pnp-peer','missing-driver-version','address-scope-dxgi-pnp') -or
           $row.pciSegmentKnown -isnot [bool] -or $row.pciSegmentKnown -ne $false -or
           $null -ne $row.ggmlJoin -or $null -ne $row.ggmlDevice -or
           $row.ggmlJoinReason -cne 'unknown-pci-segment' -or
           $row.serverProcessBound -isnot [bool] -or $row.serverProcessBound -ne $false -or
           $row.qualificationApproved -isnot [bool] -or $row.qualificationApproved -ne $false -or
           [long]$row.vendorId -lt 0 -or [long]$row.vendorId -gt 65535 -or
           [long]$row.deviceId -lt 0 -or [long]$row.deviceId -gt 65535 -or
           ($null -ne $row.bus -and ([long]$row.bus -lt 0 -or [long]$row.bus -gt 255)) -or
           ($null -ne $row.device -and ([long]$row.device -lt 0 -or [long]$row.device -gt 31)) -or
           ($null -ne $row.function -and ([long]$row.function -lt 0 -or [long]$row.function -gt 7))){
            throw 'PCI advisory row claims unsupported identity evidence.'
        }
        if($row.status -eq 'address-scope-dxgi-pnp'){
            if($row.pnpInstanceId -cnotmatch '^PCI\\VEN_[0-9A-Fa-f]{4}&DEV_[0-9A-Fa-f]{4}(?:&|\\)' -or
               [int]$row.pnpInstanceId.Length -gt 512 -or
               [string]$row.driverVersion -cnotmatch '^[0-9]+(?:\.[0-9]+){1,5}$' -or
               [int]$row.driverVersion.Length -gt 64 -or
               $null -eq $row.bus -or $null -eq $row.device -or $null -eq $row.function){
                throw 'Matched PCI advisory row lacks exact address/driver evidence.'
            }
        }elseif($null -ne $row.pnpInstanceId -or $null -ne $row.driverVersion){
            throw 'Unmatched PCI advisory row carries a PnP driver claim.'
        }
    }
}

function ConvertFrom-FastLlmPciJoinOutput {
    param([string]$OutputText,[bool]$WasTruncated)
    if($WasTruncated -or $OutputText.Length -gt 65536){throw 'PCI identity worker output incomplete or oversized.'}
    if(@($OutputText -split "`r?`n" | Where-Object { $_.StartsWith('FASTLLM_PCI_IDENTITY_JSON:') -and $_.Length -gt 7800 }).Count){
        throw 'PCI identity result exceeds the per-line capture bound.'
    }
    $records=@([regex]::Matches($OutputText,'(?m)^FASTLLM_PCI_IDENTITY_JSON:(\{[^\r\n]*\})\r?$'))
    if($records.Count -ne 1){throw 'PCI identity worker returned missing or ambiguous result marker.'}
    if($records[0].Value.Length -gt 7800){throw 'PCI identity result exceeds the per-line capture bound.'}
    $document=ConvertFrom-Json $records[0].Groups[1].Value
    Assert-FastLlmPciIdentityDocument $document
    return $document
}
