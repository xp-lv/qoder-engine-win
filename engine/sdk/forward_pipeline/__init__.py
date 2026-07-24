"""COMSOL Forward Pipeline SDK.

跨 app 共享的 COMSOL 频域电磁正演/伴随管线 SDK。
- 提供 Python API（subprocess + comsolbatch 模式）
- SHA-256 输入哈希缓存，相同输入不重跑
- MATLAB 资产沉淀在 matlab/ 子目录，与 SDK_VERSION 解耦的版本管理

主要导出：
    ForwardPipeline   - 主 API 类
    ForwardResult     - 正演返回类型
    AdjointResult     - 伴随返回类型
    SDK_VERSION       - SDK 版本号（参与缓存哈希）

参见 README.md 获取完整接口契约和使用示例。
"""

from engine.sdk.forward_pipeline.api import (
    AdjointResult,
    ForwardPipeline,
    ForwardResult,
)
from engine.sdk.forward_pipeline.cache import SDK_VERSION

__all__ = [
    "ForwardPipeline",
    "ForwardResult",
    "AdjointResult",
    "SDK_VERSION",
]
