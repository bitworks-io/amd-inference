# Fixture for block-comma-argument-tests.ps1: parsed only, never executed.
$f = { param([scriptblock]$Expect, [string]$Message) }
& $f -Expect:{param($p) $true},'msg'
