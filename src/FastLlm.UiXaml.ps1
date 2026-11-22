#requires -Version 5.1
# Constant-only XAML loader. Markup lives only in single-quoted here-strings assigned to
# $script:FastLlmUiXaml['<Name>']; no runtime string is ever put into markup. This is the only
# place that parses XAML. Callers load PresentationFramework first (Initialize-FastLlmUiWindowInterop or Add-Type).

# Keep entries registered before a second dot-source.
if (($null -eq (Get-Variable -Name FastLlmUiXaml -Scope Script -ValueOnly -ErrorAction SilentlyContinue)) -or -not ($script:FastLlmUiXaml -is [hashtable])) {
    $script:FastLlmUiXaml=@{}
}

function Assert-FastLlmUiXamlSafe {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Xaml)
    foreach ($token in @('x:Class','x:Code','ObjectDataProvider','XmlDataProvider','clr-namespace:')) {
        if ($Xaml.IndexOf($token,[System.StringComparison]::OrdinalIgnoreCase) -ge 0) { throw ('Unsafe XAML: '+$token) }
    }
}

function New-FastLlmUiXamlElement {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Name)
    if (-not $script:FastLlmUiXaml.ContainsKey($Name)) { throw ("Unknown XAML '"+$Name+"'") }
    $markup=[string]$script:FastLlmUiXaml[$Name]
    Assert-FastLlmUiXamlSafe -Xaml $markup
    return [Windows.Markup.XamlReader]::Parse($markup)
}
