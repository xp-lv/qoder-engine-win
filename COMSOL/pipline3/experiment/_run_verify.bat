@echo off
cd /d d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\pipline_adjoint
"D:\LenovoSoftstore\Install\MATLAB\bin\matlab.exe" -batch "addpath('experiment'); verify_complex_per_voxel(12.0, -3.0, 30)" > experiment\verify_voxel_stdout.txt 2>&1
echo MATLAB_EXIT_CODE=%ERRORLEVEL%
