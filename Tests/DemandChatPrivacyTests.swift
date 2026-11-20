import XCTest
import Foundation
import AppKit
@testable import DBoard

final class DemandChatPrivacyTests: XCTestCase {
    func testMissingInvalidAndNonBooleanSettingsRemainClosed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("privacy.json")
        XCTAssertFalse(DemandChatPrivacy.readEnabled(at: url))
        for value in ["{}", "invalid", #"{"demand_chat_enabled":"true"}"#,
                      #"{"demand_chat_enabled":1}"#, #"{"demand_chat_enabled":false}"#] {
            try value.write(to: url, atomically: true, encoding: .utf8)
            XCTAssertFalse(DemandChatPrivacy.readEnabled(at: url), value)
        }
    }

    func testExplicitSettingPersistsAndCanBeDisabledAgain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("privacy.json")
        let privacy = DemandChatPrivacy(url: url)
        XCTAssertFalse(privacy.enabled)
        privacy.setEnabled(true)
        XCTAssertTrue(privacy.enabled)
        XCTAssertTrue(DemandChatPrivacy(url: url).enabled)
        privacy.setEnabled(false)
        XCTAssertFalse(privacy.enabled)
        XCTAssertFalse(DemandChatPrivacy(url: url).enabled)
        XCTAssertNil(privacy.error)
    }

    func testSettingsFailureDoesNotEnableAccess() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "not a directory".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let privacy = DemandChatPrivacy(url: url.appendingPathComponent("privacy.json"))
        privacy.setEnabled(true)
        XCTAssertFalse(privacy.enabled)
        XCTAssertNotNil(privacy.error)
    }

    @MainActor
    func testExpandedDetailDoesNotExposeChatControls() throws {
        guard !DemandChatPrivacy.isEnabled else { return }
        _ = NSApplication.shared
        let vm = DBoardViewModel(loadCache: false)
        var item = try XCTUnwrap(CacheParser.parse(content: "## 🟡 重要\n### D014【ultra】锁券链路 #进行中\n").items.first)
        item.chatLinks = DemandChatLinks(primary: DemandChat(id: "cid-private", name: "私密群"))
        vm.items = [item]
        let controller = DemandDetailWindowController(activates: false)
        vm.demandWindowPresenter = { controller.show($0) }
        defer { controller.close() }
        vm.openDemandEditor(.inspect, item: item)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let navigation = try XCTUnwrap(controller.keyboardNavigation)
        let ids = navigation.focusableControls().compactMap { ($0 as? DemandKeyboardActionView)?.keyboardIdentifier }
        XCTAssertTrue(ids.contains("release-section-D014"), "The expanded requirement must be rendered")
        XCTAssertFalse(ids.contains("demand-chats-D014"))
    }

    @MainActor
    func testDisabledChatEditorCannotBeOpened() throws {
        guard !DemandChatPrivacy.isEnabled else { return }
        let vm = DBoardViewModel(loadCache: false)
        let item = try XCTUnwrap(CacheParser.parse(content: "## 🟡 重要\n### D014【ultra】锁券链路 #进行中\n").items.first)
        vm.openDemandEditor(.chats, item: item)
        XCTAssertNil(vm.demandEditor)
        let instruction = DboardAITaskContext.readInstruction(item: item)
        XCTAssertTrue(instruction.contains("不读取或搜索钉钉聊天"))
    }
}
