# Fixture for splat-duplicate-tests.ps1: parsed only, never executed.
function Invoke-Sample {
    $common = @{ ProfilePath = 'a.json'; Mode = 'fast' }
    $call = Join-TestSplat -Base $common -Replace @{ ProfilePath = 'b.json' }
    Get-Plan @call -ProfilePath 'c.json'
}
