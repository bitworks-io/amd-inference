# Fixture for splat-duplicate-tests.ps1: parsed only, never executed.
function Invoke-Sample {
    $opts = @{}
    $opts.ProfilePath = 'a.json'
    $opts['Mode'] = 'fast'
    $opts.Add('Extra', 1)
    Get-Plan @opts -ProfilePath 'b.json' -Mode 'slow' -Extra 2 -Unrelated 3
}
