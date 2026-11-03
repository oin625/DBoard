# D板 AI CLI

安装 DBoard 后，`~/.local/bin/dboard-ai` 可供执行 AI 调用。现有 `dboard` GUI 命令保留。
复制内容自动带上 D编号、标题和本机 CLI 命令；缓存位置与完整反馈 Skill 由 `context` 返回，不需要手动填写。
首页需求的「复制现状」只复制几行短指令：需求编号、`context` 读取命令和进度回写要求。AI 执行命令时读取原咒言、分支、全部进度、追加变更和反馈规则，拿到最新上下文。
历史页的归档需求可开启 2.0、3.0 等新版本，使用新 D编号。`show` 的 `item.version` 返回上一版编号、根需求编号、版本号和历史背景；`context` 一并返回旧版背景和本轮改动要求，要求 AI 在已有代码上继续，仅将本轮进度写回新需求。旧版仓库和分支作为线索，实际仓库仍需本轮 Git 核对并用 report 反馈。
展开需求可「追加变更」，只填写这次要改什么；每条变更保留独立编号。「复制这次变更」和「添加并复制」会复制带 `--change C001` 等编号的短指令，context 指定本轮目标，要求 AI 在已有实现上修改。`show` 返回 `item.changes`，反馈进度时带上 `[C001]` 等编号，未完成的测试和验收继续保留。
执行 AI 每轮有实质进展、暂停或交接前，用 report 保存尚未记录的进展。每条记录先用 --summary 写一句话概括（通常20～60字，最多120字），再按需用 --details 写关键明细。D板默认显示概括，点该条「明细」才展开；钉钉只同步概括，明细保留在本地，context 返回完整内容。明细只补关键待做、验证、阻塞和资料入口，不重复需求背景或完整清单。--progress 保留为 --summary 的兼容别名。

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
| `dboard-ai show D014` | 读取一张 D单，返回标题、分支、进度、仓库、位置和 revision |
| `dboard-ai report D014 ...` | 更新实际仓库及分支，并追加执行进度 |
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

CLI 不提供状态修改、删除或归档命令。开发结束通过进度记录“开发完成，待验收”。

## 验证

```bash
python3 -m unittest discover -s CLITests -v
swift test --filter DboardAIFeedbackTests
```

CLI 测试使用临时缓存和 Git 仓库，不修改用户的 D单或调用真实远端同步。

需求概括可用 `report --overview '一两句话说明需求范围'` 更新（单行，最多120字），不追加额外进度。总览未变时自动同步返回 `sync.status: unchanged`，本地记录仍成功保存；`dboard-ai sync` 手动重新发布总览。完整上下文始终从 `context` 读取，不能用云端简版覆盖本机。
