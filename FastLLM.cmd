@echo off
setlocal
set "FASTLLM_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "FASTLLM_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%FASTLLM_PS%" -NoLogo -NoProfile -STA -File "%~dp0fast-llm-ui.ps1"
if errorlevel 1 (
  echo FastLLM could not open. This unsigned lab build requires a reviewed,
  echo unblocked source folder and a script policy permitting local scripts.
  echo See docs\WINDOWS-LAB.md. Do not run as administrator.
  pause
)
endlocal
