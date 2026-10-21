param(
    [string]$RepositoryPath = "$env:USERPROFILE\Documents\Programming languages\math_lab\ThermoTrack_OneStep_GitHub_Fixed"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$SourceRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path.TrimEnd('\')
if (-not (Test-Path -LiteralPath (Join-Path $SourceRoot '.github\workflows\build-windows.yml')) -or
    -not (Test-Path -LiteralPath (Join-Path $SourceRoot 'CBP\ThermoTrack_Single_Application\analysis\analysis_worker.py')) -or
    -not (Test-Path -LiteralPath (Join-Path $SourceRoot 'CBP\ThermoTrack_Single_Application\build\build_windows.ps1'))) {
    throw "This folder is not the corrected ThermoTrack source package: $SourceRoot"
}

if (-not (Test-Path -LiteralPath $RepositoryPath)) {
    throw "Existing repository folder not found: $RepositoryPath`nExtract this ZIP to a separate folder first. You can pass -RepositoryPath with your local repository path."
}
$RepositoryPath = (Resolve-Path -LiteralPath $RepositoryPath).Path.TrimEnd('\')
if (-not (Test-Path -LiteralPath (Join-Path $RepositoryPath '.git'))) {
    throw "The target folder is not a Git checkout (.git is missing): $RepositoryPath"
}
if ($SourceRoot.Equals($RepositoryPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw "The source package and Git checkout are the same folder. Extract the ZIP into Downloads first, then run this script from the extracted package."
}
if ($SourceRoot.StartsWith($RepositoryPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "The source package is inside the Git checkout. Extract it outside the repository (for example, Downloads) before running this script."
}

$remoteUrl = (& git -C $RepositoryPath remote get-url origin 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $remoteUrl -notmatch 'github\.com[:/]akashkumarbhukya/ThermoTrack(?:\.git)?$') {
    throw "The target repository's origin is not the expected ThermoTrack GitHub repository.`nFound: $remoteUrl"
}

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    & git -C $RepositoryPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE. No force-push or reset was attempted."
    }
}

$currentBranch = (& git -C $RepositoryPath branch --show-current | Out-String).Trim()
if ($currentBranch -ne 'main') {
    throw "The target checkout is on branch '$currentBranch', not 'main'. Switch this checkout to main and run the helper again. No files were copied."
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupBranch = "backup-before-thermotrack-fix-$stamp"
Invoke-Git @('branch', $backupBranch, 'HEAD')
Write-Host "Safety backup branch created: $backupBranch" -ForegroundColor Green

# Preserve any edits and commits before syncing main to the current GitHub main.
$statusLines = @(& git -C $RepositoryPath status --porcelain)
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect local Git status.' }
if ($statusLines.Count -gt 0) {
    Invoke-Git @('stash', 'push', '--include-untracked', '-m', "Preserved before ThermoTrack source update $stamp")
    Write-Host 'Previous local uncommitted changes are preserved in Git stash.' -ForegroundColor Yellow
}

Invoke-Git @('fetch', 'origin')
# We already created a backup branch and preserved any dirty files, so align local
# main to GitHub main without a potentially conflicting rebase. No force-push occurs.
Invoke-Git @('switch', '-C', 'main', 'origin/main')

# Overlay the full corrected source tree, never copying Git metadata, caches, or build outputs.
$robocopyArgs = @(
    $SourceRoot, $RepositoryPath,
    '/E', '/COPY:DAT', '/R:2', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP',
    '/XD', '.git', '__pycache__', '.pytest_cache', '.venv', 'venv', 'node_modules', 'bin', 'obj', 'worker-build', 'worker-dist',
    '/XF', '*.pyc',
    '/XJ'
)
& robocopy @robocopyArgs
$copyExit = $LASTEXITCODE
if ($copyExit -ge 8) { throw "Copying corrected files failed (robocopy exit code $copyExit)." }
Write-Host 'Corrected source files copied. Existing .git metadata was preserved.' -ForegroundColor Green

# If this computer already has the worker's test dependencies, run the analysis suite locally.
# Otherwise let the GitHub Windows workflow install dependencies and perform the full CI validation.
$python = Get-Command python -ErrorAction SilentlyContinue
if ($python) {
    & python -c 'import numpy, scipy, pytest' 2>$null
    if ($LASTEXITCODE -eq 0) {
        & python -m pytest (Join-Path $RepositoryPath 'CBP\ThermoTrack_Single_Application\tests') -q
        if ($LASTEXITCODE -ne 0) { throw 'Local analysis tests failed. Source is copied, but no commit or push was made.' }
        Write-Host 'Local analysis tests passed.' -ForegroundColor Green
    } else {
        Write-Host 'Local test dependencies are not installed; GitHub Actions will run the full tests.' -ForegroundColor Yellow
    }
} else {
    Write-Host 'Python was not found locally; GitHub Actions will run the full tests.' -ForegroundColor Yellow
}

Invoke-Git @('add', '-A')
& git -C $RepositoryPath diff --cached --quiet
$diffExit = $LASTEXITCODE
if ($diffExit -eq 0) {
    Write-Host 'No new source changes to commit. The checkout already matches this package.' -ForegroundColor Yellow
    exit 0
}
if ($diffExit -ne 1) { throw 'Could not inspect staged changes.' }

Invoke-Git @('commit', '-m', 'Fix analysis worker blank-line protocol and forecast alert validation')
Invoke-Git @('push', 'origin', 'main')
Write-Host ''
Write-Host 'SOURCE PUSHED. Open the Actions page and wait for the newest workflow to finish.' -ForegroundColor Green
Write-Host 'https://github.com/akashkumarbhukya/ThermoTrack/actions'
Write-Host 'A green build verifies compilation/tests; live sensor readings still require checking on the actual PC.' -ForegroundColor Yellow
