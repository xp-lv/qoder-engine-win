#!/bin/bash
# switch.sh — 兼容壳（转发到 switch.py）
# 推荐直接使用：python3 engine/scripts/switch.py
exec python3 "$(dirname "$0")/switch.py" "$@"
