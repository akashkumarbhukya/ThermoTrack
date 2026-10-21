using LibreHardwareMonitor.Hardware;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace ThermoTrack.App;

/// <summary>
/// Reads real hardware sensor values from LibreHardwareMonitorLib. Unsupported,
/// invalid, or zero-sentinel temperatures are returned as null (never fabricated).
/// </summary>
internal sealed class SensorService : IDisposable
{
    private Computer _computer = new();
    private string? _initializationError;
    private string? _initializationNote;
    private readonly Dictionary<int, (TimeSpan Cpu, DateTime Seen)> _processCpu = new();
    private bool _disposed;
    private string? _lastSamplingError;

    public SensorService() => InitializeHardware();

    private static Computer CreateComputer(bool enableGpu, bool enableStorage) => new()
    {
        IsCpuEnabled = true,
        IsGpuEnabled = enableGpu,
        IsStorageEnabled = enableStorage,
        // OS APIs are used for RAM. Controller/motherboard enumeration is not
        // required for CPU/GPU/SSD metrics and may fail on some driver stacks.
        IsMemoryEnabled = false,
        IsMotherboardEnabled = false,
        IsControllerEnabled = false,
        IsNetworkEnabled = false
    };

    private void InitializeHardware()
    {
        // Some hardware/driver combinations fail during one device family's
        // initialization. Retry progressively narrower configurations so one
        // problematic GPU/storage device does not disable every CPU sensor.
        var attempts = new[]
        {
            (Gpu: true, Storage: true, Label: "CPU/GPU/storage"),
            (Gpu: true, Storage: false, Label: "CPU/GPU"),
            (Gpu: false, Storage: false, Label: "CPU only")
        };
        Exception? lastError = null;
        foreach (var attempt in attempts)
        {
            var candidate = CreateComputer(attempt.Gpu, attempt.Storage);
            try
            {
                candidate.Open();
                _computer = candidate;
                if (lastError is not null)
                {
                    _initializationNote = $"Hardware monitoring started in reduced mode ({attempt.Label}) after another device family failed to initialize.";
                    AppDiagnostics.Write("Sensors", _initializationNote, lastError);
                }
                return;
            }
            catch (Exception ex)
            {
                lastError = ex;
                AppDiagnostics.Write("Sensors", $"LibreHardwareMonitor initialization attempt failed ({attempt.Label}).", ex);
                try { candidate.Close(); } catch { }
            }
        }
        _initializationError = lastError?.Message ?? "LibreHardwareMonitor could not initialize hardware access.";
        AppDiagnostics.Write("Sensors", "All hardware initialization attempts failed.", lastError);
    }

