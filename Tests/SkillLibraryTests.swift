import XCTest
import SwiftUI
import AppKit
@testable import DBoard

final class SkillLibraryTests: XCTestCase {
    private func model() -> SkillsViewModel { SkillsViewModel(libraryURL: nil, categoryURL: nil) }
    private func skill(_ name: String, source: String = "Codex", enabled: Bool = true) -> SkillItem {
        SkillItem(dir: name, path: "/tmp/" + name, name: name, desc: "用于开发工作",
                  enabled: enabled, category: "开发工具", sources: [source])
    }

    func testSharedCompatibilityAndPluginsAreDiscoverableWithoutLegacyMixingIn() {
        let vm = model()
        vm.items = [skill("native"), skill("compatible", source: "Claude 兼容"),
                    skill("plugin", source: "Codex 插件"), skill("system", source: "Codex 系统"),
                    skill("legacy", source: "Claude 遗留", enabled: false)]
        XCTAssertEqual(Set(vm.currentItems.map(\.name)), ["native", "compatible", "plugin", "system"])
        XCTAssertEqual(vm.assetItems.map(\.name), ["legacy"])
        vm.sourceFilter = "共享"
        XCTAssertEqual(vm.filtered.map(\.name), ["compatible"])
        vm.switchScope(assetLibrary: true)
        XCTAssertEqual(vm.filtered.map(\.name), ["legacy"])
        XCTAssertEqual(vm.sourceFilter, "全部来源")
    }

