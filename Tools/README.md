# D板 AI CLI

安装 DBoard 后，`~/.local/bin/dboard-ai` 可供执行 AI 调用。现有 `dboard` GUI 命令保留。
开发需求使用 Dxxx，线上排查使用 Pxxx；`context P001`、`report P001` 等命令与 D 编号共用同一读写规则。复制内容自动带上任务编号、标题和本机 CLI 命令；缓存位置与完整反馈 Skill 由 `context` 返回，不需要手动填写。
首页需求的「复制现状」只复制几行短指令：需求编号、`context` 读取命令和进度回写要求。AI 执行命令时读取原咒言、分支、全部进度、追加变更和反馈规则，拿到最新上下文。
历史页的归档需求可开启 2.0、3.0 等新版本，使用新 D编号。`show` 的 `item.version` 返回上一版编号、根需求编号、版本号和历史背景；`context` 一并返回旧版背景和本轮改动要求，要求 AI 在已有代码上继续，仅将本轮进度写回新需求。旧版仓库和分支作为线索，实际仓库仍需本轮 Git 核对并用 report 反馈。
展开需求可「追加变更」，只填写这次要改什么；每条变更保留独立编号。「复制这次变更」和「添加并复制」会复制带 `--change C001` 等编号的短指令，context 指定本轮目标，要求 AI 在已有实现上修改。`show` 返回 `item.changes`，反馈进度时带上 `[C001]` 等编号，未完成的测试和验收继续保留。
执行 AI 每轮有实质进展、暂停或交接前，用 report 保存尚未记录的进展。每条记录先用 --summary 写一句话概括（通常20～60字，最多120字），再按需用 --details 写关键明细。D板默认显示概括，点该条「明细」才展开；钉钉只同步概括，明细保留在本地，context 返回完整内容。明细只补关键待做、验证、阻塞和资料入口，不重复需求背景或完整清单。--progress 保留为 --summary 的兼容别名。

## 独立代码审查

需求卡片的「代码审查」、右键「复制代码审查」和已完成卡片均可复制短指令，交给全新的 AI 执行 `context 任务编号 --task code-review`。AI 读取原咒言、全部追加变更与 CR 专用规则，确认各仓库的实际开发分支及整段提交范围，审查完整实现和相关调用链。默认只审查，不自动修复；验证按实际疑点选择，不默认全量回归。

结论通过 `report --task code-review --review-result clear|findings|limited` 写回：一句话概括，明细写代码位置、触发条件、影响、审查范围与验证边界。能核实代码版本时必须传实际审查的 `--expect-code`，代码变化则重新审查受影响部分。CR不更新测试阶段、清单、经验库或完成状态。默认按「原咒言与全部变更→摘要与代码→有疑点才查相关历史」读取，不因摘要缺失或过时而自动读取全部历史；仍每次判断压缩是否需要。CR反馈可省略 --handoff-file，保留原摘要及未覆盖历史，只记审查概括与明细。

归档需求同样可审查；其快照用于旧版本关联，保持原内容。审查记录单独保存在本机 `dboard-archive-code-reviews.json`，已完成卡片默认显示最近概括，点击看明细；`inspect --section code` 可读取。归档CR不上传远端。

## 开发后的调试测试

每张需求可手动点「无需调试页」，随后可点「撤销无需调试页」恢复入口。选择仅存本机，`show/context` 返回 `item.debug_page_not_needed`；追加变更仍保留选择，已有页面与结果不删除。AI读取最新选择后跳过建页，后端核验、接口验证及人工联调仍按需进行；旧复制命令也会遵守最新选择。CLI不提供修改用户选择的命令。

展开需求，点击「复制调试咒言」。短指令执行 `context D014 --task debug-page`，实时读取原咒言、全部变更、进度和专用规则。AI 先核验后端实现，再在 `/Users/zz/work/code/audi` 创建或完善模块，在 `/test-console` 的入口列表注册。

调试页就绪后，需求卡片会显示「启动本地 audi」：一键在本地 audi 仓库启动开发服务，服务就绪后自动在浏览器打开当前调试模块；运行期间可「打开本地调试页」或「停止」，无需回到终端。

