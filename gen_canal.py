#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
三渠统一 Canal 视角数据生成器 —— 只从 Ultra 源码扫，不读方案文档。

产出 ~/.claude/canal-cache.json，供 DBoard 的 Canal 视角渲染。
设计原则（与 gen_bizmap.py 同族）：脚本写事实，人看渲染。
只读 Ultra 仓库，不修改被扫代码。

矩阵 = 链路阶段(横轴) × 平台(纵轴)，每格状态从代码判定：
  full    override 且无 Unsupported          实心
  todo    override 但方法体内有 TODO/FIXME    施工中
  broken  override 但方法体基本只抛 Unsupported 断路
  default 未 override，走接口 default 实现    空心
  absent  该平台不参与此阶段
"""
import json
import os
import re
import subprocess
import sys
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
ULTRA_LIFE_REL = ("ultra-core/src/main/java/com/tmallyc/ultra/"
                  "application/offline/life")
# Tesla 扫描基线：三渠开发分支。工作区可能停在别的功能分支（实测发码文件等同 master）
# 且可能有脏文件，故用 git show 读该分支内容，不碰工作区、不受 checkout 影响。
TESLA_SCAN_REF_CANDIDATES = ("origin/three-canals-unified-0615",
                             "three-canals-unified-0615")
OUT = os.path.expanduser("~/.claude/canal-cache.json")

# 链路阶段（横轴）：对齐 ThirdUnifyFlow 接口方法的真实调用顺序。
# 发码在链路最前（有券才有后续），但它不在 ThirdUnifyFlow 上 ——
# Flow.sendCoupon 只是个回调薄壳（美高仅 log+parseJSON），真正的发码实现按渠道散落在
# Ultra(闪购 SPI) 与 Tesla(美团/快手 回调) 两个仓库；抖音/高德无回调，靠验券时主动查。
STAGES = [
    {"key": "issue",         "label": "发码", "method": None},
    {"key": "queryCoupon",   "label": "查券", "method": "queryCoupon"},
    {"key": "consultVerify", "label": "验券", "method": "consultVerify"},
    {"key": "executeUse",    "label": "核销", "method": "executeUse"},
    {"key": "createOrder",   "label": "创单", "method": None},  # 不在 Flow 上，由 MQ+Service 承接
    {"key": "refund",        "label": "退款", "method": "refund"},
]

# 发码实现归属（人工核定的跨仓事实，已逐条在代码中验证）：
#   mode  = spi(三方回调我方接口) / pull(无回调，验券时主动查) / none(不涉及)
#   repo  = 实现所在仓库；file/entry = 入口位置
ISSUE_MAP = {
    "SHANGOU": {
        "mode": "spi", "repo": "ultra",
        # 入口改到 SPI Controller：发码第一步就是三方回调打进来，
        # processCouponSend 由委派展开机制自动挂成下钻层
        "abs": os.path.join(SHANGOU, "spi/ShangouSpiController.java"),
        "entry": "handleCallback",
        "route": "POST /spi/shangou",
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
        "entry": "grantVoucher",
        "route": "POST /kuaishou/grantVoucher",
        "note": "快手发码回调在 Tesla（扫三渠分支）",
    },
    "DOUYIN": {
        "mode": "pull", "repo": None, "file": None, "abs": None, "entry": None,
        "route": None,
        "note": "抖音无发码回调：验券时 certificatePrepare 主动查",
    },
    "GAODE": {
        "mode": "pull", "repo": None, "file": None, "abs": None, "entry": None,
        "route": None,
        "note": "高德无发码回调：验券时 getOrderByVerificationCode 主动查",
    },
    "CDD": {"mode": "none", "note": "车点点无发码环节（券由车点点侧发）"},
    "DKH": {"mode": "none", "note": "大客户无发码环节（核销码由企业购下发）"},
}

# 平台 Flow 文件位置（纵轴顺序：四渠道在前，车点点当前重心，闪购/大客户垫底）
FLOWS = [
    ("MEITUAN",  "美团",     "meituan/MeituanThirdUnifyFlow.java"),
    ("GAODE",    "高德",     "gaode/GaodeThirdUnifyFlow.java"),
    ("KUAISHOU", "快手",     "kuaishou/KuaishouThirdUnifyFlow.java"),
    ("DOUYIN",   "抖音来客",  "douyin/DouyinThirdUnifyFlow.java"),
    ("CDD",      "车点点",    "cdd/CddThirdUnifyFlow.java"),
    ("SHANGOU",  "闪购",     "shangou/ShangouThirdUnifyFlow.java"),
    ("DKH",      "大客户",    "dkh/DkhThirdUnifyFlow.java"),
]


def read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


TESLA_SCAN_REF = None   # 延迟解析；无则回退工作区并在缓存里标明


def resolve_tesla_ref():
    global TESLA_SCAN_REF
    if TESLA_SCAN_REF is not None:
        return TESLA_SCAN_REF
    for ref in TESLA_SCAN_REF_CANDIDATES:
        ok = subprocess.run(
            ["git", "-C", TESLA, "rev-parse", "--verify", "--quiet", ref],
            capture_output=True, text=True, timeout=20,
        ).returncode == 0
        if ok:
            TESLA_SCAN_REF = ref
            return ref
    TESLA_SCAN_REF = ""   # 回退：直接读工作区
    return TESLA_SCAN_REF


def repo_rel(path):
    """绝对路径 → (仓名, 仓内相对路径)；不在两仓内返 (None, path)。"""
    for name, root in (("ultra", ULTRA), ("tesla", TESLA)):
        if path.startswith(root + os.sep):
            return name, os.path.relpath(path, root)
    return None, path


def read_src(path):
    """
    读源码的唯一入口：
    - Ultra：读工作区（当前开发分支 feature/che-dian-dian，工作区干净）
    - Tesla：git show 三渠分支内容。工作区停在其他功能分支且有脏文件，
      发码文件实测等同 master，直接读会拿到错版本。
    """
    repo, rel = repo_rel(path)
    if repo == "tesla":
        ref = resolve_tesla_ref()
        if ref:
            r = subprocess.run(
                ["git", "-C", TESLA, "show", "%s:%s" % (ref, rel)],
                capture_output=True, text=True, timeout=20,
            )
            if r.returncode == 0:
                return r.stdout
    return read(path)


def stamp_file(steps, rel):
    """给节点盖源文件戳（仓内相对路径）：双击复制 文件:行号 用。不覆盖子层已有戳。"""
    for s in steps:
        if "file" not in s:
            s["file"] = rel


def git(*args):
    return git_in(ULTRA, *args)


def git_in(repo, *args):
    try:
        return subprocess.run(
            ["git", "-C", repo, *args],
            capture_output=True, text=True, timeout=20,
        ).stdout.strip()
    except Exception:
        return ""


def strip_comments(src):
    """去块注释和行注释：注释里的 TODO 和方法名会污染判定。"""
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    return re.sub(r"//[^\n]*", "", src)


# ---------- 操作语义分类：后端接口逻辑的词汇表 ----------
# 校验/取数/写入/更新/删除/发MQ/加锁/调用，基本闭合。
# op 由方法名动词判定，target 由接收者类型判定（EsDao=ES / Reference=Dubbo …）。

def classify_op(recv, meth):
    target = None
    if recv:
        if re.search(r"(EsDao|Dao|Mapper|Repository)$", recv):
            target = "ES"
        elif re.search(r"Reference$", recv):
            target = "Dubbo"
        elif re.search(r"(ApiClient|Api)$", recv):
            target = "三方"
        elif re.search(r"[Rr]edis", recv):
            target = "Redis"
        elif re.search(r"(Producer|MQ|Mq)", recv):
            target = "MQ"
        elif re.search(r"(Service|Helper|Controller)$", recv):
            target = "内部"
    if re.match(r"(send\w*(MQ|Mq|Msg|Message)|publish|emit)", meth) or target == "MQ":
        return "mq", "MQ"
    if re.match(r"(get)?(lock|tryLock|unlock|Lock)", meth) \
            or (recv and re.search(r"[Rr]edisson", recv)):
        return "lock", "Redis"
    # 跨服务调用不按动词归取/写：调交易中心 createOrder 是 RPC，不是落自己的库
    if target == "Dubbo":
        return "rpc", "Dubbo"
    if target == "三方":
        return "http", "三方"
    if re.match(r"(insert|save|upsert|add|create|write|record|persist|append|generateAndSave\w*)", meth):
        return "write", target
    if re.match(r"(update|modify|rollback|mark|refresh|close|cancel|invalid|writeBack)", meth):
        return "update", target
    if re.match(r"(delete|remove|clear)", meth):
        return "delete", target
    if re.match(r"(get|query|search|list|find|count|select|load|fetch|page|resolve|parse|match|is[A-Z]|has[A-Z]|exists)", meth):
        return "read", target
    return "invoke", target


def locate_body(raw_src, method):
    """在原始源码里定位方法体（含注释），返 [(行号, 文本)]。含私有方法。"""
    lines = raw_src.split("\n")
    sig = re.compile(r"^\s*(?:public|private|protected|default)\s+[\w<>,\[\]\.\s\?]+\s+%s\s*\("
                     % re.escape(method))
    best = None
    for i, line in enumerate(lines):
        if not sig.match(line):
            continue
        depth, started, body = 0, False, []
        for j in range(i, min(len(lines), i + 500)):
            body.append((j + 1, lines[j]))
            depth += lines[j].count("{") - lines[j].count("}")
            if "{" in lines[j]:
                started = True
            if started and depth <= 0:
                break
        if best is None or len(body) > len(best):
            best = body
    return best or []


def extract_returns(raw_src, method):
    """
    返回字段溜源：找到方法内 new 出来的 *RO/*Result 变量，
    收集它们的 setXxx(…) —— 直接回答「返回的字段都从哪拿的」。
    只扫本方法体（委派类里的补字段在下钻层自己看）。
    """
    body = locate_body(raw_src, method)
    if not body:
        return []
    text = "\n".join(t for _, t in body)
    ro_vars = set(re.findall(r"(\w+)\s*=\s*new\s+\w*(?:RO|Result|Response|Ro)\s*\(", text))
    if not ro_vars:
        return []
    out = []
    for ln, t in body:
        m = re.match(r"\s*(\w+)\.set([A-Z]\w*)\((.*)\);?\s*$", t)
        if m and m.group(1) in ro_vars:
            src = re.sub(r"\s+", " ", m.group(3)).strip()
            field = m.group(2)[0].lower() + m.group(2)[1:]
            out.append({"field": field, "src": src[:88], "line": ln})
        m2 = re.search(r"BeanUtils\.copyProperties\((\w+),\s*(\w+)\)", t)
        if m2 and m2.group(2) in ro_vars:
            out.append({"field": "(整体拷贝)", "src": m2.group(1), "line": ln})
    return out


def method_bodies(src):
    """
    切出每个 public 方法体（带起始行号）。
    花括号配平而非整体正则：避免嵌套 lambda / 匿名类切错边界。
    """
    out = {}
    lines = src.split("\n")
    sig = re.compile(r"^\s*(?:public|private|protected|default)\s+[\w<>,\[\]\.\s\?]+\s+(\w+)\s*\(")
    for i, line in enumerate(lines):
        m = sig.match(line)
        if not m:
            continue
        name = m.group(1)
        depth, started, body = 0, False, []
        for j in range(i, min(len(lines), i + 500)):
            body.append(lines[j])
            depth += lines[j].count("{") - lines[j].count("}")
            if "{" in lines[j]:
                started = True
            if started and depth <= 0:
                break
        key = name if name not in out else "%s__%d" % (name, i)
        out[key] = {"line": i + 1, "body": "\n".join(body)}
    return out


def classify(flow_src, method):
    """判定单格状态。flow_src 须已去注释。"""
    if method is None:
        return None
    bodies = method_bodies(flow_src)
    cands = [v for k, v in bodies.items()
             if k == method or k.startswith(method + "__")]
    if not cands:
        return {"state": "default", "line": None, "note": "未 override，走接口 default"}
    # 多重载取最长者为主实现（短的通常是委托给长的那个）
    main = max(cands, key=lambda c: len(c["body"]))
    body = main["body"]
    inner = body.split("{", 1)[1] if "{" in body else body
    if "UnsupportedOperationException" in inner:
        stmts = [s.strip() for s in inner.split("\n")
                 if s.strip() and s.strip() not in ("}", "{")]
        # 方法体基本只有一句 throw => 真断路；否则是分支内防御性抛出
        if len(stmts) <= 2:
            return {"state": "broken", "line": main["line"],
                    "note": "抛 UnsupportedOperationException"}
    if re.search(r"\bTODO\b|\bFIXME\b", body):
        return {"state": "todo", "line": main["line"], "note": "方法体内有 TODO"}
    return {"state": "full", "line": main["line"], "note": ""}


# ---------- 步骤图提取：把方法体读成「干了啥 / 拦了啥 / 报啥错」 ----------

# 外部依赖调用的识别特征 → 归类展示
EXTERNAL_HINTS = [
    (r"(\w*ApiClient)\.(\w+)",              "third",  "调三方 API"),
    (r"(\w*EsDao)\.(\w+)",                  "es",     "读写 ES"),
    (r"(\w*Reference)\.(\w+)",              "dubbo",  "调 Dubbo"),
    (r"(\w*Service)\.(\w+)",                "service", "内部服务"),
    (r"(\w*Helper)\.(\w+)",                 "helper", "辅助逻辑"),
    (r"(redis\w*|\w*Redis\w*)\.(\w+)",      "redis",  "读写 Redis"),
]


def _clean_msg(s):
    """把 Java 字符串拼接表达式压成人能读的一句话。无字面量时回退到表达式本身。"""
    parts = re.findall(r'"([^"]*)"', s)
    msg = re.sub(r"\s+", " ", "".join(parts).strip())
    if msg:
        return msg[:120]
    # 如 throw new X(meituanCouponStatusDesc(status)) —— 文案由方法算出，展示调用式
    expr = s.strip().rstrip(");").strip()
    expr = re.sub(r"\s+", " ", expr)
    return ("↳ " + expr[:110]) if expr else ""


def _cond_text(s):
    """把 if 条件压成一句人能读的分支语义。"""
    s = s.strip()
    m = re.search(r"\bif\s*\((.*)\)\s*\{?\s*$", s)
    if not m:
        return None
    c = m.group(1).strip()
    c = re.sub(r"\s+", " ", c)
    # 去掉包裹的冗余括号
    while c.startswith("(") and c.endswith(")"):
        c = c[1:-1].strip()
    return c[:96]


def _catch_text(s):
    """
    catch 块也是分支：不抓就会出现悬空的「上抛」行，
    读者不知道是哪步失败才走到这里。
    """
    m = re.search(r"\bcatch\s*\(\s*([\w\.$]+(?:\s*\|\s*[\w\.$]+)*)\s+\w+\s*\)", s)
    if not m:
        return None
    types = re.sub(r"\s*\|\s*", " | ", m.group(1))
    return "捕获 " + types[:80]


def extract_steps(raw_src, method):
    """
    从**带注释**的原始源码里抽方法体步骤。
    刻意不去注释：这些 Flow 普遍写了 `// 0. 门店准入校验` 式编号注释，
    是作者亲手标的步骤名，比任何静态分析都准 —— 直接拿来当步骤标题。
    """
    bodies = method_bodies(strip_comments(raw_src))
    if not (method in bodies or any(k.startswith(method + "__") for k in bodies)):
        return None

    # 在原始源码上重新定位方法体（要保留注释）；含私有方法
    lines = raw_src.split("\n")
    sig = re.compile(r"^\s*(?:public|private|protected|default)\s+[\w<>,\[\]\.\s\?]+\s+%s\s*\("
                     % re.escape(method))
    best = None
    for i, line in enumerate(lines):
        if not sig.match(line):
            continue
        depth, started, body, endl = 0, False, [], i
        for j in range(i, min(len(lines), i + 500)):
            body.append((j + 1, lines[j]))
            depth += lines[j].count("{") - lines[j].count("}")
            if "{" in lines[j]:
                started = True
            if started and depth <= 0:
                endl = j + 1
                break
        if best is None or len(body) > len(best):
            best = body
    if not best:
        return None

    steps = []
    base = None          # 方法体主干深度
    depth = 0            # 当前行所处花括号深度
    cond_stack = []      # [(depth, 条件文本)] —— 当前嵌套的分支条件链

    for ln, text in best:
        t = text.strip()
        opens = text.count("{")
        closes = text.count("}")

        # 先结算本行开头的退出（如 "}" 或 "} else {"）：只数开头那串 }
        lead_close = re.match(r"^\s*(\}*)", text).group(1).count("}")
        depth -= lead_close
        while cond_stack and cond_stack[-1][0] > depth:
            cond_stack.pop()

        if base is None and started_body(text):
            base = depth + 1

        cur_depth = depth
        cond = _cond_text(t) or _catch_text(t)

        if t:
            rel = max(0, cur_depth - (base if base is not None else cur_depth))
            guard_cond = cond_stack[-1][1] if cond_stack else None
            node = classify_line(t, ln, rel, guard_cond)
            if node:
                steps.append(node)

        # 再结算本行尾部的进入
        depth += opens - (closes - lead_close)
        if cond and opens > 0:
            cond_stack.append((depth, cond))

    # 去重相邻同类同文本（循环体里重复调用会刷屏）
    dedup = []
    for s in steps:
        if dedup and dedup[-1].get("text") == s.get("text") \
                and dedup[-1]["kind"] == s["kind"]:
            continue
        dedup.append(s)

    # 连续注释行合并成一个注解块：四五行的说明段落本就是一个思想，
    # 渲染成四五行就是密密麻麻的墙。只合源码行号紧贴（差1）的，
    # 隔着代码的注释各自独立（它们分属不同动作，自动编号要靠这个）。
    merged = []
    prev_end = None
    for s in dedup:
        if (s["kind"] == "note" and merged and merged[-1]["kind"] == "note"
                and s.get("depth") == merged[-1].get("depth")
                and prev_end is not None and s["line"] - prev_end == 1):
            merged[-1].setdefault("more", []).append(s["text"])
            prev_end = s["line"]
            continue
        merged.append(s)
        prev_end = s["line"]
    dedup = merged

    # 顺序感修复：方法没有任何作者编号步骤时，无编号注释按出现顺序
    # 自动编号升为主干（auto 标记渲染成灰号，与作者编号区分）；
    # 有作者编号时 note 保持淡化注解。
    if not any(s["kind"] == "step" for s in dedup):
        n = 0
        for s in dedup:
            if s["kind"] == "note":
                n += 1
                s["kind"] = "step"
                s["no"] = str(n)
                s["auto"] = True
    return dedup


def started_body(line):
    return "{" in line


def classify_line(t, ln, depth, guard_cond):
    """单行 → 节点。depth = 相对主干的嵌套层级，guard_cond = 所在分支条件。"""
    # 方法声明行不是节点：否则 handle*/process* 签名会把自己识别成调用（自引用）
    if re.match(r"\s*(?:public|private|protected|default\s+\w)", t):
        return None
    common = {"line": ln, "depth": depth, "cond": guard_cond}

    # 1) 作者手写的编号步骤注释 => 主干步骤（最高信噪比）
    m = re.match(r"^//\s*(\d+(?:\.\d+)?)[\.、]?\s*(.+)$", t)
    if m and len(m.group(2)) > 1:
        return dict(common, kind="step", no=m.group(1),
                    text=m.group(2).strip()[:110], depth=0, cond=None)

    # 1b) 无编号的分段注释（如 `// ─── 幂等检查 ───` 或 `// 根据前缀路由店铺`）
    #     先记为 note：若整个方法没有作者编号，后置扫描会把 note 按出现顺序
    #     自动编号升为主干（找回顺序感）；若有作者编号，note 降为淡化注解，
    #     避免把解释性注释全贴成步骤冲淡主干。
    m = re.match(r"^//\s*(.+)$", t)
    if m:
        txt = m.group(1).strip().strip("─-=、 ").strip()
        if (len(txt) >= 6 and re.search(r"[\u4e00-\u9fff]", txt)
                and not re.match(r"^(TODO|FIXME|NOTE|XXX)\b", txt, re.I)):
            return dict(common, kind="note",
                        text=txt[:110], depth=0, cond=None)
        return None

    # 2) 抛异常 => 出口（离开主干）
    m = re.search(r"throw new (\w+)\((.*)", t)
    if m:
        arg = m.group(2).strip().rstrip(");").strip()
        # 裸重抛（throw new RuntimeException(e)）无文案可言：配合 catch 胶囊
        # 读作「捕获 X → 包一层上抛」，别输出孤零零的 “↳ e”
        if re.fullmatch(r"\w+", arg) and len(arg) <= 2:
            return dict(common, kind="throw", ex=m.group(1),
                        text="把捕获的异常包一层上抛")
        return dict(common, kind="throw", ex=m.group(1),
                    text=_clean_msg(m.group(2)))

    # 3) 失败返回 => 出口
    m = re.search(r"Results\.newFailedResult\((.*)", t)
    if m:
        return dict(common, kind="fail", text=_clean_msg(m.group(1)))

    # 4) 校验/断言类调用 => 拦截。verify* 也算（验签 verify2 这类）；
    #    但若同行命中委派接收者（xxxService.verifyXxx）则让给 call 规则，
    #    保住可展开性（否则 verifyOrderToFulfil 这类下钻就没了）。
    m = re.search(r"\b(validate\w*|check\w*|require\w*|assert\w*|verify\w*)\s*\(", t)
    if m and "//" not in t.split(m.group(1))[0]:
        if not any(re.search(p, t) for p, _, _ in EXTERNAL_HINTS):
            return dict(common, kind="guard", text=m.group(1))

    # 5) 降级 / 兜底日志
    if re.search(r"log\.(warn|error)\(", t):
        msg = _clean_msg(t)
        if re.search(r"降级|兜底|失败|异常", msg):
            return dict(common, kind="degrade", text=msg)
        return None

    # 6) 外部依赖调用：挂操作语义（取/写/更/MQ/锁）与目标（ES/Dubbo/三方…）
    for pat, cat, label in EXTERNAL_HINTS:
        m = re.search(pat, t)
        if m:
            op, tgt = classify_op(m.group(1), m.group(2))
            return dict(common, kind="call", cat=cat, label=label,
                        op=op, tgt=tgt,
                        text="%s.%s" % (m.group(1), m.group(2)))

    # 6b) 本类裸调用里的关键动作：落库/发MQ/回写这类不带接收者的方法
    #     （generateAndSaveVoucherSerial / sendCreateOrderMQ …）——
    #     正是「落了什么数据、发了什么MQ」的主体，不抓就断档。
    m = re.search(
        r"(?<![\w\.])(send\w*(?:MQ|Mq|Msg|Message)|publish\w*|generateAndSave\w+|"
        r"save\w+|insert\w+|upsert\w+|record\w+|writeBack\w+|"
        r"dispatch\w+|process\w+|handle\w+|do[A-Z]\w+)\s*\(", t)
    if m:
        op, _ = classify_op(None, m.group(1))
        return dict(common, kind="call", cat="self", label="本类",
                    op=op, tgt="本类", text=m.group(1))
    return None


