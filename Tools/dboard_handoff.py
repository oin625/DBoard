"""Lossless history, a task-state handoff, demand-loaded sources and a fresh check per read."""
import base64
import datetime
import hashlib
import json
import re
import uuid

PREFIX = "<!-- dboard-handoff:v1:"
SUFFIX = " -->"
SECTIONS = ("completed", "pending", "decisions", "verification")
LABELS = {"completed": "已完成", "pending": "待做与阻塞", "decisions": "关键决定", "verification": "验证与追溯"}
THRESHOLDS = {"records_since_compaction": 10}
POLICY = "task-state-v2"
REVIEW_QUESTIONS = [
    "只保留影响当前接手的成果、待办、阻塞、关键决定和验证边界了吗？",
    "是否重复了原咒言、追加变更、仓库、上线清单或固定Skill规则？这些从原数据按需读取。",
    "是否还有被新结论替代的旧方案、排查流水或历次提交/测试清单？证据移到可追溯入口。",
    "下一个AI能否确定从哪里继续、哪些未验证、哪些条件必须等待？有矛盾时先追溯。",
]


class HandoffError(ValueError):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def fail(message):
    raise HandoffError("INVALID_HANDOFF_DATA", message)


def digest(records):
    return hashlib.sha256(json.dumps(records, ensure_ascii=False, sort_keys=True,
                                     separators=(",", ":")).encode("utf-8")).hexdigest()


def text(value, label, maximum=None):
    if not isinstance(value, str) or (maximum is not None and len(value) > maximum) or any(
            ord(c) < 32 and c not in "\n\r\t" or ord(c) == 127 for c in value):
        fail(label + " must be plain text without control characters")
    return value.strip()


def validate(value):
    if not isinstance(value, dict) or value.get("version") != 1 or type(value.get("version")) is not int:
        fail("Unknown handoff format; original data was preserved")
    sections = value.get("sections")
    if not isinstance(sections, dict) or set(sections) != set(SECTIONS):
        fail("Handoff needs completed, pending, decisions and verification")
    for key in SECTIONS:
        text(sections[key], key)
    if not sections["pending"].strip():
        fail("State remaining work, waiting conditions, or explicitly state no actionable work")
    refs = value.get("references")
    if not isinstance(refs, list) or any(not text(x, "reference") for x in refs):
        fail("Invalid handoff references")
    if value.get("policy") not in (None, POLICY):
        fail("Unknown handoff policy; original data was preserved")
    resources(value.get("resources", []))
    for key in ("covered_count", "compacted_count"):
        if type(value.get(key)) is not int or not 0 <= value[key] <= 1000000:
            fail("Invalid handoff coverage")
    if value["compacted_count"] > value["covered_count"]:
        fail("Compaction cannot cover more than the handoff")
    for key in ("progress_hash", "compacted_hash", "scope_hash"):
        if not isinstance(value.get(key), str) or not re.fullmatch(r"[0-9a-f]{64}", value[key]):
            fail("Invalid handoff source fingerprint")
    code = value.get("code_revision")
    if code is not None and (not isinstance(code, str) or not re.fullmatch(r"[0-9a-f]{64}", code)):
        fail("Invalid handoff code fingerprint")
    for key in ("updated_at", "compacted_at"):
        if value.get(key) is not None:
            try:
                datetime.datetime.fromisoformat(value[key])
            except (ValueError, TypeError):
                fail("Invalid handoff timestamp")
    if value.get("updated_at") is None:
        fail("Handoff timestamp is missing")
    decision = value.get("last_decision")
    if not isinstance(decision, dict) or decision.get("decision") not in ("compact", "skip"):
        fail("Missing compaction decision")
    if not text(decision.get("reason"), "decision reason", 500):
        fail("Explain the compaction decision")
    return value


