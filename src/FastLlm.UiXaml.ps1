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
    $denyTokens=@('x:Class','x:Code','ObjectDataProvider','XmlDataProvider','clr-namespace:')
    foreach ($token in $denyTokens) {
        if ($Xaml.IndexOf($token,[System.StringComparison]::OrdinalIgnoreCase) -ge 0) { throw ('Unsafe XAML: '+$token) }
    }
    # The same denylist over DECODED content: an entity such as clr-namespace&#58; only becomes the token after the XML reader decodes it.
    $denyDecoded={
        param([string]$Value)
        foreach ($token in $denyTokens) {
            if ($Value.IndexOf($token,[System.StringComparison]::OrdinalIgnoreCase) -ge 0) { throw ('Unsafe XAML: '+$token) }
        }
    }
    # Only these namespaces may be declared (ordinal compare, after decoding).
    $allowedNamespaces=@('http://schemas.microsoft.com/winfx/2006/xaml/presentation','http://schemas.microsoft.com/winfx/2006/xaml')
    # An empty string now fails below as 'not well-formed XML'; that is intended, since an empty entry would not parse anyway.
    # Markup may not load anything from a URI: parse as XML (no DTD, no resolver) and check every value.
    $uriNames=@('Source','ImageSource','UriSource','NavigateUri','BaseUri','Uri')
    $fetchPatterns=@('^[a-z][a-z0-9+.-]*://','^(?:http|https|ftp|file):(?=\S)','^\\\\','^//(?=\S)','^[a-z]:[\\/]')
    $check={
        param([string]$Value,[bool]$UriTyped)
        $v=$Value.Trim()
        if ($v.Length -eq 0) { return }
        $bad=$false
        foreach ($p in $fetchPatterns) {
            if ([regex]::IsMatch($v,$p,[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) { $bad=$true }
        }
        if ($bad -and $v.StartsWith('pack://application:',[System.StringComparison]::OrdinalIgnoreCase)) { $bad=$false }
        if ($UriTyped -and -not ($v.StartsWith('pack://application:',[System.StringComparison]::OrdinalIgnoreCase) -or $v.StartsWith('{'))) { $bad=$true }
        if ($bad) { throw ("Unsafe XAML: external reference '"+$v+"'") }
    }
    $settings=New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing=[System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver=$null
    $sr=New-Object System.IO.StringReader($Xaml)
    $reader=$null
    $parents=New-Object System.Collections.ArrayList
    try {
        $reader=[System.Xml.XmlReader]::Create($sr,$settings)
        while ($reader.Read()) {
            if ($reader.NodeType -eq [System.Xml.XmlNodeType]::Element) {
                $empty=$reader.IsEmptyElement
                $local=$reader.LocalName
                & $denyDecoded $reader.Name
                if ($reader.MoveToFirstAttribute()) {
                    do {
                        & $denyDecoded $reader.Name
                        & $denyDecoded $reader.Value
                        if (($reader.Prefix -ceq 'xml') -and -not (@('space','lang') -ccontains $reader.LocalName)) { throw ("Unsafe XAML: attribute '"+$reader.Name+"'") }
                        if (($reader.Name -ceq 'xmlns') -or ($reader.Prefix -ceq 'xmlns')) {
                            if (-not ($allowedNamespaces -ccontains $reader.Value)) { throw ("Unsafe XAML: namespace '"+$reader.Value+"'") }
                            continue
                        }
                        & $check $reader.Value ($uriNames -contains $reader.LocalName)
                    } while ($reader.MoveToNextAttribute())
                    [void]$reader.MoveToElement()
                }
                if (-not $empty) { [void]$parents.Add($local) }
            } elseif ($reader.NodeType -eq [System.Xml.XmlNodeType]::ProcessingInstruction) {
                # A mapping instruction can make CLR types reachable without any xmlns the allowlist would see.
                throw 'Unsafe XAML: processing instruction'
            } elseif ($reader.NodeType -eq [System.Xml.XmlNodeType]::EndElement) {
                if ($parents.Count -gt 0) { $parents.RemoveAt($parents.Count-1) }
            } elseif (($reader.NodeType -eq [System.Xml.XmlNodeType]::Text) -or ($reader.NodeType -eq [System.Xml.XmlNodeType]::CDATA)) {
                & $denyDecoded $reader.Value
                $typed=$false
                if ($parents.Count -gt 0) {
                    $pn=[string]$parents[$parents.Count-1]
                    $typed=($uriNames -contains $pn.Substring($pn.LastIndexOf('.')+1)) -and ($pn.IndexOf('.') -ge 0)
                }
                & $check $reader.Value $typed
            }
        }
    } catch [System.Xml.XmlException] {
        if (($Xaml.IndexOf('<!DOCTYPE',[System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or ($Xaml.IndexOf('<!ENTITY',[System.StringComparison]::OrdinalIgnoreCase) -ge 0)) { throw 'Unsafe XAML: DTD' }
        throw 'Unsafe XAML: not well-formed XML'
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        $sr.Dispose()
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
