#!/bin/bash
# d — 个人工作看板
# GUI 模式: d 或 d gui   → 弹出 Tkinter 窗口
# CLI 模式: d ls         → 终端输出
#           d today      → 只看今日零碎
#           d urgent     → 只看紧急条目
#           d done 3     → 勾掉今日第 N 项
#           d D008       → 查看某条目详情

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)"
GUI_SCRIPT="$SCRIPT_DIR/dboard_gui.py"

# 找 GUI 脚本（可能在 ~/.local/bin 旁边，也可能在源码目录）
if [ ! -f "$GUI_SCRIPT" ]; then
    GUI_SCRIPT="$HOME/work/code/other/DBoard/dboard_gui.py"
fi

CACHE="$HOME/.claude/demand-center-cache.md"

case "${1:-gui}" in
    gui|"")
        if [ -f "$GUI_SCRIPT" ]; then
            python3 "$GUI_SCRIPT" &
            disown
        else
            echo "❌ 找不到 GUI: $GUI_SCRIPT"
            exit 1
        fi
        ;;
    ls)
        # 简单终端输出（保留之前的 CLI 功能）
        exec "$0.cli" "${@:2}" 2>/dev/null || {
            echo "📋 D板 · $(date +%Y-%m-%d)"
            echo ""
            grep -E "^### D[0-9]" "$CACHE" | while read -r line; do
                echo "  $line" | sed 's/### //'
            done
        }
        ;;
    today|t)
        echo "📝 今日零碎"
        awk '/^## 📝/,0' "$CACHE" | grep -E "^\s*- \[" | cat -n
        ;;
    done)
        if [ -z "${2:-}" ]; then echo "用法: d done <序号>"; exit 1; fi
        # 调用 Python 来切换
        python3 -c "
import re, os
path = os.path.expanduser('~/.claude/demand-center-cache.md')
with open(path) as f: lines = f.readlines()
in_todo, idx = False, 0
for i, line in enumerate(lines):
    if line.strip().startswith('## 📝'): in_todo = True; continue
    if in_todo and re.match(r'\s*- \[[ xX]\]', line):
        idx += 1
        if idx == $2:
            if '- [ ]' in line: lines[i] = line.replace('- [ ]', '- [x]', 1); print('✅ 已完成')
            else: lines[i] = re.sub(r'- \[[xX]\]', '- [ ]', line, count=1); print('↩️ 已恢复')
            break
with open(path, 'w') as f: f.writelines(lines)
"
        ;;
    D[0-9][0-9][0-9])
        echo ""
        awk "/^### $1/,/^### D[0-9]|^## /" "$CACHE" | head -n -1 | sed 's/^### //'
        echo ""
        ;;
    help|h|-h|--help)
        echo "用法: d [命令]"
        echo ""
        echo "  d            打开 GUI 看板窗口"
        echo "  d ls         终端输出看板"
        echo "  d today      只看今日零碎"
        echo "  d done 3     勾掉/恢复第 3 项"
        echo "  d D008       查看某条目详情"
        echo "  d help       显示帮助"
        ;;
    *)
        echo "未知命令: $1 · 输入 d help 查看帮助"
        exit 1
        ;;
esac
