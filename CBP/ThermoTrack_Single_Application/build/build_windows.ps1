$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Python = Get-Command python -ErrorAction SilentlyContinue
if (-not $Python) { throw 'Python 3.11 x64 is required on the BUILD machine only. Install it, then rerun this script.' }
$Dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if (-not $Dotnet) { throw '.NET 8 SDK is required on the BUILD machine only.' }
$iss = Get-Command ISCC.exe -ErrorAction SilentlyContinue
if (-not $iss) {
  $candidate = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
  if (-not (Test-Path $candidate)) { $candidate = Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe' }
  if (Test-Path $candidate) { $iss = [pscustomobject]@{ Source = $candidate } } else { throw 'Inno Setup 6 is required on the BUILD machine only.' }
}
$BuildDir = Join-Path $Root 'build\worker-build'
$DistDir = Join-Path $Root 'build\worker-dist'
$Publish = Join-Path $Root 'publish'
Remove-Item $BuildDir,$DistDir,$Publish -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $BuildDir,$DistDir,$Publish | Out-Null
python -m pip install --upgrade pip
python -m pip install -r (Join-Path $Root 'requirements-build.txt')
python -m pytest (Join-Path $Root 'tests') -q
python -m PyInstaller --clean --noconfirm --onefile --console --name analysis_worker --distpath $DistDir --workpath $BuildDir (Join-Path $Root 'analysis\analysis_worker.py')
$AppProject = Join-Path $Root 'src\ThermoTrack.App\ThermoTrack.App.csproj'
dotnet publish $AppProject -c Release -r win-x64 --self-contained true -p:PublishSingleFile=false -p:IncludeNativeLibrariesForSelfExtract=true -o $Publish
$AnalysisOut = Join-Path $Publish 'analysis'
New-Item -ItemType Directory -Force $AnalysisOut | Out-Null
Copy-Item (Join-Path $DistDir 'analysis_worker.exe') (Join-Path $AnalysisOut 'analysis_worker.exe')
$DashboardOut = Join-Path $Publish 'dashboard'
New-Item -ItemType Directory -Force $DashboardOut | Out-Null
Copy-Item (Join-Path $Root 'app-dashboard\index.html') (Join-Path $DashboardOut 'index.html') -Force
$WebViewBootstrapper = Join-Path $Root 'build\MicrosoftEdgeWebView2Setup.exe'
if (-not (Test-Path $WebViewBootstrapper)) {
  Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' -OutFile $WebViewBootstrapper
}
Copy-Item $WebViewBootstrapper (Join-Path $Publish 'MicrosoftEdgeWebView2Setup.exe') -Force
$InstallerDir = Join-Path $Root 'dist'
New-Item -ItemType Directory -Force $InstallerDir | Out-Null
& $iss.Source (Join-Path $Root 'installer\ThermoTrack.iss')
Write-Host "Build complete: $InstallerDir\ThermoTrack-Setup-x64.exe"
