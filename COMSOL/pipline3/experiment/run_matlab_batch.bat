@echo off
REM ============================================================
REM  run_matlab_batch.bat
REM  Standardized MATLAB -batch launcher (shell-type independent)
REM
REM  Created by: Pipeline Maintainer (H036-P0 fix)
REM  Pipeline:   gen1_comsol_adjoint
REM
REM  PURPOSE:
REM    H035/H036 discovered that Start-Process -RedirectStandardOutput
REM    silently swallows MATLAB -batch stdout in this environment
REM    (process exits ~10-25s with exit 0 but stdout 0 bytes, .mat
REM    not updated). Direct "cmd.exe /c" calls also fail when the
REM    terminal is PowerShell-only (sandbox restriction).
REM
REM    This .bat solves BOTH problems:
REM      1. Native cmd.exe fd redirection (> log 2>&1) reliably
REM         captures ALL MATLAB application stdout/stderr.
REM      2. Callable from any shell type -- PowerShell implicitly
REM         runs .bat files through cmd.exe, gaining OS-level fd
REM         redirection without needing direct cmd.exe /c access.
REM
REM  ROOT CAUSE OF H036 P0 RECURRENCE:
REM    H035 created run_matlab_batch.ps1 only in gen1_comsol (pipline),
REM    but H036 ran on gen1_comsol_adjoint (pipline_adjoint) which had
REM    NO launcher. The executor fell back to Start-Process -Redirect
REM    and hit the same silent-fail. This .bat + the .ps1 copy ensure
REM    BOTH pipelines have the canonical launcher.
REM
REM  EXIT CODES:
REM    0 = success (MATLAB exit 0, output file updated)
REM    1 = MATLAB non-zero exit OR log not created
REM    2 = silent fail (exit 0 but output file NOT updated)
REM
REM  USAGE (from PowerShell):
REM    $env:MATLAB_BATCH_CMD = "addpath('config','experiment'); ..."
REM    & ".\run_matlab_batch.bat" "stdout.log" "." "out.mat"
REM
REM  USAGE (from cmd):
REM    set MATLAB_BATCH_CMD=addpath('config','experiment'); ...
REM    run_matlab_batch.bat "stdout.log" "." "out.mat"
REM ============================================================

setlocal

REM ===== Parse arguments =====
REM MATLAB batch command MUST be set in env var MATLAB_BATCH_CMD
REM Positional: %1=LOG_FILE  %2=WORK_DIR  %3=OUTPUT_FILE  %4=MATLAB_EXE

set "LOG_FILE=%~1"
set "WORK_DIR=%~2"
if "%WORK_DIR%"=="" set "WORK_DIR=%CD%"
set "OUTPUT_FILE=%~3"
set "MATLAB_EXE=%~4"
if "%MATLAB_EXE%"=="" set "MATLAB_EXE=D:\LenovoSoftstore\Install\MATLAB\bin\matlab.exe"

if "%MATLAB_BATCH_CMD%"=="" (
    echo [FAIL] Env var MATLAB_BATCH_CMD is not set.
    echo        Set it before calling this script, e.g.:
    echo          set MATLAB_BATCH_CMD=addpath('config'); run_inversion_complex();
    exit /b 1
)
if "%LOG_FILE%"=="" (
    echo [FAIL] Usage: set MATLAB_BATCH_CMD=... ^& run_matlab_batch.bat LOG_FILE [WORK_DIR] [OUTPUT_FILE] [MATLAB_EXE]
    exit /b 1
)

REM ===== Record output file mtime BEFORE launch (silent-fail guard) =====
set "PRE_MTIME="
if "%OUTPUT_FILE%"=="" goto :launch
if not exist "%OUTPUT_FILE%" goto :launch
for %%I in ("%OUTPUT_FILE%") do set "PRE_MTIME=%%~tI"

:launch
REM ===== Clear stale log =====
if exist "%LOG_FILE%" del "%LOG_FILE%" /q

REM ===== Launch MATLAB with native cmd.exe full-stream redirection =====
cd /d "%WORK_DIR%"
echo [LAUNCH] MATLAB -batch via native cmd.exe redirection
echo   workdir:  %WORK_DIR%
echo   log:      %LOG_FILE%
if not "%OUTPUT_FILE%"=="" echo   output:   %OUTPUT_FILE% ^(mtime guard enabled^)
echo   start:    %date% %time%

"%MATLAB_EXE%" -batch "%MATLAB_BATCH_CMD%" > "%LOG_FILE%" 2>&1
set "EXIT_CODE=%ERRORLEVEL%"

echo   end:      %date% %time%
echo   exitcode: %EXIT_CODE%

REM ===== Log capture validation =====
if not exist "%LOG_FILE%" (
    echo [FAIL] Log file not created: %LOG_FILE%
    exit /b 1
)

REM ===== Silent-fail detection via output file mtime =====
if "%OUTPUT_FILE%"=="" goto :check_exit
if not exist "%OUTPUT_FILE%" (
    echo [SILENT-FAIL] MATLAB exited but output file does not exist: %OUTPUT_FILE%
    exit /b 2
)
if "%PRE_MTIME%"=="" goto :output_ok
set "POST_MTIME="
for %%I in ("%OUTPUT_FILE%") do set "POST_MTIME=%%~tI"
if "%PRE_MTIME%"=="%POST_MTIME%" (
    echo [SILENT-FAIL] MATLAB exited 0 but output file was NOT updated.
    echo   pre-mtime:  %PRE_MTIME%
    echo   post-mtime: %POST_MTIME%
    echo   This is a no-op empty run -- do NOT treat as success.
    exit /b 2
)
:output_ok
echo [OK] Output file updated: %OUTPUT_FILE%

:check_exit
if not "%EXIT_CODE%"=="0" (
    echo [FAIL] MATLAB exited with code %EXIT_CODE%
    exit /b %EXIT_CODE%
)
echo [DONE] MATLAB -batch completed successfully.
exit /b 0
