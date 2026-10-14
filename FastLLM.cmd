@echo off
setlocal
set "FASTLLM_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "FASTLLM_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
REM A Process-scope policy reaches child processes through PSExecutionPolicyPreference.
REM Set it only when the effective policy would block FastLLM's signed scripts; never weaken AllSigned or Group Policy.
for /f "usebackq delims=" %%P in (`"%FASTLLM_PS%" -NoLogo -NoProfile -NonInteractive -Command "Get-ExecutionPolicy"`) do set "FASTLLM_POLICY=%%P"
set "FASTLLM_EP="
if /i "%FASTLLM_POLICY%"=="Restricted" set "FASTLLM_EP=-ExecutionPolicy RemoteSigned"
if /i "%FASTLLM_POLICY%"=="Undefined" set "FASTLLM_EP=-ExecutionPolicy RemoteSigned"
"%FASTLLM_PS%" -NoLogo -NoProfile %FASTLLM_EP% -STA -File "%~dp0fast-llm-ui.ps1"
if errorlevel 1 (
  echo FastLLM could not open. Run it as a standard user, not as administrator.
  echo If your organization enforces a PowerShell script policy, see the FastLLM README:
  echo https://github.com/bitworks-io/amd-inference
  pause
)
endlocal
