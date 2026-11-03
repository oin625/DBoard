import XCTest
@testable import DBoard

final class ReqFlowCompletionTests: XCTestCase {
    func testAcceptedDemandsAreCompletedForMeWithoutHidingSearchOrDepartmentHistory() throws {
        let data = Data("""
        {"generated":"","phase":{"done":[],"current":"","rest":[]},"groups":[],"services":[],"routes":[],"dItemsAll":[],
         "prdItemsAll":[
          {"id":1,"no":"R001","name":"验收结束","code":"CPYSWC","status":"承接人验收完成","scopes":["mine","dept"],"services":[],"docs":[],"url":""},
          {"id":2,"no":"R002","name":"待验收","code":"CPYSZ","status":"承接人验收中","scopes":["mine","dept"],"services":[],"docs":[],"url":""},
          {"id":3,"no":"R003","name":"开发中","code":"KFZ","status":"开发中","scopes":["mine","dept"],"services":[],"docs":[],"url":""},
          {"id":4,"no":"R004","name":"组内已完成","code":"CPYSWC","status":"承接人验收完成","scopes":["dept"],"services":[],"docs":[],"url":""},
          {"id":5,"no":"R005","name":"完成名称兜底","code":"legacy","status":"承接人验收完成","scopes":["mine"],"services":[],"docs":[],"url":""}
         ]}
        """.utf8)
        let vm = BizMapViewModel(loadBackgroundData: false)
        vm.cache = try JSONDecoder().decode(BizMapCache.self, from: data)
        XCTAssertEqual(Set(vm.myActive.map(\.id)), [2, 3])
        XCTAssertEqual(Set(vm.myCompleted.map(\.id)), [1, 5])
        XCTAssertTrue(vm.tabItems(.others).contains { $0.id == 4 })
        vm.query = "验收结束"
        XCTAssertEqual(vm.filteredPRD.map(\.id), [1])
        let mine = ReqFlowLinkQueries.candidates(vm.prdItems, scope: .mine, query: "")
        XCTAssertEqual(Set(mine.map(\.id)), [2, 3])
        let department = ReqFlowLinkQueries.candidates(vm.prdItems, scope: .department, query: "")
        XCTAssertTrue(department.contains { $0.id == 1 })
    }
}
