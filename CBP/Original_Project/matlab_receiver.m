clear;
clc;

% ============================================================
% THERMAL INTELLIGENCE - MATLAB ANALYSIS ENGINE
% MATLAB R2026a compatible, base MATLAB functions only
% ============================================================

dataURL = "http://127.0.0.1:5000/data";
analysisURL = "http://127.0.0.1:5000/analysis";

% Bounded in-memory history only.
N = 120;                 % 2 minutes at 1 sample/sec
DISPLAY_N = 60;          % last 60 sec sent to frontend

history.time = NaT(N,1);
history.cpuTemp = nan(N,1);
history.cpuLoad = nan(N,1);
history.cpuPower = nan(N,1);
history.gpuTemp = nan(N,1);
history.gpuHotspot = nan(N,1);
history.gpuLoad = nan(N,1);
history.gpuPower = nan(N,1);
history.ssdTemp = nan(N,1);
history.ssdActivity = nan(N,1);
history.ramLoad = nan(N,1);

lastStatus = "NORMAL";

fprintf("==============================================================\n");
fprintf("                 THERMAL INTELLIGENCE\n");
fprintf("==============================================================\n");
fprintf("MATLAB numerical engine started...\n");

while true
    try
        data = webread(dataURL, weboptions("Timeout",2));
        nowTime = datetime("now");

        % --------------------------------------------------------
        % Current values
        % --------------------------------------------------------
        cpuTemp = safeValue(data.cpu_temp);
        cpuLoad = safeValue(data.cpu_load);
        cpuPower = safeValue(data.cpu_power);

        gpuTemp = safeValue(data.gpu_temp);
        gpuHotspot = safeValue(data.gpu_hotspot);
        gpuLoad = safeValue(data.gpu_load);
        gpuPower = safeValue(data.gpu_power);

        ssdTemp = safeValue(data.ssd_temp);
        ssdActivity = safeValue(data.ssd_activity);
        ramLoad = safeValue(data.ram_load);

        % --------------------------------------------------------
        % Shift bounded history
        % --------------------------------------------------------
        history.time = [history.time(2:end); nowTime];
        history.cpuTemp = [history.cpuTemp(2:end); cpuTemp];
        history.cpuLoad = [history.cpuLoad(2:end); cpuLoad];
        history.cpuPower = [history.cpuPower(2:end); cpuPower];
        history.gpuTemp = [history.gpuTemp(2:end); gpuTemp];
        history.gpuHotspot = [history.gpuHotspot(2:end); gpuHotspot];
        history.gpuLoad = [history.gpuLoad(2:end); gpuLoad];
        history.gpuPower = [history.gpuPower(2:end); gpuPower];
        history.ssdTemp = [history.ssdTemp(2:end); ssdTemp];
        history.ssdActivity = [history.ssdActivity(2:end); ssdActivity];
        history.ramLoad = [history.ramLoad(2:end); ramLoad];

        % --------------------------------------------------------
        % Numerical analysis
        % --------------------------------------------------------
        cpuRate = heatingRate(history.time, history.cpuTemp);
        gpuRate = heatingRate(history.time, history.gpuTemp);
        ssdRate = heatingRate(history.time, history.ssdTemp);

        cpuModel = thermalODEModel(history.time, history.cpuTemp, history.cpuLoad, history.cpuPower, cpuTemp, cpuLoad, cpuPower, 95);
        gpuModel = thermalODEModel(history.time, history.gpuTemp, history.gpuLoad, history.gpuPower, gpuTemp, gpuLoad, gpuPower, 95);
        ssdModel = thermalODEModel(history.time, history.ssdTemp, history.ssdActivity, zeros(size(history.ssdActivity)), ssdTemp, ssdActivity, 0, 80);

        % Cause analysis uses current telemetry plus recent temperature trends.
        % It reports likely contributors, not an unprovable single root cause.
        cause = analyzeCause(history, cpuRate, gpuRate, ssdRate, data);

        % More sensitive thermal status includes CPU/GPU hotspot/SSD thresholds,
        % sustained rises, and temperatures predicted to enter warning ranges.
        status = thermalStatus(cpuTemp, gpuTemp, ssdTemp, gpuHotspot, ...
            cpuRate, gpuRate, ssdRate, cpuModel, gpuModel, ssdModel);

        % High absolute temperatures and fast rises must not be labelled normal.
        anomaly = detectAnomaly(history, cpuRate, gpuRate, ssdRate, gpuHotspot, status, cpuModel, gpuModel, ssdModel);
        recommendation = makeRecommendation(status, cause, anomaly, cpuTemp, gpuTemp, ssdTemp);

        % Root-finding: Bisection + Newton-Raphson for first critical crossing.
        cpuRoot = thresholdTimes(cpuModel, 95);
        gpuRoot = thresholdTimes(gpuModel, 95);
        ssdRoot = thresholdTimes(ssdModel, 80);

        % SVD/PCA on recent feature matrix.
        pcaResult = performPCA(history);

        % Coupled 3-node educational thermal model for course syllabus.
        coupling = coupledThermalNumerics(cpuTemp, gpuTemp, ssdTemp, cpuPower, gpuPower, ssdActivity);

        % Curve fit.
        fitResult = curveFitAnalysis(history);

        % Hottest component.
        temps = [cpuTemp, gpuTemp, ssdTemp];
        names = ["CPU", "GPU", "SSD"];
        valid = ~isnan(temps);
        if any(valid)
            tv = temps(valid);
            nv = names(valid);
            [maxTemp, idx] = max(tv);
            hottest = nv(idx);
        else
            maxTemp = NaN;
            hottest = "Unknown";
        end

        % --------------------------------------------------------
        % Build analysis payload for web frontend
        % --------------------------------------------------------
        analysis.timestamp = char(nowTime);
        analysis.status = char(status);
        analysis.hottestComponent = char(hottest);
        analysis.maxTemperature = safeJSON(maxTemp);
        analysis.cause = char(cause.text);
        analysis.causeComponent = char(cause.component);
        analysis.recommendation = char(recommendation);
        analysis.anomaly = char(anomaly.message);
        analysis.anomalyDetected = anomaly.detected;
        analysis.cpuHeatingRate = safeJSON(cpuRate);
        analysis.gpuHeatingRate = safeJSON(gpuRate);
        analysis.ssdHeatingRate = safeJSON(ssdRate);
        analysis.topProcess = char(cause.topProcess);

        analysis.prediction.cpu5 = safeJSON(cpuModel.pred5);
        analysis.prediction.cpu10 = safeJSON(cpuModel.pred10);
        analysis.prediction.cpu30 = safeJSON(cpuModel.pred30);
        analysis.prediction.gpu5 = safeJSON(gpuModel.pred5);
        analysis.prediction.gpu10 = safeJSON(gpuModel.pred10);
        analysis.prediction.gpu30 = safeJSON(gpuModel.pred30);
        analysis.prediction.ssd5 = safeJSON(ssdModel.pred5);
        analysis.prediction.ssd10 = safeJSON(ssdModel.pred10);
        analysis.prediction.ssd30 = safeJSON(ssdModel.pred30);

        analysis.modelConfidence.cpu = safeJSON(cpuModel.confidence);
        analysis.modelConfidence.gpu = safeJSON(gpuModel.confidence);
        analysis.modelConfidence.ssd = safeJSON(ssdModel.confidence);

        analysis.timeToCritical.cpuBisection = safeJSON(cpuRoot.bisection);
        analysis.timeToCritical.cpuNewton = safeJSON(cpuRoot.newton);
        analysis.timeToCritical.gpuBisection = safeJSON(gpuRoot.bisection);
        analysis.timeToCritical.gpuNewton = safeJSON(gpuRoot.newton);
        analysis.timeToCritical.ssdBisection = safeJSON(ssdRoot.bisection);
        analysis.timeToCritical.ssdNewton = safeJSON(ssdRoot.newton);

        analysis.pca.explainedPC1 = safeJSON(pcaResult.explainedPC1);
        analysis.pca.dominantFactor = char(pcaResult.dominantFactor);
        analysis.pca.explainedPC2 = safeJSON(pcaResult.explainedPC2);

        analysis.coupling.jacobiIterations = coupling.jacobiIterations;
        analysis.coupling.gaussSeidelIterations = coupling.gaussSeidelIterations;
        analysis.coupling.jacobiConverged = coupling.jacobiConverged;
        analysis.coupling.gaussSeidelConverged = coupling.gaussSeidelConverged;
        analysis.coupling.maxEigenRealPart = safeJSON(coupling.maxEigenRealPart);
        analysis.coupling.stability = char(coupling.stability);

        analysis.curveFit.cpuRMSE = safeJSON(fitResult.cpuRMSE);
        analysis.curveFit.gpuRMSE = safeJSON(fitResult.gpuRMSE);
        analysis.curveFit.ssdRMSE = safeJSON(fitResult.ssdRMSE);

        % Last 60 seconds for live charts.
        idx = max(1,N-DISPLAY_N+1):N;
        analysis.history.time = cellstr(string(history.time(idx), "HH:mm:ss"));
        analysis.history.cpuTemp = finiteArray(history.cpuTemp(idx));
        analysis.history.gpuTemp = finiteArray(history.gpuTemp(idx));
        analysis.history.ssdTemp = finiteArray(history.ssdTemp(idx));
        analysis.history.cpuLoad = finiteArray(history.cpuLoad(idx));
        analysis.history.gpuLoad = finiteArray(history.gpuLoad(idx));
        analysis.history.cpuPower = finiteArray(history.cpuPower(idx));
        analysis.history.gpuPower = finiteArray(history.gpuPower(idx));
        analysis.history.ramLoad = finiteArray(history.ramLoad(idx));

        analysis.safety.manualActionOnly = true;
        analysis.safety.message = char(safetyMessage(status));

        % --------------------------------------------------------
        % Send analysis to Python -> web dashboard
        % --------------------------------------------------------
        payload = jsonencode(analysis);
        webwrite(analysisURL, payload, weboptions("MediaType","application/json","Timeout",2));

        % --------------------------------------------------------
        % MATLAB display (mirrors the web dashboard)
        % --------------------------------------------------------
        clc;
        fprintf("======================================================================\n");
        fprintf("                 THERMAL INTELLIGENCE - LIVE\n");
        fprintf("======================================================================\n\n");

        fprintf("%-20s %-15s %-15s %-15s\n", "PARAMETER", "CPU", "GPU", "SSD");
        fprintf("%-20s %-15s %-15s %-15s\n", "Temperature", fmt(cpuTemp,"C"), fmt(gpuTemp,"C"), fmt(ssdTemp,"C"));
        fprintf("%-20s %-15s %-15s %-15s\n", "Load / Activity", fmt(cpuLoad,"%"), fmt(gpuLoad,"%"), fmt(ssdActivity,"%"));
        fprintf("%-20s %-15s %-15s %-15s\n", "Power", fmt(cpuPower,"W"), fmt(gpuPower,"W"), "---");
        fprintf("%-20s %-15s %-15s %-15s\n", "Heating Rate", fmt(cpuRate,"C/s"), fmt(gpuRate,"C/s"), fmt(ssdRate,"C/s"));
        fprintf("%-20s %-15s %-15s %-15s\n", "5-min Prediction", fmt(cpuModel.pred5,"C"), fmt(gpuModel.pred5,"C"), fmt(ssdModel.pred5,"C"));
        fprintf("%-20s %-15s %-15s %-15s\n", "10-min Prediction", fmt(cpuModel.pred10,"C"), fmt(gpuModel.pred10,"C"), fmt(ssdModel.pred10,"C"));
        fprintf("%-20s %-15s %-15s %-15s\n", "30-min Prediction", fmt(cpuModel.pred30,"C"), fmt(gpuModel.pred30,"C"), fmt(ssdModel.pred30,"C"));

        fprintf("\n======================================================================\n");
        fprintf("SYSTEM\n");
        fprintf("  RAM Load             : %s\n", fmt(ramLoad,"%"));
        fprintf("  Hottest Component    : %s\n", char(hottest));
        fprintf("  Maximum Temperature  : %s\n", fmt(maxTemp,"C"));
        fprintf("  System Status        : %s\n", char(status));
        fprintf("  Anomaly              : %s\n", char(anomaly.message));

        fprintf("\n----------------------------------------------------------------------\n");
        fprintf("THERMAL ANALYSIS\n");
        fprintf("  Cause                : %s\n", char(cause.text));
        fprintf("  Recommendation       : %s\n", char(recommendation));
        fprintf("  Top process          : %s\n", char(cause.topProcess));

        fprintf("\n----------------------------------------------------------------------\n");
        fprintf("PREDICTION / MODEL CONFIDENCE\n");
        fprintf("  CPU / GPU / SSD      : %.0f%% / %.0f%% / %.0f%%\n", cpuModel.confidence, gpuModel.confidence, ssdModel.confidence);
        fprintf("  CPU critical time    : Bisection %s | Newton %s\n", rootFmt(cpuRoot.bisection), rootFmt(cpuRoot.newton));
        fprintf("  GPU critical time    : Bisection %s | Newton %s\n", rootFmt(gpuRoot.bisection), rootFmt(gpuRoot.newton));
        fprintf("  SSD critical time    : Bisection %s | Newton %s\n", rootFmt(ssdRoot.bisection), rootFmt(ssdRoot.newton));

        fprintf("\n----------------------------------------------------------------------\n");
        fprintf("ADVANCED NUMERICAL METHODS\n");
        fprintf("  PCA dominant factor  : %s\n", char(pcaResult.dominantFactor));
        fprintf("  PCA variance (PC1)   : %.1f%%\n", pcaResult.explainedPC1);
        fprintf("  Jacobi iterations    : %d\n", coupling.jacobiIterations);
        fprintf("  Gauss-Seidel iter.   : %d\n", coupling.gaussSeidelIterations);
        fprintf("  Thermal stability    : %s\n", char(coupling.stability));
        fprintf("  Curve-fit RMSE C/G/S : %.3f / %.3f / %.3f °C\n", fitResult.cpuRMSE, fitResult.gpuRMSE, fitResult.ssdRMSE);

        fprintf("\n----------------------------------------------------------------------\n");
        fprintf("SAFETY\n");
        fprintf("  %s\n", char(safetyMessage(status)));
        fprintf("----------------------------------------------------------------------\n");

        lastStatus = status;
        pause(1);

    catch ME
        clc;
        fprintf("THERMAL INTELLIGENCE - MATLAB\n");
        fprintf("Waiting for live Python data...\n");
        fprintf("%s\n", ME.message);
        pause(1);
    end
