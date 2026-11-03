import XCTest
@testable import DBoard

/// 全部使用临时文件与本地进程；不读写真实缓存，不调用钉钉、AI 表格或 PRD。
final class ReliabilityTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardReliability-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fixture(_ content: String) throws -> URL {
        let url = directory.appendingPathComponent("cache.md")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    private func todos(_ url: URL, date: String) throws -> [TodoItem] {
        let parsed = CacheParser.parse(content: try read(url))
        return ([parsed.todaySec].compactMap { $0 } + parsed.prevSecs).first { $0.dateLabel == date }?.items ?? []
    }

    private let carried = """
    ## 📝 零碎
    ### 2026-10-27
    - [x] 排查核销问题 ✅10:43
    ### 2026-10-28
    - [ ] 排查核销问题
    """

    // MARK: 零碎事项精确定位

    func testCarriedTodoToggleTouchesOnlyItsOriginalDate() throws {
        let url = try fixture(carried)
        let target = try XCTUnwrap(todos(url, date: "2026-10-28").first)
        XCTAssertTrue(TodoStore.change(target, .toggle, at: url).ok)
        XCTAssertEqual(try todos(url, date: "2026-10-27").first?.isCompleted, true, "旧完成记录不能被取消")
        XCTAssertEqual(try todos(url, date: "2026-10-28").first?.isCompleted, true)
        XCTAssertEqual(try todos(url, date: "2026-10-28").first?.text, "排查核销问题")
    }

    func testDeleteTargetsExactRecordAndCanBeRestored() throws {
        let url = try fixture(carried)
        let target = try XCTUnwrap(todos(url, date: "2026-10-28").first)
        let result = TodoStore.change(target, .delete, at: url)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(try todos(url, date: "2026-10-27").count, 1, "相似的旧记录必须保留")
        XCTAssertTrue(try todos(url, date: "2026-10-28").isEmpty)
        XCTAssertTrue(TodoStore.restore(try XCTUnwrap(result.removal), at: url))
        XCTAssertEqual(try todos(url, date: "2026-10-28").first?.text, "排查核销问题")
        XCTAssertFalse(TodoStore.restore(try XCTUnwrap(result.removal), at: url), "已恢复的记录不能重复插入")
    }

    func testStaleOrDuplicateRecordsFailClosed() throws {
        let url = try fixture(carried)
        let target = try XCTUnwrap(todos(url, date: "2026-10-28").first)
        try (try read(url)).replacingOccurrences(of: "- [ ] 排查核销问题", with: "- [ ] 排查核销问题（已改）")
            .write(to: url, atomically: true, encoding: .utf8)
        let before = try read(url)
        XCTAssertFalse(TodoStore.change(target, .edit("新内容"), at: url).ok)
        XCTAssertEqual(try read(url), before, "外部改动后旧快照不能覆盖")

        let duplicate = try fixture("## 📝 零碎\n### 2026-10-28\n- [ ] 同一件事\n- [ ] 同一件事")
        let first = try XCTUnwrap(todos(duplicate, date: "2026-10-28").first)
        XCTAssertFalse(TodoStore.change(first, .toggle, at: duplicate).ok, "无法唯一定位时不写入")
    }

    func testEditKeepsLinkNoteAndQuotedNoteIsParsedWhole() throws {
        let url = try fixture("## 📝 零碎\n### 2026-10-28\n- [ ] 联调 `→ D013`\n> 💬 等对方环境")
        let item = try XCTUnwrap(todos(url, date: "2026-10-28").first)
        XCTAssertEqual(item.note, "等对方环境")
        XCTAssertEqual(item.linkedDItem, "D013")
        XCTAssertTrue(TodoStore.change(item, .edit("联调电话线索"), at: url).ok)
        let edited = try XCTUnwrap(todos(url, date: "2026-10-28").first)
        XCTAssertEqual(edited.text, "联调电话线索")
        XCTAssertEqual(edited.note, "等对方环境")
        XCTAssertEqual(edited.linkedDItem, "D013")
        XCTAssertNotNil(edited.origin?.persistentID, "改过的记录获得稳定标识")
        XCTAssertTrue(TodoStore.change(edited, .note("已约时间"), at: url).ok)
        XCTAssertEqual(try todos(url, date: "2026-10-28").first?.id, edited.id, "有稳定标识后身份不变")
    }

