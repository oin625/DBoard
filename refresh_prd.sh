#!/bin/bash
# refresh_prd.sh — 从 ai.tmallyc.com PRD 系统拉取活跃需求数据
set -e

OUT="$HOME/.claude/prd-cache.json"
TMP="$OUT.tmp.$$"
PATH="$HOME/.qoderwork/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
COOKIE_FILE="$HOME/.config/dboard/prd-cookie.txt"

if [ ! -f "$COOKIE_FILE" ]; then
    echo "ERROR: 缺少 cookie 文件 $COOKIE_FILE" >&2
    exit 1
fi
COOKIE=$(cat "$COOKIE_FILE")

python3 - "$TMP" "$COOKIE" <<'PYTHON'
import json, sys, urllib.request, urllib.error, datetime

out_path = sys.argv[1]
cookie = sys.argv[2].strip()
base = "https://ai.tmallyc.com/prd/api/requirement"

AUTH_MSGS = ('未登录', '会话已过期')

def die_auth():
    print("ERROR: cookie 过期，请重新登录 ai.tmallyc.com 并更新 ~/.config/dboard/prd-cookie.txt", file=sys.stderr)
    sys.exit(2)

def api_get(path, params_str=""):
    url = base + path
    if params_str:
        url += '?' + params_str
    req = urllib.request.Request(url, headers={'Cookie': cookie})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read()
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            die_auth()
        raise
    try:
        data = json.loads(body)
    except (ValueError, UnicodeDecodeError):
        # 返回的不是 JSON（多半是登录页 HTML），视为登录态失效
        die_auth()
    if not isinstance(data, dict):
        return data
    if data.get('success') is False and any(m in (data.get('message') or '') for m in AUTH_MSGS):
        die_auth()
    return data

# 活跃状态过滤
ACTIVE_FILTER = "currentStatusList=YTJ&currentStatusList=YJSR&currentStatusList=FASJWC&currentStatusList=KFZ&currentStatusList=KFWC&currentStatusList=YCS&currentStatusList=CSWC&currentStatusList=CPYSZ&currentStatusList=CPYSWC"

# 拉取"我的"需求：待处理 + 进行中 + 组内 + 角色相关
all_items = []
seen_ids = set()

def add_items(items, scope=None):
    for item in items:
        rid = item.get('id')
        if rid and rid not in seen_ids:
            seen_ids.add(rid)
            if scope:
                item['_scope'] = scope
            all_items.append(item)
        elif scope and rid in seen_ids:
            for existing in all_items:
                if existing.get('id') == rid and scope not in existing.get('_scopes', []):
                    existing.setdefault('_scopes', []).append(scope)

# 1) 待我处理
resp = api_get('/myPendingList', 'pageNum=1&pageSize=100')
if resp.get('success'):
    add_items(resp.get('data') or [], scope='pending')
    print(f"  myPending: {resp.get('total', 0)}", file=sys.stderr)

# 2) 我在跟进
resp = api_get('/myInProgressList', 'pageNum=1&pageSize=100')
if resp.get('success'):
    add_items(resp.get('data') or [], scope='mine')
    print(f"  myInProgress: {resp.get('total', 0)}", file=sys.stderr)

# 3) 组内活跃需求（车主组 1004500）
page = 1
while True:
    resp = api_get('/list', f'pageNum={page}&pageSize=50&roleDeptNoList=1004500&{ACTIVE_FILTER}')
    if not resp.get('success'): break
    items = resp.get('data') or []
    add_items(items, scope='dept')
    total = resp.get('total', 0)
    print(f"  dept page {page}: +{len(items)}/{total}", file=sys.stderr)
    if page * 50 >= total or not items: break
    page += 1

# 4) 我参与的角色相关（用工号 711280），仅活跃状态
ACTIVE_FILTER = "currentStatusList=YTJ&currentStatusList=YJSR&currentStatusList=FASJWC&currentStatusList=KFZ&currentStatusList=KFWC&currentStatusList=YCS&currentStatusList=CSWC&currentStatusList=CPYSZ&currentStatusList=CPYSWC"
page = 1
while True:
    resp = api_get('/list', f'pageNum={page}&pageSize=50&rolePersonName=711280&{ACTIVE_FILTER}')
    if not resp.get('success'): break
    items = resp.get('data') or []
    add_items(items, scope='mine')
    total = resp.get('total', 0)
    print(f"  myRole page {page}: +{len(items)}/{total}", file=sys.stderr)
    if page * 50 >= total or not items: break
    page += 1

print(f"拉到 {len(all_items)} 条活跃需求", file=sys.stderr)