end

% ============================================================
% Helper functions
% ============================================================

function v = safeValue(x)
    if isempty(x)
        v = NaN;
    elseif isnumeric(x)
        v = double(x);
    else
        v = str2double(string(x));
    end
    if ~isfinite(v)
        v = NaN;
    end
end

function v = safeJSON(x)
    if isempty(x) || ~isnumeric(x) || ~isfinite(x)
        v = NaN;
    else
        v = double(x);
    end
end

function a = finiteArray(x)
    a = x;
    a(~isfinite(a)) = NaN;
    % Keep JSON valid and browser-friendly: NaN becomes null in JSON encoding.
end

function out = fmt(v, unit)
    if isempty(v) || ~isfinite(v)
        out = "---";
        return;
    end
    if unit == "C"
        out = sprintf("%.1f C", v);
    elseif unit == "C/s"
        out = sprintf("%.3f C/s", v);
    elseif unit == "%"
        out = sprintf("%.1f %%", v);
    elseif unit == "W"
        out = sprintf("%.1f W", v);
    else
        out = sprintf("%.2f %s", v, unit);
    end
end

function r = heatingRate(timeData, tempData)
    valid = ~isnat(timeData) & isfinite(tempData);
    if nnz(valid) < 3
        r = 0;
        return;
    end
    t = seconds(timeData(valid) - timeData(find(valid,1)));
    y = tempData(valid);
    % Final local slope from a short trailing window is less noisy than raw one-step difference.
    m = min(10, numel(y));
    p = polyfit(t(end-m+1:end), y(end-m+1:end), 1);
    r = p(1);
