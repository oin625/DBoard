# audi 调试页面任务

若 `item.debug_page_not_needed` 为 true，用户已手动选择无需页面：不执行下方建页与页面试调步骤，也不自行撤销设置。只按需核验后端及能独立完成的接口测试，记录已测、未测与待人工联调事项；保留已有页面和结果，仅用户撤销后恢复页面任务。

这是用户通过 D板「复制调试咒言」明确发起的下一阶段任务。先完成开发核验，再创建或完善调试页面；普通续做规则中的“开发完成就结束”不适用于尚未完成的本次页面任务。

## 核验开发

阅读原咒言、全部追加变更、最新进度、实际仓库和未提交改动。按本需求的业务流程核对接口签名、参数、返回、状态变化及关键失败情况，确认变更已覆盖，不能仅凭个人状态、历史“完成”或测试数量判定完成。

发现明确缺漏，先用 `report --stage developing` 简短反馈并补齐本需求。实现覆盖后，回写 `--stage development-complete`，明细写核验范围、实际验证依据和仍待联调的部分。已有当前范围的可靠核验且代码未变时可沿用，明确说明依据；不要重复记录。

## 建调试页

- audi 仓库：`/Users/zz/work/code/audi`。先读该仓库及上级 AGENTS.md，核对 Git 分支；不覆盖别人的未提交改动。
- 集中入口：`/test-console`，目前入口列表在 `app/test-console/_components/TestConsoleClient.jsx` 的 `CONSOLES`。先检查最新代码，在这里加对应业务入口，模块页面按需求自行创建。已有合适模块就完善，不重复建页。
- 统一壳：必须复用 `app/test-console/_components/DebugConsole.jsx` 与 `app/test-console/debug-console.css`，视觉以 `/cdd-reservation` 为基线（浅灰底、青色强调、9px 卡片、紧凑字段）；不要另造页面级 shell、设计 token 或重复样式。已有页面也先迁移到共享壳，再补功能。
- 输入收敛：首屏必填不超过 2 项，其余参数放“可选参数”折叠区。可复用且非敏感的门店/车型等信息可本地记忆；一次性券码、流水号、核销码和锁券结果不落盘，刷新后重新输入。
- 主流程：安全的只读链路提供一键执行并汇总结论；锁券、核销、退款等有业务副作用的动作必须保留显式勾选确认，结果不确定时禁止重复提交，并提供需人工核实后才能解除限制的入口。
- 信息层级：首屏先给结论（通过／待确认／失败及关键指标），再给步骤和结果卡片；原始 JSON 折叠；底部固定“已测／未测／待人工联调”三栏。禁止编造测试数据或把未执行标成通过。
- 页面实现必须同时满足以上约束及下方日志链路要求；只完成接口、只有通用 JSON 请求框，或缺少主要服务调用的日志入口与步骤展示时，不得回写 `debug-page-ready`。
- Dubbo 调用必须在服务器端通过 `src/lib/dubbo-proxy.js` 的 `dubboInvoke` 使用固定接口、方法与类型；浏览器只传业务参数，不开放任意方法、Java 类型或网关调用。环境沿用现有部署机制。
- 完成仓库要求的构建和适当测试，并实际打开页面检查首屏、折叠区和空状态；页面实现与构建验证完成且满足上述约束后记 `debug-page-ready`，尚未部署或未真实调用时明确“待部署／待联调”。

## 日志链路

参考 `app/cdd-reservation/_components/OilDeliveryTester.jsx`、`DeliveryLogSteps.jsx` 和 `StoreReservationDiagnosis.jsx` 的真实日志用法。新页从共享 `DebugConsole.jsx` 导入 `DebugLogChain`，复用 `src/features/debug-console/` 的组件及查询工具；日志请求走已有 `POST /api/logs-hist/query`，完整日志跳转 `/logs-hist`，不另建日志网关。

