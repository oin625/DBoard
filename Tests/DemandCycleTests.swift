import XCTest
@testable import DBoard

final class DemandCycleTests: XCTestCase {
    private func calendar(_ zone: String = "Asia/Shanghai") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }
    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12,
                      calendar: Calendar? = nil) -> Date {
        (calendar ?? self.calendar()).date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testStartDayIsInclusiveAndFutureStartStaysPending() {
        let calendar = calendar()
        XCTAssertEqual(DemandCycle.status(.pending, start: "10.28", deadline: "11.19",
            on: date(2026, 10, 27, hour: 23), calendar: calendar), .pending)
        XCTAssertEqual(DemandCycle.status(.pending, start: "10.28", deadline: "11.19",
            on: date(2026, 10, 28, hour: 0), calendar: calendar), .inProgress)
        XCTAssertEqual(DemandCycle.status(.pending, start: "10.28", deadline: "11.19",
            on: date(2026, 11, 19), calendar: calendar), .inProgress)
    }

    func testLocalCalendarDayControlsStart() {
        let shanghai = calendar()
        let losAngeles = calendar("America/Los_Angeles")
        let sameInstant = date(2026, 10, 28, hour: 0, calendar: shanghai)
        XCTAssertTrue(DemandCycle.hasStarted(start: "10.28", deadline: nil,
            on: sameInstant, calendar: shanghai))
        XCTAssertFalse(DemandCycle.hasStarted(start: "10.28", deadline: nil,
            on: sameInstant, calendar: losAngeles))
    }

    func testOpenEndedAndOverdueCyclesStayInProgress() {
        let calendar = calendar()
        let now = date(2026, 11, 20)
        XCTAssertEqual(DemandCycle.status(.pending, start: "10.28", deadline: nil,
            on: now, calendar: calendar), .inProgress)
        XCTAssertEqual(DemandCycle.status(.pending, start: "10.28", deadline: "11.19",
            on: now, calendar: calendar), .inProgress)
        XCTAssertEqual(DemandCycle.status(.inProgress, start: "12.30", deadline: "1.5",
            on: date(2027, 12, 1), calendar: calendar), .inProgress)
    }

    func testExplicitCompletedSuspendedAndStartedStatesArePreserved() {
        for status in [ItemStatus.completed, .suspended, .inProgress] {
            XCTAssertEqual(DemandCycle.status(status, start: "10.28", deadline: "11.19",
                on: date(2026, 10, 28), calendar: calendar()), status)
            XCTAssertEqual(DemandCycle.status(status, start: "11.19", deadline: nil,
                on: date(2026, 10, 28), calendar: calendar()), status)
        }
    }

    func testMissingAndInvalidDatesDoNotTriggerStart() {
        for start in [nil, "", "13.1", "0.5", "2.30", "10.32", "尚未定", "10.28abc", "2.29"] as [String?] {
            XCTAssertFalse(DemandCycle.hasStarted(start: start, deadline: nil,
                on: date(2025, 10, 28), calendar: calendar()))
        }
        XCTAssertFalse(DemandCycle.hasStarted(start: "10.28", deadline: "11.31",
            on: date(2026, 10, 28), calendar: calendar()))
        XCTAssertFalse(DemandCycle.hasStarted(start: nil, deadline: "10.28",
            on: date(2026, 10, 28), calendar: calendar()))
        XCTAssertTrue(DemandCycle.hasStarted(start: " 2.29 ", deadline: nil,
            on: date(2024, 2, 29), calendar: calendar()))
    }

    func testCrossYearPeriodStartsInDecemberOrDuringJanuary() {
        let calendar = calendar()
        XCTAssertFalse(DemandCycle.hasStarted(start: "12.30", deadline: "1.5",
            on: date(2026, 10, 28), calendar: calendar))
        XCTAssertFalse(DemandCycle.hasStarted(start: "12.30", deadline: "1.5",
            on: date(2026, 12, 29), calendar: calendar))
        XCTAssertTrue(DemandCycle.hasStarted(start: "12.30", deadline: "1.5",
            on: date(2026, 12, 30), calendar: calendar))
        XCTAssertTrue(DemandCycle.hasStarted(start: "12.30", deadline: "1.5",
            on: date(2027, 1, 2), calendar: calendar))
        XCTAssertTrue(DemandCycle.hasStarted(start: "12.30", deadline: "1.5",
            on: date(2027, 1, 6), calendar: calendar))
    }

    func testReconciliationPreservesLinksNotesAndManualStatesAndIsIdempotent() {
        let source = """
        ## 🟡 重要不紧急
        ### D012【canary】质保体系 #待开始 📅10.28→🎯11.19
        - **需求流**：[R1001](https://ai.tmallyc.com/prd/index.html#detail/2085)
        - **描述**：正文里保留 #待开始
        - **进度**：
            - 10.28: 手动记录
        ### D013【ultra】电话线索 #待开始 📅10.28
        ### D014【其他】未来安排 #待开始 📅11.19
        ### D015【其他】已经完成 #已完成 📅10.28
        ### D016【其他】已挂起 #挂起 📅10.28
        """
        let update = DemandCycle.reconcile(source, on: date(2026, 10, 28), calendar: calendar())
        XCTAssertEqual(update.startedIDs, ["D012", "D013"])
        XCTAssertTrue(update.content.contains("- **描述**：正文里保留 #待开始"))
        XCTAssertTrue(update.content.contains("- **需求流**：[R1001](https://ai.tmallyc.com/prd/index.html#detail/2085)"))
        XCTAssertTrue(update.content.contains("10.28: 手动记录"))
        let parsed = CacheParser.parse(content: update.content).items
        XCTAssertEqual(parsed.map(\.status), [.inProgress, .inProgress, .pending, .completed, .suspended])
        let again = DemandCycle.reconcile(update.content, on: date(2026, 10, 29), calendar: calendar())
        XCTAssertEqual(again.content, update.content)
        XCTAssertTrue(again.startedIDs.isEmpty)
    }

    @MainActor
    func testStartedDemandsEnterHomepageCountsAndAttentionList() {
        let source = """
        ## 🟡 重要不紧急
        ### D012【canary】质保体系 #待开始 📅10.28→🎯11.19
        ### D013【ultra】电话线索 #待开始 📅10.28
        """
        let update = DemandCycle.reconcile(source, on: date(2026, 10, 28), calendar: calendar())
        let vm = DBoardViewModel(loadCache: false)
        vm.items = CacheParser.parse(content: update.content).items
        XCTAssertEqual(vm.inProgressCount, 2)
        XCTAssertEqual(Set(vm.attentionItems.map(\.id)), ["D012", "D013"])
    }

    func testCreatingAndSavingUsesScheduleAndKeepsManualOverrides() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardCycleTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cache.md")
        try "## 🟡 重要不紧急\n".write(to: file, atomically: true, encoding: .utf8)
        var draft = DItemDraft(newID: "D001", priority: .p1)
        draft.name = "今天开始"
        XCTAssertEqual(draft.scheduledStatus, .inProgress)
        XCTAssertTrue(DItemStore.create(draft, at: file))
        var item = try XCTUnwrap(CacheParser.parse(content: String(contentsOf: file, encoding: .utf8)).items.first)
        XCTAssertEqual(item.status, .inProgress)
        draft = DItemDraft(from: item)
        draft.status = .suspended
        XCTAssertTrue(DItemStore.save(draft, original: item, at: file))
        item = try XCTUnwrap(CacheParser.parse(content: String(contentsOf: file, encoding: .utf8)).items.first)
        XCTAssertEqual(item.status, .suspended)
        draft = DItemDraft(from: item)
        draft.status = .pending
        draft.start = ""
        XCTAssertTrue(DItemStore.save(draft, original: item, at: file))
        item = try XCTUnwrap(CacheParser.parse(content: String(contentsOf: file, encoding: .utf8)).items.first)
        XCTAssertEqual(item.status, .pending)
    }
}
