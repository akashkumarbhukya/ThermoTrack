"""ThermoTrack numerical engine. Input telemetry and rolling history stay in RAM only.

This is a Python port of the project's MATLAB thermal-analysis behavior. It is
intentionally conservative: a missing/invalid sensor never becomes a zero, and
forecasts require a sufficiently long, complete, changing measurement history.
"""
from __future__ import annotations

import json
import math
import sys
from datetime import datetime
from typing import Any

import numpy as np
from scipy.optimize import brentq

# Match the original MATLAB thermalStatus thresholds.
TEMP_LIMITS = {
    "cpu": {"field": "cpu_temp", "watch": 75.0, "warning": 85.0, "critical": 95.0},
    "gpu": {"field": "gpu_temp", "watch": 70.0, "warning": 80.0, "critical": 88.0},
    "ssd": {"field": "ssd_temp", "watch": 55.0, "warning": 65.0, "critical": 75.0},
}
HOTSPOT_WATCH = 90.0
HOTSPOT_WARNING = 100.0
HOTSPOT_CRITICAL = 105.0
MIN_MODEL_SAMPLES = 20
MIN_CURVE_FIT_SAMPLES = 10
PCA_FIELDS = ["cpu_temp", "gpu_temp", "ssd_temp", "cpu_load", "gpu_load", "cpu_power", "gpu_power", "ram_load"]
PCA_LABELS = ["CPU temperature", "GPU temperature", "SSD temperature", "CPU load", "GPU load", "CPU power", "GPU power", "RAM load"]


def finite(value: Any) -> float | None:
    """Return a JSON-safe finite number, or None for unavailable values."""
    try:
        number = float(value)
        return number if math.isfinite(number) else None
    except (TypeError, ValueError, OverflowError):
        return None


def temperature(value: Any) -> float | None:
    """Validate a PC component temperature. Zero is treated as a sensor sentinel.

    The application targets ordinary PCs/laptops; 0 C and out-of-range values
    are not accepted as a live component temperature. This prevents faulty
    driver readings from being presented as a valid 0.0 C measurement.
    """
    value = finite(value)
    return value if value is not None and 0.0 < value <= 150.0 else None


def bounded(value: Any, low: float, high: float) -> float | None:
    value = finite(value)
    return value if value is not None and low <= value <= high else None


def series(history: list[dict[str, Any]], key: str) -> list[float | None]:
    if key.endswith("_temp") or key == "gpu_hotspot":
        return [temperature(row.get(key)) for row in history]
    if key.endswith("_load") or key == "ssd_activity" or key == "ram_load":
        return [bounded(row.get(key), 0.0, 100.0) for row in history]
    if key.endswith("_power"):
        return [bounded(row.get(key), 0.0, 2000.0) for row in history]
    return [finite(row.get(key)) for row in history]


def time_axis(history: list[dict[str, Any]]) -> np.ndarray:
    """Create a monotonic seconds axis from timestamps, falling back to sample order."""
    parsed: list[datetime] = []
    for row in history:
        raw = row.get("timestamp")
        try:
            value = datetime.fromisoformat(str(raw).replace("Z", "+00:00"))
            parsed.append(value)
        except (TypeError, ValueError):
            return np.arange(len(history), dtype=float)
    if not parsed:
        return np.asarray([], dtype=float)
    origin = parsed[0]
    axis = []
    for index, stamp in enumerate(parsed):
        try:
            seconds = (stamp - origin).total_seconds()
        except TypeError:  # mixed timezone-aware and naive timestamps
            return np.arange(len(history), dtype=float)
        axis.append(float(seconds))
    values = np.asarray(axis, dtype=float)
    if not np.isfinite(values).all() or np.any(np.diff(values) <= 0):
        # Timestamp collisions can occur on systems with coarse clocks. The
        # data collector samples roughly once/sec, so sample order is safer.
        return np.arange(len(history), dtype=float)
    return values


