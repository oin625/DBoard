import dboard_learning
"""Local personal workspace: independent of formal demands and remote synchronization."""
import argparse
import copy
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import sys
import tempfile
import time
import uuid

DEFAULT_STORE = Path.home() / ".claude/dboard-try.json"
KINDS = ("idea", "task", "digestion")
LABELS = {"idea": "想法", "task": "任务", "digestion": "消化"}


class TryError(Exception):
    pass


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise TryError(message)


def emit(value):
    print(json.dumps(value, ensure_ascii=False))


def scalar(value):
    if not isinstance(value, str) or not value.strip() or any(ord(c) < 32 for c in value):
        raise TryError("请使用非空的一行概括")
    return value.strip()


def empty_document():
    return {"version": 1, "entries": [], "projects": [], "bookmarks": {}}


def read(store):
    if not store.exists():
        return empty_document()
    try:
        value = json.loads(store.read_text(encoding="utf-8"))
        if not isinstance(value, dict) or type(value.get("version")) is not int or value["version"] != 1:
            raise ValueError()
        if not isinstance(value.get("entries"), list) or not isinstance(value.get("projects"), list):
            raise ValueError()
        if not isinstance(value.get("bookmarks", {}), dict):
            raise ValueError()
        drafts = value.get("captureDrafts")
        if drafts is not None:
            if not isinstance(drafts, dict):
                raise ValueError()
            for kind, draft in drafts.items():
                if kind not in KINDS or not isinstance(draft, dict) or not all(isinstance(draft.get(k), str) for k in ("body", "title")):
                    raise ValueError()
        addition_drafts = value.get("additionDrafts")
        if addition_drafts is not None:
            if not isinstance(addition_drafts, dict):
                raise ValueError()
            for item_id, draft in addition_drafts.items():
                if not re.fullmatch(r"T[0-9]{3,}", item_id) or not isinstance(draft, dict) or not isinstance(draft.get("body"), str):
                    raise ValueError()
        last_number = value.get("lastEntryNumber")
        if last_number is not None and (type(last_number) is not int or last_number < 0):
            raise ValueError()
        ids = set()
        for entry in value["entries"]:
            if not isinstance(entry, dict) or not re.fullmatch(r"T[0-9]{3,}", entry.get("id", "")) or entry["id"] in ids:
                raise ValueError()
            ids.add(entry["id"])
            if entry.get("deletedAt") is not None and type(entry["deletedAt"]) not in (int, float):
                raise ValueError()
            if entry.get("kind") not in KINDS or entry.get("status") not in ("active", "done", "shelved"):
                raise ValueError()
            if type(entry.get("revision")) is not int or entry["revision"] < 1:
                raise ValueError()
            for field in ("title", "body", "progress", "nextStep", "aiSummary", "aiResult"):
                if not isinstance(entry.get(field), str):
                    raise ValueError()
            if not isinstance(entry.get("relatedIDs"), list) or not all(isinstance(x, str) for x in entry["relatedIDs"]):
                raise ValueError()
            if not isinstance(entry.get("reports"), list) or not isinstance(entry.get("conversions"), list):
                raise ValueError()
            if any(not isinstance(entry.get(field), (int, float)) for field in ("createdAt", "updatedAt")):
                raise ValueError()
            additions = entry.get("additions") or []
            if not isinstance(additions, list):
                raise ValueError()
            addition_ids = set()
            for addition in additions:
                if not isinstance(addition, dict) or not re.fullmatch(r"A[0-9]{3,}", addition.get("id", "")) or addition["id"] in addition_ids:
                    raise ValueError()
                addition_ids.add(addition["id"])
                if not isinstance(addition.get("body"), str) or not addition["body"].strip() or type(addition.get("revision")) is not int or addition["revision"] < 1:
                    raise ValueError()
                if type(addition.get("createdAt")) not in (int, float):
                    raise ValueError()
                for key in ("completedAt", "withdrawnAt"):
                    if addition.get(key) is not None and type(addition[key]) not in (int, float):
                        raise ValueError()
                if addition.get("completionSummary") is not None and not isinstance(addition["completionSummary"], str):
                    raise ValueError()
            for report in entry["reports"]:
                if not isinstance(report, dict) or not all(isinstance(report.get(k), str) for k in ("id", "summary", "details")) or not isinstance(report.get("at"), (int, float)):
                    raise ValueError()
            for conversion in entry["conversions"]:
                if not isinstance(conversion, dict) or conversion.get("from") not in KINDS or conversion.get("to") not in KINDS or not isinstance(conversion.get("at"), (int, float)):
                    raise ValueError()
        projects = set()
        for project in value["projects"]:
            if not isinstance(project, dict) or not re.fullmatch(r"TP[0-9]{3,}", project.get("id", "")) or project["id"] in projects:
                raise ValueError()
            projects.add(project["id"])
            if not isinstance(project.get("name"), str) or not isinstance(project.get("context"), str) or type(project.get("revision")) is not int or not isinstance(project.get("createdAt"), (int, float)):
                raise ValueError()
        return value
    except (ValueError, TypeError, KeyError, UnicodeError) as error:
        raise TryError("个人空间数据无法读取或版本不支持；原文件已保留，未进行写入") from error


