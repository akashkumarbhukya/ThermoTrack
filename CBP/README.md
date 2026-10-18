# ThermoTrack

Real-time CPU, GPU, SSD and RAM thermal monitoring with numerical analysis, temperature predictions, anomaly warnings and recommendations. This repository keeps the two editions separate.

## Editions

### 1. Original educational project — `Original_Project/`
The original Python collector, HTML dashboard, MATLAB receiver/analysis, and supporting text files. See `Original_Project/README_Warnings.txt` for its original notes. This edition uses the existing external sensor-provider workflow and is intended for coursework/development.

### 2. Windows desktop application source — `ThermoTrack_Single_Application/`
A native C#/.NET Windows shell, bundled LibreHardwareMonitor library integration, Python analysis worker, and dashboard. The GitHub Actions workflow at `.github/workflows/build-windows.yml` builds on a Windows runner when manually triggered or when application files change on `main`. After a successful run, download the `ThermoTrack-Windows-Installer-x64` artifact from that workflow run.

**Build status:** This repository package is source code, not a precompiled installer. Do not advertise the installer as ready until the Windows workflow succeeds and the installer is tested on real Windows hardware. Sensor availability varies by device and driver.

## Build the Windows edition locally

On a Windows 10/11 x64 build machine, install the .NET 8 SDK, Python 3.11 x64, and Inno Setup 6, then run PowerShell from `ThermoTrack_Single_Application/`:

```powershell
./build/build_windows.ps1
```

The build machine downloads build dependencies. End users should not need the .NET SDK or Python build tools once a valid installer has been built.

## Privacy and excluded files

The student report `CBP_CM.docx` was excluded because it contains student/college details and is not required to run the software. The temporary editor file `tempCodeRunnerFile.py` was excluded as a duplicate/temporary artifact. Keep private copies if needed for coursework.

## Licensing

See the application folder's `LICENSE` and `THIRD_PARTY_NOTICES.md`. Confirm ownership and third-party licence compliance before publishing or redistributing binaries. The original educational files are retained as source; this root repository licence does not override third-party licences.

## Original dashboard launch fix

The original collector now resolves `index.html` relative to `collector.py`, rather than depending on the terminal's current working directory. It opens `http://127.0.0.1:5000/` automatically after the local server successfully starts and reports a clear message if port 5000 is already occupied. This change is limited to the original Python server startup and dashboard file path; the MATLAB receiver and analysis file are unchanged.
