using Microsoft.Web.WebView2.WinForms;

namespace ThermoTrack.App;

internal sealed class MainForm : Form
{
    private readonly WebView2 _web = new() { Dock = DockStyle.Fill };
    private readonly System.Windows.Forms.Timer _timer = new() { Interval = 1000 };
    private readonly List<Dictionary<string, object?>> _history = new();
    private readonly object _dataLock = new();
    private SensorService? _sensors;
    private AnalysisClient? _analysis;
    private LocalApiServer? _api;
    private Dictionary<string, object?> _latestSensor = new();
    private Dictionary<string, object?> _latestAnalysis = new();
    private bool _sampling;
    private bool _closing;
    private string _lastAlert = "NORMAL";
    private string? _analysisInitializationError;
    private readonly string _base = AppContext.BaseDirectory;

    public MainForm()
    {
        Text = "ThermoTrack — Real-time Thermal Monitoring";
        Width = 1480; Height = 960; MinimumSize = new Size(1024, 700); StartPosition = FormStartPosition.CenterScreen;
        Controls.Add(_web); Shown += StartApp; FormClosing += StopApp;
        _timer.Tick += async (_, _) => await SampleOnceAsync();
    }

    private async void StartApp(object? sender, EventArgs e)
    {
        try
        {
            AppDiagnostics.Write("Startup", "Starting ThermoTrack as the current Windows user.");
            var dashboard = Path.Combine(_base, "dashboard", "index.html");
            var worker = Path.Combine(_base, "analysis", "analysis_worker.exe");
            if (!File.Exists(dashboard))
                throw new FileNotFoundException("The embedded dashboard is missing from the installation.", dashboard);

            _sensors = new SensorService();
            try
            {
                _analysis = new AnalysisClient(worker);
            }
            catch (Exception ex)
            {
                _analysisInitializationError = ex.Message;
                AppDiagnostics.Write("Analysis", "The analysis worker could not be started. The app will continue with live sensor data and unavailable analysis fields.", ex);
            }

            _api = new LocalApiServer(dashboard, Snapshot);
            _api.Start();

            // Keep WebView2 profile/cache under the current user's writable data
            // directory. If an old profile is damaged, retry with a separate
            // profile under the user's temp directory instead of Program Files.
            var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            var primaryProfile = Path.Combine(localAppData, "ThermoTrack", "WebView2");
            Microsoft.Web.WebView2.Core.CoreWebView2Environment environment;
            try
            {
                Directory.CreateDirectory(primaryProfile);
                environment = await Microsoft.Web.WebView2.Core.CoreWebView2Environment.CreateAsync(userDataFolder: primaryProfile);
            }
            catch (Exception firstWebViewError)
            {
                AppDiagnostics.Write("WebView2", $"Could not initialize the primary user profile at '{primaryProfile}'. Retrying with a temporary profile.", firstWebViewError);
                try
                {
                    var tempProfile = Path.Combine(Path.GetTempPath(), "ThermoTrack", "WebView2");
                    Directory.CreateDirectory(tempProfile);
                    environment = await Microsoft.Web.WebView2.Core.CoreWebView2Environment.CreateAsync(userDataFolder: tempProfile);
                }
                catch (Exception fallbackError)
                {
                    AppDiagnostics.Write("WebView2", "Both writable WebView2 profiles failed to initialize.", fallbackError);
                    throw new InvalidOperationException(
                        "ThermoTrack's dashboard engine (Microsoft Edge WebView2) could not start. " +
                        "This is separate from hardware-sensor initialization. Verify the WebView2 Runtime installation. " +
                        $"Primary profile: {primaryProfile}. Diagnostic log: {Path.Combine(localAppData, "ThermoTrack", "Logs", "thermotrack.log")}",
                        new AggregateException(firstWebViewError, fallbackError));
                }
            }

            await _web.EnsureCoreWebView2Async(environment);
            _web.CoreWebView2.Settings.AreDevToolsEnabled = false;
            _web.CoreWebView2.Settings.AreDefaultContextMenusEnabled = false;
            _web.CoreWebView2.Settings.IsStatusBarEnabled = false;
            _web.Source = new Uri(_api.BaseUrl);
            await SampleOnceAsync();
            _timer.Start();
        }
        catch (Exception ex)
        {
            AppDiagnostics.Write("Startup", "The desktop shell could not initialize.", ex);
            var logPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ThermoTrack", "Logs", "thermotrack.log");
            MessageBox.Show(this,
                "ThermoTrack could not start its desktop dashboard. This does not necessarily mean that hardware sensors failed.\n\n" +
                ex.Message + "\n\nDiagnostic log: " + logPath,
                "ThermoTrack startup error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            Close();
        }
    }

    private async Task SampleOnceAsync()
    {
        if (_sampling || _closing || _sensors is null) return;
        _sampling = true;
        try
        {
            var record = await Task.Run(() => _sensors.Sample());
            Dictionary<string, object?>[] historySnapshot;
            lock (_dataLock)
            {
                _history.Add(record);
                if (_history.Count > 300) _history.RemoveAt(0);
                historySnapshot = _history.ToArray();
            }

            Dictionary<string, object?> analysis;
            var analysisClient = _analysis;
            if (analysisClient is not null)
            {
                try
                {
                    // Keep numerical fitting off the UI thread so the dashboard remains responsive.
                    analysis = await Task.Run(() => analysisClient.Analyze(historySnapshot));
                }
                catch (Exception ex)
                {
                    AppDiagnostics.Write("Analysis", "The numerical-analysis worker failed. Raw hardware readings will remain available; analysis will be marked unavailable.", ex);
                    _analysisInitializationError = ex.Message;
                    try { analysisClient.Dispose(); } catch { }
                    _analysis = null;
                    analysis = AnalysisUnavailable("The analysis worker failed: " + ex.Message);
                }
            }
            else
            {
                analysis = AnalysisUnavailable(_analysisInitializationError ?? "The analysis worker is unavailable.");
            }

            lock (_dataLock)
            {
                _latestSensor = record;
                _latestAnalysis = analysis;
            }

            var status = analysis.TryGetValue("status", out var statusValue) ? statusValue?.ToString() : "NORMAL";
            int Level(string? value) => value switch { "WATCH" => 1, "WARNING" => 2, "CRITICAL" => 3, "EMERGENCY" => 4, _ => 0 };
            if (Level(status) >= 2 && Level(status) > Level(_lastAlert)) System.Media.SystemSounds.Exclamation.Play();
            _lastAlert = status ?? "NORMAL";
        }
        catch (Exception ex)
        {
            AppDiagnostics.Write("Sampling", "Unexpected sampling failure.", ex);
            lock (_dataLock)
            {
                _latestSensor = new Dictionary<string, object?>
                {
                    ["timestamp"] = DateTime.Now.ToString("O"), ["cpu_temp"] = null, ["gpu_temp"] = null,
                    ["ssd_temp"] = null, ["sensor_error"] = ex.Message,
                    ["sensor_note"] = "Sampling failed. Current values are unavailable; no values are fabricated."
                };
                _latestAnalysis = AnalysisUnavailable("Sensor sampling failed. Check the diagnostic log for details.");
            }
        }
        finally { _sampling = false; }
    }

    private static Dictionary<string, object?> AnalysisUnavailable(string message) => new()
    {
        ["status"] = "SENSOR_UNAVAILABLE", ["hottestComponent"] = "Unknown", ["maxTemperature"] = null,
        ["anomaly"] = "ANALYSIS UNAVAILABLE", ["anomalyDetected"] = false,
        ["cause"] = message, ["causeComponent"] = "Unknown",
        ["recommendation"] = "Live readings are not replaced with estimates. Check diagnostics and sensor support.",
        ["prediction"] = new { cpu5 = (double?)null, cpu10 = (double?)null, cpu30 = (double?)null,
            gpu5 = (double?)null, gpu10 = (double?)null, gpu30 = (double?)null,
            ssd5 = (double?)null, ssd10 = (double?)null, ssd30 = (double?)null },
        ["modelConfidence"] = new { cpu = (double?)null, gpu = (double?)null, ssd = (double?)null },
        ["timeToCritical"] = new { cpuBisection = (double?)null, cpuNewton = (double?)null,
            gpuBisection = (double?)null, gpuNewton = (double?)null, ssdBisection = (double?)null, ssdNewton = (double?)null },
        ["pca"] = new { explainedPC1 = (double?)null, explainedPC2 = (double?)null, dominantFactor = "Insufficient data" },
        ["coupling"] = new { jacobiIterations = 0, gaussSeidelIterations = 0, maxEigenRealPart = (double?)null, stability = "Insufficient data" },
        ["curveFit"] = new { cpuRMSE = (double?)null, gpuRMSE = (double?)null, ssdRMSE = (double?)null },
        ["history"] = new { time = Array.Empty<string>(), cpuTemp = Array.Empty<double?>(), gpuTemp = Array.Empty<double?>(), ssdTemp = Array.Empty<double?>(), cpuLoad = Array.Empty<double?>(), gpuLoad = Array.Empty<double?>(), ramLoad = Array.Empty<double?>() },
        ["safety"] = new { manualActionOnly = true, message = "ThermoTrack is advisory only. Check manufacturer limits and shut down if the system becomes unstable." },
        ["analysis_error"] = message
    };

    private object Snapshot()
    {
        lock (_dataLock) return new { sensor = _latestSensor, analysis = _latestAnalysis };
    }

    private void StopApp(object? sender, FormClosingEventArgs e)
    {
        _closing = true;
        _timer.Stop();
        lock (_dataLock) _history.Clear(); // bounded telemetry is intentionally RAM-only
        _api?.Dispose(); _analysis?.Dispose(); _sensors?.Dispose();
        AppDiagnostics.Write("Shutdown", "ThermoTrack closed; the in-memory telemetry history was cleared.");
    }
}