def transaction(store, action):
    store.parent.mkdir(parents=True, exist_ok=True)
    with open(str(store) + ".lock", "a", encoding="utf-8") as lock:
        os.chmod(lock.name, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        value = read(store)
        result = action(value)
        temporary = None
        try:
            with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=store.parent, delete=False) as file:
                temporary = file.name
                json.dump(value, file, ensure_ascii=False, indent=2, allow_nan=False)
                file.flush()
                os.fsync(file.fileno())
            os.chmod(temporary, 0o600)
            os.replace(temporary, store)
        finally:
            if temporary and os.path.exists(temporary):
                os.unlink(temporary)
        return result


def next_id(prefix, records):
    maximum = max([int(row["id"][len(prefix):]) for row in records if re.fullmatch(re.escape(prefix) + r"[0-9]+", row["id"])] or [0])
    return prefix + str(maximum + 1).zfill(3)


def allocate_entry_id(document):
    maximum = max([int(row["id"][1:]) for row in document["entries"]] or [0])
    document["lastEntryNumber"] = max(document.get("lastEntryNumber") or 0, maximum) + 1
    return "T" + str(document["lastEntryNumber"]).zfill(3)


def entry(document, item_id):
    if not re.fullmatch(r"T[0-9]{3,}", item_id):
        raise TryError("次 Try 使用独立的 T 编号，例如 T001；D/P 编号属于主 Main")
    result = next((row for row in document["entries"] if row["id"] == item_id), None)
    if result is None:
        raise TryError("找不到这条个人记录")
    if result.get("deletedAt") is not None:
        raise TryError("这条个人记录已移到回收站；请用户恢复后再继续，不新增或重复执行")
    return result


def project(document, project_id):
    result = next((row for row in document["projects"] if row["id"] == project_id), None)
    if result is None:
        raise TryError("找不到这个个人项目")
    return result


def text_file(path):
    return Path(path).expanduser().read_text(encoding="utf-8") if path else None


def learning_notes(item, include_deleted=False):
    notes = item.get("notes")
    if notes is None:
        notes = ([{"id": "N001", "title": "", "body": item["body"],
                   "createdAt": item["createdAt"], "updatedAt": item["updatedAt"]}]
                 if item["kind"] == "digestion" and item["body"].strip() else [])
    return [note for note in notes if include_deleted or note.get("deletedAt") is None]


def note_title(note):
    return note.get("title") or (note.get("body", "").splitlines() or ["未命名笔记"])[0][:40]


