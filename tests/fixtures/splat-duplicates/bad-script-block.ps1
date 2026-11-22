# Fixture for splat-duplicate-tests.ps1: parsed only, never executed.
$base = @{ ProfilePath = 'a.json' }
Invoke-Wrapper -Script {
    Get-Plan @base -ProfilePath 'b.json'
}
