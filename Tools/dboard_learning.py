"""Learning workflow: the coach plans a trial; mastery needs real evidence."""
import datetime
import time
import uuid
import dboard_learning_knowledge as knowledge


def notes(item):
    value = item.get("notes")
    if value is None:
        value = ([{"id": "N001", "title": "", "body": item["body"],
                   "createdAt": item["createdAt"], "updatedAt": item["updatedAt"]}]
                 if item.get("body", "").strip() else [])
    return [row for row in value if row.get("deletedAt") is None]


def check_current(item, check):
    config = item.get("learningConfig") or {}
    plan = item.get("learningPlan") or {}
    stage = next((row for row in plan.get("stages", []) if row["id"] == check.get("stageID")), None)
    if not stage or plan.get("configRevision") != config.get("revision"):
        return False
    if check.get("standards") is not None:
        if check["standards"] != {key: stage[key] for key in ("objective", "practice", "check")}:
            return False
    elif check.get("planID") != plan.get("id") or check.get("configRevision") != config.get("revision"):
        return False
    active = {row["id"]: row for row in notes(item)}
    if check.get("evidenceBodies") is not None:
        return all(key in active and active[key]["body"] == body for key, body in check["evidenceBodies"].items())
    return all(key in active and (active[key].get("contentUpdatedAt") or active[key]["updatedAt"]) == version
               for key, version in check.get("evidenceVersions", {}).items())


def due_practice(item):
    now = time.time()
    due = (check for check in item.get("learningStageChecks") or []
           if check.get("practice") and not check["practice"].get("completedAt")
           and check["practice"]["dueAt"] <= now and check_current(item, check))
    return min(due, key=lambda check: check["practice"]["dueAt"], default=None)


def next_practice_date():
    day = datetime.date.today() + datetime.timedelta(days=2)
    return datetime.datetime.combine(day, datetime.time.min).timestamp()


def workflow(item, requested=None):
    config = item.get("learningConfig") or {}
    ready = bool(config.get("goal", "").strip() and config.get("minutesPerDay", 0) > 0 and config.get("deadline"))
    days = ((datetime.datetime.fromtimestamp(config["deadline"]).date() - datetime.date.today()).days
            if ready else None)
    plan = item.get("learningPlan")
    current = bool(ready and plan and plan["configRevision"] == config["revision"])
    verified = [row["stageID"] for row in item.get("learningStageChecks") or []
                if row.get("confirmedAt") and check_current(item, row)]
    stages = plan["stages"] if current else []
    stage = next((row for row in stages if row["id"] == item.get("currentLearningStageID")), None)
    stage = stage or next((row for row in stages if row["id"] not in verified), None)
    if item.get("learningFinishedAt") or (ready and days < 0) or (current and len(verified) == len(stages)):
        action = "review"
    elif not current:
        action = "plan"
    else:
        action = "lesson"
    practice = due_practice(item) if ready and current and requested == "practice" else None
    return {
        **knowledge.knowledge_context(item, stage["id"] if stage else None, notes(item)),
        "requestedAction": requested or action, "nextAction": action, "configReady": ready,
        "targetDate": datetime.datetime.fromtimestamp(config["deadline"]).strftime("%Y-%m-%d") if ready else None,
        "daysLeft": days, "availableMinutes": max(0, days + 1) * config["minutesPerDay"] if ready else 0,
        "planCurrent": current, "currentStage": stage, "verifiedStageIDs": verified,
        "stageNotes": [{"id": row["id"], "title": row.get("title", ""), "updatedAt": row["updatedAt"]}
                       for row in notes(item) if stage and row.get("learningStageID") == stage["id"]],
        "finished": bool(item.get("learningFinishedAt")),
        "duePractice": {**practice["practice"], "stageID": practice["stageID"]} if practice else None,
        "planFormat": {"goalSummary": "页面上用一句通俗的话说明要获得的能力，完整边界留在target",
                       "target": "对用户学习目标的理解，不能扩大范围",
                       "startingPoint": "已核对的基础；不确定的部分明确写出",
                       "rationale": "为什么这样安排，如何在时间内达到目标",
                       "stages": [{"id": "S001", "title": "简短阶段名称", "summary": "这一阶段要弄懂什么，一句通俗的话", "objective": "本节要获得的能力",
                                   "resources": "已核对的参考资料或可选来源",
                                   "practice": "具体的小练习", "check": "怎样证明学会，不能只是看完",
                                   "estimatedMinutes": 30}]},
        "checkFormat": {"stageID": "S001", "verdict": "ready | needs_practice | insufficient_evidence",
                        "summary": "一句话说明掌握情况", "gaps": ["还需要练习的地方"],
                        "evidenceText": "真实的用户回答、练习结果或操作证据，不编造",
                        "noteIDs": ["N001"], "outcome": "确实能做到什么；不足时可留空",
                        "practice": {"gap": "真实回答暴露的一个薄弱点及错因", "question": "换个场景检验同一能力的题目，不带答案"}},
        "practiceFormat": {"id": "duePractice.id", "answer": "用户本次真实回答或操作结果",
                           "passed": "布尔值，是否正确解决本题", "feedback": "具体反馈和理由",
                           "nextQuestion": "未答对时，下一次用不同场景再验证同一能力"},
    }