`report --stage` 可记录 `developing`、`development-complete`、`debug-page-ready`、`testing-passed`。核验结果需要 `--summary` 和简短证据 `--details`；页面结果需要真实 `--debug-page '/模块路由'`，确认可访问后可补 `--debug-url`。先核验开发再报页面就绪，AI随后简单试调能独立验证的部分。`testing-passed` 只表示这些实际执行的部分通过，界面显示「AI试调已完成 · 待人工联调」。反馈需简短区分已测及结果、未测及原因、待用户联调事项；最终内部／外部联调测试由用户协调进行。只完成页面或构建不能写试调通过，剩余需要人工配合时直接交接。

`show/context` 返回 `item.execution` 和 `item.execution_needs_review`。原咒言、追加变更或需求资料改变后，旧结论提示重新核验；仅补充进度、分支或排期不使它失效。代码后续改变或测试失败时，AI 应回退最后可靠阶段。执行结论独立于个人状态，不自动完成或归档。

## 命令

| 命令 | 行为 |
| --- | --- |
| `dboard-ai context D014 [--change C001]` | 读取最新完整现状与反馈规则，返回 context、feedback_instructions 和当前 revision |
| `dboard-ai context D014 --task debug-page` | 读取核验开发、创建 audi 调试页及联调回写的专用任务 |
| `dboard-ai context D014 --task code-review` | 读取完整需求范围、实际代码与独立 CR 规则 |
| `dboard-ai report D014 --task code-review ...` | 仅记录版本绑定的审查概括、明细与交接 |
| `dboard-ai show D014` | 读取一张 D单，返回标题、分支、进度、仓库、位置和 revision |
| `dboard-ai report D014 ...` | 更新实际仓库及分支，并追加执行进度 |
| `dboard-ai incident close P001 ...` | 用户明确要求后，留结论并完结排查单，保留历史与经验 |
| `dboard-ai sync` | 单独重试钉钉同步，不重复追加进度 |
| `dboard-ai guide` | 输出完整的执行反馈 Skill |

普通命令和错误输出 JSON，`--help` 输出参数帮助。云端 runner 使用本机 MCP 命令工具和复制内容中的绝对路径。

```bash
~/.local/bin/dboard-ai show D014
~/.local/bin/dboard-ai report D014 \
  --expect-title 'show 返回的 title' \
  --expect-revision 'show 返回的 revision' \
  --repo '/实际 Git 工作目录' \
  --summary '开发完成，本地验证通过，待联调验收。' \
  --details '下一步：测试环境联调；尚未验收或上线。' \
  --event-id '本次反馈的稳定编号'
```

`--repo` 从 Git 工作树读取当前分支，不创建或切换分支；`--branch` 可断言期望分支与当前分支一致。
仓库和进度可以分别反馈；每个 Git 仓库保留一条当前开发目录和分支，主目录与 worktree 按 Git common directory 合并，历史留在进度中。多个工程的分支展示为 `ultra:feature/xxx；audi:feature/yyy`，真实路径仍在 `item.repositories`。迁移或清理工作目录后回写实际位置；旧目录已不存在时，可用 `--repo '/实际新目录' --replace-repo '/原记录目录'` 明确替换旧记录，不根据其他任务切换后的工作目录猜测本需求分支。
反馈前核对 title 和 revision；内容变化返回 `REVISION_CONFLICT`，重新 show 后再提交。
重试同一反馈保留相同 event-id 和反馈参数；重复事件不会重复追加，复用事件编号但改变内容会失败。

默认缓存为 `~/.claude/demand-center-cache.md`。指定其他缓存：`dboard-ai --cache /tmp/fixture.md show D014`。
`--cache` 放在子命令前。自定义缓存始终只保存本地；默认缓存 report 会同步钉钉，可用 `--no-sync` 仅本地保存。
写入沿用 DBoard 的 `.lock` 文件并原子替换，只改目标条目的分支和进度。
内部反馈记录放在条目中的 HTML 注释里，用于仓库映射与重试去重；不作为页面内容显示。

## 返回结果

- 成功返回 `success: true`；report 还返回 `local_saved`、`sync`、`event_id`、`duplicate` 和最新 item。
- 写入成功但远端同步失败：退出码 3，`success: false`、`local_saved: true`，本机改动保留；用 sync 重试即可。
- 参数、目标、并发冲突或本地读写失败：退出码 2，错误信息在 `error.code` 和 `error.message`。
- `sync.status: skipped` 仅代表本地保存，没有宣称远端同步成功。

