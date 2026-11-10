# 线上排查与经验

只在 item.kind 为「线上排查」时使用收集流程。普通需求不要求经验判断、不自动形成经验。任意能访问本机 CLI 的 AI 会话都可以只读查询经验；没有 任务编号时，不擅自创建任务或回写旧案例。

## 接手与检索

context 给本次问题原文、用户纠正、当前状态、经验候选概括和查询命令。候选只是线索，采用前用 knowledge read 核对查法、确定程度、边界及来源。原始输入和本次证据优先。类似现象可能不同根因，不同现象也可能同机制；服务帮助匹配，不能只按服务分库。

查不到时从接口、报错别称及可能机制扩展查询，不能把零命中认定没有经验，也不直接把候选机制当根因。

```bash
dboard-ai knowledge search '车点点 照片为空'
dboard-ai knowledge search '登录态失效' --service ultra
dboard-ai knowledge search '线程池 超时'
dboard-ai knowledge read K012
```

优先使用 context 返回的绝对 CLI 和 --cache。search 只返回概括；service/mechanism 帮助排序，不屏蔽跨服务结果。read 返回完整经验、revision及原案例命令。已完结案例只供证据追溯，不继续开发或回写；停用条目不应用其查法。

不要求PRD、不默认建调试页；有实际代码修复才按需核验、准备发布清单。正式需求关联可作参考，不要求排查等待其验收。用户明确要求时可通过CLI完结；恢复仍由用户在D板操作。发布、生产SQL或有业务副作用的试调仍按本次明确授权执行。

## 用户要求完结时

用户明确说“完结P001”“结束本次排查”时，核对最新 `show` 的标题、类型和revision，然后调用：

```bash
dboard-ai incident close P001 \
  --expect-title 'show返回的title' --expect-revision 'show返回的revision' \
  --outcome resolved --summary '已修正配置，用户确认问题恢复。'
```

实际执行使用本机绝对CLI及当前cache；context的incident_commands提供当前任务命令。outcome按事实选：resolved（已处理）、handed-off（已定位并交接，说明交给谁）、stopped（结束本次排查，原因未定，说明结束原因）。可用--details补充证据或交接内容，明细仅存本机。不要把原因未定或仅交接写成已处理。

只执行轻量完结，不为此重新排查、生成方案、做全量测试或新写摘要。若本轮确有尚未保存的新成果或经验，先按正常report保存，再重新show；没有新成果不重复report。命令自动留一句概括，写入完结结果，标为已完成，保留原咒言、历史、摘要、经验和工作树。已完结时返回unchanged，不覆写结论或重复追加；用户可在D板恢复排查。工作树清理是另一个明确授权的动作。

只支持线上排查类型，兼容旧D编号排查；普通开发需求不能用此命令完成。清单为空无需额外确认，有未勾选事项时返回RELEASE_CHECKLIST_INCOMPLETE，反馈用户处理，不代勾选或绕过。标题／revision变化先重读；本地已保存而同步失败只重试sync，不重复完结。默认缓存仅同步总览、状态与进度概括，自定义cache或--no-sync仅本地保存。

## 每轮判断

每轮 report 都要明确：
- create：有可复用的新根因及处理方法，或经证据验证的查法；先搜索避免重复。
- update：已有同类经验，补别称、案例、范围或更可靠的查法；先 read 获取最新 revision。
- skip：无有效新信息、只有尝试流水或证据不足，说明具体原因。

判断独立保存，不新增“判断完成”的历史。总结围绕下一次如何查：什么现象、先查哪里、不同结果怎样继续、已确认什么、哪些未确认、证据在哪。不要复制完整背景、日志、历次测试或当前上线清单。

根因未确认但查法有效时用 method，明确未确认部分；confirmed 必须有证据支持的 finding。不能从“重启恢复”直接推定同根因。主要机制是开放名称，原因未定可留空；symptoms 收集不同表现与别称，scopes 写实际服务、接口、版本或条件，由 AI 提炼，用户不另填。路径相同、边界相容时更新；不同原因或冲突条件分别保存，可用 related_ids 关联，不能揉成一个确定结论。

## 原子反馈

经验 JSON 只写内容，不手写来源、维护状态或整份库：
```json
{
  "title": "核对第三方响应中的登录态失效",
  "mechanism": "登录态失效",
  "symptoms": ["接口返回401", "响应变成登录页HTML", "页面跳回登录"],
  "scopes": ["填写本次已核验的服务和接口"],
  "procedure": "先看原始响应类型，再核对请求头和凭证来源；响应已有业务数据时转查解析。",
  "finding": "",
  "confidence": "method",
  "boundaries": "根因和凭证有效性仍需按实际证据核对。",
  "evidence": ["本次实际日志、资料路径或历史记录读取线索"],
  "related_ids": []
}
```

示例仅说明格式，提交必须来自实际排查。更新另加 id 和 expect_revision（knowledge read 返回的经验 revision），保留仍有效内容，只改有依据的部分。D板自动关联当前排查任务，合并现象、范围和来源；经验与任务反馈同锁原子完成，出错不保存一半。

```bash
dboard-ai report 任务编号 \
  --expect-title '最新标题' --expect-revision '最新任务revision' \
  --summary '本轮已确认的结果。' --details '依据及下一步。' \
  --handoff-file '/本机临时文件/接续状态.json' \
  --compression-decision skip --compression-reason '当前状态足够接续，没有过时或重复结论。' \
  --experience-decision create --experience-reason '本次查法经证据核对，可供同类问题复用。' \
  --experience-file '/本机临时文件/经验.json' \
  --event-id '本轮唯一编号'
```

update 更换判断，skip 省略 experience-file。有实质进展仍更新交接状态；无变化不重复回写。压缩与经验判断各管自己的内容，不能相互替代。重试保留同一 event-id 和原参数。

用户修正的标题、机制、查法、结论、确定程度和边界受保护；保留这些内容后可补来源、别称或证据。新证据冲突时先明确告知，不覆盖修正或新建同名条目绕过保护。停用经验不能由 AI 恢复。

EXPERIENCE_REVIEW_REQUIRED：排查反馈缺判断或理由。
EXPERIENCE_FILE_REQUIRED：create/update 缺文件，或 skip 误传文件。
EXPERIENCE_TASK_REQUIRED：普通需求不能通过该流程写经验。
KNOWLEDGE_REVISION_CONFLICT：重读、合并，不能盲改 revision。
KNOWLEDGE_EXISTS：先读匹配条目；可复用就更新，边界不同则明确区分。
KNOWLEDGE_USER_MAINTAINED／KNOWLEDGE_DISABLED：保留用户修正和停用决定，不强行重试。
INVALID_KNOWLEDGE_DATA：原库或格式异常，保留数据，不按空库覆盖。
