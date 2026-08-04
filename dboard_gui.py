#!/usr/bin/env python3
"""
DBoard — Mac D板看板 (Tkinter · Tk8.5 兼容)
数据源: ~/.claude/demand-center-cache.md
"""
import tkinter as tk
from tkinter import font as tkfont
import os, re
from datetime import date

CACHE_PATH = os.path.expanduser("~/.claude/demand-center-cache.md")
WIN_W, WIN_H = 440, 640
REFRESH_MS = 5000

# ── 浅色主题（兼容 Tk 8.5）──
C = {
    "bg":          "#f5f5f7",
    "card":        "#ffffff",
    "card_hover":  "#eef1f5",
    "card_urgent": "#fff0f0",
    "text":        "#1d1d1f",
    "text2":       "#6e6e73",
    "text3":       "#aeaeb2",
    "red":         "#ff3b30",
    "orange":      "#ff9500",
    "yellow":      "#aa8800",
    "green":       "#34c759",
    "blue":        "#007aff",
    "purple":      "#af52de",
    "border":      "#d2d2d7",
    "bar_bg":      "#e5e5ea",
    "bar_fill":    "#34c759",
    "header":      "#ffffff",
    "done_text":   "#aeaeb2",
}

PRIO = {
    "p0": ("🔴", C["red"],    "重要且紧急"),
    "p1": ("🟡", C["yellow"], "重要不紧急"),
    "p2": ("🟠", C["orange"], "紧急不重要"),
    "p3": ("🟢", C["green"],  "不紧急不重要"),
}

STATUS_C = {
    "进行中": C["blue"],
    "待开始": C["text3"],
    "已完成": C["green"],
    "挂起":   C["orange"],
}


# ── 数据 ──
class DItem:
    def __init__(self, did, project, title, status, priority, deadline=None):
        self.did, self.project, self.title = did, project, title
        self.status, self.priority, self.deadline = status, priority, deadline

    @property
    def days_left(self):
        if not self.deadline: return None
        try:
            m, d = map(int, self.deadline.split("."))
            return max(0, (date(date.today().year, m, d) - date.today()).days)
        except: return None

    @property
    def urgent(self):
        d = self.days_left
        return d is not None and d <= 3


class TodoItem:
    def __init__(self, text, done, linked=None):
        self.text, self.done, self.linked = text, done, linked


# ── 解析 ──
def parse():
    if not os.path.exists(CACHE_PATH): return [], [], None
    with open(CACHE_PATH, encoding="utf-8") as f: content = f.read()
    lines = content.split("\n")
    items, todos = [], []
    sync_time = cur_prio = cur = cur_desc = None
    in_todo = False
    pmap = {"## 🔴":"p0", "## 🟡":"p1", "## 🟠":"p2", "## 🟢":"p3"}

    def flush():
        nonlocal cur, cur_desc
        if cur and cur_prio:
            items.append(DItem(cur["id"], cur["proj"], cur_desc or "", cur["st"], cur_prio, cur.get("dl")))
        cur = cur_desc = None

    for ln in lines:
        s = ln.strip()
        if s.startswith("<!-- synced:"):
            sync_time = s.replace("<!-- synced:","").replace("-->","").strip(); continue
        hit = False
        for pfx, p in pmap.items():
            if s.startswith(pfx): flush(); cur_prio = p; in_todo = False; hit = True; break
        if hit: continue
        if s.startswith("## 📝"): flush(); in_todo = True; cur_prio = None; continue
        if in_todo and re.match(r"- \[[ xX]\]", s):
            done = s[3] in "xX"
            txt = re.sub(r"^- \[[ xX]\]\s*", "", s)
            lnk = None; m = re.search(r"`→\s*(D\d{3})`", txt)
            if m: lnk = m.group(1)
            txt = re.sub(r"\s*`→\s*D\d{3}`\s*", "", txt).strip()
            todos.append(TodoItem(txt, done, lnk)); continue
        if cur_prio and re.match(r"###\s+D\d{3}", s):
            flush()
            did = re.search(r"(D\d{3})", s).group(1)
            pm = re.search(r"【([^】]+)】", s); proj = pm.group(1) if pm else ""
            st = "待开始"
            for tag in ["#进行中","#已完成","#挂起","#待开始"]:
                if tag in s: st = tag[1:]; break
            dm = re.search(r"🎯(\d+\.\d+)", s); dl = dm.group(1) if dm else None
            cur = {"id":did,"proj":proj,"st":st,"dl":dl}; cur_desc = None; continue
        if cur and s.startswith("- **描述**"):
            cur_desc = re.sub(r"^- \*\*描述\*\*[：:]\s*", "", s)
    flush()
    return items, todos, sync_time


