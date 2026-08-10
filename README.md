# DBoard — Mac 菜单栏个人 Agent 驾驶舱

Mac 菜单栏常驻应用。最初是读 `~/.claude/demand-center-cache.md` 的 D板任务看板，
现已演化为个人 AI agent 工作系统的驾驶舱：后台一队 agent（值守回复、资讯抓取、
文档同步）在干活，DBoard 让这一切可见、可控。

## 模块总览

菜单栏四个图标：D板主面板、系统监控（实时 CPU%）、Skills 看板、BizMap 业务地图。

| 模块 | 功能 | 数据源 |
|------|------|--------|
| D板看板 | 需求/零碎清单，优先级分组，截止倒计时，双写钉钉 | `~/.claude/demand-center-cache.md`（d-board skill 维护） |
| 引擎心跳 | Footer 三点状态条：值守/资讯/同步三个 daemon 的死活，点开看判定依据与修复命令 | launchctl + 各数据文件时间戳 |
| Reply Inbox | 钉钉待回复人工审批台：AI 起草 → 人批准 → 发送，支持配方沉淀 | `~/.dws/reply-pending.json`（reply-daemon） |
| Tech Scout | AI 精翻科技资讯流，历史留存 30 天 | `~/.claude/tech-scout-*.json`（tech-scout 定时任务） |
| Skills 看板 | agent 技能库治理：健康度、启停、归档、分类、实战验证状态 | 汇总 `~/.codex/skills`、Codex 插件、`~/.qoder-cn/skills` 与 Qoder CN 企业插件；Claude/Qoder 旧目录仅作迁移对照 |
| Agent Env | MCP / Hooks / 工作入口 / Context 全景可视 | 汇总 Codex、Zed、Qoder CN；显示 Luban/R2C/LoongSuite Hooks、项目 `AGENTS.md` 和可审计 Memory，旧配置显式标为遗留 |
| BizMap | TMYC 业务地图：服务卡片墙按梯队分组，搜需求关键词即路由（首查/次查高亮），D单联动，直达作战地图 | `~/.claude/bizmap-cache.json`（wiki 业务地图 gen_bizmap.py 生成） |
| SysMon | CPU/内存/温度/进程监控，AI 卡顿诊断 | 本机采样 + Qoder CN CLI |
| MarketMap | 大盘 Treemap（拖拽/缩放/聚焦） | 东方财富 + 腾讯行情 API |

交互：全局快捷键 Ctrl+D 呼出主面板，⌘K 命令面板，popover 可撕成独立窗口。
皮肤系统 5 套主题（含 NSVisualEffectView 原生毛玻璃）+ 7 种字体。

## AI 运行策略

- **DBoard 后台摘要/诊断**：Qoder CN CLI + `Qwen3.6-Flash`。
- **D板主动对话**：Qoder CN CLI + `Qwen3.8-Max`。
- **Codex**：复杂日常任务、跨应用与本机操作；DBoard 不会在 Qoder 失败时自动回退到 Codex，以避免意外消耗额度。
- **Zed**：代码与 Git 工作入口；选择 Qoder CN CLI 外部 Agent 时，Qoder CN 的 Luban、R2C、LoongSuite Hooks 在 CLI 内触发。Zed 原生 Agent 使用直连模型时不会触发这些 Qoder Hooks。

模型、认证和组织策略以各自运行时为准；看板只读取并展示配置，不保存 API Key。

## 安装

```bash
cd /Users/zz/work/code/other/DBoard
./install.sh
```

一键：构建 → 打包 .app → 安装到 ~/Applications → 开机自启 → 立即启动。

## 要求

- macOS 13.0+
- Swift 5.9+（Xcode Command Line Tools）
- 各模块依赖对应的后台 daemon，缺了不影响其他模块（Footer 心跳条会标灰/标红）

## 开发约定

- N=1 个人工具：硬编码本机路径是刻意决策，不做通用化
- 代码评审标准见 [REVIEW.md](REVIEW.md)，重要提交派独立 CodeReview subagent 按此评审
- 产品定位与路线见个人 Wiki：`~/Documents/one/projects/DBoard/`

## 卸载

```bash
rm -rf ~/Applications/DBoard.app
launchctl unload ~/Library/LaunchAgents/com.zz.dboard.plist
rm ~/Library/LaunchAgents/com.zz.dboard.plist
```
