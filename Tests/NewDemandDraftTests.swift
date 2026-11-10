import XCTest
import Foundation
@testable import DBoard

final class NewDemandDraftTests: XCTestCase {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DBoardNewDraft-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @MainActor
    func testSwitchingToIncidentNamespaceKeepsDraftAndRejectsLateCallbacks() throws {
        let vm = DBoardViewModel(loadCache: false)
        var ordinary = DItemDraft(newID: "D020", priority: .p1)
        ordinary.name = "未保存问题"
        vm.newItemDraft = ordinary
        var incident = ordinary
        incident.kind = .incident
        incident.id = "P001"
        vm.updateNewItemDraft(incident, previousID: ordinary.id)
        XCTAssertEqual(vm.newItemDraft?.id, "P001")
        XCTAssertEqual(vm.newItemDraft?.name, ordinary.name)
        vm.updateNewItemDraft(ordinary)
        XCTAssertEqual(vm.newItemDraft?.id, "P001")
        vm.finishNewItemDraft()
        vm.updateNewItemDraft(incident, previousID: ordinary.id)
        XCTAssertNil(vm.newItemDraft)
    }

    func testIncompleteDraftRoundTripsAllInputsAcrossRelaunch() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("draft.json")
            var draft = DItemDraft(newID: "D014", priority: .p2)
            draft.project = "ultra\n/Users/fixture/work space/tesla"
            draft.desc = "第一行\n第二行  "
            draft.branch = "feature/unfinished"
            draft.start = "2026-11-"
            draft.deadline = "还没确定"
            draft.reqFlow = ReqFlowLink(id: 2463, no: "R2610290014")
            draft.promptSections = DemandPromptSections(codeEntry: "三渠流程",
                materials: "https://example.com/资料", intent: "")
            XCTAssertNotNil(draft.validationError)
            XCTAssertTrue(NewDemandDraftStore(url: file).save(draft))
            let restored = NewDemandDraftStore(url: file)
            XCTAssertEqual(restored.draft, draft)
            XCTAssertNil(restored.error)
        }
    }

    @MainActor
    func testPageSwitchAndFormRecreationUseTheSameSavedDraft() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("draft.json")
            let vm = DBoardViewModel(loadCache: false, newItemDraftStore: NewDemandDraftStore(url: file))
            vm.beginNewItemDraft()
            var draft = try XCTUnwrap(vm.newItemDraft)
            draft.name = "写了一半的需求"
            draft.project = "ultra\ntesla"
            draft.promptSections.intent = "拆出锁券接口"
            vm.updateNewItemDraft(draft)
            vm.workspacePage = .todos
            vm.newItemFormOpen = false
            vm.workspacePage = .demands
            vm.beginNewItemDraft()
            XCTAssertEqual(vm.newItemDraft?.name, draft.name)
            XCTAssertEqual(vm.newItemDraft?.project, draft.project)
            XCTAssertEqual(vm.newItemDraft?.prompt, draft.prompt)
            let relaunched = DBoardViewModel(loadCache: false, newItemDraftStore: NewDemandDraftStore(url: file))
            XCTAssertEqual(relaunched.newItemDraft, vm.newItemDraft)
            XCTAssertFalse(relaunched.newItemFormOpen)
        }
    }

    @MainActor
    func testFailedCreationKeepsDraftAndSuccessfulCreationPreventsResurrection() throws {
        try withDirectory { directory in
            let draftFile = directory.appendingPathComponent("draft.json")
            let cache = directory.appendingPathComponent("cache.md")
            try "## 🟡 重要\n".write(to: cache, atomically: true, encoding: .utf8)
            let vm = DBoardViewModel(loadCache: false, newItemDraftStore: NewDemandDraftStore(url: draftFile))
            vm.beginNewItemDraft()
            var draft = try XCTUnwrap(vm.newItemDraft)
            draft.desc = "先写描述，名称还没填"
            vm.updateNewItemDraft(draft)
            XCTAssertFalse(DItemStore.create(draft, at: cache))
            XCTAssertEqual(NewDemandDraftStore(url: draftFile).draft, draft)
            draft.name = "现在可以创建"
            vm.updateNewItemDraft(draft)
            XCTAssertTrue(DItemStore.create(draft, at: cache))
            vm.finishNewItemDraft()
            vm.updateNewItemDraft(draft) // The old form's onDisappear callback.
            XCTAssertNil(vm.newItemDraft)
            XCTAssertFalse(vm.newItemFormOpen)
            XCTAssertNil(NewDemandDraftStore(url: draftFile).draft)
            XCTAssertFalse(FileManager.default.fileExists(atPath: draftFile.path))
            XCTAssertEqual(CacheParser.parse(content: try String(contentsOf: cache, encoding: .utf8)).items.count, 1)
        }
    }

    @MainActor
    func testUnreadableDraftIsPreservedAndNewInputStaysInMemory() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("draft.json")
            let bytes = Data("不可读的旧草稿".utf8)
            try bytes.write(to: file)
            let store = NewDemandDraftStore(url: file)
            let vm = DBoardViewModel(loadCache: false, newItemDraftStore: store)
            vm.beginNewItemDraft()
            var draft = try XCTUnwrap(vm.newItemDraft)
            draft.name = "新的输入不能消失"
            vm.updateNewItemDraft(draft)
            XCTAssertEqual(vm.newItemDraft, draft)
            XCTAssertNotNil(vm.newItemDraftError)
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    @MainActor
    func testWriteFailureKeepsLatestInputAndShowsAnError() throws {
        try withDirectory { directory in
            let blocked = directory.appendingPathComponent("not-a-directory")
            try Data().write(to: blocked)
            let store = NewDemandDraftStore(url: blocked.appendingPathComponent("draft.json"))
            let vm = DBoardViewModel(loadCache: false, newItemDraftStore: store)
            vm.beginNewItemDraft()
            var draft = try XCTUnwrap(vm.newItemDraft)
            draft.name = "不能写入磁盘时仍保留"
            vm.updateNewItemDraft(draft)
            XCTAssertEqual(vm.newItemDraft, draft)
            XCTAssertNotNil(vm.newItemDraftError)
        }
    }

    @MainActor
    func testEmptyFormCreatesNoDraftAndExplicitClearSurvivesRelaunch() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("draft.json")
            let vm = DBoardViewModel(loadCache: false, newItemDraftStore: NewDemandDraftStore(url: file))
            vm.beginNewItemDraft()
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            var draft = try XCTUnwrap(vm.newItemDraft)
            draft.name = "手动清空"
            vm.updateNewItemDraft(draft)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            vm.clearNewItemDraft()
            vm.updateNewItemDraft(draft)
            XCTAssertNil(vm.newItemDraft)
            XCTAssertNil(NewDemandDraftStore(url: file).draft)
        }
    }

    func testMultipleRepositoryEntriesSurviveCreationEditingAndAIReadback() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("cache.md")
            try "## 🟡 重要\n".write(to: file, atomically: true, encoding: .utf8)
            var draft = DItemDraft(newID: "D014", priority: .p1)
            draft.name = "跨仓库需求"
            draft.project = " ultra \n/Users/fixture/work space/tesla\nultra\n"
            XCTAssertNil(draft.validationError)
            XCTAssertTrue(DItemStore.create(draft, at: file))
            let item = try XCTUnwrap(CacheParser.parse(content: String(contentsOf: file, encoding: .utf8)).items.first)
            XCTAssertEqual(item.project, "ultra；/Users/fixture/work space/tesla")
            var edit = DItemDraft(from: item)
            XCTAssertEqual(DemandRepositoryEntries.parse(edit.project), ["ultra", "/Users/fixture/work space/tesla"])
            edit.project += "\ncanary"
            XCTAssertTrue(DItemStore.appendProgress(id: item.id, text: "其他 AI 新增的进度", at: file))
            XCTAssertTrue(DItemStore.save(edit, original: item, at: file))
            let cli = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Tools/dboard_ai.py").path
            let result = ProcessRunner.run("/usr/bin/env", arguments: ["python3", cli, "--cache", file.path, "show", "D014"])
            XCTAssertEqual(result.exitCode, 0)
            let response = try XCTUnwrap(try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any])
            let shown = try XCTUnwrap(response["item"] as? [String: Any])
            XCTAssertEqual(shown["declared_repositories"] as? [String], ["ultra", "/Users/fixture/work space/tesla", "canary"])
            XCTAssertEqual((shown["repositories"] as? [[String: String]])?.count, 0)
            let contextResult = ProcessRunner.run("/usr/bin/env", arguments: ["python3", cli, "--cache", file.path, "context", "D014"])
            XCTAssertEqual(contextResult.exitCode, 0)
            let contextJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: contextResult.stdout) as? [String: Any])
            let context = try XCTUnwrap(contextJSON["context"] as? String)
            for entry in ["ultra", "/Users/fixture/work space/tesla", "canary"] {
                XCTAssertTrue(context.contains(entry))
            }
            XCTAssertTrue(context.contains("其他 AI 新增的进度"))
            XCTAssertEqual(CacheParser.parse(content: try String(contentsOf: file, encoding: .utf8)).items.count, 1)
        }
    }
}
