#!/bin/bash
# stability-hook.sh — 兼容壳（转发到 stability-hook.py）
# 推荐直接使用：python3 .qoder/hooks/stability-hook.py
exec python3 "$(dirname "$0")/stability-hook.py" "$@"
