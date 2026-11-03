#!/bin/bash
# sync_to_aitable.sh — ReqFlow ↔ 钉钉 AI 表格「项目列表」同步
# 用法:
#   sync_to_aitable.sh check        — 返回每条需求的同步状态(含是否有字段变更)
#   sync_to_aitable.sh sync <名称>   — 同步单条(表内无则创建, 有则更新差异字段)
#   sync_to_aitable.sh sync-all     — 同步全部(只处理已关联/唯一同名/无相近名称的需求)
#   sync_to_aitable.sh link <名称> <recordId> — 用户确认后按需求 ID 记住对应记录
#   sync_to_aitable.sh create <名称>          — 用户确认相近记录都不是后新建
# 输出: JSON

set -e
PATH="$HOME/.qoderwork/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

MODE="${1:-check}"
REQ_NAME="${2:-}"
RECORD_ID="${3:-}"

python3 - "$MODE" "$REQ_NAME" "$RECORD_ID" <<'PYTHON'
import json, sys, subprocess, os, re, time, urllib.request, urllib.parse

mode = sys.argv[1]
req_name_arg = sys.argv[2] if len(sys.argv) > 2 else ""

PRD_CACHE = os.path.expanduser("~/.claude/prd-cache.json")
BASE_ID = "YQBnd5ExVEwGvKM7H20q9bEL8yeZqMmz"
TABLE_ID = "VLDMsZx"
MY_USER = {"userId": "03573762464021518029", "corpId": "dingda9cd6613d50209335c2f4657eb6378f"}
OWNER_MAP = {
    "林净": {"id": "MTYfsA5bON", "name": "林净"},
    "星楚": {"id": "M4y8HVjIsi", "name": "星楚"},
    "童骁宇": {"id": "gEWsm4WfqS", "name": "童骁宇"},
}
F_NAME = "q09vo80vu8jk58ji4tcve"
F_DESC = "9ecwymwxieunesq3yi8zs"
F_PRODUCT = "5wk2r4hd1pu68vixxhidh"
F_DOMAIN = "igc07gy7xzfwyeevioxcy"
F_DEV = "5a9b11ayzyn3jstht5piw"
F_TAG = "rIFWfrA"
F_SUBMIT = "bFrEeoF"          # 表内名称「PRD时间」，写入 PRD 提交时间
F_TEST = "jk9ldg5qo0yygn59a1s7k"   # 提测时间（只读展示）
F_MEMBERS = "jo7djz45nhy9s9lg1bthl"  # 其它成员（多选，按显示名）
MY_MEMBER_NAME = "周子涵(见山)"
F_DEVSTART = "ytyvw0nxs2lnfn71ijv2p"
F_ONLINE = "kl4zyxwyl3osdwk223bf0"

def dws_env():
    env = os.environ.copy()
    env['PATH'] = os.path.expanduser('~/.qoderwork/bin') + ':' + os.path.expanduser('~/.local/bin') + ':/opt/homebrew/bin:/usr/local/bin:' + env.get('PATH', '')
    return env

LINKS_PATH = os.path.expanduser("~/.claude/dboard-aitable-links.json")

class QueryFailed(Exception):
    pass

def dws_records():
    """全表记录: [{recordId, cells}, ...]。任一页失败即整体失败，绝不把部分结果当全表。"""
    out, cursor, seen = [], None, set()
    while True:
        cmd = ['dws', 'aitable', 'record', 'query',
            '--base-id', BASE_ID, '--table-id', TABLE_ID, '--limit', '100',
            '--field-ids', ','.join([F_NAME, F_DESC, F_PRODUCT, F_DOMAIN, F_DEV, F_TAG, F_SUBMIT, F_DEVSTART, F_ONLINE,
                                     F_TEST, F_MEMBERS])]
        if cursor:
            cmd.extend(['--cursor', cursor])
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=30, env=dws_env())
            d = json.loads(r.stdout)
        except Exception:
            raise QueryFailed("项目表查询失败")
        data = d.get('data') if isinstance(d, dict) else None
        if r.returncode != 0 or d.get('success') is not True or not isinstance(data, dict) \
                or not isinstance(data.get('records', []), list):
            raise QueryFailed("项目表查询失败")
        out.extend(data.get('records', []))
        cursor = data.get('nextCursor') or data.get('cursor')
        if not cursor:
            return out
        if cursor in seen:
            raise QueryFailed("项目表分页异常")
        seen.add(cursor)

