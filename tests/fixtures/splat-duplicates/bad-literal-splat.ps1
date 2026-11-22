# Fixture for splat-duplicate-tests.ps1: parsed only, never executed.
function Invoke-Sample {
    $common = @{ ProfilePath = 'a.json'; Mode = 'fast' }
    Get-Plan @common -ProfilePath 'b.json'
}