def build_class_index():
    """
    全仓 Java 类名 → 文件绝对路径。用于把“委派给 xxxService”的调用展开成真步骤。
    只建 Ultra + Tesla 两仓的 main 源码，跳过 test/target。
    """
    idx = {}
    for root_dir in (os.path.join(ULTRA, "ultra-core/src/main/java"),
                     os.path.join(ULTRA, "ultra-facade/src/main/java"),
                     os.path.join(TESLA, "tesla-main/src/main/java")):
        if not os.path.isdir(root_dir):
            continue
        for root, dirs, files in os.walk(root_dir):
            dirs[:] = [d for d in dirs if d not in ("target", "test")]
            for fn in files:
                if fn.endswith(".java"):
                    idx.setdefault(fn[:-5], os.path.join(root, fn))
    return idx


CLASS_INDEX = None


def resolve_delegate(flow_src, call_text):
    """
    把 `shangouCouponUseService.executeUse` 解成 (绝对路径, 方法名)。
    靠 Flow 里的字段声明拿真实类名（字段名首字母小写，类名大写，不能直接套）。
    """
    global CLASS_INDEX
    if "." not in call_text:
        return None, None
    recv, method = call_text.split(".", 1)
    if "." in method:
        return None, None
    # 在 Flow 中找字段类型：如 `private ShangouCouponUseService shangouCouponUseService;`
    m = re.search(r"\b([A-Z]\w+)\s+%s\s*[;=]" % re.escape(recv), flow_src)
    cls = m.group(1) if m else (recv[0].upper() + recv[1:])
    if CLASS_INDEX is None:
        CLASS_INDEX = build_class_index()
    return CLASS_INDEX.get(cls), method