def cell_text(v):
    if isinstance(v, list):
        v = v[0] if v else ''
    if isinstance(v, dict):
        v = v.get('name') or v.get('text') or ''
    return str(v or '')

def norm(name):
    return re.sub(r'\s+', '', name or '')

def load_links():
    try:
        with open(LINKS_PATH) as f:
            links = json.load(f)
        return links if isinstance(links, dict) else {}
    except FileNotFoundError:
        return {}

def save_link(req_id, record_id):
    links = load_links()
    links[str(req_id)] = record_id
    tmp = LINKS_PATH + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(links, f, ensure_ascii=False, indent=2)
    os.replace(tmp, LINKS_PATH)

def match_record(item, records, links):
    """返回 (状态, 记录, 候选)。只认已确认的 需求ID→recordId，或唯一的精确同名；相似名只作为待确认候选。"""
    linked = links.get(str(item.get('id', '')))
    if linked:
        rec = next((r for r in records if r.get('recordId') == linked), None)
        return ('linked', rec, []) if rec else ('missing-link', None, [])
    rn = norm(item.get('name'))
    exact = [r for r in records if rn and norm(cell_text(r.get('cells', {}).get(F_NAME))) == rn]
    if len(exact) == 1:
        return ('exact', exact[0], [])
    if len(exact) > 1:
        return ('ambiguous', None, exact)
    similar = []
    for r in records:
        en = norm(cell_text(r.get('cells', {}).get(F_NAME)))
        if en and rn and (rn in en or en in rn or any(en[i:i+4] in rn for i in range(len(en) - 3))):
            similar.append(r)
    return ('confirm', None, similar) if similar else ('none', None, [])

def candidates_json(recs):
    return [{"recordId": r.get('recordId', ''), "name": cell_text(r.get('cells', {}).get(F_NAME))} for r in recs[:5]]

def compress_desc(desc):
    if not desc:
        return ""
    prompt = f"直接输出一句话(20-50字)概括以下需求的问题和方案，不要任何前缀、标题、引号、markdown格式:\n{desc[:500]}"
    ai_path = os.path.expanduser("~/.local/bin/qoderclicn")
    try:
        r = subprocess.run([ai_path, '-m', 'Qwen3.7-Flash', '--tools', '',
            '--no-session-persistence', '-p', prompt],
            capture_output=True, text=True, timeout=30)
        if r.returncode == 0 and r.stdout.strip():
            import re
            text = r.stdout.strip()
            text = re.sub(r'^(压缩结果|摘要|概括|总结)[：:]\s*', '', text)
            text = re.sub(r'^[>#*\-\s]+', '', text)
            text = text.strip('"\'""''')
            return text.replace('"', "'")
    except Exception:
        pass
    return desc[:60]

def get_dev_start(item):
    """flow 时间只有 MM-dd；年份取提交时间，否则取本机当前年，不再写死。"""
    for f in (item.get('flow') or []):
        if '开发中' in f.get('to', ''):
            t = f.get('t', '')
            if re.match(r'^\d{4}-\d{2}-\d{2}', t):
                return t[:10]
            if re.match(r'^\d{2}-\d{2}', t):
                submit = item.get('submitTime') or ''
                year = submit[:4] if re.match(r'^\d{4}', submit) else time.strftime('%Y')
                return f"{year}-{t[:5]}"
    return ""

