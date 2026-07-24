"""自包含的 LiveLink runner：启动 server → 跑 MATLAB → 停 server。
避免 client 断开导致 server 自杀。

用法：
    set PYTHONIOENCODING=utf-8
    python -X utf8 engine/sdk/forward_pipeline/scripts/livelink_runner.py <script.m>

它会把 server 和 matlab 作为子进程顺序跑，server 在后台，matlab 在前台。
matlab 退出后杀 server。
"""
import os
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

import io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

COMSOL_SERVER = r"D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\bin\win64\comsolmphserver.exe"
MATLAB_EXE = r"D:\LenovoSoftstore\Install\MATLAB\bin\matlab.exe"
PORT = 2036


def is_port_up(port):
    try:
        with socket.socket() as s:
            s.settimeout(1)
            s.connect(("127.0.0.1", port))
            return True
    except Exception:
        return False


def ensure_server():
    """确保 server 在跑；如未跑则启动一个后台进程。"""
    if is_port_up(PORT):
        print(f"[runner] Server already up on {PORT}")
        return None  # 没 spawn，不需要管

    print(f"[runner] Starting COMSOL Server on {PORT}...")
    # 用 CREATE_NEW_PROCESS_GROUP 让 server 独立于 python
    proc = subprocess.Popen(
        [COMSOL_SERVER, "-port", str(PORT), "-tmpdir", "C:\\Temp\\comsol"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        creationflags=subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0,
    )
    # 等端口就绪
    for i in range(60):
        time.sleep(3)
        if is_port_up(PORT):
            print(f"[runner] Server ready after {(i+1)*3}s (pid={proc.pid})")
            return proc
    print(f"[runner] FATAL: server not ready within 180s")
    proc.kill()
    return None


def run_matlab(script_path: Path, cwd: Path):
    """前台跑 MATLAB -batch run('script.m')，实时打印输出。"""
    script_arg = f"run('{str(script_path).replace(chr(92), '/')}')"
    cmd = [MATLAB_EXE, "-batch", script_arg]
    print(f"[runner] Running: {cmd[0]} -batch run('<script>')")
    print(f"[runner] script: {script_path}")
    print(f"[runner] cwd:    {cwd}")
    print(f"[runner] --- MATLAB output begin ---")
    proc = subprocess.Popen(
        cmd, cwd=str(cwd),
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, encoding="utf-8", errors="replace", bufsize=1,
    )
    for line in proc.stdout:
        print(f"  {line.rstrip()}")
    proc.wait()
    print(f"[runner] --- MATLAB output end (exit={proc.returncode}) ---")
    return proc.returncode


def main():
    if len(sys.argv) < 2:
        print("Usage: livelink_runner.py <script.m> [cwd]")
        return 2

    script_path = Path(sys.argv[1]).resolve()
    if not script_path.is_file():
        print(f"FATAL: script not found: {script_path}")
        return 2

    cwd = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else script_path.parent
    cwd.mkdir(parents=True, exist_ok=True)

    server_proc = ensure_server()
    if server_proc is None and not is_port_up(PORT):
        return 1

    try:
        rc = run_matlab(script_path, cwd)
    finally:
        # 不杀 server（如果是我们启动的）——下次 run 复用
        # 但如果是这个 script 启动的，就 kill
        if server_proc is not None:
            print(f"[runner] Stopping COMSOL Server (pid={server_proc.pid})...")
            try:
                server_proc.terminate()
                server_proc.wait(timeout=10)
            except Exception:
                server_proc.kill()
            print(f"[runner] Server stopped")

    return rc


if __name__ == "__main__":
    sys.exit(main())
