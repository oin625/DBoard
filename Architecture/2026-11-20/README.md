# D板业务架构与技术架构研究

日期：2026-11-20。源码基线：DBoard `cbda38d`，研究开始时工作区无未提交改动。

结论：D板已经形成“研发协作驾驶舱 + 个人成长空间 + 工具门户”。最有价值的重构是把业务事实、命令和外部连接器从界面状态中抽出来，让 UI 与 CLI 使用同一套规则。建议采用渐进式模块化单体，先兼容现有 Markdown / JSON，再依据测量决定是否迁移事务存储。

## 阅读与画板导航

总图：[DBoard-architecture.excalidraw](DBoard-architecture.excalidraw)。

总图含六个可编辑画框，第一行是现状与诊断，第二行是目标与迁移：

| 画框 | 内容 |
|---|---|
| 01 | 业务架构现状：Main、Try、工具与外部事实 |
| 02 | 技术架构现状：原生 App、Python CLI、文件协议与外部运行时 |
| 03 | 优化诊断：业务问题与技术问题分别列出 |
| 04 | 业务目标：目标、下一步、交接、证据与确认 |
| 05 | 技术目标：共享业务内核、独立 CLI、Repository 与 Connector |
| 06 | 重构路线：阶段、退出条件、存储决策与保留约束 |

另有四张独立绘图，适合在 D板里逐张打开：

- [业务现状](01-business-current.excalidraw)
- [技术现状](02-technology-current.excalidraw)
- [业务优化目标](04-business-target.excalidraw)
- [技术重构目标](05-technology-target.excalidraw)

Mermaid 源文件保留在本目录，可用 Excalidraw CLI 再生成；图中节点、箭头、文本均为可编辑元素。转换后的独立图增加了画框与说明，总图再按“现状在上、目标在下”组合。

复现基础转换与画框检查（输出为临时产物）：

```sh
excalidraw mermaid 01-business-current.mmd --elbow --font-size 22 --out /tmp/dboard-business-current.excalidraw
excalidraw render DBoard-architecture.excalidraw --all-frames --out /tmp/dboard-architecture-frames/
```

蓝色表示工作 / 原生核心，绿色表示个人领域 / 本地事实，紫色表示外部来源与适配器，橙色表示需要优化的耦合或条件性方案。实线表示主流程 / 直接依赖，虚线表示参考、关联、反馈或条件性迁移。

## 研究范围与证据边界

核对了 README、Package.swift、App 启动与窗口管理、核心 ViewModel / Store、需求与学习模型、CLI 读写路径、同步脚本、交付及归档保护、文件监听、内嵌 Excalidraw，以及现有测试目录。历史产品分析文档用于确认 N=1 与“真实摩擦驱动”的决策，不把其中 2026-08 的模块数、风险清单当作当前现状。

本次没有读取真实群聊、查询线上数据库或执行远端发布 / 同步。下面的“现状”来自当前源码；性能瓶颈、使用频率和投入收益尚未用运行测量证实，相关项目明确列为需要验证的假设。

DBoard-Open 是旁边的 QuadSpell 开源 / 跨平台项目：独立 Swift 简化看板与 Electron 桌面实现，不是当前 D板 App 的运行依赖。跨平台不是本次重构的前置条件。

## 一、当前业务架构

### 1. 产品层次

**主 Main：研发协作。** D 编号用于开发需求，P 编号用于线上排查。需求承载咒言、范围变更、周期、优先级、个人状态、工程 / 分支、AI 进度、交接、技术方案、代码审查、调试验证、上线前事项及归档。今日零碎按日期维护，历史未完成事项顺延展示，但修改定位回原日期。

工作闭环是“形成目标 → 复制短指令 → 外部 AI 读取当前上下文 → 执行与回写 → 验证 / 交付 → 用户确认 / 归档”。D板目前并不是通用 AI 对话台或自主任务调度平台。

**次 Try：个人成长。** 想法保留原文与独立补充，可关联学习。学习包含目标 / 时间预算、阶段、当前单元、资料、原笔记、AI 整理草稿、真实作答、掌握检查、成果、复习与复盘。健康独立记录办公、喝水、运动，并从真实记录计算历史统计。

