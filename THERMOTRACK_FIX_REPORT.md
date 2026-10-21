# ThermoTrack Source Audit and Correction Report

## Scope

This corrected source package preserves the two editions separately:

- `CBP/Original_Project/` — the original Python collector, HTML dashboard, MATLAB analysis, and launcher/support files.
- `CBP/ThermoTrack_Single_Application/` — the C# WinForms/WebView2 desktop edition, embedded LibreHardwareMonitor sensor service, numerical-analysis worker, dashboard, tests, and installer/build configuration.

The original edition's source was used as the behavioral reference; it was not replaced by the standalone implementation.

## Issues addressed

- Expanded and prioritized CPU/GPU/hotspot/SSD sensor alias matching in the standalone C# service to handle more driver naming variants and child hardware.
- Added sensor-value validation and explicit availability notes. Invalid/missing temperatures are represented as null/unavailable rather than being silently filled with 0°C. Genuine zero load and power values remain valid.
- Added progressively reduced hardware initialization attempts so a problematic device family does not necessarily prevent all other sensors from working.
- Used Windows memory APIs for RAM reporting and kept missing RAM values nullable.
- Added per-user diagnostics under `%LOCALAPPDATA%\ThermoTrack\Logs\thermotrack.log`; temperature history/workload telemetry is not written to that log.
- Put WebView2 profile data in `%LOCALAPPDATA%\ThermoTrack\WebView2`, with a writable temporary-profile fallback, instead of storing mutable data inside the installation folder.
- Kept standard-user application execution (`asInvoker`) and per-user installation under `%LOCALAPPDATA%\Programs\ThermoTrack`.
- Made the live sensor interface continue if the analysis worker fails, with forecasts and other analysis fields explicitly unavailable instead of crashing the entire UI.
- Changed the analysis worker to reject invalid/currently missing sensor values, withhold predictions and confidence scores when the data history is insufficient or flat, and avoid plotting missing readings as zero.
- Aligned the prototype thermal limits with the original MATLAB source: CPU 75/85/95°C, GPU 70/80/88°C, GPU hotspot 90/100/105°C, SSD 55/65/75°C for watch/warning/critical. Fast temperature rise can independently raise a warning.
- Corrected threshold-crossing time units to seconds, which the dashboard converts to minutes.
- Required a larger complete and varying history for the ODE forecast, avoided imputation of missing sensor columns in PCA, and required a minimum history for curve-fit RMSE.
- Improved the Windows build script to check native-command exit codes, run tests, smoke-test the packaged analysis worker against missing data, and fail rather than uploading an absent or implausibly small installer.
- Updated the GitHub Actions action versions and documentation for both editions.

## Checks run in this environment

- Python syntax compilation: passed.
- Python test suite: **11 passed**.
- Dashboard JavaScript syntax check with Node.js: passed.
- Analysis worker JSON-lines smoke test with unavailable CPU/GPU/SSD temperatures: passed; it returned `SENSOR_UNAVAILABLE`, `maxTemperature: null`, null CPU prediction, and null CPU confidence.

## Windows physical sensor verification helper

Added `CBP/ThermoTrack_Single_Application/tests/verify_installed_hardware.ps1`. After the installer is built and installed on Windows, it locates or starts ThermoTrack, discovers the app-owned loopback listener, samples the `/data` API for 10 rounds, checks for valid CPU/GPU/GPU-hotspot/SSD readings, prints the other live metrics, and surfaces recent relevant diagnostic-log lines. It does not persist sampled telemetry. The script has not been executed in this Linux environment because PowerShell and Windows hardware are not available here.

## Not verified here

This environment did not have the .NET SDK, PowerShell, or Inno Setup available, so a Windows C# publish and installer compilation were **not run here**. This environment also cannot access the user's physical CPU/GPU/SSD sensors. The source package therefore does not claim that a Windows installer has been compiled or that the user's sensor behavior is fixed on hardware.

After pushing these changes, verify the GitHub Actions run ends with a green check and downloads the `ThermoTrack-Windows-Installer-x64` artifact. Then install and test on the target Windows computer, comparing its live values with the original working edition. Some low-level sensors remain hardware-, firmware-, driver-, and permission-dependent.
