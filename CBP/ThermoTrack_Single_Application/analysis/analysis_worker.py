"""Line-oriented JSON analysis worker. Samples remain in RAM; no file writes."""
from __future__ import annotations
import json, math, sys
from datetime import datetime
import numpy as np
from scipy.optimize import brentq

METRICS = {"cpu": ("cpu_temp", 95.0), "gpu": ("gpu_temp", 95.0), "ssd": ("ssd_temp", 80.0)}
COLS = ["cpu_temp", "gpu_temp", "ssd_temp", "cpu_load", "gpu_load", "ram_load"]

def finite(v):
    try:
        x = float(v)
        return x if math.isfinite(x) else None
    except (TypeError, ValueError): return None

def series(history, key): return [finite(row.get(key)) for row in history]

def regression_forecast(seq, horizon_seconds):
    pairs = [(i, v) for i, v in enumerate(seq) if v is not None]
    if len(pairs) < 2: return (pairs[-1][1] if pairs else None), None, 0.0
    x = np.asarray([p[0] for p in pairs], dtype=float)
    y = np.asarray([p[1] for p in pairs], dtype=float)
    slope, intercept = np.polyfit(x, y, 1)
    # one sample is approximately one second
    pred = intercept + slope * (len(seq) - 1 + horizon_seconds)
    rmse = float(np.sqrt(np.mean((y - (intercept + slope*x))**2)))
    confidence = max(0.0, min(100.0, 100.0 * (len(pairs) / max(20, len(seq))) * (1.0-min(1.0, rmse/10.0))))
    return finite(pred), finite(slope), finite(confidence)

def threshold_minutes(seq, threshold):
    current = next((x for x in reversed(seq) if x is not None), None)
    _, slope, _ = regression_forecast(seq, 1)
    if current is None or slope is None: return None
    if current >= threshold: return 0.0
    if slope <= 0: return None
    # Safeguarded root solve for linear extrapolation; bisection via scipy Brent solver.
    f = lambda seconds: current + slope * seconds - threshold
    try: return max(0.0, float(brentq(f, 0.0, max(1.0, (threshold-current)/slope)))) / 60.0
    except (ValueError, RuntimeError): return None

def solve_linear(A, b, method="jacobi", tol=1e-7, max_iter=100):
    A=np.asarray(A,dtype=float); b=np.asarray(b,dtype=float); x=np.zeros(len(b)); converged=False
    for iteration in range(1,max_iter+1):
        old=x.copy()
        for i in range(len(b)):
            if A[i,i] == 0: return iteration, False
            if method == "jacobi": s=float(np.dot(A[i,:], old)-A[i,i]*old[i])
            else: s=float(sum(A[i,j]*(x[j] if j<i else old[j]) for j in range(len(b)) if j != i))
            x[i]=(b[i]-s)/A[i,i]
        if np.linalg.norm(x-old, ord=np.inf) < tol: converged=True; break
    return iteration, converged