def read(block):
    rows = [x for x in block if x.startswith(PREFIX)]
    if not rows:
        return None
    try:
        if len(rows) != 1 or not rows[0].endswith(SUFFIX):
            fail("Duplicate or malformed handoff; original data was preserved")
        raw = base64.b64decode(rows[0][len(PREFIX):-len(SUFFIX)], validate=True)
        return validate(json.loads(raw.decode("utf-8")))
    except HandoffError:
        raise
    except (ValueError, TypeError, UnicodeError):
        fail("Handoff is unreadable; original data was preserved")


def store(block, value):
    validate(value)
    payload = base64.b64encode(json.dumps(value, ensure_ascii=False, sort_keys=True).encode("utf-8")).decode("ascii")
    block[:] = [x for x in block if not x.startswith(PREFIX)]
    block.append(PREFIX + payload + SUFFIX)


def summary_size(value):
    return sum(len(x) for x in value["sections"].values()) + sum(len(x) for x in value["references"]) if value else 0


def coverage(value, records):
    return bool(value and value["covered_count"] <= len(records) and
                value["progress_hash"] == digest(records[:value["covered_count"]]))


def evaluate(value, records, scope_hash, code_revision, now=None):
    """Always evaluate. Length is diagnostic only; it never rejects or forces a summary."""
    now = now or datetime.datetime.now().astimezone().isoformat(timespec="microseconds")
    valid = coverage(value, records)
    compact_valid = bool(value and value["compacted_count"] <= len(records) and
                         value["compacted_hash"] == digest(records[:value["compacted_count"]]))
    covered = value["covered_count"] if valid else 0
    checkpoint = value["compacted_count"] if compact_valid else 0
    delta = records[checkpoint:]
    scope_changed = bool(value and value["scope_hash"] != scope_hash)
    code_changed = bool(value and value.get("code_revision") != code_revision)
    policy_changed = bool(value and value.get("policy") != POLICY)
    reasons, codes = [], []
    for condition, code, reason in (
        (value is None and bool(records), "missing", "尚未建立交接状态，需要先核对已有历史"),
        (value is not None and not valid, "history-changed", "覆盖的历史被修改，需要重新核对"),
        (scope_changed, "scope-changed", "需求或追加变更已变化，需要核对当前重点与过时决定"),
        (code_changed, "code-changed", "代码状态已变化，需要核对旧验证边界"),
        (policy_changed, "policy-upgrade", "旧摘要需按当前接续状态整理，去掉流水及原资料的重复"),
        (len(delta) >= THRESHOLDS["records_since_compaction"], "history-accumulated",
         "距上次整体整理已累计至少10条记录，建议核对过时或重复信息"),
    ):
        if condition:
            codes.append(code)
            reasons.append(reason)
    needs_update = value is None or not valid or scope_changed or code_changed or policy_changed or covered != len(records)
    return {
        "evaluated": True, "check_id": uuid.uuid4().hex, "checked_at": now,
        "policy": POLICY, "ai_review_required": True, "recommended": bool(reasons),
        "reason_codes": codes, "review_questions": list(REVIEW_QUESTIONS),
        "reasons": reasons or ["未发现自动整理条件；仍须按接续任务检查信息是否过时、重复或缺失"],
        "thresholds": dict(THRESHOLDS),
        "metrics": {"history_records": len(records), "covered_records": covered,
                    "uncovered_records": len(records) - covered,
                    "records_since_compaction": len(delta),
                    "chars_since_compaction": sum(len(r["summary"]) + len(r["details"]) for r in delta),
                    "summary_chars": summary_size(value)},
        "summary_state": "missing" if value is None else "history-changed" if not valid else
                         "needs-update" if needs_update else "current",
        "scope_changed": scope_changed, "code_changed": code_changed, "policy_changed": policy_changed,
        "summary_update_required": needs_update,
        "last_compacted_at": value.get("compacted_at") if value else None,
        "last_decision": value.get("last_decision") if value else None,
    }


def resources(values):
    if not isinstance(values, list):
        fail("resources must be a list of topic, source and when_to_read")
    for value in values:
        if not isinstance(value, dict) or set(value) != {"topic", "source", "when_to_read"}:
            fail("Each resource needs topic, source and when_to_read")
        if any(not text(value[key], key) for key in value):
            fail("Resource fields cannot be empty")
    return values

