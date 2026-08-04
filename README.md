# DBoard — Mac 菜单栏 D板看板

Mac 菜单栏常驻插件，直接读取 `~/.claude/demand-center-cache.md`，一键查看个人工作看板。

## 功能

- 📋 菜单栏图标，点击弹出 D 板概览
- 🔴 按优先级分组显示所有条目
- ⏰ 截止日期倒计时，紧急条目高亮
- 📝 今日零碎清单，显示完成进度
- 🔄 实时监听文件变更，自动刷新
- 🚀 开机自启，常驻菜单栏

## 安装

```bash
cd /Users/zz/work/code/other/DBoard
./install.sh
```

一键搞定：构建 → 打包 .app → 安装到 ~/Applications → 配置开机自启 → 立即启动。

## 要求

- macOS 13.0+
- Swift 5.9+（Xcode Command Line Tools）

## 数据源

读取 `~/.claude/demand-center-cache.md`，这个文件由 Claude D板 skill 维护。
文件变更时 UI 自动刷新，无需手动操作。

## 卸载

```bash
rm -rf ~/Applications/DBoard.app
launchctl unload ~/Library/LaunchAgents/com.zz.dboard.plist
rm ~/Library/LaunchAgents/com.zz.dboard.plist
```
