# 次 Try 学习模块重设计实施记录

日期：2026-11-17。用户确认：“嗯可以，你改吧。”
按已确认的两份方案实施，未扩大T007的学习目标。

## 可用行为

- 学习页直接定位当前稳定单元，连贯呈现材料、指标、解释、边界与判断。学习/复习/知识笔记入口固定在正文上方；旧Markdown直接展开阅读。
- 教学偏好独立持久保存，AI交接读取偏好、限制、当前单元、主题笔记与近期短反馈。阶段末或主动复习/复测才集中检查，继续学习不要求先确认掌握。
- 笔记按跨阶段主题筛选，可回看关联单元、原文快照和整理说明。当前单元先收为整理草稿；revision和源笔记版本匹配才采纳。采纳创建新页，原页、草稿与选中页不被覆盖；撤回只把整理页放入可恢复的已删除笔记。
- 方案重排与估时变更保留所有检查，含未确认的needs_practice。标准变更保留历史并另判当前覆盖；新检查保存当时标准、关联正文与原始版本，替换检查和复习答题都保留历史。笔记标题/归类不冒充正文更改，AI整理稿不能充当独立答题。
- 阶段切换有独立操作，Swift与CLI都保留其他阶段草稿，且不更改掌握。
- 修正新主题页初始滚动及窗口调整时文档移出视口的问题；原阅读位置数据继续保存。

## T007迁移

原N001—N004、空N002、原文字句、书签、草稿、旧学习稿、配置、计划和真实检查保留。
新整理页：

| 笔记 | 主题 | 来源 |
| --- | --- | --- |
| N005 | 模型、应用与计算设备 | N003及已讲全局关系补充 |
| N006 | 参数量、量化与运行资源 | N003/N004与公开量化比较 |
| N007 | 训练、微调与LoRA | N004与已讲训练内存补充 |
| N008 | 模型选型、指标与真实比较 | 已讲AI材料，标为补充 |

修正“7B为10亿”为约70亿、“内存宽带”为“内存带宽”；“1B=1G”按数量简写澄清，不当作GB错误。量化误差与实际任务效果分别表述。

已讲的Phi/Mistral任务分数与LLaMA3量化大小/PPL保存为两个稳定单元，保留来源、条件与因果边界。当前仍S006，S001仍是唯一确认阶段；S003/S005的真实needs_practice不变。未增加学习掌握结论或虚构学习时长。

迁移先在仅含T007的副本演练，再每次重新context取得revision回写；原始历史也保留。
备份：/Users/zz/.claude/dboard-backups/T007-before-learning-redesign-20261117.json。
未运行或下载模型、安装模型工具、使用付费API或上传资料。

## 验证及限制

43项学习/笔记/展示/快捷学习相关Swift测试通过，11项CLI测试通过。后续阅读定位、主题切换、正文滚动及阅读位置变更另跑受影响测试，均通过。原生界面在深浅色、常规与660点窄窗口截图核对。

真实迁移核对：原四篇笔记、检查、草稿、学习稿、配置、计划、选中页与原124条历史逐项相等。新页数不计作掌握。

额外运行的旧TryNavigationTests与TryWorkspaceTests有11项断言失败，涉及首页旧编辑器/键盘桥与快捷卡片类型顺序（当前已有健康页）。这些旧预期未在本次范围内改写；不能宣称全仓测试全部通过。学习页面与笔记编辑器相关失败已修正并复测。

## 修改范围

Sources/TryLearningKnowledge.swift、TryLearningKnowledgeStore.swift、TryLearningUnitView.swift、TryLearningOrganizationView.swift；
TryStore、TryLearningJourney、TryLearningWorkflow、TryLearning、TryLearningPresentation、TryLearningReadingView、TryNotebook、TryNoteEditor；
Tools/dboard_learning_knowledge.py、dboard_learning.py、dboard_try.py；
Swift/CLI相关测试、README与install.sh的CLI打包清单。

保留工作区原有改动，未提交或推送代码。通过仓库安装脚本构建并更新本机DBoard.app及CLI。

## CLI接口

context含unitFormat与持久偏好。每次report仅一种学习动作：
--preferences-file、--topics-file、--unit-file、--notes-file与原plan/lesson/check/practice/review并行兼容。
unit / organization / evidence按ID读取；switch-stage / adopt-notes / undo-notes要求最新expected-revision。
