#requires -Version 5.1
# Block-comma guard: a bare comma between a script block and another value in a command argument ( & $check $result {param($p) ...},'message' ) makes
# ONE array argument (Object[]), which cannot bind to a [scriptblock] parameter on Windows PowerShell 5.1 or PowerShell 7 ("Cannot process argument
# transformation on parameter"). A native Windows run found one such call in a test file whose branch only runs natively on Windows, so CI never saw it.
# This suite finds every such argument with the PowerShell parser (never a text search): a CommandAst element that is a bare comma list (ArrayLiteralAst)
# holding a script block at any index but the last, and the same test on the argument of a colon-form parameter (-Expect:{...},'x'). It does not flag
# @(...) (a deliberate array), ( ... ) (a parenthesised list), a script block that is the last element, comma lists without a script block, assignments
# ($x = {a},'b' is not a command argument), or text inside comments and strings. The fixtures under tests/fixtures/block-comma-arguments are parsed,
# never executed. Pure parsing; no engine, GPU or network.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Split-Path $PSScriptRoot -Parent
$script:count=0
function Check($Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:count++;Write-Host "PASS: $Message"}

function Test-Ast($Node,[string]$TypeName) { return ($null -ne $Node -and $Node.GetType().Name -ceq $TypeName) }
# True when a comma list holds a script block followed by at least one more element.
function Test-BlockThenMore($Node) {
    if (-not (Test-Ast $Node 'ArrayLiteralAst')) { return $false }
    $elements=@($Node.Elements)
    for ($i=0; $i -lt $elements.Count-1; $i++) { if (Test-Ast $elements[$i] 'ScriptBlockExpressionAst') { return $true } }
    return $false
}
# One line per finding: relative/path.ps1:LINE (the start line of the comma list).
function Find-BlockComma([string]$Path,[string]$Root) {
    $ast=[System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$null,[ref]$null)
    $rootFull=[System.IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $full=[System.IO.Path]::GetFullPath($Path)
    $relative=if ($full.StartsWith($rootFull,[StringComparison]::OrdinalIgnoreCase)) { $full.Substring($rootFull.Length).TrimStart('\','/') } else { $full }
    $relative=$relative.Replace('\','/')
    $calls=@($ast.FindAll({param($n) $n.GetType().Name -ceq 'CommandAst'},$true))
    $found=@()
    foreach ($call in $calls) {
        foreach ($element in $call.CommandElements) {
            $list=$null
            if (Test-Ast $element 'ArrayLiteralAst') { $list=$element }
            elseif ((Test-Ast $element 'CommandParameterAst') -and $null -ne $element.Argument) { $list=$element.Argument }
            if ($null -ne $list -and (Test-BlockThenMore $list)) {
                $line="${relative}:$($list.Extent.StartLineNumber)"
                if ($found -cnotcontains $line) { $found+=$line }
            }
        }
    }
    return $found
}

# The failure itself, with no flagged source in this file: both calls are built from strings.
$helper={ param($Result,[scriptblock]$Expect,[string]$Message) $Expect }
$commaCall=[scriptblock]::Create('param($h) & $h 1 {param($p) $p -eq 1},''one is one''')
$spaceCall=[scriptblock]::Create('param($h) & $h 1 {param($p) $p -eq 1} ''one is one''')
$caught=$null
try { & $commaCall $helper | Out-Null } catch { $caught=$_ }
Check ($null -ne $caught -and ([string]$caught.FullyQualifiedErrorId -like '*ParameterArgumentTransformationError*' -or $caught.Exception.GetType().Name -like '*ArgumentTransformation*')) "a script block and a string joined by a comma fail to bind to [scriptblock]`$Expect (got: $(if ($null -ne $caught) { $caught.FullyQualifiedErrorId } else { 'no error' }))"
$bound=& $spaceCall $helper
Check ($bound -is [scriptblock]) 'the same two arguments separated by a space bind $Expect as a script block'

$fixtureFolder='tests/fixtures/block-comma-arguments'
$expected=[ordered]@{
    'bad-block-then-string.ps1'=@('3')
    'bad-block-then-block.ps1'=@('3')
    'bad-named-colon.ps1'=@('3')
    'bad-cmdlet.ps1'=@('3')
    'good-space.ps1'=@()
    'good-explicit-array.ps1'=@()
    'good-paren.ps1'=@()
    'good-block-last.ps1'=@()
    'good-string-list.ps1'=@()
    'good-assignment.ps1'=@()
    'good-comment-and-string.ps1'=@()
}
foreach ($name in $expected.Keys) {
    $rel="$fixtureFolder/$name"
    $want=@($expected[$name] | ForEach-Object { "${rel}:$_" })
    $got=@(Find-BlockComma (Join-Path $root $rel) $root)
    Check (($got -join "`n") -ceq ($want -join "`n")) "$name reports exactly: $(if ($want.Count) { $want -join '; ' } else { 'nothing' }) (got: $(if ($got.Count) { $got -join '; ' } else { 'nothing' }))"
}
$onDisk=@(Get-ChildItem -LiteralPath (Join-Path $root $fixtureFolder) -Filter '*.ps1' | ForEach-Object { $_.Name })
Check (@($onDisk | Where-Object { $expected.Keys -notcontains $_ }).Count -eq 0) 'every fixture file has an expected result'

# The repository scan runs only after the self-tests pass: every tracked PowerShell file except the fixtures.
$files=$null
if (Get-Command git -ErrorAction SilentlyContinue) {
    $listed=@(& git -C $root ls-files -- '*.ps1' '*.psm1' 2>$null)
    if ($LASTEXITCODE -eq 0 -and $listed.Count -gt 0) { $files=@($listed | ForEach-Object { Join-Path $root $_ }) }
}
if ($null -eq $files) {
    $files=@(Get-ChildItem -LiteralPath $root -Recurse -File -Include '*.ps1','*.psm1' | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } | ForEach-Object { $_.FullName })
}
$fixtureRoot=(Join-Path $root $fixtureFolder).Replace('\','/').TrimEnd('/')+'/'
$files=@($files | Where-Object { -not $_.Replace('\','/').StartsWith($fixtureRoot,[StringComparison]::OrdinalIgnoreCase) })
Check ($files.Count -gt 50) "scanned $($files.Count) tracked PowerShell files"
$findings=@()
foreach ($file in $files) { $findings+=@(Find-BlockComma $file $root) }
Check ($findings.Count -eq 0) "no command argument joins a script block and another value with a bare comma (findings: $($findings -join ' | '))"
Write-Host "block-comma-argument-tests: $script:count checks passed"
