#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Canal 视角视觉原型生成器 —— 把 canal-cache.json 渲染成单文件 HTML 预览。

用途：在写 Swift 面板前先定版式。产出 /tmp/canal_proto.html。
数据全部来自 gen_canal.py 的真实扫描结果，不含任何手写假数据。
"""
import json
import os
import subprocess
import sys

CACHE = os.path.expanduser("~/.claude/canal-cache.json")
OUT = "/tmp/canal_proto.html"
GEN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gen_canal.py")

if not os.path.exists(CACHE):
    subprocess.run([sys.executable, GEN], check=True)

with open(CACHE, encoding="utf-8") as f:
    data = json.load(f)

HTML = r"""<!DOCTYPE html>
<meta charset="utf-8">
<title>Canal 三渠统一 — 视觉原型</title>
<style>
:root{
  --bg:#0f1216; --panel:#161b22; --line:#232a33;
  --tx:#e6edf3; --tx2:#8b949e; --tx3:#5a6371;
  --full:#3fb950; --todo:#d29922; --broken:#f85149;
  --default:#3d444d; --accent:#6ea8fe; --cdd:#a371f7;
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--tx);
  font:13px/1.5 -apple-system,"SF Pro Text","PingFang SC",sans-serif;
  -webkit-font-smoothing:antialiased;padding:22px 26px 40px}
.wrap{max-width:1000px;margin:0 auto}

/* 头部：字标叠卡，对齐 DBoard 现有 BizMap/ReqFlow 风格 */
.head{display:flex;align-items:flex-start;gap:18px;margin-bottom:6px}
.stack{position:relative;width:250px;height:46px;flex:0 0 auto}
.wm{position:absolute;top:0;left:0;font-weight:800;letter-spacing:-.4px;
  transform-origin:top left;transition:.35s cubic-bezier(.3,1.3,.5,1)}
.wm b{display:block;font-size:19px}
.wm i{display:block;width:28px;height:2.5px;border-radius:2px;margin-top:2px}
.wm.on{color:var(--accent);z-index:2}
.wm.on i{background:var(--accent)}
.wm.off{color:var(--tx3);opacity:.4;transform:scale(.78) rotate(2.5deg)
  translate(0,0);z-index:1}
