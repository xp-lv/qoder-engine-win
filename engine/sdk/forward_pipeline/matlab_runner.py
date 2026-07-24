"""MATLAB 子进程封装 for COMSOL Forward Pipeline SDK.

职责
----
1. 把 params dict 序列化为 work_dir/params.json（ASCII 安全，全路径无中文）。
2. 调用 matlab.exe -batch "launcher('<entry>', '<work_dir>/params.json')"。
3. 实时流式 stdout/stderr 到 log_path。
4. 通过 work_dir/exit.flag 读取 exit_code（0/1）—— launcher.m 的约定。
5. 超时控制：先 SIGTERM，仍不退则 SIGKILL。

为什么不直接用 matlab.engine 包？
- matlab.engine 启动慢、调试难、Windows 路径处理麻烦。
- subprocess + -batch 模式更稳定、更接近生产部署习惯。
- 与现有 launcher_forward_pipeline.m 模式一致（项目记忆中提到的 R2d fallback）。

约定
----
launcher.m 必须在 work_dir/ 写入：
    exit.flag       — 内容为单个整数（0=success, 非 0=failure）
    pipeline_result.mat — 可选，存 result struct 用于诊断
    pipeline_console.log — 由 diary 自动写入（封装层不再重复）
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Optional, Tuple

# 默认 MATLAB 启动超时（秒）—— MATLAB 冷启动 + LiveLink 初始化
DEFAULT_TIMEOUT = 1800  # 30 min

# exit.flag 协议
EXIT_FLAG_NAME = "exit.flag"
PARAMS_JSON_NAME = "params.json"


@dataclass
class RunResult:
    """matlab_runner.run() 的返回值。"""

    exit_code: int                       # 0=success, 非 0=failure/timeout
    timed_out: bool                      # 是否因超时被 kill
    stdout: str                          # MATLAB stdout 全量
    stderr: str                          # MATLAB stderr 全量
    log_path: str                        # 日志文件路径
    work_dir: str                        # 工作目录（含 params.json / exit.flag）
    duration_sec: float                  # 实际运行时长


class MatlabRunnerError(Exception):
    """MATLAB 子进程失败。"""


def _to_ascii_safe(value: Any) -> Any:
    """递归把 dict/list/str 转为 ASCII 安全形式。

    中文 → \\uXXXX 转义（json.dumps ensure_ascii=True 默认行为）。
    float('inf') / NaN → None（JSON 不支持）。
    """
    if isinstance(value, dict):
        return {k: _to_ascii_safe(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_to_ascii_safe(v) for v in value]
    if isinstance(value, float):
        if value != value or value in (float("inf"), float("-inf")):
            return None
        return value
    if isinstance(value, str):
        # 路径里的反斜杠规范化为正斜杠（MATLAB 同时支持，且避免 \\ 转义陷阱）
        return value.replace("\\", "/") if (len(value) < 260 and "\\" in value) else value
    return value


class MatlabRunner:
    """MATLAB -batch 子进程封装。

    Parameters
    ----------
    matlab_exe : str
        matlab.exe 绝对路径。若为 "matlab.exe" 则依赖 PATH。
    matlab_scripts_dir : str
        含 launcher.m 和 run_*.m 的目录（SDK 内置 matlab/ 目录）。
    default_timeout : int
        默认单次 run 超时（秒）。
    """

    def __init__(
        self,
        matlab_exe: str = "matlab.exe",
        matlab_scripts_dir: Optional[str] = None,
        default_timeout: int = DEFAULT_TIMEOUT,
    ):
        self.matlab_exe = matlab_exe
        if matlab_scripts_dir is None:
            # 默认指向本 SDK 的 matlab/ 子目录
            here = Path(__file__).parent
            matlab_scripts_dir = str(here / "matlab")
        self.matlab_scripts_dir = matlab_scripts_dir
        self.default_timeout = default_timeout

    # ------------------------------------------------------------------
    # run
    # ------------------------------------------------------------------
    def run(
        self,
        entry_function: str,
        params: Dict[str, Any],
        work_dir: str,
        log_path: Optional[str] = None,
        timeout: Optional[int] = None,
    ) -> RunResult:
        """执行一次 MATLAB 调用。

        Args:
            entry_function: MATLAB 函数名（如 'run_forward_pipeline'）。
                launcher.m 会通过 feval 调用它。
            params: 参数 dict，会被序列化为 work_dir/params.json。
                值必须 JSON-serializable（str/int/float/list/dict）。
            work_dir: 工作目录。必须存在或可创建。
            log_path: 日志文件路径。None 则用 work_dir/pipeline.log。
            timeout: 超时秒数。None 则用 self.default_timeout。

        Returns:
            RunResult。

        Raises:
            MatlabRunnerError: MATLAB 启动失败、timeout 等。
            FileNotFoundError: matlab_exe 不存在（若给定绝对路径）。
        """
        if timeout is None:
            timeout = self.default_timeout

        work_dir_path = Path(work_dir)
        work_dir_path.mkdir(parents=True, exist_ok=True)

        if log_path is None:
            log_path = str(work_dir_path / "pipeline.log")
        log_path_path = Path(log_path)

        # 验证 entry_function 名（白名单防止注入）
        allowed = {"run_forward_pipeline", "run_adjoint_pipeline"}
        if entry_function not in allowed:
            raise MatlabRunnerError(
                f"entry_function must be one of {allowed}, got: {entry_function}"
            )

        # 序列化 params.json（ASCII safe）
        safe_params = _to_ascii_safe(params)
        # 注入 entry function 名（launcher.m 也会从 argv 读，双保险）
        safe_params["__entry_function__"] = entry_function
        params_json_path = work_dir_path / PARAMS_JSON_NAME
        params_json_path.write_text(
            json.dumps(safe_params, indent=2, ensure_ascii=True),
            encoding="ascii",
        )

        # 清掉旧的 exit.flag（避免误读上次结果）
        exit_flag_path = work_dir_path / EXIT_FLAG_NAME
        if exit_flag_path.exists():
            exit_flag_path.unlink()

        # 构造 MATLAB 命令
        # matlab.exe -batch "addpath('<scripts>'); launcher('run_forward_pipeline', '<params.json>')"
        scripts_dir_ascii = self.matlab_scripts_dir.replace("\\", "/")
        params_path_ascii = str(params_json_path).replace("\\", "/")
        matlab_stmt = (
            f"addpath('{scripts_dir_ascii}'); "
            f"launcher('{entry_function}', '{params_path_ascii}');"
        )

        cmd = [self.matlab_exe, "-batch", matlab_stmt]

        # 如果 matlab_exe 是绝对路径，校验存在
        if os.path.isabs(self.matlab_exe) and not os.path.isfile(self.matlab_exe):
            raise FileNotFoundError(f"matlab_exe not found: {self.matlab_exe}")

        # 启动子进程，实时捕获 stdout/stderr
        start = time.time()
        stdout_chunks = []
        stderr_chunks = []
        proc = None
        timed_out = False

        try:
            with open(log_path_path, "w", encoding="utf-8", errors="replace") as logf:
                header = (
                    f"=== MatlabRunner log ===\n"
                    f"entry:   {entry_function}\n"
                    f"cmd:     {' '.join(cmd)}\n"
                    f"work:    {work_dir}\n"
                    f"timeout: {timeout}s\n"
                    f"start:   {time.strftime('%Y-%m-%d %H:%M:%S')}\n"
                    f"=========================\n"
                )
                logf.write(header)
                logf.flush()

                proc = subprocess.Popen(
                    cmd,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    cwd=work_dir,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                    bufsize=1,                # 行缓冲
                )

                # 轮询读取 stdout/stderr 并实时写日志
                while True:
                    try:
                        stdout_line = proc.stdout.readline() if proc.stdout else ""
                        if stdout_line:
                            stdout_chunks.append(stdout_line)
                            logf.write(stdout_line)
                            logf.flush()
                    except Exception:
                        pass

                    try:
                        stderr_line = proc.stderr.readline() if proc.stderr else ""
                        if stderr_line:
                            stderr_chunks.append(stderr_line)
                            logf.write("[stderr] " + stderr_line)
                            logf.flush()
                    except Exception:
                        pass

                    # 检查进程是否结束
                    rc = proc.poll()
                    if rc is not None:
                        # 排空剩余输出
                        if proc.stdout:
                            rest = proc.stdout.read()
                            if rest:
                                stdout_chunks.append(rest)
                                logf.write(rest)
                        if proc.stderr:
                            rest = proc.stderr.read()
                            if rest:
                                stderr_chunks.append(rest)
                                logf.write("[stderr] " + rest)
                        break

                    # 超时检查
                    elapsed = time.time() - start
                    if elapsed > timeout:
                        timed_out = True
                        try:
                            proc.terminate()  # SIGTERM
                        except Exception:
                            pass
                        # 给 5 秒优雅退出
                        time.sleep(5)
                        if proc.poll() is None:
                            try:
                                proc.kill()  # SIGKILL
                            except Exception:
                                pass
                        logf.write(
                            f"\n[runner] TIMEOUT after {elapsed:.1f}s, process killed\n"
                        )
                        break

                    # 避免忙等
                    time.sleep(0.05)

        except FileNotFoundError as e:
            raise MatlabRunnerError(f"Failed to start MATLAB: {e}")
        except Exception as e:
            raise MatlabRunnerError(f"Runner exception: {e}")

        duration = time.time() - start
        stdout = "".join(stdout_chunks)
        stderr = "".join(stderr_chunks)

        # 读取 exit.flag
        exit_code = proc.returncode if proc else 1
        if exit_flag_path.exists():
            try:
                flag_val = exit_flag_path.read_text(encoding="ascii").strip()
                exit_code = int(flag_val)
            except (ValueError, OSError):
                # exit.flag 损坏，回退到进程返回码
                pass

        if timed_out:
            exit_code = 124  # 标准超时退出码

        result = RunResult(
            exit_code=exit_code,
            timed_out=timed_out,
            stdout=stdout,
            stderr=stderr,
            log_path=str(log_path_path),
            work_dir=str(work_dir_path),
            duration_sec=duration,
        )

        # 写入最终摘要
        try:
            with open(log_path_path, "a", encoding="utf-8") as logf:
                logf.write(
                    f"\n=== summary ===\n"
                    f"exit_code:    {exit_code}\n"
                    f"timed_out:    {timed_out}\n"
                    f"duration_sec: {duration:.2f}\n"
                    f"end:          {time.strftime('%Y-%m-%d %H:%M:%S')}\n"
                )
        except OSError:
            pass

        return result
