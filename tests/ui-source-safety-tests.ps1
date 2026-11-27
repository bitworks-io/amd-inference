#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
$checks=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:checks++}

# Constant-only markup for the parse check below; it also proves this suite's own table write passes the static rule.
. (Join-Path $root 'src/FastLlm.UiXaml.ps1')
$script:FastLlmUiXaml['Test.SourceSafetyGrid']=@'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"/>
'@

$ownName='tests/ui-source-safety-tests.ps1'
$loaderName='src/FastLlm.UiXaml.ps1'
$loaderFunction='New-FastLlmUiXamlElement'
$tableVar='script:FastLlmUiXaml'

function Get-RepoRelativePath([string]$Path){return $Path.Substring($root.Length).TrimStart('\','/').Replace('\','/')}
function Get-ScannedFiles{
    $files=@()
    $files+=Join-Path $root 'fast-llm-ui.ps1'
    foreach($d in 'src','tests','tests/helpers'){
        $dir=Join-Path $root $d
        if(Test-Path -LiteralPath $dir){$files+=@(Get-ChildItem -LiteralPath $dir -Filter '*.ps1' -File|Sort-Object Name|ForEach-Object{$_.FullName})}
    }
    return ,@($files)
}
function Read-Utf8([string]$Path){return [IO.File]::ReadAllText($Path)}
function Get-Ast([string]$Text){
    $errs=$null;$tokens=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errs)
    return $ast
}
# Each scanned file is read and parsed ONCE; every rule takes the cached AST (path -> @{ast;tokens;errors;text}).
function ConvertTo-ParsedText([string]$Text){
    $errs=$null;$tokens=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errs)
    return @{ast=$ast;tokens=$tokens;errors=$errs;text=$Text}
}
$script:ParseCache=@{}
$script:ParseCalls=0
function Get-ParsedFile([string]$Path){
    if(-not $script:ParseCache.ContainsKey($Path)){
        $script:ParseCalls++
        $script:ParseCache[$Path]=ConvertTo-ParsedText (Read-Utf8 $Path)
    }
    return $script:ParseCache[$Path]
}
# A scanned file that does not parse is a finding naming the file and its first error: the AST of a broken file is partial, so every other rule would silently skip what it cannot see.
function Get-ParseErrorFindings($Parsed,[string]$RelPath){
    $bad=New-Object System.Collections.ArrayList
    if($null -ne $Parsed['errors'] -and $Parsed['errors'].Count -gt 0){
        $first=$Parsed['errors'][0]
        [void]$bad.Add($RelPath+': does not parse (line '+$first.Extent.StartLineNumber+'): '+$first.Message)
    }
    return ,@($bad.ToArray())
}
function Test-TableVariable($Node){
    return ($Node -is [System.Management.Automation.Language.VariableExpressionAst]) -and ($Node.VariablePath.UserPath -ieq $tableVar)
}
# Exact table-name matching. Test-TableVariable stays case-insensitive on purpose (PowerShell variables are, so a re-cased write is still a write to the table and
# the write rules must see it). This rule is the strict one: every variable whose name is the table's, or within two edits of it, must be spelled exactly
# '$tableVar' (scope, name and case). A near-miss, a re-cased name or another scope is a finding, never a skip.
$script:NameDistanceMemo=@{}
function Get-NameDistance([string]$A,[string]$B){
    $key=$A+'|'+$B
    if($script:NameDistanceMemo.ContainsKey($key)){return $script:NameDistanceMemo[$key]}
    $prev=New-Object 'int[]' ($B.Length+1)
    for($j=0;$j -le $B.Length;$j++){$prev[$j]=$j}
    for($i=1;$i -le $A.Length;$i++){
        $cur=New-Object 'int[]' ($B.Length+1)
        $cur[0]=$i
        for($j=1;$j -le $B.Length;$j++){
            $cost=1
            if($A[$i-1] -eq $B[$j-1]){$cost=0}
            $cur[$j]=[Math]::Min([Math]::Min($cur[$j-1]+1,$prev[$j]+1),$prev[$j-1]+$cost)
        }
        $prev=$cur
    }
    $script:NameDistanceMemo[$key]=$prev[$B.Length]
    return $prev[$B.Length]
}
function Get-TableNameFindings([string]$Text,[string]$RelPath,$Ast=$null){
    $bad=New-Object System.Collections.ArrayList
    $ast=$Ast
    if($null -eq $ast){$ast=Get-Ast $Text}
    $tableName=$tableVar.Substring($tableVar.LastIndexOf(':')+1).ToLowerInvariant()
    foreach($v in @($ast.FindAll({param($n)$n -is [System.Management.Automation.Language.VariableExpressionAst]},$true))){
        $path=[string]$v.VariablePath.UserPath
        if($path -ceq $tableVar){continue}
        $name=$path.Substring($path.LastIndexOf(':')+1).ToLowerInvariant()
        if([Math]::Abs($name.Length-$tableName.Length) -gt 2){continue}
        if((Get-NameDistance $name $tableName) -le 2){[void]$bad.Add($RelPath+': a variable that is not exactly the XAML table name ('+$tableVar+'): $'+$path)}
    }
    return ,@($bad.ToArray())
}

function Get-LoaderFunctionExtent($Ast){
    $fn=@($Ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $loaderFunction},$true))
    if($fn.Count -ne 1){return $null}
    return $fn[0].Extent
}

# Every use of the XAML parser in one file's text: by AST (type names, string constants) and by raw text offset.
function Get-ParserUseOutside([string]$Text,[string]$RelPath,$Ast=$null){
    $bad=New-Object System.Collections.ArrayList
    $ast=$Ast
    if($null -eq $ast){$ast=Get-Ast $Text}
    $ext=$null
    if($RelPath -ceq $loaderName){$ext=Get-LoaderFunctionExtent $ast}
    $inside={param([int]$Offset)($null -ne $ext) -and $Offset -ge $ext.StartOffset -and $Offset -lt $ext.EndOffset}
    $hits=$ast.FindAll({param($n)
        ($n -is [System.Management.Automation.Language.TypeExpressionAst] -and $n.TypeName.FullName -like '*XamlReader') -or
        ($n -is [System.Management.Automation.Language.TypeConstraintAst] -and $n.TypeName.FullName -like '*XamlReader') -or
        ($n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -like '*XamlReader*') -or
        ($n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -and $n.Value -like '*XamlReader*')
    },$true)
    foreach($h in $hits){if(-not (& $inside $h.Extent.StartOffset)){[void]$bad.Add($RelPath+': parser AST use at offset '+$h.Extent.StartOffset)}}
    $i=0
    while(($i=$Text.IndexOf('XamlReader',$i,[StringComparison]::OrdinalIgnoreCase)) -ge 0){
        if(-not (& $inside $i)){[void]$bad.Add($RelPath+': parser text at offset '+$i)}
        $i+=10
    }
    return ,@($bad.ToArray())
}