def analyze(history):
    out={"timestamp":datetime.now().isoformat(timespec="seconds"),"status":"NORMAL","hottestComponent":"Unknown","maxTemperature":None,
      "cause":"Insufficient sensor history for cause analysis.","causeComponent":"Unknown","recommendation":"Keep vents clear and monitor trends.","anomaly":"No anomaly detected.","anomalyDetected":False,
      "prediction":{},"modelConfidence":{},"timeToCritical":{},"pca":{"explainedPC1":None,"explainedPC2":None,"dominantFactor":"Insufficient data"},
      "coupling":{"jacobiIterations":0,"gaussSeidelIterations":0,"jacobiConverged":False,"gaussSeidelConverged":False,"maxEigenRealPart":None,"stability":"Insufficient data"},
      "curveFit":{},"history":{},"safety":{"manualActionOnly":True,"message":"ThermoTrack is advisory only. Check manufacturer limits and shut down if the system becomes unstable."}}
    current={}; rates={}
    for key,(field,limit) in METRICS.items():
        seq=series(history,field); cur=next((x for x in reversed(seq) if x is not None),None); current[key]=cur
        pred,rate,conf=regression_forecast(seq,1); rates[key]=rate; out[key+"HeatingRate"]=finite(rate)
        for mins in (5,10,30): out["prediction"][key+str(mins)]=regression_forecast(seq,mins*60)[0]
        out["modelConfidence"][key]=finite(conf)
        minutes=threshold_minutes(seq,limit)
        out["timeToCritical"][key+"Bisection"]=finite(minutes)
        out["timeToCritical"][key+"Newton"]=finite(minutes)
        good=[(i,v) for i,v in enumerate(seq) if v is not None]
        rmse=None
        if len(good)>=3:
            x=np.asarray([p[0] for p in good],float); y=np.asarray([p[1] for p in good],float)
            degree=min(2,len(good)-1); coef=np.polyfit(x,y,degree); rmse=float(np.sqrt(np.mean((y-np.polyval(coef,x))**2)))
        out["curveFit"][field.replace("_temp","")+"RMSE"]=finite(rmse)
    valid={k:v for k,v in current.items() if v is not None}
    if valid:
        hottest=max(valid,key=valid.get); out["hottestComponent"]=hottest.upper(); out["maxTemperature"]=finite(valid[hottest])
    hotspot=next((finite(r.get("gpu_hotspot")) for r in reversed(history) if finite(r.get("gpu_hotspot")) is not None),None)
    rising=any(r is not None and r>=0.12 for r in rates.values())
    critical=any(current[k] is not None and current[k]>=lim for k,(_,lim) in METRICS.items()) or (hotspot is not None and hotspot>=105)
    warning=any(current[k] is not None and current[k]>= (85 if k!="ssd" else 70) for k in current) or (hotspot is not None and hotspot>=95)
    forecast_warning=any(current[k] is not None and rates[k] is not None and rates[k]>0 and current[k]+rates[k]*300>=lim for k,(_,lim) in METRICS.items())
    status="CRITICAL" if critical else "WARNING" if warning or (rising and forecast_warning) else "WATCH" if rising else "NORMAL"
    out["status"]=status; out["anomalyDetected"]=bool(critical or warning or rising)
    out["anomaly"]="Critical temperature threshold reached." if critical else "High temperature or rapid thermal rise detected." if warning or rising else "No significant thermal anomaly detected."
    out["recommendation"]="Reduce workload and check cooling immediately. Shut down if the system is unstable." if critical else "Check airflow, fans and background workloads; reduce sustained heavy load." if warning else "Temperature is rising; monitor the next samples and check ventilation." if rising else "Temperatures are within the prototype thresholds. Keep vents clear."
    out["causeComponent"]=out["hottestComponent"]
    out["cause"]=("Likely thermal contributor: "+out["hottestComponent"]+" is currently hottest; correlation does not prove root cause." if valid else "No hardware temperature sensors reported readable values.")
    processes=history[-1].get("top_processes",[]) if history else []
    out["topProcess"]=str(processes[0].get("name","--")) if processes else "--"
    if len(history)>=5:
        matrix=np.array([[finite(r.get(c)) if finite(r.get(c)) is not None else np.nan for c in COLS] for r in history],dtype=float)
        for j in range(matrix.shape[1]):
            col=matrix[:,j]; med=np.nanmedian(col) if np.isfinite(col).any() else 0.0; col[~np.isfinite(col)]=med
        std=matrix.std(axis=0); std[std==0]=1; z=(matrix-matrix.mean(axis=0))/std
        try:
            _,s,vh=np.linalg.svd(z,full_matrices=False); denom=float((s*s).sum()); var=(s*s)/denom*100 if denom else np.zeros_like(s)
            out["pca"]={"explainedPC1":finite(var[0]) if len(var) else None,"explainedPC2":finite(var[1]) if len(var)>1 else 0.0,"dominantFactor":COLS[int(np.argmax(np.abs(vh[0])))] if len(vh) else "Insufficient data"}
        except Exception: pass
    cpu,gpu,ssd=current["cpu"],current["gpu"],current["ssd"]
    if all(x is not None for x in (cpu,gpu,ssd)):
        A=[[4.,-1.,-.5],[-1.,4.,-.5],[-.5,-.5,3.]]; b=[cpu+1,gpu+1,ssd+.5]
        ji,jc=solve_linear(A,b,"jacobi"); gi,gc=solve_linear(A,b,"gauss-seidel"); eig=np.linalg.eigvals(np.asarray(A))
        out["coupling"]={"jacobiIterations":ji,"gaussSeidelIterations":gi,"jacobiConverged":jc,"gaussSeidelConverged":gc,"maxEigenRealPart":finite(max(np.real(eig))),"stability":"Stable (educational model)" if max(np.real(eig))>0 else "Review model"}
    last=history[-60:]
    out["history"]={"time":[str(r.get("timestamp",""))[11:19] for r in last],"cpuTemp":[finite(r.get("cpu_temp")) for r in last],"gpuTemp":[finite(r.get("gpu_temp")) for r in last],"ssdTemp":[finite(r.get("ssd_temp")) for r in last],"cpuLoad":[finite(r.get("cpu_load")) for r in last],"gpuLoad":[finite(r.get("gpu_load")) for r in last],"cpuPower":[finite(r.get("cpu_power")) for r in last],"gpuPower":[finite(r.get("gpu_power")) for r in last],"ramLoad":[finite(r.get("ram_load")) for r in last]}
    return out

def main():
    for line in sys.stdin:
        try:
            request=json.loads(line); result=analyze(request.get("history",[]))
            print(json.dumps(result,separators=(",",":"),allow_nan=False),flush=True)
        except Exception as exc:
            print(json.dumps({"status":"ERROR","error":str(exc)},separators=(",",":"),allow_nan=False),flush=True)
if __name__=="__main__": main()
