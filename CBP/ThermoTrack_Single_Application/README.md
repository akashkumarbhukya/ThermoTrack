# ThermoTrack — Native Windows Desktop Edition

This folder contains the standalone Windows desktop implementation. The separate original educational Python–HTML–MATLAB edition is preserved at `../Original_Project/`.

## Intended user experience

- Install/open ThermoTrack from a per-user Windows installer.
- Run the desktop UI as the current Windows user (`asInvoker`); no blanket administrator prompt is configured.
- Read hardware sensors through `LibreHardwareMonitorLib` embedded in the app, not through a separate LibreHardwareMonitor GUI or HTTP port.
- Use the bundled Python numerical-analysis worker built from `analysis/analysis_worker.py` with NumPy/SciPy.
- Keep a bounded 300-sample telemetry history in RAM and clear it at shutdown. Diagnostic logs store errors/status only, not sampled temperatures or workload telemetry.
- Show unavailable or invalid readings as `--`; never fabricate sensor values.

Some low-level sensors can be blocked or unavailable for a standard user depending on device, firmware, drivers, and Windows configuration. ThermoTrack continues with other available sensors and reports limitations instead of requiring elevation for the whole interface.

## Build on Windows 10/11 x64

Build-machine prerequisites: .NET 8 SDK, Python 3.11 x64, and Inno Setup 6. End users do not need these development tools. WebView2 Runtime is installed/checked by the installer; the app keeps its WebView2 profile under `%LOCALAPPDATA%\ThermoTrack\WebView2` and retries with a per-user temporary profile if needed.

From PowerShell at the repository root, run:

```powershell
./CBP/ThermoTrack_Single_Application/build/build_windows.ps1
```

The build script tests the numerical worker before publishing the application and packaging the installer. It checks native-command exit codes and refuses to produce a release when tests or required build steps fail.

The expected installer is:

`CBP/ThermoTrack_Single_Application/dist/ThermoTrack-Setup-x64.exe`

GitHub Actions also builds and uploads a `ThermoTrack-Windows-Installer-x64` artifact when the workflow succeeds. A source upload or a completed build alone does not prove that all sensors work on a given PC. Test the installer on actual Windows hardware before treating the release as complete.

## Architecture

- `src/ThermoTrack.App`: native WinForms shell, WebView2 dashboard host, embedded LibreHardwareMonitor sensor service, local loopback-only HTTP bridge, and RAM-only sample history.
- `src/ThermoTrack.App/SensorService.cs`: sensor discovery, alias matching, validation, device-family fallback, memory usage, top-process sampling, and availability notes.
- `src/ThermoTrack.App/AppDiagnostics.cs`: writable diagnostic log under `%LOCALAPPDATA%\ThermoTrack\Logs`; sensor values are not logged.
- `analysis/analysis_worker.py`: numerical engine porting the original MATLAB thermal behavior, including local heating rates, temperature/load/power ODE model, model confidence, threshold crossing in seconds, PCA/SVD, Jacobi/Gauss-Seidel thermal-balance exercise, and curve-fit RMSE.
- `app-dashboard/index.html`: dashboard with live reading-availability notice, temperature/workload charts, forecasts, alerts, recommendations, and numerical-analysis details.

## Data and model rules

- Valid zero load/power values are allowed; missing values are not replaced with zero.
- A component temperature of 0°C or outside the normal PC measurement range is treated as an invalid sensor/sentinel reading by the current implementation.
- The ODE forecast requires at least 20 complete, timestamped, varying observations of temperature plus the necessary load/power inputs. Short, stale, unavailable, or flat histories do not receive model forecasts or confidence scores.
- The original MATLAB thresholds and alert logic are retained where practical: CPU watch/warning/critical at 75/85/95°C, GPU at 70/80/88°C, SSD at 55/65/75°C, and GPU hotspot at 90/100/105°C. These are prototype advisory thresholds, not universal manufacturer specifications.
- Dashboard threshold times are returned in seconds and converted to minutes in the UI.
- No automatic process termination or system shutdown occurs.

## Diagnostics and testing

The app writes diagnostic errors (not telemetry history) to:

`%LOCALAPPDATA%\ThermoTrack\Logs\thermotrack.log`

Python tests can be run from this folder with:

```powershell
python -m pip install -r requirements-build.txt
python -m pytest tests -q
```

Unit tests do not replace sensor tests on physical hardware. Sensor names and available metrics vary by system.

## Licensing

See `LICENSE` and `THIRD_PARTY_NOTICES.md`. Third-party components retain their own license terms and required notices.
