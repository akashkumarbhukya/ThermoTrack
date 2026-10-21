# ThermoTrack

Real-time CPU, GPU, SSD, and RAM monitoring with trend analysis, thermal alerts, forecasts, and recommendations. The public repository contains two separate editions under `CBP/`.

## Edition 1 — Original educational project

`CBP/Original_Project/` preserves the original Python collector, HTML dashboard, MATLAB analysis, and launch/support files. On Windows, `START_ORIGINAL_THERMOTRACK.bat` starts its launcher flow. The original version expects the established LibreHardwareMonitor sensor provider on `http://127.0.0.1:8085/data.json`, plus its original Python and MATLAB setup.

## Edition 2 — Single Windows desktop application

`CBP/ThermoTrack_Single_Application/` contains the WinForms/WebView2 shell, embedded LibreHardwareMonitor library, bundled Python numerical-analysis worker, dashboard, installer configuration, tests, and Windows build scripts. The intent is one user-facing desktop application without manually opening MATLAB, a Python terminal, a separate LibreHardwareMonitor window, or its HTTP endpoint.

The standalone edition is configured for standard-user execution and per-user installation. Some low-level sensors may be unavailable under standard-user permissions or on particular hardware/firmware/driver combinations. Missing or invalid readings must be reported as unavailable, not fabricated.

## Build and download the Windows application

For a local build on Windows 10/11 x64, install .NET 8 SDK, Python 3.11 x64, and Inno Setup 6 on the build machine, then run PowerShell from the repository root:

```powershell
./CBP/ThermoTrack_Single_Application/build/build_windows.ps1
```

GitHub Actions workflow: `.github/workflows/build-windows.yml`. Open **Actions → Build ThermoTrack Windows installer**. After a successful run, download the `ThermoTrack-Windows-Installer-x64` artifact. Use the commit/run status, not the existence of source files, to determine whether an installer was built.

A successful CI build does not verify sensor access on every PC. Test the installer on Windows hardware and compare CPU/GPU/SSD readings with the original working version before calling a release complete.

## Privacy, limitations, and safety

The collector keeps a maximum of 300 recent samples in RAM and clears the sample history when the app closes. Diagnostic logs store initialization/build/runtime errors but do not record the sampled temperature history. Sensor access depends on hardware, firmware, drivers, and permissions. Thermal thresholds are advisory prototypes; check manufacturer specifications. ThermoTrack does not automatically kill processes or shut down the computer.

## Licensing

See root `LICENSE`, `CBP/LICENSE`, and `CBP/ThermoTrack_Single_Application/THIRD_PARTY_NOTICES.md`. Third-party components retain their own license terms.
