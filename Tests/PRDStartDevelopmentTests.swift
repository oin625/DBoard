import XCTest
import Foundation
@testable import DBoard

private final class PRDStatusTestProtocol: URLProtocol {
    private final class HandlerStorage: @unchecked Sendable {
        let lock = NSLock()
        var value: ((URLRequest) -> (Int, Data))?
    }
    private static let storage = HandlerStorage()
    static var handler: ((URLRequest) -> (Int, Data))? {
        get { storage.lock.withLock { storage.value } }
        set { storage.lock.withLock { storage.value = newValue } }
    }
    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class PRDStartDevelopmentTests: XCTestCase {
    private let detail = Data(#"{"success":true,"data":{"id":2463,"reqType":"10","currentStatus":"SJWC","launchTime":null,"acceptorId":null,"acceptorName":null,"submitterId":"333751","submitterName":"333751 - 测试提交人"}}"#.utf8)

    func testStartDevelopmentRequiresChosenDateAndSendsOfficialFieldsTogether() throws {
        var draft = try PRDStartDevelopmentDraft.decode(detail, reqID: 2463)
        XCTAssertEqual(draft.launchTime, "")
        XCTAssertEqual(draft.validationError, "请选择计划上线日期")
        XCTAssertThrowsError(try PRDStatusChange(reqID: 2463, toStatus: "KFZ", actionName: "开始开发", development: draft))
        draft.launchTime = "2026-11-03"
        let body = try JSONEncoder().encode(PRDStatusChange(reqID: 2463, toStatus: "KFZ", actionName: "开始开发", development: draft))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["launchTime"] as? String, "2026-11-03")
        XCTAssertEqual(json["acceptorId"] as? String, "333751")
        XCTAssertEqual(json["acceptorName"] as? String, "333751 - 测试提交人")
        XCTAssertNil(json["onlineTime"])
        XCTAssertThrowsError(try PRDStatusChange(reqID: 99, toStatus: "KFZ", actionName: "开始开发", development: draft))
        let other = try JSONEncoder().encode(PRDStatusChange(reqID: 2463, toStatus: "KFWC", actionName: "开发完成", development: draft))
        let otherJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: other) as? [String: Any])
        XCTAssertNil(otherJSON["launchTime"])
        XCTAssertNil(otherJSON["acceptorId"])
    }

    func testExistingPlanAndAcceptorArePreservedAndOtherTypesCanOmitDate() throws {
        let data = Data(#"{"success":true,"data":{"id":2463,"reqType":"30","currentStatus":"YJS","launchTime":"2026-11-10 00:00:00","acceptorId":"existing","acceptorName":"原验收人","submitterId":"other"}}"#.utf8)
        var draft = try PRDStartDevelopmentDraft.decode(data, reqID: 2463)
        XCTAssertEqual(draft.launchTime, "2026-11-10")
        XCTAssertEqual(draft.acceptorID, "existing")
        XCTAssertEqual(draft.acceptorName, "原验收人")
        draft.launchTime = ""
        XCTAssertNil(draft.validationError)
        XCTAssertNoThrow(try PRDStatusChange(reqID: 2463, toStatus: "KFZ", actionName: "开始开发", development: draft))
    }

    func testInvalidDatesChangedStateAndMissingDetailsAreRejected() throws {
        for text in ["2026-02-30", "2026-13-01", "11.3", "2026-11-03\nother"] {
            XCTAssertNil(PRDStartDevelopmentDraft.date(text))
        }
        XCTAssertNotNil(PRDStartDevelopmentDraft.date("2028-02-29"))
        for text in [
            #"{"success":false,"message":"无权限"}"#,
            #"{"success":true,"data":{"id":2463,"reqType":"10","currentStatus":"KFZ"}}"#,
            #"{"success":true,"data":{"id":99,"reqType":"10","currentStatus":"SJWC"}}"#,
            #"{"success":true,"data":{"id":2463,"currentStatus":"SJWC"}}"#
        ] {
            XCTAssertThrowsError(try PRDStartDevelopmentDraft.decode(Data(text.utf8), reqID: 2463))
        }
    }

    @MainActor
    private func makeVM(refresh: @escaping () -> Void = {}) throws -> (BizMapViewModel, URLSession, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PRDStatusTests-" + UUID().uuidString)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PRDStatusTestProtocol.self]
        let session = URLSession(configuration: config)
        let vm = BizMapViewModel(loadBackgroundData: false,
            projectStore: DevelopmentProjectStore(url: directory.appendingPathComponent("projects.json")),
            statusSession: session, statusCookie: { "test-session=fixture" }, statusRefresh: refresh)
        vm.cache = try JSONDecoder().decode(BizMapCache.self, from: Data(#"{"generated":"fixture","phase":{"done":[],"current":"","rest":[]},"groups":[],"services":[],"routes":[],"dItemsAll":[],"prdItemsAll":[{"id":2463,"no":"R2463","name":"测试需求","code":"SJWC","status":"方案设计完成","scopes":["pending"],"services":[],"docs":[],"url":"https://example.com/prd/index.html#detail/2463"}]}"#.utf8))
        return (vm, session, directory)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for the mocked request")
    }

    @MainActor
    func testButtonReadsDetailsBeforePostAndPreventsEmptyDateAndDoubleSubmission() async throws {
        var refreshed = false
        let (vm, session, directory) = try makeVM { refreshed = true }
        defer { session.invalidateAndCancel(); PRDStatusTestProtocol.handler = nil; try? FileManager.default.removeItem(at: directory) }
        let submitted = expectation(description: "single status POST")
        submitted.assertForOverFulfill = true
        PRDStatusTestProtocol.handler = { [detail] request in
            if request.httpMethod == "POST" {
                let body = (try? JSONSerialization.jsonObject(with: PRDStatusTestProtocol.body(request))) as? [String: Any] ?? [:]
                XCTAssertEqual(body["id"] as? Int, 2463)
                XCTAssertEqual(body["toStatus"] as? String, "KFZ")
                XCTAssertEqual(body["launchTime"] as? String, "2026-11-03")
                XCTAssertEqual(body["acceptorId"] as? String, "333751")
                submitted.fulfill()
                return (200, Data(#"{"success":true}"#.utf8))
            }
            XCTAssertEqual(request.url?.path, "/prd/api/requirement/detail/2463")
            return (200, detail)
        }
        vm.pushStatus(reqId: 2463, toStatus: "KFZ", actionName: "开始开发")
        try await waitUntil { vm.startDevelopmentDraft != nil }
        XCTAssertEqual(vm.startDevelopmentItem?.id, 2463)
        vm.pushStatus(reqId: 2463, toStatus: "KFZ", actionName: "开始开发", developmentDraft: vm.startDevelopmentDraft)
        XCTAssertTrue(vm.statusSubmitting.isEmpty)
        XCTAssertEqual(vm.startDevelopmentError, "请选择计划上线日期")
        vm.startDevelopmentDraft?.launchTime = "2026-11-03"
        vm.pushStatus(reqId: 2463, toStatus: "KFZ", actionName: "开始开发", developmentDraft: vm.startDevelopmentDraft)
        vm.pushStatus(reqId: 2463, toStatus: "KFZ", actionName: "开始开发", developmentDraft: vm.startDevelopmentDraft)
        await fulfillment(of: [submitted], timeout: 2)
        try await waitUntil { refreshed }
        XCTAssertNil(vm.startDevelopmentItem)
        XCTAssertTrue(vm.statusSubmitting.isEmpty)
    }

    @MainActor
    func testHTTPFailureKeepsChosenDateAndAllowsRetry() async throws {
        let (vm, session, directory) = try makeVM { XCTFail("Failed response triggered refresh") }
        defer { session.invalidateAndCancel(); PRDStatusTestProtocol.handler = nil; try? FileManager.default.removeItem(at: directory) }
        vm.startDevelopmentItem = vm.prdItems.first
        vm.startDevelopmentDraft = try PRDStartDevelopmentDraft.decode(detail, reqID: 2463)
        vm.startDevelopmentDraft?.launchTime = "2026-11-03"
        PRDStatusTestProtocol.handler = { _ in (500, Data(#"{"success":true}"#.utf8)) }
        vm.pushStatus(reqId: 2463, toStatus: "KFZ", actionName: "开始开发", developmentDraft: vm.startDevelopmentDraft)
        try await waitUntil { vm.statusSubmitting.isEmpty }
        XCTAssertEqual(vm.startDevelopmentDraft?.launchTime, "2026-11-03")
        XCTAssertEqual(vm.startDevelopmentItem?.id, 2463)
        XCTAssertTrue(vm.startDevelopmentError?.contains("HTTP 500") == true)
        PRDStatusTestProtocol.handler = { _ in (200, Data(#"{"success":false,"message":"无操作权限"}"#.utf8)) }
        vm.pushStatus(reqId: 2463, toStatus: "KFZ", actionName: "开始开发", developmentDraft: vm.startDevelopmentDraft)
        try await waitUntil { vm.statusSubmitting.isEmpty }
        XCTAssertTrue(vm.startDevelopmentError?.contains("无操作权限") == true)
        XCTAssertEqual(vm.startDevelopmentDraft?.launchTime, "2026-11-03")
    }
}
