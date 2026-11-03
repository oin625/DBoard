import XCTest
@testable import DBoard

final class DemandPromptSectionsTests: XCTestCase {
    func testAssemblyUsesFixedOrderAndOmitsEmptySections() {
        let sections = DemandPromptSections(codeEntry: "服务 A\n参考验券流程",
            materials: "https://example.com/prd", intent: "将锁券从验券中移除")
        XCTAssertEqual(sections.assembled,
            "## 代码入口\n请根据以下服务、流程描述或代码路径，查找并阅读相关实现：\n服务 A\n参考验券流程\n## 可能有用的资料\n请查找并阅读以下资料，结合本次任务按需参考：\nhttps://example.com/prd\n## 要做什么\n将锁券从验券中移除")
        XCTAssertEqual(DemandPromptSections(intent: "全新模块").assembled, "## 要做什么\n全新模块")
        XCTAssertEqual(DemandPromptSections(codeEntry: "  \n", materials: "\t").assembled, "")
        XCTAssertEqual(DemandPromptSections().stored, "")
        XCTAssertFalse(sections.assembled.contains("dboard-prompt"))
    }

    func testCopyOnlyAddsOneLineBreakBetweenSections() {
        let sections = DemandPromptSections(codeEntry: "\nultra 里的车点点链路\n\n",
            materials: "\n1028-PRD-车点点核销补单\n", intent: "\n拆出锁券\n\n保留原有业务规则\n\n")
        let copied = sections.assembled
        XCTAssertTrue(copied.contains("相关实现：\nultra"))
        XCTAssertTrue(copied.contains("按需参考：\n1028-PRD"))
        XCTAssertTrue(copied.contains("车点点链路\n## 可能有用的资料"))
        XCTAssertTrue(copied.contains("核销补单\n## 要做什么"))
        XCTAssertFalse(copied.contains("\n\n\n"))
        XCTAssertTrue(copied.hasSuffix("拆出锁券\n\n保留原有业务规则"))
        XCTAssertEqual(DemandPromptSections(stored: sections.stored), sections)
    }