**工具与连接器。** ReqFlow 提供正式需求流程；BizMap 提供服务、文档与路由参考；Audi 通过网页提供发布、日志与首页；剪切板、Skills、Agent 环境、GitHub 热门、待回复审批及运维入口承担辅助能力。待回复与后台值守由功能开关控制，不是研发需求的必需依赖。

### 2. 业务事实归属

| 事实 | 权威来源 | D板的职责 |
|---|---|---|
| D / P 单目标、变更、个人状态、进度与本机证据 | 本机 demand-center-cache.md | 编辑、AI交接、验证与归档 |
| 正式需求 ID、流程状态、正式验收 | ReqFlow API | 明确关联、展示带读取时间的快照、执行正式流转 |
| 开发交付声明的工程 / 分支 | ReqFlow 开发交付专用字段 | 缓存声明；不能据此声称代码已经核验 |
| 原开发仓库、真实代码版本、环境工作树 | 本机记录与 Git 核验 | 区分源开发分支和集成 / 发布工作树 |
| 服务职责与关键词路由 | wiki 业务地图及生成结果 | 提供参考；生成时间不等于职责核验时间 |
| 学习、想法、笔记、作答与草稿 | 本机 dboard-try.json | 个人学习闭环；不进入钉钉需求同步 |
| 办公、喝水、运动 | 本机 dboard-health.json | 真实记录、统计与撤销 |
| 剪切板 | 本机 clipboard.sqlite | 捕捉、搜索、过期与回写 |
| Skills / MCP / Hooks / Agents | 各运行时配置及目录 | 扫描、展示与治理 |
| Excalidraw 绘图 | 用户选择的 .excalidraw 文件 | 离线编辑与显式保存 |
| 钉钉进行时总览 | 本机工作事实的简版投影 | 分享概况；不能作为完整本机数据恢复来源 |

### 3. 必须保留的业务边界

- 个人完成状态、AI 测试通过、正式验收和发布事项是不同维度。当前完成门禁已经检查未完成上线事项；关联正式需求时还会核实正式验收。应保留并集中表达这些规则。
- CR 是独立审查结果，绑定实际代码版本，不冒充测试或验收；范围 / 代码变化会影响已有证据的有效性。
- 开发交付有方案预览、文档核验、工程声明与检查点；交付成功不会自动推进个人状态。
- AI 可以写进展、教学方案和草稿，不能覆盖用户笔记或替用户确认掌握。
- 归档保留本机完整快照；云端只输出简版。结果不明时先对账，再重试。
- 学习 / 想法 / 健康各自保持自己的语义。健康统计中的无记录日期不能被当作零记录，主动离座与自动锁屏也不能混同。

## 二、业务优化：分别解决什么问题

| 优先级 | 已有基础与当前摩擦风险 | 建议优化 | 预期收益与验证方式 |
|---|---|---|---|
| B1 高 | 状态、执行、CR、发布与正式验收已有独立记录，但分散在卡片和流程入口 | 为每条工作推导一个“下一步”，同时明确阻塞原因、需要的证据和确认方 | 用户能直接判断该开发、测试、核验还是确认；用真实任务观察跨页面查找次数 |
| B2 高 | context / handoff 已支持摘要、历史按需读取和版本校验 | 统一交接包契约：目标版本、当前代码、未完项、关键决策、证据索引；范围改变时显式提示哪些证据需重新核验 | 新会话可接手；用不同会话复核未完项与代码版本是否遗漏 |
| B3 高 | 个人状态与正式状态并行，来源已分开；工程声明也有读取时间 | 所有快照一致呈现“来自哪里 / 何时读取 / 是否已核实”；统一待核验结果的表达 | 缓存不会被误当实时事实；对离线、过期登录、部分失败做场景核对 |
| B4 中 | 学习计划、单元、笔记、草稿、检查与复习能力已经完整 | 继续把主页面收敛到当前单元与薄弱点；领域层分开用户原文、AI草稿和掌握证据 | 降低操作负担，保留可追溯性；观察一次学习需要的跳转与查证步骤 |
| B5 中 | 想法、学习、研发知识都能关联资料 | 共享资料链接、图片和证据索引，按来源追溯；只在有真实联系时关联领域 | 经验可复用，避免重复存同一资料；不自动把想法变正式需求 |
| B6 条件性 | 工具入口较多，存在使用记录，但入口次数不等于任务完成数 | 按实际使用调整首页常用入口；工具按需打开，失败只影响自身 | 更快进入核心任务；先观察实际频率和启动开销再调整 |

