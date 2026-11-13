# Prototype (not loaded by FastLlm.psm1): pick the display adapter that holds OUR llama-server child's memory, for the HIP engine
# where no adapter LUID is known. Pure rule over per-adapter observations, no native calls.
Set-StrictMode -Version 2

function Select-FastLlmProcessAdapter {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()][object[]] $Observations,
        [uint64] $MinTotalBytes = 1073741824
    )
    # An observation counts only when it has no error and both byte values. Total committed = dedicated + shared (saturating, never wraps).
    # Exactly one adapter at or above the minimum identifies the server's adapter; none or several never guess.
    try {
        $readings = 0
        $candidates = @()
        foreach ($observation in @($Observations)) {
            if ($null -eq $observation) { continue }
            $props = $observation.PSObject.Properties
            if ($null -eq $props['Luid'] -or $null -eq $props['DedicatedBytes'] -or $null -eq $props['SharedBytes']) { continue }
            if ($null -ne $props['Error'] -and -not [string]::IsNullOrEmpty([string] $props['Error'].Value)) { continue }
            if ($null -eq $props['DedicatedBytes'].Value -or $null -eq $props['SharedBytes'].Value) { continue }
            if ([string]::IsNullOrEmpty([string] $props['Luid'].Value)) { continue }
            [uint64] $dedicated = 0
            [uint64] $shared = 0
            try { $dedicated = [uint64] $props['DedicatedBytes'].Value; $shared = [uint64] $props['SharedBytes'].Value } catch { continue }
            $readings++
            [uint64] $total = [uint64]::MaxValue
            if ($dedicated -le ([uint64]::MaxValue - $shared)) { $total = $dedicated + $shared }
            if ($total -ge $MinTotalBytes) { $candidates += [string] $props['Luid'].Value }
        }
        if ($readings -eq 0) { return [pscustomobject]@{ Luid = $null; Reason = 'no-readings' } }
        if ($candidates.Count -eq 1) { return [pscustomobject]@{ Luid = $candidates[0]; Reason = $null } }
        if ($candidates.Count -eq 0) { return [pscustomobject]@{ Luid = $null; Reason = 'adapter-not-identified' } }
        return [pscustomobject]@{ Luid = $null; Reason = 'adapter-ambiguous' }
    } catch {
        return [pscustomobject]@{ Luid = $null; Reason = 'no-readings' }
    }
}
