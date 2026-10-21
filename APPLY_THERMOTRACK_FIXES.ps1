param(
    [string]$RepositoryPath = "$env:USERPROFILE\Documents\Programming languages\math_lab\ThermoTrack_OneStep_GitHub_Fixed"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# PowerShell 7 can promote a native program's non-zero exit/stderr into a
# terminating NativeCommandError before its exit code is handled. Git/robocopy
# are checked explicitly below, so disable that promotion when the variable exists.
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$SourceRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path.TrimEnd('\')
$SourceWorker = Join-Path $SourceRoot 'CBP\ThermoTrack_Single_Application\analysis\analysis_worker.py'
$SourceBuild = Join-Path $SourceRoot 'CBP\ThermoTrack_Single_Application\build\build_windows.ps1'
$SourceTests = Join-Path $SourceRoot 'CBP\ThermoTrack_Single_Application\tests\test_analysis_worker.py'
if (-not (Test-Path -LiteralPath (Join-Path $SourceRoot '.github\workflows\build-windows.yml')) -or
    -not (Test-Path -LiteralPath $SourceWorker) -or
    -not (Test-Path -LiteralPath $SourceBuild) -or
    -not (Test-Path -LiteralPath $SourceTests)) {
    throw "This folder is not the complete corrected ThermoTrack source package: $SourceRoot"
}

# Refuse to apply a package unless it contains the specific regression fix.
$sourceWorkerText = Get-Content -LiteralPath $SourceWorker -Raw
$sourceBuildText = Get-Content -LiteralPath $SourceBuild -Raw
$sourceTestsText = Get-Content -LiteralPath $SourceTests -Raw
if ($sourceWorkerText -notmatch 'if\s+not\s+line\.strip\(\)\s*:\s*\r?\n\s+continue') {
    throw 'Safety check failed: source worker does not ignore blank input lines.'
}
if ($sourceBuildText -notmatch 'responseLines\.Count\s+-ne\s+1' -or $sourceBuildText -notmatch "WriteLine\(''\)") {
    throw 'Safety check failed: Windows build smoke test does not verify the blank-line protocol.'
}
if ($sourceTestsText -notmatch 'test_worker_ignores_blank_protocol_lines') {
    throw 'Safety check failed: blank-line regression test is missing.'
}

if (-not (Test-Path -LiteralPath $RepositoryPath)) {
    throw "Existing repository folder not found: $RepositoryPath`nExtract this ZIP into a separate folder first, then run APPLY_THERMOTRACK_FIXES.cmd."
}
$RepositoryPath = (Resolve-Path -LiteralPath $RepositoryPath).Path.TrimEnd('\')
if (-not (Test-Path -LiteralPath (Join-Path $RepositoryPath '.git'))) {
    throw "Target folder is not a Git checkout (.git is missing): $RepositoryPath"
}
if ($SourceRoot.Equals($RepositoryPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The source package and Git checkout are the same folder. Extract this package separately first.'
}
if ($SourceRoot.StartsWith($RepositoryPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The source package is inside the Git checkout. Extract it to Downloads or another separate folder first.'
}

$remoteUrl = (& git -C $RepositoryPath remote get-url origin 2>&1 | Out-String).Trim()
$remoteExit = $LASTEXITCODE
if ($remoteExit -ne 0 -or $remoteUrl -notmatch 'github\.com[:/]akashkumarbhukya/ThermoTrack(?:\.git)?$') {
    throw "Target origin is not the expected ThermoTrack GitHub repository.`nFound: $remoteUrl"
}

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    & git -C $RepositoryPath @Arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $exitCode. No force-push or reset was attempted."
    }
}

$currentBranch = (& git -C $RepositoryPath branch --show-current 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Could not identify the active Git branch.' }
if ($currentBranch -ne 'main') {
    throw "Target checkout is on '$currentBranch', not 'main'. No files were copied. Open the correct repository folder and rerun."
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
Invoke-Git @('branch', "backup-before-thermotrack-fix-$stamp", 'HEAD')
Write-Host "Safety backup branch created: backup-before-thermotrack-fix-$stamp" -ForegroundColor Green

$statusLines = @(& git -C $RepositoryPath status --porcelain 2>&1)
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect Git status.' }
if ($statusLines.Count -gt 0) {
    Invoke-Git @('stash', 'push', '--include-untracked', '-m', "Preserved before ThermoTrack source update $stamp")
    Write-Host 'Previous uncommitted changes preserved in Git stash; previous commit preserved on the backup branch.' -ForegroundColor Yellow
}

Invoke-Git @('fetch', 'origin')
Invoke-Git @('switch', '-C', 'main', 'origin/main')

# Copy the validated package, explicitly excluding Git metadata, caches and build outputs.
$robocopyArgs = @(
    $SourceRoot, $RepositoryPath,
    '/E', '/COPY:DAT', '/R:2', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP',
    '/XD', '.git', '__pycache__', '.pytest_cache', '.venv', 'venv', 'node_modules', 'bin', 'obj', 'worker-build', 'worker-dist', 'publish', 'dist',
    '/XF', '*.pyc',
    '/XJ'
)
& robocopy @robocopyArgs
$copyExit = $LASTEXITCODE
if ($copyExit -ge 8) { throw "Copy failed (robocopy exit code $copyExit)." }
Write-Host 'Corrected source copied; the target .git metadata was not copied or overwritten.' -ForegroundColor Green

# Verify the exact files in the Git checkout—not merely the downloaded package.
$targetWorker = Join-Path $RepositoryPath 'CBP\ThermoTrack_Single_Application\analysis\analysis_worker.py'
$targetBuild = Join-Path $RepositoryPath 'CBP\ThermoTrack_Single_Application\build\build_windows.ps1'
$targetTests = Join-Path $RepositoryPath 'CBP\ThermoTrack_Single_Application\tests\test_analysis_worker.py'
$targetWorkerText = Get-Content -LiteralPath $targetWorker -Raw
$targetBuildText = Get-Content -LiteralPath $targetBuild -Raw
$targetTestsText = Get-Content -LiteralPath $targetTests -Raw
if ($targetWorkerText -notmatch 'if\s+not\s+line\.strip\(\)\s*:\s*\r?\n\s+continue' -or
    $targetBuildText -notmatch 'responseLines\.Count\s+-ne\s+1' -or
    $targetTestsText -notmatch 'test_worker_ignores_blank_protocol_lines') {
    throw 'Post-copy verification failed: the Git checkout does not contain all three worker protocol fixes. Nothing has been committed or pushed.'
}
Write-Host 'Verified target worker, build smoke test, and regression test.' -ForegroundColor Green

# Do not probe globally installed Python packages here: that previously stopped the updater
# in PowerShell before the source could be committed. GitHub Actions installs pinned build deps
# and is the authoritative test/build environment.
Invoke-Git @('add', '-A')
& git -C $RepositoryPath diff --cached --check
if ($LASTEXITCODE -ne 0) { throw 'Whitespace/conflict-marker validation failed; no commit was made.' }
& git -C $RepositoryPath diff --cached --quiet
$diffExit = $LASTEXITCODE
if ($diffExit -eq 0) {
    Write-Host 'No new changes detected. The remote main already contains these exact files.' -ForegroundColor Yellow
    exit 0
}
if ($diffExit -ne 1) { throw 'Could not inspect staged changes.' }

Invoke-Git @('commit', '-m', 'Fix bundled worker blank-line JSON protocol')
Invoke-Git @('push', 'origin', 'main')
Write-Host ''
Write-Host 'PUSH SUCCEEDED. GitHub Actions should now run the Windows build.' -ForegroundColor Green
Write-Host 'https://github.com/akashkumarbhukya/ThermoTrack/actions'
Write-Host 'A green workflow confirms the Windows package/build checks; real sensor access still needs hardware testing.' -ForegroundColor Yellow