**建议的业务重构单位：**

1. Work：D开发与P排查共享目标、范围、进度、资料、证据和交接；排查关闭与开发交付保留各自策略。
2. Learning：目标、计划、单元、真实作答与掌握证据。
3. Ideas：原文、补充、结束 / 恢复与学习关联。
4. Health：真实记录和统计。
5. Knowledge / Media：文档、图片、绘图与证据引用，只共享基础能力。
6. Connectors / Tools：ReqFlow、BizMap、Audi、Skills、剪切板与待回复等独立模块。

这些单位是职责边界，不要求增加同等数量的菜单或页面。首页仍可保留 Main / Try，用户不需要理解内部模块。

不建议把所有状态折成一个线性大状态机。使用四维事实更符合现状：`personalStatus`、`executionEvidence`、`releaseChecklist`、`formalAcceptance`；“下一步”是它们与当前目标版本的派生结果，不能再成为新的独立真相。

直接派发 AI、全局 Agent 舰队调度和自动周报曾经缺少明确使用价值。先解决交接可靠性与下一步可读性；只有实际摩擦持续出现，再立项直接派发。

## 三、当前技术架构

### 1. 运行结构

- SwiftPM 只有一个 executable target 与一个测试 target。最低 macOS 15；Swift tools version 6.0，但语言模式为 Swift 5。本机工具链是 Swift 6.4.2。
- SwiftUI 负责界面，AppKit 管窗口 / 浮层 / 输入 / 全局快捷键，Combine 与 NotificationCenter 驱动状态变化。
- AppDelegate 创建窗口与核心 ViewModel，管理退出、模块入口和部分后台能力。
- DBoardViewModel 同时承担工作数据、筛选与选中、编辑器 / 草稿、周期推进、文件读取、同步状态及领域协调。
- BizMapViewModel 同时包含服务地图、ReqFlow、项目表、Cookie、交付查询、HTTP / 脚本和界面状态。ReqFlow 目前依赖这个模型，而不是独立连接器。
- Python dboard-ai 及子模块直接解析、校验和修改 Markdown / JSON；部分字段、hash、学习和工作规则有 Swift 与 Python 两套实现。
- 交付已经存在一处共享模式：Python CLI 可调用 App 的 `--dboard-delivery-cli`，复用原生持久化交付工作流。下一步可以扩展这个思路，但核心 CLI 应成为独立于 AppKit 的 target。

### 2. 数据与集成结构

工作数据采用 Markdown，结构化记录嵌入版本化注释；个人空间采用 JSON；剪切板采用 SQLite；外部正式需求、业务地图与工程声明分别缓存。同步、归档、交付与草稿还有各自的凭证 / journal 文件。

文件写入普遍使用跨进程 flock、原子替换和内容 / 记录版本核对。FileRefreshObserver 对 rename / delete 重绑文件描述符，并有防抖与低频巡检。ProcessRunner 并行排空 stdout / stderr，限制输出、超时终止，区分进程成功与业务 success。

外部集成同时存在 URLSession 直接 HTTP、Shell → Python → dws、缓存生成器、WebKit 页面、Chrome Cookie Bridge，以及外部 daemon / launchd。Audi 本地调试由独立服务管理器启动本机 Next 服务。

Excalidraw 是边界比较清晰的现有模块：React 19 + @excalidraw/excalidraw 0.18.1，通过 esbuild 打包进 App，在非持久 WKWebView 中离线运行；原生桥加载场景并显式保存源文件。它保留未知字段，保存前核对磁盘原文，不因查看 / 缩放改写文件。

### 3. 规模信号

本次统计只包含手写 Sources 与 Tools，不包含打包 editor.js、node_modules 和构建产物：

