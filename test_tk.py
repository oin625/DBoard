#!/usr/bin/env python3
"""DBoard Tkinter 测试 — 验证云壳是否拦截"""
import tkinter as tk

root = tk.Tk()
root.title("D板测试")
root.geometry("300x150")

label = tk.Label(root, text="📋 D板\n\n如果你看到这个窗口\n说明云壳没拦截！", font=("Arial", 16))
label.pack(expand=True)

btn = tk.Button(root, text="关闭", command=root.destroy)
btn.pack(pady=10)

root.mainloop()
