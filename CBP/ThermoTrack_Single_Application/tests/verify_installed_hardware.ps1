$ErrorActionPreference = 'Stop'

Write-Host 'ThermoTrack installed-app and physical sensor verification' -ForegroundColor Cyan
Write-Host 'This checks actual readings from the running Windows app. Missing sensors are reported, not fabricated.'

$installedCandidates = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\ThermoTrack\ThermoTrack.exe'),
    (Join-Path $env:ProgramFiles 'ThermoTrack\ThermoTrack.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'ThermoTrack\ThermoTrack.exe')
) | Where-Object { $_ -and (Test-Path $_) }

$process = Get-Process -Name 'ThermoTrack' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $process) {
    if (-not $installedCandidates) {
        Write-Host 'FAIL: ThermoTrack.exe was not found in common install locations.' -ForegroundColor Red
        Write-Host 'Install the latest successful ThermoTrack Windows artifact first.'
        exit 2
    }
    $exe = $installedCandidates[0]
    Write-Host "Launching: $exe"
    Start-Process -FilePath $exe | Out-Null
    Start-Sleep -Seconds 2
    $deadline = (Get-Date).AddSeconds(45)
    do {
        $process = Get-Process -Name 'ThermoTrack' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($process) { break }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
}

if (-not $process) {
    Write-Host 'FAIL: ThermoTrack did not remain running. Check its startup dialog and diagnostic log.' -ForegroundColor Red
    exit 3
}

$process.Refresh()
$pidToTest = $process.Id
Write-Host "Process is running (PID $pidToTest). Sampling live API for up to 20 seconds..."

function Get-ThermoTrackPort([int]$ProcessId) {
    try {
        $connections = Get-NetTCPConnection -State Listen -OwningProcess $ProcessId -ErrorAction Stop
        foreach ($connection in $connections) {
            if ($connection.LocalAddress -in @('127.0.0.1', '::1', '0.0.0.0', '::')) {
                return [int]$connection.LocalPort
            }
        }
    } catch { }
    return $null
}

$port = $null
$deadline = (Get-Date).AddSeconds(45)
while ((Get-Date) -lt $deadline -and -not $port) {
    $process.Refresh()
    if ($process.HasExited) { break }
    $port = Get-ThermoTrackPort -ProcessId $pidToTest
    if (-not $port) { Start-Sleep -Milliseconds 500 }
}

if (-not $port) {
    Write-Host 'FAIL: No local dashboard API listener was found for ThermoTrack.' -ForegroundColor Red
    Write-Host 'This usually means startup did not complete. Inspect:'
    Write-Host (Join-Path $env:LOCALAPPDATA 'ThermoTrack\Logs\thermotrack.log')
    exit 4
}

$base = "http://127.0.0.1:$port"
try {
    $first = Invoke-RestMethod -Uri "$base/data" -TimeoutSec 5
} catch {
    Write-Host "FAIL: The local sensor API did not respond at $base/data" -ForegroundColor Red
    Write-Host $_.Exception.Message
    exit 5
}

$metrics = @('cpu_temp', 'gpu_temp', 'gpu_hotspot', 'ssd_temp')
$validCounts = @{}
$minValues = @{}
$maxValues = @{}
foreach ($metric in $metrics) {
    $validCounts[$metric] = 0
    $minValues[$metric] = [double]::PositiveInfinity
    $maxValues[$metric] = [double]::NegativeInfinity
}
$notes = @()
$rounds = 10
for ($i = 0; $i -lt $rounds; $i++) {
    try {
        $record = Invoke-RestMethod -Uri "$base/data" -TimeoutSec 5
        foreach ($metric in $metrics) {
            $value = $record.$metric
            if ($null -ne $value) {
                $number = 0.0
                if ([double]::TryParse([string]$value, [ref]$number) -and $number -gt 0 -and $number -le 150) {
                    $validCounts[$metric]++
                    $minValues[$metric] = [Math]::Min($minValues[$metric], $number)
                    $maxValues[$metric] = [Math]::Max($maxValues[$metric], $number)
                }
            }
        }
        if ($record.sensor_note) { $notes += [string]$record.sensor_note }
    } catch {
        Write-Host "WARNING: sample $($i + 1) failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    if ($i -lt ($rounds - 1)) { Start-Sleep -Seconds 2 }
}

Write-Host ''
Write-Host '=== Sensor results ===' -ForegroundColor Cyan
foreach ($metric in $metrics) {
    $label = switch ($metric) {
        'cpu_temp' { 'CPU temperature' }
        'gpu_temp' { 'GPU temperature' }
        'gpu_hotspot' { 'GPU hotspot' }
        'ssd_temp' { 'SSD temperature' }
    }
    if ($validCounts[$metric] -ge 3) {
        Write-Host ("PASS  {0}: {1}/{2} valid samples, observed range {3:N1}-{4:N1} °C" -f $label, $validCounts[$metric], $rounds, $minValues[$metric], $maxValues[$metric]) -ForegroundColor Green
    } else {
        Write-Host ("CHECK {0}: only {1}/{2} valid samples. This sensor may be unsupported or not readable on this PC." -f $label, $validCounts[$metric], $rounds) -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host '=== Other live fields ===' -ForegroundColor Cyan
foreach ($field in @('cpu_load', 'cpu_power', 'gpu_load', 'gpu_power', 'ssd_activity', 'ram_load')) {
    Write-Host ("{0}: {1}" -f $field, $(if ($null -ne $first.$field) { $first.$field } else { 'unavailable' }))
}
if ($first.sensor_note) { Write-Host "Sensor note: $($first.sensor_note)" }

$logPath = Join-Path $env:LOCALAPPDATA 'ThermoTrack\Logs\thermotrack.log'
if (Test-Path $logPath) {
    Write-Host "Diagnostic log: $logPath"
    $tail = Get-Content $logPath -Tail 80 -ErrorAction SilentlyContinue
    $issues = $tail | Where-Object { $_ -match '\[(Startup|WebView2|Sensors|Sampling)\].*(failed|error|unavailable|could not)' }
    if ($issues) {
        Write-Host 'Recent initialization/sensor diagnostic entries:' -ForegroundColor Yellow
        $issues | Select-Object -Last 10 | ForEach-Object { Write-Host $_ }
    }
}

$primary = @('cpu_temp', 'gpu_temp', 'ssd_temp')
$primaryPass = @($primary | Where-Object { $validCounts[$_] -ge 3 }).Count
if ($primaryPass -eq 3) {
    Write-Host "`nRESULT: PASS — CPU, GPU and SSD temperature readings were valid in at least 3 samples each." -ForegroundColor Green
    Write-Host 'Compare their displayed values with the original edition running on the same PC. Hotspot availability varies by GPU.'
    exit 0
}
if ($primaryPass -gt 0) {
    Write-Host "`nRESULT: PARTIAL — $primaryPass of 3 primary temperature groups reported valid readings. Check the sensor notes/log and compare with the original app." -ForegroundColor Yellow
    exit 6
}
Write-Host "`nRESULT: FAIL — no primary CPU/GPU/SSD temperature group produced enough valid readings." -ForegroundColor Red
Write-Host 'Send the report above and the last 80 lines of the diagnostic log for analysis. Do not disable UAC or Windows security.'
exit 7
