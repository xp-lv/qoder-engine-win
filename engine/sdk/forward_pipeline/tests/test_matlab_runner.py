"""matlab_runner.py 的单元测试（mock subprocess，无需真实 MATLAB）。"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path
from unittest import mock

import pytest

from engine.sdk.forward_pipeline.matlab_runner import (
    EXIT_FLAG_NAME,
    PARAMS_JSON_NAME,
    MatlabRunner,
    MatlabRunnerError,
    RunResult,
    _to_ascii_safe,
)


# ----------------------------------------------------------------------
# _to_ascii_safe
# ----------------------------------------------------------------------
class TestToAsciiSafe:
    def test_nested_dict_with_chinese(self):
        """中文字符应被转义为 \\uXXXX（ASCII safe）。"""
        data = {"name": "正演", "path": "C:\\foo"}
        out = _to_ascii_safe(data)
        # 路径反斜杠被规范化为正斜杠
        assert out["path"] == "C:/foo"
        # 中文字符串保持 str 类型（json.dumps 时会 ensure_ascii）
        assert isinstance(out["name"], str)

    def test_nan_inf_become_none(self):
        data = {"x": float("nan"), "y": float("inf"), "z": 3.14}
        out = _to_ascii_safe(data)
        assert out["x"] is None
        assert out["y"] is None
        assert out["z"] == 3.14

    def test_list_recursive(self):
        data = ["中文", [1, 2, float("nan")]]
        out = _to_ascii_safe(data)
        assert isinstance(out[0], str)
        assert out[1][2] is None

    def test_non_string_passthrough(self):
        assert _to_ascii_safe(42) == 42
        assert _to_ascii_safe(True) is True


# ----------------------------------------------------------------------
# MatlabRunner.run（mock subprocess）
# ----------------------------------------------------------------------
class TestRunnerRun:
    def test_invalid_entry_function_raises(self, tmp_path):
        runner = MatlabRunner(matlab_exe="matlab.exe")
        with pytest.raises(MatlabRunnerError):
            runner.run(
                entry_function="evil_function; system('rm -rf /')",
                params={"x": 1},
                work_dir=str(tmp_path),
            )

    def test_params_json_written_ascii(self, tmp_path):
        """params.json 必须 ASCII 安全（中文已转义）。"""
        runner = MatlabRunner(matlab_exe="matlab.exe")

        # 模拟 subprocess.Popen 的最小实现
        class FakeProc:
            returncode = 0
            stdout = mock.Mock()
            stderr = mock.Mock()
            def poll(self, fake=None):
                return 0
            def terminate(self): pass
            def kill(self): pass

        def fake_popen(*args, **kwargs):
            fp = FakeProc()
            fp.stdout.readline = lambda: ""
            fp.stderr.readline = lambda: ""
            fp.stdout.read = lambda: ""
            fp.stderr.read = lambda: ""
            # 模拟 MATLAB 进程结束时写 exit.flag（不能在 run() 前写，
            # 因为 runner 启动前会主动清掉旧 exit.flag）
            (tmp_path / EXIT_FLAG_NAME).write_text("0\n", encoding="ascii")
            return fp

        with mock.patch(
            "engine.sdk.forward_pipeline.matlab_runner.subprocess.Popen",
            side_effect=fake_popen,
        ):
            result = runner.run(
                entry_function="run_forward_pipeline",
                params={"name": "中文", "n": 64},
                work_dir=str(tmp_path),
            )

        # params.json 应该可被 ASCII 模式读取
        params_path = tmp_path / PARAMS_JSON_NAME
        assert params_path.is_file()
        # ASCII 模式读取不抛异常
        raw = params_path.read_text(encoding="ascii")
        # 中文字符串应已被 ensure_ascii 转义为 \uXXXX
        assert "\\u" in raw or "name" in raw
        parsed = json.loads(raw)
        assert parsed["n"] == 64
        assert parsed["name"] == "中文"  # json.loads 自动还原转义

    def test_exit_flag_read(self, tmp_path):
        """exit.flag 内容应决定 exit_code。

        模拟真实流程：MATLAB 进程结束后会写 exit.flag。
        所以 exit.flag 必须在 FakeProc 构造时（模拟进程结束时）写入，
        而不是在 run() 之前——因为 runner 启动前会主动清掉旧 exit.flag。
        """
        runner = MatlabRunner(matlab_exe="matlab.exe")

        class FakeProc:
            returncode = 99  # 进程返回码
            stdout = mock.Mock()
            stderr = mock.Mock()
            def poll(self, fake=None):
                return 99
            def terminate(self): pass
            def kill(self): pass

        def fake_popen(*args, **kwargs):
            fp = FakeProc()
            fp.stdout.readline = lambda: ""
            fp.stderr.readline = lambda: ""
            fp.stdout.read = lambda: ""
            fp.stderr.read = lambda: ""
            # 模拟 MATLAB 进程结束时的 exit.flag 写入
            (tmp_path / EXIT_FLAG_NAME).write_text("0\n", encoding="ascii")
            return fp

        with mock.patch(
            "engine.sdk.forward_pipeline.matlab_runner.subprocess.Popen",
            side_effect=fake_popen,
        ):
            result = runner.run(
                entry_function="run_forward_pipeline",
                params={"x": 1},
                work_dir=str(tmp_path),
            )

        assert result.exit_code == 0
        assert not result.timed_out

    def test_exit_flag_corrupt_falls_back_to_rc(self, tmp_path):
        """exit.flag 损坏时应回退到进程返回码。"""
        runner = MatlabRunner(matlab_exe="matlab.exe")

        class FakeProc:
            returncode = 7
            stdout = mock.Mock()
            stderr = mock.Mock()
            def poll(self, fake=None):
                return 7
            def terminate(self): pass
            def kill(self): pass

        def fake_popen(*args, **kwargs):
            fp = FakeProc()
            fp.stdout.readline = lambda: ""
            fp.stderr.readline = lambda: ""
            fp.stdout.read = lambda: ""
            fp.stderr.read = lambda: ""
            # 模拟 MATLAB 写入损坏的 exit.flag
            (tmp_path / EXIT_FLAG_NAME).write_text("garbage\n", encoding="ascii")
            return fp

        with mock.patch(
            "engine.sdk.forward_pipeline.matlab_runner.subprocess.Popen",
            side_effect=fake_popen,
        ):
            result = runner.run(
                entry_function="run_forward_pipeline",
                params={"x": 1},
                work_dir=str(tmp_path),
            )
        assert result.exit_code == 7

    def test_timeout_kills_process(self, tmp_path):
        """超时应 terminate + kill 进程。"""
        runner = MatlabRunner(matlab_exe="matlab.exe", default_timeout=1)

        terminate_called = []
        kill_called = []

        class FakeProc:
            returncode = None
            stdout = mock.Mock()
            stderr = mock.Mock()
            def poll(self, fake=None):
                return None  # 永不退出
            def terminate(self):
                terminate_called.append(True)
            def kill(self):
                kill_called.append(True)

        def fake_popen(*args, **kwargs):
            fp = FakeProc()
            fp.stdout.readline = lambda: ""
            fp.stderr.readline = lambda: ""
            fp.stdout.read = lambda: ""
            fp.stderr.read = lambda: ""
            return fp

        # patch sleep 加速测试
        with mock.patch(
            "engine.sdk.forward_pipeline.matlab_runner.subprocess.Popen",
            side_effect=fake_popen,
        ), mock.patch(
            "engine.sdk.forward_pipeline.matlab_runner.time.sleep",
            return_value=None,
        ), mock.patch(
            "engine.sdk.forward_pipeline.matlab_runner.time.time",
            side_effect=[0, 100, 200],  # 强制 elapsed > timeout
        ):
            result = runner.run(
                entry_function="run_forward_pipeline",
                params={"x": 1},
                work_dir=str(tmp_path),
            )

        assert result.timed_out
        assert result.exit_code == 124
        assert len(terminate_called) >= 1
        assert len(kill_called) >= 1

    def test_matlab_exe_not_found_raises(self, tmp_path):
        runner = MatlabRunner(matlab_exe="C:/nonexistent/matlab.exe")
        with pytest.raises(FileNotFoundError):
            runner.run(
                entry_function="run_forward_pipeline",
                params={"x": 1},
                work_dir=str(tmp_path),
            )

    def test_log_file_written(self, tmp_path):
        """log 文件应包含 header 和 stdout 内容。"""
        runner = MatlabRunner(matlab_exe="matlab.exe")

        class FakeProc:
            returncode = 0
            stdout = mock.Mock()
            stderr = mock.Mock()
            def poll(self, fake=None):
                return 0
            def terminate(self): pass
            def kill(self): pass

        def fake_popen(*args, **kwargs):
            fp = FakeProc()
            fp.stdout.readline = lambda: "[pipeline] hello\n"
            fp.stderr.readline = lambda: ""
            # 第二次读返回空，触发退出
            call_count = {"n": 0}
            def patched_readline():
                call_count["n"] += 1
                return "" if call_count["n"] > 1 else "[pipeline] hello\n"
            fp.stdout.readline = patched_readline
            fp.stdout.read = lambda: ""
            fp.stderr.read = lambda: ""
            # 模拟 MATLAB 进程结束时写 exit.flag
            (tmp_path / EXIT_FLAG_NAME).write_text("0\n", encoding="ascii")
            return fp

        with mock.patch(
            "engine.sdk.forward_pipeline.matlab_runner.subprocess.Popen",
            side_effect=fake_popen,
        ):
            result = runner.run(
                entry_function="run_forward_pipeline",
                params={"x": 1},
                work_dir=str(tmp_path),
            )

        log_text = Path(result.log_path).read_text(encoding="utf-8")
        assert "MatlabRunner log" in log_text
        assert "hello" in log_text
        assert "exit_code:    0" in log_text

    def test_default_scripts_dir(self):
        """默认 matlab_scripts_dir 应指向 SDK 的 matlab/ 子目录。"""
        runner = MatlabRunner()
        from pathlib import Path
        import engine.sdk.forward_pipeline.matlab_runner as mod
        expected = str(Path(mod.__file__).parent / "matlab")
        assert runner.matlab_scripts_dir == expected
