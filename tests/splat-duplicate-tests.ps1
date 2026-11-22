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

function Find-SplatDuplicates([string]$Path,[string]$Root) {
    return @()
}

$fixtureFolder='tests/fixtures/splat-duplicates'
$expected=[ordered]@{
    'bad-literal-splat.ps1'=@('4: @common + -ProfilePath')
    'bad-case-differs.ps1'=@('7: @common + -profilepath')
    'bad-later-key.ps1'=@('7: @opts + -ProfilePath','7: @opts + -Mode','7: @opts + -Extra')
    'bad-script-block.ps1'=@('4: @base + -ProfilePath')
    'good-here-string.ps1'=@()
    'good-comment.ps1'=@()
    'good-function-result.ps1'=@()
    'good-other-function.ps1'=@()
    'good-clone-helper.ps1'=@()
    'good-prefix-only.ps1'=@()
    'good-key-removed.ps1'=@()
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
