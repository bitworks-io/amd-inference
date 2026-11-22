# Fixture for splat-duplicate-tests.ps1: parsed only, never executed.
function Invoke-Sample {
    $common = @{ ProfilePathExtra = 'a.json'; ModeName = 'fast' }
    Get-Plan @common -ProfilePath 'b.json' -Mode 'slow'
}
