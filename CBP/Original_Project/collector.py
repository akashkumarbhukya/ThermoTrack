import json
import re
import os
import webbrowser
from pathlib import Path
import threading
import time
from collections import deque
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import psutil
import requests

try:
    import winsound
except ImportError:  # non-Windows fallback
    winsound = None

PROJECT_DIR = Path(__file__).resolve().parent
DASHBOARD_PATH = PROJECT_DIR / "index.html"
LHM_URL = "http://127.0.0.1:8085/data.json"
HOST = "127.0.0.1"
PORT = 5000
BUFFER_SIZE = 300              # 5 minutes at 1 sample/sec
SAMPLE_INTERVAL = 1.0
BEEP_ON_ALERT = True

buffer = deque(maxlen=BUFFER_SIZE)
latest_record = {}
latest_analysis = {}
last_alert_status = "NORMAL"


def parse_value(value):
    if value is None:
        return None
    match = re.search(r"-?\d+(?:\.\d+)?", str(value))
    return float(match.group()) if match else None


def collect_sensors(node, sensors=None):
    if sensors is None:
        sensors = []
    if isinstance(node, dict):
        if "Type" in node and "Value" in node:
            sensors.append({
                "type": str(node["Type"]),
                "name": str(node.get("Text", node.get("Name", ""))),
                "value": parse_value(node["Value"]),
            })
        for value in node.values():
            collect_sensors(value, sensors)
    elif isinstance(node, list):
        for item in node:
            collect_sensors(item, sensors)
    return sensors


def find_sensor(sensors, sensor_type, sensor_name):
    for sensor in sensors:
        if sensor["type"] == sensor_type and sensor["name"] == sensor_name:
            return sensor["value"]
    return None


def read_hardware():
    response = requests.get(LHM_URL, timeout=2)
    response.raise_for_status()
    return response.json()


def get_top_processes(limit=5):
    rows = []
    for proc in psutil.process_iter(["pid", "name"]):
        try:
            cpu = proc.cpu_percent(interval=None)
            if cpu is not None and cpu > 0:
                rows.append({
                    "pid": proc.info["pid"],
                    "name": proc.info.get("name") or "Unknown",
                    "cpu": round(float(cpu), 1),
                })
        except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
            continue
    rows.sort(key=lambda x: x["cpu"], reverse=True)
    return rows[:limit]


class DataHandler(BaseHTTPRequestHandler):
    def _set_json_headers(self):
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.send_header("Pragma", "no-cache")

    def send_json(self, payload, status=200):
        raw = json.dumps(payload, separators=(",", ":"), allow_nan=False)
        self.send_response(status)
        self._set_json_headers()
        self.end_headers()
        self.wfile.write(raw.encode("utf-8"))

    def do_GET(self):
        path = self.path.split("?", 1)[0]

        if path in ("/", "/index.html"):
            try:
                with DASHBOARD_PATH.open("rb") as file:
                    page = file.read()
            except FileNotFoundError:
                self.send_response(404)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(page)
            return

        if path == "/data":
            self.send_json(latest_record)
            return

        if path == "/dashboard":
            payload = {
                "sensor": latest_record,
                "analysis": latest_analysis,
            }
            self.send_json(payload)
            return

        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        global last_alert_status

        path = self.path.split("?", 1)[0]
        if path != "/analysis":
            self.send_response(404)
            self.end_headers()
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length)
            analysis = json.loads(body.decode("utf-8"))
            latest_analysis.clear()
            latest_analysis.update(analysis)

            status = str(analysis.get("status", "NORMAL"))
            if BEEP_ON_ALERT and winsound is not None:
                levels = {"NORMAL": 0, "WATCH": 1, "WARNING": 2, "CRITICAL": 3, "EMERGENCY": 4}
                current_level = levels.get(status, 0)
                previous_level = levels.get(last_alert_status, 0)
                # Beep once when entering WARNING; repeat the pattern on escalation to CRITICAL.
                # This avoids a continuous sound every second while the warning remains active.
                if current_level >= 2 and current_level > previous_level:
                    try:
                        if current_level == 2:
                            winsound.Beep(950, 300)
                        else:
                            winsound.Beep(1250, 450)
                            winsound.Beep(1250, 450)
                    except (RuntimeError, OSError):
                        pass

            last_alert_status = status
            self.send_json({"status": "ok"})
        except Exception as exc:
            self.send_json({"status": "error", "message": str(exc)}, status=400)

    def log_message(self, _format, *_args):
        return


