# ThermoTrack — Current Source Audit and Verification Report

## Source baseline

This package was audited from the uploaded `ThermoTrack_OneStep_GitHub_Fixed` project ZIP. The two editions remain separate:

- `CBP/Original_Project/`: the original Python collector, HTML dashboard, MATLAB analysis, and launcher/support files.
- `CBP/ThermoTrack_Single_Application/`: the C# WinForms/WebView2 application, integrated LibreHardwareMonitor sensor service, bundled Python numerical worker, dashboard, tests, and installer/build workflow.

## Corrections in this revision

- The analysis worker now ignores blank or whitespace-only lines in its newline-delimited JSON input protocol. Blank transport lines no longer produce a spurious `ERROR` JSON response. Invalid non-empty requests still return a structured error response.
- The Windows build's frozen-worker smoke test deliberately sends a blank line before a valid request, reads stdout and stderr completely and asynchronously, validates that there is exactly one non-empty JSON response, and checks the no-fabricated-values contract. The test still fails on a real error, invalid response, missing fields, or fabricated values.
- Forecast-driven `WATCH` thresholds now match the original MATLAB source: CPU 85°C, GPU 80°C, SSD 65°C. Forecasted critical bands remain CPU 95°C, GPU 88°C, and SSD 75°C; forecasts do not directly set `CRITICAL`.
- Exact-name sensor matches now pass through the same candidate-exclusion rules as fuzzy/fallback matches, reducing the risk of selecting a GPU hotspot/junction sensor as the base GPU temperature.
- Added regression tests for blank protocol lines and forecast alert bands.
- Added `APPLY_THERMOTRACK_FIXES.ps1` so the user can copy the cleaned project into an existing local checkout and push the changes without overwriting `.git`. It makes a backup branch and stashes pre-existing uncommitted changes before aligning local `main` to GitHub `origin/main`; it does not force-push.
- Removed `.git` metadata, Python bytecode, test caches, and transient build caches from the distributed ZIP.

## Checks run in this environment

- Python tests: **14 passed** (`python -m pytest tests -q`).
- Python syntax compilation: passed for the worker and tests.
- JSON-lines protocol test: passed with blank lines before/after the request; exactly one `SENSOR_UNAVAILABLE` response is emitted, `maxTemperature` is `null`, and `prediction.cpu5` is `null`.
- Dashboard embedded JavaScript syntax: passed using Node.js after extracting the inline script.
- The smoke test assertions preserve the rule that missing readings are not replaced with zero temperatures or fake forecasts.
- Package content/integrity is checked when the ZIP is produced.

## Not verified in this environment

The environment has no .NET SDK, PowerShell runtime, or Inno Setup compiler, so this revision has **not** been compiled into a Windows installer here. The frozen Windows worker smoke test has not run here, either. Physical CPU/GPU/SSD measurements cannot be exercised in this Linux/container environment. These checks must be completed by the GitHub Actions Windows workflow and then by running the installed app on the target Windows computer.

A green GitHub Actions run will verify the Windows compilation/package steps and CI smoke test, but it will not by itself prove that every hardware sensor works on the user's device. Compare the installed app's live readings with the working original program and run `CBP/ThermoTrack_Single_Application/tests/verify_installed_hardware.ps1` on the target PC. Some low-level readings remain hardware/firmware/driver/permission-dependent.