    func testAddRejectsMultilineAndReusesSingleDateBlock() throws {
        let url = try fixture("## 📝 零碎\n### 2026-10-28\n- [ ] 已有")
        XCTAssertFalse(TodoStore.add("第一行\n第二行", at: url, date: "2026-10-28"))
        XCTAssertTrue(TodoStore.add("新增", at: url, date: "2026-10-28"))
        XCTAssertTrue(TodoStore.add("明天的", at: url, date: "2026-10-29"))
        let content = try read(url)
        XCTAssertEqual(content.components(separatedBy: "### 2026-10-28").count, 2)
        XCTAssertEqual(try todos(url, date: "2026-10-28").map(\.text), ["已有", "新增"])
        XCTAssertEqual(try todos(url, date: "2026-10-29").map(\.text), ["明天的"])
    }

    // MARK: 需求内容与日期

    func testTitleKeepsVersionNumbersAndDescriptionKeepsAllLines() throws {
        let url = try fixture("""
        ## 🟡 重要不紧急
        ### D001【测试】质保3.0升级 #进行中 📅10.28→🎯11.19
        - **描述**：第一行
            第二行：含冒号
            第三行
        - **进度**：
            - 10.28: 开始
        """)
        var item = try XCTUnwrap(CacheParser.parse(content: try read(url)).items.first)
        XCTAssertEqual(item.headerTitle, "质保3.0升级")
        XCTAssertEqual(item.title, "第一行\n第二行：含冒号\n第三行")
        XCTAssertEqual(item.milestones.count, 1)

        var draft = DItemDraft(from: item)
        draft.desc = "改后第一行\n改后第二行"
        XCTAssertTrue(DItemStore.save(draft, original: item, at: url))
        item = try XCTUnwrap(CacheParser.parse(content: try read(url)).items.first)
        XCTAssertEqual(item.title, "改后第一行\n改后第二行")
        XCTAssertEqual(item.milestones.first?.content, "开始", "进度不能被描述替换吞掉")
    }

