#!/bin/bash
# D板同步脚本：把本地缓存推送到钉钉文档
# 推送前把 todo 行末的 💬备注 转成独立引用块，钉钉上显示更清爽
set -euo pipefail

CACHE="$HOME/.claude/demand-center-cache.md"
# 钉钉文档 nodeId —— 不入库, 从环境变量读取
# 用法: 在 ~/.zshrc 里 export DBOARD_NODE_ID="你的钉钉文档nodeId"
NODE_ID="${DBOARD_NODE_ID:-}"
# DBoard 由 launchd 拉起，不会加载 ~/.zshrc：环境变量缺失时从 zshrc 里捞同名 export 兜底
if [ -z "$NODE_ID" ] && [ -f "$HOME/.zshrc" ]; then
    NODE_ID=$(sed -n 's/^export DBOARD_NODE_ID="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$HOME/.zshrc" | tail -1)
fi
# launchd 的 PATH 只有 /usr/bin:/bin，补上 dws 的安装位置
export PATH="$HOME/.qoderwork/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

if [ -z "$NODE_ID" ]; then
    echo "❌ 未设置 DBOARD_NODE_ID 环境变量（钉钉文档 nodeId）" >&2
    echo "   请在 ~/.zshrc 中添加: export DBOARD_NODE_ID=\"你的nodeId\"" >&2
    exit 1
fi

if [ ! -f "$CACHE" ]; then
    echo "❌ 缓存文件不存在" >&2
    exit 1
fi

# 读取缓存（去掉 synced 注释行）
CONTENT=$(grep -v '^<!-- synced:' "$CACHE")

# 转换：把 "- [ ] xxx 💬备注" 拆成两行
#   第一行：todo 本体（去掉 💬及之后）
#   第二行：> 💬 备注（引用块，钉钉渲染为缩进引用）
CONTENT=$(printf '%s' "$CONTENT" | python3 -c '
import sys, re
lines = sys.stdin.read().split("\n")
out = []
for line in lines:
    m = re.match(r"^(\s*)(- \[[ xX]\] .*?)\s*💬(.*)$", line)
    if m:
        indent, todo, note = m.groups()
        note = note.strip()
        out.append(f"{indent}{todo}")
        if note:
            out.append(f"{indent}> 💬 {note}")
    else:
        out.append(line)
print("\n".join(out))
')

# 推送到钉钉文档（overwrite 模式，需 --yes 确认破坏性写入）
# 用 --content-file 而非 --content：内容含换行/表格/emoji，字面量传参会被 shell 转义破坏
TMP_MD=$(mktemp -t dboard-sync.XXXXXX.md)
trap 'rm -f "$TMP_MD"' EXIT
printf '%s' "$CONTENT" > "$TMP_MD"
RESULT=$(dws doc update --node "$NODE_ID" --content-file "$TMP_MD" \
                        --mode overwrite --yes 2>&1)

if echo "$RESULT" | grep -q '"success"'; then
    # 更新本地同步时间
    SYNC_TIME=$(date +"%Y-%m-%dT%H:%M:%S")
    if grep -q '^<!-- synced:' "$CACHE"; then
        sed -i '' "s|^<!-- synced:.*-->|<!-- synced: ${SYNC_TIME} -->|" "$CACHE"
    fi
    echo "✅ 已同步到钉钉文档"
else
    echo "❌ 同步失败: $RESULT" >&2
    exit 1
fi
