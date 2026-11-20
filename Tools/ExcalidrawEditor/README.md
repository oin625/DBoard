# D板本地绘图编辑器

基于 @excalidraw/excalidraw 0.18.1，在 D板的 WKWebView 中离线运行。通过原生桥接加载、编辑并显式保存同一份 .excalidraw 文件，不生成 PNG/SVG 预览或上传场景。

- 学习正文与笔记中的 file:// 链接在 D板内打开。
- 全局 Ctrl+M / 工具栏“新建画布”打开空白页；快捷键可在 D板设置中修改或禁用。
- 空白页只在内存中创建，第一次 ⌘S 才选择 .excalidraw 保存位置。
- 绿色按钮、工具栏“切换全屏”或 ⌃⌘F 使用 macOS 原生全屏。
- ⌘W 关闭当前画布窗口，未保存时先询问；⌘Q 退出整个 D板。
- Finder “打开方式 → D板”或 D板菜单“打开绘图…”支持普通源文件。
- ⌘S / 工具栏“保存”写回原文件；关闭或退出时询问未保存修改。
- 保存前比较磁盘原文，文件被其他程序改动时保留当前编辑并拒绝覆盖。
- 原生代码保留未知字段、未编辑元素和嵌入图片。单纯打开、缩放、移动视图不会改写文件。
- 依赖、CSS、字体随应用打包；编辑器使用非持久 WebKit 数据存储，不连接协作或云场景服务。

构建：Tools/build_app.sh 自动调用 node build.mjs。首次构建需要 npm；固定版本来自 package-lock.json。生成资源位于 Resources/ExcalidrawEditor，必须随二进制复制到 App 的 Contents/Resources。输入校验和避免重复构建资源。

局部验证：

```sh
DBOARD_EXCALIDRAW_SNAPSHOTS=/tmp/dboard-excalidraw-check swift test --build-system native --scratch-path .build/fast-release-native -c release -j 4 -Xswiftc -no-whole-module-optimization -Xswiftc -incremental --filter ExcalidrawTests
```

截图仅为临时测试产物；不在 LearningMaps 中保存额外文件。
