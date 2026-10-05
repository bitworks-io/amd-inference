# A presentation of the dated advisory, never an installed-driver qualification.
function Format-FastLlmDriverGuidance {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Guidance)
    if ($Guidance.schemaVersion -ne 1 -or $Guidance.qualification -ne $false -or
        $Guidance.automaticDriverInstall -ne $false -or $Guidance.hasOwnTrustedMapping -ne $false) {
        throw 'Driver guidance is not an unqualified read-only advisory.'
    }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add("Driver guidance checked: $($Guidance.asOf)")
    $lines.Add("Windows display name: $($Guidance.inputGpuName)")
    $reported = if ($Guidance.reportedPnpDriverVersion) { $Guidance.reportedPnpDriverVersion } else { 'Unavailable' }
    $lines.Add("Reported driver version: $reported")
    $lines.Add('')
    if ($Guidance.knownFocusModel) {
        Assert-FastLlmOfficialAmdUrl -Value $Guidance.productUrl -Field 'productUrl'
        $lines.Add("AMD baseline: $($Guidance.recommended.name) - $($Guidance.recommended.channel)")
        $lines.Add("Released: $($Guidance.recommended.releaseDate)")
        if ($Guidance.optional) {
            $lines.Add("Optional package: $($Guidance.optional.name) - $($Guidance.optional.channel)")
            $lines.Add("Released: $($Guidance.optional.releaseDate)")
        } else { $lines.Add('No optional package recorded in this dated snapshot.') }
        $lines.Add('')
        $lines.Add("Suggested install style: $($Guidance.suggestedInstallMode)")
        $lines.Add([string]$Guidance.installModeReason)
    } else {
        $lines.Add('No exact focus-model match. Use AMD support to identify the right package.')
    }
    if ($Guidance.note) { $lines.Add(''); $lines.Add([string]$Guidance.note) }
    $lines.Add('')
    $lines.Add('Confirm the current recommendation on AMD''s page before installing.')
    $lines.Add('This display record is not matched to the serving GPU. The installed driver is not certified or marked current by this lookup.')
    $lines.Add('No driver is downloaded or installed here. Install style is a feature/UI preference, not a measured speed improvement.')
    return $lines -join [Environment]::NewLine
}
