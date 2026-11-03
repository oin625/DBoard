import XCTest
@testable import DBoard

final class CanaryCookieBridgeTests: XCTestCase {
    let key = String(repeating: "a", count: 64)
    let origin = "chrome-extension://" + String(repeating: "a", count: 32)

    func testPairRequiresNativeConsentAndThrottlesRequests() throws {
        let bridge = CanaryCookieBridge(token: key)
        let now = Date()
        let invalid = bridge.pair(origin: "https://evil.example", approve: { XCTFail("Invalid origin prompted"); return true }, now: now)
        XCTAssertEqual(invalid.status, "403 Forbidden")
        let denied = bridge.pair(origin: origin, approve: { false }, now: now)
        XCTAssertEqual(denied.status, "403 Forbidden")
        XCTAssertFalse(String(decoding: denied.body, as: UTF8.self).contains(key))
        let busy = bridge.pair(origin: origin, approve: { XCTFail("Cooling down prompted"); return true }, now: now)
        XCTAssertEqual(busy.status, "429 Too Many Requests")
        let allowed = bridge.pair(origin: origin, approve: {
            let pending = bridge.pair(origin: self.origin, approve: { XCTFail("Concurrent prompt"); return true }, now: now.addingTimeInterval(61))
            XCTAssertEqual(pending.status, "429 Too Many Requests")
            return true
        }, now: now.addingTimeInterval(31))
        XCTAssertEqual(allowed.status, "200 OK")
        let json = try JSONSerialization.jsonObject(with: allowed.body) as! [String: String]
        XCTAssertEqual(json["token"], key)
    }

    func testPairingEnvironmentExpiryAndLogout() throws {
        let bridge = CanaryCookieBridge(token: key)
        let now = Date()
        func call(_ method: String, _ path: String, _ body: [String: String] = [:],
                  auth: String? = nil, time: Date? = nil) throws -> (String, Data) {
            bridge.response(method: method, path: path, origin: method == "POST" ? origin : "",
                authorization: auth ?? "Bearer " + key,
                body: try JSONSerialization.data(withJSONObject: body), now: time ?? now)
        }
        let payload = ["environment": "prod", "origin": CanaryCookieBridge.origins["prod"]!, "cookie": "session=secret"]
        XCTAssertEqual(try call("POST", "/canary-cookie", payload, auth: "wrong").0, "403 Forbidden")
        XCTAssertEqual(try call("GET", "/canary-cookie/prod").0, "409 Conflict")
        XCTAssertEqual(try call("POST", "/canary-cookie", payload).0, "200 OK")
        let reply = try call("GET", "/canary-cookie/prod")
        let data = try JSONSerialization.jsonObject(with: reply.1) as! [String: String]
        XCTAssertEqual(data["cookie"], "session=secret")
        XCTAssertEqual(data["origin"], CanaryCookieBridge.origins["prod"])
        XCTAssertEqual(try call("GET", "/canary-cookie/pre").0, "409 Conflict")
        var wrong = payload
        wrong["environment"] = "pre"
        XCTAssertEqual(try call("POST", "/canary-cookie", wrong).0, "400 Bad Request")
        wrong = payload; wrong["cookie"] = "session=bad\r\nX: bad"
        XCTAssertEqual(try call("POST", "/canary-cookie", wrong).0, "400 Bad Request")
        XCTAssertEqual(try call("GET", "/canary-cookie/prod", time: now.addingTimeInterval(91)).0, "409 Conflict")
        XCTAssertEqual(try call("POST", "/canary-cookie", payload).0, "200 OK")
        var logout = payload; logout["cookie"] = ""
        XCTAssertEqual(try call("POST", "/canary-cookie", logout).0, "200 OK")
        XCTAssertEqual(try call("GET", "/canary-cookie/prod").0, "409 Conflict")
        let denied = bridge.response(method: "GET", path: "/canary-cookie/prod", origin: "https://evil.example",
            authorization: "Bearer " + key, body: Data())
        XCTAssertEqual(denied.status, "404 Not Found")
    }
}
