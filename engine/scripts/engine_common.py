#!/usr/bin/env python3
"""engine_common.py — 引擎脚本公共工具模块。

集中管理多个脚本中重复实现的工具函数，消除冗余代码。
所有引擎脚本均可通过 from engine_common import xxx 引入。
"""
import json, os, sys
from datetime import datetime, timezone

# Windows: 全局 stdout UTF-8（防止 print 中文时 GBK 崩溃）
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


# ─── 输出函数（C009）───

def output(data, force_exit_zero=False):
    """统一 JSON 输出 + sys.exit。

    exit code 策略：
    - force_exit_zero=True → 始终 exit(0)（如 gate.py）
    - 默认 → exit(0 if data["status"]=="success" else 1)
    """
    print(json.dumps(data, ensure_ascii=False))
    if force_exit_zero:
        sys.exit(0)
    sys.exit(0 if data.get("status") == "success" else 1)


def output_error(error_code, message):
    """输出错误 JSON 并以非零码退出。"""
    print(json.dumps({"status": "failure", "error_code": error_code, "message": message}, ensure_ascii=False))
    sys.exit(1)


# ─── 时间函数（C010）───

def now_iso():
    """返回 ISO 8601 UTC 时间字符串。"""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ─── JSON 加载函数（C020）───

def load_json_safe(path, default=None):
    """容错 JSON 加载：失败时返回 default。"""
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            return json.load(f)
    except Exception:
        return default


def load_json_or_exit(path, error_code, error_msg, extra_fields=None):
    """加载 JSON 文件，失败时输出结构化错误 JSON 并退出。

    封装：检查文件存在性 → json.load 解析 → 失败时输出含 error_code/message
    及 extra_fields 附加字段的错误 JSON → sys.exit(1)。
    """
    if not os.path.exists(path):
        err = {"status": "failure", "error_code": error_code, "message": f"{error_msg}: {path}"}
        if extra_fields:
            err.update(extra_fields)
        print(json.dumps(err, ensure_ascii=False))
        sys.exit(1)
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            return json.load(f)
    except (json.JSONDecodeError, ValueError) as e:
        err = {"status": "failure", "error_code": error_code, "message": f"{error_msg}: {e}"}
        if extra_fields:
            err.update(extra_fields)
        print(json.dumps(err, ensure_ascii=False))
        sys.exit(1)


# ─── 路由缓存函数（C005）───

def load_router_registry_cached(app_path):
    """加载 ROUTER.json 和 registry.json，使用文件级缓存。

    缓存策略：
    - 检测源文件 mtime 未变则直接返回缓存
    - 缓存写入使用原子写（tempfile.mkstemp + os.replace）
    - 缓存读取容错：JSONDecodeError/IOError 时回退到直接读取源文件

    返回 {'router': router_data, 'registry': registry_data}
    """
    import tempfile
    cache = os.path.join(app_path, ".router_cache.json")
    router_p = os.path.join(app_path, "ROUTER.json")
    registry_p = os.path.join(app_path, "registry.json")

    def _read_source():
        with open(router_p, "r", encoding="utf-8-sig") as f:
            _r = json.load(f)
        with open(registry_p, "r", encoding="utf-8-sig") as f:
            _g = json.load(f)
        return {"router": _r, "registry": _g}

    def _atomic_write(data):
        fd, tmp = tempfile.mkstemp(dir=app_path)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False)
            os.replace(tmp, cache)
        except Exception:
            try:
                os.remove(tmp)
            except OSError:
                pass

    # 缓存命中检查（mtime 比较）
    if (os.path.exists(cache)
            and os.path.exists(router_p)
            and os.path.exists(registry_p)
            and os.path.getmtime(cache) >= os.path.getmtime(router_p)
            and os.path.getmtime(cache) >= os.path.getmtime(registry_p)):
        try:
            with open(cache, "r", encoding="utf-8-sig") as f:
                return json.load(f)
        except (json.JSONDecodeError, IOError, OSError):
            pass  # 缓存损坏，fall through 到直接读取源文件

    data = _read_source()
    _atomic_write(data)
    return data