def instructions(item, command):
    if item["kind"] == "idea":
        return (
            "D板「次 Try」用于记录和讨论用户的想法。先读 body 中的最初想法和 ideaSupplements 中全部有效补充，再读 AI 摘要与解释。\n"
            "补充按时间延续同一个想法，不是待执行的开发任务；后续补充如有明确调整，以用户最新表达为准，含糊或矛盾时先澄清。图片按 images 中的本机路径查看。\n"
            "保留用户原文和补充，AI 不直接覆盖。讨论、澄清和完善想法；未经用户明确指令，不自行实施或写代码。\n"
            "每轮回写一句话 summary；解释用 --result-file，最新讨论摘要用 --handoff-file，details 按需。历史明细仅在追溯时用 history。\n"
            "反馈前重新 context，传 --expected-revision 防止覆盖用户的新改动。没有明确问题时直接反馈，不新增任务。\n"
            "反馈示例：" + command + " report " + shlex.quote(item["id"])
            + " --expected-revision <最新revision> --summary '本轮讨论概括' --result-file <解释文件> --handoff-file <最新摘要文件>"
        )
    if item["kind"] != "task":
        return (
            "D板是用户的本机工作台，「次 Try」用于学习笔记和想法，不管理开发任务。\n"
            + ("帮助用户理解资料、解答当前疑问；用解释、例子和可选练习帮助学习，不能把读过或讲解完等同于已掌握。\n"
               if item["kind"] == "digestion" else "讨论、澄清和完善想法；未经用户明确指令，不自行实施或写代码。\n")
            + "先读 currentNote 或 currentDraft、学习资料、用户的进度与已确认成果，再读 AI 摘要。其他笔记按 noteDirectory 按需读取："
            + command + " note " + shlex.quote(item["id"]) + " <笔记ID>。历史明细需要追溯才用 history。\n"
            "笔记、资料、进度与成果是用户维护的内容，AI 不直接覆盖。解释放 --result-file，交接摘要放 --handoff-file。\n"
            "每轮回写一句话 summary，details 按需；反馈前重新 context，传 --expected-revision 防止覆盖新改动。\n"
            "学习的 --progress 和 --next-step 只保存为建议，不更新用户实际进度。可重复传 --learning-outcome '成果建议'，"
            "用 --learning-note N001 关联对应笔记；建议由用户确认后采纳。建议必须来自实际笔记、练习或用户确认，不能臆测已经学会。\n"
            "没有明确问题或待做事项时直接反馈，不新增任务，不自行推导工作。\n"
            "反馈示例：" + command + " report " + shlex.quote(item["id"])
            + " --expected-revision <最新revision> --summary '本轮讨论概括' --result-file <解释文件>"
            + " --handoff-file <最新摘要文件>"
            + (" --progress '可选的进度建议' --learning-outcome '可选的成果建议' --learning-note <对应笔记ID>" if item["kind"] == "digestion" else "")
        )
    purpose = {
        "idea": "继续讨论、澄清或完善想法。用户没有要求实施时，不自行写代码或创建执行任务。",
        "task": "按用户的目标、项目资料和最新进展执行。实际验证能做的部分，留下成果与剩余事项。",
        "digestion": "帮助用户理解资料和解答疑问。保留用户已有理解，以解释、例子或可选练习继续；不能因为讲解结束就认定用户已经掌握。",
    }[item["kind"]]
    return (
        "D板是用户的本机工作台。当前记录在独立的「次 Try」个人空间，主 Main 的正式需求规则不适用于这里。\n"
        + purpose + "\n"
        "先读当前正文、项目共用资料、用户进展和当前 AI 摘要；历史明细仅在需要追溯时用 history 查询。正文里的图片使用本机图片工具查看。\n"
        "done 或 shelved 状态先反馈已留存/搁置，等待用户明确的新指令。active 也不意味着总有待做事项：目标已达到、或没有明确要做的事时直接反馈，不推导新工作。\n"
        "用户自己写的正文是权威资料，AI 不直接覆盖。每轮有新进展时，用 report 保存一句话 summary；details 按需写。\n"
        "pendingAdditions 是在已有成果上新增或调整的任务范围，优先核对，不得因旧摘要写着完成而跳过；已处理追加只作参考，不重做。\n"
        "实际完成某一追加后，在 report 中传 --complete-addition '<id>@<revision>'，例如 A001@1；可重复传多项。只回写确实处理过的版本，新追加、修改或仍待验证的部分留为待处理。历史明细含完整追加，可按需 history 查阅。\n"
        "当前 AI 摘要须概括目标、已达成结果、必要决策、未解问题和下一步；接续旧摘要，删掉过时信息，按语义整理。用 --handoff-file 写入；详细推理不放摘要。\n"
        "整理出的可供采纳的解释、结论或成果说明放 --result-file，界面单独展示，用户主动采纳才追加到正文。\n"
        "反馈前重新 context 取得最新 revision，report 必须传 --expected-revision；冲突就重读再判断，不覆盖用户调整。\n"
        "任务完成、是否消化完由用户在界面确认；AI 只填写实际情况、待确认事项。代码 commit message 使用中文，项目名与分支保留原文。\n"
        "反馈示例：" + command + " report " + shlex.quote(item["id"])
        + " --expected-revision <最新revision> --summary '一句话概括' --handoff-file <当前摘要文件>"
        + " --details-file <可选明细文件> --progress '当前进展' --next-step '下一步或留空' --result-file <可选成果文件>\n"
        "从普通 AI 会话开始个人项目工作：先 project list / list 查现有记录，明确收到动手指令后才 create；同一改造的后续调整继续记在原任务。"
    )