| 项目 | 数量 |
|---|---:|
| Swift 源文件 | 139 |
| Swift 源码行数 | 37,741 |
| Tools Python 行数 | 4,710 |
| Swift *Tests.swift 文件 | 87 |
| Python test_*.py 文件 | 21 |
| BizMapBoard.swift | 3,094 行 |
| dboard_ai.py | 1,852 行 |
| ClipboardBoard.swift | 1,690 行 |
| DBoardView.swift | 1,668 行 |
| DItemEditor.swift | 1,182 行 |
| TryStore.swift | 1,157 行 |

大文件本身不是缺陷，但 BizMap 与 DBoardView 的职责交叉，加上单 target 和双语言规则，说明按文件拆分尚未形成稳定的模块边界。现有测试覆盖应在迁移时复用，不能沿用历史“无测试”的描述。

## 四、技术优化与重构方案

### T1：统一业务写入口和契约，优先级最高

当前风险是同一个业务事实在 Swift 与 Python 中被重复理解。新增字段、scope hash 或证据规则时，两边可能分别正确却互不兼容。

**第一步：** 保留现有命令和文件格式，定义 Command / Query 的输入输出、错误代码、TaskID、revision、scope / code revision、eventID 以及字段所有权。复用同一套 fixtures 让两边跑一致性检查，先发现偏差，再逐个迁移写命令。

**目标：** UI 和独立 dboard-core CLI 调用同一 Swift Application / Domain 模块；现有 dboard-ai Python 入口逐步成为参数与输出适配器。核心不依赖 AppKit，App 关闭时仍能运行 CLI。对更适合 Python 的外部脚本保留 Connector，不必为了统一语言重写。

### T2：拆业务状态与界面状态

把窗口、选中、搜索、展开、草稿展示状态留在各领域 ViewModel，把完成门禁、周期、证据有效性、交付和归档放入 UseCase / Domain。

先拆 ReqFlowConnector 与 BizMapRepository，解除 `DBoardViewModel → BizMapViewModel` 的业务依赖。再拆工作列表、编辑器、交付、学习笔记等观察范围，避免无关对象的 objectWillChange 连带刷新所有卡片。

领域拆包比机械移动文件更重要：Core 的代码不能读取 NSApp / NSWindow，也不应依赖 SwiftUI 的 Binding。AppDelegate 最终只做装配与生命周期协调。

### T3：把文件I/O与锁等待移出主线程

DBoardViewModel.reload 在 UI 调用路径中直接进入阻塞式 CacheFile.withLock，读文件、周期协调、写回和解析都在同一路径。外部 CLI 长时间持锁时，存在界面等待风险。TryDisk 已经用 LOCK_NB 避免打字线程无限等待，但仍需编码并写整份 JSON。

建议：Repository 在后台队列 / actor 执行 I/O，锁有明确等待上限；返回不可变快照后在 MainActor 更新界面。保留文件级跨进程锁，**Swift actor 只隔离本进程，不能替代 flock**。失败保留用户输入并可重试，测量输入响应、reload耗时和持锁时长后再进一步优化。

同时统一读失败语义：TryStore / BizMap 通常保留上次快照；主需求 reload 的读取失败可降为 "" 并解析出空列表。应把“首次不存在”“合法空数据”“读取失败”“格式不支持”分开，失败继续显示最后成功快照与错误。

### T4：统一外部操作的结果模型

归档、开发交付和总览同步已有 journal / 凭证 / 防重复保护，是可复用资产。

提炼轻量操作协议：`prepared → executing → verify-pending → confirmed`，另有明确 rejected。记录 operationID、目标版本、目标远端对象和最后核验结论。超时 / 5xx 可能发生在远端已写入之后，进入待核验；重新读取确认后再决定补做哪一步。

不同操作保留专用 journal，不建立庞大的通用工作流引擎。总览同步是可重建投影，可合并较新请求；交付与归档需要逐步核验，不能用同一“自动重试全部”策略。

### T5：先抽 Repository，再决定 SQLite

现在的 Markdown 是人和 AI 都能阅读的共享工作记忆，JSON 也能直接备份。迁移成本不仅是换数据库，还包括 CLI、草稿、监听、归档、恢复和旧数据往返。

推荐两段方案：