end

function model = thermalODEModel(timeData, tempData, loadData, powerData, currentTemp, currentLoad, currentPower, threshold)
    model = defaultModel();
    valid = ~isnat(timeData) & isfinite(tempData) & isfinite(loadData) & isfinite(powerData);
    if nnz(valid) < 20 || ~isfinite(currentTemp) || ~isfinite(currentLoad) || ~isfinite(currentPower)
        model.pred5 = currentTemp;
        model.pred10 = currentTemp;
        model.pred30 = currentTemp;
        model.confidence = 0;
        return;
    end

    t = seconds(timeData(valid) - timeData(find(valid,1)));
    T = tempData(valid);
    L = loadData(valid);
    P = powerData(valid);

    dT = gradient(T, t);
    X = [ones(size(T)), L, P, T];
    keep = isfinite(dT) & all(isfinite(X),2);
    X = X(keep,:);
    dT = dT(keep);
    if size(X,1) < 15
        model.pred5 = currentTemp;
        model.pred10 = currentTemp;
        model.pred30 = currentTemp;
        return;
    end

    % Remove predictors that do not vary in this window. For example, the
    % SSD currently has no measured power input, so its power column is all
    % zeros and cannot be estimated from the available data.
    activeColumns = true(1, size(X,2));
    for column = 2:size(X,2)  % Keep the intercept; test load/power/temperature.
        columnScale = max(1, max(abs(X(:,column))));
        columnRange = max(X(:,column)) - min(X(:,column));
        if columnRange <= 1e-8 * columnScale
            activeColumns(column) = false;
        end
    end

    Xfit = X(:, activeColumns);
    fitRank = rank(Xfit);
    rankLimited = fitRank < size(Xfit,2);

    % Use an ordinary least-squares solve when identifiable; otherwise use a
    % pseudoinverse to avoid the rank-deficient backslash warning.
    if rankLimited
        betaFit = pinv(Xfit) * dT;
    else
        betaFit = Xfit \ dT;
    end

    beta = zeros(size(X,2),1);
    beta(activeColumns) = betaFit;

    yhat = Xfit * betaFit;
    ssRes = sum((dT-yhat).^2);
    ssTot = sum((dT-mean(dT)).^2);
    if ssTot > eps
        r2 = 1 - ssRes/ssTot;
    else
        r2 = 0;
    end

    model.b0 = beta(1);
    model.bLoad = beta(2);
    model.bPower = beta(3);
    model.bTemp = beta(4);
    model.r2 = r2;
    model.confidence = max(0,min(100,100*max(0,r2)));

    % Do not overstate confidence if predictors could not be estimated.
    if rankLimited || any(~activeColumns(2:end))
        model.confidence = min(model.confidence, 30);
    end

    if model.bTemp >= -1e-5
        % Unstable local fit: use recent curve extrapolation cautiously.
        m = min(20, numel(T));
        q = polyfit(t(end-m+1:end),T(end-m+1:end),1);
        model.pred5 = q(1)* (t(end)+300) + q(2);
        model.pred10 = q(1)* (t(end)+600) + q(2);
        model.pred30 = q(1)* (t(end)+1800) + q(2);
        model.confidence = min(model.confidence,30);
        return;
    end

    forcing = model.b0 + model.bLoad*currentLoad + model.bPower*currentPower;
    Teq = -forcing/model.bTemp;
    f = @(tt,TT) forcing + model.bTemp.*TT;

    try
        sol = ode45(f,[0 1800],currentTemp);
        pred = deval(sol,[300 600 1800]);
        model.pred5 = pred(1);
        model.pred10 = pred(2);
        model.pred30 = pred(3);
        model.odeStable = true;
        model.Teq = Teq;
    catch
        model.pred5 = Teq + (currentTemp-Teq)*exp(model.bTemp*300);
        model.pred10 = Teq + (currentTemp-Teq)*exp(model.bTemp*600);
        model.pred30 = Teq + (currentTemp-Teq)*exp(model.bTemp*1800);
    end

    model.threshold = threshold;
