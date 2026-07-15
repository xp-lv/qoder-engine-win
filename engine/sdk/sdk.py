"""引擎 SDK 版本定义与兼容性检查。

SDK 版本号标记引擎对 app 编译产物的格式契约版本。
引擎升级时如果只改内部实现不改编译产物格式，SDK 版本号不变。
如果 ROUTER.json/registry.json/manifest.json 格式有 breaking change，SDK 版本号递增。

用法：
  # compiler.py 编译时写入版本号
  from sdk import SDK_VERSION
  router["schema_version"] = SDK_VERSION

  # init.py 启动时检查兼容性
  from sdk import check_app_compatibility, CompatibilityError
  check_app_compatibility(router_path)
"""

import json
import os
import sys


# 当前引擎支持的 SDK 版本
SDK_VERSION = "2.0"

# 兼容的旧版本列表（引擎能读这些版本的编译产物）
# 1.0 = transitions 为列表格式（旧格式），引擎通过 get_edge_targets 等兼容函数读取
COMPATIBLE_VERSIONS = ["1.0", "2.0"]


class CompatibilityError(Exception):
    """app 编译产物的 SDK 版本与引擎不兼容。"""

    def __init__(self, app_version, engine_version, compatible_versions):
        self.app_version = app_version
        self.engine_version = engine_version
        self.compatible_versions = compatible_versions
        super().__init__(
            f"app schema_version={app_version} 与引擎 SDK={engine_version} 不兼容。"
            f"引擎支持的版本: {compatible_versions}"
        )


def get_app_schema_version(router_path):
    """从 ROUTER.json 读取 app 的 schema_version。无此字段视为 1.0。"""
    if not os.path.exists(router_path):
        return SDK_VERSION  # 文件不存在时假定当前版本（编译器会生成）
    try:
        with open(router_path, "r", encoding="utf-8") as f:
            router = json.load(f)
        return router.get("schema_version", "1.0")
    except (json.JSONDecodeError, OSError):
        return "1.0"  # 损坏文件视为旧版本


def check_app_compatibility(router_path):
    """检查 app 的编译产物是否与引擎 SDK 兼容。

    兼容 → 正常返回（无输出）
    兼容旧版 → 打印警告
    不兼容 → 抛出 CompatibilityError
    """
    app_version = get_app_schema_version(router_path)

    if app_version == SDK_VERSION:
        return  # 完全兼容

    if app_version in COMPATIBLE_VERSIONS:
        print(f"[SDK] 警告：app 使用旧格式（v{app_version}），引擎兼容运行", file=sys.stderr)
        return

    # 不兼容
    raise CompatibilityError(app_version, SDK_VERSION, COMPATIBLE_VERSIONS)
