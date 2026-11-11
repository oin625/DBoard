import XCTest
import SwiftUI
import AppKit
@testable import DBoard

/// Opt-in rendering probe; uses fixtures and does not run remote queries or write user data.
final class WorkspaceSnapshots: XCTestCase {
    @MainActor
    func testRenderWorkspaceScreens() throws {
        guard let directory = ProcessInfo.processInfo.environment["DBOARD_UI_SNAPSHOTS"] else {
            throw XCTSkip("设置 DBOARD_UI_SNAPSHOTS 导出界面检查图")
        }
        UserDefaults.standard.register(defaults: ["reply.enabled": false])
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let projectDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardSnapshotProjects-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: projectDirectory) }
        let biz = BizMapViewModel(loadBackgroundData: false, projectStore: DevelopmentProjectStore(url: projectDirectory.appendingPathComponent("projects.json")))
        let vm = DBoardViewModel(loadCache: false, reqFlow: biz)
        vm.items = [
            DItem(id: "D001", project: "工作台", title: "统一需求卡片与工作窗口的操作反馈",
                  headerTitle: "主面板布局与窗口交互优化", status: .inProgress, priority: .p0,
                  deadline: nil, branch: "feature/workspace", startDate: "10.27", milestones: [],
                  reqFlow: ReqFlowLink(id: 1001, no: "R2610270001"),
                  prompt: DemandPromptSections(
                    codeEntry: "DBoard 需求卡片的展开、咒言编辑和复制流程",
                    materials: "需求说明：https://example.com/requirements/prompt",
                    intent: "将咒言固定为代码入口、需求资料、改造意图三个输入区。\n复制时按顺序组装，空白部分省略。\n保留旧咒言，保存失败保留输入。").stored),
            DItem(id: "D002", project: "日志", title: "保留全宽日志与快速钻取",
                  headerTitle: "Audi 日志体验优化", status: .pending, priority: .p1,
                  deadline: nil, branch: nil, startDate: nil, milestones: [])
        ]
        vm.items[0].changes = [
            DemandChange(id: "C001", createdAt: Date(timeIntervalSince1970: 1793354400),
                intent: "原功能已经开发完成，尚未验收。追加：返回结果增加照片字段；继续保留原有联调和验收待办。"),
            DemandChange(id: "C002", createdAt: Date(timeIntervalSince1970: 1793440800),
                intent: "在现有实现上增加超时重试，失败结果返回明确原因。")
        ]
        vm.todaySec = TodoSection(dateLabel: "2026-10-27", items: [
            TodoItem(text: "确认电话线索字段映射", isCompleted: false, linkedDItem: "D001", note: "等对方确认环境",
                     isCarriedOver: true, origin: TodoOrigin(date: "2026-10-24", lines: ["- [ ] 确认电话线索字段映射"], occurrence: 0)),
            TodoItem(text: "核对快捷键和窗口置顶", isCompleted: false, linkedDItem: nil, note: nil),
            TodoItem(text: "检查深浅色界面", isCompleted: true, linkedDItem: nil, note: nil)
        ], isToday: true)
        let fixture = """
        {"generated":"2026-10-27 10:00","phase":{"done":[],"current":"开发","rest":[]},"groups":[{"key":"核心","label":"核心服务"}],
         "services":[{"name":"workspace-service","tier":"核心","c":42,"st":"active","pkg":"workspace","desc":"工作台与需求流的核心服务","mapLevel":"L2","routing":["工作台"],"related":[],"branch":"main","div":"平台","doc":"https://example.com/map","dItems":[]}],
         "routes":[],"dItemsAll":[],"prdGenerated":"2026-10-27 10:00","prdItemsAll":[
         {"id":1001,"no":"R2610270001","name":"统一工作台需求与项目表的状态反馈，支持可读的长标题和明确操作",
          "code":"KFZ","status":"开发中","pri":"高","dev":"测试开发者","scopes":["mine","dept"],"services":["workspace-service"],
          "note":"测试用映射","docs":[],"url":"https://example.com/prd/1001","owner":"测试开发者","submitTime":"2026-10-27",
          "delivDocs":[{"t":1,"url":"https://example.com/design"}],"files":[]},
         {"id":1002,"no":"R2610270002","name":"优化日志查询筛选与无结果提示","code":"SJWC","status":"待开始","pri":"中",
          "dev":"测试开发者","scopes":["pending","dept"],"services":[],"docs":[],"url":"https://example.com/prd/1002"}
         ]}
        """
        biz.cache = try JSONDecoder().decode(BizMapCache.self, from: Data(fixture.utf8))
        biz.syncStatus = [biz.prdItems[0].name: "synced"]
        let declaration = try DevelopmentDeliverables.decode(Data(#"{"success":true,"data":{"3":[{"deliverableDevProject":"workspace-service:feature/feedback,frontend:feature/workspace"}]}}"#.utf8))
        XCTAssertTrue(biz.recordDeliverables(declaration, reqID: 1001))
        biz.expandedPRD = [1001]
        let skills = SkillsViewModel()
        skills.items = [
            SkillItem(dir: "workspace", path: "/tmp/workspace", name: "工作台", desc: "工作台与日常需求维护",
                      verify: "已验证", category: "开发", sources: ["共享"]),
            SkillItem(dir: "review", path: "/tmp/review", name: "代码评审", desc: "检查改动行为与边界场景",
                      health: .warn, problems: ["缺少说明"], category: "开发", sources: ["Codex"])
        ]
        let originalPage = WorkspacePreferences.shared.settingsPage
        defer { WorkspacePreferences.shared.settingsPage = originalPage }

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            vm.workspacePage = .overview
            try render(DBoardRootView().environmentObject(vm).environmentObject(ThemeManager.shared).environmentObject(FontManager.shared),
                       width: 900, height: 740, name: "workspace-" + name, appearance: appearance, directory: directory)
            try render(DBoardRootView(popoverMode: true).environmentObject(vm).environmentObject(ThemeManager.shared).environmentObject(FontManager.shared),
                       width: 520, height: 640, name: "compact-" + name, appearance: appearance, directory: directory)
            let savedToday = vm.todaySec
            vm.todaySec = nil
            try render(DBoardRootView(popoverMode: true).environmentObject(vm).environmentObject(ThemeManager.shared).environmentObject(FontManager.shared),
                       width: 520, height: 640, name: "compact-empty-todos-" + name, appearance: appearance, directory: directory)
            vm.todaySec = savedToday
            vm.workspacePage = .demands
            try render(DBoardRootView().environmentObject(vm).environmentObject(ThemeManager.shared).environmentObject(FontManager.shared),
                       width: 760, height: 560, name: "demands-min-" + name, appearance: appearance, directory: directory)
            vm.expandedIDs = ["D001"]
            vm.demandFilter = .inProgress
            try render(DBoardRootView().environmentObject(vm).environmentObject(ThemeManager.shared).environmentObject(FontManager.shared),
                       width: 900, height: 900, name: "demands-filtered-context-" + name, appearance: appearance, directory: directory)
            vm.expandedIDs = []; vm.demandFilter = .all
            vm.workspacePage = .todos
            try render(DBoardRootView().environmentObject(vm).environmentObject(ThemeManager.shared).environmentObject(FontManager.shared),
                       width: 760, height: 560, name: "todos-carried-" + name, appearance: appearance, directory: directory)
            vm.undoTitle = nil
            try render(ReqFlowRequirementPicker(flow: biz, localItems: vm.items, editingID: "D003",
                select: { _ in }, openExisting: { _ in }, cancel: {}, refreshOnAppear: false),
                width: 540, height: 520, name: "reqflow-link-picker-" + name, appearance: appearance, directory: directory)
            biz.startDevelopmentDraft = PRDStartDevelopmentDraft(reqID: 1002, requiresLaunchTime: true,
                launchTime: "", acceptorID: "fixture", acceptorName: "fixture - 测试提交人")
            try render(PRDStartDevelopmentSheet(vm: biz, item: biz.prdItems.first { $0.id == 1002 }!),
                width: 480, height: 320, name: "start-development-" + name, appearance: appearance, directory: directory)
            try render(DemandPromptEditor(item: vm.items[0], draftStore: vm.promptDraftStore, cancel: {}).environmentObject(vm),
                width: 640, height: 640, name: "prompt-editor-" + name, appearance: appearance, directory: directory)
            try render(DemandPromptEditor(item: vm.items[1], draftStore: vm.promptDraftStore, cancel: {}).environmentObject(vm),
                width: 520, height: 480, name: "prompt-editor-empty-" + name, appearance: appearance, directory: directory)
            try render(DemandChangesEditor(item: vm.items[0], draftStore: vm.changeDraftStore, cancel: {}, refreshOnAppear: false).environmentObject(vm),
                width: 640, height: 600, name: "change-spells-" + name, appearance: appearance, directory: directory)
            var longLinkItem = vm.items[0]
            longLinkItem.prompt = DemandPromptSections(
                codeEntry: "ultra 里三渠的车点点链路\n重点看验券、锁券和照片查询流程",
                materials: "https://alidocs.dingtalk.com/i/nodes/ExampleDocument?corpId=dingfixture&iframeQuery=" +
                    String(repeating: "abcdefghij", count: 20) + "&utm_source=im",
                intent: "将锁券和查照片从验券流程中拆出，提供独立接口供上游调用。").stored
            try render(DemandPromptEditor(item: longLinkItem, draftStore: vm.promptDraftStore, cancel: {}).environmentObject(vm),
                width: 520, height: 560, name: "prompt-editor-longlink-" + name, appearance: appearance, directory: directory)
            let unlinkedDraft = DItemDraft(newID: "D003", priority: .p1)
            try render(DItemEditForm(draft: unlinkedDraft, isNew: true, onSave: { _ in }, onCancel: {})
                .environmentObject(vm).environmentObject(ThemeManager.shared)
                .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(ThemeManager.shared.current.background),
                width: 480, height: 510, name: "reqflow-link-form-empty-" + name, appearance: appearance, directory: directory)
            var linkedDraft = unlinkedDraft
            linkedDraft.associate(with: biz.prdItems[1])
            try render(DItemEditForm(draft: linkedDraft, isNew: true, onSave: { _ in }, onCancel: {})
                .environmentObject(vm).environmentObject(ThemeManager.shared)
                .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(ThemeManager.shared.current.background),
                width: 480, height: 540, name: "reqflow-link-form-selected-" + name, appearance: appearance, directory: directory)
            biz.perspective = .requirements
            for width: CGFloat in [740, 980] {
                try render(BizMapBoardView(refreshOnAppear: false).environmentObject(biz)
                    .environmentObject(ThemeManager.shared).environmentObject(FontManager.shared),
                    width: width, height: 740, name: "reqflow-\(Int(width))-" + name, appearance: appearance, directory: directory)
            }
            let longDeclaration = DevelopmentProjectSnapshot(projects: [
                DeclaredDevelopmentProject(project: "workspace-service", branch: "feature/requirement-development-project-declaration-with-long-branch-name"),
                DeclaredDevelopmentProject(project: "frontend-workspace-client", branch: nil)
            ])
            try render(DevelopmentProjectsView(snapshot: longDeclaration, loading: false,
                error: "开发交付读取失败，请重试", refresh: {}).padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor)),
                width: 326, height: 330, name: "projects-long-cached-error-" + name, appearance: appearance, directory: directory)
            try render(DevelopmentProjectsView(snapshot: DevelopmentProjectSnapshot(projects: []),
                loading: false, error: nil, refresh: {}).padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor)),
                width: 326, height: 160, name: "projects-empty-" + name, appearance: appearance, directory: directory)
            try render(DevelopmentProjectsView(snapshot: nil, loading: true, error: nil, refresh: {}).padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor)),
                width: 326, height: 140, name: "projects-loading-" + name, appearance: appearance, directory: directory)
            try render(DevelopmentProjectsView(snapshot: nil, loading: false,
                error: "登录已过期，请重新登录后读取", refresh: {}).padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor)),
                width: 326, height: 160, name: "projects-unread-error-" + name, appearance: appearance, directory: directory)
            biz.perspective = .services
            try render(BizMapBoardView(refreshOnAppear: false).environmentObject(biz)
                .environmentObject(ThemeManager.shared).environmentObject(FontManager.shared),
                width: 740, height: 540, name: "bizmap-" + name, appearance: appearance, directory: directory)
            try render(SkillsBoardView(refreshOnAppear: false).environmentObject(skills)
                .environmentObject(ThemeManager.shared).environmentObject(FontManager.shared),
                width: 760, height: 540, name: "skills-" + name, appearance: appearance, directory: directory)
            for page in [SettingsPage.general, .appearance, .favorites, .shortcuts, .clipboard, .usage] {
                WorkspacePreferences.shared.settingsPage = page
                try render(DBoardSettingsView(), width: 640, height: 600,
                           name: "settings-" + page.rawValue + "-" + name, appearance: appearance, directory: directory)
            }
        }
    }

    @MainActor
    func testOpeningHomeDoesNotFocusTodoInputWithEmptyOrExistingTodos() {
        UserDefaults.standard.register(defaults: ["reply.enabled": false])
        _ = NSApplication.shared
        let previousApp = NSWorkspace.shared.frontmostApplication
        defer { previousApp?.activate() }
        for todos in [[], [TodoItem(text: "确认接口方案", isCompleted: false, linkedDItem: nil, note: nil)]] {
            let vm = DBoardViewModel(loadCache: false)
            vm.todaySec = TodoSection(dateLabel: DemandDates.today(), items: todos, isToday: true)
            let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 520, height: 640),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView:
                DBoardRootView(popoverMode: true).environmentObject(vm)
                    .environmentObject(ThemeManager.shared).environmentObject(FontManager.shared)
                    .frame(width: 520, height: 640))
            window.makeKeyAndOrderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            XCTAssertFalse((window.firstResponder as? NSTextView)?.isEditable == true,
                           "Opening home should not start text entry before the user chooses Add")
            window.close()
        }
    }

    @MainActor
    func testRenderIntentForm() throws {
        guard let directory = ProcessInfo.processInfo.environment["DBOARD_INTENT_SNAPSHOTS"] else {
            throw XCTSkip("设置 DBOARD_INTENT_SNAPSHOTS 导出咒言填空表单")
        }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let vm = DBoardViewModel(loadCache: false)
        var item = DItem(id: "D014", project: "工作台", title: "", headerTitle: "车点点锁券链路改造",
                        status: .inProgress, priority: .p1, deadline: nil, branch: nil,
                        startDate: nil, milestones: [])
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            item.prompt = DemandPromptSections(
                codeEntry: "ultra 里三渠的车点点链路", materials: "1028-PRD-车点点核销补单",
                intent: "将锁券、查照片从验券流程中拆出，提供独立接口，让 SAAS 在开工单后调用。",
                reason: "车点点部分券锁券即核销，提前锁券会导致券已核销、工单还没创建。",
                rules: "接口依次查券 → 锁券 → 查照片。\n查券后 20 分钟内必须锁券，所以这里要重新查券。\n已锁券时先解锁再加锁。").stored
            try render(DemandPromptEditor(item: item, draftStore: vm.promptDraftStore, cancel: {}).environmentObject(vm),
                       width: 640, height: 640, name: "intent-filled-" + name,
                       appearance: appearance, directory: directory)
            item.prompt = ""
            try render(DemandPromptEditor(item: item, draftStore: vm.promptDraftStore, cancel: {}).environmentObject(vm),
                       width: 480, height: 640, name: "intent-empty-" + name,
                       appearance: appearance, directory: directory)
        }
    }

    @MainActor
    func testRenderArchiveAndNewVersion() throws {
        guard let output = ProcessInfo.processInfo.environment["DBOARD_ARCHIVE_SNAPSHOTS"] else {
            throw XCTSkip("设置 DBOARD_ARCHIVE_SNAPSHOTS 导出归档和新版本检查图")
        }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardArchiveScreens-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let archiveURL = temporary.appendingPathComponent("archive.md")
        var block = ["### D014【ultra】车点点锁券与照片查询链路改造 #已完成 ✅2026-10-30",
                     "- **分支**：feature/lock-coupon", "- **描述**：原版已完成上线，准备继续迭代",
                     "- **进度**：", "    - 10.30: 独立锁券接口完成，已验收"]
        DemandPrompt.set(&block, value: DemandPromptSections(codeEntry: "ultra三渠里的车点点链路",
            materials: "https://example.com/docs/coupon",
            intent: "提供独立锁券接口，依次查券、锁券、查照片。").stored)
        let archived = try XCTUnwrap(DemandArchive.parse(block.joined(separator: "\n")).first)
        try block.joined(separator: "\n").write(to: archiveURL, atomically: true, encoding: .utf8)
        let store = DemandArchiveStore(cache: archiveURL, journalURL: temporary.appendingPathComponent("journal.json"),
                                       allowsRemote: false)
        let vm = DBoardViewModel(loadCache: false)
        vm.demandArchives = store
        var draft = try archived.newDraft(id: "D015")
        draft.promptSections.intent = "在原有锁券接口上增加超时重试，并记录失败原因。保留原有查券、锁券、查照片的调用顺序。"
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            vm.workspacePage = .history
            try render(DBoardRootView().environmentObject(vm).environmentObject(ThemeManager.shared)
                .environmentObject(FontManager.shared), width: 760, height: 560,
                name: "archive-history-" + name, appearance: appearance, directory: output)
            try render(DemandArchiveSection(store: store).environmentObject(vm)
                .background(Color(nsColor: .windowBackgroundColor)),
                width: 520, height: 480, name: "archive-compact-" + name, appearance: appearance, directory: output)
            try render(NewDemandVersionForm(record: archived, draft: draft, cancel: {}, create: { _ in false })
                .environmentObject(vm), width: 640, height: 640,
                name: "archive-new-version-" + name, appearance: appearance, directory: output)
        }
    }

    @MainActor
    func testRenderCompletedRequirements() throws {
        guard let directory = ProcessInfo.processInfo.environment["DBOARD_RESOURCE_SNAPSHOTS"] else {
            throw XCTSkip("设置 DBOARD_RESOURCE_SNAPSHOTS 导出个人已完成需求检查图")
        }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let flow = BizMapViewModel(loadBackgroundData: false)
        flow.cache = try JSONDecoder().decode(BizMapCache.self, from: Data("""
        {"generated":"","phase":{"done":[],"current":"","rest":[]},"groups":[],"services":[],"routes":[],"dItemsAll":[],
        "prdItemsAll":[
        {"id":1,"no":"R2610300001","name":"车点点锁券接口改造","code":"KFZ","status":"开发中","scopes":["mine","dept"],"services":[],"docs":[],"url":"https://example.com/1"},
        {"id":2,"no":"R2610280001","name":"上一项需求已完成验收","code":"CPYSWC","status":"承接人验收完成","scopes":["mine","dept"],"services":[],"docs":[],"url":"https://example.com/2"}]}
        """.utf8))
        flow.perspective = .requirements
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try render(BizMapBoardView(refreshOnAppear: false).environmentObject(flow).environmentObject(ThemeManager.shared)
                .environmentObject(FontManager.shared), width: 840, height: 740,
                name: "reqflow-personal-completed-" + name, appearance: appearance, directory: directory)
        }
    }

    @MainActor
    func testRenderDemandProgressHistory() throws {
        guard let directory = ProcessInfo.processInfo.environment["DBOARD_PROGRESS_SNAPSHOTS"] else {
            throw XCTSkip("设置 DBOARD_PROGRESS_SNAPSHOTS 导出进度历史折叠检查图")
        }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let milestones = [
            Milestone(date: "10.28", content: "确认原有服务入口和需求资料，整理需要改造的调用流程。"),
            Milestone(date: "10.29", content: "完成接口拆分，新增查券、锁券、查询照片的聚合入口。"),
            Milestone(date: "10.30", content: "处理重复调用、锁券失败和部分券码的兼容场景。"),
            Milestone(date: "10.30", content: "联调发现需要补充返回字段，已在原实现上完成追加改动。"),
            Milestone(date: "10.30", content: "最新进度：改造完成，相关验证通过。\n待办：与上游联调，并等待测试验收。")
        ]
        let vm = DBoardViewModel(loadCache: false)
        let item = DItem(id: "D013", project: "工作台", title: "", headerTitle: "需求进度历史折叠",
                         status: .inProgress, priority: .p1, deadline: nil, branch: nil,
                         startDate: nil, milestones: milestones)
        vm.items = [item]
        vm.expandedIDs = [item.id]
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try render(ItemCardView(item: item).environmentObject(vm)
                .environmentObject(ThemeManager.shared).environmentObject(FontManager.shared)
                .frame(width: 520, height: 500, alignment: .top)
                .background(ThemeManager.shared.current.background),
                width: 520, height: 500, name: "progress-card-latest-" + name,
                appearance: appearance, directory: directory)
            for all in [false, true] {
                try render(DemandProgressHistoryView(milestones: milestones, expanded: .constant(all))
                    .environmentObject(ThemeManager.shared).environmentObject(FontManager.shared)
                    .padding(16).frame(width: 520, height: 400, alignment: .topLeading)
                    .background(ThemeManager.shared.current.background),
                    width: 520, height: 400, name: (all ? "progress-all-" : "progress-latest-") + name,
                    appearance: appearance, directory: directory)
            }
        }
    }

    @MainActor
    private func render<V: View>(_ view: V, width: CGFloat, height: CGFloat, name: String,
                                 appearance: NSAppearance.Name, directory: String) throws {
        let previousAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: appearance)
        defer { NSApp.appearance = previousAppearance }
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "D板"
        window.toolbarStyle = .unified
        window.appearance = NSAppearance(named: appearance)
        window.contentViewController = NSHostingController(rootView: view.environment(\.colorScheme, appearance == .darkAqua ? .dark : .light))
        window.setContentSize(NSSize(width: width, height: height))
        window.orderBack(nil)
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory + "/" + name + ".png"))
        XCTAssertGreaterThan(png.count, 1000)
    }
}
