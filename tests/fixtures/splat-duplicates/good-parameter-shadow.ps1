# Fixture for splat-duplicate-tests.ps1: parsed only, never executed.
$common = @{ ProfilePath = 'a.json' }
function Get-Shadow($common) {
    Get-Plan @common -ProfilePath 'b.json'
}
function Get-ShadowBlock {
    param($common)
    Get-Plan @common -ProfilePath 'b.json'
}