# Every write to the XAML table in one file's text. Allowed: constant single-quoted here-string index assignments, and in the
# loader exactly one initialisation to an empty hashtable.
function Get-TableWriteFindings([string]$Text,[string]$RelPath,$Ast=$null){
    $bad=New-Object System.Collections.ArrayList
    $ast=$Ast
    if($null -eq $ast){$ast=Get-Ast $Text}
    $assigns=@($ast.FindAll({param($n)$n -is [System.Management.Automation.Language.AssignmentStatementAst]},$true))
    $inits=0
    foreach($a in $assigns){
        $left=$a.Left
        if($left -is [System.Management.Automation.Language.IndexExpressionAst] -and (Test-TableVariable $left.Target)){
            $r=$a.Right
            $ok=($a.Operator -eq [System.Management.Automation.Language.TokenKind]::Equals) -and
                ($r -is [System.Management.Automation.Language.CommandExpressionAst]) -and
                ($r.Expression -is [System.Management.Automation.Language.StringConstantExpressionAst]) -and
                ($r.Expression.StringConstantType -eq [System.Management.Automation.Language.StringConstantType]::SingleQuotedHereString)
            if(-not $ok){[void]$bad.Add($RelPath+': table entry is not a constant single-quoted here-string: '+$a.Extent.Text.Split("`n")[0])}
            $key=$left.Index
            $keyOk=($key -is [System.Management.Automation.Language.StringConstantExpressionAst]) -and
                (@([System.Management.Automation.Language.StringConstantType]::SingleQuoted,[System.Management.Automation.Language.StringConstantType]::DoubleQuoted) -contains $key.StringConstantType)
            if(-not $keyOk){[void]$bad.Add($RelPath+': table entry key is not a quoted constant string: '+$a.Extent.Text.Split("`n")[0])}
            continue
        }
        $hasVar=@($left.FindAll({param($n)Test-TableVariable $n},$true)).Count -gt 0
        if(-not $hasVar){continue}
        $isInit=($RelPath -ceq $loaderName) -and (Test-TableVariable $left) -and
            ($a.Operator -eq [System.Management.Automation.Language.TokenKind]::Equals) -and
            ($a.Right -is [System.Management.Automation.Language.CommandExpressionAst]) -and
            ($a.Right.Expression -is [System.Management.Automation.Language.HashtableAst]) -and
            ($a.Right.Expression.KeyValuePairs.Count -eq 0)
        if($isInit){$inits++}else{[void]$bad.Add($RelPath+': other write to the table: '+$a.Extent.Text.Split("`n")[0])}
    }
    if($RelPath -ceq $loaderName -and $inits -ne 1){[void]$bad.Add($RelPath+': expected exactly one initialisation, found '+$inits)}
    $calls=@($ast.FindAll({param($n)$n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and (Test-TableVariable $n.Expression) -and -not ($n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and @('ContainsKey','ContainsValue','get_Item','GetEnumerator') -contains $n.Member.Value)},$true))
    foreach($c in $calls){[void]$bad.Add($RelPath+': method call (not a read) on the table: '+$c.Extent.Text)}
    return ,@($bad.ToArray())
}

$files=Get-ScannedFiles
Check ($files.Count -ge 20) 'the scanned file set is found'

# 0. every scanned file parses (a broken file would skip every rule below), each parsed once
$parseBad=New-Object System.Collections.ArrayList
foreach($f in $files){
    foreach($b in (Get-ParseErrorFindings (Get-ParsedFile $f) (Get-RepoRelativePath $f))){[void]$parseBad.Add($b)}
}
Check ($parseBad.Count -eq 0) ('every scanned file parses ('+(($parseBad|Select-Object -First 3) -join ' | ')+')')

# 1. no .xaml files
$gitOk=$false
if(Get-Command git -ErrorAction SilentlyContinue){
    $listed=@(& git -C $root ls-files '*.xaml' 2>$null)
    if($LASTEXITCODE -eq 0){$gitOk=$true}
}
if(-not $gitOk){$listed=@(Get-ChildItem -LiteralPath $root -Recurse -Filter '*.xaml' -File -Force -ErrorAction SilentlyContinue|Where-Object{$_.FullName -notmatch '[\\/]\.git[\\/]'}|ForEach-Object{$_.FullName})}
Check (@($listed).Count -eq 0) 'no .xaml files are tracked'

# 2. one parser site
$parserBad=New-Object System.Collections.ArrayList
foreach($f in $files){
    $rel=Get-RepoRelativePath $f
    if($rel -ceq $ownName){continue}
    $pf=Get-ParsedFile $f
    foreach($b in (Get-ParserUseOutside $pf.text $rel $pf.ast)){[void]$parserBad.Add($b)}
}
Check ($parserBad.Count -eq 0) ('XAML is parsed in one place only ('+(($parserBad|Select-Object -First 3) -join ' | ')+')')
$loaderText=(Get-ParsedFile (Join-Path $root $loaderName)).text
Check ($loaderText -match 'Windows\.Markup\.XamlReader\]::Parse') 'the loader function does parse'

