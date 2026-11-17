param([int]$Port, [string]$Mode='ok', [string]$Model='test-model', [int]$Context=1024, [string]$DiagnosticPath='', [string]$ModeFile='')
$ErrorActionPreference='Stop'
# -ModeFile (model switch tests): the mode of THIS start is the first line of the file. With more than one line the first is consumed, so the next
# start of the same plan (the same arguments) gets the next mode; each start is appended to <ModeFile>.starts.
if ($ModeFile) {
    $modeLines=@([IO.File]::ReadAllLines($ModeFile) | Where-Object { $_ })
    $Mode=[string]$modeLines[0]
    if ($modeLines.Count -gt 1) { [IO.File]::WriteAllLines($ModeFile, [string[]]@($modeLines[1..($modeLines.Count-1)])) }
    [IO.File]::AppendAllText(($ModeFile + '.starts'), ($Mode + "`n"))
}
if ($DiagnosticPath) { [IO.File]::WriteAllText($DiagnosticPath, 'script-started') }
try {
    Add-Type -Path (Join-Path $PSScriptRoot 'MockServer.cs')
    if ($DiagnosticPath) { [IO.File]::WriteAllText($DiagnosticPath, 'mock-compiled') }
    [FastLlmTests.MockServer]::Run($Port, $Mode, $Model, $Context, $DiagnosticPath)
} catch {
    if ($DiagnosticPath) {
        $kind=$_.Exception.GetType().Name
        $message=($_.Exception.Message -replace '[\r\n\x00-\x1f]', ' ')
        [IO.File]::WriteAllText($DiagnosticPath, ('child-error ' + $kind + ': ' + $message.Substring(0,[Math]::Min(400,$message.Length))))
    }
    throw
}
