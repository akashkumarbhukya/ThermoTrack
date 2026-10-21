param(
    [string]$RepositoryPath = "$env:USERPROFILE\Documents\Programming languages\math_lab\ThermoTrack_OneStep_GitHub_Fixed"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$SourceRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path.TrimEnd('\')
if (-not (Test-Path -LiteralPath $RepositoryPath)) { throw "Repository folder not found: $RepositoryPath" }
$RepositoryPath = (Resolve-Path -LiteralPath $RepositoryPath).Path.TrimEnd('\')
$SameFolder = $SourceRoot.Equals($RepositoryPath, [StringComparison]::OrdinalIgnoreCase)
$SourceWorker = Join-Path $SourceRoot 'CBP\ThermoTrack_Single_Application\analysis\analysis_worker.py'
$SourceBuild = Join-Path $SourceRoot 'CBP\ThermoTrack_Single_Application\build\build_windows.ps1'
$SourceTests = Join-Path $SourceRoot 'CBP\ThermoTrack_Single_Application\tests\test_analysis_worker.py'
$SourceWorkflow = Join-Path $SourceRoot '.github\workflows\build-windows.yml'
foreach ($required in @($SourceWorker, $SourceBuild, $SourceTests, $SourceWorkflow)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Required ThermoTrack source file missing: $required" }
}
if (-not (Test-Path -LiteralPath (Join-Path $RepositoryPath '.git'))) { throw "Target is not a Git checkout (.git missing): $RepositoryPath" }

# Validate the actual intended fix before staging anything.
$workerText = Get-Content -LiteralPath $SourceWorker -Raw
$buildText = Get-Content -LiteralPath $SourceBuild -Raw
$testText = Get-Content -LiteralPath $SourceTests -Raw
if ($workerText -notmatch 'if\s+not\s+line\.strip\(\)\s*:\s*\r?\n\s+continue') {
    throw 'Worker must ignore blank transport lines; source validation failed.'
}
if ($buildText -match "StandardInput\.WriteLine\(''\)") {
    throw 'Build smoke test still injects a synthetic blank line into the frozen EXE.'
}
if ($buildText -notmatch 'StandardInput\.WriteLine\(\$request\)' -or $buildText -notmatch 'responseLines\.Count\s+-ne\s+1') {
    throw 'Build smoke test must send one real request and require exactly one response.'
}
if ($testText -notmatch 'test_worker_ignores_blank_protocol_lines' -or $testText -notmatch 'test_frozen_windows_smoke_test_uses_single_nonblank_request') {
    throw 'Required protocol regression tests are missing.'
}

$remoteUrl = (& git -C $RepositoryPath remote get-url origin 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $remoteUrl -notmatch 'github\.com[:/]akashkumarbhukya/ThermoTrack(?:\.git)?$') {
    throw "Target origin is not the expected GitHub repository: $remoteUrl"
}
$currentBranch = (& git -C $RepositoryPath branch --show-current 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $currentBranch -ne 'main') { throw "Expected branch main, got '$currentBranch'. No files were committed." }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = "backup-before-thermotrack-build-fix-$stamp"
& git -C $RepositoryPath branch $backup HEAD
if ($LASTEXITCODE -ne 0) { throw 'Could not create a backup branch.' }
Write-Host "Safety backup branch: $backup" -ForegroundColor Green

& git -C $RepositoryPath fetch origin
if ($LASTEXITCODE -ne 0) { throw 'git fetch failed.' }
$head = (& git -C $RepositoryPath rev-parse HEAD).Trim()
$originHead = (& git -C $RepositoryPath rev-parse origin/main).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect commit IDs.' }

if ($SameFolder) {
    # Files were already extracted/copied into the Git checkout. Do NOT stash or reset them.
    if ($head -ne $originHead) {
        throw "Local main ($head) differs from origin/main ($originHead). Files were not committed or pushed. Preserve the changes and reconcile the branch first."
    }
    Write-Host 'Package is already extracted into the Git checkout; leaving all files in place.' -ForegroundColor Yellow
} else {
    if ($SourceRoot.StartsWith($RepositoryPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Extract the package outside the repository or directly into the repository root; a nested package folder is not supported.'
    }
    $status = @(& git -C $RepositoryPath status --porcelain 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect Git status.' }
    if ($status.Count -gt 0) {
        & git -C $RepositoryPath stash push --include-untracked -m "Preserved before ThermoTrack build fix $stamp"
        if ($LASTEXITCODE -ne 0) { throw 'Could not preserve existing local changes.' }
    }
    & git -C $RepositoryPath switch -C main origin/main
    if ($LASTEXITCODE -ne 0) { throw 'Could not align target main to origin/main.' }
    & robocopy $SourceRoot $RepositoryPath /E /COPY:DAT /R:2 /W:1 /NFL /NDL /NJH /NJS /NP /XD .git __pycache__ .pytest_cache .venv venv node_modules bin obj worker-build worker-dist publish dist /XF *.pyc /XJ
    $copyResult = $LASTEXITCODE
    if ($copyResult -ge 8) { throw "File copy failed (robocopy $copyResult)." }
    Write-Host 'Corrected package copied; .git metadata was excluded.' -ForegroundColor Green
}

# Verify the files at their final location.
$targetBuild = Join-Path $RepositoryPath 'CBP\ThermoTrack_Single_Application\build\build_windows.ps1'
$targetTests = Join-Path $RepositoryPath 'CBP\ThermoTrack_Single_Application\tests\test_analysis_worker.py'
$targetWorker = Join-Path $RepositoryPath 'CBP\ThermoTrack_Single_Application\analysis\analysis_worker.py'
if (-not (Test-Path $targetBuild) -or -not (Test-Path $targetTests) -or -not (Test-Path $targetWorker)) { throw 'Post-copy verification failed: expected worker/build/tests are missing.' }
$targetBuildText = Get-Content $targetBuild -Raw
$targetTestsText = Get-Content $targetTests -Raw
if ($targetBuildText -match "StandardInput\.WriteLine\(''\)" -or
    $targetBuildText -notmatch 'StandardInput\.WriteLine\(\$request\)' -or
    $targetTestsText -notmatch 'test_frozen_windows_smoke_test_uses_single_nonblank_request') {
    throw 'Post-copy verification failed. Nothing was committed.'
}
Write-Host 'Verified: frozen EXE smoke test sends one real request; source tests retain blank-line coverage.' -ForegroundColor Green

# Stage only files belonging to this targeted correction. No unrelated user files are included.
$paths = @(
  'CBP/ThermoTrack_Single_Application/build/build_windows.ps1',
  'CBP/ThermoTrack_Single_Application/tests/test_analysis_worker.py',
  'APPLY_THERMOTRACK_FIXES.ps1',
  'THERMOTRACK_FIX_REPORT.md'
)
& git -C $RepositoryPath add -- @paths
if ($LASTEXITCODE -ne 0) { throw 'Git add failed.' }
& git -C $RepositoryPath diff --cached --check
if ($LASTEXITCODE -ne 0) { throw 'Staged changes failed git diff --check.' }
& git -C $RepositoryPath diff --cached --quiet
$diff = $LASTEXITCODE
if ($diff -eq 0) {
    Write-Host 'No targeted changes detected. No commit or push was performed.' -ForegroundColor Yellow
    exit 0
}
if ($diff -ne 1) { throw 'Could not inspect staged changes.' }

# Do not invoke the user's global Python from this updater. It can be Python 3.14
# without the build dependencies, and PowerShell 5.1 promotes its import traceback to
# NativeCommandError under $ErrorActionPreference='Stop'. Source regression tests passed
# in the package validation environment; GitHub Actions installs the declared build deps
# and is the authoritative Windows build/test run.
Write-Host 'Updater source checks passed. GitHub Actions will run the pinned Python tests and Windows EXE smoke test.' -ForegroundColor Green

& git -C $RepositoryPath commit -m 'Fix frozen worker smoke test protocol'
if ($LASTEXITCODE -ne 0) { throw 'Commit failed; backup branch remains available.' }
& git -C $RepositoryPath push origin main
if ($LASTEXITCODE -ne 0) { throw 'Push failed. No force-push was attempted; backup branch remains available.' }
Write-Host 'Push completed. Check the new Windows build workflow.' -ForegroundColor Green
Write-Host 'https://github.com/akashkumarbhukya/ThermoTrack/actions'
Write-Host 'A passing CI run confirms build validation, not physical-sensor compatibility.' -ForegroundColor Yellow
