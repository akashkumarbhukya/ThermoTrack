using System.Text;

namespace ThermoTrack.App;

/// <summary>Writes diagnostic errors only; hardware telemetry is never written to disk.</summary>
internal static class AppDiagnostics
{
    private static readonly object Gate = new();
    private static string LogPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "ThermoTrack", "Logs", "thermotrack.log");

    public static void Write(string component, string message, Exception? exception = null)
    {
        try
        {
            lock (Gate)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(LogPath)!);
                var detail = exception is null ? string.Empty : Environment.NewLine + exception;
                File.AppendAllText(LogPath,
                    $"{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss.fff zzz} [{component}] {message}{detail}{Environment.NewLine}",
                    Encoding.UTF8);
            }
        }
        catch
        {
            // Logging must never prevent the app or sensor sampling from running.
        }
    }
}