# 3 and 4. table writes
$writeBad=New-Object System.Collections.ArrayList
$nameBad=New-Object System.Collections.ArrayList
$tableEntries=0
foreach($f in $files){
    $rel=Get-RepoRelativePath $f
    $pf=Get-ParsedFile $f
    foreach($b in (Get-TableWriteFindings $pf.text $rel $pf.ast)){[void]$writeBad.Add($b)}
    foreach($b in (Get-TableNameFindings $pf.text $rel $pf.ast)){[void]$nameBad.Add($b)}
    $tableEntries+=@($pf.ast.FindAll({param($n)$n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.IndexExpressionAst] -and (Test-TableVariable $n.Left.Target)},$true)).Count
}
Check ($writeBad.Count -eq 0) ('XAML is constant markup only, written only by constant assignments ('+(($writeBad|Select-Object -First 3) -join ' | ')+')')
Check ($tableEntries -ge 1) 'at least one registered page is scanned'
Check ($nameBad.Count -eq 0) ('the XAML table is always named exactly '+$tableVar+' ('+(($nameBad|Select-Object -First 3) -join ' | ')+')')

# Non-vacuity: the rules flag what they should (synthetic text, never a committed file).
$dq='$script:FastLlmUiXaml[''X'']=@"'+"`n"+'<Grid/>'+"`n"+'"@'
Check ((Get-TableWriteFindings $dq 'tests/x.ps1').Count -eq 1) 'self-check: a double-quoted here-string entry is flagged'
Check ((Get-TableWriteFindings '$script:FastLlmUiXaml[''X'']=''<Grid/>''' 'tests/x.ps1').Count -eq 1) 'self-check: a plain string entry is flagged'
Check ((Get-TableWriteFindings '$script:FastLlmUiXaml[''X'']=$markup' 'tests/x.ps1').Count -eq 1) 'self-check: a variable entry is flagged'
Check ((Get-TableWriteFindings '$script:FastLlmUiXaml.Add(''X'',''y'')' 'tests/x.ps1').Count -eq 1) 'self-check: .Add is flagged'
Check ((Get-TableWriteFindings '$script:FastLlmUiXaml.Set_Item(''X'',''y'')' 'tests/x.ps1').Count -eq 1) 'self-check: .Set_Item is flagged'
Check ((Get-TableWriteFindings '$null=$script:FastLlmUiXaml.ContainsKey(''X'')' 'tests/x.ps1').Count -eq 0) 'self-check: a read method is allowed'
Check ((Get-TableWriteFindings '$script:FastLlmUiXaml+=@{X=1}' 'tests/x.ps1').Count -eq 1) 'self-check: += is flagged'
Check ((Get-TableWriteFindings '$script:FastLlmUiXaml=@{}' 'tests/x.ps1').Count -eq 1) 'self-check: a reassignment outside the loader is flagged'
Check ((Get-TableWriteFindings '$script:FastLlmUiXaml=@{}' $loaderName).Count -eq 0) 'self-check: the loader initialisation is allowed'
Check ((Get-TableWriteFindings '$script:FastLlmUiXaml=@{}; $script:FastLlmUiXaml=@{}' $loaderName).Count -ge 1) 'self-check: a second loader initialisation is flagged'
Check ((Get-TableWriteFindings ('$script:FastLlmUiXaml[''X'']=@'''+"`n"+'<Grid/>'+"`n"+'''@') 'tests/x.ps1').Count -eq 0) 'self-check: a single-quoted here-string entry is allowed'
$parserText='function Other{[Windows.Markup.XamlReader]::Parse($x)}'
Check ((Get-ParserUseOutside $parserText 'tests/x.ps1').Count -ge 1) 'self-check: a parser use outside the loader is flagged'
Check ((Get-ParserUseOutside $parserText $loaderName).Count -ge 1) 'self-check: a parser use in another function of the loader file is flagged'
Check ((Get-ParserUseOutside ('function '+$loaderFunction+'{[Windows.Markup.XamlReader]::Parse($x)}') $loaderName).Count -eq 0) 'self-check: the loader function may parse'
Check ((Get-ParserUseOutside '$t=''Windows.Markup.XamlReader''' 'tests/x.ps1').Count -ge 1) 'self-check: a parser name in a string is flagged'

# Item: exact table-name matching and constant keys.
$tableHere="`n"+'<Grid/>'+"`n"
Check ((Get-TableNameFindings '$script:FastLlmUiXaml[''X'']=1' 'tests/x.ps1').Count -eq 0) 'self-check: the exact table name is not a name finding'
Check ((Get-TableNameFindings '$script:FastLlmUiXaml2[''X'']=1' 'tests/x.ps1').Count -eq 1) 'self-check: a near-miss name (extra character) is flagged'
Check ((Get-TableNameFindings '$script:FastLlmUiXam[''X'']=1' 'tests/x.ps1').Count -eq 1) 'self-check: a near-miss name (missing character) is flagged'
Check ((Get-TableNameFindings '$script:FastLlmUiXamI[''X'']=1' 'tests/x.ps1').Count -eq 1) 'self-check: a near-miss name (look-alike letter) is flagged'
Check ((Get-TableNameFindings '$script:fastllmuixaml[''X'']=1' 'tests/x.ps1').Count -eq 1) 'self-check: a re-cased table name is flagged'
Check ((Get-TableNameFindings '$Script:FastLlmUiXaml[''X'']=1' 'tests/x.ps1').Count -eq 1) 'self-check: a re-cased scope is flagged'
Check ((Get-TableNameFindings '$global:FastLlmUiXaml[''X'']=1' 'tests/x.ps1').Count -eq 1) 'self-check: the table name in another scope is flagged'
Check ((Get-TableNameFindings '$FastLlmUiXaml[''X'']=1' 'tests/x.ps1').Count -eq 1) 'self-check: the table name with no scope is flagged'
Check ((Get-TableNameFindings '$script:FastLlmUiFluent=1; $script:uiDialogView=2; $tableVar=3' 'tests/x.ps1').Count -eq 0) 'self-check: unrelated variables are not flagged'
Check ((Get-TableWriteFindings '$script:fastllmuixaml[''X'']=$markup' 'tests/x.ps1').Count -eq 1) 'self-check: a re-cased table write is still seen by the write rules'
Check ((Get-TableWriteFindings ('$script:FastLlmUiXaml[$name]=@'''+$tableHere+'''@') 'tests/x.ps1').Count -eq 1) 'self-check: a key built from a variable is flagged'
Check ((Get-TableWriteFindings ('$script:FastLlmUiXaml["a$b"]=@'''+$tableHere+'''@') 'tests/x.ps1').Count -eq 1) 'self-check: a key built by string expansion is flagged'
Check ((Get-TableWriteFindings ('$script:FastLlmUiXaml[(''a''+''b'')]=@'''+$tableHere+'''@') 'tests/x.ps1').Count -eq 1) 'self-check: a key built by an expression is flagged'
Check ((Get-TableWriteFindings ('$script:FastLlmUiXaml[1]=@'''+$tableHere+'''@') 'tests/x.ps1').Count -eq 1) 'self-check: a numeric key is flagged'
Check ((Get-TableWriteFindings ('$script:FastLlmUiXaml["Test.X"]=@'''+$tableHere+'''@') 'tests/x.ps1').Count -eq 0) 'self-check: a double-quoted constant key is allowed'

# Item: parse errors are findings, and each file is parsed once.
$plantedBroken=ConvertTo-ParsedText 'function Broken { if ($x { }'
$brokenFindings=Get-ParseErrorFindings $plantedBroken 'tests/planted.ps1'
$brokenPrefix='tests/planted.ps1: does not parse (line 1): '
Check ($brokenFindings.Count -eq 1 -and $brokenFindings[0].StartsWith($brokenPrefix)) 'self-check: a planted file that does not parse is flagged with its file and first error'
Check ($brokenFindings.Count -eq 1 -and $brokenFindings[0].Length -gt $brokenPrefix.Length) 'self-check: the parse finding carries the error message'
Check ((Get-ParseErrorFindings (ConvertTo-ParsedText 'function Fine { 1 }') 'tests/fine.ps1').Count -eq 0) 'self-check: a file that parses is not flagged'
$callsBefore=$script:ParseCalls
$null=Get-ParsedFile $files[0]
$null=Get-ParsedFile $files[0]
$null=Get-ParsedFile $files[1]
Check ($script:ParseCalls -eq $callsBefore) 'self-check: a file already scanned is not parsed again'
Check ($script:ParseCalls -eq $script:ParseCache.Count -and $script:ParseCache.Count -ge $files.Count) 'every parse call cached a distinct file (no file parsed twice)'
Check ([object]::ReferenceEquals((Get-ParsedFile $files[0]).ast,(Get-ParsedFile $files[0]).ast)) 'self-check: the cached AST is the same object on every use'

# The safety assertion.
foreach($t in 'x:Class','x:Code','ObjectDataProvider','XmlDataProvider','clr-namespace:'){
    $threw=$false;$msg=''
    try{Assert-FastLlmUiXamlSafe -Xaml ('<Grid '+$t.ToUpperInvariant()+'="y"/>')}catch{$threw=$true;$msg=$_.Exception.Message}
    Check ($threw -and $msg -ceq ('Unsafe XAML: '+$t)) "rejects $t"
}
$threw=$false
try{Assert-FastLlmUiXamlSafe -Xaml '<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"/>'}catch{$threw=$true}
Check (-not $threw) 'plain markup passes'
$ns='xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"'
$refused=[ordered]@{
    'http image source'='<Image '+$ns+' Source="http://example.invalid/a.png"/>'
    'https resource dictionary'='<ResourceDictionary '+$ns+' Source="https://example.invalid/d.xaml"/>'
    'ftp source'='<Image '+$ns+' Source="ftp://example.invalid/x"/>'
    'file source'='<Image '+$ns+' Source="file:///C:/x.xaml"/>'
    'siteoforigin source'='<Image '+$ns+' Source="pack://siteoforigin:,,,/x.xaml"/>'
    'unc source'='<Image '+$ns+' Source="\\host\share\x.png"/>'
    'drive source'='<Image '+$ns+' Source="C:\x.png"/>'
    'relative source'='<Image '+$ns+' Source="images/x.png"/>'
    'property element source'='<Image '+$ns+'><Image.Source>http://example.invalid/a.png</Image.Source></Image>'
    'hyperlink navigate uri'='<TextBlock '+$ns+'><Hyperlink NavigateUri="https://example.invalid">x</Hyperlink></TextBlock>'
    'non-source attribute with a scheme'='<TextBlock '+$ns+' Tag="http://example.invalid/a"/>'
    'entity-encoded scheme'='<TextBlock '+$ns+' Tag="&#104;ttp://example.invalid/a"/>'
    'scheme with a space before slashes in a source'='<Image '+$ns+' Source="file: //host/x"/>'
    'uppercase scheme with leading space'='<TextBlock '+$ns+' Tag="  HTTP://example.invalid/a"/>'
    'cdata property element'='<Image '+$ns+'><Image.Source><![CDATA[http://example.invalid/a.png]]></Image.Source></Image>'
    'scheme without slashes'='<TextBlock '+$ns+' Tag="file:x"/>'
    'network path with forward slashes'='<TextBlock '+$ns+' Tag="//host/share/x"/>'
    'relative property element source'='<Image '+$ns+'><Image.Source>images/x.png</Image.Source></Image>'
}
foreach($k in $refused.Keys){
    $threw=$false;$msg=''
    try{Assert-FastLlmUiXamlSafe -Xaml $refused[$k]}catch{$threw=$true;$msg=$_.Exception.Message}
    Check ($threw -and $msg.StartsWith('Unsafe XAML: external reference')) "refuses $k"
}
$threw=$false;$msg=''
try{Assert-FastLlmUiXamlSafe -Xaml ('<!DOCTYPE x [<!ENTITY e "y">]><Grid '+$ns+'/>')}catch{$threw=$true;$msg=$_.Exception.Message}
Check ($threw -and $msg -ceq 'Unsafe XAML: DTD') 'refuses a DTD'
$threw=$false;$msg=''
try{Assert-FastLlmUiXamlSafe -Xaml ('<Grid '+$ns+'>')}catch{$threw=$true;$msg=$_.Exception.Message}
Check ($threw -and $msg -ceq 'Unsafe XAML: not well-formed XML') 'refuses markup that is not well-formed'
# Namespace allowlist and the denylist over decoded content. The designer-namespace markup (xmlns:d, xmlns:mc, mc:Ignorable)
# was allowed by a pin added earlier in this same PR; it is now refused, so no pre-existing expectation changes.
$nsPresentation='http://schemas.microsoft.com/winfx/2006/xaml/presentation'
$unsafeCases=[ordered]@{
    'entity-encoded clr-namespace (decimal)'='<Grid '+$ns+' xmlns:l="clr-namespace&#58;System;assembly=mscorlib"/>'
    'entity-encoded clr-namespace (hex)'='<Grid '+$ns+' xmlns:l="clr-namespace&#x3A;System;assembly=mscorlib"/>'
    'entity-encoded clr-namespace (mixed case)'='<Grid '+$ns+' xmlns:l="CLR-Namespace&#58;System;assembly=mscorlib"/>'
    'unknown prefixed namespace'='<Grid '+$ns+' xmlns:z="http://example.invalid/evil"/>'
    'unknown default namespace'='<Grid xmlns="http://example.invalid/x"/>'
    'designer namespaces'='<Grid '+$ns+' xmlns:d="http://schemas.microsoft.com/expression/blend/2008" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" mc:Ignorable="d"/>'
    'entity-encoded x:Code in text'='<TextBlock '+$ns+'>x&#58;Code</TextBlock>'
    'mapping instruction before the root'='<?Mapping XmlNamespace="urn:q" ClrNamespace="System" Assembly="mscorlib"?><Grid '+$ns+'/>'
    'mapping instruction inside the root'='<Grid '+$ns+'><?Mapping XmlNamespace="urn:q" ClrNamespace="System" Assembly="mscorlib"?></Grid>'
    'arbitrary processing instruction'='<Grid '+$ns+'><?foo bar?></Grid>'
    'xml:base relative'='<Grid '+$ns+' xml:base="foo/"/>'
    'unlisted namespace on a nested element'='<Grid '+$ns+'><Button xmlns:z="http://example.invalid/z"/></Grid>'
    'prefix redeclared to an unlisted uri on a child'='<Grid '+$ns+' xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"><Button xmlns:x="http://example.invalid/z"/></Grid>'
    'entity-encoded ObjectDataProvider in an attribute'='<Grid '+$ns+' Tag="Object&#68;ataProvider"/>'
}
foreach($k in $unsafeCases.Keys){
    $threw=$false;$msg=''
    try{Assert-FastLlmUiXamlSafe -Xaml $unsafeCases[$k]}catch{$threw=$true;$msg=$_.Exception.Message}
    Check ($threw -and $msg.StartsWith('Unsafe XAML:')) "refuses $k"
}
$piXaml='<?foo bar?><Grid '+$ns+'/>'
$baseXaml='<Grid '+$ns+' xml:base="foo/"/>'
function Test-RefusedWith([string]$Xaml,[string]$Expected){
    $threw=$false;$msg=''
    try{Assert-FastLlmUiXamlSafe -Xaml $Xaml}catch{$threw=$true;$msg=$_.Exception.Message}
    Check ($threw -and $msg -ceq $Expected) ('message: '+$Expected)
}
Test-RefusedWith $piXaml 'Unsafe XAML: processing instruction'
Test-RefusedWith $baseXaml "Unsafe XAML: attribute 'xml:base'"
$threw=$false;$msg=''
try{Assert-FastLlmUiXamlSafe -Xaml ('<Grid '+$ns+' xmlns:z="http://example.invalid/evil"/>')}catch{$threw=$true;$msg=$_.Exception.Message}
Check ($threw -and $msg -ceq "Unsafe XAML: namespace 'http://example.invalid/evil'") 'an unknown namespace is named in the message'
$threw=$false;$msg=''
try{Assert-FastLlmUiXamlSafe -Xaml ('<Grid xmlns="'+$nsPresentation+'/"/>')}catch{$threw=$true;$msg=$_.Exception.Message}
Check ($threw -and $msg.StartsWith('Unsafe XAML: namespace')) 'a namespace that differs by a trailing slash is refused'
$threw=$false;$msg=''
try{Assert-FastLlmUiXamlSafe -Xaml ('<Grid xmlns="'+$nsPresentation.ToUpperInvariant()+'"/>')}catch{$threw=$true;$msg=$_.Exception.Message}
Check ($threw -and $msg.StartsWith('Unsafe XAML: namespace')) 'a namespace that differs by case is refused'
$threw=$false;$msg=''
try{Assert-FastLlmUiXamlSafe -Xaml ('<Grid '+$ns+'><x:Code xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"/></Grid>')}catch{$threw=$true;$msg=$_.Exception.Message}
Check ($threw -and $msg -ceq 'Unsafe XAML: x:Code') 'a decoded element name carrying a token is refused'
$allowed=[ordered]@{
    'pack application source'='<Image '+$ns+' Source="pack://application:,,,/FastLlm;component/x.png"/>'
    'dynamic resource source'='<Image '+$ns+' Source="{DynamicResource X}"/>'
    'colon in content'='<Button '+$ns+' Content="Note: text"/>'
    'step text'='<TextBlock '+$ns+' Text="Step 3 of 4: Model"/>'
    'time, colour and font list'='<Border '+$ns+' Background="#FF123456" FontFamily="Segoe UI, Arial" Tag="0:0:1"/>'
    'text content'='<TextBlock '+$ns+'><Run>Note: text</Run></TextBlock>'
    'label starting with a scheme word'='<Button '+$ns+' Content="File: report"/>'
    'exact label File:'='<Button '+$ns+' Content="File:"/>'
    'exact label HTTP:'='<Button '+$ns+' Content="HTTP:"/>'
    'label starting with slashes'='<Button '+$ns+' Content="// note"/>'
    'xml declaration'='<?xml version="1.0" encoding="utf-8"?><Grid '+$ns+'/>'
    'xml:space'='<Grid '+$ns+' xml:space="preserve"/>'
    'xml:lang'='<Grid '+$ns+' xml:lang="en-US"/>'
    'x namespace'='<Grid '+$ns+' xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"/>'
    'property element binding'='<Image '+$ns+'><Image.Source>{DynamicResource X}</Image.Source></Image>'
}
foreach($k in $allowed.Keys){
    $threw=$false;$msg=''
    try{Assert-FastLlmUiXamlSafe -Xaml $allowed[$k]}catch{$threw=$true;$msg=$_.Exception.Message}
    Check (-not $threw) "passes $k"
}
$threw=$false;$msg=''
try{New-FastLlmUiXamlElement -Name 'Missing'|Out-Null}catch{$threw=$true;$msg=$_.Exception.Message}
Check ($threw -and $msg -ceq "Unknown XAML 'Missing'") 'unknown names are refused'
$script:FastLlmUiXaml['Test.SourceSafetyGrid']|Out-Null
. (Join-Path $root 'src/FastLlm.UiXaml.ps1')
Check ($script:FastLlmUiXaml.ContainsKey('Test.SourceSafetyGrid')) 'a second dot-source keeps registered entries'

# Windows only: a registered sample parses.
if($env:OS -eq 'Windows_NT'){
    Add-Type -AssemblyName PresentationFramework
    $el=New-FastLlmUiXamlElement -Name 'Test.SourceSafetyGrid'
    Check ($el -is [System.Windows.Controls.Grid]) 'a registered sample Grid parses to a WPF Grid'
}else{
    Write-Host 'SKIP: parsing a registered sample needs Windows and WPF'
}

# No event attribute in registered XAML: handlers are attached in code (the handler-by-name form needs a code-behind class the window does not have,
# and an attribute would run before the shell's own wiring). The names are the routed and CLR events of the controls the pages use.
$eventAttributeNames='Click|DoubleClick|Checked|Unchecked|Indeterminate|SelectionChanged|TextChanged|ValueChanged|Loaded|Unloaded|Initialized|KeyDown|KeyUp|TextInput|GotFocus|LostFocus|GotKeyboardFocus|LostKeyboardFocus|MouseDown|MouseUp|MouseMove|MouseEnter|MouseLeave|MouseLeftButtonDown|MouseLeftButtonUp|MouseRightButtonDown|MouseRightButtonUp|MouseWheel|TouchDown|TouchUp|Drop|DragEnter|DragLeave|DragOver|SizeChanged|IsEnabledChanged|IsVisibleChanged|DropDownOpened|DropDownClosed|Opened|Closed|Closing|Expanded|Collapsed|Executed|CanExecute|RequestNavigate|Navigated|Navigating|SourceUpdated|TargetUpdated|ContextMenuOpening|ToolTipOpening|ToolTipClosing|Activated|Deactivated|Tick|Scroll|ScrollChanged|Selected|Unselected|PasswordChanged|DataContextChanged|LayoutUpdated|DragDelta|Manipulation[A-Za-z]*|Stylus[A-Za-z]*'
# An attached form (Button.Click, TextBoxBase.TextChanged) is judged by the segment after its last dot; Validation.Error is the one event named Error; an EventSetter element is refused.
function Get-XamlEventAttributeFindings([string]$Xaml){
    $found=New-Object System.Collections.ArrayList
    $settings=New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing=[System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver=$null
    $reader=[System.Xml.XmlReader]::Create((New-Object System.IO.StringReader $Xaml),$settings)
    try{
        while($reader.Read()){
            if($reader.NodeType -ne [System.Xml.XmlNodeType]::Element -or -not $reader.HasAttributes){continue}
            $element=$reader.LocalName
            if($element -ceq 'EventSetter'){[void]$found.Add('EventSetter')}
            for($i=0;$i -lt $reader.AttributeCount;$i++){
                $reader.MoveToAttribute($i)|Out-Null
                $attributeName=$reader.LocalName
                $segment=$attributeName.Substring($attributeName.LastIndexOf('.')+1)
                if($reader.Prefix -ceq '' -and ($segment -cmatch ('^(Preview)?('+$eventAttributeNames+')$') -or $attributeName -ceq 'Validation.Error')){[void]$found.Add($element+'.'+$attributeName)}
            }
            $reader.MoveToElement()|Out-Null
        }
    }finally{$reader.Close()}
    return ,@($found.ToArray())
}
$registeredXaml=New-Object System.Collections.ArrayList
foreach($f in $files){
    $pf=Get-ParsedFile $f
    foreach($a in @($pf.ast.FindAll({param($n)$n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.IndexExpressionAst] -and (Test-TableVariable $n.Left.Target) -and $n.Right -is [System.Management.Automation.Language.CommandExpressionAst] -and $n.Right.Expression -is [System.Management.Automation.Language.StringConstantExpressionAst]},$true))){
        [void]$registeredXaml.Add([pscustomobject]@{File=(Get-RepoRelativePath $f);Xaml=[string]$a.Right.Expression.Value})
    }
}
Check ($registeredXaml.Count -ge 2) "the event-attribute rule sees the registered XAML ($($registeredXaml.Count) entries)"
$eventBad=New-Object System.Collections.ArrayList
foreach($r in $registeredXaml){
    # The synthetic Test.SourceSafetyGrid entry of this suite is a registered entry too; it has no attribute either.
    foreach($b in (Get-XamlEventAttributeFindings $r.Xaml)){[void]$eventBad.Add($r.File+': '+$b)}
}
Check ($eventBad.Count -eq 0) ('no registered XAML carries an event attribute ('+(($eventBad|Select-Object -First 3) -join ' | ')+')')
Check ((Get-XamlEventAttributeFindings ('<Button '+$ns+' Click="OnClick"/>')).Count -eq 1) 'self-check: Click="..." is flagged'
Check ((Get-XamlEventAttributeFindings ('<Grid '+$ns+'><TextBox TextChanged="T" KeyDown="K"/><CheckBox Checked="C" IsChecked="True"/></Grid>')).Count -eq 3) 'self-check: TextChanged, KeyDown and Checked are flagged, the IsChecked property is not'
Check ((Get-XamlEventAttributeFindings ('<Window '+$ns+' Loaded="L" Title="t"/>')).Count -eq 1) 'self-check: Loaded="..." is flagged'
Check ((Get-XamlEventAttributeFindings ('<Grid '+$ns+'><Button Button.Click="B"/></Grid>')).Count -eq 1) 'self-check: the attached form Button.Click="..." is flagged'
Check ((Get-XamlEventAttributeFindings ('<Grid '+$ns+'><TextBox PreviewKeyDown="K"/></Grid>')).Count -eq 1) 'self-check: PreviewKeyDown="..." is flagged'
Check ((Get-XamlEventAttributeFindings ('<Style '+$ns+'><EventSetter Event="Click" Handler="H"/></Style>')).Count -eq 1) 'self-check: an EventSetter element is refused'
Check ((Get-XamlEventAttributeFindings ('<Grid '+$ns+'><TextBox TextBoxBase.TextChanged="T"/></Grid>')).Count -eq 1) 'self-check: TextBoxBase.TextChanged="..." is flagged'
Check ((Get-XamlEventAttributeFindings ('<Grid '+$ns+'><PasswordBox PasswordChanged="P" Validation.Error="E" ManipulationDelta="M" StylusDown="S" LayoutUpdated="L" Selected="S2"/></Grid>')).Count -eq 6) 'self-check: PasswordChanged, Validation.Error, Manipulation, Stylus, LayoutUpdated and Selected are flagged'
Check ((Get-XamlEventAttributeFindings ('<Grid '+$ns+'><Button x:Name="B" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Content="Click" AutomationProperties.Name="Click"/></Grid>')).Count -eq 0) 'self-check: a property or content that only says Click is not flagged'

# ASCII
$asciiFiles='src/FastLlm.UiState.ps1','src/FastLlm.UiTheme.ps1','src/FastLlm.UiWindow.ps1','src/FastLlm.UiXaml.ps1','src/FastLlm.UiFluentAdapter.ps1','src/FastLlm.UiFluentSupport.ps1','src/FastLlm.UiFluentForm.ps1','src/FastLlm.UiFluentIcon.ps1','src/FastLlm.UiFluentHooks.ps1','src/FastLlm.UiFluentShell.ps1','src/FastLlm.UiFluentHome.ps1','src/FastLlm.UiFluentBindings.ps1','src/FastLlm.UiFluentTools.ps1','src/FastLlm.UiFluentConnect.ps1','src/FastLlm.UiFluentModels.ps1','src/FastLlm.UiFluentSettings.ps1','src/FastLlm.UiFluentDialogs.ps1','tests/helpers/UiFluentShellHarness.ps1','src/WindowsFluentWindow.cs','src/WindowsFluentAutomation.cs',
    'tests/ui-fluent-members-tests.ps1','tests/ui-fluent-parity-tests.ps1',
    'tests/ui-fluent-shell-tests.ps1','tests/ui-fluent-pages-tests.ps1','tests/helpers/FluentHostNative.cs',
    'tests/helpers/UiControlStatesMatrix.ps1','tests/helpers/New-UiControlStatesGolden.ps1','tests/ui-control-states-tests.ps1',
    'tests/ui-card-state-tests.ps1','tests/ui-fluent-adapter-tests.ps1','tests/ui-fluent-support-tests.ps1','tests/ui-theme-tests.ps1','tests/ui-window-tests.ps1','tests/ui-source-safety-tests.ps1',
    'tests/helpers/UiRenderHarness.ps1','tests/ui-render-tests.ps1'
# AccessibilityView is not a WPF API: markup or code that sets it fails at run time on the user's PC, so no file under src/ may contain it.
function Test-HasAccessibilityView([string]$Text){return ($Text.IndexOf('AccessibilityView',[StringComparison]::OrdinalIgnoreCase) -ge 0)}
Check (Test-HasAccessibilityView 'AutomationProperties.AccessibilityView="Raw"') 'self-check: the text AccessibilityView is flagged'
Check (Test-HasAccessibilityView 'x accessibilityview y') 'self-check: the text is matched case-insensitively'
Check (-not (Test-HasAccessibilityView 'IsControlElement')) 'self-check: unrelated text is not flagged'
foreach($f in @(Get-ChildItem -LiteralPath (Join-Path $root 'src') -File -Recurse)){
    Check (-not (Test-HasAccessibilityView ([IO.File]::ReadAllText($f.FullName)))) ('no AccessibilityView in '+(Get-RepoRelativePath $f.FullName))
}
function Test-AsciiBytes([byte[]]$Bytes){foreach($b in $Bytes){if($b -ge 0x80){return $false}};return $true}
Check (-not (Test-AsciiBytes ([byte[]](0x41,0xC3,0xA9)))) 'self-check: a non-ASCII byte is flagged'
foreach($rel in $asciiFiles){
    $p=Join-Path $root $rel
    Check (Test-Path -LiteralPath $p) "listed file exists: $rel"
    Check (Test-AsciiBytes ([IO.File]::ReadAllBytes($p))) "ASCII only: $rel"
}

# Pinned statements of the released window (fast-llm-ui.ps1 at 646ccb05).
function Get-Sha256Lf([string]$Text){
    $lf=$Text.Replace("`r`n","`n")
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($lf))|ForEach-Object{$_.ToString('x2')}) -join '')}finally{$sha.Dispose()}
}
function Get-AdminRefusalText($Ast){
    $ast=$Ast
    $m=@($ast.FindAll({param($n)$n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text.Contains('WindowsBuiltInRole]::Administrator')},$true))
    if($m.Count -ne 1){return $null}
    return $m[0].Extent.Text
}
function Get-CloseGuardsText($Ast){
    $ast=$Ast
    $m=@($ast.FindAll({param($n)
        $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Member.Value -ceq 'Add_FormClosing' -and
        $n.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.Expression.VariablePath.UserPath -ceq 'form' -and
        $n.Arguments.Count -eq 1 -and $n.Arguments[0] -is [System.Management.Automation.Language.ScriptBlockExpressionAst]},$true))
    if($m.Count -ne 1){return $null}
    return $m[0].Arguments[0].Extent.Text
}
$adminHash='7106c46006a2b9be7c633e1aeff49506a47ca0c12602539d17dbb9472b5a737f'
$closeHash='7a4a7c9923207fe9f2e83ee74e4e70aa2201ec7f77d2b9b6559a8a68f1b16ac4'
$windowParsed=Get-ParsedFile (Join-Path $root 'fast-llm-ui.ps1')
$adminText=Get-AdminRefusalText $windowParsed.ast
$closeText=Get-CloseGuardsText $windowParsed.ast
# PR 4a routes the handler's one confirmation through the ShowUiMessageBox view function (a named pair in the members suite, 'box close'). The guards
# are judged as text from before that seam: the pair is undone first, so the hash below is still today's, and any other edit still moves it.
$closeSeamCur="if((ShowUiMessageBox `$form 'Closing stops this window''s active download or inference process. Continue?' 'Close FastLLM' 'YesNo' 'Question') -ne 'Yes'){"
$closeSeamOrig="if([Windows.Forms.MessageBox]::Show(`$form,'Closing stops this window''s active download or inference process. Continue?','Close FastLLM','YesNo','Question') -ne 'Yes'){"
if($null -ne $closeText){
    Check (([regex]::Matches($closeText,[regex]::Escape($closeSeamCur))).Count -eq 1) 'the close handler holds the PR 4a confirmation seam exactly once'
    $closeText=$closeText.Replace($closeSeamCur,$closeSeamOrig)
}
Check ($null -ne $adminText) 'the admin refusal statement is found once'
Check ($null -ne $closeText) 'the FormClosing handler is found once'
Check ((Get-Sha256Lf $adminText) -ceq $adminHash) 'the admin refusal is unchanged'
Check ((Get-Sha256Lf $closeText) -ceq $closeHash) 'the close guards are unchanged'
Check ((Get-Sha256Lf $adminText) -cne (Get-Sha256Lf ($adminText.Replace('administrator','administratoR')))) 'self-check: a one-character change moves the admin hash'
Check ((Get-Sha256Lf $closeText) -cne (Get-Sha256Lf ($closeText+' '))) 'self-check: a one-character change moves the close-guard hash'

# A finder that ends in "return ,$x" hands its caller ONE array object; a caller that counts it as @(Finder ...) wraps that array again, so the count is always 1 and a
# mutation self-check like @(Get-X $mutant).Count -ge 1 passes whatever the finder does (found 2026-11-27 in the members suite). The caller must assign the finder
# (the array arrives intact) or write (Finder ...).Count.
function Get-CommaFinderNames([object[]]$Asts){
    $names=@{}
    foreach($ast in $Asts){
        foreach($fn in @($ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true))){
            $rets=@($fn.Body.FindAll({param($n)$n -is [System.Management.Automation.Language.ReturnStatementAst] -and $null -ne $n.Pipeline -and $n.Pipeline.Extent.Text.StartsWith(',')},$true))
            if($rets.Count -gt 0){$names[$fn.Name.ToLowerInvariant()]=$true}
        }
    }
    return $names
}
function Get-CommaFinderWrapFindings($Ast,[string]$RelPath,[hashtable]$Names){
    $bad=New-Object System.Collections.ArrayList
    foreach($arr in @($Ast.FindAll({param($n)$n -is [System.Management.Automation.Language.ArrayExpressionAst]},$true))){
        $st=@($arr.SubExpression.Statements)
        if($st.Count -ne 1 -or $st[0] -isnot [System.Management.Automation.Language.PipelineAst]){continue}
        $els=@($st[0].PipelineElements)
        if($els.Count -ne 1 -or $els[0] -isnot [System.Management.Automation.Language.CommandAst]){continue}
        $cn=[string]$els[0].GetCommandName()
        if($cn -ne '' -and $Names.ContainsKey($cn.ToLowerInvariant())){[void]$bad.Add($RelPath+':'+$arr.Extent.StartLineNumber+': @('+$cn+' ...) wraps a finder that returns ,array, so its count is always 1')}
    }
    return ,@($bad.ToArray())
}
$commaAsts=@($files|ForEach-Object{(Get-ParsedFile $_).ast})
$commaNames=Get-CommaFinderNames $commaAsts
Check ($commaNames.Count -ge 10) ('the comma-finder scan sees the finders that end in return ,array ('+$commaNames.Count+')')
$commaBad=New-Object System.Collections.ArrayList
foreach($f in $files){foreach($b in (Get-CommaFinderWrapFindings (Get-ParsedFile $f).ast (Get-RepoRelativePath $f) $commaNames)){[void]$commaBad.Add($b)}}
Check ($commaBad.Count -eq 0) ('no caller counts a ,array finder as @(Finder ...) ('+(($commaBad|Select-Object -First 3) -join ' | ')+')')
$commaPlantDef='function Get-Plant { $f=New-Object System.Collections.ArrayList; return ,$f.ToArray() }'+"`n"
$commaPlantNames=Get-CommaFinderNames @((Get-Ast $commaPlantDef))
Check ($commaPlantNames.ContainsKey('get-plant') -and $commaPlantNames.Count -eq 1) 'self-check: a function that returns ,array is a comma finder'
Check ((Get-CommaFinderWrapFindings (Get-Ast ($commaPlantDef+'$n=@(Get-Plant $x).Count')) 'tests/x.ps1' $commaPlantNames).Count -eq 1) 'self-check: @(Finder ...) around a comma finder is flagged'
Check ((Get-CommaFinderWrapFindings (Get-Ast ($commaPlantDef+'$n=@(get-plant).Count')) 'tests/x.ps1' $commaPlantNames).Count -eq 1) 'self-check: the finder name is matched case-insensitively'
Check ((Get-CommaFinderWrapFindings (Get-Ast ($commaPlantDef+'$r=Get-Plant $x; $n=$r.Count')) 'tests/x.ps1' $commaPlantNames).Count -eq 0) 'self-check: assigning the finder is not flagged'
Check ((Get-CommaFinderWrapFindings (Get-Ast ($commaPlantDef+'$n=(Get-Plant $x).Count')) 'tests/x.ps1' $commaPlantNames).Count -eq 0) 'self-check: (Finder ...).Count is not flagged'
Check ((Get-CommaFinderWrapFindings (Get-Ast ($commaPlantDef+'$n=@((Get-Plant $x)).Count')) 'tests/x.ps1' $commaPlantNames).Count -eq 0) 'self-check: @((Finder ...)) with the inner parentheses is not flagged'
$plainDef='function Get-Plain { return $x }'+"`n"
Check ((Get-CommaFinderWrapFindings (Get-Ast ($plainDef+'$n=@(Get-Plain).Count')) 'tests/x.ps1' (Get-CommaFinderNames @((Get-Ast $plainDef)))).Count -eq 0) 'self-check: @(Finder ...) around a finder without the comma is not flagged'

Write-Host "UI source safety tests passed: $checks"
exit 0
