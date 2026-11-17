# The mock embedding engine of tests/sidecar-tests.ps1. It has no param block on purpose: every argument it is given is the engine's own
# (llama-server style: --model, --alias, --host, --port, --embedding, --pooling, -c, ...), exactly as the supervisor built them, and is
# handed on unchanged. What the test sets and what the mock records live in the control folder named by FASTLLM_TEST_SIDECAR_CONTROL.
$ErrorActionPreference = 'Stop'
$controlFolder = [Environment]::GetEnvironmentVariable('FASTLLM_TEST_SIDECAR_CONTROL')
try {
    Add-Type -Path (Join-Path $PSScriptRoot 'MockEmbeddingServer.cs')
    [FastLlmTests.MockEmbeddingServer]::Run([string[]] @($args | ForEach-Object { [string] $_ }), [string] $controlFolder)
}
catch {
    if ($controlFolder) {
        $message = ([string] $_.Exception.Message -replace '[\r\n\x00-\x1f]', ' ')
        try { [IO.File]::WriteAllText((Join-Path $controlFolder 'child-error.txt'), ($_.Exception.GetType().Name + ': ' + $message.Substring(0, [Math]::Min(400, $message.Length)))) } catch { $null = $_ }
    }
    throw
}
