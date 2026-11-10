import XCTest
@testable import DBoard

final class DevelopmentProjectsTests: XCTestCase {
    private func temporaryStore() throws -> (DevelopmentProjectStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardProjectsTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (DevelopmentProjectStore(url: directory.appendingPathComponent("projects.json")), directory)
    }

    func testOnlyDevelopmentProjectFieldProvidesAssociations() throws {
        let data = Data("""
        {"success":true,"data":{
          "1":[{"deliverableDevProject":"solution-repo:main"}],
          "3":[{"deliverableDevProject":"canary:feature/coupon;canary:feature/coupon,frontend:feature/ui",
                "deliverableContent":"可能涉及 promotioncenter，另看 tesla","authorName":"开发者"},
               {"deliverableContent":"修改 ultra"}],
          "4":[{"deliverableDevProject":"test-repo:master"}],
          "5":[],"6":[],"7":[]}}
        """.utf8)
        let response = try DevelopmentDeliverables.decode(data)
        XCTAssertEqual(response.projects, [
            DeclaredDevelopmentProject(project: "canary", branch: "feature/coupon"),
            DeclaredDevelopmentProject(project: "frontend", branch: "feature/ui")
        ])
        XCTAssertEqual(response.items.count, 4)
        XCTAssertEqual(response.tags, ["solution", "dev", "test"])
    }

    func testLatestCorrectionForTheSameAuthorAndDocumentKeepsHistoryAndOtherContributions() throws {
        let data = Data("""
        {"success":true,"data":{"3":[
          {"id":1,"authorId":"A","createTime":"2026-11-04T02:19:57Z","deliverableContent":"https://example.com/d014","deliverableDevProject":"ultra:merge/pre_1013,audi:feature/vibe"},
          {"id":2,"authorId":"A","createTime":"2026-11-04T02:30:00Z","deliverableContent":"https://example.com/d014","deliverableDevProject":"ultra:feature/cdd-lock-code,audi:feature/vibe"},
          {"id":3,"authorId":"B","createTime":"2026-11-04T02:20:00Z","deliverableContent":"https://example.com/d014","deliverableDevProject":"tesla:feature/saas"},
          {"id":4,"authorId":"A","createTime":"2026-11-04T02:18:00Z","deliverableContent":"https://example.com/other","deliverableDevProject":"ultra:feature/other"}
        ]}}
        """.utf8)
        let response = try DevelopmentDeliverables.decode(data)
        XCTAssertEqual(response.items.count, 4)
        XCTAssertEqual(response.projects, [
            DeclaredDevelopmentProject(project: "ultra", branch: "feature/cdd-lock-code"),
            DeclaredDevelopmentProject(project: "audi", branch: "feature/vibe"),
            DeclaredDevelopmentProject(project: "tesla", branch: "feature/saas"),
            DeclaredDevelopmentProject(project: "ultra", branch: "feature/other")
        ])
    }

    func testParsesExplicitSeparatorsAndKeepsDifferentBranches() {
        XCTAssertEqual(DeclaredDevelopmentProject.parse([
            " canary：feature/a， frontend；canary:feature/b\ncanary:feature/a ",
            " ; , \n ", ":missing-project", "tesla:"
        ]), [
            DeclaredDevelopmentProject(project: "canary", branch: "feature/a"),
            DeclaredDevelopmentProject(project: "frontend", branch: nil),
            DeclaredDevelopmentProject(project: "canary", branch: "feature/b"),
            DeclaredDevelopmentProject(project: "tesla", branch: nil)
        ])
    }

    func testNoDevelopmentDeclarationRemainsEmpty() throws {
        for text in [
            #"{"success":true,"data":{}}"#,
            #"{"success":true,"data":{"3":[]}}"#,
            #"{"success":true,"data":{"3":[{"deliverableDevProject":null,"deliverableContent":"canary:main"}]}}"#,
            #"{"success":true,"data":{"1":[{"deliverableDevProject":"canary:main"}]}}"#
        ] {
            XCTAssertTrue(try DevelopmentDeliverables.decode(Data(text.utf8)).projects.isEmpty)
        }
    }

    func testFailedOrChangedResponsesAreNotSuccessfulEmptyDeclarations() {
        for text in [
            #"{"success":false,"data":{}}"#,
            #"{"success":true,"data":[]}"#,
            #"{"success":true,"data":{"3":"unexpected"}}"#,
            #"{"success":true,"data":{"3":[{"deliverableDevProject":123}]}}"#,
            #"{"success":true,"data":{"projects":["canary"]}}"#
        ] {
            XCTAssertThrowsError(try DevelopmentDeliverables.decode(Data(text.utf8)))
        }
    }

