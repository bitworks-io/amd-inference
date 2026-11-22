# Fixture for splat-duplicate-tests.ps1: parsed only, never executed.
function Invoke-Sample {
    $common = Get-CommonArguments
    Get-Plan @common -ProfilePath 'b.json'
}