# 不值得展开的委派目标：基础设施类。
# 展开 DAO/ApiClient/Redis 只会把“怎么存”的细节灌进来，淡化业务主干；
# 只展开真正承载业务编排的 *Service / *Helper。
NO_INLINE = re.compile(
    r"(EsDao|Dao|Mapper|Repository|ApiClient|Client|RedisCache|Cache|"
    r"Reference|Properties|Utils|Converter)$"
)


MAX_INLINE_DEPTH = 3   # 最多往下钻 3 层：再深就是全库展平，主干反而没了


def count_nodes(steps):
    n = 0
    for s in steps:
        n += 1
        if s.get("children"):
            n += count_nodes(s["children"])
    return n


def attach_children(steps, host_src, depth=1, seen=None, budget=None,
                    host_path=None):
    """
    递归展开委派调用：call 节点若指向本仓业务类（*Service/*Helper），
    把目标方法的步骤挂成 children，渲染端做成可逐层点开的下钻。
    护栏：
      - NO_INLINE 基础设施类不展（DAO/ApiClient/Redis 只是“怎么存”）
      - seen 防环（A→B→A）与同目标重复展开（同格内只展首次出现）
      - MAX_INLINE_DEPTH 限深、budget 限总节点数，防缓存 JSON 失控
      - depth>1 或步骤>18 的默认折叠，点开才见
    """
    if seen is None:
        seen = set()
    if budget is None:
        budget = {"nodes": 250}
    if depth > MAX_INLINE_DEPTH:
        return
    for s in steps:
        if s.get("kind") != "call":
            continue
        txt = s.get("text", "")
        if "." in txt:
            path, method = resolve_delegate(host_src, txt)
        else:
            # 本类私有编排方法（dispatchSpi 这类）：在同文件内展开，
            # 不展就会出现「回调进来后链路凭空消失」
            path, method = host_path, txt
        if not path or not method:
            continue
        if NO_INLINE.search(os.path.basename(path)[:-5]):
            continue
        key = (path, method)
        if key in seen:
            continue
        sub_raw = host_src if path == host_path else read_src(path)
        sub = extract_steps(sub_raw, method)
        if not sub or budget["nodes"] < len(sub):
            continue
        seen.add(key)
        budget["nodes"] -= len(sub)
        # 先递归再挂：子层的委派用子类自己的字段声明解析
        attach_children(sub, sub_raw, depth + 1, seen, budget, host_path=path)
        stamp_file(sub, repo_rel(path)[1])
        s["children"] = sub
        s["intoFile"] = os.path.basename(path)
        s["intoMethod"] = method
        s["intoCount"] = count_nodes(sub)
        # 宿主本身是薄壳（顶层没几行）时，第一层必须默认铺开，
        # 否则又回到“流程到这就停了”
        thin_host = len(steps) <= 5
        s["collapsed"] = (depth > 1 or len(sub) > 18) \
            and not (depth == 1 and thin_host)


