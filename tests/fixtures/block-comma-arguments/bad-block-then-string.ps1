# A script block and a message joined by a comma become ONE array argument, which cannot bind to [scriptblock]. Must be flagged.
$check = { param($Result, [scriptblock]$Expect, [string]$Message) & $Expect $Result }
& $check 1 {param($p) $p -eq 1},'one is one'