    func testPreviouslySavedSectionsStillDecodeAfterCopyInstructionsChange() {
        let data = Data(#"{"codeEntry":"车点点验券流程","intent":"拆出锁券","materials":"锁券接口方案"}"#.utf8)
        let previous = "<!-- dboard-prompt:v2:" + data.base64EncodedString() + " -->\n## 代码入口\n车点点验券流程\n\n## 需求资料\n锁券接口方案\n\n## 改造意图\n拆出锁券"
        let sections = DemandPromptSections(stored: previous)
        XCTAssertEqual(sections.codeEntry, "车点点验券流程")
        XCTAssertEqual(sections.materials, "锁券接口方案")
        XCTAssertEqual(sections.intent, "拆出锁券")
        XCTAssertTrue(sections.assembled.contains("查找并阅读相关实现"))
        XCTAssertTrue(sections.assembled.contains("查找并阅读以下资料"))
        XCTAssertFalse(sections.assembled.contains("dboard-prompt"))
    }

    func testNewModuleDoesNotAskAIToFindExistingServices() {
        let sections = DemandPromptSections(codeEntry: "全新模块", intent: "新增通知模块")
        XCTAssertTrue(sections.assembled.contains("本次为全新模块"))
        XCTAssertFalse(sections.assembled.contains("查找并阅读相关实现"))
    }

    func testStructuredFieldsPreserveMarkdownAndWhitespaceWithoutHeadingAmbiguity() {
        let sections = DemandPromptSections(
            codeEntry: "\n/Users/example/repo\n\n## 改造意图\n这是代码中的标题\n",
            materials: "https://example.com/prd\n<!-- example -->\n",
            intent: "\n## 代码入口\n```swift\n    let text = \"需求资料\"\n```\n  \n")
        XCTAssertEqual(DemandPromptSections(stored: sections.stored), sections)
        XCTAssertEqual(DemandPromptSections(stored: sections.stored).assembled, sections.assembled)
    }

    func testLegacyPromptIsKeptInIntentWithoutGuessingSections() {
        let legacy = "## 代码入口\n旧自由文本\n\n不要根据标题猜测原有字段。\n"
        let sections = DemandPromptSections(stored: legacy)
        XCTAssertEqual(sections.codeEntry, "")
        XCTAssertEqual(sections.materials, "")
        XCTAssertEqual(sections.intent, legacy)
        XCTAssertEqual(DemandPromptSections(stored: sections.stored).intent, legacy)
        XCTAssertEqual(sections.assembled, "## 要做什么\n" + legacy.trimmingCharacters(in: .newlines))
        let malformed = "<!-- dboard-prompt:v2:not-base64 -->\n必须保留"
        XCTAssertEqual(DemandPromptSections(stored: malformed).intent, malformed)
    }

    func testDraftSectionEditsPreserveOtherFieldsAndDiskRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardPromptSections-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cache.md")
        try "## 🟡 重要\n".write(to: file, atomically: true, encoding: .utf8)
        var draft = DItemDraft(newID: "D001", priority: .p1)
        draft.name = "拆出锁券接口"
        draft.promptSections.codeEntry = "/Users/example/service\n车点点验券流程"
        draft.promptSections.materials = "https://example.com/design"
        draft.promptSections.intent = "重新查券 → 锁券 → 查照片\n\n"
        draft.promptSections.reason = "部分券锁券即核销"
        draft.promptSections.rules = "查券 → 锁券 → 查照片\n已锁券先解锁\n"
        let expected = draft.promptSections
        XCTAssertTrue(DItemStore.create(draft, at: file))
        let original = try XCTUnwrap(CacheParser.parse(content: String(contentsOf: file, encoding: .utf8)).items.first)
        XCTAssertEqual(DemandPromptSections(stored: original.prompt), expected)
        var edited = DItemDraft(from: original)
        edited.promptSections.materials = ""
        XCTAssertEqual(edited.promptSections.codeEntry, expected.codeEntry)
        XCTAssertEqual(edited.promptSections.intent, expected.intent)
        XCTAssertEqual(edited.promptSections.reason, expected.reason)
        XCTAssertEqual(edited.promptSections.rules, expected.rules)
        XCTAssertTrue(DItemStore.savePrompt(id: original.id, text: edited.prompt,
            expected: original.prompt, at: file))
        let updated = try XCTUnwrap(CacheParser.parse(content: String(contentsOf: file, encoding: .utf8)).items.first)
        XCTAssertEqual(DemandPromptSections(stored: updated.prompt), edited.promptSections)
        XCTAssertFalse(DemandPromptSections(stored: updated.prompt).assembled.contains("## 可能有用的资料"))
    }

    func testIntentSubsectionsCopyInOrderAndOmitUnfilledExtras() {
        let sections = DemandPromptSections(intent: "\n拆出锁券\n", reason: "锁券即核销",
                                            rules: "查券 → 锁券 → 查照片")
        XCTAssertEqual(sections.assembled,
            "## 要做什么\n拆出锁券\n## 补充说明\n锁券即核销\n查券 → 锁券 → 查照片")
        XCTAssertEqual(DemandPromptSections(stored: sections.stored), sections)
        XCTAssertEqual(DemandPromptSections(intent: "新增模块", reason: " \n", rules: "\t").assembled,
                       "## 要做什么\n新增模块")
        XCTAssertFalse(sections.assembled.contains("\n\n"))
    }

