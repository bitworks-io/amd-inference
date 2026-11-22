#requires -Version 5.1
# Placeholder for the Fluent window shell (replaced by the shell task). Dot-sourced by fast-llm-ui.ps1 only with -Window fluent.
. (Join-Path $PSScriptRoot 'FastLlm.UiFluentAdapter.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.UiFluentSupport.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.UiFluentForm.ps1')
. (Join-Path $PSScriptRoot 'FastLlm.UiFluentBindings.ps1')

function Initialize-FastLlmUiFluentShell { throw 'Fluent shell not built yet' }
function Start-FastLlmUiFluentLoop { throw 'Fluent shell not built yet' }
function Get-FastLlmUiFluentTrayIcon { return [Drawing.SystemIcons]::Application }
