import importlib.util
from pathlib import Path

p = Path(__file__).parents[1] / "analysis" / "analysis_worker.py"
spec = importlib.util.spec_from_file_location("analysis_worker", p)
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)

def test_no_fake_values_when_sensors_unavailable():
    out = mod.analyze([{"timestamp":"2026-01-01T00:00:00", "cpu_temp":None,"gpu_temp":None,"ssd_temp":None,"ram_load":42}])
    assert out["maxTemperature"] is None
    assert out["hottestComponent"] == "Unknown"
    assert out["status"] == "NORMAL"

def test_critical_temperature_is_flagged():
    hist = [{"timestamp":f"2026-01-01T00:00:{i:02d}","cpu_temp":96.0,"gpu_temp":None,"ssd_temp":None,"ram_load":40} for i in range(6)]
    out = mod.analyze(hist)
    assert out["status"] == "CRITICAL"
    assert out["anomalyDetected"] is True

def test_prediction_and_history_shape():
    hist = [{"timestamp":f"2026-01-01T00:00:{i:02d}","cpu_temp":50+i*.2,"gpu_temp":40+i*.1,"ssd_temp":42+i*.05,"cpu_load":20,"gpu_load":10,"ram_load":40,"cpu_power":15,"gpu_power":8,"top_processes":[]} for i in range(10)]
    out = mod.analyze(hist)
    assert "cpu5" in out["prediction"] and len(out["history"]["cpuTemp"]) == 10
    assert out["curveFit"]["cpuRMSE"] is not None