- 每次提交时固定业务标识、服务、实际环境及开始／结束时间，生成本次执行的 `query` 快照，绑定结果卡片；不能读取用户后来改过的输入来关联旧结果。环境与当前接口调用一致，不猜预发或线上。多服务链路按实际服务分别接入。
- 优先用后端真实 traceId；接口没有返回时，用本次业务单号及请求时间窗口找到 trace，再补查同 trace 日志。业务 requestId 不等于 traceId。组件默认使用请求前后各 5 分钟的北京时间窗口，最多初查加 3 次补查，每次 200 条；异步回调使用回调发生时间，历史故障允许用户明确指定发生时间。不同 trace 分开展示，无 trace 的原文不能拼成同一次执行。
- 按业务顺序显示关键步骤，例如「查券 → 锁券 → 查照片」。`steps` 的 `markers`、`failureMarkers` 必须查实际后端日志确定；业务失败返回须按真实结构识别，必要时扩展解析。默认先展示步骤状态和异常环节，请求、响应及原文点击详情展开。有日志只表示“有记录”，没有执行记录显示“未确认”，不能据此推断通过或失败。
- 日志由用户点击读取／刷新，页面闲置不轮询；刷新只查询日志，不重发业务请求。展示服务、环境、时间、traceId 及完整日志入口；查询失败、权限不足、采集延迟、截断或部分链路补查失败都要明确提示，保留已有证据。
- 接入后核对空状态、失败高亮、详情展开、切换请求时旧结果不串入新结果。日志权限或真实测试数据缺失时写入“未测及原因”，不得编造日志或把演示数据记为实际联调。源码无可关联日志时在本需求范围补必要记录，无法补齐则明确日志链路尚未完成。

接入示意，实际服务、环境、业务标识与日志标记均以本次实现为准：

```jsx
// 在提交和响应时记录时间；只保存本次请求快照，不落盘券码等一次性数据。
const startedAt = Date.now()
// ...执行原有业务请求...
const query = {
  app: actualService, env: actualLogEnv,
  startedAt, endedAt: Date.now(),
  traceId: responseTraceId, keywords: [submittedBusinessId],
}
<DebugLogChain query={query} steps={[
  { id: 'query', title: '查券', markers: actualQueryMarkers, failureMarkers: actualFailureMarkers },
]} />
```

## 联调与交接

AI先简单试调能独立验证的部分：页面加载、输入校验，以及现有测试环境和数据下能直接调用的接口；发现本需求的问题就修复、再验证。无需也不能假定自己能完成所有联调，最终内部／外部联调测试由用户协调进行。

回写时简短区分「已测及结果」「未测及原因」「待用户联调事项」；明确需要配合的系统／人员、业务步骤和可复用的页面入口、测试数据线索。缺少账号、数据或外部配合的部分直接交接，不为覆盖所有场景反复尝试或自行扩大范围。核销等有实际业务副作用的操作依照本次测试授权执行，不自动部署。

AI能独立验证的部分已实际执行且通过，可回写 `testing-passed`，其含义仅为「AI试调已完成，待人工联调」；不是整项需求测试完成。只完成页面或构建，或者有已知测试失败时不能写通过；没有可执行的试调时保留 `debug-page-ready` 并说明待人工联调。最终联调与验收由用户确认。不修改个人状态、不自动归档。新要求或追加变更使 `item.execution_needs_review` 为 true 时，旧结论仅供参考；重新核验开发，再完善页面和验证受影响的流程。发现代码后续改变或测试失败时，主动退回最后可靠阶段，不能保留不成立的“通过”。

每次接手仍须检查 compression_check，反馈摘要和压缩决定按 [交接与历史操作](handoff.md) 执行。反馈先 `show` 取最新标题和 revision，再 `report`。每个阶段用一句话概括、按需明细记录实际证据；同阶段无新进展不重复追加。阶段顺序为 `development-complete → debug-page-ready → testing-passed`，可分轮完成。先分别记录后端与 audi 的开发仓库；每个正向阶段核验后重新 `show`，传 `--expect-code '<item.code_revision>'` 绑定本次实际代码。代码变化后旧结论失效，按反馈 Skill 回退或重新核验后更新。

```bash
dboard-ai --cache <context 返回的本机缓存> report <本次 任务编号> \
  --expect-title '<最新标题>' --expect-revision '<最新 revision>' \
  --expect-code '<核验后 show 返回的 code_revision>' \
  --stage debug-page-ready --debug-page '/实际模块路由' \
  --summary '调试页面及测试台入口已完成，构建通过，待真实环境联调。' \
  --details '说明实际覆盖的业务步骤、验证结果及下一步。' \
  --handoff-file '/本机临时文件/本轮摘要.json' \
  --compression-decision skip --compression-reason '本轮已增量更新，尚未达到整体整理阈值' \
  --event-id '<本轮唯一编号>'
```

`--debug-page` 是真实模块路由，不是固定填写 /test-console。确实已部署并核实可访问时才额外传 `--debug-url 'https://实际地址/实际模块路由'`；未部署时省略，D板展示路径供后续接手。开发核验阶段不必传页面参数。AI可独立试调的部分通过后沿用模块路径记录 `testing-passed`，概括仍保留「待人工联调」。

页面及AI可调部分已完成，或剩余事项需要用户协调内部／外部联调时，记录交接并结束；需求、代码与条件未变就不重复开发、试调或追加相同记录。
