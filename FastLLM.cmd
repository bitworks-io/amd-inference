@echo off
setlocal
set "FASTLLM_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "FASTLLM_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%FASTLLM_PS%" -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -STA -File "%~dp0fast-llm-ui.ps1"
if errorlevel 1 (
  echo FastLLM could not open. Run it as a standard user, not as administrator.
  echo If your organization enforces a PowerShell script policy, see the FastLLM README:
  echo https://github.com/bitworks-io/amd-inference
  pause
)
endlocal