def expected_dynamic(item):
    """可更新的确定性字段(不含 AI 压缩的描述, 避免每次都被判为变更)"""
    return {
        F_SUBMIT: (item.get('submitTime') or '')[:10],
        F_DEVSTART: get_dev_start(item)[:10],
        F_ONLINE: (item.get('onlineTime') or '')[:10],
        F_PRODUCT: OWNER_MAP.get(item.get('owner', ''), OWNER_MAP.get("林净")),
    }

def diff_cells(rec, item):
    changes = {}
    cells = rec.get('cells', {})
    for fid, want in expected_dynamic(item).items():
        got = cells.get(fid, '')
        if fid == F_PRODUCT:
            if cell_text(got) != (want or {}).get('name', ''):
                changes[fid] = want
        else:
            want_s = want if isinstance(want, str) else ''
            # PRD 侧为空时不覆盖表内已有手工值(避免把别人的排期清掉)
            if want_s and want_s != cell_text(got)[:10]:
                changes[fid] = want
    return changes

def dws_update(record_id, changes):
    payload = json.dumps([{"recordId": record_id, "cells": changes}], ensure_ascii=False)
    r = subprocess.run(['dws', 'aitable', 'record', 'update',
        '--base-id', BASE_ID, '--table-id', TABLE_ID, '--records', payload],
        capture_output=True, text=True, timeout=30, env=dws_env())
    try:
        res = json.loads(r.stdout)
        return (r.returncode == 0 and res.get('success') is True,
                str(res.get('error', {}).get('message', '') or res.get('summary', ''))[:120])
    except Exception:
        return (False, f"{r.stdout[:60]} {r.stderr[:60]}")

def dws_create(item, desc_short):
    product = OWNER_MAP.get(item.get('owner', ''), OWNER_MAP.get("林净"))
    dev_start = get_dev_start(item)
    cells = {
        F_NAME: item['name'],
        F_DESC: desc_short,
        F_PRODUCT: product,
        F_DOMAIN: {"id": "bqE9QXXjAV", "name": "本地化"},
        F_DEV: [MY_USER],
        F_TAG: [{"id": "wYJkoIpDR6", "name": "OPT"}],
    }
    if item.get('submitTime'):
        cells[F_SUBMIT] = item['submitTime']
    if dev_start:
        cells[F_DEVSTART] = dev_start
    if item.get('onlineTime'):
        cells[F_ONLINE] = item['onlineTime']
    r = subprocess.run(['dws', 'aitable', 'record', 'create',
        '--base-id', BASE_ID, '--table-id', TABLE_ID, '--cells', json.dumps(cells, ensure_ascii=False)],
        capture_output=True, text=True, timeout=30, env=dws_env())
    try:
        result = json.loads(r.stdout)
        if r.returncode == 0 and result.get('success') is True:
            rid = (result.get('data', {}).get('newRecordIds') or [''])[0]
            return {"status": "ok", "recordId": rid}
        return {"status": "error", "message": result.get('error', {}).get('message', '')[:100]}
    except Exception:
        return {"status": "error", "message": f"{r.stdout[:50]} {r.stderr[:50]}"}

def sync_one(item, records, links, force_create=False):
    name = item['name']
    state, rec, candidates = match_record(item, records, links)
    if state == 'missing-link':
        return {"name": name, "status": "error", "message": "已关联的项目表记录不存在，未自动新建"}
    if state == 'ambiguous':
        return {"name": name, "status": "error", "message": "项目表里有多条同名记录，请先人工处理"}
    if state == 'confirm' and not force_create:
        return {"name": name, "status": "needs-confirm", "candidates": candidates_json(candidates)}
    if rec is None:
        r = dws_create(item, compress_desc(item.get('desc', '')))
        r["name"] = name
        if r.get("status") == "ok" and r.get("recordId") and item.get('id') is not None:
            save_link(item['id'], r['recordId'])
        return r
    if state == 'exact' and item.get('id') is not None:
        save_link(item['id'], rec.get('recordId', ''))
    changes = diff_cells(rec, item)
    if not changes:
        return {"name": name, "status": "skip", "message": "已是最新", "recordId": rec.get("recordId", "")}
    ok, msg = dws_update(rec.get("recordId", ""), changes)
    return {"name": name, "status": "updated" if ok else "error",
            "recordId": rec.get("recordId", ""), "fields": sorted(changes.keys()),
            "message": "" if ok else msg}

