# ThermoTrack

Real-time CPU, GPU, SSD and RAM thermal monitoring with numerical analysis, forecasts, anomaly warnings, and recommendations. This repository contains two separate editions under `CBP/`.

## Editions

- **Original educational project:** `CBP/Original_Project/` — original Python collector, HTML dashboard, MATLAB receiver, and supporting files. Start it on Windows with `START_ORIGINAL_THERMOTRACK.bat`. The original edition still expects its existing sensor provider and Python dependencies.
- **Single Windows desktop application source:** `CBP/ThermoTrack_Single_Application/` — C#/.NET desktop shell, integrated LibreHardwareMonitor library, Python analysis worker, and dashboard. This is source/build material, not a prebuilt installer.

## Build the Windows installer

The GitHub Actions workflow is at the repository root: `.github/workflows/build-windows.yml`. Open **Actions → Build ThermoTrack Windows installer → Run workflow**. After a successful build, download the `ThermoTrack-Windows-Installer-x64` artifact from the workflow run. The installer has not been considered production-ready until the workflow succeeds and it is tested on real Windows hardware.

For a local build on Windows 10/11 x64, install .NET 8 SDK, Python 3.11 x64, and Inno Setup 6, then run PowerShell from the repository root:

```powershell
./CBP/ThermoTrack_Single_Application/build/build_windows.ps1
```

## Limitations and privacy

Hardware sensors depend on device, firmware, drivers, and permissions. Unsupported sensors should be shown as unavailable, not fabricated. The student report containing student/college details and temporary editor files are excluded from the public package.

## Licensing

See root `LICENSE` and `CBP/ThermoTrack_Single_Application/THIRD_PARTY_NOTICES.md`. Third-party components retain their own licences. Verify applicable notices and distribution obligations before publishing compiled binaries.
