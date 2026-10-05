@echo off
setlocal EnableExtensions DisableDelayedExpansion
echo FastLLM Windows bench SSH and account setup
echo Right-click this launcher and choose Run as administrator, locally or through RDP.
echo This grants administrator SSH access and allows TCP 22 from any source on all profiles.
set "FASTLLM_SETUP_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "FASTLLM_SETUP_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%FASTLLM_SETUP_PS%" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0start-windows-lab-setup.ps1"
set "FASTLLM_SETUP_RESULT=%ERRORLEVEL%"
echo.
if not "%FASTLLM_SETUP_RESULT%"=="0" echo Setup did not complete. Review the output above and any printed report path.
pause
exit /b %FASTLLM_SETUP_RESULT%