def context(document, item, store, learning_action=None):
    recent = copy.deepcopy(item)
    all_reports = recent.pop("reports")
    recent["recentReports"] = [{"id": row["id"], "at": row["at"], "summary": row["summary"]} for row in all_reports[-3:]]
    recent["reportCount"] = len(all_reports)
    cli = Path.home() / ".local/bin/dboard-ai"
    command = shlex.quote(str(cli)) + " try"
    if store != DEFAULT_STORE.resolve():
        command += " --store " + shlex.quote(str(store))
    learning_state = dboard_learning.workflow(item, learning_action) if item["kind"] == "digestion" else None
    additions = recent.pop("additions", None) or []
    pending = [row for row in additions if row.get("completedAt") is None and row.get("withdrawnAt") is None]
    processed = [row for row in additions if row not in pending]
    recent["pendingAdditions"] = pending
    recent["processedAdditions"] = [{
        "id": row["id"], "revision": row["revision"], "summary": row["body"].splitlines()[0],
        "completionSummary": row.get("completionSummary"),
        "status": "withdrawn" if row.get("withdrawnAt") is not None else "completed"
    } for row in processed[-5:]]
    recent["additionCount"] = len(additions)
    if item["kind"] == "idea":
        recent["ideaSupplements"] = [row for row in additions if row.get("withdrawnAt") is None]
        recent["pendingAdditions"] = []
        recent["processedAdditions"] = []
    if item["kind"] == "digestion":
        notes = learning_notes(item)
        selected = next((note for note in notes if note["id"] == item.get("selectedLearningNoteID")), None)
        selected = selected or (notes[-1] if notes else None)
        recent.pop("notes", None)
        recent.pop("body", None)
        recent["noteDirectory"] = [{"id": note["id"], "title": note_title(note), "updatedAt": note["updatedAt"],
                                    "learningStageID": note.get("learningStageID"), "topicIDs": note.get("topicIDs", []),
                                    "unitIDs": note.get("unitIDs", []), "origin": note.get("origin", "learner")} for note in notes]
        recent["currentNote"] = selected if item.get("selectedLearningNoteID") != "_draft" else None
        draft = recent.pop("learningNoteDraft", None)
        recent["currentDraft"] = draft if draft and (item.get("selectedLearningNoteID") == "_draft" or not selected) and (draft.get("body", "").strip() or draft.get("title", "").strip()) else None
        recent["confirmedOutcomes"] = recent.pop("outcomes", None) or []
        stage = learning_state["currentStage"]
        stage_id = stage["id"] if stage else None
        recent["currentStageNote"] = next((note for note in reversed(notes) if stage_id and note.get("learningStageID") == stage_id), None)
        recent["currentStageDraft"] = draft if draft and stage_id and draft.get("learningStageID") == stage_id else None
        lessons = recent.pop("learningLessons", None) or ([item["learningLesson"]] if item.get("learningLesson") else [])
        recent["learningLesson"] = next((row for row in reversed(lessons)
                                         if stage_id and row["stageID"] == stage_id and row["planID"] == (item.get("learningPlan") or {}).get("id")), None)
        recent["lessonDirectory"] = [{"stageID": row["stageID"], "planID": row["planID"]} for row in lessons]
        recent.pop("learningUnits", None)
        recent["currentUnit"] = learning_state["currentUnit"]
        recent["relevantTopicNotes"] = learning_state["relevantNotes"]
        organizations = recent.pop("learningOrganizations", None) or []
        recent["organizationDirectory"] = [{key: row.get(key) for key in
            ("id", "title", "explanation", "topicIDs", "unitIDs", "adoptedNoteID")} for row in organizations]
        history = recent.pop("learningCheckHistory", None) or []
        recent["historicalCheckCount"] = len(history)
        checks = recent.pop("learningStageChecks", None) or []
        recent["currentStageCheck"] = next((row for row in checks if row["stageID"] == stage_id), None)
        recent["stageCheckDirectory"] = [{"stageID": row["stageID"], "summary": row["summary"], "verdict": row["verdict"],
                                          "confirmed": bool(row.get("confirmedAt")), "current": dboard_learning.check_current(item, row),
                                          "noteIDs": list(row.get("evidenceVersions", {}))} for row in checks]
        if any(row["body"] == recent.get("aiResult") for row in lessons):
            recent["aiResult"] = ""
        if not dboard_learning.suggestion_current(item):
            recent.pop("learningSuggestion", None)
    data = {**recent}
    images = []
    image_additions = recent.get("ideaSupplements", pending)
    image_text = (item["body"] if item["kind"] != "digestion" else "") + "\n" + item["aiResult"] + "\n" + "\n".join(row["body"] for row in image_additions)
    if item["kind"] == "digestion":
        active_text = data.get("currentNote") or {}
        draft_text = data.get("currentDraft") or {}
        image_text += "\n" + active_text.get("body", "") + "\n" + draft_text.get("body", "") + "\n" + (item.get("learningSources") or "")
        image_text += "\n" + (data.get("currentStageNote") or {}).get("body", "") + "\n" + (data.get("currentStageDraft") or {}).get("body", "")
    selected_project = next((p for p in document["projects"] if p["id"] == item.get("projectID")), None) if item["kind"] == "task" else None
    if selected_project:
        image_text += "\n" + selected_project["context"]
    for label, path in re.findall(r"!\[([^\]\n]*)\]\(<(/[^>\n]+)>\)", image_text):
        images.append({"label": label, "path": path})
    if learning_state:
        data["learningWorkflow"] = learning_state
    return {
        "success": True, "space": "Try", "item": data,
        "project": selected_project,
        "related": [{"id": r["id"], "kind": r["kind"], "title": r["title"], "status": r["status"]}
                    for r in document["entries"] if r["id"] in item["relatedIDs"] and r.get("deletedAt") is None],
        "images": images,
        "action": "wait_for_user" if learning_state and learning_state["finished"] and not learning_state["duePractice"] else
                  ("continue_if_requested" if item["kind"] != "task" or item["status"] == "active" else "wait_for_user"),
        "feedback_instructions": dboard_learning.instructions(item, learning_state, command) if learning_state else instructions(item, command), "cli": command,
    }