# 加载数据
try:
    prd = json.load(open(PRD_CACHE))
except Exception:
    print(json.dumps({"status": "error", "message": "无法读取 prd-cache.json"}, ensure_ascii=False))
    sys.exit(1)

mine_items = [i for i in prd.get('items', []) if 'mine' in i.get('scopes', [])]
try:
    records = dws_records()
    links = load_links()
except (QueryFailed, ValueError, OSError) as e:
    # 查询失败绝不当成"表里没有"，避免据此重复创建
    print(json.dumps({"status": "error", "message": str(e) or "项目表或本地关联读取失败"}, ensure_ascii=False))
    sys.exit(1)

def find_item(name):
    return next((i for i in mine_items if i['name'] == name), None)

def requirement_fields(item):
    rid = item.get('id')
    status = item.get('status') or item.get('currentStatusName')
    if not isinstance(rid, int) or isinstance(rid, bool) or rid <= 0 or not isinstance(status, str) or not status:
        return {}
    return {'requirementId': rid, 'requirementNo': item.get('no') or item.get('reqNo', ''),
            'requirementCode': item.get('code') or item.get('currentStatus', ''),
            'requirementStatus': status}

def table_requirement(rec):
    """状态来自已确认 ID 或唯一同名需求；仅补查无上线日期的历史项目，不修改远端。"""
    linked = [key for key, value in links.items() if value == rec.get('recordId')]
    if len(linked) > 1:
        return {}
    rid = None
    if linked:
        try:
            rid = int(linked[0])
            if rid <= 0:
                return {}
        except (ValueError, TypeError):
            return {}
        cached = next((item for item in prd.get('items', []) if item.get('id') == rid), None)
        if cached:
            return requirement_fields(cached)
    else:
        name = cell_text(rec.get('cells', {}).get(F_NAME))
        if not norm(name) or sum(norm(cell_text(row.get('cells', {}).get(F_NAME))) == norm(name)
                                 for row in records) != 1:
            return {}
        exact = [item for item in prd.get('items', []) if norm(item.get('name')) == norm(name)]
        if len(exact) == 1:
            return requirement_fields(exact[0])
        if exact:
            return {}
        online = cell_text(rec.get('cells', {}).get(F_ONLINE))[:10]
        if online and online <= time.strftime('%Y-%m-%d'):
            return {}
    try:
        with open(os.path.expanduser('~/.config/dboard/prd-cookie.txt')) as cookie_file:
            cookie = cookie_file.read().strip()
        if not cookie:
            return {}
        base = 'https://ai.tmallyc.com/prd/api/requirement'
        path = '/detail/' + str(rid) if rid else '/list?' + urllib.parse.urlencode(
            {'pageNum': 1, 'pageSize': 100, 'reqName': name})
        request = urllib.request.Request(base + path, headers={'Cookie': cookie})
        with urllib.request.urlopen(request, timeout=15) as response:
            payload = json.load(response)
        if not isinstance(payload, dict) or payload.get('success') is not True:
            return {}
        data = payload.get('data')
        if rid:
            return requirement_fields(data) if isinstance(data, dict) and data.get('id') == rid else {}
        if not isinstance(data, list) or int(payload.get('total', len(data))) > len(data):
            return {}
        exact = [item for item in data if isinstance(item, dict)
                 and norm(item.get('reqName') or item.get('name')) == norm(name)]
        return requirement_fields(exact[0]) if len(exact) == 1 else {}
    except (OSError, ValueError, TypeError):
        return {}

