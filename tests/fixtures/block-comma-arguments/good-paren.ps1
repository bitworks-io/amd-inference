# Fixture for block-comma-argument-tests.ps1: parsed only, never executed.
$f = { param($a, $list) }
& $f 1 ({1},'x')
