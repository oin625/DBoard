#!/usr/bin/env python3
"""快速诊断 DBoard GUI 空白问题"""
import tkinter as tk
import os, sys

LOG = os.path.expanduser("~/dboard_debug.log")
CACHE = os.path.expanduser("~/.claude/demand-center-cache.md")

def log(msg):
    with open(LOG, "a") as f:
        f.write(msg + "\n")
    print(msg)

log("=" * 40)
log(f"Python: {sys.version}")
log(f"Tk version: {tk.TkVersion}")
log(f"Cache exists: {os.path.exists(CACHE)}")

root = tk.Tk()
root.title("D板诊断")
root.geometry("420x400")
root.configure(bg="#0f0f0f")

log(f"Screen: {root.winfo_screenwidth()}x{root.winfo_screenheight()}")

# 测试1: 直接放 Label
lbl1 = tk.Label(root, text="测试1: 直接Label", bg="#0f0f0f", fg="white", font=("PingFang SC", 14))
lbl1.pack(pady=10)

# 测试2: Frame 里放 Label
f2 = tk.Frame(root, bg="#1a1a1a", padx=10, pady=10)
f2.pack(fill=tk.X, padx=16, pady=4)
tk.Label(f2, text="测试2: Frame里的Label", bg="#1a1a1a", fg="white", font=("PingFang SC", 12)).pack(side=tk.LEFT)

# 测试3: Canvas + scroll_frame（模拟实际结构）
canvas = tk.Canvas(root, bg="#0f0f0f", highlightthickness=0)
sf = tk.Frame(canvas, bg="#0f0f0f")
cw = canvas.create_window((0, 0), window=sf, anchor="nw")
canvas.bind("<Configure>", lambda e: canvas.itemconfigure(cw, width=e.width))
sf.bind("<Configure>", lambda e: canvas.configure(scrollregion=canvas.bbox("all")))
canvas.pack(fill=tk.BOTH, expand=True)

for i in range(5):
    row = tk.Frame(sf, bg="#1a1a1a", padx=12, pady=8)
    row.pack(fill=tk.X, padx=12, pady=2)
    tk.Label(row, text=f"测试3-{i}: Canvas内的卡片", bg="#1a1a1a", fg="white", font=("PingFang SC", 12)).pack(side=tk.LEFT)

def after_show():
    log(f"Canvas size: {canvas.winfo_width()}x{canvas.winfo_height()}")
    log(f"SF size: {sf.winfo_width()}x{sf.winfo_height()}")
    log(f"SF children: {len(sf.winfo_children())}")
    log(f"Canvas window width: {canvas.itemcget(cw, 'width')}")
    
    # 检查每个子组件
    for i, c in enumerate(sf.winfo_children()):
        log(f"  child[{i}]: class={c.winfo_class()} w={c.winfo_width()} h={c.winfo_height()} visible={c.winfo_viewable()}")
    
    log("诊断完成 — 你看到了几行文字？")

root.after(1000, after_show)
root.mainloop()
