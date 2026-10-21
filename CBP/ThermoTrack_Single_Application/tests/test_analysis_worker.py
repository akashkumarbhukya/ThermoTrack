import importlib.util
from datetime import datetime, timedelta
from pathlib import Path

p = Path(__file__).parents[1] / "analysis" / "analysis_worker.py"
spec = importlib.util.spec_from_file_location("analysis_worker", p)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def rows(count=30, start_cpu=45.0):
    base = datetime(2026, 1, 1)
    result = []
    cpu, gpu, ssd = start_cpu, 40.0, 43.0
    for i in range(count):
        cpu_load = 22.0 + (i % 7) * 2.0
        cpu_power = 11.0 + (i % 5) * 0.8
        gpu_load = 15.0 + (i % 6) * 3.0
        gpu_power = 8.0 + (i % 4) * 0.6
        ssd_activity = 10.0 + (i % 5) * 4.0
        # Slight temperature evolution plus a deterministic ripple creates a
        # non-flat series without hard-coding any dashboard measurement.
        cpu += 0.08 + 0.015 * ((i % 3) - 1)
        gpu += 0.05 + 0.01 * ((i % 4) - 1.5)
        ssd += 0.035 + 0.008 * ((i % 4) - 1.5)
        result.append({
            "timestamp": (base + timedelta(seconds=i)).isoformat(timespec="milliseconds"),
            "cpu_temp": cpu, "cpu_load": cpu_load, "cpu_power": cpu_power,
            "gpu_temp": gpu, "gpu_hotspot": gpu + 5.5, "gpu_load": gpu_load, "gpu_power": gpu_power,
            "ssd_temp": ssd, "ssd_activity": ssd_activity,
            "ram_load": 43.0 + (i % 3), "top_processes": [{"name": "TestLoad", "cpu": 12.5}],
        })
    return result


def test_missing_sensor_values_stay_missing_and_status_is_not_normal():
    out = mod.analyze([{"timestamp": "2026-01-01T00:00:00", "cpu_temp": None, "gpu_temp": None,
                        "ssd_temp": None, "ram_load": 42}])
    assert out["maxTemperature"] is None
    assert out["hottestComponent"] == "Unknown"
    assert out["status"] == "SENSOR_UNAVAILABLE"
    assert all(v is None for v in out["prediction"].values())
    assert all(v is None for v in out["modelConfidence"].values())


def test_zero_temperature_sensor_sentinel_is_not_reported_as_valid():
    out = mod.analyze([{"timestamp": "2026-01-01T00:00:00", "cpu_temp": 0.0, "gpu_temp": None,
                        "ssd_temp": None, "ram_load": 42}])
    assert out["maxTemperature"] is None
    assert out["status"] == "SENSOR_UNAVAILABLE"
    assert out["history"]["cpuTemp"] == [None]


def test_critical_cpu_temperature_is_flagged():
    hist = [{"timestamp": (datetime(2026, 1, 1) + timedelta(seconds=i)).isoformat(),
             "cpu_temp": 96.0, "gpu_temp": None, "ssd_temp": None, "ram_load": 40} for i in range(6)]
    out = mod.analyze(hist)
    assert out["status"] == "CRITICAL"
    assert out["anomalyDetected"] is True
    assert "CPU critical" in out["anomaly"]


def test_insufficient_history_does_not_show_forecasts_or_confidence():
    out = mod.analyze(rows(10))
    assert "cpu5" in out["prediction"] and len(out["history"]["cpuTemp"]) == 10
    assert out["prediction"]["cpu5"] is None
    assert out["modelConfidence"]["cpu"] is None
    assert out["curveFit"]["cpuRMSE"] is not None  # 10 valid readings suffice for the display-fit metric.


def test_flat_temperature_trace_does_not_receive_a_forecast_or_confidence():
    history = rows(30)
    for row in history:
        row["cpu_temp"] = 45.0
    out = mod.analyze(history)
    assert out["prediction"]["cpu5"] is None
    assert out["modelConfidence"]["cpu"] is None


def test_complete_varying_history_enables_a_real_model():
    out = mod.analyze(rows(40))
    assert out["prediction"]["cpu5"] is not None
    assert out["prediction"]["gpu5"] is not None
    assert out["modelConfidence"]["cpu"] is not None
    assert 0 <= out["modelConfidence"]["cpu"] <= 100


def test_heating_rate_is_in_degrees_per_second():
    history = []
    base = datetime(2026, 1, 1)
    for i in range(10):
        history.append({"timestamp": (base + timedelta(seconds=i)).isoformat(), "cpu_temp": 40 + 0.1*i})
    rate = mod.heating_rate(history, "cpu_temp", mod.time_axis(history))
    assert rate is not None
    assert abs(rate - 0.1) < 0.005


def test_threshold_times_use_seconds_for_dashboard_minute_conversion():
    model = {"valid": True, "pred30": 90.0, "pred5": 53.3, "bTemp": -0.001,
             "equilibrium": 100.0, "current": 40.0}
    bisection, newton = mod.threshold_seconds(model, 80.0)
    assert bisection is not None and newton is not None
    assert 0 < bisection <= 1800
    assert abs(bisection-newton) < 1.0


def test_pca_does_not_impute_missing_sensors_as_zero():
    out = mod.analyze(rows(25))
    assert out["pca"]["dominantFactor"] != "Insufficient data"  # complete valid feature rows
    missing = rows(25)
    for row in missing:
        row["ssd_temp"] = None
    out_missing = mod.analyze(missing)
    assert out_missing["pca"]["dominantFactor"] == "Insufficient data"
    assert out_missing["pca"]["explainedPC1"] is None


def test_threshold_warning_matches_original_gpu_limit():
    history = rows(3)
    history[-1]["gpu_temp"] = 89.0
    out = mod.analyze(history)
    assert out["status"] == "CRITICAL"
    assert "GPU critical" in out["anomaly"]


def test_no_active_process_is_falsely_selected_from_zero_cpu_rows():
    history = rows(1)
    history[0]["top_processes"] = [{"name": "ThermoTrack", "cpu": 0.0}]
    out = mod.analyze(history)
    assert out["topProcess"] == "No CPU-heavy process identified"