def toggle_todo(index):
    if not os.path.exists(CACHE_PATH): return
    with open(CACHE_PATH, encoding="utf-8") as f: lines = f.readlines()
    in_todo = False; idx = 0
    for i, ln in enumerate(lines):
        if ln.strip().startswith("## 📝"): in_todo = True; continue
        if in_todo and re.match(r"\s*- \[[ xX]\]", ln):
            if idx == index:
                if "- [ ]" in ln: lines[i] = ln.replace("- [ ]","- [x]",1)
                else: lines[i] = re.sub(r"- \[[xX]\]","- [ ]",ln,count=1)
                break
            idx += 1
    with open(CACHE_PATH,"w",encoding="utf-8") as f: f.writelines(lines)


# ── App ──
class DBoardApp:
    def __init__(self):
        self.root = tk.Tk()
        self.root.title("D板")
        self.root.geometry(f"{WIN_W}x{WIN_H}")
        self.root.configure(bg=C["bg"])
        self.root.resizable(True, True)
        self.root.minsize(380, 400)
        sx = self.root.winfo_screenwidth()
        self.root.geometry(f"+{sx - WIN_W - 40}+60")

        self.f_h1    = tkfont.Font(family="PingFang SC", size=18, weight="bold")
        self.f_h2    = tkfont.Font(family="PingFang SC", size=13, weight="bold")
        self.f_body  = tkfont.Font(family="PingFang SC", size=12)
        self.f_small = tkfont.Font(family="PingFang SC", size=11)
        self.f_tiny  = tkfont.Font(family="PingFang SC", size=9)
        self.f_mono  = tkfont.Font(family="Menlo", size=12, weight="bold")
        self.f_mono_s= tkfont.Font(family="Menlo", size=9)

        self.last_mt = 0
        self._build()
        self.refresh()
        self._watch()

    def _build(self):
        # ── 用 Canvas 画所有内容（Canvas 自定义颜色在 Tk8.5 也生效）──
        self.canvas = tk.Canvas(self.root, bg=C["bg"], highlightthickness=0, borderwidth=0)
        self.canvas.pack(fill=tk.BOTH, expand=True)

        # macOS 滚轮
        self.canvas.bind_all("<MouseWheel>", self._on_scroll)

        self._all_items = []  # (canvas_id, type, data)

    def _on_scroll(self, e):
        self.canvas.yview_scroll(-1 * e.delta, "units")

    def _clear(self):
        self.canvas.delete("all")
        self._all_items = []

    # ── 绘制方法（全部用 Canvas 原生绘图）──
    def _draw_rect(self, x, y, w, h, fill, outline="", radius=8):
        """圆角矩形"""
        r = radius
        self.canvas.create_arc(x, y, x+2*r, y+2*r, start=90, extent=90, fill=fill, outline=outline)
        self.canvas.create_arc(x+w-2*r, y, x+w, y+2*r, start=0, extent=90, fill=fill, outline=outline)
        self.canvas.create_arc(x, y+h-2*r, x+2*r, y+h, start=180, extent=90, fill=fill, outline=outline)
        self.canvas.create_arc(x+w-2*r, y+h-2*r, x+w, y+h, start=270, extent=90, fill=fill, outline=outline)
        self.canvas.create_rectangle(x+r, y, x+w-r, y+h, fill=fill, outline="")
        self.canvas.create_rectangle(x, y+r, x+w, y+h-r, fill=fill, outline="")

    def _draw_text(self, x, y, text, font, fill, anchor="nw", max_width=None):
        tid = self.canvas.create_text(x, y, text=text, font=font, fill=fill, anchor=anchor)
        if max_width:
            # 截断过长文字
            bbox = self.canvas.bbox(tid)
            if bbox and (bbox[2] - bbox[0]) > max_width:
                while len(text) > 3:
                    text = text[:-1]
                    self.canvas.itemconfig(tid, text=text + "…")
                    bbox = self.canvas.bbox(tid)
                    if bbox and (bbox[2] - bbox[0]) <= max_width:
                        break
        return tid

    def refresh(self):
        items, todos, sync_time = parse()
        self._clear()

        W = max(self.canvas.winfo_width(), WIN_W)
        y = 0
        pad = 18
        card_pad = 14

        # ── Header ──
        self._draw_rect(0, y, W, 56, C["header"])
        self._draw_text(pad + 2, y + 16, "📋", self.f_h1, C["text"])
        self._draw_text(pad + 32, y + 16, "D板", self.f_h1, C["text"])

        uc = sum(1 for i in items if i.urgent)
        dc = sum(1 for t in todos if t.done)
        info = f"今日 {len(todos)} 项"
        if uc: info = f"⚠️ {uc}项紧急 · " + info
        self._draw_text(W - pad, y + 22, info, self.f_small, C["text2"], anchor="ne")
        y += 56

        # 分割线
        self.canvas.create_line(0, y, W, y, fill=C["border"])
        y += 1

        # ── 条目 ──
        for pk in ["p0", "p1", "p2", "p3"]:
            gi = [i for i in items if i.priority == pk]
            if not gi: continue

            # 分组标题
            y += 14
            dot, color, label = PRIO[pk]
            self._draw_text(pad, y, f"{dot} {label}", self.f_tiny, color)
            y += 18

            for it in gi:
                y = self._draw_card(it, y, W, pad, card_pad)

        # ── 分割线 ──
        y += 12
        self.canvas.create_line(pad, y, W - pad, y, fill=C["border"])
        y += 12

        # ── 今日零碎标题 ──
        self._draw_text(pad, y, "📝 今日零碎", self.f_h2, C["text"])
        self._draw_text(W - pad, y + 2, f"{dc}/{len(todos)}", self.f_mono_s, C["text3"], anchor="ne")
        y += 28

        # 进度条
        bar_w = W - pad * 2
        self._draw_rect(pad, y, bar_w, 4, C["bar_bg"], radius=2)
        if todos:
            fill_w = max(4, int(bar_w * dc / len(todos)))
            self._draw_rect(pad, y, fill_w, 4, C["bar_fill"], radius=2)
        y += 14

        # ── Todo 列表 ──
        for idx, td in enumerate(todos):
            y = self._draw_todo(td, idx, y, W, pad)

        # 底部留白
        y += 30

        # 底部信息
        self.canvas.create_line(0, y, W, y, fill=C["border"])
        self._draw_rect(0, y, W, 36, C["header"])
        if sync_time:
            try:
                t = sync_time.split("T")[1][:5]
                self._draw_text(pad, y + 10, f"同步 {t}", self.f_tiny, C["text3"])
            except: pass

        # 刷新按钮
        rid = self._draw_text(W - pad, y + 10, "↻ 刷新", self.f_small, C["blue"], anchor="ne")
        self.canvas.tag_bind(rid, "<Button-1>", lambda e: self.refresh())
        y += 36

        # 滚动区域
        self.canvas.configure(scrollregion=(0, 0, W, y))

    def _draw_card(self, item, y, W, pad, cpad):
        card_w = W - pad * 2
        bg = C["card_urgent"] if item.urgent else C["card"]

        # 先测量需要的高度
        card_h = 52
        if item.title: card_h = 68

        self._draw_rect(pad, y, card_w, card_h, bg, outline=C["border"], radius=8)

        # 左侧
        lx = pad + cpad
        ty = y + 12

        self._draw_text(lx, ty, item.did, self.f_mono, C["text"])
        self._draw_text(lx + 52, ty, item.project, self.f_small, C["text2"], max_width=card_w - 180)

        if item.title:
            self._draw_text(lx, ty + 24, item.title, self.f_tiny, C["text3"], max_width=card_w - 140)

        # 右侧
        rx = pad + card_w - cpad
        sc = STATUS_C.get(item.status, C["text3"])
        self._draw_text(rx, ty, item.status, self.f_tiny, sc, anchor="ne")

        dl = item.days_left
        if dl is not None:
            if dl <= 3:
                self._draw_text(rx, ty + 18, f"⚠️ {dl}天", self.f_small, C["red"], anchor="ne")
            else:
                self._draw_text(rx, ty + 18, f"{dl}天", self.f_tiny, C["text3"], anchor="ne")

        return y + card_h + 4

    def _draw_todo(self, todo, idx, y, W, pad):
        h = 32

        # 勾选框
        if todo.done:
            ck_text, ck_fg = "✓", C["green"]
            txt_fg = C["done_text"]
        else:
            ck_text, ck_fg = "○", C["text3"]
            txt_fg = C["text"]

        ck_id = self._draw_text(pad + 4, y + 6, ck_text, self.f_body, ck_fg)
        txt_id = self._draw_text(pad + 28, y + 7, todo.text, self.f_small, txt_fg, max_width=W - pad * 2 - 80)

        # 删除线（已完成）
        if todo.done:
            bbox = self.canvas.bbox(txt_id)
            if bbox:
                mid_y = (bbox[1] + bbox[3]) // 2
                self.canvas.create_line(bbox[0], mid_y, bbox[2], mid_y, fill=C["done_text"])

        # 关联标签
        if todo.linked:
            self._draw_text(W - pad, y + 8, todo.linked, self.f_mono_s, C["blue"], anchor="ne")

        # 点击区域
        hit = self.canvas.create_rectangle(pad, y, W - pad, y + h, fill="", outline="")
        def _toggle(e, i=idx):
            toggle_todo(i)
            self.refresh()
        self.canvas.tag_bind(hit, "<Button-1>", _toggle)
        self.canvas.tag_bind(ck_id, "<Button-1>", _toggle)
        self.canvas.tag_bind(txt_id, "<Button-1>", _toggle)

        return y + h

    def _watch(self):
        try:
            mt = os.path.getmtime(CACHE_PATH)
            if mt != self.last_mt:
                self.last_mt = mt
                self.refresh()
        except: pass
        self.root.after(REFRESH_MS, self._watch)

    def run(self):
        # 窗口显示后再刷新一次确保尺寸正确
        self.root.after(100, self.refresh)
        self.root.mainloop()


if __name__ == "__main__":
    DBoardApp().run()
