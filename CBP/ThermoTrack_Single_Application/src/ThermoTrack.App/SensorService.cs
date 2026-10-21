using LibreHardwareMonitor.Hardware;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace ThermoTrack.App;

internal sealed class SensorService : IDisposable
{
    private readonly Computer _computer = new()
    {
        IsCpuEnabled = true,
        IsGpuEnabled = true,
        IsStorageEnabled = true,
        IsMemoryEnabled = true,
        IsMotherboardEnabled = true,
        IsControllerEnabled = true,
        IsNetworkEnabled = false
    };
    private ulong _idle, _kernel, _user;
    private readonly Dictionary<int, (TimeSpan Cpu, DateTime Seen)> _processCpu = new();
    private string? _initializationError;

    public SensorService()
    {
        try { _computer.Open(); }
        catch (Exception ex)
        {
            // Keep the UI available even when this PC blocks or lacks hardware sensor access.
            _initializationError = ex.Message;
        }
    }

    public Dictionary<string, object?> Sample()
    {
        if (_initializationError is not null)
        {
            var memoryFallback = GlobalMemoryStatus();
            return new Dictionary<string, object?>
            {
                ["timestamp"] = DateTime.Now.ToString("yyyy-MM-ddTHH:mm:ss.fff"),
                ["cpu_temp"] = null, ["cpu_load"] = null, ["cpu_power"] = null,
                ["gpu_temp"] = null, ["gpu_hotspot"] = null, ["gpu_load"] = null, ["gpu_power"] = null,
                ["ssd_temp"] = null, ["ssd_activity"] = null,
                ["ram_load"] = memoryFallback.LoadPercent, ["ram_used_gb"] = memoryFallback.UsedGb,
                ["top_processes"] = TopProcesses(), ["sensor_provider"] = "LibreHardwareMonitorLib",
                ["sensor_error"] = _initializationError,
                ["sensor_note"] = "Hardware sensors could not be initialized. Temperature readings are unavailable; no values are fabricated."
            };
        }

        foreach (var hardware in _computer.Hardware) UpdateRecursive(hardware);
        var all = new List<(IHardware Hardware, ISensor Sensor)>();
        foreach (var hardware in _computer.Hardware) Flatten(hardware, all);

        double? Pick(HardwareType[] hardwareTypes, SensorType sensorType, params string[] aliases)
        {
            var candidates = all.Where(x => hardwareTypes.Contains(x.Hardware.HardwareType) && x.Sensor.SensorType == sensorType && x.Sensor.Value.HasValue).ToList();
            foreach (var alias in aliases)
            {
                var exact = candidates.FirstOrDefault(x => string.Equals(x.Sensor.Name, alias, StringComparison.OrdinalIgnoreCase));
                if (exact.Sensor is not null) return Finite(exact.Sensor.Value);
            }
            foreach (var alias in aliases)
            {
                var partial = candidates.FirstOrDefault(x => x.Sensor.Name.Contains(alias, StringComparison.OrdinalIgnoreCase));
                if (partial.Sensor is not null) return Finite(partial.Sensor.Value);
            }
            return null;
        }

        var cpu = new[] { HardwareType.Cpu };
        var gpu = new[] { HardwareType.GpuNvidia, HardwareType.GpuAmd, HardwareType.GpuIntel };
        var storage = new[] { HardwareType.Storage };
        var memory = GlobalMemoryStatus();
        var processes = TopProcesses();
        return new Dictionary<string, object?>
        {
            ["timestamp"] = DateTime.Now.ToString("yyyy-MM-ddTHH:mm:ss.fff"),
            ["cpu_temp"] = Pick(cpu, SensorType.Temperature, "Core (Tctl/Tdie)", "CPU Package", "CPU Die (average)", "CPU Core", "Package"),
            ["cpu_load"] = Pick(cpu, SensorType.Load, "CPU Total", "Total CPU"),
            ["cpu_power"] = Pick(cpu, SensorType.Power, "Package", "CPU Package"),
            ["gpu_temp"] = Pick(gpu, SensorType.Temperature, "GPU Core", "GPU Temperature", "Core Temperature"),
            ["gpu_hotspot"] = Pick(gpu, SensorType.Temperature, "GPU Hot Spot", "Hotspot Temperature", "GPU Hotspot"),
            ["gpu_load"] = Pick(gpu, SensorType.Load, "GPU Core", "GPU Core Load", "GPU Load"),
            ["gpu_power"] = Pick(gpu, SensorType.Power, "GPU Package", "GPU Power", "Board Power"),
            ["ssd_temp"] = Pick(storage, SensorType.Temperature, "Composite Temperature", "Drive Temperature", "Assembly"),
            ["ssd_activity"] = Pick(storage, SensorType.Load, "Total Activity", "Drive Activity"),
            ["ram_load"] = memory.LoadPercent,
            ["ram_used_gb"] = memory.UsedGb,
            ["top_processes"] = processes,
            ["sensor_provider"] = "LibreHardwareMonitorLib",
            ["sensor_note"] = "A null reading means this hardware/driver did not expose that sensor."
        };
    }

    private static double? Finite(float? value) => value.HasValue && float.IsFinite(value.Value) ? Math.Round(value.Value, 3) : null;
    private static void UpdateRecursive(IHardware h) { try { h.Update(); } catch { } foreach (var sub in h.SubHardware) UpdateRecursive(sub); }
    private static void Flatten(IHardware h, List<(IHardware, ISensor)> output) { foreach (var s in h.Sensors) output.Add((h, s)); foreach (var sub in h.SubHardware) Flatten(sub, output); }

    private object[] TopProcesses()
    {
        var now = DateTime.UtcNow;
        var rows = new List<(string Name, int Pid, double Cpu)>();
        foreach (var p in Process.GetProcesses())
        {
            try
            {
                var cpuTime = p.TotalProcessorTime;
                var cpu = 0.0;
                if (_processCpu.TryGetValue(p.Id, out var previous))
                {
                    var elapsed = (now - previous.Seen).TotalSeconds;
                    if (elapsed > 0) cpu = Math.Max(0, (cpuTime - previous.Cpu).TotalSeconds / (elapsed * Environment.ProcessorCount) * 100.0);
                }
                _processCpu[p.Id] = (cpuTime, now);
                rows.Add((p.ProcessName, p.Id, Math.Round(cpu, 1)));
            }
            catch { }
            finally { p.Dispose(); }
        }
        var alive = rows.Select(x => x.Pid).ToHashSet();
        foreach (var pid in _processCpu.Keys.Where(pid => !alive.Contains(pid)).ToArray()) _processCpu.Remove(pid);
        return rows.OrderByDescending(x => x.Cpu).Take(5).Select(x => (object)new { name = x.Name, pid = x.Pid, cpu = x.Cpu }).ToArray();
    }

    private static (double LoadPercent, double UsedGb) GlobalMemoryStatus()
    {
        var s = new MEMORYSTATUSEX(); s.dwLength = (uint)Marshal.SizeOf<MEMORYSTATUSEX>();
        if (!GlobalMemoryStatusEx(ref s)) return (0, 0);
        var total = Math.Max(1UL, s.ullTotalPhys); var used = total - s.ullAvailPhys;
        return (Math.Round(used * 100.0 / total, 2), Math.Round(used / 1073741824.0, 2));
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)] private struct MEMORYSTATUSEX
    {
        public uint dwLength, dwMemoryLoad; public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile, ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)] private static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX lpBuffer);
    public void Dispose() { try { _computer.Close(); } catch { } }
}