end

function m = defaultModel()
    m.pred5 = NaN; m.pred10 = NaN; m.pred30 = NaN;
    m.confidence = 0; m.b0 = 0; m.bLoad = 0; m.bPower = 0; m.bTemp = -0.01; m.r2 = 0; m.odeStable = false; m.Teq = NaN;
end

function root = thresholdTimes(model, threshold)
    root.bisection = NaN;
    root.newton = NaN;
    if ~isfinite(model.pred30) || ~isfinite(model.bTemp)
        return;
    end
    if ~isfinite(model.bTemp) || model.bTemp >= 0 || ~isfinite(model.Teq)
        return;
    end
    T0 = NaN;
    % Recover T0 from the 5-min point using the constant-coefficient ODE.
    T5 = model.pred5;
    T0 = model.Teq + (T5-model.Teq)*exp(-model.bTemp*300);
    f = @(t) model.Teq + (T0-model.Teq)*exp(model.bTemp*t) - threshold;
    if f(0) >= 0
        root.bisection = 0;
        root.newton = 0;
        return;
    end
    hi = 1800;
    if f(hi) < 0
        return;
    end

    lo = 0;
    for k = 1:60
        mid = (lo+hi)/2;
        if f(mid) >= 0
            hi = mid;
        else
            lo = mid;
        end
    end
    root.bisection = (lo+hi)/2;

    % Safeguarded Newton-Raphson inside the same bracket.
    x = min(max(root.bisection*0.8,lo),hi);
    for k = 1:30
        fx = f(x);
        dfx = model.bTemp*(model.Teq + (T0-model.Teq)*exp(model.bTemp*x) - model.Teq);
        if abs(dfx) < 1e-10
            break;
        end
        xn = x - fx/dfx;
        if xn <= lo || xn >= hi || ~isfinite(xn)
            xn = (lo+hi)/2;
        end
        if f(xn) >= 0
            hi = xn;
        else
            lo = xn;
        end
        x = xn;
        if abs(fx) < 1e-4
            break;
        end
    end
    root.newton = x;
