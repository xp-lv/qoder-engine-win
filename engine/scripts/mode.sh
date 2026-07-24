#!/bin/bash
# mode.sh — 兼容壳（转发到 mode.py）
# 推荐直接使用：python3 engine/scripts/mode.py
exec python3 "$(dirname "$0")/mode.py" "$@"
