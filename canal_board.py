#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
三渠统一状态板（v2 重做）

旧版试图把代码「逐步解说」成流程图，结果全是噪音。重做只给四类信号：
  1. 状态矩阵  7 平台 × 6 阶段，每格只有：状态 + 定制行数 + 位置
  2. 偏离清单  哪些 平台·阶段 没走统一、自己定制了（三渠统一治理的真正关注点）
  3. 施工清单  TODO/FIXME 的真实位置
  4. 入口事实  Facade 公共层方法落点、核销后创单平台集合

数据基线：Ultra 读工作区；Tesla 读 origin/three-canals-unified-0615（git show，分支感知）。
用法：python3 canal_board.py → 生成 /tmp/canal_board.html，直接打开即可。
"""
import os
import re
import subprocess
from datetime import datetime

ULTRA = os.path.expanduser("~/work/code/ultra")
TESLA = os.path.expanduser("~/work/code/tesla")
LIFE = os.path.join(
    ULTRA, "ultra-core/src/main/java/com/tmallyc/ultra/application/offline/life"
)
UNIFY = os.path.join(LIFE, "unify")
SHANGOU = os.path.join(
    ULTRA, "ultra-core/src/main/java/com/tmallyc/ultra/application/shangou"
)
TESLA_TRI = os.path.join(
    TESLA, "tesla-main/src/main/java/com/tmallyc/tesla/business/tripartite"
)
TESLA_REFS = ("origin/three-canals-unified-0615", "three-canals-unified-0615")
OUT = "/tmp/canal_board.html"

# 链路阶段（横轴）。cands = 该方法在平台 Flow 上的候选名（新名优先、旧名兜底）。
STAGES = [
    {"key": "issue", "label": "发码"},
    {"key": "queryCoupon", "label": "查券", "cands": ("queryCoupon",),
     "fcands": ("routeCode", "queryCoupon")},
    {"key": "consultVerify", "label": "验券",
     "cands": ("queryCodeContent", "consultVerify")},
    {"key": "executeUse", "label": "核销", "cands": ("writeOff", "executeUse")},
    {"key": "createOrder", "label": "创单"},
    {"key": "refund", "label": "退款", "cands": ("refund",)},
]

# 发码实现归属（人工核定、已在代码逐条验证的事实）：
#   spi  = 三方回调我方接口；pull = 无回调、验券时主动查；none = 无发码环节
ISSUE_MAP = {
    "SHANGOU": {
        "mode": "spi", "repo": "ultra",
        "abs": os.path.join(SHANGOU, "spi/ShangouSpiController.java"),
        "entry": "handleCallback", "route": "POST /spi/shangou",
        "note": "闪购发码在 Ultra：SPI 回调 → processCouponSend",
    },
    "MEITUAN": {
        "mode": "spi", "repo": "tesla",
        "abs": os.path.join(TESLA_TRI, "controller/MeituanController.java"),
        "entry": "thirdPartyReceiptSend",
        "route": "POST /meituan/dzopen/thirdpartyreceipt/send",
        "note": "美团发码回调在 Tesla（扫三渠分支）",
    },
    "KUAISHOU": {
        "mode": "spi", "repo": "tesla",
        "abs": os.path.join(TESLA_TRI, "kuaishou/KuaishouController.java"),
        "entry": "grantVoucher", "route": "POST /kuaishou/grantVoucher",
        "note": "快手发码回调在 Tesla（扫三渠分支）",
    },
    "DOUYIN": {"mode": "pull",
               "note": "抖音无发码回调：验券时 certificatePrepare 主动查"},
    "GAODE": {"mode": "pull",
              "note": "高德无发码回调：验券时 getOrderByVerificationCode 主动查"},
    "CDD": {"mode": "none", "note": "车点点无发码环节（券由车点点侧发）"},
    "DKH": {"mode": "none", "note": "大客户无发码环节（核销码由企业购下发）"},
}

# 平台 Flow 文件（纵轴顺序）
FLOWS = [
    ("MEITUAN", "美团", "meituan/MeituanThirdUnifyFlow.java"),
    ("GAODE", "高德", "gaode/GaodeThirdUnifyFlow.java"),
    ("KUAISHOU", "快手", "kuaishou/KuaishouThirdUnifyFlow.java"),
    ("DOUYIN", "抖音来客", "douyin/DouyinThirdUnifyFlow.java"),
    ("CDD", "车点点", "cdd/CddThirdUnifyFlow.java"),
    ("SHANGOU", "闪购", "shangou/ShangouThirdUnifyFlow.java"),
    ("DKH", "大客户", "dkh/DkhThirdUnifyFlow.java"),
]


def read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def run(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True,
                              timeout=20).stdout.strip()
    except Exception:
        return ""


TESLA_REF = None


def tesla_ref():
    global TESLA_REF
    if TESLA_REF is None:
        for r in TESLA_REFS:
            if run(["git", "-C", TESLA, "rev-parse", "--verify", "--quiet", r]):
                TESLA_REF = r
                break
        TESLA_REF = TESLA_REF or ""
    return TESLA_REF or None


def tesla_read(rel):
    ref = tesla_ref()
    if ref:
        out = run(["git", "-C", TESLA, "show", "%s:%s" % (ref, rel)])
        if out:
            return out
    return read(os.path.join(TESLA, rel))


def method_bodies(src):
    """切出每个方法体（带行号/行数）。花括号配平，接口无体方法记 abstract。"""
    out = {}
    lines = src.split("\n")
    sig = re.compile(r"^\s*(?:public|private|protected|default)\s+"
                     r"[\w<>,\[\]\.\s\?]+\s+(\w+)\s*\(")
    for i, line in enumerate(lines):
        m = sig.match(line)
        if not m:
            continue
        depth, started, body = 0, False, []
        for j in range(i, min(len(lines), i + 500)):
            body.append(lines[j])
            depth += lines[j].count("{") - lines[j].count("}")
            if "{" in lines[j]:
                started = True
            if started and depth <= 0:
                break
        if not started:
            out.setdefault(m.group(1), {"line": i + 1, "lines": 0, "body": ""})
            continue
        key = m.group(1) if m.group(1) not in out else "%s__%d" % (m.group(1), i)
        out[key] = {"line": i + 1, "lines": len(body), "body": "\n".join(body)}
    return out


def find_method(bodies, cands):
    """候选名优先；重载取最长体。返回 (名字, info) 或 None。"""
    for cand in cands:
        hits = [v for k, v in bodies.items()
                if (k == cand or k.startswith(cand + "__")) and v["body"]]
        if hits:
            return cand, max(hits, key=lambda v: v["lines"])
    return None


def classify(info):
    body = info["body"]
    inner = body.split("{", 1)[1] if "{" in body else body
    if "UnsupportedOperationException" in inner:
        stmts = [s for s in inner.split("\n")
                 if s.strip() and s.strip() not in ("{", "}")]
        if len(stmts) <= 2:
            return "broken"
    if re.search(r"\bTODO\b|\bFIXME\b", body):
        return "todo"
    return "full"


def esc(s):
    return (s or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def scan():
    iface_src = read(os.path.join(UNIFY, "flow/ThirdUnifyFlow.java"))
    iface_default = set(re.findall(
        r"^\s*default\s+[\w<>,\[\]\.\s\?]+\s+(\w+)\s*\(", iface_src, re.M))

    fac_src = read(os.path.join(LIFE, "ThirdUnifyFacadeImpl.java"))
    fac_bodies = method_bodies(fac_src)
    facade = []
    for st in STAGES:
        hit = find_method(fac_bodies, st.get("fcands") or st.get("cands") or ())
        if hit:
            facade.append({"stage": st["label"], "method": hit[0],
                           "line": hit[1]["line"], "lines": hit[1]["lines"]})
    m = re.search(r"TIME_RESTRICTED_PLATFORMS\s*=\s*Set\.of\((.*?)\);",
                  fac_src, re.S)
    create_platforms = set(re.findall(r"ThirdPlatformEnum\.(\w+)",
                                      m.group(1))) if m else set()

    platforms = []
    deviations = []
    for key, cn, rel in FLOWS:
        raw = read(os.path.join(LIFE, rel))
        bodies = method_bodies(raw) if raw else {}
        cells, custom_loc = {}, 0
        for st in STAGES:
            k = st["key"]
            if k == "issue":
                info = ISSUE_MAP.get(key, {"mode": "none"})
                mode = info.get("mode", "none")
                if mode == "spi":
                    src = (tesla_read(os.path.relpath(info["abs"], TESLA))
                           if info["repo"] == "tesla"
                           else read(info["abs"]))
                    hit = find_method(method_bodies(src), (info["entry"],))
                    cells[k] = {"state": "callback" if hit else "missing",
                                "route": info["route"], "note": info["note"],
                                "line": hit[1]["line"] if hit else None}
                elif mode == "pull":
                    cells[k] = {"state": "pull", "note": info["note"]}
                else:
                    cells[k] = {"state": "none", "note": info["note"]}
            elif k == "createOrder":
                cells[k] = {"state": "in" if key in create_platforms else "out"}
            else:
                hit = find_method(bodies, st["cands"])
                if hit:
                    state = classify(hit[1])
                    cells[k] = {"state": state, "method": hit[0],
                                "line": hit[1]["line"], "lines": hit[1]["lines"]}
                    custom_loc += hit[1]["lines"]
                    if state in ("full", "todo", "broken"):
                        deviations.append({
                            "cn": cn, "stage": st["label"], "method": hit[0],
                            "line": hit[1]["line"], "lines": hit[1]["lines"],
                            "state": state})
                elif any(c in iface_default for c in st["cands"]):
                    cells[k] = {"state": "default"}
                else:
                    cells[k] = {"state": "none"}
        platforms.append({"key": key, "cn": cn, "file": rel,
                          "loc": raw.count("\n") + 1, "custom": custom_loc,
                          "cells": cells})

    deviations.sort(key=lambda x: -x["lines"])
    todos = []
    for root, _, files in os.walk(LIFE):
        for fn in sorted(files):
            if not fn.endswith(".java"):
                continue
            p = os.path.join(root, fn)
            for i, line in enumerate(read(p).split("\n"), 1):
                if re.search(r"\bTODO\b|\bFIXME\b", line):
                    todos.append({"file": os.path.relpath(p, LIFE), "line": i,
                                  "text": line.strip().lstrip("/*").strip()[:120]})

    return {
        "generated": datetime.now().strftime("%Y-%m-%d %H:%M"),
        "ultra": {
            "branch": run(["git", "-C", ULTRA, "branch", "--show-current"]),
            "head": run(["git", "-C", ULTRA, "log", "-1",
                         "--format=%h %ad %s", "--date=format:%Y-%m-%d"]),
            "dirty": bool(run(["git", "-C", ULTRA, "status", "--porcelain"])),
        },
        "tesla": {
            "ref": tesla_ref() or "(无，回退工作区)",
            "head": run(["git", "-C", TESLA, "log", "-1", "--format=%h %ad",
                         "--date=format:%Y-%m-%d",
                         tesla_ref() or "HEAD"]),
        },
        "platforms": platforms,
        "deviations": deviations,
        "facade": facade,
        "todos": todos,
    }


STATE_LABEL = {
    "full": "定制", "todo": "施工中", "broken": "断路", "default": "接口默认",
    "none": "—", "callback": "回调", "pull": "主动查", "missing": "回调源未找到",
    "in": "核销后创单", "out": "—",
}
STATE_CLS = {
    "full": "ok", "todo": "warn", "broken": "bad", "default": "def",
    "none": "none", "callback": "cb", "pull": "pull", "missing": "bad",
    "in": "ok", "out": "none",
}


def cell_html(c):
    st = c["state"]
    if st in ("full", "todo", "broken"):
        txt = "%s %d行 L%d" % (STATE_LABEL[st], c["lines"], c["line"])
    elif st == "callback":
        txt = "回调 %s" % esc(c["route"])
    else:
        txt = STATE_LABEL[st]
    return '<td class="%s" title="%s">%s</td>' % (
        STATE_CLS[st], esc(c.get("note") or c.get("method") or ""), txt)


def render(d):
    rows = []
    for p in d["platforms"]:
        tds = "".join(cell_html(p["cells"][st["key"]]) for st in STAGES)
        rows.append('<tr><th>%s</th>%s<td class="num">%d</td></tr>'
                    % (esc(p["cn"]), tds, p["custom"]))
    matrix = "".join(rows)

    dev = "".join(
        '<li><b>%s · %s</b> %s() L%d · 定制 %d 行%s</li>'
        % (esc(x["cn"]), x["stage"], x["method"], x["line"], x["lines"],
           '（施工中）' if x["state"] == "todo"
           else '（断路）' if x["state"] == "broken" else "")
        for x in d["deviations"]) or "<li>无偏离，全平台走统一实现</li>"

    todo = "".join('<li>%s:%d %s</li>' % (esc(t["file"]), t["line"], esc(t["text"]))
                   for t in d["todos"]) or "<li>无 TODO</li>"

    fac = "".join('<li>%s → %s() L%d · %d 行</li>'
                  % (f["stage"], f["method"], f["line"], f["lines"])
                  for f in d["facade"]) or "<li>Facade 未解析到方法</li>"

    return """<!doctype html><html lang="zh"><head><meta charset="utf-8">
