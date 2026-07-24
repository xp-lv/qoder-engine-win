"""SDK 内部 pytest 配置。

注册自定义 marker，避免 pytest unknown-marker 警告。
"""

import pytest


def pytest_configure(config):
    config.addinivalue_line(
        "markers",
        "slow: marks tests as slow (deselect with '-m \"not slow\"')",
    )


# 默认排除 slow 测试（除非显式 -m slow）
def pytest_collection_modifyitems(config, items):
    import os
    if os.environ.get("RUN_SLOW_TESTS") == "1":
        return
    skip_slow = pytest.mark.skip(reason="slow test, set RUN_SLOW_TESTS=1 to enable")
    for item in items:
        if "slow" in item.keywords:
            item.add_marker(skip_slow)