def suggestion_current(item):
    suggestion = item.get("learningSuggestion") or {}
    if item.get("learningFinishedAt") or not any([
            (suggestion.get("progress") or "").strip(),
            (suggestion.get("nextStep") or "").strip(), suggestion.get("outcomes")]):
        return False
    state = workflow(item)
    if not state["configReady"]:
        return True
    plan_id = (item.get("learningPlan") or {}).get("id") if state["planCurrent"] else None
    stage_id = (state["currentStage"] or {}).get("id")
    return (suggestion.get("configRevision") == item["learningConfig"]["revision"] and
            suggestion.get("planID") == plan_id and suggestion.get("stageID") == stage_id)


def instructions(item, state, command):
    prefix = (
        "你是用户的学习教练。D板「次 Try」保存目标、时间、方案、笔记、自测和成果。\n"
        "当前状态以 learningWorkflow 为准；旧摘要或旧方案中的待确认文字不能阻止当前已生效的学习，回写摘要时清理过时状态。\n"
        "每轮都核对 learningConfig、learningWorkflow、当前方案、本节笔记和当前草稿。selected笔记可能属于其他节，按 learningStageID 和 stageNotes 核对，不能混用。其他笔记按目录用 note 读取；不默认读取全部历史。\n"
        "计划要服务于可验证的能力目标。基础不明确时先问两三个关键问题或做一个小诊断；不能假装已经知道用户水平。\n"
        "不能一次承诺完美方案。目标、当前基础、每天可投入时间和截止日期要匹配；无法兼顾时说明冲突，先请用户选择调整，不硬凑计划。\n"
        "learningPlanFeedback 是用户本次明确的调整意见，优先据此修订；对目标、偏好和实际时间仍有不确定时先澄清。\n"
        "只补达到目标必需的前置知识，不擅自扩大范围。根据试学、练习反馈调整节奏，已确认掌握且证据仍有效的部分不重教。\n"
        "learningPreferences 是持久偏好，constraints 必须遵守；本机模型运行/下载/安装的限制不能被新会话或方案覆盖。\n"
        "优先维护稳定学习单元：report --unit-file 按 unitFormat 保存当前完整单元；旧Markdown仍按需回看。来源、条件、指标定义紧邻结果，假设标为hypothetical，不能编造分数或因果解释。\n"
        "主题用 --topics-file [{id,title}] 合并；整理用 --notes-file 保存独立草稿（id,title,body,explanation,topicIDs,unitIDs,sourceNoteIDs,sourceVersions），不覆盖原文。\n"
        "教学单元回写时同时维护 noteTitle：用知识对象、概念或关系命名，术语与已有知识主题、整理笔记一致；讲解 title 可用问题句，noteTitle 不能照抄问题。新知识点再新增标题，同一知识点的后续答疑沿用标题。\n"
        "笔记标题单独写 title，body 不再重复同名大标题。正文围绕知识、例子和判断组织成小标题、短段或列表，保持清晰完整；原文修正、来源关系和整理过程写 explanation，掌握情况留在自测或复盘中，不夹入知识正文。\n"
        "继续教学无需确认掌握；用户明确要换阶段时，用 switch-stage <ID> <stageID> --expected-revision。不为换阶段重发计划。\n"
        "用户的笔记是权威原文，AI 解释单独保存；进度和成果建议由用户确认后采纳，不能把读过、听完讲解或笔记篇数等同于掌握。\n"
        "旧讲解按 lessonDirectory 用 lesson <学习ID> <stageID> [--plan-id <方案ID>] 按需回看。\n"
        "页面只展示目标与学习路线、本阶段学习和资料。--result-file 只写给用户阅读的知识、例子、答疑和练习提示。\n"
        "核对过程、工具执行、证据边界、未验证声明及交接安排写 --details-file；接续重点写 --handoff-file，不能混进教学正文。\n"
        "使用 --unit-file 时维护当前稳定单元，不把整阶段反复复制到笔记。只有兼容旧稿时才用 --result-file：同阶段的 --result-file 是一份持续修订的学习稿，不是本轮回答或回答历史。先读当前 learningLesson，保留仍正确的知识，纠正旧误解，把新增答疑整合到相应主题；完整回写整份学习稿。\n"
        "学习稿用 Markdown：一个主题标题，随后 ## 本节要点（少量可独立理解的要点），再按知识主题用 ## 分节，按需加入例子、公式、表格与练习。只写已经讲过的内容，不提前编造未学习内容，也不把阅读等同于掌握。\n"
        "要点用自己的话串起概念与适用边界；具体推理留在对应主题里，不能只列关键词、机械截句或压掉必要说明。不写轮次、时间、用户原话或对话口吻，不重复安排理由。资料集中在末尾 ## 资料，用 [清晰标题](完整URL)，页面会放到资料卡片区。\n"
        "只有确实需要用户采纳的进度或成果变化才传 --progress、--next-step、--learning-outcome；建议自动绑定当前目标、方案与阶段，切换后旧建议失效。\n"
        "每轮结束回写一句话 summary，handoff 只保留学习目标、当前节、真正掌握的能力、未解问题和下一步。\n"
        "回写前重新 context 取得最新 revision；report 传 --expected-revision。方案绑定当前目标与时间，符合预算后自动生效；掌握结论仍由实际练习支持，用户确认后推进。\n"
        "方案有效性由你作为教练负责：诊断起点、核查资料、用短试学和迁移练习验证并调整。用户只判断目标与投入是否合适，不要求用户审核教学设计。\n"
        "按能力选择验证方式：概念让用户用自己的话解释区别并举例，操作让用户实际完成并查看结果，方案让用户说明取舍。\n"
        "讲解里的关键外部事实附已核对的来源链接（写出完整 URL）和章节；PDF 能确认页码时标页码，无法定位时明确说明，不编造引用。\n"
    )
    if state["requestedAction"] == "practice":
        if not state["duePractice"]:
            return prefix + "当前没有到期的复习题，请回次 Try 查看最新状态。"
        specific = (
            "当前任务：复习 duePractice。先只给 question，不展示原回答、错因或答案，等用户实际答完再点评。"
            "仅用本次真实回答或操作结果按 practiceFormat 回写 --practice-file <JSON路径>。"
            "答对结束此题，仍有差距则两天后再练。只处理这道复习题；阶段掌握仍走阶段自测与用户确认。"
        )
    elif not state["configReady"]:
        specific = "还没有明确的学习目标、时间预算或截止日期。先帮助用户澄清，再让用户在 D板保存目标；暂不生成整套课程。"
    elif state["finished"]:
        specific = "这一轮已由用户结束。只回看真实成果和剩余问题，不重开课程、不新增计划或自测。"
    elif state["daysLeft"] < 0 and state["requestedAction"] != "review":
        specific = "学习已到期。先复盘已学会与待验证的部分，并建议延期或调整目标；用户更新截止日期后才继续安排或授课。复盘通过 report --review-file <路径> 回写，不自动完成学习。"
    elif state["requestedAction"] == "plan":
        specific = (
            "当前任务：制定或调整方案。先澄清成功标准及起点，再按 planFormat 提出少量阶段，解释顺序和估时。"
            "总估时不得超过 availableMinutes；资料必须可靠，不编造链接。已有方案/笔记只作继承依据，不重新教已掌握内容。\n"
            "每节写成可执行的一次或几次短学习，说明讲什么、参考哪里、动手做什么、如何自测。截止日前安排必要的复习与综合练习，估时包含练习和复盘。\n"
            "goalSummary 和阶段 summary/title 是供页面展示的简短概括，不塞入安排理由、完整资源和测试细则；详细边界、来源及依据保留在对应字段。\n"
            "把方案 JSON 写入本机临时文件，通过 report --plan-file <JSON路径> 回写。工具校验目标版本和时间预算，符合时直接开始试学，无需用户在D板额外确认方案。重读context后可从当前阶段开始简短讲解与练习；不用把整份方案贴到对话里。不能凭计划生效认定已经学会。\n"
            "若历史摘要或旧方案仍写着等待确认，以最新learningWorkflow为准；清理摘要中过时的等待状态。"
        )
    elif state["requestedAction"] == "review":
        specific = (
            "当前任务：目标验收或到期复盘。把原目标逐项对照真实回答、练习证据和已确认成果。"
            "区分已掌握、待验证和未学会；证据不足时先要求一个综合练习，不能宣布目标达成。"
            "说明剩余差距、时间是否合理及延期/缩减目标的建议。把清晰的复盘写入文件，用 report --review-file <路径> 回写；由用户决定结束或调整。"
        )
    elif state["requestedAction"] == "check":
        specific = (
            "当前任务：本节自测。只检查 currentStage 的完成标准。没有真实答案时，先给一两道应用题或小练习，等待用户回答。"
            "有答案后逐项反馈错误和原因。只有实际回答/结果满足标准才能 verdict=ready；否则 needs_practice 或 insufficient_evidence。\n"
            "按 checkFormat 写 JSON，用 report --check-file <路径> 回写。evidenceText 保存真实回答或操作结果；noteIDs 只能指向实际相关笔记。"
            "如果真实回答暴露了值得回头验证的薄弱点，在 needs_practice 时附上一个 practice，给出错因和换场景后的题目；没有真实作答时省略。"
            "不能自己编写用户答案作为证据。用户会看到依据并确认本节，AI 不自行推进或勾选完成。"
        )
    elif not state["planCurrent"] or state["daysLeft"] < 0:
        specific = "目标已变化、方案未生效或学习已到期。先按当前目标调整方案或复盘，不使用过期安排。"
    else:
        stage = state["currentStage"]
        specific = (
            "当前任务：学习 currentStage。先回顾用户已有理解，先按 learningPreferences 从有来源的现象或结果进入，讲清指标、原因、边界与判断。每次讲一个完整单元；不逐轮出题。"
            "结合 currentUnit、relevantTopics/relevantNotes 与近期反馈调整解释；先说清对象和动作再用术语。阶段末或用户主动复习/复测时才集中检查。"
            "讲解、练习提示单独写文件，用 report --result-file <路径> --lesson-stage " + stage["id"] +
            " 回写。根据最新回答继续；不要把整套课程一次倾倒给用户，也不要自行标记这一节完成。"
        )
    return prefix + specific + "\n反馈命令：" + command + " report " + item["id"] + " --expected-revision <最新revision> --summary '本轮一句话概括' --handoff-file <接续摘要> [本阶段对应文件参数]"


