# Card identity for recipe matching: PCI vendor, device and revision from DXGI plus the dedicated-VRAM total.
# Never the marketed name. Unmatched or ambiguous cards get no recipe (the planner's estimated choice applies).
Set-StrictMode -Version 2

$script:FastLlmVariantVramToleranceMiB = 512
$script:FastLlmGpuVariantFields = @('key', 'vendorId', 'deviceId', 'revisionIds', 'vramMiBMin', 'vramMiBMax', 'confirmed')

function Get-FastLlmGpuVariants {
    param([Parameter(Mandatory = $true)][string] $Path)
    $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($document.schema -ne 'bitworks.fastllm-gpu-variants/v1') { throw 'gpu-variants.json has an unexpected schema.' }
    foreach ($variant in @($document.variants)) {
        foreach ($field in $script:FastLlmGpuVariantFields) {
            if (-not $variant.PSObject.Properties[$field]) { throw "gpu-variants.json: a variant is missing '$field'." }
        }
    }
    return @($document.variants)
}

function ConvertTo-FastLlmHexId {
    param($Value, [int] $Digits)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) {
        $text = $Value.Trim() -replace '^0[xX]', ''
        if ($text -notmatch '^[0-9A-Fa-f]+$') { return $null }
        return $text.ToUpperInvariant().PadLeft($Digits, '0')
    }
    return ('{0:X}' -f [uint32] $Value).PadLeft($Digits, '0')
}

function Get-FastLlmDxgiCardVariant {
    param([Parameter(Mandatory = $true)] $Adapter, [Parameter(Mandatory = $true)][object[]] $Variants)
    $vendor = ConvertTo-FastLlmHexId $Adapter.vendorId 4
    $device = ConvertTo-FastLlmHexId $Adapter.deviceId 4
    $revision = ConvertTo-FastLlmHexId $Adapter.revision 2
    $vram = [int64] $Adapter.dedicatedVideoMiB
    $hits = @($Variants | Where-Object {
            ([string] $_.vendorId).ToUpperInvariant() -eq $vendor -and ([string] $_.deviceId).ToUpperInvariant() -eq $device -and
            (@($_.revisionIds | ForEach-Object { ([string] $_).ToUpperInvariant() }) -contains $revision) -and
            $vram -ge [int64] $_.vramMiBMin -and $vram -le [int64] $_.vramMiBMax })
    if ($hits.Count -eq 1) { return [string] $hits[0].key }
    return $null
}

function Resolve-FastLlmAdapterVariant {
    param([Parameter(Mandatory = $true)] $PlannerAdapter, [object[]] $DxgiAdapters, [Parameter(Mandatory = $true)][object[]] $Variants)
    $result = [ordered]@{ variant = $null; status = 'unmatched'; candidates = 0 }
    if (-not $DxgiAdapters -or @($DxgiAdapters).Count -eq 0) { $result.status = 'no-identity'; return [pscustomobject] $result }
    $total = [int64] $PlannerAdapter.vramMiB
    $near = @($DxgiAdapters | Where-Object {
            (ConvertTo-FastLlmHexId $_.vendorId 4) -eq '1002' -and [Math]::Abs([int64] $_.dedicatedVideoMiB - $total) -le $script:FastLlmVariantVramToleranceMiB })
    $result.candidates = $near.Count
    if ($near.Count -eq 0) { return [pscustomobject] $result }
    $keys = @($near | ForEach-Object {
            $key = Get-FastLlmDxgiCardVariant -Adapter $_ -Variants $Variants
            if ($null -eq $key) { '<none>' } else { $key } } | Sort-Object -Unique)
    if ($keys.Count -eq 1 -and $keys[0] -ne '<none>') { $result.variant = [string] $keys[0]; $result.status = 'matched' }
    elseif ($keys.Count -gt 1) { $result.status = 'ambiguous' }
    return [pscustomobject] $result
}

function Get-FastLlmDxgiCardIdentities {
    # Live Windows only. Identity fields only: no LUID (boot-scoped), no names, no instance IDs. Failure means no identity.
    # DXGI is read through Get-FastLlmWindowsInventory (the bounded child process); WindowsInventory.ps1 is a standalone
    # worker script and cannot be dot-sourced into the module.
    try {
        $inventory = Get-FastLlmWindowsInventory
        if (-not $inventory -or -not $inventory.PSObject.Properties['dxgi']) { return @() }
        return @(@($inventory.dxgi) | Where-Object { $null -ne $_ } | ForEach-Object {
                [pscustomobject] [ordered] @{ vendorId = [int] $_.VendorId; deviceId = [int] $_.DeviceId; revision = [int] $_.Revision
                    dedicatedVideoMiB = [int64] ([uint64] $_.DedicatedVideoBytes / 1MB) } })
    }
    catch { return @() }
}