end

function [textOut] = safetyMessage(status)
    switch char(status)
        case "NORMAL"
            textOut = "System within monitored prototype limits.";
        case "WATCH"
            textOut = "Monitor closely; no automatic intervention is performed.";
        case "WARNING"
            textOut = "Reduce thermal workload and inspect cooling/airflow.";
        case "CRITICAL"
            textOut = "Critical thermal condition. Stop heavy workloads and consider controlled shutdown.";
        otherwise
            textOut = "Emergency thermal condition. Manual immediate action required.";
    end
end

function status = thermalStatus(cpuTemp,gpuTemp,ssdTemp,gpuHotspot,cpuRate,gpuRate,ssdRate,cpuModel,gpuModel,ssdModel)
    % Prototype thresholds are intentionally conservative/early-warning values.
    % Verify them against the laptop and SSD manufacturers' specifications.
    status = "NORMAL";

    % Immediate high-temperature thresholds.
    if (isfinite(cpuTemp) && cpuTemp >= 95) || ...
       (isfinite(gpuTemp) && gpuTemp >= 88) || ...
       (isfinite(gpuHotspot) && gpuHotspot >= 105) || ...
       (isfinite(ssdTemp) && ssdTemp >= 75)
        status = "CRITICAL";
        return;
    end

    if (isfinite(cpuTemp) && cpuTemp >= 85) || ...
       (isfinite(gpuTemp) && gpuTemp >= 80) || ...
       (isfinite(gpuHotspot) && gpuHotspot >= 100) || ...
       (isfinite(ssdTemp) && ssdTemp >= 65)
        status = "WARNING";
        return;
    end

    if (isfinite(cpuTemp) && cpuTemp >= 75) || ...
       (isfinite(gpuTemp) && gpuTemp >= 70) || ...
       (isfinite(gpuHotspot) && gpuHotspot >= 90) || ...
       (isfinite(ssdTemp) && ssdTemp >= 55)
        status = "WATCH";
    end

    % Fast heating is itself a warning, even before the absolute limit is reached.
    rates = [cpuRate,gpuRate,ssdRate];
    if any(isfinite(rates) & rates >= 0.04)
        status = "WARNING";
        return;
    elseif any(isfinite(rates) & rates >= 0.015) && status == "NORMAL"
        status = "WATCH";
    end

    % Prediction can raise WATCH to WARNING, but predictions alone never set CRITICAL.
    pred = [cpuModel.pred10,gpuModel.pred10,ssdModel.pred10];
    pred = pred(isfinite(pred));
    if ~isempty(pred)
        if (isfinite(cpuModel.pred10) && cpuModel.pred10 >= 85) || ...
           (isfinite(gpuModel.pred10) && gpuModel.pred10 >= 80) || ...
           (isfinite(ssdModel.pred10) && ssdModel.pred10 >= 65)
            if status == "NORMAL"
                status = "WATCH";
            end
        end
        if (isfinite(cpuModel.pred10) && cpuModel.pred10 >= 95) || ...
           (isfinite(gpuModel.pred10) && gpuModel.pred10 >= 88) || ...
           (isfinite(ssdModel.pred10) && ssdModel.pred10 >= 75)
            if status == "NORMAL" || status == "WATCH"
                status = "WARNING";
            end
        end
    end
end

function rec = makeRecommendation(status,cause,anomaly,cpuTemp,gpuTemp,ssdTemp)
    if status == "CRITICAL"
        rec = "CRITICAL: stop heavy workloads now, place the laptop on a hard unobstructed surface, and allow it to cool. If temperature remains critical, shut down normally.";
    elseif status == "WARNING"
        rec = "WARNING: reduce CPU/GPU workload now, close unnecessary high-load apps, keep vents unobstructed, and check that the fans are operating.";
    elseif status == "WATCH"
        rec = "WATCH: temperature is elevated or rising. Avoid starting another heavy workload and monitor the next readings.";
    elseif anomaly.detected
        rec = "Unusual thermal trend detected. Reduce workload and inspect airflow; continue monitoring until temperatures stabilize.";
    elseif cause.component == "CPU"
        rec = "CPU appears to be contributing heat. Reduce CPU-intensive work or select a lower performance/power mode.";
    elseif cause.component == "GPU" || cause.component == "GPU / CHASSIS"
        rec = "GPU workload may be adding heat. Reduce graphics/compute load and ensure the laptop vents are clear.";
    elseif cause.component == "SSD"
        rec = "SSD activity may be contributing heat. Pause unnecessary disk-heavy tasks and check SSD cooling/ventilation.";
    elseif max([cpuTemp,gpuTemp,ssdTemp],[],'omitnan') > 65
        rec = "Keep monitoring temperature trends and avoid prolonged heavy workloads until temperatures settle.";
    else
        rec = "No current thermal action is required; continue live monitoring.";
    end
