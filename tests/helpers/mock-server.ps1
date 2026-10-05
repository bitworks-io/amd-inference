param([int]$Port, [string]$Mode='ok', [string]$Model='test-model', [int]$Context=1024)
$ErrorActionPreference='Stop'
Add-Type -Path (Join-Path $PSScriptRoot 'MockServer.cs')
[FastLlmTests.MockServer]::Run($Port, $Mode, $Model, $Context)
