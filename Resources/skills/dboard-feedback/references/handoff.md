# 接续状态与按需读取

context 任务编号 默认加载原咒言、全部追加变更、用户纠正、四段接续状态、未覆盖新记录的概括、实际仓库与代码核验、清单概括和勾选状态。历史过程、清单明细及证据、上一版全文和详细操作规则按需读取。复制按钮只复制命令，不调用模型。

## 借鉴的机制

Claude Code 将长对话整理为结构化摘要，规则、记忆与计划重新加载，文件按需重读；Codex 根据上下文 token 预算触发压缩，也支持压缩指令。它们没有通用的固定摘要字数承诺。D板借鉴“当前任务状态＋重新读取权威资料＋按需追溯”，用人可读结构跨 AI 接续，不仿制某个模型的内部压缩格式。

来源：
- https://code.claude.com/docs/en/context-window.md
- https://learn.chatgpt.com/docs/config-file/config-reference.md
- https://developers.openai.com/api/docs/guides/compaction.md

## 每次决定

每次 context，包括完整模式和空历史，都重新返回 compression_check：check_id、时间、原因、计数和 review_questions；不缓存判断。AI 每次接手都须审视：
- 现在从哪里继续？有效成果、待做、阻塞、仍适用的决定和验证边界是否齐全？
- 有没有重复原咒言、变更、仓库、清单、Skill？这些从原数据读取，不在摘要重抄。
- 有没有已被推翻的结论、排查流水、历次提交或测试数量？移出当前状态，留下相关证据入口。
- 当前任务是开发、建调试页还是排查新报错？不能因历史“开发完成”忽略新任务。

决定 compact 或 skip：
- compact：整体核对接续状态，合并同一事实，淘汰过时结论，把暂不需要的过程与证据移到 resources。首次整理或历史覆盖失效时读全部历史；之后核对旧摘要与返回的“整体整理时读取”范围。摘要不足以支持结论时追溯相关旧记录或资料。原历史不删除。
- skip：当前状态足够支持接手，说明依据。有实质进展仍增量更新；无变化不重复回写。推荐整理却选择暂缓时，说明原因及未核对范围，不能把没读到的事实当完成。

新增记录只预览概括；有尚未覆盖的明细时 history_read_required 要求先读对应范围，再判断与更新状态，不能把没加载的过程当无事发生。

没有摘要、历史覆盖失效、需求或代码变化、旧策略待迁移、距上次整体整理累计10条记录，会自动提醒。AI也可因冲突、任务阶段切换、重复或自身上下文压力提前整理。10条是兜底提醒；字数统计仅供诊断，不用于触发或拒绝保存。增量更新覆盖计数与整体整理计数独立。

不设字数目标、最小长度或硬上限。质量取决于下一 AI 能否正确继续，不能靠截断关键待办和约束变短；也不能以“不限制长度”为由复制历史。保留影响当前行动的事实，细节留在可靠来源；尚未解决的矛盾必须明确，不强行合成确定结论。

## 形成有效的接续状态

四段分别记录：
- completed：已实现且当前仍适用的成果，避免列每轮经过。
- pending：明确下一步、阻塞或等待条件。无可执行事项就明确写出，不能自行发明优化。
- decisions：原咒言或方案没有直接表达、但继续工作必须知道的有效决定与边界。
- verification：当前适用的已测／未测与限制；不复述历次测试数量、提交列表，也不把局部通过当整体验收。

有新进展每轮用最新原数据更新四段，同时写一句话修改概括和按需明细。resources 是“主题、来源、何时读取”，不是另一份流水；references 兼容旧资料入口。只引用本轮实际查到的来源，不编造文件、记录或结论。

原咒言、全部追加变更、用户纠正、清单调整与实时代码状态始终优先，摘要不能覆盖它们。代码变化只提醒重新核验，更新摘要本身不重绑旧通过结论。用户复制后追加的报错属于当前任务；空填写区不产生任务。

## 按需读取

```bash
dboard-ai inspect D014 --section release
dboard-ai inspect D014 --section code
dboard-ai inspect D014 --section handoff
dboard-ai inspect D014 --section background
dboard-ai inspect D014 --section images
dboard-ai history D014 --from-record 1 --limit 20
dboard-ai history D014 --from-record 21 --to-record 40 --details
dboard-ai history D014 --query '退款' --all --details
dboard-ai show D014 --full
dboard-ai context D014 --full
```

优先用 context_sources 返回的带正确 cache 的 read_command。inspect 的 section 还支持 spell、changes；返回最新原文、revision及对应完整数据。核对、编辑上线事项或判断完成证据之前必须先读 release，保留用户编辑、删除、证据和勾选，不能把默认未加载的明细视为不存在。只了解当前阶段时无需先加载所有清单证据。原咒言和变更图片直接提供；其他图片按 images 或完整清单读取。

默认 history 取20条概括，用 next_record 翻页；--details 读取明细，--all 读取匹配范围全部。show 默认轻量状态；show --full 读取原始咒言、历史及上一版背景。context --full 仍执行新判断。记录 index 是读取时的位置，被编辑后应重读，不能当永久业务编号。

## 原子回写

把 JSON 写本机临时文件，通过 --handoff-file 提交。元数据由 CLI 管理，不手写隐藏行。示例仅展示结构，内容根据实际现状填写：

```json
{
  "based_on_records": 75,
  "sections": {
    "completed": "接口实现与调试页已完成。",
    "pending": "待上游测试环境联调；当前无可独立继续的开发事项。",
    "decisions": "重复查券后锁券再查照片；验券阶段不锁券。",
    "verification": "本地回归通过，真实券码流程尚未验证。"
  },
  "resources": [
    {
      "topic": "锁券失败处理依据",
      "source": "record:75；docs/锁券改造.md",
      "when_to_read": "排查锁券异常或修改重试行为时"
    }
  ],
  "references": []
}
```

based_on_records 是反馈前最新 context/show 的 history_records。四段必须齐全；无待办也明确。resources 可省略；更新时保留仍有用的入口、移除失效入口。不要用摘要复制覆盖用户补充、原咒言、变更、清单或实时代码核验。

```bash
dboard-ai report D014 \
  --expect-title '最新标题' --expect-revision '最新revision' \
  --summary '接口已实现，本地回归通过，待上游联调。' \
  --details '实际验证边界与后续处理；证据见已有文档。' \
  --handoff-file '/tmp/D014-handoff.json' \
  --compression-decision skip --compression-reason '已更新本轮成果和待办，无过时结论或重复内容，当前状态足够接续。' \
  --event-id '本轮唯一编号'
```

整体整理用 compact；只整理摘要省略 summary/details，不新增“压缩完成”的低信息记录。repo-only、清单核对等反馈也带判断；产生新事实或影响接续时更新摘要。无新变化且无需整理不必 report，直接反馈本次检查结果。

HANDOFF_REQUIRED：有新进度或 compact 缺摘要，先读原摘要及相关历史。
CONTEXT_REVIEW_REQUIRED：缺本轮决定或理由。
HANDOFF_SOURCE_CONFLICT／REVISION_CONFLICT：记录数或需求版本变化；重读、合并，再用最新 revision 和记录数，不能盲改数字。
INVALID_HANDOFF_DATA：损坏或格式未知；保留原始数据，不覆盖。

coverage 通过记录前缀指纹核验；历史编辑、删除、重排使旧覆盖失效。摘要更新不改变业务状态、代码核验、用户清单与勾选。判断保存在反馈元数据，不追加普通历史。完整历史、摘要和明细只在本机，远端仍只同步总览。
