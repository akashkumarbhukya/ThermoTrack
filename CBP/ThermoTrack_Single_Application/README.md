# ThermoTrack — Native Windows Desktop Edition

This repository is the implementation project for the single-window Windows application discussed with the user.

## Intended user experience
- Install/open ThermoTrack from one Windows installer.
- A native WinForms window opens the existing dark dashboard. The app requests Windows administrator permission at launch because some low-level sensor interfaces require elevation.
- Sensor collection uses the LibreHardwareMonitor **library embedded in the application**, not its separate GUI or HTTP port.
- Python analysis runs as a bundled worker executable built from `analysis/analysis_worker.py` with NumPy/SciPy.
- No telemetry is written to disk; the application keeps a bounded 300-sample RAM buffer and clears it on exit.
- Sensors the hardware/driver does not expose are shown as unavailable, never fabricated.

## Build on Windows 10/11 x64
Prerequisites for the **developer/build machine only**: .NET 8 SDK, Python 3.11 x64, and Inno Setup 6. End users do not need these tools.

1. Open PowerShell in this folder.
2. Run `Set-ExecutionPolicy -Scope Process Bypass` if the current session blocks scripts.
3. Run `./build/build_windows.ps1`.
4. The installer is written to `dist/ThermoTrack-Setup-x64.exe`. The app is configured to request Windows administrator permission at launch.

The build downloads NuGet/PyPI dependencies. Do not distribute until you have tested the produced installer on physical Windows systems with Intel/AMD CPU, available GPU, and NVMe/SATA storage configurations.

## Architecture
- `src/ThermoTrack.App`: native Windows shell, sensor library integration, local-only HTTP bridge for the existing dashboard, and RAM-only sample history.
- `analysis/analysis_worker.py`: Python numerical engine (regression forecasts, heating rate, thresholds, polynomial RMSE, PCA/SVD, and educational Jacobi/Gauss-Seidel coupled model).
- `app-dashboard/index.html`: dashboard bundled into the native desktop application. The separate educational/original project is intentionally not included in this package.

## Limitations
Hardware sensor access varies by motherboard, GPU driver, SSD controller, and Windows permissions. This app does not promise every sensor on every computer. Temperature limits are prototype advisory thresholds, not a substitute for manufacturer specifications. The application never shuts down or terminates processes automatically.

## Third-party licensing
LibreHardwareMonitor is MPL-2.0; WebView2 and Python packages have their own terms. Review `THIRD_PARTY_NOTICES.md` and ship the applicable notices and source offer/changes required by each licence.


## Package scope
This ZIP contains only the standalone desktop-application source/build files. The separate original Python–MATLAB–HTML educational project is intentionally excluded and should remain in its own folder in the parent CBP repository.


## Non-administrator installation

The Windows edition is configured to run with the current user's permissions. The installer targets `%LOCALAPPDATA%\Programs\ThermoTrack`; WebView2 profile data is stored under `%LOCALAPPDATA%\ThermoTrack\WebView2`. Some hardware sensors may still be unavailable to standard users depending on Windows, firmware, drivers, and device permissions. In that case the app should remain open and report unavailable readings rather than inventing temperatures.
