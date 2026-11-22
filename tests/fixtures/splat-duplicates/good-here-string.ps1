# Fixture for splat-duplicate-tests.ps1: parsed only, never executed.
$text = @'
$common = @{ ProfilePath = 'a.json' }
Get-Plan @common -ProfilePath 'b.json'
'@
$text2 = @"
$common = @{ ProfilePath = 'a.json' }
Get-Plan @common -ProfilePath 'b.json'
"@
