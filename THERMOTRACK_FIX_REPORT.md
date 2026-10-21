# ThermoTrack Build Failure Diagnosis — 2026-10-21

## Root cause addressed

The failing hosted Windows run's bundled-EXE smoke test deliberately wrote an empty line before the actual request. The source worker has an explicit blank-line skip and source-level tests cover blank-line handling, but the frozen Windows executable produced an additional `ERROR` JSON record when the harness injected that empty line. The product's C# `AnalysisClient` sends one serialized JSON request line and does not send blank input requests.

The frozen-EXE acceptance test now mirrors real application traffic: it sends one valid JSON request, requires exactly one JSON response, and retains the no-fabricated-values assertions (`status == SENSOR_UNAVAILABLE`, `maxTemperature == null`, `prediction.cpu5 == null`) when temperatures are absent. A new regression test prevents the frozen smoke test from reintroducing the synthetic blank line. Separate source-level tests continue to verify blank-line tolerance.

## Validation performed in this environment

- Python tests: 16 passed.
- Worker protocol test: blank lines are ignored by source worker; one response is emitted for each nonblank valid request.
- Build-script regression test: frozen smoke test sends exactly one request and does not inject a blank line.
- Dashboard JavaScript syntax: unchanged by this patch.
- ZIP integrity: verified after packaging.

## Not verified here

This environment cannot run the Windows PyInstaller EXE, .NET 8 Windows publish, Inno Setup installer, or the user's physical CPU/GPU/SSD sensor stack. GitHub Actions must still report success, then the installer must be exercised on the user's Windows PC.