def input_summary(value, expected_records):
    if not isinstance(value, dict) or set(value) - {"based_on_records", "sections", "references", "resources"}:
        fail("Handoff input needs based_on_records, sections and references; metadata is managed by DBoard")
    if type(value.get("based_on_records")) is not int or value["based_on_records"] != expected_records:
        raise HandoffError("HANDOFF_SOURCE_CONFLICT", "History changed or coverage is missing; reread context/history and update based_on_records")
    sections = value.get("sections")
    if not isinstance(sections, dict) or set(sections) != set(SECTIONS):
        fail("Supply all four handoff sections; do not silently drop pending decisions")
    sections = {key: text(sections[key], key) for key in SECTIONS}
    refs = value.get("references", [])
    if not isinstance(refs, list):
        fail("Invalid handoff references")
    refs = [text(x, "reference") for x in refs]
    if any(not x for x in refs):
        fail("Handoff contains empty references")
    if not sections["pending"]:
        fail("Explicitly state remaining work or no actionable work")
    return sections, refs, resources(value.get("resources", []))


def update(previous, records_before, records_after, scope_hash, code_revision,
           decision, reason, summary=None, now=None):
    if decision not in ("compact", "skip") or not isinstance(reason, str) or not reason.strip() or len(reason) > 500:
        raise HandoffError("CONTEXT_REVIEW_REQUIRED",
                           "Read context and report --compression-decision compact|skip --compression-reason with the actual judgment")
    if decision == "compact" and summary is None:
        raise HandoffError("HANDOFF_REQUIRED", "Compaction requires the refreshed handoff; read history before compacting")
    now = now or datetime.datetime.now().astimezone().isoformat(timespec="microseconds")
    last = {"decision": decision, "reason": text(reason, "decision reason", 500), "checked_at": now}
    if summary is None:
        if previous:
            result = dict(previous, last_decision=last)
            return result
        return None
    sections, refs, deferred = input_summary(summary, len(records_before))
    valid_checkpoint = bool(previous and previous["compacted_count"] <= len(records_after) and
                            previous["compacted_hash"] == digest(records_after[:previous["compacted_count"]]))
    checkpoint = len(records_after) if decision == "compact" else previous["compacted_count"] if valid_checkpoint else 0
    result = {"version": 1, "policy": POLICY, "sections": sections, "references": refs, "resources": deferred,
              "covered_count": len(records_after), "progress_hash": digest(records_after),
              "scope_hash": scope_hash, "code_revision": code_revision, "updated_at": now,
              "compacted_count": checkpoint, "compacted_hash": digest(records_after[:checkpoint]),
              "compacted_at": now if decision == "compact" else previous.get("compacted_at") if previous else None,
              "last_decision": last}
    return validate(result)


def render(value):
    if value is None:
        return ""
    lines = []
    for key in SECTIONS:
        lines.extend(["### " + LABELS[key], value["sections"][key] or "未记录"])
    if value.get("resources"):
        lines.extend(["### 按需追溯"] + ["- " + r["topic"] + "：" + r["source"] + "；" + r["when_to_read"]
                                          for r in value["resources"]])
    if value["references"]:
        lines.extend(["### 其他追溯入口"] + ["- " + x for x in value["references"]])
    return "\n".join(lines)


def compact_item(item, scope_hash):
    result = {key: value for key, value in item.items() if key not in
              ("progress", "progress_records", "prompt", "images", "technical_plan")}
    records = item["progress_records"]
    result["history_records"] = len(records)
    result["progress_hash"] = digest(records)
    result["recent_progress"] = [{"index": index + 1, "date": record["date"], "summary": record["summary"]}
                                 for index, record in enumerate(records) if index >= len(records) - 3]
    result["compression_check"] = evaluate(item["handoff"], records, scope_hash, item["code_revision"])
    return result


