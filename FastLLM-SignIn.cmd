@echo off
setlocal
REM Started at sign-in by the optional per-user Run value. It makes one attempt to start the background host and records the result.
set "FASTLLM_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "FASTLLM_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
REM Same execution-policy rule as FastLLM.cmd: set a Process-scope policy only when the effective one would block FastLLM's signed scripts; never weaken AllSigned or Group Policy.
for /f "usebackq delims=" %%P in (`""%FASTLLM_PS%" -NoLogo -NoProfile -NonInteractive -Command Get-ExecutionPolicy"`) do set "FASTLLM_POLICY=%%P"
set "FASTLLM_EP="
if /i "%FASTLLM_POLICY%"=="Restricted" set "FASTLLM_EP=-ExecutionPolicy RemoteSigned"
if /i "%FASTLLM_POLICY%"=="Undefined" set "FASTLLM_EP=-ExecutionPolicy RemoteSigned"
"%FASTLLM_PS%" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden %FASTLLM_EP% -File "%~dp0tools\signin-start.ps1" -InstallRoot "%~dp0."
endlocal & exit /b %errorlevel%
