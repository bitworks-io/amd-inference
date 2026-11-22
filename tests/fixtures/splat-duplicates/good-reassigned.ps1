# Fixture for splat-duplicate-tests.ps1: parsed only, never executed.
function Get-Reassigned {
    $common = @{ ProfilePath = 'a.json' }
    $common = Get-CommonArguments
    Get-Plan @common -ProfilePath 'b.json'
}