def _valid_points(history: list[dict[str, Any]], field: str, x: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    vals = series(history, field)
    pairs = [(float(x[i]), value) for i, value in enumerate(vals) if value is not None]
    if not pairs:
        return np.asarray([], dtype=float), np.asarray([], dtype=float)
    return np.asarray([item[0] for item in pairs], dtype=float), np.asarray([item[1] for item in pairs], dtype=float)


def heating_rate(history: list[dict[str, Any]], field: str, x: np.ndarray) -> float | None:
    """Fit a trailing local slope in degrees/second, needing >=3 fresh samples."""
    tx, values = _valid_points(history, field, x)
    if len(values) < 3:
        return None
    tx, values = tx[-10:], values[-10:]
    if len(x) and x[-1] - tx[-1] > 2.0:
        return None  # do not report a heating rate from a stale sensor sample
    if tx[-1] - tx[0] < 2.0 or float(np.ptp(values)) < 1e-6:
        return 0.0 if float(np.ptp(values)) < 1e-6 else None
    try:
        slope = float(np.polyfit(tx - tx[-1], values, 1)[0])
        return finite(slope)
    except (ValueError, np.linalg.LinAlgError, FloatingPointError):
        return None


def regression_forecast(seq: list[float | None], horizon_seconds: int) -> tuple[float | None, float | None, float | None]:
    """Conservative simple trend helper retained for tests/tools; not the main ODE model."""
    pairs = [(float(i), value) for i, value in enumerate(seq) if value is not None]
    if len(pairs) < MIN_MODEL_SAMPLES:
        return None, None, None
    x = np.asarray([pair[0] for pair in pairs], dtype=float)
    y = np.asarray([pair[1] for pair in pairs], dtype=float)
    if float(np.ptp(y)) < 0.05:
        return None, None, None
    try:
        slope, intercept = np.polyfit(x, y, 1)
        predicted = float(intercept + slope * (len(seq) - 1 + horizon_seconds))
        rmse = float(np.sqrt(np.mean((y - (intercept + slope * x)) ** 2)))
        ss_total = float(np.sum((y - np.mean(y)) ** 2))
        r_squared = max(0.0, 1.0 - float(np.sum((y - (intercept + slope*x))**2))/ss_total) if ss_total > 1e-12 else 0.0
        confidence = min(100.0, max(0.0, 100.0 * r_squared))
        if not math.isfinite(predicted) or not 0.0 < predicted <= 150.0:
            return None, finite(slope), None
        return finite(predicted), finite(slope), finite(confidence)
    except (ValueError, np.linalg.LinAlgError, FloatingPointError):
        return None, None, None


def thermal_ode_model(
    history: list[dict[str, Any]], x: np.ndarray, temp_field: str, load_field: str,
    power_field: str | None, current_temp: float | None, current_load: float | None,
    current_power: float | None, threshold: float,
) -> dict[str, Any]:
    """Port of MATLAB thermalODEModel, with unavailable/flat data guarded."""
    model: dict[str, Any] = {
        "valid": False, "pred5": None, "pred10": None, "pred30": None,
        "confidence": None, "bTemp": None, "equilibrium": None, "current": current_temp,
        "threshold": threshold, "rankLimited": False, "sampleCount": 0,
    }
    temps = series(history, temp_field)
    loads = series(history, load_field)
    powers = series(history, power_field) if power_field else [0.0] * len(history)
    points = [(float(x[i]), temps[i], loads[i], powers[i]) for i in range(len(history))
              if temps[i] is not None and loads[i] is not None and powers[i] is not None]
    model["sampleCount"] = len(points)

    if (len(points) < MIN_MODEL_SAMPLES or current_temp is None or current_load is None or current_power is None):
        return model
    t = np.asarray([p[0] for p in points], dtype=float)
    T = np.asarray([p[1] for p in points], dtype=float)
    L = np.asarray([p[2] for p in points], dtype=float)
    P = np.asarray([p[3] for p in points], dtype=float)
    if t[-1] - t[0] < MIN_MODEL_SAMPLES - 1 or float(np.ptp(T)) < 0.05:
        # A flat sensor trace is not evidence of a reliable model. This also
        # blocks confidence/forecasts when firmware returns a stuck value.
        return model
    try:
        dT = np.gradient(T, t)
        X = np.column_stack((np.ones(len(T)), L, P, T))
        active = np.ones(X.shape[1], dtype=bool)
        for column in range(1, X.shape[1]):
            scale = max(1.0, float(np.max(np.abs(X[:, column]))))
            if float(np.ptp(X[:, column])) <= 1e-8 * scale:
                active[column] = False
        Xfit = X[:, active]
        rank = int(np.linalg.matrix_rank(Xfit))
        rank_limited = rank < Xfit.shape[1]
        beta_fit = np.linalg.pinv(Xfit) @ dT if rank_limited else np.linalg.lstsq(Xfit, dT, rcond=None)[0]
        beta = np.zeros(X.shape[1], dtype=float)
        beta[active] = beta_fit
        yhat = Xfit @ beta_fit
        ss_res = float(np.sum((dT-yhat)**2))
        ss_total = float(np.sum((dT-np.mean(dT))**2))
        r2 = max(0.0, 1.0 - ss_res/ss_total) if ss_total > 1e-12 else 0.0
        confidence = min(100.0, max(0.0, 100.0*r2))
        if rank_limited or any(not value for value in active[1:]):
            confidence = min(confidence, 30.0)

        b_temp = float(beta[3])
        model.update({"valid": True, "confidence": finite(confidence), "bTemp": finite(b_temp), "rankLimited": bool(rank_limited or any(not value for value in active[1:]))})
        horizons = (300.0, 600.0, 1800.0)
        if b_temp >= -1e-5:
            # Unstable/local fit: limited linear extrapolation with <=30% confidence.
            count = min(20, len(T))
            slope, intercept = np.polyfit(t[-count:] - t[-1], T[-count:], 1)
            predictions = [float(intercept + slope*h) for h in horizons]
            model["confidence"] = min(float(model["confidence"] or 0.0), 30.0)
        else:
            forcing = float(beta[0] + beta[1]*current_load + beta[2]*current_power)
            equilibrium = -forcing / b_temp
            model["equilibrium"] = finite(equilibrium)
            predictions = [float(equilibrium + (current_temp-equilibrium)*math.exp(b_temp*h)) for h in horizons]
        keys = ("pred5", "pred10", "pred30")
        for key, predicted in zip(keys, predictions):
            model[key] = finite(predicted) if math.isfinite(predicted) and 0.0 < predicted <= 150.0 else None
        if all(model[key] is None for key in keys):
            model["confidence"] = None
            model["valid"] = False
        return model
    except (ValueError, np.linalg.LinAlgError, FloatingPointError, OverflowError, ZeroDivisionError):
        return model


def threshold_seconds(model: dict[str, Any], threshold: float) -> tuple[float | None, float | None]:
    """Return first threshold crossing in seconds using bisection and Newton-Raphson."""
    if not model.get("valid") or model.get("pred30") is None:
        return None, None
    b_temp = finite(model.get("bTemp"))
    equilibrium = finite(model.get("equilibrium"))
    current = temperature(model.get("current"))
    if b_temp is None or b_temp >= 0 or equilibrium is None or current is None:
        return None, None
    if current >= threshold:
        return 0.0, 0.0
    initial = current
    f = lambda seconds: equilibrium + (initial-equilibrium)*math.exp(b_temp*seconds) - threshold
    try:
        if f(0.0) >= 0:
            return 0.0, 0.0
        if f(1800.0) < 0:
            return None, None
        root_bis = float(brentq(f, 0.0, 1800.0, xtol=1e-6, maxiter=100))
        lo, hi = 0.0, 1800.0
        value = min(max(root_bis*0.8, lo), hi)
        for _ in range(30):
            fx = f(value)
            derivative = b_temp*(equilibrium + (initial-equilibrium)*math.exp(b_temp*value) - equilibrium)
            if abs(derivative) < 1e-10:
                break
            candidate = value - fx/derivative
            if not math.isfinite(candidate) or candidate <= lo or candidate >= hi:
                candidate = (lo+hi)/2.0
            if f(candidate) >= 0:
                hi = candidate
            else:
                lo = candidate
            value = candidate
            if abs(fx) < 1e-4:
                break
        return finite(root_bis), finite(value)
    except (ValueError, RuntimeError, OverflowError):
        return None, None


def solve_linear(A: Any, b: Any, method: str = "jacobi", tol: float = 1e-4, max_iter: int = 500, x0: Any | None = None) -> tuple[int, bool]:
    """Iterative Jacobi/Gauss-Seidel solver used by the educational thermal model."""
    A = np.asarray(A, dtype=float)
    b = np.asarray(b, dtype=float)
    x = np.asarray(x0, dtype=float).copy() if x0 is not None else np.zeros(len(b), dtype=float)
    converged = False
    for iteration in range(1, max_iter+1):
        old = x.copy()
        for i in range(len(b)):
            if A[i, i] == 0:
                return iteration, False
            if method.lower() == "jacobi":
                sigma = float(np.dot(A[i, :], old) - A[i, i]*old[i])
            else:
                sigma = float(sum(A[i, j]*(x[j] if j < i else old[j]) for j in range(len(b)) if j != i))
            x[i] = (b[i]-sigma)/A[i, i]
        if np.linalg.norm(x-old, ord=np.inf) < tol:
            converged = True
            break
    return iteration, converged


def _curve_fit(history: list[dict[str, Any]], x: np.ndarray, field: str) -> float | None:
    tx, values = _valid_points(history, field, x)
    if len(values) < MIN_CURVE_FIT_SAMPLES:
        return None
    sample_x = np.arange(len(values), dtype=float)
    try:
        degree = min(2, len(values)-1)
        coefficients = np.polyfit(sample_x, values, degree)
        predicted = np.polyval(coefficients, sample_x)
        return finite(float(np.sqrt(np.mean((values-predicted)**2))))
    except (ValueError, np.linalg.LinAlgError, FloatingPointError):
        return None


def _pca(history: list[dict[str, Any]]) -> dict[str, Any]:
    result = {"explainedPC1": None, "explainedPC2": None, "dominantFactor": "Insufficient data"}
    if not history:
        return result
    columns = [series(history, key) for key in PCA_FIELDS]
    matrix = []
    for row in range(len(history)):
        values = [column[row] for column in columns]
        if all(value is not None for value in values):
            matrix.append(values)
    if len(matrix) < MIN_MODEL_SAMPLES:
        return result
    values = np.asarray(matrix, dtype=float)
    values -= values.mean(axis=0)
    std = values.std(axis=0, ddof=1)
    std[std < np.finfo(float).eps] = 1.0
    normalized = values/std
    try:
        _, singular, vh = np.linalg.svd(normalized, full_matrices=False)
        variance = singular**2
        total = float(variance.sum())
        if total <= 0:
            return result
        explained = variance/total*100.0
        result = {
            "explainedPC1": finite(explained[0]) if len(explained) else None,
            "explainedPC2": finite(explained[1]) if len(explained) > 1 else None,
            "dominantFactor": PCA_LABELS[int(np.argmax(np.abs(vh[0])))] if len(vh) else "Insufficient data",
        }
    except (ValueError, np.linalg.LinAlgError, FloatingPointError):
        pass
    return result


def _coupling(current: dict[str, float | None]) -> dict[str, Any]:
    out = {"jacobiIterations": 0, "gaussSeidelIterations": 0, "jacobiConverged": False,
           "gaussSeidelConverged": False, "maxEigenRealPart": None, "stability": "Insufficient data"}
    needed = [current.get(k) for k in ("cpu", "gpu", "ssd", "cpu_power", "gpu_power", "ssd_activity")]
    if any(value is None for value in needed):
        return out
    cpu, gpu, ssd, cpu_power, gpu_power, ssd_activity = [float(value) for value in needed]
    ambient = 25.0
    g12, g13, g23 = 0.08, 0.03, 0.04
    h1, h2, h3 = 0.20, 0.18, 0.12
    A = np.asarray([[h1+g12+g13, -g12, -g13], [-g12, h2+g12+g23, -g23], [-g13, -g23, h3+g13+g23]], dtype=float)
    Q = np.asarray([cpu_power+h1*ambient, gpu_power+h2*ambient, 0.15*ssd_activity+h3*ambient], dtype=float)
    temperatures = np.asarray([cpu, gpu, ssd], dtype=float)
    ji, jc = solve_linear(A, Q, "jacobi", tol=1e-4, max_iter=500, x0=temperatures)
    gi, gc = solve_linear(A, Q, "gauss-seidel", tol=1e-4, max_iter=500, x0=temperatures)
    eigenvalues = np.linalg.eigvals(A)
    max_real = float(np.max(np.real(eigenvalues)))
    return {"jacobiIterations": ji, "gaussSeidelIterations": gi, "jacobiConverged": jc,
            "gaussSeidelConverged": gc, "maxEigenRealPart": finite(max_real),
            "stability": "Stable thermal-balance matrix" if np.all(np.real(eigenvalues) > 0) else "Review thermal-balance model"}


def _fmt_temp(v: float | None) -> str:
    return f"{v:.1f} °C" if v is not None else "unavailable"


def _fmt_percent(v: float | None) -> str:
    return f"{v:.0f}%" if v is not None else "unavailable"


def _fmt_power(v: float | None) -> str:
    return f"{v:.1f} W" if v is not None else "unavailable"


def _fmt_rate(v: float | None) -> str:
    return f"{v:.3f} °C/s" if v is not None else "unavailable"


def forecast_alert_levels(prediction: dict[str, Any]) -> tuple[bool, bool]:
    """Return (watch, warning) flags using the original MATLAB's 10-minute bands."""
    cpu = temperature(prediction.get("cpu10"))
    gpu = temperature(prediction.get("gpu10"))
    ssd = temperature(prediction.get("ssd10"))
    watch = ((cpu is not None and cpu >= TEMP_LIMITS["cpu"]["warning"]) or
             (gpu is not None and gpu >= TEMP_LIMITS["gpu"]["warning"]) or
             (ssd is not None and ssd >= TEMP_LIMITS["ssd"]["warning"]))
    warning = ((cpu is not None and cpu >= TEMP_LIMITS["cpu"]["critical"]) or
               (gpu is not None and gpu >= TEMP_LIMITS["gpu"]["critical"]) or
               (ssd is not None and ssd >= TEMP_LIMITS["ssd"]["critical"]))
    return watch, warning


def analyze(history: list[dict[str, Any]]) -> dict[str, Any]:
    # Bound history defensively even if a caller sends more than the collector's 300 samples.
    history = list(history or [])[-300:]
    x = time_axis(history)
    out: dict[str, Any] = {
        "timestamp": datetime.now().isoformat(timespec="seconds"), "status": "SENSOR_UNAVAILABLE",
        "hottestComponent": "Unknown", "maxTemperature": None,
        "cause": "No hardware temperature sensor has reported a valid reading yet.", "causeComponent": "Unknown",
        "recommendation": "Check sensor availability and continue monitoring; no readings are fabricated.",
        "anomaly": "Hardware temperature data unavailable.", "anomalyDetected": False,
        "prediction": {}, "modelConfidence": {}, "timeToCritical": {}, "pca": _pca([]),
        "coupling": {"jacobiIterations": 0, "gaussSeidelIterations": 0, "jacobiConverged": False,
                     "gaussSeidelConverged": False, "maxEigenRealPart": None, "stability": "Insufficient data"},
        "curveFit": {"cpuRMSE": None, "gpuRMSE": None, "ssdRMSE": None}, "history": {},
        "safety": {"manualActionOnly": True, "message": "ThermoTrack is advisory only. Check manufacturer limits and shut down if the system becomes unstable."},
    }
    fields = {key: item["field"] for key, item in TEMP_LIMITS.items()}
    current: dict[str, float | None] = {}
    rates: dict[str, float | None] = {}
    models: dict[str, dict[str, Any]] = {}

    # Use the latest sample as the current value. Do not reuse an older value if
    # the latest sample says the sensor is now unavailable.
    latest = history[-1] if history else {}
    for key, field in fields.items():
        current[key] = temperature(latest.get(field))
        rates[key] = heating_rate(history, field, x) if history and current[key] is not None else None
        out[key+"HeatingRate"] = finite(rates[key])
        out["curveFit"][key+"RMSE"] = _curve_fit(history, x, field) if history else None

    current["gpu_hotspot"] = temperature(latest.get("gpu_hotspot"))
    current["cpu_load"] = bounded(latest.get("cpu_load"), 0, 100)
    current["gpu_load"] = bounded(latest.get("gpu_load"), 0, 100)
    current["cpu_power"] = bounded(latest.get("cpu_power"), 0, 2000)
    current["gpu_power"] = bounded(latest.get("gpu_power"), 0, 2000)
    current["ssd_activity"] = bounded(latest.get("ssd_activity"), 0, 100)

    for key in ("cpu", "gpu", "ssd"):
        field = fields[key]
        load_field = {"cpu": "cpu_load", "gpu": "gpu_load", "ssd": "ssd_activity"}[key]
        power_field = {"cpu": "cpu_power", "gpu": "gpu_power", "ssd": None}[key]
        current_power = current["cpu_power"] if key == "cpu" else current["gpu_power"] if key == "gpu" else (0.0 if current["ssd_activity"] is not None else None)
        models[key] = thermal_ode_model(history, x, field, load_field, power_field,
                                        current[key], bounded(latest.get(load_field), 0, 100), current_power,
                                        TEMP_LIMITS[key]["critical"])
        model = models[key]
        out["modelConfidence"][key] = finite(model.get("confidence")) if model.get("valid") else None
        for minutes in (5, 10, 30):
            out["prediction"][key+str(minutes)] = finite(model.get("pred"+str(minutes))) if model.get("valid") else None
        bis, newton = threshold_seconds(model, TEMP_LIMITS[key]["critical"])
        out["timeToCritical"][key+"Bisection"] = bis
        out["timeToCritical"][key+"Newton"] = newton

    valid = {key.upper(): value for key, value in current.items() if key in fields and value is not None}
    if valid:
        hottest = max(valid, key=valid.get)
        out["hottestComponent"] = hottest
        out["maxTemperature"] = finite(valid[hottest])

    hotspot = current["gpu_hotspot"]
    temp_specs = (("CPU", current["cpu"], 75.0, 85.0, 95.0, rates["cpu"], history, "cpu_temp"),
                  ("GPU", current["gpu"], 70.0, 80.0, 88.0, rates["gpu"], history, "gpu_temp"),
                  ("SSD", current["ssd"], 55.0, 65.0, 75.0, rates["ssd"], history, "ssd_temp"))
    flags: list[str] = []
    critical = False
    warning = False
    watch = False
    for name, value, watch_limit, warning_limit, critical_limit, rate, rows, field in temp_specs:
        if value is not None:
            if value >= critical_limit:
                flags.append(f"{name} critical at {_fmt_temp(value)}"); critical = True
            elif value >= warning_limit:
                flags.append(f"{name} high at {_fmt_temp(value)}"); warning = True
            elif value >= watch_limit:
                flags.append(f"{name} elevated at {_fmt_temp(value)}"); watch = True
        temps = series(rows, field)
        temps = [t for t in temps if t is not None]
        rise10 = (temps[-1]-temps[-11]) if len(temps) >= 11 else None
        if (rise10 is not None and rise10 >= 2.0) or (rate is not None and rate >= 0.04):
            rise_text = f"{rise10:+.1f} °C over ~10 s" if rise10 is not None else _fmt_rate(rate)
            flags.append(f"{name} temperature rising rapidly ({rise_text})"); warning = True
        elif (rise10 is not None and rise10 >= 0.8) or (rate is not None and rate >= 0.015):
            flags.append(f"{name} temperature is rising; monitor closely"); watch = True

    if hotspot is not None:
        if hotspot >= HOTSPOT_CRITICAL:
            flags.append(f"GPU hotspot critical at {_fmt_temp(hotspot)}"); critical = True
        elif hotspot >= HOTSPOT_WARNING:
            flags.append(f"GPU hotspot high at {_fmt_temp(hotspot)}"); warning = True
        elif hotspot >= HOTSPOT_WATCH:
            flags.append(f"GPU hotspot elevated at {_fmt_temp(hotspot)}"); watch = True

    # Match the original MATLAB prediction policy: reaching a warning-level
    # temperature within 10 minutes may raise NORMAL to WATCH. A predicted
    # critical-level temperature raises NORMAL/WATCH to WARNING, never directly
    # to CRITICAL because predictions are advisory rather than measurements.
    forecast_watch, forecast_warning = forecast_alert_levels(out["prediction"])

    if critical:
        status = "CRITICAL"
    elif warning or forecast_warning:
        status = "WARNING"
    elif watch or forecast_watch:
        status = "WATCH"
    elif valid:
        status = "NORMAL"
    else:
        status = "SENSOR_UNAVAILABLE"

    if status == "SENSOR_UNAVAILABLE":
        anomaly = "Hardware temperature data unavailable."
        recommendation = "Check sensor support/permissions. Live temperatures and forecasts are unavailable; no readings are fabricated."
    elif flags:
        prefix = "CRITICAL — " if critical else "WARNING — " if warning else "WATCH — "
        anomaly = prefix + "; ".join(flags)
        recommendation = ("CRITICAL: stop heavy workloads now, allow the system to cool, and shut down normally if temperatures remain critical."
                          if critical else "WARNING: reduce CPU/GPU workload, close unnecessary high-load apps, keep vents unobstructed, and check that fans are operating."
                          if warning else "WATCH: temperature is elevated or rising. Avoid starting another heavy workload and monitor the next readings.")
    elif status != "NORMAL":
        anomaly = f"Heating trend requires attention; system status is {status}."
        recommendation = "Monitor the next readings and inspect cooling if the trend persists."
    else:
        anomaly = "No significant thermal anomaly detected."
        recommendation = "Temperatures are within the prototype thresholds. Keep vents clear."

    out["status"] = status
    out["anomalyDetected"] = status in {"WATCH", "WARNING", "CRITICAL"}
    out["anomaly"] = anomaly
    out["recommendation"] = recommendation

    # Explain the most likely contributor using corroborating workload signals;
    # this is a heuristic, not proof of causation.
    cpu, gpu, ssd = current["cpu"], current["gpu"], current["ssd"]
    cpu_load, gpu_load = current["cpu_load"], current["gpu_load"]
    cpu_power, gpu_power, ssd_activity = current["cpu_power"], current["gpu_power"], current["ssd_activity"]
    cause_component = out["hottestComponent"] if valid else "Unknown"
    cause_text = "No hardware temperature sensors reported readable values."
    if valid:
        if cpu is not None and (cpu >= 75 or (rates["cpu"] is not None and rates["cpu"] >= 0.015)):
            cause_component = "CPU"
            if ((cpu_load is not None and cpu_load >= 60) or (cpu_power is not None and cpu_power >= 25)):
                cause_text = f"CPU temperature is {_fmt_temp(cpu)} with CPU load {_fmt_percent(cpu_load)} and package power {_fmt_power(cpu_power)}. Sustained CPU workload/power is a likely heat contributor."
            elif cpu_load is not None and cpu_load < 30 and cpu_power is not None and cpu_power < 20 and cpu >= 75:
                cause_text = f"CPU is hot at {_fmt_temp(cpu)} despite relatively low reported load/power. Check fan operation, blocked vents, dust, surface clearance, and room temperature."
            else:
                cause_text = f"CPU temperature is {_fmt_temp(cpu)} and its recent heating rate is {_fmt_rate(rates['cpu'])}. Compare load/power and inspect airflow if it stays high."
        elif gpu is not None and (gpu >= 70 or (rates["gpu"] is not None and rates["gpu"] >= 0.015) or (hotspot is not None and hotspot >= 90)):
            cause_component = "GPU"
            if ((gpu_load is not None and gpu_load >= 60) or (gpu_power is not None and gpu_power >= 30)):
                cause_text = f"GPU temperature is {_fmt_temp(gpu)} (hotspot {_fmt_temp(hotspot)}), with GPU load {_fmt_percent(gpu_load)} and power {_fmt_power(gpu_power)}. Sustained GPU work is a likely contributor."
            else:
                cause_text = "GPU temperature/hotspot is elevated or rising without a strong current GPU-load signal. Check airflow and fan operation; the sensors cannot identify an exact cause."
        elif ssd is not None and (ssd >= 55 or (rates["ssd"] is not None and rates["ssd"] >= 0.015)):
            cause_component = "SSD"
            if ssd_activity is not None and ssd_activity >= 50:
                cause_text = f"SSD temperature is {_fmt_temp(ssd)} with disk activity {_fmt_percent(ssd_activity)}. Sustained disk activity may be contributing to SSD heating."
            else:
                cause_text = f"SSD temperature is {_fmt_temp(ssd)} despite modest reported disk activity. Check airflow around the drive and monitor its trend; exact cause is uncertain."
        else:
            cause_text = "Temperatures are available, but current load/activity does not identify one dominant source. Heat soak, cooling performance, workload changes, and ambient temperature may contribute."
    out["causeComponent"] = cause_component
    out["cause"] = cause_text
    processes = latest.get("top_processes", []) if isinstance(latest, dict) else []
    active = [p for p in processes if isinstance(p, dict) and finite(p.get("cpu")) is not None and float(p.get("cpu", 0)) > 0.1]
    out["topProcess"] = (f"{active[0].get('name', 'Unknown')} ({float(active[0]['cpu']):.1f}% CPU)" if active else "No CPU-heavy process identified")

    out["pca"] = _pca(history)
    out["coupling"] = _coupling(current)
    last = history[-60:]
    out["history"] = {
        "time": [str(row.get("timestamp", ""))[11:19] for row in last],
        "cpuTemp": [temperature(row.get("cpu_temp")) for row in last],
        "gpuTemp": [temperature(row.get("gpu_temp")) for row in last],
        "ssdTemp": [temperature(row.get("ssd_temp")) for row in last],
        "cpuLoad": [bounded(row.get("cpu_load"), 0, 100) for row in last],
        "gpuLoad": [bounded(row.get("gpu_load"), 0, 100) for row in last],
        "cpuPower": [bounded(row.get("cpu_power"), 0, 2000) for row in last],
        "gpuPower": [bounded(row.get("gpu_power"), 0, 2000) for row in last],
        "ramLoad": [bounded(row.get("ram_load"), 0, 100) for row in last],
    }
    return out


def main() -> None:
    """Process newline-delimited JSON requests, ignoring blank transport lines.

    Some Windows process/pipe combinations can deliver an empty line before the
    first request or between requests. Blank lines are framing noise, not JSON
    requests, and must not turn a healthy worker response into an ERROR result.
    Exactly one JSON response is emitted for each non-empty request line.
    """
    for line in sys.stdin:
        if not line.strip():
            continue
        try:
            request = json.loads(line)
            if not isinstance(request, dict):
                raise ValueError("Each analysis request must be a JSON object.")
            history = request.get("history", [])
            if history is None:
                history = []
            if not isinstance(history, list):
                raise ValueError("The analysis request 'history' property must be a JSON array.")
            result = analyze(history)
            print(json.dumps(result, separators=(",", ":"), allow_nan=False), flush=True)
        except Exception as exc:  # keep the worker protocol alive, but never print non-JSON to stdout
            print(json.dumps({"status": "ERROR", "error": str(exc)}, separators=(",", ":"), allow_nan=False), flush=True)


if __name__ == "__main__":
    main()
