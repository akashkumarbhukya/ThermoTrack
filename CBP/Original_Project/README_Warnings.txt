THERMAL INTELLIGENCE — WARNING UPDATE

Files included:
- collector.py         Python live sensor collector + local web server + Windows sound alerts
- matlab_receiver.m   MATLAB numerical engine + warning/anomaly/cause analysis
- index.html          Dashboard UI

STARTUP
1. Start LibreHardwareMonitor and enable its Remote Web Server on port 8085.
2. Open a terminal in this folder and run: python collector.py
3. In MATLAB, run matlab_receiver.m from this folder.
4. Open http://127.0.0.1:5000/ in the browser.
5. Stop collection with Ctrl+C in the Python terminal. The in-memory buffer is cleared by the collector.

WARNING RULES (prototype defaults; check OEM specifications for your exact hardware)
WATCH:
- CPU >= 75 C, GPU core >= 70 C, GPU hotspot >= 90 C, or SSD >= 55 C
- A sustained rise around 0.015 C/s or a rise of about 0.8 C over 10 samples

WARNING:
- CPU >= 85 C, GPU core >= 80 C, GPU hotspot >= 100 C, or SSD >= 65 C
- Rapid rise around 0.04 C/s or about 2 C over 10 samples
- Prediction indicates a component may reach a warning/critical range within 10 minutes

CRITICAL:
- CPU >= 95 C, GPU core >= 88 C, GPU hotspot >= 105 C, or SSD >= 75 C

BEHAVIOUR
- A hot but stable CPU/GPU/SSD is not shown as normal just because its latest heating rate is negative.
- The anomaly card lists elevated readings and/or rapid rises.
- The cause panel uses temperature, load, power and SSD activity to suggest likely contributors.
  These sensors cannot prove physical causes such as blocked vents, dust or fan failure; those remain checks for the user.
- Windows emits one beep when entering WARNING and two beeps when severity escalates to CRITICAL. Set BEEP_ON_ALERT=False in collector.py to disable.
- No automatic app termination or shutdown is performed. The program is on-demand, and telemetry is kept in RAM only.

VALIDATION NOTES
- collector.py was checked with Python's syntax compiler.
- The dashboard JavaScript was checked with Node's syntax checker.
- MATLAB R2026a is not available in this execution environment, so run matlab_receiver.m in your MATLAB session to validate live behavior.
