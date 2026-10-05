param([int]$Port, [string]$Mode='ok', [string]$Model='test-model', [int]$Context=1024, [string]$DiagnosticPath='')
$ErrorActionPreference='Stop'
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
