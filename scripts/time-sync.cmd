@echo off
setlocal
rem Launcher for time-sync.ps1. Prefer 64-bit Windows PowerShell 5.1.
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" (
  set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
)
if not exist "%PS%" (
  echo Error: Windows PowerShell not found. 1>&2
  exit /b 1
)
"%PS%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0time-sync.ps1" %*
exit /b %ERRORLEVEL%
