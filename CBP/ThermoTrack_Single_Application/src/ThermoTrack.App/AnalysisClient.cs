using System.Diagnostics;
using System.Text.Json;

namespace ThermoTrack.App;

internal sealed class AnalysisClient : IDisposable
{
    private readonly Process _process;
    private readonly object _gate = new();
    public AnalysisClient(string workerPath)
    {
        if (!File.Exists(workerPath)) throw new FileNotFoundException("Bundled ThermoTrack analysis engine is missing.", workerPath);
        _process = new Process { StartInfo = new ProcessStartInfo(workerPath)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true,
            RedirectStandardError = true, WorkingDirectory = Path.GetDirectoryName(workerPath)!
        }};
        _process.Start();
    }

    public Dictionary<string, object?> Analyze(IReadOnlyCollection<Dictionary<string, object?>> history)
    {
        lock (_gate)
        {
            if (_process.HasExited) throw new InvalidOperationException("Analysis worker exited.");
            var request = JsonSerializer.Serialize(new { history });
            _process.StandardInput.WriteLine(request); _process.StandardInput.Flush();
            var response = _process.StandardOutput.ReadLine();
            if (string.IsNullOrWhiteSpace(response)) throw new InvalidOperationException("Analysis worker returned no result.");
            return JsonSerializer.Deserialize<Dictionary<string, object?>>(response) ?? new();
        }
    }
    public void Dispose() { try { if (!_process.HasExited) { _process.StandardInput.Close(); if (!_process.WaitForExit(1000)) _process.Kill(true); } } catch { } _process.Dispose(); }
}
