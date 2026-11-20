"""Stable study units and revision-aware topic-note organization."""
import copy
import time
import uuid

DEFAULT_PREFERENCES = {
    "teachingStyle": "先看有来源的现象或结果，再解释指标、原因和判断；先说清对象与动作，通俗但有内容。",
    "checkPolicy": "每阶段结束集中检查，或用户主动复习/复测；不逐轮出题。“懂了”只算学习反馈。",
    "constraints": [],
}


def strings(value):
    return isinstance(value, list) and all(isinstance(row, str) and row.strip() for row in value)


def text_fields(value, fields):
    return isinstance(value, dict) and all(isinstance(value.get(key), str) for key in fields)


def snapshot(note):
    return {key: copy.deepcopy(note.get(key)) for key in
            ("id", "title", "body", "createdAt", "updatedAt", "learningStageID", "bookmark")}


def same_source(source, note):
    return all(source.get(key) == note.get(key) for key in
               ("id", "title", "body", "updatedAt", "learningStageID"))


def current_unit(item, stage_id):
    units = [row for row in item.get("learningUnits") or [] if stage_id in row["stageIDs"]]
    return next((row for row in units if row["id"] == item.get("currentLearningUnitID")), units[-1] if units else None)


def knowledge_context(item, stage_id, notes):
    unit = current_unit(item, stage_id)
    topic_ids = set(unit["topicIDs"] if unit else [])
    if not unit:
        for note in notes:
            if note.get("learningStageID") == stage_id or any(
                    source.get("learningStageID") == stage_id for source in note.get("sourceNotes") or []):
                topic_ids.update(note.get("topicIDs") or [])
    return {
        "learningPreferences": item.get("learningPreferences") or DEFAULT_PREFERENCES,
        "currentUnit": unit,
        "unitDirectory": [{key: row.get(key) for key in ("id", "title", "noteTitle", "stageIDs", "topicIDs")}
                          for row in item.get("learningUnits") or []],
        "relevantTopics": [row for row in item.get("learningTopics") or [] if row["id"] in topic_ids],
        "relevantNotes": [row for row in notes if topic_ids.intersection(row.get("topicIDs") or [])],
        "recentLearningFeedback": (item.get("learningFeedback") or [])[-3:],
        "evidencePolicy": "整理稿、AI补讲与自述懂了不算独立作答。历史作答保留；是否覆盖当前标准另判。",
        "noteNaming": "学习主题 → 已有知识主题 → 本节知识点。title 是讲解问题；noteTitle 是稳定的名词式知识标题，例如「推理速度、Prefill 与 Decode」。沿用已有术语，不用问句、对话或轮次作笔记标题，不为同一知识点不断改名。缺少 noteTitle 时 D板使用关联知识主题标题。",
        "unitFormat": {"id": "稳定单元ID", "title": "一个具体问题",
                       "noteTitle": "本节知识点的稳定概念标题，必填于新的教学回写；旧单元兼容省略",
                       "stageIDs": ["S001"], "topicIDs": [],
                       "question": "要解释的现象", "materialKind": "public_evaluation | verified_output | hypothetical",
                       "material": "已核结果或明确标为假设的例子", "conditions": "测试条件",
                       "metrics": "指标定义、方向与单位", "reasoning": "已知原因",
                       "limits": "不能从该材料推出什么", "judgment": "怎样用于判断",
                       "sources": [{"title": "来源标题", "url": "https://...", "locator": "表或章节"}]},
    }