    func testDeadlineUsesNaturalDaysAndShowsOverdue() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 18))!
        XCTAssertEqual(DemandDates.daysRemaining(start: "10.28", deadline: "11.19", on: now, calendar: calendar), 21)
        XCTAssertEqual(DemandDates.daysRemaining(start: nil, deadline: "10.29", on: now, calendar: calendar), 0)
        XCTAssertEqual(DemandDates.daysRemaining(start: nil, deadline: "10.27", on: now, calendar: calendar), -2)
        XCTAssertEqual(DemandDates.daysRemaining(start: "2026-10-28", deadline: "2026-11-30", on: now, calendar: calendar), 32)
        XCTAssertEqual(DemandDates.daysRemaining(start: "12.20", deadline: "1.10", on: now, calendar: calendar), 73)
        for invalid in ["13.1", "2.30", "2026-02-30", "11.19abc"] {
            XCTAssertNil(DemandDates.daysRemaining(start: nil, deadline: invalid, on: now, calendar: calendar))
        }
        XCTAssertNil(DemandDates.period(start: "2026-11-20", deadline: "2026-11-19", on: now, calendar: calendar))
    }

    func testDraftValidationBlocksInvalidPeriodsAndMultilineHeaders() {
        var draft = DItemDraft(newID: "D099", priority: .p1)
        draft.name = "测试"
        draft.start = "2026-11-20"; draft.deadline = "2026-11-19"
        XCTAssertNotNil(draft.validationError)
        draft.deadline = "2026-11-30"
        XCTAssertNil(draft.validationError)
        draft.name = "两行\n标题"
        XCTAssertNotNil(draft.validationError)
        XCTAssertFalse(DItemStore.create(draft, at: directory.appendingPathComponent("none.md")))
    }

    func testDeleteRequiresExpectedSnapshotAndRestoreRefusesDuplicates() throws {
        let url = try fixture("## 🔴 重要且紧急\n### D001【a】一 #进行中\n- **描述**：x\n")
        XCTAssertNil(DItemStore.delete(id: "D001", expected: ["### D001【a】一 #进行中"], at: url))
        let block = try XCTUnwrap(DItemStore.delete(id: "D001", at: url))
        XCTAssertTrue(CacheParser.parse(content: try read(url)).items.isEmpty)
        XCTAssertTrue(DItemStore.restore(block, id: "D001", priority: .p0, at: url))
        XCTAssertFalse(DItemStore.restore(block, id: "D001", priority: .p0, at: url))
        XCTAssertEqual(CacheParser.parse(content: try read(url)).items.map(\.id), ["D001"])
    }

    // MARK: 外部命令结果

    func testBusinessSuccessRequiresBooleanTrueAndCleanExit() {
        XCTAssertFalse(BusinessResponse.succeeded(Data(#"{"success":false,"msg":"\"success\""}"#.utf8)))
        XCTAssertFalse(BusinessResponse.succeeded(Data(#"{"success":"true"}"#.utf8)))
        XCTAssertFalse(BusinessResponse.succeeded(Data("not json".utf8)))
        XCTAssertTrue(BusinessResponse.succeeded(Data("提示信息\n{\"success\":true}\n".utf8)))
        let failedExit = ProcessRunner.run("/bin/sh", arguments: ["-c", #"echo '{"success":true}'; exit 3"#])
        XCTAssertEqual(failedExit.exitCode, 3)
        XCTAssertFalse(failedExit.businessSucceeded)
        let ok = ProcessRunner.run("/bin/sh", arguments: ["-c", #"echo '{"success":true}'"#])
        XCTAssertTrue(ok.businessSucceeded)
    }

    func testRunnerDrainsLargeOutputAndTimesOut() {
        let large = ProcessRunner.run("/bin/sh", arguments: ["-c", "head -c 3000000 /dev/zero; head -c 3000000 /dev/zero >&2"], timeout: 10)
        XCTAssertEqual(large.exitCode, 0)
        XCTAssertFalse(large.timedOut)
        XCTAssertFalse(large.outputComplete, "超过保留上限时不能当成完整结果")
        let slow = ProcessRunner.run("/bin/sh", arguments: ["-c", "sleep 5"], timeout: 0.3)
        XCTAssertTrue(slow.timedOut)
        XCTAssertFalse(slow.succeeded)
    }

    func testArchiveJournalStopsWhenUnreadable() throws {
        let url = directory.appendingPathComponent("journal.json")
        try "{broken".write(to: url, atomically: true, encoding: .utf8)
        let journal = ArchiveJournal(url: url)
        XCTAssertFalse(journal.readable)
        XCTAssertFalse(journal.save(.init(id: "D001", original: ["a"], archived: ["b"], state: .submitted, createdAt: Date())))
        XCTAssertEqual(try read(url), "{broken", "不可读时不覆盖旧凭证")

        let fresh = ArchiveJournal(url: directory.appendingPathComponent("fresh.json"))
        XCTAssertTrue(fresh.save(.init(id: "D002", original: ["a"], archived: ["b"], state: .uploaded, createdAt: Date())))
        XCTAssertEqual(ArchiveJournal(url: directory.appendingPathComponent("fresh.json")).entries["D002"]?.state, .uploaded)
    }

    // MARK: 界面状态

    @MainActor
    func testFiltersMatchMetricsAndSearch() {
        let vm = DBoardViewModel(loadCache: false)
        func item(_ id: String, _ status: ItemStatus, _ priority: ItemPriority, branch: String? = nil) -> DItem {
            DItem(id: id, project: "p", title: "", headerTitle: "需求\(id)", status: status, priority: priority,
                  deadline: nil, branch: branch, startDate: nil, milestones: [])
        }
        vm.items = [item("D001", .inProgress, .p1, branch: "feature/coupon"), item("D002", .pending, .p0),
                    item("D003", .suspended, .p2)]
        vm.showDemands(.urgent)
        XCTAssertEqual(vm.filteredItems.map(\.id), ["D002"])
        vm.showDemands(.inProgress)
        XCTAssertEqual(vm.filteredItems.map(\.id), ["D001"])
        vm.demandFilter = .all; vm.demandQuery = "coupon"
        XCTAssertEqual(vm.filteredItems.map(\.id), ["D001"])
        vm.focusItem("D003")
        XCTAssertEqual(vm.demandFilter, .all, "定位需求时清掉会隐藏它的筛选")
        XCTAssertTrue(vm.filteredItems.contains { $0.id == "D003" })
    }

    @MainActor
    func testReplyActionWriteFailureKeepsItem() throws {
        let blocker = directory.appendingPathComponent("not-a-directory")
        try "x".write(to: blocker, atomically: true, encoding: .utf8)
        let vm = ReplyInboxViewModel(startObservers: false, actionDirectory: blocker)
        vm.items = [ReplyItem(key: "k", convId: "c", convTitle: "t", isSingle: true, sender: "s", incoming: "i",
                              incomingTime: "", drafts: [], needInvestigation: false, investigationNote: "")]
        XCTAssertFalse(vm.writeAction(["type": "dismiss"], removeKey: "k"))
        XCTAssertEqual(vm.items.count, 1)
        XCTAssertNotNil(vm.actionFeedback)

        let ok = ReplyInboxViewModel(startObservers: false, actionDirectory: directory.appendingPathComponent("actions"))
        ok.items = vm.items
        XCTAssertTrue(ok.writeAction(["type": "dismiss"], removeKey: "k"))
        XCTAssertTrue(ok.items.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("actions").path).count, 1)
    }

    func testExpiredSensitiveClipsAreNotLoadedWithoutPurge() throws {
        let store = ClipboardStore(url: directory.appendingPathComponent("clips.sqlite"))
        store.insert(ClipRecord(hash: "secret", kind: .text, content: "sk-test", imageData: nil, thumbData: nil,
                                fileURLs: [], sourceApp: nil, sensitive: true, expiresAt: Date().addingTimeInterval(0.3)))
        store.insert(ClipRecord(hash: "plain", kind: .text, content: "普通", imageData: nil, thumbData: nil,
                                fileURLs: [], sourceApp: nil, sensitive: false, expiresAt: nil))
        XCTAssertEqual(store.loadAll().count, 2)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(store.loadAll().map(\.content), ["普通"])
    }

    func testTableProjectStageComparesDatesWithToday() throws {
        func project(dev: String = "", test: String? = nil, online: String = "") -> TableProject {
            TableProject(recordId: "r", name: "n", desc: "", product: "", domain: "", tags: "",
                         submit: "2026-10-01", devStart: dev, online: online, test: test)
        }
        let today = "2026-10-29"
        XCTAssertEqual(project().stage(today: today).label, "未排期")
        XCTAssertEqual(project(dev: "2026-10-16").stage(today: today).label, "开发中")
        XCTAssertEqual(project(dev: "2026-11-02").stage(today: today).label, "待开发 11-02")
        XCTAssertEqual(project(dev: "2026-10-16", test: "2026-10-28").stage(today: today).label, "测试中")
        XCTAssertEqual(project(dev: "2026-10-16", test: "2026-10-28", online: "2026-11-05").stage(today: today).label, "待上线 11-05")
        XCTAssertEqual(project(dev: "2026-09-18", online: "2026-10-15").stage(today: today).label, "已上线")
        let legacy = #"{"recordId":"r","name":"n","desc":"","product":"","domain":"","tags":"","submit":"","devStart":"2026-10-16","online":""}"#
        let decoded = try JSONDecoder().decode(TableProject.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.test, "旧缓存缺少新字段时仍可读取")
        XCTAssertEqual(decoded.stage(today: today).label, "开发中")
    }

    func testContentRevisionIgnoresSyncMetadataOnly() {
        let base = "## 🔴\n### D001【a】一 #进行中"
        XCTAssertEqual(ContentRevision.hash("<!-- synced: 1 -->\n<!-- synced-hash: x -->\n" + base), ContentRevision.hash(base))
        XCTAssertNotEqual(ContentRevision.hash(base), ContentRevision.hash(base + " "))
    }
}