<title>三渠统一状态板</title>
<style>
body{font:14px/1.6 -apple-system,"PingFang SC",sans-serif;margin:24px;color:#222}
h1{font-size:20px} h2{font-size:16px;margin:28px 0 8px}
.meta{color:#666;font-size:12px}
table{border-collapse:collapse;margin-top:8px}
th,td{border:1px solid #ccc;padding:4px 10px;font-size:13px;text-align:left}
th{background:#f5f5f5}
td.ok{color:#2e7d32} td.warn{color:#ef6c00} td.bad{color:#c62828}
td.def{color:#757575} td.none{color:#bbb} td.cb{color:#1565c0} td.pull{color:#6a1b9a}
td.num{color:#999;text-align:right}
li{margin:2px 0} code{font:12px ui-monospace,monospace}
</style></head><body>
<h1>三渠统一状态板</h1>
<div class="meta">生成 %s ｜ Ultra <code>%s @ %s%s</code> ｜ Tesla <code>%s @ %s</code></div>
<h2>状态矩阵（平台 × 阶段）</h2>
<table><tr><th>平台</th>%s<th>定制行数</th></tr>%s</table>
<h2>偏离清单（没走统一、自己定制的 平台·阶段）</h2>
<ul>%s</ul>
<h2>施工清单（TODO/FIXME）</h2>
<ul>%s</ul>
<h2>Facade 公共层入口</h2>
<ul>%s</ul>
</body></html>""" % (
        d["generated"],
        esc(d["ultra"]["branch"]), esc(d["ultra"]["head"]),
        "（脏）" if d["ultra"]["dirty"] else "",
        esc(d["tesla"]["ref"]), esc(d["tesla"]["head"]),
        "".join("<th>%s</th>" % s["label"] for s in STAGES),
        matrix, dev, todo, fac)


def main():
    d = scan()
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(render(d))
    print("平台 %d，偏离 %d 处，TODO %d 处，Facade 方法 %d 个"
          % (len(d["platforms"]), len(d["deviations"]), len(d["todos"]),
             len(d["facade"])))
    print("✓ 已生成 → %s（直接打开即可）" % OUT)


if __name__ == "__main__":
    main()
