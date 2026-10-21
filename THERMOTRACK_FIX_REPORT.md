# ThermoTrack — Consolidated Build-Failure Fix and Verification Report

## Exact CI failure addressed

The reported Windows Actions failure showed the frozen analysis worker writing two JSON objects for one real request: first an `ERROR` caused by parsing an empty stdin line, then the expected `SENSOR_UNAVAILABLE` result. The underlying protocol defect is that a blank transport line was being passed to `json.loads` like a real request. A separate earlier updater failure also stopped before committing/pushing because a local optional Python dependency probe raised a PowerShell `NativeCommandError`; that made it easy for corrected files to exist locally without reaching GitHub.

## Fixes in this package

- `analysis/analysis_worker.py` ignores blank and whitespace-only input lines. Each non-empty request line produces one JSON response. Invalid non-empty requests still return a structured `ERROR` response; those errors are not hidden.
- `build/build_windows.ps1` deliberately sends a blank line followed by one valid no-sensor request to the *frozen* worker. It reads full stdout/stderr asynchronously and requires exactly one non-empty JSON response. It checks `SENSOR_UNAVAILABLE`, `maxTemperature: null`, and `prediction.cpu5: null`; extra output, invalid JSON, errors, missing properties, or fabricated values still fail the build.
- Automated regression tests cover a leading/trailing blank line around a request and multiple real requests separated by blank lines.
- Forecast watch/warning/critical thresholds match the original MATLAB policy for CPU, GPU, and SSD. The embedded worker test also checks this contract.
- Exact-name hardware sensor matches pass through exclusion rules to avoid choosing a hotspot/junction sensor as the main GPU temperature.
- `APPLY_THERMOTRACK_FIXES.ps1` no longer probes global Python imports before staging. GitHub Actions installs build dependencies and is the authoritative build/test environment. The helper validates the corrected source and build-smoke code *after copying into the actual Git checkout*, then creates a commit and pushes to `main`. It keeps `.git` metadata intact, makes a backup branch, preserves uncommitted work in a stash, and never force-pushes.

## Checks run in this environment

- Python unit/regression tests: **15 passed**.
- `py_compile` for the analysis worker and tests: passed.
- Dashboard inline JavaScript syntax: passed.
- Source-level JSON-lines protocol test: passed; a blank line followed by a missing-sensor request emits exactly one JSON response with `status: SENSOR_UNAVAILABLE`, `maxTemperature: null`, and `prediction.cpu5: null`.
- ZIP integrity and exclusion of embedded `.git` metadata/caches: verified when packaging.

## Not verified here

This environment does not provide the Windows/.NET/Inno Setup toolchain or the user's physical hardware. This ZIP is therefore a corrected source/apply package, **not proof of a newly built Windows installer**. The GitHub Actions Windows workflow must pass its build of the frozen executable and the deliberate blank-line smoke test. After that, the resulting installer must still be tested on the target PC to verify CPU/GPU/SSD readings against the original program. Sensor availability can vary with hardware, firmware, drivers, and permissions.

## Apply in three steps

1. Download and extract this package outside the repository (for example in Downloads).
2. Double-click `APPLY_THERMOTRACK_FIXES.cmd`. It validates the package and target checkout, copies the files without touching `.git`, verifies the actual target files, commits, and pushes. If any check or Git operation fails, it stops and explains the failure.
3. Open GitHub Actions and wait for the newest run. Do not use an older successful artifact if the newest run fails.
