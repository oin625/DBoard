#!/bin/bash
# sync_to_aitable.sh — ReqFlow ↔ 钉钉 AI 表格「项目列表」同步
# 用法:
#   sync_to_aitable.sh check        — 返回每条需求的同步状态(含是否有字段变更)
#   sync_to_aitable.sh sync <名称>   — 同步单条(表内无则创建, 有则更新差异字段)
#   sync_to_aitable.sh sync-all     — 同步全部(未同步→创建, 有变更→更新)
# 输出: JSON

set -e
PATH="$HOME/.qoderwork/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

MODE="${1:-check}"
REQ_NAME="$2"

python3 - "$MODE" "$REQ_NAME" <<'PYTHON'
import json, sys, subprocess, os, re, time

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
F_SUBMIT = "bFrEeoF"
F_DEVSTART = "ytyvw0nxs2lnfn71ijv2p"
F_ONLINE = "kl4zyxwyl3osdwk223bf0"

def dws_env():
    env = os.environ.copy()
    env['PATH'] = os.path.expanduser('~/.qoderwork/bin') + ':' + os.path.expanduser('~/.local/bin') + ':/opt/homebrew/bin:/usr/local/bin:' + env.get('PATH', '')
    return env

def dws_records():
    """全表记录: [{recordId, cells}, ...]"""
    out, cursor = [], None
    while True:
        cmd = ['dws', 'aitable', 'record', 'query',
            '--base-id', BASE_ID, '--table-id', TABLE_ID, '--limit', '100',
            '--field-ids', ','.join([F_NAME, F_DESC, F_PRODUCT, F_DOMAIN, F_DEV, F_TAG, F_SUBMIT, F_DEVSTART, F_ONLINE])]
        if cursor:
            cmd.extend(['--cursor', cursor])
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30, env=dws_env())
        try:
            d = json.loads(r.stdout)
            recs = d.get('data', {}).get('records', [])
            out.extend(recs)
            cursor = d.get('data', {}).get('nextCursor') or d.get('data', {}).get('cursor')
            if not cursor or not recs:
                break
        except Exception:
            break
    return out

def cell_text(v):
    if isinstance(v, list):
        v = v[0] if v else ''
    if isinstance(v, dict):
        v = v.get('name') or v.get('text') or ''
    return str(v or '')

def match_record(name, records):
    rn = (name or '').replace(' ', '')
    for rec in records:
        en = cell_text(rec.get('cells', {}).get(F_NAME, '')).replace(' ', '')
        if not en:
            continue
        if rn == en or rn in en or en in rn:
            return rec
        for i in range(len(en) - 3):
            if en[i:i+4] in rn:
                return rec
    return None

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
    for f in (item.get('flow') or []):
        if '开发中' in f.get('to', ''):
            t = f.get('t', '')
            if len(t) >= 5:
                return f"2026-{t[:5]}"
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
        return (bool(res.get('success')), str(res.get('error', {}).get('message', '') or res.get('summary', ''))[:120])
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
        if result.get('success'):
            rid = result.get('data', {}).get('newRecordIds', [''])[0]
            return {"status": "ok", "recordId": rid}
        return {"status": "error", "message": result.get('error', {}).get('message', '')[:100]}
    except Exception:
        return {"status": "error", "message": f"{r.stdout[:50]} {r.stderr[:50]}"}

def sync_one(item, records):
    name = item['name']
    rec = match_record(name, records)
    if rec is None:
        r = dws_create(item, compress_desc(item.get('desc', '')))
        r["name"] = name
        return r
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
records = dws_records()

if mode == "check":
    results = []
    for item in mine_items:
        rec = match_record(item['name'], records)
        results.append({
            "name": item['name'],
            "synced": rec is not None,
            "changed": rec is not None and len(diff_cells(rec, item)) > 0,
            "status": item.get('status', ''),
        })
    print(json.dumps({"status": "ok", "items": results}, ensure_ascii=False))

elif mode == "sync":
    if not req_name_arg:
        print(json.dumps({"status": "error", "message": "缺少需求名称"}, ensure_ascii=False))
        sys.exit(1)
    item = next((i for i in mine_items if i['name'] == req_name_arg), None)
    if not item:
        print(json.dumps({"status": "error", "message": f"找不到: {req_name_arg}"}, ensure_ascii=False))
        sys.exit(1)
    print(json.dumps(sync_one(item, records), ensure_ascii=False))

elif mode == "sync-all":
    results = []
    for item in mine_items:
        r = sync_one(item, records)
        results.append(r)
        if r['status'] == 'ok' and r.get('recordId'):
            records.append({"recordId": r['recordId'], "cells": {F_NAME: item['name']}})
    print(json.dumps({"status": "ok", "results": results}, ensure_ascii=False))

elif mode == "list-mine":
    out = []
    for rec in records:
        cells = rec.get('cells', {})
        devs = cells.get(F_DEV) or []
        if not isinstance(devs, list):
            devs = [devs]
        if not any(isinstance(d, dict) and d.get('userId') == MY_USER['userId'] for d in devs):
            continue
        def names(v):
            if isinstance(v, list):
                return '、'.join(x.get('name', '') if isinstance(x, dict) else str(x) for x in v)
            return cell_text(v)
        out.append({
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
    # 进行中(未上线)置顶, 组内按最近日期倒序; 已上线在后按上线日倒序
    out.sort(key=lambda x: (x['online'] == '',
                            max(x['online'], x['submit'], x['devStart'])), reverse=True)
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