def history_result(item, args):
    if args.from_record < 1 or args.limit < 1 or args.limit > 1000 or (
            args.to_record is not None and args.to_record < args.from_record):
        raise HandoffError("INVALID_ARGUMENT", "Use a positive history range and --limit within 1..1000")
    rows = [{"index": i + 1, **r} for i, r in enumerate(item["progress_records"])
            if i + 1 >= args.from_record and (args.to_record is None or i + 1 <= args.to_record)]
    if args.query:
        rows = [r for r in rows if args.query.casefold() in (r["summary"] + "\n" + r["details"]).casefold()]
    total = len(rows)
    chosen = rows if args.all else rows[:args.limit]
    return {"success": True, "id": item["id"], "title": item["title"], "revision": item["revision"],
            "history_records": len(item["progress_records"]), "matched_records": total,
            "progress_hash": digest(item["progress_records"]),
            "records": [{k: v for k, v in r.items() if k != "details" or args.details} for r in chosen],
            "has_more": len(chosen) < total,
            "next_record": chosen[-1]["index"] + 1 if len(chosen) < total and chosen else None}


def context(result, item, cache, scope_hash, full=False):
    import shlex
    from pathlib import Path
    records = item["progress_records"]
    handoff = item["handoff"]
    check = evaluate(handoff, records, scope_hash, item["code_revision"])
    result["compression_check"] = check
    result["history_read_command"] = shlex.join([str(Path.home() / ".local/bin/dboard-ai"),
                                               "--cache", str(cache), "history", item["id"]])
    if full:
        result["context_mode"] = "full"
        result["history_read_required"] = False
        result["item"]["handoff"] = handoff
        if item["handoff_notes"]:
            result["context"] += "\n## 用户补充或纠正（优先，保留原文）\n" + item["handoff_notes"]
        return result
    is_review = result.get("task") in ("code-review", "technical-plan")
    source = result["context"]
    if is_review:
        result["history_read_policy"] = "on-demand"
        result["reading_order"] = ["spell-and-changes", "handoff-and-code", "related-history-if-needed"]
    covered = check["metrics"]["covered_records"]
    delta = records[covered:]
    truncated = handoff is None or not coverage(handoff, records) or len(delta) > 5
    lines = ["## 交接摘要"]
    if handoff:
        lines.append(render(handoff))
        lines.append("覆盖记录：1～" + str(handoff["covered_count"]) + "；摘要状态：" + check["summary_state"])
        if check["summary_state"] != "current":
            lines.append("摘要只是此前交接结论；新增记录、用户补充、最新需求与代码核验状态优先。")
    else:
        lines.append("尚无交接摘要。CR先按原咒言、全部追加变更和实际代码审查；只在设计原因不明、信息冲突或证据不足时追溯相关历史，无需先整理全部历史。" if is_review else
                     "尚无交接摘要。先按history命令读取历史、核对已有成果和遗留事项并建立摘要，再接续业务工作。")
    if item["handoff_notes"]:
        lines.extend(["### 用户补充或纠正（保留原文，不由AI覆盖）", item["handoff_notes"]])
    lines.append("## 摘要之后的新记录")
    has_deferred_delta = any(record["details"] for record in delta)
    if has_deferred_delta:
        lines.append("这里只给新增记录概括，作为最新现状线索；CR遇到相关疑点时再读该条明细，不因明细未纳入摘要而自动补读。" if is_review else
                     "这里只给新增记录概括；未覆盖明细需先按下方history命令读取，再核对接续状态。")
    if truncated and delta:
        lines.append("仅展示最近5条概括；CR不自动读取未覆盖的全部历史，按审查疑点选取相关记录；概括与摘要不能替代当前需求和代码。" if is_review else
                     "仅展示最近5条概括；原记录完整保留。先按history读取未覆盖范围及明细，不能把未展示等同于已完成。")
        chosen = list(enumerate(records, 1))[-5:]
    else:
        chosen = list(enumerate(records, 1))[covered:]
    for index, record in chosen:
        lines.append("- 记录" + str(index) + " · " + record["date"] + "：" + record["summary"])
    if not delta:
        lines.append("没有未纳入摘要的新记录。")
    start = 1 if check["summary_state"] in ("missing", "history-changed") else covered + 1
    # An overall compaction must reconcile records since its own checkpoint, not just uncovered records.
    compact_from = 1 if handoff is None else min(start, handoff["compacted_count"] + 1)
    lines.extend(["## 每次读取的压缩判断",
                  "本次已执行判断；AI每次接手须结合推荐、原因和内容明确决定compact或skip。",
                  "系统推荐：" + ("整体整理" if check["recommended"] else "无自动整理条件"),
                  "原因：" + "；".join(check["reasons"]),
                  "判断时间：" + check["checked_at"],
                  "历史共" + str(len(records)) + "条；未纳入摘要" + str(len(delta)) +
                  "条；距上次整体整理" + str(check["metrics"]["records_since_compaction"]) + "条。",
                  ("CR仍每次判断compact或skip，但推荐压缩不要求本轮重建摘要、补读历史或先完成整理。未读到的内容保留为未知，不编造摘要覆盖。" if is_review else
                   "每轮有新进展就更新当前接续状态；整体整理去掉重复、过时和可按需读取的细节，不按字数截断。")])
    if is_review:
        lines.extend(["## CR读取顺序",
                      "1. 原咒言与全部追加变更：确定当前要求，后续变更优先。",
                      "2. 交接摘要、用户纠正和实际代码：理解现状并独立审查；摘要只是线索。",
                      "3. 相关历史明细：只有设计原因不明、信息冲突、证据不足或提交范围不清时按需追溯，不默认读全部历史。",
                      "按需找相关记录：" + result["history_read_command"] + " --query '实际审查疑点关键词' --limit 10 --details",
                      "按需读指定记录：" + result["history_read_command"] + " --from-record N --to-record N --details",
                      "CR可只追加本轮概括与明细，保留原摘要；不能把未读历史标为已覆盖。"])
    else:
        lines.extend(["按需读未覆盖历史：" + result["history_read_command"] + " --from-record " + str(start) + " --all --details",
                      "整体整理时读取：" + result["history_read_command"] + " --from-record " + str(compact_from) + " --all --details"])
    marker = "进度记录（概括及本地明细，按保存顺序，后面的记录更新）：\n"
    old = marker + (item["progress"] if item["progress"].strip() else
                    "尚未记录进度，请检查代码确认现状，不能据此认定尚未开发。")
    source = source.replace(old, "\n".join(lines), 1)
    first, last = source.find("## 上线前事项\n"), source.find("## 代码与执行现状\n")
    if first >= 0 and last > first:
        source = source[:first] + ("## 上线前事项\n最新清单见item.release_checklist；保留用户修改、勾选、明细与证据。"
                                  "未勾选不等于待开发，也不授权发布或执行生产SQL。\n") + source[last:]
    if item["version"] and item["version"]["background"]:
        source = source.replace(item["version"]["background"],
                                "上一版完整背景通过show --full按需读取；本轮需求与追加变更优先。", 1)
    result["context"] = source
    result["context_mode"] = "compact"
    result["history_read_required"] = not is_review and bool(delta and (truncated or has_deferred_delta))
    result["item"]["history_records"] = len(records)
    result["item"]["progress_hash"] = digest(records)
    result["item"]["handoff_updated_at"] = handoff["updated_at"] if handoff else None
    result["item"]["repositories"] = item["repositories"]
    attach_sources(result, item, cache)
    return result