    func testSupplementMergesOldFieldsAndEditsDoNotRestoreClearedRules() {
        // Exact old v3 representation: the new editor must still read the old persisted body.
        let payload = Data(#"{"codeEntry":"ultra","materials":"方案","intent":"拆出锁券","reason":"部分券锁券即核销","rules":"先查券\n再锁券"}"#.utf8)
        let stored = "<!-- dboard-prompt:v3:" + payload.base64EncodedString() +
            " -->\n## 代码入口\nultra\n## 需求资料\n方案\n## 改造意图\n### 要做什么\n拆出锁券\n### 为什么改\n部分券锁券即核销\n### 特殊规则\n先查券\n再锁券"
        var sections = DemandPromptSections(stored: stored)
        XCTAssertEqual(sections.supplement, "部分券锁券即核销\n先查券\n再锁券")
        XCTAssertEqual(sections.codeEntry, "ultra")
        XCTAssertEqual(sections.materials, "方案")
        XCTAssertEqual(sections.intent, "拆出锁券")
        XCTAssertFalse(sections.assembled.contains("## 为什么改"))
        XCTAssertFalse(sections.assembled.contains("## 特殊规则"))
        let merged = sections.supplement
        sections.supplement = merged + "\n本次仅提供上游接口"
        XCTAssertEqual(sections.rules, "")
        XCTAssertEqual(DemandPromptSections(stored: sections.stored).supplement,
                       merged + "\n本次仅提供上游接口")
        sections.supplement = ""
        let cleared = DemandPromptSections(stored: sections.stored)
        XCTAssertEqual(cleared.supplement, "")
        XCTAssertFalse(cleared.assembled.contains("## 补充说明"))
        XCTAssertEqual(cleared.intent, "拆出锁券")
    }

    func testSupplementSupportsEitherOldFieldAndPreservesMarkdown() {
        XCTAssertEqual(DemandPromptSections(reason: "业务背景").supplement, "业务背景")
        XCTAssertEqual(DemandPromptSections(rules: "先查券").supplement, "先查券")
        XCTAssertEqual(DemandPromptSections(reason: " \n", rules: "\t").supplement, "")
        var sections = DemandPromptSections(intent: "新增模块")
        sections.supplement = "\n## 约束\n```swift\n    let value = 1\n```\n\n"
        XCTAssertEqual(DemandPromptSections(stored: sections.stored).supplement, sections.supplement)
        XCTAssertTrue(sections.assembled.hasSuffix("    let value = 1\n```"))
        XCTAssertNil(sections.validationError)
        var draft = DItemDraft(newID: "D001", priority: .p1)
        draft.name = "新增模块"
        draft.promptSections.supplement = "本次仅做接口"
        draft.promptSections.intent = "新增通知接口"
        XCTAssertEqual(draft.promptSections.supplement, "本次仅做接口")
    }

    func testOnlyGoalIsRequiredAndEmptySpellCanBeCleared() {
        XCTAssertNil(DemandPromptSections().validationError)
        XCTAssertNil(DemandPromptSections(intent: "拆出锁券").validationError)
        XCTAssertNotNil(DemandPromptSections(codeEntry: "ultra").validationError)
        XCTAssertNotNil(DemandPromptSections(intent: " \n", reason: "锁券即核销").validationError)
        XCTAssertNotNil(DemandPromptSections(rules: "先查券").validationError)
        var draft = DItemDraft(newID: "D001", priority: .p1)
        draft.name = "拆出锁券"
        draft.promptSections.rules = "先查券"
        XCTAssertNotNil(draft.validationError)
        draft.promptSections.intent = "提供锁券接口"
        XCTAssertNil(draft.validationError)
    }

    func testExternalChangesToNewIntentSubsectionsArePreserved() {
        let sections = DemandPromptSections(intent: "原始改造", reason: "原始原因", rules: "先查券")
        let edited = sections.stored.replacingOccurrences(of: "原始原因", with: "手工修改原因")
        let restored = DemandPromptSections(stored: edited)
        XCTAssertTrue(restored.intent.contains("手工修改原因"))
        XCTAssertFalse(restored.intent.contains("原始原因"))
    }

    func testExternallyEditedReadableTextIsNotSilentlyReplacedByOldMetadata() {
        let stored = DemandPromptSections(intent: "原始改造").stored
        let externallyEdited = stored.replacingOccurrences(of: "原始改造", with: "手工更新的改造")
        let sections = DemandPromptSections(stored: externallyEdited)
        XCTAssertTrue(sections.intent.contains("手工更新的改造"))
        XCTAssertFalse(sections.intent.contains("原始改造"))
    }
}