def build_facade_stages():
    """
    Facade 入口公共环节：SAAS 调的是 ThirdUnifyFacadeImpl，路由/时间拦截/
    分布式锁/核销后发创单MQ 全在这层 —— 只扫平台 Flow 会漏掉发MQ，
    这正是「核销里怎么没发MQ」的根因。每阶段抽一次，全平台共享。
    """
    path = os.path.join(LIFE, "ThirdUnifyFacadeImpl.java")
    raw = read(path)
    rel = ULTRA_LIFE_REL + "/ThirdUnifyFacadeImpl.java"
    out = {}
    # 2026-08-07 接口改名（15f29fbd4）：queryCoupon→routeCode、
    # consultVerify→queryCodeContent（commit message 写的 Context，代码实为 Content）、
    # executeUse→writeOff。新名优先、旧名兜底，避免改名时面板静默丢 Facade 层。
    candidates = {
        "queryCoupon": ("routeCode", "queryCoupon"),
        "consultVerify": ("queryCodeContent", "queryCodeContext", "consultVerify"),
        "executeUse": ("writeOff", "executeUse"),
    }
    for key, meths in candidates.items():
        for meth in meths:
            body = locate_body(raw, meth)
            steps = extract_steps(raw, meth) or []
            if not body or not steps:
                continue
            attach_children(steps, raw, host_path=path,
                            budget={"nodes": 150})
            stamp_file(steps, rel)
            out[key] = {"method": meth, "file": rel, "line": body[0][0],
                        "steps": steps, "count": count_nodes(steps)}
            break
    return out


