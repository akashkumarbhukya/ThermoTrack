@echo off
setlocal
cd /d "%~dp0"
title ThermoTrack - Original Educational Edition
where python >nul 2>&1
if errorlevel 1 (
  echo Python was not found. Install Python 3 and ensure it is on PATH.
  pause
  exit /b 1
)
python -m pip show requests >nul 2>&1
if errorlevel 1 (
  echo Installing required Python packages...
  python -m pip install requests psutil
  if errorlevel 1 (
    echo Could not install required packages.
    pause
    exit /b 1
  )
)
echo Starting original ThermoTrack. Dashboard opens automatically.
python collector.py
echo.
echo ThermoTrack stopped. Review the message above if startup failed.
pause
