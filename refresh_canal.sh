#!/bin/bash
# Canal 面板一键刷新：拉 Tesla 远端 → 扫两仓源码 → 渲染 HTML → 发布到预览目录
# 用法：./refresh_canal.sh 然后浏览器刷新即可
set -e
cd "$(dirname "$0")"

# Tesla 读的是 origin/three-canals-unified-0615（git show），fetch 才能拿到远端新提交；
# Ultra 读工作区文件，本地一保存重跑就生效，无需任何 git 操作
git -C "$HOME/work/code/tesla" fetch --quiet origin three-canals-unified-0615 2>/dev/null || \
  echo "⚠ Tesla fetch 失败（离线？），继续用本地已有的远端快照"

python3 gen_canal.py
python3 proto_canal.py

mkdir -p /tmp/canal_preview
cp /tmp/canal_proto.html /tmp/canal_preview/index.html
echo "✓ 已发布 → http://localhost:8807 （浏览器刷新即可看到新数据）"