def build_create_order_flow():
    """创单格的真实逻辑：ThirdCanalCreateOrderService.doCreateOrder（MQ 消费入口）。"""
    path = os.path.join(UNIFY, "ThirdCanalCreateOrderService.java")
    raw = read(path)
    rel = ULTRA_LIFE_REL + "/unify/ThirdCanalCreateOrderService.java"
    body = locate_body(raw, "doCreateOrder")
    steps = extract_steps(raw, "doCreateOrder") or []
    if not body or not steps:
        return None
    attach_children(steps, raw, host_path=path, budget={"nodes": 150})
    stamp_file(steps, rel)
    line = body[0][0]
    steps.insert(0, {
        "kind": "step", "no": "0", "auto": True,
        "text": "消费 THIRD_CANAL_ASYNC_CREATE_ORDER MQ 触发（核销成功后 Facade 发送）",
        "line": line, "depth": 0, "cond": None, "file": rel,
    })
    return {"method": "doCreateOrder", "file": rel, "line": line,
            "steps": steps, "count": count_nodes(steps)}


def build_issue_cell(pkey):
    """
    发码格：注意它可能指向**另一个仓库**（Tesla）。
    spi  = 三方回调我方接口，有真实实现可下钻
    pull = 无回调，验券时主动查（不是缺失，是设计如此）
    none = 该渠道没有发码环节
    """
    info = ISSUE_MAP.get(pkey, {"mode": "none", "note": ""})
    mode = info.get("mode", "none")
    path = info.get("abs")
    rel = repo_rel(path)[1] if path else None
    cell = {
        "state": {"spi": "full", "pull": "pull", "none": "absent"}[mode],
        "line": None,
        "note": info.get("note", ""),
        "mode": mode,
        "repo": info.get("repo"),
        "srcFile": rel,
        "route": info.get("route"),
        "steps": [],
    }
    if mode == "spi" and path and os.path.exists(path):
        raw = read_src(path)
        entry = info.get("entry")
        if entry and raw:
            m = re.search(r"^\s*public\s+[\w<>,\[\]\.\s\?]+\s+%s\s*\("
                          % re.escape(entry), raw, re.M)
            if m:
                cell["line"] = raw[:m.start()].count("\n") + 1
            steps = extract_steps(raw, entry) or []
            attach_children(steps, raw, host_path=path)
            stamp_file(steps, rel)
            # 发码的第一步就是三方回调打进来：合成入口节点顶在最前，
            # 后面才是验签/解析/落库等真实步骤
            steps.insert(0, {
                "kind": "step", "no": "0", "auto": True,
                "text": "三方回调打进来 " + (info.get("route") or ""),
                "line": cell["line"] or 1, "depth": 0, "cond": None,
                "file": rel,
            })
            cell["steps"] = steps
            cell["returns"] = extract_returns(raw, entry)
    elif mode == "spi" and path:
        cell["note"] = (info.get("note", "") +
                        "（源文件未找到，确认仓库路径）")
    return cell


