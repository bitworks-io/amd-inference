# Fixture for splat-duplicate-tests.ps1: parsed only, never executed.
function Get-ReassignedLiteral {
    $common = Get-CommonArguments
    $common = @{ ProfilePath = 'a.json' }
    Get-Plan @common -ProfilePath 'b.json'
}
