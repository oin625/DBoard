import XCTest
import AppKit
@testable import DBoard

final class TryQuickLearningTests: XCTestCase {
    func testEmptyProgressStillShowsGoalAndStageAndLessonDoesNotCountAsMastery() {
        var entry = sample()
        entry.learningLesson = TryLearningLesson(stageID: "S001", planID: "plan", body: "已讲解本节内容")
        let summary = TryLearningQuickSummary(entry)
        XCTAssertEqual(summary.goal, entry.learningPlan?.goalSummary)
        XCTAssertEqual(summary.current, "建立模型的基本概念")
        XCTAssertEqual(summary.stageNumber, 1)
        XCTAssertEqual(summary.stageCount, 6)
        XCTAssertEqual(summary.masteredCount, 0)
        XCTAssertTrue(summary.next.contains("比较文字、图像与语音模型"))
    }

    func testChangedEvidenceOrGoalCannotKeepStaleProgressOrGoalSummary() {
        var entry = sample()
        let version = entry.learningNotes[0].updatedAt
        entry.learningStageChecks = [TryLearningStageCheck(stageID: "S001", planID: "plan",
            configRevision: 1, verdict: "pass", summary: "已理解", gaps: [], evidenceText: "", outcome: "",
            evidenceVersions: ["N001": version], confirmedAt: version)]
        entry.currentLearningStageID = "S002"
        XCTAssertEqual(TryLearningQuickSummary(entry).masteredCount, 1)
        XCTAssertEqual(TryLearningQuickSummary(entry).stageNumber, 2)
        entry.notes?[0].updatedAt += 1
        XCTAssertEqual(TryLearningQuickSummary(entry).masteredCount, 0)
        entry.learningPlanProposal = entry.learningPlan
        entry.learningConfig?.revision = 2
        entry.learningConfig?.goal = "能独立部署一个本地模型"
        let stale = TryLearningQuickSummary(entry)
        XCTAssertEqual(stale.goal, "能独立部署一个本地模型")
        XCTAssertEqual(stale.stageCount, 0)
        XCTAssertNil(stale.stageNumber)
        XCTAssertEqual(stale.phase, "学习目标已更新")
    }

    func testPreparationDeadlineAndFinishedStatesHaveUsefulNextSteps() {
        var entry = sample()
        entry.learningConfig = nil
        entry.learningPlan = nil
        XCTAssertEqual(TryLearningQuickSummary(entry).phase, "准备开始")
        XCTAssertFalse(TryLearningQuickSummary(entry).goal.isEmpty)
        entry = sample()
        entry.learningPlan = nil
        XCTAssertEqual(TryLearningQuickSummary(entry).phase, "等待学习方案")
        entry = sample()
        entry.learningConfig?.deadline = Date().addingTimeInterval(-2 * 86400).timeIntervalSince1970
        XCTAssertTrue(TryLearningQuickSummary(entry).next.contains("复盘"))
        entry.learningFinishedAt = Date().timeIntervalSince1970
        entry.learningGoalReached = false
        XCTAssertEqual(TryLearningQuickSummary(entry).phase, "本轮已结束")
        XCTAssertEqual(TryLearningQuickSummary(entry).next, "回看学习总结")
    }

    @MainActor
    func testCardSnapshotsForStudyPreparationAndIdeaKeepTheSameWindowSize() throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TryQuickLearning-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var study = sample()
        if let path = ProcessInfo.processInfo.environment["DBOARD_TRY_CARD_STORE"] {
            study = try XCTUnwrap(TryDisk.read(URL(fileURLWithPath: path)).entries.first { $0.id == "T007" })
        }
        var preparation = sample()
        preparation.id = "T008"; preparation.title = "准备学一门新的知识"
        preparation.learningConfig = nil; preparation.learningPlan = nil; preparation.notes = []
        let idea = TryEntry(id: "T009", kind: .idea, title: "把学过的东西留下来",
            body: "先把每天的理解留下来，慢慢找到值得继续研究的方向。",
            createdAt: 1, updatedAt: 1)
        let url = folder.appendingPathComponent("personal.json")
        try TryDisk.change(url) { $0.entries = [study, preparation, idea] }
        let store = TryStore(url: url, watching: false)
        let controller = TryQuickOpenWindowController(store: store, activates: false)
        controller.show()
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let size = window.frame.size
        for (id, name) in [(study.id, "learning"), (preparation.id, "preparation"), (idea.id, "idea")] {
            controller.model.scope = id == idea.id ? .idea : .digestion
            while controller.model.selectedID != id { controller.model.move(1) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            XCTAssertEqual(window.frame.size, size, "Switching card types must not resize the window")
            if let output = ProcessInfo.processInfo.environment["DBOARD_TRY_CARD_SNAPSHOTS"] {
                try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
                let view = try XCTUnwrap(window.contentView)
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: output + "/" + name + ".png"))
            }
        }
    }

    private func sample() -> TryEntry {
        let now = Date().timeIntervalSince1970
        var entry = TryEntry(id: "T007", kind: .digestion, title: "本地小模型研究", createdAt: now, updatedAt: now)
        entry.learningConfig = TryLearningConfig(goal: "了解本地模型，理解选型与运行条件",
            baseline: "小白", minutesPerDay: 60, deadline: now + 13 * 86400, revision: 1)
        let titles = ["建立模型的基本概念", "比较文字、图像与语音模型", "通过模型卡片选型",
            "理解本地运行条件", "理解训练与微调", "综合自测"]
        entry.learningPlan = TryLearningPlan(id: "plan", configRevision: 1, target: "", startingPoint: "", rationale: "",
            stages: titles.enumerated().map { index, title in
                TryLearningStage(id: String(format: "S%03d", index + 1), title: title, objective: "",
                    resources: "", practice: "", check: "", estimatedMinutes: 60)
            }, goalSummary: "认识文字、图像和语音模型，会看模型卡片做选型、粗估本地运行配置，理解训练与微调。")
        entry.currentLearningStageID = "S001"
        entry.notes = [TryLearningNote(id: "N001", body: "理解模型的基本概念", createdAt: now, updatedAt: now),
            TryLearningNote(id: "N002", body: "先认识模型，再尝试选型", createdAt: now, updatedAt: now)]
        return entry
    }
}
