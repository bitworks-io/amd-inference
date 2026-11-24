# Fixture for block-comma-argument-tests.ps1: parsed only, never executed.
function Invoke-Thing { param([scriptblock]$Expect, [string]$Message) }
Invoke-Thing {param($p) $p},'x'
