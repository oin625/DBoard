import XCTest
import AppKit
@testable import DBoard

final class TryLearningWorkflowTests: XCTestCase {
    func testGoalDraftPersistsAndHandoffNamesThePlanningAction() throws {
        try isolated { store in
            var config = TryLearningConfig.empty
            config.goal = "独立排查Redis内存问题"
            config.baseline = "会基础命令"
            let text = String(data: try JSONEncoder().encode(config), encoding: .utf8)!
            store.editCapture(.digestion, field: "learningConfig", value: text, generation: 0)
            XCTAssertTrue(store.flush())
            let fresh = TryStore(url: store.url, watching: false)
            XCTAssertEqual(fresh.capture(.digestion).learningConfig?.goal, config.goal)
            let id = try XCTUnwrap(fresh.submitCapture(.digestion))
            XCTAssertEqual(fresh.entry(id)?.learningConfig?.revision, 1)
            XCTAssertEqual(fresh.entry(id)?.learningAction, "plan")
            XCTAssertTrue(fresh.handoff(id)?.contains("--learning-action plan") == true)
            let context = try cli(fresh, ["context", id, "--learning-action", "plan"])
            XCTAssertEqual(context.0, 0)
            let item = try XCTUnwrap(context.1["item"] as? [String: Any])
            XCTAssertEqual((item["learningWorkflow"] as? [String: Any])?["requestedAction"] as? String, "plan")
        }
    }
    func testPlanStartsTrialAutomaticallyAndOverBudgetPlanCannotStart() throws {
        try isolated { store in
            let id = try topic(store)
            var oversized = plan()
            var stages = oversized["stages"] as! [[String: Any]]
            stages[0]["estimatedMinutes"] = 100000
            oversized["stages"] = stages
            let blocked = try jsonFile(store, name: "oversized", object: oversized)
            XCTAssertEqual(try report(store, id, ["--plan-file", blocked.path]).0, 0)
            store.reload()
            XCTAssertNotNil(store.entry(id)?.learningPlanProposal)
            XCTAssertNil(store.entry(id)?.learningPlan)
            let lesson = try textFile(store, name: "lesson", text: "先解释内存，再做小练习")
            let before = try Data(contentsOf: store.url)
            XCTAssertNotEqual(try report(store, id, ["--result-file", lesson.path, "--lesson-stage", "S001"]).0, 0)
            XCTAssertEqual(try Data(contentsOf: store.url), before)
            let file = try jsonFile(store, name: "plan", object: plan())
            XCTAssertEqual(try report(store, id, ["--plan-file", file.path]).0, 0)
            store.reload()
            XCTAssertNil(store.entry(id)?.learningPlanProposal)
            XCTAssertEqual(store.entry(id)?.learningAction, "lesson")
            XCTAssertEqual(store.entry(id)?.currentLearningStage?.id, "S001")
            XCTAssertTrue(store.entry(id)?.verifiedLearningStages.isEmpty == true)
            XCTAssertEqual(store.entry(id)?.learningGoalLabel, "学会排查内存并完成恢复")
            XCTAssertEqual(try report(store, id, ["--result-file", lesson.path, "--lesson-stage", "S001"]).0, 0)
            store.reload()
            XCTAssertEqual(store.entry(id)?.learningLesson?.body, "先解释内存，再做小练习")
        }
    }
    func testActualEvidenceRequiresUserConfirmationAndNoteChangesInvalidateOldChecks() throws {
        try isolated { store in
            let id = try topic(store)
            try acceptPlan(store, id)
            XCTAssertTrue(store.prepareLearningStageNote(id))
            store.editLearningNote(id, noteID: nil, field: "body", value: "我比较了内存淘汰策略，附上实验观察", generation: 0)
            let noteID = try XCTUnwrap(store.saveLearningNote(id))
            XCTAssertEqual(store.entry(id)?.learningNotes.first?.learningStageID, "S001")
            let checkFile = try jsonFile(store, name: "check", object: check(stage: "S001", noteID: noteID))
            XCTAssertEqual(try report(store, id, ["--check-file", checkFile.path]).0, 0)
            store.reload()
            XCTAssertTrue(store.entry(id)?.verifiedLearningStages.isEmpty == true)
            XCTAssertTrue(store.confirmLearningStage(id, stageID: "S001"))
            XCTAssertEqual(store.entry(id)?.verifiedLearningStages, ["S001"])
            XCTAssertEqual(store.entry(id)?.currentLearningStage?.id, "S002")
            store.editLearningNote(id, noteID: noteID, field: "body", value: "修改了实验结论，原答案有错误", generation: store.learningGeneration(id))
            XCTAssertTrue(store.flush())
            XCTAssertTrue(store.entry(id)?.verifiedLearningStages.isEmpty == true)
            XCTAssertFalse(store.confirmLearningStage(id, stageID: "S001"))
            XCTAssertFalse(store.finishLearning(id, reached: true))
            XCTAssertNotNil(store.entry(id)?.learningStageChecks?.first)
        }
    }
    @MainActor
    func testDuePracticeCopiesQuestionHandoffAndRecordsAnswersWithoutAdvancingStage() throws {
        _ = NSApplication.shared
        let board = NSPasteboard.general
        let old = board.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        defer {
            board.clearContents()
            let items = old.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            _ = board.writeObjects(items)
        }
        try isolated { store in
            let id = try topic(store)
            try acceptPlan(store, id)
            XCTAssertNil(store.entry(id)?.pendingLearningPractice)
            var assessment = check(stage: "S001", noteID: nil)
            assessment["verdict"] = "needs_practice"
            assessment["evidenceText"] = "我选了 volatile-lru，但这个场景没有带过期时间的键。"
            assessment["practice"] = ["gap": "没有区分淘汰范围", "question": "缓存键都没有 TTL，内存满时怎样选策略？"]
            let file = try jsonFile(store, name: "practice-check", object: assessment)
            XCTAssertEqual(try report(store, id, ["--check-file", file.path]).0, 0)
            store.reload()
            let practice = try XCTUnwrap(store.entry(id)?.pendingLearningPractice)
            XCTAssertEqual(practice.originalAnswer, assessment["evidenceText"] as? String)
            let dueDay = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: Date())))
            XCTAssertEqual(Date(timeIntervalSince1970: practice.dueAt), dueDay)

            let wrong = try jsonFile(store, name: "wrong-answer", object: ["id": practice.id, "passed": false,
                "answer": "还是选 volatile-lru", "feedback": "没有带过期时间的键可淘汰",
                "nextQuestion": "当带过期时间的键用完时，怎样保证缓存仍可淘汰？"])
            let before = try Data(contentsOf: store.url)
            XCTAssertNotEqual(try report(store, id, ["--practice-file", wrong.path]).0, 0)
            XCTAssertEqual(try Data(contentsOf: store.url), before)
            XCTAssertTrue(store.update(id) { $0.learningStageChecks?[0].practice?.dueAt = 1 })

            let detail = TryDetailWindowController(store: store, activates: false)
            detail.show(id); settle()
            defer { detail.close() }
            try click("try-learning-practice", XCTUnwrap(detail.window))
            XCTAssertTrue(board.string(forType: .string)?.contains("--learning-action practice") == true)
            let context = try cli(store, ["context", id, "--learning-action", "practice"])
            let item = try XCTUnwrap(context.1["item"] as? [String: Any])
            let workflow = try XCTUnwrap(item["learningWorkflow"] as? [String: Any])
            XCTAssertEqual((workflow["duePractice"] as? [String: Any])?["question"] as? String, practice.question)

            XCTAssertEqual(try report(store, id, ["--practice-file", wrong.path]).0, 0)
            store.reload()
            XCTAssertEqual(store.entry(id)?.pendingLearningPractice?.dueAt, practice.dueAt)
            XCTAssertEqual(store.entry(id)?.pendingLearningPractice?.lastAnswer, "还是选 volatile-lru")
            XCTAssertEqual(store.entry(id)?.pendingLearningPractice?.question, "当带过期时间的键用完时，怎样保证缓存仍可淘汰？")
            XCTAssertTrue(store.update(id) { $0.learningStageChecks?[0].practice?.dueAt = 1 })
            let correct = try jsonFile(store, name: "correct-answer", object: ["id": practice.id, "passed": true,
                "answer": "选 allkeys-lru，允许所有键参与淘汰", "feedback": "正确说明了淘汰范围"])
            XCTAssertEqual(try report(store, id, ["--practice-file", correct.path]).0, 0)
            store.reload()
            XCTAssertNil(store.entry(id)?.pendingLearningPractice)
            XCTAssertEqual(store.entry(id)?.learningStageChecks?.first?.practice?.feedback, "正确说明了淘汰范围")
            XCTAssertTrue(store.entry(id)?.verifiedLearningStages.isEmpty == true)
            XCTAssertEqual(store.entry(id)?.currentLearningStage?.id, "S001")
        }
    }
    func testChangedGoalOrTimeRejectsOldPlanAndAdjustmentKeepsValidLearnedStages() throws {
        try isolated { store in
            let id = try topic(store)
            try acceptPlan(store, id)
            let first = try jsonFile(store, name: "first-check", object: check(stage: "S001", noteID: nil))
            XCTAssertEqual(try report(store, id, ["--check-file", first.path]).0, 0)
            store.reload()
            XCTAssertTrue(store.confirmLearningStage(id, stageID: "S001"))
            let stale = try jsonFile(store, name: "stale-plan", object: plan())
            XCTAssertEqual(try report(store, id, ["--plan-file", stale.path]).0, 0)
            store.reload()
            var config = store.entry(id)!.learningConfig!
            config.deadline += 7 * 86400
            store.editLearningConfigDraft(id, config: config)
            XCTAssertTrue(store.saveLearningConfig(id))
            XCTAssertFalse(store.acceptLearningPlan(id))
            XCTAssertFalse(store.entry(id)?.learningPlanCurrent == true)
            var adjusted = plan()
            var stages = adjusted["stages"] as! [[String: Any]]
            stages[0]["estimatedMinutes"] = 40
            adjusted["stages"] = stages
            store.edit(id, field: "learningPlanFeedback", value: "多做恢复实验，讲解短一点")
            XCTAssertTrue(store.flush())
            let context = try cli(store, ["context", id, "--learning-action", "plan"])
            XCTAssertEqual((context.1["item"] as? [String: Any])?["learningPlanFeedback"] as? String, "多做恢复实验，讲解短一点")
            let file = try jsonFile(store, name: "new-plan", object: adjusted)
            XCTAssertEqual(try report(store, id, ["--plan-file", file.path]).0, 0)
            store.reload()
            XCTAssertTrue(store.entry(id)?.learningPlanCurrent == true)
            XCTAssertEqual(store.entry(id)?.verifiedLearningStages, ["S001"])
            XCTAssertEqual(store.entry(id)?.currentLearningStage?.id, "S002")
            XCTAssertNil(store.entry(id)?.learningPlanFeedback)
        }
    }
    func testDeadlineRequiresReviewAndNeverAutomaticallyCompletesLearning() throws {
        try isolated { store in
            let id = try topic(store)
            try acceptPlan(store, id)
            XCTAssertTrue(store.update(id) { $0.learningConfig?.deadline = Date().addingTimeInterval(-2 * 86400).timeIntervalSince1970 })
            XCTAssertEqual(store.entry(id)?.learningAction, "review")
            XCTAssertNil(store.entry(id)?.learningFinishedAt)
            XCTAssertFalse(store.prepareLearningStageNote(id))
            XCTAssertFalse(store.finishLearning(id, reached: false))
            let review = try textFile(store, name: "review", text: "尚未完成目标；已经理解基本概念，练习还没有完成。")
            XCTAssertEqual(try report(store, id, ["--review-file", review.path]).0, 0)
            store.reload()
            XCTAssertTrue(store.entry(id)?.learningReviewCurrent == true)
            XCTAssertTrue(store.finishLearning(id, reached: false))
            XCTAssertEqual(store.entry(id)?.learningGoalReached, false)
            XCTAssertNotNil(store.entry(id)?.learningFinishedAt)
        }
    }
    func testCompleteGoalNeedsCurrentReviewAndAIStillCannotFinishIt() throws {
        try isolated { store in
            let id = try topic(store)
            try acceptPlan(store, id)
            for stage in ["S001", "S002"] {
                let file = try jsonFile(store, name: stage, object: check(stage: stage, noteID: nil))
                XCTAssertEqual(try report(store, id, ["--check-file", file.path]).0, 0)
                store.reload()
                XCTAssertTrue(store.confirmLearningStage(id, stageID: stage))
            }
            XCTAssertEqual(store.entry(id)?.learningAction, "review")
            XCTAssertFalse(store.finishLearning(id, reached: true))
            let file = try textFile(store, name: "final-review", text: "结合真实回答和恢复实验，逐项对照目标已满足。")
            XCTAssertEqual(try report(store, id, ["--review-file", file.path]).0, 0)
            store.reload()
            XCTAssertNil(store.entry(id)?.learningFinishedAt)
            XCTAssertTrue(store.finishLearning(id, reached: true))
            let before = try Data(contentsOf: store.url)
            let newPlan = try jsonFile(store, name: "reopen", object: plan())
            XCTAssertNotEqual(try report(store, id, ["--plan-file", newPlan.path]).0, 0)
            XCTAssertEqual(try Data(contentsOf: store.url), before)
        }
    }
    func testSwitchingLessonsPreservesDraftAndContextUsesTheMatchingNotes() throws {
        try isolated { store in
            let id = try topic(store)
            try acceptPlan(store, id)
            XCTAssertTrue(store.prepareLearningStageNote(id, stageID: "S001"))
            store.editLearningNote(id, noteID: nil, field: "body", value: "第一节尚未写完的理解", generation: store.learningGeneration(id))
            XCTAssertTrue(store.prepareLearningStageNote(id, stageID: "S002"))
            let first = try XCTUnwrap(store.entry(id)?.learningNotes.first)
            XCTAssertEqual(first.body, "第一节尚未写完的理解")
            XCTAssertEqual(first.learningStageID, "S001")
            XCTAssertEqual(store.entry(id)?.learningDraft.learningStageID, "S002")
            store.editLearningNote(id, noteID: nil, field: "body", value: "第二节的恢复观察", generation: store.learningGeneration(id))
            let second = try XCTUnwrap(store.saveLearningNote(id))
            store.selectLearningNote(id, noteID: first.id)
            XCTAssertTrue(store.flush())
            let result = try cli(store, ["context", id])
            let item = try XCTUnwrap(result.1["item"] as? [String: Any])
            XCTAssertEqual((item["currentNote"] as? [String: Any])?["id"] as? String, first.id)
            XCTAssertEqual((item["currentStageNote"] as? [String: Any])?["id"] as? String, second)
            XCTAssertNil(item["notes"])
            XCTAssertTrue(store.prepareLearningStageNote(id, stageID: "S001"))
            XCTAssertEqual(store.entry(id)?.selectedLearningNoteID, first.id)
            XCTAssertEqual(store.entry(id)?.learningNotes.count, 2)
        }
    }
    func testLessonsAreRetainedSeparatelyAndMixedPhaseReportCannotWrite() throws {
        try isolated { store in
            let id = try topic(store)
            try acceptPlan(store, id)
            let first = try textFile(store, name: "first-lesson", text: "第一节的例子与练习")
            XCTAssertEqual(try report(store, id, ["--result-file", first.path, "--lesson-stage", "S001"]).0, 0)
            store.reload()
            XCTAssertTrue(store.prepareLearningStageNote(id, stageID: "S002"))
            let second = try textFile(store, name: "second-lesson", text: "第二节的恢复实验")
            XCTAssertEqual(try report(store, id, ["--result-file", second.path, "--lesson-stage", "S002"]).0, 0)
            store.reload()
            XCTAssertEqual(store.entry(id)?.learningLessonForStage("S001")?.body, "第一节的例子与练习")
            XCTAssertEqual(store.entry(id)?.learningLessonForStage("S002")?.body, "第二节的恢复实验")
            let oldLesson = try cli(store, ["lesson", id, "S001"])
            XCTAssertEqual((oldLesson.1["lesson"] as? [String: Any])?["body"] as? String, "第一节的例子与练习")
            let context = try cli(store, ["context", id])
            let item = try XCTUnwrap(context.1["item"] as? [String: Any])
            XCTAssertNil(item["learningLessons"])
            XCTAssertEqual((item["learningLesson"] as? [String: Any])?["stageID"] as? String, "S002")
            let newPlan = try jsonFile(store, name: "mixed-plan", object: plan())
            let before = try Data(contentsOf: store.url)
            XCTAssertNotEqual(try report(store, id, ["--plan-file", newPlan.path, "--result-file", second.path, "--lesson-stage", "S002"]).0, 0)
            XCTAssertEqual(try Data(contentsOf: store.url), before)
        }
    }
    func testNewConfirmationInvalidatesReviewAndUserCanFinishAnIncompleteRound() throws {
        try isolated { store in
            let id = try topic(store)
            try acceptPlan(store, id)
            let checkFile = try jsonFile(store, name: "early-check", object: check(stage: "S001", noteID: nil))
            XCTAssertEqual(try report(store, id, ["--check-file", checkFile.path]).0, 0)
            store.reload()
            let review = try textFile(store, name: "early-review", text: "只掌握第一节，第二节尚未开始。")
            XCTAssertEqual(try report(store, id, ["--review-file", review.path]).0, 0)
            store.reload()
            XCTAssertTrue(store.entry(id)?.learningReviewCurrent == true)
            XCTAssertTrue(store.confirmLearningStage(id, stageID: "S001"))
            XCTAssertFalse(store.entry(id)?.learningReviewCurrent == true)
            XCTAssertFalse(store.finishLearning(id, reached: false))
            XCTAssertEqual(try report(store, id, ["--review-file", review.path]).0, 0)
            store.reload()
            XCTAssertTrue(store.finishLearning(id, reached: false))
            XCTAssertEqual(store.entry(id)?.status, .done)
            XCTAssertEqual(store.entry(id)?.learningGoalReached, false)
            let context = try cli(store, ["context", id])
            XCTAssertEqual(context.1["action"] as? String, "wait_for_user")
        }
    }
    @MainActor
    func testActualGoalEntryCopiesPlanCommandAndAcceptedPlanOpensTheStageNotebook() throws {
        _ = NSApplication.shared
        let board = NSPasteboard.general
        let old = board.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        defer {
            board.clearContents()
            let items = old.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            _ = board.writeObjects(items)
        }
        try isolated { store in
            let capture = TryCaptureWindowController(store: store, activates: false)
            capture.show(.digestion); settle()
            let window = try XCTUnwrap(capture.window)
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
            editor.insertText("独立排查Redis内存问题", replacementRange: editor.selectedRange())
            settle()
            XCTAssertEqual(store.capture(.digestion).learningConfig?.goal, "独立排查Redis内存问题")
            try click("try-capture-save", window)
            XCTAssertNil(capture.window)
            let id = try XCTUnwrap(store.document.entries.first?.id)
            XCTAssertTrue(board.string(forType: .string)?.contains("--learning-action plan") == true)
            let planFile = try jsonFile(store, name: "ui-plan", object: plan())
            XCTAssertEqual(try report(store, id, ["--plan-file", planFile.path]).0, 0)
            store.reload()
            let detail = TryDetailWindowController(store: store, activates: false)
            detail.show(id); settle()
            defer { detail.close() }
            let panel = try XCTUnwrap(detail.window)
            XCTAssertFalse(descendants(panel.contentView!).compactMap { $0 as? DemandKeyboardActionView }.contains { $0.keyboardIdentifier == "try-learning-plan-accept" })
            XCTAssertTrue(store.entry(id)?.learningPlanCurrent == true)
            XCTAssertEqual(store.entry(id)?.currentLearningStage?.id, "S001")
            try click("try-stage-note", panel)
            let note = try XCTUnwrap(descendants(panel.contentView!).compactMap { $0 as? TryNoteTextView }.first)
            XCTAssertTrue(panel.firstResponder === note)
            note.insertText("我的理解与实验记录", replacementRange: note.selectedRange()); settle()
            XCTAssertTrue(store.flush())
            XCTAssertTrue(panel.firstResponder === note)
            XCTAssertEqual(store.entry(id)?.learningNotes.first?.learningStageID, "S001")
            XCTAssertTrue(store.entry(id)?.learningNotes.first?.body.contains("实验") == true)
            if let directory = ProcessInfo.processInfo.environment["DBOARD_LEARNING_WORKFLOW_SNAPSHOTS"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                detail.close(); settle(); detail.show(id); settle()
                let view = try XCTUnwrap(detail.window?.contentView)
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory + "/workflow.png"))
            }
        }
    }
    func testLessonReportHasOneBodyAndSuggestionsFollowTheCurrentStage() throws {
        try isolated { store in
            let id = try topic(store)
            try acceptPlan(store, id)
            let lesson = try textFile(store, name: "clean-lesson", text: "内存占用包括数据与运行开销。")
            let detail = try textFile(store, name: "audit", text: "资料核对与接续记录，只留在本地历史。")
            XCTAssertEqual(try report(store, id, ["--result-file", lesson.path, "--lesson-stage", "S001",
                "--details-file", detail.path, "--progress", "正在理解内存占用"]).0, 0)
            store.reload()
            let current = try XCTUnwrap(store.entry(id))
            XCTAssertEqual(current.learningReadingBody, "内存占用包括数据与运行开销。")
            XCTAssertTrue(current.aiResult.isEmpty)
            XCTAssertTrue(current.learningSuggestionCurrent)
            XCTAssertEqual(current.reports.last?.details, "资料核对与接续记录，只留在本地历史。")
            XCTAssertTrue(store.update(id) { $0.currentLearningStageID = "S002" })
            XCTAssertFalse(store.entry(id)?.learningSuggestionCurrent ?? true)
            XCTAssertFalse(store.acceptLearningSuggestion(id))
            let context = try cli(store, ["context", id])
            let item = try XCTUnwrap(context.1["item"] as? [String: Any])
            XCTAssertNil(item["learningSuggestion"])
            let rules = context.1["feedback_instructions"] as? String ?? ""
            XCTAssertTrue(rules.contains("--result-file 只写给用户阅读"))
            XCTAssertTrue(rules.contains("--details-file"))
            XCTAssertTrue(rules.contains("持续修订的学习稿"))
            XCTAssertTrue(rules.contains("完整回写整份学习稿"))
            XCTAssertTrue(rules.contains("## 本节要点"))
        }
    }

    @MainActor
    func testLearningOverviewHasOneReadingEntryAndReferencesStayCompact() throws {
        _ = NSApplication.shared
        try isolated { store in
            let id = try topic(store)
            try acceptPlan(store, id)
            let lesson = try textFile(store, name: "reading", text: """
            # 理解运行内存
            ## 本节要点
            - 权重占用需要结合参数量与精度。
            - 运行还需要缓存和计算空间。
            ## 权重如何估算
            基础数据量 ≈ 参数数量 × 每参数字节数。

            | 权重版本 | 基础数据量 |
            | --- | --- |
            | FP16 | 14GB |
            | 4bit | 3.5GB |
            ## 练习与边界
            为什么权重能放下，还不代表模型一定能运行？
            """)
            XCTAssertEqual(try report(store, id, ["--result-file", lesson.path, "--lesson-stage", "S001"]).0, 0)
            store.reload()
            XCTAssertTrue(store.update(id) { item in
                item.aiResult = item.learningLesson!.body
                item.learningSuggestion = TryLearningSuggestion(nextStep: "从旧阶段开始")
            })
            let detail = TryDetailWindowController(store: store, activates: false)
            detail.show(id); settle()
            defer { detail.close() }
            let window = try XCTUnwrap(detail.window)
            @MainActor func controls() -> [DemandKeyboardActionView] {
                descendants(window.contentView!).compactMap { $0 as? DemandKeyboardActionView }
            }
            // The legacy manuscript is readable immediately, without nested disclosure controls.
            XCTAssertFalse(controls().contains { $0.keyboardIdentifier == "try-study-topic-1" })
            XCTAssertFalse(controls().contains { $0.keyboardIdentifier == "try-learning-ai" })
            XCTAssertFalse(controls().contains { $0.keyboardIdentifier == "try-learning-suggestion-accept" })
            XCTAssertFalse(controls().contains { $0.keyboardIdentifier == "try-learning-sources" })
            let sources = (1...7).map { "[官方资料 \($0)](https://example.com/guide\($0))" }.joined(separator: "\n")
            store.edit(id, field: "learningSources", value: sources)
            XCTAssertTrue(store.flush()); settle()
            XCTAssertTrue(controls().contains { $0.keyboardIdentifier == "try-learning-sources" })
            XCTAssertFalse(controls().contains { $0.keyboardIdentifier.hasPrefix("try-study-topic-") })
            try click("try-learning-sources", window)
            XCTAssertTrue(controls().contains { $0.keyboardIdentifier == "try-resources-all" })
            try click("try-resources-all", window)
            XCTAssertTrue(controls().contains { $0.keyboardIdentifier == "try-resources-collapse" })
            try click("try-resources-collapse", window)
            XCTAssertTrue(controls().contains { $0.keyboardIdentifier == "try-resources-all" })
            if let directory = ProcessInfo.processInfo.environment["DBOARD_LEARNING_PRESENTATION_SNAPSHOTS"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                @MainActor func capture(_ name: String) throws {
                    let root = try XCTUnwrap(window.contentView)
                    let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                    root.cacheDisplay(in: root.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: directory + "/" + name + ".png"))
                }
                try capture("resources")
                try click("try-learning-sources", window)
                try capture("reading")
                window.setContentSize(NSSize(width: 660, height: 680)); settle()
                try capture("narrow")
            }
        }
    }

    func testReorderingAndChangedStandardsRetainUnconfirmedAnswersAndHistory() throws {
        try isolated { store in
            let id = try topic(store)
            try acceptPlan(store, id)
            var assessment = check(stage: "S001", noteID: nil)
            assessment["verdict"] = "needs_practice"
            assessment["evidenceText"] = "我选了第一种，但还没解释理由"
            assessment["gaps"] = ["理由尚未提供"]
            let file = try jsonFile(store, name: "unconfirmed", object: assessment)
            XCTAssertEqual(try report(store, id, ["--check-file", file.path]).0, 0)
            store.reload()
            let old = try XCTUnwrap(store.entry(id)?.learningStageChecks?.first)
            var adjusted = plan()
            var stages = adjusted["stages"] as! [[String: Any]]
            stages.reverse(); stages[0]["estimatedMinutes"] = 45
            adjusted["stages"] = stages
            let reordered = try jsonFile(store, name: "reordered", object: adjusted)
            XCTAssertEqual(try report(store, id, ["--plan-file", reordered.path]).0, 0)
            store.reload()
            XCTAssertEqual(store.entry(id)?.learningStageChecks?.first, old)
            XCTAssertTrue(store.entry(id)!.learningCheckCurrent(old))
            XCTAssertEqual(store.entry(id)?.currentLearningStage?.id, "S001")
            stages[1]["check"] = "新的综合能力标准"
            adjusted["stages"] = stages
            let changed = try jsonFile(store, name: "changed", object: adjusted)
            XCTAssertEqual(try report(store, id, ["--plan-file", changed.path]).0, 0)
            store.reload()
            XCTAssertEqual(store.entry(id)?.learningStageChecks?.first?.evidenceText, old.evidenceText)
            XCTAssertFalse(store.entry(id)!.learningCheckCurrent(old))
            XCTAssertEqual(try report(store, id, ["--check-file", file.path]).0, 0)
            store.reload()
            XCTAssertEqual(store.entry(id)?.learningCheckHistory?.first, old)
        }
    }
    func testMetadataEditsKeepEvidenceButChangedBodyNeedsRevalidation() throws {
        try isolated { store in
            let id = try topic(store)
            try acceptPlan(store, id)
            store.editLearningNote(id, noteID: nil, field: "body", value: "实际观察", generation: 0)
            let noteID = try XCTUnwrap(store.saveLearningNote(id))
            let file = try jsonFile(store, name: "metadata-check", object: check(stage: "S001", noteID: noteID))
            XCTAssertEqual(try report(store, id, ["--check-file", file.path]).0, 0)
            store.reload()
            XCTAssertTrue(store.confirmLearningStage(id, stageID: "S001"))
            store.editLearningNote(id, noteID: noteID, field: "title", value: "重命名", generation: 0)
            store.editLearningNote(id, noteID: noteID, field: "learningStageID", value: "S002", generation: 0)
            XCTAssertTrue(store.flush())
            XCTAssertEqual(store.entry(id)?.verifiedLearningStages, ["S001"])
            let before = try XCTUnwrap(store.entry(id)?.learningStageChecks?.first)
            store.editLearningNote(id, noteID: noteID, field: "body", value: "不同的实验结论", generation: 0)
            XCTAssertTrue(store.flush())
            XCTAssertEqual(store.entry(id)?.learningStageChecks?.first, before)
            XCTAssertTrue(store.entry(id)?.verifiedLearningStages.isEmpty == true)
        }
    }
    func testUnitOrganizationCLIAndNativeAdoptionPreserveOriginalDraftAndChecks() throws {
        try isolated { store in
            let id = try topic(store)
            try acceptPlan(store, id)
            store.editLearningNote(id, noteID: nil, field: "body", value: "原文 ![图](</tmp/original.png>)", generation: 0)
            let noteID = try XCTUnwrap(store.saveLearningNote(id))
            let original = try XCTUnwrap(store.entry(id)?.learningNotes.first)
            let checkFile = try jsonFile(store, name: "original-check", object: check(stage: "S001", noteID: noteID))
            XCTAssertEqual(try report(store, id, ["--check-file", checkFile.path]).0, 0)
            store.reload()
            let originalCheck = try XCTUnwrap(store.entry(id)?.learningStageChecks?.first)
            let prefs = try jsonFile(store, name: "prefs", object: ["teachingStyle": "结果先行", "checkPolicy": "节末测", "constraints": ["不安装模型"]])
            XCTAssertEqual(try report(store, id, ["--preferences-file", prefs.path]).0, 0)
            let topicFile = try textFile(store, name: "topics", text: "[{\"id\":\"K1\",\"title\":\"资源\"}]")
            XCTAssertEqual(try report(store, id, ["--topics-file", topicFile.path]).0, 0)
            let unit: [String: Any] = ["id": "U1", "title": "结果为何变化", "stageIDs": ["S001"], "topicIDs": ["K1"],
                "question": "要解释什么", "materialKind": "public_evaluation", "material": "| 版本 | 分数 |\n| --- | --- |\n| A | 3 |",
                "conditions": "同条件，来源示例", "metrics": "单位说明", "reasoning": "原因", "limits": "边界",
                "judgment": "判断", "sources": [["title": "资料", "url": "https://example.com/evaluation", "locator": "表1"]]]
            let unitFile = try jsonFile(store, name: "unit", object: unit)
            XCTAssertEqual(try report(store, id, ["--unit-file", unitFile.path]).0, 0)
            store.reload()
            XCTAssertEqual(store.entry(id)?.currentLearningUnit?.id, "U1")
            let organization = try jsonFile(store, name: "organize", object: ["id": "O1", "title": "资源整理",
                "body": "AI整理后的解释", "topicIDs": ["K1"], "unitIDs": ["U1"], "sourceNoteIDs": [noteID],
                "sourceVersions": [noteID: original.updatedAt], "explanation": "补充解释，原文保留"])
            XCTAssertEqual(try report(store, id, ["--notes-file", organization.path]).0, 0)
            store.reload()
            store.editLearningNote(id, noteID: nil, field: "body", value: "仍在写的草稿", generation: store.learningGeneration(id))
            XCTAssertTrue(store.flush())
            let draft = store.entry(id)?.learningDraft
            let revision = store.entry(id)!.revision
            XCTAssertFalse(store.adoptLearningOrganization(id, organizationID: "O1", expectedRevision: revision - 1))
            XCTAssertTrue(store.adoptLearningOrganization(id, organizationID: "O1", expectedRevision: revision))
            XCTAssertEqual(store.entry(id)?.learningNotes.first, original)
            XCTAssertEqual(store.entry(id)?.learningDraft, draft)
            XCTAssertEqual(store.entry(id)?.learningStageChecks?.first, originalCheck)
            let organized = try XCTUnwrap(store.entry(id)?.learningNotes.last)
            XCTAssertEqual(organized.origin, "ai_organized")
            XCTAssertEqual(organized.sourceNotes?.first?.body, original.body)
            let ctx = try cli(store, ["context", id, "--learning-action", "lesson"])
            let workflow = try XCTUnwrap((ctx.1["item"] as? [String: Any])?["learningWorkflow"] as? [String: Any])
            XCTAssertEqual((workflow["currentUnit"] as? [String: Any])?["id"] as? String, "U1")
            XCTAssertEqual((workflow["relevantNotes"] as? [[String: Any]])?.first?["id"] as? String, organized.id)
            XCTAssertTrue(store.undoLearningOrganization(id, organizationID: "O1", expectedRevision: store.entry(id)!.revision))
            XCTAssertEqual(store.entry(id)?.learningNotes, [original])
            XCTAssertEqual(store.entry(id)?.learningStageChecks?.first, originalCheck)
        }
    }
    func testCLIStageSwitchPreservesDraftWithoutClaimingMastery() throws {
        try isolated { store in
            let id = try topic(store)
            try acceptPlan(store, id)
            XCTAssertTrue(store.prepareLearningStageNote(id, stageID: "S001"))
            store.editLearningNote(id, noteID: nil, field: "body", value: "未完成的草稿", generation: store.learningGeneration(id))
            XCTAssertTrue(store.flush())
            let revision = store.entry(id)!.revision
            XCTAssertEqual(try cli(store, ["switch-stage", id, "S002", "--expected-revision", String(revision)]).0, 0)
            store.reload()
            XCTAssertEqual(store.entry(id)?.currentLearningStage?.id, "S002")
            XCTAssertEqual(store.entry(id)?.learningNotes.last?.body, "未完成的草稿")
            XCTAssertEqual(store.entry(id)?.learningNotes.last?.learningStageID, "S001")
            XCTAssertTrue(store.entry(id)?.verifiedLearningStages.isEmpty == true)
        }
    }

    @MainActor
    func testRedesignedUnitsTopicsAndEvidenceRenderInBothAppearances() throws {
        guard let fixture = ProcessInfo.processInfo.environment["DBOARD_LEARNING_REDESIGN_FIXTURE"] else {
            throw XCTSkip("Optional scoped T007 migration fixture")
        }
        _ = NSApplication.shared
        try isolated { store in
            let data = try Data(contentsOf: URL(fileURLWithPath: fixture))
            let document = try JSONDecoder().decode(TryDocument.self, from: data)
            let item = try XCTUnwrap(document.entries.first)
            try data.write(to: store.url)
            store.reload()
            XCTAssertEqual(item.learningNotes.count, 8)
            XCTAssertEqual(item.verifiedLearningStages, ["S001"])
            XCTAssertEqual(item.currentLearningUnit?.id, "U-LLAMA-QUANT-PPL")
            let detail = TryDetailWindowController(store: store, activates: false)
            detail.show(item.id); settle()
            defer { detail.close() }
            let window = try XCTUnwrap(detail.window)
            let output = ProcessInfo.processInfo.environment["DBOARD_LEARNING_REDESIGN_SNAPSHOTS"]
            if let output { try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true) }
            @MainActor func capture(_ name: String) throws {
                let root = try XCTUnwrap(window.contentView)
                root.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                root.cacheDisplay(in: root.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(png.count, 2000)
                if let output { try png.write(to: URL(fileURLWithPath: output + "/" + name + ".png")) }
            }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance); settle()
                try capture(appearance == .aqua ? "study-light" : "study-dark")
            }
            let scope = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? NSSegmentedControl }.first)
            scope.selectedSegment = 1
            if let action = scope.action { _ = scope.sendAction(action, to: scope.target) }
            settle()
            XCTAssertNotNil(descendants(window.contentView!).compactMap { $0 as? DemandKeyboardActionView }
                .first { $0.keyboardIdentifier == "try-retest-S005" })
            try capture("review")
            scope.selectedSegment = 0
            if let action = scope.action { _ = scope.sendAction(action, to: scope.target) }
            settle()
            try click("try-notebook-browse", window)
            XCTAssertFalse(descendants(window.contentView!).compactMap { $0 as? TryNoteTextView }.first?.isEditable ?? true)
            XCTAssertNotNil(descendants(window.contentView!).compactMap { $0 as? DemandKeyboardActionView }
                .first { $0.keyboardIdentifier == "try-note-topic-K002" })
            try click("try-note-topic-K002", window)
            let topicReader = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? TryNoteTextView }.first)
            XCTAssertTrue(topicReader.string.hasPrefix("参数量"), "Topic selection opens the organized note")
            XCTAssertEqual(topicReader.frame.origin, .zero, "A topic document stays inside its viewport")
            XCTAssertEqual(topicReader.visibleRect.minY, 0, accuracy: 1, "A new organized page opens at its beginning")
            try capture("topics")
            window.setContentSize(NSSize(width: 660, height: 680)); settle()
            try capture("topics-narrow")
        }
    }

    private func topic(_ store: TryStore) throws -> String {
        var config = TryLearningConfig.empty
        config.goal = "独立排查Redis内存问题"
        config.baseline = "会基础命令"
        let text = String(data: try JSONEncoder().encode(config), encoding: .utf8)!
        store.editCapture(.digestion, field: "learningConfig", value: text, generation: 0)
        return try XCTUnwrap(store.submitCapture(.digestion))
    }
    private func plan() -> [String: Any] {
        ["goalSummary": "学会排查内存并完成恢复", "target": "独立排查Redis内存问题", "startingPoint": "会基础命令，需补充机制理解", "rationale": "先理解再实践，在时间内完成",
         "stages": [["id": "S001", "title": "内存与淘汰", "objective": "能够解释淘汰策略的取舍", "resources": "Redis官方文档", "practice": "比较两种策略", "check": "解释实验观察并选择合适策略", "estimatedMinutes": 30],
                    ["id": "S002", "title": "恢复实验", "objective": "独立完成恢复", "resources": "本地环境", "practice": "做一次恢复实验", "check": "解释恢复结果与风险", "estimatedMinutes": 30]]]
    }
    private func check(stage: String, noteID: String?) -> [String: Any] {
        ["stageID": stage, "verdict": "ready", "summary": "实际回答满足这一节标准", "gaps": [],
         "evidenceText": "用户实际比较了两种策略，并解释观察到的结果。", "noteIDs": noteID.map { [$0] } ?? [],
         "outcome": stage == "S001" ? "能解释淘汰策略的取舍" : "能独立完成恢复实验"]
    }
    private func acceptPlan(_ store: TryStore, _ id: String) throws {
        let file = try jsonFile(store, name: "plan-" + UUID().uuidString, object: plan())
        XCTAssertEqual(try report(store, id, ["--plan-file", file.path]).0, 0)
        store.reload()
        XCTAssertTrue(store.entry(id)?.learningPlanCurrent == true, store.error ?? "学习方案未能生效")
    }
    private func report(_ store: TryStore, _ id: String, _ flags: [String]) throws -> (Int32, [String: Any]) {
        XCTAssertTrue(store.flush())
        return try cli(store, ["report", id, "--expected-revision", String(store.entry(id)!.revision),
            "--summary", "本轮学习反馈", "--event-id", UUID().uuidString] + flags)
    }
    private func cli(_ store: TryStore, _ flags: [String]) throws -> (Int32, [String: Any]) {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tools/dboard_ai.py")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [file.path, "try", "--store", store.url.path] + flags
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run(); let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return (process.terminationStatus, try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any]))
    }
    private func jsonFile(_ store: TryStore, name: String, object: [String: Any]) throws -> URL {
        let file = store.url.deletingLastPathComponent().appendingPathComponent(name + ".json")
        try JSONSerialization.data(withJSONObject: object).write(to: file); return file
    }
    private func textFile(_ store: TryStore, name: String, text: String) throws -> URL {
        let file = store.url.deletingLastPathComponent().appendingPathComponent(name + ".md")
        try text.write(to: file, atomically: true, encoding: .utf8); return file
    }
    private func isolated(_ action: (TryStore) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LearningFlow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try action(TryStore(url: folder.appendingPathComponent("personal.json"), watching: false))
    }
    @MainActor private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.35)) }
    @MainActor private func click(_ id: String, _ window: NSWindow) throws {
        let target = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? DemandKeyboardActionView }.first { $0.keyboardIdentifier == id })
        var ancestor = target.superview
        while let view = ancestor {
            if let scroll = view as? NSScrollView, let document = scroll.documentView {
                document.scrollToVisible(target.convert(target.bounds, to: document).insetBy(dx: 0, dy: -8))
            }
            ancestor = view.superview
        }
        settle()
        let point = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
        }
        settle()
    }
}
