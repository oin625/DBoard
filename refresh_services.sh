#!/bin/bash
# refresh_services.sh — 逐仓库 fetch + AI 分析近期变化，更新服务卡片内容
# 输出: ~/.claude/bizmap-service-updates.json
# 进度: ~/.claude/bizmap-refresh-progress.json
set -e
PATH="$HOME/.qoderwork/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
CODE_DIR="$HOME/work/code"
PROGRESS="$HOME/.claude/bizmap-refresh-progress.json"
OUTPUT="$HOME/.claude/bizmap-service-updates.json"

python3 - "$CODE_DIR" "$PROGRESS" "$OUTPUT" <<'PYTHON'
import json, sys, os, subprocess, datetime, pathlib

code_dir = pathlib.Path(sys.argv[1])
progress_file = sys.argv[2]
output_file = sys.argv[3]

# 服务列表（和 gen_bizmap.py 的 S 一致）
SERVICES = [
    "ultra", "canary", "tesla", "coserviceability", "nczmembercenter",
    "ic", "promotioncenter", "marketingcenter", "marketcenter",
    "b2ctradecenter", "orderabilitycenter", "aftersalecenter",
    "orderhandlecenter", "nczordercenter", "tmycsupply", "scfservice",
    "workorder", "ordertrademanager", "ttrade", "ordercenter",
    "extgateway", "tradeextgateway", "b2cworkbench", "tmallycweb",
    "authweb", "tmycminienterprise", "commondata", "fastsearch",
    "datacenter", "channelcenter", "superapiplus", "apimanagerplus"
]

def write_progress(current, total, name, status):
    with open(progress_file, 'w') as f:
        json.dump({"current": current, "total": total, "name": name, "status": status,
                   "percent": round(current / total * 100)}, f, ensure_ascii=False)

def git_cmd(repo, args):
    r = subprocess.run(['git', '-C', str(repo)] + args,
                       capture_output=True, text=True, timeout=30)
    return r.stdout.strip() if r.returncode == 0 else ""

def ai_summarize(text):
    if not text:
        return ""
    prompt = f"用一句中文（15-30字）概括以下git commit记录的主要变更方向，不要列举细节:\n{text[:800]}"
    try:
        r = subprocess.run([os.path.expanduser('~/.local/bin/qoderclicn'),
            '-m', 'Qwen3.7-Flash', '--tools', '', '--no-session-persistence', '-p', prompt],
            capture_output=True, text=True, timeout=30)
        if r.returncode == 0 and r.stdout.strip():
            import re
            out = r.stdout.strip()
            out = re.sub(r'^(概括|总结|摘要)[：:]\s*', '', out)
            out = out.strip('"\'""''> ')
            return out
    except:
        pass
    return ""

total = len(SERVICES)
results = {}

for i, svc in enumerate(SERVICES):
    write_progress(i + 1, total, svc, "fetching")
    repo = code_dir / svc
    if not (repo / '.git').exists():
        results[svc] = {"commits_6mo": 0, "recent": "", "new_facades": 0}
        continue

    # fetch
    subprocess.run(['git', '-C', str(repo), 'fetch', 'origin', 'master', '--quiet'],
                   capture_output=True, timeout=60)

    # 近6月 commit 数
    since = (datetime.datetime.now() - datetime.timedelta(days=180)).strftime('%Y-%m-%d')
    count_str = git_cmd(repo, ['rev-list', '--count', '--since', since, 'origin/master'])
    commits_6mo = int(count_str) if count_str.isdigit() else 0

    # 最近 20 条 commit messages
    write_progress(i + 1, total, svc, "analyzing")
    log = git_cmd(repo, ['log', 'origin/master', '--oneline', '-20', '--no-merges'])

    # 新增 Facade
    new_facades_str = git_cmd(repo, ['log', 'origin/master', '--diff-filter=A',
                                      '--name-only', '--since', since, '--', '*Facade.java'])
    new_facades = len(set(l for l in new_facades_str.splitlines() if 'Facade.java' in l))

    # AI 摘要
    recent = ""
    if log and commits_6mo > 5:
        recent = ai_summarize(log)

    results[svc] = {
        "commits_6mo": commits_6mo,
        "recent": recent,
        "new_facades": new_facades
    }

write_progress(total, total, "done", "complete")

# 写输出
with open(output_file, 'w', encoding='utf-8') as f:
    json.dump({
        "generated": datetime.datetime.now().strftime('%Y-%m-%d %H:%M'),
        "services": results
    }, f, ensure_ascii=False, indent=2)

print(f"done: {len([s for s in results.values() if s['recent']])} services with summaries")
PYTHON

# 重跑 gen_bizmap.py 合并
python3 "$HOME/Documents/one/projects/业务地图/gen_bizmap.py" > /dev/null 2>&1
echo "refresh complete"
