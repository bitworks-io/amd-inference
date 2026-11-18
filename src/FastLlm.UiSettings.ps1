# The one reader of the window's model-switching opt-in (settings.json "allowSwitch"), shared by the control window (FastLlm.UiFlow.ps1)
# and the start at sign-in (FastLlm.SignInStart.ps1). Small on purpose: no forms, no Add-Type, no window state, no other file is loaded.
# Windows PowerShell 5.1 compatible.
Set-StrictMode -Version 2

# Whether the user allows switching models while FastLLM runs. Off by default. Only a readable JSON object that holds the JSON value true
# turns it on: an absent file, a file that does not parse, one that is not an object (PowerShell 7 hands back the one element of a
# one-element array as the document, so the text must begin with "{" and the parsed value must be a PSCustomObject), a folder or a link,
# a file over 16 KiB (the writer's limit), or any other value of allowSwitch (the text "true", 1) is off. Never throws.
function Get-FastLlmUiAllowSwitch {
    param([Parameter(Mandatory = $true)][string] $InstallRoot)
    try {
        $path = Join-Path $InstallRoot 'settings.json'
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -gt 16384) { return $false }
        $text = [IO.File]::ReadAllText($path)
        if (-not $text.TrimStart().StartsWith('{', [StringComparison]::Ordinal)) { return $false }
        $stored = $text | ConvertFrom-Json -ErrorAction Stop
        if ($stored -isnot [System.Management.Automation.PSCustomObject]) { return $false }
        $property = $stored.PSObject.Properties['allowSwitch']
        return [bool] ($null -ne $property -and $property.Value -is [bool] -and $property.Value)
    }
    catch { return $false }
}