def start_server():
    server = ThreadingHTTPServer((HOST, PORT), DataHandler)
    print(f"Dashboard : http://{HOST}:{PORT}/")
    print(f"Data API  : http://{HOST}:{PORT}/data")
    print(f"Dash API  : http://{HOST}:{PORT}/dashboard")
    server.serve_forever()


def main():
    if not DASHBOARD_PATH.is_file():
        raise FileNotFoundError(f"Dashboard file not found: {DASHBOARD_PATH}")

    # Bind synchronously so port conflicts are reported before sensor collection starts.
    try:
        server = ThreadingHTTPServer((HOST, PORT), DataHandler)
    except OSError as exc:
        raise RuntimeError(
            f"Could not start ThermoTrack web interface at http://{HOST}:{PORT}/. "
            f"Port {PORT} may already be in use. Close the previous collector instance and retry."
        ) from exc

    threading.Thread(target=server.serve_forever, daemon=True).start()
    dashboard_url = f"http://{HOST}:{PORT}/"
    print(f"Dashboard : {dashboard_url}")
    print(f"Data API  : http://{HOST}:{PORT}/data")
    print(f"Dash API  : http://{HOST}:{PORT}/dashboard")
    # Open only after the local server has successfully bound its port.
    threading.Timer(1.0, lambda: webbrowser.open(dashboard_url)).start()
    print("=" * 68)
    print("                 THERMAL INTELLIGENCE")
    print("=" * 68)
    print("Sampling interval : 1 second")
    print("RAM buffer        : 300 samples")
    print("Permanent storage : NONE")
    print("Press Ctrl+C to stop")
    print()

    # Prime per-process CPU accounting.
    for proc in psutil.process_iter():
        try:
            proc.cpu_percent(interval=None)
        except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
            pass

    try:
        while True:
            cycle_start = time.monotonic()
            hardware = read_hardware()
            sensors = collect_sensors(hardware)
            memory = psutil.virtual_memory()
            top_processes = get_top_processes(limit=5)

            record = {
                "timestamp": datetime.now().isoformat(timespec="milliseconds"),
                "cpu_temp": find_sensor(sensors, "Temperature", "Core (Tctl/Tdie)"),
                "cpu_load": find_sensor(sensors, "Load", "CPU Total"),
                "cpu_power": find_sensor(sensors, "Power", "Package"),
                "gpu_temp": find_sensor(sensors, "Temperature", "GPU Core"),
                "gpu_hotspot": find_sensor(sensors, "Temperature", "GPU Hot Spot"),
                "gpu_load": find_sensor(sensors, "Load", "GPU Core"),
                "gpu_power": find_sensor(sensors, "Power", "GPU Package"),
                "ssd_temp": find_sensor(sensors, "Temperature", "Composite Temperature"),
                "ssd_activity": find_sensor(sensors, "Load", "Total Activity"),
                "ram_load": round(float(memory.percent), 2),
                "ram_used_gb": round(memory.used / (1024 ** 3), 2),
                "top_processes": top_processes,
            }

            # Make None/NaN-safe JSON by converting unavailable sensor values to None.
            for key, value in list(record.items()):
                if isinstance(value, float) and (value != value or value in (float("inf"), float("-inf"))):
                    record[key] = None

            latest_record.clear()
            latest_record.update(record)
            buffer.append(record)

            print(
                f"CPU {record['cpu_temp'] if record['cpu_temp'] is not None else '-'}°C | "
                f"GPU {record['gpu_temp'] if record['gpu_temp'] is not None else '-'}°C | "
                f"SSD {record['ssd_temp'] if record['ssd_temp'] is not None else '-'}°C | "
                f"CPU Load {record['cpu_load'] if record['cpu_load'] is not None else '-'}% | "
                f"RAM {record['ram_load']}% | "
                f"Buffer {len(buffer)}/{BUFFER_SIZE}"
            )

            elapsed = time.monotonic() - cycle_start
            time.sleep(max(0.0, SAMPLE_INTERVAL - elapsed))

    except KeyboardInterrupt:
        buffer.clear()
        latest_record.clear()
        latest_analysis.clear()
        print("\nMonitoring stopped. RAM data cleared.")


if __name__ == "__main__":
    main()