# 对最近更新的需求拉 detail 获取 flowLog（限前30条，避免太慢）
sorted_items = sorted(all_items, key=lambda x: x.get('createTime') or '', reverse=True)
for i, item in enumerate(sorted_items[:30]):
    rid = item.get('id')
    if not rid: continue
    try:
        dr = api_get(f'/detail/{rid}')
        if dr.get('success') and dr.get('data'):
            item['flowLog'] = dr['data'].get('flowLog')
    except:
        pass
    if (i + 1) % 10 == 0:
        print(f"  detail {i+1}/30...", file=sys.stderr)
print(f"  拉取 detail 完成（前30条有 flowLog）", file=sys.stderr)

# 转换格式
output_items = []
for item in all_items:
    flow_log = item.get('flowLog') or []
    flow = []
    for f in flow_log:
        t = (f.get('operateTime') or '')
        if len(t) >= 11:
            t = t[5:16]
        name = f.get('operatorName') or ''
        if ' - ' in name:
            name = name.split(' - ')[-1]
        flow.append({
            't': t,
            'from': f.get('fromStatusName', ''),
            'to': f.get('toStatusName', ''),
            'by': name
        })

    def clean_name(n):
        if not n: return ''
        return n.split(' - ')[-1] if ' - ' in n else n

    def strip_html(s):
        if not s: return ''
        import re
        s = re.sub(r'<br\s*/?>|</p>|</li>', '\n', s)
        s = re.sub(r'<[^>]+>', '', s)
        s = re.sub(r'&nbsp;', ' ', s)
        s = re.sub(r'&amp;', '&', s)
        s = re.sub(r'&lt;', '<', s)
        s = re.sub(r'&gt;', '>', s)
        s = re.sub(r'&quot;', '"', s)
        s = re.sub(r'\n{3,}', '\n\n', s)
        return s.strip()

    scopes = []
    if item.get('_scope'): scopes.append(item['_scope'])
    scopes.extend(item.get('_scopes', []))
    scopes = list(set(scopes)) or ['mine']

    output_items.append({
        'id': item.get('id'),
        'no': item.get('reqNo', ''),
        'name': item.get('reqName', '') or item.get('name', ''),
        'code': item.get('currentStatus', ''),
        'status': item.get('currentStatusName', ''),
        'pri': item.get('priority', ''),
        'dev': clean_name(item.get('devLeadName', '')),
        'scopes': scopes,
        'desc': strip_html(item.get('description', '') or ''),
        'value': item.get('businessValue', '') or '',
        'complexity': str(item.get('complexity', '')) if item.get('complexity') else '',
        'submitter': clean_name(item.get('submitterName', '')),
        'owner': clean_name(item.get('ownerName', '') or item.get('devLeadName', '')),
        'pending': clean_name(item.get('pendingPersonName', '')),
        'devTeam': [clean_name(x) for x in (item.get('devTeam') or '').split(',') if x.strip()] if isinstance(item.get('devTeam'), str) else [],
        'testTeam': [clean_name(x) for x in (item.get('testTeam') or '').split(',') if x.strip()] if isinstance(item.get('testTeam'), str) else [],
        'submitTime': (item.get('createTime') or '')[:10],
        'onlineTime': (item.get('onlineTime') or '')[:10],
        'tags': item.get('tags', '') or '',
        'flow': flow,
        'docs': [],
        'services': [],
        'confidence': '',
        'note': '',
        'url': f"https://ai.tmallyc.com/prd/index.html#detail/{item.get('id')}",
        'delivDocs': [],
        'files': [],
        'devProjects': []
    })

if not all_items:
    print("ERROR: 接口未返回任何活跃需求，疑似登录态失效或接口变更，放弃写入以免清空缓存", file=sys.stderr)
    sys.exit(3)

result = {
    'generated': datetime.datetime.now().strftime('%Y-%m-%d %H:%M'),
    'source': 'ai.tmallyc.com/prd API (auto-refresh)',
    'scopeLabels': {'pending': '待接', 'mine': '我参与', 'dept': '组内'},
    'items': output_items
}

with open(out_path, 'w', encoding='utf-8') as f:
    json.dump(result, f, ensure_ascii=False, indent=2)

print(f"OK: {len(output_items)} items → {out_path}", file=sys.stderr)
PYTHON

mv "$TMP" "$OUT"

# 重跑 gen_bizmap.py 更新 bizmap-cache.json
GEN="$HOME/Documents/one/projects/业务地图/gen_bizmap.py"
[ -f "$GEN" ] && python3 "$GEN" > /dev/null 2>&1

echo "done"