if mode == "check":
    results = []
    for item in mine_items:
        state, rec, _ = match_record(item, records, links)
        results.append({
            "name": item['name'],
            "synced": rec is not None,
            "changed": rec is not None and len(diff_cells(rec, item)) > 0,
            "needsConfirm": state in ('confirm', 'ambiguous', 'missing-link'),
            "status": item.get('status', ''),
        })
    print(json.dumps({"status": "ok", "items": results}, ensure_ascii=False))

elif mode in ("sync", "create", "link"):
    item = find_item(req_name_arg)
    if not item:
        print(json.dumps({"status": "error", "message": "找不到该需求"}, ensure_ascii=False))
        sys.exit(1)
    if mode == "link":
        record_id = sys.argv[3] if len(sys.argv) > 3 else ""
        rec = next((r for r in records if record_id and r.get('recordId') == record_id), None)
        if rec is None or item.get('id') is None:
            print(json.dumps({"status": "error", "message": "所选记录不存在"}, ensure_ascii=False))
            sys.exit(1)
        save_link(item['id'], record_id)
        links = load_links()
    print(json.dumps(sync_one(item, records, links, force_create=(mode == "create")), ensure_ascii=False))

elif mode == "sync-all":
    # 批量只处理能确定身份的需求；相似名一律留给单条确认
    results = []
    for item in mine_items:
        r = sync_one(item, records, links)
        results.append(r)
        if r['status'] == 'ok' and r.get('recordId'):
            records.append({"recordId": r['recordId'], "cells": {F_NAME: item['name']}})
            links = load_links()
    print(json.dumps({"status": "ok", "results": results}, ensure_ascii=False))

elif mode == "list-mine":
    out = []
    for rec in records:
        cells = rec.get('cells', {})
        devs = cells.get(F_DEV) or []
        if not isinstance(devs, list):
            devs = [devs]
        def names(v):
            if isinstance(v, list):
                return '、'.join(x.get('name', '') if isinstance(x, dict) else str(x) for x in v)
            return cell_text(v)
        # 「我参与的」= 主要负责人是我，或其它成员里有我
        is_owner = any(isinstance(d, dict) and d.get('userId') == MY_USER['userId'] for d in devs)
        is_member = MY_MEMBER_NAME in names(cells.get(F_MEMBERS)).split('、')
        if not (is_owner or is_member):
            continue
        out.append({
            **table_requirement(rec),
            'role': 'owner' if is_owner else 'member',
            'test': cell_text(cells.get(F_TEST))[:10],
            'recordId': rec.get('recordId', ''),
            'name': cell_text(cells.get(F_NAME)),
            'desc': re.sub(r'\s+', ' ', cell_text(cells.get(F_DESC)))[:160],
            'product': cell_text(cells.get(F_PRODUCT)),
            'domain': names(cells.get(F_DOMAIN)),
            'tags': names(cells.get(F_TAG)),
            'submit': cell_text(cells.get(F_SUBMIT))[:10],
            'devStart': cell_text(cells.get(F_DEVSTART))[:10],
            'online': cell_text(cells.get(F_ONLINE))[:10],
        })
    # 未上线置顶, 组内按最近日期倒序; 已上线在后按上线日倒序
    out.sort(key=lambda x: (x['online'] == '' or x['online'] > time.strftime('%Y-%m-%d'),
                            max(x['online'], x['test'], x['submit'], x['devStart'])), reverse=True)
    try:
        cache_p = os.path.expanduser('~/.claude/dboard-table-projects.json')
        with open(cache_p, 'w') as f:
            json.dump({'updated': time.strftime('%Y-%m-%d %H:%M:%S'), 'items': out},
                      f, ensure_ascii=False)
    except Exception:
        pass
    print(json.dumps({'status': 'ok', 'items': out, 'total': len(out)}, ensure_ascii=False))

else:
    print(json.dumps({"status": "error", "message": f"未知模式: {mode}"}, ensure_ascii=False))
PYTHON