- 阶段一：Domain / UseCase 与格式解耦；Markdown / JSON Repository 继续作为本机权威存储。对来源、revision、错误、锁和原子写明确契约。
- 阶段二：先测量文件大小、全量写耗时、查询 / 搜索成本与跨文件事务失败。如确有问题，可以先建立 SQLite 只读索引；索引可删除重建。
- 如需事务事实库：选择一个领域先迁移，保留原文件备份和导出，影子对比只读取；验收后切换唯一写入口。切换后的 Markdown 是可导出投影。不能让数据库和旧文件长期各自独立写同一事实。

多用户云服务、微服务和事件溯源平台没有当前必要性。SQLite 的价值是本机事务与索引，而不是为个人工具增加服务部署。

### T6：把生命周期、适配器与构建边界收敛

- 共享 Process / HTTP 的取消、超时、业务错误与输出完整性；现有 ProcessRunner 保留，逐步收敛其他直接 Process 调用。
- 模块只管理自己的 Timer、监听、WebView 和进程；关闭 / 退出时能释放，失败不阻塞其他模块。现有共享文件监听不重写，优先复用。
- ReqFlow、BizMap、Audi、dws、Skills 与 Auth / Cookie 分别适配；明确缓存新鲜度和接口读取时间。
- 保留原生窗口与输入体验，保持 Excalidraw 离线源文件边界。无需用 Electron 重写当前 macOS App。
- Swift 6 严格并发迁移放在职责拆分后；先理清主线程与后台所有权，再逐模块开启检查。
- native 增量构建引擎已弃用是工具链风险。保留 --full 验证入口，升级工具链时验证；不在本次研究中清缓存或更换日常构建流程。

## 五、建议目标结构

以下是职责草案，正式命名可按第一个迁移场景调整：

```text
DBoardApp                 SwiftUI / AppKit / WindowRouter / 各领域ViewModel
DBoardCLI                 无AppKit的dboard-core可执行入口
DBoardApplication         Command / Query / UseCases / 结果与错误契约
DBoardDomain              Work / Learning / Ideas / Health / Evidence
DBoardInfrastructure      FileRepositories / Process / HTTP / Clock / 变更通知
DBoardConnectors           ReqFlow / BizMap / dws / Audi / Skills / Auth
DBoardDocuments           Excalidraw / 图片 / 笔记导出
Python兼容入口             维持现有dboard-ai体验；渐进调用共享内核
```

依赖方向：App / CLI → Application → Domain 与 Ports；Infrastructure / Connectors 实现 Ports。Domain 不反向依赖 App、脚本或外部 API。一开始只拆最需要的两三个 target，避免先铺一堆空模块。

## 六、渐进重构路线与退出条件

| 阶段 | 可交付范围 | 退出条件 |
|---|---|---|
| R0：基线与契约 | 固定现有命令输出 / 文件fixtures；梳理数据所有权；记录reload、写入和锁耗时 | 现有D/P/T、归档、笔记、草稿与证据可往返；知道哪些延迟值得优化 |
| R1：读路径与隔离 | 分开ReqFlow与BizMap；抽文件Repository；后台reload；错误保留上次快照 | 不引入新的写入口；登录过期、文件损坏、原子替换时行为保全 |
| R2：共享写内核 | 先迁移一个低风险命令，如本机进度回写；再迁移方案、证据和完成规则 | UI / CLI使用同一规则；旧命令兼容；并发与重复eventID不丢失 / 重复写 |
| R3：高风险闭环 | 统一交付 / 归档的结果模型和检查点；局部状态发布；下一步投影 | 远端已写但响应丢失、应用崩溃、版本变化能恢复和对账；用户确认边界保持 |
| R4：领域与存储 | 拆Learning / Ideas / Health的模型职责；根据测量决定索引或事务存储 | 原笔记、作答历史、草稿与ID保全；唯一写源切换后可回滚且不覆盖新数据 |

回滚不是简单把老文件盖回去。迁移前保存备份；切换后产生的新记录必须可导出并被旧版本识别，或先暂停写入进行核对，才能恢复旧实现。

**第一笔建议实施的改动：** 分离 ReqFlow 读模型与 BizMap，抽工作文件 Repository，把 reload 的锁和解析移到后台并明确读失败状态。它直接减小耦合和UI等待风险，保持文件 / CLI 契约，可独立评审与回退。共享写内核随后逐命令迁移。

## 七、验证重点

保留已有测试，新增验证仅针对迁移的语义风险：