    public Dictionary<string, object?> Sample()
    {
        var memory = GlobalMemoryStatus();
        var timestamp = DateTime.Now.ToString("yyyy-MM-ddTHH:mm:ss.fff");
        if (_disposed || _initializationError is not null)
        {
            return BuildUnavailableRecord(timestamp, memory, _initializationError ?? "Sensor service is closed.");
        }

        try
        {
            foreach (var hardware in _computer.Hardware) UpdateRecursive(hardware);
            var all = new List<(IHardware Hardware, ISensor Sensor)>();
            foreach (var hardware in _computer.Hardware) Flatten(hardware, all);

            var selected = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase);
            double? Pick(string key, HardwareType[] hardwareTypes, SensorType sensorType, string[] aliases)
            {
                var candidates = all.Where(x => hardwareTypes.Contains(x.Hardware.HardwareType)
                    && x.Sensor.SensorType == sensorType && x.Sensor.Value.HasValue
                    && float.IsFinite(x.Sensor.Value.Value)).ToList();

                // Match exact names first, in priority order, as the original
                // collector does; then allow harmless driver naming variants.
                foreach (var alias in aliases)
                {
                    foreach (var item in candidates.Where(x => string.Equals(x.Sensor.Name, alias, StringComparison.OrdinalIgnoreCase)))
                    {
                        // Apply the same exclusion rules to exact-name matches as
                        // to fuzzy/fallback matches so hotspot/junction values do
                        // not accidentally become the base GPU temperature.
                        if (IsExcludedCandidate(key, item.Sensor.Name)) continue;
                        var value = ValidateMetric(key, item.Sensor.Value!.Value);
                        if (value.HasValue) { selected[key] = $"{item.Hardware.Name}: {item.Sensor.Name}"; return value; }
                    }
                }
                foreach (var alias in aliases)
                {
                    foreach (var item in candidates.Where(x => x.Sensor.Name.Contains(alias, StringComparison.OrdinalIgnoreCase)))
                    {
                        if (IsExcludedCandidate(key, item.Sensor.Name)) continue;
                        var value = ValidateMetric(key, item.Sensor.Value!.Value);
                        if (value.HasValue) { selected[key] = $"{item.Hardware.Name}: {item.Sensor.Name}"; return value; }
                    }
                }

                var fallback = FallbackCandidates(key, candidates);
                if (fallback.Count == 0) { selected[key] = null; return null; }
                // If firmware exposes per-core-only temperatures, use the
                // hottest valid core as a conservative thermal indicator.
                var pick = key == "cpu_temp" && fallback.Any(x => x.Sensor.Name.Contains("Core", StringComparison.OrdinalIgnoreCase))
                    ? fallback.OrderByDescending(x => x.Sensor.Value!.Value).First()
                    : fallback[0];
                var pickedValue = ValidateMetric(key, pick.Sensor.Value!.Value);
                selected[key] = pickedValue.HasValue ? $"{pick.Hardware.Name}: {pick.Sensor.Name}" : null;
                return pickedValue;
            }

            var cpu = new[] { HardwareType.Cpu };
            var gpu = new[] { HardwareType.GpuNvidia, HardwareType.GpuAmd, HardwareType.GpuIntel };
            var storage = new[] { HardwareType.Storage };

            var cpuTemp = Pick("cpu_temp", cpu, SensorType.Temperature,
                new[] { "Core (Tctl/Tdie)", "CPU (Tctl/Tdie)", "Tctl/Tdie", "CPU Package", "CPU Die (average)", "CPU Die", "Package", "Core Average", "CPU Core", "Core" });
            var cpuLoad = Pick("cpu_load", cpu, SensorType.Load,
                new[] { "CPU Total", "Total CPU", "CPU Utility", "Total Processor" });
            if (!cpuLoad.HasValue)
            {
                // On systems exposing only per-core load sensors, calculate a
                // true aggregate from the reported core loads; never invent it.
                var perCore = all.Where(x => x.Hardware.HardwareType == HardwareType.Cpu && x.Sensor.SensorType == SensorType.Load
                    && x.Sensor.Value.HasValue && float.IsFinite(x.Sensor.Value.Value)
                    && x.Sensor.Name.Contains("Core", StringComparison.OrdinalIgnoreCase))
                    .Select(x => ValidateMetric("cpu_load", x.Sensor.Value!.Value)).Where(x => x.HasValue).Select(x => x!.Value).ToArray();
                if (perCore.Length > 0) { cpuLoad = Math.Round(perCore.Average(), 2); selected["cpu_load"] = "Average of reported CPU core load sensors"; }
            }
            var cpuPower = Pick("cpu_power", cpu, SensorType.Power,
                new[] { "Package", "CPU Package", "CPU Power", "PPT" });

            var gpuTemp = Pick("gpu_temp", gpu, SensorType.Temperature,
                new[] { "GPU Core", "GPU Temperature", "Core Temperature", "GPU Edge", "Core" });
            var gpuHotspot = Pick("gpu_hotspot", gpu, SensorType.Temperature,
                new[] { "GPU Hot Spot", "GPU Hotspot", "Hotspot Temperature", "Hot Spot", "Junction" });
            var gpuLoad = Pick("gpu_load", gpu, SensorType.Load,
                new[] { "GPU Core", "GPU Core Load", "GPU Load", "D3D 3D", "GPU D3D Usage", "Core" });
            var gpuPower = Pick("gpu_power", gpu, SensorType.Power,
                new[] { "GPU Package", "GPU Power", "Board Power", "Total Board Power", "ASIC Power" });

            var ssdTemp = Pick("ssd_temp", storage, SensorType.Temperature,
                new[] { "Composite Temperature", "Drive Temperature", "Assembly", "Temperature" });
            var ssdActivity = Pick("ssd_activity", storage, SensorType.Load,
                new[] { "Total Activity", "Drive Activity", "Activity" });

            _lastSamplingError = null;
            var temperatures = new Dictionary<string, bool>
            {
                ["CPU temperature"] = cpuTemp.HasValue,
                ["GPU temperature"] = gpuTemp.HasValue,
                ["GPU hotspot"] = gpuHotspot.HasValue,
                ["SSD temperature"] = ssdTemp.HasValue
            };
            var unavailable = temperatures.Where(x => !x.Value).Select(x => x.Key).ToList();
            if (!cpuLoad.HasValue) unavailable.Add("CPU load");
            if (!cpuPower.HasValue) unavailable.Add("CPU power");
            if (!gpuLoad.HasValue) unavailable.Add("GPU load");
            if (!gpuPower.HasValue) unavailable.Add("GPU power");
            if (!ssdActivity.HasValue) unavailable.Add("SSD activity");

            var note = unavailable.Count == 0
                ? "All requested hardware metrics currently report valid readings."
                : "Unavailable/unsupported readings: " + string.Join(", ", unavailable) + ". Sensor support varies by hardware, firmware and driver; missing values are not fabricated.";
            if (!string.IsNullOrWhiteSpace(_initializationNote)) note = _initializationNote + " " + note;

            return new Dictionary<string, object?>
            {
                ["timestamp"] = timestamp,
                ["cpu_temp"] = cpuTemp, ["cpu_load"] = cpuLoad, ["cpu_power"] = cpuPower,
                ["gpu_temp"] = gpuTemp, ["gpu_hotspot"] = gpuHotspot, ["gpu_load"] = gpuLoad, ["gpu_power"] = gpuPower,
                ["ssd_temp"] = ssdTemp, ["ssd_activity"] = ssdActivity,
                ["ram_load"] = memory.LoadPercent, ["ram_used_gb"] = memory.UsedGb,
                ["top_processes"] = TopProcesses(), ["sensor_provider"] = "LibreHardwareMonitorLib",
                ["sensor_error"] = null, ["sensor_note"] = note,
                ["sensor_availability"] = new { cpu_temp = cpuTemp.HasValue, cpu_load = cpuLoad.HasValue, cpu_power = cpuPower.HasValue,
                    gpu_temp = gpuTemp.HasValue, gpu_hotspot = gpuHotspot.HasValue, gpu_load = gpuLoad.HasValue, gpu_power = gpuPower.HasValue,
                    ssd_temp = ssdTemp.HasValue, ssd_activity = ssdActivity.HasValue,
                    ram_load = memory.LoadPercent.HasValue, selectedSensors = selected }
            };
        }
        catch (Exception ex)
        {
            if (!string.Equals(_lastSamplingError, ex.Message, StringComparison.Ordinal))
                AppDiagnostics.Write("Sensors", "A sensor sampling cycle failed; unavailable readings will be reported for this cycle.", ex);
            _lastSamplingError = ex.Message;
            return BuildUnavailableRecord(timestamp, memory, ex.Message);
        }
    }

    private static double? ValidateMetric(string metric, float raw)
    {
        if (!float.IsFinite(raw)) return null;
        var value = (double)raw;
        return metric switch
        {
            "cpu_temp" or "gpu_temp" or "gpu_hotspot" or "ssd_temp" => value > 0.0 && value <= 150.0 ? Math.Round(value, 3) : null,
            "cpu_load" or "gpu_load" or "ssd_activity" or "ram_load" => value >= 0.0 && value <= 100.0 ? Math.Round(value, 3) : null,
            "cpu_power" or "gpu_power" => value >= 0.0 && value <= 2000.0 ? Math.Round(value, 3) : null,
            _ => Math.Round(value, 3)
        };
    }

    private static bool IsExcludedCandidate(string key, string name)
    {
        if (key is "cpu_temp" or "gpu_temp" or "ssd_temp")
        {
            var lower = name.ToLowerInvariant();
            if (lower.Contains("distance to") || lower.Contains("tjmax") || lower.Contains("offset")) return true;
            if (key == "cpu_temp" && (lower.Contains("hotspot") || lower.Contains("hot spot") || lower.Contains("memory"))) return true;
            if (key == "gpu_temp" && (lower.Contains("hotspot") || lower.Contains("hot spot") || lower.Contains("memory") || lower.Contains("junction"))) return true;
        }
        if (key == "gpu_hotspot") return false;
        if (key == "ssd_activity" && !(name.Contains("activity", StringComparison.OrdinalIgnoreCase))) return true;
        return false;
    }

    private static List<(IHardware Hardware, ISensor Sensor)> FallbackCandidates(string key, List<(IHardware Hardware, ISensor Sensor)> candidates)
    {
        var filtered = candidates.Where(x => !IsExcludedCandidate(key, x.Sensor.Name)
            && ValidateMetric(key, x.Sensor.Value!.Value).HasValue).ToList();
        if (key == "cpu_temp")
        {
            var thermal = filtered.Where(x => {
                var n = x.Sensor.Name;
                return n.Contains("core", StringComparison.OrdinalIgnoreCase) || n.Contains("package", StringComparison.OrdinalIgnoreCase)
                    || n.Contains("die", StringComparison.OrdinalIgnoreCase) || n.Contains("tctl", StringComparison.OrdinalIgnoreCase)
                    || n.Contains("tdie", StringComparison.OrdinalIgnoreCase);
            }).ToList();
            return thermal.Count > 0 ? thermal : new();
        }
        if (key == "gpu_temp")
        {
            var thermal = filtered.Where(x => {
                var n = x.Sensor.Name;
                return n.Contains("core", StringComparison.OrdinalIgnoreCase) || n.Contains("edge", StringComparison.OrdinalIgnoreCase)
                    || n.Contains("temperature", StringComparison.OrdinalIgnoreCase);
            }).ToList();
            return thermal.Count > 0 ? thermal : new();
        }
        if (key == "ssd_temp") return filtered;
        if (key == "gpu_hotspot") return filtered.Where(x => x.Sensor.Name.Contains("hot", StringComparison.OrdinalIgnoreCase)
            || x.Sensor.Name.Contains("junction", StringComparison.OrdinalIgnoreCase)).ToList();
        return new();
    }

    private static void UpdateRecursive(IHardware hardware)
    {
        try { hardware.Update(); } catch { /* One unsupported sensor family must not block the rest. */ }
        try { foreach (var child in hardware.SubHardware) UpdateRecursive(child); } catch { }
    }

    private static void Flatten(IHardware hardware, List<(IHardware Hardware, ISensor Sensor)> output)
    {
        try { foreach (var sensor in hardware.Sensors) output.Add((hardware, sensor)); } catch { }
        try { foreach (var child in hardware.SubHardware) Flatten(child, output); } catch { }
    }

    private Dictionary<string, object?> BuildUnavailableRecord(string timestamp, (double? LoadPercent, double? UsedGb) memory, string error)
    {
        return new Dictionary<string, object?>
        {
            ["timestamp"] = timestamp,
            ["cpu_temp"] = null, ["cpu_load"] = null, ["cpu_power"] = null,
            ["gpu_temp"] = null, ["gpu_hotspot"] = null, ["gpu_load"] = null, ["gpu_power"] = null,
            ["ssd_temp"] = null, ["ssd_activity"] = null,
            ["ram_load"] = memory.LoadPercent, ["ram_used_gb"] = memory.UsedGb,
            ["top_processes"] = TopProcesses(), ["sensor_provider"] = "LibreHardwareMonitorLib",
            ["sensor_error"] = error,
            ["sensor_note"] = "Hardware sensor access failed. Temperature readings are unavailable; no values are fabricated.",
            ["sensor_availability"] = new { cpu_temp = false, cpu_load = false, cpu_power = false, gpu_temp = false,
                gpu_hotspot = false, gpu_load = false, gpu_power = false, ssd_temp = false, ssd_activity = false,
                ram_load = memory.LoadPercent.HasValue, selectedSensors = new Dictionary<string, string?>() }
        };
    }

    private object[] TopProcesses()
    {
        var now = DateTime.UtcNow;
        var rows = new List<(string Name, int Pid, double Cpu)>();
        var alive = new HashSet<int>();
        foreach (var process in Process.GetProcesses())
        {
            try
            {
                alive.Add(process.Id);
                var cpuTime = process.TotalProcessorTime;
                if (_processCpu.TryGetValue(process.Id, out var previous))
                {
                    var elapsed = (now - previous.Seen).TotalSeconds;
                    if (elapsed > 0)
                    {
                        var cpu = Math.Clamp((cpuTime - previous.Cpu).TotalSeconds / (elapsed * Environment.ProcessorCount) * 100.0, 0.0, 100.0);
                        if (cpu >= 0.1) rows.Add((process.ProcessName, process.Id, Math.Round(cpu, 1)));
                    }
                }
                _processCpu[process.Id] = (cpuTime, now);
            }
            catch { }
            finally { process.Dispose(); }
        }
        foreach (var pid in _processCpu.Keys.Where(pid => !alive.Contains(pid)).ToArray()) _processCpu.Remove(pid);
        return rows.OrderByDescending(x => x.Cpu).Take(5)
            .Select(x => (object)new { name = x.Name, pid = x.Pid, cpu = x.Cpu }).ToArray();
    }

    private static (double? LoadPercent, double? UsedGb) GlobalMemoryStatus()
    {
        var status = new MEMORYSTATUSEX { dwLength = (uint)Marshal.SizeOf<MEMORYSTATUSEX>() };
        if (!GlobalMemoryStatusEx(ref status) || status.ullTotalPhys == 0) return (null, null);
        var used = status.ullTotalPhys - status.ullAvailPhys;
        return (Math.Round(used * 100.0 / status.ullTotalPhys, 2), Math.Round(used / 1073741824.0, 2));
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    private struct MEMORYSTATUSEX
    {
        public uint dwLength, dwMemoryLoad;
        public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile, ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX lpBuffer);

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        try { _computer.Close(); } catch (Exception ex) { AppDiagnostics.Write("Sensors", "Hardware monitoring shutdown reported an error.", ex); }
        _processCpu.Clear();
    }
}
