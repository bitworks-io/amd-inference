# Fixture for splat-duplicate-tests.ps1: parsed only, never executed.
function Invoke-Sample {
    $common = [ordered]@{
        'ProfilePath' = 'a.json'
        Mode = 'fast'
    }
    Get-Plan @common -profilepath 'b.json' -Other 1
}