- Swift / Python 对同一 fixture 的解析、hash、版本和输出一致。
- 两个 CLI 与 UI 并发修改不同记录 / 同一记录；原子替换后监听恢复。
- 中断、磁盘写失败、锁等待、格式不支持；用户输入和最后成功快照保留。
- 远端已提交但返回超时，重试先核验，不重复建文档 / 归档。
- 范围或代码版本改变后旧CR / 测试证据不被误认为当前有效。
- 学习原文、AI草稿、真实作答与检查历史保全；健康跨日与锁屏语义保持。
- 输入法、快捷键、窗口焦点、草稿、恢复和Excalidraw未知字段不退化。

本次只生成研究与绘图产物，未执行这些未来重构的运行验收；绘图已通过 CLI 转换与本地渲染核对。

## 八、主要源码依据

以下路径均相对 DBoard 根目录：

| 结论 | 依据 |
|---|---|
| 产品入口、同步范围与Main/Try语义 | README.md:8、README.md:72、README.md:135、README.md:204 |
| 单executable target、语言模式 | Package.swift:4 |
| App启动、窗口装配与绘图打开 | Sources/DBoardApp.swift:7、Sources/DBoardApp.swift:93 |
| UI与工作数据 / 同步耦合 | Sources/DBoardView.swift:88、Sources/DBoardView.swift:262、Sources/DBoardView.swift:499 |
| Markdown读写与阻塞锁 | Sources/Models.swift:193、Sources/Models.swift:204 |
| 原子替换监听与巡检 | Sources/FileRefreshObserver.swift:6 |
| Try复杂聚合与非阻塞锁 | Sources/TryStore.swift:103、Sources/TryStore.swift:216、Sources/TryStore.swift:291 |
| ReqFlow与BizMap交叉职责 | Sources/BizMapBoard.swift:120、Sources/BizMapBoard.swift:248 |
| CLI独立解析 / flock / 原子写 | Tools/dboard_ai.py:54、Tools/dboard_ai.py:1150、Tools/dboard_ai.py:1267 |
| 学习两侧文件协议 | Tools/dboard_try.py:17、Sources/TryStore.swift:216 |
| 技术方案两侧结构化协议 | Tools/dboard_plan.py:7、Sources/DemandTechnicalPlan.swift |
| 交接摘要与资料索引已存在 | Sources/DemandHandoff.swift:4、Tools/dboard_handoff.py |
| 代码 / 范围证据版本 | Sources/DemandExecution.swift:71、Sources/DemandVersion.swift |
| 正式验收与发布清单门禁 | Sources/DemandCompletionGate.swift:4 |
| 交付核验与原生CLI复用 | Sources/DemandDeliveryServices.swift:4、Sources/DemandDeliveryCommand.swift:5 |
| 快照、凭证、并发后重试 | sync_dboard.sh:1 |
| 进程输出与业务成功判断 | Sources/ProcessRunner.swift:5 |
| Excalidraw离线与源文件保护 | Sources/ExcalidrawDocument.swift:4、Sources/ExcalidrawWindow.swift、Tools/ExcalidrawEditor/README.md |
| N=1与重构保全原则 | REVIEW.md:20、AGENTS.md |

## 绘图字体与后续规范

2026-11-20 统一绘图字体：总图全部 176 个文本元素均使用 Excalifont（fontFamily 5），四张独立图同样统一。中文由 Excalidraw 的手写 CJK 字体回退提供；标题、说明与技术标识不再混用 Helvetica。六个画框重新渲染检查通过。

[字体统一版总图](DBoard-architecture-excalifont.excalidraw) 使用新的文件路径，方便 D板打开新场景，避免已经打开的旧窗口继续显示内存中的旧字体。

后续绘图使用 [excalidraw-cli-diagrams 技能](/Users/zz/.codex/skills/excalidraw-cli-diagrams/SKILL.md)，其 [参考来源与适配说明](/Users/zz/.codex/skills/excalidraw-cli-diagrams/references/sources.md) 记录了 Cole Medin、Axton Liu、yctimlin 的设计方法和当前 CLI 的兼容性取舍。检查工具区分字体 / 引用错误与可读性提醒；总图作为研究海报需要放大阅读，后续新图优先采用可直接阅读的概览与独立细节图。