end

function cause = analyzeCause(history,cpuRate,gpuRate,ssdRate,data)
    cause.text = "No significant thermal rise detected in the available telemetry.";
    cause.component = "NONE";
    cause.topProcess = "None";

    cpuTemp = lastFinite(history.cpuTemp);
    gpuTemp = lastFinite(history.gpuTemp);
    ssdTemp = lastFinite(history.ssdTemp);
    cpuLoad = lastFinite(history.cpuLoad);
    cpuPower = lastFinite(history.cpuPower);
    gpuLoad = lastFinite(history.gpuLoad);
    gpuPower = lastFinite(history.gpuPower);
    ssdActivity = lastFinite(history.ssdActivity);
    gpuHotspot = safeValueField(data,"gpu_hotspot");

    % Focus first on a component whose measured temperature is elevated.
    % Use workload/power/activity as supporting evidence, never as proof of cause.
    cpuHot = isfinite(cpuTemp) && cpuTemp >= 75;
    gpuHot = (isfinite(gpuTemp) && gpuTemp >= 70) || ...
             (isfinite(gpuHotspot) && gpuHotspot >= 90);
    ssdHot = isfinite(ssdTemp) && ssdTemp >= 55;
    cpuRising = isfinite(cpuRate) && cpuRate >= 0.015;
    gpuRising = isfinite(gpuRate) && gpuRate >= 0.015;
    ssdRising = isfinite(ssdRate) && ssdRate >= 0.015;

    % If a high GPU workload coincides with a hot CPU, report potential shared-chassis heat.
    if cpuHot && ((isfinite(gpuLoad) && gpuLoad >= 70) || ...
                  (isfinite(gpuPower) && gpuPower >= 35))
        cause.component = "GPU / CHASSIS";
        cause.text = "CPU is " + fmtTempText(cpuTemp) + ", while GPU activity is " + ...
            fmtPercentText(gpuLoad) + " and GPU power is " + fmtPowerText(gpuPower) + ...
            ". Heavy GPU work may add heat inside the shared laptop cooling system; this is a likely contributor, not proof of a single cause.";
    elseif cpuHot || cpuRising
        cause.component = "CPU";
        if (isfinite(cpuLoad) && cpuLoad >= 60) || (isfinite(cpuPower) && cpuPower >= 25)
            cause.text = "CPU temperature is " + fmtTempText(cpuTemp) + " with CPU load " + ...
                fmtPercentText(cpuLoad) + " and package power " + fmtPowerText(cpuPower) + ...
                ". Sustained CPU workload/power is a likely heat contributor.";
        elseif isfinite(cpuLoad) && cpuLoad < 30 && isfinite(cpuPower) && cpuPower < 20 && cpuHot
            cause.text = "CPU is hot at " + fmtTempText(cpuTemp) + " despite relatively low reported load/power. Check fan operation, blocked vents, dust, surface clearance, and room temperature; the sensors cannot distinguish these causes.";
        else
            cause.text = "CPU temperature is " + fmtTempText(cpuTemp) + ...
                " and its recent heating rate is " + fmtRateText(cpuRate) + ...
                ". CPU may be contributing; compare load/power and inspect airflow if temperature stays high.";
        end
    elseif gpuHot || gpuRising
        cause.component = "GPU";
        if (isfinite(gpuLoad) && gpuLoad >= 60) || (isfinite(gpuPower) && gpuPower >= 30)
            cause.text = "GPU temperature is " + fmtTempText(gpuTemp) + ...
                " (hotspot " + fmtTempText(gpuHotspot) + "), with GPU load " + ...
                fmtPercentText(gpuLoad) + " and power " + fmtPowerText(gpuPower) + ...
                ". Sustained GPU work is a likely heat contributor.";
        else
            cause.text = "GPU temperature/hotspot is elevated or rising without a strong current GPU-load signal. Check airflow, fan operation, and recent heat soak; exact cause is not identifiable from these sensors alone.";
        end
    elseif ssdHot || ssdRising
        cause.component = "SSD";
        if isfinite(ssdActivity) && ssdActivity >= 50
            cause.text = "SSD temperature is " + fmtTempText(ssdTemp) + " with disk activity " + ...
                fmtPercentText(ssdActivity) + ". Sustained disk activity may be contributing to SSD heating.";
        else
            cause.text = "SSD temperature is " + fmtTempText(ssdTemp) + ...
                " despite modest reported disk activity. Check airflow around the drive and monitor its trend; exact cause is uncertain.";
        end
    elseif (isfinite(cpuTemp) && cpuTemp >= 65) || (isfinite(gpuTemp) && gpuTemp >= 60) || ...
           (isfinite(ssdTemp) && ssdTemp >= 50)
        cause.component = "THERMAL";
        cause.text = "Temperatures are elevated but current load/activity does not identify one dominant source. Heat soak, cooling performance, workload changes, and ambient temperature may contribute.";
    end

    if cause.component == "CPU" && isfield(data,"top_processes")
        try
            p = data.top_processes;
            if ~isempty(p) && isstruct(p)
                cause.topProcess = string(p(1).name) + " (" + fmt(safeValue(p(1).cpu),"%") + " CPU)";
            else
                cause.topProcess = "No CPU-heavy process identified";
            end
        catch
            cause.topProcess = "Top process unavailable";
        end
    end
end