普通开发需求不提供状态修改、删除或归档命令。开发结束通过进度记录“开发完成，待验收”。

线上排查在用户明确要求后可轻量完结：`incident close P001 --expect-title '最新标题' --expect-revision 'show返回的revision' --outcome resolved --summary '一句话实际结论'`。outcome支持resolved（已处理）、handed-off（已定位并交接）、stopped（结束本次排查，原因未定），可补--details，仅本地保留明细。命令写入完结结果与一条概括，标为已完成，保留历史、摘要和经验；不要求另写摘要或重复经验判断，不清理工作树、不操作需求流。普通需求不可使用，未勾选的上线事项阻止完结，空清单无需二次确认。已完结重试返回unchanged，不重复记录或覆盖结论。恢复仍在D板操作。默认缓存同步总览，自定义cache或--no-sync不上传；同步失败只重试sync。详见`guide --topic incident`。

## 验证

```bash
python3 -m unittest discover -s CLITests -v
swift test --filter DboardAIFeedbackTests
```

CLI 测试使用临时缓存和 Git 仓库，不修改用户的 D单或调用真实远端同步。

需求概括可用 `report --overview '一两句话说明需求范围'` 更新（单行，最多120字），不追加额外进度。总览未变时自动同步返回 `sync.status: unchanged`，本地记录仍成功保存；`dboard-ai sync` 手动重新发布总览。完整上下文始终从 `context` 读取，不能用云端简版覆盖本机。

## 工作树台账与完结清理

每个任务独立保留所有工作树的路径、工程、分支、创建归属和清理状态。AI 新建统一用 `worktree create D019 --repo '/原仓库' --path '/新目录' --new-branch 'feature/xxx' --start 'origin/master'`，成功即已登记；恢复已清理目录用 `--branch '实际保留的本地分支'`，临时工作树用 `--detach --start '准确提交'`。其他工具已创建的目录立即 `register --created` 补齐，复用只用 `register` 登记使用。普通 `report --repo` 自动登记使用，保留每个工程最新开发目录，不覆盖台账。复制现状返回统计、创建／读取命令和新旧任务共用的规则。

进行中的需求可查看／补登记；已完成列表展开需求后可“清理工作树”：先预览可清理项与保留原因，再确认清理。仅清理本任务创建、代码已保存并有远端跟踪引用的独立工作树；未提交／未推送、锁定、被其他未完成任务使用或有进程占用的跳过。保留主仓库、分支和提交，忽略文件随目录移除。旧目录不能凭名称猜归属，可手动补登记。

`worktree list|preview D019` 返回最新检查结果；用户明确授权 CLI 清理时用 `worktree cleanup D019 --expect-preview '<preview_revision>'`。预览后变化拒绝执行，不强制删除。台账只保存本机 `dboard-worktrees.json`，归档沿用原台账，新版本不继承所有权。详细规则：`guide --topic worktrees`。

## 技术方案与开发分支

`context D014 --task technical-plan` 返回方案任务、最新原要求与代码、按需读取入口和方案规则，不自动加载全部历史。`plan read D014` 读取正文和方案 revision；`plan save D014 --file /绝对路径/plan.json --expect-title '标题' --expect-revision '需求revision' --expect-code 'code_revision' --expect-plan '方案revision或none'` 原子保存本地方案和一句话记录，不调用模型或上传文档。JSON包含title、markdown和projects（name、branch）。用户编辑后AI须重读，不能覆盖过期版本。

`report --repo /源工作树 --repo-role development` 记录开发目录；`--repo-role integration|release` 单独保存环境工作树，不覆盖开发分支。用途不明确、名字含pre等的分支须明确分类。上线清单保留英文工程原名，例如“发布 saleinventory 服务”。

`delivery preview D014` 只读预览方案和工程；用户授权提交后用 `delivery submit D014 --expect-delivery '<preview返回的delivery_revision>'`。此命令复用原生按钮的持久化工作流，需要已构建或安装DBoard；方案或代码变化时停止。同一需求复用已有文档，校验正文后更新，本地保留旧交付快照，错误分支通过交付接口更新纠正。普通接手续写或写方案不授权自动提交。
