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

    # Smoke-test the frozen worker itself, not just the unfrozen Python module.
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
        $request = '{"history":[{"timestamp":"2026-01-01T00:00:00.000","cpu_temp":null,"gpu_temp":null,"ssd_temp":null,"ram_load":42}]}'
        $workerProcess.StandardInput.WriteLine($request)
        $workerProcess.StandardInput.Close()
        $readLine = $workerProcess.StandardOutput.ReadLineAsync()
        if (-not $workerProcess.WaitForExit(30000)) {
            $workerProcess.Kill($true)
            throw 'The bundled analysis worker did not respond within 30 seconds.'
        }
        $workerResponse = $readLine.GetAwaiter().GetResult()
        if ($workerProcess.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($workerResponse)) {
            $workerError = $workerProcess.StandardError.ReadToEnd()
            throw "Bundled analysis worker smoke test failed. Exit code: $($workerProcess.ExitCode). $workerError"
        }
        try {
            $workerJson = $workerResponse | ConvertFrom-Json
        }
        catch {
            throw "Bundled analysis worker returned invalid JSON. Raw response: $workerResponse. Parse error: $($_.Exception.Message)"
        }

        # Validate both the semantic result and that the important fields exist.
        # Include returned values in the failure message so future CI failures are diagnosable.
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

        if ($statusValue -ne 'SENSOR_UNAVAILABLE' -or -not $maxTemperatureIsNull -or -not $predictionCpu5IsNull) {
            throw "Bundled analysis worker failed the no-fabricated-values smoke test. status='$statusValue'; maxTemperature=$maxTemperatureText; prediction.cpu5=$predictionCpu5Text; raw response=$workerResponse"
        }
        Write-Host 'Bundled analysis worker no-fabricated-values smoke test passed.' -ForegroundColor Green
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