def activate_plan(item, proposal):
    """Retain every real assessment; coverage is evaluated against current standards."""
    old = item.get("learningPlan") or {}
    previous = {stage["id"]: stage for stage in old.get("stages", [])}
    checks = item.get("learningStageChecks") or []
    for check in checks:
        before = previous.get(check["stageID"])
        if (check.get("standards") is None and before and check.get("planID") == old.get("id")
                and check.get("configRevision") == old.get("configRevision")):
            check["standards"] = {key: before[key] for key in ("objective", "practice", "check")}
    current_id = item.get("currentLearningStageID")
    item["learningPlan"] = proposal
    item.pop("learningPlanProposal", None)
    item.pop("learningPlanFeedback", None)
    item["learningStageChecks"] = checks
    item.pop("learningLesson", None)
    item.pop("learningReview", None)
    verified = {row["stageID"] for row in checks if row.get("confirmedAt") and check_current(item, row)}
    item["currentLearningStageID"] = (current_id if any(row["id"] == current_id for row in proposal["stages"])
        else next((row["id"] for row in proposal["stages"] if row["id"] not in verified), proposal["stages"][-1]["id"]))


def apply_report(item, plan_file=None, check_file=None, review=None, lesson_stage=None, result=None, practice_file=None):
    state = workflow(item)
    phases = sum(value is not None for value in (plan_file, check_file, review, lesson_stage, practice_file))
    if not phases:
        return
    if phases > 1:
        raise ValueError("一次反馈只提交方案、讲解、自测、复习答题或复盘中的一种")
    if not state["configReady"]:
        raise ValueError("请先在D板明确学习目标、时间预算与截止日期")
    if state["finished"] and (plan_file is not None or check_file is not None or lesson_stage):
        raise ValueError("本轮已结束，不能由AI重开学习")
    config = item["learningConfig"]
    plan = item.get("learningPlan") or {}
    if plan_file is not None:
        if not isinstance(plan_file, dict):
            raise ValueError("学习方案必须是JSON对象")
        for field in ("target", "startingPoint", "rationale"):
            if not isinstance(plan_file.get(field), str) or not plan_file[field].strip():
                raise ValueError("方案需要目标理解、起点判断和安排理由")
        stages = plan_file.get("stages")
        if not isinstance(stages, list) or not stages:
            raise ValueError("学习方案需要具体阶段")
        ids = set()
        normalized = []
        for stage in stages:
            if not isinstance(stage, dict) or not isinstance(stage.get("id"), str) or stage["id"] in ids:
                raise ValueError("学习阶段ID必须唯一")
            ids.add(stage["id"])
            for field in ("title", "objective", "practice", "check"):
                if not isinstance(stage.get(field), str) or not stage[field].strip():
                    raise ValueError("每节需要标题、目标、练习和可验证的完成标准")
            if type(stage.get("estimatedMinutes")) is not int or stage["estimatedMinutes"] <= 0:
                raise ValueError("每节需要合理的分钟估时")
            if not isinstance(stage.get("resources", ""), str):
                raise ValueError("学习资料格式不正确")
            if stage.get("summary") is not None and (not isinstance(stage["summary"], str) or not stage["summary"].strip()):
                raise ValueError("阶段概括需要非空文字")
            normalized.append({key: stage.get(key, "") for key in ("id", "title", "objective", "resources", "practice", "check", "estimatedMinutes")})
            if stage.get("summary") is not None:
                normalized[-1]["summary"] = stage["summary"].strip()
        if plan_file.get("goalSummary") is not None and (not isinstance(plan_file["goalSummary"], str) or not plan_file["goalSummary"].strip()):
            raise ValueError("页面学习目标需要非空的简短概括")
        proposal = {
            "id": str(uuid.uuid4()), "configRevision": config["revision"],
            "target": plan_file["target"], "startingPoint": plan_file["startingPoint"],
            "rationale": plan_file["rationale"], "stages": normalized}
        if plan_file.get("goalSummary") is not None:
            proposal["goalSummary"] = plan_file["goalSummary"].strip()
        if state["daysLeft"] >= 0 and sum(stage["estimatedMinutes"] for stage in normalized) <= state["availableMinutes"]:
            activate_plan(item, proposal)
        else:
            item["learningPlanProposal"] = proposal
    if lesson_stage is not None:
        if not state["planCurrent"] or state["daysLeft"] < 0 or not result or not any(row["id"] == lesson_stage for row in plan.get("stages", [])):
            raise ValueError("讲解需要当前当前方案的有效阶段和正文，且尚未到期")
        lesson = {"stageID": lesson_stage, "planID": plan["id"], "body": result}
        lessons = item.get("learningLessons") or ([item["learningLesson"]] if item.get("learningLesson") else [])
        item["learningLessons"] = [row for row in lessons if not (row["stageID"] == lesson_stage and row["planID"] == plan["id"])] + [lesson]
        item["learningLesson"] = lesson
    if check_file is not None:
        if not state["planCurrent"] or not isinstance(check_file, dict):
            raise ValueError("自测需要当前生效方案")
        stage_id = check_file.get("stageID")
        if not any(row["id"] == stage_id for row in plan.get("stages", [])):
            raise ValueError("自测对应的学习阶段不存在")
        verdict = check_file.get("verdict")
        if verdict not in ("ready", "needs_practice", "insufficient_evidence"):
            raise ValueError("自测结论格式不正确")
        for field in ("summary", "evidenceText", "outcome"):
            if not isinstance(check_file.get(field, ""), str):
                raise ValueError("自测说明、依据或成果格式不正确")
        if not check_file.get("summary", "").strip():
            raise ValueError("自测需要一句话说明")
        gaps = check_file.get("gaps", [])
        if not isinstance(gaps, list) or not all(isinstance(row, str) for row in gaps):
            raise ValueError("自测未解问题格式不正确")
        relevant = notes(item)
        note_ids = check_file.get("noteIDs", [row["id"] for row in relevant if row.get("learningStageID") == stage_id])
        if not isinstance(note_ids, list) or any(not isinstance(key, str) or not any(row["id"] == key for row in relevant) for key in note_ids):
            raise ValueError("自测关联的笔记不存在或已删除")
        evidence_versions = {row["id"]: row["updatedAt"] for row in relevant if row["id"] in note_ids}
        learner_notes = [row for row in relevant if row["id"] in note_ids and row.get("origin", "learner") == "learner"]
        has_evidence = check_file.get("evidenceText", "").strip() or any(row["body"].strip() for row in learner_notes)
        if verdict == "ready" and (not has_evidence or not check_file.get("outcome", "").strip()):
            raise ValueError("判定掌握需要真实回答/练习依据及具体成果")
        check = {"stageID": stage_id, "planID": plan["id"], "configRevision": config["revision"],
                 "verdict": verdict, "summary": check_file["summary"], "gaps": gaps,
                 "evidenceText": check_file.get("evidenceText", "").strip() or "\n\n".join(row["body"] for row in learner_notes), "outcome": check_file.get("outcome", ""),
                 "evidenceVersions": evidence_versions,
                 "evidenceBodies": {row["id"]: row["body"] for row in relevant if row["id"] in note_ids},
                 "standards": {key: next(row for row in plan["stages"] if row["id"] == stage_id)[key]
                               for key in ("objective", "practice", "check")}}
        checks = item.get("learningStageChecks") or []
        previous = next((row for row in checks if row["stageID"] == stage_id), None)
        practice = check_file.get("practice")
        if practice is not None:
            if (verdict != "needs_practice" or not check_file.get("evidenceText", "").strip()
                    or not isinstance(practice, dict)
                    or any(not isinstance(practice.get(key), str) or not practice[key].strip() for key in ("gap", "question"))):
                raise ValueError("复习题需要真实作答、错因和一道新的练习题")
        previous_practice = previous.get("practice") if previous and check_current(item, previous) else None
        # shortcut: one pending question per stage, expand when learners need several distinct gaps tracked together.
        if previous_practice and (practice is None or not previous_practice.get("completedAt")):
            check["practice"] = previous_practice
        elif practice is not None:
            check["practice"] = {"id": str(uuid.uuid4()), "gap": practice["gap"].strip(),
                                 "question": practice["question"].strip(), "originalAnswer": check["evidenceText"],
                                 "dueAt": next_practice_date()}
        if previous:
            item["learningCheckHistory"] = (item.get("learningCheckHistory") or []) + [previous]
        item["learningStageChecks"] = [row for row in checks if row["stageID"] != stage_id] + [check]
        item.pop("learningReview", None)
    if practice_file is not None:
        check = due_practice(item)
        if (not check or not isinstance(practice_file, dict) or practice_file.get("id") != check["practice"]["id"]):
            raise ValueError("复习题已变化或尚未到期，请重新读取")
        if (type(practice_file.get("passed")) is not bool
                or any(not isinstance(practice_file.get(key), str) or not practice_file[key].strip() for key in ("answer", "feedback"))):
            raise ValueError("复习反馈需要真实回答、是否答对和具体理由")
        next_question = practice_file.get("nextQuestion")
        if not practice_file["passed"] and (not isinstance(next_question, str) or not next_question.strip()):
            raise ValueError("复习未通过时需要一道换场景的题")
        practice = check["practice"]
        practice["attempts"] = (practice.get("attempts") or []) + [{
            "question": practice["question"], "answer": practice_file["answer"].strip(),
            "feedback": practice_file["feedback"].strip(), "passed": practice_file["passed"], "at": time.time()}]
        practice.update(lastAnswer=practice_file["answer"].strip(), feedback=practice_file["feedback"].strip())
        if practice_file["passed"]:
            practice["completedAt"] = time.time()
        else:
            practice["question"] = next_question.strip()
            practice["dueAt"] = next_practice_date()
    if review is not None:
        if not review.strip():
            raise ValueError("复盘内容不能为空")
        item["learningReview"] = review
        item["learningReviewConfigRevision"] = config["revision"]
        item["learningReviewPlanID"] = plan.get("id")
        item["learningReviewEvidenceVersions"] = {row["id"]: row["updatedAt"] for row in notes(item)}