    func testFavoritesAndPersonalDescriptionsSurviveReloadAndCanBeRemoved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("metadata.json")
        let item = skill("review")
        let vm = SkillsViewModel(libraryURL: url, categoryURL: nil)
        vm.toggleFavorite(item)
        vm.setNote("  检查我的 Java 改动  ", for: item)
        let restored = SkillsViewModel(libraryURL: url, categoryURL: nil)
        XCTAssertTrue(restored.favorites.contains(item.id))
        XCTAssertEqual(restored.note(for: item), "检查我的 Java 改动")
        restored.toggleFavorite(item)
        restored.setNote("", for: item)
        let empty = SkillsViewModel(libraryURL: url, categoryURL: nil)
        XCTAssertTrue(empty.favorites.isEmpty)
        XCTAssertEqual(empty.note(for: item), "")
    }

    func testSearchMatchesDeclaredNameCategoryAndPersonalNoteWithoutHealthPriority() {
        let vm = model()
        var a = skill("a"); a.health = .healthy
        var z = skill("z"); z.health = .broken
        z.name = "Readable Review"
        vm.items = [z, a]
        XCTAssertEqual(vm.filtered.map(\.name), ["a", "Readable Review"])
        vm.search = "readable"
        XCTAssertEqual(vm.filtered.map(\.name), ["Readable Review"])
        vm.setNote("排查超时", for: a)
        vm.search = " 超时 "
        XCTAssertEqual(vm.filtered.map(\.name), ["a"])
        vm.search = "开发工具"
        XCTAssertEqual(vm.filtered.count, 2)
        vm.search = ""
        vm.toggleFavorite(z)
        XCTAssertEqual(vm.filtered.first?.name, "Readable Review")
        vm.favoritesOnly = true
        XCTAssertEqual(vm.filtered.map(\.name), ["Readable Review"])
    }

    func testPaginationCountsActualMatchesAndResetsWhenSwitchingScope() {
        let vm = model()
        vm.items = (0..<85).map { skill(String(format: "skill-%03d", $0)) }
        XCTAssertEqual(vm.filtered.count, 40)
        XCTAssertTrue(vm.canLoadMore)
        vm.loadMoreAssets()
        XCTAssertEqual(vm.filtered.count, 80)
        vm.loadMoreAssets()
        XCTAssertEqual(vm.filtered.count, 85)
        XCTAssertFalse(vm.canLoadMore)
        vm.search = "skill-080"
        XCTAssertEqual(vm.matchedItems.count, 1)
        XCTAssertFalse(vm.canLoadMore)
        vm.switchScope(assetLibrary: false)
        XCTAssertEqual(vm.assetLimit, 40)
    }

    func testClassificationOnlyWritesSeparateMetadataAndSupportsCompatibleSkills() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = directory.appendingPathComponent("SKILL.md")
        try "original".write(to: document, atomically: true, encoding: .utf8)
        var item = skill("compatible", source: "Claude 兼容")
        item.origin = "Claude 兼容"
        let categories = directory.appendingPathComponent("categories.json")
        let vm = SkillsViewModel(libraryURL: nil, categoryURL: categories)
        vm.items = [item]
        vm.addCategory("我的调试")
        vm.assign(item, to: "我的调试")
        XCTAssertEqual(vm.items[0].category, "我的调试")
        vm.renameCategory("我的调试", to: "排查")
        XCTAssertEqual(vm.items[0].category, "排查")
        let restored = SkillsViewModel(libraryURL: nil, categoryURL: categories)
        restored.loadOverrides()
        XCTAssertEqual(restored.overrides[item.dir], "排查")
        vm.deleteCategory("排查")
        XCTAssertNotEqual(vm.items[0].category, "排查")
        XCTAssertFalse(vm.loading, "Pure classification changes should not rescan the machine")
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), "original")
    }

    func testMetadataParserDoesNotInventProblemsFromShortDescriptionOrDifferentDirectory() {
        let item = SkillsViewModel.parseDefinition("""
        ---
        name: review
        description: Code review
        ---
        状态：**未验证**
        """, directory: "some-other-folder", path: "/tmp/fixture")
        XCTAssertEqual(item.health, .healthy)
        XCTAssertTrue(item.problems.isEmpty)
        XCTAssertTrue(item.hints.isEmpty)
        XCTAssertEqual(item.name, "review")
        XCTAssertEqual(item.desc, "Code review")
    }

    func testMetadataParserReadsMultilineDescriptionAndReportsOnlyMissingMetadata() {
        let folded = SkillsViewModel.parseDefinition("""
        ---
        name: review
        description: >-
          Check code changes
          and boundary cases.
        disable-model-invocation: true
        ---
        """, directory: "review", path: "/tmp/fixture")
        XCTAssertEqual(folded.desc, "Check code changes and boundary cases.")
        XCTAssertTrue(folded.manualOnly)
        XCTAssertTrue(folded.problems.isEmpty)
        let missing = SkillsViewModel.parseDefinition("# A document", directory: "review", path: "/tmp/fixture")
        XCTAssertEqual(missing.problems, ["SKILL.md 缺少文件头元数据"])
        let crlf = SkillsViewModel.parseDefinition("---\r\nname: review\r\ndescription: 中文说明\r\n---\r\n",
                                                   directory: "review", path: "/tmp/fixture")
        XCTAssertEqual(crlf.desc, "中文说明")
    }

    func testCopyUsesSelectedSourceInsteadOfGuessingASkillName() {
        var item = skill("review")
        item.name = "Read Code"
        let result = item.invocation(at: "/tmp/another installation")
        XCTAssertTrue(result.contains("/tmp/another installation/SKILL.md"))
        XCTAssertFalse(result.contains("/tmp/review/SKILL.md"))
        XCTAssertTrue(result.hasSuffix("我的任务：\n"))
        var other = skill("review")
        other.name = "Different Skill"
        XCTAssertNotEqual(item.id, other.id)
    }

    @MainActor
    func testRenderOnlySkillsLibrary() throws {
        guard let output = ProcessInfo.processInfo.environment["DBOARD_SKILLS_SNAPSHOTS"] else {
            throw XCTSkip("Set DBOARD_SKILLS_SNAPSHOTS to render only this module")
        }
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let body = """
        ---
        name: code-review
        description: 检查需求对应的代码改动，找出行为和边界问题。
        ---
        # 代码审查
        先读需求，再核对真实改动。
        - 按风险列出具体问题。
        - 给出代码位置和可复现的场景。
        """
        try body.write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let vm = model()
        vm.items = [
            SkillItem(dir: "dboard-feedback", path: directory.path, name: "dboard-feedback",
                      desc: "承接 D板需求，读取最新现状并将进度、变更与联调结果记回面板。", category: "个人效率", sources: ["Codex", "共享"]),
            SkillItem(dir: "code-review", path: directory.path, name: "code-review",
                      desc: "检查需求对应的代码改动，找出行为和边界问题。", category: "开发方法论", sources: ["共享"]),
            SkillItem(dir: "systematic-debugging", path: directory.path, name: "systematic-debugging",
                      desc: "复现问题、寻找证据，并沿调用链定位根因。", category: "开发方法论", sources: ["共享"]),
            SkillItem(dir: "gateway-auto-register", path: directory.path, name: "gateway-auto-register",
                      desc: "配置网关接口、权限与环境映射，生成调用入口。", category: "TMYC", sources: ["共享"]),
            SkillItem(dir: "playwright-skill", path: directory.path, name: "playwright-skill",
                      desc: "浏览器交互与页面验证。支持截图和复现用户操作。", category: "浏览器", sources: ["Codex"]),
            SkillItem(dir: "dws", path: directory.path, name: "dws",
                      desc: "维护钉钉文档和知识库文件。", category: "钉钉", sources: ["共享"]),
            SkillItem(dir: "skill-creator", path: directory.path, name: "skill-creator",
                      desc: "创建和更新技能说明，组织可复用的工作流程。", category: "元技能", sources: ["系统"]),
            SkillItem(dir: "design", path: directory.path, name: "design",
                      desc: "设计清晰、自然的桌面应用布局和交互。", category: "设计/动画", sources: ["插件"])
        ]
        vm.toggleFavorite(vm.items[0])
        vm.toggleFavorite(vm.items[1])
        let domain = "SkillLibraryPreview-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let theme = ThemeManager(defaults: defaults)
        let font = FontManager(defaults: defaults)
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }

        for (name, width, appearance, selection) in [
            ("library-light", CGFloat(1060), NSAppearance.Name.aqua, Optional<String>.none),
            ("detail-light", CGFloat(1060), NSAppearance.Name.aqua, Optional("code-review")),
            ("detail-min", CGFloat(760), NSAppearance.Name.aqua, Optional("code-review")),
            ("library-dark", CGFloat(1060), NSAppearance.Name.darkAqua, Optional<String>.none)
        ] {
            NSApp.appearance = NSAppearance(named: appearance)
            let host = NSHostingController(rootView:
                SkillsBoardView(refreshOnAppear: false, initialSelection: selection)
                    .environmentObject(vm).environmentObject(theme).environmentObject(font)
                    .environment(\.dboardFontOverride, .system)
                    .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light))
            host.sizingOptions = []
            let window = DemandWorkspaceWindow(contentRect: NSRect(x: -10000, y: 0, width: width, height: 740))
            window.setContent(host)
            window.appearance = NSAppearance(named: appearance)
            window.setContentSize(NSSize(width: width, height: 740))
            window.setFrameOrigin(NSPoint(x: -10000, y: 0))
            window.orderBack(nil)
            defer { window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let content = try XCTUnwrap(window.contentView)
            content.layoutSubtreeIfNeeded()
            XCTAssertEqual(content.bounds.width, width, accuracy: 1)
            let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: output + "/" + name + ".png"))
        }
    }
}