def apply(item, active_notes, preferences=None, unit=None, topics=None, organization=None):
    if sum(value is not None for value in (preferences, unit, topics, organization)) != 1:
        raise ValueError("每次只回写偏好、单元、主题或整理草稿中的一种")
    if preferences is not None:
        if (not text_fields(preferences, ("teachingStyle", "checkPolicy"))
                or not preferences["teachingStyle"].strip() or not preferences["checkPolicy"].strip()
                or not strings(preferences.get("constraints"))):
            raise ValueError("学习偏好需要教学方式、检查时机和限制列表")
        item["learningPreferences"] = {key: copy.deepcopy(preferences[key]) for key in DEFAULT_PREFERENCES}
    if topics is not None:
        if (not isinstance(topics, list) or any(not text_fields(row, ("id", "title")) or
                not row["id"].strip() or not row["title"].strip() for row in topics)
                or len({row["id"] for row in topics}) != len(topics)):
            raise ValueError("知识主题需要唯一ID和标题")
        old = {row["id"]: row for row in item.get("learningTopics") or []}
        old.update({row["id"]: {key: row[key] for key in ("id", "title")} for row in topics})
        item["learningTopics"] = list(old.values())
    if unit is not None:
        fields = ("id", "title", "question", "materialKind", "material", "conditions", "metrics",
                  "reasoning", "limits", "judgment")
        if (not text_fields(unit, fields) or not all(unit[key].strip() for key in ("id", "title", "material"))
                or unit["materialKind"] not in ("public_evaluation", "verified_output", "hypothetical")
                or not strings(unit.get("stageIDs")) or not unit["stageIDs"] or not strings(unit.get("topicIDs"))
                or not isinstance(unit.get("sources"), list)):
            raise ValueError("学习单元格式不完整")
        if any(not text_fields(row, ("title", "url", "locator")) or
               not row["url"].startswith(("https://", "http://")) for row in unit["sources"]):
            raise ValueError("单元来源需要标题、完整URL与位置")
        if unit["materialKind"] != "hypothetical" and (not unit["sources"] or not unit["conditions"].strip()):
            raise ValueError("真实材料需要来源和测试条件；教学假设请明确标为hypothetical")
        stage_ids = {row["id"] for row in (item.get("learningPlan") or {}).get("stages", [])}
        topic_ids = {row["id"] for row in item.get("learningTopics") or []}
        if not set(unit["stageIDs"]) <= stage_ids or not set(unit["topicIDs"]) <= topic_ids:
            raise ValueError("单元关联的阶段或主题不存在")
        normalized = {key: copy.deepcopy(unit[key]) for key in (*fields, "stageIDs", "topicIDs", "sources")}
        existing = next((row for row in item.get("learningUnits") or [] if row["id"] == unit["id"]), {})
        note_title = unit.get("noteTitle", existing.get("noteTitle"))
        if note_title is not None:
            if (not isinstance(note_title, str) or not note_title.strip() or "\n" in note_title
                    or note_title.rstrip().endswith(("?", "？"))
                    or note_title.lstrip().startswith(("为什么", "怎么", "如何", "是否", "能否"))):
                raise ValueError("noteTitle 需要名词式知识标题，不能直接使用讲解问题")
            normalized["noteTitle"] = note_title.strip()
        item["learningUnits"] = [row for row in item.get("learningUnits") or [] if row["id"] != unit["id"]] + [normalized]
        if item.get("currentLearningStageID") in unit["stageIDs"]:
            item["currentLearningUnitID"] = unit["id"]
    if organization is not None:
        if (not text_fields(organization, ("id", "title", "body", "explanation"))
                or not all(organization[key].strip() for key in ("id", "title", "body", "explanation"))
                or any(not strings(organization.get(key)) for key in ("topicIDs", "unitIDs", "sourceNoteIDs"))
                or not isinstance(organization.get("sourceVersions"), dict)):
            raise ValueError("笔记整理需要正文、来源ID/版本、关联及修订说明")
        topic_ids = {row["id"] for row in item.get("learningTopics") or []}
        unit_ids = {row["id"] for row in item.get("learningUnits") or []}
        if not set(organization["topicIDs"]) <= topic_ids or not set(organization["unitIDs"]) <= unit_ids:
            raise ValueError("整理稿关联的主题或单元不存在")
        selected = [row for row in active_notes if row["id"] in organization["sourceNoteIDs"]]
        if (len(selected) != len(set(organization["sourceNoteIDs"])) or
                any(organization["sourceVersions"].get(row["id"]) != row["updatedAt"] for row in selected)):
            raise ValueError("原笔记已变化或不存在，先重新读取再整理")
        if any(row["id"] == organization["id"] for row in item.get("learningOrganizations") or []):
            raise ValueError("整理草稿ID已存在，请回看原草稿")
        draft = {key: copy.deepcopy(organization[key]) for key in
                 ("id", "title", "body", "explanation", "topicIDs", "unitIDs")}
        draft.update(createdAt=time.time(), sourceNotes=[snapshot(row) for row in selected])
        item["learningOrganizations"] = (item.get("learningOrganizations") or []) + [draft]


