<#
.SYNOPSIS
    COMSOL Server 启动辅助脚本（管线维护 Round21 — H030-P0）
.DESCRIPTION
    逆散射规范第 5 节要求 COMSOL Server 需独立终端长期运行于 port 2036。
    H029/H030 连续两次实验均在首次检查时发现 Server 未启动，浪费 ~25s 排查时间。
    run_experiment.m 已在 mphstart 前增加了端口预检查（H029-P0），
    本脚本提供配套的 Server 一键启动能力，消除手动查找路径的摩擦。

    用法：
    1. 独立终端运行：powershell -ExecutionPolicy Bypass -File start_comsol_server.ps1
    2. 若已在运行则跳过；若未运行则后台启动并等待端口就绪。
#>

param(
    [int]$Port = 2036,
    [string]$TmpDir = "D:\comsol_tmp"
)

$ErrorActionPreference = "Stop"

# --- COMSOL 安装路径（按优先级探测常见安装位置）---
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
    Write-Host "[ERROR] 未找到 comsolmphserver.exe。" -ForegroundColor Red
    Write-Host "        已探测路径均不存在，请手动指定 -ComsolExe 参数或修改脚本中的候选路径。" -ForegroundColor Yellow
    Write-Host "        示例：D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\bin\win64\comsolmphserver.exe"
    exit 1
}

# --- 检查 Server 是否已在运行 ---
Write-Host "[CHECK] 探测 localhost:$Port ..." -ForegroundColor Cyan
$connection = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($connection) {
    Write-Host "[OK] COMSOL Server 已在 localhost:$Port 运行（PID=$($connection.OwningProcess | Select-Object -First 1)），无需重复启动。" -ForegroundColor Green
    exit 0
}
Write-Host "[INFO] 端口 $Port 无监听，准备启动 COMSOL Server ..." -ForegroundColor Yellow

# --- 确保 tmpdir 存在 ---
if (-not (Test-Path $TmpDir)) {
    Write-Host "[SETUP] 创建临时目录: $TmpDir" -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $TmpDir -Force | Out-Null
}

# --- 启动 COMSOL Server（后台进程，独立终端长期运行）---
Write-Host "[START] $ComsolExe -port $Port -tmpdir $TmpDir" -ForegroundColor Cyan
$processArgs = @("-port", $Port, "-tmpdir", $TmpDir)
$process = Start-Process -FilePath $ComsolExe -ArgumentList $processArgs -PassThru -WindowStyle Normal
Write-Host "[STARTED] COMSOL Server PID=$($process.Id)" -ForegroundColor Green

# --- 等待端口就绪（最多 30s）---
Write-Host "[WAIT] 等待端口 $Port 就绪 ..." -ForegroundColor Cyan
$maxWait = 30
$waited = 0
while ($waited -lt $maxWait) {
    Start-Sleep -Seconds 1
    $waited++
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($conn) {
        Write-Host "[READY] COMSOL Server 已就绪（localhost:$Port，等待 ${waited}s）。" -ForegroundColor Green
        Write-Host ""
        Write-Host "  现在可以在 MATLAB 中执行：" -ForegroundColor White
        Write-Host "    cd('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\pipline')" -ForegroundColor White
        Write-Host "    addpath('config','experiment')" -ForegroundColor White
        Write-Host "    state = run_experiment('plugin_c01');" -ForegroundColor White
        Write-Host ""
        Write-Host "  注意：此终端须保持打开，Server 关闭后 MATLAB 连接将断开。" -ForegroundColor Yellow
        exit 0
    }
}
Write-Host "[TIMEOUT] 端口 $Port 在 ${maxWait}s 内未就绪，请检查 COMSOL 日志或许可证。" -ForegroundColor Red
exit 1
