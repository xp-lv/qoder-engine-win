<#
.SYNOPSIS
    COMSOL Server startup helper script (pipeline maintenance H031-P0).
.DESCRIPTION
    The inverse-scattering spec (Section 5) requires the COMSOL Server to run
    long-term on port 2036 in a dedicated terminal. H029/H030/H031 all found
    the Server NOT running on first check, wasting ~20-25s each time.

    H031 also discovered a NEW bug (P0): this script failed to parse on Windows
    because it contained Chinese characters saved as UTF-8 (no BOM). Windows
    PowerShell defaults to GBK codepage and mis-parses multi-byte UTF-8 Chinese
    sequences, causing errors like "missing } in statement block" and
    "array index expression missing or invalid".

    FIX (H031-P0): the entire script is now pure ASCII (English messages only),
    making it immune to all codepage/encoding issues regardless of locale.

    Usage:
    1. Run in a dedicated terminal:
       powershell -ExecutionPolicy Bypass -File start_comsol_server.ps1
    2. If already running -> skip; if not -> start in background and wait for port.
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
    if (Test-Path $candidate) {
        $ComsolExe = $candidate
        break
    }
}

if (-not $ComsolExe) {
    Write-Host "[ERROR] comsolmphserver.exe not found." -ForegroundColor Red
    Write-Host "        None of the probed paths exist. Please specify -ComsolExe or edit the candidate list." -ForegroundColor Yellow
    Write-Host "        Example: D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\bin\win64\comsolmphserver.exe" -ForegroundColor Yellow
    exit 1
}

# --- Check if Server is already running ---
Write-Host "[CHECK] Probing localhost:$Port ..." -ForegroundColor Cyan
$connection = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($connection) {
    $pidVal = ($connection.OwningProcess | Select-Object -First 1)
    Write-Host "[OK] COMSOL Server already running on localhost:$Port (PID=$pidVal), no need to start again." -ForegroundColor Green
    exit 0
}
Write-Host "[INFO] Port $Port has no listener, preparing to start COMSOL Server ..." -ForegroundColor Yellow

# --- Ensure tmpdir exists ---
if (-not (Test-Path $TmpDir)) {
    Write-Host "[SETUP] Creating temp directory: $TmpDir" -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $TmpDir -Force | Out-Null
}

# --- Start COMSOL Server (background process, long-term in dedicated terminal) ---
Write-Host "[START] $ComsolExe -port $Port -tmpdir $TmpDir" -ForegroundColor Cyan
$processArgs = @("-port", $Port, "-tmpdir", $TmpDir)
$process = Start-Process -FilePath $ComsolExe -ArgumentList $processArgs -PassThru -WindowStyle Normal
Write-Host "[STARTED] COMSOL Server PID=$($process.Id)" -ForegroundColor Green

# --- Wait for port ready (up to 30s) ---
Write-Host "[WAIT] Waiting for port $Port to be ready ..." -ForegroundColor Cyan
$maxWait = 30
$waited = 0
while ($waited -lt $maxWait) {
    Start-Sleep -Seconds 1
    $waited++
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($conn) {
        Write-Host "[READY] COMSOL Server is ready (localhost:$Port, waited ${waited}s)." -ForegroundColor Green
        Write-Host ""
        Write-Host "  Now in MATLAB you can run:" -ForegroundColor White
        Write-Host "    cd('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\pipline')" -ForegroundColor White
        Write-Host "    addpath('config','experiment')" -ForegroundColor White
        Write-Host "    state = run_experiment('plugin_c01');" -ForegroundColor White
        Write-Host ""
        Write-Host "  NOTE: Keep this terminal open. Closing it will disconnect MATLAB." -ForegroundColor Yellow
        exit 0
    }
}
Write-Host "[TIMEOUT] Port $Port not ready within ${maxWait}s. Check COMSOL logs or license." -ForegroundColor Red
exit 1
