<#
.SYNOPSIS
    Canonical MATLAB -batch launcher with reliable stdout capture + silent-fail guard.
    (pipeline maintenance H036-P0, created by pipeline maintainer for gen1_comsol_adjoint)

.DESCRIPTION
    H035 (gen1_comsol_adjoint) discovered that Start-Process -RedirectStandardOutput
    FAILS to capture MATLAB -batch stdout in this environment: the process exits in
    ~25s with exit code 0 but stdout.log contains only the marker line (~57 bytes)
    and MATLAB application output is swallowed (0 bytes). The .mat output file is
    not updated either, making the failure indistinguishable from a successful
    empty run.

    ROOT CAUSE (P0): Start-Process stdout redirection is unreliable for MATLAB
    -batch console subprocesses (output buffering / handle inheritance issue
    in this Windows + PowerShell environment).

    H036 RECURRENCE ROOT CAUSE: H035 created this launcher only in gen1_comsol
    (pipline), NOT in gen1_comsol_adjoint (pipline_adjoint). H036 ran on
    pipline_adjoint which had NO launcher -- the executor fell back to
    Start-Process -Redirect and hit the same silent-fail. This copy fills
    that gap.

    FIX:
      1. Use a generated .bat wrapper with native cmd.exe redirection
         (> log 2>&1) instead of Start-Process -RedirectStandardOutput.
         This reliably captures ALL MATLAB application stdout/stderr.
      2. After MATLAB exits, validate the output file mtime. If MATLAB
         returned exit 0 but the output file was NOT updated (still shows an
         old timestamp or does not exist), flag SILENT-FAIL instead of
         treating it as success.

    ALTERNATIVE: A standalone .bat launcher (run_matlab_batch.bat) is also
    available in this directory. It provides the same fix but is callable
    from any shell type (PowerShell runs .bat via cmd.exe implicitly).
    Prefer the .bat when the terminal cannot call cmd.exe /c directly.

    MAINTENANCE HISTORY:
      H035-P0 : Created canonical launcher in gen1_comsol (pipline).
      H036-P0 : Copied to gen1_comsol_adjoint (pipline_adjoint) to fill the
                gap that caused H036 P0 recurrence. Also created .bat variant.

    ASCII-only on purpose (immune to GBK/UTF-8 codepage issues, per H031 lesson).

.USAGE
    powershell -ExecutionPolicy Bypass -File run_matlab_batch.ps1 `
        -BatchCommand "addpath('config','experiment'); state = run_inversion_complex(); save('out.mat','state','-v7.3');" `
        -LogFile "D:\path\to\stdout.log" `
        -WorkDir "d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\pipline_adjoint" `
        -OutputFile "D:\path\to\out.mat"

    Exit codes:
      0  = success (MATLAB exit 0, log captured, output file updated)
      1  = MATLAB returned non-zero exit code OR log not created
      2  = silent fail (MATLAB exit 0 but output file NOT updated / too small)
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$BatchCommand,

    [Parameter(Mandatory=$true)]
    [string]$LogFile,

    [string]$WorkDir = (Get-Location).Path,

    [string]$OutputFile = "",

    [string]$MatlabExe = "D:\LenovoSoftstore\Install\MATLAB\bin\matlab.exe"
)

$ErrorActionPreference = "Stop"

# --- Resolve paths to absolute ---
if (-not [System.IO.Path]::IsPathRooted($WorkDir)) {
    $WorkDir = (Resolve-Path $WorkDir).Path
}
if (-not [System.IO.Path]::IsPathRooted($LogFile)) {
    $LogFile = Join-Path $WorkDir $LogFile
}

# --- Record output file mtime BEFORE launch (for silent-fail detection) ---
$preMtime = $null
if ($OutputFile -and (Test-Path $OutputFile)) {
    $preMtime = (Get-Item $OutputFile).LastWriteTime
    Write-Host "[GUARD] Output file exists, pre-mtime = $preMtime" -ForegroundColor DarkGray
}

# --- Clear stale log ---
if (Test-Path $LogFile) { Remove-Item $LogFile -Force }

# --- Build a temporary .bat wrapper with native cmd.exe redirection ---
# This avoids Start-Process -RedirectStandardOutput (which silently swallows
# MATLAB -batch stdout in this environment) and avoids nested-quote hell.
$batFile = Join-Path $env:TEMP ("run_matlab_" + (Get-Random) + ".bat")
$batContent = @"
@echo off
cd /d "$WorkDir"
"$MatlabExe" -batch "$BatchCommand" > "$LogFile" 2>&1
exit /b %ERRORLEVEL%
"@
$batContent | Out-File -FilePath $batFile -Encoding ascii -Force

Write-Host "[LAUNCH] MATLAB -batch via .bat wrapper (cmd.exe full-stream redirect)" -ForegroundColor Cyan
Write-Host "  workdir:  $WorkDir"
Write-Host "  log:      $LogFile"
if ($OutputFile) { Write-Host "  output:   $OutputFile (mtime guard enabled)" }
Write-Host "  start:    $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

# --- Execute the .bat wrapper synchronously ---
$proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "`"$batFile`"" -NoNewWindow -Wait -PassThru
$exitCode = $proc.ExitCode

# Clean up temp .bat
Remove-Item $batFile -Force -ErrorAction SilentlyContinue

Write-Host "  end:      $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "  exitcode: $exitCode"

# --- Log capture validation ---
if (-not (Test-Path $LogFile)) {
    Write-Host "[FAIL] Log file not created: $LogFile" -ForegroundColor Red
    Write-Host "       MATLAB may have failed to start." -ForegroundColor Red
    exit 1
}
$logSize = (Get-Item $LogFile).Length
Write-Host "[LOG] Captured $logSize bytes to $LogFile" -ForegroundColor Cyan

# --- Suspiciously small log warning ---
if ($exitCode -eq 0 -and $logSize -lt 200) {
    Write-Host "[WARN] MATLAB exited 0 but log is suspiciously small ($logSize bytes)." -ForegroundColor Yellow
    Write-Host "       Possible silent failure (e.g., mphstart_failed early return)." -ForegroundColor Yellow
}

# --- Silent-fail detection via output file mtime ---
if ($OutputFile) {
    if (-not (Test-Path $OutputFile)) {
        Write-Host "[SILENT-FAIL] MATLAB exited 0 but output file does not exist:" -ForegroundColor Red
        Write-Host "             $OutputFile" -ForegroundColor Red
        Write-Host "             The run likely hit an early-return path (e.g. mphstart_failed)." -ForegroundColor Red
        exit 2
    }
    $postMtime = (Get-Item $OutputFile).LastWriteTime
    if ($preMtime -and $postMtime -le $preMtime) {
        Write-Host "[SILENT-FAIL] MATLAB exited 0 but output file was NOT updated." -ForegroundColor Red
        Write-Host "             pre-mtime:  $preMtime" -ForegroundColor Red
        Write-Host "             post-mtime: $postMtime" -ForegroundColor Red
        Write-Host "             The run is a no-op (empty run) -- do NOT treat as success." -ForegroundColor Red
        exit 2
    }
    Write-Host "[OK] Output file updated: $OutputFile (mtime $postMtime)" -ForegroundColor Green
}

if ($exitCode -ne 0) {
    Write-Host "[FAIL] MATLAB exited with code $exitCode" -ForegroundColor Red
    exit $exitCode
}

Write-Host "[DONE] MATLAB -batch completed successfully." -ForegroundColor Green
exit 0