def adopt(item, draft_id, active_notes):
    draft = next((row for row in item.get("learningOrganizations") or [] if row["id"] == draft_id), None)
    if not draft or draft.get("adoptedNoteID"):
        raise ValueError("整理草稿不存在或已采纳")
    if any(not any(same_source(source, note) for note in active_notes) for source in draft["sourceNotes"]):
        raise ValueError("原笔记已变化，请重新整理；未覆盖任何内容")
    topics = {row["id"] for row in item.get("learningTopics") or []}
    units = {row["id"] for row in item.get("learningUnits") or []}
    if not set(draft["topicIDs"]) <= topics or not set(draft["unitIDs"]) <= units:
        raise ValueError("整理稿关联已变化")
    if item.get("notes") is None:
        item["notes"] = copy.deepcopy(active_notes)
    next_id = "N" + str(max([int(row["id"][1:]) for row in item["notes"]] or [0]) + 1).zfill(3)
    now = time.time()
    item["notes"].append({"id": next_id, "title": draft["title"], "body": draft["body"],
                          "createdAt": now, "updatedAt": now, "topicIDs": draft["topicIDs"],
                          "unitIDs": draft["unitIDs"], "sourceNotes": copy.deepcopy(draft["sourceNotes"]),
                          "origin": "ai_organized" if draft["sourceNotes"] else "ai_supplement"})
    draft["adoptedNoteID"] = next_id
    return next_id


def switch_stage(item, stage_id, active_notes, workflow):
    if (not workflow["planCurrent"] or workflow["finished"] or workflow["daysLeft"] < 0
            or not any(row["id"] == stage_id for row in item["learningPlan"]["stages"])):
        raise ValueError("切换需要尚未结束、未到期方案中的阶段")
    draft = item.get("learningNoteDraft") or {}
    if (draft.get("body", "").strip() or draft.get("title", "").strip()) and draft.get("learningStageID") != stage_id:
        if item.get("notes") is None:
            item["notes"] = copy.deepcopy(active_notes)
        next_id = "N" + str(max([int(row["id"][1:]) for row in item["notes"]] or [0]) + 1).zfill(3)
        item["notes"].append({**copy.deepcopy(draft), "id": next_id,
                              "createdAt": time.time(), "updatedAt": time.time()})
        item.pop("learningNoteDraft", None)
        draft = {}
    item["currentLearningStageID"] = stage_id
    unit = current_unit({**item, "currentLearningUnitID": None}, stage_id)
    item["currentLearningUnitID"] = unit["id"] if unit else None
    note = next((row for row in reversed(active_notes) if row.get("learningStageID") == stage_id), None)
    if note:
        item["selectedLearningNoteID"] = note["id"]
    else:
        stage = next(row for row in item["learningPlan"]["stages"] if row["id"] == stage_id)
        item["learningNoteDraft"] = {**draft, "learningStageID": stage_id,
                                     "title": draft.get("title") or stage["title"], "body": draft.get("body", "")}
        item["selectedLearningNoteID"] = "_draft"
