// LogSearch.swift —— 2026-09-21 Liquid Glass 重构后已按视图拆分为:
//   LogSearchModel.swift          数据模型 + 可钻取词扫描
//   LogSearchViewModel.swift      查询语义 + 后端 plumbing（API 冻结）
//   LogUIStyle.swift              共享 UI 原语（系统字体排版/玻璃材质/hover 按钮样式/动效）
//   LogSearchRootView.swift       根视图: 玻璃工具栏 + chips + 分栏骨架 + toast
//   LogSidebarView.swift          侧栏筛选（只看ERROR/时间预设/应用列表）
//   LogResultsListView.swift      结果列表 + 底部翻页条
//   LogInspectorView.swift        inspector 详情 + 全文文本视图
//   LogSearchWindowController.swift  面板窗口/快捷键监视
// 本文件保留为空壳（按团队规则不经 shell 删除文件, 可手动删除）。
