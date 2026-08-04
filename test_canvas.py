#!/usr/bin/env python3
"""Canvas 绘图测试 — Tk 8.5"""
import tkinter as tk

root = tk.Tk()
root.title("Canvas测试")
root.geometry("400x300")

c = tk.Canvas(root, width=400, height=300)
c.pack(fill=tk.BOTH, expand=True)

# 纯色矩形
c.create_rectangle(20, 20, 380, 80, fill="lightblue", outline="gray")
c.create_text(200, 50, text="如果你看到这行 = Canvas正常", font=("Arial", 14), fill="black")

# 第二个
c.create_rectangle(20, 100, 380, 160, fill="#ffcccc", outline="gray")
c.create_text(200, 130, text="D001 三渠统一  进行中  37天", font=("Menlo", 13), fill="black")

# 第三个
c.create_rectangle(20, 180, 380, 240, fill="lightyellow", outline="gray")
c.create_text(200, 210, text="📝 今日零碎 (0/5)", font=("Arial", 14), fill="black")

c.create_text(200, 270, text="能看到3个彩色方块 = 全部正常", font=("Arial", 12), fill="gray")

root.mainloop()