.wm.off i{background:transparent}
.wm.off.p1{left:64px;top:17px}
.wm.off.p2{left:128px;top:34px}
.meta{margin-left:auto;text-align:right;color:var(--tx3);font-size:10.5px;
  line-height:1.7;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
.meta .br{color:var(--accent)}
.clean{color:var(--full)}

/* 泳道：业务流顺序 */
.lane{display:flex;align-items:center;gap:0;margin:16px 0 4px;
  padding:9px 12px;background:var(--panel);border:1px solid var(--line);
  border-radius:9px}
.lane .rt{display:flex;align-items:center;gap:7px;padding-right:13px;
  margin-right:3px;border-right:1px dashed var(--line)}
.badge{display:inline-flex;align-items:center;gap:5px;padding:3px 8px;
  border-radius:6px;background:rgba(163,113,247,.13);
  border:1px solid rgba(163,113,247,.35);color:var(--cdd);
  font-size:10.5px;font-weight:600;white-space:nowrap}
.step{display:flex;align-items:center;gap:8px;flex:1}
.step span{color:var(--tx2);font-size:11.5px;white-space:nowrap}
.arw{color:var(--tx3);font-size:11px}
.mq{color:var(--todo);font-size:9.5px;border:1px dashed rgba(210,153,34,.5);
  border-radius:4px;padding:1px 4px;margin-left:2px}

/* 矩阵 */
/* 下钻：流程步骤图 */
.drill{margin-top:14px;background:var(--panel);border:1px solid var(--line);
  border-radius:11px;overflow:hidden}
.dh{display:flex;align-items:baseline;gap:10px;row-gap:3px;padding:11px 15px;
  background:#12171e;border-bottom:1px solid var(--line);flex-wrap:wrap}
/* 窄宽度禁止 flex 把标题挤成一字一行竖排：全部 nowrap；
   长路径单独省略，放不下就换整行而非逐字折叠 */
.dh b{font-size:13px;white-space:nowrap;flex-shrink:0}
.dh .mth{color:var(--accent);font-size:10.5px;white-space:nowrap;
  max-width:52%;overflow:hidden;text-overflow:ellipsis;
  font-family:ui-monospace,Menlo,monospace}
.dh .cnt{margin-left:auto;color:var(--tx3);font-size:10px;
  white-space:nowrap;flex-shrink:0}
.dh .src{color:var(--tx3);font-size:10px;white-space:nowrap;
  flex:1 1 120px;min-width:60px;overflow:hidden;text-overflow:ellipsis;
  font-family:ui-monospace,Menlo,monospace}
.hint{padding:22px 15px;color:var(--tx3);font-size:11.5px;text-align:center}

/* 步骤流：主干线 + 分支层级 */
.flow{padding:8px 0 12px;position:relative}
.fi{display:flex;gap:0;padding:2.5px 15px 2.5px 0;position:relative;
  align-items:flex-start}
.fi .gut{flex:0 0 46px;text-align:right;color:var(--tx3);font-size:9px;
  font-family:ui-monospace,Menlo,monospace;padding-top:3px}
/* 分支缩进区：画拐角连线，让“离开主干”看得见 */
.fi .ind{flex:0 0 auto;position:relative;align-self:stretch}
.fi .elbow{position:absolute;left:0;top:0;bottom:0;width:100%}
.fi .ico{flex:0 0 16px;text-align:center;font-size:10px;padding-top:1px;
  position:relative;z-index:2}
.fi .bd{flex:1;font-size:11.5px;line-height:1.5;padding-top:.5px;
  padding-left:7px}

/* 主干线：只贯穿主干节点所在的那一列 */
.flow::before{content:"";position:absolute;left:62px;top:14px;bottom:18px;
  width:1.5px;background:linear-gradient(180deg,
    var(--accent) 0%, rgba(110,168,254,.28) 8%, rgba(110,168,254,.28) 92%,
    transparent 100%)}

/* 主干步骤：实心方块压在主干线上 */
.k-step{margin-top:5px}
.k-step .ico{color:var(--accent);background:var(--panel)}
.k-step .bd{color:var(--tx);font-weight:600}
.k-step .no{display:inline-block;min-width:15px;color:var(--accent);
  font-size:9.5px;font-family:ui-monospace,Menlo,monospace;margin-right:5px}

/* 主干上的直行节点 */
.k-call .ico,.k-guard .ico{background:var(--panel)}
.k-call .ico{color:var(--tx3)}
.k-call .bd{color:var(--tx2);font-family:ui-monospace,Menlo,monospace;
  font-size:10.5px}
.k-call .tag{font-family:-apple-system,sans-serif;font-size:9px;
  color:var(--tx3);border:1px solid var(--line);border-radius:3px;
  padding:0 3px;margin-left:5px}
.k-guard .ico{color:var(--todo)}
.k-guard .bd{color:var(--todo);font-family:ui-monospace,Menlo,monospace;
  font-size:10.5px}

/* 出口节点（抛错/失败）：向右分岔离开主干 */
.k-throw .ico,.k-fail .ico{color:var(--broken)}
.k-throw .bd,.k-fail .bd{color:#ffa198}
.k-throw .bd em,.k-fail .bd em{font-style:normal;color:var(--tx3);
  font-size:9.5px;font-family:ui-monospace,Menlo,monospace;margin-right:5px}
.k-degrade .ico{color:var(--todo)}
.k-degrade .bd{color:#e3b341;opacity:.9}

/* 分支条件胶囊：挂在拐角上，告诉你“什么情况下走这里” */
.cond{display:inline-block;font-family:ui-monospace,Menlo,monospace;
  font-size:9px;color:var(--tx3);background:rgba(255,255,255,.035);
  border:1px solid var(--line);border-radius:4px;padding:0 4px;
  margin-right:6px;white-space:nowrap;max-width:330px;overflow:hidden;
  text-overflow:ellipsis;vertical-align:1px}
.k-throw .cond,.k-fail .cond{color:#d98a84;
  border-color:rgba(248,81,73,.3);background:rgba(248,81,73,.07)}

/* 跨仓库角标：发码格子可能指向 Tesla */
.repo{position:absolute;right:5px;top:4px;font-size:7.5px;line-height:1;
  padding:1px 2.5px;border-radius:2.5px;font-weight:700;letter-spacing:.2px}
.repo.tesla{color:#f0a4a0;background:rgba(248,81,73,.16)}
.repo.ultra{color:#8fd0a8;background:rgba(63,185,80,.15)}

/* 展开标记：进入另一个类的方法；可点，逐层下钻 */
.into{display:inline-block;font-size:8.5px;color:#8fd0a8;
  background:rgba(63,185,80,.1);border:1px solid rgba(63,185,80,.3);
  border-radius:3px;padding:0 3.5px;margin-left:6px;cursor:pointer;
  font-family:ui-monospace,Menlo,monospace;user-select:none}
.into:hover{background:rgba(63,185,80,.2)}
/* 被内联进来的节点：左侧竖条标明“这不是本方法的代码” */
.fi.inl{background:rgba(63,185,80,.022)}
.fi.inl .gut{color:#5b7a63}
.src2{display:inline-block;font-size:8.5px;color:var(--tx3);opacity:.55;
  margin-left:7px;font-family:ui-monospace,Menlo,monospace}

/* 操作语义徽标：一眼看出 取数/落库/更新/发MQ/校验/加锁 */
.op{display:inline-block;font-size:9px;font-weight:700;border-radius:3px;
  padding:0 4.5px;margin-right:6px;vertical-align:1px;letter-spacing:.3px;
  font-family:-apple-system,"PingFang SC",sans-serif;font-style:normal}
.op-read{color:#79c0ff;background:rgba(88,166,255,.13);border:1px solid rgba(88,166,255,.35)}
.op-write{color:#56d364;background:rgba(63,185,80,.13);border:1px solid rgba(63,185,80,.4)}
.op-update{color:#ffa657;background:rgba(219,109,40,.14);border:1px solid rgba(219,109,40,.42)}
.op-delete{color:#ff7b72;background:rgba(248,81,73,.12);border:1px solid rgba(248,81,73,.4)}
.op-mq{color:#d2a8ff;background:rgba(163,113,247,.14);border:1px solid rgba(163,113,247,.42)}
.op-lock{color:#e3b341;background:rgba(210,153,34,.12);border:1px solid rgba(210,153,34,.4)}
.op-invoke{color:var(--tx3);background:rgba(139,148,158,.1);border:1px solid var(--line)}
.op-validate{color:#e3b341;background:rgba(210,153,34,.12);border:1px solid rgba(210,153,34,.4)}
/* 跨服务调用：内部 Dubbo 与外部三方 HTTP 单独成类 */
.op-rpc{color:#39c5cf;background:rgba(57,197,207,.11);border:1px solid rgba(57,197,207,.4)}
.op-http{color:#f778ba;background:rgba(247,120,186,.1);border:1px solid rgba(247,120,186,.38)}

/* 操作汇总条：验券校验了啥、落了啥、更了啥、发了啥MQ，一行看完 */
.opsum{display:flex;gap:8px;flex-wrap:wrap;padding:8px 15px;
  border-bottom:1px solid var(--line);background:rgba(255,255,255,.012);
  font-size:10px;color:var(--tx2);align-items:center}
.opsum .op{margin-right:0}
/* 分类胶囊可点：只看某一类操作，再点还原 */
.fchip{display:inline-flex;align-items:center;gap:4px;cursor:pointer;
  padding:1px 5px;border-radius:5px;user-select:none}
.fchip:hover{background:rgba(110,168,254,.08)}
.fchip.on{background:rgba(110,168,254,.14);
  box-shadow:inset 0 0 0 1px var(--accent)}
.fchip.off{opacity:.4;cursor:default}
.fhint{margin-left:auto;color:var(--tx3);font-size:9px}

/* 分类过滤：只显命中行；仅名下有命中的主干步骤压暗留作路标（JS 标 .f-keep）；
   折叠的下钻层临时揭开，避免「汇总说有、正文看不见」；
   !important 压过密度档的隐藏规则 */
.flow[data-f] .fi{display:none!important}
.flow[data-f] .fi.k-step.f-keep{display:flex!important;opacity:.35}
.flow[data-f] .kids[hidden]{display:block!important}
.flow[data-f="validate"] .fi.k-guard{display:flex!important;opacity:1}
.flow[data-f="read"] .fi.op-read{display:flex!important;opacity:1}
.flow[data-f="write"] .fi.op-write{display:flex!important;opacity:1}
.flow[data-f="update"] .fi.op-update{display:flex!important;opacity:1}
.flow[data-f="delete"] .fi.op-delete{display:flex!important;opacity:1}
.flow[data-f="mq"] .fi.op-mq{display:flex!important;opacity:1}
.flow[data-f="lock"] .fi.op-lock{display:flex!important;opacity:1}
.flow[data-f="rpc"] .fi.op-rpc{display:flex!important;opacity:1}
.flow[data-f="http"] .fi.op-http{display:flex!important;opacity:1}
.flow[data-f="exit"] .fi.k-throw,
.flow[data-f="exit"] .fi.k-fail{display:flex!important;opacity:1}

/* 返回字段溜源表 */
.rets{border-top:1px solid var(--line);padding:9px 15px 11px}
.rets h4{margin:0 0 6px;font-size:10.5px;color:var(--tx2);font-weight:600}
.rets .rrow{display:flex;gap:8px;padding:2px 0;font-size:10.5px;
  font-family:ui-monospace,Menlo,monospace;align-items:baseline}
.rets .rf{flex:0 0 150px;color:#79c0ff;text-align:right}
.rets .ra{color:var(--tx3)}
.rets .rs{color:var(--tx2);word-break:break-all}
.rets .rl{color:var(--tx3);font-size:9px;flex:0 0 auto}

/* 淡化注解：有作者编号时，无编号注释降为注解，不当步骤 */
.k-note .ico{color:var(--tx3);opacity:.6}
.k-note .bd{color:var(--tx3);font-size:10.5px;font-style:italic}
/* 自动编号（作者没编号，按出现顺序补的）：灰号区分于作者蓝号 */
.no.auto{color:var(--tx3) !important}

/* 密度三档：脉络(只留步骤与出口) / 标准(隐注解) / 全部 */
.dens{display:inline-flex;border:1px solid var(--line);border-radius:5px;
  overflow:hidden;flex-shrink:0;margin-left:2px}
.dens i{font-style:normal;font-size:9.5px;padding:2px 8px;color:var(--tx3);
  cursor:pointer;user-select:none}
.dens i.on{background:rgba(110,168,254,.15);color:var(--accent)}
.flow.m-std .fi.k-note{display:none}
.flow.m-outline .fi.k-note,.flow.m-outline .fi.k-guard,
.flow.m-outline .fi.k-degrade,.flow.m-outline .fi.k-call.leaf{display:none}
/* 注解块：首行 + 可点开的剩余行 */
.nmore{display:inline-block;font-size:8.5px;color:var(--tx3);
  border:1px solid var(--line);border-radius:3px;padding:0 4px;
  margin-left:6px;cursor:pointer;user-select:none}
.nmore:hover{color:var(--tx2)}
.next{margin-top:2px;color:var(--tx3);font-style:italic;font-size:10.5px;
  line-height:1.55}

/* 双击复制提示 */
.toast{position:fixed;left:50%;bottom:26px;transform:translateX(-50%);
  background:#1c2530;border:1px solid var(--accent);color:var(--tx);
  font:11px ui-monospace,Menlo,monospace;padding:7px 14px;border-radius:8px;
  box-shadow:0 6px 24px rgba(0,0,0,.5);z-index:99;white-space:nowrap;
  opacity:0;transition:opacity .18s}
.toast.on{opacity:1}

/* 图例：步骤图 */
.lg2{display:flex;gap:15px;flex-wrap:wrap;padding:9px 15px;
  border-top:1px solid var(--line);color:var(--tx3);font-size:10px}

table{width:100%;border-collapse:separate;border-spacing:0;margin-top:14px;
  background:var(--panel);border:1px solid var(--line);border-radius:11px;
  overflow:hidden}
th,td{padding:0;text-align:center;border-bottom:1px solid var(--line)}
thead th{padding:11px 6px 10px;font-size:11px;font-weight:600;color:var(--tx2);
  background:#12171e;letter-spacing:.3px}
thead th.pf{text-align:left;padding-left:14px;width:172px}
tbody tr:last-child td{border-bottom:none}
tbody tr:hover{background:rgba(110,168,254,.045)}
td.pf{text-align:left;padding:9px 14px}
.pn{font-weight:600;font-size:12.5px;display:flex;align-items:center;gap:6px}
.pn.cdd{color:var(--cdd)}
.pi{color:var(--tx3);font-size:10px;font-family:ui-monospace,Menlo,monospace;
  margin-top:2px}
.cell{width:58px;height:44px;cursor:pointer;position:relative}
.cell:hover{background:rgba(110,168,254,.1)}
.cell.sel{background:rgba(110,168,254,.17);
  box-shadow:inset 0 0 0 1.5px var(--accent)}
.dot{width:13px;height:13px;border-radius:50%;margin:0 auto;position:relative}
.s-full{background:var(--full);box-shadow:0 0 0 3.5px rgba(63,185,80,.14)}
.s-todo{background:var(--todo);box-shadow:0 0 0 3.5px rgba(210,153,34,.16)}
.s-broken{background:transparent;border:2px solid var(--broken)}
.s-broken::after{content:"";position:absolute;inset:1px;
  background:linear-gradient(45deg,transparent 43%,var(--broken) 43%,
  var(--broken) 57%,transparent 57%)}
.s-default{background:transparent;border:1.5px dashed var(--default)}
/* pull：无回调，验券时主动查 —— 半实心，表“有能力但不是回调式” */
.s-pull{background:linear-gradient(90deg,var(--tx3) 0 50%,transparent 50% 100%);
  border:1.5px solid var(--tx3)}
.s-absent{width:5px;height:5px;background:var(--default);border-radius:50%;
  opacity:.55}
.ln{font-size:8.5px;color:var(--tx3);margin-top:3px;
  font-family:ui-monospace,Menlo,monospace}

/* 图例 */
.lg{display:flex;gap:17px;flex-wrap:wrap;margin:13px 2px 0;
  color:var(--tx2);font-size:10.5px;align-items:center}
.lg i{display:inline-block;vertical-align:-2px;margin-right:5px}

/* 卡点 */
.sec{margin-top:26px}
.sec h3{font-size:12px;color:var(--tx2);font-weight:600;margin:0 0 9px;
  letter-spacing:.4px;text-transform:uppercase}
.blk{background:var(--panel);border:1px solid var(--line);border-radius:9px;
  padding:3px 0}
.row{display:flex;gap:10px;padding:8px 13px;border-bottom:1px solid var(--line);
  align-items:baseline}
.row:last-child{border-bottom:none}
.row code{color:var(--cdd);font-size:10px;flex:0 0 auto;
  font-family:ui-monospace,Menlo,monospace}
.row p{margin:0;color:var(--tx2);font-size:11.5px;line-height:1.55}
.warn{border-color:rgba(248,81,73,.32);background:rgba(248,81,73,.05)}
.warn .row p b{color:var(--broken)}
</style>
<div class="wrap">

  <div class="head">
    <div class="stack">
      <div class="wm off p1"><b>BizMap</b><i></i></div>
      <div class="wm off p2"><b>ReqFlow</b><i></i></div>
      <div class="wm on"><b>Canal</b><i></i></div>
    </div>
    <div class="meta">
      <div><span class="br">__BRANCH__</span> · __HEAD__</div>
      <div title="发码代码从这个 git 分支直接读取（git show）；本地 Tesla 目录当前停在 __TBRANCH__ 分支，不影响扫描结果">Tesla 扫 <span class="br">__TSCANREF__</span> · __TESLAHEAD__</div>
      <div>工作区 <span class="clean">__DIRTY__</span> · 扫描 __GEN__</div>
    </div>
  </div>

  <div class="lane">
    <div class="rt">
      <span class="badge">◇ 路由消歧</span>
      <span class="arw">→</span>
    </div>
    <div class="step">__LANE__</div>
  </div>

  <table>
    <thead><tr><th class="pf">平台 / channel</th>__THEAD__</tr></thead>
    <tbody>__TBODY__</tbody>
  </table>

  <div class="lg">
    <span><i class="dot s-full"></i>已实现</span>
    <span><i class="dot s-pull"></i>无回调·主动查</span>
    <span><i class="dot s-todo"></i>施工中 (TODO)</span>
    <span><i class="dot s-broken"></i>断路 (抛异常)</span>
    <span><i class="dot s-default"></i>走接口默认</span>
    <span><i class="dot s-absent"></i>不参与</span>
    <span style="color:#f0a4a0">Tesl = 实现在 Tesla 仓</span>
    <span style="color:var(--accent)">← 点任意格子看它干了啥</span>
  </div>

  <div class="drill" id="drill">
    <div class="hint">点上方矩阵任意格子 → 展开该方法的流程步骤图</div>
  </div>

  <div class="sec">
    <h3>卡点 · 施工中（从代码 TODO 扫出，共 __NTODO__ 处）</h3>
    <div class="blk">__TODOS__</div>
  </div>

  <div class="sec">
    <h3>结构性风险（代码事实）</h3>
    <div class="blk warn">__RISKS__</div>
  </div>

</div>

<script>
const DATA = __DATA__;
const ICON = {step:"■", note:"·", call:"→", guard:"◈", throw:"↳", fail:"↳", degrade:"↳"};
const esc = s => (s||"").replace(/&/g,"&amp;").replace(/</g,"&lt;");
const IND = 26;   // 每层分支的缩进像素

/* 分支拐角：从主干往右下拉一根 └ ，让“岔出去”有形体 */
function elbow(depth, kind){
  if(!depth) return "";
  const w = depth * IND;
  const col = (kind==="throw"||kind==="fail") ? "rgba(248,81,73,.55)"
            : (kind==="degrade") ? "rgba(210,153,34,.5)"
            : "rgba(139,148,158,.35)";
  // 前 depth-1 层只画竖线（穿过），最后一层画 └ 拐角
  let svg = '<svg class="elbow" width="'+w+'" height="22" viewBox="0 0 '+w+' 22">';
  for(let i=0;i<depth-1;i++){
    const x = i*IND + 8;
    svg += '<line x1="'+x+'" y1="0" x2="'+x+'" y2="22" stroke="rgba(139,148,158,.22)" stroke-width="1"/>';
  }
  const x = (depth-1)*IND + 8;
  svg += '<path d="M'+x+' 0 L'+x+' 11 Q'+x+' 15 '+(x+5)+' 15 L'+w+' 15" '+
         'fill="none" stroke="'+col+'" stroke-width="1.2"/>';
  svg += '</svg>';
  return '<div class="ind" style="width:'+w+'px">'+svg+'</div>';
}

function render(pk, sk, td){
  document.querySelectorAll(".cell.sel").forEach(e=>e.classList.remove("sel"));
  td.classList.add("sel");
  const p = DATA.platforms.find(x=>x.key===pk);
  const st = DATA.stages.find(x=>x.key===sk);
  const c0 = p.cells[sk];
  /* 创单格：真实逻辑是全平台共享的 doCreateOrder（MQ 消费），缓存里存一份，渲染时注入 */
  const c = (sk==="createOrder" && c0.state==="full" && DATA.createOrderFlow)
    ? Object.assign({}, c0, {steps: DATA.createOrderFlow.steps,
        srcFile: DATA.createOrderFlow.file, line: DATA.createOrderFlow.line,
        mth: "doCreateOrder()"})
    : c0;
  const box = document.getElementById("drill");

  if((!c.steps || !c.steps.length) && !fac){
    box.innerHTML =
      '<div class="dh"><b>'+p.cn+' · '+st.label+'</b>'+
      '<span class="mth">'+(st.method||c.route||"—")+'</span>'+
      (c.repo?'<span class="repo '+c.repo+'" style="position:static">'+c.repo+'</span>':'')+
      '<span class="cnt">'+esc(c.note)+'</span></div>'+
      '<div class="hint">'+esc(c.note||"无可展开的方法体")+'</div>';
    return;
  }

const OPCN = {read:"取", write:"写", update:"更", delete:"删", mq:"MQ", lock:"锁", invoke:"调", rpc:"调", http:"调"};
function opChip(s){
  if(!s.op) return '<span class="tag">'+esc(s.label||"")+'</span>';
  const t = OPCN[s.op] + (s.tgt && s.op!=="mq" ? "·"+s.tgt : "");
  return '<i class="op op-'+s.op+'">'+t+'</i>';
}

  /* 递归渲染：每层 children 包在 .kids 容器里，点宿主行的胶囊展开/收起 */
  function rowsFor(steps, base, lvl){
    return steps.map(s=>{
      const d = base + (s.depth||0);
      let bd = "";
      if(s.cond) bd += '<span class="cond">'+esc(s.cond)+'</span>';
      if(s.kind==="step")        bd += '<span class="no'+(s.auto?' auto':'')+'">'+s.no+'</span>'+esc(s.text);
      else if(s.kind==="call")   bd += opChip(s)+esc(s.text);
      else if(s.kind==="guard")  bd += '<i class="op op-validate">校验</i>'+esc(s.text);
      else if(s.kind==="throw")  bd += '<em>'+esc(s.ex)+'</em>'+esc(s.text||"(无文案)");
      else if(s.kind==="fail")   bd += '<em>失败返回</em>'+esc(s.text||"(无文案)");
      else bd += esc(s.text);
      // 合并进来的连续注释段：首行带 +N 行胶囊，点开才铺剩余
      if(s.more && s.more.length){
        bd += '<span class="nmore">⋯ +'+s.more.length+' 行</span>'+
              '<div class="next" hidden>'+
              s.more.map(t=>'<div>'+esc(t)+'</div>').join('')+'</div>';
      }
      let kids = "";
      if(s.children && s.children.length){
        bd += '<span class="into tog">↳ '+(s.collapsed?'展开':'收起')+' '+
              esc(s.intoMethod)+'() · '+s.intoCount+' 步</span>';
        kids = '<div class="kids"'+(s.collapsed?' hidden':'')+'>'+
               rowsFor(s.children, d+1, lvl+1)+'</div>';
      }
      const ref = (s.file||c.srcFile||p.file)+':'+s.line;
      const leaf = (s.kind==="call" && !(s.children&&s.children.length)) ? " leaf" : "";
      const opc = s.op ? " op-"+s.op : "";
      return '<div class="fi k-'+s.kind+leaf+opc+(lvl>0?' inl':'')+'" data-ref="'+esc(ref)+'" title="双击复制 '+esc(ref)+'">'+
        '<div class="gut">L'+s.line+'</div>'+
        elbow(d, s.kind)+
        '<div class="ico">'+ICON[s.kind]+'</div>'+
        '<div class="bd">'+bd+'</div></div>' + kids;
    }).join("");
  }

  /* 统计递归遭遍全树 */
  function walk(steps, f){ steps.forEach(s=>{ f(s); if(s.children) walk(s.children, f); }); }
  const cnt = {step:0, note:0, call:0, guard:0, throw:0, fail:0, degrade:0};
  let deepest = 1;
  (function meas(steps, lv){ steps.forEach(s=>{ cnt[s.kind]++;
     if(s.children){ deepest=Math.max(deepest,lv+1); meas(s.children,lv+1);} });})(c.steps,1);

  /* 操作汇总：按语义归类统计，目标细分（ES/三方/Dubbo…） */
  const agg = {read:{}, write:{}, update:{}, mq:0, lock:0, del:0, val:0, rpc:0, http:0};
  const fac = (DATA.facade||{})[sk];
  const aggFn = s=>{
    if(s.kind==="guard") agg.val++;
    else if(s.kind==="call" && s.op){
      if(s.op==="mq") agg.mq++;
      else if(s.op==="lock") agg.lock++;
      else if(s.op==="delete") agg.del++;
      else if(s.op==="rpc") agg.rpc++;
      else if(s.op==="http") agg.http++;
      else if(agg[s.op]){ const t=s.tgt||"其它"; agg[s.op][t]=(agg[s.op][t]||0)+1; }
    }
  };
  walk(c.steps, aggFn);
  if(fac) walk(fac.steps, aggFn);   /* Facade 公共环节也计入：发MQ/锁在这层 */
  const dt = o => { const e=Object.entries(o); const n=e.reduce((a,[,v])=>a+v,0);
    return [n, n?' ('+e.map(([k,v])=>k+v).join(" ")+')':''] ; };
  const fchip = (f, cls, label, n, extra) => {
    const body = '<i class="op '+cls+'">'+label+'</i>'+n+(extra||'');
    return n>0 ? '<span class="fchip" data-f="'+f+'">'+body+'</span>'
               : '<span class="fchip off">'+body+'</span>';
  };
  const [nr,er]=dt(agg.read), [nw,ew]=dt(agg.write), [nu,eu]=dt(agg.update);
  const opsum =
    '<div class="opsum">'+
    fchip("validate","op-validate","校验",agg.val)+
    fchip("read","op-read","取数",nr,er)+
    fchip("write","op-write","落库",nw,ew)+
    fchip("update","op-update","更新",nu,eu)+
    fchip("rpc","op-rpc","调Dubbo",agg.rpc)+
    fchip("http","op-http","调三方",agg.http)+
    fchip("mq","op-mq","MQ",agg.mq)+
    (agg.lock?fchip("lock","op-lock","锁",agg.lock):"")+
    fchip("exit","op-delete","出口",cnt.throw+cnt.fail)+
    '<span class="fhint">点分类只看该类 · 再点还原</span>'+
    '</div>';

  /* 返回字段溜源表：返回的每个字段从哪拿的 */
  let rets = "";
  if(c.returns && c.returns.length){
    rets = '<div class="rets"><h4>返回字段从哪拿 · '+c.returns.length+'</h4>'+
      c.returns.map(r=>'<div class="rrow"><span class="rf">'+esc(r.field)+
        '</span><span class="ra">←</span><span class="rs">'+esc(r.src)+
        '</span><span class="rl">L'+r.line+'</span></div>').join('')+'</div>';
  }

  /* Facade 入口公共环节：路由/时间拦截/锁/核销后发MQ 在这层，折叠条顶在流程最前 */
  let facHtml = "";
  if(fac){
    const fref = fac.file+':'+fac.line;
    facHtml =
      '<div class="fi k-call op-rpc" data-ref="'+esc(fref)+'" title="双击复制 '+esc(fref)+'">'+
      '<div class="gut">L'+fac.line+'</div><div class="ico">→</div>'+
      '<div class="bd"><i class="op op-rpc">Facade</i>ThirdUnifyFacadeImpl.'+esc(fac.method)+'()'+
      '<span class="into tog">↳ 展开 入口公共环节(路由/锁/发MQ) · '+fac.count+' 步</span></div></div>'+
      '<div class="kids" hidden>'+rowsFor(fac.steps, 1, 1)+'</div>';
  }

  box.innerHTML =
    '<div class="dh"><b>'+p.cn+' · '+st.label+'</b>'+
    '<span class="mth">'+(st.method? st.method+'()' : (c.mth||c.route||''))+'</span>'+
    (c.repo?'<span class="repo '+c.repo+'" style="position:static">'+c.repo+'</span>':'')+
    (c.fromDefault?'<span class="repo ultra" style="position:static" title="平台未 override，走 ThirdUnifyFlow 接口默认实现，全平台公用">接口默认</span>':'')+
    '<span class="src" title="'+esc(c.srcFile||p.file)+'">'+esc(c.srcFile||p.file)+'</span>'+
    '<span class="dens"><i data-m="outline">脉络</i>'+
      '<i data-m="std" class="on">标准</i><i data-m="all">全部</i></span>'+
    '<span class="cnt">主干 '+cnt.step+' · 出口 '+(cnt.throw+cnt.fail)+
      ' · 降级 '+cnt.degrade+' · 钻深 '+deepest+' 层</span></div>'+
    opsum+
    '<div class="flow m-std">'+facHtml+rowsFor(c.steps||[], 0, 0)+'</div>'+
    rets+
    '<div class="lg2">'+
      '<span style="color:var(--accent)">■ 主干步骤</span>'+
      '<span>→ 直行调用</span>'+
      '<span style="color:var(--todo)">◈ 校验拦截</span>'+
      '<span style="color:var(--broken)">↳ 岔出：抛错/失败返回</span>'+
      '<span style="color:#e3b341">↳ 岔出：降级兜底</span>'+
      '<span>缩进 = 嵌套层级，灰胶囊 = 进入条件</span>'+
      '<span style="color:#8fd0a8">绿底 = 展开的委派类代码，胶囊可逐层点开</span>'+
      '<span style="color:var(--accent)">双击行 = 复制 文件:行号</span>'+
      '<span>脉络=只留步骤与出口 · 标准=隐注解 · 全部=含注解(斜体)</span>'+
    '</div>';

  /* 密度切换：换 .flow 的 m-* 类，纯 CSS 显隐 */
  box.querySelectorAll(".dens i").forEach(b=>b.onclick=()=>{
    box.querySelectorAll(".dens i").forEach(x=>x.classList.remove("on"));
    b.classList.add("on");
    const fl = box.querySelector(".flow");
    const f = fl.getAttribute("data-f");
    fl.className = "flow m-"+b.dataset.m;
    if(f) fl.setAttribute("data-f", f);
  });

  /* 分类过滤：点汇总胶囊只看该类，再点还原；切换不丢密度档 */
  const HIT = {validate:".k-guard", read:".op-read", write:".op-write",
               update:".op-update", delete:".op-delete", mq:".op-mq",
               lock:".op-lock", rpc:".op-rpc", http:".op-http",
               exit:".k-throw,.k-fail"};
  /* 只给「名下有命中」的步骤打路标：按文档顺序，命中行归属于它前面最近的步骤 */
  function markKeep(fl, f){
    fl.querySelectorAll(".fi.f-keep").forEach(x=>x.classList.remove("f-keep"));
    if(!f) return;
    const sel = HIT[f]; if(!sel) return;
    let lastStep = null;
    fl.querySelectorAll(".fi").forEach(row=>{
      if(row.classList.contains("k-step")){ lastStep = row; return; }
      if(row.matches(sel.split(",").map(s=>".fi"+s).join(",")) && lastStep)
        lastStep.classList.add("f-keep");
    });
  }
  box.querySelectorAll(".fchip[data-f]").forEach(ch=>ch.onclick=()=>{
    const fl = box.querySelector(".flow");
    const f = ch.dataset.f, cur = fl.getAttribute("data-f");
    box.querySelectorAll(".fchip").forEach(x=>x.classList.remove("on"));
    if(cur === f){ fl.removeAttribute("data-f"); markKeep(fl, null); }
    else { fl.setAttribute("data-f", f); ch.classList.add("on"); markKeep(fl, f); }
  });
}

document.querySelectorAll("td.cell").forEach(td=>{
  td.onclick = ()=>render(td.dataset.p, td.dataset.s, td);
});

/* 折叠展开/收起：胶囊所在行的下一个兄弟就是它的 .kids 容器，逐层可点 */
document.addEventListener("click", e=>{
  const t = e.target.closest(".tog");
  if(!t) return;
  const row = t.closest(".fi");
  const kids = row && row.nextElementSibling;
  if(!kids || !kids.classList.contains("kids")) return;
  const show = kids.hasAttribute("hidden");
  show ? kids.removeAttribute("hidden") : kids.setAttribute("hidden","");
  t.textContent = t.textContent.replace(show?"展开":"收起", show?"收起":"展开");
});
/* 注解块展开/收起 */
document.addEventListener("click", e=>{
  const t = e.target.closest(".nmore");
  if(!t) return;
  const ext = t.parentElement.querySelector(".next");
  if(!ext) return;
  const show = ext.hasAttribute("hidden");
  show ? ext.removeAttribute("hidden") : ext.setAttribute("hidden","");
});
/* 双击任意逻辑行：复制 文件:行号，直接粘到 IDE 跳转 */
let toastTimer = null;
function toast(msg){
  let t = document.querySelector(".toast");
  if(!t){ t = document.createElement("div"); t.className="toast"; document.body.appendChild(t); }
  t.textContent = msg;
  requestAnimationFrame(()=>t.classList.add("on"));
  clearTimeout(toastTimer);
  toastTimer = setTimeout(()=>t.classList.remove("on"), 1800);
}
document.addEventListener("dblclick", e=>{
  const row = e.target.closest(".fi");
  if(!row || !row.dataset.ref) return;
  const ref = row.dataset.ref;
  const fallback = ()=>{
    const ta = document.createElement("textarea");
    ta.value = ref; document.body.appendChild(ta); ta.select();
    let ok = false; try{ ok = document.execCommand("copy"); }catch(_){}
    ta.remove(); toast((ok?"已复制  ":"复制失败  ")+ref);
  };
  if(navigator.clipboard && navigator.clipboard.writeText){
    navigator.clipboard.writeText(ref)
      .then(()=>toast("已复制  "+ref), fallback);
  } else fallback();
});

// 默认展开高德验券（拦截与降级最富的一格）
const d0 = document.querySelector('td.cell[data-p="GAODE"][data-s="consultVerify"]');
if(d0) d0.click();
</script>
"""

d = data
sym = {"full": "s-full", "todo": "s-todo", "broken": "s-broken",
       "default": "s-default", "absent": "s-absent", "pull": "s-pull"}

# 泳道
lane = []
for i, s in enumerate(d["stages"]):
    if i:
        lane.append('<span class="arw">→</span>')
    tag = '<span class="mq">MQ</span>' if s["key"] == "createOrder" else ""
    if s["key"] == "issue":
        tag = '<span class="mq" style="color:#8fd0a8;'\
              'border-color:rgba(63,185,80,.45)">SPI/主动查</span>'
    lane.append("<span>%s%s</span>" % (s["label"], tag))
LANE = "".join(lane)

THEAD = "".join("<th>%s</th>" % s["label"] for s in d["stages"])

rows = []
for p in d["platforms"]:
    cls = " cdd" if p["key"] == "CDD" else ""
    todo = (' <span style="color:var(--todo);font-size:10px">▲%d</span>'
            % p["todoCount"]) if p["todoCount"] else ""
    ch = p["channel"] if p["channel"] else "—"
    cells = []
    for s in d["stages"]:
        c = p["cells"][s["key"]]
        ln = ('<div class="ln">%s</div>' % c["line"]) if c.get("line") else ""
        rb = ""
        if c.get("repo"):
            rb = '<span class="repo %s">%s</span>' % (
                c["repo"], c["repo"][:1].upper() + c["repo"][1:4])
        cells.append(
            '<td class="cell" data-p="%s" data-s="%s" title="%s %s — %s">'
            '%s<div class="dot %s"></div>%s</td>'
            % (p["key"], s["key"], p["cn"], s["label"],
               c["note"] or "已实现", rb, sym[c["state"]], ln)
        )
    rows.append(
        '<tr><td class="pf"><div class="pn%s">%s%s</div>'
        '<div class="pi">%s · %s · %d 行</div></td>%s</tr>'
        % (cls, p["cn"], todo, ch, p["serialPrefix"] or "—",
           p["loc"], "".join(cells))
    )
TBODY = "".join(rows)

TODOS = "".join(
    '<div class="row"><code>%s:%d</code><p>%s</p></div>'
    % (t["file"], t["line"], t["text"].replace("<", "&lt;"))
    for t in d["todos"]
)

risks = [
    ("创单集合与时间限制集合共用同一常量",
     "<b>CREATE_ORDER_PLATFORMS = TIME_RESTRICTED_PLATFORMS</b>："
     "「核销后创单」与「23:00-2:00 禁核销」两个语义耦在一个常量上，"
     "改一个必然动另一个。代码注释自称“未来可能解耦”。")
    if d["createOrderAliasedToTimeLimit"] else None,
    ("车点点与高德券码撞码",
     "12 位码形态重叠，靠<b>门店报名剪枝 + 主动探测 + 店员选渠道</b>三段消歧，"
     "是全链路最脆的一环（ThirdUnifyRouter 三态：RESOLVED/AMBIGUOUS/NONE）。"),
    ("车点点是最大未完工体",
     "1375 行（全场最多）却有 6 处 TODO，类注释自述"
     "「本类为落地骨架…<b>可编译、不可用于生产</b>」，且退款直接断路。"
     "当前分支名 feature/che-dian-dian 正是它。"),
    ("文档与代码已漂移",
     "方案文档全篇按「四渠道」叙事，代码是 <b>7 平台</b>；"
     "执行进度文档仍写分支 three-canals-unified-0615，"
     "实际已切 feature/che-dian-dian。"),
]
RISKS = "".join(
    '<div class="row"><code>%02d</code><p><b>%s</b> — %s</p></div>'
    % (i + 1, t, txt)
    for i, (t, txt) in enumerate(r for r in risks if r)
)

html = (HTML
        .replace("__BRANCH__", d["repo"]["branch"])
        .replace("__HEAD__", d["repo"]["head"][:58])
        .replace("__DIRTY__", "脏" if d["repo"]["dirty"] else "干净")
        .replace("__TBRANCH__", d["repo"]["tesla"]["branch"] or "?")
        .replace("__TSCANREF__", d["repo"]["tesla"].get("scanRef", "?"))
        .replace("__TESLAHEAD__", d["repo"]["tesla"]["head"][:30])
        .replace("__GEN__", d["generated"])
        .replace("__LANE__", LANE)
        .replace("__THEAD__", THEAD)
        .replace("__TBODY__", TBODY)
        .replace("__NTODO__", str(len(d["todos"])))
        .replace("__TODOS__", TODOS)
        .replace("__RISKS__", RISKS)
        .replace("__DATA__", json.dumps(d, ensure_ascii=False)))

with open(OUT, "w", encoding="utf-8") as f:
    f.write(html)
print("原型: %s" % OUT)
