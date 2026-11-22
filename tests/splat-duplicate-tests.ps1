#requires -Version 5.1
# Splat-duplicate guard: Windows PowerShell 5.1 throws ParameterAlreadyBound when a call splats a hashtable and also names one of its keys
# (Get-Thing @common -Key $x with Key in $common); PowerShell 7 lets the named argument win silently, so only the 5.1 job notices. This suite finds
# every such call with the PowerShell parser (never a text search) on every shell. Keys are resolved only when they are literal: the nearest
# assignment to the variable before the call, in the innermost enclosing function or script block (then outward), when its right side is a literal
# hashtable (or an [ordered]/[hashtable] cast of one), plus constant keys set on it afterwards in that scope ($v.Key = , $v['Key'] = , $v.Add('Key', ),
# minus $v.Remove('Key')). Anything else contributes no keys. The fixtures under tests/fixtures/splat-duplicates are parsed, never executed.
# Pure parsing; no engine, GPU or network.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Split-Path $PSScriptRoot -Parent
$script:count=0
function Check($Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:count++;Write-Host "PASS: $Message"}

function Test-Ast($Node,[string]$TypeName) { return ($null -ne $Node -and $Node.GetType().Name -ceq $TypeName) }
function Get-ConstantText($Node) { if (Test-Ast $Node 'StringConstantExpressionAst') { return [string]$Node.Value }; return $null }
# The innermost function body or script block that holds a node (the file itself is the outermost one).
function Get-EnclosingScope($Node) {
    $p=$Node.Parent
    while ($null -ne $p -and -not (Test-Ast $p 'ScriptBlockAst')) { $p=$p.Parent }
    return $p
}
# The variable name a node assigns or reads, looking through a type cast ([hashtable]$v = ...); $null for anything else.
function Get-VariableName($Node) {
    while (Test-Ast $Node 'ConvertExpressionAst') { $Node=$Node.Child }
    if (Test-Ast $Node 'VariableExpressionAst') { return $Node.VariablePath.UserPath }
    return $null
}
# The literal string keys of a hashtable expression, or $null when the expression is not a literal hashtable (or an [ordered]/[hashtable] cast of one).
function Get-LiteralHashtableKeys($Expression) {
    while (Test-Ast $Expression 'ConvertExpressionAst') {
        $type=$Expression.Type.TypeName.Name
        if ($type -ine 'ordered' -and $type -ine 'hashtable' -and $type -ine 'System.Collections.Hashtable') { return $null }
        $Expression=$Expression.Child
    }
    if (-not (Test-Ast $Expression 'HashtableAst')) { return $null }
    $keys=@()
    foreach ($pair in $Expression.KeyValuePairs) {
        $text=Get-ConstantText $pair.Item1
        if ($null -ne $text) { $keys+=$text }
    }
    return ,$keys
}
function Test-ScopeDeclaresParameter($Scope,[string]$Name) {
    $list=@()
    if ($null -ne $Scope.ParamBlock) { $list+=@($Scope.ParamBlock.Parameters) }
    if ((Test-Ast $Scope.Parent 'FunctionDefinitionAst') -and $null -ne $Scope.Parent.Parameters) { $list+=@($Scope.Parent.Parameters) }
    foreach ($parameter in $list) { if ($parameter.Name.VariablePath.UserPath -ieq $Name) { return $true } }
    return $false
}
# The literal keys a splatted variable holds at a call: the nearest earlier assignment in the innermost scope that assigns it (then outward), and the
# constant keys added or removed on it between that assignment and the call in the same scope. Unresolvable values contribute no keys.
function Get-SplatKeys($Call,[string]$Name,$Assignments,$Members) {
    $callStart=$Call.Extent.StartOffset
    $scope=Get-EnclosingScope $Call
    while ($null -ne $scope) {
        $best=$null
        foreach ($a in $Assignments) {
            if ($a.Operator.ToString() -cne 'Equals') { continue }
            if ((Get-VariableName $a.Left) -ine $Name) { continue }
            if ($a.Extent.EndOffset -gt $callStart) { continue }
            if ((Get-EnclosingScope $a) -ne $scope) { continue }
            if ($null -eq $best -or $a.Extent.EndOffset -gt $best.Extent.EndOffset) { $best=$a }
        }
        if ($null -ne $best) {
            $set=@{}
            if (Test-Ast $best.Right 'CommandExpressionAst') {
                $literal=Get-LiteralHashtableKeys $best.Right.Expression
                if ($null -ne $literal) { foreach ($k in $literal) { $set[$k]=$true } }
            }
            $events=@()
            foreach ($a in $Assignments) {
                if ($a.Operator.ToString() -cne 'Equals') { continue }
                if ($a.Extent.StartOffset -lt $best.Extent.EndOffset -or $a.Extent.EndOffset -gt $callStart) { continue }
                if ((Get-EnclosingScope $a) -ne $scope) { continue }
                $left=$a.Left; $key=$null
                if ((Test-Ast $left 'MemberExpressionAst') -and (Get-VariableName $left.Expression) -ieq $Name) { $key=Get-ConstantText $left.Member }
                elseif ((Test-Ast $left 'IndexExpressionAst') -and (Get-VariableName $left.Target) -ieq $Name) { $key=Get-ConstantText $left.Index }
                if ($null -ne $key) { $events+=[pscustomobject]@{ Offset=$a.Extent.StartOffset; Key=$key; Add=$true } }
            }
            foreach ($m in $Members) {
                if ($m.Extent.StartOffset -lt $best.Extent.EndOffset -or $m.Extent.EndOffset -gt $callStart) { continue }
                if ((Get-VariableName $m.Expression) -ine $Name -or $null -eq $m.Arguments -or $m.Arguments.Count -lt 1) { continue }
                $method=Get-ConstantText $m.Member
                $key=Get-ConstantText $m.Arguments[0]
                if ($null -eq $key -or $null -eq $method -or (Get-EnclosingScope $m) -ne $scope) { continue }
                if ($method -ieq 'Add') { $events+=[pscustomobject]@{ Offset=$m.Extent.StartOffset; Key=$key; Add=$true } }
                elseif ($method -ieq 'Remove') { $events+=[pscustomobject]@{ Offset=$m.Extent.StartOffset; Key=$key; Add=$false } }
            }
            foreach ($e in @($events | Sort-Object Offset)) { if ($e.Add) { $set[$e.Key]=$true } else { $set.Remove($e.Key) } }
            return @($set.Keys)
        }
        # A parameter of this name hides any outer variable of the same name, and its value is not known here.
        if (Test-ScopeDeclaresParameter $scope $Name) { return @() }
        $scope=Get-EnclosingScope $scope
    }
    return @()
}
# One line per finding: relative/path.ps1:LINE: @variable + -Parameter (the parameter as written on the call).
function Find-SplatDuplicates([string]$Path,[string]$Root) {
    $ast=[System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$null,[ref]$null)
    $rootFull=[System.IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $full=[System.IO.Path]::GetFullPath($Path)
    $relative=if ($full.StartsWith($rootFull,[StringComparison]::OrdinalIgnoreCase)) { $full.Substring($rootFull.Length).TrimStart('\','/') } else { $full }
    $relative=$relative.Replace('\','/')
    $calls=@($ast.FindAll({param($n) $n.GetType().Name -ceq 'CommandAst'},$true))
    $assignments=@($ast.FindAll({param($n) $n.GetType().Name -ceq 'AssignmentStatementAst'},$true))
    $members=@($ast.FindAll({param($n) $n.GetType().Name -ceq 'InvokeMemberExpressionAst'},$true))
    $found=@()
    foreach ($call in $calls) {
        $named=@($call.CommandElements | Where-Object { Test-Ast $_ 'CommandParameterAst' })
        if ($named.Count -eq 0) { continue }
        $splats=@($call.CommandElements | Where-Object { (Test-Ast $_ 'VariableExpressionAst') -and $_.Splatted })
        foreach ($splat in $splats) {
            $name=$splat.VariablePath.UserPath
            $keys=@(Get-SplatKeys $call $name $assignments $members)
            if ($keys.Count -eq 0) { continue }
            foreach ($parameter in $named) {
                if (@($keys | Where-Object { $_ -ieq $parameter.ParameterName }).Count -gt 0) {
                    $line="${relative}:$($parameter.Extent.StartLineNumber): @$name + -$($parameter.ParameterName)"
                    if ($found -cnotcontains $line) { $found+=$line }
                }
            }
        }
    }
    return $found
}

$fixtureFolder='tests/fixtures/splat-duplicates'
$expected=[ordered]@{
    'bad-literal-splat.ps1'=@('4: @common + -ProfilePath')
    'bad-case-differs.ps1'=@('7: @common + -profilepath')
    'bad-later-key.ps1'=@('7: @opts + -ProfilePath','7: @opts + -Mode','7: @opts + -Extra')
    'bad-script-block.ps1'=@('4: @base + -ProfilePath')
    'bad-reassigned.ps1'=@('5: @common + -ProfilePath')
    'good-here-string.ps1'=@()
    'good-comment.ps1'=@()
    'good-function-result.ps1'=@()
    'good-other-function.ps1'=@()
    'good-clone-helper.ps1'=@()
    'good-prefix-only.ps1'=@()
    'good-key-removed.ps1'=@()
    'good-parameter-shadow.ps1'=@()
    'good-reassigned.ps1'=@()
}
foreach ($name in $expected.Keys) {
    $rel="$fixtureFolder/$name"
    $want=@($expected[$name] | ForEach-Object { "${rel}:$_" })
    $got=@(Find-SplatDuplicates (Join-Path $root $rel) $root)
    Check (($got -join "`n") -ceq ($want -join "`n")) "$name reports exactly: $(if ($want.Count) { $want -join '; ' } else { 'nothing' }) (got: $(if ($got.Count) { $got -join '; ' } else { 'nothing' }))"
}
$onDisk=@(Get-ChildItem -LiteralPath (Join-Path $root $fixtureFolder) -Filter '*.ps1' | ForEach-Object { $_.Name })
Check (@($onDisk | Where-Object { $expected.Keys -notcontains $_ }).Count -eq 0) 'every fixture file has an expected result'

# The repository scan runs only after the self-tests pass: every tracked PowerShell file except the fixtures.
$files=$null
if (Get-Command git -ErrorAction SilentlyContinue) {
    $listed=@(& git -C $root ls-files -- '*.ps1' '*.psm1' '*.psd1' 2>$null)
    if ($LASTEXITCODE -eq 0 -and $listed.Count -gt 0) { $files=@($listed | ForEach-Object { Join-Path $root $_ }) }
}
if ($null -eq $files) {
    $files=@(Get-ChildItem -LiteralPath $root -Recurse -File -Include '*.ps1','*.psm1','*.psd1' | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } | ForEach-Object { $_.FullName })
}
$fixtureRoot=(Join-Path $root 'tests/fixtures/splat-duplicates').Replace('\','/').TrimEnd('/')+'/'
$files=@($files | Where-Object { -not $_.Replace('\','/').StartsWith($fixtureRoot,[StringComparison]::OrdinalIgnoreCase) })
Check ($files.Count -gt 50) "scanned $($files.Count) tracked PowerShell files"
$findings=@()
foreach ($file in $files) { $findings+=@(Find-SplatDuplicates $file $root) }
Check ($findings.Count -eq 0) "no call passes a splatted key by name again (findings: $($findings -join ' | '))"
Write-Host "splat-duplicate-tests: $script:count checks passed"