function v = lastFinite(values)
    values = values(isfinite(values));
    if isempty(values)
        v = NaN;
    else
        v = values(end);
    end
end

function v = safeValueField(data, fieldName)
    if isstruct(data) && isfield(data,fieldName)
        v = safeValue(data.(fieldName));
    else
        v = NaN;
    end
end

function s = fmtTempText(v)
    if isfinite(v), s = string(sprintf("%.1f °C",v)); else, s = "unavailable"; end
end

function s = fmtPercentText(v)
    if isfinite(v), s = string(sprintf("%.0f%%",v)); else, s = "unavailable"; end
end

function s = fmtPowerText(v)
    if isfinite(v), s = string(sprintf("%.1f W",v)); else, s = "unavailable"; end
end

function s = fmtRateText(v)
    if isfinite(v), s = string(sprintf("%.3f °C/s",v)); else, s = "unavailable"; end
end

function anomaly = detectAnomaly(history,cpuRate,gpuRate,ssdRate,gpuHotspot,status,cpuModel,gpuModel,ssdModel)
    anomaly.detected = false;
    anomaly.message = "Normal thermal behavior";

    cpuTemp = lastFinite(history.cpuTemp);
    gpuTemp = lastFinite(history.gpuTemp);
    ssdTemp = lastFinite(history.ssdTemp);
    flags = strings(0,1);
    hasCritical = false;
    hasWarning = false;
    hasWatch = false;

    % Absolute temperature checks ensure a hot-but-stable component is never called normal.
    if isfinite(cpuTemp) && cpuTemp >= 95
        flags(end+1) = "CPU critical at " + fmtTempText(cpuTemp); hasCritical = true;
    elseif isfinite(cpuTemp) && cpuTemp >= 85
        flags(end+1) = "CPU high at " + fmtTempText(cpuTemp); hasWarning = true;
    elseif isfinite(cpuTemp) && cpuTemp >= 75
        flags(end+1) = "CPU elevated at " + fmtTempText(cpuTemp); hasWatch = true;
    end

    if isfinite(gpuHotspot) && gpuHotspot >= 105
        flags(end+1) = "GPU hotspot critical at " + fmtTempText(gpuHotspot); hasCritical = true;
    elseif isfinite(gpuHotspot) && gpuHotspot >= 100
        flags(end+1) = "GPU hotspot high at " + fmtTempText(gpuHotspot); hasWarning = true;
    elseif isfinite(gpuHotspot) && gpuHotspot >= 90
        flags(end+1) = "GPU hotspot elevated at " + fmtTempText(gpuHotspot); hasWatch = true;
    end

    if isfinite(gpuTemp) && gpuTemp >= 88
        flags(end+1) = "GPU critical at " + fmtTempText(gpuTemp); hasCritical = true;
    elseif isfinite(gpuTemp) && gpuTemp >= 80
        flags(end+1) = "GPU high at " + fmtTempText(gpuTemp); hasWarning = true;
    elseif isfinite(gpuTemp) && gpuTemp >= 70
        flags(end+1) = "GPU elevated at " + fmtTempText(gpuTemp); hasWatch = true;
    end

    if isfinite(ssdTemp) && ssdTemp >= 75
        flags(end+1) = "SSD critical at " + fmtTempText(ssdTemp); hasCritical = true;
    elseif isfinite(ssdTemp) && ssdTemp >= 65
        flags(end+1) = "SSD high at " + fmtTempText(ssdTemp); hasWarning = true;
    elseif isfinite(ssdTemp) && ssdTemp >= 55
        flags(end+1) = "SSD elevated at " + fmtTempText(ssdTemp); hasWatch = true;
    end

    rates = [cpuRate,gpuRate,ssdRate];
    names = ["CPU","GPU","SSD"];
    histFields = {history.cpuTemp,history.gpuTemp,history.ssdTemp};
    for i = 1:3
        values = histFields{i};
        values = values(isfinite(values));
        rise10 = NaN;
        if numel(values) >= 11
            rise10 = values(end) - values(end-10);
        end
        if (isfinite(rise10) && rise10 >= 2.0) || (isfinite(rates(i)) && rates(i) >= 0.04)
            if isfinite(rise10)
                riseText = string(sprintf("%+.1f °C over ~10 s",rise10));
            else
                riseText = string(sprintf("%.3f °C/s",rates(i)));
            end
            flags(end+1) = names(i) + " temperature rising rapidly (" + riseText + ")";
            hasWarning = true;
        elseif (isfinite(rise10) && rise10 >= 0.8) || (isfinite(rates(i)) && rates(i) >= 0.015)
            flags(end+1) = names(i) + " temperature is rising; monitor closely";
            hasWatch = true;
        end
    end

    % Keep the anomaly panel consistent with the system status when predictive
    % modelling triggered WATCH/WARNING even though current readings are not high.
    if isempty(flags) && status ~= "NORMAL"
        if isfinite(cpuModel.pred10) && cpuModel.pred10 >= 85
            flags(end+1) = "CPU is predicted to reach " + fmtTempText(cpuModel.pred10) + " within 10 min";
        end
        if isfinite(gpuModel.pred10) && gpuModel.pred10 >= 80
            flags(end+1) = "GPU is predicted to reach " + fmtTempText(gpuModel.pred10) + " within 10 min";
        end
        if isfinite(ssdModel.pred10) && ssdModel.pred10 >= 65
            flags(end+1) = "SSD is predicted to reach " + fmtTempText(ssdModel.pred10) + " within 10 min";
        end
        if isempty(flags)
            flags(end+1) = "Heating trend requires attention; system status is " + status;
        end
        if status == "CRITICAL"
            hasCritical = true;
        elseif status == "WARNING"
            hasWarning = true;
        else
            hasWatch = true;
        end
    end

    if ~isempty(flags)
        anomaly.detected = true;
        if hasCritical
            prefix = "CRITICAL — ";
        elseif hasWarning
            prefix = "WARNING — ";
        else
            prefix = "WATCH — ";
        end
        anomaly.message = string(prefix) + string(strjoin(cellstr(flags),"; "));
    end
