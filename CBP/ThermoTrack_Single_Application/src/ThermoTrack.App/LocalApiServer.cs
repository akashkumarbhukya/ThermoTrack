using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace ThermoTrack.App;

// Tiny loopback-only HTTP bridge for the preserved dashboard. Uses TcpListener so no
// Windows HTTP.sys URL reservation/admin setup is needed; the OS assigns an available port.
internal sealed class LocalApiServer : IDisposable
{
    private readonly TcpListener _listener;
    private readonly string _dashboardPath;
    private readonly Func<object> _snapshot;
    private CancellationTokenSource _stop = new();
    public int Port { get; }
    public string BaseUrl => $"http://127.0.0.1:{Port}/";

    public LocalApiServer(string dashboardPath, Func<object> snapshot)
    {
        _dashboardPath = dashboardPath; _snapshot = snapshot;
        _listener = new TcpListener(IPAddress.Loopback, 0);
        _listener.Start();
        Port = ((IPEndPoint)_listener.LocalEndpoint).Port;
    }

    public void Start() => _ = Task.Run(async () =>
    {
        while (!_stop.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await _listener.AcceptTcpClientAsync(_stop.Token); }
            catch (OperationCanceledException) { break; }
            catch (ObjectDisposedException) { break; }
            catch { continue; }
            _ = Task.Run(() => Handle(client));
        }
    });

    private async Task Handle(TcpClient client)
    {
        using (client)
        {
            try
            {
                client.ReceiveTimeout = 3000; client.SendTimeout = 3000;
                using var stream = client.GetStream();
                var request = new List<byte>(); var one = new byte[1];
                while (request.Count < 16384)
                {
                    var count = await stream.ReadAsync(one.AsMemory(0, 1));
                    if (count == 0) return;
                    request.Add(one[0]);
                    var n = request.Count;
                    if (n >= 4 && request[n-4] == 13 && request[n-3] == 10 && request[n-2] == 13 && request[n-1] == 10) break;
                }
                var firstLine = Encoding.ASCII.GetString(request.ToArray()).Split("\r\n", StringSplitOptions.None)[0];
                var parts = firstLine.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                if (parts.Length < 2) { await Respond(stream, 400, "text/plain; charset=utf-8", Encoding.UTF8.GetBytes("Bad request")); return; }
                var path = parts[1].Split('?', 2)[0];
                if (parts[0] != "GET") { await Respond(stream, 405, "text/plain; charset=utf-8", Encoding.UTF8.GetBytes("Method not allowed")); return; }
                if (path is "/" or "/index.html")
                {
                    var html = await File.ReadAllBytesAsync(_dashboardPath);
                    await Respond(stream, 200, "text/html; charset=utf-8", html);
                }
                else if (path is "/dashboard" or "/data")
                {
                    var payload = JsonSerializer.SerializeToUtf8Bytes(_snapshot());
                    if (path == "/data")
                    {
                        using var doc = JsonDocument.Parse(payload);
                        payload = JsonSerializer.SerializeToUtf8Bytes(doc.RootElement.GetProperty("sensor"));
                    }
                    await Respond(stream, 200, "application/json; charset=utf-8", payload);
                }
                else await Respond(stream, 404, "text/plain; charset=utf-8", Encoding.UTF8.GetBytes("Not found"));
            }
            catch { /* Client closed the local connection; no telemetry is persisted. */ }
        }
    }

    private static async Task Respond(NetworkStream stream, int status, string contentType, byte[] body)
    {
        var reason = status switch { 200 => "OK", 400 => "Bad Request", 404 => "Not Found", 405 => "Method Not Allowed", _ => "Error" };
        var headers = Encoding.ASCII.GetBytes($"HTTP/1.1 {status} {reason}\r\nContent-Type: {contentType}\r\nContent-Length: {body.Length}\r\nCache-Control: no-store, no-cache, must-revalidate\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n\r\n");
        await stream.WriteAsync(headers); await stream.WriteAsync(body); await stream.FlushAsync();
    }

    public void Dispose() { _stop.Cancel(); try { _listener.Stop(); } catch { } _stop.Dispose(); }
}