    @MainActor
    func testOfficialDeclarationsSurviveDemandRefreshAndRestart() throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vm = BizMapViewModel(loadBackgroundData: false, projectStore: store)
        let response = try DevelopmentDeliverables.decode(Data(#"{"success":true,"data":{"3":[{"deliverableDevProject":"canary:feature/a"}]}}"#.utf8))
        XCTAssertTrue(vm.recordDeliverables(response, reqID: 42))
        vm.cache = try fixtureCache()
        let restarted = BizMapViewModel(loadBackgroundData: false,
            projectStore: DevelopmentProjectStore(url: directory.appendingPathComponent("projects.json")))
        XCTAssertEqual(restarted.developmentProjectSnapshots[42]?.projects, response.projects)
        XCTAssertEqual(vm.developmentProjectSnapshots[42]?.projects, response.projects)
        XCTAssertEqual(restarted.developmentProjectSnapshots[42]?.source, DevelopmentProjectSnapshot.officialSource)
    }

    @MainActor
    func testSuccessfulEmptyDeclarationReplacesPreviousSnapshot() throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vm = BizMapViewModel(loadBackgroundData: false, projectStore: store)
        XCTAssertTrue(vm.recordDeliverables(try DevelopmentDeliverables.decode(Data(#"{"success":true,"data":{"3":[{"deliverableDevProject":"canary:main"}]}}"#.utf8)), reqID: 42))
        XCTAssertTrue(vm.recordDeliverables(try DevelopmentDeliverables.decode(Data(#"{"success":true,"data":{"3":[]}}"#.utf8)), reqID: 42))
        let reloaded = DevelopmentProjectStore(url: directory.appendingPathComponent("projects.json"))
        XCTAssertNotNil(reloaded.records[42])
        XCTAssertEqual(reloaded.records[42]?.projects, [])
    }

    @MainActor
    func testSearchUsesDeclaredProjectsAndIgnoresLegacyInferences() throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vm = BizMapViewModel(loadBackgroundData: false, projectStore: store)
        vm.cache = try fixtureCache()
        vm.query = "guessed-service"
        XCTAssertTrue(vm.filteredPRD.isEmpty)
        vm.query = "guessed-project"
        XCTAssertTrue(vm.filteredPRD.isEmpty)
        XCTAssertTrue(vm.recordDeliverables(try DevelopmentDeliverables.decode(Data(#"{"success":true,"data":{"3":[{"deliverableDevProject":"actual-project:feature/actual"}]}}"#.utf8)), reqID: 42))
        vm.query = "actual-project"
        XCTAssertEqual(vm.filteredPRD.map(\.id), [42])
        vm.query = "feature/actual"
        XCTAssertEqual(vm.filteredPRD.map(\.id), [42])
    }

    func testInvalidAndUnverifiedCacheIsNotUsed() throws {
        let (_, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("projects.json")
        try Data("bad json".utf8).write(to: file)
        XCTAssertTrue(DevelopmentProjectStore(url: file).records.isEmpty)
        try Data(#"{"version":1,"records":{"42":{"source":"ai-inferred","fetchedAt":"2026-10-27T00:00:00Z","projects":[{"project":"guessed"}]}}}"#.utf8).write(to: file)
        XCTAssertTrue(DevelopmentProjectStore(url: file).records.isEmpty)
    }

    @MainActor
    func testCacheWriteFailureKeepsLiveDeclarationsAndShowsError() throws {
        let (_, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocker = directory.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: blocker)
        let vm = BizMapViewModel(loadBackgroundData: false,
            projectStore: DevelopmentProjectStore(url: blocker.appendingPathComponent("projects.json")))
        let response = try DevelopmentDeliverables.decode(Data(#"{"success":true,"data":{"3":[{"deliverableDevProject":"canary:main"}]}}"#.utf8))
        XCTAssertFalse(vm.recordDeliverables(response, reqID: 42))
        XCTAssertEqual(vm.developmentProjectSnapshots[42]?.projects, response.projects)
        XCTAssertNotNil(vm.deliverableReadErrors[42])
    }

    private func fixtureCache() throws -> BizMapCache {
        try JSONDecoder().decode(BizMapCache.self, from: Data("""
        {"generated":"2026-10-27 12:00","phase":{"done":[],"current":"","rest":[]},"groups":[],"services":[],"routes":[],"dItemsAll":[],
         "prdItemsAll":[{"id":42,"no":"R42","name":"示例需求","code":"KFZ","status":"开发中","scopes":["mine"],
                        "services":["guessed-service"],"docs":[],"url":"https://example.com",
                        "devProjects":["guessed-project:main"]}]}
        """.utf8))
    }
}