end

function result = performPCA(history)
    result.explainedPC1 = 0;
    result.explainedPC2 = 0;
    result.dominantFactor = "Insufficient data";

    M = [history.cpuTemp, history.gpuTemp, history.ssdTemp, ...
         history.cpuLoad, history.gpuLoad, history.cpuPower, history.gpuPower, history.ramLoad];
    validRows = all(isfinite(M),2);
    M = M(validRows,:);
    if size(M,1) < 20
        return;
    end

    M = M - mean(M,1);
    s = std(M,0,1); s(s < eps) = 1;
    M = M ./ s;

    [U,S,V] = svd(M,"econ"); %#ok<ASGLU>
    latent = diag(S).^2;
    explained = 100 * latent / sum(latent);
    result.explainedPC1 = explained(1);
    if numel(explained) >= 2
        result.explainedPC2 = explained(2);
    end

    names = ["CPU temperature","GPU temperature","SSD temperature","CPU load","GPU load","CPU power","GPU power","RAM load"];
    [~,idx] = max(abs(V(:,1)));
    result.dominantFactor = names(idx);
end

function result = coupledThermalNumerics(cpuTemp,gpuTemp,ssdTemp,cpuPower,gpuPower,ssdActivity)
    % Educational 3-node steady-state thermal network used to exercise
    % Jacobi, Gauss-Seidel and eigenvalue analysis. It is not a physical
    % replacement for manufacturer thermal specifications.
    result.jacobiIterations = 0;
    result.gaussSeidelIterations = 0;
    result.jacobiConverged = false;
    result.gaussSeidelConverged = false;
    result.maxEigenRealPart = NaN;
    result.stability = "Insufficient data";

    if any(~isfinite([cpuTemp,gpuTemp,ssdTemp,cpuPower,gpuPower,ssdActivity]))
        return;
    end

    Tamb = 25;
    g12 = 0.08; g13 = 0.03; g23 = 0.04;
    h1 = 0.20; h2 = 0.18; h3 = 0.12;
    A = [h1+g12+g13, -g12, -g13; ...
         -g12, h2+g12+g23, -g23; ...
         -g13, -g23, h3+g13+g23];
    Q = [cpuPower+h1*Tamb; gpuPower+h2*Tamb; 0.15*ssdActivity+h3*Tamb];

    T0 = [cpuTemp;gpuTemp;ssdTemp];
    [~, jacobiIt, jacobiOk] = iterativeLinearSolve(A,Q,T0,"jacobi",1e-4,500);
    [~, gsIt, gsOk] = iterativeLinearSolve(A,Q,T0,"gs",1e-4,500);
    result.jacobiIterations = jacobiIt;
    result.gaussSeidelIterations = gsIt;
    result.jacobiConverged = jacobiOk;
    result.gaussSeidelConverged = gsOk;

    ev = eig(A);
    result.maxEigenRealPart = max(real(ev));
    if all(real(ev) > 0)
        result.stability = "Stable thermal-balance matrix";
    else
        result.stability = "Review thermal-balance model";
    end
end

function [x,it,ok] = iterativeLinearSolve(A,b,x0,method,tol,maxIt)
    D = diag(diag(A));
    R = A-D;
    x = x0;
    ok=false;
    for it=1:maxIt
        old=x;
        if method=="jacobi"
            x = D \ (b - R*old);
        else
            % Gauss-Seidel: solve row by row with latest values.
            x = old;
            for i=1:size(A,1)
                sigma = A(i,1:i-1)*x(1:i-1) + A(i,i+1:end)*old(i+1:end);
                x(i) = (b(i)-sigma)/A(i,i);
            end
        end
        if norm(x-old,inf) < tol
            ok=true;
            break;
        end
    end
end

function result = curveFitAnalysis(history)
    result.cpuRMSE = NaN;
    result.gpuRMSE = NaN;
    result.ssdRMSE = NaN;
    result.cpuSlope = 0;
    result.gpuSlope = 0;
    result.ssdSlope = 0;

    temps = {history.cpuTemp,history.gpuTemp,history.ssdTemp};
    fields = {"cpuRMSE","gpuRMSE","ssdRMSE"};
    slopeFields = {"cpuSlope","gpuSlope","ssdSlope"};
    for i=1:3
        y = temps{i};
        valid = isfinite(y);
        if nnz(valid) >= 10
            y = y(valid);
            x = (1:numel(y))';
            p = polyfit(x,y,2);
            yhat = polyval(p,x);
            result.(fields{i}) = sqrt(mean((y-yhat).^2));
            result.(slopeFields{i}) = 2*p(1)*x(end)+p(2);
        end
    end
end

function out = rootFmt(v)
    if isempty(v) || ~isfinite(v)
        out = "not predicted";
    else
        out = sprintf("%.1f min",v/60);
    end
end
