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
        _process = new Process
        {
            StartInfo = new ProcessStartInfo(workerPath)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                WorkingDirectory = Path.GetDirectoryName(workerPath)!
            },
            EnableRaisingEvents = true
        };
        if (!_process.Start()) throw new InvalidOperationException("The ThermoTrack analysis worker process could not be started.");
        // Drain stderr continuously. If an underlying numerical library writes
        // enough diagnostics to a redirected pipe, an unread pipe can block it.
        _process.ErrorDataReceived += (_, args) =>
        {
            if (!string.IsNullOrWhiteSpace(args.Data)) AppDiagnostics.Write("Analysis worker", args.Data);
        };
        _process.BeginErrorReadLine();
    }

    public Dictionary<string, object?> Analyze(IReadOnlyCollection<Dictionary<string, object?>> history)
    {
        lock (_gate)
        {
            if (_process.HasExited) throw new InvalidOperationException($"Analysis worker exited with code {_process.ExitCode}.");
            var request = JsonSerializer.Serialize(new { history });
            _process.StandardInput.WriteLine(request);
            _process.StandardInput.Flush();
            var response = _process.StandardOutput.ReadLine();
            if (string.IsNullOrWhiteSpace(response)) throw new InvalidOperationException("Analysis worker returned no result.");
            var result = JsonSerializer.Deserialize<Dictionary<string, object?>>(response);
            if (result is null) throw new InvalidOperationException("Analysis worker returned invalid JSON.");
            if (result.TryGetValue("status", out var status) && status?.ToString() == "ERROR")
                throw new InvalidOperationException(result.TryGetValue("error", out var error) ? error?.ToString() : "Analysis worker error.");
            return result;
        }
    }

    public void Dispose()
    {
        try
        {
            if (!_process.HasExited)
            {
                _process.StandardInput.Close();
                if (!_process.WaitForExit(1500)) _process.Kill(true);
            }
        }
        catch (Exception ex) { AppDiagnostics.Write("Analysis", "Analysis worker shutdown reported an error.", ex); }
        _process.Dispose();
    }
}
