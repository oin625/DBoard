#!/bin/bash
# 三渠统一状态板刷新入口：同步 Tesla 三渠分支后生成 HTML。
# 直接运行 python3 canal_board.py 也可离线生成，但不会拉取远端最新提交。
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESLA_DIR="$HOME/work/code/tesla"

git -C "$TESLA_DIR" fetch --quiet origin three-canals-unified-0615 2>/dev/null || \
  echo "⚠ Tesla fetch 失败（离线？），继续使用本地已有分支快照"

python3 "$SCRIPT_DIR/canal_board.py"
