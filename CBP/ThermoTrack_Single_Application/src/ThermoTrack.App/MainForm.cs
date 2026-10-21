using Microsoft.Web.WebView2.WinForms;
using System.Diagnostics;
using System.Text.Json;

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
    private string _lastAlert = "NORMAL";
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
            var dashboard = Path.Combine(_base, "dashboard", "index.html");
            var worker = Path.Combine(_base, "analysis", "analysis_worker.exe");
            if (!File.Exists(dashboard)) throw new FileNotFoundException("The dashboard is missing from the installation.", dashboard);
            _sensors = new SensorService();
            _analysis = new AnalysisClient(worker);
            _api = new LocalApiServer(dashboard, Snapshot); _api.Start();
            // WebView2 must write its profile to a user-writable location, never Program Files.
            var webViewData = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "ThermoTrack", "WebView2");
            Directory.CreateDirectory(webViewData);
            var webViewEnvironment = await Microsoft.Web.WebView2.Core.CoreWebView2Environment.CreateAsync(
                userDataFolder: webViewData);
            await _web.EnsureCoreWebView2Async(webViewEnvironment);
            _web.CoreWebView2.Settings.AreDevToolsEnabled = false;
            _web.CoreWebView2.Settings.AreDefaultContextMenusEnabled = false;
            _web.Source = new Uri(_api.BaseUrl);
            await SampleOnceAsync(); _timer.Start();
        }
        catch (Exception ex)
        {
            MessageBox.Show(this,
                "ThermoTrack could not initialize. No sensor values will be fabricated.\n\n" + ex.Message +
                "\n\nIf this is a developer build, run the Windows build script again and check Windows security/driver permissions.",
                "ThermoTrack startup error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            Close();
        }
    }

    private async Task SampleOnceAsync()
    {
        if (_sampling || _sensors is null || _analysis is null) return;
        _sampling = true;
        try
        {
            var record = await Task.Run(() => _sensors.Sample());
            Dictionary<string, object?> analysis;
            lock (_dataLock)
            {
                _history.Add(record);
                if (_history.Count > 300) _history.RemoveAt(0);
                analysis = _analysis.Analyze(_history.ToArray());
                _latestSensor = record; _latestAnalysis = analysis;
            }
            var status = analysis.TryGetValue("status", out var s) ? s?.ToString() : "NORMAL";
            int Level(string? value) => value switch { "WATCH" => 1, "WARNING" => 2, "CRITICAL" => 3, "EMERGENCY" => 4, _ => 0 };
            if (Level(status) >= 2 && Level(status) > Level(_lastAlert)) System.Media.SystemSounds.Exclamation.Play();
            _lastAlert = status ?? "NORMAL";
        }
        catch (Exception ex)
        {
            lock (_dataLock)
            {
                _latestSensor = new Dictionary<string, object?> { ["timestamp"] = DateTime.Now.ToString("O"), ["cpu_temp"] = null, ["gpu_temp"] = null, ["ssd_temp"] = null, ["sensor_error"] = ex.Message };
                _latestAnalysis = new Dictionary<string, object?> { ["status"] = "DISCONNECTED", ["anomaly"] = "Sensor or analysis provider unavailable.", ["recommendation"] = "Check device sensor support. ThermoTrack will not invent missing readings." };
            }
        }
        finally { _sampling = false; }
    }

    private object Snapshot()
    {
        lock (_dataLock) return new { sensor = _latestSensor, analysis = _latestAnalysis };
    }

    private void StopApp(object? sender, FormClosingEventArgs e)
    {
        _timer.Stop();
        lock (_dataLock) _history.Clear(); // bounded telemetry is intentionally RAM-only
        _api?.Dispose(); _analysis?.Dispose(); _sensors?.Dispose();
    }
}
