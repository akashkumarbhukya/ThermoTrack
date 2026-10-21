$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Python = Get-Command python -ErrorAction SilentlyContinue
if (-not $Python) { throw 'Python 3.11 x64 is required on the BUILD machine only.' }
$Dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if (-not $Dotnet) { throw '.NET 8 SDK is required on the BUILD machine only.' }
$iss = Get-Command ISCC.exe -ErrorAction SilentlyContinue
if (-not $iss) {
    $candidate = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
    if (-not (Test-Path $candidate)) { $candidate = Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe' }
    if (Test-Path $candidate) { $iss = [pscustomobject]@{ Source = $candidate } }
    else { throw 'Inno Setup 6 is required on the BUILD machine only.' }
}

$BuildDir = Join-Path $Root 'build\worker-build'
$DistDir = Join-Path $Root 'build\worker-dist'
$Publish = Join-Path $Root 'publish'
$InstallerDir = Join-Path $Root 'dist'
Remove-Item $BuildDir,$DistDir,$Publish,$InstallerDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $BuildDir,$DistDir,$Publish,$InstallerDir | Out-Null

Push-Location $Root
try {
    python -m pip install --upgrade pip
    if ($LASTEXITCODE -ne 0) { throw 'pip upgrade failed.' }
    python -m pip install -r (Join-Path $Root 'requirements-build.txt')
    if ($LASTEXITCODE -ne 0) { throw 'Installing the Python build/test dependencies failed.' }

    python -m pytest (Join-Path $Root 'tests') -q
    if ($LASTEXITCODE -ne 0) { throw 'ThermoTrack analysis tests failed. The installer will not be produced.' }

    python -m PyInstaller --clean --noconfirm --onefile --console --name analysis_worker --distpath $DistDir --workpath $BuildDir (Join-Path $Root 'analysis\analysis_worker.py')
    if ($LASTEXITCODE -ne 0) { throw 'Building the bundled numerical-analysis worker failed.' }
    $WorkerExe = Join-Path $DistDir 'analysis_worker.exe'
    if (-not (Test-Path $WorkerExe)) { throw "Analysis worker output is missing: $WorkerExe" }

    # Smoke-test the frozen worker itself using the same protocol as AnalysisClient:
    # one non-empty JSON request line yields exactly one JSON response line.
    # Blank-line tolerance is covered by test_worker_ignores_blank_protocol_lines
    # against the source worker. Injecting a synthetic blank line into the frozen
    # Windows EXE caused a second ERROR response on the hosted runner even though
    # the source-level protocol test passes; the application never sends blank
    # requests, so keep the packaged smoke test faithful to production traffic.
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $WorkerExe
    $start.WorkingDirectory = $DistDir
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $workerProcess = [System.Diagnostics.Process]::Start($start)
    if ($null -eq $workerProcess) { throw 'Could not start the bundled analysis worker smoke test.' }
    try {
        # Read both pipes asynchronously before writing/waiting so neither pipe can fill and deadlock.
        $stdoutTask = $workerProcess.StandardOutput.ReadToEndAsync()
        $stderrTask = $workerProcess.StandardError.ReadToEndAsync()
        $request = '{"history":[{"timestamp":"2026-01-01T00:00:00.000","cpu_temp":null,"gpu_temp":null,"ssd_temp":null,"ram_load":42}]}'
        $workerProcess.StandardInput.WriteLine($request)
        $workerProcess.StandardInput.Flush()
        $workerProcess.StandardInput.Close()
        if (-not $workerProcess.WaitForExit(30000)) {
            $workerProcess.Kill($true)
            throw 'The bundled analysis worker did not respond within 30 seconds.'
        }
        $workerProcess.WaitForExit()
        $stdoutText = $stdoutTask.GetAwaiter().GetResult()
        $workerError = $stderrTask.GetAwaiter().GetResult()
        $responseLines = @($stdoutText -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($workerProcess.ExitCode -ne 0) {
            throw "Bundled analysis worker exited with code $($workerProcess.ExitCode). stdout='$stdoutText'; stderr='$workerError'"
        }
        if ($responseLines.Count -ne 1) {
            throw "Bundled analysis worker must emit exactly one non-empty JSON response for one request. Responses=$($responseLines.Count); stdout='$stdoutText'; stderr='$workerError'"
        }
        $workerResponse = [string]$responseLines[0]
        try {
            $workerJson = $workerResponse | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw "Bundled analysis worker returned invalid JSON. Raw response: $workerResponse. stderr='$workerError'. Parse error: $($_.Exception.Message)"
        }

        # Validate both semantic correctness and the presence of required fields.
        $statusValue = [string]$workerJson.status
        $maxTemperatureProperty = $workerJson.PSObject.Properties['maxTemperature']
        $predictionProperty = $workerJson.PSObject.Properties['prediction']
        $predictionCpu5Property = $null
        if ($null -ne $predictionProperty -and $null -ne $predictionProperty.Value) {
            $predictionCpu5Property = $predictionProperty.Value.PSObject.Properties['cpu5']
        }
        $maxTemperatureIsNull = ($null -ne $maxTemperatureProperty -and $null -eq $maxTemperatureProperty.Value)
        $predictionCpu5IsNull = ($null -ne $predictionCpu5Property -and $null -eq $predictionCpu5Property.Value)
        $maxTemperatureText = if ($null -eq $maxTemperatureProperty) { '<missing>' } else { ConvertTo-Json -InputObject $maxTemperatureProperty.Value -Compress }
        $predictionCpu5Text = if ($null -eq $predictionCpu5Property) { '<missing>' } else { ConvertTo-Json -InputObject $predictionCpu5Property.Value -Compress }
        if ($statusValue -eq 'ERROR') {
            throw "Bundled analysis worker returned ERROR: $($workerJson.error). Raw response: $workerResponse; stderr='$workerError'"
        }
        if ($statusValue -ne 'SENSOR_UNAVAILABLE' -or -not $maxTemperatureIsNull -or -not $predictionCpu5IsNull) {
            throw "Bundled analysis worker failed the no-fabricated-values smoke test. status='$statusValue'; maxTemperature=$maxTemperatureText; prediction.cpu5=$predictionCpu5Text; raw response=$workerResponse"
        }
        Write-Host 'Bundled analysis worker single-request and no-fabricated-values smoke tests passed.' -ForegroundColor Green
    }
    finally {
        $workerProcess.Dispose()
    }

    $AppProject = Join-Path $Root 'src\ThermoTrack.App\ThermoTrack.App.csproj'
    dotnet restore $AppProject
    if ($LASTEXITCODE -ne 0) { throw '.NET restore failed.' }
    dotnet publish $AppProject -c Release -r win-x64 --self-contained true -p:PublishSingleFile=false -p:IncludeNativeLibrariesForSelfExtract=true -o $Publish
    if ($LASTEXITCODE -ne 0) { throw '.NET publish failed.' }
    if (-not (Test-Path (Join-Path $Publish 'ThermoTrack.exe'))) { throw 'ThermoTrack.exe was not produced by dotnet publish.' }

    $AnalysisOut = Join-Path $Publish 'analysis'
    New-Item -ItemType Directory -Force $AnalysisOut | Out-Null
    Copy-Item $WorkerExe (Join-Path $AnalysisOut 'analysis_worker.exe') -Force
    $DashboardOut = Join-Path $Publish 'dashboard'
    New-Item -ItemType Directory -Force $DashboardOut | Out-Null
    Copy-Item (Join-Path $Root 'app-dashboard\index.html') (Join-Path $DashboardOut 'index.html') -Force

    $WebViewBootstrapper = Join-Path $Root 'build\MicrosoftEdgeWebView2Setup.exe'
    if (-not (Test-Path $WebViewBootstrapper)) {
        Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' -OutFile $WebViewBootstrapper
        if (-not (Test-Path $WebViewBootstrapper) -or (Get-Item $WebViewBootstrapper).Length -lt 100000) {
            throw 'The WebView2 Runtime bootstrapper could not be downloaded or appears incomplete.'
        }
    }
    Copy-Item $WebViewBootstrapper (Join-Path $Publish 'MicrosoftEdgeWebView2Setup.exe') -Force

    & $iss.Source (Join-Path $Root 'installer\ThermoTrack.iss')
    if ($LASTEXITCODE -ne 0) { throw 'Inno Setup reported a failure while compiling the installer.' }
    $Installer = Join-Path $InstallerDir 'ThermoTrack-Setup-x64.exe'
    if (-not (Test-Path $Installer) -or (Get-Item $Installer).Length -lt 1000000) {
        throw "Installer output missing or unexpectedly small: $Installer"
    }
    Write-Host "Build and automated tests completed. Installer: $Installer" -ForegroundColor Green
    Write-Host 'This script cannot certify sensor compatibility without running the installer on real Windows hardware.' -ForegroundColor Yellow
}
finally {
    Pop-Location
}
