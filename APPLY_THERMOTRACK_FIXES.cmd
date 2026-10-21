@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0APPLY_THERMOTRACK_FIXES.ps1"
if errorlevel 1 (
  echo.
  echo ThermoTrack update did not complete. Read the error above; do not delete the .git folder.
  pause
  exit /b 1
)
echo.
echo ThermoTrack source update completed. Check the newest GitHub Actions run.
pause