def inspect_result(item, section):
    fields = {
        "spell": ("prompt",),
        "plan": ("technical_plan", "technical_plan_state", "environment_repositories"),
        "changes": ("changes",),
        "release": ("release_checklist",),
        "code": ("repositories", "environment_repositories", "code_revision", "current_code", "execution", "execution_needs_review", "execution_review_reason", "last_code_review", "archived_code_reviews"),
        "handoff": ("handoff", "handoff_notes"),
        "background": ("version",),
        "images": ("images",),
        "incident": ("kind", "incident_closure", "experience_review"),
    }
    return {"success": True, "id": item["id"], "title": item["title"], "revision": item["revision"],
            "section": section, "data": {key: item[key] for key in fields[section]}}


def attach_sources(result, item, cache):
    """Keep authoritative state fresh, and make deferred detail explicit and retrievable."""
    import shlex
    from pathlib import Path
    cli = [str(Path.home() / ".local/bin/dboard-ai"), "--cache", str(cache)]
    labels = {
        "spell": ("原咒言", "需要回读原始输入时"),
        "plan": ("技术方案正文", "设计、实现、方案变化或提交开发交付前按需核对"),
        "changes": ("追加变更", "需要核对变更原文或编号时"),
        "release": ("上线清单明细与完成证据", "核对、编辑上线事项或判断证据时，先读取完整清单"),
        "code": ("当前代码与核验", "核验实现或提交正向阶段前"),
        "handoff": ("交接状态与用户纠正", "更新摘要或核对用户纠正时"),
        "background": ("上一版背景", "当前任务确实依赖上一版细节时"),
        "images": ("全部本机附件", "需要查看清单证据或历史背景图片时"),
    }
    result["context_sources"] = [
        {"section": section, "topic": topic, "when_to_read": when,
         "read_command": shlex.join(cli + ["inspect", item["id"], "--section", section])}
        for section, (topic, when) in labels.items()
        if section != "background" or item.get("version")
    ]
    checklist = item["release_checklist"]
    result["item"]["release_checklist"] = {
        **{key: value for key, value in checklist.items() if key != "items"},
        "items": [{key: entry[key] for key in ("id", "text", "category", "done", "updated_by")} |
                  {"has_details": bool(entry.get("details")), "has_evidence": bool(entry.get("evidence"))}
                  for entry in checklist["items"]],
        "details_deferred": any(entry.get("details") or entry.get("evidence") for entry in checklist["items"]),
    }
    result["item"]["technical_plan_state"] = item["technical_plan_state"]
    result["item"]["environment_repositories"] = item["environment_repositories"]
    result["item"]["handoff_notes"] = item["handoff_notes"]
    result["context_layout"] = {
        "always_loaded": ["原咒言与全部追加变更", "用户纠正", "当前接续状态", "未覆盖的新记录",
                          "实际仓库和代码核验", "清单当前勾选与用户维护状态", "最新核心Skill"],
        "deferred": ["清单明细与完成证据", "上一版完整背景", "历史排查过程", "资料原文", "完整操作规则"],
        "priority": "最新用户要求与原始状态优先；摘要只帮助接续，不取代它们",
    }
    release_command = shlex.join(cli + ["inspect", item["id"], "--section", "release"])
    result["context"] = result["context"].replace(
        "最新清单见item.release_checklist；保留用户修改、勾选、明细与证据。",
        "当前清单概括与勾选见item.release_checklist；明细与证据按需读取：" + release_command + "。保留用户修改。")
    # Requirement images remain immediately available; completion proof is read with its checklist.
    from dboard_ai import image_references
    active = image_references(item["prompt"] + "\n" + item["description"] + "\n" + "\n".join(change["intent"] for change in item["changes"]))
    if item["images"] != active:
        image_start = result["context"].find("## 需求图片\n")
        image_end = result["context"].find("## D板任务与执行反馈", image_start)
        if image_start >= 0 and image_end > image_start:
            image_lines = ["## 需求图片", "原咒言和追加变更中的本机图片须逐张打开；清单证据/历史附件按context_sources.images读取。"]
            image_lines += ["- " + entry["label"] + "：" + entry["path"] +
                            ("" if entry["exists"] else "（图片文件缺失）") for entry in active]
            result["context"] = result["context"][:image_start] + "\n".join(image_lines) + "\n" + result["context"][image_end:]
        result["images"] = active
