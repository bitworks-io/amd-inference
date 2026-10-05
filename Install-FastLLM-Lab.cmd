@echo off
setlocal
set "FASTLLM_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "FASTLLM_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%FASTLLM_PS%" -NoLogo -NoProfile -STA -File "%~dp0tools\install-lab-app.ps1"
if errorlevel 1 (
  echo FastLLM lab setup could not open. This unsigned private lab build requires
  echo reviewed source and a script policy permitting local scripts.
  echo No execution-policy bypass, elevation, or automatic download was attempted.
  pause
)
endlocal
