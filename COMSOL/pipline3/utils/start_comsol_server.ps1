<#
.SYNOPSIS
    COMSOL Server unified startup helper for gen1_comsol_adjoint pipeline.
    (pipeline maintenance H033-P0,固化 by 管线维护者)

.DESCRIPTION
    H029/H030/H031/H032/H033 all hit the SAME recurring failure: mphstart(2036)
    reports "Connection refused" on first check, wasting 1-3 min each time.

    ROOT CAUSE (P0): COMSOL mphserver port-binding semantics. When the requested
    port (-port 2036) is occupied, the server does NOT error out -- it silently
    auto-increments (2036 -> 2037 -> 2038) to find a free port. Stale "zombie"
    servers keep listening on the offset ports while the config still references
    2036, so MATLAB mphstart(2036) always fails.

    This launcher fixes all three sub-issues raised in the H033 optimization note:
      P0#1  Port-availability validation after start + port-offset detection.
      P0#2  Pre-start cleanup of stale comsolmphserver processes (zombies).
      P0#3  A single unified launcher the experiment executor / algorithm
            implementer can call instead of starting the server by hand.

    SAFETY: if port 2036 is ALREADY listening, the script reuses it and exits 0
    without touching any process (so an in-use MATLAB connection is never killed).
    Zombie cleanup ONLY runs when the target port has no listener.

    ASCII-only on purpose (immune to GBK/UTF-8 codepage issues, per H031 lesson).

.USAGE
    Dedicated terminal (keep it open -- closing it disconnects MATLAB):
        powershell -ExecutionPolicy Bypass -File start_comsol_server.ps1
    Custom port / tmpdir:
        powershell -ExecutionPolicy Bypass -File start_comsol_server.ps1 -Port 2036 -TmpDir D:\comsol_tmp
#>

param(
    [int]$Port = 2036,
    [string]$TmpDir = "D:\comsol_tmp"
)

$ErrorActionPreference = "Stop"

# --- COMSOL install path (probe common locations by priority) ---
$ComsolCandidates = @(
    "D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\bin\win64\comsolmphserver.exe",
    "C:\Program Files\COMSOL62\Multiphysics\bin\win64\comsolmphserver.exe",
    "C:\Program Files\COMSOL Multiphysics 6.2\bin\win64\comsolmphserver.exe"
)
$ComsolExe = $null
foreach ($candidate in $ComsolCandidates) {
    if (Test-Path $candidate) { $ComsolExe = $candidate; break }
}
if (-not $ComsolExe) {
    Write-Host "[ERROR] comsolmphserver.exe not found in any probed path." -ForegroundColor Red
    Write-Host "        Edit the candidate list or pass -ComsolExe." -ForegroundColor Yellow
    exit 1
}

# --- Step 1: is the target port already listening? Reuse if so. ---
Write-Host "[CHECK] Probing localhost:$Port ..." -ForegroundColor Cyan
$alive = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($alive) {
    $pidVal = ($alive.OwningProcess | Select-Object -First 1)
    Write-Host "[OK] COMSOL Server already running on localhost:$Port (PID=$pidVal). Reusing, nothing to do." -ForegroundColor Green
    exit 0
}

# --- Step 2 (P0#2): port has no listener -> clean up zombie comsolmphserver processes ---
# These are stale servers that auto-offset to 2037/2038; killing them frees the
# target port so the fresh start actually binds to $Port instead of offsetting again.
$zombies = Get-Process comsolmphserver -ErrorAction SilentlyContinue
if ($zombies) {
    Write-Host "[CLEAN] Target port $Port not listening. Killing $($zombies.Count) stale comsolmphserver process(es) (zombie offset artifacts) ..." -ForegroundColor Yellow
    $zombies | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
} else {
    Write-Host "[INFO] No stale comsolmphserver process found; port $Port is free." -ForegroundColor Yellow
}

# --- Step 3: ensure tmpdir exists ---
if (-not (Test-Path $TmpDir)) {
    Write-Host "[SETUP] Creating temp directory: $TmpDir" -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $TmpDir -Force | Out-Null
}

# --- Step 4 (P0#3): start fresh COMSOL Server on the target port ---
Write-Host "[START] $ComsolExe -port $Port -tmpdir $TmpDir" -ForegroundColor Cyan
$process = Start-Process -FilePath $ComsolExe -ArgumentList @("-port", $Port, "-tmpdir", $TmpDir) -PassThru -WindowStyle Normal
Write-Host "[STARTED] COMSOL Server PID=$($process.Id)" -ForegroundColor Green

# --- Step 5 (P0#1): wait for the TARGET port to be listening; detect offset if it never binds ---
Write-Host "[WAIT] Waiting for port $Port to be ready (max 30s) ..." -ForegroundColor Cyan
$maxWait = 30
$waited = 0
while ($waited -lt $maxWait) {
    Start-Sleep -Seconds 1
    $waited++
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($conn) {
        Write-Host "[READY] COMSOL Server ready on localhost:$Port (waited ${waited}s)." -ForegroundColor Green
        Write-Host ""
        Write-Host "  Now in MATLAB (gen1_comsol_adjoint):" -ForegroundColor White
        Write-Host "    cd('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\pipline_adjoint')" -ForegroundColor White
        Write-Host "    addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint','experiment')" -ForegroundColor White
        Write-Host "    addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli')" -ForegroundColor White
        Write-Host "    run_inversion_complex();" -ForegroundColor White
        Write-Host ""
        Write-Host "  NOTE: Keep this terminal open. Closing it disconnects MATLAB." -ForegroundColor Yellow
        exit 0
    }
}

# --- Timeout: the server may have offset to another port. Diagnose. ---
Write-Host "[TIMEOUT] Port $Port not listening within ${maxWait}s." -ForegroundColor Red
$offset = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
    Where-Object { $_.OwningProcess -eq $process.Id }
if ($offset) {
    $offPort = ($offset | Select-Object -First 1).LocalPort
    Write-Host "[DIAG] The server process (PID=$($process.Id)) is listening on $offPort, NOT $Port." -ForegroundColor Yellow
    Write-Host "       This is the port-offset bug. It should not happen after zombie cleanup." -ForegroundColor Yellow
    Write-Host "       Workaround: re-run this script (it will clean up and restart on $Port)." -ForegroundColor Yellow
}
exit 1