def parse_platform_enum():
    """ThirdPlatformEnum 是平台/channel号/流水号前缀的唯一事实源。"""
    src = read(os.path.join(UNIFY, "flow/ThirdPlatformEnum.java"))
    out = {}
    for m in re.finditer(
        r'(\w+)\("(\w+)",\s*"([^"]+)",\s*"([^"]*)",\s*(\d+|null)\)', src
    ):
        name, code, cn, prefix, ch = m.groups()
        out[name] = {
            "code": code,
            "cn": cn,
            "serialPrefix": prefix or None,
            "channel": None if ch == "null" else int(ch),
        }
    return out


def parse_create_order_platforms():
    """核销后发 MQ 创单的平台集合。注意它与时间限制集合共用同一常量。"""
    src = read(os.path.join(LIFE, "ThirdUnifyFacadeImpl.java"))
    m = re.search(r"TIME_RESTRICTED_PLATFORMS\s*=\s*Set\.of\((.*?)\);", src, re.S)
    members = re.findall(r"ThirdPlatformEnum\.(\w+)", m.group(1)) if m else []
    aliased = bool(
        re.search(r"CREATE_ORDER_PLATFORMS\s*=\s*TIME_RESTRICTED_PLATFORMS", src)
    )
    return members, aliased


def scan_todos():
    """全链路 TODO 清单：施工中的真实位置。"""
    todos = []
    for root, _, files in os.walk(LIFE):
        for fn in files:
            if not fn.endswith(".java"):
                continue
            p = os.path.join(root, fn)
            for i, line in enumerate(read(p).split("\n"), 1):
                if re.search(r"\bTODO\b|\bFIXME\b", line):
                    todos.append({
                        "file": os.path.relpath(p, LIFE),
                        "line": i,
                        "text": line.strip().lstrip("/*").strip()[:160],
                    })
    return todos