def main(argv=None):
    parser = Parser(description="D板次 Try：学习笔记和想法。只操作本机个人数据。")
    parser.add_argument("--store", default=str(DEFAULT_STORE), help="独立数据路径，测试时可指定")
    sub = parser.add_subparsers(dest="command", required=True)
    listing = sub.add_parser("list")
    listing.add_argument("--kind", choices=KINDS)
    listing.add_argument("--project")
    listing.add_argument("--all", action="store_true")
    create = sub.add_parser("create")
    create.add_argument("--kind", choices=KINDS, required=True)
    create.add_argument("--title", required=True)
    create.add_argument("--body-file")
    create.add_argument("--project")
    create.add_argument("--related")
    for name in ("context", "history"):
        p = sub.add_parser(name)
        p.add_argument("id")
        if name == "context":
            p.add_argument("--learning-action", choices=["plan", "lesson", "check", "practice", "review"])
    note_reader = sub.add_parser("note")
    note_reader.add_argument("id")
    note_reader.add_argument("note_id")
    for name in ("switch-stage", "adopt-notes", "undo-notes"):
        action_parser = sub.add_parser(name)
        action_parser.add_argument("id")
        action_parser.add_argument("target_id")
        action_parser.add_argument("--expected-revision", type=int, required=True)
    for name in ("unit", "organization", "evidence"):
        reader = sub.add_parser(name)
        reader.add_argument("id")
        reader.add_argument("target_id")
    lesson_reader = sub.add_parser("lesson")
    lesson_reader.add_argument("id")
    lesson_reader.add_argument("stage_id")
    lesson_reader.add_argument("--plan-id")
    report = sub.add_parser("report")
    report.add_argument("id")
    report.add_argument("--expected-revision", type=int, required=True)
    report.add_argument("--summary", required=True)
    report.add_argument("--details-file")
    report.add_argument("--handoff-file")
    report.add_argument("--result-file")
    report.add_argument("--progress")
    report.add_argument("--next-step")
    report.add_argument("--event-id")
    report.add_argument("--learning-outcome", action="append", default=[])
    report.add_argument("--learning-note")
    report.add_argument("--plan-file")
    report.add_argument("--check-file")
    report.add_argument("--practice-file")
    report.add_argument("--review-file")
    report.add_argument("--lesson-stage")
    report.add_argument("--preferences-file")
    report.add_argument("--unit-file")
    report.add_argument("--topics-file")
    report.add_argument("--notes-file")
    report.add_argument("--complete-addition", action="append", default=[], metavar="ID@REVISION")
    projects = sub.add_parser("project")
    project_sub = projects.add_subparsers(dest="operation", required=True)
    project_sub.add_parser("list")
    new_project = project_sub.add_parser("create")
    new_project.add_argument("--name", required=True)
    new_project.add_argument("--context-file")
    set_project = project_sub.add_parser("set")
    set_project.add_argument("id")
    set_project.add_argument("--expected-revision", type=int, required=True)
    set_project.add_argument("--name")
    set_project.add_argument("--context-file")
    try:
        args = parser.parse_args(argv)
        store = Path(args.store).expanduser()
        if not store.is_absolute():
            raise TryError("数据路径必须是绝对路径")
        store = store.resolve()
        if args.command == "list":
            document = read(store)
            emit({"success": True, "items": [
                {key: item.get(key) for key in ("id", "kind", "title", "projectID", "status", "progress", "nextStep", "updatedAt")}
                for item in sorted(document["entries"], key=lambda x: x["updatedAt"], reverse=True)
                if item.get("deletedAt") is None and (args.all or item["kind"] != "task" or args.kind == "task")
                and (not args.kind or args.kind == item["kind"])
                and (not args.project or args.project == item.get("projectID"))
            ]})
        elif args.command in ("context", "history"):
            document = read(store)
            item = entry(document, args.id)
            emit(context(document, item, store, args.learning_action) if args.command == "context"
                 else {"success": True, "id": item["id"], "reports": item["reports"], "conversions": item["conversions"], "additions": item.get("additions") or []})
        elif args.command == "note":
            item = entry(read(store), args.id)
            note = next((note for note in learning_notes(item) if note["id"] == args.note_id), None)
            if note is None:
                raise TryError("找不到这篇笔记，或笔记已删除")
            image_paths = [{"label": label, "path": path} for label, path in re.findall(r"!\[([^\]\n]*)\]\(<(/[^>\n]+)>\)", note["body"])]
            emit({"success": True, "id": item["id"], "revision": item["revision"], "note": note, "images": image_paths})
        elif args.command in ("unit", "organization", "evidence"):
            item = entry(read(store), args.id)
            collection = (item.get("learningUnits") or []) if args.command == "unit" else (
                item.get("learningOrganizations") or []) if args.command == "organization" else (
                (item.get("learningCheckHistory") or []) + (item.get("learningStageChecks") or []))
            matches = [row for row in collection if row.get("id", row.get("stageID")) == args.target_id]
            if not matches:
                raise TryError("找不到对应学习记录")
            emit({"success": True, "id": item["id"], "revision": item["revision"], "records": matches})
        elif args.command in ("switch-stage", "adopt-notes", "undo-notes"):
            def change_learning(document):
                item = entry(document, args.id)
                if item["kind"] != "digestion" or item["revision"] != args.expected_revision:
                    raise TryError("学习记录已变化，请重新 context 读取")
                if args.command == "switch-stage":
                    dboard_learning.knowledge.switch_stage(item, args.target_id, learning_notes(item), dboard_learning.workflow(item))
                elif args.command == "adopt-notes":
                    dboard_learning.knowledge.adopt(item, args.target_id, learning_notes(item))
                else:
                    draft = next((row for row in item.get("learningOrganizations") or [] if row["id"] == args.target_id), None)
                    note = next((row for row in item.get("notes") or [] if draft and row["id"] == draft.get("adoptedNoteID")), None)
                    if not note:
                        raise TryError("找不到已采纳的整理稿")
                    note["deletedAt"] = time.time()
                    if item.get("selectedLearningNoteID") == note["id"]:
                        item["selectedLearningNoteID"] = "_draft"
                item["revision"] += 1
                item["updatedAt"] = time.time()
                item["reports"].append({"id": str(uuid.uuid4()), "at": time.time(),
                                        "summary": {"switch-stage": "切换学习阶段，保留待巩固记录",
                                                    "adopt-notes": "采纳主题笔记整理稿，保留原文",
                                                    "undo-notes": "撤回整理页，保留原文"}[args.command],
                                        "details": args.target_id + "：保留原笔记、草稿及真实检查；不改变掌握状态。"})
                return {"success": True, "local_saved": True, "revision": item["revision"]}
            emit(transaction(store, change_learning))
        elif args.command == "lesson":
            item = entry(read(store), args.id)
            lessons = item.get("learningLessons") or ([item["learningLesson"]] if item.get("learningLesson") else [])
            plan_id = args.plan_id or (item.get("learningPlan") or {}).get("id")
            lesson = next((row for row in reversed(lessons) if row["stageID"] == args.stage_id and row["planID"] == plan_id), None)
            if lesson is None:
                raise TryError("这一节还没有对应方案的AI讲解")
            emit({"success": True, "id": item["id"], "revision": item["revision"], "lesson": lesson})
        elif args.command == "create":
            title = scalar(args.title)
            body = text_file(args.body_file) or ""
            def create_entry(document):
                if args.project:
                    project(document, args.project)
                source = entry(document, args.related) if args.related else None
                now = time.time()
                item = {"id": allocate_entry_id(document), "kind": args.kind,
                        "title": title, "body": body, "projectID": args.project,
                        "relatedIDs": [source["id"]] if source else [], "status": "active",
                        "progress": "", "nextStep": "", "aiSummary": "", "aiResult": "",
                        "reports": [], "conversions": [], "createdAt": now, "updatedAt": now, "revision": 1}
                document["entries"].append(item)
                if source:
                    source["relatedIDs"].append(item["id"])
                    source["revision"] += 1
                return {"success": True, "local_saved": True, "item": item}
            emit(transaction(store, create_entry))
        elif args.command == "report":
            summary = scalar(args.summary)
            details = text_file(args.details_file) or ""
            handoff = text_file(args.handoff_file)
            result = text_file(args.result_file)
            plan_payload = json.loads(text_file(args.plan_file)) if args.plan_file else None
            check_payload = json.loads(text_file(args.check_file)) if args.check_file else None
            practice_payload = json.loads(text_file(args.practice_file)) if args.practice_file else None
            if args.practice_file and not isinstance(practice_payload, dict):
                raise TryError("复习反馈必须是JSON对象")
            knowledge_payloads = {
                key: json.loads(text_file(getattr(args, key + "_file"))) if getattr(args, key + "_file") else None
                for key in ("preferences", "unit", "topics", "notes")}
            if sum(value is not None for value in knowledge_payloads.values()) + sum(
                    bool(value) for value in (args.plan_file, args.check_file, args.practice_file, args.review_file, args.lesson_stage)) > 1:
                raise TryError("一次反馈只提交一个学习阶段动作")
            review = text_file(args.review_file)
            event_id = scalar(args.event_id) if args.event_id else str(uuid.uuid4())
            completions = {}
            for token in args.complete_addition:
                match = re.fullmatch(r"(A[0-9]{3,})@([1-9][0-9]*)", token)
                if not match or match[1] in completions:
                    raise TryError("追加完成标记需使用 ID@revision，例如 A001@1，且不可重复")
                completions[match[1]] = int(match[2])
            fingerprint_values = [summary, details, handoff, result, args.progress, args.next_step, args.learning_outcome, args.learning_note, plan_payload, check_payload, review, args.lesson_stage]
            if any(value is not None for value in knowledge_payloads.values()):
                fingerprint_values.append(knowledge_payloads)
            if args.practice_file:
                fingerprint_values.append({"practice": practice_payload})
            if completions:
                fingerprint_values.append(sorted(completions.items()))
            fingerprint = hashlib.sha256(json.dumps(
                fingerprint_values,
                ensure_ascii=False, separators=(",", ":")).encode("utf-8")).hexdigest()
            def report_entry(document):
                item = entry(document, args.id)
                for old in item["reports"]:
                    if old["id"] == event_id:
                        if old.get("fingerprint") == fingerprint:
                            return {"success": True, "local_saved": True, "duplicate": True, "revision": item["revision"]}
                        raise TryError("同一反馈编号已有不同内容，未更新")
                if item["revision"] != args.expected_revision:
                    raise TryError("记录已变化，请重新 context 读取最新内容后再反馈")
                if item["kind"] == "task" and item["status"] != "active":
                    raise TryError("记录已留存或搁置，请等用户明确继续")
                if args.learning_note and not any(note["id"] == args.learning_note for note in learning_notes(item)):
                    raise TryError("成果建议关联的笔记不存在或已删除，请重新读取")
                if args.learning_outcome and item["kind"] != "digestion":
                    raise TryError("学习成果建议只适用于学习主题")
                if any([args.plan_file, args.check_file, args.review_file, args.lesson_stage, args.practice_file]):
                    if item["kind"] != "digestion":
                        raise TryError("学习方案、讲解与自测只用于学习主题")
                    dboard_learning.apply_report(item, plan_payload, check_payload, review, args.lesson_stage, result,
                                                 practice_file=practice_payload)
                if any(value is not None for value in knowledge_payloads.values()):
                    if item["kind"] != "digestion":
                        raise TryError("学习单元、主题、偏好与笔记整理只用于学习")
                    if knowledge_payloads["unit"] is not None:
                        state = dboard_learning.workflow(item)
                        if not state["planCurrent"] or state["finished"] or state["daysLeft"] < 0:
                            raise TryError("学习单元需要当前有效、未到期且未结束的方案")
                    dboard_learning.knowledge.apply(item, learning_notes(item),
                        preferences=knowledge_payloads["preferences"], unit=knowledge_payloads["unit"],
                        topics=knowledge_payloads["topics"], organization=knowledge_payloads["notes"])
                matched = []
                for addition_id, revision in completions.items():
                    addition = next((row for row in (item.get("additions") or []) if row["id"] == addition_id), None)
                    if addition is None or addition.get("withdrawnAt") is not None or addition.get("completedAt") is not None:
                        raise TryError("这次追加不存在、已处理或已撤回，请重新 context 核对")
                    if addition["revision"] != revision:
                        raise TryError("追加内容已修改，不能沿用旧版本的完成结论")
                    matched.append(addition)
                now = time.time()
                for addition in matched:
                    addition["completedAt"] = now
                    addition["completionSummary"] = summary
                item["reports"].append({"id": event_id, "at": now, "summary": summary, "details": details, "fingerprint": fingerprint})
                if handoff is not None:
                    item["aiSummary"] = handoff
                elif not item["aiSummary"]:
                    item["aiSummary"] = summary
                if result is not None:
                    item["aiResult"] = "" if args.lesson_stage else result
                if item["kind"] == "digestion":
                    if args.progress is not None or args.next_step is not None or args.learning_outcome:
                        state = dboard_learning.workflow(item)
                        suggestion = {
                            "configRevision": (item.get("learningConfig") or {}).get("revision"),
                            "planID": (item.get("learningPlan") or {}).get("id") if state["planCurrent"] else None,
                            "stageID": (state["currentStage"] or {}).get("id"),
                            "outcomes": [
                            {"id": str(uuid.uuid4()), "text": scalar(text), "noteID": args.learning_note, "reference": ""}
                            for text in args.learning_outcome
                        ]}
                        if args.progress is not None:
                            suggestion["progress"] = args.progress
                        if args.next_step is not None:
                            suggestion["nextStep"] = args.next_step
                        item["learningSuggestion"] = suggestion
                else:
                    if args.progress is not None:
                        item["progress"] = args.progress
                    if args.next_step is not None:
                        item["nextStep"] = args.next_step
                item["updatedAt"] = now
                item["revision"] += 1
                return {"success": True, "local_saved": True, "revision": item["revision"]}
            emit(transaction(store, report_entry))
        elif args.command == "project":
            if args.operation == "list":
                emit({"success": True, "projects": read(store)["projects"]})
            else:
                name = scalar(args.name) if args.name is not None else None
                shared = text_file(args.context_file)
                def save_project(document):
                    if args.operation == "create":
                        duplicate = next((row for row in document["projects"] if row["name"] == name), None)
                        if duplicate:
                            return {"success": True, "local_saved": False, "existing": True, "project": duplicate}
                        row = {"id": next_id("TP", document["projects"]), "name": name,
                               "context": shared or "", "createdAt": time.time(), "revision": 1}
                        document["projects"].append(row)
                    else:
                        row = project(document, args.id)
                        if row["revision"] != args.expected_revision:
                            raise TryError("项目资料已变化，请重新读取后再更新")
                        if name is not None:
                            row["name"] = name
                        if shared is not None:
                            row["context"] = shared
                        row["revision"] += 1
                    return {"success": True, "local_saved": True, "project": row}
                emit(transaction(store, save_project))
        return 0
    except (TryError, OSError, UnicodeError, ValueError) as error:
        emit({"success": False, "local_saved": False, "error": {"code": "TRY_UPDATE_FAILED", "message": str(error)}})
        return 2


if __name__ == "__main__":
    sys.exit(main())
