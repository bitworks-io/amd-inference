# Fixture for block-comma-argument-tests.ps1: parsed only, never executed.
$f = { param($a, $b) }
# & $f 1 {1},'x'
$text = @'
& $f 1 {1},'x'
'@
& $f 1 $text
