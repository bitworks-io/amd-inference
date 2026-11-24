# Fixture for block-comma-argument-tests.ps1: parsed only, never executed.
$f = { param($a, [scriptblock]$Expect, [string]$Message) }
& $f 1 {1} 'x'