def main():
    if not os.path.isdir(LIFE):
        print("找不到 Ultra 源码目录: %s" % LIFE, file=sys.stderr)
        return 1

    enum = parse_platform_enum()
    create_platforms, aliased = parse_create_order_platforms()

    # 接口 default 实现：闪购/大客户的查券走的就是这段，也是真代码，
    # 不抽就会出现「格子没内容」的假象（全平台共用同一段，按阶段抽一次）
    iface_path = os.path.join(UNIFY, "flow/ThirdUnifyFlow.java")
    iface_rel = ULTRA_LIFE_REL + "/unify/flow/ThirdUnifyFlow.java"
    iface_raw = read(iface_path)
    iface_cells = {}
    for st in STAGES:
        if not st["method"]:
            continue
        dsteps = extract_steps(iface_raw, st["method"]) or []
        drets = extract_returns(iface_raw, st["method"])
        dbody = locate_body(iface_raw, st["method"])
        if not dbody or (not dsteps and not drets):
            continue
        attach_children(dsteps, iface_raw, host_path=iface_path)
        stamp_file(dsteps, iface_rel)
        # default 体往往只有几行 set+return，抽不出节点 —— 合成一条说明，
        # 避免“有返回表却没流程”的空洞感
        if not dsteps:
            dsteps = [{
                "kind": "step", "no": "·", "auto": True,
                "text": "无平台定制动作：直接组装返回（字段见下方返回表）",
                "line": dbody[0][0], "depth": 0, "cond": None,
                "file": iface_rel,
            }]
        iface_cells[st["key"]] = {"steps": dsteps, "returns": drets}

    platforms = []
    for name, cn, rel in FLOWS:
        raw = read(os.path.join(LIFE, rel))
        if not raw:
            continue
        src = strip_comments(raw)
        cells = {}
        for st in STAGES:
            if st["key"] == "issue":
                cells[st["key"]] = build_issue_cell(name)
            elif st["key"] == "createOrder":
                inset = name in create_platforms
                cells[st["key"]] = {
                    "state": "full" if inset else "absent",
                    "line": None,
                    "note": "在 CREATE_ORDER_PLATFORMS 内，核销后发 MQ 创单"
                            if inset else "不走核销后创单",
                }
            else:
                cell = classify(src, st["method"])
                # 步骤图：真 override 的抽平台实现；走 default 的抽接口实现（也是真代码）
                if cell["state"] in ("full", "todo", "broken"):
                    steps = extract_steps(raw, st["method"]) or []
                    # 薄壳转发递归挂成 children，渲染端逐层点开
                    attach_children(steps, raw,
                                    host_path=os.path.join(LIFE, rel))
                    stamp_file(steps, ULTRA_LIFE_REL + "/" + rel)
                    cell["steps"] = steps
                    # 返回字段溜源：回答「返回的字段从哪拿」
                    cell["returns"] = extract_returns(raw, st["method"])
                elif cell["state"] == "default" and st["key"] in iface_cells:
                    ic = iface_cells[st["key"]]
                    cell["steps"] = ic["steps"]
                    cell["returns"] = ic["returns"]
                    cell["srcFile"] = iface_rel
                    cell["fromDefault"] = True
                    cell["note"] = "接口默认实现（平台未定制，公用这段）"
                else:
                    cell["steps"] = []
                cells[st["key"]] = cell
        meta = enum.get(name, {})
        platforms.append({
            "key": name,
            "cn": meta.get("cn") or cn,
            "channel": meta.get("channel"),
            "serialPrefix": meta.get("serialPrefix"),
            "file": rel,
            "loc": raw.count("\n") + 1,
            "todoCount": len(re.findall(r"\bTODO\b|\bFIXME\b", raw)),
            "createsOrder": name in create_platforms,
            "cells": cells,
        })

    cache = {
        "generated": datetime.now().strftime("%Y-%m-%d %H:%M"),
        "repo": {
            "branch": git("branch", "--show-current"),
            "head": git("log", "-1", "--format=%h %ad %s", "--date=format:%Y-%m-%d"),
            "dirty": bool(git("status", "--porcelain")),
            "root": "ultra-core/.../application/offline/life",
            # 发码格子的数据源在 Tesla：扫的是三渠分支(git show)，不是 checkout 分支
            "tesla": {
                "branch": git_in(TESLA, "branch", "--show-current"),
                "scanRef": resolve_tesla_ref() or "(工作区回退)",
                "head": git_in(TESLA, "log", "-1", "--format=%h %ad",
                               "--date=format:%Y-%m-%d",
                               resolve_tesla_ref() or "HEAD"),
                "dirty": bool(git_in(TESLA, "status", "--porcelain")),
            },
        },
        "stages": STAGES,
        "platforms": platforms,
        "createOrderPlatforms": create_platforms,
        "createOrderAliasedToTimeLimit": aliased,
        "facade": build_facade_stages(),
        "createOrderFlow": build_create_order_flow(),
        "todos": scan_todos(),
    }

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(cache, f, ensure_ascii=False, indent=2)
    print("写入 %s" % OUT)
    print("平台 %d 个，阶段 %d 个，TODO %d 处"
          % (len(platforms), len(STAGES), len(cache["todos"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
