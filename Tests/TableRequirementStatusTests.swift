import XCTest
@testable import DBoard

final class TableRequirementStatusTests: XCTestCase {
    private func project(_ name: String = "fixture", recordId: String = "record",
                         dev: String = "2026-09-01", test: String? = nil, online: String = "",
                         requirementId: Int? = nil, code: String? = nil, status: String? = nil) -> TableProject {
        TableProject(recordId: recordId, name: name, desc: "", product: "", domain: "", tags: "",
                     submit: "", devStart: dev, online: online, test: test,
                     requirementId: requirementId, requirementCode: code, requirementStatus: status)
    }

    private func requirement(_ id: Int = 42, name: String = "fixture",
                             code: String = "KFWC", status: String = "开发完成") throws -> BizPRDItem {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id, "no": "R\(id)", "name": name, "code": code, "status": status,
            "scopes": ["mine"], "services": [], "docs": [], "url": ""
        ])
        return try JSONDecoder().decode(BizPRDItem.self, from: data)
    }

    private func cache(_ items: [BizPRDItem]) -> BizMapCache {
        BizMapCache(generated: "fixture", phase: BizPhase(done: [], current: "", rest: []),
                    groups: [], services: [], routes: [], dItemsAll: [],
                    prdGenerated: "fixture", prdItemsAll: items)
    }

    func testOfficialCompletionOverridesStartAndScheduleDates() {
        let done = project(online: "2027-01-01", code: "XQWC", status: "需求完成")
        XCTAssertEqual(done.displayStage(today: "2026-11-02").label, "需求完成")
        let accepted = project(code: "CPYSWC", status: "承接人验收完成")
        XCTAssertEqual(accepted.displayStage(today: "2026-11-02").label, "承接人验收完成")
    }

    func testLatestRequirementOverridesTableStatusSnapshot() throws {
        let stale = project(requirementId: 42, code: "KFZ", status: "开发中")
        XCTAssertEqual(stale.displayStage(requirement: try requirement()).label, "开发完成")
    }

    func testUnlinkedStartOrTestDateDoesNotClaimActiveDevelopment() {
        XCTAssertEqual(project().displayStage(today: "2026-11-02").label, "状态待核实")
        XCTAssertEqual(project(test: "2026-09-02").displayStage(today: "2026-11-02").label, "状态待核实")
    }

    func testUnlinkedScheduleIsExplicitAndDatesRemainAvailable() {
        let upcoming = project(dev: "2026-12-01")
        XCTAssertEqual(upcoming.displayStage(today: "2026-11-02").label, "排期 · 待开发 12-01")
        let released = project(online: "2026-09-20")
        XCTAssertEqual(released.displayStage(today: "2026-11-02").label, "排期 · 已上线")
        XCTAssertEqual(released.online, "2026-09-20")
    }

    func testHistoricalDatesNoLongerProduceFiveDevelopingProjects() {
        let projects = [
            project(code: "KFZ", status: "开发中"),
            project(code: "KFWC", status: "开发完成"),
            project(code: "XQWC", status: "需求完成"),
            project(code: "XQWC", status: "需求完成"),
            project()
        ]
        let labels = projects.map { $0.displayStage(today: "2026-11-02").label }
        XCTAssertEqual(labels.filter { $0 == "开发中" }.count, 1)
        XCTAssertEqual(labels.filter { $0 == "开发完成" }.count, 1)
        XCTAssertEqual(labels.filter { $0 == "需求完成" }.count, 2)
        XCTAssertEqual(labels.filter { $0 == "状态待核实" }.count, 1)
    }

    func testLegacyCacheCanStillBeDecoded() throws {
        let json = #"{"recordId":"r","name":"fixture","desc":"","product":"","domain":"","tags":"","submit":"","devStart":"2026-09-01","online":""}"#
        let value = try JSONDecoder().decode(TableProject.self, from: Data(json.utf8))
        XCTAssertNil(value.requirementId)
        XCTAssertNil(value.requirementStatus)
        XCTAssertEqual(value.displayStage(today: "2026-11-02").label, "状态待核实")
    }

    @MainActor
    func testConfirmedIDSurvivesRenamingAndDoesNotFallBackToAnotherID() throws {
        let vm = BizMapViewModel(loadBackgroundData: false)
        vm.cache = cache([try requirement(name: "new name")])
        XCTAssertEqual(vm.tableProjectRequirement(project("old name", requirementId: 42))?.id, 42)
        XCTAssertNil(vm.tableProjectRequirement(project("new name", requirementId: 99)))
        XCTAssertNil(vm.tableProjectRequirement(project("new name extra")))
    }

    @MainActor
    func testDuplicateNamesStayUnresolved() throws {
        let vm = BizMapViewModel(loadBackgroundData: false)
        vm.cache = cache([try requirement(), try requirement(43)])
        XCTAssertNil(vm.tableProjectRequirement(project()))
        vm.cache = cache([try requirement()])
        vm.tableProjects = [project(), project(recordId: "other")]
        XCTAssertNil(vm.tableProjectRequirement(project()))
    }
}
