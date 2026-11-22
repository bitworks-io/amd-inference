# Fixture for splat-duplicate-tests.ps1: parsed only, never executed.
function Get-First {
    $common = @{ ProfilePath = 'a.json' }
    Get-Plan @common
}
function Get-Second {
    $common = Get-CommonArguments
    Get-Plan @common -ProfilePath 'b.json'
}
function Get-Third($common) {
    Get-Plan @common -ProfilePath 'b.json'
}
